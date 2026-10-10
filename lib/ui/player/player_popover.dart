// ═══════════════════════════════════════════════════════════════════════
//  播放器的「悬浮小窗」（popover）—— 替代原来的弹窗 / 抽屉
// ═══════════════════════════════════════════════════════════════════════
//
//  # 为什么要有这个组件（Owner 2026-10-09 第 12 条）
//
//  > 清晰度,可以像 bilibili 或者腾讯视频那样,悬浮上去出现一个小小的
//  > 操作窗口,而不是非要弹窗、抽屉,本来就不用展示太多数据,
//  > 干嘛要搞个弹窗
//
//  这些操作（倍速 / 线路 / 字幕 / 音轨 / 弹幕开关）的共同特征是
//  **数据量很小、需要频繁来回切** —— 用全屏 scrim 或 320~380 宽的抽屉
//  装 3~7 行字，是把「选一个」放大成「离开播放页」。
//
//  # 三种输入都要能用（这是本组件存在的理由，不是装饰）
//
//  ```text
//  桌面   悬停 ~150ms 后弹出；鼠标移进面板保持；移出后延迟收起；
//         点一下也能开 / 关（不靠 hover 的人也能用）
//  触摸   点按切换（悬停根本不存在）
//  TV     焦点进入按钮即展开；方向键在选项间移动；Esc / 返回键关闭
//  ```
//
//  ⚠️ 焦点这一路是**必须**的：TV 上没有鼠标，popover 只做「点击展开」
//    就等于功能缺失；方向键走 `Focus` 的默认遍历即可，不额外做 roving。
//
//  # 动画：≤150ms 的淡入 + 6px 位移，不用 BackdropFilter
//
//  `BackdropFilter` 在视频层上代价极高（每帧一次全屏读回），
//  播放器页面绝不加；半透明白/黑卡片就够（B 站 / 腾讯都是这个观感）。

import 'dart:async';

// ⚠️ 仓库铁律：lib/ 下**禁止** `package:flutter/material.dart`（test/theme_regression_test.dart
//   全文本扫描）；`package:flutter/widgets.dart` / `rendering.dart` 是允许的
//   （material_ui 只 re-export 了 widgets.dart，没有 rendering.dart ⇒ 这里必须显式引）。
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import '../tokens.dart';

/// popover 的 id 常量 —— 开关与按钮用**同一份**字符串
class PlayerPopoverIds {
  const PlayerPopoverIds._();

  static const rate = 'rate';
  static const quality = 'quality';
  static const tracks = 'tracks';
  static const danmaku = 'danmaku';
  static const more = 'more';
}

/// 一条 popover 选项（值类型由调用点决定）
class PopoverOption<T> {
  const PopoverOption({
    required this.value,
    required this.label,
    this.hint,
    this.checked = false,
    this.enabled = true,
  });

  final T value;
  final String label;

  /// 次要说明（清晰度「1080P · 6Mbps」这种），可空
  final String? hint;

  /// 是否为当前选中项 —— 画对勾 + 高亮
  final bool checked;

  final bool enabled;
}

/// popover 的开合真值源
///
/// ★ 为什么放在 State 里而不是让每个按钮各自 `setState`：
///   Esc / 返回键必须能一次关掉**当前**那个 popover，而页面里同时可能
///   有一个「更多」浮层、一个「线路」popover。真值只有一份才关得掉。
class PopoverController extends ChangeNotifier {
  String? _openId;
  Timer? _closeTimer;

