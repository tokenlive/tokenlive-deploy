#!/bin/bash

# ===========================================
# TokenLive 一键引导安装与部署脚本
# ===========================================

set -e

# 颜色输出定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 脚本目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

echo -e "${GREEN}"
echo "=================================================="
echo "         TokenLive 一键安装与配置向导             "
echo "=================================================="
echo -e "${NC}"

# 1. 检查 Docker 环境
if ! command -v docker &> /dev/null; then
    echo -e "${RED}✗ 未检测到 Docker，请先安装 Docker 以继续。${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Docker 已安装${NC}"

# 检查 Docker Compose
COMPOSE_CMD=""
if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &> /dev/null; then
    COMPOSE_CMD="docker-compose"
else
    echo -e "${RED}✗ 未检测到 Docker Compose，请先安装。${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Docker Compose 已安装 (${COMPOSE_CMD})${NC}"
echo ""

# 2. 辅助随机字符生成函数
generate_random_string() {
    local length=$1
    if command -v openssl &> /dev/null; then
        openssl rand -hex "$((length / 2))"
    else
        # 备选方案，过滤特殊字符，只保留数字字母
        tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$length" 2>/dev/null || echo "tokenlive_secret_${RANDOM}"
    fi
}

# 3. 配置文件存在检查与更新选项
RECONFIGURE=true
UPGRADE_MODE=false
if [ -f .env ]; then
    echo -e "${YELLOW}检测到已存在配置文件 .env${NC}"
    echo "请选择操作："
    echo "  1) 重新运行配置向导并部署 (覆盖现有 .env) [默认]"
    echo "  2) 一键更新版本 (保留现有配置，删除本机容器与旧镜像，拉取最新镜像启动)"
    echo "  3) 直接基于现有配置启动 (不拉取/不更新，直接启动)"
    read -r -p "请选择 [默认: 1]: " action_choice
    action_choice=${action_choice:-1}
    
    case "$action_choice" in
        2)
            RECONFIGURE=false
            UPGRADE_MODE=true
            ;;
        3)
            RECONFIGURE=false
            UPGRADE_MODE=false
            ;;
        *)
            RECONFIGURE=true
            UPGRADE_MODE=false
            ;;
    esac
fi

