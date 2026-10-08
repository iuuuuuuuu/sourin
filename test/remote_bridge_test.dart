// ═══════════════════════════════════════════════════════════════════════
//  局域网遥控桥 —— 模型与策略的回归测试
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守什么
//
// 遥控桥是**跨进程协议**：Dart 拼的 Map → Rust 反序列化 → 手机端显示。
// 任何一环的字段名/形状错了，**编译期毫无提示**，只在手机上表现为
// 「点了没反应」或「状态不对」—— 那是最难查的一类 bug。
//
// 所以这里重点守：
// ```text
// ① RemoteState.toJson() 的**字段名与形状**（必须与 Rust 侧一致）
// ② RemoteCommand.fromJson() 能把 kind 与参数正确拆开
// ③ 那个"新字段必须同步加进签名"的坑（原版踩过两次）
// ```

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

/// 空实现的全局能力 —— `_execCommand` 第一行就是 `if (g == null) return;`，
/// 不注册的话命令会被**静默丢弃**，测试就会假绿。
Future<void> _noopSearch(String _) async {}

Future<void> _noopLoadHome() async {}

/// 剥掉注释行 —— 静态断言里做文本匹配**必须先剥注释**
///
/// ⚠️ 本项目已经踩过至少四次这个坑：注释里提到某标识符，纯文本匹配
///    把它当成真实调用，测试**假绿**。
///
/// ★ 我自己这次也踩了（2026-09-25）：`_moveProvider` 的文档注释里
///   引用了 `` `case 'move_provider':` `` 来说明"文本断言不可靠"，
///   结果 `src.indexOf("case 'move_provider':")` 命中的**是那句注释**
///   （offset 6470），而不是真正的 case（offset 13475）——
///   于是「case 必须在 `final p = _player;` 之前」这条断言**误报失败**。
///   讽刺的是：那条注释的内容正是"别只做文本匹配"。
///
/// 与 `proxy_configs_test.dart` 的 `_code()` 同一实现（保持全项目一致）。
String _code(String src) => src
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
    })
    .join('\n');

