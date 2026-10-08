// =======================================================================
//  射手字幕（assrt.net）—— 客户端（搜索 / 详情 / 下载）
// =======================================================================
//
// # 这个文件解决什么
//
// 用户 2026-10-05 要求（逐字）：
// > 支持一下 射手字幕 https://assrt.net 功能
//
// 这里实现三件事：
//   1. 搜索   GET /sub/?searchword=<关键词>        —— HTML，要自己解析
//   2. 详情   GET /xml/sub/<id3>/<id>.xml         —— 名字叫 xml，**其实是 HTML**
//   3. 下载   GET /download/<id>/<文件名>          —— 真实字节（302 到 CDN）
//
// 界面在 lib/ui/subtitle/，落盘在 lib/core/assrt/subtitle_store.dart。
//
// # ★★★ 为什么走 Web 页而不是官方 API
//
// 官方 API https://api.assrt.net/v1/sub/search?q=... **强制要 token**：
//   HTTP/1.1 400 Bad Request
//   {"status":20001,"errmsg":"invalid token"}
// 带 Authorization: Bearer 或 ?token= 都是这个结果 —— token 要用户自己去
// assrt.net 申请，不能作为默认路径（否则功能对所有人都是坏的）。
// Web 页免 token，实测可用，所以主路径是 Web 页。
//
// # ★★★ 四条**实测**出来的事实（不是从文档抄的，见 .probe/assrt/TASK29-REPORT.md）
//
// ## 事实 1：文件名段被**完全忽略**，服务端按 id 返回真身
//   GET /download/663565/xyz.zzz    -> 200 / 7457646 B
//   GET /download/663565/<真名>.rar -> 200 / 7457646 B（逐字节相同）
//   响应头 Content-Disposition: subtitle; filename="xyz.zzz"（照抄请求名）
//   ⇒ **不要从 URL 猜扩展名**，必须读响应魔数（见 archive.dart）。
//
// ## 事实 2：Referer **不是**防盗链闸门
//   同一 URL 带 / 不带 / 带 bogus Referer（https://example.com/）、
//   不带 User-Agent、连打 8 次 —— 全部 200 且字节完全一致。
//   ⇒ 本文件**仍然**带 Referer + UA（零成本、贴近浏览器、对方随时可能改），
//     但报告里**不写**「缺 Referer 会失败」这种没有证据的话。
//
// ## 事实 3：错误页是 **text/xml**，正常下载是 application/octet-stream
//   /download/99999999/x.rar -> 493 / 831 B / text/xml
//     正文：<msgtitle>啊呀</msgtitle> ... 下载链接好像有点问题？请返回重试
//   file0 CDN 上没签名的 URL -> 302 -> /download/failed/<base64> -> 492 / 869 B
//   ⇒ 判定失败要看**两件事**：HTTP 非 200，**以及** 200 但正文是错误页。
//
// ## 事实 4：打包格式与扩展名**对不上**
//   实测 /download/646901/....zip 下回来的是 RAR5 魔数 52 61 72 21 1a 07 01 00。
//   ⇒ 一律读魔数，扩展名只当提示。
//
// # 禁止 package:flutter/material.dart
//   项目用拆包后的 material_ui（见 test/material_split_test.dart）。
//   本文件是 core 层，连 material_ui 都不该 import —— 只用 dart:io / dart:convert。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 站点根（测试要能改成本地 HttpServer，所以做成参数而不是到处写死）
const String kAssrtBase = 'https://assrt.net';

/// 用户代理 —— 不带 UA 时站点行为未测过，带上更贴近浏览器
const String kAssrtUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) sourin-flutter-spike/assrt';

// -----------------------------------------------------------------------
// 模型
// -----------------------------------------------------------------------

/// 搜索结果里的一条字幕
class AssrtSubtitle {
  const AssrtSubtitle({
    required this.id,
    required this.title,
    required this.detailPath,
    required this.downloadPath,
    required this.downloadName,
    this.format = '',
    this.languages = const <String>[],
    this.source = '',
    this.date = '',
    this.views = 0,
    this.downloads = 0,
    this.rating,
  });

  /// 站点数字 id（663565）
  final String id;

  /// 版本全名（锚点的 title 属性，最完整）
  final String title;

  /// 详情页相对路径（/xml/sub/663/663565.xml）
  final String detailPath;

