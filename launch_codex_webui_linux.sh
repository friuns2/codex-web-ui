#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# launch_codex_webui.sh — Launch Codex Desktop with WebUI (Linux)
#
# This script patches the CodexDesktop-Rebuild source in-place (with backups)
# and launches the app with --webui mode, serving the UI over HTTP+WebSocket.
###############################################################################

CODEX_DIR="${CODEX_DIR:-$HOME/apps/CodexDesktop-Rebuild}"
PORT="${CODEX_WEBUI_PORT:-4310}"
REMOTE=0
TOKEN=""
ORIGINS=""
NO_OPEN=0
BRIDGE_PATH="$(cd "$(dirname "$0")" && pwd)/webui-bridge.js"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  launch_codex_webui.sh [options] [-- <extra electron args>]

Options:
  --codex-dir <path>     CodexDesktop-Rebuild directory (default: ~/apps/CodexDesktop-Rebuild)
  --port <n>             WebUI port (default: 4310)
  --remote               Bind to 0.0.0.0 instead of 127.0.0.1
  --token <value>        Auth token for remote mode
  --origins <csv>        Allowed origins CSV
  --bridge <path>        Path to webui-bridge.js
  --no-open              Don't open browser automatically
  -h, --help
USAGE
}

EXTRA_ARGS=()
while (($#)); do
  case "$1" in
    --codex-dir)  CODEX_DIR="${2:?missing value}"; shift 2 ;;
    --port)       PORT="${2:?missing value}"; shift 2 ;;
    --remote)     REMOTE=1; shift ;;
    --token)      TOKEN="${2:?missing value}"; shift 2 ;;
    --origins)    ORIGINS="${2:?missing value}"; shift 2 ;;
    --bridge)     BRIDGE_PATH="${2:?missing value}"; shift 2 ;;
    --no-open)    NO_OPEN=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    --)           shift; EXTRA_ARGS+=("$@"); break ;;
    *)            EXTRA_ARGS+=("$1"); shift ;;
  esac
done

# Validate paths
[[ -d "$CODEX_DIR" ]] || { echo "Codex directory not found: $CODEX_DIR" >&2; exit 1; }
[[ -f "$CODEX_DIR/package.json" ]] || { echo "Not a valid Codex project: $CODEX_DIR" >&2; exit 1; }
[[ -f "$BRIDGE_PATH" ]] || { echo "Missing bridge file: $BRIDGE_PATH" >&2; exit 1; }

MAIN_JS="$CODEX_DIR/src/.vite/build/main-WjwBKRS3.js"
WEBVIEW_DIR="$CODEX_DIR/src/webview"
INDEX_HTML="$WEBVIEW_DIR/index.html"

[[ -f "$MAIN_JS" ]] || { echo "Missing main bundle: $MAIN_JS" >&2; exit 1; }
[[ -f "$INDEX_HTML" ]] || { echo "Missing index.html: $INDEX_HTML" >&2; exit 1; }

# Find the renderer JS file
RENDERER_JS_REL="$(sed -nE 's@.*src="./assets/(index-[A-Za-z0-9_-]+\.js)".*@\1@p' "$INDEX_HTML" | head -n1)"
[[ -n "$RENDERER_JS_REL" ]] || { echo "Failed to find renderer JS in index.html" >&2; exit 1; }
RENDERER_JS="$WEBVIEW_DIR/assets/$RENDERER_JS_REL"
[[ -f "$RENDERER_JS" ]] || { echo "Missing renderer bundle: $RENDERER_JS" >&2; exit 1; }

echo "=== Codex WebUI Launcher (Linux) ==="
echo "Codex dir:    $CODEX_DIR"
echo "Main bundle:  $MAIN_JS"
echo "Renderer:     $RENDERER_JS"
echo "Bridge:       $BRIDGE_PATH"
echo "Port:         $PORT"
echo ""

###############################################################################
# Step 1: Backup originals (only if not already backed up)
###############################################################################
backup_file() {
  local f="$1"
  if [[ ! -f "${f}.webui-backup" ]]; then
    cp "$f" "${f}.webui-backup"
    echo "Backed up: $f"
  fi
}

backup_file "$MAIN_JS"
backup_file "$RENDERER_JS"
backup_file "$INDEX_HTML"

###############################################################################
# Step 2: Patch main bundle — inject WebUI runtime
###############################################################################
MARKER="/*__CODEX_WEBUI_RUNTIME_PATCH__*/"
if grep -qF "$MARKER" "$MAIN_JS"; then
  echo "Main bundle already patched, skipping."
else
  echo "Patching main bundle..."

  CHUNK_FILE="$(mktemp)"
  cat > "$CHUNK_FILE" <<'INJECTIONJS'
