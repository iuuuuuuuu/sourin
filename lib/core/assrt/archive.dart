// =======================================================================
//  字幕包解压（zip 自己解；rar 明确不支持）
// =======================================================================
//
// # 为什么自己写 zip 解压
//
// pubspec.yaml 里没有 archive / rar / html 任何一个包，而 pubspec 不在本次改动
// 范围内（写作用域见任务卡）。zip 的 deflate 部分 dart:io 的 ZLibDecoder 直接
// 就能解（raw deflate），所以 zip 是可以**真的**做出来的。rar 不行：它是专有
// 算法，Dart 侧没有任何内置能力 —— 所以这里**明确报错**，不假装支持。
//
// # ★★★ 为什么一切按**魔数**判，不看扩展名
//
// 实测（见 .probe/assrt/TASK29-REPORT.md）：
//   GET /download/646901/....zip  -> 2681242 B，头 8 字节 52 61 72 21 1a 07 01 00
//                                    = Rar!\x1a\x07\x01\x00，RAR5，不是 PK
// 站点上「.zip」为名的条目里装的是 RAR。反过来也可能有别的错配。
// ⇒ 判类型只认字节，扩展名仅用于给用户看的提示。
//
// # 支持的形态（每一种都有真实样本）
//
//   zip       PK\x03\x04            本地解压，挑出 .srt/.ass/.ssa/.sub/.vtt
//   rar4      Rar!\x1a\x07\x00      不支持（明确报错 + 给浏览器打开的办法）
//   rar5      Rar!\x1a\x07\x01\x00  不支持（同上）
//   7z        37 7A BC AF 27 1C     不支持（同上）
//   gzip      1F 8B                 不支持（同上）
//   纯文本    [Script Info] / -->   直接就是字幕，不需要解压

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'assrt_api.dart' show AssrtException, isTextSubtitleName;

/// 压缩包/文本的形态
enum SubtitleArchiveKind {
  zip('zip'),
  rar4('rar4'),
  rar5('rar5'),
  sevenZip('7z'),
  gzip('gzip'),
  text('text'),
  unknown('unknown');

  const SubtitleArchiveKind(this.label);
  final String label;
}

/// 嗅探形态（**只看字节**）
SubtitleArchiveKind sniffKind(List<int> bytes) {
  bool at(int i, List<int> sig) {
    if (bytes.length < i + sig.length) return false;
    for (var k = 0; k < sig.length; k++) {
      if (bytes[i + k] != sig[k]) return false;
    }
    return true;
  }

  if (at(0, const [0x50, 0x4B, 0x03, 0x04]) ||
      at(0, const [0x50, 0x4B, 0x05, 0x06]) || // 空 zip（只有 EOCD）
      at(0, const [0x50, 0x4B, 0x07, 0x08])) {
    return SubtitleArchiveKind.zip;
  }
  if (at(0, const [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00])) {
    return SubtitleArchiveKind.rar5;
  }
  if (at(0, const [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00])) {
    return SubtitleArchiveKind.rar4;
  }
  if (at(0, const [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])) {
    return SubtitleArchiveKind.sevenZip;
  }
  if (at(0, const [0x1F, 0x8B])) return SubtitleArchiveKind.gzip;
  if (looksLikeSubtitleText(bytes)) return SubtitleArchiveKind.text;
  return SubtitleArchiveKind.unknown;
}

/// 这段字节看起来是不是**字幕文本本身**（不是压缩包）
///
/// 判据（任一命中）：UTF-8 BOM / UTF-16 BOM；前 4 KB 里出现 -->（SRT 时间轴）；
/// 前 4 KB 里出现 [Script Info] / [V4+ Styles]（ASS/SSA 头）。
bool looksLikeSubtitleText(List<int> bytes) {
  if (bytes.isEmpty) return false;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return true;
  }
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
          (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
    return true;
  }
  final head = bytes.sublist(0, bytes.length < 4096 ? bytes.length : 4096);
  final t = latin1.decode(head, allowInvalid: true);
  return t.contains('-->') ||
      t.contains('[Script Info]') ||
      t.contains('[V4+ Styles]') ||
      t.contains('[V4 Styles]');
}

