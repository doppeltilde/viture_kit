import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final os = input.config.code.targetOS;
    final arch = input.config.code.targetArchitecture;

    late final List<String> dylibNames;
    late final Uri sourceDir;

    switch (os) {
      case OS.macOS:
        dylibNames = ['libglasses.dylib'];
        sourceDir = input.packageRoot.resolve('src/macos/');
        break;

      case OS.windows:
        dylibNames = [
          'glasses.dll',
          'libusb-1.0.dll',
          'glew32.dll',
          'opencv_world4100.dll',
        ];
        sourceDir = input.packageRoot.resolve('src/windows/');
        break;

      case OS.android:
        final abi = (arch == Architecture.arm64) ? 'arm64-v8a' : 'armeabi-v7a';
        dylibNames = ['libglasses.so'];
        sourceDir = input.packageRoot.resolve('src/android/$abi/');
        break;

      default:
        return;
    }

    for (final dylibName in dylibNames) {
      final sourceDylib = sourceDir.resolve(dylibName);
      final sourceFile = File.fromUri(sourceDylib);

      if (!await sourceFile.exists()) {
        throw StateError('Missing dynamic library at: ${sourceFile.path}');
      }

      final targetDylib = input.outputDirectoryShared.resolve(dylibName);
      final targetFile = File.fromUri(targetDylib);

      if (!await targetFile.exists()) {
        await sourceFile.copy(targetFile.path);
      }

      final assetName = dylibName.replaceAll(RegExp(r'\.(dylib|so|dll)$'), '');

      output.assets.code.add(
        CodeAsset(
          package: input.packageName,
          name: assetName,
          linkMode: DynamicLoadingBundled(),
          file: targetDylib,
        ),
      );
    }
  });
}
