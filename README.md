<div align="center">

<!-- TODO before publishing: record docs/media/demo.gif — Denny in the notch, an approval card, the stats page. -->
<img src="docs/media/demo.gif" width="760" alt="Denny in the MacBook notch watching Claude Code and Codex">

# Denny for Agents

**A tiny robot friend that lives in your MacBook's notch and keeps an eye on Claude Code and Codex.**

Approve permissions, watch your agents work, see your plan limits and spending — without leaving what you're doing.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)
![Claude Code](https://img.shields.io/badge/Claude%20Code-supported-D97757)
![Codex](https://img.shields.io/badge/Codex-supported-7A9BFF)
![License: MIT](https://img.shields.io/badge/code-MIT-green)

</div>

---

## What it does

- 🤖 **Claude Code and Codex, live.** Every session in your notch, step by step: what it reads, edits and runs. When a long task finishes, Denny jumps for joy.
- ✅ **Approve from the notch.** Permission requests show up with **Allow / Deny / Ask there**. If Denny isn't running, your agents ask in the terminal as usual — Denny never blocks them.
- 🖥️ **Agents on SSH servers too.** Working in Claude Code over SSH? One forwarded port and Denny on your Mac sees the agent on the server — approvals included.
- 📊 **Limits and spending.** Session and weekly limits for Claude and Codex with a pace marker, what your usage would cost at API prices, cache hit rate, a trend chart, top models and projects, and a 13-week activity map.
- 💎 **Plan value.** "$1,240 at API prices on a $20 plan — ×62." The number people screenshot.
- ⏱️ **A live number by the camera.** The current task's timer while an agent works, your tightest limit as a ring when it rests.
- 🔄 **Codex limit resets.** See your banked resets and spend one from the notch, with a confirmation.
- 🔔 **Quiet notifications.** Only for tasks longer than you choose, limits crossing a threshold, or a daily budget — each one once.
- 📎 **Drop a file on the notch** and paste its path to your agent. If the agent runs on a server, Denny sends the file there with your next message.
- 🌍 **10 languages:** English, Русский, 简体中文, 日本語, 한국어, Deutsch, Français, Español, Português (Brasil), Українська.
- 🔒 **Private by design.** No account, no telemetry. Usage numbers are read from your agents' local logs and never leave your machines.

## Install

### Download

1. Get the latest `DennyForAgents.zip` from [Releases](../../releases).
2. Unzip and move **Denny for Agents.app** to `/Applications`.
3. The build isn't notarized by Apple yet. The first time, macOS says it can't check the developer: open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** (only once).

### Homebrew

```bash
brew install --cask LLC-AFTeam-Tech/tap/denny-for-agents
```

### Build from source

Requirements: macOS 13+, Xcode 16+ (or the Swift toolchain).

```bash
git clone https://github.com/LLC-AFTeam-Tech/denny-for-agents.git
cd denny-for-agents
swift test
./scripts/build-app.sh
open "dist/Denny for Agents.app"
```

## Setup

On first launch Denny asks to connect to your agents. It adds its hooks to `~/.claude/settings.json` and `~/.codex/hooks.json`, saves a backup next to each file, and never touches a file it can't parse. You can switch each agent on or off from the menu bar icon.

### Agents on an SSH server

1. Forward a port while you're connected. In Termius: **Port Forwarding → New → Remote**, remote port `47321`, bind address `127.0.0.1`, destination `127.0.0.1:47321`. Or with plain ssh:
   ```bash
   ssh -R 47321:127.0.0.1:47321 you@server
   ```
2. Put [`remote/denny-hook.py`](remote/denny-hook.py) into `~/.denny-for-agents/` on the server (Python 3, no dependencies).
3. In Denny's menu choose **Remote server (SSH)… → Copy install command**, run it on the server, then check:
   ```bash
   python3 ~/.denny-for-agents/denny-hook.py --ping
   ```
4. Restart Claude Code / Codex on the server so they pick up the hooks.

The forwarded port only listens on the server's `127.0.0.1`, and every request carries a secret token from your Mac.

## How it works

- **Hooks.** Claude Code and Codex run a tiny `denny-hook` on each event (session start, tool use, permission request, stop). It forwards the event over a Unix socket in `~/.denny-for-agents/`. For a permission request it waits for your click, then answers the agent. If nothing answers, it exits silently and the agent asks in its own prompt.
- **Usage.** `denny-hook.py --report` reads the agents' own logs incrementally — token counts, model names and times only, never prompts or answers — and plan limits from `~/.claude.json`, the Claude desktop app and `codex app-server`. Prices for Claude models come from Anthropic's public list; models without a public price are counted in tokens.
- **The notch.** A borderless panel hugging the camera notch (a capsule on Macs without one), drawn in SwiftUI.

## Privacy

Denny for Agents has no account and no analytics. Its only network request is a daily download of the public price list ([`prices.json`](prices.json)) from this repository — nothing about you or your usage is sent. Hook events travel over a local Unix socket, or through the SSH tunnel you set up. Files you drop on the notch go only to the server you're working on, with your next message.

## Full Denny

Denny for Agents is the free, open part of **[Denny](https://afteam.tech/denny/?utm_source=github)** — an AI companion for tasks, notes, reminders and offline AI on Mac and Android, with a file shelf and music controls in the notch.

## License

- **Code:** [MIT](LICENSE).
- **The Denny name, character, animations, icon and sounds:** © AFTeam, all rights reserved — see [LICENSE-ASSETS.md](LICENSE-ASSETS.md). Shipping your own fork? Give it your own name and character.

*Claude and Claude Code are trademarks of Anthropic. Codex is a trademark of OpenAI. This project is independent and not affiliated with either.*

---

[Русская версия](README.ru.md)
