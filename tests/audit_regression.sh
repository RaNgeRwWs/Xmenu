#!/bin/sh
# Сценарии глубокого аудита: только временные файлы и имитация внешних команд.
set -eu
audit_dir=$(mktemp -d)
audit_path=$PATH
source_file=$(cd "$(dirname "$0")/.." && pwd)/xmenu-v1.0.sh
sed '/^main "\$@"$/d' "$source_file" |
    sed "s#/opt/etc/nfqws2#$audit_dir/nfqws2#g; s#/opt/etc/nfqws/#$audit_dir/nfqws/#g; s#/opt/etc/opkg.conf#$audit_dir/opkg.conf#g" > "$audit_dir/library.sh"
# shellcheck disable=SC1090
. "$audit_dir/library.sh"
PATH=$audit_path
export PATH
ROOT_DIR="$audit_dir/data"
BACKUP_DIR="$ROOT_DIR/backups"
CACHE_DIR="$audit_dir/strategies"
LANG_FILE="$ROOT_DIR/language"
LOCK_DIR="$audit_dir/operation.lock"
XMENU_COMPONENT_REFRESH_LOCK="$ROOT_DIR/component.lock"
XMENU_COMPONENT_CACHE="$ROOT_DIR/components.cache"
XMENU_COMPONENT_CACHE_TIME="$ROOT_DIR/components.time"
mkdir -p "$BACKUP_DIR" "$audit_dir/bin"
trap 'rm -rf "$audit_dir"' 0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

(
    # При ошибке транспорт оставляет непустой файл. Он не должен стать обновлением.
    cat > "$audit_dir/bin/curl" <<'EOF'
#!/bin/sh
out=''
while [ "$#" -gt 0 ]; do
    case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac
done
printf '#!/bin/sh\nAPP_VERSION="1.4.0"\n' > "$out"
if [ "$XMENU_TEST_NET_MODE" = curl-ok ]; then printf '200'; exit 0; fi
exit 28
EOF
    cat > "$audit_dir/bin/wget" <<'EOF'
#!/bin/sh
out=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help) printf '%s\n' '--tries=NUMBER'; exit 0 ;;
        -O) out=$2; shift 2 ;;
        *) shift ;;
    esac
done
printf '#!/bin/sh\nAPP_VERSION="1.4.0"\n' > "$out"
[ "$XMENU_TEST_NET_MODE" = wget-ok ] && exit 0
exit 4
EOF
    chmod +x "$audit_dir/bin/curl" "$audit_dir/bin/wget"
    PATH="$audit_dir/bin:$audit_path"
    export PATH
    ensure_network() { return 0; }
    XMENU_TEST_NET_MODE=both-fail
    export XMENU_TEST_NET_MODE
    if xmenu_fetch_file https://example.test/script "$audit_dir/download" 2; then fail 'partial download accepted'; fi
    test ! -e "$audit_dir/download" || fail 'failed download not removed'
    XMENU_TEST_NET_MODE=wget-ok
    xmenu_fetch_file https://example.test/script "$audit_dir/download" 2 || fail 'valid wget fallback rejected'
    XMENU_TEST_NET_MODE=curl-ok
    xmenu_fetch_file https://example.test/script "$audit_dir/download" 2 0-4095 >/dev/null || fail 'valid curl range rejected'
    # Все обычные загрузки wget тоже должны иметь общий timeout и одну попытку.
    XMENU_TEST_NET_MODE=wget-ok
    timeout() {
        printf '%s\n' "$*" >> "$audit_dir/timeouts"
        shift
        "$@"
    }
    fetch https://example.test/script "$audit_dir/download" 2 >/dev/null || fail 'general fetch fallback failed'
    grep -q -- '-t 1' "$audit_dir/timeouts" || fail 'wget retry limit not applied'
)

