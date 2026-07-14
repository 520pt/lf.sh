#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="check-cx"
IMAGE="bingzi233/check-cx:latest"
ADMIN_APP_NAME="check-cx-admin"
ADMIN_IMAGE="bingzi233/check-cx-admin:latest"
AUTH_CONTAINER="check-cx-auth"
AUTH_IMAGE="supabase/gotrue:v2.189.0"
INSTALL_DIR="${CHECK_CX_INSTALL_DIR:-/opt/check-cx}"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
DEFAULT_PORT="${CHECK_CX_PORT:-3000}"
ADMIN_PORT="${CHECK_CX_ADMIN_PORT:-3001}"
API_PORT="${CHECK_CX_API_PORT:-8000}"
DB_CONTAINER="check-cx-db"
POSTGREST_CONTAINER="check-cx-postgrest"
GATEWAY_CONTAINER="check-cx-gateway"
SCHEMA_URL="${CHECK_CX_SCHEMA_URL:-https://raw.githubusercontent.com/BingZi-233/check-cx/master/supabase/schema.sql}"
NGINX_FILE="$INSTALL_DIR/nginx.conf"
INIT_SQL_FILE="$INSTALL_DIR/init-check-cx.sql"
SCRIPT_URL="${LF_SCRIPT_URL:-https://raw.githubusercontent.com/520pt/lf.sh/main/lf.sh}"
SCRIPT_VERSION="2026.07.14.8"
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


get_local_ipv4() {
  ip route get 8.8.8.8 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' || \
    hostname -I 2>/dev/null | awk '{print $1}' || \
    ifconfig 2>/dev/null | grep -E 'inet [0-9]' | grep -v '127.0.0.1' | awk '{print $2}' | head -n 1 || true
}

get_public_ipv4() {
  curl -4 -fsS --max-time 3 https://ipinfo.io/ip 2>/dev/null || \
    curl -4 -fsS --max-time 3 https://api.ipify.org 2>/dev/null || \
    curl -4 -fsS --max-time 3 https://ifconfig.me/ip 2>/dev/null || true
}

get_public_ipv6() {
  curl -6 -fsS --max-time 3 https://v6.ipinfo.io/ip 2>/dev/null || \
    curl -6 -fsS --max-time 3 https://api64.ipify.org 2>/dev/null || true
}

detect_primary_host() {
  local ipv4_address local_ipv4
  ipv4_address="$(get_public_ipv4 | tr -d '\r\n ')"
  local_ipv4="$(get_local_ipv4 | tr -d '\r\n ')"

  if [ -n "$ipv4_address" ]; then
    printf '%s' "$ipv4_address"
  elif [ -n "$local_ipv4" ]; then
    printf '%s' "$local_ipv4"
  else
    printf '%s' "<服务器IP>"
  fi
}
access_url_for_port() {
  local port="${1:-$DEFAULT_PORT}"
  local host
  host="$(detect_primary_host)"
  printf 'http://%s:%s' "$host" "$port"
}

api_public_url() {
  access_url_for_port "$API_PORT"
}

api_external_url() {
  printf '%s/auth/v1' "$(api_public_url)"
}

print_access_urls() {
  local port="${1:-$DEFAULT_PORT}"
  local ipv4_address ipv6_address local_ipv4 printed
  ipv4_address="$(get_public_ipv4 | tr -d '\r\n ')"
  ipv6_address="$(get_public_ipv6 | tr -d '\r\n ')"
  local_ipv4="$(get_local_ipv4 | tr -d '\r\n ')"
  printed="false"

  echo "------------------------"
  echo "访问地址:"

  if [ -n "$ipv4_address" ]; then
    echo "http://$ipv4_address:$port"
    printed="true"
  fi

  if [ -n "$ipv6_address" ]; then
    echo "http://[$ipv6_address]:$port"
    printed="true"
  fi

  if [ "$printed" = "false" ] && [ -n "$local_ipv4" ]; then
    echo "http://$local_ipv4:$port"
    printed="true"
  fi

  if [ "$printed" = "false" ]; then
    echo "http://<服务器IP>:$port"
    warn "未能自动检测服务器公网 IP，请将 <服务器IP> 替换为你的服务器公网 IP。"
  fi

  echo "------------------------"
}
print_single_access_url() {
  local label="$1"
  local port="$2"
  echo "  $label: $(access_url_for_port "$port")"
}

