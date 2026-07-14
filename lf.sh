#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="check-cx"
IMAGE="bingzi233/check-cx:latest"
INSTALL_DIR="${CHECK_CX_INSTALL_DIR:-/opt/check-cx}"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
DEFAULT_PORT="${CHECK_CX_PORT:-3000}"
COMPOSE_CMD=()

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    fail "请使用 root 运行，或执行：sudo bash <(curl -sL 你的脚本地址)"
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

install_pkg() {
  if has_cmd apt-get; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  elif has_cmd dnf; then
    dnf install -y "$@"
  elif has_cmd yum; then
    yum install -y "$@"
  elif has_cmd apk; then
    apk add --no-cache "$@"
  elif has_cmd pacman; then
    pacman -Sy --noconfirm "$@"
  else
    return 1
  fi
}

ensure_curl() {
  if ! has_cmd curl; then
    info "未检测到 curl，正在安装..."
    install_pkg curl || fail "curl 安装失败，请先手动安装 curl"
  fi
}

detect_country() {
  curl -fsS --max-time 2 https://ipinfo.io/country 2>/dev/null | tr -d '\r\n' || true
}

configure_docker_mirror_for_cn() {
  local country
  country="$(detect_country)"
  [ "$country" = "CN" ] || return 0

  info "检测到 CN 网络环境，配置 Docker 镜像加速..."
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'JSON'
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.m.daocloud.io",
    "https://dockerproxy.net",
    "https://hub.rat.dev",
    "https://docker.kejilion.pro",
    "https://hub.1panel.dev"
  ]
}
JSON
}

start_docker_service() {
  if has_cmd systemctl; then
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl restart docker >/dev/null 2>&1 || systemctl start docker >/dev/null 2>&1 || true
  elif has_cmd service; then
    service docker restart >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true
  elif has_cmd rc-service; then
    rc-update add docker default >/dev/null 2>&1 || true
    rc-service docker restart >/dev/null 2>&1 || rc-service docker start >/dev/null 2>&1 || true
  fi
}

install_docker_with_linuxmirrors() {
  local country source registry
  country="$(detect_country)"

  if [ "$country" = "CN" ]; then
    source="mirrors.huaweicloud.com/docker-ce"
    registry="docker.1ms.run"
  else
    source="download.docker.com"
    registry="registry.hub.docker.com"
  fi

  curl -fsSL https://linuxmirrors.cn/docker.sh | bash -s -- \
    --source "$source" \
    --source-registry "$registry" \
    --protocol https \
    --use-intranet-source false
}

install_docker_fallback() {
  if has_cmd apt-get || has_cmd dnf || has_cmd yum; then
    curl -fsSL https://get.docker.com | sh
  elif has_cmd apk; then
    install_pkg docker docker-cli-compose
  elif has_cmd pacman; then
    install_pkg docker docker-compose
  else
    return 1
  fi
}

install_docker() {
  info "正在安装 Docker 环境..."
  ensure_curl

  if has_cmd apt-get || has_cmd dnf || has_cmd yum; then
    install_docker_with_linuxmirrors || install_docker_fallback || fail "Docker 自动安装失败，请手动安装 Docker 后重试"
  else
    install_docker_fallback || fail "Docker 自动安装失败，请手动安装 Docker 后重试"
  fi

  configure_docker_mirror_for_cn
  start_docker_service
}

ensure_docker() {
  if ! has_cmd docker; then
    install_docker
  fi

  start_docker_service

  if ! docker info >/dev/null 2>&1; then
    fail "Docker 已安装但无法连接 daemon，请检查 Docker 服务状态"
  fi

  success "Docker 可用：$(docker --version)"
}

install_compose_plugin() {
  info "未检测到 Docker Compose，正在安装 Compose 插件..."
  if has_cmd apt-get; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin
  elif has_cmd dnf; then
    dnf install -y docker-compose-plugin
  elif has_cmd yum; then
    yum install -y docker-compose-plugin docker-compose || yum install -y docker-compose
  elif has_cmd apk; then
    apk add --no-cache docker-cli-compose docker-compose
  elif has_cmd pacman; then
    pacman -Sy --noconfirm docker-compose
  else
    return 1
  fi
}

