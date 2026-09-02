import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'viture_kit_bindings_generated.dart' as bindings;

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

abstract class VitureProductId {
  static const int vitureOne = 0x35CA;
  static const int viturePro = 0x35CB;
  static const int viturePro2 = 0x1301;
}

abstract class VitureDisplayMode {
  static const int mode1920x1200_120Hz = 0;
  static const int mode3840x1200_90Hz = 1;
}

abstract class VitureDeviceType {
  static const int carina = 1;
}

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

  Stream<ViturePoseData> get poseStream {
    _poseController ??= StreamController<ViturePoseData>.broadcast();
    return _poseController!.stream;
  }

  static String _resolveDylibPath() {
    if (Platform.isMacOS) {
      return 'glasses.framework/glasses';
    }
    throw UnsupportedError(
      'Platform not supported: ${Platform.operatingSystem}',
    );
  }

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

  static void _backgroundSensorWorker(_IsolateInitConfig config) {
    final commandPort = ReceivePort();
    config.sendPort.send(commandPort.sendPort);

    final dylib = ffi.DynamicLibrary.open(config.dylibPath);
    final api = bindings.VitureKitBindings(dylib);

    final provider = api.xr_device_provider_create(config.productId);
    if (provider == ffi.nullptr) {
      return;
    }

    final deviceType = api.xr_device_provider_get_device_type(provider);

    if (api.xr_device_provider_initialize(provider, ffi.nullptr, ffi.nullptr) !=
        0) {
      api.xr_device_provider_destroy(provider);
      return;
    }

    // Switch display resolution to 3840x1200 3D Mode before starting streams
    api.xr_device_provider_set_display_mode(
      provider,
      VitureDisplayMode.mode3840x1200_90Hz,
    );

    sleep(const Duration(milliseconds: 500));

    if (api.xr_device_provider_start(provider) != 0) {
      api.xr_device_provider_shutdown(provider);
      api.xr_device_provider_destroy(provider);
      return;
    }

    bool isRunning = true;
    ffi.NativeCallable<bindings.VitureImuPoseCallbackFunction>? nativeCallback;

    if (deviceType == VitureDeviceType.carina) {
      // Carina 6DoF Pose Polling via GL Pose
      Isolate.spawn<List<dynamic>>((args) {
        final SendPort sendPort = args[0];
        final int providerAddr = args[1];
        final String dylibPath = args[2];

        final childDylib = ffi.DynamicLibrary.open(dylibPath);
        final childApi = bindings.VitureKitBindings(childDylib);
        final childProvider = ffi.Pointer<ffi.Void>.fromAddress(providerAddr);

        final poseArray = ffi.calloc<ffi.Float>(7);
        final statusPtr = ffi.calloc<ffi.Int>();

        while (true) {
          final res = childApi.xr_device_provider_get_gl_pose_carina(
            childProvider,
            poseArray,
            0.0,
            statusPtr,
          );

          if (res == 0) {
            sendPort.send({
              'roll': poseArray[0],
              'pitch': poseArray[1],
              'yaw': poseArray[2],
              'quatW': poseArray[3],
              'quatX': poseArray[4],
              'quatY': poseArray[5],
              'quatZ': poseArray[6],
              'timestamp': DateTime.now().microsecondsSinceEpoch,
            });
          }
          sleep(const Duration(milliseconds: 10)); // ~100Hz
        }
      }, [config.sendPort, provider.address, config.dylibPath]);
    } else {
      // Standard IMU Pose Callback
      nativeCallback =
          ffi.NativeCallable<bindings.VitureImuPoseCallbackFunction>.listener((
            ffi.Pointer<ffi.Float> dataPtr,
            int timestamp,
          ) {
            if (!isRunning || dataPtr == ffi.nullptr) return;

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

      api.xr_device_provider_register_imu_pose_callback(
        provider,
        nativeCallback.nativeFunction,
      );

      api.xr_device_provider_open_imu(
        provider,
        VitureImuMode.pose,
        VitureImuFrequency.freq60Hz,
      );
    }

    commandPort.listen((message) {
      if (message == _ControlCommand.stop) {
        isRunning = false;

        if (deviceType != VitureDeviceType.carina) {
          api.xr_device_provider_close_imu(provider, VitureImuMode.pose);
        }

        // Revert display back to standard 1920x1200
        api.xr_device_provider_set_display_mode(
          provider,
          VitureDisplayMode.mode1920x1200_120Hz,
        );
        sleep(const Duration(milliseconds: 1000));

        api.xr_device_provider_stop(provider);
        api.xr_device_provider_shutdown(provider);
        api.xr_device_provider_destroy(provider);

        nativeCallback?.close();
        commandPort.close();
        Isolate.exit();
      }
    });
  }

  Future<void> stop() async {
    _commandPort?.send(_ControlCommand.stop);
    _receivePort?.close();
    _poseController?.close();
    _workerIsolate = null;
    _poseController = null;
    _commandPort = null;
  }
}
