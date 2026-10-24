import 'dart:io';
import 'package:wasmwatch/src/cli/upload_symbols.dart';

Future<void> main(List<String> arguments) async {
  try {
    stdout.writeln(await runUploadSymbols(arguments));
  } catch (error) {
    stderr.writeln('wasmwatch: $error');
    exitCode = 1;
  }
}
