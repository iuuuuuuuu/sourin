// ═══════════════════════════════════════════════════════════════════════
//  设计令牌 —— 对齐原版 Vue 的 CSS 变量（2026-09-23）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要把原版的 CSS 变量搬过来
//
// Owner 要求「操作逻辑和原版完全一致」+「UI 要好看」。
// 视觉可以优化，但**尺寸体系不能自己发明** —— 否则：
// ```text
// 原版卡片 148px 宽 → 我随手写 160px
// → 一行少放一张卡 → 用户感觉「变挤了」
// → 但说不出哪里变了（因为颜色字体都没动）
// ```
// 这类"说不出但就是不对"的差异最难查。所以间距/圆角/字号**照抄原版**。
//
// # 来源
//
// ```text
// src/design/tokens.css     → 间距 / 圆角 / 字号 / 动效
// src/design/theme.ts       → 颜色（深色为主）
// ```
//
// # 命名对应
//
// ```text
// CSS 变量      Dart 常量
// --sp-4        Sp.md
// --r-lg        Radii.lg
// --fs-base     FontSizes.base
// --dur-base    Durations.base
// ```

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/widgets.dart';

import '../core/device.dart';

/// 间距（原版 `--sp-*`）
///
/// 4px 基准的等比序列。**不要临时写 `EdgeInsets.all(18)`** ——
/// 用最近的档位，否则整个界面的节奏会乱。
abstract final class Sp {
  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x5 = 20;
  static const double x6 = 24;
  static const double x8 = 32;
  static const double x10 = 40;
  static const double x12 = 48;
  static const double x16 = 64;

  /// 页面内容底部留白 —— **给悬浮底栏让位**
  ///
  /// # 为什么需要（2026-09-24 做成悬浮底栏之后）
  ///
  /// 底栏改成"浮在内容之上"（见 `shell.dart` 的 Stack 说明）后，
  /// 它**不再占据布局空间** —— 内容会一直滚到屏幕最底边，
  /// 最后一行被底栏盖住一截。
  ///
  /// 原版是给 `.app-main` 加 padding 解决：
  /// ```css
  /// padding-bottom: calc(var(--tabbar-h) + var(--tabbar-bottom) + var(--safe-bottom));
  /// ```
  ///
  /// 这里算同样的账：
  /// ```text
  /// 桌面  底栏 58 + 间隙 12 + 余量 20 = 90
  /// TV    底栏 72 + 间隙 18 + 余量 20 = 110
  /// ```
  /// ⚠️ 余量 20 是**故意留的** —— 刚好贴着底栏会让最后一行显得"被顶住"，
  ///    多留一点滚到底时视觉上更舒服。
  static double get bottomBarInset => Device.isTv ? 110 : 90;
}

/// 圆角（原版 `--r-*`）
abstract final class Radii {
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 22;
  static const double xl = 28;
  static const double xxl = 34;

  /// 胶囊（按钮/标签）
  static const double full = 999;

  static const BorderRadius rSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius rMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius rLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius rXl = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius rFull = BorderRadius.all(Radius.circular(full));
}

/// 字号（原版 `--fs-*`，桌面档）
///
/// ⚠️ 原版在**大屏/TV** 下会整体放大（`--fs-base: 20px` 等）。
///    见 [AppMetrics.textScaleFor] —— 那是"弱 TV 也要看得清"的落点。
abstract final class FontSizes {
  /// 角标、计数、辅助说明
  static const double cap = 12;

  /// 次要文字、副标题
  static const double sm = 14;

  /// 正文、卡片标题
  static const double base = 16;

  /// 区块标题
  static const double lg = 20;

  /// 页面标题
  static const double xl = 28;

  static const double display = 46;
}

/// 字重（★ 2026-10-08 Owner 第 6 条）
///
/// # 为什么只有**两档**（改前是 5 档、138 处手写）
/// ```text
/// 改前的分布：w600×86 / w400×21 / w500×15 / w700×13 / normal×2 / w800×1
/// 而界面主字族（Windows 上是 `Microsoft YaHei UI`）**只有 400/700 两个面**
/// （msyh.ttc numFonts = 2），DirectWrite 实测选面：
/// ```
///   w400 → Normal    w500 → Normal    w600 → Bold
///   w700 → Bold      w800 → Bold
/// ```
/// ⇒ ① w500 在中文上渲染与 w400 **完全一样**（15 处死代码）
///   ② w600/w700/w800 三者渲染**完全一样**
///   ③ 而拉丁/数字走 Inter（真可变字重）⇒ 同一行「中文粗、数字细」
///      = 用户报的「粗细不一」
///
/// # 收敛规则
/// ```text
/// regular  ← w400 / w500 / normal   （系统只有 Normal 面）
/// semibold ← w600 / w700 / w800 / bold（系统只有 Bold 面）
/// ```
/// ★ 语义上仍是「普通 / 加粗」两级 —— 这正是原版的 `--fw-normal` 与
///   `--fw-bold` 表达的东西（`src/design/tokens.css:149-153`）。
/// ⚠️ 只用这两档；新增文字**不要**再写 `FontWeight.wNNN` 字面量。
abstract final class FontWeights {
  /// 普通（正文、说明、次要信息）
  static const FontWeight regular = FontWeight.w400;

  /// 加粗（标题、强调、当前项）
  static const FontWeight semibold = FontWeight.w600;
}

/// 动效时长（原版 `--dur-*`）
///
/// ⚠️ 名字是 **Motion 不是 Durations** ——
///    Flutter 的 `material/motion.dart` 里已经有一个 `Durations` 类，
///    同名会导致 `ambiguous_import`（每个使用点都报错）。
///    这类「库里的名字和你撞了」的问题，改自己的名字比 hide 对方的更省事
///    （hide 要在**每个** import 处写，漏一处就编译失败）。
abstract final class Motion {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration base = Duration(milliseconds: 260);
  static const Duration slow = Duration(milliseconds: 420);

