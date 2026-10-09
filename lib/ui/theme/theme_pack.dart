// ═══════════════════════════════════════════════════════════════════════
//  主题包 —— 一份调色板 + 少量形状/字号参数（JSON 描述）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话
//
// > 4. 主题如果可以做多主题就是外部插件式 或者之类的,能做的话就做一下,
//    不能就直接算了
//
// ⇒ 做成**外部主题包**：一份 JSON 就是一个主题，可以从文件选、可以粘贴、
//   可以放在 `<数据目录>/themes/*.json` 让它自动出现在列表里。
//
// # 为什么用「调色板 + 形状参数」而不是「整个 ThemeData」
//
// ```text
// 整个 ThemeData 序列化 → 版本一改就全废，且用户手写不动
// 一份调色板           → 与 app 的令牌体系一一对应，用户看得懂、改得动
// ```
//
// 所以格式是**扁平的角色 → 颜色**，加上几个可选的形状/字号微调。
// 缺字段一律回落默认值 —— 详见 [ThemePack.resolved]。

import 'dart:convert';
import 'dart:io';

import 'package:cross_file/cross_file.dart' show XFile;
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../app_palette.dart';
import '../../core/ui_prefs.dart';

/// 主题包的格式版本
///
/// ⚠️ 字段**只增不删不改语义**。用户的主题包可能存了很久；
///    解析时必须能认旧版本（[_parseV1] 就是为此）。
const int kThemePackVersion = 1;

/// 一份主题
@immutable
class ThemePack {
  const ThemePack({
    required this.id,
    required this.name,
    required this.brightness,
    required this.palette,
    this.radius,
    this.buttonPadding,
    this.builtin = false,
    this.sourcePath,
  });

  /// 唯一 id（内置主题用 `'builtin.dark'` 这类固定值；外部包用文件名去掉扩展名）
  final String id;

  /// 显示名
  final String name;

  /// 明暗。⚠️ 一份包**只管一档明暗** —— 两档拆成两个包更清楚，
  /// 也避免"深色底配浅色文字"这种组合被配出来。
  final Brightness brightness;

  /// 语义色
  final AppPalette palette;

  /// 控件圆角（null = 用默认 10）
  final double? radius;

  /// 按钮内边距（null = 用默认 `EdgeInsets.symmetric(horizontal: 10, vertical: 11)`）
  final EdgeInsets? buttonPadding;

  /// 是否内置（内置的不可删除）
  final bool builtin;

  /// 外部包的来源路径（内置为 null）
  final String? sourcePath;

  // ── JSON ────────────────────────────────────────────────────────────────

  Map<String, Object?> toJson() => {
        'version': kThemePackVersion,
        'id': id,
        'name': name,
        'brightness': brightness.name,
        'colors': {
          'background': _hex(palette.background),
          'surface': _hex(palette.card),
          'foreground': _hex(palette.foreground),
          'mutedForeground': _hex(palette.mutedForeground),
          'primary': _hex(palette.primary),
          'onPrimary': _hex(palette.primaryForeground),
          'secondary': _hex(palette.secondary),
          'border': _hex(palette.border),
          'error': _hex(palette.error),
        },
        if (radius != null) 'radius': radius,
        if (buttonPadding != null)
          'buttonPadding': {
            'horizontal': buttonPadding!.left,
            'vertical': buttonPadding!.top,
          },
      };

