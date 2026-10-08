// ═══════════════════════════════════════════════════════════════════════
//  主题双色 —— 三态：跟随系统 / 深色 / 浅色
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户指出「主题双色你没做」—— 确实没做，这条是补的
//
// 原版**有完整的双主题**：
// ```text
// src/design/theme.ts          89 行   三态管理 + localStorage + 跟随系统
// src/design/theme-light.css  12947 B  浅色主题全部令牌
// ```
// 我之前只做了深色（forui 的 neutral.dark），把原版的浅色整套漏掉了。
//
// # 原版的设计要点（照抄，不自己发明）
//
// `theme-light.css` 开头明确写了 5 条，**浅色不是简单反色**：
//
// ```text
// 1. 玻璃在亮背景上要"提亮"而非"压暗"
//    深色用白色低透明叠加；浅色必须用白色**高**透明（0.6+），
//    否则玻璃会消失或显脏
// 2. 氛围光球要大幅降透明度
//    深色下 0.5 的彩色光球放到白底上会糊成脏色 → 降到 0.18~0.22
// 3. 阴影要更轻更散（深色靠深阴影分层，浅色阴影过重会显脏）
// 4. 文字对比度：不能纯黑（刺眼），用 0.92 的黑；次要 0.58~0.60
// 5. **描边要反过来**
//    深色用白色描边提亮边缘；浅色要用**深色描边**才有轮廓
// ```
//
// # 与原版的三处**必要的**实现差异（已确认不影响观感）
//
// ```text
// ① 原版靠 `<html data-theme="light">` + CSS 变量切换（浏览器特性）
//    我们用 Dart 对象 —— 同一套色值，切换时机一致
// ② 原版跟随系统用 `matchMedia("(prefers-color-scheme: light)")`
//    我们用 `PlatformDispatcher.instance.platformBrightness`
// ③ 原版存 localStorage，我们存 `UiPrefs`（同一个 ui-prefs.json）
// ```

import 'package:flutter/foundation.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import '../core/ui_prefs.dart';
import 'theme_bridge.dart';

/// 主题切换的全局信号
///
/// # 为什么需要（2026-09-24 用户指出「主题双色你没做」）
///
/// 设置页改主题后要**立刻**生效，但设置页在很深的子树里，
/// 而 `MaterialApp` 在最顶层 —— 没有共同的 State 可提升。
///
/// 原版是 Vue 的响应式 `ref`（`themeMode`），改了就自动重渲染。
/// Flutter 侧等价物就是 `ValueNotifier`。
///
/// ⚠️ 放在这个**中立文件**里，不放在 `shell.dart`：
///    `shell.dart` 已经 import 了 `settings_page.dart`，
///    设置页若反过来 import `shell.dart` 就成**环**了
///    （Dart 允许环，但顶层 `final` 的初始化顺序会有隐患 ——
///     标题栏那轮已经因为这个把 `titleBarVisible` 挪出来过一次）。
final appThemeRevision = ValueNotifier<int>(0);

/// 请求重建主题（设置页改完主题后调它）
void notifyThemeChanged() => appThemeRevision.value++;

/// 主题模式（三态，与原版 `ThemeMode` 一一对应）
enum AppThemeMode {
  system('system', '跟随系统'),
  light('light', '浅色'),
  dark('dark', '深色');

  const AppThemeMode(this.id, this.label);

  /// 存储用的 id（与原版 `localStorage` 的值一致，便于将来迁移）
  final String id;

  /// 设置页显示的名字
  final String label;
}

/// 主题管理器
class AppTheme {
  /// 存储键 —— **故意用原版的键名** `dsh.theme`
  ///
  /// 虽然我们存在 `UiPrefs`（JSON）而不是 localStorage，
  /// 但保持键名一致：将来做"从原版导入设置"时能直接对上。
  static const storageKey = 'dsh.theme';

  /// 用户选择（默认 `system`，与原版一致）
  static AppThemeMode get mode {
    final v = UiPrefs.get(storageKey);
    if (v == null) return AppThemeMode.system;
    for (final m in AppThemeMode.values) {
      if (m.id == v) return m;
    }
    return AppThemeMode.system; // 值非法时回落（原版同款行为）
  }

