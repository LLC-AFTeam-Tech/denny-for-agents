#!/usr/bin/env python3
"""Denny for Agents -- remote hook for Claude Code / Codex on an SSH server.

The agent runs on the server; Denny runs on your Mac. A forwarded port
(ssh -R 47321:127.0.0.1:47321, or a Termius "Remote" rule) carries hook
events to the Mac. If the port isn't forwarded or Denny isn't running, the
hook exits 0 with no output and the agent carries on as if it weren't there.

  python3 denny-hook.py --install --port 47321 --token <token from Denny>
  python3 denny-hook.py --ping          # check the connection
  python3 denny-hook.py --uninstall
  python3 denny-hook.py --report        # usage + plan limits as JSON (used by the Mac app)
  python3 denny-hook.py --codex-reset   # spend one Codex rate-limit reset credit
  python3 denny-hook.py --statusline    # Claude Code status line: records live plan limits
  python3 denny-hook.py --statusline-install | --statusline-uninstall   # only the status line (Denny on a Mac)
  python3 denny-hook.py --snapshots     # safety net: snapshots taken before risky commands
  python3 denny-hook.py --restore ID    # put the files of a snapshot back
  python3 denny-hook.py --clear-snapshots
  python3 denny-hook.py --worker        # runs tests, reviews and night jobs sent from the Mac
  python3 denny-hook.py --set-port PORT # the tunnel Denny keeps itself landed on another port
  python3 denny-hook.py claude|codex    # called by the agent itself
"""

import base64
import calendar
import fcntl
import glob
import json
import os
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

HOME = os.path.expanduser("~")
BASE_DIR = os.path.join(HOME, ".denny-for-agents")
CONFIG_PATH = os.path.join(BASE_DIR, "remote.json")
INSTALLED_SCRIPT = os.path.join(BASE_DIR, "denny-hook.py")
MARKER = "denny-hook"
MAX_TEXT = 2000
INBOX = os.path.join(HOME, "denny-inbox")
FILES_WAIT_SECONDS = 25
MAX_FILES_LINE = 40 << 20
APPROVAL_WAIT_SECONDS = 300
APPROVAL_TIMEOUT_SECONDS = 600
EVENT_TIMEOUT_SECONDS = 5
# Stop may wait for a reply from the phone (only while the user is away).
REPLY_WAIT_SECONDS = 600
REPLY_TIMEOUT_SECONDS = 660
MAX_REPLY = 4000
CONNECT_TIMEOUT_SECONDS = 0.5

KNOWN_EVENTS = {
    "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
    "PermissionRequest", "Notification", "Stop", "Interrupt",
}
EVENTS = {
    "claude": ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
               "PermissionRequest", "Notification", "Stop"],
    "codex": ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
              "PermissionRequest", "Stop"],
}
STATE_PATH = os.path.join(BASE_DIR, "usage-state.json")
STATUSLINE_PATH = os.path.join(BASE_DIR, "claude-statusline.json")
STATUSLINE_ORIGINAL = os.path.join(BASE_DIR, "statusline-original.json")
LOCK_PATH = os.path.join(BASE_DIR, "usage-state.lock")
REPORT_STAMP = os.path.join(BASE_DIR, "report-sent")
REPORT_INTERVAL_SECONDS = 60
WORKER_LOCK = os.path.join(BASE_DIR, "worker.lock")
ACTIVITY_STAMP = os.path.join(BASE_DIR, "activity")
NIGHT_PATH = os.path.join(BASE_DIR, "night-shift.json")
RESULTS_PATH = os.path.join(BASE_DIR, "job-results.json")
# Jobs taken from the Mac: ids already stored (a resent job is recognised and
# only acknowledged again), and tests/reviews not yet run (survive a restart).
SEEN_PATH = os.path.join(BASE_DIR, "job-seen.json")
QUEUE_PATH = os.path.join(BASE_DIR, "job-queue.json")
SEEN_KEEP = 500
# Office: tasks for Claude/Codex as staff, each in its own git branch and
# working copy under ~/.denny-for-agents/office. Mirrors AgentCore/Office.swift.
OFFICE_PATH = os.path.join(BASE_DIR, "office.json")
OFFICE_DIR = os.path.join(BASE_DIR, "office")
OFFICE_KEEP = 50
WORKER_IDLE_SECONDS = 2 * 3600
TEST_TIMEOUT_SECONDS = 10 * 60
REVIEW_TIMEOUT_SECONDS = 10 * 60
NIGHT_TIMEOUT_SECONDS = 3 * 3600
NIGHT_ENV = "DENNY_NIGHT_SHIFT"
SAFETY_DIR = os.path.join(BASE_DIR, "safety-net")
SAFETY_INDEX = os.path.join(SAFETY_DIR, "index.json")
SAFETY_REF = "refs/denny/safety-net/"
SAFETY_SETTINGS = os.path.join(SAFETY_DIR, "settings.json")
SAFETY_KEEP = 50
SAFETY_COPY_FILES = 20000
KEEP_SECONDS = 92 * 86400  # 13 weeks for the activity map
RECENT_KEYS = 3000
CLAUDE_PROJECTS = os.path.join(HOME, ".claude", "projects")
CLAUDE_JSON = os.path.join(HOME, ".claude.json")
CLAUDE_APP_HISTORY = os.path.join(HOME, "Library", "Application Support", "Claude", "plan-usage-history.json")
CODEX_SESSIONS = os.path.join(HOME, ".codex", "sessions")
# OpenAI's internal names: "prolite" is the $100 Pro launched in April 2026.
# Monthly list prices (USD) for "value of your plan"; unknown plans stay unpriced.
CODEX_PLAN_PRICES = {"plus": 20.0, "prolite": 100.0, "pro_lite": 100.0, "pro": 200.0}
CLAUDE_PLAN_PRICES = {"Pro": 20.0, "Max 5x": 100.0, "Max 20x": 200.0}
CODEX_PLANS = {"plus": "Plus", "pro": "Pro $200", "prolite": "Pro $100", "pro_lite": "Pro $100",
               "promax": "Pro Max", "pro_max": "Pro Max", "team": "Team",
               "business": "Business", "enterprise": "Enterprise", "edu": "Edu", "free": "Free"}
CODEX_ACCOUNT_INTERVAL = 5 * 60
CODEX_CANDIDATES = [
    "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex",
    os.path.join(HOME, ".local", "bin", "codex"), os.path.join(HOME, ".npm-global", "bin", "codex"),
    "/Applications/Codex.app/Contents/Resources/codex",
    "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
    "/Applications/ChatGPT.app/Contents/Resources/codex",
]
PLAN_NAMES = {"claude_pro": "Pro", "claude_max": "Max", "claude_team": "Team", "claude_enterprise": "Enterprise"}
FIELDS = ("input", "cacheWrite5m", "cacheWrite1h", "cacheRead", "output")

CONFIG_FILES = {
    "claude": os.path.join(HOME, ".claude", "settings.json"),
    "codex": os.path.join(HOME, ".codex", "hooks.json"),
}


# ---------------------------------------------------------------- hook mode

def clip(value):
    if isinstance(value, str):
        return value if len(value) <= MAX_TEXT else value[:MAX_TEXT] + "…"
    if isinstance(value, list):
        return [clip(item) for item in value[:20]]
    if isinstance(value, dict):
        return {key: clip(item) for key, item in value.items()}
    return value


def build_event(payload, agent):
    """Same shape as AgentCore.HookEvent's Codable encoding."""
    session_id = payload.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        return None
    name = payload.get("hook_event_name")
    event = {
        "agent": agent,
        "name": name if name in KNOWN_EVENTS else "Other",
        "sessionId": session_id,
        "host": socket.gethostname(),
        "home": HOME,
    }
    optional = {
        "cwd": "cwd",
        "toolName": "tool_name",
        "prompt": "prompt",
        "message": "message",
        "notificationType": "notification_type",
        "lastAssistantMessage": "last_assistant_message",
    }
    for key, source in optional.items():
        value = payload.get(source)
        if isinstance(value, str):
            event[key] = clip(value)
    tool_input = payload.get("tool_input")
    if isinstance(tool_input, dict):
        event["toolInput"] = clip(tool_input)
    return event


def permission_output(decision, agent):
    if decision == "allow":
        body = {"behavior": "allow"}
    elif decision == "deny":
        body = {"behavior": "deny"}
        if agent == "codex":
            body["message"] = "Denied from Denny for Agents"
    else:
        return None
    return json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": body}},
                      sort_keys=True, separators=(",", ":"))


def load_config():
    try:
        with open(CONFIG_PATH) as handle:
            config = json.load(handle)
        return int(config["port"]), str(config["token"])
    except (OSError, ValueError, KeyError, TypeError):
        return None


def connect(port):
    try:
        conn = socket.create_connection(("127.0.0.1", port), timeout=CONNECT_TIMEOUT_SECONDS)
    except OSError:
        return None
    return conn


def read_line(conn, timeout, limit=1 << 20):
    conn.settimeout(timeout)
    chunks = []
    size = 0
    try:
        while True:
            chunk = conn.recv(1 << 16)
            if not chunk:
                return None
            chunks.append(chunk)
            size += len(chunk)
            if b"\n" in chunk:
                break
            if size > limit:
                return None
    except OSError:
        return None
    return b"".join(chunks).split(b"\n", 1)[0]


def send_request(event, port, token, wants_decision):
    """Returns the decision string, or None. Never raises."""
    conn = connect(port)
    if conn is None:
        return None
    try:
        request = {"version": 1, "id": str(uuid.uuid4()), "event": event,
                   "wantsDecision": wants_decision, "token": token}
        conn.sendall((json.dumps(request) + "\n").encode())
        if not wants_decision:
            return None
        line = read_line(conn, APPROVAL_WAIT_SECONDS)
        if line is None:
            return None
        response = json.loads(line)
        if response.get("id") != request["id"]:
            return None
        return response.get("decision")
    except (OSError, ValueError, AttributeError):
        return None
    finally:
        conn.close()


def wait_for_reply(event, port, token):
    """Stop: Denny holds the request while the user is away, and answers with
    what they replied to "done" in Telegram (or nothing). Mirrors DennyHook."""
    conn = connect(port)
    if conn is None:
        return None
    try:
        request = {"version": 1, "id": str(uuid.uuid4()), "event": event,
                   "wantsDecision": False, "wantsReply": True, "token": token}
        conn.sendall((json.dumps(request) + "\n").encode())
        line = read_line(conn, REPLY_WAIT_SECONDS)
        if line is None:
            return None
        response = json.loads(line)
        if response.get("id") != request["id"] or not isinstance(response.get("reply"), str):
            return None
        return response["reply"].strip()[:MAX_REPLY] or None
    except (OSError, ValueError, AttributeError):
        return None
    finally:
        conn.close()


def reply_instruction(text):
    return "The user replied from their phone (Telegram) with what to do next:\n\n" + text


def stop_continuation(text):
    """Claude Code and Codex both go on with `decision: block` + `reason`."""
    return json.dumps({"decision": "block", "reason": reply_instruction(text)}, sort_keys=True)


def safe_part(name):
    name = os.path.basename(str(name or "").replace("\x00", "")).strip()
    return "file" if name in ("", ".", "..") else name


def receive_files(event, port, token):
    """Ask Denny for files dropped on the notch for this server and write
    them under ~/denny-inbox. Returns the written paths."""
    conn = connect(port)
    if conn is None:
        return []
    written = []
    try:
        request = {"version": 1, "id": str(uuid.uuid4()), "event": event, "wantsDecision": False,
                   "token": token, "wantsFiles": True}
        conn.sendall((json.dumps(request) + "\n").encode())
        line = read_line(conn, FILES_WAIT_SECONDS, MAX_FILES_LINE)
        if line is None:
            return []
        delivery = json.loads(line)
        if delivery.get("id") != request["id"]:
            return []
        save_safety_settings(delivery.get("safetyNet"))
        for item in delivery.get("files") or []:
            folder = os.path.join(INBOX, safe_part(item.get("dir")))
            path = os.path.join(folder, safe_part(item.get("name")))
            os.makedirs(folder, mode=0o700, exist_ok=True)
            with open(path, "wb") as handle:
                handle.write(base64.b64decode(item.get("data") or ""))
            written.append(path)
    except (OSError, ValueError, AttributeError, TypeError):
        pass
    finally:
        conn.close()
    return written


