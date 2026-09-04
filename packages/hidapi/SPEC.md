# Spec: hidapi Dart bindings

## Problem §spec:problem

*Status: complete*

No Dart package provides complete, cross-platform access to USB and
Bluetooth HID devices. Developers resort to platform channels (Flutter
only) or incomplete FFI wrappers that require prebuilt binaries or
system-installed libraries.

## Scope §spec:scope

*Status: complete*

This package wraps the upstream [hidapi](https://github.com/libusb/hidapi)
C library. It shall expose every public function, struct, and enum from
`hidapi/hidapi.h`. Platform support shall match upstream: Windows, macOS,
and Linux. The package shall track upstream releases, adopting new versions
within a reasonable timeframe of their release. The wrapper shall remain
thin — no polling loops, isolate wrappers, or stream abstractions.
Application-level concurrency patterns vary by use case and belong in
consuming packages.

---

## API surface §spec:api-surface

*Status: complete*

Delivered in PR #1, #4, 2026-02-22.

The package shall expose an idiomatic Dart API that maps 1:1 to every
public function, struct, and enum in upstream `hidapi/hidapi.h`.

Deviations from the C API:

- Errors throw `HidException` (wrapping `hid_error()`) instead of
  returning sentinel values.
- `hidEnumerate` returns `List<HidDeviceInfo>` instead of a linked list.
  The list shall be empty (not null) when no devices match.
- `HidDevice.close()` shall be idempotent.
- `hidInit()` shall be called automatically by `hidEnumerate`, `hidOpen`,
  and `hidOpenPath` if not already initialized.
- String conversions shall handle platform `wchar_t` differences: UTF-16
  on Windows, UTF-32 on POSIX.
- `HidDevice.read` accepts an optional `Duration? timeout` parameter,
  dispatching to `hid_read` or `hid_read_timeout` accordingly.

---

## Platform support §spec:platform-support

*Status: complete*

Delivered in PR #1, 2026-02-22.

The package shall support every platform supported by upstream hidapi.
The build hook shall select the correct backend source file, frameworks,
and link libraries as defined by the upstream build system.

---

## Native source acquisition §spec:native-source-acquisition

*Status: complete*

Delivered in PR #2, 2026-02-22.

Git submodules are not viable: `dart pub get` does not recursively init
submodules, so consumers that depend on this package via pub.dev or a git
dependency would be missing the C source at build time.

Instead, the package acquires native source via a Dart 3.10 build hook
(`hook/build.dart`):

- The build hook shall download a pinned, SHA-256-verified tarball of
  upstream hidapi source on first build.
- The build hook shall delete the tarball and abort if the SHA-256 digest
  does not match the expected value.
- Subsequent builds shall reuse cached source without network access.
- `dart pub get` followed by `dart run` shall compile the native library
  with no manual steps beyond a C toolchain.

---

## Testing §spec:testing

*Status: complete*

Delivered in PR #1, #7, 2026-02-22.

HID devices require physical hardware. CI runners have none, so the test
strategy splits into two tiers:

- Unit tests shall verify FFI struct layouts, native symbol resolution,
  and all wrapper functions that do not require hardware. Error paths
  (invalid device path, invalid VID/PID) shall be tested.
- Integration tests requiring physical HID hardware shall be tagged
  `hardware` and skipped by default. Developers run these locally.

---

## CI/CD §spec:ci-cd

*Status: complete*

Delivered in PR #1, #5, #7, #8, #9, #11, 2026-02-22.

This is a single-maintainer project. Releases should not require manual
steps beyond merging a PR. pub.dev requires semver; conventional commits
let release-please derive the correct version bump automatically.

- On every push to `main` and every pull request targeting `main`, CI
  shall run static analysis (`dart analyze --fatal-infos`), format
  checking (`dart format --set-exit-if-changed`), and tests (`dart test`).
- Commits shall follow conventional commit format so release-please can
  map them to semver bumps (`feat` → minor, `fix` → patch,
  `BREAKING CHANGE` → major).
- release-please shall create version-bump PRs from those commits.
- Release PRs with the `autorelease: pending` label shall auto-merge
  after CI passes.

---

## macOS exclusive device access §spec:macos-exclusive-device-access

*Status: in progress*

On macOS, hidapi defaults to opening devices in exclusive mode
(`kIOHIDOptionsTypeSeizeDevice`). This is set by `hid_init()` calling
`hid_darwin_set_open_exclusive(1)` for backward compatibility.

Exclusive mode prevents a second `hid_open_path` call on the same device
path within the same process — the `IOHIDDeviceOpen` call fails. This
breaks applications that open separate read and write handles from
different Dart isolates (isolates share process memory, so the C-level
`device_open_options` global is visible to all threads).

The package shall expose the macOS-specific exclusive mode control:

- `hidDarwinSetOpenExclusive(bool exclusive)` — sets the global open mode.
  No-op on Linux and Windows where the symbol does not exist.
- `hidDarwinGetOpenExclusive()` — returns the current setting.
  Returns `false` on non-macOS platforms.

The FFI bindings file shall include `hid_darwin_set_open_exclusive` and
`hid_darwin_get_open_exclusive`. The Dart wrappers shall guard calls with
a platform check (attempt the native call; catch the symbol-not-found
error on non-macOS) so that consuming code does not need conditional
imports.

---

## Publishing §spec:publishing

*Status: not started*

Downstream projects should be able to depend on this package with
`dart pub add hidapi` rather than git dependencies or local paths.

- The package shall be published to pub.dev.
- Publishing is manual for now. Automated publishing may follow once the
  API stabilizes.
