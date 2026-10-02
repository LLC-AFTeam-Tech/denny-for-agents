import io
import json
import os
import socket
import sys
import tempfile
import threading
import unittest
from importlib.machinery import SourceFileLoader

HERE = os.path.dirname(os.path.abspath(__file__))
hook = SourceFileLoader("denny_hook", os.path.join(HERE, "denny-hook.py")).load_module()


class FakeDenny:
    """Accepts one connection, records the request, optionally answers."""

    def __init__(self, decision=None, files=None):
        self.files = files
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.bind(("127.0.0.1", 0))
        self.server.listen(1)
        self.port = self.server.getsockname()[1]
        self.decision = decision
        self.requests = []
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        conn, _ = self.server.accept()
        line = hook.read_line(conn, 5)
        request = json.loads(line)
        self.requests.append(request)
        if request["wantsDecision"] and self.decision:
            reply = {"id": request["id"], "decision": self.decision}
            conn.sendall((json.dumps(reply) + "\n").encode())
        if request.get("wantsFiles") and self.files is not None:
            reply = {"id": request["id"], "files": self.files}
            conn.sendall((json.dumps(reply) + "\n").encode())
        conn.close()

    def close(self):
        self.thread.join(2)
        self.server.close()


class HookTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        hook.HOME = self.home
        hook.BASE_DIR = os.path.join(self.home, ".denny-for-agents")
        hook.CONFIG_PATH = os.path.join(hook.BASE_DIR, "remote.json")
        hook.INSTALLED_SCRIPT = os.path.join(hook.BASE_DIR, "denny-hook.py")
        hook.INBOX = os.path.join(self.home, "denny-inbox")
        hook.STATUSLINE_PATH = os.path.join(hook.BASE_DIR, "claude-statusline.json")
        hook.STATUSLINE_ORIGINAL = os.path.join(hook.BASE_DIR, "statusline-original.json")
        hook.CONFIG_FILES = {
            "claude": os.path.join(self.home, ".claude", "settings.json"),
            "codex": os.path.join(self.home, ".codex", "hooks.json"),
        }

    def run_hook(self, agent, payload):
        stdin, stdout = sys.stdin, sys.stdout
        sys.stdin, sys.stdout = io.StringIO(json.dumps(payload)), io.StringIO()
        try:
            code = hook.main(["denny-hook.py", agent])
            return code, sys.stdout.getvalue()
        finally:
            sys.stdin, sys.stdout = stdin, stdout

    def write_config(self, port, token="t" * 48):
        os.makedirs(hook.BASE_DIR, exist_ok=True)
        with open(hook.CONFIG_PATH, "w") as handle:
            json.dump({"port": port, "token": token}, handle)

    def test_event_shape_matches_swift(self):
        event = hook.build_event({
            "session_id": "s1", "hook_event_name": "PreToolUse", "cwd": "/root/shop",
            "tool_name": "Bash", "tool_input": {"command": "x" * 3000}, "notification_type": 5,
        }, "claude")
        self.assertEqual(event["name"], "PreToolUse")
        self.assertEqual(event["sessionId"], "s1")
        self.assertEqual(event["toolName"], "Bash")
        self.assertEqual(len(event["toolInput"]["command"]), hook.MAX_TEXT + 1)
        self.assertNotIn("notificationType", event)
        self.assertIn("host", event)
        self.assertEqual(hook.build_event({"hook_event_name": "PreCompact", "session_id": "s"}, "codex")["name"], "Other")
        self.assertIsNone(hook.build_event({"hook_event_name": "Stop"}, "claude"))

    def test_without_config_or_server_is_silent(self):
        payload = {"session_id": "s", "hook_event_name": "PermissionRequest", "tool_name": "Bash"}
        self.assertEqual(self.run_hook("claude", payload), (0, ""))
        unused = socket.socket()
        unused.bind(("127.0.0.1", 0))
        port = unused.getsockname()[1]
        unused.close()
        self.write_config(port)
        self.assertEqual(self.run_hook("claude", payload), (0, ""))

    def test_garbage_stdin_is_silent(self):
        self.write_config(1)
        stdin, stdout = sys.stdin, sys.stdout
        sys.stdin, sys.stdout = io.StringIO("not json"), io.StringIO()
        try:
            self.assertEqual(hook.main(["denny-hook.py", "codex"]), 0)
            self.assertEqual(sys.stdout.getvalue(), "")
        finally:
            sys.stdin, sys.stdout = stdin, stdout

    def test_approval_allow_and_token(self):
        denny = FakeDenny(decision="allow")
        self.write_config(denny.port, token="secret" * 8)
        code, output = self.run_hook("claude", {
            "session_id": "s", "hook_event_name": "PermissionRequest", "tool_name": "Bash",
            "tool_input": {"command": "rm -rf build"}})
        denny.close()
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(output),
                         {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}})
        request = denny.requests[0]
        self.assertEqual(request["token"], "secret" * 8)
        self.assertTrue(request["wantsDecision"])
        self.assertEqual(request["version"], 1)

    def test_codex_deny_and_ask(self):
        denny = FakeDenny(decision="deny")
        self.write_config(denny.port)
        _, output = self.run_hook("codex", {"session_id": "s", "hook_event_name": "PermissionRequest"})
        denny.close()
        self.assertEqual(json.loads(output)["hookSpecificOutput"]["decision"],
                         {"behavior": "deny", "message": "Denied from Denny for Agents"})
        denny = FakeDenny(decision="ask")
        self.write_config(denny.port)
        self.assertEqual(self.run_hook("codex", {"session_id": "s", "hook_event_name": "PermissionRequest"}), (0, ""))
        denny.close()

    def test_regular_event_does_not_wait(self):
        denny = FakeDenny()
        self.write_config(denny.port)
        self.assertEqual(self.run_hook("claude", {"session_id": "s", "hook_event_name": "Stop"}), (0, ""))
        denny.close()
        self.assertFalse(denny.requests[0]["wantsDecision"])

    def test_prompt_submit_receives_files_safely(self):
        import base64
        files = [{"dir": "20261001-153000", "name": "Отчёт 1.pdf", "data": base64.b64encode(b"%PDF").decode()},
                 {"dir": "../../evil", "name": "../../.bashrc", "data": base64.b64encode(b"x").decode()}]
        denny = FakeDenny(files=files)
        self.write_config(denny.port)
        code, output = self.run_hook("claude", {"session_id": "s", "hook_event_name": "UserPromptSubmit", "prompt": "hi"})
        denny.close()
        self.assertEqual(code, 0)
        good = os.path.join(hook.INBOX, "20261001-153000", "Отчёт 1.pdf")
        self.assertEqual(open(good, "rb").read(), b"%PDF")
        self.assertTrue(os.path.exists(os.path.join(hook.INBOX, "evil", ".bashrc")))
        self.assertFalse(os.path.exists(os.path.join(self.home, ".bashrc")))
        self.assertIn(good, output)
        request = denny.requests[0]
        self.assertTrue(request["wantsFiles"])
        self.assertEqual(request["event"]["home"], hook.HOME)

    def test_prompt_submit_without_files_is_quiet(self):
        denny = FakeDenny(files=[])
        self.write_config(denny.port)
        self.assertEqual(self.run_hook("codex", {"session_id": "s", "hook_event_name": "UserPromptSubmit"}), (0, ""))
        denny.close()

    def test_install_merges_and_uninstall_restores(self):
        claude_path = hook.CONFIG_FILES["claude"]
        os.makedirs(os.path.dirname(claude_path))
        user_hook = {"matcher": "Bash", "hooks": [{"type": "command", "command": "my-check.sh"}]}
        with open(claude_path, "w") as handle:
            json.dump({"model": "opus", "hooks": {"PreToolUse": [user_hook]}}, handle)

        hook.install(47321, "tok" * 16, ["claude", "codex"])
        hook.install(47321, "tok" * 16, ["claude", "codex"])
        claude = json.load(open(claude_path))
        self.assertEqual(claude["model"], "opus")
        self.assertEqual(len(claude["hooks"]["PreToolUse"]), 2)
        codex = json.load(open(hook.CONFIG_FILES["codex"]))
        self.assertEqual(set(codex), set(hook.EVENTS["codex"]))
        self.assertEqual(codex["PermissionRequest"][0]["hooks"][0]["timeout"], hook.APPROVAL_TIMEOUT_SECONDS)
        self.assertEqual(codex["UserPromptSubmit"][0]["hooks"][0]["timeout"], hook.FILES_WAIT_SECONDS + 5)
        self.assertTrue(os.path.exists(hook.INSTALLED_SCRIPT))
        self.assertEqual(os.stat(hook.CONFIG_PATH).st_mode & 0o777, 0o600)
        self.assertTrue(any("denny-backup" in name for name in os.listdir(os.path.dirname(claude_path))))

        hook.uninstall()
        claude = json.load(open(claude_path))
        self.assertEqual(claude["hooks"], {"PreToolUse": [user_hook]})
        self.assertEqual(json.load(open(hook.CONFIG_FILES["codex"])), {})

    def test_statusline_records_limits_and_prints(self):
        payload = json.dumps({"rate_limits": {"five_hour": {"used_percentage": 23.5, "resets_at": 1000 + 7800},
                                              "seven_day": {"used_percentage": 41.2, "resets_at": 1000 + 3 * 86400}}}).encode()
        line = hook.run_statusline(payload, now=1000)
        self.assertEqual(line, "Denny · 5h 24% (2h10m) · 7d 41% (3d0h)\n")
        live = hook.statusline_limits()
        self.assertEqual([(w["kind"], w["percent"]) for w in live["windows"]], [("session", 23.5), ("weekly", 41.2)])
        self.assertEqual(hook.run_statusline(b"not json", now=1000), "Denny\n")

    def test_statusline_install_chains_and_restores_user_line(self):
        path = hook.CONFIG_FILES["claude"]
        os.makedirs(os.path.dirname(path))
        mine = {"type": "command", "command": "echo my-line", "refreshInterval": 5}
        with open(path, "w") as handle:
            json.dump({"statusLine": mine}, handle)
        hook.install(47321, "tok" * 16, ["claude"])
        config = json.load(open(path))
        self.assertIn("--statusline", config["statusLine"]["command"])
        self.assertEqual(hook.run_statusline(b"{}"), "my-line\n")
        hook.install(47321, "tok" * 16, ["claude"])
        self.assertEqual(json.load(open(hook.STATUSLINE_ORIGINAL))["command"], "echo my-line")
        hook.uninstall()
        self.assertEqual(json.load(open(path))["statusLine"], mine)

    def test_mac_gets_only_the_status_line(self):
        path = hook.CONFIG_FILES["claude"]
        os.makedirs(os.path.dirname(path))
        hooks = {"PreToolUse": [{"hooks": [{"type": "command", "command": "/x/bin/denny-hook claude"}]}]}
        mine = {"type": "command", "command": "echo my-line"}
        with open(path, "w") as handle:
            json.dump({"hooks": hooks, "statusLine": mine, "model": "opus"}, handle)
        self.assertEqual(hook.main(["denny-hook.py", "--statusline-install"]), 0)
        config = json.load(open(path))
        self.assertIn("--statusline", config["statusLine"]["command"])
        self.assertEqual(config["hooks"], hooks)
        self.assertEqual(config["model"], "opus")
        self.assertFalse(os.path.exists(hook.CONFIG_PATH))
        self.assertTrue(os.path.exists(hook.INSTALLED_SCRIPT))
        hook.main(["denny-hook.py", "--statusline-install"])
        self.assertEqual(json.load(open(hook.STATUSLINE_ORIGINAL))["command"], "echo my-line")
        self.assertEqual(hook.main(["denny-hook.py", "--statusline-uninstall"]), 0)
        self.assertEqual(json.load(open(path))["statusLine"], mine)
        self.assertEqual(json.load(open(path))["hooks"], hooks)

    def test_install_refuses_unreadable_config(self):
        path = hook.CONFIG_FILES["claude"]
        os.makedirs(os.path.dirname(path))
        with open(path, "w") as handle:
            handle.write("{ broken")
        with self.assertRaises(SystemExit):
            hook.install(47321, "tok" * 16, ["claude"])
        self.assertEqual(open(path).read(), "{ broken")


