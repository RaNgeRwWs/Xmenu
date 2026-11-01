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
test_process_start=$(xmenu_process_start "$$") || fail 'could not read current process start time'
xmenu_lock_pid_is_owner "$$" "$test_process_start" || fail 'matching live lock owner was rejected'
test_wrong_start=0
[ "$test_process_start" = "$test_wrong_start" ] && test_wrong_start=1
if xmenu_lock_pid_is_owner "$$" "$test_wrong_start"; then fail 'reused PID with a different start time was accepted'; fi
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
fallback_probe=$(xmenu_opkg_probe_mirror https://fallback.test /aarch64-k3.10) || :
case "$fallback_probe" in available\|*) : ;; *) fail "wget fallback failed: $fallback_probe" ;; esac
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
grep -q 'Выбрать зеркало Entware вручную$' "$test_dir/menu.txt" || fail 'manual menu label differs from requested label'
grep -Fq "${BRIGHT_CYAN}Репозитории OPKG / Entware:" "$test_dir/menu.txt" || fail 'OPKG title not highlighted'
grep -q 'Текущий:.*Working' "$test_dir/menu.txt" || fail 'active repository missing'
grep -q '4\. *Копии opkg.conf' "$test_dir/menu.txt" || fail 'opkg.conf backup submenu is not item 4'
grep -q '5\. *Выполнить opkg update' "$test_dir/menu.txt" || fail 'opkg update is not item 5'
terminal_width() { printf 100; }
test_option=2
_read_or_eof() { _read_value=$test_option; test_option=0; return 0; }
xmenu_opkg_restore_config() { printf 'restore\n' > "$test_dir/dispatched"; }
pause() { return 0; }
xmenu_opkg_backups_menu > "$test_dir/backups-menu.txt"
grep -q '1\. *Создать копию opkg.conf' "$test_dir/backups-menu.txt" || fail 'create-backup action missing'
test "$(cat "$test_dir/dispatched")" = restore || fail 'restore number wrong'
test_option=3
confirm_yes() { return 0; }
xmenu_opkg_remove_backups() { printf 'remove-backups\n' > "$test_dir/dispatched"; }
xmenu_opkg_backups_menu >/dev/null
test "$(cat "$test_dir/dispatched")" = remove-backups || fail 'opkg.conf cleanup number wrong'
unset -f xmenu_opkg_remove_backups
eval "$(sed -n '/^xmenu_opkg_remove_backups() {/,/^}/p' "$source_file")"
mkdir -p "$test_dir/opkg-backups" "$test_dir/opkg-config"
printf 'active\n' > "$test_dir/opkg-config/opkg.conf"
printf 'backup\n' > "$test_dir/opkg-config/opkg.conf.old.bak"
printf 'backup\n' > "$test_dir/opkg-backups/opkg.conf.20261031.1.bak"
printf 'keep\n' > "$test_dir/opkg-backups/other.conf.bak"
XMENU_OPKG_CONFIG_DIR="$test_dir/opkg-config" XMENU_OPKG_BACKUP_DIR="$test_dir/opkg-backups" xmenu_opkg_remove_backups > "$test_dir/remove-opkg-backups.txt"
test -f "$test_dir/opkg-config/opkg.conf" || fail 'opkg.conf cleanup deleted the active config'
test ! -e "$test_dir/opkg-config/opkg.conf.old.bak" || fail 'opkg.conf cleanup kept a config-folder backup'
test ! -e "$test_dir/opkg-backups/opkg.conf.20261031.1.bak" || fail 'opkg.conf cleanup kept an Xmenu backup'
test -f "$test_dir/opkg-backups/other.conf.bak" || fail 'opkg.conf cleanup deleted an unrelated backup'
test_option=5
confirm() { return 0; }
opkg() { printf '%s\n' "$1" > "$test_dir/dispatched"; }
opkg_settings_menu >/dev/null
test "$(cat "$test_dir/dispatched")" = update || fail 'opkg update number wrong'
version_is_older 1.3.3 1.4.1 || fail 'version ordering'

