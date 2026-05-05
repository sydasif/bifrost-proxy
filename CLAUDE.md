# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains the deployment configuration for the Bifrost Proxy. It is a deployment-only repository that manages the proxy via Docker Compose.

## Deployment Commands

- Start the proxy: `docker compose up -d`
- Stop the proxy: `docker compose down`
- View logs: `docker compose logs -f`
- Restart the proxy: `docker compose restart`

## Architecture

- **Deployment:** Managed via `docker-compose.yml`.
- **Image:** Uses `maximhq/bifrost:latest`.
- **Persistence:** Data is persisted in `./app/data`, which is mapped to `/app/data` inside the container.
- **Port:** The proxy listens on port `8080`.
