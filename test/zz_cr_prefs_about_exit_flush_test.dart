// ═══════════════════════════════════════════════════════════════════════
//  OPS-17 超范围遗留：**非优雅退出**路径（安装向导拉起 ⇒ exit(0)）也要落盘偏好
// ═══════════════════════════════════════════════════════════════════════
//
// # 缺陷（业主 E 条「要持久记忆」的同族缺陷）
//
// `lib/ui/settings/about_page.dart` 的「立即更新」在 Windows 上把安装包交给
// 系统后会 `exit(0)`（安装向导接管）。用户完全可能：
//   ① 刚在设置页拨完一个开关（`UiPrefs.set` 只改内存）
//   ② 300ms 去抖（`lib/core/ui_prefs.dart:107-113`）还没到
//   ③ 就点了「立即更新」，并且安装器成功拉起
// ⇒ `exit(0)` 立刻终止进程 ⇒ 那一次偏好**永久丢失**（下次打开还是旧值）。
//
// OPS-17 只补了**优雅退出**（`lib/core/app_tray.dart:442` / `:471` 各 await
// 一次落盘），本文件守的是剩下这一条 `exit(0)`。
//
// # 判据口径（★ 唯一合法的证据）
// 断言「**盘上** ui-prefs.json 里 key 的值就是 v」—— 直接从文件读回来，
// 绕开 `UiPrefs` 的内存。
// ✗ 「调了 flush 不抛异常」不算证据；
// ✗ 「内存里 UiPrefs.get(k) == v」也不算（set() 本来就先改内存）。
//
// # ⚠️ 为什么门禁必须分两条腿
// `exit(0)` 会**真的杀掉进程**（它的语义不许改，必须仍然真的退出）⇒
// 测试里跑到它就是测试进程自己死。所以「exit 之前盘上已有值」这条不变量
// 由两条腿合起来证明：
//   ① **接线腿**（纯源码）：剥注释后，真实 `exit(0)` 必须**紧跟在**
//      那次真的 `await …flushPrefsBeforeNonGracefulExit();` 之后
//      ⇒ 证明下面那条腿跑的那一步确实是 exit(0) 前最后发生的事。
//   ② **行为腿**：真实调用生产代码里 exit(0) 之前的那一步，
//      断言值**从盘上读得回来** ⇒ 证明那一步真的把值写下去了。
// ①单独不够（只是文本），②单独也不够（不保证被调用）—— 两条腿都各有一个
// 「必须变红」的负对照用例（变异体只存在于内存字符串里，不碰仓库文件）。
//
// # ⚠️ 测试自身的坑（OPS-17 踩过，别重踩）
// 1. flush() / load() 是**真文件 I/O**：testWidgets 的 body 跑在 FakeAsync 下，
//    真 I/O 的 Future 永远不会在假时钟下完成 ⇒ 落盘与读盘必须放进
//    `tester.runAsync`（放回真实事件循环）。
// 2. `UiPrefs.set()` 会起一个 300ms 的 `_flushSoon` 定时器；用例结束时它还
//    挂着 ⇒ flutter_test 直接判「A Timer is still pending…」。
//    每个用例末尾都要把假时钟推过 300ms 排干它。
// ★ 而**正是**坑 1 让本文件成为真门禁：假时钟不推过 300ms，于是
//   「用户 300ms 内点立即更新」这个时序被精确复现。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/settings/about_page.dart';

import '_support/strip_comments.dart';

/// 模拟「用户刚在设置页拨完的那一下开关」（与退出无关的普通偏好）
const String kProbeKey = 'dsh.zzCrAboutExitProbe';
const String kProbeValue = 'on';

/// 被守的真实源码
const String kAboutPath = 'lib/ui/settings/about_page.dart';

/// ★ 接线腿的**唯一实现**：剥注释后，**每一处** `exit(0);` 都必须紧跟在
/// 那次真的 `await AboutSettingsPageState.flushPrefsBeforeNonGracefulExit();`
/// 之后（中间只允许空白）。
///
/// ⚠️ 必须先剥注释（用仓里那一个既有实现 `test/_support/strip_comments.dart`，
///    不抄第二份）：裸 contains 会命中**注释**里的调用文本 —— 这正是 CR-28
///    的教训（`lib/shell.dart` 里 `buildMaterialTheme(` 出现 2 次、两次全在
///    注释里，而旧门禁照样绿）。下面的负对照用例专门钉这一点。
bool aboutExitFlushIsWired(String rawSource) {
  final code = stripComments(rawSource);
  final exits = RegExp(r'exit\(0\)\s*;').allMatches(code).toList();
  if (exits.isEmpty) return false; // 连 exit 都找不到 ⇒ 结构变了，门禁该红
  final flushedRightBefore = RegExp(
    r'await\s+AboutSettingsPageState\.flushPrefsBeforeNonGracefulExit\(\)\s*;\s*$',
  );
  return exits.every(
    (m) => flushedRightBefore.hasMatch(code.substring(0, m.start)),
  );
}

