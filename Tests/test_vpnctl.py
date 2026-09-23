import contextlib
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('vpnctl', Path(__file__).resolve().parents[1] / 'skills/openconnect-native/scripts/vpnctl.py')
vpnctl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vpnctl)


class ControlCLITests(unittest.TestCase):
    def run_command(self, args, responses):
        output = io.StringIO()
        with patch('sys.argv', ['vpnctl'] + args), patch.object(vpnctl, 'exchange', side_effect=responses) as exchange, patch.object(vpnctl.time, 'sleep'), contextlib.redirect_stdout(output):
            code = vpnctl.main()
        return code, json.loads(output.getvalue()), exchange.call_count

    def test_wait_does_not_mistake_old_failed_state_for_new_result(self):
        code, result, calls = self.run_command(['connect', '--wait', '5'], [
            {'ok': True, 'accepted': True},
            {'ok': True, 'state': 'failed', 'operationPending': True},
            {'ok': True, 'state': 'connected', 'operationPending': False},
        ])
        self.assertEqual(code, 0)
        self.assertEqual(result['state'], 'connected')
        self.assertEqual(calls, 3)

    def test_otp_is_intermediate_result_without_retry(self):
        code, result, calls = self.run_command(['connect', '--wait', '5'], [
            {'ok': True}, {'ok': True, 'state': 'otpRequired', 'operationPending': False},
        ])
        self.assertEqual(code, 0)
        self.assertEqual(result['state'], 'otpRequired')
        self.assertEqual(calls, 2)

    def test_unavailable_is_not_disconnected(self):
        code, result, calls = self.run_command(['status'], [FileNotFoundError()])
        self.assertEqual(code, 2)
        self.assertNotIn('state', result)
        self.assertEqual(calls, 1)

    def test_disconnect_error_is_not_success(self):
        code, result, _ = self.run_command(['disconnect', '--wait', '5'], [
            {'ok': True}, {'ok': True, 'state': 'connecting', 'hasError': True, 'operationPending': False},
        ])
        self.assertEqual(code, 1)
        self.assertFalse(result['ok'])

    def test_otp_wait_ignores_old_otp_required_snapshot(self):
        with patch('sys.stdin', io.StringIO('fixture-code\n')):
            code, result, calls = self.run_command(['otp', '--attempt-id', 'attempt', '--wait', '5'], [
                {'ok': True, 'accepted': True},
                {'ok': True, 'state': 'otpRequired', 'operationPending': False},
                {'ok': True, 'state': 'connected', 'operationPending': False},
            ])
        self.assertEqual(code, 0)
        self.assertEqual(result['state'], 'connected')
        self.assertEqual(calls, 3)


if __name__ == '__main__':
    unittest.main()