ensure_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
  elif has_cmd docker-compose; then
    COMPOSE_CMD=(docker-compose)
  else
    install_compose_plugin || fail "Docker Compose 自动安装失败，请手动安装 docker compose 插件后重试"
    if docker compose version >/dev/null 2>&1; then
      COMPOSE_CMD=(docker compose)
    elif has_cmd docker-compose; then
      COMPOSE_CMD=(docker-compose)
    else
      fail "仍未检测到 Docker Compose"
    fi
  fi

  success "Docker Compose 可用：$(${COMPOSE_CMD[@]} version | head -n 1)"
}

prompt_value() {
  local var_name="$1"
  local prompt="$2"
  local default_value="${3:-}"
  local secret="${4:-false}"
  local value="${!var_name:-}"

  if [ -n "$value" ]; then
    printf '%s' "$value"
    return 0
  fi

  while [ -z "$value" ]; do
    if [ "$secret" = "true" ]; then
      read -r -s -p "$prompt" value
      printf '\n' >&2
    elif [ -n "$default_value" ]; then
      read -r -p "$prompt [$default_value]: " value
      value="${value:-$default_value}"
    else
      read -r -p "$prompt: " value
    fi
  done

  printf '%s' "$value"
}

show_supabase_guide() {
  cat <<'EOF'

============================================================
首次部署前，请先准备 Supabase 数据库
============================================================

check-cx 需要 Supabase 保存监控配置和历史数据。
如果你还没有 Supabase 项目，请先按下面步骤操作：

1. 打开 Supabase 控制台
   https://supabase.com/dashboard

2. 新建一个 Project
   记住数据库密码，地区按需选择即可。

3. 进入项目后，打开：
   Project Settings -> API

4. 准备下面 3 个值，稍后脚本会让你输入：
   - Project URL
     填到 SUPABASE_URL
   - anon public / publishable key
     填到 SUPABASE_PUBLISHABLE_OR_ANON_KEY
   - service_role key
     填到 SUPABASE_SERVICE_ROLE_KEY

5. 初始化数据库表结构
   打开 Supabase 左侧 SQL Editor，新建 Query，复制并运行：
   https://raw.githubusercontent.com/BingZi-233/check-cx/master/supabase/schema.sql

完成以上步骤后，再回到这里继续安装。

提示：
- SUPABASE_SERVICE_ROLE_KEY 是敏感密钥，只输入到服务器，不要发给别人。
- 如果还没准备好，输入 n 退出；准备好后重新运行本脚本即可。

============================================================
EOF
}

