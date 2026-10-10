// ═══════════════════════════════════════════════════════════════════════
//  批次 5 · Provider 与插件管理（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这批的共同主题：**持久化**
//
// 前四批大多是「读数据 / 写数据」，这批的关键在于**改动要落盘**：
// ```text
// 停用某个源   → 必须记住（否则重启后全部恢复启用 —— 原版实测过的 bug）
// 调整源顺序   → 必须落盘
// 移除第三方源 → 必须从清单里删（否则重启后「幽灵源」复活）
// ```
// 每一处都有对应的原版注释说明踩过的坑。
//
// # ★★ 这批里有一个「静默失败」的经典案例
//
// `list_plugins` 的配置声明**必须从已注册的 Provider 拿**，
// 不能用 `load_plugins()` 的结果 —— 详见该函数上的长注释。
// 表现是「插件明明声明了配置，但设置页死活不显示『配置』按钮」，
// **而且不报任何错**。

use crate::model::{PersistedProvider, ProviderManifest};
use crate::provider::MediaProvider;
use crate::state::AppState;

/// 插件目录
fn plugins_dir(data_dir: &std::path::Path) -> std::path::PathBuf {
    crate::state::plugins_dir(data_dir)
}

/// 切换某个源的启用状态（**并落盘**）
///
/// # 为什么必须落盘（原版实测的 bug）
///
/// ```text
/// 原先只改内存 → 重启后全部恢复启用
/// ```
/// 「停用某个源」是用户**应该被记住的偏好**，不是临时开关。
/// 用户停用了 10 个不好用的源，重启后全回来 —— 那是很糟的体验。
pub fn set_enabled_persisted(
    state: &AppState,
    id: &str,
    enabled: bool,
) -> Result<bool, String> {
    let ok = state.registry.set_enabled(id, enabled);
    if !ok {
        // 源不存在 —— 返回 false 而不是报错（前端据此提示"源已不存在"）
        return Ok(false);
    }

    let mut list = super::commands::load_disabled(&state.data_dir);
    if enabled {
        list.retain(|x| x != id);
    } else if !list.iter().any(|x| x == id) {
        list.push(id.to_string());
    }
    super::commands::save_disabled(&state.data_dir, &list)?;
    Ok(true)
}

/// 设置源的显示顺序
///
/// # 为什么返回 `actual` 而不是回显入参
///
/// `registry.reorder()` 会**做一次实际的排序并返回真实结果** ——
/// 入参里可能有：
/// ```text
/// · 不存在的 id（前端列表过期）
/// · 缺失的 id（新增的源还没进列表）
/// ```
/// 直接回显入参会让前端以为排序成功了，而实际内存里不是那个顺序。
/// 返回真实结果，前端就能据此纠正自己的列表。
pub fn set_provider_order(
    state: &AppState,
    ids: &[String],
) -> Result<Vec<String>, String> {
    let actual = state.registry.reorder(ids);
    super::commands::save_order(&state.data_dir, &actual)?;
    Ok(actual)
}

/// 取某第三方源的持久化配置
pub fn get_provider_config(
    state: &AppState,
    id: &str,
) -> Result<Option<PersistedProvider>, String> {
    let list = state
        .third_party
        .read()
        .map_err(|_| "第三方源列表被污染".to_string())?;
    Ok(list.iter().find(|x| x.id() == id).cloned())
}

/// 移除第三方源
///
/// # ★ 两件事都要做，漏一件就有 bug
///
/// ```text
/// ① registry.unregister(id)  → 从内存摘掉
/// ② 从 third_party 清单里删 + 落盘
/// ```
/// 只做 ① 的后果：重启后 `load_persisted` 又把它加载回来 ——
/// 用户看到「删掉的源自己复活了」（原版注释称之为「幽灵源」）。
///
/// # 还要 touch_providers
///
/// 标记「配置刚被改过」供云同步的 LWW 判据用。
/// **每一个改动第三方源的路径都必须调用它** —— 漏掉任何一处，
/// 同步时就会误判成「远端更新」，把用户刚改的配置打回云端那份
///（表现：改完同步一次又变回去）。
pub fn remove_provider(state: &AppState, id: &str) -> Result<bool, String> {
    let removed = state.registry.unregister(id);

    if removed {
        {
            let mut list = state
                .third_party
                .write()
                .map_err(|_| "第三方源列表被污染".to_string())?;
            list.retain(|x| x.id() != id);
        }
        persist_from_registry(state)?;
        touch_providers(state);
    }
    Ok(removed)
}

/// 标记「内容源配置刚被改过」（供云同步的 LWW 判据用）
pub fn touch_providers(state: &AppState) {
    state.providers_updated_at.store(
        chrono::Utc::now().timestamp_millis(),
        std::sync::atomic::Ordering::SeqCst,
    );
}

