import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    if (input.config.code.targetOS != OS.macOS) {
      return;
    }

    final dylibs = [
      'libglasses.dylib',
      // 'libusb-1.0.0.dylib',
      // 'libhidapi.0.15.0.dylib',
    ];

    for (final dylibName in dylibs) {
      final sourceDylib = input.packageRoot.resolve('src/$dylibName');
      final sourceFile = File.fromUri(sourceDylib);

      if (!await sourceFile.exists()) {
        throw StateError('Missing dynamic library at: ${sourceFile.path}');
      }

      final targetDylib = input.outputDirectoryShared.resolve(dylibName);
      final targetFile = File.fromUri(targetDylib);

      if (!await targetFile.exists()) {
        await sourceFile.copy(targetFile.path);
      }

      // Name used internally by Native Assets (without extension)
      final assetName = dylibName.replaceAll('.dylib', '');

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
