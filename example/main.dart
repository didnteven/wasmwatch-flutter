import 'package:flutter/material.dart';
import 'package:wasmwatch/wasmwatch.dart';

Future<void> main() async {
  await WasmWatch.init(
    dsn: 'https://PUBLIC_KEY@your-host/api/v1/envelope/PROJECT_ID',
    appRunner: () => runApp(const MyApp()),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('WasmWatch example')),
        body: Center(
          child: ElevatedButton(
            onPressed: () => throw StateError('WasmWatch example error'),
            child: const Text('Throw test error'),
          ),
        ),
      ),
    );
  }
}
