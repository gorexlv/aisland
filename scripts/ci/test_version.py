import unittest
from version import parse_tag


class VersionTests(unittest.TestCase):
    def test_stable_versions(self):
        for tag in ('v0.0.0', 'v1.2.3', 'v12.345.678'):
            result = parse_tag(tag)
            self.assertEqual(result['version'], tag[1:])
            self.assertFalse(result['prerelease'])

    def test_prerelease_keeps_numeric_apple_version(self):
        for suffix in ('rc.1', 'alpha', '0', 'beta-2', 'a.0.z'):
            result = parse_tag('v1.2.3-' + suffix)
            self.assertEqual(result['version'], '1.2.3')
            self.assertTrue(result['prerelease'])

    def test_rejects_malformed_or_unsafe_tags(self):
        for tag in ('1.2.3', 'v1.2', 'v01.2.3', 'v1.02.3', 'v1.2.03', 'v1.2.3-',
                    'v1.2.3-rc..1', 'v1.2.3-01', 'v1.2.3-rc.01', 'v1.2.3+build',
                    'v1.2.3\n', 'v1.2.3;echo', 'v1.2.3/rc', 'latest', 'v1.2.3-中文',
                    'v1.2.3-' + 'a' * 100):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                parse_tag(tag)
