#!/usr/bin/env python3
"""Conservative repair utility for persisted Hermes harness queues.

It repairs only deterministic metadata damage: a missing document task_id and a
Step 3 that has a successful evidence record but was left running before the
queue state was written. It never closes, deletes, unblocks, or rebinds work.
"""
from __future__ import annotations

import argparse
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path


def atomic_write(path: Path, data: dict) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def stamp() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def repair_task_ids(root: Path, apply: bool) -> list[Path]:
    repaired: list[Path] = []
    for path in root.rglob("todo.json"):
        data = json.loads(path.read_text(encoding="utf-8"))
        if data.get("task_id"):
            continue
        data["task_id"] = path.parent.name
        data["updated_at"] = stamp()
        repaired.append(path)
        if apply:
            shutil.copy2(path, path.with_name("todo.json.before-metadata-repair.bak"))
            atomic_write(path, data)
    return repaired


def repair_successful_step3(root: Path, task_id: str, item_id: str, apply: bool) -> Path | None:
    path = root / task_id / "todo.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    item = next((entry for entry in data.get("items", []) if entry.get("id") == item_id), None)
    if not item or item.get("state") != "running" or item.get("next_step") != "step3":
        return None
    evidence_path = root / task_id / "step3" / "evidence.json"
    evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    if evidence.get("step") != "step3" or not evidence.get("success") or evidence.get("exit_code") != 0:
        return None
    if any(event.get("event") == "step_completed" and event.get("step") == "step3" for event in item.get("history", [])):
        return None
    attempts = item.setdefault("step_attempts", {})
    attempts["step3"] = int(attempts.get("step3", 0)) + 1
    item.setdefault("history", []).append({
        "event": "step_completed", "step": "step3", "attempt": attempts["step3"],
        "evidence": str(evidence_path), "note": "queue metadata repair: verified successful existing evidence",
    })
    item["next_step"] = "step4"
    data["updated_at"] = stamp()
    if apply:
        shutil.copy2(path, path.with_name("todo.json.before-step3-repair.bak"))
        atomic_write(path, data)
    return path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace-root", type=Path, default=Path.home() / ".hermes" / "harness-workspace")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--repair-step3", nargs=2, metavar=("TASK_ID", "ITEM_ID"))
    args = parser.parse_args()
    repaired = repair_task_ids(args.workspace_root, args.apply)
    step3 = repair_successful_step3(args.workspace_root, *args.repair_step3, args.apply) if args.repair_step3 else None
    print(json.dumps({"dry_run": not args.apply, "task_ids": [str(p) for p in repaired], "step3": str(step3) if step3 else None}, ensure_ascii=False))


if __name__ == "__main__":
    raise SystemExit(main())
