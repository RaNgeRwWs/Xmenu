import contextlib
import io
import json
import os
from pathlib import Path
import socket
import struct
import sys
import threading
import time
import types
import unittest
import zlib
from unittest import mock

path = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / 'xmenu-v1.0.sh'
source = path.read_text(encoding='utf-8')
code = source.split("<<'XMENU_SERVER_ENGINE'\n", 1)[1].split('\nXMENU_SERVER_ENGINE', 1)[0]
engine = types.ModuleType('server_extensions')
sys.modules[engine.__name__] = engine
exec(compile(code, '<server extensions>', 'exec'), engine.__dict__)


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        engine.CANCEL.clear()
        engine.END_TIME = float('inf')

    def test_historical_ports_are_validated_and_not_live_evidence(self):
        value = engine.parse_discovery('1.1.1.1', {'ip': '1.1.1.1', 'ports': [22222, 443, 22222], 'hostnames': ['vps.example.org', 'bad\x1b[31m', 'a..b']})
        self.assertEqual(value['ports'], [443, 22222])
        self.assertEqual(value['hostnames'], ['vps.example.org'])
        self.assertTrue(value['historical'])
        self.assertEqual(value['transport'], 'unspecified')

    def test_discovery_rejects_other_target_and_bad_ports(self):
        for data in ({'ip': '8.8.8.8', 'ports': [443]}, {'ip': '1.1.1.1', 'ports': [True]}, {'ip': '1.1.1.1', 'ports': [0]}, {'ip': '1.1.1.1', 'ports': ['22']}, {'ip': '1.1.1.1', 'ports': list(range(1, 258))}):
            with self.subTest(data=str(data)[:80]), self.assertRaises(ValueError):
                engine.parse_discovery('1.1.1.1', data)

    def test_404_is_missing_metadata_not_unreachable_ip(self):
        with mock.patch.object(engine, 'fetch_json', side_effect=engine.ApiHTTPError(404)):
            value = engine.discover_ports('1.1.1.1')
        self.assertEqual(value['status'], 'NO DATA')
        self.assertEqual(value['ports'], [])

    def test_unavailable_internetdb_is_api_error(self):
        with mock.patch.object(engine, 'fetch_json', side_effect=TimeoutError()):
            value = engine.discover_ports('1.1.1.1')
        self.assertEqual(value['status'], 'API ERROR')

    def test_discovery_limits_targets_and_never_retests_open_ports(self):
        local = {22: {'status': 'OPEN'}, 2053: {'status': 'SKIPPED'}}
        result = engine.discovery_targets({'ports': [22, 2053, 22222, 38491, 45000, 45001, 45002, 45003]}, local)
        self.assertEqual(len(result), 5)
        self.assertNotIn(22, result)
        self.assertIn(22222, result)

    def test_total_discovery_port_cap(self):
        local = {p: {'status': 'OPEN'} for p in range(1, 19)}
        self.assertEqual(engine.discovery_targets({'ports': [22222]}, local), [])

    def test_external_compares_one_discovered_port_and_keeps_required_ports(self):
        self.assertEqual(engine.comparison_ports([38491, 45000, 22]), [443, 22, 38491])


