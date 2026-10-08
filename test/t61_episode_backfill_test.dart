// ═══════════════════════════════════════════════════════════════════════
//  「上一集 / 下一集」的前提：播放器必须有**剧集列表**
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
//
// > 加一个剧集自动滚动到当前观看剧集位置的功能，当然进入到这个页面
// > **上一集 下一集**，也都要自动联动滚动到当前剧集到可视区域
//
// # 真机实测发现的缺口（这一条是本轮**新发现**的）
//
// ```text
// 首页入口 `_mediaRoute(provider, id)` **只给 id** ⇒ `widget.episodes` 为空
//   ⇒ `PlayerPage.episodes` 恒为空 ⇒ `_nextEpisode == null`
//   ⇒ ★ 按 N（下一集）**没有任何反应**
//
// 真机日志（pid 6868）逐字：
//   [NAV] 打开合并页: cycani:3862        ← 只给了 id
//   [PLAYER-KEY] ⓪ 入口：收到 N          ← 键确实收到了
//   （之后什么都没有）                    ← ★ 因为列表是空的
// ```
//
// ★ 这正是 task-58 记下的**已知边界**（`media_page.dart` 里逐字写过：
//   「修它要让详情区拉到剧集后**回填**给播放器 —— 那需要给 `MediaSession`
//     加一个新方法（"稍后补 episodes"）」）
//   ⇒ 本轮补上了那个方法：`updateEpisodes`。
//
// ⚠️ 本文件**不**挂真 `PlayerPage`（它一构建就建 `Player`，要 mpv + 网络）。
//    用**源码断言**（剥注释）+ 接口签名断言。本仓既有先例：`t58_media_page_test.dart`。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 读生产源码并剥掉注释
///
/// ⚠️ 必须剥注释：本文件的被测代码里**大段注释引用了旧写法/缺口描述**
///    （例如"按 N 没有任何反应"），不剥注释会让否定式断言失效。
String _src(String path) {
  final raw = File(path).readAsStringSync();
  return raw
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ')
      .replaceAll(RegExp(r'//[^\n]*'), ' ');
}

void main() {
  group('① 接口：MediaSession 必须有"稍后补 episodes"的能力', () {
    test('★★★ 接口必须声明 updateEpisodes(List<Episode>)', () {
      final src = _src('lib/ui/media_session.dart');
      expect(src.contains('void updateEpisodes(List<Episode> episodes)'), isTrue,
          reason: '★★★ 没有这个方法，详情页拉到的剧集列表就**送不到**播放器 ⇒ '
              '首页进合并页后「下一集」永久失效（真机实测）');
    });

    test('★★ updateEpisodes 必须在 applySession **之外**（它不能换会话）', () {
      final src = _src('lib/ui/media_session.dart');
      final i = src.indexOf('void updateEpisodes(');
      expect(i, greaterThan(0), reason: '找不到 updateEpisodes 声明');
      // 取它上方的一段文档（声明之前的注释已被剥掉，这里看接口区结构）
      expect(src.contains('Future<void> applySession(PlayRequestData req)'), isTrue,
          reason: '★ applySession 仍必须独立存在（换会话语义）');
    });
  });

  group('② 实现：只补列表，不碰流', () {
    test('★★★ PlayerPage 必须实现 updateEpisodes', () {
      final src = _src('lib/ui/player_page.dart');
      expect(src.contains('void updateEpisodes(List<Episode> episodes)'), isTrue,
          reason: '★★★ 接口声明了但没实现 ⇒ 编译不过（这是结构性对偶，'
              '两者必须同时存在）');
    });

    test('★★★ updateEpisodes 里**不得**出现任何重启流的调用', () {
      /*
       * 与 `updateDisplayTitle` 的既有判据**同款**（`t58_media_page_test.dart`）：
       * 用禁词表做结构性判据 —— 比"注释里承诺不重启"强得多。
       * ★ 后人若为了"顺手刷新一下"加上 `_reload()`，立刻变红。
       */
      final raw = File('lib/ui/player_page.dart').readAsStringSync();
      final i = raw.indexOf('void updateEpisodes(List<Episode> episodes)');
      expect(i, greaterThan(0), reason: '找不到 updateEpisodes 实现');
      // 取到下一个 `@override` 之前（= 本方法体）
      final end = raw.indexOf('@override', i + 10);
      expect(end, greaterThan(i), reason: '找不到方法结束边界（下一个 @override）');
      final body = raw.substring(i, end);

      for (final forbidden in [
        '_resolveAndPlay',
        '_reload(',
        '_startPlayback',
        '_loadSkipMarker',
        '_pendingSeek =',
        '_streams =',
      ]) {
        expect(body.contains(forbidden), isFalse,
            reason: '★★★ `updateEpisodes` 里出现了 `$forbidden` ⇒ '
                '它不再"只补列表" ⇒ 详情加载完这个**无害时刻**会白重启一次流'
                '（黑屏 + 丢进度）。若确实需要换流，请走 `applySession`。');
      }
      expect(body.contains('_episodes = episodes'), isTrue,
          reason: '★ 它至少要真的把列表换上（唯一职责）');
    });

    test('★★★ 下标必须夹取（新列表更短时不越界）', () {
      final src = _src('lib/ui/player_page.dart');
      final i = src.indexOf('void updateEpisodes(List<Episode> episodes)');
      final body = src.substring(i, (i + 2500).clamp(0, src.length));
      expect(body.contains('_epIndex >= _episodes.length'), isTrue,
          reason: '★★★ 当前 `_epIndex` 是基于**旧**列表算的。新列表更短时'
              '不夹取 ⇒ `_episodes[_epIndex]` 越界抛异常。')
      ;
      expect(body.contains('_epIndex = _episodes.isEmpty ? 0 : _episodes.length - 1'),
          isTrue,
          reason: '★ 夹取的目标值（注意空列表要走 0）');
    });

    test('★★ 幂等：列表没变就不 setState', () {
      final src = _src('lib/ui/player_page.dart');
      final i = src.indexOf('void updateEpisodes(List<Episode> episodes)');
      final body = src.substring(i, (i + 2500).clamp(0, src.length));
      expect(body.contains('if (same) return;'), isTrue,
          reason: '★ 详情可能多次回调 ⇒ 不幂等会反复 setState（白重建）');
      expect(body.contains('episodes.isEmpty) return;'), isTrue,
          reason: '★ 空列表不是有效回填（会把已有列表清空）');
    });
  });

  group('③ 调用点：详情加载完必须回填', () {
    test('★★★ `_onDetailLoaded` 必须调 updateEpisodes', () {
      final src = _src('lib/ui/media_page.dart');
      expect(src.contains('_session?.updateEpisodes(d.episodes)'), isTrue,
          reason: '★★★ 详情页手里**正好**有 `d.episodes` —— 不转发它，'
              '播放器的列表就永远是空的 ⇒「下一集」永久失效');
    });

    test('★★★ 回填**不得**用 applySession 代劳（那会重启流）', () {
      final src = _src('lib/ui/media_page.dart');
      final i = src.indexOf('Future<void> _onDetailLoaded(');
      expect(i, greaterThan(0), reason: '找不到 _onDetailLoaded');
      final end = src.indexOf('@override', i);
      final body = src.substring(i, end > i ? end : src.length);
      expect(body.contains('applySession'), isFalse,
          reason: '★★★ `_onDetailLoaded` 里不得出现 `applySession` —— '
              '会话四元组不同 ⇒ 判为"换会话" ⇒ **白重启一次流**'
              '（这正是 `updateDisplayTitle` 那条注释记录的教训）');
    });
  });
}
