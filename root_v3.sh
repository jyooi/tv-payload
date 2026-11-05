#!/bin/sh
# root_v2.sh - instrumented jsbro root payload
# Reports every step to the local reporting server.

LOGFILE="/tmp/root-v3.log"
REPORT_URL="http://192.168.100.231:8899"
APPID="com.webos.service.secondscreen.gateway"
SCRIPT_NAME="Jsbro Root v2"

IPK_URL="https://github.com/webosbrew/webos-homebrew-channel/releases/download/v0.7.3/org.webosbrew.hbchannel_0.7.3_all.ipk"
IPK_TMP="/tmp/hbchannel-v2.ipk"
FIFO="/tmp/root-v3.fifo"

HBC_SERVICE="/media/developer/apps/usr/palm/services/org.webosbrew.hbchannel.service/elevate-service"
HBC_STARTUP="/media/developer/apps/usr/palm/services/org.webosbrew.hbchannel.service/startup.sh"

: > "$LOGFILE"

if ! mkdir /tmp/root-v3-lock 2>/dev/null; then
    echo "lock exists, exiting"
    exit 0
fi

log() {
    echo "[$(date -Iseconds)] $*" >> "$LOGFILE"
}

report() {
    log "report step: $1"
    curl -s --max-time 5 "$REPORT_URL/report/step/$1" >> "$LOGFILE" 2>&1 || true
}

send_toast() {
    log "Toast: $1"
    luna-send -w 2000 -a "$APPID" -n 1 \
        'luna://com.webos.notification/createToast' \
        "$(printf '{"sourceId":"%s","message":"%s"}' "$APPID" "$1")" \
        >> "$LOGFILE" 2>&1 || true
}

log "===== root_v2 start ====="
report "script-started"
send_toast "Starting root setup v2."

if [ "$(id -u)" -ne 0 ]; then
    log "Not root. jsserver did not grant uid 0."
    report "fail-not-root"
    exit 1
fi
log "Root privileges confirmed."
report "root-ok"

SDKV="$(luna-send -w 2000 -n 1 -q 'sdkVersion' -f \
    'luna://com.webos.service.tv.systemproperty/getSystemInfo' \
    '{"keys":["sdkVersion"]}' 2>> "$LOGFILE" \
    | sed -n -e 's/^\s*"sdkVersion":\s*"\([0-9.]\+\)"\s*,\?\s*$/\1/p')"
log "webOS sdkVersion: ${SDKV:-unavailable}"
report "sdk-${SDKV:-unknown}"

DEVMODE_FLAG="/var/luna/preferences/devmode_enabled"
if [ -d "$DEVMODE_FLAG" ]; then
    log "Dev mode already enabled."
else
    rm -f "$DEVMODE_FLAG" 2>> "$LOGFILE" || true
    mkdir -p "$DEVMODE_FLAG" 2>> "$LOGFILE"
    if [ -d "$DEVMODE_FLAG" ]; then
        log "Dev mode enabled."
        report "devmode-enabled"
    else
        log "Failed to create devmode_enabled."
        report "fail-devmode"
        send_toast "Root setup failed at dev mode flag."
        exit 1
    fi
fi

log "Downloading Homebrew Channel IPK."
send_toast "Downloading Homebrew Channel..."
if curl -L -o "$IPK_TMP" -- "$IPK_URL" >> "$LOGFILE" 2>&1; then
    IPK_SIZE="$(stat -c %s "$IPK_TMP" 2>/dev/null || echo 0)"
    log "IPK downloaded, size: $IPK_SIZE bytes."
    report "ipk-downloaded-$IPK_SIZE"
    if [ "$IPK_SIZE" -lt 100000 ]; then
        log "IPK too small, download broken."
        report "fail-ipk-size"
        exit 1
    fi
else
    log "IPK download failed."
    report "fail-ipk-download"
    send_toast "Root setup failed at IPK download."
    exit 1
fi

log "Restarting appinstalld."
restart appinstalld >> "$LOGFILE" 2>&1 || log "appinstalld restart failed, continuing."
sleep 2
report "appinstalld-restarted"