/// 把「当前内存里的第三方源」写回清单
///
/// ⚠️ 从**内存状态反推**而不是维护一份并行列表：
/// 避免两处状态不一致（用户移除源后忘了同步清单 = 幽灵源复活）。
pub fn persist_from_registry(state: &AppState) -> Result<(), String> {
    let list: Vec<PersistedProvider> = state
        .third_party
        .read()
        .map_err(|_| "第三方源列表被污染（锁中毒）".to_string())?
        .clone();
    crate::persist::save_persisted(&state.data_dir, &list)
}

// ═══════════════════════════════════════════════════════════════════════
//  插件文件管理
// ═══════════════════════════════════════════════════════════════════════

/// 校验插件文件名（防目录穿越）
///
/// # ⚠️ 这个参数来自前端，必须当作**不可信输入**
///
/// ```text
/// "../../../Windows/System32/xxx.js"  → 能删/写任意文件
/// "sub/dir.js"                        → 能越出插件目录
/// ```
/// 三个命令（`read_plugin` / `save_plugin_source` / `remove_plugin`）
/// 都用同一个校验，所以抽出来只写一次 ——
/// **分散写三遍就可能有一处漏掉**，而漏掉的那处是安全漏洞。
fn check_plugin_name(file: &str) -> Result<(), String> {
    if file.contains('/') || file.contains('\\') || file.contains("..") {
        return Err("非法的文件名".into());
    }
    Ok(())
}

/// 读取插件源码
pub fn read_plugin(state: &AppState, file: &str) -> Result<String, String> {
    check_plugin_name(file)?;
    let path = plugins_dir(&state.data_dir).join(file);
    std::fs::read_to_string(&path).map_err(|e| format!("读取失败: {e}"))
}

/// 删除插件文件（同时从 registry 摘掉）
pub fn remove_plugin(state: &AppState, file: &str) -> Result<(), String> {
    check_plugin_name(file)?;
    let path = plugins_dir(&state.data_dir).join(file);
    if !path.exists() {
        return Err(format!("插件文件不存在: {file}"));
    }

    // 先读出 id，才能从 registry 摘掉
    if let Ok(src) = std::fs::read_to_string(&path) {
        let m = crate::plugins::parse_meta(&src);
        if !m.id.is_empty() {
            state.registry.unregister(&m.id);
        }
    }

    std::fs::remove_file(&path).map_err(|e| format!("删除失败: {e}"))?;
    log::info!("已删除插件 {file}");
    Ok(())
}

/// 保存插件源码（带校验 + 热重载）
///
/// # 三道校验（顺序不能换）
///
/// ```text
/// ① 文件名合法（防目录穿越）
/// ② 文件**必须已存在** —— 这个命令是「编辑已有插件」，
///    不是「新建」。允许新建会让前端的一个 bug 变成"写入任意 .js"
/// ③ 元信息：@id / @name 必须有（parse_meta 不执行脚本，只读头部注释）
/// ④ 语法：validate_source 会**真的执行一次**，能捕获括号不配对之类
/// ```
/// 最后热重载，改完立即生效。
pub async fn save_plugin_source(
    state: &AppState,
    file: &str,
    source: &str,
) -> Result<usize, String> {
    check_plugin_name(file)?;
    let dir = plugins_dir(&state.data_dir);
    let path = dir.join(file);
    if !path.exists() {
        return Err(format!("插件文件不存在: {file}"));
    }

    // 1) 元信息校验（不执行脚本）
    let meta = crate::plugins::parse_meta(source);
    if meta.id.is_empty() {
        return Err("保存失败：插件缺少 @id（头部注释里必须有）".into());
    }
    if meta.name.is_empty() {
        return Err(format!("保存失败：插件 {} 缺少 @name", meta.id));
    }

    // 2) 语法校验（真的执行一次，能捕获括号不配对之类的问题）
    if let Err(e) = crate::plugins::validate_source(source).await {
        return Err(format!("保存失败：{e}"));
    }

    std::fs::write(&path, source).map_err(|e| format!("写入失败: {e}"))?;
    log::info!("已保存插件 {file}（{} 字节）", source.len());

    // 3) 热重载，改完立即生效
    reload_plugins(state).await
}

