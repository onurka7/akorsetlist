import 'package:flutter/material.dart';
import 'app.dart';
import 'state/ui_prefs.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await UiPrefs.initialize();
  runApp(const AkorApp());
}