  static void setMode(AppThemeMode m) => UiPrefs.set(storageKey, m.id);

  /// 原始存储值（`null` = **从没设过**，与"设成了 system"不同）
  ///
  /// # 为什么需要区分（2026-09-24 踩到）
  ///
  /// 交付实测要在真实应用里验证三态持久化，它会把三个值依次写一遍
  /// 再"还原"。但**还原成 `system` 不等于还原成"没设过"**：
  /// ```text
  /// 用户真实 ui-prefs.json（原本）：{"dsh.srcpref....":"cychub"}
  /// 跑完交付实测后被写成：        {..., "dsh.theme":"system"}   ← 多了个键
  /// ```
  /// 实测确认：我上一轮的交付测试**真的往用户真实偏好文件里加了
  /// `"dsh.theme":"system"`**。虽然语义等价（默认就是 system），
  /// 但那是**未经要求修改了用户数据** —— 必须修掉。
  ///
  /// 修法：探针保存**原始存储值**（可能是 null），测完原样写回。
  static String? get rawStored => UiPrefs.get(storageKey);

  /// 原样恢复（`null` = 删掉那个键，回到"从没设过"）
  static void restoreRaw(String? raw) {
    if (raw == null) {
      UiPrefs.remove(storageKey);
    } else {
      UiPrefs.set(storageKey, raw);
    }
  }

  /// 解析成实际生效的明暗（`system` 时读系统偏好）
  ///
  /// 原版：
  /// ```ts
  /// const effective = themeMode === "system"
  ///   ? (systemPrefersLight() ? "light" : "dark")
  ///   : themeMode;
  /// ```
  static Brightness resolve({required Brightness systemBrightness}) {
    switch (mode) {
      case AppThemeMode.light:
        return Brightness.light;
      case AppThemeMode.dark:
        return Brightness.dark;
      case AppThemeMode.system:
        return systemBrightness;
    }
  }