# 4. 进入交互配置向导
if [ "$RECONFIGURE" = true ]; then
    # 自动生成随机安全密钥
    RANDOM_PASS=$(generate_random_string 12)
    RANDOM_SYNC_TOKEN=$(generate_random_string 32)

    # 4.1 镜像来源配置
    echo -e "${CYAN}--- 镜像来源配置 ---${NC}"
    echo "请选择您的容器镜像来源："
    echo "  1) 官方预构建镜像 [默认] (从 Github 仓库 ghcr.io 拉取，适合直接部署)"
    echo "  2) 本地源码构建          (从本地的同级源码目录进行编译构建，适合开发调试)"
    read -r -p "请选择 [默认: 1]: " img_choice
    img_choice=${img_choice:-1}
    IMAGE_SOURCE="remote"
    if [ "$img_choice" = "2" ]; then
        IMAGE_SOURCE="local"
        # 校验同级目录源码是否存在
        if [ ! -d "../tokenlive-admin" ] || [ ! -d "../tokenlive-gateway" ]; then
            echo -e "${RED}✗ 未在同级目录下找到 tokenlive-admin 或 tokenlive-gateway 源码目录。${NC}"
            echo -e "${YELLOW}使用本地构建必须确保目录结构为：${NC}"
            echo -e "  ├── tokenlive-admin/"
            echo -e "  ├── tokenlive-gateway/"
            echo -e "  └── tokenlive-deploy/ (当前所在目录)"
            read -r -p "是否强制继续使用本地构建？ [y/N]: " force_local
            case "$force_local" in
                [yY][eE][sS]|[yY]) ;;
                *) exit 1 ;;
            esac
        fi
    fi
    echo ""

    # 4.2 域名配置
    echo -e "${CYAN}--- 域名与网络配置 ---${NC}"
    echo "如果您有已解析的域名，可以配置自动申请免费 HTTPS 证书；留空则使用 HTTP 协议 IP 访问。"
    read -r -p "请输入部署域名 (例如: api.tokenlive.com) [留空使用IP访问]: " DOMAIN
    
    # 4.3 端口配置
    read -r -p "请输入 HTTP 端口 [默认: 80]: " HTTP_PORT
    HTTP_PORT=${HTTP_PORT:-80}

    # 如果输入了域名，才配置 HTTPS 端口
    if [ -n "$DOMAIN" ]; then
        read -r -p "请输入 HTTPS 端口 [默认: 443]: " HTTPS_PORT
        HTTPS_PORT=${HTTPS_PORT:-443}
    fi
    echo ""

    # 4.4 管理员初始密码配置
    echo -e "${CYAN}--- 管理后台安全配置 ---${NC}"
    read -r -p "请输入管理员初始密码 (admin 账号) [回车自动使用随机强密码: ${RANDOM_PASS}]: " ADMIN_PASSWORD
    ADMIN_PASSWORD=${ADMIN_PASSWORD:-$RANDOM_PASS}
    echo ""

    # 4.5 高级配置模式判断
    ADVANCED=false
    read -r -p "是否需要进入高级配置模式 (配置外置数据库、外部 Redis 等)？ [y/N]: " adv_choice
    case "$adv_choice" in
        [yY][eE][sS]|[yY])
            ADVANCED=true
            echo -e "${YELLOW}已进入高级配置模式。${NC}\n"
            ;;
        *)
            ;;
    esac

    # 默认值初始化
    DB_TYPE="sqlite3"
    DB_DSN="/data/admin.db"
    REDIS_ENABLED=false
    GATEWAY_SYNC_TOKEN=$RANDOM_SYNC_TOKEN

    if [ "$ADVANCED" = true ]; then
        # 4.5.1 数据库高级配置
        echo -e "${CYAN}--- 高级配置：数据库设置 ---${NC}"
        echo "请选择数据库类型："
        echo "  1) sqlite3 (内置本地文件数据库，推荐)"
        echo "  2) mysql   (外置 MySQL 数据库)"
        echo "  3) postgres(外置 PostgreSQL 数据库)"
        read -r -p "请输入选项 [默认: 1]: " db_choice
        
        case "$db_choice" in
            2)
                DB_TYPE="mysql"
                read -r -p "  请输入数据库主机 (Host) [默认: 127.0.0.1]: " DB_HOST
                DB_HOST=${DB_HOST:-"127.0.0.1"}
                read -r -p "  请输入数据库端口 (Port) [默认: 3306]: " DB_PORT
                DB_PORT=${DB_PORT:-"3306"}
                read -r -p "  请输入数据库用户名 (User) [默认: root]: " DB_USER
                DB_USER=${DB_USER:-"root"}
                read -r -s -p "  请输入数据库密码 (Password): " DB_PASS
                echo ""
                read -r -p "  请输入数据库名称 (Database) [默认: tokenlive]: " DB_NAME
                DB_NAME=${DB_NAME:-"tokenlive"}
                DB_DSN="${DB_USER}:${DB_PASS}@tcp(${DB_HOST}:${DB_PORT})/${DB_NAME}?charset=utf8mb4&parseTime=True&loc=Local"
                ;;
            3)
                DB_TYPE="postgresql"
                read -r -p "  请输入数据库主机 (Host) [默认: 127.0.0.1]: " DB_HOST
                DB_HOST=${DB_HOST:-"127.0.0.1"}
                read -r -p "  请输入数据库端口 (Port) [默认: 5432]: " DB_PORT
                DB_PORT=${DB_PORT:-"5432"}
                read -r -p "  请输入数据库用户名 (User) [默认: postgres]: " DB_USER
                DB_USER=${DB_USER:-"postgres"}
                read -r -s -p "  请输入数据库密码 (Password): " DB_PASS
                echo ""
                read -r -p "  请输入数据库名称 (Database) [默认: tokenlive]: " DB_NAME
                DB_NAME=${DB_NAME:-"tokenlive"}
                DB_DSN="host=${DB_HOST} port=${DB_PORT} user=${DB_USER} password=${DB_PASS} dbname=${DB_NAME} sslmode=disable"
                ;;
            *)
                DB_TYPE="sqlite3"
                DB_DSN="/data/admin.db"
                ;;
        esac
        echo ""

        # 4.5.2 Redis 缓存配置
        echo -e "${CYAN}--- 高级配置：Redis 服务设置 ---${NC}"
        echo "启用 Redis 可支持网关横向扩容、多实例同步和持久化全局限流状态。"
        read -r -p "是否启用 Redis 缓存服务？ [y/N]: " redis_choice
        case "$redis_choice" in
            [yY][eE][sS]|[yY])
                REDIS_ENABLED=true
                read -r -p "  请输入 Redis 连接地址 (Host:Port) [默认: redis:6379]: " REDIS_ADDR
                REDIS_ADDR=${REDIS_ADDR:-"redis:6379"}
                read -r -s -p "  请输入 Redis 连接密码 [默认空]: " REDIS_PASSWORD
                echo ""
                read -r -p "  请输入 Redis 数据库库号 (DB) [默认: 0]: " REDIS_DB
                REDIS_DB=${REDIS_DB:-"0"}
                ;;
            *)
                ;;
        esac
        echo ""

        # 4.5.3 同步安全 Token 配置
        echo -e "${CYAN}--- 高级配置：网关内部同步安全设置 ---${NC}"
        read -r -p "自定义网关同步密钥 (GATEWAY_SYNC_TOKEN) [直接回车使用自动生成的随机安全密钥]: " user_token
        if [ -n "$user_token" ]; then
            GATEWAY_SYNC_TOKEN=$user_token
        fi
        echo ""
    fi

    # 5. 生成配置文件 .env
    echo -e "${BLUE}正在生成 .env 配置文件...${NC}"
    
    cat << EOF > .env
