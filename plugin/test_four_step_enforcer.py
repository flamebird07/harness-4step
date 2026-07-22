#!/usr/bin/env python3
"""Test verification script for four-step-enforcer plugin.

Run with: python test_four_step_enforcer.py

Tests the plugin logic in isolation (no Hermes runtime needed).
Verifies all key behaviors described in the technical design.
"""

import os
import sys
import time

# ---------------------------------------------------------------------------
# Load the plugin module (hyphenated package name needs special handling)
# ---------------------------------------------------------------------------
PLUGIN_DIR = os.path.join(os.path.expanduser("~"), ".hermes", "plugins", "four-step-enforcer")
init_path = os.path.join(PLUGIN_DIR, "__init__.py")

with open(init_path, "r", encoding="utf-8") as f:
    code = f.read()

# Create a module namespace and register in sys.modules (needed for dataclass)
import types
mod = types.ModuleType("four_step_enforcer")
mod.__file__ = init_path
sys.modules["four_step_enforcer"] = mod
exec(compile(code, init_path, "exec"), mod.__dict__)

# Extract key functions/classes from the module
SessionState = mod.SessionState
_session_states = mod._session_states
_session_states.clear()  # Start fresh

_register = mod.register
_prune_states = mod._prune_states
_get_max_sessions = mod._get_max_sessions
_config = mod._config


# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

class MockCtx:
    """Mock plugin context for testing."""
    def __init__(self):
        self.hooks = {}
    
    def register_hook(self, name, callback):
        self.hooks.setdefault(name, []).append(callback)


def make_args(**kwargs):
    """Create tool args dict."""
    return kwargs


# ---------------------------------------------------------------------------
# Test 1: Plugin loads and registers hooks
# ---------------------------------------------------------------------------
def test_plugin_loads():
    print("Test 1: Plugin loads and registers hooks...")
    ctx = MockCtx()
    _register(ctx)
    assert "pre_tool_call" in ctx.hooks, "pre_tool_call hook not registered"
    assert "post_tool_call" in ctx.hooks, "post_tool_call hook not registered"
    assert "on_session_start" in ctx.hooks, "on_session_start hook not registered"
    assert "on_session_end" in ctx.hooks, "on_session_end hook not registered"
    print("  ✅ PASS: All hooks registered")
    return ctx


# ---------------------------------------------------------------------------
# Test 2: write_file blocked before delegate_task
# ---------------------------------------------------------------------------
def test_write_file_blocked_before_delegate(ctx):
    print("Test 2: write_file blocked before delegate_task...")
    hook = ctx.hooks["pre_tool_call"][0]
    
    _session_states.clear()
    
    result = hook(
        tool_name="write_file",
        args=make_args(path="test.js", content="console.log('hello')"),
        session_id="test-session-1",
        task_id="",
    )
    assert result is not None, "write_file should be blocked before delegate_task"
    assert result["action"] == "block", f"Expected block, got {result.get('action')}"
    assert "BLOCKED" in result["message"], "Block message should contain 'BLOCKED'"
    print("  ✅ PASS: write_file correctly blocked")


# ---------------------------------------------------------------------------
# Test 3: delegate_task marks step1_done (via post_tool_call)
# ---------------------------------------------------------------------------
def test_delegate_task_marks_step1(ctx):
    print("Test 3: delegate_task marks step1_done (via post_tool_call)...")
    post_hook = ctx.hooks["post_tool_call"][0]
    
    result = post_hook(
        tool_name="delegate_task",
        args=make_args(goal="审查代码中的问题", context="review findings"),
        session_id="test-session-1",
        task_id="",
        status="success",
        error_type="",
        error_message="",
    )
    # post_tool_call returns None always, but should have set state
    state = _session_states.get("test-session-1")
    assert state is not None, "Session state should exist"
    assert state.step1_done is True, "step1_done should be True after successful delegate_task"
    assert state.delegate_count == 1, f"delegate_count should be 1, got {state.delegate_count}"
    print("  ✅ PASS: delegate_task correctly marks step1_done")


# ---------------------------------------------------------------------------
# Test 4: write_file allowed after delegate_task
# ---------------------------------------------------------------------------
def test_write_file_allowed_after_delegate(ctx):
    print("Test 4: write_file allowed after delegate_task...")
    hook = ctx.hooks["pre_tool_call"][0]
    
    result = hook(
        tool_name="write_file",
        args=make_args(path="test.js", content="console.log('hello')"),
        session_id="test-session-1",
        task_id="",
    )
    assert result is None, f"write_file should be allowed after delegate_task, got {result}"
    print("  ✅ PASS: write_file correctly allowed after delegate_task")


