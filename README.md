# codex-unpacked-toolkit

Toolkit for inspecting, patching, and launching unpacked Codex Desktop (Electron) builds.

## What this repo includes

- `launch_codex_unpacked.sh`: extracts `app.asar`, launches Codex from unpacked files, and enables inspect/debug ports.
- `launch_codex_webui_unpacked.sh`: starts Codex in patched `--webui` mode so the UI can be accessed in a browser.
- `webui-bridge.js`: renderer-side bridge that maps browser WebSocket traffic to Codex desktop message flows.
- `guide.md`: patch notes and implementation details for the WebUI bridge runtime.
- `ssh codex investication spec.md`: SSH behavior investigation notes for Codex remote host operations.

## Typical use

1. Run unpacked Codex for debugging.
2. Apply/verify WebUI bridge behavior.
3. Validate SSH and remote execution behavior.

## Notes

- This repository is focused on reverse-engineering and operational tooling, not product source development.
- Scripts expect a local `Codex.app` install and standard Electron tooling (`npx`, `@electron/asar`, `electron`).
