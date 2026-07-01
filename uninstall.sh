#!/bin/bash

# ===========================================
# TokenLive 一键卸载与清理脚本
# ===========================================

set -e

# 颜色输出定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 脚本目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

echo -e "${RED}"
echo "=================================================="
echo "         TokenLive 一键卸载与清理向导             "
echo "=================================================="
echo -e "${NC}"

# 确认是否继续卸载
read -r -p "⚠️  警告：此操作将停止并销毁 TokenLive 所有的运行中容器。是否继续？ [y/N]: " confirm_uninstall
case "$confirm_uninstall" in
    [yY][eE][sS]|[yY])
        ;;
    *)
        echo -e "${GREEN}操作已取消，退出卸载。${NC}"
        exit 0
        ;;
esac
echo ""

# 1. 检查 Docker Compose 命令
COMPOSE_CMD=""
if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &> /dev/null; then
    COMPOSE_CMD="docker-compose"
else
    # 如果没装 Compose，只提示但仍尝试往下走（万一用户只是删除了命令）
    echo -e "${YELLOW}⚠️ 警告：未检测到 Docker Compose 命令，卸载可能受限。${NC}"
fi

# 2. 获取当前部署配置（主要是镜像来源和是否启用本地 Redis 容器）
IMAGE_SOURCE_VAL="remote"
USE_LOCAL_REDIS=false
if [ -f .env ]; then
    IMAGE_SOURCE_VAL=$(grep "^IMAGE_SOURCE=" .env | cut -d= -f2- || echo "remote")
    if grep -q "^REDIS_ADDR=" .env; then
        REDIS_ADDR_VAL=$(grep "^REDIS_ADDR=" .env | cut -d= -f2-)
        if [ "$REDIS_ADDR_VAL" = "redis:6379" ] || [ "$REDIS_ADDR_VAL" = "redis" ] || [[ "$REDIS_ADDR_VAL" =~ ^redis: ]]; then
            USE_LOCAL_REDIS=true
        fi
    fi
fi

# 3. 收集用户清理选项
CLEAN_DATA=false
CLEAN_IMAGES=false
CLEAN_ENV=false

# 3.1 询问是否删除数据卷（包含数据库、存储文件、Caddy 证书等）
read -r -p "是否删除所有持久化数据？(这将彻底销毁数据库及配置文件，不可恢复！) [y/N]: " data_choice
case "$data_choice" in
    [yY][eE][sS]|[yY])
        CLEAN_DATA=true
        echo -e "${RED}⚠️  已选择：清理所有持久化数据卷。${NC}"
        ;;
    *)
        ;;
esac

# 3.2 询问是否删除本地拉取的 Docker 镜像
read -r -p "是否删除本机的 TokenLive 核心 Docker 镜像？ [y/N]: " img_choice
case "$img_choice" in
    [yY][eE][sS]|[yY])
        CLEAN_IMAGES=true
        ;;
    *)
        ;;
esac

# 3.3 询问是否删除配置文件 .env
read -r -p "是否删除本地配置文件 .env？ [y/N]: " env_choice
case "$env_choice" in
    [yY][eE][sS]|[yY])
        CLEAN_ENV=true
        ;;
    *)
        ;;
esac
echo ""

# 4. 执行卸载动作
if [ -n "$COMPOSE_CMD" ]; then
    # 拼装 docker compose 配置文件列表
    COMPOSE_FILES="-f docker-compose.yml"
    if [ "$IMAGE_SOURCE_VAL" = "local" ] && [ -f docker-compose.build.yml ]; then
        COMPOSE_FILES="-f docker-compose.yml -f docker-compose.build.yml"
    fi

    # 停止并删除容器
    echo -e "${BLUE}1. 正在停止并销毁运行中的容器...${NC}"
    
    # 基础 down 参数
    DOWN_ARGS=""
    if [ "$CLEAN_DATA" = true ]; then
        DOWN_ARGS="-v" # -v 选项会自动清理 compose 文件中定义的所有数据卷
    fi

    # 根据是否启用本地 Redis 执行 down
    if [ "$USE_LOCAL_REDIS" = true ]; then
        echo -e "${YELLOW}使用本地内置 Redis 容器 Profile 停止集群...${NC}"
        $COMPOSE_CMD --profile with-redis $COMPOSE_FILES down $DOWN_ARGS
    else
        $COMPOSE_CMD $COMPOSE_FILES down $DOWN_ARGS
    fi
    echo -e "${GREEN}✓ 容器集群已成功下线并移除${NC}\n"
else
    echo -e "${YELLOW}⚠️ 未找到 Docker Compose，跳过容器销毁步骤，请手动清理。${NC}\n"
fi

# 5. 镜像清理
if [ "$CLEAN_IMAGES" = true ]; then
    echo -e "${BLUE}2. 正在清理本机的 Docker 镜像...${NC}"
    
    if [ "$IMAGE_SOURCE_VAL" = "local" ] && [ -n "$COMPOSE_CMD" ]; then
        echo -e "${YELLOW}正在清理本地构建的镜像产物...${NC}"
        COMPOSE_FILES="-f docker-compose.yml"
        if [ -f docker-compose.build.yml ]; then
            COMPOSE_FILES="-f docker-compose.yml -f docker-compose.build.yml"
        fi
        if [ "$USE_LOCAL_REDIS" = true ]; then
            $COMPOSE_CMD --profile with-redis $COMPOSE_FILES down --rmi local 2>/dev/null || true
        else
            $COMPOSE_CMD $COMPOSE_FILES down --rmi local 2>/dev/null || true
        fi
    else
        # 远程镜像，直接删除主要的核心镜像
        REGISTRY_VAL="ghcr.io/tokenlive"
        VERSION_VAL="latest"
        if [ -f .env ]; then
            REGISTRY_VAL=$(grep "^REGISTRY=" .env | cut -d= -f2- || echo "ghcr.io/tokenlive")
            VERSION_VAL=$(grep "^VERSION=" .env | cut -d= -f2- || echo "latest")
        fi
        
        echo -e "${YELLOW}正在清理远程拉取的业务镜像...${NC}"
        docker rmi "${REGISTRY_VAL}/tokenlive-gateway:${VERSION_VAL}" "${REGISTRY_VAL}/tokenlive-admin:${VERSION_VAL}" 2>/dev/null || true
    fi
    echo -e "${GREEN}✓ 镜像清理完成${NC}\n"
fi

# 6. 清理本地配置文件
if [ "$CLEAN_ENV" = true ]; then
    echo -e "${BLUE}3. 正在清理配置文件...${NC}"
    if [ -f .env ]; then
        rm -f .env
        echo -e "${GREEN}✓ 本地 .env 文件已删除${NC}\n"
    else
        echo -e "${YELLOW}未检测到 .env 配置文件，跳过。${NC}\n"
    fi
fi

echo -e "${GREEN}===============================================${NC}"
echo -e "         TokenLive 一键卸载流程执行完毕！       "
echo -e "${GREEN}===============================================${NC}"