# ---------------------------------------------------------------------------
# Test 5: patch blocked before delegate_task (new session)
# ---------------------------------------------------------------------------
def test_patch_blocked_before_delegate(ctx):
    print("Test 5: patch blocked before delegate_task (new session)...")
    hook = ctx.hooks["pre_tool_call"][0]
    
    result = hook(
        tool_name="patch",
        args=make_args(path="test.js", old_string="a", new_string="b"),
        session_id="test-session-2",
        task_id="",
    )
    assert result is not None, "patch should be blocked before delegate_task"
    assert result["action"] == "block", f"Expected block, got {result.get('action')}"
    print("  ✅ PASS: patch correctly blocked before delegate_task")


# ---------------------------------------------------------------------------
# Test 6: session isolation
# ---------------------------------------------------------------------------
def test_session_isolation(ctx):
    print("Test 6: Session isolation...")
    hook = ctx.hooks["pre_tool_call"][0]
    
    # session-2 has no delegate_task, should be blocked
    result = hook(
        tool_name="write_file",
        args=make_args(path="test.js", content="test"),
        session_id="test-session-2",
        task_id="",
    )
    assert result is not None, "session-2 should be blocked (no delegate_task)"
    
    # session-1 has delegate_task, should be allowed
    result = hook(
        tool_name="write_file",
        args=make_args(path="test.js", content="test"),
        session_id="test-session-1",
        task_id="",
    )
    assert result is None, "session-1 should be allowed (has delegate_task)"
    print("  ✅ PASS: Sessions are correctly isolated")


# ---------------------------------------------------------------------------
# Test 7: session_id=None fallback to task_id
# ---------------------------------------------------------------------------
def test_session_id_none_fallback(ctx):
    print("Test 7: session_id=None fallback to task_id...")
    pre_hook = ctx.hooks["pre_tool_call"][0]
    post_hook = ctx.hooks["post_tool_call"][0]
    
    _session_states.clear()
    
    # Try write_file with session_id=None, task_id set
    result = pre_hook(
        tool_name="write_file",
        args=make_args(path="test.js", content="test"),
        session_id="",
        task_id="task-123",
    )
    assert result is not None, "Should be blocked (no prior delegate with this task_id)"
    
    # Call delegate_task via post_tool_call with same task_id (simulates success)
    post_hook(
        tool_name="delegate_task",
        args=make_args(goal="review code"),
        session_id="",
        task_id="task-123",
        status="success",
        error_type="",
        error_message="",
    )
    
    # Now write_file with same task_id should be allowed
    result = pre_hook(
        tool_name="write_file",
        args=make_args(path="test.js", content="test"),
        session_id="",
        task_id="task-123",
    )
    assert result is None, "write_file should be allowed after delegate with same task_id"
    print("  ✅ PASS: session_id=None correctly falls back to task_id")


# ---------------------------------------------------------------------------
# Test 8: delegate_task with empty status does NOT mark step1_done
# ---------------------------------------------------------------------------
def test_delegate_empty_status_no_step1(ctx):
    print("Test 8: delegate_task with empty status does NOT mark step1_done...")
    post_hook = ctx.hooks["post_tool_call"][0]
    
    _session_states.clear()
    
    # delegate_task with empty status (not a success status)
    post_hook(
        tool_name="delegate_task",
        args=make_args(goal="review code"),
        session_id="test-session-empty",
        task_id="",
        status="",
        error_type="",
        error_message="",
    )
    state = _session_states.get("test-session-empty")
    assert state is not None, "Session state should exist"
    assert state.step1_done is False, "step1_done should be False with empty status"
    print("  ✅ PASS: Empty status correctly does NOT mark step1_done")


# ---------------------------------------------------------------------------
# Test 9: delegate_task with error does NOT mark step1_done
# ---------------------------------------------------------------------------
def test_delegate_error_no_step1(ctx):
    print("Test 9: delegate_task with error does NOT mark step1_done...")
    post_hook = ctx.hooks["post_tool_call"][0]
    
    _session_states.clear()
    
    # delegate_task with error
    post_hook(
        tool_name="delegate_task",
        args=make_args(goal="review code"),
        session_id="test-session-err",
        task_id="",
        status="success",
        error_type="RuntimeError",
        error_message="something went wrong",
    )
    state = _session_states.get("test-session-err")
    assert state is not None, "Session state should exist"
    assert state.step1_done is False, "step1_done should be False when error is present"
    print("  ✅ PASS: Error correctly does NOT mark step1_done")


# ---------------------------------------------------------------------------
# Test 10: other tools not affected
# ---------------------------------------------------------------------------
def test_other_tools_not_affected(ctx):
    print("Test 10: Other tools not affected...")
    hook = ctx.hooks["pre_tool_call"][0]
    
    _session_states.clear()
    
    for tool in ["terminal", "read_file", "search_files", "browser_navigate"]:
        result = hook(
            tool_name=tool,
            args=make_args(),
            session_id="test-session-other",
            task_id="",
        )
        assert result is None, f"{tool} should not be blocked, got {result}"
    print("  ✅ PASS: Other tools correctly unaffected")


