#!/bin/sh
# Xmenu ◆ v1.0 — Entware / BusyBox ash; based on the v2.4.19 codebase
APP_VERSION="1.0"
# XKEEN_MENU_AUTO_YES=1/true/yes/on отключает подтверждение только для NFQWS2 UI в install-all.
# Сторонние установщики пока не имеют независимой криптографической проверки; закрепление ревизий запланировано для v2.5.0.
ROOT_DIR="/opt/etc/xkeen-menu"
BACKUP_DIR="$ROOT_DIR/backups"
CACHE_DIR="/opt/etc/nfqws-menu/strategies"
LANG_FILE="$ROOT_DIR/language"
NF_REPO="https://raw.githubusercontent.com/rndnaame/nfqws-menu/main"
XKEEN_INSTALLER="https://raw.githubusercontent.com/jameszeroX/XKeen/main/install.sh"
XKEEN_UI_INSTALLER="https://raw.githubusercontent.com/zxc-rv/XKeen-UI/main/setup.sh"
NFQWS2_UI_INSTALLER="https://github.com/zemidala/nfqws2-ui/releases/latest/download/install.sh"
DPI_RUST_INSTALLER_URL="https://raw.githubusercontent.com/Runnin4ik/dpi-detector/rust/install.sh"
DPI_RUST_INSTALLER_MIRROR="https://cdn.jsdelivr.net/gh/Runnin4ik/dpi-detector@rust/install.sh"
NFQWS2_REPO_BASE="https://nfqws.github.io/nfqws2-keenetic"
NFQWS_WEB_REPO="https://nfqws.github.io/nfqws-keenetic-web/all"

PATH="/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

WORK=""
LOCK_DIR="/opt/var/lock/xkeen-menu.lock"
LOCK_HELD=0
INTERRUPTED=0
MENU_READING=0
_LAST_MENU_INTERRUPT_TS=0
_FETCH_FAIL_COUNT=0
cleanup() {
    if [ -n "$WORK" ] && [ "$WORK" != / ] && [ -d "$WORK" ]; then
        case "$WORK" in "$ROOT_DIR"/*|/tmp/xmenu-*) rm -rf "$WORK" ;; esac
    fi
    WORK=""
    if [ "$LOCK_HELD" = 1 ] && [ -d "$LOCK_DIR" ]; then
        _cleanup_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || :)
        if [ "$_cleanup_pid" = "$$" ]; then
            rm -f "$LOCK_DIR/pid" 2>/dev/null || :
            rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR" 2>/dev/null || :
        fi
    fi
    LOCK_HELD=0
}
on_int() {
    INTERRUPTED=1
    if [ "${MENU_READING:-0}" = 1 ]; then
        _interrupt_now=$(date +%s 2>/dev/null || printf '0')
        case "$_interrupt_now" in ''|*[!0-9]*) _interrupt_now=0 ;; esac
        case "${_LAST_MENU_INTERRUPT_TS:-0}" in ''|*[!0-9]*) _LAST_MENU_INTERRUPT_TS=0 ;; esac
        if [ "$_interrupt_now" -gt 0 ] && [ "$_LAST_MENU_INTERRUPT_TS" -gt 0 ]; then
            _interrupt_delta=$(( _interrupt_now - _LAST_MENU_INTERRUPT_TS ))
            if [ "$_interrupt_delta" -ge 0 ] && [ "$_interrupt_delta" -lt 2 ]; then
                cleanup
                exit 130
            fi
        fi
        _LAST_MENU_INTERRUPT_TS=$_interrupt_now
    fi
}

on_exit_signal() { cleanup; exit 130; }
trap 'on_int' INT
trap 'on_exit_signal' TERM HUP

if [ -t 1 ]; then
    RESET=$(printf '\033[0m'); PURPLE=$(printf '\033[35m'); LAVENDER=$(printf '\033[95m'); WHITE=$(printf '\033[97m')
    MUTED=$(printf '\033[90m'); GREEN=$(printf '\033[32m'); YELLOW=$(printf '\033[33m'); RED=$(printf '\033[31m'); BRIGHT_RED=$(printf '\033[91m'); CYAN=$(printf '\033[36m')
else
    RESET=''; PURPLE=''; LAVENDER=''; WHITE=''; MUTED=''; GREEN=''; YELLOW=''; RED=''; BRIGHT_RED=''; CYAN=''
fi
say() { printf '%s\n' "$*"; }

get_ui_lang() {
    _lang=$(cat "$LANG_FILE" 2>/dev/null | tr -d '[:space:]')
    case "$_lang" in en|EN) printf en ;; *) printf ru ;; esac
}

set_ui_lang() {
    _new_lang=$1
    case "$_new_lang" in en|ru) : ;; *) return 1 ;; esac
    mkdir -p "$ROOT_DIR" || return 1
    printf '%s\n' "$_new_lang" > "$LANG_FILE" || return 1
    say "Язык меню изменён: $_new_lang / Language changed: $_new_lang"
}

run_remote_installer() {
    _ri_url=$1
    _ri_name=$2
    _ri_min=${3:-1500}
    _ri_tmp="/tmp/xmenu-remote-$$.sh"
    ensure_network || return 1
    say "Источник установщика: $_ri_url"
    say "Скачиваю установщик $_ri_name..."
    if ! fetch "$_ri_url" "$_ri_tmp" 240; then
        rm -f "$_ri_tmp"
        say "${RED}Не удалось скачать установщик $_ri_name.${RESET}"
        return 1
    fi
    _ri_size=$(wc -c < "$_ri_tmp" 2>/dev/null | tr -d ' ')
    case "$_ri_size" in ''|*[!0-9]*) _ri_size=0 ;; esac
    if [ "$_ri_size" -lt "$_ri_min" ] || head -c 256 "$_ri_tmp" 2>/dev/null | grep -qiE '<html|404: Not Found|Bad Gateway|Not Found'; then
        rm -f "$_ri_tmp"
        say "${RED}Загруженный файл слишком мал или похож на страницу ошибки; запуск отменён.${RESET}"
        return 1
    fi
    if ! sh -n "$_ri_tmp"; then
        rm -f "$_ri_tmp"
        say "${RED}Синтаксис установщика $_ri_name некорректен для sh; выполнение отменено.${RESET}"
        return 1
    fi
    if [ -c /dev/tty ]; then
        sh "$_ri_tmp" </dev/tty >/dev/tty 2>&1
        _ri_rc=$?
    else
        sh "$_ri_tmp"
        _ri_rc=$?
    fi
    rm -f "$_ri_tmp"
    return "$_ri_rc"
}

configure_locale() {
    command -v locale >/dev/null 2>&1 || return 0
    _locale_list=$(locale -a 2>/dev/null || printf '')
    for _locale_candidate in ru_RU.UTF-8 ru_RU.utf8 C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
        if printf '%s\n' "$_locale_list" | awk -v want="$_locale_candidate" 'tolower($0)==tolower(want){found=1} END{exit(found?0:1)}'; then
            LC_ALL=$_locale_candidate
            export LC_ALL
            return 0
        fi
    done
    # Если UTF-8 локаль отсутствует, оставляем настройки окружения пользователя.
    return 0
}

terminal_width() {
    _width=''
    # Проверяем controlling TTY через /dev/tty, а не stdout: внутри $(...) stdout
    # является pipe, поэтому прежняя проверка [ -t 1 ] ошибочно игнорировала ширину SSH-терминала.
    if [ -r /dev/tty ] && command -v stty >/dev/null 2>&1; then
        _width=$(stty size </dev/tty 2>/dev/null | awk 'NF >= 2 {print $2; exit}')
    fi
    case "$_width" in ''|*[!0-9]*) _width=${COLUMNS:-80} ;; esac
    case "$_width" in ''|*[!0-9]*) _width=80 ;; esac
    [ "$_width" -ge 40 ] 2>/dev/null || _width=40
    # Xmenu uses a fixed maximum layout width so an SSH client that reports an
    # oversized/stale COLUMNS value cannot push the title far to the right or
    # print divider lines hundreds of characters long. Keep title and dividers
    # centered/aligned inside this same 100-column menu frame.
    [ "$_width" -le 100 ] 2>/dev/null || _width=100
    printf '%s' "$_width"
}

line() {
    _line_width=$(terminal_width)
    _line_text=$(printf '%*s' "$_line_width" '' | tr ' ' '=')
    say "${PURPLE}$_line_text${RESET}"
}
menu_item() {
    _mi_number=$1
    shift
    _mi_text=$*
    _mi_term_width=$(terminal_width)
    _mi_text_width=$((_mi_term_width - 11))
    [ "$_mi_text_width" -ge 20 ] 2>/dev/null || _mi_text_width=20
    _mi_first_prefix="      $(printf '%2s.  ' "$_mi_number")"
    # Passing the label through stdin avoids accidental shell expansion in a heredoc.
    printf '%s\n' "$_mi_text" | LC_ALL=C awk -v width="$_mi_text_width" -v first="$_mi_first_prefix" -v cont='           ' '
        function cell_length(s, t) {
            # In the C locale, remove UTF-8 continuation bytes only for measuring.
            # This treats Cyrillic letters and the title diamond as one terminal cell.
            t = s
            gsub(/[\200-\277]/, "", t)
            return length(t)
        }
        {
            count = split($0, words, /[[:space:]]+/)
            line = ""
            emitted = 0
            for (i = 1; i <= count; i++) {
                word = words[i]
                if (word == "") continue
                if (line == "") line = word
                else if (cell_length(line) + 1 + cell_length(word) <= width) line = line " " word
                else {
                    if (!emitted) printf "%s%s\n", first, line
                    else printf "%s%s\n", cont, line
                    emitted = 1
                    line = word
                }
            }
            if (line != "") {
                if (!emitted) printf "%s%s\n", first, line
                else printf "%s%s\n", cont, line
            }
        }
    '
}
pause() {
    if [ "$(get_ui_lang)" = en ]; then printf '\nPress Enter to return...';
    else printf '\nНажми Enter для возврата...'; fi
    _read_or_eof '' || :
}

require_root() { [ "$(id -u 2>/dev/null)" = 0 ] || { say "${RED}Нужен root в SSH Entware.${RESET}"; return 1; }; }
require_opkg() { command -v opkg >/dev/null 2>&1 || { say "${RED}opkg не найден: это не shell Entware.${RESET}"; return 1; }; }

_read_or_eof() {
    _read_prompt=${1:-}
    _read_value=''
    printf '%b' "$_read_prompt"
    if [ -t 0 ] && [ -r /dev/tty ]; then
        IFS= read -r _read_value </dev/tty || return 1
    else
        IFS= read -r _read_value || return 1
    fi
    _read_value=$(printf '%s' "$_read_value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    return 0
}

# Подтверждение с ответом «да» по умолчанию; неверный ответ вызывает повтор вопроса.
confirm_yes() {
    while :; do
        _read_or_eof "${YELLOW}${1:-Продолжить?} [Y/n]: ${RESET}" || return 1
        case "$(printf '%s' "$_read_value" | tr '[:upper:]' '[:lower:]')" in
            ''|y|yes|да|д|true|1) return 0 ;;
            n|no|нет|н|false|0) return 1 ;;
            *) say "Введите да или нет (y/n)." ;;
        esac
    done
}

# Подтверждение с ответом «нет» по умолчанию; неверный ответ вызывает повтор вопроса.
confirm_no() {
    while :; do
        _read_or_eof "${YELLOW}${1:-Продолжить?} [y/N]: ${RESET}" || return 1
        case "$(printf '%s' "$_read_value" | tr '[:upper:]' '[:lower:]')" in
            y|yes|да|д|true|1) return 0 ;;
            ''|n|no|нет|н|false|0) return 1 ;;
            *) say "Введите да или нет (y/n)." ;;
        esac
    done
}

# Совместимость с прежними вызовами: confirm по умолчанию отвечает «нет».
confirm() { confirm_no "$1"; }

auto_yes_enabled() {
    case "$(printf '%s' "${XKEEN_MENU_AUTO_YES:-0}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on|да|д) return 0 ;;
        *) return 1 ;;
    esac
}

# Неблокирующая очистка уже ожидающей строки stdin; при отсутствии поддержки -t сразу выходим.
drain_stdin() {
    [ -t 0 ] || return 0
    _drain_count=0
    while [ "$_drain_count" -lt 32 ]; do
        IFS= read -r -t 0 _drain_line 2>/dev/null || break
        IFS= read -r _drain_line 2>/dev/null || break
        _drain_count=$((_drain_count + 1))
    done
    return 0
}

is_installed() { opkg list-installed 2>/dev/null | awk -v p="$1" '$1==p{f=1} END{exit(f?0:1)}'; }
pkg_version() { opkg status "$1" 2>/dev/null | sed -n 's/^Version:[[:space:]]*//p' | head -n 1; }

_TRANSPORT_TLS_CACHED=''
transport_has_tls() {
    [ "$_TRANSPORT_TLS_CACHED" = yes ] && return 0
    _curl_path=$(command -v curl 2>/dev/null || printf '')
    _probe_urls="$NF_REPO/SHA256SUMS https://cdn.jsdelivr.net/gh/rndnaame/nfqws-menu@main/SHA256SUMS"
    if [ -n "$_curl_path" ] && [ -x "$_curl_path" ]; then
        # Отдельно проверяем TLS-возможность сборки, а доступность хоста решает fetch() с зеркалами.
        if "$_curl_path" -V 2>/dev/null | grep -Eiq 'Protocols:.*https' &&
           "$_curl_path" -V 2>/dev/null | grep -Eiq 'Features:.*(SSL|TLS|OpenSSL|LibreSSL|Schannel|SecureTransport|wolfSSL|mbedTLS|GnuTLS)'; then
            _TRANSPORT_TLS_CACHED=yes
            return 0
        fi
    fi
    _wget_path=$(command -v wget 2>/dev/null || printf '')
    if [ -n "$_wget_path" ] && [ -x "$_wget_path" ]; then
        for _probe_url in $_probe_urls; do
            if "$_wget_path" --help 2>&1 | grep -q -- '--spider'; then
                if "$_wget_path" -q --spider -T 8 "$_probe_url" >/dev/null 2>&1; then
                    _TRANSPORT_TLS_CACHED=yes
                    return 0
                fi
            else
                if "$_wget_path" -q -T 8 -O /dev/null --header='Range: bytes=0-1023' "$_probe_url" >/dev/null 2>&1; then
                    _TRANSPORT_TLS_CACHED=yes
                    return 0
                fi
                # Совместимый запасной вариант для wget без поддержки Range.
                if "$_wget_path" -q -T 8 -O /dev/null "$_probe_url" >/dev/null 2>&1; then
                    _TRANSPORT_TLS_CACHED=yes
                    return 0
                fi
            fi
        done
    fi
    # Отрицательный результат не кэшируется: позднее DNS или VPN могут заработать.
    return 1
}

install_transport() {
    transport_has_tls && return 0
    say 'Не найден рабочий HTTPS-транспорт (возможно, wget собран без TLS) — устанавливаю curl/wget-ssl...'
    opkg update || { say "${RED}opkg update завершился ошибкой, транспорт установить не удалось.${RESET}"; return 1; }
    opkg install curl ca-certificates wget-ssl || { say "${RED}Не удалось установить curl/ca-certificates/wget-ssl.${RESET}"; return 1; }
    _TRANSPORT_TLS_CACHED=''
    transport_has_tls || { say "${RED}После установки не удалось подтвердить поддержку HTTPS у curl/wget. Проверь DNS и доступ к raw.githubusercontent.com.${RESET}"; return 1; }
    return 0
}
ensure_dirs() {
    mkdir -p "$ROOT_DIR" "$BACKUP_DIR" /opt/tmp /opt/share/xkeen-menu /opt/var/log || {
        say "${RED}Не удалось создать рабочие каталоги Xmenu.${RESET}"
        return 1
    }
}
ensure_network() {
    require_opkg || return 1
    if [ -f "$ROOT_DIR/.base-ready" ] && transport_has_tls; then return 0; fi
    install_transport || { say "${RED}HTTPS-транспорт недоступен. Проверь DNS/интернет и повтори операцию.${RESET}"; return 1; }
    # jq нужен для надёжного разбора API релизов; остаётся и запасной разбор.
    if ! command -v jq >/dev/null 2>&1; then opkg install jq >/dev/null 2>&1 || :; fi
    for _p in ca-certificates libnghttp2 bash gawk coreutils-sha256sum; do
        is_installed "$_p" || opkg install "$_p" >/dev/null 2>&1 || :
    done
    : > "$ROOT_DIR/.base-ready" 2>/dev/null || :
    return 0
}
# Псевдоним для старых вызовов; сетевые операции используют ensure_network.
ensure_base() { ensure_network; }

fetch_url_candidates() {
    _candidate_url=$1
    case "$_candidate_url" in
        https://raw.githubusercontent.com/*)
            _candidate_rest=${_candidate_url#https://raw.githubusercontent.com/}
            _candidate_owner=${_candidate_rest%%/*}; _candidate_rest=${_candidate_rest#*/}
            _candidate_repo=${_candidate_rest%%/*}; _candidate_rest=${_candidate_rest#*/}
            _candidate_ref=${_candidate_rest%%/*}; _candidate_path=${_candidate_rest#*/}
            printf '%s\n' "$_candidate_url"
            if [ -n "$_candidate_owner" ] && [ -n "$_candidate_repo" ] && [ -n "$_candidate_ref" ] && [ -n "$_candidate_path" ]; then
                case "$_candidate_ref" in refs/heads/*) _candidate_ref=${_candidate_ref#refs/heads/} ;; refs/tags/*) _candidate_ref=${_candidate_ref#refs/tags/} ;; esac
                printf '%s\n' "https://fastly.jsdelivr.net/gh/$_candidate_owner/$_candidate_repo@$_candidate_ref/$_candidate_path"
                printf '%s\n' "https://cdn.jsdelivr.net/gh/$_candidate_owner/$_candidate_repo@$_candidate_ref/$_candidate_path"
                printf '%s\n' "https://ghproxy.net/$_candidate_url"
            fi
            ;;
        https://github.com/*/releases/latest/download/*|https://github.com/*/releases/download/*)
            printf '%s\n' "$_candidate_url" "https://ghproxy.net/$_candidate_url"
            ;;
        https://github.com/*/archive/refs/tags/*.tar.gz|https://github.com/*/archive/refs/heads/*.tar.gz)
            _archive_rest=${_candidate_url#https://github.com/}
            _archive_repo=${_archive_rest%%/archive/*}
            _archive_tail=${_archive_rest#*/archive/}
            _archive_tail=${_archive_tail%.tar.gz}
            printf '%s\n' "$_candidate_url"
            if [ -n "$_archive_repo" ] && [ -n "$_archive_tail" ]; then
                printf '%s\n' "https://codeload.github.com/$_archive_repo/tar.gz/$_archive_tail"
            fi
            printf '%s\n' "https://ghproxy.net/$_candidate_url"
            ;;
        https://api.github.com/*|https://*.github.io/*|http://*.github.io/*)
            printf '%s\n' "$_candidate_url" "https://ghproxy.net/$_candidate_url"
            ;;
        *) printf '%s\n' "$_candidate_url" ;;
    esac
}

