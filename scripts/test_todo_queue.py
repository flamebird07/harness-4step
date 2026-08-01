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

    def test_split_preserves_queue_and_requires_children_to_finish(self):
        todo_queue.add("test-task", self.item("parent", ["a.py", "b.py"]))
        self.assertEqual(todo_queue.next_item("test-task")["id"], "parent")
        todo_queue.split("test-task", "parent", [
            self.item("child-a", ["a.py"]), self.item("child-b", ["b.py"]),
        ], "read-only prompt timed out twice")
        self.assertEqual(todo_queue.summary("test-task")["counts"]["split"], 1)
        self.assertEqual(todo_queue.next_item("test-task")["id"], "child-a")
        todo_queue.finish("test-task", "child-a", "completed")
        self.assertEqual(todo_queue.next_item("test-task")["id"], "child-b")
        todo_queue.finish("test-task", "child-b", "completed")
        self.assertTrue(todo_queue.summary("test-task")["complete"])

    def test_dependencies_are_respected(self):
        todo_queue.add("test-task", self.item("first", ["first.py"]))
        second = self.item("second", ["second.py"]); second["depends_on"] = ["first"]
        todo_queue.add("test-task", second)
        self.assertEqual(todo_queue.next_item("test-task")["id"], "first")
        todo_queue.finish("test-task", "first", "completed")
        self.assertEqual(todo_queue.next_item("test-task")["id"], "second")


if __name__ == "__main__":
    unittest.main()