  /// 每个 popover 入口的**屏幕矩形**（id → 那枚按钮当前占据的 Rect）
  ///
  /// ★★ OPS-5 ②（Owner 2026-10-10 反馈第 2 条）：面板以前只会贴在窗口右下角，
  ///    因为控制器里**一个几何量都没有**（只有 `_openId`）⇒ 面板无从知道
  ///    按钮在哪。这里补上「按钮在哪」这一半。
  ///
  /// # 为什么是「探针自己写进来」而不是「面板去读按钮的 RenderBox」
  /// ```text
  /// 面板与按钮是**兄弟**（都挂在页面那个整屏 Stack 下）。
  /// 面板布局时去读按钮的 `RenderBox.size` 会撞上框架断言：
  ///   'sizeAccessAllowed': RenderBox.size accessed beyond the scope of
  ///   resize, layout, or permitted parent access
  /// —— 只有父节点才有权读子节点的 size。
  /// ⇒ 反过来：按钮那侧挂一个零尺寸的**探针**（`PopoverAnchorProbe`），
  ///   它在**自己的** `performLayout` / `paint` 里算出自己的屏幕矩形并写进这里。
  ///   底栏在 Stack 里排在面板之前 ⇒ 同一帧内按钮先布局、面板后布局，
  ///   面板读到的永远是**本帧**的几何。
  /// ```
  final Map<String, Rect> _anchorRects = <String, Rect>{};

  /// 谁写的这条矩形（探针的 RenderObject）—— 卸载时用来防止误删新探针的登记
  final Map<String, Object> _anchorOwners = <String, Object>{};

  /// 面板那一层自己的 key —— 把按钮的**全局**矩形换算成面板层的**局部**矩形
  ///
  /// 为什么需要换算：`SingleChildLayoutDelegate` 返回的偏移是相对面板层自己的
  /// 坐标系，而探针量到的是全局坐标。两者只有在「面板层恰好贴在屏幕左上角」
  /// 时才相等（播放页有标题栏 / 安全区时就不等）⇒ 老老实实换算。
  final GlobalKey _layerKey = GlobalKey();

  GlobalKey get layerKey => _layerKey;

  bool _refreshScheduled = false;
  bool _disposed = false;

  /// 当前展开的按钮 id（null = 都没展开）
  String? get openId => _openId;

  bool isOpen(String id) => _openId == id;

  /// 探针上报自己的**全局**矩形（由 `_RenderPopoverAnchorProbe` 在自己的 paint 里调用）
  ///
  /// ⚠️ 这里**不能同步 notifyListeners()**：paint 之后同帧还有别的事要做，
  ///    同步唤醒监听者会在帧中途再排一次 build。改成**帧后**通知，
  ///    且只在矩形**真的变了**时才排（否则每帧都通知 = 每帧都重建）。
  void reportAnchorRect(String id, Object owner, Rect globalRect) {
    final layer = _layerBox;
    final rect = layer == null
        ? globalRect
        : layer.globalToLocal(globalRect.topLeft) & globalRect.size;
    final changed = _anchorRects[id] != rect;
    _anchorOwners[id] = owner;
    _anchorRects[id] = rect;
    if (changed) _scheduleRefresh();
  }

  RenderBox? get _layerBox {
    final ro = _layerKey.currentContext?.findRenderObject();
    return ro is RenderBox && ro.attached ? ro : null;
  }