/// 重新加载全部 JS 插件
///
/// # 步骤（顺序重要）
///
/// ```text
/// 1) 先摘掉所有 kind == "js" 的源
/// 2) 重新扫描并注册（含补齐能力位 hydrate）
/// ```
/// 不先摘掉的话，重复注册同一个 id 会有两份实例，
/// 表现是「搜索结果里同一个源出现两次」。
pub async fn reload_plugins(state: &AppState) -> Result<usize, String> {
    let dir = plugins_dir(&state.data_dir);

    // 1) 摘掉所有 kind == "js" 的源
    let js_ids: Vec<String> = state
        .registry
        .manifests()
        .into_iter()
        .filter(|m| m.kind == "js")
        .map(|m| m.id)
        .collect();
    for id in &js_ids {
        state.registry.unregister(id);
    }

    // 2) 重新扫描并注册（含补齐能力位）
    let (plugins, failed) =
        crate::plugins::load_plugins_hydrated(&dir, Some(state.proxy.clone())).await;
    let n = plugins.len();
    for p in plugins {
        state.registry.register(std::sync::Arc::new(p));
    }

    for (f, why) in failed {
        log::warn!("插件 {f} 加载失败: {why}");
    }
    log::info!("已重新加载 {n} 个 JS 插件");
    Ok(n)
}

/// 插件列表的一项（对应原版 `PluginListResult` 的条目）
#[derive(Debug, Clone, serde::Serialize)]
pub struct PluginEntry {
    pub file: String,
    pub id: String,
    pub name: String,
    pub version: String,
    /// ★ 插件声明的作者（`@author`）—— 界面据此显示**来源标识**（task-5 / 缺陷 5）
    ///
    /// # 为什么这个字段必须一路传到界面
    ///
    /// Owner 缺陷 5 原文：
    /// > ……而且要加上标识，**自己平台的插件**还是 **tvbox 的兼容**
    ///
    /// 这个区分**只有源码知道** —— `@author tvbox-convert` 是转换器写的，
    /// 内置源模板写的是 `@author dsh`（从原版继承的名字），
    /// 新增的 emby 模板写的是 `@author sourin`。
    ///
    /// ⚠️ 不能用 `kind` 代替：TVBox **配置订阅**导入的原生源 `kind = "tvbox"`，
    ///    而 TVBox **插件**转换出来的源 `kind = "js"` —— 后者与手写 JS 插件
    ///    无法用 `kind` 区分，只有 `@author` 能区分。
    ///
    /// ⚠️ 空串表示"源码里没写 `@author`"（不是"第三方"）——
    ///    界面据此**不显示**标识，而不是猜一个。
    pub author: String,
    /// ★ 插件声明的**上游接口地址**（task-5 / 缺陷 5 的另一个诉求）
    ///
    /// Owner 缺陷 5 原文：
    /// > 你既然已经支持了 tvbox，那么就应该把所有的 tvbox 插件都**还原成原本的链接**，
    /// > 而不是现在转换后的插件
    ///
    /// ★★ 关键事实：**链接从来没丢过**。TVBox 转换器把原始接口逐字写进了生成的
    ///    `.js` 里（头部注释 ` * 上游接口（苹果CMS v10）：http://...`），
    ///    只是**界面从来没显示过** —— 所以这不是"还原"，是"显示出来"。
    ///
    /// 解析规则见 [crate::plugins::upstream_of]（只读源码，零副作用）。
    #[serde(skip_serializing_if = "String::is_empty")]
    pub upstream: String,
    /// 是否成功加载（false 时 `error` 有原因）
    pub loaded: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// ★ 插件声明的配置项（设置页据此渲染表单）
    pub config: Vec<crate::model::ConfigField>,
}

/// 插件列表结果
#[derive(Debug, Clone, serde::Serialize)]
pub struct PluginListResult {
    pub plugins: Vec<PluginEntry>,
    /// 加载失败的插件（文件名 + 原因）
    pub failed: Vec<(String, String)>,
}

