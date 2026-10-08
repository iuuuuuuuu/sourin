# 源影 Flutter 重写 · 功能对等迁移计划

> 目标（2026-09-22 用户更新）：
> **完整重写 Tauri 版，功能全实现**，而不只是四个硬指标。
> UI 可在不破坏操作逻辑的前提下优化。

---

## 一、规模盘点（实测数字）

### 原版

```text
Rust 后端       22,809 行   (src-tauri/src/)
  ├─ lib.rs      4,273 行   ← 命令层
  ├─ mod.rs      2,995 行   ← providers
  ├─ store.rs    1,467 行   ← SQLite 持久化
  ├─ streamproxy 1,490 行   ← 反盗链代理
  └─ 其余        12,584 行

Vue 前端        22,126 行   (src/)
  ├─ PlayerView   4,305 行
  ├─ SettingsView 4,442 行
  ├─ DetailView     794 行
  └─ 其余         12,585 行

Tauri 命令      87 个
```

### 当前 Flutter 版

```text
Rust 核心       17,516 行   ← ✅ 已搬（口径：可复用业务逻辑）
已接入命令      14 / 87     ← 16%
Dart 侧         shell/device/ffi/api + 探针
```

**关键结论：可复用的核心逻辑（store / registry / providers / streamproxy /
proxy / backup / webdav / follow / playback）已经搬完了 —— 17,516 行。**
剩下的是**命令层适配** + **Dart UI**。

---

## 二、搬运难度实测（重要发现）

对 87 个命令逐个测量函数体行数：

```text
≤ 5 行（纯一行适配）      31 个
6-20 行（薄逻辑）         31 个
21-60 行（中等）          18 个
> 60 行（厚逻辑）          7 个
─────────────────────────────
薄命令（≤20 行）          62 个 = 71%
```

**71% 的命令是「一行适配器」** —— 形如：

```rust
#[tauri::command]
async fn get_progress(state: State<AppState>, provider: String, id: String)
    -> Result<Option<Progress>, String> {
    state.db.get_progress(&format!("{provider}:{id}"))   // ← 就这一行
}
```

这意味着**命令层不是主要工作量** —— `state.db` / `state.registry` 这些
依赖在 Flutter 版里**已经存在**（store.rs / registry.rs 都已搬）。

### 真正需要写新逻辑的只有 7 个

```text
backup_import        170 行
set_favorite         154 行
set_following        129 行
list_favorites       101 行
list_plugins          83 行
resolve_stream        77 行   ← 已搬 ✓
search_all_stream     62 行
```

---

## 二·五、进度（2026-09-22 实时）

```text
批次  内容                      命令数  验收        状态
─────────────────────────────────────────────────────────
 1    只读（进度/历史/收藏/跳过点）  10   3/3  真实数据  ✅
 2    写入（进度/跳过点/收藏/追更）   8  14/14 隔离目录  ✅
 3    搜索（含流式导出）              2   4/4  真实网络  ✅
 4    直播（频道/流/EPG/时移）        4   3/3  真实网络  ✅
 5    Provider 与插件管理            13  10/10 隔离目录  ✅
 6    登录/代理/备份/WebDAV          22  12/12 隔离目录  ✅
 7    遥控 + 零散命令                28  17/17 含端口   ✅
─────────────────────────────────────────────────────────
     合计                          87 / 87 (100%) ★★★
```

**测试资产**（都可重复运行）：

```text
tests/batch1_readonly.rs   需 --ignored（读真实库副本）
tests/batch2_write.rs      直接跑（隔离目录）
tests/batch3_search.rs     需 --ignored（真实网络）
tests/batch4_live.rs       需 --ignored（真实网络）
tests/batch5_provider.rs   需 --ignored（真实插件）
```

**实测到的真实数据**：

```text
搜索「庆余年」        → 19 源命中 / 169 条结果 / 5 源跳过
流式搜索              → 首个事件 0.25s（总耗时 37.4s，提前 37.14s）
取消语义              → 0.66s 立即返回
直播（央视网）        → 20 个频道 / 3 个可播候选 / EPG 36 条节目
插件                  → 26/26 加载成功
```

---

## 三、分批计划

按「先只读、后写入、再网络」的顺序搬（只读命令无副作用，最好验证）。

### 批次 1 — 只读类（无副作用，优先）

```text
get_progress  continue_watching  list_history  get_skip_marker
list_skip_markers  list_favorites  total_unread  get_provider_config
plugin_config_get  remote_status_cmd  remote_auto_start  has_proxy_password
list_proxy_configs  backup_default_name  sync_status  list_platform_history
```
验收：真实数据库只读调用，返回结构与原版一致。

### 批次 2 — 收藏 / 追更 / 进度（写入）

```text
toggle_favorite  set_favorite  remove_favorite  set_following
mark_favorite_read  save_progress  set_skip_marker  clear_skip_marker
clear_history  check_updates
```
验收：**用独立数据目录**（不碰用户真实库）写入后读回，值一致。

### 批次 3 — 搜索

```text
search_all  search_all_stream
```
验收：真实跨源搜索，结果非空且结构与原版一致。

### 批次 4 — 直播