# ---------------------------------------------------------------------------
# Test 11: TTL cleanup works
# ---------------------------------------------------------------------------
def test_ttl_cleanup(ctx):
    print("Test 11: TTL cleanup works...")
    
    _session_states.clear()
    
    # Create a session with old activity
    _session_states["old-session"] = SessionState(
        step1_done=True,
        last_activity=time.time() - 4000,  # 67 minutes ago
    )
    _session_states["new-session"] = SessionState(
        step1_done=True,
        last_activity=time.time(),
    )
    
    # Force cleanup
    _prune_states()
    
    assert "old-session" not in _session_states, "Old session should be pruned"
    assert "new-session" in _session_states, "New session should remain"
    print("  ✅ PASS: TTL cleanup correctly removes expired sessions")


# ---------------------------------------------------------------------------
# Test 12: max_sessions limit
# ---------------------------------------------------------------------------
def test_max_sessions_limit(ctx):
    print("Test 12: Max sessions limit...")
    
    _session_states.clear()
    original_max = _get_max_sessions()
    _config["max_sessions"] = 5
    
    # Create 8 sessions
    for i in range(8):
        _session_states[f"session-{i}"] = SessionState(
            last_activity=time.time() - (8 - i),  # oldest first
        )
    
    # Force cleanup
    _prune_states()
    
    assert len(_session_states) <= 5, f"Should have at most 5 sessions, got {len(_session_states)}"
    
    # Restore original
    _config["max_sessions"] = original_max
    print("  ✅ PASS: Max sessions limit correctly enforced")


# ---------------------------------------------------------------------------
# Test 13: disabled mode
# ---------------------------------------------------------------------------
def test_disabled_mode(ctx):
    print("Test 13: Disabled mode...")
    hook = ctx.hooks["pre_tool_call"][0]
    
    _session_states.clear()
    _config["enabled"] = False
    
    result = hook(
        tool_name="write_file",
        args=make_args(path="test.js", content="test"),
        session_id="test-disabled",
        task_id="",
    )
    assert result is None, "write_file should be allowed when plugin is disabled"
    
    _config["enabled"] = True
    print("  ✅ PASS: Disabled mode correctly allows all tools")


# ---------------------------------------------------------------------------
# Test 14: skill_manage blocked before delegate
# ---------------------------------------------------------------------------
def test_skill_manage_blocked(ctx):
    print("Test 14: skill_manage blocked before delegate...")
    hook = ctx.hooks["pre_tool_call"][0]
    
    _session_states.clear()
    
    result = hook(
        tool_name="skill_manage",
        args=make_args(action="create", name="test-skill", content="test"),
        session_id="test-session-sm",
        task_id="",
    )
    assert result is not None, "skill_manage should be blocked before delegate_task"
    assert result["action"] == "block"
    print("  ✅ PASS: skill_manage correctly blocked before delegate_task")


# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
def main():
    print("=" * 60)
    print("Four-Step Enforcer Plugin — Test Suite")
    print("=" * 60)
    print()
    
    ctx = test_plugin_loads()
    print()
    
    test_write_file_blocked_before_delegate(ctx)
    print()
    
    test_delegate_task_marks_step1(ctx)
    print()
    
    test_write_file_allowed_after_delegate(ctx)
    print()
    
    test_patch_blocked_before_delegate(ctx)
    print()
    
    test_session_isolation(ctx)
    print()
    
    test_session_id_none_fallback(ctx)
    print()
    
    test_delegate_empty_status_no_step1(ctx)
    print()
    
    test_delegate_error_no_step1(ctx)
    print()
    
    test_other_tools_not_affected(ctx)
    print()
    
    test_ttl_cleanup(ctx)
    print()
    
    test_max_sessions_limit(ctx)
    print()
    
    test_disabled_mode(ctx)
    print()
    
    test_skill_manage_blocked(ctx)
    print()
    
    print("=" * 60)
    print("All 14 tests PASSED ✅")
    print("=" * 60)
    print()
    print("Summary:")
    print("  - write_file/patch/skill_manage blocked before delegate_task")
    print("  - delegate_task marks step1_done (only with explicit success status)")
    print("  - Empty status or error does NOT mark step1_done")
    print("  - write_file/patch allowed after delegate_task")
    print("  - Sessions are isolated")
    print("  - session_id=None falls back to task_id")
    print("  - Other tools unaffected")
    print("  - TTL cleanup removes expired sessions")
    print("  - Max sessions limit enforced")
    print("  - Disabled mode allows all tools")


if __name__ == "__main__":
    main()
