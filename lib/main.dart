import 'package:flutter/material.dart';

import 'app_services.dart';
import 'pages/servers_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppServices.init();
  runApp(const MinstrelApp());
}

class MinstrelApp extends StatelessWidget {
  const MinstrelApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF6B4E9B);
    return MaterialApp(
      title: 'Minstrel',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      home: const ServersPage(),
    );
  }
}