(
    printf 'ISP_INTERFACE="eth3 eth4" # keep both\nNFQWS_ARGS="--old"\n' > "$audit_dir/live.conf"
    printf 'ISP_INTERFACE="eth9"\r\nNFQWS_ARGS="--new"\r\n' > "$audit_dir/candidate.conf"
    prepare_strategy_config "$audit_dir/live.conf" "$audit_dir/candidate.conf" || fail 'valid strategy preparation failed'
    grep -Fq 'ISP_INTERFACE="eth3 eth4" # keep both' "$audit_dir/candidate.conf" || fail 'interface value or comment lost'
    if LC_ALL=C grep -q "$(printf '\r')" "$audit_dir/candidate.conf"; then fail 'CRLF not normalized'; fi
    chmod 640 "$audit_dir/live.conf"
    saved_mode=$(stat -c '%a' "$audit_dir/live.conf")
    replace_shell_config "$audit_dir/candidate.conf" "$audit_dir/live.conf" || fail 'atomic replacement failed'
    grep -Fq 'NFQWS_ARGS="--new"' "$audit_dir/live.conf" || fail 'new config not installed'
    test "$(stat -c '%a' "$audit_dir/live.conf")" = "$saved_mode" || fail 'config mode changed'
    saved_hash=$(sha256_file "$audit_dir/live.conf")
    printf 'NFQWS_ARGS="unterminated\n' > "$audit_dir/invalid.conf"
    if replace_shell_config "$audit_dir/invalid.conf" "$audit_dir/live.conf" 2>/dev/null; then fail 'invalid shell config installed'; fi
    test "$(sha256_file "$audit_dir/live.conf")" = "$saved_hash" || fail 'live config changed after syntax failure'
    ln -s "$audit_dir/live.conf" "$audit_dir/config-link"
    # Git Bash на NTFS может эмулировать ln -s копией; настоящие ссылки проверяет Linux CI.
    if [ -L "$audit_dir/config-link" ]; then
        if replace_shell_config "$audit_dir/candidate.conf" "$audit_dir/config-link"; then fail 'config symlink replaced'; fi
    fi
    # Имитируем ошибку записи после первых байтов (например, заполненный диск).
    cat() { printf 'PARTIAL'; return 1; }
    if replace_shell_config "$audit_dir/candidate.conf" "$audit_dir/live.conf"; then fail 'write failure ignored'; fi
    test "$(sha256_file "$audit_dir/live.conf")" = "$saved_hash" || fail 'live config truncated on write failure'
    test "$(find "$audit_dir" -name '*.xmenu.*' | wc -l)" -eq 0 || fail 'staged config leaked'
)

(
    mkdir -p "$CACHE_DIR/nfqws2" "$audit_dir/nfqws2" "$ROOT_DIR/manifests"
    printf 'NFQWS_ARGS="--old"\n' > "$audit_dir/nfqws2/nfqws2.conf"
    printf 'NFQWS_ARGS="--new"\n' > "$CACHE_DIR/nfqws2/alt.conf"
    printf 'PEER SESSION LIST\n' > "$ROOT_DIR/strategies.list"
    sync_strategies() { return 0; }
    active_conf() { printf '%s|%s' "$audit_dir/nfqws2/nfqws2.conf" "$audit_dir/nfqws2/blobs"; }
    _read_or_eof() { _read_value=0; return 0; }
    strategy_menu >/dev/null || fail 'strategy menu failed'
    test "$(cat "$ROOT_DIR/strategies.list")" = 'PEER SESSION LIST' || fail 'another session strategy list overwritten'
    test ! -e "$ROOT_DIR/strategies-list.$$" || fail 'session strategy list leaked'
    # Проверенный SHA не заменяет проверку синтаксиса перед применением.
    printf 'NFQWS_ARGS="unterminated\n' > "$CACHE_DIR/nfqws2/alt.conf"
    printf '%s  strategies/nfqws2/alt.conf\n' "$(sha256_file "$CACHE_DIR/nfqws2/alt.conf")" > "$ROOT_DIR/manifests/SHA256SUMS"
    original_hash=$(sha256_file "$audit_dir/nfqws2/nfqws2.conf")
    _read_or_eof() { _read_value=01; return 0; }
    confirm() { return 0; }
    update_blobs_for() { fail 'invalid strategy reached blob installation'; }
    if strategy_menu >/dev/null 2>&1; then fail 'invalid strategy reported success'; fi
    test "$(sha256_file "$audit_dir/nfqws2/nfqws2.conf")" = "$original_hash" || fail 'invalid strategy changed live config'
    test ! -d "$LOCK_DIR" || fail 'failed strategy kept operation lock'
)

