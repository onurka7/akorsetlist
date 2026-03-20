import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UiPrefs {
  UiPrefs._();

  static const _chordColorKey = 'ui.chordColor';

  static final ValueNotifier<Color> chordColor = ValueNotifier<Color>(
    const Color(0xFFB00020),
  );

  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final savedValue = prefs.getInt(_chordColorKey);
    if (savedValue != null) {
      chordColor.value = Color(savedValue);
    }
  }

  static Future<void> setChordColor(Color color) async {
    chordColor.value = color;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_chordColorKey, color.toARGB32());
  }
}