  /// 取对应的 forui 主题
  ///
  /// ⚠️ 用 `FTheme.neutral.{light,dark}` 而不是 `FTheme.zinc` 等 ——
  ///    `neutral` 的色相最接近原版的"无彩色 + 品牌色点缀"。
  ///    （原版 `--bg-base: #eef0f6` 有极轻微的蓝，forui neutral
  ///     的 `#FAFAFA` 更中性；这属于允许的视觉优化范围。）
  /*
   * ══════════════════════════════════════════════════════════════════
   * ★★★ 2026-10-08（Owner 第 6 条）字体统一 —— 唯一注入点
   * ══════════════════════════════════════════════════════════════════
   *
   * 用户原话：
   * > 字体大大小小 粗细不一,要优化 看看有没有苹果字体或者之类的
   * > 能不能内置进去,如果要增加很大的体积就算了,
   * > 但是这个粗细大小不一需要修复
   *
   * # 「粗细不一」的**机械成因**（不是玄学，已用字体二进制坐实）
   * ```text
   * ① 本工程**没有自己的字体**：主字族是 forui 自带的
   *    `packages/forui/Inter`（typography.dart:137 defaultFontFamily）
   * ② Inter.ttf 的 cmap 里**零中文覆盖**
   *    （解析实测：U+4E2D/U+6587/U+6D4B/U+89C6 → glyphId 0）
   *    ⇒ 界面上的**每一个汉字**都是引擎按字形回退到系统字体画的
   * ③ 本机 zh-CN 的回退族 `Microsoft YaHei UI` **只有 400 / 700 两个真实面**
   *    （msyh.ttc numFonts = 2），DirectWrite 选面实测：
   *      w400 → Normal   w500 → Normal(!!)   w600 → Bold(!!)
   *      w700 → Bold     w800 → Bold(!!)
   * ④ 而代码里用了 **5 档字重**（w400/500/600/700/800 共 138 处）
   *    而拉丁/数字走 Inter（真可变字重 100–900）
   * ⇒ 同一行里「汉字满粗、数字半粗」= 用户说的「粗细不一」
   * ```
   *
   * # 修法：让**拉丁与汉字同族**（零体积，不加任何字体文件）
   * ```text
   * 把主字族从 `packages/forui/Inter` 换成系统里**同时覆盖中英文**的族：
   *   Windows → `Microsoft YaHei UI`（回退 Microsoft YaHei / Segoe UI）
   *   其它端  → `Noto Sans CJK SC`（Android 自带）
   * ⇒ 同一个字重请求在两个文种上落到**同一个面** ⇒ 粗细一致 ✓
   * ```
   *
   * # 为什么**不**内置苹果字体（用户说「体积大就算了」）
   * ```text
   * ① SF Pro / PingFang SC 是 Apple 专有字体，授权只覆盖 Apple 设备，
   *    跨平台分发**不合规**
   * ② 中文字体全字集体积下不来：本机对照 NotoSansSC-VF.ttf = 17,773,244 B
   *    而 Windows 发布包整包才 76.21 MB ⇒ **+23%**
   * ③ 原版 Vue 本来就是靠 `-apple-system` / `PingFang SC` 用**系统**字体
   *    （`cctv_to_client/src/design/base.css:288-291`），从来没内置过
   * ⇒ macOS 上自然就是苹果字体；Windows/Android 上统一成雅黑/思源。
   * ```
   *
   * # ⚠️ 为什么必须走**工厂构造**（不能 copyWith）
   * ```text
   * `FThemeData.copyWith` **改不了 typography** ——
   * theme_data.dart:1343-1418 的参数表里根本没有 typography，
   * 函数体 :1416 写死 `typography: typography`（且 touch: true）。
   * ⇒ 唯一出路是工厂构造（形状照抄 forui 自己的 `theme.dart:160-169`）：
   *   只给 colors / touch / typography，其余 style/icons 由
   *   theme_data.dart:616-618 自动从 typography 派生 ⇒ 与改前**逐字段一致**，
   *   只有字族变 —— 这是一次**外科手术式**的改法。
   * ```
   *
   * ⚠️ `touch: false` 必须写死：改前两个分支用的都是 `.desktop` 变体。
   * ⚠️ `FTypeface.inherit` 会自己按 touch 选桌面/触屏字号表 ⇒
   *    **字号一档都不动**（只换字族）。
   */
  static FThemeData themeFor(Brightness b) {
    final colors = b == Brightness.light
        ? FColors.neutralLight
        : FColors.neutralDark;
    /*
     * ★ 字族选择：Windows 用雅黑，其它端用 Noto（Android 自带）。
     *
     * ⚠️ 用 `defaultTargetPlatform` 而不是 `Platform.isWindows` ——
     *    前者在 widget 测试里可被 `ThemeData.platform` 覆盖
     *    （`transition_clip_titlebar_test.dart` 就是这么做的），
     *    后者会读真实宿主 OS，测试里不可控。
     */
    final family = defaultTargetPlatform == TargetPlatform.windows
        ? 'Microsoft YaHei UI'
        : 'Noto Sans CJK SC';
    final face = FTypeface.inherit(
      colors: colors,
      touch: false,
      fontFamily: family,
      /*
       * 回退链：雅黑缺字（生僻字/符号）时按顺序往下找。
       * ⚠️ 不加 'Inter' —— 它没有中文，加进去只会让拉丁与汉字
       *    又分到两个字族上（正是本次要修的那个问题）。
       */
      fontFamilyFallback: const ['Microsoft YaHei', 'Noto Sans SC', 'Segoe UI'],
    );
    return FThemeData(
      colors: colors,
      touch: false,
      typography: FTypography(display: face, body: face),
    );
  }

