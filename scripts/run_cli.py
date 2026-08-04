#!/usr/bin/env python3
"""
Unified CLI executor for the 4-step harness method.

Default: Codex/Codex/Codex/Kimi (4-step harness contract).
Users can override per-step via ~/.hermes/harness-config.yaml.
For example, to use Claude for Step 1, create the config file with:
  step1: {agent: claude}

No private paths are hardcoded — executables are resolved via shutil.which().
"""
from __future__ import annotations
import argparse, hashlib, json, os, shutil, subprocess, sys, time
from copy import deepcopy
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from todo_queue import add as todo_add, finish as todo_finish, initialize as todo_initialize
from todo_queue import begin_step as todo_begin_step, next_item as todo_next
from todo_queue import record_step as todo_record_step, split as todo_split, summary as todo_summary

# ---------------------------------------------------------------------------
# Default configuration — step bindings (agent + timeout per step)
# ---------------------------------------------------------------------------

DEFAULT_CONFIG = {
    "step1": {
        "agent": "codex",
        "description": "Review: analyze, find root cause",
        "timeout_seconds": 120,
    },
    "step2": {
        "agent": "codex",
        "description": "Plan: design fix approach (read-only)",
        "timeout_seconds": 120,
    },
    "step3": {
        "agent": "codex",
        "description": "Execute: implement code changes",
        "timeout_seconds": 300,
    },
    "step4": {
        "agent": "kimi",
        "description": "Re-review: verify changes (read-only)",
        "timeout_seconds": 180,
    },
}

# Default config matches the fixed v12.16 binding. Per-step overrides remain
# available only when the user explicitly changes the binding.

# Agent -> CLI executable mapping (resolved dynamically, no hardcoded paths)
AGENT_CLI = {
    "codex": {
        "executable": "codex",
        "args_base": ["exec", "--ephemeral", "--skip-git-repo-check",
                      "--sandbox", "danger-full-access", "--json"],
        "output_parse": "json_lines",
        "step3_remove_args": ["--ephemeral"],
    },
    "mimo": {
        "executable": "mimo",
        "args_base": ["run", "--print-logs", "-m", "xiaomi/mimo-v2.5-pro"],
        "output_parse": "plain",
        "step3_remove_args": [],
    },
    "kimi": {
        "executable": "kimi",
        "args_base": ["-p"],
        "output_parse": "plain",
        "step3_remove_args": [],
    },
    "claude": {
        "executable": "claude",
        "args_base": ["-p"],
        "output_parse": "plain",
        "step3_remove_args": ["-p"],
        "args_extra": ["--dangerously-skip-permissions"],
    },
}


