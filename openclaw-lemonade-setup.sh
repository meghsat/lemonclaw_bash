#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="OpenclawXLemonade"
SCRIPT_VERSION="0.1.0"

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

RECOMMENDED_MODEL_ID="Qwen3.5-35B-A3B-Q4-K-M-GGUF"
RECOMMENDED_MODEL_SIZE="~22 GB"

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

# ---------------------------------------------------------------------------
# Step 1 — Install Lemonade via PPA
# ---------------------------------------------------------------------------
install_lemonade_via_ppa() {
  have apt-get || die "This script requires apt-get (Ubuntu/Debian)."

  info "Installing prerequisites..."
  local missing=()
  for pkg in software-properties-common curl python3 wget; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if (( ${#missing[@]} > 0 )); then
    sudo apt-get update
    DEBIAN_FRONTEND=noninteractive sudo apt-get install -y "${missing[@]}"
  fi

  if have lemonade; then
    info "Lemonade already installed at $(command -v lemonade) — skipping PPA install"
    return 0
  fi

  info "Adding lemonade-team/bleeding-edge PPA..."
  sudo add-apt-repository -y ppa:lemonade-team/bleeding-edge

  info "Updating package lists..."
  sudo apt-get update

  info "Installing lemonade-server..."
  DEBIAN_FRONTEND=noninteractive sudo apt-get install -y lemonade-server

  have lemonade \
    || die "'lemonade' not found on PATH after PPA install. Check that /usr/bin or /usr/local/bin is in your PATH."
  info "Lemonade installed: $(command -v lemonade)"
}

# ---------------------------------------------------------------------------
# Lemonade CLI helper — resolved once, cached in LEMONADE_CMD
# ---------------------------------------------------------------------------
LEMONADE_CMD=""

_resolve_lemonade_cmd() {
  if have lemonade; then          LEMONADE_CMD="lemonade"
  elif have lemonade-server; then LEMONADE_CMD="lemonade-server"
  else die "'lemonade' not found on PATH"; fi
}

lemonade_cli() { "$LEMONADE_CMD" "$@"; }

# ---------------------------------------------------------------------------
# Step 2 — Start lemonade server in background (idempotent)
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

  info "Starting lemonade server via '${server_cmd}' in background..."
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
# Step 2b — Ensure lemonade ctx_size is large enough for thinking models
# ---------------------------------------------------------------------------
LEMONADE_MIN_CTX_SIZE="${LEMONADE_MIN_CTX_SIZE:-32768}"

configure_lemonade_ctx_size() {
  local current_ctx
  current_ctx="$(lemonade config 2>/dev/null | awk '/^[[:space:]]*ctx_size/{print $NF}')"

  if [[ -n "$current_ctx" ]] && (( current_ctx >= LEMONADE_MIN_CTX_SIZE )); then
    info "Lemonade ctx_size is ${current_ctx} (>= ${LEMONADE_MIN_CTX_SIZE}) — skipping"
    return 0
  fi

  info "Setting lemonade ctx_size to ${LEMONADE_MIN_CTX_SIZE} (was ${current_ctx:-unknown})..."
  lemonade config set "ctx_size=${LEMONADE_MIN_CTX_SIZE}" \
    || die "Failed to configure lemonade ctx_size — is the server running?"

  # Unload every downloaded model so they all reload with the new ctx_size.
  local model_ids_json
  model_ids_json="$(curl -s "${LEMONADE_BASE_URL}/api/v1/models" 2>/dev/null \
    | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin).get('data', [])
    ids = [m['id'] for m in data if isinstance(m, dict) and m.get('downloaded')]
    print('\n'.join(ids))
except Exception:
    pass
" 2>/dev/null || true)"

  if [[ -n "$model_ids_json" ]]; then
    while IFS= read -r model_id; do
      [[ -z "$model_id" ]] && continue
      info "Unloading '${model_id}' so it reloads with ctx_size=${LEMONADE_MIN_CTX_SIZE}..."
      curl -s -X POST "${LEMONADE_BASE_URL}/api/v1/unload" \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"${model_id}\"}" >/dev/null 2>&1 || true
    done <<< "$model_ids_json"
  fi

  info "Context size configured: ${LEMONADE_MIN_CTX_SIZE} tokens"
}

# ---------------------------------------------------------------------------
# Step 3 — Model selection
#   Suggest the recommended Qwen model first
#   If accepted: lemonade import + pull
#   If declined: show lemonade list and let the user pick interactively
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
    local i term_width max_label label
    term_width=$(tput cols 2>/dev/null || printf '80')
    max_label=$(( term_width - 7 ))
    printf '\033[u' > /dev/tty
    for i in "${!_items[@]}"; do
      printf '\r\033[2K' > /dev/tty
      label="${_items[$i]}"
      (( ${#label} > max_label )) && label="${label:0:$(( max_label - 1 ))}…"
      if (( i == _cur )); then
        printf '  \033[1;7;36m > %s \033[0m\n' "$label" > /dev/tty
      else
        printf '  \033[0;90m   %s\033[0m\n' "$label" > /dev/tty
      fi
    done
    printf '\r\033[2K\033[0;33m  ↑↓ move  ⏎ select\033[0m' > /dev/tty
  }

  printf '\n' > /dev/tty
  printf '\033[1;34m[INFO]\033[0m %s\n\n' "$_prompt" > /dev/tty
  printf '\033[s' > /dev/tty
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

  printf '\r\033[2K\n' > /dev/tty
  printf '\033[?25h' > /dev/tty
  stty "$_old_stty" < /dev/tty 2>/dev/null || true
  printf -v "$_result_var" '%s' "${_items[$_cur]}"
}

parse_lemonade_models() {
  LEMONADE_MODEL_NAMES=()
  LEMONADE_MODEL_IDS=()
  LEMONADE_MODEL_DOWNLOADED=()

  local name downloaded backend label display_name
  while IFS=$'\t' read -r name downloaded backend; do
    [[ -z "$name" ]] && continue
    display_name="${name#user.}"
    label="${display_name}  [${backend}]"
    [[ "$downloaded" == "Yes" ]] && label+=" ✓" || label+=" (not downloaded)"
    LEMONADE_MODEL_NAMES+=("$label")
    LEMONADE_MODEL_IDS+=("$name")
    LEMONADE_MODEL_DOWNLOADED+=("$downloaded")
  done < <(
    if [[ -n "${1:-}" ]]; then printf '%s\n' "$1"
    else lemonade_cli list 2>/dev/null; fi \
    | awk -F'  +' '
      /^Model Name/ || /^-+$/ || /^WARNING/ || /^[[:space:]]*$/ { next }
      $1 != "" { printf "%s\t%s\t%s\n", $1, $2, $NF }
    '
  )

  (( ${#LEMONADE_MODEL_IDS[@]} > 0 )) \
    || die "No models found via 'lemonade list'. Is the lemonade server running?"
}

import_recommended_model() {
  info "Importing recommended model into lemonade..."
  local tmp_json
  tmp_json="$(mktemp --suffix=.json)"
  cat > "$tmp_json" <<'JSON'
{
  "model_name": "Qwen3.5-35B-A3B-Q4-K-M-GGUF",
  "checkpoint": "unsloth/Qwen3.5-35B-A3B-GGUF:Qwen3.5-35B-A3B-Q4_K_M.gguf",
  "mmproj": "unsloth/Qwen3.5-35B-A3B-GGUF:mmproj-F16.gguf",
  "recipe": "llamacpp",
  "suggested": true,
  "labels": ["vision", "tool-calling", "hot"],
  "size": 19.7,
  "recipe_options": {"ctx_size": 32768}
}
JSON
  lemonade_cli import "$tmp_json" \
    || die "lemonade import failed. Check the server logs."
  rm -f "$tmp_json"
  info "Model imported: ${RECOMMENDED_MODEL_ID}"
}

pull_model_if_needed() {
  local model_id="$1"
  local downloaded="${2:-}"

  if [[ -z "$downloaded" ]]; then
    downloaded="$(lemonade_cli list 2>/dev/null \
      | awk -F'  +' -v m="$model_id" '$1==m {print $2}')"
  fi

  if [[ "$downloaded" == "Yes" ]]; then
    info "Model '${model_id}' is already downloaded."
    return 0
  fi

  info "Pulling '${model_id}' (this may take a while)..."
  lemonade_cli pull "$model_id" \
    || die "lemonade pull failed for ${model_id}"
  info "Download complete"
}

select_lemonade_model() {
  if [[ -n "$OPENCLAW_LEMONADE_MODEL_ID" ]]; then
    info "Using model from environment: $OPENCLAW_LEMONADE_MODEL_ID"
    return 0
  fi

  printf '\n'
  printf '\033[1;34m[INFO]\033[0m Recommended model for best experience:\n'
  printf '       \033[1;36munsloth/Qwen3.5-35B-A3B-GGUF:Qwen3.5-35B-A3B-Q4_K_M.gguf\033[0m\n'
  printf '       Size: \033[1;33m%s\033[0m\n' "$RECOMMENDED_MODEL_SIZE"
  printf '\n'

  local model_choice
  pick_from_menu model_choice \
    "Use the recommended Qwen3.5-35B-A3B-Q4_K_M model? (${RECOMMENDED_MODEL_SIZE} download)" \
    "Yes — import and use Qwen3.5-35B-A3B-Q4_K_M.gguf (recommended)" \
    "No — show available models and let me choose"

  if [[ "$model_choice" == Yes* ]]; then
    import_recommended_model
    OPENCLAW_LEMONADE_MODEL_ID="user.${RECOMMENDED_MODEL_ID}"
    pull_model_if_needed "$OPENCLAW_LEMONADE_MODEL_ID"
  else
    while true; do
      info "Available models:"
      printf '\n'
      local list_output
      list_output="$(lemonade_cli list 2>/dev/null)"
      printf '%s\n\n' "$list_output"

      parse_lemonade_models "$list_output"

      local selected_idx=0
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
            selected_idx="$i"
            break
          fi
        done
      fi

      [[ -n "$OPENCLAW_LEMONADE_MODEL_ID" ]] || die "Could not resolve selected model id"
      info "Selected model: ${OPENCLAW_LEMONADE_MODEL_ID}"

      # Check if selected model is downloaded; offer to pull if not
      if [[ "${LEMONADE_MODEL_DOWNLOADED[$selected_idx]}" != "Yes" ]]; then
        local pull_choice
        pick_from_menu pull_choice \
          "'${OPENCLAW_LEMONADE_MODEL_ID}' is not downloaded yet. Download it now?" \
          "Yes — download now" \
          "No — go back and pick a different model"

        if [[ "$pull_choice" == No* ]]; then
          OPENCLAW_LEMONADE_MODEL_ID=""
          continue
        fi
      fi

      pull_model_if_needed "$OPENCLAW_LEMONADE_MODEL_ID" "${LEMONADE_MODEL_DOWNLOADED[$selected_idx]}"
      break
    done
  fi

  # If switching to a different model than what was previously configured,
  # unload the old model so it doesn't hold VRAM when the new one loads.
  if [[ -f "$OPENCLAW_CONFIG_FILE" ]]; then
    local prev_model
    prev_model="$(python3 -c "
import json, sys
from pathlib import Path
try:
    cfg = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
    ref = cfg.get('agents', {}).get('defaults', {}).get('model', {})
    primary = ref.get('primary', '') if isinstance(ref, dict) else str(ref)
    print(primary.split('/')[-1] if '/' in primary else primary)
except Exception:
    pass
" "$OPENCLAW_CONFIG_FILE" 2>/dev/null || true)"

    if [[ -n "$prev_model" ]] && [[ "$prev_model" != "$OPENCLAW_LEMONADE_MODEL_ID" ]]; then
      info "Model switch detected: '${prev_model}' -> '${OPENCLAW_LEMONADE_MODEL_ID}'"
      info "Unloading previous model to free VRAM and clear KV cache..."
      curl -s -X POST "${LEMONADE_BASE_URL}/api/v1/unload" \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"${prev_model}\"}" >/dev/null 2>&1 || true
    fi
  fi

  info "Using model: ${OPENCLAW_LEMONADE_MODEL_ID}"
}

# ---------------------------------------------------------------------------
# Step 4 — Install OpenClaw if not already present
# ---------------------------------------------------------------------------
_NPM_PREFIX=""

refresh_openclaw_path() {
  export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
  if have npm && [[ -z "$_NPM_PREFIX" ]]; then
    _NPM_PREFIX="$(npm prefix -g 2>/dev/null || true)"
  fi
  if [[ -n "$_NPM_PREFIX" ]]; then
    export PATH="$_NPM_PREFIX/bin:$_NPM_PREFIX:$PATH"
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
  mkdir -p "$HOME/.npm-global"
  export NPM_CONFIG_PREFIX="$HOME/.npm-global"

  refresh_openclaw_path
  if have openclaw; then
    info "OpenClaw already installed — skipping"
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
# Step 5 — OpenClaw onboard (non-interactive)
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
}

configure_openclaw() {
  refresh_openclaw_path
  have openclaw || die "'openclaw' not found on PATH even after install"

  if is_openclaw_configured; then
    info "OpenClaw already configured for lemonade/${OPENCLAW_LEMONADE_MODEL_ID} — skipping onboard"
    return 0
  fi

  backup_openclaw_config
  run_noninteractive_onboard || die "OpenClaw onboarding against lemonade server failed."

  if systemctl --user is-failed openclaw-gateway.service >/dev/null 2>&1; then
    info "Resetting failed gateway service (race condition during onboard)..."
    systemctl --user reset-failed openclaw-gateway.service 2>/dev/null || true
  fi
  systemctl --user start openclaw-gateway.service 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Step 6 — Post-onboard tuning
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
entry['reasoning']     = True
entry['cost'] = {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}

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
# Step 6b — Install Google Chrome (needed for OpenClaw browser control)
# ---------------------------------------------------------------------------
_CHROME_BIN=""

find_chrome_bin() {
  if [[ -n "$_CHROME_BIN" ]]; then printf '%s' "$_CHROME_BIN"; return; fi
  if   have google-chrome-stable; then _CHROME_BIN="google-chrome-stable"
  elif have google-chrome;        then _CHROME_BIN="google-chrome"
  elif have chromium-browser;     then _CHROME_BIN="chromium-browser"
  elif have chromium;             then _CHROME_BIN="chromium"
  fi
  printf '%s' "$_CHROME_BIN"
}

install_chrome_if_missing() {
  if [[ -n "$(find_chrome_bin)" ]]; then
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
# Step 6c — Write TOOLS.md so the agent knows how to use Chrome
# ---------------------------------------------------------------------------
_tools_md_body() {
  cat <<'BODY'

## Chrome Browser Usage and Control
- Chrome is available with CDP on port 9222
- If the user asks you to open a browser or visit a URL, use Chrome via the commands below
- Use the `default` browser profile: `openclaw browser --browser-profile default`
- To navigate: `openclaw browser --browser-profile default navigate <url>`
- To launch Chrome manually: `google-chrome-stable --remote-debugging-port=9222 --user-data-dir=$HOME/.openclaw/browser/chrome-profile`

## Environment
- Platform: Linux (native)
- LLM Backend: Lemonade (local, OpenAI-compatible API)
BODY
}

write_tools_md() {
  local ws_dir="$HOME/.openclaw/workspace"
  local tools_file="$ws_dir/TOOLS.md"

  if [[ -f "$tools_file" ]] && ! grep -q '## Chrome Browser Usage and Control' "$tools_file" 2>/dev/null; then
    info "Appending browser environment info to TOOLS.md"
    _tools_md_body >> "$tools_file"
  elif [[ ! -f "$tools_file" ]]; then
    mkdir -p "$ws_dir"
    info "Creating TOOLS.md with browser environment info"
    { printf '# Tools\n'; _tools_md_body; } > "$tools_file"
  fi
}

# ---------------------------------------------------------------------------
# Step 6d — Launch Chrome with CDP and open the OpenClaw dashboard
# ---------------------------------------------------------------------------
launch_chrome_dashboard() {
  local chrome_bin
  chrome_bin="$(find_chrome_bin)"

  if [[ -z "$chrome_bin" ]]; then
    warn "Chrome not found — open the dashboard manually."
    return 0
  fi

  if curl -fsS --max-time 2 "http://127.0.0.1:9222/json/version" >/dev/null 2>&1; then
    info "Chrome CDP already reachable on port 9222 — skipping launch"
    return 0
  fi

  local dashboard_url=""
  local dashboard_output
  dashboard_output="$(openclaw dashboard --no-open 2>&1 || true)"
  dashboard_url="$(printf '%s' "$dashboard_output" | grep -oP 'https?://\S+' | head -1 || true)"

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
# Step 7 — Interactive onboard (gateway/hooks/skills) + hatch
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
# Step 8 — Start OpenClaw gateway (foreground)
# ---------------------------------------------------------------------------
start_openclaw_gateway() {
  if systemctl --user is-failed openclaw-gateway.service >/dev/null 2>&1; then
    info "Resetting failed gateway service state..."
    systemctl --user reset-failed openclaw-gateway.service 2>/dev/null || true
  fi

  trap '
    systemctl --user is-failed openclaw-gateway.service >/dev/null 2>&1 \
      && systemctl --user reset-failed openclaw-gateway.service 2>/dev/null
    systemctl --user is-active openclaw-gateway.service >/dev/null 2>&1 \
      || systemctl --user start openclaw-gateway.service 2>/dev/null
  ' EXIT INT TERM HUP

  info "Starting OpenClaw gateway (port ${OPENCLAW_LEMONADE_GATEWAY_PORT})..."
  openclaw gateway run \
    --bind "$OPENCLAW_LEMONADE_GATEWAY_BIND" \
    --port "$OPENCLAW_LEMONADE_GATEWAY_PORT" \
    --force || true
}

print_summary() {
  printf '\n'
  info "${SCRIPT_NAME} ${SCRIPT_VERSION} complete"
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
  install_lemonade_via_ppa    # Step 1: add PPA, apt install lemonade-server
  _resolve_lemonade_cmd       # resolve lemonade/lemonade-server once
  start_lemonade_server       # Step 2: lemond (background)
  configure_lemonade_ctx_size # Step 2b: bump ctx_size so thinking models have room
  select_lemonade_model       # Step 3: suggest Qwen or show lemonade list + picker
  install_openclaw            # Step 4: curl install openclaw if missing
  configure_openclaw          # Step 5: openclaw onboard --non-interactive
  auto_tune_config            # Step 6: patch openclaw.json with model tuning
  install_chrome_if_missing   # Step 6b: google-chrome for browser control
  interactive_onboard_and_hatch # Step 7: gateway/hooks/skills + hatch + chrome dashboard
  start_openclaw_gateway      # Step 8: openclaw gateway run (foreground)
}

main "$@"