def jsonl(path, entries):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a") as handle:
        for entry in entries:
            handle.write(json.dumps(entry) + "\n")


def claude_entry(request, output, when="2026-10-01T10:15:00.000Z", model="claude-opus-5-5"):
    return {"type": "assistant", "timestamp": when, "requestId": request, "cwd": "/root/projects/shop",
            "message": {"model": model, "usage": {
                "input_tokens": 2, "cache_creation_input_tokens": 100, "cache_read_input_tokens": 1000,
                "output_tokens": output,
                "cache_creation": {"ephemeral_1h_input_tokens": 100, "ephemeral_5m_input_tokens": 0}}}}


class UsageTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        hook.BASE_DIR = os.path.join(self.home, ".denny-for-agents")
        hook.STATE_PATH = os.path.join(hook.BASE_DIR, "usage-state.json")
        hook.LOCK_PATH = os.path.join(hook.BASE_DIR, "lock")
        hook.CLAUDE_PROJECTS = os.path.join(self.home, ".claude", "projects")
        hook.CODEX_SESSIONS = os.path.join(self.home, ".codex", "sessions")
        hook.CLAUDE_JSON = os.path.join(self.home, ".claude.json")
        hook.CLAUDE_APP_HISTORY = os.path.join(self.home, "claude-app.json")
        hook.STATUSLINE_PATH = os.path.join(hook.BASE_DIR, "claude-statusline.json")
        self.now = hook.parse_time("2026-10-01T12:00:00Z")
        # Never touch a real Codex account from tests.
        self.real_binary = hook.codex_binary
        hook.codex_binary = lambda: None

    def tearDown(self):
        hook.codex_binary = self.real_binary

    def totals(self, report, agent):
        result = dict.fromkeys(hook.FIELDS, 0)
        for item in report["usage"]:
            if item["agent"] == agent:
                for field in hook.FIELDS:
                    result[field] += item[field]
        return result

    def test_parse_time(self):
        self.assertEqual(hook.parse_time("1970-01-01T00:01:00Z"), 60)
        self.assertEqual(hook.parse_time("1970-01-01T01:00:00.123+01:00"), 0)
        self.assertEqual(hook.parse_time("2026-10-02T07:00:00+00:00"), 1790924400)
        self.assertIsNone(hook.parse_time("nope"))

    def test_claude_streamed_reply_counted_once_and_incremental(self):
        path = os.path.join(hook.CLAUDE_PROJECTS, "-root", "s.jsonl")
        jsonl(path, [claude_entry("r1", 10), claude_entry("r1", 50), {"type": "user", "message": {}}])
        report = hook.build_report(self.now)
        self.assertEqual({item["project"] for item in report["usage"]}, {"shop"})
        first = self.totals(report, "claude")
        self.assertEqual(first, {"input": 2, "cacheWrite5m": 0, "cacheWrite1h": 100, "cacheRead": 1000, "output": 50})
        jsonl(path, [claude_entry("r1", 70), claude_entry("r2", 5)])
        second = self.totals(hook.build_report(self.now), "claude")
        self.assertEqual(second["output"], 75)
        self.assertEqual(second["cacheRead"], 2000)

    def test_partial_last_line_waits(self):
        path = os.path.join(hook.CLAUDE_PROJECTS, "-root", "s.jsonl")
        os.makedirs(os.path.dirname(path))
        line = json.dumps(claude_entry("r1", 10))
        with open(path, "w") as handle:
            handle.write(line[:40])
        self.assertEqual(self.totals(hook.build_report(self.now), "claude")["output"], 0)
        with open(path, "w") as handle:
            handle.write(line + "\n")
        self.assertEqual(self.totals(hook.build_report(self.now), "claude")["output"], 10)

    def test_codex_deltas_model_and_limits(self):
        path = os.path.join(hook.CODEX_SESSIONS, "2026", "10", "01", "rollout.jsonl")
        def count(total_in, cached, out, limits=None):
            payload = {"type": "token_count", "info": {"total_token_usage": {
                "input_tokens": total_in, "cached_input_tokens": cached, "output_tokens": out,
                "cache_write_input_tokens": 0}}, "rate_limits": limits}
            return {"timestamp": "2026-10-01T11:00:00Z", "type": "event_msg", "payload": payload}
        limits = {"primary": {"used_percent": 42.0, "window_minutes": 300, "resets_at": 1790900000},
                  "secondary": {"used_percent": 96.0, "window_minutes": 10080, "resets_at": 1791000000},
                  "plan_type": "plus"}
        jsonl(path, [{"type": "turn_context", "payload": {"model": "gpt-5.6-sol", "cwd": "/Users/t/app"}},
                     count(1000, 800, 50, limits), count(1500, 1200, 80, {"primary": None})])
        report = hook.build_report(self.now)
        totals = self.totals(report, "codex")
        self.assertEqual(totals, {"input": 300, "cacheWrite5m": 0, "cacheWrite1h": 0, "cacheRead": 1200, "output": 80})
        self.assertEqual({item["model"] for item in report["usage"]}, {"gpt-5.6-sol"})
        self.assertEqual({item["project"] for item in report["usage"]}, {"app"})
        codex = [entry for entry in report["limits"] if entry["agent"] == "codex"][0]
        self.assertEqual(codex["plan"], "Plus")
        self.assertEqual(codex["planPrice"], 20.0)
        self.assertNotIn("planRaw", codex)
        self.assertEqual([(w["kind"], w["percent"]) for w in codex["windows"]], [("session", 42.0), ("weekly", 96.0)])

    def test_claude_limits_from_claude_json_and_app(self):
        with open(hook.CLAUDE_JSON, "w") as handle:
            json.dump({"oauthAccount": {"organizationType": "claude_max"}, "cachedUsageUtilization": {
                "fetchedAtMs": 1000_000, "utilization": {"limits": [
                    {"kind": "session", "group": "session", "percent": 12, "resets_at": "2026-10-01T15:00:00Z"},
                    {"kind": "weekly_all", "group": "weekly", "percent": 30, "resets_at": "2026-10-02T07:00:00+00:00"},
                    {"kind": "weekly_opus", "group": "weekly", "percent": 5, "resets_at": None}]}}}, handle)
        limits = hook.claude_limits()
        self.assertEqual(limits["plan"], "Max")
        self.assertIsNone(limits["planPrice"])
        self.assertEqual([(w["kind"], w["label"], w["percent"]) for w in limits["windows"]],
                         [("session", None, 12.0), ("weekly", None, 30.0), ("weekly", "Opus", 5.0)])
        with open(hook.CLAUDE_APP_HISTORY, "w") as handle:
            json.dump({"version": 2, "samples": [{"t": 2000_000, "u": {"fh": 96, "sd": 54}}]}, handle)
        fresher = hook.claude_limits()
        self.assertEqual([(w["kind"], w["percent"]) for w in fresher["windows"]], [("session", 96.0), ("weekly", 54.0)])
        os.makedirs(hook.BASE_DIR, exist_ok=True)
        with open(hook.STATUSLINE_PATH, "w") as handle:
            json.dump({"observedAt": 3000, "five_hour": {"percent": 7, "resetsAt": 5000}}, handle)
        live = hook.claude_limits()
        self.assertEqual([(w["kind"], w["percent"], w["resetsAt"]) for w in live["windows"]], [("session", 7.0, 5000.0)])
        self.assertEqual((live["plan"], live["observedAt"]), ("Max", 3000.0))
        self.assertEqual(fresher["windows"][0]["resetsAt"], hook.parse_time("2026-10-01T15:00:00Z"))
        self.assertEqual(fresher["observedAt"], 2000.0)

    def test_max_tier_and_price(self):
        with open(hook.CLAUDE_JSON, "w") as handle:
            json.dump({"oauthAccount": {"organizationType": "claude_max",
                                        "organizationRateLimitTier": "default_claude_max_20x"}}, handle)
        limits = hook.claude_limits()
        self.assertEqual((limits["plan"], limits["planPrice"]), ("Max 20x", 200.0))

    def test_old_bucket_keys_still_read(self):
        os.makedirs(hook.BASE_DIR, exist_ok=True)
        state = hook.empty_state()
        state["buckets"]["%d|claude|claude-opus-5-5" % (self.now // 3600 * 3600)] = [1, 0, 0, 0, 2]
        hook.save_state(state)
        item = hook.build_report(self.now)["usage"][0]
        self.assertEqual((item["project"], item["output"]), ("", 2))

    def test_old_buckets_are_pruned(self):
        path = os.path.join(hook.CLAUDE_PROJECTS, "-root", "s.jsonl")
        jsonl(path, [claude_entry("old", 10, when="2026-06-01T10:00:00Z")])
        report = hook.build_report(self.now)
        self.assertEqual(report["usage"], [])



FAKE_CODEX = r"""#!/usr/bin/env python3
import json, sys
if sys.argv[1:] != ["app-server"]:
    sys.exit(2)
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get("method") == "initialize":
        print(json.dumps({"id": msg["id"], "result": {"userAgent": "fake"}}), flush=True)
    elif msg.get("method") == "account/rateLimits/read":
        print(json.dumps({"method": "noise/notification", "params": {}}), flush=True)
        print(json.dumps({"id": msg["id"], "result": {
            "rateLimits": {"primary": {"usedPercent": 1, "windowDurationMins": 300}},
            "rateLimitsByLimitId": {"codex": {"planType": "prolite",
                "primary": {"usedPercent": 100, "windowDurationMins": 10080, "resetsAt": 1791332228},
                "secondary": {"usedPercent": 40, "windowDurationMins": 300, "resetsAt": 1790900000}}},
            "rateLimitResetCredits": {"availableCount": 2, "credits": [
                {"id": "a", "expiresAt": 1792000000}, {"id": "b", "expiresAt": 1791500000}]}}}), flush=True)
    elif msg.get("method") == "account/rateLimitResetCredit/consume":
        ok = isinstance(msg["params"].get("idempotencyKey"), str)
        print(json.dumps({"id": msg["id"], "result": {"outcome": "reset" if ok else "bad"}}), flush=True)
"""


class CodexAccountTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.fake = os.path.join(self.home, "codex")
        with open(self.fake, "w") as handle:
            handle.write(FAKE_CODEX)
        os.chmod(self.fake, 0o755)
        hook.BASE_DIR = os.path.join(self.home, ".denny-for-agents")
        hook.STATE_PATH = os.path.join(hook.BASE_DIR, "usage-state.json")
        hook.LOCK_PATH = os.path.join(hook.BASE_DIR, "lock")
        self.real_binary = hook.codex_binary
        hook.codex_binary = lambda: self.fake

    def tearDown(self):
        hook.codex_binary = self.real_binary

    def test_live_limits_and_resets(self):
        state = hook.empty_state()
        hook.refresh_codex_account(state, 1000)
        limits = state["codexLimits"]
        self.assertEqual(limits["plan"], "Pro $100")
        self.assertEqual([(w["kind"], w["percent"]) for w in limits["windows"]], [("weekly", 100.0), ("session", 40.0)])
        self.assertEqual(state["codexResets"]["available"], 2)
        self.assertEqual(state["codexResets"]["nextExpiresAt"], 1791500000.0)
        state["codexLimits"] = None
        hook.refresh_codex_account(state, 1000 + 10)
        self.assertIsNone(state["codexLimits"])

    def test_reset_uses_idempotency_key(self):
        os.makedirs(hook.BASE_DIR, exist_ok=True)
        self.assertEqual(hook.codex_reset(), {"outcome": "reset"})

    def test_missing_codex_is_quiet(self):
        hook.codex_binary = lambda: None
        state = hook.empty_state()
        hook.refresh_codex_account(state, 1000)
        self.assertIsNone(state["codexLimits"])
        self.assertEqual(hook.codex_reset(), {"outcome": "failed"})


class SafetyNetTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        hook.HOME = self.home
        hook.BASE_DIR = os.path.join(self.home, ".denny-for-agents")
        hook.SAFETY_DIR = os.path.join(hook.BASE_DIR, "safety-net")
        hook.SAFETY_INDEX = os.path.join(hook.SAFETY_DIR, "index.json")
        hook.SAFETY_SETTINGS = os.path.join(hook.SAFETY_DIR, "settings.json")
        self.repo = os.path.join(self.home, "app")
        os.makedirs(os.path.join(self.repo, "src"))
        self.git("init", "-q")
        self.write("src/main.py", "print('v1')\n")
        self.write(".gitignore", ".env\n")
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "first")

    def git(self, *args):
        import subprocess
        return subprocess.run(["git", "-C", self.repo] + list(args), check=True, capture_output=True, text=True).stdout

    def write(self, name, text):
        path = os.path.join(self.repo, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            handle.write(text)

    def read(self, name):
        with open(os.path.join(self.repo, name)) as handle:
            return handle.read()

    def test_spots_destructive_commands(self):
        risky = [
            "rm -rf build", "sudo rm -f a.txt", "cd app && rm -r src", "git reset --hard HEAD~1",
            "git clean -fd", "git checkout -- .", "git restore src/main.py", "find . -name '*.pyc' -delete",
            "ls | xargs rm", "echo hi\nrm notes.md", "FOO=1 git -C app reset --hard",
        ]
        safe = ["ls -la", "git status", "git restore --staged a.py", "git checkout main", "echo rm -rf /",
                "python3 - <<'EOF'\nprint(1)\nEOF", "git commit -m 'rm stuff'"]
        for command in risky:
            self.assertTrue(hook.risky_command(command)[0], command)
        for command in safe:
            self.assertFalse(hook.risky_command(command)[0], command)
        self.assertEqual(hook.risky_command("rm -rf -- 'my dir' b.txt")[1], ["my dir", "b.txt"])

    def test_git_snapshot_brings_back_deleted_and_changed_files(self):
        self.write("notes.txt", "untracked but precious\n")
        snapshot = hook.take_snapshot("rm -rf src notes.txt", self.repo, "claude")
        self.assertTrue(snapshot["ref"].startswith("refs/denny/safety-net/"))
        # The user's branch, index and status stay exactly as they were.
        self.assertEqual(self.git("status", "--porcelain"), "?? notes.txt\n")
        self.assertEqual(self.git("stash", "list"), "")

        import shutil
        shutil.rmtree(os.path.join(self.repo, "src"))
        os.remove(os.path.join(self.repo, "notes.txt"))
        self.write("added-later.txt", "new work\n")
        self.git("add", "added-later.txt")

        preview = hook.snapshot_preview(snapshot)
        self.assertIn(os.path.join(self.repo, "src/main.py"), preview)
        self.assertIn(os.path.join(self.repo, "notes.txt"), preview)
        ok, _ = hook.restore_snapshot(snapshot)
        self.assertTrue(ok)
        self.assertEqual(self.read("src/main.py"), "print('v1')\n")
        self.assertEqual(self.read("notes.txt"), "untracked but precious\n")
        # Work done after the snapshot is left alone.
        self.assertEqual(self.read("added-later.txt"), "new work\n")

    def test_ignored_and_outside_files_are_copied(self):
        self.write(".env", "SECRET=1\n")
        outside = os.path.join(self.home, "data")
        os.makedirs(outside)
        with open(os.path.join(outside, "a.csv"), "w") as handle:
            handle.write("1,2\n")
        snapshot = hook.take_snapshot("rm .env ../data/*.csv", os.path.join(self.repo), "codex")
        originals = sorted(item["original"] for item in snapshot["copies"])
        self.assertEqual(originals, sorted([os.path.join(self.repo, ".env"), os.path.join(outside, "a.csv")]))
        os.remove(os.path.join(self.repo, ".env"))
        with open(os.path.join(outside, "a.csv"), "w") as handle:
            handle.write("overwritten\n")
        self.assertTrue(hook.restore_snapshot(snapshot)[0])
        self.assertEqual(self.read(".env"), "SECRET=1\n")
        with open(os.path.join(outside, "a.csv")) as handle:
            self.assertEqual(handle.read(), "1,2\n")

    def test_no_snapshot_for_safe_commands_or_nothing_to_save(self):
        self.assertIsNone(hook.take_snapshot("git status", self.repo, "claude"))
        plain = os.path.join(self.home, "plain")
        os.makedirs(plain)
        self.assertIsNone(hook.take_snapshot("rm missing.txt", plain, "claude"))

    def test_old_snapshots_are_pruned_with_their_refs(self):
        old = hook.take_snapshot("rm src/main.py", self.repo, "claude", now=1000)
        hook.take_snapshot("rm src/main.py", self.repo, "claude")
        ids = [item["id"] for item in hook.load_safety_index()]
        self.assertNotIn(old["id"], ids)
        self.assertEqual(len(ids), 1)
        refs = self.git("for-each-ref", "--format=%(refname)", "refs/denny/")
        self.assertNotIn(old["ref"], refs)

    def test_settings_from_the_mac_set_age_and_space(self):
        hook.save_safety_settings({"days": 1, "limitMB": 300})
        self.assertEqual(hook.safety_settings(), (86400, 300 << 20))
        hook.save_safety_settings({"days": "oops"})
        self.assertEqual(hook.safety_settings(), (86400, 300 << 20))

    def test_full_space_drops_the_oldest_snapshots(self):
        hook.save_safety_settings({"days": 7, "limitMB": 100})
        big = os.path.join(self.home, "big.bin")
        with open(big, "wb") as handle:
            handle.write(b"x" * (60 << 20))
        outside = os.path.join(self.home, "plain")
        os.makedirs(outside)
        first = hook.take_snapshot("rm ../big.bin", outside, "claude")
        second = hook.take_snapshot("rm ../big.bin", outside, "claude")
        self.assertEqual(first["bytes"], 60 << 20)
        ids = [item["id"] for item in hook.load_safety_index()]
        self.assertEqual(ids, [second["id"]])
        self.assertFalse(os.path.exists(os.path.join(hook.SAFETY_DIR, first["id"])))
        with open(big, "wb") as handle:
            handle.write(b"x" * (120 << 20))
        self.assertIsNone(hook.take_snapshot("rm ../big.bin", outside, "claude"))

    def test_clear_removes_everything(self):
        snapshot = hook.take_snapshot("git reset --hard", self.repo, "claude")
        stdout = sys.stdout
        sys.stdout = io.StringIO()
        try:
            hook.clear_snapshots()
        finally:
            sys.stdout = stdout
        self.assertEqual(hook.load_safety_index(), [])
        self.assertNotIn(snapshot["ref"], self.git("for-each-ref", "refs/denny/"))

    def test_hook_sends_snapshot_with_the_event(self):
        denny = FakeDenny()
        os.makedirs(hook.BASE_DIR, exist_ok=True)
        with open(os.path.join(hook.BASE_DIR, "remote.json"), "w") as handle:
            json.dump({"port": denny.port, "token": "t" * 48}, handle)
        hook.CONFIG_PATH = os.path.join(hook.BASE_DIR, "remote.json")
        stdin, stdout = sys.stdin, sys.stdout
        sys.stdin = io.StringIO(json.dumps({"session_id": "s", "hook_event_name": "PreToolUse", "cwd": self.repo,
                                            "tool_name": "Bash", "tool_input": {"command": "git reset --hard"}}))
        sys.stdout = io.StringIO()
        try:
            hook.main(["denny-hook.py", "claude"])
        finally:
            sys.stdin, sys.stdout = stdin, stdout
        denny.close()
        snapshot = denny.requests[0]["event"]["snapshot"]
        self.assertEqual(snapshot["command"], "git reset --hard")
        self.assertEqual(snapshot["repo"], self.repo)


class TurnUsageTests(unittest.TestCase):
    def test_counts_only_the_last_task(self):
        path = os.path.join(tempfile.mkdtemp(), "t.jsonl")
        def assistant(request, output, model="claude-opus-5-5", read=0):
            return {"type": "assistant", "requestId": request,
                    "message": {"model": model, "usage": {"input_tokens": 1, "output_tokens": output,
                                                          "cache_read_input_tokens": read}}}
        jsonl(path, [
            {"type": "user", "message": {"role": "user", "content": "old task"}},
            assistant("r0", 999),
            {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "new task"}]}},
            assistant("r1", 10, read=100),
            assistant("r1", 30, read=100),
            {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "ok"}]}},
            {"type": "user", "isMeta": True, "message": {"role": "user", "content": "<meta>"}},
            assistant("r2", 5),
            assistant("r3", 7, model="claude-sonnet-5-5"),
        ])
        usage = hook.turn_usage(path)
        self.assertEqual([item["model"] for item in usage], ["claude-opus-5-5", "claude-sonnet-5-5"])
        self.assertEqual(usage[0]["output"], 35)
        self.assertEqual(usage[0]["cacheRead"], 100)
        self.assertEqual(usage[0]["input"], 2)
        self.assertEqual(usage[1]["output"], 7)
        self.assertEqual(hook.turn_usage(os.path.join(tempfile.mkdtemp(), "missing.jsonl")), [])


if __name__ == "__main__":
    unittest.main()
