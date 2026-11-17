# Kardia ECG Reader for macOS

A small native Mac application that connects to a **KardiaMobile 6L** over
Bluetooth LE, displays six limb-lead traces and exports the original packets
alongside decoded samples. Built by Skjld Labs because we wanted to use the
device directly from a Mac.

**Experimental research software.** Voltage calibration, polarity and signal
integrity have not been medically validated. The app provides no diagnosis,
heart-rate calculation or clinical measurements. Use the official Kardia app
for medical recordings. This project is independent of AliveCor.

[Project story and real app screenshot](https://skjldlabs.com/blog/nytt-fra-labben-kardia-reader-mac)
· [Protocol notes](docs/protocol.md)
· [Contributing](CONTRIBUTING.md)

## What it does

- Discovers nearby Kardia-like Bluetooth advertisements and connects to a 6L.
- Reads battery level and firmware revision.
- Requests the observed M2 stream: two raw channels, with four further limb
  leads derived algebraically.
- Shows the latest approximately five seconds with independent autoscaling.
- Stops after approximately 30 seconds, on disconnect, after three seconds
  without ECG packets, or on an unexpected ECG payload length.
- Saves raw packets, decoded CSV and session metadata to a new local folder.
- Asks before replacing an unsaved recording or quitting normally.

The application uses SwiftUI, AppKit, CoreBluetooth and CryptoKit. There are no
third-party runtime dependencies, accounts, servers, cloud uploads or network
requests in the application. The user interface is currently **Norwegian**;
documentation and source comments are in English.

## Requirements

| Requirement | Supported setup |
| --- | --- |
| Computer | Apple Silicon Mac (`arm64`) |
| macOS | 14 or newer |
| Build tools | Full Xcode installed at `/Applications/Xcode.app` |
| Device | KardiaMobile 6L; local hardware testing used firmware 2.1.13 |
| Permissions | macOS Bluetooth access; normal pairing if requested |

The scripts currently use the standard full-Xcode compiler and SDK paths.
Command Line Tools alone and custom Xcode locations require adapting the two
scripts. Complete Xcode's first-run setup and review any license prompts
yourself before building. Intel Macs, other Kardia models and other firmware
versions have not been verified with this app.

## Build, test and run

```sh
git clone https://github.com/Skjld-labs/kardia-ecg-reader-macos-public.git
cd kardia-ecg-reader-macos-public

zsh test.sh
zsh build.sh
open "build/Kardia Reader.app"
```

`test.sh` compiles and runs the protocol/export tests. It does not access
Bluetooth or require a device. `build.sh` produces an optimized arm64 app with
an **ad-hoc local signature** in `build/Kardia Reader.app`. It neither installs
the app nor signs it with an Apple Developer identity or notarizes it.
No prebuilt downloadable release is currently provided.

For regular use, move the built app to `~/Applications` using Finder and open
it there. Keep a stable app location when granting Bluetooth access. The usage
description required by macOS is included in `Info.plist`.

## Record a session

1. Close the phone's Kardia app so it does not compete for the connection.
2. Enable Bluetooth on the Mac and choose **Søk etter 6L** (Search for 6L).
3. Allow Bluetooth access if macOS asks. Wake the 6L using electrode contact
   as described in the manufacturer's instructions.
4. Choose **Koble til og ta opp** (Connect and record) beside the device.
   Accept normal macOS pairing if requested; the app does not bypass bonding.
5. Follow the manufacturer's electrode-placement instructions for a six-lead
   recording, including the bottom electrode's skin contact.
6. Allow the session to stop automatically or choose **Stopp** (Stop).
7. Choose **Lagre opptak…** (Save recording) and select a new folder name.

Recordings remain **only in memory until saved**. A crash or force-quit loses
unsaved data. Starting another recording and normal quit show discard prompts.
Save first if you want to keep a session.

## Export format

Each successful save creates a new owner-accessible folder. Existing folders
are rejected rather than overwritten or mixed with another session.

| File | Contents |
| --- | --- |
| `raw-packets.csv` | Host receive times, characteristic UUID and hexadecimal bytes for every captured vendor notification, including command replies and malformed ECG packets |
| `samples.csv` | Valid decoded ECG frames, packet index, sample index within packet and six lead values in **uncalibrated raw counts** |
| `metadata.json` | Requested mode, assumed sample rate, firmware, packet/sample counts, elapsed time and explicit experimental/calibration flags |

CSV files begin with `#` comment lines. Skip these when importing them.
`packet` in `samples.csv` is a zero-based index into the complete raw packet
list, so it can skip command notifications and malformed ECG frames.
`sample_in_packet` runs from 0 to 8 for each valid M2 frame. Derived augmented
leads may include half counts and are exported with one decimal place.

Both wall-clock and monotonic elapsed timestamps describe **host packet
reception**. They are not device sample timestamps. The CSV does not invent a
continuous sample clock, interpolate missing data, filter signals or convert
counts into millivolts. See [protocol notes](docs/protocol.md) for the layout
and lead equations.

Each file is written atomically, but the folder is not one transaction: a
failed export can leave a partial folder. The app retains the in-memory
capture and reports the failure so you can save again under a new name.

## Architecture and code map

| File | Responsibility |
| --- | --- |
| `Sources/App.swift` | SwiftUI interface, `Reader` BLE lifecycle, bounded capture, trace rendering, save panel and quit protection |
| `Sources/Protocol.swift` | Service identifiers, compatibility command, M2 byte decoding, lead arithmetic and CSV serialization |
| `Sources/ProtocolTests.swift` | Synthetic protocol and export regression checks; no private ECG fixtures |
| `Info.plist` | Bundle metadata, minimum OS and Bluetooth permission description |
| `build.sh` / `test.sh` | Direct compiler invocations without a package manager or Xcode project |

CoreBluetooth delegates use the main queue, serializing acquisition with UI
state updates. Every captured vendor notification is appended before decoding.
The display is throttled to roughly 10 updates per second and retains the most
recent 1,500 samples per trace; the full raw packet list remains available for
export. Callbacks from a stopped peripheral are ignored using identity guards.

## Verification and limitations

The original local hardware run on **6 November 2026**, using firmware
**2.1.13**, verified scan, connect, service discovery, battery/firmware reads,
30-second acquisition, automatic stop and GUI export. It yielded **1,001 ECG
packets and 9,009 sample pairs**, with zero unexpected payload lengths.
Every exported value and receive timestamp was checked against the raw bytes.
The first-to-last receive cadence implied approximately **299.99 pairs/s**.
These are historical transport/export results for one setup, not a guarantee
of compatibility or medically accurate signals. Private recordings are not
included in this repository.

The automated suite covers signed little-endian decoding, wrong-length
rejection, derived-lead overflow, an M2 command test vector, preservation of
command/malformed notifications, CSV indexing/values and empty exports.
It does **not** cover the GUI, BLE state transitions, disconnects, filesystem
failure paths, signal quality or medical correctness.

Known limits and useful next steps:

- Calibration and polarity need independent reference validation.
- No device sequence tracking is implemented. Host arrival gaps can reflect
  batching or loss; average cadence cannot establish loss-free acquisition.
- Command reply bytes are preserved but their values are not validated. A
  successful write and a 36-byte frame alone do not prove the requested mode.
- Independent autoscaling prevents calibrated amplitude comparison across
  traces; the grid is decorative, not standard ECG paper.
- No crash recovery, recording library, reopening/replay UI or diagnostic
  classification is implemented.
- Export provenance could include a stop reason, capture start/end times,
  exact protocol revision and integrity hashes.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Compiler or SDK not found | Install full Xcode at the path above, or adapt `TOOLCHAIN` and `SDK` in both scripts |
| Xcode license/first-run error | Open Xcode and complete setup; the scripts do not accept agreements for you |
| No Bluetooth permission | Allow Kardia Reader in System Settings → Privacy & Security → Bluetooth |
| No device found | Close the phone app, wake the 6L and retry; the scan lasts 45 seconds |
| Connects but no ECG | Check electrode contact and any pending macOS pairing prompt; setup timeouts stop cleanly |
| Unexpected packet format | Save the raw data privately; keep decoding stopped until the format is understood |
| Save fails | Choose a new folder name and check available space/permissions; inspect any partial folder before retrying |

`~/Library/Application Support/Kardia Reader/status.json` contains bounded
connection events and counters for local troubleshooting. The app does not
deliberately log ECG bytes, device names, serials, UUIDs or command tokens
there; OS error descriptions may still contain diagnostic context. Review
logs before sharing them.

## Privacy and contributing

Saved ECG data can be sensitive. Keep recordings private. The repository
excludes build outputs, captures, local diagnostics, reference downloads and
private project/blog state. Tests use synthetic values only.

See [CONTRIBUTING.md](CONTRIBUTING.md) for reporting reproducible problems
without uploading recordings or device identifiers. Changes should preserve
raw data and keep assumptions visible.

## Attribution and licensing

This Swift implementation follows public interoperability observations and
test vectors from [ShaneBreazeale/kardia-rs](https://github.com/ShaneBreazeale/kardia-rs)
at commit `1a4e6d5dbcb30fcb3335c109ac8d825396395568` (MIT OR Apache-2.0).
Credit goes to the kardia-rs contributors; see their
[protocol evidence](https://github.com/ShaneBreazeale/kardia-rs/blob/1a4e6d5dbcb30fcb3335c109ac8d825396395568/docs/re/kardia-6l.md).
The upstream Rust project, trained models and reporting/ML code are not
bundled, linked or implemented by this app.

Kardia and KardiaMobile are AliveCor trademarks. This is independent research
software with no affiliation with or endorsement by AliveCor.

This repository is publicly readable. No open-source license has been selected
for this implementation; third-party projects retain their own licenses.
