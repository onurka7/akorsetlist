import 'package:flutter/material.dart';
import 'screens/auth_gate_screen.dart';
import 'state/auth_state.dart';
import 'state/membership_state.dart';

class AkorApp extends StatefulWidget {
  const AkorApp({super.key});

  @override
  State<AkorApp> createState() => _AkorAppState();
}

class _AkorAppState extends State<AkorApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  @override
  void initState() {
    super.initState();
    AuthState.instance.initialize();
    MembershipState.instance.initialize();
  }

  void _setDarkMode(bool isDark) {
    setState(() {
      _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF4F6FA),
        colorScheme: const ColorScheme.light(
          primary: Color(0xFFFFC83D),
        ),
        iconTheme: const IconThemeData(color: Color(0xFFFFC83D)),
        appBarTheme: const AppBarTheme(
          foregroundColor: Colors.black,
          iconTheme: IconThemeData(color: Color(0xFFFFC83D)),
          actionsIconTheme: IconThemeData(color: Color(0xFFFFC83D)),
        ),
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F1115),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFFC83D),
        ),
        iconTheme: const IconThemeData(color: Color(0xFFFFC83D)),
        appBarTheme: const AppBarTheme(
          foregroundColor: Colors.white,
          iconTheme: IconThemeData(color: Color(0xFFFFC83D)),
          actionsIconTheme: IconThemeData(color: Color(0xFFFFC83D)),
        ),
      ),
      home: AuthGateScreen(
        isDarkMode: _themeMode == ThemeMode.dark,
        onThemeChanged: _setDarkMode,
      ),
    );
  }
}