/// 解出来的一个字幕文件
class ExtractedSubtitle {
  const ExtractedSubtitle({
    required this.name,
    required this.bytes,
    this.compressedSize = 0,
    this.crcOk = true,
  });

  /// 包内路径（可能含目录）
  final String name;
  final List<int> bytes;
  final int compressedSize;

  /// 解出来的 CRC32 与 zip 中央目录里记的是否一致
  ///
  /// 不一致 = 文件本身坏了（或者解压写错了）—— 两种都必须让用户知道，
  /// 不能静默交出一个半截字幕。
  final bool crcOk;

  String get baseName {
    final i = name.lastIndexOf('/');
    return i < 0 ? name : name.substring(i + 1);
  }

  int get length => bytes.length;

  @override
  String toString() =>
      'ExtractedSubtitle($name, ${bytes.length} B, crcOk=$crcOk)';
}

/// 从下载到的字节里取出字幕文件
///
/// - zip：解压并挑出字幕类文件（按扩展名）
/// - 纯文本：原样返回一条
/// - rar / 7z / gzip：抛 [AssrtException]，消息里**明确写不支持**
///   （并让 UI 有机会给出「在浏览器打开」的兜底）
List<ExtractedSubtitle> extractSubtitles(List<int> bytes, {String hintName = ''}) {
  final kind = sniffKind(bytes);
  switch (kind) {
    case SubtitleArchiveKind.zip:
      final all = readZipEntries(bytes);
      final subs = all
          .where((e) => isTextSubtitleName(e.name))
          .where((e) => e.bytes.isNotEmpty)
          .toList();
      if (subs.isEmpty) {
        throw AssrtException(
          '这个 zip 里没有 .srt/.ass/.ssa 字幕文件（共 ${all.length} 个文件：'
          '${all.take(6).map((e) => e.baseName).join('、')}'
          '${all.length > 6 ? '…' : ''}）',
        );
      }
      return subs;
    case SubtitleArchiveKind.text:
      return <ExtractedSubtitle>[
        ExtractedSubtitle(
          name: hintName.isEmpty ? 'subtitle' : hintName,
          bytes: bytes,
        ),
      ];
    case SubtitleArchiveKind.rar4:
    case SubtitleArchiveKind.rar5:
    case SubtitleArchiveKind.sevenZip:
    case SubtitleArchiveKind.gzip:
      throw AssrtException(
        '不支持 ${kind.label} 压缩包（本应用没有内置该解压算法，'
        '也不引入新依赖）。这个版本的字幕打包成了 ${kind.label}，'
        '请改用「在浏览器打开下载链接」拿到文件，或选一个直接给 '
        '.srt/.ass 的版本。',
      );
    case SubtitleArchiveKind.unknown:
      throw AssrtException(
        '认不出下载内容的格式（前 8 字节：${_hex(bytes, 8)}）。可能不是字幕文件。',
      );
  }
}

String _hex(List<int> b, int n) {
  final k = b.length < n ? b.length : n;
  return b.sublist(0, k).map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ');
}

// -----------------------------------------------------------------------
// zip 读取（中央目录驱动 —— 不依赖本地头里的 size 字段）
// -----------------------------------------------------------------------

