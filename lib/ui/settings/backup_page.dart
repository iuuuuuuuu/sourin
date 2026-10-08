// ═══════════════════════════════════════════════════════════════════════
//  二级页：备份（2026-09-25 任务 ㉙ 从 settings_page.dart 搬来）
// ═══════════════════════════════════════════════════════════════════════
//
// # 搬运说明（★ 逻辑一字未改，只换宿主）
//
// 原来这段是 `settings_page.dart` 里 `title: '备份'` 那个 `_Block`，
// 内容就是**一个** `const BackupPanel()`。
//
// # ★ 为什么这个页面最简单（也最该搬）
//
// `BackupPanel`（700 行）是**自包含**的：
// ```text
// const BackupPanel({super.key})    ← 无参、无回调、不依赖宿主 State
// ```
// 所以搬迁只是换一层壳，**零状态传递**。
//
// 而它又是**危险操作**（导入会合并数据），按方案 A 的理由
// 「危险操作藏深一层」正该放二级页。
//
// # 从"简化版"换成完整 `BackupPanel` 的历史（原注释照搬）
//
// # 之前这里是什么
//
// 一段说明文字 + 一个「查看备份内容」按钮（只调 `backupPreview`
// 然后把读数弹个对话框）。**不能真的导出、不能导入**。
//
// # 现在
//
// `BackupPanel` 覆盖了完整的备份闭环：
// ```text
// backupPreview      本机将导出什么（各表条数 + 插件清单）
// backupDefaultName  默认文件名（原版语义）
// backupExport       真的导出 ZIP
// backupInspect      选中一个包先**看内容**再决定导不导
// backupImport       按时间戳**合并**导入
// ```
//
// ⚠️ **功能没有丢**：旧区块唯一的「查看备份内容」对应的
//    `backupPreview` 在新面板里是**首屏就显示**的
//    （`backup_panel.dart:138` 的 `_preview = p`）——
//    比原来"点一下才看得到"更直观。
//
// ═══════════════════════════════════════════════════════════════════════
//  ★ 2026-09-29：云盘同步也搬进来了（第二个区块）
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话：
// > 云盘同步合并到备份二级页去
//
// 于是本页从「1 个区块」变成「2 个区块」：
// ```text
// 备份与恢复
//   ├─ 备份        ← BackupPanel（导出 / 导入）
//   └─ 云盘同步    ← SyncPanel（WebDAV 配置 / 测试 / 立即同步）  ★ 本次新增
// ```
//
// # ★ 为什么是「同页」而不是「合并成一个面板」
//
// `backup_panel.dart:15-23` 那张表写得很清楚 ——
// 云盘是**自动**双向增量（多设备常驻），备份是用户**手动**导出导入文件：
// ```text
// 云盘没网时还能用文件传；电脑 → 安卓迁移也用文件。
// ```
// 两者是**互补**的，所以这里保持**两个独立面板**，只是挪到同一页。
// （那条"并列而不是合并"的说明描述的是**机制**，不是**位置**，不冲突。）
//
// # ★ 为什么两个面板都是「自包含无参 widget」
//
// 见两个面板各自文件头的解释。这里只补一句：
// `SyncPanel` 是**有状态**的（要拉 `syncStatus()`），但状态全在它**自己**
// 的 `_SyncPanelState` 里 ⇒ 本页仍然只是"摆两行"，
// **零状态传递、零回调** —— 这也是为什么下面 `build` 还能整个是 `const`。

import 'package:material_ui/material_ui.dart';

import '../widgets/backup_panel.dart';
import '../widgets/settings_kit.dart';
import '../widgets/settings_sub_page.dart';
import '../widgets/sync_panel.dart';

class BackupSettingsPage extends StatelessWidget {
  const BackupSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsSubPage(
      title: '备份与恢复',
      subtitle: '导出 / 导入本机数据',
      children: [
        SettingsBlock(
          title: '备份',
          children: [
            // ★ 自包含无参 widget —— 见文件头"为什么这个页面最简单"
            BackupPanel(),
          ],
        ),
        // ★ 2026-09-29 从一级页搬来（见文件头「云盘同步也搬进来了」）
        //   同样是自包含无参 widget ⇒ 本页 build 仍是 `const`
        SyncPanel(),
      ],
    );
  }
}
