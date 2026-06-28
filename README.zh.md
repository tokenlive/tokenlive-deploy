# TokenLive 一键部署

> **语言 / Language:** [English](README.md) | 简体中文

这是 TokenLive 平台的一键部署配置，包含：

- **Admin Console** - 管理后台
- **Gateway** - AI API 网关
- **Caddy** - 统一反向代理（支持自动 HTTPS）
- **Redis**（可选）- 用于缓存和状态共享
- **Prometheus + Grafana**（可选）- 监控和可视化

---

## 目录

- [快速开始](#快速开始)
- [镜像来源](#镜像来源)
  - [使用预构建镜像](#使用预构建镜像)
  - [本地构建镜像](#本地构建镜像)
- [配置说明](#配置说明)
- [可选功能](#可选功能)
- [管理命令](#管理命令)
- [架构说明](#架构说明)
- [常见问题](#常见问题)

---

## 快速开始

### 方式一：使用预构建镜像（推荐）

```bash
# 1. 下载部署文件
git clone https://github.com/tokenlive/tokenlive-deploy.git
cd tokenlive-deploy

# 2. 一键安装
chmod +x install.sh
./install.sh
```

### 方式二：本地构建镜像

```bash
# 1. 确保项目目录结构如下：
# /path/to/tokenlive-admin/
# /path/to/tokenlive-gateway/
# /path/to/tokenlive-deploy/

# 2. 构建镜像
cd tokenlive-deploy
chmod +x build-images.sh
./build-images.sh

# 3. 本地构建并启动
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

### 3. 访问服务

- **Admin 后台**: http://localhost
- **Gateway API**: http://localhost/v1

默认账号: `admin` / `admin`

---

## 镜像来源

### 使用预构建镜像

默认使用 GitHub Container Registry（ghcr.io）的镜像：

```yaml
# docker-compose.yml
services:
  admin:
    image: ghcr.io/tokenlive/tokenlive-admin:latest
  gateway:
    image: ghcr.io/tokenlive/tokenlive-gateway:latest
```

**自定义镜像仓库**:

```bash
# 设置环境变量
export REGISTRY=docker.io/myuser
export VERSION=v1.0.0

# 使用自定义镜像
docker compose up -d
```

### 本地构建镜像

#### 方式一：使用构建脚本（推荐）

```bash
# 构建所有镜像
./build-images.sh

# 只构建 Admin
./build-images.sh --admin

# 只构建 Gateway
./build-images.sh --gateway

# 构建并推送
./build-images.sh --push

# 自定义镜像仓库和版本
./build-images.sh --registry docker.io/myuser --version v1.0.0
```

#### 方式二：直接使用 docker build

```bash
# 构建 Admin
cd ../tokenlive-admin
docker build -t ghcr.io/tokenlive/tokenlive-admin:latest .

# 构建 Gateway
cd ../tokenlive-gateway
docker build -f deploy/build/Dockerfile --build-arg APP_RELATIVE_PATH="./cmd/server" -t ghcr.io/tokenlive/tokenlive-gateway:latest .
```

#### 方式三：使用 Docker Compose 构建

```bash
# 构建并启动
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

---

## 配置说明

### 基础配置

编辑 `.env` 文件配置基础参数：

```env
# 端口配置
HTTP_PORT=80
HTTPS_PORT=443

# Admin 后台密码
ADMIN_PASSWORD=your_secure_password

# 可选：域名（启用 HTTPS）
DOMAIN=your-domain.com
```

### 启用 HTTPS

1. 在 `.env` 中设置域名：

```env
DOMAIN=your-domain.com
```

2. 编辑 `caddy/Caddyfile` 取消 HTTPS 配置的注释：

```caddyfile
your-domain.com {
    reverse_proxy /v1/* gateway:8000
    reverse_proxy /* admin:8040
}
```

3. 重启服务：

```bash
docker compose restart
```

### 配置与状态存储模式

本部署方案支持以下两种运行模式：

1. **默认模式（无 Redis）**：
   * **配置动态同步**：网关默认通过 **HTTP 轮询 (HTTP Polling)** 定时从管理后台拉取最新的模型、端点、策略及 API 密钥，并在本地内存中进行热更新。
   * **运行状态**：限流、熔断及 Token 额度扣减等状态均保存在网关的单机本地内存中。
   * **适用场景**：轻量化单架部署，零外部依赖。

2. **Redis 模式（分布式集群）**：
   * **配置热同步**：网关通过 Redis 实时同步管理后台的配置变更。
   * **运行状态共享**：多台网关实例共享限流、熔断及配额扣减状态，避免单机内存限制。
   * **适用场景**：多实例横向扩容、高可用集群。

#### 启用 Redis 模式

1. 使用 Redis 启动：
```bash
docker compose --profile with-redis up -d
```

2. 在 `.env` 中添加或更新配置：
```env
# 启用 Redis 模式
GATEWAY_CONFIG_SOURCE=redis
GATEWAY_STATE_STORE=redis
REDIS_ADDR=redis:6379
```

### 启用监控

启用 Prometheus + Grafana：

```bash
docker compose --profile with-monitoring up -d
```

在 `.env` 中添加：

```env
PROMETHEUS_SERVER_URL=http://prometheus:9090
```

---

## 可选功能

### Redis（可选）

启用 Redis 后可以支持：
- **Admin 配置热同步**：管理后台的策略、模型、端点配置实时热更新至网关。
- **Gateway 多实例部署**：支持网关横向扩展，共享状态。
- **持久化限流、熔断状态**：全局限流与熔断状态的持久化及共享。

> [!NOTE]
> 如果不启用 Redis，管理后台与网关默认通过内网 HTTP 轮询接口进行配置和策略同步（无需手动配置）。网关的运行状态（限流、熔断等）将保存在单机本地内存中。

```bash
docker compose --profile with-redis up -d
```

### Prometheus + Grafana（可选）

启用完整监控：

```bash
docker compose --profile with-monitoring up -d
```

### 全部启用

```bash
docker compose --profile with-redis --profile with-monitoring up -d
```

---

## 管理命令

### 查看日志

```bash
# 查看所有服务日志
docker compose logs -f

# 查看特定服务日志
docker compose logs -f gateway
docker compose logs -f admin
```

### 服务管理

```bash
# 停止服务
docker compose stop

# 启动服务
docker compose start

# 重启服务
docker compose restart

# 查看服务状态
docker compose ps
```

### 更新镜像

```bash
# 拉取最新镜像
docker compose pull

# 重启服务
docker compose up -d
```

### 卸载服务

```bash
# 删除容器（保留数据）
docker compose down

# 删除容器和卷（清空所有数据）
docker compose down -v
```

### 数据备份

```bash
# 备份 Admin 数据库
docker cp tokenlive-admin:/data/admin.db ./backup/

# 备份 Gateway 数据库
docker cp tokenlive-gateway:/data/gateway.db ./backup/

# 备份配置
cp .env ./backup/
```

---

## 架构说明

### 极简模式（默认）

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

Status: ✅ 零外部依赖，一键启动

> [!WARNING]
> **极简模式（无 Redis）的限制**：
> 在该模式下，`Admin 后台`与 `Gateway 网关`独立运行。由于两者使用各自独立的 SQLite 数据库且无共享通道，在管理后台 UI 上所做的任何修改（如新增模型、修改端点地址、调整治理策略等）**均无法**同步给网关。网关将严格运行在静态配置模式下，仅读取本地的 YAML 配置文件（`gateway/config/default.yml`）。
>
> 若要启用动态配置热同步，**必须**使用包含 Redis 的增强模式进行部署。
```

### 可选增强模式

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
    │   Redis (可选)     │◄────────┤   Redis (可选)    │
    └─────────┬──────────┘         └─────────┬─────────┘
              │                              │
    ┌─────────▼──────────┐         ┌─────────▼─────────┐
    │ Prometheus/Grafana │◄────────┤     Metrics      │
    └────────────────────┘         └────────────────────┘

Status: 🚀 高性能、高可用、完整监控
```

---

## 资源占用预估（默认模式）

| 服务 | 内存 | 磁盘 | 端口 |
|------|------|------|------|
| Caddy | ~20MB | ~100MB | 80, 443 |
| Admin | ~80MB | ~50MB + data | 8040 (internal) |
| Gateway | ~60MB | ~50MB + data | 8000 (internal) |
| **总计** | **~160MB** | **~200MB + data** | **单端口访问** |

---

## 安全建议

### 1. 修改默认密码

```env
# .env
ADMIN_PASSWORD=your-secure-password
```

### 2. 启用 HTTPS

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

### 3. 数据备份

```bash
# 定期备份数据库
docker cp tokenlive-admin:/data/admin.db ./backup/
docker cp tokenlive-gateway:/data/gateway.db ./backup/
```

### 4. 防火墙配置

只暴露必要的端口（80, 443），不直接暴露 Admin（8040）和 Gateway（8000）。

---

## 目录结构

```
tokenlive-deploy/
├── README.md                      # 本文档
├── DEPLOYMENT_SUMMARY.md          # 部署方案总结
├── install.sh                     # 一键安装脚本
├── build-images.sh                # 镜像构建脚本
├── .env.example                   # 环境变量模板
├── docker-compose.yml             # Docker Compose 配置
├── docker-compose.build.yml       # 本地构建配置
├── caddy/
│   └── Caddyfile                  # Caddy 反向代理配置
├── gateway/
│   └── config/
│       └── default.yml            # Gateway 默认配置
└── prometheus/
    └── prometheus.yml             # Prometheus 监控配置
```

---

## 常见问题

### Q: 如何修改镜像仓库？

```bash
# 设置环境变量
export REGISTRY=docker.io/myuser

# 或在 .env 中添加
REGISTRY=docker.io/myuser

# 重启服务
docker compose up -d
```

### Q: 如何自定义镜像版本？

```bash
# 设置环境变量
export VERSION=v1.0.0

# 或在 .env 中添加
VERSION=v1.0.0

# 重启服务
docker compose up -d
```

### Q: 如何升级？

```bash
# 拉取最新镜像
docker compose pull

# 重启服务
docker compose up -d
```

### Q: 如何查看日志？

```bash
# 查看所有服务日志
docker compose logs -f

# 查看特定服务日志
docker compose logs -f gateway
docker compose logs -f admin
```

### Q: Gateway 的 Dockerfile 需要更新吗？

是的，当前 Gateway 的 Dockerfile 有些老，建议更新一下。可以参考 Admin 的 Dockerfile 进行优化。

---

## 技术支持

如遇问题，请提交 Issue: https://github.com/tokenlive/tokenlive-admin/issues