  /// 窗口「地板色」—— 自绘标题栏的玻璃**背后**垫的那一层
  ///
  /// # 为什么要集中成一个方法（2026-09-25 真机取证，任务 AB）
  ///
  /// `shell.dart` 的 `MaterialApp.builder` 里原来写的是：
  /// ```dart
  /// color: brightness == Brightness.light
  ///     ? LightTokens.bgBase
  ///     : FTheme.of(context).colors.background,   // ← 错在这里
  /// ```
  /// 明暗**判断**那一半是对的（用的是自己解析的 `brightness`），
  /// 但**取色**那一半走了 `FTheme.of(context)` ——
  /// 而 `builder` 的 `context` 在 `FTheme` **上面**：
  /// ```text
  /// LiquidGlassWidgets.wrap
  ///  └ MaterialApp
  ///      ├ builder(context, child)  ← 这个 context 找不到 FTheme
  ///      │   └ FTheme(data: theme)  ← 注入在这下面（builder 返回值里）
  ///      └ theme: materialTheme
  /// ```
  /// forui 的 `FTheme.of` **找不到祖先时不抛异常**，而是静默兜底成
  /// `FTheme.neutral.light.touch`（forui `src/theme/theme.dart:140`）——
  /// 也就是**浅色**。于是深色下这层地板是**纯白 `#FFFFFF`**。
  ///
  /// ⚠️ 这与本项目已记录的 `Theme.of` 坑是**同一个坑的 forui 版**：
  ///    两套主题系统都有"找不到祖先就静默兜底成浅色"的行为，
  ///    而且都**不报错** —— 只能靠像素取证抓出来。
  ///
  /// 后果（实测）：标题栏玻璃透出 `(239,239,239)` 浅灰，
  /// 而内容区 `FScaffold` 自己画的是 `#0A0A0A` —— 一条浅色横条压在深色内容上。
  ///
  /// 修法：只认调用方**自己算出来的** `brightness`，
  /// 色值从 `themeFor(brightness)` 取 —— 与 `MaterialApp.theme` 同源。
  ///
  /// # 为什么浅色仍用 [LightTokens.bgBase] 而不是 forui 的 background
  ///
  /// forui 的 `neutral.light.background` 是**纯白 `#FFFFFF`**，
  /// 而玻璃是"半透明白叠在底色上"—— 白叠白等于没有色差，
  /// 玻璃会整个消失。所以浅色必须用原版那一档带蓝的浅灰
  /// （`--bg-base: #eef0f6`）。这条是既有结论，本次不改。
  static Color floorColor(Brightness b) => b == Brightness.light
      ? LightTokens.bgBase
      : themeFor(b).colors.background;

  /// ★★★ 窗口描边色 —— 用来把本窗口与其它浅色窗口区分开
  ///
  /// # 用户原话（2026-09-25）
  ///
  /// > 这次你改的没有了,但是不是应该加个浅色的边框或者阴影的,
  /// > 用来区分跟其他浅色客户端的重叠
  ///
  /// # 为什么是"细边框"而不是"阴影"
  ///
  /// 用户此前**明确否掉过阴影**（原话「这个背景怎么有一圈阴影?」），
  /// 那次修法是在窗口创建时去掉 `WS_THICKFRAME`。副作用是
  /// **连窗口边界一起没了**，于是与其它浅色窗口糊在一起。
  ///
  /// ⇒ 现在的诉求是**边界**，不是**投影**。两者要分开：
  /// ```text
  /// 阴影（已否）  7px 渐变带，占窗口外空间，DWM 画
  /// 边框（本次）  1px 实线，画在窗口【内侧】，Flutter 画
  /// ```
  ///
  /// # 色值怎么定的
  ///
  /// 必须**比内容暗一档、比纯黑浅很多** —— 目标是"看得出边界"但
  /// "不像一条黑框"。浅色取 `#E3E5EB`（比 `--bg-base: #eef0f6` 暗
  /// 约 11 级），深色取 `#2A2A2A`（比 `#0A0A0A` 亮约 32 级）。
  ///
  /// ⚠️ 深色下**不能**用浅色边（会变成"深色窗口套白框"，很刺眼）；
  ///    这也是本方法收 [Brightness] 而不是返回常量的原因。
  static Color windowBorderColor(Brightness b) => b == Brightness.light
      ? const Color(0xFFE3E5EB)
      : const Color(0xFF2A2A2A);

