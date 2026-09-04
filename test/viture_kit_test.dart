import 'package:test/test.dart';

class ViturePoseData {
  final int timestamp;
  final double quatX;
  final double quatY;
  final double quatZ;
  final double quatW;
  final double roll;
  final double pitch;
  final double yaw;

  ViturePoseData({
    required this.timestamp,
    required this.quatX,
    required this.quatY,
    required this.quatZ,
    required this.quatW,
    required this.roll,
    required this.pitch,
    required this.yaw,
  });
}

class FakeVitureKit {
  bool _isHeadTrackingActive = false;

  bool get isHeadTrackingActive => _isHeadTrackingActive;

  Stream<ViturePoseData> get poseStream async* {
    if (_isHeadTrackingActive) {
      yield ViturePoseData(
        timestamp: 123456789,
        quatX: 0.0,
        quatY: 0.0,
        quatZ: 0.0,
        quatW: 1.0,
        roll: 0.0,
        pitch: 0.0,
        yaw: 0.0,
      );
    }
  }

  Future<void> takeHeadTracking() async {
    _isHeadTrackingActive = true;
  }

  Future<void> releaseHeadTracking() async {
    _isHeadTrackingActive = false;
  }

  Future<void> setHeadTrackingEnabled(bool enable) async {
    _isHeadTrackingActive = enable;
  }
}

void main() {
  late FakeVitureKit vitureKit;

  setUp(() {
    vitureKit = FakeVitureKit();
  });

  tearDown(() async {
    await vitureKit.releaseHeadTracking();
  });

  test(
    'viture sensors stream emits data when head tracking is taken',
    () async {
      await vitureKit.takeHeadTracking();
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
