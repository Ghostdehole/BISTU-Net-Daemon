#!/bin/sh
# Version: 1.7 (Golden Master)
# Description: BISTU Dr.COM auto auth daemon for OpenWrt (Production & Defense Ready)

set -u
umask 077

SCRIPT_VERSION="1.7"

# 1. Check dependencies & Arguments
if [ "$#" -gt 1 ]; then
    echo "error: too many arguments" >&2
    exit 2
fi

for cmd in curl ip awk sed tr md5sum logger head; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "fatal: missing required command: $cmd" >&2
        exit 1
    }
done

CONFIG_FILE="/etc/bistu_auth.conf"

# 2. Securely load configuration
if [ -f "$CONFIG_FILE" ]; then
    perms=$(ls -ld "$CONFIG_FILE" 2>/dev/null | awk '{print $1}')
    case "$perms" in
        -[r-][w-][x-]------*) ;;
        *) echo "warning: $CONFIG_FILE permissions too open ($perms). recommend chmod 600" >&2 ;;
    esac
    . "$CONFIG_FILE"
fi

USER="${BISTU_USER:-}"
PASS="${BISTU_PASS:-}"

if [ -z "$USER" ] || [ -z "$PASS" ]; then
    echo "fatal: missing credentials in $CONFIG_FILE" >&2
    exit 1
fi

LAN_GW="${LAN_GW:-10.144.0.3}"
WLAN_GW="${WLAN_GW:-10.144.49.2}"
TEST_URL="${TEST_URL:-http://captive.apple.com/hotspot-detect.html}"
INTERVAL="${INTERVAL:-15}"
RETRY_SEC="${RETRY_SEC:-5}"
MAX_BACKOFF="${MAX_BACKOFF:-120}"
LOGIN_SCHEME="${LOGIN_SCHEME:-auto}"

# Globals set by probe_network
TARGET_GW=""
WAN_DEV=""
LOCAL_IP=""
LOCAL_MAC=""

log() {
    logger -t "bistu_auth" "[$$] $1" 2>/dev/null || true
    echo "[$(date '+%m-%d %H:%M:%S')] [$$] $1"
}

