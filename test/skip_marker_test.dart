// ═══════════════════════════════════════════════════════════════════════
//  片头片尾设置（夸克式四箭头 + 独立预览）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户指出「片头片尾的设置你也没做」
//
// 确认：只做了**自动跳过**（`player_page.dart` 的 `_maybeSkip`），
// 用户**没有任何途径去设置**那四个点 —— 功能是半截的。
//
// # 原版的设计意图（`SkipMarkerDialog.vue` 文件头，Owner 两次指正）
//
// ## ① 是**区间**，不是单点
//
// Owner 原话：
// > 设置片头片尾应该是独立的…是可以配置**开始是从 xx 秒开始 xx 秒跳转**的，
// > 结尾也是一样，不是简单粗暴设置个片头的时间、片尾的时间就结束了，
// > 你搞错了，也做的不完善。
//
// 现在是**四个点**：`intro_start / intro_end / outro_start / outro_end`。
//
// ## ② 预览必须**独立**，不能联动主播放器
//
// Owner 原话：
// > 设置片头片尾的这个也应该视频是单独的，而不是使用第一层的那个 video，
// > 这两个应该是分别独立的…而不是跟底层的进行联动。
//
// 原版第一版把主播放器 seek 来 seek 去，三个后果（原文列出）：
// ```text
// · 设完片头，主播放器进度被改掉 —— 关掉后从"预览位置"继续看
// · 拖动让主播放器反复取分片（HLS 每次 seek 都要重新拉），搅乱缓冲
// · 手机上主播放器在弹窗背后还在播，两个画面不同步
// ```
//
// ## ③ 夸克式四箭头（用户给的设计参考）
//
// 用户原话：
// > 这个片头片尾设置你借鉴一下夸克的好吧,四个小箭头,片头两个,结束两个
// > 虽然片头都是从 00:00 开始,但是两个也可以表示一个时间
// > 结尾也是一样,虽然时间重叠,但是位置不重叠
//
// 用户还放大截图：两个大箭头**尖端相对、靠在一起**形成「领结」。
//
// # ⚠️ 本文件的两类断言（缺一不可）
//
// ```text
// ① 几何解算 —— 直接跑**生产纯函数** `computeSkipTips`
//    这是真正的行为验证：领结对不对、命中区会不会撞
// ② 接线 —— 静态断言（弹窗要真播放器才能构造，flutter_test 跑不起来）
// ```
// ⚠️ 第 ① 类是从字符串断言**升级**来的。
//    之前全是 `source.contains('...')` —— 那种断言挡不住
//    "几何算错了但字符串还在"（我前两版正是如此：
//    字符串断言全绿，但箭头实际重叠了 11px）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/ui/widgets/skip_marker_dialog.dart' show SkipEdge;
import 'package:sourin_spike/ui/widgets/skip_timeline.dart';

import '_support/strip_comments.dart';

