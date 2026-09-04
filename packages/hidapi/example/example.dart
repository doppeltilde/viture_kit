import 'package:hidapi/hidapi.dart';

void main() {
  hidInit();
  try {
    final devices = hidEnumerate();
    print('Found ${devices.length} HID device(s):');
    for (final d in devices) {
      print('  ${d.manufacturer} ${d.product} — ${d.path}');
    }
  } finally {
    hidExit();
  }
}