# Пункт стратегий должен находить конфиг, даже если opkg list-installed
# временно не подтверждает установленный пакет.
(
    strategy_detect_root="$test_dir/strategy-engine-detection"
    mkdir -p "$strategy_detect_root/nfqws2" "$strategy_detect_root/nfqws"
    printf 'NFQWS_ARGS="--dpi-desync=fake"\n' > "$strategy_detect_root/nfqws2/nfqws2.conf"
    is_installed() { return 1; }
    detected=$(active_conf_from_paths "$strategy_detect_root/nfqws2/nfqws2.conf" "$strategy_detect_root/nfqws/nfqws.conf") ||
        fail 'strategy config was missed when package query failed'
    test "$detected" = "$strategy_detect_root/nfqws2/nfqws2.conf|/opt/etc/nfqws2/blobs" ||
        fail 'NFQWS2 config was detected incorrectly'
    rm -f "$strategy_detect_root/nfqws2/nfqws2.conf"
    printf 'NFQWS_ARGS="--dpi-desync=fake"\n' > "$strategy_detect_root/nfqws/nfqws.conf"
    detected=$(active_conf_from_paths "$strategy_detect_root/nfqws2/nfqws2.conf" "$strategy_detect_root/nfqws/nfqws.conf") ||
        fail 'NFQWS v1 config was not used as fallback'
    test "$detected" = "$strategy_detect_root/nfqws/nfqws.conf|/opt/etc/nfqws" ||
        fail 'NFQWS v1 config was detected incorrectly'
)

# Стратегии показываются по кэшированному SHA256SUMS; тела файлов скачиваются
# только после выбора, устаревший локальный конфиг не должен попасть в меню.
(
    strategy_test_root="$test_dir/strategy-lazy-cache"
    ROOT_DIR="$strategy_test_root/data"
    CACHE_DIR="$strategy_test_root/cache"
    XMENU_STRATEGY_SYNC_CACHE="$ROOT_DIR/strategies-sync.cache"
    strategy_fetch_log="$strategy_test_root/fetch.log"
    strategy_manifest_fixture="$strategy_test_root/SHA256SUMS"
    strategy_selected_fixture="$strategy_test_root/alt.conf"
    strategy_live_conf="$strategy_test_root/nfqws2.conf"
    mkdir -p "$ROOT_DIR/manifests" "$CACHE_DIR/nfqws2"
    : > "$ROOT_DIR/manifests/XMENU_REVISION"
    printf 'NFQWS_ARGS="--dpi-desync=fake"\n' > "$strategy_selected_fixture"
    printf 'NFQWS_ARGS="--dpi-desync=stale"\n' > "$CACHE_DIR/nfqws2/old.conf"
    strategy_hash=$(sha256_file "$strategy_selected_fixture")
    printf '%s  strategies/nfqws2/alt.conf\n' "$strategy_hash" > "$strategy_manifest_fixture"
    printf 'NFQWS_ARGS="--dpi-desync=fake"\n' > "$strategy_live_conf"
    ensure_base() { return 0; }
    fetch() {
        printf '%s\n' "$1" >> "$strategy_fetch_log"
        case "$1" in
            */blobs/SHA256SUMS) : > "$2" ;;
            https://api.github.com/repos/rangerxxyy/Xmenu/commits/main) printf '{"sha":"0123456789abcdef0123456789abcdef01234567"}\n' > "$2" ;;
            */SHA256SUMS) cp "$strategy_manifest_fixture" "$2" ;;
            */alt.conf) cp "$strategy_selected_fixture" "$2" ;;
            *) return 1 ;;
        esac
    }
    active_conf() { printf '%s|%s' "$strategy_live_conf" "$strategy_test_root/blobs"; }
    _read_or_eof() { _read_value=${strategy_choice:-0}; return 0; }
    confirm() { return 1; }
    strategy_choice=1
    strategy_menu > "$strategy_test_root/menu.txt" || fail 'lazy strategy menu failed'
    grep -q 'alt\.conf' "$strategy_test_root/menu.txt" || fail 'manifest strategy missing from menu without a local copy'
    if grep -q 'old\.conf' "$strategy_test_root/menu.txt"; then fail 'stale unlisted strategy shown in menu'; fi
    test "$(wc -l < "$strategy_fetch_log" | tr -d ' ')" -eq 4 || fail 'strategy menu downloaded more than source manifests, revision, and selected config'
    grep -q '/alt\.conf$' "$strategy_fetch_log" || fail 'selected strategy was not fetched lazily'
    strategy_choice=0
    strategy_menu > /dev/null || fail 'cached strategy menu did not reopen'
    test "$(wc -l < "$strategy_fetch_log" | tr -d ' ')" -eq 4 || fail 'fresh strategy manifest was fetched again'
    printf 'checked=0\n' > "$XMENU_STRATEGY_SYNC_CACHE"
    strategy_menu > /dev/null || fail 'expired strategy manifest did not refresh'
    test "$(wc -l < "$strategy_fetch_log" | tr -d ' ')" -eq 7 || fail 'expired strategy manifest refresh downloaded strategy bodies'
)