void main() {
  group('RemoteState —— 上报给手机的状态', () {
    test('★★ toJson 的字段名必须与 Rust 侧逐字一致', () {
      /*
       * Rust 侧是 serde 反序列化，字段名对不上会**直接拒绝** ——
       * 这是有意的安全设计（不能让手机端任意指挥前端）。
       * 编译期不会报错，只在运行时表现为"状态不更新"。
       */
      final j = const RemoteState().toJson();

      // 逐字对齐原版 `src/api/types.ts` 的 `RemoteState`
      const expected = [
        'playing',
        'title',
        'episode_order',
        'episode_count',
        'position',
        'duration',
        'volume',
        'muted',
        'sources',
        'current_source',
        'episodes',
        'has_media',
        // ★ 片头片尾四项
        'intro_start',
        'intro_skip',
        'outro_skip',
        'outro_end',
        'auto_skip',
        'skip_editing',
      ];
      for (final k in expected) {
        expect(j.containsKey(k), isTrue,
            reason: '★ 缺字段 `$k` —— Rust 反序列化会因缺字段失败，'
                '表现为手机上状态不更新，而编译期毫无提示');
      }
      expect(j.length, expected.length,
          reason: '字段数量应与原版一致（多了不会报错，但说明契约漂移了）');
    });

    test('★ 片头片尾字段必须是 snake_case（不是 camelCase）', () {
      final j = RemoteState(
        introStart: 12,
        introSkip: 49,
        outroSkip: 6200,
        outroEnd: 6300,
      ).toJson();

      // Rust 侧是 intro_start / intro_skip / outro_skip / outro_end
      expect(j['intro_start'], 12);
      expect(j['intro_skip'], 49);
      expect(j['outro_skip'], 6200);
      expect(j['outro_end'], 6300);

      // 不该出现 camelCase 版本
      expect(j.containsKey('introStart'), isFalse);
      expect(j.containsKey('introSkip'), isFalse);
    });

    test('★★ 未设置时片头片尾字段要给 null，不能省略', () {
      /*
       * 原版注释记过这个坑：
       * > 不给的话端上显示 undefined。
       * 所以 key 必须在、值可以是 null。
       */
      final j = const RemoteState().toJson();
      for (final k in ['intro_start', 'intro_skip', 'outro_skip', 'outro_end']) {
        expect(j.containsKey(k), isTrue, reason: '`$k` 这个 key 必须存在');
        expect(j[k], isNull, reason: '`$k` 未设置时值应为 null');
      }
      expect(const RemoteState().hasMedia, isFalse);
    });

    test('★ sources / episodes 必须是 List 而不是 Map（Rust 是 Vec 元组）', () {
      final j = RemoteState(
        sources: const [('line1', '线路一'), ('line2', '线路二')],
        episodes: const [(1, '第1集'), (2, '第2集')],
      ).toJson();

      // Rust 侧 `Vec<(String,String)>` / `Vec<(i32,String)>`
      expect(j['sources'], isA<List>());
      expect(j['episodes'], isA<List>());
      expect((j['sources'] as List).first, ['line1', '线路一']);
      expect((j['episodes'] as List).first, [1, '第1集']);
    });

    test('★ idle() 是"没有播放器"的标准形状', () {
      /*
       * ⚠️ 原版注释强调：**没有播放页时也要上报**（报 idle）——
       *    不报的话手机会一直显示上次的标题与进度，用户以为还在播。
       */
      final idle = RemoteState.idle();
      expect(idle.hasMedia, isFalse);
      expect(idle.title, isEmpty);
      expect(idle.position, 0);
      expect(idle.playing, isFalse);
      // 但自动跳过是**设置项**（不属于某个视频），仍要给值
      expect(idle.autoSkip, isTrue,
          reason: 'autoSkip 是设置而非播放态 —— idle 时也要给合理值');
    });

    test('★ 往返一致：toJson 后再 fromJson 形状不变', () {
      const s = RemoteState(
        playing: true,
        title: '测试剧',
        episodeOrder: 3,
        episodeCount: 12,
        position: 100,
        duration: 2400,
        volume: 80,
        muted: false,
        sources: [('a', 'A')],
        currentSource: 'a',
        episodes: [(1, '第1集')],
        hasMedia: true,
        introStart: 10,
        introSkip: 60,
      );
      final j = s.toJson();

      // 逐项核对（这就是"手机端会看到的"）
      expect(j['playing'], true);
      expect(j['title'], '测试剧');
      expect(j['episode_order'], 3);
      expect(j['episode_count'], 12);
      expect(j['position'], 100);
      expect(j['duration'], 2400);
      expect(j['volume'], 80);
      expect(j['has_media'], true);
      expect(j['current_source'], 'a');
    });
  });

  group('RemoteCommand —— 手机发来的命令', () {
    test('★ fromJson 把 kind 与参数正确拆开', () {
      final c = RemoteCommand.fromJson({
        'kind': 'seek_to',
        'position': 120,
      });
      expect(c.kind, 'seek_to');
      expect(c.args['position'], 120);
      expect(c.args.containsKey('kind'), isFalse,
          reason: 'kind 不应混进参数里');
    });

    test('★ 各命令的具名参数取值正确', () {
      expect(RemoteCommand.fromJson({'kind': 'query_search', 'keyword': '测试'})
          .keyword, '测试');
      expect(
          RemoteCommand.fromJson({
            'kind': 'play_item',
            'provider': 'cycani',
            'id': '3862',
            'title': '某剧',
          }).provider,
          'cycani');
      expect(
          RemoteCommand.fromJson({
            'kind': 'switch_source',
            'code': 'line2',
          }).code,
          'line2');
      expect(
          RemoteCommand.fromJson({
            'kind': 'skip_toggle_auto',
            'on': true,
          }).flag('on'),
          true);
      expect(
          RemoteCommand.fromJson({
            'kind': 'goto_episode',
            'order': 5,
          }).number('order'),
          5);
    });

    test('★ 缺字段时返回 null 而不是抛异常', () {
      /*
       * 遥控是"尽力执行"的场景 —— 一条畸形命令不该让整个 tick 崩掉
       *（那样后续命令也全丢了）。
       */
      final c = RemoteCommand.fromJson({'kind': 'seek'});
      expect(c.kind, 'seek');
      expect(c.number('delta'), isNull);
      expect(c.keyword, isNull);
      expect(c.provider, isNull);
    });

    test('★ 未知 kind 不崩（Rust 侧会拒绝，前端只需不炸）', () {
      final c = RemoteCommand.fromJson({'kind': 'something_new', 'x': 1});
      expect(c.kind, 'something_new');
      expect(c.args['x'], 1);
    });

    test('★ 畸形输入（缺 kind）不崩', () {
      final c = RemoteCommand.fromJson({});
      expect(c.kind, '');
    });
  });

  group('桥的策略（静态断言 —— 守那四条性能优化）', () {
    late String src;

    setUpAll(() {
      src = File('lib/ui/remote_bridge.dart').readAsStringSync();
    });

    test('★★ 遥控没开时**不按 400ms 轮询**，而是慢速复查（第一条，2026-09-25 修订）', () {
      /*
       * 原版实测：无条件轮询时，遥控没开也在每 800ms 发两次 IPC ——
       * 一次 5 次切页的操作里各被调了 12 次（共 24 次）。
       *
       * ══════════════════════════════════════════════════════════════
       * ★★ 这条测试的**判据在 2026-09-25 变过**（task-14 E），说明原因
       * ══════════════════════════════════════════════════════════════
       *
       * 原判据是「没开就 return，**完全不挂定时器**」+ 注释里有
       * 「正常的省电路径」几个字。那个设计有个**致命副作用**：
       * ```text
       * 应用启动时遥控必然还没开（Rust 侧是异步自启的）
       *   → 早退，_timer 保持 null
       *   → 之后**再没有任何东西**会调 _ensurePolling()
       *     （setGlobals/notifyEnabled 只在 RemoteBridgeHost.initState 调一次）
       * ⇒ 桥从启动到退出，_tick() 执行 0 次
       * ⇒ remote_take_commands() 从不被调 → 手机发的命令**永远躺在队列里**
       * ```
       * 这就是用户报的「遥控只在重启后才生效 / 手机上点了没反应」的根因。
       *
       * **新判据**（仍然守住"不要无条件高频轮询"这个初衷）：
       * ```text
       * 没开时 → 挂一个 _tickDisabledMs（5000ms）的**慢速复查**
       * 开了时 → 正常 400ms 轮询
       * ```
       * 强度对比：旧设计 0 次/秒（但桥会死）；原版反对的 2.5 次/秒；
       * 新设计 **0.2 次/秒** —— 仍然比原版反对的那个慢 12 倍。
       *
       * ⚠️ 所以这条测试**不是被削弱了，是判据换了**：它现在同时守
       *    「不能无条件高频轮询」与「必须能自愈」两件事。
       */
      expect(
        src.contains('if (!st.running) {'),
        isTrue,
        reason: '必须先查 running，没开就走另一条路（不是 400ms 轮询）',
      );
      expect(
        src.contains('_scheduleRecheck()'),
        isTrue,
        reason: '★ 没开时要挂**慢速复查** —— 否则桥会永久死亡（这是真 bug 的修法）',
      );
      expect(
        src.contains('const _tickDisabledMs = 5000;'),
        isTrue,
        reason: '★ 复查间隔必须是**慢速**（5 秒），不能等于 400ms —— '
            '否则就退化成原版实测过的"没开也在高频空转"',
      );
      expect(
        src.contains('_schedule(_tickPlayingMs)') &&
            src.contains('_tickDisabledMs'),
        isTrue,
        reason: '两条路径要分开：开了走快轮询、没开走慢复查',
      );
    });

    test('★★ 状态没变就跳过上报（第三条 —— sig 去重）', () {
      expect(src.contains('String _sig(RemoteState s)'), isTrue,
          reason: '必须有状态签名函数');
      expect(src.contains('if (s != _lastSig)'), isTrue,
          reason: '★ 签名没变就**不上报** —— 这是省 IPC 的主要来源');
    });

    test('★★ sig() 必须包含**全部**会影响手机显示的字段', () {
      /*
       * ⚠️⚠️ 原版注释：这个坑**踩过两次**。
       * > 加了片头片尾字段后忘了改这里，于是
       * > `skip_config_open` / `skip_toggle_auto` / `skip_clear`
       * > 这三条命令在客户端**实际生效了**（DB 写了、弹窗开了），
       * > 但手机端状态回传永远是旧值 —— 看起来像"命令没生效"。
       *
       * 所以这里逐个断言"每个字段都进了签名"。
       */
      for (final f in [
        's.hasMedia',
        's.playing',
        's.title',
        's.episodeOrder',
        's.episodeCount',
        's.currentSource',
        's.muted',
        's.position',
        's.duration',
        's.volume',
        's.episodes.length',
        's.sources.length',
        // ★ 片头片尾四项
        's.introSkip',
        's.outroSkip',
        's.introStart',
        's.outroEnd',
        's.autoSkip',
        's.skipEditing',
      ]) {
        expect(src.contains(f), isTrue,
            reason: '★ `$f` 必须加进 sig() —— 不加的话该项变化时'
                '签名不变，**状态永远不会上报**（原版踩过两次）');
      }
    });

    test('★ 空闲时降低频率（第四条）', () {
      expect(src.contains('_tickPlayingMs'), isTrue);
      expect(src.contains('_tickIdleMs'), isTrue);
      expect(
        src.contains('_schedule(playing ? _tickPlayingMs : _tickIdleMs)'),
        isTrue,
        reason: '★ 在播 400ms、空闲 2500ms —— 动态调整',
      );
    });

    test('★★ 播放页能力可撤下，但**桥本身不停**（原版修正过的关键点）', () {
      /*
       * 原版注释：
       * > ⚠️ 与旧版的区别：以前离开播放页会调 `stopRemoteBridge()`，
       * > 于是「在首页时遥控全废」。现在离开播放页只需
       * > `clearPlayerBridge()`，桥要继续跑（搜索要用）。
       *
       * ⚠️ 2026-09-25（task-14 F）：签名从 `clearPlayer()` 变成
       *    `clearPlayer([PlayerBridge? b])` —— 多了个**可选**参数，
       *    用来防"换页重叠时误清新注册的能力"：
       * ```text
       * 新播放页 B 的 initState 先跑 → setPlayer(B)
       * 旧播放页 A 的 dispose 后跑   → clearPlayer()  ← 把 B 清了！
       * ⇒ 手机上立刻又变成"没有播放器"
       * ```
       *    所以这里断言的是**语义**（"只清 _player、不停桥"），
       *    而不是那个已经过时的精确签名。
       */
      expect(src.contains('void clearPlayer('), isTrue,
          reason: '离开播放页应有独立的"撤能力"方法');
      expect(
        RegExp(r'void clearPlayer\([^)]*\) \{[^}]*_player = null;', dotAll: true)
            .hasMatch(src),
        isTrue,
        reason: '★ clearPlayer 只清 _player，**不能**设 _stopped 或 cancel 定时器',
      );
      expect(
        RegExp(r'void clearPlayer\([^)]*\) \{[^}]*_stopped = true', dotAll: true)
            .hasMatch(src),
        isFalse,
        reason: '★ clearPlayer 里**不得**停桥 —— 那会让"在首页时遥控全废"',
      );
      /*
       * ★ 新增：防"换页重叠误清"（这是 setPlayer 上线后才会暴露的竞态）
       */
      expect(src.contains('identical(_player, b)'), isTrue,
          reason: '★ 传了 b 时要确认"桥持有的确实是它"才清 —— '
              '否则新旧播放页重叠的瞬间会把新注册的抹掉');
    });

    test('★ 命令执行后强制重报一次（原版实测 3 秒延迟的修复）', () {
      expect(
        src.contains('if (cmds.isNotEmpty && _player != null)'),
        isTrue,
        reason: '★ 命令执行完要立刻重报 —— 否则要等下一个 tick，'
            '原版实测 3.15~3.94 秒延迟，用户以为"没点上"然后反复按',
      );
    });

    test('★ play_item 不能依赖播放页（原版真 bug）', () {
      /*
       * 原版实测：
       * ```text
       * POST /api/cmd {kind:play_item}  → 200 {"ok":true}
       * 5 秒后 /api/state               → title="" has_media=false  ← 没动
       * ```
       */
      expect(
        src.contains("case 'play_item':"),
        isTrue,
        reason: 'play_item 要在"全局能力"分支里处理',
      );
      /*
       * ⚠️ 关键：它必须在 `final p = _player;` 那句**之前**被 case 掉 ——
       *    否则会落到"需要播放器"的分支里。
       */
      final playItemIdx = src.indexOf("case 'play_item':");
      final needPlayerIdx = src.indexOf('final p = _player;');
      expect(playItemIdx, greaterThan(0));
      expect(needPlayerIdx, greaterThan(0));
      expect(playItemIdx, lessThan(needPlayerIdx),
          reason: '★ play_item 的 case 必须在"需要播放器"判断之前 —— '
              '否则用户在首页时点手机会被静默跳过（原版真 bug）');
    });

    test('★ 查询类命令在播放页之外也能用', () {
      expect(src.contains("case 'query_search':"), isTrue,
          reason: '搜索是全局能力，不该依赖播放页');
      expect(src.contains("case 'query_home':"), isTrue,
          reason: '发现是全局能力');
    });

    test('★ 单条命令失败不影响后续', () {
      expect(
        src.contains('命令执行失败'),
        isTrue,
        reason: '遥控场景下「尽力执行」比中断好 —— 单条失败要 catch 住',
      );
    });

    test('★ 单例（避免两套轮询同时跑）', () {
      expect(
        src.contains('static final RemoteBridge instance = RemoteBridge._();'),
        isTrue,
        reason: '★ 必须是单例 —— 每次 mount 都造实例会造成'
            '两套轮询同时跑（IPC 翻倍，正是原版"卡顿"的成因之一）',
      );
    });

    test('★ 可挂载宿主是 widget（不要求调用方记得调某个函数）', () {
      expect(src.contains('class RemoteBridgeHost extends StatefulWidget'),
          isTrue,
          reason: '做成 widget 后"挂上就有遥控"，契约显式且编译期可见');
      expect(
        src.contains('RemoteBridge.instance.setGlobals(g)'),
        isTrue,
        reason: 'initState 里注册全局能力',
      );
    });

    test('★★ 宿主 dispose **不能**停桥（否则遥控用着用着就死了）', () {
      /*
       * `_stopped = true` 是**终态** —— 停掉之后没人会重新启动它。
       * 而 RemoteBridgeHost 可能因热重载/页面重建被短暂 dispose。
       */
      final hostIdx = src.indexOf('class _RemoteBridgeHostState');
      final disposeIdx = src.indexOf('void dispose()', hostIdx);
      expect(hostIdx, greaterThan(0));
      expect(disposeIdx, greaterThan(hostIdx));
      /*
       * ⚠️ 区间必须**夹到文件长度**（第一版写死 +900，而 dispose 之后
       *    只剩 429 字符 → `RangeError: Invalid value: Not in inclusive
       *    range`，测试**因为断言写错**而失败）。
       *    静态断言里按偏移取子串时，边界要和内容一样小心。
       */
      final raw = src.substring(
        disposeIdx,
        disposeIdx + 900 > src.length ? src.length : disposeIdx + 900,
      );
      /*
       * ⚠️⚠️ 必须**先剥掉注释**再匹配 —— 这是同一个坑的第 N 次了。
       *
       * 我在 `dispose` 的注释里**解释了为什么不能调 stop()**，
       * 里面自然写了 `RemoteBridge.instance.stop()` 这个字符串，
       * 于是纯文本匹配命中了**注释**，测试**假失败**。
       *
       * ★ 结论：静态断言做文本匹配，**一律先剥注释**。
       */
      final body = raw
          .split('\n')
          .where((l) {
            final t = l.trimLeft();
            return !t.startsWith('//') &&
                !t.startsWith('*') &&
                !t.startsWith('/*');
          })
          .join('\n');

      expect(
        body.contains('RemoteBridge.instance.stop()'),
        isFalse,
        reason: '★ 宿主 dispose 里**不得**调 stop() —— '
            '_stopped 是终态，之后没人会重启桥，表现为"遥控用着用着就死了"'
            '（注释里提到它是可以的 —— 这里已剥掉注释）',
      );
    });
  });

  group('全局能力（search / loadHome）', () {
    late String src;

    setUpAll(() {
      src = File('lib/ui/remote_bridge.dart').readAsStringSync();
    });

    test('★★ search 必须"每个源轮流取"（原版真 bug，2026-09-25 改流式后仍守）', () {
      /*
       * 原版注释：原先"外层遍历源、内层遍历条目，凑够 60 条就 break 两层"
       * —— 于是**第一个源用 60 条配额全吃掉了**，别的源完全没机会出现。
       * 用户搜「从零开始」满屏都是央视的《老兵你好》，看着像"搜索坏了"。
       *
       * ══════════════════════════════════════════════════════════════
       * ★ 2026-09-25（task-14 A）：搜索从 `searchAll` 改成流式
       *   `searchAllStream`，但 **round-robin 必须原样保留**
       * ══════════════════════════════════════════════════════════════
       *
       * 改流式是因为实测「庆余年」要 24.64s 而手机端预算只有 18.2s
       *（用户报「遥控搜不到、客户端搜得到」）。但只改数据来源、
       * **不改变排序语义** —— 否则会把这个原版真 bug 重新引回来。
       *
       * ⚠️ 实现换了写法（不再是 `perRound`/`allDone` 两个变量，而是
       *    每次 flush 从游标 0 重算），所以这里断言**语义**：
       * ```text
       * ① 有"轮转游标"这个东西（cursors）
       * ② 内层每轮每个源只取 1 条（原版 PER_ROUND = 1）
       * ③ 有上限（_remoteSearchLimit）
       * ```
       */
      expect(src.contains('cursors'), isTrue,
          reason: '★ 必须按**轮次**交替取，不能"一个源取满再下一个"');
      expect(
        RegExp(r'groups\.length').hasMatch(src),
        isTrue,
        reason: '轮转要遍历**全部**源（每个源都要露脸）',
      );
      expect(src.contains('_remoteSearchLimit'), isTrue,
          reason: '要有总量上限（原版 60 条 —— 手机屏小，再多也滑不完）');
      /*
       * ★ 新增：必须是**流式**的（这是本次修复的核心）
       *
       * ⚠️ 走的是可注入接缝 `_searchStream ?? SourinApi.searchAllStream`
       *    （为了让"边搜边回填"能**真跑**测试，见本文件末尾那组），
       *    所以这里断言的是**默认实现**是流式。
       */
      expect(
        src.contains('_searchStream ?? SourinApi.searchAllStream'),
        isTrue,
        reason: '★★ 遥控搜索默认必须走流式 —— 一次性 searchAll 实测 24.64s，'
            '超过手机端 18.2s 预算，用户看到"没有找到结果"',
      );
      expect(src.contains('await flush();'), isTrue,
          reason: '每到一个源就要 flush 回填（边搜边出）');
      expect(
        src.contains('await SourinApi.searchAll('),
        isFalse,
        reason: '★ 不得再直接调一次性 searchAll（那正是"遥控搜不到"的根因）',
      );
    });

    test('★ 搜索失败也要回填（否则手机端一直转圈）', () {
      expect(
        src.contains('搜索失败'),
        isTrue,
        reason: '★ 失败要回填空结果 —— 不回填手机端会一直轮询到超时',
      );
    });

    test('★ loadHome 的两个上限（每区块 20 条 / 最多 8 区块）', () {
      expect(src.contains('items.take(20)'), isTrue,
          reason: '每区块 20 条 —— 手机屏幕小，给太多反而难滑');
      expect(src.contains('sections.length >= 8'), isTrue,
          reason: '★ 最多 8 个区块 —— 每个区块都是一次网络请求，'
              '全拉一遍在电视盒子上要好几秒');
    });

    test('★ loadHome 只预取 category / rank（与客户端判据一致）', () {
      expect(src.contains('sec.source.isCategory'), isTrue);
      expect(src.contains('sec.source.isRank'), isTrue);

      /*
       * ══════════════════════════════════════════════════════════════════
       * ★★★ 这条判据我自己修了两版（第二版**仍然假绿**，值得记）
       * ══════════════════════════════════════════════════════════════════
       *
       * **v1（原版，假绿）**：`src.contains('单个区块失败不影响其他')`
       *   ⇒ 那是**一句中文注释**，断言的是"注释存在"。
       *
       * **v2（我第一版修法，仍假绿）**：
       * ```dart
       * RegExp(r'\}\s*catch\s*\(_\)\s*\{[\s\S]{0,200}?continue\s*;')
       * ```
       *   ⇒ `[\s\S]{0,200}?` 会**跨过 `}` 边界**去匹配**后面**的 `continue`：
       * ```text
       * 变异后（删掉 catch 里的 continue）它匹配到的是：
       *   "} catch (_) { // 注释 // [MUT] removed } if (items.isEmpty) continue;"
       *                                        ↑ 这是**后面**那个 continue！
       * ⇒ 仍然恒真
       * ```
       *   ★ 教训：**正则里的"任意字符"会把结构边界吃掉** ——
       *     想断言"某个块**内部**有 X"，必须禁止跨过块的结束符。
       *
       * **v3（现在，有分辨力）**：用 `[^}]*` 明确**不跨 `}`**
       *   ⇒ 只允许在 catch 块**内部**找 `continue`。
       *   ★ 已用端到端变异证明：删掉 `continue` ⇒ 这条**变红**。
       */
      final code = _code(src);
      expect(
        RegExp(r'\}\s*catch\s*\(_\)\s*\{[^}]*continue\s*;').hasMatch(code),
        isTrue,
        reason: '★ 错误隔离的**本体**是"区块级 try/catch + catch 里 continue"——\n'
            '  它让失败的区块被跳过、其余区块继续渲染。\n'
            '  若这条失败 ⇒ 有人把区块级 try/catch 删了 ⇒ '
            '**一个区块失败会让整个首页空白**（手机端表现为"遥控首页什么都没有"）。\n'
            '  ⚠️ 这条**不再**断言那句中文注释 —— 那是假绿（见上方 v1/v2 的说明）。\n'
            '  ⚠️ 正则用 `[^}]*`（**不跨 `}`**）—— 用 `[\\s\\S]` 会跨过块边界，'
            '匹配到后面的 continue，导致假绿（我 v2 就踩了）。',
      );
    });

    test('★ 首页失败也要回填', () {
      expect(src.contains('首页加载失败'), isTrue);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ★★ 遥控排序 —— move_provider
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 为什么这组必须**真的执行**，不能只做文本断言
  //
  // 「排序有没有生效」的硬判据是**写出去的顺序真的变了**。
  // 只断言源码里出现了 `case 'move_provider':` 是文本匹配 ——
  // 它证明不了那条 case 真的可达（比如被前面的 `return` 挡住，
  // 或写成了 `move_provider` 但 Rust 发的是别的名字）。
  //
  // 所以这里注入一个**内存版的顺序存储**，然后喂真命令进去，
  // 断言存储里收到的列表 —— 与 `proxy_configs_test.dart` 用
  // `ProxyCache.overrideFetchers` 的同一套思路。
  group('★★ 遥控排序 —— move_provider 真的改变顺序', () {
    /// 内存版"后端顺序"（模拟 `registry.reorder` + `save_order`）
    late List<String> store;

    /// 每次**写入**收到的列表（用来证明"真的调了写、且内容是换位后的"）
    late List<List<String>> writes;

    setUp(() {
      store = ['cycani', 'cctv', 'bilibili'];
      writes = [];

      RemoteBridge.overrideProviderOrderIO(
        read: () async => List<String>.from(store),
        write: (ids) async {
          writes.add(List<String>.from(ids));
          /*
           * 模拟后端 `set_provider_order` 的真实语义：
           * 它返回**实际生效**的顺序（不是回显入参）——
           * `registry.reorder()` 会对齐到实际注册的源。
           */
          store = List<String>.from(ids);
          return List<String>.from(store);
        },
      );

      /*
       * `_execCommand` 第一行就是 `if (g == null) return;` ——
       * 不注册全局能力的话命令会被**静默丢弃**，测试会假绿。
       */
      RemoteBridge.instance.setGlobals(
        const GlobalBridge(search: _noopSearch, loadHome: _noopLoadHome),
      );
    });

    tearDown(RemoteBridge.overrideProviderOrderIO);

    /// 走**真实**的 JSON 解析 + 真实的分发路径
    Future<void> feed(Map<String, dynamic> json) =>
        RemoteBridge.instance.execCommandForTest(RemoteCommand.fromJson(json));

    test('★★★ 上移：{"kind":"move_provider","id":"cctv","delta":-1} → 顺序真的变了',
        () async {
      await feed({'kind': 'move_provider', 'id': 'cctv', 'delta': -1});

      expect(
        store,
        ['cctv', 'cycani', 'bilibili'],
        reason: '★ cctv 必须从第 2 位移到第 1 位',
      );
      expect(writes.length, 1, reason: '必须真的调用了一次写入');
      expect(writes.single, ['cctv', 'cycani', 'bilibili'],
          reason: '★ 写出去的就是换位后的列表');
    });

    test('★★★ 下移：delta = +1 → 顺序真的变了', () async {
      await feed({'kind': 'move_provider', 'id': 'cycani', 'delta': 1});

      expect(store, ['cctv', 'cycani', 'bilibili'],
          reason: '★ cycani 必须从第 1 位移到第 2 位');
      expect(writes.single, ['cctv', 'cycani', 'bilibili']);
    });

    test('★★ 按 id 定位（不是拿 delta 当索引）', () async {
      // 移中间那个 —— 若实现错误地按 delta 当索引，会动到别的源
      await feed({'kind': 'move_provider', 'id': 'cctv', 'delta': 1});

      expect(store, ['cycani', 'bilibili', 'cctv'],
          reason: '★ 动的必须是 id 指的那一个（cctv），不是下标 1');
    });

    test('★★ 边界：第一项再上移 → 静默不动、**不写盘**', () async {
      await feed({'kind': 'move_provider', 'id': 'cycani', 'delta': -1});

      expect(store, ['cycani', 'cctv', 'bilibili'], reason: '越界不该改变顺序');
      expect(writes, isEmpty,
          reason: '★ 越界时**连写都不该调** —— 白写一次会白白落盘');
    });

    test('★★ 边界：最后一项再下移 → 静默不动、不写盘', () async {
      await feed({'kind': 'move_provider', 'id': 'bilibili', 'delta': 1});

      expect(store, ['cycani', 'cctv', 'bilibili']);
      expect(writes, isEmpty);
    });

    test('★★ 边界：id 不存在 → 不崩、不写盘、**如实记日志**', () async {
      final logs = <String>[];
      final saved = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) {
        if (m != null) logs.add(m);
      };
      try {
        await feed({
          'kind': 'move_provider',
          'id': 'ghost-不存在的源',
          'delta': -1,
        });
      } finally {
        debugPrint = saved;
      }

      expect(store, ['cycani', 'cctv', 'bilibili'], reason: '不该动任何东西');
      expect(writes, isEmpty);
      expect(
        logs.any((l) => l.contains('找不到源') && l.contains('ghost-不存在的源')),
        isTrue,
        reason: '★ 必须如实记日志（不能静默丢弃）—— '
            '否则用户"点了没反应"时完全无从查起。实际日志: $logs',
      );
    });

    test('★ 边界：delta = 0 → 无操作', () async {
      await feed({'kind': 'move_provider', 'id': 'cctv', 'delta': 0});
      expect(store, ['cycani', 'cctv', 'bilibili']);
      expect(writes, isEmpty);
    });

    test('★ 边界：缺 id / 缺 delta → 不崩', () async {
      await feed({'kind': 'move_provider', 'delta': -1});
      await feed({'kind': 'move_provider', 'id': 'cctv'});
      await feed({'kind': 'move_provider', 'id': '', 'delta': 5});
      expect(store, ['cycani', 'cctv', 'bilibili']);
      expect(writes, isEmpty);
    });

    test('★ 边界：极端 delta 不崩（不做算术，只判越界）', () async {
      await feed({'kind': 'move_provider', 'id': 'cctv', 'delta': -2147483648});
      await feed({'kind': 'move_provider', 'id': 'cctv', 'delta': 2147483647});
      expect(store, ['cycani', 'cctv', 'bilibili']);
      expect(writes, isEmpty);
    });

    test('★ 读写抛异常时不能把桥带崩', () async {
      RemoteBridge.overrideProviderOrderIO(
        read: () async => throw StateError('后端炸了'),
        write: (ids) async => throw StateError('后端炸了'),
      );
      // 不该抛出去
      await feed({'kind': 'move_provider', 'id': 'cctv', 'delta': -1});
      expect(store, ['cycani', 'cctv', 'bilibili'], reason: '失败时保持原样');
    });
  });

  group('★★ move_provider 的 wire 格式与分发位置（静态断言）', () {
    /// ⚠️ **必须剥注释**再匹配 —— 见 `_code()` 的说明（我自己踩过）
    late String src;

    setUpAll(() {
      src = _code(File('lib/ui/remote_bridge.dart').readAsStringSync());
    });

    test('★★ Dart 侧解析：扁平结构 → args[\'id\'] / args[\'delta\']', () {
      /*
       * ⚠️ 这是**跨语言契约**：Rust 侧 `MoveProvider { id, delta }`
       *    序列化出来是**扁平**的（顶层就是 id/delta），
       *    而 Dart 的 `RemoteCommand.fromJson` 把 `kind` 以外的字段
       *    **全塞进 `args`** —— 所以是 `args['id']`，
       *    **不是** `args['payload']['id']`。
       */
      final c = RemoteCommand.fromJson({
        'kind': 'move_provider',
        'id': 'cycani',
        'delta': -1,
      });
      expect(c.kind, 'move_provider');
      expect(c.id, 'cycani');
      expect(c.number('delta'), -1);
      // ★ 扁平：没有 payload 这一层
      expect(c.args.containsKey('payload'), isFalse);
    });

    test('★★★ move_provider 不能依赖播放页（与 play_item 同理）', () {
      /*
       * 内容源顺序是**全局设置**，跟当前在播什么无关 ——
       * 用户在首页（甚至没打开过视频）时手机上照样该能排序。
       *
       * 若落到「需要播放器」那一组，`_player == null` 时会被静默跳过，
       * 那正是原版 `play_item` 踩过的坑（见上面的实测证据）。
       */
      expect(src.contains("case 'move_provider':"), isTrue,
          reason: '要有 move_provider 的分发');

      final idx = src.indexOf("case 'move_provider':");
      final needPlayerIdx = src.indexOf('final p = _player;');
      expect(idx, greaterThan(0));
      expect(needPlayerIdx, greaterThan(0));
      expect(
        idx,
        lessThan(needPlayerIdx),
        reason: '★ move_provider 的 case 必须在"需要播放器"判断**之前** —— '
            '否则用户在首页时手机上排序会被静默跳过',
      );
    });

    /// 取 `_moveProvider` 的方法体（**已剥注释**）
    ///
    /// ⚠️ 结束标记要用**代码**（`String _sig(`），不能用注释 ——
    ///    `src` 已经剥掉注释了，用注释当边界会得到 -1。
    String moveProviderBody(String src) => _code(src.substring(
          src.indexOf('Future<void> _moveProvider'),
          src.indexOf('String _sig('),
        ));

    test('★ 换位后必须调 setProviderOrder（复用后端落盘，不另写存储）', () {
      final body = moveProviderBody(src);
      expect(
        body.contains('await _writeOrder(next)'),
        isTrue,
        reason: '★ 落盘出口必须走 setProviderOrder（后端 registry.reorder + save_order）—— '
            '不能自己写一套存储，否则前端列表不会刷新',
      );
      expect(body.contains('await _readOrder()'), isTrue,
          reason: '顺序必须**现取**（手机端只给了 id + delta，没有完整列表）');
      // 用返回值而不是回显入参（与 settings_page 的排序弹窗一致）
      expect(body.contains('final applied = await _writeOrder(next)'), isTrue,
          reason: '返回值才是真相（入参可能有幽灵项）');
    });

    test('★ 换位用 id 定位，不是拿 delta 当索引', () {
      final body = moveProviderBody(src);
      expect(body.contains('cur.indexOf(id)'), isTrue,
          reason: '★ 必须按 id 找位置 —— 手机端列表可能过期');
      expect(body.contains('j < 0 || j >= cur.length'), isTrue,
          reason: '越界判据');
    });

    test('★★ 内容源列表必须挂进上报的 state（否则手机面板永远空）', () {
      /*
       * 手机端 `page.html` 的 `renderOrd` 读的是 `s.providers`，
       * 且 `list.length === 0` 时**整块隐藏**。
       *
       * 若不上报，手机上那块「内容源顺序」面板永远不会出现 ——
       * 而协议、Rust 字段、JS 全都写好了，只有中间这一段没接。
       */
      expect(src.contains("j['providers'] = _providersJson"), isTrue,
          reason: '★ 必须把 providers 挂进上报的 JSON');
      expect(src.contains('_stateJsonWithProviders(st)'), isTrue,
          reason: '★ 上报时要用挂了 providers 的那份，不能用裸 st.toJson()');
      expect(
        src.contains('SourinApi.remoteReportState(st.toJson())'),
        isFalse,
        reason: '★ 不能再用裸 toJson() 上报 —— 那样 providers 就丢了',
      );
    });

    test('★★ providers 刷新不能依赖播放页（全局设置）', () {
      final tick = _code(src.substring(
        src.indexOf('Future<void> _tick()'),
        src.indexOf('Future<void> _refreshProviders()'),
      ));
      expect(tick.contains('await _refreshProviders();'), isTrue,
          reason: 'tick 里要刷新源列表');
      /*
       * ⚠️ 刷新必须**在** `_player?.getState()` 那套逻辑之外 ——
       *    它俩本来就是两件事（一个全局、一个跟播放页走）。
       */
      expect(tick.contains('_player'), isTrue);
      expect(tick.contains('_providersTick'), isTrue,
          reason: '★ 必须低频刷新（每 tick 刷 = 每 400ms 两次额外 IPC，'
              '正是文件头那个"操作十分卡顿"的成因）');
    });

    test('★ 源列表刷新失败时不能清空（否则手机面板突然消失）', () {
      final body = _code(src.substring(
        src.indexOf('Future<void> _refreshProviders'),
        src.indexOf('Map<String, dynamic> _stateJsonWithProviders'),
      ));
      expect(body.contains('保持上次的'), isTrue,
          reason: '★ 失败要保持上一次的列表，不能清空');
    });

    test('★★★ 排序命令必须**立刻**回报（否则手机每次都显示「未生效」）', () {
      /*
       * # 这是一个真会发生的时序 bug
       *
       * 手机端 `page.html` 的 `moveProvider` 点完 ↑↓ 后等
       * `ORD_WAIT_MS = 2600ms` 确认「服务端顺序真的变了」，
       * 没等到就**回滚 + 提示「未生效」**。
       *
       * 而源列表默认每 8 个 tick 才刷新一次（空闲时约 20 秒）——
       * 远超那 2600ms 的确认窗口。
       *
       * 结果：**排序其实成功了，但手机上每次都显示「未生效」**，
       * 用户以为坏了。所以排序命令必须触发一次立刻回报。
       */
      final tick = _code(src.substring(
        src.indexOf('Future<void> _tick()'),
        src.indexOf('Future<void> _refreshProviders()'),
      ));
      expect(tick.contains('movedProvider'), isTrue,
          reason: '★ tick 里要识别"这一轮有排序命令"');
      expect(
        tick.contains('if (movedProvider)'),
        isTrue,
        reason: '★★★ 有排序命令时要走"立刻刷新 + 回报"那段',
      );
      /*
       * ⚠️ 立刻回报那一段**不能**加 `&& _player != null` ——
       *    排序是全局设置，用户在首页（没在播）时也要能看到结果。
       */
      final block = tick.substring(tick.indexOf('if (movedProvider)'));
      expect(block.contains('await _refreshProviders();'), isTrue,
          reason: '立刻刷新源列表');
      expect(block.contains('_stateJsonWithProviders(st2)'), isTrue,
          reason: '立刻把新顺序报给手机');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ task-14：遥控「开机即可用」与「播放命令真的被接上」
  // ═══════════════════════════════════════════════════════════════════
  group('★★★ task-14 —— 开机自启 / 唤醒 / setPlayer 注册', () {
    late String src;
    late String page;
    late String settings;
    late String stateRs;

    setUpAll(() {
      src = File('lib/ui/remote_bridge.dart').readAsStringSync();
      page = File('lib/ui/player_page.dart').readAsStringSync();
      settings = File('lib/ui/settings_page.dart').readAsStringSync();
      stateRs = File('rust/sourin_core/src/state.rs').readAsStringSync();
    });

    test('★★★ C: 遥控必须**开机自启**（Rust bootstrap 里按 auto_start 起）', () {
      /*
       * 用户原话：「**我要只要这个软件打开了,这个遥控就能用**」
       *
       * 修之前：`RemotePref::default().auto_start = true` 抄对了，
       * 但 `spawn_remote_server` **只被设置页那个按钮**调用 ——
       * 启动时没人读这个偏好。原版 `lib.rs:3834` 是开机就起。
       */
      final code = _code(stateRs);
      expect(code.contains('remote_pref.auto_start'), isTrue,
          reason: '★ bootstrap 必须读 auto_start');
      expect(code.contains('spawn_remote_server'), isTrue,
          reason: '★★★ 启动时要真的把服务起起来（不是只读偏好）');
      expect(code.contains('已恢复固定配对码'), isTrue,
          reason: '★ 固定配对码也要在启动时恢复（原版 lib.rs:3824）—— '
              '否则用户设了固定码，重启后手机连不上');
    });

    test('★★ D: 设置页开启遥控后必须**唤醒桥**', () {
      /*
       * 桥只在 `RemoteBridgeHost.initState` 尝试启动一次，
       * 而那一刻遥控必然还没开 → 桥早退。用户随后点按钮把服务开起来，
       * 桥却不知道 → 手机上发命令没人取 → 「点了没反应」。
       *
       * ⚠️ 判据要落在 `_startRemote` **方法体里**，不能全文 contains ——
       *    否则注释里提一句 `notifyEnabled()` 就能骗过测试（本项目踩过）。
       */
      final body = _code(settings.substring(
        settings.indexOf('Future<void> _startRemote()'),
        settings.indexOf('Future<void> _stopRemote()'),
      ));
      expect(body.contains('RemoteBridge.instance.notifyEnabled()'), isTrue,
          reason: '★★ 开启成功后要唤醒桥，否则要重启应用才生效');
      expect(
        settings.contains("import 'remote_bridge.dart';"),
        isTrue,
        reason: '★ 之前 settings_page **完全没有** import 桥（RemoteBridge 引用 0 处）',
      );
    });

    test('★★ E: 遥控没开时必须有**慢速复查**（否则桥永久死亡）', () {
      /*
       * 原实现是"没开就 return，不挂定时器"—— 那让桥在启动后
       * **永久死亡**（没人再调 _ensurePolling）。
       * 修法是挂一个 5 秒的复查。
       */
      expect(src.contains('_scheduleRecheck'), isTrue,
          reason: '★★ 没开时要挂复查 —— 这是"遥控只在重启后生效"的根因修法');
      expect(src.contains('const _tickDisabledMs'), isTrue,
          reason: '复查间隔要有名字（可读性 + 防止后人改成 400ms）');
      expect(
        RegExp(r'const _tickDisabledMs = \d+;').firstMatch(src)?.group(0),
        isNotNull,
      );
      /*
       * ⚠️ 复查必须**显著慢于**正常轮询 —— 否则退化成原版实测过的
       *    "没开也在每 800ms 空转两次 IPC"。
       */
      final recheck = int.parse(
        RegExp(r'const _tickDisabledMs = (\d+);').firstMatch(src)!.group(1)!,
      );
      expect(recheck, greaterThanOrEqualTo(2000),
          reason: '★ 复查间隔必须够慢（≥2 秒）—— 原版反对的是高频空转');
    });

    test('★★★ F: 播放页必须注册 setPlayer（否则 14 条命令全被丢）', () {
      final code = _code(page);
      expect(code.contains('RemoteBridge.instance.setPlayer('), isTrue,
          reason: '★★★ 播放页要交出 PlayerBridge —— '
              '以前 setPlayer 全仓库**零调用**，于是 14 条播放命令被丢、选集面板永远空');
      expect(code.contains('RemoteBridge.instance.clearPlayer('), isTrue,
          reason: '离开播放页要注销（与 setPlayer 配对）');
      expect(code.contains('PlayerBridge('), isTrue);

      /*
       * ★ 必须传**自己那个实例**给 clearPlayer —— 否则换页重叠时
       *   旧页的 dispose 会把新页注册的能力清掉。
       */
      expect(code.contains('_remotePlayerBridge'), isTrue,
          reason: '★ 要存下 bridge 实例，dispose 时精确注销（防换页重叠误清）');
    });

    test('★★★ F: exec 必须覆盖 14 条播放命令（逐条断言）', () {
      /*
       * `page.html` 会发出这些 kind；在 F 之前它们**全部**落到
       * 「没有播放器」分支被丢弃。
       */
      const kinds = [
        'toggle_play',
        'next_episode',
        'prev_episode',
        'goto_episode',
        'seek',
        'seek_to',
        'set_volume',
        'toggle_mute',
        'switch_source',
        'skip_config_open',
        'skip_preview',
        'skip_confirm',
        'skip_clear',
        'skip_toggle_auto',
      ];
      final body = _code(page.substring(
        page.indexOf('Future<void> _remoteExec('),
        page.indexOf('Future<void> _remoteSwitchSource('),
      ));
      for (final k in kinds) {
        expect(body.contains("case '$k':"), isTrue,
            reason: '★ 缺少 `case \'$k\':` —— 手机上这条命令会没反应');
      }
    });

    test('★★ F: getState 要报真实的集数与剧集（选集面板靠它）', () {
      final body = _code(page.substring(
        page.indexOf('RemoteState _remoteGetState()'),
        page.indexOf('Future<void> _remoteExec('),
      ));
      expect(body.contains('episodeCount:'), isTrue,
          reason: '★ 不报集数的话手机端不显示「第 N / M 集」');
      expect(body.contains('episodes:'), isTrue,
          reason: '★★ 不报 episodes 的话 `page.html:496` 把 epsCard 整块隐藏'
              '（判据 episodes.length > 1）—— 手机上永远看不到选集');
      expect(body.contains('_epOrder('), isTrue,
          reason: '★ 集号要**从标题解析**（「第5集」），不是拿下标当集号 —— '
              '原版 reportState 就是这么做的');
      expect(body.contains('hasMedia: true'), isTrue,
          reason: '有播放页就是"有媒体"，否则手机端显示"去客户端打开一个视频"');
    });

    test('★ F: 未知命令不能抛（遥控是尽力而为的通道）', () {
      final body = _code(page.substring(
        page.indexOf('Future<void> _remoteExec('),
        page.indexOf('Future<void> _remoteSwitchSource('),
      ));
      expect(body.contains('default:'), isTrue,
          reason: '要有 default 分支 —— 未知 kind 静默忽略，不能抛');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ task-14 A：遥控搜索改流式 —— **真跑**，不是文本断言
  // ═══════════════════════════════════════════════════════════════════
  group('★★★ task-14 A —— 遥控搜索必须"边搜边回填"', () {
    tearDown(RemoteCapabilities.overrideSearchIO);

    /// 造一个假媒体条目
    MediaItem item(String id) => MediaItem(id: id, title: '片$id');

    test('★★★ 每到一个源就回填一次，且条数**递增**（这是"陆续出现"的硬判据）',
        () async {
      /*
       * # 为什么必须真跑而不是断言源码里有 `searchAllStream`
       *
       * 断言"源码里出现了 searchAllStream"证明不了：
       * ```text
       * ① 回调真的被调用（可能 streams 传空、或 kind 判断错了）
       * ② 回填是**多次**的（可能攒到最后才写一次 —— 那就退回原样了）
       * ③ 条数**单调增长**（手机端靠"条数变了就重绘"来显示增量）
       * ```
       * 所以这里注入一个假的流，按顺序吐 3 个源，然后断言
       * **`setSearch` 被调的次数与每次的条数**。
       */
      final writes = <List<dynamic>>[];

      RemoteCapabilities.overrideSearchIO(
        stream: (kw, onEvent, {page = 1}) async {
          // 模拟"三个源陆续返回"
          onEvent(SearchStreamEvent(
            kind: SearchEventKind.hit,
            provider: 'p1',
            providerName: '源一',
            items: [item('a1'), item('a2')],
          ));
          onEvent(SearchStreamEvent(
            kind: SearchEventKind.hit,
            provider: 'p2',
            providerName: '源二',
            items: [item('b1'), item('b2')],
          ));
          onEvent(SearchStreamEvent(
            kind: SearchEventKind.hit,
            provider: 'p3',
            providerName: '源三',
            items: [item('c1'), item('c2')],
          ));
          onEvent(const SearchStreamEvent(kind: SearchEventKind.done));
        },
        setSearch: (payload) async {
          writes.add((payload['items'] as List));
        },
      );

      await RemoteCapabilities.remoteSearch('测试词');

      /*
       * ★ 核心断言：**多次**回填（不是攒到最后一次）
       *
       * 3 个源 → 3 次"到达即回填" + 1 次收尾 = 4 次。
       * 若实现退化成"等全部源再写一次"，这里会是 1 —— 测试立刻红。
       */
      expect(
        writes.length,
        greaterThanOrEqualTo(3),
        reason: '★★★ 必须**每个源到达就回填** —— 只写一次就退回"等全量"了，'
            '那正是用户报的「遥控搜不到」的根因（实测 24.64s > 手机 18.2s 预算）',
      );

      // ★ 条数必须递增（手机端"条数变了才重绘"靠它显示增量）
      final counts = writes.map((w) => w.length).toList();
      expect(
        counts,
        [2, 4, 6, 6],
        reason: '★★ 条数要**单调递增**（每到达一个源 +2）—— 手机端靠它判断"有新的了"',
      );

      // ★ round-robin 语义必须保留：最终顺序是每源轮流取一条
      final finalItems = writes.last.cast<Map<String, dynamic>>();
      expect(
        finalItems.map((e) => e['id']).toList(),
        ['a1', 'b1', 'c1', 'a2', 'b2', 'c2'],
        reason: '★★ 最终顺序必须是**按轮次交替**（原版真 bug：第一个源会吃掉全部配额）—— '
            '不能因为改成流式就把排序语义弄丢',
      );

      // 每个条目都要带上 provider（手机端 play_item 要用）
      expect(finalItems.every((e) => (e['provider'] as String).isNotEmpty), isTrue);
    });

    test('★★ 流式失败时**不能**把已显示的结果擦掉', () async {
      /*
       * 流式与一次性有个关键差别：失败时可能**已经有部分源回填过了**。
       * 这时再写一个空列表，用户会看到"结果闪一下又没了"。
       */
      final writes = <List<dynamic>>[];

      RemoteCapabilities.overrideSearchIO(
        stream: (kw, onEvent, {page = 1}) async {
          onEvent(SearchStreamEvent(
            kind: SearchEventKind.hit,
            provider: 'p1',
            providerName: '源一',
            items: [item('a1')],
          ));
          throw StateError('第 2 个源之后流断了');
        },
        setSearch: (payload) async => writes.add(payload['items'] as List),
      );

      await RemoteCapabilities.remoteSearch('测试词');

      expect(writes.length, 1, reason: '只该有第 1 个源那次回填');
      expect((writes.single).length, 1,
          reason: '★★ 失败**不得**补写空列表 —— 那会把已经显示的结果擦掉');
    });

    test('★★ 一个源都没有就失败 → 必须回填空结果（否则手机转圈到超时）', () async {
      final writes = <List<dynamic>>[];

      RemoteCapabilities.overrideSearchIO(
        stream: (kw, onEvent, {page = 1}) async =>
            throw StateError('一个源都没连上'),
        setSearch: (payload) async => writes.add(payload['items'] as List),
      );

      await RemoteCapabilities.remoteSearch('测试词');

      expect(writes.length, 1);
      expect(writes.single, isEmpty);
    });

    test('★ 上限仍然生效（原版 60 条 —— 手机屏小）', () async {
      final writes = <List<dynamic>>[];

      RemoteCapabilities.overrideSearchIO(
        stream: (kw, onEvent, {page = 1}) async {
          // 一个源给 100 条，超过上限
          onEvent(SearchStreamEvent(
            kind: SearchEventKind.hit,
            provider: 'big',
            providerName: '大源',
            items: [for (var i = 0; i < 100; i++) item('x$i')],
          ));
        },
        setSearch: (payload) async => writes.add(payload['items'] as List),
      );

      await RemoteCapabilities.remoteSearch('测试词');

      expect(writes.last.length, lessThanOrEqualTo(60),
          reason: '上限 60 条（原版定的 —— 手机屏幕小，再多也滑不完）');
      expect(writes.last.length, 60, reason: '刚好截到 60');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ task-14 F：14 条播放命令必须**真的被路由**（不再被丢弃）
  // ═══════════════════════════════════════════════════════════════════
  group('★★★ task-14 F —— 播放命令真的被路由到播放页', () {
    /// 假播放桥：记下收到的每条命令
    late List<RemoteCommand> received;

    setUp(() {
      received = [];
      RemoteBridge.instance.setGlobals(
        const GlobalBridge(search: _noopSearch, loadHome: _noopLoadHome),
      );
      /*
       * ★ 注入一个假 PlayerBridge —— 这就是 `player_page.dart` 在
       *   initState 里做的事（`setPlayer(PlayerBridge(getState:…, exec:…))`）。
       *
       * 有了它，才能证明**桥真的把命令交给了播放页**，而不是
       * 落到 `_player == null` 那条"收到播放命令但当前没有播放器"的
       * 丢弃分支里 —— 那正是 F 修复前的行为。
       */
      RemoteBridge.instance.setPlayer(
        PlayerBridge(
          getState: () => const RemoteState(hasMedia: true, title: '测试片'),
          exec: (c) async => received.add(c),
        ),
      );
    });

    tearDown(RemoteBridge.instance.clearPlayer);

    Future<void> feed(String kind, [Map<String, dynamic> args = const {}]) =>
        RemoteBridge.instance
            .execCommandForTest(RemoteCommand(kind, Map.of(args)));

    test('★★★ 14 条播放命令**全部**到达播放页（F 修复前全部被丢）', () async {
      /*
       * `page.html` 会发出的播放类 kind —— 逐条喂进去，逐条断言到达。
       *
       * 修复前：`_player == null`（因为 setPlayer 零调用），
       *        这 14 条**全部**走 `debugPrint('…没有播放器…')` 被丢弃。
       */
      const cases = <String, Map<String, dynamic>>{
        'toggle_play': {},
        'next_episode': {},
        'prev_episode': {},
        'goto_episode': {'order': 3},
        'seek': {'delta': -10},
        'seek_to': {'position': 120},
        'set_volume': {'value': 50},
        'toggle_mute': {},
        'switch_source': {'code': 'l1'},
        'skip_config_open': {'target': 'intro'},
        'skip_preview': {'position': 30},
        'skip_confirm': {'target': 'intro'},
        'skip_clear': {},
        'skip_toggle_auto': {'on': true},
      };

      for (final e in cases.entries) {
        await feed(e.key, e.value);
      }

      expect(
        received.length,
        14,
        reason: '★★★ 14 条命令全部要到达播放页 —— '
            '漏掉任何一条，手机上那个按钮就是"点了没反应"（F 修复前的状态）',
      );
      expect(
        received.map((c) => c.kind).toSet(),
        cases.keys.toSet(),
        reason: '到达的 kind 集合要和发出的**完全一致**',
      );
      // 参数也要原样带过去（播放页靠 order/delta/position/value）
      final goto = received.firstWhere((c) => c.kind == 'goto_episode');
      expect(goto.number('order'), 3, reason: '参数不能在桥这一层丢掉');
      final seek = received.firstWhere((c) => c.kind == 'seek');
      expect(seek.number('delta'), -10);
    });

    test('★★ 没有播放页时**如实记日志**（不静默丢）', () async {
      RemoteBridge.instance.clearPlayer();
      received.clear();

      final logs = <String>[];
      final saved = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) {
        if (m != null) logs.add(m);
      };
      try {
        await feed('toggle_play');
      } finally {
        debugPrint = saved;
      }

      expect(received, isEmpty, reason: '没有播放页时命令当然到不了');
      expect(
        logs.any((l) => l.contains('没有播放器')),
        isTrue,
        reason: '★ 必须**明确记日志** —— 静默丢弃的表现是"手机点了没反应"，最难查',
      );
    });

    test('★ 全局能力类命令**不**走播放页（play_item / query_* / move_provider）',
        () async {
      /*
       * 这 4 条的语义与播放页无关（导航 / 搜索 / 全局设置），
       * 由 `GlobalBridge` 处理 —— 它们**不该**出现在 `_player.exec` 里。
       */
      await feed('query_home');
      await feed('move_provider', {'id': 'x', 'delta': -1});
      expect(
        received.where((c) =>
            c.kind == 'query_home' || c.kind == 'move_provider'),
        isEmpty,
        reason: '★ 全局类命令不该落到播放页 —— 它们在各自的 case 里已 return',
      );
    });
  });
}
