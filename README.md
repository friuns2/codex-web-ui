> [!IMPORTANT]
> This project has moved to **[friuns2/codexui](https://github.com/friuns2/codexui)**.
> Please use the new repository for the latest updates: **https://github.com/friuns2/codexui**.

<div align="center">

# 🌐 Codex App Web UI Enabler

### 🚀 Run OpenAI Codex Desktop in Your Browser — From Any Device 🚀

[![Shell Script](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white&style=for-the-badge)](https://www.gnu.org/software/bash/)
[![Electron](https://img.shields.io/badge/Electron-Patched-47848F?logo=electron&logoColor=white&style=for-the-badge)](https://www.electronjs.org/)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20Windows-blue?style=for-the-badge&logo=apple)](https://github.com/friuns2/codex-unpacked-toolkit)
[![License](https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge)](LICENSE)
[![Status](https://img.shields.io/badge/Status-🔥%20WORKS-brightgreen?style=for-the-badge)](https://github.com/friuns2/codex-unpacked-toolkit)
[![GitHub stars](https://img.shields.io/github/stars/friuns2/codex-unpacked-toolkit?style=for-the-badge&logo=github&color=gold)](https://github.com/friuns2/codex-unpacked-toolkit/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/friuns2/codex-unpacked-toolkit?style=for-the-badge&logo=github&color=blue)](https://github.com/friuns2/codex-unpacked-toolkit/network)

<br />

<img src="https://img.shields.io/badge/⚡_ONE_SCRIPT_TO_RULE_THEM_ALL-black?style=for-the-badge&labelColor=black" />

<br />

> **Codex Desktop's full UI — chat, skills, file editing, code execution —**
> **accessible from any browser on any device. No Electron window required.**
>
> **One script. Full Web UI. Anywhere.** 🌍

<br />

```
   ██████╗ ██████╗ ██████╗ ███████╗██╗  ██╗   ██╗    ██╗███████╗██████╗    ██╗   ██╗██╗
  ██╔════╝██╔═══██╗██╔══██╗██╔════╝╚██╗██╔╝   ██║    ██║██╔════╝██╔══██╗   ██║   ██║██║
  ██║     ██║   ██║██║  ██║█████╗   ╚███╔╝    ██║ █╗ ██║█████╗  ██████╔╝   ██║   ██║██║
  ██║     ██║   ██║██║  ██║██╔══╝   ██╔██╗    ██║███╗██║██╔══╝  ██╔══██╗   ██║   ██║██║
  ╚██████╗╚██████╔╝██████╔╝███████╗██╔╝ ╚██╗  ╚███╔███╔╝███████╗██████╔╝   ╚██████╔╝██║
   ╚═════╝ ╚═════╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝   ╚══╝╚══╝ ╚══════╝╚═════╝    ╚═════╝ ╚═╝
                    E N A B L E R
```

</div>

---

## 🤯 What Is This?

OpenAI's Codex Desktop is a powerful AI coding agent — but it's locked inside an Electron window on a single machine. What if you could access it **from any browser, on any device, anywhere on your network?**

We reverse-engineered the minified Electron bundle and built scripts that **patch the app at runtime** to expose the full Codex UI over HTTP + WebSocket. The same scripts also unlock a **hidden SSH remote execution engine** that was already compiled into the binary but never wired up.

**One command. Full Web UI. Plus SSH remote control. No recompilation.**

---

## 📱 See It In Action — Codex in Your Browser, From Any Device

> **Yes, that's a phone. Yes, that's Codex. Yes, it's running on a Mac across the network.**

<div align="center">
<table>
<tr>
<td align="center" width="50%">
<img src="images/mobile-chat-session.jpeg" width="300" />
<br />
<b>💬 Live AI Chat Session</b>
<br />
<sub>Full Codex conversation running on a Mac, controlled from an Android phone over the network. GPT-5.3-Codex responding in real-time. The address bar says it all: <code>100.107.32.83:5999</code> — that's a remote Mac.</sub>
</td>
<td align="center" width="50%">
<img src="images/mobile-skills-browser.jpeg" width="300" />
<br />
<b>🧩 Skills Manager — From Your Pocket</b>
<br />
<sub>Browsing and managing Codex skills (Playwright, Oracle Cloud CLI, Three.js, YouTube Search...) from a mobile browser. Full desktop functionality, zero compromises.</sub>
</td>
</tr>
</table>
</div>

> 🤯 **This is not a mockup.** This is a real Codex Desktop instance running on macOS, patched with our Web UI Enabler scripts, accessed from a mobile phone browser over Tailscale. Every feature works — chat, skills, file editing, code execution — all from your pocket.

---

## ⚡ Quick Start

```bash
# Run directly from npm (no clone needed)
npx -y codex-web-ui --port 5999
```

Open `http://127.0.0.1:5999/` and you're flying. ✈️

---

## 🌍 What Can You Actually Do With This?

With the Web UI enabled, Codex breaks free from the Electron window — and with SSH mode unlocked, it reaches **any machine you own**:

| 🎯 Use Case | 💡 Description |
|---|---|
| 📱 **Code From Your Phone** | Open Codex in any mobile browser — full chat, skills, file editing, code execution |
| 💻 **Use Any Browser** | Chrome, Firefox, Safari, Arc — no Electron install needed on the client |
| 🌐 **Access Over the Network** | Tailscale, LAN, VPN — access your Codex instance from anywhere securely |
| 🖥️ **Control Your Mac Remotely** | SSH into your MacBook from anywhere and let Codex operate it as if you're sitting in front of it |
| 🐧 **Orchestrate Linux Servers** | Point Codex at your Ubuntu/Debian/Arch boxes and run AI-powered coding sessions remotely |
| 🪟 **Manage Windows via WSL** | Connect through WSL2 SSH and bring Codex intelligence to your Windows dev environment |
| 🏠 **Command Your Homelab** | Proxmox, TrueNAS, Raspberry Pi clusters — Codex becomes your AI sysadmin |
| ☁️ **Cloud Fleet Management** | AWS EC2, Oracle Cloud, DigitalOcean droplets — manage entire fleets from one Codex window |
| 🔧 **Web Service Orchestration** | Nginx configs, Docker containers, systemd services — edit and deploy across machines |
| 🧪 **Remote CI/CD Pipelines** | Trigger builds, inspect logs, fix failing tests on remote CI runners in real-time |
| 📡 **IoT & Edge Devices** | SSH into Raspberry Pis, Jetson Nanos, or any edge device and code directly on them |
| 🏗️ **Multi-Machine Refactoring** | Coordinate code changes across microservices running on different hosts simultaneously |

> **TL;DR:** Codex in your browser + SSH to any machine = your entire infrastructure as one AI-powered IDE. 🧠

---

## 📁 Project Structure

```
codex-unpacked-toolkit/
├── 🌐 launch_codex_webui_unpacked.sh     # WebUI mode launcher (browser access)
├── 🔧 launch_codex_unpacked.sh          # SSH unlock & debug launcher
├── 🔌 webui-bridge.js                    # Browser-side WebSocket ↔ IPC bridge
├── 📖 PROJECT_STATE.md                    # Living project state & patching reference
├── 📂 images/                            # Screenshots & proof it works
│   ├── mobile-chat-session.jpeg          # Codex chat from mobile phone
│   └── mobile-skills-browser.jpeg        # Skills manager from mobile phone
└── 📂 skills/
    └── launch-codex-unpacked/
        └── SKILL.md                      # Codex skill definition
```

---

## 🌐 `launch_codex_webui_unpacked.sh` — Browser-Based Codex

> **The main event.** Run Codex in your browser. No Electron window needed. Access from any device on your network.

### What It Does

1. 📦 **Extracts `app.asar`** — Same unpacking as above
2. 💉 **Injects WebUI runtime patch** — Embeds a full HTTP server + WebSocket bridge directly into the Electron main process (~800 lines of runtime injection)
3. 🩹 **Patches renderer bundle** — Fixes a `roots` guard compatibility issue in the React renderer that crashes in WebUI mode
4. 🔌 **Copies `webui-bridge.js`** — Installs the browser-side bridge into the webview directory
5. 🚀 **Launches headless Electron** — Starts with `--webui` flag, hides all native windows, serves UI over HTTP
6. 🔐 **Optional token auth** — Protect your instance with `--token` for secure remote access
7. 🌍 **Origin allowlist** — Restrict which domains can connect via `--origins`
8. 🖥️ **Auto-opens browser** — Polls the server and opens your default browser when ready

### The Injected Runtime Includes

- 🌐 Full HTTP static file server (serves Codex webview assets)
- 🔄 RFC 6455-compliant WebSocket server (zero dependencies, hand-rolled frame parser)
- 🔒 Timing-safe token authentication (Bearer, header, query param, and cookie)
- 🛡️ Security headers (X-Content-Type-Options, X-Frame-Options, CORP, Referrer-Policy)
- 📡 IPC-to-WebSocket bridge (intercepts `webContents.send` and mirrors to all connected clients)
- 🚦 Rate limiting (5000 messages/minute for local, configurable)
- 👤 Single-client policy (new tab takes over, old tab gets disconnected)
- 💉 SPA fallback with automatic `webui-bridge.js` injection into HTML

### Options

```
--app <path>           Custom Codex.app path
--port <n>             WebUI port (default: 5999)
--token <value>        Auth token for secure access 🔐
--origins <csv>        Allowed origins (comma-separated)
--bridge <path>        Custom webui-bridge.js path
--user-data-dir <path> Chromium user data dir override
--no-open              Don't auto-open browser
--keep-temp            Keep extracted app dir
```

### Examples

```bash
# Run from npm package
npx -y codex-web-ui --port 5999

# Basic local access
./launch_codex_webui_unpacked.sh

# Secure remote access with auth
./launch_codex_webui_unpacked.sh --port 8080 --token mysecrettoken

# Access from specific origins only
./launch_codex_webui_unpacked.sh --origins "https://mysite.com,http://localhost:3000"
```

---

## 🔧 `launch_codex_unpacked.sh` — The SSH Unlocker

> **Bonus superpower.** This script extracts, patches, and launches Codex with the hidden SSH remote execution feature fully activated.

### What It Does

1. 📦 **Extracts `app.asar`** — Unpacks the Codex Electron bundle into a temp directory using `@electron/asar`
2. 🔑 **Injects SSH host into global state** — Writes your SSH host into `.codex-global-state.json` so the app recognizes it as a configured remote
3. 🧬 **Patches the main bundle** — Performs a surgical startup-sequence patch on minified `main-*.js` to auto-select the SSH host on startup (dynamically discovers the target sequence and rewires it to check `electron-ssh-hosts` first)
4. 🔍 **Enables Node Inspector** — Launches with `--inspect` for live debugging (port 9229 by default)
5. 🌐 **Enables Chromium Remote Debug** — Opens `--remote-debugging-port` (9222) for DevTools Protocol access
6. ✅ **SSH preflight check** — Validates connectivity to your host with `BatchMode=yes` and `ConnectTimeout=6` before launching
7. 🧹 **Auto-cleanup** — Temp directory is removed on exit (unless `--keep-temp`)

### Options

```
--app <path>                 Custom Codex.app path (default: /Applications/Codex.app)
--user-data-dir <path>       Chromium user data dir override
--inspect-port <n>           Node inspector port (default: 9229)
--remote-debug-port <n>      Chromium remote debug port (default: 9222)
--ssh-host <user@host>       The SSH host to unlock and auto-connect 🔑
--no-inspect                 Disable Node inspector
--no-remote-debug            Disable Chromium remote debugging
--keep-temp                  Keep extracted app dir for inspection
```

### Example

```bash
# Unlock SSH to your homelab server with custom ports
./launch_codex_unpacked.sh \
  --ssh-host ubuntu@192.168.1.100 \
  --inspect-port 9230 \
  --remote-debug-port 9223
```

---

## 🔌 `webui-bridge.js` — The Browser-Side Bridge

> **Makes the browser think it's Electron.** Replaces `window.electronBridge` with a WebSocket-backed implementation.

### What It Does

1. 🔍 **Detects environment** — Only activates when the native Electron preload bridge is absent
2. 🔄 **Establishes WebSocket connection** — Connects to `/ws` with automatic reconnection (exponential backoff, 500ms → 5s)
3. 📨 **Implements full `electronBridge` API** — `sendMessageFromView`, `sendWorkerMessageFromView`, `subscribeToWorkerMessages`, and more
4. 📬 **Message queue** — Buffers outbound messages while disconnected, flushes on reconnect
5. 📡 **Event forwarding** — Translates WebSocket packets into browser `MessageEvent`s that the React app expects
6. 🔄 **Worker subscription system** — Manages per-worker callback subscriptions with proper cleanup
7. 🏷️ **Session management** — Emits `client-status-changed` on connect, handles `open-new-instance` redirects
8. 🛡️ **Single-socket guard** — Token-based deduplication prevents ghost connections

---

## 🔬 How We Found It — The Investigation

> See the full reverse-engineering findings in [`PROJECT_STATE.md` § 9](PROJECT_STATE.md#9-ssh-reverse-engineering-findings)

We extracted the `app.asar`, deobfuscated the minified bundles, and traced the execution paths. Along the way we discovered a fully-built SSH remote execution engine hidden inside the binary. Here's what we found:

| 🔎 Discovery | 📝 Detail |
|---|---|
| **Remote host detection** | Activates when host config `kind` is `ssh` or `brix` |
| **Command execution** | Builds args from `hostConfig.terminal_command`, appends `--`, env vars, and command |
| **SSH wrapper** | Wraps commands in `sh -lc <quoted>` with `-o BatchMode=yes -o ConnectTimeout=10` |
| **Git over SSH** | Routes git commands through remote shell with `GIT_TERMINAL_PROMPT=0` |
| **Remote git apply** | Full flow: `mktemp -d` → `cat > patch` → `test -e` → `git apply --3way` → `rm -rf` |
| **Codex home resolution** | Checks `$CODEX_HOME`, falls back to `$HOME/.codex` |

**All of this was already compiled into the app. We just wired it up.** ⚡

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────┐
│                    YOUR BROWSER                      │
│                                                      │
│   webui-bridge.js                                    │
│   ┌──────────────────────────────────┐               │
│   │  window.electronBridge (fake)    │               │
│   │  ┌────────────┐ ┌─────────────┐ │               │
│   │  │ sendMessage │ │ subscribe   │ │               │
│   │  │ FromView    │ │ ToWorker    │ │               │
│   │  └──────┬─────┘ └──────┬──────┘ │               │
│   └─────────┼──────────────┼────────┘               │
│             │  WebSocket   │                         │
└─────────────┼──────────────┼─────────────────────────┘
              │    /ws       │
┌─────────────┼──────────────┼─────────────────────────┐
│  ELECTRON MAIN PROCESS (headless)                     │
│             │              │                          │
│   ┌────────┴──────────────┴────────┐                 │
│   │  WebUI Runtime Patch           │                 │
│   │  ┌──────────┐ ┌─────────────┐  │                 │
│   │  │ HTTP     │ │ WebSocket   │  │                 │
│   │  │ Server   │ │ Server      │  │                 │
│   │  └──────────┘ └──────┬──────┘  │                 │
│   │                      │         │                 │
│   │  webContents.send ◄──┘ (intercept & mirror)      │
│   └────────────────────────────────┘                 │
│                      │                                │
│              ┌───────┴────────┐                       │
│              │  SSH Transport │ ◄── UNLOCKED 🔓       │
│              └───────┬────────┘                       │
└──────────────────────┼────────────────────────────────┘
                       │ SSH
              ┌────────┴────────┐
              │  REMOTE HOST    │
              │  ┌────────────┐ │
              │  │ ~/.codex   │ │
              │  │ git apply  │ │
              │  │ sh -lc ... │ │
              │  └────────────┘ │
              └─────────────────┘
```

---

## 🎯 Requirements

- 🍎 **macOS** with Codex Desktop installed (or custom `--app` path)
- 📦 **Launcher dependencies are auto-installed** when missing:
  - `node`/`npx` (both launchers)
  - `ripgrep` (`launch_codex_webui_unpacked.sh`)
  - via Homebrew bootstrap when `brew` is missing
- 🌐 Internet access and `curl` available for automatic Homebrew/tool installation
- ⚙️ Optional: set `AUTO_INSTALL_TOOLS=0` to disable auto-install behavior
- 🌐 **A modern browser** (Chrome, Firefox, Safari, Arc, etc.) for Web UI access
- 🔑 **SSH key-based auth** configured for your target host — only needed for SSH mode (`BatchMode=yes`)
- 🖥️ Target host with `~/.codex` directory (or `$CODEX_HOME` set) — only needed for SSH mode

---

## 🛡️ Security Notes

- SSH uses `BatchMode=yes` — no interactive password prompts, key-based auth only
- WebUI token auth uses **timing-safe comparison** to prevent timing attacks
- Security headers are set on all HTTP responses (DENY framing, no-sniff, no-referrer)
- Single-client policy prevents session hijacking from duplicate tabs
- Rate limiting protects against WebSocket flood attacks
- No `StrictHostKeyChecking` overrides — your existing SSH config is respected

---

## 🐛 Troubleshooting

| Problem | Solution |
|---|---|
| `EADDRINUSE` | Port already in use — try `--port 6002` |
| `SSH preflight failed` | Check your SSH key: `ssh -o BatchMode=yes user@host 'echo ok'` |
| `[webui] Renderer guard patch anchor not found; continuing without renderer patch (bundle shape changed).` | Informational on newer bundles; launcher now continues |
| `Missing app.asar` | Point `--app` to your Codex.app location |
| Blank page in WebUI | Check console for `roots` error — renderer patch may need updating |

---

## 🛠️ Development

```bash
# Clone this repo
git clone https://github.com/friuns2/codex-web-ui.git
cd codex-web-ui

# 🌐 Launch the Web UI — access Codex from any browser
./launch_codex_webui_unpacked.sh --port 5999

# 🔓 Or launch with SSH mode unlocked (connects to your remote host)
./launch_codex_unpacked.sh --ssh-host user@your-server.com
```

---

## 🤝 Contributing

Found a new Codex version that breaks the patches? Bundle patterns change between releases — [PRs](https://github.com/friuns2/codex-unpacked-toolkit/pulls) to update the patch anchors are always welcome! [Open an issue](https://github.com/friuns2/codex-unpacked-toolkit/issues) if you hit a new bundle shape.

---

## ⭐ Star This Repo

If you think Codex should be accessible **from any browser, on any device** — not just the Electron window it shipped in — [smash that star button](https://github.com/friuns2/codex-unpacked-toolkit). ⭐

---

<div align="center">

**Built by reverse-engineering Codex Desktop's Electron bundle** 🔬

*Because the best features are the ones they already shipped but forgot to turn on.* 😏

</div>
