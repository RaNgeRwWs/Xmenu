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
terminal_width() { printf 80; }
_read_or_eof() { _read_value=0; return 0; }
BRIGHT_CYAN=$(printf '\033[1;38;5;51m')
opkg_settings_menu > "$test_dir/menu.txt"
LC_ALL=C awk '/Авто-выбор Entware/ {if ($0 !~ /зеркало$/) exit 1; found=1} END {if (!found) exit 1}' "$test_dir/menu.txt" || fail 'auto-select Entware explanation wrapped to another line'
grep -q 'Выбрать зеркало Entware вручную - Регион, адрес и текущий выбор.' "$test_dir/menu.txt" || fail 'manual menu label split'
grep -Fq "${BRIGHT_CYAN}Репозитории OPKG / Entware:" "$test_dir/menu.txt" || fail 'OPKG title not highlighted'
grep -q 'Текущий:.*Working' "$test_dir/menu.txt" || fail 'active repository missing'
if grep -q 'Создать копию текущего\|6\.' "$test_dir/menu.txt"; then fail 'removed menu item still present'; fi
terminal_width() { printf 100; }
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

# Ручной выбор открывается и меняет зеркало без сетевых проверок.
xmenu_opkg_check_mirrors() { fail 'manual selection started availability checks'; }
xmenu_opkg_probe_mirror() { fail 'manual selection probed a mirror'; }
test_option=1
_read_or_eof() { _read_value=$test_option; test_option=0; return 0; }
xmenu_opkg_manual_mirror_menu > "$test_dir/manual-menu.txt" || fail 'manual mirror menu failed'
grep -q '✓ Working' "$test_dir/manual-menu.txt" || fail 'current manual choice not marked'
grep -q '^src/gz entware http://blocked.test/aarch64-k3.10$' "$test_dir/opkg.conf" || fail 'manual selection not applied'

# Меню удаления сохраняет постоянные номера; резервное копирование оставлено CLI-командой.
pause() { return 0; }
_read_or_eof() { _read_value=0; return 0; }
remove_components_menu > "$test_dir/remove-menu.txt"
for menu_entry in \
    '1\. .*XKeen — полная деинсталляция' \
    '2\. .*XKeen UI — zxc-rv' \
    '3\. .*DPI Detector' \
    '4\. .*nfqws2-keenetic' \
    '5\. .*nfqws-keenetic-web' \
    '6\. .*Mihomo' \
    '7\. .*Удалить все пакеты NFQWS' \
    '8\. .*Удалить резервные копии' \
    '9\. .*Удалить все blobs NFQWS2' \
    '10\. .*Удалить все бэкапы Xmenu' \
    '11\. .*Другие установленные компоненты'; do
    grep -q "$menu_entry" "$test_dir/remove-menu.txt" || fail "removal menu entry missing: $menu_entry"
done

# Stale marker must not mark a different strategy as active.
CACHE_DIR="$test_dir/strategies"
ROOT_DIR="$test_dir/strategy-data"
mkdir -p "$CACHE_DIR/nfqws2" "$ROOT_DIR"
strategy_test_conf="$test_dir/nfqws2.conf"
printf 'NFQWS_ARGS="--dpi-desync=fake"\n' > "$strategy_test_conf"
cp "$strategy_test_conf" "$CACHE_DIR/nfqws2/fake_tls_auto_alt2.conf"
printf 'NFQWS_ARGS="--dpi-desync=none"\n' > "$CACHE_DIR/nfqws2/alt.conf"
printf 'alt.conf\n' > "$ROOT_DIR/active-strategy-nfqws2"
sync_strategies() { return 0; }
active_conf() { printf '%s|/opt/etc/nfqws2/nfqws2.conf' "$strategy_test_conf"; }
strategy_menu > "$test_dir/strategy-menu.txt" || fail 'strategy menu render failed'
grep -q 'fake_tls_auto_alt2\.conf.*— Активная стратегия' "$test_dir/strategy-menu.txt" || fail 'matching strategy not identified active'
if grep -q 'alt\.conf.*— Активная стратегия' "$test_dir/strategy-menu.txt"; then fail 'stale marker was shown as active'; fi
grep -Fq "$BRIGHT_CYAN" "$test_dir/strategy-menu.txt" || fail 'active strategy not highlighted in bright cyan'

# Компактный экран с восемью компонентами помещается в высоту скриншота.
_XMENU_DEVICE_CACHE_READY=1
_XMENU_DEVICE_INFO_CACHE='Hopper (NC-3811)|5.1.7'
_XMENU_ARCH_CACHE=aarch64
CYAN=$(printf '\033[36m')
RESET=$(printf '\033[0m')
xmenu_cached_remote_version() { printf '1.3.4'; }
render_component_statuses() {
    say 'Установленные компоненты:'
    component_table_header
    layout_component=1
    while [ "$layout_component" -le 8 ]; do
        say "  component-$layout_component 1.0"
        layout_component=$((layout_component + 1))
    done
}
render_menu > "$test_dir/main-menu.txt"
test "$(wc -l < "$test_dir/main-menu.txt")" -le 54 || fail 'menu still exceeds screenshot height'
grep -q '23\. .*Настройки OPKG' "$test_dir/main-menu.txt" || fail 'OPKG action missing'
grep -q '19\. .*Сменить язык: RU / EN (change language)' "$test_dir/main-menu.txt" || fail 'language option missing'
if grep -q 'Интерфейс и язык:\|24\. .*резервную копию' "$test_dir/main-menu.txt"; then fail 'removed menu entry remains'; fi
grep -q '0\. .*Выход' "$test_dir/main-menu.txt" || fail 'exit missing'
grep -Fq "${CYAN}Модель: Hopper (NC-3811) 5.1.7 aarch64" "$test_dir/main-menu.txt" || fail 'compact cyan device line missing'
grep -Fq "${CYAN}  ↑" "$test_dir/main-menu.txt" || fail 'update notice is not cyan'
escape=$(printf '\033')
sed "s/$escape\[[0-9;]*m//g" "$test_dir/main-menu.txt" > "$test_dir/plain-menu.txt"
update_line=$(grep -n '↑ Доступно обновление' "$test_dir/plain-menu.txt" | cut -d: -f1)
check_line=$(grep -n 'U\. .*Проверить наличие' "$test_dir/plain-menu.txt" | cut -d: -f1)
test "$update_line" -eq "$((check_line + 1))" || fail 'update notice is not directly below U'
LC_ALL=C awk '/Xmenu ◆ v1.3.3/ {
    match($0, /[^ ]/); if (RSTART-1 != 12) exit 1
    title_line=NR; found=1
} title_line && NR == title_line + 1 && $0 !~ /^=+$/ {exit 1}
  title_line && NR == title_line + 2 && $0 !~ /Модель:/ {exit 1}
END {if (!found || !title_line) exit 1}' "$test_dir/plain-menu.txt" || fail 'title header must have 12-space indent followed by divider and model'

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
