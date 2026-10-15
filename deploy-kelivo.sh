#!/usr/bin/env bash
#
# Dylan Heartbeat — 一键安装（支持「Caddy 装在 Docker 里」的情况）
#
# 用法：
#   sudo bash deploy-kelivo.sh kelivo.7963.online
#
# 特点：
#   · 自动识别 Caddy 是装在服务器上、还是跑在 Docker 容器里
#   · Docker 情况下用 compose.override.yaml 加 host-gateway，
#     完全不修改你现有的 compose.yaml
#   · 改动前一律备份，配置校验不过就自动回滚
#   · 不安装 Nginx
#
set -euo pipefail

DOMAIN="${1:-}"
APP_DIR="${APP_DIR:-/opt/dylan-heartbeat}"
REPO="${REPO:-https://github.com/Xiaoxiao-Claire/dylan-heartbeat.git}"
GATEWAY_PORT="${GATEWAY_PORT:-3000}"

c()    { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
w()    { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
e()    { printf '\033[1;31m[x] %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[✓] %s\033[0m\n' "$*"; }
line() { printf '%s\n' "------------------------------------------------------------"; }

[[ $EUID -eq 0 ]] || { e "请用 sudo 运行"; exit 1; }
if [[ -z $DOMAIN ]]; then
  e "缺少域名参数"; echo "  用法: sudo bash $0 kelivo.example.com"; exit 1
fi

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)" || TARGET_HOME=""
[[ -n $TARGET_HOME ]] || TARGET_HOME="/root"

run_as() {
  if [[ $TARGET_USER == root ]]; then bash -lc "$1"
  else sudo -u "$TARGET_USER" -H bash -lc "$1"; fi
}

# 结尾 || true 必须保留：set -o pipefail 下 head 提前退出会让 tr 收到 SIGPIPE(141)，
# 没有兜底的话赋值会被 set -e 判定失败，脚本中断。
gen() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$1" || true; }

echo
echo "============================================================"
echo "        Dylan Heartbeat 自动安装程序"
echo "============================================================"
echo "  域名      : $DOMAIN"
echo "  安装目录  : $APP_DIR"
echo "  监听端口  : $GATEWAY_PORT"
line

# ============================================================
# 检查 1：定位 Caddy（本机 or Docker）
# ============================================================
c "检查 1/8：定位 Caddy"

CADDY_MODE=""; CADDYFILE=""; CADDY_CONTAINER=""

if command -v caddy >/dev/null 2>&1 && [[ -f /etc/caddy/Caddyfile ]]; then
  CADDY_MODE="host"; CADDYFILE="/etc/caddy/Caddyfile"
  ok "Caddy 装在服务器本机"
elif command -v docker >/dev/null 2>&1; then
  while IFS= read -r cname; do
    [[ -n $cname ]] || continue
    src="$(docker inspect "$cname" \
      -f '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}' \
      2>/dev/null || true)"
    if [[ -n $src && -f $src ]]; then
      CADDY_MODE="docker"; CADDY_CONTAINER="$cname"; CADDYFILE="$src"
      break
    fi
  done < <(docker ps --format '{{.Names}}' 2>/dev/null || true)
fi

if [[ -z $CADDY_MODE ]]; then
  e "没找到 Caddy。请把屏幕截图发给我。"
  exit 1
fi

if [[ $CADDY_MODE == docker ]]; then
  ok "Caddy 跑在 Docker 容器里：$CADDY_CONTAINER"
fi
echo "Caddyfile : $CADDYFILE"

# 如果是 Docker 模式，还要找到 compose 文件
COMPOSE_DIR=""; COMPOSE_FILE=""; COMPOSE_CMD=""
if [[ $CADDY_MODE == docker ]]; then
  COMPOSE_DIR="$(dirname "$CADDYFILE")"
  if docker compose version >/dev/null 2>&1; then COMPOSE_CMD="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then COMPOSE_CMD="docker-compose"
  else e "找不到 docker compose 命令，请截图发我"; exit 1; fi

  for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    if [[ -f "$COMPOSE_DIR/$f" ]]; then COMPOSE_FILE="$COMPOSE_DIR/$f"; break; fi
  done
  [[ -n $COMPOSE_FILE ]] || { e "在 $COMPOSE_DIR 里找不到 compose 文件，请截图发我"; exit 1; }
  echo "compose   : $COMPOSE_FILE"
fi

# ============================================================
# 检查 2：端口占用
# ============================================================
c "检查 2/8：端口 $GATEWAY_PORT 是否被占用"
port_busy=0
# 注意：这里必须用 if，不能写 `grep ... && port_busy=1`。
# set -e 下 AND 列表整体返回非零有触发退出的风险，if 条件是明确豁免的。
if command -v ss >/dev/null 2>&1; then
  if ss -ltn 2>/dev/null | grep -qE "[:.]${GATEWAY_PORT}[[:space:]]"; then port_busy=1; fi
elif command -v netstat >/dev/null 2>&1; then
  if netstat -ltn 2>/dev/null | grep -qE "[:.]${GATEWAY_PORT}[[:space:]]"; then port_busy=1; fi
fi
if [[ $port_busy -eq 1 ]]; then
  e "端口 $GATEWAY_PORT 已被别的程序占用，请把下面的截图发给我："
  ss -ltnp 2>/dev/null | grep -E "[:.]${GATEWAY_PORT}[[:space:]]" || true
  exit 1
fi
ok "端口空闲"

# ============================================================
# 检查 3：系统依赖
# ============================================================
if   command -v apt-get >/dev/null 2>&1; then PM=apt
elif command -v dnf     >/dev/null 2>&1; then PM=dnf
elif command -v yum     >/dev/null 2>&1; then PM=yum
else e "无法识别系统类型，请截图发我"; exit 1; fi

c "检查 3/8：基础工具（git、curl）"
case $PM in
  apt) apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl ca-certificates ;;
  *)   $PM install -y -q git curl ca-certificates ;;
