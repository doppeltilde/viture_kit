/// Cross-platform Dart bindings for hidapi.
///
/// Provides idiomatic Dart access to USB HID devices via the proven hidapi
/// C library, compiled from vendored source at build time.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'src/hidapi_bindings.g.dart' as ffi;

/// Exception thrown when a hidapi operation fails.
class HidException implements Exception {
  HidException(this.message);
  final String message;

  @override
  String toString() => 'HidException: $message';
}

/// Bus type for a HID device.
enum HidBusType {
  unknown,
  usb,
  bluetooth,
  i2c,
  spi;

  static HidBusType _fromNative(int value) => switch (value) {
    ffi.hid_bus_type.HID_API_BUS_USB => usb,
    ffi.hid_bus_type.HID_API_BUS_BLUETOOTH => bluetooth,
    ffi.hid_bus_type.HID_API_BUS_I2C => i2c,
    ffi.hid_bus_type.HID_API_BUS_SPI => spi,
    _ => unknown,
  };
}

/// Information about a discovered HID device.
class HidDeviceInfo {
  const HidDeviceInfo({
    required this.path,
    required this.vendorId,
    required this.productId,
    this.serialNumber = '',
    this.releaseNumber = 0,
    this.manufacturer = '',
    this.product = '',
    this.usagePage = 0,
    this.usage = 0,
    this.interfaceNumber = -1,
    this.busType = HidBusType.unknown,
  });

  final String path;
  final int vendorId;
  final int productId;
  final String serialNumber;
  final int releaseNumber;
  final String manufacturer;
  final String product;
  final int usagePage;
  final int usage;
  final int interfaceNumber;
  final HidBusType busType;

  @override
  String toString() =>
      'HidDeviceInfo(vid: 0x${vendorId.toRadixString(16)}, '
      'pid: 0x${productId.toRadixString(16)}, '
      'usagePage: 0x${usagePage.toRadixString(16)}, '
      'usage: 0x${usage.toRadixString(16)}, '
      'path: $path)';
}

/// Handle to an open HID device.
///
/// Obtain via [hidOpen] or [hidOpenPath]. Must be [close]d when done.
class HidDevice {
  HidDevice._(this._ptr);

  Pointer<ffi.hid_device> _ptr;
  bool _closed = false;

  void _ensureOpen() {
    if (_closed) throw HidException('Device is closed');
  }

  /// Read up to [maxLength] bytes with optional [timeout].
  ///
  /// Returns the bytes read. Returns empty list if no data available
  /// (non-blocking mode or timeout expired).
  /// Throws [HidException] on error.
  Uint8List read(int maxLength, {Duration? timeout}) {
    _ensureOpen();
    final buf = calloc<UnsignedChar>(maxLength);
    try {
      final int result;
      if (timeout != null) {
        result = ffi.hid_read_timeout(
          _ptr,
          buf,
          maxLength,
          timeout.inMilliseconds,
        );
      } else {
        result = ffi.hid_read(_ptr, buf, maxLength);
      }
      if (result < 0) {
        throw HidException(_getDeviceError());
      }
      if (result == 0) return Uint8List(0);
      return Uint8List.fromList(buf.cast<Uint8>().asTypedList(result));
    } finally {
      calloc.free(buf);
    }
  }

  /// Write data to the device. The first byte must be the report ID
  /// (0x00 for single-report devices).
  ///
  /// Returns the number of bytes written. Throws [HidException] on error.
  int write(Uint8List data) {
    _ensureOpen();
    final buf = calloc<UnsignedChar>(data.length);
    try {
      buf.cast<Uint8>().asTypedList(data.length).setAll(0, data);
      final result = ffi.hid_write(_ptr, buf, data.length);
      if (result < 0) throw HidException(_getDeviceError());
      return result;
    } finally {
      calloc.free(buf);
    }
  }

  /// Send a feature report. The first byte must be the report ID.
  ///
  /// Returns the number of bytes sent. Throws [HidException] on error.
  int sendFeatureReport(Uint8List data) {
    _ensureOpen();
    final buf = calloc<UnsignedChar>(data.length);
    try {
      buf.cast<Uint8>().asTypedList(data.length).setAll(0, data);
      final result = ffi.hid_send_feature_report(_ptr, buf, data.length);
      if (result < 0) throw HidException(_getDeviceError());
      return result;
    } finally {
      calloc.free(buf);
    }
  }

  /// Get a feature report. [data] must have the report ID as the first byte.
  ///
  /// Returns the report data (including report ID as first byte).
  /// Throws [HidException] on error.
  Uint8List getFeatureReport(int reportId, int maxLength) {
    _ensureOpen();
    final buf = calloc<UnsignedChar>(maxLength);
    try {
      buf[0] = reportId;
      final result = ffi.hid_get_feature_report(_ptr, buf, maxLength);
      if (result < 0) throw HidException(_getDeviceError());
      return Uint8List.fromList(buf.cast<Uint8>().asTypedList(result));
    } finally {
      calloc.free(buf);
    }
  }

