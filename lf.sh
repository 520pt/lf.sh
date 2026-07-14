#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="check-cx"
IMAGE="bingzi233/check-cx:latest"
INSTALL_DIR="${CHECK_CX_INSTALL_DIR:-/opt/check-cx}"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
DEFAULT_PORT="${CHECK_CX_PORT:-3000}"
DB_CONTAINER="check-cx-db"
POSTGREST_CONTAINER="check-cx-postgrest"
GATEWAY_CONTAINER="check-cx-gateway"
SCHEMA_URL="${CHECK_CX_SCHEMA_URL:-https://raw.githubusercontent.com/BingZi-233/check-cx/master/supabase/schema.sql}"
NGINX_FILE="$INSTALL_DIR/nginx.conf"
INIT_SQL_FILE="$INSTALL_DIR/init-check-cx.sql"
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

random_hex() {
  openssl rand -hex "$1"
}

base64_url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

jwt_for_role() {
  local role="$1"
  local secret="$2"
  local header payload signing_input signature
  header="$(printf '{"alg":"HS256","typ":"JWT"}' | base64_url)"
  payload="$(printf '{"role":"%s","iss":"supabase","iat":1700000000,"exp":4102444800}' "$role" | base64_url)"
  signing_input="$header.$payload"
  signature="$(printf '%s' "$signing_input" | openssl dgst -sha256 -hmac "$secret" -binary | base64_url)"
  printf '%s.%s' "$signing_input" "$signature"
}

ensure_openssl() {
  if ! has_cmd openssl; then
    info "未检测到 openssl，正在安装..."
    install_pkg openssl || fail "openssl 安装失败，请先手动安装 openssl"
  fi
}

load_env_file() {
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
  fi
}

write_env_file() {
  mkdir -p "$INSTALL_DIR"

  if [ -f "$ENV_FILE" ]; then
    success "检测到已有环境文件，保留：$ENV_FILE"
    load_env_file
    return 0
  fi

  ensure_openssl

  info "首次部署将使用本地数据库模式：自动创建 PostgreSQL + PostgREST，不需要去 Supabase 官网创建项目。"
  local postgres_password authenticator_password jwt_secret anon_key service_role_key
  postgres_password="$(random_hex 24)"
  authenticator_password="$(random_hex 24)"
  jwt_secret="$(random_hex 32)"
  anon_key="$(jwt_for_role anon "$jwt_secret")"
  service_role_key="$(jwt_for_role service_role "$jwt_secret")"

  umask 077
  cat > "$ENV_FILE" <<EOF
# check-cx local deployment
POSTGRES_PASSWORD=$postgres_password
POSTGREST_AUTHENTICATOR_PASSWORD=$authenticator_password
JWT_SECRET=$jwt_secret
ANON_KEY=$anon_key
SERVICE_ROLE_KEY=$service_role_key

# Environment variables consumed by check-cx
SUPABASE_URL=http://$GATEWAY_CONTAINER:8000
SUPABASE_PUBLISHABLE_OR_ANON_KEY=$anon_key
SUPABASE_SERVICE_ROLE_KEY=$service_role_key
NODE_ENV=production
CHECK_POLL_INTERVAL_SECONDS=60
CHECK_NODE_ID=check-cx-1
HISTORY_RETENTION_DAYS=30
OFFICIAL_STATUS_CHECK_INTERVAL_SECONDS=60
CHECK_CONCURRENCY=8
EOF

  load_env_file
  success "已创建本地数据库环境文件：$ENV_FILE"
}

write_compose_file() {
  mkdir -p "$INSTALL_DIR"
  cat > "$COMPOSE_FILE" <<EOF
services:
  check-cx-db:
    image: postgres:16-alpine
    container_name: $DB_CONTAINER
    restart: unless-stopped
    environment:
      POSTGRES_DB: postgres
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
    volumes:
      - ./postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d postgres"]
      interval: 5s
      timeout: 5s
      retries: 30

  check-cx-postgrest:
    image: postgrest/postgrest:v12.2.12
    container_name: $POSTGREST_CONTAINER
    restart: unless-stopped
    depends_on:
      check-cx-db:
        condition: service_healthy
    environment:
      PGRST_DB_URI: postgres://authenticator:\${POSTGREST_AUTHENTICATOR_PASSWORD}@$DB_CONTAINER:5432/postgres
      PGRST_DB_SCHEMAS: public
      PGRST_DB_ANON_ROLE: anon
      PGRST_JWT_SECRET: \${JWT_SECRET}
      PGRST_SERVER_PORT: "3000"

  check-cx-gateway:
    image: nginx:alpine
    container_name: $GATEWAY_CONTAINER
    restart: unless-stopped
    depends_on:
      - check-cx-postgrest
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro

  check-cx:
    image: $IMAGE
    container_name: $APP_NAME
    restart: unless-stopped
    depends_on:
      - check-cx-gateway
    ports:
      - "${DEFAULT_PORT}:3000"
    env_file:
      - .env
    environment:
      NODE_ENV: production
      SUPABASE_URL: http://$GATEWAY_CONTAINER:8000
      SUPABASE_PUBLISHABLE_OR_ANON_KEY: \${ANON_KEY}
      SUPABASE_SERVICE_ROLE_KEY: \${SERVICE_ROLE_KEY}
EOF
  success "已写入 Compose 文件：$COMPOSE_FILE"
}

