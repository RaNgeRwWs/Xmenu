"""Проверка ввода в настоящем PTY под BusyBox ash (Linux CI)."""
import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import tempfile
import termios
import time

source = Path(__file__).resolve().parents[1] / "xmenu-v1.0.sh"


def check_input(payload, expected, interrupt=False, delay=0, pending=False, shared=None, prefix=b""):
    with tempfile.TemporaryDirectory() as directory:
        library = Path(directory) / "library.sh"
        library.write_text(source.read_text().replace('\nmain "$@"\n', '\n'), encoding="utf-8")
        harness = Path(directory) / "prompt.sh"
        version_file = Path(directory) / "version"
        version_file.write_text("1.4.0")
        ready_file = Path(directory) / "ready"
        setup = 'xmenu_show_pending_update_notice() { :; }\n'
        if pending:
            setup = (
                f'xmenu_cached_remote_version() {{ cat "{version_file}"; }}\n'
                'render_menu() { printf "\\033[2J\\033[HU. Check updates\\n"; '
                'XMENU_UPDATE_NOTICE_VISIBLE=0; xmenu_show_pending_update_notice; }\n'
                'render_menu\n'
            )
        if shared == "components":
            setup += (
                'XMENU_COMPONENT_REFRESH_PENDING=1\n'
                f'component_status_cache_fresh() {{ test -f "{ready_file}"; }}\n'
                'render_menu() { printf "COMPONENTS-READY\\n"; XMENU_COMPONENT_REFRESH_PENDING=0; }\n'
            )
        elif shared == "update":
            setup += (
                'XMENU_UPDATE_CHECK_PENDING=1\n'
                f'xmenu_update_cache_is_fresh() {{ test -f "{ready_file}"; }}\n'
            )
        harness.write_text(
            f'. "{library}"\ntrap - 0\n' + setup +
            'xmenu_read_menu_prompt "PROMPT> "\n'
            'result=$?\nprintf "RESULT=%s CHOICE=%s PENDING=%s\\n" "$result" "$_read_value" "$XMENU_COMPONENT_REFRESH_PENDING"\n',
            encoding="utf-8",
        )
        master, slave = pty.openpty()

        def controlling_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        process = subprocess.Popen(
            ["busybox", "ash", str(harness)], stdin=slave, stdout=slave,
            stderr=slave, preexec_fn=controlling_terminal,
        )
        os.close(slave)
        output = b""

        def collect_until(marker, seconds=5):
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
            collect_until(b"PROMPT> ")
            if shared:
                version_file.write_text("1.4.1")
                ready_file.write_text("ready")
                if shared == "components":
                    time.sleep(1.3)
                else:
                    collect_until("↑".encode())
                assert process.poll() is None, "shared cache update closed menu"
            if prefix:
                os.write(master, prefix)
                time.sleep(1.3)
            if interrupt:
                time.sleep(0.2)
                if pending:
                    version_file.write_text("1.4.1")
                process.send_signal(signal.SIGUSR1)
                time.sleep(0.2)
                assert process.poll() is None, "menu exited on SIGUSR1"
            if delay:
                time.sleep(delay)
                assert process.poll() is None, "menu exited on read timeout"
            os.write(master, payload)
            collect_until(expected)
            assert process.wait(timeout=3) == 0
            if pending:
                assert output.count("↑".encode()) == 1, output.decode(errors="replace")
                assert b"\x1b7\x1b[" in output, "update was not edited in place"
                assert output.count(b"\x1b[2J") == 1, "update cleared the entire screen again"
                assert "v1.4.1".encode() in output
            assert output.count(b"PROMPT> ") == 1, "background result repeated the prompt"
            if shared == "components":
                assert b"COMPONENTS-READY" not in output, "component refresh printed another menu"
                assert b"PENDING=0" in output
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)


check_input(b"23\n", b"RESULT=0 CHOICE=23", interrupt=True)
check_input(b"23\n", b"RESULT=0 CHOICE=23", interrupt=True, pending=True)
check_input(b"23\n", b"RESULT=0 CHOICE=23", delay=1.3)
check_input(b"3\n", b"RESULT=0 CHOICE=23", prefix=b"2")
check_input(b"23\n", b"RESULT=0 CHOICE=23", shared="components")
check_input(b"23\n", b"RESULT=0 CHOICE=23", pending=True, shared="update")
check_input(b"\n", b"RESULT=0 CHOICE=")
check_input(b"\x04", b"RESULT=1 CHOICE=")
print("PASS: BusyBox PTY signal, timeout, Enter and EOF")
