// Hand-written FFI bindings for hidapi 0.15.0.
// Equivalent to what ffigen would generate from hidapi/hidapi.h.
// ignore_for_file: type=lint

import 'dart:ffi';

// --- Enums ---

/// HID underlying bus types.
final class hid_bus_type {
  static const int HID_API_BUS_UNKNOWN = 0x00;
  static const int HID_API_BUS_USB = 0x01;
  static const int HID_API_BUS_BLUETOOTH = 0x02;
  static const int HID_API_BUS_I2C = 0x03;
  static const int HID_API_BUS_SPI = 0x04;
}

// --- Structs ---

/// Opaque hid_device handle (never dereferenced from Dart).
final class hid_device extends Opaque {}

/// hidapi version info.
final class hid_api_version extends Struct {
  @Int32()
  external int major;

  @Int32()
  external int minor;

  @Int32()
  external int patch;
}

/// HID device info linked-list node.
final class hid_device_info extends Struct {
  /// Platform-specific device path.
  external Pointer<Char> path;

  /// Vendor ID.
  @UnsignedShort()
  external int vendor_id;

  /// Product ID.
  @UnsignedShort()
  external int product_id;

  /// Serial number (wide string).
  external Pointer<WChar> serial_number;

  /// Device release number (BCD).
  @UnsignedShort()
  external int release_number;

  /// Manufacturer string (wide string).
  external Pointer<WChar> manufacturer_string;

  /// Product string (wide string).
  external Pointer<WChar> product_string;

  /// Usage page (Windows/Mac/hidraw only).
  @UnsignedShort()
  external int usage_page;

  /// Usage (Windows/Mac/hidraw only).
  @UnsignedShort()
  external int usage;

  /// USB interface number (-1 if not USB).
  @Int32()
  external int interface_number;

  /// Next device in linked list.
  external Pointer<hid_device_info> next;

  /// Underlying bus type.
  @Int32()
  external int bus_type;
}

// --- Functions ---

@Native<Int32 Function()>()
external int hid_init();

@Native<Int32 Function()>()
external int hid_exit();

@Native<Pointer<hid_device_info> Function(UnsignedShort, UnsignedShort)>()
external Pointer<hid_device_info> hid_enumerate(int vendorId, int productId);

@Native<Void Function(Pointer<hid_device_info>)>()
external void hid_free_enumeration(Pointer<hid_device_info> devs);

@Native<
  Pointer<hid_device> Function(UnsignedShort, UnsignedShort, Pointer<WChar>)
>()
external Pointer<hid_device> hid_open(
  int vendorId,
  int productId,
  Pointer<WChar> serialNumber,
);

@Native<Pointer<hid_device> Function(Pointer<Char>)>()
external Pointer<hid_device> hid_open_path(Pointer<Char> path);

@Native<Void Function(Pointer<hid_device>)>()
external void hid_close(Pointer<hid_device> dev);

@Native<Int32 Function(Pointer<hid_device>, Pointer<UnsignedChar>, Size)>()
external int hid_read(
  Pointer<hid_device> dev,
  Pointer<UnsignedChar> data,
  int length,
);

@Native<
  Int32 Function(Pointer<hid_device>, Pointer<UnsignedChar>, Size, Int32)
>()
external int hid_read_timeout(
  Pointer<hid_device> dev,
  Pointer<UnsignedChar> data,
  int length,
  int milliseconds,
);

@Native<Int32 Function(Pointer<hid_device>, Pointer<UnsignedChar>, Size)>()
external int hid_write(
  Pointer<hid_device> dev,
  Pointer<UnsignedChar> data,
  int length,
);

@Native<Int32 Function(Pointer<hid_device>, Pointer<UnsignedChar>, Size)>()
external int hid_send_feature_report(
  Pointer<hid_device> dev,
  Pointer<UnsignedChar> data,
  int length,
);

@Native<Int32 Function(Pointer<hid_device>, Pointer<UnsignedChar>, Size)>()
external int hid_get_feature_report(
  Pointer<hid_device> dev,
  Pointer<UnsignedChar> data,
  int length,
);

@Native<Int32 Function(Pointer<hid_device>, Pointer<UnsignedChar>, Size)>()
external int hid_get_input_report(
  Pointer<hid_device> dev,
  Pointer<UnsignedChar> data,
  int length,
);

@Native<Int32 Function(Pointer<hid_device>, Pointer<UnsignedChar>, Size)>()
external int hid_get_report_descriptor(
  Pointer<hid_device> dev,
  Pointer<UnsignedChar> buf,
  int bufLen,
);

@Native<Int32 Function(Pointer<hid_device>, Pointer<WChar>, Size)>()
external int hid_get_manufacturer_string(
  Pointer<hid_device> dev,
  Pointer<WChar> string,
  int maxlen,
);

@Native<Int32 Function(Pointer<hid_device>, Pointer<WChar>, Size)>()
external int hid_get_product_string(
  Pointer<hid_device> dev,
  Pointer<WChar> string,
  int maxlen,
);

@Native<Int32 Function(Pointer<hid_device>, Pointer<WChar>, Size)>()
external int hid_get_serial_number_string(
  Pointer<hid_device> dev,
  Pointer<WChar> string,
  int maxlen,
);

@Native<Int32 Function(Pointer<hid_device>, Int32, Pointer<WChar>, Size)>()
external int hid_get_indexed_string(
  Pointer<hid_device> dev,
  int stringIndex,
  Pointer<WChar> string,
  int maxlen,
);

@Native<Int32 Function(Pointer<hid_device>, Int32)>()
external int hid_set_nonblocking(Pointer<hid_device> dev, int nonblock);

@Native<Pointer<WChar> Function(Pointer<hid_device>)>()
external Pointer<WChar> hid_error(Pointer<hid_device> dev);

@Native<Pointer<hid_device_info> Function(Pointer<hid_device>)>()
external Pointer<hid_device_info> hid_get_device_info(Pointer<hid_device> dev);

@Native<Pointer<hid_api_version> Function()>()
external Pointer<hid_api_version> hid_version();

@Native<Pointer<Char> Function()>()
external Pointer<Char> hid_version_str();

// --- macOS-only (hidapi_darwin.h) ---

@Native<Void Function(Int32)>()
external void hid_darwin_set_open_exclusive(int openExclusive);

@Native<Int32 Function()>()
external int hid_darwin_get_open_exclusive();
