import 'package:flutter/material.dart';

void main() => runApp(const HuntTogetherApp());

class HuntTogetherApp extends StatelessWidget {
  const HuntTogetherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HuntTogether',
      theme: ThemeData(
        primarySwatch: Colors.green,
        useMaterial3: true,
      ),
      home: const Scaffold(
        body: Center(
          child: Text('HuntTogether MVP'),
        ),
      ),
    );
  }
}
