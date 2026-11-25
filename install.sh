#!/usr/bin/env bash
set -Eeuo pipefail

# Root HTTPS: Ubuntu 22.04/24.04 + Debian 12/13.
# Fresh-server installer. Does not create or overwrite site1.conf.

log()  { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
trap 'warn "Stopped at line $LINENO. See the error above."' ERR

[[ $EUID -eq 0 ]] || die 'Run as root: sudo bash install.sh'
[[ -r /etc/os-release ]] || die 'Cannot read /etc/os-release'
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
  ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ;;
  *) die 'Supported systems: Ubuntu 22.04/24.04, Debian 12/13.' ;;
esac
command -v systemctl >/dev/null || die 'systemd is required'

log 'Installing prerequisites...'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl python3 openssl iproute2

valid_public_ipv4() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    ip = ipaddress.IPv4Address(sys.argv[1])
    sys.exit(0 if ip.is_global else 1)
except ValueError:
    sys.exit(1)
PY
}

PUBLIC_IP="${PUBLIC_IP:-}"
if [[ -z "$PUBLIC_IP" ]]; then
  log 'Detecting public IPv4...'
  PUBLIC_IP="$(curl -4fsS --max-time 15 https://api.ipify.org || true)"
fi
valid_public_ipv4 "$PUBLIC_IP" || die 'Invalid public IPv4. Use: sudo env PUBLIC_IP=x.x.x.x bash install.sh'
log "Certificate IP: $PUBLIC_IP"

port80_busy() { [[ -n "$(ss -H -lnt '( sport = :80 )')" ]]; }

# Use existing Snap Certbot when present. On fresh Ubuntu install Snap;
# on fresh Debian install into a dedicated Python venv (no Snap requirement).
if command -v snap >/dev/null 2>&1 && snap list certbot >/dev/null 2>&1; then
  METHOD=snap
elif [[ "${ID}" == ubuntu ]]; then
  METHOD=snap
else
  METHOD=venv
fi

# Do not silently mix an existing apt/pip Certbot with another installation.
if command -v certbot >/dev/null 2>&1; then
  installed_path="$(command -v certbot)"
  if [[ "$METHOD" == snap ]]; then
    if [[ "$installed_path" == /snap/bin/certbot ]]; then
      : # Expected Snap binary.
    elif [[ "$installed_path" == /usr/local/bin/certbot ]] &&
         [[ "$(readlink /usr/local/bin/certbot || true)" == /snap/bin/certbot ]]; then
      : # Expected symlink created by this installer.
    else
      die "Existing Certbot at $installed_path requires manual review; will not overwrite it."
    fi
  else
    if [[ "$installed_path" != /usr/local/bin/certbot ]] ||
       [[ "$(readlink /usr/local/bin/certbot || true)" != /opt/root-https/certbot-venv/bin/certbot ]]; then
      die "Existing Certbot at $installed_path requires manual review; will not overwrite it."
    fi
  fi
fi

if [[ "$METHOD" == snap ]]; then
  log 'Using Snap Certbot...'
  DEBIAN_FRONTEND=noninteractive apt-get install -y snapd
  systemctl enable --now snapd.socket >/dev/null
  if ! snap list core >/dev/null 2>&1; then snap install core; fi
  if ! snap list certbot >/dev/null 2>&1; then snap install --classic certbot; fi
  CERTBOT=/snap/bin/certbot
  ln -sfn "$CERTBOT" /usr/local/bin/certbot
else
  log 'Using Python virtual-environment Certbot (Debian)...'
  DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv
  VENV=/opt/root-https/certbot-venv
  if [[ ! -x "$VENV/bin/python" ]]; then
    mkdir -p /opt/root-https
    python3 -m venv "$VENV"
  fi
  CERTBOT="$VENV/bin/certbot"
  if [[ ! -x "$CERTBOT" ]]; then
    "$VENV/bin/python" -m pip install --upgrade pip certbot
  fi
  ln -sfn "$CERTBOT" /usr/local/bin/certbot
fi

version="$($CERTBOT --version | awk '{print $2}')"
if [[ "$(printf '%s\n%s\n' '5.4.0' "$version" | sort -V | head -n 1)" != '5.4.0' ]]; then
  die "Certbot $version is too old (need 5.4.0+)."
fi
log "Certbot $version ($METHOD)"

