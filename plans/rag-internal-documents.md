# Internal Document Embeddings & RAG

Plan for indexing and querying internal documents on the Team AI stack.

**Status:** Planned (discussed during model download; implement after core stack is healthy)

---

## Architecture

```
Internal docs (Markdown, PDF, text)
        │
        ▼
┌─────────────────────────────────────────┐
│  Open WebUI                             │
│  • Chunk text (CHUNK_SIZE / OVERLAP)    │
│  • Hybrid search (BM25 + vector)        │
│  • Vector store (open-webui-data vol)   │
└──────────────┬──────────────────────────┘
               │ embed each chunk
               ▼
┌─────────────────────────────────────────┐
│  Ollama (CPU) — nomic-embed-text        │
│  No GPU — vLLM keeps the A6000          │
└─────────────────────────────────────────┘
               │
               ▼
User chat in Open WebUI
        │
        ▼
LiteLLM → vLLM (Gemma 4) answers using retrieved chunks
```

| Setting | Default | Where |
|---------|---------|-------|
| Embedding model | `nomic-embed-text` | `docker-compose.yml` |
| Chunk size | 1500 chars | `CHUNK_SIZE` |
| Chunk overlap | 100 chars | `CHUNK_OVERLAP` |
| Chunks retrieved | 5 | `RAG_TOP_K` |
| Search mode | Hybrid (keyword + semantic) | `ENABLE_RAG_HYBRID_SEARCH=true` |

**Key design choice:** Ollama runs on **CPU only** so embeddings do not compete with vLLM on the A6000. RAG is available in **Open WebUI chat**, not automatically in VS Code / Roo Code / LiteLLM API unless a separate retrieval layer is built.

---

## Prerequisites

1. Stack running and healthy (`docker compose ps`)
2. `ollama-init` completed:

   ```bash
   docker compose logs ollama-init
   # "Embedding model ready."
   ```

3. Verify Ollama:

   ```bash
   docker compose exec ollama curl -s http://localhost:11434/api/tags | head
   ```

4. Test embedding (optional):

   ```bash
   docker compose exec ollama curl -s http://localhost:11434/api/embeddings \
     -d '{"model":"nomic-embed-text","prompt":"Team AI onboarding guide"}' | head -c 200
   ```

---

## Recommended workflow

### 1. Prepare documents

**Do embed:**
- Engineering handbooks, API standards, runbooks
- Architecture decision records (ADRs)
- Internal wiki exports (Markdown preferred)
- Onboarding guides, release procedures

**Do not embed:**
- Credentials, API keys, `.env` files
- Raw customer exports or regulated PII
- Huge uncurated repo snapshots
- Stale docs you would not trust a new hire to read

| Format | Quality | Notes |
|--------|---------|-------|
| Markdown (`.md`) | Best | Clear headings help chunking |
| Plain text | Good | Use `#` headings for structure |
| PDF | OK | Tables/code may chunk poorly |
| Source code trees | Poor fit | Use Roo Code / grep for code |

**Example runbook** (`docs/runbooks/deploy-staging.md`):

```markdown
# Deploy to Staging

## Prerequisites
- VPN connected
- `kubectl` context: `staging`

## Steps
1. Run `./scripts/deploy.sh staging`
2. Verify health: `curl https://staging.internal/health`
3. Notify #platform in Slack

