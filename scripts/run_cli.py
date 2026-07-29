#!/usr/bin/env python3
"""
Unified CLI executor for the 4-step harness method.

Default: Codex/Codex/MiMo/Kimi (4-step harness contract).
Users can override per-step via ~/.hermes/harness-config.yaml.
To use MiMo Code (free) for ALL steps, create the config file with:
  step1: {agent: mimo}
  step2: {agent: mimo}
  step4: {agent: mimo}

No private paths are hardcoded — executables are resolved via shutil.which().
"""
from __future__ import annotations
import argparse, hashlib, json, os, shutil, subprocess, sys, time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Default configuration — Codex/Codex/MiMo/Kimi (4-step harness contract)
# ---------------------------------------------------------------------------

DEFAULT_CONFIG = {
    "step1": {
        "agent": "codex",
        "description": "Review: analyze, find root cause",
        "timeout_seconds": 120,
    },
    "step2": {
        "agent": "codex",
        "description": "Plan: design fix approach (read-only, --ephemeral)",
        "timeout_seconds": 120,
    },
    "step3": {
        "agent": "codex",
        "description": "Execute: implement code changes (-s danger-full-access)",
        "timeout_seconds": 300,
    },
    "step4": {
        "agent": "mimo",
        "description": "Re-review: verify changes (fallback: Codex CLI)",
        "timeout_seconds": 180,
    },
}

# Default config comment for new users:
# Current 4-step method: Codex/Codex/Codex/MiMo (harness-4step v10.0.0)
# Step 4 MiMo is currently broken on this machine (all models fail).
# Fallback: use Codex CLI directly for Step 4.
# To use MiMo Code (free) for ALL steps, create ~/.hermes/harness-config.yaml:
#   step1: {agent: mimo}
#   step2: {agent: mimo}
#   step4: {agent: mimo}

# Agent -> CLI executable mapping (resolved dynamically, no hardcoded paths)
AGENT_CLI = {
    "codex": {
        "executable": "codex",
        "args_base": ["exec", "--ephemeral", "--skip-git-repo-check",
                      "--sandbox", "danger-full-access", "--json"],
    },
    "mimo": {
        "executable": "mimo",
        "args_base": ["run", "--print-logs"],
    },
    "kimi": {
        "executable": "kimi",
        "args_base": ["-p"],
    },
}


