import contextlib
import errno
import http.server
import io
import json
import os
import re
from pathlib import Path
import signal
import shutil
import socket
import socketserver
import ssl
import struct
import subprocess
import sys
import threading
import time
import types
import unittest
from unittest import mock


path = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / 'xmenu-v1.0.sh'
source = path.read_text(encoding='utf-8')
code = source.split("<<'XMENU_SERVER_ENGINE'\n", 1)[1].split('\nXMENU_SERVER_ENGINE', 1)[0]
engine = types.ModuleType('server_diagnostics')
sys.modules[engine.__name__] = engine
exec(compile(code, '<server diagnostics>', 'exec'), engine.__dict__)


def ipv4(payload, protocol=1, dst='1.1.1.1'):
    return b'\x45\0' + struct.pack('!H', len(payload) + 20) + b'\0' * 4 + bytes([64, protocol]) + b'\0\0' + socket.inet_aton('192.0.2.1') + socket.inet_aton(dst) + payload


def sample_report():
    return {'ip': '1.1.1.1', 'route': {'ok': True}, 'path': {'direct_ready': True, 'local_filter': {'status': 'OK', 'candidates': []}}, 'tcp': {443: {'status': 'TIMEOUT'}}, 'ping': {'received': 0}, 'traces': {}, 'http': {}, 'ssh': {'status': 'TIMEOUT'}, 'controls': {'8.8.8.8': {'status': 'OPEN'}}, 'external': []}


class PacketTests(unittest.TestCase):
    def test_checksum(self):
        data = b'\x08\0\0\0\x12\x34\0\x01Xmenu'
        check = engine.checksum(data)
        self.assertEqual(engine.checksum(data[:2] + struct.pack('!H', check) + data[4:]), 0)

    def test_echo_reply_identity(self):
        data = ipv4(struct.pack('!BBHHH', 0, 0, 0, 123, 2))
        self.assertTrue(engine.icmp_event(data, '1.1.1.1', '1.1.1.1', 1, 123, 0, 2)['reached'])
        self.assertIsNone(engine.icmp_event(data, '1.1.1.1', '1.1.1.1', 1, 124, 0, 2))

    def test_udp_ttl_response_is_matched(self):
        quote = ipv4(struct.pack('!HHHH', 45678, 33435, 8, 0), 17)
        data = ipv4(struct.pack('!BBHI', 11, 0, 0, 0) + quote)
        event = engine.icmp_event(data, '192.0.2.2', '1.1.1.1', 17, 45678, 33435, 1)
        self.assertEqual(event['status'], 'TTL EXCEEDED')
        self.assertFalse(event['reached'])
        self.assertIsNone(engine.icmp_event(data, '192.0.2.2', '1.1.1.1', 17, 45679, 33435, 1))

    def test_prohibited_and_mtu(self):
        quote = ipv4(struct.pack('!HHHH', 45678, 33435, 8, 0), 17)
        prohibited = ipv4(struct.pack('!BBHI', 3, 13, 0, 0) + quote)
        self.assertEqual(engine.icmp_event(prohibited, '192.0.2.2', '1.1.1.1', 17, 45678, 33435, 1)['status'], 'PROHIBITED')
        mtu = ipv4(struct.pack('!BBHHH', 3, 4, 0, 0, 1400) + quote)
        self.assertEqual(engine.icmp_event(mtu, '192.0.2.2', '1.1.1.1', 17, 45678, 33435, 1)['mtu'], 1400)

    def test_udp_destination_closed_is_reached(self):
        quote = ipv4(struct.pack('!HHHH', 45678, 33435, 8, 0), 17)
        packet = ipv4(struct.pack('!BBHI', 3, 3, 0, 0) + quote)
        self.assertTrue(engine.icmp_event(packet, '1.1.1.1', '1.1.1.1', 17, 45678, 33435, 1)['reached'])

    def test_ipv6_error_packet(self):
        ip = '2001:4860:4860::8888'
        quote = b'\x60\0\0\0' + struct.pack('!HBB', 8, 17, 1) + socket.inet_pton(socket.AF_INET6, '::1') + socket.inet_pton(socket.AF_INET6, ip) + struct.pack('!HHHH', 45678, 33435, 8, 0)
        event = engine.icmp_event(struct.pack('!BBHI', 3, 0, 0, 0) + quote, '::2', ip, 17, 45678, 33435, 1)
        self.assertEqual(event['status'], 'TTL EXCEEDED')

    def test_tcp_synack_and_unrelated_packet(self):
        header = struct.pack('!HHIIBBHHH', 443, 45678, 999, 12346, 5 << 4, 0x12, 60000, 0, 0)
        packet = ipv4(header, 6)
        self.assertTrue(engine.tcp_event(packet, '1.1.1.1', '1.1.1.1', 45678, 443, 12345)['reached'])
        self.assertIsNone(engine.tcp_event(packet, '1.1.1.1', '1.1.1.1', 45678, 443, 12344))

    def test_tcp_checksum(self):
        packet = engine.tcp_packet('192.0.2.1', '1.1.1.1', 45678, 443, 12345)
        pseudo = socket.inet_aton('192.0.2.1') + socket.inet_aton('1.1.1.1') + struct.pack('!BBH', 0, 6, 20)
        self.assertEqual(engine.checksum(pseudo + packet), 0)

    def test_short_packets_do_not_match(self):
        for length in range(20):
            self.assertIsNone(engine.icmp_event(b'\0' * length, '1.1.1.1', '1.1.1.1', 17, 123, 456, 1))


