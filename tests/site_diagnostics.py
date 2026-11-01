import contextlib
import io
from pathlib import Path
import socket
import sys
import threading
import time
import types
import unittest
from unittest import mock

source = (Path(__file__).resolve().parents[1] / 'xmenu-v1.0.sh').read_text(encoding='utf-8')
def load(marker, name):
    code = source.split("<<'" + marker + "'\n", 1)[1].split('\n' + marker, 1)[0]
    module = types.ModuleType(name)
    sys.modules[name] = module
    exec(compile(code, '<' + name + '>', 'exec'), module.__dict__)
    return module
site = load('XMENU_SITE_ENGINE', 'site_tests')
transport = load('XMENU_SERVER_ENGINE', 'site_transport_tests')
dns = load('XMENU_DNS_ENGINE', 'site_dns_tests')

class SiteTests(unittest.TestCase):
    def setUp(self):
        transport.CANCEL.clear()
        transport.END_TIME = float('inf')
        transport.BYPASS_MARK = 0
        transport.WAN_IFACE = ''
        transport.INPUT_CHAINS = []

    def test_url_inputs(self):
        for value, host, port in [('example.com', 'example.com', 443), ('http://example.com:8080/a?b=c', 'example.com', 8080), ('1.1.1.1', '1.1.1.1', 443), ('2001:4860:4860::8888', '2001:4860:4860::8888', 443), ('https://[::1]:8443/', '::1', 8443)]:
            with self.subTest(value=value):
                actual = site.parse_url(value)
                self.assertEqual(actual[1:], (host, port))

    def test_bad_inputs(self):
        for value in ['', 'a b', 'https://user:password@example.com', 'ftp://example.com', 'https://example.com:99999', 'https://a..b', 'https://-a.com', 'https://example.com/\r\nX:evil']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                site.parse_url(value)

    def test_literal_does_not_use_dns(self):
        with mock.patch.object(site.subprocess, 'run', side_effect=AssertionError('DNS invoked')):
            self.assertEqual(site.resolve('1.1.1.1', transport), (['1.1.1.1'], 0.0, None))

    def test_resolver_failure(self):
        with mock.patch.object(site.subprocess, 'run', return_value=types.SimpleNamespace(returncode=1)):
            self.assertTrue(site.resolve('example.com', transport)[2])

    def test_direct_route_must_be_verified(self):
        with mock.patch.object(transport, 'public_target'), mock.patch.object(transport, 'detect_path', return_value={'mark': 1, 'direct_ready': False}), mock.patch.object(transport, 'inspect_route'):
            with self.assertRaises(OSError):
                site.direct_path('1.1.1.1', transport)

    def loopback(self, payload):
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        port = listener.getsockname()[1]
        def serve():
            try:
                connection, _ = listener.accept()
                with connection:
                    connection.recv(8192)
                    connection.sendall(payload)
            finally:
                listener.close()
        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        def connect(ip, port, timeout):
            started = time.monotonic()
            sock = socket.create_connection((ip, port), timeout)
            return sock, (time.monotonic() - started) * 1000, None
        with mock.patch.object(transport, 'connect', side_effect=connect):
            result = site.request('http://127.0.0.1:' + str(port), '127.0.0.1', transport)
        worker.join(3)
        self.assertFalse(worker.is_alive())
        return result

    def test_http_get_and_fractional_timing(self):
        value = self.loopback(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK')
        self.assertEqual(value['status'], 'OK')
        self.assertEqual(value['body'], b'OK')
        self.assertIsInstance(value['tcp_ms'], float)
        self.assertEqual(value['http'], 200)

    def test_truncated_content_length(self):
        value = self.loopback(b'HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\nOK')
        self.assertEqual(value['status'], 'BODY ERROR')

    def test_body_limit(self):
        value = self.loopback(b'HTTP/1.1 200 OK\r\nContent-Length: 20000\r\n\r\n' + b'x' * 20000)
        self.assertEqual(value['status'], 'OK')
        self.assertTrue(value['limited'])
        self.assertEqual(value['bytes'], 16384)

    def test_empty_http_is_failure(self):
        value = self.loopback(b'')
        self.assertNotEqual(value['status'], 'OK')
        self.assertIsNone(value['http'])

    def test_redirect_headers(self):
        value = self.loopback(b'HTTP/1.1 301 Moved\r\nLocation: https://example.com/\r\nContent-Length: 0\r\n\r\n')
        self.assertEqual(value['http'], 301)
        self.assertEqual(value['location'], 'https://example.com/')

    def diagnose(self, responses, resolver=None, references=None, direct=False):
        buffer = io.StringIO()
        with mock.patch.object(site, 'resolve', side_effect=resolver or (lambda *a: (['1.1.1.1'], 12.0, None))), mock.patch.object(site, 'reference_dns', side_effect=references), mock.patch.object(site, 'request', side_effect=responses), mock.patch.object(site, 'show_rows') as table, mock.patch.object(transport, 'cleanup_flows'), contextlib.redirect_stdout(buffer):
            result = site.diagnose('https://example.com', transport, dns, direct)
        return result, buffer.getvalue(), table

    def answer(self, http=200, location=None):
        return {'url': 'https://example.com', 'ip': '1.1.1.1', 'http': http, 'location': location, 'status': 'OK', 'stage': 'Чтение', 'tcp_ms': 2.4}

    def test_single_table_and_redirect_verdict(self):
        result, output, table = self.diagnose([self.answer(301, 'https://www.example.com/'), self.answer()])
        self.assertEqual(result, 0)
        self.assertIn('HTTP 301 → HTTP 200', output)
        self.assertIn('Сайт открывается', output)
        table.assert_called_once()

    def test_dns_fallback_includes_aaaa_only(self):
        calls = []
        def reference(host, transport, dns, direct, qtype):
            calls.append(qtype)
            return (['2606:4700:4700::1111'] if qtype == 28 else []), 'DoH'
        result, output, _ = self.diagnose([self.answer()], resolver=lambda *a: ([], 10, 'failed'), references=reference)
        self.assertEqual(calls, [1, 28])
        self.assertEqual(result, 1)
        self.assertIn('резервный DNS', output)

    def test_redirect_cycle(self):
        result, output, _ = self.diagnose([self.answer(301, 'https://example.com/')])
        self.assertEqual(result, 1)
        self.assertIn('Цикл', output)

    def test_403_is_not_success(self):
        result, output, _ = self.diagnose([self.answer(403)])
        self.assertEqual(result, 1)
        self.assertIn('HTTP 403', output)
        self.assertNotIn('Сайт открывается', output)

    def test_submillisecond_display(self):
        row = self.answer()
        row.update(tcp_ms=.03, tls_ms=25.2, first_ms=10, literal=False, step='1. example.com', dns_ms=2)
        with mock.patch.object(transport, 'table') as table:
            site.show_rows([row], transport)
        self.assertIn('<0.1 мс', str(table.call_args))

if __name__ == '__main__':
    unittest.main()
