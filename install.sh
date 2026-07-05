#!/bin/bash

# ===========================================
# TokenLive 一键引导安装与部署脚本
# 支持: curl -fsSL https://raw.githubusercontent.com/tokenlive/tokenlive-deploy/main/install.sh | bash
# 也支持: 交互式向导 / 命令行参数 / 环境变量(TL_ 前缀) 非交互部署
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

# 默认配置
REPO="tokenlive/tokenlive-deploy"
BRANCH="main"
DEFAULT_INSTALL_DIR="$HOME/.tokenlive"

# 运行时变量(由参数/环境变量/交互填入)
INSTALL_DIR=""
DOMAIN=""
HTTP_PORT=""
HTTPS_PORT=""
ADMIN_PASSWORD=""
DB_TYPE=""
DB_DSN=""
REDIS_ENABLED=""
REDIS_ADDR=""
REDIS_PASSWORD=""
REDIS_DB=""
CLICKHOUSE_ENABLED=""
CLICKHOUSE_ADDR=""
CLICKHOUSE_DATABASE=""
CLICKHOUSE_USERNAME=""
CLICKHOUSE_PASSWORD=""
IMAGE_SOURCE=""
GATEWAY_SYNC_TOKEN=""
REGISTRY=""
VERSION=""
ADVANCED=""

# 行为标志
NONINTERACTIVE=false
UPGRADE_MODE=false
SKIP_START=false
ASSUME_YES=false
SKIP_DOCKER_INSTALL=false

# ===========================================
# 工具函数
# ===========================================

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}✓${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}✗${NC} $*" >&2; }
die()       { log_error "$*"; exit 1; }

# 生成随机字符串
generate_random_string() {
    local length=$1
    if command -v openssl &> /dev/null; then
        openssl rand -hex "$((length / 2))"
    else
        tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$length" 2>/dev/null || echo "tokenlive_secret_${RANDOM}"
    fi
}

# 下载文件(带错误处理)
download_file() {
    local url="$1"
    local dest="$2"
    local desc="$3"
    if command -v curl &> /dev/null; then
        curl -fsSL -o "$dest" "$url" || die "下载失败: $desc ($url)"
    elif command -v wget &> /dev/null; then
        wget -q -O "$dest" "$url" || die "下载失败: $desc ($url)"
    else
        die "需要 curl 或 wget 来下载文件，请先安装。"
    fi
}

# 判断是否任意配置参数已通过命令行/环境变量传入
has_explicit_config() {
    [ -n "$DOMAIN" ] || [ -n "$HTTP_PORT" ] || [ -n "$HTTPS_PORT" ] || \
    [ -n "$ADMIN_PASSWORD" ] || [ -n "$DB_TYPE" ] || [ -n "$DB_DSN" ] || \
    [ -n "$IMAGE_SOURCE" ] || [ -n "$GATEWAY_SYNC_TOKEN" ] || \
    [ -n "$REDIS_ENABLED" ] || [ -n "$REDIS_ADDR" ] || \
    [ -n "$REDIS_PASSWORD" ] || [ -n "$REDIS_DB" ] || \
    [ -n "$CLICKHOUSE_ENABLED" ] || [ -n "$CLICKHOUSE_ADDR" ] || [ -n "$CLICKHOUSE_DATABASE" ] || \
    [ -n "$CLICKHOUSE_USERNAME" ] || [ -n "$CLICKHOUSE_PASSWORD" ] || \
    [ -n "$REGISTRY" ] || [ -n "$VERSION" ]
}

# ===========================================
# 参数解析
# ===========================================

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --domain)        DOMAIN="$2"; shift 2 ;;
            --http-port)     HTTP_PORT="$2"; shift 2 ;;
            --https-port)    HTTPS_PORT="$2"; shift 2 ;;
            --password)      ADMIN_PASSWORD="$2"; shift 2 ;;
            --db-type)       DB_TYPE="$2"; shift 2 ;;
            --db-dsn)        DB_DSN="$2"; shift 2 ;;
            --image-source)  IMAGE_SOURCE="$2"; shift 2 ;;
            --sync-token)    GATEWAY_SYNC_TOKEN="$2"; shift 2 ;;
            --registry)      REGISTRY="$2"; shift 2 ;;
            --version)       VERSION="$2"; shift 2 ;;
            --redis)         REDIS_ENABLED="true"; shift ;;
            --redis-addr)    REDIS_ADDR="$2"; REDIS_ENABLED="true"; shift 2 ;;
            --redis-password) REDIS_PASSWORD="$2"; shift 2 ;;
            --redis-db)      REDIS_DB="$2"; shift 2 ;;
            --clickhouse)     CLICKHOUSE_ENABLED="true"; shift ;;
            --clickhouse-addr) CLICKHOUSE_ADDR="$2"; CLICKHOUSE_ENABLED="true"; shift 2 ;;
            --clickhouse-database) CLICKHOUSE_DATABASE="$2"; shift 2 ;;
            --clickhouse-username) CLICKHOUSE_USERNAME="$2"; shift 2 ;;
            --clickhouse-password) CLICKHOUSE_PASSWORD="$2"; shift 2 ;;
            --install-dir)   INSTALL_DIR="$2"; shift 2 ;;
            --repo)          REPO="$2"; shift 2 ;;
            --branch)        BRANCH="$2"; shift 2 ;;
            --upgrade)       UPGRADE_MODE=true; shift ;;
            --no-start)      SKIP_START=true; shift ;;
            --yes|-y)        ASSUME_YES=true; shift ;;
            --no-docker-install) SKIP_DOCKER_INSTALL=true; shift ;;
            --advanced)      ADVANCED="true"; shift ;;
            --help|-h)
                cat <<'EOF'
