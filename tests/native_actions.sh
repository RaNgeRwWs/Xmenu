#!/bin/sh
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
sed '/^main "\$@"$/d' "$repo/xmenu-v1.0.sh" > "$tmp/library.sh"
. "$tmp/library.sh"
trap 'rm -rf "$tmp"' 0
ROOT_DIR="$tmp/data"
BACKUP_DIR="$ROOT_DIR/backups"
mkdir -p "$BACKUP_DIR" "$tmp/blobs"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cat > "$tmp/source.conf" <<'EOF'
NFQWS_BASE_ARGS="--blob=tls.test:@/opt/old.bin --blob=tlsXtest:@/opt/keep.bin"
NFQWS_ARGS="--lua-desync=fake:blob=tls.test:repeats=2 --lua-desync=fake:blob=0x0000"
NFQWS_ARGS_UDP="--lua-desync=fake:blob=tls.test:repeats=3"
EOF
xmenu_parse_fake_blobs "$tmp/source.conf" "$tmp/map" "$tmp/list" || fail 'named fake blob not detected'
test "$(wc -l < "$tmp/list" | tr -d ' ')" = 1 || fail 'fake blob aliases were not deduplicated or hex was included'
grep -Fq '1|NFQWS_ARGS|tls.test|old.bin' "$tmp/list" || fail 'fake blob mapping or section lost'
xmenu_fake_blob_rewrite "$tmp/source.conf" tls.test /opt/new.bin "$tmp/new.conf"
grep -Fq -- '--blob=tls.test:@/opt/new.bin --blob=tlsXtest:@/opt/keep.bin' "$tmp/new.conf" || fail 'blob edit matched another alias'
sh -n "$tmp/new.conf" || fail 'edited configuration is invalid'
xmenu_fake_blob_rewrite "$tmp/source.conf" missing /opt/new.bin "$tmp/added.conf"
grep -Fq 'NFQWS_BASE_ARGS="${NFQWS_BASE_ARGS:-} --blob=missing:@/opt/new.bin"' "$tmp/added.conf" || fail 'missing blob declaration not appended'
XMENU_NFQWS1_CONF="$tmp/absent.conf"
XMENU_NFQWS2_CONF="$tmp/active.conf"
XMENU_NFQWS2_BLOBS="$tmp/blobs"
cp "$tmp/source.conf" "$XMENU_NFQWS2_CONF"
printf 'blob fixture\n' > "$tmp/blobs/new.bin"
fetch() { return 1; }
acquire_lock() { return 0; }
release_operation_lock() { :; }
confirm_yes() { return 1; }
answers='1 1'
_read_or_eof() { _read_value=${answers%% *}; answers=${answers#* }; return 0; }
xmenu_fake_blob_menu > "$tmp/blob-output" || fail 'native fake blob menu failed'
grep -Fq -- "--blob=tls.test:@$tmp/blobs/new.bin" "$XMENU_NFQWS2_CONF" || fail 'native fake blob selection was not applied'
find "$BACKUP_DIR" -name 'active.conf.*.bak' | grep -q . || fail 'fake blob edit had no backup'
cat > "$tmp/hosts" <<'EOF'
# First section with spaces
203.0.113.1 example.net
203.0.113.2 example.net
999.1.2.3 invalid.example
2001:db8::1 ipv6.example
203.0.113.3 .invalid.example
203.0.113.3 invalid..example
203.0.113.3 bad;command.example
# Second section
198.51.100.1 second.example
EOF
xmenu_hosts_parse "$tmp/hosts" 1 > "$tmp/pairs"
test "$(wc -l < "$tmp/pairs" | tr -d ' ')" = 1 || fail 'host validation or duplicate handling failed'
grep -q '203.0.113.2.*example.net' "$tmp/pairs" || fail 'last address for domain was not selected'
xmenu_hosts_parse "$tmp/hosts" '1,2' > "$tmp/all-pairs"
test "$(wc -l < "$tmp/all-pairs" | tr -d ' ')" = 2 || fail 'selection of multiple named sections failed'
ndmc() { :; }
fetch() { cp "$tmp/hosts" "$2"; }
xmenu_dns_ndmc() {
    case "$1" in
        'show running-config') printf 'ip host previous.example 192.0.2.1\n' ;;
        *) printf '%s\n' "$1" >> "$tmp/commands" ;;
    esac
}
confirm_yes() { return 0; }
answers='1,2 0'
xmenu_hosts_menu > "$tmp/hosts-output" || fail 'native hosts menu failed'
grep -q '^ip host example.net 203.0.113.2$' "$tmp/commands" || fail 'host commands used wrong address or domain'
grep -q '^ip host second.example 198.51.100.1$' "$tmp/commands" || fail 'multi-section hosts edit lost a section'
grep -q '^system configuration save$' "$tmp/commands" || fail 'hosts changes were not saved'
find "$BACKUP_DIR" -name 'hosts-ip-host.*.bak' | grep -q . || fail 'hosts changes had no backup'
confirm_no() { return 1; }
cp "$tmp/commands" "$tmp/commands-before"
answers='88 0'
xmenu_hosts_menu >/dev/null || fail 'declining hosts deletion returned an error'
cmp "$tmp/commands" "$tmp/commands-before" || fail 'declining hosts deletion changed router commands'
if grep -q 'nfqws-menu.sh' "$repo/xmenu-v1.0.sh"; then fail 'obsolete menu download remains'; fi
printf 'PASS: native blob and hosts actions\n'
