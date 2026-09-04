import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:viture_kit/viture_kit.dart';
import 'package:viture_kit_example/flutter_scene_example.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: SensorHomeScreen(),
    );
  }
}

class SensorHomeScreen extends StatefulWidget {
  const SensorHomeScreen({super.key});

  @override
  State<SensorHomeScreen> createState() => _SensorHomeScreenState();
}

class _SensorHomeScreenState extends State<SensorHomeScreen> {
  final VitureKit _vitureKit = VitureKit();

  double _brightness = 0;
  double _volume = 0;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadInitialValues();
    });
  }

  Future<void> _loadInitialValues() async {
    try {
      final levels = await Isolate.run(() {
        final viture = VitureKit();
        return (
          brightness: viture.getBrightnessLevel(),
          volume: viture.getVolumeLevel(),
        );
      });

      if (!mounted) return;

      setState(() {
        _brightness = levels.brightness.toDouble();
        _volume = levels.volume.toDouble();
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showErrorSnackBar('Failed to connect to device: $e');
    }
  }

  void _updateBrightness(double value) {
    setState(() => _brightness = value);
    try {
      _vitureKit.setBrightnessLevel(value.toInt());
    } catch (e) {
      _showErrorSnackBar('Failed to set brightness: $e');
    }
  }

  void _updateVolume(double value) {
    setState(() => _volume = value);
    try {
      _vitureKit.setVolumeLevel(value.toInt());
    } catch (e) {
      _showErrorSnackBar('Failed to set volume: $e');
    }
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  StreamSubscription<ViturePoseData>? _poseSubscription;

  bool _isBusy = false;

  double _pitch = 0.0;
  double _roll = 0.0;
  double _yaw = 0.0;

  // Values from Viture are in degrees
  static const double pitchThreshold = 15.0;
  static const double yawThreshold = 15.0;

  Future<void> _onToggleChanged(bool enabled) async {
    if (_isBusy) return;

    setState(() => _isBusy = true);

    try {
      if (enabled) {
        _poseSubscription = _vitureKit.poseStream.listen(
          (data) {
            if (!mounted) return;

            setState(() {
              _pitch = -data.pitch;
              _roll = -data.roll;
              _yaw = -data.yaw;
            });
          },
          onError: (Object error) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Head tracking error: $error')),
            );
          },
        );

        await _vitureKit.takeHeadTracking();
      } else {
        await _poseSubscription?.cancel();
        _poseSubscription = null;
        await _vitureKit.releaseHeadTracking();

        if (mounted) {
          setState(() {
            _pitch = 0.0;
            _roll = 0.0;
            _yaw = 0.0;
          });
        }
      }
    } catch (e) {
      if (enabled) {
        await _poseSubscription?.cancel();
        _poseSubscription = null;
      }

      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  @override
  void dispose() {
    _poseSubscription?.cancel();
    _vitureKit.dispose();
    super.dispose();
  }

  String _getDirectionText(double pitch, double yaw) {
    final isUp = pitch > pitchThreshold;
    final isDown = pitch < -pitchThreshold;
    final isRight = yaw > yawThreshold;
    final isLeft = yaw < -yawThreshold;

    if (!isUp && !isDown && !isRight && !isLeft) {
      return 'Looking straight';
    }

    String vertical = '';
    if (isUp) vertical = 'up';
    if (isDown) vertical = 'down';

    String horizontal = '';
    if (isRight) horizontal = 'right';
    if (isLeft) horizontal = 'left';

    if (vertical.isEmpty) return 'Looking $horizontal';
    if (horizontal.isEmpty) return 'Looking $vertical';

    return 'Looking $horizontal $vertical';
  }

  @override
  Widget build(BuildContext context) {
    const textStyle = TextStyle(fontSize: 15);
    const spacer = SizedBox(height: 12);

    final bool isActive = _vitureKit.isHeadTrackingActive;
    final directionText = _getDirectionText(_pitch, _yaw);

    return Scaffold(
      appBar: AppBar(title: const Text('VITURE Head Tracking')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton(
              onPressed: () async {
                final res = VitureKit.fetchHidapiVitureProductIds();
                print(res);
              },
              child: const Text("hidapi"),
            ),
            ElevatedButton(
              onPressed: () async {
                final res = _vitureKit.getBrightnessLevel();
                print(res);
              },
              child: const Text("Get Brightness"),
            ),
            ElevatedButton(
              onPressed: () async {
                final res = _vitureKit.getVolumeLevel();
                print(res);
              },
              child: const Text("Get Volume"),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const CubeView()),
                );
              },
              child: const Text("Cube Scene"),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Brightness: ${_brightness.toInt()}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Slider(
                  value: _brightness,
                  min: 0,
                  max: 8,
                  divisions: 8,
                  label: '${_brightness.toInt()}',
                  onChanged: _updateBrightness,
                ),
                const SizedBox(height: 16),
                Text(
                  'Volume: ${_volume.toInt()}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Slider(
                  value: _volume,
                  min: 0,
                  max: 8,
                  divisions: 8,
                  label: '${_volume.toInt()}',
                  onChanged: _updateVolume,
                ),
              ],
            ),
            Card(
              elevation: 2,
              child: SwitchListTile.adaptive(
                title: const Text('Take head tracking'),
                subtitle: Text(
                  isActive
                      ? 'Active – SpaceWalker tracking is disabled'
                      : 'Released – SpaceWalker can use tracking',
                ),
                value: isActive,
                onChanged: _isBusy ? null : _onToggleChanged,
              ),
            ),
            spacer,
            if (_isBusy)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Center(child: CircularProgressIndicator()),
              ),
            Expanded(
              child: !isActive
                  ? const Center(
                      child: Text(
                        'Head tracking is released.\n'
                        'SpaceWalker should be able to use the glasses.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : SingleChildScrollView(
                      child: Column(
                        children: [
                          Card(
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
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                'Pitch: ${_pitch.toStringAsFixed(1)}°   '
                                'Roll: ${_roll.toStringAsFixed(1)}°   '
                                'Yaw: ${_yaw.toStringAsFixed(1)}°',
                                style: textStyle,
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
    const double sensitivity = 0.85;

    final double yawRad = -yaw * math.pi / 180.0 * sensitivity;
    final double pitchRad = -pitch * math.pi / 180.0 * sensitivity;
    final double rollRad = roll * math.pi / 180.0 * sensitivity;

    final matrix = Matrix4.identity()
      ..setEntry(3, 2, 0.0015)
      ..rotateY(yawRad)
      ..rotateX(pitchRad)
      ..rotateZ(rollRad);

    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text(
              'Head',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 240,
              width: 240,
              child: Center(
                child: Transform(
                  alignment: Alignment.center,
                  transform: matrix,
                  child: ClipOval(
                    child: Image.network(
                      'https://randomuser.me/api/portraits/men/32.jpg',
                      width: 200,
                      height: 200,
                      fit: BoxFit.cover,
                      loadingBuilder: (context, child, loadingProgress) {
                        if (loadingProgress == null) return child;
                        return Container(
                          width: 200,
                          height: 200,
                          color: Colors.grey.shade200,
                          child: const Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        );
                      },
                      errorBuilder: (context, error, stackTrace) {
                        debugPrint('Image load error: $error');
                        // Nice fallback face
                        return Container(
                          width: 200,
                          height: 200,
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFDBAC),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.brown.shade400,
                              width: 3,
                            ),
                          ),
                          child: const Icon(
                            Icons.person,
                            size: 110,
                            color: Colors.brown,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
