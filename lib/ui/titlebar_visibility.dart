// ═══════════════════════════════════════════════════════════════════════
//  自绘标题栏的显隐信号
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独一个文件（2026-09-24）
//
// 标题栏挂在 `MaterialApp.builder`（**Navigator 之外**），
// 而"要不要显示"由**页面**决定（播放页要收起）。
// 两者在 widget 树里相距很远，没有共同的 State 可以提升。
//
// 放 `shell.dart` 里会有个问题：`shell.dart` 已经 import 了
// `ui/player_page.dart`，而播放页要用这个 notifier →
// **形成 import 环**。Dart 允许环，但会带来初始化顺序的隐患
// （顶层 `final` 的初始化时机）。放到中立的小文件里最干净。
//
// # 为什么不用"路由观察"判断当前是不是播放页
//
// 原版是 `watch(() => route.name)` 判断 `route.name === "player"`。
// Flutter 侧要拿"当前路由"有两条路：
// ```text
// ① NavigatorObserver 记录路由栈 → 但生产构建里为了零开销不注册
//    （只在 --dart-define=DELIVERY_TEST=true 时注册），不能依赖
// ② 页面自己声明"我不要标题栏" → 语义最直接，也不依赖路由结构
// ```
// 选 ②。

import 'package:flutter/widgets.dart';

/// 自绘标题栏是否显示
///
/// - `true`  → 显示（默认；所有页面共用）
/// - `false` → 收起（让内容占满）
///
/// ⚠️ **生命周期必须成对**：`PlayerPage.initState` 置 false，
///    `PlayerPage.dispose` 必须置回 true ——
///    漏了的话用户从播放器返回后**再也拖不动窗口**。
final titleBarVisible = ValueNotifier<bool>(true);

/// 标题栏是否要**用深色**（暗色沉浸态）
///
/// # 为什么需要这个信号（2026-09-25 任务㉑③⑦）
///
/// 用户原话：
/// > 进入播放页还是上面会闪出来**白条**
/// > 我觉得……那个白条可能跟顶部的自定义操作条有关系
///
/// ## 实测复现（`.probe/whitebar_capture.py` + `.probe/real_player_capture.py`）
///
/// 标题栏挂在 `MaterialApp.builder`（**Navigator 之外**，见 `shell.dart` 的树），
/// 所以它**始终覆盖在所有路由之上**。播放页是纯黑（`Scaffold` 黑色），
/// 而标题栏是**浅色液态玻璃**（实测 `#e7eaf2`）——
/// 于是播放页顶部永远压着一条 40px 的浅色横条 = 用户说的"白条"。
///
/// ## 为什么不能像原版那样直接隐藏
///
/// 原版 `TitleBar.vue` 在播放页是 `hidden`（`route.name === 'player'`）：
/// ```js
/// hidden.value = route.name === "player";
/// ```
/// 但原版是 **WebView 里的网页**，窗口由 Tauri 管 ——
/// 它隐藏后 Tauri 的原生窗口**仍然可拖**。
/// 而我们用 `titleBarStyle: hidden` 去掉了系统标题栏，
/// **这条标题栏就是唯一的拖动区** —— 隐藏它 = 窗口彻底拖不动。
///
/// 用户为这件事专门纠正过（`player_page.dart:602-604`）：
/// > 播放器页面没有顶部的那个可拖动 缩小 放大 关闭的那个操作条,
/// > 影响体验,在桌面端播放页面 无法拖动窗口
///
/// ## 所以：**保留功能，改成深色**
///
/// ```text
/// 隐藏标题栏   → 用户明确否决过（窗口拖不动）
/// 保留浅色     → 用户报的"白条"
/// ★ 保留但转深色 → 拖动区还在，视觉上与黑色播放页融为一体
/// ```
/// 这也正是用户那句「其实还有点丑」的正解：不是删掉它，
/// 而是让它**在播放页不要那么显眼**。
///
/// ⚠️ 同样必须**成对**：`PlayerPage` 置 true，
///    `dispose` 置回 false —— 否则返回首页后标题栏一直是黑的。
final titleBarDark = ValueNotifier<bool>(false);

/// 交付实测用：真实渲染树里**当前有没有**可拖动的标题栏
///
/// # 为什么需要（2026-09-24 用户反馈）
///
/// > 影视详情页和播放页都没有顶部的那个操作条，无法拖动
///
/// 这是**结构性**问题（标题栏挂错了层级），而结构化问题单测容易漏 ——
/// 所以要在真实运行的应用里、**在真实的详情页上**直接读渲染树。
///
/// 判据：整棵树里有没有一个"高度 40 且宽度撑满"的容器
/// （`_CustomTitleBar` 的可观测特征）。不用 `find.byType(_CustomTitleBar)`
/// 是因为它是私有类，外部拿不到类型。
bool titleBarPresentInTree() {
  final root = WidgetsBinding.instance.rootElement;
  if (root == null) return false;

  var found = false;
  var visited = 0;
  void walk(Element el) {
    if (found || visited > 4000) return;
    visited++;
    final ro = el.findRenderObject();
    if (ro is RenderBox && ro.hasSize) {
      /*
       * ★ 判据：高 40.0（`_CustomTitleBar.preferredSize`）+ 宽度接近整屏
       *
       * 为什么不用"找 Text('源影')"：应用标题也可能出现在别处
       * （比如设置页的标题），会误判。
       * 尺寸特征更可靠，也不会因为文案改动而失效。
       */
      if ((ro.size.height - 40.0).abs() < 0.6 &&
          ro.size.width > 200 &&
          el.widget.runtimeType.toString().contains('CustomTitleBar')) {
        found = true;
        return;
      }
    }
    el.visitChildren(walk);
  }

  walk(root);
  return found;
}
