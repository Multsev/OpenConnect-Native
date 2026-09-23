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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['status', 'logs', 'connect', 'disconnect', 'otp'])
    parser.add_argument('--wait', type=float, default=0, metavar='SECONDS', help='Wait for connect/disconnect/otp completion; stops at OTP challenge')
    parser.add_argument('--attempt-id', help='Required for otp; take attemptID from status')
    args = parser.parse_args()
    if not 0 <= args.wait <= 120:
        parser.error('--wait must be between 0 and 120 seconds')
    request = {'command': args.command}
    if args.command == 'otp':
        if not args.attempt_id:
            parser.error('otp requires --attempt-id from status')
        request.update(attemptID=args.attempt_id, otp=getpass.getpass('OTP: ') if sys.stdin.isatty() else sys.stdin.readline().strip())
    try:
        result = exchange(request)
        if result.get('ok') and args.wait and args.command in ('connect', 'disconnect', 'otp'):
            deadline = time.monotonic() + args.wait
            while True:
                result = exchange({'command': 'status'})
                state = result.get('state')
                if not result.get('ok'):
                    break
                if args.command == 'disconnect':
                    complete = state == 'disconnected' and not result.get('operationPending')
                else:
                    complete = state in ('connected', 'otpRequired', 'failed', 'sessionExpired') or (state == 'disconnected' and not result.get('operationPending'))
                if complete and not result.get('operationPending'):
                    result['ok'] = state in ('connected', 'otpRequired') if args.command != 'disconnect' else True
                    break
                if result.get('hasError') and not result.get('operationPending'):
                    result['ok'] = False
                    break
                if time.monotonic() >= deadline:
                    result.update(ok=False, error='wait_timeout_status_unconfirmed')
                    break
                time.sleep(0.3)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0 if result.get('ok') else 1
    except (OSError, ValueError, RuntimeError):
        print(json.dumps({'ok': False, 'error': 'control_unavailable', 'action': 'Open the updated OpenConnect Native app and retry status. Do not automatically repeat authentication.'}))
        return 2


if __name__ == '__main__':
    sys.exit(main())