# ===========================================
# TokenLive 一键部署配置 (由 install.sh 自动生成)
# ===========================================

# ------------------------------
# 基础配置
# ------------------------------
IMAGE_SOURCE=${IMAGE_SOURCE}
DOMAIN=${DOMAIN}
HTTP_PORT=${HTTP_PORT}
HTTPS_PORT=${HTTPS_PORT:-443}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
DB_TYPE=${DB_TYPE}
DB_DSN=${DB_DSN}
GATEWAY_SYNC_TOKEN=${GATEWAY_SYNC_TOKEN}

# ------------------------------
# Gateway 核心配置
# ------------------------------
GATEWAY_PORT=8000
GATEWAY_API_KEY=your-api-key-here
DB_DRIVER=sqlite
DB_DSN_GATEWAY=/data/gateway.db

# ------------------------------
# Redis 状态共享与缓存配置
# ------------------------------
EOF

    if [ "$REDIS_ENABLED" = true ]; then
        cat << EOF >> .env
GATEWAY_CONFIG_SOURCE=redis
GATEWAY_STATE_STORE=redis
REDIS_ADDR=${REDIS_ADDR}
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_DB=${REDIS_DB}
EOF
    else
        cat << EOF >> .env
# GATEWAY_CONFIG_SOURCE=http
# GATEWAY_STATE_STORE=memory
# REDIS_ADDR=redis:6379
# REDIS_PASSWORD=
# REDIS_DB=0
EOF
    fi

    cat << EOF >> .env

# ------------------------------
# 高级系统配置
# ------------------------------
ADMIN_URL=http://admin:8040
ADMIN_PORT=8040
LOG_LEVEL=info
EOF

    echo -e "${GREEN}✓ .env 配置文件已就绪${NC}\n"
fi

# 6. 配置展示与确认启动
echo -e "${GREEN}==================================================${NC}"
echo -e "                 配置概要汇总                     "
echo -e "${GREEN}==================================================${NC}"
IMAGE_SOURCE_VAL=$(grep "^IMAGE_SOURCE=" .env | cut -d= -f2-)
if [ "$IMAGE_SOURCE_VAL" = "local" ]; then
    echo -e "  镜像来源:      ${YELLOW}本地源码实时构建 (Local Build)${NC}"