write_nginx_file() {
  mkdir -p "$INSTALL_DIR"
  cat > "$NGINX_FILE" <<EOF
server {
  listen 8000;
  server_name _;

  location = /health {
    return 200 'ok';
    add_header Content-Type text/plain;
  }

  location = /rest/v1 {
    proxy_pass http://$POSTGREST_CONTAINER:3000/;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
  }

  location /rest/v1/ {
    proxy_pass http://$POSTGREST_CONTAINER:3000/;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
  }
}
EOF
  success "已写入本地 Supabase REST 网关配置：$NGINX_FILE"
}

wait_for_postgres() {
  info "等待本地 PostgreSQL 就绪..."
  local i
  for i in $(seq 1 60); do
    if docker exec "$DB_CONTAINER" pg_isready -U postgres -d postgres >/dev/null 2>&1; then
      success "本地 PostgreSQL 已就绪"
      return 0
    fi
    sleep 2
  done
  fail "本地 PostgreSQL 启动超时，请检查日志：docker logs $DB_CONTAINER"
}

build_init_sql() {
  local schema_tmp
  schema_tmp="$INSTALL_DIR/schema.sql"
  info "下载 check-cx 数据库结构..."
  curl -fsSL "$SCHEMA_URL" -o "$schema_tmp" || fail "下载 schema.sql 失败：$SCHEMA_URL"

  cat > "$INIT_SQL_FILE" <<EOF
CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN BYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD '$POSTGREST_AUTHENTICATOR_PASSWORD';
  END IF;
END
\$\$;

ALTER ROLE authenticator WITH PASSWORD '$POSTGREST_AUTHENTICATOR_PASSWORD';
ALTER ROLE service_role BYPASSRLS;
GRANT anon, authenticated, service_role TO authenticator;
EOF

  cat "$schema_tmp" >> "$INIT_SQL_FILE"

  cat >> "$INIT_SQL_FILE" <<'EOF'

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO anon;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO service_role;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;
EOF
}

init_local_database() {
  load_env_file
  if [ -z "${POSTGRES_PASSWORD:-}" ] || [ -z "${POSTGREST_AUTHENTICATOR_PASSWORD:-}" ]; then
    fail "环境文件缺少本地数据库配置：$ENV_FILE"
  fi

  info "启动本地数据库容器..."
  (cd "$INSTALL_DIR" && "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" up -d check-cx-db)
  wait_for_postgres

  local exists
  exists="$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONTAINER" psql -U postgres -d postgres -tAc "SELECT to_regclass('public.check_configs') IS NOT NULL" 2>/dev/null | tr -d '[:space:]' || true)"
  if [ "$exists" = "t" ]; then
    success "检测到数据库已初始化，跳过 schema 导入"
    return 0
  fi

  build_init_sql
  info "初始化本地数据库表结构..."
  docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONTAINER" \
    psql -v ON_ERROR_STOP=1 -U postgres -d postgres < "$INIT_SQL_FILE" >/dev/null
  success "本地数据库初始化完成"
}

deploy() {
  need_root
  ensure_curl
  ensure_docker
  ensure_compose
  write_env_file
  write_compose_file
  write_nginx_file

  info "拉取 Docker 镜像..."
  (cd "$INSTALL_DIR" && "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" pull)

  init_local_database

  info "启动/更新 check-cx 与本地 Supabase 兼容服务..."
  (cd "$INSTALL_DIR" && "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" up -d --remove-orphans)

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
    warn "本地 HTTP 检测返回 $code。服务可能仍在启动中，请稍后查看日志。"
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
    (cd "$INSTALL_DIR" && "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" down)
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
  CHECK_CX_SCHEMA_URL=https://raw.githubusercontent.com/BingZi-233/check-cx/master/supabase/schema.sql

说明：
  默认使用本地数据库模式，会自动部署 PostgreSQL + PostgREST + REST 网关。
  不需要手动创建 Supabase 项目，也不需要输入 Supabase URL 或 Key。
EOF
      ;;
  esac
}

main "$@"