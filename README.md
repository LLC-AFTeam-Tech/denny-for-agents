<div align="center">

<img src="docs/media/demo.gif" width="760" alt="Denny in the MacBook notch watching Claude Code and Codex">

# Denny for Agents

**A tiny robot that lives in your MacBook's notch and looks after Claude Code and Codex.**

He watches your agents work, asks before anything risky runs, saves your files before destructive commands,<br>
warns you when an agent goes in circles, and cheers when the job is done. Free, open source, and private by design.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)
![Claude Code](https://img.shields.io/badge/Claude%20Code-supported-D97757)
![Codex](https://img.shields.io/badge/Codex-supported-7A9BFF)
![License: MIT](https://img.shields.io/badge/code-MIT-green)

[**Download**](../../releases/latest) · [Install](#install) · [Agents on a server](#agents-on-an-ssh-server) · [Privacy](#privacy) · [Русская версия](README.ru.md)

</div>

---

## Only in Denny

### 🛡️ The guard
Every permission request is read before you see it. `rm -rf ~`, `curl … | sh`, `git push --force`, `sudo`, anything touching `~/.ssh` or `.env` — Denny flags it in red, puts **Deny** first and plays a warning sound. Safe requests stay calm and green, so the red ones really stand out.

### 🛟 The safety net
Right before an agent runs `rm -rf`, `git reset --hard`, `git clean -f` or `git checkout -- .`, Denny snapshots your files — uncommitted and untracked ones included. Deleted the wrong folder? **Undo** in the notch puts everything back. In a git project the snapshot lives in a hidden ref and never touches your branch, index or stash; files outside git are copied aside. Snapshots are kept for 7 days by default — choose 1, 7 or 30 days and how much space copies may take. Claude Code's own rewind only covers its file edits — not what a shell command wiped out.

### 🌙 Night shift
Your limit ran out at 11 pm and renews at 3 am? Queue the task — on the Mac or on a server, where it runs even if your SSH session drops — and Denny starts the agent by himself the moment the limit renews (or at the time you pick) and keeps the Mac awake. Nobody approves at night, so he plays it safe: edits and safe commands go ahead, anything the guard calls dangerous is refused, the safety net snapshots as usual. In the morning a receipt is waiting, and Telegram tells you it's done. For a server job that message comes once the Mac is in touch with that server again: right away with Denny's own SSH connections, otherwise after the tunnel reconnects.

### 🔁 The relay
Claude hit its plan limit in the middle of a task? Denny offers to hand the work to Codex — or the other way round — and writes the hand-off note for you: what was asked, which files were edited, which commands ran, and the last message. One click copies it, ⌘V continues the task.

### 🌀 "Going in circles"
Running the same command for the third time, editing the same file again and again, or busy for twenty minutes without a single change — Denny notices the loop and taps you on the shoulder before it burns your limit.

## Everything else

**Your agents, live**
- 🤖 Every Claude Code and Codex session in the notch, step by step: what it reads, edits and runs.
- ✅ **Allow / Deny / Ask there** right from the notch. If Denny isn't running, agents ask in the terminal as usual — he never blocks them.
- 🎉 Denny peeks out with a laptop when a task starts and celebrates with a *Task Completed!* when it ends. In between he lives in the notch: looks around, crawls, hides, reacts.
- 🧾 **Task receipt:** when a task ends — how long it took, files changed (+lines −lines), commands run, tokens and what they'd cost at API prices. One click copies it for a post.
- ✅ **Is it really done?** Denny runs your project's tests right after the task — on the Mac or on the server where the agent works — (`swift test`, `npm test`, `cargo test`, `pytest`… or your own in `.denny-test`) and shows ✅ or ❌. Failed? One click copies the output for the agent to fix.
- 👀 **Cross-review:** one click and the other agent reviews what this one just changed — Codex checks Claude, Claude checks Codex — read-only, in the language of your task. Findings show up in the notch, ready to send back to the author.
- 👆 Swipe two fingers on the open notch to flip between the overview and the stats.
- ⏱️ A live number by the camera: the current task's timer while an agent works, your tightest limit at rest.
- 📱 **Approve from your phone.** Away from the Mac? Requests come to Telegram through your own bot with ✅ Allow / ❌ Deny buttons, risky ones flagged by the guard. Paired by a one-time code, so the bot obeys only you.
- 🖥️ **Agents on SSH servers too** — one forwarded port and Denny on your Mac sees the agent on the server, approvals included.

**Limits and money**
- 📊 Session and weekly limits for Claude and Codex with a pace marker and reset times — Claude's are live, refreshed after every reply through Claude Code's status line (your own status line keeps working).
- 💎 **Plan value:** *"$1,240 at API prices on a $20 plan — ×62."* The number people screenshot.
- 📈 Spending at API prices, cache hit rate, a trend chart, top models and projects, a 13-week activity map.
- 🔄 Spend a banked Codex limit reset from the notch, with a confirmation.

**Your Mac**
- ☕ **Keep Awake:** no idle sleep while an agent works — optionally even with the lid closed on the charger.
- 🌡️ **Load:** CPU, memory pressure and swap of your Mac and connected servers, with a warning before a heavy build runs out of memory.
- 📎 **Drop a file on the notch** to paste its path to your agent. If the agent runs on a server, Denny delivers the file there with your next message.
- 🔔 Quiet notifications — only for long tasks, limits crossing a threshold or a daily budget, each once. One click silences Denny for an hour.
- ⬆️ Updates itself from GitHub releases, checked once a day.
- 🌍 10 languages: English, Русский, Українська, Deutsch, Français, Español, Português (Brasil), 简体中文, 日本語, 한국어.

## Install

### Download

1. Get **DennyForAgents.zip** from the [latest release](../../releases/latest).
2. Unzip and move **Denny for Agents.app** to **Applications**.
3. The app isn't notarized by Apple yet. The first time, macOS says it can't check the developer: open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. Only once.

### Homebrew

```bash
brew install --cask LLC-AFTeam-Tech/tap/denny-for-agents
```

### Build from source

macOS 13+ and Xcode 16+ (or the Swift toolchain):

```bash
git clone https://github.com/LLC-AFTeam-Tech/denny-for-agents.git
cd denny-for-agents
swift test
./scripts/build-app.sh
open "dist/Denny for Agents.app"
```

### Updates

Denny checks GitHub once a day and tells you when a new version is out. **Settings → About → Update** downloads it, verifies its SHA-256 checksum, swaps the app and restarts. Installed with Homebrew? Use `brew upgrade denny-for-agents` instead.

## Setup

On first launch Denny offers to connect to your agents. He adds his hooks to `~/.claude/settings.json` and `~/.codex/hooks.json`, saves a backup next to each file and never touches a file he can't parse. Each agent can be switched on or off in **Settings → Agents**.

### Agents on an SSH server

Claude Code or Codex run on a server (say, you work there through Termius or Terminal) and Denny runs on your Mac. Denny connects to the server over SSH himself and shows in the notch everything the agents do there.

#### 1. An SSH key on the Mac (once)

Denny connects the way you do from Terminal, but without a password — with a key. Check in **Terminal on the Mac** (not in Termius):

```bash
ssh user@server
```

Let in without a password — you have a key, go to step 2. Asked for a password (or you only use Termius) — create a key and send it to the server:

```bash
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
ssh-copy-id user@server
```

`ssh-copy-id` asks for the server password once. After that `ssh user@server` lets you in without one. A short name from `~/.ssh/config` works too.

#### 2. Add the server

**Settings → Servers → Denny's own connections** → enter `user@server` (or a name from `~/.ssh/config`) → **Add**.

A dot appears next to it:

| Dot | Meaning |
|---|---|
| 🟢 connected | all good |
| 🟠 connecting… | give it a few seconds |
| 🔴 with a note | something's in the way — see "If it won't connect" below; Denny keeps retrying |

#### 3. Connect the agents (once per server)

Press **Connect agents**. Denny puts his hook on the server (`~/.denny-for-agents/denny-hook.py`, needs only Python 3) and adds it to Claude Code's and Codex's settings — the old settings are kept next to them as a backup.

Then **restart Claude Code / Codex on the server** — they only pick up new hooks at launch.

Done: Allow / Deny requests, "the agent is writing code", receipts, limits and server load show up in the notch. Denny keeps the link alive himself: after the Mac sleeps, Wi-Fi changes or a VPN reconnects he connects again — no need to keep Termius open.

After updating Denny, press **Connect agents** again to put the new hook version on the server.

#### If it won't connect

| Denny says | What to do |
|---|---|
| No SSH key for this server | Redo step 1. Denny shows the commands and a Copy commands button. |
| Server unreachable | Check the address and the internet. If the server is only reachable over a VPN, turn it on. |
| The server's key has changed | The server was reinstalled or replaced. If you're sure it's yours: `ssh-keygen -R server-address`, then `ssh user@server` and accept the new key. |
| python3 isn't installed on the server | Install Python 3 there (e.g. `apt install python3`). |
| Port is still busy on the server | Nothing to do: Denny takes the next port. Happens right after a dropped connection. |

To check the hook on the server: `python3 ~/.denny-for-agents/denny-hook.py --ping`.

To remove a server: 🗑 → Remove (the hook stays on the server) or Remove and disconnect agents on the server.

#### By hand, without Denny's own connections

If you'd rather keep the tunnel yourself (say, in Termius):

1. Forward the port while connected. In Termius: **Port Forwarding → New → Remote**, server port `47321`, address `127.0.0.1`, destination `127.0.0.1:47321`. With plain ssh:
   ```bash
   ssh -R 47321:127.0.0.1:47321 you@server
   ```
2. Put [`remote/denny-hook.py`](remote/denny-hook.py) on the server in `~/.denny-for-agents/`.
3. In **Settings → Servers**, copy the install command, run it on the server and check with `--ping`.
4. Restart Claude Code / Codex on the server.

Note: such a tunnel drops when the Mac sleeps, the network changes or Termius closes — and doesn't come back by itself.

Either way, the forwarded port listens only on `127.0.0.1` on the server, and every request carries a secret token from your Mac.

## How it works

- **Hooks.** Claude Code and Codex run a tiny `denny-hook` on each event — session start, tool use, permission request, stop — which forwards it over a Unix socket in `~/.denny-for-agents/`. For a permission request it waits for your click and answers the agent. If nothing answers, it exits silently and the agent asks in its own prompt.
- **Usage.** `denny-hook.py --report` reads the agents' own logs incrementally — token counts, model names and times only, never prompts or answers — and plan limits from Claude Code's status line, `~/.claude.json`, the Claude desktop app and `codex app-server`. Claude prices come from Anthropic's public list; models without a public price, Codex included, are counted in tokens.
- **The notch.** A borderless SwiftUI panel hugging the camera notch (a capsule on Macs without one). Denny's animations are short videos, about half a megabyte in total.

## Privacy

No account, no analytics, no telemetry. Denny makes exactly two kinds of network requests, both to this GitHub repository and both anonymous: once a day he downloads the public price list ([`prices.json`](prices.json)) and checks for a new release. Only if you connect a Telegram bot do approval requests go through Telegram as well. Nothing about you, your code or your usage is ever sent.

Hook events travel over a local Unix socket, or through the SSH tunnel you set up yourself. Safety-net snapshots stay on the machine where the agent runs (`~/.denny-for-agents/safety-net`). Files you drop on the notch go only to the server you're working on, with your next message.

## The full Denny

Denny for Agents is the free, open part of **[Denny](https://afteam.tech/denny/?utm_source=github)** — an AI companion for tasks, notes, reminders and offline AI on Mac and Android, with a file shelf and music controls in the notch.

## License

- **Code:** [MIT](LICENSE).
- **The Denny name, character, animations, icon and sounds:** © AFTeam, all rights reserved — see [LICENSE-ASSETS.md](LICENSE-ASSETS.md). Shipping your own fork? Give it your own name and character.

<sub>Claude and Claude Code are trademarks of Anthropic. Codex and ChatGPT are trademarks of OpenAI. Denny for Agents is an independent project and is not affiliated with or endorsed by either company.</sub>
