# AI Proxy Gateway

[![Bifrost](https://img.shields.io/badge/Powered%20by-Bifrost-FF6B35?style=for-the-badge)](https://github.com/maximhq/bifrost)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-D97757?style=for-the-badge&logo=anthropic&logoColor=white)](https://claude.com/product/claude-code)
[![NVIDIA NIM](https://img.shields.io/badge/Backend-NVIDIA%20NIM-76B900?style=for-the-badge&logo=nvidia&logoColor=white)](https://build.nvidia.com/explore/discover)
[![Docker](https://img.shields.io/badge/docker-%230db7ed.svg?style=for-the-badge&logo=docker&logoColor=white)](https://www.docker.com/)

A proxy gateway that routes Claude Code through **Bifrost** (Go, ~11µs overhead, Redis caching) to multiple backend providers.

Provider and model configuration is kept in sync with the sibling `litellm-proxy/` gateway — same upstreams, same models, same API keys.

---

## Features

- **Single proxy**: Bifrost (Go, fast, Redis semantic caching)
- **Multi-provider routing**: NVIDIA NIM, Agnes, Sensenova, AMD Radeon, Gemini through a single endpoint
- **Load balancing**: NVIDIA and Gemini each have 2 API keys with per-key retry rotation
- **Docker Native**: Official images, compose file ready
- **Secure**: Environment-based API key management

---

## Project Structure

```
bifrost-proxy/
├── docker-compose.yml          # Active compose (Bifrost stack)
├── .env                        # API keys
├── .env.example
├── .gitignore
├── AGENTS.md
├── README.md
└── bifrost/
    └── config.json             # Bifrost provider config
```

---

## Prerequisites

- [Docker Desktop](https://docs.docker.com/get-docker/) or Docker Engine
- [Docker Compose](https://docs.docker.com/compose/install/)
- API keys for the backends you plan to use (see `.env.example`)

---

## Quick Start

### 1. Configure Environment

```bash
cp .env.example .env
# Edit .env and add your API keys
```

Required keys: `NVIDIA_API_KEY_1`, `NVIDIA_API_KEY_2`, `AGNES_API_KEY`, `SENSENOVA_API_KEY`, `AMD_API_KEY`, `GEMINI_API_KEY_1`, `GEMINI_API_KEY_2`, plus `BIFROST_VIRTUAL_KEY` (the virtual key Claude Code authenticates with).

### 2. Deploy

```bash
docker compose up -d
```

Proxy is now running at `http://localhost:4000`.

> **Port conflict:** the sibling `litellm-proxy/` gateway binds the same host port `4000`. Stop one before starting the other:
> `docker compose down` in the other directory. Bifrost is the active gateway right now; LiteLLM is stopped.

### 3. Verify

```bash
curl http://localhost:4000/v1/models
```

---

## Provider Configuration

### Bifrost — `bifrost/config.json`

| Provider  | Timeout | Models                                                                            | Keys                    |
| :-------- | :------ | :-------------------------------------------------------------------------------- | :---------------------- |
| nvidia    | 180s    | `nvidia/nemotron-3.5-super-vl-120b-a12b`, `nvidia/nemotron-3.5-lightning-30b-a3b` | 2 keys, weight 1.0 each |
| agnes     | 180s    | `agnes-2.5-flash`                                                                 | 1 key, weight 1.0       |
| sensenova | 180s    | `sensenova-6.8-flash-lite`                                                        | 1 key, weight 1.0       |
| amd       | 180s    | `Qwen3.8-27B`, `Qwen3.8-Flash-Next`                                               | 1 key, weight 1.0       |
| gemini    | 180s    | `gemini-3.5-flash-lite`, `gemini-3.1-flash-lite`                                  | 2 keys, weight 1.0 each |

**Request format:** `<provider>/<model>` (e.g. `nvidia/nvidia/nemotron-3.5-lightning-30b-a3b`, `agnes/agnes-2.5-flash`, `sensenova/sensenova-6.8-flash-lite`, `amd/Qwen3.8-Flash-Next`, `gemini/gemini-3.5-flash-lite`). Claude Code uses aliases rewritten by `governance.routing_rules` (sonnet rotates across agnes/sensenova/amd; all aliases have gemini fallbacks).

**Images:** `maximhq/bifrost:v2.3.2`, `redis/redis-stack-server:7.4.0-v8`.

---

## Using with Claude Code

Claude Code is routed to Bifrost through `~/.claude/settings.json` (`ANTHROPIC_BASE_URL=http://localhost:4000/anthropic`) and `~/.zprofile`:

```bash
export ANTHROPIC_AUTH_TOKEN=<same value as BIFROST_VIRTUAL_KEY in .env>
export ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5-5
export ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5
export ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-5-5
export ANTHROPIC_DEFAULT_FABLE_MODEL=claude-fable-5-1
export CLAUDE_CODE_SUBAGENT_MODEL=claude-haiku-5-5
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000
```

After editing, `source ~/.zprofile` or open a new shell before running `claude`.

Authentication matters here: without `ANTHROPIC_AUTH_TOKEN` matching the virtual key, requests bypass governance and the configured rate limits are not enforced.

---

## Reference

| Action           | Command                                       |
| :--------------- | :-------------------------------------------- |
| **Start**        | `docker compose up -d`                        |
| **Stop**         | `docker compose down`                         |
| **View Logs**    | `docker compose logs -f`                      |
| **Restart**      | `docker compose restart`                      |
| **Update**       | `docker compose pull && docker compose up -d` |
| **Models Check** | `curl http://localhost:4000/v1/models`        |

---

## License

MIT
