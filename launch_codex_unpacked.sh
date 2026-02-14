#!/usr/bin/env bash
set -euo pipefail

APP_PATH="/Applications/Codex.app"
APP_ASAR="$APP_PATH/Contents/Resources/app.asar"
CLI_PATH="$APP_PATH/Contents/Resources/codex"
KEEP_TEMP=0
USER_DATA_DIR=""
INSPECT_PORT="${CODEX_INSPECT_PORT:-9229}"
REMOTE_DEBUG_PORT="${CODEX_REMOTE_DEBUG_PORT:-9222}"
ENABLE_INSPECT=1
ENABLE_REMOTE_DEBUG=1
SSH_HOST=""

usage() {
  cat <<'USAGE'
Usage:
  launch_codex_unpacked.sh [options] [-- <extra args>]

Options:
  --app <path>                 Codex.app path
  --user-data-dir <path>       chromium user data dir override
  --inspect-port <n>           node inspector port (default: 9229)
  --remote-debug-port <n>      chromium remote debug port (default: 9222)
  --ssh-host <user@host>       add/select SSH host and auto-open it on launch
  --no-inspect                 disable --inspect
  --no-remote-debug            disable --remote-debugging-port
  --keep-temp                  keep temp extracted app dir
  -h, --help
USAGE
}

parse_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  (( value >= 1 && value <= 65535 )) || return 1
  printf '%s\n' "$value"
}

upsert_ssh_host_in_global_state() {
  local host="$1"
  local codex_home="${CODEX_HOME:-$HOME/.codex}"
  local state_file="$codex_home/.codex-global-state.json"

  mkdir -p "$codex_home"
  node - "$state_file" "$host" <<'NODE'
const fs = require("node:fs");
const file = process.argv[2];
const host = String(process.argv[3] ?? "").trim();
if (!host) process.exit(1);

let data = {};
try {
  if (fs.existsSync(file)) {
    data = JSON.parse(fs.readFileSync(file, "utf8"));
  }
} catch {
  data = {};
}

const key = "electron-ssh-hosts";
const current = Array.isArray(data[key]) ? data[key].filter((x) => typeof x === "string") : [];
const normalized = [host, ...current.filter((x) => x.trim() !== host)];
data[key] = normalized;
fs.writeFileSync(file, JSON.stringify(data), "utf8");
NODE
}

patch_main_for_ssh_autostart() {
  local main_file="$1"
  node - "$main_file" <<'NODE'
const fs = require("node:fs");
const file = process.argv[2];
let source = fs.readFileSync(file, "utf8");
const marker = "__CODEX_SSH_AUTOSTART_PATCH__";
if (source.includes(marker)) process.exit(0);

const target = "await kp.refresh({triggerProviderRefresh:!0}),await bu(Gt),await pM.flushPendingDeepLinks()";
if (!source.includes(target)) {
  console.error("SSH autostart patch anchor not found.");
  process.exit(1);
}

const replacement =
  'await kp.refresh({triggerProviderRefresh:!0});/*__CODEX_SSH_AUTOSTART_PATCH__*/const __codexSshHosts=IJ(Co);if(__codexSshHosts.length>0){await bu(__codexSshHosts[0].id)}else await bu(Gt);await pM.flushPendingDeepLinks()';
source = source.replace(target, replacement);
fs.writeFileSync(file, source, "utf8");
NODE
}

EXTRA_ARGS=()
while (($#)); do
  case "$1" in
    --app)
      APP_PATH="${2:?missing value}"
      APP_ASAR="$APP_PATH/Contents/Resources/app.asar"
      CLI_PATH="$APP_PATH/Contents/Resources/codex"
      shift 2
      ;;
    --user-data-dir)
      USER_DATA_DIR="${2:?missing value}"
      shift 2
      ;;
    --inspect-port)
      INSPECT_PORT="$(parse_port "${2:?missing value}")" || {
        echo "Invalid --inspect-port: ${2}" >&2
        exit 1
      }
      shift 2
      ;;
    --remote-debug-port)
      REMOTE_DEBUG_PORT="$(parse_port "${2:?missing value}")" || {
        echo "Invalid --remote-debug-port: ${2}" >&2
        exit 1
      }
      shift 2
      ;;
    --ssh-host)
      SSH_HOST="${2:?missing value}"
      shift 2
      ;;
    --no-inspect)
      ENABLE_INSPECT=0
      shift
      ;;
    --no-remote-debug)
      ENABLE_REMOTE_DEBUG=0
      shift
      ;;
    --keep-temp)
      KEEP_TEMP=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      EXTRA_ARGS+=("$@")
      break
      ;;
    *)
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

[[ -f "$APP_ASAR" ]] || { echo "Missing app.asar: $APP_ASAR" >&2; exit 1; }
[[ -x "$CLI_PATH" ]] || { echo "Missing codex binary: $CLI_PATH" >&2; exit 1; }
command -v npx >/dev/null 2>&1 || { echo "npx is required" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-unpacked.XXXXXX")"
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

if [[ -n "$SSH_HOST" ]]; then
  if command -v ssh >/dev/null 2>&1; then
    if ! ssh -o BatchMode=yes -o ConnectTimeout=6 "$SSH_HOST" 'printf ok' >/dev/null 2>&1; then
      echo "Warning: SSH preflight failed for $SSH_HOST (app may fail to connect)." >&2
    fi
  fi
  upsert_ssh_host_in_global_state "$SSH_HOST"
  MAIN_JS_FILE="$(ls "$APP_DIR"/.vite/build/main-*.js | head -n1)"
  patch_main_for_ssh_autostart "$MAIN_JS_FILE"
fi

CMD=(npx electron "--user-data-dir=$USER_DATA_DIR" "$APP_DIR")
if [[ "$ENABLE_INSPECT" -eq 1 ]]; then
  CMD+=("--inspect=$INSPECT_PORT")
fi
if [[ "$ENABLE_REMOTE_DEBUG" -eq 1 ]]; then
  CMD+=("--remote-debugging-port=$REMOTE_DEBUG_PORT")
fi
if ((${#EXTRA_ARGS[@]})); then
  CMD+=("${EXTRA_ARGS[@]}")
fi

unset ELECTRON_RUN_AS_NODE
export ELECTRON_FORCE_IS_PACKAGED=true
export BUILD_FLAVOR=prod
export NODE_ENV=production
export CODEX_CLI_PATH="$CLI_PATH"
export CUSTOM_CLI_PATH="$CLI_PATH"
export ELECTRON_ENABLE_LOGGING=1

echo "App dir: $APP_DIR"
echo "User data dir: $USER_DATA_DIR"
if [[ -n "$SSH_HOST" ]]; then
  echo "SSH host: $SSH_HOST"
fi
printf 'Command:'
printf ' %q' "${CMD[@]}"
echo

exec "${CMD[@]}"
