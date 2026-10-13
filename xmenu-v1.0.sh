#!/bin/sh
# Xmenu ◆ v1.4.0 — Entware / BusyBox ash; based on the v2.4.19 codebase
APP_VERSION="1.4.0"
# XKEEN_MENU_AUTO_YES=1/true/yes/on отключает подтверждение только для NFQWS2 UI в install-all.
# Сторонние установщики пока не имеют независимой криптографической проверки; закрепление ревизий запланировано для v2.5.0.
ROOT_DIR="/opt/etc/xmenu"
BACKUP_DIR="$ROOT_DIR/backups"
CACHE_DIR="/opt/etc/nfqws-menu/strategies"
LANG_FILE="$ROOT_DIR/language"
NF_REPO="https://raw.githubusercontent.com/rndnaame/nfqws-menu/main"
XMENU_UPDATE_URL="https://raw.githubusercontent.com/rangerxxyy/Xmenu/main/xmenu-v1.0.sh"
XKEEN_INSTALLER="https://raw.githubusercontent.com/jameszeroX/XKeen/main/install.sh"
XKEEN_UI_INSTALLER="https://raw.githubusercontent.com/zxc-rv/XKeen-UI/main/setup.sh"
DPI_RUST_INSTALLER_URL="https://raw.githubusercontent.com/Runnin4ik/dpi-detector/rust/install.sh"
DPI_RUST_INSTALLER_MIRROR="https://cdn.jsdelivr.net/gh/Runnin4ik/dpi-detector@rust/install.sh"
NFQWS2_REPO_BASE="https://nfqws.github.io/nfqws2-keenetic"
NFQWS_WEB_REPO="https://nfqws.github.io/nfqws-keenetic-web/all"

PATH="/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

WORK=""
LOCK_DIR="/opt/var/lock/xmenu-operation.lock"
LOCK_HELD=0
INTERRUPTED=0
MENU_READING=0
_LAST_MENU_INTERRUPT_TS=0
_FETCH_FAIL_COUNT=0
XMENU_UPDATE_REDRAW=0
XMENU_UPDATE_NOTICE_VISIBLE=0
XMENU_UPDATE_CHECK_PID=''
XMENU_UPDATE_CHECK_PENDING=0
XMENU_MANUAL_UPDATE_CHECK=0
XMENU_UPDATE_CACHE="$ROOT_DIR/xmenu-update.cache"
XMENU_UPDATE_LOCK="$ROOT_DIR/.xmenu-update-check.lock"
XMENU_OPKG_MIRRORS_FILE="$ROOT_DIR/entware-mirrors.conf"
XMENU_COMPONENT_CACHE="$ROOT_DIR/components-status.cache"
XMENU_COMPONENT_CACHE_TIME="$ROOT_DIR/components-status.cache.time"
XMENU_COMPONENT_REFRESH_LOCK="$ROOT_DIR/.xmenu-component-refresh.lock"
XMENU_COMPONENT_REFRESH_PENDING=0
trap '[ "${XMENU_MANUAL_UPDATE_CHECK:-0}" = 1 ] || XMENU_UPDATE_REDRAW=1' USR1
stop_component_status_refresh() {
    [ -d "$XMENU_COMPONENT_REFRESH_LOCK" ] || return 0
    [ "$(cat "$XMENU_COMPONENT_REFRESH_LOCK/menu_pid" 2>/dev/null || :)" = "$$" ] || return 0
    _scsr_worker=$(cat "$XMENU_COMPONENT_REFRESH_LOCK/check_pid" 2>/dev/null || :)
    case "$_scsr_worker" in
        ''|*[!0-9]*|0) : ;;
        *)
            _scsr_start=$(cat "$XMENU_COMPONENT_REFRESH_LOCK/check_start" 2>/dev/null || :)
            if [ "$_scsr_worker" != "$$" ] && xmenu_lock_pid_is_owner "$_scsr_worker" "$_scsr_start"; then
                kill "$_scsr_worker" 2>/dev/null || :
                wait "$_scsr_worker" 2>/dev/null || :
            fi ;;
    esac
    rm -rf "$XMENU_COMPONENT_REFRESH_LOCK" 2>/dev/null || :
    return 0
}

# Параметр final передаётся из EXIT trap; старые версии ShellCheck его не учитывают.
# shellcheck disable=SC2120
cleanup() {
    _cleanup_mode=${1:-release}
    if [ -n "${_OPKG_RENDER_CACHE_FILE:-}" ]; then
        case "$_OPKG_RENDER_CACHE_FILE" in "$ROOT_DIR"/.opkg-installed.*) rm -f "$_OPKG_RENDER_CACHE_FILE" ;; esac
        _OPKG_RENDER_CACHE_FILE=''
    fi
    if [ -n "$WORK" ] && [ "$WORK" != / ] && [ -d "$WORK" ]; then
        case "$WORK" in "$ROOT_DIR"/*|/tmp/xmenu-*) rm -rf "$WORK" ;; esac
    fi
    WORK=""
    # Some operations call cleanup() only to release the lock. Keep session caches
    # in that case; at process exit remove this PID's /tmp files and Xmenu work artifacts.
    if [ "$_cleanup_mode" = final ]; then
        if [ -n "${XMENU_UPDATE_CHECK_PID:-}" ] && [ -d "$XMENU_UPDATE_LOCK" ] &&
           [ "$(cat "$XMENU_UPDATE_LOCK/menu_pid" 2>/dev/null || :)" = "$$" ] &&
           [ "$(cat "$XMENU_UPDATE_LOCK/check_pid" 2>/dev/null || :)" = "$XMENU_UPDATE_CHECK_PID" ]; then
            kill "$XMENU_UPDATE_CHECK_PID" 2>/dev/null || :
            rm -rf "$XMENU_UPDATE_LOCK" 2>/dev/null || :
        fi
        stop_component_status_refresh
        rm -f "$ROOT_DIR/.xmenu-update-cache.$$" /tmp/xmenu-version-"$$" 2>/dev/null || :
        for _cleanup_path in /tmp/xmenu-*-"$$" /tmp/xmenu-*-"$$".* "$ROOT_DIR"/*."$$" "$ROOT_DIR"/*."$$".* "$ROOT_DIR"/.*."$$" "$ROOT_DIR"/.*."$$".* "$ROOT_DIR"/*-"$$" "$ROOT_DIR"/*-"$$".*; do
            [ -e "$_cleanup_path" ] || [ -L "$_cleanup_path" ] || continue
            case "$_cleanup_path" in /tmp/xmenu-*|"$ROOT_DIR"/*) rm -rf "$_cleanup_path" 2>/dev/null || : ;; esac
        done
    fi
    release_operation_lock
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
# POSIX exit trap guarantees final temporary-file cleanup for both menu and CLI modes.
trap 'cleanup final' 0

if [ -t 1 ]; then
    RESET=$(printf '\033[0m'); PURPLE=$(printf '\033[35m'); LAVENDER=$(printf '\033[95m'); WHITE=$(printf '\033[97m')
    MUTED=$(printf '\033[90m'); GREEN=$(printf '\033[32m'); YELLOW=$(printf '\033[33m'); RED=$(printf '\033[31m'); CYAN=$(printf '\033[36m'); BRIGHT_CYAN=$(printf '\033[1;38;5;51m'); ACTIVE=$(printf '\033[1;92m')
else
    RESET=''; PURPLE=''; LAVENDER=''; WHITE=''; MUTED=''; GREEN=''; YELLOW=''; RED=''; CYAN=''; BRIGHT_CYAN=''; ACTIVE=''
fi
say() { printf '%s\n' "$*"; }

# A character device may exist even when the process has no controlling TTY.
# Attempt to open /dev/tty before redirecting interactive installer I/O.
has_controlling_tty() {
    ( : </dev/tty ) >/dev/null 2>&1
}

read_uptime_tenths() {
    _uptime_tenths=''
    [ -r /proc/uptime ] || return 1
    _xru_raw=''
    IFS=' ' read -r _xru_raw _xru_rest < /proc/uptime 2>/dev/null || return 1
    case "${_xru_raw}" in ''|*[!0-9.]*|*.*.*) return 1 ;; esac
    case "${_xru_raw}" in
        *.*)
            _xru_whole=${_xru_raw%%.*}
            _xru_frac=${_xru_raw#*.}
            _xru_frac=${_xru_frac%"${_xru_frac#?}"}
            ;;
        *) _xru_whole=${_xru_raw}; _xru_frac=0 ;;
    esac
    case "${_xru_whole}" in ''|*[!0-9]*) return 1 ;; esac
    case "${_xru_frac}" in ''|*[!0-9]*) _xru_frac=0 ;; esac
    _uptime_tenths=$((_xru_whole * 10 + _xru_frac))
    return 0
}

# Portable response-page check: inspect only the first few lines.
# Match HTML and explicit HTTP error-page markers, not generic words like "Not Found":
# those can legitimately occur in shell comments or the first lines of domain lists.
response_looks_like_error_page() {
    [ -f "$1" ] || return 1
    sed -n '1,8p' "$1" 2>/dev/null | grep -qiE '<html([[:space:]>])|<!doctype[[:space:]]+html|^[[:space:]]*404:[[:space:]]*not found[[:space:]]*$|^[[:space:]]*404 not found[[:space:]]*$|^[[:space:]]*502 bad gateway[[:space:]]*$|^[[:space:]]*503 service unavailable[[:space:]]*$'
}

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
    if [ "$_ri_size" -lt "$_ri_min" ] || response_looks_like_error_page "$_ri_tmp"; then
        rm -f "$_ri_tmp"
        say "${RED}Загруженный файл слишком мал или похож на страницу ошибки; запуск отменён.${RESET}"
        return 1
    fi
    if ! sh -n "$_ri_tmp"; then
        rm -f "$_ri_tmp"
        say "${RED}Синтаксис установщика $_ri_name некорректен для sh; выполнение отменено.${RESET}"
        return 1
    fi
    if has_controlling_tty; then
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
    if has_controlling_tty && command -v stty >/dev/null 2>&1; then
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
    _line_width=${_XMENU_RENDER_WIDTH:-}
    [ -n "$_line_width" ] || _line_width=$(terminal_width)
    _line_text=$(printf '%*s' "$_line_width" '' | tr ' ' '=')
    say "${PURPLE}$_line_text${RESET}"
}
menu_item() {
    _mi_number=$1
    shift
    _mi_text=$*
    _mi_term_width=${_XMENU_RENDER_WIDTH:-}
    [ -n "$_mi_term_width" ] || _mi_term_width=$(terminal_width)
    _mi_text_width=$((_mi_term_width - 11))
    [ "$_mi_text_width" -ge 20 ] 2>/dev/null || _mi_text_width=20
    # Keep the number's first digit in a fixed column, and keep labels aligned
    # after the dot for both one- and two-digit choices (including the U hotkey).
    _mi_first_prefix="      ${_mi_number}."
    _mi_prefix_spaces=$((11 - ${#_mi_first_prefix}))
    if [ "$_mi_prefix_spaces" -gt 0 ] 2>/dev/null; then
        _mi_first_prefix="${_mi_first_prefix}$(printf '%*s' "$_mi_prefix_spaces" '')"
    else
        _mi_first_prefix="${_mi_first_prefix} "
    fi
    # Fast path: most menu labels fit on one line. Avoid starting awk for those.
    _mi_text_length=${#_mi_text}
    if [ "$_mi_text_length" -le "$_mi_text_width" ] 2>/dev/null; then
        printf '%s%s\n' "$_mi_first_prefix" "$_mi_text"
        return 0
    fi
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
    if [ "${INTERRUPTED:-0}" = 1 ]; then
        INTERRUPTED=0
        return 0
    fi
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
    if [ -t 0 ] && has_controlling_tty; then
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

# During menu rendering, one opkg snapshot avoids spawning `opkg` repeatedly for every row.
# Outside rendering the original live lookup is retained so install/remove actions see fresh state.
_OPKG_RENDER_CACHE_FILE=''
is_installed() {
    _ip_pkg=$1
    if [ -n "${_OPKG_RENDER_CACHE_FILE:-}" ] && [ -r "$_OPKG_RENDER_CACHE_FILE" ]; then
        awk -v p="$_ip_pkg" '$1==p && $2=="-" {f=1} END{exit(f?0:1)}' "$_OPKG_RENDER_CACHE_FILE"
    else
        opkg list-installed 2>/dev/null | awk -v p="$_ip_pkg" '$1==p{f=1} END{exit(f?0:1)}'
    fi
}
pkg_version() {
    _pv_pkg=$1
    if [ -n "${_OPKG_RENDER_CACHE_FILE:-}" ] && [ -r "$_OPKG_RENDER_CACHE_FILE" ]; then
        awk -v p="$_pv_pkg" '$1==p {if ($2=="-") print $3; else if ($2!="") print $2; exit}' "$_OPKG_RENDER_CACHE_FILE"
    else
        opkg status "$_pv_pkg" 2>/dev/null | sed -n 's/^Version:[[:space:]]*//p' | head -n 1
    fi
}

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
                if xmenu_wget_bounded 8 "$_wget_path" -q --spider -T 8 "$_probe_url" >/dev/null 2>&1; then
                    _TRANSPORT_TLS_CACHED=yes
                    return 0
                fi
            else
                if xmenu_wget_bounded 8 "$_wget_path" -q -T 8 -O /dev/null --header='Range: bytes=0-1023' "$_probe_url" >/dev/null 2>&1; then
                    _TRANSPORT_TLS_CACHED=yes
                    return 0
                fi
                # Совместимый запасной вариант для wget без поддержки Range.
                if xmenu_wget_bounded 8 "$_wget_path" -q -T 8 -O /dev/null "$_probe_url" >/dev/null 2>&1; then
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
migrate_legacy_xmenu_data() {
    _mld_old='/opt/etc/xkeen-menu'
    # Не возвращаем удалённые бэкапы при последующих запусках меню.
    [ -f "$ROOT_DIR/.legacy-data-migrated" ] && return 0
    [ -d "$_mld_old" ] || return 0
    mkdir -p "$ROOT_DIR" || return 1
    _mld_list="/tmp/xmenu-migrate-$$"
    find "$_mld_old" -type f -print > "$_mld_list" 2>/dev/null || { rm -f "$_mld_list"; return 1; }
    _mld_failed=0
    while IFS= read -r _mld_file || [ -n "$_mld_file" ]; do
        [ -n "$_mld_file" ] || continue
        _mld_relative=${_mld_file#"$_mld_old"/}
        case "$_mld_relative" in .xmenu-update-check.lock/*|.xmenu-component-refresh.lock/*) continue ;; esac
        _mld_target="$ROOT_DIR/$_mld_relative"
        if [ -e "$_mld_target" ] || [ -L "$_mld_target" ]; then continue; fi
        mkdir -p "${_mld_target%/*}" || { _mld_failed=1; continue; }
        cp -p "$_mld_file" "$_mld_target" 2>/dev/null || _mld_failed=1
    done < "$_mld_list"
    rm -f "$_mld_list"
    [ "$_mld_failed" = 0 ] || return 1
    : > "$ROOT_DIR/.legacy-data-migrated"
}
ensure_dirs() {
    mkdir -p "$ROOT_DIR" "$BACKUP_DIR" /opt/tmp /opt/share/xmenu /opt/var/log || {
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
            # Explicit revision URLs contain refs/heads/<branch>/ or refs/tags/<tag>/.
            # Consume all three leading path segments before separating the file path.
            case "$_candidate_rest" in
                refs/heads/*)
                    _candidate_rest=${_candidate_rest#refs/heads/}
                    _candidate_ref=${_candidate_rest%%/*}
                    _candidate_path=${_candidate_rest#*/}
                    ;;
                refs/tags/*)
                    _candidate_rest=${_candidate_rest#refs/tags/}
                    _candidate_ref=${_candidate_rest%%/*}
                    _candidate_path=${_candidate_rest#*/}
                    ;;
                *)
                    _candidate_ref=${_candidate_rest%%/*}
                    _candidate_path=${_candidate_rest#*/}
                    ;;
            esac
            printf '%s\n' "$_candidate_url"
            if [ -n "$_candidate_owner" ] && [ -n "$_candidate_repo" ] && [ -n "$_candidate_ref" ] && [ -n "$_candidate_path" ]; then
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
            if [ -n "$_wget_path" ] && [ -x "$_wget_path" ] && xmenu_wget_bounded "$_fetch_timeout" "$_wget_path" -q -T "$_fetch_timeout" -O "$_fetch_out" "$_fetch_candidate"; then
                [ -s "$_fetch_out" ] && _fetch_ok=1
            fi
        fi
        if [ "$_fetch_ok" -eq 1 ] && ! response_looks_like_error_page "$_fetch_out"; then
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
        armv7*|armhf*) echo armv7 ;;
        armv6*|arm*) echo '' ;;
        mipsel*|mips64el*) echo mipsel ;;
        mips*) echo mips ;;
        x86_64*|amd64*|x64*) echo x86_64 ;;
        i[3-6]86*|x86*|i686*) echo x86 ;;
        *) echo '' ;;
    esac
}
_arch_pick_best() {
    awk '$1=="arch" && $2!="" && $2!="all" && $2!="noarch" {p=$3+0; n=$2; bonus=0; if(n~/^mipsel/ || n~/^mipselsf/ || n~/^mips64el/ || n~/^aarch64/ || n~/^arm64/ || n~/^armv7/ || n~/^armhf/)bonus=2; score=p*10+bonus; if(score>best){best=score; name=n}} END{if(name!="")print name}'
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
                    *armv7*|*armhf*) echo armv7; return 0 ;;
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
    # This is a local API call. Keep the UI responsive if the API is disabled;
    # do not spend another timeout trying the same endpoint with a second client.
    if command -v curl >/dev/null 2>&1; then
        _rci=$(curl -fLsS --connect-timeout 1 --max-time 2 http://127.0.0.1:79/rci/show/version 2>/dev/null) || _rci=''
    elif command -v wget >/dev/null 2>&1; then
        _rci=$(wget -qO- -T 2 http://127.0.0.1:79/rci/show/version 2>/dev/null) || _rci=''
    fi
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
    _backup_dir=${2:-$BACKUP_DIR}
    mkdir -p "$_backup_dir" || return 1
    _ts=$(date '+%Y%m%d-%H%M%S' 2>/dev/null); [ -n "$_ts" ] || _ts="backup-$$"
    _dest_base="$_backup_dir/$(basename "$_f").$_ts.$$"
    _dest="$_dest_base.bak"
    _backup_seq=1
    # Do not overwrite an earlier backup created during the same second.
    while [ -e "$_dest" ] || [ -L "$_dest" ]; do
        _dest="$_dest_base.$_backup_seq.bak"
        _backup_seq=$((_backup_seq + 1))
    done
    cp -p "$_f" "$_dest" || { say "${RED}Не удалось создать бэкап $_f${RESET}"; return 1; }
    # Выбор последнего бэкапа использует mtime: это время создания копии,
    # а не давняя дата исходного файла, которую переносит cp -p.
    touch -m "$_dest" || { say "${RED}Не удалось записать время создания бэкапа $_dest${RESET}"; return 1; }
    say "${MUTED}Бэкап: $_dest${RESET}"
}
backup_configs() {
    mkdir -p "$BACKUP_DIR" || return 1
    _ts=$(date '+%Y%m%d-%H%M%S' 2>/dev/null); [ -n "$_ts" ] || _ts="backup-$$"
    set --
    for _p in /opt/etc/nfqws/nfqws.conf /opt/etc/nfqws2/nfqws2.conf /opt/etc/nfqws2/blobs/*.bin /opt/etc/nfqws2/*.bin /opt/etc/nfqws/*.bin /opt/etc/xkeen; do
        [ -e "$_p" ] && [ ! -L "$_p" ] && set -- "$@" "${_p#/}"
    done
    [ "$#" -gt 0 ] || { say 'Конфигурации для бэкапа не найдены.'; return 0; }
    _archive_base="$BACKUP_DIR/configs-$_ts.$$"
    if command -v gzip >/dev/null 2>&1; then
        _archive_ext='.tar.gz'
    else
        _archive_ext='.tar'
    fi
    _archive="$_archive_base$_archive_ext"
    _archive_seq=1
    # Preserve previous archives when backups are made more than once per second.
    while [ -e "$_archive" ] || [ -L "$_archive" ]; do
        _archive="$_archive_base.$_archive_seq$_archive_ext"
        _archive_seq=$((_archive_seq + 1))
    done
    if [ "$_archive_ext" = '.tar.gz' ]; then
        tar -czf "$_archive" -C / "$@"
    else
        say "${YELLOW}gzip не найден; создаю несжатый tar-архив.${RESET}"
        tar -cf "$_archive" -C / "$@"
    fi
    _tar_rc=$?
    if [ "$_tar_rc" -ne 0 ] || [ ! -s "$_archive" ]; then
        rm -f "$_archive"
        say "${RED}Не удалось создать архив конфигураций (tar=$_tar_rc).${RESET}"
        return 1
    fi
    say "${GREEN}Бэкап: $_archive${RESET}"
}

# Обновляют только NFQWS-пакет без повторного запуска интерактивных
# миграций/проверок установки. Используется в install_all_missing(), когда
# пакет уже установлен; opkg update всегда выполняется перед opkg upgrade.
upgrade_nfqws2_package() {
    require_opkg || return 1
    _up_arch=$(get_arch) || { say "${RED}Не удалось определить архитектуру Entware.${RESET}"; return 1; }
    case "$_up_arch" in aarch64|armv7|mipsel|mips|x86_64|x86) ;; *) say "${RED}Не удалось надёжно определить архитектуру Entware.${RESET}"; return 1;; esac

    # Определяем действие до сетевого запроса и сообщаем пользователю, что будет обновляться.
    if is_installed nfqws2-keenetic; then
        _up_action=upgrade
        say 'nfqws2 уже установлен. Обновляю индексы репозиториев, затем выполню opkg upgrade nfqws2-keenetic.'
    else
        _up_action=install
        say "${YELLOW}nfqws2 не найден в списке установленных пакетов. После обновления индексов выполню opkg install.${RESET}"
    fi

    opkg install ca-certificates wget-ssl >/dev/null 2>&1 || :
    mkdir -p /opt/etc/opkg || return 1
    printf 'src/gz nfqws2-keenetic %s/%s\n' "$NFQWS2_REPO_BASE" "$_up_arch" > /opt/etc/opkg/nfqws2-keenetic.conf || return 1
    say 'Обновляю индексы OPKG...'
    opkg update || { say "${RED}opkg update не завершился. Пакет пока не обновлялся; повтори попытку после исправления доступа к репозиторию.${RESET}"; return 1; }

    # Перепроверяем локальную базу перед действием, чтобы не пытаться обновить исчезнувший пакет.
    if is_installed nfqws2-keenetic; then
        say 'Выполняю: opkg upgrade nfqws2-keenetic'
        opkg upgrade nfqws2-keenetic
    else
        say 'Выполняю: opkg install nfqws2-keenetic'
        opkg install nfqws2-keenetic
    fi
}
upgrade_nf_web_package() {
    require_opkg || return 1
    if is_installed nfqws-keenetic-web; then
        say 'nfqws-keenetic-web уже установлен. Обновляю индексы репозиториев, затем выполню opkg upgrade nfqws-keenetic-web.'
    else
        say "${YELLOW}nfqws-keenetic-web не найден в списке установленных пакетов. После обновления индексов выполню opkg install.${RESET}"
    fi

    opkg install ca-certificates wget-ssl >/dev/null 2>&1 || :
    mkdir -p /opt/etc/opkg || return 1
    printf 'src/gz nfqws-keenetic-web %s\n' "$NFQWS_WEB_REPO" > /opt/etc/opkg/nfqws-keenetic-web.conf || return 1
    say 'Обновляю индексы OPKG...'
    opkg update || { say "${RED}opkg update не завершился. Пакет пока не обновлялся; проверь доступ к репозиторию.${RESET}"; return 1; }

    if is_installed nfqws-keenetic-web; then
        say 'Выполняю: opkg upgrade nfqws-keenetic-web'
        opkg upgrade nfqws-keenetic-web
    else
        say 'Выполняю: opkg install nfqws-keenetic-web'
        opkg install nfqws-keenetic-web
    fi
}
install_nfqws2() {
    line; say "${CYAN}nfqws2${RESET} — движок обхода DPI"
    # Это прямая OPKG-операция: ensure_network() мог запускать предварительный opkg update
    # и делать второй сетевой проход до проверки/обновления целевого пакета.
    require_opkg || return 1
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
    mkdir -p /opt/etc/opkg || return 1
    printf 'src/gz nfqws2-keenetic %s/%s\n' "$NFQWS2_REPO_BASE" "$_arch" > /opt/etc/opkg/nfqws2-keenetic.conf || return 1
    if is_installed nfqws2-keenetic; then
        say 'nfqws2 уже установлен. Обновляю индексы, затем выполню opkg upgrade nfqws2-keenetic.'
    else
        say 'nfqws2 не установлен. Обновляю индексы, затем выполню opkg install nfqws2-keenetic.'
    fi
    say 'Обновляю индексы OPKG...'
    opkg update || { say "${RED}opkg update не завершился. До opkg upgrade/install выполнение не дошло.${RESET}"; return 1; }
    if is_installed nfqws2-keenetic; then
        say 'Выполняю: opkg upgrade nfqws2-keenetic'
        opkg upgrade nfqws2-keenetic
    else
        say 'Выполняю: opkg install nfqws2-keenetic'
        opkg install nfqws2-keenetic
    fi
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
    # Для установки/обновления OPKG-пакета не нужен HTTPS-preflight Xmenu;
    # он мог запускать отдельный opkg update до проверки целевого репозитория.
    require_opkg || return 1
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
    mkdir -p /opt/etc/opkg || return 1
    printf 'src/gz nfqws-keenetic-web %s\n' "$NFQWS_WEB_REPO" > /opt/etc/opkg/nfqws-keenetic-web.conf || return 1
    if is_installed nfqws-keenetic-web; then
        say 'nfqws-keenetic-web уже установлен. Обновляю индексы, затем выполню opkg upgrade nfqws-keenetic-web.'
    else
        say 'nfqws-keenetic-web не установлен. Обновляю индексы, затем выполню opkg install nfqws-keenetic-web.'
    fi
    say 'Обновляю индексы OPKG...'
    opkg update || { say "${RED}opkg update не завершился. До opkg upgrade/install выполнение не дошло.${RESET}"; return 1; }
    if is_installed nfqws-keenetic-web; then
        say 'Выполняю: opkg upgrade nfqws-keenetic-web'
        opkg upgrade nfqws-keenetic-web
    else
        say 'Выполняю: opkg install nfqws-keenetic-web'
        opkg install nfqws-keenetic-web
    fi
}
install_nf_web2() {
    line; say "${CYAN}nfqws-ui (nfqws2-ui)${RESET}"
    require_opkg || return 1
    if ! is_installed nfqws2-keenetic; then
        say 'Сначала установи nfqws2 (пункт 4).'
        return 1
    fi

    # Official upstream command: nfqws-ui update (nfqws-ui-setup is its full name).
    # Check package AND utility, since older installations may have no short alias.
    if is_installed nfqws2-ui || is_installed nfqws-ui || \
       command -v nfqws-ui >/dev/null 2>&1 || \
       [ -x /opt/sbin/nfqws-ui-setup ] || [ -x /opt/usr/sbin/nfqws-ui-setup ]; then
        say 'Обнаружен nfqws-ui. Запускаю официальное обновление...'
        if command -v nfqws-ui >/dev/null 2>&1; then
            if has_controlling_tty; then nfqws-ui update </dev/tty; else nfqws-ui update; fi
        elif command -v nfqws-ui-setup >/dev/null 2>&1; then
            if has_controlling_tty; then nfqws-ui-setup update </dev/tty; else nfqws-ui-setup update; fi
        elif [ -x /opt/sbin/nfqws-ui-setup ]; then
            if has_controlling_tty; then /opt/sbin/nfqws-ui-setup update </dev/tty; else /opt/sbin/nfqws-ui-setup update; fi
        elif [ -x /opt/usr/sbin/nfqws-ui-setup ]; then
            if has_controlling_tty; then /opt/usr/sbin/nfqws-ui-setup update </dev/tty; else /opt/usr/sbin/nfqws-ui-setup update; fi
        else
            say 'Пакет обнаружен, но команда обновления отсутствует. Восстанови штатную утилиту пакета.'
            return 1
        fi
        _nfui_rc=$?
        [ "$_nfui_rc" -eq 0 ] || say "${RED}Обновление nfqws-ui завершилось с кодом $_nfui_rc.${RESET}"
        return "$_nfui_rc"
    fi

    # Official upstream install.sh, downloaded to a file rather than piped into
    # an interactive shell. No modification of the vendor's installer.
    _nfui_tmp="/tmp/xmenu-nfqws-ui-install-$$.sh"
    _nfui_url='https://github.com/zemidala/nfqws2-ui/releases/latest/download/install.sh'
    rm -f "$_nfui_tmp"
    say 'nfqws-ui не установлен. Загружаю официальный установщик...'
    if ! fetch "$_nfui_url" "$_nfui_tmp" 120; then
        rm -f "$_nfui_tmp"
        say 'Не удалось скачать официальный установщик nfqws-ui с основного адреса и зеркал.'
        return 1
    fi
    if [ ! -s "$_nfui_tmp" ] || response_looks_like_error_page "$_nfui_tmp" || ! sh -n "$_nfui_tmp"; then
        rm -f "$_nfui_tmp"
        say 'Официальный установщик пуст или содержит синтаксическую ошибку.'
        return 1
    fi
    say 'Запускаю официальный install.sh...'
    if has_controlling_tty; then sh "$_nfui_tmp" </dev/tty; else sh "$_nfui_tmp"; fi
    _nfui_rc=$?
    rm -f "$_nfui_tmp"
    [ "$_nfui_rc" -eq 0 ] || say "${RED}Установка nfqws-ui завершилась с кодом $_nfui_rc.${RESET}"
    return "$_nfui_rc"
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
    # Normalize CRLF before inspecting or rewriting the downloaded shell script.
    _src_norm="${_src}.normalized"
    tr -d '\r' < "$_src" > "$_src_norm" && mv -f "$_src_norm" "$_src" || {
        rm -f "$_src" "$_src_norm"; say "${RED}Не удалось нормализовать официальный установщик XKeen.${RESET}"; return 1;
    }
    grep -q 'url_stable=' "$_src" && grep -Eq '^[[:space:]]*exec[[:space:]]+/opt/sbin/xkeen[[:space:]]+-i[[:space:]]*$' "$_src" && sh -n "$_src" || {
        rm -f "$_src"; say "${RED}Структура официального установщика изменилась; запуск отменён.${RESET}"; return 1;
    }
    # Keep the official Stable downloader/archive validation, but skip its interactive first -i.
    sed 's#^[[:space:]]*exec[[:space:]][[:space:]]*/opt/sbin/xkeen[[:space:]][[:space:]]*-i[[:space:]]*$#exit 0#' "$_src" > "$_auto" || { rm -f "$_src" "$_auto"; return 1; }
    if grep -Eq '^[[:space:]]*exec[[:space:]]+/opt/sbin/xkeen[[:space:]]+-i[[:space:]]*$' "$_auto" || \
       ! grep -q '^exit 0$' "$_auto" || ! sh -n "$_auto"; then
        rm -f "$_src" "$_auto"; say "${RED}Не удалось подготовить неинтерактивный запуск Stable-инсталлятора.${RESET}"; return 1;
    fi
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
    # Replace only the entry managed by Xmenu. Preserve unrelated crontab lines.
    grep -Fv 'XMENU_GEOIPSET_DAILY_0430' "$_GIP_CRON_CURRENT" > "$_GIP_CRON_NEXT" || :
    if grep -Fv 'XMENU_GEOIPSET_DAILY_0430' "$_GIP_CRON_CURRENT" | grep -Fq '/opt/sbin/xkeen -ug'; then
        say "${YELLOW}Найдена другая задача xkeen -ug без метки Xmenu; она сохранена. Проверь crontab на дублирующее расписание GeoIP/GeoIPSet.${RESET}"
    fi
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
    /opt/sbin/xkeen -i auto cores=none geo=on geoipset=on cron=off autostart=on
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
    /opt/sbin/xkeen -i auto cores=none geo=on geoipset=on cron=off autostart=on
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
    if has_controlling_tty; then sh "$_tmp" </dev/tty; else sh "$_tmp"; fi
    _rc=$?; rm -f "$_tmp"; return "$_rc"
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
    if has_controlling_tty; then
        (cd /opt/xkeen-ui && sh ./install.sh) </dev/tty >/dev/tty 2>&1
        _uirc=$?
    else
        (cd /opt/xkeen-ui && sh ./install.sh)
        _uirc=$?
    fi
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

    # Для этих двух opkg-пакетов повторный запуск install-all обновляет уже
    # установленную версию (opkg update + opkg upgrade), а не просто пропускает её.
    if is_installed nfqws2-keenetic; then
        _install_all_step 'Обновление nfqws2' upgrade_nfqws2_package; _rc=$?
    else
        _install_all_step 'Установка nfqws2' install_nfqws2; _rc=$?
    fi
    case "$_rc" in 0) : ;; 130) return 130 ;; *) _failed=1 ;; esac

    if is_installed nfqws-keenetic-web; then
        _install_all_step 'Обновление nfqws-keenetic-web' upgrade_nf_web_package; _rc=$?
    else
        _install_all_step 'Установка nfqws-keenetic-web' install_nf_web; _rc=$?
    fi
    case "$_rc" in 0) : ;; 130) return 130 ;; *) _failed=1 ;; esac
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
    if [ -x /opt/bin/dpi-detector ]; then
        say 'DPI Detector уже установлен — пропуск.'
    else
        _all_arch=$(get_arch 2>/dev/null || :)
        if [ "$_all_arch" != aarch64 ]; then
            say "${YELLOW}DPI Detector доступен только для aarch64 — пропуск (обнаружено: ${_all_arch:-архитектура не определена}).${RESET}"
        else
            _install_all_step 'DPI Detector' install_dpi_detector; _rc=$?
            case "$_rc" in 0) : ;; 130) return 130 ;; *) _failed=1 ;; esac
        fi
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

