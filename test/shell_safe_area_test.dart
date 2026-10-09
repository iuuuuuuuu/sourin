// ═══════════════════════════════════════════════════════════════════════
//  F6：内容区的**顶部安全区**（手机状态栏 / 挖孔）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守的是什么 bug（真机实测，不是推测）
//
// 手机 emulator-5556（1080×2400 @ 420dpi ⇒ DPR 2.625）：
// ```text
// dumpsys window displays
//   mAppBounds = Rect(0, 128 - 1080, 2274)
//   InsetsSource type=statusBars     frame=[0,0][1080,128]      visible=true
//   InsetsSource type=navigationBars frame=[0,2274][1080,2400]  visible=true
// Flutter 内容视图 [0,0][1080,2274]
// ```
// ⇒ **底部 126 设备 px 由系统让出，顶部不让**。这就是不对称的根：
//    引擎把底部内缩算进了窗口，顶部留给应用自己处理。
//
// 同一台机器的 a11y 树（`.probe\t178_ui_phone.xml`）：
// ```text
// 「所有直播」按钮 bounds = [713,84][986,163]
// ```
// 84 设备 px = `Sp.x8`(32 逻辑) × 2.625 ⇒ **页面的 y=0 就是屏幕的 y=0**。
// 页头那 32 逻辑 px 里，有 48.76 落在状态栏/挖孔底下。
//
// # 为什么修在 shell 而不是逐页加
//
// 同一个"从 y=0 起算"的问题出现在**每一个**页面：
// 手机 a11y 树停在**追更页**（首行 y=63 设备 px = 24 逻辑）、
// TV 首行 y=48 设备 px —— 都是**外壳级**现象，不是某一页的局部问题。
// 逐页加 = 5 处重复，且以后新增页面必然再漏一次。
//
// # 为什么只吃顶部（`bottom: false`）
//
// 底部留白由各页自己的 `Sp.bottomBarInset` 负责（底栏是**悬浮**的，
// 见 `lib\ui\tokens.dart:56-73`）。SafeArea 若连底部一起吃，
// 就是**叠一层**，内容被顶高一截。
// ⇒ 本文件有一条断言专门守"底栏一个像素都不许动"。
//
// # 阴性对照：为什么桌面 / TV 必须是严格 no-op
//
// TV 实测 `dumpsys window displays` 的 `InsetsState` 里**只有**
// `type=ime` 一条（`visible=false`），**没有 statusBars、也没有
// navigationBars** ⇒ `padding.top == 0`。
// 桌面同理：`ViewPadding.zero` 是引擎的默认值
// （`sky_engine\lib\ui\platform_dispatcher.dart:2000`）。
//
// # 为什么用 widget test 而不是真机截图
//
// 真机截图能证明"现在对"，但**守不住以后** —— 谁把 SafeArea 挪走
// 都不会有东西报红。这个文件要的是**回归门禁**：
// 位移必须**恰好**等于状态栏高度，多一个像素少一个像素都算失败。
//
// ⚠️ 必须用 `tester.view.padding` / `physicalSize` / `devicePixelRatio`，
//    **不能**用 `setSurfaceSize` —— 后者只改布局约束，
//    不动 FlutterView 的 metrics，于是 `MediaQuery.fromView` 读到的
//    仍是 flutter_test 默认值（800×600 @ DPR 3.0），
//    测试会对着一个和生产不同的数字断言。
//    （同一个坑已记在 `test\bottom_bar_fit_test.dart:71-87`。）

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/spatial_nav.dart' show BottomBarMarker;

/// 复刻 `SourinApp.build` 的树结构（`FTheme` 在 `MaterialApp.builder` 里）
///
/// 理由与 `test\core_error_test.dart:55-64` 相同：`_CoreErrorView` 用
/// `FTheme.of(context)` 取色，少了这一层会抛异常，于是测试测的是
/// "我的壳拼错了"，不是被测结构。
Widget _appWith({required Widget home}) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (context, child) =>
        AppThemeHost(data: theme, child: child ?? const SizedBox()),
    home: home,
  );
}

/// 真机实测那条错误（Android TV，Permission denied）
const _realError =
    'PathAccessException: Exists failed, path = '
    "'/storage/emulated/0/tvdata' (OS Error: Permission denied, errno = 13)";

