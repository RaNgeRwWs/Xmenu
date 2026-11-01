#!/bin/sh
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' 0
sed '/^main "\$@"$/d' "$repo/xmenu-v1.0.sh" > "$tmp/library"
. "$tmp/library"
ROOT_DIR="$tmp/data"
BACKUP_DIR="$ROOT_DIR/backups"
XMENU_NFQWS1_CONF="$tmp/nfqws/nfqws.conf"
XMENU_NFQWS1_INIT="$tmp/init/S51nfqws"
XMENU_NFQWS1_FEED="$tmp/opkg/nfqws-keenetic.conf"
calls="$tmp/calls"
require_opkg() { :; }
get_arch() { printf '%s' "$arch"; }
confirm() { [ "$accept" = yes ]; }
invalidate_component_status_cache() { :; }
is_installed() {
    case "$1" in
        nfqws-keenetic) [ "$present" = yes ] ;;
        nfqws2-keenetic) [ "$v2" = yes ] ;;
        tpws-keenetic) [ "$tpws" = yes ] ;;
        *) return 1 ;;
    esac
}
opkg() {
    printf '%s\n' "$*" >> "$calls"
    [ "$*" != "$fail_at" ] || return 1
    case "$*" in
        'install nfqws-keenetic'|'upgrade nfqws-keenetic')
            mkdir -p "$(dirname "$XMENU_NFQWS1_CONF")" "$(dirname "$XMENU_NFQWS1_INIT")"
            [ -f "$XMENU_NFQWS1_CONF" ] || printf 'ISP_INTERFACE="eth3"\n' > "$XMENU_NFQWS1_CONF"
            printf '#!/bin/sh\n[ "$1" = status ] || exit 8\nexit %s\n' "$status_rc" > "$XMENU_NFQWS1_INIT"
            chmod 700 "$XMENU_NFQWS1_INIT"
            ;;
    esac
}
reset_case() {
    accept=yes present=no v2=no tpws=no fail_at=none status_rc=0 arch=aarch64
    : > "$calls"
    rm -f "$XMENU_NFQWS1_CONF" "$XMENU_NFQWS1_INIT" "$XMENU_NFQWS1_FEED"
}
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reset_case
accept=no
install_nfqws1 >/dev/null || fail 'cancel did not return cleanly'
[ ! -s "$calls" ] || fail 'cancel changed packages'
[ ! -e "$XMENU_NFQWS1_FEED" ] || fail 'cancel changed repository'
reset_case
v2=yes
if install_nfqws1 >/dev/null; then fail 'v2 conflict accepted'; fi
[ ! -s "$calls" ] || fail 'v2 conflict changed packages'
reset_case
tpws=yes
if install_nfqws1 >/dev/null; then fail 'tpws conflict accepted'; fi
[ ! -s "$calls" ] || fail 'tpws conflict changed packages'
reset_case
arch=unknown
if install_nfqws1 >/dev/null; then fail 'unknown architecture accepted'; fi
[ ! -s "$calls" ] || fail 'unknown architecture changed packages'
reset_case
fail_at=update
if install_nfqws1 >/dev/null; then fail 'index failure accepted'; fi
! grep -q '^install ' "$calls" || fail 'package installed after failed index'
reset_case
fail_at='install nfqws-keenetic'
if install_nfqws1 >/dev/null; then fail 'package failure accepted'; fi
[ ! -e "$XMENU_NFQWS1_INIT" ] || fail 'service created after package failure'
reset_case
install_nfqws1 > "$tmp/result" || fail 'fresh install failed'
grep -q '^install nfqws-keenetic$' "$calls" || fail 'v1 not installed'
grep -q '\[5/5\]' "$tmp/result" || fail 'stages incomplete'
grep -qx 'src/gz nfqws-keenetic https://nfqws.github.io/nfqws-keenetic/all' "$XMENU_NFQWS1_FEED" || fail 'wrong official feed'
reset_case
present=yes
mkdir -p "$(dirname "$XMENU_NFQWS1_CONF")"
printf 'ISP_INTERFACE="eth9"\n' > "$XMENU_NFQWS1_CONF"
install_nfqws1 >/dev/null || fail 'upgrade failed'
grep -q '^upgrade nfqws-keenetic$' "$calls" || fail 'installed v1 not upgraded'
grep -qx 'ISP_INTERFACE="eth9"' "$XMENU_NFQWS1_CONF" || fail 'existing config rewritten'
find "$BACKUP_DIR" -type f -name 'nfqws.conf.*.bak' | grep -q . || fail 'config backup missing'
reset_case
status_rc=1
if install_nfqws1 >/dev/null; then fail 'inactive service reported working'; fi
reset_case
ln -s "$tmp/protected" "$XMENU_NFQWS1_FEED"
if install_nfqws1 >/dev/null; then fail 'symlink feed accepted'; fi
[ ! -s "$calls" ] || fail 'symlink check happened after package changes'
printf 'PASS: staged NFQWS v1 install, conflicts, cancellation, upgrade and failures\n'
