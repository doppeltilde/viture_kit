# Viture Kit

Native Dart FFI bindings for the [VITURE XR Glasses SDK](https://www.viture.com/).

![showcase](https://www.viture.com/images/developer/sdk-show.png)

## Platform Support

| Platform | Support |
| -------- | ------- |
| macOS    | ✅ Supported |
| iOS    | ❌ Unsupported |
| Linux    | ❌ Unsupported |
| Android  | ✅ Supported |
| Windows  | ✅ Supported |

## API Reference

### Core Class: `VitureKit`

| Method / Property | Type | Description |
|---|---|---|
| `sdkVersion` | `String` | Returns the native SDK version string. |
| `isHeadTrackingActive` | `bool` | Indicates whether IMU data is currently streaming. |
| `sensorStream` | `Stream<VitureSensorData>` | Broadcast stream delivering raw and parsed orientation updates. |
| `stateStream` | `Stream<VitureStateEvent>` | Broadcast stream delivering hardware changes. |
| `getBrightnessLevel({bool setDarwinOpenExclusive = false})` | `int` | Reads the current brightness level from the connected device. |
| `setBrightnessLevel(int level, {bool setDarwinOpenExclusive = false})` | `void` | Sets the brightness level for the connected device. |
| `getVolumeLevel({bool setDarwinOpenExclusive = false})` | `int` | Reads the current volume level from the connected device. |
| `setVolumeLevel(int level, , {bool setDarwinOpenExclusive = false})` | `void` | Sets the volume level for the connected device. |
| `startHeadTracking({int imuFrequency = VitureImuFrequency.freq120Hz, bool setDarwinOpenExclusive = false})` | `Future<HeadTrackingResponse>` | Initializes native bindings and starts receiving IMU data. Returns status, message, and code (-7 if glasses not found, 0 if successful). |
| `releaseHeadTracking()` | `Future<void>` | Safely shuts down the native provider and terminates the worker isolate. |
| `setHeadTrackingEnabled(bool enabled)` | `Future<void>` | Convenience toggle for starting or stopping head tracking. |
| `dispose()` | `Future<void>` | Releases tracking and closes the pose controller. |

### Model Class: `VitureSensorData`

| Field | Type | Description |
|---|---|---|
| `roll`, `pitch`, `yaw` | `double` | Device orientation in Euler angles. |
| `quatW`, `quatX`, `quatY`, `quatZ` | `double` | Device orientation as a quaternion. |
| `magX`, `magY`, `magZ` | `double?` | Magnetometer axes, populated only on magnetometer-capable devices (Luma / Luma Pro / Beast / Pro 2). `null` on devices without a magnetometer. |
| `temperature` | `double?` | Sensor temperature reading, populated alongside the magnetometer fields. `null` when unavailable. |
| `hasMagnetometer` | `bool` | Convenience getter indicating whether `magX`/`magY`/`magZ` are present. |
| `timestamp` | `int` | Timestamp associated with the pose sample. |

### Model Class: `HeadTrackingResponse`

| Field | Type | Description |
|---|---|---|
| `status` | `bool` | Indicates success or failure |
| `message` | `String` | Status or error description |
| `code` | `int` | Error code |

### Model Class: `VitureStateEvent`

| Field | Type | Description |
|---|---|---|
| `stateId` | `int` | Identifies which hardware setting changed. |
| `value` | `String` | The new numeric level or status. |

---

## Usage Example

```dart
import 'dart:async';
import 'package:viture_kit/viture_kit.dart';

Future<void> main() async {
  final viture = VitureKit();

  print('VITURE SDK Version: ${VitureKit.sdkVersion}');

  // 1. Listen to orientation events
  final subscription = viture.sensorStream.listen((VitureSensorData pose) {
    print('Roll: ${pose.roll}, Pitch: ${pose.pitch}, Yaw:${pose.yaw}');
    print('Quat: [${pose.quatW},${pose.quatX}, ${pose.quatY},${pose.quatZ}]');
  });

  // 2. Claim ownership of the IMU
  try {
    final HeadTrackingResponse headTrackingResponse = await viture.startHeadTracking();
    if (headTrackingResponse.status == false || headTrackingResponse.code == -7) {
      print(headTrackingResponse.message);
      return;
    }

    print('Head tracking started successfully.');
  } catch (e) {
    print('Failed to start head tracking: $e');
  }

  final subscription = viture.stateStream.listen((VitureStateEvent event) {
    final stateId = VitureStateId.fromId(event.stateId);
    print('State: $stateId, Value: ${event.value}');
  });

  // 3. Stop tracking and clean up
  await subscription.cancel();
  await viture.releaseHeadTracking();
  await viture.dispose();
  print('Head tracking released.');
}
```

---

## Caveat
> [!IMPORTANT]  
> When the Spacewalker App is open `viture_kit` will claim ownership of the IMU for head tracking, stopping head tracking on the Spacewalker app.

---
_Notice:_ _This project was initally created to be used in-house, as such the
development is first and foremost aligned with the internal requirements._
