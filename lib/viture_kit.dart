import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'viture_kit_bindings_generated.dart' as bindings;

/// Formatted pose data read from the glasses.
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
  String toString() {
    return 'ViturePoseData('
        'PRY: [$pitch, $roll, $yaw], '
        'Quat: [$quatW, $quatX, $quatY, $quatZ], '
        'ts: $timestamp'
        ')';
  }
}

/// Product IDs for VITURE XR Glasses models.
abstract class VitureProductId {
  static const int vitureOne = 0x35CA;
  static const int viturePro = 0x35CB;
  static const int viturePro2 = 0x1301;
}

/// IMU modes matching VITURE protocol.
abstract class VitureImuMode {
  static const int raw = 0;
  static const int pose = 1;
}

/// IMU frequencies matching VITURE protocol.
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

  /// Resolve the VITURE framework location on macOS.
  static String _resolveDylibPath() {
    if (Platform.isMacOS) {
      return 'glasses.framework/glasses';
    }

    throw UnsupportedError(
      'Platform not supported: ${Platform.operatingSystem}',
    );
  }

  /// Take ownership of the glasses IMU.
  ///
  /// SpaceWalker's tracking will stop while this app owns
  /// the IMU.
  Future<void> takeHeadTracking({
    int productId = VitureProductId.viturePro2,
  }) async {
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

        if (message is List && message.length == 8) {
          final controller = _poseController;

          if (controller == null || controller.isClosed) {
            return;
          }

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
                timestamp: message[7] as int,
              ),
            );
          } catch (_) {
            // Ignore events arriving during shutdown.
          }

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

      // Wait for the native worker to confirm that the IMU
      // is actually open.
      await startCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw TimeoutException('Timed out waiting for VITURE IMU to start.');
        },
      );

      _isHeadTrackingActive = true;
    } catch (e) {
      _log('Start failed: $e');

      // Make absolutely sure a partially-created worker
      // cannot keep the IMU open.
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

  /// Release ownership of the glasses IMU.
  ///
  /// IMPORTANT:
  ///
  /// We do NOT close the ReceivePort or mark tracking inactive
  /// until the worker explicitly confirms:
  ///
  ///   close_imu()
  ///   stop()
  ///   shutdown()
  ///   destroy()
  ///
  /// has completed.
  ///
  /// This is much safer for handoff to SpaceWalker than the
  /// previous arbitrary 200 ms delay.
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
      // Tell the native worker to perform the complete
      // teardown.
      commandPort.send(_ControlCommand.stop);

      // Wait for the native side to explicitly confirm
      // that the provider has been destroyed.
      await releaseCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw TimeoutException(
            'Timed out waiting for VITURE IMU to release.',
          );
        },
      );

      // The worker has now completed:
      //
      // close_imu
      // stop
      // shutdown
      // destroy
      //
      // Only now tear down the Dart-side resources.
      worker.kill(priority: Isolate.immediate);

      _workerIsolate = null;
      _commandPort = null;

      _receivePort?.close();
      _receivePort = null;

      _isHeadTrackingActive = false;
    } catch (e) {
      _log('Release failed: $e');

      // If the worker is somehow stuck, do not leave a dead
      // Dart reference around forever.
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

  Future<void> setHeadTrackingEnabled(
    bool enabled, {
    int productId = VitureProductId.viturePro2,
  }) async {
    if (enabled) {
      await takeHeadTracking(productId: productId);
    } else {
      await releaseHeadTracking();
    }
  }

  static void _log(String message) {
    // ignore: avoid_print
    print('[VitureKit] $message');
  }

  /// Native worker.
  static void _backgroundSensorWorker(_IsolateInitConfig config) {
    final commandPort = ReceivePort();

    config.sendPort.send(commandPort.sendPort);

    bindings.VitureKitBindings? api;
    ffi.Pointer<ffi.Void>? provider;

    ffi.NativeCallable<bindings.VitureImuPoseCallbackFunction>? poseCallable;

    bool cleanedUp = false;

    void cleanup() {
      if (cleanedUp) {
        return;
      }

      cleanedUp = true;

      _workerLog('Beginning native IMU cleanup');

      try {
        if (provider != null && api != null) {
          //
          // IMPORTANT:
          //
          // Close the IMU FIRST.
          //
          _workerLog('Closing IMU');

          api.xr_device_provider_close_imu(provider!, VitureImuMode.pose);

          //
          // Then stop the provider.
          //
          _workerLog('Stopping provider');

          api.xr_device_provider_stop(provider!);

          //
          // Then shutdown.
          //
          _workerLog('Shutting down provider');

          api.xr_device_provider_shutdown(provider!);

          //
          // Finally destroy.
          //
          _workerLog('Destroying provider');

          api.xr_device_provider_destroy(provider!);

          provider = null;

          _workerLog('Native provider destroyed');
        }
      } catch (e, st) {
        _workerLog('ERROR: Native cleanup failed: $e\n$st');

        config.sendPort.send('ERROR: Cleanup failed: $e');
      } finally {
        //
        // The callback must not remain alive after the provider
        // has been destroyed.
        //
        try {
          poseCallable?.close();
        } catch (_) {}

        poseCallable = null;

        //
        // THIS is the important new handshake.
        //
        // Do not make the Flutter isolate guess when cleanup
        // has completed.
        //
        config.sendPort.send('IMU_RELEASED');

        commandPort.close();

        _workerLog('Cleanup complete');
      }
    }

    try {
      _workerLog('Opening VITURE framework: ${config.dylibPath}');

      final dylib = ffi.DynamicLibrary.open(config.dylibPath);

      api = bindings.VitureKitBindings(dylib);

      _workerLog(
        'Creating device provider for product '
        '${config.productId}',
      );

      provider = api!.xr_device_provider_create(config.productId);

      if (provider == ffi.nullptr) {
        config.sendPort.send('ERROR: Failed to create device provider');

        cleanup();
        Isolate.exit();
      }

      _workerLog('Initializing provider');

      api!.xr_device_provider_initialize(provider!, ffi.nullptr, ffi.nullptr);

      _workerLog('Starting provider');

      api!.xr_device_provider_start(provider!);

      //
      // Give the native provider a moment to initialize
      // before registering/opening the IMU.
      //
      sleep(const Duration(milliseconds: 400));

      //
      // Register pose callback.
      //
      poseCallable =
          ffi.NativeCallable<bindings.VitureImuPoseCallbackFunction>.listener((
            ffi.Pointer<ffi.Float> dataPtr,
            int timestamp,
          ) {
            if (dataPtr == ffi.nullptr) {
              return;
            }

            if (cleanedUp) {
              return;
            }

            try {
              config.sendPort.send(<Object>[
                dataPtr[0],
                dataPtr[1],
                dataPtr[2],
                dataPtr[3],
                dataPtr[4],
                dataPtr[5],
                dataPtr[6],
                timestamp,
              ]);
            } catch (_) {
              // Ignore callbacks during teardown.
            }
          });

      _workerLog('Registering IMU pose callback');

      api!.xr_device_provider_register_imu_pose_callback(
        provider!,
        poseCallable!.nativeFunction,
      );

      _workerLog('Opening pose IMU');

      api!.xr_device_provider_open_imu(
        provider!,
        VitureImuMode.pose,
        VitureImuFrequency.freq60Hz,
      );

      _workerLog('IMU ready');

      config.sendPort.send('IMU_READY');
    } catch (e, st) {
      config.sendPort.send('ERROR: $e\n$st');

      cleanup();

      Isolate.exit();
    }

    //
    // Wait for commands from the main isolate.
    //
    commandPort.listen((message) {
      if (message == _ControlCommand.stop) {
        _workerLog('STOP command received');

        cleanup();

        //
        // Cleanup sends IMU_RELEASED before exiting.
        //
        Isolate.exit();
      }
    });
  }

  static void _workerLog(String message) {
    // ignore: avoid_print
    print('[VitureKitWorker] $message');
  }

  /// Call this when the Flutter app itself is going away.
  ///
  /// We deliberately do not close the pose controller here because
  /// callers may still own the stream. The native worker is released.
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