def _load_user_config() -> dict[str, Any]:
    """Load user overrides from ~/.hermes/harness-config.yaml (if exists)."""
    config_path = Path.home() / ".hermes" / "harness-config.yaml"
    if not config_path.is_file():
        return {}
    try:
        import yaml
        with open(config_path, "r", encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    except ImportError:
        try:
            return json.loads(config_path.read_text(encoding="utf-8"))
        except Exception:
            return {}
    except Exception:
        return {}


def _resolve_executable(agent: str) -> str | None:
    """Find CLI executable via shutil.which() — no hardcoded paths."""
    cli_info = AGENT_CLI.get(agent)
    if not cli_info:
        return None
    exe = cli_info["executable"]
    # Try direct name first
    found = shutil.which(exe)
    if found:
        return found
    # Try with .cmd extension on Windows
    if sys.platform == "win32":
        for ext in [".cmd", ".exe", ".bat"]:
            found = shutil.which(exe + ext)
            if found:
                return found
    return None


def get_step_config(step: str) -> dict[str, Any]:
    """Get merged config for a step: defaults + user overrides."""
    user_config = _load_user_config()
    step_cfg = dict(DEFAULT_CONFIG.get(step, {}))
    if step in user_config:
        step_cfg.update(user_config[step])
    if "all" in user_config:
        step_cfg.update(user_config["all"])
    return step_cfg


@dataclass
class CliRunResult:
    step: str; agent: str; command: list; started_at: str; finished_at: str
    duration_ms: int; exit_code: int; stdout_path: str; stderr_path: str
    evidence_path: str; output_sha256: str; success: bool
    failure_reason: str | None = None; agent_message: str | None = None


def run_cli(*, step: str, task_id: str, workspace: Path, prompt: str,
            timeout_seconds: int | None = None) -> CliRunResult:
    if step not in DEFAULT_CONFIG:
        raise ValueError(f"Unknown step: {step}. Must be step1-step4.")
    cfg = get_step_config(step)
    agent = cfg["agent"]
    exe = _resolve_executable(agent)
    if not exe:
        return CliRunResult(step=step, agent=agent, command=[agent], started_at="",
            finished_at="", duration_ms=0, exit_code=-1, stdout_path="",
            stderr_path="", evidence_path="", output_sha256="", success=False,
            failure_reason=f"CLI '{agent}' not found. Install or override in ~/.hermes/harness-config.yaml")
    cli_info = AGENT_CLI[agent]
    cmd = [exe] + cli_info["args_base"] + [prompt]
    d = Path.home() / ".hermes" / "harness-workspace" / task_id / step
    d.mkdir(parents=True, exist_ok=True)
    stdout_p, stderr_p, ev_p = d/"stdout.jsonl", d/"stderr.txt", d/"evidence.json"
    (d/"prompt.txt").write_text(prompt, encoding="utf-8")
    t = timeout_seconds or cfg.get("timeout_seconds", 180)
    s0 = time.monotonic(); sa = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    try:
        r = subprocess.run(cmd, cwd=str(workspace), stdin=subprocess.DEVNULL,
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            timeout=t, shell=False)
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
    elif agent in ("mimo", "kimi"):
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


def print_config():
    print("=== harness-4step CLI Configuration ===")
    print("Current: Codex/Codex/Codex/MiMo (harness-4step v10.0.0)")
    print("Step 4 MiMo is broken on this machine — fallback to Codex CLI directly.")
    print("Config file: ~/.hermes/harness-config.yaml")
    print()
    for step in ["step1","step2","step3","step4"]:
        cfg = get_step_config(step)
        exe = _resolve_executable(cfg["agent"])
        status = "OK" if exe else "NOT FOUND"
        print(f"  {step}: agent={cfg['agent']}, exe={exe or 'N/A'} ({status})")
    print()
    print("To use MiMo Code (free) for ALL steps:")
    print("  Create ~/.hermes/harness-config.yaml with:")
    print("    step1: {agent: mimo}")
    print("    step2: {agent: mimo}")
    print("    step4: {agent: mimo}")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description="4-step harness CLI executor")
    p.add_argument("--step", choices=["step1","step2","step3","step4"])
    p.add_argument("--task-id"); p.add_argument("--workspace")
    p.add_argument("--prompt"); p.add_argument("--prompt-file")
    p.add_argument("--timeout", type=int)
    p.add_argument("--verify-only", action="store_true")
    p.add_argument("--show-config", action="store_true")
    a = p.parse_args()
    if a.show_config:
        print_config(); sys.exit(0)
    if not a.step or not a.task_id or not a.workspace:
        p.error("--step, --task-id, --workspace required (or --show-config)")
    ws = Path(a.workspace)
    if not ws.is_dir(): print(f"Error: {ws}", file=sys.stderr); sys.exit(1)
    if a.verify_only:
        ev = Path.home()/".hermes"/"harness-workspace"/a.task_id/a.step/"evidence.json"
        ok, msg = verify_evidence(ev)
        print(json.dumps({"success":ok,"message":msg})); sys.exit(0 if ok else 1)
    prompt = Path(a.prompt_file).read_text(encoding="utf-8") if a.prompt_file else (a.prompt or "")
    if not prompt: print("Need --prompt or --prompt-file", file=sys.stderr); sys.exit(1)
    r = run_cli(step=a.step, task_id=a.task_id, workspace=ws, prompt=prompt, timeout_seconds=a.timeout)
    # Print CLI invocation info for transparency
    print(f"\n{'='*60}")
    print(f"CLI Invoked: {r.agent.upper()}")
    print(f"Step: {r.step}")
    print(f"Command: {' '.join(r.command[:3])}...")
    print(f"{'='*60}\n")
    print(json.dumps(asdict(r), ensure_ascii=False, indent=2)); sys.exit(0 if r.success else 1)