def run_hook(agent):
    config = load_config()
    if config is None:
        return
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return
    if not isinstance(payload, dict):
        return
    event = build_event(payload, agent)
    if event is None:
        return
    try:
        with open(ACTIVITY_STAMP, "w"):
            pass
    except OSError:
        pass
    night = os.environ.get(NIGHT_ENV)
    if night:
        event["nightShift"] = night
        try:
            remember_office_session(night, payload.get("session_id"))
        except OSError:
            pass
        if agent == "claude" and event["name"] == "PreToolUse":
            output = night_output(payload.get("tool_name"), payload.get("tool_input"))
            if output:
                sys.stdout.write(output + "\n")
                sys.stdout.flush()
    if event["name"] in ("SessionStart", "UserPromptSubmit", "Stop"):
        start_worker()
    if event["name"] in ("UserPromptSubmit", "SessionStart"):
        written = receive_files(event, config[0], config[1])
        if written and agent == "claude" and event["name"] == "UserPromptSubmit":
            # Claude Code adds this hook's output to the conversation.
            sys.stdout.write("Denny for Agents delivered from the user's Mac: %s\n" % ", ".join(written))
        if event["name"] == "SessionStart":
            sys.stdout.flush()
            send_report_in_background(config[0], config[1])
        return
    if event["name"] == "PreToolUse":
        try:
            snapshot = take_snapshot(full_command(payload.get("tool_input")), payload.get("cwd"), agent)
            if snapshot:
                event["snapshot"] = snapshot
        except Exception:
            pass
    if event["name"] == "Stop":
        try:
            usage = turn_usage(payload.get("transcript_path")) if agent == "claude" \
                else codex_turn_usage(codex_rollout(payload))
            if usage:
                event["turnUsage"] = usage
        except Exception:
            pass
    if event["name"] == "Stop" and not night:
        reply = wait_for_reply(event, config[0], config[1])
        if reply:
            sys.stdout.write(stop_continuation(reply) + "\n")
        sys.stdout.flush()
        send_report_in_background(config[0], config[1])
        return
    wants_decision = event["name"] == "PermissionRequest"
    decision = send_request(event, config[0], config[1], wants_decision)
    if wants_decision:
        output = permission_output(decision, agent)
        if output:
            sys.stdout.write(output + "\n")
    elif event["name"] == "Stop":
        sys.stdout.flush()
        send_report_in_background(config[0], config[1])


# ---------------------------------------------------------------- task receipt

TURN_TAIL_BYTES = 8 << 20
CODEX_SESSIONS = os.path.join(HOME, ".codex", "sessions")


def is_prompt(entry):
    """A line the user typed (not a tool result or a meta line)."""
    if entry.get("type") != "user" or entry.get("isMeta"):
        return False
    message = entry.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if isinstance(content, str):
        return bool(content)
    if isinstance(content, list):
        return any(isinstance(part, dict) and part.get("type") == "text" for part in content)
    return False


def turn_usage(path):
    """Tokens of the last task in a Claude Code transcript, by model, in the
    shape of AgentCore's UsageReport.Item. Mirrors TurnUsage.claude."""
    if not isinstance(path, str):
        return []
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            start = max(0, size - TURN_TAIL_BYTES)
            handle.seek(start)
            lines = handle.read().split(b"\n")
    except OSError:
        return []
    if start > 0 and lines:
        lines = lines[1:]
    readings, order = {}, []
    for line in lines:
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if not isinstance(entry, dict):
            continue
        if is_prompt(entry):
            readings, order = {}, []
            continue
        message = entry.get("message")
        if entry.get("type") != "assistant" or not isinstance(message, dict):
            continue
        usage, model = message.get("usage"), message.get("model")
        if not isinstance(usage, dict) or not isinstance(model, str) or not model or model.startswith("<"):
            continue
        split = usage.get("cache_creation") if isinstance(usage.get("cache_creation"), dict) else {}
        write_total = as_int(usage.get("cache_creation_input_tokens"))
        write_1h = as_int(split.get("ephemeral_1h_input_tokens"))
        write_5m = as_int(split.get("ephemeral_5m_input_tokens"))
        if write_1h + write_5m < write_total:
            write_5m = write_total - write_1h
        values = [as_int(usage.get("input_tokens")), write_5m, write_1h,
                  as_int(usage.get("cache_read_input_tokens")), as_int(usage.get("output_tokens"))]
        key = entry.get("requestId") or message.get("id") or str(uuid.uuid4())
        if key in readings:
            readings[key] = (model, [max(a, b) for a, b in zip(readings[key][1], values)])
        else:
            readings[key] = (model, values)
            order.append(key)
    by_model, models = {}, []
    for key in order:
        model, values = readings[key]
        if model not in by_model:
            models.append(model)
            by_model[model] = [0, 0, 0, 0, 0]
        by_model[model] = [a + b for a, b in zip(by_model[model], values)]
    return [{"hour": 0, "agent": "claude", "model": model, "input": v[0], "cacheWrite5m": v[1],
             "cacheWrite1h": v[2], "cacheRead": v[3], "output": v[4]}
            for model, v in ((model, by_model[model]) for model in models)]


def read_tail(path, size=None):
    size = size or TURN_TAIL_BYTES
    with open(path, "rb") as handle:
        handle.seek(0, os.SEEK_END)
        total = handle.tell()
        start = max(0, total - size)
        handle.seek(start)
        lines = handle.read().split(b"\n")
    return lines[1:] if start > 0 and lines else lines


def codex_rollout(payload):
    """The Codex session log: the path the hook was given, else found by session id."""
    path = payload.get("transcript_path")
    if isinstance(path, str) and os.path.exists(path):
        return path
    session = payload.get("session_id")
    if not isinstance(session, str) or not session or "/" in session:
        return None
    matches = glob.glob(os.path.join(CODEX_SESSIONS, "*", "*", "*", "rollout-*%s.jsonl" % session))
    return max(matches, key=os.path.getmtime) if matches else None


# Where a Codex task starts. Codex marks tasks itself (task_started); the
# prompt is only a fallback, and it has been written three ways over time:
# event_msg user_message (old), response_item message role=user and
# event_msg item_completed with a UserMessage item (current).
def codex_boundary(entry, payload):
    kind, item = entry.get("type"), payload.get("type")
    if kind == "event_msg" and item in ("task_started", "turn_started"):
        return "task"
    if kind == "event_msg" and item == "user_message":
        return "prompt"
    if kind == "response_item" and item == "message" and payload.get("role") == "user":
        return "prompt"
    if kind == "event_msg" and item == "item_completed" and isinstance(payload.get("item"), dict) \
            and payload["item"].get("type") == "UserMessage":
        return "prompt"
    return None


def codex_usage_in(lines):
    """(found a start, usage of the last task) for these rollout lines."""
    model, base, last, summed = "codex", [0, 0, 0, 0], None, [0, 0, 0, 0]
    seen, tasks_marked = False, False
    for line in lines:
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        payload = entry.get("payload") if isinstance(entry, dict) else None
        if not isinstance(payload, dict):
            continue
        if entry.get("type") == "turn_context" and isinstance(payload.get("model"), str):
            model = payload["model"]
            continue
        boundary = codex_boundary(entry, payload)
        # With task markers present, a prompt is just part of the task: one
        # message written in two formats mustn't restart the count.
        if boundary == "task" or (boundary == "prompt" and not tasks_marked):
            tasks_marked = tasks_marked or boundary == "task"
            base = last or [0, 0, 0, 0]
            summed = [0, 0, 0, 0]
            seen = True
        elif entry.get("type") == "event_msg" and payload.get("type") == "token_count":
            info = payload.get("info") if isinstance(payload.get("info"), dict) else {}
            def reading(usage):
                usage = usage if isinstance(usage, dict) else {}
                return [as_int(usage.get("input_tokens")), as_int(usage.get("cached_input_tokens")),
                        as_int(usage.get("output_tokens")), as_int(usage.get("cache_write_input_tokens"))]
            if isinstance(info.get("total_token_usage"), dict):
                last = reading(info["total_token_usage"])
            if seen and isinstance(info.get("last_token_usage"), dict):
                summed = [a + b for a, b in zip(summed, reading(info["last_token_usage"]))]
    if not seen or last is None:
        return seen, []
    delta = [now - before for now, before in zip(last, base)]
    if any(value < 0 for value in delta):
        delta = summed  # totals restarted (compaction): add up the requests instead
    if not any(delta):
        return seen, []
    cached = min(delta[1], delta[0])
    # OpenAI counts cached tokens inside input_tokens.
    return seen, [{"hour": 0, "agent": "codex", "model": model, "input": delta[0] - cached, "cacheWrite5m": delta[3],
                   "cacheWrite1h": 0, "cacheRead": cached, "output": delta[2]}]


# A long task can push its start out of the usual tail; look further back
# before giving up instead of reporting nothing.
CODEX_TAIL_STEPS = (TURN_TAIL_BYTES, 64 << 20, 512 << 20)


def codex_turn_usage(path):
    """Tokens of the last task in a Codex rollout: the running totals after
    its start minus the totals before it. Mirrors TurnUsage.codex."""
    if not isinstance(path, str):
        return []
    try:
        size = os.path.getsize(path)
        for step in CODEX_TAIL_STEPS:
            seen, usage = codex_usage_in(read_tail(path, step))
            if seen or step >= size:
                return usage
    except OSError:
        return []
    return []


# ---------------------------------------------------------------- safety net
#
# Right before an agent runs a destructive command (rm, git reset --hard,
# git clean -f, git checkout/restore over local changes, find -delete), the
# hook snapshots the files: inside a git repo the whole working tree,
# untracked files included, goes into a hidden ref (refs/denny/...) without
# touching the branch, index or stash; targets outside git or git-ignored are
# copied aside. `--restore ID` puts them back. Mirrors AgentCore/SafetyNet.swift.

def full_command(tool_input):
    if not isinstance(tool_input, dict):
        return None
    command = tool_input.get("command")
    if isinstance(command, str):
        return command
    if isinstance(command, list):
        words = [word for word in command if isinstance(word, str)]
        if len(words) == 3 and words[1] in ("-lc", "-c"):
            return words[2]
        return " ".join(words) if words else None
    return None


def command_segments(command):
    """Words of each simple command; operators and new lines split, quotes respected."""
    command = command.replace("\\\n", " ").replace("\n", ";")
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|")
    lexer.whitespace_split = True
    lexer.commenters = ""
    segments, current = [], []
    try:
        for token in lexer:
            if token and set(token) <= set(";&|"):
                if current:
                    segments.append(current)
                current = []
            else:
                current.append(token)
    except ValueError:
        return [part.split() for part in command.replace("&", ";").replace("|", ";").split(";") if part.split()]
    if current:
        segments.append(current)
    return segments


def strip_prefixes(words):
    index = 0
    while index < len(words):
        word = words[index]
        if "=" in word and not word.startswith("-") and word.split("=", 1)[0].isidentifier():
            index += 1
        elif word in ("sudo", "command", "nohup", "time", "exec", "builtin"):
            index += 1
        else:
            break
    return words[index:]


def risky_command(command):
    """(is_risky, rm targets) for a shell command, or (False, [])."""
    if not isinstance(command, str) or not command.strip():
        return False, []
    risky, targets = False, []
    for words in command_segments(command):
        words = strip_prefixes(words)
        if not words:
            continue
        name = os.path.basename(words[0])
        rest = words[1:]
        if name == "xargs" and "rm" in rest:
            risky = True
        elif name in ("rm", "unlink", "rmdir"):
            risky = True
            options_done = False
            for word in rest:
                if not options_done and word == "--":
                    options_done = True
                elif options_done or not word.startswith("-"):
                    targets.append(word)
        elif name == "find" and "-delete" in rest:
            risky = True
        elif name == "git":
            args = list(rest)
            while args and args[0].startswith("-"):
                args = args[2:] if args[0] in ("-C", "-c") else args[1:]
            if not args:
                continue
            sub, sub_args = args[0], args[1:]
            if sub == "reset" and "--hard" in sub_args:
                risky = True
            elif sub == "clean" and any(arg == "--force" or (arg.startswith("-") and not arg.startswith("--") and "f" in arg)
                                        for arg in sub_args):
                risky = True
            elif sub == "checkout" and ("--" in sub_args or "." in sub_args or "-f" in sub_args or "--force" in sub_args):
                risky = True
            elif sub == "restore" and ("--staged" not in sub_args or "--worktree" in sub_args):
                risky = True
    return risky, targets


def run_git(repo, args, env=None, timeout=60):
    try:
        result = subprocess.run(["git", "-C", repo] + args, capture_output=True, text=True,
                                timeout=timeout, env=env)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def git_snapshot(repo, snapshot_id, message):
    index = run_git(repo, ["rev-parse", "--git-path", "index"])
    if index is None:
        return None
    index = os.path.join(repo, index) if not os.path.isabs(index) else index
    os.makedirs(SAFETY_DIR, mode=0o700, exist_ok=True)
    temp_index = os.path.join(SAFETY_DIR, "index-" + snapshot_id)
    try:
        if os.path.exists(index):
            shutil.copyfile(index, temp_index)
        env = dict(os.environ, GIT_INDEX_FILE=temp_index,
                   GIT_AUTHOR_NAME="Denny for Agents", GIT_AUTHOR_EMAIL="denny@localhost",
                   GIT_COMMITTER_NAME="Denny for Agents", GIT_COMMITTER_EMAIL="denny@localhost")
        if run_git(repo, ["add", "-A"], env=env, timeout=120) is None:
            return None
        tree = run_git(repo, ["write-tree"], env=env)
        if not tree:
            return None
        head = run_git(repo, ["rev-parse", "--verify", "-q", "HEAD"])
        commit = run_git(repo, ["commit-tree", tree] + (["-p", head] if head else []) + ["-m", message], env=env)
        if not commit or run_git(repo, ["update-ref", SAFETY_REF + snapshot_id, commit]) is None:
            return None
        return SAFETY_REF + snapshot_id
    finally:
        try:
            os.remove(temp_index)
        except OSError:
            pass


