// ═══════════════════════════════════════════════════════════════════════
//  设备能力检测与 TV 适配 —— 对应原版 src/design/device.ts
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须做这个
//
// 契约文件（INTERACTION-CONTRACT.md §二）记录了一个**真机测出来的 bug**：
//
// > 实测发现（TV 真机，adb 方向键）——
// > 「发现 / 直播 / 追更 / 搜索 / 设置」，TV 上等于困死在一个页面。
//
// 意思是：应用能在 TV 上启动、能显示界面，但**用户无法切换页面** ——
// 因为没有鼠标，而底栏只响应点击。这等于整个应用不可用。
//
// # 原版的判定逻辑（必须一致）
//
// 原版注释记录了三次真机实测，纠正了两个**错误假设**：
//
// ```text
// 错误假设 ①：「TV 会报告 pointer: coarse」
//   → 真机是 coarse=false。所以不能用 coarse 判 TV。
//
// 错误假设 ②：「TV 的 UA 不含 Mobile」
//   → 真机 UA 结尾**确实有** Mobile：
//     Mozilla/5.0 (Linux; Android 11; AOSP TV on x86 Build/...; wv)
//       AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0
//       Chrome/90.0.4430.91 Mobile Safari/537.36
//   → 靠它判 TV 会永远失败。
// ```
//
// 真正能区分的特征（三级真机实测）：
//
// ```text
//            hover   coarse   fine
// 桌面         true    false    true      → 有鼠标
// 手机         false   true     false     → 粗指针（手指）
// TV           false   false    true      → ★ 精确但无悬停 = 遥控器
// ```
//
// 遥控器的方向键是**精确**的（能逐项移动焦点），但**不能悬停**
// （没有指针停在元素上这回事）。这个组合只有 TV 有。
//
// # Flutter 侧的差异（诚实说明）
//
// 原版跑在 WebView 里，能用 `window.matchMedia("(hover: hover)")`
// 这类 CSS 媒体查询。**Flutter 没有等价 API** —— 拿不到
// `hover` / `pointer: fine/coarse` 这些能力位。
//
// 所以 Flutter 侧只能用**间接判据**：
// ```text
// ① Android 上读系统 feature（leanback / touchscreen）—— 最准
// ② UA 标志词（部分设备）
// ③ 兜底：Android + 无触摸 + 大屏 → 当作 TV
// ```
// ① 需要平台通道（写 Kotlin）。本轮先做 ② + ③，
// 并在文档里标明 ① 是后续要补的。

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// TV 常见 UA 标志词（与 `device.ts` 的 `TV_UA_MARKERS` 一致）
///
/// ⚠️ 大小写敏感，按原样匹配 —— 原版注释强调过这一点。
const kTvUaMarkers = <String>[
  'TV', // AOSP TV / MiTV / Android TV / GoogleTV —— 真机命中
  'AFT', // Amazon Fire TV
  'BRAVIA', // Sony
  'SHIELD', // NVIDIA
  'ATV', // 部分盒子
  'GoogleTV',
  'AppleTV',
];

/// 设备类型
enum DeviceKind {
  /// 桌面（有鼠标键盘）
  desktop,

  /// 触屏（手机 / 平板）—— 没有键盘鼠标
  touchOnly,

  /// 电视（遥控器操作）
  tv,
}

/// 设备能力
///
/// # 为什么不用 `kIsDesktop` 那种简单常量
///
/// `kIsDesktop` 只区分「是不是桌面操作系统」，而这里要区分的是
/// **交互形态**：
/// ```text
/// Android 平板  → platform=android，但用**触摸**布局
/// Android TV    → platform=android，但用**遥控**布局
/// ```
/// 两者平台相同、交互完全不同。所以需要独立判定。
class Device {
  Device._();

  static DeviceKind? _cached;

  /// 当前设备类型（带缓存 —— 判定要读平台通道，不该每帧做）
  static DeviceKind get kind => _cached ??= _detect();

