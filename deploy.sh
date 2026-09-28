#!/usr/bin/env bash
#
# artligent.com — 部署脚本
# ---------------------------------------------------------------------------
# 把本仓库的静态文件 rsync 到源站 nginx 的站点根目录。
#
#   ./deploy.sh              正式发布（发布前自动在服务器上打包备份）
#   ./deploy.sh --dry-run    只预览，不改动线上任何文件
#
# 源站信息来自 ~/Projects/VSep/DEPLOY.md。Cloudflare 会自动回源，无需在
# 服务器上做额外操作；nginx 配置只改动 /etc/nginx/sites-available/artligent.com，
# 本脚本不碰任何 nginx / fail2ban / DNS 配置。
# ---------------------------------------------------------------------------

set -euo pipefail

REMOTE_HOST="101.47.154.162"
REMOTE_PORT="7022"
REMOTE_USER="root"
REMOTE_PATH="/var/www/html"
REMOTE_BACKUP_DIR="/root/backups"

# 保持线上原有的属主（历史文件为 uid 501 / gid staff）。置空字符串则跳过。
REMOTE_OWNER="501:staff"

# 保留最近多少天的备份
BACKUP_KEEP_DAYS="30"

LOCAL_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EXCLUDES=(
  --exclude=.git
  --exclude=.gitignore
  --exclude=.workbuddy
  --exclude=.DS_Store
  --exclude=deploy.sh
  --exclude=README.md
)

SSH_OPTS=(-p "$REMOTE_PORT" -o BatchMode=yes -o ConnectTimeout=15)
SSH_CMD="ssh -p ${REMOTE_PORT} -o BatchMode=yes -o ConnectTimeout=15"
REMOTE="${REMOTE_USER}@${REMOTE_HOST}"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY_RUN=1 ;;
    -h|--help)    sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $arg（可用：--dry-run / --help）" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$1"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$1" >&2; exit 1; }

# --------------------------------------------------------------------------
step "0/5 前置检查"
[ -f "$LOCAL_PATH/index.html" ] || die "本地缺少 index.html，请从仓库根目录运行：$LOCAL_PATH"
[ -d "$LOCAL_PATH/css" ]       || die "本地缺少 css/ 目录"
command -v rsync >/dev/null || die "本机没有 rsync"

LOCAL_FILES=$(cd "$LOCAL_PATH" && find . -type f \
  -not -path './.git/*' -not -path './.workbuddy/*' \
  -not -name '.DS_Store' -not -name 'deploy.sh' | wc -l | tr -d ' ')
echo "本地待发布文件: ${LOCAL_FILES} 个"
echo "目标: ${REMOTE}:${REMOTE_PATH}"
if [ "$DRY_RUN" = "1" ]; then
  warn "DRY-RUN 模式 —— 不会改动线上任何文件"
fi

ssh "${SSH_OPTS[@]}" "$REMOTE" 'echo SSH_OK' >/dev/null 2>&1 \
  || die "SSH 连接失败：${REMOTE}:${REMOTE_PORT}"

ssh "${SSH_OPTS[@]}" "$REMOTE" "test -d '$REMOTE_PATH'" \
  || die "远端目录不存在：$REMOTE_PATH"

# --------------------------------------------------------------------------
step "1/5 预览变更（rsync 干跑）"
PREVIEW=$(rsync -avzc --delete --dry-run -i "${EXCLUDES[@]}" \
  -e "$SSH_CMD" "$LOCAL_PATH/" "$REMOTE:$REMOTE_PATH/" 2>&1)

CHANGED=$(printf '%s\n' "$PREVIEW" | grep -E '^[<>ch]' | wc -l | tr -d ' ')
printf '%s\n' "$PREVIEW" | grep -E '^[<>ch]' | sed 's/^/    /' || true
echo "    -> 待更新条目: ${CHANGED}"

DELETIONS=$(printf '%s\n' "$PREVIEW" | grep -i 'deleting' || true)
if [ -n "$DELETIONS" ]; then
  warn "本次会【删除】线上以下文件（--delete 生效）："
  printf '%s\n' "$DELETIONS" | sed 's/^/    /'
  die "已中止。确认无误后，请手工核对本地仓库是否缺文件，再重新执行。"
fi

if [ "$DRY_RUN" = "1" ]; then
  echo
  echo "DRY-RUN 结束，未做任何改动。去掉 --dry-run 即正式发布。"
  exit 0
fi

# --------------------------------------------------------------------------
step "2/5 备份线上现有内容"
TS=$(date +%Y%m%d-%H%M%S)
BACKUP="${REMOTE_BACKUP_DIR}/artligent-web-${TS}.tar.gz"
ssh "${SSH_OPTS[@]}" "$REMOTE" "
  set -e
  mkdir -p '$REMOTE_BACKUP_DIR'
  tar czf '$BACKUP' -C '$REMOTE_PATH' .
  echo \"    备份文件: $BACKUP\"
  echo \"    包内文件数: \$(tar tzf '$BACKUP' | wc -l | tr -d ' ')\"
  echo \"    大小: \$(du -h '$BACKUP' | cut -f1)\"
  find '$REMOTE_BACKUP_DIR' -name 'artligent-web-*.tar.gz' -type f -mtime +${BACKUP_KEEP_DAYS} -delete
"
echo "    回滚命令: ssh -p ${REMOTE_PORT} ${REMOTE} \"tar xzf ${BACKUP} -C ${REMOTE_PATH}\""

# --------------------------------------------------------------------------
step "3/5 同步文件"
rsync -avzc --delete "${EXCLUDES[@]}" \
  -e "$SSH_CMD" "$LOCAL_PATH/" "$REMOTE:$REMOTE_PATH/" | tail -3

if [ -n "$REMOTE_OWNER" ]; then
  ssh "${SSH_OPTS[@]}" "$REMOTE" "chown -R '$REMOTE_OWNER' '$REMOTE_PATH' && echo '    属主已设为 ${REMOTE_OWNER}'"
fi

# --------------------------------------------------------------------------
step "4/5 源站自检（模拟 Cloudflare 回源 / 期望 200）"
ssh "${SSH_OPTS[@]}" "$REMOTE" "
  printf '    %-20s ' '/ (直连,期望301)'
  curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: artligent.com' 'http://127.0.0.1/'
  for p in / /index.html /beingtime.html /beingtime-cn.html /lifetime.html /privacy.html; do
    printf '    %-20s ' \"\$p\"
    curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: artligent.com' \
      -H 'CF-Connecting-IP: 203.0.113.9' -H 'X-Forwarded-Proto: https' \"http://127.0.0.1\$p\"
  done
"

# --------------------------------------------------------------------------
step "5/5 外部验证（经 Cloudflare）"
FAIL=0
for p in / /index.html /beingtime.html /beingtime-cn.html \
         /privacy.html /privacy-cn.html /support.html /support-cn.html \
         /terms.html /vsep.html /vsep-cn.html /sitemap.xml /robots.txt; do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "https://artligent.com${p}" || echo "000")
  printf '    %-22s %s\n' "$p" "$CODE"
  [ "$CODE" = "200" ] || FAIL=$((FAIL + 1))
done

printf '    %-22s ' "/lifetime.html(存根)"
curl -s -o /dev/null -w '%{http_code}  (期望 200)\n' --max-time 25 https://artligent.com/lifetime.html

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[1;32m发布完成：全部 200\033[0m\n'
else
  warn "发布完成，但有 ${FAIL} 个路径不是 200，请检查上面输出"
  exit 1
fi