class RoutingTests(unittest.TestCase):
    def test_visibility_has_observation_time_and_valid_counters(self):
        value = engine.parse_visibility({'resource': '1.1.1.0/24', 'query_time': '2026-11-01T16:00:00', 'visibility': {'v4': {'ris_peers_seeing': 200, 'total_ris_peers': 300}}, 'origins': [{'origin': 13335}]}, '1.1.1.0/24')
        self.assertEqual(value['status'], 'VISIBLE')
        self.assertEqual(value['peers_seen'], 200)
        self.assertEqual(value['origins'], [13335])
        self.assertTrue(value['observed_at'])

    def test_visibility_invalid_counts_and_target_are_not_missing_bgp(self):
        for data in ({'resource': '8.8.8.0/24', 'visibility': {}}, {'resource': '1.1.1.0/24', 'visibility': {'v4': {'ris_peers_seeing': 5, 'total_ris_peers': 2}}}):
            with self.assertRaises(ValueError):
                engine.parse_visibility(data, '1.1.1.0/24')

    def test_rpki_unknown_is_neutral(self):
        value = engine.parse_rpki({'resource': '13335', 'prefix': '1.1.1.0/24', 'status': 'unknown'}, '1.1.1.0/24', 13335)
        self.assertEqual(value['status'], 'UNKNOWN')

    def test_rpki_valid_and_invalid_are_distinct(self):
        for status, expected in (('valid', 'VALID'), ('invalid_asn', 'INVALID'), ('invalid_length', 'INVALID')):
            value = engine.parse_rpki({'resource': 13335, 'prefix': '1.1.1.0/24', 'status': status}, '1.1.1.0/24', 13335)
            self.assertEqual(value['status'], expected)

    def test_rpki_cannot_validate_other_asn_or_prefix(self):
        for data in ({'resource': 1, 'prefix': '1.1.1.0/24', 'status': 'valid'}, {'resource': 13335, 'prefix': '8.8.8.0/24', 'status': 'valid'}):
            with self.assertRaises(ValueError):
                engine.parse_rpki(data, '1.1.1.0/24', 13335)


class StunTests(unittest.TestCase):
    def response(self, transaction, kind=0x0101, attributes=None):
        if attributes is None:
            attributes = struct.pack('!HHBBHI', 0x0020, 8, 0, 1, 54321 ^ 0x2112, 0xcb007109 ^ 0x2112a442) if kind == 0x0101 else b''
        return struct.pack('!HHI', kind, len(attributes), 0x2112a442) + transaction + attributes

    def test_stun_success_correlates_cookie_and_transaction(self):
        tx = b'123456789012'
        value = engine.parse_stun(self.response(tx), tx)
        self.assertEqual(value['status'], 'STUN REPLY')
        self.assertTrue(value['reachable'])
        self.assertIsNone(engine.parse_stun(self.response(b'000000000000'), tx))

    def test_stun_error_is_service_response_not_ip_block(self):
        tx = b'123456789012'
        attributes = struct.pack('!HH', 9, 4) + b'\0\0\x04\x01'
        result = engine.parse_stun(self.response(tx, 0x0111, attributes), tx)
        self.assertEqual(result['error_code'], 401)
        self.assertTrue(result['reachable'])

    def test_stun_rejects_bad_length_cookie_and_attributes(self):
        tx = b'123456789012'
        valid = self.response(tx)
        for data in (valid[:19], valid[:4] + b'ABCD' + valid[8:], valid[:2] + b'\0\x08' + valid[4:], self.response(tx, attributes=b'\0\x01\0\x08'), self.response(tx, kind=0x0001)):
            self.assertIsNone(engine.parse_stun(data, tx))

    def test_stun_xor_mapped_address_is_decoded(self):
        tx = b'123456789012'
        ip = bytes(a ^ b for a, b in zip(socket.inet_aton('203.0.113.9'), struct.pack('!I', 0x2112a442)))
        attributes = struct.pack('!HHBBH', 0x0020, 8, 0, 1, 54321 ^ 0x2112) + ip
        value = engine.parse_stun(self.response(tx, attributes=attributes), tx)
        self.assertEqual(value['mapped_address'], '203.0.113.9')
        self.assertEqual(value['mapped_port'], 54321)


    def test_stun_fingerprint_and_ipv6_mapping(self):
        tx = b'123456789012'
        mask = struct.pack('!I', 0x2112a442) + tx
        address = bytes(a ^ b for a, b in zip(socket.inet_pton(socket.AF_INET6, '2001:db8::7'), mask))
        attributes = struct.pack('!HHBBH', 0x0020, 20, 0, 2, 54321 ^ 0x2112) + address
        message = self.response(tx, attributes=attributes)
        message = message[:2] + struct.pack('!H', len(attributes) + 8) + message[4:]
        message += struct.pack('!HHI', 0x8028, 4, zlib.crc32(message) ^ 0x5354554e)
        result = engine.parse_stun(message, tx)
        self.assertEqual(result['mapped_address'], '2001:db8::7')
        self.assertIsNone(engine.parse_stun(message[:-1] + bytes([message[-1] ^ 1]), tx))