  /// 原版 `--ease-out: cubic-bezier(0.22, 1, 0.36, 1)`
  ///
  /// 这个曲线"起步快、收尾长"，是原版所有过渡的默认值。
  /// Flutter 的 `Curves.easeOutCubic` 数值接近但不是同一个 ——
  /// 要用就照抄。
  static const Curve easeOut = Cubic(0.22, 1, 0.36, 1);
  static const Curve easeInOut = Cubic(0.65, 0, 0.35, 1);

  /// 原版 `--ease-spring`（按钮回弹）
  static const Curve spring = Cubic(0.34, 1.56, 0.64, 1);

  /*
   * ══════════════════════════════════════════════════════════════════
   * ★★ task-44 追加（2026-09-26）—— 两档"低于 fast"的时长
   * ══════════════════════════════════════════════════════════════════
   *
   * # 为什么要追加（而不是就地写 `Duration(milliseconds: 90)`）
   * ```text
   * 用户要求："6.动画效果加一下,多个动画效果"
   * ⇒ 我新增了两处高频交互动画，它们都需要**比 `fast` 更快**的一档：
   * ```
   * ```text
   *                值      用在哪                  为什么这么快
   *   press      90ms   按下反馈（pointer down）   按下必须"立刻"响应，
   *                                               否则用户会重复点击
   *   fade      200ms   骨架 → 内容淡入           介于 fast/base；
   *                                               每次进首页都经历，
   *                                               260ms 会显得在等
   * ```
   *
   * # ★ 为什么放在 `Motion` 里而不是各自文件内
   * ```text
   * 本项目已有 33 处 `Duration(milliseconds:)` **散落**在多个文件，
   * 同一个 260ms 有 `Motion.base` 和裸字面量两种写法
   * ⇒ ★ 新增值若也写成本地常量，就是**继续增加散落**
   *   ⇒ 放在 `Motion` 里：改"所有按压反馈的快慢"只需动一处，
   *     而且**理由（为什么是 90/200）与其它动效时长放在一起**
   * ```
   *
   * ⚠️ **只追加，不改**既有 `fast/base/slow` 三个值与两条曲线 ——
   *    它们已被 18 处使用，改动面太大（且原版对齐关系已核实）。
   *    既有那 33 处裸字面量**本次不动**（跨多个别人的文件，会在报告里列为建议）。
   */

  /// 按下反馈（pointer down）—— **90ms**
  ///
  /// ★ 比 `fast` 还快：按下是"因果**必须**立刻可见"的动作。
  ///   实测依据：Material 规范的 ripple 起始约 75~100ms；
  ///   超过 ~120ms 用户就会觉得"点了没反应"从而重复点击。
  static const Duration press = Duration(milliseconds: 90);

  /// 骨架 → 内容淡入 —— **200ms**
  ///
  /// ★ 介于 `fast`(150) 与 `base`(260) 之间，理由：
  ///   · 它是**每次进首页都要经历**的过渡 ⇒ 越短越好（不像一次性动画）
  ///   · 但太短（≤150）会看不出是"淡入"，像"闪一下"
  ///   ⇒ 200ms 是"能看清是过渡、又不觉得在等"的经验值
  /// ⚠️ 判据②要求 ≤300ms ✓
  static const Duration fade = Duration(milliseconds: 200);
}

/// 浮层（弹窗 / 抽屉 / 底部弹层）的动效档位 —— task-99 追加
///
/// ══════════════════════════════════════════════════════════════════════
/// ★ 为什么要有这一层（而不是各处直接写 `Motion.base`）
/// ══════════════════════════════════════════════════════════════════════
/// 用户原话（桌面端 9 条问题 · 第 7 条）：
/// ```text
/// 很多弹窗我都觉得很生硬，包括抽屉还有页面之间的跳转，请优化
/// ```
/// 取证结论：本项目有 4 个自实现的全屏浮层（弹幕设置 / 字幕面板 /
/// 选集面板 / 选集条），它们的入场**全都不一样**：
/// ```text
/// 弹幕设置 / 字幕面板        零动画（一帧硬切）
/// 选集条 / 选集面板（手机）   只有位移、没有透明度，遮罩硬切
/// 选集面板（桌面居中弹窗）    零动画（begin == end == 0）
/// cast 底部弹层              吃 material 默认 250ms/200ms（不跟 token）
/// ```
/// ⇒ 统一到**一处**：这里定义"浮层这一档"用的时长/位移/曲线，
///   由 `ui/widgets/overlay_motion.dart` 的两个包装件消费。
///
/// ⚠️ **只追加**：本类不动上面 `Motion` 的 `fast`/`base`/`slow`/曲线 ——
///    那三个值已被 18 处使用，改它们等于改全局节奏。
abstract final class OverlayMotion {
  /// 遮罩（scrim）淡入时长 —— 取 `Motion.fast`(150ms)
  ///
  /// ★ 比卡片**更快**到位是有意的：遮罩是"铺底"，如果它比卡片慢，
  ///   会看到"黑幕还没铺满，卡片已经飞进来了"。
  static const Duration scrimDuration = Motion.fast;

  /// 卡片 / 面板本体的入场时长 —— 取 `Motion.base`(260ms)
  static const Duration cardDuration = Motion.base;

