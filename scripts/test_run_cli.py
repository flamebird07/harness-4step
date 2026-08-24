import json
import os
import tempfile
import unittest
from pathlib import Path

import run_cli


def binding_lock(bindings: dict[str, str] | None = None) -> dict:
    """A declarative lock; tests must not rely on code-owned CLI families."""
    return {
        "schema_version": 2,
        "locked": True,
        "backends": {
            "codex": {"family": "openai"},
            "claude": {"family": "anthropic"},
            "mimo": {"family": "xiaomi"},
            "kimi": {"family": "moonshot"},
        },
        "bindings": bindings or {
            "step1": "codex", "step2": "claude", "step3": "claude", "step4": "kimi",
        },
        "constraints": {"step4_must_differ_from_step3_family": True},
    }

class BindingLockTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.config = Path(self.temp.name) / "config.json"
        self.lock = Path(self.temp.name) / "binding-lock.json"
        self.old_config = os.environ.get("HERMES_HARNESS_CONFIG")
        self.old_lock = os.environ.get("HERMES_BINDING_LOCK")
        os.environ["HERMES_HARNESS_CONFIG"] = str(self.config)
        os.environ["HERMES_BINDING_LOCK"] = str(self.lock)
        self.lock.write_text(json.dumps(binding_lock()), encoding="utf-8")

    def tearDown(self):
        if self.old_config is None:
            os.environ.pop("HERMES_HARNESS_CONFIG", None)
        else:
            os.environ["HERMES_HARNESS_CONFIG"] = self.old_config
        if self.old_lock is None:
            os.environ.pop("HERMES_BINDING_LOCK", None)
        else:
            os.environ["HERMES_BINDING_LOCK"] = self.old_lock
        self.temp.cleanup()

    def test_matching_locked_bindings_load(self):
        self.config.write_text("{}", encoding="utf-8")
        cfg = run_cli.load_config()
        lock = json.loads(self.lock.read_text(encoding="utf-8"))
        for step_name, expected_agent in lock["bindings"].items():
            self.assertEqual(cfg.step(step_name)["agent"], expected_agent)

    def test_unapproved_binding_override_is_rejected(self):
        self.config.write_text(json.dumps({"steps": {"step1": {"agent": "kimi"}}}), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "Binding lock violation"):
            run_cli.load_config()

    def test_authorized_change_requires_meaningful_text_and_is_audited(self):
        with self.assertRaisesRegex(ValueError, "explicit authorization"):
            run_cli.authorize_binding_change("step1", "kimi", "short")
        changed = run_cli.authorize_binding_change("step1", "kimi", "用户明确授权 Step 1 改用 Kimi CLI")
        self.assertEqual(changed["bindings"]["step1"], "kimi")
        self.assertEqual(len(changed["authorization_log"]), 1)

    def test_same_family_step3_and_step4_is_rejected_from_configuration(self):
        invalid = binding_lock({
            "step1": "codex", "step2": "codex", "step3": "codex", "step4": "codex",
        })
        self.lock.write_text(json.dumps(invalid), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "both use model family 'openai'"):
            run_cli.load_binding_lock(self.lock)

    def test_custom_backend_is_accepted_when_declared_in_lock(self):
        custom = binding_lock({
            "step1": "local-review", "step2": "local-review", "step3": "local-build", "step4": "local-review",
        })
        custom["backends"] = {
            "local-review": {"family": "review-model"},
            "local-build": {"family": "build-model"},
        }
        self.lock.write_text(json.dumps(custom), encoding="utf-8")
        self.assertEqual(run_cli.load_binding_lock(self.lock)["bindings"]["step4"], "local-review")


