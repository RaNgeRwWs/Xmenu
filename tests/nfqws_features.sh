#!/bin/sh
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sed '/^main "\$@"$/d' "$repo/xmenu-v1.0.sh" > "$tmp/library.sh"
. "$tmp/library.sh"
ROOT_DIR="$tmp/data"
get_ui_lang() { printf ru; }
get_router() { printf 'Hopper (KN-3811)|KeeneticOS 5.2'; }
get_arch() { printf aarch64; }
render_component_statuses() { printf 'components\n'; }
xmenu_show_pending_update_notice() { :; }
_XMENU_DEVICE_CACHE_READY=0
_XMENU_FRAME_FILE="$tmp/frame"
: > "$tmp/frame"
render_menu_content > "$tmp/main-menu"
grep -q 'Модель: Hopper (KN-3811) KeeneticOS 5.2 (aarch64)' "$tmp/main-menu" || { echo 'FAIL: architecture is not displayed in parentheses' >&2; exit 1; }
grep -q '12\.  Управление nfqws2' "$tmp/main-menu" || { echo 'FAIL: nfqws2 management is not item 13' >&2; exit 1; }
grep -q '13\.  Диагностика' "$tmp/main-menu" || { echo 'FAIL: diagnostics is not item 13' >&2; exit 1; }
grep -q '17\.  Прочие утилиты' "$tmp/main-menu" || { echo 'FAIL: other utilities is not the last item in utilities and diagnostics' >&2; exit 1; }
if grep -Eq '^[[:space:]]+(1[6-9])\.  (Выбрать и применить стратегию nfqws|Скачать/проверить blobs|Установить все blobs|Скачать rkn.list)' "$tmp/main-menu"; then echo 'FAIL: NFQWS strategy/blob actions remain in the main menu' >&2; exit 1; fi
grep -Fq '17) xmenu_other_utilities_menu ;;' "$tmp/library.sh" || { echo 'FAIL: main-menu item 17 does not open other utilities' >&2; exit 1; }
grep -Fq '18) change_ui_language; pause ;;' "$tmp/library.sh" || { echo 'FAIL: main-menu item 18 does not open language selection' >&2; exit 1; }
read_values='0'
_read_or_eof() { _read_value=${read_values%% *}; case "$read_values" in *' '*) read_values=${read_values#* } ;; *) read_values=0 ;; esac; return 0; }
is_installed() { return 0; }
confirm_yes() { return 0; }
xmenu_discord_menu() { printf discord >> "$tmp/actions"; }
xmenu_nf_manage_menu > "$tmp/manager-menu"
grep -q 'Выбрать и применить стратегию nfqws' "$tmp/manager-menu" || { echo 'FAIL: strategy action is missing from nfqws2 management' >&2; exit 1; }
grep -q 'Установить все blobs nfqws2' "$tmp/manager-menu" || { echo 'FAIL: install-all-blobs action is missing from nfqws2 management' >&2; exit 1; }
grep -q 'Скачать/проверить blobs и lists активной стратегии' "$tmp/manager-menu" || { echo 'FAIL: active strategy blob/list action is missing from nfqws2 management' >&2; exit 1; }
grep -q 'Скачать rkn.list (nfqws / nfqws2)' "$tmp/manager-menu" || { echo 'FAIL: rkn.list action is missing from nfqws2 management' >&2; exit 1; }
grep -q 'Обход блокировки DoT/DoH' "$tmp/manager-menu" || { echo 'FAIL: DoT/DoH bypass is missing' >&2; exit 1; }
grep -q 'Настройки текущих DNS-серверов' "$tmp/manager-menu" || { echo 'FAIL: current DNS settings item is missing' >&2; exit 1; }
grep -q 'Обновить Ipset Lists' "$tmp/manager-menu" || { echo 'FAIL: native IPSet item is missing' >&2; exit 1; }
grep -q 'Смена текущих fake:blob' "$tmp/manager-menu" || { echo 'FAIL: fake:blob item is missing' >&2; exit 1; }
grep -q 'Discord: включить/выключить фикс' "$tmp/manager-menu" || { echo 'FAIL: Discord fix item is missing' >&2; exit 1; }
grep -q 'Обновление hosts' "$tmp/manager-menu" || { echo 'FAIL: hosts item is missing' >&2; exit 1; }
awk '/Выбрать и применить стратегию nfqws/{a=NR} /Установить все blobs nfqws2/{b=NR} /Скачать\/проверить blobs и lists активной стратегии/{c=NR} /Скачать rkn.list \(nfqws \/ nfqws2\)/{d=NR} /Обход блокировки DoT\/DoH/{e=NR} /Настройки текущих DNS-серверов/{f=NR} /Обновить Ipset Lists/{g=NR} /Смена текущих fake:blob/{h=NR} /Discord: включить\/выключить фикс/{i=NR} /Обновление hosts/{j=NR} END {if (!(a<b&&b<c&&c<d&&d<e&&e<f&&f<g&&g<h&&h<i&&i<j)) exit 1}' "$tmp/manager-menu" || { echo 'FAIL: nfqws2 management actions are out of the requested order' >&2; exit 1; }
strategy_menu() { printf 'strategy\n' >> "$tmp/actions"; }
sync_active_blobs() { printf 'sync\n' >> "$tmp/actions"; }
install_all_nfqw2_blobs() { printf 'all-blobs\n' >> "$tmp/actions"; }
install_rkn_list() { printf 'rkn\n' >> "$tmp/actions"; }
ensure_network() { return 0; }
read_values='1 2 3 4 0'
xmenu_nf_manage_menu > "$tmp/manager-actions"
for action in strategy sync all-blobs rkn; do grep -q "^$action$" "$tmp/actions" || { echo "FAIL: nfqws2 management item did not dispatch $action" >&2; exit 1; }; done
is_installed() { [ "$1" = nfqws2-keenetic ]; }
xmenu_dot_doh_bypass_menu() { printf 'dot-bypass\n' >> "$tmp/actions"; }
read_values='5 0'
xmenu_nf_manage_menu > "$tmp/bypass-action"
grep -q '^dot-bypass$' "$tmp/actions" || { echo 'FAIL: DoT/DoH bypass is not a native menu action' >&2; exit 1; }
read_values='6 0'
: > "$tmp/actions"
ndmc() { :; }
xmenu_dns_ndmc() {
    case "$1" in
        'show dns-proxy')
            cat <<'EOF'
proxy-name: System
proxy-config:
  dns_server = 8.8.8.8 .
  dns_server = 127.0.0.1:40508 . # https://dns.example/dns-query@dnsm
DNS Servers
Ip               Port  Queries  ...
8.8.8.8          53    1        1 0 2ms 2ms 1
proxy-tls:
  server-tls:
    address: 1.1.1.1
    sni: cloudflare-dns.com
proxy-tls-filters:
  server-tls:
    address: 9.9.9.9
    port: 8853
    sni: dns.quad9.net
proxy-https-filters:
  server-https:
    uri: https://dns.adguard-dns.com/dns-query
proxy-name: Policy0
proxy-config:
  dns_server = 1.1.1.1 .
proxy-tls-filters:
  server-tls:
    address: 149.112.112.112
    sni: dns.quad9.net
EOF
            ;;
        'show running-config')
            printf '%s\n' \
                'dns-proxy filter assign interface preset Home adguard-family' \
                'dns-proxy filter profile DnsProfile0 tls upstream 185.228.168.9 853 sni security-filter-dns.cleanbrowsing.org' \
                'dns-proxy filter profile DnsProfile1 https upstream https://dns.adguard-dns.com/dns-query'
            ;;
        *) printf 'COMMAND:%s\n' "$1" >> "$tmp/ndmc-commands" ;;
    esac
}
xmenu_nf_manage_menu > "$tmp/dns-menu"
grep -q 'Интернет-фильтры' "$tmp/dns-menu" || { echo 'FAIL: Internet filter DNS section is not shown' >&2; exit 1; }
grep -q '9\.9\.9\.9' "$tmp/dns-menu" || { echo 'FAIL: DNS upstream from internet filter is not shown' >&2; exit 1; }
grep -q 'https://dns.adguard-dns.com/dns-query' "$tmp/dns-menu" || { echo 'FAIL: DoH upstream from internet filter is not shown' >&2; exit 1; }
grep -q 'DnsProfile0: DoT: 185\.228\.168\.9' "$tmp/dns-menu" || { echo 'FAIL: profile DNS from current internet-filter config is not shown' >&2; exit 1; }
grep -q 'Сеть Home: adguard-family' "$tmp/dns-menu" || { echo 'FAIL: active internet-filter preset assignment is not shown' >&2; exit 1; }
grep -q 'DNS без шифрования' "$tmp/dns-menu" || { echo 'FAIL: unencrypted system DNS is not shown' >&2; exit 1; }
if grep -q '127.0.0.1:40508' "$tmp/dns-menu"; then echo 'FAIL: internal encrypted DNS proxy was shown as a plain DNS server' >&2; exit 1; fi
if grep -Eq '^[[:space:]]+(Интернет-фильтры|Общие DNS:|1\. Добавить DoT)' "$tmp/dns-menu"; then echo 'FAIL: DNS screen still has a left margin' >&2; exit 1; fi
grep -q '8\.8\.8\.8' "$tmp/dns-menu" || { echo 'FAIL: unencrypted DNS address is not shown' >&2; exit 1; }
if grep -q 'Runtime DNS:\|DNS upstream-ы не заданы\|dns_server =' "$tmp/dns-menu"; then echo 'FAIL: raw or empty DNS sections remain in the user screen' >&2; exit 1; fi
if grep -q 'external loader called' "$tmp/dns-menu"; then echo 'FAIL: native DoT/DoH settings called the downloaded nfqws-menu loader' >&2; exit 1; fi
grep -q 'Добавить DoT' "$tmp/dns-menu" || { echo 'FAIL: native DoT menu action is missing' >&2; exit 1; }
if xmenu_dns_apply_dot '1.1.1.1;reboot' '' '' '' >/dev/null; then echo 'FAIL: DoT input allowed a command separator' >&2; exit 1; fi
if xmenu_dns_apply_doh 'https://dns.example/dns-query;reboot' '' >/dev/null; then echo 'FAIL: DoH input allowed a command separator' >&2; exit 1; fi
xmenu_dns_apply_dot 1.1.1.1 853 cloudflare-dns.com '' || { echo 'FAIL: valid DoT upstream was rejected' >&2; exit 1; }
grep -q '^COMMAND:dns-proxy tls upstream 1\.1\.1\.1 853 sni cloudflare-dns.com$' "$tmp/ndmc-commands" || { echo 'FAIL: valid DoT config was not sent to ndmc' >&2; exit 1; }
xmenu_dns_apply_doh https://dns.example/dns-query '' || { echo 'FAIL: valid DoH upstream was rejected' >&2; exit 1; }
grep -q '^COMMAND:dns-proxy https upstream https://dns.example/dns-query$' "$tmp/ndmc-commands" || { echo 'FAIL: valid DoH config was not sent to ndmc' >&2; exit 1; }
BRIGHT_CYAN='<CYAN>' RESET='</CYAN>'
read_values='99 example.net example.net 853 dns.example.net'
xmenu_dns_add_menu dot > "$tmp/dot-manual"
grep -Fq '<CYAN>  99) Ввести вручную</CYAN>' "$tmp/dot-manual" || { echo 'FAIL: manual DoT option is not turquoise 99' >&2; exit 1; }
grep -q '^COMMAND:dns-proxy tls upstream example.net 853 sni dns.example.net domain example.net$' "$tmp/ndmc-commands" || { echo 'FAIL: DoT manual 99 selection did not use manual fields' >&2; exit 1; }
read_values='99 example.net https://dns.example/dns-query'
xmenu_dns_add_menu doh > "$tmp/doh-manual"
grep -Fq '<CYAN>  99) Ввести вручную</CYAN>' "$tmp/doh-manual" || { echo 'FAIL: manual DoH option is not turquoise 99' >&2; exit 1; }
grep -q '^COMMAND:dns-proxy https upstream https://dns.example/dns-query$' "$tmp/ndmc-commands" || { echo 'FAIL: DoH manual 99 selection did not use manual URI' >&2; exit 1; }
read_values='1'
xmenu_dns_remove_menu > "$tmp/dns-remove"
grep -q '^COMMAND:no dns-proxy tls upstream 1\.1\.1\.1$' "$tmp/ndmc-commands" || { echo 'FAIL: removing a selected global DoT entry did not issue the expected Keenetic command' >&2; exit 1; }
if grep -q '^COMMAND:no dns-proxy tls upstream 9\.9\.9\.9' "$tmp/ndmc-commands"; then echo 'FAIL: global DNS deletion included the Internet filter upstream' >&2; exit 1; fi
grep -q 'Настройки текущих DNS-серверов' "$tmp/dns-menu" || { echo 'FAIL: native current DNS settings are not in nfqws2 management' >&2; exit 1; }

