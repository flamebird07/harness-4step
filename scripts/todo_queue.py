#!/usr/bin/env python3
"""Durable, dependency-aware to-do queue for the 4-step harness."""
from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Any

VALID_STATES = {"pending", "running", "completed", "blocked", "split"}
ATOMIC_FIELDS = {"id", "title", "acceptance", "files"}
STEPS = ("step1", "step2", "step3", "step4")


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


def split(task_id: str, parent_id: str, children: list[dict[str, Any]], reason: str) -> list[dict[str, Any]]:
    if not children:
        raise ValueError("Split requires at least one child")
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
        c.update(state="pending", loops=0, history=[{"event": "created_by_split", "parent": parent_id}])
        prepared.append(c)
    parent["state"] = "split"
    parent.setdefault("history", []).append({"event": "split", "reason": reason, "children": [x["id"] for x in prepared]})
    data["items"].extend(prepared); _write(path, data)
    return prepared


def next_item(task_id: str) -> dict[str, Any] | None:
    path = queue_path(task_id); data = _read(path)
    completed = {x["id"] for x in data["items"] if x.get("state") == "completed"}
    for item in data["items"]:
        if item.get("state") == "pending" and set(item.get("depends_on", [])) <= completed:
            if item.get("split_required"):
                raise ValueError(
                    f"Item '{item['id']}' requires split (read-only step failed twice); "
                    "split it instead of reclaiming"
                )
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
    attempts = item.setdefault("step_attempts", {})
    attempts[step] = int(attempts.get(step, 0)) + 1
    event = {"event": "step_completed" if success else "step_failed", "step": step,
             "attempt": attempts[step], "evidence": evidence_path}
    item.setdefault("history", []).append(event)
    if success:
        next_index = STEPS.index(step) + 1
        item["next_step"] = STEPS[next_index] if next_index < len(STEPS) else "finish"
    elif step in {"step1", "step2", "step4"} and attempts[step] >= 2:
        item["split_required"] = True
        item["history"].append({"event": "split_required", "reason": "two failed read-only attempts", "step": step})
    _write(path, data)
    return item


def finish(task_id: str, item_id: str, state: str, note: str = "") -> dict[str, Any]:
    if state not in {"completed", "blocked"}:
        raise ValueError("finish state must be completed or blocked")
    path = queue_path(task_id); data = _read(path)
    item = next((x for x in data["items"] if x["id"] == item_id), None)
    if not item:
        raise ValueError(f"Unknown to-do id: {item_id}")
    if state == "completed" and item.get("next_step") != "finish":
        raise ValueError("Cannot complete item until Step 1 through Step 4 all succeed")
    item["state"] = state; item.setdefault("history", []).append({"event": state, "note": note})
    _write(path, data); return item


def recover(task_id: str, item_id: str, note: str = "") -> dict[str, Any]:
    """Return an orphaned running item to pending so it can be reclaimed.

    Only a running item may be recovered. The split_required flag is preserved:
    a split-forced item still blocks reclaim (next_item raises) until it is
    split into children, so recovery cannot bypass the split gate.
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
    data["counts"] = counts
    data["complete"] = counts["pending"] == counts["running"] == counts["blocked"] == 0
    return data
