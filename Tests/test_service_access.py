import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('service_access', Path(__file__).resolve().parents[1] / 'skills/openconnect-native/scripts/service_access.py')
access = importlib.util.module_from_spec(spec)
spec.loader.exec_module(access)


class ServiceAccessTests(unittest.TestCase):
    def test_http_errors_never_connect_vpn(self):
        for code in (200, 302, 401, 403, 405, 503):
            exchange = Mock()
            with patch.object(access.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, str(code), '')):
                result = access.ensure('https://example.test', exchange, Mock(), 5)
            self.assertTrue(result['ok'])
            self.assertEqual(result['probe']['httpStatus'], code)
            exchange.assert_not_called()

    def test_certificate_failure_does_not_connect(self):
        exchange = Mock()
        with patch.object(access.subprocess, 'run', return_value=subprocess.CompletedProcess([], 60, '000', 'private details')):
            result = access.ensure('https://example.test', exchange, Mock(), 5)
        self.assertFalse(result['ok'])
        exchange.assert_not_called()
        self.assertNotIn('private details', str(result))

    def test_on_demand_connects_once_then_stops_for_otp(self):
        exchange = Mock(side_effect=[{'ok': True, 'state': 'disconnected'}, {'ok': True}])
        wait = Mock(return_value={'ok': True, 'state': 'otpRequired', 'attemptID': 'attempt'})
        with patch.object(access, 'enabled', return_value=True), patch.object(access, 'probe', return_value={'reachable': False, 'networkFailure': True, 'category': 'dns'}):
            result = access.ensure('https://example.test', exchange, wait, 55)
        self.assertEqual(result['state'], 'otpRequired')
        self.assertEqual(exchange.call_count, 2)
        self.assertEqual(exchange.call_args.args[0], {'command': 'connect'})

    def test_never_reconnects_active_or_failed_vpn(self):
        for state in ('connected', 'failed', 'authenticating'):
            exchange = Mock(return_value={'ok': True, 'state': state})
            with patch.object(access, 'enabled', return_value=True), patch.object(access, 'probe', return_value={'reachable': False, 'networkFailure': True}):
                result = access.ensure('https://example.test', exchange, Mock(), 55)
            self.assertFalse(result['ok'])
            self.assertEqual(exchange.call_count, 1)

    def test_policy_is_explicit_and_persistent(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(access, 'CONFIG', Path(directory) / 'policy.json'):
            self.assertFalse(access.enabled())
            access.set_policy(True)
            self.assertTrue(access.enabled())
            access.set_policy(False)
            self.assertFalse(access.enabled())

    def test_rejects_credentials_and_signed_urls(self):
        for url in ('http://example.test', 'https://user:secret@example.test', 'https://example.test/?token=secret'):
            with self.assertRaises(ValueError):
                access.validate_url(url)
