import 'package:hidapi/hidapi.dart';

class HIDAPIHelper {
  static const vitureVendorId = 0x35ca;

  static Set<int> fetchHidapiVitureProductIds({
    bool setDarwinOpenExclusive = false,
  }) {
    final productIds = <int>{};

    hidInit();

    try {
      hidDarwinSetOpenExclusive(setDarwinOpenExclusive);

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