# Повторное открытие выбора стратегий не должно повторно скачивать манифесты
# и пересчитывать SHA-256, если успешная синхронизация была менее часа назад.
(
    strategy_cache_test_root="$test_dir/strategy-sync-cache"
    ROOT_DIR="$strategy_cache_test_root/data"
    CACHE_DIR="$strategy_cache_test_root/strategies"
    XMENU_STRATEGY_SYNC_CACHE="$ROOT_DIR/strategies-sync.cache"
    strategy_fetch_log="$strategy_cache_test_root/fetch.log"
    strategy_manifest_fixture="$strategy_cache_test_root/SHA256SUMS"
    mkdir -p "$ROOT_DIR/manifests" "$CACHE_DIR/nfqws2"
    printf 'NFQWS_ARGS="--dpi-desync=fake"\n' > "$CACHE_DIR/nfqws2/alt.conf"
    strategy_hash=$(sha256_file "$CACHE_DIR/nfqws2/alt.conf")
    printf '%s  strategies/nfqws2/alt.conf\n' "$strategy_hash" > "$strategy_manifest_fixture"
    cp "$strategy_manifest_fixture" "$ROOT_DIR/manifests/SHA256SUMS"
    cp "$strategy_manifest_fixture" "$ROOT_DIR/manifests/SHA256SUMS.nfqws-menu"
    cp "$strategy_manifest_fixture" "$ROOT_DIR/manifests/SHA256SUMS.xmenu"
    printf '0123456789abcdef0123456789abcdef01234567\n' > "$ROOT_DIR/manifests/XMENU_REVISION"
    printf 'checked=%s\ncatalog=2\n' "$(date +%s)" > "$XMENU_STRATEGY_SYNC_CACHE"
    ensure_base() { printf 'ensure_base\n' >> "$strategy_fetch_log"; return 0; }
    fetch() {
        printf '%s\n' "$1" >> "$strategy_fetch_log"
        case "$1" in
            */blobs/SHA256SUMS) : > "$2" ;;
            */SHA256SUMS) cp "$strategy_manifest_fixture" "$2" ;;
            *) return 1 ;;
        esac
    }
    sync_strategies || fail 'fresh strategy cache was rejected'
    test ! -s "$strategy_fetch_log" || fail 'fresh strategy cache performed redundant network work'
    printf 'checked=0\n' > "$XMENU_STRATEGY_SYNC_CACHE"
    sync_strategies || fail 'expired strategy cache did not refresh'
    test -s "$strategy_fetch_log" || fail 'expired strategy cache skipped refresh'
)

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
mkdir -p "$ROOT_DIR/manifests"
strategy_test_conf="$test_dir/nfqws2.conf"
printf 'NFQWS_ARGS="--dpi-desync=fake"\n' > "$strategy_test_conf"
cp "$strategy_test_conf" "$CACHE_DIR/nfqws2/fake_tls_auto_alt2.conf"
printf 'NFQWS_ARGS="--dpi-desync=none"\n' > "$CACHE_DIR/nfqws2/alt.conf"
printf '%064d  strategies/nfqws2/alt.conf\n%064d  strategies/nfqws2/fake_tls_auto_alt2.conf\n' 0 0 > "$ROOT_DIR/manifests/SHA256SUMS"
printf '0123456789abcdef0123456789abcdef01234567\n' > "$ROOT_DIR/manifests/XMENU_REVISION"
printf 'alt.conf\n' > "$ROOT_DIR/active-strategy-nfqws2"
sync_strategies() { return 0; }
active_conf() { printf '%s|/opt/etc/nfqws2/nfqws2.conf' "$strategy_test_conf"; }
strategy_menu > "$test_dir/strategy-menu.txt" || fail 'strategy menu render failed'
grep -q 'fake_tls_auto_alt2.*— Активная стратегия' "$test_dir/strategy-menu.txt" || fail 'matching strategy not identified active'
if grep -Eq '^ *[0-9]+\. *alt — Активная стратегия' "$test_dir/strategy-menu.txt"; then fail 'stale marker was shown as active'; fi
grep -Fq "$BRIGHT_CYAN" "$test_dir/strategy-menu.txt" || fail 'active strategy not highlighted in bright cyan'

