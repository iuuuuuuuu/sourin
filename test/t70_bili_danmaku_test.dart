// ═══════════════════════════════════════════════════════════════════════
//  task-28：哔哩哔哩弹幕导入 / 自动绑定 / 自动更新 —— 全链路测试
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// > 支持一下 哔哩哔哩填入链接导入弹幕，并且自动绑定剧集和自动更新弹幕
// ```
//
// # 这个文件守什么（★ 四层，从「字节」到「像素」）
// ```text
// ① 传输层：dm/list.so 回的是**裸 deflate**，Dart 的 autoUncompress 解不了
//    ⇒ 断言 rawInflate 的正确性 + 断言「不用 rawInflate 就会失败」（红度对照）
// ② 解析层：B 站 p 是 9 段（颜色在下标 3），与 dandanplay 的 4 段（下标 2）
//    不是同一套 ⇒ 断言颜色/模式/排序/截断语义
// ③ 业务层：输入解析、分集对齐、自动绑定的接受/拒绝、增量的差集语义
// ④ UI 层：面板渲染 + 三个按钮的启用/禁用 + 回调真的接到宿主
// ```
//
// # ★★★ 为什么 ① 要写「红度对照」
//
// 本项目踩过 5 次「断言恒真」的坑（见 test/probe_cleanup_test.dart 头部）。
// 就本条而言：如果只断言 `rawInflate(bytes).length == 126075`，
// 那**把 rawInflate 换成恒等函数**也可能过不了 —— 但**换成 gzip 解压**呢？
// 光看「绿」分不出「解对了」和「碰巧没报错」。
// ⇒ 所以同时断言 `zlib.decode(同一份 bytes) 必须抛 FormatException`。
//   两条一起才证明：**这份数据只有 raw inflate 能解**。
//
// # 夹具出处（都是**真跑 HTTP 抓下来的**，不是手搓的）
// ```text
// test/data/bili_danmaku_sample.xml        122,680 B  1200 条  （identity 编码的响应体）
// test/data/bili_danmaku_raw_deflate.bin    47,592 B  1200 条  （同一接口的 deflate 响应体）
// 抓取脚本与响应头原文见 .probe/bili/03_dmlist_headers.txt 等
// ```
//
// # ⚠️ 两条「不要写」的纪律（都是实测踩出来的）
// ```text
// ① **不要断言 dmid 的十进制字面量**：B 站的 dmid 是 17~19 位，
//    全部 > 2^53 ⇒ 任何经 double 往返的路径（JS/JSON/日志）都会改写末几位。
//    实测：真值 44118477636632581，经 double 变成 ...584。
//    ⇒ 要断言身份就用 text / time / 位置，不用 dmid 数值。
// ② **不要把两份夹具的结论互相套用**：sample 与 raw_deflate 是
//    **两次不同的抓取**（时间不同 ⇒ 弹幕不同）。
//    实测：sample 的排序首条 = 「世 界 线 收 束」，raw_deflate 的排序首条
//    = 「宁  又  来  了」；sample 的 t=0 有 74 条，raw_deflate 有 86 条。
//    ⇒ 本文件只在 raw_deflate 上断言「能解开 + 条数」，
//      所有解析语义断言都只用 sample。
// ```
//
// # ⚠️ 关于「有没有发真网络」
// ```text
// 本文件**一个网络包都不发**：
//   · flutter_test 默认把全局 HttpClient 换成 mock（任何请求回 400 空响应，
//     并打印一行 Warning），本文件索性连真 client 都不造；
//   · 业务层用 _FakeApi（继承 BiliApi，只覆盖 danmaku()），
//     它的父类持有 _NoNetClient —— 一旦有人误走真路径，**直接抛**。
// 真实网络的端到端证据在 .probe/bili/TASK28-REPORT.md（真跑 dart，不在单测里）。
// ```

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/bili/bili_api.dart';
import 'package:sourin_spike/core/bili/bili_auto_update.dart';
import 'package:sourin_spike/core/bili/bili_bind.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/widgets/bili_import_dialog.dart';

// ══════════════════════════════════════════════════════════════════════
//  夹具
// ══════════════════════════════════════════════════════════════════════

const String _xmlPath = 'test/data/bili_danmaku_sample.xml';
const String _binPath = 'test/data/bili_danmaku_raw_deflate.bin';

/// 实测值（全部来自夹具本身，不是推算）
const int _rawDeflateBytes = 47592;
const int _inflatedBytes = 126075;
const int _sampleCount = 1200;

// ══════════════════════════════════════════════════════════════════════
//  测试替身
// ══════════════════════════════════════════════════════════════════════

/// 假 HttpClient：**任何**成员被用到就抛。
///
/// 为什么不实现全部 40 个成员：本文件根本不该走到那里 ——
/// 走到了就是测试写错了，报错比「静默发一个包出去」好得多。
class _NoNetClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
        '单测里不许用真 HttpClient（成员：${invocation.memberName}）',
      );
}

/// 只覆盖 [BiliApi.danmaku] 的假 API。
///
/// 它同时是「不触发网络」的证明：父类拿的是 [_NoNetClient]，
/// 而 updateDanmaku / updateForEpisode 只走 [danmaku] 这一个出口。
class _FakeApi extends BiliApi {
  _FakeApi({List<DanmakuComment>? comments, this.error})
      : _comments = comments ?? const <DanmakuComment>[],
        super(client: _NoNetClient());

  final List<DanmakuComment> _comments;

  /// 非 null ⇒ danmaku() 抛它（模拟网络/接口失败）。
  final Object? error;

  /// 发了几次请求 —— 用来断言「缓存命中时**一次都不发**」。
  int calls = 0;

  @override
  Future<List<DanmakuComment>> danmaku(int cid) async {
    calls++;
    final e = error;
    if (e != null) throw e;
    return _comments;
  }
}

/// 造一批可控的弹幕（cid 就是 id，增量比对用它）。
List<DanmakuComment> _comments(int from, int to) => <DanmakuComment>[
      for (var i = from; i <= to; i++)
        DanmakuComment(cid: i, time: i.toDouble(), text: 'm$i'),
    ];

/// 宿主回调的记账本。
class _Calls {
  String? importInput;
  int? importPage;
  int? picked;
  bool? autoUpdate;
  int? interval;
  int updateNow = 0;
  int unbind = 0;
  int close = 0;
}

/// 把面板套进真实的壳（与 test/episode_strip_test.dart 同款的最小壳）。
///
/// ⚠️ 必须用 material_ui 的 MaterialApp + 一层 Stack：
///   · 用 flutter/material 的 MaterialApp 会拿到 ThemeData.fallback()（亮色），
///     与生产不一致（见 test/material_split_test.dart）；
///   · 面板自己的 build 返回的是 `Positioned.fill`
///     ⇒ 它的父链里必须有一个 Stack，否则 ParentDataWidget 找不到宿主。
Widget _host(BiliImportState state, _Calls c) => MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Stack(
          children: <Widget>[
            BiliImportDialog(
              state: state,
              onImport: (String input, int page) async {
                c.importInput = input;
                c.importPage = page;
              },
              onSelectPage: (int p) => c.picked = p,
              onSetAutoUpdate: (bool v) => c.autoUpdate = v,
              onSetInterval: (int v) => c.interval = v,
              onUpdateNow: () async => c.updateNow++,
              onUnbind: () => c.unbind++,
              onClose: () => c.close++,
            ),
          ],
        ),
      ),
    );

/// 多 P 的示例视频信息（P1 / P2）。
BiliVideoInfo _info({int pages = 2}) => BiliVideoInfo(
      bvid: 'BV1GJ411x7h7',
      aid: 80433022,
      title: '某番剧 第一季',
      pages: <BiliPage>[
        for (var i = 1; i <= pages; i++)
          BiliPage(cid: 100 + i, page: i, part: '第' '$i' '话'),
      ],
    );