install_attempt() {
    rm -f "$FIFO" 2>> "$LOGFILE" || true
    mkfifo "$FIFO" 2>> "$LOGFILE" || return 1
    luna-send -w 90000 -i \
        'luna://com.webos.appInstallService/dev/install' \
        "$(printf '{"id":"com.ares.defaultName","ipkUrl":"%s","subscribe":true}' "$IPK_TMP")" \
        > "$FIFO" 2>> "$LOGFILE" &
    LUNA_PID="$!"
    RESULT="$(grep -m 1 -E 'installed|failed|Unknown method' -- "$FIFO")"
    kill -TERM "$LUNA_PID" 2>/dev/null || true
    rm -f "$FIFO" 2>> "$LOGFILE" || true
    echo "$RESULT"
}

INSTALL_STATUS="failed"
ATTEMPT=1
while [ "$ATTEMPT" -le 3 ]; do
    log "Install attempt $ATTEMPT."
    OUT="$(install_attempt)"
    log "Install response: $OUT"
    if echo "$OUT" | grep -q 'installed'; then
        INSTALL_STATUS="installed"
        break
    fi
    if echo "$OUT" | grep -q 'Unknown method'; then
        INSTALL_STATUS="unknown-method"
        break
    fi
    ATTEMPT=$((ATTEMPT + 1))
    sleep 5
done

if [ "$INSTALL_STATUS" != "installed" ]; then
    log "Install failed with status: $INSTALL_STATUS"
    report "fail-install-$INSTALL_STATUS"
    send_toast "Root setup failed at install step."
    exit 1
fi
report "ipk-installed"

if [ -x "$HBC_SERVICE" ] && [ -f "$HBC_STARTUP" ]; then
    log "HBC service files present."
else
    log "HBC service files missing after install."
    report "fail-hbc-files-missing"
fi

log "Executing elevate-service."
if "$HBC_SERVICE" >> "$LOGFILE" 2>&1; then
    log "elevate-service completed."
    report "elevated"
else
    log "elevate-service failed."
    report "fail-elevate"
fi

DEVMODE_APP_STATE="$(luna-send -w 2000 -n 1 -f \
    'luna://com.webos.applicationManager/getAppLoadStatus' \
    '{"appId":"com.palmdts.devmode"}' 2>> "$LOGFILE" || true)"
log "Dev Mode app state: $DEVMODE_APP_STATE"
if echo "$DEVMODE_APP_STATE" | grep -q '"exist"[[:space:]]*:[[:space:]]*true'; then
    log "Dev Mode app present, attempting removal."
    rm -f "$FIFO" 2>> "$LOGFILE" || true
    mkfifo "$FIFO" 2>> "$LOGFILE" || true
    luna-send -w 30000 -i \
        'luna://com.webos.appInstallService/remove' \
        '{"id":"com.palmdts.devmode","subscribe":true}' \
        > "$FIFO" 2>> "$LOGFILE" &
    LUNA_PID="$!"
    RMRESULT="$(grep -m 1 -E '"statusValue"[[:space:]]*:[[:space:]]*(31|25)|Unknown method|"returnValue"[[:space:]]*:[[:space:]]*false' -- "$FIFO")"
    kill -TERM "$LUNA_PID" 2>/dev/null || true
    rm -f "$FIFO" 2>> "$LOGFILE" || true
    log "Dev Mode removal response: $RMRESULT"
    report "devmode-app-removal-attempted"
else
    log "Dev Mode app not installed, nothing to remove."
    report "devmode-app-absent"
fi

log "Creating final alert."
ALERT_MSG="<h3>${SCRIPT_NAME}</h3><br>Root setup complete.<br><br>Reboot the TV to activate persistent root. Quick Start+ must be disabled."
luna-send -w 2000 -a "$APPID" -n 1 \
    'luna://com.webos.notification/createAlert' \
    "$(printf '{"sourceId":"%s","message":"%s","buttons":[{"label":"OK"}]}' "$APPID" "$ALERT_MSG")" \
    >> "$LOGFILE" 2>&1 || true

log "===== root_v2 finished ====="
report "script-done"
curl -s --max-time 10 --data-binary @"$LOGFILE" "$REPORT_URL/report/log" >> "$LOGFILE" 2>&1 || true
exit 0
