"""four-step-enforcer — Harness 4-Step enforcement plugin.

Enforces the "4-step harness" rule at the tool-call level:
  1. When delegate_task completes successfully → mark Step 1 as done for this session
  2. When write_file/patch is invoked → block unless delegate_task was completed first

This replaces the old skill-only approach (which LLMs could ignore) with
a hard technical gate that blocks tool calls at the infrastructure level.

Architecture:
  - pre_tool_call hook: intercepts write_file/patch, checks state, blocks or allows
  - post_tool_call hook: observes delegate_task success → marks step1_done
  - on_session_start/end: lifecycle hooks for cleanup
  - State: in-memory dict keyed by session_id with TTL-based expiry

Session identification:
  - Primary key: session_id (from hook kwargs)
  - Fallback: task_id (when session_id is empty)
  - Both None/empty → bypass enforcement (no "global" key)

Exemptions (checked in order):
  1. Plugin disabled via config
  2. Tool not in target list (write_file, patch, skill_manage)
  3. No session identifier available → bypass (degraded mode)
  4. delegate_task already completed successfully (step1_done)
  5. Explicit exemption via config (exempt_tools, exempt_goal_patterns)

Memory management:
  - TTL: 30 minutes (configurable via config.ttl_minutes)
  - Max sessions: 200 (configurable via config.max_sessions)
  - Prune every 30 seconds (time-based, not hash-based)
"""

from __future__ import annotations

import logging
import os
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Set

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

_DEFAULT_TTL_MINUTES = 30
_DEFAULT_MAX_SESSIONS = 200
_DEFAULT_PRUNE_INTERVAL_SECONDS = 30

# Tools that are blocked until Step 1 (delegate_task) is completed.
# skill_manage is included because write_file/patch sub-actions modify code.
_BLOCKED_TOOLS: Set[str] = {"write_file", "patch", "skill_manage"}


# ---------------------------------------------------------------------------
# State management
# ---------------------------------------------------------------------------

@dataclass
class SessionState:
    """Per-session harness enforcement state."""
    step1_done: bool = False
    step1_tool_name: str = ""          # which tool completed Step 1
    last_activity: float = field(default_factory=time.time)
    delegate_count: int = 0            # total delegates in this session
    blocked_count: int = 0             # total blocks in this session

# Module-level state store. Keyed by session_id (or task_id fallback).
_session_states: Dict[str, SessionState] = {}

# Configuration cache (loaded from plugin.yaml at init time)
_config: Dict[str, Any] = {}
_config_loaded = False

# Time-based pruning state
_last_prune_time: float = 0.0


def _load_config(ctx: Any) -> Dict[str, Any]:
    """Load plugin configuration from the plugin context."""
    global _config, _config_loaded
    if _config_loaded:
        return _config
    try:
        # Try to get config from the plugin context
        if hasattr(ctx, '_manager') and hasattr(ctx._manager, '_manifest'):
            manifest = ctx._manager._manifest
            if hasattr(manifest, 'config') and manifest.config:
                _config.update(manifest.config)
                _config_loaded = True
                return _config
    except Exception:
        pass
    # Fallback to defaults + env vars
    _config.update({
        "enabled": os.environ.get("FOUR_STEP_ENFORCER_ENABLED", "1").lower() in {"1", "true", "yes", "on"},
        "ttl_minutes": int(os.environ.get("FOUR_STEP_ENFORCER_TTL", str(_DEFAULT_TTL_MINUTES))),
        "max_sessions": int(os.environ.get("FOUR_STEP_ENFORCER_MAX_SESSIONS", str(_DEFAULT_MAX_SESSIONS))),
        "exempt_tools": [],
        "exempt_goal_patterns": [],
    })
    _config_loaded = True
    return _config


def _is_enabled() -> bool:
    """Check if the plugin is enabled."""
    return _config.get("enabled", True)


def _get_ttl_seconds() -> int:
    """Get TTL in seconds."""
    return _config.get("ttl_minutes", _DEFAULT_TTL_MINUTES) * 60


def _get_max_sessions() -> int:
    """Get max session limit."""
    return _config.get("max_sessions", _DEFAULT_MAX_SESSIONS)


def _get_exempt_tools() -> Set[str]:
    """Get exempt tools from config."""
    return set(_config.get("exempt_tools", []))


def _get_exempt_goal_patterns() -> List[str]:
    """Get exempt goal patterns from config."""
    return _config.get("exempt_goal_patterns", [])


# ---------------------------------------------------------------------------
# Session key resolution
# ---------------------------------------------------------------------------