  /// 下载相对路径（/download/663565/xxx.rar）
  final String downloadPath;

  /// 下载文件名（从 downloadPath 末段解出来，**未** URL 解码）
  final String downloadName;

  /// 字幕格式文案（Subrip(srt) / SSA / VobSub …），可能为空
  final String format;

  /// 语种列表（英 / 简 / 繁 …），**整段可能缺失** ⇒ 空列表是正常值
  final List<String> languages;

  final String source;
  final String date;
  final int views;
  final int downloads;

  /// 用户评分（0..10），无评分时 null（页面写的是「暂无评分」）
  final double? rating;

  /// 下载路径末段的扩展名（小写，不含点）；没有则空串
  ///
  /// ⚠️ 只作**提示**用 —— 实测 .zip 里装的是 RAR。判类型必须读魔数。
  String get extensionHint {
    final i = downloadName.lastIndexOf('.');
    if (i < 0 || i == downloadName.length - 1) return '';
    return downloadName.substring(i + 1).toLowerCase();
  }

  String detailUrl([String base = kAssrtBase]) => '$base$detailPath';

  String downloadUrl([String base = kAssrtBase]) => '$base$downloadPath';

  @override
  String toString() => 'AssrtSubtitle($id, $title)';
}

/// 详情页里的一个文件
class AssrtFile {
  const AssrtFile({
    required this.index,
    required this.name,
    this.sizeText = '',
    this.subtype = '',
  });

  /// 页面里的序号（onthefly 的第二个参数，从 1 开始）
  final String index;
  final String name;
  final String sizeText;

  /// 页面给的类型标签（subtype-srt / subtype-ass …）
  final String subtype;

  @override
  String toString() => 'AssrtFile($index, $name, $sizeText)';
}

/// 详情页
class AssrtSubtitleDetail {
  const AssrtSubtitleDetail({
    required this.id,
    required this.title,
    required this.downloadPath,
    this.format = '',
    this.languages = const <String>[],
    this.viewsText = '',
    this.downloadsText = '',
    this.publishedAt = '',
    this.source = '',
    this.matchedVideo = '',
    this.note = '',
    this.packSizeText = '',
    this.packFileName = '',
    this.files = const <AssrtFile>[],
  });

  final String id;
  final String title;
  final String downloadPath;
  final String format;
  final List<String> languages;
  final String viewsText;
  final String downloadsText;
  final String publishedAt;
  final String source;
  final String matchedVideo;
  final String note;

  /// 「下载字幕 | 7.1MB」里的 7.1MB
  final String packSizeText;

  /// 「文件名：xxx.rar」那一行
  final String packFileName;

  /// 包内文件清单（可能为空 —— 直链单文件条目就没有清单）
  final List<AssrtFile> files;

  /// 包内是否含 srt / ass / ssa（用文件名判断，**不**用来决定是否解压）
  bool get hasTextSubtitleFile => files.any((f) => isTextSubtitleName(f.name));

  @override
  String toString() => 'AssrtSubtitleDetail($id, $title, ${files.length} files)';
}

/// 一次下载的结果
class AssrtDownload {
  const AssrtDownload({
    required this.bytes,
    required this.fileName,
    required this.finalUrl,
    required this.contentType,
  });

  final List<int> bytes;
  final String fileName;
  final String finalUrl;
  final String contentType;

  int get length => bytes.length;

  @override
  String toString() => 'AssrtDownload($fileName, ${bytes.length} B, $contentType)';
}

/// 失败原因
class AssrtException implements Exception {
  AssrtException(this.message, {this.statusCode, this.url = '', this.body = ''});

  final String message;
  final int? statusCode;
  final String url;

  /// 服务端返回的正文（最多留 400 字符 —— 错误页只有几百字节）
  final String body;

  @override
  String toString() => 'AssrtException($message)';
}

// -----------------------------------------------------------------------
// HTML 小工具（不引 html 包 —— pubspec 不在本次写范围内）
// -----------------------------------------------------------------------

