
# Xmenu v1.0 — Интерактивное меню для Keenetic / Entware

**Xmenu** — это интерактивное shell-меню для установки, настройки и удаления **XKeen**, **nfqws/nfqws2** и связанных сетевых утилит на роутерах **Keenetic / Netcraze** с **Entware**.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/platform-Keenetic%20%7C%20Entware-blue)](https://github.com/RaNgeRwWs/Xmenu)
[![Shell](https://img.shields.io/badge/shell-bash%20%7C%20ash-green)](https://github.com/RaNgeRwWs/Xmenu)

> ⚠️ **Внимание:** некоторые действия скачивают и запускают сторонние установщики с правами `root`. Перед использованием проверьте ссылки на первоисточники, сохраните резервную копию настроек и убедитесь, что у вас есть способ восстановить доступ к роутеру. Проверка синтаксиса не заменяет тестирование на устройстве.

---

## 🚀 Возможности

- 🛠 **Установка и обновление**:
  - **XKeen Stable**
  - XKeen UI (zxc-rv / umarcheh001)
  - **nfqws2**
  - **nfqws-web-keenetic**
  - **nfqws2-ui**
- 📦 **Готовые профили XKeen Auto** с Mihomo или Xray, GeoIPSet и автозагрузкой.
- 🎯 **Выбор стратегии** nfqws/nfqws2, проверка и загрузка используемых blobs/lists, установка blobs и загрузка `rkn.list`.
- 🧰 **Установка/запуск**:
  - **DPI Detector**
  - **TG WS Proxy Rust**
  - **KeenKit**
  - **awg-manager**
- 📊 **Отображение** установленных компонентов и их состояния.
- 🌐 **Переключение интерфейса** RU / EN.
- 🔢 **Числовые пункты** в меню удаления компонентов; действия, удаляющие файлы или пакеты, запрашивают подтверждение.
- 🛡 **Защита кастомной стратегии**: проверка активных blobs/lists не должна заменять произвольно изменённый пользователем конфиг только из-за старой метки выбранной стратегии.
- 💾 **Резервирование** существующего скрипта перед обновлением и проверка синтаксиса перед заменой.

---

## 📋 Главное меню

| Номер | Действие |
|-------|----------|
| 1–6   | XKeen Stable, две версии XKeen UI, nfqws2, nfqws-web-keenetic, nfqws2-ui |
| 7–10  | Профили XKeen Auto / Mihomo / Xray и комбинированные профили |
| 11–14 | Стратегия, blobs/lists активной стратегии, все blobs NFQWS2, `rkn.list` |
| 15–20 | DPI Detector, TG WS Proxy Rust, KeenKit, awg-manager, статус, язык |
| 21–22 | Удаление компонентов и удаление Xmenu |
| 0     | Выход |

> В меню удаления динамические пункты назначаются только цифрами. Нумерация компонентов строится по обнаруженным установленным компонентам.

---

## 🖥 Отображение устройства

Xmenu получает модель роутера и название/версию системы из локального Keenetic RCI API (`http://127.0.0.1:79/rci/show/version`) — по тому же принципу, что и `nfqws-menu`. Если RCI недоступен или неполон, скрипт использует дополнительные локальные источники, включая `ndmc` и Device Tree.

Архитектура определяется в порядке:
1. `opkg print-architecture` — основной и предпочтительный источник.
2. `/opt/etc/opkg.conf` — резервный источник.
3. `uname -m` — последний fallback; значения `mips*` от `uname` не используются, так как на части Keenetic они могут быть неточными.

---

## 📦 Установка одной командой из SSH

### 🔹 Быстрый способ (рекомендуется)

Скопируйте и вставьте эту команду в терминал:

```bash
opkg update && opkg install curl libnghttp2 && curl -fLsS --retry 3 https://raw.githubusercontent.com/RaNgeRwWs/Xmenu/main/xmenu-v1.0.sh -o /tmp/xmenu-v1.0.sh && sh -n /tmp/xmenu-v1.0.sh && mkdir -p /opt/bin && { [ ! -f /opt/bin/xmenu ] || cp -p /opt/bin/xmenu /opt/bin/xmenu.bak; } && cp /tmp/xmenu-v1.0.sh /opt/bin/xmenu && chmod +x /opt/bin/xmenu && sh /opt/bin/xmenu
```

### 🔹 Ещё проще (для ленивых)

Если вы уверены в безопасности и хотите просто запустить:

```bash
curl -fLsS --retry 3 https://raw.githubusercontent.com/RaNgeRwWs/Xmenu/main/xmenu-v1.0.sh | sh
```

> После первого запуска для быстрого старта просто введите: `xmenu`

---

## 📚 Источники проектов

- [nfqws-menu](https://github.com/rndnaame/nfqws-menu) — Оригинальный проект nfqws-menu.
- [XKeen](https://github.com/jameszeroX/XKeen)
- [XKeen UI — zxc-rv](https://github.com/zxc-rv/XKeen-UI)
- [XKeen UI — umarcheh001](https://github.com/umarcheh001/Xkeen-UI)
- [nfqws2-keenetic](https://github.com/nfqws/nfqws2-keenetic)
- [nfqws-keenetic-web](https://github.com/nfqws/nfqws-keenetic-web)
- [nfqws2-ui](https://github.com/zemidala/nfqws2-ui)
- [DPI Detector](https://github.com/Runnin4ik/dpi-detector)
- [TG WS Proxy Rust](https://github.com/valnesfjord/tg-ws-proxy-rs)
- [KeenKit](https://github.com/spatiumstas/KeenKit)
- [awg-manager](https://github.com/hoaxisr/awg-manager)
- [RKN list source](https://github.com/IndeecFOX/zapret4rocket)

> Скрипт проверяет минимальный размер и синтаксис ряда скачиваемых shell-установщиков, но это не является криптографической проверкой подлинности. Upstream-ветки `main`/`master` могут изменяться; для production-релиза рекомендуется фиксировать проверенные commit SHA и публиковать контрольные суммы.

---

## ⚙️ Проверки и ограничения

Локально проверяются синтаксис `sh`, `dash` и BusyBox `ash`; отдельно проверяется формирование заголовка с заданной шириной терминала и отсутствие буквенных пунктов в меню удаления.

Эти проверки **не подтверждают** успешность установки пакетов, корректность перезапуска сервисов или все особенности вывода в конкретном SSH-клиенте. Скрипт не был установлен и полностью протестирован на физическом Keenetic в рамках этой сборки. Перед публичным выпуском следует провести тестирование на реальном устройстве.

---

## 🤝 Вклад

Если у вас есть идеи или вы нашли баг — создайте Issue или отправьте Pull Request. Мы будем рады улучшениям!

---

## 📄 Лицензия

Этот проект распространяется под лицензией MIT. Подробнее см. в файле [LICENSE](LICENSE).
```

---

Просто скопируй этот блок целиком и вставь в файл `README.md` в корне репозитория. Всё уже готово. 🚀
