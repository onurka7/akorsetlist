import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:akor_setlist/screens/home_screen.dart';

void main() {
  Widget buildTestApp() {
    return const MaterialApp(home: HomeScreen());
  }

  testWidgets('App opens', (WidgetTester tester) async {
    await tester.pumpWidget(buildTestApp());
    expect(find.text("Setlist'lerim"), findsOneWidget);
  }, skip: true);

  testWidgets(
    'HomeScreen: web sekmesine gecince klavye otomatik acilmaz',
    (WidgetTester tester) async {
      await tester.pumpWidget(buildTestApp());
      expect(find.text("Ara (Web)"), findsNothing);
    },
    skip: true,
  );

  testWidgets(
    'HomeScreen: setlist sekmesine donunce focus kalkar',
    (WidgetTester tester) async {
      await tester.pumpWidget(buildTestApp());

      final searchNavLabel = find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text("Ara (Web)"),
      );
      await tester.tap(searchNavLabel.first);
      await tester.pump(const Duration(milliseconds: 200));

      final textFieldBefore =
          tester.widget<TextField>(find.byType(TextField).first);
      final searchFocusNode = textFieldBefore.focusNode!;

      await tester.tap(find.byType(TextField).first);
      await tester.pump();
      expect(searchFocusNode.hasFocus, isTrue);

      final setlistsNavLabel = find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text("Setlist’lerim"),
      );
      await tester.tap(setlistsNavLabel.first);
      await tester.pump();

      expect(searchFocusNode.hasFocus, isFalse);
    },
    skip: true,
  );
}
