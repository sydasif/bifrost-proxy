# AI Proxy Gateway

[![Bifrost](https://img.shields.io/badge/Powered%20by-Bifrost-FF6B35?style=for-the-badge)](https://github.com/maximhq/bifrost)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-D97757?style=for-the-badge&logo=anthropic&logoColor=white)](https://claude.com/product/claude-code)
[![OpenCode Zen](https://img.shields.io/badge/Backend-OpenCode%20Zen-6C47FF?style=for-the-badge)](https://opencode.ai)
[![Google Gemini](https://img.shields.io/badge/Backend-Google%20Gemini-4285F4?style=for-the-badge&logo=google&logoColor=white)](https://deepmind.google/technologies/gemini/)
[![Docker](https://img.shields.io/badge/docker-%230db7ed.svg?style=for-the-badge&logo=docker&logoColor=white)](https://www.docker.com/)

A proxy gateway that routes Claude Code through **Bifrost** (Go, ~11µs overhead, Redis caching) to multiple backend providers.

---

## Features

- **Single proxy**: Bifrost (Go, fast, Redis semantic caching)
- **Multi-provider routing**: OpenCode, Gemini, Agnes through a single endpoint
- **Load balancing**: Multiple API keys per provider (e.g. 2 Gemini keys)
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

Required keys: `OPENCODE_API_KEY`, `GEMINI_API_KEY_1`, `GEMINI_API_KEY_2`, `AGNES_API_KEY`.

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

| Provider | Timeout | Models                                            | Keys                             |
| :------- | :------ | :------------------------------------------------ | :------------------------------- |
| opencode | 300s    | `nemotron-3-ultra-free`, `deepseek-v4-flash-free` | 1 key, weight 1.0                |
| gemini   | 120s    | `gemma-4-31b-it`                                  | 2 keys, load-balanced (0.5 each) |
| agnes    | 180s    | `agnes-2.0-flash`                                 | 1 key, weight 1.0                |

**Request format:** `<provider>/<model>` (e.g. `opencode/nemotron-3-ultra-free`).

---

## Using with Claude Code

The proxy URL and model names for Bifrost. Set these in `~/.profile` (or equivalent):

### Bifrost (Current)

```bash
export ANTHROPIC_BASE_URL=http://localhost:4000/anthropic
export ANTHROPIC_DEFAULT_OPUS_MODEL=opencode/nemotron-3-ultra-free
export ANTHROPIC_DEFAULT_SONNET_MODEL=gemini/gemma-4-31b-it
export ANTHROPIC_DEFAULT_HAIKU_MODEL=opencode/deepseek-v4-flash-free
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