/// 把 HTTP 头里按 latin1 读出来的字节还原成 UTF-8 文本
///
/// 实测（本仓真踩到，见 .probe/assrt/TASK29-REPORT.md 事实 5）：
/// CDN 回的响应头是
///   Content-Disposition: subtitle; filename="[进击的巨人…].srt"
/// 其中中文是**裸 UTF-8 字节**（`e8 bf 9b e5 87 bb …`），
/// 而 Dart 的 `HttpHeaders` 按 **latin1** 解码头值 ——
/// 于是文件名变成 `[è¿å»çå·¨äºº…].srt`（mojibake），
/// 并且这个乱码会一路带到落盘文件名。
///
/// 这里按 latin1 取回原始字节，再按 UTF-8 解码；解不出（有非 UTF-8 序列）
/// 就原样返回 —— 真正的 latin1 文件名不会被这次修复弄坏。
String utf8HeaderText(String s) {
  if (s.isEmpty) return s;
  var ascii = true;
  for (final c in s.codeUnits) {
    if (c > 0x7F) {
      ascii = false;
      break;
    }
  }
  if (ascii) return s;
  try {
    final bytes = <int>[];
    for (final c in s.codeUnits) {
      if (c > 0xFF) return s; // 不是 latin1 视图，别乱动
      bytes.add(c);
    }
    return utf8.decode(bytes);
  } catch (_) {
    return s;
  }
}

/// 把 HTML 实体还原成字符
///
/// 实测页面里出现过的：&nbsp; &amp; &#x2913; 以及标题里的中日文（本身不是实体）
String htmlUnescape(String s) {
  var out = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'");
  // &#xHHHH; 与 &#DDDD;
  out = out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
    final v = int.tryParse(m.group(1)!, radix: 16);
    return v == null ? m.group(0)! : String.fromCharCode(v);
  });
  out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final v = int.tryParse(m.group(1)!);
    return v == null ? m.group(0)! : String.fromCharCode(v);
  });
  return out;
}

/// 去掉所有标签（标题里会混 <span style="color:red">影</span> 这种高亮）
String stripTags(String s) => s.replaceAll(RegExp(r'<[^>]*>'), '');

/// 取标签属性（只在一个 start tag 的内部切片上调用）
String? _attrOf(String tag, String name) {
  final m = RegExp(name + r'''\s*=\s*"([^"]*)"''').firstMatch(tag);
  if (m != null) return m.group(1);
  final m2 = RegExp(name + r"""\s*=\s*'([^']*)'""").firstMatch(tag);
  return m2?.group(1);
}

int _intOf(String? s) {
  if (s == null) return 0;
  final m = RegExp(r'\d+').firstMatch(s.replaceAll(',', ''));
  return m == null ? 0 : (int.tryParse(m.group(0)!) ?? 0);
}

