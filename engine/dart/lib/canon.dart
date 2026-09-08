/// B1-CANON-1 for Dart, including SHA-256.
///
/// Normative definition: SPEC/20-b1-canon-1.md. Written independently rather than bound to
/// libb1sig, so its agreement with the normative implementation is a genuine cross-check.
///
/// `jsonDecode` is not used: it keeps the last of a set of duplicate member names, one of the
/// silent repairs this profile is required to reject.
library;

import 'dart:convert';
import 'dart:typed_data';

const int maxDepth = 64;
const int maxSafe = 9007199254740991; // 2^53 - 1
final RegExp keyRe = RegExp(r'^[A-Za-z0-9_$.\-]{1,64}$');

class B1Error implements Exception {
  final String token;
  final String detail;

  B1Error(this.token, [this.detail = '']);

  @override
  String toString() => detail.isEmpty ? token : '$token: $detail';
}

// --- SHA-256 (FIPS 180-4) ----------------------------------------------------

const List<int> _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

String sha256Hex(List<int> message) {
  final h = Uint32List.fromList([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]);

  final bitLen = message.length * 8;
  final paddedLen = ((message.length + 9 + 63) ~/ 64) * 64;
  final padded = Uint8List(paddedLen);
  padded.setRange(0, message.length, message);
  padded[message.length] = 0x80;
  for (var i = 0; i < 8; i++) {
    padded[paddedLen - 1 - i] = (bitLen >> (8 * i)) & 0xff;
  }

  final w = Uint32List(64);
  for (var off = 0; off < paddedLen; off += 64) {
    for (var t = 0; t < 16; t++) {
      w[t] = (padded[off + t * 4] << 24) |
          (padded[off + t * 4 + 1] << 16) |
          (padded[off + t * 4 + 2] << 8) |
          padded[off + t * 4 + 3];
    }
    for (var t = 16; t < 64; t++) {
      final s0 = _rotr(w[t - 15], 7) ^ _rotr(w[t - 15], 18) ^ (w[t - 15] >> 3);
      final s1 = _rotr(w[t - 2], 17) ^ _rotr(w[t - 2], 19) ^ (w[t - 2] >> 10);
      w[t] = (s1 + w[t - 7] + s0 + w[t - 16]) & 0xffffffff;
    }

    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];

    for (var t = 0; t < 64; t++) {
      final bsig1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ (~e & g);
      final t1 = (hh + bsig1 + ch + _k[t] + w[t]) & 0xffffffff;
      final bsig0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (bsig0 + maj) & 0xffffffff;

      hh = g; g = f; f = e; e = (d + t1) & 0xffffffff;
      d = c; c = b; b = a; a = (t1 + t2) & 0xffffffff;
    }

    h[0] = (h[0] + a) & 0xffffffff; h[1] = (h[1] + b) & 0xffffffff;
    h[2] = (h[2] + c) & 0xffffffff; h[3] = (h[3] + d) & 0xffffffff;
    h[4] = (h[4] + e) & 0xffffffff; h[5] = (h[5] + f) & 0xffffffff;
    h[6] = (h[6] + g) & 0xffffffff; h[7] = (h[7] + hh) & 0xffffffff;
  }

  return h.map((x) => x.toRadixString(16).padLeft(8, '0')).join();
}

// --- strict parser -----------------------------------------------------------

class _Parser {
  final String s;
  int i = 0;

  _Parser(this.s);

  Object? parse() {
    _ws();
    final v = _value(0);
    _ws();
    if (i != s.length) throw B1Error('B1_ERR_PARSE', 'trailing input');
    return v;
  }