print_deployment_summary() {
  load_env_file
  local auth_callback admin_redirect github_status
  auth_callback="${GITHUB_CALLBACK_URL:-${API_EXTERNAL_URL:-$(api_external_url)}/callback}"
  admin_redirect="${APP_URL:-$(access_url_for_port "$ADMIN_PORT")}/auth/callback"
  github_status="未配置"
  if [ "${GITHUB_ENABLED:-false}" = "true" ] && [ -n "${GITHUB_CLIENT_ID:-}" ] && [ -n "${GITHUB_CLIENT_SECRET:-}" ]; then
    github_status="已配置"
  fi

  echo ""
  echo "============================================================"
  echo "Check CX 部署信息"
  echo "============================================================"
  print_single_access_url "前台监控面板" "$DEFAULT_PORT"
  print_single_access_url "后台管理面板" "$ADMIN_PORT"
  print_single_access_url "Supabase 兼容 API" "$API_PORT"
  echo ""
  echo "后台登录方式:"
  echo "  官方后台 check-cx-admin 使用 GitHub OAuth 登录。"
  echo "  GitHub OAuth 状态: $github_status"
  echo "  GitHub OAuth App 回调地址填这个: $auth_callback"
  echo "  后台允许跳转地址: $admin_redirect"
  echo "  如果还没配置，执行: lf app check-cx admin"
  echo ""
  echo "容器:"
  printf '  %-24s %s\n' "$APP_NAME" "前台监控面板"
  printf '  %-24s %s\n' "$ADMIN_APP_NAME" "后台管理面板"
  printf '  %-24s %s\n' "$AUTH_CONTAINER" "Supabase Auth / GitHub OAuth"
  printf '  %-24s %s\n' "$DB_CONTAINER" "PostgreSQL 本地数据库"
  printf '  %-24s %s\n' "$POSTGREST_CONTAINER" "Supabase REST 兼容 API"
  printf '  %-24s %s\n' "$GATEWAY_CONTAINER" "REST/Auth 网关"
  echo ""
  echo "目录与配置:"
  echo "  安装目录: $INSTALL_DIR"
  echo "  环境变量: $ENV_FILE"
  echo "  Compose:  $COMPOSE_FILE"
  echo "  网关配置: $NGINX_FILE"
  echo "  数据目录: $INSTALL_DIR/postgres-data"
  echo "  注意: .env 和 postgres-data 包含密钥/业务数据，请勿公开。"
  echo ""
  echo "常用命令:"
  echo "  面板管理: lf"
  echo "  安装/更新: lf app check-cx install"
  echo "  配置后台: lf app check-cx admin"
  echo "  查看状态: lf app check-cx status"
  echo "  查看日志: lf app check-cx logs"
  echo "  卸载保留数据: lf app check-cx uninstall"
  echo "  彻底删除数据: lf app check-cx purge"
  echo "============================================================"
}
compose_down_keep_data() {
  if [ -f "$COMPOSE_FILE" ]; then
    (cd "$INSTALL_DIR" && "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" down --remove-orphans)
  else
    docker rm -f "$APP_NAME" "$ADMIN_APP_NAME" "$AUTH_CONTAINER" "$DB_CONTAINER" "$POSTGREST_CONTAINER" "$GATEWAY_CONTAINER" >/dev/null 2>&1 || true
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

set_env_value() {
  local key="$1"
  local value="$2"
  local escaped
  escaped="$(printf '%s' "$value" | sed 's/[&|]/\\&/g')"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

append_env_if_missing() {
  local key="$1"
  local value="$2"
  if ! grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

ensure_env_secrets() {
  ensure_openssl
  append_env_if_missing "POSTGRES_PASSWORD" "$(random_hex 24)"
  append_env_if_missing "POSTGREST_AUTHENTICATOR_PASSWORD" "$(random_hex 24)"

  load_env_file
  if [ -z "${JWT_SECRET:-}" ]; then
    append_env_if_missing "JWT_SECRET" "$(random_hex 32)"
    load_env_file
  fi
  if [ -z "${ANON_KEY:-}" ]; then
    append_env_if_missing "ANON_KEY" "$(jwt_for_role anon "$JWT_SECRET")"
  fi
  if [ -z "${SERVICE_ROLE_KEY:-}" ]; then
    append_env_if_missing "SERVICE_ROLE_KEY" "$(jwt_for_role service_role "$JWT_SECRET")"
  fi
}

write_env_file() {
  mkdir -p "$INSTALL_DIR"

  if [ ! -f "$ENV_FILE" ]; then
    info "首次部署将使用本地数据库模式：自动创建 PostgreSQL + PostgREST + Auth + 后台，不需要去 Supabase 官网创建项目。"
    umask 077
    cat > "$ENV_FILE" <<'EOF'
# check-cx local deployment
EOF
  else
    success "检测到已有环境文件，保留并补齐缺失项：$ENV_FILE"
  fi

  ensure_env_secrets
  load_env_file

  local public_api_url external_auth_url admin_app_url admin_callback_url github_callback_url
  public_api_url="$(api_public_url)"
  external_auth_url="$(api_external_url)"
  admin_app_url="$(access_url_for_port "$ADMIN_PORT")"
  admin_callback_url="$admin_app_url/auth/callback"
  github_callback_url="$external_auth_url/callback"

  # 前台容器继续使用 Docker 内网网关；后台/浏览器使用服务器可访问的公网 API 地址。
  set_env_value "SUPABASE_URL" "http://$GATEWAY_CONTAINER:8000"
  set_env_value "SUPABASE_PUBLISHABLE_OR_ANON_KEY" "${ANON_KEY}"
  set_env_value "SUPABASE_SERVICE_ROLE_KEY" "${SERVICE_ROLE_KEY}"
  set_env_value "PUBLIC_SUPABASE_URL" "$public_api_url"
  set_env_value "API_EXTERNAL_URL" "$external_auth_url"
  set_env_value "APP_URL" "$admin_app_url"
  set_env_value "SITE_URL" "$admin_app_url"
  set_env_value "ADDITIONAL_REDIRECT_URLS" "$admin_callback_url"
  set_env_value "GITHUB_CALLBACK_URL" "$github_callback_url"

  append_env_if_missing "SUPABASE_DB_SCHEMA" "public"
  append_env_if_missing "SUPABASE_OAUTH_PROVIDERS" "github"
  append_env_if_missing "ADMIN_EMAILS" ""
  append_env_if_missing "GITHUB_ENABLED" "false"
  append_env_if_missing "GITHUB_CLIENT_ID" ""
  append_env_if_missing "GITHUB_CLIENT_SECRET" ""

  append_env_if_missing "NODE_ENV" "production"
  append_env_if_missing "CHECK_POLL_INTERVAL_SECONDS" "60"
  append_env_if_missing "CHECK_NODE_ID" "check-cx-1"
  append_env_if_missing "HISTORY_RETENTION_DAYS" "30"
  append_env_if_missing "OFFICIAL_STATUS_CHECK_INTERVAL_SECONDS" "60"
  append_env_if_missing "CHECK_CONCURRENCY" "8"

  load_env_file
  success "已准备本地数据库、API、Auth、后台环境文件：$ENV_FILE"
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

  check-cx-auth:
    image: $AUTH_IMAGE
    container_name: $AUTH_CONTAINER
    restart: unless-stopped
    depends_on:
      check-cx-db:
        condition: service_healthy
    environment:
      GOTRUE_API_HOST: 0.0.0.0
      GOTRUE_API_PORT: "9999"
      API_EXTERNAL_URL: \${API_EXTERNAL_URL}
      GOTRUE_DB_DRIVER: postgres
      GOTRUE_DB_DATABASE_URL: postgres://supabase_auth_admin:\${POSTGRES_PASSWORD}@$DB_CONTAINER:5432/postgres?sslmode=disable
      GOTRUE_SITE_URL: \${SITE_URL}
      GOTRUE_URI_ALLOW_LIST: \${ADDITIONAL_REDIRECT_URLS}
      GOTRUE_DISABLE_SIGNUP: "false"
      GOTRUE_JWT_ADMIN_ROLES: service_role
      GOTRUE_JWT_AUD: authenticated
      GOTRUE_JWT_DEFAULT_GROUP_NAME: authenticated
      GOTRUE_JWT_EXP: "3600"
      GOTRUE_JWT_SECRET: \${JWT_SECRET}
      GOTRUE_JWT_ISSUER: \${API_EXTERNAL_URL}
      GOTRUE_EXTERNAL_EMAIL_ENABLED: "false"
      GOTRUE_MAILER_AUTOCONFIRM: "true"
      GOTRUE_EXTERNAL_PHONE_ENABLED: "false"
      GOTRUE_SMS_AUTOCONFIRM: "true"
      GOTRUE_EXTERNAL_GITHUB_ENABLED: \${GITHUB_ENABLED:-false}
      GOTRUE_EXTERNAL_GITHUB_CLIENT_ID: \${GITHUB_CLIENT_ID:-}
      GOTRUE_EXTERNAL_GITHUB_SECRET: \${GITHUB_CLIENT_SECRET:-}
      GOTRUE_EXTERNAL_GITHUB_REDIRECT_URI: \${GITHUB_CALLBACK_URL}

  check-cx-gateway:
    image: nginx:alpine
    container_name: $GATEWAY_CONTAINER
    restart: unless-stopped
    depends_on:
      - check-cx-postgrest
      - check-cx-auth
    ports:
      - "${API_PORT}:8000"
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

  check-cx-admin:
    image: $ADMIN_IMAGE
    container_name: $ADMIN_APP_NAME
    restart: unless-stopped
    depends_on:
      - check-cx-gateway
    ports:
      - "${ADMIN_PORT}:3000"
    env_file:
      - .env
    environment:
      NODE_ENV: production
      SUPABASE_URL: \${PUBLIC_SUPABASE_URL}
      SUPABASE_PUBLISHABLE_OR_ANON_KEY: \${ANON_KEY}
      SUPABASE_SERVICE_ROLE_KEY: \${SERVICE_ROLE_KEY}
      SUPABASE_DB_SCHEMA: public
      APP_URL: \${APP_URL}
      SUPABASE_OAUTH_PROVIDERS: github
      ADMIN_EMAILS: \${ADMIN_EMAILS:-}
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
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }

  location /rest/v1/ {
    proxy_pass http://$POSTGREST_CONTAINER:3000/;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }

  location = /auth/v1 {
    proxy_pass http://$AUTH_CONTAINER:9999/;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }

  location /auth/v1/ {
    proxy_pass http://$AUTH_CONTAINER:9999/;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF
  success "已写入本地 Supabase REST/Auth 网关配置：$NGINX_FILE"
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
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_auth_admin') THEN
    CREATE ROLE supabase_auth_admin NOINHERIT LOGIN PASSWORD '$POSTGRES_PASSWORD';
  END IF;
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
ALTER ROLE supabase_auth_admin WITH PASSWORD '$POSTGRES_PASSWORD';
ALTER ROLE supabase_auth_admin SET search_path = auth;
ALTER ROLE service_role BYPASSRLS;
CREATE SCHEMA IF NOT EXISTS auth AUTHORIZATION supabase_auth_admin;
ALTER SCHEMA auth OWNER TO supabase_auth_admin;
GRANT anon, authenticated, service_role TO authenticator;
GRANT USAGE ON SCHEMA auth TO postgres, anon, authenticated, service_role, supabase_auth_admin;
GRANT ALL PRIVILEGES ON SCHEMA auth TO supabase_auth_admin;
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

ensure_auth_schema() {
  info "检查 Supabase Auth 数据库角色和 schema..."
  docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONTAINER"     psql -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
DO \$\$
DECLARE
  item record;
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
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_auth_admin') THEN
    CREATE ROLE supabase_auth_admin NOINHERIT LOGIN PASSWORD '$POSTGRES_PASSWORD';
  END IF;
END
\$\$;

ALTER ROLE supabase_auth_admin WITH PASSWORD '$POSTGRES_PASSWORD';
ALTER ROLE supabase_auth_admin SET search_path = auth;
ALTER ROLE service_role BYPASSRLS;
CREATE SCHEMA IF NOT EXISTS auth AUTHORIZATION supabase_auth_admin;
ALTER SCHEMA auth OWNER TO supabase_auth_admin;
GRANT USAGE ON SCHEMA auth TO postgres, anon, authenticated, service_role, supabase_auth_admin;
GRANT ALL PRIVILEGES ON SCHEMA auth TO supabase_auth_admin;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA auth TO supabase_auth_admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA auth TO supabase_auth_admin;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA auth TO supabase_auth_admin;

DO \$\$
BEGIN
  IF to_regclass('auth.oauth_clients') IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
       FROM information_schema.columns
       WHERE table_schema = 'auth'
         AND table_name = 'oauth_clients'
         AND column_name = 'client_id'
     ) THEN
    DROP TABLE auth.oauth_clients CASCADE;
  END IF;

  IF to_regclass('auth.oauth_authorizations') IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM pg_constraint
       WHERE conrelid = 'auth.oauth_authorizations'::regclass
         AND conname = 'oauth_authorizations_nonce_length'
     ) THEN
    ALTER TABLE auth.oauth_authorizations DROP CONSTRAINT oauth_authorizations_nonce_length;
  END IF;
END
\$\$;

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_auth_admin IN SCHEMA auth GRANT ALL ON TABLES TO supabase_auth_admin;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_auth_admin IN SCHEMA auth GRANT ALL ON SEQUENCES TO supabase_auth_admin;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_auth_admin IN SCHEMA auth GRANT ALL ON FUNCTIONS TO supabase_auth_admin;

DO \$\$
DECLARE
  item record;
BEGIN
  FOR item IN SELECT format('%I.%I', schemaname, tablename) AS name FROM pg_tables WHERE schemaname = 'auth' LOOP
    EXECUTE 'ALTER TABLE ' || item.name || ' OWNER TO supabase_auth_admin';
  END LOOP;
  FOR item IN SELECT format('%I.%I', sequence_schema, sequence_name) AS name FROM information_schema.sequences WHERE sequence_schema = 'auth' LOOP
    EXECUTE 'ALTER SEQUENCE ' || item.name || ' OWNER TO supabase_auth_admin';
  END LOOP;
  FOR item IN SELECT oid::regprocedure AS name FROM pg_proc WHERE pronamespace = 'auth'::regnamespace LOOP
    EXECUTE 'ALTER FUNCTION ' || item.name || ' OWNER TO supabase_auth_admin';
  END LOOP;
  FOR item IN
    SELECT format('%I.%I', n.nspname, t.typname) AS name
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'auth'
      AND t.typtype IN ('d', 'e', 'r', 'm')
      AND t.typname NOT LIKE '\_%'
  LOOP
    EXECUTE 'ALTER TYPE ' || item.name || ' OWNER TO supabase_auth_admin';
  END LOOP;
END
\$\$;
SQL
  success "Auth 数据库角色和 schema 已就绪"
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
    success "检测到数据库已初始化，跳过 check-cx schema 导入"
    ensure_auth_schema
    return 0
  fi

  build_init_sql
  info "初始化本地数据库表结构..."
  docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONTAINER" \
    psql -v ON_ERROR_STOP=1 -U postgres -d postgres < "$INIT_SQL_FILE" >/dev/null
  ensure_auth_schema
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

  info "启动/更新 Check CX 前台、后台、Auth 与本地 Supabase 兼容服务..."
  (cd "$INSTALL_DIR" && "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" up -d --remove-orphans)

  sleep 8
  local container
  for container in "$APP_NAME" "$ADMIN_APP_NAME" "$AUTH_CONTAINER" "$DB_CONTAINER" "$POSTGREST_CONTAINER" "$GATEWAY_CONTAINER"; do
    if docker ps --format '{{.Names}}' | grep -qx "$container"; then
      success "容器已运行：$container"
    else
      warn "容器未处于运行状态：$container，最近日志如下："
      docker logs "$container" --tail 80 2>/dev/null || true
      fail "部署未成功启动"
    fi
  done

  local front_code admin_code api_code
  front_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${DEFAULT_PORT}" || true)"
  admin_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${ADMIN_PORT}" || true)"
  api_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${API_PORT}/health" || true)"

  [ "$front_code" = "200" ] && success "前台已通过本地 HTTP 检测" || warn "前台本地 HTTP 检测返回 $front_code，可能仍在启动中。"
  [ "$admin_code" = "200" ] && success "后台已通过本地 HTTP 检测" || warn "后台本地 HTTP 检测返回 $admin_code，可能仍在启动中。"
  [ "$api_code" = "200" ] && success "API 网关已通过本地 HTTP 检测" || warn "API 网关本地 HTTP 检测返回 $api_code，可能仍在启动中。"

  print_deployment_summary
}

show_logs() {
  ensure_docker
  ensure_compose
  if [ -f "$COMPOSE_FILE" ]; then
    (cd "$INSTALL_DIR" && "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" logs -f)
  else
    docker logs -f "$APP_NAME"
  fi
}

uninstall() {
  need_root
  ensure_docker
  ensure_compose
  info "正在卸载 Check CX 容器，保留配置和数据库数据..."
  compose_down_keep_data
  success "容器已停止并删除"
  warn "已保留安装目录: $INSTALL_DIR"
  warn "已保留数据库数据: $INSTALL_DIR/postgres-data"
  echo ""
  echo "如需恢复，重新运行安装命令即可："
  echo "  bash <(curl -sL https://raw.githubusercontent.com/520pt/lf.sh/main/lf.sh)"
  echo ""
  echo "如需彻底删除数据，请执行："
  echo "  bash <(curl -sL https://raw.githubusercontent.com/520pt/lf.sh/main/lf.sh) purge"
}

purge() {
  need_root
  ensure_docker
  ensure_compose

  if [ "${CHECK_CX_ASSUME_YES:-}" != "1" ]; then
    echo "这将彻底删除 Check CX 容器、配置和本地数据库数据："
    echo "  $INSTALL_DIR"
    echo ""
    read -r -p "确认彻底删除？输入 DELETE 继续: " answer
    if [ "$answer" != "DELETE" ]; then
      info "已取消彻底卸载"
      return 0
    fi
  fi

  info "正在停止并删除容器..."
  compose_down_keep_data

  if [ -n "$INSTALL_DIR" ] && [ "$INSTALL_DIR" != "/" ] && [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    success "已删除安装目录和本地数据库数据: $INSTALL_DIR"
  else
    warn "安装目录不存在或路径异常，跳过删除: $INSTALL_DIR"
  fi
}


install_self_shortcut() {
  [ "${LF_SKIP_SHORTCUT:-}" = "1" ] && return 0

  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    return 0
  fi

  if [ ! -w /usr/local/bin ] && ! mkdir -p /usr/local/bin 2>/dev/null; then
    return 0
  fi

  if [ ! -f /usr/local/bin/lf ] || ! cmp -s "$0" /usr/local/bin/lf 2>/dev/null; then
    if curl -fsSL "$SCRIPT_URL" -o /usr/local/bin/lf 2>/dev/null; then
      chmod +x /usr/local/bin/lf
      success "快捷命令已安装/更新：lf"
    fi
  fi
}

download_self_to_shortcut() {
  local tmp_file
  mkdir -p /usr/local/bin
  tmp_file="$(mktemp)"

  if ! curl -fsSL "$SCRIPT_URL" -o "$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi

  if [ -f /usr/local/bin/lf ] && cmp -s "$tmp_file" /usr/local/bin/lf; then
    rm -f "$tmp_file"
    return 2
  fi

  if ! install -m 755 "$tmp_file" /usr/local/bin/lf; then
    rm -f "$tmp_file"
    return 1
  fi

  rm -f "$tmp_file"
  return 0
}

update_self() {
  need_root
  ensure_curl
  if download_self_to_shortcut; then
    success "脚本已更新：/usr/local/bin/lf"
  else
    local code=$?
    if [ "$code" -eq 2 ]; then
      success "脚本已是最新版本：/usr/local/bin/lf"
    else
      fail "脚本更新失败：$SCRIPT_URL"
    fi
  fi
  echo "以后可直接输入：lf"
}

auto_update_self() {
  [ "${LF_DISABLE_AUTO_UPDATE:-}" = "1" ] && return 0
  [ "${LF_AUTO_UPDATED:-}" = "1" ] && return 0
  [ "${LF_SKIP_SHORTCUT:-}" = "1" ] && return 0
  [ "${EUID:-$(id -u)}" -eq 0 ] || return 0
  [ -f /usr/local/bin/lf ] || return 0

  local self_path
  self_path="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
  [ "$self_path" = "/usr/local/bin/lf" ] || return 0

  ensure_curl
  local code
  set +e
  download_self_to_shortcut
  code=$?
  set -e

  case "$code" in
    0)
      success "检测到脚本新版本，已自动更新并重新进入最新版。"
      LF_AUTO_UPDATED=1 exec /usr/local/bin/lf "$@"
      ;;
    2)
      return 0
      ;;
    *)
      warn "自动更新失败，继续使用当前版本。可稍后手动执行：lf self-update"
      return 0
      ;;
  esac
}

pause_return() {
  echo ""
  read -r -p "按回车返回..." _ || true
}

show_banner() {
  clear 2>/dev/null || true
  cat <<'EOF'
╦  ╔═╗
║  ╠╣
╩═╝╚
EOF
  echo "LF 脚本工具箱"
  echo "命令行输入 lf 可快速启动脚本"
  echo "------------------------"
}

show_main_menu() {
  show_banner
  echo "1.   系统信息查询"
  echo "2.   系统更新"
  echo "3.   系统清理"
  echo "4.   基础工具"
  echo "5.   BBR管理"
  echo "6.   Docker管理"
  echo "7.   WARP管理"
  echo "8.   测试脚本合集"
  echo "9.   甲骨文云脚本合集"
  echo "10.  LDNMP建站"
  echo "11.  应用市场"
  echo "------------------------"
  echo "00.  脚本更新"
  echo "------------------------"
  echo "0.   退出脚本"
  echo "------------------------"
}

main_menu_loop() {
  install_self_shortcut
  while true; do
    show_main_menu
    read -r -p "请输入你的选择: " choice
    case "$choice" in
      1) linux_info; pause_return ;;
      2) linux_update; pause_return ;;
      3) linux_clean; pause_return ;;
      4) linux_tools ;;
      5) linux_bbr ;;
      6) linux_docker ;;
      7) linux_warp ;;
      8) linux_test ;;
      9) linux_oracle ;;
      10) linux_ldnmp ;;
      11) app_market ;;
      00) update_self; pause_return ;;
      0) exit 0 ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}

