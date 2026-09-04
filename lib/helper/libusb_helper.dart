// ignore_for_file: depend_on_referenced_packages

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:dart_libusb/dart_libusb.dart';

class LibusbHelper {
  static const vitureVendorId = 0x35ca;

  static String _resolveLibUsbDylibPath() {
    if (Platform.isMacOS) {
      return 'usb-1.0.0.framework/usb-1.0.0';
    }

    throw UnsupportedError(
      'Platform not supported: ${Platform.operatingSystem}',
    );
  }

  static Set<int> fetchLibUsbVitureProductIds() {
    final productIds = <int>{};
    final libusb = Libusb(DynamicLibrary.open(_resolveLibUsbDylibPath()));

    final ctx = calloc<Pointer<libusb_context>>();
    if (libusb.libusb_init(ctx) != 0) return productIds;

    final list = calloc<Pointer<Pointer<libusb_device>>>();
    final count = libusb.libusb_get_device_list(ctx.value, list);

    for (var i = 0; i < count; i++) {
      final dev = list.value[i];
      final desc = calloc<libusb_device_descriptor>();

      if (libusb.libusb_get_device_descriptor(dev, desc) == 0) {
        if (desc.ref.idVendor == vitureVendorId) {
          productIds.add(desc.ref.idProduct);
        }
      }
      calloc.free(desc);
    }

    libusb.libusb_free_device_list(list.value, 1);
    calloc.free(list);
    libusb.libusb_exit(ctx.value);
    calloc.free(ctx);

    return productIds;
  }
}
