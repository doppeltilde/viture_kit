import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:viture_kit/helper/hiadpi_helper.dart';

import 'viture_kit_bindings_generated.dart' as bindings;

const int vitureDeviceTypeCarina = 2;

class VitureSensorData {
  final double roll;
  final double pitch;
  final double yaw;
  final double quatW;
  final double quatX;
  final double quatY;
  final double quatZ;

  final double gyroX;
  final double gyroY;
  final double gyroZ;
  final double accelX;
  final double accelY;
  final double accelZ;
  final double magX;
  final double magY;
  final double magZ;
  final double temperature;

  final int timestamp;
  final int vsync;

  final bool isRaw;

  const VitureSensorData.pose({
    required this.roll,
    required this.pitch,
    required this.yaw,
    required this.quatW,
    required this.quatX,
    required this.quatY,
    required this.quatZ,
    required this.timestamp,
  }) : gyroX = 0.0,
       gyroY = 0.0,
       gyroZ = 0.0,
       accelX = 0.0,
       accelY = 0.0,
       accelZ = 0.0,
       magX = 0.0,
       magY = 0.0,
       magZ = 0.0,
       temperature = 0.0,
       vsync = 0,
       isRaw = false;

  const VitureSensorData.raw({
    required this.gyroX,
    required this.gyroY,
    required this.gyroZ,
    required this.accelX,
    required this.accelY,
    required this.accelZ,
    required this.magX,
    required this.magY,
    required this.magZ,
    required this.temperature,
    required this.timestamp,
    required this.vsync,
  }) : roll = 0.0,
       pitch = 0.0,
       yaw = 0.0,
       quatW = 0.0,
       quatX = 0.0,
       quatY = 0.0,
       quatZ = 0.0,
       isRaw = true;

  @override
  String toString() {
    if (isRaw) {
      return 'VitureSensorData.raw('
          'Gyro: [$gyroX, $gyroY, $gyroZ], '
          'Accel: [$accelX, $accelY, $accelZ], '
          'Mag: [$magX, $magY, $magZ], '
          'Temp: $temperature, '
          'ts: $timestamp, vsync: $vsync'
          ')';
    }
    return 'VitureSensorData.pose('
        'PRY: [$pitch, $roll, $yaw], '
        'Quat: [$quatW, $quatX, $quatY, $quatZ], '
        'ts: $timestamp'
        ')';
  }
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
  final int imuMode;
  final int imuFrequency;

  const _IsolateInitConfig(
    this.sendPort,
    this.dylibPath,
    this.productId,
    this.imuMode,
    this.imuFrequency,
  );
}

enum _ControlCommand { stop }

class VitureKit {
  static String get sdkVersion => bindings.VITURE_VERSION_STRING;

  static int get sdkVersionMajor => bindings.VITURE_VERSION_MAJOR;
  static int get sdkVersionMinor => bindings.VITURE_VERSION_MINOR;
  static int get sdkVersionPatch => bindings.VITURE_VERSION_PATCH;

  Isolate? _workerIsolate;
  ReceivePort? _receivePort;
  SendPort? _commandPort;

  StreamController<VitureSensorData>? _sensorController;

  Completer<void>? _startCompleter;
  Completer<void>? _releaseCompleter;

  bool _isHeadTrackingActive = false;
  bool _isStarting = false;
  bool _isReleasing = false;

  bool get isHeadTrackingActive => _isHeadTrackingActive;

  Stream<VitureSensorData> get sensorStream {
    _sensorController ??= StreamController<VitureSensorData>.broadcast();
    return _sensorController!.stream;
  }

  static String _resolveDylibPath() {
    if (Platform.isMacOS) {
      return 'glasses.framework/glasses';
    }

    throw UnsupportedError(
      'Platform not supported: ${Platform.operatingSystem}',
    );
  }

  static int? fetchHidapiVitureProductIds() {
    final productIds = HIDAPIHelper.fetchHidapiVitureProductIds();
    return productIds.isEmpty ? null : productIds.first;
  }