  /// 解析。**任何**非法输入都归一到一份可用的主题包 + 一条警告，
  /// 绝不抛异常 —— 一份坏主题包不该让应用起不来。
  static _Parsed parse(String source, {String? idHint, String? path}) {
    final warnings = <String>[];
    Map<String, Object?> root;
    try {
      final raw = jsonDecode(source);
      if (raw is! Map) {
        return _Parsed(_fallback(idHint, path), ['不是 JSON 对象']);
      }
      root = raw.cast<String, Object?>();
    } catch (e) {
      return _Parsed(_fallback(idHint, path), ['JSON 语法错误：$e']);
    }

    final version = (root['version'] as num?)?.toInt() ?? kThemePackVersion;
    if (version > kThemePackVersion) {
      warnings.add('版本 $version 比本应用新（支持到 $kThemePackVersion），'
          '未知的字段已忽略');
    }

    final brightness = switch ((root['brightness'] as String?)?.toLowerCase()) {
      'light' => Brightness.light,
      'dark' => Brightness.dark,
      'system' || null => null,
      var s => () {
          warnings.add('未知的 brightness「$s」，按跟随系统处理');
          return null;
        }(),
    };
    // 解析不出明暗就用这份主题的底色亮度来判（深色底 = 深色主题）
    final colors = (root['colors'] as Map?)?.cast<String, Object?>();
    if (brightness == null && colors != null) {
      final bg = _unhex(colors['background']);
      final b = bg == null
          ? Brightness.dark
          : (bg.computeLuminance() < 0.5 ? Brightness.dark : Brightness.light);
      return _parseWithBrightness(root, colors, b, warnings, idHint, path);
    }
    return _parseWithBrightness(root, colors, brightness ?? Brightness.dark,
        warnings, idHint, path);
  }

  static _Parsed _parseWithBrightness(
    Map<String, Object?> root,
    Map<String, Object?>? colors,
    Brightness brightness,
    List<String> warnings,
    String? idHint,
    String? path,
  ) {
    final base = brightness == Brightness.dark ? AppPalette.dark : AppPalette.light;

    Color? pick(String key, Color fallback) {
      final raw = colors?[key];
      if (raw == null) return null; // 缺字段 = 用默认，不算错
      final c = _unhex(raw);
      if (c == null) {
        warnings.add('颜色字段 $key 的值「$raw」不是合法的 #RRGGBB，'
            '已回落到默认值');
        return null;
      }
      return c;
    }

    final palette = base.copyWith(
      background: pick('background', base.background) ?? base.background,
      card: pick('surface', base.card) ?? base.card,
      foreground: pick('foreground', base.foreground) ?? base.foreground,
      mutedForeground: pick('mutedForeground', base.mutedForeground) ??
          base.mutedForeground,
      primary: pick('primary', base.primary) ?? base.primary,
      primaryForeground: pick('onPrimary', base.primaryForeground) ??
          base.primaryForeground,
      secondary: pick('secondary', base.secondary) ?? base.secondary,
      border: pick('border', base.border) ?? base.border,
      error: pick('error', base.error) ?? base.error,
    );

    final radius = (root['radius'] as num?)?.toDouble();
    if (radius != null && (radius < 0 || radius > 40)) {
      warnings.add('radius=$radius 超出合理范围 [0,40]，已忽略');
    }

    EdgeInsets? pad;
    final bp = (root['buttonPadding'] as Map?)?.cast<String, Object?>();
    if (bp != null) {
      final h = (bp['horizontal'] as num?)?.toDouble();
      final v = (bp['vertical'] as num?)?.toDouble();
      if (h != null && v != null && h >= 0 && v >= 0 && h < 80 && v < 40) {
        pad = EdgeInsets.symmetric(horizontal: h, vertical: v);
      } else {
        warnings.add('buttonPadding 缺失或超出范围，已忽略');
      }
    }

    return _Parsed(
      ThemePack(
        id: (root['id'] as String?)?.trim().isNotEmpty == true
            ? (root['id'] as String).trim()
            : (idHint ?? 'imported'),
        name: (root['name'] as String?)?.trim().isNotEmpty == true
            ? (root['name'] as String).trim()
            : '导入的主题',
        brightness: brightness,
        palette: palette,
        radius: (radius != null && radius >= 0 && radius <= 40) ? radius : null,
        buttonPadding: pad,
        sourcePath: path,
      ),
      warnings,
    );
  }

  static ThemePack _fallback(String? idHint, String? path) => ThemePack(
        id: idHint ?? 'imported',
        name: '导入的主题',
        brightness: Brightness.dark,
        palette: AppPalette.dark,
        sourcePath: path,
      );