  void _ws() {
    while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) {
      i++;
    }
  }

  void _lit(String word) {
    if (s.startsWith(word, i)) {
      i += word.length;
    } else {
      throw B1Error('B1_ERR_PARSE', 'expected $word');
    }
  }

  Object? _value(int depth) {
    if (depth > maxDepth) throw B1Error('B1_ERR_DEPTH', 'depth > $maxDepth');
    if (i >= s.length) throw B1Error('B1_ERR_PARSE', 'unexpected end of input');
    final c = s[i];
    if (c == '{') return _object(depth);
    if (c == '[') return _array(depth);
    if (c == '"') return _string();
    if (c == 't') { _lit('true'); return true; }
    if (c == 'f') { _lit('false'); return false; }
    if (c == 'n') { _lit('null'); return null; }
    if (c == '-' || (c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57)) return _number();
    throw B1Error('B1_ERR_PARSE', 'unexpected character $c');
  }

  Map<String, Object?> _object(int depth) {
    i++;
    final map = <String, Object?>{};
    _ws();
    if (i < s.length && s[i] == '}') { i++; return map; }
    while (true) {
      _ws();
      if (i >= s.length || s[i] != '"') throw B1Error('B1_ERR_PARSE', 'expected key');
      final key = _string();
      if (!keyRe.hasMatch(key)) throw B1Error('B1_ERR_KEY_SYNTAX', key);
      if (map.containsKey(key)) throw B1Error('B1_ERR_DUPLICATE_KEY', key);
      _ws();
      if (i >= s.length || s[i] != ':') throw B1Error('B1_ERR_PARSE', "expected ':'");
      i++;
      _ws();
      map[key] = _value(depth + 1);
      _ws();
      if (i >= s.length) throw B1Error('B1_ERR_PARSE', 'unterminated object');
      if (s[i] == ',') { i++; continue; }
      if (s[i] == '}') { i++; return map; }
      throw B1Error('B1_ERR_PARSE', "expected ',' or '}'");
    }
  }

  List<Object?> _array(int depth) {
    i++;
    final items = <Object?>[];
    _ws();
    if (i < s.length && s[i] == ']') { i++; return items; }
    while (true) {
      _ws();
      items.add(_value(depth + 1));
      _ws();
      if (i >= s.length) throw B1Error('B1_ERR_PARSE', 'unterminated array');
      if (s[i] == ',') { i++; continue; }
      if (s[i] == ']') { i++; return items; }
      throw B1Error('B1_ERR_PARSE', "expected ',' or ']'");
    }
  }

  int _number() {
    final start = i;
    if (s[i] == '-') i++;
    final digitsStart = i;
    while (i < s.length && s.codeUnitAt(i) >= 48 && s.codeUnitAt(i) <= 57) {
      i++;
    }
    if (i == digitsStart) throw B1Error('B1_ERR_PARSE', 'expected digits');
    if (i - digitsStart > 1 && s[digitsStart] == '0') {
      throw B1Error('B1_ERR_PARSE', 'leading zero');
    }
    if (i < s.length && (s[i] == '.' || s[i] == 'e' || s[i] == 'E')) {
      throw B1Error('B1_ERR_NONINTEGER_NUMBER', 'non-integer');
    }
    final text = s.substring(start, i);
    if (text == '-0') throw B1Error('B1_ERR_NONINTEGER_NUMBER', 'negative zero');
    final v = int.tryParse(text);
    if (v == null || v > maxSafe || v < -maxSafe) {
      throw B1Error('B1_ERR_NONINTEGER_NUMBER', 'out of range: $text');
    }
    return v;
  }

  int _hex4() {
    if (i + 4 > s.length) throw B1Error('B1_ERR_PARSE', 'truncated escape');
    final hex = s.substring(i, i + 4);
    final v = int.tryParse(hex, radix: 16);
    if (v == null || !RegExp(r'^[0-9a-fA-F]{4}$').hasMatch(hex)) {
      throw B1Error('B1_ERR_PARSE', 'bad \\u escape');
    }
    i += 4;
    return v;
  }

  /// Joins a surrogate pair into one scalar; either half alone is rejected (SPEC/20 R3).
  String _unicodeEscape() {
    final cp = _hex4();
    if (cp >= 0xD800 && cp <= 0xDBFF) {
      if (i + 2 > s.length || s[i] != '\\' || s[i + 1] != 'u') {
        throw B1Error('B1_ERR_INVALID_UTF8', 'unpaired high surrogate');
      }
      i += 2;
      final low = _hex4();
      if (low < 0xDC00 || low > 0xDFFF) {
        throw B1Error('B1_ERR_INVALID_UTF8', 'high surrogate without a low one');
      }
      return String.fromCharCode(0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00));
    }
    if (cp >= 0xDC00 && cp <= 0xDFFF) {
      throw B1Error('B1_ERR_INVALID_UTF8', 'unpaired low surrogate');
    }
    return String.fromCharCode(cp);
  }

  String _string() {
    i++;
    final buf = StringBuffer();
    while (true) {
      if (i >= s.length) throw B1Error('B1_ERR_PARSE', 'unterminated string');
      final c = s[i];
      if (c == '"') { i++; return buf.toString(); }
      if (c == '\\') {
        i++;
        if (i >= s.length) throw B1Error('B1_ERR_PARSE', 'unterminated escape');
        final e = s[i];
        i++;
        switch (e) {
          case '"': buf.write('"'); break;
          case '\\': buf.write('\\'); break;
          case '/': buf.write('/'); break;
          case 'b': buf.write('\b'); break;
          case 'f': buf.write('\f'); break;
          case 'n': buf.write('\n'); break;
          case 'r': buf.write('\r'); break;
          case 't': buf.write('\t'); break;
          case 'u': buf.write(_unicodeEscape()); break;
          default: throw B1Error('B1_ERR_PARSE', 'bad escape \\$e');
        }
        continue;
      }
      if (c.codeUnitAt(0) < 0x20) throw B1Error('B1_ERR_PARSE', 'raw control character');
      buf.write(c);
      i++;
    }
  }
}