# Choosing "n" for the DoT/DoH confirmation must stop before download, backup,
# config edits, or service restart.
mkdir -p "$tmp/router/nfqws2" "$tmp/backups"
printf 'NFQWS_ARGS_CUSTOM=""\nTCP_PORTS=443\nUDP_PORTS=443\n' > "$tmp/router/nfqws2/nfqws2.conf"
cp "$tmp/router/nfqws2/nfqws2.conf" "$tmp/original-nfqws2.conf"
XMENU_NFQWS2_CONF="$tmp/router/nfqws2/nfqws2.conf"
XMENU_NFQWS2_INIT="$tmp/router/S51nfqws2"
backup_file() { printf '%s\n' "$1" >> "$tmp/backups/calls"; [ ! -f "$1" ] || cp "$1" "$1.bak"; }
xmenu_dot_doh_load_strategy() { printf '%s\n' called >> "$tmp/dot-doh-downloads"; return 1; }
xmenu_dot_doh_restart_service() { printf '%s\n' "$1" >> "$tmp/dot-doh-restarts"; }
unset -f xmenu_dot_doh_bypass_menu
eval "$(sed -n '/^xmenu_dot_doh_bypass_menu() {/,/^}/p' "$repo/xmenu-v1.0.sh")"
unset -f confirm_yes
eval "$(sed -n '/^confirm_yes() {/,/^}/p' "$repo/xmenu-v1.0.sh")"
read_values='5 n 0'
: > "$tmp/actions"
: > "$tmp/backups/calls"
rm -f "$tmp/dot-doh-downloads" "$tmp/dot-doh-restarts" "$tmp/external-actions"
xmenu_nf_manage_menu > "$tmp/dot-doh-no"
cmp -s "$tmp/original-nfqws2.conf" "$tmp/router/nfqws2/nfqws2.conf" || { echo 'FAIL: declining DoT/DoH changed the NFQWS2 config' >&2; exit 1; }
[ ! -s "$tmp/backups/calls" ] || { echo 'FAIL: declining DoT/DoH created a backup' >&2; exit 1; }
[ ! -e "$tmp/dot-doh-downloads" ] || { echo 'FAIL: declining DoT/DoH downloaded a strategy' >&2; exit 1; }
[ ! -e "$tmp/dot-doh-restarts" ] || { echo 'FAIL: declining DoT/DoH restarted a service' >&2; exit 1; }
grep -q 'Отменено: конфиг не менялся, стратегия не загружалась' "$tmp/dot-doh-no" || { echo 'FAIL: DoT/DoH cancellation was not reported clearly' >&2; exit 1; }

