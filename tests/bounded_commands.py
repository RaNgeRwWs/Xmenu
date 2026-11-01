import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

source = (Path(__file__).resolve().parents[1] / 'xmenu-v1.0.sh').read_text(encoding='utf-8')
code = source.split("<<'XMENU_TIMEOUT'\n", 1)[1].split('\nXMENU_TIMEOUT', 1)[0]

class TimeoutTests(unittest.TestCase):
    def run_command(self, limit, program):
        return subprocess.run([sys.executable, '-c', code, str(limit), sys.executable, '-c', program], capture_output=True, timeout=5)

    def test_stdout_and_stderr(self):
        result = self.run_command(2, 'import sys; print("out"); print("err", file=sys.stderr)')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), b'out')
        self.assertEqual(result.stderr.strip(), b'err')

    def test_exit_code_preserved(self):
        self.assertEqual(self.run_command(2, 'raise SystemExit(7)').returncode, 7)

    def test_timeout(self):
        start = time.monotonic()
        self.assertEqual(self.run_command(.1, 'import time; time.sleep(10)').returncode, 124)
        self.assertLess(time.monotonic() - start, 2)

    def test_invalid_limit_never_executes(self):
        for limit in ('nan', '-1', '0', 'inf', 'bad'):
            result = self.run_command(limit, 'print("executed")')
            self.assertEqual(result.returncode, 127)
            self.assertNotIn(b'executed', result.stdout)

    def test_cancel_terminates_child_group(self):
        with tempfile.TemporaryDirectory() as directory:
            pidfile = Path(directory) / 'pid'
            program = 'import subprocess,sys,time; p=subprocess.Popen([sys.executable,"-c","import time;time.sleep(30)"]);open(sys.argv[1],"w").write(str(p.pid));time.sleep(30)'
            process = subprocess.Popen([sys.executable, '-c', code, '20', sys.executable, '-c', program, str(pidfile)])
            try:
                deadline = time.monotonic() + 3
                while not pidfile.exists() and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(pidfile.exists())
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=3), 143)
                state = Path('/proc/' + pidfile.read_text() + '/stat')
                if state.exists():
                    self.assertEqual(state.read_text().split()[2], 'Z', 'grandchild still running')
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()

if __name__ == '__main__':
    unittest.main()
