// ======================================================================
//  *** CR-28 反向验证：主题门禁**不是**假门禁（2026-10-10）
// ======================================================================
//
//  # 这个文件存在的唯一理由
//
//  本仓铁律：「**假门禁比红更糟**」。
//  CR-03 骂的就是仓里已有的假测试；CR-28 骂的是 `theme_regression_test.dart`
//  里那条 `src.contains('buildMaterialTheme(')` —— 它**能命中注释**。
//
//  # ** 先把「缺陷」摆出来（不是推测，是实测）
//
//  ```text
//  lib/shell.dart 原始文本   buildMaterialTheme( 出现 2 次
//  剥掉注释之后             buildMaterialTheme( 出现 0 次
//  => 两次全在注释里，而旧断言 contains 照样为 true => 绿
//  => 旧门禁守的是**注释文本**，不是代码
//  ```
//
//  # 所以光「改断言」不够 —— 必须能证明新门禁**会红**
//
//  本文件用两条腿证明：
//  ① **腿 A（结构）**：真门禁 `test/theme_regression_test.dart`
//     必须 import 共享实现，且**不允许**再出现裸 contains 断言。
//     => 修之前这条**真红**（RED）。
//  ② **腿 B（行为）**：把 `lib/shell.dart` 真实文本拿去做**变异**，
//     变异体落到系统临时目录（* 不碰仓库里的真实文件）：
//       · 注释里加一次调用文本  => 门禁**必须仍绿**
//         （证明注释既不能**满足**门禁、也不能**破坏**门禁）
//       · 真代码里去掉 theme 绑定 => 门禁**必须变红**
//       · 真代码里去掉 theme 来源 => 门禁**必须变红**
//
//  ⚠ 变异体写在 `Directory.systemTemp`，**绝不在仓库里建临时 .dart**。
//     （仓库里 34 个 lib/*_probe.dart 是有意的既有约定，这里只是数据。）

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '_support/strip_comments.dart';
import 'zz_cr_nit_shell_theme_gate.dart';

const String kShellPath = 'lib/shell.dart';
const String kGatePath = 'test/theme_regression_test.dart';

/// 极小的 shell.dart 形状样本（够门禁用的最小结构）
const String _kGood = r'''
class X {
  Widget build(BuildContext context) {
    final brightness = AppTheme.resolve();
    final materialTheme = AppTheme.themeFor(brightness);
    return MaterialApp(
      theme: materialTheme,
      home: const SizedBox(),
    );
  }
}
''';

/// **只有注释**里提到那个调用，代码里一次都没有（= 旧门禁的中招样本）
const String _kCommentOnlyDecoy = r'''
// 老实现写的是 buildMaterialTheme( foruiTheme, bridge )
class X {
  Widget build(BuildContext context) {
    final brightness = AppTheme.resolve();
    return MaterialApp(home: const SizedBox());
  }
}
''';

/// 变异体只落在这里，**绝不写进仓库**（铁律：不许在仓库里造临时 .dart）。
///
/// ⚠ 必须是 setUpAll/tearDownAll 一对：若用 addTearDown，
///   第一条测试结束时目录就被删了，而 late final 仍记着那个路径
///   ⇒ 后续测试报 PathNotFound（**假红**，踩过）。
Directory? _tmpDir;

void _setUpTmpDir() {
  _tmpDir = Directory.systemTemp.createTempSync('cr28_');
}

void _tearDownTmpDir() {
  final d = _tmpDir;
  if (d != null && d.existsSync()) d.deleteSync(recursive: true);
}