fetch() {
    _fetch_original_url=$1
    _fetch_out=$2
    _fetch_timeout=${3:-240}
    case "$_fetch_timeout" in ''|*[!0-9]*) _fetch_timeout=240 ;; esac
    ensure_network || { rm -f "$_fetch_out"; return 1; }
    _fetch_candidates=$(fetch_url_candidates "$_fetch_original_url")
    for _fetch_candidate in $_fetch_candidates; do
        rm -f "$_fetch_out"
        _fetch_ok=0
        _curl_path=$(command -v curl 2>/dev/null || printf '')
        if [ -n "$_curl_path" ] && [ -x "$_curl_path" ]; then
            _http_code=$("$_curl_path" -L -sS --fail --connect-timeout 8 --max-time "$_fetch_timeout" -o "$_fetch_out" -w '%{http_code}' "$_fetch_candidate" 2>/dev/null) || _http_code=''
            case "$_http_code" in 2??) [ -s "$_fetch_out" ] && _fetch_ok=1 ;; esac
        fi
        if [ "$_fetch_ok" -ne 1 ]; then
            rm -f "$_fetch_out"
            _wget_path=$(command -v wget 2>/dev/null || printf '')
            if [ -n "$_wget_path" ] && [ -x "$_wget_path" ] && "$_wget_path" -q -T "$_fetch_timeout" -O "$_fetch_out" "$_fetch_candidate"; then
                [ -s "$_fetch_out" ] && _fetch_ok=1
            fi
        fi
        if [ "$_fetch_ok" -eq 1 ] && ! head -c 256 "$_fetch_out" 2>/dev/null | grep -qiE '404: Not Found|502 Bad Gateway|503 Service Unavailable'; then
            _FETCH_FAIL_COUNT=0
            return 0
        fi
        rm -f "$_fetch_out"
    done
    _FETCH_FAIL_COUNT=$(( ${_FETCH_FAIL_COUNT:-0} + 1 ))
    if [ "$_FETCH_FAIL_COUNT" -ge 2 ]; then _TRANSPORT_TLS_CACHED=''; fi
    say "${YELLOW}Не удалось скачать файл с основного адреса и доступных зеркал: $_fetch_original_url${RESET}"
    return 1
}
normalize_arch() {
    # Схема как в nfqws-menu: сначала архитектура opkg, затем opkg.conf,
    # uname -m используется только как fallback; ARM 32-bit не выдаём за aarch64.
    case "$1" in
        aarch64*|arm64*) echo aarch64 ;;
        armv7*|armv6*|arm*) echo '' ;;
        mipsel*|mipselsf*|mips64el*) echo mipsel ;;
        mips*|mipssf*) echo mips ;;
        x86_64*|amd64*|x64*) echo x86_64 ;;
        i[3-6]86*|x86*|i686*) echo x86 ;;
        *) echo '' ;;
    esac
}
_arch_pick_best() {
    awk '$1=="arch" && $2!="" && $2!="all" && $2!="noarch" {p=$3+0; n=$2; bonus=0; if(n~/^mipsel/ || n~/^mipselsf/ || n~/^mips64el/ || n~/^aarch64/ || n~/^arm64/)bonus=2; score=p*10+bonus; if(score>best){best=score; name=n}} END{if(name!="")print name}'
}
_arch_from_opkg_conf() {
    _conf="${1:-/opt/etc/opkg.conf}"
    [ "${INTERRUPTED:-0}" = 0 ] || { printf "%s\n" "Архитектура не определена: операция прервана." >&2; return 1; }
    [ -r "$_conf" ] || return 0
    _name=$(grep -E '^[[:space:]]*arch[[:space:]]+' "$_conf" 2>/dev/null | _arch_pick_best)
    if [ -n "$_name" ]; then printf '%s\n' "$_name"; return 0; fi
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            src/gz*|src\ *)
                case "$_line" in
                    *mipselsf*|*mips64el*) echo mipselsf; return 0 ;;
                    *mipssf*) echo mipssf; return 0 ;;
                    *mipsel*) echo mipsel; return 0 ;;
                    *aarch64*|*arm64*) echo aarch64; return 0 ;;
                    *x86_64*|*/x64*) echo x86_64; return 0 ;;
                    *i386*|*/x86*) echo x86; return 0 ;;
                    *mips*) echo mips; return 0 ;;
                esac
                ;;
        esac
    done < "$_conf"
}
get_arch() {
    _raw=$(opkg print-architecture 2>/dev/null | _arch_pick_best)
    _arch=$(normalize_arch "$_raw")
    if [ -z "$_arch" ]; then
        _raw=$(_arch_from_opkg_conf /opt/etc/opkg.conf) || return $?
        _arch=$(normalize_arch "$_raw")
    fi
    if [ -z "$_arch" ]; then
        _u=$(uname -m 2>/dev/null || :)
        case "$_u" in mips|mipsel|mips64|mips64el|'') _arch='' ;; *) _arch=$(normalize_arch "$_u") ;; esac
    fi
    printf '%s' "$_arch"
}
rci_json() {
    _rci=''
    if command -v curl >/dev/null 2>&1 && [ -x "$(command -v curl 2>/dev/null)" ]; then
        _rci=$(curl -fLsS --connect-timeout 2 --max-time 3 http://127.0.0.1:79/rci/show/version 2>/dev/null) || _rci=''
    fi
    if [ -z "$_rci" ] && command -v wget >/dev/null 2>&1; then _rci=$(wget -qO- -T 3 http://127.0.0.1:79/rci/show/version 2>/dev/null) || _rci=''; fi
    [ -n "$_rci" ] && printf '%s\n' "$_rci"
}
_json_value() {
    _key="$1"; _json="$2"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$_json" | jq -r --arg k "$_key" '.[$k] // empty' 2>/dev/null | head -n 1
    else
        _pattern="\"${_key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\""
        printf '%s\n' "$_json" | grep -oE "$_pattern" | head -n 1 |
            sed 's/^[^:]*:[[:space:]]*//; s/^\"//; s/\"$//'
    fi
}
get_router() {
    _json=$(rci_json)
    _model=$(_json_value model "$_json")
    _title=$(_json_value title "$_json")
    _fallback=''
    _device_model=''
    _compat=''
    if [ -r /proc/device-tree/model ]; then _device_model=$(tr -d '\000\r\n' < /proc/device-tree/model 2>/dev/null); fi
    if [ -r /proc/device-tree/compatible ]; then _compat=$(tr '\000' '\n' < /proc/device-tree/compatible 2>/dev/null); fi
    if [ -z "$_model" ] || [ -z "$_title" ]; then
        if command -v ndmc >/dev/null 2>&1; then _fallback=$(LD_LIBRARY_PATH=/lib:/usr/lib ndmc -c 'show version' 2>/dev/null); fi
    fi
    [ -n "$_model" ] || _model=$(printf '%s\n' "$_fallback" | grep -iE 'Hopper|NC[- ]?3811|KN[- ]?3811|Model:|Модель:' | head -n 1 | sed 's/^[[:space:]]*//')
    [ -n "$_model" ] || _model="$_device_model"
    case "$_model $_device_model $_compat $_json $_fallback" in
        *NC-3811*|*NC3811*|*KN-3811*|*KN3811*|*nc-3811*|*kn-3811*) _model='Hopper (NC-3811)' ;;
        *Hopper*|*hopper*) _model='Hopper' ;;
    esac
    if [ -z "$_title" ]; then
        _title=$(printf '%s\n' "$_fallback" | grep -iE 'KeeneticOS|NDMS|Version:|версия' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    fi
    [ -n "$_model" ] || _model='Keenetic/Netcraze (не определён)'
    [ -n "$_title" ] || _title='версия не определена'
    _model=$(printf '%s' "$_model" | tr '|' '/')
    _title=$(printf '%s' "$_title" | tr '|' '/')
    printf '%s|%s' "$_model" "$_title"
}
backup_file() {
    _f="$1"
    [ -L "$_f" ] && { say "${YELLOW}Бэкап симлинка пропущен: $_f${RESET}"; return 1; }
    [ -e "$_f" ] || return 0
    [ -f "$_f" ] || return 0
    mkdir -p "$BACKUP_DIR" || return 1
    _ts=$(date '+%Y%m%d-%H%M%S' 2>/dev/null); [ -n "$_ts" ] || _ts="backup-$$"
    _dest="$BACKUP_DIR/$(basename "$_f").$_ts.bak"
    cp -p "$_f" "$_dest" || { say "${RED}Не удалось создать бэкап $_f${RESET}"; return 1; }
    say "${MUTED}Бэкап: $_dest${RESET}"
}
backup_configs() {
    mkdir -p "$BACKUP_DIR" || return 1
    _ts=$(date '+%Y%m%d-%H%M%S' 2>/dev/null); [ -n "$_ts" ] || _ts="backup-$$"
    set --
    for _p in /opt/etc/nfqws/nfqws.conf /opt/etc/nfqws2/nfqws2.conf /opt/etc/nfqws2/blobs/*.bin /opt/etc/nfqws2/*.bin /opt/etc/nfqws/*.bin /opt/etc/xkeen; do
        [ -e "$_p" ] && [ ! -L "$_p" ] && set -- "$@" "$_p"
    done
    [ "$#" -gt 0 ] || { say 'Конфигурации для бэкапа не найдены.'; return 0; }
    if command -v gzip >/dev/null 2>&1; then
        _archive="$BACKUP_DIR/configs-$_ts.tar.gz"
        tar -czf "$_archive" "$@"
    else
        _archive="$BACKUP_DIR/configs-$_ts.tar"
        say "${YELLOW}gzip не найден; создаю несжатый tar-архив.${RESET}"
        tar -cf "$_archive" "$@"
    fi
    _tar_rc=$?
    if [ "$_tar_rc" -ne 0 ] || [ ! -s "$_archive" ]; then
        rm -f "$_archive"
        say "${RED}Не удалось создать архив конфигураций (tar=$_tar_rc).${RESET}"
        return 1
    fi
    say "${GREEN}Бэкап: $_archive${RESET}"
}

install_nfqws2() {
    line; say "${CYAN}nfqws2${RESET} — движок обхода DPI"
    ensure_network || return 1
    _arch=$(get_arch) || { say "${RED}Не удалось определить архитектуру Entware.${RESET}"; return 1; }
    case "$_arch" in aarch64|armv7|mipsel|mips|x86_64|x86) ;; *) say "${RED}Не удалось надёжно определить архитектуру Entware.${RESET}"; return 1;; esac
    if is_installed nfqws-keenetic; then
        say "${YELLOW}Найден старый nfqws-keenetic v1; версии используют разные конфиги.${RESET}"
        if confirm 'Удалить старый NFQWS v1 и его Web UI для перехода на v2?'; then
            [ -x /opt/etc/init.d/S51nfqws ] && /opt/etc/init.d/S51nfqws stop >/dev/null 2>&1 || :
            for _pkg in nfqws-keenetic-web nfqws-keenetic; do
                if is_installed "$_pkg"; then opkg remove "$_pkg" || return 1; fi
            done
        else
            say 'Оставляю v1; установка v2 отменена.'; return 1
        fi
    fi
    opkg install ca-certificates wget-ssl >/dev/null 2>&1 || :
    mkdir -p /opt/etc/opkg
    printf 'src/gz nfqws2-keenetic %s/%s\n' "$NFQWS2_REPO_BASE" "$_arch" > /opt/etc/opkg/nfqws2-keenetic.conf || return 1
    opkg update || return 1
    if is_installed nfqws2-keenetic; then opkg upgrade nfqws2-keenetic; else opkg install nfqws2-keenetic; fi
}
port_state() {
    _port="$1"
    case "$_port" in *[!0-9]*|'') return 2 ;; esac
    _checked=0
    if command -v netstat >/dev/null 2>&1; then
        _checked=1
        netstat -lnt 2>/dev/null | grep -qE "[.:]${_port}[[:space:]]" && return 0
    fi
    if command -v ss >/dev/null 2>&1; then
        _checked=1
        ss -lnt 2>/dev/null | grep -qE "[.:]${_port}([[:space:]]|$)" && return 0
    fi
    _hex=$(printf '%04X' "$_port")
    if [ -r /proc/net/tcp ] || [ -r /proc/net/tcp6 ]; then
        _checked=1
        { cat /proc/net/tcp /proc/net/tcp6 2>/dev/null; } |
            awk -v p="$_hex" '$2 ~ ":"p"$" && $4=="0A" {found=1} END{exit(found?0:1)}' && return 0
    fi
    [ "$_checked" -eq 1 ] && return 1
    return 2
}

install_nf_web() {
    line; say "${CYAN}nfqws-web-keenetic${RESET}"
    ensure_network || return 1
    port_state 90
    _ps=$?
    case "$_ps" in
        0) say "${YELLOW}Порт TCP 90 уже слушается. Возможен конфликт с другой панелью.${RESET}"; confirm 'Продолжить установку NFQWS Web?' || return 1 ;;
        1) : ;;
        2) say "${YELLOW}Не удалось определить состояние TCP 90 (нет netstat/ss и procfs). Продолжить с осторожностью.${RESET}"; confirm 'Продолжить?' || return 1 ;;
    esac
    if ! is_installed nfqws2-keenetic && ! is_installed nfqws-keenetic; then
        if [ "$(get_ui_lang)" = en ]; then say 'Install nfqws2 (menu option 4) or NFQWS v1 first.'; else say 'Сначала установи nfqws2 (пункт 4) или NFQWS v1.'; fi
        return 1
    fi
    opkg install ca-certificates wget-ssl >/dev/null 2>&1 || :
    mkdir -p /opt/etc/opkg
    printf 'src/gz nfqws-keenetic-web %s\n' "$NFQWS_WEB_REPO" > /opt/etc/opkg/nfqws-keenetic-web.conf || return 1
    opkg update || return 1
    if is_installed nfqws-keenetic-web; then opkg upgrade nfqws-keenetic-web; else opkg install nfqws-keenetic-web; fi
}
install_nf_web2() {
    # БЕЗОПАСНОСТЬ: скачиваемый скрипт не имеет независимой криптографической проверки.
    # Закрепление URL за commit SHA — задача v2.5.0.
    line; say "${CYAN}nfqws-ui${RESET}"
    ensure_network || return 1
    is_installed nfqws2-keenetic || { say 'Сначала установи nfqws2.'; return 1; }
    _tmp="$ROOT_DIR/nfqws2-ui-install.$$"
    fetch "$NFQWS2_UI_INSTALLER" "$_tmp" || { rm -f "$_tmp"; say 'Не удалось скачать установщик.'; return 1; }
    grep -qi 'nfqws2-ui' "$_tmp" && grep -qi 'sha256' "$_tmp" && sh -n "$_tmp" || { rm -f "$_tmp"; say 'Проверка установщика не пройдена.'; return 1; }
    if [ -r /dev/tty ]; then sh "$_tmp" </dev/tty; else sh "$_tmp"; fi
    _rc=$?; rm -f "$_tmp"; drain_stdin; return "$_rc"
}
require_space() {
    _needed_kb="$1"
    _avail=$(df -Pk /opt 2>/dev/null | awk 'NR==2 {print $4; exit}')
    case "$_avail" in ''|*[!0-9]*)
        say "${YELLOW}Не удалось определить свободное место в /opt.${RESET}"
        confirm 'Продолжить без проверки места?' || return 1
        return 0
        ;;
    esac
    if [ "$_avail" -lt "$_needed_kb" ]; then
        say "${RED}Недостаточно места в /opt: ${_avail} KiB, нужно не менее ${_needed_kb} KiB.${RESET}"
        return 1
    fi
}
latest_tag() {
    _repo="$1"; _jsonfile="$2"
    fetch "https://api.github.com/repos/$_repo/releases/latest" "$_jsonfile" || {
        say "${RED}Не удалось получить latest release: $_repo${RESET}"
        return 1
    }
    if command -v jq >/dev/null 2>&1; then
        _tag=$(jq -er '.tag_name // empty' "$_jsonfile" 2>/dev/null | head -n 1)
    else
        _tag=$(grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' "$_jsonfile" | head -n 1 | sed 's/.*:[[:space:]]*"//;s/"$//')
    fi
    case "$_tag" in ''|null|*[!A-Za-z0-9._+-]*) say "${RED}Некорректный тег релиза $_repo: $_tag${RESET}"; return 1 ;; esac
    printf '%s' "$_tag"
}
xkeen_channel() {
    _marker="$ROOT_DIR/xkeen-channel"
    if [ -r "$_marker" ]; then
        _saved=$(sed -n '1p' "$_marker" | tr -d '\r')
        case "$_saved" in Stable|Beta) printf '%s' "$_saved"; return 0 ;; esac
    fi
    # Проверяем только настройки и маркеры канала, а не скрипт установки XKeen,
    # в котором Stable и Beta закономерно встречаются одновременно.
    for _f in /opt/etc/xkeen/xkeen.json /opt/etc/xkeen/channel /opt/etc/xkeen/xkeen-channel /opt/sbin/.xkeen/channel; do
        [ -f "$_f" ] || continue
        if grep -iE 'XKEEN_CHANNEL.*beta|"channel".*beta|channel[[:space:]]*:[[:space:]]*beta' "$_f" >/dev/null 2>&1; then
            printf '%s' 'Beta'; return 0
        fi
        if grep -iE 'XKEEN_CHANNEL.*stable|"channel".*stable|channel[[:space:]]*:[[:space:]]*stable' "$_f" >/dev/null 2>&1; then
            printf '%s' 'Stable'; return 0
        fi
    done
    printf '%s' 'не удалось определить'
}
install_xkeen_stable_binary() {
    # БЕЗОПАСНОСТЬ: скачиваемый скрипт не имеет независимой криптографической проверки.
    # Закрепление URL за commit SHA — задача v2.5.0.
    ensure_network || return 1
    require_space 120000 || return 1
    _src="$ROOT_DIR/install-xkeen-upstream.$$"
    _auto="$ROOT_DIR/install-xkeen-stable-auto.$$"
    fetch "$XKEEN_INSTALLER" "$_src" || { rm -f "$_src"; say "${RED}Не скачан официальный XKeen install.sh.${RESET}"; return 1; }
    grep -q 'url_stable=' "$_src" && grep -q 'exec /opt/sbin/xkeen -i' "$_src" && sh -n "$_src" || {
        rm -f "$_src"; say "${RED}Структура официального установщика изменилась; запуск отменён.${RESET}"; return 1;
    }
    # Оставляем официальный Stable-загрузчик и проверку архива, но пропускаем его интерактивный первый -i.
    sed 's#^exec /opt/sbin/xkeen -i$#exit 0#' "$_src" > "$_auto" || { rm -f "$_src" "$_auto"; return 1; }
    grep -q '^exit 0$' "$_auto" && ! grep -q '^exec /opt/sbin/xkeen -i$' "$_auto" && sh -n "$_auto" || {
        rm -f "$_src" "$_auto"; say "${RED}Не удалось подготовить неинтерактивный запуск Stable-инсталлятора.${RESET}"; return 1;
    }
    say 'Устанавливаю XKeen из официального Stable-релиза...'
    mkdir -p /opt/tmp || { say "${RED}Не удалось создать /opt/tmp.${RESET}"; rm -f "$_src" "$_auto"; return 1; }
    (cd /opt/tmp && sh "$_auto" --stable)
    _rc=$?
    rm -f "$_src" "$_auto"
    [ "$_rc" -eq 0 ] && [ -x /opt/sbin/xkeen ] || { say "${RED}Установка XKeen Stable завершилась с ошибкой (код $_rc).${RESET}"; return 1; }
    printf '%s\n' 'Stable' > "$ROOT_DIR/xkeen-channel" || say "${YELLOW}Не удалось записать маркер канала XKeen.${RESET}"
    return 0
}
# Настраивает ежедневное обновление геофайлов XKeen в 04:30 по времени роутера.
# Команда -ug обновляет геофайлы GeoIP/GeoSite, используемые XKeen и GeoIPSet.
ensure_geoipset_cron() {
    if ! command -v crontab >/dev/null 2>&1; then
        say "${RED}Не найден crontab: не удалось назначить обновление GeoIP/GeoIPSet на 04:30.${RESET}"
        return 1
    fi
    if [ ! -x /opt/sbin/xkeen ]; then
        say "${RED}Не найден /opt/sbin/xkeen; расписание GeoIPSet не создано.${RESET}"
        return 1
    fi
    mkdir -p "$ROOT_DIR" /opt/var/log || return 1
    _GIP_CRON_CURRENT="$ROOT_DIR/crontab-geoipset-current.$$"
    _GIP_CRON_NEXT="$ROOT_DIR/crontab-geoipset-next.$$"
    crontab -l > "$_GIP_CRON_CURRENT" 2>/dev/null || : > "$_GIP_CRON_CURRENT"
    grep -Fv 'XMENU_GEOIPSET_DAILY_0430' "$_GIP_CRON_CURRENT" > "$_GIP_CRON_NEXT" || :
    printf '%s\n' '30 4 * * * /opt/sbin/xkeen -ug >> /opt/var/log/xkeen-geoipset-update.log 2>&1 # XMENU_GEOIPSET_DAILY_0430' >> "$_GIP_CRON_NEXT" || {
        rm -f "$_GIP_CRON_CURRENT" "$_GIP_CRON_NEXT"
        return 1
    }
    if ! crontab "$_GIP_CRON_NEXT"; then
        rm -f "$_GIP_CRON_CURRENT" "$_GIP_CRON_NEXT"
        say "${RED}Не удалось сохранить cron для обновления GeoIP/GeoIPSet.${RESET}"
        return 1
    fi
    rm -f "$_GIP_CRON_CURRENT" "$_GIP_CRON_NEXT"
    say "${GREEN}Автообновление GeoIP/GeoIPSet настроено: ежедневно в 04:30 по времени роутера.${RESET}"
    return 0
}

install_xkeen_auto() {
    line; say "${GREEN}XKeen Auto${RESET} — Stable + Xray + Mihomo + GeoIPSet + автозагрузка"
    ensure_base || return 1
    require_space 120000 || return 1

    if [ ! -x /opt/sbin/xkeen ]; then
        install_xkeen_stable_binary || return 1
    else
        _channel=$(xkeen_channel)
        case "$_channel" in
            Stable)
                say "${GREEN}Канал XKeen: Stable.${RESET}"
                ;;
            Beta|'Beta/не-Stable')
                say "${YELLOW}Обнаружен канал XKeen Beta; этот автоматический установщик поддерживает только Stable.${RESET}"
                if confirm 'Заменить текущую установку официальной Stable-версией?'; then
                    install_xkeen_stable_binary || return 1
                else
                    say 'Отменено; ядра и настройки не менялись.'
                    return 1
                fi
                ;;
            *)
                say "${YELLOW}Канал XKeen не удалось подтвердить: $_channel.${RESET}"
                if confirm 'Переустановить официальный Stable-релиз перед обновлением ядер?'; then
                    install_xkeen_stable_binary || return 1
                else
                    say 'Отменено: без подтверждённого Stable обновление остановлено.'
                    return 1
                fi
                ;;
        esac
    fi

    [ -x /opt/sbin/xkeen ] || { say "${RED}Не найден /opt/sbin/xkeen после установки.${RESET}"; return 1; }

    WORK="$ROOT_DIR/work-xkeen-$$"
    [ -z "$WORK" ] || mkdir -p "$WORK" || return 1
    _xr_tag=$(latest_tag XTLS/Xray-core "$WORK/xray-release.json") || { cleanup; return 1; }
    _mh_tag=$(latest_tag MetaCubeX/mihomo "$WORK/mihomo-release.json") || { cleanup; return 1; }

    say "Устанавливаю Xray: $_xr_tag"
    /opt/sbin/xkeen -ux "$_xr_tag"
    _rc=$?
    [ "$_rc" -eq 0 ] || { say "${RED}Установка Xray $_xr_tag завершилась с кодом $_rc.${RESET}"; cleanup; return "$_rc"; }

    say "Устанавливаю Mihomo: $_mh_tag"
    /opt/sbin/xkeen -um "$_mh_tag"
    _rc=$?
    [ "$_rc" -eq 0 ] || { say "${RED}Установка Mihomo $_mh_tag завершилась с кодом $_rc.${RESET}"; cleanup; return "$_rc"; }

    say 'Настраиваю автоматический режим, GeoIP/GeoIPSet, cron и автозагрузку...'
    /opt/sbin/xkeen -i auto cores=none geo=on geoipset=on cron=on autostart=on
    _rc=$?
    cleanup
    if [ "$_rc" -ne 0 ]; then
        say "${RED}XKeen установил ядра, но настройка auto/GeoIPSet/cron/autostart завершилась с кодом $_rc.${RESET}"
        return "$_rc"
    fi
    ensure_geoipset_cron || { say "${YELLOW}XKeen настроен, но расписание GeoIP/GeoIPSet не установлено.${RESET}"; return 1; }
    printf '%s\n' 'Stable' > "$ROOT_DIR/xkeen-channel" || :
    say "${GREEN}XKeen Stable/Auto завершён: Xray $_xr_tag; Mihomo $_mh_tag; GeoIPSet, ежедневное обновление 04:30 и автозагрузка настроены.${RESET}"
    return 0
}
# Готовит стабильную установку XKeen для ручного профиля.
ensure_xkeen_profile_ready() {
    ensure_network || return 1
    require_space 120000 || return 1
    if [ ! -x /opt/sbin/xkeen ]; then
        install_xkeen_stable_binary || return 1
    else
        _profile_channel=$(xkeen_channel)
        case "$_profile_channel" in
            Stable) : ;;
            Beta|'Beta/не-Stable')
                say "${YELLOW}Обнаружен канал XKeen Beta; профиль рассчитан на Stable.${RESET}"
                confirm_no 'Переустановить XKeen Stable?' || return 1
                install_xkeen_stable_binary || return 1
                ;;
            *)
                say "${YELLOW}Канал XKeen не удалось подтвердить.${RESET}"
                confirm_no 'Переустановить XKeen Stable перед настройкой профиля?' || return 1
                install_xkeen_stable_binary || return 1
                ;;
        esac
    fi
    [ -x /opt/sbin/xkeen ] || { say "${RED}Не найден /opt/sbin/xkeen.${RESET}"; return 1; }
    return 0
}

# Устанавливает только выбранное ядро; уже установленное другое ядро автоматически не удаляется.
install_xkeen_core_profile() {
    _profile_core=$1
    case "$_profile_core" in
        mihomo) _profile_repo='MetaCubeX/mihomo'; _profile_label='Mihomo' ;;
        xray) _profile_repo='XTLS/Xray-core'; _profile_label='Xray' ;;
        *) say 'Неизвестный профиль XKeen.'; return 2 ;;
    esac
    line
    say "${GREEN}Ручная настройка XKeen Auto — $_profile_label${RESET}"
    say 'Выбранное ядро будет установлено/обновлено; другое ранее установленное ядро автоматически не удаляется.'
    ensure_xkeen_profile_ready || return 1
    WORK="$ROOT_DIR/work-xkeen-profile-$$"
    mkdir -p "$WORK" || { cleanup; return 1; }
    _profile_tag=$(latest_tag "$_profile_repo" "$WORK/release.json") || { cleanup; return 1; }
    say "Устанавливаю/обновляю $_profile_label: $_profile_tag"
    case "$_profile_core" in
        mihomo) /opt/sbin/xkeen -um "$_profile_tag" ;;
        xray) /opt/sbin/xkeen -ux "$_profile_tag" ;;
    esac
    _profile_rc=$?
    if [ "$_profile_rc" -ne 0 ]; then
        cleanup
        say "${RED}Установка $_profile_label завершилась с кодом $_profile_rc.${RESET}"
        return "$_profile_rc"
    fi
    say 'Настраиваю GeoIP/GeoIPSet, cron и автозагрузку XKeen...'
    /opt/sbin/xkeen -i auto cores=none geo=on geoipset=on cron=on autostart=on
    _profile_rc=$?
    cleanup
    if [ "$_profile_rc" -ne 0 ]; then
        say "${RED}Настройка XKeen Auto завершилась с кодом $_profile_rc.${RESET}"
        return "$_profile_rc"
    fi
    ensure_geoipset_cron || { say "${YELLOW}Ядро установлено, но расписание GeoIP/GeoIPSet не удалось сохранить.${RESET}"; return 1; }
    printf '%s\n' 'Stable' > "$ROOT_DIR/xkeen-channel" 2>/dev/null || :
    say "${GREEN}Профиль XKeen Auto ($_profile_label + GeoIPSet + ежедневное обновление 04:30) завершён.${RESET}"
    return 0
}

# Полный профиль дополнительно устанавливает XKeen UI, NFQWS2 и NFQWS Web.
install_manual_bundle_profile() {
    _bundle_core=$1
    case "$_bundle_core" in
        mihomo) _bundle_label='Mihomo + GeoIPSet + XKeen Auto + XKeen UI + nfqws2 + NFQWS Web' ;;
        xray) _bundle_label='Xray + GeoIPSet + XKeen Auto + XKeen UI + nfqws2 + NFQWS Web' ;;
        *) say 'Неизвестный профиль установки.'; return 2 ;;
    esac
    line
    say "${WHITE}РУЧНОЙ ПРОФИЛЬ: $_bundle_label${RESET}"
    install_xkeen_core_profile "$_bundle_core" || return $?
    install_xkeen_ui || { _bundle_rc=$?; say "${RED}Профиль остановлен: не удалось установить XKeen UI (код $_bundle_rc).${RESET}"; return "$_bundle_rc"; }
    install_nfqws2 || { _bundle_rc=$?; say "${RED}Профиль остановлен: не удалось установить nfqws2 (код $_bundle_rc).${RESET}"; return "$_bundle_rc"; }
    install_nf_web || { _bundle_rc=$?; say "${RED}Профиль остановлен: не удалось установить NFQWS Web (код $_bundle_rc).${RESET}"; return "$_bundle_rc"; }
    say "${GREEN}Полный ручной профиль установлен: $_bundle_label.${RESET}"
    return 0
}

install_xkeen() {
    install_xkeen_auto
}

install_xkeen_ui() {
    # БЕЗОПАСНОСТЬ: скачиваемый скрипт не имеет независимой криптографической проверки.
    # Закрепление URL за commit SHA — задача v2.5.0.
    line; say "${GREEN}XKeen UI — zxc-rv${RESET}"
    ensure_network || return 1
    [ -x /opt/sbin/xkeen ] || { say 'Сначала установи XKeen.'; return 1; }
    if xkeen_ui_is_installed; then
        say "${YELLOW}Уже обнаружена панель XKeen UI. Установщик zxc-rv может заменить файлы панели и изменить конфигурацию lighttpd.${RESET}"
        confirm 'Продолжить запуск установщика XKeen UI zxc-rv?' || { say 'Отменено.'; return 1; }
    fi
    _tmp="$ROOT_DIR/xkeen-ui-install.$$"
    fetch "$XKEEN_UI_INSTALLER" "$_tmp" || { rm -f "$_tmp"; say 'Не удалось скачать XKeen UI.'; return 1; }
    grep -q 'XKEENUI_BIN=' "$_tmp" && sh -n "$_tmp" || { rm -f "$_tmp"; say 'Проверка установщика XKeen UI не пройдена.'; return 1; }
    say 'В штатном меню выбери 1 для установки или 2 для обновления.'
    if [ -r /dev/tty ]; then sh "$_tmp" </dev/tty; else sh "$_tmp"; fi
    _rc=$?; rm -f "$_tmp"; drain_stdin; return "$_rc"
}


install_xkeen_ui_umarcheh001() {
    # Архив сверяется с опубликованной SHA-256; подпись издателя отдельно не проверяется.
    line
    say "${GREEN}XKeen UI — umarcheh001${RESET}"
    ensure_network || return 1
    xkeen_is_installed || { say 'Сначала установи XKeen.'; return 1; }
    if xkeen_ui_zxc_is_installed; then
        say "${YELLOW}Уже обнаружена панель zxc-rv. Эти два варианта UI могут конфликтовать по интерфейсу и обслуживанию.${RESET}"
        confirm 'Продолжить установку/замену на вариант umarcheh001?' || { say 'Отменено.'; return 1; }
    elif xkeen_ui_umar_is_installed; then
        confirm 'Обновить XKeen UI umarcheh001?' || { say 'Отменено.'; return 1; }
    fi
    _uiwork="$ROOT_DIR/xkeen-ui-umar-$$"
    _uiarchive="$_uiwork/xkeen-ui-routing.tar.gz"
    _uichecksum="$_uiwork/xkeen-ui-routing.tar.gz.sha256"
    _uistage="$_uiwork/stage"
    _uibackup=''
    rm -rf "$_uiwork"
    mkdir -p "$_uistage" "$BACKUP_DIR" || { rm -rf "$_uiwork"; return 1; }
    _uiurl='https://github.com/umarcheh001/Xkeen-UI/releases/latest/download/xkeen-ui-routing.tar.gz'
    fetch "$_uiurl" "$_uiarchive" || { rm -rf "$_uiwork"; say 'Не удалось скачать архив XKeen UI umarcheh001.'; return 1; }
    fetch "$_uiurl.sha256" "$_uichecksum" || { rm -rf "$_uiwork"; say 'Не удалось получить SHA-256 архива; установка отменена.'; return 1; }
    _uiexpected=$(awk 'NF {for (i=1;i<=NF;i++) if (length($i)==64 && $i ~ /^[0-9A-Fa-f]+$/) {print $i; exit}}' "$_uichecksum")
    case "$_uiexpected" in *[!0-9A-Fa-f]*|'') rm -rf "$_uiwork"; say 'Файл контрольной суммы имеет неверный формат.'; return 1 ;; esac
    [ "${#_uiexpected}" -eq 64 ] || { rm -rf "$_uiwork"; say 'Длина контрольной суммы неверна.'; return 1; }
    sha_ok "$_uiarchive" "$_uiexpected" || { rm -rf "$_uiwork"; say "${RED}SHA-256 архива не совпала; установка отменена.${RESET}"; return 1; }
    command -v tar >/dev/null 2>&1 || { rm -rf "$_uiwork"; say 'Команда tar не найдена.'; return 1; }
    tar -tzf "$_uiarchive" > "$_uiwork/archive.list" 2>/dev/null || { rm -rf "$_uiwork"; say 'Архив повреждён или не поддерживается tar.'; return 1; }
    awk '
        BEGIN { bad=0; found=0 }
        {
            p=$0
            sub(/\/$/, "", p)
            if (p=="xkeen-ui/install.sh") found=1
            if (p=="xkeen-ui") next
            if (substr(p,1,9)!="xkeen-ui/" || p ~ /^\// || p ~ /(^|\/)\.\.(\/|$)/ || p ~ /\/\//) bad=1
        }
        END { if (bad || !found) exit 1 }
    ' "$_uiwork/archive.list" || { rm -rf "$_uiwork"; say 'В архиве найдены неожиданные пути или отсутствует xkeen-ui/install.sh.'; return 1; }
    tar -tvzf "$_uiarchive" > "$_uiwork/archive.verbose" 2>/dev/null || { rm -rf "$_uiwork"; say 'Не удалось проверить типы файлов архива.'; return 1; }
    if awk 'substr($0,1,1)=="l" || substr($0,1,1)=="h" {bad=1} END{exit(bad?0:1)}' "$_uiwork/archive.verbose"; then
        rm -rf "$_uiwork"; say 'Архив содержит ссылки; извлечение отменено в целях безопасности.'; return 1
    fi
    tar -xzf "$_uiarchive" -C "$_uistage" || { rm -rf "$_uiwork"; say 'Не удалось распаковать архив.'; return 1; }
    [ -f "$_uistage/xkeen-ui/install.sh" ] || { rm -rf "$_uiwork"; say 'В распакованном архиве не найден install.sh.'; return 1; }
    if [ -d /opt/xkeen-ui ]; then
        _uitimestamp=$(date '+%Y%m%d-%H%M%S' 2>/dev/null || printf 'backup')
        _uibackup="$BACKUP_DIR/xkeen-ui-umarcheh001-$_uitimestamp.tar.gz"
        tar -czf "$_uibackup" -C /opt xkeen-ui || { rm -rf "$_uiwork"; say 'Не удалось сохранить резервную копию прежней панели.'; return 1; }
        _uiold="$_uiwork/xkeen-ui-old"
        mv /opt/xkeen-ui "$_uiold" || { rm -rf "$_uiwork"; say 'Не удалось переместить прежнюю панель.'; return 1; }
    else
        _uiold=''
    fi
    mv "$_uistage/xkeen-ui" /opt/xkeen-ui || {
        [ -n "$_uiold" ] && mv "$_uiold" /opt/xkeen-ui
        rm -rf "$_uiwork"; say 'Не удалось разместить файлы панели.'; return 1
    }
    say 'Запускаю официальный install.sh umarcheh001...'
    (cd /opt/xkeen-ui && sh ./install.sh)
    _uirc=$?
    if [ "$_uirc" -ne 0 ]; then
        say "${RED}Установщик завершился с кодом $_uirc.${RESET}"
        rm -rf /opt/xkeen-ui
        if [ -n "$_uiold" ] && [ -d "$_uiold" ]; then mv "$_uiold" /opt/xkeen-ui || :; fi
        rm -rf "$_uiwork"
        return "$_uirc"
    fi
    rm -rf "$_uiwork"
    say "${GREEN}Установка XKeen UI umarcheh001 завершена.${RESET}"
    [ -z "$_uibackup" ] || say "Резервная копия файлов панели: $_uibackup"
    return 0
}

install_dpi_detector() {
    # Официальный Rust-установщик сам выбирает ARM64-релиз, проверяет checksum и тестирует запуск.
    line; say "${CYAN}DPI Detector${RESET} — диагностика DPI/DNS"
    ensure_network || return 1
    _dpi_arch=$(get_arch) || { say "${RED}Не удалось определить архитектуру Entware.${RESET}"; return 1; }
    [ -n "$_dpi_arch" ] || { say "${RED}Не удалось определить архитектуру Entware.${RESET}"; return 1; }
    [ "$_dpi_arch" = aarch64 ] || {
        say "${RED}Официальный Rust DPI Detector требует aarch64; обнаружено: $_dpi_arch.${RESET}"
        return 1
    }
    _dpi_force=${1:-}
    if [ -x /opt/bin/dpi-detector ] && [ "$_dpi_force" != force ]; then
        say 'DPI Detector уже установлен.'
        confirm_no 'Обновить/переустановить официальную Rust-версию?' || return 0
    fi
    [ ! -L /opt/bin/dpi-detector ] || {
        say "${RED}/opt/bin/dpi-detector является симлинком; безопасная замена отменена.${RESET}"
        return 1
    }
    _dpi_work="$ROOT_DIR/dpi-rust-installer.$$"
    mkdir -p "$_dpi_work" /opt/bin || { rm -rf "$_dpi_work"; return 1; }
    _dpi_installer="$_dpi_work/install.sh"
    _dpi_installer_ok=0
    # Берём установщик из официальной ветки rust, затем пробуем зеркало CDN.
    for _dpi_installer_url in "$DPI_RUST_INSTALLER_URL" "$DPI_RUST_INSTALLER_MIRROR"; do
        rm -f "$_dpi_installer"
        if fetch "$_dpi_installer_url" "$_dpi_installer" 30 &&
           grep -q 'Runnin4ik/dpi-detector' "$_dpi_installer" &&
           grep -q 'dpi-detector-linux-arm64' "$_dpi_installer" &&
           sh -n "$_dpi_installer"; then
            _dpi_installer_ok=1
            break
        fi
    done
    if [ "$_dpi_installer_ok" != 1 ]; then
        rm -rf "$_dpi_work"
        say "${RED}Не удалось загрузить и проверить официальный Rust-установщик DPI Detector.${RESET}"
        say 'Ручная установка: curl -fsSL https://raw.githubusercontent.com/Runnin4ik/dpi-detector/rust/install.sh | sh'
        return 1
    fi
    if [ -f /opt/bin/dpi-detector ]; then
        backup_file /opt/bin/dpi-detector || { rm -rf "$_dpi_work"; return 1; }
    fi
    say 'Запускаю официальный Rust-установщик (загрузка с зеркал и проверка checksum выполняются самим установщиком)...'
    DPI_INSTALL_DIR=/opt/bin sh "$_dpi_installer"
    _dpi_install_rc=$?
    rm -rf "$_dpi_work"
    if [ "$_dpi_install_rc" -ne 0 ]; then
        say "${RED}Официальный установщик DPI Detector завершился с кодом $_dpi_install_rc.${RESET}"
        return "$_dpi_install_rc"
    fi
    [ -x /opt/bin/dpi-detector ] || {
        say "${RED}Установщик завершился, но /opt/bin/dpi-detector не найден или не исполняемый.${RESET}"
        return 1
    }
    _dpi_version=$(/opt/bin/dpi-detector --version 2>/dev/null | head -n 1)
    case "$_dpi_version" in *[0-9]*) : ;; *) _dpi_version='версия неизвестна' ;; esac
    printf '%s\n' "$_dpi_version" > "$ROOT_DIR/dpi-detector-version" 2>/dev/null || :
    rm -f "$ROOT_DIR/dpi-detector-native-incompatible" "$ROOT_DIR/dpi-detector-python-mode"
    # Убираем оставшиеся файлы неудачной старой Python/pip-попытки.
    rm -rf "$ROOT_DIR/dpi-detector-python" "$ROOT_DIR/dpi-detector-python-deps"
    rm -f "$ROOT_DIR/dpi-detector-pip.log"
    say "${GREEN}DPI Detector Rust установлен в /opt/bin/dpi-detector; checksum и запуск проверены установщиком.${RESET}"
    [ "$_dpi_version" = 'версия неизвестна' ] || say "Версия: $_dpi_version"
    return 0
}

_install_all_step() {
    # Возвращает: 0 = OK, 2 = шаг упал (но прерывания нет), 130 = прерывание.
    _step_label=$1
    shift
    [ "${INTERRUPTED:-0}" = 0 ] || {
        : > "$ROOT_DIR/first-run-attempted"
        say 'Первичная установка прервана.'
        return 130
    }
    "$@"
    _step_rc=$?
    if [ "$_step_rc" -eq 130 ] || [ "${INTERRUPTED:-0}" != 0 ]; then
        : > "$ROOT_DIR/first-run-attempted"
        say 'Первичная установка прервана.'
        return 130
    fi
    if [ "$_step_rc" -ne 0 ]; then
        say "${YELLOW}Не удалось выполнить шаг: $_step_label (код $_step_rc).${RESET}"
        return 2
    fi
    return 0
}
install_all_missing() {
    line; say "${WHITE}ПЕРВЫЙ ЗАПУСК — ПРОВЕРКА КОМПОНЕНТОВ${RESET}"; line
    say 'Уже установленные пакеты NFQWS и панели пропускаются. XKeen Auto обновит ядра и выполнит настройку GeoIPSet/autostart.'
    # XKEEN_MENU_AUTO_YES=1/true/yes/on отключает подтверждение только для дополнительного NFQWS2 UI.
    _failed=0
    [ "${INTERRUPTED:-0}" = 0 ] || { : > "$ROOT_DIR/first-run-attempted"; say 'Первичная установка прервана.'; return 130; }

    if is_installed nfqws2-keenetic; then say 'nfqws2 уже установлен — пропуск.'
    else
        _install_all_step 'nfqws2' install_nfqws2; _rc=$?
        case "$_rc" in 0) : ;; 130) return 130 ;; *) _failed=1 ;; esac
    fi
    if is_installed nfqws-keenetic-web; then say 'Оригинальная NFQWS Web уже установлена — пропуск.'
    else
        _install_all_step 'Оригинальная NFQWS Web' install_nf_web; _rc=$?
        case "$_rc" in 0) : ;; 130) return 130 ;; *) _failed=1 ;; esac
    fi
    _install_all_step 'XKeen Auto' install_xkeen_auto; _rc=$?
    case "$_rc" in 0) : ;; 130) return 130 ;; *) _failed=1 ;; esac
    if [ -x /opt/sbin/xkeen-ui ]; then say 'XKeen UI уже установлен — пропуск.'
    else
        _install_all_step 'XKeen UI' install_xkeen_ui; _rc=$?
        case "$_rc" in 0) : ;; 130) return 130 ;; *) _failed=1 ;; esac
    fi
    if is_installed nfqws2-ui || [ -x /opt/sbin/nfqws-ui-setup ]; then
        say 'Дополнительная nfqws2 UI уже установлена — пропуск.'
    elif auto_yes_enabled; then
        _install_all_step 'zemidala/nfqws2-ui' install_nf_web2; _rc=$?
        case "$_rc" in 0) : ;; 130) return 130 ;; *) _failed=1 ;; esac
    elif confirm 'Установить дополнительную zemidala/nfqws2-ui?'; then
        _install_all_step 'zemidala/nfqws2-ui' install_nf_web2; _rc=$?
        case "$_rc" in 0) : ;; 130) return 130 ;; *) _failed=1 ;; esac
    else
        say 'zemidala/nfqws2-ui пропущен: подтверждение не получено или установка отклонена.'
    fi
    if [ -x /opt/bin/dpi-detector ]; then say 'DPI Detector уже установлен — пропуск.'
    else
        _install_all_step 'DPI Detector' install_dpi_detector; _rc=$?
        case "$_rc" in 0) : ;; 130) return 130 ;; *) _failed=1 ;; esac
    fi
    if [ "${INTERRUPTED:-0}" != 0 ]; then : > "$ROOT_DIR/first-run-attempted"; say 'Первичная установка прервана.'; return 130; fi
    if [ "$_failed" -eq 0 ]; then
        : > "$ROOT_DIR/first-run-complete"
        rm -f "$ROOT_DIR/first-run-attempted"
        say "${GREEN}Проверка первого запуска завершена без ошибок.${RESET}"
        return 0
    fi
    say "${YELLOW}Проверка завершена с ошибками отдельных компонентов. Меню остаётся доступным; повтори нужный пункт вручную.${RESET}"
    : > "$ROOT_DIR/first-run-attempted"
    return 1
}

sha256_file() {
    [ -f "$1" ] || return 1
    _sha_out=''
    if command -v sha256sum >/dev/null 2>&1; then
        _sha_out=$(sha256sum "$1" 2>/dev/null) || return 1
        _sha_out=$(printf '%s\n' "$_sha_out" | awk 'NF {print $1; exit}')
    elif command -v openssl >/dev/null 2>&1; then
        _sha_out=$(openssl dgst -sha256 "$1" 2>/dev/null) || return 1
        _sha_out=$(printf '%s\n' "$_sha_out" | awk 'NF {print $NF; exit}')
    else return 1; fi
    case "$_sha_out" in *[!a-fA-F0-9]*|'') return 1 ;; esac
    [ "${#_sha_out}" -eq 64 ] || return 1
    printf '%s\n' "$_sha_out"
}
sha_ok() {
    _expected=$(printf '%s' "$2" | tr 'A-F' 'a-f')
    case "$_expected" in *[!0-9a-f]*|'') return 1 ;; esac
    [ "${#_expected}" -eq 64 ] || return 1
    _got=$(sha256_file "$1") || return 1
    _got=$(printf '%s' "$_got" | tr 'A-F' 'a-f')
    [ "$_got" = "$_expected" ]
}
verify_sum() { sha_ok "$1" "$2"; }
manifest_relpath() {
    # SHA256SUMS: 64 шестнадцатеричных символа, пробелы и путь (возможно со звёздочкой).
    printf '%s\n' "$1" | cut -c65- | sed 's/^[[:space:]]*//; s/^\*//'
}
sync_strategies() {
    # Сначала пытаемся подготовить сеть, но при сбое продолжаем с проверенным кэшем.
    _sync_can_fetch=1
    ensure_base || _sync_can_fetch=0
    mkdir -p "$CACHE_DIR/nfqws1" "$CACHE_DIR/nfqws2" "$CACHE_DIR/blobs" "$ROOT_DIR/manifests" || return 1
    _tmp="$ROOT_DIR/sync.$$"
    rm -rf "$_tmp"
    mkdir -p "$_tmp" || return 1
    _cached_manifest="$ROOT_DIR/manifests/SHA256SUMS"

    if [ "$_sync_can_fetch" = 1 ] && fetch "$NF_REPO/SHA256SUMS" "$_tmp/SHA256SUMS" 30 &&
       grep -Eq 'strategies/nfqws[12]/.*\.conf' "$_tmp/SHA256SUMS"; then
        mv "$_tmp/SHA256SUMS" "$_cached_manifest" || { rm -rf "$_tmp"; return 1; }
    elif [ -s "$_cached_manifest" ] && grep -Eq 'strategies/nfqws[12]/.*\.conf' "$_cached_manifest"; then
        say "${YELLOW}Использую сохранённый манифест стратегий.${RESET}"
    else
        rm -rf "$_tmp"
        say "${RED}Нет доступного манифеста стратегий и проверенного офлайн-кэша.${RESET}"
        return 1
    fi

    _cached_blob_manifest="$ROOT_DIR/manifests/blobs-SHA256SUMS"
    if [ "$_sync_can_fetch" = 1 ] && fetch "$NF_REPO/strategies/blobs/SHA256SUMS" "$_tmp/blobs.SHA256SUMS" 30 &&
       awk 'NF>=2 && length($1)==64 && $1 ~ /^[0-9a-fA-F]+$/ {n++} END {exit(n>0?0:1)}' "$_tmp/blobs.SHA256SUMS"; then
        mv "$_tmp/blobs.SHA256SUMS" "$_cached_blob_manifest" || { rm -rf "$_tmp"; return 1; }
    fi

    _manifest="$_cached_manifest"
    _sync_have_cache=0
    _sync_errors=0
    while IFS= read -r _entry || [ -n "$_entry" ]; do
        [ "${INTERRUPTED:-0}" = 0 ] || { rm -rf "$_tmp"; say 'Синхронизация прервана пользователем.'; return 130; }
        _hash=$(printf '%s' "$_entry" | cut -c1-64)
        _rel=$(manifest_relpath "$_entry")
        case "$_hash" in *[!a-fA-F0-9]*|'') continue ;; esac
        [ "${#_hash}" -eq 64 ] || continue
        case "$_rel" in
            strategies/nfqws1/*.conf|strategies/nfqws2/*.conf) ;;
            *) continue ;;
        esac
        case "$_rel" in /*|../*|*/../*|*/..|*//*) continue ;; esac
        _name=${_rel##*/}
        case "$_name" in ''|.|..|*/*|*..*|*'?'*|*'#'*|*'%'*|*'['*|*']'*|*'\'*) continue ;; esac
        printf '%s\n' "$_name" | LC_ALL=C grep -Eq '^[A-Za-z0-9_.+ -]+$' || continue
        case "$_rel" in
            strategies/nfqws1/*) _dest="$CACHE_DIR/nfqws1/$_name" ;;
            strategies/nfqws2/*) _dest="$CACHE_DIR/nfqws2/$_name" ;;
        esac
        if [ -s "$_dest" ] && verify_sum "$_dest" "$_hash"; then
            _sync_have_cache=1
            continue
        fi
        if [ "$_sync_can_fetch" = 1 ]; then
            _dl="$_tmp/strategy-download.$$"
            _url_rel=$(printf '%s' "$_rel" | sed 's/ /%20/g')
            if fetch "$NF_REPO/$_url_rel" "$_dl" 45 && verify_sum "$_dl" "$_hash"; then
                [ -f "$_dest" ] && backup_file "$_dest" || :
                if mv "$_dl" "$_dest"; then
                    _sync_have_cache=1
                else
                    rm -f "$_dl"
                    _sync_errors=$((_sync_errors + 1))
                fi
            else
                rm -f "$_dl"
                _sync_errors=$((_sync_errors + 1))
            fi
        fi
    done < "$_manifest"

    # Также считаем кэш доступным, если в нём есть хотя бы одна стратегия-файл.
    for _f in "$CACHE_DIR/nfqws1"/*.conf "$CACHE_DIR/nfqws2"/*.conf; do
        [ -s "$_f" ] || continue
        _sync_have_cache=1
        break
    done
    rm -rf "$_tmp"
    if [ "$_sync_have_cache" != 1 ]; then
        say "${RED}Список стратегий получен, но локальные файлы отсутствуют. Проверь соединение.${RESET}"
        return 1
    fi
    if [ "$_sync_errors" -gt 0 ]; then
        say "${YELLOW}Часть стратегий не обновлена; доступны уже сохранённые файлы.${RESET}"
    fi
    return 0
}

# Извлекаем абсолютные пути к blobs/lists так же, как nfqws-menu: учитываем @/path и =/path.
extract_blob_paths() {
    grep -vE '^[[:space:]]*#' "$1" 2>/dev/null | tr ' \t' '\n' |
        sed -n -e 's/.*@\(\/[^[:space:]"]*\.bin\).*/\1/p' \
               -e 's/.*=\(\/[^[:space:]"]*\.bin\).*/\1/p' | sort -u
}
extract_list_paths() {
    grep -vE '^[[:space:]]*#' "$1" 2>/dev/null | tr ' \t' '\n' |
        sed -n -e 's/.*[=:]\(\/[^[:space:]"]*\.list\).*/\1/p' \
               -e 's/^\(\/[^[:space:]"]*\.list\)$/\1/p' | sort -u
}

# Проверяем и скачиваем blobs активной конфигурации по SHA-256 из манифеста.
update_blobs_for() {
    _ub_conf=$1
    _ub_default=$2
    BLOBS_CHANGED=0
    [ -f "$_ub_conf" ] || { say "Конфиг не найден: $_ub_conf"; return 1; }
    _ub_root=$_ub_default
    case "$_ub_default" in */blobs) _ub_root=${_ub_default%/blobs} ;; esac
    _ub_work="$ROOT_DIR/blobwork.$$"
    mkdir -p "$_ub_work" "$BACKUP_DIR/blobs" || { rm -rf "$_ub_work"; return 1; }

    # Используем кэш манифеста, а при отсутствии загружаем только SHA256SUMS blobs.
    if [ ! -s "$ROOT_DIR/manifests/blobs-SHA256SUMS" ]; then
        mkdir -p "$ROOT_DIR/manifests" || { rm -rf "$_ub_work"; return 1; }
        if fetch "$NF_REPO/strategies/blobs/SHA256SUMS" "$_ub_work/blobs-SHA256SUMS" 30 &&
           awk 'NF>=2 && length($1)==64 && $1 ~ /^[0-9a-fA-F]+$/ {ok++} END {exit(ok?0:1)}' "$_ub_work/blobs-SHA256SUMS"; then
            cp "$_ub_work/blobs-SHA256SUMS" "$ROOT_DIR/manifests/blobs-SHA256SUMS.tmp" &&
                mv "$ROOT_DIR/manifests/blobs-SHA256SUMS.tmp" "$ROOT_DIR/manifests/blobs-SHA256SUMS" || {
                    rm -rf "$_ub_work"; return 1;
                }
        else
            say "${RED}Не удалось получить проверяемый манифест blobs; стратегия не будет применена.${RESET}"
            rm -rf "$_ub_work"
            return 1
        fi
    fi

    # Извлекаем полные пути из активных строк конфига, как в nfqws-menu.
    extract_blob_paths "$_ub_conf" > "$_ub_work/paths"
    if [ ! -s "$_ub_work/paths" ]; then
        rm -rf "$_ub_work"
        return 0
    fi

    _ub_failed=0
    while IFS= read -r _ub_path || [ -n "$_ub_path" ]; do
        [ -n "$_ub_path" ] || continue
        _ub_name=${_ub_path##*/}
        case "$_ub_name" in *[!A-Za-z0-9_.+-]*|*..*|.|..) say "${YELLOW}Пропуск небезопасного имени blob: $_ub_name${RESET}"; _ub_failed=1; continue ;; esac
        case "$_ub_path" in
            "$_ub_root"/*) ;;
            "$_ub_default"/*) ;;
            /*)
                say "${YELLOW}Blob $_ub_name находится вне каталога NFQWS: $_ub_path; пропуск.${RESET}"
                _ub_failed=1
                continue
                ;;
            *) _ub_path="$_ub_default/$_ub_name" ;;
        esac
        case "$_ub_path" in *'/../'*|*/..) say "${YELLOW}Недопустимый путь blob: $_ub_path${RESET}"; _ub_failed=1; continue ;; esac
        _ub_hash=$(awk -v n="$_ub_name" 'NF>=2 {p=$2; sub(/^\*/,"",p); sub(/^.*\//,"",p); if(p==n && length($1)==64 && $1 ~ /^[0-9a-fA-F]+$/){print $1; exit}}' "$ROOT_DIR/manifests/blobs-SHA256SUMS")
        case "$_ub_path" in *'/../'*|*/..) say "${YELLOW}Недопустимый путь blob: $_ub_path${RESET}"; _ub_failed=1; continue ;; esac

        if [ -z "$_ub_hash" ]; then
            if [ -f "$_ub_path" ] && [ ! -L "$_ub_path" ]; then
                say "${YELLOW}Blob $_ub_name уже существует, но его нет в SHA256SUMS; сохраняю локальный файл.${RESET}"
                continue
            fi
            say "${RED}Нет доверенной SHA-256 для отсутствующего blob $_ub_name; стратегия не будет применена.${RESET}"
            _ub_failed=1
            continue
        fi
        if [ -f "$_ub_path" ] && [ ! -L "$_ub_path" ] && sha_ok "$_ub_path" "$_ub_hash"; then
            say "${GREEN}Blob OK:${RESET} $_ub_name"
            continue
        fi
        if [ -L "$_ub_path" ]; then
            say "${RED}Путь blob является симлинком; замена запрещена: $_ub_path${RESET}"
            _ub_failed=1
            continue
        fi
        _ub_dl="$_ub_work/$_ub_name"
        say "Загружаю blob $_ub_name..."
        if fetch "$NF_REPO/strategies/blobs/$_ub_name" "$_ub_dl" 60 && sha_ok "$_ub_dl" "$_ub_hash"; then
            mkdir -p "$(dirname "$_ub_path")" || { rm -f "$_ub_dl"; _ub_failed=1; continue; }
            if [ -f "$_ub_path" ]; then
                _ub_ts=$(date '+%Y%m%d-%H%M%S' 2>/dev/null || printf 'backup')
                cp -p "$_ub_path" "$BACKUP_DIR/blobs/$_ub_name.$_ub_ts.bak" || {
                    rm -f "$_ub_dl"; say "${RED}Не удалось создать бэкап $_ub_path; blob не заменён.${RESET}"; _ub_failed=1; continue;
                }
            fi
            if mv "$_ub_dl" "$_ub_path"; then
                chmod 644 "$_ub_path" 2>/dev/null || :
                BLOBS_CHANGED=1
                say "${GREEN}Blob установлен и проверен:${RESET} $_ub_path"
            else
                rm -f "$_ub_dl"; _ub_failed=1
                say "${RED}Не удалось сохранить blob $_ub_name.${RESET}"
            fi
        else
            rm -f "$_ub_dl"; _ub_failed=1
            say "${RED}Не удалось загрузить/проверить SHA-256 для blob $_ub_name.${RESET}"
        fi
    done < "$_ub_work/paths"
    rm -rf "$_ub_work"
    [ "$_ub_failed" -eq 0 ]
}