Object? parse(String text) => _Parser(text).parse();

// --- canonical serialization -------------------------------------------------

String _escape(String s) {
  final buf = StringBuffer('"');
  for (final rune in s.runes) {
    switch (rune) {
      case 0x22: buf.write(r'\"'); break;
      case 0x5c: buf.write(r'\\'); break;
      case 0x08: buf.write(r'\b'); break;
      case 0x09: buf.write(r'\t'); break;
      case 0x0a: buf.write(r'\n'); break;
      case 0x0c: buf.write(r'\f'); break;
      case 0x0d: buf.write(r'\r'); break;
      default:
        if (rune < 0x20) {
          buf.write('\\u${rune.toRadixString(16).padLeft(4, '0')}'); // lowercase, per R3
        } else {
          buf.writeCharCode(rune);
        }
    }
  }
  buf.write('"');
  return buf.toString();
}

String canonicalize(Object? v, [int depth = 0]) {
  if (depth > maxDepth) throw B1Error('B1_ERR_DEPTH', 'depth > $maxDepth');
  if (v == null) return 'null';
  if (v is bool) return v ? 'true' : 'false';
  if (v is int) {
    if (v > maxSafe || v < -maxSafe) throw B1Error('B1_ERR_NONINTEGER_NUMBER', 'out of range');
    return v.toString();
  }
  if (v is double) throw B1Error('B1_ERR_NONINTEGER_NUMBER', 'floating point is not representable');
  if (v is String) return _escape(v);
  if (v is List) return '[${v.map((e) => canonicalize(e, depth + 1)).join(',')}]';
  if (v is Map) {
    // R2 restricts names to ASCII, so a plain sort is the canonical order.
    final keys = v.keys.map((k) => k as String).toList()..sort();
    final parts = keys.map((k) {
      if (!keyRe.hasMatch(k)) throw B1Error('B1_ERR_KEY_SYNTAX', k);
      return '${_escape(k)}:${canonicalize(v[k], depth + 1)}';
    });
    return '{${parts.join(',')}}';
  }
  throw B1Error('B1_ERR_PARSE', 'unsupported type ${v.runtimeType}');
}

String digestValue(Object? v) => sha256Hex(utf8.encode(canonicalize(v)));

String digestText(String text) => digestValue(parse(text));

String b1c1(String digestHex) => 'b1c1:$digestHex';