# Компактный экран с восемью компонентами помещается в высоту скриншота.
_XMENU_DEVICE_CACHE_READY=1
_XMENU_DEVICE_INFO_CACHE='Hopper (NC-3811)|5.1.7'
_XMENU_ARCH_CACHE=aarch64
CYAN=$(printf '\033[36m')
RESET=$(printf '\033[0m')
xmenu_cached_remote_version() { printf '9.9.9'; }
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
test "$(wc -l < "$test_dir/main-menu.txt")" -le 55 || fail 'menu still exceeds screenshot height'
grep -q '22\. .*Настройки OPKG' "$test_dir/main-menu.txt" || fail 'OPKG action missing'
if grep -q 'U\. .*Проверить наличие обновления' "$test_dir/main-menu.txt"; then fail 'standalone U update row remains in menu'; fi
grep -q '18\. .*Сменить язык: RU / EN (change language)' "$test_dir/main-menu.txt" || fail 'language option missing'
grep -q '12\. .*Управление nfqws2' "$test_dir/main-menu.txt" || fail 'nfqws2 management item missing'
grep -q '17\. .*Прочие утилиты' "$test_dir/main-menu.txt" || fail 'other utilities item missing'
if grep -q 'Интерфейс и язык:\|26\. .*резервную копию' "$test_dir/main-menu.txt"; then fail 'removed menu entry remains'; fi
grep -q '0\. .*Выход' "$test_dir/main-menu.txt" || fail 'exit missing'
grep -Fq "${RESET}${WHITE}Модель: Hopper (NC-3811) ${BRIGHT_CYAN}5.1.7 ${RESET}${GREEN}(aarch64)${RESET}" "$test_dir/main-menu.txt" || fail 'device colors differ from model/firmware/architecture layout'
grep -Fq "${CYAN}  ↑" "$test_dir/main-menu.txt" || fail 'update notice is not cyan'
escape=$(printf '\033')
sed "s/$escape\[[0-9;]*m//g" "$test_dir/main-menu.txt" > "$test_dir/plain-menu.txt"
update_line=$(grep -n '↑ Доступно обновление' "$test_dir/plain-menu.txt" | cut -d: -f1)
grep -q 'Xmenu ◆ v1.4.4' "$test_dir/plain-menu.txt" || fail 'script version was not raised to 1.4.4'
grep -q 'Выбери пункт 21 для установки' "$test_dir/plain-menu.txt" || fail 'update notice lost update action hint'
LC_ALL=C awk '/Xmenu ◆ v1.4.4/ {
    match($0, /[^ ]/); if (RSTART-1 != 12) exit 1
    title_line=NR; found=1
} title_line && NR == title_line + 1 && $0 !~ /^=+$/ {exit 1}
  title_line && NR == title_line + 2 && $0 !~ /Модель:/ {exit 1}
END {if (!found || !title_line) exit 1}' "$test_dir/plain-menu.txt" || fail 'title header must have 12-space indent followed by divider and model'

# S opens the service submenu, while U remains available in the prompt.
(
    configure_locale() { :; }
    require_root() { :; }
    migrate_legacy_xmenu_data() { :; }
    install_xmenu_command() { :; }
    require_opkg() { :; }
    ensure_dirs() { :; }
    get_ui_lang() { printf en; }
    xmenu_start_update_check() { :; }
    render_menu() { printf 'MAIN-MENU\n'; }
    hotkey_reads=0
    xmenu_read_menu_prompt() {
        printf '%s\n' "$1"
        hotkey_reads=$((hotkey_reads + 1))
        if [ "$hotkey_reads" -eq 1 ]; then _read_value=S; else _read_value=''; fi
        return 0
    }
    xmenu_service_menu() { printf 'SERVICE-HOTKEY\n'; }
    main > "$test_dir/service-hotkey.txt" || fail 'S hotkey dispatch failed'
)
grep -q 'S = service, U = check updates' "$test_dir/service-hotkey.txt" || fail 'S or U missing from prompt'
grep -q 'SERVICE-HOTKEY' "$test_dir/service-hotkey.txt" || fail 'S did not open service submenu'

# Фоновое заполнение кеша не должно повторно печатать весь экран.
XMENU_COMPONENT_CACHE="$test_dir/components-status.cache"
XMENU_COMPONENT_CACHE_TIME="$test_dir/components-status.cache.time"
printf 'xkeen\t1.0\n' > "$XMENU_COMPONENT_CACHE"
date +%s > "$XMENU_COMPONENT_CACHE_TIME"
XMENU_COMPONENT_REFRESH_PENDING=1
XMENU_UPDATE_NOTICE_VISIBLE=1
render_menu() { printf 'COMPONENTS-REDRAW\n'; }
if xmenu_redraw_pending_update > "$test_dir/components-redraw.txt"; then fail 'component refresh requested another prompt'; fi
if grep -q COMPONENTS-REDRAW "$test_dir/components-redraw.txt"; then fail 'component refresh printed the whole menu again'; fi
test "$XMENU_COMPONENT_REFRESH_PENDING" = 0 || fail 'component redraw flag was not cleared'

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