  /// Enable or disable non-blocking reads.
  void setNonBlocking(bool nonblock) {
    _ensureOpen();
    final result = ffi.hid_set_nonblocking(_ptr, nonblock ? 1 : 0);
    if (result < 0) throw HidException(_getDeviceError());
  }

  /// Get an input report. Sets [reportId] as the first byte of the buffer.
  ///
  /// Returns the report data (including report ID as first byte).
  /// Throws [HidException] on error.
  Uint8List getInputReport(int reportId, int maxLength) {
    _ensureOpen();
    final buf = calloc<UnsignedChar>(maxLength);
    try {
      buf[0] = reportId;
      final result = ffi.hid_get_input_report(_ptr, buf, maxLength);
      if (result < 0) throw HidException(_getDeviceError());
      return Uint8List.fromList(buf.cast<Uint8>().asTypedList(result));
    } finally {
      calloc.free(buf);
    }
  }

  /// Get the HID report descriptor.
  ///
  /// Returns up to [maxLength] bytes of the raw report descriptor.
  /// Throws [HidException] on error.
  Uint8List getReportDescriptor(int maxLength) {
    _ensureOpen();
    final buf = calloc<UnsignedChar>(maxLength);
    try {
      final result = ffi.hid_get_report_descriptor(_ptr, buf, maxLength);
      if (result < 0) throw HidException(_getDeviceError());
      return Uint8List.fromList(buf.cast<Uint8>().asTypedList(result));
    } finally {
      calloc.free(buf);
    }
  }

  /// Get the manufacturer string.
  ///
  /// Throws [HidException] on error.
  String getManufacturerString() {
    _ensureOpen();
    final buf = calloc<WChar>(256);
    try {
      final result = ffi.hid_get_manufacturer_string(_ptr, buf, 256);
      if (result < 0) throw HidException(_getDeviceError());
      return _wcharToString(buf);
    } finally {
      calloc.free(buf);
    }
  }

  /// Get the product string.
  ///
  /// Throws [HidException] on error.
  String getProductString() {
    _ensureOpen();
    final buf = calloc<WChar>(256);
    try {
      final result = ffi.hid_get_product_string(_ptr, buf, 256);
      if (result < 0) throw HidException(_getDeviceError());
      return _wcharToString(buf);
    } finally {
      calloc.free(buf);
    }
  }

  /// Get the serial number string.
  ///
  /// Throws [HidException] on error.
  String getSerialNumberString() {
    _ensureOpen();
    final buf = calloc<WChar>(256);
    try {
      final result = ffi.hid_get_serial_number_string(_ptr, buf, 256);
      if (result < 0) throw HidException(_getDeviceError());
      return _wcharToString(buf);
    } finally {
      calloc.free(buf);
    }
  }

  /// Get an indexed string.
  ///
  /// Throws [HidException] on error.
  String getIndexedString(int index) {
    _ensureOpen();
    final buf = calloc<WChar>(256);
    try {
      final result = ffi.hid_get_indexed_string(_ptr, index, buf, 256);
      if (result < 0) throw HidException(_getDeviceError());
      return _wcharToString(buf);
    } finally {
      calloc.free(buf);
    }
  }

  /// Get device info for this open device.
  HidDeviceInfo? getDeviceInfo() {
    _ensureOpen();
    final ptr = ffi.hid_get_device_info(_ptr);
    if (ptr == nullptr) return null;
    return _deviceInfoFromNative(ptr.ref);
  }

  /// Close the device and release resources.
  void close() {
    if (_closed) return;
    _closed = true;
    ffi.hid_close(_ptr);
    _ptr = nullptr;
  }

  String _getDeviceError() {
    final errPtr = ffi.hid_error(_ptr);
    if (errPtr == nullptr) return 'Unknown error';
    return errPtr.cast<Utf16>().toDartString();
  }
}

/// Initialize the hidapi library.
///
/// Not strictly required — called automatically by [hidEnumerate] and
/// [hidOpenPath]. Call explicitly if multiple threads may open devices
/// simultaneously.
void hidInit() {
  final result = ffi.hid_init();
  if (result < 0) throw HidException('hid_init failed');
}

/// Finalize the hidapi library and free static data.
void hidExit() {
  final result = ffi.hid_exit();
  if (result < 0) throw HidException('hid_exit failed');
}

/// Enumerate connected HID devices.
///
/// Pass 0 for [vendorId] or [productId] to match all.
List<HidDeviceInfo> hidEnumerate({int vendorId = 0, int productId = 0}) {
  final head = ffi.hid_enumerate(vendorId, productId);
  if (head == nullptr) return [];
  try {
    final results = <HidDeviceInfo>[];
    var current = head;
    while (current != nullptr) {
      results.add(_deviceInfoFromNative(current.ref));
      current = current.ref.next;
    }
    return results;
  } finally {
    ffi.hid_free_enumeration(head);
  }
}

