"""Run the release checks on Linux or an Entware router without changing packages."""
import ast
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)

def run(args, env=None):
    print('+ ' + ' '.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), check=True, env=env)

with tempfile.TemporaryDirectory(prefix='xmenu-checks-') as temporary:
    env = os.environ.copy()
    if not env.get('XMENU_TEST_CERT') and shutil.which('openssl'):
        cert, key = Path(temporary) / 'cert.pem', Path(temporary) / 'key.pem'
        run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1', '-keyout', key, '-out', cert])
        env.update(XMENU_TEST_CERT=str(cert), XMENU_TEST_KEY=str(key))
    # Old router sleep applets accept integer seconds only. This shim belongs
    # to the test process PATH and is removed with the temporary directory.
    probe = subprocess.run(['sleep', '0.001'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if probe.returncode:
        shim = Path(temporary) / 'sleep'
        shim.write_text('#!' + sys.executable + '\nimport sys,time\ntime.sleep(float(sys.argv[1]))\n')
        shim.chmod(0o700)
        env['PATH'] = temporary + os.pathsep + env.get('PATH', '')
    text = (ROOT / 'xmenu-v1.0.sh').read_text(encoding='utf-8')
    for marker in ('XMENU_SITE_ENGINE', 'XMENU_DNS_ENGINE', 'XMENU_SERVER_ENGINE'):
        code = text.split("<<'" + marker + "'\n", 1)[1].split('\n' + marker, 1)[0]
        ast.parse(code)
    for filename in ('SHA256SUMS', 'strategies/nfqws2/SHA256SUMS'):
        for line in Path(filename).read_text().splitlines():
            digest, path = line.split(maxsplit=1)
            assert hashlib.sha256(Path(path.lstrip('*')).read_bytes()).hexdigest() == digest, path
    for path in [Path('xmenu-v1.0.sh'), *Path('strategies/nfqws2').rglob('*.conf')]:
        run(['busybox', 'ash', '-n', path], env)
    if shutil.which('shellcheck'):
        run(['shellcheck', '-s', 'sh', '-S', 'warning', 'xmenu-v1.0.sh'], env)
    else:
        print('ShellCheck unavailable in this environment; CI runs it separately.', flush=True)
    for name in ('regression', 'audit_regression', 'service_regression', 'nfqws_features', 'native_actions', 'site_diagnostics', 'nfqws_install', 'additional_strategies'):
        run(['busybox', 'ash', 'tests/' + name + '.sh'], env)
    for name in ('strategy_configs', 'bounded_commands', 'dns_diagnostics', 'server_diagnostics', 'server_extensions', 'site_diagnostics', 'menu_input', 'startup_render'):
        run([sys.executable, 'tests/' + name + '.py'], env)
print('PASS: complete release checks', flush=True)
