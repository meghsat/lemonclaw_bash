#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="OpenclawXLemonade"
SCRIPT_VERSION="0.1.0"

LEMONADE_DIR="${LEMONADE_DIR:-$HOME/lemonade-dev/lemonade}"
LEMONADE_BUILD_DIR="${LEMONADE_DIR}/build"
LEMONADE_BASE_URL="${LEMONADE_BASE_URL:-http://127.0.0.1:13305}"
LEMONADE_PORT="${LEMONADE_PORT:-13305}"

OPENCLAW_CONFIG_FILE="${OPENCLAW_CONFIG_PATH:-$HOME/.openclaw/openclaw.json}"
OPENCLAW_LEMONADE_MODEL_ID="${OPENCLAW_LEMONADE_MODEL_ID:-}"
OPENCLAW_LEMONADE_CONTEXT_TOKENS="${OPENCLAW_LEMONADE_CONTEXT_TOKENS:-190000}"
OPENCLAW_LEMONADE_MODEL_MAX_TOKENS="${OPENCLAW_LEMONADE_MODEL_MAX_TOKENS:-64000}"
OPENCLAW_LEMONADE_MAX_AGENTS="${OPENCLAW_LEMONADE_MAX_AGENTS:-2}"
OPENCLAW_LEMONADE_MAX_SUBAGENTS="${OPENCLAW_LEMONADE_MAX_SUBAGENTS:-2}"
OPENCLAW_LEMONADE_GATEWAY_PORT="${OPENCLAW_LEMONADE_GATEWAY_PORT:-18789}"
OPENCLAW_LEMONADE_GATEWAY_BIND="${OPENCLAW_LEMONADE_GATEWAY_BIND:-loopback}"
OPENCLAW_LEMONADE_SKIP_TUNING="${OPENCLAW_LEMONADE_SKIP_TUNING:-0}"

RAN_ONBOARD=0

print_banner() {
  printf '\033[1;33m    🦞  OpenClaw on AMD (Lemonade + Linux)  🦞\033[0m\n'
  printf '\n'
}

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }


require_linux() {
  [[ "$(uname -s)" == "Linux" ]] || die "This script is for Linux only."
}

append_line_if_missing() {
  local file="$1" line="$2"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  grep -qxF "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"
}

