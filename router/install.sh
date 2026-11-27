#!/bin/sh
# Run from a root SSH terminal on OpenWrt after extracting the local package.
set +x
set +a
set -eu
umask 077

die() { printf 'Installation failed: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 0 ] || die 'Run sh install.sh without arguments.'
[ "$(id -u)" = 0 ] || die 'Run as root on the router.'

package=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
program=/usr/bin/bistu_auth.sh
service=/etc/init.d/bistu-auth
config=/etc/bistu_auth.conf
for cmd in awk cat chmod cmp cp curl cut date dirname flock grep head id ip jsonfilter ln logger ls md5sum mktemp mv rm rmdir sed sh sleep tr ubus uci; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"
done
[ -x /etc/rc.common ] && [ -r /lib/functions/procd.sh ] || die 'OpenWrt procd is required.'
ubus -t 5 list service | grep -qx service || die 'The local procd service is unavailable.'
for file in bistu_auth.sh bistu-auth bistu_auth.conf; do
    [ -r "$package/$file" ] && sh -n "$package/$file" 2>/dev/null || die "Missing or invalid package file: $file"
done

# The directory descriptor provides a local kernel lock, released even on exit.
exec 9</etc/init.d
flock -n 9 || die 'Another installer holds the service directory lock. Retry later.'
for file in "$program" "$service" "$config"; do
    [ ! -L "$file" ] && { [ ! -e "$file" ] || [ -f "$file" ]; } || die "Expected a regular file: $file"
done

bin_stage='' init_stage='' conf_stage=''
replace_program=0 replace_service=0 touched_enable=0 touched_run=0
was_enabled=0 was_running=0

restore_file() {
    if [ -f "$1/old" ]; then mv -f "$1/old" "$2"; else rm -f "$2"; fi
}
clean_stage() {
    [ -n "$1" ] || return 0
    rm -f "$1/new" "$1/old" && rmdir "$1"
}
on_exit() {
    result=$?
    trap - EXIT
    trap '' HUP INT TERM
    set +e
    recovery=0
    if [ "$result" -ne 0 ]; then
        if [ "$touched_run" = 1 ]; then "$service" stop >/dev/null 2>&1 || recovery=1; fi
        if [ "$touched_enable" = 1 ]; then "$service" disable >/dev/null 2>&1 || recovery=1; fi
        if [ "$replace_program" = 1 ]; then restore_file "$bin_stage" "$program" || recovery=1; fi
        if [ "$replace_service" = 1 ]; then restore_file "$init_stage" "$service" || recovery=1; fi
        if [ -n "$conf_stage" ] && [ "$conf_stage/new" -ef "$config" ]; then rm -f "$config" || recovery=1; fi
        if [ "$touched_enable" = 1 ] && [ "$was_enabled" = 1 ]; then "$service" enable || recovery=1; fi
        if [ "$touched_run" = 1 ] && [ "$was_running" = 1 ]; then "$service" start || recovery=1; fi
    fi
    if [ "$recovery" -eq 0 ]; then
        clean_stage "$bin_stage"
        clean_stage "$init_stage"
        clean_stage "$conf_stage"
    else
        printf 'Rollback needs attention. Staging directories: %s %s %s\n' "$bin_stage" "$init_stage" "$conf_stage" >&2
    fi
    exit "$result"
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Pass each credential to sed on standard input. The result is one quoted
# shell assignment, including literal spaces, backslashes and single quotes.
write_assignment() {
    sed -e "s/'/'\\\\''/g" -e "s/^/$1='/" -e "s/\$/'/" <<EOF
$2
EOF
}
owner_mode() { LC_ALL=C ls -ldn "$1" | awk '{print $3 ":" $1}'; }
if [ -f "$config" ]; then
    case $(owner_mode "$config") in
        0:-r--------|0:-rw-------) ;;
        *) die "Review $config ownership and permissions. A root-owned mode 600 or 400 file is required." ;;
    esac
    sh -n "$config" 2>/dev/null || die "Check the shell syntax in $config."
    printf 'Keeping existing %s, including its login scheme and credentials.\n' "$config"
else
    [ -t 0 ] || die 'First installation needs an interactive SSH terminal for credential entry.'
    conf_stage=$(mktemp -d "${config%/*}/.bistu-auth.XXXXXX")
    unset input_user input_pass
    printf 'Campus username (hidden): ' >&2
    IFS= read -r -s input_user </dev/tty && [ -n "$input_user" ] || die 'A username is required.'
    printf '\nCampus password (hidden): ' >&2
    IFS= read -r -s input_pass </dev/tty && [ -n "$input_pass" ] || die 'A password is required.'
    printf '\n' >&2
    {
        sed '/^BISTU_USER=/d; /^BISTU_PASS=/d; /^LOGIN_SCHEME=/d' "$package/bistu_auth.conf"
        printf '\nLOGIN_SCHEME=verified\n'
        write_assignment BISTU_USER "$input_user"
        write_assignment BISTU_PASS "$input_pass"
    } >"$conf_stage/new"
    unset input_user input_pass
    chmod 600 "$conf_stage/new"
    sh -n "$conf_stage/new" 2>/dev/null || die 'Failed to prepare the new configuration.'
fi

needs_update() {
    [ -f "$2" ] && [ "$(owner_mode "$2")" = 0:-rwxr-xr-x ] && cmp -s "$1" "$2" && return 1
    return 0
}
stage_file() {
    [ ! -f "$2" ] || cp -p "$2" "$3/old"
    cp "$1" "$3/new"
    chmod 755 "$3/new"
}
if needs_update "$package/bistu_auth.sh" "$program"; then
    bin_stage=$(mktemp -d "${program%/*}/.bistu-auth.XXXXXX")
    stage_file "$package/bistu_auth.sh" "$program" "$bin_stage"
fi
if needs_update "$package/bistu-auth" "$service"; then
    init_stage=$(mktemp -d "${service%/*}/.bistu-auth.XXXXXX")
    stage_file "$package/bistu-auth" "$service" "$init_stage"
fi
if [ -x "$service" ]; then
    "$service" enabled >/dev/null 2>&1 && was_enabled=1
    "$service" running >/dev/null 2>&1 && was_running=1
fi

if [ -n "$conf_stage" ]; then
    # An atomic hard link cannot replace a config created by another process.
    ln "$conf_stage/new" "$config" || die "Could not create $config."
fi
if [ -n "$bin_stage" ]; then
    replace_program=1
    mv -f "$bin_stage/new" "$program"
fi
if [ -n "$init_stage" ]; then
    replace_service=1
    mv -f "$init_stage/new" "$service"
fi
if [ "$was_enabled" = 0 ] || [ "$replace_service" = 1 ]; then
    touched_enable=1
    "$service" enable && "$service" enabled || die 'procd could not enable the service.'
fi
if [ "$was_running" = 0 ]; then
    touched_run=1
    "$service" start || die 'procd could not start the service.'
elif [ "$replace_program" = 1 ] || [ "$replace_service" = 1 ] || [ -n "$conf_stage" ]; then
    touched_run=1
    "$service" restart || die 'procd could not restart the updated service.'
fi
for delay in 0 1 2 3; do
    "$service" running >/dev/null 2>&1 && break
    [ "$delay" -lt 3 ] || die 'procd did not report a running service.'
    sleep 1
done
printf 'bistu-auth is enabled and running. Check network status with bistu_auth.sh --status.\n'
