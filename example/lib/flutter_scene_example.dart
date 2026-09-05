// import 'package:flutter/material.dart';
// import 'package:flutter_scene/scene.dart';
// import 'package:vector_math/vector_math.dart' as vm;

// class CubeView extends StatefulWidget {
//   const CubeView({super.key});

//   @override
//   State<CubeView> createState() => _CubeViewState();
// }

// class _CubeViewState extends State<CubeView> {
//   final Scene scene = Scene();
//   bool ready = false;

//   @override
//   void initState() {
//     super.initState();
//     Scene.initializeStaticResources().then((_) {
//       scene.add(
//         Node(
//           mesh: Mesh(
//             CuboidGeometry(vm.Vector3(1, 1, 1)),
//             PhysicallyBasedMaterial(),
//           ),
//         ),
//       );
//       if (mounted) setState(() => ready = true);
//     });
//   }

//   @override
//   Widget build(BuildContext context) {
//     if (!ready) return const SizedBox.expand();
//     return SceneView(
//       scene,
//       camera: PerspectiveCamera(position: vm.Vector3(2, 2, -4)),
//     );
//   }
// }