# IPSet update is implemented locally and cleans comments/blank lines before
# replacing the selected version's list and restarting only that service.
is_installed() { [ "$1" = nfqws2-keenetic ]; }
XMENU_NFQWS2_IPSET="$tmp/router/nfqws2/lists/ipset.list"
XMENU_NFQWS2_INIT="$tmp/router/S51nfqws2"
mkdir -p "$(dirname "$XMENU_NFQWS2_IPSET")"
printf '198.51.100.0/24\n' > "$XMENU_NFQWS2_IPSET"
: > "$tmp/backups/calls"
fetch() {
    printf '%s\n' "$1" >> "$tmp/ipset-urls"
    printf '# downloaded comment\n\n203.0.113.0/24  \n' > "$2"
}
xmenu_ipset_restart_service() { printf '%s\n' "$1" >> "$tmp/ipset-restarts"; }
read_values='7 1 0'
rm -f "$tmp/ipset-urls" "$tmp/ipset-restarts" "$tmp/external-actions"
xmenu_nf_manage_menu > "$tmp/ipset-menu"
grep -Fq 'Flowseal/zapret-discord-youtube/refs/heads/main/.service/ipset-service.txt' "$tmp/ipset-urls" || { echo 'FAIL: native IPSet action did not fetch the Flowseal list' >&2; exit 1; }
grep -Fxq '203.0.113.0/24' "$XMENU_NFQWS2_IPSET" || { echo 'FAIL: native IPSet action did not write the cleaned list' >&2; exit 1; }
! grep -q '^#\|^$' "$XMENU_NFQWS2_IPSET" || { echo 'FAIL: native IPSet action kept comments or blank lines' >&2; exit 1; }
grep -Fq "$XMENU_NFQWS2_IPSET" "$tmp/backups/calls" || { echo 'FAIL: native IPSet action did not back up the existing list' >&2; exit 1; }
grep -Fq "$tmp/router/S51nfqws2" "$tmp/ipset-restarts" || { echo 'FAIL: native IPSet action did not restart nfqws2' >&2; exit 1; }

