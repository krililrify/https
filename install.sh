#!/usr/bin/env bash
set -Eeuo pipefail

# Root HTTPS v1.3
# Ubuntu 22.04/24.04, Debian 12/13; Certbot via isolated Python venv.
# Never creates or overwrites /etc/nginx/conf.d/site1.conf.

log()  { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
trap 'warn "Stopped at line ${LINENO}."' ERR

[[ ${EUID} -eq 0 ]] || die 'Run as root: sudo bash install.sh'
[[ -r /etc/os-release ]] || die 'Cannot read /etc/os-release'
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
  ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ;;
  *) die 'Supported: Ubuntu 22.04/24.04, Debian 12/13' ;;
esac
command -v systemctl >/dev/null || die 'systemd is required'

VENV=/opt/root-https/certbot-venv
CERTBOT="$VENV/bin/certbot"
HOOK=/etc/letsencrypt/renewal-hooks/deploy/root-https-reload-nginx.sh
TIMER=/etc/systemd/system/root-https-renew.timer
SERVICE=/etc/systemd/system/root-https-renew.service

# If Snap is currently stuck in uninterruptible I/O, do not start another installer.
if ps -eo stat=,args= | awk '$1 ~ /^D/ && /\/snap\/certbot\// {found=1} END {exit !found}'; then
  die 'Snap Certbot is stuck in D state (disk I/O). Investigate/reboot safely before retrying.'
fi

log 'Installing prerequisites...'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl python3 python3-venv openssl iproute2 nginx-common

valid_ipv4() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    sys.exit(0 if ipaddress.IPv4Address(sys.argv[1]).is_global else 1)
except ValueError:
    sys.exit(1)
PY
}

PUBLIC_IP="${PUBLIC_IP:-}"
if [[ -z "$PUBLIC_IP" ]]; then
  log 'Detecting public IPv4...'
  PUBLIC_IP="$(curl -4fsS --connect-timeout 5 --max-time 15 https://api.ipify.org || true)"
fi
valid_ipv4 "$PUBLIC_IP" || die 'Invalid public IP. Use: sudo env PUBLIC_IP=x.x.x.x bash install.sh'
log "Certificate IP: $PUBLIC_IP"

port80_busy() { [[ -n "$(ss -H -lnt '( sport = :80 )')" ]]; }

# Fail closed on certificates maintained by another Certbot installation.
# A marker is created only after Root HTTPS completes its initial issuance/setup.
MARKER=/opt/root-https/managed-ip
if [[ -e "$MARKER" ]]; then
  [[ "$(cat "$MARKER")" == "$PUBLIC_IP" ]] || die "Existing Root HTTPS installation manages $(cat "$MARKER"); refusing to switch IP automatically"
