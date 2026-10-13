#!/bin/sh
# Регрессии запускаются с временными конфигами и имитацией сетевых ответов.
set -eu
test_dir=$(mktemp -d)
test_path=$PATH
source_file=$(cd "$(dirname "$0")/.." && pwd)/xmenu-v1.0.sh
sed '/^main "\$@"$/d' "$source_file" |
    sed "s#/opt/etc/opkg.conf#$test_dir/opkg.conf#g; s#/opt/etc/.opkg.conf#$test_dir/.opkg.conf#g; s#/opt/etc/xkeen-menu#$test_dir/legacy#g" > "$test_dir/library.sh"
# shellcheck disable=SC1090
. "$test_dir/library.sh"
PATH=$test_path
export PATH
trap 'rm -rf "$test_dir"' 0
ROOT_DIR="$test_dir/data"
BACKUP_DIR="$ROOT_DIR/backups"
LANG_FILE="$ROOT_DIR/language"
LOCK_DIR="$test_dir/operation.lock"
MENU_SESSION_LOCK_DIR="$test_dir/menu.lock"
XMENU_COMPONENT_REFRESH_LOCK="$ROOT_DIR/component.lock"
XMENU_UPDATE_LOCK="$ROOT_DIR/update.lock"
XMENU_OPKG_MIRRORS_FILE="$ROOT_DIR/mirrors.conf"
RESET=''; ACTIVE=''; GREEN=''; YELLOW=''; RED=''; WHITE=''; PURPLE=''; MUTED=''
mkdir -p "$BACKUP_DIR" "$test_dir/legacy/backups" "$test_dir/bin"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Импорт не должен повторно создавать удалённые пользователем бэкапы.
printf 'backup\n' > "$test_dir/legacy/backups/archive.tar.gz"
migrate_legacy_xmenu_data || fail migration
test -f "$BACKUP_DIR/archive.tar.gz" || fail 'backup not migrated'
rm "$BACKUP_DIR/archive.tar.gz"
migrate_legacy_xmenu_data || fail 'second migration'
test ! -e "$BACKUP_DIR/archive.tar.gz" || fail 'deleted backup resurrected'

# При закрытии одной сессии временные файлы другой должны сохраниться.
mkdir "$ROOT_DIR/blobwork.$$" "$ROOT_DIR/blobwork.99999999"
printf 'own\n' > "$ROOT_DIR/apply-$$.conf"
printf 'other\n' > "$ROOT_DIR/apply-99999999.conf"
cleanup final
test ! -e "$ROOT_DIR/blobwork.$$" || fail 'own work not cleaned'
test -d "$ROOT_DIR/blobwork.99999999" || fail 'another session work removed'
test -f "$ROOT_DIR/apply-99999999.conf" || fail 'another session config removed'

# Обрыв ввода не является согласием на запуск установщика.
if confirm_yes 'Install?' </dev/null; then fail 'EOF accepted as yes'; fi
printf '\n' | confirm_yes 'Install?' || fail 'Enter default changed'

acquire_lock || fail 'operation lock acquisition'
if acquire_lock; then fail 'live operation lock bypassed'; fi
cleanup
mkdir "$LOCK_DIR"
acquire_lock || fail 'empty stale lock not recovered'
cleanup

printf 'Package: test\nVersion: 1.0\nArchitecture: all\n\n' | gzip -c > "$test_dir/packages.gz"
printf '<html>blocked</html>\n' | gzip -c > "$test_dir/blocked.gz"
xmenu_opkg_is_packages_index "$test_dir/packages.gz" || fail 'valid package index rejected'
if xmenu_opkg_is_packages_index "$test_dir/blocked.gz"; then fail 'compressed block page accepted'; fi
head -c 8 "$test_dir/packages.gz" > "$test_dir/truncated.gz"
if xmenu_opkg_is_packages_index "$test_dir/truncated.gz"; then fail 'truncated gzip accepted'; fi

export XMENU_TEST_DIR="$test_dir"
cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
out=''
while [ "$#" -gt 0 ]; do
    case "$1" in -o) out=$2; shift 2 ;; *) url=$1; shift ;; esac
done
case "$url" in
    *blocked.test*) cp "$XMENU_TEST_DIR/blocked.gz" "$out"; printf '200|0.001' ;;
    *good.test*) cp "$XMENU_TEST_DIR/packages.gz" "$out"; printf '200|0.040' ;;
    *fallback.test*) printf '000|0.001'; exit 60 ;;
    *) printf '403|0.001'; exit 22 ;;