/// 两个箭头**箭身**的重叠像素数
///
/// # 为什么按"箭身区间"而不是"箭身中心距离"判
///
/// 中心距离只是重叠的**近似** —— 方向不同、或者有一个被 `clamp`
/// 顶到画布边缘时，"中心够远"不代表"箭身没压上"。
/// 用户的要求是「位置不重叠」，那就该直接量**形状**：
/// ```text
/// 朝右箭头箭身 = [tip - kArrowW, tip]
/// 朝左箭头箭身 = [tip, tip + kArrowW]
/// 交集长度 > 0  → 真的重叠了
/// 交集长度 = 0  → 恰好相切（**领结**就是这个状态，要保留）
/// ```
/// ⚠️ 返回负值表示中间有缝（分开的），0 表示相切。
double _bodyOverlap(SkipEdge a, double tipA, SkipEdge b, double tipB) {
  double lo(SkipEdge e, double tip) =>
      skipEdgePointsRight(e) ? tip - kArrowW : tip;
  double hi(SkipEdge e, double tip) =>
      skipEdgePointsRight(e) ? tip : tip + kArrowW;

  final l = [lo(a, tipA), lo(b, tipB)].reduce((x, y) => x > y ? x : y);
  final h = [hi(a, tipA), hi(b, tipB)].reduce((x, y) => x < y ? x : y);
  return h - l; // >0 重叠，0 相切，<0 有缝
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 几何解算 —— 跑**生产纯函数**（真实行为验证）
  // ═══════════════════════════════════════════════════════════════════
  group('时间轴几何 —— 跑真实 computeSkipTips', () {
    /// 测试用画布宽度（弹窗 maxWidth 720 减去内边距）
    const w = 700.0;
    const total = 100.0;

    Map<SkipEdge, double?> tips({
      int? iStart,
      int? ie,
      int? os,
      int? oe,
    }) =>
        computeSkipTips(
          width: w,
          total: total,
          introStart: iStart,
          introEnd: ie,
          outroStart: os,
          outroEnd: oe,
        );

    test('★★★ 方向语义：开始朝右、结束朝左', () {
      /*
       * 箭头比竖线强的地方就是**自带方向**：
       * ```text
       * 区间**开始** → 朝右（"从这里开始跳"）
       * 区间**结束** → 朝左（"跳到这里为止"）
       * ```
       */
      expect(skipEdgePointsRight(SkipEdge.introStart), isTrue,
          reason: '片头开始 → 朝右');
      expect(skipEdgePointsRight(SkipEdge.introEnd), isFalse,
          reason: '片头结束 → 朝左');
      expect(skipEdgePointsRight(SkipEdge.outroStart), isTrue,
          reason: '片尾开始 → 朝右');
      expect(skipEdgePointsRight(SkipEdge.outroEnd), isFalse,
          reason: '片尾结束 → 朝左');
    });

    test('★★★ 领结：片头 0-0 时两个尖端必须落在**同一个 x**', () {
      /*
       * 这是夸克那个设计的核心形态。
       *
       * 两个箭头尖端同 x 时：
       * ```text
       * 朝右箭头 箭身 [tip-aw, tip]
       * 朝左箭头 箭身 [tip, tip+aw]
       *                ─────────────
       *                [tip-aw, tip+aw]  ← 对称领结
       * ```
       *
       * ⚠️ 我第二版把 `drawX` 当"箭身左边"用，又加了
       *    `minGap = arrowW + 2` 的错开 —— 语义不一致，
       *    箭身互相压了 11px，看起来是一个歪的实心块。
       */
      final t = tips(iStart: 0, ie: 0);
      expect(t[SkipEdge.introStart], isNotNull);
      expect(
        t[SkipEdge.introStart],
        closeTo(t[SkipEdge.introEnd]!, 0.01),
        reason: '★ 两个尖端必须同 x —— 这才形成领结。'
            '若此处不等，说明又引入了多余的错开偏移',
      );
    });

    test('★★★ 领结：片尾 总长-总长 时同理', () {
      final t = tips(os: 100, oe: 100);
      expect(
        t[SkipEdge.outroStart],
        closeTo(t[SkipEdge.outroEnd]!, 0.01),
        reason: '片尾两个尖端也要同 x（领结）',
      );
    });

    test('★★★ 领结形态下，两个箭身中心必须相距**一个箭宽**', () {
      /*
       * 这是「**位置不重叠**」的量化定义（用户明确要求）。
       *
       * 尖端同 x，但箭身中心分居两侧：
       * ```text
       * 朝右 中心 = tip - aw/2   （交点左侧）
       * 朝左 中心 = tip + aw/2   （交点右侧）
       * 相距 = aw
       * ```
       * ⚠️ 若命中判定用**尖端**（而不是箭身中心），
       *    两个箭头到点击点距离都是 0 → 永远只能抓到第一个 →
       *    用户会以为"另一个箭头点不动"。
       */
      final t = tips(iStart: 0, ie: 0);
      final c1 = skipEdgeBodyCenter(SkipEdge.introStart, t[SkipEdge.introStart])!;
      final c2 = skipEdgeBodyCenter(SkipEdge.introEnd, t[SkipEdge.introEnd])!;
      expect(
        (c1 - c2).abs(),
        closeTo(kArrowW, 0.01),
        reason: '★ 两个箭身中心必须恰好相距一个箭宽（$kArrowW）—— '
            '这是"位置不重叠"的量化保证',
      );
    });

    test('★★ 边界：端点不会被裁出画布', () {
      /*
       * 朝右箭头的箭身在 tip **左侧**，所以 tip=0 时箭身会跑到画布外。
       * 留白 `kArrowInset` 就是为了这个。
       */
      final t = tips(iStart: 0, ie: 30, os: 70, oe: 100);

      // 朝右的最左箭头：箭身左边缘 >= 0
      final leftTip = t[SkipEdge.introStart]!;
      expect(leftTip - kArrowW >= -0.01, isTrue,
          reason: '★ 最左的朝右箭头，箭身左边缘不能出画布（会被裁掉）');

      // 朝左的最右箭头：箭身右边缘 <= w
      final rightTip = t[SkipEdge.outroEnd]!;
      expect(rightTip + kArrowW <= w + 0.01, isTrue,
          reason: '★ 最右的朝左箭头，箭身右边缘不能出画布');
    });

    test('★★ 单调性：时间越大，tip x 越大', () {
      final t = tips(iStart: 0, ie: 30, os: 70, oe: 100);
      expect(t[SkipEdge.introStart]! < t[SkipEdge.introEnd]!, isTrue);
      expect(t[SkipEdge.introEnd]! < t[SkipEdge.outroStart]!, isTrue);
      expect(t[SkipEdge.outroStart]! < t[SkipEdge.outroEnd]!, isTrue);
    });

    test('★ 未设置 → tip 为 null（不是 0）', () {
      final t = tips();
      for (final e in SkipEdge.values) {
        expect(t[e], isNull, reason: '未设置的端点必须是 null');
      }
    });

    test('★★★ 退化情况：同向箭头重叠时必须推开（否则抓不开）', () {
      /*
       * 零长度区间会产生**同向**重叠：
       * ```text
       * 片头 0-0（零长度）+ 片尾 0-100
       *   → introStart 与 outroStart **都是朝右**且同 x
       *   → 箭身完全重合，用户只能抓到一个
       * ```
       * 正常数据不会触发（片头 < 片尾 是硬约束），但用户能手动造出来。
       */
      final t = tips(iStart: 0, ie: 0, os: 0, oe: 100);
      final a = skipEdgeBodyCenter(SkipEdge.introStart, t[SkipEdge.introStart])!;
      final b = skipEdgeBodyCenter(SkipEdge.outroStart, t[SkipEdge.outroStart])!;
      expect(
        (a - b).abs() >= kArrowW - 0.01,
        isTrue,
        reason: '★ 两个**同向**箭头的箭身中心必须分开至少一个箭宽，'
            '否则命中区重叠、抓不开（实测过：只差 2px）',
      );
    });

    test('★ 退化推开**不能破坏领结**（阈值必须是 kArrowW）', () {
      /*
       * 领结的两个箭身中心本来就恰好相距 `kArrowW`。
       * 如果推开阈值取得**大于** `kArrowW`，领结会被误判成"重叠"而推开 ——
       * 那就把夸克那个核心形态毁掉了。
       *
       * 这条测试是那个阈值的**护栏**：同时验证
       * ```text
       * 领结（相距 kArrowW）  → 不被推
       * 重叠（相距 2px）      → 被推
       * ```
       */
      // 领结保留
      final bow = tips(iStart: 0, ie: 0);
      expect(
        bow[SkipEdge.introStart],
        closeTo(bow[SkipEdge.introEnd]!, 0.01),
        reason: '领结的尖端必须仍然同 x（没有被推开）',
      );

      // 重叠被推开（同上一条，这里再确认一次阈值两侧行为不同）
      final overlap = tips(iStart: 0, ie: 0, os: 0, oe: 100);
      expect(
        (overlap[SkipEdge.introStart]! - overlap[SkipEdge.outroStart]!).abs() >=
            kArrowW - 0.01,
        isTrue,
        reason: '同向重叠必须被推开',
      );
    });

    test('★ 零总长不会除零（防御）', () {
      final t = computeSkipTips(
        width: w,
        total: 0,
        introStart: 0,
        introEnd: 0,
        outroStart: null,
        outroEnd: null,
      );
      for (final e in SkipEdge.values) {
        final v = t[e];
        if (v != null) {
          expect(v.isFinite, isTrue, reason: 'total=0 时不能产生 NaN/Infinity');
        }
      }
    });

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 任意两箭头：**箭身不得重叠**（这是"位置不重叠"的真正判据）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 为什么还要加这一组（前面的断言漏了什么）
     *
     * 前面那条退化测试断言的是**箭身中心**相距 `>= kArrowW`。
     * 但"中心距离"只是个**近似**：两个箭头方向不同、或者其中一个被
     * `clamp` 顶到画布边缘时，中心够远**不代表箭身没压上**。
     *
     * 用户的原话是「虽然时间重叠，但是**位置不重叠**」——
     * 那就该直接按**箭身区间**判，而不是按中心点判：
     * ```text
     * 朝右箭头箭身 = [tip - aw, tip]
     * 朝左箭头箭身 = [tip     , tip + aw]
     * 两个区间相交 → 用户看到的是一坨，不是一个箭头
     * ```
     *
     * ⚠️ 领结是**例外且是必需的**：它两尖端同 x，箭身恰好**相切**于
     *    交点（区间 [t-aw,t] 与 [t,t+aw] 交集只有一个点）——
     *    `intersection > 0` 才算重叠，相切不算。这正是夸克那个形态。
     *
     * ★ 教训：这一组才是"几何算错"的真护栏。
     *   字符串断言、甚至"中心点距离"断言都可能全绿而箭头实际压在一起。
     */
    test('★★★ 任意两箭头：箭身不得重叠（穷举场景）', () {
      // 各种端点组合 —— 覆盖正常 / 领结 / 零长度 / 同向重叠 / 边界
      const scenes = <List<int?>>[
        [0, 30, 70, 100], // 正常
        [0, 0, null, null], // 片头领结
        [null, null, 100, 100], // 片尾领结
        [0, 0, 0, 100], // 退化：零长度片头 + 片尾
        [0, 123, null, null], // 隔离库里的真实数据（0-123）
        [0, 1, 1, 100], // 片头结束与片尾开始贴着
        [0, 50, 50, 100], // 两个区间背靠背
        [99, 100, 100, 100], // 全挤在末尾
        [0, 100, 100, 100], // 片尾零长度在最右
        [0, 0, 100, 100], // 两个零长度区间
      ];

      for (final s in scenes) {
        final t = tips(iStart: s[0], ie: s[1], os: s[2], oe: s[3]);
        final present = SkipEdge.values.where((e) => t[e] != null).toList();

        for (var i = 0; i < present.length; i++) {
          for (var j = i + 1; j < present.length; j++) {
            final a = present[i], b = present[j];
            final overlap = _bodyOverlap(a, t[a]!, b, t[b]!);
            expect(
              overlap,
              lessThanOrEqualTo(0.01),
              reason: '★ 场景 $s：`$a` 与 `$b` 的箭身重叠了 '
                  '${overlap.toStringAsFixed(1)}px —— '
                  '用户看到的是一个糊在一起的块，不是一个箭头',
            );
          }
        }
      }
    });

    test('★★★ 领结形态：两箭身必须**相切**（既不重叠、也不分开）', () {
      /*
       * 这是"领结"的**精确**定义 —— 用箭身区间表达，而不是靠"尖端同 x"：
       * ```text
       * 朝右箭身 [t-aw, t]  朝左箭身 [t, t+aw]
       * 交集 = {t}  →  overlap == 0   ← 相切，形成领结
       * ```
       * 若 overlap < 0 → 中间有道缝，看着是两个分开的箭头（不是领结）
       * 若 overlap > 0 → 压在一起，看着是一坨
       */
      for (final sc in [
        [0, 0, null, null], // 片头 0-0
        [null, null, 100, 100], // 片尾 末-末
      ]) {
        final t = tips(iStart: sc[0], ie: sc[1], os: sc[2], oe: sc[3]);
        final present = SkipEdge.values.where((e) => t[e] != null).toList();
        expect(present.length, 2, reason: '该场景应恰好有两个箭头');
        final overlap = _bodyOverlap(
          present[0], t[present[0]]!, present[1], t[present[1]]!,
        );
        expect(
          overlap,
          closeTo(0, 0.01),
          reason: '★ 领结必须**恰好相切**（overlap == 0）：'
              '负值=中间有缝不像领结，正值=压成一坨',
        );
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 接线 —— 静态断言真实路径
  //
  //  ⚠️ 弹窗要真播放器（media_kit 原生后端）才能构造，
  //     flutter_test 里跑不起来。所以这部分仍是源码断言。
  // ═══════════════════════════════════════════════════════════════════
  group('片头片尾设置 —— 静态断言真实路径', () {
    late String dlg;
    late String timeline;
    late String player;

    setUpAll(() {
      // ★★ 2026-10-02：**必须剥注释**（铁律 170 的共享 helper，不许再抄一份）。
      //
      // 为什么：本文件原先直接断言 `readAsStringSync()` 的**原始文本**，
      // 而本仓的源码里写了大量中文注释解释"为什么改掉它"，
      // 注释里**会原样引用**被断言的片段 ⇒ 断言守的是**注释文本**，不是代码 ⇒ **假通过**。
      //
      // 实测（2026-10-02）：`_drawPlayhead` 在 `skip_timeline.dart` 里
      // 原始文本 raw=2 / 剥注释后 st=**0** —— 两处命中**全在注释里**
      // （那根黑竖条已被删除，注释里记着删除理由）。
      // ⇒ 不剥注释时 `:546` 那条断言会一直"绿"，而它本该红。
      //
      // ★ 已逐条复核：本文件其余 37 处 `.contains(` 的针在剥注释后**全部仍然命中**
      //   （唯一翻红的就是下面 `_drawPlayhead` 那条，而它本就该翻）。
      dlg = stripComments(
        File('lib/ui/widgets/skip_marker_dialog.dart').readAsStringSync(),
      );
      timeline = stripComments(
        File('lib/ui/widgets/skip_timeline.dart').readAsStringSync(),
      );
      player = stripComments(
        File('lib/ui/player_page.dart').readAsStringSync(),
      );
    });

    test('★★ 必须是**四个点**（区间语义），不是单点', () {
      for (final f in ['_introStart', '_introEnd', '_outroStart', '_outroEnd']) {
        expect(dlg.contains(f), isTrue,
            reason: '★ 缺 `$f` —— 四个端点缺一不可（片头/片尾各是一个区间）');
      }
      for (final k in [
        'introStart: _introStart',
        'introEnd: _introEnd',
        'outroStart: _outroStart',
        'outroEnd: _outroEnd',
      ]) {
        expect(dlg.contains(k), isTrue, reason: '保存时必须传 `$k`');
      }
    });

    test('★★ 端点用 `int?` —— null 是"未设置"，与"0 秒"不同', () {
      /*
       * 片头开始天然就是 0，所以 **0 是合法值**，不能用 0 当哨兵。
       */
      expect(dlg.contains('int? _introStart'), isTrue,
          reason: '★ 必须是可空 —— 用 0 当"未设置"的话，'
              '用户真的把片头开始设在 0 秒就没法表达了');
    });

    test('★★ 预览播放器必须**独立**（不能复用主播放器）', () {
      expect(dlg.contains('Player? _preview'), isTrue,
          reason: '★ 必须有自己的 `Player` 实例');
      /*
       * ⚠️ 这里原来断言的是**完整字面量** `await p.open(Media(widget.streamUrl))`。
       *    2026-09-25 加了用户要求的 `play: false`（不自动播放），
       *    字面量不再逐字相等 —— 所以改成断言**调用形态**（前缀）
       *    而不是整行，**意图不变**：独立实例自己去 open 那路 URL。
       */
      expect(
        dlg.contains('await p.open(Media(widget.streamUrl)'),
        isTrue,
        reason: '★ 独立实例用同一路流地址自己加载 —— 不是去 seek 主播放器',
      );
      expect(
        dlg.contains('play: false'),
        isTrue,
        reason: '★★ 打开弹窗**不得自动播放**（2026-09-25 用户实测：'
            '`media_kit` 的 `Player.open()` 默认 `play: true`，'
            '不显式传就会一打开就播）',
      );
      expect(
        dlg.contains('_player.') || dlg.contains('widget.player'),
        isFalse,
        reason: '★ 弹窗**不得**持有或操作主播放器 —— '
            '那正是原版第一版被否掉的做法',
      );
    });

    test('★ 预览播放器必须在 dispose 里释放', () {
      expect(
        dlg.contains('_preview?.dispose()'),
        isTrue,
        reason: '★ 不 dispose 会**泄漏原生 mpv 实例** —— '
            '开几次设置就多几个解码器在后台跑',
      );
    });

    test('★ 预览也要设硬解（否则拖动时卡）', () {
      expect(
        dlg.contains("native.setProperty('hwdec', 'auto-safe')"),
        isTrue,
        reason: '★ 预览不设硬解的话 Android 上软解 —— '
            '用户拖动时要即时看到画面，卡顿直接毁掉体验',
      );
      expect(
        dlg.contains('if (native is NativePlayer)'),
        isTrue,
        reason: '`setProperty` 在 `Player` 上不存在，必须转 `NativePlayer`',
      );
    });

    test('★ 时间轴要画**两个区间**（片头 + 片尾）', () {
      expect(
        timeline.contains('drawRange(SkipEdge.introStart, SkipEdge.introEnd'),
        isTrue,
        reason: '片头区间要高亮',
      );
      expect(
        timeline.contains('drawRange(SkipEdge.outroStart, SkipEdge.outroEnd'),
        isTrue,
        reason: '片尾区间要高亮',
      );
    });

    test('★ 时间轴用**实心**箭头（夸克是实心无描边）', () {
      /*
       * ⚠️ 我第二版加了 1.5px 白描边 —— 深色底上显得"空心/细"，
       *    与参考图不符，已去掉。
       */
      expect(
        timeline.contains('void drawArrow('),
        isTrue,
        reason: '★ 必须是**箭头**而不是竖线 —— 箭头自带方向语义',
      );
      // 四个箭头各自被画（方向由 skipEdgePointsRight 决定，不再传参）
      for (final e in ['introStart', 'introEnd', 'outroStart', 'outroEnd']) {
        expect(
          timeline.contains('drawArrow(SkipEdge.$e,'),
          isTrue,
          reason: '箭头 `$e` 必须被画出来',
        );
      }
      // 实心：不再用 stroke 描边
      expect(
        timeline.contains('PaintingStyle.stroke'),
        isFalse,
        reason: '★ 不要描边 —— 夸克那个箭头是**实心**的，'
            '加描边在深色底上会显得空心/细',
      );
    });

    test('★ 拖拽必须按**真实 x** 换算秒数（不能用平移后的位置）', () {
      /*
       * 平移（错开）只是为了"看得见、抓得到"。
       * 拖拽若按平移后的位置算秒数，用户会发现拖到某个像素时秒数跳变。
       */
      expect(
        timeline.contains('widget.onChanged(e, secOf(d.localPosition.dx'),
        isTrue,
        reason: '★ 拖拽必须按真实 x 换算 —— 不能用 drawTips 的位置',
      );
    });

    test('★ 抓到的是箭身，按下时不能跳（要补偿抓取偏移）', () {
      /*
       * 用户抓到的是**箭身**，而箭头的语义位置是**尖端** ——
       * 两者差 `kArrowW/2`（8.5px）。
       * 不补偿的话一按下箭头就跳 8.5px，手感是"抓不住"。
       */
      expect(timeline.contains('_grabOffset'), isTrue,
          reason: '★ 必须记录并减掉抓取偏移，否则按下瞬间箭头会跳');
    });

    test('★★ 时间轴要能看出**当前画面在第几秒**（黑竖条已按 Owner 要求删除）', () {
      /*
       * ★★ 2026-10-02：这条断言的**判据反转过**，理由必须写在案。
       *
       * 改前：`expect(timeline.contains('_drawPlayhead'), isTrue)` ——
       *   它**从来没有咬住过代码**：`_drawPlayhead` 在 `skip_timeline.dart` 里
       *   原始文本 raw=2，但**剥掉注释后 st=0** —— 两处命中**全在注释里**
       *   （记的正是"为什么把它删掉"）⇒ 这条断言一直是**假绿**。
       *   它守的是**注释文本**，不是代码。
       *
       * 而 Owner 已拍板**删除**那根黑竖条（「一个黑色的竖着的东西，
       *   没有用的话就给删了」，2026-10-01 第三次提）⇒
       *   "这根线必须画出来"这个方向本身就已经**反了**。
       *
       * ★ 真正的守卫分两层，本条只负责第一层：
       *   ① **源码层**（本条）：`_drawPlayhead` 的定义与调用都**不许**回来；
       *   ② **像素层**（`t447_playhead_removed_test.dart`）：轨道那一带
       *      不得出现"宽 <= 3px 且高 >= 轨道高"的暗色竖条。
       *   ★ 像素层才是 Owner 的判据 —— 源码断言只能证明"那段代码没了"，
       *     **证明不了"屏幕上那根线没了"**。
       *
       * ★ 而"用户得知道当前画面在第几秒"这个**需求本身仍然成立** ——
       *   它现在由**橙色当前时间标签 + 已播进度条**承担，两者都锚在
       *   `xOf(position)` 上，所以下面继续验算这套换算。
       */
      expect(
        timeline.contains('_drawPlayhead'),
        isFalse,
        reason: '★★★ 黑竖条已按 Owner 要求删除（2026-10-01）—— '
            '定义与调用都不许回来。'
            '★ 本文件的源码断言**已剥注释**：若不剥，注释里那两处 '
            '`_drawPlayhead` 会把这条断言弄成**假红**',
      );
      // 由**生产纯函数**验算"当前时间"的 x（而不是只断言它"被调用过"）
      const bw = 700.0, bTotal = 100.0, pos = 50.0;
      final tt = computeSkipTips(
        width: bw,
        total: bTotal,
        introStart: 0,
        introEnd: 30,
        outroStart: 70,
        outroEnd: 100,
      );
      final head = xOfTip(width: bw, total: bTotal, sec: pos);
      expect(head.isFinite, isTrue, reason: '当前时间的位置必须算出有限值');
      // 50 秒落在片头结束(30)与片尾开始(70)之间 —— 顺序必须成立
      expect(head > tt[SkipEdge.introEnd]!, isTrue,
          reason: '当前时间必须跟时间轴用**同一套换算**，否则会和箭头对不上');
      expect(head < tt[SkipEdge.outroStart]!, isTrue);
      expect(
        timeline.contains('xOf(position)'),
        isTrue,
        reason: '★ 当前时间标签与已播进度条必须落在 `xOf(position)` 处 —— '
            '用固定像素或另一套换算就会和箭头/高亮对不上',
      );
    });

    test('★ 命中半径要够大（触摸端）', () {
      expect(timeline.contains('_hitR'), isTrue,
          reason: '★ 必须有独立的**命中半径** —— 只按轨道高度判的话触摸端点不中');
    });

    test('★★ 区间合法性要在 UI 层提前拦（不能等后端抛错）', () {
      /*
       * 原版注释：
       * > ⚠️ 后端会校验区间合法性（start < end、片头在片尾之前），
       * >    违反时**抛错**。
       * 让用户点了"确认"才看到报错很糟 —— 所以提前禁用按钮。
       */
      expect(dlg.contains('bool get _canSave'), isTrue, reason: '★ 必须先在 UI 层校验');
      expect(dlg.contains('_introStart! >= _introEnd!'), isTrue,
          reason: '片头必须 起点 < 终点');
      expect(dlg.contains('_outroStart! >= _outroEnd!'), isTrue,
          reason: '片尾必须 起点 < 终点');
      expect(dlg.contains('_introEnd! > _outroStart!'), isTrue,
          reason: '片头必须在片尾之前');
      expect(dlg.contains('区间不合法'), isTrue,
          reason: '★ 要显示**具体原因**，否则用户以为按钮坏了');
    });

    test('★★ 中段可滚动 + 保存按钮固定（否则存不了盘）', () {
      /*
       * 实测抓到的布局 bug：弹窗 maxHeight 640，而内容需要约 799px
       * （预览 16:9 就 405px）—— 底部的「确认设置」被**裁出屏幕**，
       * 用户根本没法保存。
       *
       * ⚠️ 而且**没有 RenderFlex overflow 报错** ——
       *    因为 `Column` 里有 `Spacer()`，它把剩余空间压成 0
       *    然后让后面的子节点溢出而不报错。这类"不报错的溢出"
       *    只有真机截图才看得出来。
       */
      expect(dlg.contains('Expanded('), isTrue,
          reason: '★ 中段必须 Expanded（才能滚动）');
      expect(dlg.contains('SingleChildScrollView'), isTrue,
          reason: '★ 中段必须可滚动');
      expect(dlg.contains('_footer(colors)'), isTrue,
          reason: '★ 底部按钮要**固定**（保存是这个弹窗的唯一出口）');
    });

    test('★ 打开弹窗时要暂停主播放器（原版明确行为）', () {
      expect(
        player.contains('if (_playing) await _player.pause();'),
        isTrue,
        reason: '★ 打开设置前要暂停主播放器（避免两个画面不同步 + 白耗流量）',
      );
    });

    test('★ 直播不给设（原版第一行就拦）', () {
      expect(player.contains('if (_isLive) return;'), isTrue,
          reason: '直播是线性的，没有"片头片尾"的概念');
      expect(
        player.contains('onSkipMarkers: _isLive ? null : _openSkipDialog'),
        isTrue,
        reason: '★ 直播时应传 null 让按钮**不显示** —— '
            '显示一个点了没用的按钮比不显示更糟',
      );
    });

    test('★★ 保存后要重置"已触发过"标志（否则设了没用）', () {
      /*
       * `_introSkipped` 是"本次会话已跳过"的标志。
       * 用户设完新片头，但本会话早先已经跳过过一次 → 新设置**不生效**，
       * 表现为"设了没用"，极难排查。
       */
      expect(player.contains('_introSkipped = false;'), isTrue,
          reason: '★ 保存新设置后必须重置 —— 否则本次会话内新设置不生效');
      expect(player.contains('_outroSkipped = false;'), isTrue, reason: '同上');
    });

    test('★ 保存后要立刻更新内存里的 _skipMarker（不用重拉接口）', () {
      expect(player.contains('_skipMarker = SkipMarker('), isTrue,
          reason: '★ 刚写完就是最新的，直接更新内存 —— '
              '否则用户设完片头要等下一次换集才生效，不合理');
    });

    test('★★★ 预览 seek 必须等流就绪 —— 不能 open 完立刻 seek', () {
      /*
       * # 实测抓到的真 bug（2026-09-24，编排者从播放器页转来的同类问题）
       *
       * `Player.open()` **返回 ≠ 流已就绪**：此刻 `duration` 还是 0、
       * demux 没完成。这时发出的 seek 会被随后的音视频链重建**复位掉**，
       * 而 seek 调用**不报错** —— 日志/状态全显示成功、画面却在原地。
       * 播放器页的现象是"日志说已续播到 276s，画面上是 00:29"。
       *
       * # 在本弹窗里后果更严重
       *
       * 预览做的是**区间循环**（播到区间末尾 seek 回起点）。seek 被丢弃
       * → 循环失效 → 用户看到"预览一直往前播、不循环"，
       * 而且**没有任何报错**，只会以为"预览按钮坏了"。
       */
      expect(
        dlg.contains('while (_mediaDuration <= 0 && mounted'),
        isTrue,
        reason: '★ 必须**等 duration > 0** 再 seek —— 否则 seek 会被加载复位吃掉，'
            '而且不报错（实测：日志说成功、画面没动）',
      );
      expect(
        dlg.contains('_verifySeek'),
        isTrue,
        reason: '★ seek 不报错，唯一判据是"位置有没有变过去" —— 必须回头核对',
      );
      expect(
        dlg.contains('_rawPos'),
        isTrue,
        reason: '★ `_previewPos` 是乐观值（点了预览就设成目标），'
            '不能拿它当"seek 成功"的证据',
      );
    });

    test('★★★ 区间循环必须按**画面真实位置**判，不能按乐观读数', () {
      /*
       * 若循环用 `_previewPos` 判：seek 被静默丢弃时 `_previewPos`
       * 照样等于目标值 → 循环**看起来**成功了，实际画面根本没跳回去。
       * 必须用播放器流报告的 `_rawPos`。
       */
      final at = dlg.indexOf(
        'Timer.periodic(const Duration(milliseconds: 200)',
      );
      expect(at, greaterThan(0), reason: '应能找到循环定时器');
      final rest = dlg.substring(at);
      final end = rest.indexOf('});');
      final body = rest.substring(0, end < 0 ? rest.length : end);

      expect(
        body.contains('_rawPos'),
        isTrue,
        reason: '★ 循环判据必须是播放器真实位置 `_rawPos` —— '
            '用 `_previewPos` 会在 seek 被丢弃时"假成功"',
      );
      expect(
        RegExp(r'_previewPos\s*>=').hasMatch(body),
        isFalse,
        reason: '★ 循环里不得拿乐观读数 `_previewPos` 做 `>=` 比较',
      );
    });

    test('★ 禁止 import flutter/material（两套 Theme 会串台）', () {
      for (final src in [dlg, timeline]) {
        expect(
          src.contains("package:flutter/material.dart"),
          isFalse,
          reason: '★ Flutter 3.47 把 Material 拆成了 `material_ui` 包 —— '
              '混用会导致"两套 Theme 串台"（踩过：设置页标题对比度 1.16:1）',
        );
      }
    });
  });
}