/*__CODEX_WEBUI_RUNTIME_PATCH__*/
;(() => {
  if (globalThis.__CODEX_WEBUI_RUNTIME_PATCHED__) return;
  globalThis.__CODEX_WEBUI_RUNTIME_PATCHED__ = true;

  function webUiParsePortArg(value, fallback) {
    const parsed = Number.parseInt(String(value ?? ""), 10);
    return Number.isFinite(parsed) && parsed >= 1 && parsed <= 65535 ? parsed : fallback;
  }

  function webUiParseCliOptions(argv = process.argv, env = process.env) {
    let enabled = false;
    let remote = false;
    let port = webUiParsePortArg(env.CODEX_WEBUI_PORT, 3210);
    let token = (env.CODEX_WEBUI_TOKEN ?? "").trim();
    let origins = (env.CODEX_WEBUI_ORIGINS ?? "")
      .split(",")
      .map((x) => x.trim())
      .filter(Boolean);

    for (let i = 0; i < argv.length; i += 1) {
      const arg = argv[i];
      if (arg === "--webui") { enabled = true; continue; }
      if (arg === "--remote") { remote = true; continue; }
      if (arg === "--port" && i + 1 < argv.length) {
        port = webUiParsePortArg(argv[i + 1], port); i += 1; continue;
      }
      if (arg.startsWith("--port=")) {
        port = webUiParsePortArg(arg.slice("--port=".length), port); continue;
      }
      if (arg === "--token" && i + 1 < argv.length) {
        token = String(argv[i + 1] ?? "").trim(); i += 1; continue;
      }
      if (arg.startsWith("--token=")) {
        token = arg.slice("--token=".length).trim(); continue;
      }
      if (arg.startsWith("--origins=")) {
        origins = arg.slice("--origins=".length).split(",").map((x) => x.trim()).filter(Boolean);
        continue;
      }
    }
    return { enabled, remote, port, token, origins };
  }

  const webUiOptions = webUiParseCliOptions();
  if (!webUiOptions.enabled) return;

  const http = require("node:http");
  const fs = require("node:fs");
  const path = require("node:path");
  const crypto = require("node:crypto");
  const { EventEmitter } = require("node:events");
  const electron = require("electron");

  // Simple logger that works regardless of the app's internal logger
  const webUiLog = {
    info: (...args) => console.log("[WebUI]", ...args),
    warning: (...args) => console.warn("[WebUI]", ...args),
    error: (...args) => console.error("[WebUI]", ...args),
  };

  // ---- Minimal WebSocket implementation (no external deps) ----
  class WebUiSocket extends EventEmitter {
    constructor(socket) {
      super();
      this.socket = socket;
      this.readyState = WebUiSocket.OPEN;
      this.closed = false;
      this.buffer = Buffer.alloc(0);
      socket.on("data", (chunk) => this.onData(chunk));
      socket.on("error", (err) => {
        this.emit("ws-error", err);
        this.finishClose(1006, String(err?.code ?? "socket-error"));
      });
      socket.on("close", () => this.finishClose(1006, ""));
      socket.on("end", () => this.finishClose(1006, ""));
    }
    send(data, callback) {
      if (this.readyState !== WebUiSocket.OPEN) {
        if (typeof callback === "function") callback(new Error("Socket is not open"));
        return;
      }
      const payload = Buffer.isBuffer(data) ? data : Buffer.from(String(data));
      this.socket.write(WebUiSocket.buildFrame(0x1, payload), callback);
    }
    close(code = 1000, reason = "") {
      if (this.readyState === WebUiSocket.CLOSED || this.readyState === WebUiSocket.CLOSING) return;
      this.readyState = WebUiSocket.CLOSING;
      let payload;
      try {
        const reasonBuf = Buffer.from(String(reason));
        payload = Buffer.allocUnsafe(2 + reasonBuf.length);
        payload.writeUInt16BE(code, 0);
        reasonBuf.copy(payload, 2);
      } catch { payload = Buffer.from([0x03, 0xe8]); }
      this.socket.write(WebUiSocket.buildFrame(0x8, payload), () => this.socket.end());
    }
    onData(chunk) {
      this.buffer = this.buffer.length === 0 ? chunk : Buffer.concat([this.buffer, chunk]);
      while (this.buffer.length >= 2) {
        const first = this.buffer[0];
        const second = this.buffer[1];
        const masked = (second & 0x80) !== 0;
        let payloadLen = second & 0x7f;
        let offset = 2;
        if (payloadLen === 126) {
          if (this.buffer.length < 4) return;
          payloadLen = this.buffer.readUInt16BE(2); offset = 4;
        } else if (payloadLen === 127) {
          if (this.buffer.length < 10) return;
          payloadLen = this.buffer.readUInt32BE(2) * 2 ** 32 + this.buffer.readUInt32BE(6);
          if (!Number.isSafeInteger(payloadLen)) { this.close(1009, "Frame too large"); return; }
          offset = 10;
        }
        let mask;
        if (masked) {
          if (this.buffer.length < offset + 4) return;
          mask = this.buffer.subarray(offset, offset + 4); offset += 4;
        }
        if (this.buffer.length < offset + payloadLen) return;
        let payload = this.buffer.subarray(offset, offset + payloadLen);
        this.buffer = this.buffer.subarray(offset + payloadLen);
        if (masked && mask) {
          payload = Buffer.from(payload);
          for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i & 3];
        }
        const opcode = first & 0x0f;
        if (opcode === 0x1) { this.emit("message", payload); continue; }
        if (opcode === 0x8) {
          let code = 1000, reason = "";
          if (payload.length >= 2) { code = payload.readUInt16BE(0); reason = payload.subarray(2).toString(); }
          if (this.readyState === WebUiSocket.OPEN) {
            this.socket.write(WebUiSocket.buildFrame(0x8, payload), () => this.socket.end());
          }
          this.finishClose(code, reason); return;
        }
        if (opcode === 0x9) { this.socket.write(WebUiSocket.buildFrame(0xA, payload)); continue; }
        if (opcode === 0xA) continue;
        this.close(1003, "Unsupported opcode"); return;
      }
    }
    finishClose(code, reason) {
      if (this.closed) return;
      this.closed = true; this.readyState = WebUiSocket.CLOSED;
      this.emit("close", code, reason);
    }
    static buildFrame(opcode, payload) {
      const len = payload.length;
      let headerLen = len < 126 ? 2 : len <= 65535 ? 4 : 10;
      const out = Buffer.allocUnsafe(headerLen + len);
      out[0] = 0x80 | (opcode & 0x0f);
      if (headerLen === 2) { out[1] = len; payload.copy(out, 2); }
      else if (headerLen === 4) { out[1] = 126; out.writeUInt16BE(len, 2); payload.copy(out, 4); }
      else { out[1] = 127; out.writeUInt32BE(Math.floor(len / 2 ** 32), 2); out.writeUInt32BE(len >>> 0, 6); payload.copy(out, 10); }
      return out;
    }
  }
  WebUiSocket.CONNECTING = 0; WebUiSocket.OPEN = 1; WebUiSocket.CLOSING = 2; WebUiSocket.CLOSED = 3;

  class WebUiSocketServer extends EventEmitter {
    handleUpgrade(req, socket, head, callback) {
      const key = req.headers["sec-websocket-key"];
      if (String(req.headers.upgrade ?? "").toLowerCase() !== "websocket" || !key) {
        socket.write("HTTP/1.1 400 Bad Request\r\n\r\n"); socket.destroy(); return;
      }
      const accept = crypto.createHash("sha1").update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
      socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
      if (head && head.length > 0) socket.unshift(head);
      callback(new WebUiSocket(socket), req);
    }
    close() { this.emit("close"); }
  }

  function webUiTokensEqual(a, b) {
    if (!a || !b) return false;
    try { const l = Buffer.from(a), r = Buffer.from(b); return l.length === r.length && crypto.timingSafeEqual(l, r); }
    catch { return false; }
  }

  function webUiExtractAuthToken(req, parsedUrl) {
    const auth = req.headers.authorization;
    if (typeof auth === "string" && auth.startsWith("Bearer ")) return auth.slice(7).trim();
    const ht = req.headers["x-codex-webui-token"];
    if (typeof ht === "string" && ht.trim()) return ht.trim();
    const qp = parsedUrl.searchParams.get("token");
    if (qp && qp.trim()) return qp.trim();
    const cookies = (req.headers.cookie ?? "").split(";").reduce((acc, s) => {
      const idx = s.indexOf("="); if (idx > 0) acc[s.slice(0, idx).trim()] = decodeURIComponent(s.slice(idx + 1).trim());
      return acc;
    }, {});
    return typeof cookies.codex_webui_token === "string" ? cookies.codex_webui_token.trim() : "";
  }

  function webUiInjectRuntimeScripts(html) {
    if (html.includes('/webui-bridge.js')) return html;
    const injection = '\n    <script src="/webui-config.js"><\/script>\n    <script src="/webui-bridge.js"><\/script>\n';
    return html.includes("</head>") ? html.replace("</head>", `${injection}</head>`) : `${injection}${html}`;
  }

  function webUiRelaxCSP(html) {
    // Remove or relax the CSP meta tag to allow ws: connections and inline scripts for bridge
    return html.replace(
      /<meta\s+http-equiv="Content-Security-Policy"[^>]*>/gi,
      '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; img-src \'self\' https: data: blob:; child-src \'self\' blob:; frame-src \'self\' blob:; worker-src \'self\' blob:; script-src \'self\' \'unsafe-inline\' \'wasm-unsafe-eval\'; style-src \'self\' \'unsafe-inline\'; font-src \'self\' data:; media-src \'self\' blob:; connect-src \'self\' ws: wss: https://ab.chatgpt.com https://cdn.openai.com;">'
    );
  }

  // ---- Discover internal app references at runtime ----
  // We hook into BrowserWindow creation to find the primary window and its context.

  async function waitForPrimaryWindow(timeoutMs = 30000) {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      const wins = electron.BrowserWindow.getAllWindows();
      const win = wins.find(w => !w.isDestroyed() && w.webContents && !w.webContents.isDestroyed());
      if (win) return win;
      await new Promise(r => setTimeout(r, 50));
    }
    return null;
  }

  // Find the message handler context by intercepting IPC
  let resolvedMessageHandler = null;

  function getMessageHandlerFromWindow(win) {
    // The app registers IPC handlers. We look for the handler that processes
    // "codex_desktop:message-from-view" channel messages.
    // We intercept webContents.send to discover the context.
    return resolvedMessageHandler;
  }

  async function webUiStartBridgeRuntime({ bridgeWindow }) {
    // Resolve the asset root — the webview directory
    // In dev mode, the app source is at CODEX_DIR/src, so webview is at CODEX_DIR/src/webview
    const appPath = electron.app.getAppPath();
    // In dev mode, webview is at src/webview relative to app root
    // In packaged mode, it would be at webview relative to app root
    let assetRoot = path.join(appPath, "webview");
    if (!fs.existsSync(assetRoot)) {
      assetRoot = path.join(appPath, "src", "webview");
    }

    webUiLog.info("Asset root:", assetRoot);
    webUiLog.info("App path:", appPath);

    const host = webUiOptions.remote ? "0.0.0.0" : "127.0.0.1";
    const authRequired = webUiOptions.remote || !!webUiOptions.token;
    const token = authRequired && !webUiOptions.token
      ? crypto.randomBytes(24).toString("hex")
      : webUiOptions.token;
    const originAllowlist = new Set(webUiOptions.origins);
    const sockets = new Set();
    let cachedIndexHtml = "";

    const IPC_CHANNEL = "codex_desktop:message-for-view";
    const WORKER_PREFIX = "codex_desktop:worker:";

    const originAllowed = (origin, hostHeader) => {
      if (typeof origin !== "string") return false;
      if (originAllowlist.size > 0) return originAllowlist.has(origin);
      try { return origin.length === 0 ? true : new URL(origin).host === hostHeader; }
      catch { return false; }
    };

    const broadcast = (packet) => {
      if (sockets.size === 0) return;
      let serialized;
      try { serialized = JSON.stringify(packet); } catch { return; }
      for (const ws of sockets) {
        if (ws.readyState !== WebUiSocket.OPEN) continue;
        ws.send(serialized, (err) => { if (err) webUiLog.warning("WS send failed", err.message); });
      }
    };

    // Intercept webContents.send to mirror IPC to WebSocket
    const originalSend = bridgeWindow.webContents.send.bind(bridgeWindow.webContents);
    bridgeWindow.webContents.send = (channel, ...args) => {
      if (channel === IPC_CHANNEL) {
        broadcast({ kind: "message-for-view", payload: args[0] });
      } else if (channel.startsWith(WORKER_PREFIX) && channel.endsWith(":for-view")) {
        broadcast({
          kind: "worker-message-for-view",
          workerId: channel.slice(WORKER_PREFIX.length, -":for-view".length),
          payload: args[0],
        });
      }
      originalSend(channel, ...args);
    };

    // Discover the message handler for codex_desktop:message-from-view
    // The app uses ipcMain.handle() (invoke/handle pattern), not ipcMain.on()
    const fromViewChannel = "codex_desktop:message-from-view";
    let messageHandlerFn = null;

    const createMessageHandler = (handler) => {
      return async (webContents, payload) => {
        const fakeEvent = {
          sender: webContents,
          senderFrame: webContents.mainFrame ?? null,
          ports: [],
          processId: webContents.getProcessId?.() ?? 0,
          frameId: 0,
          returnValue: undefined,
          reply: (...args) => webContents.send(...args),
        };
        try { await handler(fakeEvent, payload); }
        catch (e) { webUiLog.warning("IPC handler error:", e?.message ?? e); }
      };
    };

    // Monkey-patch ipcMain.handle to capture the handler when registered
    const origHandle = electron.ipcMain.handle.bind(electron.ipcMain);
    electron.ipcMain.handle = function(channel, handler) {
      if (channel === fromViewChannel) {
        webUiLog.info("Captured ipcMain.handle for", channel);
        messageHandlerFn = createMessageHandler(handler);
      }
      return origHandle(channel, handler);
    };

    // Check if handler already registered via Electron internals
    if (electron.ipcMain._invokeHandlers) {
      const existing = electron.ipcMain._invokeHandlers.get(fromViewChannel);
      if (existing) {
        webUiLog.info("Found existing ipcMain.handle handler for", fromViewChannel);
        messageHandlerFn = createMessageHandler(existing);
      }
    }

    // Fallback: poll for handler registration
    if (!messageHandlerFn) {
      webUiLog.info("Polling for IPC handler registration...");
      const poll = () => {
        if (messageHandlerFn) return;
        if (electron.ipcMain._invokeHandlers) {
          const h = electron.ipcMain._invokeHandlers.get(fromViewChannel);
          if (h) { webUiLog.info("Found handler via polling"); messageHandlerFn = createMessageHandler(h); return; }
        }
        setTimeout(poll, 100);
      };
      poll();
    }

    // HTTP server
    const server = http.createServer(async (req, res) => {
      const parsedUrl = new URL(req.url ?? "/", `http://${req.headers.host ?? "127.0.0.1"}`);

      // Security headers
      res.setHeader("X-Content-Type-Options", "nosniff");
      res.setHeader("X-Frame-Options", "DENY");
      res.setHeader("Referrer-Policy", "no-referrer");

      // Auth check
      if (authRequired) {
        const provided = webUiExtractAuthToken(req, parsedUrl);
        if (!webUiTokensEqual(provided, token)) {
          res.statusCode = 401; res.setHeader("Content-Type", "text/plain"); res.end("Unauthorized"); return;
        }
        if (parsedUrl.searchParams.get("token")) {
          res.setHeader("Set-Cookie", `codex_webui_token=${encodeURIComponent(token)}; Path=/; HttpOnly; SameSite=Lax`);
        }
      }

      // /webui-config.js — runtime config for the bridge
      if (parsedUrl.pathname === "/webui-config.js") {
        const config = JSON.stringify({
          wsPath: "/ws",
          buildFlavor: process.env.BUILD_FLAVOR || "dev",
          sentryInitOptions: null,
          appSessionId: null,
        });
        res.setHeader("Content-Type", "application/javascript; charset=utf-8");
        res.setHeader("Cache-Control", "no-store");
        res.end(`window.__CODEX_WEBUI_CONFIG__=${config};`);
        return;
      }

      // Resolve asset path
      let reqPath = parsedUrl.pathname;
      if (reqPath === "/" || reqPath === "/index.html") reqPath = "/index.html";

      let decoded;
      try { decoded = decodeURIComponent(reqPath); } catch { decoded = reqPath; }
      const rel = decoded.replace(/^[/\\]+/, "") || "index.html";
      const resolved = path.resolve(assetRoot, rel);

      // Security: ensure path is within assetRoot
      if (!resolved.startsWith(path.resolve(assetRoot) + path.sep) && resolved !== path.resolve(assetRoot)) {
        if (reqPath !== "/index.html") {
          // SPA fallback
        } else {
          res.statusCode = 403; res.end("Forbidden"); return;
        }
      }

      // Try to serve the file
      try {
        const stat = await fs.promises.stat(resolved);
        if (stat.isFile()) {
          if (path.basename(resolved) === "index.html") {
            if (!cachedIndexHtml) {
              let raw = await fs.promises.readFile(resolved, "utf8");
              raw = webUiRelaxCSP(raw);
              cachedIndexHtml = webUiInjectRuntimeScripts(raw);
            }
            res.setHeader("Content-Type", "text/html; charset=utf-8");
            res.setHeader("Cache-Control", "no-store");
            res.end(cachedIndexHtml);
            return;
          }

          const ext = path.extname(resolved).toLowerCase();
          const mimeMap = {
            ".html": "text/html", ".js": "application/javascript", ".mjs": "application/javascript",
            ".css": "text/css", ".json": "application/json", ".map": "application/json",
            ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
            ".gif": "image/gif", ".webp": "image/webp", ".ico": "image/x-icon",
            ".txt": "text/plain", ".wasm": "application/wasm", ".wav": "audio/wav",
          };
          const mime = mimeMap[ext] || "application/octet-stream";
          res.setHeader("Content-Type", mime.includes("charset") ? mime : `${mime}; charset=utf-8`);
          res.setHeader("Cache-Control", "no-store");
          fs.createReadStream(resolved).on("error", () => {
            if (!res.headersSent) { res.statusCode = 500; res.setHeader("Content-Type", "text/plain"); }
            res.end("Internal Server Error");
          }).pipe(res);
          return;
        }
      } catch { /* fall through to SPA fallback */ }

      // API/WS routes return 404
      if (reqPath.startsWith("/api") || reqPath.startsWith("/auth") || reqPath === "/ws") {
        res.statusCode = 404; res.setHeader("Content-Type", "text/plain"); res.end("Not Found"); return;
      }

      // SPA fallback
      if (!cachedIndexHtml) {
        try {
          let raw = await fs.promises.readFile(path.join(assetRoot, "index.html"), "utf8");
          raw = webUiRelaxCSP(raw);
          cachedIndexHtml = webUiInjectRuntimeScripts(raw);
        } catch { cachedIndexHtml = "<!doctype html><html><body><h1>Web UI unavailable</h1></body></html>"; }
      }
      res.setHeader("Content-Type", "text/html; charset=utf-8");
      res.setHeader("Cache-Control", "no-store");
      res.end(cachedIndexHtml);
    });

    // WebSocket server
    const wss = new WebUiSocketServer();

    server.on("upgrade", (req, socket, head) => {
      const parsedUrl = new URL(req.url ?? "/", `http://${req.headers.host ?? "127.0.0.1"}`);
      if (parsedUrl.pathname !== "/ws") { socket.write("HTTP/1.1 404 Not Found\r\n\r\n"); socket.destroy(); return; }
      if (!originAllowed(req.headers.origin ?? "", req.headers.host ?? "")) {
        socket.write("HTTP/1.1 403 Forbidden\r\n\r\n"); socket.destroy(); return;
      }
      if (authRequired && !webUiTokensEqual(webUiExtractAuthToken(req, parsedUrl), token)) {
        socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n"); socket.destroy(); return;
      }

      wss.handleUpgrade(req, socket, head, (ws) => {
        sockets.add(ws);
        ws.on("close", () => sockets.delete(ws));
        ws.on("ws-error", (err) => webUiLog.warning("WS error", err.message));

        let bucketStart = Date.now(), count = 0;
        const inboundLimit = webUiOptions.remote ? 240 : 5000;

        ws.on("message", async (raw) => {
          const now = Date.now();
          if (now - bucketStart > 60000) { bucketStart = now; count = 0; }
          if (++count > inboundLimit) { ws.close(1008, "Rate limit exceeded"); return; }

          let packet;
          try { packet = JSON.parse(String(raw)); }
          catch { ws.send(JSON.stringify({ kind: "bridge-error", message: "Invalid payload" })); return; }

          try {
            if (packet?.kind === "message-from-view") {
              const payload = packet.payload;
              if (!payload || typeof payload.type !== "string") return;

              if (messageHandlerFn) {
                await messageHandlerFn(bridgeWindow.webContents, payload);
              } else {
                webUiLog.warning("No message handler available yet");
              }

              if (payload.type === "ready") {
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
              }
              return;
            }

            if (packet?.kind === "worker-message-from-view") {
              if (typeof packet.workerId !== "string" || !packet.workerId) return;
              // Forward worker messages via the bridge window
              try {
                const code = `
                  Promise.resolve().then(async () => {
                    const bridge = window.electronBridge;
                    if (!bridge || typeof bridge.sendWorkerMessageFromView !== "function") return null;
                    return await bridge.sendWorkerMessageFromView(${JSON.stringify(packet.workerId)}, ${JSON.stringify(packet.payload)});
                  });
                `;
                await bridgeWindow.webContents.executeJavaScript(code, true);
              } catch (e) { webUiLog.warning("Worker message forward failed", e.message); }
              return;
            }
          } catch (err) {
            webUiLog.warning("Bridge dispatch failed", err.message);
            ws.send(JSON.stringify({ kind: "bridge-error", message: "Bridge dispatch failed" }));
          }
        });
      });
    });

    // Start listening
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(webUiOptions.port, host, () => {
        const addr = server.address();
        if (typeof addr === "object" && addr) webUiOptions.port = addr.port;
        server.off("error", reject);
        resolve();
      });
    });

    webUiLog.info(`WebUI bridge started on http://${host}:${webUiOptions.port}/`);
    if (authRequired) webUiLog.info("Access token:", token);

    return {
      host, port: webUiOptions.port, token: authRequired ? token : "",
      dispose: async () => {
        wss.close();
        for (const ws of sockets) { try { ws.close(1001, "Shutting down"); } catch {} }
        sockets.clear();
        await new Promise(r => server.close(() => r()));
        bridgeWindow.webContents.send = originalSend;
      },
    };
  }

  let webUiRuntime = null;
  let webUiBridgeWindow = null;
  let webUiStartPromise = null;

  async function webUiStart() {
    if (webUiStartPromise) return webUiStartPromise;
    webUiStartPromise = (async () => {
      const primaryWindow = await waitForPrimaryWindow();
      if (!primaryWindow) throw new Error("Timed out waiting for primary window");
      webUiBridgeWindow = primaryWindow;

      // Hide the Electron window — we're serving via HTTP
      try { primaryWindow.hide(); } catch {}

      primaryWindow.on("close", (event) => {
        if (!electron.app.isQuitting) {
          event.preventDefault();
          try { primaryWindow.hide(); } catch {}
        }
      });
      primaryWindow.on("minimize", () => { try { primaryWindow.hide(); } catch {} });

      webUiRuntime = await webUiStartBridgeRuntime({ bridgeWindow: primaryWindow });
      return webUiRuntime;
    })();
    return webUiStartPromise;
  }

  // Suppress all windows in WebUI mode
  electron.app.on("browser-window-created", (_event, win) => {
    if (!webUiOptions.enabled || !win || win.isDestroyed()) return;
    win.once("ready-to-show", () => { try { win.hide(); } catch {} });
    setImmediate(() => { try { win.hide(); } catch {} });
  });

  electron.app.whenReady().then(() => {
    webUiStart().catch((err) => webUiLog.error("WebUI start failed", err));
  });

  electron.app.on("activate", () => {
    if (!webUiOptions.enabled) return;
    const win = webUiBridgeWindow;
    if (win && !win.isDestroyed()) { try { win.hide(); } catch {} }
  });

  electron.app.on("will-quit", () => {
    if (webUiRuntime && typeof webUiRuntime.dispose === "function") {
      webUiRuntime.dispose().catch((err) => webUiLog.warning("Shutdown failed", err));
      webUiRuntime = null;
    }
  });

  // Track app quitting state
  let _isQuitting = false;
  Object.defineProperty(electron.app, 'isQuitting', {
    get: () => _isQuitting,
    configurable: true,
  });
  electron.app.on("before-quit", () => { _isQuitting = true; });
})();
INJECTIONJS

  # Inject the chunk before the sourceMappingURL line
  node - "$MAIN_JS" "$CHUNK_FILE" <<'NODE'