# Сначала полностью записываем и проверяем файл рядом с действующим конфигом.
# Только rename меняет живой конфиг: ошибка записи не обрежет рабочий файл.
replace_shell_config() (
    _rsc_source=$1
    _rsc_target=$2
    [ -f "$_rsc_source" ] && [ ! -L "$_rsc_source" ] || return 1
    [ ! -L "$_rsc_target" ] || return 1
    if [ -e "$_rsc_target" ] && [ ! -f "$_rsc_target" ]; then return 1; fi
    _rsc_tmp=$(mktemp "${_rsc_target}.xmenu.XXXXXX") || return 1
    trap 'rm -f "$_rsc_tmp"' 0
    trap 'exit 130' INT TERM HUP
    if [ -f "$_rsc_target" ]; then cp -p "$_rsc_target" "$_rsc_tmp" || return 1; fi
    cat "$_rsc_source" > "$_rsc_tmp" || return 1
    sh -n "$_rsc_tmp" || return 1
    [ "${INTERRUPTED:-0}" = 0 ] || return 130
    mv -f "$_rsc_tmp" "$_rsc_target"
)

# Копируем присваивание интерфейса буквально, без вставки значения в sed.
# Сохраняются кавычки, комментарии и список интерфейсов из текущего конфига.
prepare_strategy_config() {
    _psc_old=$1
    _psc_new=$2
    _psc_tmp="$_psc_new.norm"
    awk '
        FILENAME == ARGV[1] {
            if (!have_interface && /^[[:space:]]*ISP_INTERFACE[[:space:]]*=/) {
                interface=$0; sub(/\r$/, "", interface); have_interface=1
            }
            next
        }
        {
            sub(/\r$/, "")
            if (have_interface && /^[[:space:]]*ISP_INTERFACE[[:space:]]*=/) {
                print interface; replaced=1
            } else print
        }
        END {if (have_interface && !replaced) print interface}
    ' "$_psc_old" "$_psc_new" > "$_psc_tmp" &&
        sh -n "$_psc_tmp" && mv -f "$_psc_tmp" "$_psc_new" || {
            rm -f "$_psc_tmp"
            say "${RED}Не удалось подготовить корректный конфиг стратегии; действующий файл сохранён.${RESET}"
            return 1
        }
}
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
    # A path may be written as --option="/path/file.bin" or --option='/path/file.bin'.
    # Strip only quote characters from tokenized arguments before extracting paths.
    grep -vE '^[[:space:]]*#' "$1" 2>/dev/null | sed "s/[\"']//g" | tr ' \t' '\n' |
        sed -n -e 's/.*@\(\/[^[:space:]]*\.bin\).*/\1/p' \
               -e 's/.*=\(\/[^[:space:]]*\.bin\).*/\1/p' | sort -u
}
extract_list_paths() {
    grep -vE '^[[:space:]]*#' "$1" 2>/dev/null | sed "s/[\"']//g" | tr ' \t' '\n' |
        sed -n -e 's/.*[=:]\(\/[^[:space:]]*\.list\).*/\1/p' \
               -e 's/^\(\/[^[:space:]]*\.list\)$/\1/p' | sort -u
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
            cp "$_ub_work/blobs-SHA256SUMS" "$ROOT_DIR/manifests/blobs-SHA256SUMS.tmp.$$" &&
                mv "$ROOT_DIR/manifests/blobs-SHA256SUMS.tmp.$$" "$ROOT_DIR/manifests/blobs-SHA256SUMS" || {
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
        [ "${INTERRUPTED:-0}" = 0 ] || { rm -rf "$_ub_work"; say 'Загрузка blobs прервана пользователем.'; return 130; }
        [ -n "$_ub_path" ] || continue
        _ub_name=${_ub_path##*/}
        case "$_ub_name" in ''|*[!A-Za-z0-9_.+-]*|*..*|.) say "${YELLOW}Пропуск небезопасного имени blob: $_ub_name${RESET}"; _ub_failed=1; continue ;; esac
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
                backup_file "$_ub_path" "$BACKUP_DIR/blobs" || {
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
    [ "${INTERRUPTED:-0}" = 0 ] || { rm -rf "$_ub_work"; say 'Загрузка blobs прервана пользователем.'; return 130; }
    rm -rf "$_ub_work"
    [ "$_ub_failed" -eq 0 ]
}

# Удаляет только битую ссылку на необязательный rkn.list.
# rkn.list устанавливается отдельным действием; он не должен становиться
# обязательной зависимостью кастомной стратегии, если самого файла нет.
drop_missing_rkn_reference() {
    _dmr_conf=$1
    _dmr_ver=$2
    case "$_dmr_ver" in
        2) _dmr_list='/opt/etc/nfqws2/lists/rkn.list'
           ;;
        1) _dmr_list='/opt/etc/nfqws/rkn.list'
           ;;
        *) return 0 ;;
    esac
    [ -s "$_dmr_list" ] && return 0
    _dmr_host="--hostlist=$_dmr_list"
    grep -Fq -- "$_dmr_host" "$_dmr_conf" 2>/dev/null || return 0

    # Never modify a config through a symlink.
    if [ -L "$_dmr_conf" ]; then
        say "${YELLOW}rkn.list отсутствует, а конфиг является симлинком; ссылку на необязательный список не меняю автоматически.${RESET}"
        return 0
    fi

    _dmr_tmp="${_dmr_conf}.rkn-clean.$$"
    _dmr_out="${_dmr_tmp}.out"
    rm -f "$_dmr_tmp" "$_dmr_out"
    cp -p "$_dmr_conf" "$_dmr_tmp" || { rm -f "$_dmr_tmp"; return 1; }
    awk -v host="$_dmr_host" '
        function boundary(c) {return c=="" || c ~ /[[:space:]"\047]/}
        /^[[:space:]]*#/ {print; next}
        {
            rest=$0; result=""
            while ((pos=index(rest,host)) > 0) {
                result=result substr(rest,1,pos-1)
                rest=substr(rest,pos+length(host))
                if (!boundary(substr(result,length(result),1)) || !boundary(substr(rest,1,1))) result=result host
            }
            print result rest
        }
    ' "$_dmr_tmp" > "$_dmr_out" || {
        rm -f "$_dmr_tmp" "$_dmr_out"
        return 1
    }
    cat "$_dmr_out" > "$_dmr_tmp" || {
        rm -f "$_dmr_tmp" "$_dmr_out"
        return 1
    }
    rm -f "$_dmr_out"
    if command -v cmp >/dev/null 2>&1 && cmp -s "$_dmr_conf" "$_dmr_tmp"; then
        rm -f "$_dmr_tmp"
        return 0
    fi

    # Back up only the live NFQWS config; temporary strategy files are staged
    # copies and will be installed by their caller after all checks succeed.
    case "$_dmr_conf" in
        /opt/etc/nfqws2/nfqws2.conf|/opt/etc/nfqws/nfqws.conf)
            backup_file "$_dmr_conf" || { rm -f "$_dmr_tmp"; return 1; }
            ;;
    esac
    if ! replace_shell_config "$_dmr_tmp" "$_dmr_conf"; then
        rm -f "$_dmr_tmp"
        return 1
    fi
    rm -f "$_dmr_tmp"
    RKN_REFERENCE_REMOVED=1
    say "${YELLOW}rkn.list не найден: удалена только ссылка на него из конфига. Стратегия продолжит работу без этого необязательного списка; остальные параметры сохранены.${RESET}"
    return 0
}