// ── 手机实测常量（全部来自 `dumpsys window displays`，不是估的）──
const double _phoneDpr = 2.625; // 1080 / 411.43
const double _phoneW = 1080.0;
const double _phoneH = 2400.0;
/// 状态栏：`InsetsSource type=statusBars frame=[0,0][1080,128]`
const double _phoneStatusBarPhysical = 128.0;
/// 128 设备 px ÷ 2.625 = 48.7619… 逻辑 px
const double _phoneStatusBarLogical = _phoneStatusBarPhysical / _phoneDpr;

/// 把 `ShellPage`（核心启动失败那一支）挂在真机尺寸 + 真机内缩下
///
/// # 为什么用 `coreError` 这一支来测安全区
///
/// ① 它是**同步渲染**的（`core_error_test.dart:94` 一句注释：
///    "一帧就够 —— 错误页是同步渲染的"）⇒ 没有异步抖动污染几何读数；
/// ② 它**不走保活**（`lib\shell.dart:3088-3093` 明确记录），
///    树结构稳定；
/// ③ 它和正常页共享**同一个** SafeArea 包裹点 —— SafeArea 包的是
///    整个三元表达式，两支都在里面 ⇒ 测这一支就能守住那一层。
///    （这也是当初选择"包整个三元"而不是"只包 Stack"的原因之一。）
Future<void> _pumpErrorShell(
  WidgetTester tester, {
  double topPhysical = 0,
  double bottomPhysical = 0,
  double leftPhysical = 0,
  double rightPhysical = 0,
}) async {
  tester.view.devicePixelRatio = _phoneDpr;
  tester.view.physicalSize = const Size(_phoneW, _phoneH);
  tester.view.padding = FakeViewPadding(
    top: topPhysical,
    bottom: bottomPhysical,
    left: leftPhysical,
    right: rightPhysical,
  );
  addTearDown(tester.view.reset);

  await tester.pumpWidget(_appWith(
    home: const ShellPage(
      coreError: _realError,
      coreDataDir: '/storage/emulated/0/tvdata',
    ),
  ));
  await tester.pump();
}

/// 收集并清空所有异常 —— 与 `bottom_bar_fit_test.dart` 的 `_claim` 同形
///
/// ⚠️ 与那一份的区别：这里**把异常打出来**。
///
/// 静默吞掉异常是本项目反复踩过的坑 —— 第一版这个文件里，
/// 第二次 `pumpWidget` 抛了异常被吞掉，测试只是以
/// 「Found 0 widgets with text containing 核心未能启动」失败，
/// **真因一个字都看不到**。吞可以（shell 在 flutter_test 里本来就有
/// 已知噪声），但**必须留痕**。
List<Object> _claim(WidgetTester tester, [String label = '']) {
  final out = <Object>[];
  for (Object? e = tester.takeException(); e != null;) {
    out.add(e);
    debugPrint('[SA] ⚠️ 异常${label.isEmpty ? '' : '($label)'}: $e');
    e = tester.takeException();
  }
  return out;
}

Finder _headline() => find.textContaining('核心未能启动');
Finder _bar() => find.byType(BottomBarMarker);

