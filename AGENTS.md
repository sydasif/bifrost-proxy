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

**Images:** `maximhq/bifrost:v2.3.2`, `redis/redis-stack-server:7.4.0-v8`

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
- **Port conflict:** Bifrost and LiteLLM both bind host port `4000`. Only one gateway can run at a time — stop the other before starting this one. **Bifrost is currently the active gateway; LiteLLM is stopped.**
- Custom provider base_urls omit `/v1` (Bifrost appends it): `https://integrate.api.nvidia.com`, `https://apihub.agnes-ai.com`, `https://token.sensenova.ai`, `https://developer.amd.com.cn/radeon`.
- NVIDIA model names are sent as-is — they must match the exact NVIDIA API model ID (`nvidia/nemotron-3.5-super-vl-120b-a12b`). Short names like `nemotron-3.5-super-vl` will be rejected.
- `gemini` is a native Bifrost provider (not an OpenAI-compatible custom one); no `base_url` is set, so it uses Google's default endpoint.
- Redis must be healthy before Bifrost starts — crashes immediately if Redis isn't ready.
- Semantic caching: exact-match only, opt-in via `x-bf-cache-key` header.
- Health check is TCP socket (`nc -z`) — no quota burn.

### Authentication (required for governance + rate limits)

Bifrost validates the `Authorization: Bearer` header against virtual keys. Requests **without** a token bypass governance entirely — which also means the virtual key rate limits below are **not enforced**.

- The virtual key value is pinned in `config.json` as `env.BIFROST_VIRTUAL_KEY` (defined in `.env`). Without this, Bifrost regenerates the value on every start and the client token stops matching.
- `ANTHROPIC_AUTH_TOKEN` (in `~/.zprofile`) must equal `BIFROST_VIRTUAL_KEY` from `.env`.
- Each provider config carries `"key_ids": ["*"]`. Without it, governance resolves an empty key set for the provider config and every authenticated request fails with `no keys found for provider: <name> and model: <model>`.
- Rate limits live in `governance.rate_limits` and are referenced by `rate_limit_id`. An inline `rate_limit` object inside `provider_configs` is silently dropped (collapses into one empty-id limit that is attached to nothing).

### Resilience & Fallbacks

Bifrost provides three layers of fault tolerance:

- **Key rotation** (same provider): NVIDIA and Gemini have 2 API keys each. If one hits a rate limit or auth error, Bifrost rotates to the other key. Each key gets its own retry budget.
- **Cross-provider retries** (same model): Each provider is configured with `max_retries: 1`. Transient failures (5xx, network) retry on the same key with exponential backoff; per-key failures (429, 401, 403) rotate to the next key immediately.
- **Routing rules (alias + rotation + fallbacks):** `governance.routing_rules` maps Claude Code aliases to real providers and carries LiteLLM-equivalent gemini fallbacks.

| Alias              | Targets (weights)                                                                                     | Fallbacks                                                      |
| :----------------- | :---------------------------------------------------------------------------------------------------- | :------------------------------------------------------------- |
| `claude-sonnet-5`  | `agnes/agnes-2.5-flash` (0.34), `sensenova/sensenova-6.8-flash-lite` (0.33), `amd/Qwen3.8-27B` (0.33) | `gemini/gemini-3.5-flash-lite`, `gemini/gemini-3.1-flash-lite` |
| `claude-opus-5-5`  | `nvidia/nvidia/nemotron-3.5-super-vl-120b-a12b` (1.0)                                                 | `gemini/gemini-3.5-flash-lite`, `gemini/gemini-3.1-flash-lite` |
| `claude-haiku-5-5` | `nvidia/nvidia/nemotron-3.5-lightning-30b-a3b` (1.0)                                                  | `gemini/gemini-3.5-flash-lite`, `gemini/gemini-3.1-flash-lite` |
| `claude-fable-5-1` | `amd/Qwen3.8-Flash-Next` (1.0)                                                                        | `gemini/gemini-3.5-flash-lite`, `gemini/gemini-3.1-flash-lite` |

Routing rules load from `config.json` and run before governance provider selection. Weights must sum to 1; rules are evaluated by scope/priority (global, priority 0/10/20/30). Config changes require `docker compose down && up -d`.

### Claude Code Wiring — `~/.zprofile` + `~/.claude/settings.json`

Claude Code is routed to **Bifrost** (active gateway on `:4000`):

| Setting                                          | Value                                      |
| ------------------------------------------------ | ------------------------------------------ |
| `ANTHROPIC_BASE_URL` (`~/.claude/settings.json`) | `http://localhost:4000/anthropic`          |
| `ANTHROPIC_AUTH_TOKEN` (`~/.zprofile`)           | must equal `BIFROST_VIRTUAL_KEY` in `.env` |
| `ANTHROPIC_DEFAULT_OPUS_MODEL`                   | `claude-opus-5-5`                          |
| `ANTHROPIC_DEFAULT_SONNET_MODEL`                 | `claude-sonnet-5`                          |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL`                  | `claude-haiku-5-5`                         |
| `ANTHROPIC_DEFAULT_FABLE_MODEL`                  | `claude-fable-5-1`                         |
| `CLAUDE_CODE_SUBAGENT_MODEL`                     | `claude-haiku-5-5`                         |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW`                | `200000`                                   |

`/anthropic` is required: Bifrost's Anthropic drop-in lives at `http://localhost:4000/anthropic/v1/messages`.

**Known limitations:**

- `POST /anthropic/v1/messages/count_tokens` is not supported for the custom (OpenAI-compatible) providers — it returns `400 count_tokens is not supported by <provider> provider`. Claude Code tolerates this and continues.
- Claude Code does not recognize gateway model IDs, so it assumes a 200k context window and prints `[claude-code:unrecognized_model]`. `CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000` makes that explicit.

### Switching back to LiteLLM

```bash
cd /home/zulu/bifrost-proxy && docker compose down
cd /home/zulu/litellm-proxy && docker compose up -d
```

The aliases in `~/.zprofile` are now identical to LiteLLM. Only restore `ANTHROPIC_AUTH_TOKEN` to the LiteLLM master key and set `ANTHROPIC_BASE_URL` back to `http://localhost:4000` in `~/.claude/settings.json`.

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
