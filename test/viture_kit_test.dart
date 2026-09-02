import 'package:test/test.dart';
import 'package:viture_kit/viture_kit.dart'; // or package:viture_sensors/viture_kit.dart

void main() {
  late VitureKit vitureKit;

  setUp(() {
    vitureKit = VitureKit();
  });

  tearDown(() async {
    // Always release so the next test (and SpaceWalker) can use the IMU
    await vitureKit.releaseHeadTracking();
  });

  test(
    'viture sensors stream emits data when head tracking is taken',
    () async {
      // Take ownership of the IMU
      await vitureKit.takeHeadTracking();

      // Verify stream emits at least one valid ViturePoseData object
      expect(vitureKit.poseStream, emits(isA<ViturePoseData>()));
    },
  );

  test('imu stream data contains non-null sensor fields', () async {
    await vitureKit.takeHeadTracking();

    final data = await vitureKit.poseStream.first.timeout(
      const Duration(seconds: 3),
    );

    expect(data.timestamp, isA<int>());
    expect(data.quatX, isA<double>());
    expect(data.quatY, isA<double>());
    expect(data.quatZ, isA<double>());
    expect(data.quatW, isA<double>());
    expect(data.roll, isA<double>());
    expect(data.pitch, isA<double>());
    expect(data.yaw, isA<double>());
  });

  test('isHeadTrackingActive reflects current state', () async {
    expect(vitureKit.isHeadTrackingActive, isFalse);

    await vitureKit.takeHeadTracking();
    expect(vitureKit.isHeadTrackingActive, isTrue);

    await vitureKit.releaseHeadTracking();
    expect(vitureKit.isHeadTrackingActive, isFalse);
  });

  test('setHeadTrackingEnabled convenience method works', () async {
    expect(vitureKit.isHeadTrackingActive, isFalse);

    await vitureKit.setHeadTrackingEnabled(true);
    expect(vitureKit.isHeadTrackingActive, isTrue);

    await vitureKit.setHeadTrackingEnabled(false);
    expect(vitureKit.isHeadTrackingActive, isFalse);
  });
}