def tree_size(path, budget):
    """Bytes under path, stopping once past budget (or too many files)."""
    if os.path.islink(path) or not os.path.isdir(path):
        try:
            return os.lstat(path).st_size
        except OSError:
            return 0
    total, count = 0, 0
    for root, dirs, files in os.walk(path):
        for name in files:
            count += 1
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                pass
            if total > budget or count > SAFETY_COPY_FILES:
                return budget + 1
    return total


def expand_targets(targets, cwd):
    paths = []
    for target in targets:
        path = os.path.expanduser(target)
        if not os.path.isabs(path):
            path = os.path.join(cwd, path)
        matches = glob.glob(path) if any(char in target for char in "*?[") else [path]
        for match in matches:
            match = os.path.normpath(match)
            # Real folder, name untouched: a symlink being deleted stays the symlink.
            match = os.path.join(os.path.realpath(os.path.dirname(match)), os.path.basename(match))
            if os.path.lexists(match) and match not in paths:
                paths.append(match)
    return paths


def take_snapshot(command, cwd, agent, now=None):
    risky, targets = risky_command(command)
    if not risky or not isinstance(cwd, str) or not os.path.isdir(cwd):
        return None
    now = time.time() if now is None else now
    snapshot_id = time.strftime("%Y%m%d-%H%M%S", time.localtime(now)) + "-" + uuid.uuid4().hex[:4]
    short = command.strip().splitlines()[0][:200]
    max_age, limit = safety_settings()
    index = prune_snapshots(load_safety_index(), now, max_age)
    repo = run_git(cwd, ["rev-parse", "--show-toplevel"])
    ref = git_snapshot(repo, snapshot_id, "Denny safety net: " + short) if repo else None
    copies, skipped, copied = [], [], 0
    for path in expand_targets(targets, cwd):
        inside_repo = ref and (path + os.sep).startswith(repo.rstrip(os.sep) + os.sep)
        if inside_repo and run_git(repo, ["check-ignore", "-q", path]) is None:
            continue  # tracked or untracked-but-not-ignored: already in the git snapshot
        if path in (os.sep, HOME):
            skipped.append(path)
            continue
        size = tree_size(path, limit)
        # Oldest snapshots make room; what can't fit at all is skipped.
        index = make_room(index, copied + size, limit)
        if used_bytes(index) + copied + size > limit:
            skipped.append(path)
            continue
        stored = os.path.join(str(len(copies)), os.path.basename(path) or "root")
        destination = os.path.join(SAFETY_DIR, snapshot_id, stored)
        try:
            os.makedirs(os.path.dirname(destination), mode=0o700, exist_ok=True)
            if os.path.isdir(path) and not os.path.islink(path):
                shutil.copytree(path, destination, symlinks=True)
            else:
                shutil.copy2(path, destination, follow_symlinks=False)
        except (OSError, shutil.Error):
            skipped.append(path)
            continue
        copied += size
        copies.append({"original": path, "stored": stored})
    if not ref and not copies:
        save_safety_index(index)
        return None
    snapshot = {"id": snapshot_id, "createdAt": now, "agent": agent, "cwd": cwd, "command": short,
                "repo": repo if ref else None, "ref": ref, "copies": copies, "skipped": skipped,
                "host": socket.gethostname(), "bytes": copied}
    index.append(snapshot)
    for item in index[:-SAFETY_KEEP]:
        remove_snapshot(item)
    save_safety_index(index[-SAFETY_KEEP:])
    return snapshot


def safety_settings():
    """Days to keep and MB for copies, as chosen in Denny on the Mac."""
    days, limit_mb = 7, 2048
    try:
        with open(SAFETY_SETTINGS) as handle:
            data = json.load(handle)
        days = max(int(data.get("days", days)), 1)
        limit_mb = max(int(data.get("limitMB", limit_mb)), 100)
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    return days * 86400, limit_mb << 20


def save_safety_settings(data):
    if not isinstance(data, dict):
        return
    try:
        days, limit_mb = int(data["days"]), int(data["limitMB"])
    except (KeyError, ValueError, TypeError):
        return
    os.makedirs(SAFETY_DIR, mode=0o700, exist_ok=True)
    with open(SAFETY_SETTINGS, "w") as handle:
        json.dump({"days": days, "limitMB": limit_mb}, handle)


def used_bytes(snapshots):
    return sum(item.get("bytes") or 0 for item in snapshots)


def remove_snapshot(item):
    if item.get("repo") and item.get("ref"):
        run_git(item["repo"], ["update-ref", "-d", item["ref"]])
    shutil.rmtree(os.path.join(SAFETY_DIR, item["id"]), ignore_errors=True)


def make_room(snapshots, needed, limit):
    """Drops the oldest snapshots until `needed` more bytes fit under the limit."""
    kept = list(snapshots)
    while kept and needed <= limit and used_bytes(kept) + needed > limit:
        remove_snapshot(kept.pop(0))
    return kept


def clear_snapshots():
    for item in load_safety_index():
        remove_snapshot(item)
    save_safety_index([])
    print("All snapshots deleted.")
    return 0


def load_safety_index():
    try:
        with open(SAFETY_INDEX) as handle:
            data = json.load(handle)
        return [item for item in data.get("snapshots", []) if isinstance(item, dict) and item.get("id")]
    except (OSError, ValueError, AttributeError):
        return []


def save_safety_index(snapshots):
    os.makedirs(SAFETY_DIR, mode=0o700, exist_ok=True)
    temp = SAFETY_INDEX + ".tmp"
    with open(temp, "w") as handle:
        json.dump({"version": 1, "snapshots": snapshots}, handle, indent=1)
    os.replace(temp, SAFETY_INDEX)


def prune_snapshots(snapshots, now, max_age):
    kept = []
    for item in snapshots:
        if now - item.get("createdAt", 0) <= max_age:
            kept.append(item)
        else:
            remove_snapshot(item)
    return kept


def snapshot_preview(snapshot):
    """Paths that a restore would bring back or overwrite."""
    paths = []
    repo, ref = snapshot.get("repo"), snapshot.get("ref")
    if repo and ref:
        listed = run_git(repo, ["ls-tree", "-r", "--name-only", ref]) or ""
        changed = set((run_git(repo, ["diff", "--name-only", ref]) or "").splitlines())
        for name in listed.splitlines():
            if name in changed or not os.path.lexists(os.path.join(repo, name)):
                paths.append(os.path.join(repo, name))
    for item in snapshot.get("copies", []):
        paths.append(item["original"])
    return paths


def restore_snapshot(snapshot):
    """Puts files back. Files created after the snapshot are left alone; ones
    that a copy would overwrite are moved aside first. Returns (ok, message)."""
    repo, ref = snapshot.get("repo"), snapshot.get("ref")
    if repo and ref:
        if run_git(repo, ["restore", "--source=" + ref, "--worktree", "--overlay", "--", "."]) is None \
                and run_git(repo, ["checkout", ref, "--", "."]) is None:
            return False, "git could not restore the snapshot"
    folder = os.path.join(SAFETY_DIR, snapshot["id"])
    aside = os.path.join(folder, "replaced-" + time.strftime("%Y%m%d-%H%M%S"))
    for index, item in enumerate(snapshot.get("copies", [])):
        source, original = os.path.join(folder, item["stored"]), item["original"]
        if not os.path.lexists(source):
            continue
        try:
            if os.path.lexists(original):
                os.makedirs(aside, mode=0o700, exist_ok=True)
                shutil.move(original, os.path.join(aside, str(index)))
            os.makedirs(os.path.dirname(original), exist_ok=True)
            if os.path.isdir(source) and not os.path.islink(source):
                shutil.copytree(source, original, symlinks=True)
            else:
                shutil.copy2(source, original, follow_symlinks=False)
        except (OSError, shutil.Error) as error:
            return False, "could not put back %s: %s" % (original, error)
    return True, "restored"


def list_snapshots():
    snapshots = load_safety_index()
    if not snapshots:
        print("No snapshots yet.")
        return 0
    for item in reversed(snapshots):
        when = time.strftime("%Y-%m-%d %H:%M", time.localtime(item.get("createdAt", 0)))
        print("%s  %s  %s\n    %s" % (item["id"], when, item.get("cwd", ""), item.get("command", "")))
    return 0


def restore_command(snapshot_id, assume_yes):
    snapshot = next((item for item in load_safety_index() if item["id"] == snapshot_id), None)
    if snapshot is None:
        print("No snapshot %s. See --snapshots." % snapshot_id)
        return 1
    paths = snapshot_preview(snapshot)
    print("Snapshot %s before: %s" % (snapshot_id, snapshot.get("command", "")))
    print("%d path(s) will be put back or overwritten:" % len(paths))
    for path in paths[:30]:
        print("  " + path)
    if len(paths) > 30:
        print("  … and %d more" % (len(paths) - 30))
    if not paths:
        print("Nothing differs from the snapshot.")
        return 0
    if not assume_yes:
        try:
            answer = input("Changes made to these files after the snapshot will be lost. Restore? [y/N] ")
        except EOFError:
            answer = ""
        if answer.strip().lower() not in ("y", "yes", "д", "да"):
            print("Cancelled.")
            return 1
    ok, message = restore_snapshot(snapshot)
    print(message)
    return 0 if ok else 1


# ---------------------------------------------------------------- worker
#
# The Mac can't reach into the server, so a small background worker asks it
# for jobs through the same forwarded port: run the tests, review a diff with
# the other agent, count changed lines, queue a night task. Results wait in a
# file until the Mac is reachable again. Night tasks live here, so they run
# even if the SSH session drops overnight.

RISK_RULES = [
    (3, r"\b(curl|wget)\b[^|;&]*\|\s*(sudo\s+)?(sh|bash|zsh|python3?|perl|ruby)\b"),
    (3, r"\brm\s+(-[a-z]*[rf][a-z]*\s+)+(--no-preserve-root\s+)?(/|~|\$HOME|/\*|~/\*|\*)(\s|$)"),
    (3, r"\bdd\b[^;&|]*\bof=/dev/|>\s*/dev/(disk|sd|nvme)"),
    (3, r"\b(mkfs(\.\w+)?|diskutil\s+(erase\w*|partitionDisk|zeroDisk))\b"),
    (3, r":\(\)\s*\{\s*:\|:&\s*\};:"),
    (3, r"\b(drop\s+(table|database|schema)|truncate\s+table)\b"),
    (2, r"\brm\s+(?:-[a-z]+\s+)*-[a-z]*r"),
    (2, r"\bgit\s+push\b[^;&|]*(\s--force(-with-lease)?\b|\s-f\b)"),
    (2, r"\bgit\s+reset\s+[^;&|]*--hard\b"),
    (2, r"\bgit\s+clean\s+-[a-z]*f"),
    (2, r"(^|[;&|]\s*|\s)sudo\s"),
    (2, r"\bchmod\s+(-R\s+)?0?777\b|\bchown\s+-R\b"),
    (2, r"\b(kill\s+-9|killall|pkill)\b"),
    (2, r"\b(shutdown|reboot|halt)\b"),
    (2, r"\bdocker\s+(system\s+prune|volume\s+(rm|prune)|rm\s+-f)\b"),
    (2, r"\b(npm\s+publish|cargo\s+publish|twine\s+upload|gem\s+push|gh\s+release\s+create|pod\s+trunk\s+push)\b"),
    (2, r"(\.ssh/|id_(rsa|ed25519)|\.aws/credentials|\.env\b|keychain|security\s+find-generic-password)"),
]
SENSITIVE_PATH = r"(^|/)(\.ssh|\.aws|\.gnupg|\.config/gh)(/|$)|(^|/)\.env(\.|$)|^/(etc|usr|bin|sbin|System|Library)/|(^|/)\.(zshrc|bashrc|bash_profile|zprofile|profile)$|(^|/)(id_rsa|id_ed25519)"
WRITING_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch", "ApplyPatch")


def risk_level(tool_name, tool_input):
    """0 safe .. 3 critical, by the same rules as AgentCore.RiskRadar."""
    import re
    level = 0
    command = full_command(tool_input)
    if command:
        for rule_level, pattern in RISK_RULES:
            if rule_level > level and re.search(pattern, command, re.IGNORECASE):
                level = rule_level
    if tool_name in WRITING_TOOLS and isinstance(tool_input, dict):
        path = tool_input.get("file_path") or tool_input.get("path") or tool_input.get("notebook_path")
        if isinstance(path, str) and re.search(SENSITIVE_PATH, os.path.expanduser(path)):
            level = max(level, 2)
    return level


