import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart';

import 'package:viture_kit/core/viture_constants.dart';
import 'package:viture_kit/models/viture_head_tracking_response_model.dart';
import 'package:viture_kit/models/viture_sensor_data_model.dart';
import 'package:viture_kit/models/viture_state_event_model.dart';

export 'package:viture_kit/core/viture_constants.dart';
export 'package:viture_kit/models/viture_head_tracking_response_model.dart';
export 'package:viture_kit/models/viture_sensor_data_model.dart';
export 'package:viture_kit/models/viture_state_event_model.dart';

@JS()
extension type GlassesDevice._(JSObject _) implements JSObject {
  external GlassesDevice(JSObject mod);

  external JSPromise connect();
  external JSPromise disconnect();

  external String get productName;
  external int get deviceType;
  external bool get supportsNativeDof;

  external JSPromise onPose(JSFunction cb, [JSNumber? freq]);
  external JSPromise offPose();
  external JSPromise onRaw(JSFunction cb, [JSNumber? freq]);
  external JSPromise offRaw();

  external void onStateChange(JSFunction cb);
  external void offStateChange();

  external JSPromise getBrightness();
  external JSPromise setBrightness(int v);
  external JSPromise getVolume();
  external JSPromise setVolume(int v);
}

@JS()
extension type PoseJS._(JSObject _) implements JSObject {
  external double get roll;
  external double get pitch;
  external double get yaw;
  external double get qw;
  external double get qx;
  external double get qy;
  external double get qz;
}

class VitureKit {
  JSObject? _mod;
  StreamController<VitureSensorData>? _sensorController;
  StreamController<VitureStateEvent>? _stateController;

  GlassesDevice? _device;
  bool _isConnected = false;
  Completer<void>? _connectingCompleter;

  bool _isHeadTrackingActive = false;
  bool _isStarting = false;
  bool _isReleasing = false;
  bool _scriptsLoaded = false;

  static String _cachedSdkVersion = '1.0.0';
  static int _cachedSdkVersionMajor = 1;
  static int _cachedSdkVersionMinor = 0;
  static int _cachedSdkVersionPatch = 0;
  static bool _sdkVersionLoaded = false;

  static String get sdkVersion => _cachedSdkVersion;
  static int get sdkVersionMajor => _cachedSdkVersionMajor;
  static int get sdkVersionMinor => _cachedSdkVersionMinor;
  static int get sdkVersionPatch => _cachedSdkVersionPatch;
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

  Future<void> _ensureScriptsLoaded() async {
    if (_scriptsLoaded) return;

    await _loadClassicScript(_resolve('glasses.js'));

    final moduleUrl = _absoluteUrl(_resolve('glasses-api.js'));
    final module = (await importModule(moduleUrl.toJS).toDart);

    globalContext['__VitureGlassesDevice'] = module['GlassesDevice'];

    _scriptsLoaded = true;
  }

  String _resolve(String file) {
    return 'assets/packages/viture_kit/assets/$file';
  }

  String _absoluteUrl(String relativePath) {
    return Uri.base.resolve(relativePath).toString();
  }

  Future<void> _loadClassicScript(String src) {
    final c = Completer<void>();
    final s = HTMLScriptElement()
      ..src = src
      ..async = true;
    s.onLoad.listen((_) => c.complete());
    s.onError.listen((_) => c.completeError('Failed to load $src'));
    document.head!.append(s);
    return c.future;
  }

  Future<GlassesDevice> _createRawDevice() async {
    await _ensureScriptsLoaded();

    final modFactory = globalContext['GlassesModule'] as JSFunction;
    final mod =
        await (modFactory.callAsFunction() as JSPromise).toDart as JSObject;
    _mod = mod;

    final deviceCtor = globalContext['__VitureGlassesDevice'] as JSFunction;
    final device = deviceCtor.callAsConstructor(mod) as GlassesDevice;
    return device;
  }

  Future<String> getSdkVersion() async {
    if (_mod == null) {
      await _createRawDevice();
    }
    final mod = _mod!;
    final ccall = mod['ccall'] as JSFunction;

    final emptyList = JSArray();
    final ptr = (ccall.callAsFunction(
      mod,
      'GetVersionString'.toJS,
      'number'.toJS,
      emptyList,
      emptyList,
    ) as JSNumber).toDartInt;

    final utf8ToString = mod['UTF8ToString'] as JSFunction;
    return (utf8ToString.callAsFunction(mod, ptr.toJS) as JSString).toDart;
  }

  static Future<void>? _sdkVersionLoadingFuture;

  Future<void> _loadSdkVersionIfNeeded() {
    if (_sdkVersionLoaded) return Future.value();
    return _sdkVersionLoadingFuture ??= () async {
      try {
        final version = await getSdkVersion();
        final clean = version.split('-').first;
        final parts = clean.split('.');
        _cachedSdkVersion = version;
        if (parts.isNotEmpty) {
          _cachedSdkVersionMajor =
              int.tryParse(parts[0]) ?? _cachedSdkVersionMajor;
        }
        if (parts.length > 1) {
          _cachedSdkVersionMinor =
              int.tryParse(parts[1]) ?? _cachedSdkVersionMinor;
        }
        if (parts.length > 2) {
          _cachedSdkVersionPatch =
              int.tryParse(parts[2]) ?? _cachedSdkVersionPatch;
        }
        _sdkVersionLoaded = true;
      } catch (_) {
      } finally {
        _sdkVersionLoadingFuture = null;
      }
    }();
  }

