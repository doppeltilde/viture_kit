import 'package:test/test.dart';
import 'package:viture_kit/viture_kit.dart';

void main() {
  late VitureKit vitureKit;

  setUp(() {
    vitureKit = VitureKit();
  });

  tearDown(() async {
    await vitureKit.stop();
  });

  test('viture sensors stream emits data when started', () async {
    // Start sensor reader pipeline
    await vitureKit.start();

    // Verify stream emits at least one valid VitureImuData object
    expect(vitureKit.imuStream, emits(isA<VitureImuData>()));
  });

  test('imu stream data contains non-null sensor fields', () async {
    await vitureKit.start();

    final data = await vitureKit.imuStream.first;

    expect(data.timestamp, isA<int>());
    expect(data.gyroX, isA<double>());
    expect(data.accelX, isA<double>());
  });
}