const fs = require("node:fs");
const mainFile = process.argv[2];
const chunkFile = process.argv[3];
const marker = "/*__CODEX_WEBUI_RUNTIME_PATCH__*/";
let source = fs.readFileSync(mainFile, "utf8");
if (source.includes(marker)) { process.exit(0); }
const chunk = fs.readFileSync(chunkFile, "utf8");
const mapIndex = source.lastIndexOf("//# sourceMappingURL=");
if (mapIndex >= 0) {
  source = `${source.slice(0, mapIndex)}\n${chunk}\n${source.slice(mapIndex)}`;
} else {
  source = `${source}\n${chunk}\n`;
}
fs.writeFileSync(mainFile, source, "utf8");
NODE

  rm -f "$CHUNK_FILE"
  echo "Main bundle patched."
fi

###############################################################################
# Step 3: Patch renderer bundle — add Array.isArray guard for roots
###############################################################################
RENDERER_FIND="if(!v)return;const T=v.roots.map(A4),A=g.current;"
RENDERER_REPLACE="if(!v||!Array.isArray(v.roots))return;const T=v.roots.map(A4),A=g.current;"

if grep -qF '!Array.isArray(v.roots)' "$RENDERER_JS"; then
  echo "Renderer already patched, skipping."
else
  echo "Patching renderer bundle..."
  node - "$RENDERER_JS" <<NODE
