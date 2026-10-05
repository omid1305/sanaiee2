#!/bin/bash
set -u

CONFIG_FILE="/etc/x-ui/config.json"
LOG() { echo "[panel-bootstrap] $*"; }

PANEL_PORT=$(jq -r '.xui.internal_port // 2053' "$CONFIG_FILE")
BASE_PATH=$(jq -r '.xui.web_base_path // "/managepanel"' "$CONFIG_FILE")
SUB_PORT=$(jq -r '.xui.subscription_port // 2096' "$CONFIG_FILE")
SUB_LISTEN=$(jq -r '.xui.subscription_listen // "127.0.0.1"' "$CONFIG_FILE")
# Prefer an explicit override, otherwise use Railway's injected public domain.
DOMAIN="${PUBLIC_DOMAIN:-${RAILWAY_PUBLIC_DOMAIN:-}}"
DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN%%/*}"
DB="/etc/x-ui/x-ui.db"

wait_for_db() {
    for i in $(seq 1 30); do
        [ -f "$DB" ] && return 0
        sleep 1
    done
    return 1
}

set_setting() {
    local key="$1" value="$2"
    [ -f "$DB" ] || return 0
    sqlite3 "$DB" "UPDATE settings SET value=$(printf '%s' "$value" | jq -Rs .) WHERE key=$(printf '%s' "$key" | jq -Rs .); INSERT INTO settings(key,value) SELECT $(printf '%s' "$key" | jq -Rs .),$(printf '%s' "$value" | jq -Rs .) WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key=$(printf '%s' "$key" | jq -Rs .));" 2>/dev/null || true
}

wait_for_db || { LOG "⚠️ SQLite DB was not created yet; skipping public URL settings."; exit 0; }

if [ -n "$DOMAIN" ]; then
    LOG "🌐 Configuring single-domain settings for $DOMAIN"
    set_setting "webDomain" "$DOMAIN"
    set_setting "subDomain" "$DOMAIN"
    set_setting "subPort" "$SUB_PORT"
    set_setting "subListen" "$SUB_LISTEN"
    set_setting "subURI" "https://${DOMAIN}/sub/"
    set_setting "subJsonURI" "https://${DOMAIN}/json/"
    set_setting "subClashURI" "https://${DOMAIN}/clash/"
    set_setting "subPath" "/sub/"
    set_setting "subJsonPath" "/json/"
    set_setting "subClashPath" "/clash/"
    LOG "✅ Panel/subscription domain settings applied"
else
    LOG "⚠️ No public domain detected. If this is Railway, generate a Public Domain under Networking; Railway then exposes it as RAILWAY_PUBLIC_DOMAIN automatically."
fi

LOG "ℹ️ No inbound is created, deleted, migrated, or routed by this bootstrap."
LOG "ℹ️ Users can create manual inbounds in the reserved 8080-8090 range."