/// 读一个 zip 里的全部条目
///
/// # 为什么走**中央目录**而不是顺序扫本地头
///
/// 本地文件头的 compressed size / uncompressed size 在**流式写入**的 zip 里是 0
/// （真正的长度在数据之后的 data descriptor 里，靠 flag bit 3 标记）。顺序扫的话
/// 必须实现 data descriptor 探测，容易错。中央目录里的长度是**权威值**，而且它
/// 本来就该在文件末尾 —— 从末尾往前找 EOCD 签名（0x06054B50）即可，简单且稳。
///
/// # 已知边界（诚实标注）
///
/// · 不支持 ZIP64（条目 > 65535 或单文件 > 4 GB）—— 字幕包到不了这个量级，
///   真遇到会抛 AssrtException，而不是给出错数据。
/// · 不支持加密 zip（flag bit 0）—— 抛异常。
/// · 文件名若不是 UTF-8（bit 11 未置位且非 UTF-8 字节），Dart 没有内置 GBK
///   解码器 ⇒ 名字可能带替换字符。扩展名是 ASCII，**挑文件不受影响**。
List<ExtractedSubtitle> readZipEntries(List<int> bytes) {
  final b = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final eocd = _findEocd(b);
  if (eocd < 0) {
    throw AssrtException('不是有效的 zip（没找到中央目录结尾记录 EOCD）');
  }
  final entryCount = _u16(b, eocd + 10);
  final cdSize = _u32(b, eocd + 12);
  final cdOff = _u32(b, eocd + 16);
  if (entryCount == 0xFFFF || cdOff == 0xFFFFFFFF || cdSize == 0xFFFFFFFF) {
    throw AssrtException('这是 ZIP64 包，本实现不支持（条目数或体积超出普通 zip 上限）');
  }
  if (cdOff + cdSize > b.length) {
    throw AssrtException(
        'zip 中央目录越界（声明 $cdOff+$cdSize，文件只有 ${b.length} 字节）');
  }

  final out = <ExtractedSubtitle>[];
  var p = cdOff;
  for (var i = 0; i < entryCount; i++) {
    if (p + 46 > b.length || _u32(b, p) != 0x02014B50) break;
    final flags = _u16(b, p + 8);
    final method = _u16(b, p + 10);
    final crc = _u32(b, p + 16);
    final compSize = _u32(b, p + 20);
    final uncompSize = _u32(b, p + 24);
    final nameLen = _u16(b, p + 28);
    final extraLen = _u16(b, p + 30);
    final commentLen = _u16(b, p + 32);
    final localOff = _u32(b, p + 42);
    final nameBytes = b.sublist(p + 46, p + 46 + nameLen);
    final name = _decodeZipName(nameBytes, flags);

    if (flags & 0x1 != 0) {
      throw AssrtException('zip 里的「$name」是加密条目，本实现不支持解密');
    }

    // 本地头：拿到 name/extra 长度才能定位数据起点
    if (localOff + 30 > b.length || _u32(b, localOff) != 0x04034B50) {
      throw AssrtException('zip 条目「$name」的本地头损坏');
    }
    final lNameLen = _u16(b, localOff + 26);
    final lExtraLen = _u16(b, localOff + 28);
    final dataOff = localOff + 30 + lNameLen + lExtraLen;
    if (dataOff + compSize > b.length) {
      throw AssrtException('zip 条目「$name」的数据越界');
    }
    final raw = b.sublist(dataOff, dataOff + compSize);

    List<int> data;
    switch (method) {
      case 0:
        data = raw;
        break;
      case 8:
        data = ZLibDecoder(raw: true).convert(raw);
        break;
      default:
        throw AssrtException(
            'zip 条目「$name」用了不支持的压缩方式 $method（只支持 0=存储 / 8=deflate）');
    }
    if (data.length != uncompSize) {
      throw AssrtException(
          'zip 条目「$name」解压后长度不符（声明 $uncompSize，实际 ${data.length}）');
    }
    out.add(ExtractedSubtitle(
      name: name,
      bytes: data,
      compressedSize: compSize,
      crcOk: crc32(data) == crc,
    ));

    p += 46 + nameLen + extraLen + commentLen;
  }
  return out;
}

/// zip 文件名解码：bit 11（0x800）置位 = UTF-8；否则先按 UTF-8 严格解，失败退 latin1
String _decodeZipName(List<int> raw, int flags) {
  if (flags & 0x800 != 0) {
    return utf8.decode(raw, allowMalformed: true);
  }
  try {
    return utf8.decode(raw);
  } catch (_) {
    // 很可能是 GBK —— Dart 没有内置解码器，latin1 至少不会抛，
    // 且 ASCII 部分（含扩展名）保持正确
    return latin1.decode(raw, allowInvalid: true);
  }
}

int _findEocd(Uint8List b) {
  final minPos = b.length > 66000 ? b.length - 66000 : 0;
  for (var i = b.length - 22; i >= minPos; i--) {
    if (b[i] == 0x50 && b[i + 1] == 0x4B && b[i + 2] == 0x05 && b[i + 3] == 0x06) {
      return i;
    }
  }
  return -1;
}

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);

