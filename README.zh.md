# TokenLive 一键部署

> **语言 / Language:** [English](README.md) | 简体中文

这是 TokenLive 平台的一键部署配置，包含：

- **Admin Console** - 管理后台
- **Gateway** - AI API 网关
- **Caddy** - 统一反向代理（支持自动 HTTPS）
- **Redis**（可选）- 用于缓存和状态共享
- **Prometheus**（可选）- 指标采集

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

### 方式一：一键安装（推荐）

无需克隆仓库，一行命令即可完成部署：

```bash
curl -fsSL https://raw.githubusercontent.com/tokenlive/tokenlive-deploy/main/install.sh | bash
```

交互式向导会引导你完成域名、端口、密码等配置。如需非交互式部署（CI/自动化场景）：

```bash
curl -fsSL https://raw.githubusercontent.com/tokenlive/tokenlive-deploy/main/install.sh | bash -s -- --domain api.example.com --password your-password --yes
```

也可通过环境变量传参（`TL_` 前缀）：

```bash
TL_DOMAIN=api.example.com TL_ADMIN_PASSWORD=your-password \
  curl -fsSL https://raw.githubusercontent.com/tokenlive/tokenlive-deploy/main/install.sh | bash
```

> 脚本会自动检测并安装 Docker（Linux），下载所需配置文件到 `~/.tokenlive` 目录。macOS 用户需先手动安装 Docker Desktop。完整参数说明见 `bash install.sh --help`。

### 方式二：克隆仓库后安装

```bash
git clone https://github.com/tokenlive/tokenlive-deploy.git
cd tokenlive-deploy
chmod +x install.sh
./install.sh
```

### 方式三：本地构建镜像

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

### 组件独立版本

Admin 与 Gateway 可在 `.env` 中独立选择发行版本：

```env
VERSION=v1.0.0
ADMIN_VERSION=v1.1.0
GATEWAY_VERSION=v1.2.0
```

组件版本非空时优先于 `VERSION`；为空或未设置时回退到 `VERSION`，再回退到 `latest`。两个 Compose 文件都兼容原来只配置 `VERSION` 的方式。

构建和安装脚本均支持 `--admin-version`、`--gateway-version`，原有 `--version` 继续作为共享镜像标签回退值：

```bash
./build-images.sh --admin-version v1.1.0 --gateway-version v1.2.0
bash install.sh --admin-version v1.1.0 --gateway-version v1.2.0 --yes
```

安装器接受 `TL_ADMIN_VERSION` / `TL_GATEWAY_VERSION` 以及无前缀版本环境变量。每个字段的优先级为命令行参数、`TL_` 环境变量、无前缀环境变量、已有 `.env`。组件固定版本仍优先于共享的 `--version`。普通安装在没有显式覆盖时保留原来的镜像仓库和版本字段；其他配置字段仍按原有方式重新生成。

使用 `--upgrade` 时，显式覆盖仅对本次运行生效，不改写 `.env`。持久调整版本请编辑 `.env`，否则之后直接运行 Compose 时仍使用保存的版本。升级脚本会在停止容器前通过 Compose 解析准确的 Admin/Gateway 镜像；删除镜像、拉取、启动使用相同的文件、profile 和覆盖值。

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

#### 镜像标签与程序构建元数据

镜像标签不等于可执行程序的版本。两个本地构建入口的 `ADMIN_BUILD_VERSION`、`GATEWAY_BUILD_VERSION` 都默认 `dev`，即使镜像标签是 `latest`、分支别名或语义版本号也不会自动改变。确需嵌入已知源码版本时请显式设置：

```bash
ADMIN_BUILD_VERSION=v1.1.0 GATEWAY_BUILD_VERSION=v1.2.0 \
  ./build-images.sh --admin-version v1.1.0 --gateway-version v1.2.0
```

Compose 构建可将相同的 `ADMIN_BUILD_VERSION` / `GATEWAY_BUILD_VERSION` 写入 `.env`。构建脚本只读取已导出的环境变量，不自行加载 `.env`。`ADMIN_BUILD_KIND` / `GATEWAY_BUILD_KIND` 回退到 `BUILD_KIND`，再回退到 `dev`；只有受控正式发布构建才应显式设置 `release`。仅设置版本格式的镜像标签或构建版本，不会让本地开发构建参与正式版本比较。不要将 `latest` 或分支别名用作程序构建版本。

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

# 可选：域名（填入后启用 HTTPS，留空使用 HTTP）
DOMAIN=your-domain.com
```

### 版本上报与更新检查

```env
UPDATE_CHECK_ENABLED=true
UPDATE_CHECK_INTERVAL_SECONDS=21600
GATEWAY_VERSION_NAMESPACE=default
```

Admin 启动后异步检查一次更新，之后默认每 6 小时检查。设置 `UPDATE_CHECK_ENABLED=false` 会关闭定时和手动外部检查，但当前版本展示及 Gateway 内部上报继续运行。更新检查不会自动安装更新或重启服务。

同一部署中的 Admin 与 Gateway 必须使用相同 namespace。共用 Redis 的不同部署应设置不同 namespace，避免节点观测相互混入。纯内存模式下部署多个 Admin 时，每个 Admin 只展示本实例观测到的节点。

### 启用 HTTPS

1. 在 `.env` 中设置域名：

```env
DOMAIN=your-domain.com
```

2. 重启服务：

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
REDIS_PASSWORD=
REDIS_DB=0
```

#### 启用 ClickHouse 访问日志

ClickHouse 为外置可选依赖，部署脚本只生成连接配置并注入 Gateway，不会安装 ClickHouse 服务。

交互式安装时进入高级配置并按提示启用；非交互部署可使用：

```bash
bash install.sh --clickhouse --clickhouse-addr clickhouse.example.com:9000 --clickhouse-database tokenlive_gateway --yes
```

或在 `.env` 中添加或更新：

```env
CLICKHOUSE_ENABLED=true
CLICKHOUSE_ADDR=clickhouse.example.com:9000
CLICKHOUSE_DATABASE=tokenlive_gateway
CLICKHOUSE_USERNAME=default
CLICKHOUSE_PASSWORD=
```

### 启用监控

启用 Prometheus：

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

### Prometheus（可选）

启用指标采集：

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
> 在该模式下，`Admin 后台`与 `Gateway 网关`默认通过内网 HTTP 轮询同步配置，适合单机轻量部署。限流、熔断及 Token 额度扣减等运行状态仍保存在网关本地内存中，无法在多网关实例之间共享。
>
> 若要启用多实例共享状态和 Redis 实时同步，请使用包含 Redis 的增强模式部署。
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
    │    Prometheus      │◄────────┤     Metrics      │
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