# Проверяет списки .list, на которые ссылается конфигурация, и скачивает отсутствующие.
# Источник и логика соответствуют nfqws-menu: strategies/lists/<имя>.
update_lists_for() {
    _ul_conf=$1
    _ul_ver=$2
    LISTS_CHANGED=0
    [ -f "$_ul_conf" ] || { say "Конфиг списков не найден: $_ul_conf"; return 1; }
    case "$_ul_ver" in
        2) _ul_base='/opt/etc/nfqws2/lists' ;;
        1) _ul_base='/opt/etc/nfqws/lists' ;;
        *) say "Неизвестная версия NFQWS для списков: $_ul_ver"; return 1 ;;
    esac
    _ul_work="$ROOT_DIR/listwork.$$"
    mkdir -p "$_ul_work" || return 1

    # Извлекаем абсолютные пути списков тем же способом, что и upstream nfqws-menu.
    extract_list_paths "$_ul_conf" > "$_ul_work/refs"

    if [ ! -s "$_ul_work/refs" ]; then
        rm -rf "$_ul_work"
        return 0
    fi

    _ul_total=$(wc -l < "$_ul_work/refs" | tr -d ' ')
    _ul_i=0
    _ul_fail=0
    while IFS= read -r _ul_ref || [ -n "$_ul_ref" ]; do
        [ -n "$_ul_ref" ] || continue
        _ul_i=$((_ul_i + 1))
        _ul_name=${_ul_ref##*/}
        case "$_ul_name" in
            ''|.|..|*..*|*[!A-Za-z0-9_.+-]*)
                say "${YELLOW}Пропускаю небезопасное имя списка: $_ul_name${RESET}"
                _ul_fail=$((_ul_fail + 1))
                continue
                ;;
            *.list) : ;;
            *) continue ;;
        esac
        case "$_ul_ref" in
            "$_ul_base"/*) _ul_path=$_ul_ref ;;
            /*)
                if [ -s "$_ul_ref" ]; then continue; fi
                say "${RED}Отсутствующий список указан вне каталога $_ul_base: $_ul_ref${RESET}"
                _ul_fail=$((_ul_fail + 1))
                continue
                ;;
            *) _ul_path="$_ul_base/$_ul_name" ;;
        esac

        if [ -s "$_ul_path" ]; then
            continue
        fi
        if [ -L "$_ul_path" ]; then
            say "${RED}Путь списка является симлинком; загрузка отменена: $_ul_path${RESET}"
            _ul_fail=$((_ul_fail + 1))
            continue
        fi
        mkdir -p "$(dirname "$_ul_path")" || { _ul_fail=$((_ul_fail + 1)); continue; }

        # auto.list создаёт и заполняет сам демон NFQWS; достаточно пустого файла.
        if [ "$_ul_name" = 'auto.list' ]; then
            : > "$_ul_path" || { _ul_fail=$((_ul_fail + 1)); continue; }
            LISTS_CHANGED=1
            say "${GREEN}Создан пустой список демона: $_ul_path${RESET}"
            continue
        fi

        _ul_tmp="$_ul_work/$_ul_name"
        say "Список отсутствует: $_ul_name — скачиваю из strategies/lists/..."
        if fetch "$NF_REPO/strategies/lists/$_ul_name" "$_ul_tmp" 30 && [ -s "$_ul_tmp" ]; then
            if [ -e "$_ul_path" ] && [ ! -L "$_ul_path" ]; then
                backup_file "$_ul_path" || { rm -f "$_ul_tmp"; _ul_fail=$((_ul_fail + 1)); continue; }
            fi
            if mv "$_ul_tmp" "$_ul_path"; then
                chmod 644 "$_ul_path" 2>/dev/null || :
                LISTS_CHANGED=1
                say "${GREEN}  готово: $_ul_path${RESET}"
            else
                rm -f "$_ul_tmp"
                say "${RED}Не удалось сохранить список $_ul_name.${RESET}"
                _ul_fail=$((_ul_fail + 1))
            fi
        else
            rm -f "$_ul_tmp"
            say "${RED}Не удалось скачать список $_ul_name; конфигурация не будет применена.${RESET}"
            _ul_fail=$((_ul_fail + 1))
        fi
    done < "$_ul_work/refs"
    rm -rf "$_ul_work"
    [ "$_ul_fail" -eq 0 ]
}

# Загружает полный официальный список blobs NFQWS2 в /opt/etc/nfqws2/blobs.
install_all_nfqw2_blobs() {
    ensure_network || return 1
    if ! is_installed nfqws2-keenetic; then
        say "${RED}Сначала установи пакет nfqws2-keenetic.${RESET}"
        return 1
    fi
    _blob_dir='/opt/etc/nfqws2/blobs'
    _blob_work="$ROOT_DIR/all-blobs.$$"
    mkdir -p "$_blob_dir" "$_blob_work" "$ROOT_DIR/manifests" || { rm -rf "$_blob_work"; return 1; }
    say 'Получаю официальный манифест SHA-256 blobs...'
    if ! fetch "$NF_REPO/strategies/blobs/SHA256SUMS" "$_blob_work/SHA256SUMS" 30; then
        rm -rf "$_blob_work"
        say "${RED}Не удалось скачать манифест blobs.${RESET}"
        return 1
    fi
    _blob_total=$(awk 'NF>=2 && length($1)==64 && $1 ~ /^[0-9a-fA-F]+$/ {n++} END {print n+0}' "$_blob_work/SHA256SUMS")
    case "$_blob_total" in ''|*[!0-9]*|0)
        rm -rf "$_blob_work"
        say "${RED}Манифест blobs пуст или некорректен; ничего не устанавливаю.${RESET}"
        return 1 ;;
    esac
    cp "$_blob_work/SHA256SUMS" "$ROOT_DIR/manifests/blobs-SHA256SUMS.tmp" || { rm -rf "$_blob_work"; return 1; }
    mv "$ROOT_DIR/manifests/blobs-SHA256SUMS.tmp" "$ROOT_DIR/manifests/blobs-SHA256SUMS" || { rm -rf "$_blob_work"; return 1; }
    _blob_i=0
    _blob_ok=0
    _blob_fail=0
    while IFS= read -r _blob_line || [ -n "$_blob_line" ]; do
        _blob_hash=$(printf '%s\n' "$_blob_line" | awk 'NF>=2 {print $1; exit}')
        _blob_name=$(printf '%s\n' "$_blob_line" | awk 'NF>=2 {n=$2; sub(/^\*/, "", n); print n; exit}')
        case "$_blob_hash" in *[!0-9a-fA-F]*|'') continue ;; esac
        [ "${#_blob_hash}" -eq 64 ] || continue
        case "$_blob_name" in ''|.|..|*/*|*..*|*'?'*|*'#'*|*'%'*|*'\\'*) say "${YELLOW}Пропускаю небезопасное имя blob: $_blob_name${RESET}"; _blob_fail=$((_blob_fail + 1)); continue ;; esac
        printf '%s\n' "$_blob_name" | LC_ALL=C grep -Eq '^[A-Za-z0-9_.+-]+\.bin$' || { _blob_fail=$((_blob_fail + 1)); continue; }
        _blob_i=$((_blob_i + 1))
        _blob_target="$_blob_dir/$_blob_name"
        if [ -L "$_blob_target" ]; then
            printf '[%s/%s] пропуск симлинка: %s\n' "$_blob_i" "$_blob_total" "$_blob_name"
            _blob_fail=$((_blob_fail + 1))
            continue
        fi
        if [ -f "$_blob_target" ] && sha_ok "$_blob_target" "$_blob_hash"; then
            printf '[%s/%s] уже проверен: %s\n' "$_blob_i" "$_blob_total" "$_blob_name"
            _blob_ok=$((_blob_ok + 1))
            continue
        fi
        printf '[%s/%s] скачивание %s...\n' "$_blob_i" "$_blob_total" "$_blob_name"
        _blob_tmp="$_blob_work/$_blob_name"
        if fetch "$NF_REPO/strategies/blobs/$_blob_name" "$_blob_tmp" 45 && sha_ok "$_blob_tmp" "$_blob_hash"; then
            if [ -f "$_blob_target" ]; then
                backup_file "$_blob_target" || { rm -f "$_blob_tmp"; _blob_fail=$((_blob_fail + 1)); continue; }
            fi
            if mv "$_blob_tmp" "$_blob_target"; then
                chmod 644 "$_blob_target" || :
                _blob_ok=$((_blob_ok + 1))
            else
                rm -f "$_blob_tmp"
                _blob_fail=$((_blob_fail + 1))
                say "${RED}Не удалось сохранить $_blob_name.${RESET}"
            fi
        else
            rm -f "$_blob_tmp"
            _blob_fail=$((_blob_fail + 1))
            say "${RED}Ошибка загрузки или SHA-256 для $_blob_name; файл не установлен.${RESET}"
        fi
    done < "$_blob_work/SHA256SUMS"
    rm -rf "$_blob_work"
    say "${GREEN}Установлено/проверено $_blob_ok из $_blob_total blobs в $_blob_dir.${RESET}"
    if [ "$_blob_fail" -gt 0 ] || [ "$_blob_ok" -ne "$_blob_total" ]; then
        say "${YELLOW}Ошибок или пропусков: $_blob_fail. Повтори операцию после проверки сети и прав доступа.${RESET}"
        return 1
    fi
    return 0
}

active_conf() {
    if is_installed nfqws2-keenetic && [ -f /opt/etc/nfqws2/nfqws2.conf ]; then echo '/opt/etc/nfqws2/nfqws2.conf|/opt/etc/nfqws2/blobs'
    elif is_installed nfqws-keenetic && [ -f /opt/etc/nfqws/nfqws.conf ]; then echo '/opt/etc/nfqws/nfqws.conf|/opt/etc/nfqws'
    else return 1; fi
}
# Сравниваем конфиг с кэшированной стратегией; игнорируем ISP_INTERFACE, комментарии и нашу добавку rkn.list.
strategy_configs_equal() {
    _sce_current=$1
    _sce_candidate=$2
    [ -f "$_sce_current" ] && [ -f "$_sce_candidate" ] || return 1
    _sce_a="$ROOT_DIR/.strategy-current.$$.tmp"
    _sce_b="$ROOT_DIR/.strategy-candidate.$$.tmp"
    sed -e 's/\r$//' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
        -e '/^[[:space:]]*ISP_INTERFACE[[:space:]]*=/d' \
        -e 's|--hostlist=/opt/etc/nfqws2/lists/rkn.list||g' \
        -e 's|--hostlist=/opt/etc/nfqws/rkn.list||g' \
        -e 's/[[:space:]]\{2,\}/ /g' -e 's/[[:space:]]*"/"/g' -e 's/[[:space:]]*$//' \
        "$_sce_current" > "$_sce_a" || { rm -f "$_sce_a" "$_sce_b"; return 1; }
    sed -e 's/\r$//' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
        -e '/^[[:space:]]*ISP_INTERFACE[[:space:]]*=/d' \
        -e 's|--hostlist=/opt/etc/nfqws2/lists/rkn.list||g' \
        -e 's|--hostlist=/opt/etc/nfqws/rkn.list||g' \
        -e 's/[[:space:]]\{2,\}/ /g' -e 's/[[:space:]]*"/"/g' -e 's/[[:space:]]*$//' \
        "$_sce_candidate" > "$_sce_b" || { rm -f "$_sce_a" "$_sce_b"; return 1; }
    if command -v cmp >/dev/null 2>&1; then
        cmp -s "$_sce_a" "$_sce_b" 2>/dev/null
        _sce_rc=$?
    else
        _sce_ha=$(sha256_file "$_sce_a") || _sce_ha=''
        _sce_hb=$(sha256_file "$_sce_b") || _sce_hb=''
        [ -n "$_sce_ha" ] && [ "$_sce_ha" = "$_sce_hb" ]
        _sce_rc=$?
    fi
    rm -f "$_sce_a" "$_sce_b"
    return "$_sce_rc"
}
active_strategy_label() {
    _asl_active=$(active_conf) || { printf '%s' 'NFQWS не установлен'; return 0; }
    _asl_conf=${_asl_active%%|*}
    case "$_asl_conf" in
        */nfqws2.conf) _asl_ver=2; _asl_label='nfqws2' ;;
        */nfqws.conf) _asl_ver=1; _asl_label='NFQWS' ;;
        *) printf '%s' 'не определена'; return 0 ;;
    esac
    _asl_marker="$ROOT_DIR/active-strategy-nfqws$_asl_ver"
    _asl_name=$(sed -n '1{s/\r$//;p;}' "$_asl_marker" 2>/dev/null)
    if [ -n "$_asl_name" ] && [ -f "$CACHE_DIR/nfqws$_asl_ver/$_asl_name" ] &&
       strategy_configs_equal "$_asl_conf" "$CACHE_DIR/nfqws$_asl_ver/$_asl_name"; then
        printf '%s: %s' "$_asl_label" "$_asl_name"
        return 0
    fi
    for _asl_file in "$CACHE_DIR/nfqws$_asl_ver"/*.conf; do
        [ -s "$_asl_file" ] || continue
        if strategy_configs_equal "$_asl_conf" "$_asl_file"; then
            _asl_name=${_asl_file##*/}
            printf '%s: %s' "$_asl_label" "$_asl_name"
            return 0
        fi
    done
    if [ -n "$_asl_name" ]; then
        printf '%s: %s (активный конфиг изменён после выбора)' "$_asl_label" "$_asl_name"
    else
        printf '%s: не определена (конфиг не совпадает с кэшем)' "$_asl_label"
    fi
}

