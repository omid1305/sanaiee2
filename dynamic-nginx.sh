#!/bin/bash
set -u

CONFIG_FILE="/etc/x-ui/config.json"
PANEL_PORT=$(jq -r '.xui.internal_port // 2053' "$CONFIG_FILE")
BASE_PATH=$(jq -r '.xui.web_base_path // "/managepanel"' "$CONFIG_FILE")
PANEL_INTERNAL="http://127.0.0.1:${PANEL_PORT}${BASE_PATH}"
USER_NAME="${XUI_USERNAME:-$(jq -r '.xui.default_username // "admin"' "$CONFIG_FILE")}"
USER_PASS="${XUI_PASSWORD:-$(jq -r '.xui.default_password // "admin"' "$CONFIG_FILE")}"
API_TOKEN="${XUI_API_TOKEN:-}"
ROUTES_DIR="/etc/nginx/inbounds"
COOKIE_JAR="/tmp/xui-route-cookies.txt"
CSRF_TOKEN=""
STATE_FILE="/tmp/xui-route-state.sha256"

mkdir -p "$ROUTES_DIR"

api_get() {
    local path="$1"
    if [ -n "$API_TOKEN" ]; then
        curl -fsS --max-time 10 -H "Authorization: Bearer ${API_TOKEN}" "${PANEL_INTERNAL}${path}"
    else
        curl -fsS --max-time 10 -b "$COOKIE_JAR" "${PANEL_INTERNAL}${path}"
    fi
}

login() {
    if [ -n "$API_TOKEN" ]; then
        return 0
    fi

    local csrf_resp resp ok json_data
    csrf_resp=$(curl -fsS --max-time 10 -c "$COOKIE_JAR" "${PANEL_INTERNAL}/csrf-token" 2>/dev/null || true)
    CSRF_TOKEN=$(printf '%s' "$csrf_resp" | jq -r '.obj // .token // empty' 2>/dev/null || true)
    json_data=$(jq -nc --arg u "$USER_NAME" --arg p "$USER_PASS" '{username:$u,password:$p}')

    if [ -n "$CSRF_TOKEN" ]; then
        resp=$(curl -fsS --max-time 10 -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
            -H 'Content-Type: application/json' -H "X-CSRF-Token: ${CSRF_TOKEN}" \
            -X POST "${PANEL_INTERNAL}/login" -d "$json_data" 2>/dev/null || true)
    else
        resp=$(curl -fsS --max-time 10 -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
            -H 'Content-Type: application/json' -X POST "${PANEL_INTERNAL}/login" \
            -d "$json_data" 2>/dev/null || true)
    fi

    ok=$(printf '%s' "$resp" | jq -r '.success // empty' 2>/dev/null || true)
    [ "$ok" = "true" ]
}

sanitize_name() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

extract_path() {
    local network="$1" stream="$2"
    case "$network" in
        ws|websocket)
            printf '%s' "$stream" | jq -r '.wsSettings.path // empty'
            ;;
        xhttp|splithttp)
            printf '%s' "$stream" | jq -r '.xhttpSettings.path // .splitHttpSettings.path // empty'
            ;;
        *)
            printf ''
            ;;
    esac
}

build_routes() {
    local data="$1"
    local tmpdir="${ROUTES_DIR}.new"
    rm -rf "$tmpdir"
    mkdir -p "$tmpdir"

    # Full inbound objects are preferred. If this API version exposes only a
    # slim list, no route is generated rather than guessing.
    if ! printf '%s' "$data" | jq -e '.success == true and (.obj | type == "array")' >/dev/null 2>&1; then
        echo "⚠️ Invalid inbound API response; keeping existing routes."
        rm -rf "$tmpdir"
        return 1
    fi

    local count=0
    while IFS=$'\t' read -r id port network security stream; do
        [ -n "$port" ] || continue
        [ -n "$network" ] || continue

        local path
        path=$(extract_path "$network" "$stream")
        [ -n "$path" ] || continue
        [[ "$path" == /* ]] || path="/$path"
        [[ "$path" != *$'\n'* ]] || continue

        # Reserved application routes must never be shadowed by an inbound.
        case "$path" in
            /managepanel|/managepanel/*|/sub|/sub/*|/json|/json/*|/clash|/clash/*|/health|/ping)
                echo "⚠️ Skipping reserved inbound path: $path"
                continue
                ;;
        esac

        # This router is for HTTP-based WS/XHTTP transports. Nginx terminates
        # the public HTTPS connection and forwards HTTP/1.1 to the local Xray port.
        # TLS-enabled upstream inbounds are intentionally not proxied here.
        if [ "$security" != "none" ] && [ "$security" != "" ] && [ "$security" != "null" ]; then
            echo "⚠️ Skipping TLS-enabled HTTP inbound id=${id}, path=${path}; use security=none behind Nginx."
            continue
        fi

        local name
        name="$(sanitize_name "${id}_${path}")"
        cat > "${tmpdir}/${name}.conf" <<NGINX
location = ${path} {
    proxy_pass http://127.0.0.1:${port};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}

location ^~ ${path}/ {
    proxy_pass http://127.0.0.1:${port};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}
NGINX
        count=$((count + 1))
    done < <(printf '%s' "$data" | jq -r '.obj[] | [(.id // "unknown"), (.port // ""), (.streamSettings.network // ""), (.streamSettings.security // "none"), ((.streamSettings // {}) | tojson)] | @tsv' 2>/dev/null)

    rm -rf "$ROUTES_DIR.old"
    mv "$ROUTES_DIR" "$ROUTES_DIR.old" 2>/dev/null || true
    mv "$tmpdir" "$ROUTES_DIR"
    rm -rf "$ROUTES_DIR.old"

    local hash
    hash=$(find "$ROUTES_DIR" -type f -print0 | sort -z | xargs -0 cat 2>/dev/null | sha256sum | awk '{print $1}')
    local old=""
    [ -f "$STATE_FILE" ] && old=$(cat "$STATE_FILE" 2>/dev/null || true)

    if [ "$hash" != "$old" ]; then
        printf '%s' "$hash" > "$STATE_FILE"
        echo "🔄 Inbound routes changed: ${count} HTTP routes"
        if nginx -t >/dev/null 2>&1; then
            nginx -s reload >/dev/null 2>&1 || true
            echo "✅ Nginx reloaded with ${count} inbound route(s)."
        else
            echo "❌ Nginx config test failed; routes were written but reload was skipped."
            return 1
        fi
    fi

    return 0
}

sync_once() {
    if ! login; then
        echo "⚠️ Could not authenticate to Senai API; keeping existing inbound routes."
        return 1
    fi

    local data
    data=$(api_get "/panel/api/inbounds/list" 2>/dev/null || true)
    if [ -z "$data" ]; then
        echo "⚠️ Inbound list API returned nothing; keeping existing routes."
        return 1
    fi
    build_routes "$data"
}

sync_once
