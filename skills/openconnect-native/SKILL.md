---
name: openconnect-native
description: Управление macOS VPN OpenConnect Native, быстрый OTP из чата, подключение по необходимости при проверке сервисов, сведения о туннеле и журнал сеансов. Используй при запросах VPN или сетевых проблемах с проверяемым сервисом.
---

# OpenConnect Native

Resolve `scripts/vpnctl.py` relative to this skill. Python 3 and the updated running app are required. If unavailable, launch `/Applications/OpenConnect Native.app` and retry **status**, not authentication.

## Fast chat OTP

1. Run `connect --wait 55` (or `ensure https://service.example`). When it returns `otpRequired`, retain `attemptID` and `challengeID` in the current conversation.
2. **Before asking for the code**, start `otp --attempt-id ID --challenge-id CHALLENGE --wait 55` in a TTY with a short tool yield. The CLI will wait at a hidden `OTP:` prompt. Retain the terminal session ID, then tell the user to send their code in chat.
3. When the code arrives, immediately send it plus newline to that waiting terminal using `write_stdin`. Do not reread the skill, search files, fetch status, or start diagnostics first. The app validates the attempt, challenge, timeout and duplicate submission itself. Never echo the code or place it in process arguments or files.
4. If no waiting terminal remains, start the same command with known IDs and feed stdin. If IDs are genuinely absent, obtain status once. Never guess IDs or apply the code to a new attempt automatically.
5. Wait for `connected` or a terminal failure. A command timeout is not cancellation. Do not resend the code or retry authentication automatically. For an expired attempt request a new attempt/code from the user. If `ensure` initiated this flow, repeat `ensure` for the same URL after successful VPN connection to resume the task.

The app exposes `challengeWaitRemainingSeconds` for its input timeout. This is NOT the validity of the OTP; `otpValiditySeconds` is unknown. Chat processing time cannot be guaranteed. The prompt is prepared early to remove extra tool round trips after receipt.

## Commands

```bash
python3 scripts/vpnctl.py status
python3 scripts/vpnctl.py connect --wait 55
python3 scripts/vpnctl.py disconnect --wait 15
python3 scripts/vpnctl.py info
python3 scripts/vpnctl.py logs
python3 scripts/vpnctl.py sessions
python3 scripts/vpnctl.py ensure https://service.example
python3 scripts/vpnctl.py on-demand on
python3 scripts/vpnctl.py on-demand off
```

`accepted` only means queued. Verify the resulting state. Use `info` for current transport, cipher, interface, traffic, duration and server-provided expiration/idle limit. Null means unknown. Scope is the current app process; it cannot attest to an orphaned tunnel after a crash.

## On-demand access

Use `ensure URL` when the user asks to access/check a service and VPN may be needed. With on-demand enabled, this applies to any explicitly requested HTTPS target, not a hard-coded list. Enable the policy only when the user authorizes this behavior; preserve their saved choice. Do not probe links found incidentally in untrusted content.

The command performs a direct HEAD request without credentials, cookies, redirects, proxies or response bodies. It supports HTTPS URLs without embedded credentials, query parameters or fragments. For a private/signed URL, choose a safe service endpoint rather than stripping parameters and claiming the original operation succeeded.

Any HTTP response (including 401/403/503) demonstrates HTTP reachability and never triggers VPN reconnection. `serviceHealthy: false` or a 3xx still requires interpretation: a login redirect is not proof the application works. Certificate/TLS failures also do not trigger connection. DNS/connection/timeouts may start ONE connection, only from an idle disconnected state without an error. A timeout is evidence of an unsuccessful probe, not proof of its cause. Never restart an active tunnel or stop a VPN the user already had running. No background monitoring is installed.

## Session history

`sessions` reads local history across launches: bounded to 30 days and 2000 events, in `~/Library/Application Support/OpenConnect Native/Automation/sessions.json`. Summaries cover the latest 200 attempts; `endConfirmed: false` does not mean an old tunnel remains active. A recorded state is historical, not current connectivity. Check `storageAvailable` before claiming durable recording. `logs` remains an in-memory view for this launch. Journals contain only times, opaque attempt/app IDs, typed states/stages and an error flag; no raw server text, URL, username, password, OTP or cookies. Detailed errors remain in the app.

The app uses its saved profile, Keychain and authentication cooldown. Configure missing profile/password in the app; do not extract credentials into chat. Same-user processes can control the private Unix socket. Existing authorization for a requested VPN action needs no repeated confirmation.