esac
EOF
cat > "$test_dir/bin/wget" <<'EOF'
#!/bin/sh
out=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help) printf 'wget -T SEC -O FILE URL\n'; exit 0 ;;
        -t) exit 2 ;; # Имитируем урезанную сборку BusyBox без --tries.
        -O) out=$2; shift 2 ;;
        *) url=$1; shift ;;
    esac
done
case "$url" in
    *fallback.test*) cp "$XMENU_TEST_DIR/packages.gz" "$out" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$test_dir/bin/curl" "$test_dir/bin/wget"
PATH="$test_dir/bin:$test_path"
export PATH
printf '1|Blocked|http://blocked.test|Global\n2|Working|https://good.test/entware/|Region\n3|Fallback|https://fallback.test|Region\n4|Forbidden|https://forbidden.test|Region' > "$XMENU_OPKG_MIRRORS_FILE"
printf 'src/gz entware http://blocked.test/aarch64-k3.10\nsrc/gz custom https://custom.test/feed\n' > "$test_dir/opkg.conf"
test "$(xmenu_opkg_probe_mirror http://blocked.test /aarch64-k3.10)" = 'unavailable||invalid-index-http-200' || fail 'blocked response accepted'
case "$(xmenu_opkg_probe_mirror https://fallback.test /aarch64-k3.10)" in available\|*) : ;; *) fail 'wget fallback failed' ;; esac
xmenu_opkg_mirror_info_by_id 4 || fail 'catalog last line without newline ignored'
xmenu_opkg_auto_select_mirror || fail 'auto selection failed'
grep -q '^src/gz entware https://good.test/entware/aarch64-k3.10$' "$test_dir/opkg.conf" || fail 'wrong mirror applied'
grep -q '^src/gz custom https://custom.test/feed$' "$test_dir/opkg.conf" || fail 'custom feed rewritten'
test "$(xmenu_opkg_feed_path)" = '/aarch64-k3.10' || fail 'trailing slash feed parsing'

# Проверяем новый список и маршрутизацию пунктов 4/5.
terminal_width() { printf 100; }
_read_or_eof() { _read_value=0; return 0; }
opkg_settings_menu > "$test_dir/menu.txt"
grep -q 'Выбрать зеркало Entware вручную -   Статус, регион и адрес каждого зеркала.' "$test_dir/menu.txt" || fail 'manual menu label split'
grep -q 'Текущий:.*Working' "$test_dir/menu.txt" || fail 'active repository missing'
if grep -q 'Создать копию текущего\|6\.' "$test_dir/menu.txt"; then fail 'removed menu item still present'; fi
test_option=4
_read_or_eof() { _read_value=$test_option; test_option=0; return 0; }
xmenu_opkg_restore_config() { printf 'restore\n' > "$test_dir/dispatched"; }
pause() { return 0; }
opkg_settings_menu >/dev/null
test "$(cat "$test_dir/dispatched")" = restore || fail 'restore number wrong'
test_option=5
confirm() { return 0; }
opkg() { printf '%s\n' "$1" > "$test_dir/dispatched"; }
opkg_settings_menu >/dev/null
test "$(cat "$test_dir/dispatched")" = update || fail 'opkg update number wrong'
version_is_older 1.3.2 1.3.3 || fail 'version ordering'

# Открытие двух меню не должно удерживать общий lock сессии.
configure_locale() { return 0; }
require_root() { return 0; }
migrate_legacy_xmenu_data() { return 0; }
install_xmenu_command() { return 0; }
require_opkg() { return 0; }
ensure_dirs() { return 0; }
xmenu_start_update_check() { return 0; }
render_menu() { printf 'SESSION-OPEN\n'; }
xmenu_read_menu_prompt() { sleep 0.2; _read_value=0; return 0; }
(main > "$test_dir/session1") &
session1=$!
(main > "$test_dir/session2") &
session2=$!
wait "$session1" || fail 'first concurrent menu failed'
wait "$session2" || fail 'second concurrent menu failed'
grep -q SESSION-OPEN "$test_dir/session1" || fail 'first menu not opened'
grep -q SESSION-OPEN "$test_dir/session2" || fail 'second menu not opened'
printf 'PASS: regression scenarios\n'