apt_install_if_missing() {
  have apt-get || die "This script requires apt-get (Ubuntu/Debian)."
  local missing=()
  local pkg
  for pkg in "$@"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if (( ${#missing[@]} > 0 )); then
    info "Installing missing packages: ${missing[*]}"
    sudo apt-get update
    DEBIAN_FRONTEND=noninteractive sudo apt-get install -y "${missing[@]}"
  else
    info "All required packages already installed — skipping apt-get"
  fi
}

# ---------------------------------------------------------------------------
# Step 1 — System prerequisites
# ---------------------------------------------------------------------------
install_prerequisites() {
  apt_install_if_missing git build-essential wget jq curl python3

  info "Checking CMake version..."
  local current_version="0.0.0"
  if have cmake; then
    current_version="$(cmake --version | head -n1 | awk '{print $3}')"
    info "Found CMake ${current_version}"
  fi

  local required_version="3.28.0"
  if printf '%s\n%s\n' "$required_version" "$current_version" | sort -C -V; then
    info "CMake ${current_version} satisfies >= ${required_version} — skipping"
    return 0
  fi

  info "Installing CMake 3.28.6 from official binary..."
  local cmake_version="3.28.6"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  (
    cd "$tmp_dir"
    wget -q "https://github.com/Kitware/CMake/releases/download/v${cmake_version}/cmake-${cmake_version}-linux-x86_64.sh"
    chmod +x "cmake-${cmake_version}-linux-x86_64.sh"
    sudo "./cmake-${cmake_version}-linux-x86_64.sh" --skip-license --prefix=/usr/local
  )
  rm -rf "$tmp_dir"
  info "Installed $(cmake --version | head -n1)"
}

# ---------------------------------------------------------------------------
# Step 2 — Clone lemonade (idempotent)
# ---------------------------------------------------------------------------
clone_lemonade() {
  if [[ -d "$LEMONADE_DIR/.git" ]]; then
    info "Lemonade repo already present at ${LEMONADE_DIR} — skipping clone"
    return 0
  fi

  local parent_dir
  parent_dir="$(dirname "$LEMONADE_DIR")"
  info "Cloning lemonade into ${LEMONADE_DIR}..."
  mkdir -p "$parent_dir"
  git clone https://github.com/lemonade-sdk/lemonade.git "$LEMONADE_DIR"
}

# ---------------------------------------------------------------------------
# Step 3 — Patch server_models.json with Qwen model entry (idempotent)
# ---------------------------------------------------------------------------
patch_server_models() {
  # Patch both the source and build copies so the model entry exists
  local src_file="${LEMONADE_DIR}/src/cpp/resources/server_models.json"
  local build_file="${LEMONADE_BUILD_DIR}/resources/server_models.json"

  [[ -f "$src_file" ]] || die "server_models.json not found at ${src_file}"

  _apply_patch() {
    local models_file="$1"
    [[ -f "$models_file" ]] || return 0
    if jq -e '."Qwen3.5-35B-A3B-Q4-K-M-GGUF"' "$models_file" >/dev/null 2>&1; then
      info "Qwen3.5-35B-A3B model entry already present in ${models_file} — skipping"
      return 0
    fi
    info "Patching ${models_file}..."
    local tmp_file
    tmp_file="$(mktemp)"
    jq '. + {
      "Qwen3.5-35B-A3B-Q4-K-M-GGUF": {
        "checkpoint": "unsloth/Qwen3.5-35B-A3B-GGUF:Qwen3.5-35B-A3B-Q4_K_M.gguf",
        "mmproj": "mmproj-F16.gguf",
        "recipe": "llamacpp",
        "suggested": true,
        "labels": ["vision", "tool-calling", "hot"],
        "size": 19.7
      }
    }' "$models_file" > "$tmp_file" && mv "$tmp_file" "$models_file"
  }

  _apply_patch "$src_file"
  _apply_patch "$build_file"

  # Write ctx_size to lemonade's recipe_options cache — this is what lemond
  # actually reads at load time (server_models.json recipe_options only applies
  # during 'lemonade pull', not on load)
  local recipe_opts_file="$HOME/.cache/lemonade/recipe_options.json"
  info "Writing ctx_size=32768 to ${recipe_opts_file}..."
  python3 - <<PY "$recipe_opts_file"
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
p.parent.mkdir(parents=True, exist_ok=True)
data = json.loads(p.read_text()) if p.exists() else {}
data.setdefault('Qwen3.5-35B-A3B-Q4-K-M-GGUF', {})['ctx_size'] = 32768
p.write_text(json.dumps(data, indent=2))
PY
  info "server_models.json patched"
}

# ---------------------------------------------------------------------------
# Step 4 — Build lemonade (idempotent: skips if lemonade-server already built)
# ---------------------------------------------------------------------------
build_lemonade() {
  if [[ -x "${LEMONADE_BUILD_DIR}/lemond" ]] || [[ -x "${LEMONADE_BUILD_DIR}/lemonade-server" ]]; then
    info "Lemonade already built at ${LEMONADE_BUILD_DIR} — skipping build"
    return 0
  fi

  info "Running lemonade setup.sh..."
  (
    cd "$LEMONADE_DIR"
    CI=1 ./setup.sh
    cmake --build --preset default
  )
  info "Lemonade build complete"
}

# ---------------------------------------------------------------------------
# Step 5 — Add lemonade build dir to PATH (idempotent)
# ---------------------------------------------------------------------------
add_lemonade_to_path() {
  local path_line="export PATH=\"${LEMONADE_BUILD_DIR}:\$PATH\""
  append_line_if_missing "$HOME/.profile" "$path_line"
  append_line_if_missing "$HOME/.bashrc" "$path_line"
  [[ -f "$HOME/.zshrc" ]] && append_line_if_missing "$HOME/.zshrc" "$path_line"

  export PATH="${LEMONADE_BUILD_DIR}:$PATH"
  hash -r 2>/dev/null || true

  have lemond || have lemonade-server \
    || die "Neither 'lemond' nor 'lemonade-server' found after adding ${LEMONADE_BUILD_DIR} to PATH."
  have lemonade \
    || die "'lemonade' CLI not found after adding ${LEMONADE_BUILD_DIR} to PATH."
  info "Lemonade binaries are on PATH"
}

# ---------------------------------------------------------------------------
# Lemonade CLI helpers
# 'lemond'   — server daemon (replaces 'lemonade-server serve')
# 'lemonade' — CLI commands  (replaces 'lemonade-server list' etc.)
# ---------------------------------------------------------------------------
lemonade_cli() {
  if have lemonade; then
    lemonade "$@"
  elif have lemonade-server; then
    lemonade-server "$@"
  else
    die "'lemonade' not found on PATH"
  fi
}

# ---------------------------------------------------------------------------
# Step 6 — Start lemonade server in background (idempotent)
# ---------------------------------------------------------------------------
start_lemonade_server() {
  if curl -fsS --max-time 2 "${LEMONADE_BASE_URL}/api/v1/models" >/dev/null 2>&1; then
    info "Lemonade server already running at ${LEMONADE_BASE_URL} — skipping start"
    return 0
  fi

  local server_cmd
  if have lemond; then
    server_cmd="lemond"
  elif have lemonade-server; then
    warn "'lemond' not found, falling back to deprecated 'lemonade-server'"
    server_cmd="lemonade-server"
  else
    die "Neither 'lemond' nor 'lemonade-server' found on PATH"
  fi

  info "Starting lemonade server via '${server_cmd} serve' in background..."
  nohup "$server_cmd" > /tmp/lemonade-server.log 2>&1 &
  disown

  local attempts=0 max_attempts=10
  while (( attempts < max_attempts )); do
    if curl -fsS --max-time 2 "${LEMONADE_BASE_URL}/api/v1/models" >/dev/null 2>&1; then
      info "Lemonade server is up"
      return 0
    fi
    (( attempts++ )) || true
    sleep 2
  done
  die "Lemonade server did not become reachable after ${max_attempts} attempts. Check /tmp/lemonade-server.log"
}

# ---------------------------------------------------------------------------
# Step 7 — Model selection using 'lemonade list'
# ---------------------------------------------------------------------------
pick_from_menu() {
  local _result_var="$1"; shift
  local _prompt="$1"; shift
  local -a _items=("$@")
  local _count=${#_items[@]} _cur=0

  local _old_stty
  _old_stty="$(stty -g < /dev/tty 2>/dev/null)"
  stty -echo -icanon min 1 time 0 < /dev/tty 2>/dev/null
  printf '\033[?25l' > /dev/tty

  _draw_menu() {
    local i
    for i in "${!_items[@]}"; do
      printf '\r\033[2K' > /dev/tty
      if (( i == _cur )); then
        printf '  \033[1;7;36m > %s \033[0m\n' "${_items[$i]}" > /dev/tty
      else
        printf '  \033[0;90m   %s\033[0m\n' "${_items[$i]}" > /dev/tty
      fi
    done
    printf '\r\033[2K\033[0;33m  ↑↓ move  ⏎ select\033[0m' > /dev/tty
    printf '\033[%dA' "$(( _count ))" > /dev/tty
  }

  printf '\n' > /dev/tty
  printf '\033[1;34m[INFO]\033[0m %s\n\n' "$_prompt" > /dev/tty
  _draw_menu

  local _key
  while true; do
    IFS= read -r -n1 _key < /dev/tty 2>/dev/null || true
    if [[ "$_key" == $'\x1b' ]]; then
      local _s1 _s2
      IFS= read -r -n1 -t 0.1 _s1 < /dev/tty 2>/dev/null || true
      IFS= read -r -n1 -t 0.1 _s2 < /dev/tty 2>/dev/null || true
      if [[ "$_s1" == "[" ]]; then
        case "$_s2" in
          A) (( _cur > 0 )) && (( _cur-- )); _draw_menu ;;
          B) (( _cur < _count - 1 )) && (( _cur++ )) || true; _draw_menu ;;
        esac
      fi
    elif [[ "$_key" == "" || "$_key" == $'\n' ]]; then
      break
    elif [[ "$_key" == "k" ]]; then (( _cur > 0 )) && (( _cur-- )); _draw_menu
    elif [[ "$_key" == "j" ]]; then (( _cur < _count - 1 )) && (( _cur++ )) || true; _draw_menu
    fi
  done

  printf '\033[%dB' "$(( _count ))" > /dev/tty
  printf '\r\033[2K\n' > /dev/tty
  printf '\033[?25h' > /dev/tty
  stty "$_old_stty" < /dev/tty 2>/dev/null || true
  eval "$_result_var=\${_items[\$_cur]}"
}

# Parse 'lemonade list' fixed-width output into parallel arrays:
#   LEMONADE_MODEL_NAMES[] — rich display label shown in picker
#   LEMONADE_MODEL_IDS[]   — raw model name passed to openclaw
parse_lemonade_models() {
  LEMONADE_MODEL_NAMES=()
  LEMONADE_MODEL_IDS=()
  LEMONADE_MODEL_DOWNLOADED=()

  local line name downloaded backend label
  while IFS= read -r line; do
    [[ "$line" =~ ^Model\ Name ]] && continue
    [[ "$line" =~ ^-+$         ]] && continue
    [[ "$line" =~ ^WARNING     ]] && continue
    [[ -z "${line// /}"        ]] && continue

    # Columns are fixed-width; split on runs of 2+ spaces
    name="$(      printf '%s' "$line" | awk -F'  +' '{print $1}')"
    downloaded="$(printf '%s' "$line" | awk -F'  +' '{print $2}')"
    backend="$(   printf '%s' "$line" | awk -F'  +' '{print $NF}')"

    [[ -z "$name" ]] && continue

    label="${name}  [${backend}]"
    [[ "$downloaded" == "Yes" ]] && label+=" ✓" || label+=" (not downloaded)"
    LEMONADE_MODEL_NAMES+=("$label")
    LEMONADE_MODEL_IDS+=("$name")
    LEMONADE_MODEL_DOWNLOADED+=("$downloaded")
  done < <(lemonade_cli list 2>/dev/null)

  (( ${#LEMONADE_MODEL_IDS[@]} > 0 )) \
    || die "No models found via 'lemonade list'. Check server_models.json."
}

select_lemonade_model() {
  if [[ -n "$OPENCLAW_LEMONADE_MODEL_ID" ]]; then
    info "Using model from environment: $OPENCLAW_LEMONADE_MODEL_ID"
    return 0
  fi

  info "Querying available models via 'lemonade list'..."
  parse_lemonade_models

  if (( ${#LEMONADE_MODEL_IDS[@]} == 1 )); then
    OPENCLAW_LEMONADE_MODEL_ID="${LEMONADE_MODEL_IDS[0]}"
    info "Only one model available: ${OPENCLAW_LEMONADE_MODEL_ID}"
  else
    local selected_label
    pick_from_menu selected_label \
      "Select a model (✓ = already downloaded):" \
      "${LEMONADE_MODEL_NAMES[@]}"

    local i
    for i in "${!LEMONADE_MODEL_NAMES[@]}"; do
      if [[ "${LEMONADE_MODEL_NAMES[$i]}" == "$selected_label" ]]; then
        OPENCLAW_LEMONADE_MODEL_ID="${LEMONADE_MODEL_IDS[$i]}"
        break
      fi
    done
  fi

  [[ -n "$OPENCLAW_LEMONADE_MODEL_ID" ]] || die "Could not resolve selected model id"
  info "Selected model: ${OPENCLAW_LEMONADE_MODEL_ID}"

  # Check if the selected model is downloaded; offer to pull it if not
  local selected_idx
  for selected_idx in "${!LEMONADE_MODEL_IDS[@]}"; do
    [[ "${LEMONADE_MODEL_IDS[$selected_idx]}" == "$OPENCLAW_LEMONADE_MODEL_ID" ]] && break
  done

  if [[ "${LEMONADE_MODEL_DOWNLOADED[$selected_idx]}" != "Yes" ]]; then
    local pull_choice
    pick_from_menu pull_choice \
      "'${OPENCLAW_LEMONADE_MODEL_ID}' is not downloaded yet. Download it now?" \
      "Yes — download now" \
      "No — go back and pick a different model"

    if [[ "$pull_choice" == No* ]]; then
      OPENCLAW_LEMONADE_MODEL_ID=""
      select_lemonade_model   # recurse back to picker
      return
    fi

    info "Pulling ${OPENCLAW_LEMONADE_MODEL_ID} (this may take a while)..."
    lemonade_cli pull "$OPENCLAW_LEMONADE_MODEL_ID" \
      || die "lemonade pull failed for ${OPENCLAW_LEMONADE_MODEL_ID}"
    info "Download complete"
  fi
}

# ---------------------------------------------------------------------------
# Step 7b — Install OpenClaw if not already present
# ---------------------------------------------------------------------------
refresh_openclaw_path() {
  export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
  if have npm; then
    local npm_prefix
    npm_prefix="$(npm prefix -g 2>/dev/null || true)"
    if [[ -n "$npm_prefix" ]]; then
      export PATH="$npm_prefix/bin:$npm_prefix:$PATH"
    fi
  fi
  hash -r 2>/dev/null || true
}

persist_openclaw_path() {
  refresh_openclaw_path
  local openclaw_bin
  openclaw_bin="$(command -v openclaw 2>/dev/null || true)"
  if [[ -z "$openclaw_bin" ]]; then
    for search_dir in \
      "$HOME/.local/bin" \
      "$HOME/.npm-global/bin" \
      /usr/local/bin; do
      if [[ -x "$search_dir/openclaw" ]]; then
        openclaw_bin="$search_dir/openclaw"
        break
      fi
    done
  fi
  if [[ -n "$openclaw_bin" ]]; then
    local bin_dir
    bin_dir="$(dirname "$openclaw_bin")"
    info "Found openclaw at $openclaw_bin"
    local path_line="export PATH=\"${bin_dir}:\$PATH\""
    append_line_if_missing "$HOME/.profile" "$path_line"
    append_line_if_missing "$HOME/.bashrc" "$path_line"
    [[ -f "$HOME/.zshrc" ]] && append_line_if_missing "$HOME/.zshrc" "$path_line"
    export PATH="$bin_dir:$PATH"
    hash -r 2>/dev/null || true
  fi
}

install_openclaw() {
  # Set npm prefix before installing so the binary lands somewhere predictable
  mkdir -p "$HOME/.npm-global"
  export NPM_CONFIG_PREFIX="$HOME/.npm-global"
  have npm && npm config set prefix "$HOME/.npm-global" >/dev/null 2>&1 || true

  refresh_openclaw_path
  if have openclaw; then
    info "OpenClaw already installed — skipping"
    refresh_openclaw_path
    return 0
  fi

  info "Installing OpenClaw..."
  curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-prompt --no-onboard

  have npm && npm config set prefix "$HOME/.npm-global" >/dev/null 2>&1 || true
  persist_openclaw_path

  have openclaw || die "OpenClaw installation failed — 'openclaw' not found on PATH after install"
  info "OpenClaw installed successfully"
}

# ---------------------------------------------------------------------------
# Step 8 — OpenClaw onboard (non-interactive)
# ---------------------------------------------------------------------------
backup_openclaw_config() {
  [[ -f "$OPENCLAW_CONFIG_FILE" ]] || return 0
  local backup="${OPENCLAW_CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$OPENCLAW_CONFIG_FILE" "$backup"
  info "Backed up existing config to $backup"
}

is_openclaw_configured() {
  [[ -f "$OPENCLAW_CONFIG_FILE" ]] || return 1
  python3 - <<'PY' "$OPENCLAW_CONFIG_FILE" "lemonade" "$OPENCLAW_LEMONADE_MODEL_ID"
import json, sys
from pathlib import Path
try:
    cfg = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
except Exception:
    sys.exit(1)
providers = cfg.get('models', {}).get('providers', {})
if sys.argv[2] not in providers:
    sys.exit(1)
models = providers[sys.argv[2]].get('models', [])
if not any(isinstance(m, dict) and m.get('id') == sys.argv[3] for m in models):
    sys.exit(1)
if not cfg.get('gateway'):
    sys.exit(1)
sys.exit(0)
PY
}

run_noninteractive_onboard() {
  info "Configuring OpenClaw against lemonade server (${LEMONADE_BASE_URL}/api/v1)..."
  openclaw onboard \
    --non-interactive \
    --mode local \
    --auth-choice custom-api-key \
    --custom-base-url "${LEMONADE_BASE_URL}/api/v1" \
    --custom-model-id "$OPENCLAW_LEMONADE_MODEL_ID" \
    --custom-provider-id "lemonade" \
    --custom-compatibility "openai" \
    --custom-api-key "lemonade" \
    --secret-input-mode plaintext \
    --gateway-port "$OPENCLAW_LEMONADE_GATEWAY_PORT" \
    --gateway-bind "$OPENCLAW_LEMONADE_GATEWAY_BIND" \
    --skip-health \
    --accept-risk
  RAN_ONBOARD=1
}

configure_openclaw() {
  refresh_openclaw_path
  have openclaw || die "'openclaw' not found on PATH even after install"

  if is_openclaw_configured; then
    info "OpenClaw already configured for lemonade/${OPENCLAW_LEMONADE_MODEL_ID} — skipping onboard"
    RAN_ONBOARD=1
    return 0
  fi

  backup_openclaw_config
  run_noninteractive_onboard || die "OpenClaw onboarding against lemonade server failed."
}

# ---------------------------------------------------------------------------
# Step 9 — Post-onboard tuning
# ---------------------------------------------------------------------------
auto_tune_config() {
  [[ "$OPENCLAW_LEMONADE_SKIP_TUNING" == "1" ]] && return 0
  [[ -f "$OPENCLAW_CONFIG_FILE" ]] || return 0

  python3 - <<'PY' \
    "$OPENCLAW_CONFIG_FILE" \
    "lemonade" \
    "$OPENCLAW_LEMONADE_MODEL_ID" \
    "$OPENCLAW_LEMONADE_CONTEXT_TOKENS" \
    "$OPENCLAW_LEMONADE_MODEL_MAX_TOKENS" \
    "$OPENCLAW_LEMONADE_MAX_AGENTS" \
    "$OPENCLAW_LEMONADE_MAX_SUBAGENTS" \
    "$LEMONADE_BASE_URL"
import json, sys
from pathlib import Path

config_path      = Path(sys.argv[1])
provider_id      = sys.argv[2]
model_id         = sys.argv[3]
context_tokens   = int(sys.argv[4])
model_max_tokens = int(sys.argv[5])
max_agents       = int(sys.argv[6])
max_subagents    = int(sys.argv[7])
lemonade_base_url = sys.argv[8]

cfg = json.loads(config_path.read_text(encoding='utf-8'))

agents   = cfg.setdefault('agents', {})
defaults = agents.setdefault('defaults', {})
model_ref = f"{provider_id}/{model_id}"

current_model = defaults.get('model')
if isinstance(current_model, str):
    defaults['model'] = {'primary': model_ref}
elif isinstance(current_model, dict):
    current_model['primary'] = model_ref
else:
    defaults['model'] = {'primary': model_ref}

defaults['contextTokens'] = context_tokens
defaults['maxConcurrent']  = max_agents
defaults.setdefault('subagents', {})['maxConcurrent'] = max_subagents

providers       = cfg.setdefault('models', {}).setdefault('providers', {})
provider        = providers.setdefault(provider_id, {})
provider_models = provider.setdefault('models', [])

entry = next((m for m in provider_models if isinstance(m, dict) and m.get('id') == model_id), None)
if entry is None:
    entry = {'id': model_id, 'name': model_id}
    provider_models.append(entry)

entry['contextWindow'] = context_tokens
entry['maxTokens']     = model_max_tokens
entry['cost'] = {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}
entry['reasoning'] = True
entry['compat'] = {'thinkingFormat': 'qwen'}

# --- Embeddings via lemonade's nomic-embed (OpenAI-compatible /api/v1/embeddings) ---
ms = defaults.setdefault('memorySearch', {})
ms['enabled'] = True
ms['provider'] = 'openai'
ms['model'] = 'nomic-embed-text-v1-GGUF'
remote = ms.setdefault('remote', {})
remote['baseUrl'] = lemonade_base_url + '/api/v1'
remote['apiKey'] = 'lemonade'

# --- Browser profile: connect to Chrome via CDP on port 9222 ---
browser = cfg.setdefault('browser', {})
profiles = browser.setdefault('profiles', {})
chrome_profile = profiles.setdefault('default', {})
chrome_profile['cdpUrl'] = 'http://127.0.0.1:9222'
chrome_profile.setdefault('color', '4A90D9')

config_path.write_text(json.dumps(cfg, indent=2, sort_keys=False) + '\n', encoding='utf-8')
PY

  info "Applied tuning to ${OPENCLAW_CONFIG_FILE}"
  info "Embeddings configured (nomic-embed-text-v1 via Lemonade at ${LEMONADE_BASE_URL}/api/v1)"
}

# ---------------------------------------------------------------------------
# Step 9b — Install Google Chrome (needed for OpenClaw browser control)
# ---------------------------------------------------------------------------
install_chrome_if_missing() {
  if have google-chrome-stable || have google-chrome || have chromium-browser || have chromium; then
    info "Chrome/Chromium already installed — skipping"
    return 0
  fi

  info "Installing Google Chrome..."
  sudo apt-get install -y wget gnupg2

  wget -qO- https://dl.google.com/linux/linux_signing_key.pub \
    | sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg

  printf 'deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main\n' \
    | sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null

  sudo apt-get update
  DEBIAN_FRONTEND=noninteractive sudo apt-get install -y google-chrome-stable

  have google-chrome-stable || warn "Chrome install finished but 'google-chrome-stable' not found on PATH."
  info "Google Chrome installed"
}

# ---------------------------------------------------------------------------
# Step 9c — Write TOOLS.md so the agent knows how to use Chrome
# ---------------------------------------------------------------------------
write_tools_md() {
  local ws_dir="$HOME/.openclaw/workspace"
  local tools_file="$ws_dir/TOOLS.md"

  if [[ -f "$tools_file" ]] && ! grep -q '## Chrome Browser Usage and Control' "$tools_file" 2>/dev/null; then
    info "Appending browser environment info to TOOLS.md"
    cat >> "$tools_file" <<'TOOLS_APPEND'

## Chrome Browser Usage and Control
- Chrome is available with CDP on port 9222
- If the user asks you to open a browser or visit a URL, use Chrome via the commands below
- Use the `default` browser profile: `openclaw browser --browser-profile default`
- To navigate: `openclaw browser --browser-profile default navigate <url>`
- To launch Chrome manually: `google-chrome-stable --remote-debugging-port=9222 --user-data-dir=$HOME/.openclaw/browser/chrome-profile`

## Environment
- Platform: Linux (native)
- LLM Backend: Lemonade (local, OpenAI-compatible API)
TOOLS_APPEND
  elif [[ ! -f "$tools_file" ]]; then
    mkdir -p "$ws_dir"
    info "Creating TOOLS.md with browser environment info"
    cat > "$tools_file" <<'TOOLS_NEW'
# Tools

## Chrome Browser Usage and Control
- Chrome is available with CDP on port 9222
- If the user asks you to open a browser or visit a URL, use Chrome via the commands below
- Use the `default` browser profile: `openclaw browser --browser-profile default`
- To navigate: `openclaw browser --browser-profile default navigate <url>`
- To launch Chrome manually: `google-chrome-stable --remote-debugging-port=9222 --user-data-dir=$HOME/.openclaw/browser/chrome-profile`

## Environment
- Platform: Linux (native)
- LLM Backend: Lemonade (local, OpenAI-compatible API)
TOOLS_NEW
  fi
}

# ---------------------------------------------------------------------------
# Step 9d — Launch Chrome with CDP and open the OpenClaw dashboard
# ---------------------------------------------------------------------------
launch_chrome_dashboard() {
  local chrome_bin=""
  if have google-chrome-stable;  then chrome_bin="google-chrome-stable"
  elif have google-chrome;        then chrome_bin="google-chrome"
  elif have chromium-browser;     then chrome_bin="chromium-browser"
  elif have chromium;             then chrome_bin="chromium"
  fi

  if [[ -z "$chrome_bin" ]]; then
    warn "Chrome not found — open the dashboard manually."
    return 0
  fi

  # Get the dashboard URL (includes access token)
  local dashboard_url=""
  local dashboard_output
  dashboard_output="$(openclaw dashboard --no-open 2>&1 || true)"
  dashboard_url="$(printf '%s' "$dashboard_output" | grep -oP 'https?://\S+' | head -1 || true)"

  # Fallback: extract token from config
  if [[ -z "$dashboard_url" ]] && [[ -f "$OPENCLAW_CONFIG_FILE" ]]; then
    local gw_token
    gw_token="$(python3 -c "
import json, sys
from pathlib import Path
try:
    cfg = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
    token = cfg.get('gateway', {}).get('auth', {}).get('token', '')
    if token:
        print(token)
except Exception:
    pass
" "$OPENCLAW_CONFIG_FILE" 2>/dev/null || true)"
    if [[ -n "$gw_token" ]]; then
      dashboard_url="http://127.0.0.1:${OPENCLAW_LEMONADE_GATEWAY_PORT}/#token=${gw_token}"
    fi
  fi

  if [[ -z "$dashboard_url" ]]; then
    dashboard_url="http://127.0.0.1:${OPENCLAW_LEMONADE_GATEWAY_PORT}/"
    warn "Could not retrieve dashboard token — you may need to authenticate manually."
  fi

  local chrome_user_data="$HOME/.openclaw/browser/chrome-profile"
  mkdir -p "$chrome_user_data"

  info "Launching Chrome with CDP and opening dashboard: ${dashboard_url}"
  nohup "$chrome_bin" \
    --no-first-run \
    --no-default-browser-check \
    --remote-debugging-port=9222 \
    --remote-allow-origins="*" \
    --user-data-dir="$chrome_user_data" \
    "$dashboard_url" >/dev/null 2>&1 &
  disown
}

# ---------------------------------------------------------------------------
# Step 10 — Interactive onboard (gateway/hooks/skills) + hatch
# ---------------------------------------------------------------------------
interactive_onboard_and_hatch() {
  refresh_openclaw_path

  # Pass 1: configure gateway, hooks, skills, channels — skip auth (already done)
  info "Launching interactive onboard for gateway, hooks, skills, and channels..."
  printf '\n'
  openclaw onboard --auth-choice skip --skip-ui < /dev/tty \
    || warn "Interactive onboard exited with an error. Re-run later with: openclaw onboard"
  printf '\n'

  write_tools_md

  info "Building memory search index..."
  openclaw memory index 2>&1 || warn "Memory indexing failed. Re-run with: openclaw memory index"

  print_summary
  launch_chrome_dashboard

  # Pass 2: hatch only (opens the UI experience)
  info "Launching hatching..."
  printf '\n'
  openclaw onboard \
    --auth-choice skip \
    --accept-risk \
    --skip-search \
    --skip-skills \
    --skip-channels \
    --skip-daemon \
    --skip-health \
    < /dev/tty || warn "Hatching exited with an error. Re-run with: openclaw onboard"
}

# ---------------------------------------------------------------------------
# Step 11 — Start OpenClaw gateway (foreground)
# ---------------------------------------------------------------------------
start_openclaw_gateway() {
  info "Starting OpenClaw gateway (port ${OPENCLAW_LEMONADE_GATEWAY_PORT})..."
  openclaw gateway run \
    --bind "$OPENCLAW_LEMONADE_GATEWAY_BIND" \
    --port "$OPENCLAW_LEMONADE_GATEWAY_PORT" \
    --force
}

print_summary() {
  printf '\n'
  info "${SCRIPT_NAME} ${SCRIPT_VERSION} complete"
  printf '  Lemonade dir      : %s\n' "$LEMONADE_DIR"
  printf '  Lemonade endpoint : %s/api/v1\n' "$LEMONADE_BASE_URL"
  printf '  Model             : %s\n' "$OPENCLAW_LEMONADE_MODEL_ID"
  printf '  Context tokens    : %s\n' "$OPENCLAW_LEMONADE_CONTEXT_TOKENS"
  printf '  Max tokens        : %s\n' "$OPENCLAW_LEMONADE_MODEL_MAX_TOKENS"
  printf '  Agent concurrency : %s\n' "$OPENCLAW_LEMONADE_MAX_AGENTS"
  printf '  Subagent conc.    : %s\n' "$OPENCLAW_LEMONADE_MAX_SUBAGENTS"
  printf '  Gateway port      : %s\n' "$OPENCLAW_LEMONADE_GATEWAY_PORT"
  printf '\n'
}

main() {
  print_banner
  require_linux

  printf '\n'
  printf '\033[1;33m================================================================\033[0m\n'
  printf '\033[1;33m  IMPORTANT — PLEASE READ BEFORE CONTINUING\033[0m\n'
  printf '\033[1;33m================================================================\033[0m\n'
  printf '\n'
  printf '\033[1;33mOpenClaw is a highly autonomous AI agent. Giving any AI agent\033[0m\n'
  printf '\033[1;33maccess to any system may result in the AI acting in unpredictable\033[0m\n'
  printf '\033[1;33mways with unpredictable/unforeseen outcomes. Use of any AMD\033[0m\n'
  printf '\033[1;33msuggested implementations is made at your own risk. AMD makes no\033[0m\n'
  printf '\033[1;33mrepresentations/warranties with your use of an AI agent as\033[0m\n'
  printf '\033[1;33mdescribed herein. Failure to exercise appropriate caution may\033[0m\n'
  printf '\033[1;33mresult in damages (foreseen and/or unforeseen).\033[0m\n'
  printf '\n'
  printf '\033[1;33m================================================================\033[0m\n'
  printf '\n'
  local accept=""
  read -r -p "Do you accept the risk and wish to continue? [y/N]: " accept < /dev/tty
  if [[ ! "$accept" =~ ^[Yy] ]]; then
    die "Risk not accepted. Exiting."
  fi
  printf '\n'

  sudo -v                 
  install_prerequisites   # Step 1: cmake, git, build-essential, jq, curl, python3
  clone_lemonade          # Step 2: git clone lemonade
  patch_server_models     # Step 3: inject Qwen model entry into server_models.json
  build_lemonade          # Step 4: setup.sh + cmake --build
  add_lemonade_to_path    # Step 5: export PATH with build dir, verify binaries
  start_lemonade_server   # Step 6: lemond (background)
  select_lemonade_model   # Step 7: lemonade list → interactive picker
  install_openclaw              # Step 7b: curl install openclaw if missing
  configure_openclaw            # Step 8: openclaw onboard --non-interactive
  auto_tune_config              # Step 9: patch openclaw.json with model tuning
  install_chrome_if_missing     # Step 9b: google-chrome for browser control
  interactive_onboard_and_hatch # Step 10: gateway/hooks/skills + hatch + chrome dashboard
  start_openclaw_gateway        # Step 11: openclaw gateway run (foreground)
}

main "$@"
