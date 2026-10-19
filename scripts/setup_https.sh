#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TLS_DIR="/etc/aimilivpn/tls"
CERT_FILE="$TLS_DIR/fullchain.pem"
KEY_FILE="$TLS_DIR/privkey.pem"
NGINX_CONF="/etc/nginx/conf.d/aimilivpn-production.conf"
ACME_CONF="/etc/nginx/conf.d/aimilivpn-acme.conf"
ACME_ROOT="/var/www/aimilivpn-acme"
SUB_DIR="/var/lib/aimilivpn/subscriptions"
ENABLE_IP_ACME="${AIMILIVPN_ENABLE_ACME_IP_CERT:-0}"
ACME_AVAILABLE=0
ACME_ISSUED=0

if [ "$(id -u)" != "0" ]; then echo "错误: 需要 root 权限。" >&2; exit 1; fi

service_enable() {
  if command -v systemctl >/dev/null 2>&1; then systemctl enable nginx >/dev/null 2>&1 || true
  elif command -v rc-update >/dev/null 2>&1; then rc-update add nginx default >/dev/null 2>&1 || true
  fi
}
service_restart() {
  if command -v systemctl >/dev/null 2>&1; then systemctl restart nginx
  else rc-service nginx restart
  fi
}
service_reload() {
  if command -v systemctl >/dev/null 2>&1; then systemctl reload nginx
  else rc-service nginx reload || rc-service nginx restart
  fi
}

