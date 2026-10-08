// t457 守卫：播放页顶栏的「快捷键」入口**只在对该端真的有意义时才出现**。
//
// 缺陷背景（Lead 读源码 + 真机冒烟证实，2026-10-04，task-20）：
//   `hintsFor()` 在触摸端返回**空列表**（触摸端没有键盘 —— 见该函数自己的注释），
//   但 `_TopBar` 的「快捷键」按钮**无条件**渲染 ⇒ 手机用户点开的是一个
//   只有标题「快捷键」+「点击任意处关闭」的**空面板**。
//
//   这类缺陷的特征与 t456 同族：不会编译报错、不会抛异常、
//   测试也全绿（面板确实「打开了」）—— 只是**对用户毫无意义**。
//
// ★ 为什么是「隐藏」而不是「给触摸端补一批提示」：
//   触摸端真的没有键盘可按，写上去就是「假装有」。
//   产品原则与插件 / TVBox 那套一致：**没有的能力不假装有**。
//
// ★★ 本文件**刻意不挂 widget**（真行为测试在 `t458_hints_entry_ui_test.dart`，
//   那个文件加载 libmpv 所以打了 `native-media` 标签、默认不跑）。
//   这里只做**静态可判定**的契约 —— 好处是它在默认全量跑里每次都真跑，
//   改坏了一行代码就立刻红，而不是等到有人想起来加 `--tags native-media`。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/ui/player_page.dart';

/// 递归收集 .dart 文件（照抄 `t456_media_route_touch_test.dart:23-31`）。
List<File> dartFilesUnder(Directory dir) {
  final out = <File>[];
  if (!dir.existsSync()) return out;
  for (final e in dir.listSync(recursive: true, followLinks: false)) {
    if (e is File && e.path.endsWith('.dart')) out.add(e);
  }
  out.sort((a, b) => a.path.compareTo(b.path));
  return out;
}

void main() {
  late String src;

  setUpAll(() {
    final f = File('lib/ui/player_page.dart');
    expect(f.existsSync(), isTrue,
        reason: '★ 读不到源码 ⇒ 本文件全部无从判起（空断言比没断言更危险）');
    src = f.readAsStringSync();
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① 上游前提：触摸端的提示表**本来就是空的**
  // ═══════════════════════════════════════════════════════════════════
  //
  // ★ 这条必须最先钉住。若哪天有人给触摸端补了提示，
  //   「触摸端不许有键盘图标」就成了错的判据 —— 那时应当**恢复按钮**，
  //   而不是删掉这个测试。
  group('① 上游前提（钉住「触摸端本来就没提示」这个事实）', () {
    test('★ 触摸端 hints 为空；PC / TV 非空', () {
      expect(
        hintsFor(isTv: false, isTouchOnly: true, isLive: false),
        isEmpty,
        reason: '★★ 本修复的**前提**：触摸端没有键盘 ⇒ 没有任何快捷键可列。'
            '若这条红了，说明有人给触摸端补了提示 —— 请**恢复**该入口而不是删本测试',
      );
      expect(
        hintsFor(isTv: false, isTouchOnly: false, isLive: false),
        isNotEmpty,
        reason: '★ PC 端有 8 条（`kDesktopHints`）',
      );
      expect(
        hintsFor(isTv: true, isTouchOnly: false, isLive: false),
        isNotEmpty,
        reason: '★ TV 端有 4 条（`kTvHints`）',
      );
    });

    test('★ 直播页也遵守同一前提（触摸端直播仍是空）', () {
      expect(hintsFor(isTv: false, isTouchOnly: true, isLive: true), isEmpty);
      expect(hintsFor(isTv: false, isTouchOnly: false, isLive: true), isNotEmpty);
      expect(hintsFor(isTv: true, isTouchOnly: false, isLive: true), isNotEmpty);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 源码契约：按钮必须被门控，调用点必须按 hints 判空
  // ═══════════════════════════════════════════════════════════════════
  group('② 源码契约（改坏一行就红）', () {
    test('`_TopBar.onHints` 是可空字段（否则调用点没法表达「这一端没有」）', () {
      expect(
        src.contains('final VoidCallback? onHints;'),
        isTrue,
        reason: '★ `onHints` 必须可空 —— 不可空就只能画一个空面板',
      );
      expect(
        src.contains('required this.onHints,'),
        isFalse,
        reason: '★ 构造参数不许是 required（那等于强制每个调用点都给一个按钮）',
      );
    });

    test('★ 按钮被 `if (onHints != null)` 门控', () {
      expect(
        src.contains('if (onHints != null)'),
        isTrue,
        reason: '★★ 这是本缺陷的**唯一**修复点：没有这行，触摸端就会画出按钮',
      );
      expect(
        src.contains('onPressed: onHints,'),
        isTrue,
        reason: '★ 门控之内仍要真的把回调接上（门控不能把 PC 端也一起关掉）',
      );
    });

    test('★ 调用点按 `hints.isEmpty` 决定传不传', () {
      expect(
        src.contains('onHints: hints.isEmpty ? null : _toggleHints,'),
        isTrue,
        reason: '★★ 判据必须绑在 `hints`（真实数据）上，而不是绑在 `Device.isTouchOnly` ——'
            '后者会在「TV 遥控器没有键盘」这类端上漏判',
      );
      expect(
        src.contains('hints.isEmpty'),
        isTrue,
        reason: '★ 显式再确认一次「判空」这件事真的写在调用点',
      );
    });

    test('★ 键盘图标全仓只此一处（改错地方会被这条抓到）', () {
      final hits = <String>[];
      for (final f in dartFilesUnder(Directory('lib'))) {
        if (f.readAsStringSync().contains('Icons.keyboard_outlined')) {
          hits.add(f.path.replaceAll('\\', '/'));
        }
      }
      expect(
        hits,
        <String>['lib/ui/player_page.dart'],
        reason: '★ 播放页顶栏的键盘入口若被挪到别处，本测试必须跟着更新（不是自动通过）',
      );
    });
  });
}
