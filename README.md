# TokenLive One-Click Deployment

> **Language / 语言:** English | [简体中文](README.zh.md)

This is the one-click deployment configuration for the TokenLive platform, including:

- **Admin Console** - Administration dashboard
- **Gateway** - AI API gateway
- **Caddy** - Unified reverse proxy (with automatic HTTPS support)
- **Redis** (optional) - For caching and state sharing
- **Prometheus** (optional) - Metrics collection

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

### Option 1: One-Click Install (Recommended)

No need to clone the repo — deploy with a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/tokenlive/tokenlive-deploy/main/install.sh | bash
```

An interactive wizard guides you through domain, port, and password configuration. For non-interactive deployment (CI/automation):

```bash
curl -fsSL https://raw.githubusercontent.com/tokenlive/tokenlive-deploy/main/install.sh | bash -s -- --domain api.example.com --password your-password --yes
```

Or pass configuration via environment variables (`TL_` prefix):

```bash
TL_DOMAIN=api.example.com TL_ADMIN_PASSWORD=your-password \
  curl -fsSL https://raw.githubusercontent.com/tokenlive/tokenlive-deploy/main/install.sh | bash
```

> The script auto-installs Docker on Linux if missing, and downloads required config files to `~/.tokenlive`. macOS users need Docker Desktop installed first. See `bash install.sh --help` for full options.

### Option 2: Clone & Install

```bash
git clone https://github.com/tokenlive/tokenlive-deploy.git
cd tokenlive-deploy
chmod +x install.sh
./install.sh
```

### Option 3: Build Images Locally

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
    image: ghcr.io/tokenlive/tokenlive-admin:latest
  gateway:
    image: ghcr.io/tokenlive/tokenlive-gateway:latest
```

**Custom Image Registry**:

```bash
# Set environment variables
export REGISTRY=docker.io/myuser
export VERSION=v1.0.0

# Use custom images
docker compose up -d
```

### Independent Component Versions

Admin and Gateway releases can be selected independently in `.env`:

```env
VERSION=v1.0.0
ADMIN_VERSION=v1.1.0
GATEWAY_VERSION=v1.2.0
```

Each non-empty component version takes priority over `VERSION`; an empty or missing component value falls back to `VERSION`, then `latest`. Old configurations containing only `VERSION` continue to work in both Compose files.

Both scripts accept `--admin-version` and `--gateway-version`, while `--version` remains the shared image-tag fallback:

```bash
./build-images.sh --admin-version v1.1.0 --gateway-version v1.2.0
bash install.sh --admin-version v1.1.0 --gateway-version v1.2.0 --yes
```

The installer accepts `TL_ADMIN_VERSION` / `TL_GATEWAY_VERSION` and the unprefixed version variables. For each field, precedence is CLI flag, `TL_` variable, unprefixed variable, then existing `.env`. Component pins still take priority over a shared `--version` value. A normal install preserves prior registry/image-version fields unless overridden; its existing regeneration behavior for other configuration fields is unchanged.

With `--upgrade`, explicit overrides apply only to that run, and `.env` is left unchanged. Edit `.env` for a durable version change; otherwise a later Compose command will use the saved versions again. The upgrade script resolves its exact Admin/Gateway images through Compose before stopping containers and uses the same files, profile, and overrides for image removal, pull, and startup.

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
docker build -t ghcr.io/tokenlive/tokenlive-admin:latest .

# Build Gateway
cd ../tokenlive-gateway
docker build -f deploy/build/Dockerfile --build-arg APP_RELATIVE_PATH="./cmd/server" -t ghcr.io/tokenlive/tokenlive-gateway:latest .
```

#### Option 3: Using Docker Compose Build

```bash
# Build and start
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

#### Image Tags vs. Runtime Build Metadata

An image tag is not executable version metadata. Both local build paths default `ADMIN_BUILD_VERSION` and `GATEWAY_BUILD_VERSION` to `dev`, even when the image tag is `latest`, a branch alias, or a semantic version. To embed a known source version, set the build versions explicitly:

```bash
ADMIN_BUILD_VERSION=v1.1.0 GATEWAY_BUILD_VERSION=v1.2.0 \
  ./build-images.sh --admin-version v1.1.0 --gateway-version v1.2.0
```

