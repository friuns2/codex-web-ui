#!/usr/bin/env bash
set -euo pipefail

APP_PATH="/Applications/Codex.app"
APP_ASAR="$APP_PATH/Contents/Resources/app.asar"
CLI_PATH="$APP_PATH/Contents/Resources/codex"
PORT="${CODEX_WEBUI_PORT:-5999}"
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
  --port <n>             webui port (default: 5999)
  --token <value>        pass --token for auth
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

  function webUiParseCliOptions(argv = process.argv, env = process.env) {
    let enabled = false;
    let port = webUiParsePortArg(env.CODEX_WEBUI_PORT, 3210);
    let token = (env.CODEX_WEBUI_TOKEN ?? "").trim();
    let origins = (env.CODEX_WEBUI_ORIGINS ?? "")
      .split(",")
      .map((x) => x.trim())
      .filter(Boolean);

    for (let i = 0; i < argv.length; i += 1) {
      const arg = argv[i];
      if (arg === "--webui") {
        enabled = true;
        continue;
      }
      if (arg === "--port" && i + 1 < argv.length) {
        port = webUiParsePortArg(argv[i + 1], port);
        i += 1;
        continue;
      }
      if (arg.startsWith("--port=")) {
        port = webUiParsePortArg(arg.slice("--port=".length), port);
        continue;
      }
      if (arg === "--token" && i + 1 < argv.length) {
        token = String(argv[i + 1] ?? "").trim();
        i += 1;
        continue;
      }
      if (arg.startsWith("--token=")) {
        token = arg.slice("--token=".length).trim();
        continue;
      }
      if (arg.startsWith("--origins=")) {
        origins = arg
          .slice("--origins=".length)
          .split(",")
          .map((x) => x.trim())
          .filter(Boolean);
        continue;
      }
    }

    return { enabled, port, token, origins };
  }

  const webUiOptions = webUiParseCliOptions();
  if (!webUiOptions.enabled) return;

  const http = require("node:http");
  const fs = require("node:fs");
  const path = require("node:path");
  const crypto = require("node:crypto");
  const { EventEmitter } = require("node:events");
  function webUiFormatError(err) {
    if (!err) return "Unknown error";
    if (typeof err === "string") return err;
    if (typeof err.message === "string" && err.message.length > 0) return err.message;
    try {
      return JSON.stringify(err);
    } catch {
      return String(err);
    }
  }
  const webUiLogger = (() => {
    try {
      if (typeof Xt === "function") {
        const logger = Xt();
        if (logger && typeof logger.info === "function" && typeof logger.warning === "function") {
          return logger;
        }
      }
    } catch {}
    return {
      info(message, data) {
        console.info(`[webui] ${message}`, data ?? "");
      },
      warning(message, data) {
        console.warn(`[webui] ${message}`, data ?? "");
      },
    };
  })();

  class WebUiSocket extends EventEmitter {
    constructor(socket) {
      super();
      this.socket = socket;
      this.readyState = WebUiSocket.OPEN;
      this.closed = false;
      this.buffer = Buffer.alloc(0);

      socket.on("data", (chunk) => this.onData(chunk));
      socket.on("error", (err) => {
        // Avoid unhandled EventEmitter "error" crashes on transient socket resets.
        this.emit("ws-error", err);
        this.finishClose(1006, String(err?.code ?? "socket-error"));
      });
      socket.on("close", () => {
        this.finishClose(1006, "");
      });
      socket.on("end", () => {
        this.finishClose(1006, "");
      });
    }

    send(data, callback) {
      if (this.readyState !== WebUiSocket.OPEN) {
        if (typeof callback === "function") callback(new Error("Socket is not open"));
        return;
      }
      const payload = Buffer.isBuffer(data) ? data : Buffer.from(String(data));
      const frame = WebUiSocket.buildFrame(0x1, payload);
      this.socket.write(frame, callback);
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
      } catch {
        payload = Buffer.from([0x03, 0xe8]);
      }
      this.socket.write(WebUiSocket.buildFrame(0x8, payload), () => {
        this.socket.end();
      });
    }

    onData(chunk) {
      this.buffer = this.buffer.length === 0 ? chunk : Buffer.concat([this.buffer, chunk]);

      while (this.buffer.length >= 2) {
        const first = this.buffer[0];
        const second = this.buffer[1];
        const fin = (first & 0x80) !== 0;
        const opcode = first & 0x0f;
        const masked = (second & 0x80) !== 0;
        let payloadLen = second & 0x7f;
        let offset = 2;

        if (payloadLen === 126) {
          if (this.buffer.length < 4) return;
          payloadLen = this.buffer.readUInt16BE(2);
          offset = 4;
        } else if (payloadLen === 127) {
          if (this.buffer.length < 10) return;
          const high = this.buffer.readUInt32BE(2);
          const low = this.buffer.readUInt32BE(6);
          payloadLen = high * 2 ** 32 + low;
          if (!Number.isSafeInteger(payloadLen)) {
            this.close(1009, "Frame too large");
            return;
          }
          offset = 10;
        }

        let mask;
        if (masked) {
          if (this.buffer.length < offset + 4) return;
          mask = this.buffer.subarray(offset, offset + 4);
          offset += 4;
        }

        if (this.buffer.length < offset + payloadLen) return;

        let payload = this.buffer.subarray(offset, offset + payloadLen);
        this.buffer = this.buffer.subarray(offset + payloadLen);

        if (masked && mask) {
          payload = Buffer.from(payload);
          for (let i = 0; i < payload.length; i += 1) {
            payload[i] ^= mask[i & 3];
          }
        }

        if (!fin) {
          this.close(1003, "Fragmented frames are not supported");
          return;
        }

        if (opcode === 0x1) {
          this.emit("message", payload);
          continue;
        }
        if (opcode === 0x8) {
          let code = 1000;
          let reason = "";
          if (payload.length >= 2) {
            code = payload.readUInt16BE(0);
            reason = payload.subarray(2).toString();
          }
          if (this.readyState === WebUiSocket.OPEN) {
            this.socket.write(WebUiSocket.buildFrame(0x8, payload), () => {
              this.socket.end();
            });
          }
          this.finishClose(code, reason);
          return;
        }
        if (opcode === 0x9) {
          this.socket.write(WebUiSocket.buildFrame(0xA, payload));
          continue;
        }
        if (opcode === 0xA) {
          continue;
        }

        this.close(1003, "Unsupported opcode");
        return;
      }
    }

    finishClose(code, reason) {
      if (this.closed) return;
      this.closed = true;
      this.readyState = WebUiSocket.CLOSED;
      this.emit("close", code, reason);
    }

    static buildFrame(opcode, payload) {
      const len = payload.length;
      let headerLen = 2;
      if (len >= 126 && len <= 65535) headerLen = 4;
      else if (len > 65535) headerLen = 10;

      const out = Buffer.allocUnsafe(headerLen + len);
      out[0] = 0x80 | (opcode & 0x0f);

      if (headerLen === 2) {
        out[1] = len;
        payload.copy(out, 2);
      } else if (headerLen === 4) {
        out[1] = 126;
        out.writeUInt16BE(len, 2);
        payload.copy(out, 4);
      } else {
        out[1] = 127;
        const high = Math.floor(len / 2 ** 32);
        const low = len >>> 0;
        out.writeUInt32BE(high, 2);
        out.writeUInt32BE(low, 6);
        payload.copy(out, 10);
      }

      return out;
    }
  }

  WebUiSocket.CONNECTING = 0;
  WebUiSocket.OPEN = 1;
  WebUiSocket.CLOSING = 2;
  WebUiSocket.CLOSED = 3;

  class WebUiSocketServer extends EventEmitter {
    handleUpgrade(req, socket, head, callback) {
      const upgrade = String(req.headers.upgrade ?? "").toLowerCase();
      const key = req.headers["sec-websocket-key"];
      if (upgrade !== "websocket" || typeof key !== "string" || key.length === 0) {
        socket.write("HTTP/1.1 400 Bad Request\r\n\r\n");
        socket.destroy();
        return;
      }

      const accept = crypto
        .createHash("sha1")
        .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
        .digest("base64");

      const headers = [
        "HTTP/1.1 101 Switching Protocols",
        "Upgrade: websocket",
        "Connection: Upgrade",
        `Sec-WebSocket-Accept: ${accept}`,
      ];
      socket.write(`${headers.join("\r\n")}\r\n\r\n`);

      if (head && head.length > 0) socket.unshift(head);

      const ws = new WebUiSocket(socket);
      callback(ws, req);
    }

    close() {
      this.emit("close");
    }
  }

  function webUiTokensEqual(a, b) {
    if (!a || !b) return false;
    try {
      const left = Buffer.from(a);
      const right = Buffer.from(b);
      return left.length === right.length && crypto.timingSafeEqual(left, right);
    } catch {
      return false;
    }
  }

  function webUiParseCookieHeader(value) {
    if (!value) return {};
    return value
      .split(";")
      .map((part) => part.trim())
      .filter(Boolean)
      .reduce((acc, segment) => {
        const idx = segment.indexOf("=");
        if (idx <= 0) return acc;
        const key = segment.slice(0, idx).trim();
        const raw = segment.slice(idx + 1).trim();
        try {
          acc[key] = decodeURIComponent(raw);
        } catch {
          acc[key] = raw;
        }
        return acc;
      }, {});
  }

  function webUiExtractAuthToken(req, parsedUrl) {
    const auth = req.headers.authorization;
    if (typeof auth === "string" && auth.startsWith("Bearer ")) return auth.slice(7).trim();
    const headerToken = req.headers["x-codex-webui-token"];
    if (typeof headerToken === "string" && headerToken.trim()) return headerToken.trim();
    const qpToken = parsedUrl.searchParams.get("token");
    if (qpToken && qpToken.trim()) return qpToken.trim();
    const cookieToken = webUiParseCookieHeader(req.headers.cookie ?? "").codex_webui_token;
    return typeof cookieToken === "string" ? cookieToken.trim() : "";
  }

  function webUiResolveAssetPath(rootDir, requestPath) {
    let decoded;
    try {
      decoded = decodeURIComponent(requestPath);
    } catch {
      return null;
    }

    const rel = decoded === "/" ? "index.html" : decoded.replace(/^[/\\]+/, "");
    const root = path.resolve(rootDir);
    const resolved = path.resolve(root, rel);
    return resolved === root || resolved.startsWith(`${root}${path.sep}`) ? resolved : null;
  }

  function webUiSetResponseSecurityHeaders(res) {
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("X-Frame-Options", "DENY");
    res.setHeader("Referrer-Policy", "no-referrer");
    res.setHeader("Cross-Origin-Resource-Policy", "same-origin");
  }

  function webUiInjectRuntimeScripts(html) {
    if (html.includes('/webui-bridge.js')) return html;
    const injection =
      "\n    <script src=\"/webui-config.js\"></script>\n    <script src=\"/webui-bridge.js\"></script>\n";
    return html.includes("</head>") ? html.replace("</head>", `${injection}</head>`) : `${injection}${html}`;
  }

  async function webUiInvokeElectronBridgeMethod(windowRef, method, args) {
    if (windowRef.isDestroyed() || windowRef.webContents.isDestroyed()) {
      throw new Error("WebUI bridge window is not available.");
    }
    const methodJson = JSON.stringify(method);
    const argsJson = JSON.stringify(args ?? []);
    const code = `
      Promise.resolve().then(async () => {
        const bridge = window.electronBridge;
        if (!bridge || typeof bridge[${methodJson}] !== "function") {
          return null;
        }
        return await bridge[${methodJson}](...${argsJson});
      });
    `;
    return windowRef.webContents.executeJavaScript(code, true);
  }

  async function webUiDispatchMessageFromView(bridgeWindow, context, payload) {
    // Prefer the renderer bridge API; it is stable across minified builds.
    const bridged = await webUiInvokeElectronBridgeMethod(bridgeWindow, "sendMessageFromView", [
      payload,
    ]);
    if (bridged !== null) return;

    // Fallback for older/newer app internals.
    if (context && typeof context.handleMessage === "function") {
      await context.handleMessage(bridgeWindow.webContents, payload);
      return;
    }
    throw new Error("No message dispatch handler available for WebUI bridge");
  }

  async function waitForPrimaryWindow(timeoutMs = 30000) {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      const win = Vt.getPrimaryWindow(Pt);
      if (win && !win.isDestroyed()) return win;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    return null;
  }

  function webUiForceWindowHidden(win) {
    if (!win || win.isDestroyed()) return;
    const hideNow = () => {
      try {
        win.hide();
      } catch {}
    };

    hideNow();

    if (!win.__codexWebUiShowPatched) {
      win.__codexWebUiShowPatched = true;
      if (typeof win.show === "function") {
        win.show = () => {
          hideNow();
        };
      }
      if (typeof win.showInactive === "function") {
        win.showInactive = () => {
          hideNow();
        };
      }
    }

    win.on("show", () => {
      setTimeout(hideNow, 0);
    });
  }

  async function webUiStartBridgeRuntime({ bridgeWindow, context }) {
    const assetRoot = path.join(L.app.getAppPath(), "webview");
    const host = "0.0.0.0";
    const authRequired = !!webUiOptions.token;
    const token =
      authRequired && !webUiOptions.token
        ? crypto.randomBytes(24).toString("hex")
        : webUiOptions.token;
    const originAllowlist = new Set(webUiOptions.origins);
    const sockets = new Set();
    let cachedIndexHtml = "";

    const originAllowed = (origin, hostHeader) => {
      if (typeof origin !== "string") return false;
      if (originAllowlist.size > 0) return originAllowlist.has(origin);
      try {
        return origin.length === 0 ? true : new URL(origin).host === hostHeader;
      } catch {
        return false;
      }
    };

    const broadcast = (packet) => {
      if (sockets.size === 0) return;
      let serialized;
      try {
        serialized = JSON.stringify(packet);
      } catch {
        return;
      }
      for (const ws of sockets) {
        if (ws.readyState !== WebUiSocket.OPEN) continue;
        ws.send(serialized, (err) => {
          if (err) {
            webUiLogger.warning("WebUI socket send failed", {
              message: webUiFormatError(err),
            });
          }
        });
      }
    };

    const originalSend = bridgeWindow.webContents.send.bind(bridgeWindow.webContents);
    bridgeWindow.webContents.send = (channel, ...args) => {
      if (channel === bt) {
        broadcast({
          kind: "message-for-view",
          payload: args[0],
        });
      } else if (channel.startsWith("codex_desktop:worker:") && channel.endsWith(":for-view")) {
        broadcast({
          kind: "worker-message-for-view",
          workerId: channel.slice("codex_desktop:worker:".length, -":for-view".length),
          payload: args[0],
        });
      }
      originalSend(channel, ...args);
    };

    const server = http.createServer(async (req, res) => {
      const parsedUrl = new URL(req.url ?? "/", `http://${req.headers.host ?? "127.0.0.1"}`);
      webUiSetResponseSecurityHeaders(res);

      if (authRequired) {
        const provided = webUiExtractAuthToken(req, parsedUrl);
        if (!webUiTokensEqual(provided, token)) {
          res.statusCode = 401;
          res.setHeader("Content-Type", "text/plain; charset=utf-8");
          res.end("Unauthorized");
          return;
        }
        if (parsedUrl.searchParams.get("token")) {
          res.setHeader(
            "Set-Cookie",
            `codex_webui_token=${encodeURIComponent(token)}; Path=/; HttpOnly; SameSite=Lax`,
          );
        }
      }

      if (parsedUrl.pathname === "/webui-config.js") {
        const config = JSON.stringify({
          wsPath: "/ws",
          buildFlavor: sn,
          sentryInitOptions: ma,
          appSessionId: Ya,
        });
        res.setHeader("Content-Type", "application/javascript; charset=utf-8");
        res.setHeader("Cache-Control", "no-store");
        res.end(`window.__CODEX_WEBUI_CONFIG__=${config};`);
        return;
      }

      let assetPath = webUiResolveAssetPath(assetRoot, parsedUrl.pathname);
      if (parsedUrl.pathname === "/" || parsedUrl.pathname === "/index.html") {
        assetPath = path.join(assetRoot, "index.html");
      }

      if (assetPath) {
        try {
          const stat = await fs.promises.stat(assetPath);
          if (stat.isFile()) {
            if (path.basename(assetPath) === "index.html") {
              if (!cachedIndexHtml) {
                cachedIndexHtml = webUiInjectRuntimeScripts(await fs.promises.readFile(assetPath, "utf8"));
              }
              res.setHeader("Content-Type", "text/html; charset=utf-8");
              res.setHeader("Cache-Control", "no-store");
              res.end(cachedIndexHtml);
              return;
            }

            const ext = path.extname(assetPath).toLowerCase();
            const mime =
              ext === ".html"
                ? "text/html"
                : ext === ".js" || ext === ".mjs"
                  ? "application/javascript"
                  : ext === ".css"
                    ? "text/css"
                    : ext === ".json" || ext === ".map"
                      ? "application/json"
                      : ext === ".svg"
                        ? "image/svg+xml"
                        : ext === ".png"
                          ? "image/png"
                          : ext === ".jpg" || ext === ".jpeg"
                            ? "image/jpeg"
                            : ext === ".gif"
                              ? "image/gif"
                              : ext === ".webp"
                                ? "image/webp"
                                : ext === ".ico"
                                  ? "image/x-icon"
                                  : ext === ".txt"
                                    ? "text/plain"
                                    : ext === ".wasm"
                                      ? "application/wasm"
                                      : "application/octet-stream";

            res.setHeader(
              "Content-Type",
              mime.includes("charset") ? mime : `${mime}; charset=utf-8`,
            );
            res.setHeader("Cache-Control", "no-store");

            fs.createReadStream(assetPath)
              .on("error", (err) => {
                webUiLogger.warning("WebUI static stream failed", {
                  message: webUiFormatError(err),
                });
                if (!res.headersSent) {
                  res.statusCode = 500;
                  res.setHeader("Content-Type", "text/plain; charset=utf-8");
                }
                res.end("Internal Server Error");
              })
              .pipe(res);
            return;
          }
        } catch {
          // fall through to SPA fallback
        }
      }

      if (
        parsedUrl.pathname === "/api" ||
        parsedUrl.pathname.startsWith("/api/") ||
        parsedUrl.pathname === "/auth" ||
        parsedUrl.pathname.startsWith("/auth/") ||
        parsedUrl.pathname === "/ws"
      ) {
        res.statusCode = 404;
        res.setHeader("Content-Type", "text/plain; charset=utf-8");
        res.end("Not Found");
        return;
      }

      const indexPath = path.join(assetRoot, "index.html");
      try {
        if (!cachedIndexHtml) {
          cachedIndexHtml = webUiInjectRuntimeScripts(await fs.promises.readFile(indexPath, "utf8"));
        }
      } catch {
        cachedIndexHtml = "<!doctype html><html><body><h1>Web UI unavailable</h1></body></html>";
      }
      res.setHeader("Content-Type", "text/html; charset=utf-8");
      res.setHeader("Cache-Control", "no-store");
      res.end(cachedIndexHtml);
    });

    const wss = new WebUiSocketServer();

    server.on("upgrade", (req, socket, head) => {
      const parsedUrl = new URL(req.url ?? "/", `http://${req.headers.host ?? "127.0.0.1"}`);
      if (parsedUrl.pathname !== "/ws") {
        socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
        socket.destroy();
        return;
      }
      if (!originAllowed(req.headers.origin ?? "", req.headers.host ?? "")) {
        socket.write("HTTP/1.1 403 Forbidden\r\n\r\n");
        socket.destroy();
        return;
      }
      if (authRequired && !webUiTokensEqual(webUiExtractAuthToken(req, parsedUrl), token)) {
        socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
        socket.destroy();
        return;
      }

      wss.handleUpgrade(req, socket, head, (ws) => {
        // Single active client policy: newer tab takes over and prior tabs are disconnected.
        for (const existing of sockets) {
          try {
            existing.send(
              JSON.stringify({
                kind: "bridge-error",
                message: "Another tab took over this session",
              }),
            );
            existing.close(1012, "Replaced by newer client tab");
          } catch {}
        }

        sockets.add(ws);
        ws.on("close", () => {
          sockets.delete(ws);
        });
        ws.on("ws-error", (err) => {
          webUiLogger.warning("WebUI socket error", {
            message: webUiFormatError(err),
          });
        });

        let bucketStart = Date.now();
        let count = 0;
        const inboundLimit = 5000;

        ws.on("message", async (raw) => {
          const now = Date.now();
          if (now - bucketStart > 60000) {
            bucketStart = now;
            count = 0;
          }
          count += 1;
          if (count > inboundLimit) {
            webUiLogger.warning("WebUI inbound rate limit exceeded", {
              count,
              limit: inboundLimit,
            });
            ws.close(1008, "Rate limit exceeded");
            return;
          }

          let packet;
          try {
            packet = JSON.parse(String(raw));
          } catch {
            ws.send(
              JSON.stringify({
                kind: "bridge-error",
                message: "Invalid payload",
              }),
            );
            return;
          }

          try {
            if (packet?.kind === "message-from-view") {
              const payload = packet.payload;
              if (!payload || typeof payload.type !== "string") return;
              await webUiDispatchMessageFromView(bridgeWindow, context, payload);
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
              if (typeof packet.workerId !== "string" || packet.workerId.length === 0) return;
              await webUiInvokeElectronBridgeMethod(bridgeWindow, "sendWorkerMessageFromView", [
                packet.workerId,
                packet.payload,
              ]);
              return;
            }

            if (packet?.kind === "trigger-sentry-test") {
              await webUiInvokeElectronBridgeMethod(bridgeWindow, "triggerSentryTestError", []);
              return;
            }
          } catch (err) {
            webUiLogger.warning("WebUI bridge dispatch failed", {
              message: webUiFormatError(err),
            });
            ws.send(
              JSON.stringify({
                kind: "bridge-error",
                message: "Bridge dispatch failed",
              }),
            );
          }
        });
      });
    });

    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(webUiOptions.port, host, () => {
        const address = server.address();
        if (typeof address === "object" && address && "port" in address) {
          webUiOptions.port = address.port;
        }
        server.off("error", reject);
        resolve();
      });
    });

    webUiLogger.info("WebUI bridge started", {
      host,
      port: webUiOptions.port,
      authRequired,
      originAllowlist: [...originAllowlist],
    });

    if (authRequired) {
      webUiLogger.info("WebUI access token", { token });
    }

    return {
      host,
      port: webUiOptions.port,
      token: authRequired ? token : "",
      dispose: async () => {
        wss.close();
        for (const ws of sockets) {
          try {
            ws.close(1001, "Server shutting down");
          } catch {}
        }
        sockets.clear();
        await new Promise((resolve) => {
          server.close(() => resolve());
        });
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
      webUiForceWindowHidden(primaryWindow);

      const preventClose = (event) => {
        if (!Vt.isAppQuitting) {
          event.preventDefault();
          webUiForceWindowHidden(primaryWindow);
        }
      };
      primaryWindow.on("close", preventClose);
      primaryWindow.on("minimize", () => {
        webUiForceWindowHidden(primaryWindow);
      });

      webUiRuntime = await webUiStartBridgeRuntime({
        bridgeWindow: primaryWindow,
        context: Dde,
      });

      return webUiRuntime;
    })();

    return webUiStartPromise;
  }

  L.app.on("browser-window-created", (_event, win) => {
    if (!webUiOptions.enabled) return;
    if (win && !win.isDestroyed()) {
      webUiForceWindowHidden(win);
      win.once("ready-to-show", () => {
        webUiForceWindowHidden(win);
      });
      setImmediate(() => {
        webUiForceWindowHidden(win);
      });
    }
  });

  L.app.whenReady().then(() => {
      webUiStart().catch((err) => {
        webUiLogger.warning("WebUI runtime start failed", {
        message: webUiFormatError(err),
      });
    });
  });

  L.app.on("activate", () => {
    if (!webUiOptions.enabled) return;
    const win = webUiBridgeWindow ?? Vt.getPrimaryWindow(Pt);
    if (win && !win.isDestroyed()) {
      webUiForceWindowHidden(win);
    }
  });

  L.app.on("will-quit", () => {
    if (webUiRuntime && typeof webUiRuntime.dispose === "function") {
      webUiRuntime.dispose().catch((err) => {
        webUiLogger.warning("WebUI shutdown failed", {
          message: webUiFormatError(err),
        });
      });
      webUiRuntime = null;
    }
  });
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
  node - "$renderer_file" <<'NODE'