  static T _withNativeProvider<T>(
    T Function(bindings.VitureKitBindings api, ffi.Pointer<ffi.Void> provider)
    action,
  ) {
    final productId = fetchHidapiVitureProductIds();
    if (productId == null) {
      throw StateError('No VITURE device found.');
    }

    final dylib = ffi.DynamicLibrary.open(_resolveDylibPath());
    final api = bindings.VitureKitBindings(dylib);
    final provider = api.xr_device_provider_create(productId);

    if (provider == ffi.nullptr) {
      throw StateError('Failed to create device provider.');
    }

    try {
      api.xr_device_provider_initialize(provider, ffi.nullptr, ffi.nullptr);
      return action(api, provider);
    } finally {
      api.xr_device_provider_shutdown(provider);
      api.xr_device_provider_destroy(provider);
    }
  }

  int getBrightnessLevel() {
    return _withNativeProvider((api, provider) {
      return api.xr_device_provider_get_brightness_level(provider);
    });
  }

  void setBrightnessLevel(int level) {
    _withNativeProvider((api, provider) {
      api.xr_device_provider_set_brightness_level(provider, level);
    });
  }

  int getVolumeLevel() {
    return _withNativeProvider((api, provider) {
      return api.xr_device_provider_get_volume_level(provider);
    });
  }

  void setVolumeLevel(int level) {
    _withNativeProvider((api, provider) {
      api.xr_device_provider_set_volume_level(provider, level);
    });
  }

  Future<void> startHeadTracking({
    // int imuMode = VitureImuMode.pose,
    int imuFrequency = VitureImuFrequency.freq120Hz,
  }) async {
    int imuMode = VitureImuMode.pose;
    final res = fetchHidapiVitureProductIds();
    if (res == null) {
      return;
    }

    final productId = res;

    if (_isHeadTrackingActive) {
      return;
    }

    if (_isStarting) {
      return _startCompleter?.future ?? Future.value();
    }

    if (_isReleasing) {
      throw StateError(
        'Cannot start head tracking while release is in progress.',
      );
    }

    _isStarting = true;

    final receivePort = ReceivePort();
    _receivePort = receivePort;

    final startCompleter = Completer<void>();
    _startCompleter = startCompleter;

    try {
      final dylibPath = _resolveDylibPath();

      receivePort.listen((dynamic message) {
        if (message is SendPort) {
          _commandPort = message;
          return;
        }

        if (message is List) {
          final controller = _sensorController;
          if (controller == null || controller.isClosed) {
            return;
          }

          try {
            if (message.length == 8) {
              controller.add(
                VitureSensorData.pose(
                  roll: (message[0] as num).toDouble(),
                  pitch: (message[1] as num).toDouble(),
                  yaw: (message[2] as num).toDouble(),
                  quatW: (message[3] as num).toDouble(),
                  quatX: (message[4] as num).toDouble(),
                  quatY: (message[5] as num).toDouble(),
                  quatZ: (message[6] as num).toDouble(),
                  timestamp: message[7] as int,
                ),
              );
            } else if (message.length == 12) {
              controller.add(
                VitureSensorData.raw(
                  gyroX: (message[0] as num).toDouble(),
                  gyroY: (message[1] as num).toDouble(),
                  gyroZ: (message[2] as num).toDouble(),
                  accelX: (message[3] as num).toDouble(),
                  accelY: (message[4] as num).toDouble(),
                  accelZ: (message[5] as num).toDouble(),
                  magX: (message[6] as num).toDouble(),
                  magY: (message[7] as num).toDouble(),
                  magZ: (message[8] as num).toDouble(),
                  temperature: (message[9] as num).toDouble(),
                  timestamp: message[10] as int,
                  vsync: message[11] as int,
                ),
              );
            }
          } catch (_) {}

          return;
        }

        if (message is String) {
          _log(message);

          if (message == 'IMU_READY') {
            if (!startCompleter.isCompleted) {
              startCompleter.complete();
            }
          } else if (message.startsWith('ERROR:')) {
            if (!startCompleter.isCompleted) {
              startCompleter.completeError(Exception(message));
            }

            if (_releaseCompleter != null && !_releaseCompleter!.isCompleted) {
              _releaseCompleter!.completeError(Exception(message));
            }
          } else if (message == 'IMU_RELEASED') {
            if (_releaseCompleter != null && !_releaseCompleter!.isCompleted) {
              _releaseCompleter!.complete();
            }
          }
        }
      });

      _sensorController ??= StreamController<VitureSensorData>.broadcast();

      _workerIsolate = await Isolate.spawn(
        _backgroundSensorWorker,
        _IsolateInitConfig(
          receivePort.sendPort,
          dylibPath,
          productId,
          imuMode,
          imuFrequency,
        ),
        debugName: 'VitureKitWorker',
      );

      await startCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw TimeoutException('Timed out waiting for VITURE IMU to start.');
        },
      );

