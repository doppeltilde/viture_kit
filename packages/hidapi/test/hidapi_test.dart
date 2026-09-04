import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';
import 'package:hidapi/hidapi.dart';
import 'package:hidapi/src/hidapi_bindings.g.dart';
import 'package:test/test.dart';

void main() {
  group('struct layout', () {
    test('hid_api_version has 3 int fields', () {
      // major, minor, patch — each 4 bytes = 12 bytes minimum.
      expect(sizeOf<hid_api_version>(), greaterThanOrEqualTo(12));
    });

    test('hid_device_info is non-trivial size', () {
      // Contains multiple pointer and integer fields.
      // On 64-bit: ~10 pointers (8 bytes each) + several shorts/ints.
      expect(sizeOf<hid_device_info>(), greaterThan(40));
    });
  });

  group('native symbol resolution', () {
    test('hid_version resolves and returns valid version', () {
      final versionPtr = hid_version();
      expect(versionPtr, isNot(nullptr));
      final v = versionPtr.ref;
      expect(v.major, equals(0));
      expect(v.minor, equals(15));
      expect(v.patch, equals(0));
    });

    test('hid_version_str resolves and returns version string', () {
      final strPtr = hid_version_str();
      expect(strPtr, isNot(nullptr));
      final str = strPtr.cast<Utf8>().toDartString();
      expect(str, contains('0.15.0'));
    });

    test('hid_init and hid_exit succeed', () {
      expect(hid_init(), equals(0));
      expect(hid_exit(), equals(0));
    });
  });

  group('hidapi wrapper', () {
    test('hidVersion returns 0.15.0', () {
      final v = hidVersion();
      expect(v.major, equals(0));
      expect(v.minor, equals(15));
      expect(v.patch, equals(0));
    });

    test('hidVersionStr contains 0.15.0', () {
      expect(hidVersionStr(), contains('0.15.0'));
    });

    test('hidInit and hidExit succeed', () {
      hidInit();
      hidExit();
    });

    test('hidEnumerate returns a list (may be empty)', () {
      hidInit();
      try {
        final devices = hidEnumerate();
        expect(devices, isA<List<HidDeviceInfo>>());
      } finally {
        hidExit();
      }
    });

    test('hidOpenPath throws HidException for invalid path', () {
      hidInit();
      try {
        expect(() => hidOpenPath('nonexistent'), throwsA(isA<HidException>()));
      } finally {
        hidExit();
      }
    });

    test('hidOpen with VID/PID 0xFFFF/0xFFFF throws HidException', () {
      hidInit();
      try {
        expect(() => hidOpen(0xFFFF, 0xFFFF), throwsA(isA<HidException>()));
      } finally {
        hidExit();
      }
    });
  });

  group('darwin exclusive mode', () {
    test('hidDarwinGetOpenExclusive returns bool', () {
      hidInit();
      try {
        final val = hidDarwinGetOpenExclusive();
        expect(val, isA<bool>());
      } finally {
        hidExit();
      }
    });

    test('hidDarwinSetOpenExclusive accepts bool without throwing', () {
      hidInit();
      try {
        expect(() => hidDarwinSetOpenExclusive(false), returnsNormally);
      } finally {
        hidExit();
      }
    });

    test(
      'hidDarwinSetOpenExclusive round-trips value',
      () {
        hidInit();
        try {
          hidDarwinSetOpenExclusive(false);
          expect(hidDarwinGetOpenExclusive(), isFalse);
          hidDarwinSetOpenExclusive(true);
          expect(hidDarwinGetOpenExclusive(), isTrue);
        } finally {
          hidExit();
        }
      },
      skip: !Platform.isMacOS ? 'macOS-only' : null,
    );

    test(
      'hidDarwinGetOpenExclusive defaults to true after init',
      () {
        hidInit();
        try {
          // Per upstream docs, hid_init sets exclusive mode to true.
          expect(hidDarwinGetOpenExclusive(), isTrue);
        } finally {
          hidExit();
        }
      },
      skip: !Platform.isMacOS ? 'macOS-only' : null,
    );
  });
}