/// 列出插件（含配置声明）
///
/// # ★★ 一个「静默失败」的经典案例（原版踩过）
///
/// ## 错误做法
///
/// ```text
/// let (loaded, failed) = load_plugins(&dir);
/// for p in loaded {
///     let config = p.manifest().config;   // ★ 永远是空数组
/// }
/// ```
/// `load_plugins()` 的文档明确写着「**只做静态解析，不执行脚本**」——
/// 它返回的 provider 里 `manifest.config` 是**空的**，
/// 因为能力位与配置项都要**跑脚本**才知道（见 `hydrate_capabilities()`）。
///
/// ## 症状（很难查）
///
/// ```text
/// 插件明明声明了配置，但设置页死活不显示「配置」按钮，
/// 而且**不报任何错**。
/// ```
///
/// ## 正解
///
/// 从 `state.registry` 拿**已经 hydrate 过**的实例 ——
/// registry 里的 provider 在注册前都跑过 `hydrate_capabilities()`
///（见 `plugins::register_all`），所以 `config` 是齐的。
///
/// ## 为什么这个坑值得记住
///
/// 「拿到空数组」不会报错，只会让 UI 少显示一个按钮。
/// 从"少一个按钮"回溯到"应该从 registry 拿而不是 load_plugins"，
/// 中间隔了很远 —— 所以这里的注释写得很详细，防止再犯。
pub fn list_plugins(state: &AppState) -> Result<PluginListResult, String> {
    let dir = plugins_dir(&state.data_dir);

    // ★ 关键：从**已注册的 Provider** 拿，不能用 load_plugins() 的结果
    let registered: Vec<ProviderManifest> = state.registry.manifests();

    let (loaded, mut failed) = crate::plugins::load_plugins(&dir);
    let loaded_ids: std::collections::HashSet<String> = loaded
        .iter()
        .map(|p| MediaProvider::manifest(p).id.clone())
        .collect();

    let mut plugins = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for e in entries.flatten() {
            let path = e.path();
            if path.extension().and_then(|s| s.to_str()) != Some("js") {
                continue;
            }
            let file = path
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_string();

            let src = match std::fs::read_to_string(&path) {
                Ok(s) => s,
                Err(e) => {
                    failed.push((file.clone(), format!("读取失败: {e}")));
                    continue;
                }
            };
            let meta = crate::plugins::parse_meta(&src);
            /*
             * ★ task-5（缺陷 5）：上游接口地址也在这里一起解析
             *
             * ⚠️ 放在**读源码的地方**而不是放进上面的 `registered` 循环 ——
             *    `registered` 是已注册的 Provider，**加载失败的插件不在里面**，
             *    而"某个源挂了"恰恰是用户最想看它上游是谁的时候。
             *    这里只依赖 `src`（已经读进来了），零额外 IO。
             */
            let upstream = crate::plugins::upstream_of(&src);

            /*
             * ★ 从 registered 里找（已 hydrate）——
             *   而不是从 loaded 里找（config 是空的）
             */
            let manifest = registered.iter().find(|m| m.id == meta.id);

            let (name, version, config, loaded_ok, error) = match manifest {
                Some(m) => (
                    m.name.clone(),
                    m.version.clone(),
                    m.config.clone(),
                    true,
                    None,
                ),
                None => {
                    let why = if meta.id.is_empty() {
                        "缺少 @id".to_string()
                    } else if !loaded_ids.contains(&meta.id) {
                        "加载失败（语法错误或缺少必需字段）".to_string()
                    } else {
                        // 加载成功但没注册 —— 不应该发生，记下来便于排查
                        "已解析但未注册".to_string()
                    };
                    (meta.name.clone(), meta.version.clone(), Vec::new(), false, Some(why))
                }
            };

            plugins.push(PluginEntry {
                file,
                id: meta.id,
                name,
                version,
                // ★ task-5：来源标识 + 上游链接（都只用于显示，不参与运行）
                author: meta.author,
                upstream,
                loaded: loaded_ok,
                error,
                config,
            });
        }
    }

    plugins.sort_by(|a, b| a.file.cmp(&b.file));
    Ok(PluginListResult { plugins, failed })
}

// ═══════════════════════════════════════════════════════════════════════
//  插件「检测更新 / 更新 / 回滚」（task-23，2026-09-25）
// ═══════════════════════════════════════════════════════════════════════
//
// 用户拍板：
// > 通过链接检测更新,可以进行回滚
// > 插件市场暂时不做  github raw 暂时不做
//
// # 数据来源只有一条：当初安装它的那个链接
//
// 所以本组命令的**前置条件**是 `plugins/.meta/<id>.json` 里有 `source_url`
//（由 `install_plugin` 落盘，见 `commands_remote.rs`）。
//
// # ★★ 最重要的一条产品原则：**没有的能力不假装有**
//
// 用户手动丢进 `plugins/` 的 `.js` **没有安装链接** ——
// 这类插件**永远无法通过链接检测更新**（没有源可查）。
// 所以：
// ```text
// · check 系列返回 needsSource = true（而不是"已是最新"）
// · 界面据此**不显示**「检测更新」按钮，只如实说明"无安装链接"
// ```
// ⚠️ 绝不把它当成"检测过、已是最新" —— 那是**假装有能力**。
//    用户会以为"点了没反应 = 没问题"，实际我们从没查过。

