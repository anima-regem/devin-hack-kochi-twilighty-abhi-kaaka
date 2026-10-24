# Change log

## 2026-10-24T21:53:05+05:30 — Correct Devin Hack Kochi event guidance

- Changed: corrected the current event name and AI tool guidance in `.github/pull_request_template.md`, `AGENTS.md`, `AI_USAGE.md`, `CHANGELOG.md`, `README.md`, `RULES.md`, `SUBMISSION.md`.
- Why: the organizer shared an older event template; Devin Hack Kochi has no
  major AI usage constraints and the template must not require a particular AI provider.
- Scope: preserved project implementation and historical assistance records.
- Removed obsolete template logistics, participation limits, and credit promises; current organizer instructions remain authoritative.
- Validation: reviewed documentation diffs, checked whitespace with `git diff --check`, and checked local Markdown links for new breakage.
- Limitations: maintainer review is pending; application tests were not run for this documentation-only correction.

Record each meaningful project change during the event, newest first. Update this file in the same commit as the change. Use a real timestamp with timezone, for example `YYYY-MM-DDTHH:MM:SS+05:30`.

## Event build log

## 2026-10-24T21:50:00+05:30 — Rename project to Kaaka

- Changed: Renamed RakshaNet / Rakshak / realm-hack to Kaaka across apps, server, dashboard, backend, scripts, hfp-bridge and docs. Android app IDs and Java packages are now `com.kaaka.sensors` (client) and `com.kaaka.callapp` (gateway). The client now sends "Kaaka Alert: …"; the server and dashboard accept both "Kaaka" and legacy "Rakshak" alerts (`ALERT_TAGS` / `has_alert_tag` in `server/server.py`) so older app builds still work. Also adds the nested READMEs and `.gitignore` files that the import commit missed.
- Why: New project name.
- Validation: `swift build -c release` for hfp-bridge; Python syntax check of server, audio bridge, mac telephony client and scripts; `git grep` shows "Rakshak" only in the intentional legacy matching.
- Limitations: Changed app IDs mean the Android apps install as new apps (permissions and default-SMS role must be granted again). `gateway/RakshaNet.apk` and `client/RakshakSensors.apk` are still the old prebuilt apps until rebuilt.

## 2026-10-24T21:40:00+05:30 — Run the call server on macOS via hfp-bridge

- Changed: Added `mac/hfp-bridge` (Swift, IOBluetooth Hands-Free client that emits JSON-line events and accepts answer/hangup/status/quit commands, with a reconnect watchdog and caller-ID via CLIP/CLCC) and `server/mac_telephony.py` (subprocess client). `server/server.py` and `server/audio_bridge.py` guard Linux-only imports and, on macOS, use hfp-bridge for call detection, answer and hangup; auto-answer defaults off on macOS. Added `server/requirements-mac.txt` and a macOS section in the README. Also imported `subprocess` in `server.py`, which the ADB telemetry thread needed (it failed silently before, including on Linux).
- Why: Run the server side on a MacBook (Apple Silicon) with a Galaxy S23 as the hands-free audio gateway.
- Validation: `swift build -c release` with no warnings; Python compile checks; server run against a stub bridge (CALL_DETECTED broadcast, hangup/answer commands, /api/status, missing-binary path); live run with the real bridge and S23 on 2026-10-24: HFP connected, real incoming call detected with caller number, 1-ring hangup sent and call ended.
- Limitations: No call audio on macOS (SCO unsupported), so the AI voice loop is disabled there. Bluetooth MAP SMS is Linux-only; the gateway app sends the auto-reply SMS. First HFP connect attempt after start can time out (20 s) before the retry succeeds.

## 2026-10-24T21:30:00+05:30 — Import RakshaNet call and telemetry system

- Changed: Imported the existing RakshaNet code from the separate `phone-connector` folder: `client/` (Capacitor sensor + default-SMS app), `gateway/` (Capacitor call/SMS gateway app), `server/` (Python PipeWire/oFono call server, audio bridge, dashboard, Node telemetry backend), `scripts/`, prebuilt APKs, and its README as the project README.
- Why: Consolidate the project into this repository before porting the server to macOS and renaming it.
- Validation: Content copied unchanged from the original folder (dependency/build folders and runtime telemetry data excluded); no code changes in this commit.
- Limitations: Server side is Linux-only at this point (PipeWire, BlueZ, D-Bus). This code was written before this repository was created; it was not built from scratch here.

## 2026-10-24T21:20:00+05:30 — Add hfptest Bluetooth hands-free feasibility tool

- Changed: Added `tools/hfptest` (Swift package, IOBluetooth) that lists paired devices with HFP Audio Gateway SDP status, connects to a phone as a Hands-Free unit, logs indicators/incoming calls, answers calls, requests SCO audio and records any Bluetooth input device to WAV.
- Why: Check whether a MacBook (Apple Silicon, macOS 27) can replace the Linux PipeWire hands-free setup used by the call server.
- Validation: Built with `swift build`; live tests against a Galaxy S23 on 2026-10-24: HFP connection PASS, incoming call detected PASS, answer from Mac worked, SCO audio FAIL (`kIOReturnUnsupported`, 0xE00002C7), no Bluetooth CoreAudio device appeared.
- Limitations: macOS does not provide HFP call audio (SCO) to apps; only call control works. `connect()` silently does nothing unless the baseband link is opened and SDP refreshed first (handled in the tool).

## Template setup — 10 October 2026

- Changed: Added the event README, rules, agent guide, change log, AI usage record, submission checklist, Git ignore rules, and pull request checklist.
- Why: Give participants a consistent starting point for event rules, basic coding patterns, documented changes, and regular commits.
- Validation: Checked local Markdown links, event detail consistency, required documents, and diff whitespace before publishing.
- Limitations: Documentation scaffolding only; no participant project, application, or working demo is included. GitHub publication and template status are verified separately after creation.
