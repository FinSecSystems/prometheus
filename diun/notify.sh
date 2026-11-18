#!/bin/sh
# Diun script notifier: raise an info alert in Alertmanager (email + Telegram bot routes).
# Only real digest changes of a tag (status update) are sent. The alert lives 30 days so the route's repeat_interval does not re-send it.
set -eu
# "new" only means Diun saw this tag for the first time (it is what we deployed, e.g. right after an upgrade), and an
# image pinned by digest (name@sha256:...) is compared to nothing newer: neither is an update, so no alert (2026-11-19).
case "$DIUN_ENTRY_STATUS" in new) exit 0 ;; esac
case "$DIUN_ENTRY_IMAGE" in *@sha256:*) exit 0 ;; esac
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ends=$(date -u -d "@$(( $(date +%s) + 2592000 ))" +%Y-%m-%dT%H:%M:%SZ)
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
body=$(printf '[{"labels":{"alertname":"ImageUpdateAvailable","severity":"info","image":"%s"},"annotations":{"summary":"Image update: %s (%s)","description":"Diun status %s, platform %s, digest %s, %s"},"startsAt":"%s","endsAt":"%s"}]' \
  "$(esc "$DIUN_ENTRY_IMAGE")" "$(esc "$DIUN_ENTRY_IMAGE")" "$(esc "$DIUN_ENTRY_STATUS")" \
  "$(esc "$DIUN_ENTRY_STATUS")" "$(esc "$DIUN_ENTRY_PLATFORM")" "$(esc "$DIUN_ENTRY_DIGEST")" "$(esc "${DIUN_ENTRY_HUBLINK:-}")" "$now" "$ends")
wget -q -O /dev/null --header 'Content-Type: application/json' --post-data "$body" http://prometheus-alertmanager:9093/api/v2/alerts
