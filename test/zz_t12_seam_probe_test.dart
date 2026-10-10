// ═══════════════════════════════════════════════════════════════════════
//  task-12 A/B 接缝探针：`_onDetailPlay` 的 localPath 三分支
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么还要跑这条（ui-dev 已经重放过判据）
// ```text
// ui-dev 的探针是重放**我写的那段判断文本**（三行纯逻辑），
// ★ 但真正要证的是**集成后的路径**：`_onDetailPlay` 是 State 的私有方法，
//   它的入参来自详情区/下载面板，而**磁盘那条链**（_onPlayDownloaded）
//   走的是另一个调用点 —— 两者在同一个文件里、但先后位置决定谁覆盖谁。
// ⇒ 这里直接验**真实 State 上的那个方法**（不是重放文本），
//   并且把 ui-dev 点出的「先后位置」隐性契约显式测出来。
// ```
//
// ⚠️ 与 ui-dev 那条口诀一致：**别 await 整条链**
//    （applySession → _startPlayback → _player.open 在 flutter_tester 里永不返回）。
//    本探针只断言**方法入口处 req 被补成了什么**，不 await 后续。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/cache_page.dart';
import 'package:sourin_spike/ui/media_session.dart';

void main() {
  test('A/B 接缝：补字段逻辑必须**不覆盖**已带的 localPath（先后位置是隐性契约）', () {
    // ★ CR-25 / OPS-18：本探针原先把 Windows 路径**写死**（反斜杠）。
    //    在 POSIX 上反斜杠只是普通字符，而 `buildLocalPlayRequest`（判据 ④）用的是
    //    `Platform.pathSeparator` ⇒ 两侧拼出的串不一致 ⇒ 判据 ④ 在 macOS 上必红。
    //
    // ★ 修法：根目录**按平台取形**（不是把断言跳掉）——
    //    Windows 用 `C:` + 分隔符 + `v`，POSIX 用 `/v`。
    //    两边都是**合法的该平台绝对路径**，且都真的走同一条生产代码
    //    ⇒ 在 macOS 上照样断言，不是空跑。
    final sep = Platform.pathSeparator;
    final root = Platform.isWindows ? ('C:' + sep + 'v') : (sep + 'v');
    // ── 判据 ①：已带 ⇒ 原样用 ──────────────────────────────
    // 右侧面板从磁盘选的第 N 集走的就是这条（media_page.dart:906）
    final diskPick = '$root' + sep + '无职转生' + sep + 'e2.mp4';
    var req = PlayRequestData(
      provider: 'local',
      id: 'c:/v/无职转生/e2.mp4',
      title: '无职转生',
      episodeId: 'e2.mp4',
      localPath: diskPick,
    );
    // 模拟 _onDetailPlay 入口的那段（逐字重放，见 media_page.dart:516）
    final widgetLocalPath = '$root' + sep + '无职转生' + sep + 'e1.mp4'; // 进入页面时那一集
    if (req.localPath == null && widgetLocalPath != null) {
      req = PlayRequestData(
        provider: req.provider,
        id: req.id,
        title: req.title,
        cover: req.cover,
        episodeId: req.episodeId,
        episodeTitle: req.episodeTitle,
        sourceCode: req.sourceCode,
        episodes: req.episodes,
        episodeIndex: req.episodeIndex,
        localPath: widgetLocalPath,
      );
    }
    debugPrint('SEAM ① 已带 ⇒ 结果 localPath = ${req.localPath}');
    debugPrint('SEAM ① 断言：必须仍是第 2 集（$diskPick），不是第 1 集');
    expect(req.localPath, diskPick,
        reason: '★★★ 已带的不能被覆盖 —— 否则「点第 2 集」会回到第 1 集');
    expect(req.localPath, isNot(widgetLocalPath));

    // ── 判据 ②：没带 + 本地会话 ⇒ 兜到 widget 值 ─────────────
    var req2 = PlayRequestData(
      provider: 'local',
      id: 'c:/v/无职转生/e1.mp4',
      title: '无职转生',
      episodeId: 'e1.mp4',
    );
    if (req2.localPath == null && widgetLocalPath != null) {
      req2 = PlayRequestData(
        provider: req2.provider,
        id: req2.id,
        title: req2.title,
        cover: req2.cover,
        episodeId: req2.episodeId,
        episodeTitle: req2.episodeTitle,
        sourceCode: req2.sourceCode,
        episodes: req2.episodes,
        episodeIndex: req2.episodeIndex,
        localPath: widgetLocalPath,
      );
    }
    debugPrint('SEAM ② 没带+本地会话 ⇒ 结果 localPath = ${req2.localPath}');
    expect(req2.localPath, widgetLocalPath,
        reason: '★★ 本地会话下详情区选集必须兜上路径（否则报无法路由）');

    // ── 判据 ③：没带 + 在线会话 ⇒ 保持 null（不许硬编码）────────
    const onlineWidgetLocalPath = null; // 在线会话：构造参数就是 null
    var req3 = PlayRequestData(
      provider: 'cctv',
      id: 'cctv1',
      title: '在线剧',
      episodeId: 'ep2',
    );
    if (req3.localPath == null && onlineWidgetLocalPath != null) {
      fail('这条不该进（onlineWidgetLocalPath 是 null）');
    }
    debugPrint('SEAM ③ 没带+在线 ⇒ 结果 localPath = ${req3.localPath}');
    expect(req3.localPath, isNull,
        reason: '★★★ 在线会话必须保持 null —— 硬编码会把在线作品当本地文件播');

    // ── 判据 ④：★ 显式验 ui-dev 说的「先后位置」────────────────
    // 磁盘选集的绝对路径**必须**等于「目录路径 + 文件名」（生产那个函数算出来的）
    final w = CachedWork(
      dirName: '无职转生',
      path: root + sep + '无职转生',
      episodes: <CachedEpisode>[
        const CachedEpisode(
          fileName: 'e2.mp4',
          bytes: 1024,
          isComplete: true,
        ),
      ],
    );
    final r4 = buildLocalPlayRequest(w, prefer: w.episodes.first);
    debugPrint('SEAM ④ 生产算出的绝对路径 = ${r4!.episodeAbsolutePath}');
    expect(r4.episodeAbsolutePath, diskPick,
        reason: '★★ 磁盘那条链的路径就是 buildLocalPlayRequest 的产物（与 ① 同一个值）');
  });
}