  /// 帧后刷新面板位置（窗口缩放 / 横竖屏切换后按钮挪了位，面板要跟着挪）
  void _scheduleRefresh() {
    if (_refreshScheduled || _disposed) return;
    _refreshScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  /// 探针卸载时注销（只在自己还是登记人时才删）
  void forgetAnchorRect(String id, Object owner) {
    if (!identical(_anchorOwners[id], owner)) return;
    _anchorOwners.remove(id);
    _anchorRects.remove(id);
  }

  /// 当前展开那枚按钮的屏幕矩形（还没上报 / 已卸载 ⇒ null）
  Rect? anchorRectOf(String? id) => id == null ? null : _anchorRects[id];

  void toggle(String id) {
    _closeTimer?.cancel();
    if (_openId == id) {
      close();
    } else {
      _openId = id;
      notifyListeners();
    }
  }

  /// 悬停到期时**只展开、不切换**（此时若已展开就什么都不做）
  void toggleOpen(String id) {
    _closeTimer?.cancel();
    if (_openId == id) return;
    _openId = id;
    notifyListeners();
  }

  void close() {
    _closeTimer?.cancel();
    if (_openId == null) return;
    _openId = null;
    notifyListeners();
  }

  /// 指针**进了面板** —— 取消「收起」计时
  void holdOpen() => _closeTimer?.cancel();

  /// 指针**离开了面板** —— 重新武装那 250ms 的收起计时
  void armClose() {
    if (_openId == null) return;
    _closeTimer?.cancel();
    _closeTimer = Timer(closeDelay, close);
  }

  static const Duration closeDelay = Duration(milliseconds: 250);

  @override
  void dispose() {
    _disposed = true;
    _closeTimer?.cancel();
    super.dispose();
  }
}

/// 面板外观 —— B 站 / 腾讯视频那一档
class PlayerPopoverSurface extends StatelessWidget {
  const PlayerPopoverSurface({
    super.key,
    required this.child,
    this.width = 168,
  });

  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(vertical: Sp.x1),
      decoration: BoxDecoration(
        color: const Color(0xF01A1A1A),
        borderRadius: Radii.rSm,
        border: Border.all(color: const Color(0x1FFFFFFF)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// 面板里的一行
class PopoverRow extends StatelessWidget {
  const PopoverRow({
    super.key,
    required this.label,
    this.hint,
    this.checked = false,
    this.onTap,
    this.focusNode,
  });

  final String label;
  final String? hint;
  final bool checked;
  final VoidCallback? onTap;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Sp.x3,
            vertical: Sp.x2,
          ),
          child: Row(
            children: [
              // ★ 固定宽度的对勾槽：勾与不勾时文字**不左右跳**
              SizedBox(
                width: 18,
                child: checked
                    ? const Icon(
                        Icons.check,
                        size: 15,
                        color: Color(0xFF32C7FF),
                      )
                    : null,
              ),
              const SizedBox(width: Sp.x1),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: onTap == null
                        ? const Color(0xFF7A7A7A)
                        : const Color(0xFFF2F2F2),
                    fontSize: FontSizes.sm,
                  ),
                ),
              ),
              if (hint != null && hint!.isNotEmpty) ...[
                const SizedBox(width: Sp.x2),
                Text(
                  hint!,
                  style: const TextStyle(
                    color: Color(0xFF8C8C8C),
                    fontSize: FontSizes.cap,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 面板里的分组标题（紧凑，不抢视线）
class PopoverGroupLabel extends StatelessWidget {
  const PopoverGroupLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Sp.x3, Sp.x2, Sp.x3, Sp.x1),
    child: Text(
      text,
      style: const TextStyle(color: Color(0xFF8C8C8C), fontSize: FontSizes.cap),
    ),
  );
}

/// 面板与按钮之间的分隔线
class PopoverDivider extends StatelessWidget {
  const PopoverDivider({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: Sp.x1, horizontal: Sp.x2),
    child: Divider(height: 1, color: Color(0x1FFFFFFF)),
  );
}

/// 淡入 + 6px 位移（≤150ms）
///
/// ★ 用 `TweenAnimationBuilder` 而不是逐帧 `setState`：面板内容（含列表）只在
///   「开 / 关」时重建一次，动画帧只驱动 Opacity/Transform。
/// ★ 面板整体放在 `IgnorePointer` 里而不是靠 opacity 归零 ——
///   否则透明的那一帧仍然吃掉画面左上角的点击（这是「残留」的第二层）。
class PopoverMotion extends StatelessWidget {
  const PopoverMotion({
    super.key,
    required this.visible,
    required this.child,
    this.placement = PopoverPlacement.above,
  });

  final bool visible;
  final Widget child;
  final PopoverPlacement placement;

  /// 进场位移的方向：上方弹出的往**下**落一点，下方弹出的往**上**升一点
  Offset get _offset => placement == PopoverPlacement.above
      ? const Offset(0, -6)
      : const Offset(0, 6);

  @override
  Widget build(BuildContext context) {
    // ★ 用框架自带的两条隐式动画，而不是自己驱动一条 Tween：
    //    的 child 只在 tween **端点变化**时重建，
    //   加上第一帧 t=0 直接返回 shrink，那条写法在「开关来回切」时会出现
    //   首帧空档与硬切。AnimatedOpacity / AnimatedSlide 的端点语义清楚。
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSlide(
        duration: Motion.fast,
        curve: Motion.easeOut,
        offset: visible ? Offset.zero : _offset / 24,
        child: AnimatedOpacity(
          duration: Motion.fast,
          curve: Motion.easeOut,
          opacity: visible ? 1 : 0,
          child: child,
        ),
      ),
    );
  }
}

enum PopoverPlacement { above, below }

/// 面板自身的「移入保持」壳
///
/// ★ 指针从按钮挪进面板的路上会经过一小段空白（按钮上沿到面板下沿之间的缝）。
///   没有这层壳，`PopoverAnchorButton` 的 250ms 收起计时会在指针**还没进面板**
///   时到点 ⇒ 面板消失、用户永远点不进去。
/// ⇒ 这层壳在**指针进面板**的那一刻取消那个计时。
class PopoverKeepAlive extends StatefulWidget {
  const PopoverKeepAlive({
    super.key,
    required this.controller,
    required this.child,
  });

  final PopoverController controller;
  final Widget child;

  @override
  State<PopoverKeepAlive> createState() => _PopoverKeepAliveState();
}

class _PopoverKeepAliveState extends State<PopoverKeepAlive> {
  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => widget.controller.holdOpen(),
    onExit: (_) => widget.controller.armClose(),
    child: widget.child,
  );
}

/// 悬停 ~150ms 展开的入口按钮（桌面）
///
/// # 三种输入的分工（同一个按钮上）
/// ```text
/// 悬停 150ms   → 展开（`_openHoverTimer`）——「鼠标只是路过就弹出」是 B 站的观感
/// 移出         → 250ms 后收起（`_closeHoverTimer`）—— 给「从按钮挪进面板」留路
/// 点击 / 确认键 → 切换（`_onTap`）—— 触摸与 TV 走这条；桌面也支持不靠悬停
/// ```
///
/// ⚠️ 那 250ms 的延迟**不能省**：B 站/腾讯的按钮与面板之间有一条空隙，
///   用户要移过那条缝；零延迟会让指针一离开按钮面板就消失，永远点不进去。
///
/// # 为什么不用 `MenuAnchor` / `Tooltip`
/// `MenuAnchor` 会把菜单挂到 overlay 里（层级与命中测试都另起一套），
/// 而这里要的是「贴在按钮上方、跟着按钮走」的小卡片；自己挂在一个
/// `Stack` 里位置更可控、也更容易做交叉淡出。
/// 锚点探针 —— 把「这枚按钮在屏幕上的矩形」上报给 `PopoverController`。
///
/// ★★ OPS-5 ②：面板与按钮是兄弟节点，面板**不能**去读按钮的 `RenderBox`
///    （框架断言：只有父节点有权读子节点 size —— 实测报错原文：
///    'sizeAccessAllowed': RenderBox.size accessed beyond the scope of
///    resize, layout, or permitted parent access）。
///    反过来让按钮自己上报：探针在**自己的** `paint` 里算 `offset & size`，
///    这两个量它自己有权读；且 Stack 的子件按顺序布局绘制 ⇒ 按钮先于面板
///    完成绘制，面板同一帧就能拿到本帧的正确矩形。
///
/// 为什么是 `paint` 而不是 `performLayout`：`paint` 时自己的 `size` 已定稿，
/// 祖先链的布局也全部完成（不会读到半成品）。零尺寸、不拦截命中测试，
/// 对按钮本身没有任何影响。
class _PopoverAnchorProbe extends SingleChildRenderObjectWidget {
  const _PopoverAnchorProbe({
    required this.controller,
    required this.id,
    required super.child,
  });