void main() {
  group('★ F6 内容区顶部安全区：手机状态栏不许盖住内容', () {
    testWidgets('① 阳性：状态栏 128 设备 px ⇒ 内容整体下移 48.76 逻辑 px', (t) async {
      await _pumpErrorShell(t, topPhysical: 0);
      final exceptions = _claim(t);
      expect(exceptions, isEmpty, reason: '这一支应当干净渲染（coreError 是同步路径）');
      final before = t.getRect(_headline()).top;

      await _pumpErrorShell(t, topPhysical: _phoneStatusBarPhysical);
      _claim(t);
      final after = t.getRect(_headline()).top;

      /*
       * ★ 判据是**恰好相等**，不是"变大了就行"。
       *
       * 去掉 SafeArea 时这里是 0（红）—— 这个等式本身就是红度证明：
       * 位移必须精确等于状态栏高度，多/少一个像素都说明
       * 有别的东西在同时改布局（比如底部也被吃了、或叠了第二层）。
       */
      expect(
        after - before,
        closeTo(_phoneStatusBarLogical, 0.01),
        reason: '★ 内容必须**恰好**下移一个状态栏的高度'
            '（期望 ${_phoneStatusBarLogical.toStringAsFixed(4)} 逻辑 px，'
            '实测 ${(after - before).toStringAsFixed(4)}）—— '
            '位移为 0 = SafeArea 没生效，手机上前 48.76 px 的内容点不到；'
            '位移偏大 = 有别的地方也在加内边距。',
      );
    });

    testWidgets('② 位移必须**跟着** MediaQuery 走（硬编码 48.76 会在这里露馅）', (t) async {
      /*
       * # 为什么是"两点线性响应"而不是别的阴性对照
       *
       * ① 已经证明了 `0 → 128` 的位移恰好是 48.7619。
       * 但**一个常数**就能通过 ①：只要有人写死
       * `Padding(top: 48.76)`，① 照样绿。
       *
       * ⇒ 这里换**另一个**状态栏高度（256 设备 px，即双倍），
       *   要求位移**同样恰好**翻倍。写死的常数过不了这一关，
       *   而"真的在读 `MediaQuery.padding.top`"必然过。
       *
       * 两点合起来 = 值跟随 + 线性 + 无偏移。
       *
       * ⚠️ 我第一版这里写的是"上游 `MediaQuery.removePadding` 清掉再比"，
       *    **那个判据在 flutter_test 里不成立** —— 见文件末尾的说明。
       */
      await _pumpErrorShell(t, topPhysical: _phoneStatusBarPhysical);
      _claim(t, '128');
      final at128 = t.getRect(_headline()).top;

      const double doubled = _phoneStatusBarPhysical * 2; // 256
      await _pumpErrorShell(t, topPhysical: doubled);
      _claim(t, '256');
      final at256 = t.getRect(_headline()).top;

      final delta = at256 - at128;
      expect(
        delta,
        closeTo(_phoneStatusBarLogical, 0.01),
        reason: '★ 状态栏从 128 涨到 256 设备 px 时，内容必须**再**下移 '
            '${_phoneStatusBarLogical.toStringAsFixed(4)} 逻辑 px'
            '（实测 ${delta.toStringAsFixed(4)}）。'
            '若这里是 0 ⇒ 内边距是个**写死的常数**，真机上换了状态栏高度就错；'
            '若偏离 ⇒ 有别的因素在参与布局。',
      );
    });

    testWidgets('③ 只吃顶部：底栏一个像素都不许动（`bottom: false`）', (t) async {
      await _pumpErrorShell(t, topPhysical: 0);
      _claim(t);
      final barBefore = t.getRect(_bar());
      final before = t.getRect(_headline()).top;

      await _pumpErrorShell(t, topPhysical: _phoneStatusBarPhysical);
      _claim(t);
      final barAfter = t.getRect(_bar());

      expect(
        barAfter,
        barBefore,
        reason: '★ 底栏位置必须**完全相同**。底部留白归各页自己的 '
            '`Sp.bottomBarInset` 管（`tokens.dart:56-73`），'
            'SafeArea 再吃一次就是叠一层 ⇒ 内容被顶高一截。'
            '（改前 $barBefore，改后 $barAfter）',
      );

      /*
       * ── 反方向：给**底部**内缩，内容必须一动不动 ──
       *
       * 上面那半只证明了"顶部变化时底栏不动"。
       * 这一半证明"底部变化时内容不动" —— 两个方向都查，
       * 才能把 `bottom: false` 钉死。
       *
       * 若谁把它改成 `bottom: true`，SafeArea 会为底部导航栏
       * 再加一层 Padding，内容被往上顶、底部白扔一条 —— 立刻报红。
       *
       * ⚠️ 这里的数值只要**非零**就够（它只用来触发「有底部内缩」这一态）。
       *    2026-10-05 在 emulator-5554（1080x2400 @480dpi）实测：
       *    `navigationBars frame=[0,2256][1080,2400]` ⇒ **144 设备 px**，
       *    而本文件旧注释里的 126 / `[0,2274]` 是另一台 1080x2340 的数字。
       */
      const double navBarPhysical = 144.0; // [0,2256][1080,2400] ⇒ 144px = 48dp
      await _pumpErrorShell(t, topPhysical: 0, bottomPhysical: navBarPhysical);
      _claim(t, 'bottom');
      final headWithBottom = t.getRect(_headline()).top;

      expect(
        headWithBottom,
        closeTo(before, 0.01),
        reason: '★ 底部内缩**不许**影响内容起点（`bottom: false`）。'
            '底部那 126 设备 px 由各页的 `Sp.bottomBarInset` 负责，'
            'shell 再吃一次就是叠两层。'
            '（无底部内缩 $before，有底部内缩 $headWithBottom）',
      );
    });

    testWidgets('④ 左右不吃：`left/right: false` ⇒ 横向布局不许变', (t) async {
      await _pumpErrorShell(t, topPhysical: 0);
      _claim(t);
      final headBefore = t.getRect(_headline());
      final barBefore = t.getRect(_bar());

      // 挖孔/手势条在横屏时会给出左右内缩 —— 这里不该被消费
      await _pumpErrorShell(
        t,
        topPhysical: 0,
        leftPhysical: 40,
        rightPhysical: 40,
      );
      _claim(t);
      final headAfter = t.getRect(_headline());

      expect(
        headAfter.left,
        closeTo(headBefore.left, 0.01),
        reason: '★ 左右内缩不该被 shell 消费（`left: false`）',
      );
      expect(
        headAfter.right,
        closeTo(headBefore.right, 0.01),
        reason: '★ 同上（`right: false`）',
      );
      expect(t.getRect(_bar()), barBefore, reason: '★ 底栏横向也不许动');
    });

    testWidgets('⑤ 结构：SafeArea 必须**只吃顶部**，且是内容区的祖先', (t) async {
      await _pumpErrorShell(t, topPhysical: _phoneStatusBarPhysical);
      _claim(t);

      final ancestors = t.widgetList<SafeArea>(
        find.ancestor(of: _headline(), matching: find.byType(SafeArea)),
      );

      expect(
        ancestors.any((s) => s.top && !s.bottom && !s.left && !s.right),
        isTrue,
        reason: '★ 内容区上方必须存在一个「只吃顶部」的 SafeArea。'
            '这四个开关是**语义契约**：`bottom: true` 会叠一层底部留白，'
            '`left/right: true` 会在横屏挖孔时白扔一条边。',
      );
    });

    testWidgets('⑥ 内容起点必须落在状态栏下方（不许有像素被盖住）', (t) async {
      await _pumpErrorShell(t, topPhysical: _phoneStatusBarPhysical);
      _claim(t);

      final top = t.getRect(_headline()).top;
      expect(
        top,
        greaterThanOrEqualTo(_phoneStatusBarLogical - 0.01),
        reason: '★ 第一行文字必须完全在状态栏之下。'
            '实测 top=${top.toStringAsFixed(2)}，状态栏底边='
            '${_phoneStatusBarLogical.toStringAsFixed(2)} —— '
            '小于它就意味着有内容被状态栏/挖孔盖住（F6 原始症状）。',
      );
    });

    testWidgets('⑦ 底栏自己必须躲开系统导航栏（`Positioned.bottom`）', (t) async {
      /*
       * ── 2026-10-05：用户实测「这手机端底部都被遮挡了」──
       *
       * 底栏这个 `Positioned` 是上面那个 `SafeArea` 的**兄弟**（它挂在
       * `Stack` 下、不在 `Positioned.fill` 里）⇒ 它读到的是**根**
       * `MediaQuery.padding.bottom`，**没有**被 `removePadding` 清零。
       *
       * 原版 CSS `bottom: calc(var(--tabbar-bottom) + var(--safe-bottom))`
       * 的后半截当初漏掉了 ⇒ 药丸（58dp）与导航栏带（48dp）重叠 36dp。
       *
       * 这一条把「底栏真的按 `padding.bottom` 上移」钉死 ——
       * 位移必须**恰好**等于 底部内缩 ÷ dpr，不许近似、不许来自别处。
       *
       * ⚠️ 现有 ③④ 抓不到这个 bug：它们每一对比较的两轮 `bottomPhysical`
       *    都是 0 ⇒ `bottom: 0` 与 `bottom: paddingOf(...).bottom` 同分。
       */
      await _pumpErrorShell(t, topPhysical: 0);
      _claim(t);
      final barNoInset = t.getRect(_bar());

      const double navBarPhysical = 144.0; // 同 ③：本机实测的导航栏高
      await _pumpErrorShell(t, topPhysical: 0, bottomPhysical: navBarPhysical);
      _claim(t, 'bottom');
      final barWithInset = t.getRect(_bar());

      final wantLift = navBarPhysical / _phoneDpr; // = 48.0 逻辑 px
      expect(
        barNoInset.bottom - barWithInset.bottom,
        closeTo(wantLift, 0.01),
        reason: '★ 底部内缩必须**原样**抬升底栏。'
            '（无内缩 bottom=${barNoInset.bottom}，'
            '有内缩 bottom=${barWithInset.bottom}，'
            '期望抬升 ${wantLift.toStringAsFixed(4)}）'
            '位移为 0 ⇒ 又丢掉了原版的 `var(--safe-bottom)`（F6 同款症状）。',
      );
      // 只许上移：尺寸与横向一个像素都不许被顺手改掉
      expect(barWithInset.height, closeTo(barNoInset.height, 0.01));
      expect(barWithInset.left, closeTo(barNoInset.left, 0.01));
      expect(barWithInset.right, closeTo(barNoInset.right, 0.01));

      /*
       * ── 阴性对照：鉴别力自查 ──
       *
       * 若哪天有人把底栏挪进一个 `bottom: true` 的 `SafeArea`，
       * `removePadding` 会把 `padding.bottom` 清零 ⇒ 上面那条位移断言
       * 退化成「0 == 0」永远绿。这一半专门堵住那种看起来还在测的假绿。
       */
      final barAncestors = t.widgetList<SafeArea>(
        find.ancestor(of: _bar(), matching: find.byType(SafeArea)),
      );
      expect(
        barAncestors.any((s) => s.bottom),
        isFalse,
        reason: '★ 底栏不许落在任何吃底部的 SafeArea 里 —— 那样 '
            '`padding.bottom` 会被 `removePadding` 清零，上面那条位移断言 '
            '就失去鉴别力（两边都是 0 ⇒ 恒绿）。',
      );
    });
  });
}

