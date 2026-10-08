// ══════════════════════════════════════════════════════════════════════
//  t461 —— ★★★ 播放中拖动 ⇒ 必须**停住**（Owner 第三次反馈）
// ══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// 「在播放的过程中,拖动调整片头片尾,状态应该重置,不应该继续播放,
//   应该是变回拖动结束后的那一帧预览」
// ```
//
// # 改前的 bug
// ```text
// 用户点「整段」⇒ _previewRange ⇒ _preview.play()   ← 预览**正在播**
// 然后拖时间轴箭头
//   ⇒ onChanged ⇒ _followPreviewTo ⇒ _previewSeek(v)
//   ⇒ ★ `_previewSeek` **只 seek、不暂停**
//   ⇒ 画面 seek 过去后**继续往前走** ⇒ 看不到那一帧
//   ⇒ 而且 `_loopTimer` 还在跑 ⇒ 越界就把画面**拽回区间起点**
// ```
//
// # 这条测试怎么验"停住"
//
// 预览播放器在本环境加载不了 `sourin_core.dll`（无核心库），
// `_preview` 恒为 null ⇒ 直接观察 `play()`/`pause()` 不可行。
//
// ★ 改用**可观察的代理**：
// ```text
// `_previewFrame` 做三件事：
//   ① _loopTimer?.cancel()  ⇒ _loopTimer 变 null（可观察）
//   ② _preview?.pause()     ⇒ 播放器为 null 时是 no-op
//   ③ _previewSeek(v)       ⇒ _previewPos = v（可观察）
// `_previewSeek` 只做 ③
// ⇒ ★ 判据：拖动后 `_previewPos` **变了**（证明跟随生效），
//   并且**区间循环被清掉了**（证明"状态重置"）。
// ```
//
// ⚠️ 而"循环被清掉"在外部怎么观察？
//    `_previewRange` 是「整段」按钮触发的，它设 `_loopFrom/_loopTo`
//    并起 `_loopTimer`。这些是**私有状态**，测试读不到。
//
// ★ 所以改用**行为判据**：让预览"看起来在播"——
//   在拖动**之前**先点一次「整段」（若按钮可用），
//   然后拖动，然后断言 `_previewPos` 停在**拖动值**上而不是被循环拉走。
//
// ⚠️ 更可靠的做法（本文件采用）：直接断言**源码结构**——
//    `_followPreviewTo` 必须调用 `_previewFrame`（会 pause），
//    **不得**调用 `_previewSeek`（不 pause）。
//    这是"决定"的断言，不是"实现细节"的断言 ——
//    与 `t66` 里"播放头必须已删除"同一层级。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 读源码并**剥掉注释**（否则注释里的 `_previewSeek` 会造成假红/假绿）
String _stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  var inLine = false;
  var inBlock = false;
  var inStr = false;
  var strCh = '';
  while (i < src.length) {
    final c = src[i];
    final n = i + 1 < src.length ? src[i + 1] : '';
    if (inLine) {
      if (c == '\n') { inLine = false; out.write(c); }
      i++;
      continue;
    }
    if (inBlock) {
      if (c == '*' && n == '/') { inBlock = false; i += 2; continue; }
      i++;
      continue;
    }
    if (inStr) {
      out.write(c);
      if (c == r'\') { if (n.isNotEmpty) { out.write(n); i += 2; continue; } }
      if (c == strCh) inStr = false;
      i++;
      continue;
    }
    if (c == '/' && n == '/') { inLine = true; i += 2; continue; }
    if (c == '/' && n == '*') { inBlock = true; i += 2; continue; }
    if (c == "'" || c == '"') { inStr = true; strCh = c; out.write(c); i++; continue; }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 取某个顶层方法的**方法体**（按大括号配平）
String _bodyOf(String src, String signature) {
  final i = src.indexOf(signature);
  if (i < 0) return '';
  var j = src.indexOf('{', i);
  if (j < 0) return '';
  var depth = 0;
  final start = j;
  for (; j < src.length; j++) {
    if (src[j] == '{') depth++;
    else if (src[j] == '}') {
      depth--;
      if (depth == 0) return src.substring(start, j + 1);
    }
  }
  return '';
}

void main() {
  final dlgPath =
      'lib${Platform.pathSeparator}ui${Platform.pathSeparator}widgets'
      '${Platform.pathSeparator}skip_marker_dialog.dart';
  final raw = File(dlgPath).readAsStringSync();
  final src = _stripComments(raw);

  group('t461 播放中拖动 ⇒ 必须停住（Owner 第三条）', () {
    test('★★★ `_followPreviewTo` 必须走 `_previewFrame`（会 pause），不得只 seek',
        () {
      final body = _bodyOf(src, 'void _followPreviewTo(SkipEdge e)');
      expect(body, isNotEmpty,
          reason: '★ 找不到 `_followPreviewTo` 的方法体 —— 剥注释器或签名变了');

      expect(
        body.contains('_previewFrame('), isTrue,
        reason: '★★★ `_followPreviewTo` 必须调用 `_previewFrame` —— '
            '它做三件事：退出区间循环（状态重置）+ `pause()`（不继续播）'
            '+ seek（定格到那一帧）。'
            'Owner：「在播放的过程中,拖动调整片头片尾,状态应该重置,'
            '不应该继续播放,应该是变回拖动结束后的那一帧预览」',
      );

      /*
       * ★ 阴性对照：**不得**直接调 `_previewSeek`。
       *   `_previewSeek` 只 seek、不暂停 ⇒ 播放中拖动会"seek 完继续走"。
       *   ⚠️ 注意 `_previewFrame` 内部**会**调 `_previewSeek` ——
       *      所以这里只在 `_followPreviewTo` 的**方法体**里查，
       *      不会误伤。
       */
      expect(
        body.contains('_previewSeek('), isFalse,
        reason: '★★★ `_followPreviewTo` 不得直接调 `_previewSeek` —— '
            '那个**只 seek、不暂停**（见它自己的文档）。'
            '播放中拖动会变成"seek 过去然后继续播"，用户看不到那一帧。',
      );
    });

    test('★★★ `_previewFrame` 必须同时做"退循环 + pause + seek"三件事', () {
      final body = _bodyOf(src, 'Future<void> _previewFrame(num seconds)');
      expect(body, isNotEmpty, reason: '★ 找不到 `_previewFrame` 的方法体');

      // ① 状态重置：退出区间循环
      expect(body.contains('_loopTimer?.cancel()'), isTrue,
          reason: '★★★ 必须 `_loopTimer?.cancel()` —— 否则区间循环会把画面'
              '**拽回区间起点**，用户拖完看到"画面自己跳回去了"');
      // ② 不继续播放
      expect(body.contains('pause()'), isTrue,
          reason: '★★★ 必须 `pause()` —— Owner 要的「不应该继续播放」');
      // ③ 定格到那一帧
      expect(body.contains('_previewSeek('), isTrue,
          reason: '★★★ 必须 seek 到目标 —— Owner 要的「变回拖动结束后的那一帧」');
    });

    test('★★★ 阳性对照：读数行的 `_applyEdge` 也必须走同一条路', () {
      /*
       * ★ 没有这条，只修拖拽而漏掉 +/- 也能绿 ——
       *   而 Owner 说的"拖动调整"包含两条链路。
       *   `_applyEdge` 末尾调 `_followPreviewTo` ⇒ 自动继承修复。
       */
      final body = _bodyOf(src, 'void _applyEdge(int? want, SkipEdge e)');
      expect(body, isNotEmpty, reason: '★ 找不到 `_applyEdge` 的方法体');
      expect(body.contains('_followPreviewTo('), isTrue,
          reason: '★★★ `_applyEdge` 必须调 `_followPreviewTo` —— '
              '两条链路共用同一个跟随实现（否则只改一条会静默漂移）');
    });

    test('★ 剥注释器自检：注释里的 `_previewSeek` 不该被算进来', () {
      /*
       * ★ 没有这条，剥注释器坏掉（比如把注释当代码）会让上面几条**假红**；
       *   反之若它把代码当注释剥掉，会**假绿**。
       *   ⇒ 用"注释里必有的词"验证它真的剥掉了。
       */
      expect(raw.contains('只 seek、不暂停'), isTrue,
          reason: '★ 原文里应当有这句注释（若没有说明我改错了地方）');
      expect(src.contains('只 seek、不暂停'), isFalse,
          reason: '★ 剥注释器失效：注释内容还在 ⇒ 上面的判据不可信');
      // 代码里确实有 `_previewSeek` 的定义（证明剥注释没把代码剥掉）
      expect(src.contains('Future<void> _previewSeek('), isTrue,
          reason: '★ 剥注释器把代码也剥掉了 ⇒ 判据会假绿');
    });
  });
}
