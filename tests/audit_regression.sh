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

printf 'PASS: deep audit regression scenarios\n'
