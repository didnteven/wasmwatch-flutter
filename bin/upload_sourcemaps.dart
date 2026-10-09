import 'dart:io';
import 'package:wasmwatch/src/cli/upload_sourcemaps.dart';

Future<void> main(List<String> arguments) async {
  try {
    stdout.writeln(await runUploadSourcemaps(arguments));
  } catch (error) {
    stderr.writeln('wasmwatch: $error');
    exitCode = 1;
  }
}