TokenLive 一键安装脚本

用法:
  交互式:   curl -fsSL <url> | bash
  非交互式: bash install.sh --domain api.xxx.com --password xxx --yes
  环境变量: TL_DOMAIN=api.xxx.com TL_ADMIN_PASSWORD=xxx bash install.sh

参数:
  --domain DOMAIN         部署域名(留空用 IP 访问)
  --http-port PORT        HTTP 端口 (默认 80)
  --https-port PORT       HTTPS 端口 (默认 443)
  --password PASS         管理员密码 (默认随机)
  --db-type TYPE          sqlite3|mysql|postgresql (默认 sqlite3)
  --db-dsn DSN            外置数据库 DSN (配合 --db-type)
  --image-source SRC      remote|local (默认 remote)
  --redis                 启用 Redis
  --redis-addr ADDR       Redis 地址 (默认 redis:6379)
  --redis-password PASS   Redis 密码
  --redis-db N            Redis 库号
  --clickhouse            启用外置 ClickHouse 访问日志写入
  --clickhouse-addr ADDR  ClickHouse 地址 (启用后必填，如 clickhouse.example.com:9000)
  --clickhouse-database DB ClickHouse 数据库名 (默认 tokenlive_gateway)
  --clickhouse-username USER ClickHouse 用户名 (默认 default)
  --clickhouse-password PASS ClickHouse 密码
  --sync-token TOKEN      网关同步密钥 (默认随机)
  --registry URL          镜像仓库 (默认 ghcr.io/tokenlive)
  --version VER           镜像版本 (默认 latest)
  --install-dir DIR       安装目录 (默认 ~/.tokenlive)
  --repo REPO             仓库地址 (默认 tokenlive/tokenlive-deploy)
  --branch BRANCH         仓库分支 (默认 main)
  --upgrade               升级模式(保留配置,拉新镜像)
  --no-start              只生成配置不启动
  --yes/-y                跳过所有确认
  --no-docker-install     不自动安装 Docker
  --advanced              强制进入高级配置(交互模式)
  --help/-h               显示帮助

环境变量(TL_ 前缀, 优先级低于命令行参数):
  TL_DOMAIN, TL_HTTP_PORT, TL_HTTPS_PORT, TL_ADMIN_PASSWORD,
  TL_DB_TYPE, TL_DB_DSN, TL_IMAGE_SOURCE, TL_GATEWAY_SYNC_TOKEN,
  TL_REDIS_ENABLED, TL_REDIS_ADDR, TL_REDIS_PASSWORD, TL_REDIS_DB,
  TL_CLICKHOUSE_ENABLED, TL_CLICKHOUSE_ADDR, TL_CLICKHOUSE_DATABASE,
  TL_CLICKHOUSE_USERNAME, TL_CLICKHOUSE_PASSWORD,
  TL_REGISTRY, TL_VERSION, TL_INSTALL_DIR, TL_REPO, TL_BRANCH
EOF
                exit 0 ;;
            *)
                die "未知参数: $1 (使用 --help 查看帮助)" ;;
        esac
    done
}

