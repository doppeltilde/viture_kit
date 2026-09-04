import 'package:hidapi/hidapi.dart';

class HIDAPIHelper {
  static const vitureVendorId = 0x35ca;

  static Set<int> fetchHidapiVitureProductIds() {
    final productIds = <int>{};

    hidInit();

    try {
      final devices = hidEnumerate(vendorId: vitureVendorId, productId: 0);

      for (final device in devices) {
        productIds.add(device.productId);
      }
    } finally {
      hidExit();
    }

    return productIds;
  }
}
