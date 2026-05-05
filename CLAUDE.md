# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains the deployment configuration for the Bifrost Proxy. It is a deployment-only repository that manages the proxy via Docker Compose.

## Deployment Commands

- Start the proxy: `docker compose up -d`
- Stop the proxy: `docker compose down`
- View logs: `docker compose logs -f`
- Restart the proxy: `docker compose restart`
- Update image: `docker compose pull && docker compose up -d`

## Architecture

- **Deployment:** Managed via `docker-compose.yml`.
- **Image:** Uses `maximhq/bifrost:latest`.
- **Persistence:** Data is persisted in `./app/data`, which is mapped to `/app/data` inside the container.
- **Port:** The proxy listens on port `8080`.

## Integration Guide

### OpenCode Configuration

To redirect `opencode` to this proxy, use the following settings in `opencode.json`:

- **baseURL:** `http://localhost:8080/v1`
- **Provider:** `bifrost`

### Claude Code Configuration

To redirect `claude` to this proxy, use the following environment variables in `settings.json`:

- `ANTHROPIC_BASE_URL`: `http://localhost:8080/`
- `ANTHROPIC_DEFAULT_SONNET_MODEL`: `gemini/gemma-4-31b-it`
- `ANTHROPIC_DEFAULT_OPUS_MODEL`: `gemini/gemini-3.1-flash-lite-preview`
- `ANTHROPIC_DEFAULT_HAIKU_MODEL`: `gemini/gemma-4-26b-a4b-it`
