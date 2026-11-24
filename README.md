# Threadwork

A native macOS quick-access network monitor. Open from the dotted menu-bar icon or **Control–Option–Space**; dismiss with Escape or by clicking away. No Dock icon.

## Build and open

Requires macOS 14+ and the Swift 6.2 toolchain (Xcode).

```sh
bash scripts/build-app.sh --install
open ~/Applications/Threadwork.app --args --show
```

## 1.0

- Dot-matrix download and upload charts show this Mac’s actual interface traffic over the last 60 samples. Each chart labels its own changing scale. Bytes/sec here; bits/sec in speed-test results.
- Scan discovers observed devices on the connected local IPv4 network using its neighbor table and an optional active sweep. The sweep covers at most this Mac’s /24, or the actual subnet when smaller; a neighbor-table entry does not prove a device is still online. It cannot find every sleeping, isolated, or firewalled device. Allow local-network access if macOS asks. VPN-primary interfaces and active scans of public ranges are not supported.
- Run Check measures internet and router latency, packet loss, DNS lookup time, and upload/download speed. Speed checks use Apple’s `networkQuality` service and can transfer substantial data. The confirmation explains external probes. ICMP may be blocked; unavailable measurements are not treated as healthy. DNS timing uses `dig`’s default configured resolver, which does not reproduce macOS split-DNS routing.
- Name known networks and devices, and keep the last 30 checks per network. Data stays in `~/Library/Application Support/Threadwork/networks.json`.
- History uses the router’s hardware address rather than assuming identical IP ranges are the same home. Hardware addresses can change; this is recognition, not authentication. When no router address is available, the app does not merge network history. Device nicknames also require a stable device address. Wi-Fi names may be unavailable due to macOS privacy restrictions.
- Other devices’ bandwidth is explicitly unavailable: there is no router integration in 1.0, no traffic attribution by guesswork, and no per-app traffic accounting.

Remembered checks are individual observations, not proof that a particular device caused a slowdown. A comparison to the previous check is not a long-term network baseline.

For a live UI capture during development:

```sh
open build/Threadwork.app --args --capture /tmp/threadwork.png
```

The capture is of the actual running panel after six seconds, with live network readings, not sample data.
