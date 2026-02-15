# Agent Instructions — Codex SSH Unlocker

## Project overview

This repo contains scripts and patches that unlock hidden SSH remote-execution and WebUI browser-access features inside the OpenAI Codex Desktop Electron app. The key deliverables are two bash launchers (`launch_codex_unpacked.sh`, `launch_codex_webui_unpacked.sh`), a browser-side WebSocket bridge (`webui-bridge.js`), and the public-facing `README.md`.

## PROJECT_STATE.md — the living reference

`PROJECT_STATE.md` is the single source of truth for the project's internal technical state. It records:

- How each patch works (CLI parsing, startup split, HTTP/WS server, IPC bridge, renderer bridge)
- Minification-safe patching guidelines (what to rely on, what to avoid)
- Stability fixes discovered during testing (socket guards, rate limits, status events)
- SSH mode workflow and verification procedures
- Launch commands, scripts, and known failure/success signatures
- Log triage (noise vs actual blockers)

### When to update PROJECT_STATE.md

Update it **every time** you make a change that affects the project's technical reality:

| Change type | What to add/update in PROJECT_STATE.md |
|---|---|
| New patch or code injection | Add a numbered section describing what it does, with a code snippet |
| New CLI flag or env var | Document it in the relevant section and in the launch commands |
| Bug fix or stability improvement | Add to section 6 ("Stability fixes") with before/after context |
| New known failure or success | Add to "Known failure/success examples" |
| Changed file paths | Update the "Patched Files" list |
| New script or npm script | Add to section 7 ("Scripts and run commands") |
| Log triage discovery | Add to section 9 ("Log Triage and Fixes") under the right category |
| Architecture change | Update the relevant numbered section |

### How to update it

1. **Read `PROJECT_STATE.md` first** — understand the current structure before editing.
2. **Append to existing sections** when the change fits an existing category. Don't duplicate sections.
3. **Add new numbered sections** (e.g. `## 10) ...`) only for genuinely new capabilities.
4. **Include code snippets** for any injected or patched code — this is a reference doc, not prose.
5. **Keep entries concrete** — include actual values, paths, port numbers, error strings. Avoid vague descriptions.
6. **Preserve the numbering** — sections are numbered for cross-referencing. Don't renumber existing sections.

### What NOT to put in PROJECT_STATE.md

- Marketing copy or user-facing instructions (that goes in `README.md`)
- Temporary debug notes (use git commit messages instead)
- Secrets or credentials

## Other files

| File | Purpose | When to update |
|---|---|---|
| `README.md` | Public-facing docs, quick start, feature list | When user-visible behavior changes (new flags, new capabilities, new screenshots) |
| `launch_codex_unpacked.sh` | SSH unlock launcher | When SSH patching logic or CLI flags change |
| `launch_codex_webui_unpacked.sh` | WebUI launcher | When WebUI injection, HTTP server, or CLI flags change |
| `webui-bridge.js` | Browser-side WS bridge | When the bridge protocol or electronBridge API changes |
| `skills/launch-codex-unpacked/SKILL.md` | Codex skill definition | When launcher usage or flags change |
