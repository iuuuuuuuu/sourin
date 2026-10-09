// ═══════════════════════════════════════════════════════════════════════
//  task-58：合并页（上播放器 + 下详情）的回归测试
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要有这个文件（lead 的提醒）
//
// 本仓既有的一批测试是**读源码字符串**的（`readAsStringSync`），
// 它们在"详情页退役"之后**可能仍然绿** —— 因为文件还在。
// ⇒ ★ 那是**假绿**：测的东西已经不在产品路径上了。
//
// 所以这里补两类测试：
// ```text
// ① ★ **新路径真的接上了**（生产源码的门控断言）：
//      shell.dart 的非直播入口必须是 MediaPage，直播必须仍是 PlayerPage
// ② ★ **新逻辑本身正确**（纯逻辑，不需要真播放器）：
//      · isSameSessionAs 的四元组语义（含 null/'' 等价）
//      · ★ "只补标题"绝不能触发重启 —— 那个设计 bug 的回归测试
// ```
//
// ⚠️ 这里**不**实例化真 `MediaPage`：它一构建就创建 `Player`（要 mpv + 网络）。
//    结构/门控用源码断言（本仓既有先例：`zz_t42` 断言 `_anySheetOpen` 成员、
//    `zz_t53` 断言参数表），逻辑用纯函数测。
//    真机行为由**真机实测**回答（见 task-58 验收判据）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/models.dart' show Episode;
import 'package:sourin_spike/ui/media_session.dart';

/// 读生产源码并**剥掉注释**
///
/// ⚠️ 必须剥注释：本仓踩过这个坑（`zz_t53` L354-357 逐字记录了
///    "把注释文本写进判据 ⇒ 永远找不到 ⇒ 假红"）。
///    而本文件尤其需要 —— 我在 `shell.dart` 里写了**大段注释**提到
///    `PlayerPage`/`MediaPage`，不剥注释会让"计数"类断言全部失真。
String _src(String path) {
  final raw = File(path).readAsStringSync();
  return raw
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ')
      .replaceAll(RegExp(r'//[^\n]*'), ' ');
}

