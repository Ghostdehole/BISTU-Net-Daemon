#!/bin/sh
# BISTU Dr.COM account authentication service for OpenWrt.

set -u
umask 077

SCRIPT_VERSION="1.8.0"

# 1. Check dependencies & Arguments
if [ "$#" -gt 1 ]; then
    echo "error: too many arguments" >&2
    exit 2
fi

usage() {
    cat <<EOF
Usage: $0 [--daemon|--once|--status|--status-json|--help|--version]

  --daemon         run as background daemon with exponential backoff
  --once           run a single auth check and login if needed (default)
  --status         read-only connectivity check: 0=ONLINE 10=NO_INTERFACE 11=NOT_CAMPUS 12=NEED_LOGIN 13=INCONCLUSIVE
  --status-json    print network state in JSON format (gateway may be 'none' when ONLINE; same exit codes as --status)
  --version        print version info
  --help           show this help
EOF
}

case "${1:-}" in
    --version) echo "bistu_auth v$SCRIPT_VERSION"; exit 0 ;;
    --help|-h) usage; exit 0 ;;
esac

for cmd in curl ip awk sed tr md5sum logger head; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "fatal: missing required command: $cmd" >&2
        exit 1
    }
done

CONFIG_FILE="/etc/bistu_auth.conf"

# 2. Securely load configuration
if [ ! -f "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]; then
    echo "fatal: expected a regular file at $CONFIG_FILE" >&2
    exit 1
fi
case $(LC_ALL=C ls -ldn "$CONFIG_FILE" | awk '{print $3 ":" $1}') in
    0:-r--------|0:-rw-------) ;;
    *) echo "fatal: $CONFIG_FILE must be root-owned, with mode 600 or 400" >&2; exit 1 ;;
esac
. "$CONFIG_FILE"

USER="${BISTU_USER:-}"
PASS="${BISTU_PASS:-}"
LOGIN_SCHEME="${LOGIN_SCHEME:-auto}"
CAMPUS_INTERFACE="${CAMPUS_INTERFACE-wan}"
if [ "$LOGIN_SCHEME" = verified ]; then
    case "$CAMPUS_INTERFACE" in ''|*[!a-zA-Z0-9_]*) echo 'invalid CAMPUS_INTERFACE' >&2; exit 2 ;; esac
fi
if [ "${1:-}" = --print-campus-interface ]; then
    if [ "$LOGIN_SCHEME" = verified ]; then printf '%s\n' "$CAMPUS_INTERFACE"; fi
    exit 0
fi

if [ -z "$USER" ] || [ -z "$PASS" ]; then
    echo "fatal: missing credentials in $CONFIG_FILE" >&2
    exit 1
fi

LAN_GW="${LAN_GW:-10.144.0.3}"
WLAN_GW="${WLAN_GW:-10.144.49.2}"
TEST_URL="${TEST_URL:-http://captive.apple.com/hotspot-detect.html}"
if [ "$LOGIN_SCHEME" = verified ]; then
    INTERVAL="${INTERVAL:-180}"
    CAMPUS_PASSWORD_FORM="${CAMPUS_PASSWORD_FORM:-md5}"
    case "$CAMPUS_PASSWORD_FORM" in md5|password) ;; *) echo 'invalid CAMPUS_PASSWORD_FORM' >&2; exit 2 ;; esac
    case "$INTERVAL" in ''|*[!0-9]*|0*) echo 'invalid INTERVAL' >&2; exit 2 ;; esac
    [ "${#INTERVAL}" -le 6 ] || { echo 'invalid INTERVAL' >&2; exit 2; }
else
    INTERVAL="${INTERVAL:-15}"
fi
RETRY_SEC="${RETRY_SEC:-5}"
MAX_BACKOFF="${MAX_BACKOFF:-120}"

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
#   4 - INCONCLUSIVE
probe_verified() {
    local net page status redirect authority host
    net=$(ubus -t 4 call "network.interface.$CAMPUS_INTERFACE" status 2>/dev/null) || return 1
    [ "$(jsonfilter -s "$net" -e '@.up')" = true ] || return 1
    WAN_DEV=$(jsonfilter -s "$net" -e '@.l3_device')
    LOCAL_IP=$(jsonfilter -s "$net" -e '@["ipv4-address"][0].address')
    case "$WAN_DEV" in ''|*[!a-zA-Z0-9_.:-]*) return 1 ;; esac
    case "$LOCAL_IP" in ''|*[!0-9.]*) return 1 ;; esac

    # One credential-free HTTP probe. A timeout or an unexpected page never starts a login.
    page=$(curl -q -4 -s -i --max-filesize 32768 -m 5 --noproxy '*' --interface "if!$WAN_DEV" "$TEST_URL") || return 4
    status=$(printf '%s\n' "$page" | awk 'NR==1 {print $2; exit}')
    case "$status" in
        204) return 0 ;;
        200)
            if printf '%s\n' "$page" | awk '{sub(/\r$/,"")} !body {if ($0=="") body=1; next} {text=text tolower($0)} END {exit !(text ~ /<body>[[:space:]]*success[[:space:]]*<\/body>/ || text ~ /^[[:space:]]*success[[:space:]]*$/)}'; then return 0; fi
            return 4 ;;
        301|302|303|307|308) ;;
        *) return 4 ;;
    esac
    redirect=$(printf '%s\n' "$page" | awk '{sub(/\r$/,"")} $0=="" {exit} tolower($1)=="location:" {print $2; exit}')
    case "$redirect" in http://*|https://*) ;; *) return 4 ;; esac
    authority=${redirect#*://}; authority=${authority%%[/?#]*}
    case "$authority" in *@*) return 2 ;; esac
    host=$(printf '%s' "${authority%%:*}" | tr 'A-Z' 'a-z')
    case "$host" in
        lan.bistu.edu.cn|"$LAN_GW") TARGET_GW="$LAN_GW" ;;
        wlan.bistu.edu.cn|"$WLAN_GW") TARGET_GW="$WLAN_GW" ;;
        *) return 2 ;;
    esac
    LOCAL_MAC=$(ip link show dev "$WAN_DEV" 2>/dev/null | awk '/link\/ether/ {print $2; exit}' | tr -d ':' | tr 'a-f' 'A-F')
    printf '%s\n' "$LOCAL_MAC" | grep -qE '^[0-9A-F]{12}$' || return 4
    return 3
}