strategy_menu() {
    sync_strategies || { _rc=$?; [ "$_rc" -eq 130 ] && return 130; return 1; }
    _active=$(active_conf) || { say 'nfqws/nfqws2 конфиг не найден; сначала установи движок.'; return 1; }
    _conf=${_active%%|*}; _default=${_active#*|}
    case "$_conf" in */nfqws2.conf) _ver=2; _dir="$CACHE_DIR/nfqws2";; *) _ver=1; _dir="$CACHE_DIR/nfqws1";; esac
    _list="$ROOT_DIR/strategies.list"
    _priority="$ROOT_DIR/strategies-priority.$$"
    _others="$ROOT_DIR/strategies-other.$$"
    _display="$ROOT_DIR/strategies-display.$$"
    : > "$_list"
    # Сначала показываем самые используемые стратегии в привычном порядке.
    cat > "$_priority" <<'XMENU_STRATEGY_ORDER'
MartinBacker.conf
Uvvi2.conf
alt.conf
alt10.conf
alt11.conf
alt12.conf
alt13.conf
alt2.conf
alt3.conf
alt4.conf
alt4_mod.conf
alt5.conf
alt6.conf
alt7.conf
alt8.conf
alt9.conf
eduncey.conf
exp.conf
fake_tls_auto.conf
fake_tls_auto_alt.conf
fake_tls_auto_alt2.conf
fake_tls_auto_alt3.conf
hardcorp74.conf
krushaaa.conf
simple_fake.conf
simple_fake_alt.conf
simple_fake_alt2.conf
XMENU_STRATEGY_ORDER
    while IFS= read -r _priority_name || [ -n "$_priority_name" ]; do
        case "$_priority_name" in ''|*/*|*..*) continue ;; esac
        [ -f "$_dir/$_priority_name" ] || continue
        grep -Fxq "$_priority_name" "$_list" 2>/dev/null || printf '%s\n' "$_priority_name" >> "$_list"
    done < "$_priority"
    : > "$_others"
    for _f in "$_dir"/*.conf; do
        [ -f "$_f" ] || continue
        _candidate=${_f##*/}
        grep -Fxq "$_candidate" "$_list" 2>/dev/null || printf '%s\n' "$_candidate" >> "$_others"
    done
    if [ -s "$_others" ]; then
        LC_ALL=C sort "$_others" >> "$_list"
    fi
    rm -f "$_priority" "$_others"
    [ -s "$_list" ] || { rm -f "$_list" "$_display"; say 'Кэш стратегий пуст.'; return 1; }

    # Отмечаем выбранную стратегию по маркеру, затем по совпадению конфига.
    _current_strategy=$(sed -n '1{s/\r$//;p;}' "$ROOT_DIR/active-strategy-nfqws$_ver" 2>/dev/null)
    case "$_current_strategy" in ''|*/*|*..*|*[!A-Za-z0-9_.+-]*) _current_strategy='' ;; esac
    if [ -z "$_current_strategy" ] || [ ! -f "$_dir/$_current_strategy" ]; then
        _current_strategy=''
        for _candidate_file in "$_dir"/*.conf; do
            [ -s "$_candidate_file" ] || continue
            if strategy_configs_equal "$_conf" "$_candidate_file"; then
                _current_strategy=${_candidate_file##*/}
                break
            fi
        done
    fi
    : > "$_display"
    while IFS= read -r _display_name || [ -n "$_display_name" ]; do
        if [ "$_display_name" = "$_current_strategy" ]; then
            printf '%s\t%s\n' "$_display_name" '— Активная стратегия ⚡' >> "$_display"
        else
            printf '%s\t%s\n' "$_display_name" '' >> "$_display"
        fi
    done < "$_list"
    line; say "${WHITE}ВЫБОР СТРАТЕГИИ — NFQWS$_ver${RESET}"; line
    awk -F '\t' '{printf "      %2d. %-28s %s\n", NR, $1, $2}' "$_display"
    menu_item 0 'Назад'
    line; _read_or_eof 'Номер стратегии: ' || { rm -f "$_display"; return 0; }; _n=$_read_value
    rm -f "$_display"
    case "$_n" in ''|0) return 0;; *[!0-9]*) say 'Неверный номер.'; return 1;; esac
    _name=$(sed -n "${_n}p" "$_list")
    case "$_name" in
        ''|.|..|*/*|*../*|../*|*..*|*'?'*|*'#'*|*'%'*|*'['*|*']'*|*'\\'*)
            say 'Недопустимое имя стратегии.'; return 1 ;;
    esac
    printf '%s\n' "$_name" | LC_ALL=C grep -Eq '^[A-Za-z0-9_.+ -]+$' || {
        say 'Недопустимые символы в имени стратегии.'
        return 1
    }
    [ -f "$_dir/$_name" ] || { say 'Стратегия отсутствует в кэше.'; return 1; }
    _rel="strategies/nfqws$_ver/$_name"
    _url_rel=$(printf '%s' "$_rel" | sed 's/ /%20/g')
    _src="$NF_REPO/$_url_rel"; _tmp="$ROOT_DIR/apply-$$.conf"
    _expected=$(while IFS= read -r _entry || [ -n "$_entry" ]; do
        _h=$(printf '%s' "$_entry" | cut -c1-64)
        _p=$(manifest_relpath "$_entry")
        [ "$_p" = "$_rel" ] && { printf '%s\n' "$_h"; break; }
    done < "$ROOT_DIR/manifests/SHA256SUMS")
    [ -n "$_expected" ] || { say 'В манифесте нет такой стратегии.'; return 1; }
    if [ -s "$_dir/$_name" ] && verify_sum "$_dir/$_name" "$_expected"; then
        cp "$_dir/$_name" "$_tmp" || { say 'Не удалось подготовить копию стратегии из кэша.'; return 1; }
    else
        fetch "$_src" "$_tmp" 45 && verify_sum "$_tmp" "$_expected" || { rm -f "$_tmp"; say 'Стратегия не скачалась или SHA256 не совпала.'; return 1; }
    fi
    _if=$(awk -F= '$1 ~ /^[[:space:]]*ISP_INTERFACE[[:space:]]*$/ {gsub(/[ \047]/, "", $2); gsub(/"/, "", $2); print $2; exit}' "$_conf")
    if [ -n "$_if" ]; then
        sed "s|^[[:space:]]*ISP_INTERFACE=.*|ISP_INTERFACE=\"$_if\"|" "$_tmp" > "$_tmp.norm" && mv "$_tmp.norm" "$_tmp"
    fi
    sed 's/\r$//' "$_tmp" > "$_tmp.norm" && mv "$_tmp.norm" "$_tmp"
    case "$_ver" in 2) preserve_rkn_hostlist "$_conf" "$_tmp" 2 || { rm -f "$_tmp" "$_tmp.norm"; return 1; } ;; 1) preserve_rkn_hostlist "$_conf" "$_tmp" 1 || { rm -f "$_tmp" "$_tmp.norm"; return 1; } ;; esac
    say "Выбрана стратегия: $_name"
    say 'Будет создан бэкап; сначала проверю/доустановлю нужные blobs, затем заменю конфиг и перезапущу NFQWS.'
    if confirm 'Применить стратегию?'; then
        [ ! -L "$_conf" ] || { rm -f "$_tmp" "$_tmp.norm"; say 'Активный конфиг является симлинком; замена отменена.'; return 1; }
        acquire_lock || { rm -f "$_tmp" "$_tmp.norm"; return 1; }
        # Сначала обеспечиваем все необходимые blobs; живой конфиг не меняется при ошибке загрузки.
        if ! update_blobs_for "$_tmp" "$_default"; then
            cleanup
            rm -f "$_tmp" "$_tmp.norm"
            say "${RED}Стратегия не применена: не удалось подготовить все необходимые blobs.${RESET}"
            return 1
        fi
        if ! update_lists_for "$_tmp" "$_ver"; then
            cleanup
            rm -f "$_tmp" "$_tmp.norm"
            say "${RED}Стратегия не применена: не удалось подготовить необходимые lists.${RESET}"
            return 1
        fi
        backup_file "$_conf" || { cleanup; rm -f "$_tmp" "$_tmp.norm"; return 1; }
        cp "$_tmp" "$_conf" || { cleanup; rm -f "$_tmp" "$_tmp.norm"; say 'Не удалось применить конфиг.'; return 1; }
        printf '%s\n' "$_name" > "$ROOT_DIR/active-strategy-nfqws$_ver" || say 'Не удалось сохранить имя активной стратегии для автообновления.'
        case "$_ver" in 2) _init=/opt/etc/init.d/S51nfqws2;; 1) _init=/opt/etc/init.d/S51nfqws;; esac
        _strategy_apply_rc=0
        if [ -x "$_init" ]; then
            "$_init" restart || { say "${RED}Конфиг применён, но перезапуск $_init завершился ошибкой.${RESET}"; _strategy_apply_rc=1; }
        else
            say "${YELLOW}Конфиг применён, но init-скрипт $_init не найден; перезапусти NFQWS вручную.${RESET}"
            _strategy_apply_rc=1
        fi
        cleanup
        if [ "$_strategy_apply_rc" -eq 0 ]; then
            say "${GREEN}Стратегия применена, необходимые blobs/lists проверены, сервис перезапущен. Бэкап сохранён.${RESET}"
        fi
        rm -f "$_tmp" "$_tmp.norm"
        return "$_strategy_apply_rc"
    fi
    rm -f "$_tmp" "$_tmp.norm"
}

# Сохраняет связь rkn.list в MODE_LIST при обновлении/смене стратегии.
mode_list_has_host() {
    _ml_conf=$1
    _ml_host=$2
    awk -v host="$_ml_host" '/^[[:space:]]*MODE_LIST[[:space:]]*=/ && index($0, host) > 0 {found=1} END {exit(found?0:1)}' "$_ml_conf" 2>/dev/null
}

preserve_rkn_hostlist() {
    _pr_old=$1
    _pr_new=$2
    _pr_ver=$3
    case "$_pr_ver" in
        2) _pr_list='/opt/etc/nfqws2/lists/rkn.list' ;;
        1) _pr_list='/opt/etc/nfqws/rkn.list' ;;
        *) return 0 ;;
    esac
    mode_list_has_host "$_pr_old" "--hostlist=$_pr_list" || return 0
    mode_list_has_host "$_pr_new" "--hostlist=$_pr_list" && return 0
    _pr_tmp="$_pr_new.rkn.$$"
    awk -v host="--hostlist=$_pr_list" '
        /^[[:space:]]*MODE_LIST[[:space:]]*=/ {
            if (index($0, host) > 0) { print; found=1; next }
            if ($0 ~ /"[[:space:]]*$/) {
                sub(/"[[:space:]]*$/, " " host "\"")
                print; found=1; next
            }
        }
        { print }
        END { if (!found) exit 3 }
    ' "$_pr_new" > "$_pr_tmp" || {
        rm -f "$_pr_tmp"
        say "${YELLOW}В конфиге стратегии не удалось найти MODE_LIST; привязка rkn.list не менялась.${RESET}"
        return 1
    }
    mv "$_pr_tmp" "$_pr_new" || { rm -f "$_pr_tmp"; return 1; }
    say "${GREEN}Сохранил привязку rkn.list в MODE_LIST.${RESET}"
    return 0
}

apply_marked_active_strategy() {
    STRATEGY_CHANGED=0
    # Never replace a custom config merely because an old strategy marker exists.
    if [ "${SYNC_ALLOW_STRATEGY_UPDATE:-0}" != 1 ]; then
        say "${YELLOW}Автоматическая подмена стратегии пропущена: активный конфиг до обновления не совпадал с сохранённой стратегией или маркер отсутствует; конфиг оставлен без изменений.${RESET}"
        return 0
    fi
    _active=$(active_conf) || return 0
    _conf=${_active%%|*}; _default=${_active#*|}
    case "$_conf" in
        */nfqws2.conf) _ver=2 ;;
        */nfqws.conf) _ver=1 ;;
        *) return 0 ;;
    esac
    _marker="$ROOT_DIR/active-strategy-nfqws$_ver"
    [ -s "$_marker" ] || return 0
    _name=$(sed -n '1p' "$_marker" | tr -d '\r')
    case "$_name" in ''|.|..|*/*|*..*|*'?'*|*'#'*|*'%'*|*'['*|*']'*|*'\\'*)
        say "${YELLOW}Имя активной стратегии в маркере некорректно; автоматическая замена пропущена.${RESET}"
        return 0 ;;
    esac
    printf '%s\n' "$_name" | LC_ALL=C grep -Eq '^[A-Za-z0-9_.+ -]+$' || {
        say "${YELLOW}Недопустимые символы в маркере активной стратегии; пропуск.${RESET}"
        return 0
    }
    _rel="strategies/nfqws$_ver/$_name"
    _src="$CACHE_DIR/nfqws$_ver/$_name"
    [ -f "$_src" ] || { say "${YELLOW}Активная стратегия $_name отсутствует в кэше; пропуск.${RESET}"; return 0; }
    _expected=$(while IFS= read -r _entry || [ -n "$_entry" ]; do
        _h=$(printf '%s' "$_entry" | cut -c1-64)
        _p=$(manifest_relpath "$_entry")
        [ "$_p" = "$_rel" ] && { printf '%s\n' "$_h"; break; }
    done < "$ROOT_DIR/manifests/SHA256SUMS")
    verify_sum "$_src" "$_expected" || { say "${RED}Кэш активной стратегии $_name не прошёл SHA-256; конфиг не изменён.${RESET}"; return 1; }
    _tmpconf="$ROOT_DIR/active-strategy-update.$$"
    cp "$_src" "$_tmpconf" || return 1
    _if=$(awk -F= '$1 ~ /^[[:space:]]*ISP_INTERFACE[[:space:]]*$/ {gsub(/[ \047]/, "", $2); gsub(/"/, "", $2); print $2; exit}' "$_conf")
    if [ -n "$_if" ]; then
        sed "s|^[[:space:]]*ISP_INTERFACE=.*|ISP_INTERFACE=\"$_if\"|" "$_tmpconf" > "$_tmpconf.norm" && mv "$_tmpconf.norm" "$_tmpconf" || { rm -f "$_tmpconf" "$_tmpconf.norm"; return 1; }
    fi
    sed 's/\r$//' "$_tmpconf" > "$_tmpconf.norm" && mv "$_tmpconf.norm" "$_tmpconf" || { rm -f "$_tmpconf" "$_tmpconf.norm"; return 1; }
    preserve_rkn_hostlist "$_conf" "$_tmpconf" "$_ver" || { rm -f "$_tmpconf" "$_tmpconf.norm"; return 1; }
    _old_sum=$(sha256_file "$_conf") || _old_sum=''
    _new_sum=$(sha256_file "$_tmpconf") || _new_sum=''
    if [ -n "$_old_sum" ] && [ "$_old_sum" = "$_new_sum" ]; then rm -f "$_tmpconf"; return 0; fi
    [ ! -L "$_conf" ] || { rm -f "$_tmpconf"; say 'Активный конфиг является симлинком; автообновление пропущено.'; return 1; }
    if ! update_blobs_for "$_tmpconf" "$_default"; then
        rm -f "$_tmpconf" "$_tmpconf.norm"
        say "${YELLOW}Автообновление стратегии отменено: не удалось подготовить все необходимые blobs.${RESET}"
        return 1
    fi
    if ! update_lists_for "$_tmpconf" "$_ver"; then
        rm -f "$_tmpconf" "$_tmpconf.norm"
        say "${YELLOW}Автообновление стратегии отменено: не удалось подготовить необходимые lists.${RESET}"
        return 1
    fi
    backup_file "$_conf" || { rm -f "$_tmpconf"; return 1; }
    cp "$_tmpconf" "$_conf" || { rm -f "$_tmpconf"; return 1; }
    rm -f "$_tmpconf"
    STRATEGY_CHANGED=1
    say "${GREEN}Активная стратегия $_name обновлена из проверенного кэша; ISP_INTERFACE сохранён.${RESET}"
}
sync_active_blobs() {
    # Decide whether the live config is an official selected strategy BEFORE the cache is refreshed.
    # If it differs, it is custom and the config must not be replaced by a menu strategy.
    SYNC_ALLOW_STRATEGY_UPDATE=0
    _pre_active=$(active_conf 2>/dev/null || :)
    if [ -n "$_pre_active" ]; then
        _pre_conf=${_pre_active%%|*}
        case "$_pre_conf" in
            */nfqws2.conf) _pre_ver=2 ;;
            */nfqws.conf) _pre_ver=1 ;;
            *) _pre_ver=0 ;;
        esac
        if [ "$_pre_ver" != 0 ]; then
            _pre_marker="$ROOT_DIR/active-strategy-nfqws$_pre_ver"
            _pre_name=$(sed -n '1{s/\\r$//;p;}' "$_pre_marker" 2>/dev/null)
            case "$_pre_name" in ''|.|..|*/*|*..*|*[!A-Za-z0-9_.+-]*) _pre_name='' ;; esac
            if [ -n "$_pre_name" ] && [ -f "$CACHE_DIR/nfqws$_pre_ver/$_pre_name" ] &&
               strategy_configs_equal "$_pre_conf" "$CACHE_DIR/nfqws$_pre_ver/$_pre_name"; then
                SYNC_ALLOW_STRATEGY_UPDATE=1
            fi
        fi
    fi
    acquire_lock || return 1
    sync_strategies || { _rc=$?; cleanup; [ "$_rc" -eq 130 ] && return 130; return 1; }
    apply_marked_active_strategy || { _rc=$?; cleanup; [ "$_rc" -eq 130 ] && return 130; return 1; }
    _active=$(active_conf) || { cleanup; say 'Нет активного NFQWS конфига.'; return 1; }
    _conf=${_active%%|*}; _default=${_active#*|}
    update_blobs_for "$_conf" "$_default"
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
        case "$_conf" in */nfqws2.conf) _sync_ver=2 ;; *) _sync_ver=1 ;; esac
        update_lists_for "$_conf" "$_sync_ver"
        _list_rc=$?
        [ "$_list_rc" -eq 0 ] || _rc=1
    fi
    if [ "$_rc" -eq 0 ] && { [ "${STRATEGY_CHANGED:-0}" = 1 ] || [ "${BLOBS_CHANGED:-0}" = 1 ] || [ "${LISTS_CHANGED:-0}" = 1 ]; }; then
        case "$_conf" in */nfqws2.conf) _init=/opt/etc/init.d/S51nfqws2 ;; *) _init=/opt/etc/init.d/S51nfqws ;; esac
        if [ -x "$_init" ]; then
            "$_init" restart || { say "${RED}Стратегия/blob/list обновлены, но перезапуск $_init завершился ошибкой.${RESET}"; _rc=1; }
        else
            say "${YELLOW}Стратегия/blob/list обновлены; init-скрипт NFQWS не найден для перезапуска.${RESET}"
            _rc=1
        fi
    fi
    cleanup
    SYNC_ALLOW_STRATEGY_UPDATE=0
    return "$_rc"
}
acquire_lock() {
    mkdir -p "$(dirname "$LOCK_DIR")" || return 1
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        LOCK_HELD=1
        printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || :
        return 0
    fi
    # Удаляем устаревшую блокировку только после завершения указанного процесса.
    _lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || :)
    case "$_lock_pid" in
        ''|*[!0-9]*) ;;
        *)
            if ! kill -0 "$_lock_pid" 2>/dev/null; then
                rm -f "$LOCK_DIR/pid" 2>/dev/null || :
                rmdir "$LOCK_DIR" 2>/dev/null || :
                if mkdir "$LOCK_DIR" 2>/dev/null; then
                    LOCK_HELD=1
                    printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || :
                    return 0
                fi
            fi
            ;;
    esac
    say "${YELLOW}Другая операция xmenu уже меняет настройки. Подожди и повтори.${RESET}"
    return 1
}
launch_dpi() {
    _dpi_bin='/opt/bin/dpi-detector'
    if [ ! -x "$_dpi_bin" ]; then
        say "${YELLOW}DPI Detector не найден. Устанавливаю официальную Rust-версию для Entware...${RESET}"
        install_dpi_detector force || return $?
    fi

    # Сначала проверяем --version: это позволяет поймать ELF с отсутствующим loader,
    # не перенаправляя stderr интерактивного TUI в файл.
    _dpi_probe=$(sh -c 'exec "$1" --version' x "$_dpi_bin" 2>&1)
    _dpi_probe_rc=$?
    if [ "$_dpi_probe_rc" -eq 126 ] || [ "$_dpi_probe_rc" -eq 127 ] ||
       printf '%s\n' "$_dpi_probe" | grep -qiE 'not found|No such file|No such interpreter'; then
        say "${YELLOW}Нативный DPI Detector не запускается (код $_dpi_probe_rc). Переустанавливаю официальную Rust-версию и повторяю проверку.${RESET}"
        case "$_dpi_probe_rc" in
            126|127) : ;; # Не печатаем шум shell для заведомо несовместимого ELF.
            *) [ -z "$_dpi_probe" ] || printf '%s\n' "$_dpi_probe" | sed -n '1,4p' ;;
        esac
        install_dpi_detector force || return 1
        _dpi_probe=$(sh -c 'exec "$1" --version' x "$_dpi_bin" 2>&1)
        _dpi_probe_rc=$?
        if [ "$_dpi_probe_rc" -ne 0 ]; then
            say "${RED}DPI Detector всё ещё не запускается после установки (код $_dpi_probe_rc).${RESET}"
            [ -z "$_dpi_probe" ] || printf '%s\n' "$_dpi_probe" | sed -n '1,6p'
            return 1
        fi
    fi

    # Запускаем приложение с обычным tty и не перехватываем его stdout/stderr:
    # терминальный интерфейс должен управлять экраном и получать клавиши напрямую.
    "$_dpi_bin" "$@"
    _dpi_launch_rc=$?
    if [ "$_dpi_launch_rc" -ne 0 ]; then
        say "${RED}DPI Detector завершился с кодом $_dpi_launch_rc.${RESET}"
        say 'Для диагностики запусти: /opt/bin/dpi-detector --help'
    fi
    return "$_dpi_launch_rc"
}

