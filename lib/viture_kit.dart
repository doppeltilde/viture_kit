import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'viture_kit_bindings_generated.dart' as bindings;

/// Formatted Pose data read from the glasses (roll, pitch, yaw, and orientation quaternion).
class ViturePoseData {
  final double roll;
  final double pitch;
  final double yaw;
  final double quatW;
  final double quatX;
  final double quatY;
  final double quatZ;
  final int timestamp;

  const ViturePoseData({
    required this.roll,
    required this.pitch,
    required this.yaw,
    required this.quatW,
    required this.quatX,
    required this.quatY,
    required this.quatZ,
    required this.timestamp,
  });

  @override
  String toString() =>
      'ViturePoseData(PRY: [$pitch, $roll, $yaw], Quat: [$quatW, $quatX, $quatY, $quatZ], ts: $timestamp)';
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
  StreamController<ViturePoseData>? _poseController;

  /// Public broadcast stream exposing 3DoF pose data updates.
  Stream<ViturePoseData> get poseStream {
    _poseController ??= StreamController<ViturePoseData>.broadcast();
    return _poseController!.stream;
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
        _poseController?.add(
          ViturePoseData(
            roll: message['roll'] as double,
            pitch: message['pitch'] as double,
            yaw: message['yaw'] as double,
            quatW: message['quatW'] as double,
            quatX: message['quatX'] as double,
            quatY: message['quatY'] as double,
            quatZ: message['quatZ'] as double,
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

    // 4. Bind Pose Callback using exact signature: (float* data, uint64_t timestamp)
    final nativeCallback =
        ffi.NativeCallable<bindings.VitureImuPoseCallbackFunction>.listener((
          ffi.Pointer<ffi.Float> dataPtr,
          int timestamp,
        ) {
          if (dataPtr == ffi.nullptr) return;

          // Parse float array layout according to header:
          // [roll, pitch, yaw, quaternion_w, quaternion_x, quaternion_y, quaternion_z]
          config.sendPort.send({
            'roll': dataPtr[0],
            'pitch': dataPtr[1],
            'yaw': dataPtr[2],
            'quatW': dataPtr[3],
            'quatX': dataPtr[4],
            'quatY': dataPtr[5],
            'quatZ': dataPtr[6],
            'timestamp': timestamp,
          });
        });

    // 5. Register callback and open IMU Pose stream (@ 60Hz)
    api.xr_device_provider_register_imu_pose_callback(
      provider,
      nativeCallback.nativeFunction,
    );

    // Open pose stream using matching mode
    api.xr_device_provider_open_imu(
      provider,
      VitureImuMode.pose,
      VitureImuFrequency.freq60Hz,
    );

    // 6. Listen for cleanup commands from main isolate
    commandPort.listen((message) {
      if (message == _ControlCommand.stop) {
        // Must pass matching VitureImuMode.pose to close_imu
        api.xr_device_provider_close_imu(provider, VitureImuMode.pose);
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
    _poseController?.close();
    _workerIsolate = null;
    _poseController = null;
    _commandPort = null;
  }
}
