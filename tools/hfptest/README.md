# hfptest

Minimal Swift CLI used to check whether a Mac can act as a Bluetooth Hands-Free unit (HFP HF) for an Android phone.

```
cd tools/hfptest && swift build
.build/debug/hfptest list [--sdp]                 # paired devices + HFP Audio Gateway service
.build/debug/hfptest connect <address> [--auto]   # then: answer | hangup | sco | devices | rec | status | q
```

Run from a terminal app that has Bluetooth permission (System Settings → Privacy & Security → Bluetooth).
An Info.plist with `NSBluetoothAlwaysUsageDescription` is embedded into the binary at link time.

Result on macOS 27.0.1 with a Galaxy S23: HFP connection, indicators, incoming-call detection and
answer work; `connectSCO` returns `kIOReturnUnsupported`, so call audio cannot reach the Mac.
`connect()` only works after the baseband link is opened and SDP is refreshed first.
