#!/bin/sh
# Diun script notifier: raise an info alert in Alertmanager (email + Telegram bot routes).
# The alert lives 30 days so the route's repeat_interval does not re-send it.
set -eu
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ends=$(date -u -d "@$(( $(date +%s) + 2592000 ))" +%Y-%m-%dT%H:%M:%SZ)
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
body=$(printf '[{"labels":{"alertname":"ImageUpdateAvailable","severity":"info","image":"%s"},"annotations":{"summary":"Image update: %s (%s)","description":"Diun status %s, platform %s, digest %s, %s"},"startsAt":"%s","endsAt":"%s"}]' \
  "$(esc "$DIUN_ENTRY_IMAGE")" "$(esc "$DIUN_ENTRY_IMAGE")" "$(esc "$DIUN_ENTRY_STATUS")" \
  "$(esc "$DIUN_ENTRY_STATUS")" "$(esc "$DIUN_ENTRY_PLATFORM")" "$(esc "$DIUN_ENTRY_DIGEST")" "$(esc "${DIUN_ENTRY_HUBLINK:-}")" "$now" "$ends")
wget -q -O /dev/null --header 'Content-Type: application/json' --post-data "$body" http://prometheus-alertmanager:9093/api/v2/alerts
