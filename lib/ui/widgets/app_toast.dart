// ═══════════════════════════════════════════════════════════════════════
//  统一的 toast
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么自己写，而不是用 Material 的 SnackBar
//
// ```text
// SnackBar  只能挂在 ScaffoldMessenger 上 —— 而本项目有 5 个 tab 页 +
//           若干 push 出来的全屏页，各自带 Scaffold，且播放页是全屏视频。
//           ⇒ 「谁是当前 ScaffoldMessenger」这件事本身就不确定，
//           会偶发弹在错误的页面上。
// 手写 _Toast  四个页面各抄了一份（detail / follow / settings / settings\skip），
//           只能同时显示一条、样式四份、关不掉。
// ```
//
// 现在统一到这里：**一条 Overlay**（挂在 `MaterialApp.builder` 里，全路由可见），
// 支持多条堆叠、各自计时、可手动关闭。
//
// # 与旧版的差别（有意为之，Owner 的第 11 条「整体 ui 优化」）
//
// ```text
// 旧  黑底胶囊 @82%，2.4s 后消失，只有最后一条
// 新  跟随主题的浮层卡片；多条同时堆叠（新的在下面），
//     hover 时露出关闭按钮，键盘也能关（Esc / Tab 到关闭键回车）
// ```
//
// ⚠️ **刻意不做「进度条」**：计时条每帧重绘，在低端 Android TV 上是纯开销，
//    而 toast 本来就是几秒的信息。

import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../tokens.dart';

/// 挂在 `MaterialApp.builder` 里的 toast 宿主
///
/// 用法：`toastHost(child)` 包住 `builder` 的返回值即可。
class ToastHost extends StatelessWidget {
  const ToastHost({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      ToastDismissShortcut(child: AppToaster(child: child));
}

/// 一条 toast 的外观参数
@immutable
class AppToastStyle {
  AppToastStyle({this.icon, this.accent, this.actionLabel, this.onAction});

  /// 左侧图标（成功/错误语义用）
  final IconData? icon;

  /// 图标与边框的强调色
  final Color? accent;

  /// 右侧动作（如「重试」）
  final String? actionLabel;
  final VoidCallback? onAction;
}

/// 弹一条 toast
///
/// 调用方式和旧版一样简单：
/// ```dart
/// showAppToast(context, '已收藏');
/// ```
///
/// - [context] 用来找到 [AppToaster]；找不到就静默忽略（**不抛异常**）——
///   toast 是锦上添花，绝不该把调用方搞崩。
void showAppToast(
  BuildContext context,
  String message, {
  Duration duration = const Duration(milliseconds: 2600),
  AppToastStyle? style,
}) {
  AppToaster.maybeOf(context)?.show(message, duration: duration, style: style);
}

/// 最多同时显示几条
///
/// ⚠️ 不是「装饰」而是**防止刷屏**：某些失败路径会连着弹十几条
/// （比如批量操作里每一项都失败），那时前 5 条早已过期，占的却是最新信息。
const int _maxVisible = 4;

class AppToaster extends StatefulWidget {
  const AppToaster({required this.child, super.key});

  final Widget child;

  /// 找到当前可见的 toast 宿主；找不到返回 null（调用方静默忽略）
  static _AppToasterState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<_AppToasterState>();

  @override
  State<AppToaster> createState() => _AppToasterState();
}

class _ToastEntry {
  _ToastEntry(this.message, this.style, this.expiresAt) : id = Object();

  final Object id;
  final String message;
  final AppToastStyle? style;

  /// 用单调递增的计数代替绝对时间 —— 挂在 widget 测试里时
  /// `pump(Duration)` 会推进 fake clock，绝对时间在那种环境里不可靠。
  int elapsed = 0;
  int expiresAt;
}

class _AppToasterState extends State<AppToaster> {
  final _entries = <_ToastEntry>[];

  /// 每 100ms 推进一次「已显示时长」，用来看哪条该消失了
  ///
  /// ⚠️ 用 `Timer.periodic` 而**不是** `AnimationController.repeat()`：
  ///    后者只要在跑就永远有下一帧 —— ① 空闲时白烧 CPU；
  ///    ② widget 测试里 `pumpAndSettle` 会**永远等不到静止**而超时。
  Timer? _clock;
  int _elapsed = 0;

  void _startClock() {
    _clock ??= Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
  }

  void _stopClock() {
    _clock?.cancel();
    _clock = null;
  }

  void _tick() {
    if (!mounted) {
      _stopClock();
      return;
    }
    _elapsed++;
    final gone = _entries.where((e) => _elapsed >= e.expiresAt).toList();
    setState(() => _entries.removeWhere((e) => _elapsed >= e.expiresAt));
    // 全部消失就停表 —— 没有 toast 的时间必须是**零开销**的。
    if (gone.isNotEmpty && _entries.isEmpty) _stopClock();
  }

  void show(
    String message, {
    Duration duration = const Duration(milliseconds: 2600),
    AppToastStyle? style,
  }) {
    // ⚠️ 在 build 期间调用 setState 会抛 "setState() called during build"。
    //    调用点可能是任意位置（包括某个 Builder 里顺手弹提示），把这件事
    //    兜在组件内部，调用方就不必记得"要延后一帧"。
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) show(message, duration: duration, style: style);
      });
      return;
    }
    final e = _ToastEntry(
      message,
      style,
      (duration.inMilliseconds / 100).ceil(),
    );
    setState(() {
      _entries.add(e);
      // 新的排在**下面**（视觉上更近底栏，视线不用往上找）
      while (_entries.length > _maxVisible) {
        _entries.removeAt(0);
      }
    });
    _startClock();
  }

  /// 手动关掉最上面那条（Esc 键）
  void dismissTop() {
    if (_entries.isEmpty) return;
    _dismiss(_entries.last.id);
  }

  void _dismiss(Object id) {
    if (!mounted) return;
    setState(() => _entries.removeWhere((e) => e.id == id));
    if (_entries.isEmpty) _stopClock();
  }

  @override
  void dispose() {
    _stopClock();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_entries.isEmpty) return widget.child;
    final cs = Theme.of(context).colorScheme;
    return Stack(
      children: [
        widget.child,
        Positioned(
          left: 0,
          right: 0,
          bottom: Sp.x10,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in _entries)
                _ToastCard(
                  key: ValueKey(e.id),
                  message: e.message,
                  style: e.style,
                  // 剩余寿命：只剩最后一秒时才开始变淡（先别急着消失）
                  fade: _fadeFor(e),
                  onClose: () => _dismiss(e.id),
                ),
            ],
          ),
        ),
      ],
    );
  }

  double _fadeFor(_ToastEntry e) {
    final left = (e.expiresAt - _elapsed) * 100;
    if (left > 1200) return 1;
    return (left / 1200).clamp(0.25, 1.0);
  }
}

