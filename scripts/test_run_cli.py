import json
import os
import tempfile
import unittest
from pathlib import Path

import run_cli


class BindingLockTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.config = Path(self.temp.name) / "config.json"
        self.lock = Path(self.temp.name) / "binding-lock.json"
        self.old_config = os.environ.get("HERMES_HARNESS_CONFIG")
        self.old_lock = os.environ.get("HERMES_BINDING_LOCK")
        os.environ["HERMES_HARNESS_CONFIG"] = str(self.config)
        os.environ["HERMES_BINDING_LOCK"] = str(self.lock)
        self.lock.write_text(json.dumps({"schema_version": 1, "locked": True, "bindings": {
            "step1": "codex", "step2": "codex", "step3": "codex", "step4": "kimi"
        }}), encoding="utf-8")

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
        self.assertEqual(run_cli.load_config().step("step3")["agent"], "codex")

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


if __name__ == "__main__":
    unittest.main()