  /// ★ 启动时调用：用平台通道**异步**确定设备类型
  ///
  /// # 为什么需要单独一个初始化步骤（2026-09-22 在 Android TV 上踩到）
  ///
  /// `kind` 是同步 getter，拿不到平台通道的结果 —— 所以它只能走
  /// 兜底启发式，在 Android TV 上会**误判成 touchOnly**：
  /// ```text
  /// Android 上拿不到 userAgent（Flutter 没有这个 API）
  ///   → _detect() 落到最后的 return DeviceKind.touchOnly
  ///   → Device.isTv == false
  ///   → 焦点环不画、字号不放大
  ///   → ★ 更糟：showsHints == false，**TV 上看不到遥控器提示**
  /// ```
  /// 最后一条最严重：TV 用户最需要知道遥控器怎么操作，却什么都看不到。
  ///
  /// # 用法
  ///
  /// 在 `runApp` 之前 await 一次：
  /// ```dart
  /// WidgetsFlutterBinding.ensureInitialized();
  /// await Device.init();
  /// runApp(...);
  /// ```
  /// 这样首帧就是正确的设备布局（避免先按手机画再跳成 TV 的抖动 ——
  /// 大屏上那种闪动非常明显，原版注释也强调过）。
  static Future<void> init() async {
    if (_cached != null) return;
    try {
      final k = await detectViaPlatform();
      if (k != null) {
        _cached = k;
        /*
         * 打印**派生值**而不只是类型 —— 这些才是真正影响渲染的开关。
         *
         * 加这行的原因：TV 适配的样式（字号/焦点环/提示区块）都挂在
         * 这几个派生值上。只报 "tv" 不能证明样式生效 ——
         * 万一某个 getter 写错，类型对而样式不对，光看类型看不出来。
         */
        debugPrint('[DEVICE] 平台通道判定: ${k.name}');
        debugPrint('[DEVICE] isTv=$isTv touchOnly=$isTouchOnly '
            'showsHints=$showsHints needsFocusRing=$needsFocusRing '
            'textScale=$textScale safeArea=$safeAreaHorizontal');
        return;
      }
    } catch (e) {
      debugPrint('[DEVICE] 平台通道不可用: $e');
    }
    // 通道不可用 → 用兜底启发式（桌面上本来就正确）
    _cached = _detect();
    debugPrint('[DEVICE] 兜底判定: ${_cached!.name}');
  }

  /// 是否电视（遥控器操作）
  static bool get isTv => kind == DeviceKind.tv;

  /// 是否只有触摸输入（手机 / 平板）
  static bool get isTouchOnly => kind == DeviceKind.touchOnly;

  /// 是否桌面
  static bool get isDesktop => kind == DeviceKind.desktop;

  /// ★ 是否显示「操作提示」区块
  ///
  /// # Owner 的明确要求
  ///
  /// > 「播放详情页的 提示，在手机端根本没必要」
  ///
  /// 原版 `device.ts` 的分工：
  /// ```text
  /// 手机端：**完全没有**（没键盘，列出来纯占空间）
  /// TV 端：  有，但必须是**遥控器键位**（方向键/Enter/Back）
  /// 桌面端：  原有的键盘键位
  /// ```
  static bool get showsHints => !isTouchOnly;

  /// ★ 是否需要「焦点可见」的样式
  ///
  /// TV 上没有鼠标悬停 —— 焦点是**唯一**的位置指示。
  /// 所以 TV 上所有可交互元素都必须有可见的焦点态。
  static bool get needsFocusRing => isTv;

  /// TV 的字号缩放（10 英尺原则）
  ///
  /// 原版草稿要求：正文 16→20、标题→25、卡片 168→216，整体 ×1.25。
  /// 沙发到电视的距离约 3 米，正常字号的 16px 在这个距离上读不清。
  static double get textScale => isTv ? 1.25 : 1.0;

  /// 安全区（电视 overscan）
  ///
  /// 老电视会把画面边缘裁掉 3~5%，所以内容要往里收。
  static double get safeAreaHorizontal => isTv ? 0.05 : 0.0;

  static DeviceKind _detect() {
    // ── ① 非 Android 平台直接判定 ──
    if (!Platform.isAndroid) {
      return DeviceKind.desktop;
    }

    // ── ② UA 标志词 ──
    //
    // ⚠️ Dart 侧拿 UA 的方式与 WebView 不同。Flutter 没有直接 API，
    //    所以这条在 Flutter 里**通常拿不到** —— 保留它是为了
    //    将来接平台通道时能直接用（原版的判据要保持可追溯）。
    final ua = _userAgentOrNull();
    if (ua != null && kTvUaMarkers.any(ua.contains)) {
      return DeviceKind.tv;
    }

    // ── ③ 兜底启发式 ──
    //
    // 拿不到 UA、也没有平台通道时，只能粗略判断。
    // Android 上「没有触摸屏」通常就是 TV —— 但**本方法无法区分**，
    // 所以默认按触摸设备处理（对手机/平板是正确的，对 TV 会退化成
    // 「能点但方向键未必可用」）。
    //
    // ⚠️ 这是**已知的不足**，不是设计如此。正确做法见
    //    `TvDetector`（需要 Kotlin 侧配合）。这里先保证：
    //    手机上行为正确 + 提示区块正确隐藏。
    return DeviceKind.touchOnly;
  }

  /// 尝试拿 UA（Flutter 没有稳定 API，拿不到就返回 null）
  ///
  /// 不抛异常：拿不到 UA 是**预期情况**，不是错误。
  static String? _userAgentOrNull() {
    try {
      // 部分平台（如 Flutter Web 或装了特定插件）会暴露这个常量。
      // 原生 Android 上没有 —— 返回 null 让上层走兜底。
      const ua = String.fromEnvironment('DEVICE_USER_AGENT', defaultValue: '');
      return ua.isEmpty ? null : ua;
    } catch (_) {
      return null;
    }
  }

