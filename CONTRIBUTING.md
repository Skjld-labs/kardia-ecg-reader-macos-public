# Contributing

Keep changes focused on reliable capture, inspectable data and explicit
protocol assumptions. Read [README](README.md) and [protocol notes](docs/protocol.md)
before changing acquisition or decoding.

## Local checks

```sh
zsh test.sh
zsh build.sh
git diff --check
```

Protocol/export tests use synthetic data and need no device. Changes to the
BLE lifecycle or interface also need a hardware/manual check; a passing
protocol suite does not verify those paths. State what you tested, the
macOS/firmware versions, and what remains unverified in the pull request.

## Reporting an issue

Include the app version or commit, macOS version, device model, firmware,
steps to reproduce, expected result and actual behavior. Small synthetic
packet examples are preferable to real recordings.

Do not attach ECG recordings, device serials/names/UUIDs, pairing material,
command values from your device, credentials or private filesystem paths.
Review any copied diagnostics before posting. If a problem needs private
evidence, describe that need without publishing the evidence in an issue.

## Implementation expectations

- Preserve the original notification before decoding it.
- Stop on unknown formats rather than guessing how to display them.
- Distinguish host timestamps, assumed rates and observed device behavior.
- Keep main-queue state handling and stopped-peripheral guards intact.
- Document calibration and validation limits alongside affected output.
- Add focused regression coverage when changing decoder/export behavior.
- Keep generated builds and personal captures out of commits.

Public availability does not establish an open-source license. Discuss
licensing with the maintainers before assuming reuse rights.
