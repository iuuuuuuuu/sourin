// ═══════════════════════════════════════════════════════════════════════
//  直播页 —— 与原版 LiveView.vue 的行为对等回归
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守的是什么
//
// 原版 `D:\WishProject\cctv_to_client\src\views\LiveView.vue`（586 行）
// 的直播页行为，逐条钉死。分两类断言：
//
// ```text
// ① 静态契约（读源码）—— 守「代码里有没有这么写」
// ② 渲染契约（挂载控件）—— 守「用户看不看得见 / 点不点得动」
// ```
//
// ⚠️ **静态断言必须先剥掉注释行再匹配**。
//
// 项目里踩过 3 次「断言匹配到注释文本 → 假通过」。就在本页上还真有
// 一个活例子：`test/search_all_test.dart:192` 断言
//
// ```dart
// livePage.contains('!e.replayable')
// ```
//
// 而 `live_page.dart` 里那句 `!e.replayable` 原本只出现在**块注释**中
// （`原版：:disabled="!e.replayable && !isNow(e)"`）—— 也就是那条
// "只有 replayable 的节目才给点"的测试，当时**根本没在守代码**。
// 本文件所有静态断言统一走 [stripComments]，不再给注释留后门。
//
// # 为什么节目单要单独渲染测试
//
// ★ **更正**（2026-09-25）：这里原来写着「`LivePage` 整页依赖 FFI bridge
// （`SourinApi.getLiveChannels` 走 `SourinCore.callAsync`），
// `flutter test` 里起不来」—— **那句是错的**。
// 实测（另一代理独立验证 + 本文件后续用例）：
// ```text
// mounted_ok=true / looks_like_FFI_failure=false
// ⇒ ★ LivePage **挂得起来**（单独挂 + 在 ShellPage 里挂都行）
// 原因：`loadAll()` 的 FFI 失败**被 catch 了**，不影响建树。
// ```
// ★ 这个区分很关键：它决定了"门控"是**缺口**还是**结构墙**。
// 我当时误判成"起不来"，于是把节目单抽成
// `lib/ui/widgets/epg_panel.dart`（纯数据 → 纯 UI）——
// **那个抽取本身是对的**（三态 + 点击分流能真的渲染验证），
// 但**理由写错了**：不是因为整页起不来，而是因为
// "把可测的 UI 与有副作用的加载逻辑分开"更好测、更清晰。
//
// ═══════════════════════════════════════════════════════════════════════
// ★★★ 2026-09-26 用户要求删除直播页节目单 ⇒ 本节 4 条**翻转为反向断言**
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话（实测反馈第 2 条）：
// ```text
// > 直播删除掉节目单,左侧固定,右侧就一个播放器也固定,还要支持双击进入全屏播放
// ```
//
// ★ 为什么"翻转"而不是"删除"（lead 裁决 + 铁律 169）：
// ```text
// 【错法 1】直接删掉 ⇒ ★ "契约作废"这件事**没被记录** ⇒
//           后人看到 git 历史里曾有 EPG 测试，会以为**功能丢了**
// 【错法 2】放宽断言 ⇒ 违反"不许放宽"的纪律
// 【本法】正向 ⇒ 反向（"不应再有 X"）+ 写明作废理由
//          ⇒ ① 留下决策痕迹 ② **防止有人改回来** ③ 不放宽
// ```
//
// 被翻转的 4 条（详见各条注释内的"★ 2026-09-26 翻转"段）：
// ```text
// · 原 L359「EPG 拉取失败不算错误」    ⇒ 直播页**不再请求** EPG
// · 原 L457「节目单抽到 epg_panel 并用上」⇒ 直播页**不再 import** epg_panel
// · 原 L822「页头跟着 epg 有没有数据走」 ⇒ 页头**恒不显示**节目单提示
// · 原 L831「没选中时节目单照样渲染」    ⇒ 直播页**不再构造** EPG 容器
// ```
//
// ⚠️ **`epg_panel.dart` 自身的渲染测试全部保留** ——
//    那些测的是**组件本身**（三态 / 点击分流 / 进度条），与直播页无关，
//    ★ 组件没被删除，所以它的契约**依然有效**。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/widgets/epg_panel.dart';

// ═══════════════════════════════════════════════════════════════════════
//  工具
// ═══════════════════════════════════════════════════════════════════════

