import tempfile
import unittest
from pathlib import Path

import todo_queue


class TodoQueueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.original = todo_queue.queue_path
        todo_queue.queue_path = lambda _: Path(self.temp.name) / "todo.json"
        todo_queue.initialize("test-task", "Test")

    def tearDown(self):
        todo_queue.queue_path = self.original
        self.temp.cleanup()

    @staticmethod
    def item(item_id, files):
        return {"id": item_id, "title": item_id, "acceptance": f"{item_id} passes", "files": files}

    @staticmethod
    def complete_steps(item_id):
        for step in ("step1", "step2", "step3", "step4"):
            todo_queue.begin_step("test-task", item_id, step)
            todo_queue.record_step("test-task", item_id, step, True, f"{step}.json")

    def test_split_preserves_queue_and_requires_children_to_finish(self):
        todo_queue.add("test-task", self.item("parent", ["a.py", "b.py"]))
        self.assertEqual(todo_queue.next_item("test-task")["id"], "parent")
        todo_queue.split("test-task", "parent", [
            self.item("child-a", ["a.py"]), self.item("child-b", ["b.py"]),
        ], "read-only prompt timed out twice")
        self.assertEqual(todo_queue.summary("test-task")["counts"]["split"], 1)
        self.assertEqual(todo_queue.next_item("test-task")["id"], "child-a")
        self.complete_steps("child-a")
        todo_queue.finish("test-task", "child-a", "completed")
        self.assertEqual(todo_queue.next_item("test-task")["id"], "child-b")
        self.complete_steps("child-b")
        todo_queue.finish("test-task", "child-b", "completed")
        self.assertTrue(todo_queue.summary("test-task")["complete"])

    def test_dependencies_are_respected(self):
        todo_queue.add("test-task", self.item("first", ["first.py"]))
        second = self.item("second", ["second.py"]); second["depends_on"] = ["first"]
        todo_queue.add("test-task", second)
        self.assertEqual(todo_queue.next_item("test-task")["id"], "first")
        self.complete_steps("first")
        todo_queue.finish("test-task", "first", "completed")
        self.assertEqual(todo_queue.next_item("test-task")["id"], "second")

    def test_steps_are_ordered_and_two_readonly_failures_require_split(self):
        todo_queue.add("test-task", self.item("item", ["a.py"]))
        todo_queue.next_item("test-task")
        todo_queue.begin_step("test-task", "item", "step1")
        item = todo_queue.record_step("test-task", "item", "step1", False, "first.json")
        self.assertFalse(item.get("split_required", False))
        todo_queue.begin_step("test-task", "item", "step1")
        item = todo_queue.record_step("test-task", "item", "step1", False, "second.json")
        self.assertTrue(item["split_required"])
        with self.assertRaisesRegex(ValueError, "until Step 1 through Step 4"):
            todo_queue.finish("test-task", "item", "completed")

    def test_steps_must_complete_in_order_before_finish(self):
        todo_queue.add("test-task", self.item("item", ["a.py"]))
        todo_queue.next_item("test-task")
        self.complete_steps("item")
        self.assertEqual(todo_queue.finish("test-task", "item", "completed")["state"], "completed")

    def test_recover_returns_orphaned_running_item_to_pending(self):
        todo_queue.add("test-task", self.item("item", ["a.py"]))
        self.assertEqual(todo_queue.next_item("test-task")["id"], "item")
        item = todo_queue.recover("test-task", "item")
        self.assertEqual(item["state"], "pending")
        self.assertEqual(todo_queue.summary("test-task")["counts"]["pending"], 1)

    def test_recover_rejects_non_running_item(self):
        todo_queue.add("test-task", self.item("item", ["a.py"]))
        with self.assertRaisesRegex(ValueError, "running"):
            todo_queue.recover("test-task", "item")

    def test_recover_rejects_unknown_item_id(self):
        todo_queue.add("test-task", self.item("item", ["a.py"]))
        with self.assertRaisesRegex(ValueError, "Unknown to-do id"):
            todo_queue.recover("test-task", "missing")

    def test_split_required_blocks_reclaim_after_recover(self):
        todo_queue.add("test-task", self.item("item", ["a.py"]))
        todo_queue.next_item("test-task")
        for _ in range(2):
            todo_queue.begin_step("test-task", "item", "step1")
            todo_queue.record_step("test-task", "item", "step1", False, "failure.json")
        todo_queue.recover("test-task", "item")
        self.assertEqual(todo_queue.summary("test-task")["counts"]["pending"], 1)
        # next_item skips the split-required item instead of raising, so other
        # claimable items are not blocked (parallel dispatch); the item stays pending.
        self.assertIsNone(todo_queue.next_item("test-task"))
        self.assertEqual(todo_queue.summary("test-task")["counts"]["pending"], 1)

    def test_first_timeout_triggers_split(self):
        # F-A-02：只读步骤第 1 次超时即触发拆分（HERMES_SPLIT_ON_FIRST_TIMEOUT 默认开）
        todo_queue.add("test-task", self.item("item", ["a.py"]))
        todo_queue.next_item("test-task")
        todo_queue.begin_step("test-task", "item", "step1")
        item = todo_queue.record_step("test-task", "item", "step1", False, "Timeout after 120s")
        self.assertTrue(item["split_required"])
        self.assertTrue(item["pending_split"])

    def test_success_after_timeout_still_requires_split(self):
        # F-A-04 粘性：step1 超时→pending_split 置位后，record_step 即便 success
        # 也不清除拆分门（todo_queue.py:171-179）；begin_step 会拒绝重入 step1
        # （split_required 拦截），故此处直接验证 record_step 自身的 success 分支。
        todo_queue.add("test-task", self.item("item", ["a.py"]))
        todo_queue.next_item("test-task")
        todo_queue.begin_step("test-task", "item", "step1")
        todo_queue.record_step("test-task", "item", "step1", False, "Timeout after 120s")
        # 直接验证 record_step success 分支的粘性（绕过 begin_step 属测试范围）
        item = todo_queue.record_step("test-task", "item", "step1", True, "step1.json")
        self.assertTrue(item["split_required"], "split_required must remain sticky on success")
        self.assertTrue(item["pending_split"], "pending_split must remain sticky on success")
        # split() 解除门验证
        todo_queue.split("test-task", "item", [self.item("child", ["a.py"])], "split after timeout")
        self.assertEqual(todo_queue.summary("test-task")["counts"].get("awaits_split", 0), 0)

    def test_summary_exposes_awaits_split(self):
        # F-O01：卡在拆分门的 item 在摘要中显式可见 awaits_split，且不算 complete
        todo_queue.add("test-task", self.item("item", ["a.py"]))
        todo_queue.next_item("test-task")
        todo_queue.begin_step("test-task", "item", "step1")
        todo_queue.record_step("test-task", "item", "step1", False, "Timeout after 120s")
        summ = todo_queue.summary("test-task")
        self.assertEqual(summ["counts"]["awaits_split"], 1)
        self.assertEqual(summ["awaits_split_ids"], ["item"])
        self.assertFalse(summ["complete"])
        todo_queue.recover("test-task", "item")          # recover 保留拆分门
        self.assertEqual(todo_queue.summary("test-task")["counts"]["awaits_split"], 1)


if __name__ == "__main__":
    unittest.main()
