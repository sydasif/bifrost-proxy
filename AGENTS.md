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

| Provider | Timeout | Models                                            | Keys              |
| :------- | :------ | :------------------------------------------------ | :---------------- |
| opencode | 180s    | `nemotron-3-ultra-free`, `deepseek-v4-flash-free` | 1 key, weight 1.0 |
| agnes    | 180s    | `agnes-2.0-flash`                                 | 1 key, weight 1.0 |

**Request format:** `<provider>/<model>` (e.g. `opencode/nemotron-3-ultra-free`, `agnes/agnes-2.0-flash`).

**Gotchas:**

- Config is mounted read-only (`:ro`). Edit then `docker compose down && up -d` (not restart).
- OpenCode base_url: `https://opencode.ai/zen` (no `/v1` — Bifrost appends it internally).
- Redis must be healthy before Bifrost starts — crashes immediately if Redis isn't ready.
- Semantic caching: exact-match only, opt-in via `x-bf-cache-key` header.
- Health check is TCP socket (`nc -z`) — no quota burn.

### .profile Values

| Variable                         | Value                             |
| -------------------------------- | --------------------------------- |
| `ANTHROPIC_BASE_URL`             | `http://localhost:4000/anthropic` |
| `ANTHROPIC_DEFAULT_OPUS_MODEL`   | `opencode/nemotron-3-ultra-free`  |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | `agnes/agnes-2.0-flash`           |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL`  | `opencode/deepseek-v4-flash-free` |

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