void main() {
  late String real;

  setUpAll(() {
    real = File(kShellPath).readAsStringSync();
    _setUpTmpDir();
  });

  tearDownAll(_tearDownTmpDir);

  group('① 事实认定：旧门禁确实是假门禁（不是推测）', () {
    test('★ shell.dart 里的那个调用只存在于注释中', () {
      final rawHits = 'buildMaterialTheme('.allMatches(real).length;
      final code = stripComments(real);
      final codeHits = 'buildMaterialTheme('.allMatches(code).length;

      expect(rawHits, greaterThan(0),
          reason: '若 shell.dart 里一次都没出现，说明缺陷前提变了，本文件要重写');
      expect(codeHits, 0,
          reason: '★ shell.dart 的真实代码里**不该**再调那个桥接函数 —— '
              '入口已改成 AppTheme.themeFor()。这正是裸 contains 只能靠注释过门的原因。');
      expect(real.contains('buildMaterialTheme('), isTrue,
          reason: '★ 复现缺陷：裸 contains 对「只在注释里的文本」返回 true ⇒ 旧门禁永远绿');
    });

    test('裸 contains 对「只有注释里有该调用」的样本同样返回 true', () {
      expect(_kCommentOnlyDecoy.contains('buildMaterialTheme('), isTrue,
          reason: '★ 旧门禁的病根：它分不出注释与代码');
      expect(shellThemeBindingHasMatch(_kCommentOnlyDecoy), isFalse,
          reason: '★ 新门禁必须对「只有注释里有该调用」返回 false');
    });
  });

  group('② 腿 A：真门禁本身的结构（修之前是 RED）', () {
    test('★★ theme_regression_test.dart 必须 import 共享门禁实现', () {
      final gate = File(kGatePath).readAsStringSync();
      expect(gate, contains("import 'zz_cr_nit_shell_theme_gate.dart'"),
          reason: '★★ 真门禁必须复用共享实现（铁律 170：同一纪律只能有一个实现）');
    });

    test('★★ theme_regression_test.dart 不允许再用裸 contains 断言', () {
      final gate = stripComments(File(kGatePath).readAsStringSync());
      expect(gate, isNot(contains("contains('buildMaterialTheme('")),
          reason: '★★ 裸 contains 会命中注释 ⇒ 假门禁，必须走 shellThemeBindingHasMatch()');
      expect(gate, contains('shellThemeBindingHasMatch'),
          reason: '★★ 门禁必须真的绑定到 MaterialApp.theme，而不是某个函数名');
    });
  });

  group('③ 腿 B 负对照：注释里的调用文本不能影响门禁', () {
    test('★ 在注释里塞调用文本，门禁仍为 true', () {
      const marker = '    final materialTheme = AppTheme.themeFor(brightness);';
      expect(real.contains(marker), isTrue, reason: '锚点行不在，先修测试');

      final mutated = real.replaceFirst(
        marker,
        '    // 老实现写的是 buildMaterialTheme( foruiTheme, bridge )' +
            '\n' + marker,
      );
      final f = File(_tmpDir!.path + '/shell_with_comment_decoy.dart');
      f.writeAsStringSync(mutated);

      expect(f.readAsStringSync().contains('buildMaterialTheme('), isTrue,
          reason: '★ 前提：注释里确实多了一次调用文本');
      expect(shellThemeBindingHasMatch(f.readAsStringSync()), isTrue,
          reason: '★★ 注释里的调用文本**不能让门禁变红**；'
              '它**不能**成为门禁通过的原因（由①的反向样本证明）');
    });
  });

  group('④ 腿 B 负对照：真代码里去掉绑定，门禁必须变红', () {
    test('★ 去掉真代码里的 theme 绑定 → 门禁 false', () {
      final mutated =
          real.replaceFirst('      theme: materialTheme,', '      theme: null,');
      final f = File(_tmpDir!.path + '/shell_theme_binding_removed.dart');
      f.writeAsStringSync(mutated);

      expect(mutated.contains('      theme: materialTheme,'), isFalse,
          reason: '前提：绑定确实被去掉了');
      expect(shellThemeBindingHasMatch(f.readAsStringSync()), isFalse,
          reason: '★★ 门禁真的会红：入口不再把主题挂到 MaterialApp.theme 上');
    });

    test('★ 去掉主题来源 AppTheme.themeFor(brightness) → 门禁 false', () {
      final mutated = real.replaceFirst(
        '    final materialTheme = AppTheme.themeFor(brightness);',
        '    final materialTheme = AppTheme.resolve();',
      );
      final f = File(_tmpDir!.path + '/shell_theme_source_removed.dart');
      f.writeAsStringSync(mutated);

      expect(mutated.contains('    final materialTheme = AppTheme.themeFor(brightness);'),
          isFalse);
      expect(shellThemeBindingHasMatch(f.readAsStringSync()), isFalse,
          reason: '★★ 主题来源不是 AppTheme.themeFor(brightness) 时，门禁必须失败');
    });

    test('★ MaterialApp 改用另一个主题来源 → 门禁 false', () {
      final mutated = real.replaceFirst(
        '      theme: materialTheme,',
        '      theme: foruiTheme,',
      );
      final f = File(_tmpDir!.path + '/shell_other_theme.dart');
      f.writeAsStringSync(mutated);

      expect(shellThemeBindingHasMatch(f.readAsStringSync()), isFalse,
          reason: '★★ MaterialApp 必须用 materialTheme；裸 forui 主题会让卡片底等于背景色');
    });
  });

  group('⑤ 裸桥接调用的检查同样不吃注释', () {
    test('注释里提到不算，代码里出现才算', () {
      expect(bareApproximateMaterialThemeLines(_kGood), isEmpty);

      const withComment =
          '// 这里曾用 toApproximateMaterialTheme()\nfinal t = 1;';
      expect(bareApproximateMaterialThemeLines(withComment), isEmpty,
          reason: '★ 注释里的裸调用**不能**被判违规（否则门禁会被注释触发）');

      const withCode =
          '// 注释\nfinal t = theme.toApproximateMaterialTheme();';
      expect(bareApproximateMaterialThemeLines(withCode).length, 1,
          reason: '★ 真代码里的裸调用必须被抓出来');
    });

    test('★ 真实 shell.dart 剥注释后没有裸调用', () {
      final bare = bareApproximateMaterialThemeLines(real);
      expect(bare, isEmpty, reason: '真实代码里不该再有裸调用：\n  ' + bare.join('\n  '));
    });
  });
}
