#!/usr/bin/env bash
set -euo pipefail

APP_PATH="/Applications/Codex.app"
APP_ASAR="$APP_PATH/Contents/Resources/app.asar"
CLI_PATH="$APP_PATH/Contents/Resources/codex"
# Derive a deterministic port from the running directory path.
# Hash the absolute path of the current working directory and map it into
# the range 10000-59999 so each project directory gets its own port by default.
_dir_hash_port() {
  local dir_path
  dir_path="$(pwd -P)"
  # Use a simple portable hash: sum of bytes mod range + base
  local hash
  hash=$(printf '%s' "$dir_path" | cksum | awk '{print $1}')
  echo $(( (hash % 50000) + 10000 ))
}
PORT="${CODEX_WEBUI_PORT:-$(_dir_hash_port)}"
REMOTE=0
TOKEN=""
ORIGINS=""
KEEP_TEMP=0
NO_OPEN=0
USER_DATA_DIR=""
BRIDGE_PATH="$(cd "$(dirname "$0")" && pwd)/webui-bridge.js"

usage() {
  cat <<'USAGE'
Usage:
  launch_codex_webui_unpacked.sh [options] [-- <extra args>]

Options:
  --app <path>           Codex.app path
  --port <n>             webui port (default: 4310)
  --remote               pass --remote
  --token <value>        pass --token for remote mode auth
  --origins <csv>        pass --origins allowlist
  --bridge <path>        standalone webui-bridge.js path
  --user-data-dir <path> chromium user data dir override
  --no-open              don't open browser
  --keep-temp            keep temp extracted app dir
  -h, --help
USAGE
}

