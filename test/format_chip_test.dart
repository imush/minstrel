import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minstrel/widgets/format_chip.dart';

void main() {
  Future<void> show(WidgetTester tester, {String? others}) => tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Center(child: FormatChip(format: 'WAV 24/352.8', others: others))),
      ));

  testWidgets('a tap shows the original behind an upsampled stream, another hides it', (tester) async {
    await show(tester, others: 'FLAC 16/44.1');
    expect(find.text('WAV 24/352.8'), findsOneWidget);

    await tester.tap(find.byType(FormatChip));
    await tester.pump();
    expect(find.text('WAV 24/352.8 (also FLAC 16/44.1)'), findsOneWidget);

    await tester.tap(find.byType(FormatChip));
    await tester.pump();
    expect(find.text('WAV 24/352.8'), findsOneWidget);
  });

  testWidgets('with one format there is nothing to tap', (tester) async {
    await show(tester);
    expect(find.text('WAV 24/352.8'), findsOneWidget);
    expect(find.byType(ActionChip), findsNothing);
  });
}