fi
if [[ ! -e "$MARKER" && -d /etc/letsencrypt/renewal ]]; then
  shopt -s nullglob
  existing=(/etc/letsencrypt/renewal/*.conf)
  shopt -u nullglob
  if (( ${#existing[@]} > 0 )); then
    die 'Existing Certbot renewal records found. Do not mix installers; inspect /etc/letsencrypt/renewal first.'
  fi
fi

# Do not alter existing Nginx services: standalone needs an idle port 80.
if port80_busy; then
  ss -lntp '( sport = :80 )' || true
  die 'TCP 80 is already in use. This installer is for fresh VPS only.'
fi

log 'Installing isolated Certbot (Python venv, no Snap)...'
if [[ ! -x "$VENV/bin/python" ]]; then
  mkdir -p /opt/root-https
  python3 -m venv "$VENV"
fi
if [[ ! -x "$CERTBOT" ]]; then
  timeout 300 "$VENV/bin/python" -m pip install --disable-pip-version-check --retries 2 --timeout 20 'certbot>=5.4,<7' \
    || die 'Certbot pip installation failed or timed out. Check network/PyPI access.'
fi
version="$(timeout 30 "$CERTBOT" --version)" || die 'Certbot cannot start within 30 seconds'
log "$version"
# Only manage our own symlink; do not clobber apt/snap Certbot.
if [[ ! -e /usr/local/bin/certbot && ! -L /usr/local/bin/certbot ]]; then
  ln -s "$CERTBOT" /usr/local/bin/certbot
elif [[ "$(readlink /usr/local/bin/certbot || true)" == /snap/bin/certbot ]]; then
  # Replace only the known Snap symlink created by an earlier Root HTTPS release.
  ln -sfn "$CERTBOT" /usr/local/bin/certbot
elif [[ "$(readlink /usr/local/bin/certbot || true)" != "$CERTBOT" ]]; then
  warn 'Existing /usr/local/bin/certbot preserved. Use /opt/root-https/certbot-venv/bin/certbot explicitly.'
fi

cert_file="/etc/letsencrypt/live/$PUBLIC_IP/fullchain.pem"
key_file="/etc/letsencrypt/live/$PUBLIC_IP/privkey.pem"
renewal_file="/etc/letsencrypt/renewal/$PUBLIC_IP.conf"
if [[ -e "$renewal_file" ]]; then
  [[ -r "$cert_file" && -r "$key_file" ]] || die 'Renewal file exists but certificate/key is missing'
  openssl x509 -in "$cert_file" -noout -ext subjectAltName | grep -Fq "IP Address:$PUBLIC_IP" \
    || die 'Existing certificate SAN does not match public IP'
  if ! openssl x509 -in "$cert_file" -noout -checkend 86400 >/dev/null; then
    die 'Existing certificate expired or expires soon. Inspect renewal settings manually.'
  fi
  log 'Existing certificate detected. Skipping duplicate issuance.'
else
  log 'Requesting production IP certificate (TCP 80 must be reachable externally)...'
  args=(certonly --standalone --non-interactive --agree-tos --preferred-profile shortlived --ip-address "$PUBLIC_IP")
  if [[ -n "${LE_EMAIL:-}" ]]; then
    args+=(--email "$LE_EMAIL")
  else
    args+=(--register-unsafely-without-email)
  fi
  timeout 240 "$CERTBOT" "${args[@]}" || die 'Certificate issuance failed/timed out. Check TCP 80, public IP and logs.'
fi

log 'Installing/checking Nginx...'
nginx_preexisting=0
if command -v nginx >/dev/null 2>&1; then nginx_preexisting=1; fi
apt-get install -y nginx
if [[ $nginx_preexisting -eq 0 && -L /etc/nginx/sites-enabled/default ]] && \
   [[ "$(readlink -f /etc/nginx/sites-enabled/default)" == /etc/nginx/sites-available/default ]]; then
  rm /etc/nginx/sites-enabled/default
  log 'Disabled stock Nginx default site.'
fi
nginx -t
systemctl enable --now nginx
systemctl reload nginx
for ((i=1; i<=15; i++)); do
  if ! port80_busy; then break; fi
  sleep 1
done
if port80_busy; then
  ss -lntp '( sport = :80 )' || true
  die 'TCP 80 remains occupied after Nginx reload; fix before automated renewal.'
fi

log 'Setting up renewal hook and systemd timer...'
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
if [[ ! -e "$HOOK" ]]; then
  cat > "$HOOK" <<'HOOK_EOF'
#!/bin/sh
set -e
/usr/sbin/nginx -t >/dev/null 2>&1
/bin/systemctl reload nginx
HOOK_EOF
  chmod 755 "$HOOK"
fi

cat > "$SERVICE" <<EOF
[Unit]
Description=Root HTTPS - renew IP certificates
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$CERTBOT renew --quiet
EOF
cat > "$TIMER" <<'EOF'
[Unit]
Description=Root HTTPS - check renewals four times per day

[Timer]
OnCalendar=*-*-* 00,06,12,18:00:00
RandomizedDelaySec=1800
Persistent=true
Unit=root-https-renew.service

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now root-https-renew.timer

# Do not allow a second Certbot scheduler to manage the same directory.
if systemctl is-enabled --quiet snap.certbot.renew.timer 2>/dev/null; then
  # If no other lineages exist, Snap may be disabled without removing Snap itself.
  systemctl disable --now snap.certbot.renew.timer || warn 'Could not disable old Snap Certbot timer; inspect manually.'
fi
if systemctl is-enabled --quiet certbot.timer 2>/dev/null; then
  systemctl disable --now certbot.timer || warn 'Could not disable old apt Certbot timer; inspect manually.'
fi
mkdir -p /opt/root-https
printf '%s\n' "$PUBLIC_IP" > "$MARKER"

log 'Installation completed.'
openssl x509 -in "$cert_file" -noout -issuer -dates -ext subjectAltName
printf '\nCertificate: %s\nPrivate key: %s\n' "$cert_file" "$key_file"
printf 'Nginx config (create yourself): /etc/nginx/conf.d/site1.conf\n'
printf 'Test renewal: %s renew --dry-run --run-deploy-hooks\n' "$CERTBOT"
printf 'Timer: systemctl list-timers --all | grep root-https\n'
printf 'Keep TCP 80 and your HTTPS application port open in provider firewall.\n'
