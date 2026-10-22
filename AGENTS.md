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

Mirrors `litellm-proxy/litellm/config.yaml` — same upstreams, same models, same keys.

| Provider  | Timeout | Models                                                                            | Keys                    |
| :-------- | :------ | :-------------------------------------------------------------------------------- | :---------------------- |
| nvidia    | 180s    | `nvidia/nemotron-3.5-super-vl-120b-a12b`, `nvidia/nemotron-3.5-lightning-30b-a3b` | 2 keys, weight 1.0 each |
| agnes     | 180s    | `agnes-2.5-flash`                                                                 | 1 key, weight 1.0       |
| sensenova | 180s    | `sensenova-6.8-flash-lite`                                                        | 1 key, weight 1.0       |
| amd       | 180s    | `Qwen3.8-27B`, `Qwen3.8-Flash-Next`                                               | 1 key, weight 1.0       |
| gemini    | 180s    | `gemini-3.5-flash-lite`, `gemini-3.1-flash-lite`                                  | 2 keys, weight 1.0 each |

**Request format:** `<provider>/<model>` (e.g. `nvidia/nvidia/nemotron-3.5-lightning-30b-a3b`, `agnes/agnes-2.5-flash`, `sensenova/sensenova-6.8-flash-lite`, `amd/Qwen3.8-Flash-Next`, `gemini/gemini-3.5-flash-lite`).

**Gotchas:**

- Config is mounted read-only (`:ro`). Edit then `docker compose down && up -d` (not restart).
- **Port conflict:** Bifrost and LiteLLM both bind host port `4000`. Only one gateway can run at a time — stop the other before starting this one.
- Custom provider base_urls omit `/v1` (Bifrost appends it): `https://integrate.api.nvidia.com`, `https://apihub.agnes-ai.com`, `https://token.sensenova.ai`, `https://developer.amd.com.cn/radeon`.
- NVIDIA model names are sent as-is — they must match the exact NVIDIA API model ID (`nvidia/nemotron-3.5-super-vl-120b-a12b`). Short names like `nemotron-3.5-super-vl` will be rejected.
- `gemini` is a native Bifrost provider (not an OpenAI-compatible custom one); no `base_url` is set, so it uses Google's default endpoint.
- Redis must be healthy before Bifrost starts — crashes immediately if Redis isn't ready.
- Semantic caching: exact-match only, opt-in via `x-bf-cache-key` header.
- Health check is TCP socket (`nc -z`) — no quota burn.

### Resilience & Fallbacks

Bifrost provides two layers of fault tolerance:

- **Key rotation** (same provider): NVIDIA and Gemini have 2 API keys each. If one hits a rate limit or auth error, Bifrost rotates to the other key. Each key gets its own retry budget.
- **Cross-provider retries** (same model): Each provider is configured with `max_retries: 1`. Transient failures (5xx, network) retry on the same key with exponential backoff; per-key failures (429, 401, 403) rotate to the next key immediately.

**Note:** Bifrost fallbacks are provider-level (same model on different provider), not model-level (different model on different provider) like LiteLLM. LiteLLM falls back `claude-*` → `gemini-3.5-flash-lite` → `gemini-3.1-flash-lite`; Bifrost has no config-level equivalent, so the client must send a `fallbacks` array in the request body:

```json
{
  "model": "nvidia/nvidia/nemotron-3.5-super-vl-120b-a12b",
  "fallbacks": ["gemini/gemini-3.5-flash-lite", "gemini/gemini-3.1-flash-lite"]
}
```

### Claude Code Wiring — `~/.zprofile`

Claude Code currently points at **LiteLLM** (aliases, not Bifrost provider/model strings):

| Variable                         | Value                                             |
| -------------------------------- | ------------------------------------------------- |
| `ANTHROPIC_BASE_URL`             | `http://localhost:4000` (`.claude/settings.json`) |
| `ANTHROPIC_DEFAULT_OPUS_MODEL`   | `claude-opus-5-5`                                 |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | `claude-sonnet-5`                                 |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL`  | `claude-haiku-5-5`                                |
| `ANTHROPIC_DEFAULT_FABLE_MODEL`  | `claude-fable-5-1`                                |
| `CLAUDE_CODE_SUBAGENT_MODEL`     | `claude-haiku-5-5`                                |

To serve Claude Code from Bifrost instead, stop LiteLLM (`docker compose down` in `litellm-proxy/`), start Bifrost, and use the Bifrost-native model names:

```bash
export ANTHROPIC_BASE_URL=http://localhost:4000/anthropic
export ANTHROPIC_DEFAULT_OPUS_MODEL=nvidia/nvidia/nemotron-3.5-super-vl-120b-a12b
export ANTHROPIC_DEFAULT_SONNET_MODEL=agnes/agnes-2.5-flash
export ANTHROPIC_DEFAULT_HAIKU_MODEL=nvidia/nvidia/nemotron-3.5-lightning-30b-a3b
export ANTHROPIC_DEFAULT_FABLE_MODEL=amd/Qwen3.8-Flash-Next
export CLAUDE_CODE_SUBAGENT_MODEL=nvidia/nvidia/nemotron-3.5-lightning-30b-a3b
```

---

## Failure Handling

| Symptom                   | Fix                                                                    |
| ------------------------- | ---------------------------------------------------------------------- |
| `address already in use`  | `docker ps` — LiteLLM or a leftover container on port 4000             |
| `401` / `Invalid API key` | Verify the required keys are set in `.env`                             |
| Service won't start       | `docker compose logs -f` — check startup logs                          |
| `model not found`         | Update model names in the active config file                           |
| Config not applied        | `docker compose down && up -d` (not restart) — config loads at startup |

---

## Stop & Ask

Escalate if: (1) backend API quota exceeded (`429`), (2) Docker daemon unavailable, (3) Claude Code still can't see the model after config change.
