#!/usr/bin/env bash
#
# Dylan Heartbeat — 自有服务器一键部署（会问你 4 个问题）
#
# 适用：已经装了 Caddy 的 Linux 服务器（腾讯云 / Ubuntu / Debian 等）
#
# 用法：
#   sudo bash deploy-kelivo.sh kelivo.7963.online
#
# 脚本会问你 4 个问题，其它全部自动完成。
# 全程不会安装 Nginx（会和 Caddy 抢端口），不会碰你现有的其它站点。
#
set -euo pipefail

DOMAIN="${1:-}"
APP_DIR="${APP_DIR:-/opt/dylan-heartbeat}"
REPO="${REPO:-https://github.com/Xiaoxiao-Claire/dylan-heartbeat.git}"
GATEWAY_PORT="${GATEWAY_PORT:-3000}"

c() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
w() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
e() { printf '\033[1;31m[x] %s\033[0m\n' "$*"; }
line() { printf '\033[0;37m%s\033[0m\n' "------------------------------------------------------------"; }

[[ $EUID -eq 0 ]] || { e "请用 sudo 运行"; exit 1; }
if [[ -z $DOMAIN ]]; then
  e "缺少域名参数"
  echo "  用法: sudo bash $0 kelivo.example.com"
  exit 1
fi

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)" || TARGET_HOME=""
[[ -n $TARGET_HOME ]] || TARGET_HOME="/root"

run_as() {
  if [[ $TARGET_USER == root ]]; then
    bash -lc "$1"
  else
    sudo -u "$TARGET_USER" -H bash -lc "$1"
  fi
}

# 结尾的 || true 是必须的：set -o pipefail 下 head 提前退出会让 tr 收到 SIGPIPE（141），
# 没有兜底的话赋值语句会被 set -e 判定失败，脚本直接中断。
gen() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$1" || true; }

echo
echo "============================================================"
echo "        Dylan Heartbeat 自动安装程序"
echo "============================================================"
echo
echo "  域名      : $DOMAIN"
echo "  安装目录  : $APP_DIR"
echo "  监听端口  : $GATEWAY_PORT （只对本机开放，由 Caddy 转发）"
echo
line

# ---------- 1. 检查 Caddy ----------
c "检查 1/8：Caddy 是否正常"
if ! command -v caddy >/dev/null 2>&1; then
  e "没找到 caddy。这台机器可能不是用 Caddy 的，请把这个截图发给我。"
  exit 1
fi
caddy version 2>/dev/null || true

CADDYFILE="${CADDYFILE:-}"
if [[ -z $CADDYFILE ]]; then
  if [[ -f /etc/caddy/Caddyfile ]]; then
    CADDYFILE="/etc/caddy/Caddyfile"
  else
    CADDYFILE="$(systemctl cat caddy 2>/dev/null \
      | grep -oE '\-\-config[= ][^ ]+' | head -1 \
      | sed -E 's/--config[= ]//')" || true
  fi
fi
if [[ -z $CADDYFILE || ! -f $CADDYFILE ]]; then
  e "找不到 Caddyfile，请把这个截图发给我。"
  exit 1
fi
echo "配置文件: $CADDYFILE"

# ---------- 2. 端口检查 ----------
c "检查 2/8：端口 $GATEWAY_PORT 是否被占用"
port_busy=0
if command -v ss >/dev/null 2>&1; then
  if ss -ltn 2>/dev/null | grep -qE "[:.]${GATEWAY_PORT}[[:space:]]"; then port_busy=1; fi
elif command -v netstat >/dev/null 2>&1; then
  if netstat -ltn 2>/dev/null | grep -qE "[:.]${GATEWAY_PORT}[[:space:]]"; then port_busy=1; fi
fi
if [[ $port_busy -eq 1 ]]; then
  w "端口 $GATEWAY_PORT 已被别的程序占用。"
  w "请把这个截图发给我，不要继续。"
  ss -ltnp 2>/dev/null | grep -E "[:.]${GATEWAY_PORT}[[:space:]]" || true
  exit 1
fi
echo "端口空闲，可以继续"

