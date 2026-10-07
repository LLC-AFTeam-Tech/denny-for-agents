"""Isolated review checks. No agents, Telegram, or user configuration run."""
import threading
import unittest
import shutil
from pathlib import Path
from unittest.mock import patch
import importlib.util

spec = importlib.util.spec_from_file_location("rereview_base", Path(__file__).with_name("test_astra_regressions.py"))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
hook = base.hook


class RereviewEdgeTests(base.RemoteReviewTests):
    def test_ignored_unicode_child_must_restore(self):
        src = self.repo / "src"
        src.mkdir()
        (src / "code.txt").write_text("code\n")
        (self.repo / ".gitignore").write_text("src/*.local\n")
        self.assertEqual(0, self.git(["add", "-A"])[0])
        self.assertEqual(0, self.git(["commit", "-qm", "source"])[0])
        ignored = src / "настройки.local"
        ignored.write_text("important configuration\n")
        snapshot = hook.take_snapshot("rm -rf src", str(self.repo), "claude")
        self.assertIsNotNone(snapshot.get("ref"), "A real git snapshot is required")
        print("ignored unicode copies:", snapshot["copies"], "skipped:", snapshot["skipped"])
        shutil.rmtree(src)
        restored = hook.restore_snapshot(snapshot)
        self.assertTrue(restored[0] if isinstance(restored, tuple) else restored)
        self.assertTrue(ignored.exists(), "Git's quoted ls-files path was used as a literal filename")

    def test_finished_job_must_not_restart_from_a_stale_queue_read(self):
        first = {"id": "A", "kind": "tests", "cwd": str(self.repo)}
        main = threading.current_thread()
        handler_entered = threading.Event()
        release_handler = threading.Event()
        original_load = hook.load_json_list
        executed = []
        worker_threads = []
        turns = {"config": 0, "ask": 0}
        interleaved = []

        def handler(job):
            executed.append(job["id"])
            worker_threads.append(threading.current_thread())
            if len(executed) == 1:
                handler_entered.set()
                if not release_handler.wait(2):
                    raise RuntimeError("fixture did not release the first job")
            return {"state": "passed"}

        def load(path):
            items = original_load(path)
            if path == hook.QUEUE_PATH and threading.current_thread() is main and handler_entered.is_set() and not interleaved:
                self.assertEqual(["A"], [job["id"] for job in items])
                # Main has read [A]. Now completion removes A and clears busy
                # before main calls next_heavy with its stale read.
                interleaved.append(True)
                release_handler.set()
                # A corrected scheduler may hold the queue lock while taking
                # this read: then completion must wait until the read returns.
                # Do not require it to finish inside that future transaction.
                worker_threads[0].join(0.2)
                if not worker_threads[0].is_alive():
                    self.assertEqual([], original_load(hook.QUEUE_PATH))
            return items

        def config():
            turns["config"] += 1
            return (1, "fixture") if turns["config"] <= 2 else None

        def ask(*args):
            turns["ask"] += 1
            return [first] if turns["ask"] == 1 else []

        def sleep(_):
            self.assertTrue(handler_entered.wait(2))

        try:
            with patch.object(hook, "load_json_list", load), patch.object(hook, "load_config", config), \
                 patch.object(hook, "ask_for_jobs", ask), patch.object(hook, "job_tests", handler), \
                 patch.object(hook.time, "sleep", sleep):
                hook.run_worker()
                for thread in worker_threads:
                    thread.join(2)
                    self.assertFalse(thread.is_alive())
        finally:
            release_handler.set()
            for thread in worker_threads:
                thread.join(2)
        print("executed jobs:", executed)
        self.assertTrue(interleaved, "The completion/read interleaving must occur")
        self.assertEqual(["A"], executed, "An already completed job was started again")


if __name__ == "__main__":
    unittest.main(verbosity=2)