# Проверяет списки .list, на которые ссылается конфигурация, и скачивает отсутствующие.
# Источник и логика соответствуют nfqws-menu: strategies/lists/<имя>.
update_lists_for() {
    _ul_conf=$1
    _ul_ver=$2
    LISTS_CHANGED=0
    RKN_REFERENCE_REMOVED=0
    [ -f "$_ul_conf" ] || { say "Конфиг списков не найден: $_ul_conf"; return 1; }
    drop_missing_rkn_reference "$_ul_conf" "$_ul_ver" || {
        say "${RED}Не удалось безопасно обработать отсутствующий rkn.list; конфиг списков не изменён.${RESET}"
        return 1
    }
    [ "${RKN_REFERENCE_REMOVED:-0}" = 1 ] && LISTS_CHANGED=1
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
        [ "${INTERRUPTED:-0}" = 0 ] || { rm -rf "$_ul_work"; say 'Загрузка списков прервана пользователем.'; return 130; }
        [ -n "$_ul_ref" ] || continue
        case "$_ul_ref" in */../*|*/..|*/./*|*'//'*)
            say "${RED}Недопустимый путь списка: $_ul_ref${RESET}"
            _ul_fail=$((_ul_fail + 1))
            continue ;;
        esac
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
                if [ -f "$_ul_ref" ]; then continue; fi
                say "${RED}Отсутствующий список указан вне каталога $_ul_base: $_ul_ref${RESET}"
                _ul_fail=$((_ul_fail + 1))
                continue
                ;;
            *) _ul_path="$_ul_base/$_ul_name" ;;
        esac

        # Пустые user/exclude/auto-списки допустимы: скачиваем только отсутствующие.
        if [ -f "$_ul_path" ]; then
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
    [ "${INTERRUPTED:-0}" = 0 ] || { rm -rf "$_ul_work"; say 'Загрузка списков прервана пользователем.'; return 130; }
    rm -rf "$_ul_work"
    [ "$_ul_fail" -eq 0 ]
}

# Загружает полный официальный список blobs NFQWS2 в /opt/etc/nfqws2/blobs.
install_all_nfqw2_blobs() {
    acquire_lock || return 1
    install_all_nfqw2_blobs_locked
    _ianb_rc=$?
    release_operation_lock
    return "$_ianb_rc"
}

install_all_nfqw2_blobs_locked() {
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
    cp "$_blob_work/SHA256SUMS" "$ROOT_DIR/manifests/blobs-SHA256SUMS.tmp.$$" || { rm -rf "$_blob_work"; return 1; }
    mv "$ROOT_DIR/manifests/blobs-SHA256SUMS.tmp.$$" "$ROOT_DIR/manifests/blobs-SHA256SUMS" || { rm -rf "$_blob_work"; return 1; }
    _blob_i=0
    _blob_ok=0
    _blob_fail=0
    while IFS= read -r _blob_line || [ -n "$_blob_line" ]; do
        [ "${INTERRUPTED:-0}" = 0 ] || { rm -rf "$_blob_work"; say 'Установка blobs прервана пользователем.'; return 130; }
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
    [ "${INTERRUPTED:-0}" = 0 ] || { rm -rf "$_blob_work"; say 'Установка blobs прервана пользователем.'; return 130; }
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
    strategy_menu_session
    _sms_rc=$?
    rm -f "$ROOT_DIR/strategies-list.$$" "$ROOT_DIR/strategies-priority.$$" "$ROOT_DIR/strategies-other.$$" "$ROOT_DIR/strategies-display.$$"
    return "$_sms_rc"
}

strategy_menu_session() {
    sync_strategies || { _rc=$?; [ "$_rc" -eq 130 ] && return 130; return 1; }
    _active=$(active_conf) || { say 'nfqws/nfqws2 конфиг не найден; сначала установи движок.'; return 1; }
    _conf=${_active%%|*}; _default=${_active#*|}
    case "$_conf" in */nfqws2.conf) _ver=2; _dir="$CACHE_DIR/nfqws2";; *) _ver=1; _dir="$CACHE_DIR/nfqws1";; esac
    _list="$ROOT_DIR/strategies-list.$$"
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
        grep -Fxq -- "$_priority_name" "$_list" 2>/dev/null || printf '%s\n' "$_priority_name" >> "$_list"
    done < "$_priority"
    : > "$_others"
    for _f in "$_dir"/*.conf; do
        [ -f "$_f" ] || continue
        _candidate=${_f##*/}
        grep -Fxq -- "$_candidate" "$_list" 2>/dev/null || printf '%s\n' "$_candidate" >> "$_others"
    done
    if [ -s "$_others" ]; then
        LC_ALL=C sort "$_others" >> "$_list"
    fi
    rm -f "$_priority" "$_others"
    [ -s "$_list" ] || { rm -f "$_list" "$_display"; say 'Кэш стратегий пуст.'; return 1; }

    # Отмечаем выбранную стратегию по маркеру, затем по совпадению конфига.
    _current_strategy=$(sed -n '1{s/\r$//;p;}' "$ROOT_DIR/active-strategy-nfqws$_ver" 2>/dev/null)
    case "$_current_strategy" in ''|*/*|*..*|*[!A-Za-z0-9_.+-]*) _current_strategy='' ;; esac
    if [ -z "$_current_strategy" ] || [ ! -f "$_dir/$_current_strategy" ] ||
       ! strategy_configs_equal "$_conf" "$_dir/$_current_strategy"; then
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
    line; say "${BRIGHT_CYAN}ВЫБОР СТРАТЕГИИ — nfqws$_ver:${RESET}"; line
    awk -F '\t' -v active="$_current_strategy" -v cyan="$BRIGHT_CYAN" -v reset="$RESET" '{
        if ($1 == active) printf "      %2d. %-28s %s— Активная стратегия ⚡%s\n", NR, $1, cyan, reset
        else printf "      %2d. %-28s %s\n", NR, $1, $2
    }' "$_display"
    menu_item 0 'Назад'
    line; _read_or_eof 'Номер стратегии: ' || { rm -f "$_display"; return 0; }; _n=$_read_value
    rm -f "$_display"
    case "$_n" in ''|0) return 0;; *[!0-9]*) say 'Неверный номер.'; return 1;; esac
    _name=$(awk -v n="$_n" 'NR==n {print; exit}' "$_list")
    case "$_name" in
        ''|.|*/*|*..*|*'?'*|*'#'*|*'%'*|*'['*|*']'*|*'\\'*)
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
    say "Выбрана стратегия: $_name"
    say 'Будет создан бэкап; сначала проверю/доустановлю нужные blobs, затем заменю конфиг и перезапущу NFQWS.'
    if confirm 'Применить стратегию?'; then
        [ ! -L "$_conf" ] || { rm -f "$_tmp" "$_tmp.norm"; say 'Активный конфиг является симлинком; замена отменена.'; return 1; }
        acquire_lock || { rm -f "$_tmp" "$_tmp.norm"; return 1; }
        prepare_strategy_config "$_conf" "$_tmp" && preserve_rkn_hostlist "$_conf" "$_tmp" "$_ver" || {
            cleanup; rm -f "$_tmp" "$_tmp.norm"; return 1;
        }
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
        replace_shell_config "$_tmp" "$_conf" || { cleanup; rm -f "$_tmp" "$_tmp.norm"; say 'Не удалось применить конфиг.'; return 1; }
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
    awk -v host="$_ml_host" '
        /^[[:space:]]*MODE_LIST[[:space:]]*=/ {
            line=$0; sub(/^[^=]*=[[:space:]]*/, "", line)
            sub(/[[:space:]]+#.*/, "", line); gsub(/["\047]/, "", line)
            n=split(line, tokens, /[[:space:]]+/)
            for (i=1; i<=n; i++) if (tokens[i]==host) found=1
        }
        END {exit(found?0:1)}
    ' "$_ml_conf" 2>/dev/null
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
    # Preserve an existing opt-in only when the optional file is still present.
    # A stale MODE_LIST argument must not make the replacement strategy unstartable.
    [ -s "$_pr_list" ] || return 0
    mode_list_has_host "$_pr_old" "--hostlist=$_pr_list" || return 0
    mode_list_has_host "$_pr_new" "--hostlist=$_pr_list" && return 0
    _pr_tmp="$_pr_new.rkn.$$"
    awk -v host="--hostlist=$_pr_list" '
        /^[[:space:]]*MODE_LIST[[:space:]]*=/ {
            if (index($0, host) > 0) { print; found=1; next }
            # Only append when MODE_LIST is a one-line double-quoted value.
            # Unknown formats are left intact instead of risking a bad config edit.
            if ($0 ~ /"[[:space:]]*$/) {
                sub(/"[[:space:]]*$/, " " host "\"")
                print; found=1; next
            }
        }
        { print }
        END { if (!found) exit 3 }
    ' "$_pr_new" > "$_pr_tmp" || {
        rm -f "$_pr_tmp"
        say "${YELLOW}Не удалось безопасно изменить MODE_LIST; привязка rkn.list не менялась, применение стратегии продолжится.${RESET}"
        return 0
    }
    if ! mv "$_pr_tmp" "$_pr_new"; then
        rm -f "$_pr_tmp"
        say "${RED}Не удалось сохранить привязку rkn.list; применение стратегии отменено.${RESET}"
        return 1
    fi
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
    prepare_strategy_config "$_conf" "$_tmpconf" && preserve_rkn_hostlist "$_conf" "$_tmpconf" "$_ver" || {
        rm -f "$_tmpconf" "$_tmpconf.norm"; return 1;
    }
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
    replace_shell_config "$_tmpconf" "$_conf" || { rm -f "$_tmpconf"; return 1; }
    rm -f "$_tmpconf"
    STRATEGY_CHANGED=1
    say "${GREEN}Активная стратегия $_name обновлена из проверенного кэша; ISP_INTERFACE сохранён.${RESET}"
}
sync_active_blobs() {
    acquire_lock || return 1
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
            _pre_name=$(tr -d '\r' < "$_pre_marker" 2>/dev/null | sed -n '1p')
            case "$_pre_name" in ''|.|..|*/*|*..*|*[!A-Za-z0-9_.+-]*) _pre_name='' ;; esac
            if [ -n "$_pre_name" ] && [ -f "$CACHE_DIR/nfqws$_pre_ver/$_pre_name" ] &&
               strategy_configs_equal "$_pre_conf" "$CACHE_DIR/nfqws$_pre_ver/$_pre_name"; then
                SYNC_ALLOW_STRATEGY_UPDATE=1
            fi
        fi
    fi
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
xmenu_process_start() {
    [ -r "/proc/$1/stat" ] || return 1
    # После имени процесса в скобках starttime находится в поле 20.
    sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'
}

# PID может быть повторно использован после завершения процесса. Если в lock
# записано время старта, сверяем его с /proc, чтобы не принять чужую сессию
# за прежнего владельца блокировки.
xmenu_lock_pid_is_owner() {
    _xlpio_pid=$1
    _xlpio_expected_start=${2:-}
    case "$_xlpio_pid" in ''|*[!0-9]*|0) return 1 ;; esac
    kill -0 "$_xlpio_pid" 2>/dev/null || return 1
    [ -n "$_xlpio_expected_start" ] || return 0
    _xlpio_actual_start=$(xmenu_process_start "$_xlpio_pid" 2>/dev/null || :)
    # Если /proc недоступен, лучше сохранить блокировку, чем прервать живую сессию.
    [ -z "$_xlpio_actual_start" ] || [ "$_xlpio_actual_start" = "$_xlpio_expected_start" ]
}

release_operation_lock() {
    if [ "$LOCK_HELD" = 1 ] && [ -d "$LOCK_DIR" ] &&
       [ "$(cat "$LOCK_DIR/pid" 2>/dev/null || :)" = "$$" ]; then
        rm -f "$LOCK_DIR/pid" "$LOCK_DIR/start" 2>/dev/null || :
        rmdir "$LOCK_DIR" 2>/dev/null || :
    fi
    LOCK_HELD=0
}

operation_lock_publish() {
    if ! printf '%s\n' "$$" > "$LOCK_DIR/pid"; then
        rmdir "$LOCK_DIR" 2>/dev/null || :
        return 1
    fi
    _olp_start=$(xmenu_process_start "$$" 2>/dev/null || :)
    [ -z "$_olp_start" ] || printf '%s\n' "$_olp_start" > "$LOCK_DIR/start"
    LOCK_HELD=1
    return 0
}

acquire_lock() {
    mkdir -p "$(dirname "$LOCK_DIR")" || return 1
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        operation_lock_publish
        return $?
    fi
    # Удаляем устаревшую блокировку только после завершения указанного процесса.
    _lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || :)
    _lock_stale=0
    case "$_lock_pid" in
        ''|*[!0-9]*)
            # Учитываем паузу между mkdir и записью PID параллельной сессией.
            sleep 1
            _lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || :)
            case "$_lock_pid" in ''|*[!0-9]*) _lock_stale=1 ;; esac
            ;;
    esac
    case "$_lock_pid" in
        ''|*[!0-9]*) : ;;
        *)
            _lock_recorded_start=$(cat "$LOCK_DIR/start" 2>/dev/null || :)
            _lock_actual_start=$(xmenu_process_start "$_lock_pid" 2>/dev/null || :)
            if ! kill -0 "$_lock_pid" 2>/dev/null; then _lock_stale=1
            elif [ -n "$_lock_recorded_start" ] && [ -n "$_lock_actual_start" ] &&
                 [ "$_lock_recorded_start" != "$_lock_actual_start" ]; then _lock_stale=1; fi
            ;;
    esac
    if [ "$_lock_stale" = 1 ]; then
        rm -f "$LOCK_DIR/pid" "$LOCK_DIR/start" 2>/dev/null || :
        rmdir "$LOCK_DIR" 2>/dev/null || :
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            operation_lock_publish
            return $?
        fi
    fi
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
        _v=$(pkg_version xkeen)
    fi
    printf '%s' "${_v:-неизвестна}"
}

get_xkeen_ui_zxc_version() {
    xkeen_ui_zxc_is_installed || { printf '%s' 'не установлен'; return 0; }
    _v=$(pkg_version xkeen-ui)
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
    _xray_cache="/tmp/xmenu-xray-version-$$"
    if [ -s "$_xray_cache" ]; then cat "$_xray_cache"; return 0; fi
    _bin=$(command -v xray 2>/dev/null)
    [ -n "$_bin" ] && [ -x "$_bin" ] || _bin=''
    [ -n "$_bin" ] || { [ -x /opt/bin/xray ] && _bin=/opt/bin/xray; }
    [ -n "$_bin" ] || { [ -x /opt/sbin/xray ] && _bin=/opt/sbin/xray; }
    [ -n "$_bin" ] || { [ -x /opt/sbin/.xkeen/xray ] && _bin=/opt/sbin/.xkeen/xray; }
    [ -n "$_bin" ] || { [ -x /opt/sbin/.xkeen/bin/xray ] && _bin=/opt/sbin/.xkeen/bin/xray; }
    if [ -z "$_bin" ] && [ -d /opt/sbin/.xkeen ]; then
        _xray_candidates=$(find /opt/sbin/.xkeen -type f -name xray 2>/dev/null)
        for _candidate in $_xray_candidates; do [ -x "$_candidate" ] && { _bin=$_candidate; break; }; done
    fi
    [ -n "$_bin" ] || {
        printf '%s\n' 'не найден' > "$_xray_cache" 2>/dev/null || :
        printf '%s' 'не найден'
        return 0
    }
    _v=$("$_bin" version 2>&1 | sed -n '1p')
    _v=${_v:-версия не сообщена}
    printf '%s\n' "$_v" > "$_xray_cache" 2>/dev/null || :
    printf '%s' "$_v"
}

get_mihomo_version() {
    _mihomo_cache="/tmp/xmenu-mihomo-version-$$"
    if [ -s "$_mihomo_cache" ]; then cat "$_mihomo_cache"; return 0; fi
    _bin=$(command -v mihomo 2>/dev/null)
    [ -n "$_bin" ] && [ -x "$_bin" ] || _bin=''
    [ -n "$_bin" ] || { [ -x /opt/bin/mihomo ] && _bin=/opt/bin/mihomo; }
    [ -n "$_bin" ] || { [ -x /opt/sbin/mihomo ] && _bin=/opt/sbin/mihomo; }
    [ -n "$_bin" ] || { [ -x /opt/sbin/.xkeen/mihomo ] && _bin=/opt/sbin/.xkeen/mihomo; }
    [ -n "$_bin" ] || { [ -x /opt/sbin/.xkeen/bin/mihomo ] && _bin=/opt/sbin/.xkeen/bin/mihomo; }
    if [ -z "$_bin" ] && [ -d /opt/sbin/.xkeen ]; then
        _mihomo_candidates=$(find /opt/sbin/.xkeen -type f -name mihomo 2>/dev/null)
        for _candidate in $_mihomo_candidates; do [ -x "$_candidate" ] && { _bin=$_candidate; break; }; done
    fi
    [ -n "$_bin" ] || {
        printf '%s\n' 'не найден' > "$_mihomo_cache" 2>/dev/null || :
        printf '%s' 'не найден'
        return 0
    }
    _v=$("$_bin" -v 2>&1 | sed -n '1p')
    _v=${_v:-версия не сообщена}
    printf '%s\n' "$_v" > "$_mihomo_cache" 2>/dev/null || :
    printf '%s' "$_v"
}

# Called after install/update/remove actions which can change a core binary.
invalidate_core_version_cache() {
    rm -f "/tmp/xmenu-xray-version-$$" "/tmp/xmenu-mihomo-version-$$" "/tmp/xmenu-dpi-version-$$"
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

# Cache only the rendered component rows, not action results. The short TTL keeps
# re-entry into the menu fast; component-changing actions explicitly invalidate it.
component_status_cache_fresh() {
    [ -f "$XMENU_COMPONENT_CACHE" ] && [ -r "$XMENU_COMPONENT_CACHE_TIME" ] || return 1
    _csc_checked=$(sed -n '1p' "$XMENU_COMPONENT_CACHE_TIME" 2>/dev/null)
    case "$_csc_checked" in ''|*[!0-9]*) return 1 ;; esac
    _csc_now=$(date +%s 2>/dev/null || printf '0')
    case "$_csc_now" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_csc_now" -ge "$_csc_checked" ] 2>/dev/null || return 1
    [ $((_csc_now - _csc_checked)) -lt 60 ] 2>/dev/null
}

invalidate_component_status_cache() {
    rm -f "$XMENU_COMPONENT_CACHE" "$XMENU_COMPONENT_CACHE_TIME"
}

render_component_status_table() {
    _rcst_file=$1
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
    done < "$_rcst_file"
    if [ ! -s "$_rcst_file" ]; then
        if [ "$(get_ui_lang)" = en ]; then
            say "  ${YELLOW}No managed components installed yet.${RESET}"
        else
            say "  ${YELLOW}Управляемые компоненты пока не установлены.${RESET}"
        fi
    fi
}

render_component_statuses_sync() {
    if [ "${XMENU_FORCE_COMPONENT_REFRESH:-0}" != 1 ] && component_status_cache_fresh; then
        _COMPONENT_INSTALLED_FILE="$XMENU_COMPONENT_CACHE"
        _XMENU_COMPONENT_CACHE_HIT=1
        _OPKG_RENDER_CACHE_FILE=''
    else
        _COMPONENT_INSTALLED_FILE="$ROOT_DIR/.components-installed.$$"
        _XMENU_COMPONENT_CACHE_HIT=0
        _OPKG_RENDER_CACHE_FILE="$ROOT_DIR/.opkg-installed.$$"
        : > "$_COMPONENT_INSTALLED_FILE" || return 1
    if ! opkg list-installed > "$_OPKG_RENDER_CACHE_FILE" 2>/dev/null; then
        rm -f "$_OPKG_RENDER_CACHE_FILE"
        _OPKG_RENDER_CACHE_FILE=''
    fi

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
        _dpi_cache="/tmp/xmenu-dpi-version-$$"
        if [ -s "$_dpi_cache" ]; then
            _dpi_v=$(cat "$_dpi_cache" 2>/dev/null)
        else
            _dpi_probe=$(sh -c 'exec /opt/bin/dpi-detector --version' 2>/dev/null)
            _dpi_probe_rc=$?
            _dpi_v=$(printf '%s\n' "$_dpi_probe" | sed -n '1p')
            if [ "$_dpi_probe_rc" -eq 0 ] && [ -n "$_dpi_v" ]; then
                printf '%s\n' "$_dpi_v" > "$ROOT_DIR/dpi-detector-version" 2>/dev/null || :
                rm -f "$ROOT_DIR/dpi-detector-native-incompatible" "$ROOT_DIR/dpi-detector-python-mode"
            elif [ "$_dpi_probe_rc" -eq 126 ] || [ "$_dpi_probe_rc" -eq 127 ] ||
                 [ -f "$ROOT_DIR/dpi-detector-native-incompatible" ]; then
                _dpi_v='ELF несовместим с Entware'
            else
                _dpi_v=$(sed -n '1p' "$ROOT_DIR/dpi-detector-version" 2>/dev/null)
            fi
            [ -z "$_dpi_v" ] || printf '%s\n' "$_dpi_v" > "$_dpi_cache" 2>/dev/null || :
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

        # Publish the cache atomically. An empty row file is valid when nothing is installed.
        _component_cache_tmp="$ROOT_DIR/.components-status.$$.tmp"
        _component_cache_time_tmp="$ROOT_DIR/.components-status-time.$$.tmp"
        if cp "$_COMPONENT_INSTALLED_FILE" "$_component_cache_tmp" 2>/dev/null &&
           mv -f "$_component_cache_tmp" "$XMENU_COMPONENT_CACHE" 2>/dev/null; then
            _component_cache_now=$(date +%s 2>/dev/null || printf '0')
            case "$_component_cache_now" in ''|*[!0-9]*) _component_cache_now=0 ;; esac
            if printf '%s\n' "$_component_cache_now" > "$_component_cache_time_tmp" 2>/dev/null &&
               mv -f "$_component_cache_time_tmp" "$XMENU_COMPONENT_CACHE_TIME" 2>/dev/null; then
                :
            else
                rm -f "$XMENU_COMPONENT_CACHE_TIME" "$_component_cache_time_tmp"
            fi
        else
            rm -f "$_component_cache_tmp" "$_component_cache_time_tmp"
        fi
    fi

    render_component_status_table "$_COMPONENT_INSTALLED_FILE"
    if [ "${_XMENU_COMPONENT_CACHE_HIT:-0}" != 1 ]; then rm -f "$_COMPONENT_INSTALLED_FILE"; fi
    [ -z "${_OPKG_RENDER_CACHE_FILE:-}" ] || rm -f "$_OPKG_RENDER_CACHE_FILE"
    _OPKG_RENDER_CACHE_FILE=''
}

# Return success when another live process is already refreshing the component cache.
component_refresh_is_running() {
    [ -d "$XMENU_COMPONENT_REFRESH_LOCK" ] || return 1
    _crir_worker=$(cat "$XMENU_COMPONENT_REFRESH_LOCK/check_pid" 2>/dev/null || :)
    _crir_worker_start=$(cat "$XMENU_COMPONENT_REFRESH_LOCK/check_start" 2>/dev/null || :)
    _crir_owner=$(cat "$XMENU_COMPONENT_REFRESH_LOCK/menu_pid" 2>/dev/null || :)
    _crir_owner_start=$(cat "$XMENU_COMPONENT_REFRESH_LOCK/menu_start" 2>/dev/null || :)
    # Между mkdir и публикацией PID другая SSH-сессия видит пустую директорию.
    if [ -z "$_crir_worker" ] && [ -z "$_crir_owner" ]; then
        sleep 1
        [ -d "$XMENU_COMPONENT_REFRESH_LOCK" ] || return 1
        _crir_worker=$(cat "$XMENU_COMPONENT_REFRESH_LOCK/check_pid" 2>/dev/null || :)
        _crir_worker_start=$(cat "$XMENU_COMPONENT_REFRESH_LOCK/check_start" 2>/dev/null || :)
        _crir_owner=$(cat "$XMENU_COMPONENT_REFRESH_LOCK/menu_pid" 2>/dev/null || :)
        _crir_owner_start=$(cat "$XMENU_COMPONENT_REFRESH_LOCK/menu_start" 2>/dev/null || :)
    fi
    case "$_crir_worker" in
        ''|*[!0-9]*)
            xmenu_lock_pid_is_owner "$_crir_owner" "$_crir_owner_start" && return 0
            ;;
        *)
            xmenu_lock_pid_is_owner "$_crir_worker" "$_crir_worker_start" && return 0
            ;;
    esac
    rm -rf "$XMENU_COMPONENT_REFRESH_LOCK" 2>/dev/null || :
    return 1
}

start_component_status_refresh() {
    mkdir -p "$ROOT_DIR" 2>/dev/null || return 1
    # Ждём готовый общий кеш также в сессии, которая не запускала worker.
    XMENU_COMPONENT_REFRESH_PENDING=1
    component_refresh_is_running && return 0
    if ! mkdir "$XMENU_COMPONENT_REFRESH_LOCK" 2>/dev/null; then
        component_refresh_is_running && return 0
        mkdir "$XMENU_COMPONENT_REFRESH_LOCK" 2>/dev/null || return 1
    fi
    printf '%s\n' "$$" > "$XMENU_COMPONENT_REFRESH_LOCK/menu_pid" 2>/dev/null || {
        rm -rf "$XMENU_COMPONENT_REFRESH_LOCK" 2>/dev/null || :
        return 1
    }
    _scr_start=$(xmenu_process_start "$$" 2>/dev/null || :)
    [ -z "$_scr_start" ] || printf '%s\n' "$_scr_start" > "$XMENU_COMPONENT_REFRESH_LOCK/menu_start" 2>/dev/null || :

    # Resolve the script currently running instead of assuming /opt/bin/xmenu.
    case "$0" in
        /*) _scr_source=$0 ;;
        */*) _scr_source="$PWD/$0" ;;
        *)
            _scr_source=$(command -v "$0" 2>/dev/null || :)
            [ -r "$_scr_source" ] || { [ -r "$0" ] && _scr_source="$PWD/$0"; }
            ;;
    esac
    [ -r "$_scr_source" ] || _scr_source=/opt/bin/xmenu
    [ -r "$_scr_source" ] || {
        rm -rf "$XMENU_COMPONENT_REFRESH_LOCK" 2>/dev/null || :
        return 1
    }

    XMENU_COMPONENT_REFRESH_PENDING=1
    # The wrapper writes its own PID before exec, so the worker cannot finish
    # and remove the lock before check_pid has been published by the parent.
    sh -c '
        printf "%s\n" "$$" > "$1/check_pid" 2>/dev/null || exit 1
        sed "s/^.*) //" "/proc/$$/stat" 2>/dev/null | awk "{print \$20}" > "$1/check_start" 2>/dev/null || :
        exec sh "$2" __refresh-component-cache "$3"
    ' xmenu-component-refresh "$XMENU_COMPONENT_REFRESH_LOCK" "$_scr_source" "$$" </dev/null >/dev/null 2>&1 &
    return 0
}