# 从环境变量读取(TL_ 前缀),仅在命令行未指定时
load_env_vars() {
    [ -z "$DOMAIN" ]          && DOMAIN="${TL_DOMAIN:-}"
    [ -z "$HTTP_PORT" ]       && HTTP_PORT="${TL_HTTP_PORT:-}"
    [ -z "$HTTPS_PORT" ]      && HTTPS_PORT="${TL_HTTPS_PORT:-}"
    [ -z "$ADMIN_PASSWORD" ]  && ADMIN_PASSWORD="${TL_ADMIN_PASSWORD:-}"
    [ -z "$DB_TYPE" ]         && DB_TYPE="${TL_DB_TYPE:-}"
    [ -z "$DB_DSN" ]          && DB_DSN="${TL_DB_DSN:-}"
    [ -z "$IMAGE_SOURCE" ]    && IMAGE_SOURCE="${TL_IMAGE_SOURCE:-}"
    [ -z "$GATEWAY_SYNC_TOKEN" ] && GATEWAY_SYNC_TOKEN="${TL_GATEWAY_SYNC_TOKEN:-}"
    [ -z "$REDIS_ADDR" ]      && REDIS_ADDR="${TL_REDIS_ADDR:-}"
    [ -z "$REDIS_PASSWORD" ]  && REDIS_PASSWORD="${TL_REDIS_PASSWORD:-}"
    [ -z "$REDIS_DB" ]        && REDIS_DB="${TL_REDIS_DB:-}"
    [ -z "$CLICKHOUSE_ADDR" ] && CLICKHOUSE_ADDR="${TL_CLICKHOUSE_ADDR:-}"
    [ -z "$CLICKHOUSE_DATABASE" ] && CLICKHOUSE_DATABASE="${TL_CLICKHOUSE_DATABASE:-}"
    [ -z "$CLICKHOUSE_USERNAME" ] && CLICKHOUSE_USERNAME="${TL_CLICKHOUSE_USERNAME:-}"
    [ -z "$CLICKHOUSE_PASSWORD" ] && CLICKHOUSE_PASSWORD="${TL_CLICKHOUSE_PASSWORD:-}"
    [ -z "$REGISTRY" ]        && REGISTRY="${TL_REGISTRY:-}"
    [ -z "$VERSION" ]         && VERSION="${TL_VERSION:-}"
    [ -z "$INSTALL_DIR" ]     && INSTALL_DIR="${TL_INSTALL_DIR:-}"
    [ -z "$REPO" ]            && REPO="${TL_REPO:-$REPO}"
    [ -z "$BRANCH" ]          && BRANCH="${TL_BRANCH:-$BRANCH}"
    # Redis 启用判断
    if [ -z "$REDIS_ENABLED" ] && [ "${TL_REDIS_ENABLED:-}" = "true" ]; then
        REDIS_ENABLED="true"
    fi
    if [ -z "$CLICKHOUSE_ENABLED" ] && [ "${TL_CLICKHOUSE_ENABLED:-}" = "true" ]; then
        CLICKHOUSE_ENABLED="true"
    fi
    if [ -z "$CLICKHOUSE_ENABLED" ] && [ -n "$CLICKHOUSE_ADDR" ]; then
        CLICKHOUSE_ENABLED="true"
    fi
}

# ===========================================
# Docker 检测与自动安装
# ===========================================

ensure_docker() {
    # 检测 docker
    if command -v docker &> /dev/null; then
        log_ok "Docker 已安装"
        # 验证 daemon 可用
        if ! docker info &> /dev/null; then
            log_warn "Docker daemon 未运行，尝试启动..."
            if command -v systemctl &> /dev/null; then
                sudo systemctl start docker 2>/dev/null || true
            elif [ "$(uname)" = "Darwin" ]; then
                log_warn "请手动启动 Docker Desktop 后重新运行此脚本"
                exit 1
            fi
            docker info &> /dev/null || die "Docker daemon 仍不可用，请手动启动 Docker 服务"
        fi
        return 0
    fi

    # 未安装
    if [ "$SKIP_DOCKER_INSTALL" = true ]; then
        die "未检测到 Docker 且已指定 --no-docker-install，请先安装 Docker。"
    fi

    if [ "$(uname)" = "Darwin" ]; then
        log_error "macOS 不支持自动安装 Docker，请手动安装 Docker Desktop:"
        log_error "  https://docs.docker.com/desktop/install/mac-install/"
        exit 1
    fi

    log_info "未检测到 Docker，开始自动安装..."
    if [ "$ASSUME_YES" = true ]; then
        curl -fsSL https://get.docker.com | sudo sh -s -- --dry-run >/dev/null 2>&1 || true
        curl -fsSL https://get.docker.com | sudo sh
    else
        echo -e "${YELLOW}即将通过 get.docker.com 官方脚本安装 Docker${NC}"
        read -r -p "是否继续? [Y/n]: " docker_confirm
        docker_confirm=${docker_confirm:-Y}
        case "$docker_confirm" in
            [yY][eE][sS]|[yY]) curl -fsSL https://get.docker.com | sudo sh ;;
            *) die "已取消 Docker 安装，无法继续" ;;
        esac
    fi

    # 启动 docker 服务
    if command -v systemctl &> /dev/null; then
        sudo systemctl enable docker 2>/dev/null || true
        sudo systemctl start docker 2>/dev/null || true
    fi

    # 加入 docker group(避免后续都要 sudo)
    if id -nG "$USER" | grep -qw docker; then
        :
    else
        sudo groupadd docker 2>/dev/null || true
        sudo usermod -aG docker "$USER" 2>/dev/null || true
        log_warn "已将当前用户加入 docker 组，需重新登录后生效。本次将使用 sudo 调用 docker。"
    fi

    # 重新检测
    if ! docker info &> /dev/null; then
        # 可能 group 未生效，测试 sudo docker
        if sudo docker info &> /dev/null; then
            log_warn "当前用户暂无 docker 权限，本脚本将使用 sudo 调用 docker。请重新登录后即可免 sudo。"
            DOCKER_SUDO="sudo"
        else
            die "Docker 安装后仍不可用，请检查 Docker 服务状态"
        fi
    fi
    log_ok "Docker 已就绪"
}