else
    echo -e "  镜像来源:      预构建官方镜像 (ghcr.io)"
fi
if [ -n "$(grep "^DOMAIN=" .env | cut -d= -f2-)" ]; then
    echo -e "  部署域名:      https://$(grep "^DOMAIN=" .env | cut -d= -f2-)"
else
    echo -e "  部署模式:      使用 HTTP 本地/内网 IP 访问"
fi
echo -e "  HTTP 端口:     $(grep "^HTTP_PORT=" .env | cut -d= -f2-)"
if grep -q "^HTTPS_PORT=" .env; then
    echo -e "  HTTPS 端口:    $(grep "^HTTPS_PORT=" .env | cut -d= -f2-)"
fi
echo -e "  数据库类型:    $(grep "^DB_TYPE=" .env | cut -d= -f2-)"
if grep -q "^REDIS_ADDR=" .env; then
    echo -e "  Redis 缓存:    已启用 (${YELLOW}$(grep "^REDIS_ADDR=" .env | cut -d= -f2-)${NC})"
else
    echo -e "  Redis 缓存:    未启用 (单机内存模式)"
fi
echo -e "  管理员账号:    admin"
echo -e "  管理员密码:    ${YELLOW}$(grep "^ADMIN_PASSWORD=" .env | cut -d= -f2-)${NC} (请务必牢记)"
echo -e "${GREEN}==================================================${NC}\n"

# 7. 一键拉取镜像与部署启动
if [ "$UPGRADE_MODE" = true ]; then
    read -r -p "确认要更新版本吗？这会停止并删除本机的旧容器和镜像，并拉取/构建最新版启动。 [Y/n]: " upgrade_choice
    upgrade_choice=${upgrade_choice:-"Y"}
    case "$upgrade_choice" in
        [yY][eE][sS]|[yY])
            IMAGE_SOURCE_VAL=$(grep "^IMAGE_SOURCE=" .env | cut -d= -f2-)
            USE_LOCAL_REDIS=false
            if grep -q "^REDIS_ADDR=" .env; then
                REDIS_ADDR_VAL=$(grep "^REDIS_ADDR=" .env | cut -d= -f2-)
                if [ "$REDIS_ADDR_VAL" = "redis:6379" ] || [ "$REDIS_ADDR_VAL" = "redis" ] || [[ "$REDIS_ADDR_VAL" =~ ^redis: ]]; then
                    USE_LOCAL_REDIS=true
                fi
            fi

            COMPOSE_FILES="-f docker-compose.yml"
            if [ "$IMAGE_SOURCE_VAL" = "local" ]; then
                COMPOSE_FILES="-f docker-compose.yml -f docker-compose.build.yml"
            fi
            
            echo -e "${YELLOW}正在停止并清理现有容器集群...${NC}"
            if [ "$USE_LOCAL_REDIS" = true ]; then
                $COMPOSE_CMD --profile with-redis $COMPOSE_FILES down
            else
                $COMPOSE_CMD $COMPOSE_FILES down
            fi
            
            if [ "$IMAGE_SOURCE_VAL" = "local" ]; then
                echo -e "${YELLOW}检测到使用本地构建，正在清理本地旧镜像产物...${NC}"
                if [ "$USE_LOCAL_REDIS" = true ]; then
                    $COMPOSE_CMD --profile with-redis $COMPOSE_FILES down --rmi local
                else
                    $COMPOSE_CMD $COMPOSE_FILES down --rmi local
                fi
                
                echo -e "${BLUE}正在重新编译并启动本地容器...${NC}"
                if [ "$USE_LOCAL_REDIS" = true ]; then
                    $COMPOSE_CMD --profile with-redis $COMPOSE_FILES up -d --build
                else
                    $COMPOSE_CMD $COMPOSE_FILES up -d --build
                fi
            else
                echo -e "${YELLOW}正在删除本地的 TokenLive 核心远程镜像...${NC}"
                REGISTRY_VAL=$(grep "^REGISTRY=" .env | cut -d= -f2-)
                REGISTRY_VAL=${REGISTRY_VAL:-"ghcr.io/tokenlive"}
                VERSION_VAL=$(grep "^VERSION=" .env | cut -d= -f2-)
                VERSION_VAL=${VERSION_VAL:-"latest"}
                
                docker rmi "${REGISTRY_VAL}/tokenlive-gateway:${VERSION_VAL}" "${REGISTRY_VAL}/tokenlive-admin:${VERSION_VAL}" 2>/dev/null || true
                
                echo -e "${BLUE}正在拉取最新 Docker 镜像并启动...${NC}"
                if [ "$USE_LOCAL_REDIS" = true ]; then
                    $COMPOSE_CMD --profile with-redis pull
                    $COMPOSE_CMD --profile with-redis $COMPOSE_FILES up -d
                else
                    $COMPOSE_CMD pull
                    $COMPOSE_CMD $COMPOSE_FILES up -d
                fi
            fi
            
            echo -e "\n${GREEN}==========================================${NC}"
            echo -e "  ${GREEN}✓ TokenLive 版本更新启动成功！${NC}"
            echo -e "${GREEN}==========================================${NC}"
            exit 0
            ;;
        *)
            echo -e "${YELLOW}更新已被取消。${NC}"
            exit 0
            ;;
    esac
