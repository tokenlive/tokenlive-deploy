# TokenLive 一键部署方案总结

## 📋 核心决策回顾

### 1. 目标用户
中小团队自部署，需要简单、快速、资源占用少的部署方式。

### 2. 数据库选择
- **默认**: SQLite（零配置，数据持久化）
- **可选**: MySQL/PostgreSQL（大规模使用）

### 3. Redis 依赖处理
- **默认**: 内存模式（无外部依赖，单实例部署）
- **可选**: Redis（启用多实例、共享状态、更高级功能）

### 4. 监控方案
- **内置监控**: Admin Dashboard 直接从 Gateway 拉取指标
- **可选扩展**: Prometheus + Grafana（专业监控）

### 5. 统一入口
- **Caddy 反向代理**: 单端口访问（HTTP/80，可选 HTTPS/443）
- **路由配置**:
  - `/` → Admin Console
  - `/v1/*` → Gateway API

---

## 🎯 部署架构

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

## 📁 已创建的文件

```
tokenlive-deploy/
├── README.md                      # 详细使用文档
├── DEPLOYMENT_SUMMARY.md          # 本文档
├── install.sh                     # 一键安装脚本
├── .env.example                   # 环境变量模板
├── docker-compose.yml             # Docker Compose 配置
├── caddy/
│   └── Caddyfile                  # Caddy 反向代理配置
├── gateway/
│   └── config/
│       └── default.yml            # Gateway 默认配置
└── prometheus/
    └── prometheus.yml             # Prometheus 监控配置
```

---

## 🚀 快速开始

### 一键部署
```bash
# 1. 克隆部署仓库
git clone https://github.com/tokenlive/tokenlive-deploy.git
cd tokenlive-deploy

# 2. 运行安装脚本
chmod +x install.sh
./install.sh

# 3. 访问 Admin 后台
# http://localhost
# 账号: admin
# 密码: admin (在 .env 中修改)
```

### 启用 Redis
```bash
# 使用带 Redis 的配置
docker compose --profile with-redis up -d
```

### 启用完整监控
```bash
# 启动所有服务
docker compose --profile with-monitoring up -d
```

---

## 🔧 现有功能检查

### ✅ Gateway 功能
- [x] Memory StateStore（无 Redis 模式）
- [x] Redis StateStore（可选）
- [x] Metrics HTTP 端点
- [x] SQLite 数据库支持
- [x] OpenTelemetry 集成

### ✅ Admin Console 功能
- [x] Dashboard 指标展示
- [x] Prometheus 查询集成
- [x] Redis 降级查询
- [x] WebSocket 实时更新
- [x] HTTP 轮询兜底
- [x] 模型管理
- [x] 策略管理
- [x] 用户/空间管理

### ✅ 配置管理
- [x] Admin 配置同步到 Redis（可选）
- [x] Gateway 从 Redis 读取配置（可选）
- [x] 配置热更新

---

## 📊 资源占用预估（默认模式）

| 服务 | 内存 | 磁盘 | 端口 |
|------|------|------|------|
| Caddy | ~20MB | ~100MB | 80, 443 |
| Admin | ~80MB | ~50MB + data | 8040 (internal) |
| Gateway | ~60MB | ~50MB + data | 8000 (internal) |
| **总计** | **~160MB** | **~200MB + data** | **单端口访问** |

---

## 🔐 安全建议

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

```Caddyfile
# caddy/Caddyfile
your-domain.com {
    reverse_proxy /v1/* gateway:8000
    reverse_proxy /* admin:8040
}
```

### 3. 数据备份
```bash
# 备份数据库
docker cp tokenlive-admin:/data/admin.db ./backup/
docker cp tokenlive-gateway:/data/gateway.db ./backup/
```

---

## 📝 后续建议（可选）

### 1. 性能优化
- 为 Gateway 启用 Redis 以支持多实例部署
- 使用 MySQL 替代 SQLite 以支持更高并发
- 配置 Caddy 缓存静态资源

### 2. 高可用部署
```yaml
# docker-compose.ha.yml
services:
  gateway:
    deploy:
      replicas: 3
  redis:
    deploy:
      replicas: 1
```

### 3. 监控和日志
- 启用 Prometheus + Grafana
- 配置日志聚合（ELK, Loki）
- 设置告警规则

---

## 📞 技术支持

如遇问题，请提交 Issue: https://github.com/tokenlive/tokenlive-admin/issues
