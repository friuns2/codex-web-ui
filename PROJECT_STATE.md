# WebUI Bridge Patch Guide (Codex Electron)

## Unpacked launcher and SSH mode

Use `/Users/igor/.codex/worktrees/5b82/untitled folder 67/launch_codex_unpacked.sh` to run Codex from extracted `app.asar` with debug flags and optional SSH host auto-start.

### Capabilities

- Node inspector enabled by default (`--inspect`)
- Chromium CDP enabled by default (`--remote-debugging-port`)
- Optional SSH host bootstrap via `--ssh-host <user@host>`
- Automatic prerequisite bootstrap for launcher dependencies (Homebrew + required tools)

### SSH mode workflow

When `--ssh-host` is provided, the launcher:

1. Runs SSH preflight (`BatchMode=yes`, `ConnectTimeout`) and warns if unreachable.
2. Writes the host into `~/.codex/.codex-global-state.json` under `electron-ssh-hosts` (host first).
3. Patches extracted unpacked `main-*.js` to auto-open first SSH host window on startup.

Injected runtime marker:

- `/*__CODEX_SSH_AUTOSTART_PATCH__*/`

### Verification procedure

1. Check host reachability:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 ubuntu@149.118.68.1 'echo ok'
```

2. Run unpacked launcher in SSH mode:

```bash
bash ./launch_codex_unpacked.sh --ssh-host ubuntu@149.118.68.1
```

3. Validate logs contain SSH app-server lifecycle lines:
- `Codex app-server connection state changed ... next=connecting`
- `stdio_transport_spawned ... executablePath=ssh`
- `initialize_handshake_result ... outcome=success|failure`

### Known failure/success examples

- `ubuntu@149.118.68.1`: network timeout (`ssh: connect to host 149.118.68.1 port 22: Operation timed out`)
- `ubuntu@149.118.68.145`: handshake and connected state succeed

This guide documents exactly how `--webui` was added in the readable Codex build, how IPC was bridged to WebSocket, and how WebUI was exposed in a browser.

## Patched Files

- `/Users/igor/temp/untitled folder 67/codex_reverse/readable/.vite/build/main-BLcwFbOH.js`
- `/Users/igor/temp/untitled folder 67/codex_reverse/readable/webview/webui-bridge.js`
- `/Users/igor/temp/untitled folder 67/codex_reverse/readable/webview/assets/index-BnRAGF7J.js`
- `/Users/igor/temp/untitled folder 67/codex_reverse/readable/package.json`

## Minification-safe patching guidelines

When patching bundled Electron output, avoid relying on build-specific minified identifiers.

- Prefer stable Electron imports (`require("electron")`) over internal short names.
- Use `BrowserWindow.getAllWindows()` to discover windows instead of app-private globals.
- Detect IPC payloads by payload shape (`{ type: string }`) rather than fixed minified channel IDs.
- Generate `/webui-config.js` from explicit runtime values, not from opaque internal symbols.
- Treat names like `L`, `Vt`, `Pt`, `Dde`, `bt`, `sn`, `ma`, `Ya` as unstable and non-portable.

## 1) Add `--webui` CLI mode

In main process bundle, parse CLI/env switches and keep options in `webUiOptions`.

```js
function webUiParseCliOptions(argv = process.argv, env = process.env) {
  let enabled = false;
  let remote = false;
  let port = webUiParsePortArg(env.CODEX_WEBUI_PORT, 3210);
  let token = (env.CODEX_WEBUI_TOKEN ?? "").trim();
  let origins = (env.CODEX_WEBUI_ORIGINS ?? "")
    .split(",")
    .map((x) => x.trim())
    .filter(Boolean);

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--webui") enabled = true;
    if (a === "--remote") remote = true;
    if (a === "--port" && i + 1 < argv.length) port = webUiParsePortArg(argv[++i], port);
    if (a.startsWith("--port=")) port = webUiParsePortArg(a.slice("--port=".length), port);
    if (a === "--token" && i + 1 < argv.length) token = String(argv[++i] ?? "").trim();
    if (a.startsWith("--token=")) token = a.slice("--token=".length).trim();
    if (a.startsWith("--origins=")) {
      origins = a.slice("--origins=".length).split(",").map((x) => x.trim()).filter(Boolean);
    }
  }
  return { enabled, remote, port, token, origins };
}
```

## 2) Split startup path (desktop vs web)

In `app.whenReady()`, do not create normal window when `--webui` is enabled.

```js
const electron = require("electron");
const app = electron.app;
const BrowserWindow = electron.BrowserWindow;
// ... normal startup ...
if (webUiOptions.enabled) {
  const win = BrowserWindow.getAllWindows().find((w) => w && !w.isDestroyed());
  webUiRuntime = await webUiStartBridgeRuntime({ bridgeWindow: win, context: null });
}
```

Also keep app alive in headless mode:

```js
electron.app.on("window-all-closed", () => {
  if (webUiOptions.enabled) return;
  if (process.platform !== "darwin") electron.app.quit();
});
```

## 3) Expose WebUI over HTTP + WebSocket

`webUiStartBridgeRuntime(...)` starts HTTP server and WS server:

- Bind host:
  - `127.0.0.1` for local mode
  - `0.0.0.0` for `--remote`
- Serve `webview` assets and SPA fallback
- Inject `webui-config.js` and `webui-bridge.js` into HTML
- Guard `/ws` with origin check and optional token auth

```js
const host = webUiOptions.remote ? "0.0.0.0" : "127.0.0.1";
const authRequired = webUiOptions.remote || !!webUiOptions.token;
const wss = new WebSocketServer({ noServer: true, perMessageDeflate: false });
```

Static serving with no-store cache (prevents stale frontend):

```js
res.setHeader("Cache-Control", "no-store");
```

## 4) IPC -> WebSocket bridge

Main trick: intercept `bridgeWindow.webContents.send` and mirror IPC events to WS packets.

```js
const originalSend = bridgeWindow.webContents.send.bind(bridgeWindow.webContents);
bridgeWindow.webContents.send = (channel, ...args) => {
  const payload = args.find(
    (value) =>
      value &&
      typeof value === "object" &&
      !Array.isArray(value) &&
      typeof value.type === "string",
  );
  if (payload) {
    broadcast({ kind: "message-for-view", payload });
  } else if (
    typeof channel === "string" &&
    channel.startsWith("codex_desktop:worker:") &&
    channel.endsWith(":for-view")
  ) {
    broadcast({
      kind: "worker-message-for-view",
      workerId: channel.slice("codex_desktop:worker:".length, -":for-view".length),
      payload: args[0],
    });
  }
  originalSend(channel, ...args);
};
```

Incoming WS -> existing electron message handler:

```js
if (packet?.kind === "message-from-view") {
  await context.handleMessage(bridgeWindow.webContents, packet.payload);
}
if (packet?.kind === "worker-message-from-view") {
  await webUiInvokeElectronBridgeMethod(bridgeWindow, "sendWorkerMessageFromView", [
    packet.workerId,
    packet.payload,
  ]);
}
```

## 5) Renderer web bridge (`window.electronBridge`)

In `webview/webui-bridge.js`, define the bridge only when preload bridge is absent.

```js
if (window.electronBridge?.sendMessageFromView) return;
```

Use WS adapter compatible with existing renderer message flow:

```js
window.electronBridge = {
  windowType: "web",
  sendMessageFromView: async (message) => sendPacket({ kind: "message-from-view", payload: message }),
  sendWorkerMessageFromView: async (workerId, message) =>
    sendPacket({ kind: "worker-message-from-view", workerId, payload: message }),
  subscribeToWorkerMessages: (...) => ...,
  getPathForFile: () => null,
};
```

Incoming WS packets are forwarded as browser `"message"` events:

```js
window.dispatchEvent(new MessageEvent("message", { data: packet.payload }));
```

## 6) Stability fixes added after testing

### A0) Forward IPC payload from any argument slot

In newer bundles, IPC payload is not always `args[0]`. Use first object arg with `type`.

```js
bridgeWindow.webContents.send = (channel, ...args) => {
  const payload = args.find(
    (value) =>
      value &&
      typeof value === "object" &&
      !Array.isArray(value) &&
      typeof value.type === "string",
  );
  if (payload) {
    broadcast({ kind: "message-for-view", payload });
  } else if (
    typeof channel === "string" &&
    channel.startsWith("codex_desktop:worker:") &&
    channel.endsWith(":for-view")
  ) {
    broadcast({
      kind: "worker-message-for-view",
      workerId: channel.slice("codex_desktop:worker:".length, -":for-view".length),
      payload: args[0],
    });
  }
  originalSend(channel, ...args);
};
```

### A) Single active socket guard

Avoid duplicate WS sessions and duplicated events:

```js
let activeSocketToken = 0;
const currentToken = ++activeSocketToken;
if (currentToken !== activeSocketToken) return;
```

### B) Trigger refresh when connection is marked connected

In renderer state manager:

```js
F5("client-status-changed", (e) => {
  if (e.params.status === "connected") {
    this.refreshRecentConversations({ sortKey: this.recentConversationsSortKey }).catch(() => {});
    for (const id of this.streamingConversations) this.broadcastConversationSnapshot(id);
  }
});
```

### C) Explicitly emit `client-status-changed` on ready

In main message handler (`type: "ready"`):

```js
broadcast({
  kind: "message-for-view",
  payload: {
    type: "ipc-broadcast",
    method: "client-status-changed",
    sourceClientId: null,
    version: 1,
    params: { status: "connected" },
  },
});
```

### D) Raise local WS inbound rate limit

Prevent local bridge churn from very chatty frontend traffic:

```js
const inboundLimit = webUiOptions.remote ? 240 : 5000;
if (++count > inboundLimit) {
  ws.close(1008, "Rate limit exceeded");
}
```

## 7) Scripts and run commands

Added scripts in `package.json`:

```json
"webui": "NODE_ENV=production electron . --webui",
"webui:remote": "NODE_ENV=production electron . --webui --remote"
```

Launch example used during patching:

```bash
env \
  CODEX_CLI_PATH='/opt/homebrew/bin/codex' \
  CUSTOM_CLI_PATH='/opt/homebrew/bin/codex' \
  '/Users/igor/temp/untitled folder 67/codex_reverse/meta/electron-runner/node_modules/.bin/electron' \
  '/Users/igor/temp/untitled folder 67/codex_reverse/readable' \
  --webui --port 4310