const fs = require("node:fs");
const rendererFile = process.argv[2];
let source = fs.readFileSync(rendererFile, "utf8");

// Older bundle shape (kept for compatibility).
const find = "if(!v)return;const M=v.roots.map(A4),A=g.current;";
const replace = "if(!v||!Array.isArray(v.roots))return;const M=v.roots.map(A4),A=g.current;";
if (source.includes(find)) {
  source = source.replace(find, replace);
  fs.writeFileSync(rendererFile, source, "utf8");
  process.exit(0);
}

// Newer bundle shape where minified variable names change between builds.
const generic = /if\(!([A-Za-z_$][\w$]*)\)return;const ([A-Za-z_$][\w$]*)=\1\.roots\.map\(A4\),([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)\.current;/;
if (generic.test(source)) {
  source = source.replace(
    generic,
    "if(!$1||!Array.isArray($1.roots))return;const $2=$1.roots.map(A4),$3=$4.current;"
  );
  fs.writeFileSync(rendererFile, source, "utf8");
  process.exit(0);
}

console.error("Renderer guard patch anchor not found.");
process.exit(1);

fs.writeFileSync(rendererFile, source, "utf8");
NODE
}

EXTRA_ARGS=()
while (($#)); do
  case "$1" in
    --app)
      APP_PATH="${2:?missing value}"; APP_ASAR="$APP_PATH/Contents/Resources/app.asar"; CLI_PATH="$APP_PATH/Contents/Resources/codex"; shift 2 ;;
    --port)
      PORT="${2:?missing value}"; shift 2 ;;
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
rg -q -- '!Array\.isArray\([[:alnum:]_$]+\.roots\)' "$APP_DIR/webview/assets/$target_renderer_js_rel" || { echo "Patched renderer missing roots guard" >&2; exit 1; }
rg -q 'sendMessageFromView' "$APP_DIR/webview/webui-bridge.js" || { echo "Bridge file looks invalid" >&2; exit 1; }

CMD=(npx electron "--user-data-dir=$USER_DATA_DIR" "$APP_DIR" --webui --port "$PORT")
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