fi

read -r -p "是否立即启动部署？ [Y/n]: " deploy_choice
deploy_choice=${deploy_choice:-"Y"}

case "$deploy_choice" in
    [yY][eE][sS]|[yY])
        # 准备数据目录
        mkdir -p caddy gateway/config

        IMAGE_SOURCE_VAL=$(grep "^IMAGE_SOURCE=" .env | cut -d= -f2-)
        USE_LOCAL_REDIS=false
        if grep -q "^REDIS_ADDR=" .env; then
            REDIS_ADDR_VAL=$(grep "^REDIS_ADDR=" .env | cut -d= -f2-)
            if [ "$REDIS_ADDR_VAL" = "redis:6379" ] || [ "$REDIS_ADDR_VAL" = "redis" ] || [[ "$REDIS_ADDR_VAL" =~ ^redis: ]]; then
                USE_LOCAL_REDIS=true
            fi
        fi
        
        # 拼装 docker compose 配置文件列表
        COMPOSE_FILES="-f docker-compose.yml"
        if [ "$IMAGE_SOURCE_VAL" = "local" ]; then
            COMPOSE_FILES="-f docker-compose.yml -f docker-compose.build.yml"
        fi

        # 启动命令根据是否使用 Redis 以及镜像来源动态组装
        START_CMD="$COMPOSE_CMD $COMPOSE_FILES up -d"
        if [ "$IMAGE_SOURCE_VAL" = "local" ]; then
            START_CMD="$COMPOSE_CMD $COMPOSE_FILES up -d --build"
        fi

        if [ "$USE_LOCAL_REDIS" = true ]; then
            echo -e "${YELLOW}检测到使用本地 Redis 服务，将包含 with-redis Profile 运行...${NC}"
            START_CMD="$COMPOSE_CMD --profile with-redis $COMPOSE_FILES up -d"
            if [ "$IMAGE_SOURCE_VAL" = "local" ]; then
                START_CMD="$COMPOSE_CMD --profile with-redis $COMPOSE_FILES up -d --build"
            fi
        fi

        # 拉取镜像 (只有在使用官方预构建镜像时才拉取，本地构建跳过)
        if [ "$IMAGE_SOURCE_VAL" != "local" ]; then
            echo -e "${BLUE}==========================================${NC}"
            echo -e "${BLUE}  正在拉取最新 Docker 镜像...             ${NC}"
            echo -e "${BLUE}==========================================${NC}"
            if [ "$USE_LOCAL_REDIS" = true ]; then
                $COMPOSE_CMD --profile with-redis pull
            else
                $COMPOSE_CMD pull
            fi
        fi

        echo -e "\n${BLUE}==========================================${NC}"
        echo -e "${BLUE}  正在启动 TokenLive 容器集群...          ${NC}"
        echo -e "${BLUE}==========================================${NC}"
        eval "$START_CMD"

        echo -e "\n${GREEN}==========================================${NC}"
        echo -e "  ${GREEN}✓ TokenLive 部署成功！${NC}"
        echo -e "${GREEN}==========================================${NC}"
        
        # 结果输出
        FINAL_DOMAIN=$(grep "^DOMAIN=" .env | cut -d= -f2-)
        FINAL_HTTP_PORT=$(grep "^HTTP_PORT=" .env | cut -d= -f2-)
        
        echo ""
        echo "服务访问地址："
        if [ -n "$FINAL_DOMAIN" ]; then
            echo -e "  - Admin 后台:  ${CYAN}https://${FINAL_DOMAIN}${NC}"
            echo -e "  - Gateway API: ${CYAN}https://${FINAL_DOMAIN}/v1${NC}"
        else
            if [ "$FINAL_HTTP_PORT" = "80" ]; then
                echo -e "  - Admin 后台:  ${CYAN}http://localhost${NC}"
                echo -e "  - Gateway API: ${CYAN}http://localhost/v1${NC}"
            else
                echo -e "  - Admin 后台:  ${CYAN}http://localhost:${FINAL_HTTP_PORT}${NC}"
                echo -e "  - Gateway API: ${CYAN}http://localhost:${FINAL_HTTP_PORT}/v1${NC}"
            fi
        fi
        
        echo ""
        echo "默认管理账号："
        echo "  - 用户名: admin"
        echo -e "  - 密  码: ${YELLOW}$(grep "^ADMIN_PASSWORD=" .env | cut -d= -f2-)${NC}"
        echo ""
        echo "常用运维命令："
        echo -e "  - 查看服务日志:  $COMPOSE_CMD $COMPOSE_FILES logs -f"
        echo -e "  - 重启所有服务:  $COMPOSE_CMD $COMPOSE_FILES restart"
        echo -e "  - 关闭所有服务:  $COMPOSE_CMD $COMPOSE_FILES down"
        echo ""
        ;;
    *)
        echo -e "${YELLOW}部署已被用户取消。${NC}"
        echo -e "您可以随时进入 ${CYAN}${SCRIPT_DIR}${NC} 目录下运行以下命令手动完成启动："
        IMAGE_SOURCE_VAL=$(grep "^IMAGE_SOURCE=" .env | cut -d= -f2-)
        USE_LOCAL_REDIS=false
        if grep -q "^REDIS_ADDR=" .env; then
            REDIS_ADDR_VAL=$(grep "^REDIS_ADDR=" .env | cut -d= -f2-)
            if [ "$REDIS_ADDR_VAL" = "redis:6379" ] || [ "$REDIS_ADDR_VAL" = "redis" ] || [[ "$REDIS_ADDR_VAL" =~ ^redis: ]]; then
                USE_LOCAL_REDIS=true
            fi
        fi

        COMPOSE_FILES="-f docker-compose.yml"
        if [ "$IMAGE_SOURCE_VAL" = "local" ]; then
            COMPOSE_FILES="-f docker-compose.yml -f docker-compose.build.yml"
        fi
        
        if [ "$USE_LOCAL_REDIS" = true ]; then
            if [ "$IMAGE_SOURCE_VAL" = "local" ]; then
                echo -e "  ${BLUE}$COMPOSE_CMD --profile with-redis $COMPOSE_FILES up -d --build${NC}"
            else
                echo -e "  ${BLUE}$COMPOSE_CMD --profile with-redis $COMPOSE_FILES up -d${NC}"
            fi
        else
            if [ "$IMAGE_SOURCE_VAL" = "local" ]; then
                echo -e "  ${BLUE}$COMPOSE_CMD $COMPOSE_FILES up -d --build${NC}"
            else
                echo -e "  ${BLUE}$COMPOSE_CMD $COMPOSE_FILES up -d${NC}"
            fi
        fi
        echo ""
        ;;
esac