# 获取 compose 命令(考虑 sudo 前缀)
get_compose_cmd() {
    local prefix="${DOCKER_SUDO:-}"
    if ${prefix:+sudo }docker compose version &> /dev/null; then
        echo "${prefix:+sudo }docker compose"
    elif ${prefix:+sudo }command -v docker-compose &> /dev/null; then
        echo "${prefix:+sudo }docker-compose"
    else
        die "未检测到 Docker Compose，请安装 Docker Compose 插件。"
    fi
}

# ===========================================
# 工作目录与依赖文件准备
# ===========================================

prepare_workdir() {
    # 如果当前目录已有 docker-compose.yml,视为就地部署
    if [ -f "docker-compose.yml" ]; then
        INSTALL_DIR="$(pwd)"
        log_info "检测到当前目录已含部署文件，就地部署: $INSTALL_DIR"
        return 0
    fi

    # 否则使用 INSTALL_DIR(默认 ~/.tokenlive)
    INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    log_info "工作目录: $INSTALL_DIR"

    # 若工作目录已有 docker-compose.yml,无需下载
    if [ -f "docker-compose.yml" ]; then
        log_ok "部署文件已存在，跳过下载"
        return 0
    fi

    # 从 GitHub 下载所需文件
    local base_url="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
    log_info "正在从 GitHub 下载部署文件..."
    mkdir -p caddy gateway/config prometheus
    download_file "$base_url/docker-compose.yml"         "docker-compose.yml"         "docker-compose.yml"
    download_file "$base_url/docker-compose.build.yml"   "docker-compose.build.yml"   "docker-compose.build.yml"
    download_file "$base_url/caddy/Caddyfile"            "caddy/Caddyfile"            "Caddyfile"
    download_file "$base_url/gateway/config/default.yml" "gateway/config/default.yml" "gateway default.yml"
    download_file "$base_url/prometheus/prometheus.yml"  "prometheus/prometheus.yml"  "prometheus.yml"
    log_ok "部署文件下载完成"
}

# ===========================================
# 交互式配置向导
# ===========================================