/// 把「英&nbsp;简&nbsp;繁」拆成 ['英','简','繁']
List<String> splitLanguages(String raw) {
  final t = htmlUnescape(raw).replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return const <String>[];
  return t
      .split(RegExp(r'[\s,，/|]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList(growable: false);
}

/// 是不是「文本类字幕」文件名（srt / ass / ssa / sub / vtt / smi）
///
/// 注意：这是**按名字**判的，只用于「包内有没有字幕」这类展示，
/// **不**用于决定解压方式 —— 解压看魔数。
bool isTextSubtitleName(String name) {
  final n = name.toLowerCase();
  for (final e in const <String>['.srt', '.ass', '.ssa', '.sub', '.vtt', '.smi']) {
    if (n.endsWith(e)) return true;
  }
  return false;
}

// -----------------------------------------------------------------------
// 搜索结果页解析
// -----------------------------------------------------------------------

/// 解析搜索结果页
///
/// # 为什么按 class="introtitle" 切，而不是按 class="subitem" 切
///
/// 页面里**第一处** class="subitem" 是顶部广告位：
///   <div id="top-banner" class="subitem" style="display:none;"> ... </div>
/// 按 subitem 切会把广告当成一条结果（而且它没有标题、没有下载链接，
/// 会变成一条空记录）。class="introtitle" **只在**结果条目里出现
/// （实测 火影 页：introtitle 15 个 == 结果条数），所以按它切天然排除广告。
///
/// 每条结果的结构（逐字，来自真实页面）：
///   <a class="introtitle" onfocus="this.blur();" target="_blank"
///      title="<版本全名>" href="/xml/sub/663/663565.xml"> <标题> </a>
///   ...
///   <a ... id="downsubbtn" ... onclick=" javascript:location.href='/download/663565/x.rar';return false;"
List<AssrtSubtitle> parseSearchHtml(String html, {String base = kAssrtBase}) {
  final out = <AssrtSubtitle>[];
  final chunks = html.split('class="introtitle"');
  for (var i = 1; i < chunks.length; i++) {
    final c = chunks[i];
    // 锚点的 start tag 到此为止（属性里没有裸的 >）
    final tagEnd = c.indexOf('>');
    if (tagEnd < 0) continue;
    final tag = c.substring(0, tagEnd);

    final title = htmlUnescape(_attrOf(tag, 'title') ?? '').trim();
    final href = _attrOf(tag, 'href') ?? '';
    final id = idFromDetailPath(href);
    if (id.isEmpty) continue;

    // 条目正文：从 </a> 之后开始
    final bodyStart = c.indexOf('</a>', tagEnd);
    final body = bodyStart < 0 ? c : c.substring(bodyStart + 4);

    final dl = downloadPathOf(body);
    out.add(AssrtSubtitle(
      id: id,
      title: title.isEmpty
          ? htmlUnescape(stripTags(_innerText(c, tagEnd))).trim()
          : title,
      detailPath: href,
      downloadPath: dl,
      downloadName: dl.isEmpty ? '' : fileNameOfDownloadPath(dl),
      format: _metaText(body, '格式：'),
      languages: splitLanguages(_metaRaw(body, '语言：')),
      source: _metaText(body, '来源：'),
      date: _metaText(body, '日期：'),
      views: _intOf(_metaRaw(body, '查阅次数：')),
      downloads: _intOf(_metaRaw(body, '下载次数：')),
      rating: _ratingOf(body),
    ));
  }
  return out;
}

/// 锚点内的文本（去掉标签）
String _innerText(String chunk, int tagEnd) {
  final close = chunk.indexOf('</a>', tagEnd);
  if (close < 0) return '';
  return chunk.substring(tagEnd + 1, close);
}

/// 抓「标签：值」里的值，值到下一个标签或换行为止
String _metaRaw(String body, String label) {
  final m = RegExp(RegExp.escape(label) + r'\s*([^<\n]*)').firstMatch(body);
  return m == null ? '' : m.group(1)!;
}

String _metaText(String body, String label) =>
    htmlUnescape(_metaRaw(body, label)).trim();

double? _ratingOf(String body) {
  final m = RegExp(r'用户评分([0-9]+(?:\.[0-9]+)?)分').firstMatch(body);
  if (m == null) return null;
  return double.tryParse(m.group(1)!);
}

/// 从结果条目正文里取下载相对路径
///
/// 下载入口是个 JS 链接，href 是 #，真地址在 onclick 里：
///   onclick=" javascript:location.href='/download/663565/x.rar';return false;"
String downloadPathOf(String body) {
  // ⚠️ 正则末尾**不要**再写一个引号：真实页面里 onclick 的值是
  //     onclick=" javascript:location.href='/download/663565/xxx.rar';return false;"
  // 即 href 前有换行+若干空格，引号紧跟在路径后面。
  // 曾经写成 ...([^']+)' （末尾多一个引号+空格）⇒ 15/15 条全部匹配失败、
  // downloadPath 全为空串（见 test/t71_assrt_test.dart 的「下载路径必须解析出来」）。
  // [^']+ 本身就在引号前停下，末尾不需要那个引号。
  final m = RegExp(r'''id="downsubbtn"[\s\S]{0,400}?location\.href='([^']+)''')
      .firstMatch(body);
  if (m != null) return m.group(1)!.trim();
  // 兜底：条目里任意一处 location.href='/download/...'
  final m2 = RegExp(r'''location\.href='(/download/[^']+)''').firstMatch(body);
  return m2 == null ? '' : m2.group(1)!.trim();
}

/// /download/663565/xxx.rar -> 663565
String idFromDownloadPath(String p) {
  final m = RegExp(r'/download/(\d+)').firstMatch(p);
  return m == null ? '' : m.group(1)!;
}

/// /xml/sub/663/663565.xml -> 663565
String idFromDetailPath(String p) {
  final m = RegExp(r'/xml/sub/\d+/(\d+)\.xml').firstMatch(p);
  if (m != null) return m.group(1)!;
  final m2 = RegExp(r'/xml/sub/\d+/(\d+)').firstMatch(p);
  return m2 == null ? '' : m2.group(1)!;
}

/// /download/663565/Virgin.River...rar -> Virgin.River...rar（**不**解码）
String fileNameOfDownloadPath(String p) {
  final i = p.lastIndexOf('/');
  return i < 0 ? p : p.substring(i + 1);
}

// -----------------------------------------------------------------------
// 详情页解析
// -----------------------------------------------------------------------

/// 解析详情页
///
/// 详情页的字段 class 名与搜索页**不同**：
///   搜索页  版本：<b>…</b>   格式： …   语言： …
///   详情页  <span class="subdes_th">字幕格式：</span><span class="subdes_td"> Subrip(srt)</span>
/// 所以这里不能复用 _metaRaw（那个是给搜索页的裸文本用的）。
AssrtSubtitleDetail parseDetailHtml(String html, {String base = kAssrtBase}) {
  return AssrtSubtitleDetail(
    id: detailId(html),
    title: detailTitle(html),
    downloadPath: detailDownloadPath(html),
    format: _subdesTd(html, '字幕格式：'),
    languages: splitLanguages(_subdesTd(html, '字幕语种：')),
    viewsText: _subdesTd(html, '查阅次数：'),
    downloadsText: _subdesTd(html, '下载次数：'),
    publishedAt: _col3(html, '发布时间：'),
    source: _subdesTd(html, '字幕来源：'),
    matchedVideo: _col3(html, '匹配视频：'),
    note: _noteOf(html),
    packSizeText: _packSize(html),
    packFileName: _packFileName(html),
    files: parseDetailFiles(html),
  );
}

/// 详情页 id：优先从下载锚的 href 取，退而从任意 /download/<id>/ 取
String detailId(String html) {
  final m = RegExp(r'''id="btn_download"[^>]*href="([^"]+)"''').firstMatch(html);
  if (m != null) {
    final id = idFromDownloadPath(m.group(1)!);
    if (id.isNotEmpty) return id;
  }
  final m2 = RegExp(r'/download/(\d+)/').firstMatch(html);
  return m2 == null ? '' : m2.group(1)!;
}

/// 详情页标题：<span class="name_org" id="movietitle1">…</span>
String detailTitle(String html) {
  final m =
      RegExp(r'''id="movietitle1"[^>]*>([\s\S]*?)</span>''').firstMatch(html);
  return m == null ? '' : htmlUnescape(stripTags(m.group(1)!)).trim();
}

/// <span class="subdes_th">字幕格式：</span><span class="subdes_td"> Subrip(srt)</span>
String _subdesTd(String html, String label) {
  final m = RegExp(
    RegExp.escape(label) +
        r'''</span>\s*<span[^>]*class="subdes_td"[^>]*>([\s\S]*?)</span>''',
  ).firstMatch(html);
  return m == null ? '' : htmlUnescape(stripTags(m.group(1)!)).trim();
}

/// 发布时间 / 匹配视频 用的是 <span colspan="3" class="col-3">（不是 subdes_td）
String _col3(String html, String label) {
  final m = RegExp(
    RegExp.escape(label) +
        r'''</span>\s*<span[^>]*class="col-3"[^>]*>([\s\S]*?)</span>''',
  ).firstMatch(html);
  return m == null ? '' : htmlUnescape(stripTags(m.group(1)!)).trim();
}

/// 备注：<span class="col-3"><intro>…</intro></span>
String _noteOf(String html) {
  final m = RegExp(r'<intro>([\s\S]*?)</intro>').firstMatch(html);
  return m == null ? '' : htmlUnescape(stripTags(m.group(1)!)).trim();
}

/// <em id="downsubbtnfsize">7.1MB </em>
String _packSize(String html) {
  final m =
      RegExp(r'''id="downsubbtnfsize"[^>]*>([\s\S]*?)</em>''').firstMatch(html);
  return m == null ? '' : htmlUnescape(stripTags(m.group(1)!)).trim();
}

/// 「文件名：Virgin.River.S04.720p.WEB.H264-KOGi_Subs.rar」那一行
String _packFileName(String html) {
  final m = RegExp(r'文件名：\s*([^<\n]*)').firstMatch(html);
  return m == null ? '' : htmlUnescape(m.group(1)!).trim();
}

/// 详情页的下载相对路径
///
/// ⚠️ 该锚点**有两个 id 属性**：id="btn_download" id="downsubbtn"
/// （浏览器取第一个，所以下面按 btn_download 找；找不到再退 downsubbtn）
String detailDownloadPath(String html) {
  final m = RegExp(r'''id="btn_download"[^>]*href="([^"]+)"''').firstMatch(html);
  if (m != null) return htmlUnescape(m.group(1)!).trim();
  final m2 = RegExp(r'''id="downsubbtn"[^>]*href="([^"]+)"''').firstMatch(html);
  if (m2 != null) return htmlUnescape(m2.group(1)!).trim();
  final m3 = RegExp(r'''location\.href='(/download/[^']+)' ''').firstMatch(html);
  return m3 == null ? '' : m3.group(1)!.trim();
}

/// 包内文件清单
///
/// 每项形如（**单引号属性**）：
///   <div ... onclick='onthefly("663565","1","Virgin..._[spa].srt")'>
///     <span id='filelist-name'>Virgin..._[spa].srt</span>
///     <span id='filelist-size'>44.8KB</span></div>
List<AssrtFile> parseDetailFiles(String html) {
  final out = <AssrtFile>[];
  final re = RegExp(r'''onthefly\("([^"]*)","([^"]*)","([^"]*)"\)''');
  for (final m in re.allMatches(html)) {
    final idx = m.group(2)!;
    final name = m.group(3)!;
    // 名字后面紧跟着 size
    final after = html.substring(m.end, (m.end + 400).clamp(0, html.length));
    final sm = RegExp(r'''id='filelist-size'[^>]*>([^<]*)''').firstMatch(after);
    out.add(AssrtFile(
      index: idx,
      name: htmlUnescape(name).trim(),
      sizeText: sm == null ? '' : htmlUnescape(sm.group(1)!).trim(),
      subtype: _subtypeBefore(html, m.start),
    ));
  }
  return out;
}

/// 找 onclick 之前最近的一个 id='subtype-xxx'
String _subtypeBefore(String html, int at) {
  final head = html.substring((at - 200).clamp(0, at), at);
  final m = RegExp(r"id='(subtype-[a-z0-9]+)'").allMatches(head).toList();
  return m.isEmpty ? '' : m.last.group(1)!;
}

// -----------------------------------------------------------------------
// 传输层（可注入 —— 单测要能确定性地造 493 / 492 / 200-xml）
// -----------------------------------------------------------------------

/// 一次 HTTP 响应（**字节**，不是字符串 —— 下载可能是 rar）
class AssrtHttpResponse {
  const AssrtHttpResponse({
    required this.statusCode,
    required this.bytes,
    required this.headers,
    this.finalUrl = '',
  });

  final int statusCode;
  final List<int> bytes;

  /// 响应头，**键统一小写**
  final Map<String, String> headers;

  /// 跟随重定向之后的最终 URL（拿不到就是空串）
  final String finalUrl;

  String get contentType => headers['content-type'] ?? '';

  bool get isOk => statusCode >= 200 && statusCode < 300;

  /// 正文当文本看（UTF-8，坏字节不炸）
  String get text => utf8.decode(bytes, allowMalformed: true);

  @override
  String toString() => 'AssrtHttpResponse($statusCode, ${bytes.length} B)';
}

/// HTTP 传输接口
///
/// 存在的理由与 danmaku.dart 里的 DanmakuTransport 一样：
/// 单测要能**确定性地**造出 493 / 492 / 200-但是错误页，而不是跑到网上碰运气。
abstract class AssrtTransport {
  /// 发一次 GET。**不允许**在非 2xx 时抛异常 —— 状态码与正文要带回来，
  /// 由上层解释（本站的错误页是 200 还是 493 得看情况，得看得见）。
  Future<AssrtHttpResponse> get(Uri uri, {Map<String, String> headers});

  void close();
}

/// 生产实现：dart:io 的 HttpClient
class IoAssrtTransport implements AssrtTransport {
  IoAssrtTransport({HttpClient? client, this.timeout = const Duration(seconds: 25)})
      : _client = client ??
            (HttpClient()
              ..connectionTimeout = const Duration(seconds: 10)
              ..userAgent = kAssrtUserAgent
              // 下载是 302 到 file0.assrt.net，不跟随就永远拿不到字节
              ..maxConnectionsPerHost = 6);

  final HttpClient _client;
  final Duration timeout;

  @override
  Future<AssrtHttpResponse> get(Uri uri,
      {Map<String, String> headers = const {}}) async {
    final req = await _client.getUrl(uri).timeout(timeout);
    headers.forEach(req.headers.set);
    final resp = await req.close().timeout(timeout);
    final bytes = <int>[];
    await for (final chunk in resp.timeout(timeout)) {
      bytes.addAll(chunk);
    }
    final h = <String, String>{};
    resp.headers.forEach((name, values) {
      if (values.isNotEmpty) h[name.toLowerCase()] = values.join(', ');
    });
    // 下载是 302 -> file0.assrt.net，HttpClient 自动跟随；
    // redirects 里的最后一跳才是真正取到字节的地址（报告里要写清这一点）。
    final finalUrl = resp.redirects.isEmpty
        ? uri.toString()
        : resp.redirects.last.location.toString();
    return AssrtHttpResponse(
      statusCode: resp.statusCode,
      bytes: bytes,
      headers: h,
      finalUrl: finalUrl,
    );
  }

  @override
  void close() => _client.close(force: true);
}

// -----------------------------------------------------------------------
// 客户端
// -----------------------------------------------------------------------

/// 射手字幕客户端
class AssrtClient {
  AssrtClient({
    AssrtTransport? transport,
    this.base = kAssrtBase,
    this.timeout = const Duration(seconds: 25),
  }) : _transport = transport ?? IoAssrtTransport(timeout: timeout);

  final AssrtTransport _transport;
  final String base;
  final Duration timeout;

  /// 搜索
  ///
  /// [page] 从 1 开始；[sort] 空串=默认，另有 rank（评分）/ relevance（相关度）。
  Future<List<AssrtSubtitle>> search(
    String keyword, {
    int page = 1,
    String sort = '',
  }) async {
    final kw = keyword.trim();
    if (kw.isEmpty) {
      throw AssrtException('搜索关键词为空');
    }
    final uri = Uri.parse('$base/sub/').replace(queryParameters: <String, String>{
      'searchword': kw,
      if (page > 1) 'page': '$page',
      if (sort.isNotEmpty) 'sort': sort,
    });
    final resp = await _transport.get(uri, headers: <String, String>{
      'Accept': 'text/html,application/xhtml+xml',
      // 实测 Referer 不是闸门，但带上零成本
      'Referer': '$base/sub/?searchword=${Uri.encodeQueryComponent(kw)}',
    });
    _ensureHtmlOk(resp, uri, what: '搜索');
    return parseSearchHtml(resp.text, base: base);
  }

  /// 详情
  ///
  /// [idOrPath] 可以是纯数字 id，也可以是 /xml/sub/663/663565.xml
  Future<AssrtSubtitleDetail> detail(String idOrPath) async {
    final p = detailPathOf(idOrPath);
    if (p.isEmpty) {
      throw AssrtException('详情地址无法识别：$idOrPath');
    }
    final uri = Uri.parse('$base$p');
    final resp = await _transport.get(uri, headers: <String, String>{
      'Accept': 'text/html,application/xhtml+xml',
      'Referer': '$base/',
    });
    _ensureHtmlOk(resp, uri, what: '详情');
    return parseDetailHtml(resp.text, base: base);
  }

  /// 把 id / 相对路径 / 绝对 URL 都归一到详情相对路径
  static String detailPathOf(String idOrPath) {
    final s = idOrPath.trim();
    if (s.isEmpty) return '';
    if (s.startsWith('/xml/sub/')) return s;
    if (s.startsWith('http://') || s.startsWith('https://')) {
      final u = Uri.tryParse(s);
      if (u == null) return '';
      return u.path;
    }
    if (RegExp(r'^\d+$').hasMatch(s)) {
      final id3 = s.length <= 3 ? s : s.substring(0, 3);
      return '/xml/sub/$id3/$s.xml';
    }
    return '';
  }

  /// HTTP 头值只能是 ASCII（RFC 7230）。
  ///
  /// 实测（本仓真踩到）：把中文关键词直接塞进 Referer，
  /// `req.headers.set` 会抛
  /// FormatException: Invalid HTTP header field value: "…searchword=火影"。
  /// 浏览器发的 Referer 本身也是百分号编码的（火影 -> %E7%81%AB%E5%BD%B1），
  /// 所以这里按 UTF-8 逐字节做百分号编码，只保留可见 ASCII。
  static String asciiHeaderValue(String s) {
    final sb = StringBuffer();
    for (final b in utf8.encode(s)) {
      if (b >= 0x21 && b <= 0x7E) {
        sb.writeCharCode(b);
      } else {
        sb.write('%');
        sb.write(b.toRadixString(16).toUpperCase().padLeft(2, '0'));
      }
    }
    return sb.toString();
  }
  /// 下载
  ///
  /// [referer] 缺省用站点根；实测不是闸门，但保持浏览器行为。
  Future<AssrtDownload> download({
    required String downloadPath,
    String referer = '',
  }) async {
    if (downloadPath.isEmpty) {
      throw AssrtException('下载地址为空');
    }
    final uri = Uri.parse(
        downloadPath.startsWith('http') ? downloadPath : '$base$downloadPath');
    final resp = await _transport.get(uri, headers: <String, String>{
      'Accept': '*/*',
      'Referer': asciiHeaderValue(referer.isEmpty ? '$base/' : referer),
    });

    // ── 失败判定：HTTP 状态 + 正文形态，两条都要看 ──
    // 实测：/download/99999999/x.rar -> 493 + text/xml 错误页
    //       CDN 无签名 URL -> 302 -> /download/failed/... -> 492 + 869 B
    if (!resp.isOk) {
      throw AssrtException(
        '下载失败：HTTP ${resp.statusCode}',
        statusCode: resp.statusCode,
        url: uri.toString(),
        body: _snip(resp.text),
      );
    }
    final ct = resp.contentType.toLowerCase();
    final head = resp.text.trimLeft();
    final looksLikeErrorPage = ct.contains('text/xml') ||
        ct.contains('application/xml') ||
        head.startsWith('<?xml') ||
        head.contains('<msgtitle>') ||
        head.contains('/download/failed/');
    if (looksLikeErrorPage) {
      throw AssrtException(
        '下载链接已失效（站点返回错误页，不是字幕字节）',
        statusCode: resp.statusCode,
        url: uri.toString(),
        body: _snip(resp.text),
      );
    }
    if (resp.bytes.isEmpty) {
      throw AssrtException('下载得到 0 字节',
          statusCode: resp.statusCode, url: uri.toString());
    }

    return AssrtDownload(
      bytes: resp.bytes,
      fileName: _fileNameOfResponse(resp, downloadPath),
      finalUrl: resp.finalUrl.isEmpty ? uri.toString() : resp.finalUrl,
      contentType: resp.contentType,
    );
  }

  static String _snip(String s) => s.length <= 400 ? s : s.substring(0, 400);

  static String _fileNameOfResponse(AssrtHttpResponse resp, String path) {
    final cd = resp.headers['content-disposition'] ?? '';
    final m = RegExp('filename="([^"]*)"').firstMatch(cd);
    if (m != null && m.group(1)!.isNotEmpty) {
      // ★ 头值里的中文是裸 UTF-8 字节、被 latin1 读成 mojibake ⇒ 必须转回来。
      //   不转的话这个乱码会直接变成落盘文件名（实测过，截图里就是乱码）。
      var name = utf8HeaderText(m.group(1)!);
      // 有些站点会把整个路径塞进 filename="..."，只取最后一段
      final slash = name.lastIndexOf(RegExp(r'[\\/]'));
      if (slash >= 0 && slash + 1 < name.length) name = name.substring(slash + 1);
      if (name.isNotEmpty) return name;
    }
    return utf8HeaderText(Uri.decodeComponent(fileNameOfDownloadPath(path)));
  }

  /// HTML 接口的失败判定：非 2xx，或者正文里出现站点的错误页标记
  void _ensureHtmlOk(AssrtHttpResponse resp, Uri uri, {required String what}) {
    if (!resp.isOk) {
      throw AssrtException('$what失败：HTTP ${resp.statusCode}',
          statusCode: resp.statusCode, url: uri.toString(), body: _snip(resp.text));
    }
    final t = resp.text;
    if (t.contains('<msgtitle>') || t.contains('/download/failed/')) {
      throw AssrtException('$what失败：站点返回错误页',
          statusCode: resp.statusCode, url: uri.toString(), body: _snip(t));
    }
    if (t.trim().isEmpty) {
      throw AssrtException('$what失败：响应正文为空',
          statusCode: resp.statusCode, url: uri.toString());
    }
  }

  void close() => _transport.close();
}
