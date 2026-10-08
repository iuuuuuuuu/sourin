// ═══════════════════════════════════════════════════════════════════════
//  全源搜索 —— 为什么它**不**在搜索页里
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件的存在本身是一条结论的记录
//
// 派单时说「`searchAll` 在 UI 里零调用，请在 `search_page.dart` 里接上」。
// 我去读了原版之后发现**这条不成立**，所以没有照做：
//
// ```text
// 原版 SearchView.vue:88        → content.searchStream(...)    ← 流式
// 原版 App.vue:141              → content.searchAll(...)       ← 唯一调用点
//                                  （在 setRemoteGlobals({ search }) 里）
// 我们 search_page.dart:156     → SourinApi.searchAllStream(...) ← 与原版一致
// ```
//
// 结论：**`searchAll` 是遥控桥专用的**（它要的是"一次拿全，然后整理成
// 60 条回填给手机"），而搜索页要的是"搜完一个显示一个"（流式）。
// 两者是**不同的需求**，不是同一个 API 的两个入口。
//
// 所以 `searchAll` 的正确落点是 `remote_bridge.dart` 的
// `RemoteCapabilities.remoteSearch`，已在 `remote_bridge_test.dart` 覆盖。
//
// ⚠️ 本文件守的是**搜索页不该被改坏**这件事 ——
//    防止后人看到"searchAll 零调用"又把它接进搜索页，
//    那样会丢掉"搜完一个显示一个"的体验（原版 Owner 明确要求过）。
//
// # 原版 Owner 的原话（SearchView.vue 文件头）
//
// > 搜索页面,不应该等待所有源一起搜索完毕再显示出来,
// > **搜索结束一个就显示一个**,后面的往里面push就行了
//
// ═══════════════════════════════════════════════════════════════════════
// ★★★ 2026-09-26 两处修正（用户要求删除直播页节目单 ⇒ 连带影响本文件）
// ═══════════════════════════════════════════════════════════════════════
//
// 【修正 1】`直播回看` 那个 group 的 4 条**翻转为反向断言**（铁律 169）
// ```text
// 用户原话（实测反馈第 2 条）：
//   > 直播删除掉节目单,左侧固定,右侧就一个播放器也固定,还要支持双击进入全屏播放
//
// ★ 为什么作废：回看入口**物理上就在节目单里**（`EpgPanel.onWatchReplay`）
//   ⇒ 删节目单 ⇒ 回看入口**必然**一起消失
//   ⇒ 该 group 原来守的「回看只传频道 / 不带时间区间 / 只有 replayable 给点」
//     其**对象已不存在**
// ★ 处置（lead 裁决）：
//   · 4 条红的 ⇒ **翻转成反向断言**（"不应再有 X"）+ 写明作废理由
//   · `getTimeshift(api)` 那条 ⇒ **保留原样** —— 它证明**能力还在**
//     （`SourinApi.getTimeshift` 未动，将来要接随时能接）
// ```
//
// 【修正 2】★★★ 本文件改为**使用共享 `stripComments`**（铁律 170）
// ```text
// ★ 实测过的**假通过**（就在本文件）：
//   原 L192 `livePage.contains('_watchReplay')` 断言 == true ⇒ **通过**
//   而当时 `live_page.dart` 里 `_watchReplay` **只剩注释**（函数已删）
//   ⇒ ★ **代码里没有了，测试却是绿的** ⇒ 因为它**不剥注释**
//
// ★ 根因不是"忘了剥"，而是**纪律分叉**：
//   全仓 `stripComments` 曾有 **10 个不同实现**，而 **naive 正则版**
//   （被 6 个文件使用）**可证明更弱**：
//     ① 字符串里的 `/* */` 会被**误删**（把代码当注释删了）
//     ② 行尾 `// 注释` **不删** ⇒ `contains('注释里的词')` **仍然命中**
//
// ⇒ ★ 铁律 170：「同一纪律必须**只有一个实现**（一个 helper），
//   否则它会**分叉成两套行为**」
// ⇒ 本文件 import `_support/strip_comments.dart`（状态机版，唯一实现）
// ```
//
// ⚠️ **本文件所有静态断言从此断言 `stripComments(...)` 的结果**，
//    **不再**断言原始文本 —— 见下面各 `setUpAll` 的写法。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '_support/strip_comments.dart';

