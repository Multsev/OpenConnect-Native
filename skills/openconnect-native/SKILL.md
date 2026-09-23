---
name: openconnect-native
description: Управление macOS VPN OpenConnect Native через Codex — подключить, отключить, посмотреть статус, безопасные логи и передать запрошенный OTP. Использует установленное приложение и его сохранённый профиль.
---

# OpenConnect Native

Use the bundled `scripts/vpnctl.py` with Python 3. Resolve the script relative to this skill directory. The app must be running; if unavailable, launch `/Applications/OpenConnect Native.app` with `open` and retry **status**. Never infer VPN state from a missing socket or a stale file.

```bash
python3 scripts/vpnctl.py status
python3 scripts/vpnctl.py connect --wait 55
python3 scripts/vpnctl.py disconnect --wait 15
python3 scripts/vpnctl.py logs
```

- Connection commands use the existing app profile, Keychain, helper and authentication cooldown. Configure missing gateway, group or password in the app. Do not read Keychain secrets into the conversation or change the privileged helper's trust rules.
- `accepted: true` means queued, not connected/disconnected. Verify `status` after a command. `connected` confirms the app's tunnel checks; it does not prove a particular corporate service is reachable. `scope: current_app_session` does not describe other VPN applications or sessions left by an earlier app crash.
- If state is `otpRequired`, ask the user to enter OTP in the app, or use `otp --attempt-id <attemptID>` with a hidden terminal prompt. If the user supplies a code explicitly, feed it through stdin; never put it in argv, a file, logs, or a commit. Do not request the primary password in chat. An OTP challenge is an intermediate result, not a successful connection.
- Do not retry authentication automatically after rejection, timeout, or an uncertain response. Read status/logs first; obey the existing cooldown. A command timeout does not cancel the operation. An explicit cancellation request uses `disconnect` and verifies the result.
- `logs` returns up to 200 safe state transitions plus up to 20 stage events in memory for this app launch. It intentionally excludes raw server text, passwords, OTP, cookies, gateway and username. `hasError` means inspect the app's error dialog if the safe stages do not explain the failure.
- Same-user processes can control the socket, including disconnecting the VPN. There is no network listener or root CLI. No extra confirmation is needed for a VPN action the user already requested.
