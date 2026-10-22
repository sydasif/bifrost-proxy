# AGENTS.md

**Role:** Proxy Gateway Operator
**Mandate:** Deploy and maintain the Bifrost proxy gateway for Claude Code.

---

## Quick Reference

```bash
docker compose up -d                # Start (detached)
docker compose down                  # Stop (keeps data)
docker compose logs -f              # Tail logs
curl http://localhost:4000/         # Health / models check
docker compose pull && docker compose up -d  # Update image + restart
./tests/edge-cases.sh --static      # Config/env consistency (no network, no tokens)
./tests/edge-cases.sh               # Auth + validation edge cases (no upstream calls)
./tests/edge-cases.sh --full        # + routing, streaming, cache, 200KB/unicode payloads
```

**Images:** `maximhq/bifrost:v2.3.2`, `redis/redis-stack-server:7.4.0-v8`
**Dashboard:** `http://localhost:4000` (login = `BIFROST_ADMIN_USERNAME` / `BIFROST_ADMIN_PASSWORD` from `.env`)

> **Never run `docker compose down -v`.** It deletes the named volumes and wipes dashboard history, admin config, and the Redis cache. `down` (no `-v`) is safe.

---

## Data & Persistence

`/app/data` is the named volume `bifrost-proxy_bifrost_data` (not the container layer, not an anonymous volume). It holds:

| File        | Contents                                                            |
| :---------- | :------------------------------------------------------------------ |
| `config.db` | providers, virtual keys, routing rules, governance, client settings |
| `logs.db`   | dashboard request history (LLM logs, MCP logs, async jobs)          |
| `logs/`     | rotated/archived log files                                          |

- Data survives `docker compose down && up -d` and image upgrades.
- `bifrost/config.json` is a read-only bind **inside** the volume mount — it overlays `/app/data/config.json` and is the declarative source of truth for providers/routing/auth.
- If the volume is ever lost: `docker compose up` recreates it empty (fresh DB, empty dashboard), then `config.json` re-seeds providers/routing on boot.
- `client.log_retention_days: 30` bounds `logs.db` growth (roughly 10–40KB per logged request with content logging on; ~120 test requests produced a 1.4MB `logs.db` plus WAL). Without it Bifrost keeps history forever; the DB previously reported 365 while the file config loaded 0 — an unset key is config drift.
- Prompt/response content **is** persisted (`input_history`, `raw_request`, `raw_response`) because `disable_content_logging` is unset. Set `client.disable_content_logging: true` if you do not want source code sitting in `logs.db`.
- Backup: `docker run --rm -v bifrost-proxy_bifrost_data:/src:ro -v "$PWD":/out alpine tar czf /out/bifrost-data-$(date +%F).tgz -C /src .`

**Why this exists:** the earlier compose file had no mount for `/app/data`. Docker created an anonymous volume per container, so every `down`/`up` silently started from a fresh DB — that is what erased the dashboard history.

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
- Redis is a **disposable cache**: persistence is disabled (`--appendonly no --save ""`), so there are no fsync/AOF-rewrite stalls and no disk growth. Restarting Redis loses cached responses only (10m TTL); Bifrost state is in `/app/data`.
- Redis must be healthy before Bifrost starts (`depends_on: service_healthy`). If Redis dies **at runtime**, Bifrost stays up and keeps serving: the cache plugin degrades silently, adding ~3.5s of overhead per cache-eligible request, and `is_cache_connected` still reports `true`. Restarting Redis restores caching immediately.
- Semantic caching runs in **direct (exact-hash) mode** (`dimension: 1`, no embedding provider). `default_cache_key: "claude-code"` makes every request cache-eligible, so hits no longer require the `x-bf-cache-key` header. `conversation_history_threshold: 50` means conversations longer than 50 messages bypass the cache entirely. Cache hits replay in ~2ms vs ~500ms upstream.
- Health check is TCP socket (`nc -z`) — no quota burn.

### Authentication (dashboard + inference)

Two independent layers, both configured declaratively in `config.json`:

| Layer              | Setting                                   | Effect                                                        |
| :----------------- | :---------------------------------------- | :------------------------------------------------------------ |
| Dashboard / `/api` | `governance.auth_config.is_enabled: true` | Username+password login; `/api/*` requires a session          |
| Inference          | `client.enforce_auth_on_inference: true`  | `/v1/*` and `/anthropic/*` require a credential (401 without) |