# Normal rendering never waits for slow version probes. It uses a fresh cache,
# falls back to last known rows while revalidating, and redraws when the worker ends.
render_component_statuses() {
    if [ "${XMENU_FORCE_COMPONENT_REFRESH:-0}" = 1 ]; then
        render_component_statuses_sync
        return $?
    fi

    if component_status_cache_fresh; then
        XMENU_COMPONENT_REFRESH_PENDING=0
        render_component_status_table "$XMENU_COMPONENT_CACHE"
        return $?
    fi

    if ! start_component_status_refresh; then
        XMENU_COMPONENT_REFRESH_PENDING=0
        XMENU_FORCE_COMPONENT_REFRESH=1
        render_component_statuses_sync
        _rcs_rc=$?
        unset XMENU_FORCE_COMPONENT_REFRESH
        return "$_rcs_rc"
    fi

    if [ -f "$XMENU_COMPONENT_CACHE" ]; then
        render_component_status_table "$XMENU_COMPONENT_CACHE"
    else
        if [ "$(get_ui_lang)" = en ]; then
            say "${PURPLE}Installed components:${RESET}"
            component_table_header
        else
            say "${PURPLE}Установленные компоненты:${RESET}"
            component_table_header
        fi
    fi
    return 0
}

show_status() {
    invalidate_component_status_cache
    _r=$(get_router); _model=${_r%%|*}; _fw=${_r#*|}; _arch=$(get_arch); _arch=${_arch:-не определена}
    if [ "$(get_ui_lang)" = en ]; then
        line; say "${WHITE}Xmenu v$APP_VERSION — STATUS${RESET}"; line
        say "Router: $_model | KeeneticOS: ${_fw:-not detected} | ARCH: $_arch"
    else
        line; say "${WHITE}Xmenu v$APP_VERSION — СТАТУС${RESET}"; line
        say "Роутер: $_model | KeeneticOS: ${_fw:-не определена} | ARCH: $_arch"
    fi
    say ''
    render_component_statuses_sync
    _status_strategy=$(active_strategy_label)
    if [ "$(get_ui_lang)" = en ]; then say "  Active strategy: ${CYAN}$_status_strategy${RESET}"; else say "  Активная стратегия: ${CYAN}$_status_strategy${RESET}"; fi
    ps w 2>/dev/null | grep -q '[m]ihomo' && say "${GREEN}Mihomo: запущен ⚡${RESET}" || :
    ps w 2>/dev/null | grep -q '[n]fqws2' && say "${GREEN}nfqws2: запущен ⚡${RESET}" || :
    if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -Fq 'XMENU_GEOIPSET_DAILY_0430'; then
        say '  GeoIP/GeoIPSet         ежедневно 04:30'
    else
        say '  GeoIP/GeoIPSet         расписание не настроено'
    fi
    say "  Бэкапы: $BACKUP_DIR"
}

# Загружает rkn.list и добавляет его в MODE_LIST, не меняя другие параметры конфига.
install_rkn_for() {
    acquire_lock || return 1
    install_rkn_for_locked "$1"
    _irf_rc=$?
    release_operation_lock
    return "$_irf_rc"
}

install_rkn_for_locked() {
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
        if [ "$_rkn_size" -lt 10000 ] || response_looks_like_error_page "$_rkn_tmp"; then
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
        replace_shell_config "$_rkn_tmpconf" "$_rkn_conf" || { rm -f "$_rkn_tmpconf"; return 1; }
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
        if has_controlling_tty; then sh /opt/keenkit.sh </dev/tty >/dev/tty 2>&1; else sh /opt/keenkit.sh; fi
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

nfmenu_final_main_menu_call() {
    awk '
        function is_menu_call(s, t) {
            t=s
            sub(/[[:space:]]+#.*/, "", t)
            sub(/^[[:space:]]+/, "", t)
            sub(/[[:space:]]+$/, "", t)
            sub(/;$/, "", t)
            return t=="main_menu" || t=="main_menu \"$@\"" || t=="main_menu \047$@\047" || t=="main_menu $@"
        }
        /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
        { valid=is_menu_call($0) }
        END { exit(valid ? 0 : 1) }
    ' "$1"
}

nfmenu_strip_final_main_menu_call() {
    awk '
        function is_menu_call(s, t) {
            t=s
            sub(/[[:space:]]+#.*/, "", t)
            sub(/^[[:space:]]+/, "", t)
            sub(/[[:space:]]+$/, "", t)
            sub(/;$/, "", t)
            return t=="main_menu" || t=="main_menu \"$@\"" || t=="main_menu \047$@\047" || t=="main_menu $@"
        }
        {
            rows[NR]=$0
            if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) next
            last_content=NR
            last_is_menu=is_menu_call($0)
        }
        END {
            if (!last_content || !last_is_menu) exit 1
            for (i=1; i<=NR; i++) if (i!=last_content) print rows[i]
        }
    ' "$1"
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
       ! nfmenu_final_main_menu_call "$_ufn_tmp" ||
       response_looks_like_error_page "$_ufn_tmp" || ! sh -n "$_ufn_tmp"; then
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


# Возвращает 0, если первая версия строго старее второй; 1 — если равна/новее.
# Версии Xmenu ожидаются в числовом формате вроде 1.1 или 1.0.5.
version_is_older() {
    _vo_old=$1
    _vo_current=$2
    case "$_vo_old:$_vo_current" in
        *[!0-9.:]*|:*|*:) return 2 ;;
    esac
    case "$_vo_old" in .*|*..*|*.) return 2 ;; esac
    case "$_vo_current" in .*|*..*|*.) return 2 ;; esac
    awk -v old="$_vo_old" -v current="$_vo_current" '
        BEGIN {
            n=split(old, a, ".")
            m=split(current, b, ".")
            max=(n>m?n:m)
            for (i=1; i<=max; i++) {
                x=(i<=n ? a[i]+0 : 0)
                y=(i<=m ? b[i]+0 : 0)
                if (x < y) exit 0
                if (x > y) exit 1
            }
            exit 1
        }
    '
}

# Сетевой загрузчик для обновления самого Xmenu. Не вызывает ensure_network/opkg:
# обновление меню не должно зависеть от зависшего opkg update. Для wget принудительно
# задаём одну попытку (-t 1), потому что Entware wget иначе может повторять тайм-ауты бесконечно.
xmenu_wget_bounded() {
    _xwb_limit=$1
    _xwb_wget=$2
    shift 2
    # В урезанных BusyBox-сборках -t может отсутствовать; GNU wget его требует
    # для ограничения повторных попыток. Общий timeout используется независимо.
    if "$_xwb_wget" --help 2>&1 | grep -Eq -- '--tries|(^|[[:space:]])-t([,[:space:]]|$)'; then
        set -- -t 1 "$@"
    fi
    if command -v timeout >/dev/null 2>&1; then
        timeout "$_xwb_limit" "$_xwb_wget" "$@"
        return $?
    fi
    if command -v busybox >/dev/null 2>&1 && busybox timeout "$_xwb_limit" true >/dev/null 2>&1; then
        busybox timeout "$_xwb_limit" "$_xwb_wget" "$@"
        return $?
    fi
    # Если timeout отсутствует, сохраняем сетевой тайм-аут -T и доступное
    # ограничение повторов вместо отключения загрузчика.
    "$_xwb_wget" "$@"
    return $?
}

xmenu_fetch_file() {
    _xmf_url=$1
    _xmf_out=$2
    _xmf_timeout=${3:-12}
    _xmf_range=${4:-}
    case "$_xmf_timeout" in ''|*[!0-9]*) _xmf_timeout=12 ;; esac
    _xmf_candidates=$(fetch_url_candidates "$_xmf_url") || return 1
    _xmf_curl=$(command -v curl 2>/dev/null || :)
    _xmf_wget=$(command -v wget 2>/dev/null || :)
    for _xmf_candidate in $_xmf_candidates; do
        rm -f "$_xmf_out"
        if [ -n "$_xmf_curl" ] && [ -x "$_xmf_curl" ]; then
            _xmf_rc=0
            if [ -n "$_xmf_range" ]; then
                "$_xmf_curl" -fLsS --connect-timeout 4 --max-time "$_xmf_timeout" \
                    --range "$_xmf_range" -o "$_xmf_out" "$_xmf_candidate" 2>/dev/null || _xmf_rc=$?
            else
                "$_xmf_curl" -fLsS --connect-timeout 4 --max-time "$_xmf_timeout" \
                    -o "$_xmf_out" "$_xmf_candidate" 2>/dev/null || _xmf_rc=$?
            fi
            # Непустой файл после тайм-аута может быть только обрывком ответа.
            if [ "$_xmf_rc" -eq 0 ] && [ -s "$_xmf_out" ] && ! response_looks_like_error_page "$_xmf_out"; then return 0; fi
        fi
        rm -f "$_xmf_out"
        if [ -z "$_xmf_curl" ] && [ -n "$_xmf_wget" ] && [ -x "$_xmf_wget" ]; then
            # -T controls read/connect timeout; -t 1 prevents wget retrying forever.
            if xmenu_wget_bounded "$_xmf_timeout" "$_xmf_wget" -q -T "$_xmf_timeout" -O "$_xmf_out" "$_xmf_candidate" >/dev/null 2>&1 &&
               [ -s "$_xmf_out" ] && ! response_looks_like_error_page "$_xmf_out"; then return 0; fi
        fi
        rm -f "$_xmf_out"
    done
    # wget is a fallback after all bounded curl attempts. Do not invoke it unless
    # it is installed; its retries are explicitly capped to a single attempt.
    if [ -n "$_xmf_curl" ] && [ -n "$_xmf_wget" ] && [ -x "$_xmf_wget" ]; then
        for _xmf_candidate in $_xmf_candidates; do
            rm -f "$_xmf_out"
            if xmenu_wget_bounded "$_xmf_timeout" "$_xmf_wget" -q -T "$_xmf_timeout" -O "$_xmf_out" "$_xmf_candidate" >/dev/null 2>&1 &&
               [ -s "$_xmf_out" ] && ! response_looks_like_error_page "$_xmf_out"; then return 0; fi
            rm -f "$_xmf_out"
        done
    fi
    rm -f "$_xmf_out"
    return 1
}

xmenu_extract_version() {
    [ -r "$1" ] || return 1
    sed -n 's/^[[:space:]]*APP_VERSION[[:space:]]*=[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' "$1" | sed -n '1p'
}

xmenu_valid_version() {
    case "$1" in ''|*[!0-9.]*|.*|*..*|*.) return 1 ;; esac
    return 0
}

xmenu_update_cache_is_fresh() {
    [ -r "$XMENU_UPDATE_CACHE" ] || return 1
    _xcf_checked=$(sed -n 's/^checked=//p' "$XMENU_UPDATE_CACHE" | sed -n '1p')
    case "$_xcf_checked" in ''|*[!0-9]*) return 1 ;; esac
    _xcf_now=$(date +%s 2>/dev/null || printf '0')
    case "$_xcf_now" in ''|*[!0-9]*) return 1 ;; esac
    [ $((_xcf_now - _xcf_checked)) -ge 0 ] 2>/dev/null || return 1
    _xcf_version=$(sed -n 's/^version=//p' "$XMENU_UPDATE_CACHE" | sed -n '1p')
    # A failed probe is only cached briefly. A transient GitHub/CDN outage must
    # not hide a newly published update for the full successful-cache window.
    case "$_xcf_version" in
        unknown|'') [ $((_xcf_now - _xcf_checked)) -lt 60 ] 2>/dev/null || return 1 ;;
        *) [ $((_xcf_now - _xcf_checked)) -lt 600 ] 2>/dev/null || return 1 ;;
    esac
    return 0
}

xmenu_cached_remote_version() {
    xmenu_update_cache_is_fresh || return 1
    _xcr_version=$(sed -n 's/^version=//p' "$XMENU_UPDATE_CACHE" | sed -n '1p')
    xmenu_valid_version "$_xcr_version" || return 1
    printf '%s' "$_xcr_version"
}

xmenu_remote_version_probe() {
    _xrv_tmp="/tmp/xmenu-version-$$"
    rm -f "$_xrv_tmp"
    # Usually APP_VERSION is in the first few bytes; use a bounded range so the
    # menu can display the available version without downloading the full script.
    if xmenu_fetch_file "$XMENU_UPDATE_URL" "$_xrv_tmp" 7 0-4095; then
        _xrv_version=$(xmenu_extract_version "$_xrv_tmp")
        if xmenu_valid_version "$_xrv_version" &&
           [ "$(head -n 1 "$_xrv_tmp" 2>/dev/null | tr -d '\r')" = '#!/bin/sh' ] &&
           grep -q '^APP_VERSION=' "$_xrv_tmp"; then
            rm -f "$_xrv_tmp"
            printf '%s' "$_xrv_version"
            return 0
        fi
    fi
    rm -f "$_xrv_tmp"
    return 1
}

# Stop the automatic probe before a manual check. Both paths share one cache,
# and an automatic SIGUSR1 during the manual result used to trigger an extra redraw.
xmenu_stop_update_check() {
    XMENU_MANUAL_UPDATE_CHECK=1
    XMENU_UPDATE_CHECK_PENDING=0
    if [ -n "${XMENU_UPDATE_CHECK_PID:-}" ] && [ -d "$XMENU_UPDATE_LOCK" ] &&
       [ "$(cat "$XMENU_UPDATE_LOCK/menu_pid" 2>/dev/null || :)" = "$$" ] &&
       [ "$(cat "$XMENU_UPDATE_LOCK/check_pid" 2>/dev/null || :)" = "$XMENU_UPDATE_CHECK_PID" ]; then
        kill "$XMENU_UPDATE_CHECK_PID" 2>/dev/null || :
        wait "$XMENU_UPDATE_CHECK_PID" 2>/dev/null || :
        rm -rf "$XMENU_UPDATE_LOCK" 2>/dev/null || :
    fi
    XMENU_UPDATE_REDRAW=0
}

# Force a network check even when the automatic 10-minute cache is still fresh.
check_xmenu_update_now() {
    xmenu_stop_update_check
    _cxu_cache_write_failed=0
    _cxu_lang=$(get_ui_lang)
    if [ "$_cxu_lang" = en ]; then
        say "Checking GitHub for an Xmenu update..."
    else
        say "Проверяю наличие обновления Xmenu на GitHub..."
    fi
    _cxu_version=$(xmenu_remote_version_probe) || {
        if [ "$_cxu_lang" = en ]; then
            say "${RED}Could not retrieve the remote Xmenu version. Check the connection and try again.${RESET}"
        else
            say "${RED}Не удалось получить версию Xmenu с сервера. Проверь подключение и повтори попытку.${RESET}"
        fi
        XMENU_MANUAL_UPDATE_CHECK=0
        return 1
    }

    _cxu_now=$(date +%s 2>/dev/null || printf '0')
    case "$_cxu_now" in ''|*[!0-9]*) _cxu_now=0 ;; esac
    _cxu_cache_tmp="$ROOT_DIR/xmenu-update-cache.manual.$$"
    {
        printf 'checked=%s\n' "$_cxu_now"
        printf 'version=%s\n' "$_cxu_version"
    } > "$_cxu_cache_tmp" 2>/dev/null || {
        rm -f "$_cxu_cache_tmp"
        _cxu_cache_write_failed=1
    }
    if [ "${_cxu_cache_write_failed:-0}" != 1 ] && ! mv -f "$_cxu_cache_tmp" "$XMENU_UPDATE_CACHE" 2>/dev/null; then
        rm -f "$_cxu_cache_tmp"
        _cxu_cache_write_failed=1
    fi
    if [ "${_cxu_cache_write_failed:-0}" = 1 ]; then
        if [ "$_cxu_lang" = en ]; then
            say "${YELLOW}Remote version was detected, but the cache could not be updated.${RESET}"
        else
            say "${YELLOW}Удалённая версия получена, но кэш обновить не удалось.${RESET}"
        fi
    fi

    if version_is_older "$APP_VERSION" "$_cxu_version"; then
        if [ "$_cxu_lang" = en ]; then
            say "${CYAN}↑ Update available: Xmenu v$_cxu_version (installed: v$APP_VERSION).${RESET}"
            say 'Choose option 22 — Update Xmenu to install it.'
        else
            say "${CYAN}↑ Доступно обновление Xmenu v$_cxu_version (установлена: v$APP_VERSION).${RESET}"
            say 'Для установки выбери пункт 22 — «Обновить Xmenu».'
        fi
        XMENU_MANUAL_UPDATE_CHECK=0
        return 0
    fi

    if version_is_older "$_cxu_version" "$APP_VERSION"; then
        if [ "$_cxu_lang" = en ]; then
            say "${YELLOW}The server version v$_cxu_version is older than the installed v$APP_VERSION. No downgrade will be offered.${RESET}"
        else
            say "${YELLOW}На сервере версия v$_cxu_version старее установленной v$APP_VERSION. Откат не предлагается.${RESET}"
        fi
    else
        if [ "$_cxu_lang" = en ]; then
            say "${GREEN}Xmenu v$APP_VERSION is up to date. The updater can still apply changed code with the same version.${RESET}"
        else
            say "${GREEN}Установлена актуальная версия Xmenu v$APP_VERSION. Пункт 22 также может применить изменённый код с тем же номером версии.${RESET}"
        fi
    fi
    XMENU_MANUAL_UPDATE_CHECK=0
    return 0
}

xmenu_update_check_worker() {
    _xuw_parent=$1
    _xuw_tmp="$ROOT_DIR/.xmenu-update-cache.$_xuw_parent"
    _xuw_version=$(xmenu_remote_version_probe 2>/dev/null) || _xuw_version=unknown
    {
        printf 'checked=%s\n' "$(date +%s 2>/dev/null || printf 0)"
        printf 'version=%s\n' "$_xuw_version"
    } > "$_xuw_tmp" 2>/dev/null && mv -f "$_xuw_tmp" "$XMENU_UPDATE_CACHE" 2>/dev/null || rm -f "$_xuw_tmp"
    _xuw_update_pending=0
    if xmenu_valid_version "$_xuw_version" && version_is_older "$APP_VERSION" "$_xuw_version"; then
        _xuw_update_pending=1
    fi
    if [ "$_xuw_update_pending" = 1 ]; then
        kill -USR1 "$_xuw_parent" 2>/dev/null || :
    fi
    if [ "$(cat "$XMENU_UPDATE_LOCK/menu_pid" 2>/dev/null || :)" = "$_xuw_parent" ]; then
        rm -rf "$XMENU_UPDATE_LOCK" 2>/dev/null || :
    fi
}

