#!/usr/bin/env python3
"""Durable, dependency-aware to-do queue for the 4-step harness."""
from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Any

TERMINAL_STATES = {"completed", "blocked"}
NON_TERMINAL_STATES = {"pending", "running", "split"}
# 注意：split 是中转态（父项拆分后等待子项），子项全部完成后由 _propagate_parent_completion 自动终态化
# split 不应被 finish() 直接设置，也不应出现在 summary counts 中作为终态
VALID_STATES = TERMINAL_STATES | NON_TERMINAL_STATES
ATOMIC_FIELDS = {"id", "title", "acceptance", "files"}
STEPS = ("step1", "step2", "step3", "step4")


def _split_on_first_timeout() -> bool:
    """超时即拆开关：HERMES_SPLIT_ON_FIRST_TIMEOUT=1（默认开）时，只读步骤第 1 次超时即触发拆分。"""
    import os
    return os.environ.get("HERMES_SPLIT_ON_FIRST_TIMEOUT", "1").lower() in {"1", "true", "yes", "on"}


def _is_timeout_evidence(evidence_path: str) -> bool:
    """识别 run_cli 传入的超时证据串（failure_reason 前缀，如 'Timeout after 120s'）。"""
    return "timeout" in (evidence_path or "").lower()


def decide_disposition(item: dict[str, Any], step: str, attempt: int, is_timeout: bool) -> str:
    """只读步骤失败处置优先级（core-logic §4b）：超时即拆（第 1 次），否则 2 次失败才拆。"""
    if _split_on_first_timeout() and is_timeout:
        return "split" if attempt >= 1 else "retry"
    return "split" if attempt >= 2 else "retry"


def queue_path(task_id: str) -> Path:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,79}", task_id):
        raise ValueError("task-id must contain only letters, numbers, dot, underscore, or hyphen")
    return Path.home() / ".hermes" / "harness-workspace" / task_id / "todo.json"


