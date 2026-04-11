# OpenClaw on a local Lemonade server

[OpenClaw](https://openclaw.ai/) is a personal AI assistant that can browse the web, manage files, run code, and orchestrate multi-step tasks on your behalf. By default it connects to cloud-hosted AI APIs, but you can run it entirely on your own hardware using [Lemonade Server](https://lemonade-server.ai/) as the local backend, no API keys, no cloud costs, no data leaving your machine.

This script automates the full end-to-end setup: it installs Lemonade Server from the official PPA, pulls an AI model, installs OpenClaw, and wires the two together so OpenClaw uses your local Lemonade instance as its inference backend.

---

## Prerequisites

- Ubuntu 24.04 (x86-64)
- Internet connection (for downloading packages and model weights)

---

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/meghsat/lemonclaw_bash/main/openclaw-lemonade-setup.sh | bash
```

### Environment overrides

All settings can be overridden via environment variables before running the script:

| Variable | Default | Description |
|---|---|---|
| `LEMONADE_BASE_URL` | `http://127.0.0.1:13305` | URL the Lemonade server listens on |
| `LEMONADE_PORT` | `13305` | Lemonade server port |
| `LEMONADE_MIN_CTX_SIZE` | `32768` | Minimum context window size configured on the server |
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

### Step 1 — Install Lemonade via PPA

Installs prerequisites (`software-properties-common`, `curl`, `python3`, `wget`), then adds the `ppa:lemonade-team/bleeding-edge` repository and installs `lemonade-server` via `apt`. Skipped if `lemonade` is already present on `PATH`.

### Step 2 — Start Lemonade Server

Pings `http://127.0.0.1:13305/api/v1/models` to check whether the server is already running. If not, launches `lemond` (or `lemonade-server` as a fallback) in the background via `nohup`, then polls until the endpoint responds — up to 10 attempts, 2 seconds apart. Logs go to `/tmp/lemonade-server.log`.

### Step 2b — Configure context size

Reads the current `ctx_size` from `lemonade config` and, if it is below `LEMONADE_MIN_CTX_SIZE` (default 32768), runs `lemonade config set ctx_size=<value>` to raise it. 

### Step 3 — Model selection

The script first recommends the **Qwen3.5-35B-A3B-Q4_K_M** model (~22 GB) with an interactive Yes/No prompt:

- **Yes: use the recommended model**: runs `lemonade import` with a JSON spec that registers the model (checkpoint, recipe, labels, size, and `ctx_size=32768`), then `lemonade pull` to download it.
- **No: choose a different model**: displays the full `lemonade list` output and shows an interactive arrow-key menu of all available models and their download status.

<p align="center">
  <img width="300" height="300" alt="image" src="https://github.com/user-attachments/assets/7bc4463c-a4c6-4bfd-9b4b-f024d5ae2ecb" />
</p>

- If only one model is available it is selected automatically.
- If the chosen model has not been downloaded yet, you are offered the option to `lemonade pull` it before continuing (this can take a while for large GGUF files).
- If switching to a different model than what was previously configured, the old model is unloaded first to free VRAM.
- The model can be pre-selected non-interactively via `OPENCLAW_LEMONADE_MODEL_ID`.

### Step 4 — Install OpenClaw

Sets `~/.npm-global` as the npm global prefix (so the binary lands in a user-writable location), then runs the official OpenClaw installer:

```bash
curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-prompt --no-onboard
```

Skipped if `openclaw` is already on `PATH`.

### Step 5 — Configure OpenClaw (non-interactive onboard)

Runs `openclaw onboard --non-interactive` to point OpenClaw at the local Lemonade server:

| Onboard flag | Value |
|---|---|
| `--mode` | `local` |
| `--custom-base-url` | `http://127.0.0.1:13305/api/v1` |
| `--custom-provider-id` | `lemonade` |
| `--custom-compatibility` | `openai` (Lemonade exposes an OpenAI-compatible API) |
| `--custom-api-key` | `lemonade` (placeholder; no real key needed) |
| `--custom-model-id` | the model selected in Step 3 |
| `--gateway-port` | `18789` |
| `--gateway-bind` | `loopback` |

Before running, the script backs up any existing `~/.openclaw/openclaw.json` to a timestamped `.bak` file. The step is skipped if the config already contains a `lemonade` provider entry for the selected model.

### Step 6 — Auto-tune configuration

Edits `~/.openclaw/openclaw.json` with Python to apply model-specific settings that the non-interactive onboard does not set:

- Sets the agent default model to `lemonade/<model-id>`
- Sets `contextTokens` to 190000
- Sets agent and subagent `maxConcurrent` values
- Sets `contextWindow`, `maxTokens`, zero-cost pricing, and `reasoning: true` on the model entry
- Configures memory-search embeddings to use `nomic-embed-text-v1-GGUF` via Lemonade's OpenAI-compatible `/api/v1/embeddings` endpoint (provider: `openai`)
- Sets the default browser profile to connect to Chrome via CDP on `http://127.0.0.1:9222`

### Step 6b — Install Google Chrome

OpenClaw can control a browser for web tasks. If no Chrome or Chromium binary is found, the script adds the Google Chrome APT repository and installs `google-chrome-stable`.

### Step 7 — Interactive onboard and hatch

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

### Step 8 — Start OpenClaw gateway (foreground)

Starts the OpenClaw gateway in the foreground:

```bash
openclaw gateway run --bind loopback --port 18789 --force
```

The gateway is the local HTTP server that the OpenClaw web UI and browser extension talk to.

<p align="center">
  <img width="600" height="600" alt="Screenshot from 2026-04-03 23-53-15" src="https://github.com/user-attachments/assets/7f67ffbc-edc5-44d3-ad5a-443f7f1cb0f9" />
</p>

---
