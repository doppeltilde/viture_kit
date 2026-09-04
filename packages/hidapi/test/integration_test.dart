@Tags(['hardware'])
library;

import 'package:hidapi/hidapi.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(hidInit);
  tearDownAll(hidExit);

  test('enumerate finds at least one HID device', () {
    final devices = hidEnumerate();
    print('Found ${devices.length} HID device(s):');
    for (final d in devices) {
      print('  $d');
    }
    expect(devices, isNotEmpty);
  });
}
