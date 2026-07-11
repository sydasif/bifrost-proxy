# AGENTS.md

**Role:** Proxy Gateway Operator
**Mandate:** Deploy and maintain the Bifrost proxy gateway for Claude Code.

---

## Quick Reference

```bash
docker compose up -d                # Start (detached)
docker compose down                  # Stop
docker compose logs -f              # Tail logs
docker compose restart               # Restart services
curl http://localhost:4000/         # Health / models check
docker compose pull && docker compose up -d  # Update image + restart
```

---

## Provider Configuration

### Bifrost — `bifrost/config.json`

| Provider | Timeout | Models                                                     | Keys                    |
| :------- | :------ | :--------------------------------------------------------- | :---------------------- |
| opencode | 120s    | `mimo-v2.5-free`                                           | 1 key, weight 1.0       |
| nvidia   | 120s    | `openai/gpt-oss-120b`, `nvidia/nemotron-3-ultra-550b-a55b` | 2 keys, weight 1.0 each |
| agnes    | 120s    | `agnes-2.0-flash`                                          | 1 key, weight 1.0       |

**Request format:** `<provider>/<model>` (e.g. `nvidia/openai/gpt-oss-120b`, `opencode/mimo-v2.5-free`, `agnes/agnes-2.0-flash`).

**Gotchas:**

- Config is mounted read-only (`:ro`). Edit then `docker compose down && up -d` (not restart).
- OpenCode base_url: `https://opencode.ai/zen` (no `/v1` — Bifrost appends it internally).
- NVIDIA base_url: `https://integrate.api.nvidia.com` (no `/v1` — Bifrost appends it internally). The model name after `nvidia/` is sent as-is — it must match the exact NVIDIA API model ID (`openai/gpt-oss-120b`, `nvidia/nemotron-3-ultra-550b-a55b`). Short names like `gpt-oss-120b` will likely be rejected.
- Redis must be healthy before Bifrost starts — crashes immediately if Redis isn't ready.
- Semantic caching: exact-match only, opt-in via `x-bf-cache-key` header.
- Health check is TCP socket (`nc -z`) — no quota burn.

### Resilience & Fallbacks

Bifrost provides two layers of fault tolerance:

- **Key rotation** (same provider): NVIDIA has 2 API keys. If one hits a rate limit or auth error, Bifrost rotates to the other key. Each key gets its own retry budget.
- **Cross-provider retries** (same model): Each provider is configured with `max_retries: 1`. Transient failures (5xx, network) retry on the same key with exponential backoff; per-key failures (429, 401, 403) rotate to the next key immediately.

**Note:** Bifrost fallbacks are provider-level (same model on different provider), not model-level (different model on different provider) like LiteLLM. If you need model-level fallback (e.g. `nvidia/openai/gpt-oss-120b` → `agnes/agnes-2.0-flash`), the client must send a `fallbacks` array in the request body:

```json
{
  "model": "nvidia/openai/gpt-oss-120b",
  "fallbacks": ["agnes/agnes-2.0-flash"]
}
```

### .profile Values

| Variable                         | Value                                      |
| -------------------------------- | ------------------------------------------ |
| `ANTHROPIC_BASE_URL`             | `http://localhost:4000/anthropic`          |
| `ANTHROPIC_DEFAULT_OPUS_MODEL`   | `nvidia/nvidia/nemotron-3-ultra-550b-a55b` |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | `opencode/mimo-v2.5-free`                  |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL`  | `nvidia/openai/gpt-oss-120b`               |

---

## Failure Handling

| Symptom                   | Fix                                                                    |
| ------------------------- | ---------------------------------------------------------------------- |
| `address already in use`  | `docker ps` — leftover containers on port 4000                         |
| `401` / `Invalid API key` | Verify the required keys are set in `.env`                             |
| Service won't start       | `docker compose logs -f` — check startup logs                          |
| `model not found`         | Update model names in the active config file                           |
| Config not applied        | `docker compose down && up -d` (not restart) — config loads at startup |

---

## Stop & Ask

Escalate if: (1) backend API quota exceeded (`429`), (2) Docker daemon unavailable, (3) Claude Code still can't see the model after config change.