# ---------- 3. 系统依赖 ----------
if   command -v apt-get >/dev/null 2>&1; then PM=apt
elif command -v dnf     >/dev/null 2>&1; then PM=dnf
elif command -v yum     >/dev/null 2>&1; then PM=yum
else e "无法识别系统类型，请把截图发给我"; exit 1
fi

c "检查 3/8：安装基础工具（git、curl）"
case $PM in
  apt) apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl ca-certificates ;;
  *)   $PM install -y -q git curl ca-certificates ;;
esac

# ---------- 4. Node.js ----------
c "检查 4/8：Node.js（需要 20 以上）"
need_node=1
if command -v node >/dev/null 2>&1; then
  major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  if [[ $major -ge 20 ]]; then need_node=0; echo "已有 Node $(node -v)，跳过安装"; fi
fi
if [[ $need_node -eq 1 ]]; then
  echo "正在安装 Node.js 22，大约需要 1-2 分钟..."
  if [[ $PM == apt ]]; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
  else
    curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
    $PM install -y nodejs
  fi
fi
node -v

# ---------- 5. pm2 ----------
c "检查 5/8：pm2（后台守护程序）"
npm install -g pm2 >/dev/null
pm2 -v

# ---------- 6. 下载代码 ----------
c "检查 6/8：下载 Dylan Heartbeat 代码"
mkdir -p "$(dirname "$APP_DIR")"
if [[ -d "$APP_DIR/.git" ]]; then
  w "目录已存在，执行更新"
  git -C "$APP_DIR" pull --ff-only
else
  git clone "$REPO" "$APP_DIR"
fi
chown -R "$TARGET_USER" "$APP_DIR"

echo "正在安装依赖，大约需要 1 分钟..."
run_as "cd $APP_DIR && npm install --no-audit --no-fund"

# ---------- 7. 交互式配置 ----------
c "检查 7/8：填写配置（4 个问题）"

if [[ -f "$APP_DIR/.env" ]]; then
  w "$APP_DIR/.env 已存在，跳过问答，保留你原来的配置"
