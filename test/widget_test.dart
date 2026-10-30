import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minstrel/pages/browse_page.dart';
import 'package:minstrel/pages/settings_page.dart';
import 'package:minstrel/widgets/cover_art.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  test('formatDuration', () {
    expect(formatDuration(const Duration(minutes: 4, seconds: 5)), '4:05');
    expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
    expect(formatDuration(null), '');
  });

  test('filter text ignores case and accents', () {
    expect(foldForSearch('Dvořák'), 'dvorak');
    expect(foldForSearch('BEYONCÉ'), 'beyonce');
    expect(foldForSearch('Straße Œuvre'), 'strasse oeuvre');
  });

  testWidgets('settings show the version and build', (tester) async {
    PackageInfo.setMockInitialValues(
        appName: 'Minstrel', packageName: 'p', version: '1.0.1', buildNumber: '11', buildSignature: '');
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: AppVersion())));
    await tester.pump();
    expect(find.text('Minstrel 1.0.1 (build 11)'), findsOneWidget);
  });
}
