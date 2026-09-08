## 0.2.1
- **FEAT**: Expose SDK Version on Web.

## 0.2.0
- **BREAKING:** `getBrightnessLevel()` and `getVolumeLevel()` now return `Future<int?>` instead of `int?`. Callers must `await` these calls.
- **BREAKING:** `setBrightnessLevel()` and `setVolumeLevel()` now return `Future<void>` instead of `void`. Callers should `await` these calls to ensure the write completes before proceeding.
- **NEW:** `connect()` opens a persistent connection to the glasses, reused by all subsequent calls until `disconnect()` or `dispose()` is called.
- **NEW:** `disconnect()` closes the persistent connection, stopping head tracking first if active.
- **NEW**: `Web` support.

## 0.1.5
- New: `setDarwinOpenExclusive` argument.

## 0.1.4
- New: `stateStream`.

## 0.1.3
- `startHeadTracking` now returns `HeadTrackingResponse`.

## 0.1.2
- `getBrightnessLevel` and `getVolumeLevel` now return `null`.

## 0.1.1
- Windows support
- Android support

## 0.1.0
- fix: PAC failure during HID manager teardown
- breaking: `poseStream` is now `sensorStream`
- breaking: `takeHeadTracking` is now `startHeadTracking`
- breaking: `ViturePoseData` is now `VitureSensorData`

## 0.0.7
- added: magnetometer_raw_x, magnetometer_raw_y, magnetometer_raw_z, temperature

## 0.0.1

* Initial Release