xmenu_start_update_check() {
    # Successful results are cached for 10 minutes; failures only for 60 seconds.
    xmenu_update_cache_is_fresh && return 0
    mkdir -p "$ROOT_DIR" 2>/dev/null || return 1
    XMENU_UPDATE_CHECK_PENDING=1
    if ! mkdir "$XMENU_UPDATE_LOCK" 2>/dev/null; then
        _xsc_stale_pid=$(cat "$XMENU_UPDATE_LOCK/menu_pid" 2>/dev/null || :)
        if [ -z "$_xsc_stale_pid" ]; then
            sleep 1
            _xsc_stale_pid=$(cat "$XMENU_UPDATE_LOCK/menu_pid" 2>/dev/null || :)
        fi
        _xsc_stale_start=$(cat "$XMENU_UPDATE_LOCK/menu_start" 2>/dev/null || :)
        case "$_xsc_stale_pid" in ''|*[!0-9]*) _xsc_stale_pid='' ;; esac
        if ! xmenu_lock_pid_is_owner "$_xsc_stale_pid" "$_xsc_stale_start"; then
            rm -rf "$XMENU_UPDATE_LOCK" 2>/dev/null || :
            mkdir "$XMENU_UPDATE_LOCK" 2>/dev/null || return 0
        else
            return 0
        fi
    fi
    printf '%s\n' "$$" > "$XMENU_UPDATE_LOCK/menu_pid" 2>/dev/null || { rm -rf "$XMENU_UPDATE_LOCK"; return 1; }
    _xsc_start=$(xmenu_process_start "$$" 2>/dev/null || :)
    [ -z "$_xsc_start" ] || printf '%s\n' "$_xsc_start" > "$XMENU_UPDATE_LOCK/menu_start" 2>/dev/null || :
    ( xmenu_update_check_worker "$$" ) </dev/null >/dev/null 2>&1 &
    XMENU_UPDATE_CHECK_PID=$!
    printf '%s\n' "$XMENU_UPDATE_CHECK_PID" > "$XMENU_UPDATE_LOCK/check_pid" 2>/dev/null || :
    return 0
}

xmenu_read_menu_prompt() {
    _xrmp_prompt=$1
    printf '%b' "${_xrmp_prompt}"
    if [ ! -t 0 ] || ! has_controlling_tty; then
        _read_or_eof ''
        return $?
    fi
    while :; do
        # SIGUSR1 получает владелец общей проверки. Остальные SSH-сессии
        # замечают готовый кеш на очередном тайм-ауте чтения.
        if [ "${XMENU_COMPONENT_REFRESH_PENDING:-0}" = 1 ] && component_status_cache_fresh; then
            XMENU_UPDATE_REDRAW=1
        fi
        if [ "${XMENU_UPDATE_CHECK_PENDING:-0}" = 1 ] && xmenu_update_cache_is_fresh; then
            XMENU_UPDATE_CHECK_PENDING=0
            XMENU_UPDATE_REDRAW=1
        fi
        if [ "${XMENU_UPDATE_REDRAW:-0}" = 1 ]; then
            XMENU_UPDATE_REDRAW=0
            if xmenu_redraw_pending_update; then printf '%b' "${_xrmp_prompt}"; fi
        fi
        read_uptime_tenths && _xrmp_before_ticks=$_uptime_tenths || _xrmp_before_ticks=''
        # BusyBox ash поддерживает -t; ниже предусмотрен обычный read для других sh.
        # shellcheck disable=SC3045
        IFS= read -r -t 1 _read_value </dev/tty
        _xrmp_rc=$?
        read_uptime_tenths && _xrmp_after_ticks=$_uptime_tenths || _xrmp_after_ticks=''
        if [ "${_xrmp_rc}" -eq 0 ]; then
            _read_value=$(printf '%s' "${_read_value}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            return 0
        fi
        if [ "${XMENU_UPDATE_REDRAW:-0}" = 1 ]; then
            XMENU_UPDATE_REDRAW=0
            if xmenu_redraw_pending_update; then printf '%b' "${_xrmp_prompt}"; fi
            # SIGUSR1 can make ash return status 1 from read; do not treat it as EOF.
            [ "${_xrmp_rc}" -eq 0 ] || continue
        fi
        if [ "${INTERRUPTED:-0}" = 1 ]; then return 1; fi
        if ! has_controlling_tty; then return 1; fi
        if [ "${_xrmp_rc}" -eq 1 ]; then
            # BusyBox ash may report both timeout and EOF as status 1. A normal
            # one-second timeout advances /proc/uptime; an immediate EOF does not.
            case "${_xrmp_before_ticks}:${_xrmp_after_ticks}" in
                *[!0-9:]*|:*|*:)
                    sleep 0.1 >/dev/null 2>&1 || sleep 1
                    ;;
                *)
                    _xrmp_elapsed=$((_xrmp_after_ticks - _xrmp_before_ticks))
                    if [ "${_xrmp_elapsed}" -lt 5 ]; then
                        [ "${XMENU_UPDATE_REDRAW:-0}" = 1 ] && continue
                        return 1
                    fi
                    ;;
            esac
        fi
        # If -t is unsupported, use the normal blocking prompt as a fallback.
        if [ "${_xrmp_rc}" -gt 1 ]; then
            _read_or_eof ''
            return $?
        fi
    done
}

xmenu_redraw_pending_update() {
    # После первичной фоновой загрузки статусов перерисовываем меню с готовыми компонентами.
    if [ "${XMENU_COMPONENT_REFRESH_PENDING:-0}" = 1 ] && component_status_cache_fresh; then
        XMENU_COMPONENT_REFRESH_PENDING=0
        render_menu
        return 0
    fi
    # Результат фоновой проверки показываем на месте под U, а не под приглашением.
    [ "${XMENU_UPDATE_NOTICE_VISIBLE:-0}" = 1 ] && return 1
    _xrpu_latest=$(xmenu_cached_remote_version 2>/dev/null || :)
    xmenu_valid_version "$_xrpu_latest" || return 1
    version_is_older "$APP_VERSION" "$_xrpu_latest" || return 1
    render_menu
    return 0
}

xmenu_show_pending_update_notice() {
    [ "${XMENU_UPDATE_NOTICE_VISIBLE:-0}" = 1 ] && return 0
    _xsp_latest=$(xmenu_cached_remote_version 2>/dev/null || :)
    xmenu_valid_version "$_xsp_latest" || return 0
    version_is_older "$APP_VERSION" "$_xsp_latest" || return 0
    if [ "$(get_ui_lang)" = en ]; then
        say "${CYAN}  ↑ Update available: Xmenu v$_xsp_latest. Choose option 22 to install it.${RESET}"
    else
        say "${CYAN}  ↑ Доступно обновление Xmenu v$_xsp_latest. Выбери пункт 22 для установки.${RESET}"
    fi
    XMENU_UPDATE_NOTICE_VISIBLE=1
}

update_xmenu_script() {
    _ux_target='/opt/bin/xmenu'
    _ux_tmp="/opt/bin/.xmenu-update.$$"
    rm -f "$_ux_tmp"
    say "Проверяю Xmenu v$APP_VERSION и ищу актуальный код на GitHub/зеркалах..."
    _ux_cache_bust=$(date '+%s' 2>/dev/null)
    case "$_ux_cache_bust" in ''|*[!0-9]*) _ux_cache_bust=0 ;; esac
    _ux_url="${XMENU_UPDATE_URL}?xmenu_refresh=${_ux_cache_bust}"
    if ! xmenu_fetch_file "$_ux_url" "$_ux_tmp" 15; then
        rm -f "$_ux_tmp"
        say "${RED}Не удалось скачать обновление Xmenu через GitHub и зеркала. Текущая версия не изменена.${RESET}"
        return 1
    fi
    _ux_size=$(wc -c < "$_ux_tmp" 2>/dev/null | tr -d ' ')
    case "$_ux_size" in ''|*[!0-9]*) _ux_size=0 ;; esac
    if [ "$_ux_size" -lt 25000 ] ||
       [ "$(head -n 1 "$_ux_tmp" 2>/dev/null | tr -d '\r')" != '#!/bin/sh' ] ||
       ! grep -q '^APP_VERSION=' "$_ux_tmp" ||
       ! grep -q '^XMENU_UPDATE_URL=' "$_ux_tmp" ||
       ! grep -q '^update_xmenu_script()' "$_ux_tmp" ||
       ! grep -q '^opkg_settings_menu()' "$_ux_tmp" ||
       ! grep -q '^render_menu()' "$_ux_tmp" ||
       ! grep -q '^main "\$@"' "$_ux_tmp" ||
       response_looks_like_error_page "$_ux_tmp" || ! sh -n "$_ux_tmp"; then
        rm -f "$_ux_tmp"
        say "${RED}Проверка обновления не пройдена. Нужен полный Xmenu с настройками OPKG; текущая версия не изменена.${RESET}"
        return 1
    fi
    _ux_remote_version=$(xmenu_extract_version "$_ux_tmp")
    xmenu_valid_version "$_ux_remote_version" || {
        rm -f "$_ux_tmp"
        say "${RED}В загруженном файле отсутствует корректная APP_VERSION. Текущий скрипт сохранён.${RESET}"
        return 1
    }
    if [ "$_ux_remote_version" = "$APP_VERSION" ]; then
        if [ -f "$_ux_target" ] && cmp -s "$_ux_tmp" "$_ux_target"; then
            rm -f "$_ux_tmp"
            say "${GREEN}Установлена актуальная Xmenu v$APP_VERSION; локальный и серверный файлы совпадают.${RESET}"
            return 0
        fi
        say "${YELLOW}Код на GitHub отличается при той же версии v$APP_VERSION. Обновляю файл...${RESET}"
    elif version_is_older "$_ux_remote_version" "$APP_VERSION"; then
        rm -f "$_ux_tmp"
        say "${YELLOW}На сервере Xmenu v$_ux_remote_version, но локально v$APP_VERSION. Откат запрещён; проверь файл $XMENU_UPDATE_URL.${RESET}"
        return 1
    else
        _ux_compare_rc=$?
        if [ "$_ux_compare_rc" -eq 2 ]; then
            rm -f "$_ux_tmp"
            say "${RED}Не удалось сравнить версии; текущая версия не изменена.${RESET}"
            return 1
        fi
    fi
    if [ -f "$_ux_target" ]; then
        backup_file "$_ux_target" || { rm -f "$_ux_tmp"; say "${RED}Не удалось сохранить резервную копию Xmenu.${RESET}"; return 1; }
    fi
    chmod 700 "$_ux_tmp" || { rm -f "$_ux_tmp"; return 1; }
    mv -f "$_ux_tmp" "$_ux_target" || { rm -f "$_ux_tmp"; return 1; }
    chmod 700 "$_ux_target" 2>/dev/null || :
    rm -f "$XMENU_UPDATE_CACHE"
    say "${GREEN}Xmenu обновлён до v$_ux_remote_version. Перезапускаю новое меню...${RESET}"
    stop_component_status_refresh
    xmenu_stop_update_check
    exec "$_ux_target"
}

# Каталог зеркал хранится отдельно от скрипта, чтобы администратор мог менять
# подписи, регионы и адреса без редактирования основной логики Xmenu.
xmenu_opkg_mirrors_ensure_config() {
    [ -s "$XMENU_OPKG_MIRRORS_FILE" ] && return 0
    mkdir -p "$ROOT_DIR" || return 1
    _omc_tmp="$XMENU_OPKG_MIRRORS_FILE.tmp.$$"
    cat > "$_omc_tmp" <<'XMENU_ENTWARE_MIRRORS_EOF'
# id|name|base URL|region
1|Entware official|http://bin.entware.net|Global
2|BFSU|https://mirrors.bfsu.edu.cn/entware|China, Beijing
3|CQUPT|https://mirrors.cqupt.edu.cn/entware|China, Chongqing
4|NJU|https://mirrors.nju.edu.cn/entware|China, Nanjing
5|Diversion|https://entware.diversion.ch|Switzerland
XMENU_ENTWARE_MIRRORS_EOF
    chmod 644 "$_omc_tmp" 2>/dev/null || :
    if [ -s "$XMENU_OPKG_MIRRORS_FILE" ]; then
        rm -f "$_omc_tmp"
        return 0
    fi
    mv -f "$_omc_tmp" "$XMENU_OPKG_MIRRORS_FILE" || { rm -f "$_omc_tmp"; return 1; }
}

xmenu_opkg_mirror_info_by_id() {
    _omi_want=$1
    xmenu_opkg_mirrors_ensure_config || return 1
    while IFS='|' read -r _omi_id _omi_name _omi_url _omi_region || [ -n "$_omi_id" ]; do
        case "$_omi_id" in ''|\#*) continue ;; *[!0-9]*) continue ;; esac
        case "$_omi_url" in http://*|https://*) : ;; *) continue ;; esac
        case "$_omi_url" in *[!A-Za-z0-9:/._-]*) continue ;; esac
        [ "$_omi_id" = "$_omi_want" ] || continue
        XMENU_MIRROR_NAME=$_omi_name
        XMENU_MIRROR_URL=${_omi_url%/}
        XMENU_MIRROR_REGION=$(printf '%s' "$_omi_region" | tr -d '\r')
        return 0
    done < "$XMENU_OPKG_MIRRORS_FILE"
    return 1
}

xmenu_opkg_mirror_info_by_url() {
    _omi_want=${1%/}
    xmenu_opkg_mirrors_ensure_config || return 1
    while IFS='|' read -r _omi_id _omi_name _omi_url _omi_region || [ -n "$_omi_id" ]; do
        case "$_omi_id" in ''|\#*) continue ;; *[!0-9]*) continue ;; esac
        case "$_omi_url" in http://*|https://*) : ;; *) continue ;; esac
        case "$_omi_url" in *[!A-Za-z0-9:/._-]*) continue ;; esac
        [ "${_omi_url%/}" = "$_omi_want" ] || continue
        XMENU_MIRROR_NAME=$_omi_name
        XMENU_MIRROR_URL=$_omi_want
        XMENU_MIRROR_REGION=$(printf '%s' "$_omi_region" | tr -d '\r')
        return 0
    done < "$XMENU_OPKG_MIRRORS_FILE"
    return 1
}