def _read(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise FileNotFoundError(f"To-do queue does not exist: {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1 or not isinstance(data.get("items"), list):
        raise ValueError("Invalid to-do queue")
    return data


def _write(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def _validate_item(item: dict[str, Any]) -> None:
    missing = ATOMIC_FIELDS - set(item)
    if missing:
        raise ValueError(f"To-do item missing: {', '.join(sorted(missing))}")
    if not isinstance(item["files"], list) or not item["files"]:
        raise ValueError("To-do item files must be a non-empty list")
    if not str(item["acceptance"]).strip():
        raise ValueError("To-do item acceptance must be non-empty")


def initialize(task_id: str, title: str) -> dict[str, Any]:
    path = queue_path(task_id)
    if path.is_file():
        raise ValueError(f"To-do queue already exists: {path} (use --todo-add to append items)")
    data = {"schema_version": 1, "task_id": task_id, "title": title, "items": [],
            "created_at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
    _write(path, data)
    return data


def add(task_id: str, item: dict[str, Any]) -> dict[str, Any]:
    _validate_item(item)
    path = queue_path(task_id); data = _read(path)
    if any(x["id"] == item["id"] for x in data["items"]):
        raise ValueError(f"Duplicate to-do id: {item['id']}")
    item = dict(item)
    item.setdefault("depends_on", [])
    item.setdefault("state", "pending")
    item.setdefault("loops", 0)
    item.setdefault("history", [])
    item.setdefault("next_step", "step1")
    item.setdefault("step_attempts", {})
    if item["state"] not in VALID_STATES:
        raise ValueError("Invalid to-do state")
    data["items"].append(item); _write(path, data)
    return item


def _propagate_parent_completion(task_id: str, parent_id: str):
    """当所有子项均为终态时，自动将父项置为 completed"""
    path = queue_path(task_id); data = _read(path)
    parent = next((x for x in data["items"] if x["id"] == parent_id), None)
    if not parent:
        return
    children_ids = parent.get("children", [])
    if not children_ids:
        return
    all_done = all(
        next((x for x in data["items"] if x["id"] == cid), {}).get("state") in TERMINAL_STATES
        for cid in children_ids
    )
    if all_done:
        parent["state"] = "completed"
        # 清理 children 引用，防止悬挂
        parent.pop("children", None)
        parent.setdefault("history", []).append({"event": "parent_completed", "reason": "all_children_terminal"})
        _write(path, data)


def split(task_id: str, parent_id: str, children: list[dict[str, Any]], reason: str) -> list[dict[str, Any]]:
    if not children:
        raise ValueError("Split requires at least one child")
    if not reason or not str(reason).strip():
        raise ValueError("Split requires a non-empty reason (split events must carry reason)")
    path = queue_path(task_id); data = _read(path)
    parent = next((x for x in data["items"] if x["id"] == parent_id), None)
    if not parent or parent.get("state") not in {"pending", "running"}:
        raise ValueError("Only a pending or running item may be split")
    existing = {x["id"] for x in data["items"]}
    prepared = []
    for child in children:
        _validate_item(child)
        if child["id"] in existing:
            raise ValueError(f"Duplicate to-do id: {child['id']}")
        existing.add(child["id"])
        c = dict(child); c.setdefault("depends_on", list(parent.get("depends_on", [])))
        inherited_history = [h for h in parent.get("history", []) if h.get("event") == "step_completed"]
        c.setdefault("next_step", parent.get("next_step", "step1"))
        c.setdefault("step_attempts", dict(parent.get("step_attempts", {})))
        c.update(state="pending", loops=0,
                 history=[{"event": "created_by_split", "parent": parent_id}] + inherited_history)
        prepared.append(c)
    parent["state"] = "split"
    # F-A-04：split() 是唯一「解套」出口——清除拆分门粘性标记，使子项可独立领取。
    parent["split_required"] = False
    parent["pending_split"] = False
    parent.setdefault("history", []).append({"event": "split", "reason": reason, "children": [x["id"] for x in prepared]})
    data["items"].extend(prepared); _write(path, data)
    # F-P03: split() 调用后立即触发一次向上检查
    _propagate_parent_completion(task_id, parent_id)
    return prepared


def next_item(task_id: str) -> dict[str, Any] | None:
    path = queue_path(task_id); data = _read(path)
    completed = {x["id"] for x in data["items"] if x.get("state") == "completed"}
    for item in data["items"]:
        if item.get("state") == "pending" and set(item.get("depends_on", [])) <= completed:
            if item.get("split_required"):
                # Skip: a split-forced item must be split, but must not block
                # other claimable items (parallel dispatch). It stays pending.
                continue
            item["state"] = "running"
            item.setdefault("next_step", "step1")
            item.setdefault("history", []).append({"event": "claimed"})
            _write(path, data)
            return item
    return None


def begin_step(task_id: str, item_id: str, step: str) -> dict[str, Any]:
    if step not in STEPS:
        raise ValueError("Invalid harness step")
    path = queue_path(task_id); data = _read(path)
    item = next((x for x in data["items"] if x["id"] == item_id), None)
    if not item or item.get("state") != "running":
        raise ValueError("Step requires a claimed running to-do item")
    if item.get("split_required"):
        raise ValueError(
            f"Item '{item_id}' requires split (read-only step failed twice); "
            "split it instead of re-running steps"
        )
    if item.get("next_step") != step:
        raise ValueError(f"Out-of-order step: expected {item.get('next_step')}, got {step}")
    item.setdefault("history", []).append({"event": "step_started", "step": step})
    _write(path, data)
    return item


def record_step(task_id: str, item_id: str, step: str, success: bool, evidence_path: str = "") -> dict[str, Any]:
    path = queue_path(task_id); data = _read(path)
    item = next((x for x in data["items"] if x["id"] == item_id), None)
    if not item:
        raise ValueError(f"Unknown to-do id: {item_id}")
    if item.get("next_step") != step:
        raise ValueError(f"Out-of-order step: expected {item.get('next_step')}, got {step}")
    attempts = item.setdefault("step_attempts", {})
    attempts[step] = int(attempts.get(step, 0)) + 1
    event = {"event": "step_completed" if success else "step_failed", "step": step,
             "attempt": attempts[step], "evidence": evidence_path}
    item.setdefault("history", []).append(event)
    if success:
        # F-A-04：若该 step 曾因超时被判「需拆分」（经由降级换 CLI 重跑成功），
        # 拆分门不因成功而消失——仍要求先拆分，禁止「成功降级=免拆分」。
        if item.get("pending_split"):
            item["split_required"] = True
            item["history"].append({"event": "split_required",
                                    "reason": "step previously timed out and was routed around by CLI switch",
                                    "step": step})
            item["pending_split"] = True   # 锁定，直到真正 split()
        else:
            next_index = STEPS.index(step) + 1
            item["next_step"] = STEPS[next_index] if next_index < len(STEPS) else "finish"
            # F-P02: 若 next_step 已推进到 finish 且当前 step 为 step4，自动终态化
            if item["next_step"] == "finish" and step == "step4":
                finish(task_id, item_id, state="completed")
    elif step in {"step1", "step2", "step4"}:
        # F-A-02/F-A-03/F-A-04：超时即拆（第 1 次），或 2 次非超时失败；
        # 「换 CLI 重跑」不计入免拆（decide_disposition 判定，拆分优先于降级）。
        is_timeout = _is_timeout_evidence(evidence_path)
        if decide_disposition(item, step, attempts[step], is_timeout) == "split":
            item["split_required"] = True
            item["pending_split"] = True
            item["history"].append({"event": "split_required",
                                    "reason": ("read-only timeout on first attempt" if is_timeout
                                               else "two failed read-only attempts"),
                                    "step": step})
    _write(path, data)
    return item


def _all_steps_completed(item: dict) -> bool:
    """检查 item 是否所有 step1-4 evidence 均存在于 history"""
    history = item.get("history", [])
    completed_steps = {e["step"] for e in history if e.get("step_completed")}
    return completed_steps >= {"step1", "step2", "step3", "step4"}


def finish(task_id: str, item_id: str, state: str = None, note: str = "") -> dict[str, Any]:
    # state 为 None 时触发自动终态判定（清理残留项）
    if state is None:
        path = queue_path(task_id); data = _read(path)
        item = next((x for x in data["items"] if x["id"] == item_id), None)
        if not item:
            raise ValueError(f"Unknown to-do id: {item_id}")
        if item.get("next_step") == "finish" and _all_steps_completed(item):
            state = "completed"
        else:
            state = "blocked"  # 保守兜底
    # 移除 state 必须是 completed/blocked 的硬性校验，允许任意值覆写
    path = queue_path(task_id); data = _read(path)
    item = next((x for x in data["items"] if x["id"] == item_id), None)
    if not item:
        raise ValueError(f"Unknown to-do id: {item_id}")
    if state == "completed" and item.get("next_step") != "finish":
        raise ValueError("Cannot complete item until Step 1 through Step 4 all succeed")
    item["state"] = state; item.setdefault("history", []).append({"event": state, "note": note})
    # F-P03: 对已设置 children 的父项触发向上传播
    if item.get("children"):
        _propagate_parent_completion(task_id, item_id)
    _write(path, data); return item


def recover(task_id: str, item_id: str, note: str = "") -> dict[str, Any]:
    """Return an orphaned running item to pending so it can be reclaimed.

    Only a running item may be recovered. The split_required flag is preserved:
    a split-forced item still cannot be reclaimed (next_item skips it) until it
    is split into children, so recovery cannot bypass the split gate.
    """
    path = queue_path(task_id); data = _read(path)
    item = next((x for x in data["items"] if x["id"] == item_id), None)
    if not item:
        raise ValueError(f"Unknown to-do id: {item_id}")
    if item.get("state") != "running":
        raise ValueError("Only a running item may be recovered")
    item["state"] = "pending"
    item.setdefault("history", []).append({"event": "recovered", "note": note})
    _write(path, data); return item


def summary(task_id: str) -> dict[str, Any]:
    data = _read(queue_path(task_id))
    counts = {state: sum(x.get("state") == state for x in data["items"]) for state in VALID_STATES}
    # F-O01：显式暴露「等待拆分」的卡死项，避免 UI 上混同正常 pending/running 而不可察觉。
    awaits_split = [x["id"] for x in data["items"]
                    if x.get("split_required") and x.get("state") in {"pending", "running"}]
    counts["awaits_split"] = len(awaits_split)
    # F-P07: 新增 non_terminal_items 字段
    non_terminal_items = []
    for item in data["items"]:
        if item.get("state") not in TERMINAL_STATES:
            non_terminal_items.append({
                "task_id": task_id,
                "item_id": item["id"],
                "state": item["state"],
                "next_step": item.get("next_step")
            })
    data["counts"] = counts
    data["awaits_split_ids"] = awaits_split
    data["complete"] = (counts["pending"] == counts["running"] == counts["blocked"] == 0
                        and not awaits_split)
    data["non_terminal_items"] = non_terminal_items  # F-P07
    data["non_terminal_count"] = len(non_terminal_items)  # F-P07: 精确残留数
    return data