```

Open:

```bash
open http://127.0.0.1:4310/
```

## 8) Notes when patching installed `.app`

- `app.asar` and `app.asar.unpacked` are coupled.
- Renaming archive without matching `.unpacked` path can break extraction tooling.
- Safest workflow is patching a copy of the app bundle, then replacing atomically.

## 9) SSH Reverse-Engineering Findings

Original investigation of how Codex Desktop uses SSH internally.

### Scope

- Unpacked Electron build analysis (`app.asar` extracted)
- SSH execution path in worker runtime
- Remote Codex home resolution behavior

### Remote host detection

- Remote mode is enabled when host config kind is `ssh` or `brix`.

### Command execution model

- Remote commands are executed by building an argument list from `hostConfig.terminal_command`.
- Generic remote process runner appends:
  - `--`
  - environment assignments (if any)
  - requested command args

### SSH helper behavior

- Dedicated SSH command helper wraps commands with:
  - `sh -lc <quoted command>`
- Enforced SSH options:
  - `-o BatchMode=yes`
  - `-o ConnectTimeout=10`

### Git over remote

- Git command executor routes remote git commands through remote shell execution.
- Uses non-interactive mode via `GIT_TERMINAL_PROMPT=0`.

### Remote patch/apply flow

For remote apply operations, implementation performs:

1. Create temp dir (`mktemp -d ...`)
2. Write patch file (`cat > ...`)
3. Check file existence (`test -e`)
4. Run `git apply --3way ...`
5. Cleanup temp dir (`rm -rf`)

### Remote Codex home resolution

- Resolution command checks:
  - `$CODEX_HOME` if set
  - otherwise `$HOME/.codex`

Observed on test host:
- SSH non-interactive connection succeeded.
- `CODEX_HOME` env var: not set.
- `~/.codex`: exists.
- Effective Codex home fallback is `/home/ubuntu/.codex`.

### Risks / notes

- No explicit `StrictHostKeyChecking` or `known_hosts` overrides were observed in the checked SSH helper path.
- Actual auth and host-key behavior depends on existing SSH client/user config on the machine running Codex.

### Optional follow-ups

1. Add a startup check that prints resolved remote Codex home for each configured SSH host.
2. Add explicit host-key policy controls in host configuration if stricter behavior is required.
3. Add an automated smoke test that exercises remote `git apply` path end-to-end.

## 10) Log Triage and Fixes (Current Launcher)

### Fixed in launcher

- Force production flavor to remove dev-only startup failures/noise:

```bash
export BUILD_FLAVOR=prod
export NODE_ENV=production
```

This removes recurring devbox cache errors like:
- `Applied devbox cache refresh failed ... spawn applied ENOENT`

### Expected/noise (can be ignored for WebUI health)

- `No owner repo found for remote task ...`
- `IpcClient ... no handler is configured ...`
- `No promise for request ID ...`
- Git scan noise such as `config --get remote.upstream.url` exitCode `1`

### Actual blocker signatures

- `WebUI runtime start failed ... EADDRINUSE` (port already used)
- `Renderer guard patch anchor not found` (bundle pattern mismatch)

Use a free port to avoid EADDRINUSE:

```bash
./launch_codex_webui_unpacked.sh --port 6002
```

## 11) Auto-install Tool Bootstrap (Homebrew + required binaries)

Both launchers now attempt to auto-install missing prerequisites instead of failing immediately.

Updated files:

- `/Users/igor/.codex/worktrees/5b82/untitled folder 67/launch_codex_unpacked.sh`
- `/Users/igor/.codex/worktrees/5b82/untitled folder 67/launch_codex_webui_unpacked.sh`

### Behavior

1. Detect and activate Homebrew in PATH (`brew shellenv`, `/opt/homebrew/bin/brew`, `/usr/local/bin/brew`).
2. If Homebrew is missing and `AUTO_INSTALL_TOOLS=1` (default), install Homebrew non-interactively.
3. Install required packages via Homebrew when command probes fail.
4. If Homebrew path fails (no admin/sudo), fall back to user-space Node bootstrap.
5. Continue with normal launcher flow after dependencies are present.

`AUTO_INSTALL_TOOLS` control:

- Default: `AUTO_INSTALL_TOOLS=1` (auto-install enabled)
- Disable auto-install: `AUTO_INSTALL_TOOLS=0`

### Required tool mapping

- `launch_codex_unpacked.sh`:
  - tries Homebrew `node` install if `node`/`npx` is missing
  - falls back to user-space `nvm` install (`nvm install --lts`) when Homebrew install is unavailable
  - if `nvm` install fails, downloads user-space `fnm` binary directly from GitHub Releases and runs `fnm install --lts`
- `launch_codex_webui_unpacked.sh`:
  - tries Homebrew `node` install if `node`/`npx` is missing
  - falls back to user-space `nvm` install (`nvm install --lts`) when Homebrew install is unavailable
  - if `nvm` install fails, downloads user-space `fnm` binary directly from GitHub Releases and runs `fnm install --lts`
  - uses `rg` if present, otherwise falls back to `grep -E` for patch validation checks

### Known bootstrap failure signatures and fixes

- Failure (macOS VM without admin): Homebrew install prints `Need sudo access on macOS ...`.
- Failure (nvm install path): `You may be on a Mac, and need to install the Xcode Command Line Developer Tools.`
- Failure (first fnm attempt): `.../.local/share/fnm/fnm: cannot execute binary file` when Linux asset was selected on macOS.
- Failure (fnm CLI mismatch): `error: unexpected argument '--lts' found` from `fnm use --lts`.
- Fix: use OS-aware asset selection (`Darwin => fnm-macos.zip`, `Linux arm64 => fnm-arm64.zip`, `Linux x64 => fnm-linux.zip`).
- Fix: use `fnm use lts-latest` (compatible with fnm 1.38.x) after `fnm install --lts`.
- Fix: run Electron via `npx -y electron ...` so npm never prompts for `(y) Proceed?` during package install.
- Success signature after fix: `[webui] WebUI bridge started { host: '0.0.0.0', port: 6011, ... }` and HTTP probe returns `<!doctype html>`.

### Injected helper pattern

```bash
ensure_homebrew() {
  activate_homebrew_path
  if command -v brew >/dev/null 2>&1; then return; fi
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  activate_homebrew_path
}