/// 剥掉注释（`//` 行注释 **和** `/* */` 块注释）
///
/// ⚠️ 这是本文件所有静态断言的前提 —— 见文件头说明。
///
/// # 为什么用状态机而不是正则
///
/// 要区分三种情况：
/// ```text
/// 'http://x'     字符串里的 `//` **不是**注释
/// "a /* b"       字符串里的 `/*` 不是注释
/// /*  //  */     块注释里的 `//` 不是行注释
/// ```
/// 正则做不到（需要记忆状态）。所以走一遍字符。
/// （与 `test/episode_strip_test.dart` 的实现一致 —— 那边也是被同一个
///  假通过坑过之后写的。）
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote; // 当前是否在字符串里（记录引号字符）

  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';

    // ── 在字符串里：原样保留，只找结束引号 ──
    if (quote != null) {
      if (c == r'\') {
        out.write(c);
        if (next.isNotEmpty) {
          out.write(next);
          i += 2;
          continue;
        }
      }
      if (c == quote) quote = null;
      out.write(c);
      i++;
      continue;
    }

    // ── 不在字符串里 ──
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && next == '/') {
      // 行注释：跳到行尾（保留换行，行号不变）
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && next == '*') {
      // 块注释：跳到 */
      i += 2;
      while (i < src.length &&
          !(src[i] == '*' && i + 1 < src.length && src[i + 1] == '/')) {
        if (src[i] == '\n') out.write('\n'); // 保留换行，行号才对得上
        i++;
      }
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 把控件套进真实的壳（forui 主题 + material_ui 的 MaterialApp）
///
/// ⚠️ 与 `shell.dart` 同款：`FTheme` 在 `builder` 里。
///    必须用 `material_ui` 的 `MaterialApp` —— 用 `flutter/material`
///    会拿到 `ThemeData.fallback()`（亮色），测试环境和生产不一致。
///
/// ⚠️ `Scaffold` 在这里是**故意的**：它提供 `Material` 祖先。
///    生产环境的 `FScaffold` **不提供**（见 `material_ancestor_test.dart`
///    记录的遥控器确认键失效 bug）—— shell.dart 已经补了一层
///    `Material(type: transparency)`。这里断言的是 EpgPanel 自身的
///    行为，不重复测那一层。
Widget _host(Widget child) {
  final theme = FTheme.neutral.dark.desktop;
  return MaterialApp(
    theme: theme.toApproximateMaterialTheme(),
    builder: (_, c) => FTheme(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: child),
  );
}

/// 固定的「当前时间」—— 不依赖真实时钟，边界才稳定
const int kNow = 1700000000;

/// 造一条 EPG
EpgEntry _epg(
  String title, {
  required int start,
  required int end,
  bool replayable = false,
  String? showTime,
}) =>
    EpgEntry(
      title: title,
      start: start,
      end: end,
      replayable: replayable,
      showTime: showTime,
    );

/// 三条典型节目：已播完可回看 / 正在播 / 已播完不可回看
///
/// 正好覆盖原版 `.epg-item` 的三种状态（含 `:disabled` 那条）。
List<EpgEntry> _three() => [
      _epg('可回看的节目',
          start: kNow - 7200, end: kNow - 3600, replayable: true),
      _epg('正在播的节目', start: kNow - 900, end: kNow + 900),
      _epg('不可回看的节目',
          start: kNow - 10800, end: kNow - 7200, replayable: false),
    ];

/// 时间列故意做成一眼能认出来的形式，用来断言"用的是哪个来源"
String _fmtStub(int ts) => '@$ts';

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 静态契约：与原版逐条对齐（**先剥注释**）
  // ═══════════════════════════════════════════════════════════════════

  group('① 静态契约（剥注释后匹配，避免假通过）', () {
    late String liveRaw; // 原始（含注释）—— 只有"禁止出现某字符串"才用它
    late String live; // 剥注释后的**代码**
    late String epgRaw; // epg_panel.dart 原始（含注释）
    late String epgCode; // epg_panel.dart 剥注释后的代码

    setUpAll(() {
      liveRaw = File('lib/ui/live_page.dart').readAsStringSync();
      live = stripComments(liveRaw);
      epgRaw = File('lib/ui/widgets/epg_panel.dart').readAsStringSync();
      epgCode = stripComments(epgRaw);
    });

    /*
     * ★★★ 2026-09-26 探针更换（不是翻转 —— 这条是**元测试**）
     *
     * 【原样】它用 `!e.replayable` 当**探针**：断言
     *   ① 原始文件（含注释）里有它
     *   ② `stripComments` 之后**仍然**有它
     *   ⇒ 合起来证明「剥注释**没有误删真代码**」。
     *
     * 【为什么必须换探针】**用户 2026-09-26 要求删掉直播页节目单** ⇒
     *   `!e.replayable`（回看守卫）**代码与注释里都没有了**
     *   （它原来只出现在注释抄的原版 CSS 说明里）⇒ 探针**失去对象**。
     *
     * ⚠️ **不能翻转它** —— 翻转会变成"剥注释后**不该**有它"，
     *    那是**错误的语义**：这条测试本来要证明的是
     *    「**真代码被保留了**」，不是「某串不该存在」。
     *    ★ 翻转一条元测试 = 把它变成一条测别的东西的测试。
     *
     * 【新探针】`cycleChannel` —— 满足探针的两个条件：
     *   · 注释里有（文档里多处提到它）
     *   · 代码里也有（`void cycleChannel(int delta)` 与两个调用点）
     *   ⇒ ★ 且它是本页**核心功能**（上下键切台），语义上最适合当"真代码"的代表。
     */
    test('★ 剥注释这件事本身有效（否则下面全是假通过）', () {
      /*
       * 反向验证：注释里**确实**有 `cycleChannel`（本页多处文档提到它），
       * 剥完必须**仍然**有（因为代码里也有）。
       * 如果这条挂了，说明 stripComments 要么没生效、要么**误删了代码** ——
       * 那下面的断言一个都不能信。
       */
      expect(
        liveRaw.contains('cycleChannel'),
        isTrue,
        reason: '前置条件：原文件（含注释）里应该有这个串',
      );
      expect(
        live.contains('cycleChannel'),
        isTrue,
        reason: '★ 剥注释后**仍然**要有 —— 因为 `void cycleChannel(int delta)` '
            '是真代码（本页 ↑/↓ 切台的实现）。'
            '★ 若这条挂了：stripComments 把真代码也删了 ⇒ 下面全是假通过。'
            '（原探针 `!e.replayable` 已在 2026-09-26 随节目单删除而失效，'
            '故换成 `cycleChannel`）',
      );
    });

    test('★★ 这些串**只在注释里**存在 —— 拿它们做断言就是假通过', () {
      /*
       * 项目里踩过 3 次「断言匹配到注释文本 → 假通过」。
       * 本条把本页里所有**只在注释中出现**的串钉出来：
       *
       * ```text
       * 若有人（包括我自己）用 `src.contains('max-height: 420px')` 之类
       * 去断言"节目单内部有滚动"，那条测试**永远不会失败** ——
       * 因为原版 CSS 被抄进了注释里，代码删光它都还在。
       * ```
       *
       * ⚠️ 这是一条**活的反例清单**，不是形式主义：
       *    `search_all_test.dart:192` 就是现成的受害者 ——
       *    它断言 `livePage.contains('!e.replayable')`，
       *    而在我改之前那句只出现在块注释里（`原版：:disabled=...`）。
       *
       * 每条都要：原始文件里有（说明注释确实抄了原版）
       *        + 剥注释后没有（说明代码里**没有**这个行为）。
       */
      final commentOnly = <String, String>{
        // 来自 epg_panel.dart 里抄的原版 CSS / 模板
        ':disabled=': 'epg_panel.dart 里只有注释提到原版的 :disabled',
        'chip--live': 'epg_panel.dart 里只有注释提到原版的 chip--live',
        'epg-item__bar': 'epg_panel.dart 里只有注释提到原版的进度条类名',
        'max-height: 420px': '★ 节目单**故意不做**内部滚动 —— '
            '若有人拿这个串断言"有内层滚动"，会永远通过',
        'overflow-y: auto': '同上',
        'isNow(e) ? watchLive': 'epg_panel.dart 里只有注释抄了原版三元表达式',
        '@click=': 'epg_panel.dart 里只有注释抄了原版模板',
        // 来自 live_page.dart
        'v-if="epg.length"': 'live_page.dart 里只有注释抄了原版模板条件',
        /*
         * ★★★ 2026-09-26 换 entry（原为 `console.warn`）
         *
         * ```text
         * 【原 entry】'console.warn': 'live_page.dart 里只有注释提到原版的 console.warn'
         * 【为什么失效】用户要求删直播页节目单 ⇒ 我删 EPG 时把那段注释**一起清了**
         *   ⇒ 实测 `live_page.dart` 里 `console.warn` = **0 次**（注释与代码都没有）
         *   ⇒ ★ **前置条件失败**（`inRaw` 为 false）⇒ 全量里这 1 条红
         *
         * ★ 这是**元测试正确报警**，不是回归：
         *   这条测试同时断言 ① 前置条件（串在注释里）② 反向（剥注释后不在）。
         *   ★ 若它**只有** ② ⇒ 删掉注释后它**会静默通过**（"不该有"确实成立）
         *     ⇒ **空断言**。
         *   ⇒ ★★ 而 ① 正是**防空断言的那一半** —— 它现在正确地报了红
         *     （铁律 149：候选集必须断言非空）。
         *
         * 【新 entry】`watchReplay` —— 严格满足本表的**双条件**：
         *   ① 注释里有：`// 同理 \`timeshift\`：原版 \`watchReplay\` **不带时间区间**`
         *   ② 代码里没有：`_watchReplay` 已随节目单删除 ⇒ 真代码里不存在
         *   ⇒ ★ 语义与原 entry **完全同类**：都是"原版有、我们代码里没有"
         *     （`console.warn` 是原版的告警调用，`watchReplay` 是原版的回看入口）
         * ```
         * ⚠️ **不是翻转**（铁律 169 在这里不适用）：翻转会把它变成
         *    "剥注释后**不该**在" —— 那是**错的语义**，
         *    因为本表要证明的是"**注释里抄了原版**"，不是"某串不该存在"。
         */
        'watchReplay': 'live_page.dart 里只有注释提到原版的 watchReplay'
            '（2026-09-26 换：原 entry `console.warn` 随删 EPG 一并消失）',
      };

      for (final e in commentOnly.entries) {
        final inRaw = liveRaw.contains(e.key) || epgRaw.contains(e.key);
        final inCode = live.contains(e.key) || epgCode.contains(e.key);
        expect(
          inRaw,
          isTrue,
          reason: '前置条件：`${e.key}` 应该出现在注释里（${e.value}）',
        );
        expect(
          inCode,
          isFalse,
          reason: '★★ `「${e.key}」` 剥注释后**不该**存在。'
              '${e.value}。'
              '如果这条挂了：要么代码里真的加了这个行为（那要看是不是'
              '擅自改了交互），要么 stripComments 漏剥了 —— 两种都要查。',
        );
      }
    });

    test('★ 禁止 import package:flutter/material.dart（两套 Theme 串台）', () {
      /*
       * Flutter 3.47 把 material 拆到了 `material_ui` 包。
       * 混用会拿到两套 ThemeData → 实测对比度只剩 1.16:1。
       */
      for (final e in {
        'lib/ui/live_page.dart': live,
        'lib/ui/widgets/epg_panel.dart': epgCode,
      }.entries) {
        expect(
          e.value.contains("package:flutter/material.dart"),
          isFalse,
          reason: '${e.key} 必须用 material_ui —— 见项目铁律',
        );
        expect(
          e.value.contains("package:material_ui/material_ui.dart"),
          isTrue,
          reason: '${e.key} 要 import material_ui',
        );
      }
    });

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-09-26 翻转（正向 ⇒ 反向）：回看链路随节目单一起移除
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话（实测反馈第 2 条）：
     * > 直播删除掉节目单,左侧固定,右侧就一个播放器也固定,还要支持双击进入全屏播放
     *
     * ```text
     * ★ 为什么回看链路一并消失（必然，不是我做错了）：
     *   回看入口**物理上就在节目单里** —— `EpgPanel.onWatchReplay` 回调
     *   ⇒ 删节目单 ⇒ 没有东西能触发回看 ⇒ `_watchReplay` / `_fmtTime`
     *     / 以及它拼的 `title` / `episodeTitle` **全部失去调用点**
     * ⇒ 所以下面 4 条原来守的"回看行为"**对象已不存在**
     *
     * ★ 处置（lead 裁决，铁律 169）：
     *   · 正向 ⇒ **反向**（"不应再有 X"）+ 写明作废理由
     *   · ★ 收益：① 留下决策痕迹 ② **防止有人改回来** ③ 不放宽断言
     *
     * ⚠️ **能力本身仍在**：`SourinApi.getTimeshift` **未动**
     *   （下面另有一条正向断言证明它还在），`LivePage.onWatchReplay`
     *   构造参数也**保留**（shell 仍传）⇒ 将来要恢复回看是**零改动接回**。
     * ```
     */
    test('★ 直播页**不再**有回看入口（用户 2026-09-26 要求删节目单）', () {
      expect(
        live.contains('_watchReplay'),
        isFalse,
        reason: '★ 回看入口随节目单移除。若它又出现在**代码**里，'
            '说明有人把回看加回来了 —— 那是回归（用户没要求恢复）。'
            '★ 注意：本断言走 stripComments ⇒ 注释里提到它**不算**。',
      );
    });

    test('★ 直播页**不得**调 getTimeshift（原判据保留，仍有效）', () {
      /*
       * ★ 这条**不是翻转** —— 它原本就是"不该有"，且**理由依然成立**：
       *   原版自己也没接 `timeshift`（`src/api/index.ts:649` 定义了但全仓无调用点），
       *   接了就是**新增功能**，要改播放器入口契约 ⇒ 需先问用户。
       *   ★ 而用户这次**只说了删节目单**，没说恢复回看 ⇒ 判据不变。
       * ⚠️ 用 `liveRaw`（含注释）匹配：连注释里提一嘴都不行 ——
       *   否则将来有人"顺手接上"时注释会先泄题。
       */
      expect(
        liveRaw.contains('getTimeshift'),
        isFalse,
        reason: '★ 直播页**不得**调 getTimeshift —— 原版自己也没接。'
            '注意这条用**原始文件**匹配：连注释里提一嘴都不行，'
            '否则将来有人"顺手接上"时注释会先泄题。',
      );
    });

    test('★ 直播页**不再**拼回看的 episodeTitle（对象已不存在）', () {
      /*
       * ★★★ 2026-09-26 翻转
       * 【原断言】`episodeTitle` 要带时间前缀「HH:mm 节目名」——
       *   原版 `${fmtTime(e.start)} ${e.title}`，用于播放器显示"你在看哪一段"。
       * 【为什么作废】回看入口没了 ⇒ 那个拼接**没有调用点**
       *   （其依赖 `_fmtTime` 已随之删除）。
       * 【新契约】不应再出现该拼接。
       */
      expect(
        RegExp(r"'\$\{_fmtTime\(e\.start\)\} \$\{e\.title\}'").hasMatch(live),
        isFalse,
        reason: '★ 回看入口移除 ⇒ 该 episodeTitle 拼接一并消失（含 `_fmtTime`）',
      );
      expect(
        live.contains('_fmtTime'),
        isFalse,
        reason: '★ `_fmtTime` 只服务节目单/回看标题 ⇒ 应一并移除',
      );
    });

    test('★ 直播页**不再**拼回看的 title（对象已不存在）', () {
      /*
       * ★★★ 2026-09-26 翻转
       * 【原断言】回看标题是「频道名 · 节目名」
       *   （原版 `title: \`${selected.value.name} · ${e.title}\``）。
       * 【为什么作废】同上 —— 该拼接只在 `_watchReplay` 里，已随入口删除。
       * 【新契约】不应再出现该拼接。
       */
      expect(
        live.contains("'\${s.name} · \${e.title}'"),
        isFalse,
        reason: r'★ 原版 title 模板随回看入口移除而消失',
      );
    });

    test('★ 直播页**不再**有 replayable 守卫（对象已不存在）', () {
      /*
       * ★★★ 2026-09-26 翻转
       * 【原断言】`if (s == null || !e.replayable) return;` 必须在
       *   （原版 `LiveView.vue:134`：`if (!selected.value || !e.replayable) return;`）。
       * 【为什么作废】`replayable` 是**节目单条目**（`EpgEntry`）的字段 ⇒
       *   节目单删除后本页不再接触它，该守卫**没有对象**。
       * 【新契约】不应再出现该守卫或 `replayable`。
       */
      expect(
        RegExp(r'if \(s == null \|\| !e\.replayable\) return;').hasMatch(live),
        isFalse,
        reason: '★ 节目单移除 ⇒ "这条节目可否回看"的守卫没有对象了',
      );
      expect(
        live.contains('replayable'),
        isFalse,
        reason: '★ `EpgEntry` 相关字段整体不该再出现在直播页',
      );
    });

    /*
     * ★★★ 2026-09-26 翻转（正向 ⇒ 反向）
     *
     * 【原断言】`live.contains('该频道暂无节目单')` = true
     *   —— 守"EPG 拉取失败只 warn，不报错"。
     * 【为什么作废】用户要求「直播删除掉节目单」⇒
     *   直播页**不再请求 EPG** ⇒ 那句 catch/warn **连同取数一起删掉了**
     *   （不只是不显示 —— 连 IPC 都不发，见 `_select` 的实现注释）。
     * 【新契约】直播页**不应**再出现任何 EPG 取数痕迹。
     *   ★ 反向断言的额外价值：**防止有人改回来**（回归护栏）。
     */
    test('★ 直播页**不再请求** EPG（用户 2026-09-26 要求删节目单）', () {
      expect(
        live.contains('该频道暂无节目单'),
        isFalse,
        reason: '★ 2026-09-26 用户要求删除节目单 ⇒ 取数连同那段 warn 一起删除。'
            '若它又出现，说明有人把 EPG 取数加回来了 —— 那是回归。',
      );
      expect(
        live.contains('getEpg'),
        isFalse,
        reason: '★ 直播页**不该**再发 EPG 请求（切台只取流）。'
            '★ 顺带为本页的"卡顿"贡献：少一次每台必发的 IPC + 插件 JS 执行',
      );
      expect(
        live.contains('EpgEntry'),
        isFalse,
        reason: '★ EPG 数据模型也不该再出现在直播页（状态已整体移除）',
      );
    });

    test('★ 返回本页保留选中的频道（原版 loadAll(true)）', () {
      /*
       * 原版 `LiveView.vue:39 loadAll(keepSelection = false)` +
       * `:73 onActivated(() => loadAll(true))`。
       *
       * 原版注释（L46-51）：
       * > 不能无脑「默认选中第一个频道」—— 用户切走又切回时，
       * > 那样会把他在看的台**重置成第一个**，是很明显的体验倒退。
       */
      expect(
        RegExp(r'Future<void> loadAll\(\{bool keepSelection = false\}\)')
            .hasMatch(live),
        isTrue,
        reason: '★ 签名必须保留 `keepSelection` —— shell.dart 靠它调 '
            '`loadAll(keepSelection: true)`',
      );
      expect(
        live.contains('final prevId = keepSelection ? _selected?.id : null;'),
        isTrue,
        reason: '保留选中 = 先记住旧 id，再从新列表里找回',
      );
      expect(
        live.contains('final restored = prevId != null'),
        isTrue,
        reason: '原版 `const restored = prevId ? all.find(...) : undefined`',
      );
      expect(
        live.contains('final target = restored ??'),
        isTrue,
        reason: '★ 找回优先于"第一个" —— 顺序反了就等于没保留',
      );
    });

    /*
     * ★★★ 2026-09-26 翻转（正向 ⇒ 反向）
     *
     * 【原断言】`Duration(seconds: 30)` 与 `_clock?.cancel()` 必须在
     *   —— 守"「当前节目」高亮每 30 秒推进"（原版 `LiveView.vue:32`）。
     * 【为什么作废】那个定时器**只服务节目单的「当前节目」高亮** ⇒
     *   节目单删除后它没有任何读取者。
     *
     * ★★ 而**删它的真实原因不只是"服务节目单"**（这点必须写准）：
     * ```text
     * 它每 30 秒调一次 `setState` ⇒ **整页重建**。
     * 而用户第 8 条正是问"直播好像有点卡顿,能优化优化吗?"
     * ⇒ ★ 一个**每 30 秒整页重建**的定时器，在没有 UI 读它之后
     *   就是**纯粹的负担** ⇒ 删掉它对"卡顿"是**正贡献**。
     * ```
     * 【新契约】不应再有任何周期性 `setState` 定时器。
     */
    test('★ 直播页**不再**有周期性重建定时器（用户 2026-09-26 要求删节目单）', () {
      expect(
        live.contains('Duration(seconds: 30)'),
        isFalse,
        reason: '★ 那个 30 秒计时器只服务"当前节目"高亮 ⇒ 节目单删除后'
            '没有读取者。★ 而它每 30 秒 `setState` 一次（整页重建）—— '
            '删掉它对用户第 8 条问的"直播卡顿"是**正贡献**。',
      );
      expect(
        live.contains('_clock'),
        isFalse,
        reason: '★ `_clock` 与其 `dispose` 里的 `cancel()` 一并移除'
            '（留着就是死代码；且"Timer 未取消"的风险也随之消失）',
      );
    });

    test('★ 窄屏断点是 900px（原版 @media max-width: 900px）', () {
      expect(
        live.contains('size.width < 900'),
        isTrue,
        reason: '原版 `LiveView.vue:288 @media (max-width: 900px)`',
      );
    });

    test('★ 加载态是**两栏骨架**，不是居中转圈（原版 L162-165）', () {
      /*
       * 原版：
       * ```html
       * <div v-if="loading" class="live-layout">
       *   <div class="skeleton" style="height: 400px" />
       *   <div class="skeleton" style="height: 400px" />
       * </div>
       * ```
       * 转圈 → 两栏的**布局跳动**很明显（从"居中一个小圆"突然变成
       * 左 268px + 右自适应），骨架能消掉它。
       */
      expect(
        live.contains('_PanelSkeleton'),
        isTrue,
        reason: '原版加载态是骨架块',
      );
      expect(
        live.contains('CircularProgressIndicator'),
        isFalse,
        reason: '★ 直播页加载态**不该**再有转圈 —— 原版是两栏骨架',
      );
      // 两块：左频道列表 + 右节目单（窄屏是上下两块）
      expect(
        RegExp(r'_PanelSkeleton\(\)').allMatches(live).length,
        greaterThanOrEqualTo(4),
        reason: '宽屏两块 + 窄屏两块（同一条加载分支里的两个布局）',
      );
    });

    /*
     * ★★★ 2026-09-26 翻转（正向 ⇒ 反向）
     *
     * 【原断言】`live.contains('EpgPanel(')` = true +
     *   `live.contains("import 'widgets/epg_panel.dart';")` = true
     *   —— 守"节目单抽出去后必须接回来"。
     * 【为什么作废】用户要求删掉直播页的节目单 ⇒ 本页**不再引用**该组件。
     * 【新契约】直播页**不得**再 import/构造 `EpgPanel`。
     *   ★ 反向断言的额外价值：**防止有人改回来**。
     *
     * ⚠️ **`epg_panel.dart` 自身的测试全部保留**（下面的"② 节目单三态"整组）——
     *    那些测的是**组件本身**（三态 / 点击分流 / 进度条），与直播页无关。
     *    ★ 组件**没有**被删除，所以它的契约**依然有效** ——
     *      删掉它们会真的丢掉测试覆盖（那是另一种错误）。
     */
    test('★ 直播页**不再**引用 epg_panel（用户 2026-09-26 要求删节目单）', () {
      expect(
        live.contains('EpgPanel('),
        isFalse,
        reason: '★ 2026-09-26 用户要求删除节目单 ⇒ 本页不再构造 EpgPanel。'
            '若它又出现，说明有人把节目单加回来了 —— 那是回归。',
      );
      expect(
        live.contains("import 'widgets/epg_panel.dart';"),
        isFalse,
        reason: '★ 本页不该再 import 它（组件文件本身保留，供别的页面使用）',
      );
      expect(
        live.contains("import 'widgets/collapsible_epg.dart';"),
        isFalse,
        reason: '★ 折叠容器同理 —— 它是为"节目单可折叠"服务的，一并移除',
      );
      /*
       * ★★ 反向断言的**边界**（必须说清，否则这条测试会被误读成"组件被删了"）：
       *   · 断言的是**本页不再引用**，不是"组件不存在"
       *   · 下面整组「② 节目单三态」仍然在测组件本身 ⇒ 组件**必须存在**
       */
      expect(
        File('lib/ui/widgets/epg_panel.dart').existsSync(),
        isTrue,
        reason: '★ 组件文件**必须保留** —— 本页不用了，但它的渲染测试还在跑，'
            '而且别的页面可能仍在使用它（删除它是另一个决策，不在本次范围）',
      );
    });

    test('★ 直播页**不读** capabilities（原版也没读 —— 数据驱动）', () {
      /*
       * 原版 `LiveView.vue:5` 的注释写着「能力位驱动：Provider 声明
       * capabilities.epg / timeshift 才显示对应功能」，
       * 但**整个文件里没有任何一处读 `capabilities`**（全仓 grep 证实：
       * 只有 SettingsView.vue 有 9 处，直播页 0 处）。
       *
       * 原版真正的判据是数据驱动的：
       * ```ts
       * epg.value = await liveApi.epg(activeProvider.value, ch.id);
       * ```
       * 有数据就显示，没有就「暂无节目单」。
       *
       * ⚠️ 这条测试的意义是**防止将来有人照字面加** `caps.epg` 判断 ——
       *    在只声明 `live: true` 的源上，那会**多出**一块原版没有的
       *    「暂无节目单」区域，属于改变交互。
       */
      for (final e in {
        'lib/ui/live_page.dart': live,
        'lib/ui/widgets/epg_panel.dart': epgCode,
      }.entries) {
        expect(
          e.value.contains('capabilities'),
          isFalse,
          reason: '${e.key}：原版直播页没有能力位判断，'
              '加了会改变交互（详见 live_page.dart 文件头）',
        );
        // 顺带：旧字段名（后端从不发送）一个都不许出现
        for (final dead in ['c.login', 'c.rank', 'c.category', 'platformHistory']) {
          expect(
            e.value.contains(dead),
            isFalse,
            reason: '${e.key}：`$dead` 是 Capabilities 修复前的旧字段名，'
                '后端从不下发这些键',
          );
        }
      }
    });

    test('★ 节目单列表**不做**内部滚动（唯一一处有意的交互差异）', () {
      /*
       * 原版 `.epg__list { max-height: 420px; overflow-y: auto; }` ——
       * 节目单自己一条滚动轴，页面外层还有一条 → **两条嵌套**。
       *
       * 1280x800 下 420px 只装得下约 7 条，而一天的节目单常有三四十条，
       * 内层滚动条是必然出现的。所以这里让列表随内容撑开，
       * 只保留页面主滚动轴。
       *
       * ⚠️ 这是本页**唯一**一处与原版不同的交互选择，
       *    已在交付报告里单列。
       */
      expect(
        epgCode.contains('SingleChildScrollView'),
        isFalse,
        reason: '★ 节目单里不该有第二条第滚动轴',
      );
      expect(
        epgCode.contains('ListView'),
        isFalse,
        reason: '★ 同上 —— 用 Column 随内容撑开',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 渲染契约：节目单三态
  // ═══════════════════════════════════════════════════════════════════

  group('② 节目单三态（真的渲染出来看）', () {
    testWidgets('加载中 → 6 块骨架，不显示"暂无节目单"', (t) async {
      await t.pumpWidget(_host(EpgPanel(
        epg: const [],
        epgLoading: true,
        now: kNow,
        fmtTime: _fmtStub,
        onWatchLive: () {},
        onWatchReplay: (_) {},
      )));
      await t.pumpAndSettle();

      // 标题一直在（原版 `.epg__head` 不在任何 v-if 里）
      expect(find.text('节目单'), findsOneWidget);

      // 骨架：6 块高 52 的 Container（原版 `v-for="i in 6"`）
      final boxes = t.widgetList<Container>(find.byType(Container)).where((c) {
        final d = c.constraints;
        return d != null && d.maxHeight == 52 && d.minHeight == 52;
      });
      expect(
        boxes.length,
        6,
        reason: '原版 `LiveView.vue:244`：`v-for="i in 6"` 六块骨架',
      );

      // 加载中不能同时显示空态 —— 三态必须互斥
      expect(
        find.text('暂无节目单'),
        findsNothing,
        reason: '★ 三态互斥：v-if / v-else-if / v-else，不能同时出现',
      );
    });

    testWidgets('拉取失败/没有数据 → 空态（原版 EmptyState）', (t) async {
      await t.pumpWidget(_host(EpgPanel(
        epg: const [],
        epgLoading: false,
        now: kNow,
        fmtTime: _fmtStub,
        onWatchLive: () {},
        onWatchReplay: (_) {},
      )));
      await t.pumpAndSettle();

      expect(find.text('节目单'), findsOneWidget);
      expect(find.text('暂无节目单'), findsOneWidget);
      expect(
        find.text('该频道未提供 EPG 数据'),
        findsOneWidget,
        reason: '原版 EmptyState 的 desc',
      );
      // 骨架不该还在
      final boxes = t.widgetList<Container>(find.byType(Container)).where((c) {
        final d = c.constraints;
        return d != null && d.maxHeight == 52 && d.minHeight == 52;
      });
      expect(boxes.length, 0, reason: '★ 三态互斥：空态时不该有骨架');
    });

    testWidgets('有数据 → 每条节目都渲染，标题可读', (t) async {
      final epg = _three();
      await t.pumpWidget(_host(EpgPanel(
        epg: epg,
        epgLoading: false,
        now: kNow,
        fmtTime: _fmtStub,
        onWatchLive: () {},
        onWatchReplay: (_) {},
      )));
      await t.pumpAndSettle();

      for (final e in epg) {
        expect(find.text(e.title), findsOneWidget, reason: '节目「${e.title}」要显示');
      }
      expect(find.text('暂无节目单'), findsNothing, reason: '★ 三态互斥');
    });

    testWidgets('★ 徽章：正在播 → 「直播中」；可回看 → 「回看」', (t) async {
      await t.pumpWidget(_host(EpgPanel(
        epg: _three(),
        epgLoading: false,
        now: kNow,
        fmtTime: _fmtStub,
        onWatchLive: () {},
        onWatchReplay: (_) {},
      )));
      await t.pumpAndSettle();

      // 原版：`v-if="isNow(e)"` → chip--live「直播中」；`v-else-if="e.replayable"` → 「回看」
      expect(find.text('直播中'), findsOneWidget);
      expect(
        find.text('回看'),
        findsOneWidget,
        reason: '只有第一条 replayable —— 不可回看那条**不能**有「回看」徽章',
      );
    });

    testWidgets('★ 进度条只在「正在播」那条上（原版 v-if="isNow(e)"）', (t) async {
      await t.pumpWidget(_host(EpgPanel(
        epg: _three(),
        epgLoading: false,
        now: kNow,
        fmtTime: _fmtStub,
        onWatchLive: () {},
        onWatchReplay: (_) {},
      )));
      await t.pumpAndSettle();

      final bars = t.widgetList<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bars.length, 1, reason: '★ 只有正在播的那条有进度条');
      // 播了一半：900/1800 = 50%
      expect(
        bars.first.value,
        closeTo(0.5, 0.01),
        reason: '原版 `progressOf` = (now-start)/(end-start)',
      );
    });

    testWidgets('★ 时间列：有 showTime 就用它，否则用 fmtTime(start)', (t) async {
      await t.pumpWidget(_host(EpgPanel(
        epg: [
          _epg('带 show_time 的',
              start: kNow - 7200,
              end: kNow - 3600,
              replayable: true,
              showTime: '08:30'),
          _epg('不带的', start: kNow - 10800, end: kNow - 7200, replayable: true),
        ],
        epgLoading: false,
        now: kNow,
        fmtTime: _fmtStub,
        onWatchLive: () {},
        onWatchReplay: (_) {},
      )));
      await t.pumpAndSettle();

      expect(
        find.text('08:30'),
        findsOneWidget,
        reason: '`EpgEntry.showTime` 是契约里真实存在的字段'
            '（`src/api/types.ts:169 show_time?: string`），有就用',
      );
      expect(
        find.text('@${kNow - 10800}'),
        findsOneWidget,
        reason: '没有 showTime 时回落到 fmtTime(start) —— 与原版一致',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 渲染契约：点击分流（原版三元表达式）
  // ═══════════════════════════════════════════════════════════════════

  group('③ 点击分流 —— 与原版 `isNow(e) ? watchLive() : watchReplay(e)` 一致', () {
    testWidgets('★ 点「正在播」那条 → 看直播（**不是**回看）', (t) async {
      var live = 0;
      final replayed = <String>[];

      await t.pumpWidget(_host(EpgPanel(
        epg: _three(),
        epgLoading: false,
        now: kNow,
        fmtTime: _fmtStub,
        onWatchLive: () => live++,
        onWatchReplay: (e) => replayed.add(e.title),
      )));
      await t.pumpAndSettle();

      await t.tap(find.text('正在播的节目'));
      await t.pumpAndSettle();

      expect(live, 1, reason: '原版：`isNow(e) ? watchLive() : …`');
      expect(
        replayed,
        isEmpty,
        reason: '★ 正在播的节目**不能**走回看 —— 原版三元表达式的左边分支',
      );
    });

    testWidgets('★ 点「可回看」那条 → 回看，且回调拿到的是**那一条**', (t) async {
      var live = 0;
      final replayed = <String>[];

      await t.pumpWidget(_host(EpgPanel(
        epg: _three(),
        epgLoading: false,
        now: kNow,
        fmtTime: _fmtStub,
        onWatchLive: () => live++,
        onWatchReplay: (e) => replayed.add(e.title),
      )));
      await t.pumpAndSettle();

      await t.tap(find.text('可回看的节目'));
      await t.pumpAndSettle();

      expect(live, 0, reason: '★ 回看**不能**走 watchLive');
      expect(replayed, ['可回看的节目'], reason: '回调必须拿到被点的那一条');
    });

    testWidgets('★★ 不可回看且不是正在播 → 禁用（原版 :disabled）', (t) async {
      var live = 0;
      final replayed = <String>[];

      await t.pumpWidget(_host(EpgPanel(
        epg: _three(),
        epgLoading: false,
        now: kNow,
        fmtTime: _fmtStub,
        onWatchLive: () => live++,
        onWatchReplay: (e) => replayed.add(e.title),
      )));
      await t.pumpAndSettle();

      // 直接断言 InkWell 的 onTap 是 null（比"点一下看有没有反应"更强）
      final ink = t.widget<InkWell>(
        find.ancestor(
          of: find.text('不可回看的节目'),
          matching: find.byType(InkWell),
        ),
      );
      expect(
        ink.onTap,
        isNull,
        reason: '原版 `:disabled="!e.replayable && !isNow(e)"` —— '
            '源不提供回看流，点了只会报错，不如直接禁掉',
      );

      // 再真的点一下，确认两个回调都不会被调
      await t.tap(find.text('不可回看的节目'), warnIfMissed: false);
      await t.pumpAndSettle();
      expect(live, 0);
      expect(replayed, isEmpty);
    });

    testWidgets('★ 没有选中频道时（onWatchLive == null）点「正在播」不炸', (t) async {
      /*
       * 原版 `LiveView.vue:122`：`function watchLive() { if (!selected.value) return; }`
       * 页面层把 `onWatchLive` 传成 null（见 live_page.dart 里
       * `onWatchLive: _selected == null ? null : _watchLive`）。
       */
      final replayed = <String>[];

      await t.pumpWidget(_host(EpgPanel(
        epg: _three(),
        epgLoading: false,
        now: kNow,
        fmtTime: _fmtStub,
        onWatchLive: null, // ← 没选中频道
        onWatchReplay: (e) => replayed.add(e.title),
      )));
      await t.pumpAndSettle();

      await t.tap(find.text('正在播的节目'), warnIfMissed: false);
      await t.pumpAndSettle();

      expect(replayed, isEmpty, reason: '★ 不能"降级"成回看 —— 那是原版没有的行为');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 页面级静态契约：数据驱动的可见性
  // ═══════════════════════════════════════════════════════════════════

  group('④ 页面可见性由数据决定（不是能力位）', () {
    late String live;

    setUpAll(() {
      live = stripComments(File('lib/ui/live_page.dart').readAsStringSync());
    });

    test('★ 没有频道 → 空态「没有可用的直播源」', () {
      expect(live.contains('没有可用的直播源'), isTrue);
      expect(
        live.contains('在设置中启用一个支持直播的内容源'),
        isTrue,
        reason: '原版 EmptyState 的 desc（`LiveView.vue:171`）',
      );
    });

    /*
     * ★★★ 2026-09-26 翻转（正向 ⇒ 反向）
     *
     * 【原断言】`live.contains('showEpgHint: _epg.isNotEmpty')` = true
     *   —— 守"页头那句『· 支持节目单与回看』跟着 EPG 数据走"
     *      （原版 `<template v-if="epg.length">`）。
     * 【为什么作废】节目单整体删除 ⇒ **页头也不该再宣称支持节目单**
     *   （否则 UI 在骗用户："支持节目单"但页面里根本没有）。
     * 【新契约】页头**恒**不显示节目单提示。
     */
    test('★ 页头**不再**宣称"支持节目单与回看"（用户 2026-09-26 要求删）', () {
      expect(
        live.contains('_epg.isNotEmpty'),
        isFalse,
        reason: '★ 节目单已删 ⇒ 不能再有"跟着 EPG 数据走"的提示逻辑',
      );
      expect(
        RegExp(r'showEpgHint:\s*false').hasMatch(live),
        isTrue,
        reason: '★ 新契约：页头恒不显示节目单提示（写死 false）。'
            '★ 这与"删掉节目单"必须一致 —— 否则界面会说支持而实际没有',
      );
    });

    /*
     * ★★★ 2026-09-26 翻转（正向 ⇒ 反向）
     *
     * 【原断言】`live.contains('CollapsibleEpg(key: _epgKey, child: epg)')` = true
     *   —— 守"EPG 容器无条件构造（折叠只影响展开状态）"。
     * 【为什么作废】容器本身已从本页删除 ⇒ 断言的字面对象不存在了。
     * 【新契约】直播页**不得**再有 EPG 容器。
     *
     * ★ 但**原断言背后的那个语义仍然有效、必须继续守**：
     *   "播放器/右栏不该被包在『选中了才建』的条件里" ——
     *   这条与本页的"默认打开就自动播 + 固定布局"直接相关。
     *   ⇒ 所以下面**保留**对 `onWatchLive: _selected == null ? null : …`
     *     那条断言的检查（它表达"没选中时照样渲染，只是回调为 null"）。
     */
    test('★ 直播页**不再**构造 EPG 容器（用户 2026-09-26 要求删）', () {
      expect(
        live.contains('CollapsibleEpg'),
        isFalse,
        reason: '★ 折叠容器是为"节目单可折叠"服务的 ⇒ 节目单删除后它没有存在理由。'
            '若它又出现，说明有人把节目单加回来了 —— 那是回归。',
      );
      expect(
        live.contains('_epgKey'),
        isFalse,
        reason: '★ 那个 GlobalKey 已随之删除（留着就是死代码）',
      );
      /*
       * ★ 保留原断言背后的**语义**（不该因契约翻转而丢失）：
       *   右侧播放器**不**被包在"选中了才建"的条件里 ——
       *   没选中时它照样渲染，只是回调传 null。
       */
      expect(
        live.contains('onToggleFullscreen: _selected == null ? null : _watchLive'),
        isTrue,
        reason: '★ 右栏**无条件渲染**，靠回调传 null 表达"没选中" —— '
            '这条语义与节目单无关，翻转后**必须继续守**',
      );
    });
  });
}