(
    mkdir -p "$audit_dir/nfqws2/lists"
    printf 'NFQWS_ARGS="--hostlist=%s/nfqws2/lists/../../escaped.list"\n' "$audit_dir" > "$audit_dir/list.conf"
    fetch() { printf 'example.test\n' > "$2"; }
    if update_lists_for "$audit_dir/list.conf" 2 >/dev/null; then fail 'list traversal accepted'; fi
    test ! -e "$audit_dir/escaped.list" || fail 'list written outside NFQWS directory'
    : > "$audit_dir/nfqws2/lists/user.list"
    : > "$audit_dir/nfqws2/lists/auto.list"
    printf 'NFQWS_ARGS="--hostlist=%s/nfqws2/lists/user.list --hostlist-auto=%s/nfqws2/lists/auto.list"\n' "$audit_dir" "$audit_dir" > "$audit_dir/list.conf"
    fetch() { fail 'existing empty list fetched again'; }
    update_lists_for "$audit_dir/list.conf" 2 >/dev/null || fail 'valid empty lists rejected'
    test "$LISTS_CHANGED" = 0 || fail 'existing empty list requests restart'
    printf 'MODE_LIST="--hostlist=%s/nfqws2/lists/rkn.list.backup"\n' "$audit_dir" > "$audit_dir/rkn.conf"
    host="--hostlist=$audit_dir/nfqws2/lists/rkn.list"
    if mode_list_has_host "$audit_dir/rkn.conf" "$host"; then fail 'hostlist prefix treated as exact argument'; fi
    saved_hash=$(sha256_file "$audit_dir/rkn.conf")
    drop_missing_rkn_reference "$audit_dir/rkn.conf" 2 >/dev/null || fail 'similar RKN filename processing failed'
    test "$(sha256_file "$audit_dir/rkn.conf")" = "$saved_hash" || fail 'rkn.list.backup reference damaged'
    printf 'MODE_LIST="%s %s.backup"\n# %s\n' "$host" "$host" "$host" > "$audit_dir/rkn.conf"
    mode_list_has_host "$audit_dir/rkn.conf" "$host" || fail 'exact RKN argument not found'
    drop_missing_rkn_reference "$audit_dir/rkn.conf" 2 >/dev/null || fail 'broken RKN argument not removed'
    if mode_list_has_host "$audit_dir/rkn.conf" "$host"; then fail 'broken RKN argument still present'; fi
    grep -Fq -- "$host.backup" "$audit_dir/rkn.conf" || fail 'similar filename damaged during removal'
    grep -Fq "# $host" "$audit_dir/rkn.conf" || fail 'RKN comment damaged'
)

(
    mkdir -p "$audit_dir/backup-a" "$audit_dir/backup-b" "$audit_dir/parallel/root"
    printf 'FIRST\n' > "$audit_dir/backup-a/settings.conf"
    printf 'SECOND\n' > "$audit_dir/backup-b/settings.conf"
    touch -t 200001010000 "$audit_dir/backup-a/settings.conf" "$audit_dir/backup-b/settings.conf"
    cat > "$audit_dir/backup-worker.sh" <<'EOF'
#!/bin/sh
set -eu
. "$1"
trap - 0
ROOT_DIR="$2/root"
BACKUP_DIR="$2/backups"
date() { printf '20000101-000000\n'; }
cp() {
    : > "$ROOT_DIR/arrived.$$"
    attempts=0
    while [ "$(find "$ROOT_DIR" -name 'arrived.*' | wc -l)" -lt 2 ]; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 100 ] || return 1
        sleep 0.05
    done
    command cp "$@"
}
backup_file "$3" >/dev/null
EOF
    sh "$audit_dir/backup-worker.sh" "$audit_dir/library.sh" "$audit_dir/parallel" "$audit_dir/backup-a/settings.conf" &
    backup_first=$!
    sh "$audit_dir/backup-worker.sh" "$audit_dir/library.sh" "$audit_dir/parallel" "$audit_dir/backup-b/settings.conf" &
    backup_second=$!
    wait "$backup_first" || fail 'first parallel backup failed'
    wait "$backup_second" || fail 'second parallel backup failed'
    test "$(find "$audit_dir/parallel/backups" -type f | wc -l)" -eq 2 || fail 'parallel backup overwritten'
    grep -l FIRST "$audit_dir/parallel/backups"/* >/dev/null || fail 'first backup content lost'
    grep -l SECOND "$audit_dir/parallel/backups"/* >/dev/null || fail 'second backup content lost'
    for archive in "$audit_dir/parallel/backups"/*; do
        test "$(stat -c '%Y' "$archive")" -gt 946684800 || fail 'backup still has old source timestamp'
    done
)

printf 'PASS: deep audit regression scenarios\n'