  /// 卡片入场的位移（逻辑像素）
  ///
  /// ★ 本项目偏好**克制**的动效：既有的 `page_transition.dart` 缩放幅度
  ///   只有 **0.02**（2%），页面切换的位移也只在 20~24px 量级。
  ///   这里沿用同一个量级 —— 目的是"让用户看出东西是从哪来的"，
  ///   而不是"表演一段动画"。
  /// ⚠️ 纯平移：`Transform.translate` 不改布局、不改尺寸，动画结束时
  ///   offset = (0,0) ⇒ 卡片几何与改前**逐像素一致**（几何被
  ///   `episode_drawer_test.dart` / `t57` / `zz_t70` 钉住）。
  static const double cardSlide = 24;

  /// 卡片入场的曲线 —— `Motion.easeOut`
  static const Curve cardCurve = Motion.easeOut;

  /// 浮层**退场**（关闭）的时长 —— 与入场同一个 token
  ///
  /// ★ 为什么不单独给一个更短的数（例如 110ms）：
  ///   自实现浮层的退场由 `SheetTransition` / `SheetExitMotion` 驱动，
  ///   两者的入场都是 `cardDuration`；退场取**同一个值**才能让"关"与"开"
  ///   是同一段路（`showDialog` 侧更是**框架硬限制**：退场 == 入场，
  ///   理由见 `sheetAnimationStyle()` 的文档）。
  /// ⇒ 真要让"关得更快"，改的是**这一个常量**，不是某个调用点的魔数。
  static const Duration exitDuration = cardDuration;

  /// 浮层退场的曲线 —— 与入场同一条
  static const Curve exitCurve = cardCurve;

  /// `showModalBottomSheet` / `showDialog` 用的动画样式
  ///
  /// # ★ 为什么必须**逐调用点**传（不能靠主题）
  /// ```text
  /// 逐字段核对过 material_ui-1.4.0：
  ///   · `BottomSheetThemeData` 只有 backgroundColor / elevation / shape /
  ///     showDragHandle / …  —— **没有** animationStyle
  ///   · `DialogThemeData`       只有 backgroundColor / shape / barrierColor /
  ///     insetPadding / …     —— **也没有** animationStyle
  /// ⇒ 没有任何全局主题字段能改这两个函数的时长。
  /// ```
  /// 框架默认值（`bottom_sheet.dart:29-30` / `dialog.dart:1904`）：
  /// ```text
  /// showModalBottomSheet   入场 250ms / 退场 200ms（_kBottomSheetEnter/Exit）
  /// showDialog             入场 150ms（DialogRoute.transitionDuration）
  /// ```
  /// ⇒ 与本项目的 token（150/260/420）**都不一致**（弹层比页面切换还慢）。
  ///
  /// # ★★ `reverseDuration` 只对 **bottom sheet** 有效（2026-10-08 逐行核对）
  /// ```text
  /// showModalBottomSheet  bottom_sheet.dart:250
  ///     reverseDuration: sheetAnimationStyle?.reverseDuration ?? _kBottomSheetExitDuration
  ///     ⇒ 真的读了它 ⇒ 退场 150ms（比入场 260ms 干脆）
  ///
  /// showDialog            dialog.dart:1853
  ///     transitionDuration: animationStyle?.duration ?? 150ms
  ///     ↑ **只**传了 transitionDuration，没有传 reverseTransitionDuration
  ///   routes.dart:234-235
  ///     final Duration duration = transitionDuration;
  ///     final Duration reverseDuration = reverseTransitionDuration;
  ///     ↑ reverseTransitionDuration 的默认值**就是** transitionDuration
  ///     ⇒ 给 showDialog 传 reverseDuration **完全无效**，退场恒等于入场。
  /// ```
  /// ⇒ 这里保留 `reverseDuration`（bottom sheet 吃得到），但**不许**把它
  ///   说成"showDialog 的退场时长"；也**不许**为了改 showDialog 的退场去
  ///   自建 `RawDialogRoute`（会丢掉 `_FullWindowDialogWrapper` /
  ///   `_DialogPopScope` 这些 3.47 才有的对话框语义）。
  static AnimationStyle sheetAnimationStyle() => const AnimationStyle(
    duration: cardDuration,
    reverseDuration: scrimDuration,
    curve: cardCurve,
    reverseCurve: cardCurve,
  );
}

/// 布局尺寸 —— **必须与原版一致**，否则每行卡片数会变
abstract final class AppMetrics {
  /// 海报卡宽度（原版 `.skeleton-rail { grid-auto-columns: 148px }`）
  static const double posterWidth = 148;

  /// 海报宽高比（2:3，影视海报标准）
  static const double posterAspect = 2 / 3;

  /// 标题栏高度
  static const double titleBarHeight = 40;

  /// 底栏高度
  static const double bottomBarHeight = 60;

  /// 首页顶部内边距（原版 `.container { padding-top: var(--sp-5) }`）
  static const double homeTopPadding = Sp.x5;

  /// 内容左右内边距（原版 `.container { padding: 0 var(--sp-6) }`）
  static const double contentPadding = Sp.x6;

  /// TV / 大屏的字号放大系数
  ///
  /// # 为什么 TV 要放大
  ///
  /// 电视观看距离是显示器的 2~3 倍，同样的 16px 字在沙发上
  /// **看不清**。原版 `device.ts` 在 leanback 设备上把整套
  /// `--fs-*` 调大一档（cap 12→14、base 16→20 …）。
  ///
  /// ⚠️ 这里**只管字号**。卡片宽度是另一回事 —— 它由 [Layout] 按「桌面 /
  ///    TV」两档算（TV 档走原版 `--poster-w: 216px`，见 [Layout.minCellTv]）。
  ///    两者不要互相引用：字号放大**不许**顺带改掉每行张数。
  static double textScaleFor({required bool isTv}) => isTv ? tvScale : 1.0;