/// 一个插件的「检测更新」结果
#[derive(Debug, Clone, serde::Serialize)]
pub struct PluginUpdateInfo {
    pub id: String,
    pub file: String,
    /// 本地当前版本（插件声明的 `@version`）
    pub version: String,
    /// ★ 没有安装链接 = 无法检测（**不是错误**，是如实的能力缺失）
    ///
    /// 界面据此**不显示**「检测更新」按钮。见文件头那段原则。
    pub needs_source: bool,
    /// 安装来源链接（`needs_source == true` 时为 `None`）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_url: Option<String>,
    /// 远端版本（查不到时为 `None`）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remote_version: Option<String>,
    /// 是否有新版（`remote > local`）
    pub has_update: bool,
    /// ★ 远端内容与本地**逐字节相同**（"内容没变"）
    ///
    /// 与 `has_update` 分开两个字段，因为它们是**两件事**：
    /// ```text
    /// has_update   版本号变新了        → 该提示"更新到 vX"
    /// same_content 内容一模一样        → 即使版本号变新，"更新"也是空操作
    /// ```
    /// 表现：作者改了内容但忘了改版本号时 `has_update=false / same_content=false`
    ///       —— 我们**不提示更新**（保守），但历史弹窗里能看到差异。
    pub same_content: bool,
    /// 失败原因（网络错 / 链接失效 / 不是 JS / 解析不出版本）
    ///
    /// ★ **失败要如实**：绝不静默成"已是最新"。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// 找到某个插件的文件名（扫 `plugins/*.js`，按 `@id` 匹配）
///
/// ⚠️ 为什么不直接用 `<id>.js`：
/// ```text
/// `save_plugin` 确实按 `<id>.js` 命名，但用户**手动放进来的文件**
/// 文件名是任意的（`我的插件.js` / `154.js` …）——
/// 而 `list_plugins` 是按文件扫的。所以必须真的扫目录匹配 @id。
/// ```
/// 只读文件头（`parse_meta` 只看前 2KB），不执行脚本。
fn find_plugin_file(dir: &std::path::Path, id: &str) -> Option<(String, String)> {
    let rd = std::fs::read_dir(dir).ok()?;
    for e in rd.flatten() {
        let path = e.path();
        if path.extension().and_then(|s| s.to_str()) != Some("js") {
            continue;
        }
        let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
            continue;
        };
        let Ok(src) = std::fs::read_to_string(&path) else {
            continue;
        };
        let m = crate::plugins::parse_meta(&src);
        if m.id == id {
            return Some((name.to_string(), src));
        }
    }
    None
}

/// 读某个插件当前声明的版本 + 它的来源 meta
///
/// 返回 `(file, source, version, meta)`；插件不存在返回 `Err`。
fn plugin_state(
    dir: &std::path::Path,
    id: &str,
) -> Result<(String, String, String, Option<crate::plugins::PluginSourceMeta>), String> {
    let (file, src) = find_plugin_file(dir, id).ok_or_else(|| format!("没有找到插件 {id}"))?;
    let m = crate::plugins::parse_meta(&src);
    let version = if m.version.is_empty() {
        // 与 load_plugins 的兜底一致（mod.rs:298）—— 缺 @version 时按 1.0.0
        "1.0.0".to_string()
    } else {
        m.version.clone()
    };
    let meta = crate::plugins::read_plugin_meta(dir, id);
    Ok((file, src, version, meta))
}

/// 检测**单个**插件是否有更新（只走安装链接）
///
/// # 三种结局，都不许静默
///
/// ```text
/// ① 没有 source_url        → needs_source=true（如实说"查不了"）
/// ② 网络/解析失败           → error=Some(原因)（如实说"查失败了"）
/// ③ 查到了                  → remote_version + has_update + same_content
/// ```
pub async fn check_plugin_update(
    state: &AppState,
    id: &str,
) -> Result<PluginUpdateInfo, String> {
    let dir = plugins_dir(&state.data_dir);
    let (file, local_src, version, meta) = plugin_state(&dir, id)?;

    let Some(url) = meta.as_ref().and_then(|m| m.source_url.clone()) else {
        // ★ 手动放入的插件 —— 如实报告"无法检测"，绝不假装"已是最新"
        return Ok(PluginUpdateInfo {
            id: id.to_string(),
            file,
            version,
            needs_source: true,
            source_url: None,
            remote_version: None,
            has_update: false,
            same_content: false,
            error: None,
        });
    };

    // ★ 复用已有的下载路径（原版「导入/覆盖安装」那条）—— 别另写一套
    let fetched = crate::plugins::fetch_plugin_source(Some(&state.proxy), &url).await;

    match fetched {
        Err(e) => Ok(PluginUpdateInfo {
            id: id.to_string(),
            file,
            version,
            needs_source: false,
            source_url: Some(url),
            remote_version: None,
            has_update: false,
            same_content: false,
            // ★ 如实报失败原因（网络错/链接失效/不是 JS）
            error: Some(e),
        }),
        Ok((remote_src, _used)) => {
            let rm = crate::plugins::parse_meta(&remote_src);
            if rm.version.is_empty() {
                /*
                 * ★ 远端解析不出版本 —— **这是个真实且常见的情况**：
                 *   作者可能忘了写 @version。此时**不能**默认成 1.0.0 然后
                 *   跟本地比（本地也可能被兜底成 1.0.0 → 得出"无更新"的假结论）。
                 *   如实报"远端没有版本号"，让用户自己决定。
                 */
                return Ok(PluginUpdateInfo {
                    id: id.to_string(),
                    file,
                    version,
                    needs_source: false,
                    source_url: Some(url),
                    remote_version: None,
                    has_update: false,
                    same_content: crate::plugins::same_content(&remote_src, &local_src),
                    error: Some("远端插件没有声明 @version，无法比较版本".into()),
                });
            }
            let has_update = crate::plugins::version_is_newer(&rm.version, &version);
            Ok(PluginUpdateInfo {
                id: id.to_string(),
                file,
                version,
                needs_source: false,
                source_url: Some(url),
                remote_version: Some(rm.version),
                has_update,
                same_content: crate::plugins::same_content(&remote_src, &local_src),
                error: None,
            })
        }
    }
}

