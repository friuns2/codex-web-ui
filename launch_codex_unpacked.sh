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
AUTO_INSTALL_TOOLS="${AUTO_INSTALL_TOOLS:-1}"

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

activate_homebrew_path() {
  if command -v brew >/dev/null 2>&1; then
    eval "$(brew shellenv)" >/dev/null 2>&1 || true
    return
  fi
  local brew_bin
  for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$brew_bin" ]]; then
      eval "$("$brew_bin" shellenv)" >/dev/null 2>&1 || export PATH="$(dirname "$brew_bin"):$PATH"
      return
    fi
  done
}

ensure_homebrew() {
  activate_homebrew_path
  if command -v brew >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$AUTO_INSTALL_TOOLS" != "1" ]]; then
    echo "Missing Homebrew (set AUTO_INSTALL_TOOLS=1 to allow auto-install)." >&2
    return 1
  fi

  command -v curl >/dev/null 2>&1 || {
    echo "curl is required to install Homebrew automatically." >&2
    return 1
  }

  echo "Homebrew not found. Installing Homebrew..."
  if ! NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
    return 1
  fi
  activate_homebrew_path
  command -v brew >/dev/null 2>&1 || {
    echo "Homebrew install completed, but brew is still unavailable in PATH." >&2
    return 1
  }
  return 0
}

ensure_brew_package() {
  local command_name="$1"
  local package_name="$2"
  if command -v "$command_name" >/dev/null 2>&1; then
    return
  fi
  ensure_homebrew || return 1
  echo "Installing missing tool: $package_name"
  brew list "$package_name" >/dev/null 2>&1 || brew install "$package_name" || return 1
  activate_homebrew_path
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Failed to install required tool: $command_name" >&2
    return 1
  }
  return 0
}

install_node_with_nvm() {
  if [[ "$AUTO_INSTALL_TOOLS" != "1" ]]; then
    return 1
  fi
  command -v curl >/dev/null 2>&1 || return 1

  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
    echo "Installing nvm (user-space) to bootstrap Node.js..."
    if ! curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash >/dev/null; then
      return 1
    fi
  fi

  [[ -s "$NVM_DIR/nvm.sh" ]] || return 1
  # shellcheck disable=SC1090
  source "$NVM_DIR/nvm.sh" || return 1
  nvm install --lts >/dev/null || return 1
  nvm use --lts >/dev/null || return 1
  command -v node >/dev/null 2>&1 && command -v npx >/dev/null 2>&1
}

install_node_with_fnm() {
  if [[ "$AUTO_INSTALL_TOOLS" != "1" ]]; then
    return 1
  fi
  command -v curl >/dev/null 2>&1 || return 1
  command -v unzip >/dev/null 2>&1 || return 1

  local fnm_dir="${FNM_DIR:-$HOME/.local/share/fnm}"
  local fnm_bin="$fnm_dir/fnm"
  if ! command -v fnm >/dev/null 2>&1; then
    echo "Installing fnm (user-space) to bootstrap Node.js..."
    local tag asset tmp_dir
    tag="$(curl -fsSL https://api.github.com/repos/Schniz/fnm/releases/latest | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    [[ -n "$tag" ]] || return 1
    case "$(uname -s)" in
      Darwin)
        asset="fnm-macos.zip"
        ;;
      Linux)
        case "$(uname -m)" in
          arm64|aarch64) asset="fnm-arm64.zip" ;;
          x86_64|amd64) asset="fnm-linux.zip" ;;
          *) return 1 ;;
        esac
        ;;
      *)
        return 1
        ;;
    esac
    tmp_dir="$(mktemp -d)"
    if ! curl -fsSL "https://github.com/Schniz/fnm/releases/download/$tag/$asset" -o "$tmp_dir/fnm.zip"; then
      rm -rf "$tmp_dir"
      return 1
    fi
    mkdir -p "$fnm_dir"
    if ! unzip -oq "$tmp_dir/fnm.zip" -d "$fnm_dir"; then
      rm -rf "$tmp_dir"
      return 1
    fi
    chmod +x "$fnm_bin" >/dev/null 2>&1 || true
    rm -rf "$tmp_dir"
  fi

  if [[ -x "$fnm_bin" ]]; then
    export PATH="$fnm_dir:$PATH"
  fi
  command -v fnm >/dev/null 2>&1 || return 1

  # shellcheck disable=SC2046
  eval "$(fnm env --shell bash)" || return 1
  fnm install --lts >/dev/null || return 1
  fnm use lts-latest >/dev/null || return 1
  command -v node >/dev/null 2>&1 && command -v npx >/dev/null 2>&1
}

ensure_required_tools() {
  if ! command -v node >/dev/null 2>&1 || ! command -v npx >/dev/null 2>&1; then
    ensure_brew_package node node || install_node_with_nvm || install_node_with_fnm || {
      echo "Failed to install Node.js/npx automatically." >&2
      exit 1
    }
  fi
  command -v node >/dev/null 2>&1 || { echo "node is required" >&2; exit 1; }
  command -v npx >/dev/null 2>&1 || { echo "npx is required" >&2; exit 1; }
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

const sequenceRe = /await\s+([A-Za-z_$][\w$]*)\.refresh\(\{triggerProviderRefresh:!0\}\)\s*,\s*await\s+([A-Za-z_$][\w$]*)\(([A-Za-z_$][\w$]*)\)\s*,\s*await\s+([A-Za-z_$][\w$]*)\.flushPendingDeepLinks\(\)/g;
const matches = Array.from(source.matchAll(sequenceRe));
if (matches.length === 0) {
  console.error("SSH autostart patch anchor not found (dynamic matcher).");
  process.exit(1);
}

const [fullMatch, refreshObj, openFn, defaultTarget, deepLinkObj] = matches[0];
const replacement =
  `await ${refreshObj}.refresh({triggerProviderRefresh:!0});` +
  `/*__CODEX_SSH_AUTOSTART_PATCH__*/` +
  `let __codexDefaultTarget=${defaultTarget};` +
  `try{` +
  `const __codexReq=(typeof require==="function"?require:globalThis.require);` +
  `if(typeof __codexReq==="function"){` +
  `const __codexFs=__codexReq("node:fs");` +
  `const __codexPath=__codexReq("node:path");` +
  `const __codexHome=process.env.CODEX_HOME||__codexPath.join(process.env.HOME||"",".codex");` +
  `const __codexStateFile=__codexPath.join(__codexHome,".codex-global-state.json");` +
  `if(__codexFs.existsSync(__codexStateFile)){` +
  `const __codexRaw=__codexFs.readFileSync(__codexStateFile,"utf8");` +
  `const __codexParsed=JSON.parse(__codexRaw);` +
  `const __codexHosts=Array.isArray(__codexParsed?.["electron-ssh-hosts"])?__codexParsed["electron-ssh-hosts"]:[];` +
  `if(__codexHosts.length>0&&typeof __codexHosts[0]==="string"&&__codexHosts[0].trim()){__codexDefaultTarget=__codexHosts[0].trim()}` +
  `}` +
  `}` +
  `}catch{}` +
  `await ${openFn}(__codexDefaultTarget),await ${deepLinkObj}.flushPendingDeepLinks()`;

source = source.replace(fullMatch, replacement);
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
ensure_required_tools

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

CMD=(npx -y electron "--user-data-dir=$USER_DATA_DIR" "$APP_DIR")
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
