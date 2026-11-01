import contextlib
import http.server
import io
import os
import re
from pathlib import Path
import socket
import socketserver
import ssl
import struct
import sys
import threading
import types
import unittest
from unittest import mock


source = Path(sys.argv.pop(1)).read_text(encoding='utf-8') if len(sys.argv) > 1 else (Path(__file__).resolve().parents[1] / 'xmenu-v1.0.sh').read_text(encoding='utf-8')
code = source.split("<<'XMENU_DNS_ENGINE'\n", 1)[1].split('\nXMENU_DNS_ENGINE', 1)[0]
engine = types.ModuleType('xmenu_dns_engine')
sys.modules[engine.__name__] = engine
exec(compile(code, '<xmenu DNS engine>', 'exec'), engine.__dict__)


def answer(packet, ip='93.184.216.34', flags=0x8180):
    ident = struct.unpack('!H', packet[:2])[0]
    record = b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 60, 4) + socket.inet_aton(ip)
    return struct.pack('!6H', ident, flags, 1, 1 if flags & 15 == 0 else 0, 0, 0) + packet[12:] + (record if flags & 15 == 0 else b'')


class InputTests(unittest.TestCase):
    def test_invalid_utf8_retries_without_losing_next_line(self):
        with contextlib.redirect_stdout(io.StringIO()):
            result = engine.read_value('IP: ', io.BytesIO(b'\xd1\n1.1.1.1\n'))
        self.assertEqual(result, '1.1.1.1')

    def test_custom_dns_menu_accepts_ipv4(self):
        stream = io.BytesIO(b'4\n1.1.1.1\n\n\n\n\n\n\n')
        with mock.patch('builtins.open', return_value=stream), contextlib.redirect_stdout(io.StringIO()):
            chosen, domains = engine.interactive()
        self.assertEqual(chosen[0].ip, '1.1.1.1')
        self.assertTrue(domains)

    def test_custom_dns_menu_accepts_ipv6(self):
        stream = io.BytesIO(b'4\n2606:4700:4700::1111\n\n\n\n\n\n')
        with mock.patch('builtins.open', return_value=stream), contextlib.redirect_stdout(io.StringIO()):
            chosen, domains = engine.interactive()
        self.assertEqual(chosen[0].ip, '2606:4700:4700::1111')


