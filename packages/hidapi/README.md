# hidapi

Dart FFI bindings for [hidapi](https://github.com/libusb/hidapi) — the
cross-platform C library for USB and Bluetooth HID device access.

Compiles hidapi 0.15.0 from source at build time via
[Dart build hooks](https://dart.dev/interop/c-interop). No system-level
hidapi installation required.

## Why this package?

- **Pure Dart.** No Flutter dependency. Works in CLI tools, servers, and
  any Dart application.
- **Modern build.** Uses Dart 3.10 native build hooks to compile hidapi
  from vendored source. No manual toolchain setup beyond a C compiler.
- **Complete API.** Wraps every public hidapi function — enumerate, open,
  read/write, feature and input reports, report descriptors, string
  queries, device info, and version introspection.

## Platform support

| Platform | Backend          |
|----------|------------------|
| Windows  | `windows/hid.c`  |
| macOS    | `mac/hid.c`      |
| Linux    | `linux/hid.c`    |

## Requirements

- Dart SDK >=3.10.0
- A C toolchain (MSVC, Clang, or GCC) reachable by `native_toolchain_c`
- Linux: `libudev-dev` (or equivalent)

## Install

```sh
dart pub add hidapi
```

## Usage

```dart
import 'package:hidapi/hidapi.dart';

void main() {
  hidInit();
  try {
    // List all HID devices (0, 0 = match any VID/PID)
    final devices = hidEnumerate();
    for (final d in devices) {
      print('${d.manufacturer} ${d.product} — ${d.path}');
    }

    // Open a specific device by path
    if (devices.isNotEmpty) {
      final dev = hidOpenPath(devices.first.path);
      try {
        dev.setNonBlocking(true);
        final data = dev.read(64, timeout: Duration(milliseconds: 100));
        print('Read ${data.length} bytes');
      } finally {
        dev.close();
      }
    }
  } finally {
    hidExit();
  }
}
```

## API

Top-level functions: `hidInit`, `hidExit`, `hidEnumerate`, `hidOpen`,
`hidOpenPath`, `hidVersion`, `hidVersionStr`.

`HidDevice` wraps an open device handle with methods for read/write,
feature and input reports, report descriptors, string queries, and
non-blocking mode.

See the [API reference](https://pub.dev/documentation/hidapi/latest/)
for full details.

## How the build works

The Dart build hook downloads a pinned, SHA-256-verified hidapi tarball
on first build and caches it. No manual steps beyond a C toolchain.

## Upstream

[libusb/hidapi](https://github.com/libusb/hidapi) — originally
[signal11/hidapi](https://github.com/signal11/hidapi), now maintained
under the [libusb](https://github.com/libusb) org.

## Issues and contributions

File bugs and feature requests on the
[issue tracker](https://github.com/repentsinner/hidapi/issues).

## License

See [LICENSE](LICENSE).
