# TokenLive One-Click Deployment

> **Language / 语言:** English | [简体中文](README.zh.md)

This is the one-click deployment configuration for the TokenLive platform, including:

- **Admin Console** - Administration dashboard
- **Gateway** - AI API gateway
- **Caddy** - Unified reverse proxy (with automatic HTTPS support)
- **Redis** (optional) - For caching and state sharing
- **Prometheus + Grafana** (optional) - Monitoring and visualization

---

## Table of Contents

- [Quick Start](#quick-start)
- [Image Sources](#image-sources)
  - [Using Pre-built Images](#using-pre-built-images)
  - [Building Images Locally](#building-images-locally)
- [Configuration](#configuration)
- [Optional Features](#optional-features)
- [Management Commands](#management-commands)
- [Architecture](#architecture)
- [FAQ](#faq)

---

## Quick Start

### Option 1: Use Pre-built Images (Recommended)

```bash
# 1. Download deployment files
git clone https://github.com/tokenlive/tokenlive-deploy.git
cd tokenlive-deploy

# 2. One-click install
chmod +x install.sh
./install.sh
```

### Option 2: Build Images Locally

```bash
# 1. Ensure the project directory structure is as follows:
# /path/to/tokenlive-admin/
# /path/to/tokenlive-gateway/
# /path/to/tokenlive-deploy/

# 2. Build images
cd tokenlive-deploy
chmod +x build-images.sh
./build-images.sh

# 3. Build and start locally
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

### 3. Access Services

- **Admin Console**: http://localhost
- **Gateway API**: http://localhost/v1

Default credentials: `admin` / `admin`

---

## Image Sources

### Using Pre-built Images

By default, images from GitHub Container Registry (ghcr.io) are used:

```yaml
# docker-compose.yml
services:
  admin:
    image: ghcr.io/chenzhiguo/tokenlive-admin:latest
  gateway:
    image: ghcr.io/chenzhiguo/tokenlive-gateway:latest
```

**Custom Image Registry**:

```bash
# Set environment variables
export REGISTRY=docker.io/myuser
export VERSION=v1.0.0

# Use custom images
docker compose up -d
```

### Building Images Locally

#### Option 1: Using the Build Script (Recommended)

```bash
# Build all images
./build-images.sh

# Build Admin only
./build-images.sh --admin

# Build Gateway only
./build-images.sh --gateway

# Build and push
./build-images.sh --push

# Custom registry and version
./build-images.sh --registry docker.io/myuser --version v1.0.0
```

#### Option 2: Using docker build Directly

```bash
# Build Admin
cd ../tokenlive-admin
docker build -t ghcr.io/chenzhiguo/tokenlive-admin:latest .

# Build Gateway
cd ../tokenlive-gateway
docker build -f deploy/build/Dockerfile --build-arg APP_RELATIVE_PATH="./cmd/server" -t ghcr.io/chenzhiguo/tokenlive-gateway:latest .
```

#### Option 3: Using Docker Compose Build

```bash
# Build and start
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

---

## Configuration

### Basic Configuration

Edit the `.env` file to configure basic parameters:

```env
# Port configuration
HTTP_PORT=80
HTTPS_PORT=443

# Admin console password
ADMIN_PASSWORD=your_secure_password

# Optional: Domain (enables HTTPS)
DOMAIN=your-domain.com
```

### Enabling HTTPS

1. Set the domain in `.env`:

```env
DOMAIN=your-domain.com
```

2. Edit `caddy/Caddyfile` and uncomment the HTTPS configuration:

```caddyfile
your-domain.com {
    reverse_proxy /v1/* gateway:8000
    reverse_proxy /* admin:8040
}
```

3. Restart services:

```bash
docker compose restart
```

### Enabling Redis

By default, an in-memory mode is used. Enabling Redis provides:

- Multi-instance deployment support
- Hot configuration synchronization
- Persistent rate limiting and circuit breaker state

```bash
docker compose --profile with-redis up -d
```

Add to `.env`:

```env
REDIS_ADDR=redis:6379
```

### Enabling Monitoring

Enable Prometheus + Grafana:

```bash
docker compose --profile with-monitoring up -d
```

Add to `.env`:

```env
PROMETHEUS_SERVER_URL=http://prometheus:9090
```

---

## Optional Features

### Redis (Optional)

Enabling Redis provides support for:

- Gateway multi-instance deployment
- Admin configuration hot-sync
- Persistent rate limiting and circuit breaker state

```bash
docker compose --profile with-redis up -d
```

### Prometheus + Grafana (Optional)

Enable full monitoring:

```bash
docker compose --profile with-monitoring up -d
```

### Enable All

```bash
docker compose --profile with-redis --profile with-monitoring up -d
```

---

## Management Commands

### View Logs

```bash
# View all service logs
docker compose logs -f

# View specific service logs
docker compose logs -f gateway
docker compose logs -f admin
```

### Service Management

```bash
# Stop services
docker compose stop

# Start services
docker compose start

# Restart services
docker compose restart

# View service status
docker compose ps
```

### Update Images

```bash
# Pull latest images
docker compose pull

# Restart services
docker compose up -d
```

### Uninstall

```bash
# Remove containers (keep data)
docker compose down

# Remove containers and volumes (clear all data)
docker compose down -v
```

### Data Backup

```bash
# Backup Admin database
docker cp tokenlive-admin:/data/admin.db ./backup/

# Backup Gateway database
docker cp tokenlive-gateway:/data/gateway.db ./backup/

# Backup configuration
cp .env ./backup/
```

---

## Architecture

### Minimal Mode (Default)

```
                    ┌───────────────────┐
                    │   Caddy (80/443) │
                    └─────────┬─────────┘
                              │
              ┌───────────────┴───────────────┐
              │                               │
    ┌─────────▼──────────┐         ┌─────────▼─────────┐
    │   Admin Console    │         │   Gateway API    │
    │   (8040 internal)  │         │   (8000 internal)│
    └─────────┬──────────┘         └─────────┬─────────┘
              │                              │
    ┌─────────▼──────────┐         ┌─────────▼─────────┐
    │ SQLite (admin.db)  │         │ SQLite (gateway.db)│
    └────────────────────┘         └────────────────────┘

Status: ✅ Zero external dependencies, one-click start
```

### Enhanced Mode (Optional)

```
                    ┌───────────────────┐
                    │   Caddy (80/443) │
                    └─────────┬─────────┘
                              │
              ┌───────────────┴───────────────┐
              │                               │
    ┌─────────▼──────────┐         ┌─────────▼─────────┐
    │   Admin Console    │         │   Gateway API    │
    └─────────┬──────────┘         └─────────┬─────────┘
              │                              │
    ┌─────────▼──────────┐         ┌─────────▼─────────┐
    │   Redis (optional) │◄────────┤   Redis (optional)│
    └─────────┬──────────┘         └─────────┬─────────┘
              │                              │
    ┌─────────▼──────────┐         ┌─────────▼─────────┐
    │ Prometheus/Grafana │◄────────┤     Metrics      │
    └────────────────────┘         └────────────────────┘

Status: 🚀 High performance, high availability, full monitoring
```

---

## Resource Usage Estimates (Default Mode)

| Service | Memory | Disk | Port |
|---------|--------|------|------|
| Caddy | ~20MB | ~100MB | 80, 443 |
| Admin | ~80MB | ~50MB + data | 8040 (internal) |
| Gateway | ~60MB | ~50MB + data | 8000 (internal) |
| **Total** | **~160MB** | **~200MB + data** | **Single port access** |

---

## Security Recommendations

### 1. Change Default Password

```env
# .env
ADMIN_PASSWORD=your-secure-password
```

### 2. Enable HTTPS

```env
# .env
DOMAIN=your-domain.com
```

```caddyfile
# caddy/Caddyfile
your-domain.com {
    reverse_proxy /v1/* gateway:8000
    reverse_proxy /* admin:8040
}
```

### 3. Data Backup

```bash
# Regularly backup databases
docker cp tokenlive-admin:/data/admin.db ./backup/
docker cp tokenlive-gateway:/data/gateway.db ./backup/
```

### 4. Firewall Configuration

Only expose necessary ports (80, 443). Do not directly expose Admin (8040) and Gateway (8000).

---

## Directory Structure

```
tokenlive-deploy/
├── README.md                      # This document
├── DEPLOYMENT_SUMMARY.md          # Deployment summary
├── install.sh                     # One-click install script
├── build-images.sh                # Image build script
├── .env.example                   # Environment variable template
├── docker-compose.yml             # Docker Compose configuration
├── docker-compose.build.yml       # Local build configuration
├── caddy/
│   └── Caddyfile                  # Caddy reverse proxy configuration
├── gateway/
│   └── config/
│       └── default.yml            # Gateway default configuration
└── prometheus/
    └── prometheus.yml             # Prometheus monitoring configuration
```

---

## FAQ

### Q: How to change the image registry?

```bash
# Set environment variable
export REGISTRY=docker.io/myuser

# Or add to .env
REGISTRY=docker.io/myuser

# Restart services
docker compose up -d
```

### Q: How to customize the image version?

```bash
# Set environment variable
export VERSION=v1.0.0

# Or add to .env
VERSION=v1.0.0

# Restart services
docker compose up -d
```

### Q: How to upgrade?

```bash
# Pull latest images
docker compose pull

# Restart services
docker compose up -d
```

### Q: How to view logs?

```bash
# View all service logs
docker compose logs -f

# View specific service logs
docker compose logs -f gateway
docker compose logs -f admin
```

### Q: Does the Gateway Dockerfile need to be updated?

Yes, the current Gateway Dockerfile is somewhat outdated and it is recommended to update it. You can refer to the Admin Dockerfile for optimization.

---

## Technical Support

If you encounter issues, please submit an Issue: https://github.com/tokenlive/tokenlive-admin/issues
