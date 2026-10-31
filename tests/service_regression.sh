#!/bin/sh
# Service actions use temporary files and mock firewall/package commands.
set -eu
test_dir=$(mktemp -d)
source_file=$(cd "$(dirname "$0")/.." && pwd)/xmenu-v1.0.sh
sed '/^main "\$@"$/d' "$source_file" > "$test_dir/library.sh"
# shellcheck disable=SC1090
. "$test_dir/library.sh"
trap 'rm -rf "$test_dir"' 0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

XMENU_DISCORD_DIR="$test_dir/discord"
XMENU_DISCORD_CONF="$XMENU_DISCORD_DIR/fullsession.conf"
XMENU_DISCORD_INIT="$test_dir/init/S52xmenu-discord-fullsession"
XMENU_DISCORD_HOOK="$test_dir/hook/101-xmenu-discord-fullsession.sh"
XMENU_NFQWS2_INIT="$test_dir/init/S51nfqws2"
XMENU_NFQWS2_CONF="$test_dir/nfqws2/nfqws2.conf"
XMENU_XKEEN_EXCLUDE="$test_dir/xkeen/port_exclude.lst"
XMENU_DROPBEAR_CONF="$test_dir/dropbear/dropbear.conf"
XMENU_DROPBEAR_INIT="$test_dir/dropbear/S51dropbear"
XMENU_DROPBEAR_LOG="$test_dir/dropbear/restart.log"
XMENU_OPTBIN="$test_dir/opt/bin"
XMENU_OPTSBIN="$test_dir/opt/sbin"
XMENU_TEST_LOG="$test_dir/commands.log"
export XMENU_TEST_LOG
mkdir -p "$(dirname "$XMENU_NFQWS2_CONF")" "$(dirname "$XMENU_NFQWS2_INIT")" "$test_dir/bin"
printf 'ISP_INTERFACE="eth3"\nNFQUEUE_NUM="300"\n' > "$XMENU_NFQWS2_CONF"
printf 'NFQUEUE_NUM="301"\n' > "$XMENU_NFQWS2_CONF.run"
printf '#!/bin/sh\nexit 0\n' > "$XMENU_NFQWS2_INIT"
printf '#!/bin/sh\nprintf "iptables %%s\\n" "$*" >> "$XMENU_TEST_LOG"\ncase "$*" in *" -C "*) exit 1;; esac\nexit 0\n' > "$test_dir/bin/iptables"
printf '#!/bin/sh\nprintf "upx %%s\\n" "$*" >> "$XMENU_TEST_LOG"\n' > "$test_dir/bin/upx"
printf '#!/bin/sh\nprintf "opkg %%s\\n" "$*" >> "$XMENU_TEST_LOG"\n' > "$test_dir/bin/opkg"
chmod +x "$test_dir/bin/iptables" "$test_dir/bin/upx" "$test_dir/bin/opkg"
PATH="$test_dir/bin:$PATH"
export PATH
is_installed() { [ "$1" = nfqws2-keenetic ]; }
confirm() { return 0; }
pause() { :; }
say() { printf '%s\n' "$*"; }

xmenu_discord_enable > "$test_dir/enable.txt" || fail 'Discord enable failed'
test -s "$XMENU_DISCORD_CONF" || fail 'Discord settings were not persisted'
grep -q '^PORTS=19294:19344,50000:50100$' "$XMENU_DISCORD_CONF" || fail 'unexpected Discord ports'
test -x "$XMENU_DISCORD_INIT" || fail 'Discord boot init was not installed'
test -x "$XMENU_DISCORD_HOOK" || fail 'Discord firewall hook was not installed'
grep -q 'xmenu_discord' "$XMENU_TEST_LOG" || fail 'firewall rules did not use Xmenu-owned chains'
grep -q 'NFQUEUE --queue-num 301' "$XMENU_TEST_LOG" || fail 'Discord packets did not use the effective nfqws2 queue from .run'
grep -q ' -j PPE' "$XMENU_TEST_LOG" || fail 'PPE fastpath bypass rules were not added'

