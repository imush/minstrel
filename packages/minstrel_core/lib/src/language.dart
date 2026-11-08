/// Names for the language codes a media file carries on its audio and
/// subtitle tracks.
///
/// ISO 639-2 has two codes for several languages — a bibliographic and a
/// terminologic one — and rippers use either, so both are listed. Two-letter
/// 639-1 codes turn up too. Anything unrecognised is shown as it came:
/// a wrong guess is worse than an honest code.
String languageName(String code) {
  final c = code.toLowerCase().trim().split(RegExp('[-_]')).first;
  return _names[c] ?? code;
}

const _names = {
  'eng': 'English', 'en': 'English',
  'heb': 'Hebrew', 'he': 'Hebrew', 'iw': 'Hebrew',
  'fre': 'French', 'fra': 'French', 'fr': 'French',
  'ger': 'German', 'deu': 'German', 'de': 'German',
  'spa': 'Spanish', 'es': 'Spanish',
  'ita': 'Italian', 'it': 'Italian',
  'rus': 'Russian', 'ru': 'Russian',
  'por': 'Portuguese', 'pt': 'Portuguese',
  'dut': 'Dutch', 'nld': 'Dutch', 'nl': 'Dutch',
  'pol': 'Polish', 'pl': 'Polish',
  'ara': 'Arabic', 'ar': 'Arabic',
  'yid': 'Yiddish', 'yi': 'Yiddish',
  'jpn': 'Japanese', 'ja': 'Japanese',
  'chi': 'Chinese', 'zho': 'Chinese', 'zh': 'Chinese',
  'ukr': 'Ukrainian', 'uk': 'Ukrainian',
  'swe': 'Swedish', 'sv': 'Swedish',
  'nor': 'Norwegian', 'no': 'Norwegian',
  'dan': 'Danish', 'da': 'Danish',
  'fin': 'Finnish', 'fi': 'Finnish',
  'tur': 'Turkish', 'tr': 'Turkish',
  'gre': 'Greek', 'ell': 'Greek', 'el': 'Greek',
  'cze': 'Czech', 'ces': 'Czech', 'cs': 'Czech',
  'hun': 'Hungarian', 'hu': 'Hungarian',
  'rum': 'Romanian', 'ron': 'Romanian', 'ro': 'Romanian',
  'kor': 'Korean', 'ko': 'Korean',
  'hin': 'Hindi', 'hi': 'Hindi',
};