linux_info() {
  echo "系统信息查询"
  echo "------------------------"
  echo "主机名:       $(hostname 2>/dev/null || echo unknown)"
  echo "系统版本:     $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" || echo unknown)"
  echo "Linux版本:    $(uname -r)"
  echo "CPU架构:      $(uname -m)"
  echo "CPU核心数:    $(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo unknown)"
  echo "内存使用:     $(free -h 2>/dev/null | awk '/Mem:/ {print $3"/"$2}' || echo unknown)"
  echo "硬盘使用:     $(df -h / 2>/dev/null | awk 'NR==2 {print $3"/"$2" ("$5")"}' || echo unknown)"
  echo "运行时间:     $(uptime -p 2>/dev/null || cat /proc/uptime 2>/dev/null | awk '{printf "%d 秒", $1}' || echo unknown)"
  echo "IPv4地址:     $(get_public_ipv4 | tr -d '\r\n ' || true)"
  echo "IPv6地址:     $(get_public_ipv6 | tr -d '\r\n ' || true)"
}

linux_update() {
  need_root
  info "正在系统更新..."
  if has_cmd apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y
  elif has_cmd dnf; then
    dnf -y update
  elif has_cmd yum; then
    yum -y update
  elif has_cmd apk; then
    apk update && apk upgrade
  elif has_cmd pacman; then
    pacman -Syu --noconfirm
  else
    fail "未知的包管理器"
  fi
  success "系统更新完成"
}

