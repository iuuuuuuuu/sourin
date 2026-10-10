// ═══════════════════════════════════════════════════════════════════════
//  OPS-9 探针 1：本地页的「来源」chip 到底停在哪一步
// ═══════════════════════════════════════════════════════════════════════
//
// ⚠️⚠️ 本文件的结论**已被探针 3 推翻**（2026-10-10，同一天）。
// 它量出来的「卡在 await 里」是**假时钟**的产物，不是产品形态：
// ```text
// 探针 1/2（只泵假时钟）：cycani=0 ⇒ 看起来"永不完成"
// 探针 3（tester.runAsync 真事件循环）：
//     callAsync(list_providers) = err:SourinCoreException(unsupported):
//         核心尚未启动 —— 请先调用 sourin_start({dataDir})
//     providerDisplayName(cycani) = cycani
// ⇒ 真事件循环下 FFI **立刻回一个异常**，名字退化成裸 id，
//   那条 await 链根本没卡。
// ```
// ★ 教训：NativeCallable.listener 的回包走**真**消息端口，FakeAsync 下
//   不转 ⇒ 「假时钟里的永不完成」是测量方式的产物。
//   留下的价值：它把"不是渲染层的问题"这一点钉死了（见下面的三种可能）。
//   结论请以 test/zz_cr_origin_probe3_test.dart / probe4 为准。
//
// 只回答一个问题（不改任何生产代码）：
// 注入的记录**已经**喂给了 `debugLocalOriginRecords`，为什么
// `find.text('cycani')` 仍然是 0？
//
// 三种可能，探针一次分清：
// ```text
// ① state._localOrigin == null   ⇒ _loadLocalOrigin 那条 await 链**没跑完**
//                                  （或中途抛了异常，被 unawaited 吞掉）
// ② state._localOrigin == '本地' ⇒ 匹配**没命中**（标题归一化对不上）
// ③ state._localOrigin == 'cycani' ⇒ 值对了，是**渲染**这一层没画出来
// ```
//
// 跑法：
// ```text
// flutter test test/zz_cr_origin_probe_test.dart --reporter expanded --concurrency=1
// ```

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/network_status.dart';
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/cache_page.dart' show CachedEpisode, CachedWork;
import 'package:sourin_spike/ui/detail_page.dart';

final String _bs = String.fromCharCode(92);
final String _dir = 'C:${_bs}Users${_bs}Videos${_bs}sourin';
const String _ep01 = '第01集.mp4';
final String _ep01Path = '$_dir$_bs$_ep01';
const String _title = '测试影片';

void _claim(WidgetTester t) {
  while (t.takeException() != null) {}
}

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return mui.MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: mui.Scaffold(body: mui.Material(child: child)),
  );
}

int _n(String s) => find.text(s).evaluate().length;

void main() {
  setUp(() {
    NetworkStatus.debugResetForTest();
  });
  tearDown(() {
    NetworkStatus.debugResetForTest();
    debugSetLocalOriginRecords(null);
  });

  testWidgets('探针：来源 chip 的三岔口', (t) async {
    NetworkStatus.debugProbe = () async => true;
    await t.binding.setSurfaceSize(const Size(433.0, 900.0));
    addTearDown(() => t.binding.setSurfaceSize(null));

    debugSetLocalOriginRecords(() => (
          progress: <Progress>[
            const Progress(
              key: 'cycani:m1',
              provider: 'cycani',
              nativeId: 'm1',
              title: _title,
              updatedAt: 10,
            ),
          ],
          favorites: const <Favorite>[],
        ));

    final key = GlobalKey<State<DetailPage>>();
    await t.pumpWidget(_host(
      DetailPage(
        key: key,
        provider: 'local',
        id: _ep01Path,
        embedded: true,
        localFile: _ep01Path,
        localTitle: _title,
        localEpisodeCount: 1,
        localEpisodes: <LocalEpisodeRef>[
          LocalEpisodeRef(
            fileName: _ep01,
            episodeTitle: '第01集',
            absolutePath: _ep01Path,
            bytes: 2 * 1024 * 1024,
          ),
        ],
        currentEpisodeId: _ep01,
        localMeta: CachedWork(
          dirName: _title,
          path: _dir,
          episodes: const <CachedEpisode>[],
        ),
      ),
    ));
    _claim(t);

    for (var i = 0; i < 12; i++) {
      await t.pump(const Duration(milliseconds: 50));
      _claim(t);
    }

    // ignore: avoid_dynamic_calls
    final st = key.currentState! as dynamic;
    Object? origin;
    Object? item;
    Object? online;
    try {
      origin = st._localOrigin;
      item = st._localOriginItem;
      online = st._online;
    } catch (e) {
      origin = '<读不到: $e>';
    }
    debugPrint('[PROBE] _localOrigin=$origin _localOriginItem=$item _online=$online');
    debugPrint('[PROBE] 文本计数: cycani=${_n('cycani')} 本地=${_n('本地')} '
        '测试影片=${_n('测试影片')} 换源=${_n('换源')}');
    final chips = find.byType(Text).evaluate().length;
    debugPrint('[PROBE] 全树 Text 数=$chips');
    for (final e in find.byType(Text).evaluate().take(40)) {
      final w = e.widget as Text;
      debugPrint('[PROBE]   Text("${w.data}")');
    }
  });
}