xkeen_is_installed() {
    command -v xkeen >/dev/null 2>&1 || [ -x /opt/sbin/xkeen ] || [ -x /opt/bin/xkeen ] || is_installed xkeen
}

xkeen_ui_zxc_is_installed() {
    is_installed xkeen-ui || command -v xkeen-ui >/dev/null 2>&1 ||
        [ -x /opt/sbin/xkeen-ui ] || [ -x /opt/bin/xkeen-ui ] ||
        [ -f /opt/etc/init.d/S99xkeen-ui ] || [ -d /opt/share/www/XKeen-UI ]
}

xkeen_ui_umar_is_installed() {
    [ -f /opt/etc/init.d/S99xkeen-ui-umarcheh001 ] ||
        [ -x /opt/etc/init.d/S99xkeen-ui-umarcheh001 ] ||
        [ -f /opt/xkeen-ui/install.sh ] ||
        [ -f /opt/etc/xkeen-ui/devtools.env ]
}

xkeen_ui_is_installed() {
    xkeen_ui_zxc_is_installed || xkeen_ui_umar_is_installed ||
        [ -x /opt/sbin/xkeen-ui-umar ]
}

version_token_is_valid() {
    printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[vV]?[0-9][A-Za-z0-9._+-]*$'
}

read_version_file() {
    for _version_file in "$@"; do
        [ -r "$_version_file" ] || continue
        _version_value=$(sed -n '1{s/\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//; p;}' "$_version_file" 2>/dev/null)
        [ -n "$_version_value" ] && { printf '%s' "$_version_value"; return 0; }
    done
    return 1
}