def _resolve_session_key(
    session_id: str,
    task_id: str,
    args: Any,
) -> Optional[str]:
    """Resolve the session key from available identifiers.

    Priority: session_id > task_id > None (bypass)

    When both session_id and task_id are empty, returns None to indicate
    that enforcement should be bypassed (no cross-session pollution).
    """
    if session_id and session_id.strip():
        return session_id.strip()
    if task_id and task_id.strip():
        return f"task:{task_id.strip()}"
    return None  # No identifier available → bypass enforcement


# ---------------------------------------------------------------------------
# State cleanup (TTL + max limit, time-based)
# ---------------------------------------------------------------------------

def _prune_states() -> None:
    """Remove expired entries and enforce max session limit."""
    now = time.time()
    ttl = _get_ttl_seconds()
    max_sessions = _get_max_sessions()

    # Remove expired entries
    expired = [
        key for key, state in _session_states.items()
        if now - state.last_activity > ttl
    ]
    for key in expired:
        del _session_states[key]

    # Enforce max limit (remove oldest first)
    if len(_session_states) > max_sessions:
        sorted_keys = sorted(
            _session_states.keys(),
            key=lambda k: _session_states[k].last_activity
        )
        to_remove = sorted_keys[:len(sorted_keys) - max_sessions]
        for key in to_remove:
            del _session_states[key]


def _maybe_prune() -> None:
    """Run pruning at most once per _DEFAULT_PRUNE_INTERVAL_SECONDS."""
    global _last_prune_time
    now = time.time()
    if now - _last_prune_time >= _DEFAULT_PRUNE_INTERVAL_SECONDS:
        _last_prune_time = now
        _prune_states()


# Background thread for independent periodic pruning
_prune_thread: Optional[threading.Thread] = None
_prune_stop_event = threading.Event()


def _prune_loop() -> None:
    """Background thread that runs _prune_states() every 30 seconds."""
    while not _prune_stop_event.is_set():
        _prune_stop_event.wait(timeout=_DEFAULT_PRUNE_INTERVAL_SECONDS)
        if _prune_stop_event.is_set():
            break
        try:
            _prune_states()
        except Exception:
            logger.debug("four-step-enforcer: prune loop error (ignored)", exc_info=True)


def _get_or_create_state(session_key: str) -> SessionState:
    """Get or create state for a session, with periodic cleanup."""
    _maybe_prune()

    if session_key not in _session_states:
        _session_states[session_key] = SessionState()

    state = _session_states[session_key]
    state.last_activity = time.time()
    return state


# ---------------------------------------------------------------------------
# Exemption checking
# ---------------------------------------------------------------------------

def _is_exempt(
    tool_name: str,
    args: Any,
    state: SessionState,
) -> bool:
    """Check if this tool call is exempt from enforcement.

    Exemptions (in priority order):
    1. Tool not in blocked set → exempt (not our concern)
    2. User-level config exemptions (exempt_tools, exempt_goal_patterns)
    """
    # 1. Tool not in blocked set
    if tool_name not in _BLOCKED_TOOLS:
        return True

    # 2. Config-level exemptions
    if tool_name in _get_exempt_tools():
        return True

    # 3. Goal pattern exemptions
    if isinstance(args, dict):
        goal = str(args.get("goal", "") or "")
        context = str(args.get("context", "") or "")
        for pattern in _get_exempt_goal_patterns():
            if pattern.lower() in goal.lower() or pattern.lower() in context.lower():
                return True

    return False


# ---------------------------------------------------------------------------
# Hook callbacks
# ---------------------------------------------------------------------------

def _on_pre_tool_call(
    tool_name: str = "",
    args: Any = None,
    task_id: str = "",
    session_id: str = "",
    tool_call_id: str = "",
    turn_id: str = "",
    api_request_id: str = "",
    **_: Any,
) -> Optional[Dict[str, str]]:
    """Pre-tool-call hook — the core enforcement logic.

    Flow:
    1. If plugin disabled → allow
    2. Resolve session key
    3. If no session identifier → bypass (no cross-session pollution)
    4. Get/create session state
    5. If tool is delegate_task → allow (success tracked in post_hook)
    6. If tool is write_file/patch → check Step 1 done, block or allow
    7. All other tools → allow
    """
    if not _is_enabled():
        return None

    # Resolve session key (handles None/empty session_id)
    session_key = _resolve_session_key(session_id, task_id, args)

    # FIX #2: When no session identifier available, bypass enforcement entirely
    # instead of using a "global" key that would cause cross-session pollution.
    if session_key is None:
        return None

    state = _get_or_create_state(session_key)

    # --- delegate_task: allow, success tracked in post_tool_call ---
    if tool_name == "delegate_task":
        return None  # Always allow delegate_task

    # --- write_file/patch: check Step 1 ---
    if tool_name in _BLOCKED_TOOLS:
        # Check exemptions
        if _is_exempt(tool_name, args, state):
            return None

        # Check if Step 1 has been completed
        if not state.step1_done:
            state.blocked_count += 1

            # Build a helpful error message
            blocked_tool = tool_name
            message = (
                f"🚫 BLOCKED by four-step-enforcer: "
                f"Cannot call '{blocked_tool}' before completing Step 1.\n\n"
                f"The 4-step harness requires that Hermes first delegates "
                f"analysis/planning via delegate_task before modifying any code.\n\n"
                f"To proceed:\n"
                f"1. Call delegate_task to delegate Step 1 (review/analysis)\n"
                f"2. Then retry this {blocked_tool} call\n\n"
                f"Session: {session_key[:16]}... | "
                f"Blocks so far: {state.blocked_count} | "
                f"Delegates so far: {state.delegate_count}\n\n"
                f"To exempt this tool: add it to four-step-enforcer config "
                f"exempt_tools, or set FOUR_STEP_ENFORCER_ENABLED=0"
            )

            logger.warning(
                "four-step-enforcer: BLOCKED %s for session %s "
                "(step1_done=%s, blocks=%d)",
                tool_name, session_key[:16], state.step1_done,
                state.blocked_count,
            )
            return {"action": "block", "message": message}

    return None


