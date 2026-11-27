#!/usr/bin/env bash
# No external I/O. Run the actual verified daemon with only its config path and
# monotonic clock file redirected to this fixture. All network tools are fakes.
set -eu
export PATH=/usr/bin:/bin
here=$(cd "$(dirname "$0")" && pwd)
src="$here/../bistu_auth.sh"
MOCK=$(mktemp -d "$here/verified-case.XXXXXX")
export MOCK
case "$MOCK" in "$here"/verified-case.??????) ;; *) exit 2;; esac
pid=''
stop_daemon() {
    if [ -n "$pid" ]; then
        kill -TERM "$pid" 2>/dev/null || :
        wait "$pid" || :
        pid=''
    fi
}
cleanup() {
    stop_daemon
    rm -rf -- "$MOCK"
}
trap cleanup EXIT
fail() {
    echo "FAIL $*" >&2
    tail -n 25 "$MOCK"/daemon.log "$MOCK"/calls "$MOCK"/waits 2>/dev/null >&2 || :
    exit 1
}
pass() { echo "PASS $*"; }
mkdir "$MOCK/bin"
cd "$MOCK"
sed -e 's|/etc/bistu_auth.conf|$MOCK/conf|g' -e 's|</proc/uptime|<"$MOCK/uptime"|g' "$src" >daemon
grep -q 'CONFIG_FILE=.*MOCK.*/conf' daemon || fail 'config fixture substitution missing'
grep -q 'read .*MOCK/uptime' daemon || fail 'clock fixture substitution missing'
cat >conf <<'CONF'
BISTU_USER=offline_fixture
BISTU_PASS=synthetic_offline_password
LOGIN_SCHEME=verified
CAMPUS_INTERFACE=campus_wired
TEST_URL=http://canary.invalid/status
CONF
chmod 600 conf
cat >bin/ls <<'STUB'
#!/bin/sh
case "$1:$2" in
    -ldn:"$MOCK/conf"|-ld:"$MOCK/conf") echo '-rw------- 1 0 0 123 Jan 1 00:00 fixture';;
    *) exec /usr/bin/ls "$@";;
esac
STUB
cat >bin/ubus <<'STUB'
#!/bin/sh
echo "netifd $*" >>"$MOCK/calls"
[ "$*" = '-t 4 call network.interface.campus_wired status' ] || exit 70
case "$(cat "$MOCK/net")" in
    down) printf '%s\n' '{"up":false,"l3_device":"campus0.20","ipv4-address":[{"address":"192.0.2.40"}]}' ;;
    up) printf '%s\n' '{"up":true,"l3_device":"campus0.20","ipv4-address":[{"address":"192.0.2.40"}]}' ;;
    noaddr) printf '%s\n' '{"up":true,"l3_device":"campus0.20","ipv4-address":[]}' ;;
    missing) exit 4 ;;
esac
STUB
cat >bin/jsonfilter <<'STUB'
#!/bin/sh
if [ "$1" = '-e' ]; then
    doc=$(cat)
    case "$doc:$2" in
        '{"result":1}':@.result) printf '1\n';;
        '{"result":0,"msg":"2"}':@.result) printf '0\n';;
        '{"result":0,"msg":"2"}':@.msg) printf '2\n';;
        *) exit 1;;
    esac
    exit 0
fi
[ "$1" = '-s' ] && [ "$3" = '-e' ] || exit 70
case "$4" in
    '@.up') printf '%s' "$2" | sed -n 's/.*"up":\([a-z]*\).*/\1/p' ;;
    '@.l3_device') printf '%s' "$2" | sed -n 's/.*"l3_device":"\([^"]*\)".*/\1/p' ;;
    '@["ipv4-address"][0].address') printf '%s' "$2" | sed -n 's/.*"address":"\([^"]*\)".*/\1/p' ;;
    *) exit 70 ;;
esac
STUB
cat >bin/ip <<'STUB'
#!/bin/sh
echo "ip $*" >>"$MOCK/calls"
if [ "$*" = 'link show dev campus0.20' ]; then
    echo 'link/ether 02:00:00:00:01:20'
else
    echo 'unexpected route or interface selection' >>"$MOCK/violation"
    exit 70