// ═══════════════════════════════════════════════════════════════════════
//  附：一个**被我写错过**的判据，以及为什么它不成立（留给下一个人）
// ═══════════════════════════════════════════════════════════════════════
//
// 本文件第一版的用例②写的是：
//
//   在上游套一层 `MediaQuery.removePadding(removeTop: true)`，
//   断言"位移必须完全消失" —— 以此证明 SafeArea 读的是 MediaQuery。
//
// 它**跑不过**，而且不是被测代码的问题，是判据本身不成立：
//
// ```text
// flutter_test\lib\src\window.dart
//   :1097 FakeViewPadding get padding => _padding ?? FakeViewPadding._wrap(_view.padding);
//   :1098 FakeViewPadding? _padding;
//   :1100   _padding = value;          ← set padding 直接写这个字段
//   :1205 FakeViewPadding get viewInsets => _viewInsets ?? ...
//   :1231 FakeViewPadding get viewPadding => _viewPadding ?? ...
// ```
//
// ⇒ 在 flutter_test 里，`view.padding` / `view.viewPadding` / `view.viewInsets`
//   是**三个互相独立的覆盖值**，**不会**按
//   `padding = max(0, viewPadding - viewInsets)`
//   那条真机规则互相推导。
//
// 真机上那条规则在引擎侧：
//   `flutter\lib\src\widgets\media_query.dart:307`
//     `padding = EdgeInsets.fromViewPadding(view.padding, view.devicePixelRatio),`
//   `:163` 文档：`padding` = `max(0.0, viewPadding - viewInsets)`
//
// 所以"清掉上游 padding"在 flutter_test 里只会让 SafeArea 读到 0，
// 位移**确实**会消失 —— 但那证明的是"flutter_test 的 padding 是我设的那个值"，
// 与"生产代码读的是 MediaQuery"是**两件事**。
//
// # 换成了什么
//
// 两点线性响应（见用例②）：`128 → 256` 设备 px 时位移必须**同样**是
// 48.7619 逻辑 px。写死的常数过不了这一关。
//
// # 教训（可复用）
//
// · **阴性对照必须真的能区分**两种解释。第一版那条对照，
//   "SafeArea 读 MediaQuery"与"SafeArea 读某个被设成 0 的东西"
//   都会让它通过 ⇒ 它没有鉴别力。
// · 写判据前先读**被测框架**的实现。我按真机语义（引擎侧那条 max 公式）
//   推了 flutter_test 的行为，而 flutter_test 的 fake 是**独立字段**。
//   ⇒ 同一个名字在两层的语义不同，这是本项目反复踩的一类坑。
// · 吞异常必须留痕：第一版里第二次 `pumpWidget` 抛的异常被 `_claim`
//   静默吃掉，测试只报「Found 0 widgets with text containing 核心未能启动」，
//   真因一个字都看不到。现在 `_claim` 会 `debugPrint` 出来。