# probe_network return codes:
#   0 - ONLINE
#   1 - NO_INTERFACE
#   2 - NOT_CAMPUS
#   3 - NEED_LOGIN
probe_network() {
    local route_info alt_ip redirect
    
    # Always reset globals
    TARGET_GW=""
    WAN_DEV=""
    LOCAL_IP=""
    LOCAL_MAC=""

    route_info=$(ip route get "$LAN_GW" 2>/dev/null)
    WAN_DEV=$(echo "$route_info" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    LOCAL_IP=$(echo "$route_info" | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')

    if [ -z "$WAN_DEV" ] || [ -z "$LOCAL_IP" ]; then
        route_info=$(ip route get "$WLAN_GW" 2>/dev/null)
        WAN_DEV=$(echo "$route_info" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
        LOCAL_IP=$(echo "$route_info" | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    fi

    case "$WAN_DEV" in
        sing-*|tun*|tap*)
            WAN_DEV=$(ip route show table main default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
            [ -z "$WAN_DEV" ] && WAN_DEV=$(uci -q get network.wan.device || echo "eth0")
            LOCAL_IP=$(ip -4 addr show "$WAN_DEV" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
            ;;
    esac

    if [ -z "$WAN_DEV" ] || [ -z "$LOCAL_IP" ]; then
        return 1
    fi

    # MAC validation pipeline
    LOCAL_MAC=$(echo "${BISTU_MAC:-}" | tr -d ':-' | tr 'a-z' 'A-Z')
    if ! echo "$LOCAL_MAC" | grep -qE '^[0-9A-F]{12}$'; then
        [ -n "${BISTU_MAC:-}" ] && log "warning: invalid BISTU_MAC format, falling back to interface MAC"
        if [ -f "/sys/class/net/${WAN_DEV}/address" ]; then
            LOCAL_MAC=$(cat "/sys/class/net/${WAN_DEV}/address" | tr -d ':' | tr 'a-z' 'A-Z')
        else
            LOCAL_MAC=$(ip link show "$WAN_DEV" 2>/dev/null | awk '/link\/ether/ {print $2}' | tr -d ':' | tr 'a-z' 'A-Z')
        fi
    fi
    if ! echo "$LOCAL_MAC" | grep -qE '^[0-9A-F]{12}$'; then
        log "warning: no valid MAC found on $WAN_DEV, using zero-mac"
        LOCAL_MAC="000000000000"
    fi

    if curl -s -m 3 --interface "$WAN_DEV" "$TEST_URL" | grep -q "Success"; then
        return 0
    fi

    redirect=$(curl -s -m 3 --interface "$WAN_DEV" -o /dev/null -D - "$TEST_URL" | grep -i "^location:" | tr -d '\r' | head -1)

    if echo "$redirect" | grep -qE "10.144.0.3|lan.bistu.edu.cn"; then
        TARGET_GW="$LAN_GW"
    elif echo "$redirect" | grep -qE "10.144.49.2|wlan.bistu.edu.cn"; then
        TARGET_GW="$WLAN_GW"
    else
        if curl -s --connect-timeout 1 -m 2 -o /dev/null "http://${LAN_GW}"; then
            TARGET_GW="$LAN_GW"
        elif curl -s --connect-timeout 1 -m 2 -o /dev/null "http://${WLAN_GW}"; then
            TARGET_GW="$WLAN_GW"
        fi
    fi

    if [ -z "$TARGET_GW" ]; then
        return 2
    fi

    return 3
}

# do_login return codes:
#   0 - LOGIN_SUCCESS
#   3 - LOGIN_FAILED
do_login() {
    local url pid calg raw md5_hash upass_md5 attempt_cnt rand_v success mode upass r2 resp err xip

    case "$LOGIN_SCHEME" in
        http)  url="http://${TARGET_GW}/drcom/login" ;;
        https) url="https://${TARGET_GW}/drcom/login" ;;
        *)
            if curl -s -k --connect-timeout 2 -m 3 -o /dev/null "https://${TARGET_GW}/drcom/login" 2>/dev/null; then
                url="https://${TARGET_GW}/drcom/login"
            else
                url="http://${TARGET_GW}/drcom/login"
            fi
            ;;
    esac

    pid="1"
    calg="12345678"
    raw="${pid}${PASS}${calg}"
    md5_hash=$(printf "%s" "$raw" | md5sum | awk '{print $1}')
    upass_md5="${md5_hash}${calg}${pid}"

    success=0
    attempt_cnt=0

    for mode in "md5" "plain"; do
        attempt_cnt=$((attempt_cnt + 1))
        rand_v=$(( (${RANDOM:-0} + $$ * 31 + attempt_cnt * 7919) % 10000 + 500 ))

        if [ "$mode" = "md5" ]; then
            upass="$upass_md5"
            r2="1"
        else
            upass="$PASS"
            r2=""
            log "md5 auth failed, falling back to plain text"
        fi

        log "sending login request to $TARGET_GW ($mode) via $WAN_DEV"

        resp=$(curl -s -k -m 5 --interface "$WAN_DEV" "$url" \
            -G \
            --data-urlencode "callback=dr1001" \
            --data-urlencode "DDDDD=${USER}" \
            --data-urlencode "upass=${upass}" \
            --data-urlencode "0MKKey=123456" \
            --data-urlencode "R1=0" \
            --data-urlencode "R2=${r2}" \
            --data-urlencode "R3=0" \
            --data-urlencode "R6=0" \
            --data-urlencode "para=00" \
            --data-urlencode "v4ip=${LOCAL_IP}" \
            --data-urlencode "v6ip=" \
            --data-urlencode "terminal_type=1" \
            --data-urlencode "lang=en" \
            --data-urlencode "wlan_user_mac=${LOCAL_MAC}" \
            --data-urlencode "mac=${LOCAL_MAC}" \
            --data-urlencode "v=${rand_v}" \
            -H "User-Agent: Mozilla/5.0")

        if echo "$resp" | grep -qE '"result":(1|"ok")([^a-zA-Z0-9]|$)|"msg":"15"([^a-zA-Z0-9]|$)' || echo "$resp" | grep -qi 'clientip online'; then
            log "login payload accepted ($mode)"
            success=1
            break
        else
            err=$(echo "$resp" | sed -n 's/.*"msga":"\([^"]*\)".*/\1/p')
            [ -z "$err" ] && err=$(echo "$resp" | sed -n 's/.*"msg":"\([^"]*\)".*/\1/p')

            if echo "$resp" | grep -qE '"msg":(2|"2")([^0-9]|$)'; then
                xip=$(echo "$resp" | sed -n 's/.*"xip":"\([^"]*\)".*/\1/p')
                [ -n "$xip" ] && log "warning: account conflict! IP $xip is already online."
            fi

            if echo "$resp" | grep -qE '"msg":([01]|"[01]")([^0-9]|$)' && [ "$mode" = "md5" ]; then
                continue
            else
                log "login failed ($mode): ${err:-unknown error}"
                break
            fi
        fi
    done

    if [ "$success" -eq 1 ]; then
        return 0
    else
        return 3
    fi
}

check_auth() {
    probe_network
    local state=$?
    if [ "$state" -eq 3 ]; then
        do_login
        local login_state=$?
        if [ "$login_state" -eq 0 ]; then
            log "waiting 6s for firewall policy propagation..."
            sleep 6
            probe_network
            local post_state=$?
            if [ "$post_state" -eq 0 ]; then
                log "policy verified. connectivity fully restored."
                return 0
            else
                log "warning: login reported success but upstream check failed."
                
                # Single-shot Failover Logic (Escape Gateway Deadlock)
                local old_gw="$TARGET_GW"
                if [ "$TARGET_GW" = "$LAN_GW" ]; then
                    TARGET_GW="$WLAN_GW"
                else
                    TARGET_GW="$LAN_GW"
                fi
                log "failover: switching gateway from $old_gw to $TARGET_GW (dev=$WAN_DEV ip=$LOCAL_IP mac=$LOCAL_MAC)"
                
                do_login
                local retry_state=$?
                if [ "$retry_state" -eq 0 ]; then
                    sleep 6
                    probe_network
                    local retry_post=$?
                    if [ "$retry_post" -eq 0 ]; then
                        log "failover policy verified. connectivity restored via fallback."
                        return 0
                    fi
                fi
                
                return 3
            fi
        else
            return 3
        fi
    fi
    return "$state"
}

usage() {
    cat <<EOF
Usage: $0 [--daemon|--once|--status|--status-json|--help|--version]

  --daemon         run as background daemon with exponential backoff
  --once           run a single auth check and login if needed (default)
  --status         probe network state ONLY (exit codes: 0=ONLINE 10=NO_INTERFACE 11=NOT_CAMPUS 12=NEED_LOGIN)
  --status-json    print network state in JSON format (gateway may be 'none' when ONLINE; same exit codes as --status)
  --version        print version info
  --help           show this help
EOF
}

# 3. Execution controller
case "${1:---once}" in
    --daemon)
        trap 'log "bistu auth daemon stopped."; exit 0' TERM INT
        log "bistu auth daemon started (v$SCRIPT_VERSION)."
        fails=0

        while true; do
            check_auth
            ret=$?

            if [ "$ret" -eq 0 ]; then
                if [ "$fails" -gt 0 ]; then
                    log "connection restored. resetting fail counter."
                    fails=0
                fi
                sleep "$INTERVAL"
            elif [ "$ret" -eq 1 ]; then
                sleep "$RETRY_SEC"
            elif [ "$ret" -eq 2 ]; then
                fails=0
                sleep 30
            else
                fails=$((fails + 1))
                [ "$fails" -gt 100 ] && fails=100
                if [ "$fails" -ge 5 ]; then
                    backoff=$(( (fails - 4) * 30 ))
                    [ "$backoff" -gt "$MAX_BACKOFF" ] && backoff="$MAX_BACKOFF"
                    log "auth failed $fails times. sleeping for $backoff sec to avoid ban"
                    sleep "$backoff"
                else
                    sleep "$RETRY_SEC"
                fi
            fi
        done
        ;;
    --status)
        probe_network
        ret=$?
        case "$ret" in
            0) echo "ONLINE"; exit 0 ;;
            1) echo "NO_INTERFACE"; exit 10 ;;
            2) echo "NOT_CAMPUS"; exit 11 ;;
            3) echo "NEED_LOGIN"; exit 12 ;;
            *) echo "UNKNOWN"; exit 99 ;;
        esac
        ;;
    --status-json)
        probe_network
        ret=$?
        case "$ret" in
            0) state="ONLINE" ;;
            1) state="NO_INTERFACE" ;;
            2) state="NOT_CAMPUS" ;;
            3) state="NEED_LOGIN" ;;
            *) state="UNKNOWN" ;;
        esac
        printf '{"state":"%s","gateway":"%s","interface":"%s","ip":"%s","mac":"%s"}\n' \
            "$state" "${TARGET_GW:-none}" "${WAN_DEV:-none}" "${LOCAL_IP:-none}" "${LOCAL_MAC:-none}"
        case "$ret" in 0) exit 0;; 1) exit 10;; 2) exit 11;; 3) exit 12;; *) exit 99;; esac
        ;;
    --once)
        check_auth
        ret=$?
        case "$ret" in
            0) echo "auth success or already online" ;;
            1) echo "network interface not ready" ;;
            2) echo "not in campus network" ;;
            3) echo "login failed" ;;
            *) echo "unknown state" ;;
        esac
        exit "$ret"
        ;;
    --version)
        echo "bistu_auth v$SCRIPT_VERSION"
        exit 0
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    *)
        echo "error: unknown argument '${1}'" >&2
        usage >&2
        exit 2
        ;;
esac