- The admin account is declared as `admin_username: env.BIFROST_ADMIN_USERNAME` / `admin_password: env.BIFROST_ADMIN_PASSWORD`. **Do not create it through the UI** — `config.json` is mounted `:ro`, so a UI-created account lives only in memory and disappears on the next restart. Declaring it in config makes it persist.
- `setup_token` (`env.BIFROST_SETUP_TOKEN`) is the bootstrap fallback: `POST /api/session/setup` with header `X-Bifrost-Setup-Token` creates the first admin when config declares none.
- The virtual key is still accepted for inference as `Authorization: Bearer <VK>` even with dashboard auth on. Claude Code only sends that header, so this is what keeps it working.
- The virtual key value is pinned in `config.json` as `env.BIFROST_VIRTUAL_KEY` (defined in `.env`). Without this, Bifrost regenerates the value on every start and the client token stops matching.
- `ANTHROPIC_AUTH_TOKEN` (in `~/.zprofile`) must equal `BIFROST_VIRTUAL_KEY` from `.env`.
- Each provider config carries `"key_ids": ["*"]`. Without it, governance resolves an empty key set for the provider config and every authenticated request fails with `no keys found for provider: <name> and model: <model>`.
- Rate limits live in `governance.rate_limits` and are referenced by `rate_limit_id`. An inline `rate_limit` object inside `provider_configs` is silently dropped (collapses into one empty-id limit that is attached to nothing).
- **A governance 429 is final — it does not fall back.** The limiter runs before routing, so a sonnet request routed to an exhausted provider returns `429 rate_limit_error` to the client even when the other two rotation targets are idle. Keep limits well above real usage (currently 60/min for agnes/sensenova/amd, 120/min for nvidia/gemini). Upstream 429s are different: those rotate keys and fall back, so they are self-healing.

Login endpoint: `POST /api/session/login` with `{"username": "...", "password": "..."}` (sets a session cookie). Sessions live in the DB, so they survive container restarts.

### Resilience & Fallbacks

Bifrost provides three layers of fault tolerance:

- **Key rotation** (same provider): NVIDIA and Gemini have 2 API keys each. If one hits a rate limit or auth error, Bifrost rotates to the other key. Each key gets its own retry budget.
- **Cross-provider retries** (same model): `max_retries: 1` only on the two multi-key providers (nvidia, gemini), where a retry can reach the other key. The single-key providers (agnes, sensenova, amd) run `max_retries: 0`: retrying the same rate-limited key only burns ~500ms of backoff. Measured on a throttled agnes: **0.84s → 0.18s** per 429. Transient failures (5xx, network) retry on the same key with exponential backoff; per-key failures (429, 401, 403) rotate to the next key immediately.
- **Routing rules (alias + rotation + fallbacks):** `governance.routing_rules` maps Claude Code aliases to real providers and carries LiteLLM-equivalent gemini fallbacks.

| Alias              | Targets (weights)                                                                                     | Fallbacks                                                      |
| :----------------- | :---------------------------------------------------------------------------------------------------- | :------------------------------------------------------------- |
| `claude-sonnet-5`  | `agnes/agnes-2.5-flash` (0.34), `sensenova/sensenova-6.8-flash-lite` (0.33), `amd/Qwen3.8-27B` (0.33) | `gemini/gemini-3.5-flash-lite`, `gemini/gemini-3.1-flash-lite` |
| `claude-opus-5-5`  | `nvidia/nvidia/nemotron-3.5-super-vl-120b-a12b` (1.0)                                                 | `gemini/gemini-3.5-flash-lite`, `gemini/gemini-3.1-flash-lite` |
| `claude-haiku-5-5` | `nvidia/nvidia/nemotron-3.5-lightning-30b-a3b` (1.0)                                                  | `gemini/gemini-3.5-flash-lite`, `gemini/gemini-3.1-flash-lite` |
| `claude-fable-5-1` | `amd/Qwen3.8-Flash-Next` (1.0)                                                                        | `gemini/gemini-3.5-flash-lite`, `gemini/gemini-3.1-flash-lite` |

Routing rules load from `config.json` and run before governance provider selection. Weights must sum to 1; rules are evaluated by scope/priority (global, priority 0/10/20/30). Config changes require `docker compose down && up -d`.

**Fallback semantics (verified):** a broken or throttled upstream (401/429/5xx) on a routing-rule target transparently fails over to the next fallback — `X-Bifrost-Fallback-Index: 1` plus `X-Bifrost-Routing-Info-Is-Fallback: true` on the response. A governance/rate-limit rejection does not. Direct `<provider>/<model>` requests (bypassing a routing rule) have no fallback either — they surface the upstream error, and with `max_retries: 1` a throttled provider can stall for 25–80s before returning it.

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

