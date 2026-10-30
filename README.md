# AVETemporalPoC — CVE-2026-112705 (AppleAVE2) Reproduction

Setting `NumberOfTemporalLayers` via VideoToolbox on iOS 27.0.1 triggers an out-of-bounds
write in the `AppleAVE2` kernel driver, resulting in a kernel panic (Kernel data abort).
This flaw was fixed in iOS 27.2.

- Component: AppleAVE2 (`com.apple.driver.AppleAVE2`)
- Type: kernel out-of-bounds write / denial of service (fixed-offset constant fill,
  **no** arbitrary read/write capability)
- Affected: iOS 27.0.1 (24A446)
- Fixed: iOS 27.2 (24B119)
- Original discovery: Calif / Chollima team (this repo reproduces their public
  findings on a real device for verification; no discovery claim is made)

## Trigger conditions

- Device: iPhone 17 Pro (`iPhone18,1`, T8150)
- `NumberOfTemporalLayers = 16463` (real threshold; 16462 survives)
- After `vtCompressionSessionCreate` returns 0, the first encode panics the kernel

## Observed behavior

- Panic: Kernel data abort, PC inside AppleAVE2 at `+0xDA78`
- Register fingerprint: `far = 0x59`, `x19 = 0x1` (with `N=16464`:
  `0x100000059` / `0x100000001`)
- Crashing process: `videocodecd`
- Same app, same parameters, on iOS 27.2: `NTL` returns `-12900` directly, no panic

## Project layout

```
AVETemporalPoC.xcodeproj
AVETemporalPoC/AVETemporalPoCApp.swift
AVETemporalPoC/ContentView.swift
AVETemporalPoC/Runner.swift      # trigger logic
panic-evidence/                  # panic logs exported from the device
```

Build: open the project in Xcode, set `DEVELOPMENT_TEAM` and
`PRODUCT_BUNDLE_IDENTIFIER`, deploy to a physical device (the simulator has no
VideoToolbox hardware encode path).

Trigger: run with the launch argument `--stage9 16463`
(Xcode → Scheme → Arguments Passed On Launch). 16462 survives, 16463 panics.
The stage9 log is written to `live.txt` in the App Documents directory; the last
line before the panic is `stage9(...) encode[0]`.

## Evidence

`panic-evidence/panic-full-2026-10-28-014135.0002.ips`
(iPhone OS 27.0.1 24A446, Kernel data abort, x0 = 0x100000059)

## Disclaimer

For authorized security research and vendor verification only. This is a crash
reproduction of an already-public CVE. It contains no exploitation code and
provides no read/write primitives. Do not use against systems you are not
authorized to test.