  final PopoverController controller;
  final String id;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPopoverAnchorProbe(controller: controller, id: id);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPopoverAnchorProbe renderObject,
  ) => renderObject
    ..controller = controller
    ..id = id;
}

class _RenderPopoverAnchorProbe extends RenderProxyBox {
  _RenderPopoverAnchorProbe({
    required PopoverController controller,
    required String id,
  }) {
    // ⚠️ 不能写成 `this._controller` 初始化形参：下面有同名 setter，
    //    初始化形参会和 setter 冲突（analyzer: prefer_initializing_formals
    //    在这条上无法满足，故在构造函数体里赋值并显式豁免）。
    // ignore: prefer_initializing_formals
    _controller = controller;
    // ignore: prefer_initializing_formals
    _id = id;
  }

  late PopoverController _controller;
  set controller(PopoverController value) {
    if (identical(_controller, value)) return;
    _controller.forgetAnchorRect(_id, this);
    _controller = value;
  }

  late String _id;
  set id(String value) {
    if (_id == value) return;
    _controller.forgetAnchorRect(_id, this);
    _id = value;
  }

  bool _reported = false;

  @override
  void paint(PaintingContext context, Offset offset) {
    // 自己的 size + 自己的 offset（= 相对最近的 repaint boundary / 祖先）
    // ⇒ 换算成**全局**坐标再上报，控制器那边再换算成面板层的局部坐标。
    if (hasSize && size.width > 0 && size.height > 0) {
      _controller.reportAnchorRect(
        _id,
        this,
        localToGlobal(Offset.zero) & size,
      );
      _reported = true;
    }
    super.paint(context, offset);
  }

