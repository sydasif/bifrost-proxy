# 🚀 Bifrost Proxy

[![Docker](https://img.shields.io/badge/docker-%230db7ed.svg?style=for-the-badge&logo=docker&logoColor=white)](https://www.docker.com/)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-D97757?style=for-the-badge&logo=anthropic&logoColor=white)](https://claude.com/product/claude-code)
[![OpenCode](https://img.shields.io/badge/OpenCode-007ACC?style=for-the-badge)](https://opencode.ai)
[![Google Gemini](https://img.shields.io/badge/Backend-Google%20Gemini-4285F4?style=for-the-badge&logo=google&logoColor=white)](https://deepmind.google/technologies/gemini/)

A lightweight deployment of the Bifrost Proxy, managed via Docker Compose for instant setup and persistence.

---

## ✨ Features

- 🐳 **Docker Native**: Uses the official Bifrost image, no build step required.
- 💾 **Persistent Storage**: Automatic data persistence via Docker volumes.
- ⚡ **Instant Deployment**: Single-command setup for rapid environment spin-up.

---

## 📂 Project Structure

```text
bifrost-proxy/
├── app/
│   └── data/             # Persistent proxy data and logs
├── docker-compose.yml    # Deployment configuration
└── CLAUDE.md             # Guidance for Claude Code
```

---

## 📋 Prerequisites

Before you begin, ensure you have the following installed:

- [Docker Desktop](https://docs.docker.com/get-docker/) or Docker Engine
- [Docker Compose](https://docs.docker.com/compose/install/)

---

## 🚀 Quick Start

### 1. Deploy Proxy

```bash
docker compose up -d
```

The Bifrost Proxy is now running and accessible at `http://localhost:8080`.

---

## 🤖 Using with OpenCode

To redirect `opencode` to your local proxy, update your global `opencode.json` file:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "bifrost": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Bifrost",
      "options": {
        "baseURL": "http://localhost:8080/v1"
      },
      "models": {
        "gemini/gemma-4-31b-it": {
          "name": "Gemma-4-31b"
        },
        "gemini/gemma-4-26b-a4b-it": {
          "name": "Gemma-4-26b"
        },
        "gemini/gemini-3.1-flash-lite-preview": {
          "name": "Gemini-3.1-flash-lite"
        }
      }
    }
  }
}
```

---

## 🤖 Using with Claude Code

To redirect `claude` to your local proxy, update your global `settings.json` file:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:8080/",
    "ANTHROPIC_AUTH_TOKEN": "sk-xxx",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "gemini/gemma-4-31b-it",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "gemini/gemini-3.1-flash-lite-preview",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "gemini/gemma-4-26b-a4b-it"
  }
}
```

---

## 🔧 Configuration

### Port Customization

If you need to change the external port, modify the `ports` section in `docker-compose.yml`:

```yaml
services:
  bifrost-proxy:
    ports:
      - "9090:8080" # Maps port 9090 on your host to 8080 in the container
```

After changing the port, restart the proxy:

```bash
docker compose down
docker compose up -d
```

### Data Persistence

Data is stored in the `./app/data` directory on the host machine and mapped to `/app/data` inside the container. This ensures that your configurations and logs are preserved across container restarts.

---

## 📋 Operational Commands

| Action                      | Command                                       |
| :-------------------------- | :-------------------------------------------- |
| **Start Proxy**             | `docker compose up -d`                        |
| **Stop Proxy**              | `docker compose down`                         |
| **View Logs**               | `docker compose logs -f`                      |
| **Restart Proxy**           | `docker compose restart`                      |
| **Update Image**            | `docker compose pull && docker compose up -d` |

---

## 📄 License

This project is licensed under the MIT License.

---

Made with ❤️ for the AI community
