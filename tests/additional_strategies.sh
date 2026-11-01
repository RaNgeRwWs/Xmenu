#!/bin/sh
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
sed '/^main "\$@"$/d' "$repo/xmenu-v1.0.sh" > "$tmp/library"
. "$tmp/library"
trap 'rm -rf "$tmp"' 0
ROOT_DIR="$tmp/data"
CACHE_DIR="$tmp/cache"
mkdir -p "$ROOT_DIR/manifests" "$CACHE_DIR/nfqws2/additional"
cp "$repo/strategies/nfqws2/SHA256SUMS" "$ROOT_DIR/manifests/SHA256SUMS"
cp "$repo/strategies/nfqws2/SHA256SUMS" "$ROOT_DIR/manifests/SHA256SUMS.xmenu"
printf '0123456789abcdef0123456789abcdef01234567\n' > "$ROOT_DIR/manifests/XMENU_REVISION"
printf 'ISP_INTERFACE="eth9"\nNFQWS_ARGS="--old"\n' > "$tmp/nfqws2.conf"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
sync_strategies() { :; }
active_conf() { printf '%s|%s' "$tmp/nfqws2.conf" "$tmp/blobs"; }
_read_or_eof() { _read_value=$(sed -n '1p' "$tmp/input"); sed '1d' "$tmp/input" > "$tmp/input.new"; mv "$tmp/input.new" "$tmp/input"; }
confirm() { return 1; }
fetch() {
    printf '%s\n' "$1" >> "$tmp/fetches"
    case "$1" in */0123456789abcdef0123456789abcdef01234567/strategies/nfqws2/additional/*.conf) : ;; *) fail 'wrong source or revision' ;; esac
    cp "$repo/strategies/nfqws2/additional/${1##*/}" "$2"
}
strategy_names_from_manifest 2 > "$tmp/main"
strategy_names_from_manifest 2 additional > "$tmp/extra"
[ "$(wc -l < "$tmp/main")" -eq 13 ] || fail 'main catalog changed'
[ "$(wc -l < "$tmp/extra")" -eq 30 ] || fail 'additional catalog count'
! grep -q / "$tmp/main" || fail 'extra entries leaked into main list'
for bad in '../evil.conf' 'additional/../evil.conf' 'additional/nested/a.conf' '/a.conf' 'foo/evil.conf' 'additional/a.conf;echo'; do
    if strategy_valid_name "$bad"; then fail 'unsafe strategy name accepted'; fi
done
strategy_valid_name additional/Configuration-3.2.conf || fail 'valid nested config rejected'
printf '99\n0\n' > "$tmp/input"
strategy_menu > "$tmp/menu" || fail 'additional menu failed'
grep -q '99.*Дополнительные конфигурации' "$tmp/menu" || fail 'submenu missing'
grep -q 'Configuration-3.2' "$tmp/menu" || fail 'config label missing'
if grep -Eq 'additional/|\.conf|31[-_ ]|32[-_ ]' "$tmp/menu"; then fail 'technical prefix or extension shown'; fi
[ ! -e "$tmp/fetches" ] || fail 'menu eagerly downloaded configs'
printf '99\n1\n' > "$tmp/input"
strategy_menu > "$tmp/selected" || fail 'additional selection failed'
[ "$(wc -l < "$tmp/fetches")" -eq 1 ] || fail 'selected config not downloaded once'
[ -s "$CACHE_DIR/nfqws2/additional/Aggressive-Hybrid.conf" ] || fail 'extra cache missing'
grep -q -- '--old' "$tmp/nfqws2.conf" || fail 'cancel changed active config'
SYNC_ALLOW_STRATEGY_UPDATE=1
printf 'additional/Aggressive-Hybrid.conf\n' > "$ROOT_DIR/active-strategy-nfqws2"
update_blobs_for() { :; }
update_lists_for() { :; }
backup_file() { cp "$1" "$1.bak"; }
apply_marked_active_strategy > "$tmp/applied" || fail 'marked apply failed'
grep -q 'ISP_INTERFACE="eth9"' "$tmp/nfqws2.conf" || fail 'interface not preserved'
grep -q -- '--lua-desync' "$tmp/nfqws2.conf" || fail 'nested marked strategy not applied'
[ -s "$tmp/nfqws2.conf.bak" ] || fail 'missing config backup'
printf 'PASS: additional configs, labels, lazy download, revision, cancellation and marked apply\n'
