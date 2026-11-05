"""Exercise publication safety gates with fake Git/GitHub, never a network request."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class PublicationTests(unittest.TestCase):
    def run_publish(self, tag='v1.2.3', case='ok'):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / 'scripts/ci'
            scripts.mkdir(parents=True)
            for name in ('publish.sh', 'version.py'):
                shutil.copy(Path(__file__).parent / name, scripts / name)
            (root / 'release').mkdir()
            (root / 'release/SHA256SUMS').write_text(
                'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  fixture.zip\n')
            (root / 'release/fixture.zip').touch()
            if case == 'bad-checksum':
                (root / 'release/fixture.zip').write_text('corrupt')
            binary = root / 'bin'
            binary.mkdir()
            fake = '''#!/usr/bin/env python3
import json, os, pathlib, sys
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['CALL_LOG'], 'a') as stream:
    stream.write(json.dumps([tool, *args]) + '\\n')
case = os.environ['CASE']
if tool == 'git':
    if args[0] == 'rev-parse': print('moved' if case == 'moved' else 'abc123')
    if args[0] == 'merge-base' and case == 'off-main': sys.exit(1)
if tool == 'gh':
    if args[0] == 'api':
        if case == 'api-error': sys.exit(1)
        if case == 'duplicate': print(os.environ['RELEASE_TAG'])
    if args[:2] == ['release', 'create'] and case == 'upload-error': sys.exit(1)
'''
            for tool in ('git', 'gh'):
                path = binary / tool
                path.write_text(fake)
                path.chmod(0o755)
            log = root / 'calls.jsonl'
            env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                       RELEASE_TAG=tag, GITHUB_SHA='abc123', GITHUB_REPOSITORY='fixture/repo',
                       CASE=case, CALL_LOG=str(log))
            result = subprocess.run(['bash', str(scripts / 'publish.sh')], env=env,
                                    capture_output=True, text=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def test_stages_before_publish_and_marks_prerelease(self):
        for tag in ('v1.2.3', 'v1.2.3-rc.1'):
            result, calls = self.run_publish(tag)
            self.assertEqual(result.returncode, 0, result.stderr)
            writes = [call for call in calls if call[:2] == ['gh', 'release']]
            self.assertEqual([call[2] for call in writes], ['create', 'edit'])
            self.assertIn('--verify-tag', writes[0])
            self.assertIn('--draft', writes[0])
            self.assertEqual('--prerelease' in writes[0], '-' in tag)
            self.assertIn('--draft=false', writes[1])

    def test_safety_gates_never_create(self):
        for case in ('duplicate', 'moved', 'off-main', 'api-error', 'bad-checksum'):
            result, calls = self.run_publish(case=case)
            self.assertNotEqual(result.returncode, 0, case)
            self.assertFalse(any(call[:2] == ['gh', 'release'] for call in calls), case)

    def test_failed_upload_never_publishes(self):
        result, calls = self.run_publish(case='upload-error')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[:3] == ['gh', 'release', 'edit'] for call in calls))

    def test_invalid_tag_never_calls_git_or_github(self):
        result, calls = self.run_publish('not-a-version')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])
