// ═══════════════════════════════════════════════════════════════════════
//  F2「本地播放页 单集删除 / 批量删除」的 **UI 面** 硬门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要有这个文件
//
// 删除的**逻辑**已有硬门禁：test/zz_media_delete_guard_test.dart（D-0…D-4，
// 含路径穿越拒绝与真实字节数）。
// 但 UI 面此前**只有截图探针**：test/zz_media_shots_test.dart 的
// 「SHOT-5 本地播放页：批量删除选择态」正文只有一句
// debugPrint('SHOT-5 = ' + f.path) —— 出图不断言。
//
// ⇒ 后果：「管理」按钮被误删、勾选框不渲染、计数不更新，**门禁都不会红**。
//   本文件把这条链路钉成断言。
//
// # 产品形态（lib/ui/detail_page.dart，本文件只读它，不改）
//
//   普通态  标题行右侧 = TextButton('管理')                       (:3329-3342)
//           每行右侧   = _LocalRowDeleteButton（垃圾桶图标）       (:3383-3387)
//                        onDelete: _localSelectMode ? null : () => _confirmDeleteLocalEpisode(e)
//   选择态  标题行     = '已选 N 集' + [全选/全不选] [删除] [取消]  (:3400-3447)
//           每行左侧   = Icon(Icons.check_box_rounded /
//                            Icons.check_box_outline_blank_rounded) (:4515-4650)
//           每行 onDelete = null（垃圾桶整块**不构建**）
//
// ★ 勾选框是 **Icon(Icons.check_box_*)**，不是 Checkbox widget —— 判据照抄实现。
//
// # 反假绿（每条断言都真的做过一次故意破坏）
//
// 破坏方式与红色读数记在 .probe/ops/F2UI-report.md 的「反假绿」一节；
// 结论：五条断言在破坏后**都**变红，恢复后**都**变绿。
//
// # 夹具为什么是「纯 DetailPage」而不是整页 MediaPage
//
// ① 被测对象是详情区里的本地选集区块，MediaPage 只是它的宿主；
// ② 整页 MediaPage 会拉起 PlayerPage ⇒ 需要 libmpv 夹具，缺夹具就得 skip，
//    而本门禁**不允许** skip（skip 掉的守卫等于没有守卫）；
// ③ 本地模式的 DetailPage 由 localMeta/localEpisodes 直接铺数据，
//    不依赖核心库（sourin_core.dll 缺失只会让「续播进度」读不到，
//    见下面的 [DETAIL] 日志 —— 不影响选集区块）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/download_queue.dart';
import 'package:sourin_spike/core/network_status.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/cache_page.dart';
import 'package:sourin_spike/ui/detail_page.dart';
import 'package:sourin_spike/ui/theme_bridge.dart';

// ══════════════════════════════════════════════════════════════════════════
//  夹具
// ══════════════════════════════════════════════════════════════════════════

/// 系统临时目录下的沙盒（**绝不碰** %APPDATA%\app.sourin.player 与业主真实下载目录）
Directory _sandbox(String name) {
  final p = Directory.systemTemp.absolute.path + Platform.pathSeparator + name;
  final d = Directory(p);
  if (!d.isAbsolute) fail('★ 沙盒必须是绝对路径，实际 = ' + p);
  d.createSync(recursive: true);
  return d;
}

late Directory _root;
late Directory _workDir;
late CachedWork _work;
late List<LocalEpisodeRef> _eps;

/// 三集，1..3 —— 名字带「集」是为了让 find.text('第02集') 能定位到行
const int _epCount = 3;

String _epName(int i) => '第0' + i.toString() + '集';

/// 读出当前树里所有 _LocalEpisodeRow（按树序）
///
/// ★ 行是私有 widget，本文件在 **test** 侧用 runtimeType 名字匹配；
///   它的 onDelete / checked / onTap 是**公开 final 字段**，
///   所以这里读到的就是实现真正传给它的值 —— 不是猜的。
List<Widget> _rows(WidgetTester t) => t.allWidgets
    .where((w) => w.runtimeType.toString() == '_LocalEpisodeRow')
    .toList();