class VerdictTests(unittest.TestCase):
    def test_ping_blocked_but_tcp_open(self):
        report = sample_report()
        report['tcp'][443]['status'] = 'OPEN'
        self.assertIn('доступен', engine.verdict(report)[0])

    def test_external_tcp_works_and_direct_does_not(self):
        report = sample_report()
        report['external'] = [{'kind': 'tcp', 'port': 443, 'status': 'OPEN'}]
        self.assertIn('внешних узлов', engine.verdict(report)[0])

    def test_refused_is_not_passive_ip_ban(self):
        report = sample_report()
        report['tcp'][443]['status'] = 'REFUSED'
        self.assertIn('явный отказ', engine.verdict(report)[0])

    def test_ipv6_no_route_is_local_problem(self):
        report = sample_report()
        report.update(ip='2001:4860::1', route={'ok': False})
        self.assertIn('локального маршрута', engine.verdict(report)[0])

    def test_unverified_proxy_is_not_ip_verdict(self):
        report = sample_report()
        report['path']['direct_ready'] = False
        report['tcp'][443]['status'] = 'OPEN'
        self.assertIn('не подтверждён', engine.verdict(report)[0])

    def test_all_silent_does_not_assert_provider_ban(self):
        report = sample_report()
        self.assertIn('Однозначно', engine.verdict(report)[1])

    def test_external_ping_parser(self):
        status, delay = engine.remote_value([[['OK', .01, '1.1.1.1'], ['TIMEOUT', 3], ['OK', .02]]], 'ping')
        self.assertEqual(status, 'REPLY')
        self.assertAlmostEqual(delay, 15)

    def test_external_tcp_parser(self):
        self.assertEqual(engine.remote_value([{'time': .02, 'address': '1.1.1.1'}], 'tcp'), ('OPEN', 20))
        self.assertEqual(engine.remote_value([{'error': 'Connection timed out'}], 'tcp')[0], 'TIMEOUT')
        self.assertEqual(engine.remote_value(None, 'tcp')[0], 'PENDING')