  /// ★★★ 窗口投影色 —— 「像 QQ 那种边缘模糊阴影」
  ///
  /// # 用户原话（2026-09-25）
  ///
  /// > 像 qq 客户端这种边缘模糊阴影,之前的是实体的非常难看
  ///
  /// # 为什么系统给不了（实测，不是推测）
  ///
  /// ```text
  /// ① DWM 阴影 —— ★ 本机拿不到
  ///    DwmGetWindowAttribute(EXTENDED_FRAME_BOUNDS) = 0,0,0,0
  ///    即使 CAPTION=True + THICKFRAME=True 也仍是 0,0,0,0
  ///    ★ 根因是【系统设置】：VisualFXSetting = 2（「调整为最佳性能」）
  ///      ⇒ 用户机器上"窗口阴影"这个视觉特效被系统关掉了
  ///      ⇒ 依赖系统 = 在用户机器上必然拿不到
  /// ② SetWindowCompositionAttribute 的 accent 渐变
  ///    能画色带，但那是【实心硬色带】= 用户说的「实体的非常难看」
  /// ③ SetWindowRgn —— 二值裁剪，做不出模糊
  /// ```
  ///
  /// ⇒ 只能自绘。返回值只用**明度**（绘制时按层降 alpha）：
  /// ```text
  /// 浅色主题  #1A1D26  —— 带一点蓝的深色，与浅灰地板色搭配自然
  /// 深色主题  #000000  —— 纯黑，在深色底上最干净
  /// ```
  static Color windowShadowColor(Brightness b) => b == Brightness.light
      ? const Color(0xFF1A1D26)
      : const Color(0xFF000000);
}

// ═══════════════════════════════════════════════════════════════════════
//  浅色主题的**语义角色补全**
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么浅色也需要补（对称于深色的 theme_bridge）
//
// 深色那边踩过一次坑：`toApproximateMaterialTheme()` **只填一部分角色**，
// 其余留空，而 Material 的 getter 兜底值恰好会让「卡片底 = 背景色」
// 「边框 = 纯白」—— 设置页标题对比度只有 1.16:1（几乎看不见）。
//
// 浅色下**同样的问题**存在，只是表现相反：
// ```text
// 深色漏填 → 兜底成亮色 → 白底黑字（看起来"没主题"）
// 浅色漏填 → 兜底成暗色 → 黑底浅字（卡片变黑块）
// ```
// 所以两套都要走 bridge。
//
// 色值取自原版 `theme-light.css`：
// ```text
// --bg-base        #eef0f6   → surface / background
// --bg-elevated    #ffffff   → surfaceContainer（卡片）
// --text-primary   rgb(16 18 26 / .93)  → onSurface
// --text-secondary rgb(16 18 26 / .60)  → onSurfaceVariant
// --divider        rgb(16 18 26 / .07)  → outlineVariant
// --brand-1        #3b6fe0   → primary
// ```

/// 浅色主题的语义色（照抄原版 `theme-light.css`）
class LightTokens {
  /// `--bg-base: #eef0f6`
  static const bgBase = Color(0xFFEEF0F6);

  /// `--bg-elevated: #ffffff`
  static const bgElevated = Color(0xFFFFFFFF);

  /// `--text-primary: rgb(16 18 26 / 0.93)`
  ///
  /// ⚠️ 不是纯黑 —— 原版注释：「不能纯黑（刺眼）」。
  ///    在 `#eef0f6` 上合成后约 `#1E2028`。
  static const textPrimary = Color(0xFF1E2028);

  /// `--text-secondary: rgb(16 18 26 / 0.60)` → 合成后约 `#70727A`
  static const textSecondary = Color(0xFF70727A);

  /// `--divider: rgb(16 18 26 / 0.07)` → 合成后约 `#DFE1E8`
  static const divider = Color(0xFFDFE1E8);

  /// `--glass-stroke: rgb(16 18 26 / 0.045)`
  static const glassStroke = Color(0xFFE4E6EC);

  /// `--brand-1: #3b6fe0`（浅色下比深色**略深**，保证白底对比度）
  static const brand = Color(0xFF3B6FE0);

  /// `--brand-2: #8b4de8`
  static const brand2 = Color(0xFF8B4DE8);

  /// 错误色 —— 浅色下也需要保证在白底上可读
  static const error = Color(0xFFD93025);

  /// 错误容器底色（浅红）
  static const errorContainer = Color(0xFFFCE8E6);