const fs = require("node:fs");
const file = process.argv[2];
let source = fs.readFileSync(file, "utf8");
const find = $(printf '%s' "$RENDERER_FIND" | node -e "process.stdout.write(JSON.stringify(require('fs').readFileSync('/dev/stdin','utf8')))");
const replace = $(printf '%s' "$RENDERER_REPLACE" | node -e "process.stdout.write(JSON.stringify(require('fs').readFileSync('/dev/stdin','utf8')))");
if (!source.includes(find)) {
  // Try to find a similar pattern
  const altFind = source.match(/if\(!v\)return;const \w+=v\.roots\.map\(\w+\),\w+=\w+\.current;/);
  if (altFind) {
    const altReplace = altFind[0].replace("if(!v)return;", "if(!v||!Array.isArray(v.roots))return;");
    source = source.replace(altFind[0], altReplace);
    console.log("Renderer patched with alternative pattern:", altFind[0]);
  } else {
    console.error("Renderer guard patch anchor not found - skipping (may still work).");
    process.exit(0);
  }
} else {
  source = source.replace(find, replace);
}
fs.writeFileSync(file, source, "utf8");
NODE
  echo "Renderer patched."
fi

###############################################################################
# Step 4: Copy bridge file to webview directory
###############################################################################
if [[ ! -f "$WEBVIEW_DIR/webui-bridge.js" ]] || ! diff -q "$BRIDGE_PATH" "$WEBVIEW_DIR/webui-bridge.js" >/dev/null 2>&1; then
  cp "$BRIDGE_PATH" "$WEBVIEW_DIR/webui-bridge.js"
  echo "Bridge file copied to webview."