get_xkeen_version() {
    xkeen_is_installed || { printf '%s' 'не установлен'; return 0; }
    _v=''
    _xkeen_cmd=$(command -v xkeen 2>/dev/null || printf '')
    [ -n "$_xkeen_cmd" ] || { [ -x /opt/sbin/xkeen ] && _xkeen_cmd=/opt/sbin/xkeen; }
    [ -n "$_xkeen_cmd" ] || { [ -x /opt/bin/xkeen ] && _xkeen_cmd=/opt/bin/xkeen; }
    if [ -n "$_xkeen_cmd" ]; then
        _v=$("$_xkeen_cmd" -v 2>/dev/null | head -n 1 | awk '{print $NF}')
        version_token_is_valid "$_v" || _v=''
    fi
    if [ -z "$_v" ]; then
        _v=$(read_version_file /opt/etc/xkeen/version /opt/etc/xkeen/version.txt 2>/dev/null || printf '')
    fi
    if [ -z "$_v" ]; then
        _v=$(opkg list-installed 2>/dev/null | awk '$1=="xkeen" {print $3; exit}')
    fi
    printf '%s' "${_v:-неизвестна}"
}

get_xkeen_ui_zxc_version() {
    xkeen_ui_zxc_is_installed || { printf '%s' 'не установлен'; return 0; }
    _v=$(opkg list-installed 2>/dev/null | awk '$1=="xkeen-ui" {print $3; exit}')
    if [ -z "$_v" ]; then
        _v=$(read_version_file /opt/etc/xkeen-ui/version /opt/etc/xkeen-ui/version.txt 2>/dev/null || printf '')
    fi
    if [ -z "$_v" ]; then
        _ui_cmd=$(command -v xkeen-ui 2>/dev/null || printf '')
        [ -n "$_ui_cmd" ] || { [ -x /opt/sbin/xkeen-ui ] && _ui_cmd=/opt/sbin/xkeen-ui; }
        [ -n "$_ui_cmd" ] || { [ -x /opt/bin/xkeen-ui ] && _ui_cmd=/opt/bin/xkeen-ui; }
        if [ -n "$_ui_cmd" ]; then
            _v=$("$_ui_cmd" -v 2>/dev/null | head -n 1 | awk '{print $NF}')
            version_token_is_valid "$_v" || _v=''
        fi
    fi
    printf '%s' "${_v:-неизвестна}"
}

get_xkeen_ui_umar_version() {
    xkeen_ui_umar_is_installed || { printf '%s' 'не установлен'; return 0; }
    _v=$(read_version_file /opt/etc/xkeen-ui/version /opt/etc/xkeen-ui/version.txt /opt/xkeen-ui/VERSION /opt/xkeen-ui/version 2>/dev/null || printf '')
    if [ -z "$_v" ] && [ -r /opt/xkeen-ui/package.json ]; then
        _v=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /opt/xkeen-ui/package.json | head -n 1)
    fi
    case "$_v" in ''|*[!A-Za-z0-9._+-]*) _v='' ;; esac
    printf '%s' "${_v:-неизвестна}"
}

get_xkeen_ui_version() {
    if xkeen_ui_zxc_is_installed; then get_xkeen_ui_zxc_version
    elif xkeen_ui_umar_is_installed; then get_xkeen_ui_umar_version
    else printf '%s' 'не установлен'
    fi
}

get_xray_version() {
    _bin=$(command -v xray 2>/dev/null)
    [ -n "$_bin" ] || { [ -x /opt/bin/xray ] && _bin=/opt/bin/xray; }
    [ -n "$_bin" ] || { [ -x /opt/sbin/xray ] && _bin=/opt/sbin/xray; }
    [ -n "$_bin" ] || { [ -x /opt/sbin/.xkeen/xray ] && _bin=/opt/sbin/.xkeen/xray; }
    [ -n "$_bin" ] || { [ -x /opt/sbin/.xkeen/bin/xray ] && _bin=/opt/sbin/.xkeen/bin/xray; }
    [ -n "$_bin" ] || { _bin=$(find /opt/sbin/.xkeen -maxdepth 4 -type f -name xray -perm -111 2>/dev/null | head -n 1); }
    [ -n "$_bin" ] || { echo 'не найден'; return; }
    _v=$("$_bin" version 2>&1 | head -n 1)
    printf '%s' "${_v:-версия не сообщена}"
}

get_mihomo_version() {
    _bin=$(command -v mihomo 2>/dev/null)
    [ -n "$_bin" ] || { [ -x /opt/bin/mihomo ] && _bin=/opt/bin/mihomo; }
    [ -n "$_bin" ] || { [ -x /opt/sbin/mihomo ] && _bin=/opt/sbin/mihomo; }
    [ -n "$_bin" ] || { [ -x /opt/sbin/.xkeen/mihomo ] && _bin=/opt/sbin/.xkeen/mihomo; }
    [ -n "$_bin" ] || { [ -x /opt/sbin/.xkeen/bin/mihomo ] && _bin=/opt/sbin/.xkeen/bin/mihomo; }
    [ -n "$_bin" ] || { _bin=$(find /opt/sbin/.xkeen -maxdepth 4 -type f -name mihomo -perm -111 2>/dev/null | head -n 1); }
    [ -n "$_bin" ] || { echo 'не найден'; return; }
    _v=$("$_bin" -v 2>&1 | head -n 1)
    printf '%s' "${_v:-версия не сообщена}"
}
print_component() {
    _pc_label=$1
    _pc_installed=$2
    _pc_version=${3:-}
    # Не показываем отсутствующие компоненты в таблице установленного ПО.
    if [ "$_pc_installed" != yes ] || [ "$_pc_version" = 'не установлен' ] || [ "$_pc_version" = 'не найден' ]; then
        return 0
    fi
    case "$_pc_version" in
        ''|'неизвестна'|'установлен; версия не извлечена'|'версия не сообщена')
            _pc_display='версия неизвестна'
            ;;
        'ELF несовместим с Entware')
            _pc_display='ELF несовместим с Entware'
            ;;
        *)
            _pc_display=$(printf '%s' "$_pc_version" | cut -c1-45)
            [ "$_pc_display" = "$_pc_version" ] || _pc_display="$_pc_display..."
            ;;
    esac
    printf '%s\t%s\n' "$_pc_label" "$_pc_display" >> "$_COMPONENT_INSTALLED_FILE"
}

component_table_header() {
    say "  ${MUTED}──────────────────────────────────────────────${RESET}"
}

render_component_statuses() {
    _COMPONENT_INSTALLED_FILE="$ROOT_DIR/.components-installed.$$"
    : > "$_COMPONENT_INSTALLED_FILE" || return 1

    # Собираем и показываем только установленные компоненты.
    print_component 'nfqws-keenetic' "$(is_installed nfqws-keenetic && printf yes || printf no)" "$(pkg_version nfqws-keenetic)"
    print_component 'nfqws2-keenetic' "$(is_installed nfqws2-keenetic && printf yes || printf no)" "$(pkg_version nfqws2-keenetic)"
    print_component 'nfqws-keenetic-web' "$(is_installed nfqws-keenetic-web && printf yes || printf no)" "$(pkg_version nfqws-keenetic-web)"
    print_component 'xkeen' "$(xkeen_is_installed && printf yes || printf no)" "$(get_xkeen_version)"
    print_component 'xkeen-ui (zxc-rv)' "$(xkeen_ui_zxc_is_installed && printf yes || printf no)" "$(get_xkeen_ui_zxc_version)"
    print_component 'xkeen-ui (umarcheh001)' "$(xkeen_ui_umar_is_installed && printf yes || printf no)" "$(get_xkeen_ui_umar_version)"
    _nfui_installed=no
    if is_installed nfqws2-ui || is_installed nfqws-ui || \
       [ -x /opt/sbin/nfqws-ui-setup ] || [ -x /opt/usr/sbin/nfqws-ui-setup ]; then
        _nfui_installed=yes
    fi
    _nfui_version=$(pkg_version nfqws2-ui)
    [ -n "$_nfui_version" ] || _nfui_version=$(pkg_version nfqws-ui)
    print_component 'nfqws-ui' "$_nfui_installed" "${_nfui_version:-неизвестна}"
    if [ -x /opt/bin/dpi-detector ]; then
        _dpi_probe=$(sh -c 'exec /opt/bin/dpi-detector --version' 2>/dev/null)
        _dpi_probe_rc=$?
        _dpi_v=$(printf '%s\n' "$_dpi_probe" | head -n 1)
        if [ "$_dpi_probe_rc" -eq 0 ] && [ -n "$_dpi_v" ]; then
            printf '%s\n' "$_dpi_v" > "$ROOT_DIR/dpi-detector-version" 2>/dev/null || :
            rm -f "$ROOT_DIR/dpi-detector-native-incompatible" "$ROOT_DIR/dpi-detector-python-mode"
        elif [ "$_dpi_probe_rc" -eq 126 ] || [ "$_dpi_probe_rc" -eq 127 ] ||
             [ -f "$ROOT_DIR/dpi-detector-native-incompatible" ]; then
            _dpi_v='ELF несовместим с Entware'
        else
            _dpi_v=$(sed -n '1p' "$ROOT_DIR/dpi-detector-version" 2>/dev/null)
        fi
        print_component 'DPI Detector' yes "${_dpi_v:-версия неизвестна}"
    else
        print_component 'DPI Detector' no ''
    fi
    if is_installed awg-manager; then print_component 'awg-manager' yes "$(pkg_version awg-manager)"; fi
    if [ -x /opt/keenkit.sh ] || command -v keenkit >/dev/null 2>&1; then print_component 'KeenKit' yes "$(read_version_file /opt/keenkit.version 2>/dev/null || printf 'неизвестна')"; fi
    if [ -x /opt/bin/tg-ws-proxy-rs ]; then
        print_component 'TG WS Proxy Rust' yes "$(/opt/bin/tg-ws-proxy-rs --version 2>/dev/null | head -n 1)"
    elif [ -x /opt/bin/tgwsproxy ] || [ -x /opt/etc/init.d/S99tgwsproxy ]; then
        print_component 'TG WS Proxy Rust' yes "$(/opt/bin/tgwsproxy --version 2>/dev/null | head -n 1)"
    fi
    _xrv=$(get_xray_version)
    if [ "$_xrv" = 'не найден' ]; then print_component 'Xray' no ''; else print_component 'Xray' yes "$_xrv"; fi
    _mhv=$(get_mihomo_version)
    if [ "$_mhv" = 'не найден' ]; then print_component 'Mihomo' no ''; else print_component 'Mihomo' yes "$_mhv"; fi
    if command -v crond >/dev/null 2>&1 || is_installed crond || is_installed cronie || is_installed cron; then
        _crond_v=$(pkg_version crond)
        [ -n "$_crond_v" ] || _crond_v=$(pkg_version cronie)
        [ -n "$_crond_v" ] || _crond_v=$(pkg_version cron)
        [ -n "$_crond_v" ] || _crond_v=$(pkg_version busybox)
        if [ -z "$_crond_v" ] && command -v busybox >/dev/null 2>&1; then
            _crond_v=$(busybox 2>&1 | sed -n '1{s/^BusyBox v\([^ ]*\).*/BusyBox \1/p;}')
        fi
        print_component 'crond' yes "${_crond_v:-неизвестна}"
    else print_component 'crond' no ''; fi
    if command -v dropbear >/dev/null 2>&1 || is_installed dropbear; then
        _dropbear_v=$(pkg_version dropbear)
        print_component 'dropbear' yes "${_dropbear_v:-неизвестна}"
    else print_component 'dropbear' no ''; fi

    if [ "$(get_ui_lang)" = en ]; then
        say "${PURPLE}Installed components:${RESET}"
    else
        say "${PURPLE}Установленные компоненты:${RESET}"
    fi
    component_table_header
    while IFS="$(printf '\t')" read -r _row_label _row_version || [ -n "$_row_label" ]; do
        case "$_row_version" in
            'версия неизвестна'|'ELF несовместим с Entware')
                printf '  %s%-22s %s%s %s⚡%s\n' "$PURPLE" "$_row_label" "$YELLOW" "$_row_version" "$GREEN" "$RESET"
                ;;
            *)
                printf '  %s%-22s %s%s %s⚡%s\n' "$PURPLE" "$_row_label" "$PURPLE" "$_row_version" "$GREEN" "$RESET"
                ;;
        esac
    done < "$_COMPONENT_INSTALLED_FILE"
    if [ ! -s "$_COMPONENT_INSTALLED_FILE" ]; then
        if [ "$(get_ui_lang)" = en ]; then say "  ${YELLOW}No managed components installed yet.${RESET}"; else say "  ${YELLOW}Управляемые компоненты пока не установлены.${RESET}"; fi
    fi
    rm -f "$_COMPONENT_INSTALLED_FILE"
}

show_status() {
    _r=$(get_router); _model=${_r%%|*}; _fw=${_r#*|}; _arch=$(get_arch); _arch=${_arch:-не определена}
    if [ "$(get_ui_lang)" = en ]; then
        line; say "${WHITE}Xmenu v$APP_VERSION — STATUS${RESET}"; line
        say "Router: $_model | KeeneticOS: ${_fw:-not detected} | ARCH: $_arch"
    else
        line; say "${WHITE}Xmenu v$APP_VERSION — СТАТУС${RESET}"; line
        say "Роутер: $_model | KeeneticOS: ${_fw:-не определена} | ARCH: $_arch"
    fi
    say ''
    render_component_statuses
    _status_strategy=$(active_strategy_label)
    if [ "$(get_ui_lang)" = en ]; then say "  Active strategy: ${CYAN}$_status_strategy${RESET}"; else say "  Активная стратегия: ${CYAN}$_status_strategy${RESET}"; fi
    ps w 2>/dev/null | grep -q '[m]ihomo' && say "${GREEN}Mihomo: запущен ⚡${RESET}" || :
    ps w 2>/dev/null | grep -q '[n]fqws2' && say "${GREEN}nfqws2: запущен ⚡${RESET}" || :
    if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -Fq 'XMENU_GEOIPSET_DAILY_0430'; then
        say '  GeoIP/GeoIPSet         ежедневно 04:30'
    else
        say '  GeoIP/GeoIPSet         расписание не настроено'
    fi
    if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -Fq '/opt/bin/xmenu sync'; then
        say '  Синхронизация стратегий cron: настроена'
    fi
    say "  Бэкапы: $BACKUP_DIR"
}

# Загружает rkn.list и добавляет его в MODE_LIST, не меняя другие параметры конфига.
install_rkn_for() {
    _rkn_ver=$1
    case "$_rkn_ver" in
        2)
            _rkn_pkg=nfqws2-keenetic
            _rkn_conf=/opt/etc/nfqws2/nfqws2.conf
            _rkn_list=/opt/etc/nfqws2/lists/rkn.list
            _rkn_init=/opt/etc/init.d/S51nfqws2
            ;;
        1)
            _rkn_pkg=nfqws-keenetic
            _rkn_conf=/opt/etc/nfqws/nfqws.conf
            _rkn_list=/opt/etc/nfqws/rkn.list
            _rkn_init=/opt/etc/init.d/S51nfqws
            ;;
        *) return 1 ;;
    esac
    is_installed "$_rkn_pkg" && [ -f "$_rkn_conf" ] || {
        say "${RED}$_rkn_pkg не установлен или конфиг не найден.${RESET}"
        return 1
    }
    _rkn_changed=0
    mkdir -p "$(dirname "$_rkn_list")" "$ROOT_DIR" || return 1
    _rkn_download=1
    if [ -s "$_rkn_list" ]; then
        _rkn_kb=$(awk -v n="$(wc -c < "$_rkn_list" | tr -d ' ')" 'BEGIN{printf "%.0f",n/1024}')
        say "Найден существующий rkn.list (${_rkn_kb} КБ): $_rkn_list"
        if confirm_no 'Обновить rkn.list?'; then _rkn_download=1; else _rkn_download=0; fi
    fi
    if [ "$_rkn_download" = 1 ]; then
        ensure_network || return 1
        _rkn_tmp="$ROOT_DIR/rkn-download-$$.tmp"
        _rkn_url='https://raw.githubusercontent.com/IndeecFOX/zapret4rocket/master/extra_strats/TCP/RKN/List.txt'
        say 'Загружаю актуальный список RKN из zapret4rocket...'
        if ! fetch "$_rkn_url" "$_rkn_tmp" 180; then
            rm -f "$_rkn_tmp"
            say "${RED}Не удалось загрузить rkn.list с GitHub/CDN.${RESET}"
            return 1
        fi
        _rkn_size=$(wc -c < "$_rkn_tmp" 2>/dev/null | tr -d ' ')
        case "$_rkn_size" in ''|*[!0-9]*) _rkn_size=0 ;; esac
        if [ "$_rkn_size" -lt 10000 ] || head -c 256 "$_rkn_tmp" 2>/dev/null | grep -qiE '<html|404: Not Found|Bad Gateway|Not Found'; then
            rm -f "$_rkn_tmp"
            say "${RED}Файл rkn.list слишком мал или содержит страницу ошибки; прежний список сохранён.${RESET}"
            return 1
        fi
        if [ -e "$_rkn_list" ] && [ ! -L "$_rkn_list" ]; then backup_file "$_rkn_list" || { rm -f "$_rkn_tmp"; return 1; }; fi
        [ ! -L "$_rkn_list" ] || { rm -f "$_rkn_tmp"; say 'Путь rkn.list является симлинком; запись отменена.'; return 1; }
        mv "$_rkn_tmp" "$_rkn_list" || { rm -f "$_rkn_tmp"; return 1; }
        chmod 644 "$_rkn_list" 2>/dev/null || :
        _rkn_changed=1
        say "${GREEN}rkn.list загружен ($((_rkn_size / 1024)) КБ).${RESET}"
    fi
    # Add RKN list to MODE_LIST only. Since MODE_AUTO uses $MODE_LIST, the link is inherited there.
    if ! mode_list_has_host "$_rkn_conf" "--hostlist=$_rkn_list"; then
        _rkn_tmpconf="$ROOT_DIR/rkn-conf-$$.tmp"
        awk -v host="--hostlist=$_rkn_list" '
            /^[[:space:]]*MODE_LIST[[:space:]]*=/ {
                if ($0 ~ /"[[:space:]]*$/) {
                    sub(/"[[:space:]]*$/, " " host "\"")
                    found=1
                }
            }
            { print }
            END { if (!found) exit 3 }
        ' "$_rkn_conf" > "$_rkn_tmpconf" || {
            rm -f "$_rkn_tmpconf"
            say "${RED}Не найден MODE_LIST в $_rkn_conf; файл оставлен, конфиг не изменён.${RESET}"
            return 1
        }
        backup_file "$_rkn_conf" || { rm -f "$_rkn_tmpconf"; return 1; }
        cp "$_rkn_tmpconf" "$_rkn_conf" || { rm -f "$_rkn_tmpconf"; return 1; }
        rm -f "$_rkn_tmpconf"
        _rkn_changed=1
        say "${GREEN}rkn.list подключён к MODE_LIST.${RESET}"
    else
        say 'rkn.list уже подключён к MODE_LIST.'
    fi
    if [ "$_rkn_changed" = 1 ]; then
        if [ -x "$_rkn_init" ]; then
            "$_rkn_init" restart || { say "${RED}Изменения сохранены, но перезапуск $_rkn_init завершился ошибкой.${RESET}"; return 1; }
        else
            say "${YELLOW}Изменения сохранены; init-скрипт $_rkn_init не найден, перезапусти движок вручную.${RESET}"
            return 1
        fi
    else
        say 'Список и конфигурация уже актуальны; перезапуск не требуется.'
    fi
    return 0
}