## Rollback
If deploy fails, run `./scripts/rollback.sh staging`.
```

### 2. Create Knowledge collections

In Open WebUI (http://127.0.0.1:8080 or SSH tunnel):

1. **Workspace → Knowledge** → **+ New Collection**
2. Name clearly: `Platform Runbooks`, `API Standards`, `Onboarding`
3. Add description and named owner
4. Upload files

**Suggested starter collections:**

| Collection | Owner | Contents |
|------------|-------|----------|
| `engineering-handbook` | Platform lead | Git workflow, review standards |
| `api-standards` | API team | REST conventions, error formats |
| `runbooks` | On-call | Incident, deploy, rollback |
| `onboarding` | New-hire buddy | Accounts, VPN, tools |
| `product-faq` | PM | Internal product decisions |

### 3. Chat with knowledge attached

1. New chat → model **gemma-4-31b**
2. Attach knowledge collection
3. Ask specific questions with expected sources

**Good:** "According to our API standards, what HTTP status for validation errors?"

**Weak:** "Tell me about the project" (too vague; RAG won't see your live repo)

---

## Tuning

Edit `docker-compose.yml` under `open-webui`, then `docker compose up -d open-webui`.

| Variable | Increase when | Decrease when |
|----------|---------------|---------------|
| `CHUNK_SIZE` | Long coherent sections | Code snippets, Q&A |
| `CHUNK_OVERLAP` | Answers span boundaries | Repetitive docs |
| `RAG_TOP_K` | Complex multi-part questions | Irrelevant chunks in answers |

**Example profiles:**

```yaml
# Dense reference (API specs)
CHUNK_SIZE: "1000"
CHUNK_OVERLAP: "150"
RAG_TOP_K: "8"

# Narrative runbooks (default)
CHUNK_SIZE: "1500"
CHUNK_OVERLAP: "100"
RAG_TOP_K: "5"

# Short FAQ
CHUNK_SIZE: "800"
CHUNK_OVERLAP: "50"
RAG_TOP_K: "3"
```

---

## Bulk ingest

- **Pilot:** UI upload, 5–20 files per collection
- **Larger sets:** Export wiki to Markdown, upload in batches (~20 files)
- Monitor: `docker compose logs -f open-webui` and `docker stats ai-ollama`

---

## Content governance

| Practice | Why |
|----------|-----|
| Named owner per collection | Updates when wiki changes |
| Monthly review of top collections | Stale RAG erodes trust |
| Version in filename | `api-standards-2025-06.md` |
| Remove superseded files | Avoid duplicate conflicting chunks |
| Classification | Internal only — not regulated data unless policy allows |

Presidio redacts PII in API traffic; still do not upload secrets or customer data into collections.

---

## Quality testing

Before rollout, 5–10 questions per collection with known answers:

| Question | Expected source | Pass? |
|----------|-----------------|-------|
| LiteLLM port? | engineering-handbook | |
| Staging rollback command? | runbooks/deploy-staging.md | |
| Validation error HTTP code? | api-standards | |

**Bad-answer report template:**

```
Prompt:
Expected answer:
Actual answer:
Collection:
Chunks cited:
Doc version / date:
```

---

## Operations

| Task | Action |
|------|--------|
| Backup vectors | `./scripts/backup.sh` (includes `open-webui-data`, `ollama-data`) |
| Refresh docs | Remove old file in collection → upload new version → re-test |
| Slow ingest | Normal on CPU; avoid multi-GB uploads at once |
| Wrong answers | Usually stale docs or bad chunks — not model failure |

```bash
docker compose logs open-webui | grep -i rag
docker compose logs ollama | tail -50
```

---

## Out of scope (this stack)

| Use case | Alternative |
|----------|-------------|
| IDE codebase search | Roo Code grep; future MCP + index |
| Live Confluence sync | Scheduled Markdown export |
| Multi-tenant isolation | Admin-managed collections; separate stacks if needed |

---

## Future upgrades

| Stage | Change |
|-------|--------|
| Now | Open WebUI + Ollama CPU + `nomic-embed-text` |
| Better recall | Test `mxbai-embed-large` or `nomic-embed-text-v1.5` |
| Larger corpus | External vector DB (Qdrant, pgvector) + ingest pipeline |
| Code-aware RAG | MCP server with repo index on dev machines |

To switch embedding model: update `ollama-init` pull + `RAG_EMBEDDING_MODEL`, then re-embed collections.

---

## Checklist

- [ ] Core stack healthy; Ollama embedding model pulled
- [ ] Create 3–5 starter collections with named owners
- [ ] Upload curated Markdown docs (no secrets/PII)
- [ ] Run quality test questions per collection
- [ ] Enable `scripts/backup.sh` cron for `open-webui-data`
- [ ] Publish internal user guide: how to attach knowledge in chat

See also: [README §10.4](../README.md), [README §11.4](../README.md).