class MissingLockTests(unittest.TestCase):
    """When binding-lock.json is absent, load_config() must not crash
    but run_cli() must fail-closed with a clear message."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.config = Path(self.temp.name) / "config.json"
        self.lock = Path(self.temp.name) / "binding-lock.json"
        self.old_config = os.environ.get("HERMES_HARNESS_CONFIG")
        self.old_lock = os.environ.get("HERMES_BINDING_LOCK")
        os.environ["HERMES_HARNESS_CONFIG"] = str(self.config)
        os.environ["HERMES_BINDING_LOCK"] = str(self.lock)
        self.config.write_text("{}", encoding="utf-8")
        # lock file deliberately NOT written

    def tearDown(self):
        if self.old_config is None:
            os.environ.pop("HERMES_HARNESS_CONFIG", None)
        else:
            os.environ["HERMES_HARNESS_CONFIG"] = self.old_config
        if self.old_lock is None:
            os.environ.pop("HERMES_BINDING_LOCK", None)
        else:
            os.environ["HERMES_BINDING_LOCK"] = self.old_lock
        self.temp.cleanup()

    def test_load_config_succeeds_without_lock(self):
        cfg = run_cli.load_config()
        for step_name in ("step1", "step2", "step3", "step4"):
            self.assertIsNone(cfg.step(step_name).get("agent"))

    def test_run_cli_fails_without_lock(self):
        result = run_cli.run_cli(
            step="step1", task_id="t-missing", workspace=Path(self.temp.name),
            prompt="test", timeout_seconds=10)
        self.assertFalse(result.success)
        self.assertIn("No agent bound", result.failure_reason)


class Step4StaticReviewPrefixTests(unittest.TestCase):
    def setUp(self):
        # run_cli writes prompt.txt under Path.home()/.hermes/harness-workspace.
        # On Windows Path.home() uses USERPROFILE, not HOME, so locate it there.
        self.temp = tempfile.TemporaryDirectory()
        self.old_profile = os.environ.get("USERPROFILE")
        os.environ["USERPROFILE"] = self.temp.name
        self.addCleanup(self._restore_profile)
        # Provide a valid binding lock / config so load_config() succeeds.
        self.lock = Path(self.temp.name) / "binding-lock.json"
        self.config = Path(self.temp.name) / "config.json"
        self.old_lock = os.environ.get("HERMES_BINDING_LOCK")
        self.old_config = os.environ.get("HERMES_HARNESS_CONFIG")
        os.environ["HERMES_BINDING_LOCK"] = str(self.lock)
        os.environ["HERMES_HARNESS_CONFIG"] = str(self.config)
        self.lock.write_text(json.dumps(binding_lock()), encoding="utf-8")
        self.config.write_text("{}", encoding="utf-8")
        self.addCleanup(self._restore_env)

    def _restore_env(self):
        for key, old in (("HERMES_BINDING_LOCK", self.old_lock), ("HERMES_HARNESS_CONFIG", self.old_config)):
            if old is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = old

    def _restore_profile(self):
        if self.old_profile is None:
            os.environ.pop("USERPROFILE", None)
        else:
            os.environ["USERPROFILE"] = self.old_profile

    def _run(self, step, prompt):
        # Fakes without shelling out to a real CLI: resolve the executable to a
        # plain path (not .cmd/.bat, so no cmd.exe shell) and stub subprocess.run.
        original_resolve = run_cli.HarnessConfig.resolve_executable
        run_cli.HarnessConfig.resolve_executable = lambda self, agent: "fakecli"
        self.addCleanup(lambda: setattr(run_cli.HarnessConfig, "resolve_executable", original_resolve))
        original_run = run_cli.subprocess.run
        run_cli.subprocess.run = lambda *a, **k: type("F", (), {"returncode": 0, "stdout": "ok", "stderr": ""})()
        self.addCleanup(lambda: setattr(run_cli.subprocess, "run", original_run))
        return run_cli.run_cli(
            step=step, task_id="t1", workspace=Path(self.temp.name),
            prompt=prompt, timeout_seconds=30)

    def test_step4_prefixes_prompt_with_static_readonly_instruction(self):
        self.lock.write_text(json.dumps(binding_lock({
            "step1": "claude", "step2": "claude", "step3": "claude", "step4": "codex",
        })), encoding="utf-8")
        result = self._run("step4", "Review the diff.")
        prompt_path = Path(self.temp.name) / ".hermes" / "harness-workspace" / "t1" / "step4" / "prompt.txt"
        prompt = prompt_path.read_text(encoding="utf-8")
        self.assertTrue(prompt.startswith(
            "IMPORTANT: This is a static read-only review. "
            "You may read the listed files and run strictly non-mutating inspection commands. "
            "Do NOT execute tests, builds, installs, or any command that writes files. "
            "Do NOT treat missing tools as failure."))
        self.assertTrue(prompt.endswith("\n\nReview the diff."))
        self.assertTrue(result.success)
        sandbox_index = result.command.index("--sandbox")
        self.assertEqual(result.command[sandbox_index + 1], "read-only")

    def test_non_step4_is_not_prefixed(self):
        result = self._run("step1", "Hello.")
        prompt_path = Path(self.temp.name) / ".hermes" / "harness-workspace" / "t1" / "step1" / "prompt.txt"
        self.assertEqual(prompt_path.read_text(encoding="utf-8"), "Hello.")
        self.assertTrue(result.success)

    def test_step3_has_prefix(self):
        result = self._run("step3", "Implement the fix.")
        prompt_path = Path(self.temp.name) / ".hermes" / "harness-workspace" / "t1" / "step3" / "prompt.txt"
        prompt = prompt_path.read_text(encoding="utf-8")
        self.assertIn("Step 3 implementation", prompt)
        self.assertTrue(prompt.endswith("\n\nImplement the fix."))
        self.assertTrue(result.success)

    def test_step4_has_prefix(self):
        result = self._run("step4", "Review the diff.")
        prompt_path = Path(self.temp.name) / ".hermes" / "harness-workspace" / "t1" / "step4" / "prompt.txt"
        prompt = prompt_path.read_text(encoding="utf-8")
        self.assertIn("static read-only review", prompt)
        self.assertTrue(result.success)

    def test_step1_no_prefix(self):
        result = self._run("step1", "Analyze.")
        prompt_path = Path(self.temp.name) / ".hermes" / "harness-workspace" / "t1" / "step1" / "prompt.txt"
        self.assertEqual(prompt_path.read_text(encoding="utf-8"), "Analyze.")
        self.assertTrue(result.success)

    def test_step2_no_prefix(self):
        result = self._run("step2", "Plan.")
        prompt_path = Path(self.temp.name) / ".hermes" / "harness-workspace" / "t1" / "step2" / "prompt.txt"
        self.assertEqual(prompt_path.read_text(encoding="utf-8"), "Plan.")
        self.assertTrue(result.success)


class MimoPromptModeTests(unittest.TestCase):
    """mimo must pass the prompt via -f prompt.txt (prompt_mode=file) and must
    not use stdin (use_stdin=false), which mimo does not support and would hang."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.old_profile = os.environ.get("USERPROFILE")
        os.environ["USERPROFILE"] = self.temp.name
        self.addCleanup(self._restore_profile)
        self.lock = Path(self.temp.name) / "binding-lock.json"
        self.config = Path(self.temp.name) / "config.json"
        self.old_lock = os.environ.get("HERMES_BINDING_LOCK")
        self.old_config = os.environ.get("HERMES_HARNESS_CONFIG")
        os.environ["HERMES_BINDING_LOCK"] = str(self.lock)
        os.environ["HERMES_HARNESS_CONFIG"] = str(self.config)
        self.addCleanup(self._restore_env)
        self.config.write_text("{}", encoding="utf-8")

    def _restore_env(self):
        for key, old in (("HERMES_BINDING_LOCK", self.old_lock), ("HERMES_HARNESS_CONFIG", self.old_config)):
            if old is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = old

    def _restore_profile(self):
        if self.old_profile is None:
            os.environ.pop("USERPROFILE", None)
        else:
            os.environ["USERPROFILE"] = self.old_profile

    def _bind_mimo_to_step3(self):
        self.lock.write_text(json.dumps(binding_lock({
            "step1": "codex", "step2": "claude", "step3": "mimo", "step4": "kimi",
        })), encoding="utf-8")

    def _run_capturing(self, prompt):
        self._bind_mimo_to_step3()
        original_resolve = run_cli.HarnessConfig.resolve_executable
        run_cli.HarnessConfig.resolve_executable = lambda self, agent: "fakecli"
        self.addCleanup(lambda: setattr(run_cli.HarnessConfig, "resolve_executable", original_resolve))
        captured = {}
        original_run = run_cli.subprocess.run

        def fake_run(cmd, **kw):
            captured["cmd"] = cmd
            captured["input"] = kw.get("input")
            captured["stdin"] = kw.get("stdin")
            return type("F", (), {"returncode": 0, "stdout": "ok", "stderr": ""})()

        run_cli.subprocess.run = fake_run
        self.addCleanup(lambda: setattr(run_cli.subprocess, "run", original_run))
        result = run_cli.run_cli(
            step="step3", task_id="t-mimo", workspace=Path(self.temp.name),
            prompt=prompt, timeout_seconds=30)
        return result, captured

    def test_mimo_prompt_is_sent_via_stdin(self):
        long_prompt = "A long prompt that must not be truncated. " * 2000
        result, captured = self._run_capturing(long_prompt)
        self.assertTrue(result.success)
        cmd_strs = [str(c) for c in captured["cmd"]]
        # mimo -f is an attachment flag, not a message flag.  Prompts must use stdin.
        self.assertNotIn("-f", cmd_strs)
        self.assertFalse(any(c.endswith("prompt.txt") for c in cmd_strs))
        self.assertNotIn("A long prompt", cmd_strs)
        self.assertIn(long_prompt, captured["input"])
        self.assertIsNone(captured["stdin"])

    def test_mimo_use_stdin_true(self):
        self.assertTrue(run_cli.load_config().agent("mimo").get("use_stdin"))
        result, captured = self._run_capturing("Implement the fix.")
        self.assertTrue(result.success)
        self.assertIn("Implement the fix.", captured["input"])
        self.assertIsNone(captured["stdin"])


class OverrideAuthorizationTests(unittest.TestCase):
    def test_library_override_requires_explicit_authorization(self):
        """Direct callers must not turn a CLI failure into an unapproved fallback."""
        with tempfile.TemporaryDirectory() as tmp:
            result = run_cli.run_cli(
                step="step1", task_id="no-fallback", workspace=Path(tmp),
                prompt="Review this.", agent_override="mimo",
            )
        self.assertFalse(result.success)
        self.assertEqual(-1, result.exit_code)
        self.assertIn("explicit user authorization", result.failure_reason)

if __name__ == "__main__":
    unittest.main()
