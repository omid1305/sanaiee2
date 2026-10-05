#!/bin/bash
set -u

CONFIG_FILE="/etc/x-ui/config.json"
[ -f "$CONFIG_FILE" ] || { echo "❌ Missing $CONFIG_FILE"; exit 1; }

NGINX_PORT=$(jq -r '.server.public_port // 3000' "$CONFIG_FILE")
XUI_INTERNAL_PORT=$(jq -r '.xui.internal_port // 2053' "$CONFIG_FILE")
XUI_WEB_BASE_PATH=$(jq -r '.xui.web_base_path // "/managepanel"' "$CONFIG_FILE")
export NGINX_PORT

# Railway injects RAILWAY_PUBLIC_DOMAIN when the service has a public domain.
# PUBLIC_DOMAIN remains an optional override for custom/static deployments.
detect_public_domain() {
    local d="${PUBLIC_DOMAIN:-}"
    local source="PUBLIC_DOMAIN"
    if [ -z "$d" ]; then
        d="${RAILWAY_PUBLIC_DOMAIN:-}"
        source="RAILWAY_PUBLIC_DOMAIN"
    fi
    d="${d#http://}"
    d="${d#https://}"
    d="${d%%/*}"
    if [ -n "$d" ]; then
        PUBLIC_DOMAIN="$d"
        PUBLIC_DOMAIN_SOURCE="$source"
    else
        PUBLIC_DOMAIN=""
        PUBLIC_DOMAIN_SOURCE="none"
    fi
    export PUBLIC_DOMAIN PUBLIC_DOMAIN_SOURCE
}
detect_public_domain

cd /usr/local/x-ui || exit 1
pkill -f x-ui 2>/dev/null || true
pkill -f xray 2>/dev/null || true
sleep 2

mkdir -p /etc/nginx/inbounds
rm -f /etc/nginx/inbounds/*.conf /tmp/xui-route-state.sha256

echo "🚀 Starting Senai/3x-ui for Railway — no Tor, no auto-created inbounds"
if [ -n "$PUBLIC_DOMAIN" ]; then
    echo "🌐 Public domain: https://${PUBLIC_DOMAIN} (source: ${PUBLIC_DOMAIN_SOURCE})"
else
    echo "⚠️ No public domain detected. Railway must have a generated/custom public domain for stable HTTPS subscription URLs."
fi
echo "🔌 Manual inbound range: 8080-8090 (internal reservation)"

echo "🔧 Applying panel settings..."
./x-ui setting -port "$XUI_INTERNAL_PORT" -webBasePath "$XUI_WEB_BASE_PATH" -listenIP "127.0.0.1" || echo "⚠️ x-ui setting command failed; continuing"

echo "▶️ Starting 3x-ui web/subscription server..."
./x-ui run > /var/log/x-ui/runtime.log 2>&1 &
XUI_PID=$!

PANEL_READY=false
for i in $(seq 1 30); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}"         "http://127.0.0.1:${XUI_INTERNAL_PORT}${XUI_WEB_BASE_PATH}/login"         || true)

    # Any HTTP response means the web server is listening.
    # Do not require HTTP 200: redirects are valid during panel startup.
    if [ "$HTTP_CODE" != "000" ]; then
        PANEL_READY=true
        echo "✅ 3x-ui is responding (HTTP $HTTP_CODE)"
        break
    fi

    sleep 2
done

if [ "$PANEL_READY" != "true" ]; then
    echo "❌ 3x-ui panel did not become ready. Runtime log:"
    cat /var/log/x-ui/runtime.log 2>/dev/null || true
    exit 1
fi

# Configure public-domain/subscription settings after the DB exists.
/panel-bootstrap.sh 2>&1 | tee /var/log/panel-bootstrap.log || true

# Render the static/base nginx configuration.
envsubst '${NGINX_PORT}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

if ! nginx -t; then
    echo "❌ nginx config test failed"
    exit 1
fi

# Build initial dynamic WS/XHTTP routes before nginx starts.
if [ -x /dynamic-nginx.sh ]; then
    /dynamic-nginx.sh 2>&1 | tee /var/log/dynamic-nginx.log || true
fi

if ! nginx -t; then
    echo "❌ nginx config test failed after dynamic route generation"
    exit 1
fi

if ! kill -0 "$XUI_PID" 2>/dev/null; then
    echo "❌ 3x-ui process exited unexpectedly. Runtime log:"
    cat /var/log/x-ui/runtime.log 2>/dev/null || true
    exit 1
fi

# Keep Nginx routes synchronized with manual inbounds created/edited/deleted in Senai.
# Only reloads Nginx when the generated route set actually changes.
(
    while true; do
        sleep 5
        /dynamic-nginx.sh >> /var/log/dynamic-nginx.log 2>&1 || true
    done
) &
ROUTE_SYNC_PID=$!

trap 'kill "$ROUTE_SYNC_PID" 2>/dev/null || true; kill "$XUI_PID" 2>/dev/null || true' TERM INT EXIT

echo "============================================================"
echo "✅ Senai Railway single-domain mode is ready"
echo "🌐 Panel: https://${PUBLIC_DOMAIN:-YOUR_DOMAIN}${XUI_WEB_BASE_PATH}/"
echo "📦 Subscription: https://${PUBLIC_DOMAIN:-YOUR_DOMAIN}/sub/<TOKEN>"
echo "🧾 JSON: https://${PUBLIC_DOMAIN:-YOUR_DOMAIN}/json/<TOKEN>"
echo "☁️ Clash: https://${PUBLIC_DOMAIN:-YOUR_DOMAIN}/clash/<TOKEN>"
echo "🔀 Dynamic WS/XHTTP routing: ENABLED"
echo "🔌 Manual inbound range: 8080-8090"
echo "============================================================"

exec nginx -g 'daemon off;'