/// 已绑定的示例状态。
BiliBinding _binding({int episodes = 2}) => BiliBinding(
      bvid: 'BV1GJ411x7h7',
      title: '某番剧 第一季',
      aid: 80433022,
      episodes: <BiliEpisodeBinding>[
        for (var i = 0; i < episodes; i++)
          BiliEpisodeBinding(
            episodeIndex: i,
            page: i + 1,
            cid: 100 + i + 1,
            part: '第${i + 1}话',
          ),
      ],
    );

// ══════════════════════════════════════════════════════════════════════
//  静态审计用的小工具
// ══════════════════════════════════════════════════════════════════════

/// 剥掉 Dart 注释（行注释 + 块注释）。
///
/// ⚠️ 本仓踩过 3 次「断言匹配到注释文本 → 假通过」。
/// 本文件要断言的恰好是「文件里**没有** import flutter/material」——
/// 而 bili_import_dialog.dart 的头部注释里**正写着**那个字符串
/// ⇒ 不剥注释就是一条必然失败的断言（写反了也一样危险）。
String _stripDartComments(String src) {
  final out = StringBuffer();
  var inBlock = false;
  for (final line in src.split('\n')) {
    final buf = StringBuffer();
    var i = 0;
    while (i < line.length) {
      if (inBlock) {
        final end = line.indexOf('*/', i);
        if (end < 0) {
          i = line.length;
        } else {
          inBlock = false;
          i = end + 2;
        }
        continue;
      }
      if (line.startsWith('/*', i)) {
        inBlock = true;
        i += 2;
        continue;
      }
      if (line.startsWith('//', i)) break;
      buf.write(line[i]);
      i++;
    }
    out.writeln(buf.toString());
  }
  return out.toString();
}