ensure_brew_package() {
  local command_name="$1"
  local package_name="$2"
  command -v "$command_name" >/dev/null 2>&1 && return
  ensure_homebrew
  brew list "$package_name" >/dev/null 2>&1 || brew install "$package_name"
}

install_node_with_nvm() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash || return 1
  [[ -s "$NVM_DIR/nvm.sh" ]] || return 1
  source "$NVM_DIR/nvm.sh"
  nvm install --lts || return 1
  nvm use --lts || return 1
}

install_node_with_fnm() {
  local fnm_dir="${FNM_DIR:-$HOME/.local/share/fnm}"
  local tag asset
  tag="$(curl -fsSL https://api.github.com/repos/Schniz/fnm/releases/latest | ...)"
  # Darwin => fnm-macos.zip, Linux arm64 => fnm-arm64.zip, Linux x64 => fnm-linux.zip
  asset="<platform-specific>"
  curl -fsSL "https://github.com/Schniz/fnm/releases/download/$tag/$asset" -o "$tmp/fnm.zip" || return 1
  unzip -oq "$tmp/fnm.zip" -d "$fnm_dir" || return 1
  export PATH="$fnm_dir:$PATH"
  eval "$(fnm env --shell bash)" || return 1
  fnm install --lts || return 1
  fnm use --lts || return 1
}

