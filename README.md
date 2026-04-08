# openclaw-lemonade-setup

[OpenClaw](https://openclaw.ai/) is a personal AI assistant that can browse the web, manage files, run code, and orchestrate multi-step tasks on your behalf. By default it connects to cloud-hosted AI APIs, but you can run it entirely on your own hardware using [Lemonade Server](https://lemonade-server.ai/) as the local backend — no API keys, no cloud costs, no data leaving your machine.

This script automates the full end-to-end setup: it installs and builds Lemonade Server, pulls an AI model, installs OpenClaw, and wires the two together so OpenClaw uses your local Lemonade instance as its inference backend.

---

## Prerequisites

- Ubuntu 24.04 (x86-64)
- Internet connection (for downloading packages and model weights)

---

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/meghsat/lemonclaw_bash/main/openclaw-lemonade-setup.sh | bash
```

The script is fully idempotent: Re-running it is safe and will skip any steps that are already complete.

### Environment overrides

All settings can be overridden via environment variables before running the script:

| Variable | Default | Description |
|---|---|---|
| `LEMONADE_DIR` | `~/lemonade-dev/lemonade` | Where the Lemonade source is cloned |
| `LEMONADE_BASE_URL` | `http://127.0.0.1:13305` | URL the Lemonade server listens on |
| `LEMONADE_PORT` | `13305` | Lemonade server port |
| `OPENCLAW_LEMONADE_MODEL_ID` | _(interactive)_ | Skip the model picker and use this model directly |
| `OPENCLAW_LEMONADE_CONTEXT_TOKENS` | `190000` | Context window size passed to OpenClaw |
| `OPENCLAW_LEMONADE_MODEL_MAX_TOKENS` | `64000` | Max output tokens per request |
| `OPENCLAW_LEMONADE_MAX_AGENTS` | `2` | Max concurrent top-level agents |
| `OPENCLAW_LEMONADE_MAX_SUBAGENTS` | `2` | Max concurrent subagents per agent |
| `OPENCLAW_LEMONADE_GATEWAY_PORT` | `18789` | Port the OpenClaw gateway listens on |
| `OPENCLAW_LEMONADE_GATEWAY_BIND` | `loopback` | Network interface for the gateway (`loopback` or `all`) |
| `OPENCLAW_LEMONADE_SKIP_TUNING` | `0` | Set to `1` to skip post-onboard config tuning |

---

## What the Script Does

### Step 1 — System prerequisites

Updates `apt` and installs: `git`, `build-essential` (gcc/g++/make), `wget`, `jq`, `curl`, and `python3`.

CMake 3.28+ is required to build Lemonade. If the system CMake is older than 3.28.0 (or absent), the script downloads and installs the official CMake 3.28.6 binary from the Kitware GitHub releases into `/usr/local`.

**Note:** The following steps build Lemonade from source to include an additional model, **Qwen3.5-35B-A3B-Q4-K-M-GGUF**, in the list. If you choose not to include this model, you don’t need to build Lemonade from source, simply running these steps will install the server.
```bash
sudo add-apt-repository ppa:lemonade-team/stable
sudo apt install lemonade-server
```

### Step 2 — Clone Lemonade

Clones the [lemonade-sdk/lemonade](https://github.com/lemonade-sdk/lemonade) repository into `~/lemonade-dev/lemonade` (or the path set by `LEMONADE_DIR`). Skipped if the directory already contains a git repo.

### Step 3 — Patch server_models.json

Lemonade ships with a registry of known models in `server_models.json`. This step injects an entry for the **Qwen3.5-35B-A3B-Q4-K-M-GGUF** model (a 4-bit quantised 35B mixture-of-experts model from Unsloth) so that Lemonade knows how to pull and load it.

The model entry sets the following properties:

- **checkpoint**: `unsloth/Qwen3.5-35B-A3B-GGUF:Qwen3.5-35B-A3B-Q4_K_M.gguf`
- **mmproj**: `mmproj-F16.gguf`
- **recipe**: `llamacpp`
- **suggested**: `true`
- **labels**: vision, tool-calling, hot
- **size**: 19.7 GB

Additionally, `ctx_size=32768` is written to `~/.cache/lemonade/recipe_options.json` so that `lemond` picks up the correct context size at load time (the `server_models.json` recipe options only apply during `lemonade pull`, not on load).

### Step 4 — Build Lemonade

Runs `setup.sh` inside the Lemonade repo (which installs its own system dependencies) and then builds the project with `cmake --build --preset default`. The resulting binaries: `lemond` (the server daemon) and `lemonade` (the CLI) are placed in `build/`.

Skipped if the `lemond` or `lemonade-server` binary is already present in the build directory.

### Step 5 — Add Lemonade to PATH

Appends an `export PATH` line for the Lemonade build directory to `~/.profile`, `~/.bashrc`, and `~/.zshrc` (if it exists), then exports the path for the current session. Verifies that both `lemond`/`lemonade-server` and the `lemonade` CLI are reachable.

### Step 6 — Start Lemonade Server

Pings `http://127.0.0.1:13305/api/v1/models` to check whether the server is already running. If not, launches `lemond` (or `lemonade-server` as a fallback) in the background via `nohup`, then polls until the endpoint responds up to 10 attempts, 2 seconds apart. Logs go to `/tmp/lemonade-server.log`.

### Step 7 — Model selection

Calls `lemonade list` to retrieve all known models and their download status. Displays an interactive arrow-key menu in the terminal showing each model's name, backend, and whether it has already been downloaded.

<p align="center">
  <img width="300" height="300" alt="image" src="https://github.com/user-attachments/assets/7bc4463c-a4c6-4bfd-9b4b-f024d5ae2ecb" />
</p>

- If only one model is available it is selected automatically.
- If the chosen model has not been downloaded yet, you are offered the option to `lemonade pull` it before continuing (this can take a while for large GGUF files).
- The model can be pre-selected non-interactively via `OPENCLAW_LEMONADE_MODEL_ID`.

### Step 7b — Install OpenClaw

Sets `~/.npm-global` as the npm global prefix (so the binary lands in a user-writable location), then runs the official OpenClaw installer:

```bash
curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-prompt --no-onboard
```

Skipped if `openclaw` is already on `PATH`.

### Step 8 — Configure OpenClaw (non-interactive onboard)

Runs `openclaw onboard --non-interactive` to point OpenClaw at the local Lemonade server:

| Onboard flag | Value |
|---|---|
| `--mode` | `local` |
| `--custom-base-url` | `http://127.0.0.1:13305/api/v1` |
| `--custom-provider-id` | `lemonade` |
| `--custom-compatibility` | `openai` (Lemonade exposes an OpenAI-compatible API) |
| `--custom-api-key` | `lemonade` (placeholder; no real key needed) |
| `--custom-model-id` | the model selected in Step 7 |
| `--gateway-port` | `18789` |
| `--gateway-bind` | `loopback` |

Before running, the script backs up any existing `~/.openclaw/openclaw.json` to a timestamped `.bak` file. The step is skipped if the config already contains a `lemonade` provider entry for the selected model.

### Step 9 — Auto-tune configuration

Edits `~/.openclaw/openclaw.json` with Python to apply model-specific settings that the non-interactive onboard does not set:

- Sets the agent default model to `lemonade/<model-id>`
- Sets `contextTokens` to 190000
- Sets agent and subagent `maxConcurrent` values
- Sets `contextWindow`, `maxTokens`, and zero-cost pricing on the model entry
- Marks the model as having reasoning capability with `thinkingFormat: qwen`
- Configures memory-search embeddings to use `nomic-embed-text-v1-GGUF` via Lemonade's OpenAI-compatible `/api/v1/embeddings` endpoint (provider: `openai`)
- Sets the default browser profile to connect to Chrome via CDP on `http://127.0.0.1:9222`

### Step 9b — Install Google Chrome

OpenClaw can control a browser for web tasks. If no Chrome or Chromium binary is found, the script adds the Google Chrome APT repository and installs `google-chrome-stable`.

### Step 10 — Interactive onboard and hatch

Launches `openclaw onboard --auth-choice skip` interactively (reading from `/dev/tty`) so you can configure:

- The OpenClaw gateway (auth token, allowed origins)
- Hooks (shell commands that fire on agent events)
- Skills (custom agent capabilities)
- Notification channels

After that completes:

- A `TOOLS.md` file is written to `~/.openclaw/workspace/` documenting how the agent can use Chrome (CDP on port 9222) and noting the Lemonade backend.
- The memory search index is built with `openclaw memory index`.
- Chrome is launched in the background with `--remote-debugging-port=9222` and the OpenClaw dashboard URL is opened automatically.
- A second pass of `openclaw onboard` runs the hatching flow (the initial agent interaction experience).

### Step 11 — Start OpenClaw gateway (foreground)

Starts the OpenClaw gateway in the foreground:

```bash
openclaw gateway run --bind loopback --port 18789 --force
```

The gateway is the local HTTP server that the OpenClaw web UI and browser extension talk to. Keeping it in the foreground means the terminal session stays attached; use a terminal multiplexer (`tmux`, `screen`) or a separate terminal if you want to keep using the shell while the gateway runs.

<p align="center">
  <img width="600" height="600" alt="Screenshot from 2026-04-03 23-53-15" src="https://github.com/user-attachments/assets/7f67ffbc-edc5-44d3-ad5a-443f7f1cb0f9" />
</p>

---

## After Setup

Once the script finishes the gateway is running and Chrome has the dashboard open. To use OpenClaw again after a reboot:

1. Start Lemonade: `lemond`
2. Start the OpenClaw gateway: `openclaw gateway run --bind loopback --port 18789 --force`
3. Open the dashboard in Chrome (or run `openclaw dashboard`)
