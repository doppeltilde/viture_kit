import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:viture_sensors/viture_kit.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: SensorHomeScreen());
  }
}

class SensorHomeScreen extends StatefulWidget {
  const SensorHomeScreen({super.key});

  @override
  State<SensorHomeScreen> createState() => _SensorHomeScreenState();
}

class _SensorHomeScreenState extends State<SensorHomeScreen> {
  final VitureKit _vitureKit = VitureKit();
  StreamSubscription<ViturePoseData>? _poseSubscription;
  bool _isStreaming = false;

  double _pitch = 0.0;
  double _roll = 0.0;
  double _yaw = 0.0;

  static const double pitchThreshold = 0.30;
  static const double yawThreshold = 0.30;

  Future<void> _toggleStreaming() async {
    if (_isStreaming) {
      await _poseSubscription?.cancel();
      _poseSubscription = null;
      await _vitureKit.stop();
      if (mounted) {
        setState(() {
          _isStreaming = false;
          _pitch = 0.0;
          _roll = 0.0;
          _yaw = 0.0;
        });
      }
    } else {
      await _vitureKit.start(productId: VitureProductId.viturePro2);

      // Listen to native Pose stream outside of build()
      _poseSubscription = _vitureKit.poseStream.listen((data) {
        if (mounted) {
          setState(() {
            _pitch = data.pitch;
            _roll = data.roll;
            _yaw = data.yaw;
          });
        }
      });

      if (mounted) {
        setState(() => _isStreaming = true);
      }
    }
  }

  @override
  void dispose() {
    _poseSubscription?.cancel();
    _vitureKit.stop();
    super.dispose();
  }

  String _getDirectionText(double pitch, double yaw) {
    String vertical = '';
    if (pitch > pitchThreshold) {
      vertical = 'up';
    } else if (pitch < -pitchThreshold) {
      vertical = 'down';
    }

    String horizontal = '';
    if (yaw > yawThreshold) {
      horizontal = 'right';
    } else if (yaw < -yawThreshold) {
      horizontal = 'left';
    }

    if (vertical.isEmpty && horizontal.isEmpty) {
      return 'Looking straight';
    }
    if (vertical.isEmpty) return 'Looking $horizontal';
    if (horizontal.isEmpty) return 'Looking $vertical';
    return 'Looking $horizontal $vertical';
  }

