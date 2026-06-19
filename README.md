# Team AI Stack — Administrator Guide

Self-hosted AI platform for ~50 users on a single **NVIDIA RTX A6000 (48 GB)** GPU.

| Layer | Component | Purpose |
|---|---|---|
| Inference | [vLLM](https://github.com/vllm-project/vllm) | Serves Gemma 4 31B with continuous batching |
| API gateway | [LiteLLM](https://github.com/BerriAI/litellm) | Auth, rate limits, usage tracking, guardrails |
| Chat UI | [Open WebUI](https://github.com/open-webui/open-webui) | Team chat, RAG knowledge bases, SSO |
| Embeddings | [Ollama](https://ollama.com) (CPU) | RAG embedding model (`nomic-embed-text`) |
| Guardrails | [Presidio](https://github.com/microsoft/presidio) | PII detection/redaction on API requests |
| Monitoring | Prometheus + Grafana + Alertmanager | Metrics, dashboards, alerts |
| Logging | Loki + Promtail | Centralized container logs |
| Observability (optional) | [Langfuse](https://langfuse.com) | Agent/request tracing for IDE workflows |
| Model | `google/gemma-4-31B-it-qat-w4a16-ct` | Largest Gemma 4 that fits A6000 (QAT W4A16) |

All components are open source (Apache 2.0 / MIT / BSD).

---

## Architecture

```
Team laptops
    │
    ├── SSH tunnel or Tailscale VPN
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│  GPU server (localhost bindings only)                   │
│                                                         │
│  Open WebUI :8080 ──► LiteLLM :4000 ──► vLLM :8000      │
│       │                      │              │           │
│       └── RAG ──► Ollama (CPU embeddings)               │
│                              │              │           │
│                         PostgreSQL      A6000 GPU       │
│                         Presidio (PII)                  │
│                                                         │
│  Grafana :3000 ──► Prometheus ──► vLLM / LiteLLM / GPU  │
│                 └── Loki ◄── Promtail (container logs)  │
│  Alertmanager :9093                                     │
│  Langfuse :3101 (optional, --profile observability)     │
└─────────────────────────────────────────────────────────┘
```

**Security principle:** vLLM is never exposed to the network. Only Open WebUI (`8080`) and LiteLLM (`4000`) bind to `127.0.0.1`. Users reach them via SSH tunnel or VPN.

---

## Hardware requirements

| Resource | Minimum | Recommended |
|---|---|---|
| GPU | 1× RTX A6000 (48 GB) | Same |
| CPU | 8 cores | 16+ cores |
| RAM | 64 GB | 128 GB |
| Disk | 200 GB free SSD | 500 GB NVMe |
| OS | Ubuntu 22.04 or 24.04 LTS | Ubuntu 24.04 LTS |
| Network | 1 Gbps | 10 Gbps (internal) |

Expected capacity on A6000 with QAT 31B:

- **~15–25 concurrent chat sessions** (with default tuning)
- **~50 total users** with queuing and rate limits

---

## Repository layout

```
.
├── README.md                          # This file
├── docker-compose.yml                 # Full stack definition
├── docker-compose.observability.yml   # Optional Langfuse overlay
├── .env.example                       # Environment template
├── systemd/
│   └── team-ai.service                # Boot-time systemd unit template
├── scripts/
│   ├── install-systemd.sh             # Install and enable systemd service
│   ├── install-backup-cron.sh         # Install nightly backup cron job
│   ├── backup.sh                      # Backup Postgres + WebUI + Ollama volumes
│   ├── issue-user-key.sh              # Generate per-user LiteLLM API keys
│   ├── check-capacity.sh              # GPU/queue capacity status (JSON)
│   ├── load-test.sh                   # Concurrent load test wrapper
│   └── load-test.py                   # Load test implementation (Python stdlib)
└── config/
    ├── litellm/
    │   ├── config.yaml                # LiteLLM routing + guardrails
    │   └── config.observability.yaml  # LiteLLM + Langfuse callbacks
    ├── alertmanager/alertmanager.yml  # Alert routing (Slack/email hooks)
    ├── loki/loki.yml                  # Log storage
    ├── promtail/promtail.yml          # Docker log shipping
    ├── prometheus/
    │   ├── prometheus.yml             # Metrics scrape config
    │   └── alerts/team-ai.yml         # Alert rules
    └── grafana/provisioning/          # Datasources + dashboards
```

---

## Phase 1 — Server preparation

Run all commands as a user with `sudo` access on the GPU server.

### 1.1 Install NVIDIA driver

Verify the A6000 is visible:

```bash
nvidia-smi
```

You should see **RTX A6000** with **49140 MiB** (or similar). If not, install the latest production driver from NVIDIA for your Ubuntu version.

### 1.2 Install Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"
newgrp docker
```

### 1.3 Install NVIDIA Container Toolkit

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Verify GPU access inside Docker:

```bash
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

### 1.4 Install Hugging Face CLI (for model pre-download)

```bash
sudo apt-get install -y python3-pip git
pip3 install --user "huggingface_hub[cli]"
```

---

## Phase 2 — Hugging Face access

Gemma 4 requires accepting Google's license on Hugging Face.

1. Create a Hugging Face account: https://huggingface.co/join
2. Accept the license: https://huggingface.co/google/gemma-4-31B-it-qat-w4a16-ct
3. Create an access token: https://huggingface.co/settings/tokens (Read access is sufficient)

---

## Phase 3 — Deploy the stack

### 3.1 Clone or copy this directory to the server

```bash
sudo mkdir -p /opt/team-ai
sudo chown "$USER:$USER" /opt/team-ai
cd /opt/team-ai

# Copy the files from this repository into /opt/team-ai
```

### 3.2 Configure environment

```bash
cp .env.example .env
chmod 600 .env
```

Edit `.env` and set:

| Variable | Action |
|---|---|
| `HF_TOKEN` | Your Hugging Face read token |
| `LITELLM_MASTER_KEY` | Long random string, must start with `sk-` |
| `LITELLM_SALT_KEY` | Another long random string |
| `POSTGRES_PASSWORD` | Strong database password |
| `WEBUI_SECRET_KEY` | Random string for Open WebUI sessions |
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin password |

Generate secrets:

```bash
openssl rand -hex 32
```

### 3.3 Pre-download the model (recommended)

First run downloads ~20 GB. Pre-fetching avoids a long wait during container startup:

```bash
export HF_TOKEN="hf_your_token_here"

huggingface-cli download google/gemma-4-31B-it-qat-w4a16-ct \
  --local-dir /opt/team-ai/models/gemma-4-31b-qat \
  --local-dir-use-symlinks False
```

If you pre-download to a custom path, update `VLLM_MODEL` in `.env` to that local path and add a bind mount in `docker-compose.yml` under the vLLM service.

Default setup uses the Hugging Face cache volume and pulls automatically on first start.

### 3.4 Start the stack

```bash
cd /opt/team-ai
docker compose pull
docker compose up -d
```

First startup takes **10–20 minutes** while vLLM loads the model into GPU memory. Monitor progress:

```bash
docker compose logs -f vllm
```

Wait until you see `Application startup complete` or the health check passes:

```bash
docker compose ps
```

All services should show `healthy`.

### 3.5 Verify each layer

**vLLM (internal):**

```bash
docker compose exec litellm curl -s http://vllm:8000/v1/models | head
```

**LiteLLM:**

```bash
curl -s http://127.0.0.1:4000/v1/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

**End-to-end chat completion:**

```bash
curl -s http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-4-31b",
    "messages": [{"role": "user", "content": "Say hello in one sentence."}],
    "max_tokens": 64
  }'
```

**Open WebUI:**

Open http://127.0.0.1:8080 on the server (or via SSH tunnel — see Phase 5).

---

## Phase 4 — User and access management

### 4.1 Create the first Open WebUI admin

1. Open WebUI at http://127.0.0.1:8080
2. Register the first account — it becomes admin (`ENABLE_SIGNUP=false` blocks further self-registration)
3. Create accounts for team members via **Admin Panel → Users**

### 4.2 Issue LiteLLM API keys (for scripts/IDE integrations)

Generate a per-user or per-team key with rate limits:

```bash
curl -X POST 'http://127.0.0.1:4000/key/generate' \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "key_alias": "team-engineering",
    "models": ["gemma-4-31b"],
    "rpm_limit": 30,
    "tpm_limit": 100000,
    "max_budget": 1000
  }'
```

Suggested defaults for ~50 users:

| Limit | Value | Rationale |
|---|---|---|
| `rpm_limit` | 20–30 per key | Prevents one user monopolizing the GPU |
| `tpm_limit` | 100,000 | ~100K tokens/minute per key |
| `max_parallel_requests` | 3 | Limits concurrent streams per key |

Manage keys via LiteLLM UI at http://127.0.0.1:4000/ui (log in with master key).

### 4.3 Configure Open WebUI to use LiteLLM

This is pre-configured in `docker-compose.yml`:

- `OPENAI_API_BASE_URL=http://litellm:4000/v1`
- `DEFAULT_MODELS=gemma-4-31b`

Users select **gemma-4-31b** in the model dropdown.

### 4.4 VS Code and IDE integrations

LiteLLM exposes an **OpenAI-compatible API** at `/v1`. VS Code extensions that support a custom OpenAI base URL can use the same stack as Open WebUI — no extra services required.

```
VS Code extension  →  LiteLLM :4000/v1  →  vLLM  →  Gemma 4
```

**Prerequisites**

1. A per-user LiteLLM API key (see [4.2](#42-issue-litellm-api-keys-for-scriptside-integrations))
2. Network access to port `4000` via SSH tunnel or Tailscale (see [Phase 5](#phase-5--team-access-via-ssh))

**What works**

| Tool | Supported? | Notes |
|---|---|---|
| VS Code + **Continue** | Yes | Chat, autocomplete, inline edits |
| VS Code + **Cline** / **Roo Code** | Yes | Agent-style coding assistant |
| VS Code + **CodeGPT** | Yes | Chat with custom OpenAI endpoint |
| **GitHub Copilot** | No | Requires GitHub's service; not configurable to LiteLLM |
| **Cursor** | Separate product | Not covered here; use VS Code + an OpenAI-compatible extension |

**Step 1 — Forward the API port**

On the developer's laptop (same SSH session can also forward WebUI port `8080`):

```bash
ssh -N -L 4000:127.0.0.1:4000 user@gpu-server.example.com
```

With Tailscale, use the server's Tailscale IP instead of `localhost`, e.g. `http://100.x.x.x:4000/v1`.

**Step 2 — Verify connectivity**

```bash
curl -s http://localhost:4000/v1/models \
  -H "Authorization: Bearer sk-their-litellm-key"
```

You should see `gemma-4-31b` in the response.

**Step 3 — Configure an extension**

Use these values in any extension that asks for OpenAI settings:

| Setting | Value |
|---|---|
| API base URL | `http://localhost:4000/v1` |
| API key | Per-user LiteLLM key from [4.2](#42-issue-litellm-api-keys-for-scriptside-integrations) |
| Model | `gemma-4-31b` |

Optional shell exports (for CLI tools or extensions that read env vars):

```bash
export OPENAI_API_BASE=http://localhost:4000/v1
export OPENAI_API_KEY=sk-their-litellm-key
```

#### Continue (recommended)

1. Install the [Continue extension](https://marketplace.visualstudio.com/items?itemName=Continue.continue) in VS Code
2. Open the Continue config: Command Palette → **Continue: Open config.yaml**
3. Add a model entry (replace the API key). Continue reads keys from `config.yaml` or a `.env` file — not from shell exports in the integrated terminal:

```yaml
name: Team AI
version: 0.0.1
schema: v1

models:
  - name: Gemma 4 (team)
    provider: openai
    model: gemma-4-31b
    apiBase: http://localhost:4000/v1
    apiKey: sk-their-litellm-key
    roles:
      - chat
      - edit
```

4. Reload the VS Code window if prompted, select **Gemma 4 (team)** in the Continue model dropdown, and send a test prompt

#### Cline / Roo Code

1. Install **Cline** or **Roo Code** from the VS Code Marketplace
2. Open extension settings and choose **OpenAI Compatible** (or equivalent) as the provider
3. Set:
   - **Base URL:** `http://localhost:4000/v1`
   - **API key:** per-user LiteLLM key
   - **Model ID:** `gemma-4-31b`
4. Run a small edit or chat task to confirm responses stream back

For multi-step agent behavior (read files, run commands, apply edits), see [4.5](#45-agentic-coding-with-roo-code).

**Capacity and limits**

IDE traffic shares the same GPU and LiteLLM rate limits as chat users:

- Expect **~15–25 concurrent sessions** total on the A6000 (see [Hardware requirements](#hardware-requirements))
- Per-key limits from [4.2](#42-issue-litellm-api-keys-for-scriptside-integrations) apply (`rpm_limit`, `max_parallel_requests`)
- If IDE users see HTTP **429** errors, lower concurrency or raise limits in the LiteLLM admin UI

**Troubleshooting**

| Symptom | Check |
|---|---|
| Connection refused | SSH tunnel or Tailscale not running; confirm port `4000` is forwarded |
| HTTP 401 | Wrong or expired LiteLLM API key |
| HTTP 429 | Rate limit hit; wait or adjust key limits in LiteLLM UI |
| Model not found | Model name must be exactly `gemma-4-31b` |
| Slow responses | Normal under load; check Grafana and vLLM queue depth ([Phase 6](#phase-6--monitoring)) |

### 4.5 Agentic coding with Roo Code

Cursor-style **agentic** behavior — plan, call tools, observe results, repeat — requires three layers working together:

```
Roo Code (agent loop + built-in tools)
    →  LiteLLM :4000/v1  →  vLLM (tool calling enabled)  →  Gemma 4
         ↑
    .roo/rules/ + .roo/skills/ + MCP servers  (you provide)
```

Roo Code (recommended over plain chat extensions) runs an autonomous loop using **built-in tools** (read/write files, terminal, search, browser). You do not implement those tools yourself. You provide **rules** (always-on standards), **skills** (on-demand workflows), and **MCP servers** (external integrations).

#### Server requirement: enable tool calling

Gemma 4 supports native function calling via vLLM's `gemma4` parser. This stack enables it in `docker-compose.yml`:

```yaml
- --enable-auto-tool-choice
- --tool-call-parser gemma4
```

After deploying, verify tool calls return structured `tool_calls` (not raw `<|tool_call>` tokens in message content):

```bash
curl -s http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-4-31b",
    "messages": [{"role": "user", "content": "Use the calculator tool to compute 19 * 23."}],
    "tools": [{
      "type": "function",
      "function": {
        "name": "calculator",
        "description": "Evaluate a math expression",
        "parameters": {
          "type": "object",
          "properties": {"expr": {"type": "string"}},
          "required": ["expr"]
        }
      }
    }],
    "tool_choice": "auto"
  }'
```

If tool calling fails, confirm you are on a recent `vllm/vllm-openai` image with Gemma 4 support. Do **not** add `--reasoning-parser gemma4` alongside tool calling on the 31B model — it can break streaming tool parsing.

#### Install and connect Roo Code

1. Install [Roo Code](https://marketplace.visualstudio.com/items?itemName=RooVeterinaryInc.roo-cline) in VS Code
2. Forward port `4000` (see [4.4](#44-vs-code-and-ide-integrations))
3. In Roo Code settings, choose **OpenAI Compatible** as the provider:
   - **Base URL:** `http://localhost:4000/v1`
   - **API key:** per-user LiteLLM key
   - **Model ID:** `gemma-4-31b`
4. Use **Code** mode for autonomous edits; **Ask** mode for read-only questions; **Architect** mode for design-first work

Roo Code requires **native OpenAI-compatible tool calling**. Models without tool support cannot run the agent loop.

Suggested LiteLLM key limits for agent users (see [4.2](#42-issue-litellm-api-keys-for-scriptside-integrations)):

| Limit | Suggested value | Rationale |
|---|---|---|
| `max_parallel_requests` | `2–3` | Agent loops issue many sequential requests |
| `rpm_limit` | `20–30` | Prevents one agent session monopolizing the GPU |

#### Cursor concepts mapped to Roo Code

| Cursor | Roo Code equivalent | When it loads |
|---|---|---|
| Agent mode | **Code** mode | Autonomous edit + terminal loop |
| Rules | `.roo/rules/` or `~/.roo/rules/` | Always (part of system prompt) |
| Skills | `.roo/skills/*/SKILL.md` or `~/.roo/skills/` | On demand (via Roo's skill tool) |
| MCP servers | `.roo/mcp.json` or global MCP settings | When the agent calls an MCP tool |
| Ask / Plan | **Ask** / **Architect** modes | Read-only or design-first |

#### Rules — team standards (always on)

Add project rules so every agent session follows your conventions:

```
my-project/
└── .roo/
    └── rules/
        ├── general.md          # coding style, semver, commit policy
        └── api-design.md       # REST conventions, error handling
```

Global rules (all projects): `~/.roo/rules/`

Example `my-project/.roo/rules/general.md`:

```markdown
# Team standards

- Match existing code style; read surrounding files before editing
- Minimize scope — do not refactor unrelated code
- Run tests after changes; do not commit unless explicitly asked
- Use `gh` for GitHub operations when available
```

Mode-specific rules load only in that mode, e.g. `.roo/rules-code/`, `.roo/rules-architect/`.

#### Skills — specialized workflows (on demand)

Skills package multi-step procedures Roo loads when a task matches. Same format as Cursor `SKILL.md`:

```
my-project/
└── .roo/
    └── skills/
        └── pr-review/
            ├── SKILL.md
            └── checklist.md
```

Example `my-project/.roo/skills/pr-review/SKILL.md`:

```markdown
---
name: pr-review
description: Review pull requests using team standards. Use when reviewing PRs or code changes.
---

# PR Review

1. Read the diff and identify behavior changes
2. Check test coverage for changed logic
3. Verify API backward compatibility
4. Flag security issues (auth, input validation, secrets)
5. Summarize findings as blocking / non-blocking
```

Global skills: `~/.roo/skills/`. Project skills override global skills with the same name.

#### MCP — external tools and integrations

MCP (Model Context Protocol) servers extend Roo with GitHub, databases, internal APIs, and other services. Configure per-project in `.roo/mcp.json`:

```json
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "<user-token>"
      }
    }
  }
}
```

Common MCP servers teams add:

| Integration | Example server |
|---|---|
| GitHub (PRs, issues) | `@modelcontextprotocol/server-github` |
| Filesystem / docs | Custom MCP or community servers |
| Internal APIs | MCP server you build for your REST/gRPC services |

MCP servers run on the **developer's machine** (inside VS Code), not on the GPU server. Each user installs and authenticates their own MCP servers.

#### What Roo provides vs what you provide

| Provided by Roo Code | Provided by you |
|---|---|
| Agent loop (plan → act → observe) | Rules (team standards) |
| Read / write / diff files | Skills (specialized workflows) |
| Run terminal commands | MCP servers (GitHub, Jira, etc.) |
| Search workspace files | Custom modes and prompts |
| Browser automation (optional) | Per-user API keys and MCP credentials |

#### Limitations vs Cursor

| Feature | Self-hosted with Gemma 4 31B |
|---|---|
| Multi-step agent loop | Yes, with tool calling enabled |
| Rules + skills + MCP | Yes |
| Semantic codebase search | Weaker — Roo uses file/grep search unless you add an MCP index |
| Tool-calling reliability | Below frontier cloud models — expect more retries |
| Parallel subagents | No direct equivalent |
| GPU load | Agent loops are heavy — limit concurrent agent users |

#### Agent troubleshooting

| Symptom | Check |
|---|---|
| Agent never calls tools | Tool calling not enabled in vLLM; run the curl test above |
| Raw `<|tool_call>` tokens in chat | vLLM parser misconfigured or reasoning parser conflict |
| Tool calls but bad edits | Expected with 31B — tighten rules, use Architect mode first |
| HTTP 429 during agent tasks | Lower `max_parallel_requests` or raise key limits |
| MCP tool not found | MCP server not installed or `.roo/mcp.json` misconfigured locally |

---

## Phase 5 — Team access via SSH

Each user connects without exposing ports to the internet.

### Option A — SSH port forwarding (simple)

On the user's laptop:

```bash
ssh -N -L 8080:127.0.0.1:8080 -L 4000:127.0.0.1:4000 user@gpu-server.example.com
```

Then open http://localhost:8080 in the browser.

For API/IDE use:

```bash
export OPENAI_API_BASE=http://localhost:4000/v1
export OPENAI_API_KEY=sk-their-litellm-key
```

### Option B — Tailscale (recommended for 50 users)

1. Install Tailscale on the GPU server and each user device
2. Enable Tailscale SSH or serve Open WebUI on the Tailscale IP
3. Restrict access with Tailscale ACLs by team/group

Example ACL snippet:

```json
{
  "acls": [
    {
      "action": "accept",
      "src": ["group:engineering"],
      "dst": ["tag:ai-server:8080", "tag:ai-server:4000"]
    }
  ]
}
```

### Firewall on the GPU server

```bash
sudo ufw default deny incoming
sudo ufw allow OpenSSH
sudo ufw enable
```

Do **not** open ports 4000, 8080, or 8000 to the public internet.

---

## Phase 6 — Monitoring

### Grafana

1. SSH tunnel ports 3000 and 9093: `ssh -L 3000:127.0.0.1:3000 -L 9093:127.0.0.1:9093 user@gpu-server`
2. Open http://localhost:3000
3. Log in with credentials from `.env`
4. Open dashboard **Team AI Overview** (pre-provisioned)

Additional community dashboards:

- NVIDIA GPU detail: dashboard ID `12239` (DCGM metrics now scraped natively)

### Key metrics to watch

| Metric | Healthy range | Action if bad |
|---|---|---|
| GPU utilisation | 60–95% under load | Normal |
| vLLM queue depth | < 10 | Increase `max-num-seqs` or add rate limits |
| Time to first token (TTFT) | < 2s | Reduce `max-model-len` or concurrent users |
| OOM errors in vLLM logs | 0 | Lower `VLLM_MAX_MODEL_LEN` or `VLLM_GPU_MEMORY_UTILIZATION` |

### Logs

```bash
docker compose logs -f vllm
docker compose logs -f litellm
docker compose logs -f open-webui
```

---

## Phase 7 — Operations

### Start / stop / restart

```bash
cd /opt/team-ai

docker compose up -d          # start
docker compose down           # stop (keeps volumes)
docker compose restart vllm   # restart inference only
```

### Update containers

```bash
docker compose pull
docker compose up -d
```

Pin image tags in production instead of `:latest` once the stack is stable.

### Backup

Use the automated backup script (see [10.6](#106-automated-backups)):

```bash
./scripts/backup.sh
```

Manual one-off (Postgres only):

```bash
docker run --rm \
  -v team-ai_postgres-data:/data \
  -v /backups:/backup \
  alpine tar czf /backup/postgres-$(date +%F).tar.gz -C /data .
```

Model weights in `huggingface-cache` can be re-downloaded; backing them up saves bandwidth.

### Tuning for A6000

Edit `.env` and restart vLLM:

| Variable | Default | If OOM | If underutilised |
|---|---|---|---|
| `VLLM_MAX_MODEL_LEN` | `16384` | `8192` | `32768` |
| `VLLM_GPU_MEMORY_UTILIZATION` | `0.92` | `0.88` | `0.95` |
| `VLLM_MAX_NUM_SEQS` | `24` | `16` | `32` |

After changes:

```bash
docker compose up -d vllm
```

---

## Phase 8 — Boot-time startup (systemd)

Containers use `restart: unless-stopped`, but systemd ensures the full stack is brought up after a server reboot.

### 8.1 Install the service

From the stack directory on the GPU server:

```bash
chmod +x scripts/install-systemd.sh scripts/install-backup-cron.sh scripts/backup.sh \
  scripts/issue-user-key.sh scripts/check-capacity.sh scripts/load-test.sh scripts/load-test.py
sudo ./scripts/install-systemd.sh /opt/team-ai
```

The install script defaults to the repository directory if you omit the path.

### 8.2 Manage the service

```bash
sudo systemctl start team-ai       # start now
sudo systemctl status team-ai      # check state
sudo systemctl stop team-ai        # graceful shutdown
sudo systemctl restart team-ai     # restart stack
journalctl -u team-ai -f           # boot/start logs
```

On reboot, systemd runs `docker compose up -d`. vLLM may take **10–20 minutes** to become healthy while the model loads:

```bash
docker compose logs -f vllm
docker compose ps
```

### 8.3 Notes

- Set `COMPOSE_PROJECT_NAME=team-ai` in `.env` so volume names stay consistent across manual and systemd starts.
- First boot after install still requires a populated `.env` and accepted Hugging Face license.
- To change the install path later, re-run `install-systemd.sh` with the new directory.

---

## Phase 9 — Load testing (pre-rollout)

Run a concurrency test **before** giving access to the full team. The script fires parallel chat requests through LiteLLM and reports success rate, latency percentiles, and approximate tokens/sec.

### 9.1 Prerequisites

- Stack is up and healthy (`docker compose ps`)
- `.env` contains a valid `LITELLM_MASTER_KEY`

### 9.2 Run the default test

Simulates **8 concurrent users × 3 requests = 24 total requests** (typical burst for ~50-person team):

```bash
cd /opt/team-ai
./scripts/load-test.sh
```

### 9.3 Custom scenarios

```bash
# Heavier burst: 12 users, 5 requests each (60 total)
./scripts/load-test.sh --concurrency 12 --requests 5

# Measure time-to-first-token with streaming
./scripts/load-test.sh --stream

# Stress test (expect some queuing on A6000)
./scripts/load-test.sh --concurrency 16 --requests 4 --max-tokens 512
```

Environment overrides (also in `.env.example`):

| Variable | Default | Purpose |
|---|---|---|
| `LOAD_TEST_CONCURRENCY` | `8` | Parallel workers |
| `LOAD_TEST_REQUESTS_PER_WORKER` | `3` | Requests per worker |
| `LOAD_TEST_MAX_TOKENS` | `256` | Output length per request |
| `LOAD_TEST_TIMEOUT` | `180` | Per-request timeout (seconds) |

### 9.4 Acceptance criteria (A6000 + 31B QAT)

| Metric | Target | Action if failed |
|---|---|---|
| Success rate | ≥ 95% | Lower concurrency or tune vLLM (Phase 7) |
| p95 latency | ≤ 60s | Reduce `max_tokens` or `VLLM_MAX_NUM_SEQS` |
| HTTP 429 errors | 0 (unless testing rate limits) | Raise LiteLLM limits or reduce test concurrency |
| OOM in vLLM logs | 0 | Lower `VLLM_MAX_MODEL_LEN` |

Watch GPU utilisation during the test:

```bash
watch -n 1 nvidia-smi
```

Recommended test sequence before go-live:

1. `./scripts/load-test.sh` — baseline (8×3)
2. `./scripts/load-test.sh --concurrency 12 --requests 3` — peak burst
3. `./scripts/load-test.sh --stream` — TTFT check for chat UX

Exit code `0` means the script passed its built-in thresholds; `1` means review tuning before rollout.

---

## Phase 10 — Production hardening (monitoring, RAG, SSO, ops)

These components ship with the stack by default. Optional Langfuse tracing uses a Compose profile.

### 10.1 GPU metrics (DCGM Exporter)

Prometheus scrapes **NVIDIA DCGM Exporter** for GPU utilisation and VRAM metrics. The **Team AI Overview** dashboard in Grafana is pre-provisioned — no manual import required.

Verify metrics after startup:

```bash
curl -s http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=DCGM_FI_DEV_GPU_UTIL' | head
```

### 10.2 Alertmanager

Alert rules live in `config/prometheus/alerts/team-ai.yml`:

| Alert | Trigger |
|---|---|
| `VLLMDown` | vLLM unreachable for 2 minutes |
| `LiteLLMDown` | LiteLLM unreachable for 2 minutes |
| `GPUHighMemory` | VRAM above 95% for 5 minutes |
| `VLLMQueueHigh` | More than 10 queued requests for 5 minutes |
| `HighLiteLLMErrorRate` | More than 10 LiteLLM 5xx responses in 5 minutes |

View active alerts: http://127.0.0.1:9093 (via SSH tunnel).

Configure Slack or email in `config/alertmanager/alertmanager.yml`, then reload:

```bash
docker compose exec alertmanager kill -HUP 1
```

### 10.3 SSO / OAuth for Open WebUI

Enable SSO by setting provider credentials in `.env` and restarting WebUI:

```bash
ENABLE_OAUTH_SIGNUP=true
GOOGLE_CLIENT_ID=...
GOOGLE_CLIENT_SECRET=...
```

Supported providers (set one): **Google**, **GitHub**, **Microsoft**, or generic **OIDC** (`OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, `OPENID_PROVIDER_URL`).

With SSO enabled, disable manual signup remains the default (`ENABLE_SIGNUP=false`); users authenticate via your IdP. Create the first admin by signing in once, then promote via **Admin Panel → Users**.

### 10.4 RAG (internal documents)

Open WebUI RAG uses **Ollama on CPU** with `nomic-embed-text` — no GPU contention with vLLM.

On first startup, `ollama-init` pulls the embedding model automatically. In Open WebUI:

1. Open **Workspace → Documents** (or Knowledge)
2. Upload PDFs, Markdown, or text files
3. Start a chat and attach the knowledge collection

Tune chunking via `.env`: `CHUNK_SIZE`, `CHUNK_OVERLAP`, `RAG_TOP_K`.

### 10.5 Pinned container images

Images are pinned in `docker-compose.yml` (not `:latest`). After validating upgrades on a staging host:

```bash
docker compose pull
docker compose up -d
```

Override tags by editing the `x-image-tags` anchor block at the top of `docker-compose.yml`.

### 10.6 Automated backups

Back up Postgres, Open WebUI data, and Ollama embeddings:

```bash
chmod +x scripts/backup.sh scripts/install-backup-cron.sh
sudo ./scripts/backup.sh
```

Install nightly backups (default 03:00, retain 14 days):

```bash
sudo ./scripts/install-backup-cron.sh --dir /var/backups/team-ai
```

### 10.7 Centralized logging (Loki)

Grafana includes a **Loki** datasource. The Team AI Overview dashboard has a log panel for `vllm`, `litellm`, and `open-webui`.

Explore all logs in Grafana → **Explore** → Loki:

```logql
{service="vllm"} |= "error"
```

Logs are retained for 7 days (`config/loki/loki.yml`).

### 10.8 Per-user API keys and audit

Issue a tracked LiteLLM key per user:

```bash
./scripts/issue-user-key.sh --alias jane.doe
```

Users paste the key into:

- **Open WebUI:** Settings → Connections → OpenAI-compatible connection
- **VS Code / Roo Code:** provider settings (see [4.4](#44-vs-code-and-ide-integrations))

LiteLLM stores spend logs and prompts (`store_prompts_in_spend_logs: true`). Review usage at http://127.0.0.1:4000/ui.

### 10.9 Tailscale Serve (alternative to SSH tunnels)

Instead of per-user port forwarding, expose services on your tailnet with **Tailscale Serve**:

```bash
# On the GPU server (authenticated tailnet member)
sudo tailscale serve --bg --https=443 http://127.0.0.1:8080   # Open WebUI
sudo tailscale serve --bg --https=8443 http://127.0.0.1:4000   # LiteLLM API
sudo tailscale serve status
```

Users connect to `https://gpu-server.tailnet-name.ts.net` without local SSH tunnels. Combine with [Tailscale ACLs](#option-b--tailscale-recommended-for-50-users) to restrict access by group.

### 10.10 Guardrails (PII redaction)

LiteLLM runs **Presidio** pre-call guardrails on all API traffic. PII patterns (emails, phone numbers, etc.) are redacted before reaching vLLM.

Presidio services: `presidio-analyzer`, `presidio-anonymizer`. To disable, remove the `guardrails` block from `config/litellm/config.yaml` and restart LiteLLM.

### 10.11 Langfuse (optional agent observability)

For tracing Roo Code / agent sessions, enable the observability overlay:

```bash
docker compose -f docker-compose.yml -f docker-compose.observability.yml \
  --profile observability up -d
```

1. Open http://127.0.0.1:3101 and create a Langfuse project
2. Copy API keys into `.env` (`LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`)
3. Restart LiteLLM: `docker compose restart litellm`

LiteLLM switches to `config/litellm/config.observability.yaml` which enables Langfuse callbacks.

### 10.12 Capacity status

Check GPU load and service health:

```bash
./scripts/check-capacity.sh
```

Exit codes: `0` healthy, `1` busy (high VRAM or queue), `2` degraded (service down).

Optional: paste the `webui_banner` JSON from the script output into `.env` as `WEBUI_BANNERS` to warn users during high load. Automate with cron:

```bash
# Example: update banner every 5 minutes (requires jq)
*/5 * * * * /opt/team-ai/scripts/check-capacity.sh | jq -r '.webui_banner // empty'
```

---

## Phase 11 — Administrator deliverables

Phases 1–10 cover the **technical stack**. Phase 11 covers what admins must **provide around** the stack — policy, content, user education, and operational rhythm. Without these, teams get a GPU server, not a trusted internal service.

### 11.1 Governance (before wide rollout)

| Deliverable | Purpose |
|---|---|
| **Acceptable use policy** | What may be pasted into chat (code OK; customer PII, credentials, and regulated data not OK) |
| **Data classification guide** | Map internal labels (public / internal / confidential) to permitted tools |
| **Approved use cases** | Code assist, docs Q&A, drafting — explicitly not for legal, medical, or compliance decisions |
| **Escalation path** | Named owner, backup contact, and channel for outages or misuse |

Presidio redacts common PII patterns but is **not** a substitute for policy. State clearly that prompts may be logged (LiteLLM `store_prompts_in_spend_logs`) and retained per your log retention policy.

### 11.2 Identity and access operations

Beyond SSO configuration ([10.3](#103-sso--oauth-for-open-webui)):

| Task | Admin action |
|---|---|
| **IdP group mapping** | Tie Tailscale ACLs / SSO groups to who may access the stack (e.g. `group:engineering`) |
| **Onboarding** | SSO login → `./scripts/issue-user-key.sh --alias USER` → share user setup guide |
| **Offboarding** | Revoke IdP access, delete or rotate LiteLLM key, remove from Tailscale |
| **Key naming** | Use identifiable aliases (`jane.doe`, `team-platform`) — not generic test keys |
| **Rotation** | Review and rotate keys quarterly; immediately on departure |

### 11.3 End-user documentation

Publish a **team user guide** (1–2 pages) separate from this admin README. Minimum contents:

- How to connect (SSH tunnel vs [Tailscale Serve](#109-tailscale-serve-alternative-to-ssh-tunnels))
- Open WebUI: chat vs knowledge collections ([RAG](#104-rag-internal-documents))
- VS Code / Roo Code setup ([4.4](#44-vs-code-and-ide-integrations), [4.5](#45-agentic-coding-with-roo-code))
- Prompt tips for Gemma 4 31B (be specific, provide context, one task at a time)
- What to do when responses are slow ([capacity status](#1012-capacity-status))
- Where to report bad answers ([11.8](#118-feedback-and-improvement))

Host this on your internal wiki or in a shared repo — not only in the GPU server README.

### 11.4 RAG content strategy

Do not enable RAG and walk away. **Curate knowledge deliberately:**

| Deliverable | Examples |
|---|---|
| **Starter collections** | Engineering handbook, API standards, runbooks, architecture decision records |
| **Collection owners** | Named person who updates each collection when source docs change |
| **Inclusion rules** | Markdown/PDF only; no secrets, credentials, or raw customer exports |
| **Refresh cadence** | Monthly review of the top 5 most-used collections |

Stale or wrong RAG answers erode trust faster than having no RAG at all.

### 11.5 Shared developer assets

Provide a **team standards template** that engineers copy or submodule into projects:

```
team-ai-standards/
├── .roo/
│   ├── rules/              # coding standards, commit policy
│   └── skills/             # PR review, release, incident response
├── docs/
│   ├── user-guide.md
│   └── mcp-allowlist.md    # approved MCP servers
└── examples/
    └── roo-code.env.example
```

Also publish:

- **Approved MCP list** — which external tools devs may connect (e.g. GitHub MCP yes; unvetted npm MCPs no)
- **Starter Roo modes** — if the team uses custom Architect / Code prompts
- **Example IDE config** — Continue `config.yaml` snippet with placeholders, not real keys

See [4.5](#45-agentic-coding-with-roo-code) for rules, skills, and MCP layout.

### 11.6 Set expectations with users

Communicate openly before rollout — a single slide or all-hands note prevents most disappointment:

| Topic | Honest message |
|---|---|
| **vs ChatGPT / Cursor** | Strong for internal code and docs; below frontier cloud models; slower under load |
| **Concurrency** | ~15–25 active sessions on A6000 — not unlimited parallel agents |
| **Agents** | Roo Code works but needs more supervision and iteration than Cursor |
| **Hallucinations** | Always verify generated code, configs, shell commands, and citations |
| **Maintenance** | Planned windows for upgrades; vLLM reload after reboot takes 10–20 minutes |

### 11.7 Operations rhythm

| Cadence | Admin action |
|---|---|
| **Daily** | Glance at Grafana **Team AI Overview** or run `./scripts/check-capacity.sh` |
| **Weekly** | Review LiteLLM usage by key in Admin UI; flag one key dominating GPU time |
| **Monthly** | Test a [backup restore](#106-automated-backups); update RAG collections; review [alert](#102-alertmanager) history |
| **Quarterly** | [Load test](#phase-9--load-testing-pre-rollout) after tuning changes; review pinned image upgrades on staging |
| **Per upgrade** | Run `./scripts/load-test.sh` and the [tool-calling curl test](#45-agentic-coding-with-roo-code) before production |

Additional operational deliverables:

- **Staging host** — same stack on a tailnet `-staging` tag to validate image upgrades
- **Incident runbook** — OOM, vLLM stuck loading, LiteLLM 429 storm, disk full (see [Troubleshooting](#troubleshooting))
- **Status channel** — e.g. Slack `#team-ai-status`; post when `check-capacity.sh` exits busy or degraded
- **Maintenance comms** — announce reboots and compose pulls at least 24 hours ahead

### 11.8 Feedback and improvement

| Deliverable | Purpose |
|---|---|
| **Bad-answer report template** | Prompt, expected vs actual, model, RAG collection, IDE vs WebUI |
| **Office hours** | 30 minutes monthly for prompt tips and Roo Code help |
| **Usage review** | Peak hours, chat vs agent ratio, teams with zero adoption |
| **Tuning backlog** | Track requests for more GPU, longer context, second model, etc. |

Without a feedback channel, admins tune capacity and content blind.

### 11.9 Security and compliance

| Deliverable | Action |
|---|---|
| **Gemma license** | Legal review of [Google Gemma terms](https://ai.google.dev/gemma/terms) for your use case |
| **Log retention** | Define retention for LiteLLM spend logs and Loki (align with GDPR / internal policy) |
| **Usage monitoring** | Alert on anomalies — one key at 10× normal tokens, off-hours spikes |
| **Exposure audit** | Quarterly check: UFW, no public ports, Tailscale ACLs still correct |
| **Cloud escape hatch** | Document when teams may use commercial AI instead (e.g. external client confidential work) |

### 11.10 Administrator starter pack

Hand new operators this checklist before declaring the service “live”:

**Policy and people**

- [ ] Acceptable use policy published
- [ ] Data classification guide published
- [ ] Named service owner and escalation path
- [ ] Onboarding and offboarding runbooks written

**User-facing**

- [ ] Team user guide published (separate from this README)
- [ ] Expectations doc shared (quality, concurrency, maintenance)
- [ ] Feedback channel or form live

**Content and dev assets**

- [ ] 3–5 curated RAG collections with named owners
- [ ] Shared `.roo/rules` template repo available
- [ ] Approved MCP allowlist published

**Operations**

- [ ] Incident runbook and status comms channel ready
- [ ] Staging environment for upgrade testing (recommended)
- [ ] Monthly and quarterly ops cadence on calendar
- [ ] Legal/compliance sign-off on model license and log retention

---

## Troubleshooting

### vLLM fails with CUDA OOM

1. Lower `VLLM_MAX_MODEL_LEN` to `8192`
2. Lower `VLLM_MAX_NUM_SEQS` to `16`
3. Confirm no other process is using the GPU: `nvidia-smi`

### vLLM stuck on "Loading model weights"

- Check HF token: `docker compose logs vllm | grep -i "401\|403\|gated"`
- Confirm license accepted on Hugging Face
- Ensure disk has > 50 GB free: `df -h`

### LiteLLM cannot reach vLLM

```bash
docker compose exec litellm curl -v http://vllm:8000/health
```

If vLLM is unhealthy, wait for model load or check vLLM logs.

### Open WebUI shows "Connection error"

1. Confirm LiteLLM is healthy: `curl http://127.0.0.1:4000/health/liveliness`
2. Verify `OPENAI_API_KEY` in the Open WebUI container matches `LITELLM_MASTER_KEY`
3. Check LiteLLM logs for upstream errors

### Slow responses under team load

Expected on a single A6000 with 31B. Mitigations:

1. Tighten per-key `rpm_limit` in LiteLLM
2. Enable prefix caching (already on in `docker-compose.yml`)
3. Plan upgrade to A100 80 GB for BF16 quality and higher concurrency

### Prometheus shows "prometheus.yml is a directory"

This happens if the file was missing at first startup:

```bash
docker compose down
rm -rf config/prometheus/prometheus.yml   # if it became a directory
git checkout config/prometheus/prometheus.yml
docker compose up -d
```

---

## Upgrade path

| Stage | Hardware | Model | When |
|---|---|---|---|
| **Now** | 1× A6000 | 31B QAT W4A16 | Pilot and production for ≤50 users |
| **Next** | 1× A100 80 GB | 31B BF16 | Better quality, more KV cache headroom |
| **Scale** | 2× A100 80 GB | 31B BF16 + LiteLLM load balancing | >25 concurrent users |
| **Future** | DGX | Multiple models + fine-tuning | RAG pipelines, training, HA |

To add a second vLLM instance later, duplicate the `vllm` service in `docker-compose.yml` with a second GPU and add both backends to `config/litellm/config.yaml`.

---

## Quick reference

| Service | URL (on server) | Purpose |
|---|---|---|
| Open WebUI | http://127.0.0.1:8080 | Team chat + RAG |
| LiteLLM API | http://127.0.0.1:4000/v1 | OpenAI-compatible API |
| LiteLLM Admin UI | http://127.0.0.1:4000/ui | Keys, usage, limits |
| Grafana | http://127.0.0.1:3000 | Dashboards + logs |
| Prometheus | http://127.0.0.1:9090 | Metrics (admin) |
| Alertmanager | http://127.0.0.1:9093 | Alerts (admin) |
| Langfuse | http://127.0.0.1:3101 | Agent tracing (optional) |
| vLLM | internal only (`vllm:8000`) | Inference engine |

| Command | Action |
|---|---|
| `docker compose up -d` | Start stack |
| `docker compose down` | Stop stack |
| `docker compose logs -f vllm` | Watch model loading |
| `docker compose ps` | Check health |
| `nvidia-smi` | GPU status |
| `sudo systemctl start team-ai` | Start stack via systemd |
| `./scripts/load-test.sh` | Run concurrency load test |
| `./scripts/backup.sh` | Backup volumes |
| `./scripts/issue-user-key.sh --alias USER` | Issue per-user API key |
| `./scripts/check-capacity.sh` | Check GPU capacity / health |

---

## License notes

- **Gemma 4**: Apache 2.0 — review [Google's Gemma terms](https://ai.google.dev/gemma/terms) for your use case
- **Stack components**: See each project's license (all permissive open source)

---

## Support checklist for new administrators

Complete [Phase 11 starter pack](#1110-administrator-starter-pack) before declaring the service live.

- [ ] `nvidia-smi` shows A6000
- [ ] Docker GPU test passes
- [ ] Hugging Face license accepted
- [ ] `.env` secrets set and file mode `600`
- [ ] `docker compose up -d` — all services healthy
- [ ] Test chat completion via curl succeeds
- [ ] Open WebUI admin account created
- [ ] Team access via SSH tunnel or Tailscale verified
- [ ] LiteLLM API keys issued with rate limits
- [ ] VS Code + Continue (or similar) tested against LiteLLM API
- [ ] vLLM tool calling verified (curl test in [4.5](#45-agentic-coding-with-roo-code))
- [ ] Roo Code agent loop tested with project `.roo/rules/`
- [ ] Grafana **Team AI Overview** dashboard visible
- [ ] Alertmanager reachable and alert rules loaded
- [ ] SSO configured (or manual user provisioning documented)
- [ ] RAG tested with a sample document upload
- [ ] `./scripts/backup.sh` succeeds; cron installed via `install-backup-cron.sh`
- [ ] `./scripts/issue-user-key.sh` tested; per-user usage visible in LiteLLM UI
- [ ] `./scripts/check-capacity.sh` returns healthy under normal load
- [ ] Presidio guardrails active (PII redaction)
- [ ] Langfuse enabled if using Roo Code agents at scale (optional)
- [ ] `sudo ./scripts/install-systemd.sh` — stack starts on boot
- [ ] `./scripts/load-test.sh` passes (≥95% success, p95 ≤60s)
