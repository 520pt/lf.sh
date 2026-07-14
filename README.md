# lf.sh

Check CX 一键 Docker 部署脚本。

## 首次安装前先准备 Supabase

`check-cx` 需要 Supabase 保存监控配置和历史数据。首次运行脚本时，如果还没有 `/opt/check-cx/.env`，脚本会先显示准备教程，并询问你是否已经完成 Supabase 初始化。

需要准备：

1. 打开 Supabase 控制台：
   <https://supabase.com/dashboard>
2. 新建一个 Project。
3. 进入项目后打开：`Project Settings -> API`。
4. 准备 3 个值：
   - `SUPABASE_URL`：Project URL
   - `SUPABASE_PUBLISHABLE_OR_ANON_KEY`：anon public / publishable key
   - `SUPABASE_SERVICE_ROLE_KEY`：service_role key
5. 打开 Supabase 的 SQL Editor，执行 check-cx 的数据库结构：
   <https://raw.githubusercontent.com/BingZi-233/check-cx/master/supabase/schema.sql>

完成后再运行安装脚本。

## 使用

```bash
bash <(curl -sL https://raw.githubusercontent.com/520pt/lf.sh/main/lf.sh)
```

如果需要 sudo：

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/520pt/lf.sh/main/lf.sh)
```

## 常用命令

```bash
bash <(curl -sL https://raw.githubusercontent.com/520pt/lf.sh/main/lf.sh) update
bash <(curl -sL https://raw.githubusercontent.com/520pt/lf.sh/main/lf.sh) logs
bash <(curl -sL https://raw.githubusercontent.com/520pt/lf.sh/main/lf.sh) uninstall
```

## 非交互安装

如果你已经准备好 Supabase，也可以通过环境变量传入：

```bash
SUPABASE_URL="https://你的项目.supabase.co" \
SUPABASE_PUBLISHABLE_OR_ANON_KEY="你的 anon/public key" \
SUPABASE_SERVICE_ROLE_KEY="你的 service_role key" \
bash <(curl -sL https://raw.githubusercontent.com/520pt/lf.sh/main/lf.sh)
```

`SUPABASE_SERVICE_ROLE_KEY` 是敏感密钥，不要公开分享。