  /// 同一个系数的**常量**形态 —— 给 `const` 上下文用
  ///
  /// ★ 2026-10-04 A1 接线：`lib/shell.dart` 在 `MaterialApp.builder` 里挂
  ///   `TextScaler.linear(AppMetrics.effectiveTextScale)` ——
  ///   注意**不是**这个常量本身（那正是第一版的缺陷形状：
  ///   「判定看平台、挂的是常量」两个真源）。本常量只是系数的**数值**，
  ///   谁是 TV 由 [effectiveTextScale] 说了算。
  static const double tvScale = 1.25;

  /// ★★ A1 的**唯一真源**：这台设备**实际**该用的字号系数
  ///
  /// # 为什么要单独有它（2026-10-04 缺陷修复）
  ///
  /// 第一版 A1 只判**平台**：
  /// ```dart
  /// switch (defaultTargetPlatform) {
  ///   TargetPlatform.android || TargetPlatform.fuchsia => tvScale,
  ///   _ => 1.0,
  /// }
  /// ```
  /// ⇒ **安卓手机也被 ×1.25**：手机上整套字大了一档，而放大字号的两个理由
  /// （10 英尺原则 / 沙发距离）在手机上一条都不成立。
  ///
  /// 平台只是**必要**条件 —— 安卓上既可能是 TV 也可能是手机，真正区分它们的是
  /// [Device.isTv]（`sourin/device` 通道读 `android.software.leanback` /
  /// `FEATURE_TOUCHSCREEN`，见 `lib/core/device.dart:273-301`）。
  /// 所以条件是**两个都要**：平台 ∈ {android, fuchsia} **且** [Device.isTv]。
  /// 桌面端（`TargetPlatform.windows` 等）恒 1.0 —— 一个像素都不变。
  ///
  /// # 为什么这里敢用 [Device.isTv]（第一版注释说不敢，那两条前提已不成立）
  ///
  /// 1. `Device.init()` 在 `runApp` **之前** await 完成（`lib/shell.dart` 的
  ///    `main()`）⇒ TV 上首帧 [Device.isTv] 就已经是 true，
  ///    **不会**先按 1.0 画一帧再跳 1.25。
  /// 2. `flutter test` 里 `defaultTargetPlatform` 被**强制**成
  ///    `TargetPlatform.android`（SDK `foundation/_platform_io.dart` 的
  ///    `FLUTTER_TEST` 分支）⇒ 只判平台的写法在测试里**恒**走放大分支；
  ///    加上 [Device.isTv] 这道门之后，`Device.overrideKind(DeviceKind.tv)`
  ///    才是放大 ⇒ 这条分支**变成可断言的了**（`test/a1_tv_text_scale_test.dart`）。
  ///
  /// ⚠️ 这是**唯一**真源：[cardTextScale] 与 `lib/shell.dart` 的 `_TextScaleHost`
  ///    都必须引用它，**不许各写一份**（分叉了就会像第一版那样只在手机上露馅）。
  static double get effectiveTextScale {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.fuchsia) {
      return 1.0;
    }
    return Device.isTv ? tvScale : 1.0;
  }

  /// 卡片**文字**区的整体缩放 —— TV ×1.25，其余 1.0
  ///
  /// # 为什么必须有它（不做的话 TV 上必然溢出）
  /// 字号被 `TextScaler` 放大后，**文字本身需要的行高也变大了**：
  /// ```text
  /// 标题两行 16px×1.35×2 = 43.2  →  20px×1.35×2 = 54.0
  /// 副标题    12px        = 12.0  →   15px       = 15.0
  /// ```
  /// 而承载高度 `railHeight(titleLines: 2)` 若不变，卡片内容就会
  /// **超出 `SizedBox` 高度** ⇒ `RenderFlex overflowed`（TV 上一排海报被切）。
  /// ⇒ 承载高度与字号**必须同源缩放**（这也正是本文件 :221 那句
  ///   「两者不要互相引用」的反面：字号与**文字区高度**是一件事，
  ///   与「每行张数」才是两件事）。
  ///
  /// ★ 直接引用 [effectiveTextScale] —— 承载高度必须与**真正挂上去**的那个
  ///   `TextScaler` 同源。第一版这里自己写 `Device.isTv ? tvScale : 1.0`，
  ///   而挂上去的看平台 ⇒ 手机上是「文字大了、承载高度没大」的错配。
  static double get cardTextScale => effectiveTextScale;

  /// 标题**单行**高度 —— 原版 `line-height: 1.35` × 16px = 21.6
  ///
  /// 依据 `D:\WishProject\cctv_to_client\src\design\base.css:844-854`：
  /// ```css
  /// .poster-meta__title { font-size: var(--fs-base); line-height: 1.35; }
  /// ```
  static const double posterTitleLine = FontSizes.base * 1.35;

  /// 标题区里**除标题本身**之外的高度（`Sp.x2` 间距 8 + 副标题 cap 12 + 上间距 2 + 余量）
  ///
  /// ★ 取值让「单行标题」回到历史上那个 `44`：`22.4 + 21.6 × 1 = 44.0`
  ///   ⇒ 所有未显式传 `titleLines` 的调用点**逐位不变**（零回归）。
  static const double posterMetaOther = 22.4;

  /// 海报卡片「标题 + 副标题」区的高度
  ///
  /// # 为什么要有这个函数（而不是到处写 `+ 44`）
  /// 原版 `.poster-meta` 的高度是**固定**的 `--poster-meta-h: 62px`
  /// （`base.css:834-842`，`overflow:hidden`），标题 `-webkit-line-clamp: 2`
  /// 注释逐字写着「固定两行：标题长短不一时卡片仍对齐（大厂列表的通用做法）」。
  /// 也就是说：**一行的标题也占两行的高度** ⇒ 卡片底边永远对齐。
  ///
  /// ⚠️ 启用两行时必须**同时**改承载高度，否则标题被裁：
  ///   `railHeight(titleLines: 2)` / `childAspectRatio` 用本函数。
  static double posterMetaHeight({int titleLines = 1}) =>
      (posterMetaOther + posterTitleLine * titleLines) * cardTextScale;

  /// 卡片轨道高度（海报高度 + ��题区高度）
  ///
  /// ⚠️ `titleLines` 必须与调用点传给 [PosterCard.titleLines] 的值**相同**，
  ///    否则标题要么被裁、要么卡片下方露白。
  static double railHeight({double scale = 1, int titleLines = 1}) =>
      posterWidth / posterAspect * scale +
      posterMetaHeight(titleLines: titleLines);
}