  /// 次级容器（`--surface-2` 合成值）
  static const surface2 = Color(0xFFF5F7FA);
}

/// 给浅色主题补全 Material 语义角色
///
/// 与 `theme_bridge.dart` 的 `buildMaterialTheme` 对称 ——
/// 那边补深色，这边补浅色。
///
/// ⚠️ 两个函数是**独立**的，不是一个按 brightness 分支的共用函数
///    （要补的角色不同：浅色要反过来设 surface / onSurface / 描边）。
///    ★ 所以**任何一处修复都必须在另一处同步做**。
///    末尾的 `fixButtonContrast` 就是必须同步的那一步 ——
///    它修的是 **forui `toApproximateMaterialTheme()` 自带的
///    `filledButtonTheme` 复制粘贴 bug**（详情页「播放」按钮
///    浅色下 1.00:1、深色下 1.21:1，都是一块看不见字的药丸）。
///    详见 `theme_bridge.dart` 里 `fixButtonContrast` 的文档。
ThemeData buildLightMaterialTheme(FThemeData theme) {
  final base = theme.toApproximateMaterialTheme();
  final cs = base.colorScheme;

  return fixButtonContrast(
    base.copyWith(
      /*
       * ★ 转场 scrim 透明（修任务⑰⑤「播放页白色条盖住顶部操作条」）
       *
       * 浅色下 `surface = LightTokens.bgBase = #EEF0F6`，
       * 而 `ZoomPageTransitionsBuilder` 会拿 `surface` 当 scrim
       * 铺满**离场路由**（含顶部操作条）—— 用户看到的就是这条"白色条"。
       * 显式传 `Colors.transparent` 只去掉那层色块，缩放淡入动画保留。
       *
       * 详见 `theme_bridge.dart` 的 `buildPageTransitionsTheme`。
       */
      pageTransitionsTheme: buildPageTransitionsTheme(),
      colorScheme: cs.copyWith(
        brightness: Brightness.light,

        // ── 表面层级（浅色下"越高越白"，与深色相反）──
        surface: LightTokens.bgBase,
        surfaceContainerLowest: LightTokens.bgElevated,
        surfaceContainerLow: LightTokens.bgElevated,
        surfaceContainer: LightTokens.bgElevated,
        surfaceContainerHigh: const Color(0xFFF7F8FB),
        surfaceContainerHighest: LightTokens.surface2,

        // ── 文字 ──
        onSurface: LightTokens.textPrimary,
        onSurfaceVariant: LightTokens.textSecondary,

        // ── 描边：浅色下必须是**深色**描边才有轮廓（原版要点 ⑤）──
        outline: LightTokens.glassStroke,
        outlineVariant: LightTokens.divider,

        // ── 品牌色 ──
        primary: LightTokens.brand,
        onPrimary: const Color(0xFFFFFFFF),
        primaryContainer: const Color(0xFFDCE6FB),
        onPrimaryContainer: const Color(0xFF10305E),

        // ── 错误 ──
        error: LightTokens.error,
        onError: const Color(0xFFFFFFFF),
        errorContainer: LightTokens.errorContainer,
        onErrorContainer: const Color(0xFF5F1410),

        // ── 其余 ──
        secondary: const Color(0xFFE8EAF0),
        onSecondary: LightTokens.textPrimary,
        /*
         * ★ `secondaryContainer` / `onSecondaryContainer` 也要显式给。
         *
         * forui 的转换方法把它们设成了 `colors.secondary` /
         * `colors.secondaryForeground`，浅色下是 `#F5F5F5` / `#171717`
         * —— 对比度 16.44:1 没问题，但那是 **forui 的中性灰**，
         * 与我们上面设的 `secondary`（`#E8EAF0`，带一点蓝）不是同一个。
         *
         * 留着不管的后果是 FilledButton.tonal 看起来"没跟着主题走"
         * —— 它就是读这两个角色的（`filled_tonal_button_defaults_m3.g.dart:31,40`）。
         */
        secondaryContainer: const Color(0xFFE8EAF0),
        onSecondaryContainer: LightTokens.textPrimary,
        surfaceTint: const Color(0x00000000),
      ),
    ),
  );
}