confirm_supabase_ready() {
  if [ -n "${SUPABASE_URL:-}" ] && [ -n "${SUPABASE_PUBLISHABLE_OR_ANON_KEY:-}" ] && [ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
    return 0
  fi

  show_supabase_guide

  local answer
  read -r -p "你是否已经创建 Supabase 项目并执行 schema.sql？[y/N]: " answer
  case "$answer" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      info "已退出。准备好 Supabase 后重新运行：bash <(curl -sL https://raw.githubusercontent.com/520pt/lf.sh/main/lf.sh)"
      exit 0
      ;;
  esac
}
write_env_file() {
  mkdir -p "$INSTALL_DIR"

  if [ -f "$ENV_FILE" ]; then
    success "检测到已有环境文件，保留：$ENV_FILE"
    return 0
  fi

  confirm_supabase_ready

  info "请输入 Supabase 配置。输入内容只会写入 $ENV_FILE，不会打印到屏幕。"
  local supabase_url anon_key service_key node_id interval retention official_interval concurrency
  supabase_url="$(prompt_value SUPABASE_URL 'SUPABASE_URL')"
  anon_key="$(prompt_value SUPABASE_PUBLISHABLE_OR_ANON_KEY 'SUPABASE_PUBLISHABLE_OR_ANON_KEY')"
  service_key="$(prompt_value SUPABASE_SERVICE_ROLE_KEY 'SUPABASE_SERVICE_ROLE_KEY' '' true)"
  node_id="$(prompt_value CHECK_NODE_ID 'CHECK_NODE_ID' 'check-cx-1')"
  interval="$(prompt_value CHECK_POLL_INTERVAL_SECONDS 'CHECK_POLL_INTERVAL_SECONDS' '60')"
  retention="$(prompt_value HISTORY_RETENTION_DAYS 'HISTORY_RETENTION_DAYS' '30')"
  official_interval="$(prompt_value OFFICIAL_STATUS_CHECK_INTERVAL_SECONDS 'OFFICIAL_STATUS_CHECK_INTERVAL_SECONDS' '60')"
  concurrency="$(prompt_value CHECK_CONCURRENCY 'CHECK_CONCURRENCY' '8')"

  umask 077
  cat > "$ENV_FILE" <<EOF
SUPABASE_URL=$supabase_url
SUPABASE_PUBLISHABLE_OR_ANON_KEY=$anon_key
SUPABASE_SERVICE_ROLE_KEY=$service_key
NODE_ENV=production
CHECK_POLL_INTERVAL_SECONDS=$interval
CHECK_NODE_ID=$node_id
HISTORY_RETENTION_DAYS=$retention
OFFICIAL_STATUS_CHECK_INTERVAL_SECONDS=$official_interval
CHECK_CONCURRENCY=$concurrency
EOF
  success "已创建环境文件：$ENV_FILE"
}

write_compose_file() {
  mkdir -p "$INSTALL_DIR"
  cat > "$COMPOSE_FILE" <<EOF
services:
  check-cx:
    image: $IMAGE
    container_name: $APP_NAME
    restart: unless-stopped
    ports:
      - "${DEFAULT_PORT}:3000"
    env_file:
      - .env
    environment:
      - NODE_ENV=production
EOF
  success "已写入 Compose 文件：$COMPOSE_FILE"
}

deploy() {
  need_root
  ensure_curl
  ensure_docker
  ensure_compose
  write_env_file
  write_compose_file

  info "拉取镜像：$IMAGE"
  "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" pull

  info "启动/更新容器..."
  "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" up -d --remove-orphans

  sleep 5
  if docker ps --format '{{.Names}}' | grep -qx "$APP_NAME"; then
    success "容器已运行：$APP_NAME"
  else
    warn "容器未处于运行状态，最近日志如下："
    docker logs "$APP_NAME" --tail 80 2>/dev/null || true
    fail "部署未成功启动"
  fi

  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${DEFAULT_PORT}" || true)"
  if [ "$code" = "200" ]; then
    success "访问地址：http://服务器IP:${DEFAULT_PORT}"
  else
    warn "本地 HTTP 检测返回 $code。若 Supabase schema 尚未初始化，请先在 Supabase 执行项目的 supabase/schema.sql。"
    warn "仍可尝试访问：http://服务器IP:${DEFAULT_PORT}"
  fi

  info "常用命令："
  printf '  查看日志：docker logs -f %s\n' "$APP_NAME"
  printf '  修改配置：nano %s && cd %s && %s up -d\n' "$ENV_FILE" "$INSTALL_DIR" "${COMPOSE_CMD[*]}"
  printf '  更新版本：bash <(curl -sL 你的脚本地址)\n'
}

show_logs() {
  docker logs -f "$APP_NAME"
}

uninstall() {
  need_root
  ensure_docker
  ensure_compose
  if [ -f "$COMPOSE_FILE" ]; then
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" down
  else
    docker rm -f "$APP_NAME" >/dev/null 2>&1 || true
  fi
  warn "配置目录未删除：$INSTALL_DIR"
  warn "如需彻底删除，请手动执行：rm -rf $INSTALL_DIR"
}

main() {
  case "${1:-deploy}" in
    deploy|install|update)
      deploy
      ;;
    logs)
      show_logs
      ;;
    uninstall|remove)
      uninstall
      ;;
    *)
      cat <<EOF
用法：
  bash <(curl -sL 你的脚本地址)            # 安装或更新
  bash <(curl -sL 你的脚本地址) update     # 更新
  bash <(curl -sL 你的脚本地址) logs       # 查看日志
  bash <(curl -sL 你的脚本地址) uninstall  # 停止并删除容器，保留配置目录

可选环境变量：
  CHECK_CX_PORT=3000
  CHECK_CX_INSTALL_DIR=/opt/check-cx
  SUPABASE_URL=...
  SUPABASE_PUBLISHABLE_OR_ANON_KEY=...
  SUPABASE_SERVICE_ROLE_KEY=...
EOF
      ;;
  esac
}

main "$@"