probe_network() {
    local route_info alt_ip redirect
    
    # Always reset globals
    TARGET_GW=""
    WAN_DEV=""
    LOCAL_IP=""
    LOCAL_MAC=""

    if [ "$LOGIN_SCHEME" = verified ]; then
        probe_verified
        return $?
    fi

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

    if curl -q -s -m 3 --noproxy '*' --interface "$WAN_DEV" "$TEST_URL" | grep -q "Success"; then
        return 0
    fi

    redirect=$(curl -q -s -m 3 --noproxy '*' --interface "$WAN_DEV" -o /dev/null -D - "$TEST_URL" | awk 'tolower($1) == "location:" { print $2; exit }' | tr -d '\r')

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

# Decode the JSON or the requested JSONP callback from the authenticated HTTPS endpoint.
verified_reply() {
    local json result msg detail success
    json=$(printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$json" in
        dr1001\(*\)\;) json=${json#dr1001(}; json=${json%??} ;;
        dr1001\(*\)) json=${json#dr1001(}; json=${json%?} ;;
    esac
    case "$json" in \{*\}) ;; *) return 3 ;; esac
    result=$(printf '%s' "$json" | jsonfilter -e '@.result' 2>/dev/null)
    msg=$(printf '%s' "$json" | jsonfilter -e '@.msg' 2>/dev/null)
    detail=$(printf '%s' "$json" | jsonfilter -e '@.msga' 2>/dev/null)
    success=$(printf '%s' "$json" | jsonfilter -e '@.success' 2>/dev/null)
    case "$result" in 1|ok) return 0 ;; esac
    [ "$msg" = 15 ] || [ "$detail" = 'clientip online' ] || {
        case "$msg" in 0|1|2|3|4|5) return 5 ;; esac
        case "$result" in 0|false) return 5 ;; esac
        [ "$success" = false ] && return 5
        return 3
    }
    return 0
}

# do_login return codes:
#   0 - LOGIN_SUCCESS
#   3 - temporary or unknown login failure
#   5 - verified portal rejected the submission
do_login() {
    local url pid calg raw md5_hash upass_md5 attempt_cnt rand_v success mode upass r2 resp err xip portal dev reply_state

    set -- -k
    dev=$WAN_DEV
    case "$LOGIN_SCHEME" in
        verified)
            case "$TARGET_GW" in
                "$LAN_GW") portal=lan.bistu.edu.cn ;;
                "$WLAN_GW") portal=wlan.bistu.edu.cn ;;
                *) return 3 ;;
            esac
            url="https://${portal}/drcom/login"
            dev="if!$WAN_DEV"
            set -- -4 --fail --max-filesize 32768 --proto '=https' --resolve "${portal}:443:${TARGET_GW}"
            ;;
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

    local modes="md5 plain"
    if [ "$LOGIN_SCHEME" = verified ]; then
        case "$CAMPUS_PASSWORD_FORM" in md5) modes=md5 ;; password) modes=plain ;; esac
    fi
    for mode in $modes; do
        attempt_cnt=$((attempt_cnt + 1))
        rand_v=$(( (${RANDOM:-0} + $$ * 31 + attempt_cnt * 7919) % 10000 + 500 ))

        if [ "$mode" = "md5" ]; then
            upass="$upass_md5"
            r2="1"
        else
            upass="$PASS"
            r2=""
            log "using the password form ($LOGIN_SCHEME transport)"
        fi

        log "sending login request to $TARGET_GW ($mode) via $WAN_DEV"

        # Read the password field from stdin so it is not exposed in curl's argv.
        resp=$(printf '%s' "$upass" | curl -q -s "$@" --noproxy '*' -m 5 --interface "$dev" "$url" \
            -G \
            --data-urlencode "callback=dr1001" \
            --data-urlencode "DDDDD=${USER}" \
            --data-urlencode 'upass@-' \
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
            -H "User-Agent: Mozilla/5.0") || {
                log "login transport failed ($LOGIN_SCHEME); check portal availability, clock and CA trust"
                return 3
            }

        if [ "$LOGIN_SCHEME" = verified ]; then
            verified_reply "$resp"; reply_state=$?
            case "$reply_state" in
                0) log "portal accepted login; checking campus connectivity" ;;
                5) log "portal rejected the request; automatic submissions paused until service restart" ;;
                *) log "unrecognized portal response; retry later" ;;
            esac
            return "$reply_state"
        fi
        if echo "$resp" | grep -qE '"result"[[:space:]]*:[[:space:]]*(1|"ok")([^a-zA-Z0-9]|$)|"msg"[[:space:]]*:[[:space:]]*"15"([^a-zA-Z0-9]|$)' || echo "$resp" | grep -qi 'clientip online'; then
            log "login payload accepted ($mode)"
            success=1
            break
        else
            err=$(echo "$resp" | sed -n 's/.*"msga":"\([^"]*\)".*/\1/p')
            [ -z "$err" ] && err=$(echo "$resp" | sed -n 's/.*"msg":"\([^"]*\)".*/\1/p')

            if [ "$LOGIN_SCHEME" != verified ] && echo "$resp" | grep -qE '"msg":(2|"2")([^0-9]|$)'; then
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
                
                # Only the gateway identified by the captive portal is eligible in verified mode.
                [ "$LOGIN_SCHEME" = verified ] && return 3
                # Historical configurations may switch to the alternate portal.
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
            return "$login_state"
        fi
    fi
    return "$state"
}

