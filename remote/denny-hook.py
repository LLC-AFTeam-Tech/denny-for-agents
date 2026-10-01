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
  python3 denny-hook.py claude|codex    # called by the agent itself
"""

import base64
import calendar
import fcntl
import glob
import json
import os
import shutil
import socket
import subprocess
import sys
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
    if event["name"] in ("UserPromptSubmit", "SessionStart"):
        written = receive_files(event, config[0], config[1])
        if written and agent == "claude" and event["name"] == "UserPromptSubmit":
            # Claude Code adds this hook's output to the conversation.
            sys.stdout.write("Denny for Agents delivered from the user's Mac: %s\n" % ", ".join(written))
        if event["name"] == "SessionStart":
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
    if agent == "claude":
        table = config.get("hooks")
        return table if isinstance(table, dict) else {}
    return config


def with_hooks_table(config, agent, table):
    if agent == "claude":
        config = dict(config)
        if table:
            config["hooks"] = table
        else:
            config.pop("hooks", None)
        return config
    return table


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
    if "--report" in argv:
        sys.stdout.write(json.dumps(build_report()) + "\n")
        return 0
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