else
  echo "Bridge file already in place."
fi

###############################################################################
# Step 5: Verify patches
###############################################################################
echo ""
echo "Verifying patches..."
grep -qF '__CODEX_WEBUI_RUNTIME_PATCH__' "$MAIN_JS" || { echo "FAIL: Main bundle missing runtime marker" >&2; exit 1; }
grep -qF 'sendMessageFromView' "$WEBVIEW_DIR/webui-bridge.js" || { echo "FAIL: Bridge file invalid" >&2; exit 1; }
echo "All patches verified."

###############################################################################
# Step 6: Detect platform and find CLI binary
###############################################################################
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) PLATFORM_DIR="linux-arm64" ;;
  x86_64)        PLATFORM_DIR="linux-x64" ;;
  *)             echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

CLI_PATH="$CODEX_DIR/resources/bin/$PLATFORM_DIR/codex"
[[ -x "$CLI_PATH" ]] || { echo "Missing codex CLI binary: $CLI_PATH" >&2; exit 1; }

###############################################################################
# Step 7: Find electron binary
###############################################################################
ELECTRON_BIN="$CODEX_DIR/node_modules/.bin/electron"
[[ -x "$ELECTRON_BIN" ]] || ELECTRON_BIN="$(command -v electron 2>/dev/null || true)"
[[ -x "$ELECTRON_BIN" ]] || { echo "Electron binary not found" >&2; exit 1; }