/// 「形状正确」的最小样本（证明正则不是恒假）
const String _kGoodShape = r'''
Future<void> f(File file) async {
  final msg = await InstallLaunch.open(file);
  if (msg != null) {
    toast(msg);
  } else if (Platform.isWindows) {
    await AboutSettingsPageState.flushPrefsBeforeNonGracefulExit();
    exit(0);
  }
}
''';

/// **只有注释**里提到那次落盘，代码里一次都没有（= CR-28 那种假门禁样本）
const String _kCommentOnlyDecoy = r'''
// 老实现写的是 await AboutSettingsPageState.flushPrefsBeforeNonGracefulExit();
Future<void> f() async {
  exit(0);
}
''';

/// 调了但**没有 await**（unawaited / 发出去就走）—— 必须同样判红
const String _kUnawaitedDecoy = r'''
Future<void> f() async {
  unawaited(AboutSettingsPageState.flushPrefsBeforeNonGracefulExit());
  exit(0);
}
''';

/// 偏好文件所在的临时「数据目录」
late Directory _dataDir;

/// 偏好文件的绝对路径（UiPrefs.load 拼的就是这个名字）
String _prefsPath() => '${_dataDir.path}${Platform.pathSeparator}ui-prefs.json';

/// 从**盘上**读回偏好（★ 唯一合法的证据来源；同步读，FakeAsync 下也能用）
Map<String, String> _readDisk() {
  final f = File(_prefsPath());
  if (!f.existsSync()) return <String, String>{};
  final raw = f.readAsStringSync();
  if (raw.trim().isEmpty) return <String, String>{};
  final m = jsonDecode(raw);
  return m is Map
      ? m.map((k, v) => MapEntry(k.toString(), v.toString()))
      : <String, String>{};
}

/// 排干 UiPrefs 的 300ms 去抖定时器。
///
/// 顺序**不能反**：
///   ① 先在 runAsync 里把待写的偏好真正落盘（FakeAsync 下真 I/O 的 Future
///      永不完成，会把文件截成 0 字节）；
///   ② 再推 400ms 假时钟，让 _flushSoon 那个 300ms 定时器**真的到期**
///      （此时 _dirty 已是 false，flush 直接返回，不会再起 I/O）。
///
/// ⚠️ 断言必须在本函数**之前**完成：本函数会把内存里剩下的东西写下去。
Future<void> _drain(WidgetTester t) async {
  await t.runAsync(() => UiPrefs.flush());
  await t.pump(const Duration(milliseconds: 400));
}

