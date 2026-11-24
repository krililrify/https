#!/usr/bin/env bash
set -Eeuo pipefail

# KRI IP HTTPS - Ubuntu 22.04/24.04 fresh VPS bootstrap.
# The script intentionally does not create or overwrite business Nginx configs.

log(){ printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn(){ printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
trap 'warn "安装在第 ${LINENO} 行发生错误；请检查前面的错误信息。"' ERR

[[ $EUID -eq 0 ]] || die '请用 sudo bash install.sh 或 root 账户执行'
[[ -f /etc/os-release ]] || die '无法识别系统'
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == ubuntu && ( "${VERSION_ID:-}" == 22.04 || "${VERSION_ID:-}" == 24.04 ) ]] || die '当前仅支持 Ubuntu 22.04/24.04 LTS'
command -v systemctl >/dev/null || die '需要 systemd 环境'

valid_ipv4(){
  local ip=$1 part
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b c d <<< "$ip"
  for part in "$a" "$b" "$c" "$d"; do
    [[ $part =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$part <= 255 )) || return 1
  done
  # Require public unicast (Python's ipaddress handles reserved IPv4 ranges).
  python3 - "$ip" <<'PY'
import ipaddress,sys
ip=ipaddress.IPv4Address(sys.argv[1]); sys.exit(0 if ip.is_global else 1)
PY
}

log '安装基础依赖'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl python3 snapd nginx-common

PUBLIC_IP="${PUBLIC_IP:-}"
if [[ -z "$PUBLIC_IP" ]]; then
  log '自动识别公网 IPv4（通过 api.ipify.org）'
  PUBLIC_IP="$(curl -4fsS --max-time 12 https://api.ipify.org || true)"
fi
valid_ipv4 "$PUBLIC_IP" || die "无法获取有效的公网 IPv4：${PUBLIC_IP:-空}。可用 PUBLIC_IP=1.2.3.4 sudo -E bash install.sh 指定。"
log "目标公网 IP：$PUBLIC_IP"

# Refuse to disrupt existing port-80 services. We use standalone HTTP-01.
if ss -H -lnt '( sport = :80 )' | grep -q .; then
  die 'TCP 80 正被占用。为保护现有业务，脚本不会自动停止服务。请释放 80 端口后再运行，或另行采用 webroot 验证。'
fi

if command -v certbot >/dev/null 2>&1 && [[ "$(readlink -f "$(command -v certbot)")" != /snap/* ]]; then
  die '发现非 Snap 版 Certbot，可能与本脚本的续签配置冲突。请先人工确认安装来源。'
fi

log '安装或检查 Snap Certbot'
systemctl enable --now snapd.socket >/dev/null
if ! snap list core >/dev/null 2>&1; then snap install core; fi
if ! snap list certbot >/dev/null 2>&1; then snap install --classic certbot; fi
ln -sf /snap/bin/certbot /usr/local/bin/certbot
CERTBOT=/snap/bin/certbot
version="$($CERTBOT --version | awk '{print $2}')"
if [[ "$(printf '%s\n%s\n' '5.4.0' "$version" | sort -V | head -n 1)" != '5.4.0' ]]; then
  die "Certbot $version 过旧，IP 证书需要支持 --ip-address 的新版 Certbot。"
fi
log "Certbot 版本：$version"

if [[ -e "/etc/letsencrypt/renewal/$PUBLIC_IP.conf" ]]; then
  log "检测到已有证书续签配置：$PUBLIC_IP，跳过重复签发（请自行检查其签发机构）"
  [[ -r "/etc/letsencrypt/live/$PUBLIC_IP/fullchain.pem" ]] || die '已有续签记录但证书文件不存在，需人工修复'
  if openssl x509 -in "/etc/letsencrypt/live/$PUBLIC_IP/fullchain.pem" -noout -issuer | grep -Eiq 'staging|fake|test'; then
    die '现有证书似乎是 Staging 测试证书。为避免意外强制续签，请先人工处理后重试。'
  fi
else
  log "申请 Let's Encrypt 正式公网 IP 证书（TCP 80 需从公网可达）"
  args=(certonly --standalone --non-interactive --agree-tos --preferred-profile shortlived --ip-address "$PUBLIC_IP")
  if [[ -n "${LE_EMAIL:-}" ]]; then
    args+=(--email "$LE_EMAIL")
  else
    args+=(--register-unsafely-without-email)
  fi
  "$CERTBOT" "${args[@]}"
fi

log '安装 Nginx（不生成或覆盖业务站点配置）'
nginx_preexisting=0
if dpkg-query -W -f='${Status}' nginx 2>/dev/null | grep -q 'install ok installed'; then nginx_preexisting=1; fi
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
# On new installations, Ubuntu ships an enabled example on port 80. Disable ONLY
# that stock default symlink, and do not disturb existing custom sites.
if [[ $nginx_preexisting -eq 0 && -L /etc/nginx/sites-enabled/default ]]; then
  if [[ "$(readlink -f /etc/nginx/sites-enabled/default)" == '/etc/nginx/sites-available/default' ]]; then
    rm /etc/nginx/sites-enabled/default
    log '已移除 Ubuntu Nginx 默认站点软链接，释放 TCP 80 供续签使用'
  fi
fi
nginx -t
systemctl enable --now nginx
systemctl reload nginx
if ss -H -lnt '( sport = :80 )' | grep -q .; then
  die 'Nginx 启动后 TCP 80 仍被占用。请检查已有站点配置，自动续签会失败。'
fi

log '设置证书续签成功后的 Nginx 重载钩子'
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
hook=/etc/letsencrypt/renewal-hooks/deploy/kri-ip-https-reload-nginx.sh
if [[ -e "$hook" ]]; then
  log '已有 KRI 重载钩子，保留原文件'
else
  cat > "$hook" <<'HOOK'
#!/bin/sh
set -e
/usr/sbin/nginx -t
/bin/systemctl reload nginx
HOOK
  chmod 755 "$hook"
fi

systemctl enable --now snap.certbot.renew.timer >/dev/null 2>&1 || warn 'Certbot 定时器无法确认，请执行 systemctl status snap.certbot.renew.timer'

log '验证证书及续签定时器'
openssl x509 -in "/etc/letsencrypt/live/$PUBLIC_IP/fullchain.pem" -noout -issuer -dates -ext subjectAltName
systemctl list-timers --all 'snap.certbot.renew.timer' --no-pager || true

cat <<SUMMARY

============================================================
KRI IP HTTPS 基础环境已安装！
公网 IP: $PUBLIC_IP
证书: /etc/letsencrypt/live/$PUBLIC_IP/fullchain.pem
私钥: /etc/letsencrypt/live/$PUBLIC_IP/privkey.pem
Nginx: /etc/nginx/conf.d/site1.conf (由你自行编写)
续签测试: sudo certbot renew --dry-run --run-deploy-hooks
配置生效: sudo nginx -t && sudo systemctl reload nginx

注意：尚未创建 HTTPS 业务站点，所以现在 HTTPS 端口不会自动开放。
注意：服务商安全组必须允许 TCP 80（证书验证）和业务 HTTPS 端口。
============================================================
SUMMARY