bool? _checkedOf(Widget row) => (row as dynamic).checked as bool?;
bool _hasOnDelete(Widget row) => (row as dynamic).onDelete != null;
bool _hasOnTap(Widget row) => (row as dynamic).onTap != null;

/// 把积压的框架异常收走（诊断用：只打印，不做断言）
///
/// ⚠️ 本地模式的 DetailPage 会去调 SourinApi.getProgress（FFI）——
///   仓库根没有 sourin_core.dll（CI 也没有）⇒ 抛「Failed to load dynamic
///   library 'sourin_core.dll'」。那条异常与本地选集 UI 无关，
///   让它在 _pump 之后堆积会把后续断言染红成别的东西。
List<String> _drain(WidgetTester t) {
  final out = <String>[];
  Object? e;
  while ((e = t.takeException()) != null) {
    out.add('' + e.toString());
  }
  return out;
}

Future<void> _pumpLocal(WidgetTester t,
    {Size size = const Size(1440, 900)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);

  await t.pumpWidget(MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: DetailPage(
      provider: kLocalProvider,
      id: _work.episodes.first.fileName,
      localFile: _workDir.path + Platform.pathSeparator + _epName(1) + '.mp4',
      localMeta: _work,
      localEpisodes: _eps,
      localEpisodeCount: _eps.length,
      // ★ 不传 onPlayLocalEpisode：普通态每行的 onTap 就是 null
      //   ⇒ 普通态点行**不会**有任何副作用（探针实测 onTap=false），
      //   这样「点行」在两种态下的语义差异才是干净的。
    ),
  ));
  await t.pump(const Duration(milliseconds: 50));
  _drain(t);
}