fi
STUB
cat >bin/curl <<'STUB'
#!/bin/sh
scope='' interface='' host='' resolve='' proto='' scope_value='' previous=''
login=0; userfield=0; macfield=0; insecure=0; ipv4=0; http_fail=0
for arg in "$@"; do
    case "$previous" in
        --noproxy) scope_value="$arg";;
        --interface) interface="$arg";;
        --resolve) resolve="$arg";;
        --proto) proto="$arg";;
    esac
    case "$arg" in
        https://*/drcom/login) host="$arg"; login=1;;
        http://canary.invalid/status) scope=probe;;
        v4ip=192.0.2.40) userfield=1;;
        mac=020000000120) macfield=1;;
        -k|--insecure) insecure=1;;
        -4) ipv4=1;;
        --fail) http_fail=1;;
    esac
    previous="$arg"
done
check() { if ! "$@"; then echo 'unexpected curl options' >>"$MOCK/violation"; exit 70; fi; }
check test "$scope_value" = '*'
check test "$interface:$ipv4" = 'if!campus0.20:1'
if [ "$login" = 1 ]; then
    check test "$http_fail" = 1
    check test "$userfield:$macfield:$insecure:$proto" = '1:1:0:=https'
    case "$host:$resolve" in
        https://lan.bistu.edu.cn/drcom/login:lan.bistu.edu.cn:443:10.144.0.3) ;;
        https://wlan.bistu.edu.cn/drcom/login:wlan.bistu.edu.cn:443:10.144.49.2) ;;
        *) echo 'wrong portal/resolve' >>"$MOCK/violation"; exit 70;;
    esac
    cat >/dev/null
    printf 'login %s %s\n' "$host" "$(cat "$MOCK/uptime")" >>"$MOCK/calls"
    case "$(cat "$MOCK/reply")" in
        accept) echo online204 >"$MOCK/page"; echo 'dr1001({"result":1})';;
        deny) echo 'dr1001({"result":0,"msg":"2"})';;
        transport) exit 28;;
        unknown) echo 'service temporarily unavailable';;
    esac
    exit 0
fi
check test "$scope" = probe
page=$(cat "$MOCK/page")
echo "probe $page $interface" >>"$MOCK/calls"
case "$page" in
    online204) printf 'HTTP/1.1 204 No Content\r\n\r\n';;
    apple) printf 'HTTP/1.1 200 OK\r\nHeader: ok\r\n\r\n<HTML><BODY>Success</BODY></HTML>\n';;
    plain) printf 'HTTP/1.1 200 OK\r\n\r\nsuccess\n';;
    unknown200) printf 'HTTP/1.1 200 OK\r\nX-State: Success\r\n\r\nUnrelated page\n';;
    timeout) exit 28;;
    unavailable) printf 'HTTP/1.1 503 Unavailable\r\n\r\n';;
    foreign) printf 'HTTP/1.1 302 Found\r\nLocation: https://guest.invalid/login\r\n\r\n';;
    lan) printf 'HTTP/1.1 302 Found\r\nLocation: http://lan.bistu.edu.cn/\r\n\r\n';;
    wlan) printf 'HTTP/1.1 307 Redirect\r\nLocation: http://10.144.49.2/\r\n\r\n';;
    *) exit 70;;
