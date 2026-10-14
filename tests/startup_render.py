"""Быстрый последовательный экран, фоновые результаты и ввод во время уведомления."""
import fcntl
from pathlib import Path
import os
import pty
import re
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time

source = Path(__file__).resolve().parents[1] / "xmenu-v1.0.sh"


def check_startup(order, rows, columns):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        library = root / "library.sh"
        library.write_text(source.read_text().replace('\nmain "$@"\n', '\n'), encoding="utf-8")
        harness = root / "startup.sh"
        events = {
            "components": 'touch "$ROOT_DIR/ready"',
            "update": 'printf "1.4.1" > "$ROOT_DIR/version"',
        }
        harness.write_text(
            (
            f'. "{library}"\n'
            f'ROOT_DIR="{root}/data"\n'
            'BACKUP_DIR="$ROOT_DIR/backups"; LANG_FILE="$ROOT_DIR/language"\n'
            'sleep() { case "${1:-}" in *.*) printf "%s\\n" "$1" >> "$ROOT_DIR/fractional-sleep.calls" ;; esac; command sleep "$@"; }\n'
            'usleep() { printf "%s\\n" "$1" >> "$ROOT_DIR/usleep.calls"; command sleep 1; }\n'
            'XMENU_COMPONENT_CACHE="$ROOT_DIR/components"\n'
            'XMENU_COMPONENT_CACHE_TIME="$ROOT_DIR/components.time"\n'
            'XMENU_COMPONENT_REFRESH_LOCK="$ROOT_DIR/component.lock"\n'
            'XMENU_UPDATE_LOCK="$ROOT_DIR/update.lock"; LOCK_DIR="$ROOT_DIR/operation.lock"\n'
            'mkdir -p "$BACKUP_DIR"; printf "1.4.0" > "$ROOT_DIR/version"\n'
            'configure_locale() { :; }; require_root() { :; }; require_opkg() { :; }\n'
            'migrate_legacy_xmenu_data() { :; }; install_xmenu_command() { :; }; ensure_dirs() { :; }\n'
            'get_router() { printf "Hopper (NC-3811)|5.1.7"; }; get_arch() { printf aarch64; }\n'
            'xmenu_cached_remote_version() { cat "$ROOT_DIR/version"; }\n'
            'xmenu_update_cache_is_fresh() { test "$(cat "$ROOT_DIR/version")" = 1.4.1; }\n'
            'component_status_cache_fresh() { test -f "$ROOT_DIR/ready"; }\n'
            'start_component_status_refresh() { return 1; }\n'
            'render_component_statuses_sync() {\n'
            '  printf "Установленные компоненты:\\n  xkeen 1.0\\n"\n'
            '  printf "xkeen\\t1.0\\n" > "$XMENU_COMPONENT_CACHE"\n'
            '  XMENU_COMPONENT_REFRESH_PENDING=1\n'
            '}\n'
            'opkg_settings_menu() { printf "SELECTED=23\\n"; exit 0; }\n'
            'xmenu_start_update_check() {\n'
            '  XMENU_UPDATE_CHECK_PENDING=1\n'
            f'  (command sleep 0.3; {events[order[0]]}; kill -USR1 "$$"; '
            f'command sleep 0.5; {events[order[1]]}; kill -USR1 "$$") &\n'
            '}\nmain\n'
            ),
            encoding="utf-8",
        )
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        env = os.environ.copy()
        env["TERM"] = "xterm"

        def controlling_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        process = subprocess.Popen(
            ["busybox", "ash", str(harness)], stdin=slave, stdout=slave,
            stderr=slave, preexec_fn=controlling_terminal, env=env,
        )
        os.close(slave)
        output = b""
        started_at = time.monotonic()

        def collect(marker, seconds=6):
            nonlocal output
            deadline = time.monotonic() + seconds
            while marker not in output and time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        output += os.read(master, 4096)
                    except OSError:
                        break
            assert marker in output, output.decode(errors="replace")

        try:
            collect(b"[?]")
            assert time.monotonic() - started_at < 2, "initial menu frame was too slow"
            assert not (root / "data/usleep.calls").exists(), "startup invoked usleep"
            assert not (root / "data/fractional-sleep.calls").exists(), "startup invoked fractional sleep"
            assert "Установленные компоненты:".encode() in output, "first screen lacks components"
            assert b"xkeen 1.0" in output, "first screen lacks installed version"
            assert "Запуск Xmenu".encode() not in output, "startup banner should not be shown"
            assert b"Starting Xmenu" not in output, "startup banner should not be shown"
            os.write(master, b"2")
            collect(b"v1.4.1")
            time.sleep(0.5)
            assert process.poll() is None, "background completion closed menu"
            os.write(master, b"3\n")
            collect(b"SELECTED=23")
            assert process.wait(timeout=3) == 0
            assert output.count(b"\x1b[2J") == 1, "startup cleared the whole menu more than once"
            assert output.count("Xmenu ◆ v1.4.0".encode()) == 1, "startup printed a second menu"
            assert output.count(b"[?]") == 1, "startup repeated the prompt"
            assert output.count(b"v1.4.1") == 1, "update notice duplicated"
            offsets = re.findall(rb"\x1b7\x1b\[(\d+)A", output)
            assert len(offsets) == 1, "notice was not patched exactly once"
            assert (int(offsets[0]) > 1) == (rows == 70), "wrong visible notice slot"
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            os.close(master)


for order in (("components", "update"), ("update", "components")):
    for rows, columns in ((70, 80), (24, 80), (24, 40)):
        check_startup(order, rows, columns)
print("PASS: quick sequential startup, no artificial delays or duplicate menu, both background orders")
