"""Astra's review 07.10.2026: reproductions of A1, A2, A5, A6 against the real hook."""
import importlib.util
import atexit
import os
import shutil
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

review_root = Path(tempfile.mkdtemp(prefix="astra-dfa-review-")).resolve()
import atexit, shutil
atexit.register(shutil.rmtree, review_root, True)  # leave nothing behind in /tmp
atexit.register(lambda: shutil.rmtree(review_root, ignore_errors=True))
original_expanduser = os.path.expanduser
os.path.expanduser = lambda value: str(review_root) if value == "~" else original_expanduser(value)
source_path = Path(os.environ.get("DENNY_REVIEW_SOURCE", str(Path(__file__).parent / "denny-hook.py")))
spec = importlib.util.spec_from_file_location("review_hook", source_path)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)
os.path.expanduser = original_expanduser


class RemoteReviewTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(dir=review_root)).resolve()
        base = self.root / ".denny-for-agents"
        base.mkdir()
        hook.BASE_DIR = str(base)
        hook.HOME = str(self.root)
        for key, name in {
            "RESULTS_PATH": "results.json", "QUEUE_PATH": "queue.json", "SEEN_PATH": "seen.json",
            "NIGHT_PATH": "night.json", "OFFICE_PATH": "office.json", "WORKER_LOCK": "worker.lock",
            "ACTIVITY_STAMP": "activity", "OFFICE_SESSIONS": "sessions.json", "SAFETY_INDEX": "safety/index.json",
        }.items():
            setattr(hook, key, str(base / name))
        hook.OFFICE_DIR = str(base / "office")
        hook.SAFETY_DIR = str(base / "safety")
        hook.SAFETY_SETTINGS = str(base / "safety/settings.json")
        self.repo = self.root / "project"
        self.repo.mkdir()
        (self.repo / "a.txt").write_text("base\n")
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@example.invalid"],
                     ["config", "user.name", "Test"], ["add", "-A"], ["commit", "-qm", "base"]]:
            self.assertEqual(0, self.git(args)[0])

    def git(self, args):
        return hook.office_git(["-C", str(self.repo)] + args)

    def task(self):
        task = {"id": "aa112233-0000-0000-0000-000000000000", "agent": "claude", "cwd": str(self.repo),
                "prompt": "Change a", "state": "review"}
        self.assertIsNone(hook.office_prepare(task))
        return task

    def test_commit_failure_must_keep_work(self):
        task = self.task()
        edited = Path(task["workdir"]) / "a.txt"
        edited.write_text("agent changes\n")
        self.assertEqual(0, self.git(["config", "user.name", ""])[0])
        hook.office_decide(task, True)
        self.assertTrue(edited.exists(), "Accept deleted the only working copy after Git commit failed")
        self.assertNotEqual("accepted", task["state"])

    def test_accept_must_not_abort_users_merge(self):
        self.assertEqual(0, self.git(["checkout", "-qb", "feature"])[0])
        (self.repo / "a.txt").write_text("feature\n")
        self.assertEqual(0, self.git(["commit", "-qam", "feature"])[0])
        self.assertEqual(0, self.git(["checkout", "-q", "main"])[0])
        (self.repo / "a.txt").write_text("main\n")
        self.assertEqual(0, self.git(["commit", "-qam", "main"])[0])
        task = self.task()
        (Path(task["workdir"]) / "b.txt").write_text("agent\n")
        hook.office_commit_leftovers(task)
        self.assertNotEqual(0, self.git(["merge", "feature"])[0])
        (self.repo / "a.txt").write_text("user manual resolution\n")
        self.assertEqual(0, self.git(["add", "a.txt"])[0])
        hook.office_decide(task, True)
        self.assertEqual(0, self.git(["rev-parse", "--verify", "MERGE_HEAD"])[0], "Denny aborted an unrelated merge")

    def test_ignored_child_must_restore(self):
        src = self.repo / "src"
        src.mkdir()
        (src / "code.txt").write_text("code\n")
        (self.repo / ".gitignore").write_text("src/*.local\n")
        self.assertEqual(0, self.git(["add", "-A"])[0])
        self.assertEqual(0, self.git(["commit", "-qm", "source"])[0])
        ignored = src / "settings.local"
        ignored.write_text("important configuration\n")
        snapshot = hook.take_snapshot("rm -rf src", str(self.repo), "claude")
        self.assertIsNotNone(snapshot)
        import shutil
        shutil.rmtree(src)
        self.assertTrue(hook.restore_snapshot(snapshot))
        self.assertTrue(ignored.exists(), "Git snapshot excluded the ignored child and no extra copy was taken")

    def test_finishing_job_must_not_erase_newly_received_job(self):
        first = {"id": "A", "kind": "tests", "cwd": str(self.repo)}
        second = {"id": "B", "kind": "review", "cwd": str(self.repo)}
        read_old_queue = threading.Event()
        adding_attempted = threading.Event()
        release_completion = threading.Event()
        newly_saved = threading.Event()
        old_writer_done = threading.Event()
        original_save = hook.save_json_list
        main = threading.current_thread()
        acknowledgements = []
        turns = {"config": 0, "ask": 0}

        def save(path, items):
            if path == hook.QUEUE_PATH and threading.current_thread() is not main and not items:
                # Completion has read [A] and computed []; pause before writing.
                read_old_queue.set()
                if not release_completion.wait(2):
                    raise RuntimeError("fixture did not release the finishing transaction")
                original_save(path, items)
                old_writer_done.set()
                return
            original_save(path, items)
            if path == hook.QUEUE_PATH and "B" in {item.get("id") for item in items}:
                newly_saved.set()
                if "A" in {item.get("id") for item in items} and not old_writer_done.wait(2):
                    raise RuntimeError("fixture did not finish the old queue writer")

        def release():
            if adding_attempted.wait(2):
                # An unlocked writer can save [A,B]. A serialized writer waits
                # outside the transaction; release the finisher independently.
                newly_saved.wait(0.2)
                release_completion.set()

        def config():
            turns["config"] += 1
            return (1, "fixture") if turns["config"] <= 3 else None

        def ask(port, token, results, received):
            turns["ask"] += 1
            acknowledgements.extend(received)
            if turns["ask"] == 1:
                return [first]
            if turns["ask"] == 2:
                if not read_old_queue.wait(5):
                    raise RuntimeError("fixture did not pause the finishing thread")
                adding_attempted.set()
                return [second]
            return []

        def sleep(_):
            if turns["ask"] == 1:
                if not read_old_queue.wait(5):
                    raise RuntimeError("fixture work did not finish")

        coordinator = threading.Thread(target=release, daemon=True)
        coordinator.start()
        original_next = hook.next_heavy
        def next_heavy(queue, *args):
            # Leave B waiting so its durable storage, seen id and ACK can be
            # inspected after run_worker; only A executes in this fixture.
            return None if queue and queue[0].get("id") == "B" else original_next(queue, *args)
        with patch.object(hook, "save_json_list", save), patch.object(hook, "load_config", config), \
             patch.object(hook, "ask_for_jobs", ask), patch.object(hook, "job_tests", lambda job: {"state": "passed"}), \
             patch.object(hook, "next_heavy", next_heavy), \
             patch.object(hook.time, "sleep", sleep):
            hook.run_worker()
        coordinator.join(2)
        self.assertTrue(newly_saved.is_set() and old_writer_done.is_set(), "Interleaving actually occurred")
        self.assertIn("B", acknowledgements, "The Mac was told B had been stored")
        self.assertIn("B", hook.load_json_list(hook.SEEN_PATH), "A resend will be ignored as already received")
        self.assertIn("B", [job["id"] for job in hook.load_json_list(hook.QUEUE_PATH)], "Acknowledged job B disappeared")


if __name__ == "__main__":
    unittest.main(verbosity=2)