xmenu_discord_enable >/dev/null || fail 'repeated Discord enable failed'
printf 'POLICY_MARK="0x100/0xff00"\nPOLICY_EXCLUDE="1"\n' >> "$XMENU_NFQWS2_CONF.run"
: > "$XMENU_TEST_LOG"
xmenu_discord_rules_apply >/dev/null || fail 'Discord policy exclusion failed'
grep -q -- '-m mark --mark 0x100/0xff00 -j RETURN' "$XMENU_TEST_LOG" || fail 'excluded policy traffic was not returned before NFQUEUE'
if grep -q -- '-m mark ! --mark 0x100/0xff00 -j RETURN' "$XMENU_TEST_LOG"; then fail 'excluded Discord policy was inverted'; fi
xmenu_discord_disable > "$test_dir/disable.txt" || fail 'Discord disable failed'
test ! -e "$XMENU_DISCORD_CONF" || fail 'Discord state remained after disable'
test ! -e "$XMENU_DISCORD_INIT" || fail 'Discord init remained after disable'
test ! -e "$XMENU_DISCORD_HOOK" || fail 'Discord hook remained after disable'
if grep 'iptables .* -D ' "$XMENU_TEST_LOG" | grep -v 'xmenu_discord'; then fail 'disable touched a non-Xmenu firewall chain'; fi

mkdir -p "$test_dir/dropbear" "$XMENU_OPTBIN" "$XMENU_OPTSBIN"
printf 'PORT=22\n' > "$XMENU_DROPBEAR_CONF"
printf 'PIDFILE="/opt/var/run/dropbear.pid"\n' > "$XMENU_DROPBEAR_INIT"
printf 'root:oldhash:0:0:root:/root:/bin/sh\n' > "$test_dir/dropbear/passwd"
passwd_file="$test_dir/dropbear/passwd"
xmenu_dropbear_patch_files "$XMENU_DROPBEAR_CONF" "$XMENU_DROPBEAR_INIT" "$passwd_file" 0 || fail 'Dropbear patch failed'
grep -q '^PORT=222$' "$XMENU_DROPBEAR_CONF" || fail 'Dropbear port was not changed to 222'
grep -q 'PIDFILE="/var/run/dropbear.pid"' "$XMENU_DROPBEAR_INIT" || fail 'Dropbear pidfile was not moved to /var/run'
grep -q '^root:oldhash:' "$passwd_file" || fail 'default Dropbear fix changed the root password'
printf 'PORT=22\n' > "$XMENU_DROPBEAR_CONF"
printf 'PIDFILE="/opt/var/run/dropbear.pid"\n' > "$XMENU_DROPBEAR_INIT"
xmenu_dropbear_patch_files "$XMENU_DROPBEAR_CONF" "$XMENU_DROPBEAR_INIT" "$passwd_file" 1 || fail 'Dropbear password reset option failed'
grep -Fq 'root:$1$6vKOV7zs$d2EqNYGvlBWEYoFD7FFkr0:' "$passwd_file" || fail 'explicit Dropbear reset did not set requested password hash'
backup_count=$(find "$test_dir/dropbear" -name 'passwd.xmenu.*.bak' | wc -l | tr -d ' ')
test "$backup_count" -ge 1 || fail 'Dropbear password reset did not preserve the original password file'

printf '#!/bin/sh\nprintf "upx %%s\\n" "$*" >> "$XMENU_TEST_LOG"\n' > "$test_dir/bin/upx"
chmod +x "$test_dir/bin/upx"
printf '#!/bin/sh\nexit 0\n' > "$XMENU_OPTBIN/fixture"
printf '#!/bin/sh\nexit 0\n' > "$XMENU_OPTSBIN/fixture"
chmod +x "$XMENU_OPTBIN/fixture" "$XMENU_OPTSBIN/fixture"
confirm() { return 0; }
xmenu_compress_binsbin >/dev/null || fail 'UPX compression action failed'
grep -q "upx --lzma --best $XMENU_OPTBIN/fixture" "$XMENU_TEST_LOG" || fail 'UPX did not process /opt/bin fixture'
grep -q "upx --lzma --best $XMENU_OPTSBIN/fixture" "$XMENU_TEST_LOG" || fail 'UPX did not process /opt/sbin fixture'

printf 'PASS: service action regression scenarios\n'
