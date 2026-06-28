#!/bin/bash

# ===========================================
# TokenLive 镜像构建脚本
# ===========================================

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置
REGISTRY=${REGISTRY:-"ghcr.io/chenzhiguo"}
VERSION=${VERSION:-"latest"}

# 检测项目目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ADMIN_DIR=${ADMIN_DIR:-"$(cd "$SCRIPT_DIR/../tokenlive-admin" && pwd)"}
GATEWAY_DIR=${GATEWAY_DIR:-"$(cd "$SCRIPT_DIR/../tokenlive-gateway" && pwd)"}

# 打印帮助
print_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --admin            只构建 Admin 镜像"
    echo "  --gateway          只构建 Gateway 镜像"
    echo "  --push             构建后推送到镜像仓库"
    echo "  --registry URL     镜像仓库地址 (默认: $REGISTRY)"
    echo "  --version TAG      镜像版本 (默认: $VERSION)"
    echo "  --help             显示帮助信息"
    echo ""
    echo "Examples:"
    echo "  $0                          # 构建所有镜像"
    echo "  $0 --admin                  # 只构建 Admin 镜像"
    echo "  $0 --push                   # 构建并推送"
    echo "  $0 --registry docker.io/myuser --version v1.0.0"
}

# 解析参数
BUILD_ADMIN=true
BUILD_GATEWAY=true
PUSH_IMAGES=false

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --admin)
            BUILD_GATEWAY=false
            shift
            ;;
        --gateway)
            BUILD_ADMIN=false
            shift
            ;;
        --push)
            PUSH_IMAGES=true
            shift
            ;;
        --registry)
            REGISTRY="$2"
            shift 2
            ;;
        --version)
            VERSION="$2"
            shift 2
            ;;
        --help)
            print_help
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            print_help
            exit 1
            ;;
    esac
done

# 验证项目目录
verify_directories() {
    if [ "$BUILD_ADMIN" = true ]; then
        if [ ! -d "$ADMIN_DIR" ]; then
            echo -e "${RED}Admin directory not found: $ADMIN_DIR${NC}"
            echo -e "${YELLOW}Please set ADMIN_DIR environment variable to the correct path${NC}"
            exit 1
        fi
        if [ ! -f "$ADMIN_DIR/Dockerfile" ]; then
            echo -e "${RED}Admin Dockerfile not found: $ADMIN_DIR/Dockerfile${NC}"
            exit 1
        fi
        echo -e "${BLUE}Admin directory: $ADMIN_DIR${NC}"
    fi

    if [ "$BUILD_GATEWAY" = true ]; then
        if [ ! -d "$GATEWAY_DIR" ]; then
            echo -e "${RED}Gateway directory not found: $GATEWAY_DIR${NC}"
            echo -e "${YELLOW}Please set GATEWAY_DIR environment variable to the correct path${NC}"
            exit 1
        fi
        if [ ! -f "$GATEWAY_DIR/deploy/build/Dockerfile" ]; then
            echo -e "${RED}Gateway Dockerfile not found: $GATEWAY_DIR/deploy/build/Dockerfile${NC}"
            exit 1
        fi
        echo -e "${BLUE}Gateway directory: $GATEWAY_DIR${NC}"
    fi
}

# 构建 Admin 镜像
build_admin() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Building Admin Image...${NC}"
    echo -e "${BLUE}========================================${NC}"

    cd "$ADMIN_DIR"

    # 构建镜像
    if ! docker build -t "${REGISTRY}/tokenlive-admin:${VERSION}" .; then
        echo -e "${RED}Failed to build Admin image${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Admin image built: ${REGISTRY}/tokenlive-admin:${VERSION}${NC}"
}

# 构建 Gateway 镜像
build_gateway() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Building Gateway Image...${NC}"
    echo -e "${BLUE}========================================${NC}"

    cd "$GATEWAY_DIR"

    # 构建镜像
    if ! docker build -f deploy/build/Dockerfile --build-arg APP_RELATIVE_PATH="./cmd/server" -t "${REGISTRY}/tokenlive-gateway:${VERSION}" .; then
        echo -e "${RED}Failed to build Gateway image${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Gateway image built: ${REGISTRY}/tokenlive-gateway:${VERSION}${NC}"
}

# 推送镜像
push_images() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Pushing Images...${NC}"
    echo -e "${BLUE}========================================${NC}"

    if [ "$BUILD_ADMIN" = true ]; then
        echo -e "${BLUE}Pushing Admin image...${NC}"
        if ! docker push "${REGISTRY}/tokenlive-admin:${VERSION}"; then
            echo -e "${RED}Failed to push Admin image${NC}"
            exit 1
        fi
        echo -e "${GREEN}✓ Admin image pushed${NC}"
    fi

    if [ "$BUILD_GATEWAY" = true ]; then
        echo -e "${BLUE}Pushing Gateway image...${NC}"
        if ! docker push "${REGISTRY}/tokenlive-gateway:${VERSION}"; then
            echo -e "${RED}Failed to push Gateway image${NC}"
            exit 1
        fi
        echo -e "${GREEN}✓ Gateway image pushed${NC}"
    fi
}

# 主函数
main() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  TokenLive Image Build Script${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "Registry: ${REGISTRY}"
    echo -e "Version: ${VERSION}"

    verify_directories

    if [ "$BUILD_ADMIN" = true ]; then
        build_admin
    fi

    if [ "$BUILD_GATEWAY" = true ]; then
        build_gateway
    fi

    if [ "$PUSH_IMAGES" = true ]; then
        push_images
    fi

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Build Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    if [ "$PUSH_IMAGES" = false ]; then
        echo "To push images, run:"
        echo "  $0 --push"
        echo ""
    fi
    echo "To use the built images in Docker Compose:"
    echo "  1. Update docker-compose.yml with your image tags"
    echo "  2. Run: docker compose up -d"
    echo ""
}

# 运行主函数
main