/// 内容带布局 —— 原版 `src/design/base.css` 的 `.container` + `.grid` 等价式
///
/// # 为什么必须单独一个类（而不是套一层 `Center`/`ConstrainedBox`）
/// ```text
/// 原版 CSS：
///   .container { width:100%; max-width: var(--content-max-w); margin:0 auto;
///                padding: 0 var(--sp-6) }        ← 原版：1440px 上限 + 居中 + 24px 内边距
///   @media (max-width:640px){ .container{ padding: 0 var(--sp-4) } }  ← 断点切 16px
///   .grid { grid-template-columns: repeat(auto-fill,
///             minmax(calc(var(--poster-w) - 16px), 1fr)) }            ← 列宽下限 152px
/// ```
/// Flutter 侧**没有** `max-width`：滚动视口会吃掉一切宽松的交叉轴约束
/// （`RenderViewport.sizedByParent == true`，见 SDK `rendering/viewport.dart`），
/// 所以「外层套 `Center`/`ConstrainedBox`」是**空操作** —— 宽度必须在滚动体
/// **内部**、在每个自带左右内边距的节点上算成
/// `side = (窗口宽 - bandFor(窗口宽)) / 2 + 断点内边距`。
///
/// ★ 2026-10-04（业主原话：「放大之后两侧留白过多，改为两侧占满吧」）：
///   [bandFor] 不再封顶 ⇒ 上式里的 `side` **恒为 0**，整条式子退化成
///   「只有断点内边距」。式子、[sideInsetForWindow] 与全部调用点都**保留**，
///   是为了将来若要恢复居中只需改 [bandFor] 一处。
///
/// # A/B 开关
/// `bool.fromEnvironment` 是**编译期常量**，所以 `--dart-define=LAYOUT_AB=legacy`
/// 能在**同一份源码**上产出一个「旧布局行为」的二进制，供 before/after 对比探针
/// 使用；不传时默认 `fixed`（新行为）。⚠️ 这是**编译期**分支，两条臂是两个 exe。
abstract final class Layout {
  /// `--dart-define=LAYOUT_AB=legacy` ⇒ true（不传 = `fixed`）
  ///
  /// ⚠️ 用 `String.fromEnvironment` 而不是 `bool.fromEnvironment`：
  ///    后者的 `defaultValue` 是 **bool**，塞不进 `fixed` 这种字符串
  ///    （第一版就是这么写错的：`const_eval_throws_exception` 直接编译失败）。
  ///    两者都是**编译期常量**，A/B 分臂的效果一样。
  static const String ab = String.fromEnvironment(
    'LAYOUT_AB',
    defaultValue: 'fixed',
  );

  static const bool legacy = ab == 'legacy';

  /// 原版 `--content-max-w: 1440px`。
  ///
  /// ★ 2026-10-04（业主：放大之后两侧留白过多，改为两侧占满）：`bandFor` 不再套这个上限，
  ///   `sideInsetForWindow` 恒返回 0 ⇒ **生产代码已不再引用本常量**。
  ///   保留它只是为了留下原版数值（日后若恢复封顶可直接用），不要在当代代码里引用它。
  static const double contentMaxWidth = 1440;

  /// 原版 `@media (max-width: 640px)`
  static const double narrowBreakpoint = 640;

  /// 列数下界 —— 1 列就是 Owner 投诉的「一行一个」
  static const int minColumns = 2;

  /// 列数上界 —— 防超宽屏一行几十张
  static const int maxColumns = 12;

  /// 宽档单元格宽度下限 = `var(--poster-w)`(168) - 16 = 152
  static const double minCellWide = 152;

  /// 窄档单元格宽度下限（原版 640px 断点后的 112px）
  static const double minCellNarrow = 112;

  /// TV 档单元格宽度下限 —— 原版 TV 块的 `--poster-w: 216px`（`tokens.css:461`）
  /// 减去与宽档同源的 16px（`minmax(calc(var(--poster-w) - 16px), 1fr))`）⇒ 200。
  ///
  /// ⚠️ 216 而不是桌面档的 168：Owner 在 `tokens.css:460` 逐字写着
  ///    「② 卡片放大（168 → 216，保持 2:3）」—— TV 上卡片**本来就要更大**。
  static const double minCellTv = 200;

  /// TV 档列间距 —— 原版 TV 块的 `--poster-gap: 20px`（`tokens.css:462`）
  static const double gapTv = Sp.x5;

  /// 内容带宽度 = **窗口宽**（不再套 1440 上限）
  ///
  /// ★★ 2026-10-04 改动（Owner 原话：「放大之后两侧留白过多，改为两侧占满吧」）
  ///   旧行为：`min(窗口宽, 1440)` + 两侧居中 ⇒ 2560px 窗口每侧留 **560px** 空白。
  ///   现行为：恒等于窗口宽 ⇒ 两侧占满。语义与 TV 档一致
  ///   （原版 `tokens.css:477-481` `:root[data-tv] .container{max-width:none}`）。
  ///   ⚠️ 两条臂（legacy / fixed）**都不再封顶** ⇒ 宽屏上几何结果相同，
  ///      只剩「每行张数怎么算」的差别（旧式 `usable/(148+12)` vs 新式 `minmax(152,1fr)`）。
  static double bandFor(double windowWidth) {
    // ★ TV **不套**上限 —— 原版 `tokens.css:477-481`
    //   `:root[data-tv] .container { max-width: none }`：
    //   电视前没有「居中留白更好看」这回事，留白只会把内容挤成中间一条。
    if (legacy || Device.isTv) return windowWidth;
    return windowWidth;
  }