def _deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    """Recursively merge configuration without changing its inputs."""
    result = deepcopy(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = _deep_merge(result[key], value)
        else:
            result[key] = deepcopy(value)
    return result


@dataclass(frozen=True)
class HarnessConfig:
    """Configuration model for the harness's steps, agents, and defaults."""
    defaults: dict[str, Any]
    agents: dict[str, dict[str, Any]]
    steps: dict[str, dict[str, Any]]
    source: Path

    def step(self, name: str) -> dict[str, Any]:
        if name not in self.steps:
            raise ValueError(f"Unknown step: {name}. Configured steps: {', '.join(self.steps)}.")
        return _deep_merge(self.defaults, self.steps[name])

    def agent(self, name: str) -> dict[str, Any]:
        try:
            return self.agents[name]
        except KeyError as error:
            raise ValueError(f"Unknown agent '{name}' in {self.source}.") from error

    def resolve_executable(self, agent: str) -> str | None:
        exe = self.agent(agent)["executable"]
        if found := shutil.which(exe):
            return found
        if sys.platform == "win32":
            for ext in (".cmd", ".exe", ".bat"):
                if found := shutil.which(exe + ext):
                    return found
        return None


def _config_path() -> Path:
    """Environment override supports project-local configs and automated tests."""
    return Path(os.environ.get("HERMES_HARNESS_CONFIG", Path.home() / ".hermes" / "harness-config.yaml"))


def _binding_lock_path() -> Path:
    return Path(os.environ.get("HERMES_BINDING_LOCK", Path.home() / ".hermes" / "binding-lock.json"))


def load_binding_lock(path: Path | None = None) -> dict[str, Any]:
    """Load the user-approved immutable step-to-agent bindings."""
    source = path or _binding_lock_path()
    if not source.is_file():
        raise ValueError(f"Missing binding lock: {source}")
    data = json.loads(source.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1 or not data.get("locked") or not isinstance(data.get("bindings"), dict):
        raise ValueError(f"Invalid binding lock: {source}")
    if set(data["bindings"]) != set(DEFAULT_CONFIG):
        raise ValueError("Binding lock must define exactly step1, step2, step3, step4")
    return data


def authorize_binding_change(step: str, agent: str, authorization: str) -> dict[str, Any]:
    """Change one binding only with explicit, auditable user authorization text."""
    if step not in DEFAULT_CONFIG:
        raise ValueError("Unknown step")
    if agent not in AGENT_CLI:
        raise ValueError("Unknown agent")
    if len(authorization.strip()) < 12:
        raise ValueError("Provide the user's explicit authorization text (at least 12 characters)")
    path = _binding_lock_path(); data = load_binding_lock(path)
    data["bindings"][step] = agent
    data.setdefault("authorization_log", []).append({
        "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "step": step,
        "agent": agent, "authorization": authorization.strip(),
    })
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)
    return data


def load_config(path: Path | None = None) -> HarnessConfig:
    """Load the configuration model and retain legacy root-level step overrides."""
    source = path or _config_path()
    override = _load_user_config(source)
    legacy_steps = {name: value for name, value in override.items() if name in DEFAULT_CONFIG}
    legacy_defaults = override.pop("all", {})
    for name in legacy_steps:
        override.pop(name)
    agents = _deep_merge(AGENT_CLI, override.get("agents", {}))
    steps = _deep_merge(DEFAULT_CONFIG, override.get("steps", {}))
    steps = _deep_merge(steps, legacy_steps)
    defaults = _deep_merge({"timeout_seconds": 180}, override.get("defaults", {}))
    defaults = _deep_merge(defaults, legacy_defaults)
    config = HarnessConfig(defaults=defaults, agents=agents, steps=steps, source=source)
    for name, agent in config.agents.items():
        if not isinstance(agent, dict) or not isinstance(agent.get("executable"), str) or not isinstance(agent.get("args_base", []), list):
            raise ValueError(f"Agent '{name}' must define string executable and list args_base.")
    for name, step in config.steps.items():
        if not isinstance(step, dict) or step.get("agent") not in config.agents:
            raise ValueError(f"Step '{name}' must reference a configured agent.")
    lock = load_binding_lock()
    for name, agent in lock["bindings"].items():
        if config.steps[name].get("agent") != agent:
            raise ValueError(
                f"Binding lock violation for {name}: configured '{config.steps[name].get('agent')}', locked '{agent}'. "
                "Use --authorize-binding-change with the user's explicit authorization."
            )
    return config


def _load_user_config(config_path: Path | None = None) -> dict[str, Any]:
    """Read YAML, with JSON as the dependency-free fallback."""
    config_path = config_path or _config_path()
    if not config_path.is_file():
        return {}
    try:
        import yaml
        loaded = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    except ImportError:
        loaded = json.loads(config_path.read_text(encoding="utf-8"))
    if loaded is None:
        return {}
    if not isinstance(loaded, dict):
        raise ValueError(f"Configuration root must be a mapping: {config_path}")
    return loaded


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
    """Compatibility wrapper for callers importing the old helper."""
    return load_config().step(step)


@dataclass
class CliRunResult:
    step: str; agent: str; command: list; started_at: str; finished_at: str
    duration_ms: int; exit_code: int; stdout_path: str; stderr_path: str
    evidence_path: str; output_sha256: str; success: bool
    failure_reason: str | None = None; agent_message: str | None = None


def run_cli(*, step: str, task_id: str, workspace: Path, prompt: str,
            timeout_seconds: int | None = None) -> CliRunResult:
    config = load_config()
    cfg = config.step(step)
    agent = cfg["agent"]
    exe = config.resolve_executable(agent)
    if not exe:
        return CliRunResult(step=step, agent=agent, command=[agent], started_at="",
            finished_at="", duration_ms=0, exit_code=-1, stdout_path="",
            stderr_path="", evidence_path="", output_sha256="", success=False,
            failure_reason=f"CLI '{agent}' not found. Install or override in ~/.hermes/harness-config.yaml")
    cli_info = config.agent(agent)
    args_base = list(cli_info["args_base"])
    if step == "step3":
        for arg in cli_info.get("step3_remove_args", []):
            args_base = [x for x in args_base if x != arg]
    for arg in cli_info.get('args_extra', []):
        args_base.append(arg)
    use_stdin = bool(cfg.get("use_stdin", False))
    cmd = [exe] + args_base + ([] if use_stdin else [prompt])
    d = Path.home() / ".hermes" / "harness-workspace" / task_id / step
    d.mkdir(parents=True, exist_ok=True)
    stdout_p, stderr_p, ev_p = d/"stdout.jsonl", d/"stderr.txt", d/"evidence.json"
    (d/"prompt.txt").write_text(prompt, encoding="utf-8")
    t = timeout_seconds or cfg.get("timeout_seconds", 180)
    s0 = time.monotonic(); sa = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    try:
        # On Windows, npm-installed CLIs are commonly .cmd/.bat wrappers.
        # They must be launched through cmd.exe rather than CreateProcess.
        use_shell = sys.platform == "win32" and Path(exe).suffix.lower() in {".cmd", ".bat"}
        r = subprocess.run(cmd, cwd=str(workspace),
            input=prompt if cfg.get("use_stdin") else None,
            stdin=None if cfg.get("use_stdin") else subprocess.DEVNULL,
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            timeout=t, shell=use_shell)
        ec, so, se = r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired as e:
        # Keep partial output: it is evidence for diagnosing whether a timeout is
        # caused by model work, a stalled CLI, or a prompt that needs splitting.
        def as_text(value: Any) -> str:
            if value is None:
                return ""
            return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else str(value)
        ec, so = -2, as_text(e.stdout)
        se = f"Timeout {t}s" + ("\n" + as_text(e.stderr) if e.stderr else "")
    except Exception as e:
        ec, so, se = -3, "", str(e)
    dm = int((time.monotonic()-s0)*1000); fa = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    stdout_p.write_text(so, encoding="utf-8"); stderr_p.write_text(se, encoding="utf-8")
    h = hashlib.sha256(so.encode()).hexdigest()
    am = None
    output_parse = cli_info.get("output_parse", "plain")
    if output_parse == "json_lines":
        for ln in so.split("\n"):
            if not ln.strip(): continue
            try:
                d2 = json.loads(ln)
                if d2.get("type")=="item.completed" and d2.get("item",{}).get("type")=="agent_message":
                    am = d2["item"].get("text","")
            except: pass
    else:
        am = so.strip()
    ok = ec == 0 and bool(so.strip())
    fr = (f"Timeout after {t}s" if ec == -2 else f"Exit code: {ec}") if ec != 0 else ("Empty stdout" if not so.strip() else None)
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
    stdout_path = ev.get("stdout_path")
    expected_hash = ev.get("output_sha256")
    if not isinstance(stdout_path, str) or not stdout_path:
        return False, "Missing: stdout_path"
    if not isinstance(expected_hash, str) or not expected_hash:
        return False, "Missing: output_sha256"
    try:
        output = Path(stdout_path).read_bytes()
    except OSError as error:
        return False, f"Cannot read stdout: {error}"
    if hashlib.sha256(output).hexdigest() != expected_hash:
        return False, "stdout SHA-256 does not match evidence"
    return True, "OK"


def print_config():
    config = load_config()
    print("=== harness-4step CLI Configuration ===")
    print(f"Config file: {config.source}")
    print()
    for step in config.steps:
        cfg = config.step(step)
        exe = config.resolve_executable(cfg["agent"])
        status = "OK" if exe else "NOT FOUND"
        print(f"  {step}: agent={cfg['agent']}, timeout={cfg.get('timeout_seconds')}s, exe={exe or 'N/A'} ({status})")
    print()
    print("Use 'agents', 'steps', and 'defaults' in harness-config.yaml; legacy root step overrides also work.")


def print_step_report(result: CliRunResult, task_id: str, todo_id: str, queue_item: dict[str, Any] | None) -> None:
    """Always emit a machine-readable and human-visible report for every step."""
    report = {
        "type": "harness_step_report", "task_id": task_id,
        "todo_id": todo_id, "step": result.step, "agent": result.agent,
        "exit_code": result.exit_code, "success": result.success,
        "duration_ms": result.duration_ms, "evidence_path": result.evidence_path,
        "failure_reason": result.failure_reason,
        "next_step": queue_item.get("next_step") if queue_item else None,
        "split_required": bool(queue_item and queue_item.get("split_required")),
    }
    print("\n=== Harness Step Report ===")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    p = argparse.ArgumentParser(description="4-step harness CLI executor")
    p.add_argument("--step", help="Configured step name")
    p.add_argument("--task-id"); p.add_argument("--todo-id"); p.add_argument("--workspace")
    p.add_argument("--prompt"); p.add_argument("--prompt-file")
    p.add_argument("--timeout", type=int)
    p.add_argument("--verify-only", action="store_true")
    p.add_argument("--show-config", action="store_true")
    p.add_argument("--show-bindings", action="store_true")
    p.add_argument("--authorize-binding-change", metavar="STEP")
    p.add_argument("--agent", metavar="AGENT")
    p.add_argument("--authorization", metavar="USER_TEXT")
    p.add_argument("--todo-init", metavar="TITLE")
    p.add_argument("--todo-add", metavar="ITEM_JSON")
    p.add_argument("--todo-add-file", metavar="ITEM_JSON_FILE")
    p.add_argument("--todo-split", metavar="PARENT_ID")
    p.add_argument("--todo-children", metavar="CHILDREN_JSON")
    p.add_argument("--todo-children-file", metavar="CHILDREN_JSON_FILE")
    p.add_argument("--todo-reason", default="")
    p.add_argument("--todo-next", action="store_true")
    p.add_argument("--todo-finish", metavar="ITEM_ID")
    p.add_argument("--todo-state", choices=["completed", "blocked"])
    p.add_argument("--todo-note", default="")
    p.add_argument("--todo-list", action="store_true")
    a = p.parse_args()
    if a.show_config:
        print_config(); sys.exit(0)
    if a.show_bindings:
        print(json.dumps(load_binding_lock(), ensure_ascii=False, indent=2)); sys.exit(0)
    if a.authorize_binding_change:
        if not a.agent or not a.authorization:
            p.error("--agent and --authorization are required with --authorize-binding-change")
        try:
            print(json.dumps(authorize_binding_change(a.authorize_binding_change, a.agent, a.authorization), ensure_ascii=False, indent=2))
        except ValueError as e:
            print(json.dumps({"success": False, "error": str(e)}, ensure_ascii=False)); sys.exit(1)
        sys.exit(0)
    todo_action = any([a.todo_init, a.todo_add, a.todo_add_file, a.todo_split, a.todo_next, a.todo_finish, a.todo_list])
    if todo_action:
        if not a.task_id:
            p.error("--task-id is required for to-do operations")
        try:
            if a.todo_init:
                output = todo_initialize(a.task_id, a.todo_init)
            elif a.todo_add or a.todo_add_file:
                if a.todo_add and a.todo_add_file:
                    p.error("Use only one of --todo-add or --todo-add-file")
                item_json = Path(a.todo_add_file).read_text(encoding="utf-8") if a.todo_add_file else a.todo_add
                output = todo_add(a.task_id, json.loads(item_json))
            elif a.todo_split:
                if bool(a.todo_children) == bool(a.todo_children_file):
                    p.error("Provide exactly one of --todo-children or --todo-children-file with --todo-split")
                children_json = Path(a.todo_children_file).read_text(encoding="utf-8") if a.todo_children_file else a.todo_children
                output = todo_split(a.task_id, a.todo_split, json.loads(children_json), a.todo_reason)
            elif a.todo_next:
                output = todo_next(a.task_id)
            elif a.todo_finish:
                if not a.todo_state:
                    p.error("--todo-state is required with --todo-finish")
                output = todo_finish(a.task_id, a.todo_finish, a.todo_state, a.todo_note)
            else:
                output = todo_summary(a.task_id)
        except (ValueError, FileNotFoundError, json.JSONDecodeError) as e:
            print(json.dumps({"success": False, "error": str(e)}, ensure_ascii=False)); sys.exit(1)
        print(json.dumps({"success": True, "result": output}, ensure_ascii=False, indent=2)); sys.exit(0)
    if not a.step or not a.task_id or not a.todo_id or not a.workspace:
        p.error("--step, --task-id, --todo-id, --workspace required (or --show-config)")
    ws = Path(a.workspace)
    if not ws.is_dir(): print(f"Error: {ws}", file=sys.stderr); sys.exit(1)
    if a.verify_only:
        ev = Path.home()/".hermes"/"harness-workspace"/a.task_id/a.step/"evidence.json"
        ok, msg = verify_evidence(ev)
        print(json.dumps({"success":ok,"message":msg})); sys.exit(0 if ok else 1)
    prompt = Path(a.prompt_file).read_text(encoding="utf-8") if a.prompt_file else (a.prompt or "")
    if not prompt: print("Need --prompt or --prompt-file", file=sys.stderr); sys.exit(1)
    try:
        todo_begin_step(a.task_id, a.todo_id, a.step)
    except (ValueError, FileNotFoundError) as e:
        print(json.dumps({"type": "harness_step_report", "success": False, "step": a.step,
                          "todo_id": a.todo_id, "failure_reason": str(e)}, ensure_ascii=False, indent=2))
        sys.exit(1)
    r = run_cli(step=a.step, task_id=a.task_id, workspace=ws, prompt=prompt, timeout_seconds=a.timeout)
    queue_item = todo_record_step(a.task_id, a.todo_id, a.step, r.success, r.evidence_path)
    # Print CLI invocation info for transparency
    print(f"\n{'='*60}")
    print(f"CLI Invoked: {r.agent.upper()}")
    print(f"Step: {r.step}")
    print(f"Command: {' '.join(r.command[:3])}...")
    print(f"{'='*60}\n")
    print(json.dumps(asdict(r), ensure_ascii=False, indent=2))
    print_step_report(r, a.task_id, a.todo_id, queue_item)
    sys.exit(0 if r.success else 1)