interactive_wizard() {
    # 确保 read 能从 tty 读取(curl|bash 场景)
    if [ ! -t 0 ] && [ -t /dev/tty ]; then
        exec </dev/tty
    fi

    RANDOM_PASS=$(generate_random_string 12)
    RANDOM_SYNC_TOKEN=$(generate_random_string 32)

    echo -e "${CYAN}--- 镜像来源配置 ---${NC}"
    echo "请选择您的容器镜像来源："
    echo "  1) 官方预构建镜像 [默认] (从 ghcr.io 拉取，适合直接部署)"
    echo "  2) 本地源码构建          (从同级源码目录编译，适合开发调试)"
    read -r -p "请选择 [默认: 1]: " img_choice
    img_choice=${img_choice:-1}
    IMAGE_SOURCE="remote"
    if [ "$img_choice" = "2" ]; then
        IMAGE_SOURCE="local"
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

    echo -e "${CYAN}--- 域名与网络配置 ---${NC}"
    echo "如果您有已解析的域名，可以配置自动申请免费 HTTPS 证书；留空则使用 HTTP 协议 IP 访问。"
    [ -z "$DOMAIN" ] && read -r -p "请输入部署域名 (例如: api.tokenlive.com) [留空使用IP访问]: " DOMAIN
    [ -z "$HTTP_PORT" ] && read -r -p "请输入 HTTP 端口 [默认: 80]: " HTTP_PORT
    HTTP_PORT=${HTTP_PORT:-80}
    if [ -n "$DOMAIN" ] && [ -z "$HTTPS_PORT" ]; then
        read -r -p "请输入 HTTPS 端口 [默认: 443]: " HTTPS_PORT
    fi
    HTTPS_PORT=${HTTPS_PORT:-443}
    echo ""

    echo -e "${CYAN}--- 管理后台安全配置 ---${NC}"
    [ -z "$ADMIN_PASSWORD" ] && read -r -p "请输入管理员初始密码 (admin 账号) [回车自动使用随机强密码: ${RANDOM_PASS}]: " ADMIN_PASSWORD
    ADMIN_PASSWORD=${ADMIN_PASSWORD:-$RANDOM_PASS}
    echo ""

    # 默认值初始化(--advanced 传入时跳过询问直接进入高级)
    DB_TYPE=${DB_TYPE:-sqlite3}
    DB_DSN=${DB_DSN:-/data/admin.db}
    REDIS_ENABLED=${REDIS_ENABLED:-false}
    CLICKHOUSE_ENABLED=${CLICKHOUSE_ENABLED:-false}
    GATEWAY_SYNC_TOKEN=${GATEWAY_SYNC_TOKEN:-$RANDOM_SYNC_TOKEN}

    if [ "$ADVANCED" != "true" ]; then
        read -r -p "是否需要进入高级配置模式 (配置外置数据库、外部 Redis 等)？ [y/N]: " adv_choice
        case "$adv_choice" in
            [yY][eE][sS]|[yY])
                ADVANCED=true
                echo -e "${YELLOW}已进入高级配置模式。${NC}\n"
                ;;
        esac
    else
        echo -e "${YELLOW}已指定 --advanced，进入高级配置模式。${NC}\n"
    fi

    if [ "$ADVANCED" = true ]; then
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

        echo -e "${CYAN}--- 高级配置：Redis 服务设置 ---${NC}"
        echo "启用 Redis 可支持网关横向扩容、多实例同步和持久化全局限流状态。"
        if [ "$REDIS_ENABLED" != "true" ]; then
            read -r -p "是否启用 Redis 缓存服务？ [y/N]: " redis_choice
            case "$redis_choice" in
                [yY][eE][sS]|[yY]) REDIS_ENABLED=true ;;
            esac
        fi
        if [ "$REDIS_ENABLED" = true ]; then
            [ -z "$REDIS_ADDR" ] && read -r -p "  请输入 Redis 连接地址 (Host:Port) [默认: redis:6379]: " REDIS_ADDR
            REDIS_ADDR=${REDIS_ADDR:-"redis:6379"}
            [ -z "$REDIS_PASSWORD" ] && { read -r -s -p "  请输入 Redis 连接密码 [默认空]: " REDIS_PASSWORD; echo ""; }
            [ -z "$REDIS_DB" ] && read -r -p "  请输入 Redis 数据库库号 (DB) [默认: 0]: " REDIS_DB
            REDIS_DB=${REDIS_DB:-"0"}
        fi
        echo ""

        echo -e "${CYAN}--- 高级配置：ClickHouse 访问日志设置 ---${NC}"
        echo "启用 ClickHouse 后，网关会将访问日志写入外置 ClickHouse；脚本只写入连接配置，不安装 ClickHouse。"
        if [ "$CLICKHOUSE_ENABLED" != "true" ]; then
            read -r -p "是否启用 ClickHouse 访问日志写入？ [y/N]: " clickhouse_choice
            case "$clickhouse_choice" in
                [yY][eE][sS]|[yY]) CLICKHOUSE_ENABLED=true ;;
            esac
        fi
        if [ "$CLICKHOUSE_ENABLED" = true ]; then
            while [ -z "$CLICKHOUSE_ADDR" ]; do
                read -r -p "  请输入 ClickHouse 地址 (Host:Port，必填): " CLICKHOUSE_ADDR
                [ -n "$CLICKHOUSE_ADDR" ] || echo -e "${YELLOW}  启用 ClickHouse 时必须填写可从 Gateway 容器访问的地址。${NC}"
            done
            [ -z "$CLICKHOUSE_DATABASE" ] && read -r -p "  请输入 ClickHouse 数据库名 [默认: tokenlive_gateway]: " CLICKHOUSE_DATABASE
            CLICKHOUSE_DATABASE=${CLICKHOUSE_DATABASE:-"tokenlive_gateway"}
            [ -z "$CLICKHOUSE_USERNAME" ] && read -r -p "  请输入 ClickHouse 用户名 [默认: default]: " CLICKHOUSE_USERNAME
            CLICKHOUSE_USERNAME=${CLICKHOUSE_USERNAME:-"default"}
            [ -z "$CLICKHOUSE_PASSWORD" ] && { read -r -s -p "  请输入 ClickHouse 密码 [默认空]: " CLICKHOUSE_PASSWORD; echo ""; }
        fi
        echo ""

        echo -e "${CYAN}--- 高级配置：网关内部同步安全设置 ---${NC}"
        [ -z "$GATEWAY_SYNC_TOKEN" ] && read -r -p "自定义网关同步密钥 (GATEWAY_SYNC_TOKEN) [直接回车使用自动生成的随机安全密钥]: " user_token
        if [ -n "${user_token:-}" ]; then
            GATEWAY_SYNC_TOKEN="$user_token"
        fi
        echo ""
    fi
}

# ===========================================
# 非交互配置(用默认值/传入参数填充)
# ===========================================