  /// 这个内容带是否走 640px 断点的窄档
  static bool isNarrow(double band) {
    if (legacy) return false;
    // ★ TV 不走这个断点：原版 TV 块（`tokens.css:460-472`）把
    //   `--poster-w` / `--poster-gap` 整体换了一套，与 640px 无关。
    if (Device.isTv) return false;
    return band <= narrowBreakpoint;
  }

  /// 内容带**两侧各自**的内边距（CSS `.container` 的 padding）
  static double paddingFor(double band) {
    if (Device.isTv) return tvPaddingFor(band);
    return isNarrow(band) ? Sp.x4 : AppMetrics.contentPadding;
  }

  /// TV 档的内容带两侧内边距 = `max(--sp-6, 5vw)`
  ///（原版 `:root[data-tv] .container` 的 `--tv-safe-x: 5vw`
  ///  与 `padding-left: max(var(--sp-6), var(--tv-safe-x))`）。
  static double tvPaddingFor(double band) {
    final safe = band * 0.05;
    return safe > AppMetrics.contentPadding ? safe : AppMetrics.contentPadding;
  }

  /// 内容带居中所需的外边距（CSS `margin: 0 auto` 的等价物）
  ///
  /// ★ 2026-10-04：内容带不再封顶 ⇒ 本函数**恒返回 0**（两侧占满）。
  ///   保留函数与全部调用点，是为了将来若要恢复居中只需改这一处。
  ///
  /// ⚠️ TV **不做**上限 —— 原版 `tokens.css:477-481` 明确写了
  ///    `:root[data-tv] .container { max-width: none }`：
  ///    电视前没有"Margin 留白更好看"这回事，留白只会把内容挤到中间一条。
  static double sideInsetForWindow(double windowWidth) {
    if (legacy || Device.isTv) return 0;
    final band = bandFor(windowWidth);
    final side = (windowWidth - band) / 2;
    return side > 0 ? side : 0;
  }

  /// ★★「居中」为什么用**外层 `Padding`**，而不是套 `Center`/`ConstrainedBox`
  ///
  /// ```text
  /// Center / Align / ConstrainedBox → 子件收到的是 **loose** 约束，
  ///   maxWidth 仍是整窗宽 ⇒ RenderViewport.sizedByParent == true
  ///   （SDK rendering/viewport.dart:1676）取 constraints.biggest
  ///   ⇒ 视口仍是整窗宽 ⇒ **空操作**。
  ///
  /// Padding(horizontal: side)    → 先把 maxWidth **减掉 2*side** 再传下去，
  ///   视口拿到的 biggest 就是内容带宽度 ⇒ 真的变窄 ✓
  ///   （★ 2026-10-04 起 `side` 恒为 0 ⇒ 逐字节等于改动前的树）
  /// ```
  ///
  /// ⚠️ `CustomScrollView` **没有** `padding` 参数
  ///    （SDK `widgets/scroll_view.dart:722-747` 里只有 `slivers:`）
  ///    ⇒ browse / search 这两个 `CustomScrollView` 页面只能用**外层 `Padding`**；
  ///    `ListView` 页面（follow）则直接用 `padding.add(sideInsetOf(..))`。

  /// [sideInsetForWindow] 的取宽糖（给 `ListView` 那类自带上下 padding、
  /// 只需要补左右居中的滚动体）
  static EdgeInsets sideInsetOf(BuildContext context) => EdgeInsets.symmetric(
    horizontal: sideInsetForWindow(MediaQuery.sizeOf(context).width),
  );

  /// 内容带**内**的左右内边距（原版 `.container { padding: 0 var(--sp-6) }`
  /// 与 `@media (max-width:640px){ padding: 0 var(--sp-4) }`）——
  /// 即"每个自带左右内边距的 sliver/子件"该用的那一个。
  static EdgeInsets contentInsetForWindow(double windowWidth) =>
      EdgeInsets.symmetric(horizontal: paddingFor(bandFor(windowWidth)));

  /// [contentInsetForWindow] 的取宽糖 —— 省掉每个调用点自己写 `MediaQuery`
  static EdgeInsets contentInsetOf(BuildContext context) =>
      contentInsetForWindow(MediaQuery.sizeOf(context).width);

  /// 「**居中 + 容器内边距**」的完整横向内边距 —— 给**没有 `padding:` 参数**
  /// 的滚动根用（`CustomScrollView` 是唯一一种）。
  ///
  /// 语义 = CSS `margin: 0 auto` + `.container { padding: 0 var(--sp-6) }` 的**合并结果**，
  /// 也就是「一个自带横向内边距的滚动体」该用的那一个。
  ///
  /// ⚠️ 别把它和 [contentInsetOf] 混用：
  /// ```text
  /// 页面根（扮演 `.container`）        → horizontalInsetOf   （居中 + 内边距）
  /// 页面内**自带**横向内边距的子件     → contentInsetOf      （只有内边距）
  /// ```
  /// 两者**不能叠加**在同一个子件上（那就是 ×2，只有原版 `.section__rail`
  /// 那种「容器的子元素自己也带 `--sp-6`」的嵌套元素才该拿 ×2）。
  ///
  /// ★ 真浏览器权威读数（`.probe/_m4_readings.txt`，引出厂 dist CSS）：
  /// ```text
  /// d1904  container padL=24px  → secItem l=280   mineItem l=256
  /// tv1904 container padL=95.2  → secItem l=119.19 mineItem l=95.19
  /// tv960  container padL=48    → secItem l=72     mineItem l=48
  /// n500   container padL=16    → secItem l=32     mineItem l=16
  /// ```
  static EdgeInsets horizontalInsetOf(BuildContext context) =>
      horizontalInsetForWindow(MediaQuery.sizeOf(context).width);

