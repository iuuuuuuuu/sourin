// ═══════════════════════════════════════════════════════════════════════
//  探针 4（OPS-9 / task-17 ②）：E 组那枚「来源」chip 要几轮真事件循环才亮
// ═══════════════════════════════════════════════════════════════════════
//
// 探针 3 已经证明：**给真事件循环**，providerDisplayName('cycani') 是能回来的
// （FFI 会立刻回一个 SourinCoreException(unsupported) ⇒ 退化成裸 id cycani）。
// 那 E 组为什么还是 0 枚？这一版把"真事件循环转几轮 + 每轮后泵几帧"扫一遍。
//
//   flutter test test/zz_cr_origin_probe4_test.dart --reporter expanded --concurrency=1

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/network_status.dart';
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/cache_page.dart' show CachedEpisode, CachedWork;
import 'package:sourin_spike/ui/detail_page.dart';

const double _panelW = 433.0;
const double _panelH = 900.0;
final String _bs = String.fromCharCode(92);
final String _dir = 'C:' + _bs + 'Users' + _bs + 'Videos' + _bs + 'sourin';
const String _ep01 = '第01集.mp4';
final String _ep01Path = _dir + _bs + _ep01;
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

String _count() {
  final a = find.text('cycani').evaluate().length;
  final b = find.text('本地').evaluate().length;
  return 'cycani=' + a.toString() + ' 本地=' + b.toString();
}

void main() {
  testWidgets('探针4：来源 chip 在第几轮真事件循环后亮', (t) async {
    NetworkStatus.debugProbe = () async => true;
    addTearDown(NetworkStatus.debugResetForTest);
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
    addTearDown(() => debugSetLocalOriginRecords(null));

    await t.binding.setSurfaceSize(const Size(_panelW, _panelH));
    addTearDown(() => t.binding.setSurfaceSize(null));

    await t.pumpWidget(_host(
      DetailPage(
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
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 50));
      _claim(t);
    }
    debugPrint('[P4] 挂载后（还没转真事件循环） ' + _count());

    for (var round = 1; round <= 6; round++) {
      await t.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 50));
        _claim(t);
      }
      debugPrint('[P4] 第 ' + round.toString() + ' 轮后 ' + _count());
    }
  });
}
