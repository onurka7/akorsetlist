import 'package:flutter/material.dart';
import 'app.dart';
import 'state/auth_state.dart';
import 'state/membership_state.dart';
import 'state/ui_prefs.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await UiPrefs.initialize();
  await AuthState.instance.initialize();
  await MembershipState.instance.initialize();
  runApp(const AkorApp());
}