/// 批量检测（**用户真正会用的**：26 个插件不可能一个个点）
///
/// 返回 `(结果列表, 跳过的数量)`。
///
/// # 为什么返回"跳过数"而不是只返回结果
///
/// ```text
/// 26 个插件里可能只有 1 个有链接 —— 界面要说
/// 「检测了 1 个，25 个没有安装链接（手动放入的）」
/// 否则用户看到列表安安静静，会以为"功能坏了"。
/// ```
///
/// ⚠️ 返回**对象**而不是 `(Vec, usize)` 元组：
///    元组会被 serde 序列化成 JSON **数组** `[{...}, 25]`，
///    前端得按位置取值（脆、且看不出来 25 是什么）。
///    具名字段自解释，将来加字段也不会错位。
///
/// # ⚠️ 为什么串行而不是并发
///
/// ```text
/// ① 这些请求都走同一个 reqwest client（有连接池），并发收益有限
/// ② 插件源常是同一台 CDN —— 并发容易被限流
/// ③ 串行的进度是**确定的**（用户能看到一个一个地查）
/// ④ 实测 26 个里通常只有个位数有链接 → 串行延迟完全可接受
/// ```
pub async fn check_all_plugin_updates(
    state: &AppState,
) -> Result<serde_json::Value, String> {
    let dir = plugins_dir(&state.data_dir);
    let (plugins, _failed) = crate::plugins::load_plugins(&dir);

    let mut out = Vec::new();
    let mut skipped = 0usize;
    for p in plugins {
        let id = p.manifest().id.clone();
        match check_plugin_update(state, &id).await {
            Ok(info) => {
                if info.needs_source {
                    skipped += 1;
                }
                out.push(info);
            }
            Err(e) => {
                /*
                 * ⚠️ 单个插件出错**不能让整批失败** ——
                 *    否则一个坏文件就让"批量检测"整个不可用。
                 *    记日志 + 跳过（它不在 out 里，前端看到的就是"没这个插件"）。
                 */
                log::warn!("批量检测跳过 {id}: {e}");
                skipped += 1;
            }
        }
    }
    Ok(serde_json::json!({ "items": out, "skipped": skipped }))
}