esac
STUB
cat >bin/sleep <<'STUB'
#!/bin/sh
if [ "$1" = 6 ]; then exit 0; fi
printf '%s\n' "$1" >>"$MOCK/waits"
exec /bin/sleep 40
STUB
printf '#!/bin/sh\nexit 0\n' >bin/logger
chmod +x bin/*
export PATH="$MOCK/bin:/usr/bin:/bin"
echo up >net
echo 100.00 >uptime
echo accept >reply
: >calls
: >waits
count() { grep -c "^$1" calls || :; }
verify() { [ ! -f violation ] || fail "$(cat violation)"; }
run_once() {
    local expected=$1 flag=$2 actual=0
    /bin/sh ./daemon "$flag" >last.out 2>last.err || actual=$?
    [ "$actual" = "$expected" ] || fail "$flag expected=$expected actual=$actual $(cat last.out last.err)"
    verify
}
for row in 'online204 0 ONLINE' 'apple 0 ONLINE' 'plain 0 ONLINE' 'unknown200 13 INCONCLUSIVE' 'timeout 13 INCONCLUSIVE' 'unavailable 13 INCONCLUSIVE' 'foreign 11 NOT_CAMPUS' 'lan 12 NEED_LOGIN'; do
    read -r mode expected state <<<"$row"
    echo "$mode" >page
    : >calls
    run_once "$expected" --status-json
    grep -q "\"state\":\"$state\"" last.out || fail "$mode returned wrong status"
    [ "$(count probe)" = 1 ] && [ "$(count login)" = 0 ] || fail "$mode was not a single read-only check"
done
pass '204, Apple and plain success recognized; unfamiliar 200, timeout, 503, foreign redirect and campus redirect classified without credentials'
for state in down noaddr missing; do
    echo "$state" >net
    : >calls
    run_once 1 --once
    [ "$(count probe):$(count login)" = '0:0' ] || fail "$state queried a network"
done
pass 'campus netifd down, missing IPv4 or unavailable interface never uses F50/default route'
echo up >net
for mode in lan wlan; do
    echo "$mode" >page
    : >calls
    run_once 0 --once
    [ "$(count login):$(count probe)" = '1:2' ] || fail "$mode login or post-login validation"
done
pass 'validated campus redirections use matching TLS host/IP, campus L3 device, IP and MAC; success requires independent post-login check'
for row in 'foreign 2' 'unknown200 4' 'timeout 4'; do
    read -r mode expected <<<"$row"; echo "$mode" >page; : >calls
    run_once "$expected" --once
    [ "$(count login)" = 0 ] || fail "$mode submitted a login"
done
pass 'foreign portal, uncertain page and offline timeout never submit credentials on --once'
start_daemon() {
    echo 100.00 >uptime; echo lan >page; echo "$1" >reply
    : >calls; : >waits
    /bin/sh ./daemon --daemon >daemon.log 2>&1 &
    pid=$!
}
await_wait() {
    local index=$1 expected=$2 got
    for ((i=0;i<100;i++)); do
        got=$(sed -n "${index}p" waits)
        if [ -n "$got" ]; then
            [ "$got" = "$expected" ] || fail "wait $index expected=$expected got=$got"
            verify
            return 0
        fi
        kill -0 "$pid" 2>/dev/null || fail 'daemon stopped early'
        /bin/sleep 0.04
    done
    fail "waiting for deadline $index timed out"
}
wake() { echo "$1.00" >uptime; kill -USR1 "$pid"; }
start_daemon deny
await_wait 1 3600
wake 135; await_wait 2 3600
wake 7400; await_wait 3 3600
[ "$(count login)" = 1 ] || fail 'rejected login repeated'
stop_daemon
pass 'one explicit denial blocks all submissions after repeated real SIGUSR1 and an elapsed hour'
start_daemon transport
await_wait 1 60
wake 120; await_wait 2 40
wake 159; await_wait 3 1
[ "$(count login)" = 1 ] || fail 'event skipped first cooldown'
wake 160; await_wait 4 120
wake 270; await_wait 5 10
[ "$(count login)" = 2 ] || fail 'event skipped second cooldown'
wake 280; await_wait 6 240
wake 520; await_wait 7 480
wake 1000; await_wait 8 900
wake 1900; await_wait 9 900
[ "$(count login)" = 6 ] || fail 'expected six transient attempts'
echo accept >reply
wake 2800; await_wait 10 180
[ "$(count login):$(count probe)" = '7:8' ] || fail 'recovery did not verify connection'
wake 2801; await_wait 11 2
wake 2802; await_wait 12 1
[ "$(count probe)" = 8 ] || fail 'multiple events in debounce window caused duplicate checks'
wake 2803; await_wait 13 180
[ "$(count login):$(count probe)" = '7:9' ] || fail 'a wake after debounce failed to check once'
stop_daemon
pass 'real events cannot skip monotonic 60,120,240,480,900-second cooldowns; 900-second cap and recovery verified'
pass 'two real USR1 events inside 3 seconds coalesce; next eligible event performs one read-only check'
verify