void main() {
  late String real;

  setUpAll(() => real = File(kAboutPath).readAsStringSync());

  setUp(() async {
    _dataDir = Directory.systemTemp.createTempSync('sourin_about_exit_flush');
    addTearDown(() {
      // Windows 上偶尔还会被上一轮未收尾的写句柄占住 —— 临时目录清不掉
      // 与被测行为无关，不该判测试失败。
      try {
        if (_dataDir.existsSync()) {
          _dataDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    });

    // 从干净初值开始（UiPrefs._data 是 static，跨用例共享）
    UiPrefs.debugResetForTest();
    // ★ 必须先 load：set() 只改内存，flush() 要有 _file 才能落盘
    await UiPrefs.load(_dataDir.path);
  });

  // ─────────────────────────────────────────────────────────────────────
  group('① 接线腿：真实 exit(0) 之前必须真的 await 落盘', () {
    test('★★ about_page.dart：每一处 exit(0) 都紧跟在 await 落盘之后', () {
      expect(
        aboutExitFlushIsWired(real),
        isTrue,
        reason: '★★★ lib/ui/settings/about_page.dart 里 exit(0); 之前必须'
            '紧挨着 await AboutSettingsPageState.flushPrefsBeforeNonGracefulExit();。'
            '没有它 ⇒ 用户刚拨的开关（UiPrefs.set 只改内存，落盘是 300ms 去抖）'
            '会随 exit(0) 一起消失，下次打开还是旧值。',
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  group('② 负对照：接线腿会红（不是假门禁）', () {
    test('★ 形状正确的样本 ⇒ 门禁为真（证明正则不是恒假）', () {
      expect(aboutExitFlushIsWired(_kGoodShape), isTrue);
    });

    test('★ 只有注释里提到那次落盘 ⇒ 门禁必须为假（CR-28 的坑）', () {
      expect(_kCommentOnlyDecoy.contains('flushPrefsBeforeNonGracefulExit'),
          isTrue, reason: '前提：诱饵里确实有那段文本（只是它在注释里）');
      expect(
        aboutExitFlushIsWired(_kCommentOnlyDecoy),
        isFalse,
        reason: '★★ 注释里的调用文本**不能**让门禁变绿 —— 门禁守的是代码',
      );
    });

    test('★ 调了但没 await（发出去就走）⇒ 门禁必须为假', () {
      expect(aboutExitFlushIsWired(_kUnawaitedDecoy), isFalse,
          reason: '★★ 非优雅退出必须**真的 await**：unawaited 之后进程立刻没了，'
              '写盘大概率还没发生');
    });

    test('★ 把真实源码里那次 await 注释掉 ⇒ 门禁必须变红', () {
      const anchor =
          'await AboutSettingsPageState.flushPrefsBeforeNonGracefulExit();';
      expect(real.contains(anchor), isTrue,
          reason: '锚点不在真实源码里，先修测试（门禁的另一条腿也依赖它）');

      final mutated = real.replaceFirst(anchor, '// $anchor');
      expect(mutated, isNot(real), reason: '前提：变异确实发生了');
      expect(
        aboutExitFlushIsWired(mutated),
        isFalse,
        reason: '★★★ 这就是缺陷本身：exit(0) 之前不落盘 ⇒ 门禁必须变红',
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  group('③ 行为腿：真的跑 exit(0) 之前那一步 ⇒ 值必须从盘上读得回来', () {
    testWidgets('★★ 落盘步骤执行后，ui-prefs.json 里就有刚拨的那一次 set', (t) async {
      // 用户刚拨的开关：只改了内存，落盘还挂在 300ms 去抖里
      UiPrefs.set(kProbeKey, kProbeValue);
      expect(UiPrefs.get(kProbeKey), kProbeValue,
          reason: '前置：内存里已改（set 先改内存，这一步**不是**证据）');
      expect(_readDisk()[kProbeKey], isNull,
          reason: '前置：此刻盘上还没有 —— 正是会被 exit(0) 吃掉的那一次');

      // ★ 真文件 I/O 必须在 runAsync 里：FakeAsync 假时钟下 flush 的
      //   Future 永远不会完成（OPS-17 踩过的坑）。
      await t.runAsync(
        () => AboutSettingsPageState.flushPrefsBeforeNonGracefulExit(),
      );

      // ★ 唯一合法的证据：从**盘上**读回来的值。
      //   ✗ 不是 UiPrefs.get()（set 本来就先改内存）
      //   ✗ 不是「flush 没抛异常」
      final onDisk = _readDisk();
      expect(
        onDisk[kProbeKey],
        kProbeValue,
        reason: '★★★ exit(0) 之前那一步必须把偏好**真的写进** ui-prefs.json；'
            '否则「刚拨完开关 → 300ms 内点立即更新 → 安装器成功拉起」'
            '这一次偏好永久丢失（下次打开还是旧值）。'
            '盘上文件内容=$onDisk',
      );

      await _drain(t);
    });

    /// 修复前的样子：`exit(0)` 之前**什么都不做**（= 把那次落盘换成 no-op）。
    ///
    /// 这就是「反假绿自检」的自动化版本：③ 那条断言必须靠**真的调用**
    /// 生产代码里的落盘步骤才成立；换成 no-op 就必须变红。
    testWidgets('★ 负对照：落盘换成 no-op（修复前的行为）⇒ 盘上必须没有', (t) async {
      UiPrefs.set(kProbeKey, kProbeValue);
      expect(_readDisk()[kProbeKey], isNull, reason: '前置：盘上还没有');

      // no-op —— 等价于把 about_page.dart 里那行 await 删掉/注释掉
      await t.runAsync(() async {});

      expect(
        _readDisk()[kProbeKey],
        isNull,
        reason: '★★ 不落盘就真的没有 ⇒ ③ 那条断言会红（证明它不是假门禁）。'
            '真实进程里 exit(0) 之后就没有「下一次」了。',
      );

      await _drain(t);
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  group('④ 前提（非门禁）：去抖没跑完就退 ⇒ 盘上真的什么都没有', () {
    testWidgets('★ 300ms 去抖未到 ⇒ 盘上没有这个值（丢的就是这一次）', (t) async {
      UiPrefs.set(kProbeKey, kProbeValue);
      expect(UiPrefs.get(kProbeKey), kProbeValue,
          reason: '前置：内存里已改（set 先改内存，这一步**不是**证据）');
      expect(
        _readDisk()[kProbeKey],
        isNull,
        reason: '★ 假时钟不推过 300ms ⇒ 去抖定时器不会触发 ⇒ '
            '修复前 exit(0) 之前什么都不做，退出后盘上永远没有它',
      );

      await _drain(t);
    });
  });
}