/// 更新到远端最新版（**用户点了才执行** —— 绝不自动覆盖）
///
/// # 步骤（顺序不能换）
///
/// ```text
/// ① 取来源链接（没有 → 报错，不猜）
/// ② 下载远端（复用 fetch_plugin_source）
/// ③ 校验：@id 必须与本地**一致**（防止链接被换成了别的插件）
///    ★ 这条很重要：source_url 是**外部可变**的 —— 站点被劫持/作者改仓库，
///      都可能让"更新"变成"换掉一个完全不同的插件"
/// ④ 归档当前版本到 .versions（**这就是回滚的数据来源**）
/// ⑤ 写盘 + 热重载
/// ⑥ 更新 meta（新版本号 + 时间）
/// ⑦ 清理 .versions（保持有界）
/// ```
///
/// ⚠️ 第 ④ 步在**第 ⑤ 步之前**：万一写盘失败，至少历史档已经存下了，
///    磁盘上还是能恢复的（反过来做则可能两边都丢）。
///
/// ⚠️ **不碰 `plugins/.data/`** —— 那是插件的用户配置，
///    回滚/更新只换 `.js`。这条有单测锁住（`update_keeps_user_config`）。
pub async fn update_plugin_from_source(
    state: &AppState,
    id: &str,
) -> Result<serde_json::Value, String> {
    let dir = plugins_dir(&state.data_dir);
    let (file, local_src, version, meta) = plugin_state(&dir, id)?;

    let url = meta
        .as_ref()
        .and_then(|m| m.source_url.clone())
        .ok_or_else(|| {
            format!("插件 {id} 没有安装链接（可能是手动放入的），无法通过链接更新")
        })?;

    let (remote_src, _used) = crate::plugins::fetch_plugin_source(Some(&state.proxy), &url).await?;

    // ③ 校验 @id 一致
    let rm = crate::plugins::parse_meta(&remote_src);
    if rm.id.is_empty() {
        return Err("下载到的内容不是合法插件（缺少 @id）".into());
    }
    if rm.id != id {
        return Err(format!(
            "链接指向的插件 @id 是「{}」，与当前「{id}」不一致 —— 已拒绝更新（防止链接被换成别的插件）",
            rm.id
        ));
    }
    if rm.name.is_empty() {
        return Err(format!("插件 {} 缺少 @name", rm.id));
    }

    // ★ 内容没变就别覆盖（用户要求 + 元数据里 sha256 那条需求的实质）
    if crate::plugins::same_content(&remote_src, &local_src) {
        return Ok(serde_json::json!({
            "updated": false,
            "reason": "内容与本地一致，无需更新",
            "version": version,
            "file": file,
        }));
    }

    // ④ 归档当前版本（回滚的数据来源）
    let archived = crate::plugins::archive_plugin_version(&dir, id, &version, &local_src)?;

    // ⑤ 写盘
    std::fs::write(dir.join(&file), &remote_src).map_err(|e| format!("写入失败: {e}"))?;

    let new_version = if rm.version.is_empty() {
        version.clone()
    } else {
        rm.version.clone()
    };

    // ⑥ 更新 meta
    let new_meta = crate::plugins::PluginSourceMeta {
        source_url: Some(url),
        installed_version: new_version.clone(),
        installed_at: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0),
        file: file.clone(),
    };
    // meta 写失败不影响更新本身（只是下次查不到版本基准）→ 记日志
    if let Err(e) = crate::plugins::write_plugin_meta(&dir, id, &new_meta) {
        log::warn!("写入插件 meta 失败（不影响更新）: {e}");
    }

    // ⑦ 清理历史档（保持有界）
    let pruned = crate::plugins::prune_plugin_versions(&dir, id);

    // 热重载 —— 不重载的话界面上还是旧版行为
    reload_plugins(state).await?;

    log::info!(
        "已更新插件 {id}: v{version} → v{new_version}（归档 {archived:?}，清理 {pruned} 档）"
    );

    Ok(serde_json::json!({
        "updated": true,
        "fromVersion": version,
        "version": new_version,
        "file": file,
        "archived": archived.file_name().and_then(|s| s.to_str()).unwrap_or(""),
        "pruned": pruned,
    }))
}

/// 列出某个插件的**历史版本档**（新的在前）
///
/// 返回 `(version, 文件名, 大小, 修改时间)`。
///
/// ⚠️ 这是回滚弹窗的数据源。**没有历史时返回空列表，不是错误**。
pub fn list_plugin_version_history(
    state: &AppState,
    id: &str,
) -> Result<Vec<serde_json::Value>, String> {
    let dir = plugins_dir(&state.data_dir);
    let out = crate::plugins::list_plugin_versions(&dir, id)
        .into_iter()
        .map(|(v, path)| {
            let meta = std::fs::metadata(&path).ok();
            serde_json::json!({
                "version": v,
                "file": path.file_name().and_then(|s| s.to_str()).unwrap_or(""),
                "bytes": meta.as_ref().map(|m| m.len()).unwrap_or(0),
                "mtime": meta
                    .and_then(|m| m.modified().ok())
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs() as i64)
                    .unwrap_or(0),
            })
        })
        .collect();
    Ok(out)
}

/// 回滚到指定历史版本
///
/// # 步骤
///
/// ```text
/// ① 找到那一档（找不到 → 报错，并列出可用的档，方便用户自己纠正）
/// ② ★ 先把**当前**版本也归档一份 —— 否则"回滚错了想再回来"就回不去了
/// ③ 覆盖 plugins/<file>.js
/// ④ 更新 meta 的 installed_version
/// ⑤ 热重载
/// ```
///
/// ⚠️ 第 ② 步是**对称性**要求：更新会归档旧版，那回滚也该归档"被换掉的版本"，
///    否则来回几次会把中间版本丢光（用户实测最容易踩的就是"手滑回滚"）。
///
/// ⚠️ **绝不碰 `plugins/.data/`** —— 用户配置必须原样保留（有单测）。
pub async fn rollback_plugin(
    state: &AppState,
    id: &str,
    version: &str,
) -> Result<serde_json::Value, String> {
    let dir = plugins_dir(&state.data_dir);
    let (file, local_src, current_version, meta) = plugin_state(&dir, id)?;

    let all = crate::plugins::list_plugin_versions(&dir, id);
    let Some((_, src_path)) = all.iter().find(|(v, _)| v == version) else {
        let avail: Vec<String> = all.iter().map(|(v, _)| v.clone()).collect();
        return Err(format!(
            "没有找到 {id} 的版本 {version}；可用版本：{}",
            if avail.is_empty() {
                "（无历史档）".to_string()
            } else {
                avail.join(", ")
            }
        ));
    };

    let restore = std::fs::read_to_string(src_path)
        .map_err(|e| format!("读取历史版本失败: {e}"))?;

    // ② 对称归档：把当前版本存下来，让"回滚错了"也能再回来
    let _ = crate::plugins::archive_plugin_version(&dir, id, &current_version, &local_src);

    // ③ 覆盖
    std::fs::write(dir.join(&file), &restore).map_err(|e| format!("写入失败: {e}"))?;

    // ④ meta：版本改回旧的，但**来源链接保持**（回滚不该让插件失去来源，
    //    否则回滚一次就再也检测不了更新了）
    let new_meta = crate::plugins::PluginSourceMeta {
        source_url: meta.as_ref().and_then(|m| m.source_url.clone()),
        installed_version: version.to_string(),
        installed_at: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0),
        file: file.clone(),
    };
    if let Err(e) = crate::plugins::write_plugin_meta(&dir, id, &new_meta) {
        log::warn!("写入插件 meta 失败（不影响回滚）: {e}");
    }

    crate::plugins::prune_plugin_versions(&dir, id);

    // ⑤ 热重载
    reload_plugins(state).await?;

    log::info!("已回滚插件 {id}: v{current_version} → v{version}");

    Ok(serde_json::json!({
        "rolledBack": true,
        "fromVersion": current_version,
        "version": version,
        "file": file,
    }))
}