- `POST /anthropic/v1/messages/count_tokens` is answered locally by Bifrost (returns `{"input_tokens": N}`), including for the custom OpenAI-compatible providers. It is an estimate, not a provider-exact count.
- Unknown routes (`/v1/nope`, `GET` on `/v1/chat/completions`) return the dashboard SPA HTML with `200`, not `404`/`405`. Clients that treat any 200 as success can be fooled; always check the `content-type`.
- Claude Code does not recognize gateway model IDs, so it assumes a 200k context window and prints `[claude-code:unrecognized_model]`. `CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000` makes that explicit.

### Switching back to LiteLLM

```bash
cd /home/zulu/bifrost-proxy && docker compose down
cd /home/zulu/litellm-proxy && docker compose up -d
```

The aliases in `~/.zprofile` are now identical to LiteLLM. Only restore `ANTHROPIC_AUTH_TOKEN` to the LiteLLM master key and set `ANTHROPIC_BASE_URL` back to `http://localhost:4000` in `~/.claude/settings.json`.

---

## Verification & Baselines

`tests/edge-cases.sh` is the regression gate. `--static` needs no server; the default mode exercises auth/validation; `--full` adds billed inference, routing, streaming, cache and payload checks. It exits non-zero on any failure.

Measured on this stack (2026-10-22, `maximhq/bifrost:v2.3.2`):

| Check                    | Result                                                                 |
| :----------------------- | :--------------------------------------------------------------------- |
| Gateway overhead (happy path) | p50 **1.9ms**, p90 11.5ms (n=85 logged requests); 2.5–10ms even at 12 concurrent |
| Gateway overhead (recovery)   | ~450–600ms per retry or fallback — bookkeeping, paid only when a provider fails |
| Streaming TTFB           | proxy 522–708ms vs direct upstream 487–648ms — indistinguishable, no added latency |
| Cached stream replay     | 2.6ms TTFB (cached SSE replayed chunk-by-chunk)                        |
| Exact-match cache hit    | 2.2ms vs 490ms upstream (~200x)                                        |
| Key rotation             | rotating across `nvidia-key-1`/`-2`; `X-Bifrost-Routing-Info-Key` shows the pick |
| Cross-provider fallback  | 6/12 sonnet calls hit a deliberately broken sensenova key; 6/6 served by gemini, all 200 |
| Restart persistence      | healthy in ~2s after `down && up -d`; logs, sessions and providers intact |
| Redis outage (runtime)   | no crash, inference still 200, +~3.5s per cache-eligible request        |
| Governance 429           | fails fast (~2ms), **no** fallback                                     |
| Throttled-provider 429   | 0.18s with `max_retries: 0` vs 0.84s with `1`                          |

Provider health under light load: nvidia ~0.4–3.5s and stable; amd 1–12s; agnes and sensenova hit free-tier upstream limits (`429 ... free users / tpm-rpm`) after roughly 9–10 requests in a minute, and sensenova stalled 25–78s before answering. Because alias routes fall back to gemini, those degrade to slower responses rather than errors. Direct `<provider>/<model>` calls surface the 429 after the stall.

---

## Failure Handling

| Symptom                        | Fix                                                                                                                                                                    |
| :----------------------------- | :--------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `address already in use`       | `docker ps` — LiteLLM or a leftover container on port 4000                                                                                                             |
| `401` / `Invalid API key`      | Verify the required keys are set in `.env`; for inference, send `Authorization: Bearer <VK>`                                                                           |
| Service won't start            | `docker compose logs -f` — check startup logs                                                                                                                          |
| `model not found`              | Update model names in the active config file                                                                                                                           |
| Config not applied             | `docker compose down && up -d` (not restart) — config loads at startup                                                                                                 |
| Dashboard asks for setup again | `governance.auth_config` missing from `config.json`, or admin was created only via the UI (not persisted)                                                              |
| Dashboard history empty        | Volume not mounted — check `docker inspect bifrost --format '{{range .Mounts}}{{.Name}} {{.Destination}}{{"\n"}}{{end}}'` shows `bifrost-proxy_bifrost_data /app/data` |
| `429 rate_limit_error` on some sonnet calls but not others | Governance limit hit before routing (no fallback). Check `request_max_limit` in `governance.rate_limits` and raise it |
| Sudden +3.5s on every request  | Redis down while Bifrost stays up — `docker compose ps redis`, restart it |
| Upstream `429 ... free users` / `tpm-rpm` | Provider quota, not Bifrost. Alias traffic falls back to gemini; direct provider calls do not |

---

## Stop & Ask

Escalate if: (1) backend API quota exceeded (`429`), (2) Docker daemon unavailable, (3) Claude Code still can't see the model after config change.
