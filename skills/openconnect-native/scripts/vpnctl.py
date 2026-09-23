#!/usr/bin/env python3
"""Control the installed OpenConnect Native app using a same-user Unix socket."""
import argparse
import getpass
import json
import os
from pathlib import Path
import socket
import stat
import sys
import time


def exchange(request):
    path = Path.home() / 'Library/Caches/ocnative/control.sock'
    for item in (path.parent, path):
        info = item.lstat()
        if info.st_uid != os.getuid() or info.st_mode & 0o077 or stat.S_ISLNK(info.st_mode):
            raise RuntimeError('Unsafe control socket permissions')
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(5)
        client.connect(str(path))
        client.sendall(json.dumps(request).encode() + b'\n')
        data = b''
        while not data.endswith(b'\n'):
            chunk = client.recv(65536)
            if not chunk:
                raise RuntimeError('App closed the connection without a response')
            data += chunk
            if len(data) > 1024 * 1024:
                raise RuntimeError('Response too large')
        return json.loads(data)


def wait_for_result(command, seconds):
    deadline = time.monotonic() + seconds
    while True:
        result = exchange({'command': 'status'})
        state = result.get('state')
        if not result.get('ok'):
            return result
        pending = result.get('operationPending')
        if command == 'disconnect':
            complete = state == 'disconnected'
        elif command == 'otp':
            # The pre-submission OTP snapshot can briefly survive a helper poll.
            complete = state in ('connected', 'failed', 'sessionExpired', 'disconnected')
        else:
            complete = state in ('connected', 'otpRequired', 'failed', 'sessionExpired', 'disconnected')
        if complete and not pending:
            result['ok'] = state == 'disconnected' if command == 'disconnect' else state in ('connected', 'otpRequired')
            return result
        if result.get('hasError') and not pending:
            return dict(result, ok=False)
        if time.monotonic() >= deadline:
            return dict(result, ok=False, error='wait_timeout_status_unconfirmed')
        time.sleep(0.2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['status', 'info', 'logs', 'sessions', 'connect', 'disconnect', 'otp', 'ensure', 'on-demand'])
    parser.add_argument('target', nargs='?', help='HTTPS URL for ensure; on/off for on-demand')
    parser.add_argument('--wait', type=float, default=None, metavar='SECONDS')
    parser.add_argument('--attempt-id', help='Required for otp; use attemptID from the connection response')
    parser.add_argument('--challenge-id', help='Bind OTP to the challenge returned by status')
    args = parser.parse_args()
    seconds = args.wait if args.wait is not None else (55 if args.command in ('otp', 'ensure') else 0)
    if not 0 <= seconds <= 120:
        parser.error('--wait must be between 0 and 120 seconds')
    request = {'command': args.command}
    if args.command == 'otp':
        if not args.attempt_id:
            parser.error('otp requires --attempt-id from the connection response')
        # Start this hidden prompt BEFORE asking the user for their code. Their
        # next message can then go straight to this process via terminal stdin.
        request.update(attemptID=args.attempt_id, otp=getpass.getpass('OTP: ') if sys.stdin.isatty() else sys.stdin.readline().strip())
        if args.challenge_id:
            request['challengeID'] = args.challenge_id
    try:
        if args.command in ('ensure', 'on-demand'):
            sys.path.insert(0, str(Path(__file__).resolve().parent))
            import service_access
            if args.command == 'on-demand':
                if args.target not in ('on', 'off'):
                    parser.error('on-demand requires on or off')
                result = service_access.set_policy(args.target == 'on')
            else:
                if not args.target:
                    parser.error('ensure requires an HTTPS URL')
                service_access.validate_url(args.target)
                result = service_access.ensure(args.target, exchange, wait_for_result, seconds)
        else:
            result = exchange(request)
            if result.get('ok') and seconds and args.command in ('connect', 'disconnect', 'otp'):
                result = wait_for_result(args.command, seconds)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0 if result.get('ok') else 1
    except (OSError, ValueError, RuntimeError):
        print(json.dumps({'ok': False, 'error': 'control_or_configuration_unavailable', 'action': 'Check URL/configuration and the updated app. Do not automatically repeat authentication.'}))
        return 2


if __name__ == '__main__':
    sys.exit(main())
