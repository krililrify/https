#!/usr/bin/env bash
set -Eeuo pipefail

# Root HTTPS: bootstrap for a fresh Ubuntu 22.04/24.04 VPS.
# Does not create or overwrite business reverse-proxy configuration.

log()  { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
trap 'warn "Command failed at line ${LINENO}."' ERR

[[ ${EUID} -eq 0 ]] || die 'Run as root (sudo bash install.sh).'
[[ -f /etc/os-release ]] || die 'Cannot identify operating system.'
# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == 'ubuntu' && ( "${VERSION_ID:-}" == '22.04' || "${VERSION_ID:-}" == '24.04' ) ]] || die 'Only Ubuntu 22.04 / 24.04 LTS is supported.'
command -v systemctl >/dev/null || die 'systemd is required.'

valid_public_ipv4() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    ip = ipaddress.IPv4Address(sys.argv[1])
    sys.exit(0 if ip.is_global else 1)
except ipaddress.AddressValueError:
    sys.exit(1)
PY
}

# Install only prerequisites before checking the system state.
log 'Installing prerequisites...'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl python3 snapd openssl

PUBLIC_IP="${PUBLIC_IP:-}"
if [[ -z "$PUBLIC_IP" ]]; then
  log 'Detecting public IPv4...'
  PUBLIC_IP="$(curl -4fsS --max-time 15 https://api.ipify.org || true)"
fi
valid_public_ipv4 "$PUBLIC_IP" || die 'No valid public IPv4 detected. Set PUBLIC_IP manually.'
log "Certificate IP: $PUBLIC_IP"

# Standalone issuance and renewal need exclusive access to TCP port 80.
if ss -H -lnt '( sport = :80 )' | grep -q .; then
  die 'TCP 80 is occupied. Refusing to interrupt existing services.'
fi

if command -v certbot >/dev/null 2>&1; then
  certbot_path="$(readlink -f "$(command -v certbot)")"
  [[ "$certbot_path" == /snap/* ]] || die 'A non-Snap Certbot installation exists. Resolve manually first.'
fi

log 'Installing Snap Certbot...'
systemctl enable --now snapd.socket >/dev/null
if ! snap list core >/dev/null 2>&1; then snap install core; fi
if ! snap list certbot >/dev/null 2>&1; then snap install --classic certbot; fi
ln -sf /snap/bin/certbot /usr/local/bin/certbot
CERTBOT=/snap/bin/certbot
version="$($CERTBOT --version | awk '{print $2}')"
if [[ "$(printf '%s\n%s\n' '5.4.0' "$version" | sort -V | head -n 1)" != '5.4.0' ]]; then
  die "Certbot $version is too old for this script."
fi

# Never force reissuance on an existing Certbot lineage.
cert_file="/etc/letsencrypt/live/$PUBLIC_IP/fullchain.pem"
renewal_file="/etc/letsencrypt/renewal/$PUBLIC_IP.conf"
if [[ -e "$renewal_file" ]]; then
  [[ -r "$cert_file" ]] || die 'Renewal configuration exists but certificate file is missing.'
  issuer="$(openssl x509 -in "$cert_file" -noout -issuer)"
  if grep -Eiq 'staging|fake|test' <<< "$issuer"; then
    die 'Existing certificate looks like a staging certificate. Handle it manually.'
  fi
  # Fail closed if the existing cert does not actually include the requested IP SAN.
  if ! openssl x509 -in "$cert_file" -noout -ext subjectAltName | grep -Fq "IP Address:$PUBLIC_IP"; then
    die 'Existing certificate does not contain the requested IP SAN.'
  fi
  log 'Existing IP certificate found. Skipping new issuance.'
else
  log 'Issuing a production IP certificate...'
  args=(certonly --standalone --non-interactive --agree-tos --preferred-profile shortlived --ip-address "$PUBLIC_IP")
  if [[ -n "${LE_EMAIL:-}" ]]; then
    args+=(--email "$LE_EMAIL")
  else
    args+=(--register-unsafely-without-email)
  fi
  "$CERTBOT" "${args[@]}"
fi

log 'Installing Nginx (without creating business configuration)...'
nginx_preexisting=0
if dpkg-query -W -f='${Status}' nginx 2>/dev/null | grep -q 'install ok installed'; then
  nginx_preexisting=1
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
# Remove only Ubuntu's stock enabled default site on first Nginx installation.
if [[ "$nginx_preexisting" -eq 0 && -L /etc/nginx/sites-enabled/default ]]; then
  if [[ "$(readlink -f /etc/nginx/sites-enabled/default)" == '/etc/nginx/sites-available/default' ]]; then
    rm /etc/nginx/sites-enabled/default
  fi
fi
nginx -t
systemctl enable --now nginx
systemctl reload nginx
if ss -H -lnt '( sport = :80 )' | grep -q .; then
  die 'TCP 80 is still occupied after Nginx installation. Renewals will fail.'
fi

log 'Setting deploy hook...'
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
fi

systemctl enable --now snap.certbot.renew.timer >/dev/null 2>&1 || warn 'Could not confirm Certbot timer; check manually.'

log 'Installed. Certificate details:'
openssl x509 -in "$cert_file" -noout -issuer -dates -ext subjectAltName
printf '\nCertificate: /etc/letsencrypt/live/%s/fullchain.pem\n' "$PUBLIC_IP"
printf 'Private key: /etc/letsencrypt/live/%s/privkey.pem\n' "$PUBLIC_IP"
printf 'Nginx configuration: /etc/nginx/conf.d/site1.conf (create manually)\n'
printf 'Renewal test: sudo certbot renew --dry-run --run-deploy-hooks\n'
printf 'Reminder: Allow inbound TCP 80 and your HTTPS port in provider firewall.\n'
