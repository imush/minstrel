// Which of two copies of a track is good enough to play, which decides
// whether the cache on a phone can stand in for the library at home.
import 'package:minstrel_core/minstrel_core.dart';
import 'package:test/test.dart';

DidlResource res(String mime,
        {int? bitrate, int? sampleFrequency, int? bitsPerSample}) =>
    DidlResource(
      uri: Uri.parse('http://h/a'),
      protocolInfo: ProtocolInfo.parse('http-get:*:$mime:*'),
      bitrate: bitrate,
      sampleFrequency: sampleFrequency,
      bitsPerSample: bitsPerSample,
    );

void main() {
  final flac = res('audio/flac', sampleFrequency: 44100, bitsPerSample: 16);
  final hiRes = res('audio/flac', sampleFrequency: 96000, bitsPerSample: 24);
  final mp3 = res('audio/mpeg', bitrate: 40000); // 320 kbit/s
  final mp3Low = res('audio/mpeg', bitrate: 16000);

  test('a copy is as good as itself', () {
    expect(flac.atLeast(flac), isTrue);
    expect(flac.isBetterThan(flac), isFalse, reason: 'nothing to re-fetch');
  });

  test('lossless beats lossy however high the bitrate', () {
    expect(flac.atLeast(mp3), isTrue);
    expect(mp3.atLeast(flac), isFalse);
    expect(flac.isBetterThan(mp3), isTrue);
  });

  test('a higher sample format is better, a lower one is not enough', () {
    expect(hiRes.atLeast(flac), isTrue);
    expect(flac.atLeast(hiRes), isFalse);
    expect(hiRes.isBetterThan(flac), isTrue);
  });

  test('lossless of another kind is a wash', () {
    final wav = res('audio/wav', sampleFrequency: 44100, bitsPerSample: 16);
    expect(wav.atLeast(flac), isTrue);
    expect(flac.atLeast(wav), isTrue);
    expect(wav.isBetterThan(flac), isFalse, reason: 'same music, no reason to swap');
  });

  test('lossy copies are told apart by bitrate', () {
    expect(mp3.atLeast(mp3Low), isTrue);
    expect(mp3Low.atLeast(mp3), isFalse);
  });

  test('an unknown sample format does not block a lossless stand-in', () {
    final bare = res('audio/flac');
    expect(bare.atLeast(flac), isTrue);
    expect(flac.atLeast(bare), isTrue);
  });

  test('the same lossy format with nothing to compare is taken as the same encode', () {
    expect(res('audio/mpeg').atLeast(res('audio/mpeg')), isTrue);
  });

  test('different lossy formats with no bitrate are not assumed equal', () {
    expect(res('audio/mpeg').atLeast(res('audio/mp4')), isFalse,
        reason: 'cautious: stream rather than play a possibly worse copy');
  });
}