###############################################################################
# Step 8: Build launch command
###############################################################################
CMD=("$ELECTRON_BIN" "$CODEX_DIR" --webui --port "$PORT")
if [[ "$REMOTE" -eq 1 ]]; then CMD+=(--remote); fi
if [[ -n "$TOKEN" ]]; then CMD+=(--token "$TOKEN"); fi
if [[ -n "$ORIGINS" ]]; then CMD+=(--origins "$ORIGINS"); fi
if ((${#EXTRA_ARGS[@]})); then CMD+=("${EXTRA_ARGS[@]}"); fi

# Set environment
unset ELECTRON_RUN_AS_NODE
export ELECTRON_FORCE_IS_PACKAGED=true
export CODEX_CLI_PATH="$CLI_PATH"
export CUSTOM_CLI_PATH="$CLI_PATH"
export BUILD_FLAVOR="${BUILD_FLAVOR:-dev}"

# Ensure DISPLAY is set for headless environments
if [[ -z "${DISPLAY:-}" ]]; then
  if pgrep -x Xvfb >/dev/null 2>&1; then
    export DISPLAY=:99
    echo "Using existing Xvfb display :99"
  else
    echo "Warning: No DISPLAY set. Starting Xvfb..."
    Xvfb :99 -screen 0 1920x1080x24 >/dev/null 2>&1 &
    sleep 1
    export DISPLAY=:99
  fi
fi

echo ""
echo "=== Launching Codex WebUI ==="
echo "CLI:     $CLI_PATH"
echo "Display: $DISPLAY"
printf 'Command:'; printf ' %q' "${CMD[@]}"; echo
echo ""

###############################################################################
# Step 9: Open browser after server is ready
###############################################################################
if [[ "$NO_OPEN" -eq 0 ]]; then
  (
    for _ in {1..120}; do
      if curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
        echo ""
        echo "=========================================="
        echo "  WebUI ready at: http://127.0.0.1:${PORT}/"
        echo "=========================================="
        echo ""
        xdg-open "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 || true
        exit 0
      fi
      sleep 0.25
    done
    echo "Warning: WebUI did not become ready within 30 seconds"
  ) &
fi

###############################################################################
# Step 10: Launch
###############################################################################
exec "${CMD[@]}"