# apt-get update 遇到坏的第三方源（缺 GPG 公钥 NO_PUBKEY、404 没有 Release 文件、未签名）不中断安装：
# 识别报错的源，备份后临时注释/停用，再重试一次，并提示用户。系统官方源（ubuntu/debian）不动。
aimili_apt_update() {
    local out rc urls u f changed=0 disabled="" ad="${AIMILI_APT_DIR:-/etc/apt}"
    out=$(LC_ALL=C apt-get update -q 2>&1); rc=$?
    printf '%s\n' "$out" | tail -n 40
    urls=$(printf '%s\n' "$out" | grep -E "NO_PUBKEY|EXPKEYSIG|is not signed|does not have a Release file|404 +Not Found|Release' no longer has a Release" \
        | grep -oE "https?://[^ ']+" | sed -E 's#/(dists/.*|InRelease|Release)$##; s#/+$##' | sort -u)
    [ -z "$urls" ] && return $rc
    for u in $urls; do
        case "$u" in
            *://archive.ubuntu.com*|*://*.archive.ubuntu.com*|*://security.ubuntu.com*|*://ports.ubuntu.com*|*://deb.debian.org*|*://security.debian.org*|*://*.ec2.archive.ubuntu.com*) continue ;;
        esac
        for f in "$ad/sources.list" "$ad"/sources.list.d/*.list "$ad"/sources.list.d/*.sources; do
            [ -f "$f" ] && grep -qF "$u" "$f" || continue
            case "$f" in
                *.sources)
                    mv -f "$f" "$f.aimili-disabled" && changed=1 && disabled="$disabled $f" ;;
                *)
                    [ -e "$f.aimili-bak" ] || cp -a "$f" "$f.aimili-bak"
                    awk -v u="$u" 'index($0,u) && $0 ~ /^[[:space:]]*deb(-src)?[[:space:]]/ {print "# [AimiliVPN 临时停用，apt update 报错] " $0; next} {print}' "$f" >"$f.tmp" && mv -f "$f.tmp" "$f" \
                        && changed=1 && disabled="$disabled $f($u)" ;;
            esac
        done
    done
    if [ "$changed" = "1" ]; then
        echo -e "${YELLOW:-}  -> 以下第三方软件源 apt update 报错（缺公钥/404/未签名），已临时停用后重试：${PLAIN:-}"
        for f in $disabled; do echo -e "${YELLOW:-}     $f${PLAIN:-}"; done
        echo -e "${YELLOW:-}     原文件已备份为 *.aimili-bak（.sources 文件改名为 *.aimili-disabled）；修好公钥/地址后可自行恢复。${PLAIN:-}"
        LC_ALL=C apt-get update -q 2>&1 | tail -n 20; rc=${PIPESTATUS[0]}
    fi
    return $rc
}

OS_TYPE=""
[ -f /etc/os-release ] && . /etc/os-release && OS_TYPE="$ID"
case "$OS_TYPE" in
  ubuntu|debian) export DEBIAN_FRONTEND=noninteractive; aimili_apt_update || echo "  -> apt-get update 仍有报错，继续用现有软件源清单安装。"; apt-get install -y nginx openssl curl ca-certificates certbot ;;
  alpine) apk add --no-cache nginx openssl curl ca-certificates certbot ;;
  centos|rhel|rocky|almalinux|fedora|ol|amzn) (command -v dnf >/dev/null 2>&1 && dnf install -y nginx openssl curl ca-certificates certbot) || yum install -y nginx openssl curl ca-certificates certbot ;;
  *) echo "不支持的系统: $OS_TYPE" >&2; exit 1 ;;
esac

rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/00-default /etc/nginx/conf.d/default.conf
rm -f /etc/nginx/http.d/default.conf 2>/dev/null || true

mkdir -p "$TLS_DIR" "$ACME_ROOT/.well-known/acme-challenge" "$SUB_DIR"
chmod 700 "$TLS_DIR"
PUBLIC_IP="${PUBLIC_IP:-$(curl -4fsS --max-time 5 https://api.ipify.org || true)}"
[ -z "$PUBLIC_IP" ] && PUBLIC_IP="127.0.0.1"

CERT_DAYS=3650
if [ "${AIMILIVPN_IP_CERT_FOREVER:-0}" = "1" ]; then
  CERT_DAYS=36500
  ENABLE_IP_ACME=0
fi
if ! openssl req -x509 -nodes -newkey rsa:2048 -days "$CERT_DAYS" -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=$PUBLIC_IP" -addext "subjectAltName=IP:$PUBLIC_IP" >/dev/null 2>&1; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=$PUBLIC_IP" -addext "subjectAltName=IP:$PUBLIC_IP" >/dev/null 2>&1
fi
chmod 600 "$KEY_FILE"; chmod 644 "$CERT_FILE"

cert_is_signed() {
  local file="$1" subject issuer
  [ -s "$file" ] || return 1
  openssl x509 -in "$file" -noout -checkend 0 >/dev/null 2>&1 || return 1
  subject=$(openssl x509 -in "$file" -noout -subject 2>/dev/null || true)
  issuer=$(openssl x509 -in "$file" -noout -issuer 2>/dev/null || true)
  [ -n "$subject" ] && [ "$subject" != "$issuer" ] || return 1
  # staging / 测试 CA 不算 CA 签发（测试时 AIMILI_ALLOW_STAGING_CERT=1）
  if [ "${AIMILI_ALLOW_STAGING_CERT:-}" != "1" ] && printf '%s' "$issuer" | grep -Eqi 'STAGING|Fake LE|Pebble|\(TEST\)'; then return 1; fi
}
cert_matches_name() {
  local file="$1" name="$2"
  [ -z "$name" ] && return 0
  openssl x509 -in "$file" -noout -subject -ext subjectAltName 2>/dev/null | grep -Fqi "$name"
}
cert_dns_name() {
  openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null \
    | sed -n 's/.*DNS:\([^, ]*\).*/\1/p' | head -n 1
}
key_for_cert() {
  local cert="$1" dir base stem candidate
  dir=$(dirname "$cert")
  base=$(basename "$cert")
  stem="${base%.*}"
  for candidate in "$dir/privkey.pem" "$dir/$stem.key" "${cert%.crt}.key" "${cert%.pem}.key"; do
    if [ -s "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}
ADOPTED_CERT=""
ADOPTED_DOMAIN=""
consider_cert() {
  local cert="$1" key
  [ -z "$ADOPTED_CERT" ] || return 0
  cert_is_signed "$cert" || return 0
  cert_matches_name "$cert" "${AIMILIVPN_DOMAIN:-}" || return 0
  key=$(key_for_cert "$cert") || return 0
  if [ -z "${AIMILIVPN_DOMAIN:-}" ]; then
    cert_dns_name "$cert" >/dev/null || return 0
    [ -n "$(cert_dns_name "$cert")" ] || return 0
  fi
  ADOPTED_CERT="$cert"
  ADOPTED_KEY="$key"
  ADOPTED_DOMAIN="${AIMILIVPN_DOMAIN:-$(cert_dns_name "$cert")}"
}
if [ -n "${AIMILIVPN_DOMAIN:-}" ] && [ -s "/etc/letsencrypt/live/${AIMILIVPN_DOMAIN}/fullchain.pem" ]; then
  consider_cert "/etc/letsencrypt/live/${AIMILIVPN_DOMAIN}/fullchain.pem"
fi
if [ -d /etc/letsencrypt/live ]; then
  for cert in /etc/letsencrypt/live/*/fullchain.pem; do
    [ -e "$cert" ] || continue
    consider_cert "$cert"
  done
fi
if [ -d /etc/v2ray-agent/tls ]; then
  for cert in /etc/v2ray-agent/tls/*.crt /etc/v2ray-agent/tls/*.pem; do
    [ -e "$cert" ] || continue
    consider_cert "$cert"
  done
fi
if [ -z "$ADOPTED_CERT" ] && [ -d /etc/nginx ]; then
  while read -r cert; do
    [ -n "$cert" ] || continue
    case "$cert" in
      "$CERT_FILE"|*aimilivpn/tls/*) continue ;;
    esac
    consider_cert "$cert"
  done < <(grep -R --include='*.conf' -h '^\s*ssl_certificate\s' /etc/nginx 2>/dev/null | awk '{print $2}' | tr -d ';')
fi
if [ -n "$ADOPTED_CERT" ]; then
  install -m 0644 "$ADOPTED_CERT" "$CERT_FILE"
  install -m 0600 "$ADOPTED_KEY" "$KEY_FILE"
  ENABLE_IP_ACME=0
  echo "已使用服务器上已有的正式证书：${ADOPTED_DOMAIN:-$ADOPTED_CERT}"
fi

install -m 0644 "$ROOT_DIR/scripts/nginx/aimilivpn-production.conf" "$NGINX_CONF"
NGINX_SERVER_NAME="${ADOPTED_DOMAIN:-${AIMILIVPN_DOMAIN:-}}"
if [ -n "$NGINX_SERVER_NAME" ]; then
  sed -i "s/server_name _;/server_name ${NGINX_SERVER_NAME};/" "$NGINX_CONF"
fi
rm -f "$ACME_CONF"

if [ "$ENABLE_IP_ACME" = "1" ] && ! ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)80$'; then
  install -m 0644 "$ROOT_DIR/scripts/nginx/aimilivpn-acme.conf" "$ACME_CONF"
  ACME_AVAILABLE=1
else
  ACME_AVAILABLE=0
fi

service_enable
nginx -t
service_restart

if [ "$ACME_AVAILABLE" = "1" ] && command -v certbot >/dev/null 2>&1; then
  if certbot certonly --webroot -w "$ACME_ROOT" --preferred-profile shortlived --ip-address "$PUBLIC_IP" --cert-name aimilivpn-ip --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring; then
    LE_DIR="/etc/letsencrypt/live/aimilivpn-ip"
    if [ -s "$LE_DIR/fullchain.pem" ] && [ -s "$LE_DIR/privkey.pem" ]; then
      install -m 0644 "$LE_DIR/fullchain.pem" "$CERT_FILE"
      install -m 0600 "$LE_DIR/privkey.pem" "$KEY_FILE"
      mkdir -p /etc/letsencrypt/renewal-hooks/deploy
      cat > /etc/letsencrypt/renewal-hooks/deploy/aimilivpn-nginx <<'HOOK'
#!/bin/sh
set -eu
install -m 0644 /etc/letsencrypt/live/aimilivpn-ip/fullchain.pem /etc/aimilivpn/tls/fullchain.pem
install -m 0600 /etc/letsencrypt/live/aimilivpn-ip/privkey.pem /etc/aimilivpn/tls/privkey.pem
if command -v systemctl >/dev/null 2>&1; then systemctl reload nginx; else rc-service nginx reload || rc-service nginx restart; fi
HOOK
      chmod 755 /etc/letsencrypt/renewal-hooks/deploy/aimilivpn-nginx
      echo "已获得 Let's Encrypt 公网可信 IP 证书。"
    fi
  else
    echo "Let's Encrypt IP 证书申请失败，继续使用自签名证书。"
  fi
fi

if [ "$ACME_AVAILABLE" = "1" ] && [ "$ACME_ISSUED" != "1" ]; then
  rm -f "$ACME_CONF"
  service_reload
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw delete allow 80/tcp >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port=80/tcp >/dev/null || true
    firewall-cmd --reload >/dev/null || true
  fi
fi

nginx -t && service_reload

if [ "$ACME_ISSUED" = "1" ] && command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^certbot.timer'; then
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
elif [ "$ACME_ISSUED" = "1" ] && [ -d /etc/cron.daily ]; then
  cat > /etc/cron.daily/aimilivpn-certbot-renew <<'EOF'
#!/bin/sh
certbot renew --quiet
EOF
  chmod 755 /etc/cron.daily/aimilivpn-certbot-renew
elif [ "$ACME_ISSUED" = "1" ] && [ -d /etc/periodic/daily ]; then
  cat > /etc/periodic/daily/aimilivpn-certbot-renew <<'EOF'
#!/bin/sh
certbot renew --quiet
EOF
  chmod 755 /etc/periodic/daily/aimilivpn-certbot-renew
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 8443/tcp >/dev/null; ufw allow 8500/tcp >/dev/null; ufw allow 18443/tcp >/dev/null
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port=8443/tcp >/dev/null || true
  firewall-cmd --permanent --add-port=8500/tcp >/dev/null || true
  firewall-cmd --permanent --add-port=18443/tcp >/dev/null || true
  firewall-cmd --reload >/dev/null || true
fi

if [ -n "${AIMILIVPN_DOMAIN:-}" ]; then
  echo "HTTPS 管理后台: https://${AIMILIVPN_DOMAIN}:8443/  （备用 IP: https://${PUBLIC_IP}:8443/）"
else
  echo "HTTPS 管理后台: https://${PUBLIC_IP}:8443/"
fi
if [ -n "${AIMILIVPN_DOMAIN:-}" ]; then
  echo "HTTPS 订阅入口: https://${AIMILIVPN_DOMAIN}:18443/  （备用 IP: https://${PUBLIC_IP}:18443/）"
else
  echo "HTTPS 订阅入口: https://${PUBLIC_IP}:18443/"
fi
echo "内部管理服务:   http://127.0.0.1:8501/"