  /// 只要"一个数"的调用点用（例如 `EdgeInsets.fromLTRB` 里只改左右）
  static double contentPaddingOf(BuildContext context) =>
      paddingFor(bandFor(MediaQuery.sizeOf(context).width));

  /// ★★ **第二层**（分区标题 `.section__head` / 海报轨道 `.section__rail`）
  /// 的横向内边距 —— 与容器层**不同源**，不能复用 [contentPaddingOf]。
  ///
  /// 原版里这一层是元素自带的：
  /// ```text
  /// .section__head { padding: 0 var(--sp-6) }   // base.css:867-874
  /// .section__rail { padding: 0 var(--sp-6) var(--sp-2) }  // base.css:906-915
  /// @media (max-width:640px) ⇒ var(--sp-4)      // base.css:877 / :918
  /// ```
  /// ⇒ 恒为 `--sp-6`(24) / 窄档 `--sp-4`(16)，**TV 上不放大**。
  ///
  /// ⚠️ 为什么不能用 [contentPaddingOf]：那个函数 = [paddingFor]，在 TV 上走
  ///    [tvPaddingFor]（`max(24, 5vw)` ⇒ TV@960 得 **48**），于是
  ///    48(容器) + 48(轨道) = **96dp = 192px**。真机实测（t510 首测）就是这个
  ///    数，目标 144px。m4 真浏览器读数（`.probe\_m4_readings.txt`）：
  /// ```text
  /// d1904  containerPadL=24    → secItem l=280     (= 232 + 24 + 24)
  /// tv1904 containerPadL=95.2  → secItem l=119.19  (= 95.2 + 24)
  /// tv960  containerPadL=48    → secItem l=72      (= 48 + 24)
  /// n500   containerPadL=16    → secItem l=32      (= 16 + 16)
  /// ```
  ///    注意 `secHeadPadL` / `secRailPadL` 四档**都是 24**（TV 也不例外）。
  static double railPaddingFor(double band) => isNarrow(band) ? Sp.x4 : Sp.x6;

  /// [railPaddingFor] 的 context 版（只跟窄档有关；TV 也是 24，不是 5vw）
  static double railPaddingOf(BuildContext context) =>
      railPaddingFor(bandFor(MediaQuery.sizeOf(context).width));

  /// 自带左右内边距的 sliver：**完整**水平内边距（外边距 + 内边距）
  static EdgeInsets horizontalInsetForWindow(double windowWidth) =>
      EdgeInsets.symmetric(
        horizontal:
            sideInsetForWindow(windowWidth) + paddingFor(bandFor(windowWidth)),
      );

  /// 内容带内的**真实内容宽**（= CSS `.grid` 所在容器的宽度）
  static double innerWidthFor(double band) {
    if (legacy) return band - AppMetrics.contentPadding * 2;
    return band - paddingFor(band) * 2;
  }

  /// 列间距（宽档对齐 `--poster-gap: 16px`，窄档 `--sp-3: 12px`）
  static double gapFor(double band) {
    if (Device.isTv) return gapTv;
    return isNarrow(band) ? Sp.x3 : Sp.x4;
  }

  /// ★ 由**内容带宽度**算列数 —— 等价 CSS `repeat(auto-fill, minmax(minCell, 1fr))`
  ///
  /// ⚠️ 入参是**内容带宽度**（`bandFor(窗口宽)`，★ 2026-10-04 起**恒等于窗口宽**），**不是**已经减过内边距的宽度：
  ///    减内边距这一步在函数内部做，**只做一次**（task-74⑤ 那个双重相减的坑）。
  static int columnsForBand(double band) {
    if (legacy) {
      final usable = band - AppMetrics.contentPadding * 2;
      final n = (usable / (AppMetrics.posterWidth + Sp.x3)).floor();
      return n < minColumns ? minColumns : (n > maxColumns ? maxColumns : n);
    }
    final inner = innerWidthFor(band);
    final minCell = Device.isTv
        ? minCellTv
        : (isNarrow(band) ? minCellNarrow : minCellWide);
    final gap = gapFor(band);
    final n = ((inner + gap) / (minCell + gap)).floor();
    return n < minColumns ? minColumns : (n > maxColumns ? maxColumns : n);
  }

  /// 单元格宽度 —— 与 `columnsForBand` 同源，调用方不要再自己减内边距
  static double cellWidthFor(double band, int columns) {
    final inner = innerWidthFor(band);
    if (columns < 1) return inner;
    return (inner - gapFor(band) * (columns - 1)) / columns;
  }
}

/// 语义化颜色 —— 从 forui 主题取，这里只做"角色 → forui 色"的映射说明
///
/// # 为什么不自己定一套颜色
///
/// Owner 选了 forui 作为 UI 库，主题（深浅色、色板）应由 forui 管。
/// 我们只决定「哪个角色用哪个色」：
/// ```text
/// 正文        FTheme.colors.foreground
/// 次要文字     FTheme.colors.mutedForeground
/// 卡片底      FTheme.colors.card
/// 边框        FTheme.colors.border
/// 主色（选中） FTheme.colors.primary
/// ```
/// 这样切换 forui 主题（将来可能加浅色）时整个应用自动跟随。
abstract final class AppColors {
  /// 未读徽章底色（原版是品牌红）
  static const Color badge = Color(0xFFE5484D);

