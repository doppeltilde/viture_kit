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
