import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:viture_kit/core/viture_constants.dart';
import 'package:viture_kit/helper/hiadpi_helper.dart';
import 'package:viture_kit/models/viture_head_tracking_response_model.dart';
import 'package:viture_kit/models/viture_sensor_data_model.dart';
import 'package:viture_kit/models/viture_state_event_model.dart';

import 'viture_kit_bindings_generated.dart' as bindings;

export 'package:viture_kit/core/viture_constants.dart';
export 'package:viture_kit/models/viture_head_tracking_response_model.dart';
export 'package:viture_kit/models/viture_sensor_data_model.dart';
export 'package:viture_kit/models/viture_state_event_model.dart';

class VitureKit {
  static String get sdkVersion => bindings.VITURE_VERSION_STRING;
  static int get sdkVersionMajor => bindings.VITURE_VERSION_MAJOR;
  static int get sdkVersionMinor => bindings.VITURE_VERSION_MINOR;
  static int get sdkVersionPatch => bindings.VITURE_VERSION_PATCH;

  StreamController<VitureSensorData>? _sensorController;
  StreamController<VitureStateEvent>? _stateController;

  bindings.VitureKitBindings? _api;
  ffi.Pointer<ffi.Void>? _provider;
  bool _isConnected = false;
  Completer<void>? _connectingCompleter;

  ffi.NativeCallable<bindings.GlassStateCallbackFunction>? _stateCallable;
  ffi.NativeCallable<bindings.VitureImuPoseCallbackFunction>? _poseCallable;
  ffi.NativeCallable<bindings.VitureImuRawCallbackFunction>? _rawCallable;

  Timer? _carinaTimer;
  ffi.Pointer<ffi.Float>? _posePtr;
  ffi.Pointer<ffi.Int>? _statusPtr;

  int _deviceType = -1;
  VitureImuMode _imuMode = VitureImuMode.pose;
  bool _isHeadTrackingActive = false;
  bool _isStarting = false;
  bool _isReleasing = false;

  bool get isConnected => _isConnected;
  bool get isHeadTrackingActive => _isHeadTrackingActive;

  Stream<VitureSensorData> get sensorStream {
    _sensorController ??= StreamController<VitureSensorData>.broadcast();
    return _sensorController!.stream;
  }

  Stream<VitureStateEvent> get stateStream {
    _stateController ??= StreamController<VitureStateEvent>.broadcast();
    return _stateController!.stream;
  }

  void _registerStateCallback() {
    if (_api == null || _provider == null || _provider == ffi.nullptr) return;

    _stateController ??= StreamController<VitureStateEvent>.broadcast();

    _stateCallable =
        ffi.NativeCallable<bindings.GlassStateCallbackFunction>.listener((
          int stateId,
          int value,
        ) {
          final controller = _stateController;
          if (controller == null || controller.isClosed) return;
          controller.add(VitureStateEvent(stateId, value));
        });

    _api!.xr_device_provider_register_state_callback(
      _provider!,
      _stateCallable!.nativeFunction,
    );
  }

  static String _resolveDylibPath() {
    if (Platform.isMacOS) {
      return 'glasses.framework/glasses';
    }

    if (Platform.isWindows) {
      return 'glasses';
    }

    if (Platform.isAndroid) {
      return 'libglasses';
    }

    throw UnsupportedError(
      'Platform not supported: ${Platform.operatingSystem}',
    );
  }

  static int? fetchHidapiVitureProductIds({
    bool setDarwinOpenExclusive = false,
  }) {
    final productIds = HIDAPIHelper.fetchHidapiVitureProductIds(
      setDarwinOpenExclusive: setDarwinOpenExclusive,
    );
    return productIds.isEmpty ? null : productIds.first;
  }

  Future<void> connect({bool setDarwinOpenExclusive = false}) async {
    if (_isConnected && _api != null && _provider != null) return;

    if (_connectingCompleter != null) {
      return _connectingCompleter!.future;
    }

    final completer = Completer<void>();
    _connectingCompleter = completer;
    try {
      final productId = fetchHidapiVitureProductIds(
        setDarwinOpenExclusive: setDarwinOpenExclusive,
      );
      if (productId == null) {
        throw StateError('Unable to find the glasses.');
      }

      final dylib = ffi.DynamicLibrary.open(_resolveDylibPath());
      final api = bindings.VitureKitBindings(dylib);
      final provider = api.xr_device_provider_create(productId);

      if (provider == ffi.nullptr) {
        throw StateError('Unable to find the glasses.');
      }

      api.xr_device_provider_initialize(provider, ffi.nullptr, ffi.nullptr);
      api.xr_device_provider_start(provider);

      _api = api;
      _provider = provider;
      _isConnected = true;

      _registerStateCallback();

      completer.complete();
    } catch (e) {
      _api = null;
      _provider = null;
      _isConnected = false;
      completer.completeError(e);
      rethrow;
    } finally {
      _connectingCompleter = null;
    }
  }