class BypassTests(unittest.TestCase):
    def setUp(self):
        engine.FLOW_RULES.clear()
        engine.CANCEL.clear()

    def test_scoped_rule_and_exact_cleanup(self):
        with mock.patch.object(engine, 'INPUT_CHAINS', [('iptables', 'nfqws_pre')]), mock.patch.object(engine, 'firewall', return_value=True) as call:
            guard = engine.FlowGuard('1.1.1.1', 'tcp', 45678, 443)
            add = call.call_args_list[0][0][0]
            self.assertEqual(add[:7], ['iptables', '-w', '-t', 'mangle', '-I', 'nfqws_pre', '1'])
            self.assertEqual(add[add.index('--dport') + 1], '45678')
            self.assertEqual(add[add.index('--sport') + 1], '443')
            self.assertEqual(add[add.index('-s') + 1], '1.1.1.1')
            guard.close()
            delete = call.call_args_list[1][0][0]
            self.assertEqual(delete[:6], ['iptables', '-w', '-t', 'mangle', '-D', 'nfqws_pre'])
            self.assertEqual(delete[6:], add[7:])
            self.assertFalse(engine.FLOW_RULES)

    def test_unsupported_bypass_aborts_probe(self):
        with mock.patch.object(engine, 'INPUT_CHAINS', [('iptables', 'nfqws_pre')]), mock.patch.object(engine, 'firewall', return_value=False):
            with self.assertRaises(OSError) as error:
                engine.FlowGuard('1.1.1.1', 'tcp', 45678, 443)
            self.assertEqual(engine.network_error(error.exception), 'BYPASS FAIL')

    def test_socket_mark_is_set(self):
        sock = mock.Mock()
        with mock.patch.object(engine, 'BYPASS_MARK', 0x40000000):
            engine.prepare_socket(sock)
        sock.setsockopt.assert_called_once_with(socket.SOL_SOCKET, getattr(socket, 'SO_MARK', 36), 0x40000000)

    def test_route_error_not_mistaken_for_timeout(self):
        result = mock.Mock(returncode=2, stdout=b'', stderr=b'Network unreachable')
        with mock.patch.object(engine.subprocess, 'run', return_value=result):
            self.assertFalse(engine.route('1.1.1.1')['ok'])

    def test_sigterm_removes_temporary_rules(self):
        if not shutil.which('iptables-save'):
            self.skipTest('Router integration requires iptables and active NFQUEUE rules')
        snapshot = subprocess.run(['iptables-save', '-t', 'mangle'], capture_output=True)
        if snapshot.returncode or b'-j NFQUEUE' not in snapshot.stdout:
            self.skipTest('No active router NFQUEUE interception to bypass')
        child = subprocess.Popen([sys.executable, '-c', code, '1.1.1.1', '--ports', '22', '--hops', '15', '--no-external', '--json'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            tag = 'xmenu-server-' + str(child.pid) + '-'
            deadline = time.monotonic() + 8
            found = False
            while child.poll() is None and time.monotonic() < deadline:
                rules = subprocess.run(['iptables-save', '-t', 'mangle'], stdout=subprocess.PIPE, check=True).stdout.decode()
                if tag in rules:
                    found = True
                    break
                time.sleep(.1)
            self.assertTrue(found, 'Child did not create a temporary flow rule before deadline')
            child.send_signal(signal.SIGTERM)
            child.wait(timeout=12)
            rules = subprocess.run(['iptables-save', '-t', 'mangle'], stdout=subprocess.PIPE, check=True).stdout.decode()
            self.assertNotIn('xmenu-server-' + str(child.pid) + '-', rules)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()


class PresentationTests(unittest.TestCase):
    def test_udp_reply_alone_confirms_ip_reachability(self):
        report = sample_report()
        report['udp'] = {443: {'status': 'QUIC VN', 'reachable': True}}
        self.assertIn('UDP', engine.verdict(report)[0])
        self.assertIn('IP доступен', engine.verdict(report)[0])

    def test_ssh_tcp_without_banner_confirms_reachability(self):
        report = sample_report()
        report['ssh'] = {'status': 'TIMEOUT', 'tcp_open': True}
        self.assertIn('доступен', engine.verdict(report)[0])

    def test_default_ports_cover_requested_discovery(self):
        self.assertEqual(engine.DEFAULT_PORTS, [22, 80, 443, 8080, 8443, 2053, 2083, 2087, 2096, 2098, 31618])

    def test_trace_cells_explain_missing_hops(self):
        self.assertEqual(engine.trace_cell({'reached': False, 'status': 'PROHIBITED', 'hops': []}, 0), '')
        self.assertEqual(engine.trace_cell({'reached': True, 'status': 'ECHO REPLY', 'hops': []}, 0), '')
        self.assertEqual(engine.trace_cell({'reached': False, 'status': '*', 'hops': [{'ip': '', 'status': '*'}]}, 0), 'Нет ответа')

    def test_trace_colors_and_summary(self):
        value = {'reached': True, 'status': 'ECHO REPLY', 'hops': [{'ip': '1.1.1.1', 'status': 'ECHO REPLY', 'reached': True}]}
        self.assertEqual(engine.trace_color(value, 0), '32;1')
        self.assertIn('VPS ответил', engine.trace_summary(value)[0])
        value = {'reached': False, 'status': 'PROHIBITED', 'hops': [{'ip': '1.1.1.1', 'status': 'PROHIBITED', 'reached': False}]}
        self.assertEqual(engine.trace_color(value, 0), '31;1')
        self.assertIn('запретил', engine.trace_summary(value)[0])

    def test_table_supports_different_cell_colors(self):
        with mock.patch.object(engine, 'COLOR', True), contextlib.redirect_stdout(io.StringIO()) as output:
            engine.table(['Хоп', 'ICMP', 'UDP'], [(['1', 'Ответ', 'Запрет'], ['36;1', '32;1', '31;1'])], [3, 10, 10])
        self.assertIn('\x1b[32;1m', output.getvalue())
        self.assertIn('\x1b[31;1m', output.getvalue())

    def test_asn_confirmed_with_holder(self):
        with mock.patch.object(engine, 'fetch_json', side_effect=[{'data': {'prefix': '1.1.1.0/24'}}, {'data': {'announced': True, 'asns': [{'asn': 13335, 'holder': 'CLOUDFLARE'}]}}]):
            result = engine.bgp('1.1.1.1')
        self.assertEqual(result['status'], 'ANNOUNCED')
        self.assertIn('AS13335', result['detail'])
        self.assertIn('CLOUDFLARE', result['detail'])

    def test_missing_asn_not_confirmed(self):
        with mock.patch.object(engine, 'fetch_json', side_effect=[{'data': {'prefix': '1.1.1.0/24'}}, {'data': {'announced': True, 'asns': []}}]):
            result = engine.bgp('1.1.1.1')
        self.assertEqual(result['status'], 'NO DATA')
        self.assertIn('ASN не подтвержден', result['detail'])

    def test_private_ip_asn_not_confirmed(self):
        with mock.patch.object(engine, 'fetch_json') as fetch:
            self.assertIn('ASN не подтвержден', engine.bgp('192.168.1.1')['detail'])
            fetch.assert_not_called()


class LocalNetworkTests(unittest.TestCase):
    def start_server(self, cls, handler):
        srv = cls(('127.0.0.1', 0), handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        return srv.server_address[1]

    def test_tcp_open(self):
        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                pass
        port = self.start_server(socketserver.TCPServer, Handler)
        self.assertEqual(engine.tcp('127.0.0.1', port)['status'], 'OPEN')

    def test_ssh_banner(self):
        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.sendall(b'SSH-2.0-TestServer\r\n')
        port = self.start_server(socketserver.TCPServer, Handler)
        self.assertEqual(engine.ssh_banner('127.0.0.1', port)['status'], 'SSH')

    def test_udp_reply(self):
        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                data, sock = self.request
                sock.sendto(b'OK', self.client_address)
        port = self.start_server(socketserver.UDPServer, Handler)
        self.assertEqual(engine.udp('127.0.0.1', port)['status'], 'REPLY')

    def test_quic_version_negotiation_on_udp(self):
        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                data, sock = self.request
                self.server.packet_size = len(data)
                dcid = data[6:14]
                scid = data[15:23]
                reply = b'\x80\0\0\0\0\x08' + scid + b'\x08' + dcid + struct.pack('!I', 1)
                sock.sendto(reply, self.client_address)
        port = self.start_server(socketserver.UDPServer, Handler)
        result = engine.udp('127.0.0.1', port, 1, quic=True)
        self.assertEqual(result['status'], 'QUIC VN')
        self.assertTrue(result['reachable'])
        self.assertEqual(result['versions'], [1])

    def test_quic_rejects_unrelated_or_invalid_versions(self):
        packet, dcid, scid, version = engine.quic_probe_packet()
        self.assertEqual(len(packet), 1200)
        header = b'\x80\0\0\0\0\x08' + scid + b'\x08' + dcid
        self.assertEqual(engine.quic_versions(header + struct.pack('!I', 1), dcid, scid, version), [1])
        for reply in (header + b'\0', header + struct.pack('!I', 0), header + struct.pack('!I', version), header[:6] + b'wrongCID' + header[14:] + struct.pack('!I', 1)):
            self.assertIsNone(engine.quic_versions(reply, dcid, scid, version))

    def test_ssh_without_banner_preserves_open_tcp_port(self):
        sock = mock.MagicMock()
        sock.__enter__.return_value = sock
        sock.recv.side_effect = TimeoutError()
        with mock.patch.object(engine, 'connect', return_value=(sock, 5, None)):
            result = engine.ssh_banner('127.0.0.1')
        self.assertTrue(result['tcp_open'])
        self.assertEqual(result['status'], 'TIMEOUT')

    def test_http_404_confirms_reachability(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_HEAD(self):
                self.send_response(404)
                self.end_headers()

            def log_message(self, *args):
                pass
        port = self.start_server(http.server.HTTPServer, Handler)
        result = engine.http_probe('127.0.0.1', port)
        self.assertEqual(result['status'], 'HTTP 404')
        self.assertTrue(result['reachable'])

    def test_tls_certificate_error_is_not_ip_block(self):
        cert = os.environ.get('XMENU_TEST_CERT')
        key = os.environ.get('XMENU_TEST_KEY')
        if not cert or not key:
            self.skipTest('Provide TLS fixture paths')
        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                pass
        server = socketserver.TCPServer(('127.0.0.1', 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            result = engine.http_probe('127.0.0.1', server.server_address[1], True)
            self.assertEqual(result['status'], 'TLS CERT')
            self.assertTrue(result['reachable'])
        finally:
            server.shutdown()
            server.server_close()

    def test_echo_ipv4_and_ipv6(self):
        for ip in ('127.0.0.1', '::1'):
            self.assertEqual(engine.echo(ip, count=1)['received'], 1)

    def test_all_traces_ipv4_ipv6(self):
        for ip in ('127.0.0.1', '::1'):
            for mode in ('ICMP', 'UDP', 'TCP'):
                with self.subTest(ip=ip, mode=mode):
                    value = engine.trace(ip, mode, 2, 9, 1)
                    self.assertTrue(value['reached'], value)

    def test_big_df_echo(self):
        self.assertEqual(engine.echo('127.0.0.1', 1472, 1, True)['received'], 1)


class DisplayTests(unittest.TestCase):
    def test_table_alignment(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            engine.table(['Проверка', 'Результат', 'Подробности'], [(['TCP 443', 'TIMEOUT', 'Длинный текст ' * 8], '31')], [19, 15, 36])
        lines = re.sub(r'\x1b\[[0-9;]*m', '', output.getvalue()).splitlines()
        self.assertEqual({engine.width(line) for line in lines}, {80})

    def test_untrusted_banner_cannot_inject_ansi(self):
        self.assertNotIn('\x1b', engine.clean('\x1b[31mevil\r\n'))


class AdvancedTests(unittest.TestCase):
    def setUp(self):
        engine.CANCEL.clear()
        engine.END_TIME = float('inf')
        engine.WAN_INTERFACE = ''

    def test_public_target_rejects_special_ranges_and_injection(self):
        for value in ('127.0.0.1', '0.0.0.0', '169.254.1.1', '224.0.0.1', '255.255.255.255', '10.1.2.3', '172.16.0.1', '192.168.1.1', '100.64.1.1', '192.0.2.1', '198.51.100.1', '203.0.113.1', '198.18.0.1', '240.0.0.1', '192.0.0.9', '192.88.99.1', '1.2.3.4;id', '1.2.3', '::1', 'fe80::1', 'ff02::1'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                engine.public_target(value)
        self.assertEqual(engine.public_target('::ffff:1.1.1.1'), '1.1.1.1')

    def test_no_reply_never_means_confirmed_ip_ban(self):
        for status in ('TIMEOUT', 'REFUSED', 'RESET', 'PROHIBITED', 'SKIPPED', 'ERROR'):
            report = sample_report()
            report['tcp'][443]['status'] = status
            result = engine.classify(report)
            self.assertNotIn(result['state'], ('BLOCKED', 'IP_BANNED', 'DPI_CONFIRMED'))
            self.assertIn(result['confidence'], ('Low', 'Medium', 'High'))

    def test_ping_only_confirms_reachability(self):
        report = sample_report()
        report['ping']['received'] = 3
        self.assertEqual(engine.classify(report)['state'], 'REACHABLE')

    def test_local_controls_down_prevents_path_block_verdict(self):
        report = sample_report()
        report['controls']['8.8.8.8']['status'] = 'TIMEOUT'
        report['external'] = [{'kind': 'tcp', 'port': 443, 'status': 'OPEN'}]
        self.assertEqual(engine.classify(report)['state'], 'LOCAL_NETWORK_PROBLEM')

    def test_external_same_port_independent_nodes_and_local_retry(self):
        report = sample_report()
        report['tcp'][443]['attempts'] = [{'status': 'TIMEOUT'}, {'status': 'TIMEOUT'}]
        report['controls']['1.1.1.1'] = {'status': 'OPEN'}
        report['external'] = [{'kind': 'tcp', 'port': 443, 'status': 'OPEN', 'country': 'DE', 'asn': 'AS1'}, {'kind': 'tcp', 'port': 443, 'status': 'OPEN', 'country': 'US', 'asn': 'AS2'}]
        self.assertEqual(engine.classify(report)['state'], 'LIKELY_PATH_SPECIFIC_FILTERING')
        report['external'][1]['asn'] = 'AS1'
        self.assertEqual(engine.classify(report)['state'], 'POSSIBLE_BLOCK')

    def test_unchecked_port_is_not_a_local_failure(self):
        report = sample_report()
        report['external'] = [{'kind': 'tcp', 'port': 8443, 'status': 'OPEN'}]
        self.assertEqual(engine.classify(report)['state'], 'INCONCLUSIVE')
        report['tcp'][8443] = {'status': 'SKIPPED'}
        self.assertEqual(engine.classify(report)['state'], 'INCONCLUSIVE')

    def test_refused_local_same_port_is_not_path_filtering(self):
        report = sample_report()
        report['tcp'][443]['status'] = 'REFUSED'
        report['external'] = [{'kind': 'tcp', 'port': 443, 'status': 'OPEN'}]
        self.assertEqual(engine.classify(report)['suspected_cause'], 'CLOSED_OR_REJECTED')

    def test_tls_failure_and_udp_silence_do_not_override_open_tcp(self):
        report = sample_report()
        report['tcp'][443]['status'] = 'OPEN'
        report['tls'] = {443: {'1.2': {'status': 'PROTOCOL_FAILURE'}, '1.3': {'status': 'PROTOCOL_FAILURE'}}}
        report['udp'] = {443: {'status': 'NO REPLY', 'port_state': 'OPEN_FILTERED'}}
        result = engine.classify(report)
        self.assertEqual(result['state'], 'REACHABLE')
        self.assertEqual(result['suspected_cause'], 'PROTOCOL_FAILURE')

    def test_proxy_only_success_is_not_direct_reachability(self):
        report = sample_report()
        report['tcp'][443]['status'] = 'OPEN'
        report['path']['direct_ready'] = False
        result = engine.classify(report)
        self.assertEqual(result['reachability'], 'UNKNOWN')
        self.assertEqual(result['suspected_cause'], 'DIRECT_PATH_UNVERIFIED')

    def test_probe_errors_are_not_port_filtering(self):
        report = sample_report()
        report['tcp'][443]['status'] = 'NO PERMISSION'
        self.assertEqual(engine.classify(report)['state'], 'CHECK_ERROR')

    def test_missing_bgp_route_is_not_claimed_as_provider_ban(self):
        report = sample_report()
        report['bgp'] = {'status': 'NOT ANNOUNCED'}
        result = engine.classify(report)
        self.assertEqual(result['state'], 'INCONCLUSIVE')
        self.assertEqual(result['suspected_cause'], 'BGP_ROUTE_NOT_ANNOUNCED')

    def test_remote_parser_rejects_malformed_wrong_target_and_nonfinite(self):
        for value in ([{'time': True, 'address': '1.1.1.1'}], [{'time': float('nan'), 'address': '1.1.1.1'}], [{'time': -1, 'address': '1.1.1.1'}], [{'time': .1, 'address': '8.8.8.8'}], {'time': .1}, [[]]):
            self.assertNotEqual(engine.remote_value(value, 'tcp', '1.1.1.1')[0], 'OPEN')
        self.assertEqual(engine.remote_value(None, 'tcp')[0], 'PENDING')

    def test_independent_nodes_filter_duplicates_and_untrusted_ids(self):
        data = {'nodes': {'de1.node.check-host.net': {'asn': 'AS1', 'location': ['de', 'Germany', 'A']}, 'de2.node.check-host.net': {'asn': 'AS2', 'location': ['de', 'Germany', 'B']}, 'us1.node.check-host.net': {'asn': 'AS3', 'location': ['us', 'USA', 'C']}, '../../evil': {'asn': 'AS4', 'location': ['fr', 'France', 'D']}}}
        self.assertEqual(engine.independent_nodes(data), ['de1.node.check-host.net', 'us1.node.check-host.net'])

    def test_external_api_error_is_technical_not_target_failure(self):
        with mock.patch.object(engine, 'fetch_json', side_effect=ValueError('API invalid')), mock.patch.object(engine, 'globalping', return_value=[]):
            rows = engine.external('1.1.1.1', [443])
        self.assertTrue(rows)
        self.assertTrue(all(r['status'] == 'API ERROR' for r in rows))

    def test_globalping_tcp_success_is_open(self):
        requested = []
        def fetch(url, *args, **kwargs):
            if 'payload' in kwargs:
                options = kwargs['payload']['measurementOptions']
                requested.append(options.get('port'))
                return {'id': 'p' + str(options.get('port', 'icmp'))}
            return {'status': 'finished', 'results': [{'probe': {'country': 'DE', 'asn': 123}, 'result': {'status': 'finished', 'resolvedAddress': '1.1.1.1', 'stats': {'rcv': 3, 'avg': 5}}}]}
        with mock.patch.object(engine, 'fetch_json', side_effect=fetch):
            rows = engine.globalping('1.1.1.1', [443])
        self.assertEqual([v['status'] for v in rows if v['kind'] == 'tcp'], ['OPEN', 'OPEN'])
        self.assertEqual(requested, [None, 443, 22])

    def test_tcp_retry_recovers_and_records_instability(self):
        with mock.patch.object(engine, 'tcp', side_effect=[{'status': 'TIMEOUT', 'ms': None, 'port': 443}, {'status': 'OPEN', 'ms': 10, 'port': 443}]):
            result = engine.tcp_discovery('1.1.1.1', 443)
        self.assertEqual(result['port_state'], 'OPEN')
        self.assertTrue(result['unstable'])
        self.assertEqual(len(result['attempts']), 2)

    def test_udp_no_protocol_does_not_send_generic_data(self):
        with mock.patch.object(engine.socket, 'socket') as sock:
            for port in (500, 4500, 51820):
                self.assertEqual(engine.udp_service('1.1.1.1', port)['status'], 'INCONCLUSIVE')
            sock.assert_not_called()

    def test_deadline_prevents_new_connections(self):
        engine.END_TIME = time.monotonic() - 1
        with self.assertRaises(OSError):
            engine.remaining(1)
        engine.END_TIME = float('inf')

    def test_stage_contains_memory_and_partial_failures(self):
        report = {'errors': [], 'stages': [], 'tcp': {}}
        def failure():
            raise MemoryError('limited memory')
        engine.run_stage(report, 'test', [(('tcp', 1), failure, ()), (('tcp', 2), lambda: {'status': 'OPEN'}, ())], True)
        self.assertEqual(report['tcp'][1]['status'], 'ERROR')
        self.assertEqual(report['tcp'][2]['status'], 'OPEN')
        self.assertTrue(report['errors'])

    def test_cancelled_stage_does_not_start_work(self):
        report = {'errors': [], 'stages': [], 'tcp': {}}
        engine.CANCEL.set()
        task = mock.Mock()
        engine.run_stage(report, 'test', [(('tcp', 1), task, ())], True)
        task.assert_not_called()

    def test_unreadable_firewall_is_not_assumed_direct(self):
        process = mock.Mock(returncode=1, stdout=b'')
        with mock.patch.object(engine.subprocess, 'run', return_value=process), mock.patch.object(engine.shutil, 'which', return_value=None):
            result = engine.detect_path()
        self.assertFalse(result['direct_ready'])

    def test_unrelated_nfqueue_mark_does_not_bypass_other_proxy(self):
        text = b'*mangle\n-A OUTPUT -j other\n-A other -j REDIRECT\n-A unrelated -m mark --mark 0x40000000/0x40000000 -j RETURN\nCOMMIT\n'
        process = mock.Mock(returncode=0, stdout=text)
        with mock.patch.object(engine.subprocess, 'run', return_value=process), mock.patch.object(engine.shutil, 'which', return_value=None):
            result = engine.detect_path()
        self.assertFalse(result['direct_ready'])

    def test_marked_route_command_includes_mark_and_source(self):
        process = mock.Mock(returncode=0, stdout=b'1.1.1.1 via 10.0.0.1 dev eth3 src 10.0.0.2', stderr=b'')
        with mock.patch.object(engine, 'BYPASS_MARK', 0x40000000), mock.patch.object(engine.subprocess, 'run', return_value=process) as run:
            result = engine.route('1.1.1.1', '10.0.0.2')
        self.assertIn('mark', run.call_args.args[0])
        self.assertIn('from', run.call_args.args[0])
        self.assertEqual(result['interface'], 'eth3')

    def test_tcp_recheck_preserves_initial_timeouts(self):
        previous = {'attempts': [{'status': 'TIMEOUT'}, {'status': 'TIMEOUT'}]}
        with mock.patch.object(engine, 'tcp', return_value={'status': 'OPEN', 'port': 443, 'ms': 2}):
            result = engine.tcp_recheck('1.1.1.1', 443, previous)
        self.assertEqual(len(result['attempts']), 3)
        self.assertTrue(result['unstable'])
        self.assertTrue(result['external_recheck'])

    def test_tls_protocol_failure_is_rechecked(self):
        with mock.patch.object(engine, 'tls_probe', side_effect=[{'status': 'PROTOCOL_FAILURE'}, {'status': 'TLS OK'}]):
            result = engine.tls_confirm('1.1.1.1', 443, ssl.TLSVersion.TLSv1_2)
        self.assertEqual(result['status'], 'TLS OK')
        self.assertTrue(result['unstable'])

    def test_rst_only_traceroute_does_not_prove_open_service(self):
        report = sample_report()
        report['traces'] = {'TCP': {'status': 'RST', 'reached': True}}
        self.assertEqual(engine.classify(report)['state'], 'INCONCLUSIVE')

    def test_synack_without_connect_is_reachability_evidence(self):
        report = sample_report()
        report['syn'] = {443: {'status': 'SYN/ACK'}}
        self.assertEqual(engine.classify(report)['state'], 'REACHABLE')

    def test_bind_permission_error_is_not_network_prohibited(self):
        sock = mock.Mock()
        sock.setsockopt.side_effect = PermissionError(errno.EPERM, 'no mark')
        with mock.patch.object(engine, 'BYPASS_MARK', 123):
            with self.assertRaises(OSError) as error:
                engine.prepare_socket(sock)
        self.assertEqual(engine.network_error(error.exception), 'BYPASS FAIL')

    def test_nft_redirect_prevents_direct_assertion(self):
        def run(command, **kwargs):
            return mock.Mock(returncode=0, stdout=b'table ip nat { redirect to :1234 }' if command[0] == 'nft' else b'')
        with mock.patch.object(engine.subprocess, 'run', side_effect=run), mock.patch.object(engine.shutil, 'which', return_value='/opt/sbin/nft'):
            result = engine.detect_path('1.1.1.1')
        self.assertFalse(result['direct_ready'])

    def test_tunnel_route_is_not_reported_as_direct(self):
        path = {'direct_ready': True, 'risks': []}
        values = [mock.Mock(returncode=0, stdout=b'0: from all lookup main'), mock.Mock(returncode=0, stdout=b'default dev tun0'), mock.Mock(returncode=0, stdout=b'1: tun0: link/none tun type tun')]
        with mock.patch.object(engine, 'route', return_value={'status': 'OK', 'ok': True, 'interface': 'tun0', 'source': '10.0.0.2'}), mock.patch.object(engine.subprocess, 'run', side_effect=values):
            engine.inspect_route('1.1.1.1', path)
        self.assertFalse(path['direct_ready'])
        self.assertEqual(path['status'], 'DIRECT_PATH_UNVERIFIED')

    def test_external_pending_then_same_target_success(self):
        nodes = {'de1.node.check-host.net': ['de', 'Germany', 'Berlin', '1.2.3.4', 'AS1']}
        counts = {'poll': 0}
        def fetch(url, *args, **kwargs):
            if '/nodes/hosts' in url:
                return {'nodes': {}}
            if '/check-ping?' in url:
                return {'ok': 1, 'request_id': 'ping1', 'nodes': nodes}
            if '/check-tcp?' in url:
                return {'ok': 1, 'request_id': 'tcp1', 'nodes': nodes}
            if url.endswith('ping1'):
                return {'de1.node.check-host.net': [[['OK', .01, '1.1.1.1']]]}
            counts['poll'] += 1
            return {'de1.node.check-host.net': None if counts['poll'] == 1 else [{'time': .02, 'address': '1.1.1.1'}]}
        with mock.patch.object(engine, 'fetch_json', side_effect=fetch), mock.patch.object(engine.CANCEL, 'wait', return_value=False):
            rows = engine.external('1.1.1.1', [443])
        self.assertEqual([r['status'] for r in rows], ['REPLY', 'OPEN', 'OPEN'])
        self.assertEqual(rows[1]['asn'], 'AS1')
        self.assertEqual(counts['poll'], 3)

    def test_globalping_polls_all_jobs_before_waiting_again(self):
        polls = []
        def fetch(url, *args, **kwargs):
            if 'payload' in kwargs:
                return {'id': 'p' + str(kwargs['payload']['measurementOptions'].get('port', 'icmp'))}
            ident = url.rsplit('/', 1)[1]
            polls.append(ident)
            if ident == 'picmp' and polls.count(ident) == 1:
                return {'status': 'in-progress', 'results': []}
            return {'status': 'finished', 'results': [{'probe': {'country': 'DE', 'asn': 123}, 'result': {'status': 'finished', 'resolvedAddress': '1.1.1.1', 'stats': {'rcv': 3, 'avg': 5}}}]}
        with mock.patch.object(engine, 'fetch_json', side_effect=fetch), mock.patch.object(engine.CANCEL, 'wait', return_value=False):
            rows = engine.globalping('1.1.1.1', [8080, 8443])
        self.assertEqual(polls[:3], ['picmp', 'p443', 'p22'])
        self.assertEqual({r['port'] for r in rows if r['kind'] == 'tcp'}, {443, 22, 8080})

    def test_globalping_wrong_resolved_target_is_not_success(self):
        def fetch(url, *args, **kwargs):
            if 'payload' in kwargs:
                return {'id': 'p' + str(kwargs['payload']['measurementOptions'].get('port', 'icmp'))}
            return {'status': 'finished', 'results': [{'probe': {}, 'result': {'status': 'finished', 'resolvedAddress': '8.8.8.8', 'stats': {'rcv': 3, 'avg': 5}}}]}
        with mock.patch.object(engine, 'fetch_json', side_effect=fetch):
            rows = engine.globalping('1.1.1.1', [443, 22])
        self.assertTrue(all(r['status'] == 'API ERROR' for r in rows))

    def test_compact_table_never_wraps_or_exceeds_width(self):
        rows = [(['Контроль сети', 'Нет ответа', 'Длинное описание ' * 20], ['36', '31', '37'])]
        with contextlib.redirect_stdout(io.StringIO()) as output:
            engine.table(['Проверка', 'Результат', 'Подробности'], rows, [17, 16, 31], compact=True)
        lines = output.getvalue().splitlines()
        self.assertEqual(len(lines), 5)
        self.assertEqual({engine.width(line) for line in lines}, {74})
        self.assertIn('…', lines[3])

    def test_default_always_checks_external_443_22_even_when_tcp_open(self):
        selected = []
        def stage(report, title, jobs, quiet=False):
            for (key, index), function, args in jobs:
                if key in ('tcp', 'controls'):
                    report[key][index] = {'status': 'OPEN', 'ms': 1}
                elif key == 'external':
                    selected.append(tuple(args[1]))
        path = {'mark': 0, 'direct_ready': True, 'risks': [], 'interface': 'eth3', 'source': '10.0.0.1'}
        with mock.patch.object(sys, 'argv', ['engine', '1.1.1.1', '--json', '--ports', '8080']), mock.patch.dict(os.environ, {'XMENU_SERVER_EXTERNAL': '0'}), mock.patch.object(engine, 'detect_path', return_value=path), mock.patch.object(engine, 'inspect_route', return_value={'status': 'OK', 'ok': True}), mock.patch.object(engine, 'run_stage', side_effect=stage), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(engine.main(), 0)
        report = json.loads(output.getvalue())
        self.assertEqual(selected, [(443, 22)])
        self.assertTrue(report['settings']['external_allowed'])
        self.assertTrue({'443', '22'}.issubset(report['tcp']))

    def test_main_summary_and_asn_have_distinct_colors(self):
        report = sample_report()
        report['route'].update(status='OK', detail='eth3', interface='eth3')
        report['tcp'][443].update(status='OPEN', port_state='OPEN', ms=1)
        report.update(ports=[443], udp={}, elapsed=1, bgp={'status': 'ANNOUNCED', 'prefix': '1.1.1.0/24', 'asns': [{'asn': 13335, 'holder': 'CLOUDFLARE'}]})
        report['ping'].update(status='TIMEOUT', sent=3)
        report['analysis'] = engine.classify(report)
        with mock.patch.object(engine, 'COLOR', True), contextlib.redirect_stdout(io.StringIO()) as output:
            engine.render_report(report)
        text = output.getvalue()
        self.assertIn('\x1b[33;1mAS13335', text)
        self.assertIn('\x1b[35;1mCLOUDFLARE', text)
        self.assertIn('\x1b[32;1mVPS доступен', text)

    def test_remote_request_id_is_not_used_as_path(self):
        with mock.patch.object(engine, 'fetch_json', return_value={'ok': 1, 'request_id': '../../etc/passwd', 'nodes': {}}) as fetch, mock.patch.object(engine, 'globalping', return_value=[]):
            rows = engine.external('1.1.1.1', [443])
        self.assertTrue(all('/check-result/' not in c.args[0] for c in fetch.call_args_list))
        self.assertTrue(all(r['status'] == 'API ERROR' for r in rows))

    def test_udp_dns_and_ntp_responses_are_validated(self):
        for port in (53, 123):
            sock = mock.MagicMock()
            sock.__enter__.return_value = sock
            sock.getsockname.return_value = ('127.0.0.1', 45678)
            request = []
            sock.send.side_effect = lambda data: request.append(data)
            def response(*args):
                if port == 53:
                    return request[0][:2] + b'\x81\x80' + request[0][4:]
                return b'\x24\x01' + b'\0' * 22 + request[0][40:48] + b'\0' * 16
            sock.recv.side_effect = response
            with mock.patch.object(engine.socket, 'socket', return_value=sock), mock.patch.object(engine, 'FlowGuard'):
                result = engine.udp_service('1.1.1.1', port)
            self.assertEqual(result['status'], 'REPLY')
            self.assertTrue(result['reachable'])

    def test_no_external_setting_skips_all_api_calls_without_curl_jq(self):
        path = {'mark': 0, 'direct_ready': True, 'risks': [], 'interface': 'eth3', 'source': '10.0.0.1'}
        echo = {'status': 'OK', 'sent': 1, 'received': 1, 'rtts': [1], 'events': []}
        with mock.patch.object(sys, 'argv', ['engine', '1.1.1.1', '--no-external', '--json', '--hops', '1']), mock.patch.object(engine, 'detect_path', return_value=path), mock.patch.object(engine, 'inspect_route', return_value={'status': 'OK', 'ok': True}), mock.patch.object(engine, 'tcp', return_value={'status': 'OPEN', 'port': 443, 'ms': 1}), mock.patch.object(engine, 'echo', return_value=echo), mock.patch.object(engine, 'udp_service', return_value={'status': 'NO REPLY', 'ms': None}), mock.patch.object(engine, 'trace', return_value={'status': 'NO REPLY', 'hops': [], 'reached': False}), mock.patch.object(engine, 'http_probe', return_value={'status': 'TLS CERT', 'reachable': True}), mock.patch.object(engine, 'tls_confirm', return_value={'status': 'TLS OK'}), mock.patch.object(engine, 'ssh_banner', return_value={'status': 'SSH', 'tcp_open': True}), mock.patch.object(engine, 'fetch_json') as fetch, mock.patch.object(engine.shutil, 'which', return_value=None), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(engine.main(), 0)
        fetch.assert_not_called()
        report = json.loads(output.getvalue())
        self.assertFalse(report['settings']['external_allowed'])
        self.assertEqual(report['tcp']['2053']['status'], 'SKIPPED')
        self.assertFalse(report['dependencies']['curl'])
        self.assertFalse(report['dependencies']['jq'])

    def test_tls_without_sni_can_handshake_self_signed_certificate(self):
        cert, key = os.environ.get('XMENU_TEST_CERT'), os.environ.get('XMENU_TEST_KEY')
        if not cert or not key:
            self.skipTest('TLS fixture paths unavailable')
        seen = []
        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                pass
        server = socketserver.TCPServer(('127.0.0.1', 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        context.set_servername_callback(lambda sock, name, ctx: seen.append(name))
        server.socket = context.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            result = engine.tls_probe('127.0.0.1', server.server_address[1], ssl.TLSVersion.TLSv1_2)
            self.assertEqual(result['status'], 'TLS OK')
            self.assertEqual(seen, [None])
        finally:
            server.shutdown()
            server.server_close()

    def test_goto_cannot_hide_output_redirect(self):
        for flag in ('-g', '--goto'):
            text = ('*nat\n-A OUTPUT ' + flag + ' HIDDEN\n-A HIDDEN -j REDIRECT --to-ports 1234\nCOMMIT\n').encode()
            with mock.patch.object(engine.subprocess, 'run', return_value=mock.Mock(returncode=0, stdout=text)), mock.patch.object(engine.shutil, 'which', return_value=None):
                result = engine.detect_path('1.1.1.1')
            self.assertFalse(result['direct_ready'])

    def test_unknown_incoming_nfqueue_is_not_silently_direct(self):
        text = b'*mangle\n-A PREROUTING -j SOME_FILTER\n-A SOME_FILTER -j NFQUEUE --queue-num 99\nCOMMIT\n'
        with mock.patch.object(engine.subprocess, 'run', return_value=mock.Mock(returncode=0, stdout=text)), mock.patch.object(engine.shutil, 'which', return_value=None):
            result = engine.detect_path('1.1.1.1')
        self.assertFalse(result['direct_ready'])

    def test_stale_rule_failed_cleanup_is_tracked(self):
        text = b'*mangle\n-A nfqws_pre -s 1.1.1.1 -p tcp --sport 443 --dport 45678 -m comment --comment xmenu-server-999999999-0123456789 -j RETURN\nCOMMIT\n'
        try:
            with mock.patch.object(engine.subprocess, 'run', return_value=mock.Mock(returncode=0, stdout=text)), mock.patch.object(engine.shutil, 'which', return_value=None), mock.patch.object(engine, 'firewall', return_value=False):
                engine.detect_path('1.1.1.1')
            self.assertTrue(engine.FLOW_RULES)
        finally:
            engine.FLOW_RULES.clear()

    def test_tls_deadline_after_connect_is_not_protocol_failure(self):
        sock = mock.MagicMock()
        def budget(*args):
            engine.CANCEL.set()
            raise OSError(errno.ECANCELED, 'deadline')
        with mock.patch.object(engine, 'connect', return_value=(sock, 1, None)), mock.patch.object(engine, 'remaining', side_effect=[1, OSError(errno.ECANCELED, 'deadline')]):
            result = engine.tls_probe('1.1.1.1', 443, ssl.TLSVersion.TLSv1_2)
        self.assertEqual(result['status'], 'CANCELLED')

    def test_slow_flow_setup_does_not_start_late_connect(self):
        sock = mock.MagicMock()
        def setup(*args):
            time.sleep(.02)
            return mock.Mock()
        with mock.patch.object(engine.socket, 'socket', return_value=sock), mock.patch.object(engine, 'FlowGuard', side_effect=setup):
            with self.assertRaises(OSError):
                engine.connect('1.1.1.1', 443, .01)
        sock.connect.assert_not_called()


if __name__ == '__main__':
    unittest.main()