else
  cp "$APP_DIR/.env.example" "$APP_DIR/.env"

  ADMIN_PW="$(gen 32)"
  GW_KEY="$(gen 48)"
  if [[ ${#ADMIN_PW} -ne 32 || ${#GW_KEY} -ne 48 ]]; then
    e "随机密码生成失败，请把截图发给我"
    exit 1
  fi

  echo
  echo "============================================================"
  echo "  下面问你 4 个问题。"
  echo "  不知道答案的，直接按回车跳过，最后我会告诉你怎么补。"
  echo "============================================================"

  ask() {
    # $1=编号 $2=标题 $3=说明 $4=变量名 $5=默认占位
    echo
    line
    printf '\033[1;36m【%s】%s\033[0m\n' "$1" "$2"
    printf '%s\n' "$3"
    echo
    read -rp "  粘贴到这里，然后按回车: " _ans || _ans=""
    _ans="$(printf '%s' "$_ans" | tr -d '\r')"
    if [[ -z $_ans ]]; then
      w "跳过了，稍后需要手动补"
      _ans="$5"
    fi
    sed -i "s|^$4=.*|$4=$(printf '%s' "$_ans" | sed 's/[&|\\]/\\&/g')|" "$APP_DIR/.env"
  }

  ask "1/4" "你的 AI 接口地址" \
"  打开手机 Kelivo → 设置 → 供应商 → 点开你正在用的那个
  找「接口地址 / Base URL」，它通常长得像：
      https://xxx.com/v1/chat/completions" \
    "TARGET_API_URL" "https://api地址/v1/chat/completions"

  ask "2/4" "你的 AI 接口密钥" \
"  还在刚才那个页面，找「API Key」，一般以 sk- 开头" \
    "TARGET_API_KEY" "你的APIKey"

  ask "3/4" "模型名称" \
"  还是那个页面，看你选的是哪个模型，比如 deepseek-chat
  也可以直接在 Kelivo 聊天界面顶部看到当前模型名" \
    "MODEL_NAME" "你的模型名称"

  ask "4/4" "Bark 推送钥匙（iPhone 上的 Bark App 里）" \
"  如果还没装 Bark，先按回车跳过，装好之后我教你怎么填
  装好 Bark 后打开它，首页那串字符就是" \
    "BARK_KEY" "你的BarkKey"

  # 写入自动生成的两个密钥
  sed -i \
    -e "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${ADMIN_PW}|" \
    -e "s|^GATEWAY_API_KEY=.*|GATEWAY_API_KEY=${GW_KEY}|" \
    -e "s|^ALLOW_PUBLIC_API=.*|ALLOW_PUBLIC_API=true|" \
    -e "s|^PORT=.*|PORT=${GATEWAY_PORT}|" \
    "$APP_DIR/.env"

  chown "$TARGET_USER" "$APP_DIR/.env"
  chmod 600 "$APP_DIR/.env"

  echo
  echo "============================================================"
  echo "  ★ 请把下面两行抄下来（只显示这一次）★"
  echo "============================================================"
  echo
  echo "   管理页面密码（用户名是 admin）:"
  echo "     $ADMIN_PW"
  echo
  echo "   Kelivo 里要填的 Gateway API Key:"
  echo "     $GW_KEY"
  echo
  echo "============================================================"
fi

# ---------- 8. 启动 ----------
c "检查 8/8：启动服务"
run_as "cd $APP_DIR && pm2 delete gateway wake-up >/dev/null 2>&1 || true"
run_as "cd $APP_DIR && pm2 start server.js --name gateway"
run_as "cd $APP_DIR && pm2 start wake_up.js --name wake-up"
run_as "pm2 save"

pm2 startup systemd -u "$TARGET_USER" --hp "$TARGET_HOME" >/dev/null 2>&1 || \
  w "开机自启设置失败（不影响现在使用）"

sleep 3

# ---------- Caddy ----------
c "配置 Caddy 反向代理"
CADDY_BACKUP=""
if grep -qE "^[[:space:]]*${DOMAIN}[[:space:]]*\{" "$CADDYFILE"; then
  w "Caddyfile 里已经有了，跳过"
else
  CADDY_BACKUP="${CADDYFILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CADDYFILE" "$CADDY_BACKUP"
  echo "已备份原配置到 $CADDY_BACKUP"

  cat >> "$CADDYFILE" <<CADDY_EOF

# --- Dylan Heartbeat Gateway ---
${DOMAIN} {
	handle /internal/* {
		respond 404
	}

	handle {
		reverse_proxy 127.0.0.1:${GATEWAY_PORT} {
			flush_interval -1
		}
	}
}
CADDY_EOF
fi

if caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
  systemctl reload caddy 2>/dev/null || caddy reload --config "$CADDYFILE" --adapter caddyfile
  echo "Caddy 已重新加载"
else
  e "Caddy 配置有问题，正在自动恢复原样"
  caddy validate --config "$CADDYFILE" --adapter caddyfile || true
  if [[ -n $CADDY_BACKUP ]]; then
    cp "$CADDY_BACKUP" "$CADDYFILE"
    systemctl reload caddy 2>/dev/null || true
    e "已恢复，你现有的网站没受影响"
  fi
  exit 1
fi

# ---------- 完成 ----------
cat <<EOF

============================================================
  ★★★ 安装完成 ★★★
============================================================

 服务已经在后台运行。现在做最后 2 件事：

 【第一件】把 3000 端口关掉（安全）
   腾讯云控制台 →「安全组」→ 确认里面没有放行 3000
   80 和 443 不要动

 【第二件】检查是否成功
   浏览器打开：  https://$DOMAIN/v1/models
   ● 如果显示 401 或要求密码 → 正常，成功了
   ● 如果显示 403 → 有问题，截图发我
   ● 如果打不开 → 有问题，截图发我

 常用命令：
   查看运行状态：  pm2 status
   查看日志：      pm2 logs
   重启：          pm2 restart gateway wake-up --update-env

 配置文件位置：$APP_DIR/.env （以后要改就改这个）

============================================================
EOF