For Compose builds, put the same `ADMIN_BUILD_VERSION` / `GATEWAY_BUILD_VERSION` values in `.env`. The build script uses exported environment variables and does not load `.env` itself. `ADMIN_BUILD_KIND` / `GATEWAY_BUILD_KIND` fall back to `BUILD_KIND`, then `dev`; only a controlled release build should explicitly set `release`. Version-like tags or build versions alone do not make a local development build eligible for release comparisons. Never use `latest` or a branch alias as a build version.

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

# Optional: Domain (enables HTTPS when set; leave empty for HTTP)
DOMAIN=your-domain.com
```

### Version Reporting and Update Checks

```env
UPDATE_CHECK_ENABLED=true
UPDATE_CHECK_INTERVAL_SECONDS=21600
GATEWAY_VERSION_NAMESPACE=default
```

Admin checks for updates asynchronously after startup and then every six hours by default. Setting `UPDATE_CHECK_ENABLED=false` disables both scheduled and manual external checks, but current-version display and internal Gateway reporting continue. These checks do not install updates or restart services.

Use the same namespace for Admin and Gateway within one deployment. Separate deployments sharing Redis must use different namespaces to keep node observations isolated. In memory-only deployments with multiple Admin instances, each Admin displays only nodes observed by that instance.

### Enabling HTTPS

1. Set the domain in `.env`:

```env
DOMAIN=your-domain.com
```

2. Restart services:

```bash
docker compose restart
```

### Configuration & State Storage Modes

This deployment supports two running modes:

1. **Default Mode (No Redis)**:
   * **Dynamic Configuration Sync**: The Gateway automatically polls the Admin Console via **HTTP Polling** to fetch the latest models, endpoints, policies, and API keys, and hot-reloads them in memory.
   * **Runtime State**: Rate limiting, circuit breaker, and token settlement states are stored in the Gateway's local memory.
   * **Use Case**: Lightweight, single-instance deployment with zero external dependencies.

2. **Redis Mode (Distributed Cluster)**:
   * **Configuration Hot-Sync**: The Gateway synchronizes configuration changes from the Admin Console in real-time via Redis Pub/Sub.
   * **Shared State**: Multiple Gateway instances share rate limiting, circuit breaker, and quota deduction states.
   * **Use Case**: Multi-instance horizontal scaling and high-availability clusters.

#### Enabling Redis Mode

1. Start with Redis:
```bash
docker compose --profile with-redis up -d
```

2. Add or update configurations in `.env`:
```env
# Enable Redis Mode
GATEWAY_CONFIG_SOURCE=redis
GATEWAY_STATE_STORE=redis
REDIS_ADDR=redis:6379
REDIS_PASSWORD=
REDIS_DB=0
```

#### Enabling ClickHouse Access Logs

ClickHouse is an optional external dependency. The deployment script only writes the connection settings and injects them into the Gateway; it does not install ClickHouse.

In interactive mode, enter advanced configuration and enable it when prompted. For non-interactive deployment:

```bash
bash install.sh --clickhouse --clickhouse-addr clickhouse.example.com:9000 --clickhouse-database tokenlive_gateway --yes
```

Or add/update these values in `.env`:

```env
CLICKHOUSE_ENABLED=true
CLICKHOUSE_ADDR=clickhouse.example.com:9000
CLICKHOUSE_DATABASE=tokenlive_gateway
CLICKHOUSE_USERNAME=default
CLICKHOUSE_PASSWORD=
```

### Enabling Monitoring

Enable Prometheus:

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
- **Admin Configuration Hot-Sync**: Real-time synchronization of policies, models, and endpoints from the Admin Console to the Gateway.
- **Gateway Multi-instance Deployment**: Distribute load across multiple Gateway instances.
- **Persistent State**: Persistent rate limiting, circuit breaker, and metrics.

> [!NOTE]
> Without Redis, the Admin Console and Gateway automatically synchronize configuration and policies via internal HTTP polling (no manual setup required). The Gateway's runtime states (rate limiting, circuit breakers) are stored in local memory.

```bash
docker compose --profile with-redis up -d
```

### Prometheus (Optional)

Enable metrics collection:

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

> [!WARNING]
> **Limitations of Minimal Mode (Without Redis)**:
> In this mode, the `Admin Console` and `Gateway API` synchronize configuration through internal HTTP polling by default, which is suitable for lightweight single-instance deployments. Runtime state such as rate limits, circuit breakers, and token quota deductions remains in the Gateway's local memory and is not shared across multiple Gateway instances.
>
> Use the Redis profile when you need shared runtime state across multiple Gateway instances and Redis-based real-time synchronization.
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
    │    Prometheus      │◄────────┤     Metrics      │
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