def _on_post_tool_call(
    tool_name: str = "",
    args: Any = None,
    result: Any = None,
    task_id: str = "",
    session_id: str = "",
    tool_call_id: str = "",
    turn_id: str = "",
    api_request_id: str = "",
    status: str = "",
    error_type: str = "",
    error_message: str = "",
    **_: Any,
) -> None:
    """Post-tool-call hook — tracks delegate_task success.

    FIX #1: Only mark step1_done=True when delegate_task succeeds
    (status indicates success, no error), not in pre_tool_call.
    This prevents marking step1_done before the tool actually executes.
    """
    if not _is_enabled():
        return

    if tool_name == "delegate_task":
        session_key = _resolve_session_key(session_id, task_id, args)
        if session_key is None:
            return  # No session identifier, nothing to track

        state = _get_or_create_state(session_key)
        state.delegate_count += 1

        # FIX #1: Only mark step1_done on successful completion
        # status must be explicitly "success"/"completed"/"ok" (not empty string)
        # AND error_message must be empty
        _success_statuses = ("success", "completed", "ok")
        is_success = (
            status in _success_statuses
            and not error_type
            and not (error_message and error_message.strip())
        )
        if is_success:
            state.step1_done = True
            state.step1_tool_name = "delegate_task"
            logger.info(
                "four-step-enforcer: Step 1 completed for session %s "
                "(delegate #%d, status=%s)",
                session_key[:16], state.delegate_count, status,
            )
        else:
            logger.debug(
                "four-step-enforcer: delegate_task did NOT mark step1_done "
                "for session %s (status=%s, error_type=%s)",
                session_key[:16], status, error_type,
            )


def _on_session_start(
    session_id: str = "",
    platform: str = "",
    model: str = "",
    **_: Any,
) -> None:
    """Session start hook — initialize state."""
    if not _is_enabled():
        return
    session_key = _resolve_session_key(session_id, "", None)
    if session_key is None:
        return
    state = _get_or_create_state(session_key)
    logger.debug(
        "four-step-enforcer: session started: %s (step1_done=%s)",
        session_key[:16], state.step1_done,
    )


def _on_session_end(
    session_id: str = "",
    **_: Any,
) -> None:
    """Session end hook — cleanup state."""
    if not _is_enabled():
        return
    session_key = _resolve_session_key(session_id, "", None)
    if session_key is None:
        return
    if session_key in _session_states:
        state = _session_states.pop(session_key)
        logger.debug(
            "four-step-enforcer: session ended: %s "
            "(delegates=%d, blocks=%d)",
            session_key[:16], state.delegate_count, state.blocked_count,
        )


# ---------------------------------------------------------------------------
# Plugin registration
# ---------------------------------------------------------------------------

def register(ctx) -> None:
    """Register the four-step-enforcer plugin hooks."""
    global _config, _config_loaded, _prune_thread, _prune_stop_event

    # Load config
    _load_config(ctx)

    # Register hooks
    ctx.register_hook("pre_tool_call", _on_pre_tool_call)
    ctx.register_hook("post_tool_call", _on_post_tool_call)
    ctx.register_hook("on_session_start", _on_session_start)
    ctx.register_hook("on_session_end", _on_session_end)

    # Start independent background pruning thread (FIX #2)
    _prune_stop_event.clear()
    if _prune_thread is None or not _prune_thread.is_alive():
        _prune_thread = threading.Thread(target=_prune_loop, daemon=True, name="four-step-prune")
        _prune_thread.start()

    enabled = _is_enabled()
    logger.info(
        "four-step-enforcer: registered (enabled=%s, ttl=%dm, max_sessions=%d)",
        enabled, _config.get("ttl_minutes", 30), _get_max_sessions(),
    )