write_main_injection_chunk() {
  local dest="$1"
  cat > "$dest" <<'JS'
/*__CODEX_WEBUI_RUNTIME_PATCH__*/
;(() => {
  if (globalThis.__CODEX_WEBUI_RUNTIME_PATCHED__) return;
  globalThis.__CODEX_WEBUI_RUNTIME_PATCHED__ = true;

  function webUiParsePortArg(value, fallback) {
    const parsed = Number.parseInt(String(value ?? ""), 10);
    return Number.isFinite(parsed) && parsed >= 1 && parsed <= 65535 ? parsed : fallback;
  }

  function webUiDirHashPort(dirPath) {
    let hash = 0;
    const buf = Buffer.from(dirPath || process.cwd());
    for (let i = 0; i < buf.length; i++) hash = (hash + buf[i]) | 0;
    return ((((hash % 50000) + 50000) % 50000) + 10000);
  }

  function webUiParseCliOptions(argv = process.argv, env = process.env) {
    let enabled = false;
    let remote = false;
    let port = webUiParsePortArg(env.CODEX_WEBUI_PORT, webUiDirHashPort(process.cwd()));
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
    return html.replace(
      /<meta\s+http-equiv="Content-Security-Policy"[^>]*>/gi,
      '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; img-src \'self\' https: data: blob:; child-src \'self\' blob:; frame-src \'self\' blob:; worker-src \'self\' blob:; script-src \'self\' \'unsafe-inline\' \'wasm-unsafe-eval\'; style-src \'self\' \'unsafe-inline\'; font-src \'self\' data:; media-src \'self\' blob:; connect-src \'self\' ws: wss: https://ab.chatgpt.com https://cdn.openai.com;">'
    );
  }

  // ---- Wait for the primary app window ----
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

  // ---- Capture the IPC handler function ----
  let resolvedMessageHandler = null;

  function createMessageHandler(handler) {
    return handler;   // store the raw handler; we build fakeEvent per-call
  }

  // =========================================================================
  // Per-tab session manager  (lightweight — NO extra BrowserWindows)
  //
  // Each WebSocket connection gets a *proxy webContents* object.  When the
  // Codex IPC handler calls `event.sender.send(channel, data)`, the proxy
  // forwards it over the correct WebSocket — giving every browser tab its
  // own isolated message stream without the cost of an extra renderer.
  // =========================================================================
  const IPC_CHANNEL  = "codex_desktop:message-for-view";
  const WORKER_PREFIX = "codex_desktop:worker:";

  // Methods whose responses are *unicast* (sent only to the requester).
  // Anything NOT in this set is treated as a broadcast.
  const _broadcastMethods = new Set([
    "skills_update_available",
    "client-status-changed",
  ]);

  // Notification throttle — prevent skills_update_available storms
  const _notifThrottle = { last: 0, intervalMs: 2000 };
  function shouldThrottleNotif(method) {
    if (method !== "skills_update_available") return false;
    const now = Date.now();
    if (now - _notifThrottle.last < _notifThrottle.intervalMs) return true;
    _notifThrottle.last = now;
    return false;
  }

  class SessionManager {
    constructor({ primaryWindow }) {
      this._primaryWindow = primaryWindow;
      this._sessions = new Map();
      this._nextId = 1;
      this._ipcHandler = null;
      this._pendingRequests = new Map();
      this._requestStack = [];

      this._origPrimarySend = primaryWindow.webContents.send.bind(
        primaryWindow.webContents
      );
      const self = this;
      primaryWindow.webContents.send = function(channel, ...args) {
        self._origPrimarySend(channel, ...args);

        if (channel === IPC_CHANNEL) {
          const payload = args[0];
          const method = payload?.method ?? payload?.type ?? "";
          if (shouldThrottleNotif(method)) return;

          const reqId = payload?.requestId;
          if (reqId && self._pendingRequests.has(reqId)) {
            const targetWs = self._pendingRequests.get(reqId);
            self._pendingRequests.delete(reqId);
            self._sendToWs(targetWs, { kind: "message-for-view", payload });
            return;
          }

          if (_broadcastMethods.has(method)) {
            self._broadcastAll({ kind: "message-for-view", payload });
            return;
          }

          if (payload?.type === "ipc-broadcast") {
            const bcastMethod = payload?.method ?? "";
            if (bcastMethod === "client-status-changed" ||
                bcastMethod === "codex-app-server-connection-changed" ||
                bcastMethod === "codex-app-server-initialized") {
              self._broadcastAll({ kind: "message-for-view", payload });
              return;
            }
          }

          if (self._requestStack.length > 0) {
            const target = self._requestStack[self._requestStack.length - 1];
            self._sendToWs(target, { kind: "message-for-view", payload });
            return;
          }
        } else if (
          channel.startsWith(WORKER_PREFIX) &&
          channel.endsWith(":for-view")
        ) {
          const workerId = channel.slice(
            WORKER_PREFIX.length,
            -":for-view".length
          );
          const packet = {
            kind: "worker-message-for-view",
            workerId,
            payload: args[0],
          };
          if (self._requestStack.length > 0) {
            const target = self._requestStack[self._requestStack.length - 1];
            self._sendToWs(target, packet);
          }
        }
      };
    }

    _sendToWs(ws, packet) {
      if (ws.readyState !== WebUiSocket.OPEN) return;
      try { ws.send(JSON.stringify(packet)); } catch {}
    }

    _broadcastAll(packet) {
      const serialized = JSON.stringify(packet);
      for (const [ws] of this._sessions) {
        if (ws.readyState === WebUiSocket.OPEN) {
          try { ws.send(serialized); } catch {}
        }
      }
    }

    set ipcHandler(fn) { this._ipcHandler = fn; }

    createSession(ws) {
      const sessionId = `session-${this._nextId++}`;
      webUiLog.info(`Creating ${sessionId} (lightweight proxy)`);
      this._sessions.set(ws, { sessionId });
      return { sessionId };
    }

    destroySession(ws) {
      const session = this._sessions.get(ws);
      if (!session) return;
      this._sessions.delete(ws);
      for (const [reqId, pendingWs] of this._pendingRequests) {
        if (pendingWs === ws) this._pendingRequests.delete(reqId);
      }
      this._requestStack = this._requestStack.filter(w => w !== ws);
      webUiLog.info(`Destroying ${session.sessionId}`);
    }

    async handleMessage(ws, payload) {
      const session = this._sessions.get(ws);
      if (!session) {
        webUiLog.warning("No session for WS client");
        return;
      }
      if (!this._ipcHandler) {
        webUiLog.warning("IPC handler not ready yet");
        return;
      }

      const reqId = payload?.requestId;
      if (reqId) {
        this._pendingRequests.set(reqId, ws);
        setTimeout(() => this._pendingRequests.delete(reqId), 30000);
      }

      this._requestStack.push(ws);

      const primaryWC = this._primaryWindow.webContents;
      const fakeEvent = {
        sender: primaryWC,
        senderFrame: primaryWC.mainFrame ?? null,
        ports: [],
        processId: primaryWC.getProcessId?.() ?? 0,
        frameId: 0,
        returnValue: undefined,
        reply: (...args) => primaryWC.send(...args),
      };

      try {
        await this._ipcHandler(fakeEvent, payload);
      } catch (e) {
        webUiLog.warning(`IPC handler error (${session.sessionId}):`, e?.message ?? e);
      } finally {
        setTimeout(() => {
          const idx = this._requestStack.lastIndexOf(ws);
          if (idx >= 0) this._requestStack.splice(idx, 1);
        }, 500);
      }
    }

    async handleWorkerMessage(ws, workerId, workerPayload) {
      const session = this._sessions.get(ws);
      if (!session) return;
      this._requestStack.push(ws);
      try {
        const code = `
          Promise.resolve().then(async () => {
            const bridge = window.electronBridge;
            if (!bridge || typeof bridge.sendWorkerMessageFromView !== "function") return null;
            return await bridge.sendWorkerMessageFromView(${JSON.stringify(workerId)}, ${JSON.stringify(workerPayload)});
          });
        `;
        await this._primaryWindow.webContents.executeJavaScript(code, true);
      } catch (e) {
        webUiLog.warning(`Worker message failed (${session.sessionId}):`, e.message);
      } finally {
        setTimeout(() => {
          const idx = this._requestStack.lastIndexOf(ws);
          if (idx >= 0) this._requestStack.splice(idx, 1);
        }, 500);
      }
    }

    destroyAll() {
      for (const [ws] of this._sessions) {
        this.destroySession(ws);
      }
    }
  }

  // =========================================================================
  // Bridge runtime — HTTP server + WebSocket server + session manager
  // =========================================================================
  async function webUiStartBridgeRuntime({ bridgeWindow }) {
    const appPath = electron.app.getAppPath();
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
    let cachedIndexHtml = "";

    const fromViewChannel = "codex_desktop:message-from-view";
    let rawIpcHandler = null;

    const originAllowed = (origin, hostHeader) => {
      if (typeof origin !== "string") return false;
      if (originAllowlist.size > 0) return originAllowlist.has(origin);
      try { return origin.length === 0 ? true : new URL(origin).host === hostHeader; }
      catch { return false; }
    };

    // ---- Session manager (lightweight — no extra BrowserWindows) ----
    const sessionMgr = new SessionManager({ primaryWindow: bridgeWindow });

    // ---- Capture IPC handler ----
    const origHandle = electron.ipcMain.handle.bind(electron.ipcMain);
    electron.ipcMain.handle = function(channel, handler) {
      if (channel === fromViewChannel) {
        webUiLog.info("Captured ipcMain.handle for", channel);
        rawIpcHandler = handler;
        sessionMgr.ipcHandler = handler;
      }
      return origHandle(channel, handler);
    };

    if (electron.ipcMain._invokeHandlers) {
      const existing = electron.ipcMain._invokeHandlers.get(fromViewChannel);
      if (existing) {
        webUiLog.info("Found existing ipcMain.handle handler for", fromViewChannel);
        rawIpcHandler = existing;
        sessionMgr.ipcHandler = existing;
      }
    }

    if (!rawIpcHandler) {
      webUiLog.info("Polling for IPC handler registration...");
      const poll = () => {
        if (rawIpcHandler) return;
        if (electron.ipcMain._invokeHandlers) {
          const h = electron.ipcMain._invokeHandlers.get(fromViewChannel);
          if (h) {
            webUiLog.info("Found handler via polling");
            rawIpcHandler = h;
            sessionMgr.ipcHandler = h;
            return;
          }
        }
        setTimeout(poll, 100);
      };
      poll();
    }

    // ---- HTTP server ----
    const server = http.createServer(async (req, res) => {
      const parsedUrl = new URL(req.url ?? "/", `http://${req.headers.host ?? "127.0.0.1"}`);

      res.setHeader("X-Content-Type-Options", "nosniff");
      res.setHeader("X-Frame-Options", "DENY");
      res.setHeader("Referrer-Policy", "no-referrer");

      if (authRequired) {
        const provided = webUiExtractAuthToken(req, parsedUrl);
        if (!webUiTokensEqual(provided, token)) {
          res.statusCode = 401; res.setHeader("Content-Type", "text/plain"); res.end("Unauthorized"); return;
        }
        if (parsedUrl.searchParams.get("token")) {
          res.setHeader("Set-Cookie", `codex_webui_token=${encodeURIComponent(token)}; Path=/; HttpOnly; SameSite=Lax`);
        }
      }

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

      let reqPath = parsedUrl.pathname;
      if (reqPath === "/" || reqPath === "/index.html") reqPath = "/index.html";

      let decoded;
      try { decoded = decodeURIComponent(reqPath); } catch { decoded = reqPath; }
      const rel = decoded.replace(/^[/\\]+/, "") || "index.html";
      const resolved = path.resolve(assetRoot, rel);

      if (!resolved.startsWith(path.resolve(assetRoot) + path.sep) && resolved !== path.resolve(assetRoot)) {
        if (reqPath !== "/index.html") { /* SPA fallback below */ }
        else { res.statusCode = 403; res.end("Forbidden"); return; }
      }

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

      if (reqPath.startsWith("/api") || reqPath.startsWith("/auth") || reqPath === "/ws") {
        res.statusCode = 404; res.setHeader("Content-Type", "text/plain"); res.end("Not Found"); return;
      }

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

    // ---- WebSocket server ----
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
        // Register this tab — lightweight, no extra BrowserWindow
        const session = sessionMgr.createSession(ws);
        webUiLog.info(`Tab connected: ${session.sessionId}`);

        ws.on("close", () => {
          sessionMgr.destroySession(ws);
        });

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

              await sessionMgr.handleMessage(ws, payload);

              if (payload.type === "ready") {
                // Send connected status to this tab
                const statusPacket = JSON.stringify({
                  kind: "message-for-view",
                  payload: {
                    type: "ipc-broadcast",
                    method: "client-status-changed",
                    sourceClientId: null,
                    version: 1,
                    params: { status: "connected" },
                  },
                });
                ws.send(statusPacket, () => {});
              }
              return;
            }

            if (packet?.kind === "worker-message-from-view") {
              if (typeof packet.workerId !== "string" || !packet.workerId) return;
              await sessionMgr.handleWorkerMessage(ws, packet.workerId, packet.payload);
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
        sessionMgr.destroyAll();
        wss.close();
        await new Promise(r => server.close(() => r()));
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
JS
}

apply_main_chunk() {
  local main_file="$1"
  local chunk_file="$2"

  node - "$main_file" "$chunk_file" <<'NODE'
const fs = require("node:fs");
const mainFile = process.argv[2];
const chunkFile = process.argv[3];

const marker = "/*__CODEX_WEBUI_RUNTIME_PATCH__*/";
let source = fs.readFileSync(mainFile, "utf8");
if (source.includes(marker)) {
  process.exit(0);
}

const chunk = fs.readFileSync(chunkFile, "utf8");
const mapIndex = source.lastIndexOf("//# sourceMappingURL=");
if (mapIndex >= 0) {
  source = `${source.slice(0, mapIndex)}\n${chunk}\n${source.slice(mapIndex)}`;
} else {
  source = `${source}\n${chunk}\n`;
}
fs.writeFileSync(mainFile, source, "utf8");
NODE
}

patch_renderer_bundle() {
  local renderer_file="$1"
  node - "$renderer_file" <<'RENDERERNODE'
const fs = require("node:fs");
const file = process.argv[2];
let s = fs.readFileSync(file, "utf8");
let count = 0;

// 1. Array.isArray guard for v.roots.map
const rootsRe = /if\(!v\)return;const (\w+)=v\.roots\.map\((\w+)\),(\w+)=(\w+)\.current;/;
const rootsMatch = s.match(rootsRe);
if (rootsMatch) {
  s = s.replace(rootsMatch[0],
    rootsMatch[0].replace("if(!v)return;", "if(!v||!Array.isArray(v.roots))return;"));
  count++;
  console.log("  [1] v.roots.map guard applied");
}

// 2. Guard j.data.map — protect against undefined .data
const dataMapRe = /(\w+)\.data\.map\(/g;
let dm;
while ((dm = dataMapRe.exec(s)) !== null) {
  const varName = dm[1];
  const orig = dm[0];
  const safe = `(Array.isArray(${varName}?.data)?${varName}.data:[]).map(`;
  if (!s.includes(safe)) {
    s = s.replace(orig, safe);
    count++;
    console.log(`  [2] ${varName}.data.map guard applied`);
    break;
  }
}

// 3. Guard .turns.map
const turnsMapRe = /(\w+)\.turns\.map\(/g;
let tm;
const turnsMapGuarded = new Set();
while ((tm = turnsMapRe.exec(s)) !== null) {
  const varName = tm[1];
  const orig = tm[0];
  const safe = `(Array.isArray(${varName}?.turns)?${varName}.turns:[]).map(`;
  if (!turnsMapGuarded.has(orig) && !s.includes(safe)) {
    s = s.replace(orig, safe);
    turnsMapGuarded.add(orig);
    count++;
    console.log(`  [3] ${varName}.turns.map guard applied`);
  }
}

// 4. Guard .turns.find
const turnsFindRe = /(\w+)\.turns\.find\(/g;
let tf;
const turnsFindGuarded = new Set();
while ((tf = turnsFindRe.exec(s)) !== null) {
  const varName = tf[1];
  const orig = tf[0];
  const safe = `(Array.isArray(${varName}?.turns)?${varName}.turns:[]).find(`;
  if (!turnsFindGuarded.has(orig) && !s.includes(safe)) {
    s = s.replace(orig, safe);
    turnsFindGuarded.add(orig);
    count++;
    console.log(`  [4] ${varName}.turns.find guard applied`);
  }
}

// 5. Guard .turns.push — use optional chaining
const turnsPushRe = /(\w+)\.turns\.push\(/g;
let tp;
const turnsPushGuarded = new Set();
while ((tp = turnsPushRe.exec(s)) !== null) {
  const varName = tp[1];
  const orig = tp[0];
  const safe = `${varName}.turns?.push(`;
  if (!turnsPushGuarded.has(orig) && !s.includes(`${varName}.turns?.push(`)) {
    s = s.replace(orig, safe);
    turnsPushGuarded.add(orig);
    count++;
    console.log(`  [5] ${varName}.turns.push guard applied`);
  }
}

// 6. Guard x.files.map
const filesMapRe = /(\w+)\.files\.map\(/g;
let fm;
while ((fm = filesMapRe.exec(s)) !== null) {
  const varName = fm[1];
  const orig = fm[0];
  const safe = `(Array.isArray(${varName}?.files)?${varName}.files:[]).map(`;
  if (!s.includes(safe)) {
    s = s.replace(orig, safe);
    count++;
    console.log(`  [6] ${varName}.files.map guard applied`);
    break;
  }
}

// 7. Patch error boundary to auto-reload on persistent errors
const ebRe = /getDerivedStateFromError\(\w+\)\{return\{hasError:!0\}\}/;
const ebMatch = s.match(ebRe);
if (ebMatch) {
  const ebOrig = ebMatch[0];
  const ebSafe = ebOrig.replace(
    "return{hasError:!0}",
    "return{hasError:!0,errorCount:(this?.state?.errorCount||0)+1}"
  );
  s = s.replace(ebOrig, ebSafe);

  const cdcRe = /componentDidCatch\((\w+),(\w+)\)\{/;
  const cdcMatch = s.match(cdcRe);
  if (cdcMatch) {
    const cdcOrig = cdcMatch[0];
    s = s.replace(cdcOrig, cdcOrig +
      `try{const _ec=(this.state&&this.state.errorCount)||0;` +
      `if(_ec<=5){setTimeout(()=>{try{this.setState({hasError:false,errorCount:_ec})}catch(e){}},300*_ec);}` +
      `else if(_ec<=8){setTimeout(()=>{try{this.setState({hasError:false,errorCount:_ec})}catch(e){}},1000);}` +
      `else{setTimeout(()=>{try{window.location.reload()}catch(e){}},2000);}}catch(_e){}`
    );
    count++;
    console.log("  [7] Error boundary auto-retry + reload applied");
  }
}

console.log(`Renderer: ${count} guard(s) applied`);
fs.writeFileSync(file, s, "utf8");
RENDERERNODE
}

EXTRA_ARGS=()
while (($#)); do
  case "$1" in
    --app)
      APP_PATH="${2:?missing value}"; APP_ASAR="$APP_PATH/Contents/Resources/app.asar"; CLI_PATH="$APP_PATH/Contents/Resources/codex"; shift 2 ;;
    --port)
      PORT="${2:?missing value}"; shift 2 ;;
    --remote)
      REMOTE=1; shift ;;
    --token)
      TOKEN="${2:?missing value}"; shift 2 ;;
    --origins)
      ORIGINS="${2:?missing value}"; shift 2 ;;
    --bridge)
      BRIDGE_PATH="${2:?missing value}"; shift 2 ;;
    --user-data-dir)
      USER_DATA_DIR="${2:?missing value}"; shift 2 ;;
    --no-open)
      NO_OPEN=1; shift ;;
    --keep-temp)
      KEEP_TEMP=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; EXTRA_ARGS+=("$@"); break ;;
    *)
      EXTRA_ARGS+=("$1"); shift ;;
  esac
done

[[ -f "$APP_ASAR" ]] || { echo "Missing app.asar: $APP_ASAR" >&2; exit 1; }
[[ -x "$CLI_PATH" ]] || { echo "Missing codex binary: $CLI_PATH" >&2; exit 1; }
[[ -f "$BRIDGE_PATH" ]] || { echo "Missing standalone bridge file: $BRIDGE_PATH" >&2; exit 1; }
command -v npx >/dev/null 2>&1 || { echo "npx is required" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "node is required" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-webui-unpacked.XXXXXX")"
APP_DIR="$WORKDIR/app"
if [[ -z "$USER_DATA_DIR" ]]; then
  USER_DATA_DIR="$WORKDIR/user-data"
fi

cleanup() {
  if [[ "$KEEP_TEMP" -eq 0 ]]; then
    rm -rf "$WORKDIR"
  else
    echo "Kept temp dir: $WORKDIR"
  fi
}
trap cleanup EXIT

echo "Extracting app.asar to: $APP_DIR"
npx -y @electron/asar extract "$APP_ASAR" "$APP_DIR"

target_main_js_rel="$(sed -nE 's@.*(main-[A-Za-z0-9_-]+\.js).*@\1@p' "$APP_DIR/.vite/build/main.js" | head -n1 || true)"
target_renderer_js_rel="$(sed -nE 's@.*assets/(index-[A-Za-z0-9_-]+\.js).*@\1@p' "$APP_DIR/webview/index.html" | head -n1 || true)"
[[ -n "$target_main_js_rel" && -n "$target_renderer_js_rel" ]] || { echo "Failed resolving target bundle names" >&2; exit 1; }

MAIN_CHUNK_FILE="$WORKDIR/main-webui.chunk.js"
write_main_injection_chunk "$MAIN_CHUNK_FILE"
apply_main_chunk "$APP_DIR/.vite/build/$target_main_js_rel" "$MAIN_CHUNK_FILE"
patch_renderer_bundle "$APP_DIR/webview/assets/$target_renderer_js_rel"

cp "$BRIDGE_PATH" "$APP_DIR/webview/webui-bridge.js"

rg -q -- '__CODEX_WEBUI_RUNTIME_PATCH__' "$APP_DIR/.vite/build/$target_main_js_rel" || { echo "Patched main missing runtime marker" >&2; exit 1; }
# Renderer patches are best-effort; verify at least one guard applied
rg -q -- 'Array.isArray' "$APP_DIR/webview/assets/$target_renderer_js_rel" || echo "Warning: No renderer guards found (may still work)"
rg -q 'sendMessageFromView' "$APP_DIR/webview/webui-bridge.js" || { echo "Bridge file looks invalid" >&2; exit 1; }

CMD=(npx electron "--user-data-dir=$USER_DATA_DIR" "$APP_DIR" --webui --port "$PORT")
if [[ "$REMOTE" -eq 1 ]]; then
  CMD+=(--remote)
fi
if [[ -n "$TOKEN" ]]; then
  CMD+=(--token "$TOKEN")
fi
if [[ -n "$ORIGINS" ]]; then
  CMD+=(--origins "$ORIGINS")
fi
if ((${#EXTRA_ARGS[@]})); then
  CMD+=("${EXTRA_ARGS[@]}")
fi

unset ELECTRON_RUN_AS_NODE
export ELECTRON_FORCE_IS_PACKAGED=true
export CODEX_CLI_PATH="$CLI_PATH"
export CUSTOM_CLI_PATH="$CLI_PATH"

echo "App dir: $APP_DIR"
echo "User data dir: $USER_DATA_DIR"
echo "WebUI port: $PORT (derived from $(pwd -P))"
printf 'Command:'; printf ' %q' "${CMD[@]}"; echo

if [[ "$NO_OPEN" -eq 0 ]]; then
  (
    if command -v curl >/dev/null 2>&1; then
      for _ in {1..120}; do
        if curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
          open "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 || true
          exit 0
        fi
        sleep 0.25
      done
    else
      sleep 1
      open "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 || true
    fi
  ) &
fi

exec "${CMD[@]}"