## 12) GitHub Release Automation (release per push)

Added workflow:

- `/Users/igor/.codex/worktrees/5b82/untitled folder 67/.github/workflows/release-on-push.yml`

Behavior:

1. Triggers on every push to any branch.
2. Uses `softprops/action-gh-release@v2`.
3. Creates a unique tag per workflow run:
   - `auto-${{ github.run_number }}-${{ github.sha }}`
4. Publishes non-draft, non-prerelease release.
5. Includes launcher instruction text in release notes:
   - `open terminal and drag launch_codex_webui_unpacked.sh to it`
```

## 13) npm CLI packaging + npx symlink fix

Added npm wrapper files so users can run the launcher via `npx codex-web-ui`:

- `/Users/igor/.codex/worktrees/5b82/untitled folder 67/package.json`
- `/Users/igor/.codex/worktrees/5b82/untitled folder 67/bin/codex-web-ui`

Initial wrapper used:

```bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$DIR/launch_codex_webui_unpacked.sh" "$@"
```

## 14) SSH Autostart Dynamic Target Discovery (Cross-Version)

Updated file:

- `/Users/igor/.codex/worktrees/5b82/untitled folder 67/launch_codex_unpacked.sh`

### Problem fixed

Previous SSH autostart patching depended on one exact minified anchor:

```js
await kp.refresh({triggerProviderRefresh:!0}),await bu(Gt),await pM.flushPendingDeepLinks()
```

When Codex obfuscation changed across versions, this exact string often disappeared and patching failed with:

- `SSH autostart patch anchor not found.`

### New patch strategy

Launcher now performs dynamic sequence discovery using a regex over semantic call structure (refresh -> open target -> flush deep links), then rewrites only the first matched sequence.

```js
const sequenceRe = /await\s+([A-Za-z_$][\w$]*)\.refresh\(\{triggerProviderRefresh:!0\}\)\s*,\s*await\s+([A-Za-z_$][\w$]*)\(([A-Za-z_$][\w$]*)\)\s*,\s*await\s+([A-Za-z_$][\w$]*)\.flushPendingDeepLinks\(\)/g;
const matches = Array.from(source.matchAll(sequenceRe));
```

If no sequence matches, launcher emits:

- `SSH autostart patch anchor not found (dynamic matcher).`

### Host source decoupling from minified internals

Patched code no longer relies on internal minified getters (e.g. `IJ(Co)` style names). Instead it resolves the host from persistent global state at runtime:

```js
const __codexHome = process.env.CODEX_HOME || path.join(process.env.HOME || "", ".codex");
const __codexStateFile = path.join(__codexHome, ".codex-global-state.json");
const __codexHosts = Array.isArray(parsed?.["electron-ssh-hosts"]) ? parsed["electron-ssh-hosts"] : [];
```

If host list has entries, first host is used as startup target; otherwise launcher falls back to original default target variable from the matched sequence.

Issue found after publish:

- `npx codex-web-ui --help` failed because npm executes the command through a symlink in `node_modules/.bin`, so `BASH_SOURCE[0]` resolved to `.bin` instead of package `bin/`.
- Error signature:
  - `/node_modules/.bin/codex-web-ui: ... /node_modules/launch_codex_webui_unpacked.sh: No such file or directory`

Fix applied in `bin/codex-web-ui`:

```bash
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  LINK_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$LINK_DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
exec "$DIR/launch_codex_webui_unpacked.sh" "$@"
```