  @override
  void detach() {
    if (_reported) _controller.forgetAnchorRect(_id, this);
    super.detach();
  }
}
class PopoverAnchorButton extends StatefulWidget {
  const PopoverAnchorButton({
    super.key,
    required this.controller,
    required this.id,
    required this.child,
    this.tooltip,
  });

  final PopoverController controller;

  /// 与 `PopoverController.toggle` 用的同一个 id
  final String id;
  final Widget child;
  final String? tooltip;

  @override
  State<PopoverAnchorButton> createState() => PopoverAnchorButtonState();
}

class PopoverAnchorButtonState extends State<PopoverAnchorButton> {
  Timer? _openTimer;
  Timer? _closeTimer;

  /// 悬停展开的等待时间 —— 150ms：B 站那一档，短到像"跟手"，长到不会路过就弹
  static const Duration hoverDelay = Duration(milliseconds: 150);

  /// 移出后收起的等待 —— 与 `PopoverController.closeDelay` 同一份
  static const Duration closeDelay = PopoverController.closeDelay;

  bool get _isOpen => widget.controller.isOpen(widget.id);

  @override
  void dispose() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    super.dispose();
  }

  void _armOpen() {
    _closeTimer?.cancel();
    if (_isOpen) return;
    _openTimer?.cancel();
    _openTimer = Timer(hoverDelay, () {
      if (mounted) widget.controller.toggleOpen(widget.id);
    });
  }

  void _armClose() {
    _openTimer?.cancel();
    if (!_isOpen) return;
    widget.controller.armClose();
  }

  void _onTap() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    widget.controller.toggle(widget.id);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _armOpen(),
      onExit: (_) => _armClose(),
      // ★ 探针包在**最外层**：上报的矩形 = 按钮本体（含 Tooltip / 内边距），
      //   面板右缘对齐的就是它。零尺寸，不影响任何布局。
      child: _PopoverAnchorProbe(
        controller: widget.controller,
        id: widget.id,
        child: Tooltip(
          message: widget.tooltip ?? '',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _onTap,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
