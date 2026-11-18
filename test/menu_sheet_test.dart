import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minstrel/widgets/menu_sheet.dart';

void main() {
  // A phone held sideways in a car mount: short, so a long menu scrolls.
  Future<void> open(WidgetTester tester, {int rows = 20}) async {
    tester.view.physicalSize = const Size(2400, 1080);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showMenuSheet<void>(context,
                builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
                      for (var i = 0; i < rows; i++) ListTile(title: Text('Row $i')),
                    ])),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('a menu taller than the screen leaves some of the page above it', (tester) async {
    await open(tester);
    final screen = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final sheet = tester.getRect(find.byType(BottomSheet));
    expect(sheet.top, greaterThan(screen * 0.1));
  });

  testWidgets('pulling down from the top of a long menu closes it', (tester) async {
    await open(tester);
    expect(find.text('Row 0'), findsOneWidget);
    await tester.drag(find.text('Row 1'), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(find.text('Row 0'), findsNothing);
  });

  testWidgets('scrolling down a long menu leaves it open', (tester) async {
    await open(tester);
    await tester.drag(find.text('Row 3'), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    // And back up to the top, stopping there, still open.
    await tester.drag(find.byType(ListTile).hitTestable().first, const Offset(0, 150));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
  });

  testWidgets('a short menu fits and the last row is fully on screen', (tester) async {
    await open(tester, rows: 3);
    final screen = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(tester.getRect(find.text('Row 2')).bottom, lessThan(screen));
  });
}
