// ═══════════════════════════════════════════════════════════════════════
//  二级页：关于（2026-09-25 任务 ㉙ 从 settings_page.dart 搬来）
// ═══════════════════════════════════════════════════════════════════════
//
// # 搬运说明（★ 逻辑一字未改，只换宿主）
//
// 原来这段是 `settings_page.dart` 里 `title: '关于'` 那个 `_Block`。
//
// # ★ 为什么这个页面**必须自己拉数据**（而主题页不用）
//
// 原区块读两个**来自父级 State 的字段**：
// ```text
// _sync?.deviceId        ← SyncStatus（云盘同步状态里带的设备 ID）
// _providers.length      ← 内容源列表（26 个 / 25 个已启用）
// ```
// 二级页是**独立路由**，拿不到设置页的 State —— 所以自己调 API。
//
// ⚠️ **不能**把设置页的 `_sync` / `_providers` 传进来：
// ```text
// ① 设置页那两份数据是"打开设置页那一刻"的快照 —— 用户可能几分钟后
//    才点进「关于」，显示的就是过期数据（设备 ID 尤其不该过期）
// ② 传参会把二级页与设置页的 State 形状**绑死** —— 以后设置页改字段，
//    二级页跟着编译失败（搬家的意义就没了）
// ```
//
// # 这里读的两个 API 与设置页**完全一致**
//
// ```text
// SourinApi.syncStatus()    → SyncStatus（含 deviceId）
// SourinApi.listProviders() → List<ProviderManifest>
// ```
// 与 `settings_page.dart` 的 `loadAll()` 用的是同一对接口，
// 所以两处显示的数字**必然一致**（不存在"设置页说 26 个、关于页说 25 个"）。

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/sourin_api.dart';
import '../tokens.dart';
import '../widgets/settings_kit.dart';
import '../widgets/settings_sub_page.dart';

class AboutSettingsPage extends StatefulWidget {
  const AboutSettingsPage({super.key});

  @override
  State<AboutSettingsPage> createState() => _AboutSettingsPageState();
}

class _AboutSettingsPageState extends State<AboutSettingsPage> {
  SyncStatus? _sync;
  List<ProviderManifest> _providers = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    /*
     * ⚠️ 两个请求**各自 try/catch** —— 一个失败不该让另一个也不显示。
     *
     * 设备 ID 来自云盘同步状态：用户**没配云盘**时这个接口可能直接报错
     * （那是正常状态，不是故障）。若共用一个 try，没配云盘的用户会连
     * "内容源 26 个"都看不到 —— 而那跟云盘毫无关系。
     */
    SyncStatus? sync;
    List<ProviderManifest> providers = const [];
    try {
      sync = await SourinApi.syncStatus();
    } catch (e) {
      debugPrint('[ABOUT] 云盘状态读取失败（未配置时属正常）: $e');
    }
    try {
      providers = await SourinApi.listProviders();
    } catch (e) {
      debugPrint('[ABOUT] 内容源列表读取失败: $e');
    }
    if (!mounted) return;
    setState(() {
      _sync = sync;
      _providers = providers;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '关于',
      subtitle: '版本与运行信息',
      children: [
        /*
         * ★★★ 2026-10-01：块标题从 `'关于'` 改成 `'运行信息'`（Owner 报「排版混乱」）
         *
         * # 症状（手机截图 `.probe\n8_about.png`）
         * ```text
         * ← 返回设置
         * 关于                  ← 页头大标题（xl=28）
         * 版本与运行信息          ← 页头副标题（sm=14）
         * 关于                  ← ★ 块标题（lg=20）—— 与页头**同名**
         * ┌────────────────┐
         * │ 架构  Flutter…  │
         * ```
         * 一屏里「关于」出现两次 ⇒ 读起来像渲染重复/页面没做完。
         *
         * # 为什么改块标题而不是删掉它
         * 块标题是 `SettingsBlock` 的必需参数，且它承担"这框是什么"的语义。
         * 页头已经说了「关于」，块里装的是**具体的运行信息**
         * （架构 / 核心版本 / 设备 ID / 内容源）⇒ 叫「运行信息」既消重
         * 又比「关于」更准确。
         *
         * ⚠️ **不改页头**（`title: '关于'`）：那是路由名，也是
         *   `SettingsEntryRow(title: '关于')` 点进来的落点，改名会破坏
         *   "入口叫什么、进去还叫什么"的一致性。
         */
        SettingsBlock(
          title: '运行信息',
          children: [
            /*
             * ★ 「架构」这一行与原版**故意不同**
             *
             * 原版写的是 `Tauri 2 + Vue 3 + Rust` —— 那是旧实现。
             * 重写后是 `Flutter + media_kit + Rust`，如实显示才对。
             *
             * ⚠️ 这是**内容**差异不是**交互**差异：
             *    用户看到的是"这个软件用什么做的"，
             *    显示旧栈反而是错的（误导）。
             */
            const SettingsInfoRow(
              label: '架构',
              value: 'Flutter + media_kit + Rust',
            ),
            SettingsInfoRow(label: '核心版本', value: SourinApi.version),
            SettingsInfoRow(
              label: '设备 ID',
              value: _sync?.deviceId ?? '(未知)',
            ),
            SettingsInfoRow(
              label: '内容源',
              value: '${_providers.length} 个'
                  '（${_providers.where((p) => p.enabled).length} 个已启用）',
            ),
          ],
        ),
      ],
    );
  }
}