esac
ok "基础工具就绪"

# ============================================================
# 检查 4：Node.js
# ============================================================
c "检查 4/8：Node.js（需要 20 以上）"
need_node=1
if command -v node >/dev/null 2>&1; then
  major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  if [[ $major -ge 20 ]]; then need_node=0; ok "已有 Node $(node -v)"; fi
fi
if [[ $need_node -eq 1 ]]; then
  echo "正在安装 Node.js 22，大约 1-2 分钟，请耐心等..."
  if [[ $PM == apt ]]; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
  else
    curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
    $PM install -y nodejs
  fi
  ok "已安装 Node $(node -v)"
fi

# ============================================================
# 检查 5：pm2
# ============================================================
c "检查 5/8：pm2（让程序一直后台运行）"
npm install -g pm2 >/dev/null 2>&1
ok "pm2 $(pm2 -v 2>/dev/null || echo ok)"

# ============================================================
# 检查 6：下载代码
# ============================================================
c "检查 6/8：下载 Dylan Heartbeat"
mkdir -p "$(dirname "$APP_DIR")"
if [[ -d "$APP_DIR/.git" ]]; then
  w "目录已存在，执行更新"
  git -C "$APP_DIR" pull --ff-only || true
else
  git clone "$REPO" "$APP_DIR"
fi
chown -R "$TARGET_USER" "$APP_DIR"
echo "正在安装依赖，约 1 分钟..."
run_as "cd $APP_DIR && npm install --no-audit --no-fund"
ok "代码就绪"

# ============================================================
# 检查 7：交互式配置
# ============================================================
c "检查 7/8：填写配置"

if [[ -f "$APP_DIR/.env" ]]; then
  w "$APP_DIR/.env 已存在，跳过问答，保留原配置"