class PacketTests(unittest.TestCase):
    def setUp(self):
        self.q = engine.query('example.com')

    def test_good(self):
        self.assertEqual(engine.parse(answer(self.q), self.q)['ips'], ['93.184.216.34'])

    def test_nxdomain(self):
        r = engine.parse(answer(self.q, flags=0x8183), self.q)
        self.assertEqual(r['rcode'], 3)
        self.assertFalse(r['ips'])

    def test_wrong_id(self):
        data = bytearray(answer(self.q)); data[0] ^= 1
        with self.assertRaises(ValueError):
            engine.parse(bytes(data), self.q)

    def test_wrong_question(self):
        q = self.q[:12] + engine.query('another.com')[12:]
        with self.assertRaises(ValueError):
            engine.parse(answer(q), self.q)

    def test_truncated(self):
        self.assertTrue(engine.parse(answer(self.q, flags=0x8380), self.q)['tc'])
        with self.assertRaises(ValueError):
            engine.parse(answer(self.q)[:-1], self.q)

    def test_compression_loop(self):
        data = answer(self.q)[:12] + b'\xc0\x0c'
        with self.assertRaises(ValueError):
            engine.parse(data, self.q)

    def test_cname(self):
        target = b'\x03cdn\x07example\x03com\0'
        cname = b'\xc0\x0c' + struct.pack('!HHIH', 5, 1, 60, len(target)) + target
        address = target + struct.pack('!HHIH', 1, 1, 60, 4) + socket.inet_aton('1.2.3.4')
        data = self.q[:2] + struct.pack('!5H', 0x8180, 1, 2, 0, 0) + self.q[12:] + cname + address
        self.assertEqual(engine.parse(data, self.q)['ips'], ['1.2.3.4'])

    def test_unrelated_address_not_accepted(self):
        target = b'\x04evil\x03net\0'
        record = target + struct.pack('!HHIH', 1, 1, 60, 4) + socket.inet_aton('1.2.3.4')
        data = self.q[:2] + struct.pack('!5H', 0x8180, 1, 1, 0, 0) + self.q[12:] + record
        self.assertFalse(engine.parse(data, self.q)['ips'])

    def test_txt_wire_answer(self):
        q = engine.query('AS15169.asn.cymru.com', 16)
        txt = b'15169 | US | GOOGLE'
        payload = bytes([len(txt)]) + txt
        record = b'\xc0\x0c' + struct.pack('!HHIH', 16, 1, 60, len(payload)) + payload
        data = q[:2] + struct.pack('!5H', 0x8180, 1, 1, 0, 0) + q[12:] + record
        self.assertEqual(engine.parse(data, q)['txt'], [txt.decode()])

    def test_empty_asn_txt_does_not_crash(self):
        with mock.patch.object(engine, 'probe', return_value={'error': '', 'txt': ['']}):
            self.assertEqual(engine.resolver_org('8.8.8.8', 1, None), '')

    def test_invalid_domains(self):
        for value in ('x;id', 'example.com/path', '-a.com', 'a..com', 'a' * 64 + '.com', '8.8.8.8'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                engine.domain(value)

    def test_custom_ipv6(self):
        s = engine.custom_server('2001:4860:4860::8888', 'dns.google', 'https://dns.google/dns-query')
        self.assertEqual(s.ip, '2001:4860:4860::8888')

    def test_bad_doh_url(self):
        for url in ('http://example.com', 'https://user:pw@example.com/', 'https://example.com/\r\nHost: bad'):
            with self.subTest(url=url), self.assertRaises(ValueError):
                engine.check_doh(url)

    def test_presets(self):
        self.assertGreater(len(engine.SERVERS), 30)
        for server in engine.SERVERS:
            if server.udp:
                engine.custom_server(server.ip, server.dot, server.doh)
            self.assertTrue(server.udp or server.dot or server.doh)


class AssessmentTests(unittest.TestCase):
    def test_no_false_positive_for_different_public_addresses(self):
        control = {'error': '', 'rcode': 0, 'ips': ['1.1.1.1'], 'tc': False}
        data = {'control': control, 'domains': {'example.com': control}, 'invalid': {'ips': [], 'error': '', 'tc': False}}
        judged, difference, signals = engine.assess(data, {'example.com': {'8.8.8.8'}})
        self.assertEqual((judged, difference, signals), (1, 1, []))

    def test_nxdomain_vs_encrypted_answer(self):
        control = {'error': '', 'rcode': 0, 'ips': ['1.1.1.1'], 'tc': False}
        negative = dict(control, ips=[], rcode=3)
        data = {'control': control, 'domains': {'example.com': negative}, 'invalid': None}
        self.assertTrue(engine.assess(data, {'example.com': {'8.8.8.8'}})[2])

    def test_fake_ip(self):
        control = {'error': '', 'rcode': 0, 'ips': ['1.1.1.1'], 'tc': False}
        data = {'control': control, 'domains': {'example.com': dict(control, ips=['198.18.1.1'])}, 'invalid': None}
        self.assertIn('Fake-IP', engine.assess(data, {'example.com': {'8.8.8.8'}})[2][0])

    def test_nonexistent_name_with_address(self):
        data = {'control': {'error': 'TIMEOUT', 'rcode': None, 'ips': [], 'tc': False}, 'domains': {}, 'invalid': {'ips': ['1.2.3.4'], 'error': '', 'tc': False}}
        self.assertTrue(engine.assess(data, {})[2])

    def test_doh_timeout(self):
        server = engine.SERVERS[0]
        with mock.patch.object(engine, 'DohSession', side_effect=engine.ProbeError('TIMEOUT')):
            self.assertEqual(engine.probe(server, 'DoH', 'example.com', 1, None)['error'], 'TIMEOUT')

    def test_certificate_error(self):
        with mock.patch.object(engine, 'DotSession', side_effect=engine.ProbeError('TLS ERR')):
            self.assertEqual(engine.probe(engine.SERVERS[0], 'DoT', 'example.com', 1, None)['error'], 'TLS ERR')

    def test_menu_enter(self):
        with mock.patch('builtins.open', return_value=io.StringIO('\n')), contextlib.redirect_stdout(io.StringIO()):
            self.assertIsNone(engine.interactive())

    def test_menu_select_and_domains(self):
        with mock.patch('builtins.open', return_value=io.StringIO('3\n1 5 7\nexample.com\n')), contextlib.redirect_stdout(io.StringIO()):
            selected, domains = engine.interactive()
            self.assertEqual([s.ip for s in selected], ['8.8.4.4', '1.1.1.1', '9.9.9.9'])
            self.assertEqual(domains, ['example.com'])

    def test_menu_custom(self):
        with mock.patch('builtins.open', return_value=io.StringIO('4\n1.1.1.1\n\ncloudflare-dns.com\n\nhttps://cloudflare-dns.com/dns-query\n\nexample.com\n')), contextlib.redirect_stdout(io.StringIO()):
            selected, domains = engine.interactive()
            self.assertEqual(selected[0].dot, 'cloudflare-dns.com')
            self.assertEqual(selected[0].doh, 'https://cloudflare-dns.com/dns-query')


class DetectorParityTests(unittest.TestCase):
    def good(self, ips=None, ms=5):
        return {'error': '', 'rcode': 0, 'ips': ['1.1.1.1'] if ips is None else ips, 'txt': [], 'tc': False, 'ms': ms, 'ad': False}

    def test_reference_domains_and_all_120_endpoints(self):
        self.assertEqual(engine.DEFAULT_DOMAINS, ['rutor.info', 'flibusta.is', 'clubtone.do.am', 'rezka.ag', 'shikimori.one'])
        self.assertEqual(engine.ALLOWED_DOMAINS, ['vk.ru', 'gosuslugi.ru'])
        self.assertEqual(sum(engine.enabled(s, t) for s in engine.SERVERS for t in ('UDP', 'DoT', 'DoH')), 120)

    def test_custom_and_preset_use_identical_known_ip_parameters(self):
        for preset in engine.SERVERS:
            if not preset.ip:
                continue
            custom = engine.custom_server(preset.ip)
            first = next(s for s in engine.SERVERS if s.ip == preset.ip)
            self.assertEqual((custom.ip, custom.dot, custom.doh, custom.port, custom.dot_port), (first.ip, first.dot, first.doh, first.port, first.dot_port))

    def test_tls_uses_service_address_instead_of_udp_ip(self):
        server = engine.Server('Preset', '1.1.1.1', 'tls.example.com', 'https://tls.example.com/dns-query')
        response = mock.Mock(stdout=b'Name: tls.example.com\nAddress 1: 203.0.113.20\n')
        with mock.patch.dict(engine._bootstrap_cache, {}, clear=True), mock.patch.object(engine.subprocess, 'run', return_value=response):
            for transport in ('DoT', 'DoH'):
                self.assertEqual(engine.tls_target(server, transport, 1, None).ip, '203.0.113.20')
        self.assertEqual(server.ip, '1.1.1.1')

    def test_tls_literal_and_ipv6_endpoints_override_udp_ip(self):
        server = engine.Server('Preset', '1.1.1.1', '2606:4700:4700::1111', 'https://1.0.0.1/dns-query')
        with mock.patch.object(engine.subprocess, 'run', side_effect=AssertionError('Unexpected resolution')):
            self.assertEqual(engine.tls_target(server, 'DoT', 1, None).ip, '2606:4700:4700::1111')
            self.assertEqual(engine.tls_target(server, 'DoH', 1, None).ip, '1.0.0.1')

    def test_fixed_truth_uses_complete_public_panel_independent_of_selection(self):
        response = {'domains': {'test.com': self.good(['8.8.8.8'])}}
        with mock.patch.object(engine, 'scan_transport', return_value=response) as scan:
            truth, count = engine.fixed_truth(['test.com'], 1, None, 'random.invalid')
        self.assertEqual(count, len(engine.reference_panel()))
        self.assertEqual(truth, {'test.com': {'8.8.8.8'}})
        self.assertEqual(len(scan.call_args_list), 71)
        self.assertTrue(all(c.args[0].ip == '' for c in scan.call_args_list))
        self.assertTrue(all(c.args[1] in ('DoH', 'DoT') for c in scan.call_args_list))

    def test_public_panel_collects_more_than_two_providers_answers(self):
        def scan(server, transport, *args):
            ip = '104.21.30.148' if server.name.startswith('AdGuard') else '188.114.96.1'
            return {'domains': {'shikimori.one': self.good([ip])}}
        with mock.patch.object(engine, 'scan_transport', side_effect=scan):
            truth, _ = engine.fixed_truth(['shikimori.one'], 1, None, 'random.invalid')
        result = {'control': self.good(), 'domains': {'shikimori.one': self.good(['104.21.30.148'])}, 'invalid': None}
        self.assertEqual(engine.assess(result, truth)[:2], (1, 0))

    def test_main_spoofing_is_independent_of_selection_and_own_tls_answers(self):
        import copy
        reports = []
        controls = self.good(['8.8.4.4'])
        transport = {'control': controls, 'domains': {'example.com': controls}, 'invalid': None, 'egress': None}
        data = {t: transport for t in ('UDP', 'DoT', 'DoH')}
        for selection in (['--ip', '1.1.1.1'], ['--servers', '5'], ['--servers', '1,5,7']):
            args = ['xmenu'] + selection + ['--domains', 'example.com', '--json']
            with mock.patch.object(sys, 'argv', args), mock.patch.object(engine, 'curl_library'), mock.patch.object(engine, 'fixed_truth', return_value=({'example.com': {'1.1.1.1'}}, 1)), mock.patch.object(engine, 'scan_server', side_effect=lambda *args: copy.deepcopy(data)), contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(engine.main(), 0)
            report = engine.json.loads(output.getvalue())
            item = next(v for v in report['servers'] if v['ip'] == '1.1.1.1')
            self.assertEqual((item['differences'], item['judged']), (1, 1))
            self.assertEqual(report['truth'], {'example.com': ['1.1.1.1']})
            reports.append(report['settings'])
        self.assertEqual(reports[0], reports[1])
        self.assertEqual(reports[1], reports[2])

    def test_custom_defaults_can_explicitly_disable_tls(self):
        server = engine.custom_server('1.1.1.1', '', '')
        self.assertFalse(engine.enabled(server, 'DoT'))
        self.assertFalse(engine.enabled(server, 'DoH'))

    def test_ipv4_mapped_ipv6_uses_same_preset(self):
        mapped = engine.custom_server('::ffff:1.1.1.1')
        plain = engine.custom_server('1.1.1.1')
        self.assertEqual((mapped.ip, mapped.dot, mapped.doh), (plain.ip, plain.dot, plain.doh))

    def test_invalid_dns_ip_and_port_rejected(self):
        for ip in ('0.0.0.0', '::', '224.0.0.1', 'ff02::1', '255.255.255.255'):
            with self.subTest(ip=ip), self.assertRaises(ValueError):
                engine.custom_server(ip)
        with self.assertRaises(ValueError):
            engine.custom_server('1.1.1.1', port=0)

    def test_udp_alive_when_one_trusted_domain_fails(self):
        def probe(server, transport, name, timeout, context):
            return engine.failure('TIMEOUT') if name == 'vk.ru' else self.good()
        with mock.patch.object(engine, 'probe', side_effect=probe):
            data = engine.scan_transport(engine.BOOTSTRAP[0], 'UDP', ['blocked.test'], 1, None, 'random.invalid')
        self.assertIn('blocked.test', data['domains'])
        self.assertFalse(data['control']['error'])
        self.assertEqual(engine.latency_color(data, 'UDP', engine.cell(data)), '33')

    def test_timeout_on_live_udp_counts_in_spoofing(self):
        data = {'control': self.good(), 'domains': {'blocked.test': engine.failure('TIMEOUT')}, 'invalid': None}
        judged, differences, signals = engine.assess(data, {'blocked.test': {'8.8.8.8'}})
        self.assertEqual((judged, differences), (1, 1))
        self.assertTrue(signals)

    def test_truth_unions_dot_and_doh_and_excludes_fakeip(self):
        truth = {}
        result = {0: {'DoH': {'domains': {'test': self.good(['8.8.8.8', '198.18.0.1'])}}, 'DoT': {'domains': {'test': self.good(['1.1.1.1'])}}}}
        self.assertEqual(engine.add_truth(truth, result), 2)
        self.assertEqual(truth['test'], {'8.8.8.8', '1.1.1.1'})

    def test_egress_retry_has_short_first_window(self):
        with mock.patch.object(engine, 'probe', side_effect=[engine.failure('TIMEOUT'), self.good()]) as probe, mock.patch.object(engine.time, 'sleep'):
            self.assertFalse(engine.probe_egress(engine.BOOTSTRAP[0], 10, None)['error'])
        self.assertEqual([c.args[3] for c in probe.call_args_list], [2, 10])

    def test_same_brand_secondary_address_is_not_hijack(self):
        items = [{'name': 'Google', 'egress': '203.0.113.1', 'organization': 'Unknown', 'signals': []}, {'name': 'Google #2', 'egress': '203.0.113.2', 'organization': 'Unknown', 'signals': []}]
        self.assertEqual(engine.detect_hijacks(items), [])
        self.assertFalse(any(i['signals'] for i in items))

    def test_shared_unknown_network_and_exempt_resolver(self):
        items = [{'name': n, 'egress': '203.0.113.' + str(i + 1), 'organization': 'Unknown', 'signals': []} for i, n in enumerate(('Google', 'Quad9', 'MSK-IX'))]
        findings = engine.detect_hijacks(items)
        self.assertEqual({f['name'] for f in findings}, {'Google', 'Quad9'})
        self.assertFalse(any(item['signals'] for item in items))

    def test_local_network_is_not_labeled_fakeip(self):
        self.assertFalse(engine.fake_ip('192.168.1.1'))
        self.assertFalse(engine.fake_ip('100.64.0.1'))
        self.assertTrue(engine.fake_ip('198.19.255.254'))

    def test_doh_warmup_tls_failure_is_not_overwritten_by_skipped(self):
        session = mock.Mock(closed=True)
        session.query.return_value = engine.failure('TLS DROP')
        with mock.patch.object(engine, 'tls_target', return_value=engine.BOOTSTRAP[0]), mock.patch.object(engine, 'DohSession', return_value=session):
            result = engine.scan_transport(engine.BOOTSTRAP[0], 'DoH', ['test.com'], 1, None, 'random.invalid')
        self.assertEqual(engine.cell(result, 'DoH'), 'TLS DROP')
        session.close.assert_called_once()

    def test_dot_nxdomain_warmup_does_not_abort_other_domains(self):
        session = mock.Mock()
        session.query.side_effect = [dict(self.good([]), rcode=3), self.good(), self.good([])]
        with mock.patch.object(engine, 'tls_target', return_value=engine.BOOTSTRAP[0]), mock.patch.object(engine, 'DotSession', return_value=session):
            result = engine.scan_transport(engine.BOOTSTRAP[0], 'DoT', ['test.com'], 1, None, 'random.invalid')
        self.assertEqual(engine.cell(result, 'DoT'), '5.0ms')
        self.assertEqual(session.query.call_count, 3)


class LocalUDPTests(unittest.TestCase):
    def test_unrelated_udp_packet_is_ignored_before_valid_response(self):
        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                packet, sock = self.request
                valid = answer(packet)
                ident = (struct.unpack('!H', valid[:2])[0] + 1) & 65535
                sock.sendto(struct.pack('!H', ident) + valid[2:], self.client_address)
                sock.sendto(valid, self.client_address)
        with socketserver.UDPServer(('127.0.0.1', 0), Handler) as srv:
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            try:
                result = engine.probe(engine.Server('Local', '127.0.0.1', port=srv.server_address[1]), 'UDP', 'example.com', 1, None)
                self.assertFalse(result['error'])
                self.assertEqual(result['ips'], ['93.184.216.34'])
            finally:
                srv.shutdown()

    def test_real_udp(self):
        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                packet, sock = self.request
                sock.sendto(answer(packet), self.client_address)
        with socketserver.UDPServer(('127.0.0.1', 0), Handler) as srv:
            thread = threading.Thread(target=srv.serve_forever, daemon=True)
            thread.start()
            try:
                server = engine.Server('Local', '127.0.0.1', port=srv.server_address[1])
                result = engine.probe(server, 'UDP', 'example.com', 1, None)
                self.assertFalse(result['error'])
                self.assertEqual(result['ips'], ['93.184.216.34'])
            finally:
                srv.shutdown()


class TableTests(unittest.TestCase):
    def sample(self):
        a = {'error': '', 'rcode': 0, 'ips': ['1.1.1.1'], 'tc': False, 'ms': 19.25}
        result = {'control': a, 'domains': {'example.com': a}}
        return {'name': 'Cloudflare', 'ip': '1.1.1.1', 'cells': {'UDP': '19.2ms', 'DoT': '21.3ms', 'DoH': '22.4ms'}, 'results': dict.fromkeys(('UDP', 'DoT', 'DoH'), result), 'egress': '172.70.1.1', 'organization': 'AS13335 · CLOUDFLARENET - Cloudflare, Inc., US', 'judged': 5, 'differences': 0, 'signals': []}

    def test_grid_width_and_six_columns(self):
        for width in (40, 60, 80, 100, 120, 140):
            with self.subTest(width=width), contextlib.redirect_stdout(io.StringIO()) as output:
                engine.render_table([self.sample()], width)
                lines = output.getvalue().splitlines()
                lengths = {engine.text_width(re.sub(r'\x1b\[[0-9;]*m', '', line)) for line in lines}
                self.assertEqual(len(lengths), 1)
                self.assertLessEqual(max(lengths), width)
                for line in lines:
                    if '│' in line:
                        self.assertEqual(line.count('│'), 7)

    def test_no_detached_ip_or_asn_line(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            engine.render_table([self.sample()], 140)
        content = output.getvalue()
        self.assertIn('1.1.1.1→CLOUDFLARENET', content)
        for line in content.splitlines():
            self.assertTrue(line.startswith(('┌', '│', '╞', '└')))

    def test_ansi_does_not_shift_borders(self):
        with mock.patch.object(engine, 'COLOR', True), contextlib.redirect_stdout(io.StringIO()) as output:
            engine.render_table([self.sample()], 100)
        self.assertIn('\x1b[', output.getvalue())
        lines = re.sub(r'\x1b\[[0-9;]*m', '', output.getvalue()).splitlines()
        self.assertEqual(len({engine.text_width(line) for line in lines}), 1)

    def test_long_ipv6_and_provider_name_stay_inside_cells(self):
        item = self.sample()
        item.update(name='Custom 2001:4860:4860::8888', ip='2001:4860:4860::8888', egress='2001:4860:4860::8844', organization='')
        with contextlib.redirect_stdout(io.StringIO()) as output:
            engine.render_table([item], 80)
        self.assertEqual(len({engine.text_width(line) for line in output.getvalue().splitlines()}), 1)

    def test_resolver_column_is_compact_on_wide_terminal(self):
        item = self.sample()
        item['organization'] = 'AS13335 · ' + 'A' * 60
        with contextlib.redirect_stdout(io.StringIO()) as output:
            engine.render_table([item], 200)
        lines = re.sub(r'\x1b\[[0-9;]*m', '', output.getvalue()).splitlines()
        self.assertLessEqual(max(engine.text_width(line) for line in lines), 120)
        for line in lines:
            if line.startswith('│'):
                self.assertLessEqual(engine.text_width(line.split('│')[5]), 34)

    def test_latency_is_minimum_domain_response_for_dot(self):
        sample = self.sample()['results']['DoT']
        sample['domains']['other.com'] = dict(sample['control'], ms=11.12)
        self.assertEqual(engine.cell(sample, 'DoT'), '11.1ms')
        self.assertEqual(engine.cell(sample, 'UDP'), '19.2ms')

    def test_partial_response_is_yellow(self):
        sample = self.sample()['results']['DoH']
        sample['domains']['other.com'] = dict(sample['control'], ips=[], ms=None, error='TIMEOUT')
        value = engine.cell(sample, 'DoH')
        self.assertEqual(engine.latency_color(sample, 'DoH', value), '33')

    def test_partial_timeout_is_in_table(self):
        item = self.sample()
        item['results']['DoH']['domains']['other.com'] = dict(item['results']['DoH']['control'], ips=[], ms=None, error='TIMEOUT')
        with contextlib.redirect_stdout(io.StringIO()) as output:
            engine.render_table([item], 100)
        self.assertIn('TIMEOUT', output.getvalue())
        self.assertIn('Spoofing', output.getvalue())

    def test_partial_nxdomain_is_in_table(self):
        item = self.sample()
        item['results']['DoH']['domains']['other.com'] = dict(item['results']['DoH']['control'], ips=[], ms=None, rcode=3)
        with contextlib.redirect_stdout(io.StringIO()) as output:
            engine.render_table([item], 100)
        self.assertIn('NXDOMAIN', output.getvalue())

    def test_tls_timeout_classification(self):
        self.assertEqual(engine.tls_error(TimeoutError(), 'connect'), 'SYN DROP')
        self.assertEqual(engine.tls_error(TimeoutError(), 'handshake'), 'TLS DROP')
        self.assertEqual(engine.tls_error(TimeoutError(), 'query'), 'TIMEOUT')
        self.assertEqual(engine.tls_error(ConnectionResetError(), 'handshake'), 'TLS RST')
        self.assertEqual(engine.tls_error(ssl.SSLError('TLS alert handshake failure'), 'handshake'), 'TLS ALERT')

    def test_native_doh_distinguishes_timeout_stage(self):
        for tcp, tls, connected, expected in ((0, 0, False, 'SYN DROP'), (0.01, 0, False, 'TLS DROP'), (0.01, 0, True, 'TLS DROP'), (0, 0, True, 'TIMEOUT')):
            with self.subTest(expected=expected):
                session = object.__new__(engine.DohSession)
                session.lib = mock.Mock()
                session.lib.curl_easy_perform.return_value = 28
                session.handle = 1
                session.body = bytearray()
                session.error = engine.ctypes.create_string_buffer(256)
                session.timeout = 1
                session.url = 'https://dns.google/dns-query'
                session.connected = connected
                session.set = mock.Mock()
                session.info = lambda key, integer=False: tcp if key == 0x300005 else 3 if integer else tls
                self.assertEqual(session.query('example.com')['error'], expected)

    def test_skipped_probe_is_not_spoofing(self):
        control = {'error': '', 'rcode': 0, 'ips': ['1.1.1.1'], 'tc': False}
        data = {'control': control, 'domains': {'example.com': engine.failure('SKIPPED')}, 'invalid': None}
        self.assertEqual(engine.assess(data, {'example.com': {'8.8.8.8'}}), (0, 0, []))


class CurlLibraryTests(unittest.TestCase):
    def test_system_library_fallback(self):
        library = mock.MagicMock()
        library.curl_global_init.return_value = 0
        with mock.patch.object(engine, '_curl', None), mock.patch.object(engine.ctypes, 'CDLL', side_effect=[OSError('no Entware'), library]) as loader, mock.patch.object(engine.ctypes.util, 'find_library', return_value='libcurl.so.4'):
            self.assertIs(engine.curl_library(), library)
            self.assertEqual(loader.call_args_list, [mock.call('/opt/lib/libcurl.so.4'), mock.call('libcurl.so.4')])

    def test_missing_library_has_install_hint(self):
        with mock.patch.object(engine, '_curl', None), mock.patch.object(engine.ctypes, 'CDLL', side_effect=OSError('missing')), mock.patch.object(engine.ctypes.util, 'find_library', return_value=None):
            with self.assertRaisesRegex(OSError, 'opkg install'):
                engine.curl_library()


class LocalTLSTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cert = os.environ.get('XMENU_TEST_CERT')
        cls.key = os.environ.get('XMENU_TEST_KEY')
        if not cls.cert or not cls.key:
            raise unittest.SkipTest('Provide XMENU_TEST_CERT and XMENU_TEST_KEY for local TLS integration')

    def make_server(self, handler):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.cert, self.key)
        srv = socketserver.TCPServer(('127.0.0.1', 0), handler)
        srv.socket = context.wrap_socket(srv.socket, server_side=True)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        return srv.server_address[1]

    def test_real_dot_with_length_prefix(self):
        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                deadline = engine.time.monotonic() + 2
                size = struct.unpack('!H', engine.exact(self.request, 2, deadline))[0]
                packet = engine.exact(self.request, size, deadline)
                result = answer(packet)
                self.request.sendall(struct.pack('!H', len(result)) + result)
        port = self.make_server(Handler)
        context = ssl.create_default_context(cafile=self.cert)
        server = engine.Server('Local', '127.0.0.1', dot='localhost', dot_port=port)
        result = engine.probe(server, 'DoT', 'example.com', 2, context)
        self.assertFalse(result['error'])
        self.assertEqual(result['ips'], ['93.184.216.34'])

    def test_dot_rejects_wrong_hostname(self):
        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                pass
        port = self.make_server(Handler)
        context = ssl.create_default_context(cafile=self.cert)
        server = engine.Server('Local', '127.0.0.1', dot='wrong.example', dot_port=port)
        self.assertEqual(engine.probe(server, 'DoT', 'example.com', 2, context)['error'], 'TLS ERR')

    def test_real_doh_post_wire_and_verified_certificate(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                self.server.content_type = self.headers.get('Content-Type')
                packet = self.rfile.read(int(self.headers['Content-Length']))
                result = answer(packet)
                self.send_response(200)
                self.send_header('Content-Type', 'application/dns-message')
                self.send_header('Content-Length', str(len(result)))
                self.end_headers()
                self.wfile.write(result)

            def log_message(self, *args):
                pass
        port = self.make_server(Handler)
        server = engine.Server('Local', '127.0.0.1', doh=f'https://localhost:{port}/dns-query')
        with mock.patch.dict(os.environ, {'CURL_CA_BUNDLE': self.cert}):
            result = engine.probe(server, 'DoH', 'example.com', 2, None)
        self.assertFalse(result['error'])
        self.assertEqual(result['ips'], ['93.184.216.34'])

    def test_persistent_dot_reuses_connection_and_excludes_setup(self):
        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                for _ in range(2):
                    deadline = engine.time.monotonic() + 2
                    size = struct.unpack('!H', engine.exact(self.request, 2, deadline))[0]
                    packet = engine.exact(self.request, size, deadline)
                    result = answer(packet)
                    self.request.sendall(struct.pack('!H', len(result)) + result)
        port = self.make_server(Handler)
        context = ssl.create_default_context(cafile=self.cert)
        server = engine.Server('Local', '127.0.0.1', dot='localhost', dot_port=port)
        session = engine.DotSession(server, 2, context)
        try:
            for _ in range(2):
                result = session.query('example.com')
                self.assertFalse(result['error'])
                self.assertLess(result['ms'], 200)
                self.assertEqual(result['ips'], ['93.184.216.34'])
        finally:
            session.close()

    def test_doh_get_fallback_after_post_rejected(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def do_POST(self):
                self.rfile.read(int(self.headers['Content-Length']))
                self.send_response(405)
                self.send_header('Content-Length', '0')
                self.end_headers()

            def do_GET(self):
                token = engine.urllib.parse.parse_qs(engine.urllib.parse.urlsplit(self.path).query)['dns'][0]
                packet = engine.base64.urlsafe_b64decode(token + '=' * (-len(token) % 4))
                data = answer(packet)
                self.send_response(200)
                self.send_header('Content-Type', 'application/dns-message')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        port = self.make_server(Handler)
        server = engine.Server('Local', '127.0.0.1', doh=f'https://localhost:{port}/dns-query')
        with mock.patch.dict(os.environ, {'CURL_CA_BUNDLE': self.cert}):
            session = engine.DohSession(server, 2)
        try:
            for _ in range(2):
                result = session.query('example.com')
                self.assertFalse(result['error'])
                self.assertEqual(result['ips'], ['93.184.216.34'])
        finally:
            session.close()

    def test_persistent_doh_reuses_tls_and_reports_dns_time(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def do_POST(self):
                packet = self.rfile.read(int(self.headers['Content-Length']))
                result = answer(packet)
                self.send_response(200)
                self.send_header('Content-Type', 'application/dns-message')
                self.send_header('Content-Length', str(len(result)))
                self.end_headers()
                self.wfile.write(result)

            def log_message(self, *args):
                pass
        port = self.make_server(Handler)
        server = engine.Server('Local', '127.0.0.1', doh=f'https://localhost:{port}/dns-query')
        with mock.patch.dict(os.environ, {'CURL_CA_BUNDLE': self.cert}):
            session = engine.DohSession(server, 2)
            try:
                first = session.query('example.com')
                self.assertFalse(first['error'])
                self.assertEqual(first['new_connections'], 1)
                second = session.query('example.com')
                self.assertFalse(second['error'])
                self.assertEqual(second['new_connections'], 0)
                self.assertAlmostEqual(second['ms'], (session.info(0x300003) - session.info(0x300021)) * 1000)
            finally:
                session.close()


if __name__ == '__main__':
    unittest.main()