install_rkn_list() {
    _rkn_have2=0; _rkn_have1=0
    is_installed nfqws2-keenetic && [ -f /opt/etc/nfqws2/nfqws2.conf ] && _rkn_have2=1
    is_installed nfqws-keenetic && [ -f /opt/etc/nfqws/nfqws.conf ] && _rkn_have1=1
    if [ "$_rkn_have2" = 0 ] && [ "$_rkn_have1" = 0 ]; then
        say "${RED}Сначала установи nfqws2 или nfqws-keenetic.${RESET}"
        return 1
    elif [ "$_rkn_have2" = 1 ] && [ "$_rkn_have1" = 0 ]; then
        install_rkn_for 2; return $?
    elif [ "$_rkn_have2" = 0 ] && [ "$_rkn_have1" = 1 ]; then
        install_rkn_for 1; return $?
    fi
    line; say 'ЗАГРУЗКА rkn.list'; line
    menu_item 1 'nfqws2-keenetic'
    menu_item 2 'nfqws-keenetic'
    menu_item 3 'Обе версии'
    menu_item 0 'Назад'
    _read_or_eof 'Выбор [0]: ' || return 0
    case "$_read_value" in
        1) install_rkn_for 2 ;;
        2) install_rkn_for 1 ;;
        3) install_rkn_for 2; _rkn_rc2=$?; install_rkn_for 1; _rkn_rc1=$?; [ "$_rkn_rc2" -eq 0 ] && [ "$_rkn_rc1" -eq 0 ] ;;
        ''|0) return 0 ;;
        *) say 'Неверный выбор.'; return 1 ;;
    esac
}

install_tg_ws_proxy_rust() {
    say 'TG WS Proxy Rust — MTProto → WebSocket proxy with local web panel.'
    say 'По умолчанию панель может быть доступна без пароля в LAN; не публикуй порт панели в WAN.'
    run_nfmenu_action menu_tg_ws_proxy_rs
}

install_keenkit() {
    if [ -x /opt/keenkit.sh ]; then
        say 'KeenKit уже найден: запускаю /opt/keenkit.sh.'
        if [ -c /dev/tty ]; then sh /opt/keenkit.sh </dev/tty >/dev/tty 2>&1; else sh /opt/keenkit.sh; fi
        return $?
    fi
    confirm_yes 'Установить KeenKit?' || return 0
    if ! command -v curl >/dev/null 2>&1; then
        opkg update || return 1
        opkg install curl || return 1
    fi
    run_remote_installer 'https://raw.githubusercontent.com/spatiumstas/KeenKit/main/install.sh' 'KeenKit' 500
}

install_awg_manager() {
    say 'AWG Manager требует включённый WireGuard-компонент Keenetic.'
    say 'Будет вызвана установка из актуального nfqws-menu; перед подтверждением проверь репозиторий пакетов и адреса источников.'
    confirm_yes 'Установить или обновить awg-manager?' || return 0
    # Use the current upstream nfqws-menu action instead of a stale direct installer URL.
    run_nfmenu_action menu_awg_manager
}

update_nfmenu_script() {
    ensure_network || return 1
    _ufn_target='/opt/nfqws-menu.sh'
    _ufn_tmp="/opt/nfqws-menu.sh.new.$$"
    say 'Загружаю официальный nfqws-menu.sh для безопасного обновления...'
    if ! fetch "$NF_REPO/nfqws-menu.sh" "$_ufn_tmp" 120; then
        rm -f "$_ufn_tmp"
        say "${RED}Не удалось загрузить nfqws-menu.sh.${RESET}"
        return 1
    fi
    _ufn_size=$(wc -c < "$_ufn_tmp" 2>/dev/null | tr -d ' ')
    case "$_ufn_size" in ''|*[!0-9]*) _ufn_size=0 ;; esac
    if [ "$_ufn_size" -lt 50000 ] || ! grep -q '^SCRIPT_VERSION=' "$_ufn_tmp" ||
       ! grep -q '^main_menu()' "$_ufn_tmp" ||
       [ "$(tail -n 1 "$_ufn_tmp" | tr -d '\r')" != 'main_menu' ] || ! sh -n "$_ufn_tmp"; then
        rm -f "$_ufn_tmp"
        say "${RED}Проверка официального nfqws-menu.sh не пройдена; текущий файл не изменён.${RESET}"
        return 1
    fi
    if [ -f "$_ufn_target" ]; then
        backup_file "$_ufn_target" || { rm -f "$_ufn_tmp"; say "${RED}Не удалось создать резервную копию nfqws-menu.sh.${RESET}"; return 1; }
    fi
    chmod 700 "$_ufn_tmp" || { rm -f "$_ufn_tmp"; return 1; }
    mv -f "$_ufn_tmp" "$_ufn_target" || { rm -f "$_ufn_tmp"; return 1; }
    chmod 700 "$_ufn_target" 2>/dev/null || :
    say "${GREEN}Официальный nfqws-menu.sh обновлён. Xmenu оставлен без изменений.${RESET}"
    return 0
}

change_ui_language() {
    _lang_now=$(get_ui_lang)
    if [ "$_lang_now" = en ]; then set_ui_lang ru; else set_ui_lang en; fi
}


# Executes one action from the current official nfqws-menu without leaving the
# Xmenu main menu. The downloaded script is syntax-checked and its entry point
# is replaced only in a temporary /tmp copy; the installed nfqws-menu is untouched.
run_nfmenu_action() {
    _rnf_action=${1:-}
    case "$_rnf_action" in
        menu_install_nfqws|update_ipset_list|update_rkn_list|menu_dot_doh|menu_change_fake_blob|menu_update_hosts|menu_dns_manage|menu_dpi_detector|menu_awg_manager|menu_keenkit|menu_usque_keenetic|menu_magitrickle|menu_telemt|menu_tg_ws_proxy_rs|remove_tg_ws_proxy_rs|menu_service|opkg_upgrade_all) : ;;
        *) say "${RED}Неизвестное действие nfqws-menu.${RESET}"; return 2 ;;
    esac
    ensure_network || return 1
    _rnf_src="/tmp/xmenu-nfqws-source-$$.sh"
    _rnf_run="/tmp/xmenu-nfqws-action-$$.sh"
    rm -f "$_rnf_src" "$_rnf_run"
    say "Загружаю официальный nfqws-menu для действия: $_rnf_action"
    if ! fetch "$NF_REPO/nfqws-menu.sh" "$_rnf_src" 90; then
        rm -f "$_rnf_src" "$_rnf_run"
        say "${RED}Не удалось получить актуальный nfqws-menu.${RESET}"
        return 1
    fi
    _rnf_size=$(wc -c < "$_rnf_src" 2>/dev/null | tr -d ' ')
    case "$_rnf_size" in ''|*[!0-9]*) _rnf_size=0 ;; esac
    if [ "$_rnf_size" -lt 50000 ] || ! grep -q '^SCRIPT_VERSION=' "$_rnf_src" ||
       ! grep -q '^main_menu()' "$_rnf_src" || [ "$(tail -n 1 "$_rnf_src" | tr -d '\r')" != 'main_menu' ] ||
       ! grep -Eq "^${_rnf_action}[[:space:]]*\(\)[[:space:]]*\{" "$_rnf_src" || ! sh -n "$_rnf_src"; then
        rm -f "$_rnf_src" "$_rnf_run"
        say "${RED}Проверка источника nfqws-menu не пройдена; выполнение отменено.${RESET}"
        return 1
    fi
    if ! sed '$d' "$_rnf_src" > "$_rnf_run"; then
        rm -f "$_rnf_src" "$_rnf_run"
        return 1
    fi
    cat >> "$_rnf_run" <<'XMENU_NFQWS_ACTION_EOF'
case "${XMENU_NFQWS_ACTION:-menu}" in
  menu) main_menu ;;
  menu_install_nfqws) menu_install_nfqws ;;
  update_ipset_list) update_ipset_list ;;
  update_rkn_list) update_rkn_list ;;
  menu_dot_doh) menu_dot_doh ;;
  menu_change_fake_blob) menu_change_fake_blob ;;
  menu_update_hosts) menu_update_hosts ;;
  menu_dns_manage) menu_dns_manage ;;
  menu_dpi_detector) menu_dpi_detector ;;
  menu_awg_manager) menu_awg_manager ;;
  menu_keenkit) menu_keenkit ;;
  menu_usque_keenetic) menu_usque_keenetic ;;
  menu_magitrickle) menu_magitrickle ;;
  menu_telemt) menu_telemt ;;
  menu_tg_ws_proxy_rs) menu_tg_ws_proxy_rs ;;
  remove_tg_ws_proxy_rs) remove_tg_ws_proxy_rs ;;
  menu_service) menu_service ;;
  opkg_upgrade_all) opkg_upgrade_all ;;
  *) printf '%s\n' 'Unsupported action' >&2; exit 2 ;;
esac
XMENU_NFQWS_ACTION_EOF
    if ! sh -n "$_rnf_run"; then
        rm -f "$_rnf_src" "$_rnf_run"
        say "${RED}Проверка временного сценария nfqws-menu не пройдена.${RESET}"
        return 1
    fi
    _rnf_rc=0
    if [ -c /dev/tty ]; then
        NFQWS_MENU_LANG="$(get_ui_lang)" XMENU_NFQWS_ACTION="$_rnf_action" sh "$_rnf_run" </dev/tty >/dev/tty 2>&1 || _rnf_rc=$?
    else
        NFQWS_MENU_LANG="$(get_ui_lang)" XMENU_NFQWS_ACTION="$_rnf_action" sh "$_rnf_run" || _rnf_rc=$?
    fi
    rm -f "$_rnf_src" "$_rnf_run"
    drain_stdin
    return "$_rnf_rc"
}

xmenu_install_menu() {
    while :; do
        line
        if [ "$(get_ui_lang)" = en ]; then
            say "${PURPLE}[::]  Install / update components${RESET}"
            menu_item 1 'Official NFQWS / NFQWS2 installer'
            menu_item 2 'nfqws2-keenetic'
            menu_item 3 'nfqws-web-keenetic'
            menu_item 4 'nfqws2-ui'
            menu_item 5 'XKeen — Stable'
            menu_item 6 'XKeen UI — zxc-rv'
            menu_item 7 'XKeen UI — umarcheh001'
            menu_item 8 'XKeen Auto (Mihomo + GeoIPSet)'
            menu_item 9 'XKeen Auto (Xray + GeoIPSet)'
            menu_item 10 'Mihomo + GeoIPSet + XKeen UI + NFQWS bundle'
            menu_item 11 'Xray + GeoIPSet + XKeen UI + NFQWS bundle'
            menu_item 0 'Back'
            _sub_prompt='Your choice [0 = back]: '
        else
            say "${PURPLE}[::]  Установка / обновление компонентов${RESET}"
            menu_item 1 'Официальная установка NFQWS / NFQWS2'
            menu_item 2 'nfqws2-keenetic'
            menu_item 3 'nfqws-web-keenetic'
            menu_item 4 'nfqws2-ui'
            menu_item 5 'XKeen — Stable'
            menu_item 6 'XKeen UI — zxc-rv'
            menu_item 7 'XKeen UI — umarcheh001'
            menu_item 8 'XKeen Auto (Mihomo + GeoIPSet)'
            menu_item 9 'XKeen Auto (Xray + GeoIPSet)'
            menu_item 10 'Mihomo + GeoIPSet + XKeen UI + NFQWS'
            menu_item 11 'Xray + GeoIPSet + XKeen UI + NFQWS'
            menu_item 0 'Назад'
            _sub_prompt='Ваш выбор [0 = назад]: '
        fi
        line
        _read_or_eof "$_sub_prompt" || return 0
        _sub_choice=$_read_value
        case "$_sub_choice" in
            ''|0) return 0 ;;
            *[!0-9]*) say "${RED}Введите номер цифрами.${RESET}"; continue ;;
            1) run_nfmenu_action menu_install_nfqws; pause ;;
            2) ensure_network && install_nfqws2; pause ;;
            3) ensure_network && install_nf_web; pause ;;
            4) ensure_network && install_nf_web2; pause ;;
            5) ensure_network && install_xkeen_stable_binary; pause ;;
            6) ensure_network && install_xkeen_ui; pause ;;
            7) ensure_network && install_xkeen_ui_umarcheh001; pause ;;
            8) install_xkeen_core_profile mihomo; pause ;;
            9) install_xkeen_core_profile xray; pause ;;
            10) install_manual_bundle_profile mihomo; pause ;;
            11) install_manual_bundle_profile xray; pause ;;
            *) say "${RED}Нет такого пункта.${RESET}"; sleep 1 ;;
        esac
    done
}

xmenu_service_menu() {
    while :; do
        line
        if [ "$(get_ui_lang)" = en ]; then
            say "${PURPLE}[::]  Xmenu service tools${RESET}"
            menu_item 1 'Check/download blobs and lists of active config'
            menu_item 2 'Install all nfqws2 blobs'
            menu_item 3 'Status and versions'
            menu_item 4 'Official nfqws-menu service tools (UPX / Dropbear)'
            menu_item 5 'Manual install profiles'
            menu_item 6 'Remove Xmenu'
            menu_item 0 'Back'
            _sub_prompt='Your choice [0 = back]: '
        else
            say "${PURPLE}[::]  Сервисные инструменты Xmenu${RESET}"
            menu_item 1 'Проверить/скачать blobs и lists активной стратегии'
            menu_item 2 'Установить все blobs nfqws2'
            menu_item 3 'Статус и версии'
            menu_item 4 'Сервисные инструменты nfqws-menu (UPX / Dropbear)'
            menu_item 5 'Ручные профили установки'
            menu_item 6 'Удалить Xmenu'
            menu_item 0 'Назад'
            _sub_prompt='Ваш выбор [0 = назад]: '
        fi
        line
        _read_or_eof "$_sub_prompt" || return 0
        _svc_choice=$_read_value
        case "$_svc_choice" in
            ''|0) return 0 ;;
            1) sync_active_blobs; pause ;;
            2) install_all_nfqw2_blobs; pause ;;
            3) show_status; pause ;;
            4) run_nfmenu_action menu_service; pause ;;
            5) xmenu_install_menu ;;
            6)
                remove_menu
                [ "${XMENU_REMOVED:-0}" = 1 ] && return 10
                ;;
            *[!0-9]*) say "${RED}Введите номер цифрами.${RESET}" ;;
            *) say "${RED}Нет такого пункта.${RESET}"; sleep 1 ;;
        esac
    done
}

render_menu() {
    [ -t 1 ] && printf '\033[2J\033[H'
    _lang=$(get_ui_lang)
    _r=$(get_router); _model=${_r%%|*}; _fw=${_r#*|}; _arch=$(get_arch)
    # Одна строка заголовка без дополнительных рамок. Длину считаем в
    # видимых UTF-8 символах, а не в байтах (◆ занимает один столбец).
    _title="Xmenu ◆ v$APP_VERSION"
    _title_cells=$(printf '%s\n' "$_title" | LC_ALL=C awk '{s=$0; gsub(/[\200-\277]/, "", s); print length(s)}')
    case "$_title_cells" in ''|*[!0-9]*) _title_cells=12 ;; esac
    _title_line_cells=$((_title_cells + 4))
    # FIX: заголовок намеренно прижат к левому краю терминала.
    # Не вычислять отступ от COLUMNS/stty: на роутерах эти значения могут
    # различаться и снова визуально уводить заголовок далеко вправо.
    _title_pad=0
    _title_pad_text=''
    printf '%s%s %s%s%s %s\n' \
        "$_title_pad_text" "${PURPLE}|${RESET}" "$WHITE" "$_title" "$RESET" "${PURPLE}|${RESET}"
    say ''

    # Architecture uses nfqws-menu order: opkg print-architecture -> opkg.conf -> uname -m.
    _cpu=$_arch
    if [ -z "$_cpu" ]; then
        if [ "$_lang" = en ]; then _cpu='not detected'; else _cpu='не определена'; fi
    fi
    if [ -z "$_arch" ]; then
        if [ "$_lang" = en ]; then _arch='not detected'; else _arch='не определена'; fi
    fi

    if [ "$_lang" = en ]; then
        printf '  Router:       %s%s%s\n' "$CYAN" "$_model" "$RESET"
        printf '  KeeneticOS:   %s%s%s\n' "$CYAN" "${_fw:-not detected}" "$RESET"
        printf '  Processor:    %s%s%s\n' "$GREEN" "$_cpu" "$RESET"
    else
        # Пробелы заданы явно: позиция значений одинаковая и в BusyBox без locale.
        printf '  Роутер:      %s%s%s\n' "$CYAN" "$_model" "$RESET"
        printf '  KeeneticOS:  %s%s%s\n' "$CYAN" "${_fw:-не определена}" "$RESET"
        printf '  Процессор:   %s%s%s\n' "$GREEN" "$_cpu" "$RESET"
    fi
    say ''
    render_component_statuses
    line

    if [ "$_lang" = en ]; then
        say "${PURPLE}[::]  Install / update:${RESET}"
        menu_item 1  'XKeen — Stable'
        menu_item 2  'XKeen UI — zxc-rv'
        menu_item 3  'XKeen UI — umarcheh001'
        menu_item 4  'nfqws2'
        menu_item 5  'nfqws-web-keenetic'
        menu_item 6  'nfqws2-ui'
        say ''
        say "${PURPLE}[::]  Manual installation profiles:${RESET}"
        menu_item 7  'XKeen Auto (Mihomo + GeoIPSet + XKeen at startup)'
        menu_item 8  'XKeen Auto (Xray + GeoIPSet + XKeen at startup)'
        menu_item 9  'Mihomo + GeoIPSet + XKeen Auto + XKeen UI + nfqws2 + nfqws-web-keenetic'
        menu_item 10 'Xray + GeoIPSet + XKeen Auto + XKeen UI + nfqws2 + nfqws-web-keenetic'
        say ''
        say "${PURPLE}[::]  Strategies / blobs / lists:${RESET}"
        menu_item 11 'Select and apply nfqws strategy'
        menu_item 12 'Download/check blobs and lists for active strategy from the list'
        menu_item 13 'Install all required blobs'
        menu_item 14 'Download rkn.list (nfqws2 / nfqws) — 125k+ domains'
        say ''
        say "${PURPLE}[::]  Utilities / diagnostics:${RESET}"
        menu_item 15 'DPI Detector (DNS/16 KB)'
        menu_item 16 'TG WS Proxy Rust'
        menu_item 17 'KeenKit (install / launch)'
        menu_item 18 'awg-manager'
        menu_item 19 'Status and versions'
        menu_item 20 'Change language: RU / EN'
        say ''
        say "${PURPLE}[::]  Package removal:${RESET}"
        menu_item 21 'Remove components'
        menu_item 22 'Remove Xmenu'
        menu_item 0  'Exit'
        _prompt='[?] Select an option [Enter = exit]: '
    else
        say "${PURPLE}[::]  Установка / обновление:${RESET}"
        menu_item 1  'XKeen — Stable'
        menu_item 2  'XKeen UI — zxc-rv'
        menu_item 3  'XKeen UI — umarcheh001'
        menu_item 4  'nfqws2'
        menu_item 5  'nfqws-web-keenetic'
        menu_item 6  'nfqws2-ui'
        say ''
        say "${PURPLE}[::]  Ручные настройки установки:${RESET}"
        menu_item 7  'XKeen Auto (Mihomo + GeoIPSet + XKeen в автозагрузке)'
        menu_item 8  'XKeen Auto (Xray + GeoIPSet + XKeen в автозагрузке)'
        menu_item 9  'Mihomo + GeoIPSet + XKeen Auto + XKeen UI + nfqws2 + nfqws-web-keenetic'
        menu_item 10 'Xray + GeoIPSet + XKeen Auto + XKeen UI + nfqws2 + nfqws-web-keenetic'
        say ''
        say "${PURPLE}[::]  Стратегии / blobs / lists:${RESET}"
        menu_item 11 'Выбрать и применить стратегию nfqws'
        menu_item 12 'Скачать/проверить blobs и lists активной стратегии из списка'
        menu_item 13 'Установить все необходимые blobs'
        menu_item 14 'Скачать rkn.list (nfqws2 / nfqws) — 125k+ доменов'
        say ''
        say "${PURPLE}[::]  Утилиты и диагностика:${RESET}"
        menu_item 15 'DPI Detector (DNS/16kb)'
        menu_item 16 'TG WS Proxy Rust'
        menu_item 17 'KeenKit (установка / запуск)'
        menu_item 18 'awg-manager'
        menu_item 19 'Статус и версии'
        menu_item 20 'Сменить язык: RU / EN'
        say ''
        say "${PURPLE}[::]  Удаление пакетов:${RESET}"
        menu_item 21 'Удаление компонентов'
        menu_item 22 'Удалить Xmenu'
        menu_item 0  'Выход'
        _prompt='[?] Выберите пункт [Enter = выход]: '
    fi
    line
}

# ---------------------------- Component removal ----------------------------
# All removal operations are explicit, confirmation-protected, and preserve
# user configs unless the user selects a separate cleanup action.
remove_nf2_component() {
    _rnc_pkg=${1:-}
    case "$_rnc_pkg" in
        nfqws2-keenetic|nfqws-keenetic-web|nfqws-keenetic) : ;;
        *) say "${RED}Недопустимое имя пакета для удаления.${RESET}"; return 2 ;;
    esac
    is_installed "$_rnc_pkg" || { say "Пакет $_rnc_pkg не установлен."; return 0; }
    confirm "Удалить пакет $_rnc_pkg? Конфиги будут сохранены." || { say 'Удаление отменено.'; return 1; }
    opkg remove "$_rnc_pkg"
}

remove_nfui_component() {
    _rnui_found=0
    for _rnui_pkg in nfqws2-ui nfqws-ui; do
        if is_installed "$_rnui_pkg"; then _rnui_found=1; fi
    done
    if [ "$_rnui_found" -eq 0 ]; then
        say 'Не найден установленный пакет NFQWS UI. Файлы вручную не удалял.'
        return 1
    fi
    confirm 'Удалить установленный пакет NFQWS UI? Общие зависимости будут сохранены.' || { say 'Удаление отменено.'; return 1; }
    _rnui_rc=0
    for _rnui_pkg in nfqws2-ui nfqws-ui; do
        if is_installed "$_rnui_pkg"; then opkg remove "$_rnui_pkg" || _rnui_rc=1; fi
    done
    return "$_rnui_rc"
}

remove_dpi_detector_component() {
    [ -x /opt/bin/dpi-detector ] || { say 'DPI Detector не найден.'; return 0; }
    confirm 'Удалить бинарный файл DPI Detector и его init-скрипт? Конфигурации и журналы будут сохранены.' || { say 'Удаление отменено.'; return 1; }
    for _rdp_init in /opt/etc/init.d/S99dpi-detector /opt/etc/init.d/S99dpi_detector; do
        [ -x "$_rdp_init" ] || continue
        "$_rdp_init" stop >/dev/null 2>&1 || :
        rm -f "$_rdp_init"
    done
    rm -f /opt/bin/dpi-detector
    rm -f "$ROOT_DIR/dpi-detector-version" "$ROOT_DIR/dpi-detector-native-incompatible" "$ROOT_DIR/dpi-detector-python-mode"
    say 'Бинарный файл DPI Detector удалён; конфигурации/журналы сохранены.'
}