  @override
  Widget build(BuildContext context) {
    const textStyle = TextStyle(fontSize: 15);
    const spacer = SizedBox(height: 12);

    final directionText = _getDirectionText(_pitch, _yaw);

    return Scaffold(
      appBar: AppBar(title: const Text('VITURE Head Tracking')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton(
              onPressed: _toggleStreaming,
              child: Text(
                _isStreaming ? 'Stop IMU Stream' : 'Start IMU Stream',
              ),
            ),
            spacer,
            Expanded(
              child: !_isStreaming
                  ? const Center(
                      child: Text(
                        'Stream is offline.\nTap "Start IMU Stream" to begin.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : SingleChildScrollView(
                      child: Column(
                        children: [
                          Card(
                            color: Colors.blue.shade50,
                            elevation: 3,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 16,
                                horizontal: 20,
                              ),
                              child: Text(
                                directionText,
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blueAccent,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                          spacer,
                          HeadVisualizer(pitch: _pitch, roll: _roll, yaw: _yaw),
                          spacer,
                          Card(
                            elevation: 2,
                            child: Padding(
                              padding: const EdgeInsets.all(12.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Pitch: ${_pitch.toStringAsFixed(2)}   '
                                    'Roll: ${_roll.toStringAsFixed(2)}   '
                                    'Yaw: ${_yaw.toStringAsFixed(2)}',
                                    style: textStyle,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class HeadVisualizer extends StatelessWidget {
  final double pitch;
  final double roll;
  final double yaw;

  const HeadVisualizer({
    super.key,
    required this.pitch,
    required this.roll,
    required this.yaw,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            const Text(
              'Head',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 240,
              width: 240,
              child: CustomPaint(
                painter: HeadPainter(pitch: pitch, roll: roll, yaw: yaw),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HeadPainter extends CustomPainter {
  final double pitch;
  final double roll;
  final double yaw;

  HeadPainter({required this.pitch, required this.roll, required this.yaw});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width * 0.36;

    canvas.drawCircle(
      center,
      radius + 20,
      Paint()..color = Colors.grey.shade200,
    );
    canvas.drawCircle(
      center,
      radius + 20,
      Paint()
        ..color = Colors.grey.shade400
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    canvas.save();
    canvas.translate(center.dx, center.dy);

    canvas.rotate(yaw);
    canvas.rotate(roll * 0.6);

    final double pitchAmount = pitch.clamp(-1.4, 1.4);
    final double faceShiftY = pitchAmount * radius * 0.85;
    final double faceScaleY = (1.0 - pitchAmount.abs() * 0.40).clamp(0.50, 1.0);

    final headPaint = Paint()..color = const Color(0xFFFFDBAC);
    final outline = Paint()
      ..color = Colors.brown.shade400
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.8;

    final headRect = Rect.fromCenter(
      center: Offset(0, faceShiftY * 0.15),
      width: radius * 2,
      height: radius * 2 * faceScaleY,
    );
    canvas.drawOval(headRect, headPaint);
    canvas.drawOval(headRect, outline);

    final double featureY = faceShiftY;

    final eyeWhite = Paint()..color = Colors.white;
    final pupil = Paint()..color = Colors.black87;
    final eyeX = radius * 0.30;
    final eyeBaseY = featureY - radius * 0.20;

    canvas.drawCircle(Offset(-eyeX, eyeBaseY), radius * 0.14, eyeWhite);
    canvas.drawCircle(
      Offset(-eyeX + math.sin(yaw) * 4, eyeBaseY + pitchAmount * 8),
      radius * 0.075,
      pupil,
    );

    canvas.drawCircle(Offset(eyeX, eyeBaseY), radius * 0.14, eyeWhite);
    canvas.drawCircle(
      Offset(eyeX + math.sin(yaw) * 4, eyeBaseY + pitchAmount * 8),
      radius * 0.075,
      pupil,
    );

    final brow = Paint()
      ..color = Colors.brown.shade800
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;

    final browY = eyeBaseY - 18;
    canvas.drawLine(
      Offset(-eyeX - 14, browY - pitchAmount * 10),
      Offset(-eyeX + 14, browY - pitchAmount * 4),
      brow,
    );
    canvas.drawLine(
      Offset(eyeX - 14, browY - pitchAmount * 4),
      Offset(eyeX + 14, browY - pitchAmount * 10),
      brow,
    );

    final noseY = featureY + radius * 0.05;
    final nosePath = Path()
      ..moveTo(0, noseY - 12)
      ..lineTo(-7, noseY + 10)
      ..lineTo(7, noseY + 10)
      ..close();
    canvas.drawPath(
      nosePath,
      Paint()
        ..color = Colors.brown.shade400
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    final mouthY = featureY + radius * 0.42;
    final mouthPaint = Paint()
      ..color = Colors.red.shade400
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.8
      ..strokeCap = StrokeCap.round;

    final smileFactor = (-pitchAmount * 15).clamp(-18.0, 18.0);
    final mouthPath = Path()
      ..moveTo(-radius * 0.24, mouthY)
      ..quadraticBezierTo(0, mouthY + smileFactor, radius * 0.24, mouthY);
    canvas.drawPath(mouthPath, mouthPaint);

    final earPaint = Paint()..color = const Color(0xFFFFDBAC);
    canvas.drawCircle(
      Offset(-radius * 0.97, faceShiftY * 0.1),
      radius * 0.17,
      earPaint,
    );
    canvas.drawCircle(
      Offset(radius * 0.97, faceShiftY * 0.1),
      radius * 0.17,
      earPaint,
    );
    canvas.drawCircle(
      Offset(-radius * 0.97, faceShiftY * 0.1),
      radius * 0.17,
      outline,
    );
    canvas.drawCircle(
      Offset(radius * 0.97, faceShiftY * 0.1),
      radius * 0.17,
      outline,
    );

    final arrowPaint = Paint()..color = Colors.blueAccent;
    final arrowPath = Path()
      ..moveTo(0, -radius * 1.15 + faceShiftY * 0.3)
      ..lineTo(-13, -radius * 0.93 + faceShiftY * 0.3)
      ..lineTo(13, -radius * 0.93 + faceShiftY * 0.3)
      ..close();
    canvas.drawPath(arrowPath, arrowPaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant HeadPainter oldDelegate) {
    return oldDelegate.pitch != pitch ||
        oldDelegate.roll != roll ||
        oldDelegate.yaw != yaw;
  }
}
