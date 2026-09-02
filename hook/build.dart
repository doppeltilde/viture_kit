import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    // Only ship the macOS dylib for now
    if (input.config.code.targetOS != OS.macOS) {
      return;
    }

    final sourceDylib = input.packageRoot.resolve('src/libglasses.dylib');
    final sourceFile = File.fromUri(sourceDylib);

    if (!await sourceFile.exists()) {
      throw StateError('Missing dynamic library at: ${sourceFile.path}');
    }

    // Prefer outputDirectory (per-architecture) or outputDirectoryShared
    final targetDylib = input.outputDirectoryShared.resolve('libglasses.dylib');

    // Only copy if it doesn't already exist (avoids unnecessary work)
    final targetFile = File.fromUri(targetDylib);
    if (!await targetFile.exists()) {
      await sourceFile.copy(targetFile.path);
    }

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'libglasses',
        linkMode: DynamicLoadingBundled(),
        file: targetDylib,
      ),
    );
  });
}
