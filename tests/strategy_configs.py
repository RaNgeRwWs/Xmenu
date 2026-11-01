from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
FILES = sorted((ROOT / 'strategies/nfqws2/additional').glob('*.conf'))
ASSIGNMENT = re.compile(r'(?m)^([A-Z][A-Z0-9_]*)="([^"`]*)"\n?')
SECTIONS = ('NFQWS_ARGS', 'NFQWS_ARGS_CUSTOM', 'NFQWS_ARGS_QUIC', 'NFQWS_ARGS_UDP')


def values(path):
    return {match[1]: match[2] for match in ASSIGNMENT.finditer(path.read_text())}


class StrategyTests(unittest.TestCase):
    def test_count_names_and_comment_free_assignments(self):
        self.assertEqual(len(FILES), 30)
        for path in FILES:
            with self.subTest(path=path.name):
                text = path.read_text()
                self.assertFalse(re.match(r'^(?:\d+|NEW-\d+)', path.stem))
                self.assertFalse(ASSIGNMENT.sub('', text).strip())
                self.assertNotIn('$(', text)
                self.assertNotIn('`', text)
                self.assertNotIn('#', text)
                keys = [match[1] for match in ASSIGNMENT.finditer(text)]
                self.assertEqual(len(keys), len(set(keys)))

    def test_variables_defined_before_expansion(self):
        for path in FILES:
            known = set()
            for match in ASSIGNMENT.finditer(path.read_text()):
                for variable in re.findall(r'\$([A-Z][A-Z0-9_]*)', match[2]):
                    self.assertIn(variable, known, (path.name, variable))
                known.add(match[1])
            self.assertTrue(set(SECTIONS + ('MODE_LIST', 'ISP_INTERFACE', 'TCP_PORTS', 'UDP_PORTS', 'NFQWS_ARGS_IPSET')) <= known, path)

    def test_blobs_declared_or_builtin(self):
        for path in FILES:
            config = values(path)
            declared = set(re.findall(r'--blob=([^:\s]+):', config['NFQWS_BASE_ARGS']))
            declared.update(('fake_default_http', 'fake_default_tls'))
            for key in SECTIONS:
                for blob in re.findall(r':(?:blob|pattern|seqovl_pattern)=([^:\s]+)', config[key]):
                    self.assertTrue(blob in declared or re.fullmatch(r'0x(?:[0-9a-fA-F]{2})+', blob), (path.name, key, blob))
                for line in config[key].splitlines():
                    if line.startswith('--lua-desync=fake:'):
                        self.assertIn(':blob=', line, path.name)

    def test_circular_strategies_are_nonempty_and_contiguous(self):
        for path in FILES:
            for key in SECTIONS:
                for profile in re.split(r'\s+--new\s+', values(path)[key]):
                    if '--lua-desync=circular:' in profile:
                        numbers = sorted({int(v) for v in re.findall(r':strategy=(\d+)', profile)})
                        self.assertTrue(numbers, (path.name, key))
                        self.assertEqual(numbers, list(range(1, len(numbers) + 1)), (path.name, key))

    def test_removed_unsupported_arguments_and_single_split_position(self):
        for path in FILES:
            for key in SECTIONS:
                for line in values(path)[key].splitlines():
                    self.assertNotRegex(line, r':(?:altorder|oob_data|oob|badseq)(?:=|:|$)')
                    if line.startswith(('--lua-desync=fakedsplit:', '--lua-desync=fakeddisorder:')):
                        for position in re.findall(r':pos=([^:\s]+)', line):
                            self.assertNotIn(',', position, path.name)
                    if line.startswith('--lua-desync=hostfakesplit:'):
                        self.assertNotRegex(line, r':(?:seqovl|seqovl_pattern)=')

    def test_every_filter_port_is_intercepted(self):
        for path in FILES:
            config = values(path)
            profiles = '\n'.join(config[key] for key in SECTIONS)
            for protocol in ('TCP', 'UDP'):
                intercepted = set(config[protocol + '_PORTS'].split(','))
                for group in re.findall('--filter-' + protocol.lower() + r'=([^\s]+)', profiles):
                    for port in group.split(','):
                        self.assertIn(port.replace('-', ':'), intercepted, (path.name, protocol, port))


if __name__ == '__main__':
    unittest.main()