  /// 用原生 feature 精确判定 TV（需要平台通道）
  ///
  /// # 为什么这个方法比 `kind` 更可靠
  ///
  /// Android 有明确的系统 feature：
  /// ```text
  /// android.software.leanback   → 设备是 TV（有遥控器）
  /// android.hardware.touchscreen → 设备有触摸屏
  /// ```
  /// 读它们比猜 UA 准得多。
  ///
  /// # 用法
  ///
  /// 需要在 Android 侧注册一个 `MethodChannel`，用
  /// `PackageManager.hasSystemFeature()` 实现。
  /// 本轮未接（属于「需要写 Kotlin」的独立工作），
  /// 但接口先定下来，接上后 `kind` 就能自动变准。
  ///
  /// ```kotlin
  /// // MainActivity.kt 里加：
  /// MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sourin/device")
  ///   .setMethodCallHandler { call, result ->
  ///     if (call.method == "features") {
  ///       val pm = packageManager
  ///       result.success(mapOf(
  ///         "leanback" to pm.hasSystemFeature("android.software.leanback"),
  ///         "touchscreen" to pm.hasSystemFeature("android.hardware.touchscreen"),
  ///       ))
  ///     }
  ///   }
  /// ```
  static Future<DeviceKind?> detectViaPlatform() async {
    if (!Platform.isAndroid) return DeviceKind.desktop;
    try {
      const ch = MethodChannel('sourin/device');
      final r = await ch.invokeMethod<Map<dynamic, dynamic>>('features');
      if (r == null) return null;
      final leanback = r['leanback'] == true;
      final touch = r['touchscreen'] == true;

      /*
       * 判定顺序（对应原版 device.ts 的分支）
       *
       * ```text
       * ① leanback=true        → TV（这是 TV 的定义）
       * ② 没有触摸屏           → TV（盒子通常也不声明 leanback，
       *                          但没有触摸屏这点足够说明问题）
       * ③ 有触摸屏             → 手机/平板
       * ```
       * ⚠️ ② 必须在 ③ 之前 —— 顺序反了会把 TV 判成手机
       *    （原版注释明确记录了「必须先排除 TV 否则会误判」）。
       */
      if (leanback) return DeviceKind.tv;
      if (!touch) return DeviceKind.tv;
      return DeviceKind.touchOnly;
    } catch (_) {
      // 通道没注册（本轮就是这样）→ 交给上层兜底
      return null;
    }
  }

  /// 允许测试/诊断时强制覆盖
  @visibleForTesting
  static void overrideKind(DeviceKind? k) => _cached = k;
}

// ═══════════════════════════════════════════════════════════════════════
//  TV 操作提示（遥控器键位）
// ═══════════════════════════════════════════════════════════════════════

/// 一条操作提示
class HintItem {
  const HintItem(this.keys, this.text);

  /// 键位（渲染成 <kbd> 样式）
  final List<String> keys;

  /// 说明
  final String text;
}

/// 桌面：键盘快捷键（与 `device.ts` 的 `DESKTOP_HINTS` 一致）
const kDesktopHints = <HintItem>[
  HintItem(['空格'], '播放 / 暂停'),
  HintItem(['←', '→'], '快退 / 快进 5 秒'),
  HintItem(['J', 'L'], '±10 秒 · 双击左右侧同效'),
  HintItem(['0', '…', '9'], '跳转到百分比'),
  HintItem(['↑', '↓'], '音量 · M 静音 · 滚轮同效'),
  HintItem(['F'], '全屏 · P 画中画'),
  HintItem([',', '.'], '减速 / 加速'),
  HintItem(['N'], '下一集'),
];

/// TV：遥控器键位
///
/// 与桌面**不是同一套操作** —— 遥控器只有方向键 + 确认 + 返回，
/// 没有 J/L/数字/F 这些键。所以文案必须重写，不能照抄。
const kTvHints = <HintItem>[
  HintItem(['确认'], '播放 / 暂停'),
  HintItem(['←', '→'], '快退 / 快进 10 秒'),
  HintItem(['↑', '↓'], '音量'),
  HintItem(['返回'], '退出播放 / 返回上一页'),
];

/// 按当前设备取提示条目
///
/// 手机端返回**空列表** → 调用方直接不渲染（原版的 `getHints` 同此）。
List<HintItem> hintsFor({bool isLive = false}) {
  final src = Device.isTv
      ? kTvHints
      : Device.isTouchOnly
          ? const <HintItem>[]
          : kDesktopHints;
  if (!isLive) return src;

  /*
   * 直播不能快进/跳转 —— 列出来只会让人白试
   * （进度条本身也是禁用的，见 PlayerView 的说明）
   */
  return src
      .where((h) =>
          !h.text.contains('快退') &&
          !h.text.contains('百分比') &&
          !h.text.contains('减速'))
      .toList();
}
