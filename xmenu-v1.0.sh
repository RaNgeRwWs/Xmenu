#!/bin/sh
# Xmenu ◆ v1.4.4 — Entware / BusyBox ash
APP_VERSION="1.4.4"
# XKEEN_MENU_AUTO_YES=1/true/yes/on отключает подтверждение только для NFQWS2 UI в install-all.
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

# Ограничиваем диагностические команды: неисправный --version не должен
# удерживать первый показ меню. Интерактивный запуск утилит не ограничивается.
xmenu_run_bounded() {
    _xrb_limit=$1
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$_xrb_limit" "$@"
    elif command -v busybox >/dev/null 2>&1 && busybox timeout "$_xrb_limit" true >/dev/null 2>&1; then
        busybox timeout "$_xrb_limit" "$@"
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "$_xrb_limit" "$@" <<'XMENU_TIMEOUT'
import math
import os
import signal
import subprocess
import sys

child = None

def terminate():
    if child is None:
        return
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        child.wait(timeout=.3)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    child.wait()

def cancel(signum, frame):
    terminate()
    raise SystemExit(128 + signum)

try:
    limit = float(sys.argv[1])
    if not math.isfinite(limit) or limit <= 0:
        raise ValueError('Invalid timeout')
    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    child = subprocess.Popen(sys.argv[2:], stdin=subprocess.DEVNULL, start_new_session=True)
    try:
        code = child.wait(timeout=limit)
        sys.exit(code if code >= 0 else 128 - code)
    except subprocess.TimeoutExpired:
        terminate()
        sys.exit(124)
except (OSError, ValueError):
    terminate()
    sys.exit(127)
XMENU_TIMEOUT
    else
        # Эти команды читают только локальную базу пакетов; разрешаем их без
        # timeout, чтобы отсутствие утилиты не скрывало установленные компоненты.
        case "${1:-}:${2:-}" in
            opkg:list-installed|opkg:status) "$@" ;;
            *)
                say "${YELLOW}Команда отменена: timeout недоступен, безопасно ограничить время выполнения нельзя.${RESET}" >&2
                return 127
                ;;
        esac
    fi
}

# Version probes are short local commands. On BusyBox builds without `timeout`,
# run them directly, as Xmenu did before 1.4.1, instead of reporting timeout's
# missing-command status as an incompatible binary or an unknown version.
xmenu_run_version_probe() {
    _xrvp_limit=$1
    shift
    if command -v timeout >/dev/null 2>&1 ||
       { command -v busybox >/dev/null 2>&1 && busybox timeout "$_xrvp_limit" true >/dev/null 2>&1; }; then
        xmenu_run_bounded "$_xrvp_limit" "$@"
    else
        "$@"
    fi
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
        xmenu_run_bounded 3 opkg list-installed 2>/dev/null | awk -v p="$_ip_pkg" '$1==p{f=1} END{exit(f?0:1)}'
    fi
}
pkg_version() {
    _pv_pkg=$1
    if [ -n "${_OPKG_RENDER_CACHE_FILE:-}" ] && [ -r "$_OPKG_RENDER_CACHE_FILE" ]; then
        awk -v p="$_pv_pkg" '$1==p {if ($2=="-") print $3; else if ($2!="") print $2; exit}' "$_OPKG_RENDER_CACHE_FILE"
    else
        xmenu_run_bounded 3 opkg status "$_pv_pkg" 2>/dev/null | sed -n 's/^Version:[[:space:]]*//p' | head -n 1
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
        _rci=$(xmenu_wget_bounded 2 "$(command -v wget)" -qO- -T 2 http://127.0.0.1:79/rci/show/version 2>/dev/null) || _rci=''
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
        if command -v ndmc >/dev/null 2>&1; then _fallback=$(xmenu_run_bounded 3 env LD_LIBRARY_PATH=/lib:/usr/lib ndmc -c 'show version' 2>/dev/null); fi
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
install_nfqws1() (
    line; say "${CYAN}nfqws v1 — поэтапная установка / обновление${RESET}"
    require_opkg || return 1
    _nf1_conf=${XMENU_NFQWS1_CONF:-/opt/etc/nfqws/nfqws.conf}
    _nf1_init=${XMENU_NFQWS1_INIT:-/opt/etc/init.d/S51nfqws}
    _nf1_feed=${XMENU_NFQWS1_FEED:-/opt/etc/opkg/nfqws-keenetic.conf}
    _nf1_tmp=''
    trap '[ -z "$_nf1_tmp" ] || rm -f "$_nf1_tmp"' 0
    trap 'exit 130' INT TERM HUP
    say '[1/5] Проверка Entware и совместимости'
    _nf1_arch=$(get_arch) || return 1
    case "$_nf1_arch" in aarch64|armv7|mipsel|mips|mips64|x86_64|x86|lexra) : ;; *) say 'Архитектура Entware не поддерживается пакетом nfqws v1.'; return 1 ;; esac
    for _nf1_conflict in nfqws2-keenetic tpws-keenetic; do
        if is_installed "$_nf1_conflict"; then
            say "${YELLOW}Установлен несовместимый пакет: $_nf1_conflict. Установка v1 остановлена.${RESET}"
            say 'Сначала сохрани конфигурацию и удали конфликтующий пакет через раздел удаления компонентов.'
            return 1
        fi
    done
    [ ! -L "$_nf1_feed" ] && [ ! -L "$_nf1_conf" ] && [ ! -L "$_nf1_init" ] || { say 'Конфигурация, репозиторий или служба являются симлинком. Установка остановлена.'; return 1; }
    confirm 'Установить / обновить nfqws v1? Пакет автоматически запускает службу.' || return 0
    say '[2/5] Обновление индексов и зависимости'
    opkg update || { say 'Индексы OPKG не обновлены. Установка остановлена.'; return 1; }
    if is_installed wget-nossl; then opkg remove wget-nossl || return 1; fi
    opkg install ca-certificates wget-ssl || { say 'Зависимости не установлены.'; return 1; }
    say '[3/5] Официальный репозиторий nfqws-keenetic'
    backup_file "$_nf1_feed" || return 1
    backup_file "$_nf1_conf" || return 1
    mkdir -p "$(dirname "$_nf1_feed")" || return 1
    _nf1_tmp=$(mktemp "$_nf1_feed.XXXXXX") || return 1
    printf 'src/gz nfqws-keenetic https://nfqws.github.io/nfqws-keenetic/all\n' > "$_nf1_tmp" || return 1
    chmod 644 "$_nf1_tmp" && mv -f "$_nf1_tmp" "$_nf1_feed" || return 1
    _nf1_tmp=''
    say '[4/5] Установка / обновление пакета'
    opkg update || { say 'Официальный репозиторий недоступен. Пакет не изменялся.'; return 1; }
    if is_installed nfqws-keenetic; then
        opkg upgrade nfqws-keenetic || return 1
    else
        opkg install nfqws-keenetic || return 1
    fi
    say '[5/5] Проверка конфигурации и службы'
    [ -f "$_nf1_conf" ] && sh -n "$_nf1_conf" || { say 'Конфигурация не найдена или содержит ошибку синтаксиса.'; return 1; }
    [ -x "$_nf1_init" ] || { say 'Скрипт службы S51nfqws не установлен.'; return 1; }
    if ! "$_nf1_init" status; then
        say "${YELLOW}Пакет установлен, но работа службы не подтверждена. Проверь ISP_INTERFACE и конфигурацию.${RESET}"
        return 1
    fi
    invalidate_component_status_cache
    say "${GREEN}nfqws v1 установлен / обновлён. Служба отвечает.${RESET}"
    say "Конфигурация: $_nf1_conf"
)

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


install_xkeen_ui() {
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
    _dpi_version=$(xmenu_run_version_probe 3 /opt/bin/dpi-detector --version 2>/dev/null | head -n 1)
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
    # Combine the upstream catalog with Xmenu-hosted NFQWS2 configs.
    mkdir -p "$CACHE_DIR/nfqws1" "$CACHE_DIR/nfqws2/additional" "$CACHE_DIR/blobs" "$ROOT_DIR/manifests" || return 1
    _cached_manifest="$ROOT_DIR/manifests/SHA256SUMS"
    _cached_upstream_manifest="$ROOT_DIR/manifests/SHA256SUMS.nfqws-menu"
    _cached_xmenu_manifest="$ROOT_DIR/manifests/SHA256SUMS.xmenu"
    _cached_xmenu_revision="$ROOT_DIR/manifests/XMENU_REVISION"
    _sync_stamp="$ROOT_DIR/strategies-sync.cache"
    _sync_valid_manifest() {
        [ -s "$1" ] && awk '
            length($1)==64 && $1 ~ /^[0-9a-fA-F]+$/ {
                p=substr($0, index($0, $2)); sub(/^\*/, "", p)
                if (p ~ /^strategies\/nfqws[12]\/(additional\/)?[^/]+\.conf$/) ok++
            }
            END {exit(ok ? 0 : 1)}
        ' "$1"
    }
    _sync_valid_xmenu_manifest() {
        [ -s "$1" ] && awk '
            {
                h=substr($0,1,64); p=substr($0,65); sub(/^[[:space:]]+/, "", p); sub(/^\*/, "", p)
                if (h !~ /^[0-9a-fA-F]+$/ || length(h)!=64 || p !~ /^strategies\/nfqws2\/(additional\/)?[A-Za-z0-9_.+ -]+\.conf$/ || p ~ /\.\./) bad++
                else ok++
            }
            END {exit(ok>0 && bad==0 ? 0 : 1)}
        ' "$1"
    }
    _sync_checked=$(sed -n 's/^checked=\([0-9][0-9]*\)$/\1/p' "$_sync_stamp" 2>/dev/null | sed -n '1p')
    _sync_now=$(date +%s 2>/dev/null)
    case "$_sync_checked:$_sync_now" in *[!0-9:]*|:*) _sync_checked= ;; esac
    if [ -n "$_sync_checked" ] && [ -n "$_sync_now" ] && [ "$_sync_now" -ge "$_sync_checked" ] &&
       [ $((_sync_now - _sync_checked)) -lt 3600 ] && _sync_valid_manifest "$_cached_manifest" &&
       grep -qx 'catalog=2' "$_sync_stamp" &&
       _sync_valid_manifest "$_cached_upstream_manifest" && _sync_valid_xmenu_manifest "$_cached_xmenu_manifest"; then
        return 0
    fi

    # Migrate the old combined cache before refreshing into per-source caches.
    if ! _sync_valid_manifest "$_cached_upstream_manifest" &&
       ! _sync_valid_xmenu_manifest "$_cached_xmenu_manifest" &&
       _sync_valid_manifest "$_cached_manifest"; then
        cp "$_cached_manifest" "$_cached_upstream_manifest" || return 1
    fi

    _sync_can_fetch=1
    ensure_base || _sync_can_fetch=0
    _tmp="$ROOT_DIR/sync.$$"
    rm -rf "$_tmp"
    mkdir -p "$_tmp" || return 1
    if [ "$_sync_can_fetch" = 1 ]; then
        if fetch "$NF_REPO/SHA256SUMS" "$_tmp/SHA256SUMS.nfqws-menu" 30 &&
           _sync_valid_manifest "$_tmp/SHA256SUMS.nfqws-menu"; then
            mv -f "$_tmp/SHA256SUMS.nfqws-menu" "$_cached_upstream_manifest" || { rm -rf "$_tmp"; return 1; }
        fi
        _xmenu_strategy_repo=${XMENU_STRATEGY_REPO:-https://raw.githubusercontent.com/rangerxxyy/Xmenu/main}
        _xmenu_revision=''
        if [ -z "${XMENU_STRATEGY_REPO:-}" ]; then
            _xmenu_revision=$(sed -n '1p' "$_cached_xmenu_revision" | tr -d '\r' 2>/dev/null)
            printf '%s\n' "$_xmenu_revision" | LC_ALL=C grep -Eq '^[0-9a-fA-F]{40}$' || _xmenu_revision=''
            if [ -n "$_xmenu_revision" ]; then
                _xmenu_strategy_repo="https://raw.githubusercontent.com/rangerxxyy/Xmenu/$_xmenu_revision"
            fi
            if fetch https://api.github.com/repos/rangerxxyy/Xmenu/commits/main "$_tmp/XMENU-REVISION.json" 30; then
                _xmenu_latest_revision=$(sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([0-9a-fA-F]\{40\}\)".*/\1/p' "$_tmp/XMENU-REVISION.json" | sed -n '1p')
                if printf '%s\n' "$_xmenu_latest_revision" | LC_ALL=C grep -Eq '^[0-9a-fA-F]{40}$'; then
                    _xmenu_revision=$_xmenu_latest_revision
                    _xmenu_strategy_repo="https://raw.githubusercontent.com/rangerxxyy/Xmenu/$_xmenu_revision"
                fi
            fi
        fi
        if fetch "$_xmenu_strategy_repo/strategies/nfqws2/SHA256SUMS" "$_tmp/SHA256SUMS.xmenu" 30 &&
           _sync_valid_xmenu_manifest "$_tmp/SHA256SUMS.xmenu"; then
            mv -f "$_tmp/SHA256SUMS.xmenu" "$_cached_xmenu_manifest" || { rm -rf "$_tmp"; return 1; }
            if [ -n "$_xmenu_revision" ]; then
                printf '%s\n' "$_xmenu_revision" > "$_cached_xmenu_revision.tmp.$$" &&
                    mv -f "$_cached_xmenu_revision.tmp.$$" "$_cached_xmenu_revision" || { rm -rf "$_tmp"; return 1; }
            fi
        fi
    fi
    if ! _sync_valid_manifest "$_cached_upstream_manifest" && ! _sync_valid_xmenu_manifest "$_cached_xmenu_manifest"; then
        rm -rf "$_tmp"
        say "${RED}Нет доступного манифеста стратегий и проверенного офлайн-кэша.${RESET}"
        return 1
    fi
    : > "$_tmp/SHA256SUMS"
    if _sync_valid_manifest "$_cached_upstream_manifest"; then
        cat "$_cached_upstream_manifest" >> "$_tmp/SHA256SUMS" || { rm -rf "$_tmp"; return 1; }
    fi
    if _sync_valid_xmenu_manifest "$_cached_xmenu_manifest"; then
        cat "$_cached_xmenu_manifest" >> "$_tmp/SHA256SUMS" || { rm -rf "$_tmp"; return 1; }
    fi
    if ! _sync_valid_manifest "$_tmp/SHA256SUMS"; then
        rm -rf "$_tmp"
        say "${RED}Объединённый манифест стратегий повреждён.${RESET}"
        return 1
    fi
    mv -f "$_tmp/SHA256SUMS" "$_cached_manifest" || { rm -rf "$_tmp"; return 1; }
    printf 'checked=%s\ncatalog=2\n' "$_sync_now" > "$_sync_stamp.tmp.$$" &&
        mv -f "$_sync_stamp.tmp.$$" "$_sync_stamp" || { rm -rf "$_tmp"; return 1; }
    rm -rf "$_tmp"
    return 0
}

strategy_source_repo() {
    _ssr_rel=$1
    _ssr_manifest="$ROOT_DIR/manifests/SHA256SUMS.xmenu"
    if [ -s "$_ssr_manifest" ]; then
        while IFS= read -r _ssr_entry || [ -n "$_ssr_entry" ]; do
            [ "$(manifest_relpath "$_ssr_entry")" = "$_ssr_rel" ] || continue
            _ssr_repo=${XMENU_STRATEGY_REPO:-}
            if [ -z "$_ssr_repo" ]; then
                _ssr_revision=$(sed -n '1p' "$ROOT_DIR/manifests/XMENU_REVISION" | tr -d '\r' 2>/dev/null)
                printf '%s\n' "$_ssr_revision" | LC_ALL=C grep -Eq '^[0-9a-fA-F]{40}$' || _ssr_revision=''
                _ssr_repo="https://raw.githubusercontent.com/rangerxxyy/Xmenu/${_ssr_revision:-main}"
            fi
            printf '%s\n' "$_ssr_repo"
            return 0
        done < "$_ssr_manifest"
    fi
    printf '%s\n' "$NF_REPO"
}

strategy_valid_name() {
    case "$1" in *..*) return 1 ;; esac
    printf '%s\n' "$1" | LC_ALL=C grep -Eq '^(additional/)?[A-Za-z0-9_.+ -]+\.conf$'
}

strategy_names_from_manifest() {
    _sn_ver=$1
    _sn_manifest="$ROOT_DIR/manifests/SHA256SUMS"
    [ -s "$_sn_manifest" ] || return 1
    LC_ALL=C awk -v ver="$_sn_ver" -v group="${2:-main}" '
        length(substr($0,1,64))==64 && substr($0,1,64) ~ /^[0-9a-fA-F]+$/ {
            rel=substr($0,65); sub(/^[[:space:]]+/, "", rel); sub(/^\*/, "", rel)
            prefix="strategies/nfqws" ver "/"
            if (index(rel,prefix)!=1) next
            name=substr(rel,length(prefix)+1)
            if (name !~ /^(additional\/)?[A-Za-z0-9_.+ -]+\.conf$/ || name ~ /\.\./) next
            if (group == "additional" && index(name,"additional/") != 1) next
            if (group != "additional" && index(name,"/") != 0) next
            print name
        }
    ' "$_sn_manifest" | LC_ALL=C sort -u
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

active_conf_from_paths() {
    _ac_nf2_conf=$1
    _ac_nf1_conf=$2
    if is_installed nfqws2-keenetic && [ -f "$_ac_nf2_conf" ]; then
        printf '%s|%s' "$_ac_nf2_conf" /opt/etc/nfqws2/blobs
    elif is_installed nfqws-keenetic && [ -f "$_ac_nf1_conf" ]; then
        printf '%s|%s' "$_ac_nf1_conf" /opt/etc/nfqws
    elif [ -f "$_ac_nf2_conf" ]; then
        # Конфиг надёжнее списка opkg, который может быть временно недоступен.
        printf '%s|%s' "$_ac_nf2_conf" /opt/etc/nfqws2/blobs
    elif [ -f "$_ac_nf1_conf" ]; then
        printf '%s|%s' "$_ac_nf1_conf" /opt/etc/nfqws
    else return 1; fi
}
active_conf() {
    active_conf_from_paths /opt/etc/nfqws2/nfqws2.conf /opt/etc/nfqws/nfqws.conf
}
normalize_strategy_config() {
    awk -v host1='--hostlist=/opt/etc/nfqws/lists/rkn.list' -v host2='--hostlist=/opt/etc/nfqws2/lists/rkn.list' '
        function boundary(c) {return c=="" || c ~ /[[:space:]"\047]/}
        function strip_host(line, host, rest, result, pos) {
            rest=line; result=""
            while ((pos=index(rest,host)) > 0) {
                result=result substr(rest,1,pos-1)
                rest=substr(rest,pos+length(host))
                if (!boundary(substr(result,length(result),1)) || !boundary(substr(rest,1,1))) result=result host
            }
            return result rest
        }
        {
            sub(/\r$/, "")
            if ($0 ~ /^[[:space:]]*(#|$)/ || $0 ~ /^[[:space:]]*ISP_INTERFACE[[:space:]]*=/) next
            line=strip_host(strip_host($0,host1),host2)
            gsub(/[[:space:]][[:space:]]+/, " ", line)
            gsub(/[[:space:]]*"/, "\"", line)
            sub(/[[:space:]]*$/, "", line)
            print line
        }
    ' "$1"
}

# Удаляем только точный аргумент rkn.list, иначе похожий пользовательский
# путь мог ошибочно сделать кастомный конфиг равным официальной стратегии.
strategy_configs_equal() {
    _sce_current=$1
    _sce_candidate=$2
    [ -f "$_sce_current" ] && [ -f "$_sce_candidate" ] || return 1
    _sce_a="$ROOT_DIR/.strategy-current.$$.tmp"
    _sce_b="$ROOT_DIR/.strategy-candidate.$$.tmp"
    normalize_strategy_config "$_sce_current" > "$_sce_a" || { rm -f "$_sce_a" "$_sce_b"; return 1; }
    normalize_strategy_config "$_sce_candidate" > "$_sce_b" || { rm -f "$_sce_a" "$_sce_b"; return 1; }
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
    for _asl_file in "$CACHE_DIR/nfqws$_asl_ver"/*.conf "$CACHE_DIR/nfqws$_asl_ver"/additional/*.conf; do
        [ -s "$_asl_file" ] || continue
        if strategy_configs_equal "$_asl_conf" "$_asl_file"; then
            _asl_name=${_asl_file#"$CACHE_DIR/nfqws$_asl_ver/"}
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
    rm -f "$ROOT_DIR/strategies-list.$$" "$ROOT_DIR/strategies-priority.$$" "$ROOT_DIR/strategies-other.$$" "$ROOT_DIR/strategies-display.$$" "$ROOT_DIR/strategies-catalog.$$"
    return "$_sms_rc"
}

strategy_menu_session() {
    sync_strategies || { _rc=$?; [ "$_rc" -eq 130 ] && return 130; return 1; }
    _active=$(active_conf) || {
        say 'Конфиг NFQWS не найден. Проверь /opt/etc/nfqws2/nfqws2.conf и /opt/etc/nfqws/nfqws.conf; если файлов нет, сначала установи движок.'
        return 1
    }
    _conf=${_active%%|*}; _default=${_active#*|}
    case "$_conf" in */nfqws2.conf) _ver=2; _dir="$CACHE_DIR/nfqws2";; *) _ver=1; _dir="$CACHE_DIR/nfqws1";; esac
    _list="$ROOT_DIR/strategies-list.$$"
    _priority="$ROOT_DIR/strategies-priority.$$"
    _others="$ROOT_DIR/strategies-other.$$"
    _display="$ROOT_DIR/strategies-display.$$"
    _catalog="$ROOT_DIR/strategies-catalog.$$"
    strategy_names_from_manifest "$_ver" "${XMENU_STRATEGY_GROUP:-main}" > "$_catalog" || :
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
        grep -Fxq -- "$_priority_name" "$_catalog" 2>/dev/null || continue
        grep -Fxq -- "$_priority_name" "$_list" 2>/dev/null || printf '%s\n' "$_priority_name" >> "$_list"
    done < "$_priority"
    : > "$_others"
    while IFS= read -r _candidate || [ -n "$_candidate" ]; do
        [ -n "$_candidate" ] || continue
        grep -Fxq -- "$_candidate" "$_list" 2>/dev/null || printf '%s\n' "$_candidate" >> "$_others"
    done < "$_catalog"
    if [ -s "$_others" ]; then
        LC_ALL=C sort "$_others" >> "$_list"
    fi
    rm -f "$_priority" "$_others" "$_catalog"
    [ -s "$_list" ] || { rm -f "$_list" "$_display"; say 'Список стратегий пуст или манифест недоступен.'; return 1; }

    # Отмечаем выбранную стратегию по маркеру, затем по совпадению конфига.
    _current_strategy=$(sed -n '1{s/\r$//;p;}' "$ROOT_DIR/active-strategy-nfqws$_ver" 2>/dev/null)
    strategy_valid_name "$_current_strategy" || _current_strategy=''
    if [ -z "$_current_strategy" ] || [ ! -f "$_dir/$_current_strategy" ] ||
       ! strategy_configs_equal "$_conf" "$_dir/$_current_strategy"; then
        _current_strategy=''
        for _candidate_file in "$_dir"/*.conf "$_dir"/additional/*.conf; do
            [ -s "$_candidate_file" ] || continue
            if strategy_configs_equal "$_conf" "$_candidate_file"; then
                _current_strategy=${_candidate_file#"$_dir/"}
                break
            fi
        done
    fi
    : > "$_display"
    while IFS= read -r _display_name || [ -n "$_display_name" ]; do
        _display_label=${_display_name#additional/}
        _display_label=${_display_label%.conf}
        if [ "$_display_name" = "$_current_strategy" ]; then
            printf '%s\t%s\n' "$_display_label" '— Активная стратегия ⚡' >> "$_display"
        else
            printf '%s\t%s\n' "$_display_label" '' >> "$_display"
        fi
    done < "$_list"
    _active_label=${_current_strategy#additional/}
    _active_label=${_active_label%.conf}
    line
    if [ "${XMENU_STRATEGY_GROUP:-main}" = additional ]; then
        say "${BRIGHT_CYAN}Дополнительные конфигурации — nfqws$_ver:${RESET}"
    else
        say "${BRIGHT_CYAN}ВЫБОР СТРАТЕГИИ — nfqws$_ver:${RESET}"
    fi
    line
    awk -F '\t' -v active="$_active_label" -v cyan="$BRIGHT_CYAN" -v reset="$RESET" '{
        if ($1 == active) printf "      %2d. %-28s %s— Активная стратегия ⚡%s\n", NR, $1, cyan, reset
        else printf "      %2d. %-28s %s\n", NR, $1, $2
    }' "$_display"
    if [ "$_ver" = 2 ] && [ "${XMENU_STRATEGY_GROUP:-main}" = main ]; then
        menu_item 99 'Дополнительные конфигурации'
    fi
    menu_item 0 'Назад'
    line; _read_or_eof 'Номер стратегии: ' || { rm -f "$_display"; return 0; }; _n=$_read_value
    rm -f "$_display"
    case "$_n" in ''|0) return 0;; *[!0-9]*) say 'Неверный номер.'; return 1;; esac
    if [ "$_n" = 99 ] && [ "$_ver" = 2 ] && [ "${XMENU_STRATEGY_GROUP:-main}" = main ]; then
        (XMENU_STRATEGY_GROUP=additional; strategy_menu_session)
        return $?
    fi
    _name=$(awk -v n="$_n" 'NR==n {print; exit}' "$_list")
    strategy_valid_name "$_name" || { say 'Недопустимое имя стратегии.'; return 1; }
    _rel="strategies/nfqws$_ver/$_name"
    _url_rel=$(printf '%s' "$_rel" | sed 's/ /%20/g')
    _src="$(strategy_source_repo "$_rel")/$_url_rel"; _tmp="$ROOT_DIR/apply-$$.conf"
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
        if mv -f "$_tmp" "$_dir/$_name"; then
            cp "$_dir/$_name" "$ROOT_DIR/apply-$$.conf" || { say 'Не удалось подготовить загруженную стратегию.'; return 1; }
        else
            say 'Не удалось сохранить стратегию в локальный кэш.'
            return 1
        fi
        _tmp="$ROOT_DIR/apply-$$.conf"
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
    strategy_valid_name "$_name" || { say 'Имя активной стратегии некорректно; пропуск.'; return 0; }
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
            strategy_valid_name "$_pre_name" || _pre_name=''
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
xmenu_site_check() (
    if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import ssl' >/dev/null 2>&1; then
        if [ "${XMENU_SITE_DIRECT:-0}" = 1 ]; then
            say 'Прямой режим требует Python 3 с TLS: opkg install python3 python3-ssl'
            return 2
        fi
        say 'Python 3 с TLS недоступен; используется базовая диагностика curl.'
        xmenu_site_check_legacy "$@"
        return $?
    fi
    _site_source=${XMENU_SITE_SOURCE:-$0}
    [ -f "$_site_source" ] || _site_source=$(command -v "$_site_source" 2>/dev/null || :)
    [ -f "$_site_source" ] || _site_source=/opt/bin/xmenu
    _site_mode=normal
    [ "${XMENU_SITE_DIRECT:-0}" != 1 ] || _site_mode=direct
    python3 - "$_site_source" "$_site_mode" "${1:-}" <<'XMENU_SITE_ENGINE'
import argparse
import base64
import errno
import http.client
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import threading
import time
import types
import urllib.parse


def load_engine(source, marker, name):
    code = source.split("<<'" + marker + "'\n", 1)[1].split('\n' + marker, 1)[0]
    module = types.ModuleType(name)
    sys.modules[name] = module
    exec(compile(code, '<' + name + '>', 'exec'), module.__dict__)
    return module


def parse_url(value):
    value = value.strip()
    if not value or len(value) > 4096 or any(ord(c) < 33 or ord(c) == 127 for c in value):
        raise ValueError('Введите домен, IP или HTTP/HTTPS URL без пробелов.')
    if '://' not in value:
        try:
            address = ipaddress.ip_address(value.strip('[]'))
            value = '[' + str(address) + ']' if address.version == 6 else str(address)
        except ValueError:
            pass
        value = 'https://' + value
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme not in ('http', 'https') or parsed.username is not None or parsed.password is not None or not parsed.hostname:
        raise ValueError('Допустимы HTTP/HTTPS без учётных данных в URL.')
    host = parsed.hostname.encode('idna').decode('ascii').lower()
    try:
        host = str(ipaddress.ip_address(host))
    except ValueError:
        if len(host) > 253 or any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label) for label in host.split('.')):
            raise ValueError('Некорректное имя сайта.')
    port = parsed.port if parsed.port is not None else (443 if parsed.scheme == 'https' else 80)
    if not 1 <= port <= 65535:
        raise ValueError('Порт должен быть от 1 до 65535.')
    authority = '[' + host + ']' if ':' in host else host
    if port != (443 if parsed.scheme == 'https' else 80):
        authority += ':' + str(port)
    path = urllib.parse.quote(parsed.path or '/', safe="/%:@!$&'()*+,;=-._~")
    query = urllib.parse.quote(parsed.query, safe="%/?@!$&'()*+,;=:-._~")
    return urllib.parse.urlunsplit((parsed.scheme, authority, path, query, '')), host, port


def resolve(host, transport):
    try:
        return [str(ipaddress.ip_address(host))], 0.0, None
    except ValueError:
        pass
    started = time.monotonic()
    program = 'import socket,json,sys,time; t=time.monotonic(); a=sorted({v[4][0] for v in socket.getaddrinfo(sys.argv[1],None,0,socket.SOCK_STREAM)}); print(json.dumps({"ips":a,"ms":(time.monotonic()-t)*1000}))'
    try:
        result = subprocess.run([sys.executable, '-c', program, host], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=transport.remaining(4))
        if result.returncode:
            return [], (time.monotonic() - started) * 1000, 'DNS не вернул адрес'
        values = json.loads(result.stdout)
        return [str(ipaddress.ip_address(v)) for v in values['ips']][:32], values['ms'], None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return [], (time.monotonic() - started) * 1000, 'DNS: ошибка или тайм-аут'


def direct_path(ip, transport):
    transport.public_target(ip)
    path = transport.detect_path(ip)
    transport.BYPASS_MARK = path['mark']
    transport.inspect_route(ip, path)
    if not path['direct_ready']:
        reason = '; '.join(path.get('risks', []) + path.get('inspection_errors', []))
        raise OSError(errno.ENOTSUP, 'Прямой WAN не подтверждён' + (': ' + reason if reason else ''))
    return path


def request(url, ip, transport, direct=False, accept='*/*', read_limit=16384):
    normalized, host, port = parse_url(url)
    parsed = urllib.parse.urlsplit(normalized)
    data = {'url': normalized, 'ip': ip, 'tcp_ms': None, 'tls_ms': None, 'first_ms': None, 'body_ms': None, 'http': None, 'status': 'ERROR', 'stage': 'Маршрут'}
    sock = guard = response = timer = None
    timed_out = threading.Event()
    try:
        if direct:
            data['path'] = direct_path(ip, transport)
        data['stage'] = 'TCP'
        sock, data['tcp_ms'], guard = transport.connect(ip, port, 3)
        if direct and ipaddress.ip_address(sock.getsockname()[0]) != ipaddress.ip_address(data['path']['source']):
            raise OSError(errno.ENOTSUP, 'Исходный адрес не совпал с подтверждённым WAN-маршрутом')
        deadline = min(transport.END_TIME, time.monotonic() + 7)
        def timeout():
            timed_out.set()
            if sock:
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
        timer = threading.Timer(max(.001, deadline - time.monotonic()), timeout)
        timer.daemon = True
        timer.start()
        sock.settimeout(transport.remaining(3))
        if parsed.scheme == 'https':
            data['stage'] = 'TLS'
            context = ssl.create_default_context()
            started = time.monotonic()
            sock = context.wrap_socket(sock, server_hostname=host)
            with transport.SOCKET_LOCK:
                transport.ACTIVE_SOCKETS.add(sock)
            data['tls_ms'] = (time.monotonic() - started) * 1000
            data['tls_version'] = sock.version()
            certificate = sock.getpeercert()
            data['cert_expires'] = certificate.get('notAfter')
        data['stage'] = 'HTTP'
        target = urllib.parse.urlunsplit(('', '', parsed.path or '/', parsed.query, ''))
        headers = 'GET ' + target + ' HTTP/1.1\r\nHost: ' + parsed.netloc + '\r\nUser-Agent: Xmenu/1.4.4\r\nAccept: ' + accept + '\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n'
        sock.settimeout(transport.remaining(min(3, max(.001, deadline - time.monotonic()))))
        started = time.monotonic()
        sock.sendall(headers.encode('ascii'))
        response = http.client.HTTPResponse(sock, method='GET')
        if not response.fp.peek(1):
            raise http.client.RemoteDisconnected('Сервер закрыл соединение без HTTP-ответа')
        data['first_ms'] = (time.monotonic() - started) * 1000
        response.begin()
        if timed_out.is_set() or transport.CANCEL.is_set():
            raise TimeoutError('Ожидание HTTP-заголовков прервано по лимиту')
        data['http'] = response.status
        data['location'] = response.getheader('Location')
        data['content_type'] = response.getheader('Content-Type', '')[:120]
        data['status'] = 'HTTP'
        if response.status in (301, 302, 303, 307, 308):
            return data
        data['stage'] = 'Чтение'
        started = time.monotonic()
        try:
            body = response.read(read_limit + 1)
            data['body_ms'] = (time.monotonic() - started) * 1000
            data['bytes'] = min(len(body), read_limit)
            data['limited'] = len(body) > read_limit
            data['body'] = body[:read_limit]
            if timed_out.is_set() or transport.CANCEL.is_set():
                data.update(status='BODY ERROR', error='Чтение ответа прервано по лимиту времени')
            elif not data['limited'] and response.length is not None and response.length > 0:
                data.update(status='BODY ERROR', error='Сервер закрыл ответ раньше объявленного Content-Length')
            else:
                data['status'] = 'OK'
        except (OSError, http.client.HTTPException) as exc:
            data['status'] = 'BODY ERROR'
            data['error'] = transport.clean(str(exc))
        return data
    except ssl.SSLCertVerificationError as exc:
        data.update(status='CERT ERROR', error=transport.clean(exc.verify_message))
    except ssl.SSLError as exc:
        data.update(status='TLS ERROR', error=transport.clean(str(exc)))
    except (OSError, ValueError, http.client.HTTPException) as exc:
        code = getattr(exc, 'errno', None)
        status = 'TIMEOUT' if isinstance(exc, TimeoutError) else 'RESET' if code == errno.ECONNRESET else 'REFUSED' if code == errno.ECONNREFUSED else 'NO ROUTE' if code in (errno.ENETUNREACH, errno.EHOSTUNREACH) else 'CANCELLED' if code == errno.ECANCELED else 'ERROR'
        data.update(status=status, error=transport.clean(str(exc)))
    finally:
        if timer:
            timer.cancel()
        if response:
            response.close()
        if sock:
            sock.close()
        if guard:
            guard.close()
    return data


def reference_dns(host, transport, dns, direct, qtype=1):
    packet = dns.query(host, qtype)
    value = base64.urlsafe_b64encode(packet).rstrip(b'=').decode('ascii')
    for endpoint, ip in (('cloudflare-dns.com', '1.1.1.1'), ('dns.google', '8.8.8.8')):
        result = request('https://' + endpoint + '/dns-query?dns=' + value, ip, transport, direct, 'application/dns-message', 65535)
        if result['status'] != 'OK' or result.get('http') != 200:
            continue
        try:
            answer = dns.parse(result['body'], packet)
            if answer['tc'] or answer['rcode'] not in (0, 3):
                continue
            return answer['ips'], 'DoH: NXDOMAIN' if answer['rcode'] == 3 else 'DoH: адрес получен' if answer['ips'] else 'DoH: записей этой версии IP нет'
        except ValueError:
            continue
    return [], 'Контрольный DoH недоступен или вернул некорректный ответ'


def friendly_result(item):
    code, status = item.get('http'), item['status']
    if status == 'BODY ERROR':
        return 'Загрузка прервалась', '31;1'
    if code:
        if 200 <= code < 300:
            return 'Открывается', '32;1'
        if code in (301, 302, 303, 307, 308):
            return 'Переход на другую страницу', '33'
        if code in (401, 403):
            return 'Доступ ограничен сайтом', '33'
        if code in (404, 410):
            return 'Страница не найдена', '33'
        if code == 429:
            return 'Сайт просит повторить позже', '33'
        return 'Ошибка на стороне сайта' if code >= 500 else 'Необычный ответ сайта', '31;1'
    if item['stage'] == 'Маршрут':
        return 'Прямой путь не подтверждён', '33'
    if status == 'CERT ERROR':
        return 'Ошибка сертификата сайта', '31;1'
    if status == 'NO ROUTE':
        return 'Нет маршрута к адресу', '33'
    if item['stage'] == 'TLS':
        return 'Не удалось защитить соединение', '31;1'
    return {'TIMEOUT': 'Сайт не отвечает', 'RESET': 'Соединение сброшено', 'REFUSED': 'Соединение отклонено', 'CANCELLED': 'Не хватило времени'}.get(status, 'Ответ не получен'), '31;1'


def show_rows(rows, transport):
    columns = max(74, min(120, shutil.get_terminal_size((110, 24)).columns))
    values = []
    last_step = None
    for item in rows:
        step = item.get('step', '')
        if step != last_step:
            values.append(([step, '', '', '', ''] if columns >= 100 else [step, '', '', ''], ['36;1'] * (5 if columns >= 100 else 4)))
            last_step = step
        outcome, color = friendly_result(item)
        timing = lambda key: ('<0.1 мс' if item[key] < .1 else f"{item[key]:.1f} мс") if item.get(key) is not None else None
        dns_value = 'IP задан' if item.get('literal') else f"{item.get('dns_ms', 0):.0f} мс"
        tcp_value = timing('tcp_ms') or ('Не провер.' if item['stage'] == 'Маршрут' else 'Нет пути' if item['status'] == 'NO ROUTE' else 'Отказ' if item['status'] == 'REFUSED' else 'Нет ответа')
        tls_value = timing('tls_ms') or ('Не нужен' if item['url'].startswith('http:') else 'Серт. неверен' if item['status'] == 'CERT ERROR' else 'Нет ответа' if item['stage'] == 'TLS' else 'Не проверен')
        if item.get('tls_ms') is not None and item.get('tls_version'):
            tls_value = item['tls_version'].replace('TLSv', 'TLS') + f" {item['tls_ms']:.1f} мс"
        http_value = ('HTTP ' + str(item['http']) + (' · обрыв' if item['status'] == 'BODY ERROR' else (f" · {item['first_ms']:.0f} мс" if item.get('first_ms') is not None else ''))) if item.get('http') else 'Нет ответа' if item['stage'] == 'HTTP' else 'Не проверен'
        if item.get('stage') == 'Маршрут':
            http_value = 'Обход не подтверждён'
        tcp_color = '32' if item.get('tcp_ms') is not None else '33' if item['stage'] == 'Маршрут' else '31;1'
        tls_color = '32' if item.get('tls_ms') is not None else '90' if tls_value in ('Не нужен', 'Не проверен') else '31;1'
        if columns >= 100:
            values.append(([item['ip'], dns_value, tcp_value, tls_value, http_value], ['36', '37', tcp_color, tls_color, color]))
        else:
            values.append(([item['ip'], dns_value, tcp_value + ' / ' + tls_value, http_value], ['36', '37', color, color]))
    if columns >= 100:
        address_width = min(39, columns - 71)
        transport.table(['Сайт / IP', 'DNS', 'TCP', 'TLS', 'HTTP / ответ'], values, [address_width, 7, 10, 15, columns - address_width - 48], compact=True)
    else:
        address_width = max(20, columns - 54)
        transport.table(['Сайт / IP', 'DNS', 'TCP / TLS', 'HTTP / ответ'], values, [address_width, 7, 18, columns - address_width - 38], compact=True)


def diagnose(value, transport, dns, direct=False):
    original, host, port = parse_url(value)
    transport.CANCEL.clear()
    transport.END_TIME = time.monotonic() + 50
    started = time.monotonic()
    watchdog = threading.Timer(50, transport.stop_probes)
    watchdog.daemon = True
    watchdog.start()
    all_rows, chain, visited = [], [], set()
    current = original
    final = None
    dns_fallback = False
    issue = None
    print('\n' + transport.paint('Проверка сайта: ' + host))
    print('Подключение: ' + transport.paint('напрямую, в обход XKeen/nfqws2' if direct else 'через текущие настройки роутера', '33' if direct else '36'))
    try:
        for hop in range(6):
            current, name, current_port = parse_url(current)
            if current in visited:
                issue = 'Цикл перенаправлений: сайт возвращает на уже проверенный URL.'
                break
            visited.add(current)
            try:
                ipaddress.ip_address(name)
                literal = True
            except ValueError:
                literal = False
            if direct and not literal:
                lookup_started = time.monotonic()
                addresses, note = reference_dns(name, transport, dns, True, 1)
                ipv6, note6 = reference_dns(name, transport, dns, True, 28)
                addresses += ipv6
                lookup_ms = (time.monotonic() - lookup_started) * 1000
                lookup_error = None if addresses else note + '; ' + note6
            else:
                addresses, lookup_ms, lookup_error = resolve(name, transport)
            if lookup_error:
                if direct:
                    issue = 'Не удалось получить адрес сайта через прямое подключение.'
                    break
                ips, note = reference_dns(name, transport, dns, direct, 1)
                ipv6, note6 = reference_dns(name, transport, dns, direct, 28)
                ips += ipv6
                if not ips:
                    issue = 'Не удалось найти адрес сайта. Проверьте домен и настройки DNS.'
                    break
                addresses = ips
                dns_fallback = True
            selected = []
            try:
                versions = (ipaddress.ip_address(name).version,)
            except ValueError:
                versions = (4, 6)
            for version in versions:
                choices = [ip for ip in addresses if ipaddress.ip_address(ip).version == version][:2]
                selected += choices
            results = []
            for ip in selected:
                item = request(current, ip, transport, direct)
                item.update(step=str(hop + 1) + '. ' + name, dns_ms=lookup_ms, literal=literal)
                results.append(item)
                if transport.CANCEL.is_set():
                    break
            all_rows.extend(results)
            good = [item for item in results if item.get('http')]
            if not good:
                issue = None
                if results and all(item['stage'] == 'Маршрут' for item in results):
                    issue = 'Проверка напрямую не выполнена: маршрут через WAN не подтверждён.'
                elif any(item['status'] == 'CERT ERROR' for item in results):
                    issue = 'Не удалось проверить сертификат сайта. Проверьте дату роутера.'
                elif any(item['stage'] == 'TLS' for item in results):
                    issue = 'TCP-соединение установлено, но TLS не завершён.'
                elif any(item['stage'] == 'HTTP' for item in results):
                    issue = 'Соединение установлено, но HTTP-ответ от сайта не получен.'
                else:
                    issue = 'Сайт не ответил на подключение с роутера.'
                break
            priority = lambda item: 0 if item['status'] == 'OK' and 200 <= item['http'] < 300 else 1 if item['http'] in (301, 302, 303, 307, 308) and item.get('location') else 2 if item['status'] == 'OK' else 3
            final = min(good, key=priority)
            if final['http'] not in (301, 302, 303, 307, 308):
                break
            location = final.get('location')
            if not location:
                issue = 'Сайт перенаправляет запрос, но не сообщает адрес новой страницы.'
                break
            try:
                next_url, _, _ = parse_url(urllib.parse.urljoin(current, location))
            except ValueError as exc:
                issue = 'Недопустимое перенаправление: ' + str(exc)
                break
            chain.append((final['http'], next_url))
            if current.startswith('https:') and next_url.startswith('http:'):
                print(transport.paint('Переход HTTPS → HTTP: следующий участок без шифрования.', '33'))
            if hop == 5:
                issue = 'Лимит: 5 переходов. Конечная страница не проверена.'
                break
            current = next_url
    finally:
        watchdog.cancel()
        transport.cleanup_flows()
    if all_rows:
        print()
        show_rows(all_rows, transport)
    print()
    confirmation = ' → '.join('HTTP ' + str(code) for code in [entry[0] for entry in chain] + ([final['http']] if final and not issue else []))
    if issue:
        not_checked = issue.startswith('Проверка напрямую не выполнена') or (direct and not all_rows)
        print(transport.paint('Проверка не выполнена' if not_checked else 'Сайт не открывается', '33;1' if not_checked else '31;1'))
        print(issue)
    elif final and final['status'] == 'OK' and 200 <= final['http'] < 300:
        if dns_fallback:
            print(transport.paint('Сайт открывается через резервный DNS — ' + confirmation, '33;1'))
            print('Проверьте обычный DNS роутера: он не смог найти адрес сайта.')
        else:
            print(transport.paint('Сайт открывается' + (' напрямую' if direct else '') + ' — ' + confirmation, '32;1'))
    elif final:
        code = final['http']
        detail = 'Требуется вход или сервер ограничил доступ.' if code in (401, 403) else 'Страница не найдена.' if code in (404, 410) else 'Сервер ограничил частоту запросов.' if code == 429 else 'Ошибка сервера.' if code >= 500 else 'Ответ получен, но успешная загрузка не подтверждена.'
        print(transport.paint(('Сайт доступен, страница не найдена' if code in (404, 410) else 'Сайт не открывается') + ' — ' + confirmation, '33;1' if code in (404, 410) else '31;1'))
        print('Загрузка ответа прервалась.' if final['status'] == 'BODY ERROR' else detail)
    failures = [item for item in all_rows if item.get('http') is None]
    if failures and not issue and final and final['status'] == 'OK' and 200 <= final['http'] < 300:
        print(transport.paint('Один из адресов сайта недоступен, другой отвечает.', '33'))
    if transport.CANCEL.is_set():
        print(transport.paint('Время проверки истекло; часть адресов не проверена.', '33'))
    if transport.FLOW_RULES:
        print(transport.paint('Внимание: не все временные исключения удалены.', '31;1'))
    if not direct and any(item.get('tcp_ms') is not None and item['tcp_ms'] < 1 for item in all_rows):
        print('TCP — время подключения, не ping. Через локальный прокси оно может быть меньше 1 мс.')
    print(transport.paint(f'Проверка заняла {time.monotonic() - started:.1f} с.', '90'))
    return 0 if not issue and not dns_fallback and not transport.CANCEL.is_set() and not transport.FLOW_RULES and final and final['status'] == 'OK' and 200 <= final['http'] < 300 else 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('source')
    parser.add_argument('mode', choices=('normal', 'direct'))
    parser.add_argument('target')
    args = parser.parse_args()
    source = Path(args.source).read_text(encoding='utf-8')
    transport = load_engine(source, 'XMENU_SERVER_ENGINE', 'xmenu_site_transport')
    dns = load_engine(source, 'XMENU_DNS_ENGINE', 'xmenu_site_dns')
    def cancel(signum, frame):
        transport.stop_probes()
        raise KeyboardInterrupt
    signal.signal(signal.SIGINT, cancel)
    signal.signal(signal.SIGTERM, cancel)
    try:
        return diagnose(args.target, transport, dns, args.mode == 'direct')
    finally:
        transport.cleanup_flows()


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('\nПроверка отменена.')
        sys.exit(130)
    except (OSError, ValueError, IndexError) as exc:
        print('Ошибка: ' + str(exc), file=sys.stderr)
        sys.exit(2)

XMENU_SITE_ENGINE
)


xmenu_site_check_legacy() (
    _site_input=${1:-}
    case "$_site_input" in
        *[!0-9A-Fa-f:]*|'') : ;;
        *:*:*) _site_input="[$_site_input]" ;;
    esac
    case "$_site_input" in
        http://*|https://*) _site_url=$_site_input ;;
        *://*) say 'Допустимы только http:// и https://'; return 2 ;;
        *) _site_url="https://$_site_input" ;;
    esac
    if ! printf '%s\n' "$_site_url" | LC_ALL=C grep -Eq '^https?://[][A-Za-z0-9._~:/?#%+=&-]+$'; then
        say 'Введите домен или HTTP/HTTPS URL без пробелов и учётных данных.'; return 2
    fi
    _site_authority=${_site_url#*://}; _site_authority=${_site_authority%%[/?#]*}
    _site_host=$_site_authority; _site_port=443; _site_secure=1
    case "$_site_url" in http://*) _site_port=80; _site_secure=0 ;; esac
    case "$_site_authority" in
        \[*\]*)
            _site_host=${_site_authority#\[}; _site_host=${_site_host%%\]*}
            _site_tail=${_site_authority#*\]}
            case "$_site_tail" in '') : ;; :*) _site_port=${_site_tail#:} ;; *) return 2 ;; esac
            printf '%s\n' "$_site_host" | grep -Eq '^[0-9A-Fa-f:]+$' || return 2 ;;
        *:*) _site_host=${_site_authority%%:*}; _site_port=${_site_authority#*:} ;;
    esac
    [ -n "$_site_host" ] || { say 'Не указан адрес сайта.'; return 2; }
    case "$_site_port" in ''|*[!0-9]*) say 'Некорректный порт.'; return 2 ;; esac
    [ "${#_site_port}" -le 5 ] && [ "$_site_port" -ge 1 ] && [ "$_site_port" -le 65535 ] || { say 'Порт должен быть от 1 до 65535.'; return 2; }
    case "$_site_host" in
        *:*) : ;;
        *) printf '%s\n' "$_site_host" | LC_ALL=C awk '
            length($0)>253 {exit 1}
            {n=split($0,a,"."); for(i=1;i<=n;i++) if(length(a[i])<1 || length(a[i])>63 || a[i]!~/^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$/) exit 1}' || { say 'Некорректное имя сайта.'; return 2; } ;;
    esac
    command -v curl >/dev/null 2>&1 || { say 'Для диагностики нужен curl: opkg install curl ca-bundle'; return 2; }
    umask 077
    _site_tmp=$(mktemp -d /tmp/xmenu-site-XXXXXX) || return 2
    trap 'rm -rf "$_site_tmp"' EXIT
    trap 'exit 130' INT TERM HUP
    line
    say "${CYAN}Диагностика сайта: $_site_host (порт $_site_port)${RESET}"
    say 'Проверяю DNS → TCP → TLS → HTTP. Ожидание — до 15 секунд.'
    _site_rc=0
    curl -q --noproxy '*' --proto '=http,https' --globoff --connect-timeout 8 --max-time 15 --retry 0 \
        --head --silent --show-error --output /dev/null --url "$_site_url" \
        --write-out 'code=%{http_code}\nip=%{remote_ip}\ndns=%{time_namelookup}\ntcp=%{time_connect}\ntls=%{time_appconnect}\ntotal=%{time_total}\n' \
        > "$_site_tmp/metrics" 2> "$_site_tmp/error" || _site_rc=$?
    _site_code=$(sed -n 's/^code=//p' "$_site_tmp/metrics")
    _site_ip=$(sed -n 's/^ip=//p' "$_site_tmp/metrics")
    _site_dns=$(sed -n 's/^dns=//p' "$_site_tmp/metrics")
    _site_tcp=$(sed -n 's/^tcp=//p' "$_site_tmp/metrics")
    _site_tls=$(sed -n 's/^tls=//p' "$_site_tmp/metrics")
    _site_dns_ok=0; _site_tcp_ok=0; _site_tls_ok=0; _site_http_ok=0
    awk -v n="$_site_dns" 'BEGIN {exit !(n+0>0)}' && _site_dns_ok=1
    awk -v n="$_site_tcp" 'BEGIN {exit !(n+0>0)}' && _site_tcp_ok=1
    awk -v n="$_site_tls" 'BEGIN {exit !(n+0>0)}' && _site_tls_ok=1
    case "$_site_code" in [1-5][0-9][0-9]) _site_http_ok=1; _site_tcp_ok=1; [ "$_site_secure" = 0 ] || _site_tls_ok=1 ;; esac
    case "$_site_rc" in 35|51|58|59|60|64|77) _site_tls_ok=0 ;; esac
    _site_result=1
    _site_literal=0
    case "$_site_host" in *:*) _site_literal=1 ;; *[!0-9.]*) : ;; *) _site_literal=1 ;; esac
    if [ "$_site_literal" = 1 ]; then
        say '[1/4] DNS: пропущен — указан IP-адрес.'
        _site_summary='Проверка соединения по IP-адресу не завершена.'
    elif [ "$_site_rc" = 6 ]; then
        say "${RED}[1/4] DNS: имя сайта не найдено.${RESET}"
        _site_summary='Не удалось получить IP-адрес. Проверьте написание домена и доступность вашего DNS.'
    elif [ -n "$_site_ip" ] || [ "$_site_tcp_ok" = 1 ] || [ "$_site_dns_ok" = 1 ] || [ "$_site_rc" = 7 ]; then
        say "${GREEN}[1/4] DNS / адрес назначения: ${_site_ip:-$_site_host}${RESET}"
        _site_summary='Адрес получен, но соединение не завершено.'
    else
        say "${YELLOW}[1/4] DNS: результат не подтверждён.${RESET}"
        _site_summary='Проверка не завершена. Возможна задержка DNS или ошибка инструмента.'
    fi
    if [ "$_site_tcp_ok" = 1 ]; then
        say "${GREEN}[2/4] TCP: соединение установлено.${RESET}"
    elif [ "$_site_rc" = 6 ] || { [ "$_site_dns_ok" = 0 ] && [ -z "$_site_ip" ] && [ "$_site_rc" != 7 ]; }; then
        say '[2/4] TCP: результат не подтверждён.'
    else
        say "${RED}[2/4] TCP: соединение не установлено.${RESET}"
        [ "$_site_rc" = 6 ] || _site_summary='Нет TCP-соединения. Проверьте доступность сайта, порт, маршрут и правила сети.'
    fi
    if [ "$_site_secure" = 0 ]; then
        say '[3/4] TLS: не используется для HTTP.'
    elif [ "$_site_tls_ok" = 1 ]; then
        say "${GREEN}[3/4] TLS: защищённое соединение установлено, сертификат проверен.${RESET}"
    elif [ "$_site_tcp_ok" = 1 ]; then
        say "${RED}[3/4] TLS: защищённое соединение не установлено.${RESET}"
        _site_summary='TCP работает, но TLS не завершён. Возможны ошибка сертификата, неверное время роутера или обрыв соединения.'
    else
        say '[3/4] TLS: не проверен — нет TCP-соединения.'
    fi
    if [ "$_site_http_ok" = 1 ]; then
        say "${CYAN}[4/4] HTTP: ответ $_site_code${RESET}"
        case "$_site_code" in
            2??) _site_summary='Все необходимые этапы пройдены. Сервер отвечает на запрос с роутера.'; _site_result=0 ;;
            3??) _site_summary='Сервер доступен и перенаправляет запрос. Конечная страница перенаправления не проверялась.'; _site_result=0 ;;
            401|403) _site_summary='Сеть и соединение работают. Сервер ограничил доступ: возможны авторизация или защита от автоматических запросов.' ;;
            404|410) _site_summary='Сервер доступен, но запрошенная страница не найдена.' ;;
            405|501) _site_summary='Сервер доступен, но не поддерживает диагностический HEAD-запрос. Открытие страницы в браузере требует отдельной проверки.' ;;
            429) _site_summary='Сервер доступен, но ограничивает частоту запросов. Повторите позже.' ;;
            5??) _site_summary='Соединение работает. Ошибку вернул сервер или промежуточный узел.' ;;
            *) _site_summary='Сервер доступен, но вернул ошибку HTTP. Проверьте адрес страницы.' ;;
        esac
    else
        say '[4/4] HTTP: ответ не получен.'
        if [ "$_site_tls_ok" = 1 ] || { [ "$_site_secure" = 0 ] && [ "$_site_tcp_ok" = 1 ]; }; then
            _site_summary='Соединение установлено, но HTTP-ответ не получен. Возможны ожидание сервера или обрыв передачи.'
        fi
    fi
    case "$_site_rc" in
        1|2|3|4) _site_summary='curl не смог выполнить проверку. Проверьте URL и поддержку HTTPS установленной версией curl.' ;;
        60|51) _site_summary='Не прошла проверка сертификата TLS. Проверьте дату роутера, сертификат сайта и пакет ca-bundle.' ;;
        77) _site_summary='curl не смог прочитать хранилище сертификатов. Проверьте установку ca-bundle.' ;;
    esac
    line
    say "${CYAN}Итог${RESET}"
    say "$_site_summary"
    _site_total=$(sed -n 's/^total=//p' "$_site_tmp/metrics")
    awk -v d="$_site_dns" -v c="$_site_tcp" -v t="$_site_tls" -v total="$_site_total" '
        BEGIN {
            if(d+0>0) printf "DNS: %.0f мс",d*1000; else printf "DNS: —"
            if(c+0>0) printf " · TCP: %.0f мс",(c-d)*1000
            if(t+0>0) printf " · TLS: %.0f мс",(t-c)*1000
            if(total+0>0) printf " · Всего: %.2f с",total
            printf "\n"
        }'
    [ "$_site_rc" != 28 ] || say 'Достигнут лимит ожидания. Сам по себе тайм-аут не доказывает блокировку.'
    case "$_site_host" in *:*) say 'Проверяется указанный IPv6-адрес. Для соединения нужен рабочий IPv6-маршрут.' ;; esac
    say 'Проверка идёт с роутера. Работа браузера и загрузка всей страницы могут отличаться.'
    return "$_site_result"
)

xmenu_site_batch() (
    if [ "$#" -lt 1 ] || [ "$#" -gt 5 ]; then
        say 'Введите от 1 до 5 доменов или URL.'; return 2
    fi
    _batch_total=$#; _batch_index=0; _batch_failed=0
    for _batch_target do
        _batch_index=$((_batch_index + 1))
        [ "$_batch_total" -le 1 ] || say "${CYAN}Сайт $_batch_index из $_batch_total${RESET}"
        _site_failed=0
        if [ "${XMENU_SITE_DIRECT:-0}" = 1 ]; then
            xmenu_site_check "$_batch_target" || _site_failed=1
        else
            say "${CYAN}Тест 1/2 — обычное подключение${RESET}"
            (XMENU_SITE_DIRECT=0; xmenu_site_check "$_batch_target") || _site_failed=1
            say ''
            say "${CYAN}Тест 2/2 — принудительно напрямую${RESET}"
            (XMENU_SITE_DIRECT=1; xmenu_site_check "$_batch_target") || _site_failed=1
        fi
        [ "$_site_failed" = 0 ] || _batch_failed=$((_batch_failed + 1))
        say ''
    done
    if [ "$_batch_total" -gt 1 ]; then
        line
        say "Без замечаний: $((_batch_total - _batch_failed)) из $_batch_total. Требуют внимания: $_batch_failed."
    fi
    [ "$_batch_failed" = 0 ]
)

xmenu_site_input_batch() (
    _batch_input=$1
    set -f
    _batch_input=$(printf '%s' "$_batch_input" | tr ',' ' ')
    # shellcheck disable=SC2086
    set -- $_batch_input
    xmenu_site_batch "$@"
)

xmenu_dns_diagnose() {
    command -v python3 >/dev/null 2>&1 || {
        say 'Нужен Python 3 с TLS: opkg install python3 python3-ssl'
        return 2
    }
    command -v curl >/dev/null 2>&1 || { say 'Нужен curl: opkg install curl ca-bundle'; return 2; }
    python3 - "$@" <<'XMENU_DNS_ENGINE'
import argparse
import base64
import concurrent.futures
import ctypes
import ctypes.util
import errno
import ipaddress
import json
import os
import random
import secrets
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import time
import threading
import unicodedata
import urllib.parse
from dataclasses import dataclass, replace


PRESETS = '''Google|8.8.4.4|dns.google|https://dns.google/dns-query|1
Google #2|8.8.8.8|8.8.8.8||1
Google #3||8.8.4.4||0
Cloudflare|||https://cloudflare-dns.com/dns-query|0
Cloudflare IP|1.1.1.1|1.1.1.1|https://1.1.1.1/dns-query|1
Cloudflare IP 2|1.0.0.1|1.0.0.1|https://1.0.0.1/dns-query|1
Quad9|9.9.9.9|dns.quad9.net|https://dns.quad9.net/dns-query|1
Quad9 #2|149.112.112.112|||1
AdGuard|94.140.14.14|dns.adguard-dns.com|https://dns.adguard-dns.com/dns-query|1
AdGuard #2|94.140.15.15|||1
НСДИ|195.208.4.1|||1
НСДИ #2|195.208.5.1|||1
AdGuard (F)|94.140.14.15|family.adguard-dns.com|https://family.adguard-dns.com/dns-query|1
AdGuard (L)||dns.adguard.com|https://dns.adguard.com/dns-query|0
AdGuard (UN)|94.140.14.140|unfiltered.adguard-dns.com|https://unfiltered.adguard-dns.com/dns-query|1
Alibaba|223.5.5.5|dns.alidns.com|https://dns.alidns.com/dns-query|1
Alibaba #2|223.6.6.6|||1
CleanBrowsing|185.228.168.9|security-filter-dns.cleanbrowsing.org|https://doh.cleanbrowsing.org/doh/security-filter|1
CleanBrowsing #2|185.228.169.9|||1
Cloudflare (M)|||https://mozilla.cloudflare-dns.com/dns-query|0
Cloudflare (S)||security.cloudflare-dns.com|https://security.cloudflare-dns.com/dns-query|0
Cloudflare dns|||https://dns.cloudflare.com/dns-query|0
Cloudflare dot||1dot1dot1dot1.cloudflare-dns.com|https://1dot1dot1dot1.cloudflare-dns.com/dns-query|0
Cloudflare one||one.one.one.one|https://one.one.one.one/dns-query|0
Comodo|8.26.56.26|||1
Comodo 2|8.20.247.20|||1
Comss.one|83.220.169.155|dns.comss.one|https://dns.comss.one/dns-query|1
Comss.one #2|212.109.195.93||https://doh.comss.one/dns-query|1
ControlD|76.76.2.11|freedns.controld.com|https://freedns.controld.com/p0|1
ControlD #2|76.76.10.11|||1
DNS Watch|84.200.69.80|||1
DNS Watch 2|84.200.70.40|||1
DNS.SB|185.222.222.222|dot.sb|https://dns.sb/dns-query|1
DNS.SB #2|45.11.45.11|||1
DNS4all|194.0.5.3|dot.dns4all.eu|https://doh.dns4all.eu/dns-query|1
dnsforge|176.9.93.198|dnsforge.de|https://dnsforge.de/dns-query|1
First Colo|212.224.71.71|||1
First Colo #2|79.133.62.62|||1
Geohide|45.155.204.190|dns.geohide.ru|https://dns.geohide.ru:444/dns-query|1
Gesellschaft||dns.digitale-gesellschaft.ch|https://dns.digitale-gesellschaft.ch/dns-query|0
Level 3|209.244.0.3|||1
Level 3 #2|209.244.0.4|||1
Level 3 #3|4.2.2.1|||1
Level 3 #4|4.2.2.2|||1
LibreDNS||dot.libredns.gr|https://doh.libredns.gr/dns-query|0
MSK-IX|62.76.62.76|||1
MSK-IX #2|62.76.76.62|||1
Mullvad||dns.mullvad.net|https://dns.mullvad.net/dns-query|0
NextDNS|45.90.28.0|dns.nextdns.io|https://dns.nextdns.io/dns-query|1
NextDNS #2|45.90.30.0|||1
OpenDNS|208.67.220.220|dns.opendns.com|https://doh.opendns.com/dns-query|1
OpenDNS #2|208.67.222.222||https://dns.opendns.com/dns-query|1
Quad9 (S)|9.9.9.11|dns11.quad9.net|https://dns11.quad9.net/dns-query|1
Quad9 (UN)|9.9.9.10|dns10.quad9.net|https://dns10.quad9.net/dns-query|1
Quad9 (UN2)|9.9.9.12|dns12.quad9.net|https://dns12.quad9.net/dns-query|1
UncensoredDNS||unicast.censurfridns.dk|https://anycast.uncensoreddns.org/dns-query|0
Wikimedia||wikimedia-dns.org|https://wikimedia-dns.org/dns-query|0
XboxDNS (RU)|111.88.96.55|xbox-dns.ru|https://xbox-dns.ru/dns-query|1
Yandex|77.88.8.1|common.dot.dns.yandex.net|https://common.dot.dns.yandex.net/dns-query|1
Yandex #2|77.88.8.8|||1
Yandex (Safe 2)|77.88.8.2|||1
Yandex (Safe)|77.88.8.88|safe.dot.dns.yandex.net|https://safe.dot.dns.yandex.net/dns-query|1'''


@dataclass
class Server:
    name: str
    ip: str
    dot: str = ''
    doh: str = ''
    port: int = 53
    dot_port: int = 853
    udp: bool = True


SERVERS = [Server(*line.split('|')[:4], udp=line.split('|')[4] == '1') for line in PRESETS.splitlines()]
BOOTSTRAP = [Server('Google reference', '8.8.8.8', 'dns.google', 'https://dns.google/dns-query'), Server('Cloudflare reference', '1.1.1.1', 'cloudflare-dns.com', 'https://cloudflare-dns.com/dns-query')]
DEFAULT_DOMAINS = ['rutor.info', 'flibusta.is', 'clubtone.do.am', 'rezka.ag', 'shikimori.one']
ALLOWED_DOMAINS = ['vk.ru', 'gosuslugi.ru']
KNOWN_RESOLVERS = ('google', 'cloudflarenet', 'i3dnet', 'cdn77', 'alibaba-cn-net', 'as-vultr', 'cdnext', 'xtom', 'tencent-net-ap-cn', 'misaka-cis-as', 'as-anexia', 'ru-jsciot', 'yandex', 'cisco', 'woodynet', 'e1-emea', 'gtt-backbone', 'level3', 'firstcolo', 'cloudflare', 'quad9', 'adguard', 'opendns', 'cleanbrowsing', 'nextdns', 'controld', 'mullvad', 'dns0', 'ahadns', 'comss', 'geohide')
COLOR = sys.stdout.isatty() and os.environ.get('TERM') != 'dumb'


def paint(text, color='36;1'):
    return '\033[' + color + 'm' + str(text) + '\033[0m' if COLOR else str(text)


def title(text):
    print('\n' + paint(text), flush=True)


def progress(text):
    if sys.stdout.isatty():
        print('\r\033[2K' + text, end='', flush=True)


def domain(text):
    value = text.strip().rstrip('.').encode('idna').decode('ascii').lower()
    if not value or len(value) > 253:
        raise ValueError('Некорректный домен')
    try:
        ipaddress.ip_address(value)
    except ValueError:
        pass
    else:
        raise ValueError('Здесь нужен домен для DNS-запроса, IP сервера выбирается отдельно')
    for label in value.split('.'):
        if not label or len(label) > 63 or label.startswith('-') or label.endswith('-'):
            raise ValueError('Некорректный домен')
        if any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-' for c in label):
            raise ValueError('Некорректный домен')
    return value


def query(name, qtype=1):
    ident = secrets.randbelow(65536)
    qname = b''.join(bytes([len(p)]) + p.encode('ascii') for p in domain(name).split('.')) + b'\0'
    return struct.pack('!HHHHHH', ident, 0x0100, 1, 0, 0, 0) + qname + struct.pack('!HH', qtype, 1)


def read_name(data, offset):
    labels = []
    end = None
    seen = set()
    for _ in range(128):
        if offset >= len(data) or offset in seen:
            raise ValueError('Некорректное DNS-имя')
        seen.add(offset)
        n = data[offset]
        if n & 0xc0 == 0xc0:
            if offset + 1 >= len(data):
                raise ValueError('Обрезанный DNS-ответ')
            if end is None:
                end = offset + 2
            offset = ((n & 63) << 8) | data[offset + 1]
            continue
        if n > 63 or offset + 1 + n > len(data):
            raise ValueError('Обрезанный DNS-ответ')
        offset += 1
        if n == 0:
            return '.'.join(labels).lower(), end if end is not None else offset
        labels.append(data[offset:offset + n].decode('ascii'))
        offset += n
    raise ValueError('Слишком длинное DNS-имя')


def parse(data, request):
    if len(data) < 12 or len(data) > 65535:
        raise ValueError('Некорректная длина DNS-ответа')
    ident, flags, qd, an, ns, ar = struct.unpack('!6H', data[:12])
    expected_id = struct.unpack('!H', request[:2])[0]
    if ident != expected_id or not flags & 0x8000 or (flags >> 11) & 15 or qd != 1:
        raise ValueError('Ответ не соответствует запросу')
    qname, offset = read_name(data, 12)
    original, original_end = read_name(request, 12)
    if offset + 4 > len(data) or qname != original or data[offset:offset + 4] != request[original_end:original_end + 4]:
        raise ValueError('В ответе изменён DNS-вопрос')
    qtype = struct.unpack('!H', data[offset:offset + 2])[0]
    offset += 4
    records = []
    for index in range(an + ns + ar):
        owner, offset = read_name(data, offset)
        if offset + 10 > len(data):
            raise ValueError('Обрезанная DNS-запись')
        rtype, rclass, ttl, size = struct.unpack('!HHIH', data[offset:offset + 10])
        offset += 10
        if offset + size > len(data):
            raise ValueError('Обрезанные DNS-данные')
        value = data[offset:offset + size]
        if index < an and rclass == 1:
            if rtype in (1, 28) and size == (4 if rtype == 1 else 16):
                records.append((owner, rtype, str(ipaddress.ip_address(value))))
            elif rtype == 5:
                target, _ = read_name(data, offset)
                records.append((owner, rtype, target))
            elif rtype == 16:
                pieces = []
                pos = 0
                while pos < len(value):
                    length = value[pos]
                    pos += 1
                    if pos + length > len(value):
                        raise ValueError('Обрезанная TXT-запись')
                    pieces.append(value[pos:pos + length].decode('ascii', 'replace'))
                    pos += length
                records.append((owner, rtype, ''.join(pieces)))
        offset += size
    owners = {qname}
    for _ in range(16):
        extra = {v for o, t, v in records if o in owners and t == 5}
        if extra.issubset(owners):
            break
        owners.update(extra)
    ips = {v for o, t, v in records if o in owners and t == qtype and t in (1, 28)}
    texts = [v for o, t, v in records if o in owners and t == 16]
    return {'ips': sorted(ips), 'txt': texts, 'rcode': flags & 15, 'ad': bool(flags & 0x20), 'tc': bool(flags & 0x200)}


class ProbeError(Exception):
    pass


def failure(label):
    return {'ips': [], 'txt': [], 'rcode': None, 'ms': None, 'error': label, 'tc': False, 'ad': False}


def tls_error(exc, stage):
    if isinstance(exc, (TimeoutError, socket.timeout)):
        return {'connect': 'SYN DROP', 'handshake': 'TLS DROP'}.get(stage, 'TIMEOUT')
    if isinstance(exc, ssl.SSLCertVerificationError):
        return 'NO CA BUNDLE' if getattr(exc, 'verify_code', None) in (2, 18, 19, 20, 21) else 'TLS ERR'
    if isinstance(exc, ConnectionRefusedError):
        return 'REFUSED'
    if isinstance(exc, ConnectionAbortedError):
        return 'TLS ABORT' if stage != 'connect' else 'TCP ABORT'
    if isinstance(exc, ConnectionResetError):
        return 'TLS RST' if stage != 'connect' else 'TCP RST'
    if isinstance(exc, ssl.SSLEOFError) or 'eof' in str(exc).lower():
        return 'TLS RST' if stage == 'handshake' else 'TLS EOF'
    message = str(exc).lower()
    if 'wrong version number' in message:
        return 'TLS SPOOF'
    if 'protocol_version' in message or 'protocol version' in message:
        return 'TLS BLOCK'
    if 'alert' in str(exc).lower():
        return 'TLS ALERT'
    if getattr(exc, 'errno', None) in (errno.ENETUNREACH, errno.ENETDOWN):
        return 'NET UNREACH'
    if getattr(exc, 'errno', None) in (errno.EHOSTUNREACH, errno.EHOSTDOWN):
        return 'HOST UNREACH'
    return 'TLS ERR' if isinstance(exc, ssl.SSLError) else 'OS ERR'


_curl = None
_curl_lock = threading.Lock()


def curl_library():
    global _curl
    with _curl_lock:
        if _curl is not None:
            return _curl
        try:
            library = ctypes.CDLL('/opt/lib/libcurl.so.4')
        except OSError:
            try:
                library = ctypes.CDLL(ctypes.util.find_library('curl') or 'libcurl.so.4')
            except OSError as exc:
                raise OSError('Нужен libcurl: opkg install curl libcurl ca-bundle') from exc
        library.curl_global_init.argtypes = [ctypes.c_long]
        library.curl_global_init.restype = ctypes.c_int
        if library.curl_global_init(3):
            raise ProbeError('CURL INIT')
        library.curl_easy_init.restype = ctypes.c_void_p
        library.curl_easy_setopt.argtypes = [ctypes.c_void_p, ctypes.c_int]
        library.curl_easy_setopt.restype = ctypes.c_int
        library.curl_easy_getinfo.argtypes = [ctypes.c_void_p, ctypes.c_int]
        library.curl_easy_getinfo.restype = ctypes.c_int
        library.curl_easy_perform.argtypes = [ctypes.c_void_p]
        library.curl_easy_perform.restype = ctypes.c_int
        library.curl_easy_cleanup.argtypes = [ctypes.c_void_p]
        library.curl_slist_append.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        library.curl_slist_append.restype = ctypes.c_void_p
        library.curl_slist_free_all.argtypes = [ctypes.c_void_p]
        _curl = library
        return library


class DohSession:
    def __init__(self, server, timeout):
        self.lib = curl_library()
        self.handle = self.lib.curl_easy_init()
        self.headers = None
        self.resolve = None
        self.body = bytearray()
        self.error = ctypes.create_string_buffer(256)
        self.timeout = timeout
        self.connected = False
        self.closed = False
        self.url = server.doh
        if not self.handle:
            raise ProbeError('CURL INIT')
        self.callback = ctypes.CFUNCTYPE(ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_void_p)(self.receive)
        try:
            url = urllib.parse.urlsplit(server.doh)
            address = '[' + server.ip + ']' if ':' in server.ip else server.ip
            self.resolve = self.lib.curl_slist_append(None, f'{url.hostname}:{url.port or 443}:{address}'.encode())
            for header in (b'Content-Type: application/dns-message', b'Accept: application/dns-message'):
                self.headers = self.lib.curl_slist_append(self.headers, header)
            self.set(10002, ctypes.c_char_p(server.doh.encode()))
            self.set(10010, self.error)
            self.set(20011, self.callback)
            self.set(10023, ctypes.c_void_p(self.headers))
            self.set(10203, ctypes.c_void_p(self.resolve))
            self.set(10177, ctypes.c_char_p(b'*'))
            self.set(10018, ctypes.c_char_p(b'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36'))
            self.set(10318, ctypes.c_char_p(b'https'))
            for option, value in ((47, 1), (99, 1), (64, 1), (81, 2), (84, 4), (121, 1), (52, 0)):
                self.set(option, ctypes.c_long(value))
            ca = os.environ.get('CURL_CA_BUNDLE') or os.environ.get('SSL_CERT_FILE')
            if ca:
                self.set(10065, ctypes.c_char_p(ca.encode()))
        except BaseException:
            self.close()
            raise

    def set(self, option, value):
        if self.lib.curl_easy_setopt(self.handle, option, value):
            raise ProbeError('CURL OPT')

    def receive(self, pointer, size, count, userdata):
        length = size * count
        if len(self.body) + length > 65535:
            return 0
        self.body.extend(ctypes.string_at(pointer, length))
        return length

    def info(self, option, integer=False):
        value = ctypes.c_long() if integer else ctypes.c_double()
        if self.lib.curl_easy_getinfo(self.handle, option, ctypes.byref(value)):
            raise ProbeError('CURL INFO')
        return value.value

    def query(self, name, qtype=1, _get=False, _deadline=None, _elapsed=0):
        packet = query(name, qtype)
        deadline = _deadline or time.monotonic() + self.timeout * (1 if self.connected else 3)
        self.body.clear()
        self.error.value = b''
        if _get:
            separator = '&' if '?' in self.url else '?'
            url = self.url + separator + 'dns=' + base64.urlsafe_b64encode(packet).decode('ascii').rstrip('=')
            self.set(10002, ctypes.c_char_p(url.encode()))
            self.set(80, ctypes.c_long(1))
        else:
            self.set(10002, ctypes.c_char_p(self.url.encode()))
            self.set(47, ctypes.c_long(1))
            self.set(10015, ctypes.c_char_p(packet))
            self.set(60, ctypes.c_long(len(packet)))
        self.set(156, ctypes.c_long(int(self.timeout * 2000)))
        self.set(155, ctypes.c_long(max(1, int((deadline - time.monotonic()) * 1000))))
        code = self.lib.curl_easy_perform(self.handle)
        tcp = self.info(0x300005)
        tls = self.info(0x300021)
        if code:
            message = self.error.value.decode('utf-8', 'replace').lower()
            if code == 28:
                label = 'TLS DROP' if tcp and not tls or any(v in message for v in ('ssl connection timeout', 'tls handshake', 'ssl handshake')) else 'SYN DROP' if 'connect' in message and any(v in message for v in ('timed out', 'timeout')) else 'TIMEOUT' if tls or self.connected else 'SYN DROP'
            elif code in (51, 60):
                label = 'NO CA BUNDLE' if any(t in message for t in ('self-signed', 'self signed', 'unable to get local issuer', 'unable to verify the first')) else 'TLS ERR'
            elif code == 77:
                label = 'CA FAIL'
            elif code in (35, 56):
                label = 'TLS SPOOF' if 'wrong version number' in message else 'TLS BLOCK' if 'protocol version' in message or 'protocol_version' in message else 'TLS RST' if 'reset' in message or not tls and any(v in message for v in ('eof', 'closed', 'syscall')) else 'TLS ALERT' if 'alert' in message else 'TLS ERR' if not tls else 'TLS EOF'
            else:
                os_error = self.info(0x200019, True)
                connection_error = 'REFUSED' if 'refused' in message or os_error == errno.ECONNREFUSED else 'NET UNREACH' if os_error in (errno.ENETUNREACH, errno.ENETDOWN) else 'HOST UNREACH' if os_error in (errno.EHOSTUNREACH, errno.EHOSTDOWN) else 'OS ERR'
                label = {7: connection_error, 23: 'BAD DNS', 16: 'HTTP2 ERR', 92: 'HTTP2 RST', 52: 'TLS EOF'}.get(code, 'DOH FAIL')
            self.closed = code != 28 or self.info(0x20002e, True) != 3
            return failure(label)
        self.connected = True
        status = self.info(0x200002, True)
        if not 200 <= status < 300:
            if not _get and time.monotonic() < deadline:
                result = self.query(name, qtype, True, deadline, _elapsed + max(0, (self.info(0x300003) - tls) * 1000))
                if result['error'].startswith('HTTP '):
                    return failure('HTTP ' + str(status))
                return result
            return failure('HTTP ' + str(status))
        elapsed = (self.info(0x300003) - tls) * 1000
        try:
            answer = parse(bytes(self.body), packet)
        except (ValueError, UnicodeError, struct.error):
            return failure('BAD DNS')
        answer.update(ms=_elapsed + max(0.0, elapsed), error='', new_connections=self.info(0x20001a, True))
        return answer

    def close(self):
        if self.handle:
            self.lib.curl_easy_cleanup(self.handle)
            self.handle = None
        if self.headers:
            self.lib.curl_slist_free_all(self.headers)
            self.headers = None
        if self.resolve:
            self.lib.curl_slist_free_all(self.resolve)
            self.resolve = None


class DotSession:
    def __init__(self, server, timeout, context):
        self.sock = None
        self.timeout = timeout
        self.broken = ''
        stage = 'connect'
        raw = None
        try:
            raw = socket.create_connection((server.ip, server.dot_port), timeout)
            raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            stage = 'handshake'
            raw.settimeout(timeout)
            self.sock = context.wrap_socket(raw, server_hostname=server.dot)
        except (OSError, ssl.SSLError) as exc:
            if raw:
                raw.close()
            raise ProbeError(tls_error(exc, stage)) from exc

    def query(self, name, qtype=1):
        if self.broken:
            return failure(self.broken)
        packet = query(name, qtype)
        start = time.monotonic()
        try:
            self.sock.settimeout(self.timeout)
            self.sock.sendall(struct.pack('!H', len(packet)) + packet)
            size = struct.unpack('!H', exact(self.sock, 2, start + self.timeout))[0]
            data = exact(self.sock, size, start + self.timeout)
            elapsed = (time.monotonic() - start) * 1000
            answer = parse(data, packet)
            answer.update(ms=elapsed, error='')
            return answer
        except (OSError, ProbeError) as exc:
            self.broken = 'TLS EOF' if isinstance(exc, ProbeError) else tls_error(exc, 'query')
            self.close()
            return failure(self.broken)
        except (ValueError, UnicodeError, struct.error):
            return failure('BAD DNS')

    def close(self):
        if self.sock:
            self.sock.close()
            self.sock = None


def exact(sock, count, deadline):
    result = b''
    while len(result) < count:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError
        sock.settimeout(remaining)
        chunk = sock.recv(count - len(result))
        if not chunk:
            raise ProbeError('EOF')
        result += chunk
    return result


def exchange(server, transport, packet, timeout, context):
    af = socket.AF_INET6 if ':' in server.ip else socket.AF_INET
    with socket.socket(af, socket.SOCK_DGRAM) as sock:
        sock.connect((server.ip, server.port))
        deadline = time.monotonic() + timeout
        sock.send(packet)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError
            sock.settimeout(remaining)
            data = sock.recv(65535)
            try:
                parse(data, packet)
                return data
            except (ValueError, UnicodeError, struct.error):
                continue


def probe(server, transport, name, timeout, context, qtype=1):
    session = None
    try:
        if transport != 'UDP':
            session = DotSession(server, timeout, context) if transport == 'DoT' else DohSession(server, timeout)
            return session.query(name, qtype)
        packet = query(name, qtype)
        start = time.monotonic()
        data = exchange(server, transport, packet, timeout, context)
        result = parse(data, packet)
        result['ms'] = (time.monotonic() - start) * 1000
        result['error'] = ''
        return result
    except ssl.SSLCertVerificationError as exc:
        error = tls_error(exc, 'handshake')
    except (socket.timeout, TimeoutError, subprocess.TimeoutExpired):
        error = 'TIMEOUT'
    except ConnectionRefusedError:
        error = 'REFUSED'
    except ConnectionResetError:
        error = 'RESET'
    except ssl.SSLError:
        error = 'TLS FAIL'
    except ProbeError as exc:
        error = str(exc)
    except (ValueError, UnicodeError, struct.error):
        error = 'BAD DNS'
    except OSError:
        error = 'NET FAIL'
    finally:
        if session:
            session.close()
    return failure(error)


def resolver_org(ip, timeout, context):
    address = ipaddress.ip_address(ip)
    if not address.is_global:
        return ''
    if address.version == 4:
        name = '.'.join(reversed(ip.split('.'))) + '.origin.asn.cymru.com'
    else:
        name = '.'.join(reversed(address.exploded.replace(':', ''))) + '.origin6.asn.cymru.com'
    fallbacks = [Server('Yandex reference', '77.88.8.8', doh='https://common.dot.dns.yandex.net/dns-query'), Server('NextDNS reference', '45.90.28.0', doh='https://dns.nextdns.io/dns-query'), Server('OpenDNS reference', '208.67.222.222', doh='https://dns.opendns.com/dns-query')]
    for reference in BOOTSTRAP + fallbacks:
        result = probe(reference, 'DoH', name, timeout, context, 16)
        if result['error'] or not result['txt']:
            continue
        fields = result['txt'][0].split('|')[0].strip().split()
        if not fields:
            continue
        asn = fields[0]
        if not asn.isdigit():
            continue
        detail = probe(reference, 'DoH', 'AS' + asn + '.asn.cymru.com', timeout, context, 16)
        org = detail['txt'][0].strip('"').split('|')[-1].strip() if detail['txt'] else ''
        if len(org) == 10 and org[4:5] == '-' and org[7:8] == '-' and org.replace('-', '').isdigit():
            org = ''
        org = ''.join(c for c in org if 32 <= ord(c) <= 126)[:60]
        return 'AS' + asn + (' · ' + org if org else '')
    return ''


def enabled(server, transport):
    return server.udp if transport == 'UDP' else bool(server.dot if transport == 'DoT' else server.doh)


_bootstrap_cache = {}
_bootstrap_lock = threading.Lock()


def tls_target(server, transport, timeout, context):
    host = server.dot if transport == 'DoT' else urllib.parse.urlsplit(server.doh).hostname
    try:
        ipaddress.ip_address(host)
        return replace(server, ip=host)
    except ValueError:
        pass
    with _bootstrap_lock:
        ip = _bootstrap_cache.get(host)
    if ip:
        return replace(server, ip=ip)
    try:
        response = subprocess.run(['nslookup', host], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
        text = response.stdout.decode('utf-8', 'replace')
        addresses = []
        found = False
        for line in text.splitlines():
            if line.strip().lower().startswith('name:'):
                found = True
            elif found and line.strip().lower().startswith('address'):
                for token in line.split():
                    try:
                        addresses.append(str(ipaddress.ip_address(token.strip('[]'))))
                    except ValueError:
                        pass
        if addresses:
            ip = next((v for v in addresses if ':' not in v), addresses[0])
            with _bootstrap_lock:
                _bootstrap_cache[host] = ip
            return replace(server, ip=ip)
    except (OSError, subprocess.TimeoutExpired):
        pass
    for reference in BOOTSTRAP + [Server('Quad9 reference', '9.9.9.9')]:
        answer = probe(reference, 'UDP', host, timeout, context)
        if not answer['error'] and answer['ips']:
            ip = answer['ips'][0]
            with _bootstrap_lock:
                _bootstrap_cache[host] = ip
            return replace(server, ip=ip)
    raise ProbeError('DNS FAIL')


def scan_transport(server, transport, domains, timeout, context, invalid):
    result = {'control': failure('SKIPPED'), 'controls': {}, 'domains': {}, 'invalid': None, 'egress': None, 'target_ip': server.ip}
    session = None
    try:
        if transport == 'UDP':
            with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
                controls = {pool.submit(probe, server, 'UDP', name, timeout, context): name for name in ALLOWED_DOMAINS}
                domain_jobs = {}
                for future in concurrent.futures.as_completed(controls):
                    answer = future.result()
                    result['controls'][controls[future]] = answer
                    if not answer['error'] and not answer['tc'] and answer['rcode'] == 0 and not domain_jobs:
                        domain_jobs = {pool.submit(probe, server, 'UDP', name, timeout, context): name for name in domains}
                good = [a for a in result['controls'].values() if not a['error'] and not a['tc'] and a['rcode'] == 0]
                result['control'] = min(good, key=lambda a: a['ms']) if good else next(iter(result['controls'].values()))
                for future in concurrent.futures.as_completed(domain_jobs):
                    result['domains'][domain_jobs[future]] = future.result()
                if good:
                    result['invalid'] = probe(server, 'UDP', invalid, min(timeout, 2), context)
            return result
        else:
            target = tls_target(server, transport, timeout, context)
            result['target_ip'] = target.ip
            session = DotSession(target, timeout, context) if transport == 'DoT' else DohSession(target, timeout)
            warmup = session.query(ALLOWED_DOMAINS[0])
            if (transport == 'DoT' and warmup['error']) or (transport == 'DoH' and warmup['error'] and session.closed):
                result['control'] = warmup
                return result
            execute = session.query
        deadline = time.monotonic() + timeout * (len(domains) + 1) + 3
        for name in domains:
            answer = execute(name) if time.monotonic() + timeout <= deadline else failure('SKIPPED')
            if transport == 'DoH' and (answer['error'] or answer['rcode']) and answer['error'] != 'SKIPPED' and not session.closed:
                pause = random.uniform(.3, 1)
                if time.monotonic() + pause + timeout <= deadline:
                    time.sleep(pause)
                    answer = execute(name)
            result['domains'][name] = answer
        good = [a for a in result['domains'].values() if not a['error'] and not a['tc'] and a['rcode'] == 0]
        result['control'] = min(good, key=lambda a: a['ms']) if good else next(iter(result['domains'].values()), warmup)
        result['invalid'] = execute(invalid) if time.monotonic() + timeout <= deadline else failure('SKIPPED')
        return result
    except ProbeError as exc:
        result['control'] = failure(str(exc))
        return result
    finally:
        if session:
            session.close()


def reference_panel():
    endpoints = {}
    for server in SERVERS:
        for transport in ('DoH', 'DoT'):
            if enabled(server, transport):
                endpoint = server.doh if transport == 'DoH' else server.dot
                port = (urllib.parse.urlsplit(endpoint).port or 443) if transport == 'DoH' else server.dot_port
                endpoints.setdefault((transport, endpoint, port), replace(server, ip='', udp=False))
    return endpoints


def fixed_truth(domains, timeout, context, invalid, show_progress=False):
    truth = {name: set() for name in domains}
    references = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        endpoints = reference_panel()
        jobs = {pool.submit(scan_transport, server, transport, domains, timeout, context, invalid): (i, transport) for i, ((transport, endpoint, port), server) in enumerate(endpoints.items())}
        for future in concurrent.futures.as_completed(jobs):
            index, transport = jobs[future]
            references.setdefault(index, {})[transport] = future.result()
            if show_progress:
                progress(f'1/3 · Защищённые эталоны: {len(references)}/{len(jobs)}')
    return truth, add_truth(truth, references)


def scan_server(server, domains, timeout, context, invalid):
    result = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        jobs = {pool.submit(scan_transport, server, transport, domains, timeout, context, invalid): transport for transport in ('UDP', 'DoT', 'DoH') if enabled(server, transport)}
        if enabled(server, 'UDP'):
            jobs[pool.submit(probe_egress, server, timeout, context)] = 'egress'
        for future in concurrent.futures.as_completed(jobs):
            result[jobs[future]] = future.result()
    if 'UDP' in result:
        result['UDP']['egress'] = result.get('egress')
    return result


def probe_egress(server, timeout, context):
    result = failure('TIMEOUT')
    for attempt in range(2):
        result = probe(server, 'UDP', 'whoami.akamai.net', min(timeout, 2) if attempt == 0 else timeout, context)
        if not result['error'] and result['ips']:
            return result
        if attempt == 0:
            time.sleep(.2)
    return result


def cell(result, transport='UDP'):
    if result is None:
        return '—'
    if transport != 'UDP':
        answers = list(result['domains'].values())
        good = [a['ms'] for a in answers if not a['error'] and not a['tc'] and a['rcode'] == 0]
        if good:
            return f'{min(good):.1f}ms'
        control = next((a for a in answers if a['error'] or a['rcode'] or not a['ips']), result['control'])
    else:
        control = result['control']
    if control['error']:
        return control['error']
    if control['tc']:
        return 'TRUNCATED'
    if control['rcode']:
        return {2: 'SERVFAIL', 3: 'NXDOMAIN', 5: 'REFUSED'}.get(control['rcode'], 'RCODE ' + str(control['rcode']))
    return f"{control['ms']:.1f}ms"


def text_width(text):
    return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in text)


def wrap_cell(text, width):
    lines = []
    for part in str(text).split('\n'):
        current = ''
        for char in part:
            if unicodedata.category(char).startswith('C'):
                char = '?'
            if current and text_width(current + char) > width:
                lines.append(current)
                current = ''
            current += char
        lines.append(current)
    return lines


def latency_color(result, transport, value):
    if result is None:
        return '90'
    if not value.endswith('ms'):
        return '31'
    answers = list(result.get('controls' if transport == 'UDP' else 'domains', {}).values())
    if answers and any(a['error'] or a['tc'] or a['rcode'] for a in answers):
        return '33'
    return '32'


def resolver_cell(item):
    ip = item['ip']
    if not ip:
        return '—', '90'
    if not item['cells']['UDP'].endswith('ms'):
        return ip + '→—', '90'
    if not item['egress'] or item['egress'] == '0.0.0.0':
        return ip + ': нет данных', '90'
    if fake_ip(item['egress']):
        return ip + '→Fake-IP', '35'
    org = item['organization']
    if not org:
        return ip + '→' + item['egress'], '37'
    label = org.split(' · ', 1)[-1].split(' - ', 1)[0]
    return ip + '→' + label, '32' if any(v in label.lower() for v in KNOWN_RESOLVERS) else '31'


def render_table(report, columns=None):
    columns = max(40, min(140, columns or shutil.get_terminal_size((120, 24)).columns))
    padding = 1 if columns >= 85 else 0
    widths = [10, 9, 9, 9, 21, 8] if columns >= 76 else [7, 5, 5, 5, 7, 4]
    spare = columns - sum(widths) - 7 - 12 * padding
    resolver_width = max((text_width(resolver_cell(r)[0]) for r in report), default=21)
    caps = [max(12, min(26, max((text_width(r['name']) for r in report), default=12))), 10, 10, 10, max(18, min(24, resolver_width)), 8]
    while spare > 0:
        changed = False
        for index in (4, 4, 4, 4, 0, 0, 0, 0, 1, 2, 3, 5):
            if spare and widths[index] < caps[index]:
                widths[index] += 1
                spare -= 1
                changed = True
        if not changed:
            break

    def border(left, join, right, horizontal='─'):
        print(paint(left + join.join(horizontal * (w + 2 * padding) for w in widths) + right, '90'))

    def row(values, colors):
        wrapped = [wrap_cell(value, width) for value, width in zip(values, widths)]
        for line_no in range(max(map(len, wrapped))):
            chunks = []
            for index, lines in enumerate(wrapped):
                line = lines[line_no] if line_no < len(lines) else ''
                line += ' ' * (widths[index] - text_width(line))
                color = '90' if line.strip() == 'SKIPPED' else '31' if index in (1, 2, 3) and line_no > 0 and line.strip() else colors[index]
                chunks.append(' ' * padding + paint(line, color) + ' ' * padding)
            print(paint('│', '90') + paint('│', '90').join(chunks) + paint('│', '90'))

    border('┌', '┬', '┐')
    headers = ['Провайдер', 'DoH', 'DoT', 'UDP', 'UDP-резолвер', 'Spoofing']
    if columns < 76:
        headers = ['DNS', 'DoH', 'DoT', 'UDP', 'UDP-резолвер', 'Spoofing']
    row(headers, ['37;1'] * 6)
    border('╞', '╪', '╡', '═')
    for item in report:
        real, real_color = resolver_cell(item)
        score = f"{item['differences']}/{item['judged']}" if item['judged'] else '—'
        score_color = '90' if not item['judged'] else '32' if not item['differences'] else '31' if item['differences'] == item['judged'] else '33'
        if any('Fake-IP' in s for s in item['signals']):
            score_color = '35'
        if any('.invalid' in s for s in item['signals']):
            score = 'INVALID'
            score_color = '31'
        protocol_values = []
        for transport in ('DoH', 'DoT', 'UDP'):
            value = item['cells'][transport]
            if value.endswith('ms'):
                errors = set()
                for answer in item['results'].get(transport, {}).get('domains', {}).values():
                    label = answer['error'] or ('TRUNCATED' if answer['tc'] else {2: 'SERVFAIL', 3: 'NXDOMAIN', 5: 'REFUSED'}.get(answer['rcode'], 'RCODE ' + str(answer['rcode'])) if answer['rcode'] else '')
                    if label:
                        errors.add(label)
                errors = sorted(errors)
                value += ''.join('\n' + e for e in errors)
            protocol_values.append(value)
        values = [item['name']] + protocol_values + [real, score]
        colors = ['36;1'] + [latency_color(item['results'].get(t), t, item['cells'][t]) for t in ('DoH', 'DoT', 'UDP')] + [real_color, score_color]
        row(values, colors)
    border('└', '┴', '┘')


def suspicious_ip(value):
    address = ipaddress.ip_address(value)
    return address.is_loopback or address.is_unspecified or address.is_link_local or address.is_private or address in ipaddress.ip_network('198.18.0.0/15') or address in ipaddress.ip_network('100.64.0.0/10')


def assess(result, truth):
    differences = 0
    judged = 0
    signals = []
    if result is None:
        return judged, differences, signals
    control = result['control']
    alive = not control['error'] and not control['tc'] and control['rcode'] == 0
    invalid = result['invalid']
    if invalid and not invalid['error'] and not invalid['tc'] and invalid['ips']:
        signals.append('несуществующий домен .invalid получил IP')
    for name, answer in result['domains'].items():
        reference = truth.get(name, set())
        if not reference or not alive:
            continue
        if answer['tc'] or answer['error'] == 'SKIPPED':
            continue
        judged += 1
        ips = answer['ips'] if not answer['error'] and answer['rcode'] == 0 else []
        if not reference.intersection(ips):
            differences += 1
        if answer['error'] and answer['error'] != 'SKIPPED':
            signals.append(name + ': нет ответа на проверяемый домен при работающем UDP')
        if answer['rcode'] == 3 or (answer['rcode'] == 0 and not answer['ips'] and not answer['tc']):
            signals.append(name + ': NXDOMAIN/EMPTY при наличии адреса через DoH')
        if answer['ips'] and any(suspicious_ip(ip) for ip in answer['ips']) and all(not suspicious_ip(ip) for ip in reference):
            signals.append(name + ': локальный адрес / Fake-IP вместо публичного')
    return judged, differences, signals


def add_truth(truth, results):
    count = 0
    for data in results.values():
        for transport in ('DoH', 'DoT'):
            for name, answer in data.get(transport, {}).get('domains', {}).items():
                if answer['error'] or answer['tc'] or answer['rcode'] != 0:
                    continue
                ips = {ip for ip in answer['ips'] if not fake_ip(ip)}
                if ips:
                    truth.setdefault(name, set()).update(ips)
                    count += 1
    return count


def fake_ip(ip):
    address = ipaddress.ip_address(ip)
    return address.version == 4 and address in ipaddress.ip_network('198.18.0.0/15')


def detect_hijacks(items):
    networks = {}
    findings = []
    for item in items:
        ip = item['egress']
        if not ip or ip == '0.0.0.0' or fake_ip(ip):
            continue
        address = ipaddress.ip_address(ip)
        prefix = ipaddress.ip_network(ip + ('/24' if address.version == 4 else '/48'), strict=False)
        brand = item['name'].split(' (')[0].split(' #')[0].strip()
        networks.setdefault(str(prefix), set()).add(brand)
    for item in items:
        ip = item['egress']
        if not ip or ip == '0.0.0.0' or fake_ip(ip):
            continue
        address = ipaddress.ip_address(ip)
        prefix = str(ipaddress.ip_network(ip + ('/24' if address.version == 4 else '/48'), strict=False))
        exempt = any(v in item['name'].lower() for v in ('msk-ix', 'нсди', 'nsdi'))
        org = item['organization'].split(' · ', 1)[-1].split(' - ', 1)[0].lower()
        if len(networks[prefix]) >= 2 and not exempt and not any(v in org for v in KNOWN_RESOLVERS):
            findings.append({'name': item['name'], 'network': prefix})
    return findings


def read_value(prompt, stream):
    while True:
        print(prompt, end='', flush=True)
        value = stream.readline()
        if value in ('', b''):
            raise EOFError
        if isinstance(value, bytes):
            try:
                value = value.decode('utf-8')
            except UnicodeDecodeError:
                print('Некорректные символы во вводе. Введите значение заново.')
                continue
        return value.strip()


def check_doh(value):
    url = urllib.parse.urlsplit(value)
    if url.scheme != 'https' or not url.hostname or url.username or url.password or url.fragment:
        raise ValueError('Нужен HTTPS URL без учётных данных и фрагмента')
    if any(ord(c) <= 32 or ord(c) >= 127 for c in value):
        raise ValueError('Недопустимые символы в DoH URL')
    if url.port is not None and not 1 <= url.port <= 65535:
        raise ValueError('Неверный порт')
    return value


def custom_server(ip, dot=None, doh=None, port=53, dot_port=853):
    parsed = ipaddress.ip_address(ip.strip().strip('[]'))
    if isinstance(parsed, ipaddress.IPv6Address) and parsed.ipv4_mapped:
        parsed = parsed.ipv4_mapped
    address = str(parsed)
    if parsed.is_multicast or parsed.is_unspecified or parsed.is_link_local or address == '255.255.255.255':
        raise ValueError('Укажите unicast IP DNS-сервера, не multicast, unspecified или link-local')
    if not 1 <= port <= 65535 or not 1 <= dot_port <= 65535:
        raise ValueError('Порт должен быть от 1 до 65535')
    known = next((s for s in SERVERS if s.ip == address), None)
    dot = (known.dot if known else '') if dot is None else dot
    doh = (known.doh if known else '') if doh is None else doh
    if dot:
        try:
            dot = str(ipaddress.ip_address(dot.strip('[]')))
        except ValueError:
            dot = domain(dot)
    return Server('Custom ' + address, address, dot, check_doh(doh) if doh else '', port, dot_port)


def interactive():
    with open('/dev/tty', 'rb', buffering=0) as stream:
        while True:
            title('Какие DNS-серверы проверить?')
            print('1. Популярные: Google, Cloudflare, Quad9, AdGuard, Yandex, DNS.SB')
            print(f'2. Все пресеты ({len(SERVERS)} серверов)')
            print('3. Выбрать из списка')
            print('4. Ввести свои DNS-серверы')
            choice = read_value('Enter — назад. Выбор: ', stream)
            if choice in ('', '0'):
                return None
            if choice == '1':
                chosen = [next(s for s in SERVERS if s.name == name) for name in ('Google', 'Cloudflare IP', 'Quad9', 'AdGuard', 'Yandex', 'DNS.SB')]
                break
            if choice == '2':
                chosen = SERVERS[:]
                break
            if choice == '3':
                for i, server in enumerate(SERVERS, 1):
                    print(f'{i:2}. {server.name:23} {server.ip or server.dot or server.doh}')
                try:
                    text = read_value('Номера через пробел (например 1 3 7), Enter — назад: ', stream)
                    if not text:
                        continue
                    indices = list(dict.fromkeys(int(v) for v in text.replace(',', ' ').split()))
                    if not indices or any(i < 1 or i > len(SERVERS) for i in indices):
                        raise ValueError('Некорректный номер')
                    chosen = [SERVERS[i - 1] for i in indices]
                    break
                except ValueError:
                    print('Укажите номера серверов из списка.')
            elif choice == '4':
                chosen = []
                print('UDP — указанный IP. DoT/DoH — адреса введённых сервисов.')
                while len(chosen) < 10:
                    ip = read_value('IP DNS-сервера (IPv4 / IPv6), Enter — закончить: ', stream)
                    if not ip:
                        break
                    try:
                        defaults = custom_server(ip)
                        if defaults.dot or defaults.doh:
                            print('Для известного IP предложены параметры пресета. Enter — принять, «-» — отключить протокол.')
                        udp_port = int(read_value('Порт UDP [53]: ', stream) or '53')
                        dot = read_value('Адрес DoT-сервиса (имя или IP)' + (' [' + defaults.dot + ']' if defaults.dot else ' (Enter — не проверять)') + ': ', stream)
                        dot = '' if dot == '-' else dot or defaults.dot
                        dot_port = int(read_value('Порт DoT [853]: ', stream) or '853') if dot else 853
                        doh = read_value('DoH URL' + (' [' + defaults.doh + ']' if defaults.doh else ' (Enter — не проверять)') + ': ', stream)
                        doh = '' if doh == '-' else doh or defaults.doh
                        if not 1 <= udp_port <= 65535 or not 1 <= dot_port <= 65535:
                            raise ValueError('Порт должен быть от 1 до 65535')
                        chosen.append(custom_server(ip, dot, doh, udp_port, dot_port))
                    except ValueError as exc:
                        print('Ошибка: ' + str(exc))
                if chosen:
                    break
        while True:
            print('Проверяемые домены по умолчанию: ' + ', '.join(DEFAULT_DOMAINS))
            text = read_value('Свой список до 5 доменов или Enter — стандартный: ', stream)
            try:
                domains = list(dict.fromkeys(domain(v) for v in text.replace(',', ' ').split())) if text else DEFAULT_DOMAINS
                if not 1 <= len(domains) <= 5:
                    raise ValueError('Нужно от 1 до 5 доменов')
                return chosen, domains
            except ValueError as exc:
                print('Ошибка: ' + str(exc))


def main():
    parser = argparse.ArgumentParser(description='Xmenu: UDP / DoT / DoH DNS diagnostics')
    parser.add_argument('--servers', help='Preset numbers separated by commas, or all')
    parser.add_argument('--ip', help='Custom IPv4 or IPv6 UDP DNS server')
    parser.add_argument('--dot', default=None, help='DoT service hostname or IP; empty disables DoT')
    parser.add_argument('--doh', default=None, help='Custom DoH HTTPS URL; empty disables DoH')
    parser.add_argument('--domains', default=','.join(DEFAULT_DOMAINS))
    parser.add_argument('--timeout', type=float, default=10.0)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    if args.ip:
        chosen = [custom_server(args.ip, args.dot, args.doh)]
    elif args.servers:
        ids = list(range(1, len(SERVERS) + 1)) if args.servers == 'all' else list(dict.fromkeys(int(i) for i in args.servers.split(',')))
        if not ids or any(i < 1 or i > len(SERVERS) for i in ids):
            raise ValueError('Неверный номер сервера')
        chosen = [SERVERS[i - 1] for i in ids]
    else:
        selection = interactive()
        if selection is None:
            return 3
        chosen, domains = selection
    if args.ip or args.servers:
        domains = list(dict.fromkeys(domain(i) for i in args.domains.split(',')))
    if not 1 <= len(domains) <= 5 or not 0.2 <= args.timeout <= 10:
        raise ValueError('Нужно 1–5 доменов; timeout 0.2–10 секунд')
    context = ssl.create_default_context()
    curl_library()
    invalid = 'xmenu-' + secrets.token_hex(8) + '.invalid'
    started = time.monotonic()
    if not args.json:
        progress('1/3 · Фиксированные независимые эталоны DoH / DoT…')
    truth, reference_ok = fixed_truth(domains, args.timeout, context, invalid, show_progress=not args.json)
    results = {}
    for i, server in enumerate(chosen):
        if not args.json:
            progress(f'2/3 · DNS {i + 1}/{len(chosen)}: {server.name}…')
        results[i] = scan_server(server, domains, args.timeout, context, invalid)
    egress_ips = {data['egress']['ips'][0] for data in results.values() if data.get('egress') and data['egress']['ips']}
    if not args.json:
        progress('3/3 · Реальные резолверы и ASN…')
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        org_jobs = {pool.submit(resolver_org, ip, args.timeout, context): ip for ip in egress_ips}
        organizations = {org_jobs[future]: future.result() for future in concurrent.futures.as_completed(org_jobs)}
    report = []
    working = 0
    incomplete = 0
    available = {t: 0 for t in ('UDP', 'DoT', 'DoH')}
    totals = {t: 0 for t in ('UDP', 'DoT', 'DoH')}
    no_ca = 0
    for i, server in enumerate(chosen):
        data = results[i]
        judged, differences, signals = assess(data.get('UDP'), truth)
        cells = {t: cell(data.get(t), t) for t in ('UDP', 'DoT', 'DoH')}
        for transport, value in cells.items():
            available[transport] += value.endswith('ms')
            if enabled(server, transport):
                if value in ('NO CA BUNDLE', 'CA FAIL'):
                    no_ca += 1
                else:
                    totals[transport] += 1
        working += any(v.endswith('ms') for v in cells.values())
        incomplete += bool(server.udp and (judged < len(domains) or any(a['error'] or a['tc'] for a in data.get('UDP', {}).get('domains', {}).values())))
        egress = data.get('UDP', {}).get('egress')
        egress = egress['ips'][0] if egress and egress['ips'] else None
        org = organizations.get(egress, '')
        report.append({'name': server.name, 'ip': server.ip, 'cells': cells, 'judged': judged, 'differences': differences, 'signals': signals, 'egress': egress, 'organization': org, 'results': data})
    batch_findings = detect_hijacks(report)
    suspicious = sum(bool(item['signals']) or item['differences'] > 0 for item in report)
    elapsed = time.monotonic() - started
    if args.json:
        settings = {'timeout': args.timeout, 'target_scheduling': 'one-server-at-a-time', 'tls_target_policy': 'service-endpoint', 'reference_policy': 'fixed-public-encrypted-panel', 'reference_endpoints': list(reference_panel())}
        print(json.dumps({'servers': report, 'domains': domains, 'allowed_domains': ALLOWED_DOMAINS, 'reference_answers': reference_ok, 'truth': {name: sorted(ips) for name, ips in truth.items()}, 'batch_findings': batch_findings, 'settings': settings, 'no_ca_bundle': no_ca, 'elapsed': elapsed}, ensure_ascii=False))
        return 0
    progress('')
    render_table(report)
    print(paint(f'Итог: DNS {len(chosen)} · с успешными запросами {working} · подозрительных {suspicious} · {elapsed:.1f} с'))
    print('Успешно: ' + ' · '.join(t + ' ' + str(available[t]) + '/' + str(totals[t]) for t in ('UDP', 'DoT', 'DoH')))
    if no_ca:
        print('Не проверены из-за доверия сертификатам: ' + str(no_ca) + '; в недоступные серверы не включены.')
    if batch_findings:
        print(paint('Сравнение между DNS: общая неизвестная сеть у ' + ', '.join(dict.fromkeys(v['name'] for v in batch_findings)) + '.', '33'))
    if suspicious:
        print(paint('Есть признаки фильтрации, подмены ответов или локальных DNS-правил.', '33'))
    elif reference_ok == 0 or incomplete:
        print(paint('Недостаточно данных для общего вывода: часть DNS-запросов не завершена.', '33'))
    else:
        print(paint('В выполненных проверках признаков подмены не найдено.', '32'))
    print('ms — DNS без TCP/TLS; Spoofing — расхождения UDP с защищёнными ответами.')
    print('UDP — выбранный IP; DoT/DoH — адреса указанных сервисов.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (KeyboardInterrupt, EOFError):
        print('\nПроверка отменена.')
        sys.exit(130)
    except (ValueError, OSError) as exc:
        print('Ошибка: ' + str(exc), file=sys.stderr)
        sys.exit(2)

XMENU_DNS_ENGINE
}

xmenu_server_diagnose() {
    command -v python3 >/dev/null 2>&1 || { say 'Нужен Python 3: opkg install python3 python3-ssl'; return 2; }
    python3 - "$@" <<'XMENU_SERVER_ENGINE'
import argparse
import atexit
import concurrent.futures
import errno
import http.client
import ipaddress
import json
import os
import re
import secrets
import select
import shlex
import signal
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import time
import threading
import unicodedata
import urllib.parse
import math
import statistics
import weakref
import zlib
import datetime


COLOR = sys.stdout.isatty() and os.environ.get('TERM') != 'dumb'
DEFAULT_PORTS = [22, 80, 443, 8080, 8443, 2053, 2083, 2087, 2096, 2098, 31618]
BYPASS_MARK = 0
INPUT_CHAINS = []
FLOW_RULES = []
FLOW_LOCK = threading.RLock()
CANCEL = threading.Event()
API_ADDRESSES = {}
MAX_DISCOVERY_PORTS = 5
MAX_TOTAL_PORTS = 18
END_TIME = float('inf')
WAN_INTERFACE = ''
ACTIVE_SOCKETS = weakref.WeakSet()
SOCKET_LOCK = threading.RLock()


def remaining(timeout):
    if CANCEL.is_set():
        raise OSError(errno.ECANCELED, 'Проверка остановлена')
    value = min(timeout, END_TIME - time.monotonic())
    if value <= 0:
        raise OSError(errno.ECANCELED, 'Общий лимит времени исчерпан')
    return max(.001, value)


def stop_probes():
    CANCEL.set()
    with SOCKET_LOCK:
        for sock in list(ACTIVE_SOCKETS):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def public_target(value):
    address = ipaddress.ip_address(value.strip().strip('[]'))
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
        address = address.ipv4_mapped
    if not address.is_global or address.is_multicast or address.is_reserved or address.is_loopback or address.is_link_local:
        raise ValueError('Нужен публичный IP VPS: частные, CGNAT, loopback и специальные диапазоны не подходят')
    if address.version == 4 and any(address in ipaddress.ip_network(prefix) for prefix in ('192.0.0.0/24', '192.88.99.0/24', '192.31.196.0/24', '192.52.193.0/24', '192.175.48.0/24')):
        raise ValueError('Специальный инфраструктурный диапазон IANA не подходит для проверки VPS')
    if address.version == 6 and (address.sixtofour or address.teredo or address.scope_id or address in ipaddress.ip_network('64:ff9b::/96')):
        raise ValueError('Переходные IPv6-адреса 6to4/Teredo не подходят для прямой проверки VPS')
    return str(address)


def firewall(arguments):
    return subprocess.run(arguments, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=4).returncode == 0


class FlowGuard:
    def __init__(self, ip, protocol, local_port, remote_port):
        self.rules = []
        command = 'ip6tables' if family(ip) == socket.AF_INET6 else 'iptables'
        tag = 'xmenu-server-' + str(os.getpid()) + '-' + secrets.token_hex(5)
        with FLOW_LOCK:
            try:
                for binary, chain in INPUT_CHAINS:
                    if binary != command:
                        continue
                    prefix = [binary, '-w', '-t', 'mangle']
                    match = ['-s', ip, '-p', protocol, '--sport', str(remote_port), '--dport', str(local_port), '-m', 'comment', '--comment', tag, '-j', 'RETURN']
                    rule = prefix + ['-D', chain] + match
                    add = prefix + ['-I', chain, '1'] + match
                    if not firewall(add):
                        raise OSError(errno.ENOTSUP, 'Не удалось исключить входящую пробу из NFQUEUE')
                    self.rules.append(rule)
                    FLOW_RULES.append(rule)
            except BaseException:
                self.close()
                raise

    def close(self):
        with FLOW_LOCK:
            for rule in self.rules[:]:
                try:
                    if firewall(rule):
                        self.rules.remove(rule)
                        if rule in FLOW_RULES:
                            FLOW_RULES.remove(rule)
                except (OSError, subprocess.TimeoutExpired):
                    pass


def cleanup_flows():
    with FLOW_LOCK:
        for rule in FLOW_RULES[:]:
            try:
                if firewall(rule):
                    FLOW_RULES.remove(rule)
            except (OSError, subprocess.TimeoutExpired):
                pass


atexit.register(cleanup_flows)


def jump_target(row):
    for flag in ('-j', '--jump', '-g', '--goto'):
        if flag in row and row.index(flag) + 1 < len(row):
            return row[row.index(flag) + 1]
    return ''


def detect_path(ip=None):
    global INPUT_CHAINS
    rules = ''
    snapshots = []
    inspection_errors = []
    incoming_risks = []
    INPUT_CHAINS = []
    for binary in ('iptables', 'ip6tables'):
        if ip is not None and (binary == 'ip6tables') != (family(ip) == socket.AF_INET6):
            continue
        for kind in ('nat', 'mangle'):
            try:
                result = subprocess.run([binary + '-save', '-t', kind], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=3)
                text = result.stdout.decode('ascii', 'replace')
                if len(result.stdout) > 1048576:
                    inspection_errors.append(binary + '-save ' + kind + ': неполный снимок')
                if result.returncode:
                    if binary == 'iptables' or ip is not None:
                        inspection_errors.append(binary + '-save ' + kind)
                    continue
                snapshots.append((binary, kind, text[:1048576]))
                rules += text
                if kind == 'mangle':
                    lines = [shlex.split(line) for line in text.splitlines() if line.startswith('-A ')]
                    edges = {}
                    for line in lines:
                        target = jump_target(line)
                        if target:
                            edges.setdefault(line[1], set()).add(target)
                    reachable = {'PREROUTING'}
                    for _ in range(64):
                        extra = set().union(*(edges.get(chain, set()) for chain in reachable))
                        if extra.issubset(reachable):
                            break
                        reachable.update(extra)
                    if any(not edges.get(chain, set()).issubset(reachable) for chain in reachable):
                        incoming_risks.append('Неполный обход входящих цепочек ' + binary)
                    for line in lines:
                        if line[1] in reachable and jump_target(line) in ('NFQUEUE', 'QUEUE'):
                            if 'nfqws' in line[1].lower():
                                INPUT_CHAINS.append((binary, line[1]))
                                protocol = line[line.index('-p') + 1] if '-p' in line else ''
                                negated = '-p' in line and line.index('-p') > 0 and line[line.index('-p') - 1] == '!'
                                if protocol not in ('tcp', 'udp', '6', '17') or negated:
                                    incoming_risks.append('Входящая очередь может менять ICMP: ' + binary + '/' + line[1])
                            else:
                                incoming_risks.append('Нераспознанная входящая очередь: ' + binary + '/' + line[1])
                        if '--comment' in line:
                            tag = line[line.index('--comment') + 1]
                            match = re.fullmatch(r'xmenu-server-(\d+)-[0-9a-f]{10}', tag)
                            if match and not os.path.exists('/proc/' + match[1]):
                                delete = [binary, '-w', '-t', kind, '-D'] + line[1:]
                                with FLOW_LOCK:
                                    if delete not in FLOW_RULES:
                                        FLOW_RULES.append(delete)
                                    if firewall(delete):
                                        FLOW_RULES.remove(delete)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                if binary == 'iptables' or ip is not None:
                    inspection_errors.append(binary + '-save ' + kind)
    INPUT_CHAINS = list(dict.fromkeys(INPUT_CHAINS))
    risks = incoming_risks
    matched = False
    for binary, kind, text in snapshots:
        lines = [shlex.split(line) for line in text.splitlines() if line.startswith('-A ')]
        graph = {}
        for row in lines:
            target = jump_target(row)
            if target:
                graph.setdefault(row[1], set()).add(target)
        reachable = {'OUTPUT', 'POSTROUTING'}
        for _ in range(64):
            expanded = reachable | set().union(*(graph.get(c, set()) for c in reachable))
            if expanded == reachable:
                break
            reachable = expanded
        if any(not graph.get(chain, set()).issubset(reachable) for chain in reachable):
            risks.append('Неполный обход исходящих цепочек ' + binary + '/' + kind)
        exempt = set()
        for row in lines:
            if row[1] not in reachable:
                continue
            target = jump_target(row)
            if target == 'RETURN' and '--mark' in row and '!' not in row and row[row.index('--mark') + 1] == '0x40000000/0x40000000':
                tokens = row[2:]
                allowed = {'-m', 'mark', '--mark', '0x40000000/0x40000000', 'comment', '--comment', '-j', 'RETURN'}
                if '--comment' in tokens:
                    tokens = tokens[:tokens.index('--comment')] + tokens[tokens.index('--comment') + 2:]
                if all(token in allowed for token in tokens):
                    exempt.add(row[1])
                    matched = True
            dangerous = target in ('REDIRECT', 'TPROXY', 'DNAT', 'MARK', 'CONNMARK', 'NFQUEUE', 'QUEUE')
            excluded = '--mark' in row and row[row.index('--mark') - 1] == '!' and row[row.index('--mark') + 1] == '0x40000000/0x40000000'
            if dangerous and row[1] not in exempt and not excluded:
                risks.append(binary + '/' + kind + '/' + row[1] + ': ' + target)
            elif dangerous and excluded:
                matched = True
    nft = ''
    if shutil.which('nft'):
        try:
            result = subprocess.run(['nft', 'list', 'ruleset'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=3)
            nft = result.stdout.decode('ascii', 'replace')[:1048576]
            if result.returncode or len(result.stdout) > 1048576 or re.search(r'\b(tproxy|redirect|dnat|queue)\b|meta mark set|ct mark set', nft, re.I):
                risks.append('Правила nftables не подтверждены как безопасные для прямых проб')
        except (OSError, subprocess.TimeoutExpired):
            risks.append('Не удалось прочитать nftables')
    proxy_rules = bool(re.search(r'\b(?:REDIRECT|TPROXY)\b', rules))
    return {'mark': 0x40000000 if matched else 0, 'proxy_rules': proxy_rules, 'direct_ready': not risks and not inspection_errors, 'risks': risks, 'inspection_errors': inspection_errors, 'nft_present': bool(nft), 'policy_rules': '', 'interface': '', 'source': ''}


def inspect_route(ip, path):
    global WAN_INTERFACE
    marked = route(ip)
    try:
        version = '-6' if family(ip) == socket.AF_INET6 else '-4'
        result = subprocess.run(['ip', version, 'rule', 'show'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=remaining(3))
        path['policy_rules'] = result.stdout.decode('ascii', 'replace')[:8192]
        if result.returncode:
            path['risks'].append('Не удалось проверить ip rule')
        defaults = subprocess.run(['ip', version, 'route', 'show', 'table', 'main', 'default'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=remaining(3))
        devices = re.findall(r'\bdev\s+(\S+)', defaults.stdout.decode('ascii', 'replace'))
        dev = marked.get('interface', '')
        tunnel = bool(re.match(r'(?:tun|tap|wg|sstp|pptp|l2tp|ipsec|gre|sit|ip6tnl|tailscale|mihomo|clash|lo|br)', dev, re.I)) or os.path.exists('/sys/class/net/' + dev + '/tun_flags')
        if dev:
            link = subprocess.run(['ip', '-details', 'link', 'show', 'dev', dev], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=remaining(2))
            link_text = link.stdout.decode('ascii', 'replace')
            if link.returncode or re.search(r'\b(?:wireguard|vxlan|ipip|ip6tnl|vti|vti6|gretap|gre|tun|tap|sit|xfrm)\b', link_text, re.I):
                tunnel = True
            physical = os.path.exists('/sys/class/net/' + dev + '/device') or bool(re.fullmatch(r'(?:eth|en|wan|wwan|ptm|atm)[A-Za-z0-9_.:-]*', dev))
            if not physical and ' vlan ' not in link_text:
                path['risks'].append('Тип WAN не подтверждён как физический/операторский: ' + dev)
        if not dev or dev not in devices or tunnel:
            path['risks'].append('Маршрут не подтверждён как прямой WAN: ' + (dev or 'интерфейс не найден'))
        else:
            WAN_INTERFACE = dev
            path['interface'] = dev
        source = marked.get('source', '')
        path['source'] = source
        if source:
            check = route(ip, source=source)
            path['source_route'] = check
            if check.get('interface') != dev or not check.get('ok'):
                path['risks'].append('Маршрут с исходным адресом отличается от ожидаемого WAN')
        else:
            path['risks'].append('Исходный адрес не определён')
    except (OSError, subprocess.TimeoutExpired):
        path['risks'].append('Не удалось полностью проверить маршрутизацию')
    path['direct_ready'] = path['direct_ready'] and not path['risks']
    path['status'] = 'DIRECT' if path['direct_ready'] else 'DIRECT_PATH_UNVERIFIED'
    return marked


def filter_candidates(ip, text, source='', interface=''):
    rows = [shlex.split(line) for line in text.splitlines() if line.startswith('-A ')]
    graph = {}
    for row in rows:
        target = jump_target(row)
        if target:
            graph.setdefault(row[1], set()).add(target)
    results = []
    for root in ('OUTPUT', 'INPUT'):
        reachable = {root}
        for _ in range(64):
            expanded = reachable | set().union(*(graph.get(chain, set()) for chain in reachable))
            if expanded == reachable:
                break
            reachable = expanded
        if any(not graph.get(chain, set()).issubset(reachable) for chain in reachable):
            results.append({'direction': root, 'protocol': 'all', 'ports': '*', 'potential': True, 'rule': 'Граф цепочек слишком глубокий; полный аудит не подтверждён'})
        incoming = root == 'INPUT'
        for row in rows:
            if row[1] not in reachable or jump_target(row) not in ('DROP', 'REJECT'):
                continue
            matches = True
            for flag, address in (('-s', ip if incoming else source), ('-d', source if incoming else ip)):
                if flag in row and address:
                    index = row.index(flag)
                    try:
                        included = ipaddress.ip_address(address) in ipaddress.ip_network(row[index + 1], strict=False)
                    except (ValueError, IndexError):
                        continue
                    if index and row[index - 1] == '!':
                        included = not included
                    if not included:
                        matches = False
            direction = '-i' if incoming else '-o'
            if direction in row and interface:
                value = row[row.index(direction) + 1]
                included = interface.startswith(value[:-1]) if value.endswith('+') else interface == value
                if row.index(direction) and row[row.index(direction) - 1] == '!':
                    included = not included
                if not included:
                    matches = False
            for flag in ('--ctstate', '--state'):
                if flag in row and not (row.index(flag) > 0 and row[row.index(flag) - 1] == '!') and not set(row[row.index(flag) + 1].split(',')) & {'NEW', 'ESTABLISHED', 'UNTRACKED'}:
                    matches = False
            if not matches:
                continue
            port_flag = '--sport' if incoming else '--dport'
            multi_flag = '--sports' if incoming else '--dports'
            ports = row[row.index(port_flag) + 1] if port_flag in row else row[row.index(multi_flag) + 1] if multi_flag in row else '*'
            selected_flag = port_flag if port_flag in row else multi_flag if multi_flag in row else None
            results.append({'direction': root, 'chain': row[1], 'action': jump_target(row), 'protocol': row[row.index('-p') + 1] if '-p' in row else 'all', 'protocol_negated': '-p' in row and row.index('-p') > 0 and row[row.index('-p') - 1] == '!', 'ports': ports, 'ports_negated': bool(selected_flag and row.index(selected_flag) > 0 and row[row.index(selected_flag) - 1] == '!'), 'potential': True, 'rule': clean(' '.join(row))})
        if re.search(r'^:' + root + r'\s+DROP\b', text, re.M):
            results.append({'direction': root, 'chain': root, 'action': 'DROP', 'protocol': 'all', 'ports': '*', 'potential': True, 'rule': 'Политика ' + root + ' DROP; достижимость зависит от разрешающих правил'})
    if len(results) > 32:
        return results[:31] + [{'direction': 'UNKNOWN', 'protocol': 'all', 'ports': '*', 'potential': True, 'rule': 'Список правил сокращён; полный аудит не подтверждён'}]
    return results


def inspect_filter(ip, path):
    binary = 'ip6tables-save' if family(ip) == socket.AF_INET6 else 'iptables-save'
    try:
        response = subprocess.run([binary, '-t', 'filter'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=remaining(2))
        if response.returncode:
            raise OSError('Не удалось прочитать filter')
        if len(response.stdout) > 1048576:
            raise ValueError('Таблица filter слишком большая для полного аудита')
        return {'status': 'OK', 'candidates': filter_candidates(ip, response.stdout.decode('ascii', 'replace')[:1048576], path.get('source', ''), path.get('interface', ''))}
    except (OSError, ValueError, IndexError, subprocess.TimeoutExpired) as exc:
        return {'status': 'UNKNOWN', 'candidates': [], 'detail': clean(str(exc))[:100]}


def filter_affects(candidate, port):
    protocol_matches = candidate.get('protocol') in ('all', 'tcp', '0', '6')
    if candidate.get('protocol_negated'):
        protocol_matches = not protocol_matches
    if not protocol_matches:
        return False
    ports = candidate.get('ports', '*')
    if ports == '*':
        return True
    for value in ports.split(','):
        try:
            if ':' in value:
                start, end = value.split(':', 1)
                if int(start or 0) <= port <= int(end or 65535):
                    return not candidate.get('ports_negated', False)
            elif int(value) == port:
                return not candidate.get('ports_negated', False)
        except ValueError:
            return True
    return candidate.get('ports_negated', False)


def prepare_socket(sock, direct=True):
    try:
        if direct and BYPASS_MARK:
            sock.setsockopt(socket.SOL_SOCKET, getattr(socket, 'SO_MARK', 36), BYPASS_MARK)
        if direct and WAN_INTERFACE:
            sock.setsockopt(socket.SOL_SOCKET, getattr(socket, 'SO_BINDTODEVICE', 25), WAN_INTERFACE.encode('ascii') + b'\0')
    except OSError as exc:
        raise OSError(errno.ENOTSUP, 'Не удалось задать метку/интерфейс прямой пробы') from exc
    return sock


def connect(ip, port, timeout):
    if CANCEL.is_set():
        raise OSError(errno.ECANCELED, 'Проверка отменена')
    deadline = min(END_TIME, time.monotonic() + timeout)
    sock = socket.socket(family(ip), socket.SOCK_STREAM)
    with SOCKET_LOCK:
        ACTIVE_SOCKETS.add(sock)
    guard = None
    try:
        prepare_socket(sock)
        sock.settimeout(remaining(timeout))
        sock.bind(('::' if family(ip) == socket.AF_INET6 else '0.0.0.0', 0))
        guard = FlowGuard(ip, 'tcp', sock.getsockname()[1], port)
        if deadline - time.monotonic() <= 0:
            raise OSError(errno.ENOTSUP, 'Время подготовки прямой TCP-пробы исчерпано')
        sock.settimeout(remaining(deadline - time.monotonic()))
        started = time.monotonic()
        sock.connect((ip, port))
        with SOCKET_LOCK:
            ACTIVE_SOCKETS.add(sock)
        return sock, (time.monotonic() - started) * 1000, guard
    except BaseException:
        sock.close()
        if guard:
            guard.close()
        raise


def clean(value):
    return ''.join(c if not unicodedata.category(c).startswith('C') else '?' for c in str(value))[:500]


def paint(value, color='36;1'):
    value = clean(value)
    return '\033[' + color + 'm' + value + '\033[0m' if COLOR else value


def progress(value):
    if sys.stdout.isatty():
        print('\r\033[2K' + clean(value), end='', flush=True)


def width(value):
    return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ('F', 'W') else 1 for c in value)


def wrap(value, limit):
    lines = []
    for paragraph in str(value).split('\n'):
        part = ''
        for char in clean(paragraph):
            if part and width(part + char) > limit:
                lines.append(part)
                part = ''
            part += char
        lines.append(part)
    return lines


def fit(value, limit):
    value = clean(str(value).replace('\n', ' '))
    if width(value) <= limit:
        return value
    text = ''
    for char in value:
        if width(text + char) > limit - 1:
            break
        text += char
    return text.rstrip() + '…'


def table(headers, rows, sizes, compact=False):
    def border(left, middle, right, horizontal='─'):
        print(paint(left + middle.join(horizontal * (n + 2) for n in sizes) + right, '90'))

    def row(values, color):
        pieces = [[fit(value, size)] if compact else wrap(value, size) for value, size in zip(values, sizes)]
        for line in range(max(map(len, pieces))):
            cells = []
            for i, part in enumerate(pieces):
                text = part[line] if line < len(part) else ''
                text += ' ' * (sizes[i] - width(text))
                cell_color = color[i] if isinstance(color, (list, tuple)) else color if i else '36;1'
                cells.append(' ' + paint(text, cell_color) + ' ')
            print('│' + '│'.join(cells) + '│')
    border('┌', '┬', '┐')
    row(headers, '37;1')
    border('╞', '╪', '╡', '═')
    for values, color in rows:
        row(values, color)
    border('└', '┴', '┘')


def family(ip):
    return socket.AF_INET6 if ipaddress.ip_address(ip).version == 6 else socket.AF_INET


def checksum(data):
    if len(data) % 2:
        data += b'\0'
    total = sum(struct.unpack('!' + 'H' * (len(data) // 2), data))
    while total >> 16:
        total = (total & 65535) + (total >> 16)
    return ~total & 65535


def network_error(exc):
    if isinstance(exc, (socket.timeout, TimeoutError)):
        return 'TIMEOUT'
    return {errno.ECONNREFUSED: 'REFUSED', errno.ENETUNREACH: 'NO ROUTE', errno.EHOSTUNREACH: 'HOST UNREACH', errno.EACCES: 'PROHIBITED', errno.EPERM: 'NO PERMISSION', errno.EMSGSIZE: 'TOO BIG', errno.ECONNRESET: 'RESET', errno.ENOTSUP: 'BYPASS FAIL', errno.ECANCELED: 'CANCELLED'}.get(getattr(exc, 'errno', None), 'NET ERROR')


def route(ip, source=''):
    try:
        command = ['ip', '-6' if family(ip) == socket.AF_INET6 else '-4', 'route', 'get', ip]
        if source:
            command += ['from', source]
        if BYPASS_MARK:
            command += ['mark', hex(BYPASS_MARK)]
        process = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=remaining(3))
        text = process.stdout.decode('utf-8', 'replace').strip().splitlines()
        text = text[0] if text else process.stderr.decode('utf-8', 'replace').strip()
        if process.returncode or not text or any(word in text.lower() for word in ('unreachable', 'prohibit', 'blackhole', 'error -')):
            return {'status': 'NO ROUTE', 'detail': clean(text), 'ok': False}
        fields = text.split()
        return {'status': 'OK', 'detail': clean(text), 'ok': True, 'interface': fields[fields.index('dev') + 1] if 'dev' in fields else '', 'source': fields[fields.index('src') + 1] if 'src' in fields else source, 'gateway': fields[fields.index('via') + 1] if 'via' in fields else '', 'mark': BYPASS_MARK}
    except FileNotFoundError:
        return {'status': 'UNKNOWN', 'detail': 'Команда ip отсутствует', 'ok': None}
    except subprocess.TimeoutExpired:
        return {'status': 'TIMEOUT', 'detail': 'Чтение таблицы маршрутизации', 'ok': None}


def icmp_payload(packet, version):
    if version == 4:
        if len(packet) < 20 or packet[0] >> 4 != 4:
            return b''
        offset = (packet[0] & 15) * 4
        if offset < 20 or len(packet) < offset + 8:
            return b''
        return packet[offset:]
    return packet if len(packet) >= 8 else b''


def quoted_match(data, ip, protocol, source_port, dest_port, sequence):
    version = ipaddress.ip_address(ip).version
    if version == 4:
        if len(data) < 28 or data[0] >> 4 != 4:
            return False
        offset = (data[0] & 15) * 4
        if offset < 20 or len(data) < offset + 8 or data[9] != protocol or data[16:20] != socket.inet_aton(ip) or struct.unpack('!H', data[6:8])[0] & 0x1fff:
            return False
    else:
        if len(data) < 48 or data[0] >> 4 != 6 or data[6] != protocol or data[24:40] != socket.inet_pton(socket.AF_INET6, ip):
            return False
        offset = 40
    payload = data[offset:]
    if protocol in (1, 58):
        return struct.unpack('!HH', payload[4:8]) == (source_port, sequence & 65535)
    if struct.unpack('!HH', payload[:4]) != (source_port, dest_port):
        return False
    return protocol != 6 or struct.unpack('!I', payload[4:8])[0] == sequence


def icmp_event(packet, peer, ip, protocol, source_port, dest_port, sequence):
    version = ipaddress.ip_address(ip).version
    data = icmp_payload(packet, version)
    if len(data) < 8:
        return None
    kind, code = data[:2]
    echo_reply = 0 if version == 4 else 129
    if kind == echo_reply and protocol in (1, 58) and peer == ip and struct.unpack('!HH', data[4:8]) == (source_port, sequence & 65535):
        return {'status': 'ECHO REPLY', 'reached': True, 'ip': peer}
    errors = (3, 11, 12) if version == 4 else (1, 2, 3, 4)
    if kind not in errors or not quoted_match(data[8:], ip, protocol, source_port, dest_port, sequence):
        return None
    prohibited = version == 4 and kind == 3 and code in (9, 10, 13) or version == 6 and kind == 1 and code == 1
    too_big = version == 4 and kind == 3 and code == 4 or version == 6 and kind == 2
    expired = kind == (11 if version == 4 else 3)
    port_closed = version == 4 and kind == 3 and code == 3 or version == 6 and kind == 1 and code == 4
    status = 'PROHIBITED' if prohibited else 'TOO BIG' if too_big else 'TTL EXCEEDED' if expired else 'PORT CLOSED' if port_closed else 'NETWORK UNREACHABLE' if version == 4 and kind == 3 and code == 0 else 'HOST UNREACHABLE' if version == 4 and kind == 3 and code == 1 else 'UNREACHABLE'
    result = {'status': status, 'reached': peer == ip and port_closed, 'ip': peer, 'code': code}
    if too_big:
        result['mtu'] = struct.unpack('!H', data[6:8])[0] if version == 4 else struct.unpack('!I', data[4:8])[0]
    return result


def echo(ip, size=56, count=3, df=False, timeout=2):
    version = ipaddress.ip_address(ip).version
    protocol = socket.IPPROTO_ICMP if version == 4 else socket.IPPROTO_ICMPV6
    ident = secrets.randbelow(65535) + 1
    result = {'status': 'TIMEOUT', 'sent': 0, 'received': 0, 'rtts': [], 'size': size, 'events': []}
    try:
        with socket.socket(family(ip), socket.SOCK_RAW, protocol) as sock:
            prepare_socket(sock)
            if df and version == 4:
                sock.setsockopt(socket.IPPROTO_IP, 10, 2)
            elif df and version == 6:
                sock.setsockopt(socket.IPPROTO_IPV6, getattr(socket, 'IPV6_DONTFRAG', 62), 1)
            for sequence in range(count):
                if CANCEL.is_set():
                    break
                head = struct.pack('!BBHHH', 8 if version == 4 else 128, 0, 0, ident, sequence)
                data = (b'Xmenu server diagnostic ' * (size // 24 + 2))[:size]
                packet = head + data
                if version == 4:
                    packet = packet[:2] + struct.pack('!H', checksum(packet)) + packet[4:]
                started = time.monotonic()
                sock.sendto(packet, (ip, 0))
                result['sent'] += 1
                deadline = started + remaining(timeout)
                while time.monotonic() < deadline:
                    ready, _, _ = select.select([sock], [], [], max(0, deadline - time.monotonic()))
                    if not ready:
                        break
                    incoming, peer = sock.recvfrom(65535)
                    event = icmp_event(incoming, peer[0], ip, protocol, ident, 0, sequence)
                    if not event:
                        continue
                    result['events'].append(event)
                    if event['status'] == 'ECHO REPLY':
                        result['received'] += 1
                        result['rtts'].append((time.monotonic() - started) * 1000)
                    else:
                        result['status'] = event['status']
                    break
        if result['received']:
            result['status'] = 'OK' if result['received'] == count else 'PARTIAL'
    except OSError as exc:
        result['status'] = network_error(exc)
    values = result['rtts']
    result.update(min_ms=min(values) if values else None, avg_ms=statistics.mean(values) if values else None, max_ms=max(values) if values else None, loss_percent=100 * (result['sent'] - result['received']) / result['sent'] if result['sent'] else None, unstable=bool(len(values) > 1 and max(values) - min(values) > max(20, min(values) * 2) or 0 < result['received'] < result['sent']))
    return result


def timestamp_reply(data, peer, ip, ident, sequence, original):
    if peer != ip or len(data) != 20 or data[:2] != b'\x0e\0' or checksum(data) != 0:
        return None
    received_ident, received_sequence, echoed, received, transmitted = struct.unpack('!HHIII', data[4:20])
    if (received_ident, received_sequence, echoed) != (ident, sequence, original):
        return None
    return {'status': 'TIMESTAMP REPLY', 'reachable': True, 'received_timestamp': received, 'transmit_timestamp': transmitted}


def timestamp_probe(ip, timeout=1):
    if family(ip) != socket.AF_INET:
        return {'status': 'SKIPPED', 'reachable': False, 'detail': 'ICMP Timestamp существует только для IPv4'}
    ident = secrets.randbelow(65535) + 1
    result = {'status': 'NO REPLY', 'reachable': False, 'attempts': [], 'ms': None}
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP) as sock:
            prepare_socket(sock)
            for sequence in range(2):
                original = int(time.time() * 1000) % 86400000
                packet = struct.pack('!BBHHHIII', 13, 0, 0, ident, sequence, original, 0, 0)
                packet = packet[:2] + struct.pack('!H', checksum(packet)) + packet[4:]
                duration = remaining(timeout)
                started = time.monotonic()
                sock.sendto(packet, (ip, 0))
                deadline = started + duration
                while time.monotonic() < deadline and not CANCEL.is_set():
                    ready, _, _ = select.select([sock], [], [], max(0, deadline - time.monotonic()))
                    if not ready:
                        break
                    incoming, peer = sock.recvfrom(65535)
                    answer = timestamp_reply(icmp_payload(incoming, 4), peer[0], ip, ident, sequence, original)
                    if answer:
                        answer['ms'] = (time.monotonic() - started) * 1000
                        result['attempts'].append(answer)
                        result.update(answer)
                        return result
                result['attempts'].append({'status': 'NO REPLY'})
        return result
    except OSError as exc:
        result['status'] = network_error(exc)
        return result


def tcp(ip, port, timeout=4):
    guard = None
    try:
        sock, elapsed, guard = connect(ip, port, timeout)
        with sock:
            return {'status': 'OPEN', 'ms': elapsed, 'port': port, 'source': sock.getsockname()[0], 'peer': sock.getpeername()[0]}
    except OSError as exc:
        return {'status': network_error(exc), 'ms': None, 'port': port}
    finally:
        if guard:
            guard.close()


def tcp_discovery(ip, port, attempts=2, timeout=2):
    samples = []
    for _ in range(attempts):
        if CANCEL.is_set() or END_TIME - time.monotonic() < .1:
            break
        sample = tcp(ip, port, remaining(timeout))
        sample['at'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        samples.append(sample)
        if samples[-1]['status'] in ('OPEN', 'REFUSED', 'NO ROUTE', 'NO PERMISSION', 'BYPASS FAIL'):
            break
        if len(samples) < attempts:
            CANCEL.wait(.15)
    if not samples:
        return {'status': 'SKIPPED', 'port_state': 'UNKNOWN', 'ms': None, 'port': port, 'attempts': []}
    chosen = next((v for v in samples if v['status'] == 'OPEN'), samples[-1])
    state = {'OPEN': 'OPEN', 'REFUSED': 'CLOSED', 'RESET': 'CLOSED', 'TIMEOUT': 'FILTERED', 'PROHIBITED': 'FILTERED'}.get(chosen['status'], 'ERROR' if chosen['status'] in ('NET ERROR', 'NO PERMISSION', 'BYPASS FAIL') else 'UNKNOWN')
    return dict(chosen, port_state=state, attempts=samples, unstable=len({s['status'] for s in samples}) > 1)


def tcp_recheck(ip, port, previous):
    samples = []
    for index in range(3):
        if index and CANCEL.wait(.75 * index):
            break
        if CANCEL.is_set() or END_TIME - time.monotonic() < .1:
            break
        value = tcp_discovery(ip, port, 1, 2)
        samples += value.get('attempts', [])
        if value['status'] in ('OPEN', 'REFUSED', 'BYPASS FAIL', 'NO PERMISSION'):
            break
    if not samples:
        return dict(previous, external_recheck=False, recheck_incomplete=True)
    value = dict(samples[-1]) if samples else {'status': 'SKIPPED', 'ms': None, 'port': port, 'port_state': 'UNKNOWN'}
    value['port_state'] = {'OPEN': 'OPEN', 'REFUSED': 'CLOSED', 'RESET': 'CLOSED', 'TIMEOUT': 'FILTERED', 'PROHIBITED': 'FILTERED'}.get(value['status'], 'UNKNOWN')
    value['attempts'] = samples
    history = previous.get('attempts', []) + value.get('attempts', [])
    value.update(attempts=history[-8:], unstable=len({s['status'] for s in history}) > 1, external_recheck=True)
    return value


def quic_probe_packet():
    dcid, scid = secrets.token_bytes(8), secrets.token_bytes(8)
    version = 0x1a2a3a4a
    header = b'\xc0' + struct.pack('!I', version) + bytes([len(dcid)]) + dcid + bytes([len(scid)]) + scid
    return header + secrets.token_bytes(1200 - len(header)), dcid, scid, version


def quic_versions(data, dcid, scid, version):
    if len(data) < 7 or not data[0] & 0x80 or data[1:5] != b'\0\0\0\0':
        return None
    offset = 5
    length = data[offset]
    offset += 1
    destination = data[offset:offset + length]
    offset += length
    if offset >= len(data):
        return None
    length = data[offset]
    offset += 1
    source = data[offset:offset + length]
    offset += length
    tail = data[offset:]
    if destination != scid or source != dcid or not tail or len(tail) % 4:
        return None
    versions = [struct.unpack('!I', tail[i:i + 4])[0] for i in range(0, len(tail), 4)]
    if 0 in versions or version in versions:
        return None
    return versions


def udp(ip, port, timeout=3, quic=None):
    started = time.monotonic()
    guard = None
    try:
        with socket.socket(family(ip), socket.SOCK_DGRAM) as sock:
            prepare_socket(sock)
            sock.settimeout(remaining(timeout))
            sock.bind(('::' if family(ip) == socket.AF_INET6 else '0.0.0.0', 0))
            guard = FlowGuard(ip, 'udp', sock.getsockname()[1], port)
            sock.connect((ip, port))
            started = time.monotonic()
            if not (port == 443 if quic is None else quic):
                sock.send(b'Xmenu connectivity probe\r\n')
                data = sock.recv(2048)
                return {'status': 'REPLY', 'ms': (time.monotonic() - started) * 1000, 'port': port, 'bytes': len(data), 'reachable': True}
            packet, dcid, scid, version = quic_probe_packet()
            deadline = started + remaining(timeout)
            attempts = 0
            while attempts < 3 and time.monotonic() < deadline:
                if CANCEL.is_set():
                    raise OSError(errno.ECANCELED, 'Проверка отменена')
                sent = time.monotonic()
                sock.send(packet)
                attempts += 1
                window = min(deadline, sent + .666 * 2 ** (attempts - 1))
                while time.monotonic() < window:
                    sock.settimeout(max(.001, window - time.monotonic()))
                    try:
                        data = sock.recv(2048)
                    except (TimeoutError, socket.timeout):
                        break
                    versions = quic_versions(data, dcid, scid, version)
                    if versions:
                        return {'status': 'QUIC VN', 'ms': (time.monotonic() - sent) * 1000 if attempts == 1 else None, 'attempts': attempts, 'port': port, 'reachable': True, 'versions': versions, 'detail': 'UDP/443 отвечает на QUIC-пробу; полный QUIC/TLS-сеанс не проверялся'}
                    if data[1:5] != b'\0\0\0\0' or not data or not data[0] & 0x80:
                        return {'status': 'REPLY', 'ms': (time.monotonic() - sent) * 1000 if attempts == 1 else None, 'attempts': attempts, 'port': port, 'reachable': True, 'detail': 'Получен UDP-ответ; протокол QUIC не подтвержден'}
            return {'status': 'NO REPLY', 'ms': None, 'port': port, 'reachable': False, 'detail': 'Нет ответа на QUIC-пробы. Отсутствие QUIC-сервиса и фильтрация не различимы'}
    except OSError as exc:
        return {'status': 'NO REPLY' if isinstance(exc, (TimeoutError, socket.timeout)) else 'PORT CLOSED' if getattr(exc, 'errno', None) == errno.ECONNREFUSED else network_error(exc), 'ms': None, 'port': port}
    finally:
        if guard:
            guard.close()


def ssh_banner(ip, port=22):
    guard = None
    connected = False
    try:
        sock, elapsed, guard = connect(ip, port, 4)
        connected = True
        with sock:
            sock.settimeout(remaining(3))
            data = sock.recv(512)
            text = clean(data.split(b'\n', 1)[0].decode('ascii', 'replace')).strip()
            return {'status': 'SSH' if text.startswith('SSH-') else 'REPLY' if data else 'EOF', 'detail': text, 'tcp_open': True}
    except OSError as exc:
        return {'status': network_error(exc), 'detail': '', 'tcp_open': connected}
    finally:
        if guard:
            guard.close()


def banner_probe(ip, port):
    guard = None
    connected = False
    try:
        sock, elapsed, guard = connect(ip, port, remaining(2))
        connected = True
        with sock:
            sock.settimeout(remaining(1))
            data = sock.recv(256)
            line = clean(data.split(b'\n', 1)[0].decode('ascii', 'replace')).strip()
            protocol = 'SSH' if line.startswith('SSH-') else 'SMTP' if line.startswith('220') and 'SMTP' in line.upper() else 'FTP' if line.startswith('220') and 'FTP' in line.upper() else 'HTTP' if line.startswith('HTTP/') else 'UNKNOWN'
            return {'status': 'BANNER REPLY' if data else 'EOF', 'tcp_open': True, 'protocol': protocol, 'banner': line, 'ms': elapsed, 'port': port}
    except OSError as exc:
        return {'status': network_error(exc), 'tcp_open': connected, 'protocol': 'UNKNOWN', 'port': port}
    finally:
        if guard:
            guard.close()


def http_probe(ip, port, secure=False, sni=''):
    sock = None
    guard = None
    stage = 'TCP'
    try:
        sock, elapsed, guard = connect(ip, port, 4)
        sock.settimeout(remaining(5))
        if secure:
            stage = 'TLS'
            sock = ssl.create_default_context().wrap_socket(sock, server_hostname=sni or ip)
            with SOCKET_LOCK:
                ACTIVE_SOCKETS.add(sock)
        stage = 'HTTP'
        host = sni or ('[' + ip + ']' if family(ip) == socket.AF_INET6 else ip)
        sock.settimeout(remaining(5))
        sock.sendall(('HEAD / HTTP/1.1\r\nHost: ' + host + '\r\nConnection: close\r\n\r\n').encode('ascii'))
        data = sock.recv(4096)
        match = re.match(rb'HTTP/\d(?:\.\d)?\s+(\d{3})', data)
        return {'status': 'HTTP ' + match[1].decode() if match else 'REPLY' if data else 'EOF', 'detail': 'TLS проверен' if secure else 'Сервер ответил без TLS', 'reachable': bool(data)}
    except ssl.SSLCertVerificationError:
        return {'status': 'TLS CERT', 'detail': 'TLS отвечает; сертификат не подтверждён для ' + (sni or 'IP'), 'reachable': True}
    except ssl.SSLError as exc:
        return {'status': 'TLS ALERT' if 'alert' in str(exc).lower() else 'TLS ERROR', 'detail': clean(str(exc))[:80], 'reachable': False}
    except OSError as exc:
        error = network_error(exc)
        return {'status': 'TLS DROP' if stage == 'TLS' and error == 'TIMEOUT' else error, 'detail': 'Этап: ' + stage, 'reachable': False}
    finally:
        if sock:
            sock.close()
        if guard:
            guard.close()


def tcp_packet(source, target, source_port, dest_port, sequence):
    header = struct.pack('!HHIIBBHHH', source_port, dest_port, sequence, 0, 5 << 4, 2, 64240, 0, 0)
    version = ipaddress.ip_address(target).version
    if version == 4:
        pseudo = socket.inet_aton(source) + socket.inet_aton(target) + struct.pack('!BBH', 0, 6, len(header))
    else:
        pseudo = socket.inet_pton(socket.AF_INET6, source) + socket.inet_pton(socket.AF_INET6, target) + struct.pack('!I3xB', len(header), 6)
    return header[:16] + struct.pack('!H', checksum(pseudo + header)) + header[18:]


def tcp_event(data, peer, ip, source_port, dest_port, sequence):
    if peer != ip:
        return None
    if family(ip) == socket.AF_INET:
        if len(data) < 40 or data[0] >> 4 != 4:
            return None
        offset = (data[0] & 15) * 4
        if offset < 20 or len(data) < offset + 20:
            return None
        data = data[offset:]
    if len(data) < 20:
        return None
    sport, dport, seq, ack = struct.unpack('!HHII', data[:12])
    if (sport, dport, ack) != (dest_port, source_port, (sequence + 1) & 0xffffffff):
        return None
    flags = data[13]
    if flags & 4:
        return {'status': 'RST', 'reached': True, 'ip': peer}
    if flags & 0x12 == 0x12:
        return {'status': 'SYN/ACK', 'reached': True, 'ip': peer}
    return None


def trace(ip, mode, hops=24, port=443, timeout=1, start_ttl=1):
    version = ipaddress.ip_address(ip).version
    icmp_protocol = socket.IPPROTO_ICMP if version == 4 else socket.IPPROTO_ICMPV6
    protocol = icmp_protocol if mode == 'ICMP' else 17 if mode == 'UDP' else 6
    source_port = secrets.randbelow(20000) + 40000
    seq_base = secrets.randbelow(0xffff0000)
    result = {'mode': mode, 'hops': [], 'reached': False, 'status': 'NO REPLY'}
    sender = receiver = tcp_receiver = reservation = guard = None
    try:
        with socket.socket(family(ip), socket.SOCK_DGRAM) as local:
            prepare_socket(local)
            local.connect((ip, port))
            source = local.getsockname()[0]
        receiver = socket.socket(family(ip), socket.SOCK_RAW, icmp_protocol)
        if mode == 'ICMP':
            sender = socket.socket(family(ip), socket.SOCK_RAW, icmp_protocol)
        elif mode == 'UDP':
            sender = socket.socket(family(ip), socket.SOCK_DGRAM)
            sender.bind((source, 0))
            source_port = sender.getsockname()[1]
        else:
            reservation = socket.socket(family(ip), socket.SOCK_STREAM)
            reservation.bind((source, 0))
            source_port = reservation.getsockname()[1]
            guard = FlowGuard(ip, 'tcp', source_port, port)
            sender = socket.socket(family(ip), socket.SOCK_RAW, socket.IPPROTO_TCP)
            sender.bind((source, 0))
            tcp_receiver = socket.socket(family(ip), socket.SOCK_RAW, socket.IPPROTO_TCP)
        prepare_socket(sender)
        watches = [receiver] + ([tcp_receiver] if tcp_receiver else [])
        for ttl in range(start_ttl, hops + 1):
            if CANCEL.is_set():
                result['status'] = 'CANCELLED'
                break
            sender.setsockopt(socket.IPPROTO_IP if version == 4 else socket.IPPROTO_IPV6, socket.IP_TTL if version == 4 else socket.IPV6_UNICAST_HOPS, ttl)
            sequence = (seq_base + ttl) & 0xffffffff
            dest_port = 33434 + ttl if mode == 'UDP' else port
            if mode == 'ICMP':
                packet = struct.pack('!BBHHH', 8 if version == 4 else 128, 0, 0, source_port, sequence & 65535) + b'Xmenu trace'
                if version == 4:
                    packet = packet[:2] + struct.pack('!H', checksum(packet)) + packet[4:]
            elif mode == 'UDP':
                packet = b'Xmenu trace'
            else:
                packet = tcp_packet(source, ip, source_port, port, sequence)
            started = time.monotonic()
            sender.sendto(packet, (ip, dest_port if mode == 'UDP' else 0))
            event = None
            deadline = started + remaining(timeout)
            while time.monotonic() < deadline:
                ready, _, _ = select.select(watches, [], [], max(0, deadline - time.monotonic()))
                if not ready:
                    break
                for sock in ready:
                    data, peer = sock.recvfrom(65535)
                    event = tcp_event(data, peer[0], ip, source_port, port, sequence) if sock is tcp_receiver else icmp_event(data, peer[0], ip, protocol, source_port, dest_port, sequence)
                    if event:
                        break
                if event:
                    break
            if event:
                event.update(ttl=ttl, ms=(time.monotonic() - started) * 1000)
                result['hops'].append(event)
                if event['reached'] or event['status'] in ('PROHIBITED', 'UNREACHABLE', 'NETWORK UNREACHABLE', 'HOST UNREACHABLE'):
                    result.update(reached=event['reached'], status=event['status'])
                    break
            else:
                result['hops'].append({'ttl': ttl, 'ip': '', 'ms': None, 'status': '*', 'reached': False})
        return result
    except OSError as exc:
        result['status'] = network_error(exc)
        return result
    finally:
        for sock in (sender, receiver, tcp_receiver, reservation):
            if sock:
                sock.close()
        if guard:
            guard.close()


def syn_probe(ip, port):
    value = trace(ip, 'TCP', 64, port, 1.5, start_ttl=64)
    state = {'SYN/ACK': 'OPEN', 'RST': 'CLOSED', 'PROHIBITED': 'FILTERED', 'NO REPLY': 'FILTERED', 'NO PERMISSION': 'SKIPPED'}.get(value['status'], 'UNKNOWN')
    return {'status': value['status'], 'port_state': state, 'port': port, 'hops': value['hops']}


def parse_stun(data, transaction):
    if len(data) < 20 or len(transaction) != 12:
        return None
    kind, size, cookie = struct.unpack('!HHI', data[:8])
    if kind not in (0x0101, 0x0111) or cookie != 0x2112a442 or data[8:20] != transaction or size % 4 or len(data) != size + 20:
        return None
    result = {'status': 'STUN REPLY', 'reachable': True}
    offset = 20
    while offset < len(data):
        if offset + 4 > len(data):
            return None
        attribute, length = struct.unpack('!HH', data[offset:offset + 4])
        end = offset + 4 + length
        if end > len(data):
            return None
        value = data[offset + 4:end]
        if attribute == 0x0020:
            if len(value) not in (8, 20) or value[0] != 0 or (value[1], len(value)) not in ((1, 8), (2, 20)):
                return None
            mask = struct.pack('!I', cookie) + transaction
            decoded = bytes(a ^ b for a, b in zip(value[4:], mask))
            result['mapped_address'] = socket.inet_ntop(socket.AF_INET if value[1] == 1 else socket.AF_INET6, decoded)
            result['mapped_port'] = struct.unpack('!H', value[2:4])[0] ^ 0x2112
        elif attribute == 9:
            if len(value) < 4 or value[:2] != b'\0\0' or value[2] & 0xf8 or not 300 <= value[2] * 100 + value[3] <= 699 or value[3] > 99:
                return None
            result['error_code'] = value[2] * 100 + value[3]
        elif attribute == 0x8028:
            if length != 4 or end != len(data) or struct.unpack('!I', value)[0] != (zlib.crc32(data[:offset]) ^ 0x5354554e):
                return None
        offset = end + (-length % 4)
    if offset != len(data) or kind == 0x0101 and 'mapped_address' not in result or kind == 0x0111 and 'error_code' not in result:
        return None
    return result


def stun_probe(ip, port=3478, timeout=2):
    transaction = secrets.token_bytes(12)
    packet = struct.pack('!HHI', 1, 0, 0x2112a442) + transaction
    guard = None
    try:
        with socket.socket(family(ip), socket.SOCK_DGRAM) as sock:
            prepare_socket(sock)
            sock.bind(('::' if family(ip) == socket.AF_INET6 else '0.0.0.0', 0))
            guard = FlowGuard(ip, 'udp', sock.getsockname()[1], port)
            sock.connect((ip, port))
            deadline = time.monotonic() + remaining(timeout)
            started = time.monotonic()
            sock.send(packet)
            while time.monotonic() < deadline:
                sock.settimeout(remaining(max(.001, deadline - time.monotonic())))
                answer = parse_stun(sock.recv(2048), transaction)
                if answer:
                    return dict(answer, ms=(time.monotonic() - started) * 1000, port=port, port_state='OPEN', detail='STUN ответил' + ('; код ' + str(answer['error_code']) if 'error_code' in answer else ''))
            raise TimeoutError()
    except OSError as exc:
        status = 'PORT CLOSED' if getattr(exc, 'errno', None) == errno.ECONNREFUSED else 'NO REPLY' if isinstance(exc, TimeoutError) else network_error(exc)
        return {'status': status, 'port_state': 'CLOSED' if status == 'PORT CLOSED' else 'OPEN_FILTERED' if status == 'NO REPLY' else 'UNKNOWN', 'reachable': False, 'ms': None, 'port': port, 'detail': 'STUN-сервис не подтвердил ответ'}
    finally:
        if guard:
            guard.close()


def udp_service(ip, port, timeout=2):
    if port == 3478:
        return stun_probe(ip, port, timeout)
    if port == 443:
        value = udp(ip, port, remaining(timeout))
        value['port_state'] = 'OPEN' if value.get('reachable') else 'CLOSED' if value['status'] == 'PORT CLOSED' else 'OPEN_FILTERED' if value['status'] == 'NO REPLY' else 'UNKNOWN'
        return value
    if port not in (53, 123):
        return {'status': 'INCONCLUSIVE', 'port_state': 'UNKNOWN', 'port': port, 'ms': None, 'detail': 'Без параметров IKE/WireGuard достоверная протокольная проба невозможна', 'reachable': False}
    guard = None
    transaction = secrets.token_bytes(2)
    ntp_stamp = secrets.token_bytes(8)
    packet = transaction + b'\x01\0\0\x01\0\0\0\0\0\0\0\0\x02\0\x01' if port == 53 else b'\x23' + b'\0' * 39 + ntp_stamp
    try:
        with socket.socket(family(ip), socket.SOCK_DGRAM) as sock:
            prepare_socket(sock)
            sock.settimeout(remaining(timeout))
            sock.bind(('::' if family(ip) == socket.AF_INET6 else '0.0.0.0', 0))
            guard = FlowGuard(ip, 'udp', sock.getsockname()[1], port)
            sock.connect((ip, port))
            started = time.monotonic()
            sock.send(packet)
            deadline = started + remaining(timeout)
            while time.monotonic() < deadline:
                sock.settimeout(remaining(max(.001, deadline - time.monotonic())))
                data = sock.recv(2048)
                valid = len(data) >= 12 and data[:2] == transaction and bool(data[2] & 128) and data[2] & 0x78 == 0 if port == 53 else len(data) >= 48 and data[0] & 7 == 4 and data[24:32] == ntp_stamp and data[1] <= 15
                if valid:
                    return {'status': 'REPLY', 'port_state': 'OPEN', 'port': port, 'ms': (time.monotonic() - started) * 1000, 'reachable': True, 'detail': 'Подтверждён ответ DNS' if port == 53 else 'Подтверждён ответ NTP'}
            raise socket.timeout()
    except OSError as exc:
        status = 'PORT CLOSED' if getattr(exc, 'errno', None) == errno.ECONNREFUSED else 'NO REPLY' if isinstance(exc, TimeoutError) else network_error(exc)
        return {'status': status, 'port_state': 'CLOSED' if status == 'PORT CLOSED' else 'OPEN_FILTERED' if status == 'NO REPLY' else 'UNKNOWN', 'port': port, 'ms': None, 'reachable': False, 'detail': 'ICMP: порт недоступен' if status == 'PORT CLOSED' else 'Нет подтверждённого ответа; UDP-сервис может отсутствовать'}
    finally:
        if guard:
            guard.close()


def tls_probe(ip, port, version, timeout=2):
    sock = guard = None
    connected = False
    started = time.monotonic()
    try:
        sock, elapsed, guard = connect(ip, port, remaining(timeout))
        connected = True
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        context.minimum_version = context.maximum_version = version
        sock.settimeout(remaining(timeout))
        sock = context.wrap_socket(sock, server_hostname=None)
        with SOCKET_LOCK:
            ACTIVE_SOCKETS.add(sock)
        return {'status': 'TLS OK', 'tcp_open': True, 'protocol': sock.version(), 'ms': (time.monotonic() - started) * 1000, 'detail': 'Handshake без SNI; подлинность сертификата этой пробой не проверяется'}
    except ssl.SSLError as exc:
        if CANCEL.is_set() or time.monotonic() >= END_TIME:
            return {'status': 'CANCELLED', 'tcp_open': connected, 'detail': 'TLS-проверка остановлена'}
        return {'status': 'PROTOCOL_FAILURE', 'tcp_open': connected, 'error': 'TLS ALERT' if 'alert' in str(exc).lower() else 'TLS ERROR', 'detail': clean(str(exc))[:120]}
    except OSError as exc:
        if getattr(exc, 'errno', None) == errno.ECANCELED or CANCEL.is_set() or time.monotonic() >= END_TIME:
            return {'status': 'CANCELLED', 'tcp_open': connected, 'detail': 'TLS-проверка остановлена'}
        return {'status': 'PROTOCOL_FAILURE' if connected else network_error(exc), 'tcp_open': connected, 'error': network_error(exc), 'phase': 'TLS ClientHello' if connected else 'TCP Connect', 'reset_after_connect': connected and getattr(exc, 'errno', None) == errno.ECONNRESET, 'detail': 'Ошибка после TCP Connect' if connected else 'TCP Connect не установлен'}
    finally:
        if sock:
            sock.close()
        if guard:
            guard.close()


def tls_confirm(ip, port, version):
    first = tls_probe(ip, port, version)
    if first['status'] != 'PROTOCOL_FAILURE' or END_TIME - time.monotonic() < 2 or CANCEL.is_set():
        return dict(first, attempts=[first])
    second = tls_probe(ip, port, version)
    return dict(second, attempts=[first, second], unstable=first['status'] != second['status'])


class ApiHTTPError(OSError):
    def __init__(self, status):
        self.status = status
        super().__init__('HTTP API ' + str(status))


def fetch_json(url, timeout=6, payload=None):
    parsed = urllib.parse.urlsplit(url)
    timeout = remaining(timeout)
    call_deadline = min(END_TIME, time.monotonic() + timeout)
    def budget(limit=timeout):
        value = min(limit, call_deadline - time.monotonic())
        if value <= 0:
            raise TimeoutError('Лимит времени запроса API')
        return remaining(value)
    if parsed.scheme != 'https' or parsed.hostname not in ('check-host.net', 'stat.ripe.net', 'api.globalping.io', 'internetdb.shodan.io') or parsed.username or parsed.password or parsed.port not in (None, 443) or parsed.fragment:
        raise ValueError('Неподдерживаемый API')
    ip = API_ADDRESSES.get(parsed.hostname)
    if not ip:
        lookup = subprocess.run(['nslookup', parsed.hostname], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=budget(3))
        addresses = []
        answer = False
        for line in lookup.stdout.decode('ascii', 'replace').splitlines():
            if line.startswith(('Name:', 'Non-authoritative answer:')):
                answer = True
            if answer and line.startswith('Address'):
                for value in line.split()[1:]:
                    try:
                        address = ipaddress.ip_address(value)
                        if address.is_global:
                            addresses.append(address)
                    except ValueError:
                        pass
        if not addresses:
            raise OSError('DNS API не ответил')
        ip = str(sorted(addresses, key=lambda item: item.version)[0])
        API_ADDRESSES[parsed.hostname] = ip
    sock = guard = timer = response = None
    try:
        sock, elapsed, guard = connect(ip, 443, budget(3))
        sock.settimeout(budget())
        sock = ssl.create_default_context().wrap_socket(sock, server_hostname=parsed.hostname)
        with SOCKET_LOCK:
            ACTIVE_SOCKETS.add(sock)
        def interrupt():
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        timer = threading.Timer(budget(), interrupt)
        timer.daemon = True
        timer.start()
        path = urllib.parse.urlunsplit(('', '', parsed.path or '/', parsed.query, ''))
        data = json.dumps(payload).encode('utf-8') if payload is not None else b''
        headers = ('POST' if payload is not None else 'GET') + ' ' + path + ' HTTP/1.1\r\nHost: ' + parsed.hostname + '\r\nAccept: application/json\r\nUser-Agent: Xmenu/1.4.4\r\nConnection: close\r\n'
        if payload is not None:
            headers += 'Content-Type: application/json\r\nContent-Length: ' + str(len(data)) + '\r\n'
        sock.sendall((headers + '\r\n').encode('ascii') + data)
        response = http.client.HTTPResponse(sock)
        response.begin()
        if response.status not in (200, 202):
            raise ApiHTTPError(response.status)
        data = response.read(1048577)
        if len(data) > 1048576:
            raise ValueError('Ответ API слишком большой')
        try:
            decoded = json.loads(data)
        except RecursionError as exc:
            raise ValueError('Слишком глубокий JSON API') from exc
        if not isinstance(decoded, dict):
            raise ValueError('Неверный формат JSON API')
        return decoded
    except http.client.HTTPException as exc:
        raise OSError('Некорректный ответ HTTP API') from exc
    finally:
        if timer:
            timer.cancel()
        if response:
            response.close()
        if sock:
            sock.close()
        if guard:
            guard.close()


def parse_discovery(ip, data):
    if not isinstance(data, dict) or data.get('ip') != ip or not isinstance(data.get('ports'), list) or len(data['ports']) > 256:
        raise ValueError('Некорректный ответ InternetDB')
    ports = data['ports']
    if any(not isinstance(p, int) or isinstance(p, bool) or not 1 <= p <= 65535 for p in ports):
        raise ValueError('Некорректный порт InternetDB')
    hostnames = data.get('hostnames', [])
    if not isinstance(hostnames, list):
        raise ValueError('Некорректные имена InternetDB')
    names = [name for name in hostnames[:16] if isinstance(name, str) and len(name) <= 253 and re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?', name) and '..' not in name]
    return {'status': 'FOUND' if ports else 'NO DATA', 'ports': sorted(set(ports)), 'hostnames': names, 'source': 'Shodan InternetDB', 'historical': True, 'transport': 'unspecified', 'queried_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'detail': 'Исторические наблюдения; доступность проверяется отдельно'}


def discover_ports(ip):
    try:
        return parse_discovery(ip, fetch_json('https://internetdb.shodan.io/' + urllib.parse.quote(ip, safe=':'), timeout=4))
    except ApiHTTPError as exc:
        return {'status': 'NO DATA' if exc.status == 404 else 'API ERROR', 'ports': [], 'detail': 'Нет записи InternetDB' if exc.status == 404 else clean(str(exc))}
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        return {'status': 'API ERROR', 'ports': [], 'detail': clean(str(exc))[:120]}


def discovery_targets(discovery, local):
    available = [p for p in discovery.get('ports', []) if p not in local or local[p]['status'] == 'SKIPPED']
    available.sort(key=lambda p: (p in DEFAULT_PORTS, p))
    chosen = []
    count = len(local)
    for port in available:
        if port not in local:
            if count >= MAX_TOTAL_PORTS:
                continue
            count += 1
        chosen.append(port)
        if len(chosen) == MAX_DISCOVERY_PORTS:
            break
    return chosen


def comparison_ports(ports):
    values = [443, 22]
    for port in ports:
        if isinstance(port, int) and not isinstance(port, bool) and 1 <= port <= 65535 and port not in values:
            values.append(port)
            break
    return values


def bgp(ip):
    if not ipaddress.ip_address(ip).is_global:
        return {'status': 'NO DATA', 'detail': 'ASN не подтвержден: адрес не является публичным'}
    try:
        network = fetch_json('https://stat.ripe.net/data/network-info/data.json?resource=' + urllib.parse.quote(ip, safe=''))
        prefix = network.get('data', {}).get('prefix')
        if not prefix:
            return {'status': 'NO DATA', 'detail': 'ASN не подтвержден: префикс IP не найден'}
        prefix = str(ipaddress.ip_network(prefix, strict=True))
        if ipaddress.ip_address(ip) not in ipaddress.ip_network(prefix):
            raise ValueError('RIPEstat вернул префикс другого IP')
        data = fetch_json('https://stat.ripe.net/data/prefix-overview/data.json?resource=' + urllib.parse.quote(prefix, safe='')).get('data', {})
        announced = data.get('announced')
        asns = [v for v in data.get('asns', []) if str(v.get('asn', '')).isdigit() and int(v['asn']) > 0]
        owners = ', '.join('AS' + str(v['asn']) + (' · ' + str(v['holder']) if v.get('holder') else '') for v in asns)
        detail = prefix + ' · ' + (owners or 'ASN не подтвержден')
        return {'status': 'ANNOUNCED' if announced is True and asns else 'NOT ANNOUNCED' if announced is False else 'NO DATA', 'detail': clean(detail), 'prefix': prefix, 'asns': [{'asn': int(v['asn']), 'holder': clean(v.get('holder', ''))} for v in asns]}
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {'status': 'NO DATA', 'detail': 'ASN не подтвержден: сервис RIPEstat недоступен'}


def parse_visibility(data, prefix):
    if not isinstance(data, dict) or data.get('resource') != prefix:
        raise ValueError('RIPEstat: неверный ресурс маршрута')
    version = ipaddress.ip_network(prefix).version
    visibility = data.get('visibility', {}).get('v' + str(version), {})
    seen, total = visibility.get('ris_peers_seeing'), visibility.get('total_ris_peers')
    if any(not isinstance(v, int) or isinstance(v, bool) for v in (seen, total)) or not 0 <= seen <= total or total <= 0:
        raise ValueError('RIPEstat: некорректные счётчики RIS')
    observed = data.get('query_time')
    age = None
    if isinstance(observed, str):
        try:
            stamp = datetime.datetime.fromisoformat(observed.replace('Z', '+00:00'))
            if stamp.tzinfo is None:
                stamp = stamp.replace(tzinfo=datetime.timezone.utc)
            age = time.time() - stamp.timestamp()
        except ValueError:
            observed = None
    origins = []
    raw_origins = data.get('origins', [])
    if not isinstance(raw_origins, list):
        raise ValueError('RIPEstat: некорректные origin ASN')
    for value in raw_origins[:32]:
        raw = value.get('origin') if isinstance(value, dict) else None
        if isinstance(raw, (str, int)) and not isinstance(raw, bool) and str(raw).isdigit() and 0 < int(raw) <= 4294967295:
            origins.append(int(raw))
    stale = age is None or age < -300 or age > 86400
    return {'status': 'VISIBLE' if seen else 'NOT VISIBLE', 'peers_seen': seen, 'peers_total': total, 'origins': sorted(set(origins)), 'observed_at': observed, 'stale': stale, 'detail': str(seen) + '/' + str(total) + ' RIS-наблюдателей'}


def parse_rpki(data, prefix, asn):
    if not isinstance(data, dict) or str(data.get('resource', '')) not in (str(asn), 'AS' + str(asn)) or data.get('prefix') != prefix:
        raise ValueError('RIPEstat: RPKI для другого префикса/ASN')
    state = data.get('status')
    if state not in ('valid', 'invalid_asn', 'invalid_length', 'unknown'):
        raise ValueError('RIPEstat: неизвестный статус RPKI')
    return {'status': 'VALID' if state == 'valid' else 'UNKNOWN' if state == 'unknown' else 'INVALID', 'reason': state, 'prefix': prefix, 'asn': asn}


def routing_analysis(ip, network):
    prefix = network.get('prefix')
    result = {'status': 'NO DATA', 'visibility': {}, 'rpki': [], 'errors': []}
    if not prefix:
        return result
    try:
        prefix = str(ipaddress.ip_network(prefix, strict=True))
        if ipaddress.ip_address(ip) not in ipaddress.ip_network(prefix):
            raise ValueError('Префикс не содержит проверяемый IP')
        deadline = min(END_TIME, time.monotonic() + 9)
        answer = fetch_json('https://stat.ripe.net/data/routing-status/data.json?' + urllib.parse.urlencode({'resource': prefix}), timeout=min(4, remaining(4)))
        if answer.get('status') not in (None, 'ok'):
            raise ValueError('RIPEstat routing-status: ошибка API')
        result['visibility'] = parse_visibility(answer.get('data'), prefix)
        result['status'] = result['visibility']['status']
        origins = result['visibility']['origins'][:2]
        if not origins:
            origins = [v['asn'] for v in network.get('asns', [])[:2] if isinstance(v, dict) and isinstance(v.get('asn'), int) and not isinstance(v['asn'], bool) and 0 < v['asn'] <= 4294967295]
        for asn in origins:
            if deadline - time.monotonic() <= .1 or CANCEL.is_set():
                break
            try:
                answer = fetch_json('https://stat.ripe.net/data/rpki-validation/data.json?' + urllib.parse.urlencode({'resource': asn, 'prefix': prefix}), timeout=min(3, deadline - time.monotonic()))
                if answer.get('status') not in (None, 'ok'):
                    raise ValueError('RIPEstat rpki-validation: ошибка API')
                result['rpki'].append(parse_rpki(answer.get('data'), prefix, asn))
            except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
                result['errors'].append(clean(str(exc))[:120])
        return result
    except (OSError, ValueError, TypeError, AttributeError, subprocess.TimeoutExpired) as exc:
        result['errors'].append(clean(str(exc))[:120])
        return result


def remote_value(value, kind, expected_ip=None):
    if value is None:
        return 'PENDING', None
    if kind == 'tcp':
        records = [v for v in value if isinstance(v, dict)] if isinstance(value, list) else []
        good = next((v for v in records if isinstance(v.get('time'), (int, float)) and not isinstance(v['time'], bool) and math.isfinite(v['time']) and 0 <= v['time'] <= 180 and not v.get('error') and (expected_ip is None or v.get('address') == expected_ip)), None)
        if good:
            return 'OPEN', good['time'] * 1000
        error = str(records[0].get('error', 'NO DATA')).lower() if records else 'no data'
        return ('REFUSED' if 'refused' in error else 'TIMEOUT' if 'timed out' in error else 'API ERROR'), None
    samples = []
    def visit(item, depth=0):
        if isinstance(item, list) and depth < 5:
            if len(item) >= 2 and item[0] == 'OK' and isinstance(item[1], (int, float)) and not isinstance(item[1], bool) and math.isfinite(item[1]) and 0 <= item[1] <= 180 and (expected_ip is None or len(item) < 3 or item[2] == expected_ip):
                samples.append(item[1] * 1000)
            else:
                for child in item[:16]:
                    visit(child, depth + 1)
    visit(value)
    return ('REPLY', sum(samples) / len(samples)) if samples else ('NO REPLY', None)


def globalping(ip, ports, budget=18):
    rows = []
    jobs = []
    total_deadline = min(END_TIME, time.monotonic() + budget)
    targets = comparison_ports(ports)
    for kind, port in [('ping', None)] + [('tcp', p) for p in targets]:
        options = {'packets': 3, 'protocol': 'ICMP' if port is None else 'TCP'}
        if port is not None:
            options['port'] = port
        payload = {'type': 'ping', 'target': ip, 'limit': 3, 'locations': [{'country': 'DE'}, {'country': 'NL'}, {'country': 'US'}], 'measurementOptions': options}
        try:
            if total_deadline - time.monotonic() <= 0:
                break
            answer = fetch_json('https://api.globalping.io/v1/measurements', min(4, total_deadline - time.monotonic()), payload=payload)
            ident = answer.get('id', '')
            if not isinstance(ident, str) or not re.fullmatch('[A-Za-z0-9_-]{1,64}', ident):
                raise ValueError('Некорректный идентификатор Globalping')
            jobs.append((kind, port, ident))
        except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
            rows.append({'kind': kind, 'port': port, 'node': 'Globalping', 'status': 'RATE LIMIT' if '429' in str(exc) else 'API ERROR', 'ms': None})
    answers, errors = {}, {}
    pending = jobs[:]
    while pending and time.monotonic() < total_deadline and not CANCEL.is_set():
        next_pending = []
        for kind, port, ident in pending:
            if CANCEL.is_set() or total_deadline - time.monotonic() <= 0:
                next_pending.append((kind, port, ident))
                continue
            try:
                answer = fetch_json('https://api.globalping.io/v1/measurements/' + ident, min(2, total_deadline - time.monotonic()))
                answers[ident] = answer
                errors.pop(ident, None)
                if answer.get('status') not in ('finished', 'failed'):
                    next_pending.append((kind, port, ident))
            except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
                errors[ident] = 'RATE LIMIT' if '429' in str(exc) else 'API ERROR'
                if '429' not in str(exc):
                    next_pending.append((kind, port, ident))
        pending = next_pending
        if pending:
            CANCEL.wait(min(1, max(0, total_deadline - time.monotonic())))
    for kind, port, ident in jobs:
        answer = answers.get(ident, {})
        results = answer.get('results', [])
        if not isinstance(results, list) or not results:
            rows.append({'kind': kind, 'port': port, 'node': 'Globalping', 'status': errors.get(ident, 'API ERROR' if answer.get('status') == 'failed' else 'PENDING'), 'ms': None})
            continue
        for item in results[:3]:
            if not isinstance(item, dict):
                continue
            result = item.get('result', {})
            probe = item.get('probe', {})
            if not isinstance(result, dict) or not isinstance(probe, dict):
                continue
            stats = result.get('stats', {})
            if not isinstance(stats, dict):
                continue
            count = stats.get('rcv', 0)
            average = stats.get('avg')
            target_matches = result.get('resolvedAddress') == ip
            valid = target_matches and isinstance(count, (int, float)) and not isinstance(count, bool) and 0 < count <= 3 and isinstance(average, (int, float)) and math.isfinite(average) and 0 <= average <= 180000
            status = ('OPEN' if kind == 'tcp' else 'REPLY') if valid else 'NO REPLY' if target_matches and result.get('status') == 'finished' else 'API ERROR' if result.get('status') in ('failed', 'finished') else 'PENDING'
            asn = str(probe.get('asn', ''))
            asn = asn[2:] if asn.startswith('AS') else asn
            asn = 'AS' + str(int(asn)) if asn.isdigit() and int(asn) > 0 else ''
            rows.append({'kind': kind, 'port': port, 'node': clean('Globalping ' + str(probe.get('country', '')) + '/' + str(probe.get('city', ''))), 'country': clean(probe.get('country', '')), 'asn': asn, 'status': status, 'ms': average if valid else None})
    return rows


def independent_nodes(data, limit=4):
    nodes = data.get('nodes', {})
    if not isinstance(nodes, dict):
        raise ValueError('Некорректный список внешних узлов')
    selected, countries, asns = [], set(), set()
    for name, info in sorted(nodes.items())[:300]:
        if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9-]+\.node\.check-host\.net', name) or not isinstance(info, dict):
            continue
        location, asn = info.get('location'), str(info.get('asn', ''))
        if not isinstance(location, list) or len(location) < 3 or not re.fullmatch(r'AS[1-9][0-9]{0,9}', asn):
            continue
        country = str(location[0])
        if country in countries or asn in asns:
            continue
        selected.append(name)
        countries.add(country)
        asns.add(asn)
        if len(selected) == limit:
            break
    return selected


def external(ip, ports):
    rows = []
    jobs = []
    stage_deadline = min(END_TIME, time.monotonic() + 35)
    target_ports = comparison_ports(ports)
    selected = []
    try:
        selected = independent_nodes(fetch_json('https://check-host.net/nodes/hosts', timeout=4))
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    for kind, port in [('ping', None)] + [('tcp', p) for p in target_ports]:
        host = ip if port is None else ('[' + ip + ']' if family(ip) == socket.AF_INET6 else ip) + ':' + str(port)
        try:
            if stage_deadline - time.monotonic() <= 0:
                break
            parameters = [('host', host), ('max_nodes', '4')] + [('node', node) for node in selected]
            data = fetch_json('https://check-host.net/check-' + kind + '?' + urllib.parse.urlencode(parameters), min(4, stage_deadline - time.monotonic()))
            ident = data.get('request_id', '')
            if data.get('ok') != 1 or not re.fullmatch('[A-Za-z0-9_-]{1,64}', str(ident)):
                raise ValueError('Некорректный ответ Check-Host')
            nodes = data.get('nodes', {})
            if not isinstance(nodes, dict) or not nodes:
                raise ValueError('Нет узлов Check-Host')
            nodes = {node: info for node, info in list(nodes.items())[:4] if isinstance(node, str) and re.fullmatch(r'[A-Za-z0-9-]+\.node\.check-host\.net', node) and isinstance(info, list) and len(info) >= 3}
            if not nodes:
                raise ValueError('Некорректный список узлов')
            jobs.append((kind, port, str(ident), nodes))
        except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
            rows.append({'kind': kind, 'port': port, 'node': 'Check-Host', 'status': 'API ERROR', 'ms': None, 'detail': clean(str(exc))[:120]})
    deadline = min(stage_deadline, time.monotonic() + 16)
    pending = jobs[:]
    while pending and time.monotonic() < deadline:
        if CANCEL.is_set():
            break
        next_pending = []
        for kind, port, ident, nodes in pending:
            try:
                answer = fetch_json('https://check-host.net/check-result/' + ident, min(4, max(1, deadline - time.monotonic())))
            except (OSError, ValueError, subprocess.TimeoutExpired):
                next_pending.append((kind, port, ident, nodes))
                continue
            unfinished = {}
            for node, info in nodes.items():
                status, ms = remote_value(answer.get(node), kind, ip)
                if status == 'PENDING':
                    unfinished[node] = info
                else:
                    location = '/'.join(str(x) for x in info[1:3]) if isinstance(info, list) else node
                    rows.append({'kind': kind, 'port': port, 'node': clean(location), 'node_id': node, 'country': clean(info[0]), 'asn': clean(info[4]) if len(info) > 4 else '', 'status': status, 'ms': ms})
            if unfinished:
                next_pending.append((kind, port, ident, unfinished))
        pending = next_pending
        if pending:
            CANCEL.wait(min(1, max(0, END_TIME - time.monotonic())))
    for kind, port, ident, nodes in pending:
        for node, info in nodes.items():
            rows.append({'kind': kind, 'port': port, 'node': clean('/'.join(str(x) for x in info[1:3])), 'status': 'PENDING', 'ms': None})
    if not any(row['status'] in ('OPEN', 'REPLY', 'REFUSED', 'TIMEOUT', 'NO REPLY') for row in rows) and not CANCEL.is_set() and stage_deadline - time.monotonic() > 4:
        rows += globalping(ip, ports, min(18, stage_deadline - time.monotonic()))
    return rows


def classify(report):
    result = {'state': 'INCONCLUSIVE', 'reachability': 'UNKNOWN', 'suspected_cause': 'UNKNOWN', 'confidence': 'Low', 'evidence': [], 'limitations': ['Без доступа к VPS нельзя отличить все правила firewall по исходному IP от фильтрации по пути.'], 'messages': []}
    local = report.get('tcp', {})
    opens = [p for p, v in local.items() if v['status'] == 'OPEN']
    refused = [p for p, v in local.items() if v['status'] in ('REFUSED', 'RESET')]
    ping_ok = report.get('ping', {}).get('received', 0) > 0
    timestamp_ok = report.get('timestamp', {}).get('reachable', False)
    trace_ok = any(v.get('reached') and v.get('status') not in ('RST', 'PORT CLOSED') for v in report.get('traces', {}).values())
    syn_ok = any(v.get('status') == 'SYN/ACK' for v in report.get('syn', {}).values())
    udp_open = [p for p, v in report.get('udp', {}).items() if v.get('reachable')]
    application = any(v.get('reachable') for v in report.get('http', {}).values()) or report.get('ssh', {}).get('tcp_open') or report.get('ssh', {}).get('status') == 'SSH'
    controls = sum(v['status'] == 'OPEN' for v in report.get('controls', {}).values())
    evidence = result['evidence']
    if opens:
        evidence.append('TCP Connect: ' + ', '.join(map(str, opens)))
    if ping_ok:
        evidence.append('Получен ICMP Echo Reply от целевого IP')
    if timestamp_ok:
        evidence.append('Получен соответствующий запросу ICMP Timestamp Reply от целевого IP')
    if udp_open:
        evidence.append('UDP-ответ: ' + ', '.join(map(str, udp_open)))
    if syn_ok:
        evidence.append('Получен соответствующий исходной SYN-пробе SYN/ACK')
    if refused:
        evidence.append('Получен TCP RST/отказ: ' + ', '.join(map(str, refused)))
    result['limitations'].append('Timeout ICMP/TCP/UDP и закрытый порт сами по себе не подтверждают блокировку IP.')
    if report.get('route', {}).get('ok') is False:
        result.update(state='LOCAL_NETWORK_PROBLEM', suspected_cause='NO_ROUTE', confidence='High', messages=['До VPS нет рабочего локального маршрута. Проверьте подключение и маршрутизацию.'])
        return result
    if not report.get('path', {}).get('direct_ready', False):
        result['limitations'] += report.get('path', {}).get('risks', [])
        result.update(suspected_cause='DIRECT_PATH_UNVERIFIED', messages=['Прямой путь не подтверждён: DIRECT_PATH_UNVERIFIED.', 'Результаты могут зависеть от VPN/прокси или локальных правил; вывод о блокировке IP недостоверен.'])
        return result
    direct_reply = bool(opens or application or udp_open or ping_ok or timestamp_ok or trace_ok or syn_ok)
    historical = report.get('discovery', {})
    if historical.get('historical') and historical.get('ports'):
        result['limitations'].append('InternetDB содержит прежние наблюдения; отсутствие локального ответа на эти порты само по себе не доказывает блокировку.')
    routing = report.get('routing', {})
    visibility = routing.get('visibility', {})
    if visibility.get('status') == 'VISIBLE':
        evidence.append('BGP: маршрут наблюдают ' + str(visibility.get('peers_seen', 0)) + ' RIS-пиров; снимок ' + str(visibility.get('observed_at') or 'без даты'))
    if visibility.get('stale'):
        result['limitations'].append('BGP-снимок устарел или его время не подтверждено.')
    if any(v.get('status') == 'INVALID' for v in routing.get('rpki', [])):
        result['limitations'].append('RPKI не подтверждает объявление префикса/ASN: возможны ограничения маршрутизации; это не доказательство бана IP.')
    remote_ports = {}
    for row in report.get('external', []):
        port = row.get('port')
        if row.get('kind') == 'tcp' and row.get('status') == 'OPEN' and port in local and local[port]['status'] in ('TIMEOUT', 'PROHIBITED', 'HOST UNREACH', 'NO ROUTE'):
            remote_ports.setdefault(port, []).append(row)
    if remote_ports and controls:
        ports = ', '.join(map(str, sorted(remote_ports)))
        strong = False
        local_filter = report.get('path', {}).get('local_filter', {})
        local_rules = local_filter.get('candidates', [])
        suspected_local = any(filter_affects(rule, port) for rule in local_rules for port in remote_ports)
        for port, rows in remote_ports.items():
            asns = {r.get('asn') for r in rows if r.get('asn')}
            countries = {r.get('country') for r in rows if r.get('country')}
            attempts = local[port].get('attempts', [])
            if len(asns) >= 2 and len(countries) >= 2 and len(attempts) >= 2 and all(v['status'] in ('TIMEOUT', 'PROHIBITED') for v in attempts) and controls >= 2 and local_filter.get('status') == 'OK' and not suspected_local:
                strong = True
        evidence.append('Тот же IP/TCP-порт открыт извне, локально повторно не отвечает: ' + ports)
        result.update(state='LIKELY_PATH_SPECIFIC_FILTERING' if strong else 'POSSIBLE_BLOCK', reachability='PARTIAL' if direct_reply else 'NOT_CONFIRMED', suspected_cause='PATH_OR_SOURCE_ACL', confidence='Medium' if strong else 'Low', messages=[('VPS доступен частично. ' if direct_reply else '') + 'С внешних узлов TCP ' + ports + ' доступен, с роутера — нет.', 'Возможна фильтрация на маршруте или firewall VPS по исходному адресу; блокировка провайдером не доказана.'])
        if suspected_local:
            result.update(state='PORT_FILTERED' if direct_reply else 'INCONCLUSIVE', suspected_cause='LOCAL_RULE_OR_PATH', confidence='Low', messages=['TCP ' + ports + ' доступен извне, локально ответ не подтверждён.', 'На роутере есть потенциально ограничивающие правила firewall. Их действие нужно исключить до вывода о внешней фильтрации.'])
        elif local_filter.get('status') != 'OK':
            result['limitations'].append('Локальная таблица filter не проверена полностью; высокая уверенность в причине недоступна.')
        return result
    if direct_reply:
        result.update(state='REACHABLE', reachability='REACHABLE', confidence='High', suspected_cause='NONE')
        if opens or application:
            result['messages'] = ['VPS доступен из вашей сети' + (' по TCP: ' + ', '.join(map(str, opens)) if opens else '') + '.', 'Получен прямой ответ; полная блокировка IP не подтверждается.']
        elif udp_open:
            result['messages'] = ['Получен ответ по UDP: ' + ', '.join(map(str, udp_open)) + '; IP доступен из вашей сети.', 'Доступность TCP-сервисов не подтверждена.']
        else:
            result['messages'] = ['IP отвечает из вашей сети, но проверяемые TCP-сервисы не подтвердили доступность.', 'Проверьте порты сервиса и firewall VPS.']
        filtered = [p for p, v in local.items() if v['status'] in ('TIMEOUT', 'PROHIBITED') and len(v.get('attempts', [])) >= 2]
        if opens and filtered:
            result.update(state='PORT_FILTERED', reachability='PARTIAL', suspected_cause='PORT_NO_RESPONSE', confidence='Low')
            result['limitations'].append('Порты без ответа: ' + ', '.join(map(str, filtered)) + '. Сервис может отсутствовать; источник фильтрации не установлен.')
        tls = [value for values in report.get('tls', {}).values() for value in values.values()]
        if tls and all(v['status'] == 'PROTOCOL_FAILURE' for v in tls):
            result['suspected_cause'] = 'PROTOCOL_FAILURE'
            result['limitations'].append('TLS без SNI не прошёл: возможны требования виртуального хоста, версия TLS или протокольное ограничение; DPI не подтверждён.')
        return result
    if refused:
        result.update(suspected_cause='CLOSED_OR_REJECTED', confidence='Medium', reachability='RESPONSE_OBSERVED', messages=['На TCP получен явный отказ. Возможны закрытые порты или отклонение firewall.', 'Ответ мог сформировать промежуточный узел; пассивную блокировку IP подтвердить нельзя.'])
        return result
    errors = [v['status'] for v in local.values() if v['status'] in ('NET ERROR', 'NO PERMISSION', 'BYPASS FAIL', 'ERROR')]
    if errors and not any(v['status'] in ('TIMEOUT', 'PROHIBITED') for v in local.values()):
        result.update(state='CHECK_ERROR', suspected_cause='PROBE_ERROR', messages=['Не удалось выполнить необходимые сетевые проверки.', 'Ошибка инструмента не является признаком блокировки VPS.'])
    elif not controls:
        result.update(state='LOCAL_NETWORK_PROBLEM' if report.get('controls') else 'INCONCLUSIVE', suspected_cause='CONTROL_UNAVAILABLE', messages=['Нет подтверждённой доступности ни VPS, ни контрольных адресов.', 'Проверьте Интернет и исходящие правила роутера; блокировка VPS не установлена.'])
    else:
        prohibited = any(v['status'] == 'PROHIBITED' for v in local.values()) or any(v.get('status') == 'PROHIBITED' for v in report.get('traces', {}).values())
        result.update(state='POSSIBLE_BLOCK' if prohibited else 'INCONCLUSIVE', reachability='NOT_CONFIRMED', suspected_cause='PATH_OR_FIREWALL' if prohibited else 'NO_RESPONSE', messages=['Интернет с роутера доступен, но VPS не ответил.', 'Возможны выключенный VPS, закрытые сервисы, firewall или фильтрация пути. Однозначно определить причину пока нельзя.'])
        if report.get('bgp', {}).get('status') == 'NOT ANNOUNCED':
            result.update(state='INCONCLUSIVE', suspected_cause='BGP_ROUTE_NOT_ANNOUNCED', confidence='Medium', messages=['VPS не ответил; RIPEstat не подтвердил активный BGP-анонс префикса.', 'Возможна общая проблема маршрутизации префикса. Данных о блокировке провайдером недостаточно.'])
            evidence.append('RIPEstat: префикс не анонсирован')
    return result


def verdict(report):
    return classify(report)['messages']


def status_text(status):
    extra = {'FOUND': 'Найдены порты', 'REVIEW': 'Есть правила', 'STUN REPLY': 'STUN ответил', 'TIMESTAMP REPLY': 'ICMP ответил', 'VISIBLE': 'Маршрут виден', 'NOT VISIBLE': 'Не наблюдается', 'VALID': 'ROA корректен', 'INVALID': 'Проверьте ROA', 'BANNER REPLY': 'Сервис ответил'}
    if status in extra:
        return extra[status]
    return {'OK': 'Работает', 'OPEN': 'Доступен', 'SSH': 'Доступен', 'TIMEOUT': 'Нет ответа',
            'NO REPLY': 'Нет ответа', 'QUIC VN': 'QUIC отвечает', 'NO DATA': 'Нет данных', 'REFUSED': 'Порт закрыт',
            'PORT CLOSED': 'Порт закрыт', 'REPLY': 'Получен ответ', 'NO ROUTE': 'Нет маршрута',
            'PROHIBITED': 'Запрет узла', 'UNREACHABLE': 'Недоступно',
            'ANNOUNCED': 'Подтвержден', 'NOT ANNOUNCED': 'Нет анонса',
            'DIRECT': 'Напрямую', 'SYSTEM': 'Системный путь', 'TLS CERT': 'Серт. не принят',
            'PARTIAL': 'Часть ответов', 'UNKNOWN': 'Не определено', 'FAILED': 'Ошибка',
            'BYPASS FAIL': 'Обход не выполнен', 'RATE LIMIT': 'Лимит запросов',
            'TLS DROP': 'TLS: нет ответа', 'EOF': 'Соединение закрыто', 'RST': 'Порт закрыт',
            'ECHO REPLY': 'Цель ответила', '*': 'Нет ответа', 'SKIPPED': 'Пропущено',
            'INCONCLUSIVE': 'Нет достоверной пробы', 'API ERROR': 'Ошибка API', 'ERROR': 'Ошибка проверки',
            'PENDING': 'Не завершено', 'TLS OK': 'TLS работает', 'PROTOCOL_FAILURE': 'Ошибка протокола',
            'NO PERMISSION': 'Нет прав', 'CANCELLED': 'Остановлено', 'NETWORK UNREACHABLE': 'Сеть недоступна',
            'HOST UNREACHABLE': 'Узел недоступен', 'HOST UNREACH': 'Узел недоступен', 'NET ERROR': 'Сетевая ошибка',
            'RESET': 'Разрыв / RST', 'TOO BIG': 'Превышен MTU', 'TTL EXCEEDED': 'TTL исчерпан'}.get(status, status)


def trace_cell(value, index):
    if index >= len(value['hops']):
        return ''
    hop = value['hops'][index]
    if not hop['ip']:
        return status_text(hop['status'])
    text = hop['ip'] + f" · {hop['ms']:.1f} мс"
    if hop['reached']:
        text += ' · цель'
    elif hop['status'] in ('PROHIBITED', 'UNREACHABLE', 'NETWORK UNREACHABLE', 'HOST UNREACHABLE'):
        text = hop['ip'] + (' · запрет' if hop['status'] == 'PROHIBITED' else ' · недоступен')
    return text


def trace_color(value, index):
    if index >= len(value['hops']):
        return '90'
    hop = value['hops'][index]
    if hop['reached']:
        return '32;1'
    if hop['status'] in ('PROHIBITED', 'UNREACHABLE', 'NETWORK UNREACHABLE', 'HOST UNREACHABLE'):
        return '31;1'
    return '32' if hop['ip'] else '31;1'


def trace_summary(value):
    if value['reached']:
        return 'VPS ответил; путь до IP подтвержден', '32;1'
    if value['status'] == 'PROHIBITED':
        return 'Узел пути запретил пробу; трассировка остановлена', '31;1'
    if value['status'] in ('UNREACHABLE', 'NETWORK UNREACHABLE', 'HOST UNREACHABLE'):
        return 'Узел сообщил о недоступности; трассировка остановлена', '31;1'
    if value['hops']:
        return 'Ответ VPS не получен за ' + str(len(value['hops'])) + ' хопов', '33'
    return 'Проверка не выполнена: ' + status_text(value['status']), '31;1'


def run_stage(report, title, jobs, quiet=False):
    started = time.monotonic()
    completed = 0
    if not quiet:
        progress(title)
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        tasks = {}
        for key, function, arguments in jobs:
            if not CANCEL.is_set() and END_TIME - time.monotonic() > .05:
                tasks[pool.submit(function, *arguments)] = key
        try:
            for future in concurrent.futures.as_completed(tasks):
                key, index = tasks[future]
                try:
                    value = future.result()
                except (OSError, ValueError, TypeError, AttributeError, IndexError, MemoryError, subprocess.SubprocessError, ssl.SSLError) as exc:
                    value = {'status': 'ERROR', 'detail': clean(str(exc))[:160], 'ms': None}
                    report['errors'].append(title + ': ' + clean(str(exc))[:160])
                    if key == 'external':
                        value = [{'kind': 'api', 'port': None, 'node': 'Внешний API', 'status': 'API ERROR', 'ms': None, 'detail': clean(str(exc))[:160]}]
                if index is None:
                    if isinstance(report.get(key), dict) and isinstance(value, dict):
                        report[key].update(value)
                    else:
                        report[key] = value
                else:
                    report[key][index] = value
                completed += 1
                if not quiet:
                    progress(title + ' · ' + str(completed) + '/' + str(len(tasks)))
        except BaseException:
            stop_probes()
            for future in tasks:
                future.cancel()
            raise
    report['stages'].append({'name': title, 'elapsed': time.monotonic() - started, 'completed': completed, 'requested': len(jobs)})


def render_report(report):
    columns = max(60, min(108, shutil.get_terminal_size((100, 24)).columns))
    print(paint('Проверка блокировки IP · ' + report['ip']))
    path = report['path']
    print('Интерфейс: ' + (path.get('interface') or 'не подтверждён') + ' · исходный IP: ' + (path.get('source') or 'не определён'))
    print(paint('Путь: ' + ('напрямую через WAN' if path['direct_ready'] else 'DIRECT_PATH_UNVERIFIED'), '32' if path['direct_ready'] else '33;1'))
    network = report.get('bgp', {})
    for owner in network.get('asns', [])[:3]:
        print('ASN: ' + paint('AS' + str(owner['asn']), '33;1') + ' · Хостер: ' + paint(fit(owner.get('holder') or 'не определён', columns - 34), '35;1'))
    rows = []
    def add(method, status, detail, ms=None):
        good = status in ('OK', 'OPEN', 'REPLY', 'QUIC VN', 'SSH', 'ANNOUNCED', 'TLS OK', 'STUN REPLY', 'TIMESTAMP REPLY', 'VISIBLE', 'VALID', 'BANNER REPLY') or status.startswith('HTTP ')
        color = '36;1' if status == 'FOUND' else '32;1' if good else '90' if status in ('SKIPPED', 'INCONCLUSIVE', 'NO DATA', 'UNKNOWN', 'PENDING') else '33;1' if status in ('TLS CERT', 'PARTIAL', 'REFUSED', 'PORT CLOSED', 'CLOSED', 'OPEN_FILTERED', 'INVALID', 'NOT VISIBLE', 'REVIEW') else '31;1'
        rows.append(([method, status_text(status), (f'{ms:.1f} мс · ' if ms is not None else '') + str(detail or 'Нет дополнительных сведений')], color))
    route_info = report['route']
    route_detail = (route_info.get('interface', '') + (' → ' + route_info['gateway'] if route_info.get('gateway') else '')).strip()
    add('Маршрут', route_info['status'], route_detail or route_info.get('detail', ''))
    historical = report.get('discovery', {})
    if historical.get('status') != 'SKIPPED' and historical:
        chosen = historical.get('selected_ports', [])
        add('Поиск портов', historical.get('status', 'NO DATA'), 'Ранее: ' + ', '.join(map(str, chosen)) if chosen else 'Новых портов нет' if historical.get('status') == 'FOUND' else 'InternetDB: API недоступен' if historical.get('status') in ('API ERROR', 'ERROR') else 'InternetDB: запись об IP не найдена')
    if report.get('timestamp'):
        value = report['timestamp']
        add('ICMP Timestamp', value['status'], 'ответ на отдельный тип ICMP' if value.get('reachable') else 'ответ не получен; это не признак бана', value.get('ms'))
    for key, label in (('ping', 'ICMP 56 B'), ('medium_ping', 'ICMP 1200 B'), ('large_ping', 'ICMP DF/1500 B')):
        value = report.get(key, {})
        if not value:
            continue
        detail = f"{value.get('received', 0)}/{value.get('sent', 0)} ответов"
        if value.get('loss_percent') is not None:
            detail += f" · потери {value['loss_percent']:.0f}%"
        if value.get('min_ms') is not None:
            detail += f" · среднее {value['avg_ms']:.1f} мс"
        if value.get('unstable'):
            detail += ' · нестабильно'
        mtus = [v['mtu'] for v in value.get('events', []) if v.get('mtu')]
        if mtus:
            detail += '; MTU ' + str(min(mtus))
        add(label, value['status'], detail)
    for port, value in report['tcp'].items():
        state = value.get('port_state', 'UNKNOWN')
        detail = {'OPEN': 'соединение установлено', 'CLOSED': 'RST: закрыт или отклонён', 'FILTERED': 'причина неизвестна', 'ERROR': 'ошибка проверки', 'UNKNOWN': 'не проверялся'}.get(state, state)
        if value['status'] == 'PROHIBITED':
            detail = 'получен запрет'
        attempts = value.get('attempts', [])
        if len(attempts) > 1:
            detail += ' · попыток ' + str(len(attempts))
        if value.get('unstable'):
            detail += ' · нестабильно'
        add('TCP/' + str(port), value['status'], detail, value.get('ms'))
    for port, value in report['udp'].items():
        detail = 'QUIC ответил' if value['status'] == 'QUIC VN' else 'UDP ответил; QUIC не подтверждён' if value.get('reachable') and port == 443 else 'сервис ответил' if value.get('reachable') else 'порт закрыт / отклонён' if value['status'] == 'PORT CLOSED' else 'сервис отсутствует или фильтруется'
        if value['status'] == 'STUN REPLY':
            detail = 'STUN: код ' + str(value['error_code']) if value.get('error_code') else 'STUN Binding подтвердил ответ'
        if value.get('reachable') and isinstance(value.get('attempts'), int) and value['attempts'] > 1:
            detail += '; повторная проба, RTT не определён'
        add('UDP/' + str(port), value['status'], detail, value.get('ms'))
    for port, value in report.get('services', {}).items():
        protocol = value.get('protocol', 'UNKNOWN')
        add('Сервис/' + str(port), 'BANNER REPLY' if value.get('status') == 'BANNER REPLY' else 'NO DATA', protocol if protocol != 'UNKNOWN' else 'баннер не распознан; TCP проверен')
    value = report.get('ssh')
    if value:
        add('SSH/22', value['status'], 'SSH-сервер ответил' if value['status'] == 'SSH' else 'SSH-приветствие не получено')
    for port, versions in report.get('tls', {}).items():
        for version, value in versions.items():
            add('TLS ' + version + '/' + str(port), value['status'], 'без SNI; handshake прошёл' if value['status'] == 'TLS OK' else value.get('error') or status_text(value['status']))
    for port, value in report['http'].items():
        detail = 'TLS есть; сертификат не принят' if value['status'] == 'TLS CERT' else 'HTTP-сервер ответил' if value['status'].startswith('HTTP ') else value.get('detail', '')
        add('HTTPS/' + str(port) if port == 443 else 'HTTP/' + str(port), value['status'], detail)
    control_open = sum(v['status'] == 'OPEN' for v in report['controls'].values())
    add('Контроль сети', 'OK' if control_open else 'NO REPLY', str(control_open) + '/' + str(len(report['controls'])) + ' контрольных TCP/443')
    if 'bgp' in report:
        add('BGP-префикс', report['bgp']['status'], report['bgp'].get('prefix') or 'ASN не подтверждён')
    routing = report.get('routing', {})
    visibility = routing.get('visibility', {})
    if visibility:
        add('BGP RIS', 'NO DATA' if visibility.get('stale') else visibility['status'], visibility.get('detail', '') + ('; снимок устарел' if visibility.get('stale') else ''))
    for value in routing.get('rpki', []):
        add('RPKI AS' + str(value['asn']), value['status'], 'ROA отсутствует; это не ошибка' if value['status'] == 'UNKNOWN' else value['prefix'])
    if routing.get('errors') and not routing.get('rpki'):
        add('Данные RPKI', 'API ERROR', 'API недоступен; не признак бана')
    filters = path.get('local_filter', {})
    if filters.get('candidates'):
        add('Локальный filter', 'REVIEW', 'DROP/REJECT найдены; действие не подтверждено')
    table(['Проверка', 'Результат', 'Подробности'], rows, [17, 16, columns - 43], compact=True)
    if report['external']:
        remote_rows = []
        for value in report['external']:
            good = value['status'] in ('OPEN', 'REPLY')
            color = '32;1' if good else '90' if value['status'] in ('NO DATA', 'PENDING') else '31;1'
            method = 'ICMP' if value['kind'] == 'ping' else 'TCP/22 (SSH)' if value.get('port') == 22 else 'TCP/' + str(value['port'])
            remote_rows.append(([value['node'], method, status_text(value['status']), f"{value['ms']:.1f} мс" if value.get('ms') is not None else 'нет RTT'], ['36;1', '37', color, '32' if good else '90']))
        checked = sorted({v['port'] for v in report['external'] if v.get('kind') == 'tcp' and v.get('port') not in (443, 22)})
        print(paint('Внешняя проверка · ICMP, TCP/443 и TCP/22 (SSH)' + (' + TCP/' + ','.join(map(str, checked)) if checked else '')))
        table(['Откуда', 'Проверка', 'Результат', 'RTT'], remote_rows, [min(32, columns - 52), 12, 17, 10], compact=True)
    analysis = report['analysis']
    title = {'REACHABLE': 'IP доступен', 'PORT_FILTERED': 'IP доступен · часть портов не отвечает', 'LIKELY_PATH_SPECIFIC_FILTERING': 'Есть признаки фильтрации пути', 'POSSIBLE_BLOCK': 'Возможно ограничение', 'LOCAL_NETWORK_PROBLEM': 'Проблема локальной сети', 'CHECK_ERROR': 'Ошибка проверки', 'INCONCLUSIVE': 'Недостаточно данных'}[analysis['state']]
    result_color = '32;1' if analysis['state'] in ('REACHABLE', 'PORT_FILTERED') else '31;1' if analysis['state'] in ('LOCAL_NETWORK_PROBLEM', 'CHECK_ERROR') else '33;1'
    print(paint(title, result_color))
    for message in analysis['messages']:
        print(paint(message, result_color))
    if analysis.get('suspected_cause') == 'PORT_NO_RESPONSE':
        unanswered = [str(port) for port, value in report['tcp'].items() if value['status'] in ('TIMEOUT', 'PROHIBITED') and len(value.get('attempts', [])) >= 2]
        print(paint('Без ответа: TCP ' + ', '.join(unanswered) + '.', '33'))
        print('Причина отсутствия ответа не установлена: сервис может отсутствовать или фильтроваться.')
    if report.get('deadline_reached'):
        print(paint('Достигнут лимит времени: часть проверок не завершена.', '33'))
    if not report.get('cleanup_ok', True):
        print(paint('Не все временные исключения удалены.', '31;1'))
    print(paint(f"Длительность проверки: {report['elapsed']:.1f} с.", '90'))


def main():
    global BYPASS_MARK, END_TIME, WAN_INTERFACE
    parser = argparse.ArgumentParser(description='Xmenu: проверка блокировки IP VPS')
    parser.add_argument('target')
    parser.add_argument('--ports', default='')
    parser.add_argument('--sni', default='')
    parser.add_argument('--hops', type=int, default=15)
    parser.add_argument('--timeout', type=float, default=120)
    parser.add_argument('--no-external', action='store_true')
    parser.add_argument('--details', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    parts = args.target.split()
    ip = public_target(parts[0] if parts else '')
    address = ipaddress.ip_address(ip)
    ports = list(dict.fromkeys(int(v) for v in (args.ports.replace(',', ' ').split() if args.ports else parts[1:] or DEFAULT_PORTS)))
    if not 1 <= len(ports) <= 16 or any(not 1 <= p <= 65535 for p in ports) or not 1 <= args.hops <= 15 or not 20 <= args.timeout <= 180:
        raise ValueError('Нужно 1–16 портов 1–65535; hops 1–15; timeout 20–180 секунд')
    if args.sni and (len(args.sni) > 253 or not re.fullmatch(r'[A-Za-z0-9.-]+', args.sni)):
        raise ValueError('Некорректное имя SNI')
    private = args.no_external
    if not private:
        ports = list(dict.fromkeys(ports + [443, 22]))
    CANCEL.clear()
    WAN_INTERFACE = ''
    started = time.monotonic()
    END_TIME = started + args.timeout
    watchdog = threading.Timer(args.timeout, stop_probes)
    watchdog.daemon = True
    watchdog.start()
    path = detect_path(ip)
    BYPASS_MARK = path['mark']
    path_route = inspect_route(ip, path)
    path['local_filter'] = inspect_filter(ip, path)
    skipped = lambda port: {'status': 'SKIPPED', 'port_state': 'UNKNOWN', 'ms': None, 'port': port, 'attempts': []}
    report = {'schema_version': 2, 'version': '1.4.4', 'generated_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'ip': ip, 'ports': ports, 'path': path, 'route': path_route, 'tcp': {p: skipped(p) for p in ports}, 'udp': {}, 'http': {}, 'tls': {}, 'syn': {}, 'services': {}, 'discovery': {'status': 'SKIPPED', 'ports': []}, 'routing': {}, 'controls': {}, 'traces': {}, 'external': [], 'external_status': 'DISABLED' if private else 'NOT_NEEDED', 'stages': [], 'errors': [], 'ping': {'status': 'SKIPPED', 'sent': 0, 'received': 0, 'rtts': [], 'events': []}, 'settings': {'external_allowed': not private, 'timeout': args.timeout, 'max_workers': 3, 'max_hops': args.hops, 'discovery_port_cap': MAX_DISCOVERY_PORTS, 'total_port_cap': MAX_TOTAL_PORTS}, 'dependencies': {name: bool(shutil.which(name)) for name in ('ip', 'iptables', 'ip6tables', 'nft', 'nmap', 'mtr', 'curl', 'jq')}}
    quiet = args.json
    try:
        if not quiet:
            progress('1/6 · Проверка маршрута и WAN')
        if path_route.get('ok') is not False:
            primary = [p for p in ports if p in (22, 80, 443, 8080, 8443)]
            if not primary:
                primary = ports[:3]
            controls = ('2606:4700:4700::1111', '2001:4860:4860::8888', '2620:fe::fe') if address.version == 6 else ('1.1.1.1', '8.8.8.8', '9.9.9.9')
            controls = tuple(value for value in controls if value != ip)
            jobs = [(('tcp', p), tcp_discovery, (ip, p)) for p in primary]
            if not private:
                jobs.insert(0, (('discovery', None), discover_ports, (ip,)))
            jobs += [(('controls', control), tcp, (control, 443, 2)) for control in controls]
            jobs.append((('ping', None), echo, (ip, 56, 3, False, 1)))
            run_stage(report, '2/6 · ICMP и основные TCP-порты', jobs, quiet)
            basic_open = any(v['status'] == 'OPEN' for v in report['tcp'].values())
            selected_ports = discovery_targets(report['discovery'], report['tcp'])
            report['discovery']['selected_ports'] = selected_ports
            for port in selected_ports:
                if port not in report['tcp']:
                    ports.append(port)
                    report['tcp'][port] = skipped(port)
            jobs = []
            if not basic_open:
                jobs += [(('tcp', p), tcp_discovery, (ip, p)) for p in ports if p not in primary]
            else:
                jobs += [(('tcp', p), tcp_discovery, (ip, p)) for p in selected_ports]
            jobs += [(('large_ping', None), echo, (ip, 1452 if address.version == 6 else 1472, 2, True, 1)), (('udp', 443), udp_service, (ip, 443))]
            if not basic_open or report['ping'].get('unstable'):
                jobs += [(('medium_ping', None), echo, (ip, 1200, 2, False, 1)), (('udp', 53), udp_service, (ip, 53)), (('udp', 123), udp_service, (ip, 123))]
            if not basic_open or 3478 in report['discovery'].get('ports', []):
                jobs.append((('udp', 3478), udp_service, (ip, 3478)))
            if not basic_open and not report['ping'].get('received') and address.version == 4:
                jobs.append((('timestamp', None), timestamp_probe, (ip,)))
            run_stage(report, '3/6 · Дополнительные порты, UDP и MTU', jobs, quiet)
            jobs = []
            if not private and END_TIME - time.monotonic() > .1:
                candidates = sorted(selected_ports, key=lambda p: {'TIMEOUT': 0, 'PROHIBITED': 0, 'OPEN': 1, 'REFUSED': 2}.get(report['tcp'][p]['status'], 3))
                compare = comparison_ports(candidates)
                report['settings']['external_tcp_ports'] = compare
                jobs.append((('external', None), external, (ip, compare)))
                report['external_status'] = 'REQUESTED'
                jobs.append((('bgp', None), bgp, (ip,)))
            run_stage(report, '4/6 · Независимые внешние узлы', jobs, quiet)
            if private:
                report['bgp'] = {'status': 'NO DATA', 'detail': 'ASN не подтвержден: внешние запросы отключены'}
            jobs = []
            remote_open = {r['port'] for r in report['external'] if r['kind'] == 'tcp' and r['status'] == 'OPEN' and r['port'] in report['tcp']}
            for port in remote_open:
                if report['tcp'][port]['status'] != 'OPEN':
                    jobs.append((('tcp', port), tcp_recheck, (ip, port, report['tcp'][port])))
            if jobs:
                run_stage(report, '4/6 · Локальная перепроверка тех же портов', jobs, quiet)
            jobs = []
            if not private and report.get('bgp', {}).get('prefix') and END_TIME - time.monotonic() > 1:
                jobs.append((('routing', None), routing_analysis, (ip, report['bgp'])))
            opens = [p for p, v in report['tcp'].items() if v['status'] == 'OPEN']
            no_open = not opens
            if 22 in opens:
                jobs.append((('ssh', None), ssh_banner, (ip,)))
            for port in [p for p in selected_ports if p in opens and p not in (22, 80, 443)][:2]:
                jobs.append((('services', port), banner_probe, (ip, port)))
            for port in (80, 443):
                if port in opens:
                    jobs.append((('http', port), http_probe, (ip, port, port == 443, args.sni)))
            tls_ports = [p for p in (443, 8443, 2053, 2083, 2087, 2096) if p in opens][:2]
            for port in tls_ports:
                report['tls'][port] = {}
                for name, version in (('1.2', ssl.TLSVersion.TLSv1_2), ('1.3', ssl.TLSVersion.TLSv1_3)):
                    jobs.append((('tls_' + str(port), name), tls_confirm, (ip, port, version)))
                report['tls_' + str(port)] = report['tls'][port]
            if no_open:
                jobs += [(('syn', port), syn_probe, (ip, port)) for port in ([443] if 443 in ports else ports[:1])]
            run_stage(report, '5/6 · TLS без SNI, HTTP и SYN', jobs, quiet)
            for port in tls_ports:
                report.pop('tls_' + str(port), None)
            jobs = [(('traces', mode), trace, (ip, mode, args.hops, 443 if 443 in ports else ports[0], .7)) for mode in ('ICMP', 'UDP', 'TCP')]
            if no_open and 22 in ports and END_TIME - time.monotonic() > 20:
                jobs.append((('traces', 'TCP/22'), trace, (ip, 'TCP', args.hops, 22, .7)))
            run_stage(report, '5/6 · Трассировка пути', jobs, quiet)
    finally:
        watchdog.cancel()
        cleanup_flows()
    report['cleanup_ok'] = not FLOW_RULES
    report['deadline_reached'] = time.monotonic() >= END_TIME
    report['elapsed'] = time.monotonic() - started
    path['observed_sources'] = sorted({v['source'] for v in report['tcp'].values() if v.get('status') == 'OPEN' and v.get('source')})
    if any(source != path.get('source') for source in path['observed_sources']):
        path['risks'].append('Реальный исходный адрес TCP отличается от проверенного маршрута')
        path['direct_ready'] = False
        path['status'] = 'DIRECT_PATH_UNVERIFIED'
    if any(v['status'] == 'BYPASS FAIL' for group in ('tcp', 'udp') for v in report[group].values()):
        path['direct_ready'] = False
        path['status'] = 'DIRECT_PATH_UNVERIFIED'
    if not report['cleanup_ok']:
        report['errors'].append('Не все временные исключения удалены')
    report['analysis'] = classify(report)
    if not quiet:
        progress('6/6 · Итог проверки')
    report['verdict'] = report['analysis']['messages']
    if report['deadline_reached']:
        report['analysis']['limitations'].append('Общий лимит времени: незавершённые проверки не используются как признаки блокировки.')
    if args.json:
        print(json.dumps(report, ensure_ascii=False, allow_nan=False))
        return 0
    progress('')
    render_report(report)
    return 0


if __name__ == '__main__':
    def cancel(signum, frame):
        stop_probes()
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    try:
        sys.exit(main())
    except (KeyboardInterrupt, EOFError):
        print('\nПроверка отменена.')
        sys.exit(130)
    except (OSError, ValueError, IndexError) as exc:
        print('Ошибка: ' + clean(str(exc)), file=sys.stderr)
        sys.exit(2)
    finally:
        cleanup_flows()

XMENU_SERVER_ENGINE
}

xmenu_diagnostics_menu() {
    while :; do
        line; say "${CYAN}Диагностика${RESET}"
        menu_item 1 'Диагностика сайта — DNS / TCP / TLS / HTTP'
        menu_item 2 'DPI Detector'
        menu_item 3 'Проверка DNS-серверов и признаков подмены'
        menu_item 4 'Доступность VPS-сервера'
        menu_item 0 'Назад'
        _read_or_eof 'Выберите пункт (Enter — назад): ' || return 0
        case "$_read_value" in
            1)
                _read_or_eof 'До 5 доменов, IPv4, IPv6 или URL через пробел (0 — назад): ' || return 0
                case "$_read_value" in 0|'') return 0 ;; esac
                _site_targets=$_read_value
                xmenu_site_input_batch "$_site_targets" || :
                pause ;;
            2) launch_dpi; pause ;;
            3)
                _dns_menu_rc=0
                xmenu_dns_diagnose || _dns_menu_rc=$?
                [ "$_dns_menu_rc" != 3 ] || return 0
                pause ;;
            4)
                _read_or_eof 'Публичный IP VPS (IPv4; Enter — назад): ' || return 0
                case "$_read_value" in 0|'') return 0 ;; esac
                xmenu_server_diagnose "$_read_value" || : ;;
            0|'') return 0 ;;
        esac
    done
}

launch_dpi() {
    _dpi_bin='/opt/bin/dpi-detector'
    if [ ! -x "$_dpi_bin" ]; then
        say "${YELLOW}DPI Detector не найден. Устанавливаю официальную Rust-версию для Entware...${RESET}"
        install_dpi_detector force || return $?
    fi

    # Сначала проверяем --version: это позволяет поймать ELF с отсутствующим loader,
    # не перенаправляя stderr интерактивного TUI в файл.
    _dpi_probe=$(xmenu_run_version_probe 3 sh -c 'exec "$1" --version' x "$_dpi_bin" 2>&1)
    _dpi_probe_rc=$?
    if [ "$_dpi_probe_rc" -eq 126 ] || [ "$_dpi_probe_rc" -eq 127 ] ||
       printf '%s\n' "$_dpi_probe" | grep -qiE 'not found|No such file|No such interpreter'; then
        say "${YELLOW}Нативный DPI Detector не запускается (код $_dpi_probe_rc). Переустанавливаю официальную Rust-версию и повторяю проверку.${RESET}"
        case "$_dpi_probe_rc" in
            126|127) : ;; # Не печатаем шум shell для заведомо несовместимого ELF.
            *) [ -z "$_dpi_probe" ] || printf '%s\n' "$_dpi_probe" | sed -n '1,4p' ;;
        esac
        install_dpi_detector force || return 1
        _dpi_probe=$(xmenu_run_version_probe 3 sh -c 'exec "$1" --version' x "$_dpi_bin" 2>&1)
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
        _v=$(xmenu_run_version_probe 3 "$_xkeen_cmd" -v 2>/dev/null | head -n 1 | awk '{print $NF}')
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
            _v=$(xmenu_run_version_probe 3 "$_ui_cmd" -v 2>/dev/null | head -n 1 | awk '{print $NF}')
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
    if _v=$(xmenu_run_version_probe 3 "$_bin" version 2>&1); then
        _v=$(printf '%s\n' "$_v" | sed -n '1p')
    else
        _v=''
    fi
    _v=${_v:-версия неизвестна}
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
    if _v=$(xmenu_run_version_probe 3 "$_bin" -v 2>&1); then
        _v=$(printf '%s\n' "$_v" | sed -n '1p')
    else
        _v=''
    fi
    _v=${_v:-версия неизвестна}
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
                printf '  %s%-22s %s%s %s⚡%s\n' "$PURPLE" "$_row_label" "$BRIGHT_CYAN" "$_row_version" "$GREEN" "$RESET"
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
    if ! xmenu_run_bounded 3 opkg list-installed > "$_OPKG_RENDER_CACHE_FILE" 2>/dev/null; then
        rm -f "$_OPKG_RENDER_CACHE_FILE"
        _OPKG_RENDER_CACHE_FILE=''
        rm -f "$_COMPONENT_INSTALLED_FILE"
        say "${YELLOW}Не удалось прочитать список установленных компонентов; повтори проверку командой xmenu status.${RESET}"
        return 1
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
            _dpi_probe=$(xmenu_run_version_probe 3 sh -c 'exec /opt/bin/dpi-detector --version' 2>/dev/null)
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
        print_component 'TG WS Proxy Rust' yes "$(xmenu_run_version_probe 3 /opt/bin/tg-ws-proxy-rs --version 2>/dev/null | head -n 1)"
    elif [ -x /opt/bin/tgwsproxy ] || [ -x /opt/etc/init.d/S99tgwsproxy ]; then
        print_component 'TG WS Proxy Rust' yes "$(xmenu_run_version_probe 3 /opt/bin/tgwsproxy --version 2>/dev/null | head -n 1)"
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

# Первый список готовим до показа меню. Старый непустой кеш обновляем в фоне;
# новый результат появится при следующем обычном входе в меню, без второй страницы.
render_component_statuses() {
    if [ "${XMENU_FORCE_COMPONENT_REFRESH:-0}" = 1 ]; then
        XMENU_COMPONENT_REFRESH_PENDING=0
        render_component_statuses_sync
        return $?
    fi

    if [ ! -f "$XMENU_COMPONENT_CACHE" ]; then
        XMENU_COMPONENT_REFRESH_PENDING=0
        XMENU_FORCE_COMPONENT_REFRESH=1
        render_component_statuses_sync
        _rcs_first_rc=$?
        unset XMENU_FORCE_COMPONENT_REFRESH
        return "$_rcs_first_rc"
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
    run_remote_installer 'https://raw.githubusercontent.com/rndnaame/nfqws-menu/main/installer_tgws_rs.sh' 'TG WS Proxy Rust' 8000
}

install_usque_keenetic() {
    run_remote_installer 'https://raw.githubusercontent.com/rndnaame/nfqws-menu/main/installer_usque.sh' 'usque-keenetic' 2000 || {
        say "${RED}Установщик usque-keenetic завершился с ошибкой.${RESET}"
        return 1
    }
    invalidate_component_status_cache 2>/dev/null || :
}

install_firc() {
    run_remote_installer 'https://raw.githubusercontent.com/rndnaame/nfqws-menu/main/installer_firc.sh' 'firc' 2000 || {
        say "${RED}Установщик firc завершился с ошибкой.${RESET}"
        return 1
    }
    invalidate_component_status_cache 2>/dev/null || :
}

install_warpscout() {
    run_remote_installer 'https://raw.githubusercontent.com/rndnaame/nfqws-menu/main/installer_warpscout.sh' 'warpscout' 2000 || {
        say "${RED}Установщик warpscout завершился с ошибкой.${RESET}"
        return 1
    }
}

install_magitrickle() {
    invalidate_component_status_cache || return 1
    if is_installed magitrickle; then
        say 'MagiTrickle установлен — проверяю обновление пакета.'
        opkg update && opkg install magitrickle || return 1
        if [ -x /opt/etc/init.d/S99magitrickle ]; then
            /opt/etc/init.d/S99magitrickle restart || return 1
        else
            say "${YELLOW}Пакет обновлён, но init-скрипт MagiTrickle не найден.${RESET}"
        fi
        return 0
    fi
    confirm_yes 'Добавить репозиторий MagiTrickle и установить пакет?' || { say 'Отменено.'; return 0; }
    run_remote_installer 'http://bin.magitrickle.dev/packages/add_repo.sh' 'MagiTrickle repository bootstrap' 300 || return 1
    opkg update && opkg install magitrickle || return 1
    if [ -x /opt/etc/init.d/S99magitrickle ]; then /opt/etc/init.d/S99magitrickle start; fi
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
    say 'Установка будет выполнена из отдельного установочного сценария.'
    confirm_yes 'Установить или обновить awg-manager?' || return 0
    run_remote_installer 'https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh' 'awg-manager' 2000
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
    # Если timeout отсутствует, сохраняем сетевой тайм-аут -T и доступное
    # ограничение повторов вместо отключения загрузчика.
    xmenu_run_bounded "$_xwb_limit" "$_xwb_wget" "$@"
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
            say 'Choose option 21 — Update Xmenu to install it.'
        else
            say "${CYAN}↑ Доступно обновление Xmenu v$_cxu_version (установлена: v$APP_VERSION).${RESET}"
            say 'Для установки выбери пункт 21 — «Обновить Xmenu». '
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
    # Готовность кеша проверяет основной prompt. Сигнал мог прерывать read
    # в подтверждении или подменю и ошибочно отменять выбранное действие.
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
    # Фоновые события больше не вызывают render_menu: кадр и введённые символы
    # остаются на месте, а готовые строки компонентов показываем при следующем входе.
    if [ "${XMENU_COMPONENT_REFRESH_PENDING:-0}" = 1 ] && component_status_cache_fresh; then
        XMENU_COMPONENT_REFRESH_PENDING=0
    fi
    [ "${XMENU_UPDATE_NOTICE_VISIBLE:-0}" = 1 ] && return 1
    _xrpu_latest=$(xmenu_cached_remote_version 2>/dev/null || :)
    xmenu_valid_version "$_xrpu_latest" || return 1
    version_is_older "$APP_VERSION" "$_xrpu_latest" || return 1
    [ -t 1 ] && has_controlling_tty || return 1
    # В высоком терминале обновляем зарезервированную строку под U. Если она
    # уже ушла за верх экрана или терминал изменил размер, используем нижний разделитель.
    _xrpu_up=1
    _xrpu_size=$(stty size </dev/tty 2>/dev/null || :)
    _xrpu_rows=${_xrpu_size%% *}
    _xrpu_columns=${_xrpu_size#* }
    case "${XMENU_UPDATE_SLOT_UP:-}:${_xrpu_rows}:${_xrpu_columns}" in
        *[!0-9:]*|:*|*::*|*:) : ;;
        *)
            if [ "${XMENU_UPDATE_FRAME_COLUMNS:-0}" = "$_xrpu_columns" ] &&
               [ "$XMENU_UPDATE_SLOT_UP" -gt 0 ] && [ "$XMENU_UPDATE_SLOT_UP" -lt "$_xrpu_rows" ]; then
                _xrpu_up=$XMENU_UPDATE_SLOT_UP
            fi ;;
    esac
    printf '\0337\033[%sA\r\033[2K' "$_xrpu_up"
    xmenu_show_pending_update_notice
    printf '\0338'
    # Курсор восстановлен вместе с набранным вводом: приглашение не печатаем второй раз.
    return 1
}

xmenu_show_pending_update_notice() {
    [ "${XMENU_UPDATE_NOTICE_VISIBLE:-0}" = 1 ] && return 0
    _xsp_latest=$(xmenu_cached_remote_version 2>/dev/null || :)
    xmenu_valid_version "$_xsp_latest" || return 0
    version_is_older "$APP_VERSION" "$_xsp_latest" || return 0
    if [ "$(get_ui_lang)" = en ]; then
        _xsp_notice="↑ Update available: Xmenu v$_xsp_latest. Choose option 21 to install it."
    else
        _xsp_notice="↑ Доступно обновление Xmenu v$_xsp_latest. Выбери пункт 21 для установки."
    fi
    _xsp_width=$(terminal_width)
    _xsp_length=$(printf '%s' "$_xsp_notice" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' ')
    if [ $((_xsp_length + 2)) -ge "$_xsp_width" ]; then
        if [ "$(get_ui_lang)" = en ]; then _xsp_notice="↑ Xmenu v$_xsp_latest — update: 21"
        else _xsp_notice="↑ Xmenu v$_xsp_latest — обновить: 21"; fi
    fi
    say "${CYAN}  $_xsp_notice${RESET}"
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
            menu_item 3 'Choose Entware mirror manually'
            menu_item 4 'opkg.conf backups'
            menu_item 5 'Run opkg update'
            menu_item 0 'Back'
            _osm_prompt='[?] Select an option: '
        else
            say "${BRIGHT_CYAN}Репозитории OPKG / Entware:${RESET}"
            xmenu_opkg_show_active_repository ru
            line
            menu_item 1 'Авто-выбор Entware — проверит и выберет доступное зеркало'
            menu_item 2 'Проверить доступность зеркал Entware'
            menu_item 3 'Выбрать зеркало Entware вручную'
            menu_item 4 'Копии opkg.conf'
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
            4) xmenu_opkg_backups_menu ;;
            5)
                say 'opkg update обновляет индексы репозитория, но не установленные пакеты.'
                confirm 'Выполнить opkg update?' && opkg update
                pause ;;
            0|'') return 0 ;;
            *) say 'Неверный пункт.'; sleep 1 ;;
        esac
    done
}

xmenu_opkg_create_backup() {
    [ -f /opt/etc/opkg.conf ] || { say 'Файл /opt/etc/opkg.conf не найден.'; return 1; }
    acquire_lock || return 1
    backup_file /opt/etc/opkg.conf
    _ocb_rc=$?
    release_operation_lock
    return "$_ocb_rc"
}

xmenu_opkg_backups_menu() {
    while :; do
        line
        if [ "$(get_ui_lang)" = en ]; then
            say "${BRIGHT_CYAN}opkg.conf backups${RESET}"
            menu_item 1 'Create opkg.conf backup'
            menu_item 2 'Restore opkg.conf backup'
            menu_item 3 'Delete all opkg.conf backups'
            menu_item 0 'Back'
            _obm_prompt='[?] Select an option: '
        else
            say "${BRIGHT_CYAN}Копии opkg.conf${RESET}"
            menu_item 1 'Создать копию opkg.conf'
            menu_item 2 'Восстановить копию opkg.conf'
            menu_item 3 'Удалить все копии opkg.conf'
            menu_item 0 'Назад'
            _obm_prompt='[?] Выбери пункт: '
        fi
        line
        _read_or_eof "$_obm_prompt" || return 0
        case "$_read_value" in
            1) xmenu_opkg_create_backup; pause ;;
            2) xmenu_opkg_restore_config; pause ;;
            3) xmenu_opkg_remove_backups; pause ;;
            0|'') return 0 ;;
            *) say 'Неверный пункт.' ;;
        esac
    done
}

xmenu_opkg_remove_backups() {
    _xorb_list="$ROOT_DIR/.opkg-backups-remove.$$"
    _xorb_config_dir=${XMENU_OPKG_CONFIG_DIR:-/opt/etc}
    _xorb_backup_dir=${XMENU_OPKG_BACKUP_DIR:-$BACKUP_DIR}
    mkdir -p "$ROOT_DIR" || return 1
    : > "$_xorb_list" || return 1
    if [ -d "$_xorb_config_dir" ] && ! find "$_xorb_config_dir" -maxdepth 1 -type f \
        \( -name 'opkg.conf.*.bak' -o -name 'opkg.conf.bak*' -o -name 'opkg.conf-*.bak' -o -name 'opkg.conf_*.bak' \) \
        -print 2>/dev/null >> "$_xorb_list"; then
        rm -f "$_xorb_list"
        say "${RED}Не удалось проверить копии opkg.conf в $_xorb_config_dir.${RESET}"
        return 1
    fi
    if [ -d "$_xorb_backup_dir" ] && ! find "$_xorb_backup_dir" -maxdepth 1 -type f \
        \( -name 'opkg.conf.*.bak' -o -name 'opkg.conf.bak*' -o -name 'opkg.conf-*.bak' -o -name 'opkg.conf_*.bak' \) \
        -print 2>/dev/null >> "$_xorb_list"; then
        rm -f "$_xorb_list"
        say "${RED}Не удалось проверить копии opkg.conf в $_xorb_backup_dir.${RESET}"
        return 1
    fi
    if [ ! -s "$_xorb_list" ]; then
        rm -f "$_xorb_list"
        say 'Копии opkg.conf не найдены.'
        return 0
    fi
    _xorb_count=$(wc -l < "$_xorb_list" | tr -d ' ')
    say "Найдены копии opkg.conf: $_xorb_count"
    while IFS= read -r _xorb_file || [ -n "$_xorb_file" ]; do
        [ -n "$_xorb_file" ] && printf '  %s\n' "$_xorb_file"
    done < "$_xorb_list"
    confirm_yes 'Удалить перечисленные резервные копии opkg.conf?' || {
        rm -f "$_xorb_list"
        say 'Удаление отменено.'
        return 0
    }
    _xorb_removed=0 _xorb_failed=0
    while IFS= read -r _xorb_file || [ -n "$_xorb_file" ]; do
        [ -n "$_xorb_file" ] || continue
        case "$_xorb_file" in
            "$_xorb_config_dir"/*|"$_xorb_backup_dir"/*) : ;;
            *) _xorb_failed=$((_xorb_failed + 1)); continue ;;
        esac
        if rm -f -- "$_xorb_file"; then _xorb_removed=$((_xorb_removed + 1));
        else _xorb_failed=$((_xorb_failed + 1)); say "${RED}Не удалось удалить $_xorb_file${RESET}"; fi
    done < "$_xorb_list"
    rm -f "$_xorb_list"
    say "Удалено копий opkg.conf: $_xorb_removed"
    [ "$_xorb_failed" -eq 0 ]
}
change_ui_language() {
    _lang_now=$(get_ui_lang)
    if [ "$_lang_now" = en ]; then set_ui_lang ru; else set_ui_lang en; fi
}


# ------------------------------- Service tools -------------------------------
xmenu_service_menu() {
    _xsm_lang=$(get_ui_lang)
    while :; do
        if [ "$_xsm_lang" = en ]; then
            say "${BRIGHT_CYAN}[::]  Service (S):${RESET}"
            menu_item 1 'Dropbear Fix'
            menu_item 2 'Compress bin/sbin (UPX)'
            menu_item 3 'Discord Fix (full voice UDP session in nfqws2)'
            menu_item 0 'Back'
            _xsm_prompt='[?] Select an option: '
        else
            say "${BRIGHT_CYAN}[::]  Сервис (S):${RESET}"
            menu_item 1 'Dropbear Fix'
            menu_item 2 'Сжать bin/sbin (UPX)'
            menu_item 3 'Discord Fix (все UDP-пакеты в nfqws2)'
            menu_item 0 'Назад'
            _xsm_prompt='[?] Выбери пункт: '
        fi
        _read_or_eof "$_xsm_prompt" || return 0
        case "$_read_value" in
            1) xmenu_dropbear_fix ;;
            2) xmenu_compress_binsbin ;;
            3) xmenu_discord_menu ;;
            0|'') return 0 ;;
            *) say 'Неверный пункт.' ;;
        esac
        say ''
    done
}

xmenu_compress_binsbin() {
    say 'UPX сожмёт исполняемые файлы только в /opt/bin и /opt/sbin.'
    say 'Сжатие обратимо командой upx -d; уже сжатые файлы и неподдерживаемые форматы пропускаются.'
    confirm 'Продолжить сжатие bin/sbin?' || { say 'Отменено.'; return 0; }
    if ! command -v upx >/dev/null 2>&1; then
        say 'UPX не найден. Устанавливаю пакет...'
        opkg update || return 1
        opkg install upx || return 1
    fi
    for _xcbs_dir in "${XMENU_OPTBIN:-/opt/bin}" "${XMENU_OPTSBIN:-/opt/sbin}"; do
        [ -d "$_xcbs_dir" ] || continue
        find "$_xcbs_dir" -type f -perm -111 -exec upx --lzma --best {} \; || :
    done
    say 'Обработка исполняемых файлов в /opt/bin и /opt/sbin завершена.'
}

xmenu_dropbear_patch_files() {
    _xdf_conf=$1 _xdf_init=$2 _xdf_passwd=$3 _xdf_reset=${4:-0}
    [ -f "$_xdf_conf" ] && [ -f "$_xdf_init" ] || return 1
    _xdf_stamp="$(date '+%Y%m%d-%H%M%S' 2>/dev/null || printf 'backup')-$$"
    _xdf_conf_bak="$_xdf_conf.xmenu.$_xdf_stamp.bak"
    _xdf_init_bak="$_xdf_init.xmenu.$_xdf_stamp.bak"
    cp -p "$_xdf_conf" "$_xdf_conf_bak" && cp -p "$_xdf_init" "$_xdf_init_bak" || {
        rm -f "$_xdf_conf_bak" "$_xdf_init_bak"
        return 1
    }
    if [ "$_xdf_reset" = 1 ]; then
        _xdf_passwd_bak="$_xdf_passwd.xmenu.$_xdf_stamp.bak"
        cp -p "$_xdf_passwd" "$_xdf_passwd_bak" || {
            rm -f "$_xdf_conf_bak" "$_xdf_init_bak"
            return 1
        }
    fi
    if grep -q '^PORT=22$' "$_xdf_conf"; then sed -i 's/^PORT=22$/PORT=222/' "$_xdf_conf"; fi
    if grep -q 'PIDFILE="/opt/var/run/dropbear.pid"' "$_xdf_init"; then
        sed -i 's|PIDFILE="/opt/var/run/dropbear.pid"|PIDFILE="/var/run/dropbear.pid"|g' "$_xdf_init"
    fi
    if [ "$_xdf_reset" = 1 ] && [ -f "$_xdf_passwd" ]; then
        sed -i 's#^\(root:\)[^:]*#\1$1$6vKOV7zs$d2EqNYGvlBWEYoFD7FFkr0#' "$_xdf_passwd"
    fi
    if ! grep -q '^PORT=222$' "$_xdf_conf" || ! grep -q 'PIDFILE="/var/run/dropbear.pid"' "$_xdf_init"; then
        cp -p "$_xdf_conf_bak" "$_xdf_conf"
        cp -p "$_xdf_init_bak" "$_xdf_init"
        [ "$_xdf_reset" = 1 ] && cp -p "$_xdf_passwd_bak" "$_xdf_passwd"
        return 1
    fi
    if [ "$_xdf_reset" = 1 ] && ! grep -Fq 'root:$1$6vKOV7zs$d2EqNYGvlBWEYoFD7FFkr0:' "$_xdf_passwd"; then
        cp -p "$_xdf_conf_bak" "$_xdf_conf"
        cp -p "$_xdf_init_bak" "$_xdf_init"
        cp -p "$_xdf_passwd_bak" "$_xdf_passwd"
        return 1
    fi
    return 0
}

xmenu_dropbear_fix() {
    _xdf_conf=${XMENU_DROPBEAR_CONF:-/opt/etc/config/dropbear.conf}
    _xdf_init=${XMENU_DROPBEAR_INIT:-/opt/etc/init.d/S51dropbear}
    _xdf_passwd=${XMENU_ENTWARE_PASSWD:-/opt/etc/passwd}
    _xdf_log=${XMENU_DROPBEAR_LOG:-/tmp/xmenu-dropbear-restart.log}
    [ -f "$_xdf_conf" ] || { say "${RED}Не найден $_xdf_conf.${RESET}"; return 1; }
    [ -f "$_xdf_init" ] || { say "${RED}Не найден $_xdf_init — Entware Dropbear не установлен.${RESET}"; return 1; }
    command -v nohup >/dev/null 2>&1 || { say "${RED}Не найден nohup; исправление отменено, чтобы сохранить доступ по SSH.${RESET}"; return 1; }
    say '  1) Исправить порт и PIDFILE без смены пароля'
    say '  2) То же исправление со сбросом пароля root Entware на keenetic'
    say '  0) Назад'
    _read_or_eof '[?] Выбери пункт: ' || return 0
    case "$_read_value" in
        1) _xdf_reset=0 ;;
        2)
            confirm_no 'Сбросить пароль root Entware на известный пароль keenetic?' || { say 'Отменено.'; return 0; }
            [ -f "$_xdf_passwd" ] || { say "${RED}Не найден $_xdf_passwd; пароль не изменён.${RESET}"; return 1; }
            _xdf_reset=1 ;;
        0|'') return 0 ;;
        *) say 'Неверный выбор.'; return 1 ;;
    esac
    _xdf_port=$(sed -n 's/^PORT=//p' "$_xdf_conf" | head -n 1 | tr -d '\r')
    case "$_xdf_port" in ''|*[!0-9]*) _xdf_port=222 ;; esac
    say 'Будут изменены PORT 22 → 222 и PIDFILE /opt/var/run → /var/run.'
    say 'Entware Dropbear будет перезапущен в фоне, текущая SSH-сессия оборвётся.'
    if [ "$_xdf_reset" = 1 ]; then say 'Пароль root Entware станет keenetic.'; fi
    confirm 'Продолжить исправление и перезапустить Dropbear?' || { say 'Отменено.'; return 0; }
    xmenu_dropbear_patch_files "$_xdf_conf" "$_xdf_init" "$_xdf_passwd" "$_xdf_reset" || {
        say "${RED}Изменения не прошли проверку; исходные настройки восстановлены.${RESET}"
        return 1
    }
    _xdf_port=$(sed -n 's/^PORT=//p' "$_xdf_conf" | head -n 1 | tr -d '\r')
    rm -f "$_xdf_log"
    nohup sh -c "trap '' HUP; sleep 2; '$_xdf_init' stop >>'$_xdf_log' 2>&1 || true; killall -9 dropbear >>'$_xdf_log' 2>&1 || true; rm -f /opt/var/run/dropbear.pid /var/run/dropbear.pid; sleep 1; '$_xdf_init' start >>'$_xdf_log' 2>&1 || /opt/sbin/dropbear -p '$_xdf_port' >>'$_xdf_log' 2>&1" </dev/null >>"$_xdf_log" 2>&1 &
    say "Перезапуск запланирован на порту $_xdf_port. Резервные копии сохранены рядом с конфигом и init-файлом; журнал: $_xdf_log"
}

xmenu_discord_config_value() {
    _xdcv_key=$1 _xdcv_file=$2
    [ -f "$_xdcv_file" ] || return 0
    {
        sed -n "s/^[[:space:]]*${_xdcv_key}[[:space:]]*=[[:space:]]*//p" "$_xdcv_file"
        [ -f "$_xdcv_file.run" ] && sed -n "s/^[[:space:]]*${_xdcv_key}[[:space:]]*=[[:space:]]*//p" "$_xdcv_file.run"
    } | tail -n 1 | tr -d "'\"\r" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

xmenu_discord_ports() {
    _xdp_ports=$(xmenu_discord_config_value PORTS "${XMENU_DISCORD_CONF:-${XMENU_DISCORD_DIR:-/opt/etc/nfqws2-fullsession}/fullsession.conf}")
    [ -n "$_xdp_ports" ] || _xdp_ports='19294:19344,50000:50100'
    case "$_xdp_ports" in *[!0-9,:-]*|'') return 1 ;; esac
    printf '%s\n' "$_xdp_ports"
}

xmenu_discord_config() {
    _xdc_file=${XMENU_NFQWS2_CONF:-/opt/etc/nfqws2/nfqws2.conf}
    _xdc_iface=$(xmenu_discord_config_value ISP_INTERFACE "$_xdc_file")
    _xdc_queue=$(xmenu_discord_config_value NFQUEUE_NUM "$_xdc_file")
    _xdc_mark=$(xmenu_discord_config_value POLICY_MARK "$_xdc_file")
    _xdc_exclude=$(xmenu_discord_config_value POLICY_EXCLUDE "$_xdc_file")
    [ -n "$_xdc_iface" ] || _xdc_iface=eth3
    [ -n "$_xdc_queue" ] || _xdc_queue=300
    case "$_xdc_queue" in *[!0-9]*|'') _xdc_queue=300 ;; esac
    case "$_xdc_mark" in *[!0-9A-Fa-fxX./]*) _xdc_mark='' ;; esac
    case "$_xdc_exclude" in 0|1) : ;; *) _xdc_exclude=0 ;; esac
    XMENU_DISCORD_IFACES=$_xdc_iface
    XMENU_DISCORD_QUEUE=$_xdc_queue
    XMENU_DISCORD_POLICY_MARK=$_xdc_mark
    XMENU_DISCORD_POLICY_EXCLUDE=$_xdc_exclude
}

xmenu_discord_nfqws2_ready() {
    _xdnr_init=${XMENU_NFQWS2_INIT:-/opt/etc/init.d/S51nfqws2}
    _xdnr_conf=${XMENU_NFQWS2_CONF:-/opt/etc/nfqws2/nfqws2.conf}
    [ -f "$_xdnr_init" ] && [ -f "$_xdnr_conf" ]
}

xmenu_discord_ppe_available() {
    _xdpa_chain="XDP$$"
    iptables -w -t mangle -N "$_xdpa_chain" 2>/dev/null || return 1
    _xdpa_rc=1
    iptables -w -t mangle -A "$_xdpa_chain" -j PPE 2>/dev/null && _xdpa_rc=0
    iptables -w -t mangle -F "$_xdpa_chain" 2>/dev/null || :
    iptables -w -t mangle -X "$_xdpa_chain" 2>/dev/null || :
    return "$_xdpa_rc"
}

xmenu_discord_chain_sync() {
    _xdcs_chain=$1 _xdcs_parent=$2 _xdcs_rules=$3
    _xdcs_tmp="${_xdcs_chain}_new"
    iptables -w -t mangle -N "$_xdcs_tmp" 2>/dev/null || :
    iptables -w -t mangle -F "$_xdcs_tmp" || return 1
    printf '%s\n' "$_xdcs_rules" | while IFS= read -r _xdcs_rule; do
        [ -n "$_xdcs_rule" ] || continue
        # shellcheck disable=SC2086
        iptables -w -t mangle -A "$_xdcs_tmp" $_xdcs_rule || exit 1
    done || { iptables -w -t mangle -F "$_xdcs_tmp"; iptables -w -t mangle -X "$_xdcs_tmp"; return 1; }
    iptables -w -t mangle -I "$_xdcs_parent" -j "$_xdcs_tmp" || {
        iptables -w -t mangle -F "$_xdcs_tmp"; iptables -w -t mangle -X "$_xdcs_tmp"; return 1;
    }
    while iptables -w -t mangle -C "$_xdcs_parent" -j "$_xdcs_chain" 2>/dev/null; do
        iptables -w -t mangle -D "$_xdcs_parent" -j "$_xdcs_chain" || return 1
    done
    iptables -w -t mangle -F "$_xdcs_chain" 2>/dev/null || :
    iptables -w -t mangle -X "$_xdcs_chain" 2>/dev/null || :
    iptables -w -t mangle -E "$_xdcs_tmp" "$_xdcs_chain"
}

xmenu_discord_rules_remove_chain() {
    _xdrr_chain=$1 _xdrr_parent=$2
    while iptables -w -t mangle -C "$_xdrr_parent" -j "$_xdrr_chain" 2>/dev/null; do
        iptables -w -t mangle -D "$_xdrr_parent" -j "$_xdrr_chain" || return 1
    done
    iptables -w -t mangle -F "$_xdrr_chain" 2>/dev/null || :
    iptables -w -t mangle -X "$_xdrr_chain" 2>/dev/null || :
}

xmenu_discord_rules_remove() {
    xmenu_discord_rules_remove_chain xmenu_discord_post POSTROUTING
    xmenu_discord_rules_remove_chain xmenu_discord_fwd FORWARD
}

xmenu_discord_rules_apply() {
    _xdra_state=${XMENU_DISCORD_CONF:-${XMENU_DISCORD_DIR:-/opt/etc/nfqws2-fullsession}/fullsession.conf}
    [ -s "$_xdra_state" ] || return 0
    xmenu_discord_nfqws2_ready || { say 'nfqws2 не установлен или не найден его конфиг.'; return 1; }
    xmenu_discord_config
    _xdra_ports=$(xmenu_discord_ports) || { say 'Недопустимый список Discord-портов.'; return 1; }
    _xdra_post='' _xdra_fwd=''
    for _xdra_iface in $XMENU_DISCORD_IFACES; do
        case "$_xdra_iface" in *[!A-Za-z0-9_.:-]*|'') continue ;; esac
        if [ -n "$XMENU_DISCORD_POLICY_MARK" ]; then
            _xdra_policy=''
            [ "$XMENU_DISCORD_POLICY_EXCLUDE" = 1 ] || _xdra_policy='! '
            _xdra_post="$_xdra_post-o $_xdra_iface -m mark ${_xdra_policy}--mark $XMENU_DISCORD_POLICY_MARK -j RETURN
"
            _xdra_fwd="$_xdra_fwd-o $_xdra_iface -m mark ${_xdra_policy}--mark $XMENU_DISCORD_POLICY_MARK -j RETURN
"
        fi
        _xdra_post="$_xdra_post-o $_xdra_iface -m mark ! --mark 0x40000000/0x40000000 -p udp -m multiport --dports $_xdra_ports -j NFQUEUE --queue-num $XMENU_DISCORD_QUEUE --queue-bypass
"
        _xdra_fwd="$_xdra_fwd-o $_xdra_iface -p udp -m multiport --dports $_xdra_ports -j PPE
-i $_xdra_iface -p udp -m multiport --sports $_xdra_ports -j PPE
"
    done
    [ -n "$_xdra_post" ] || { say 'Не найдены подходящие значения ISP_INTERFACE.'; return 1; }
    if xmenu_discord_ppe_available; then
        xmenu_discord_chain_sync xmenu_discord_fwd FORWARD "$_xdra_fwd" || return 1
    else
        xmenu_discord_rules_remove_chain xmenu_discord_fwd FORWARD || :
        say 'Цель PPE недоступна; очередь NFQUEUE установлена, но fastpath исключение недоступно.'
    fi
    # Match the upstream ordering: exclude Discord flows from PPE before
    # installing NFQUEUE, so early packets cannot escape to fastpath.
    xmenu_discord_chain_sync xmenu_discord_post POSTROUTING "$_xdra_post" || return 1
}

xmenu_discord_enable() {
    _xde_dir=${XMENU_DISCORD_DIR:-/opt/etc/nfqws2-fullsession}
    _xde_conf=${XMENU_DISCORD_CONF:-$_xde_dir/fullsession.conf}
    _xde_init=${XMENU_DISCORD_INIT:-/opt/etc/init.d/S52xmenu-discord-fullsession}
    _xde_hook=${XMENU_DISCORD_HOOK:-/opt/etc/ndm/netfilter.d/101-xmenu-discord-fullsession.sh}
    xmenu_discord_nfqws2_ready || { say 'Для Discord Fix сначала установи nfqws2.'; return 1; }
    mkdir -p "$_xde_dir" "$(dirname "$_xde_init")" "$(dirname "$_xde_hook")" || return 1
    _xde_ports=$(xmenu_discord_ports) || { say 'Недопустимый список Discord-портов.'; return 1; }
    _xde_tmp="$_xde_conf.tmp.$$"
    printf 'PORTS=%s\n' "$_xde_ports" > "$_xde_tmp" && mv "$_xde_tmp" "$_xde_conf" || return 1
    _xde_bin=${XMENU_BIN_PATH:-/opt/bin/xmenu}
    cat > "$_xde_hook" <<EOF
#!/bin/sh
[ "\$type" = iptables ] && [ "\$table" = mangle ] || exit 0
[ -s $_xde_conf ] && $_xde_bin discord-fix-rules >/dev/null 2>&1
exit 0
EOF
    cat > "$_xde_init" <<EOF
#!/bin/sh
case "\$1" in
  start|restart) $_xde_bin discord-fix-rules ;;
  stop) $_xde_bin discord-fix-unrules ;;
  status) $_xde_bin discord-fix-status ;;
  *) echo "Usage: \$0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF
    chmod 700 "$_xde_hook" "$_xde_init" || return 1
    xmenu_discord_rules_apply || {
        xmenu_discord_rules_remove
        rm -f "$_xde_hook" "$_xde_init" "$_xde_conf"
        return 1
    }
    say 'Discord Fix включён: UDP-сессии направляются в NFQWS2, правила восстановятся при загрузке.'
}

xmenu_discord_disable() {
    _xdd_conf=${XMENU_DISCORD_CONF:-${XMENU_DISCORD_DIR:-/opt/etc/nfqws2-fullsession}/fullsession.conf}
    _xdd_init=${XMENU_DISCORD_INIT:-/opt/etc/init.d/S52xmenu-discord-fullsession}
    _xdd_hook=${XMENU_DISCORD_HOOK:-/opt/etc/ndm/netfilter.d/101-xmenu-discord-fullsession.sh}
    confirm 'Выключить Discord Fix и удалить его правила?' || { say 'Отменено.'; return 0; }
    xmenu_discord_rules_remove
    rm -f "$_xdd_hook" "$_xdd_init" "$_xdd_conf"
    say 'Discord Fix выключен; собственные правила, hook и init-файл удалены.'
}

xmenu_discord_status() {
    _xds_conf=${XMENU_DISCORD_CONF:-${XMENU_DISCORD_DIR:-/opt/etc/nfqws2-fullsession}/fullsession.conf}
    if [ -s "$_xds_conf" ]; then
        _xds_ports=$(xmenu_discord_ports)
        say "Discord Fix: включён (UDP-порты $_xds_ports)."
    else
        say 'Discord Fix: выключен.'
    fi
    if pidof nfqws2 >/dev/null 2>&1; then say 'nfqws2: запущен.'; else say 'nfqws2: не запущен.'; fi
    _xds_save=$(iptables-save -t mangle 2>/dev/null || :)
    _xds_post=$(printf '%s\n' "$_xds_save" | grep -E -- '-A xmenu_discord_post .*NFQUEUE' | wc -l | tr -d ' ')
    _xds_ppe=$(printf '%s\n' "$_xds_save" | grep -E -- '-A xmenu_discord_fwd .* -j PPE' | wc -l | tr -d ' ')
    say "Правила полной UDP-сессии: NFQUEUE=$_xds_post, PPE=$_xds_ppe."
    xmenu_discord_ppe_available && say 'PPE: доступно.' || say 'PPE: недоступно; NFQUEUE продолжает работать.'
    if [ -x /opt/sbin/xkeen ]; then
        _xds_exclude=${XMENU_XKEEN_EXCLUDE:-/opt/etc/xkeen/port_exclude.lst}
        if grep -q '19294:19344' "$_xds_exclude" 2>/dev/null && grep -q '50000:50100' "$_xds_exclude" 2>/dev/null; then
            say 'XKeen: Discord-порты исключены.'
        else
            say 'XKeen: порты Discord ещё не исключены.'
        fi
    fi
}

xmenu_discord_xkeen_exclude() {
    _xdx_file=${XMENU_XKEEN_EXCLUDE:-/opt/etc/xkeen/port_exclude.lst}
    [ -x /opt/sbin/xkeen ] || { say 'XKeen не найден.'; return 1; }
    _xdx_dir=$(dirname "$_xdx_file")
    mkdir -p "$_xdx_dir" || return 1
    if [ -f "$_xdx_file" ]; then
        _xdx_bak="$_xdx_file.xmenu.$(date '+%Y%m%d-%H%M%S').bak"
        cp -p "$_xdx_file" "$_xdx_bak" || return 1
        touch "$_xdx_file"
    else
        : > "$_xdx_file" || return 1
    fi
    grep -Fxq '19294:19344' "$_xdx_file" || printf '%s\n' '19294:19344' >> "$_xdx_file"
    grep -Fxq '50000:50100' "$_xdx_file" || printf '%s\n' '50000:50100' >> "$_xdx_file"
    say "Discord-порты добавлены в $_xdx_file."
    if pidof xray >/dev/null 2>&1 && confirm 'Перезапустить XKeen сейчас?'; then
        /opt/sbin/xkeen -restart >/dev/null 2>&1 && say 'XKeen перезапускается.'
    fi
}

xmenu_discord_menu() {
    xmenu_discord_nfqws2_ready || { say 'Для Discord Fix сначала установи nfqws2 (пункт 4).'; return 1; }
    _xdm_lang=$(get_ui_lang)
    while :; do
        if [ "$_xdm_lang" = en ]; then
            say "${BRIGHT_CYAN}Discord: full voice UDP session in nfqws2${RESET}"
            menu_item 1 'Status / diagnostics'
            menu_item 2 'Enable fix'
            menu_item 3 'Disable fix'
            [ -x /opt/sbin/xkeen ] && menu_item 4 'XKeen: exclude Discord ports'
            menu_item 0 'Back'
            _xdm_prompt='[?] Select an option: '
        else
            say "${BRIGHT_CYAN}Discord: весь голосовой UDP-трафик в nfqws2${RESET}"
            menu_item 1 'Статус / диагностика'
            menu_item 2 'Включить фикс'
            menu_item 3 'Выключить фикс'
            [ -x /opt/sbin/xkeen ] && menu_item 4 'XKeen: исключить порты Discord'
            menu_item 0 'Назад'
            _xdm_prompt='[?] Выбери пункт: '
        fi
        _read_or_eof "$_xdm_prompt" || return 0
        case "$_read_value" in
            1) xmenu_discord_status ;;
            2) xmenu_discord_enable ;;
            3) xmenu_discord_disable ;;
            4) xmenu_discord_xkeen_exclude ;;
            0|'') return 0 ;;
            *) say 'Неверный пункт.' ;;
        esac
        say ''
    done
}

# DNS server and filter tools use local Keenetic CLI operations.
xmenu_dns_valid_host() {
    printf '%s\n' "${1:-}" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:%-]*$' &&
        ! printf '%s\n' "$1" | grep -q '\.\.'
}

xmenu_dns_valid_domain() {
    printf '%s\n' "${1:-}" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$' &&
        ! printf '%s\n' "$1" | grep -q '\.\.'
}

xmenu_dns_valid_port() {
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    awk -v n="$1" 'BEGIN { exit !(n >= 1 && n <= 65535) }'
}

xmenu_dns_valid_uri() {
    printf '%s\n' "${1:-}" | LC_ALL=C grep -Eq '^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?(/[A-Za-z0-9._~:/?#@%+=&-]*)?$'
}

xmenu_dns_ndmc() {
    LD_LIBRARY_PATH=/lib:/usr/lib ndmc -c "$*"
}

xmenu_dns_save() {
    if xmenu_dns_ndmc 'system configuration save' >/dev/null 2>&1; then
        say 'Конфигурация Keenetic сохранена.'
    else
        say "${RED}Не удалось сохранить конфигурацию Keenetic.${RESET}"
        return 1
    fi
}

xmenu_dns_show() {
    command -v ndmc >/dev/null 2>&1 || { say 'ndmc не найден: управление DNS доступно только на Keenetic/Netcraze OS.'; return 1; }
    say "${BRIGHT_CYAN}DNS-серверы Keenetic${RESET}"
    say ''
    {
        xmenu_dns_ndmc 'show dns-proxy' 2>/dev/null
        printf '\nXMENU_RUNNING_CONFIG\n'
        xmenu_dns_ndmc 'show running-config' 2>/dev/null
    } | awk '
        function save_server(   value,key) {
            value = (kind == "DoT" ? address : uri)
            if (value != "") {
                if (kind == "DoT" && port != "" && port != "853") value = value ":" port
                if (sni != "") value = value " (" sni ")"
                if (domain != "") value = value " → " domain
                key = scope "|" kind "|" value
                if (filter && !seen[key]++) filters[++nf] = kind ": " value " [" scope "]"
                else if (!filter && scope == "System" && !seen[key]++) {
                    if (kind == "DoT") dot[++nt] = value
                    else doh[++nh] = value
                }
            }
            address = uri = port = sni = domain = ""
        }
        /^XMENU_RUNNING_CONFIG$/ { save_server(); config = 1; next }
        config {
            if ($1 == "dns-proxy" && $2 == "filter" && $3 == "profile" && ($5 == "tls" || $5 == "https") && $6 == "upstream") {
                value = ($5 == "tls" ? "DoT: " : "DoH: ") $7
                if ($5 == "tls" && $8 ~ /^[0-9]+$/ && $8 != "853") value = value ":" $8
                if (!profile_seen[value]++) profiles[++np] = $4 ": " value
            }
            if ($1 == "dns-proxy" && $2 == "filter" && $3 == "assign" && ($4 == "host" || $4 == "interface")) {
                value = ($4 == "host" ? "Устройство " : "Сеть ") $6 ": " $7
                if (!assign_seen[value]++) assignments[++na] = value
            }
            next
        }
        /^[[:space:]]*proxy-name:/ { save_server(); scope = $2; kind = ""; filter = 0; next }
        /^[[:space:]]*proxy-(tls|https)(-filters)?:/ {
            save_server(); filter = ($1 ~ /-filters:/); kind = ($1 ~ /https/ ? "DoH" : "DoT"); next
        }
        /^[[:space:]]*proxy-[A-Za-z-]+:/ { save_server(); kind = ""; next }
        /^[[:space:]]*server-(tls|https):/ { save_server(); kind = ($1 ~ /https/ ? "DoH" : "DoT"); next }
        kind != "" && $1 == "address:" { address = $2; next }
        kind != "" && $1 == "port:" { port = $2; next }
        kind != "" && $1 == "sni:" { sni = $2; next }
        kind != "" && $1 == "uri:" { uri = $2; next }
        kind != "" && $1 == "domain:" { domain = $2; next }
        /^[[:space:]]*dns_server[[:space:]]*=/ {
            if ($3 != "" && $3 !~ /^127\./ && $3 !~ /^\[?::1\]?(:|$)/ && !plain_seen[$3]++) plain[++nn] = $3
            next
        }
        END {
            save_server()
            print "Интернет-фильтры"
            if (nf + np + na == 0) print "Отдельные DNS-серверы фильтров не настроены."
            for (i = 1; i <= nf; i++) print "" filters[i]
            for (i = 1; i <= np; i++) print "" profiles[i]
            for (i = 1; i <= na; i++) print "" assignments[i]
            if (nn > 0) {
                print ""
                print "DNS без шифрования"
                for (i = 1; i <= nn; i++) print "" plain[i]
            }
            print ""
            print "Общие DNS: DoT " nt+0 "/8 · DoH " nh+0 "/8"
            for (i = 1; i <= nt; i++) print "DoT: " dot[i]
            for (i = 1; i <= nh; i++) print "DoH: " doh[i]
            if (nt + nh == 0) print "Дополнительные серверы не добавлены."
            else print "Запросы к этим серверам передаются с шифрованием."
        }
    '
    say ''
    say 'DoT и DoH шифруют DNS-запросы.'
    say 'Общие серверы и DNS интернет-фильтров настраиваются отдельно.'
}

xmenu_dns_apply_dot() {
    _xdda_host=$1 _xdda_port=$2 _xdda_sni=$3 _xdda_domain=$4
    xmenu_dns_valid_host "$_xdda_host" || { say 'Некорректный адрес DoT.'; return 1; }
    [ -z "$_xdda_port" ] || xmenu_dns_valid_port "$_xdda_port" || { say 'Порт должен быть числом от 1 до 65535.'; return 1; }
    [ -z "$_xdda_sni" ] || xmenu_dns_valid_domain "$_xdda_sni" || { say 'Некорректное имя SNI.'; return 1; }
    [ -z "$_xdda_domain" ] || xmenu_dns_valid_domain "$_xdda_domain" || { say 'Некорректный домен привязки.'; return 1; }
    _xdda_cmd="dns-proxy tls upstream $_xdda_host"
    [ -z "$_xdda_port" ] || _xdda_cmd="$_xdda_cmd $_xdda_port"
    [ -z "$_xdda_sni" ] || _xdda_cmd="$_xdda_cmd sni $_xdda_sni"
    [ -z "$_xdda_domain" ] || _xdda_cmd="$_xdda_cmd domain $_xdda_domain"
    xmenu_dns_ndmc "$_xdda_cmd" >/dev/null 2>&1 || { say "${RED}ndmc отклонил добавление DoT: $_xdda_host${RESET}"; return 1; }
    return 0
}

xmenu_dns_apply_doh() {
    _xddh_uri=$1 _xddh_domain=$2
    xmenu_dns_valid_uri "$_xddh_uri" || { say 'Разрешён только корректный HTTPS URI DoH без пробелов и управляющих символов.'; return 1; }
    [ -z "$_xddh_domain" ] || xmenu_dns_valid_domain "$_xddh_domain" || { say 'Некорректный домен привязки.'; return 1; }
    _xddh_cmd="dns-proxy https upstream $_xddh_uri"
    [ -z "$_xddh_domain" ] || _xddh_cmd="$_xddh_cmd domain $_xddh_domain"
    xmenu_dns_ndmc "$_xddh_cmd" >/dev/null 2>&1 || { say "${RED}ndmc отклонил добавление DoH: $_xddh_uri${RESET}"; return 1; }
    return 0
}

xmenu_dns_dot_data() {
    cat <<'EOF'
1|Yandex|77.88.8.8|common.dot.dns.yandex.net|
2|Cloudflare|1.1.1.1|cloudflare-dns.com|
3|Google|8.8.8.8|dns.google|
4|Quad9|9.9.9.9|dns.quad9.net|
5|CleanBrowsing|185.228.168.9|security-filter-dns.cleanbrowsing.org|853
6|OpenDNS|208.67.222.222|dns.opendns.com|
7|AdGuard Default|94.140.14.14|dns.adguard-dns.com|
8|AdGuard Family|94.140.14.15|family.adguard-dns.com|
9|ControlD Free|p0.freedns.controld.com|p0.freedns.controld.com|
10|DNS.SB|185.222.222.222|dot.sb|
11|DNS4EU Protective|protective.joindns4.eu|protective.joindns4.eu|
12|Alibaba DNS|dns.alidns.com|dns.alidns.com|
13|DNSPod|dot.pub|dot.pub|
14|Xbox-DNS|xbox-dns.ru|xbox-dns.ru|
15|Comss DNS|dns.comss.one|dns.comss.one|
16|Malw Link|dns.malw.link|dns.malw.link|
17|NullsProxy|dns.nullsproxy.com|dns.nullsproxy.com|
18|Geo Hide|geohide.ru|geohide.ru|
19|AstraCat|dns.astracat.network|dns.astracat.network|
20|Bezmezhau|dns.bezmezhau.com|dns.bezmezhau.com|
21|DNS-AI|dns.dns-ai.ru|dns.dns-ai.ru|
22|Mafioznik|dns.mafioznik.xyz|dns.mafioznik.xyz|
23|Shecan Free|free.shecan.ir|free.shecan.ir|
EOF
}

xmenu_dns_doh_data() {
    cat <<'EOF'
1|Yandex|https://77.88.8.8/dns-query
2|Cloudflare|https://cloudflare-dns.com/dns-query
3|Google|https://dns.google/dns-query
4|Quad9|https://dns.quad9.net/dns-query
5|CleanBrowsing|https://doh.cleanbrowsing.org/doh/security-filter/
6|OpenDNS|https://doh.opendns.com/dns-query
7|AdGuard Default|https://dns.adguard-dns.com/dns-query
8|AdGuard Family|https://family.adguard-dns.com/dns-query
9|ControlD Free|https://freedns.controld.com/p0
10|DNS.SB|https://doh.dns.sb/dns-query
11|DNS4EU Protective|https://protective.joindns4.eu/dns-query
12|DNS4EU Unfiltered|https://unfiltered.joindns4.eu/dns-query
13|Alibaba DNS|https://dns.alidns.com/dns-query
14|DNSPod|https://doh.pub/dns-query
15|Xbox-DNS|https://xbox-dns.ru/dns-query
16|Comss DNS|https://dns.comss.one/dns-query
17|Malw Link|https://dns.malw.link/dns-query
18|NullsProxy|https://dns.nullsproxy.com/dns-query
19|Geo Hide|https://dns.geohide.ru/dns-query
20|AstraCat|https://dns.astracat.network/dns-query
21|Bezmezhau|https://dns.bezmezhau.com/dns-query
22|DNS-AI|https://dns.dns-ai.ru/dns-query
23|Mafioznik|https://dns.mafioznik.xyz/dns-query
24|Shecan Free|https://free.shecan.ir/dns-query
EOF
}

xmenu_dns_add_menu() {
    _xdadd_kind=$1
    if [ "$_xdadd_kind" = dot ]; then
        xmenu_dns_dot_data | while IFS='|' read -r n label host sni _port; do
            say "  $n) $label — $host${sni:+ (SNI $sni)}"
        done
        say "${BRIGHT_CYAN}  99) Ввести вручную${RESET}"
    else
        xmenu_dns_doh_data | while IFS='|' read -r n label uri; do say "  $n) $label — $uri"; done
        say "${BRIGHT_CYAN}  99) Ввести вручную${RESET}"
    fi
    say '  0) Назад'
    _read_or_eof 'Номера серверов через запятую: ' || return 1
    _xdadd_choices=$(printf '%s' "$_read_value" | tr ',' ' ')
    if ! printf '%s\n' "$_xdadd_choices" | LC_ALL=C grep -Eq '^[0-9 ]*$'; then say 'Неверный список номеров.'; return 1; fi
    _read_or_eof 'Привязать серверы к домену (Enter — общие): ' || return 1
    _xdadd_domain=$_read_value
    [ -z "$_xdadd_domain" ] || xmenu_dns_valid_domain "$_xdadd_domain" || { say 'Некорректный домен.'; return 1; }
    _xdadd_added=0
    for _xdadd_choice in $_xdadd_choices; do
        [ "$_xdadd_choice" = 0 ] && continue
        if [ "$_xdadd_kind" = dot ]; then
            if [ "$_xdadd_choice" = 99 ]; then
                _read_or_eof 'Адрес DoT: ' || return 1; _xdadd_host=$_read_value
                _read_or_eof 'Порт (Enter — 853): ' || return 1; _xdadd_port=$_read_value
                _read_or_eof 'SNI (Enter — без SNI): ' || return 1; _xdadd_sni=$_read_value
            else
                _xdadd_row=$(xmenu_dns_dot_data | awk -F'|' -v n="$_xdadd_choice" '$1 == n {print; exit}')
                [ -n "$_xdadd_row" ] || continue
                IFS='|' read -r _xdadd_n _xdadd_label _xdadd_host _xdadd_sni _xdadd_port <<EOF
$_xdadd_row
EOF
            fi
            if xmenu_dns_apply_dot "$_xdadd_host" "$_xdadd_port" "$_xdadd_sni" "$_xdadd_domain"; then _xdadd_added=1; fi
        else
            if [ "$_xdadd_choice" = 99 ]; then
                _read_or_eof 'HTTPS URI DoH: ' || return 1; _xdadd_uri=$_read_value
            else
                _xdadd_row=$(xmenu_dns_doh_data | awk -F'|' -v n="$_xdadd_choice" '$1 == n {print; exit}')
                [ -n "$_xdadd_row" ] || continue
                IFS='|' read -r _xdadd_n _xdadd_label _xdadd_uri <<EOF
$_xdadd_row
EOF
            fi
            if xmenu_dns_apply_doh "$_xdadd_uri" "$_xdadd_domain"; then _xdadd_added=1; fi
        fi
    done
    [ "$_xdadd_added" = 1 ] && xmenu_dns_save
}

xmenu_dns_domain_presets() {
    say '1) CleanBrowsing DoT -> instagram.com'
    say '2) CleanBrowsing DoH -> instagram.com'
    say '3) CleanBrowsing DoT -> cdninstagram.com'
    say '4) CleanBrowsing DoH -> cdninstagram.com'
    say '5) sw.ext.io DoT -> rutor.is и rutor.info'
    say '6) Malw Link DoH -> ntc.party'
    say '7) Xbox-DNS DoT -> Twitch'
    say '8) Xbox-DNS DoH -> Twitch'
    say '9) NullsProxy DoT -> домены Supercell'
    say '10) NullsProxy DoH -> домены Supercell'
    say '0) Назад'
    _read_or_eof 'Выбери пресет: ' || return 1
    _xdpr_added=0
    case "$_read_value" in
        1) xmenu_dns_apply_dot 185.228.168.9 853 security-filter-dns.cleanbrowsing.org instagram.com && _xdpr_added=1 ;;
        2) xmenu_dns_apply_doh https://doh.cleanbrowsing.org/doh/security-filter/ instagram.com && _xdpr_added=1 ;;
        3) xmenu_dns_apply_dot 185.228.168.9 853 security-filter-dns.cleanbrowsing.org cdninstagram.com && _xdpr_added=1 ;;
        4) xmenu_dns_apply_doh https://doh.cleanbrowsing.org/doh/security-filter/ cdninstagram.com && _xdpr_added=1 ;;
        5) xmenu_dns_apply_dot sw.ext.io '' '' rutor.is && xmenu_dns_apply_dot sw.ext.io '' '' rutor.info && _xdpr_added=1 ;;
        6) xmenu_dns_apply_doh https://dns.malw.link/dns-query ntc.party && _xdpr_added=1 ;;
        7) xmenu_dns_apply_dot xbox-dns.ru 853 xbox-dns.ru gql.twitch.tv && xmenu_dns_apply_dot xbox-dns.ru 853 xbox-dns.ru usher.ttvnw.net && _xdpr_added=1 ;;
        8) xmenu_dns_apply_doh https://xbox-dns.ru/dns-query gql.twitch.tv && xmenu_dns_apply_doh https://xbox-dns.ru/dns-query usher.ttvnw.net && _xdpr_added=1 ;;
        9|10)
            for _xdpr_domain in supercell.com supercellid.com brawlstarsgame.com clashofclans.com clashroyaleapp.com; do
                if [ "$_read_value" = 9 ]; then xmenu_dns_apply_dot dns.nullsproxy.com 853 dns.nullsproxy.com "$_xdpr_domain" && _xdpr_added=1
                else xmenu_dns_apply_doh https://dns.nullsproxy.com/dns-query "$_xdpr_domain" && _xdpr_added=1; fi
            done
            ;;
        0|'') return 0 ;;
        *) say 'Неизвестный пресет.'; return 1 ;;
    esac
    [ "$_xdpr_added" = 1 ] && xmenu_dns_save
}

xmenu_dns_remove_menu() {
    _xdrem_tmp="${ROOT_DIR}/.dns-upstreams.$$"
    mkdir -p "$ROOT_DIR" || return 1
    umask 077
    xmenu_dns_ndmc 'show dns-proxy' 2>/dev/null | awk '
        function emit() {if(type=="dot") print "dot|" addr "|" port "|" domain; else if(type=="doh") print "doh|" uri "||" domain}
        /^ *proxy-name:/ {if(type=="dot"&&addr!="") emit(); if(type=="doh"&&uri!="") emit(); scope=$2; type=""; addr=port=uri=domain=""; next}
        /^ *proxy-tls:/ {type=(scope=="System"?"dot":""); next}
        /^ *proxy-https:/ {if(type=="dot"&&addr!="") emit(); type=(scope=="System"?"doh":""); next}
        /^ *proxy-tls-filters:/ || /^ *proxy-https-filters:/ {if(type=="dot"&&addr!="") emit(); if(type=="doh"&&uri!="") emit(); type=""; next}
        /^ *server-tls:/ {if(type=="dot"&&addr!="") emit(); type=(scope=="System"?"dot":""); addr=port=domain=""; next}
        /^ *server-https:/ {if(type=="doh"&&uri!="") emit(); type=(scope=="System"?"doh":""); uri=domain=""; next}
        type=="dot"&&$1=="address:" {addr=$2; next}
        type=="dot"&&$1=="port:" {port=$2; next}
        type=="dot"&&$1=="domain:" {domain=$2; next}
        type=="doh"&&$1=="uri:" {uri=$2; next}
        type=="doh"&&$1=="domain:" {domain=$2; next}
        END {if(type=="dot"&&addr!="") emit(); if(type=="doh"&&uri!="") emit()}
    ' > "$_xdrem_tmp"
    if [ ! -s "$_xdrem_tmp" ]; then rm -f "$_xdrem_tmp"; say 'Общие DoT/DoH серверы не найдены.'; return 0; fi
    say 'Общие upstream серверы (записи интернет-фильтров не удаляются этим пунктом):'
    _xdrem_n=0
    while IFS='|' read -r _xdrem_type _xdrem_target _xdrem_port _xdrem_domain; do
        _xdrem_n=$((_xdrem_n + 1))
        printf '  %s) %s %s %s %s\n' "$_xdrem_n" "$_xdrem_type" "$_xdrem_target" "$_xdrem_port" "$_xdrem_domain"
    done < "$_xdrem_tmp"
    _read_or_eof 'Номера для удаления через запятую (0 — назад): ' || { rm -f "$_xdrem_tmp"; return 1; }
    _xdrem_choices=$(printf '%s' "$_read_value" | tr ',' ' ')
    if ! printf '%s\n' "$_xdrem_choices" | LC_ALL=C grep -Eq '^[0-9 ]*$'; then rm -f "$_xdrem_tmp"; say 'Неверный список номеров.'; return 1; fi
    _xdrem_changed=0
    for _xdrem_choice in $_xdrem_choices; do
        case "$_xdrem_choice" in ''|0) continue ;; esac
        _xdrem_row=$(awk -F'|' -v n="$_xdrem_choice" 'NR==n {print; exit}' "$_xdrem_tmp")
        [ -n "$_xdrem_row" ] || continue
        IFS='|' read -r _xdrem_type _xdrem_target _xdrem_port _xdrem_domain <<EOF
$_xdrem_row
EOF
        if [ "$_xdrem_type" = dot ]; then
            xmenu_dns_valid_host "$_xdrem_target" || continue
            _xdrem_cmd="no dns-proxy tls upstream $_xdrem_target"
            if [ -n "$_xdrem_port" ] && [ "$_xdrem_port" != 853 ]; then
                xmenu_dns_valid_port "$_xdrem_port" || continue
                _xdrem_cmd="$_xdrem_cmd $_xdrem_port"
            fi
        else
            xmenu_dns_valid_uri "$_xdrem_target" || continue
            _xdrem_cmd="no dns-proxy https upstream $_xdrem_target"
        fi
        if xmenu_dns_ndmc "$_xdrem_cmd" >/dev/null 2>&1; then _xdrem_changed=1; fi
    done
    rm -f "$_xdrem_tmp"
    [ "$_xdrem_changed" = 1 ] && xmenu_dns_save
}

xmenu_dns_manage_menu() {
    command -v ndmc >/dev/null 2>&1 || { say 'ndmc не найден: управление DNS доступно только на Keenetic/Netcraze OS.'; return 1; }
    while :; do
        xmenu_dns_show
        say ''
        say '1. Добавить DoT'
        say '2. Добавить DoH'
        say '3. Привязать домен к DNS (пресеты)'
        say '4. Удалить общие DNS-серверы'
        say '0. Назад'
        _read_or_eof 'Выбери пункт: ' || return 0
        case "$_read_value" in
            1) xmenu_dns_add_menu dot ;;
            2) xmenu_dns_add_menu doh ;;
            3) xmenu_dns_domain_presets ;;
            4) xmenu_dns_remove_menu ;;
            0|'') return 0 ;;
            *) say 'Неверный пункт.' ;;
        esac
    done
}

# IPSet sources and paths follow the official nfqws-menu choices. Files are
# staged and checked before existing lists are backed up or replaced.
XMENU_IPSET_FLOWSEAL_URL='https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/ipset-service.txt'
XMENU_IPSET_NFQWS1_URL='https://raw.githubusercontent.com/nfqws/nfqws-keenetic/master/etc/nfqws/ipset.list'
XMENU_IPSET_NFQWS2_URL='https://raw.githubusercontent.com/nfqws/nfqws2-keenetic/master/etc/nfqws2/lists/ipset.list'

xmenu_ipset_clean_file() {
    _xic_src=$1 _xic_dest=$2
    awk '!/^[[:space:]]*([#;]|$)/ { gsub(/[ \t\r]+$/, ""); if ($0 != "") print }' "$_xic_src" > "$_xic_dest" || return 1
    XMENU_IPSET_COUNT=$(wc -l < "$_xic_dest" 2>/dev/null | tr -d ' ')
    case "$XMENU_IPSET_COUNT" in ''|*[!0-9]*|0) return 1 ;; esac
}

xmenu_ipset_fetch_clean() {
    _xif_url=$1 _xif_dest=$2 _xif_raw="$_xif_dest.raw"
    say "Загружаю IP/CIDR список: $_xif_url"
    fetch "$_xif_url" "$_xif_raw" 90 || { rm -f "$_xif_raw" "$_xif_dest"; return 1; }
    if response_looks_like_error_page "$_xif_raw"; then
        rm -f "$_xif_raw" "$_xif_dest"
        say 'Вместо IP/CIDR-списка получена страница ошибки; исходный список сохранён.'
        return 1
    fi
    xmenu_ipset_clean_file "$_xif_raw" "$_xif_dest" || {
        rm -f "$_xif_raw" "$_xif_dest"
        say "${RED}Список пуст или не содержит строк с адресами.${RESET}"
        return 1
    }
    rm -f "$_xif_raw"
    say "Подготовлено записей: $XMENU_IPSET_COUNT"
}

xmenu_ipset_target() {
    case "$1" in
        1) printf '%s\n' "${XMENU_NFQWS1_IPSET:-/opt/etc/nfqws/ipset.list}" ;;
        2) printf '%s\n' "${XMENU_NFQWS2_IPSET:-/opt/etc/nfqws2/lists/ipset.list}" ;;
        *) return 1 ;;
    esac
}

xmenu_ipset_init() {
    case "$1" in
        1) printf '%s\n' "${XMENU_NFQWS1_INIT:-/opt/etc/init.d/S51nfqws}" ;;
        2) printf '%s\n' "${XMENU_NFQWS2_INIT:-/opt/etc/init.d/S51nfqws2}" ;;
        *) return 1 ;;
    esac
}

xmenu_ipset_restart_service() {
    _xirs_init=$1
    if [ -x "$_xirs_init" ]; then
        "$_xirs_init" restart
    else
        say "${YELLOW}Не найден init-скрипт NFQWS: $_xirs_init${RESET}"
        return 1
    fi
}

xmenu_ipset_apply_file() {
    _xia_ver=$1 _xia_source=$2
    _xia_target=$(xmenu_ipset_target "$_xia_ver") || return 1
    _xia_dir=${_xia_target%/*}
    [ ! -L "$_xia_target" ] || { say "${RED}Путь списка является симлинком; запись отменена: $_xia_target${RESET}"; return 1; }
    [ ! -e "$_xia_target" ] || [ -f "$_xia_target" ] || { say "${RED}Путь списка не является обычным файлом: $_xia_target${RESET}"; return 1; }
    mkdir -p "$_xia_dir" || return 1
    _xia_stage=$(mktemp "$_xia_dir/.ipset.list.xmenu.XXXXXX") || return 1
    cp "$_xia_source" "$_xia_stage" && chmod 644 "$_xia_stage" || { rm -f "$_xia_stage"; return 1; }
    backup_file "$_xia_target" || { rm -f "$_xia_stage"; return 1; }
    mv -f "$_xia_stage" "$_xia_target" || { rm -f "$_xia_stage"; return 1; }
    say "${GREEN}Список записан: $_xia_target${RESET}"
    _xia_init=$(xmenu_ipset_init "$_xia_ver") || return 1
    xmenu_ipset_restart_service "$_xia_init" || { say "${RED}Список обновлён, но сервис не перезапустился.${RESET}"; return 1; }
    return 0
}

xmenu_update_ipset_list() {
    _xui_has1=0 _xui_has2=0
    is_installed nfqws-keenetic && _xui_has1=1
    is_installed nfqws2-keenetic && _xui_has2=1
    if [ "$_xui_has1" -eq 0 ] && [ "$_xui_has2" -eq 0 ]; then
        say 'Для обновления IPSet нужен установленный nfqws-keenetic или nfqws2-keenetic.'
        return 1
    fi
    say 'IPSet — список IP/CIDR для применения стратегии.'
    say 'Flowseal — большой список Discord/YouTube, он может заметно увеличить размер набора.'
    say 'Стандартный источник берётся из репозитория выбранной версии NFQWS.'
    menu_item 1 'Загрузить большой список Flowseal (Discord/YouTube)'
    menu_item 2 'Загрузить стандартный IPSet для пакета'
    menu_item 0 'Назад'
    _read_or_eof 'Источник IPSet: ' || return 0
    _xui_source=$_read_value
    case "$_xui_source" in 1|2) ;; 0|'') return 0 ;; *) say 'Выбери 1, 2 или 0.'; return 1 ;; esac

    if [ "$_xui_has1" -eq 1 ] && [ "$_xui_has2" -eq 1 ]; then
        say 'Установлены обе версии NFQWS.'
        menu_item 1 'Обновить nfqws-keenetic (v1)'
        menu_item 2 'Обновить nfqws2-keenetic (v2)'
        menu_item a 'Обновить обе версии'
        menu_item 0 'Отмена'
        _read_or_eof 'Выбери версию: ' || return 0
        case "$_read_value" in
            1) _xui_versions='1' ;;
            2) _xui_versions='2' ;;
            a|A) _xui_versions='1 2' ;;
            *) return 0 ;;
        esac
    elif [ "$_xui_has1" -eq 1 ]; then
        _xui_versions=1
    else
        _xui_versions=2
    fi
    ensure_network || return 1

    _xui_work="${TMPDIR:-/tmp}/xmenu-ipset-$$"
    (umask 077 && mkdir "$_xui_work") || return 1
    _xui_rc=0
    for _xui_ver in $_xui_versions; do
        case "$_xui_ver:$_xui_source" in
            1:1|2:1) _xui_url=$XMENU_IPSET_FLOWSEAL_URL ;;
            1:2) _xui_url=$XMENU_IPSET_NFQWS1_URL ;;
            2:2) _xui_url=$XMENU_IPSET_NFQWS2_URL ;;
        esac
        if ! xmenu_ipset_fetch_clean "$_xui_url" "$_xui_work/nfqws$_xui_ver.list"; then
            _xui_rc=1
            break
        fi
    done
    if [ "$_xui_rc" -eq 0 ]; then
        for _xui_ver in $_xui_versions; do
            xmenu_ipset_apply_file "$_xui_ver" "$_xui_work/nfqws$_xui_ver.list" || { _xui_rc=1; break; }
        done
    fi
    rm -rf "$_xui_work"
    return "$_xui_rc"
}

xmenu_nfqws_config_path() {
    case "$1" in
        1) printf '%s\n' "${XMENU_NFQWS1_CONF:-/opt/etc/nfqws/nfqws.conf}" ;;
        2) printf '%s\n' "${XMENU_NFQWS2_CONF:-/opt/etc/nfqws2/nfqws2.conf}" ;;
        *) return 1 ;;
    esac
}

xmenu_nfqws_init_path() {
    case "$1" in
        1) printf '%s\n' "${XMENU_NFQWS1_INIT:-/opt/etc/init.d/S51nfqws}" ;;
        2) printf '%s\n' "${XMENU_NFQWS2_INIT:-/opt/etc/init.d/S51nfqws2}" ;;
        *) return 1 ;;
    esac
}

xmenu_dot_doh_fallback() {
    case "$1" in
        1) cat <<'XMENU_DOT_DOH_V1'
#DNS
--filter-tcp=443,853 --filter-l7=http,tls --hostlist-domains=dns.iij.jp,dot.sb,dns.sb,doh.sb,dns.google,dot.pub,doh.pub,controld.com,opendns.com,anycast.censurfridns.dk,dns.alidns.com,libredns.gr,cloudflare-dns.com,one.one.one.one,opennameserver.org,cleanbrowsing.org,dns.adguard-dns.com,dns.comss.one,xbox-dns.ru,dns.malw.link,geohide.ru,dns.nextdns.io,dns10.quad9.net,dns.astracat.network,dns.bezmezhau.com,dns.dns-ai.ru,dns.mafioznik.xyz,free.shecan.ir --dpi-desync=multisplit,fake --dpi-desync-split-pos=1,host+2,midsld+2,endsld-2 --dpi-desync-split-seqovl=4 --dpi-desync-fooling=md5sig --dpi-desync-fake-tls=/opt/etc/nfqws/tls_clienthello.bin --dpi-desync-fake-tls-mod=rnd,dupsid,sni=ozon.ru --dpi-desync-repeats=3
--new
--filter-tcp=443,853 --filter-l7=http,tls --ipset-ip=104.16.248.249,104.16.249.249,91.239.100.100,89.233.43.71,8.8.8.8,8.8.4.4,1.12.12.12,120.53.53.120,208.67.222.222,208.67.220.220,223.5.5.5,223.6.6.6,1.1.1.1,1.0.0.1,1.1.1.2,1.0.0.2,1.1.1.3,1.0.0.3,217.160.70.42,213.202.211.221,81.169.136.222,185.181.61.24,185.228.168.9,185.228.169.9,94.140.14.14,94.140.15.15,94.140.14.140,94.140.14.141,94.140.15.16,45.90.28.94,45.90.30.94,76.76.2.11,76.76.10.11,9.9.9.9,9.9.9.10,149.112.112.112,185.222.222.222,45.11.45.11,172.104.93.80 --dpi-desync=multisplit,fake --dpi-desync-split-pos=1,27 --dpi-desync-split-seqovl=4 --dpi-desync-fooling=md5sig --dpi-desync-fake-tls=/opt/etc/nfqws/tls_clienthello.bin --dpi-desync-fake-tls-mod=rnd,dupsid,sni=ozon.ru --dpi-desync-repeats=3
--new
--filter-udp=443,853 --filter-l7=quic --hostlist-domains=cloudflare-dns.com,dns.adguard-dns.com,dns.nextdns.io,nextdns.io,dns.google,controld.com --dpi-desync=ipfrag2 --dpi-desync-ipfrag-pos-udp=88
XMENU_DOT_DOH_V1
        ;;
        2) cat <<'XMENU_DOT_DOH_V2'
#DNS
--filter-tcp=443,853
--filter-l7=http,tls
--hostlist-domains=dns.iij.jp,dot.sb,dns.sb,doh.sb,dns.google,dot.pub,doh.pub,controld.com,opendns.com,anycast.censurfridns.dk,dns.alidns.com,libredns.gr,cloudflare-dns.com,one.one.one.one,opennameserver.org,cleanbrowsing.org,dns.adguard-dns.com,dns.comss.one,xbox-dns.ru,dns.malw.link,geohide.ru,dns.nextdns.io,dns10.quad9.net,dns.astracat.network,dns.bezmezhau.com,dns.dns-ai.ru,dns.mafioznik.xyz,free.shecan.ir
--out-range=-d10
--payload=tls_client_hello,http_req
--lua-desync=multisplit:pos=1,host+2,midsld+2,endsld-2:seqovl=4:tcp_ts_up
--lua-desync=fake:blob=tls_clienthello:tcp_md5:tcp_seq=10000:tls_mod=rnd,dupsid,sni=ozon.ru:repeats=3
--new
--filter-tcp=443,853
--filter-l7=http,tls
--ipset-ip=104.16.248.249,104.16.249.249,91.239.100.100,89.233.43.71,8.8.8.8,8.8.4.4,1.12.12.12,120.53.53.53,208.67.222.222,208.67.220.220,223.5.5.5,223.6.6.6,116.202.176.26,1.1.1.1,1.0.0.1,1.1.1.2,1.0.0.2,1.1.1.3,1.0.0.3,217.160.70.42,213.202.211.221,81.169.136.222,185.181.61.24,185.228.168.9,185.228.169.9,94.140.14.14,94.140.15.15,94.140.14.140,94.140.14.141,94.140.15.16,45.90.28.94,45.90.30.94,76.76.2.11,76.76.10.11,9.9.9.9,9.9.9.10,149.112.112.112,185.222.222.222,45.11.45.11,172.104.93.80
--out-range=-d10
--payload=tls_client_hello,http_req
--lua-desync=multisplit:pos=1,27:seqovl=4:tcp_ts_up
--lua-desync=fake:blob=tls_clienthello:tcp_md5:tcp_seq=10000:tls_mod=rnd,dupsid,sni=ozon.ru:repeats=3
--new
--filter-udp=443,853
--filter-l7=quic
--hostlist-domains=cloudflare-dns.com,dns.adguard-dns.com,dns.nextdns.io,nextdns.io,dns.google,controld.com
--payload=quic_initial
--lua-desync=send:ipfrag:ipfrag_pos_udp=88
XMENU_DOT_DOH_V2
        ;;
        *) return 1 ;;
    esac
}

xmenu_dot_doh_load_strategy() {
    _xdls_ver=$1 _xdls_dest=$2
    _xdls_raw="$_xdls_dest.raw"
    if fetch "$NF_REPO/strategies/dns_filter_nfqws$_xdls_ver" "$_xdls_raw" 45 &&
       [ -s "$_xdls_raw" ] && ! response_looks_like_error_page "$_xdls_raw"; then
        tr -d '\r' < "$_xdls_raw" | sed '/^[[:space:]]*$/d' > "$_xdls_dest"
        rm -f "$_xdls_raw"
        grep -q '^--filter-tcp=' "$_xdls_dest" || { rm -f "$_xdls_dest"; return 1; }
        say "${GREEN}Загружена стратегия dns_filter_nfqws$_xdls_ver.${RESET}"
        return 0
    fi
    rm -f "$_xdls_raw"
    say "${YELLOW}GitHub недоступен; использую встроенный fallback dns_filter_nfqws$_xdls_ver.${RESET}"
    xmenu_dot_doh_fallback "$_xdls_ver" > "$_xdls_dest"
}

xmenu_dot_doh_inject_strategy() {
    _xdis_conf=$1 _xdis_strategy=$2 _xdis_out=$3
    _xdis_found=0 _xdis_open=0 _xdis_has=0
    : > "$_xdis_out" || return 1
    while IFS= read -r _xdis_line || [ -n "$_xdis_line" ]; do
        if [ "$_xdis_open" -eq 0 ]; then
            case "$_xdis_line" in
                NFQWS_ARGS_CUSTOM=\"\")
                    _xdis_found=1
                    printf 'NFQWS_ARGS_CUSTOM="\n' >> "$_xdis_out"
                    cat "$_xdis_strategy" >> "$_xdis_out"
                    printf '"\n' >> "$_xdis_out"
                    ;;
                NFQWS_ARGS_CUSTOM=\")
                    _xdis_found=1 _xdis_open=1
                    printf '%s\n' "$_xdis_line" >> "$_xdis_out"
                    ;;
                NFQWS_ARGS_CUSTOM=\"*\")
                    _xdis_found=1
                    _xdis_body=${_xdis_line#NFQWS_ARGS_CUSTOM=\"}; _xdis_body=${_xdis_body%\"}
                    printf 'NFQWS_ARGS_CUSTOM="\n' >> "$_xdis_out"
                    if [ -n "$(printf '%s' "$_xdis_body" | tr -d '[:space:]')" ]; then
                        printf '%s\n--new\n' "$_xdis_body" >> "$_xdis_out"
                    fi
                    cat "$_xdis_strategy" >> "$_xdis_out"
                    printf '"\n' >> "$_xdis_out"
                    ;;
                NFQWS_ARGS_CUSTOM=\"*)
                    _xdis_found=1 _xdis_open=1 _xdis_has=1
                    printf '%s\n' "$_xdis_line" >> "$_xdis_out"
                    ;;
                *) printf '%s\n' "$_xdis_line" >> "$_xdis_out" ;;
            esac
        else
            case "$_xdis_line" in
                \"|[[:space:]]*\")
                    [ "$_xdis_has" -eq 1 ] && printf '%s\n' '--new' >> "$_xdis_out"
                    cat "$_xdis_strategy" >> "$_xdis_out"
                    printf '%s\n' "$_xdis_line" >> "$_xdis_out"
                    _xdis_open=0
                    ;;
                *\")
                    _xdis_body=${_xdis_line%\"}
                    if [ -n "$(printf '%s' "$_xdis_body" | tr -d '[:space:]\\')" ]; then
                        printf '%s\n' "$_xdis_body" >> "$_xdis_out"
                        _xdis_has=1
                    fi
                    [ "$_xdis_has" -eq 1 ] && printf '%s\n' '--new' >> "$_xdis_out"
                    cat "$_xdis_strategy" >> "$_xdis_out"
                    printf '"\n' >> "$_xdis_out"
                    _xdis_open=0
                    ;;
                *)
                    [ -z "$(printf '%s' "$_xdis_line" | tr -d '[:space:]\\')" ] || _xdis_has=1
                    printf '%s\n' "$_xdis_line" >> "$_xdis_out"
                    ;;
            esac
        fi
    done < "$_xdis_conf"
    [ "$_xdis_open" -eq 0 ] || { say "${RED}Кавычка NFQWS_ARGS_CUSTOM не закрыта; конфиг не изменён.${RESET}"; return 1; }
    if [ "$_xdis_found" -eq 0 ]; then
        printf '\nNFQWS_ARGS_CUSTOM="\n' >> "$_xdis_out"
        cat "$_xdis_strategy" >> "$_xdis_out"
        printf '"\n' >> "$_xdis_out"
    fi
    sh -n "$_xdis_out"
}

xmenu_dot_doh_ensure_port() {
    _xdep_file=$1 _xdep_var=$2 _xdep_port=$3
    _xdep_line=$(grep -m 1 -E "^[[:space:]]*${_xdep_var}=" "$_xdep_file" 2>/dev/null || :)
    if [ -z "$_xdep_line" ]; then printf '%s=%s\n' "$_xdep_var" "$_xdep_port" >> "$_xdep_file"; return $?; fi
    _xdep_value=${_xdep_line#*=}
    _xdep_value=$(printf '%s' "$_xdep_value" | tr -d '\"\047[:space:]')
    case ",$_xdep_value," in *,"$_xdep_port",*) return 0 ;; esac
    _xdep_tmp="$_xdep_file.port.$$"
    awk -v var="$_xdep_var" -v port="$_xdep_port" '
        BEGIN { done=0 }
        $0 ~ "^[[:space:]]*" var "=" && !done {
            value=$0; sub(/^[^=]*=/, "", value); gsub(/[\"\047[:space:]]/, "", value)
            if (value=="") value=port; else value=value "," port
            print var "=" value; done=1; next
        }
        { print }
        END { if (!done) exit 1 }
    ' "$_xdep_file" > "$_xdep_tmp" && mv -f "$_xdep_tmp" "$_xdep_file" || { rm -f "$_xdep_tmp"; return 1; }
}

xmenu_dot_doh_apply_version() {
    _xdav_ver=$1
    _xdav_conf=$(xmenu_nfqws_config_path "$_xdav_ver") || return 1
    _xdav_init=$(xmenu_nfqws_init_path "$_xdav_ver") || return 1
    [ -f "$_xdav_conf" ] || { say "${RED}Конфиг не найден: $_xdav_conf${RESET}"; return 1; }
    [ ! -L "$_xdav_conf" ] || { say "${RED}Конфиг является симлинком; изменение отменено.${RESET}"; return 1; }
    if grep -qE '#DNS|dot\.pub,doh\.pub|dns\.iij\.jp|xbox-dns\.ru' "$_xdav_conf" 2>/dev/null; then
        say "${YELLOW}В конфиге уже найдены признаки DNS-фильтра (nfqws$_xdav_ver). Добавить ещё раз?${RESET}"
        confirm_no 'Повторно добавить стратегию?' || { say "Пропущено для nfqws$_xdav_ver."; return 0; }
    fi
    ensure_network || return 1
    mkdir -p "$ROOT_DIR" || return 1
    _xdav_work="$ROOT_DIR/dns-filter-$$"
    mkdir "$_xdav_work" || return 1
    _xdav_strategy="$_xdav_work/strategy.conf" _xdav_candidate="$_xdav_work/candidate.conf"
    if ! xmenu_dot_doh_load_strategy "$_xdav_ver" "$_xdav_strategy" ||
       ! xmenu_dot_doh_inject_strategy "$_xdav_conf" "$_xdav_strategy" "$_xdav_candidate" ||
       ! xmenu_dot_doh_ensure_port "$_xdav_candidate" TCP_PORTS 853 ||
       ! xmenu_dot_doh_ensure_port "$_xdav_candidate" UDP_PORTS 853 || ! sh -n "$_xdav_candidate"; then
        rm -rf "$_xdav_work"
        say "${RED}Не удалось подготовить корректное изменение; исходный конфиг сохранён.${RESET}"
        return 1
    fi
    backup_file "$_xdav_conf" || { rm -rf "$_xdav_work"; return 1; }
    replace_shell_config "$_xdav_candidate" "$_xdav_conf" || { rm -rf "$_xdav_work"; say 'Не удалось атомарно обновить конфиг.'; return 1; }
    rm -rf "$_xdav_work"
    say "${GREEN}Добавлена стратегия обхода DoT/DoH для nfqws$_xdav_ver; порты TCP/UDP 853 проверены.${RESET}"
    if [ -x "$_xdav_init" ]; then
        "$_xdav_init" restart || { say "${RED}Конфиг обновлён, но перезапуск $_xdav_init завершился ошибкой.${RESET}"; return 1; }
    else
        say "${YELLOW}Конфиг обновлён, но init-скрипт не найден: $_xdav_init${RESET}"
        return 1
    fi
}

xmenu_dot_doh_bypass_menu() {
    _xddm_has1=0 _xddm_has2=0
    is_installed nfqws-keenetic && _xddm_has1=1
    is_installed nfqws2-keenetic && _xddm_has2=1
    if [ "$_xddm_has1" -eq 0 ] && [ "$_xddm_has2" -eq 0 ]; then
        say 'Обход DoT/DoH доступен при установленном nfqws-keenetic или nfqws2-keenetic.'
        return 1
    fi
    if [ "$_xddm_has1" -eq 1 ] && [ "$_xddm_has2" -eq 1 ]; then
        say 'Установлены обе версии NFQWS.'
        menu_item 1 'nfqws-keenetic (v1) — классический dpi-desync'
        menu_item 2 'nfqws2-keenetic (v2) — lua-desync'
        menu_item a 'Обе версии'
        menu_item 0 'Отмена'
        _read_or_eof 'Выбери версию: ' || return 0
        case "$_read_value" in
            1) _xddm_versions=1 ;;
            2) _xddm_versions=2 ;;
            a|A|а|А) _xddm_versions='1 2' ;;
            *) return 0 ;;
        esac
    elif [ "$_xddm_has1" -eq 1 ]; then _xddm_versions=1
    else _xddm_versions=2
    fi
    _xddm_label='nfqws'
    [ "$_xddm_versions" = 2 ] && _xddm_label='nfqws2'
    [ "$_xddm_versions" = '1 2' ] && _xddm_label='обе версии'
    confirm_yes "Добавить стратегию обхода блокировок DoT/DoH в NFQWS_ARGS_CUSTOM ($_xddm_label)?" || {
        say 'Отменено: конфиг не менялся, стратегия не загружалась.'
        return 0
    }
    _xddm_rc=0
    for _xddm_ver in $_xddm_versions; do xmenu_dot_doh_apply_version "$_xddm_ver" || _xddm_rc=1; done
    return "$_xddm_rc"
}

xmenu_parse_fake_blobs() {
    : > "$2" && : > "$3" || return 1
    awk -v mapfile="$2" -v entries="$3" '
        /^[[:space:]]*#/ {next}
        {
            if (match($0, /^NFQWS_[A-Z_]*ARGS[A-Z_]*=/)) section=substr($0,1,RLENGTH-1)
            rest=$0
            while (match(rest, /--blob=[A-Za-z0-9_.-]+:[^[:space:]"\047]+/)) {
                token=substr(rest,RSTART+7,RLENGTH-7)
                separator=index(token,":")
                alias=substr(token,1,separator-1)
                path=substr(token,separator+1)
                sub(/^@/,"",path)
                sub(/^.*\//,"",path)
                mapped[alias]=path
                rest=substr(rest,RSTART+RLENGTH)
            }
            rest=$0
            while (match(rest, /fake:blob=[^:[:space:]"\047]+/)) {
                alias=substr(rest,RSTART+10,RLENGTH-10)
                if (alias !~ /^0[xX]/ && !referenced[alias]++) {
                    ordered[++count]=alias
                    sections[alias]=(section=="" ? "NFQWS" : section)
                }
                rest=substr(rest,RSTART+RLENGTH)
            }
        }
        END {
            for (alias in mapped) print alias "|" mapped[alias] > mapfile
            for (i=1;i<=count;i++) {
                alias=ordered[i]
                filename=(alias in mapped ? mapped[alias] : "встроенный blob")
                print i "|" sections[alias] "|" alias "|" filename > entries
            }
            exit(count ? 0 : 1)
        }
    ' "$1"
}

xmenu_choose_nfqws() {
    _xcn_one=$(xmenu_nfqws_config_path 1)
    _xcn_two=$(xmenu_nfqws_config_path 2)
    if [ -f "$_xcn_one" ] && [ -f "$_xcn_two" ]; then
        menu_item 1 'nfqws (v1)'
        menu_item 2 'nfqws2 (v2)'
        menu_item 0 'Назад'
        _read_or_eof 'Выбери версию: ' || return 1
        case "$_read_value" in 1|2) XMENU_SELECTED_NFQWS_VERSION=$_read_value ;; *) return 1 ;; esac
    elif [ -f "$_xcn_two" ]; then XMENU_SELECTED_NFQWS_VERSION=2
    elif [ -f "$_xcn_one" ]; then XMENU_SELECTED_NFQWS_VERSION=1
    else say 'Конфигурация NFQWS не найдена.'; return 1
    fi
}

xmenu_fake_blob_rewrite() {
    awk -v name="$2" -v path="$3" '
        {
            line=$0; result=""; needle="--blob=" name ":"
            while ((pos=index(line,needle)) > 0) {
                result=result substr(line,1,pos-1) needle "@" path
                line=substr(line,pos+length(needle))
                sub(/^[^[:space:]"\047]*/, "", line)
                found=1
            }
            print result line
        }
        END {
            if (!found) print "NFQWS_BASE_ARGS=\"${NFQWS_BASE_ARGS:-} --blob=" name ":@" path "\""
        }
    ' "$1" > "$4"
}

xmenu_fake_blob_menu() (
    xmenu_choose_nfqws || return 0
    ver=$XMENU_SELECTED_NFQWS_VERSION
    conf=$(xmenu_nfqws_config_path "$ver")
    init=$(xmenu_nfqws_init_path "$ver")
    case "$ver" in 1) blobs=${XMENU_NFQWS1_BLOBS:-/opt/etc/nfqws} ;; 2) blobs=${XMENU_NFQWS2_BLOBS:-/opt/etc/nfqws2/blobs} ;; esac
    work=$(mktemp -d /tmp/xmenu-fakeblob-XXXXXX) || return 1
    trap 'rm -rf "$work"' 0
    trap 'exit 130' INT TERM HUP
    xmenu_parse_fake_blobs "$conf" "$work/map" "$work/list" || {
        say 'В конфиге нет именованных fake:blob. Hex-значения не изменяются.'; return 0;
    }
    while IFS='|' read -r idx section name base; do
        say "$idx. $section: $name ($base)"
    done < "$work/list"
    _read_or_eof 'Номер fake:blob (0 — назад): ' || return 0
    case "$_read_value" in ''|0) return 0 ;; *[!0-9]*) say 'Нужен номер из списка.'; return 1 ;; esac
    selected=$(awk -F'|' -v n="$_read_value" '$1==n {print $3; exit}' "$work/list")
    case "$selected" in ''|*[!A-Za-z0-9_.-]*) say 'Недопустимое имя blob.'; return 1 ;; esac
    : > "$work/local"
    for file in "$blobs"/*.bin; do [ ! -f "$file" ] || basename "$file" >> "$work/local"; done
    : > "$work/repo"
    if fetch "$NF_REPO/strategies/blobs/SHA256SUMS" "$work/sums" 30; then
        awk 'length($1)==64 && $1 !~ /[^0-9a-fA-F]/ {n=$2; sub(/^\*/,"",n); sub(/.*\//,"",n); if (n ~ /^[A-Za-z0-9_.-]+\.bin$/) print n}' "$work/sums" > "$work/repo"
    fi
    if [ ! -s "$work/repo" ] && fetch 'https://api.github.com/repos/rndnaame/nfqws-menu/contents/strategies/blobs' "$work/api" 30; then
        grep -oE '"name":[[:space:]]*"[A-Za-z0-9_.-]+\.bin"' "$work/api" | sed 's/.*"\([^"]*\)"$/\1/' > "$work/repo"
    fi
    if [ ! -s "$work/repo" ]; then
        printf '%s\n' ACTIVE_DISCORD_UDP.bin ACTIVE_GAME_UDP.bin quic_initial_www_google_com.bin stun.bin stun2.bin tls_clienthello_www_google_com.bin > "$work/repo"
    fi
    cat "$work/local" "$work/repo" | awk '!seen[$0]++' > "$work/candidates"
    idx=0
    while IFS= read -r file; do
        idx=$((idx+1)); label='из репозитория'
        [ ! -f "$blobs/$file" ] || label='локально'
        say "$idx. $file ($label)"
    done < "$work/candidates"
    _read_or_eof 'Номер нового файла (0 — назад): ' || return 0
    case "$_read_value" in ''|0) return 0 ;; *[!0-9]*) return 1 ;; esac
    file=$(awk -v n="$_read_value" 'NR==n {print; exit}' "$work/candidates")
    case "$file" in ''|*[!A-Za-z0-9_.-]*) say 'Неверный файл.'; return 1 ;; esac
    target="$blobs/$file"
    if [ ! -f "$target" ]; then
        fetch "$NF_REPO/strategies/blobs/$file" "$work/download" 60 && [ -s "$work/download" ] &&
            ! response_looks_like_error_page "$work/download" || return 1
        expected=$(awk -v n="$file" '{f=$2; sub(/^\*/,"",f); sub(/.*\//,"",f); if(f==n && length($1)==64) {print $1; exit}}' "$work/sums" 2>/dev/null)
        if [ -n "$expected" ] && ! sha_ok "$work/download" "$expected"; then say 'Контрольная сумма blob не совпала.'; return 1; fi
        mkdir -p "$blobs" || return 1
        cp "$work/download" "$target.xmenu.$$" && mv "$target.xmenu.$$" "$target" || return 1
    fi
    acquire_lock || return 1
    trap 'release_operation_lock; rm -rf "$work"' 0
    xmenu_fake_blob_rewrite "$conf" "$selected" "$target" "$work/candidate" &&
        sh -n "$work/candidate" && backup_file "$conf" && replace_shell_config "$work/candidate" "$conf" || return 1
    release_operation_lock
    say "Настроено: --blob=$selected:@$target"
    if confirm_yes "Перезапустить nfqws$ver?"; then
        [ -x "$init" ] && "$init" restart || { say "Не удалось перезапустить $init."; return 1; }
    fi
)

xmenu_hosts_parse() {
    awk -v choices="$2" '
        function valid_ip(ip, a,n,i) {
            n=split(ip,a,"."); if(n!=4) return 0
            for(i=1;i<=n;i++) if(a[i]!~/^[0-9]+$/ || a[i]+0>255) return 0
            return 1
        }
        function valid_domain(d, a,n,i) {
            if(length(d)>253 || d !~ /\./ || d ~ /\.\./) return 0
            n=split(d,a,".")
            for(i=1;i<=n;i++) if(length(a[i])<1 || length(a[i])>63 || a[i] !~ /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$/) return 0
            return 1
        }
        BEGIN { n=split(choices,c,/[,; ]+/); for(i=1;i<=n;i++) selected[c[i]]=1 }
        /^[[:space:]]*#/ {section++; next}
        NF>=2 && (choices=="all" || selected[section]) && valid_ip($1) && valid_domain($2) {values[tolower($2)]=$1}
        END {for(d in values) print values[d] "\t" d}
    ' "$1"
}

xmenu_hosts_menu() (
    command -v ndmc >/dev/null 2>&1 || { say 'Нужен ndmc Keenetic/Netcraze.'; return 1; }
    work=$(mktemp -d /tmp/xmenu-hosts-XXXXXX) || return 1
    trap 'rm -rf "$work"' 0
    trap 'exit 130' INT TERM HUP
    fetch "$NF_REPO/hosts" "$work/hosts" 45 && [ -s "$work/hosts" ] &&
        ! response_looks_like_error_page "$work/hosts" || { say 'Не удалось загрузить hosts.'; return 1; }
    awk '/^[[:space:]]*#/ {name=$0; sub(/^[[:space:]]*#+[[:space:]]*/,"",name); sub(/[[:space:]]+$/,"",name); print ++i ". " name}' "$work/hosts"
    say 'a. Все секции'
    say '88. Удалить домены из этого hosts-файла'
    say '99. Показать текущие записи'
    say '0. Назад'
    _read_or_eof 'Выбери секции через запятую: ' || return 0
    choice=$_read_value
    case "$choice" in
        ''|0) return 0 ;;
        99) xmenu_dns_ndmc 'show running-config' | awk '$1=="ip" && $2=="host" {print $3 " → " $4}'; return 0 ;;
        88) action=remove; choice=all ;;
        a|A|all|ALL|все|Все) action=add; choice=all ;;
        *[!0-9,\;\ ]*) say 'Неверный выбор.'; return 1 ;;
        *) action=add ;;
    esac
    xmenu_hosts_parse "$work/hosts" "$choice" > "$work/pairs"
    count=$(wc -l < "$work/pairs" | tr -d ' ')
    [ "$count" -gt 0 ] || { say 'В выбранных секциях нет корректных записей IPv4.'; return 0; }
    if [ "$action" = remove ]; then
        confirm_no "Удалить домены из hosts-файла ($count)?" || return 0
    else
        say "Будет добавлено уникальных доменов: $count"
        [ "$count" -le 64 ] || say 'Превышен лимит 64 записей Keenetic; часть доменов может не добавиться.'
        confirm_yes 'Применить выбранные записи hosts?' || return 0
    fi
    acquire_lock || return 1
    trap 'release_operation_lock; rm -rf "$work"' 0
    mkdir -p "$BACKUP_DIR" || return 1
    if ! xmenu_dns_ndmc 'show running-config' > "$work/running"; then say 'Не удалось сохранить текущие записи.'; return 1; fi
    awk '$1=="ip" && $2=="host"' "$work/running" > "$work/previous"
    (umask 077; cp "$work/previous" "$BACKUP_DIR/hosts-ip-host.$(date +%Y%m%d-%H%M%S).$$.bak") || return 1
    changed=0; failed=0
    while IFS="$(printf '\t')" read -r ip domain; do
        if [ "$action" = remove ]; then cmd="no ip host $domain"; else cmd="ip host $domain $ip"; fi
        if xmenu_dns_ndmc "$cmd" >/dev/null 2>&1; then changed=$((changed+1)); else failed=$((failed+1)); say "Ошибка: $domain"; fi
    done < "$work/pairs"
    if [ "$changed" -gt 0 ]; then xmenu_dns_save || return 1; fi
    say "Обработано записей: $changed; ошибок: $failed."
    [ "$failed" -eq 0 ]
)

remove_tg_ws_proxy_rust() {
    if [ -x /opt/etc/init.d/S99tg-ws-proxy-rs ]; then /opt/etc/init.d/S99tg-ws-proxy-rs stop || return 1; fi
    rm -f /opt/etc/init.d/S99tg-ws-proxy-rs /opt/bin/tg-ws-proxy-rs || return 1
    say 'TG WS Proxy Rust удалён; настройки и секрет сохранены в /opt/etc/tg-ws-proxy-rs.'
}


xmenu_nf_manage_menu() {
    _xnfm_lang=$(get_ui_lang)
    while :; do
        if [ "$_xnfm_lang" = en ]; then
            say "${BRIGHT_CYAN}[::]  nfqws2 management:${RESET}"
            menu_item 1 'Select and apply nfqws strategy'
            menu_item 2 'Install all nfqws2 blobs'
            menu_item 3 'Download/check blobs and lists for active strategy'
            menu_item 4 'Download rkn.list (nfqws / nfqws2)'
            menu_item 5 'DoT/DoH blocking bypass'
            menu_item 6 'Current DNS server settings'
            menu_item 7 'Update Ipset Lists'
            menu_item 8 'Change current fake:blob'
            menu_item 9 'Discord: enable/disable fix'
            menu_item 10 'Update Keenetic hosts'
            menu_item 0 'Back'
            _xnfm_prompt='[?] Select an option: '
        else
            say "${BRIGHT_CYAN}[::]  Управление nfqws2:${RESET}"
            menu_item 1 'Выбрать и применить стратегию nfqws'
            menu_item 2 'Установить все blobs nfqws2'
            menu_item 3 'Скачать/проверить blobs и lists активной стратегии'
            menu_item 4 'Скачать rkn.list (nfqws / nfqws2)'
            menu_item 5 'Обход блокировки DoT/DoH'
            menu_item 6 'Настройки текущих DNS-серверов'
            menu_item 7 'Обновить Ipset Lists'
            menu_item 8 'Смена текущих fake:blob'
            menu_item 9 'Discord: включить/выключить фикс'
            menu_item 10 'Обновление hosts'
            menu_item 0 'Назад'
            _xnfm_prompt='[?] Выбери пункт: '
        fi
        _read_or_eof "$_xnfm_prompt" || return 0
        case "$_read_value" in
            1) ensure_network && strategy_menu ;;
            2) ensure_network && install_all_nfqw2_blobs ;;
            3) sync_active_blobs ;;
            4) install_rkn_list ;;
            5) xmenu_dot_doh_bypass_menu ;;
            6) xmenu_dns_manage_menu ;;
            7) xmenu_update_ipset_list ;;
            8) xmenu_fake_blob_menu ;;
            9) xmenu_discord_menu ;;
            10) xmenu_hosts_menu ;;
            0|'') return 0 ;;
            *) say "${RED}Неверный пункт.${RESET}" ;;
        esac
    done
}

xmenu_other_utilities_menu() {
    _xoum_lang=$(get_ui_lang)
    while :; do
        if [ "$_xoum_lang" = en ]; then
            say "${BRIGHT_CYAN}[::]  Other utilities:${RESET}"
            menu_item 1 'usque-keenetic'
            menu_item 2 'MagiTrickle'
            menu_item 3 'firc'
            menu_item 4 'warpscout'
            menu_item 5 'Zapret-Manager (OpenWrt only)'
            menu_item 0 'Back'
            _xoum_prompt='[?] Select an option: '
        else
            say "${BRIGHT_CYAN}[::]  Прочие утилиты:${RESET}"
            menu_item 1 'usque-keenetic'
            menu_item 2 'MagiTrickle'
            menu_item 3 'firc'
            menu_item 4 'warpscout'
            menu_item 5 'Zapret-Manager — только для OpenWrt'
            menu_item 0 'Назад'
            _xoum_prompt='[?] Выбери пункт: '
        fi
        _read_or_eof "$_xoum_prompt" || return 0
        case "$_read_value" in
            1) install_usque_keenetic; invalidate_component_status_cache ;;
            2)
                if ! is_installed magitrickle; then
                    if [ "$_xoum_lang" = en ]; then
                        say 'Security note: the upstream MagiTrickle bootstrap currently uses HTTP to add its package feed.'
                        confirm_yes 'Continue with the upstream installer? The feed bootstrap is not encrypted.' || continue
                    else
                        say 'Безопасность: установщик MagiTrickle добавляет пакетный репозиторий по HTTP.'
                        confirm_yes 'Продолжить запуск установщика? Подключение репозитория не шифруется.' || continue
                    fi
                fi
                install_magitrickle
                invalidate_component_status_cache
                ;;
            3) install_firc; invalidate_component_status_cache ;;
            4) install_warpscout ;;
            5)
                say 'Zapret-Manager рассчитан на OpenWrt (firewall4/nftables) и не устанавливается на штатную KeeneticOS.'
                say 'Официальная инструкция: https://github.com/StressOzz/Zapret-Manager'
                ;;
            0|'') return 0 ;;
            *) say "${RED}Неверный пункт.${RESET}" ;;
        esac
    done
}

# The main menu is the single entry point; service tools are opened with S.

render_menu() {
    _XMENU_RENDER_WIDTH=$(terminal_width)
    _XMENU_FRAME_FILE="$ROOT_DIR/.menu-frame.$$"
    if ! render_menu_content > "$_XMENU_FRAME_FILE"; then rm -f "$_XMENU_FRAME_FILE"; return 1; fi
    _XMENU_FRAME_LINES=$(wc -l < "$_XMENU_FRAME_FILE" | tr -d ' ')
    XMENU_UPDATE_SLOT_UP=$((_XMENU_FRAME_LINES + 1 - _XMENU_NOTICE_LINE))
    XMENU_UPDATE_FRAME_COLUMNS=''
    if has_controlling_tty; then
        XMENU_UPDATE_FRAME_COLUMNS=$(stty size </dev/tty 2>/dev/null | awk '{print $2}' || :)
    fi
    [ -t 1 ] && printf '\033[2J\033[H'
    # Печатаем готовые строки подряд без пауз: меню быстро появляется
    # без ожидания таймеров между пунктами.
    while IFS= read -r _XMENU_FRAME_LINE || [ -n "$_XMENU_FRAME_LINE" ]; do
        printf '%s\n' "$_XMENU_FRAME_LINE"
    done < "$_XMENU_FRAME_FILE"
    _XMENU_FRAME_RC=$?
    rm -f "$_XMENU_FRAME_FILE"
    _XMENU_RENDER_WIDTH=''
    return "$_XMENU_FRAME_RC"
}

render_menu_content() {
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
    printf '%12s%s%s%s\n' '' "$BRIGHT_CYAN" "$_title" "$RESET"
    line

    # Prefer Entware architecture over the kernel architecture.
    _cpu=$_arch
    if [ -z "$_cpu" ]; then
        if [ "$_lang" = en ]; then _cpu='not detected'; else _cpu='не определена'; fi
    fi

    if [ "$_lang" = en ]; then
            printf '%s%sModel: %s %s%s %s%s(%s)%s\n' "$RESET" "$WHITE" "$_model" "$BRIGHT_CYAN" "${_fw:-not detected}" "$RESET" "$GREEN" "$_cpu" "$RESET"
    else
            printf '%s%sМодель: %s %s%s %s%s(%s)%s\n' "$RESET" "$WHITE" "$_model" "$BRIGHT_CYAN" "${_fw:-не определена}" "$RESET" "$GREEN" "$_cpu" "$RESET"
    fi
    render_component_statuses
    line

    _XMENU_NOTICE_LINE=$(( $(wc -l < "$_XMENU_FRAME_FILE") + 1 ))
    xmenu_show_pending_update_notice
    [ "${XMENU_UPDATE_NOTICE_VISIBLE:-0}" = 1 ] || say ''

    if [ "$_lang" = en ]; then
        say "${PURPLE}[::]  Install / update:${RESET}"
        menu_item 1  'XKeen — Stable'
        menu_item 2  'XKeen UI — zxc-rv'
        menu_item 3  'XKeen UI — umarcheh001'
        menu_item 4  'nfqws2'
        menu_item 5  'nfqws v1 — step-by-step install / update'
        menu_item 6  'nfqws-web-keenetic'
        menu_item 7  'nfqws2-ui'
        say ""
        say "${PURPLE}[::]  Manual installation profiles:${RESET}"
        menu_item 8  'XKeen Auto (Mihomo + GeoIPSet + XKeen at startup)'
        menu_item 9  'XKeen Auto (Xray + GeoIPSet + XKeen at startup)'
        menu_item 10  'Mihomo + GeoIPSet + XKeen Auto + XKeen UI + nfqws2 + nfqws-web-keenetic'
        menu_item 11 'Xray + GeoIPSet + XKeen Auto + XKeen UI + nfqws2 + nfqws-web-keenetic'
        say ""
        say "${PURPLE}[::]  nfqws2 management:${RESET}"
        menu_item 12 'nfqws2 management'
        say ""
        say "${PURPLE}[::]  Utilities / diagnostics:${RESET}"
        menu_item 13 'Diagnostics'
        menu_item 14 'TG WS Proxy Rust'
        menu_item 15 'KeenKit'
        menu_item 16 'awg-manager'
        menu_item 17 'Other utilities'
        say ""
        say "${PURPLE}[::]  Maintenance / settings:${RESET}"
        menu_item 18 'Сменить язык: RU / EN (change language)'
        menu_item 19 'Remove components'
        menu_item 20 'Remove Xmenu'
        menu_item 21 'Update Xmenu'
        menu_item 22 'OPKG settings / Entware mirrors'
        menu_item 0  'Exit'
    else
        say "${PURPLE}[::]  Установка / обновление:${RESET}"
        menu_item 1  'XKeen — Stable'
        menu_item 2  'XKeen UI — zxc-rv'
        menu_item 3  'XKeen UI — umarcheh001'
        menu_item 4  'nfqws2'
        menu_item 5  'nfqws v1 — поэтапная установка / обновление'
        menu_item 6  'nfqws-web-keenetic'
        menu_item 7  'nfqws2-ui'
        say ""
        say "${PURPLE}[::]  Ручные настройки установки:${RESET}"
        menu_item 8  'XKeen Auto (Mihomo + GeoIPSet + XKeen в автозагрузке)'
        menu_item 9  'XKeen Auto (Xray + GeoIPSet + XKeen в автозагрузке)'
        menu_item 10  'Mihomo + GeoIPSet + XKeen Auto + XKeen UI + nfqws2 + nfqws-web-keenetic'
        menu_item 11 'Xray + GeoIPSet + XKeen Auto + XKeen UI + nfqws2 + nfqws-web-keenetic'
        say ""
        say "${PURPLE}[::]  Управление nfqws2:${RESET}"
        menu_item 12 'Управление nfqws2'
        say ""
        say "${PURPLE}[::]  Утилиты и диагностика:${RESET}"
        menu_item 13 'Диагностика'
        menu_item 14 'TG WS Proxy Rust'
        menu_item 15 'KeenKit'
        menu_item 16 'awg-manager'
        menu_item 17 'Прочие утилиты'
        say ""
        say "${PURPLE}[::]  Обслуживание и настройки:${RESET}"
        menu_item 18 'Сменить язык: RU / EN (change language)'
        menu_item 19 'Удаление компонентов'
        menu_item 20 'Удалить Xmenu'
        menu_item 21 'Обновить Xmenu'
        menu_item 22 'Настройки OPKG / зеркала Entware'
        menu_item 0  'Выход'
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
                    if [ -x /opt/etc/init.d/S99tg-ws-proxy-rs ] || [ -x /opt/bin/tg-ws-proxy-rs ]; then remove_tg_ws_proxy_rust
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
    case "${1:-menu}" in
        site-check|diagnose-site)
            shift
            if [ "${1:-}" = --direct ]; then XMENU_SITE_DIRECT=1; shift; fi
            xmenu_site_batch "$@"; return $? ;;
        dns-check) shift; xmenu_dns_diagnose "$@"; return $? ;;
        server-check) shift; xmenu_server_diagnose "$@"; return $? ;;
        discord-fix-rules) xmenu_discord_rules_apply; return $? ;;
        discord-fix-unrules) xmenu_discord_rules_remove; return $? ;;
        discord-fix-status) xmenu_discord_status; return $? ;;
    esac
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
        install-nfqws|install-nfqws2|install-nf-web|install-nf-web2|install-dpi-detector)
            [ "$1" = install-nf-web2 ] || ensure_network || return 1
            case "$1" in
                install-nfqws) install_nfqws1 ;;
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
        render_menu || { say "${RED}Не удалось вывести меню; проверь свободное место в $ROOT_DIR.${RESET}"; return 1; }
        INTERRUPTED=0
        MENU_READING=1
        _menu_lang=$(get_ui_lang)
        if [ "$_menu_lang" = en ]; then _prompt='[?] Select an option [S = service, U = check updates, Enter = exit]: '; else _prompt='[?] Выберите пункт [S = сервис, U = проверить обновление, Enter = выход]: '; fi
        if [ "$(terminal_width)" -lt 70 ]; then
            if [ "$_menu_lang" = en ]; then _prompt='[?] Option [S, U, Enter=exit]: '
            else _prompt='[?] Пункт [S, U, Enter=выход]: '; fi
        fi
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
            1|2|3|4|5|6|7|8|9|10|11|13|14|15|16|17|19|21) invalidate_component_status_cache ;;
        esac
        case "$_choice" in
            s|S)
                xmenu_service_menu
                continue
                ;;
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
            5) install_nfqws1; pause ;;
            6) ensure_network && install_nf_web; pause ;;
            7) install_nf_web2; pause ;;
            8) install_xkeen_core_profile mihomo; invalidate_core_version_cache; pause ;;
            9) install_xkeen_core_profile xray; invalidate_core_version_cache; pause ;;
            10) install_manual_bundle_profile mihomo; invalidate_core_version_cache; pause ;;
            11) install_manual_bundle_profile xray; invalidate_core_version_cache; pause ;;
            12) xmenu_nf_manage_menu ;;
            13) xmenu_diagnostics_menu ;;
            14) install_tg_ws_proxy_rust; pause ;;
            15) install_keenkit; pause ;;
            16) install_awg_manager; pause ;;
            17) xmenu_other_utilities_menu ;;
            18) change_ui_language; pause ;;
            19) remove_components_menu; invalidate_core_version_cache ;;
            20) remove_menu; _remove_rc=$?; [ "${XMENU_REMOVED:-0}" = 1 ] && { cleanup; return 0; } ;;
            21) update_xmenu_script || pause ;;
            22) opkg_settings_menu ;;
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
