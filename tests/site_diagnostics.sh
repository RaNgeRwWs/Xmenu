#!/bin/sh
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sed '/^main "\$@"$/d' "$repo/xmenu-v1.0.sh" > "$tmp/library"
. "$tmp/library"
curl() {
    printf 'code=%s\nip=%s\ndns=%s\ntcp=%s\ntls=%s\ntotal=1\n' "$code" "$ip" "$dns" "$tcp" "$tls"
    return "$rc"
}
check() {
    result=0
    xmenu_site_check_legacy "$1" > "$tmp/report" || result=$?
    grep -Fq "$2" "$tmp/report" || { cat "$tmp/report"; exit 1; }
}
code=200 ip=1.1.1.1 dns=0.01 tcp=0.02 tls=0.03 rc=0
check example.com 'Все необходимые этапы пройдены'
[ "$result" = 0 ]
code=403; check example.com 'Сервер ограничил доступ'
code=302; check example.com 'Конечная страница перенаправления не проверялась'
code=000 ip='' dns=0 tcp=0 tls=0 rc=6
check invalid.example 'имя сайта не найдено'
rc=7 dns=0.01; check example.com 'Нет TCP-соединения'
rc=28; check example.com 'Нет TCP-соединения'
rc=60 tcp=0.02; check example.com 'Не прошла проверка сертификата'
! grep -q 'сертификат проверен' "$tmp/report"
rc=28; check example.com 'TCP работает, но TLS не завершён'
tls=0.03; check example.com 'HTTP-ответ не получен'
code=200 rc=0; check http://example.com 'не используется для HTTP'
check 'https://example.com:99999' 'Порт должен быть'
[ "$result" = 2 ]
check 'https://user:password@example.com' 'без пробелов и учётных данных'
[ "$result" = 2 ]
check 'https://example.com/$(id)' 'без пробелов и учётных данных'
[ "$result" = 2 ]
printf 'Site diagnostics checks passed\n'