class LoopbackTests(unittest.TestCase):
    def setUp(self):
        engine.CANCEL.clear()
        engine.END_TIME = float('inf')

    def test_stun_live_socket_round_trip_and_mapped_address(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
            server.bind(('127.0.0.1', 0))
            server.settimeout(2)
            def answer():
                data, peer = server.recvfrom(2048)
                server.sendto(StunTests().response(b'000000000000'), peer)
                server.sendto(StunTests().response(data[8:20]), peer)
            worker = threading.Thread(target=answer)
            worker.start()
            with mock.patch.object(engine, 'prepare_socket', side_effect=lambda value: value), mock.patch.object(engine, 'FlowGuard'):
                result = engine.stun_probe('127.0.0.1', server.getsockname()[1], 1)
            worker.join(3)
            self.assertEqual(result['status'], 'STUN REPLY')
            self.assertTrue(result['reachable'])
            self.assertGreaterEqual(result['ms'], 0)

    def test_passive_custom_port_banner(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
            server.bind(('127.0.0.1', 0))
            server.listen(1)
            server.settimeout(2)
            def answer():
                connection, peer = server.accept()
                with connection:
                    connection.sendall(b'SSH-2.0-TestServer\r\n')
            worker = threading.Thread(target=answer)
            worker.start()
            with mock.patch.object(engine, 'prepare_socket', side_effect=lambda value: value), mock.patch.object(engine, 'FlowGuard'):
                result = engine.banner_probe('127.0.0.1', server.getsockname()[1])
            worker.join(3)
            self.assertEqual(result['status'], 'BANNER REPLY')
            self.assertEqual(result['protocol'], 'SSH')


class AuditRegressionTests(unittest.TestCase):
    def setUp(self):
        engine.CANCEL.clear()
        engine.END_TIME = float('inf')

    def tearDown(self):
        engine.CANCEL.clear()

    def test_cancelled_recheck_preserves_completed_original_probe(self):
        previous = {'status': 'TIMEOUT', 'port_state': 'FILTERED', 'port': 443, 'ms': None, 'attempts': [{'status': 'TIMEOUT'}, {'status': 'TIMEOUT'}]}
        engine.CANCEL.set()
        value = engine.tcp_recheck('1.1.1.1', 443, previous)
        self.assertEqual(value['status'], 'TIMEOUT')
        self.assertTrue(value['recheck_incomplete'])
        self.assertFalse(value['external_recheck'])

    def test_quic_retransmission_does_not_claim_precise_rtt(self):
        clock = [100.0]
        dcid, scid, version = b'd' * 8, b's' * 8, 0x1a2a3a4a
        reply = b'\x80' + b'\0' * 4 + bytes([len(scid)]) + scid + bytes([len(dcid)]) + dcid + struct.pack('!I', 1)
        sock = mock.MagicMock()
        sock.__enter__.return_value = sock
        sock.getsockname.return_value = ('0.0.0.0', 54321)
        calls = []
        def receive(size):
            calls.append(1)
            clock[0] += .7 if len(calls) == 1 else .02
            if len(calls) == 1:
                raise TimeoutError()
            return reply
        sock.recv.side_effect = receive
        with mock.patch.object(engine.socket, 'socket', return_value=sock), mock.patch.object(engine, 'prepare_socket', side_effect=lambda value: value), mock.patch.object(engine, 'FlowGuard'), mock.patch.object(engine.time, 'monotonic', side_effect=lambda: clock[0]), mock.patch.object(engine, 'quic_probe_packet', return_value=(b'probe', dcid, scid, version)):
            value = engine.udp('1.1.1.1', 443, 2)
        self.assertEqual(value['status'], 'QUIC VN')
        self.assertIsNone(value['ms'])
        self.assertEqual(value['attempts'], 2)


class TimestampTests(unittest.TestCase):
    def packet(self, ident=123, seq=7, orig=12345):
        data = struct.pack('!BBHHHIII', 14, 0, 0, ident, seq, orig, 100, 101)
        return data[:2] + struct.pack('!H', engine.checksum(data)) + data[4:]

    def test_timestamp_reply_matches_identity_original_time_and_checksum(self):
        data = self.packet()
        self.assertTrue(engine.timestamp_reply(data, '1.1.1.1', '1.1.1.1', 123, 7, 12345))
        self.assertIsNone(engine.timestamp_reply(data, '8.8.8.8', '1.1.1.1', 123, 7, 12345))
        self.assertIsNone(engine.timestamp_reply(data, '1.1.1.1', '1.1.1.1', 123, 8, 12345))
        self.assertIsNone(engine.timestamp_reply(data, '1.1.1.1', '1.1.1.1', 123, 7, 54321))
        self.assertIsNone(engine.timestamp_reply(data[:-1] + b'\0', '1.1.1.1', '1.1.1.1', 123, 7, 12345))


class LocalFilterTests(unittest.TestCase):
    def rules(self, text):
        return engine.filter_candidates('1.1.1.1', text, '100.78.47.7', 'eth3')

    def test_negated_port_does_not_hide_local_filter(self):
        rule = self.rules('-A OUTPUT -p tcp ! --dport 443 -j DROP')[0]
        self.assertTrue(engine.filter_affects(rule, 22))
        self.assertFalse(engine.filter_affects(rule, 443))

    def test_negated_multiport_and_protocol(self):
        rule = self.rules('-A OUTPUT -p tcp -m multiport ! --dports 80,443 -j REJECT')[0]
        self.assertTrue(engine.filter_affects(rule, 22))
        self.assertFalse(engine.filter_affects(rule, 80))
        rule = self.rules('-A OUTPUT ! -p udp -j DROP')[0]
        self.assertTrue(engine.filter_affects(rule, 443))
        rule = self.rules('-A OUTPUT ! -p tcp -j DROP')[0]
        self.assertFalse(engine.filter_affects(rule, 443))

    def test_truncation_remains_conservative_for_every_port(self):
        rules = self.rules('\n'.join('-A OUTPUT -p tcp --dport %d -j DROP' % p for p in range(10000, 10040)))
        self.assertEqual(len(rules), 32)
        self.assertTrue(any(engine.filter_affects(r, 22) for r in rules))

    def test_other_ip_interface_and_unreachable_chain_are_excluded(self):
        rules = self.rules('-A OUTPUT -d 8.8.8.8 -j DROP\n-A OUTPUT -o eth4 -j DROP\n-A UNUSED -j DROP')
        self.assertEqual(rules, [])

    def test_jump_input_source_port_and_ranges(self):
        rules = self.rules('-A INPUT -j CUSTOM\n-A CUSTOM -s 1.1.1.1 -p tcp --sport 20:25 -j REJECT')
        self.assertEqual(len(rules), 1)
        self.assertTrue(engine.filter_affects(rules[0], 22))
        self.assertFalse(engine.filter_affects(rules[0], 443))

    def test_default_drop_cannot_be_reported_as_clear(self):
        rules = self.rules(':OUTPUT DROP [0:0]')
        self.assertTrue(engine.filter_affects(rules[0], 443))

    def test_negated_connection_state_and_numeric_protocol_are_retained(self):
        rules = self.rules('-A OUTPUT -p 6 -m conntrack ! --ctstate INVALID -j DROP')
        self.assertEqual(len(rules), 1)
        self.assertTrue(engine.filter_affects(rules[0], 443))
        rule = self.rules('-A OUTPUT ! -p esp -j DROP')[0]
        self.assertTrue(engine.filter_affects(rule, 443))

    def test_oversized_filter_is_not_a_successful_audit(self):
        response = types.SimpleNamespace(returncode=0, stdout=b' ' * 1048577)
        with mock.patch.object(engine.subprocess, 'run', return_value=response):
            result = engine.inspect_filter('1.1.1.1', {})
        self.assertEqual(result['status'], 'UNKNOWN')

    def test_unqualified_nfqueue_cannot_prove_icmp_bypass(self):
        text = b'*mangle\n-A PREROUTING -j nfqws_pre\n-A nfqws_pre -j NFQUEUE --queue-num 200\nCOMMIT\n'
        response = types.SimpleNamespace(returncode=0, stdout=text)
        with mock.patch.object(engine.subprocess, 'run', return_value=response), mock.patch.object(engine.shutil, 'which', return_value=None):
            result = engine.detect_path('1.1.1.1')
        self.assertFalse(result['direct_ready'])

    def test_deep_chain_graph_remains_conservative(self):
        text = '-A OUTPUT -j C0\n' + '\n'.join('-A C%d -j C%d' % (n, n + 1) for n in range(70)) + '\n-A C70 -p tcp --dport 22 -j DROP'
        rules = self.rules(text)
        self.assertTrue(any(engine.filter_affects(rule, 22) for rule in rules))

    def test_truncated_mangle_snapshot_cannot_prove_bypass(self):
        response = types.SimpleNamespace(returncode=0, stdout=b' ' * 1048577)
        with mock.patch.object(engine.subprocess, 'run', return_value=response), mock.patch.object(engine.shutil, 'which', return_value=None):
            result = engine.detect_path('1.1.1.1')
        self.assertFalse(result['direct_ready'])

    def test_deep_mangle_graph_cannot_hide_redirect(self):
        text = '-A OUTPUT -j C0\n' + '\n'.join('-A C%d -j C%d' % (n, n + 1) for n in range(70)) + '\n-A C70 -j REDIRECT --to-ports 1080'
        response = types.SimpleNamespace(returncode=0, stdout=text.encode())
        with mock.patch.object(engine.subprocess, 'run', return_value=response), mock.patch.object(engine.shutil, 'which', return_value=None):
            result = engine.detect_path('1.1.1.1')
        self.assertFalse(result['direct_ready'])

    def test_truncated_nft_snapshot_cannot_prove_bypass(self):
        def run(command, **kwargs):
            return types.SimpleNamespace(returncode=0, stdout=b' ' * 1048577 if command[0] == 'nft' else b'')
        with mock.patch.object(engine.subprocess, 'run', side_effect=run), mock.patch.object(engine.shutil, 'which', return_value='/usr/sbin/nft'):
            result = engine.detect_path('1.1.1.1')
        self.assertFalse(result['direct_ready'])


class PipelineTests(unittest.TestCase):
    def run_main(self, private=False):
        selected = []
        def stage(report, title, jobs, quiet=False):
            for (key, index), function, args in jobs:
                if key == 'discovery':
                    report[key] = engine.parse_discovery('1.1.1.1', {'ip': '1.1.1.1', 'ports': [38491]})
                elif key in ('tcp', 'controls'):
                    report[key][index] = {'status': 'OPEN', 'ms': 1}
                elif key == 'external':
                    selected.append(list(args[1]))
                elif key == 'bgp':
                    report[key] = {'prefix': '1.1.1.0/24', 'asns': []}
        path = {'mark': 0, 'direct_ready': True, 'risks': [], 'interface': 'eth3', 'source': '100.78.47.7'}
        argv = ['engine', '1.1.1.1', '--json'] + (['--no-external'] if private else [])
        with mock.patch.object(sys, 'argv', argv), mock.patch.object(engine, 'detect_path', return_value=path), mock.patch.object(engine, 'inspect_route', return_value={'status': 'OK', 'ok': True}), mock.patch.object(engine, 'inspect_filter', return_value={'status': 'OK', 'candidates': []}), mock.patch.object(engine, 'run_stage', side_effect=stage), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(engine.main(), 0)
        return json.loads(output.getvalue()), selected

    def test_historical_candidate_is_live_probed_and_externally_compared(self):
        report, selected = self.run_main()
        self.assertEqual(report['tcp']['38491']['status'], 'OPEN')
        self.assertEqual(selected, [[443, 22, 38491]])
        self.assertEqual(report['discovery']['selected_ports'], [38491])

    def test_no_external_skips_metadata_and_external_jobs(self):
        report, selected = self.run_main(True)
        self.assertEqual(report['discovery']['status'], 'SKIPPED')
        self.assertEqual(selected, [])
        self.assertNotIn('38491', report['tcp'])

    def test_new_result_rows_fit_compact_tables(self):
        report, selected = self.run_main()
        report['bgp']['status'] = 'ANNOUNCED'
        report['routing'] = {'visibility': {'status': 'VISIBLE', 'stale': False, 'detail': '100/100 RIS-наблюдателей'}, 'rpki': [], 'errors': ['API timeout']}
        report['timestamp'] = {'status': 'TIMESTAMP REPLY', 'reachable': True, 'ms': 1}
        report['udp'][3478] = {'status': 'STUN REPLY', 'reachable': True, 'ms': 1}
        report['services'][38491] = {'status': 'BANNER REPLY', 'protocol': 'SSH'}
        for columns in (74, 100, 108):
            with mock.patch.object(engine.shutil, 'get_terminal_size', return_value=os.terminal_size((columns, 24))), contextlib.redirect_stdout(io.StringIO()) as output:
                engine.render_report(report)
            rendered = output.getvalue()
            self.assertIn('API недоступен', rendered)
            self.assertIn('ICMP ответил', rendered)
            self.assertIn('STUN ответил', rendered)
            for line in rendered.splitlines():
                if line.startswith(('│', '┌', '├', '└')):
                    self.assertLessEqual(engine.width(line), columns)

    def test_summary_has_explicit_cause_duration_and_no_details_link(self):
        report, selected = self.run_main()
        report['bgp']['status'] = 'ANNOUNCED'
        report['tcp']['8080'] = {'status': 'TIMEOUT', 'attempts': [{'status': 'TIMEOUT'}, {'status': 'TIMEOUT'}]}
        report['discovery'] = {'status': 'API ERROR', 'ports': []}
        report['path']['local_filter'] = {'status': 'OK', 'candidates': [{'protocol': 'all', 'ports': '*'}]}
        report['analysis'] = engine.classify(report)
        with contextlib.redirect_stdout(io.StringIO()) as output:
            engine.render_report(report)
        text = output.getvalue()
        self.assertNotIn('уверенность', text)
        self.assertNotIn('см. D', text)
        self.assertNotIn('D —', text)
        self.assertIn('Длительность проверки:', text)
        self.assertIn('Причина отсутствия ответа не установлена', text)
        self.assertIn('API недоступен', text)


class EvidenceTests(unittest.TestCase):
    def report(self):
        return {'ip': '1.1.1.1', 'route': {'ok': True}, 'path': {'direct_ready': True, 'local_filter': {'status': 'OK', 'candidates': []}}, 'tcp': {22: {'status': 'TIMEOUT', 'attempts': [{'status': 'TIMEOUT'}, {'status': 'TIMEOUT'}]}}, 'ping': {'received': 0}, 'traces': {}, 'http': {}, 'ssh': {'status': 'TIMEOUT'}, 'controls': {'8.8.8.8': {'status': 'OPEN'}, '9.9.9.9': {'status': 'OPEN'}}, 'external': []}

    def test_historical_ports_alone_do_not_prove_reachability(self):
        report = self.report()
        report['discovery'] = {'status': 'FOUND', 'ports': [22, 443], 'historical': True}
        self.assertEqual(engine.classify(report)['state'], 'INCONCLUSIVE')

    def test_timestamp_only_is_live_evidence_of_ip_response(self):
        report = self.report()
        report['timestamp'] = {'status': 'TIMESTAMP REPLY', 'reachable': True}
        self.assertEqual(engine.classify(report)['state'], 'REACHABLE')

    def test_local_rule_prevents_strong_external_path_attribution(self):
        report = self.report()
        report['external'] = [{'kind': 'tcp', 'port': 22, 'status': 'OPEN', 'asn': a, 'country': c} for a, c in [('AS1', 'DE'), ('AS2', 'US')]]
        report['path']['local_filter']['candidates'] = [{'protocol': 'all', 'ports': '*'}]
        self.assertNotEqual(engine.classify(report)['state'], 'LIKELY_PATH_SPECIFIC_FILTERING')

    def test_invalid_rpki_does_not_override_direct_tcp_response(self):
        report = self.report()
        report['tcp'][22] = {'status': 'OPEN'}
        report['routing'] = {'rpki': [{'status': 'INVALID'}]}
        self.assertEqual(engine.classify(report)['state'], 'REACHABLE')

    def test_rpki_resource_must_be_exact_asn(self):
        for resource in ('AAS13335', 'SS13335', '13335junk'):
            with self.assertRaises(ValueError):
                engine.parse_rpki({'resource': resource, 'prefix': '1.1.1.0/24', 'status': 'valid'}, '1.1.1.0/24', 13335)


if __name__ == '__main__':
    unittest.main()