  /// 直播"正在播"的圆点
  static const Color liveDot = Color(0xFFE5484D);

  /// 海报占位底色（图未加载时）—— **前景色的 5%**
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 为什么是"前景色的 5%"而不是一个固定色值（task-37）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// 用户原话：
  /// > 切换首页的时候图片从**黑色占位**再变成图片  **体验割裂**
  ///
  /// # 修之前错在哪
  ///
  /// ```dart
  /// static const Color posterPlaceholder = Color(0xFF23262E);  // 旧的
  /// ```
  /// 一个**硬编码的深色**。它在深色主题下勉强能看（背景 #0A0A0A），
  /// 但用户的实际设置是 `"dsh.theme":"system"` + 系统浅色 ⇒
  /// 他看到的背景是 `LightTokens.bgBase = #EEF0F6`（很浅的灰蓝），
  /// 而占位块是 `#23262E`（近黑）——
  /// ```text
  /// 对比度 ≈ 12:1  ⇒ 一块**非常显眼的深色方块**
  /// ```
  /// 图片淡入时就是"深色方块 → 彩色海报"，正是用户说的"割裂"。
  ///
  /// # 原版怎么做（`src/design/base.css` + `theme-light.css`）
  ///
  /// 原版**从不硬编码占位色**，用的是**同一个规则的两个实例**：
  /// ```css
  /// /* 深色（默认）—— base.css:734 */
  /// .poster { background: rgb(255 255 255 / 0.05); }
  ///
  /// /* 浅色 —— theme-light.css:220 */
  /// :root[data-theme="light"] .poster { background: rgb(16 18 26 / 0.05); }
  /// ```
  /// ★ 两个都是 **5%**，只是"叠在什么上面"不同：
  /// ```text
  /// 深色：白 5% 叠 #0A0A0A → ≈ #161616   比背景**略亮**
  /// 浅色：黑 5% 叠 #EEF0F6 → ≈ #E3E5EB   比背景**略深**
  /// ```
  /// ⇒ **两个主题下占位与背景都只差 5%** —— 这才是"不割裂"的机制：
  ///   占位块几乎融进背景，用户看到的是「背景 → 图片」而不是「色块 → 图片」。
  ///
  /// # 为什么用"前景色 5%"能一条规则管两个主题
  ///
  /// ```text
  /// 深色主题：onSurface = 浅色（近白）⇒ 5% 白 叠深底  ⇒ 略亮 ✓
  /// 浅色主题：onSurface = 深色（近黑）⇒ 5% 黑 叠浅底  ⇒ 略深 ✓
  /// ```
  /// 「前景色」在两个主题下**天然是"与背景相反"的那个方向**，
  /// 所以不需要 `if (brightness == dark)` 分支 ——
  /// 这正是原版只写两条 CSS 就够用的原因。
  ///
  /// ⚠️ 用法必须是 `colors.onSurface.withValues(alpha: ...)`，
  ///    **不能**把它当成一个可以直接画的 `Color`（见下）。
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 与「结构修复」的关系 —— 两个修复**不互相替代**（务必读懂）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// 用户原话里还有一句关键的反问：
  /// > 首页不是占位颜色太深，**不是加的有缓存吗**？怎么切换还会这个样子
  ///
  /// ★ 用户的直觉**完全正确** —— 封面确实在缓存里。完整因果链：
  ///
  /// ```text
  /// ① shell.dart:2264-2280
  ///      AnimatedSwitcher(child: KeyedSubtree(key: ValueKey(_tab), ...))
  ///    ⇒ 切 tab 换 key ⇒ 旧子树被**整个销毁**（没有 IndexedStack 保活）
  ///
  /// ② 切回首页 ⇒ **新的** _HomePageState
  ///      home_page.dart:188-192
  ///        initState → loadAll(force: true)
  ///    ⇒ 卡片用新数据**重建** ⇒ PosterCard._loaded 归零
  ///
  /// ③ 封面 URL 是**稳定**的，所以图确实在 ImageCache 里
  ///      rust/sourin_core/src/streamproxy.rs:312-320
  ///        // 已登记过 → 复用同一个 token（这是保住浏览器缓存的关键）
  ///        if let Some(t) = idx.get(url).cloned() { return .../s/{t}; }
  ///    ⇒ 但 PosterCard 是**新对象**，`_loaded=false` 从零开始
  /// ```
  /// ⇒ ★★ **缓存救得了字节，救不了 State。**
  ///
  /// # 所以两个修复各治一段，都要做
  ///
  /// ```text
  /// 结构修复（shell.dart 保活）：让"切回来"不再重建
  ///   → 占位态**不再每次切换都出现**（治本）
  ///
  /// 颜色修复（本常量）：让"占位态真的出现时"不再是一块深色方块
  ///   → ★ **首次进首页**永远会经历一次真实冷加载（ImageCache 是空的），
  ///     那时占位色仍然会被用户看到 ⇒ 这一段结构修复**管不到**
  /// ```
  ///
  /// # ★ 原版早就写过这条教训（`src/App.vue:345-356`）
  ///
  /// ```text
  /// ⚠️ **不能用「给组件换 key 触发重挂载」的办法** ——
  /// 那会与 keep-alive 直接冲突（换 key = 新组件实例 = 保活白做，
  /// 滚动位置与内部状态全丢）。正确做法是：
  ///   - 数据层用缓存 TTL（见 `api/cache.ts`）保证新鲜度
  ///   - 「我的」区块自己监听路由变化去重取（见 MyShelf）
  /// ```
  /// ★ 原版用的是 `keep-alive` + **数据层 TTL**；
  ///   而我们（`shell.dart:2265`）正是原版明确警告的"换 key 触发重挂载"。
  static const double posterPlaceholderAlpha = 0.05;
}
