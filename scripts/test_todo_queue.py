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


if __name__ == "__main__":
    unittest.main()