  Future<void> disconnect() async {
    if (_isHeadTrackingActive || _isStarting) {
      await _forceCleanupHeadTracking();
    }

    final api = _api;
    final provider = _provider;

    if (api != null && provider != null && provider != ffi.nullptr) {
      try {
        api.xr_device_provider_register_state_callback(provider, ffi.nullptr);
      } catch (_) {}

      try {
        _stateCallable?.close();
      } catch (_) {}
      _stateCallable = null;

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
    _isConnected = false;
  }

  Future<void> _opQueue = Future<void>.value();

  Future<T?> _withProvider<T>(
    T Function(bindings.VitureKitBindings api, ffi.Pointer<ffi.Void> provider)
    action, {
    bool setDarwinOpenExclusive = false,
  }) {
    final result = _opQueue.then((_) async {
      try {
        await connect(setDarwinOpenExclusive: setDarwinOpenExclusive);
        final api = _api;
        final provider = _provider;
        if (api == null || provider == null || provider == ffi.nullptr) {
          return null;
        }
        return action(api, provider);
      } catch (_) {
        return null;
      }
    });
    _opQueue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<int?> getBrightnessLevel({bool setDarwinOpenExclusive = false}) {
    return _withProvider((api, provider) {
      return api.xr_device_provider_get_brightness_level(provider);
    }, setDarwinOpenExclusive: setDarwinOpenExclusive);
  }

  Future<void> setBrightnessLevel(
    int level, {
    bool setDarwinOpenExclusive = false,
  }) async {
    await _withProvider((api, provider) {
      api.xr_device_provider_set_brightness_level(provider, level);
    }, setDarwinOpenExclusive: setDarwinOpenExclusive);
  }

  Future<int?> getVolumeLevel({bool setDarwinOpenExclusive = false}) {
    return _withProvider((api, provider) {
      return api.xr_device_provider_get_volume_level(provider);
    }, setDarwinOpenExclusive: setDarwinOpenExclusive);
  }

  Future<void> setVolumeLevel(
    int level, {
    bool setDarwinOpenExclusive = false,
  }) async {
    await _withProvider((api, provider) {
      api.xr_device_provider_set_volume_level(provider, level);
    }, setDarwinOpenExclusive: setDarwinOpenExclusive);
  }

  Future<HeadTrackingResponse> startHeadTracking({
    VitureImuFrequency imuFrequency = VitureImuFrequency.freq120Hz,
    bool setDarwinOpenExclusive = false,
  }) async {
    const imuMode = VitureImuMode.pose;

    if (_isHeadTrackingActive || _isStarting) {
      return HeadTrackingResponse(
        status: true,
        message: "Successfully started head tracking.",
        code: bindings.VITURE_GLASSES_SUCCESS,
      );
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

      final result = await _opQueue.then((_) async {
        await connect(setDarwinOpenExclusive: setDarwinOpenExclusive);
        final api = _api;
        final provider = _provider;
        if (api == null || provider == null || provider == ffi.nullptr) {
          return HeadTrackingResponse(
            status: false,
            message: "Unable to find the glasses.",
            code: bindings.VITURE_GLASSES_ERROR_DEVICE_REJECTED,
          );
        }

        _deviceType = api.xr_device_provider_get_device_type(provider);

        if (_deviceType != VitureDeviceType.carina) {
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
            api.xr_device_provider_register_imu_raw_callback(
              provider,
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
            api.xr_device_provider_register_imu_pose_callback(
              provider,
              _poseCallable!.nativeFunction,
            );
          }

          final openResult = api.xr_device_provider_open_imu(
            provider,
            imuMode.value,
            imuFrequency.value,
          );
          if (openResult < 0) {
            await _forceCleanupHeadTracking();
            return HeadTrackingResponse(
              status: false,
              message: "Unable to find the glasses.",
              code: bindings.VITURE_GLASSES_ERROR_DEVICE_REJECTED,
            );
          }
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

        return HeadTrackingResponse(
          status: true,
          message: "Successfully started head tracking.",
          code: bindings.VITURE_GLASSES_SUCCESS,
        );
      });
      _opQueue = _opQueue.then((_) {}, onError: (_) {});

      if (result.status) {
        _isHeadTrackingActive = true;
      }
      return result;
    } catch (e) {
      await _forceCleanupHeadTracking();
      return HeadTrackingResponse(
        status: false,
        message: "Unable to find the glasses.",
        code: bindings.VITURE_GLASSES_ERROR_DEVICE_REJECTED,
      );
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
      await _forceCleanupHeadTracking();
    } finally {
      _isReleasing = false;
    }
  }

  Future<void> _forceCleanupHeadTracking() async {
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
        if (_deviceType != VitureDeviceType.carina) {
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

      if (_deviceType != VitureDeviceType.carina) {
        try {
          api.xr_device_provider_close_imu(provider, _imuMode.value);
        } catch (_) {}
      }
    }

    _deviceType = -1;
  }

  Future<void> setHeadTrackingEnabled(
    bool enabled, {
    bool setDarwinOpenExclusive = false,
  }) async {
    if (enabled) {
      await startHeadTracking(setDarwinOpenExclusive: setDarwinOpenExclusive);
    } else {
      await releaseHeadTracking();
    }
  }

  Future<void> dispose() async {
    try {
      await disconnect();
    } catch (_) {}
    await _sensorController?.close();
    _sensorController = null;
    await _stateController?.close();
    _stateController = null;
  }
}