/// 列出**哪些插件有安装来源**（`{ id: sourceUrl }`）
///
/// # 为什么单独一个命令（而不是塞进 `list_plugins`）
///
/// ```text
/// ① 界面需要它来决定"这张卡要不要显示「检测更新」按钮" ——
///    而这个判断在**页面加载时**就要做。
/// ② 若用 `check_all_plugin_updates` 来判断，会在**打开设置页时
///    对每个插件发一次 HTTP 请求** —— 那是不可接受的
///    （打开设置页要等几秒，还可能被限流）。
/// ③ 所以拆成"纯本地读 sidecar"（本命令，毫秒级、零网络）
///    与"联网检测"（check_*，只在用户点按钮时跑）。
/// ```
///
/// ⚠️ 返回 `map` 而不是 `list`：界面按 `id` 查"有没有来源"，
///    map 是 O(1) 且天然去重。
///
/// ⚠️ **只列出有来源的** —— 没有来源的插件不出现在 map 里，
///    界面查到 `null` 就知道"这个查不了"，**如实不显示按钮**。
pub fn list_plugin_sources(state: &AppState) -> Result<serde_json::Value, String> {
    let dir = plugins_dir(&state.data_dir);
    let (plugins, _failed) = crate::plugins::load_plugins(&dir);
    let mut map = serde_json::Map::new();
    for p in plugins {
        let id = p.manifest().id.clone();
        if let Some(m) = crate::plugins::read_plugin_meta(&dir, &id) {
            if let Some(url) = m.source_url {
                if !url.is_empty() {
                    map.insert(id, serde_json::Value::String(url));
                }
            }
        }
    }
    Ok(serde_json::json!({ "sources": map }))
}

/// 【测试/诊断】把插件标记为"从某链接安装"
///
/// # 为什么需要这个命令
///
/// 本机现有的 26 个插件**全是手动放入的**（没有任何 meta）→
/// 做完功能后界面上**一个「检测更新」按钮都不会出现**，
/// 无法验证 UI 也说不清"功能到底有没有生效"。
///
/// 这个命令让你**指定一个链接**给某个插件（模拟"它当初是从这里装的"），
/// 于是它可以走检测/更新/回滚全流程。
///
/// ⚠️ 它是**真实功能**（不是测试专用开关）：用户也可能想"我这个手动放的插件
///    其实来自这个链接，以后就按它检测更新" —— 这正是合理的用户诉求。
pub fn set_plugin_source(
    state: &AppState,
    id: &str,
    url: &str,
) -> Result<serde_json::Value, String> {
    let dir = plugins_dir(&state.data_dir);
    let (file, _src, version, _old) = plugin_state(&dir, id)?;
    let url = url.trim();
    if url.is_empty() {
        // 传空 = 清除来源（回到"手动放入"状态）
        let p = crate::plugins::plugin_meta_dir(&dir).join(format!("{id}.json"));
        let _ = std::fs::remove_file(p);
        return Ok(serde_json::json!({ "id": id, "sourceUrl": null }));
    }
    let meta = crate::plugins::PluginSourceMeta {
        source_url: Some(url.to_string()),
        installed_version: version,
        installed_at: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0),
        file,
    };
    crate::plugins::write_plugin_meta(&dir, id, &meta)?;
    Ok(serde_json::json!({ "id": id, "sourceUrl": url }))
}