confirm_yes() { return 0; }
run_remote_installer() { printf 'installer %s %s %s\n' "$1" "$2" "$3" >> "$tmp/actions"; }
opkg() { printf 'opkg %s\n' "$*" >> "$tmp/actions"; }
for utility in '1 usque-keenetic' '2 MagiTrickle' '3 firc' '4 warpscout'; do
    set -- $utility
    read_values="$1 0"
    : > "$tmp/actions"
    xmenu_other_utilities_menu > "$tmp/utilities-menu"
    grep -q "$2" "$tmp/utilities-menu" || { echo "FAIL: $2 utility is missing" >&2; exit 1; }
    if grep -q 'nfqws-menu.sh' "$tmp/actions"; then echo "FAIL: $2 downloaded the whole nfqws-menu.sh" >&2; exit 1; fi
done
is_installed() { return 1; }
confirm_yes() { return 1; }
read_values='2 0'
: > "$tmp/actions"
xmenu_other_utilities_menu > "$tmp/magitrickle-security"
grep -q 'репозиторий по HTTP' "$tmp/magitrickle-security" || { echo 'FAIL: insecure MagiTrickle bootstrap warning is missing' >&2; exit 1; }
if [ -s "$tmp/actions" ]; then echo 'FAIL: MagiTrickle installer ran without explicit confirmation' >&2; exit 1; fi
read_values='5 0'
: > "$tmp/actions"
xmenu_other_utilities_menu > "$tmp/zapret-manager"
grep -q 'OpenWrt' "$tmp/zapret-manager" || { echo 'FAIL: unsupported platform warning is missing' >&2; exit 1; }
if [ -s "$tmp/actions" ]; then echo 'FAIL: unsupported Zapret-Manager must not run an installer' >&2; exit 1; fi
printf 'PASS: NFQWS management and utility menus\n'
