#!/bin/bash

set -e

# ===========================================
# TokenLive 一键部署脚本
# ===========================================

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 脚本目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

echo ""
echo "=========================================="
echo "  TokenLive 一键部署工具"
echo "=========================================="
echo ""

# 检查 Docker
if ! command -v docker &> /dev/null; then
    echo -e "${RED}✗ 未检测到 Docker，请先安装 Docker${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Docker 已安装${NC}"

# 检查 Docker Compose
if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    echo -e "${RED}✗ 未检测到 Docker Compose，请先安装${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Docker Compose 已安装${NC}"
echo ""

# 检查配置文件
if [ ! -f .env ]; then
    echo -e "${YELLOW}⚠ 未找到 .env 文件，正在从 .env.example 创建...${NC}"
    cp .env.example .env
    echo ""
    echo "=========================================="
    echo "  请编辑 .env 文件配置环境变量"
    echo "  然后重新运行此脚本"
    echo "=========================================="
    echo ""
    echo "配置项说明："
    echo "  - ADMIN_PASSWORD      Admin 后台密码"
    echo "  - HTTP_PORT           HTTP 端口 (默认 80)"
    echo "  - HTTPS_PORT          HTTPS 端口 (默认 443)"
    echo "  - DOMAIN              可选：自定义域名，留空使用 HTTP"
    echo ""
    exit 0
fi

echo -e "${GREEN}✓ .env 配置文件已就绪${NC}"
echo ""

# 创建必要的目录
mkdir -p caddy gateway/config

# 拉取镜像
echo "=========================================="
echo "  正在拉取最新镜像..."
echo "=========================================="
if command -v docker-compose &> /dev/null; then
    docker-compose pull
else
    docker compose pull
fi
echo ""

# 启动服务
echo "=========================================="
echo "  正在启动 TokenLive 服务..."
echo "=========================================="
if command -v docker-compose &> /dev/null; then
    docker-compose up -d
else
    docker compose up -d
fi

echo ""
echo "=========================================="
echo -e "  ${GREEN}✓ TokenLive 部署成功！${NC}"
echo "=========================================="
echo ""
echo "访问地址："
if [ -n "${DOMAIN:-}" ]; then
    echo "  - Admin 后台: https://${DOMAIN}"
    echo "  - Gateway API: https://${DOMAIN}/v1"
else
    echo "  - Admin 后台: http://localhost"
    echo "  - Gateway API: http://localhost/v1"
fi
echo ""
echo "默认账号："
echo "  - 用户名: admin"
echo "  - 密码: admin (请在 .env 文件中修改 ADMIN_PASSWORD)"
echo ""
echo "管理命令："
echo "  - 查看日志: docker compose logs -f"
echo "  - 停止服务: docker compose stop"
echo "  - 启动服务: docker compose start"
echo "  - 重启服务: docker compose restart"
echo "  - 卸载服务: docker compose down -v"
echo ""
echo "可选功能："
echo "  - 启用 Redis: docker compose --profile with-redis up -d"
echo "  - 启用监控: docker compose --profile with-monitoring up -d"
echo ""
