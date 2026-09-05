import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:viture_kit/helper/hiadpi_helper.dart';

import 'viture_kit_bindings_generated.dart' as bindings;

const int vitureDeviceTypeCarina = 2;

class ViturePoseData {
  final double roll;
  final double pitch;
  final double yaw;

  final double quatW;
  final double quatX;
  final double quatY;
  final double quatZ;

  final double? magX;
  final double? magY;
  final double? magZ;
  final double? temperature;

  final int timestamp;

  const ViturePoseData({
    required this.roll,
    required this.pitch,
    required this.yaw,
    required this.quatW,
    required this.quatX,
    required this.quatY,
    required this.quatZ,
    this.magX,
    this.magY,
    this.magZ,
    this.temperature,
    required this.timestamp,
  });

  bool get hasMagnetometer => magX != null && magY != null && magZ != null;

  @override
  String toString() {
    return 'ViturePoseData('
        'PRY: [$pitch, $roll, $yaw], '
        'Quat: [$quatW, $quatX, $quatY, $quatZ], '
        '${hasMagnetometer ? 'Mag: [$magX, $magY, $magZ], ' : ''}'
        '${temperature != null ? 'Temp: $temperature, ' : ''}'
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

  const _IsolateInitConfig(this.sendPort, this.dylibPath, this.productId);
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

  StreamController<ViturePoseData>? _poseController;

  Completer<void>? _startCompleter;
  Completer<void>? _releaseCompleter;

  bool _isHeadTrackingActive = false;
  bool _isStarting = false;
  bool _isReleasing = false;

  bool get isHeadTrackingActive => _isHeadTrackingActive;

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

  Future<void> takeHeadTracking() async {
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

        if (message is List && (message.length == 8 || message.length == 12)) {
          final controller = _poseController;

          if (controller == null || controller.isClosed) {
            return;
          }

          final hasExtras = message.length == 12;

          try {
            controller.add(
              ViturePoseData(
                roll: (message[0] as num).toDouble(),
                pitch: (message[1] as num).toDouble(),
                yaw: (message[2] as num).toDouble(),
                quatW: (message[3] as num).toDouble(),
                quatX: (message[4] as num).toDouble(),
                quatY: (message[5] as num).toDouble(),
                quatZ: (message[6] as num).toDouble(),
                magX: hasExtras ? (message[7] as num).toDouble() : null,
                magY: hasExtras ? (message[8] as num).toDouble() : null,
                magZ: hasExtras ? (message[9] as num).toDouble() : null,
                temperature: hasExtras ? (message[10] as num).toDouble() : null,
                timestamp: hasExtras ? message[11] as int : message[7] as int,
              ),
            );
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

      _poseController ??= StreamController<ViturePoseData>.broadcast();

      _workerIsolate = await Isolate.spawn(
        _backgroundSensorWorker,
        _IsolateInitConfig(receivePort.sendPort, dylibPath, productId),
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
      await takeHeadTracking();
    } else {
      await releaseHeadTracking();
    }
  }

  static void _log(String message) {
    // ignore: avoid_print
    print('[VitureKit] $message');
  }

  static bool _deviceSupportsMagnetometer(int deviceType) {
    return deviceType != vitureDeviceTypeCarina;
  }

  static void _backgroundSensorWorker(_IsolateInitConfig config) {
    final commandPort = ReceivePort();
    config.sendPort.send(commandPort.sendPort);

    bindings.VitureKitBindings? api;
    ffi.Pointer<ffi.Void>? provider;
    ffi.NativeCallable<bindings.VitureImuPoseCallbackFunction>? poseCallable;

    bool cleanedUp = false;
    int deviceType = -1;

    void cleanup() {
      if (cleanedUp) return;
      cleanedUp = true;

      _workerLog('Beginning native IMU cleanup');

      try {
        if (provider != null && api != null) {
          if (deviceType != vitureDeviceTypeCarina) {
            _workerLog('Unregistering IMU callback first');
            api.xr_device_provider_register_imu_pose_callback(
              provider!,
              ffi.nullptr,
            );

            poseCallable?.close();
            poseCallable = null;

            _workerLog('Closing IMU');
            api.xr_device_provider_close_imu(provider!, VitureImuMode.pose);
          }

          _workerLog('Stopping provider');
          api.xr_device_provider_stop(provider!);

          _workerLog('Shutting down provider');
          api.xr_device_provider_shutdown(provider!);

          _workerLog('Destroying provider');
          api.xr_device_provider_destroy(provider!);

          provider = null;
        }
      } catch (e, st) {
        _workerLog('ERROR: Native cleanup failed: $e\n$st');
        config.sendPort.send('ERROR: Cleanup failed: $e');
      } finally {
        poseCallable?.close();
        poseCallable = null;

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
        final hasMagnetometer = _deviceSupportsMagnetometer(deviceType);

        poseCallable =
            ffi.NativeCallable<bindings.VitureImuPoseCallbackFunction>.listener(
              (ffi.Pointer<ffi.Float> dataPtr, int timestamp) {
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
                  ];

                  if (hasMagnetometer) {
                    payload.addAll(<Object>[
                      dataPtr[7],
                      dataPtr[8],
                      dataPtr[9],
                      dataPtr[10],
                    ]);
                  }

                  payload.add(timestamp);

                  config.sendPort.send(payload);
                } catch (_) {}
              },
            );

        api.xr_device_provider_register_imu_pose_callback(
          provider!,
          poseCallable!.nativeFunction,
        );

        api.xr_device_provider_open_imu(
          provider!,
          VitureImuMode.raw,
          VitureImuFrequency.freq120Hz,
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
    // ignore: avoid_print
    print('[VitureKitWorker] $message');
  }

  Future<void> dispose() async {
    try {
      await releaseHeadTracking();
    } catch (e) {
      _log('Dispose release failed: $e');
    }

    await _poseController?.close();
    _poseController = null;
  }
}