int _u32(Uint8List b, int o) =>
    (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) & 0xFFFFFFFF;

// -----------------------------------------------------------------------
// CRC32（只为校验 zip 条目完整性 —— 不是安全用途）
// -----------------------------------------------------------------------

List<int>? _crcTable;

int crc32(List<int> data) {
  final t = _crcTable ??= _buildCrcTable();
  var c = 0xFFFFFFFF;
  for (final byte in data) {
    c = t[(c ^ byte) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

List<int> _buildCrcTable() {
  final t = List<int>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[i] = c;
  }
  return t;
}

// -----------------------------------------------------------------------
// 字幕文本解码
// -----------------------------------------------------------------------

/// 解出来的字幕文本 + 编码说明
class SubtitleText {
  const SubtitleText(
      {required this.text, required this.encoding, this.lossy = false});

  final String text;

  /// 'utf-8' / 'utf-8-bom' / 'utf-16le' / 'utf-16be' / 'latin1'
  final String encoding;

  /// true = 有字节无法确定地解码（很可能是 GBK/Big5，本实现没有解码器）
  final bool lossy;

  @override
  String toString() =>
      'SubtitleText(${text.length} chars, $encoding, lossy=$lossy)';
}

/// 把字幕字节解成文本
///
/// # 为什么不用 utf8.decode(bytes, allowMalformed: true) 一路到底
///
/// 那样会把**每一个**非法字节换成 U+FFFD 而不出声 —— 用户看到的是满屏乱码，
/// 却以为「字幕坏了」。这里改成：严格 UTF-8 先试，失败就**明确标注**
/// lossy=true 并给出「很可能是 GBK」的判断，让 UI 能如实提示。
SubtitleText decodeSubtitleBytes(List<int> bytes) {
  if (bytes.isEmpty) {
    return const SubtitleText(text: '', encoding: 'utf-8');
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return SubtitleText(
      text: utf8.decode(bytes.sublist(3), allowMalformed: true),
      encoding: 'utf-8-bom',
    );
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return SubtitleText(
      text: _utf16(bytes.sublist(2), little: true),
      encoding: 'utf-16le',
    );
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return SubtitleText(
      text: _utf16(bytes.sublist(2), little: false),
      encoding: 'utf-16be',
    );
  }
  try {
    return SubtitleText(text: utf8.decode(bytes), encoding: 'utf-8');
  } catch (_) {
    return SubtitleText(
      text: latin1.decode(bytes, allowInvalid: true),
      encoding: 'latin1',
      lossy: true,
    );
  }
}

String _utf16(List<int> b, {required bool little}) {
  final codes = <int>[];
  for (var i = 0; i + 1 < b.length; i += 2) {
    codes.add(little ? (b[i] | (b[i + 1] << 8)) : ((b[i] << 8) | b[i + 1]));
  }
  return String.fromCharCodes(codes);
}

// -----------------------------------------------------------------------
// 字幕文件名的「像不像同一集」—— 给挂载排序用
// -----------------------------------------------------------------------

/// 从文件名里抽出集号（S01E03 / E03 / 第03集 / EP03 / [03]）；抽不到返回 null
///
/// 用途：一个包里 384 个字幕文件时，用户要能一眼看到「这条是这个版本的哪一集」。
/// 抽不到就是 null（**不猜**）。
int? episodeNumberOf(String name) {
  final s = name.replaceAll('\\', '/').split('/').last;
  final pats = <RegExp>[
    RegExp(r'[Ss](\d{1,2})[Ee](\d{1,3})'),
    RegExp(r'[Ee][Pp]?(\d{1,3})\b'),
    RegExp(r'第\s*(\d{1,3})\s*[集话話]'),
    RegExp(r'\[(\d{1,3})\]'),
  ];
  for (final p in pats) {
    final m = p.firstMatch(s);
    if (m == null) continue;
    final g = m.groupCount >= 2 && m.group(2) != null ? m.group(2)! : m.group(1)!;
    final v = int.tryParse(g);
    if (v != null) return v;
  }
  return null;
}
