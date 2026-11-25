#!/usr/bin/env bash
set -Eeuo pipefail

# Root HTTPS - Ubuntu 22.04 / 24.04 LTS
# Installs Certbot + Nginx; leaves business Nginx configuration untouched.

log()  { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
trap 'warn "Failed at line ${LINENO}."' ERR

[[ $EUID -eq 0 ]] || die 'Run as root: sudo bash install.sh'
[[ -r /etc/os-release ]] || die 'Cannot read /etc/os-release'
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == ubuntu && ( "${VERSION_ID:-}" == 22.04 || "${VERSION_ID:-}" == 24.04 ) ]] \
  || die 'Only Ubuntu 22.04 / 24.04 LTS is supported'
command -v systemctl >/dev/null || die 'systemd is required'

log 'Installing prerequisites...'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl python3 snapd openssl iproute2 nginx-common

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
valid_public_ipv4 "$PUBLIC_IP" || die 'Invalid public IPv4; set PUBLIC_IP explicitly'
log "Certificate IP: $PUBLIC_IP"

port80_busy() {
  # ss exits without a listener line when port 80 is free.
  [[ -n "$(ss -H -lnt '( sport = :80 )')" ]]
}

# Never assume that an existing certbot command is not Snap based on readlink -f:
# /snap/bin/certbot commonly resolves to /usr/bin/snap.
if command -v certbot >/dev/null 2>&1 && ! snap list certbot >/dev/null 2>&1; then
  die 'Certbot exists but Snap Certbot is not installed; inspect manually before continuing'
fi

log 'Installing or checking Snap Certbot...'
systemctl enable --now snapd.socket >/dev/null
if ! snap list core >/dev/null 2>&1; then snap install core; fi
if ! snap list certbot >/dev/null 2>&1; then snap install --classic certbot; fi
ln -sf /snap/bin/certbot /usr/local/bin/certbot
CERTBOT=/snap/bin/certbot
version="$($CERTBOT --version | awk '{print $2}')"
if [[ "$(printf '%s\n%s\n' '5.4.0' "$version" | sort -V | head -n 1)" != '5.4.0' ]]; then
  die "Certbot $version is too old for IP certificates"
fi
log "Certbot version: $version"

cert_file="/etc/letsencrypt/live/$PUBLIC_IP/fullchain.pem"
key_file="/etc/letsencrypt/live/$PUBLIC_IP/privkey.pem"
renewal_file="/etc/letsencrypt/renewal/$PUBLIC_IP.conf"

if [[ -e "$renewal_file" ]]; then
  [[ -r "$cert_file" && -r "$key_file" ]] || die 'Certificate lineage exists, but certificate/key is missing'
  issuer="$(openssl x509 -in "$cert_file" -noout -issuer)"
  if grep -Eiq 'staging|fake|test' <<< "$issuer"; then
    die 'Existing certificate appears to be a staging certificate; handle manually'
  fi
  openssl x509 -in "$cert_file" -noout -ext subjectAltName | grep -Fq "IP Address:$PUBLIC_IP" \
    || die 'Existing certificate does not contain the expected IPv4 SAN'
  log 'Existing certificate found; skipping issuance'
else
  if port80_busy; then
    ss -lntp '( sport = :80 )' || true
    die 'TCP 80 is occupied; standalone validation requires it to be free'
  fi
  log 'Issuing a production IP certificate...'
  args=(certonly --standalone --non-interactive --agree-tos --preferred-profile shortlived --ip-address "$PUBLIC_IP")
  if [[ -n "${LE_EMAIL:-}" ]]; then
    args+=(--email "$LE_EMAIL")
  else
    args+=(--register-unsafely-without-email)
  fi
  "$CERTBOT" "${args[@]}"
fi

log 'Installing/checking Nginx...'
# Detect whether there was an existing Nginx binary before apt installs it.
# nginx-common is installed earlier, but does not install the nginx server binary.
nginx_preexisting=0
if command -v nginx >/dev/null 2>&1; then nginx_preexisting=1; fi
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx

# Remove ONLY the stock Ubuntu site on a fresh Nginx installation.
# Existing Nginx installations and custom sites remain untouched.
if [[ $nginx_preexisting -eq 0 && -L /etc/nginx/sites-enabled/default ]]; then
  if [[ "$(readlink -f /etc/nginx/sites-enabled/default)" == '/etc/nginx/sites-available/default' ]]; then
    rm /etc/nginx/sites-enabled/default
    log 'Disabled Ubuntu stock default site'
  fi
fi

nginx -t
systemctl enable --now nginx
systemctl reload nginx

# A reload can leave old workers/listeners alive briefly. Poll instead of
# failing immediately (never terminate an unknown service on TCP 80).
port80_free=0
for ((i=1; i<=15; i++)); do
  if ! port80_busy; then
    port80_free=1
    break
  fi
  sleep 1
done
if [[ $port80_free -ne 1 ]]; then
  ss -lntp '( sport = :80 )' || true
  die 'TCP 80 is still occupied; inspect active Nginx sites/services before renewing'
fi

log 'Configuring Certbot deploy hook...'
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
hook=/etc/letsencrypt/renewal-hooks/deploy/root-https-reload-nginx.sh
if [[ ! -e "$hook" ]]; then
  cat > "$hook" <<'HOOK'
#!/bin/sh
set -e
/usr/sbin/nginx -t
/bin/systemctl reload nginx
HOOK
  chmod 755 "$hook"
else
  warn 'Existing deploy hook preserved; check its content and execute permission'
fi

if ! systemctl enable --now snap.certbot.renew.timer >/dev/null 2>&1; then
  warn 'Certbot renewal timer could not be confirmed; inspect it manually'
fi

log 'Installation complete. Certificate details:'
openssl x509 -in "$cert_file" -noout -issuer -dates -ext subjectAltName
printf '\nCertificate: %s\n' "$cert_file"
printf 'Private key: %s\n' "$key_file"
printf 'Business config: /etc/nginx/conf.d/site1.conf (create manually)\n'
printf 'Renewal test: certbot renew --dry-run --run-deploy-hooks\n'
printf 'Allow inbound TCP 80 and your chosen HTTPS port in the VPS firewall/security group.\n'
