import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'viture_kit_bindings_generated.dart' as bindings;

/// Formatted IMU sensor data read from the glasses.
class VitureImuData {
  final double gyroX;
  final double gyroY;
  final double gyroZ;
  final double accelX;
  final double accelY;
  final double accelZ;
  final int timestamp;

  const VitureImuData({
    required this.gyroX,
    required this.gyroY,
    required this.gyroZ,
    required this.accelX,
    required this.accelY,
    required this.accelZ,
    required this.timestamp,
  });

  @override
  String toString() =>
      'VitureImuData(gyro: [$gyroX, $gyroY, $gyroZ], accel: [$accelX, $accelY, $accelZ], ts: $timestamp)';
}

/// Product IDs for VITURE XR Glasses models.
abstract class VitureProductId {
  static const int vitureOne = 0x35CA;
  static const int viturePro = 0x35CB;
  static const int viturePro2 = 0x1301;
}

/// IMU constants matching VITURE protocol.
abstract class VitureImuMode {
  static const int raw = 0;
  static const int pose = 1;
}

abstract class VitureImuFrequency {
  static const int freq60Hz = 1;
  static const int freq120Hz = 2;
  static const int freq240Hz = 3;
}

class _IsolateInitConfig {
  final SendPort sendPort;
  final String dylibPath;
  final int productId;

  const _IsolateInitConfig(this.sendPort, this.dylibPath, this.productId);
}

enum _ControlCommand { stop }

class VitureKit {
  Isolate? _workerIsolate;
  ReceivePort? _receivePort;
  SendPort? _commandPort;
  StreamController<VitureImuData>? _imuController;

  /// Public broadcast stream exposing IMU data updates.
  Stream<VitureImuData> get imuStream {
    _imuController ??= StreamController<VitureImuData>.broadcast();
    return _imuController!.stream;
  }

  /// Resolve dynamic library location for macOS.
  static String _resolveDylibPath() {
    if (Platform.isMacOS) {
      return 'glasses.framework/glasses';
    }
    throw UnsupportedError(
      'Platform not supported: ${Platform.operatingSystem}',
    );
  }

  /// Start the hardware reader pipeline on a background isolate.
  Future<void> start({int productId = VitureProductId.viturePro2}) async {
    if (_workerIsolate != null) return;

    _receivePort = ReceivePort();
    final dylibPath = _resolveDylibPath();

    _receivePort!.listen((dynamic message) {
      if (message is SendPort) {
        _commandPort = message;
      } else if (message is Map<String, dynamic>) {
        _imuController?.add(
          VitureImuData(
            gyroX: message['gyroX'] as double,
            gyroY: message['gyroY'] as double,
            gyroZ: message['gyroZ'] as double,
            accelX: message['accelX'] as double,
            accelY: message['accelY'] as double,
            accelZ: message['accelZ'] as double,
            timestamp: message['timestamp'] as int,
          ),
        );
      }
    });

    _workerIsolate = await Isolate.spawn(
      _backgroundSensorWorker,
      _IsolateInitConfig(_receivePort!.sendPort, dylibPath, productId),
    );
  }

  /// Worker task executed in worker isolate.
  static void _backgroundSensorWorker(_IsolateInitConfig config) {
    final commandPort = ReceivePort();
    config.sendPort.send(commandPort.sendPort);

    // 1. Open dynamic library & bind API
    final dylib = ffi.DynamicLibrary.open(config.dylibPath);
    final api = bindings.VitureKitBindings(dylib);

    // 2. Create device provider instance
    final provider = api.xr_device_provider_create(config.productId);
    if (provider == ffi.nullptr) {
      return;
    }

    // 3. Initialize & Start provider
    api.xr_device_provider_initialize(provider, ffi.nullptr, ffi.nullptr);
    api.xr_device_provider_start(provider);

    sleep(const Duration(milliseconds: 1000));

    // 4. Bind raw IMU callback using exact generated type signature
    final nativeCallback =
        ffi.NativeCallable<bindings.VitureImuRawCallbackFunction>.listener((
          ffi.Pointer<ffi.Float> dataPtr,
          int timestamp,
          int vsync,
        ) {
          if (dataPtr == ffi.nullptr) return;

          // Parse float array layout:
          // [0..2] -> Gyro X, Y, Z
          // [3..5] -> Accel X, Y, Z
          final gyroX = dataPtr[0];
          final gyroY = dataPtr[1];
          final gyroZ = dataPtr[2];
          final accelX = dataPtr[3];
          final accelY = dataPtr[4];
          final accelZ = dataPtr[5];
          final magX = dataPtr[6];
          final magY = dataPtr[7];
          final magZ = dataPtr[8];
          final temperature = dataPtr[9];

          config.sendPort.send({
            'gyroX': gyroX,
            'gyroY': gyroY,
            'gyroZ': gyroZ,
            'accelX': accelX,
            'accelY': accelY,
            'accelZ': accelZ,
            'timestamp': timestamp,
            "magX": magX,
            "magY": magY,
            "magZ": magZ,
            "temperature": temperature,
          });
        });

    // 5. Register callback and open IMU stream (Raw mode @ 60Hz)
    api.xr_device_provider_register_imu_raw_callback(
      provider,
      nativeCallback.nativeFunction,
    );
    api.xr_device_provider_open_imu(
      provider,
      VitureImuMode.pose,
      VitureImuFrequency.freq60Hz,
    );

    // 6. Listen for cleanup commands from main isolate
    commandPort.listen((message) {
      if (message == _ControlCommand.stop) {
        api.xr_device_provider_close_imu(provider, VitureImuMode.raw);
        api.xr_device_provider_stop(provider);
        api.xr_device_provider_shutdown(provider);
        api.xr_device_provider_destroy(provider);
        nativeCallback.close();
        commandPort.close();
        Isolate.exit();
      }
    });
  }

  /// Gracefully shutdown hardware streams and isolates.
  Future<void> stop() async {
    _commandPort?.send(_ControlCommand.stop);
    _receivePort?.close();
    _imuController?.close();
    _workerIsolate = null;
    _imuController = null;
    _commandPort = null;
  }
}
