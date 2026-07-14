# lf.sh

Check CX 一键 Docker 部署脚本。

## 一键安装命令

```bash
bash <(curl -sL https://raw.githubusercontent.com/520pt/lf.sh/main/lf.sh)
```

如果需要 sudo：

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/520pt/lf.sh/main/lf.sh)
```

## 现在不需要手动创建 Supabase

脚本默认使用本地数据库模式，会在同一台服务器的 Docker Compose 里自动部署：

- `check-cx` 主程序
- PostgreSQL 本地数据库
- PostgREST，本地 Supabase REST API 兼容层
- Nginx REST 网关，把 `/rest/v1/*` 转发给 PostgREST

首次运行时脚本会自动：

1. 检测并安装 Docker / Docker Compose。
2. 生成本地数据库密码、JWT Secret、anon key、service role key。
3. 写入 `/opt/check-cx/.env`。
4. 写入 `/opt/check-cx/docker-compose.yml`。
5. 下载 `check-cx` 的 `supabase/schema.sql`。
6. 启动本地 PostgreSQL。
7. 自动创建 Supabase 兼容角色：`anon`、`authenticated`、`service_role`、`authenticator`。
8. 自动执行数据库表结构初始化。
9. 启动 `check-cx`。

所以用户不需要再去 Supabase 官网创建项目，也不需要手动输入：

- `SUPABASE_URL`
- `SUPABASE_PUBLISHABLE_OR_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`

这些都会由脚本自动生成并写入服务器本地配置。


## 部署完成后会显示什么

部署完成后，脚本会输出完整摘要：

- 前台监控面板访问地址，自动显示公网 IPv4 / IPv6
- 当前后台管理状态说明
- 已部署容器列表
- 安装目录、环境变量文件、Compose 文件、网关配置、数据库目录
- 查看日志、更新、卸载、彻底删除命令

示例：

```text
Check CX 部署信息
前台监控面板:
http://你的公网IPv4:3000
http://[你的IPv6]:3000

后台管理:
当前脚本部署的是 check-cx 前台监控面板 + 本地数据库兼容层。
本地轻量模式暂未内置后台管理入口。

容器:
check-cx                  前台监控面板
check-cx-db               PostgreSQL 本地数据库
check-cx-postgrest        Supabase REST 兼容 API
check-cx-gateway          REST 网关
```
## 部署目录

默认部署在：

```text
/opt/check-cx
```

主要文件：

```text
/opt/check-cx/.env                 # 本地数据库和 check-cx 环境变量，包含密钥
/opt/check-cx/docker-compose.yml   # Docker Compose 配置
/opt/check-cx/nginx.conf           # 本地 REST 网关配置
/opt/check-cx/postgres-data/       # PostgreSQL 数据目录
```

`.env` 里包含敏感密钥，不要公开分享。

## 常用命令

安装或更新：

```bash
bash <(curl -sL https://raw.githubusercontent.com/520pt/lf.sh/main/lf.sh)
```

查看日志：

```bash
bash <(curl -sL https://raw.githubusercontent.com/520pt/lf.sh/main/lf.sh) logs
```

停止并删除容器，保留配置和数据库文件：

```bash
bash <(curl -sL https://raw.githubusercontent.com/520pt/lf.sh/main/lf.sh) uninstall
```

彻底删除数据需要手动执行：

```bash
rm -rf /opt/check-cx
```

## 可选环境变量

修改 Web 端口：

```bash
CHECK_CX_PORT=8080 bash <(curl -sL https://raw.githubusercontent.com/520pt/lf.sh/main/lf.sh)
```

修改安装目录：

```bash
CHECK_CX_INSTALL_DIR=/opt/my-check-cx bash <(curl -sL https://raw.githubusercontent.com/520pt/lf.sh/main/lf.sh)
```

指定数据库 schema 地址：

```bash
CHECK_CX_SCHEMA_URL=https://raw.githubusercontent.com/BingZi-233/check-cx/master/supabase/schema.sql \
bash <(curl -sL https://raw.githubusercontent.com/520pt/lf.sh/main/lf.sh)
```

## 已有旧版远程 Supabase 配置怎么办

如果服务器上已经存在旧版 `/opt/check-cx/.env`，脚本会保留它，不会覆盖。

如果你想切换为本地数据库模式，可以先备份旧配置：

```bash
cp /opt/check-cx/.env /opt/check-cx/.env.bak
```

然后删除旧配置并重新运行脚本：

```bash
rm /opt/check-cx/.env
bash <(curl -sL https://raw.githubusercontent.com/520pt/lf.sh/main/lf.sh)
```
