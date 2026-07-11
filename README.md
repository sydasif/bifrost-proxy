# AI Proxy Gateway

[![Bifrost](https://img.shields.io/badge/Powered%20by-Bifrost-FF6B35?style=for-the-badge)](https://github.com/maximhq/bifrost)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-D97757?style=for-the-badge&logo=anthropic&logoColor=white)](https://claude.com/product/claude-code)
[![OpenCode Zen](https://img.shields.io/badge/Backend-OpenCode%20Zen-6C47FF?style=for-the-badge)](https://opencode.ai)
[![NVIDIA NIM](https://img.shields.io/badge/Backend-NVIDIA%20NIM-76B900?style=for-the-badge&logo=nvidia&logoColor=white)](https://build.nvidia.com/explore/discover)
[![Docker](https://img.shields.io/badge/docker-%230db7ed.svg?style=for-the-badge&logo=docker&logoColor=white)](https://www.docker.com/)

A proxy gateway that routes Claude Code through **Bifrost** (Go, ~11µs overhead, Redis caching) to multiple backend providers.

---

## Features

- **Single proxy**: Bifrost (Go, fast, Redis semantic caching)
- **Multi-provider routing**: NVIDIA NIM, OpenCode, Agnes through a single endpoint
- **Load balancing**: Two NVIDIA API keys with per-key retry rotation
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

Required keys: `NVIDIA_API_KEY_1`, `NVIDIA_API_KEY_2`, `OPENCODE_API_KEY`, `AGNES_API_KEY`.

### 2. Deploy

```bash
docker compose up -d
```

Proxy is now running at `http://localhost:4000`.

### 3. Verify

```bash
curl http://localhost:4000/v1/models
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

---

## Using with Claude Code

The proxy URL and model names for Bifrost. Set these in `~/.profile` (or equivalent):

### Bifrost (Current)

```bash
export ANTHROPIC_BASE_URL=http://localhost:4000/anthropic
export ANTHROPIC_DEFAULT_OPUS_MODEL=nvidia/nvidia/nemotron-3-ultra-550b-a55b
export ANTHROPIC_DEFAULT_SONNET_MODEL=opencode/mimo-v2.5-free
export ANTHROPIC_DEFAULT_HAIKU_MODEL=nvidia/openai/gpt-oss-120b
```

After editing, `source ~/.profile` or open a new shell before running `claude`.

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
