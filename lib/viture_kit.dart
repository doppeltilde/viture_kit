import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

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

class VitureKit {
  static String get sdkVersion => bindings.VITURE_VERSION_STRING;
  static int get sdkVersionMajor => bindings.VITURE_VERSION_MAJOR;
  static int get sdkVersionMinor => bindings.VITURE_VERSION_MINOR;
  static int get sdkVersionPatch => bindings.VITURE_VERSION_PATCH;

  StreamController<VitureSensorData>? _sensorController;

  bindings.VitureKitBindings? _api;
  ffi.Pointer<ffi.Void>? _provider;
  ffi.NativeCallable<bindings.VitureImuPoseCallbackFunction>? _poseCallable;
  ffi.NativeCallable<bindings.VitureImuRawCallbackFunction>? _rawCallable;
  Timer? _carinaTimer;
  ffi.Pointer<ffi.Float>? _posePtr;
  ffi.Pointer<ffi.Int>? _statusPtr;

  int _deviceType = -1;
  int _imuMode = VitureImuMode.pose;
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
      try {
        api.xr_device_provider_shutdown(provider);
      } catch (_) {}
      try {
        api.xr_device_provider_destroy(provider);
      } catch (_) {}
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
    int imuFrequency = VitureImuFrequency.freq120Hz,
  }) async {
    const imuMode = VitureImuMode.pose;
    final productId = fetchHidapiVitureProductIds();
    if (productId == null) {
      return;
    }

    if (_isHeadTrackingActive || _isStarting) {
      return;
    }
    if (_isReleasing) {
      throw StateError(
        'Cannot start head tracking while release is in progress.',
      );
    }

    _isStarting = true;
    _imuMode = imuMode;

    try {
      _sensorController ??= StreamController<VitureSensorData>.broadcast();

      final dylib = ffi.DynamicLibrary.open(_resolveDylibPath());
      _api = bindings.VitureKitBindings(dylib);

      _provider = _api!.xr_device_provider_create(productId);
      if (_provider == ffi.nullptr) {
        throw StateError('Failed to create device provider');
      }

      _api!.xr_device_provider_initialize(_provider!, ffi.nullptr, ffi.nullptr);
      _api!.xr_device_provider_start(_provider!);

      await Future<void>.delayed(const Duration(milliseconds: 450));

      _deviceType = _api!.xr_device_provider_get_device_type(_provider!);

      if (_deviceType != vitureDeviceTypeCarina) {
        if (imuMode == VitureImuMode.raw) {
          _rawCallable =
              ffi.NativeCallable<
                bindings.VitureImuRawCallbackFunction
              >.listener((
                ffi.Pointer<ffi.Float> dataPtr,
                int timestamp,
                int vsync,
              ) {
                if (!_isHeadTrackingActive || dataPtr == ffi.nullptr) return;
                final controller = _sensorController;
                if (controller == null || controller.isClosed) return;
                try {
                  controller.add(
                    VitureSensorData.raw(
                      gyroX: dataPtr[0],
                      gyroY: dataPtr[1],
                      gyroZ: dataPtr[2],
                      accelX: dataPtr[3],
                      accelY: dataPtr[4],
                      accelZ: dataPtr[5],
                      magX: dataPtr[6],
                      magY: dataPtr[7],
                      magZ: dataPtr[8],
                      temperature: dataPtr[9],
                      timestamp: timestamp,
                      vsync: vsync,
                    ),
                  );
                } catch (_) {}
              });
          _api!.xr_device_provider_register_imu_raw_callback(
            _provider!,
            _rawCallable!.nativeFunction,
          );
        } else {
          _poseCallable =
              ffi.NativeCallable<
                bindings.VitureImuPoseCallbackFunction
              >.listener((ffi.Pointer<ffi.Float> dataPtr, int timestamp) {
                if (!_isHeadTrackingActive || dataPtr == ffi.nullptr) return;
                final controller = _sensorController;
                if (controller == null || controller.isClosed) return;
                try {
                  controller.add(
                    VitureSensorData.pose(
                      roll: dataPtr[0],
                      pitch: dataPtr[1],
                      yaw: dataPtr[2],
                      quatW: dataPtr[3],
                      quatX: dataPtr[4],
                      quatY: dataPtr[5],
                      quatZ: dataPtr[6],
                      timestamp: timestamp,
                    ),
                  );
                } catch (_) {}
              });
          _api!.xr_device_provider_register_imu_pose_callback(
            _provider!,
            _poseCallable!.nativeFunction,
          );
        }

        _api!.xr_device_provider_open_imu(_provider!, imuMode, imuFrequency);
      } else {
        _posePtr = calloc<ffi.Float>(7);
        _statusPtr = calloc<ffi.Int>();

        _carinaTimer = Timer.periodic(const Duration(milliseconds: 2), (_) {
          if (!_isHeadTrackingActive) return;
          final api = _api;
          final provider = _provider;
          final posePtr = _posePtr;
          final statusPtr = _statusPtr;
          if (api == null ||
              provider == null ||
              posePtr == null ||
              statusPtr == null) {
            return;
          }
          try {
            api.xr_device_provider_get_gl_pose_carina(
              provider,
              posePtr,
              0.0,
              statusPtr,
            );
            if (statusPtr.value == 0) {
              final controller = _sensorController;
              if (controller == null || controller.isClosed) return;
              controller.add(
                VitureSensorData.pose(
                  roll: posePtr[0],
                  pitch: posePtr[1],
                  yaw: posePtr[2],
                  quatW: posePtr[3],
                  quatX: posePtr[4],
                  quatY: posePtr[5],
                  quatZ: posePtr[6],
                  timestamp: DateTime.now().millisecondsSinceEpoch,
                ),
              );
            }
          } catch (_) {}
        });
      }

      _isHeadTrackingActive = true;
    } catch (e) {
      await _forceCleanup();
      rethrow;
    } finally {
      _isStarting = false;
    }
  }

  Future<void> releaseHeadTracking() async {
    if (!_isHeadTrackingActive && !_isStarting) {
      return;
    }
    if (_isReleasing) {
      return;
    }

    _isReleasing = true;
    try {
      await _forceCleanup();
    } finally {
      _isReleasing = false;
    }
  }

  Future<void> _forceCleanup() async {
    _isHeadTrackingActive = false;

    _carinaTimer?.cancel();
    _carinaTimer = null;

    if (_posePtr != null) {
      calloc.free(_posePtr!);
      _posePtr = null;
    }
    if (_statusPtr != null) {
      calloc.free(_statusPtr!);
      _statusPtr = null;
    }

    final api = _api;
    final provider = _provider;

    if (api != null && provider != null && provider != ffi.nullptr) {
      try {
        if (_deviceType != vitureDeviceTypeCarina) {
          if (_imuMode == VitureImuMode.raw) {
            api.xr_device_provider_register_imu_raw_callback(
              provider,
              ffi.nullptr,
            );
          } else {
            api.xr_device_provider_register_imu_pose_callback(
              provider,
              ffi.nullptr,
            );
          }
        }
      } catch (_) {}

      try {
        _poseCallable?.close();
      } catch (_) {}
      _poseCallable = null;

      try {
        _rawCallable?.close();
      } catch (_) {}
      _rawCallable = null;

      if (_deviceType != vitureDeviceTypeCarina) {
        try {
          api.xr_device_provider_close_imu(provider, _imuMode);
        } catch (_) {}
      }

      try {
        api.xr_device_provider_stop(provider);
      } catch (_) {}

      try {
        api.xr_device_provider_shutdown(provider);
      } catch (_) {}

      try {
        api.xr_device_provider_destroy(provider);
      } catch (_) {}
    }

    _provider = null;
    _api = null;
    _deviceType = -1;
  }

  Future<void> setHeadTrackingEnabled(bool enabled) async {
    if (enabled) {
      await startHeadTracking();
    } else {
      await releaseHeadTracking();
    }
  }

  Future<void> dispose() async {
    try {
      await releaseHeadTracking();
    } catch (_) {}
    await _sensorController?.close();
    _sensorController = null;
  }
}