noninteractive_config() {
    IMAGE_SOURCE=${IMAGE_SOURCE:-remote}
    HTTP_PORT=${HTTP_PORT:-80}
    HTTPS_PORT=${HTTPS_PORT:-443}
    ADMIN_PASSWORD=${ADMIN_PASSWORD:-$(generate_random_string 12)}
    DB_TYPE=${DB_TYPE:-sqlite3}
    DB_DSN=${DB_DSN:-/data/admin.db}
    GATEWAY_SYNC_TOKEN=${GATEWAY_SYNC_TOKEN:-$(generate_random_string 32)}
    REDIS_ADDR=${REDIS_ADDR:-redis:6379}
    REDIS_DB=${REDIS_DB:-0}
    CLICKHOUSE_ENABLED=${CLICKHOUSE_ENABLED:-false}
    if [ "$CLICKHOUSE_ENABLED" = true ]; then
        [ -n "$CLICKHOUSE_ADDR" ] || die "启用 ClickHouse 时必须指定 --clickhouse-addr 或 TL_CLICKHOUSE_ADDR。"
        CLICKHOUSE_DATABASE=${CLICKHOUSE_DATABASE:-tokenlive_gateway}
        CLICKHOUSE_USERNAME=${CLICKHOUSE_USERNAME:-default}
    fi
    # REDIS_PASSWORD 可空
    # CLICKHOUSE_PASSWORD 可空
}

# ===========================================
# 生成 .env
# ===========================================

generate_env() {
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
STORAGE_CACHE_TYPE=$([ "$REDIS_ENABLED" = true ] && echo "redis" || echo "memory")

# ------------------------------
# 镜像仓库配置
# ------------------------------
REGISTRY=${REGISTRY:-ghcr.io/tokenlive}
VERSION=${VERSION:-latest}

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
# ClickHouse 访问日志配置（可选，需使用外置 ClickHouse）
# ------------------------------
EOF

    if [ "$CLICKHOUSE_ENABLED" = true ]; then
        cat << EOF >> .env
CLICKHOUSE_ENABLED=true
CLICKHOUSE_ADDR=${CLICKHOUSE_ADDR}
CLICKHOUSE_DATABASE=${CLICKHOUSE_DATABASE}
CLICKHOUSE_USERNAME=${CLICKHOUSE_USERNAME}
CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD}
EOF
    else
        cat << EOF >> .env
CLICKHOUSE_ENABLED=false
# CLICKHOUSE_ADDR=clickhouse.example.com:9000
# CLICKHOUSE_DATABASE=tokenlive_gateway
# CLICKHOUSE_USERNAME=default
# CLICKHOUSE_PASSWORD=
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
}

# ===========================================
# 配置概要展示
# ===========================================

show_summary() {
    echo -e "${GREEN}==================================================${NC}"
    echo -e "                 配置概要汇总                     "
    echo -e "${GREEN}==================================================${NC}"
    local img_src=$(grep "^IMAGE_SOURCE=" .env | cut -d= -f2-)
    if [ "$img_src" = "local" ]; then
        echo -e "  镜像来源:      ${YELLOW}本地源码实时构建 (Local Build)${NC}"
    else
        echo -e "  镜像来源:      预构建官方镜像 (ghcr.io)"
    fi
    local domain_val=$(grep "^DOMAIN=" .env | cut -d= -f2-)
    if [ -n "$domain_val" ]; then
        echo -e "  部署域名:      https://${domain_val}"
    else
        echo -e "  部署模式:      使用 HTTP 本地/内网 IP 访问"
    fi
    echo -e "  HTTP 端口:     $(grep "^HTTP_PORT=" .env | cut -d= -f2-)"
    echo -e "  HTTPS 端口:    $(grep "^HTTPS_PORT=" .env | cut -d= -f2-)"
    echo -e "  数据库类型:    $(grep "^DB_TYPE=" .env | cut -d= -f2-)"
    if grep -q "^REDIS_ADDR=" .env; then
        echo -e "  Redis 缓存:    已启用 (${YELLOW}$(grep "^REDIS_ADDR=" .env | cut -d= -f2-)${NC})"
    else
        echo -e "  Redis 缓存:    未启用 (单机内存模式)"
    fi
    if grep -q "^CLICKHOUSE_ENABLED=true" .env; then
        echo -e "  ClickHouse:    已启用 (${YELLOW}$(grep "^CLICKHOUSE_ADDR=" .env | cut -d= -f2-)${NC}, database=$(grep "^CLICKHOUSE_DATABASE=" .env | cut -d= -f2-))"
    else
        echo -e "  ClickHouse:    未启用"
    fi
    echo -e "  管理员账号:    admin"
    echo -e "  管理员密码:    ${YELLOW}$(grep "^ADMIN_PASSWORD=" .env | cut -d= -f2-)${NC} (请务必牢记)"
    echo -e "${GREEN}==================================================${NC}\n"
}

# ===========================================
# 读取 .env 辅助
# ===========================================

env_get() { grep "^$1=" .env | cut -d= -f2-; }

# ===========================================
# 部署启动
# ===========================================