  static String _hex(Color c) =>
      '#${(c.a >= 0.999 ? c.toARGB32() : c.withValues(alpha: 1).toARGB32())
          .toRadixString(16)
          .padLeft(8, '0')
          .substring(2)}';

  static Color? _unhex(Object? v) {
    if (v is! String) return null;
    var s = v.trim().replaceFirst('#', '');
    if (s.length == 6) s = 'ff$s';
    if (s.length != 8) return null;
    final n = int.tryParse(s, radix: 16);
    return n == null ? null : Color(n);
  }

  ThemePack copyWith({
    String? id,
    String? name,
    Brightness? brightness,
    AppPalette? palette,
    double? radius,
    EdgeInsets? buttonPadding,
    bool? builtin,
    String? sourcePath,
  }) =>
      ThemePack(
        id: id ?? this.id,
        name: name ?? this.name,
        brightness: brightness ?? this.brightness,
        palette: palette ?? this.palette,
        radius: radius ?? this.radius,
        buttonPadding: buttonPadding ?? this.buttonPadding,
        builtin: builtin ?? this.builtin,
        sourcePath: sourcePath ?? this.sourcePath,
      );
}

class _Parsed {
  const _Parsed(this.pack, this.warnings);
  final ThemePack pack;
  final List<String> warnings;
}

/// 主题包的解析结果 + 警告（给 UI 提示用）
class ThemePackResult {
  const ThemePackResult(this.pack, this.warnings);
  final ThemePack pack;
  final List<String> warnings;
}

/// 主题包的存取
abstract final class ThemePackStore {
  /// 存储键（当前选中的主题包 id）
  static const storageKey = 'dsh.themepack';

  static final _rev = ValueNotifier<int>(0);

  /// 任何写入后自增，UI 监听它刷新
  static ValueNotifier<int> get revision => _rev;

  static String? _injectedDataDir;

  /// 由 `shell.dart` 在启动时用 `ClipDownload.dataDir()` 注入一次。
  ///
  /// ⚠️ 为什么不能直接在这里 `await`：主题页可能在数据目录解析完成前
  ///   就被打开（保活的 tab 页），而 `loadAll()` 是**同步**的。
  ///   拿不到就回落到 [_fallbackDataDir]，最坏结果是"主题包列表为空"，
  ///   内置主题仍然全都在 —— 不会让应用起不来。
  static void debugSetDataDir(String? dir) => _injectedDataDir = dir;

  static String get _root => _injectedDataDir ?? _fallbackDataDir;

  /// 同步回落：只覆盖 `--dart-define` 与桌面 `%APPDATA%` 两条路径
  /// （与 `core/clip_download.dart` 的 `dataDir()` 同源，只是不 await）。
  static String get _fallbackDataDir {
    const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
    if (override.isNotEmpty) return override;
    final appdata = Platform.environment['APPDATA'] ??
        Platform.environment['HOME'] ??
        '.';
    return '$appdata${Platform.pathSeparator}app.sourin.player';
  }

  /// 主题包目录：`<数据目录>/themes`
  ///
  /// ⚠️ 绝不能落到用户的真实视频目录 —— 一律跟着应用数据目录走。
  static Directory get dir {
    final d = Directory('$_root${Platform.pathSeparator}themes');
    if (!d.existsSync()) {
      try {
        d.createSync(recursive: true);
      } catch (_) {
        // 建不出来（只读介质）→ 导入功能降级，内置主题仍然可用
      }
    }
    return d;
  }

  static List<ThemePack> loadAll() {
    final out = <ThemePack>[...builtins];
    for (final f in _listPackFiles()) {
      final r = parseFile(f);
      // ★ 解析不出来的**不进列表**。
      //   为什么不是"降级也要显示"：主题页的卡片网格里出现一张
      //   名为「导入的主题」、配色全是默认值的卡片，用户完全不知道
      //   自己哪个文件坏了 —— 那种"静默降级"比"明确不显示"更糟。
      //   （手动导入时仍会降级并提示，见 [importFromString]。）
      if (r == null) {
        debugPrint('[THEME] 跳过读不出主题包的文件：${f.path}');
        continue;
      }
      out.add(r.pack);
    }
    return out;
  }

  static List<File> _listPackFiles() {
    try {
      return dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.json'))
          .toList();
    } catch (_) {
      // 目录不存在 / 不可枚举 —— 只用内置主题，不让应用起不来
      return const [];
    }
  }