def night_output(tool_name, tool_input):
    """Claude Code's PreToolUse answer for a night task: the careful policy."""
    level = risk_level(tool_name, tool_input)
    decision = {"hookEventName": "PreToolUse", "permissionDecision": "deny" if level >= 2 else "allow"}
    if level >= 2:
        decision["permissionDecisionReason"] = ("Denny for Agents night shift: this looks dangerous and nobody is "
                                                "here to approve it. Find a safer way or leave it for the morning.")
    return json.dumps({"hookSpecificOutput": decision}, sort_keys=True)


def start_worker():
    """Spawns the worker unless one already runs (it holds a lock)."""
    try:
        with open(WORKER_LOCK, "a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(handle, fcntl.LOCK_UN)
    except OSError:
        return
    try:
        script = INSTALLED_SCRIPT if os.path.exists(INSTALLED_SCRIPT) else os.path.abspath(__file__)
        subprocess.Popen([sys.executable, script, "--worker"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
    except OSError:
        pass


def project_root(cwd):
    return run_git(cwd, ["rev-parse", "--show-toplevel"]) or cwd


def detect_tests(cwd):
    """(root, command) like AgentCore.TestRunner.detect, or None."""
    root = project_root(cwd)
    def has(name):
        return os.path.exists(os.path.join(root, name))
    def read(name):
        try:
            with open(os.path.join(root, name)) as handle:
                return handle.read()
        except (OSError, UnicodeDecodeError):
            return None
    custom = read(".denny-test")
    if custom:
        for line in custom.splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                return root, line
    if has("Package.swift"):
        return root, "swift test"
    package = read("package.json")
    if package:
        try:
            script = (json.loads(package).get("scripts") or {}).get("test")
        except (ValueError, AttributeError):
            script = None
        if isinstance(script, str) and "no test specified" not in script:
            if has("bun.lockb") or has("bun.lock"):
                return root, "bun run test"
            if has("pnpm-lock.yaml"):
                return root, "pnpm test"
            if has("yarn.lock"):
                return root, "yarn test"
            return root, "npm test"
    if has("Cargo.toml"):
        return root, "cargo test"
    if has("go.mod"):
        return root, "go test ./..."
    pyproject = read("pyproject.toml") or ""
    if has("pytest.ini") or has("conftest.py") or "[tool.pytest" in pyproject or \
            (has("tests") and (has("pyproject.toml") or has("setup.py") or has("requirements.txt"))):
        return root, "python3 -m pytest -q"
    makefile = read("Makefile") or ""
    if any(line.startswith("test:") for line in makefile.splitlines()):
        return root, "make test"
    return None


def tail_lines(text, count=40):
    return "\n".join(text.splitlines()[-count:]).strip()


def run_shell(arguments, cwd, timeout, env=None):
    """(exit code or None on timeout, combined output) in a login shell, gently niced."""
    try:
        result = subprocess.run(["nice", "-n", "10", "bash", "-lc", '"$0" "$@"'] + arguments, cwd=cwd,
                                capture_output=True, text=True, timeout=timeout, env=env, errors="replace")
        return result.returncode, (result.stdout + result.stderr)
    except subprocess.TimeoutExpired as error:
        output = error.stdout.decode("utf-8", "replace") if isinstance(error.stdout, bytes) else (error.stdout or "")
        return None, output
    except OSError as error:
        return 127, str(error)


def job_tests(job):
    found = detect_tests(job.get("cwd") or HOME) if os.path.isdir(job.get("cwd") or "") else None
    if found is None:
        return {"state": "none"}
    root, command = found
    started = time.time()
    code, output = run_shell(["bash", "-lc", command], root, TEST_TIMEOUT_SECONDS,
                             env=dict(os.environ, CI="1"))
    return {"state": "passed" if code == 0 else "failed", "command": command,
            "output": tail_lines(output) + ("\nStopped after 10 minutes." if code is None else ""),
            "duration": time.time() - started}


def task_diff(cwd, files, limit=120000):
    repo = run_git(cwd, ["rev-parse", "--show-toplevel"]) if os.path.isdir(cwd or "") else None
    if not repo or not files:
        return None
    text = run_git(repo, ["diff", "HEAD", "--"] + files) or ""
    for name in (run_git(repo, ["ls-files", "--others", "--exclude-standard", "--full-name", "--"] + files) or "").splitlines():
        try:
            with open(os.path.join(repo, name)) as handle:
                text += "\n\nNew file %s:\n%s" % (name, handle.read())
        except (OSError, UnicodeDecodeError):
            continue
    text = text.strip()
    if not text:
        return None
    return text if len(text) <= limit else text[:limit] + "\n\n[diff cut here: too long]"


def review_prompt(author, task, diff):
    """Same words as AgentCore.CrossReview.prompt."""
    names = {"claude": "Claude Code", "codex": "Codex"}
    asked = "The task was: «%s»." % task if task else "The task description isn't available."
    return ("You are reviewing changes that another AI coding agent (%s) has just made in this project. %s\n\n"
            "Review them like a careful senior engineer: bugs, regressions, missed edge cases, security problems, "
            "and anything that doesn't do what was asked. Don't edit any files — only read. You may open other files "
            "of the project for context.\n\n"
            "Reply with a short list of concrete findings, most important first, one per line starting with \"- \", "
            "each with the file and line. If everything looks right, reply with one line saying so and nothing else. "
            "Write the review in the same language as the task description.\n\n"
            "The changes (git diff against the last commit):\n\n%s") % (names.get(author, author), asked, diff)


def agent_binary(agent):
    name = "claude" if agent == "claude" else "codex"
    for path in (os.path.join(HOME, ".local", "bin", name), os.path.join(HOME, ".claude", "local", name),
                 "/usr/local/bin/" + name, "/usr/bin/" + name):
        if os.access(path, os.X_OK):
            return path
    code, output = run_shell(["sh", "-c", "command -v " + name], HOME, 20)
    path = output.strip().splitlines()[-1] if code == 0 and output.strip() else ""
    return path if path.startswith("/") else None


def review_arguments(reviewer, prompt):
    if reviewer == "codex":
        return ["exec", "--sandbox", "read-only", "--skip-git-repo-check", prompt]
    return ["-p", prompt, "--allowedTools", "Read,Grep,Glob",
            "--disallowedTools", "Edit,Write,MultiEdit,NotebookEdit,Bash"]


def job_review(job):
    author = job.get("author") or "claude"
    reviewer = "codex" if author == "claude" else "claude"
    binary = agent_binary(reviewer)
    if not binary:
        return {"state": "failed", "output": "not found on " + socket.gethostname(), "reviewer": reviewer}
    diff = task_diff(job.get("cwd"), job.get("files") or [])
    if not diff:
        return {"state": "failed", "output": "no changes to review", "reviewer": reviewer}
    code, output = run_shell([binary] + review_arguments(reviewer, review_prompt(author, job.get("task"), diff)),
                             project_root(job["cwd"]), REVIEW_TIMEOUT_SECONDS)
    output = output.strip()
    if code != 0 or not output:
        return {"state": "failed", "output": tail_lines(output, 3) or "exit %s" % code, "reviewer": reviewer}
    return {"state": "done", "output": output, "reviewer": reviewer}


def job_lines(job):
    cwd, files = job.get("cwd"), job.get("files") or []
    repo = run_git(cwd, ["rev-parse", "--show-toplevel"]) if os.path.isdir(cwd or "") else None
    if not repo or not files:
        return {"state": "none"}
    added = removed = 0
    counted = set()
    for line in (run_git(repo, ["diff", "--numstat", "HEAD", "--"] + files) or "").splitlines():
        parts = line.split("\t", 2)
        if len(parts) == 3:
            added += int(parts[0]) if parts[0].isdigit() else 0
            removed += int(parts[1]) if parts[1].isdigit() else 0
            counted.add(os.path.join(repo, parts[2]))
    for name in (run_git(repo, ["ls-files", "--others", "--exclude-standard", "--full-name", "--"] + files) or "").splitlines():
        path = os.path.join(repo, name)
        try:
            if path not in counted and os.path.getsize(path) < 2 << 20:
                with open(path) as handle:
                    added += len(handle.read().splitlines())
        except (OSError, UnicodeDecodeError):
            continue
    return {"state": "done", "added": added, "removed": removed}


def load_json_list(path):
    try:
        with open(path) as handle:
            data = json.load(handle)
        return data if isinstance(data, list) else []
    except (OSError, ValueError):
        return []


def save_json_list(path, items):
    os.makedirs(BASE_DIR, mode=0o700, exist_ok=True)
    # A temp file of its own: two writers must never share (and steal) one.
    descriptor, temp = tempfile.mkstemp(prefix=os.path.basename(path) + ".", suffix=".tmp", dir=os.path.dirname(path))
    try:
        with os.fdopen(descriptor, "w") as handle:
            json.dump(items, handle)
        os.replace(temp, path)
    except BaseException:
        try:
            os.remove(temp)
        except OSError:
            pass
        raise


# Results are added by the test/review thread while the main loop prunes the
# delivered ones: every read-modify-write of the file goes through this lock.
RESULTS_LOCK = threading.Lock()


def add_result(result):
    with RESULTS_LOCK:
        results = load_json_list(RESULTS_PATH)
        results.append(result)
        save_json_list(RESULTS_PATH, results[-200:])


def drop_delivered_results(delivered):
    """delivered: the (id, state) pairs the Mac has received."""
    with RESULTS_LOCK:
        save_json_list(RESULTS_PATH, [item for item in load_json_list(RESULTS_PATH)
                                      if (item.get("id"), item.get("state")) not in delivered])


def interrupted_nights(nights):
    """A night job saved as running whose worker is gone (crash, reboot): its
    process can't be found any more, so say so instead of "running" forever.
    Never restarted on its own -- it may have done half the work."""
    for job in nights:
        if job.get("state") == "running":
            job["state"] = "failed"
            add_result({"id": job["id"], "kind": "night", "state": "failed",
                        "output": "interrupted: the server or its worker restarted"})
    return nights


def night_due(job, now):
    if job.get("state") != "waiting":
        return False
    if isinstance(job.get("at"), (int, float)):
        return now >= job["at"]
    if isinstance(job.get("resetsAt"), (int, float)):
        return now >= job["resetsAt"] + 60
    return True


def valid_session(value):
    return isinstance(value, str) and 0 < len(value) <= 128 and not value.startswith("-") \
        and all(c.isascii() and (c.isalnum() or c in "-_") for c in value)


def start_night_job(job):
    binary = agent_binary(job.get("agent"))
    if not binary or not os.path.isdir(job.get("cwd") or ""):
        return None, "not found"
    resume = job.get("resume")
    if resume is not None and not valid_session(resume):
        return None, "bad session"
    # A reply from the phone resumes its session (Claude forks it, so a
    # terminal still open on the original isn't written to underneath).
    if job.get("agent") == "codex":
        arguments = ["exec", "--sandbox", "workspace-write", "--skip-git-repo-check"] \
            + (["resume", resume] if resume else []) + [job.get("prompt", "")]
    else:
        arguments = ["-p", job.get("prompt", "")] + (["--resume", resume, "--fork-session"] if resume else []) \
            + ["--permission-mode", "acceptEdits"]
    try:
        process = subprocess.Popen(["nice", "-n", "5", "bash", "-lc", '"$0" "$@"', binary] + arguments,
                                   cwd=job["cwd"], env=dict(os.environ, **{NIGHT_ENV: job["id"]}),
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError as error:
        return None, str(error)
    return process, None


def ask_for_jobs(port, token, results, received=()):
    """Sends finished results and the ids of jobs already stored here, returns
    the jobs the Mac still holds for us (or None if it's unreachable). The Mac
    keeps a job until its id comes back in `received`."""
    conn = connect(port)
    if conn is None:
        return None
    try:
        event = {"agent": "claude", "name": "Other", "sessionId": "worker", "host": socket.gethostname(), "home": HOME}
        request = {"version": 1, "id": str(uuid.uuid4()), "event": event, "wantsDecision": False,
                   "token": token, "wantsJobs": True, "jobResults": results, "jobsReceived": list(received)}
        conn.sendall((json.dumps(request) + "\n").encode())
        line = read_line(conn, 10)
        if line is None:
            return None
        reply = json.loads(line)
        if reply.get("id") != request["id"]:
            return None
        return [job for job in reply.get("jobs") or [] if isinstance(job, dict) and job.get("id")]
    except (OSError, ValueError, AttributeError):
        return None
    finally:
        conn.close()


# ---------------------------------------------------------------- office

def office_git(args, timeout=120):
    """(exit code, combined output) of git; never raises."""
    try:
        result = subprocess.run(["git"] + args, capture_output=True, text=True, timeout=timeout, errors="replace")
        return result.returncode, (result.stdout + result.stderr).strip()
    except (OSError, subprocess.TimeoutExpired) as error:
        return -1, str(error)


def office_branch(task_id):
    return "denny/office-" + task_id[:8].lower()


def office_repo(folder):
    code, out = office_git(["-C", folder, "rev-parse", "--show-toplevel"])
    return out if code == 0 and out else None


def office_run_folder(folder, repo, workdir):
    root, path = os.path.realpath(repo), os.path.realpath(folder)
    if not path.startswith(root + os.sep):
        return workdir
    return os.path.join(workdir, path[len(root) + 1:])


def office_prepare(task):
    """Own branch and working copy; a folder outside git is used as it is.
    Returns an error text or None."""
    if not os.path.isdir(task.get("cwd") or ""):
        return "not found"
    repo = office_repo(task["cwd"])
    if not repo:
        return None
    code, branch = office_git(["-C", repo, "rev-parse", "--abbrev-ref", "HEAD"])
    base = branch if code == 0 and branch and branch != "HEAD" else office_git(["-C", repo, "rev-parse", "HEAD"])[1]
    copy = os.path.join(OFFICE_DIR, os.path.basename(repo) + "-" + task["id"][:8].lower())
    os.makedirs(OFFICE_DIR, mode=0o700, exist_ok=True)
    code, out = office_git(["-C", repo, "worktree", "add", "-b", office_branch(task["id"]), copy, "HEAD"])
    if code != 0:
        return out or "git worktree"
    task["branch"], task["base"] = office_branch(task["id"]), base
    task["workdir"] = office_run_folder(task["cwd"], repo, copy)
    return None


def office_copy_root(task):
    return office_repo(task["workdir"]) if task.get("workdir") and os.path.isdir(task["workdir"]) else None


def office_commit_leftovers(task):
    copy = office_copy_root(task)
    if not copy or office_git(["-C", copy, "add", "-A"])[0] != 0:
        return
    if office_git(["-C", copy, "diff", "--cached", "--quiet"])[0] == 1:
        office_git(["-C", copy, "-c", "commit.gpgsign=false", "commit", "-q", "--no-verify",
                    "-m", "%s: %s" % ("Codex" if task.get("agent") == "codex" else "Claude Code", office_title(task))])


def office_title(task):
    line = (task.get("prompt") or "").strip().splitlines()[0] if (task.get("prompt") or "").strip() else ""
    return line if len(line) <= 80 else line[:79] + "…"


def office_changes(task):
    """(files, added, removed) since the task started."""
    copy = office_copy_root(task)
    if not copy or not task.get("base"):
        return [], 0, 0
    code, out = office_git(["-C", copy, "diff", "--numstat", task["base"] + "...HEAD"])
    files, added, removed = [], 0, 0
    for line in (out if code == 0 else "").splitlines():
        parts = line.split("\t", 2)
        if len(parts) == 3:
            added += int(parts[0]) if parts[0].isdigit() else 0
            removed += int(parts[1]) if parts[1].isdigit() else 0
            files.append(parts[2])
    return files, added, removed


def office_tests(folder):
    """Like job_tests, but a fresh copy has no installed JS packages: skipped then."""
    found = detect_tests(folder) if os.path.isdir(folder or "") else None
    if found is None:
        return None
    root, command = found
    if os.path.exists(os.path.join(root, "package.json")) and not os.path.isdir(os.path.join(root, "node_modules")):
        return None
    code, output = run_shell(["bash", "-lc", command], root, TEST_TIMEOUT_SECONDS, env=dict(os.environ, CI="1"))
    return {"tests": "passed" if code == 0 else "failed", "testOutput": command + "\n" + tail_lines(output, 30)}


def office_review(task):
    reviewer = "codex" if task.get("agent") == "claude" else "claude"
    binary = agent_binary(reviewer)
    copy = office_copy_root(task)
    if not binary or not copy or not task.get("base"):
        return None
    code, diff = office_git(["-C", copy, "diff", task["base"] + "...HEAD"])
    if code != 0 or not diff:
        return None
    code, output = run_shell([binary] + review_arguments(reviewer, review_prompt(task.get("agent"), task.get("prompt"),
                                                                                  diff[:120000])),
                             copy, REVIEW_TIMEOUT_SECONDS)
    output = output.strip()
    return {"reviewer": reviewer, "review": output[:6000]} if code == 0 and output else None


def office_arguments(task, prompt, resume=None):
    """Mirrors Office.arguments / reworkArguments (careful policy via the environment)."""
    if task.get("agent") == "codex":
        return ["exec", "--sandbox", "workspace-write", "--skip-git-repo-check"] \
            + (["resume", resume] if resume else []) + [prompt]
    arguments = ["-p", prompt] + (["--resume", resume, "--fork-session"] if resume else []) \
        + ["--permission-mode", "acceptEdits"]
    budget = task.get("budgetUSD")
    if isinstance(budget, (int, float)) and budget > 0:
        arguments += ["--max-budget-usd", "%.2f" % budget]
    return arguments


def office_start_process(task, prompt, resume=None):
    binary = agent_binary(task.get("agent"))
    folder = task.get("workdir") or task.get("cwd")
    if not binary or not os.path.isdir(folder or ""):
        return None, "not found"
    if resume is not None and not valid_session(resume):
        return None, "bad session"
    try:
        os.makedirs(os.path.dirname(office_log(task)), mode=0o700, exist_ok=True)
        with open(office_log(task), "w") as log:  # the agent's output: why a run failed
            process = subprocess.Popen(["nice", "-n", "5", "bash", "-lc", '"$0" "$@"', binary]
                                       + office_arguments(task, prompt, resume),
                                       cwd=folder, env=dict(os.environ, **{NIGHT_ENV: task["id"]}),
                                       stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
    except OSError as error:
        return None, str(error)
    return process, None


def office_log(task):
    return os.path.join(BASE_DIR, "office-logs", task["id"] + ".log")


def office_failure_reason(task, code):
    """Mirrors Office.failureReason: the last lines the agent printed."""
    try:
        with open(office_log(task), errors="replace") as handle:
            lines = [line.strip() for line in handle.read().splitlines() if line.strip()]
    except OSError:
        lines = []
    tail = " · ".join(lines[-3:])
    return "exit %s: %s" % (code, tail[-300:]) if tail else "exit %s" % code


def office_result(task, state, **extra):
    result = {"id": str(uuid.uuid4()), "kind": "office", "task": task["id"], "state": state}
    result.update({key: value for key, value in extra.items() if value is not None})
    add_result(result)


def office_finish(task, code, stopped_reason=None):
    """After the agent exits (blocking: tests and review can take minutes).
    Reports and returns the new state."""
    office_commit_leftovers(task)
    files, added, removed = office_changes(task)
    extra = {"files": files, "added": added, "removed": removed}
    if code == 0:
        extra.update(office_tests(task.get("workdir") or task.get("cwd")) or {})
        if task.get("review"):
            extra.update(office_review(task) or {})
        office_result(task, "review", **extra)
        return "review"
    office_result(task, "failed", output=stopped_reason or office_failure_reason(task, code), **extra)
    return "failed"


OFFICE_LOCK = threading.Lock()
OFFICE_SESSIONS = os.path.join(BASE_DIR, "office-sessions.json")


def office_update(task_id, change):
    """Read-modify-write of one task under the lock (the main loop and the
    finishing thread both write)."""
    with OFFICE_LOCK:
        tasks = load_json_list(OFFICE_PATH)
        for task in tasks:
            if task.get("id") == task_id:
                change(task)
        office_save(tasks)
        return tasks


def remember_office_session(task_id, session_id):
    """The hook of an Office run notes its session (for the Codex budget)."""
    if not task_id or not isinstance(session_id, str) or not session_id:
        return
    try:
        with open(OFFICE_SESSIONS) as handle:
            sessions = json.load(handle)
        if not isinstance(sessions, dict):
            sessions = {}
    except (OSError, ValueError):
        sessions = {}
    if sessions.get(task_id) == session_id:
        return
    sessions[task_id] = session_id
    keep = dict(list(sessions.items())[-100:])
    os.makedirs(BASE_DIR, mode=0o700, exist_ok=True)
    descriptor, temp = tempfile.mkstemp(prefix="office-sessions.", suffix=".tmp", dir=BASE_DIR)
    with os.fdopen(descriptor, "w") as handle:
        json.dump(keep, handle)
    os.replace(temp, OFFICE_SESSIONS)


def office_session(task_id):
    try:
        with open(OFFICE_SESSIONS) as handle:
            return json.load(handle).get(task_id)
    except (OSError, ValueError, AttributeError):
        return None


def office_decide(task, accept):
    """Accept (merge into what the project has checked out) or throw away."""
    repo = office_repo(task.get("cwd") or "") if os.path.isdir(task.get("cwd") or "") else None
    branch = task.get("branch")
    if not branch or not repo:
        task["state"] = "accepted" if accept else "discarded"
        office_result(task, task["state"])
        return
    copy = office_copy_root(task)
    if accept:
        office_commit_leftovers(task)
        code, out = office_git(["-C", repo, "-c", "commit.gpgsign=false", "merge", "--no-ff",
                                "-m", "%s: %s" % ("Codex" if task.get("agent") == "codex" else "Claude Code",
                                                  office_title(task)), branch])
        if code != 0:
            office_git(["-C", repo, "merge", "--abort"])
            office_result(task, "acceptFailed", output=(out or "git merge")[:1000])
            return
    if copy:
        office_git(["-C", repo, "worktree", "remove", "--force", copy])
    office_git(["-C", repo, "branch", "-d" if accept else "-D", branch])
    task["state"] = "accepted" if accept else "discarded"
    office_result(task, task["state"])


def office_interrupted(tasks):
    """A task saved as running whose worker is gone: say so, never rerun it."""
    for task in tasks:
        if task.get("state") == "running":
            task["state"] = "failed"
            office_result(task, "failed", output="interrupted: the server or its worker restarted")
    return tasks


def office_save(tasks):
    open_ = [task for task in tasks if task.get("state") in ("queued", "running", "review", "failed")]
    done = [task for task in tasks if task not in open_]
    save_json_list(OFFICE_PATH, open_ + done[-OFFICE_KEEP:])


def office_budget_exceeded(task):
    """Codex has no prices: stop at the token budget (input + output + cache writes)."""
    limit = task.get("budgetTokens")
    if task.get("agent") != "codex" or not isinstance(limit, int) or limit <= 0:
        return False
    session = office_session(task.get("id"))
    if not session:
        return False
    try:
        usage = codex_turn_usage(codex_rollout({"session_id": session}))
    except Exception:
        return False
    used = sum(item.get("input", 0) + item.get("output", 0) + item.get("cacheWrite5m", 0) + item.get("cacheWrite1h", 0)
               for item in usage or [])
    return used > limit


def next_heavy(queue, nights, busy, running, now, office=()):
    """What may start now, if anything: ("job", job), ("office", task) or
    ("night", job). One heavy thing at a time -- tests, a review, an Office
    task or a night agent -- since they share the server's memory. Tests go
    first, then the Office; a due night job waits for both."""
    if busy or running:
        return None
    if queue:
        return "job", queue[0]
    for task in office:
        if task.get("state") == "queued":
            return "office", task
    for job in nights:
        if night_due(job, now):
            return "night", job
    return None


def office_take(job, office, running):
    """An Office job from the Mac, applied to the task list (under OFFICE_LOCK)."""
    kind = job.get("kind")
    if kind == "office":
        if not any(task.get("id") == job["id"] for task in office):
            office.append({"id": job["id"], "agent": job.get("agent") or "claude", "cwd": job.get("cwd"),
                           "prompt": job.get("prompt") or "", "review": bool(job.get("review")),
                           "budgetUSD": job.get("budgetUSD"), "budgetTokens": job.get("budgetTokens"),
                           "state": "queued", "created": time.time()})
        return
    task = next((item for item in office if item.get("id") == job.get("target")), None)
    if task is None:
        return
    if kind == "officeRework" and task.get("state") in ("review", "failed"):
        task["rework"] = {"prompt": job.get("prompt") or "", "resume": job.get("resume")}
        task["budgetUSD"], task["budgetTokens"] = job.get("budgetUSD"), job.get("budgetTokens")
        task["review"] = bool(job.get("review"))
        task["state"] = "queued"
    elif kind in ("officeAccept", "officeDiscard") and task.get("state") in ("review", "failed"):
        office_decide(task, kind == "officeAccept")
    elif kind == "cancel":
        if task.get("state") == "queued":
            task["state"] = "discarded"
        elif task["id"] in running:
            task["stopReason"] = "stopped"
            running[task["id"]][0].terminate()


def run_worker():
    os.makedirs(BASE_DIR, mode=0o700, exist_ok=True)
    lock = open(WORKER_LOCK, "a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0
    running = {}
    office_running = {}
    busy = threading.Event()
    seen = load_json_list(SEEN_PATH)
    received = []
    save_json_list(NIGHT_PATH, interrupted_nights(load_json_list(NIGHT_PATH)))
    with OFFICE_LOCK:
        office_save(office_interrupted(load_json_list(OFFICE_PATH)))
    budget_checked = 0

    def work(job):
        try:
            handler = {"tests": job_tests, "review": job_review, "lines": job_lines}.get(job.get("kind"))
            result = handler(job) if handler else {"state": "failed", "output": "unknown job"}
        except Exception as error:  # a broken job must not stop the worker
            result = {"state": "failed", "output": str(error)}
        result.update({"id": job["id"], "kind": job["kind"]})
        add_result(result)
        save_json_list(QUEUE_PATH, [item for item in load_json_list(QUEUE_PATH) if item.get("id") != job["id"]])
        busy.clear()

    def finish_office(task, code, reason):
        try:
            state = office_finish(task, code, reason)
        except Exception as error:
            state = "failed"
            office_result(task, "failed", output=str(error))
        office_update(task["id"], lambda item: item.update(state=state, rework=None, stopReason=None))
        busy.clear()

    started = time.time()
    while True:
        config = load_config()
        if config is None:
            return 0
        now = time.time()
        jobs = None
        try:
            pending = load_json_list(RESULTS_PATH)
            jobs = ask_for_jobs(config[0], config[1], pending, received)
            if jobs is not None:
                if pending:
                    drop_delivered_results({(item.get("id"), item.get("state")) for item in pending})
                # Store every new job first, then remember its id, then
                # acknowledge it on the next request -- a lost reply only
                # means the Mac sends it again and it's recognised here.
                nights = load_json_list(NIGHT_PATH)
                queue = load_json_list(QUEUE_PATH)
                with OFFICE_LOCK:
                    office = load_json_list(OFFICE_PATH)
                    office_ids = {task.get("id") for task in office}
                    for job in jobs:
                        if job["id"] in seen:
                            continue
                        kind = job.get("kind") or ""
                        if kind == "night":
                            job["state"] = "waiting"
                            nights.append(job)
                            add_result({"id": job["id"], "kind": "night", "state": "queued"})
                        elif kind.startswith("office") or (kind == "cancel" and job.get("target") in office_ids):
                            office_take(job, office, office_running)
                        elif kind == "cancel":
                            for item in nights:
                                if item.get("id") == job.get("target") and item.get("state") in ("waiting", "running"):
                                    item["state"] = "cancelled"
                                    if item["id"] in running:
                                        running[item["id"]][0].terminate()
                        else:
                            queue.append(job)
                    office_save(office)
                save_json_list(NIGHT_PATH, nights)
                save_json_list(QUEUE_PATH, queue)
                seen = (seen + [job["id"] for job in jobs if job["id"] not in seen])[-SEEN_KEEP:]
                save_json_list(SEEN_PATH, seen)
                received = [job["id"] for job in jobs]
            nights = load_json_list(NIGHT_PATH)
            queue = load_json_list(QUEUE_PATH)
            office = load_json_list(OFFICE_PATH)
            heavy = next_heavy(queue, nights, busy.is_set(), running or office_running, now, office)
            if heavy and heavy[0] == "job":
                busy.set()
                threading.Thread(target=work, args=(heavy[1],), daemon=True).start()
            elif heavy and heavy[0] == "office":
                task = heavy[1]
                rework = task.get("rework") or {}
                error = None if task.get("branch") or task.get("workdir") else office_prepare(task)
                process = None
                if error is None:
                    process, error = office_start_process(task, rework.get("prompt") or task.get("prompt") or "",
                                                          rework.get("resume"))
                if process is None:
                    office_result(task, "failed", output=error)
                    fields = {"state": "failed"}
                else:
                    office_running[task["id"]] = (process, now)
                    office_result(task, "running")
                    fields = {"state": "running"}
                fields.update({key: task.get(key) for key in ("branch", "base", "workdir")})
                office_update(task["id"], lambda item: item.update(fields))
            elif heavy:
                job = heavy[1]
                process, error = start_night_job(job)
                if process is None:
                    job["state"] = "failed"
                    add_result({"id": job["id"], "kind": "night", "state": "failed", "output": error})
                else:
                    job["state"] = "running"
                    running[job["id"]] = (process, now)
                    add_result({"id": job["id"], "kind": "night", "state": "running"})
            check_budget = now - budget_checked > 30
            if check_budget:
                budget_checked = now
            for task_id, (process, since) in list(office_running.items()):
                task = next((item for item in load_json_list(OFFICE_PATH) if item.get("id") == task_id), {"id": task_id})
                if process.poll() is None and now - since > NIGHT_TIMEOUT_SECONDS:
                    task["stopReason"] = "stopped after 3 hours"
                    office_update(task_id, lambda item: item.update(stopReason="stopped after 3 hours"))
                    process.terminate()
                elif process.poll() is None and check_budget and office_budget_exceeded(task):
                    office_update(task_id, lambda item: item.update(stopReason="over budget"))
                    process.terminate()
                if process.poll() is not None:
                    del office_running[task_id]
                    busy.set()  # tests and the review run next, in the same slot
                    code = process.returncode
                    threading.Thread(target=finish_office, args=(task, code, task.get("stopReason")), daemon=True).start()
            for job_id, (process, since) in list(running.items()):
                if process.poll() is None and now - since > NIGHT_TIMEOUT_SECONDS:
                    process.terminate()
                if process.poll() is not None:
                    del running[job_id]
                    code = process.returncode
                    for job in nights:
                        if job.get("id") == job_id and job.get("state") == "running":
                            job["state"] = "done" if code == 0 else "failed"
                            add_result({"id": job_id, "kind": "night", "state": job["state"],
                                        "output": None if code == 0 else "exit %s" % code})
            save_json_list(NIGHT_PATH, [job for job in nights if job.get("state") in ("waiting", "running")]
                           + [job for job in nights if job.get("state") not in ("waiting", "running")][-20:])
        except Exception:  # one bad turn (a full disk, a broken file) must not end the worker
            nights, queue = load_json_list(NIGHT_PATH), load_json_list(QUEUE_PATH)
            office = load_json_list(OFFICE_PATH)
        try:
            activity = os.path.getmtime(ACTIVITY_STAMP)
        except OSError:
            activity = started
        waiting = any(job.get("state") in ("waiting", "running") for job in nights) \
            or any(task.get("state") in ("queued", "running") for task in office)
        if not waiting and not queue and not busy.is_set() and not running and not office_running \
                and not load_json_list(RESULTS_PATH) and now - max(activity, started) > WORKER_IDLE_SECONDS:
            return 0
        time.sleep(3 if jobs is not None else 15)


# ---------------------------------------------------------------- usage report
#
# Token counts are bucketed per UTC hour, agent and model, so the Mac can
# group them into its own local days. Only counters, model names and times are
# kept; prompts, answers and file contents are never read into the state.

def parse_time(text):
    """ISO 8601 (with Z or offset) -> epoch seconds, or None."""
    if not isinstance(text, str) or len(text) < 19:
        return None
    try:
        base = time.strptime(text[:19], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None
    seconds = calendar.timegm(base)
    rest = text[19:]
    if "." in rest[:1]:
        digits = ""
        for char in rest[1:]:
            if not char.isdigit():
                break
            digits += char
        rest = rest[1 + len(digits):]
    if rest[:1] in ("+", "-") and len(rest) >= 6:
        sign = 1 if rest[0] == "+" else -1
        try:
            seconds -= sign * (int(rest[1:3]) * 3600 + int(rest[4:6]) * 60)
        except ValueError:
            pass
    return seconds


def as_int(value):
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else 0


def empty_state():
    return {"version": 1, "files": {}, "buckets": {}, "recent": {}, "recentOrder": [],
            "codexLimits": None, "activity": {}}


def load_state():
    try:
        with open(STATE_PATH) as handle:
            state = json.load(handle)
        if state.get("version") == 1:
            return state
    except (OSError, ValueError):
        pass
    return empty_state()


def save_state(state):
    os.makedirs(BASE_DIR, mode=0o700, exist_ok=True)
    temporary = STATE_PATH + ".tmp"
    with open(temporary, "w") as handle:
        json.dump(state, handle, separators=(",", ":"))
    os.replace(temporary, STATE_PATH)


def project_name(cwd):
    return os.path.basename(cwd.rstrip("/")) if isinstance(cwd, str) and cwd.strip("/") else ""


def add_tokens(state, agent, model, when, tokens, project=""):
    if not any(tokens):
        return
    hour = int(when // 3600 * 3600)
    key = "%d|%s|%s|%s" % (hour, agent, project.replace("|", "/"), model)
    bucket = state["buckets"].setdefault(key, [0, 0, 0, 0, 0])
    for index, value in enumerate(tokens):
        bucket[index] += value
    previous = state["activity"].get(agent, 0)
    state["activity"][agent] = max(previous, when)


def claude_line(state, line):
    """One assistant line of a Claude Code transcript. Streamed replies log
    the same request several times; only growth over the largest reading
    seen for that request is counted."""
    try:
        entry = json.loads(line)
    except ValueError:
        return
    if not isinstance(entry, dict) or entry.get("type") != "assistant":
        return
    message = entry.get("message")
    if not isinstance(message, dict):
        return
    usage = message.get("usage")
    model = message.get("model")
    if not isinstance(usage, dict) or not isinstance(model, str) or not model or model.startswith("<"):
        return
    when = parse_time(entry.get("timestamp"))
    if when is None:
        return
    split = usage.get("cache_creation") if isinstance(usage.get("cache_creation"), dict) else {}
    write_total = as_int(usage.get("cache_creation_input_tokens"))
    write_1h = as_int(split.get("ephemeral_1h_input_tokens"))
    write_5m = as_int(split.get("ephemeral_5m_input_tokens"))
    if write_1h + write_5m < write_total:
        write_5m = write_total - write_1h
    reading = [as_int(usage.get("input_tokens")), write_5m, write_1h,
               as_int(usage.get("cache_read_input_tokens")), as_int(usage.get("output_tokens"))]
    project = project_name(entry.get("cwd"))
    key = entry.get("requestId") or message.get("id")
    if not isinstance(key, str) or not key:
        add_tokens(state, "claude", model, when, reading, project)
        return
    seen = state["recent"].get(key)
    if seen is None:
        state["recent"][key] = reading
        state["recentOrder"].append(key)
        if len(state["recentOrder"]) > RECENT_KEYS:
            for old in state["recentOrder"][:-RECENT_KEYS]:
                state["recent"].pop(old, None)
            state["recentOrder"] = state["recentOrder"][-RECENT_KEYS:]
        add_tokens(state, "claude", model, when, reading, project)
        return
    delta = [max(0, new - old) for new, old in zip(reading, seen)]
    state["recent"][key] = [max(new, old) for new, old in zip(reading, seen)]
    add_tokens(state, "claude", model, when, delta, project)


def codex_window(limit, observed):
    if not isinstance(limit, dict):
        return None
    percent = limit.get("used_percent")
    if not isinstance(percent, (int, float)) or isinstance(percent, bool):
        return None
    minutes = limit.get("window_minutes")
    resets = limit.get("resets_at")
    if not isinstance(resets, (int, float)) or isinstance(resets, bool):
        seconds = limit.get("resets_in_seconds")
        resets = observed + seconds if isinstance(seconds, (int, float)) and not isinstance(seconds, bool) else None
    kind = "session" if isinstance(minutes, int) and minutes <= 360 else "weekly"
    return {"kind": kind, "label": None, "percent": float(min(100, max(0, percent))),
            "resetsAt": float(resets) if resets else None}


def codex_plan_name(plan):
    if not isinstance(plan, str) or not plan:
        return None
    return CODEX_PLANS.get(plan.lower(), plan.replace("_", " ").title())


def codex_line(state, file_state, line):
    try:
        entry = json.loads(line)
    except ValueError:
        return
    if not isinstance(entry, dict):
        return
    payload = entry.get("payload")
    if not isinstance(payload, dict):
        return
    if entry.get("type") == "turn_context":
        if isinstance(payload.get("model"), str):
            file_state["model"] = payload["model"]
        if isinstance(payload.get("cwd"), str):
            file_state["project"] = project_name(payload["cwd"])
        return
    if entry.get("type") != "event_msg" or payload.get("type") != "token_count":
        return
    when = parse_time(entry.get("timestamp"))
    if when is None:
        return
    info = payload.get("info")
    totals = info.get("total_token_usage") if isinstance(info, dict) else None
    if isinstance(totals, dict):
        current = [as_int(totals.get("input_tokens")), as_int(totals.get("cached_input_tokens")),
                   as_int(totals.get("output_tokens")), as_int(totals.get("cache_write_input_tokens"))]
        previous = file_state.get("totals") or [0, 0, 0, 0]
        if any(now < before for now, before in zip(current, previous)):
            previous = [0, 0, 0, 0]
        delta = [now - before for now, before in zip(current, previous)]
        file_state["totals"] = current
        cached = min(delta[1], delta[0])
        # OpenAI counts cached tokens inside input_tokens.
        add_tokens(state, "codex", file_state.get("model") or "codex", when,
                   [delta[0] - cached, delta[3], 0, cached, delta[2]], file_state.get("project", ""))
    limits = payload.get("rate_limits")
    if isinstance(limits, dict):
        known = state.get("codexLimits") or {}
        if when >= known.get("observedAt", 0):
            windows = [w for w in (codex_window(limits.get("primary"), when),
                                   codex_window(limits.get("secondary"), when)) if w]
            if not windows:
                return
            plan = limits.get("plan_type")
            state["codexLimits"] = {"agent": "codex", "observedAt": float(when), "windows": windows,
                                    "plan": codex_plan_name(plan), "planRaw": plan}


def scan_file(state, path, agent, now):
    try:
        stat = os.stat(path)
    except OSError:
        return
    if now - stat.st_mtime > KEEP_SECONDS:
        return
    file_state = state["files"].setdefault(path, {"offset": 0})
    if stat.st_size < file_state.get("offset", 0):
        file_state.clear()
        file_state["offset"] = 0
    if stat.st_size == file_state["offset"]:
        return
    marker = b'"usage"' if agent == "claude" else None
    with open(path, "rb") as handle:
        handle.seek(file_state["offset"])
        position = file_state["offset"]
        for raw in handle:
            if not raw.endswith(b"\n"):
                break
            position += len(raw)
            if agent == "claude":
                if marker in raw:
                    claude_line(state, raw)
            elif b"token_count" in raw or b"turn_context" in raw:
                codex_line(state, file_state, raw)
        file_state["offset"] = position


def prune(state, now):
    cutoff = now - KEEP_SECONDS
    state["buckets"] = {key: value for key, value in state["buckets"].items()
                        if int(key.split("|", 1)[0]) >= cutoff}
    state["files"] = {path: value for path, value in state["files"].items() if os.path.exists(path)}


def claude_limits():
    """Plan and limits Claude Code caches in ~/.claude.json, refreshed with
    the Claude desktop app's own readings when it is installed (Mac)."""
    result = None
    try:
        with open(CLAUDE_JSON) as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        data = {}
    account = data.get("oauthAccount") if isinstance(data.get("oauthAccount"), dict) else {}
    plan = PLAN_NAMES.get(account.get("organizationType"))
    tier = str(account.get("organizationRateLimitTier") or "")
    if plan == "Max":
        plan = "Max 20x" if "20x" in tier else ("Max 5x" if "5x" in tier else plan)
    cached = data.get("cachedUsageUtilization") if isinstance(data.get("cachedUsageUtilization"), dict) else {}
    utilization = cached.get("utilization") if isinstance(cached.get("utilization"), dict) else {}
    windows = []
    for limit in utilization.get("limits") or []:
        if not isinstance(limit, dict) or not isinstance(limit.get("percent"), (int, float)):
            continue
        kind = limit.get("kind") or ""
        group = limit.get("group") or ""
        label = None
        if kind.startswith("weekly_") and kind != "weekly_all":
            label = kind[len("weekly_"):].capitalize()
        windows.append({"kind": "session" if group == "session" else ("weekly" if group == "weekly" else "other"),
                        "label": label, "percent": float(limit["percent"]),
                        "resetsAt": parse_time(limit.get("resets_at"))})
    if not windows:
        for key, kind in (("five_hour", "session"), ("seven_day", "weekly")):
            window = utilization.get(key)
            if isinstance(window, dict) and isinstance(window.get("utilization"), (int, float)):
                windows.append({"kind": kind, "label": None, "percent": float(window["utilization"]),
                                "resetsAt": parse_time(window.get("resets_at"))})
    fetched = cached.get("fetchedAtMs")
    if windows or plan:
        result = {"agent": "claude", "plan": plan, "windows": windows,
                  "observedAt": fetched / 1000.0 if isinstance(fetched, (int, float)) else 0.0}
    result = merge_claude_app(result, plan)
    live = statusline_limits()
    if live and (not result or live["observedAt"] >= result["observedAt"]):
        result = {"agent": "claude", "plan": plan, "windows": live["windows"], "observedAt": live["observedAt"]}
    if result:
        result["planPrice"] = CLAUDE_PLAN_PRICES.get(result.get("plan"))
    return result


def merge_claude_app(result, plan):
    try:
        with open(CLAUDE_APP_HISTORY) as handle:
            history = json.load(handle)
        samples = history.get("samples") or []
        last = max((s for s in samples if isinstance(s, dict) and isinstance(s.get("t"), (int, float))),
                   key=lambda s: s["t"])
    except (OSError, ValueError, AttributeError, TypeError):
        return result
    observed = last["t"] / 1000.0
    if result and result["observedAt"] >= observed:
        return result
    values = last.get("u") if isinstance(last.get("u"), dict) else last
    resets = {}
    for window in (result or {}).get("windows", []):
        resets[(window["kind"], window["label"])] = window["resetsAt"]
    windows = []
    for key, kind, label in (("fh", "session", None), ("sd", "weekly", None),
                             ("so", "weekly", "Opus"), ("sn", "weekly", "Sonnet")):
        value = values.get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            windows.append({"kind": kind, "label": label, "percent": float(min(100, max(0, value))),
                            "resetsAt": resets.get((kind, label))})
    if not windows:
        return result
    return {"agent": "claude", "plan": plan, "windows": windows, "observedAt": observed}


def system_load():
    """Load, memory and swap of this server (Linux /proc); None elsewhere."""
    try:
        with open("/proc/loadavg") as handle:
            load = [float(x) for x in handle.read().split()[:3]]
        meminfo = {}
        with open("/proc/meminfo") as handle:
            for line in handle:
                key, _, rest = line.partition(":")
                parts = rest.split()
                if parts:
                    meminfo[key] = int(parts[0]) * 1024
        with open("/proc/uptime") as handle:
            uptime = float(handle.read().split()[0])
    except (OSError, ValueError, IndexError):
        return None
    return {"load1": load[0], "load5": load[1], "load15": load[2], "cpus": os.cpu_count() or 1,
            "memTotal": meminfo.get("MemTotal", 0), "memAvailable": meminfo.get("MemAvailable", 0),
            "swapTotal": meminfo.get("SwapTotal", 0),
            "swapUsed": max(0, meminfo.get("SwapTotal", 0) - meminfo.get("SwapFree", 0)),
            "uptime": uptime}


def build_report(now=None, wait=True):
    """None when another scan holds the lock and wait is False."""
    now = now or time.time()
    os.makedirs(BASE_DIR, mode=0o700, exist_ok=True)
    with open(LOCK_PATH, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX if wait else fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return None
        state = load_state()
        for path in glob.glob(os.path.join(CLAUDE_PROJECTS, "**", "*.jsonl"), recursive=True):
            scan_file(state, path, "claude", now)
        for path in glob.glob(os.path.join(CODEX_SESSIONS, "**", "*.jsonl"), recursive=True):
            scan_file(state, path, "codex", now)
        prune(state, now)
        refresh_codex_account(state, now)
        save_state(state)
    usage = []
    for key, tokens in state["buckets"].items():
        parts = key.split("|", 3)
        if len(parts) == 3:  # saved before projects were tracked
            hour, agent, model = parts
            project = ""
        else:
            hour, agent, project, model = parts
        item = {"hour": float(hour), "agent": agent, "model": model, "project": project}
        item.update(dict(zip(FIELDS, tokens)))
        usage.append(item)
    codex = state.get("codexLimits")
    if codex:
        raw = codex.get("planRaw") or (codex.get("plan") or "").replace(" ", "").lower()
        codex = dict(codex, planPrice=CODEX_PLAN_PRICES.get({"pro$100": "prolite", "pro$200": "pro"}.get(raw, raw)))
        codex.pop("planRaw", None)
    if codex and codex.get("plan"):
        # Saved by an older version as a raw name like "Prolite".
        raw = codex["plan"].replace(" ", "").lower()
        codex = dict(codex, plan=codex_plan_name({"prolite": "prolite", "pro$100": "prolite",
                                                  "pro$200": "pro", "promax": "promax"}.get(raw, raw)))
    limits = [entry for entry in (claude_limits(), codex) if entry]
    resets = [state["codexResets"]] if state.get("codexResets") else []
    report = {"host": socket.gethostname(), "generatedAt": now, "usage": usage, "limits": limits,
              "activity": [{"agent": agent, "at": float(at)} for agent, at in state["activity"].items()],
              "resets": resets}
    system = system_load()
    if system:
        report["system"] = system
    return report


def send_report_in_background(port, token):
    """Detach so the agent never waits on a log scan."""
    try:
        if time.time() - os.path.getmtime(REPORT_STAMP) < REPORT_INTERVAL_SECONDS:
            return
    except OSError:
        pass
    try:
        with open(REPORT_STAMP, "w"):
            pass
        if os.fork() > 0:
            return
        os.setsid()
        if os.fork() > 0:
            os._exit(0)
        null = os.open(os.devnull, os.O_RDWR)
        for descriptor in (0, 1, 2):
            os.dup2(null, descriptor)
        try:
            report = build_report(wait=False)
            if report is None:
                os._exit(0)
            event = {"agent": "claude", "name": "Other", "sessionId": "usage-report", "host": report["host"]}
            conn = connect(port)
            if conn is not None:
                request = {"version": 1, "id": str(uuid.uuid4()), "event": event, "wantsDecision": False,
                           "token": token, "report": report}
                conn.sendall((json.dumps(request) + "\n").encode())
                conn.close()
        finally:
            os._exit(0)
    except OSError:
        return


# ---------------------------------------------------------------- codex account
#
# `codex app-server` speaks JSON-RPC over stdio and answers with the account's
# live limits and banked reset credits. Codex signs in by itself; Denny never
# sees its credentials.

def codex_binary():
    found = shutil.which("codex")
    if found:
        return found
    for path in CODEX_CANDIDATES:
        if os.access(path, os.X_OK):
            return path
    return None


def codex_rpc(method, params, timeout=15, binary=None):
    """One request to a fresh app-server. Returns the result dict or None."""
    binary = binary or codex_binary()
    if not binary:
        return None
    try:
        process = subprocess.Popen([binary, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL)
    except OSError:
        return None
    deadline = time.time() + timeout
    try:
        def send(message):
            process.stdin.write((json.dumps(message) + "\n").encode())
            process.stdin.flush()

        def wait_for(request_id):
            while time.time() < deadline:
                line = process.stdout.readline()
                if not line:
                    return None
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if isinstance(message, dict) and message.get("id") == request_id:
                    return message
            return None

        send({"id": 1, "method": "initialize",
              "params": {"clientInfo": {"name": "denny-for-agents", "version": "0.1.0"}}})
        if wait_for(1) is None:
            return None
        send({"method": "initialized"})
        send({"id": 2, "method": method, "params": params})
        reply = wait_for(2)
        if not reply or not isinstance(reply.get("result"), dict):
            return None
        return reply["result"]
    except (OSError, ValueError):
        return None
    finally:
        try:
            process.kill()
            process.wait(timeout=2)
        except (OSError, subprocess.TimeoutExpired):
            pass


def codex_account_window(window, kind_hint):
    if not isinstance(window, dict) or not isinstance(window.get("usedPercent"), (int, float)):
        return None
    minutes = window.get("windowDurationMins")
    kind = "session" if isinstance(minutes, int) and minutes <= 360 else kind_hint
    resets = window.get("resetsAt")
    return {"kind": kind, "label": None, "percent": float(min(100, max(0, window["usedPercent"]))),
            "resetsAt": float(resets) if isinstance(resets, (int, float)) and not isinstance(resets, bool) else None}


def refresh_codex_account(state, now, binary=None):
    """Live limits and reset credits, at most every few minutes."""
    if now - state.get("codexAccountAt", 0) < CODEX_ACCOUNT_INTERVAL:
        return
    state["codexAccountAt"] = now
    result = codex_rpc("account/rateLimits/read", None, binary=binary)
    if not result:
        return
    snapshot = (result.get("rateLimitsByLimitId") or {}).get("codex") or result.get("rateLimits") or {}
    windows = [w for w in (codex_account_window(snapshot.get("primary"), "weekly"),
                           codex_account_window(snapshot.get("secondary"), "weekly")) if w]
    if windows:
        state["codexLimits"] = {"agent": "codex", "observedAt": float(now), "windows": windows,
                                "plan": codex_plan_name(snapshot.get("planType")), "planRaw": snapshot.get("planType")}
    credits = result.get("rateLimitResetCredits")
    if isinstance(credits, dict):
        expiring = [c.get("expiresAt") for c in credits.get("credits") or []
                    if isinstance(c, dict) and isinstance(c.get("expiresAt"), (int, float))]
        state["codexResets"] = {"agent": "codex", "available": int(credits.get("availableCount") or 0),
                                "nextExpiresAt": float(min(expiring)) if expiring else None,
                                "observedAt": float(now), "host": socket.gethostname()}


def codex_reset():
    """Spends one reset credit. Prints {"outcome": ...}."""
    result = codex_rpc("account/rateLimitResetCredit/consume", {"idempotencyKey": str(uuid.uuid4())}, timeout=30)
    outcome = result.get("outcome") if result else None
    if outcome:
        try:
            with open(LOCK_PATH, "w") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                state = load_state()
                state["codexAccountAt"] = 0
                save_state(state)
        except OSError:
            pass
    return {"outcome": outcome or "failed"}


# ---------------------------------------------------------------- status line
#
# Claude Code hands its status line command fresh plan limits after every
# response (rate_limits.five_hour / seven_day, Pro and Max plans). Denny keeps
# them and still runs the user's own status line, if there was one.

def short_span(seconds):
    minutes = max(0, int(seconds // 60))
    if minutes >= 1440:
        return "%dd%dh" % (minutes // 1440, minutes % 1440 // 60)
    if minutes >= 60:
        return "%dh%02dm" % (minutes // 60, minutes % 60)
    return "%dm" % minutes


def run_statusline(raw, now=None):
    now = now or time.time()
    try:
        data = json.loads(raw or b"{}")
    except ValueError:
        data = {}
    limits = data.get("rate_limits") if isinstance(data, dict) else None
    if isinstance(limits, dict):
        record = {"observedAt": now}
        for key in ("five_hour", "seven_day"):
            window = limits.get(key)
            if isinstance(window, dict) and isinstance(window.get("used_percentage"), (int, float)):
                record[key] = {"percent": float(window["used_percentage"]),
                               "resetsAt": window.get("resets_at") if isinstance(window.get("resets_at"), (int, float)) else None}
        try:
            os.makedirs(BASE_DIR, mode=0o700, exist_ok=True)
            temporary = STATUSLINE_PATH + ".tmp"
            with open(temporary, "w") as handle:
                json.dump(record, handle)
            os.replace(temporary, STATUSLINE_PATH)
        except OSError:
            pass
    try:
        with open(STATUSLINE_ORIGINAL) as handle:
            original = json.load(handle).get("command")
    except (OSError, ValueError, AttributeError):
        original = None
    if original:
        try:
            result = subprocess.run(original, shell=True, input=raw, capture_output=True, timeout=5)
            return result.stdout.decode("utf-8", "replace")
        except (OSError, subprocess.TimeoutExpired):
            return ""
    parts = ["Denny"]
    for key, label in (("five_hour", "5h"), ("seven_day", "7d")):
        window = (limits or {}).get(key) if isinstance(limits, dict) else None
        if isinstance(window, dict) and isinstance(window.get("used_percentage"), (int, float)):
            text = "%s %d%%" % (label, round(window["used_percentage"]))
            if isinstance(window.get("resets_at"), (int, float)):
                text += " (%s)" % short_span(window["resets_at"] - now)
            parts.append(text)
    return " · ".join(parts) + "\n"


def statusline_limits():
    try:
        with open(STATUSLINE_PATH) as handle:
            record = json.load(handle)
    except (OSError, ValueError):
        return None
    windows = []
    for key, kind in (("five_hour", "session"), ("seven_day", "weekly")):
        window = record.get(key)
        if isinstance(window, dict) and isinstance(window.get("percent"), (int, float)):
            resets = window.get("resetsAt")
            windows.append({"kind": kind, "label": None, "percent": float(window["percent"]),
                            "resetsAt": float(resets) if isinstance(resets, (int, float)) else None})
    if not windows:
        return None
    return {"observedAt": float(record.get("observedAt") or 0), "windows": windows}


# ---------------------------------------------------------------- install

def command_for(agent):
    return "python3 '%s' %s" % (INSTALLED_SCRIPT.replace("'", "'\\''"), agent)


def is_ours(entry):
    hooks = entry.get("hooks") if isinstance(entry, dict) else None
    if not isinstance(hooks, list):
        return False
    return any(isinstance(h, dict) and MARKER in str(h.get("command", "")) for h in hooks)


def hooks_table(config, agent):
    """Claude keeps hooks under "hooks"; so does Codex since 0.14x. Older Codex
    hooks.json was the table itself (event names at the top level)."""
    table = config.get("hooks")
    if isinstance(table, dict):
        return table
    if agent == "codex":
        return {key: value for key, value in config.items() if key in KNOWN_EVENTS or isinstance(value, list)}
    return {}


def with_hooks_table(config, agent, table):
    config = dict(config)
    if agent == "codex":
        # Drop the old top-level layout: new Codex refuses unknown top-level keys.
        config = {key: value for key, value in config.items() if not (key in KNOWN_EVENTS or isinstance(value, list))}
    if table:
        config["hooks"] = table
    else:
        config.pop("hooks", None)
    return config


def without_ours(table):
    cleaned = {}
    for event, entries in table.items():
        if not isinstance(entries, list):
            cleaned[event] = entries
            continue
        kept = [entry for entry in entries if not is_ours(entry)]
        if kept:
            cleaned[event] = kept
    return cleaned


def statusline_command():
    return "python3 '%s' --statusline" % INSTALLED_SCRIPT.replace("'", "'\\''")


def with_statusline(config):
    """Claude only: our status line in front, the user's kept and chained."""
    config = dict(config)
    current = config.get("statusLine")
    if isinstance(current, dict) and MARKER not in str(current.get("command", "")) and current.get("command"):
        os.makedirs(BASE_DIR, mode=0o700, exist_ok=True)
        with open(STATUSLINE_ORIGINAL, "w") as handle:
            json.dump({"command": current["command"], "settings": current}, handle)
    config["statusLine"] = {"type": "command", "command": statusline_command()}
    return config


def without_statusline(config):
    config = dict(config)
    current = config.get("statusLine")
    if isinstance(current, dict) and MARKER in str(current.get("command", "")):
        try:
            with open(STATUSLINE_ORIGINAL) as handle:
                config["statusLine"] = json.load(handle)["settings"]
        except (OSError, ValueError, KeyError):
            config.pop("statusLine", None)
    return config


def merged(config, agent):
    table = without_ours(hooks_table(config, agent))
    for event in EVENTS[agent]:
        if event == "PermissionRequest":
            timeout = APPROVAL_TIMEOUT_SECONDS
        elif event in ("UserPromptSubmit", "SessionStart"):
            timeout = FILES_WAIT_SECONDS + 5
        elif event == "Stop":
            timeout = REPLY_TIMEOUT_SECONDS
        else:
            timeout = EVENT_TIMEOUT_SECONDS
        table.setdefault(event, []).append(
            {"hooks": [{"type": "command", "command": command_for(agent), "timeout": timeout}]})
    return with_hooks_table(config, agent, table)


def removed(config, agent):
    return with_hooks_table(config, agent, without_ours(hooks_table(config, agent)))


def read_json(path):
    if not os.path.exists(path):
        return {}
    with open(path) as handle:
        text = handle.read()
    if not text.strip():
        return {}
    try:
        data = json.loads(text)
    except ValueError:
        raise SystemExit("Can't parse %s -- left untouched." % path)
    if not isinstance(data, dict):
        raise SystemExit("Unexpected content in %s -- left untouched." % path)
    return data


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        backup = "%s.denny-backup-%d" % (path, int(time.time()))
        if not os.path.exists(backup):
            shutil.copy2(path, backup)
    temporary = path + ".denny-tmp"
    with open(temporary, "w") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")
    os.replace(temporary, path)


def set_port(port):
    """Denny keeps the SSH tunnel itself; when 47321 is still held by a dead
    session it lands on the next port and tells the hook here."""
    try:
        with open(CONFIG_PATH) as handle:
            config = json.load(handle)
    except (OSError, ValueError):
        return 1
    if not isinstance(config, dict) or not 1024 <= port <= 65535:
        return 2
    config["port"] = port
    descriptor = os.open(CONFIG_PATH + ".part", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        json.dump(config, handle)
    os.replace(CONFIG_PATH + ".part", CONFIG_PATH)
    return 0


def install(port, token, agents):
    os.makedirs(BASE_DIR, mode=0o700, exist_ok=True)
    source = os.path.abspath(__file__)
    if source != INSTALLED_SCRIPT:
        shutil.copy2(source, INSTALLED_SCRIPT)
    os.chmod(INSTALLED_SCRIPT, 0o755)
    descriptor = os.open(CONFIG_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        json.dump({"port": port, "token": token}, handle)
    for agent in agents:
        path = CONFIG_FILES[agent]
        config = merged(read_json(path), agent)
        if agent == "claude":
            config = with_statusline(config)
        write_json(path, config)
        print("Connected %s (%s)" % (agent, path))


def install_statusline():
    """Denny on a Mac: hooks are its own, only the status line comes from here."""
    os.makedirs(BASE_DIR, mode=0o700, exist_ok=True)
    source = os.path.abspath(__file__)
    if source != INSTALLED_SCRIPT:
        shutil.copy2(source, INSTALLED_SCRIPT)
    os.chmod(INSTALLED_SCRIPT, 0o755)
    path = CONFIG_FILES["claude"]
    write_json(path, with_statusline(read_json(path)))
    return 0


def uninstall_statusline():
    path = CONFIG_FILES["claude"]
    config = read_json(path)
    status = config.get("statusLine") if isinstance(config.get("statusLine"), dict) else {}
    if MARKER in str(status.get("command", "")):
        write_json(path, without_statusline(config))
    return 0


def uninstall():
    for agent, path in CONFIG_FILES.items():
        config = read_json(path)
        table = hooks_table(config, agent)
        status = config.get("statusLine") if isinstance(config.get("statusLine"), dict) else {}
        ours_status = agent == "claude" and MARKER in str(status.get("command", ""))
        if ours_status or any(isinstance(e, list) and any(is_ours(x) for x in e) for e in table.values()):
            cleaned = removed(config, agent)
            if agent == "claude":
                cleaned = without_statusline(cleaned)
            write_json(path, cleaned)
            print("Disconnected %s (%s)" % (agent, path))


def ping():
    config = load_config()
    if config is None:
        print("Not installed: run --install --port <port> --token <token> first.")
        return 1
    conn = connect(config[0])
    if conn is None:
        print("No connection to Denny on 127.0.0.1:%d. Is the port forwarded (Termius Remote rule / ssh -R) "
              "and Denny for Agents running on your Mac?" % config[0])
        return 1
    conn.close()
    session = "denny-ping-%d" % int(time.time())
    # Start, finish (Denny celebrates), then end so the test row goes away.
    for name, pause in (("SessionStart", 0.3), ("Stop", 2.5), ("SessionEnd", 0)):
        event = {"agent": "claude", "name": name, "sessionId": session, "host": socket.gethostname(),
                 "cwd": "connection-test", "lastAssistantMessage": "Remote connection works"}
        send_request(event, config[0], config[1], False)
        time.sleep(pause)
    try:
        os.remove(REPORT_STAMP)
    except OSError:
        pass
    send_report_in_background(config[0], config[1])
    print("Sent a test event and a usage report -- Denny should jump with joy on your Mac.")
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] in EVENTS:
        try:
            run_hook(argv[1])
        except Exception:
            pass
        return 0
    if "--uninstall" in argv:
        uninstall()
        return 0
    if "--ping" in argv:
        return ping()
    if "--statusline-install" in argv:
        return install_statusline()
    if "--statusline-uninstall" in argv:
        return uninstall_statusline()
    if "--statusline" in argv:
        try:
            raw = sys.stdin.buffer.read()
            sys.stdout.write(run_statusline(raw))
        except Exception:
            pass
        return 0
    if "--codex-reset" in argv:
        sys.stdout.write(json.dumps(codex_reset()) + "\n")
        return 0
    if "--start-worker" in argv:
        # The Mac queued a job for this server: make sure someone takes it.
        start_worker()
        return 0
    if "--worker" in argv:
        try:
            return run_worker()
        except Exception:
            return 0
    if "--clear-snapshots" in argv:
        return clear_snapshots()
    if "--snapshots" in argv:
        return list_snapshots()
    if "--restore" in argv:
        position = argv.index("--restore")
        if position + 1 >= len(argv):
            print(__doc__)
            return 2
        return restore_command(argv[position + 1], "--yes" in argv)
    if "--report" in argv:
        sys.stdout.write(json.dumps(build_report()) + "\n")
        return 0
    if "--set-port" in argv:
        position = argv.index("--set-port")
        try:
            return set_port(int(argv[position + 1]))
        except (IndexError, ValueError):
            print(__doc__)
            return 2

    if "--install" in argv:
        def value(flag):
            if flag in argv and argv.index(flag) + 1 < len(argv):
                return argv[argv.index(flag) + 1]
            return None
        token = value("--token")
        port = int(value("--port") or 47321)
        agents = (value("--agents") or "claude,codex").split(",")
        if not token or any(agent not in EVENTS for agent in agents):
            print(__doc__)
            return 2
        install(port, token, agents)
        return 0
    print(__doc__)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