# SIGUSR1 from the matching netifd event interrupts the current idle wait.
# A monotonic deadline still protects login retries across link events.
wait_for_check() {
    [ "$wakeup" = 1 ] && return 0
    sleep "$1" &
    timer_pid=$!
    if [ "$wakeup" = 1 ]; then kill "$timer_pid" 2>/dev/null || :; fi
    wait "$timer_pid" 2>/dev/null || :
    timer_pid=''
}
monotonic_seconds() { local t unused; read -r t unused </proc/uptime || return 1; printf '%s\n' "${t%%.*}"; }
verified_daemon() {
    local wakeup=0 timer_pid='' delay="$INTERVAL" cooldown=0 next_probe=0 backoff=60 now state paused=0
    trap 'wakeup=1; if [ -n "$timer_pid" ]; then kill "$timer_pid" 2>/dev/null || :; fi' USR1
    trap 'if [ -n "$timer_pid" ]; then kill "$timer_pid" 2>/dev/null || :; fi; exit 0' TERM INT
    log "watching netifd interface $CAMPUS_INTERFACE; fallback interval ${INTERVAL}s"
    while :; do
        wakeup=0
        now=$(monotonic_seconds) || return 1
        if [ "$paused" = 1 ]; then
            delay=3600
        elif [ "$now" -lt "$cooldown" ]; then
            delay=$((cooldown-now))
        elif [ "$now" -lt "$next_probe" ]; then
            delay=$((next_probe-now))
        else
            next_probe=$((now+3))
            check_auth; state=$?
            case "$state" in
                0) backoff=60; delay=$INTERVAL ;;
                1|2|4) delay=$INTERVAL ;;
                5) paused=1; delay=3600 ;;
                *)
                    delay=$backoff
                    now=$(monotonic_seconds) || return 1
                    cooldown=$((now+delay)); backoff=$((backoff*2))
                    [ "$backoff" -le 900 ] || backoff=900
                    log "temporary login failure; next submission in at least ${delay}s" ;;
            esac
        fi
        wait_for_check "$delay"
    done
}

# 3. Execution controller
case "${1:---once}" in
    --daemon)
        if [ "$LOGIN_SCHEME" = verified ]; then verified_daemon; exit $?; fi
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
            4) echo "INCONCLUSIVE"; exit 13 ;;
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
            4) state="INCONCLUSIVE" ;;
            *) state="UNKNOWN" ;;
        esac
        printf '{"state":"%s","gateway":"%s","interface":"%s","ip":"%s","mac":"%s"}\n' \
            "$state" "${TARGET_GW:-none}" "${WAN_DEV:-none}" "${LOCAL_IP:-none}" "${LOCAL_MAC:-none}"
        case "$ret" in 0) exit 0;; 1) exit 10;; 2) exit 11;; 3) exit 12;; 4) exit 13;; *) exit 99;; esac
        ;;
    --once)
        check_auth
        ret=$?
        case "$ret" in
            0) echo "auth success or already online" ;;
            1) echo "network interface not ready" ;;
            2) echo "not in campus network" ;;
            3) echo "login failed" ;;
            4) echo "campus connectivity check inconclusive; no login attempted" ;;
            5) echo "portal rejected this login; check the account or portal in a browser" ;;
            *) echo "unknown state" ;;
        esac
        exit "$ret"
        ;;
    *)
        echo "error: unknown argument '${1}'" >&2
        usage >&2
        exit 2
        ;;
esac
