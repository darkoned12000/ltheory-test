#!/usr/bin/env python3
"""Process-status contracts for the HoloNodeDemo integration runner."""

import contextlib
import io
from pathlib import Path
import subprocess
import sys
import unittest
from types import SimpleNamespace
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import configure


class HoloRunnerTests(unittest.TestCase):
    def run_case(self, *, returncode=0, stdout='', timeout=False):
        if timeout:
            result = subprocess.TimeoutExpired(['lt64r', 'HoloNodeDemo'], 40,
                                               output=stdout)
            side_effect = result
        else:
            side_effect = None
            result = SimpleNamespace(returncode=returncode, stdout=stdout)

        output = io.StringIO()
        with mock.patch('configure.os.path.exists', return_value=True), \
             mock.patch('configure.subprocess.run') as run, \
             contextlib.redirect_stdout(output):
            if timeout:
                run.side_effect = side_effect
            else:
                run.return_value = result
            status = configure.run_holo_integration_test()
        return status, output.getvalue()

    def test_clean_zero_exit_with_pass_marker_succeeds(self):
        status, _ = self.run_case(stdout='[HOLOTEST] ALL CHECKS PASSED\n')
        self.assertEqual(status, 0)

    def test_nonzero_exit_with_pass_marker_fails(self):
        status, output = self.run_case(returncode=11,
                                       stdout='[HOLOTEST] ALL CHECKS PASSED\n')
        self.assertEqual(status, 1)
        self.assertIn('FAILED', output)

    def test_timeout_with_pass_marker_fails(self):
        status, output = self.run_case(
            stdout='[HOLOTEST] ALL CHECKS PASSED\n', timeout=True)
        self.assertEqual(status, 1)
        self.assertIn('FAILED', output)

    def test_failure_marker_fails_even_with_zero_exit(self):
        status, _ = self.run_case(stdout='[HOLOTEST] FAIL: missing node\n')
        self.assertEqual(status, 1)

    def test_missing_pass_marker_fails(self):
        status, _ = self.run_case(stdout='normal engine output\n')
        self.assertEqual(status, 1)


if __name__ == '__main__':
    unittest.main()