cert_file="/etc/letsencrypt/live/$PUBLIC_IP/fullchain.pem"
key_file="/etc/letsencrypt/live/$PUBLIC_IP/privkey.pem"
renewal_file="/etc/letsencrypt/renewal/$PUBLIC_IP.conf"
if [[ -e "$renewal_file" ]]; then
  [[ -r "$cert_file" && -r "$key_file" ]] || die 'Existing certificate record lacks certificate/key; fix manually.'
  issuer="$(openssl x509 -in "$cert_file" -noout -issuer)"
  if grep -Eiq 'staging|fake|test' <<< "$issuer"; then
    die 'Existing certificate appears to be staging; replace manually.'
  fi
  openssl x509 -in "$cert_file" -noout -ext subjectAltName | grep -Fq "IP Address:$PUBLIC_IP" \
    || die 'Existing certificate does not contain requested IP SAN.'
  log 'Existing IP certificate found; skipping issuance.'
else
  if port80_busy; then
    ss -lntp '( sport = :80 )' || true
    die 'TCP 80 is busy; cannot use standalone HTTP-01 safely.'
  fi
  log 'Requesting production IP certificate...'
  args=(certonly --standalone --non-interactive --agree-tos --preferred-profile shortlived --ip-address "$PUBLIC_IP")
  if [[ -n "${LE_EMAIL:-}" ]]; then
    args+=(--email "$LE_EMAIL")
  else
    args+=(--register-unsafely-without-email)
  fi
  "$CERTBOT" "${args[@]}"
fi

log 'Installing/checking Nginx...'
nginx_preexisting=0
if command -v nginx >/dev/null 2>&1; then nginx_preexisting=1; fi
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
# Only disable the stock default site on a FIRST nginx install.
if [[ $nginx_preexisting -eq 0 && -L /etc/nginx/sites-enabled/default ]] &&
   [[ "$(readlink -f /etc/nginx/sites-enabled/default)" == /etc/nginx/sites-available/default ]]; then
  rm /etc/nginx/sites-enabled/default
  log 'Disabled stock Nginx default site.'
fi
nginx -t
systemctl enable --now nginx
systemctl reload nginx

# Old Nginx workers can briefly retain port 80 after reload.
port80_free=0
for ((i=1; i<=15; i++)); do
  if ! port80_busy; then port80_free=1; break; fi
  sleep 1
done
if [[ $port80_free -ne 1 ]]; then
  ss -lntp '( sport = :80 )' || true
  die 'TCP 80 remains occupied; automatic standalone renewal would fail.'
fi

log 'Configuring Nginx renewal hook...'
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
hook=/etc/letsencrypt/renewal-hooks/deploy/root-https-reload-nginx.sh
if [[ ! -e "$hook" ]]; then
  cat > "$hook" <<'HOOK'
#!/bin/sh
set -e
/usr/sbin/nginx -t >/dev/null 2>&1
/bin/systemctl reload nginx
HOOK
  chmod 755 "$hook"
else
  warn 'Existing renewal hook retained; inspect it if previously modified.'
fi

if [[ "$METHOD" == snap ]]; then
  systemctl enable --now snap.certbot.renew.timer >/dev/null 2>&1 || \
    die 'Snap Certbot renewal timer could not be enabled.'
else
  # A dedicated systemd timer replaces Snap's renewal timer on fresh Debian.
  cat > /etc/systemd/system/root-https-renew.service <<EOF
[Unit]
Description=Renew Root HTTPS certificates
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$CERTBOT renew --quiet
EOF
  cat > /etc/systemd/system/root-https-renew.timer <<'EOF'
[Unit]
Description=Check Root HTTPS certificates every 6小时

[Timer]
OnCalendar=*-*-* 00,06,12,18:00:00
RandomizedDelaySec=1800
Persistent=true
Unit=root-https-renew.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now root-https-renew.timer >/dev/null
fi

log 'Installation complete.'
openssl x509 -in "$cert_file" -noout -issuer -dates -ext subjectAltName
printf '\nCertificate: %s\nPrivate key: %s\n' "$cert_file" "$key_file"
printf 'Nginx config: /etc/nginx/conf.d/site1.conf (create manually)\n'
printf 'Certbot method: %s\n' "$METHOD"
printf 'Renewal test: %s renew --dry-run --run-deploy-hooks\n' "$CERTBOT"
printf 'Keep inbound TCP 80 open for renewals, plus your HTTPS application port.\n'
