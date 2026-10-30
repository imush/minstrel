import 'package:flutter_test/flutter_test.dart';
import 'package:minstrel/widgets/cover_art.dart';

void main() {
  test('formatDuration', () {
    expect(formatDuration(const Duration(minutes: 4, seconds: 5)), '4:05');
    expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
    expect(formatDuration(null), '');
  });
}
