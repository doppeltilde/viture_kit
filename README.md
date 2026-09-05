# Viture Kit

Native Dart FFI bindings for the [VITURE XR Glasses SDK](https://www.viture.com/).

![showcase](https://www.viture.com/images/developer/sdk-show.png)

## API Reference

### Core Class: `VitureKit`

| Method / Property | Type | Description |
|---|---|---|
| `sdkVersion` | `String` | Returns the native SDK version string. |
| `isHeadTrackingActive` | `bool` | Indicates whether IMU data is currently streaming. |
| `poseStream` | `Stream<ViturePoseData>` | Broadcast stream delivering raw and parsed orientation updates. |
| `getBrightnessLevel()` | `int` | Reads the current brightness level from the connected device. |
| `setBrightnessLevel(int level)` | `void` | Sets the brightness level for the connected device. |
| `getVolumeLevel()` | `int` | Reads the current volume level from the connected device. |
| `setVolumeLevel(int level)` | `void` | Sets the volume level for the connected device. |
| `takeHeadTracking({int productId})` | `Future<void>` | Initializes native bindings and starts receiving IMU data. |
| `releaseHeadTracking()` | `Future<void>` | Safely shuts down the native provider and terminates the worker isolate. |
| `setHeadTrackingEnabled(bool enabled)` | `Future<void>` | Convenience toggle for starting or stopping head tracking. |
| `dispose()` | `Future<void>` | Releases tracking and closes the pose controller. |

### Data Models & Constants

#### `ViturePoseData`
Holds orientation and timestamp attributes:
* `roll`, `pitch`, `yaw`: `double` (Euler angles)
* `quatW`, `quatX`, `quatY`, `quatZ`: `double` (Quaternion orientation)
* `timestamp`: `int`

---

## Usage Example

```dart
import 'dart:async';
import 'package:viture_kit/viture_kit.dart';

Future<void> main() async {
  final viture = VitureKit();

  print('VITURE SDK Version: ${VitureKit.sdkVersion}');

  // 1. Listen to orientation events
  final subscription = viture.poseStream.listen((ViturePoseData pose) {
    print('Roll: ${pose.roll}, Pitch: ${pose.pitch}, Yaw:${pose.yaw}');
    print('Quat: [${pose.quatW},${pose.quatX}, ${pose.quatY},${pose.quatZ}]');
  });

  // 2. Claim ownership of the IMU
  try {
    await viture.takeHeadTracking();
    print('Head tracking started successfully.');
  } catch (e) {
    print('Failed to start head tracking: $e');
  }

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
> When the Spacewalker App is open `VitureKit` will assume control of the IMU for head tracking, stopping tracking on the Spacewalker app.

---
_Notice:_ _This project was initally created to be used in-house, as such the
development is first and foremost aligned with the internal requirements._