```text
get_live_channels  get_live_stream  get_epg  get_timeshift
```
验收：真实直播源解析出可播 URL。

### 批次 5 — Provider / 插件管理

```text
set_provider_enabled  set_provider_order  remove_provider
list_plugins  reload_plugins  remove_plugin  install_plugin
install_plugin_source  read_plugin  save_plugin_source
import_declarative_provider  install_http_provider  health_sweep
plugin_config_set
```
验收：插件列表读得到、启停生效、顺序持久化。

### 批次 6 — 登录 / 代理 / 备份 / 同步

```text
provider_login  provider_logout  provider_session  provider_session_state
ensure_provider_session  forget_provider_credentials
list_proxy_configs  set_proxy_config  clear_proxy_config  set_proxy_password
test_proxy  system_proxy_hint
backup_preview  backup_export  backup_inspect  backup_import
backup_platform_history  list_platform_history
configure_webdav  disconnect_sync  test_sync  sync_now  sync_platform_history
```

### 批次 7 — 局域网遥控

```text
remote_start  remote_stop  remote_refresh_pin  remote_set_fixed_pin
remote_set_auto_start  remote_report_state  remote_take_commands
remote_set_search  remote_set_home
```

---

## 三·五、命令层已完成 —— 剩余的是 UI

```text
★ 87 / 87 命令全部迁移完成（100%）
  权威核对: .probe/check_command_coverage.py
            （数 #[tauri::command] + 与 generate_handler![] 交叉验证）

集成测试总计: 59 个（b1:3 b2:14 b3:4 b4:3 b5:10 b6:12 b7:17）
单元测试:     244 个
导出符号:     sourin_call / sourin_call_async / sourin_call_stream /
              sourin_start / sourin_free
```

**下一步只剩 UI**（原版 22,126 行 Vue → Flutter）。

---

## 四、UI 计划（对标原版 Vue）

按原版行数从大到小做：

```text
1. 发现 HomeView    (639)  + SourceBar(454) + PosterCard(105)
2. 详情 DetailView  (794)  + EpisodeStrip(296) + EpisodeSheet(291)
3. 播放器 PlayerView(4305) + SkipMarkerDialog(1121)   ← 最大
4. 直播 LiveView    (484)
5. 追更 FollowView  (527)  + MyShelf(524)
6. 搜索 SearchView  (400)
7. 设置 SettingsView(4442) + BackupPanel(412) + ProviderProxy(386)
                           + PluginConfigDialog(366) + SourceSwitchDialog(465)
```

**约束（用户明确要求）**：操作逻辑与原版**完全一致** ——
交互流程、导航结构、播放器操作、快捷键都不得改。
UI 视觉可以优化，但任何**交互差异**需先与用户确认。

---

## 五、硬指标保持（不得回归）

```text
① HEVC 硬解 + AC3/DTS + ASS   已 PASS=15（Windows）
   ⚠️ Android TV 上的 HEVC 播放尚未验证 —— 本轮要补
② 一套代码三端                 已实证（含 TV 遥控器真机）
③ Windows <50MB / Android 分包  已达标（需在最终构建复测）
④ Rust 核心复用                 17,516 行
```

---

## 六、验收纪律（用户硬性规则）

```text
· 每个功能点必须有【跑出来的证据】，不接受"应该可以"
· 编译通过 / 单测绿 / SHA256 都不算实测
· 涉及用户真实数据时必须用独立数据目录
· 禁止未经明确要求 commit / push
```

---

## 三·六、★ 发现一个**原版就有的 bug**：22/26 插件取不到分类

**实测证据（纯 Rust 复现，绕开 Dart 层）**：

```text
ffzy:        categories 失败: Other 插件报错: not a function
cj:          categories 失败: Other 插件报错: not a function
hongniuzy2:  categories 失败: Other 插件报错: not a function
```

**根因**：26 个插件里有 **22 个**把 `categories` 写成**数组属性**：

```js
categories: [ { id: "1", name: "电影片" }, ... ]    // ← 22 个插件
```

但运行时调的是 **函数形式**：

```rust
let json = self.call_js("plugin.categories()").await?;   // ← 数组当函数调
```

只有 4 个插件（bilibili / cctv / cycani / demo）写成函数，所以能用。

**这不是我引入的** —— 我的 `plugins/mod.rs` L1562 与原版 L1562 **逐字相同**。
原版前端 `BrowseView.vue` L49 直接调 `content.categories(provider)`，没有 fallback。

**影响面（查了真实用户库）**：用户实际在用的源里 **154 / tyyszy 是数组形式**
（`cycani` / `cctv` / `bilibili` 是函数形式，不受影响）。

**能不能修**：能，且改动很小 —— 在 `categories()` 里加一层兼容：

```rust
// 先问是不是函数；不是就当数组读
let expr = "(typeof plugin.categories === 'function') \
            ? plugin.categories() : plugin.categories";
```

`has_method()`（L1834）已经有现成的 `typeof` 判断写法可复用。

⚠️ **但这会改变与原版不一致的行为** —— 按 Owner 的硬性要求
（「操作逻辑和原版完全一致，任何交互差异需先确认」），
**必须先问过用户**再改。

**待用户决定**：修 / 不修 / 只在 Flutter 版修。