/// Open a HID device by vendor/product ID.
///
/// Optionally filter by [serialNumber]. Throws [HidException] on failure.
HidDevice hidOpen(int vendorId, int productId, {String? serialNumber}) {
  Pointer<WChar> serialPtr = nullptr;
  try {
    if (serialNumber != null) {
      // Encode as platform wchar_t (UTF-16 on Windows, UTF-32 on POSIX).
      if (sizeOf<WChar>() == 2) {
        final units = serialNumber.codeUnits;
        serialPtr = calloc<WChar>(units.length + 1);
        final p = serialPtr.cast<Uint16>();
        for (var i = 0; i < units.length; i++) {
          p[i] = units[i];
        }
        p[units.length] = 0;
      } else {
        final runes = serialNumber.runes.toList();
        serialPtr = calloc<WChar>(runes.length + 1);
        final p = serialPtr.cast<Uint32>();
        for (var i = 0; i < runes.length; i++) {
          p[i] = runes[i];
        }
        p[runes.length] = 0;
      }
    }
    final dev = ffi.hid_open(vendorId, productId, serialPtr);
    if (dev == nullptr) {
      final errPtr = ffi.hid_error(nullptr);
      final msg = errPtr != nullptr
          ? errPtr.cast<Utf16>().toDartString()
          : 'Failed to open device';
      throw HidException(msg);
    }
    return HidDevice._(dev);
  } finally {
    if (serialPtr != nullptr) calloc.free(serialPtr);
  }
}

/// Open a HID device by its platform-specific path.
///
/// The path is obtained from [HidDeviceInfo.path] via [hidEnumerate].
/// Throws [HidException] on failure.
HidDevice hidOpenPath(String path) {
  final pathPtr = path.toNativeUtf8().cast<Char>();
  try {
    final dev = ffi.hid_open_path(pathPtr);
    if (dev == nullptr) {
      final errPtr = ffi.hid_error(nullptr);
      final msg = errPtr != nullptr && errPtr != nullptr
          ? errPtr.cast<Utf16>().toDartString()
          : 'Failed to open device';
      throw HidException(msg);
    }
    return HidDevice._(dev);
  } finally {
    calloc.free(pathPtr);
  }
}

/// Get the hidapi library version.
({int major, int minor, int patch}) hidVersion() {
  final v = ffi.hid_version();
  return (major: v.ref.major, minor: v.ref.minor, patch: v.ref.patch);
}

/// Get the hidapi library version as a string.
String hidVersionStr() {
  final ptr = ffi.hid_version_str();
  return ptr.cast<Utf8>().toDartString();
}

/// Set the macOS exclusive device open mode.
///
/// When `true`, subsequent [hidOpen] and [hidOpenPath] calls seize the device
/// exclusively (`kIOHIDOptionsTypeSeizeDevice`). Defaults to `true` after
/// [hidInit].
///
/// No-op on Linux and Windows where the symbol does not exist.
void hidDarwinSetOpenExclusive(bool exclusive) {
  try {
    ffi.hid_darwin_set_open_exclusive(exclusive ? 1 : 0);
  } on ArgumentError {
    // Symbol not available on this platform.
  }
}

/// Get the current macOS exclusive device open mode.
///
/// Returns `false` on non-macOS platforms where the symbol does not exist.
bool hidDarwinGetOpenExclusive() {
  try {
    return ffi.hid_darwin_get_open_exclusive() != 0;
  } on ArgumentError {
    return false;
  }
}

// --- Internal helpers ---

HidDeviceInfo _deviceInfoFromNative(ffi.hid_device_info info) {
  return HidDeviceInfo(
    path: info.path != nullptr ? info.path.cast<Utf8>().toDartString() : '',
    vendorId: info.vendor_id,
    productId: info.product_id,
    serialNumber: _wcharToString(info.serial_number),
    releaseNumber: info.release_number,
    manufacturer: _wcharToString(info.manufacturer_string),
    product: _wcharToString(info.product_string),
    usagePage: info.usage_page,
    usage: info.usage,
    interfaceNumber: info.interface_number,
    busType: HidBusType._fromNative(info.bus_type),
  );
}

String _wcharToString(Pointer<WChar> ptr) {
  if (ptr == nullptr) return '';
  // wchar_t is 2 bytes (UTF-16) on Windows, 4 bytes (UTF-32) on POSIX.
  if (sizeOf<WChar>() == 2) {
    return ptr.cast<Utf16>().toDartString();
  }
  // UTF-32: walk until null terminator, decode code points.
  final buf = StringBuffer();
  final p = ptr.cast<Uint32>();
  for (var i = 0; p[i] != 0; i++) {
    buf.writeCharCode(p[i]);
  }
  return buf.toString();
}