class _ToastCard extends StatelessWidget {
  const _ToastCard({
    required this.message,
    required this.style,
    required this.fade,
    required this.onClose,
    super.key,
  });

  final String message;
  final AppToastStyle? style;
  final double fade;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accent = style?.accent ?? cs.primary;

    return Opacity(
      opacity: fade,
      child: Padding(
        padding: const EdgeInsets.only(top: Sp.x2),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: DecoratedBox(
              decoration: BoxDecoration(
                // 浮层底：比页面底亮一档 ⇒ 在深色页面上也能浮起来
                color: cs.surfaceContainerHigh,
                borderRadius: Radii.rMd,
                border: Border.all(color: cs.outlineVariant),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.32),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Sp.x4, Sp.x3, Sp.x2, Sp.x3),
                // ⚠️ 这里**必须**是「撑满」的 Row，不能是 `MainAxisSize.min` ——
                //    min + `Flexible` 在宽度无界时会让 `Flexible` 拿到无穷大，
                //    Row 直接溢出几万像素。而宽度为什么无界：`Positioned(left:0,right:0)`
                //    只约束了 **Positioned 自己**，里面的 Column 再给 Row 时
                //    已经过了那层约束。
                //    卡片居中由外层的 `Center` 负责，Row 自己只需要不溢出。
                child: Row(
                  children: [
                    if (style?.icon != null) ...[
                      Icon(style!.icon, size: 18, color: accent),
                      const SizedBox(width: Sp.x3),
                    ],
                    Flexible(
                      child: Text(
                        message,
                        style: TextStyle(
                          fontSize: FontSizes.sm,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                    if (style?.actionLabel != null) ...[
                      const SizedBox(width: Sp.x3),
                      TextButton(
                        onPressed: style!.onAction,
                        child: Text(style!.actionLabel!),
                      ),
                    ],
                    // 关闭键：常驻但视觉很轻（半透明），需要时一定够得着
                    // （鼠标 / 遥控器都算；Esc 也能关，见 ToastDismissShortcut）。
                    //
                    // ⚠️ 这里**刻意不加 tooltip**：`Tooltip` 要求祖先有
                    //    `Overlay`，而 ToastHost 挂在 `MaterialApp.builder` 里
                    //    = 在 Navigator 的 Overlay **之上** ⇒ 一点就抛
                    //    "No Overlay widget found"。`IconButton.tooltip` 内部
                    //    同样会建 Tooltip，所以也不行。
                    //    一个 16px 的 ✕ 不需要文字解释；可发现性靠"常驻可见"，
                    //    不靠 hover 提示。
                    IconButton(
                      onPressed: onClose,
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.close,
                        size: 16,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 便捷动作样式（成功 / 失败）
AppToastStyle okToastStyle() => AppToastStyle(icon: Icons.check_circle_outline);

AppToastStyle errToastStyle() =>
    AppToastStyle(icon: Icons.error_outline, accent: Colors.redAccent);

/// Esc 关掉最上面那条（TV 遥控器上比鼠标 hover 更靠谱）
class ToastDismissShortcut extends StatelessWidget {
  const ToastDismissShortcut({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.escape):
          const _DismissToastIntent(),
    },
    child: Actions(
      actions: <Type, Action<Intent>>{
        _DismissToastIntent: CallbackAction<_DismissToastIntent>(
          onInvoke: (_) {
            AppToaster.maybeOf(context)?.dismissTop();
            return null;
          },
        ),
      },
      child: child,
    ),
  );
}

class _DismissToastIntent extends Intent {
  const _DismissToastIntent();
}