  /// 读一个主题包文件。
  ///
  /// 返回 `null` = **这个文件不是可用的主题包**（读不了 / 语法错误 / 空）。
  /// 缺字段、非法颜色值那种「局部有问题」仍会降级并带上警告 ——
  /// 那是可用但要提示，与「完全读不懂」是两回事。
  static ThemePackResult? parseFile(File f) {
    final String src;
    try {
      src = f.readAsStringSync();
    } catch (_) {
      return null;
    }
    if (src.trim().isEmpty) return null;
    final parsed = ThemePack.parse(src, idHint: _idOfPath(f.path), path: f.path);
    // 语法 / 结构层面失败 -> 当作「不是主题包」
    if (parsed.warnings.any((w) =>
        w.contains('JSON 语法错误') || w.contains('不是 JSON 对象'))) {
      return null;
    }
    return ThemePackResult(parsed.pack, parsed.warnings);
  }

  /// 从字符串导入（设置页的「粘贴 JSON」入口）
  static ThemePackResult importFromString(String source,
      {String idHint = 'imported'}) {
    final p = ThemePack.parse(source, idHint: idHint);
    return ThemePackResult(p.pack, p.warnings);
  }

  /// 从文件导入 —— 会**落盘**到 [dir]
  ///
  /// ⚠️ 参数是 [XFile] 而不是 `File`：文件选择器返回的就是 `XFile`
  ///    （跨平台、且在 Web 上没有 `File`）。
  static ThemePackResult importFromFile(XFile src) {
    final id = _idOfPath(src.path);
    final r = importFromString(_readOrEmpty(src), idHint: id);
    final target = File('${dir.path}${Platform.pathSeparator}$id.json');
    try {
      target.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(r.pack.toJson()));
      _rev.value++;
    } catch (_) {
      // 落盘失败不致命：至少这一轮能看见（用户可能想立刻切过去）
    }
    return ThemePackResult(r.pack.copyWith(sourcePath: target.path), r.warnings);
  }

  /// 删除一个外部主题包（内置的不可删）
  static bool delete(ThemePack pack) {
    if (pack.builtin || pack.sourcePath == null) return false;
    try {
      File(pack.sourcePath!).deleteSync();
      if (selectedId == pack.id) {
        UiPrefs.remove(storageKey);
        _rev.value++;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 从文件路径取出主题包 id（= 文件名去扩展名）
  ///
  /// ⚠️ 必须自己按分隔符切，**不能**用 `f.uri.pathSegments`：
  ///    `File('C:<BS>Users<BS>x<BS>ok.json').uri` 在 Windows 上解析不出 scheme，
  ///    `pathSegments.last` 会返回**整条路径**（实测），于是 id 变成一个
  ///    含反斜杠的巨型字符串 —— 表现是「导入后在列表里找不到它」。
  static String _idOfPath(String path) {
    // ⚠️ 这里**刻意不用正则**。两种朴素写法都会踩坑：
    // ```dart
    // path.split(RegExp(r'[/\]'))   // 非法字符类：\] 被当成转义右括号
    //                               // ⇒ FormatException: Unterminated character class
    // path.split('/')                // Windows 的路径里一个都不匹配 ⇒ last 是整条路径
    // ```
    // 而 `File.uri.pathSegments` 在 Windows 上同样不给力（见上面那段）。
    // ⇒ 直接按 `Platform` 声明的分隔符切，两个平台的都对。
    final sep = Platform.pathSeparator;
    var base = path;
    final i = base.lastIndexOf(sep);
    if (i >= 0) base = base.substring(i + 1);
    final dot = base.lastIndexOf('.');
    final id = (dot > 0 ? base.substring(0, dot) : base).trim();
    return id.isEmpty ? 'imported' : id;
  }

  static String _readOrEmpty(XFile f) {
    // ⚠️ `readAsStringSync` 在 XFile 上不存在；统一走 path 拿 File。
    //    读不到就返回空串 —— 解析层会给出"JSON 语法错误"的警告并降级。
    try {
      return File(f.path).readAsStringSync();
    } catch (_) {
      return '';
    }
  }

  /// 当前选中的主题包 id
  static String get selectedId => UiPrefs.get(storageKey) ?? '';

  static void select(String id) {
    UiPrefs.set(storageKey, id);
    _rev.value++;
  }

  /// 当前生效的主题包（找不到就回落第一套内置的）
  static ThemePack current() {
    final all = loadAll();
    final id = selectedId;
    for (final p in all) {
      if (p.id == id) return p;
    }
    return all.first;
  }

  // ── 内置主题 ────────────────────────────────────────────────────────────
  //
  // 每套都按 WCAG 调过（见 theme_invariants_test.dart 的对比度断言）。
  // 命名用**用户能懂**的说法，不是色号。

  static ThemePack _dark(String id, String name, AppPalette p) =>
      ThemePack(id: id, name: name, brightness: Brightness.dark, palette: p, builtin: true);

  static ThemePack _light(String id, String name, AppPalette p) =>
      ThemePack(id: id, name: name, brightness: Brightness.light, palette: p, builtin: true);

  /// 内置主题清单
  ///
  /// ⚠️ 顺序 = 主题页的展示顺序，第一套是**默认值**。
  static final List<ThemePack> builtins = [
    _dark('builtin.midnight', '午夜', AppPalette.dark),
    _light('builtin.daylight', '日间', _daylight),
    // OLED 纯黑：像素熄灭 ⇒ 深色下的省电与对比最优
    _dark('builtin.oled', 'OLED 纯黑', AppPalette.dark.copyWith(
      background: const Color(0xFF000000),
      card: const Color(0xFF0B0B0B),
      secondary: const Color(0xFF1C1C1C),
      muted: const Color(0xFF1C1C1C),
      border: const Color(0x3DFFFFFF),
    )),
    // 午夜蓝：给喜欢冷色调的人；正文仍是近白，只有背景偏蓝
    _dark('builtin.midnightBlue', '深海蓝', AppPalette.dark.copyWith(
      background: const Color(0xFF0B1220),
      card: const Color(0xFF141E30),
      secondary: const Color(0xFF1E2C42),
      muted: const Color(0xFF1E2C42),
      border: const Color(0xFF33455F),
    )),
    // 樱粉：暖色，强调色偏粉；正文仍用近白（不牺牲对比度换"氛围"）
    _dark('builtin.sakura', '樱粉', AppPalette.dark.copyWith(
      background: const Color(0xFF14100F),
      card: const Color(0xFF20191C),
      secondary: const Color(0xFF2E2429),
      muted: const Color(0xFF2E2429),
      border: const Color(0xFF3A2E35),
      primary: const Color(0xFFF2B8C6),
      primaryForeground: const Color(0xFF231419),
      error: const Color(0xFFFF8A8A),
    )),
    // 森绿：把"主色"从浅灰换成叶绿，于是选中态、开关、滑杆都带上绿色语言
    _dark('builtin.forest', '森绿', AppPalette.dark.copyWith(
      background: const Color(0xFF0A0F0C),
      card: const Color(0xFF121A15),
      secondary: const Color(0xFF1B271F),
      muted: const Color(0xFF1B271F),
      border: const Color(0xFF24332A),
      primary: const Color(0xFF8ED9A8),
      primaryForeground: const Color(0xFF0C1A11),
      error: const Color(0xFFFF9E8A),
    )),
  ];

  /// 日间（浅色）
  ///
  /// 沿用原版 `theme-light.css` 的那一套（`--bg-base: #eef0f6` /
  ///   `--brand-1: #3b6fe0`），已在项目里跑了很久，不重新发明。
  static final AppPalette _daylight = AppPalette.light.copyWith(
        background: const Color(0xFFEEF0F6),
        foreground: const Color(0xFF1E2028),
        mutedForeground: const Color(0xFF70727A),
        secondary: const Color(0xFFE8EAF0),
        secondaryForeground: const Color(0xFF1E2028),
        muted: const Color(0xFFE8EAF0),
        card: const Color(0xFFFFFFFF),
        border: const Color(0xFFD7DAE4),
        primary: const Color(0xFF3B6FE0),
        primaryForeground: Colors.white,
        error: const Color(0xFFD93025),
      );
}