deploy() {
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    export COMPOSE_CMD="$compose_cmd"

    local image_source=$(env_get IMAGE_SOURCE)
    local use_local_redis=false
    if grep -q "^REDIS_ADDR=" .env; then
        local redis_addr=$(env_get REDIS_ADDR)
        if [ "$redis_addr" = "redis:6379" ] || [ "$redis_addr" = "redis" ] || [[ "$redis_addr" =~ ^redis: ]]; then
            use_local_redis=true
        fi
    fi

    local compose_files="-f docker-compose.yml"
    if [ "$image_source" = "local" ]; then
        compose_files="-f docker-compose.yml -f docker-compose.build.yml"
    fi

    local start_cmd="$compose_cmd $compose_files up -d"
    if [ "$image_source" = "local" ]; then
        start_cmd="$compose_cmd $compose_files up -d --build"
    fi
    if [ "$use_local_redis" = true ]; then
        echo -e "${YELLOW}检测到使用本地 Redis 服务，将包含 with-redis Profile 运行...${NC}"
        start_cmd="$compose_cmd --profile with-redis $compose_files up -d"
        if [ "$image_source" = "local" ]; then
            start_cmd="$compose_cmd --profile with-redis $compose_files up -d --build"
        fi
    fi

    # 拉取镜像(仅远程)
    if [ "$image_source" != "local" ]; then
        echo -e "${BLUE}==========================================${NC}"
        echo -e "${BLUE}  正在拉取最新 Docker 镜像...             ${NC}"
        echo -e "${BLUE}==========================================${NC}"
        if [ "$use_local_redis" = true ]; then
            $compose_cmd --profile with-redis pull
        else
            $compose_cmd pull
        fi
    fi

    echo -e "\n${BLUE}==========================================${NC}"
    echo -e "${BLUE}  正在启动 TokenLive 容器集群...          ${NC}"
    echo -e "${BLUE}==========================================${NC}"
    eval "$start_cmd"

    echo -e "\n${GREEN}==========================================${NC}"
    echo -e "  ${GREEN}✓ TokenLive 部署成功！${NC}"
    echo -e "${GREEN}==========================================${NC}"

    local final_domain=$(env_get DOMAIN)
    local final_http_port=$(env_get HTTP_PORT)
    echo ""
    echo "服务访问地址："
    if [ -n "$final_domain" ]; then
        echo -e "  - Admin 后台:  ${CYAN}https://${final_domain}${NC}"
        echo -e "  - Gateway API: ${CYAN}https://${final_domain}/v1${NC}"
    else
        if [ "$final_http_port" = "80" ]; then
            echo -e "  - Admin 后台:  ${CYAN}http://localhost${NC}"
            echo -e "  - Gateway API: ${CYAN}http://localhost/v1${NC}"
        else
            echo -e "  - Admin 后台:  ${CYAN}http://localhost:${final_http_port}${NC}"
            echo -e "  - Gateway API: ${CYAN}http://localhost:${final_http_port}/v1${NC}"
        fi
    fi
    echo ""
    echo "默认管理账号："
    echo "  - 用户名: admin"
    echo -e "  - 密  码: ${YELLOW}$(env_get ADMIN_PASSWORD)${NC}"
    echo ""
    echo "常用运维命令(在 $INSTALL_DIR 目录下执行):"
    echo -e "  - 查看服务日志:  $compose_cmd $compose_files logs -f"
    echo -e "  - 重启所有服务:  $compose_cmd $compose_files restart"
    echo -e "  - 关闭所有服务:  $compose_cmd $compose_files down"
    echo -e "  - 升级版本:      $compose_cmd pull && $compose_cmd $compose_files up -d"
    echo ""
}

# ===========================================
# 升级模式
# ===========================================

upgrade() {
    local compose_cmd
    compose_cmd=$(get_compose_cmd)

    local image_source=$(env_get IMAGE_SOURCE)
    local use_local_redis=false
    if grep -q "^REDIS_ADDR=" .env; then
        local redis_addr=$(env_get REDIS_ADDR)
        if [ "$redis_addr" = "redis:6379" ] || [ "$redis_addr" = "redis" ] || [[ "$redis_addr" =~ ^redis: ]]; then
            use_local_redis=true
        fi
    fi

    local compose_files="-f docker-compose.yml"
    if [ "$image_source" = "local" ] && [ -f docker-compose.build.yml ]; then
        compose_files="-f docker-compose.yml -f docker-compose.build.yml"
    fi

    echo -e "${YELLOW}正在停止并清理现有容器集群...${NC}"
    if [ "$use_local_redis" = true ]; then
        $compose_cmd --profile with-redis $compose_files down
    else
        $compose_cmd $compose_files down
    fi

    if [ "$image_source" = "local" ]; then
        echo -e "${YELLOW}检测到使用本地构建，正在清理本地旧镜像产物...${NC}"
        if [ "$use_local_redis" = true ]; then
            $compose_cmd --profile with-redis $compose_files down --rmi local
        else
            $compose_cmd $compose_files down --rmi local
        fi
        echo -e "${BLUE}正在重新编译并启动本地容器...${NC}"
        if [ "$use_local_redis" = true ]; then
            $compose_cmd --profile with-redis $compose_files up -d --build
        else
            $compose_cmd $compose_files up -d --build
        fi
    else
        echo -e "${YELLOW}正在删除本地的 TokenLive 核心远程镜像...${NC}"
        local registry_val=$(env_get REGISTRY)
        registry_val=${registry_val:-"ghcr.io/tokenlive"}
        local version_val=$(env_get VERSION)
        version_val=${version_val:-"latest"}
        docker rmi "${registry_val}/tokenlive-gateway:${version_val}" "${registry_val}/tokenlive-admin:${version_val}" 2>/dev/null || true
        echo -e "${BLUE}正在拉取最新 Docker 镜像并启动...${NC}"
        if [ "$use_local_redis" = true ]; then
            $compose_cmd --profile with-redis pull
            $compose_cmd --profile with-redis $compose_files up -d
        else
            $compose_cmd pull
            $compose_cmd $compose_files up -d
        fi
    fi

    echo -e "\n${GREEN}==========================================${NC}"
    echo -e "  ${GREEN}✓ TokenLive 版本更新启动成功！${NC}"
    echo -e "${GREEN}==========================================${NC}"
}

