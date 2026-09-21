"""Exercise the sync script against disposable local Git remotes."""
# Copyright (c) 2026 Apple Inc. and the Swift project authors.
# Licensed under Apache License v2.0 with Runtime Library Exception.

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('rebase-upstream.sh').resolve()


class RebaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.upstream = self.root / 'upstream'
        self.fork = self.root / 'fork.git'
        self.checkout = self.root / 'checkout'
        self.output = self.root / 'output'
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_AUTHOR_NAME='Test', GIT_AUTHOR_EMAIL='test@example.invalid',
                        GIT_COMMITTER_NAME='Test', GIT_COMMITTER_EMAIL='test@example.invalid',
                        GIT_TERMINAL_PROMPT='0', GITHUB_OUTPUT=str(self.output),
                        UPSTREAM_REPOSITORY=str(self.upstream))
        self.git(self.root, 'init', '-b', 'main', str(self.upstream))
        self.commit(self.upstream, 'shared.txt', 'base\n')
        self.git(self.root, 'clone', '--bare', str(self.upstream), str(self.fork))
        self.git(self.root, 'clone', str(self.fork), str(self.checkout))
        self.commit(self.checkout, 'feature.txt', 'fork feature\n')
        self.git(self.checkout, 'push', 'origin', 'main')
        self.original = self.git(self.fork, 'rev-parse', 'main')

    def git(self, cwd, *args):
        return subprocess.run(['git', *args], cwd=cwd, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, cwd, path, content):
        (cwd / path).write_text(content)
        self.git(cwd, 'add', path)
        self.git(cwd, 'commit', '-m', 'Update ' + path)

    def run_sync(self, phase):
        if phase == 'publish':
            values = dict(line.split('=', 1) for line in self.output.read_text().splitlines())
            self.env.update(ORIGINAL_HEAD=values['original_head'], UPSTREAM_HEAD=values['upstream_head'])
        return subprocess.run(['bash', str(SCRIPT), phase], cwd=self.checkout, env=self.env,
                              capture_output=True, text=True)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_rebases_then_publishes_and_is_idempotent(self):
        self.commit(self.upstream, 'upstream.txt', 'new upstream\n')
        self.assert_success(self.run_sync('prepare'))
        self.assertEqual(self.git(self.fork, 'rev-parse', 'main'), self.original)
        self.assertEqual((self.checkout / 'feature.txt').read_text(), 'fork feature\n')
        self.assert_success(self.run_sync('publish'))
        latest = self.git(self.fork, 'rev-parse', 'main')
        self.assertNotEqual(latest, self.original)
        self.git(self.fork, 'merge-base', '--is-ancestor', self.git(self.upstream, 'rev-parse', 'main'), 'main')
        self.output.write_text('')
        self.assert_success(self.run_sync('prepare'))
        self.assert_success(self.run_sync('publish'))
        self.assertEqual(self.git(self.fork, 'rev-parse', 'main'), latest)

    def test_conflict_aborts_without_changing_remote(self):
        self.commit(self.checkout, 'shared.txt', 'fork\n')
        self.git(self.checkout, 'push', 'origin', 'main')
        before = self.git(self.fork, 'rev-parse', 'main')
        self.commit(self.upstream, 'shared.txt', 'upstream\n')
        self.assertNotEqual(self.run_sync('prepare').returncode, 0)
        self.assertEqual(self.git(self.checkout, 'rev-parse', 'HEAD'), before)
        self.assertEqual(self.git(self.fork, 'rev-parse', 'main'), before)
        self.assertFalse((self.checkout / '.git/rebase-merge').exists())

    def test_lease_rejects_concurrent_remote_change(self):
        self.commit(self.upstream, 'upstream.txt', 'new upstream\n')
        self.assert_success(self.run_sync('prepare'))
        concurrent = self.root / 'concurrent'
        self.git(self.root, 'clone', str(self.fork), str(concurrent))
        self.commit(concurrent, 'concurrent.txt', 'preserve this\n')
        self.git(concurrent, 'push', 'origin', 'main')
        before = self.git(self.fork, 'rev-parse', 'main')
        self.assertNotEqual(self.run_sync('publish').returncode, 0)
        self.assertEqual(self.git(self.fork, 'rev-parse', 'main'), before)

    def test_dirty_validation_cannot_publish(self):
        self.commit(self.upstream, 'upstream.txt', 'new upstream\n')
        self.assert_success(self.run_sync('prepare'))
        (self.checkout / 'feature.txt').write_text('unexpected test mutation\n')
        self.assertNotEqual(self.run_sync('publish').returncode, 0)
        self.assertEqual(self.git(self.fork, 'rev-parse', 'main'), self.original)


if __name__ == '__main__':
    unittest.main()
