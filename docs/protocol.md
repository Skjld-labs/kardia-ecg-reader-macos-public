# Observed M2 protocol and export assumptions

This describes the implemented behavior so it can be reviewed and tested.
It is based on public interoperability observations, not an official protocol
specification. See the attribution and limitations in [README](../README.md).

## BLE characteristics

| Role | UUID | Required property |
| --- | --- | --- |
| Six-lead service | `AC060001-328C-A28F-9846-5A8AA212661B` | Service |
| Command | `AC060002-328C-A28F-9846-5A8AA212661B` | Write with response, indicate |
| ECG | `AC060003-328C-A28F-9846-5A8AA212661B` | Notify |

The app also reads standard battery (`2A19`) and firmware (`2A26`)
characteristics when available. Candidate advertisements match a Kardia-like
name or the vendor service; discovery then checks the required GATT interface.

## Connection sequence

1. Scan without a service filter because some advertisements omit the UUID.
2. Connect through CoreBluetooth and discover vendor/device-info/battery services.
3. Wait for characteristic discovery across all requested services.
4. Enable command indications.
5. Write the observed compatibility command with response.
6. After the successful write callback, enable ECG notifications.
7. Preserve received vendor notifications before attempting ECG decoding.

The M2 command is UTF-8 text: `M2 K` followed by the first eight SHA-256
digest bytes encoded as 16 lowercase hexadecimal characters. The hashed input
is `Triangle` concatenated with the advertised local device name. The generic
`Kardia6L` test name is a public test vector, not a real user's device name.
Normal OS authentication/bonding is still required; this command does not
replace it. Do not publish an individual's device names or command values.

Command reply bytes are recorded without interpretation. The app currently
does not check that a reply confirms M2; this is a known validation gap.

## ECG frame

Only **36-byte** ECG notifications are accepted: nine consecutive sample
pairs, each containing signed little-endian 16-bit channel I then channel II.

```text
byte offset     0       2       4       6             32      34
              I[0]   II[0]   I[1]   II[1]   ...     I[8]   II[8]
              <i16   <i16    <i16   <i16            <i16   <i16
```

`Int16(bitPattern:)` preserves the signed interpretation; no status-bit
masking, voltage conversion, smoothing or interpolation is applied.
Unexpected lengths cause acquisition to stop. The raw packet remains in the
session, while `samples.csv` contains only successfully decoded frames.

## Derived leads

Values are promoted to `Double` before arithmetic to avoid Int16 overflow
and preserve half-count results. Export/display order is:

```text
I   = I
II  = II
III = II - I
aVR = -(I + II) / 2
aVL = I - II / 2
aVF = II - I / 2
```

Lead labels follow the upstream channel-mapping observations. These equations
do not establish voltage calibration, correct polarity or electrode contact.

## Timing and integrity

- The rate of 300 sample pairs/s is assumed, not negotiated with the device.
- `received_unix_s` uses `Date` at notification delivery.
- `received_elapsed_s` uses monotonic system uptime relative to connection setup.
- The session timer starts at the first valid ECG notification, so its displayed
  duration has a different origin from the exported elapsed receive time.
- Samples within each packet are indexed 0–8, without invented device timestamps.
- Packet size and mean cadence cannot prove loss-free acquisition; no sequence
  counter is decoded or checked.

The display window of 1,500 samples is approximately five seconds only under
the assumed 300 Hz rate. Its independent vertical autoscaling and decorative
grid must not be interpreted as calibrated ECG paper.