# ===========================================
# 主流程
# ===========================================

main() {
    parse_args "$@"
    load_env_vars

    echo -e "${GREEN}"
    echo "=================================================="
    echo "         TokenLive 一键安装与配置向导             "
    echo "=================================================="
    echo -e "${NC}"

    # 1. Docker 检测与安装
    ensure_docker

    # 2. 工作目录与依赖文件
    prepare_workdir

    # 3. 升级模式
    if [ "$UPGRADE_MODE" = true ]; then
        if [ ! -f .env ]; then
            die "未找到 .env 配置文件，升级模式需要已有部署。请先正常运行安装。"
        fi
        show_summary
        if [ "$ASSUME_YES" = true ]; then
            upgrade
        else
            read -r -p "确认要更新版本吗？这将停止并删除旧容器，拉取最新版启动。 [Y/n]: " upgrade_choice
            upgrade_choice=${upgrade_choice:-Y}
            case "$upgrade_choice" in
                [yY][eE][sS]|[yY]) upgrade ;;
                *) echo -e "${YELLOW}更新已被取消。${NC}"; exit 0 ;;
            esac
        fi
        exit 0
    fi

    # 4. 配置向导(交互/非交互)
    # 判断模式: 有显式配置参数 或 --yes 或 非 tty → 非交互
    if [ "$ASSUME_YES" = true ] || has_explicit_config || [ ! -t 0 ]; then
        NONINTERACTIVE=true
        log_info "非交互模式: 使用命令行参数/环境变量/默认值生成配置"
        noninteractive_config
    else
        log_info "交互模式: 进入配置向导"
        interactive_wizard
    fi

    # 5. 已存在 .env 的处理(交互模式)
    if [ "$NONINTERACTIVE" = false ] && [ -f .env ]; then
        echo -e "${YELLOW}检测到已存在配置文件 .env${NC}"
        echo "请选择操作："
        echo "  1) 重新运行配置向导并部署 (覆盖现有 .env) [默认]"
        echo "  2) 一键更新版本 (保留现有配置，拉取最新镜像启动)"
        echo "  3) 直接基于现有配置启动 (不拉取/不更新，直接启动)"
        read -r -p "请选择 [默认: 1]: " action_choice
        action_choice=${action_choice:-1}
        case "$action_choice" in
            2) UPGRADE_MODE=true ;;
            3)
                show_summary
                deploy
                exit 0
                ;;
        esac
        # 选项 1 继续(会覆盖 .env)
        if [ "$UPGRADE_MODE" = true ]; then
            show_summary
            if [ "$ASSUME_YES" = true ]; then
                upgrade
            else
                read -r -p "确认要更新版本吗？ [Y/n]: " uc
                uc=${uc:-Y}
                case "$uc" in
                    [yY][eE][sS]|[yY]) upgrade ;;
                    *) echo -e "${YELLOW}已取消。${NC}"; exit 0 ;;
                esac
            fi
            exit 0
        fi
    fi

    # 6. 生成 .env
    generate_env

    # 7. 概要展示
    show_summary

    # 8. 启动确认
    if [ "$SKIP_START" = true ]; then
        echo -e "${YELLOW}已指定 --no-start，配置已生成，未启动服务。${NC}"
        echo "稍后可手动启动: cd $INSTALL_DIR && $COMPOSE_CMD up -d"
        exit 0
    fi

    if [ "$NONINTERACTIVE" = true ] || [ "$ASSUME_YES" = true ]; then
        deploy
    else
        read -r -p "是否立即启动部署？ [Y/n]: " deploy_choice
        deploy_choice=${deploy_choice:-Y}
        case "$deploy_choice" in
            [yY][eE][sS]|[yY]) deploy ;;
            *)
                echo -e "${YELLOW}部署已被用户取消。${NC}"
                echo -e "可随时进入 ${CYAN}${INSTALL_DIR}${NC} 运行: $COMPOSE_CMD up -d"
                ;;
        esac
    fi
}

main "$@"