# Return the first configured Entware source, skipping unrelated third-party
# feeds so they cannot hide the active Entware architecture path.
xmenu_opkg_first_catalog_source_url() {
    _ofp_conf=/opt/etc/opkg.conf
    [ -r "$_ofp_conf" ] || return 1
    xmenu_opkg_mirrors_ensure_config || return 1
    awk -v mirrors="$XMENU_OPKG_MIRRORS_FILE" '
        BEGIN {
            while ((getline cfg < mirrors) > 0) {
                n=split(cfg, f, "|")
                if (n < 4 || f[1] !~ /^[0-9]+$/ || f[3] !~ /^https?:\/\//) continue
                sub(/\/+$/, "", f[3])
                rest=f[3]; sub(/^https?:\/\//, "", rest)
                host=rest; sub(/\/.*/, "", host)
                prefix=substr(rest, length(host)+1)
                count++; mirror_host[count]=host; mirror_prefix[count]=prefix
            }
            close(mirrors)
        }
        ($1 == "src/gz" || $1 == "src") && NF >= 3 {
            url=$3; sub(/\r$/, "", url)
            rest=url; sub(/^https?:\/\//, "", rest)
            if (rest == url) next
            host=rest; sub(/\/.*/, "", host)
            path=substr(rest, length(host)+1)
            for (i=1; i<=count; i++) {
                if (host != mirror_host[i]) continue
                prefix=mirror_prefix[i]
                if (prefix == "" || prefix == "/" || path == prefix || index(path, prefix "/") == 1) {
                    print url; exit
                }
            }
        }
    ' "$_ofp_conf"
}

# Extract the path below the selected mirror's configured prefix. All candidate
# mirrors are tested against the same package index path.
xmenu_opkg_feed_path() {
    _ofp_conf=/opt/etc/opkg.conf
    [ -r "$_ofp_conf" ] || return 1
    _ofp_url=$(xmenu_opkg_first_catalog_source_url | tr -d '\r')
    [ -n "$_ofp_url" ] || return 1
    _ofp_rest=${_ofp_url#*://}
    [ "$_ofp_rest" != "$_ofp_url" ] || return 1
    _ofp_host=${_ofp_rest%%/*}
    _ofp_path=${_ofp_rest#"$_ofp_host"}
    [ "$_ofp_path" != "$_ofp_rest" ] || _ofp_path='/'
    while IFS='|' read -r _ofp_id _ofp_name _ofp_base _ofp_region || [ -n "$_ofp_id" ]; do
        _ofp_base=${_ofp_base%/}
        case "$_ofp_id" in ''|\#*) continue ;; *[!0-9]*) continue ;; esac
        case "$_ofp_base" in http://*|https://*) : ;; *) continue ;; esac
        _ofp_base_rest=${_ofp_base#*://}
        _ofp_base_host=${_ofp_base_rest%%/*}
        _ofp_prefix=${_ofp_base_rest#"$_ofp_base_host"}
        [ "$_ofp_prefix" != "$_ofp_base_rest" ] || _ofp_prefix=''
        [ "$_ofp_host" = "$_ofp_base_host" ] || continue
        if [ -n "$_ofp_prefix" ] && [ "$_ofp_prefix" != / ]; then
            case "$_ofp_path" in
                "$_ofp_prefix"/*) _ofp_path=${_ofp_path#"$_ofp_prefix"} ;;
                "$_ofp_prefix") _ofp_path='/' ;;
                *) continue ;;
            esac
        fi
        [ -n "$_ofp_path" ] || _ofp_path='/'
        case "$_ofp_path" in /*) printf '%s' "$_ofp_path" ;; *) printf '/%s' "$_ofp_path" ;; esac
        return 0
    done < "$XMENU_OPKG_MIRRORS_FILE"
    return 1
}

# Переключает записи зеркал из каталога в /opt/etc/opkg.conf атомарно.
# Посторонние URL и дополнительные конфиги OPKG остаются нетронутыми.
xmenu_opkg_mirror_label() {
    xmenu_opkg_mirror_info_by_url "$1" && printf '%s' "$XMENU_MIRROR_NAME" || printf 'custom / unknown'
}

xmenu_opkg_set_mirror() {
    acquire_lock || return 1
    xmenu_opkg_set_mirror_locked "$1"
    _osm_apply_rc=$?
    release_operation_lock
    return "$_osm_apply_rc"
}

xmenu_opkg_set_mirror_locked() {
    _osm_base=$1
    xmenu_opkg_mirror_info_by_url "$_osm_base" || { say "${RED}Зеркало отсутствует в каталоге Entware; изменение отменено.${RESET}"; return 2; }
    _osm_conf=/opt/etc/opkg.conf
    _osm_tmp="/opt/etc/.opkg.conf.xmenu.$$"
    [ -r "$_osm_conf" ] || { say "${RED}Не найден $_osm_conf.${RESET}"; return 1; }
    rm -f "$_osm_tmp"
    awk -v base="$_osm_base" -v mirrors="$XMENU_OPKG_MIRRORS_FILE" '
        function mirror_url(url, rest, host, path, i, prefix, suffix) {
            rest=url
            sub(/^https?:\/\//, "", rest)
            host=rest
            sub(/\/.*$/, "", host)
            path=substr(rest, length(host)+1)
            for (i=1; i<=mirror_count; i++) {
                if (host != mirror_host[i]) continue
                prefix=mirror_prefix[i]
                if (prefix != "" && prefix != "/") {
                    if (path == prefix) path="/"
                    else if (index(path, prefix "/") == 1) path=substr(path, length(prefix)+1)
                    else continue
                }
                if (path == "") path="/"
                suffix=path
                return base suffix
            }
            return ""
        }
        BEGIN {
            while ((getline cfgline < mirrors) > 0) {
                n=split(cfgline, fields, "|")
                sub(/\/+$/, "", fields[3])
                if (n < 4 || fields[1] !~ /^[0-9]+$/ || fields[3] !~ /^https?:\/\/[A-Za-z0-9.-]+(:[0-9]+)?(\/[A-Za-z0-9._-]+)*$/) continue
                rest=fields[3]; sub(/^https?:\/\//, "", rest)
                host=rest; sub(/\/.*$/, "", host)
                prefix=substr(rest, length(host)+1)
                mirror_count++
                mirror_host[mirror_count]=host
                mirror_prefix[mirror_count]=prefix
            }
            close(mirrors)
        }
        {
            line=$0
            if (($1 == "src/gz" || $1 == "src") && NF >= 3) {
                url=$3
                sub(/\r$/, "", url)
                replacement=mirror_url(url)
                if (replacement != "") {
                    matched++
                    if (match(line, /https?:\/\/[^[:space:]]+/)) {
                        line=substr(line, 1, RSTART-1) replacement substr(line, RSTART+RLENGTH)
                    }
                }
            }
            print line
        }
        END { if (matched == 0) exit 4 }
    ' "$_osm_conf" > "$_osm_tmp"
    _osm_rc=$?
    if [ "$_osm_rc" -ne 0 ] || [ ! -s "$_osm_tmp" ]; then
        rm -f "$_osm_tmp"
        say "${YELLOW}В $_osm_conf не найдено распознаваемых источников официальных зеркал Entware. Файл не изменён.${RESET}"
        say 'Проверь строки src и src/gz в /opt/etc/opkg.conf; кастомные и сторонние репозитории автоматически не переписываются.'
        return 1
    fi
    if ! cmp -s "$_osm_conf" "$_osm_tmp" 2>/dev/null; then
        backup_file "$_osm_conf" || { rm -f "$_osm_tmp"; say "${RED}Не удалось сохранить резервную копию opkg.conf.${RESET}"; return 1; }
        chmod 644 "$_osm_tmp" 2>/dev/null || :
        mv -f "$_osm_tmp" "$_osm_conf" || { rm -f "$_osm_tmp"; say "${RED}Не удалось активировать новую конфигурацию OPKG.${RESET}"; return 1; }
        say "${GREEN}Зеркало Entware переключено на: $(xmenu_opkg_mirror_label "$_osm_base").${RESET}"
        say 'Настройка сохранена. opkg update автоматически не запускается, чтобы не блокировать меню при проблемах с сетью.'
    else
        rm -f "$_osm_tmp"
        say "${GREEN}Уже используется выбранное зеркало: $(xmenu_opkg_mirror_label "$_osm_base").${RESET}"
    fi
    return 0
}

xmenu_opkg_active_mirror_url() {
    _oam_conf=/opt/etc/opkg.conf
    [ -r "$_oam_conf" ] || return 1
    xmenu_opkg_mirrors_ensure_config || return 1
    _oam_url=$(xmenu_opkg_first_catalog_source_url | tr -d '\r')
    _oam_rest=${_oam_url#*://}
    [ "$_oam_rest" != "$_oam_url" ] || return 1
    _oam_host=${_oam_rest%%/*}
    _oam_path=${_oam_rest#"$_oam_host"}
    [ "$_oam_path" != "$_oam_rest" ] || _oam_path='/'
    while IFS='|' read -r _oam_id _oam_name _oam_base _oam_region || [ -n "$_oam_id" ]; do
        _oam_base=${_oam_base%/}
        case "$_oam_id" in ''|\#*) continue ;; *[!0-9]*) continue ;; esac
        _oam_base_rest=${_oam_base#*://}
        _oam_base_host=${_oam_base_rest%%/*}
        _oam_prefix=${_oam_base_rest#"$_oam_base_host"}
        [ "$_oam_prefix" != "$_oam_base_rest" ] || _oam_prefix=''
        [ "$_oam_host" = "$_oam_base_host" ] || continue
        if [ -n "$_oam_prefix" ] && [ "$_oam_prefix" != / ]; then
            case "$_oam_path" in "$_oam_prefix"/*|"$_oam_prefix") : ;; *) continue ;; esac
        fi
        printf '%s' "${_oam_base%/}"
        return 0
    done < "$XMENU_OPKG_MIRRORS_FILE"
    return 1
}

# Проверяем целостность всего gzip-индекса, а не только HTTP-ответ:
# перехватчик может вернуть страницу блокировки с кодом 200.
xmenu_opkg_is_packages_index() {
    [ -s "$1" ] || return 1
    gzip -t "$1" >/dev/null 2>&1 || return 1
    # Gzip-страница блокировки тоже является архивом: нужны поля пакета OPKG.
    gzip -dc "$1" 2>/dev/null | awk '
        /^Package:[[:space:]]+[^[:space:]]/ {package=1}
        /^Version:[[:space:]]+[^[:space:]]/ {version=1}
        /^[[:space:]]*$/ {if (package && version) valid=1; package=0; version=0}
        END {exit(valid || (package && version) ? 0 : 1)}
    '
}

# Ответ: доступно|задержка-мс|HTTP-код или причина. В режиме auto выполняем одну повторную
# попытку; в интерактивном списке проверяем один раз, чтобы не задерживать UI.
xmenu_opkg_probe_mirror() {
    command -v gzip >/dev/null 2>&1 || { printf 'unavailable||no-gzip'; return 0; }
    _opm_base=${1%/}
    _opm_feed=${2#/}
    while [ "${_opm_feed%/}" != "$_opm_feed" ]; do _opm_feed=${_opm_feed%/}; done
    _opm_attempts=${3:-1}
    if [ -n "$_opm_feed" ]; then _opm_url="$_opm_base/$_opm_feed/Packages.gz"
    else _opm_url="$_opm_base/Packages.gz"; fi
    _opm_attempt=0
    _opm_result=''
    _opm_code=''
    _opm_curl=$(command -v curl 2>/dev/null || printf '')
    _opm_wget=$(command -v wget 2>/dev/null || printf '')
    while [ "$_opm_attempt" -lt "$_opm_attempts" ]; do
        _opm_attempt=$((_opm_attempt + 1))
        _opm_tmp="/tmp/xmenu-mirror-probe-$$"
        rm -f "$_opm_tmp"
        if [ -n "$_opm_curl" ] && [ -x "$_opm_curl" ]; then
            # Используем обычный GET как в прежней рабочей проверке Entware:
            # некоторые зеркала и сборки curl на роутерах некорректно отвечают на Range.
            _opm_result=$("$_opm_curl" -L -sS --fail --connect-timeout 3 --max-time 6 -o "$_opm_tmp" -w '%{http_code}|%{time_total}' "$_opm_url" 2>/dev/null)
            _opm_rc=$?
            _opm_code=${_opm_result%%|*}
            _opm_seconds=${_opm_result#*|}
            if [ "$_opm_rc" -eq 0 ] && [ -s "$_opm_tmp" ] && xmenu_opkg_is_packages_index "$_opm_tmp"; then
                case "$_opm_seconds" in ''|*[!0-9.]*|*.*.*) _opm_ms=999999 ;;
                *) _opm_ms=$(awk -v t="$_opm_seconds" 'BEGIN {printf "%d", t * 1000}') ;;
                esac
                rm -f "$_opm_tmp"
                printf 'available|%s|%s' "$_opm_ms" "$_opm_code"
                return 0
            fi
            case "$_opm_rc:$_opm_code" in
                28:*) _opm_code='timeout' ;;
                0:2??) _opm_code="invalid-index-http-$_opm_code" ;;
                *) case "$_opm_code" in
                ''|000) _opm_code='000' ;;
                *) _opm_code="http-$_opm_code" ;;
                esac ;;
            esac
        fi
        # При сбое curl пробуем wget: поддержка TLS у этих сборок может различаться.
        if [ -n "$_opm_wget" ] && [ -x "$_opm_wget" ]; then
            # Совместимый с BusyBox wget-путь: обычное скачивание, как раньше.
            if xmenu_wget_bounded 6 "$_opm_wget" -q -T 6 -O "$_opm_tmp" "$_opm_url" 2>/dev/null && xmenu_opkg_is_packages_index "$_opm_tmp"; then
                rm -f "$_opm_tmp"
                printf 'available|999999|200'
                return 0
            fi
            [ -n "${_opm_code:-}" ] || _opm_code='download-or-invalid-index'
        elif [ -z "$_opm_curl" ]; then
            printf 'unavailable||no-transport'
            return 0
        fi
        rm -f "$_opm_tmp"
        [ "$_opm_attempt" -lt "$_opm_attempts" ] && sleep 1
    done
    printf 'unavailable||%s' "${_opm_code:-000}"
}

xmenu_opkg_probe_all() {
    _opa_force=${1:-0}
    _opa_attempts=${2:-1}
    _opa_feed=$(xmenu_opkg_feed_path) || return 1
    _opa_cache="$ROOT_DIR/opkg-mirrors-status.cache"
    _opa_now=$(date +%s 2>/dev/null || printf 0)
    case "$_opa_now" in ''|*[!0-9]*) _opa_now=0 ;; esac
    if [ "$_opa_force" != 1 ] && [ -r "$_opa_cache" ]; then
        _opa_checked=$(sed -n 's/^checked=//p' "$_opa_cache" | sed -n '1p')
        _opa_cached_feed=$(sed -n 's/^feed=//p' "$_opa_cache" | sed -n '1p')
        case "$_opa_checked" in ''|*[!0-9]*) _opa_checked=0 ;; esac
        _opa_checker=$(sed -n 's/^checker=//p' "$_opa_cache" | sed -n '1p')
        if [ "$_opa_checker" = 3 ] && [ "$_opa_cached_feed" = "$_opa_feed" ] && [ $((_opa_now - _opa_checked)) -ge 0 ] 2>/dev/null && [ $((_opa_now - _opa_checked)) -lt 60 ] 2>/dev/null; then return 0; fi
    fi
    _opa_tmp="$_opa_cache.tmp.$$"
    {
        printf 'checker=3\nchecked=%s\nfeed=%s\n' "$_opa_now" "$_opa_feed"
        while IFS='|' read -r _opa_id _opa_name _opa_base _opa_region || [ -n "$_opa_id" ]; do
            case "$_opa_id" in ''|\#*) continue ;; *[!0-9]*) continue ;; esac
            case "$_opa_base" in http://*|https://*) : ;; *) continue ;; esac
            case "$_opa_base" in *[!A-Za-z0-9:/._-]*) continue ;; esac
            _opa_status=$(xmenu_opkg_probe_mirror "$_opa_base" "$_opa_feed" "$_opa_attempts")
            printf 'mirror=%s|%s\n' "$_opa_id" "$_opa_status"
        done < "$XMENU_OPKG_MIRRORS_FILE"
    } > "$_opa_tmp" 2>/dev/null || { rm -f "$_opa_tmp"; return 1; }
    mv -f "$_opa_tmp" "$_opa_cache" || { rm -f "$_opa_tmp"; return 1; }
    return 0
}

xmenu_opkg_show_active_repository() {
    _osar_lang=$1
    _osar_source=$(xmenu_opkg_first_catalog_source_url 2>/dev/null || :)
    _osar_base=$(xmenu_opkg_active_mirror_url 2>/dev/null || :)
    if [ -n "$_osar_base" ] && xmenu_opkg_mirror_info_by_url "$_osar_base"; then
        _osar_label="✓ $XMENU_MIRROR_NAME ($XMENU_MIRROR_REGION)"
    else
        _osar_source=$(awk '($1=="src/gz" || $1=="src") && NF>=3 {print $3; exit}' /opt/etc/opkg.conf 2>/dev/null)
        if [ "$_osar_lang" = en ]; then _osar_label='Custom repository'; else _osar_label='Пользовательский репозиторий'; fi
    fi
    if [ -z "$_osar_source" ]; then
        if [ "$_osar_lang" = en ]; then say "${YELLOW}No package source found in opkg.conf.${RESET}"
        else say "${YELLOW}В opkg.conf не найден источник пакетов.${RESET}"; fi
    else
        if [ "$_osar_lang" = en ]; then say "  Current: ${ACTIVE}$_osar_label${RESET}"
        else say "  Текущий: ${ACTIVE}$_osar_label${RESET}"; fi
        say "  URL:     ${ACTIVE}$_osar_source${RESET}"
    fi
    return 0
}

xmenu_opkg_probe_reason() {
    _opr_code=$1
    _opr_lang=$2
    if [ "$_opr_lang" = en ]; then
        case "$_opr_code" in
            http-*) printf 'Server returned HTTP %s.' "${_opr_code#http-}" ;;
            invalid-index-*) printf 'Response is not a valid OPKG package index.' ;;
            timeout) printf 'Download timed out.' ;;
            no-gzip) printf 'gzip is required to validate package indexes.' ;;
            no-transport) printf 'Neither curl nor wget is available.' ;;
            *) printf 'Could not download and validate the package index.' ;;
        esac
    else
        case "$_opr_code" in
            http-*) printf 'Сервер вернул HTTP %s.' "${_opr_code#http-}" ;;
            invalid-index-*) printf 'Ответ не является корректным индексом пакетов OPKG.' ;;
            timeout) printf 'Истекло время ожидания загрузки.' ;;
            no-gzip) printf 'Для проверки индекса нужна команда gzip.' ;;
            no-transport) printf 'Не найдены curl и wget.' ;;
            *) printf 'Не удалось скачать и проверить индекс пакетов.' ;;
        esac
    fi
}

xmenu_opkg_check_mirrors() {
    _ocm_conf=/opt/etc/opkg.conf
    [ -r "$_ocm_conf" ] || { say "Не найден $_ocm_conf."; return 1; }
    _ocm_force=${1:-0}
    _ocm_feed=$(xmenu_opkg_feed_path) || { say "${RED}Не удалось определить путь Entware-репозитория из $_ocm_conf.${RESET}"; return 1; }
    _ocm_lang=$(get_ui_lang)
    if [ "$_ocm_force" = 1 ]; then
        if [ "$_ocm_lang" = en ]; then say 'Refreshing Entware mirror availability…'
        else say 'Обновляю доступность зеркал Entware…'; fi
    fi
    xmenu_opkg_probe_all "$_ocm_force" 1 || { say "${RED}Не удалось проверить зеркала: проверь opkg.conf и сеть.${RESET}"; return 1; }
    _ocm_active=$(xmenu_opkg_active_mirror_url 2>/dev/null || :)
    _ocm_cache="$ROOT_DIR/opkg-mirrors-status.cache"
    line
    if [ "$_ocm_lang" = en ]; then
        say "${WHITE}◆ ENTWARE REPOSITORIES${RESET}"
        say 'The Packages.gz content is verified; blocking pages count as unavailable.'
        [ -n "$_ocm_active" ] && say "Current repository: ${ACTIVE}$_ocm_active${RESET}"
    else
        say "${WHITE}◆ РЕПОЗИТОРИИ ENTWARE / OPKG${RESET}"
        say 'Проверяется содержимое Packages.gz; страницы блокировки считаются недоступностью.'
        [ -n "$_ocm_active" ] && say "Текущий репозиторий: ${ACTIVE}$_ocm_active${RESET}"
    fi
    line
    _ocm_available=0
    _ocm_total=0
    while IFS='|' read -r _ocm_id _ocm_name _ocm_base _ocm_region || [ -n "$_ocm_id" ]; do
        _ocm_base=${_ocm_base%/}
        _ocm_region=${_ocm_region%"$(printf '\r')"}
        case "$_ocm_id" in ''|\#*) continue ;; *[!0-9]*) continue ;; esac
        case "$_ocm_base" in http://*|https://*) : ;; *) continue ;; esac
        _ocm_total=$((_ocm_total + 1))
        _ocm_row=$(awk -F '|' -v id="$_ocm_id" '$1=="mirror=" id {print substr($0, index($0, "|")+1); exit}' "$_ocm_cache")
        _ocm_state=${_ocm_row%%|*}
        _ocm_rest=${_ocm_row#*|}
        _ocm_ms=${_ocm_rest%%|*}
        _ocm_reason=${_ocm_rest#*|}
        _ocm_host_url=${_ocm_base#*://}; _ocm_host=${_ocm_host_url%%/*}
        _ocm_marker=''
        [ "$_ocm_base" = "$_ocm_active" ] && { if [ "$_ocm_lang" = en ]; then _ocm_marker='  ✓ current'; else _ocm_marker='  ✓ текущее'; fi; }
        case "$_ocm_state" in
            available)
                _ocm_available=$((_ocm_available + 1))
                case "$_ocm_ms" in ''|*[!0-9]*|999999)
                    if [ "$_ocm_lang" = en ]; then _ocm_time='time n/a'; else _ocm_time='время н/д'; fi ;;
                    *) if [ "$_ocm_lang" = en ]; then _ocm_time="${_ocm_ms} ms"; else _ocm_time="${_ocm_ms} мс"; fi ;;
                esac
                if [ "$_ocm_lang" = en ]; then _ocm_status="${GREEN}● available${RESET}"
                else _ocm_status="${GREEN}● доступно${RESET}"; fi ;;
            *) if [ "$_ocm_lang" = en ]; then _ocm_status="${RED}● unavailable${RESET}"; _ocm_time='—'
               else _ocm_status="${RED}● недоступно${RESET}"; _ocm_time='—'; fi ;;
        esac
        if [ -n "$_ocm_marker" ]; then
            say "  $_ocm_status  ${ACTIVE}$_ocm_name [$_ocm_region] — $_ocm_time$_ocm_marker${RESET}"
        else
            say "  $_ocm_status  $_ocm_name [$_ocm_region] — $_ocm_time"
        fi
        say "      URL: ${_ocm_base%/}"
        if [ "$_ocm_state" != available ] && [ -n "$_ocm_reason" ]; then
            say "      $(xmenu_opkg_probe_reason "$_ocm_reason" "$_ocm_lang")"
        fi
        say ''
    done < "$XMENU_OPKG_MIRRORS_FILE"
    line
    if [ "$_ocm_lang" = en ]; then say "Available repositories: ${GREEN}$_ocm_available${RESET} / $_ocm_total"
    else say "Доступно репозиториев: ${GREEN}$_ocm_available${RESET} из $_ocm_total"; fi
    line
}

xmenu_opkg_auto_select_mirror() {
    _oas_feed=$(xmenu_opkg_feed_path) || { say "${RED}Не удалось определить путь репозитория. Проверь /opt/etc/opkg.conf.${RESET}"; return 1; }
    _oas_lang=$(get_ui_lang)
    if [ "$_oas_lang" = en ]; then say 'Testing repository response time (one retry on connection failure)…'
    else say 'Ищу доступное зеркало (при ошибке - повторная попытка)..'; fi
    xmenu_opkg_probe_all 1 2 || { say "${RED}Не удалось проверить репозитории. Проверь URL в /opt/etc/opkg.conf и подключение к интернету.${RESET}"; return 1; }
    _oas_cache="$ROOT_DIR/opkg-mirrors-status.cache"
    _oas_best_id=''
    _oas_best_ms=2147483647
    while IFS='|' read -r _oas_id _oas_name _oas_base _oas_region || [ -n "$_oas_id" ]; do
        case "$_oas_id" in ''|\#*) continue ;; *[!0-9]*) continue ;; esac
        _oas_row=$(awk -F '|' -v id="$_oas_id" '$1=="mirror=" id {print substr($0, index($0, "|")+1); exit}' "$_oas_cache")
        _oas_state=${_oas_row%%|*}
        _oas_rest=${_oas_row#*|}
        _oas_ms=${_oas_rest%%|*}
        [ "$_oas_state" = available ] || continue
        case "$_oas_ms" in ''|*[!0-9]*) _oas_ms=999999 ;; esac
        if [ -z "$_oas_best_id" ] || [ "$_oas_ms" -lt "$_oas_best_ms" ]; then
            _oas_best_id=$_oas_id
            _oas_best_ms=$_oas_ms
        fi
    done < "$XMENU_OPKG_MIRRORS_FILE"
    if [ -z "$_oas_best_id" ] || ! xmenu_opkg_mirror_info_by_id "$_oas_best_id"; then
        if [ "$_oas_lang" = en ]; then say "${RED}No Entware repository responded successfully. Configuration was not changed.${RESET}"
        else say "${RED}Не найдено доступных зеркал Entware. Конфигурация не изменена.${RESET}"; fi
        return 1
    fi
    _oas_name=$XMENU_MIRROR_NAME
    _oas_base=$XMENU_MIRROR_URL
    _oas_region=$XMENU_MIRROR_REGION
    xmenu_opkg_set_mirror "$_oas_base" || return 1
    if [ "$_oas_lang" = en ]; then
        say "${GREEN}Selected $_oas_name ($_oas_region), response time ${_oas_best_ms} ms.${RESET}"
        say 'The new source is active immediately; run opkg update to refresh package indexes.'
    else
        say "${GREEN}Выбрано зеркало $_oas_name ($_oas_region), отклик ${_oas_best_ms} мс.${RESET}"
        say 'Новый источник действует сразу; для обновления индексов запусти opkg update.'
    fi
}

xmenu_opkg_check_selected_mirror() {
    _ocsm_base=$(xmenu_opkg_active_mirror_url) || { say 'В opkg.conf не найден текущий репозиторий из каталога.'; return 1; }
    _ocsm_feed=$(xmenu_opkg_feed_path) || return 1
    xmenu_opkg_mirror_info_by_url "$_ocsm_base" || return 1
    _ocsm_status=$(xmenu_opkg_probe_mirror "$_ocsm_base" "$_ocsm_feed" 1)
    if [ "${_ocsm_status%%|*}" = available ]; then
        _ocsm_rest=${_ocsm_status#*|}; _ocsm_ms=${_ocsm_rest%%|*}
        say "${GREEN}✓ $XMENU_MIRROR_NAME — доступно (${_ocsm_ms} мс)${RESET}"
    else
        say "${RED}✗ $XMENU_MIRROR_NAME — не отвечает. Выбери другой репозиторий или запусти авто-выбор.${RESET}"
        return 1
    fi
}

xmenu_opkg_restore_config() {
    acquire_lock || return 1
    xmenu_opkg_restore_config_locked
    _orc_apply_rc=$?
    release_operation_lock
    return "$_orc_apply_rc"
}

xmenu_opkg_restore_config_locked() {
    _orc_conf=/opt/etc/opkg.conf
    _orc_latest=$(ls -1t "$BACKUP_DIR"/opkg.conf.*.bak 2>/dev/null | sed -n '1p')
    [ -n "$_orc_latest" ] && [ -r "$_orc_latest" ] || { say 'Резервная копия opkg.conf не найдена.'; return 1; }
    say "Восстановить $_orc_latest? Текущая конфигурация тоже будет сохранена в резервную копию."
    confirm 'Восстановить резервную копию OPKG?' || { say 'Восстановление отменено.'; return 1; }
    backup_file "$_orc_conf" || return 1
    _orc_tmp="/opt/etc/.opkg.conf.restore.$$"
    cp -p "$_orc_latest" "$_orc_tmp" || { rm -f "$_orc_tmp"; return 1; }
    mv -f "$_orc_tmp" "$_orc_conf" || { rm -f "$_orc_tmp"; return 1; }
    say "${GREEN}Конфигурация OPKG восстановлена из бэкапа.${RESET}"
}

xmenu_opkg_manual_mirror_menu() {
    _omm_lang=$(get_ui_lang)
    xmenu_opkg_mirrors_ensure_config || { say 'Не удалось загрузить каталог зеркал.'; return 1; }
    while :; do
        line
        if [ "$_omm_lang" = en ]; then
            say "${WHITE}CHOOSE AN ENTWARE MIRROR${RESET}"
            say 'Select a mirror by number. No network checks are run here.'
            _omm_prompt='[?] Repository: '
            _omm_back='Back'
        else
            say "${WHITE}ВЫБОР ЗЕРКАЛА ENTWARE${RESET}"
            say 'Выбери зеркало по номеру. Сетевая проверка здесь не запускается.'
            _omm_prompt='[?] Репозиторий: '
            _omm_back='Назад'
        fi
        xmenu_opkg_show_active_repository "$_omm_lang"
        line
        _omm_active=$(xmenu_opkg_active_mirror_url 2>/dev/null || :)
        while IFS='|' read -r _omm_id _omm_name _omm_url _omm_region || [ -n "$_omm_id" ]; do
            _omm_region=${_omm_region%"$(printf '\r')"}
            case "$_omm_id" in ''|\#*) continue ;; *[!0-9]*) continue ;; esac
            case "$_omm_url" in http://*|https://*) : ;; *) continue ;; esac
            if [ "${_omm_url%/}" = "$_omm_active" ]; then
                printf '%s' "$ACTIVE"
                menu_item "$_omm_id" "✓ $_omm_name — $_omm_region"
                say "           ${_omm_url%/}"
                printf '%s' "$RESET"
            else
                menu_item "$_omm_id" "$_omm_name — $_omm_region"
                say "           ${_omm_url%/}"
            fi
        done < "$XMENU_OPKG_MIRRORS_FILE"
        menu_item 0 "$_omm_back"
        line
        _read_or_eof "$_omm_prompt" || return 0
        case "$_read_value" in
            0|'') return 0 ;;
            *[!0-9]*) say 'Неверный пункт.'; sleep 1 ;;
            *)
                if xmenu_opkg_mirror_info_by_id "$_read_value"; then
                    xmenu_opkg_set_mirror "$XMENU_MIRROR_URL"
                    pause
                else
                    say 'Такого зеркала нет в каталоге.'
                    sleep 1
                fi
                ;;
        esac
    done
}

opkg_settings_menu() {
    _osm_lang=$(get_ui_lang)
    while :; do
        line
        if [ "$_osm_lang" = en ]; then
            say "${BRIGHT_CYAN}OPKG / Entware repositories:${RESET}"
            xmenu_opkg_show_active_repository en
            line
            menu_item 1 'Auto-select Entware mirror - check and choose an available source'
            menu_item 2 'Check Entware mirror availability'
            menu_item 3 'Choose Entware mirror manually - Region, URL and current selection.'
            menu_item 4 'Restore latest opkg.conf backup'
            menu_item 5 'Run opkg update'
            menu_item 0 'Back'
            _osm_prompt='[?] Select an option: '
        else
            say "${BRIGHT_CYAN}Репозитории OPKG / Entware:${RESET}"
            xmenu_opkg_show_active_repository ru
            line
            menu_item 1 'Авто-выбор Entware — проверит и выберет доступное зеркало'
            menu_item 2 'Проверить доступность зеркал Entware'
            menu_item 3 'Выбрать зеркало Entware вручную - Регион, адрес и текущий выбор.'
            menu_item 4 'Восстановить копию opkg.conf'
            menu_item 5 'Выполнить opkg update'
            menu_item 0 'Назад'
            _osm_prompt='[?] Выбери пункт: '
        fi
        line
        _read_or_eof "$_osm_prompt" || return 0
        case "$_read_value" in
            1) xmenu_opkg_auto_select_mirror; pause ;;
            2) xmenu_opkg_check_mirrors 1; pause ;;
            3) xmenu_opkg_manual_mirror_menu ;;
            4) xmenu_opkg_restore_config; pause ;;
            5)
                say 'opkg update обновляет индексы репозитория, но не установленные пакеты.'
                confirm 'Выполнить opkg update?' && opkg update
                pause ;;
            0|'') return 0 ;;
            *) say 'Неверный пункт.'; sleep 1 ;;
        esac
    done
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
    _rnf_download="/tmp/xmenu-nfqws-download-$$.sh"
    _rnf_run="/tmp/xmenu-nfqws-action-$$.sh"
    rm -f "$_rnf_run"
    # Keep the validated upstream file for this process; repeated actions reuse it.
    _rnf_valid=0
    if [ -s "$_rnf_src" ]; then
        _rnf_size=$(wc -c < "$_rnf_src" 2>/dev/null | tr -d ' ')
        case "$_rnf_size" in ''|*[!0-9]*) _rnf_size=0 ;; esac
        _rnf_last=$(tr -d '\r' < "$_rnf_src" | sed '/^[[:space:]]*$/d' | tail -n 1 | sed 's/[[:space:]]*$//')
        if [ "$_rnf_size" -ge 50000 ] && grep -q '^SCRIPT_VERSION=' "$_rnf_src" && \
           grep -q '^main_menu()' "$_rnf_src" && nfmenu_final_main_menu_call "$_rnf_src" && \
           grep -Eq "^${_rnf_action}[[:space:]]*\(\)[[:space:]]*\{" "$_rnf_src" && sh -n "$_rnf_src"; then
            _rnf_valid=1
        fi
    fi
    if [ "$_rnf_valid" != 1 ]; then
        rm -f "$_rnf_src" "$_rnf_download"
        say "Загружаю официальный nfqws-menu для действия: $_rnf_action"
        if ! fetch "$NF_REPO/nfqws-menu.sh" "$_rnf_download" 90; then
            rm -f "$_rnf_download" "$_rnf_run"
            say "${RED}Не удалось получить актуальный nfqws-menu.${RESET}"
            return 1
        fi
        _rnf_size=$(wc -c < "$_rnf_download" 2>/dev/null | tr -d ' ')
        case "$_rnf_size" in ''|*[!0-9]*) _rnf_size=0 ;; esac
        _rnf_last=$(tr -d '\r' < "$_rnf_download" | sed '/^[[:space:]]*$/d' | tail -n 1 | sed 's/[[:space:]]*$//')
        if [ "$_rnf_size" -lt 50000 ] || response_looks_like_error_page "$_rnf_download" || \
           ! grep -q '^SCRIPT_VERSION=' "$_rnf_download" || ! grep -q '^main_menu()' "$_rnf_download" || \
           ! nfmenu_final_main_menu_call "$_rnf_download" || \
           ! grep -Eq "^${_rnf_action}[[:space:]]*\(\)[[:space:]]*\{" "$_rnf_download" || ! sh -n "$_rnf_download"; then
            rm -f "$_rnf_download" "$_rnf_run"
            say "${RED}Проверка источника nfqws-menu не пройдена; выполнение отменено.${RESET}"
            return 1
        fi
        tr -d '\r' < "$_rnf_download" > "$_rnf_src" || { rm -f "$_rnf_download" "$_rnf_src"; return 1; }
        rm -f "$_rnf_download"
    fi
    # Remove only the final nonblank `main_menu` invocation. The awk script
    # buffers blank lines so interior blank lines (including here-doc content)
    # are preserved exactly; trailing blank lines are emitted after the last line.
    if ! nfmenu_strip_final_main_menu_call "$_rnf_src" > "$_rnf_run"; then
        rm -f "$_rnf_run"
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
    if has_controlling_tty; then
        NFQWS_MENU_LANG="$(get_ui_lang)" XMENU_NFQWS_ACTION="$_rnf_action" sh "$_rnf_run" </dev/tty >/dev/tty 2>&1 || _rnf_rc=$?
    else
        NFQWS_MENU_LANG="$(get_ui_lang)" XMENU_NFQWS_ACTION="$_rnf_action" sh "$_rnf_run" || _rnf_rc=$?
    fi
    rm -f "$_rnf_run"
    return "$_rnf_rc"
}

# The main menu is the single entry point; duplicate unreachable install/service menus were removed.

render_menu() {
    _XMENU_RENDER_WIDTH=$(terminal_width)
    [ -t 1 ] && printf '\033[2J\033[H'
    _lang=$(get_ui_lang)
    # Router model, firmware and Entware architecture do not change during one menu session.
    # Query once, then reuse the values when returning from a submenu/action.
    if [ "${_XMENU_DEVICE_CACHE_READY:-0}" != 1 ]; then
        _XMENU_DEVICE_INFO_CACHE=$(get_router)
        _XMENU_ARCH_CACHE=$(get_arch)
        _XMENU_DEVICE_CACHE_READY=1
    fi
    _r=$_XMENU_DEVICE_INFO_CACHE
    _model=${_r%%|*}; _fw=${_r#*|}; _arch=$_XMENU_ARCH_CACHE
    # У заголовка постоянный отступ в 12 знакомест, как в образце интерфейса.
    _title="Xmenu ◆ v$APP_VERSION"
    XMENU_UPDATE_NOTICE_VISIBLE=0
    printf '%12s%s%s%s\n' '' "$WHITE" "$_title" "$RESET"
    line

    # Architecture uses nfqws-menu order: opkg print-architecture -> opkg.conf -> uname -m.
    _cpu=$_arch
    if [ -z "$_cpu" ]; then
        if [ "$_lang" = en ]; then _cpu='not detected'; else _cpu='не определена'; fi
    fi
    if [ -z "$_arch" ]; then
        if [ "$_lang" = en ]; then _arch='not detected'; else _arch='не определена'; fi
    fi

    if [ "$_lang" = en ]; then
        printf '%sModel: %s %s %s%s\n' "$CYAN" "$_model" "${_fw:-not detected}" "$_cpu" "$RESET"
    else
        printf '%sМодель: %s %s %s%s\n' "$CYAN" "$_model" "${_fw:-не определена}" "$_cpu" "$RESET"
    fi
    render_component_statuses
    line

    if [ "$_lang" = en ]; then
        menu_item U 'Check for Xmenu updates now'
    else
        menu_item U 'Проверить наличие обновления Xmenu'
    fi
    xmenu_show_pending_update_notice

    if [ "$_lang" = en ]; then
        say "${PURPLE}[::]  Install / update:${RESET}"
        menu_item 1  'XKeen — Stable'
        menu_item 2  'XKeen UI — zxc-rv'
        menu_item 3  'XKeen UI — umarcheh001'
        menu_item 4  'nfqws2'
        menu_item 5  'nfqws-web-keenetic'
        menu_item 6  'nfqws2-ui'
        say ""
        say "${PURPLE}[::]  Manual installation profiles:${RESET}"
        menu_item 7  'XKeen Auto (Mihomo + GeoIPSet + XKeen at startup)'
        menu_item 8  'XKeen Auto (Xray + GeoIPSet + XKeen at startup)'
        menu_item 9  'Mihomo + GeoIPSet + XKeen Auto + XKeen UI + nfqws2 + nfqws-web-keenetic'
        menu_item 10 'Xray + GeoIPSet + XKeen Auto + XKeen UI + nfqws2 + nfqws-web-keenetic'
        say ""
        say "${PURPLE}[::]  Strategies / blobs / lists:${RESET}"
        menu_item 11 'Select and apply nfqws strategy'
        menu_item 12 'Download/check blobs and lists for active strategy from the list'
        menu_item 13 'Install all nfqws2 blobs'
        menu_item 14 'Download rkn.list (nfqws2 / nfqws) — 125k+ domains'
        say ""
        say "${PURPLE}[::]  Utilities / diagnostics:${RESET}"
        menu_item 15 'DPI Detector (DNS/16 KB)'
        menu_item 16 'TG WS Proxy Rust'
        menu_item 17 'KeenKit'
        menu_item 18 'awg-manager'
        say ""
        say "${PURPLE}[::]  Maintenance / settings:${RESET}"
        menu_item 19 'Сменить язык: RU / EN (change language)'
        menu_item 20 'Remove components'
        menu_item 21 'Remove Xmenu'
        menu_item 22 'Update Xmenu'
        menu_item 23 'OPKG settings / Entware mirrors'
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
        say ""
        say "${PURPLE}[::]  Ручные настройки установки:${RESET}"
        menu_item 7  'XKeen Auto (Mihomo + GeoIPSet + XKeen в автозагрузке)'
        menu_item 8  'XKeen Auto (Xray + GeoIPSet + XKeen в автозагрузке)'
        menu_item 9  'Mihomo + GeoIPSet + XKeen Auto + XKeen UI + nfqws2 + nfqws-web-keenetic'
        menu_item 10 'Xray + GeoIPSet + XKeen Auto + XKeen UI + nfqws2 + nfqws-web-keenetic'
        say ""
        say "${PURPLE}[::]  Стратегии / blobs / lists:${RESET}"
        menu_item 11 'Выбрать и применить стратегию nfqws'
        menu_item 12 'Скачать/проверить blobs и lists активной стратегии из списка'
        menu_item 13 'Установить все blobs nfqws2'
        menu_item 14 'Скачать rkn.list (nfqws2 / nfqws) — 125k+ доменов'
        say ""
        say "${PURPLE}[::]  Утилиты и диагностика:${RESET}"
        menu_item 15 'DPI Detector (DNS/16kb)'
        menu_item 16 'TG WS Proxy Rust'
        menu_item 17 'KeenKit'
        menu_item 18 'awg-manager'
        say ""
        say "${PURPLE}[::]  Обслуживание и настройки:${RESET}"
        menu_item 19 'Сменить язык: RU / EN (change language)'
        menu_item 20 'Удаление компонентов'
        menu_item 21 'Удалить Xmenu'
        menu_item 22 'Обновить Xmenu'
        menu_item 23 'Настройки OPKG / зеркала Entware'
        menu_item 0  'Выход'
        _prompt='[?] Выберите пункт [Enter = выход]: '
    fi
    line
    _XMENU_RENDER_WIDTH=''
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
    if [ "$_rxc_core" = mihomo ] && [ -x /opt/sbin/xkeen ]; then
        confirm 'Удалить Mihomo штатной командой xkeen -dm? Конфигурация Mihomo может быть удалена самой XKeen.' || { say 'Удаление отменено.'; return 1; }
        /opt/sbin/xkeen -dm
        return $?
    fi
    say "${YELLOW}$_rxc_core не является отдельным opkg-пакетом. Автоматическое удаление бинарника отключено, чтобы не повредить управление XKeen/конфиги.${RESET}"
    return 1
}

remove_all_nf_components() {
    confirm 'Удалить все установленные пакеты NFQWS и NFQWS UI? Пользовательские конфиги будут сохранены.' || { say 'Удаление отменено.'; return 1; }
    _ran_failed=0
    for _ran_pkg in nfqws2-ui nfqws-ui nfqws-keenetic-web nfqws2-keenetic nfqws-keenetic; do
        [ "${INTERRUPTED:-0}" = 0 ] || { say 'Удаление пакетов NFQWS прервано; оставшиеся пакеты сохранены.'; return 130; }
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
    if [ "$(get_ui_lang)" = en ]; then
        say 'Backup cleanup scans /opt/etc/nfqws, /opt/etc/nfqws2, /opt/etc/xkeen, /opt/etc/lighttpd and /opt/etc/xmenu/backups.'
        say 'Matching files: *.bak, *.bak.* and *-opkg. The active configuration files are not selected.'
    else
        say 'Проверяются каталоги: /opt/etc/nfqws, /opt/etc/nfqws2, /opt/etc/xkeen, /opt/etc/lighttpd и /opt/etc/xmenu/backups.'
        say 'Маски файлов: *.bak, *.bak.* и *-opkg. Основные файлы конфигурации не затрагиваются.'
    fi
    _rb_list="$ROOT_DIR/remove-backups-list.$$"
    : > "$_rb_list" || return 1
    for _rb_dir in /opt/etc/nfqws /opt/etc/nfqws2 /opt/etc/xkeen /opt/etc/lighttpd /opt/etc/xmenu/backups; do
        [ -d "$_rb_dir" ] || continue
        if ! find "$_rb_dir" -type f \( -name '*.bak' -o -name '*.bak.*' -o -name '*-opkg' \) -print 2>/dev/null >> "$_rb_list"; then
            rm -f "$_rb_list"
            say "${RED}Не удалось проверить $_rb_dir; файлы не удалены.${RESET}"
            return 1
        fi
    done
    if [ ! -s "$_rb_list" ]; then
        rm -f "$_rb_list"
        say 'Резервные файлы указанного типа не найдены.'
        return 0
    fi
    _rb_count=$(wc -l < "$_rb_list" | tr -d ' ')
    say "Будет удалено резервных файлов: $_rb_count"
    while IFS= read -r _rb_file || [ -n "$_rb_file" ]; do
        [ "${INTERRUPTED:-0}" = 0 ] || { rm -f "$_rb_list"; say 'Очистка прервана; оставшиеся файлы сохранены.'; return 130; }
        [ -n "$_rb_file" ] && printf '  %s\n' "$_rb_file"
    done < "$_rb_list"
    if [ "$(get_ui_lang)" = en ]; then
        _rb_prompt='Delete all backups of what? : *.bak, *.bak.* and *-opkg files in the listed config folders. Continue?'
    else
        _rb_prompt='Удалить все резервные копии чего? : файлы *.bak, *.bak.* и *-opkg в перечисленных каталогах конфигураций. Продолжить?'
    fi
    confirm_no "$_rb_prompt" || { rm -f "$_rb_list"; say 'Очистка отменена.'; return 1; }
    _rb_removed=0
    _rb_failed=0
    while IFS= read -r _rb_file || [ -n "$_rb_file" ]; do
        [ "${INTERRUPTED:-0}" = 0 ] || { rm -f "$_rb_list"; say 'Очистка прервана; оставшиеся файлы сохранены.'; return 130; }
        [ -n "$_rb_file" ] || continue
        if rm -f "$_rb_file" 2>/dev/null; then
            _rb_removed=$((_rb_removed + 1))
        else
            _rb_failed=$((_rb_failed + 1))
            say "${RED}Не удалось удалить: $_rb_file${RESET}"
        fi
    done < "$_rb_list"
    [ "${INTERRUPTED:-0}" = 0 ] || { rm -f "$_rb_list"; say 'Очистка прервана.'; return 130; }
    rm -f "$_rb_list"
    say "Удалено резервных файлов: $_rb_removed"
    [ "$_rb_failed" -eq 0 ]
}

# Удаляет только файлы blobs (*.bin) из каталога NFQWS2; пакет и конфиги не затрагиваются.
remove_nfqw2_blobs() {
    _rnb_dir='/opt/etc/nfqws2/blobs'
    [ -d "$_rnb_dir" ] || {
        say "Каталог $_rnb_dir не найден; blobs удалять нечего."
        return 0
    }
    command -v find >/dev/null 2>&1 || { say "${RED}Команда find не найдена.${RESET}"; return 1; }
    _rnb_list="$ROOT_DIR/.remove-nfqws2-blobs.$$"
    : > "$_rnb_list" || return 1
    if ! find "$_rnb_dir" -maxdepth 1 -type f -name '*.bin' -print 2>/dev/null > "$_rnb_list"; then
        rm -f "$_rnb_list"
        say "${RED}Не удалось просканировать $_rnb_dir; файлы не удалены.${RESET}"
        return 1
    fi
    if [ ! -s "$_rnb_list" ]; then
        rm -f "$_rnb_list"
        say 'Файлы blobs (*.bin) не найдены.'
        return 0
    fi
    _rnb_count=$(wc -l < "$_rnb_list" | tr -d ' ')
    say "Найдено blobs для удаления: $_rnb_count"
    while IFS= read -r _rnb_file || [ -n "$_rnb_file" ]; do
        [ "${INTERRUPTED:-0}" = 0 ] || { rm -f "$_rnb_list"; say 'Удаление blobs прервано; оставшиеся файлы сохранены.'; return 130; }
        [ -n "$_rnb_file" ] && printf '  %s\n' "$_rnb_file"
    done < "$_rnb_list"
    if [ "$(get_ui_lang)" = en ]; then
        _rnb_prompt='Delete all *.bin files from /opt/etc/nfqws2/blobs? The nfqws2 package and configs will remain.'
    else
        _rnb_prompt='Удалить все файлы *.bin из /opt/etc/nfqws2/blobs? Пакет nfqws2 и конфигурации останутся.'
    fi
    confirm_no "$_rnb_prompt" || { rm -f "$_rnb_list"; say 'Удаление отменено.'; return 1; }
    _rnb_removed=0
    _rnb_failed=0
    while IFS= read -r _rnb_file || [ -n "$_rnb_file" ]; do
        [ "${INTERRUPTED:-0}" = 0 ] || { rm -f "$_rnb_list"; say 'Удаление blobs прервано; оставшиеся файлы сохранены.'; return 130; }
        [ -n "$_rnb_file" ] || continue
        if rm -f "$_rnb_file" 2>/dev/null; then
            _rnb_removed=$((_rnb_removed + 1))
        else
            _rnb_failed=$((_rnb_failed + 1))
            say "${RED}Не удалось удалить: $_rnb_file${RESET}"
        fi
    done < "$_rnb_list"
    [ "${INTERRUPTED:-0}" = 0 ] || { rm -f "$_rnb_list"; say 'Удаление blobs прервано.'; return 130; }
    rm -f "$_rnb_list"
    say "Удалено blobs: $_rnb_removed из $_rnb_count."
    [ "$_rnb_failed" -eq 0 ]
}

# Удаляет резервные копии Xmenu, не затрагивая действующий /opt/bin/xmenu.
# Архивы в BACKUP_DIR могут содержать сохранённые конфигурации — показываем их до подтверждения.
remove_xmenu_backups() {
    command -v find >/dev/null 2>&1 || { say "${RED}Команда find не найдена.${RESET}"; return 1; }
    _rxb_list="$ROOT_DIR/.remove-xmenu-backups.$$"
    : > "$_rxb_list" || return 1
    if [ -d /opt/bin ]; then
        find /opt/bin -maxdepth 1 \( -type f -o -type l \) -name 'xmenu.bak*' -print 2>/dev/null >> "$_rxb_list" || {
            rm -f "$_rxb_list"
            say "${RED}Не удалось просканировать /opt/bin; бэкапы не удалены.${RESET}"
            return 1
        }
    fi
    if [ -d "$BACKUP_DIR" ]; then
        find "$BACKUP_DIR" \( -type f -o -type l \) -print 2>/dev/null >> "$_rxb_list" || {
            rm -f "$_rxb_list"
            say "${RED}Не удалось просканировать $BACKUP_DIR; бэкапы не удалены.${RESET}"
            return 1
        }
    fi
    if [ ! -s "$_rxb_list" ]; then
        rm -f "$_rxb_list"
        say 'Резервные копии Xmenu не найдены.'
        return 0
    fi
    _rxb_count=$(wc -l < "$_rxb_list" | tr -d ' ')
    say "Найдено файлов резервных копий Xmenu: $_rxb_count"
    while IFS= read -r _rxb_file || [ -n "$_rxb_file" ]; do
        [ "${INTERRUPTED:-0}" = 0 ] || { rm -f "$_rxb_list"; say 'Очистка бэкапов прервана.'; return 130; }
        [ -n "$_rxb_file" ] && printf '  %s\n' "$_rxb_file"
    done < "$_rxb_list"
    if [ "$(get_ui_lang)" = en ]; then
        _rxb_prompt='Delete all Xmenu backups, including saved config backups in /opt/etc/xmenu/backups? The active /opt/bin/xmenu will remain.'
    else
        _rxb_prompt='Удалить все бэкапы Xmenu, включая копии конфигураций в /opt/etc/xmenu/backups? Действующий /opt/bin/xmenu останется.'
    fi
    confirm_no "$_rxb_prompt" || { rm -f "$_rxb_list"; say 'Удаление отменено.'; return 1; }
    _rxb_failed=0
    while IFS= read -r _rxb_file || [ -n "${_rxb_file}" ]; do
        [ "${INTERRUPTED:-0}" = 0 ] || { rm -f "${_rxb_list}"; say 'Очистка прервана; оставшиеся бэкапы сохранены.'; return 130; }
        [ -n "${_rxb_file}" ] || continue
        if rm -f "${_rxb_file}" 2>/dev/null; then
            :
        else
            _rxb_failed=1
            say "${RED}Не удалось удалить: ${_rxb_file}${RESET}"
        fi
    done < "${_rxb_list}"
    [ "${INTERRUPTED:-0}" = 0 ] || { rm -f "${_rxb_list}"; say 'Очистка прервана; оставшиеся бэкапы сохранены.'; return 130; }
    if [ -d "${BACKUP_DIR}" ]; then
        find "${BACKUP_DIR}" -depth -type d -exec rmdir {} \; 2>/dev/null || :
        rmdir "${BACKUP_DIR}" 2>/dev/null || :
    fi
    rm -f "${_rxb_list}"
    if [ "$_rxb_failed" -eq 0 ]; then
        say 'Резервные копии Xmenu удалены; действующий /opt/bin/xmenu сохранён.'
    else
        say "${RED}Не удалось удалить часть резервных копий Xmenu. Проверь права и остатки файлов.${RESET}"
    fi
    return "$_rxb_failed"
}

# Дополнительные пункты сохранены в отдельном списке, чтобы нумерация основных действий не менялась.
remove_optional_components_menu() {
    while :; do
        _REMOVE_MENU_FILE="$ROOT_DIR/.remove-components.$$"
        : > "$_REMOVE_MENU_FILE" || return 1
        _rm_lang=$(get_ui_lang)
        line
        if [ "$_rm_lang" = en ]; then say "${BRIGHT_CYAN}OTHER INSTALLED COMPONENTS${RESET}"
        else say "${BRIGHT_CYAN}ДРУГИЕ УСТАНОВЛЕННЫЕ КОМПОНЕНТЫ${RESET}"; fi
        if [ "$_rm_lang" = en ]; then say 'Only detected components are shown; shared dependencies are preserved.'
        else say 'Показываются только найденные компоненты; общие зависимости сохраняются.'; fi
        line
        xkeen_ui_umar_is_installed && _remove_menu_add ui-umar 'XKeen UI — umarcheh001'
        is_installed awg-manager && _remove_menu_add awg 'awg-manager'
        { [ -x /opt/bin/tgwsproxy ] || [ -x /opt/etc/init.d/S99tgwsproxy ] || [ -x /opt/bin/tg-ws-proxy-rs ] || [ -x /opt/etc/init.d/S99tg-ws-proxy-rs ]; } && _remove_menu_add tgws 'TG WS Proxy Rust'
        { [ -x /opt/keenkit.sh ] || [ -L /opt/bin/keenkit ]; } && _remove_menu_add keenkit 'KeenKit'
        is_installed nfqws-keenetic && _remove_menu_add nfqws1 'nfqws-keenetic'
        if is_installed nfqws2-ui || is_installed nfqws-ui || [ -x /opt/sbin/nfqws-ui-setup ] || [ -x /opt/usr/sbin/nfqws-ui-setup ]; then _remove_menu_add nfui 'NFQWS UI'; fi
        [ "$(get_xray_version)" != 'не найден' ] && _remove_menu_add xray 'Xray'
        if [ ! -s "$_REMOVE_MENU_FILE" ]; then
            if [ "$_rm_lang" = en ]; then say "  ${YELLOW}No additional components detected.${RESET}"
            else say "  ${YELLOW}Другие компоненты не обнаружены.${RESET}"; fi
            rm -f "$_REMOVE_MENU_FILE"
            return 0
        fi
        _rm_idx=0
        while IFS="$(printf '\t')" read -r _rm_code _rm_label || [ -n "$_rm_code" ]; do
            _rm_idx=$((_rm_idx + 1))
            menu_item "$_rm_idx" "$_rm_label"
        done < "$_REMOVE_MENU_FILE"
        menu_item 0 'Назад'
        line
        if [ "$_rm_lang" = en ]; then _rm_prompt='Choose a component [0 = back]: '
        else _rm_prompt='Выбери компонент [0 = назад]: '; fi
        _read_or_eof "$_rm_prompt" || { rm -f "$_REMOVE_MENU_FILE"; return 0; }
        _rm_choice=$_read_value
        case "$_rm_choice" in ''|0) rm -f "$_REMOVE_MENU_FILE"; return 0 ;; *[!0-9]*)
            if [ "$_rm_lang" = en ]; then say 'Enter a number only.'; else say 'Введи номер цифрами.'; fi
            rm -f "$_REMOVE_MENU_FILE"
            continue
            ;;
        esac
        while [ "${_rm_choice#0}" != "$_rm_choice" ]; do _rm_choice=${_rm_choice#0}; done
        [ -n "$_rm_choice" ] || _rm_choice=0
        _rm_code=$(sed -n "${_rm_choice}p" "$_REMOVE_MENU_FILE" 2>/dev/null | cut -f1)
        case "$_rm_code" in
            ui-umar) remove_xkeen_ui_umarcheh001 ;;
            awg) if confirm 'Удалить пакет awg-manager (настройки в /opt/etc/awg-manager сохранятся)?'; then opkg remove awg-manager || say "${RED}Не удалось удалить awg-manager.${RESET}"; fi ;;
            tgws)
                if confirm 'Удалить TG WS Proxy Rust, сохранив настройки?'; then
                    if [ -x /opt/etc/init.d/S99tg-ws-proxy-rs ] || [ -x /opt/bin/tg-ws-proxy-rs ]; then run_nfmenu_action remove_tg_ws_proxy_rs
                    else say "${YELLOW}Автоудаление старой реализации TG WS Proxy отключено; проверь пакет и инструкцию его версии.${RESET}"; fi
                fi ;;
            keenkit) if confirm 'Удалить KeenKit (/opt/keenkit.sh)?'; then rm -f /opt/keenkit.sh; [ ! -L /opt/bin/keenkit ] || rm -f /opt/bin/keenkit; say 'KeenKit удалён.'; fi ;;
            nfqws1) remove_nf2_component nfqws-keenetic ;;
            nfui) remove_nfui_component ;;
            xray) remove_xkeen_core xray ;;
            *) say 'Неверный пункт.' ;;
        esac
        rm -f "$_REMOVE_MENU_FILE"
        pause
    done
}

remove_components_menu() {
    while :; do
        _rm_lang=$(get_ui_lang)
        line
        if [ "$_rm_lang" = en ]; then
            say "${BRIGHT_CYAN}REMOVE UTILITIES AND COMPONENTS${RESET}"
            say 'Only selected packages or files are removed; configuration is preserved where possible.'
            line
            menu_item 1 'XKeen — full uninstall'
            menu_item 2 'XKeen UI — zxc-rv'
            menu_item 3 'DPI Detector'
            menu_item 4 'nfqws2-keenetic'
            menu_item 5 'nfqws-keenetic-web'
            menu_item 6 'Mihomo'
            menu_item 7 'Remove all NFQWS packages'
            menu_item 8 'Remove backup files (*.bak, *.bak.* / *-opkg)'
            menu_item 9 'Remove all NFQWS2 blobs (*.bin)'
            menu_item 10 'Remove all Xmenu backups (including config backups)'
            menu_item 11 'Other installed components'
            menu_item 0 'Back'
            _rm_prompt='Choose an action [0 = back]: '
        else
            say "${BRIGHT_CYAN}УДАЛЕНИЕ УТИЛИТ И КОМПОНЕНТОВ${RESET}"
            say 'Выбранный пакет или файл будет удалён; конфигурации сохраняются, если это возможно.'
            line
            menu_item 1 'XKeen — полная деинсталляция'
            menu_item 2 'XKeen UI — zxc-rv'
            menu_item 3 'DPI Detector'
            menu_item 4 'nfqws2-keenetic'
            menu_item 5 'nfqws-keenetic-web'
            menu_item 6 'Mihomo'
            menu_item 7 'Удалить все пакеты NFQWS'
            menu_item 8 'Удалить резервные копии (*.bak, *.bak.* / *-opkg)'
            menu_item 9 'Удалить все blobs NFQWS2 (*.bin)'
            menu_item 10 'Удалить все бэкапы Xmenu (включая копии конфигураций)'
            menu_item 11 'Другие установленные компоненты'
            menu_item 0 'Назад'
            _rm_prompt='Что удалить? Ваш выбор [0 = назад]: '
        fi
        line
        _read_or_eof "$_rm_prompt" || return 0
        _rm_choice=$_read_value
        case "$_rm_choice" in ''|0) return 0 ;; *[!0-9]*)
            if [ "$_rm_lang" = en ]; then say 'Enter a number only.'; else say 'Введи номер цифрами.'; fi
            continue
            ;;
        esac
        while [ "${_rm_choice#0}" != "$_rm_choice" ]; do _rm_choice=${_rm_choice#0}; done
        [ -n "$_rm_choice" ] || _rm_choice=0
        case "$_rm_choice" in
            1) if xkeen_is_installed; then remove_xkeen_component; else say 'XKeen не найден.'; fi ;;
            2) if xkeen_ui_zxc_is_installed; then remove_xkeen_ui_zxc; else say 'XKeen UI zxc-rv не найден.'; fi ;;
            3) remove_dpi_detector_component ;;
            4) remove_nf2_component nfqws2-keenetic ;;
            5) remove_nf2_component nfqws-keenetic-web ;;
            6) remove_xkeen_core mihomo ;;
            7) remove_all_nf_components ;;
            8) remove_component_backups ;;
            9) remove_nfqw2_blobs ;;
            10) remove_xmenu_backups ;;
            11) remove_optional_components_menu ;;
            *) say 'Неверный пункт.'; continue ;;
        esac
        pause
    done
}

remove_menu() {
    XMENU_REMOVED=0
    if [ "$(get_ui_lang)" = en ]; then
        _remove_prompt='Delete Xmenu and all its files and components?'
        _remove_keep_prompt="Keep configuration backups in $BACKUP_DIR?"
        _remove_delete_prompt="Delete all configuration backups in $BACKUP_DIR?"
    else
        _remove_prompt='Удалить xmenu и все его файлы и компоненты?'
        _remove_keep_prompt="Сохранить резервные копии конфигураций в $BACKUP_DIR?"
        _remove_delete_prompt="Удалить все резервные копии конфигураций в $BACKUP_DIR?"
    fi
    if ! confirm "$_remove_prompt"; then return 1; fi

    # Keep backups by default. A negative answer requires a second, explicit
    # confirmation before any user configuration archives are deleted.
    _remove_keep_backups=1
    if ! confirm_yes "$_remove_keep_prompt"; then
        if confirm_no "$_remove_delete_prompt"; then
            _remove_keep_backups=0
        else
            _remove_keep_backups=1
        fi
    fi

    _c=$(mktemp "$ROOT_DIR/crontab.XXXXXX" 2>/dev/null) || _c="$ROOT_DIR/crontab.$(date +%s)"
    if command -v crontab >/dev/null 2>&1 && crontab -l > "$_c" 2>/dev/null; then
        grep -Fv '/opt/bin/xmenu sync' "$_c" > "$_c.next" || :
        if ! crontab "$_c.next"; then
            rm -f "$_c" "$_c.next"
            say 'Не удалось сохранить crontab; удаление Xmenu отменено.'
            return 1
        fi
    fi

    # Stop this session's status worker before removing the directory that holds its lock.
    stop_component_status_refresh
    xmenu_stop_update_check
    rm -f "$_c.next" "$_c"
    rm -f /opt/bin/xmenu /opt/bin/xmenu.bak*

    if [ "$_remove_keep_backups" = 1 ]; then
        # Remove all Xmenu-owned entries except the backups directory itself.
        for _remove_path in "$ROOT_DIR"/* "$ROOT_DIR"/.[!.]* "$ROOT_DIR"/..?*; do
            [ -e "$_remove_path" ] || [ -L "$_remove_path" ] || continue
            [ "$_remove_path" = "$BACKUP_DIR" ] && continue
            rm -rf "$_remove_path" 2>/dev/null || :
        done
        if [ -d "$BACKUP_DIR" ]; then
            say "${GREEN}Xmenu удалён; резервные копии сохранены в $BACKUP_DIR. XKeen/nfqws2 сохранены.${RESET}"
        else
            rmdir "$ROOT_DIR" 2>/dev/null || :
            say "${GREEN}Xmenu удалён. Каталог резервных копий не найден. XKeen/nfqws2 сохранены.${RESET}"
        fi
    else
        rm -rf "$ROOT_DIR"
        say "${GREEN}Xmenu удалён вместе с конфигурацией и резервными копиями. XKeen/nfqws2 сохранены.${RESET}"
    fi
    XMENU_REMOVED=1
    return 0
}

main() {
    configure_locale
    require_root || return 1
    migrate_legacy_xmenu_data || { say "Не удалось перенести данные Xmenu в $ROOT_DIR. Старые файлы сохранены."; return 1; }
    # Фоновое чтение статусов не должно переустанавливать /opt/bin/xmenu.
    case "${1:-menu}" in __refresh-component-cache) : ;; *) install_xmenu_command || : ;; esac
    if [ "${1:-menu}" = update-xmenu ]; then
        update_xmenu_script
        return $?
    fi
    require_opkg || return 1
    ensure_dirs || return 1
    [ -s "$LANG_FILE" ] || printf 'ru\n' > "$LANG_FILE" 2>/dev/null || :
    case "${1:-menu}" in
        __refresh-component-cache)
            _xcrc_parent=${2:-}
            XMENU_FORCE_COMPONENT_REFRESH=1
            export XMENU_FORCE_COMPONENT_REFRESH
            render_component_statuses_sync >/dev/null 2>&1
            _xcrc_rc=$?
            if [ -d "$XMENU_COMPONENT_REFRESH_LOCK" ] &&
               [ "$(cat "$XMENU_COMPONENT_REFRESH_LOCK/menu_pid" 2>/dev/null || :)" = "$_xcrc_parent" ]; then
                rm -rf "$XMENU_COMPONENT_REFRESH_LOCK" 2>/dev/null || :
                case "$_xcrc_parent" in ''|*[!0-9]*|0) : ;; *) kill -USR1 "$_xcrc_parent" 2>/dev/null || : ;; esac
            fi
            return "$_xcrc_rc" ;;
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
            [ "$1" = install-nf-web2 ] || ensure_network || return 1
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
        dpi-detector) shift; launch_dpi "$@"; return $? ;;
        rkn-list) install_rkn_list; return $? ;;
        install-tg-ws-proxy-rust) install_tg_ws_proxy_rust; return $? ;;
        install-keenkit) install_keenkit; return $? ;;
        install-awg-manager) install_awg_manager; return $? ;;
        backup) backup_configs; return $? ;;
        opkg-settings) opkg_settings_menu; return $? ;;
        *) : ;;
    esac
    # Проверка последней версии работает в фоне: меню не ждёт GitHub/зеркала и не зависит от opkg.
    xmenu_start_update_check || :
    # Первое открытие не запускает установку компонентов и не показывает предупреждений.
    while :; do
        render_menu
        INTERRUPTED=0
        MENU_READING=1
        _menu_lang=$(get_ui_lang)
        if [ "$_menu_lang" = en ]; then _prompt='[?] Select an option [U = check updates, Enter = exit]: '; else _prompt='[?] Выберите пункт [U = проверить обновление, Enter = выход]: '; fi
        xmenu_read_menu_prompt "${LAVENDER}$_prompt${RESET}"
        _read_rc=$?
        MENU_READING=0
        if [ "$_read_rc" -eq 2 ]; then continue; fi
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
            1|2|3|4|5|6|7|8|9|10|15|16|17|18|20) invalidate_component_status_cache ;;
        esac
        case "$_choice" in
            u|U)
                check_xmenu_update_now
                pause
                continue
                ;;
        esac
        case "$_choice" in
            *[!0-9]*) say "${RED}Нужно ввести номер пункта цифрами.${RESET}"; continue ;;
        esac
        case "$_choice" in
            1) ensure_network && install_xkeen_stable_binary; pause ;;
            2) ensure_network && install_xkeen_ui; pause ;;
            3) ensure_network && install_xkeen_ui_umarcheh001; pause ;;
            4) ensure_network && install_nfqws2; pause ;;
            5) ensure_network && install_nf_web; pause ;;
            6) install_nf_web2; pause ;;
            7) install_xkeen_core_profile mihomo; invalidate_core_version_cache; pause ;;
            8) install_xkeen_core_profile xray; invalidate_core_version_cache; pause ;;
            9) install_manual_bundle_profile mihomo; invalidate_core_version_cache; pause ;;
            10) install_manual_bundle_profile xray; invalidate_core_version_cache; pause ;;
            11) ensure_network && strategy_menu; pause ;;
            12) sync_active_blobs; pause ;;
            13) install_all_nfqw2_blobs; pause ;;
            14) install_rkn_list; pause ;;
            15) launch_dpi; pause ;;
            16) run_nfmenu_action menu_tg_ws_proxy_rs; pause ;;
            17) run_nfmenu_action menu_keenkit; pause ;;
            18) run_nfmenu_action menu_awg_manager; pause ;;
            19) change_ui_language; pause ;;
            20) remove_components_menu; invalidate_core_version_cache ;;
            21) remove_menu; _remove_rc=$?; [ "${XMENU_REMOVED:-0}" = 1 ] && { cleanup; return 0; } ;;
            22) update_xmenu_script || pause ;;
            23) opkg_settings_menu ;;
            0) cleanup; return 0 ;;
            *) say "${RED}Неверный пункт.${RESET}"; sleep 1 ;;
        esac
    done
}

# First-run bootstrap: when launched from a transferred/downloaded path, install
# this exact script as /opt/bin/xmenu so the `xmenu` command remains available
# after the user exits the menu. When already running from the target, do nothing.
install_xmenu_command() {
    _ix_target='/opt/bin/xmenu'
    case "$0" in
        "$_ix_target") return 0 ;;
    esac
    _ix_source=$0
    case "$_ix_source" in
        /*) : ;;
        *) _ix_source="$PWD/$_ix_source" ;;
    esac
    [ -f "$_ix_source" ] && [ -r "$_ix_source" ] || return 0
    if [ -f "$_ix_target" ] && command -v cmp >/dev/null 2>&1 &&
       cmp -s "$_ix_source" "$_ix_target"; then
        return 0
    fi
    mkdir -p /opt/bin || {
        say "${RED}Не удалось создать /opt/bin; установи скрипт вручную в /opt/bin/xmenu.${RESET}"
        return 1
    }
    _ix_tmp="/opt/bin/.xmenu-bootstrap.$$"
    rm -f "$_ix_tmp"
    if ! cp "$_ix_source" "$_ix_tmp"; then
        rm -f "$_ix_tmp"
        say "${RED}Не удалось скопировать Xmenu в /opt/bin/xmenu.${RESET}"
        return 1
    fi
    if ! sh -n "$_ix_tmp"; then
        rm -f "$_ix_tmp"
        say "${RED}Проверка синтаксиса копии Xmenu не пройдена; установленная команда не изменена.${RESET}"
        return 1
    fi
    if ! chmod 700 "$_ix_tmp" || ! mv -f "$_ix_tmp" "$_ix_target"; then
        rm -f "$_ix_tmp"
        say "${RED}Не удалось активировать /opt/bin/xmenu.${RESET}"
        return 1
    fi
    say "${GREEN}Команда Xmenu установлена: /opt/bin/xmenu. После выхода из меню запускай командой xmenu.${RESET}"
    return 0
}

main "$@"