linux_clean() {
  need_root
  info "正在系统清理..."
  if has_cmd apt-get; then
    apt-get autoremove -y
    apt-get autoclean -y
    apt-get clean -y
  elif has_cmd dnf; then
    dnf autoremove -y || true
    dnf clean all || true
  elif has_cmd yum; then
    yum autoremove -y || true
    yum clean all || true
  elif has_cmd apk; then
    rm -rf /var/cache/apk/*
  elif has_cmd pacman; then
    pacman -Sc --noconfirm || true
  fi
  journalctl --vacuum-time=7d >/dev/null 2>&1 || true
  docker system prune -f >/dev/null 2>&1 || true
  success "系统清理完成"
}

linux_tools() {
  while true; do
    clear 2>/dev/null || true
    echo "基础工具"
    echo "------------------------"
    echo "1. 安装常用工具 curl wget sudo socat htop unzip tar tmux vim nano git jq"
    echo "2. 安装增强工具 btop ncdu fzf ranger"
    echo "0. 返回上一级"
    echo "------------------------"
    read -r -p "请输入你的选择: " choice
    case "$choice" in
      1) need_root; install_pkg curl wget sudo socat htop unzip tar tmux vim nano git jq; pause_return ;;
      2) need_root; install_pkg btop ncdu fzf ranger; pause_return ;;
      0) break ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}

linux_bbr() {
  while true; do
    clear 2>/dev/null || true
    echo "BBR管理"
    echo "------------------------"
    echo "当前拥塞算法: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    echo "当前队列算法: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
    echo "------------------------"
    echo "1. 开启 BBR + fq"
    echo "2. 查看状态"
    echo "0. 返回上一级"
    read -r -p "请输入你的选择: " choice
    case "$choice" in
      1)
        need_root
        cat >/etc/sysctl.d/99-lf-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
        sysctl --system >/dev/null || true
        success "已尝试开启 BBR"
        pause_return
        ;;
      2) sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || true; pause_return ;;
      0) break ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}

linux_docker() {
  while true; do
    clear 2>/dev/null || true
    echo "Docker管理"
    echo "------------------------"
    echo "1. 安装/更新 Docker 环境"
    echo "2. 查看 Docker 全局状态"
    echo "3. 查看容器列表"
    echo "4. 查看镜像列表"
    echo "5. 清理无用镜像/缓存"
    echo "0. 返回上一级"
    read -r -p "请输入你的选择: " choice
    case "$choice" in
      1) need_root; ensure_curl; install_docker; ensure_compose; pause_return ;;
      2) docker info; pause_return ;;
      3) docker ps -a --format 'table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}'; pause_return ;;
      4) docker image ls; pause_return ;;
      5) docker system prune -af; pause_return ;;
      0) break ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}

linux_warp() {
  clear 2>/dev/null || true
  echo "WARP管理"
  echo "------------------------"
  echo "将调用 fscarmen WARP 官方菜单脚本。"
  read -r -p "是否继续？[y/N]: " answer
  case "$answer" in
    y|Y) install_pkg wget || true; wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh ;;
    *) return 0 ;;
  esac
}

linux_test() {
  while true; do
    clear 2>/dev/null || true
    echo "测试脚本合集"
    echo "------------------------"
    echo "1. bench.sh 基准测试"
    echo "2. IP质量/解锁检测入口提示"
    echo "0. 返回上一级"
    read -r -p "请输入你的选择: " choice
    case "$choice" in
      1) curl -Lso- bench.sh | bash; pause_return ;;
      2) echo "可按需运行第三方检测脚本；请确认来源可信后执行。"; pause_return ;;
      0) break ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}

linux_oracle() {
  clear 2>/dev/null || true
  echo "甲骨文云脚本合集"
  echo "------------------------"
  echo "当前版本仅提供兼容入口。建议按需使用原 kejilion 菜单里的甲骨文云功能。"
  echo "运行：bash <(curl -sL kejilion.sh)，选择 9。"
  pause_return
}

linux_ldnmp() {
  clear 2>/dev/null || true
  echo "LDNMP建站"
  echo "------------------------"
  echo "当前版本仅提供兼容入口。LDNMP 功能体量较大，建议使用原 kejilion 菜单。"
  echo "运行：bash <(curl -sL kejilion.sh)，选择 10。"
  pause_return
}

app_market() {
  while true; do
    clear 2>/dev/null || true
    echo "应用市场"
    echo "------------------------"
    echo "1. Check CX - AI 模型 API 健康监控面板"
    echo "------------------------"
    echo "0. 返回上一级"
    echo "------------------------"
    read -r -p "请输入你的选择: " choice
    case "$choice" in
      1) check_cx_menu ;;
      0) break ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}

check_cx_container_status() {
  local label="$1"
  local name="$2"
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
    docker ps -a --filter "name=^/${name}$" --format "$label: {{.Status}}"
  else
    echo "$label: 未安装"
  fi
}

check_cx_status() {
  echo "Check CX 状态"
  echo "------------------------"
  check_cx_container_status "前台容器" "$APP_NAME"
  check_cx_container_status "后台容器" "$ADMIN_APP_NAME"
  check_cx_container_status "Auth容器" "$AUTH_CONTAINER"
  check_cx_container_status "数据库容器" "$DB_CONTAINER"
  check_cx_container_status "REST容器" "$POSTGREST_CONTAINER"
  check_cx_container_status "网关容器" "$GATEWAY_CONTAINER"
  echo "安装目录: $INSTALL_DIR"
  echo "配置文件: $ENV_FILE"
  echo ""
  print_single_access_url "前台监控面板" "$DEFAULT_PORT"
  print_single_access_url "后台管理面板" "$ADMIN_PORT"
  print_single_access_url "Supabase 兼容 API" "$API_PORT"
}

check_cx_urls() {
  load_env_file
  echo "Check CX 访问地址"
  echo "------------------------"
  print_single_access_url "前台监控面板" "$DEFAULT_PORT"
  print_single_access_url "后台管理面板" "$ADMIN_PORT"
  print_single_access_url "Supabase 兼容 API" "$API_PORT"
  echo ""
  echo "后台 OAuth 相关地址:"
  echo "  GitHub OAuth App 回调地址: ${GITHUB_CALLBACK_URL:-${API_EXTERNAL_URL:-$(api_external_url)}/callback}"
  echo "  后台登录回跳地址: ${APP_URL:-$(access_url_for_port "$ADMIN_PORT")}/auth/callback"
}

check_cx_admin_guide() {
  need_root
  ensure_curl
  write_env_file
  load_env_file

  clear 2>/dev/null || true
  echo "Check CX 后台管理配置"
  echo "------------------------"
  echo "后台地址: ${APP_URL:-$(access_url_for_port "$ADMIN_PORT")}"
  echo "Supabase 兼容 API: ${PUBLIC_SUPABASE_URL:-$(api_public_url)}"
  echo "GitHub OAuth App 回调地址: ${GITHUB_CALLBACK_URL:-${API_EXTERNAL_URL:-$(api_external_url)}/callback}"
  echo "后台登录回跳地址: ${APP_URL:-$(access_url_for_port "$ADMIN_PORT")}/auth/callback"
  echo "------------------------"
  echo "GitHub OAuth App 新建步骤:"
  echo "1. 打开 GitHub: https://github.com/settings/developers"
  echo "2. 进入 OAuth Apps -> New OAuth App。"
  echo "3. Application name 可填: Check CX Admin。"
  echo "4. Homepage URL 填后台地址: ${APP_URL:-$(access_url_for_port "$ADMIN_PORT")}"
  echo "5. Authorization callback URL 填: ${GITHUB_CALLBACK_URL:-${API_EXTERNAL_URL:-$(api_external_url)}/callback}"
  echo "6. 创建后复制 Client ID，再点 Generate a new client secret 复制 Secret。"
  echo "7. ADMIN_EMAILS 填允许进后台的 GitHub 邮箱，多个邮箱用英文逗号分隔。"
  echo "------------------------"

  read -r -p "现在写入 GitHub OAuth 配置吗？[y/N]: " answer
  case "$answer" in
    y|Y)
      local client_id client_secret admin_emails
      read -r -p "GitHub Client ID: " client_id
      read -r -s -p "GitHub Client Secret（输入不回显）: " client_secret
      echo ""
      read -r -p "ADMIN_EMAILS（允许登录的 GitHub 邮箱，多个用英文逗号）: " admin_emails

      if [ -z "$client_id" ] || [ -z "$client_secret" ] || [ -z "$admin_emails" ]; then
        warn "Client ID、Client Secret、ADMIN_EMAILS 都不能为空，已取消写入。"
        return 0
      fi

      set_env_value "GITHUB_ENABLED" "true"
      set_env_value "GITHUB_CLIENT_ID" "$client_id"
      set_env_value "GITHUB_CLIENT_SECRET" "$client_secret"
      set_env_value "ADMIN_EMAILS" "$admin_emails"
      load_env_file
      success "后台 OAuth 配置已写入 $ENV_FILE"

      if [ -f "$COMPOSE_FILE" ]; then
        ensure_docker
        ensure_compose
        write_compose_file
        write_nginx_file
        init_local_database
        info "正在重启后台、Auth 和 API 网关..."
        (cd "$INSTALL_DIR" && "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" up -d check-cx-auth check-cx-gateway check-cx-admin)
        success "后台相关服务已重启"
      else
        warn "还没有部署 Compose 文件，请执行: lf app check-cx install"
      fi
      ;;
    *)
      info "已跳过写入。需要时重新执行: lf app check-cx admin"
      ;;
  esac
}
check_cx_menu() {
  while true; do
    clear 2>/dev/null || true
    echo "Check CX 管理"
    echo "------------------------"
    check_cx_status
    echo "------------------------"
    echo "1. 安装 / 更新"
    echo "2. 查看状态"
    echo "3. 查看访问地址"
    echo "4. 查看全部日志"
    echo "5. 卸载，保留数据"
    echo "6. 彻底删除"
    echo "7. 配置后台登录 / OAuth"
    echo "0. 返回上一级"
    echo "------------------------"
    read -r -p "请输入你的选择: " choice
    case "$choice" in
      1) deploy; pause_return ;;
      2) check_cx_status; pause_return ;;
      3) check_cx_urls; pause_return ;;
      4) show_logs ;;
      5) uninstall; pause_return ;;
      6) purge; pause_return ;;
      7) check_cx_admin_guide ;;
      0) break ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}

check_cx_dispatch() {
  local action="${1:-menu}"
  case "$action" in
    menu|manage|管理) check_cx_menu ;;
    install|deploy|update|安装|更新) deploy ;;
    status|状态) check_cx_status ;;
    url|urls|address|地址) check_cx_urls ;;
    logs|log|日志) show_logs ;;
    uninstall|remove|卸载) uninstall ;;
    purge|destroy|删除) purge ;;
    admin|后台) check_cx_admin_guide ;;
    *)
      echo "Check CX 用法:"
      echo "  lf app check-cx"
      echo "  lf app check-cx install|update|status|url|logs|uninstall|purge|admin"
      return 1
      ;;
  esac
}

app_dispatch() {
  local app="${1:-market}"
  shift || true
  case "$app" in
    market|list|应用市场|"") app_market ;;
    check-cx|checkcx|cx) check_cx_dispatch "$@" ;;
    *)
      warn "未知应用: $app"
      echo "可用应用: check-cx"
      return 1
      ;;
  esac
}

show_help() {
  cat <<EOF
用法：
  lf                                  # 打开主菜单
  lf app                              # 打开应用市场
  lf app check-cx                     # 打开 Check CX 管理页
  lf app check-cx install             # 安装/更新 Check CX
  lf app check-cx status              # 查看状态
  lf app check-cx url                 # 查看访问地址
  lf app check-cx logs                # 查看日志
  lf app check-cx uninstall           # 卸载容器，保留数据
  lf app check-cx purge               # 彻底删除容器、配置和数据库
  lf self-update                      # 手动更新 lf 脚本
  lf version                          # 查看脚本版本和快捷命令状态

兼容旧命令：
  lf install | lf update | lf logs | lf uninstall | lf purge

系统功能：
  lf info | lf system-update | lf clean | lf tools | lf bbr | lf docker | lf warp | lf test | lf oracle | lf ldnmp
EOF
}

show_version() {
  echo "lf.sh version: $SCRIPT_VERSION"
  echo "script url: $SCRIPT_URL"
  if [ -f /usr/local/bin/lf ]; then
    echo "shortcut: /usr/local/bin/lf"
  else
    echo "shortcut: 未安装"
  fi
}

main() {
  auto_update_self "$@"
  install_self_shortcut

  if [ $# -eq 0 ]; then
    main_menu_loop
    return 0
  fi

  local cmd="$1"
  shift || true
  case "$cmd" in
    app|应用市场)
      app_dispatch "$@"
      ;;
    deploy|install|update|安装|更新)
      check_cx_dispatch install
      ;;
    status|状态)
      check_cx_dispatch status
      ;;
    url|urls|address|地址)
      check_cx_dispatch url
      ;;
    logs|log|日志)
      check_cx_dispatch logs
      ;;
    uninstall|remove|卸载)
      check_cx_dispatch uninstall
      ;;
    purge|destroy|删除)
      check_cx_dispatch purge
      ;;
    info|system-info|系统信息)
      linux_info
      ;;
    system-update|sys-update|系统更新)
      linux_update
      ;;
    clean|系统清理)
      linux_clean
      ;;
    tools|基础工具)
      linux_tools
      ;;
    bbr|BBR)
      linux_bbr
      ;;
    docker|Docker)
      linux_docker
      ;;
    warp|WARP)
      linux_warp
      ;;
    test|bench|测试)
      linux_test
      ;;
    oracle|甲骨文)
      linux_oracle
      ;;
    ldnmp|web|建站)
      linux_ldnmp
      ;;
    00|self-update|script-update|脚本更新)
      update_self
      ;;
    version|-v|--version|版本)
      show_version
      ;;
    help|-h|--help)
      show_help
      ;;
    *)
      show_help
      return 1
      ;;
  esac
}

main "$@"