else
  cp "$APP_DIR/.env.example" "$APP_DIR/.env"

  ADMIN_PW="$(gen 32)"; GW_KEY="$(gen 48)"
  if [[ ${#ADMIN_PW} -ne 32 || ${#GW_KEY} -ne 48 ]]; then
    e "随机密码生成失败，请截图发我"; exit 1
  fi

  echo
  echo "============================================================"
  echo "  下面问你 4 个问题"
  echo "  不知道的直接按回车跳过，最后我再教你补"
  echo "============================================================"

  ask() {
    echo
    line
    printf '\033[1;36m【%s】%s\033[0m\n' "$1" "$2"
    printf '%s\n' "$3"
    echo
    read -rp "  粘贴后按回车: " _ans || _ans=""
    _ans="$(printf '%s' "$_ans" | tr -d '\r')"
    if [[ -z $_ans ]]; then w "已跳过，稍后需要手动补"; _ans="$5"; fi
    sed -i "s|^$4=.*|$4=$(printf '%s' "$_ans" | sed 's/[&|\\]/\\&/g')|" "$APP_DIR/.env"
  }

  ask "1/4" "AI 接口地址" \
"  https://api.deepseek.com/chat/completions" \
    "TARGET_API_URL" "https://api地址/v1/chat/completions"

  ask "2/4" "AI 接口密钥（sk- 开头那串）" \
"  从 https://platform.deepseek.com/api_keys 复制
  如果后台只显示 sk-**** 看不到内容，就新建一个" \
    "TARGET_API_KEY" "你的APIKey"

  ask "3/4" "模型名称" \
"  打开 Kelivo → 底部「模型」标签 → 看你勾选的名字
  通常是 deepseek-chat" \
    "MODEL_NAME" "你的模型名称"

  ask "4/4" "Bark 推送钥匙" \
"  手机 Bark → 服务器列表 → api.day.app → 那串字符" \
    "BARK_KEY" "你的BarkKey"

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
  echo "  ★★★ 请立刻抄下这两串，只显示这一次 ★★★"
  echo "============================================================"
  echo "   管理页面密码（用户名 admin）："
  echo "      $ADMIN_PW"
  echo
  echo "   Kelivo 要填的 Gateway Key："
  echo "      $GW_KEY"
  echo "============================================================"
fi

# ============================================================
# 检查 8：启动服务
# ============================================================
c "检查 8/8：启动服务"
run_as "cd $APP_DIR && pm2 delete gateway wake-up >/dev/null 2>&1 || true"
run_as "cd $APP_DIR && pm2 start server.js --name gateway >/dev/null"
run_as "cd $APP_DIR && pm2 start wake_up.js --name wake-up >/dev/null"
run_as "pm2 save >/dev/null 2>&1 || true"
pm2 startup systemd -u "$TARGET_USER" --hp "$TARGET_HOME" >/dev/null 2>&1 || \
  w "开机自启设置失败（不影响现在使用）"

sleep 3
if curl -fsS "http://127.0.0.1:${GATEWAY_PORT}/healthz" >/dev/null 2>&1; then
  ok "服务已启动（本机 $GATEWAY_PORT 有响应）"
else
  w "本机 $GATEWAY_PORT 暂时没响应，继续配置反代，稍后一起检查"
fi

# ============================================================
# 配置 Caddy
# ============================================================
c "配置 Caddy 反向代理"

if [[ $CADDY_MODE == docker ]]; then
  UPSTREAM="host.docker.internal:${GATEWAY_PORT}"
else
  UPSTREAM="127.0.0.1:${GATEWAY_PORT}"
fi

CADDY_BACKUP=""
if grep -qE "^[[:space:]]*${DOMAIN}[[:space:]]*\{" "$CADDYFILE"; then
  w "Caddyfile 里已有 $DOMAIN，跳过追加"
else
  CADDY_BACKUP="${CADDYFILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CADDYFILE" "$CADDY_BACKUP"
  echo "已备份到 $CADDY_BACKUP"

  cat >> "$CADDYFILE" <<CADDY_EOF

# --- Dylan Heartbeat Gateway ---
${DOMAIN} {
	handle /internal/* {
		respond 404
	}

	handle {
		reverse_proxy ${UPSTREAM} {
			flush_interval -1
		}
	}
}
CADDY_EOF
fi

# --- 校验配置 ---
echo "正在校验 Caddy 配置..."
validate_ok=0
if [[ $CADDY_MODE == host ]]; then
  caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 && validate_ok=1
else
  docker run --rm --entrypoint caddy \
    -v "$CADDYFILE:/etc/caddy/Caddyfile:ro" \
    caddy:2 validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 && validate_ok=1
fi

if [[ $validate_ok -ne 1 ]]; then
  e "配置校验失败，正在自动还原"
  if [[ $CADDY_MODE == host ]]; then
    caddy validate --config "$CADDYFILE" --adapter caddyfile || true
  else
    docker run --rm --entrypoint caddy -v "$CADDYFILE:/etc/caddy/Caddyfile:ro" \
      caddy:2 validate --config /etc/caddy/Caddyfile --adapter caddyfile || true
  fi
  if [[ -n $CADDY_BACKUP ]]; then
    cp "$CADDY_BACKUP" "$CADDYFILE"
    e "已还原，你现有的网站没受影响"
  fi
  exit 1
fi
ok "配置语法正确"

# --- Docker 模式：加 host-gateway ---
if [[ $CADDY_MODE == docker ]]; then
  OVERRIDE="$COMPOSE_DIR/compose.override.yaml"
  if [[ -f $OVERRIDE ]] && grep -q "host.docker.internal" "$OVERRIDE"; then
    w "compose.override.yaml 已存在，跳过"
  else
    if [[ -f $OVERRIDE ]]; then
      cp "$OVERRIDE" "${OVERRIDE}.bak.$(date +%Y%m%d%H%M%S)"
    fi
    cat > "$OVERRIDE" <<'OVERRIDE_EOF'
# 由 Dylan Heartbeat 安装程序生成。
# 作用：让 caddy 容器能通过 host.docker.internal 访问服务器本机的端口。
# 想完全还原：删掉本文件，然后执行 docker compose up -d
services:
  caddy:
    extra_hosts:
      - "host.docker.internal:host-gateway"
OVERRIDE_EOF
    ok "已创建 $OVERRIDE（没有改动你原有的 compose.yaml）"
  fi
fi

# --- 应用 ---
echo "正在应用配置（caddy 会重启几秒，期间网站短暂不可访问）..."
if [[ $CADDY_MODE == host ]]; then
  systemctl reload caddy 2>/dev/null || caddy reload --config "$CADDYFILE" --adapter caddyfile
else
  ( cd "$COMPOSE_DIR" && $COMPOSE_CMD up -d ) >/dev/null 2>&1 || {
    e "docker compose up 失败，请把截图发我"; exit 1; }
fi
ok "Caddy 已重新加载"

# ============================================================
# 完成
# ============================================================
cat <<EOF

============================================================
  ★★★ 安装完成 ★★★
============================================================

 现在做 2 件收尾的事：

 【1】确认 3000 端口没有对公网开放
   腾讯云控制台 → 轻量应用服务器 → 防火墙
   确认放行列表里没有 3000（有 80、443 就够了）

 【2】验证（浏览器打开）
   https://$DOMAIN/v1/models
     ● 显示 401 或要求密码  → 成功 ✅
     ● 显示 403            → 有问题，截图发我
     ● 打不开              → 有问题，截图发我
   （Caddy 申请证书需要 1-2 分钟，稍等一下再试）

 常用命令：
   查看状态： pm2 status
   查看日志： pm2 logs
   重启服务： pm2 restart gateway wake-up --update-env
   改配置：   nano $APP_DIR/.env

 想撤销 Caddy 改动：
   恢复 $CADDYFILE 的 .bak 备份，
   删除 $COMPOSE_DIR/compose.override.yaml，
   再执行 docker compose up -d

============================================================
EOF
