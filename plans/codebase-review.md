# Codebase Review — Team AI Stack

Initial review from the implementation planning conversation (June 2025).

**Conclusion:** Mature **Docker Compose deployment kit** with strong documentation. Technical stack is largely complete; remaining work is operator configuration and organizational rollout—not missing application code.

---

## Purpose

Self-hosted AI platform for ~50 users on a single **NVIDIA RTX A6000 (48 GB)** GPU. Infrastructure-as-config: upstream Docker images orchestrated by Compose.

```
Team laptops → SSH tunnel / Tailscale
    → Open WebUI (:8080) → LiteLLM (:4000) → vLLM (:8000) → Gemma 4 31B QAT
    → RAG via Ollama (CPU embeddings)
    → Prometheus/Grafana/Loki + optional Langfuse
```

---

## Components

### Core (`docker-compose.yml`) — 14 services

| Service | State | Notes |
|---------|-------|-------|
| vllm | Ready | GPU; tool calling (`gemma4` parser); internal only |
| postgres | Ready | LiteLLM key/usage DB |
| litellm | Ready | Auth, rate limits, Presidio; `127.0.0.1:4000` |
| open-webui | Ready | Chat + RAG; `127.0.0.1:8080` |
| ollama + ollama-init | Ready | CPU `nomic-embed-text` |
| presidio-analyzer/anonymizer | Ready | PII redaction |
| dcgm-exporter | Ready | GPU metrics |
| prometheus, alertmanager, grafana | Ready | Monitoring; alert receivers need config |
| loki, promtail | Ready | 7-day log retention |

### Optional (`docker-compose.observability.yml`, profile `observability`)

Langfuse + backing stores for agent tracing.

### Scripts

| Script | Purpose |
|--------|---------|
| `install-systemd.sh` | Boot persistence |
| `install-backup-cron.sh` | Nightly backups |
| `backup.sh` | Postgres, WebUI, Ollama volumes |
| `issue-user-key.sh` | Per-user LiteLLM keys |
| `check-capacity.sh` | GPU/queue health JSON |
| `load-test.sh` / `load-test.py` | Concurrency load test |

---

## Ready vs operator action

### Ready in repo

- Pinned images, health checks, localhost-only bindings
- LiteLLM routing + Presidio guardrails
- Grafana **Team AI Overview** dashboard
- RAG wiring (Ollama embeddings)
- vLLM tool-calling for Roo Code
- README Phases 1–11

### Requires operator setup

| Item | Gap |
|------|-----|
| `.env` secrets | Must generate before prod |
| Hugging Face token | Required for Gemma 4 |
| SSO/OAuth | Wired but empty by default |
| Alert notifications | Slack/email commented out in Alertmanager |
| Langfuse keys | Empty until project created |
| Capacity banner cron | Example only in README |

### Documented but not in repo (Phase 11)

- Acceptable use policy, data classification
- Team user guide (separate from admin README)
- Onboarding/offboarding runbooks
- Curated RAG collections, `.roo` templates
- Incident runbook, staging environment

### Explicitly out of scope

- Kubernetes / Terraform / CI/CD
- Multi-GPU HA, fine-tuning pipeline
- Cursor as first-class client (use VS Code + Continue/Roo Code)
- In-stack TLS / reverse proxy

---

## Server readiness (planning time)

| Check | Result |
|-------|--------|
| GPU | NVIDIA RTX A6000, 49140 MiB |
| Docker GPU | Verified via `nvidia/cuda` container |
| Docker Compose | v5.1.4 |
| `.env` | Not yet created |

---

## Backup scope

`backup.sh` covers: `postgres-data`, `open-webui-data`, `ollama-data`.

Not backed up: `huggingface-cache`, prometheus/grafana/loki data (HF cache re-downloadable).

---

## Recommended next steps

1. [deploy-team-ai-stack.md](deploy-team-ai-stack.md) — core deployment
2. [rag-internal-documents.md](rag-internal-documents.md) — after stack healthy
3. Phase 11 org deliverables when approaching team rollout

**Historical note:** [`cursor_vscode_compatibility_with_self_h.md`](../cursor_vscode_compatibility_with_self_h.md) records earlier gap analysis; most listed gaps (DCGM, backups, RAG, pinned tags) are now implemented.