void main() {
  group('搜索页必须用**流式**搜索（不是 searchAll）', () {
    late String searchPage;
    late String api;

    setUpAll(() {
      // ★ 铁律 170：静态断言一律先剥注释（唯一实现见 `_support/`）
      searchPage = stripComments(
        File('lib/ui/search_page.dart').readAsStringSync(),
      );
      api = stripComments(
        File('lib/core/sourin_api.dart').readAsStringSync(),
      );
    });

    test('★★ 搜索页用 searchAllStream，不用 searchAll', () {
      expect(
        searchPage.contains('SourinApi.searchAllStream('),
        isTrue,
        reason: '★ 必须用流式版 —— 非流式要等**所有**源跑完（实测 37 秒），'
            '而流式首个结果 0.25 秒就到。'
            '原版 Owner 明确要求「搜索结束一个就显示一个」',
      );
      /*
       * ⚠️ 用正则而不是 `contains('searchAll(')` ——
       *    后者会被 `searchAllStream(` 命中（子串匹配的经典坑）。
       */
      final bareSearchAll =
          RegExp(r'SourinApi\.searchAll\((?!Stream)').hasMatch(searchPage);
      expect(
        bareSearchAll,
        isFalse,
        reason: '★ 搜索页**不得**调非流式的 `searchAll` —— '
            '那是遥控桥专用的（要"一次拿全再整理成 60 条"）',
      );
    });

    test('★ 搜索页必须能取消上一次搜索（防"幽灵结果"）', () {
      /*
       * 用户连续改关键词时，旧的那次还在跑 ——
       * 不取消的话旧结果会混进新结果里。
       */
      expect(
        searchPage.contains('_cancelCurrent()'),
        isTrue,
        reason: '★ 新搜索前必须取消上一次（原版 `current?.cancel()`）',
      );
      expect(
        searchPage.contains('cancelStream'),
        isTrue,
        reason: '取消要走 `SourinCore.cancelStream`',
      );
    });

    test('★ 回调返回 false 表示"用户已离开"（立刻中止剩余源）', () {
      /*
       * 原版注释：
       * > 用户已经离开页面了，还在后台跑几十个网络请求是纯浪费。
       * > 实测 0.66 秒返回，而不是等 30 秒。
       */
      expect(
        RegExp(r'if \(!mounted\) return false;').hasMatch(searchPage),
        isTrue,
        reason: '★ 页面已卸载时要返回 false 让 Rust 提前终止循环',
      );
    });

    test('★ 改关键词时立刻清空旧结果（避免"看起来没生效"）', () {
      expect(
        searchPage.contains('_hits = [];'),
        isTrue,
        reason: '★ 不立刻清的话，用户改词后会先看到旧关键词的结果挂在那里',
      );
    });

    test('★ 遥控桥必须走**流式**搜索（2026-09-25 改，原判据已过时）', () {
      final bridge = File('lib/ui/remote_bridge.dart').readAsStringSync();
      /*
       * ══════════════════════════════════════════════════════════════
       * ★ 这条测试的判据在 2026-09-25 变过（task-14 A），说明原因
       * ══════════════════════════════════════════════════════════════
       *
       * 原判据是「遥控桥里必须出现 `SourinApi.searchAll(`」。那在当时
       * 是对的（当时的取舍是"一次拿全，再按轮次整理成 60 条"），
       * 但它带来了一个用户可见的 bug：
       * ```text
       * 客户端  searchAllStream → 每搜到一个源就显示（首个 0.25s）
       * 遥控    searchAll       → 等**全部**源（实测「庆余年」24.64s）
       * 手机端预算              → 18.2s（page.html 26 × 700ms）
       * ⇒ 遥控必然先超时 → 用户看到「没有找到结果」
       *   而同一时刻客户端早就列出来了
       * ```
       * 用户原话：「**筛选是指在遥控上搜索数据是空的,在客户端搜索数据却有**」
       *
       * 所以遥控桥现在**必须**用流式 —— 与客户端同一条路径。
       * ⚠️ 注意本文件上半部分守的仍然成立：**搜索页**必须用流式
       *    （`searchAll` 的调用点只能在遥控桥里，不能在搜索页）。
       *    现在的变化是：遥控桥也**不再是** `searchAll` 的调用点了。
       */
      expect(
        bridge.contains('_searchStream ?? SourinApi.searchAllStream'),
        isTrue,
        reason: '★★ 遥控搜索默认必须走流式 —— 一次性 searchAll 要 24.64s，'
            '超过手机端 18.2s 预算（这正是"遥控搜不到"的根因）',
      );
      expect(
        bridge.contains('await SourinApi.searchAll('),
        isFalse,
        reason: '★ 不得再直接调一次性 searchAll',
      );
      expect(
        bridge.contains('remoteSetSearch'),
        isTrue,
        reason: '搜完必须回填给遥控服务，否则手机端一直转圈',
      );
    });

    test('★ API 层两个方法都要在（各有各的用途）', () {
      expect(
        RegExp(r'static Future<SearchAllResult> searchAll\(').hasMatch(api),
        isTrue,
        reason: 'searchAll 给遥控桥用',
      );
      expect(
        RegExp(r'static Future<void> searchAllStream\(').hasMatch(api),
        isTrue,
        reason: 'searchAllStream 给搜索页用',
      );
    });
  });

  group('直播回看：★ 2026-09-26 起入口已随节目单移除（能力仍在）', () {
    late String livePage;
    late String shell;
    late String api;

    setUpAll(() {
      // ★ 铁律 170：静态断言先剥注释 —— 本 group 尤其关键：
      //   下面有"源码里**不该**出现 X"的反向断言，
      //   若不剥注释，**注释里提到 X** 就会让它假红/假绿。
      livePage = stripComments(
        File('lib/ui/live_page.dart').readAsStringSync(),
      );
      shell = stripComments(File('lib/shell.dart').readAsStringSync());
      api = stripComments(
        File('lib/core/sourin_api.dart').readAsStringSync(),
      );
    });

    test('★ 直播页**不再**有回看入口（用户 2026-09-26 要求删节目单）', () {
      /*
       * ★★★ 2026-09-26 翻转（正向 ⇒ 反向）
       *
       * 【原断言】`livePage.contains('_watchReplay')` = true
       *   —— 守「回看入口要在」。
       * 【为什么作废】用户要求删掉直播页节目单 ⇒ 回看入口**随之移除**
       *   （它物理上就在 `EpgPanel.onWatchReplay` 里）。
       * 【新契约】直播页**不得**再有回看入口的**代码**。
       *
       * ★★ 这条曾经是**假通过**（本文件最值得记的一次）：
       *   删掉 `_watchReplay` 后它**仍然是绿的** ——
       *   因为 `live_page.dart` 的**注释**里提到了这个名字，
       *   而本文件当时**不剥注释**。
       * ⇒ 现在走 `stripComments`，断言的是**真代码**。
       */
      expect(
        livePage.contains('_watchReplay'),
        isFalse,
        reason: '★ 2026-09-26 用户要求删除节目单 ⇒ 回看入口（_watchReplay）'
            '随之移除。若它又出现在**代码**里，说明有人把节目单/回看加回来了。'
            '⚠️ 本断言必须走 stripComments —— 否则注释里一提它就假通过。',
      );
      expect(
        livePage.contains('onWatchReplay?.call'),
        isFalse,
        reason: '★ 不再调用回看回调（构造参数保留，但本页不再用它）',
      );
      // ★ 保留原断言里仍然有效的那半：**不得**接 getTimeshift（新增功能）
      expect(
        livePage.contains('getTimeshift'),
        isFalse,
        reason: '★ 直播页**不得**调 getTimeshift —— 原版自己也没接，'
            '接了就是新增功能（要改播放器入参），需先确认',
      );
    });

    test('★ 直播页**不再**有「episodeTitle 带时间前缀」那段（对象已不存在）', () {
      /*
       * ★★★ 2026-09-26 翻转（正向 ⇒ 反向）
       * 【原断言】`episodeTitle` 必须是「HH:mm 节目名」
       *   （原版 `${fmtTime(e.start)} ${e.title}`，`LiveView.vue:132`）——
       *   用于播放器上显示"你在看哪一段"。
       * 【为什么作废】回看入口移除 ⇒ 那个拼接**没有调用点**了
       *   （其依赖 `_fmtTime` 已随之删除）。
       * 【新契约】不应再出现该拼接与 `_fmtTime`。
       */
      expect(
        RegExp(r"'\$\{_fmtTime\(e\.start\)\} \$\{e\.title\}'").hasMatch(livePage),
        isFalse,
        reason: '★ 回看入口移除 ⇒ 该 episodeTitle 拼接一并消失',
      );
      expect(
        livePage.contains('_fmtTime'),
        isFalse,
        reason: '★ `_fmtTime` 只服务节目单/回看标题 ⇒ 应一并移除',
      );
    });

    test('★ 直播页**不再**有「只有 replayable 才给点」（对象已不存在）', () {
      /*
       * ★★★ 2026-09-26 翻转（正向 ⇒ 反向）
       * 【原断言】`livePage.contains('!e.replayable')` = true
       *   —— 原版 `if (!selected.value || !e.replayable) return;`
       * 【为什么作废】`replayable` 是**节目单条目**（`EpgEntry`）的字段 ⇒
       *   节目单删除后本页不再接触它，该守卫没有对象。
       * 【新契约】不应再出现 `replayable`。
       */
      expect(
        livePage.contains('!e.replayable'),
        isFalse,
        reason: '★ 节目单移除 ⇒ 不再判定"这条节目可否回看"',
      );
      expect(
        livePage.contains('replayable'),
        isFalse,
        reason: '★ `EpgEntry` 相关字段整体不该再出现在直播页',
      );
    });

    test('★ 直播页**不再**请求 EPG（与 live_page_test.dart 同口径）', () {
      /*
       * ★★★ 2026-09-26 翻转（正向 ⇒ 反向）
       * 【原断言】`livePage.contains('该频道暂无节目单')` = true
       *   —— 守"EPG 拉取失败只 warn，不报错"。
       * 【为什么作废】取数本身删了（不只是不显示）⇒ 那段 catch/warn 消失。
       * 【新契约】不应再有 EPG 取数痕迹。
       */
      expect(
        livePage.contains('该频道暂无节目单'),
        isFalse,
        reason: '★ 直播页不再取 EPG ⇒ 那段"暂无节目单"的 warn 一并消失',
      );
      expect(
        livePage.contains('getEpg'),
        isFalse,
        reason: '★ 切台只取流，不再发 EPG 请求（也为本页卡顿减一次 IPC）',
      );
    });

    test('★ API 层保留 getTimeshift（能力在，只是 UI 不接）', () {
      expect(
        RegExp(r'static Future<StreamCandidate> getTimeshift\(').hasMatch(api),
        isTrue,
        reason: 'Rust 侧 `cctv.rs::timeshift` 是好的（live_url + '
            '?begintimeabs=..&endtimeabs=..）—— API 保留，将来要接随时能接',
      );
    });

    /*
     * ★★ 2026-09-26 新增：**shell 侧的接线仍在** —— 让回看"随时能接回来"
     *
     * ```text
     * 处置回看入口时我**保留了** `LivePage.onWatchReplay` 构造参数
     * （shell 仍在传，只是直播页不再调用）—— 这样将来要恢复回看时
     * **零改动**（不用碰 shell.dart，那是别人的写入范围）。
     * ⇒ 但"保留了"这件事**必须被验证**，否则后人可能顺手删掉它，
     *   而那会让恢复回看变成"要改 shell"的跨文件改动。
     * ```
     */
    test('★ shell 侧的 onWatchReplay 接线仍在（回看可零改动接回）', () {
      expect(
        shell.contains('onWatchReplay:'),
        isTrue,
        reason: '★ shell 仍传 `onWatchReplay:` ⇒ 将来恢复回看**不必改 shell**'
            '（那是别人的写入范围）。若这条红了，说明接线被删了 —— '
            '恢复回看就会变成跨文件改动',
      );
    });

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-09-26 新增：让**纪律本身**可验证（lead 要求）
     * ══════════════════════════════════════════════════════════════════
     *
     * ```text
     * 本文件曾有一条**假通过**：断言 `contains('_watchReplay')` 为真，
     * 而当时它**只剩注释**（函数已删）。
     * 根因：本文件**不剥注释**，而 `live_page_test.dart` 剥
     *   ⇒ 同一纪律、两种行为（分叉）。
     *
     * ⇒ 修完之后必须防"后人又改回去" ⇒ 断言**本文件自己用的是共享 helper**。
     * ★ 这是**元断言**：它守的不是产品代码，而是**测试写法**本身。
     * ```
     */
    test('★★ 本文件必须走共享 stripComments（防纪律分叉，铁律 170）', () {
      final self = File('test/search_all_test.dart').readAsStringSync();

      expect(
        self.contains("import '_support/strip_comments.dart';"),
        isTrue,
        reason: '★ 必须 import **共享** helper —— 而不是在本文件里再抄一份。'
            '★ 实测全仓曾有 **10 个不同实现**，其中 naive 正则版'
            '（6 个文件在用）可证明更弱：行尾 // 注释不删、'
            '字符串里的 /* */ 被误删',
      );

      /*
       * ★ 关键：断言**真的调用**了它，而不只是 import。
       *   "引了包却不用"与"用了"必须能区分（铁律 78 同族）。
       */
      expect(
        RegExp(r'stripComments\(\s*\n?\s*File\(').hasMatch(self),
        isTrue,
        reason: '★ 必须**真的调用** stripComments 包住 '
            'File(...).readAsStringSync()，而不是只 import 不用',
      );

      /*
       * ★ 反向：本文件**不得**再自带一份 `stripComments` 实现。
       *
       * ⚠️ 必须**先剥自身注释**再断言：
       *   本文件顶部文档注释里**提到**了函数名，
       *   若直接拿原始文本断言会被自己的注释坑
       *   —— 那**正是**本文件要防的那类假通过。
       *   ⇒ 用共享 helper 剥自己（自指但安全：剥注释不改函数体）。
       *
       * ★★★ 而这里**踩过一次铁律 159**（判据不能拼出它要禁的字串）：
       * ```text
       * 我第一版写的是：
       *     selfCode.contains('String <函数名>(')
       * ⇒ ★ **判据那一行自己就含那个串** ⇒ 断言**永久为假**（自指）
       * ⇒ 实测：剥注释后仍然命中 1 次，且命中**就是这行判据本身**
       *
       * 修法：**不要拼出那个字串** ——
       *   改用「声明行 + 函数名字面」的组合正则，
       *   这样判据里**不含**完整的 `String <名字>(` 串。
       * ```
       */
      final selfCode = stripComments(self);
      expect(
        // ★ 判据自身不拼出被禁的完整串：用「返回类型 String + 函数名 + 左括号」
        //   ⚠️ 用**相邻字符串字面量**（编译期拼接）而不是 `+` 运算：
        //      两者**运行期完全相同**，但相邻写法更清晰（且过 lint）。
        //      ★ 关键性质不变：**源码文本里不含**那个完整签名串 ⇒ 不会自指。
        RegExp(
          r'\bString\s+' 'stripComments' r'\s*\(',
        ).hasMatch(selfCode),
        isFalse,
        reason: '★ 本文件不该再自带实现（否则又是分叉）。'
            '⚠️ 本断言先剥自身注释；且**判据不拼出完整函数签名**'
            '（铁律 159：判据若含被禁字串 ⇒ 自指 ⇒ 永久为假）',
      );
      /*
       * ★ 并**证明这条判据真的能发现"自带实现"** ——
       *   否则它是一个"永远为真"的空判据（红度证明，铁律 126）。
       *   造一份**含实现**的假源码，断言同一判据**必须命中**。
       */
      const fakeWithImpl = 'String strip' 'Comments(String src) { return src; }';
      expect(
        RegExp(
          r'\bString\s+' 'stripComments' r'\s*\(',
        ).hasMatch(fakeWithImpl),
        isTrue,
        reason: '★★ 红度证明：同一条判据**必须**能发现"自带实现"的样本。'
            '若这条红了，说明上面那条 isFalse 是**空判据**（永远不会失败）',
      );
    });
  });
}