      _isHeadTrackingActive = true;
    } catch (e) {
      _log('Start failed: $e');

      try {
        _commandPort?.send(_ControlCommand.stop);
      } catch (_) {}

      _workerIsolate?.kill(priority: Isolate.immediate);
      _workerIsolate = null;
      _commandPort = null;

      _receivePort?.close();
      _receivePort = null;

      _isHeadTrackingActive = false;

      rethrow;
    } finally {
      _startCompleter = null;
      _isStarting = false;
    }
  }

  Future<void> releaseHeadTracking() async {
    if (!_isHeadTrackingActive && !_isStarting && !_isReleasing) {
      return;
    }

    if (_isReleasing) {
      return _releaseCompleter?.future ?? Future.value();
    }

    _isReleasing = true;

    final commandPort = _commandPort;
    final worker = _workerIsolate;

    if (commandPort == null || worker == null) {
      _isHeadTrackingActive = false;
      _isReleasing = false;
      return;
    }

    final releaseCompleter = Completer<void>();
    _releaseCompleter = releaseCompleter;

    try {
      commandPort.send(_ControlCommand.stop);

      await releaseCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw TimeoutException(
            'Timed out waiting for VITURE IMU to release.',
          );
        },
      );

      worker.kill(priority: Isolate.immediate);

      _workerIsolate = null;
      _commandPort = null;

      _receivePort?.close();
      _receivePort = null;

      _isHeadTrackingActive = false;
    } catch (e) {
      _log('Release failed: $e');

      try {
        worker.kill(priority: Isolate.immediate);
      } catch (_) {}

      _workerIsolate = null;
      _commandPort = null;

      _receivePort?.close();
      _receivePort = null;

      _isHeadTrackingActive = false;

      rethrow;
    } finally {
      _releaseCompleter = null;
      _isReleasing = false;
    }
  }

  Future<void> setHeadTrackingEnabled(bool enabled) async {
    if (enabled) {
      await startHeadTracking();
    } else {
      await releaseHeadTracking();
    }
  }

  static void _log(String message) {
    print('[VitureKit] $message');
  }

  static void _backgroundSensorWorker(_IsolateInitConfig config) {
    final commandPort = ReceivePort();
    config.sendPort.send(commandPort.sendPort);

    bindings.VitureKitBindings? api;
    ffi.Pointer<ffi.Void>? provider;
    ffi.NativeCallable<bindings.VitureImuPoseCallbackFunction>? poseCallable;
    ffi.NativeCallable<bindings.VitureImuRawCallbackFunction>? rawCallable;

    bool cleanedUp = false;
    int deviceType = -1;

    void cleanup() {
      if (cleanedUp) return;
      cleanedUp = true;

      _workerLog('Beginning native IMU cleanup');

      try {
        if (provider != null && api != null) {
          if (deviceType != vitureDeviceTypeCarina) {
            if (config.imuMode == VitureImuMode.raw) {
              api.xr_device_provider_register_imu_raw_callback(
                provider!,
                ffi.nullptr,
              );
              rawCallable?.close();
              rawCallable = null;
            } else {
              api.xr_device_provider_register_imu_pose_callback(
                provider!,
                ffi.nullptr,
              );
              poseCallable?.close();
              poseCallable = null;
            }

            api.xr_device_provider_close_imu(provider!, config.imuMode);
          }

          api.xr_device_provider_stop(provider!);
          api.xr_device_provider_shutdown(provider!);
          api.xr_device_provider_destroy(provider!);

          provider = null;
        }
      } catch (e, st) {
        _workerLog('ERROR: Native cleanup failed: $e\n$st');
        config.sendPort.send('ERROR: Cleanup failed: $e');
      } finally {
        poseCallable?.close();
        poseCallable = null;
        rawCallable?.close();
        rawCallable = null;

        config.sendPort.send('IMU_RELEASED');
        commandPort.close();
        _workerLog('Cleanup complete');
      }
    }

    try {
      final dylib = ffi.DynamicLibrary.open(config.dylibPath);
      api = bindings.VitureKitBindings(dylib);

      provider = api.xr_device_provider_create(config.productId);
      if (provider == ffi.nullptr) {
        config.sendPort.send('ERROR: Failed to create device provider');
        cleanup();
        Isolate.exit();
      }

      api.xr_device_provider_initialize(provider!, ffi.nullptr, ffi.nullptr);
      api.xr_device_provider_start(provider!);

      sleep(const Duration(milliseconds: 400));
      deviceType = api.xr_device_provider_get_device_type(provider!);

      if (deviceType != vitureDeviceTypeCarina) {
        if (config.imuMode == VitureImuMode.raw) {
          rawCallable =
              ffi.NativeCallable<
                bindings.VitureImuRawCallbackFunction
              >.listener((
                ffi.Pointer<ffi.Float> dataPtr,
                int timestamp,
                int vsync,
              ) {
                if (dataPtr == ffi.nullptr || cleanedUp) return;

                try {
                  final payload = <Object>[
                    dataPtr[0],
                    dataPtr[1],
                    dataPtr[2],
                    dataPtr[3],
                    dataPtr[4],
                    dataPtr[5],
                    dataPtr[6],
                    dataPtr[7],
                    dataPtr[8],
                    dataPtr[9],
                    timestamp,
                    vsync,
                  ];

                  config.sendPort.send(payload);
                } catch (_) {}
              });

          api.xr_device_provider_register_imu_raw_callback(
            provider!,
            rawCallable!.nativeFunction,
          );
        } else {
          poseCallable =
              ffi.NativeCallable<
                bindings.VitureImuPoseCallbackFunction
              >.listener((ffi.Pointer<ffi.Float> dataPtr, int timestamp) {
                if (dataPtr == ffi.nullptr || cleanedUp) return;

                try {
                  final payload = <Object>[
                    dataPtr[0],
                    dataPtr[1],
                    dataPtr[2],
                    dataPtr[3],
                    dataPtr[4],
                    dataPtr[5],
                    dataPtr[6],
                    timestamp,
                  ];

                  config.sendPort.send(payload);
                } catch (_) {}
              });

          api.xr_device_provider_register_imu_pose_callback(
            provider!,
            poseCallable!.nativeFunction,
          );
        }

        api.xr_device_provider_open_imu(
          provider!,
          config.imuMode,
          config.imuFrequency,
        );
      } else {
        final posePtr = calloc<ffi.Float>(7);
        final statusPtr = calloc<ffi.Int>();

        Timer.periodic(const Duration(milliseconds: 2), (timer) {
          if (cleanedUp) {
            timer.cancel();
            calloc.free(posePtr);
            calloc.free(statusPtr);
            return;
          }

          api!.xr_device_provider_get_gl_pose_carina(
            provider!,
            posePtr,
            0.0,
            statusPtr,
          );

          if (statusPtr.value == 0) {
            try {
              config.sendPort.send(<Object>[
                posePtr[0],
                posePtr[1],
                posePtr[2],
                posePtr[3],
                posePtr[4],
                posePtr[5],
                posePtr[6],
                DateTime.now().millisecondsSinceEpoch,
              ]);
            } catch (_) {}
          }
        });
      }

      config.sendPort.send('IMU_READY');
    } catch (e, st) {
      config.sendPort.send('ERROR: $e\n$st');
      cleanup();
      Isolate.exit();
    }

    commandPort.listen((message) {
      if (message == _ControlCommand.stop) {
        cleanup();
        Isolate.exit();
      }
    });
  }

  static void _workerLog(String message) {
    print('[VitureKitWorker] $message');
  }

  Future<void> dispose() async {
    try {
      await releaseHeadTracking();
    } catch (e) {
      _log('Dispose release failed: $e');
    }

    await _sensorController?.close();
    _sensorController = null;
  }
}
