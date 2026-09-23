"""Direct, bounded HTTPS probes and one-shot on-demand VPN connection."""
import json
import os
from pathlib import Path
import subprocess
from urllib.parse import urlsplit

CONFIG = Path.home() / 'Library/Application Support/OpenConnect Native/Automation/on-demand.json'


def set_policy(enabled):
    CONFIG.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(CONFIG.parent, 0o700)
    temporary = CONFIG.with_suffix('.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump({'enabled': enabled}, stream)
    os.replace(temporary, CONFIG)
    return {'ok': True, 'onDemandEnabled': enabled}


def enabled():
    try:
        return json.loads(CONFIG.read_text()).get('enabled') is True
    except (OSError, ValueError):
        return False


def validate_url(url):
    parsed = urlsplit(url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.fragment or parsed.query:
        raise ValueError('Use an HTTPS URL without credentials, query parameters or fragments')
    _ = parsed.port  # Validate malformed ports before running curl.
    return url


def probe(url):
    validate_url(url)
    try:
        result = subprocess.run([
            '/usr/bin/curl', '--disable', '--silent', '--head', '--output', '/dev/null',
            '--write-out', '%{http_code}', '--connect-timeout', '3', '--max-time', '5',
            '--noproxy', '*', '--proto', '=https', '--url', url,
        ], capture_output=True, text=True, timeout=7)
    except subprocess.TimeoutExpired:
        return {'reachable': False, 'category': 'timeout', 'networkFailure': True}
    categories = {6: 'dns', 7: 'connection', 28: 'timeout', 35: 'tls_handshake', 60: 'certificate'}
    if result.returncode == 0:
        code = int(result.stdout) if result.stdout.strip().isdigit() else 0
        return {'reachable': code > 0, 'category': 'http', 'httpStatus': code,
                'networkFailure': False, 'serviceHealthy': 200 <= code < 400}
    return {'reachable': False, 'category': categories.get(result.returncode, 'transport'),
            'networkFailure': result.returncode in (6, 7, 28)}


def ensure(url, exchange, wait_for_result, seconds):
    # A HEAD response, including 401/403/503, proves HTTP reachability. Do not
    # resend authentication or restart an existing VPN in response to it.
    first = probe(url)
    if first['reachable'] or not first['networkFailure']:
        return {'ok': first['reachable'], 'probe': first, 'vpnStarted': False}
    if not enabled():
        return {'ok': False, 'error': 'on_demand_disabled', 'probe': first, 'vpnStarted': False}
    status = exchange({'command': 'status'})
    if not status.get('ok'):
        return status
    state = status.get('state')
    if state == 'connected':
        return {'ok': False, 'error': 'service_unreachable_with_vpn', 'probe': first, 'vpnStarted': False}
    if state == 'otpRequired':
        return dict(status, probe=first, vpnStarted=False, action='supply_otp_then_repeat_ensure')
    if state != 'disconnected' or status.get('hasError') or status.get('operationPending'):
        return {'ok': False, 'error': 'vpn_not_idle_no_automatic_retry', 'vpn': status, 'probe': first}
    accepted = exchange({'command': 'connect'})
    if not accepted.get('ok'):
        return accepted
    status = wait_for_result('connect', seconds)
    if status.get('state') == 'otpRequired':
        return dict(status, probe=first, vpnStarted=True, action='supply_otp_then_repeat_ensure')
    if not status.get('ok') or status.get('state') != 'connected':
        return dict(status, probe=first, vpnStarted=True)
    final = probe(url)
    return {'ok': final['reachable'], 'probe': final, 'vpnStarted': True}