void main() {
  setUpAll(() {
    // DetailPage 本地模式不会构造 Player，但保留这行与仓库其它探针一致：
    // dll 在就初始化，不在也不影响本文件（**不**据此 skip）。
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    UiPrefs.debugResetForTest();
  });

  setUp(() {
    final sep = Platform.pathSeparator;
    _root = _sandbox('sourin_f2_local_select_ui');
    for (final e in _root.listSync()) {
      e.deleteSync(recursive: true);
    }
    _workDir = Directory(_root.path + sep + '无职转生 第三季')
      ..createSync(recursive: true);
    for (var i = 1; i <= _epCount; i++) {
      File(_workDir.path + sep + _epName(i) + '.mp4')
          .writeAsBytesSync(List<int>.filled(1024, 0x42));
    }
    // ★ 造 CachedWork 用同步 listSync（绝不在 fake-async 区里 await 真 IO：
    //   那个 future 永不完成 ⇒ 用例 did not complete）
    _work = CachedWork(
      dirName: '无职转生 第三季',
      path: _workDir.path,
      title: '无职转生 第三季',
      episodes: <CachedEpisode>[
        for (final f in _workDir.listSync().whereType<File>())
          CachedEpisode(
            fileName: f.uri.pathSegments.last,
            bytes: f.lengthSync(),
            isComplete: true,
          ),
      ],
      description: 'F2 UI 门禁夹具',
    );
    _eps = <LocalEpisodeRef>[
      for (var i = 1; i <= _epCount; i++)
        LocalEpisodeRef(
          fileName: _epName(i) + '.mp4',
          episodeTitle: _epName(i),
          absolutePath: _workDir.path + sep + _epName(i) + '.mp4',
          bytes: 1024,
        ),
    ];

    // 网络状态探针：不给它，页面会真去发请求（fake-async 里永不完成）
    NetworkStatus.debugResetForTest();
    NetworkStatus.debugProbe = () async => true;
    DownloadQueue.debugReset();
  });

  tearDown(() {
    NetworkStatus.debugProbe = null;
    debugSetLocalOriginRecords(null);
  });

  tearDownAll(() {
    final d = Directory(Directory.systemTemp.absolute.path +
        Platform.pathSeparator +
        'sourin_f2_local_select_ui');
    if (d.isAbsolute && d.existsSync()) d.deleteSync(recursive: true);
  });

  // ══════════════════════════════════════════════════════════════════════
  group('★ F2 本地选集：删除入口的 UI 面硬门禁', () {
    testWidgets('★ ① 普通态：本地剧集详情页必须有「管理」入口（可点的 TextButton）',
        (t) async {
      await _pumpLocal(t);

      // ── 夹具前置 ──
      expect(_rows(t).length, _epCount,
          reason: '夹具前置：localEpisodes 有 ' +
              _epCount.toString() +
              ' 集 ⇒ 必须渲染同样多的行');
      expect(find.text('已下载'), findsOneWidget,
          reason: '夹具前置：本地选集区块的标题应当是「已下载」');

      // ── ① 被测断言：管理入口存在，且是**可点的**按钮 ──
      // 只断言「有这段文字」不够：文案还在但 TextButton 被换成 Text
      // （= 点不动了）同样应当红 ⇒ 必须钉住它是 TextButton 的后代。
      expect(
        find.text('管理'),
        findsOneWidget,
        reason: '★ ① 普通态必须出现「管理」入口（lib/ui/detail_page.dart:3329-3342）。'
            '它没了 ⇒ 业主**根本进不去**批量删除 ⇒ 整条删除链路在 UI 面上断开。',
      );
      expect(
        find.ancestor(of: find.text('管理'), matching: find.byType(TextButton)),
        findsOneWidget,
        reason: '★ ①「管理」必须是 TextButton 里的（能点）。'
            '若只剩一段静态文字 ⇒ 入口是死的。',
      );

      // ── 普通态的对照读数（不是被测断言，是让「选择态」的差异可解释）──
      expect(find.byIcon(Icons.delete_outline_rounded).evaluate().length,
          _epCount,
          reason: '普通态每行右侧一枚垃圾桶（_LocalRowDeleteButton）');
      expect(
        find.byIcon(Icons.check_box_outline_blank_rounded),
        findsNothing,
        reason: '普通态**不得**出现勾选框 —— 勾选框是选择态独有的',
      );
      for (final row in _rows(t)) {
        expect(_checkedOf(row), isNull,
            reason: '普通态 checked 必须是 null（= 实现用它表示「不画勾选框」）');
        expect(_hasOnDelete(row), isTrue,
            reason: '普通态每行必须有单集删除回调（垃圾桶点得动）');
      }
    });

    testWidgets('★ ② 点「管理」⇒ 选择态：出现「已选 0 集」且每行出现勾选框',
        (t) async {
      await _pumpLocal(t);
      await t.tap(find.text('管理'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      _drain(t);

      // ── ② 被测断言 ──
      expect(
        find.text('已选 0 集'),
        findsOneWidget,
        reason: '★ ② 进入选择态后标题行必须变成「已选 0 集」'
            '（lib/ui/detail_page.dart:3400-3447 的 _localSelectBar）。'
            '计数文案是业主看删除范围的**唯一**读数 ⇒ 它不更新等于看不见删谁。',
      );
      expect(
        find.text('管理'),
        findsNothing,
        reason: '★ ② 选择态下「管理」入口必须让位给选择栏（标题行被替换）',
      );
      expect(
        find.byIcon(Icons.check_box_outline_blank_rounded).evaluate().length,
        _epCount,
        reason: '★ ② 选择态下**每一行**左侧都要出现未勾选的勾选框'
            '（_LocalEpisodeRow 里 checked != null ⇒ 画 Icon(check_box_*)）。'
            '一行不画 ⇒ 那一集选不上 ⇒ 批量删除漏集。',
      );
      for (final row in _rows(t)) {
        expect(_checkedOf(row), isFalse,
            reason: '★ ② 刚进选择态时每行都应当是「未勾选」（不是 null，也不是 true）');
        expect(_hasOnTap(row), isTrue,
            reason: '★ ② 选择态下每行必须可点（点行 = 勾选/取消勾选）');
      }
    });

    testWidgets('★ ③ 勾选一集 ⇒ 计数变「已选 1 集」', (t) async {
      await _pumpLocal(t);
      await t.tap(find.text('管理'));
      await t.pump();
      await t.tap(find.text(_epName(2)).first);
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      _drain(t);

      // ── ③ 被测断言 ──
      expect(
        find.text('已选 1 集'),
        findsOneWidget,
        reason: '★ ③ 勾选一集后计数必须变成「已选 1 集」。'
            '计数不跟着变 ⇒ 业主无法确认删的是哪几集（而删除是**不可恢复**的）。',
      );
      expect(
        find.byIcon(Icons.check_box_rounded).evaluate().length,
        1,
        reason: '★ ③ 被勾中的那一行必须换成实心勾选框（Icon(check_box_rounded)）',
      );
      expect(
        find.byIcon(Icons.check_box_outline_blank_rounded).evaluate().length,
        _epCount - 1,
        reason: '★ ③ 其余行必须保持未勾选 —— 勾一集不能连带勾上别的',
      );
      final rows = _rows(t);
      expect(_checkedOf(rows[1]), isTrue,
          reason: '★ ③ 被点的应当是第 2 行（' + _epName(2) + '）');
      expect(_checkedOf(rows[0]), isFalse, reason: '★ ③ 第 1 行不得被连带勾选');
      expect(_checkedOf(rows[2]), isFalse, reason: '★ ③ 第 3 行不得被连带勾选');
    });

    testWidgets('★ ④ 选择态：行尾垃圾桶不再触发单集删除弹窗', (t) async {
      await _pumpLocal(t);
      await t.tap(find.text('管理'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      _drain(t);

      // ── ④ 被测断言（三层，都是实测到的真实机制）──
      // 第 1 层：垃圾桶**整块不构建**
      expect(
        find.byIcon(Icons.delete_outline_rounded),
        findsNothing,
        reason: '★ ④ 选择态下行尾垃圾桶必须消失（探针实测：普通态 3 枚、选择态 0 枚）。'
            '它还在 ⇒ 业主在批量删除时**还能**误点到单集删除，'
            '两个删除入口同时活着 = 误删风险。',
      );
      // 第 2 层：回调本身被置空（这才是根因所在的那一行：
      //   detail_page.dart:3383-3387  onDelete: _localSelectMode ? null : …）
      for (final row in _rows(t)) {
        expect(_hasOnDelete(row), isFalse,
            reason: '★ ④ 选择态下每行的 onDelete 必须是 null'
                '（detail_page.dart 里 onDelete: _localSelectMode ? null : …）。'
                '它非 null ⇒ 单集删除弹窗随时能被点出来。');
      }
      // 第 3 层：行为面 —— 点行只勾选，**不**弹「删除这一集？」
      await t.tap(find.text(_epName(2)).first);
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      _drain(t);
      expect(
        find.text('删除这一集？'),
        findsNothing,
        reason: '★ ④ 选择态下点行**不得**弹出单集删除确认框（它只应当勾选）',
      );
      expect(
        find.text('已选 1 集'),
        findsOneWidget,
        reason: '★ ④ 反向自证：点行的效果是「勾选」⇒ 计数必须变成已选 1 集'
            '（若这里也失败，说明点行根本没生效，上面的「没弹窗」是假绿）',
      );
    });

    testWidgets('★ ④ 阳性对照：普通态点垃圾桶**会**弹「删除这一集？」（证明机制存在）',
        (t) async {
      await _pumpLocal(t);
      expect(find.byIcon(Icons.delete_outline_rounded).evaluate().length,
          _epCount,
          reason: '阳性对照前置：普通态每行一枚垃圾桶');

      await t.tap(find.byIcon(Icons.delete_outline_rounded).first,
          warnIfMissed: false);
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      _drain(t);

      expect(
        find.text('删除这一集？'),
        findsOneWidget,
        reason: '★★ 阳性对照：普通态点垃圾桶**必须**弹出单集删除确认框。'
            '这条成立，上面 ④ 的「选择态不弹窗」才有意义 ——'
            '否则可能只是「这个弹窗在测试环境里永远弹不出来」的假绿。',
      );
      expect(
        find.textContaining('文件会从磁盘上真正删除'),
        findsOneWidget,
        reason: '★ 阳性对照：确认框必须写明不可恢复（业主删的是真文件）',
      );
      // 收尾：取消掉，别把弹窗留给下一条用例
      // ⚠️ showAppDialog 走的是带过渡动画的 showDialog ⇒ 点「取消」后必须
      //   把**关闭动画**跑完（实测 pump 两帧不够，弹窗还在树里）。
      await t.tap(find.text('取消'));
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      _drain(t);
      expect(find.text('删除这一集？'), findsNothing,
          reason: '收尾：点「取消」后确认框必须关闭');
    });
  });
}