  Future<void> connect() async {
    if (_isConnected && _device != null) return;

    if (_connectingCompleter != null) {
      return _connectingCompleter!.future;
    }

    final completer = Completer<void>();
    _connectingCompleter = completer;
    try {
      final device = await _createRawDevice();
      await device.connect().toDart;
      _device = device;
      _isConnected = true;

      await _loadSdkVersionIfNeeded();

      completer.complete();
    } catch (e) {
      _device = null;
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
    final d = _device;
    if (d != null) {
      try {
        await d.disconnect().toDart;
      } catch (_) {}
    }
    _device = null;
    _isConnected = false;
  }

  Future<void> _opQueue = Future<void>.value();

  Future<T?> _withDevice<T>(FutureOr<T> Function(GlassesDevice d) action) {
    final result = _opQueue.then((_) async {
      try {
        await connect();
        final device = _device;
        if (device == null) return null;
        return await action(device);
      } catch (_) {
        return null;
      }
    });
    _opQueue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<int?> getBrightnessLevel({bool setDarwinOpenExclusive = false}) =>
      _withDevice((d) async {
        final result = await d.getBrightness().toDart;
        return (result as JSNumber).toDartInt;
      });

  Future<void> setBrightnessLevel(
    int level, {
    bool setDarwinOpenExclusive = false,
  }) => _withDevice((d) async {
    await d.setBrightness(level).toDart;
  });

  Future<int?> getVolumeLevel({bool setDarwinOpenExclusive = false}) =>
      _withDevice((d) async {
        final result = await d.getVolume().toDart;
        return (result as JSNumber).toDartInt;
      });

  Future<void> setVolumeLevel(
    int level, {
    bool setDarwinOpenExclusive = false,
  }) => _withDevice((d) async {
    await d.setVolume(level).toDart;
  });

  Future<HeadTrackingResponse> startHeadTracking({
    VitureImuFrequency imuFrequency = VitureImuFrequency.freq120Hz,
    bool setDarwinOpenExclusive = false,
  }) async {
    if (_isHeadTrackingActive || _isStarting) {
      return HeadTrackingResponse(
        status: true,
        message: 'Already running',
        code: 0,
      );
    }
    if (_isReleasing) {
      throw StateError('Cannot start while release is in progress');
    }

    _isStarting = true;
    try {
      _sensorController ??= StreamController<VitureSensorData>.broadcast();
      _stateController ??= StreamController<VitureStateEvent>.broadcast();

      final opFuture = _opQueue.then((_) async {
        await connect();
        final device = _device;
        if (device == null) {
          throw StateError('No device connected');
        }

        device.onStateChange(
          ((JSNumber id, JSNumber value) {
            final c = _stateController;
            if (c == null || c.isClosed) return;
            c.add(VitureStateEvent(id.toDartInt, value.toDartInt));
          }).toJS,
        );

        final freq = imuFrequency.value;
        await device
            .onPose(
              ((PoseJS pose) {
                if (!_isHeadTrackingActive) return;
                final c = _sensorController;
                if (c == null || c.isClosed) return;
                c.add(
                  VitureSensorData.pose(
                    roll: pose.roll,
                    pitch: pose.pitch,
                    yaw: pose.yaw,
                    quatW: pose.qw,
                    quatX: pose.qx,
                    quatY: pose.qy,
                    quatZ: pose.qz,
                    timestamp: DateTime.now().millisecondsSinceEpoch,
                  ),
                );
              }).toJS,
              freq.toJS,
            )
            .toDart;
      });
      _opQueue = opFuture.then((_) {}, onError: (_) {});
      await opFuture;

      _isHeadTrackingActive = true;
      return HeadTrackingResponse(
        status: true,
        message: 'Successfully started head tracking.',
        code: 0,
      );
    } catch (e) {
      await _forceCleanupHeadTracking();
      return HeadTrackingResponse(
        status: false,
        message: 'Unable to find the glasses.',
        code: -1,
      );
    } finally {
      _isStarting = false;
    }
  }

  Future<void> releaseHeadTracking() async {
    if (!_isHeadTrackingActive && !_isStarting) return;
    if (_isReleasing) return;
    _isReleasing = true;
    try {
      await _forceCleanupHeadTracking();
    } finally {
      _isReleasing = false;
    }
  }

  Future<void> _forceCleanupHeadTracking() async {
    _isHeadTrackingActive = false;
    final d = _device;
    if (d != null) {
      try {
        await d.offPose().toDart;
      } catch (_) {}
      try {
        d.offStateChange();
      } catch (_) {}
    }
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
    _mod = null;
  }

  static int? fetchHidapiVitureProductIds({
    bool setDarwinOpenExclusive = false,
  }) => null;
}