void main() {
  final String xml = File(_xmlPath).readAsStringSync();
  final Uint8List rawBytes = File(_binPath).readAsBytesSync();

  // ═══════════════════════════════════════════════════════════════════
  //  ① 裸 deflate —— 这条链路最容易整段静默失败
  // ═══════════════════════════════════════════════════════════════════

  group('① 裸 deflate 解码（dm/list.so 的真实编码）', () {
    test('夹具本身就是裸 deflate（前 3 字节不是 zlib/gzip 头）', () {
      expect(rawBytes.length, _rawDeflateBytes);

      // zlib 头 = 0x78 开头（CMF：低 4 位 8 = deflate，高 4 位 = 窗口）
      // gzip 头 = 0x1F 0x8B
      // 实测 = 0xB4 0xFD 0x69 —— 既不是 zlib 也不是 gzip
      expect(rawBytes[0], 0xB4, reason: '实测首字节（不是 zlib 的 0x78）');
      expect(rawBytes[1], 0xFD);
      expect(rawBytes[0], isNot(0x78), reason: '★ 有 zlib 头才是 zlib 流');
      expect(rawBytes[0] == 0x1F && rawBytes[1] == 0x8B, isFalse,
          reason: '★ 也不是 gzip');
    });

    test('★★ rawInflate 解得开：126,075 B / 1200 条', () {
      final Uint8List out = Uint8List.fromList(rawInflate(rawBytes));

      expect(out.length, _inflatedBytes,
          reason: '★ 这是「解对了」的字节级判据（47,592 → 126,075）');

      final String text = utf8.decode(out, allowMalformed: true);
      expect(text.startsWith('<?xml version="1.0" encoding="UTF-8"?><i>'), isTrue,
          reason: '解压后的头必须是弹幕 XML 的声明 + <i> 根节点');

      expect('<d p='.allMatches(text).length, _sampleCount,
          reason: '1200 条弹幕（与 sample.xml 同量级，但不是同一份数据）');
      expect(text.endsWith('</i>'), isTrue);
    });

    test('★★ 红度对照：同一份字节交给 zlib.decode 必须抛', () {
      // 这条**不是**在测 zlib —— 是在证明上一条断言有分辨力：
      // 如果 rawInflate 退化成 zlib.decode（或者干脆 return 原样），
      // 上一条会红；而如果这份数据其实是 zlib 流，这一条会红。
      expect(
        () => zlib.decode(rawBytes),
        throwsA(isA<FormatException>()),
        reason: '★ 实测 FormatException: Filter error, bad data',
      );
    });

    test('rawInflate 对空输入 / 单字节垃圾的处理（不抛，交给调用方）', () {
      expect(rawInflate(<int>[]), isEmpty);
      // 一个字节什么也解不出来 —— 但**不该**抛到调用方
      expect(rawInflate(<int>[0xB4]), isEmpty);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② XML → DanmakuComment
  // ═══════════════════════════════════════════════════════════════════

  group('② 弹幕 XML 解析（颜色在下标 3，不是 dandanplay 的下标 2）', () {
    test('1200 条全部解析出来，且按 time 升序', () {
      final List<DanmakuComment> list = parseBiliDanmakuXml(xml);

      expect(list.length, _sampleCount);

      var sorted = true;
      for (var i = 1; i < list.length; i++) {
        if (list[i].time < list[i - 1].time) sorted = false;
      }
      expect(sorted, isTrue,
          reason: '★ DanmakuTrackAllocator.layout 要求输入已排序 —— 排序是解析器的责任');

      expect(list.first.time, 0.0);
      expect(list.last.time, 210.532,
          reason: '实测夹具的最大时间（末条正文 = 150*42）');
      expect(list.last.text, '150*42');
    });

    test('★ 同刻并列时按 cid 升序（夹具里有 148 个重复时刻）', () {
      // 实测：1200 条里只有 1052 个不同的 time ⇒ 差集全靠次级关键字
      final List<DanmakuComment> t0 =
          parseBiliDanmakuXml(xml).where((DanmakuComment c) => c.time == 0).toList();

      expect(t0.length, 74, reason: '实测 t=0 共 74 条');

      var sorted = true;
      for (var i = 1; i < t0.length; i++) {
        if (t0[i].cid < t0[i - 1].cid) sorted = false;
      }
      expect(sorted, isTrue, reason: '同刻必须按 cid（dmid）升序，否则顺序不稳定');
    });

    test('★ 颜色读的是 p[3]；> 0xFFFFFF 的带 alpha 值要截成 24 位', () {
      final List<DanmakuComment> list = parseBiliDanmakuXml(xml);

      // 实测：白 828 条 / 27 种颜色
      final int white = list.where((DanmakuComment c) => c.color == 0xFFFFFF).length;
      expect(white, 828);

      // big_color：p[3] = 99999999（> 0xFFFFFF）⇒ 0xF5E0FF
      final DanmakuComment big =
          list.firstWhere((DanmakuComment c) => c.text == 'big_color');
      expect(big.color, 0xF5E0FF,
          reason: '99999999 & 0xFFFFFF = 0xF5E0FF；若读成 p[2] 会得到字号 25');

      // 反证：p[2] 是字号，取出来是 25/18/28 —— 断言它**不等于**任何一条的颜色
      expect(big.color, isNot(25));
    });

    test('★ 模式映射：1/7 → 滚动，4 → 底部，5 → 顶部', () {
      final List<DanmakuComment> list = parseBiliDanmakuXml(xml);

      int n(DanmakuMode m) => list.where((DanmakuComment c) => c.mode == m).length;

      expect(n(DanmakuMode.scroll), 823, reason: '模式 1(815) + 7(8) 都按滚动处理');
      expect(n(DanmakuMode.bottom), 68, reason: '模式 4');
      expect(n(DanmakuMode.top), 309, reason: '模式 5');
      expect(list.length, 823 + 68 + 309);
    });

    test('高级弹幕（模式 7）不丢：正文原样保留', () {
      final List<DanmakuComment> list = parseBiliDanmakuXml(xml);

      final List<DanmakuComment> adv = list
          .where((DanmakuComment c) => c.text.startsWith('['))
          .toList();
      expect(adv.length, 37, reason: '实测 37 条正文以 [ 开头');

      final DanmakuComment first7 =
          list.firstWhere((DanmakuComment c) => c.time == 43.235);
      expect(first7.mode, DanmakuMode.scroll);
      expect(first7.text.startsWith('["0.05"'), isTrue,
          reason: '模式 7 的正文是一段 JSON 数组字符串，原样带出来');
    });

    test('uid 取的是 p[6]（hash），不是 p[3] 的颜色', () {
      final List<DanmakuComment> list = parseBiliDanmakuXml(xml);
      final DanmakuComment big =
          list.firstWhere((DanmakuComment c) => c.text == 'big_color');

      expect(big.userId, 'dbe63c24', reason: '实测 p = 2.00000,1,25,99999999,...,dbe63c24,...');
      expect(big.time, 2.0);
    });

    test('正文实体反转义 + 首尾空白裁剪', () {
      final List<DanmakuComment> list =
          parseBiliDanmakuXml('<i><d p="1,1,25,16777215,0,0,abc,7,0">  &lt;b&gt;hi&amp;  </d></i>');

      expect(list.length, 1);
      expect(list[0].text, '<b>hi&', reason: '反转义后 trim');
      expect(list[0].cid, 7);
    });

    test('坏条目直接跳过：空正文 / 时间非法 / 段数不足', () {
      const String bad = '<i>'
          '<d p="1,1,25,16777215,0,0,abc,1,0">   </d>'   // 正文全空白
          '<d p="abc,1,25,16777215,0,0,abc,2,0">ok</d>'  // 时间不是数
          '<d p="3,1">ok</d>'                            // 段数不足 4
          '<d p="4,1,25,16777215,0,0,abc,4,0">留下</d>'  // 唯一合法的一条
          '</i>';

      final List<DanmakuComment> list = parseBiliDanmakuXml(bad);
      expect(list.length, 1);
      expect(list[0].text, '留下');
      expect(list[0].time, 4.0);
    });

    test('★ max 的语义 = 文档序前 N 条，然后才排序', () {
      final List<DanmakuComment> three = parseBiliDanmakuXml(xml, max: 3);

      expect(three.length, 3);
      // 文档序前 3 条（实测）：
      //   0.601  我是一万个点赞，正在反复横跳
      //   9.416  J O J O 飙 马 野 郎 提 前 观 看 地 址
      //  35.391  I just wanna tell you how I'm feeling
      // ⚠️ 注意：**不是**取排序后的前 3 条（那三条都是 t=0 的）
      expect(three.map((DanmakuComment c) => c.text).toList(), <String>[
        '我是一万个点赞，正在反复横跳',
        'J O J O 飙 马 野 郎 提 前 观 看 地 址',
        "I just wanna tell you how I'm feeling",
      ]);
      expect(three.map((DanmakuComment c) => c.time).toList(), <double>[
        0.601,
        9.416,
        35.391,
      ]);

      // 对照：全量解析的前 3 条是 t=0 那批（证明上面确实不是「排序后前 3」）
      final List<DanmakuComment> all = parseBiliDanmakuXml(xml);
      expect(all.first.time, 0.0);
      expect(all.first.text, '世 界 线 收 束');
      expect(all[1].text, '无 敌 破 坏 王');
      expect(all[2].text, '免   费   流   量');
    });

    test('shift：整体平移；平移到负数的时间直接丢', () {
      final List<DanmakuComment> shifted =
          parseBiliDanmakuXml('<i><d p="10,1,25,16777215,0,0,abc,1,0">a</d></i>', shift: -2.5);
      expect(shifted.single.time, 7.5);

      final List<DanmakuComment> gone =
          parseBiliDanmakuXml('<i><d p="1,1,25,16777215,0,0,abc,1,0">a</d></i>', shift: -2);
      expect(gone, isEmpty, reason: '提前到负数 = 这条本来就不该出现');
    });

    test('空输入不炸', () {
      expect(parseBiliDanmakuXml(''), isEmpty);
    });

    test('unescapeXml：命名实体 + 数字实体 + 非法码点原样保留', () {
      expect(unescapeXml('a&lt;b&gt;c&quot;d&apos;e&amp;f'), 'a<b>c"d\'e&f');
      expect(unescapeXml('&#65;&#x42;'), 'AB');
      expect(unescapeXml('&#x110000;'), '&#x110000;', reason: '超出 U+10FFFF 不转');
      expect(unescapeXml('无实体'), '无实体');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 输入解析
  // ═══════════════════════════════════════════════════════════════════

  group('③ 输入解析：BV / av / 链接 / b23 短链', () {
    test('BV 号（裸的 / 夹在中文里 / 带分 P）', () {
      expect(parseBiliInput('BV1GJ411x7h7')!.bvid, 'BV1GJ411x7h7');

      final BiliRef? inText = parseBiliInput('看看这个 BV1GJ411x7h7 挺好看');
      expect(inText!.bvid, 'BV1GJ411x7h7');
      expect(inText.raw, '看看这个 BV1GJ411x7h7 挺好看', reason: '原文要留着回显');

      final BiliRef? p2 = parseBiliInput('https://www.bilibili.com/video/BV1GJ411x7h7/?p=2');
      expect(p2!.bvid, 'BV1GJ411x7h7');
      expect(p2.page, 2, reason: '?p=2');
      expect(p2.isResolved, isTrue);
      expect(p2.query, 'bvid=BV1GJ411x7h7');
      expect(p2.id, 'BV1GJ411x7h7');
    });

    test('av 号（大小写都认，且不许误吃长数字）', () {
      expect(parseBiliInput('av80433022')!.aid, 80433022);
      expect(parseBiliInput('AV80433022')!.aid, 80433022);
      expect(parseBiliInput('https://www.bilibili.com/video/av80433022')!.aid, 80433022);
      expect(parseBiliInput('av80433022')!.query, 'aid=80433022');
      expect(parseBiliInput('av80433022')!.id, 'av80433022');

      // 词边界：save123456789012 里的 "ave123456789012" 不该被当成 av 号
      expect(parseBiliInput('save123456789012'), isNull);
    });

    test('b23.tv 短链：只认 URL，还需要一次跳转', () {
      final BiliRef? s = parseBiliInput('https://b23.tv/abc1234');
      expect(s!.bvid, isEmpty);
      expect(s.shortUrl, 'https://b23.tv/abc1234');
      expect(s.isShortLink, isTrue);
      expect(s.isResolved, isFalse, reason: '★ 短链不能直接打 API');
    });

    test('分 P 的两种写法 + 认不出来返回 null', () {
      expect(parseBiliInput('https://www.bilibili.com/video/BV1GJ411x7h7?p=3')!.page, 3);
      expect(parseBiliInput('BV1GJ411x7h7_P2')!.page, 2);
      expect(parseBiliInput('BV1GJ411x7h7')!.page, 0, reason: '没写就是 0（取第 1 P）');

      expect(parseBiliInput(''), isNull);
      expect(parseBiliInput('   '), isNull);
      expect(parseBiliInput('https://www.youtube.com/watch?v=xxx'), isNull);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 分集对齐 + 自动绑定
  // ═══════════════════════════════════════════════════════════════════

  group('④ 分集对齐 alignEpisodes', () {
    test('没有分 P ⇒ 绑不上', () {
      expect(alignEpisodes(episodeTitles: <String>['a', 'b'], pages: <BiliPage>[]),
          isEmpty);
    });

    test('★ 单 P ⇒ 每一集都指向它（共用一条时间轴）', () {
      final List<BiliEpisodeBinding> eps = alignEpisodes(
        episodeTitles: <String>['第1话', '第2话', '第3话'],
        pages: <BiliPage>[const BiliPage(cid: 999, page: 1, part: '全集')],
      );

      expect(eps.length, 3);
      expect(eps.map((BiliEpisodeBinding e) => e.cid).toList(), <int>[999, 999, 999]);
      expect(eps.map((BiliEpisodeBinding e) => e.page).toList(), <int>[1, 1, 1]);
      expect(eps.map((BiliEpisodeBinding e) => e.episodeIndex).toList(), <int>[0, 1, 2]);
    });

    test('多 P ⇒ 按序一集对一 P；B 站 P 多出来的不绑', () {
      final List<BiliEpisodeBinding> eps = alignEpisodes(
        episodeTitles: <String>['a', 'b'],
        pages: <BiliPage>[
          const BiliPage(cid: 11, page: 1, part: 'x'),
          const BiliPage(cid: 22, page: 2, part: 'y'),
          const BiliPage(cid: 33, page: 3, part: 'z'),
        ],
      );

      expect(eps.length, 2);
      expect(eps.map((BiliEpisodeBinding e) => e.cid).toList(), <int>[11, 22]);
    });

    test('本地集数多于 P ⇒ 多出来的集没绑', () {
      final List<BiliEpisodeBinding> eps = alignEpisodes(
        episodeTitles: <String>['a', 'b', 'c', 'd'],
        pages: <BiliPage>[
          const BiliPage(cid: 11, page: 1),
          const BiliPage(cid: 22, page: 2),
        ],
      );
      expect(eps.length, 2);
    });

    test('★ 手动指定 P ⇒ 只绑一集', () {
      final List<BiliEpisodeBinding> eps = alignEpisodes(
        episodeTitles: <String>['a', 'b', 'c'],
        pages: <BiliPage>[
          const BiliPage(cid: 11, page: 1),
          const BiliPage(cid: 22, page: 2),
        ],
        forcedPage: 2,
        forcedEpisode: 2,
      );

      expect(eps.length, 1, reason: '指定了 P 就只绑那一集');
      expect(eps.single.episodeIndex, 2);
      expect(eps.single.page, 2);
      expect(eps.single.cid, 22);
    });

    test('指定了不存在的 P ⇒ 退回第 1 P（不空手）', () {
      final List<BiliEpisodeBinding> eps = alignEpisodes(
        episodeTitles: <String>['a'],
        pages: <BiliPage>[const BiliPage(cid: 11, page: 1)],
        forcedPage: 9,
      );
      expect(eps.single.cid, 11);
      expect(eps.single.episodeIndex, 0);
    });
  });

  group('④ 标题修正 refineByTitle', () {
    test('单 P / 空 base ⇒ 原样返回（不做任何猜测）', () {
      final List<BiliEpisodeBinding> base = <BiliEpisodeBinding>[
        const BiliEpisodeBinding(episodeIndex: 0, page: 1, cid: 11),
      ];
      expect(
        refineByTitle(
          episodeTitles: <String>['第1话'],
          pages: <BiliPage>[const BiliPage(cid: 11, page: 1, part: '第1话')],
          base: base,
        ),
        same(base),
      );
    });

    test('★ 标题更像的那一 P 会被换过来（搬运工放乱 P 序）', () {
      final List<BiliEpisodeBinding> fixed = refineByTitle(
        episodeTitles: <String>['第一话 出发', '第二话 归来'],
        pages: <BiliPage>[
          const BiliPage(cid: 22, page: 1, part: '第二话 归来'),
          const BiliPage(cid: 11, page: 2, part: '第一话 出发'),
        ],
        base: <BiliEpisodeBinding>[
          const BiliEpisodeBinding(episodeIndex: 0, page: 1, cid: 22, part: '第二话 归来'),
          const BiliEpisodeBinding(episodeIndex: 1, page: 2, cid: 11, part: '第一话 出发'),
        ],
      );

      expect(fixed[0].page, 2, reason: '第 1 集应该绑到「第一话 出发」那一 P');
      expect(fixed[0].cid, 11);
      expect(fixed[1].page, 1);
      expect(fixed[1].cid, 22);
    });

    test('★ 一个 P 只能被一集占用（先到先得）', () {
      // ⚠️ base 必须是 alignEpisodes 真能产出的形态（第 i 集 → pages[i]）。
      //    理由：refineByTitle 只在 planBinding 里被调用，而那里的 base 就是
      //    alignEpisodes 的输出。用「手搓的乱序 base」会构造出**生产走不到**
      //    的状态，那种断言要么恒真、要么固化一个不存在的契约
      //    （本项目已经踩过 5 次「测的不是发货代码」）。
      //
      // 本用例：两集标题都叫「第一话」，只有 P1 叫「第一话」。
      //   E0（在 P1）：标题命中 P1 ⇒ 保持不动，P1 被占用
      //   E1（在 P2）：P1 已被占用 ⇒ 只能在剩下的 P2 里挑；
      //                titleSimilarity('第一话','别的') = 0 < 阈值 ⇒ 保持 P2
      // ⇒ 两集仍然落在不同的 P 上。
      final List<BiliEpisodeBinding> fixed = refineByTitle(
        episodeTitles: <String>['第一话', '第一话'],
        pages: <BiliPage>[
          const BiliPage(cid: 11, page: 1, part: '第一话'),
          const BiliPage(cid: 22, page: 2, part: '别的'),
        ],
        base: <BiliEpisodeBinding>[
          const BiliEpisodeBinding(episodeIndex: 0, page: 1, cid: 11, part: '第一话'),
          const BiliEpisodeBinding(episodeIndex: 1, page: 2, cid: 22, part: '别的'),
        ],
      );

      expect(fixed.length, 2, reason: '一集一条，不增不减');
      expect(fixed[0].page, 1, reason: 'E0 的标题命中 P1，保持');
      expect(fixed[1].page, 2, reason: 'P1 已被 E0 占用 ⇒ E1 不抢');
      expect(
        fixed.map((BiliEpisodeBinding e) => e.page).toSet().length,
        2,
        reason: '★ 两集不许落在同一个 P 上',
      );
    });

    test('本地标题为空 ⇒ 保留按序结论', () {
      final List<BiliEpisodeBinding> fixed = refineByTitle(
        episodeTitles: <String>['', ''],
        pages: <BiliPage>[
          const BiliPage(cid: 11, page: 1, part: '第一话'),
          const BiliPage(cid: 22, page: 2, part: '第二话'),
        ],
        base: <BiliEpisodeBinding>[
          const BiliEpisodeBinding(episodeIndex: 0, page: 1, cid: 11),
          const BiliEpisodeBinding(episodeIndex: 1, page: 2, cid: 22),
        ],
      );
      expect(fixed.map((BiliEpisodeBinding e) => e.page).toList(), <int>[1, 2]);
    });
  });

  group('④ 自动绑定 planBinding', () {
    test('多 P 对齐 + 文案 + created', () {
      final BiliBindOutcome o = planBinding(
        info: _info(),
        localTitle: '某番剧 第一季',
        episodeTitles: <String>['第1话', '第2话'],
      );

      expect(o.binding.episodeCount, 2);
      expect(o.reason, '按 P 序对齐了 2 集');
      expect(o.created, isTrue, reason: '之前没绑过');
      expect(o.score, 1.0, reason: '标题一模一样 ⇒ bigram Jaccard = 1');
      expect(o.ok, isTrue);
      expect(o.binding.bvid, 'BV1GJ411x7h7');
      expect(o.binding.updatedAt, greaterThan(0));
    });

    test('单 P 的文案专门解释「所有集共用一条时间轴」', () {
      final BiliBindOutcome o = planBinding(
        info: _info(pages: 1),
        localTitle: '某番剧 第一季',
        episodeTitles: <String>['第1话', '第2话', '第3话'],
      );

      expect(o.binding.episodeCount, 3);
      expect(o.reason, 'B 站是单 P 视频，3 集共用这一条弹幕时间轴');
    });

    test('P 比本地集少 ⇒ 明说「多出来的集没绑」', () {
      final BiliBindOutcome o = planBinding(
        info: _info(),
        localTitle: '某番剧 第一季',
        episodeTitles: <String>['第1话', '第2话', '第3话', '第4话'],
      );

      expect(o.binding.episodeCount, 2);
      expect(o.reason, 'B 站只有 2 P，本地 4 集，多出来的集没绑');
    });

    test('B 站一个 P 都没有 ⇒ 绑不上', () {
      final BiliBindOutcome o = planBinding(
        info: _info(pages: 0),
        localTitle: 'x',
        episodeTitles: <String>['第1话'],
      );

      expect(o.binding.isEmpty, isTrue);
      expect(o.ok, isFalse);
      expect(o.reason, 'B 站那边一个分 P 都没有，没法绑');
    });

    test('手动指定的文案带上 P 号与集号', () {
      final BiliBindOutcome o = planBinding(
        info: _info(),
        localTitle: '某番剧 第一季',
        episodeTitles: <String>['第1话', '第2话'],
        forcedPage: 2,
        forcedEpisode: 1,
      );

      expect(o.reason, '按你指定的 P2 绑了第 2 集');
      expect(o.binding.episodeCount, 1);
    });

    test('★ 手动绑过的不许被自动流程改掉', () {
      final BiliBinding manual = _binding().copyWith(manual: true);
      final BiliBindOutcome o = planBinding(
        info: _info(),
        localTitle: '完全不一样的名字',
        episodeTitles: <String>['a', 'b', 'c', 'd', 'e'],
        existing: manual,
      );

      expect(o.reason, '这是你手动绑的，自动流程不动它');
      expect(o.binding, same(manual), reason: '原样返回，连 copy 都不做');
      expect(o.created, isFalse);
      expect(o.score, lessThan(kBiliAutoBindThreshold), reason: '分很低也不影响');
    });

    test('换了一个 BV 号 ⇒ 视为新建', () {
      final BiliBindOutcome o = planBinding(
        info: _info(),
        localTitle: '某番剧 第一季',
        episodeTitles: <String>['第1话', '第2话'],
        existing: _binding().copyWith(bvid: 'BV1other0001', manual: true),
      );

      expect(o.created, isTrue);
      expect(o.reason, '按 P 序对齐了 2 集');
    });

    test('★ 自动绑定的接受/拒绝：单 P 永不放行门槛', () {
      final BiliBindOutcome weak = planBinding(
        info: _info(),
        localTitle: '完全不搭边',
        episodeTitles: <String>['第1话', '第2话'],
      );

      expect(weak.score, lessThan(kBiliAutoBindThreshold));
      expect(shouldRejectAutoBind(weak, isMultiPart: true), isTrue,
          reason: '多 P + 标题不像 ⇒ 拒绝（避免绑错一整季）');
      expect(shouldRejectAutoBind(weak), isFalse,
          reason: '★ 单 P 不设门槛：用户填了链接就是想绑');
    });

    test('标题像 ⇒ 不拒绝', () {
      final BiliBindOutcome strong = planBinding(
        info: _info(),
        localTitle: '某番剧 第一季',
        episodeTitles: <String>['第1话', '第2话'],
      );
      expect(shouldRejectAutoBind(strong, isMultiPart: true), isFalse);
    });
  });

  group('④ 绑定落盘与取回（UiPrefs 内存态）', () {
    setUp(UiPrefs.debugResetForTest);

    test('save / load 往返 + 手动标记单独存一个键', () {
      saveBinding('demo', 'id1', _binding());
      final BiliBinding? back = loadBinding('demo', 'id1');

      expect(back, isNotNull);
      expect(back!.bvid, 'BV1GJ411x7h7');
      expect(back.episodeCount, 2);
      expect(back.manual, isFalse);
      expect(back.cidFor(0), 101);
      expect(back.pageFor(1), 2);
      expect(back.cidFor(99), 0, reason: '没绑的集返回 0');
      expect(isManualBinding('demo', 'id1'), isFalse);

      saveBinding('demo', 'id1', _binding().copyWith(manual: true));
      expect(isManualBinding('demo', 'id1'), isTrue);
      expect(loadBinding('demo', 'id1')!.manual, isTrue);

      clearBinding('demo', 'id1');
      expect(loadBinding('demo', 'id1'), isNull);
      expect(isManualBinding('demo', 'id1'), isFalse, reason: '手动标记也要清掉');
      expect(UiPrefs.get(BiliPrefs.pageKey('demo', 'id1')), isNull);
    });

    test('偏好键的形态（旧键名不许漂移）', () {
      expect(BiliPrefs.bindKey('demo', 'id1'), 'dsh.bili.bind.demo:id1');
      expect(BiliPrefs.manualKey('demo', 'id1'), 'dsh.bili.manual.demo:id1');
      expect(BiliPrefs.pageKey('demo', 'id1'), 'dsh.bili.page.demo:id1');
      expect(BiliPrefs.autoUpdateKey, 'dsh.bili.autoupdate');
      expect(BiliPrefs.lastSyncKey, 'dsh.bili.lastsync');
      expect(BiliPrefs.intervalKey, 'dsh.bili.interval');
    });

    test('损坏的 JSON 不抛，返回 null', () {
      UiPrefs.set(BiliPrefs.bindKey('demo', 'bad'), '{不是 json');
      expect(loadBinding('demo', 'bad'), isNull);
    });

    test('toJson / fromJson 往返（短键）', () {
      final BiliBinding b = _binding();
      final Object? o = jsonDecode(jsonEncode(b.toJson()));
      final BiliBinding? back = BiliBinding.fromJson(o);

      expect(back!.bvid, b.bvid);
      expect(back.title, b.title);
      expect(back.aid, b.aid);
      expect(back.episodeCount, 2);
      expect(back.episodes[1].part, '第2话');

      expect(BiliBinding.fromJson(<String, dynamic>{'b': ''}), isNull);
      expect(BiliBinding.fromJson('字符串'), isNull);
      expect(BiliEpisodeBinding.fromJson(<String, dynamic>{'i': 0, 'p': 1, 'c': 0}), isNull,
          reason: 'cid <= 0 的条目直接丢');
    });
  });

  group('④ 取某一集用哪个 cid', () {
    setUp(UiPrefs.debugResetForTest);

    test('有绑定 ⇒ 返回该集的 cid；越界且只绑了 1 集 ⇒ 退回第 0 集', () {
      saveBinding('demo', 'id1', _binding());
      expect(resolveCid(provider: 'demo', id: 'id1', episodeIndex: 0), 101);
      expect(resolveCid(provider: 'demo', id: 'id1', episodeIndex: 1), 102);
      expect(resolveCid(provider: 'demo', id: 'id1', episodeIndex: 5), 0,
          reason: '绑了 2 集，第 6 集没有对应');

      saveBinding('demo', 'single', _binding(episodes: 1));
      expect(resolveCid(provider: 'demo', id: 'single', episodeIndex: 5), 101,
          reason: '★ 单 P 场景所有集共用一个 cid，越界也不空手');
    });

    test('没绑定 ⇒ 0；resolveEpisodeBinding 同构', () {
      expect(resolveCid(provider: 'demo', id: 'none', episodeIndex: 0), 0);
      expect(resolveEpisodeBinding(provider: 'demo', id: 'none', episodeIndex: 0), isNull);

      saveBinding('demo', 'id1', _binding());
      expect(resolveEpisodeBinding(provider: 'demo', id: 'id1', episodeIndex: 1)!.page, 2);
      expect(resolveEpisodeBinding(provider: 'demo', id: 'id1', episodeIndex: 9), isNull);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ 自动更新 + 增量
  // ═══════════════════════════════════════════════════════════════════

  group('⑤ 弹幕缓存与增量', () {
    setUp(BiliDanmakuStore.debugResetForTest);

    test('首次拉取：全部算新增', () async {
      final _FakeApi api = _FakeApi(comments: _comments(1, 5));
      final BiliUpdateResult r = await updateDanmaku(api: api, cid: 1001);

      expect(api.calls, 1);
      expect(r.ok, isTrue);
      expect(r.total, 5);
      expect(r.added, 5);
      expect(r.removed, 0);
      expect(r.changed, isTrue);
      expect(r.fromCache, isFalse);
      expect(r.summary, '新增 5 条，共 5 条');
      expect(BiliDanmakuStore.has(1001), isTrue);
      expect(BiliDanmakuStore.idsOf(1001), <int>{1, 2, 3, 4, 5});
    });

    test('★ 时效内再进这一集：直接吃缓存，一次请求都不发', () async {
      final _FakeApi api = _FakeApi(comments: _comments(1, 5));
      await updateDanmaku(api: api, cid: 1002);
      final BiliUpdateResult again = await updateDanmaku(api: api, cid: 1002);

      expect(api.calls, 1, reason: '★ 这是「自动更新」不刷屏的关键：没到期不打 API');
      expect(again.fromCache, isTrue);
      expect(again.changed, isFalse);
      expect(again.total, 5);
      expect(again.summary, '缓存命中（5 条）');
    });

    test('★ force = true 无视缓存时效', () async {
      final _FakeApi api = _FakeApi(comments: _comments(1, 5));
      await updateDanmaku(api: api, cid: 1003);
      await updateDanmaku(api: api, cid: 1003, force: true);

      expect(api.calls, 2, reason: '「立即更新」按钮走的就是 force');
    });

    test('★ 增量 = 按 dmid 求差集（服务端每次吐全量）', () async {
      final _FakeApi first = _FakeApi(comments: _comments(1, 5));
      await updateDanmaku(api: first, cid: 1004);

      // 第二次：3、4 被删了，6、7 是新的
      final _FakeApi second = _FakeApi(comments: <DanmakuComment>[
        ..._comments(1, 2),
        ..._comments(6, 7),
      ]);
      final BiliUpdateResult r =
          await updateDanmaku(api: second, cid: 1004, force: true);

      expect(r.total, 4);
      expect(r.added, 2, reason: '6、7 是新的');
      // ⚠️ removed = 3（不是 2）：旧集合是 {1,2,3,4,5}，新集合是 {1,2,6,7}
      //    差集 = {3,4,5} —— 我第一版手算成 2，是**测试写错**，被这条断言抓住了
      expect(r.removed, 3, reason: '3、4、5 在新集合里都没有了');
      expect(r.changed, isTrue);
      expect(r.summary, '新增 2 条，减少 3 条，共 4 条');
      expect(BiliDanmakuStore.idsOf(1004), <int>{1, 2, 6, 7});
    });

    test('内容没变 ⇒ changed = false（文案说「没有新弹幕」）', () async {
      final _FakeApi api = _FakeApi(comments: _comments(1, 3));
      await updateDanmaku(api: api, cid: 1005);
      final BiliUpdateResult r = await updateDanmaku(api: api, cid: 1005, force: true);

      expect(r.changed, isFalse);
      expect(r.added, 0);
      expect(r.removed, 0);
      expect(r.summary, '没有新弹幕（3 条）');
    });

    test('★ 请求失败不抛：返回 error + 上一次的内容', () async {
      final _FakeApi ok = _FakeApi(comments: _comments(1, 4));
      await updateDanmaku(api: ok, cid: 1006);

      final _FakeApi boom = _FakeApi(
        error: DanmakuException(
          '弹幕接口返回 HTTP 503',
          statusCode: 503,
          uri: 'https://api.bilibili.com/x/v1/dm/list.so?oid=1006',
        ),
      );
      final BiliUpdateResult r = await updateDanmaku(api: boom, cid: 1006, force: true);

      expect(r.ok, isFalse);
      expect(r.error, contains('DanmakuException'));
      expect(r.error, contains('HTTP 503'));
      expect(r.fromCache, isTrue, reason: '有旧缓存 ⇒ 播放页还能拿到上次的弹幕');
      expect(r.comments.length, 4, reason: '★ 旧内容原样带回来，不是空白');
      expect(r.changed, isFalse);
      expect(r.summary, startsWith('更新失败：'));
    });

    test('第一次就失败 ⇒ 空结果 + error', () async {
      final _FakeApi boom = _FakeApi(error: StateError('网络不通'));
      final BiliUpdateResult r = await updateDanmaku(api: boom, cid: 1007);

      expect(r.ok, isFalse);
      expect(r.fromCache, isFalse);
      expect(r.total, 0);
      expect(r.comments, isEmpty);
      expect(r.error, contains('网络不通'));
    });

    test('缓存条数上限 12，超了淘汰最早那条', () async {
      final _FakeApi api = _FakeApi(comments: _comments(1, 1));
      for (var cid = 1; cid <= 13; cid++) {
        await updateDanmaku(api: api, cid: cid);
      }

      expect(BiliDanmakuStore.maxEntries, 12);
      expect(BiliDanmakuStore.has(1), isFalse, reason: '最早写入的被淘汰');
      expect(BiliDanmakuStore.has(13), isTrue);
      expect(BiliDanmakuStore.has(2), isTrue);
    });
  });

  group('⑤ updateForEpisode：没绑定就不发请求', () {
    setUp(UiPrefs.debugResetForTest);

    test('★ 没绑定 ⇒ 直接返回错误，一个包都不发', () async {
      final _FakeApi api = _FakeApi(comments: _comments(1, 9));
      final BiliUpdateResult r = await updateForEpisode(
        api: api,
        provider: 'demo',
        id: 'id1',
        episodeIndex: 0,
      );

      expect(api.calls, 0, reason: '★★ 这是本文件最重要的一条「不发请求」断言');
      expect(r.ok, isFalse);
      expect(r.error, '这一集还没有绑定 B 站弹幕');
      expect(r.cid, 0);
      expect(r.total, 0);
    });

    test('绑定了 ⇒ 用该集的 cid 去拉', () async {
      saveBinding('demo', 'id1', _binding());
      final _FakeApi api = _FakeApi(comments: _comments(1, 3));
      final BiliUpdateResult r = await updateForEpisode(
        api: api,
        provider: 'demo',
        id: 'id1',
        episodeIndex: 1,
      );

      expect(api.calls, 1);
      expect(r.cid, 102, reason: '第 2 集绑的是 P2 / cid 102');
      expect(r.total, 3);
    });
  });

  group('⑤ 自动更新的开关与间隔（全局偏好）', () {
    setUp(UiPrefs.debugResetForTest);

    test('默认是开的', () {
      expect(biliAutoUpdateEnabled(), isTrue, reason: '★ 用户要的就是「自动更新」');
      expect(biliAutoUpdateInterval(), 30);
      expect(defaultIntervalMinutes, 30);
    });

    test('开关往返', () {
      setBiliAutoUpdateEnabled(false);
      expect(biliAutoUpdateEnabled(), isFalse);
      setBiliAutoUpdateEnabled(true);
      expect(biliAutoUpdateEnabled(), isTrue);
    });

    test('★ 间隔被夹在 5 ~ 1440 分钟；越界值读回来回落成默认', () {
      setBiliAutoUpdateInterval(1);
      expect(biliAutoUpdateInterval(), 5, reason: '写 1 被夹到 5');
      setBiliAutoUpdateInterval(99999);
      expect(biliAutoUpdateInterval(), 1440);

      // 绕过 setter 直接写坏值（模拟手改配置文件）
      UiPrefs.set(BiliPrefs.intervalKey, '3');
      expect(biliAutoUpdateInterval(), 30, reason: '读的时候也兜一次');
      UiPrefs.set(BiliPrefs.intervalKey, '不是数字');
      expect(biliAutoUpdateInterval(), 30);
    });

    test('同步时间戳 + minutesSinceLastSync 的「从没同步过」哨兵', () {
      expect(biliLastSyncAt(), 0);
      expect(minutesSinceLastSync(), 1 << 30, reason: '★ 哨兵值 = 很久很久以前');

      markBiliSynced();
      expect(biliLastSyncAt(), greaterThan(0));
      expect(minutesSinceLastSync(), 0);
    });

    test('shouldAutoUpdate：开关关了就不更新；缓存新鲜也不更新', () async {
      expect(shouldAutoUpdate(), isTrue, reason: '没给 cid ⇒ 交给调用方决定');
      expect(shouldAutoUpdate(cid: 1001), isTrue, reason: '没缓存 = 过期');

      final _FakeApi api = _FakeApi(comments: _comments(1, 2));
      await updateDanmaku(api: api, cid: 1001);
      expect(shouldAutoUpdate(cid: 1001), isFalse, reason: '刚拉过，还新鲜');

      setBiliAutoUpdateEnabled(false);
      expect(shouldAutoUpdate(cid: 1001), isFalse);
      expect(shouldAutoUpdate(), isFalse, reason: '开关优先于一切');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑥ 面板（纯 UI，宿主给状态、回调回宿主）
  // ═══════════════════════════════════════════════════════════════════

  group('⑥ 导入面板', () {
    testWidgets('未绑定：状态文案 + 「立即更新」和「解除绑定」都不可用', (WidgetTester t) async {
      final _Calls c = _Calls();
      await t.pumpWidget(_host(const BiliImportState(), c));
      await t.pump();

      expect(find.text('哔哩哔哩弹幕'), findsOneWidget);
      expect(find.text('视频链接'), findsOneWidget);
      expect(find.text('BV 号 / av 号 / 完整链接 / b23.tv 短链都行'), findsOneWidget);
      expect(find.text('https://www.bilibili.com/video/BV1GJ411x7h7'), findsOneWidget);
      expect(find.text('弹幕是免登录抓的，不需要 B 站账号。'), findsOneWidget);

      expect(find.text('还没绑定 B 站弹幕'), findsOneWidget);

      // 三个按钮：只有「导入并绑定」可用
      final FilledButton import = t.widget<FilledButton>(
        find.widgetWithText(FilledButton, '导入并绑定'),
      );
      expect(import.onPressed, isNotNull);

      final TextButton update = t.widget<TextButton>(
        find.widgetWithText(TextButton, '立即更新'),
      );
      expect(update.onPressed, isNull, reason: '★ 没绑定 ⇒ 没有可更新的东西');

      expect(find.text('解除绑定'), findsNothing, reason: '没绑定就没有解除');
      expect(find.text('分 P 对齐'), findsNothing, reason: '只有 1 P 时不显示分 P 区');
    });

    testWidgets('★ 输入 → 点「导入并绑定」→ 回调带着去空格后的文本和当前 P', (WidgetTester t) async {
      final _Calls c = _Calls();
      await t.pumpWidget(_host(const BiliImportState(selectedPage: 2), c));
      await t.pump();

      await t.enterText(find.byType(TextField), '  BV1GJ411x7h7  ');
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, '导入并绑定'));
      await t.pump();

      expect(c.importInput, 'BV1GJ411x7h7', reason: '首尾空白要裁掉');
      expect(c.importPage, 2, reason: '把当前选中的 P 一起回传');
    });

    testWidgets('输入为空 ⇒ 点按钮不发任何回调', (WidgetTester t) async {
      final _Calls c = _Calls();
      await t.pumpWidget(_host(const BiliImportState(), c));
      await t.pump();

      await t.tap(find.widgetWithText(FilledButton, '导入并绑定'));
      await t.pump();

      expect(c.importInput, isNull);
    });

    testWidgets('加载中：按钮全禁 + 输入框禁用 + 转圈', (WidgetTester t) async {
      final _Calls c = _Calls();
      await t.pumpWidget(_host(
        BiliImportState(loading: true, busyLabel: '正在拉视频信息…', binding: _binding()),
        c,
      ));
      await t.pump(); // ⚠️ 不能 pumpAndSettle：转圈永不静止

      expect(find.text('正在拉视频信息…'), findsOneWidget);
      expect(t.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(
        t.widget<FilledButton>(find.widgetWithText(FilledButton, '导入并绑定')).onPressed,
        isNull,
      );
      expect(
        t.widget<TextButton>(find.widgetWithText(TextButton, '立即更新')).onPressed,
        isNull,
        reason: '★ 已经有一个请求在飞了，不许再点',
      );
      expect(find.text('解除绑定'), findsNothing, reason: '加载中不显示解除');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('已绑定：状态 + 视频/集/P/cid 四行信息 + 按钮都可用', (WidgetTester t) async {
      final _Calls c = _Calls();
      await t.pumpWidget(_host(
        BiliImportState(
          binding: _binding(),
          info: _info(),
          pages: _info().pages,
          episodeIndex: 1,
          episodeTitle: '第2话',
          episodeCount: 3,
          comments: 42,
        ),
        c,
      ));
      await t.pump();

      expect(find.text('已绑定 · 自动更新每 30 分钟一次'), findsOneWidget);
      expect(find.text('B 站视频：某番剧 第一季'), findsOneWidget);
      expect(find.text('本机第 2 集 / 共 3 集　→　B 站 P2（cid 102）'), findsOneWidget);
      expect(find.text('这一集挂了 42 条弹幕'), findsOneWidget);

      expect(
        t.widget<TextButton>(find.widgetWithText(TextButton, '立即更新')).onPressed,
        isNotNull,
      );
      expect(find.text('解除绑定'), findsOneWidget);
    });

    testWidgets('自动更新关掉 ⇒ 状态文案换成「已关」', (WidgetTester t) async {
      final _Calls c = _Calls();
      await t.pumpWidget(_host(
        BiliImportState(binding: _binding(), autoUpdate: false),
        c,
      ));
      await t.pump();

      expect(find.text('已绑定 · 自动更新已关'), findsOneWidget);
      expect(find.text('已绑定 · 自动更新每 30 分钟一次'), findsNothing);
    });

    testWidgets('★ 多 P 才显示分 P 区；点某个 P 回传它的 P 号', (WidgetTester t) async {
      final _Calls c = _Calls();
      final BiliVideoInfo info = _info();
      await t.pumpWidget(_host(
        BiliImportState(binding: _binding(), info: info, pages: info.pages),
        c,
      ));
      await t.pump();

      expect(find.text('分 P 对齐'), findsOneWidget);
      expect(find.text('默认按顺序一集对一 P'), findsOneWidget);
      expect(
        find.text('这个 B 站视频有 2 P。选「自动」时：多 P 按顺序对齐；只有 1 P 时所有集共用这一条时间轴。'),
        findsOneWidget,
      );
      expect(find.text('自动'), findsOneWidget);
      expect(find.text('P1'), findsOneWidget);
      expect(find.text('P2'), findsOneWidget);

      await t.tap(find.text('P2'));
      await t.pump();
      expect(c.picked, 2);

      await t.tap(find.text('自动'));
      await t.pump();
      expect(c.picked, 0, reason: '0 = 自动');
    });

    testWidgets('★ 开关和滑条真的接到宿主回调', (WidgetTester t) async {
      final _Calls c = _Calls();
      await t.pumpWidget(_host(BiliImportState(binding: _binding()), c));
      await t.pump();

      expect(find.text('自动更新'), findsOneWidget);
      expect(find.text('重新进入这一集时自动比对增量'), findsOneWidget);
      expect(find.text('间隔'), findsOneWidget);
      expect(find.text('30 分钟'), findsOneWidget);

      // 滑条的量程与当前值（写死在这里，改了就红）
      final Slider slider = t.widget<Slider>(find.byType(Slider));
      expect(slider.min, 5);
      expect(slider.max, 240);
      expect(slider.value, 30);

      await t.tap(find.byType(Switch));
      await t.pump();
      expect(c.autoUpdate, isFalse, reason: '当前是 true，点一下变 false');

      // 拖到最左 ⇒ 夹到 min = 5
      await t.drag(find.byType(Slider), const Offset(-400, 0));
      await t.pump();
      expect(c.interval, 5, reason: '★ 拖到最左必须夹在 5（不能是 0 或负数）');
    });

    testWidgets('★ 「立即更新」走 force 那条回调（不是重新导入）', (WidgetTester t) async {
      final _Calls c = _Calls();
      await t.pumpWidget(_host(BiliImportState(binding: _binding()), c));
      await t.pump();

      await t.tap(find.widgetWithText(TextButton, '立即更新'));
      await t.pump();

      expect(c.updateNow, 1);
      expect(c.importInput, isNull, reason: '不是导入');

      await t.tap(find.text('解除绑定'));
      await t.pump();
      expect(c.unbind, 1);
    });

    testWidgets('点背景关闭；点卡片内部不关', (WidgetTester t) async {
      final _Calls c = _Calls();
      await t.pumpWidget(_host(BiliImportState(binding: _binding()), c));
      await t.pump();

      // 卡片左上角之外（面板根节点铺满整屏，角落一定是 scrim）
      await t.tapAt(const Offset(8, 8));
      await t.pump();
      expect(c.close, 1, reason: '点 scrim 关闭（与播放页其它面板一致）');

      await t.tap(find.text('视频链接'));
      await t.pump();
      expect(c.close, 1, reason: '点卡片内部不该关掉面板');
    });

    testWidgets('失败态：一句话 + 服务端原文都显示出来', (WidgetTester t) async {
      final _Calls c = _Calls();
      await t.pumpWidget(_host(
        BiliImportState(
          error: DanmakuException(
            '视频信息接口返回 HTTP 404',
            statusCode: 404,
            uri: 'https://api.bilibili.com/x/web-interface/view?bvid=BV1GJ411x7h7',
            body: '{"code":-404,"message":"啥都木有"}',
          ),
        ),
        c,
      ));
      await t.pump();

      expect(find.text('上次导入失败（下方有服务端原文）'), findsOneWidget);
      expect(find.text('视频信息接口返回 HTTP 404'), findsOneWidget);
      expect(
        find.textContaining('HTTP 404', findRichText: false),
        findsWidgets,
        reason: 'e.detail 里逐行写着状态码',
      );
      expect(find.textContaining('啥都木有'), findsOneWidget, reason: '服务端原文必须原样给用户');
    });

    testWidgets('真实请求区：只显示最近 5 条，且最新在上', (WidgetTester t) async {
      final _Calls c = _Calls();
      final List<BiliHttpTrace> trace = <BiliHttpTrace>[
        for (var i = 1; i <= 7; i++)
          BiliHttpTrace(
            method: 'GET',
            uri: 'https://api.bilibili.com/x/v1/dm/list.so?oid=$i',
            status: 200,
            bytes: i * 100,
            contentEncoding: 'deflate',
            elapsedMs: i * 10,
            note: 'raw-deflate $i',
          ),
      ];
      await t.pumpWidget(_host(
        BiliImportState(binding: _binding(), trace: trace),
        c,
      ));
      await t.pump();

      expect(find.text('真实请求'), findsOneWidget);
      expect(find.text('共 7 条，显示最近 5 条'), findsOneWidget);

      // 最新在上：第 7 条先出现
      final double y7 = t.getTopLeft(find.textContaining('oid=7').first).dy;
      final double y3 = t.getTopLeft(find.textContaining('oid=3').first).dy;
      expect(y7, lessThan(y3), reason: '★ 倒序：最新的在最上面');

      expect(find.textContaining('oid=1'), findsNothing, reason: '被截掉了');
      expect(find.textContaining('oid=2'), findsNothing);
      expect(find.textContaining('oid=3'), findsOneWidget);
    });

    testWidgets('更新结果的那句话显示在状态区', (WidgetTester t) async {
      final _Calls c = _Calls();
      await t.pumpWidget(_host(
        BiliImportState(
          binding: _binding(),
          result: const BiliUpdateResult(
            cid: 101,
            total: 30,
            added: 4,
            removed: 0,
            fromCache: false,
            changed: true,
          ),
        ),
        c,
      ));
      await t.pump();

      expect(find.text('新增 4 条，共 30 条'), findsOneWidget);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑦ 静态审计：这次交付的四个文件不许把 UI 依赖带进 core
  // ═══════════════════════════════════════════════════════════════════

  group('⑦ 静态审计', () {
    test('★ core/bili 的三个文件不许 import flutter/material（剥注释后再看）', () {
      for (final String rel in <String>[
        'lib/core/bili/bili_api.dart',
        'lib/core/bili/bili_bind.dart',
        'lib/core/bili/bili_auto_update.dart',
      ]) {
        final String code = _stripDartComments(File(rel).readAsStringSync());
        expect(code.contains('package:flutter/material.dart'), isFalse, reason: rel);
        expect(code.contains('material_ui'), isFalse,
            reason: '$rel 是 core 层，不许依赖任何 UI 包');
      }
    });

    test('★ 面板文件不许 import flutter/material（注释里写着这句，所以必须剥注释）', () {
      final String raw = File('lib/ui/widgets/bili_import_dialog.dart').readAsStringSync();
      final String code = _stripDartComments(raw);

      // 先证明「剥注释」这件事本身是必要的：原始文本里**有**这个字符串
      // （头部注释写着「禁止 package:flutter/material.dart」）
      expect(raw.contains('package:flutter/material.dart'), isTrue,
          reason: '★ 注释里就该有它 —— 否则这条测试是假绿（判据被绕过了）');
      expect(code.contains('package:flutter/material.dart'), isFalse,
          reason: '真正 import 的必须是 material_ui');
      expect(code.contains("package:material_ui/material_ui.dart"), isTrue);
    });

    test('面板的根节点默认仍是 Positioned.fill（单测必须套 Stack 的原因）', () {
      final String code = _stripDartComments(
        File('lib/ui/widgets/bili_import_dialog.dart').readAsStringSync(),
      );
      /*
       * ★★★ task-104：根节点多了 `fill` 开关（默认 true）—— 判据跟着形态走，
       *     语义一字不变：**默认**挂载时必须自带 `Positioned.fill`（本文件
       *     所有 widget 测试都要套 Stack 的前提就是它）。
       *     `fill: false` 只给播放页的 SheetExitMotion 用（那里不能再写
       *     Positioned —— 会抛 Incorrect use of ParentDataWidget），由 t104 门禁单独钉。
       */
      expect(code.contains('return widget.fill ? Positioned.fill(child: body) : body;'),
          isTrue,
          reason: '★ 改了这个，本文件 ⑥ 组所有 widget 测试都会炸 —— 提前给出人话');
      expect(code.contains('this.fill = true,'), isTrue,
          reason: '★ 默认必须是 true —— 否则单测必须套 Stack 的前提就没了');
    });
  });
}
