# lf.sh

LF 脚本工具箱，参考 `kejilion.sh` 的菜单式交互。Check CX 作为“应用市场”里的应用管理。

## 一键启动

```bash
bash <(curl -sL https://raw.githubusercontent.com/520pt/lf.sh/main/lf.sh)
```

首次以 root 运行时会自动安装快捷命令：

```bash
lf
```

之后直接输入 `lf` 打开主菜单。

## 主菜单

```text
LF 脚本工具箱
命令行输入 lf 可快速启动脚本
------------------------
1.   系统信息查询
2.   系统更新
3.   系统清理
4.   基础工具
5.   BBR管理
6.   Docker管理
7.   WARP管理
8.   测试脚本合集
9.   甲骨文云脚本合集
10.  LDNMP建站
11.  应用市场
------------------------
00.  脚本更新
0.   退出脚本
```

## 应用市场模式

打开应用市场：

```bash
lf app
```

进入 Check CX 管理页：

```bash
lf app check-cx
```

别名：

```bash
lf app cx
lf app checkcx
```

## Check CX 直达命令

安装或更新：

```bash
lf app check-cx install
```

查看状态：

```bash
lf app check-cx status
```

查看访问地址：

```bash
lf app check-cx url
```

查看日志：

```bash
lf app check-cx logs
```

卸载容器，保留配置和数据库：

```bash
lf app check-cx uninstall
```

彻底删除容器、配置和本地数据库：

```bash
lf app check-cx purge
```

`purge` 会要求输入 `DELETE` 二次确认。

## 兼容旧命令

这些命令仍然可用，默认映射到 Check CX：

```bash
lf install
lf update
lf status
lf url
lf logs
lf uninstall
lf purge
```

如果还没安装快捷命令，也可以用完整形式：

```bash
bash <(curl -sL https://raw.githubusercontent.com/520pt/lf.sh/main/lf.sh) app check-cx install
```

## Check CX 本地数据库模式

`lf app check-cx install` 会在同一台服务器的 Docker Compose 里自动部署：

- `check-cx` 前台监控面板
- PostgreSQL 本地数据库
- PostgREST，Supabase REST API 兼容层
- Nginx REST 网关，把 `/rest/v1/*` 转发给 PostgREST

不需要手动创建 Supabase 项目，也不需要手动输入：

- `SUPABASE_URL`
- `SUPABASE_PUBLISHABLE_OR_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`

这些都会由脚本自动生成并写入服务器本地配置。

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

`.env` 和 `postgres-data` 包含敏感配置/业务数据，不要公开分享。

## 系统功能直达命令

```bash
lf info
lf system-update
lf clean
lf tools
lf bbr
lf docker
lf warp
lf test
lf oracle
lf ldnmp
```

## 可选环境变量

修改 Web 端口：

```bash
CHECK_CX_PORT=8080 lf app check-cx install
```

修改安装目录：

```bash
CHECK_CX_INSTALL_DIR=/opt/my-check-cx lf app check-cx install
```

指定数据库 schema 地址：

```bash
CHECK_CX_SCHEMA_URL=https://raw.githubusercontent.com/BingZi-233/check-cx/master/supabase/schema.sql \
lf app check-cx install
```

跳过快捷命令安装：

```bash
LF_SKIP_SHORTCUT=1 bash <(curl -sL https://raw.githubusercontent.com/520pt/lf.sh/main/lf.sh)
```