remove_xkeen_ui_zxc() {
    confirm 'Удалить XKeen UI (zxc-rv), сохранив общие зависимости? Конфиг lighttpd будет убран только для этой панели.' || { say 'Удаление отменено.'; return 1; }
    [ ! -x /opt/etc/init.d/S99xkeen-ui ] || /opt/etc/init.d/S99xkeen-ui stop >/dev/null 2>&1 || :
    rm -f /opt/sbin/xkeen-ui /opt/etc/init.d/S99xkeen-ui /opt/etc/lighttpd/conf.d/90-xkeenui.conf
    rm -rf /opt/share/www/XKeen-UI
    if [ -x /opt/etc/init.d/S80lighttpd ]; then /opt/etc/init.d/S80lighttpd restart >/dev/null 2>&1 || :; fi
    say 'XKeen UI zxc-rv удалён; lighttpd и прочие зависимости оставлены.'
}

remove_xkeen_ui_umarcheh001() {
    _rum_uninstall='/opt/etc/xkeen-ui/uninstall.sh'
    if [ ! -f "$_rum_uninstall" ]; then
        say "${YELLOW}Не найден официальный uninstall.sh ($_rum_uninstall). Ничего не удалено, чтобы не повредить конфиги.${RESET}"
        say 'Переустанови/удали панель по инструкции её текущей версии.'
        return 1
    fi
    confirm 'Запустить официальный uninstall.sh панели XKeen UI (umarcheh001)?' || { say 'Удаление отменено.'; return 1; }
    sh "$_rum_uninstall"
}

remove_xkeen_component() {
    confirm 'Выполнить полное удаление XKeen штатной командой xkeen -remove? Перед продолжением рекомендуется сохранить конфиги.' || { say 'Удаление отменено.'; return 1; }
    if [ -x /opt/sbin/xkeen ]; then
        /opt/sbin/xkeen -remove
    else
        say "${RED}Не найден /opt/sbin/xkeen. Автоматическое удаление не выполнено.${RESET}"
        return 1
    fi
}

remove_xkeen_core() {
    _rxc_core=${1:-}
    case "$_rxc_core" in xray|mihomo) : ;; *) say 'Неизвестное ядро.'; return 2 ;; esac
    if is_installed "$_rxc_core"; then
        confirm "Удалить пакет $_rxc_core? Пользовательские конфиги будут сохранены." || { say 'Удаление отменено.'; return 1; }
        opkg remove "$_rxc_core"
        return $?
    fi
    if [ "$_rxc_core" = xray ] && [ -x /opt/sbin/xkeen ]; then
        confirm 'Удалить Xray штатной командой xkeen -dx? Конфиги Xray могут быть затронуты самой XKeen.' || { say 'Удаление отменено.'; return 1; }
        /opt/sbin/xkeen -dx
        return $?
    fi
    say "${YELLOW}$_rxc_core не является отдельным opkg-пакетом. Автоматическое удаление бинарника отключено, чтобы не повредить управление XKeen/конфиги.${RESET}"
    return 1
}

remove_all_nf_components() {
    confirm 'Удалить все установленные пакеты NFQWS и NFQWS UI? Пользовательские конфиги будут сохранены.' || { say 'Удаление отменено.'; return 1; }
    _ran_failed=0
    for _ran_pkg in nfqws2-ui nfqws-ui nfqws-keenetic-web nfqws2-keenetic nfqws-keenetic; do
        if is_installed "$_ran_pkg"; then
            say "Удаление пакета $_ran_pkg..."
            opkg remove "$_ran_pkg" || _ran_failed=1
        fi
    done
    if [ "$_ran_failed" -eq 0 ]; then say 'Пакеты NFQWS удалены (если были установлены); конфиги сохранены.'
    else say "${RED}Не удалось удалить один или несколько пакетов. Проверь вывод opkg.${RESET}"; fi
    return "$_ran_failed"
}

# Добавляет установленный компонент в динамический список удаления.
_remove_menu_add() {
    _rma_code=$1
    _rma_label=$2
    printf '%s\t%s\n' "$_rma_code" "$_rma_label" >> "$_REMOVE_MENU_FILE"
}

remove_component_backups() {
    command -v find >/dev/null 2>&1 || { say "${RED}Команда find не найдена.${RESET}"; return 1; }
    confirm_no 'Удалить резервные файлы *.bak, *.bak.* и *-opkg в каталогах конфигурации?' || { say 'Очистка отменена.'; return 1; }
    _rb_list="$ROOT_DIR/remove-backups-list.$$"
    : > "$_rb_list" || return 1
    for _rb_dir in /opt/etc/nfqws /opt/etc/nfqws2 /opt/etc/xkeen /opt/etc/lighttpd /opt/etc/xkeen-menu/backups; do
        [ -d "$_rb_dir" ] || continue
        find "$_rb_dir" -type f \( -name '*.bak' -o -name '*.bak.*' -o -name '*-opkg' \) -print 2>/dev/null >> "$_rb_list"
    done
    if [ ! -s "$_rb_list" ]; then
        rm -f "$_rb_list"
        say 'Резервные файлы указанного типа не найдены.'
        return 0
    fi
    _rb_count=$(wc -l < "$_rb_list" | tr -d ' ')
    say "Будет удалено резервных файлов: $_rb_count"
    while IFS= read -r _rb_file || [ -n "$_rb_file" ]; do
        [ -n "$_rb_file" ] && printf '  %s\n' "$_rb_file"
    done < "$_rb_list"
    confirm_no 'Подтвердить удаление перечисленных резервных файлов?' || { rm -f "$_rb_list"; say 'Очистка отменена.'; return 1; }
    _rb_removed=0
    _rb_failed=0
    while IFS= read -r _rb_file || [ -n "$_rb_file" ]; do
        [ -n "$_rb_file" ] || continue
        if rm -f "$_rb_file" 2>/dev/null; then
            _rb_removed=$((_rb_removed + 1))
        else
            _rb_failed=$((_rb_failed + 1))
            say "${RED}Не удалось удалить: $_rb_file${RESET}"
        fi
    done < "$_rb_list"
    rm -f "$_rb_list"
    say "Удалено резервных файлов: $_rb_removed"
    [ "$_rb_failed" -eq 0 ]
}

# Подменю показывает только реально обнаруженные компоненты Xmenu.
remove_components_menu() {
    while :; do
        _REMOVE_MENU_FILE="$ROOT_DIR/.remove-components.$$"
        : > "$_REMOVE_MENU_FILE" || return 1
        _rm_lang=$(get_ui_lang)
        line
        if [ "$_rm_lang" = en ]; then
            say "${WHITE}REMOVE COMPONENTS${RESET}"
            say 'Only detected components are shown. Shared dependencies are not removed automatically.'
        else
            say "${WHITE}УДАЛЕНИЕ КОМПОНЕНТОВ${RESET}"
            say 'Показываются только установленные компоненты. Общие зависимости автоматически не удаляются.'
        fi
        line

        if [ "$_rm_lang" = en ]; then
            xkeen_is_installed && _remove_menu_add xkeen 'XKeen — uninstall'
            xkeen_ui_zxc_is_installed && _remove_menu_add ui-zxc 'XKeen UI — zxc-rv'
            xkeen_ui_umar_is_installed && _remove_menu_add ui-umar 'XKeen UI — umarcheh001'
            [ -x /opt/bin/dpi-detector ] && _remove_menu_add dpi 'DPI Detector'
            is_installed awg-manager && _remove_menu_add awg 'awg-manager'
            { [ -x /opt/bin/tgwsproxy ] || [ -x /opt/etc/init.d/S99tgwsproxy ] || [ -x /opt/bin/tg-ws-proxy-rs ] || [ -x /opt/etc/init.d/S99tg-ws-proxy-rs ]; } && _remove_menu_add tgws 'TG WS Proxy Rust'
            { [ -x /opt/keenkit.sh ] || [ -L /opt/bin/keenkit ]; } && _remove_menu_add keenkit 'KeenKit'
            is_installed nfqws2-keenetic && _remove_menu_add nfqws2 'nfqws2-keenetic'
            is_installed nfqws-keenetic-web && _remove_menu_add nfweb 'nfqws-keenetic-web'
            is_installed nfqws-keenetic && _remove_menu_add nfqws1 'nfqws-keenetic'
            if is_installed nfqws2-ui || is_installed nfqws-ui || [ -x /opt/sbin/nfqws-ui-setup ] || [ -x /opt/usr/sbin/nfqws-ui-setup ]; then
                _remove_menu_add nfui 'NFQWS UI'
            fi
            [ "$(get_xray_version)" != 'не найден' ] && _remove_menu_add xray 'Xray'
            [ "$(get_mihomo_version)" != 'не найден' ] && _remove_menu_add mihomo 'Mihomo'
        else
            xkeen_is_installed && _remove_menu_add xkeen 'XKeen — полная деинсталляция'
            xkeen_ui_zxc_is_installed && _remove_menu_add ui-zxc 'XKeen UI — zxc-rv'
            xkeen_ui_umar_is_installed && _remove_menu_add ui-umar 'XKeen UI — umarcheh001'
            [ -x /opt/bin/dpi-detector ] && _remove_menu_add dpi 'DPI Detector'
            is_installed awg-manager && _remove_menu_add awg 'awg-manager'
            { [ -x /opt/bin/tgwsproxy ] || [ -x /opt/etc/init.d/S99tgwsproxy ] || [ -x /opt/bin/tg-ws-proxy-rs ] || [ -x /opt/etc/init.d/S99tg-ws-proxy-rs ]; } && _remove_menu_add tgws 'TG WS Proxy Rust'
            { [ -x /opt/keenkit.sh ] || [ -L /opt/bin/keenkit ]; } && _remove_menu_add keenkit 'KeenKit'
            is_installed nfqws2-keenetic && _remove_menu_add nfqws2 'nfqws2-keenetic'
            is_installed nfqws-keenetic-web && _remove_menu_add nfweb 'nfqws-keenetic-web'
            is_installed nfqws-keenetic && _remove_menu_add nfqws1 'nfqws-keenetic'
            if is_installed nfqws2-ui || is_installed nfqws-ui || [ -x /opt/sbin/nfqws-ui-setup ] || [ -x /opt/usr/sbin/nfqws-ui-setup ]; then
                _remove_menu_add nfui 'NFQWS UI'
            fi
            [ "$(get_xray_version)" != 'не найден' ] && _remove_menu_add xray 'Xray'
            [ "$(get_mihomo_version)" != 'не найден' ] && _remove_menu_add mihomo 'Mihomo'
        fi

        _rm_idx=0
        if [ -s "$_REMOVE_MENU_FILE" ]; then
            while IFS="$(printf '\t')" read -r _rm_code _rm_label || [ -n "$_rm_code" ]; do
                _rm_idx=$((_rm_idx + 1))
                menu_item "$_rm_idx" "$_rm_label"
            done < "$_REMOVE_MENU_FILE"
        else
            if [ "$_rm_lang" = en ]; then
                say "  ${YELLOW}No installed components detected.${RESET}"
            else
                say "  ${YELLOW}Нет обнаруженных компонентов для удаления.${RESET}"
            fi
        fi

        # Все действия имеют числовые номера, выдаваемые после списка компонентов.
        _rm_all_idx=$((_rm_idx + 1))
        _rm_backup_idx=$((_rm_idx + 2))
        if [ "$_rm_lang" = en ]; then
            menu_item "$_rm_all_idx" 'Remove all NFQWS packages'
            menu_item "$_rm_backup_idx" 'Remove backup files (*.bak, *.bak.* / *-opkg)'
            menu_item 0 'Back'
            _rm_prompt='Choose a number [0 = back]: '
        else
            menu_item "$_rm_all_idx" 'Удалить все пакеты NFQWS'
            menu_item "$_rm_backup_idx" 'Удалить резервные копии (*.bak, *.bak.* / *-opkg)'
            menu_item 0 'Назад'
            _rm_prompt='Что удалить? Ваш выбор [0 = назад]: '
        fi
        line
        _read_or_eof "$_rm_prompt" || { rm -f "$_REMOVE_MENU_FILE"; return 0; }
        _rm_choice=$_read_value
        case "$_rm_choice" in
            ''|0) rm -f "$_REMOVE_MENU_FILE"; return 0 ;;
            *[!0-9]*)
                if [ "$_rm_lang" = en ]; then say "${RED}Enter a number only.${RESET}"; else say "${RED}Введи номер цифрами.${RESET}"; fi
                rm -f "$_REMOVE_MENU_FILE"
                continue
                ;;
        esac
        # Нормализуем ведущие нули, чтобы ввод 08/09 не зависел от арифметики shell.
        while [ "${_rm_choice#0}" != "$_rm_choice" ]; do _rm_choice=${_rm_choice#0}; done
        [ -n "$_rm_choice" ] || _rm_choice=0
        case "$_rm_choice" in
            0) rm -f "$_REMOVE_MENU_FILE"; return 0 ;;
            "$_rm_all_idx") remove_all_nf_components ;;
            "$_rm_backup_idx") remove_component_backups ;;
            *)
                _rm_code=$(sed -n "${_rm_choice}p" "$_REMOVE_MENU_FILE" 2>/dev/null | cut -f1)
                case "$_rm_code" in
                    xkeen) remove_xkeen_component ;;
                    ui-zxc) remove_xkeen_ui_zxc ;;
                    ui-umar) remove_xkeen_ui_umarcheh001 ;;
                    dpi) remove_dpi_detector_component ;;
                    awg)
                        if confirm 'Удалить пакет awg-manager (настройки в /opt/etc/awg-manager сохранятся)?'; then
                            opkg remove awg-manager || say "${RED}Не удалось удалить awg-manager.${RESET}"
                        fi
                        ;;
                    tgws)
                        if confirm 'Удалить TG WS Proxy Rust, сохранив настройки?'; then
                            if [ -x /opt/etc/init.d/S99tg-ws-proxy-rs ] || [ -x /opt/bin/tg-ws-proxy-rs ]; then
                                run_nfmenu_action remove_tg_ws_proxy_rs
                            else
                                say "${YELLOW}Обнаружен старый путь TG WS Proxy. Автоудаление старой реализации отключено: её установщик не относится к текущему официальному nfqws-menu.${RESET}"
                                say 'Проверь пакет в opkg list-installed и используй инструкцию именно той версии, которая была установлена.'
                            fi
                        fi
                        ;;
                    keenkit)
                        if confirm 'Удалить KeenKit (/opt/keenkit.sh)?'; then
                            rm -f /opt/keenkit.sh
                            [ ! -L /opt/bin/keenkit ] || rm -f /opt/bin/keenkit
                            say 'KeenKit удалён.'
                        fi
                        ;;
                    nfqws2) remove_nf2_component nfqws2-keenetic ;;
                    nfweb) remove_nf2_component nfqws-keenetic-web ;;
                    nfqws1) remove_nf2_component nfqws-keenetic ;;
                    nfui) remove_nfui_component ;;
                    xray) remove_xkeen_core xray ;;
                    mihomo) remove_xkeen_core mihomo ;;
                    *)
                        if [ "$_rm_lang" = en ]; then say "${RED}No component at that number.${RESET}"; else say "${RED}Нет компонента с таким номером.${RESET}"; fi
                        ;;
                esac
                ;;
        esac
        rm -f "$_REMOVE_MENU_FILE"
        say ''
        if [ "$_rm_lang" = en ]; then _read_or_eof 'Press Enter to refresh component list...' || return 0
        else _read_or_eof 'Enter — обновить список компонентов...' || return 0
        fi
    done
}

remove_menu() {
    XMENU_REMOVED=0
    if ! confirm 'Удалить только /opt/bin/xmenu и его задание автообновления?'; then return 1; fi
    _remove_backups=0
    confirm 'Удалить также конфигурацию xmenu (manifest-ы, кэш, бэкапы)?' && _remove_backups=1
    _c="$ROOT_DIR/crontab.$$"
    crontab -l 2>/dev/null | grep -Fv '/opt/bin/xmenu sync' | grep -Fv 'XMENU_GEOIPSET_DAILY_0430' > "$_c" || :
    crontab "$_c" 2>/dev/null || :
    rm -f "$_c" /opt/bin/xmenu
    # Всегда удаляем манифесты и маркеры Xmenu; бэкапы сохраняем без отдельного подтверждения.
    rm -rf "$ROOT_DIR/manifests"
    rm -f "$ROOT_DIR/xkeen-channel" "$ROOT_DIR"/first-run-* "$ROOT_DIR"/active-strategy-*
    rm -f "$ROOT_DIR"/strategies.list "$ROOT_DIR"/apply-*.conf "$ROOT_DIR"/crontab.*
    rm -f "$ROOT_DIR"/.base-ready
    if [ "$_remove_backups" = 1 ]; then
        rm -rf "$BACKUP_DIR"
        rmdir "$ROOT_DIR" 2>/dev/null || :
        say "${GREEN}Xmenu удалён вместе с конфигурацией и бэкапами. XKeen/nfqws2 сохранены.${RESET}"
    else
        say "${GREEN}Xmenu удалён. Бэкапы сохранены в $BACKUP_DIR; manifests и маркеры очищены.${RESET}"
    fi
    XMENU_REMOVED=1
    return 0
}

main() {
    configure_locale
    require_root || return 1
    require_opkg || return 1
    ensure_dirs || return 1
    [ -s "$LANG_FILE" ] || printf 'ru\n' > "$LANG_FILE" 2>/dev/null || :
    case "${1:-menu}" in
        sync|update-strategies)
            ensure_network || return 1
            sync_active_blobs
            return $? ;;
        status) show_status; return $? ;;
        install-all)
            if [ "${2:-}" = --yes ]; then XKEEN_MENU_AUTO_YES=1; export XKEEN_MENU_AUTO_YES; fi
            ensure_network || return 1
            install_all_missing
            _install_all_rc=$?
            show_status
            return "$_install_all_rc" ;;
        install-xkeen)
            ensure_network || return 1
            install_xkeen_auto
            return $? ;;
        install-xkeen-ui)
            ensure_network || return 1
            install_xkeen_ui
            return $? ;;
        install-xkeen-ui-umarcheh001)
            ensure_network || return 1
            install_xkeen_ui_umarcheh001
            return $? ;;
        install-nfqws2|install-nf-web|install-nf-web2|install-dpi-detector)
            ensure_network || return 1
            case "$1" in
                install-nfqws2) install_nfqws2 ;;
                install-nf-web) install_nf_web ;;
                install-nf-web2) install_nf_web2 ;;
                install-dpi-detector) install_dpi_detector ;;
            esac
            return $? ;;
        install-blobs-nfqws2)
            install_all_nfqw2_blobs
            return $? ;;
        strategies)
            ensure_network || return 1
            strategy_menu
            return $? ;;
        dpi-detector) launch_dpi; return $? ;;
        rkn-list) install_rkn_list; return $? ;;
        install-tg-ws-proxy-rust) install_tg_ws_proxy_rust; return $? ;;
        install-keenkit) install_keenkit; return $? ;;
        install-awg-manager) install_awg_manager; return $? ;;
        backup) backup_configs; return $? ;;
        *) : ;;
    esac
    # При первом запуске запускаем только запрошенную первичную установку.
    if [ ! -f "$ROOT_DIR/first-run-complete" ] && [ ! -f "$ROOT_DIR/first-run-attempted" ]; then
        say "${PURPLE}Первый запуск Xmenu v$APP_VERSION${RESET}"
        say "${YELLOW}Установка сторонних компонентов и автонастройка XKeen могут изменить маршрутизацию и оборвать SSH-сессию. Убедись, что есть альтернативный доступ к роутеру.${RESET}"
        if confirm 'Выполнить первичную установку отсутствующих компонентов сейчас?'; then
            install_all_missing
        else
            : > "$ROOT_DIR/first-run-attempted"
            say "${MUTED}Первичная установка отложена. Запускай компоненты вручную из меню.${RESET}"
        fi
    fi
    while :; do
        render_menu
        INTERRUPTED=0
        MENU_READING=1
        _menu_lang=$(get_ui_lang)
        if [ "$_menu_lang" = en ]; then _prompt='[?] Select an option [Enter = exit]: '; else _prompt='[?] Выберите пункт [Enter = выход]: '; fi
        _read_or_eof "${LAVENDER}$_prompt${RESET}"
        _read_rc=$?
        MENU_READING=0
        if [ "$_read_rc" -ne 0 ]; then
            if [ "${INTERRUPTED:-0}" = 1 ]; then
                INTERRUPTED=0
                say "${YELLOW}Ввод отменён; меню остаётся открытым. Нажми Ctrl+C ещё раз в течение 2 секунд для выхода.${RESET}"
                continue
            fi
            cleanup
            return 0
        fi
        _choice=$_read_value
        if [ -z "$_choice" ]; then
            cleanup
            return 0
        fi
        case "$_choice" in
            *[!0-9]*) say "${RED}Нужно ввести номер пункта цифрами.${RESET}"; continue ;;
        esac
        case "$_choice" in
            1) ensure_network && install_xkeen_stable_binary; pause ;;
            2) ensure_network && install_xkeen_ui; pause ;;
            3) ensure_network && install_xkeen_ui_umarcheh001; pause ;;
            4) ensure_network && install_nfqws2; pause ;;
            5) ensure_network && install_nf_web; pause ;;
            6) ensure_network && install_nf_web2; pause ;;
            7) install_xkeen_core_profile mihomo; pause ;;
            8) install_xkeen_core_profile xray; pause ;;
            9) install_manual_bundle_profile mihomo; pause ;;
            10) install_manual_bundle_profile xray; pause ;;
            11) ensure_network && strategy_menu; pause ;;
            12) sync_active_blobs; pause ;;
            13) install_all_nfqw2_blobs; pause ;;
            14) run_nfmenu_action update_rkn_list; pause ;;
            15) launch_dpi; pause ;;
            16) run_nfmenu_action menu_tg_ws_proxy_rs; pause ;;
            17) run_nfmenu_action menu_keenkit; pause ;;
            18) run_nfmenu_action menu_awg_manager; pause ;;
            19) show_status; pause ;;
            20) change_ui_language; pause ;;
            21) remove_components_menu ;;
            22) remove_menu; _remove_rc=$?; [ "${XMENU_REMOVED:-0}" = 1 ] && { cleanup; return 0; } ;;
            0) cleanup; return 0 ;;
            *) say "${RED}Неверный пункт.${RESET}"; sleep 1 ;;
        esac
    done
}
main "$@"
