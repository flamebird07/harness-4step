#!/usr/bin/env python3
"""Unified CLI executor for the 4-step harness method."""
from __future__ import annotations
import argparse, hashlib, json, os, subprocess, sys, time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

STEP_CLI = {
    "step1": {"agent": "codex", "executable": r"C:\Users\Administrator\AppData\Roaming\npm\codex.cmd",
              "args": ["exec", "--ephemeral", "--skip-git-repo-check", "--sandbox", "danger-full-access", "--json"],
              "timeout_seconds": 180},
    "step2": {"agent": "codex", "executable": r"C:\Users\Administrator\AppData\Roaming\npm\codex.cmd",
              "args": ["exec", "--ephemeral", "--skip-git-repo-check", "--sandbox", "danger-full-access", "--json"],
              "timeout_seconds": 180},
    "step3": {"agent": "mimo", "executable": r"C:\Users\Administrator\AppData\Roaming\npm\codex.cmd",
              "args": ["exec", "--ephemeral", "--skip-git-repo-check", "--sandbox", "workspace-write", "--json", "--model", "mimo"],
              "timeout_seconds": 300},
    "step4": {"agent": "kimi", "executable": r"C:\Users\Administrator\AppData\Roaming\npm\kimi.cmd",
              "args": ["-p"], "timeout_seconds": 120},
}

@dataclass
class CliRunResult:
    step: str; agent: str; command: list; started_at: str; finished_at: str
    duration_ms: int; exit_code: int; stdout_path: str; stderr_path: str
    evidence_path: str; output_sha256: str; success: bool
    failure_reason: str | None = None; agent_message: str | None = None

def run_cli(*, step: str, task_id: str, workspace: Path, prompt: str,
            timeout_seconds: int | None = None) -> CliRunResult:
    if step not in STEP_CLI:
        raise ValueError(f"Unknown step: {step}")
    cfg = STEP_CLI[step]; agent = cfg["agent"]; exe = cfg["executable"]
    if not os.path.isfile(exe):
        return CliRunResult(step=step, agent=agent, command=[exe], started_at="", finished_at="",
            duration_ms=0, exit_code=-1, stdout_path="", stderr_path="", evidence_path="",
            output_sha256="", success=False, failure_reason=f"Not found: {exe}")
    cmd = [exe] + cfg["args"] + [prompt]
    d = Path.home() / ".hermes" / "harness-workspace" / task_id / step
    d.mkdir(parents=True, exist_ok=True)
    stdout_p, stderr_p, ev_p = d/"stdout.jsonl", d/"stderr.txt", d/"evidence.json"
    (d/"prompt.txt").write_text(prompt, encoding="utf-8")
    t = timeout_seconds or cfg["timeout_seconds"]; s0 = time.monotonic()
    sa = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    try:
        r = subprocess.run(cmd, cwd=str(workspace), stdin=subprocess.DEVNULL,
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=t, shell=False)
        ec, so, se = r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        ec, so, se = -2, "", f"Timeout {t}s"
    except Exception as e:
        ec, so, se = -3, "", str(e)
    dm = int((time.monotonic()-s0)*1000); fa = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    stdout_p.write_text(so, encoding="utf-8"); stderr_p.write_text(se, encoding="utf-8")
    h = hashlib.sha256(so.encode()).hexdigest()
    am = None
    if agent == "codex":
        for ln in so.split("\n"):
            if not ln.strip(): continue
            try:
                d2 = json.loads(ln)
                if d2.get("type")=="item.completed" and d2.get("item",{}).get("type")=="agent_message":
                    am = d2["item"].get("text","")
            except: pass
    elif agent == "kimi":
        am = so.strip()
    ok = ec == 0 and bool(so.strip())
    fr = f"Exit code: {ec}" if ec != 0 else ("Empty stdout" if not so.strip() else None)
    ev = {"schema_version":1,"task_id":task_id,"step":step,"agent":agent,"executable":exe,
          "command":cmd,"workspace":str(workspace),"started_at":sa,"finished_at":fa,
          "duration_ms":dm,"exit_code":ec,"stdout_path":str(stdout_p),"stderr_path":str(stderr_p),
          "output_sha256":h,"success":ok,"failure_reason":fr,
          "agent_message_preview":(am or "")[:500] if am else None}
    tmp = ev_p.with_suffix(".tmp")
    tmp.write_text(json.dumps(ev, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(ev_p)
    return CliRunResult(step=step, agent=agent, command=cmd, started_at=sa, finished_at=fa,
        duration_ms=dm, exit_code=ec, stdout_path=str(stdout_p), stderr_path=str(stderr_p),
        evidence_path=str(ev_p), output_sha256=h, success=ok, failure_reason=fr, agent_message=am)

def verify_evidence(ev_p: Path) -> tuple[bool, str]:
    if not ev_p.is_file(): return False, f"Not found: {ev_p}"
    try: ev = json.loads(ev_p.read_text(encoding="utf-8"))
    except Exception as e: return False, str(e)
    for f in ["schema_version","task_id","step","agent","exit_code","success"]:
        if f not in ev: return False, f"Missing: {f}"
    if not ev.get("success"): return False, f"Failed: {ev.get('failure_reason')}"
    return True, "OK"

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--step", required=True, choices=["step1","step2","step3","step4"])
    p.add_argument("--task-id", required=True); p.add_argument("--workspace", required=True)
    p.add_argument("--prompt"); p.add_argument("--prompt-file"); p.add_argument("--timeout", type=int)
    p.add_argument("--verify-only", action="store_true")
    a = p.parse_args(); ws = Path(a.workspace)
    if not ws.is_dir(): print(f"Error: {ws}", file=sys.stderr); sys.exit(1)
    if a.verify_only:
        ev = Path.home()/".hermes"/"harness-workspace"/a.task_id/a.step/"evidence.json"
        ok, msg = verify_evidence(ev)
        print(json.dumps({"success":ok,"message":msg})); sys.exit(0 if ok else 1)
    prompt = Path(a.prompt_file).read_text(encoding="utf-8") if a.prompt_file else (a.prompt or "")
    if not prompt: print("Need --prompt or --prompt-file", file=sys.stderr); sys.exit(1)
    r = run_cli(step=a.step, task_id=a.task_id, workspace=ws, prompt=prompt, timeout_seconds=a.timeout)
    print(json.dumps(asdict(r), ensure_ascii=False, indent=2)); sys.exit(0 if r.success else 1)