PlayRequestData _req({
  String provider = 'cycani',
  String id = '3862',
  String? episodeId,
  String? sourceCode,
  String title = '测试剧',
}) =>
    PlayRequestData(
      provider: provider,
      id: id,
      title: title,
      episodeId: episodeId,
      sourceCode: sourceCode,
    );

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① isSameSessionAs 的四元组语义
  // ═══════════════════════════════════════════════════════════════════

  group('① isSameSessionAs：决定"要不要重启流"的判据', () {
    test('★ 四元组全同 ⇒ 同一会话（不重启）', () {
      final a = _req(episodeId: 'ep3', sourceCode: 'line1');
      final b = _req(episodeId: 'ep3', sourceCode: 'line1');
      expect(a.isSameSessionAs(b), isTrue);
      expect(b.isSameSessionAs(a), isTrue, reason: '必须对称');
    });

    test('★★ 换集 ⇒ 不同会话（★ 只比 provider/id 会让换集失效）', () {
      final a = _req(episodeId: 'ep3', sourceCode: 'line1');
      final b = _req(episodeId: 'ep4', sourceCode: 'line1');
      expect(a.isSameSessionAs(b), isFalse,
          reason: '★★★ 若这里为 true ⇒ 用户点另一集**不会换** ⇒ 换集失效。'
              '这正是四元组必须含 episodeId 的理由');
    });

    test('★★ 换线路 ⇒ 不同会话', () {
      final a = _req(episodeId: 'ep3', sourceCode: 'line1');
      final b = _req(episodeId: 'ep3', sourceCode: 'line2');
      expect(a.isSameSessionAs(b), isFalse);
    });

    test('★ 换作品 ⇒ 不同会话', () {
      expect(_req(id: '1').isSameSessionAs(_req(id: '2')), isFalse);
      expect(_req(provider: 'a').isSameSessionAs(_req(provider: 'b')), isFalse);
    });

    test('★★ null 与空串**等价**（否则"同一条线路"会被误判成换线路）', () {
      /*
       * 调用方一处传 `_activeSource.isEmpty ? null : _activeSource`、
       * 另一处可能传 `''` —— 那是同一个意思。
       * 严格比较会把它们判成"换了线路" ⇒ 多一次重启。
       */
      final a = _req(episodeId: 'ep3', sourceCode: null);
      final b = _req(episodeId: 'ep3', sourceCode: '');
      expect(a.isSameSessionAs(b), isTrue,
          reason: '★ null 与 "" 都表示"没有指定线路" ⇒ 必须等价');
      expect(b.isSameSessionAs(a), isTrue, reason: '必须对称');
    });

    test('★★ 标题/剧集列表**不参与**判据（否则刷新详情就会重启播放）', () {
      final a = PlayRequestData(
        provider: 'p',
        id: 'i',
        title: '旧标题',
        episodeId: 'ep1',
        sourceCode: 's',
        episodes: const [Episode(id: 'ep1', title: '第1集')],
        episodeIndex: 0,
      );
      final b = PlayRequestData(
        provider: 'p',
        id: 'i',
        title: '新标题（上游改了）',
        episodeId: 'ep1',
        sourceCode: 's',
        // 剧集多了一集
        episodes: const [
          Episode(id: 'ep1', title: '第1集'),
          Episode(id: 'ep2', title: '第2集'),
        ],
        episodeIndex: 0,
      );
      expect(a.isSameSessionAs(b), isTrue,
          reason: '★★ 标题变了、剧集多了一集 ⇒ 仍是**同一个会话**。'
              '若这里为 false ⇒ "详情刷新"会导致**正在播的流被重启**'
              '（黑屏 + 丢进度），而那是用户完全没要求的动作');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② "只补标题"不得触发重启（那个设计 bug 的回归测试）
  // ═══════════════════════════════════════════════════════════════════

  group('② ★★★ 补标题不得重启流（设计 bug 的回归测试）', () {
    test('★★★ 若用 applySession 补标题 ⇒ 会因 episodeId 缺失被判为"换会话"', () {
      /*
       * 这是**反面**证明：把"补标题"写成 `applySession(provider,id,title)`
       * （不传 episodeId/sourceCode）会怎样。
       *
       * 合并页的启动顺序是"播放器先起播、详情后加载"，那一刻会话已经是
       * 第 3 集 / line1 了。若"补标题"走 applySession：
       */
      final current = _req(episodeId: 'ep3', sourceCode: 'line1');
      final titleOnly = PlayRequestData(
        provider: 'cycani',
        id: '3862',
        title: '真标题',
        // ★ 没传 episodeId / sourceCode ⇒ 默认 null
      );
      expect(titleOnly.isSameSessionAs(current), isFalse,
          reason: '★★★ 这就是那个 bug：**补个标题**却让四元组不同 ⇒ '
              '被判为"换会话" ⇒ **白重启一次流**（黑屏 + 丢进度）。'
              '⇒ 所以"改展示"必须走**另一个**方法（updateDisplayTitle）');
    });

    test('★★ 接口层面：MediaSession 必须把两件事分成两个方法', () {
      final src = _src('lib/ui/media_session.dart');
      expect(src.contains('Future<void> applySession('), isTrue,
          reason: 'applySession 必须存在（改会话）');
      expect(src.contains('void updateDisplayTitle('), isTrue,
          reason: '★★ updateDisplayTitle 必须存在（只改展示）——'
              '它是"补标题不重启"的结构性保证：'
              '它**不碰任何流相关状态**，因此不可能导致重启');
    });

    test('★★ updateDisplayTitle 的实现只碰标题（不碰流状态）', () {
      /*
       * 结构性判据：实现体里**不得**出现任何"流相关"的调用。
       * 比"注释里承诺"强 —— 后人加了 `_resolveAndPlay` 就会红。
       */
      final raw = File('lib/ui/player_page.dart').readAsStringSync();
      final i = raw.indexOf('void updateDisplayTitle(');
      expect(i, greaterThan(0), reason: '找不到 updateDisplayTitle 实现');
      // 取到下一个 `}` 结束的方法体（粗取 800 字符足够覆盖这个方法）
      final body = raw.substring(i, (i + 800).clamp(0, raw.length));

      for (final forbidden in [
        '_resolveAndPlay',
        '_reload(',
        '_startPlayback',
        '_loadSkipMarker',
        '_pendingSeek',
        '_streams =',
      ]) {
        expect(body.contains(forbidden), isFalse,
            reason: '★★★ `updateDisplayTitle` 里出现了 `$forbidden` ⇒ '
                '它不再"只改展示" ⇒ 补标题可能重启流（正是那个 bug 的形态）。'
                '若确实需要改流状态，请**改调 applySession**，不要混进这里');
      }
      expect(body.contains('_title ='), isTrue,
          reason: '它应当更新 `_title`（那是它唯一的职责）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 生产源码门控：新路径真的接上了
  // ═══════════════════════════════════════════════════════════════════

  group('③ ★★ 生产源码门控：入口必须指向合并页', () {
    test('★★★ 非直播入口必须是 MediaPage（不是 PlayerPage）', () {
      final shell = _src('lib/shell.dart');

      // 三个非直播入口：`onShelfPlay` / `FollowPage.onPlay` / `_openPlayer`
      expect(shell.contains('_mediaRoute('), isTrue,
          reason: '★★★ `_mediaRoute` 不见了 ⇒ `_openDetail` 又回去 push 详情页了');
      expect(shell.contains('MediaPage('), isTrue,
          reason: '★★★ shell.dart 里必须出现 MediaPage( —— 否则详情入口没接上合并页');

      /*
       * ★ 判据：`_detailRoute` **不得**再存在（旧名字）。
       *   它若还在，说明有人把入口改回去了。
       */
      expect(shell.contains('_detailRoute'), isFalse,
          reason: '★★ `_detailRoute` 是**旧**入口的名字（push 独立详情页）。'
              '它还在 ⇒ 说明有入口没改到合并页');
    });

    test('★★★ 直播入口必须仍是 PlayerPage（风险④：直播不受影响）', () {
      final shell = _src('lib/shell.dart');
      /*
       * 剥注释后统计：`PlayerPage(` 必须仍然存在（直播那 3 处）。
       * ⚠️ 不能断言"恰好 3 次" —— 那会让无关的格式改动变红。
       *    要钉的性质是"**直播仍走 PlayerPage**"，用 liveChannelId 共存来判。
       */
      expect(shell.contains('PlayerPage('), isTrue,
          reason: '★★★ shell.dart 里 `PlayerPage(` 全没了 ⇒ 直播入口被误改成 '
              'MediaPage 了。而 MediaPage **没有** liveChannelId 等四个参数 ⇒ '
              '直播会失去"↑/↓ 切台"与"所有直播列表"（task-53 的功能）');

      // 每一处 PlayerPage( 的参数块里都应当有 liveChannelId
      final idx = <int>[];
      var from = 0;
      while (true) {
        final i = shell.indexOf('PlayerPage(', from);
        if (i < 0) break;
        idx.add(i);
        from = i + 1;
      }
      expect(idx, isNotEmpty, reason: '找不到 PlayerPage( ⇒ 结构变了');
      for (final i in idx) {
        final blk = shell.substring(i, (i + 400).clamp(0, shell.length));
        expect(blk.contains('liveChannelId'), isTrue,
            reason: '★★ 有一处 `PlayerPage(` 的参数块里**没有** liveChannelId ⇒ '
                '那是一条**非直播**入口，应当用 MediaPage（合并页）');
      }
    });

    test('★★ lib/ 里不得再有地方 push 独立 DetailPage', () {
      /*
       * 判据③"旧详情页完全去掉"的可测部分：
       * `DetailPage(` 只应出现在**两处**（它的构造声明 + 合并页嵌它）。
       * 若别处也出现 ⇒ 有人又把独立详情页 push 回来了。
       */
      final files = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();

      final hits = <String>[];
      for (final f in files) {
        final s = _src(f.path.replaceAll('\\', '/'));
        var from = 0;
        while (true) {
          final i = s.indexOf('DetailPage(', from);
          if (i < 0) break;
          hits.add('${f.path.replaceAll('\\', '/')}@$i');
          from = i + 1;
        }
      }

      // 允许的两处：构造声明（detail_page.dart）+ 合并页嵌入（media_page.dart）
      final allowed = hits
          .where((h) =>
              h.startsWith('lib/ui/detail_page.dart') ||
              h.startsWith('lib/ui/media_page.dart'))
          .toList();
      final unexpected = hits.where((h) => !allowed.contains(h)).toList();

      expect(unexpected, isEmpty,
          reason: '★★★ 这些地方在 push 独立 `DetailPage` ⇒ '
              '判据③（旧详情页完全去掉）被破坏：$unexpected');
    });

    test('★ MediaPage 必须用"类型与位置恒定"的布局（否则全屏会重建播放器）', () {
      final mp = _src('lib/ui/media_page.dart');
      /*
       * ★★★ 这是那个"极难归因"的坑的结构性防线：
       * 若有人把布局写成 `_windowFullscreen ? player : Row([...player...])`，
       * 父级就变了 ⇒ Element 卸载 ⇒ 新 State ⇒ **重建 Player**
       * ⇒ 症状"全屏后黑屏/重新加载"。
       *
       * ══════════════════════════════════════════════════════════════
       * ★ task-59：断言从 **Column 上下分栏** 改为 **Row 左右分栏**
       * ══════════════════════════════════════════════════════════════
       *
       * Owner 新裁决（逐字）：
       * > 你参照一下腾讯视频的播放页面布局，**左侧播放器右侧是视频的信息**
       * ⇒ 宽屏（>=900）走 `Row`；窄屏（手机竖屏）仍回退 `Column`。
       * ★ 所以**两者都必须存在**，且 `Row` 是宽屏那条主路径。
       */
      expect(mp.contains('Row('), isTrue,
          reason: '★★ task-59：MediaPage 必须用 **Row** 做左右分栏'
              '（Owner：「左侧播放器右侧是视频的信息」）');
      expect(mp.contains('Column('), isTrue,
          reason: '★ 窄屏（<900）必须**回退** Column 上下分栏 —— '
              '否则手机上左右分栏会把两者都挤到不可用');
      expect(mp.contains('Expanded('), isTrue,
          reason: '★ 视频区必须用 Expanded（占满剩余宽度）');
      expect(mp.contains('SizedBox(width: detailW'), isTrue,
          reason: '★★ 右侧信息栏必须是**定宽** `SizedBox(width: detailW)` —— '
              '腾讯视频的侧栏也是定宽（不是按比例拉伸）');
      expect(mp.contains('_playerKey'), isTrue,
          reason: '★★ 播放器必须挂**稳定的 GlobalKey** ⇒ '
              '无论 flex 怎么变、详情区在不在、轴向怎么切，'
              '它的 Element 位置不变 ⇒ State 复用');
      // 不得把播放器放在三元表达式里"换父级"
      expect(
        RegExp(r'_\w*[Ff]ullscreen\s*\?\s*\w*[Pp]layer').hasMatch(mp),
        isFalse,
        reason: '★★★ 出现"全屏 ? 播放器 : …"这种**换父级**的写法 ⇒ '
            '全屏切换会重建播放器（黑屏）。必须保持播放器恒定是第 0 个 child',
      );
      /*
       * ★★ 轴向阈值 900 必须与 `live_page.dart` 的窄屏断点同源。
       *   ⚠️ 不写死"900"字面量在这里 —— 只要求源码里出现 `>= 900`。
       */
      expect(RegExp(r'width\s*>=\s*900').hasMatch(mp), isTrue,
          reason: '★ 轴向阈值必须是 `width >= 900`（与 live_page 的窄屏断点同源）');
    });

    // ═══════════════════════════════════════════════════════════════════
    //  ★★★ 全屏检测（真机实测抓到的 bug 的回归测试）
    // ═══════════════════════════════════════════════════════════════════

    test('★★★ 全屏判据不得只依赖 windowManager 的 enter-full-screen 事件', () {
      /*
       * # 真机实测的 bug（我第一版）
       *
       * `MediaPage` 用 `WindowListener.onWindowEnterFullScreen` 判断全屏
       * ⇒ **永远不会触发**：
       * ```text
       * window_manager 的 Windows 插件只在 WM_SIZE + SIZE_MAXIMIZED 时
       * 发 "enter-full-screen"（window_manager_plugin.cpp L291-294）；
       * 而对无边框窗口 SetFullScreen 连 SetWindowPos 都不调
       * （window_manager.cpp L591-614 的两次 SetWindowPos 全在
       *  if (!is_frameless_) 里；L592 那句会触发 SIZE_MAXIMIZED 的
       *  WM_SYSCOMMAND, SC_MAXIMIZE 被插件作者注释掉了）
       * ```
       * 实测证据：`'[MEDIA] 进入全屏' = 0 次`，而
       * `'[WINDOWFRAME#3] … physical=2560x1440 … => fullscreen=true'`
       * 证明窗口**确实**全屏了 ⇒ 判据⑥ FAIL。
       */
      final mp = _src('lib/ui/media_page.dart');

      // ① 必须有"播放器通知"这条权威来源
      expect(mp.contains('onFullscreenChanged'), isTrue,
          reason: '★★★ 必须注册播放器的全屏通知 —— 它是**权威来源**'
              '（`_fullscreen` 是"用户按了全屏键"的直接结果，不依赖窗口事件）');
      expect(mp.contains('_explicitFullscreen'), isTrue,
          reason: '★★ 必须有"显式来源"字段（由通知维护）⇒ '
              '与 WindowFrame 的 `_filled` 同一手法');

      // ② 必须有尺寸兜底
      expect(mp.contains('isWindowFullscreen('), isTrue,
          reason: '★ 必须有**尺寸兜底**（覆盖"从别处全屏进来"/"通知还没到"）');

      // ③ ★★★ 尺寸判据必须在 build 里被求值 ⇒ 必须注册尺寸依赖
      //    否则窗口 resize 时本页不重建 ⇒ 判据永远不被重新求值（task-54 的根因）
      expect(mp.contains('MediaQuery.of(context)'), isTrue,
          reason: '★★★ 必须在 build 里读一次 `MediaQuery` **注册尺寸依赖** —— '
              '否则全屏（= 窗口 resize）时本页**不会重建** ⇒ '
              '尺寸兜底判据永远不会被重新求值（这正是 task-54 的根因，'
              '见 window_frame.dart L627 的逐字记录）');

      // ④ 回调必须在 dispose 里注销（避免打到已卸载的 State）
      expect(mp.contains('s.onFullscreenChanged = null'), isTrue,
          reason: '★ dispose 里必须**注销**回调 ⇒ '
              '否则播放器若比本页活得久，回调会打到已卸载的 State 上');
    });

    test('★★ 播放器必须在 setState 之后、且用 ?.call 发通知', () {
      final raw = File('lib/ui/player_page.dart').readAsStringSync();
      /*
       * ★★★ 2026-10-09（task-15）：匹配串**不能带 `()`**
       *
       * # 为什么要改（这是 task-8 引入的真红）
       * ```text
       * 原来写死 `'Future<void> _toggleFullscreen()'`。
       * task-8 ① 给它加了可选参数（`{bool awaitOs = true}`）—— 那是 lead 要求的修法 ——
       * 于是签名字面量变成 `Future<void> _toggleFullscreen({bool awaitOs = true})`
       * ⇒ 本行 `indexOf` 取到 **-1** ⇒ 这条断言失败（Expected > 0, Actual -1）。
       * ```
       * ★ 判据的**意图**（「这个函数必须存在」）没变，所以只去掉 `()` 这个无关细节，
       *   **不是**放宽判据 —— 下面 :400-405 那两条顺序断言仍然一字不改地钉着。
       */
      final i = raw.indexOf('Future<void> _toggleFullscreen(');
      expect(i, greaterThan(0), reason: '找不到 _toggleFullscreen');
      /*
       * ★ 窗口大小复核（task-15 lead 明确要求给读数）
       * ```text
       * 实测（改后重新量，因为 awaitOs 参数 + 新增的长注释都加大了偏移）：
       *   i                    = 242306
       *   iSet（setState 锚点） = 121
       *   iNotify（?.call 锚点）= 1169
       *   函数体真实结束偏移      = 2614   <- 由 `\n  }\n` 测得
       *   窗口 4200              = 仍完整覆盖，余量 ~1586 字符
       * ```
       * ⇒ **4200 够用，不需要调大**；且两个锚点都在窗口内、顺序正确（iNotify > iSet）。
       * ⚠️ 窗尾会多伸进后面无关注释约 1586 字符 —— 对 `contains`/`indexOf` 无影响
       *   （只会在两个锚点**之后**追加文本，不会把 iSet/iNotify 带偏）。
       */
      final body = raw.substring(i, (i + 4200).clamp(0, raw.length));

      expect(body.contains('_onFullscreenChanged?.call(next)'), isTrue,
          reason: '★★★ `_toggleFullscreen` 必须通知合并页（`MediaSession` 的'
              '权威来源）。`?.call` 是必需的 —— 独立页面用法下回调为 null');

      /*
       * ★ 顺序判据：通知必须在 `setState(() => _fullscreen = next);` **之后**
       *   —— 否则合并页重建时读到的 `isFullscreen` 还是**旧值**
       *   ⇒ 白重建一次（症状：全屏后详情区不收起）。
       */
      final iSet = body.indexOf('setState(() => _fullscreen = next);');
      final iNotify = body.indexOf('_onFullscreenChanged?.call(next)');
      expect(iSet, greaterThan(0), reason: '找不到 _fullscreen 的 setState');
      expect(iNotify, greaterThan(iSet),
          reason: '★★★ 通知必须在 `setState(_fullscreen = next)` **之后** —— '
              '否则合并页重建时读到的还是旧值 ⇒ 全屏后详情区不收起');
    });

    test('★★ 接口层：MediaSession 必须同时有 getter 与 setter（权威 + 兜底）', () {
      final src = _src('lib/ui/media_session.dart');
      expect(src.contains('bool get isFullscreen'), isTrue,
          reason: '★ 需要 getter（合并页读当前状态）');
      expect(src.contains('set onFullscreenChanged('), isTrue,
          reason: '★★ 需要 setter（播放器**主动**通知）—— '
              '子节点 setState 不会让父节点重建，所以必须主动通知');
    });

    test('★★★ 注册回调的重试必须有**上限**（否则每帧空转）', () {
      /*
       * # 我自己发现的坑（写完就复查出来的）
       *
       * `_bindPlayerCallbacks` 在 `_session == null` 时会"下一帧再试"：
       * ```dart
       * WidgetsBinding.instance.addPostFrameCallback((_) => _bindPlayerCallbacks());
       * ```
       * 若播放器**永远**挂不上（例如它抛异常没建出来），这就是
       * **每帧排一帧**的无限递归 ⇒ CPU 白烧 + 日志被刷爆。
       *
       * ⚠️ 它只在"播放器永远挂不上"时发作 —— 而那正是最难注意到的情况
       *   （页面看起来正常，只是风扇转得快）。
       */
      final mp = _src('lib/ui/media_page.dart');
      expect(mp.contains('_bindAttempts'), isTrue,
          reason: '★★★ 必须有重试计数器 —— 否则 `addPostFrameCallback` 递归'
              '会变成"每帧排一帧"的空转（CPU 白烧 + 日志刷爆）');
      expect(
        RegExp(r'_bindAttempts\s*>\s*\d+').hasMatch(mp),
        isTrue,
        reason: '★★★ 计数器必须**真的用于比较**（有一个上限）—— '
            '只声明不用等于没有上限',
      );
      expect(mp.contains('放弃注册全屏回调'), isTrue,
          reason: '★ 到达上限时要**明确说明**后果（退化为尺寸兜底），'
              '不能静默 —— 静默会让"全屏后详情区不收"变成无线索现象');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 详情区的 embedded 开关
  // ═══════════════════════════════════════════════════════════════════

  group('④ 详情区的 embedded 开关', () {
    test('★ 合并页必须传 embedded: true（否则多一层 Scaffold + 返回按钮）', () {
      final mp = _src('lib/ui/media_page.dart');
      expect(mp.contains('embedded: true'), isTrue,
          reason: '★ 合并页里详情区必须 embedded ⇒ '
              '不画 Scaffold/SafeArea（外层已有）、不画返回按钮'
              '（返回语义变成"回首页"，由 MediaPage 顶层负责）');
    });

    test('★ embedded 时不得画 Scaffold / 返回按钮', () {
      final dp = _src('lib/ui/detail_page.dart');
      /*
       * ══════════════════════════════════════════════════════════════
       * ★ task-59：从**字面串**改成**语义判据**
       * ══════════════════════════════════════════════════════════════
       *
       * 原断言是 `dp.contains('if (widget.embedded) return content;')`。
       * 而 T2 修根因②时把它从**单行**改成了**块**（加主题底色）：
       * ```dart
       * if (widget.embedded) {
       *   return ColoredBox(color: colors.surface, child: content);
       * }
       * ```
       * ⇒ ★ 那个改动是**对的**（正是"嵌入态必须自带底色"的修复），
       *   但**字面串断言**因此变红 ⇒ **假红**。
       *
       * ★ 教训（与本轮其它坑同族）：
       *   **断言字面写法 ⇒ 会把"等价的正确改写"报成回归**。
       *   要断言的语义是：
       *     ① `embedded` 分支**提前 return**
       *     ② 那个 return **不包** `Scaffold` / `SafeArea`
       *   ⇒ 用**结构**表达，而不是**字面**表达。
       */
      final i = dp.indexOf('if (widget.embedded)');
      expect(i, isNot(-1),
          reason: '★ 必须存在 `if (widget.embedded)` 分支');

      /*
       * 取该分支的**块体**：从 `if (widget.embedded)` 起，
       * 到"下一个顶层 `return Scaffold(`"之前 —— 那正是 embedded 提前返回
       * 与独立页 Scaffold 的分界。
       */
      final scaffoldAt = dp.indexOf('return Scaffold(', i);
      expect(scaffoldAt, greaterThan(i),
          reason: '★ 前置：`embedded` 分支之后应当有独立页的 `return Scaffold(`');
      final branch = dp.substring(i, scaffoldAt);

      expect(branch.contains('return'), isTrue,
          reason: '★ `embedded` 分支必须**提前返回**（不落到下面的 Scaffold）');
      expect(branch.contains('Scaffold('), isFalse,
          reason: '★★ `embedded` 分支里**不得**出现 `Scaffold(` ⇒ '
              '否则合并页里会多一层 Material 背景（盖住主题底色）');
      expect(branch.contains('SafeArea('), isFalse,
          reason: '★★ `embedded` 分支里**不得**出现 `SafeArea(` ⇒ '
              '否则它把"右侧栏"当整屏算内边距，边缘留白错位');

      expect(dp.contains('if (!widget.embedded)'), isTrue,
          reason: '★ 返回按钮必须被 `!embedded` 门控 ⇒ '
              '否则合并页里会出现两个返回入口，且语义不一致');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ 已知边界必须**可诊断**（Lead 裁决"记为已知边界"）
  // ═══════════════════════════════════════════════════════════════════

  group('⑤ 已知边界：换源后 episodes 未就绪', () {
    test('★★★ 必须有一行日志说明"下一集暂时不可用"（可诊断化）', () {
      /*
       * # 这个边界的由来（真机实测）
       *
       * 换源时 `MediaPage._onDetailSwitchSource` 调的 `applySession`
       * **没有带 `episodes`**（新源的剧集要等详情区重新拉一次才知道）⇒
       * 在"换源完成 → 新详情加载完"这**几秒**里播放器的剧集列表是空的：
       * ```text
       * · "下一集"暂时不可用（点了没反应）
       * · 选集面板暂时是空的
       * ```
       * 真机日志证据：`[PLAYER] applySession：换会话 ⇒ bilibili:… 共 **0** 集`
       *
       * # 为什么本测试盯"日志"而不是"修复"
       *
       * Lead 已裁决**记为已知边界**（修它要改 `applySession` 的契约 ——
       * 让合并页能"稍后补 episodes"，那是新的接口设计，值得单独一个 task）。
       * 但**必须可诊断**：否则用户报"下一集没反应"时无从下手。
       *
       * ★ 而这正是本会话的教训：我第一版的全屏判据坏了，日志里**什么都没有**，
       *   只能靠某行日志的**缺失**反推 —— 那是最难查的一类。
       */
      final mp = _src('lib/ui/media_page.dart');
      expect(mp.contains('episodes 尚未就绪'), isTrue,
          reason: '★★★ 换源后必须打一行"episodes 未就绪 ⇒ 下一集暂时不可用" —— '
              '把"已知边界"变成"**可诊断的**已知边界"。'
              '若有人删了它，用户报"下一集没反应"时就只剩猜');
      expect(mp.contains('已知边界'), isTrue,
          reason: '★ 注释里要写明它是**已知边界**（不是故障）—— '
              '否则后人会以为那是 bug 而"修"错地方');
    });

    test('★ 换源时**故意不传** episodes（这是设计，不是遗漏）', () {
      final mp = _src('lib/ui/media_page.dart');
      // 找到 _onDetailSwitchSource 里的 applySession 调用
      final i = mp.indexOf('Future<void> _onDetailSwitchSource(');
      expect(i, greaterThan(0), reason: '找不到 _onDetailSwitchSource');
      final body = mp.substring(i, (i + 2600).clamp(0, mp.length));
      final iCall = body.indexOf('applySession(PlayRequestData(');
      expect(iCall, greaterThan(0), reason: '换源里应当调 applySession');

      /*
       * ⚠️ 参数块必须**精确截到调用的收尾**（`));`），不能用一个固定长度窗口。
       *
       * ★ 我第一版用 400 字符窗口 ⇒ 窗口**越过了**调用的 `));`，
       *   把**后面那段解释"为什么不传 episodes"的注释**也吃进来了
       *   ⇒ 断言 `!call.contains('episodes')` **假失败**
       *     （注释里当然有这个词）。
       *
       * ⇒ 教训：**"在某段文本里找某词"必须先精确界定那段文本的边界** ——
       *   否则你会把相邻的注释/代码一起算进来（本仓反复踩的坑）。
       */
      final iEnd = body.indexOf('));', iCall);
      expect(iEnd, greaterThan(iCall), reason: '找不到 applySession 调用的收尾 `));`');
      final call = body.substring(iCall, iEnd + 2);

      expect(call.contains('episodes'), isFalse,
          reason: '★ 换源时**不应**传 episodes —— 那一刻新源的剧集还不知道。'
              '若有人"顺手"传了旧源的 episodes，播放器会拿着**旧源的剧集列表**'
              '去播新源 ⇒ 点"下一集"会跳到旧源的集上（串台）');
    });
  });
}
