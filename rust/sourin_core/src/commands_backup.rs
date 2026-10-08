// ═══════════════════════════════════════════════════════════════════════
//  批次 6 · 登录 / 代理 / 备份 / WebDAV 同步（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这批是最大的一批（22 个命令），但结构清晰
//
// ```text
// 登录会话  6 个   薄适配器 → registry / provider
// 代理      7 个   薄适配器 → ProxyStore
// 备份      6 个   中等（backup_import 最厚，173 行）
// 云同步    6 个   薄适配器 → SyncEngine
// ```
//
// # ★ 备份的合并语义（这批最需要小心的地方）
//
// `backup_import` 不是"覆盖"，而是**按时间戳合并**：
// ```text
// 已存在 → 只在新数据更「新」时更新（updated_at 是判据）
// 不存在 → 新增
// ```
// 这样"另一台机器上刚加的关注"能覆盖本机很久以前的记录，
// 反之不会倒退。**不能简化成"导入即覆盖"** —— 那会把用户
// 本机较新的进度打回旧值。

use crate::state::AppState;

/// 插件目录
fn plugins_dir(data_dir: &std::path::Path) -> std::path::PathBuf {
    crate::state::plugins_dir(data_dir)
}

// ═══════════════════════════════════════════════════════════════════════
//  登录 / 会话
// ═══════════════════════════════════════════════════════════════════════

/// 用账号密码登录某个源
pub async fn provider_login(
    state: &AppState,
    provider: &str,
    username: String,
    password: String,
) -> Result<crate::provider::Session, String> {
    let p = state
        .registry
        .get(provider)
        .ok_or_else(|| format!("找不到 Provider: {provider}"))?;
    p.login(crate::provider::Credentials {
        username,
        password,
        extra: Default::default(),
    })
    .await
    .map_err(|e| e.message)
}

/// 登出
pub async fn provider_logout(state: &AppState, provider: &str) -> Result<(), String> {
    let p = state
        .registry
        .get(provider)
        .ok_or_else(|| format!("找不到 Provider: {provider}"))?;
    p.logout().await.map_err(|e| e.message)
}

/// 取当前会话（None = 未登录）
pub async fn provider_session(
    state: &AppState,
    provider: &str,
) -> Result<Option<crate::provider::Session>, String> {
    let p = state
        .registry
        .get(provider)
        .ok_or_else(|| format!("找不到 Provider: {provider}"))?;
    p.session().await.map_err(|e| e.message)
}

/// 取会话状态（是否可用 / 是否需要刷新）—— 设置页据此显示「需要重新登录」
///
/// ⚠️ 源不存在时返回 `None`（不是报错）—— 原版如此。
/// 设置页靠 None 区分「源不在列表里」与「源存在但未登录」。
pub async fn provider_session_state(
    state: &AppState,
    provider: &str,
) -> Result<Option<crate::provider::SessionState>, String> {
    Ok(state.registry.session_state(provider).await)
}

/// 确保会话可用（必要时自动登录）
pub async fn ensure_provider_session(
    state: &AppState,
    provider: &str,
) -> Result<bool, String> {
    state
        .registry
        .ensure_session(provider)
        .await
        .ok_or_else(|| format!("找不到 Provider: {provider}"))
}

/// 忘记某源的凭据
///
/// # ★ 优先走插件的 `forgetCredentials()`
///
/// 插件把自己的凭据存在**插件私有存储**里
/// （`plugins/.data/<id>.json`），而不是应用的系统钥匙串 ——
/// 所以清理由插件自己负责。
///
/// 回退：插件没实现该方法时，用内置源的钥匙串清理
///（cycani 的 Rust 实现仍在源码里，保留兼容）。
pub async fn forget_provider_credentials(
    state: &AppState,
    provider: &str,
) -> Result<(), String> {
    let p = state
        .registry
        .get(provider)
        .ok_or_else(|| format!("找不到 Provider: {provider}"))?;

    if p.has_method("forgetCredentials").await {
        return p.forget_credentials().await.map_err(|e| e.message);
    }

    match provider {
        "cycani" => {
            crate::providers::cycani::forget_credentials().map_err(|e| e.message)?;
            // 同时清掉内存会话，避免出现「凭据没了但 token 还在」的中间态
            let _ = p.logout().await;
            Ok(())
        }
        other => Err(format!("{other} 不支持凭据管理")),
    }
}

/// ★ 申请一个登录二维码（扫码登录第一步，2026-10-05）
///
/// # 与 `provider_login` 的关系
///
/// 扫码与账密是**两条并列的登录路径**，最终都落到 `mediaprovider::session()`
/// 上（插件把扫码换来的 Cookie 存进自己的私有存储），
/// 所以这一层不需要额外写会话。
///
/// # 返回的 `svg` 是谁画的
///
/// **宿主**画的 —— 插件层 `plugins::PluginProvider::qr_login_start`
/// 已经调 `crate::remote::qr_svg_for(&start.url)` 填好，
/// 这里只做透传（与 Tauri 版 `lib.rs` 的 `provider_qr_login_start` 一致）。
///
/// # 不支持扫码的源
///
/// `MediaProvider::qr_login_start` 的默认实现返回
/// `ProviderError::unsupported("该源不支持扫码登录")` —— **如实透传**，
/// 界面据此不显示二维码。不要在这里把它翻译成别的文案，
/// 否则前端分不清「这个源不支持」与「扫码这一步失败了」。
pub async fn provider_qr_login_start(
    state: &AppState,
    provider: &str,
) -> Result<crate::provider::QrLoginStart, String> {
    let p = state
        .registry
        .get(provider)
        .ok_or_else(|| format!("找不到 Provider: {provider}"))?;

    p.qr_login_start().await.map_err(|e| e.message)
}

/// ★ 轮询扫码状态（扫码登录第二步，2026-10-05）
///
/// ⚠️ **由前端按约 2 秒的间隔调用**，直到拿到
///    `confirmed` / `expired` / `failed` 为止。
///    插件实现里**不 sleep**（QuickJS 是单线程，sleep 会占住它），
///    宿主这一层也**不循环** —— 循环会让一次调用阻塞几十秒，
///    界面就没法显示「等待扫码…」。
///
/// `status == confirmed` 时返回的 `session` 里带新会话；
/// `expired` 要重新调 `provider_qr_login_start`。
pub async fn provider_qr_login_poll(
    state: &AppState,
    provider: &str,
    key: &str,
) -> Result<crate::provider::QrLoginPoll, String> {
    let p = state
        .registry
        .get(provider)
        .ok_or_else(|| format!("找不到 Provider: {provider}"))?;

    p.qr_login_poll(key).await.map_err(|e| e.message)
}


// ═══════════════════════════════════════════════════════════════════════
//  站点代理
// ═══════════════════════════════════════════════════════════════════════

/// 全部源的代理配置（provider_id → 配置）
pub fn list_proxy_configs(
    state: &AppState,
) -> Result<std::collections::HashMap<String, crate::proxy::ProxyConfig>, String> {
    Ok(state.proxy.all())
}

/// 设置某源的代理
pub fn set_proxy_config(
    state: &AppState,
    provider: &str,
    config: crate::proxy::ProxyConfig,
) -> Result<(), String> {
    state.proxy.set(provider, config)
}

/// 清除某源的代理
pub fn clear_proxy_config(state: &AppState, provider: &str) -> Result<(), String> {
    state.proxy.clear(provider)
}

/// 设置代理密码
///
/// ⚠️ 注意：这个命令**不需要 AppState** —— 原版签名里没有 state。
/// 密码存在**系统钥匙串**里（不是数据库），所以与 AppState 无关。
pub fn set_proxy_password(provider: &str, password: &str) -> Result<(), String> {
    crate::proxy::set_proxy_password(provider, password)
}

/// 是否已设置代理密码（**不返回密码本身**）
pub fn has_proxy_password(provider: &str) -> Result<bool, String> {
    Ok(crate::proxy::get_proxy_password(provider).is_some())
}

/// 测试代理连通性
pub async fn test_proxy(
    state: &AppState,
    provider: &str,
) -> Result<serde_json::Value, String> {
    let (ok, message) = state.proxy.test(provider).await;
    Ok(serde_json::json!({ "ok": ok, "message": message }))
}

/// 系统代理提示（检测到系统代理时给用户一条提示）
///
/// 静态方法 —— 不需要 AppState。
pub fn system_proxy_hint() -> Result<Option<String>, String> {
    Ok(crate::proxy::ProxyStore::system_proxy_hint())
}

// ═══════════════════════════════════════════════════════════════════════
//  备份
// ═══════════════════════════════════════════════════════════════════════

/// 组装备份内容（导出与"只预览不写盘"共用）
///
/// # 四个部分
///
/// ```text
/// ① watch_data  收藏 / 追更 / 进度 / 历史
/// ② providers   第三方源清单 + 停用名单
/// ③ settings    片头片尾跳过点
/// ④ plugins     插件源码（原样字节）
/// ```
///
/// ⚠️ 历史取 100000 上限 —— **备份要全量**，
///    不能像界面那样只取 100 条（那会让备份"少了一段历史"）。
pub fn build_backup_payload(
    state: &AppState,
) -> Result<crate::backup::BackupPayload, String> {
    let favorites = state.db.list_favorites(true)?;
    let following = state.db.list_following()?;
    let progress = state.db.list_all_progress()?;
    let history = state.db.list_history(100_000)?;
    let watch_data = serde_json::json!({
        "favorites": favorites,
        "following": following,
        "progress": progress,
        "history": history,
    });

    let third_party: serde_json::Value = state
        .third_party
        .read()
        .map_err(|_| "第三方源列表被污染（锁中毒）".to_string())
        .map(|v| serde_json::to_value(&*v).unwrap_or(serde_json::json!([])))?;
    let disabled = super::commands::load_disabled(&state.data_dir);
    let providers = serde_json::json!({
        "third_party": third_party,
        "disabled": disabled,
    });

    let skip = state.db.list_skip_markers()?;
    let settings = serde_json::json!({ "skip_markers": skip });

    // ④ 插件源码（原样字节）
    let pdir = plugins_dir(&state.data_dir);
    let mut plugins = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&pdir) {
        for e in entries.flatten() {
            let p = e.path();
            if p.extension().and_then(|s| s.to_str()) != Some("js") {
                continue;
            }
            let Some(name) = p.file_name().and_then(|s| s.to_str()).map(|s| s.to_string())
            else {
                continue;
            };
            if let Ok(bytes) = std::fs::read(&p) {
                plugins.push((name, bytes));
            }
        }
    }

    let entries: Vec<crate::backup::BackupEntry> = plugins
        .iter()
        .map(|(n, b)| crate::backup::BackupEntry {
            path: format!("plugins/{n}"),
            bytes: b.len() as u64,
        })
        .collect();

    let manifest = crate::backup::BackupManifest {
        version: crate::backup::BACKUP_VERSION,
        exported_at: chrono::Utc::now().timestamp_millis(),
        device_id: state.device_id.clone(),
        app_version: env!("CARGO_PKG_VERSION").to_string(),
        entries,
    };

    Ok(crate::backup::BackupPayload {
        manifest,
        watch_data,
        providers,
        settings,
        plugins,
    })
}

/// 数一个 JSON 数组字段的长度（备份预览用）
fn arr_len(v: &serde_json::Value, k: &str) -> usize {
    v.get(k)
        .and_then(|x| x.as_array())
        .map(|a| a.len())
        .unwrap_or(0)
}

/// 备份预览（不写盘，只报告"会导出什么"）
pub fn backup_preview(state: &AppState) -> Result<serde_json::Value, String> {
    let p = build_backup_payload(state)?;
    Ok(serde_json::json!({
        "version": p.manifest.version,
        "deviceId": p.manifest.device_id,
        "appVersion": p.manifest.app_version,
        "counts": {
            "favorites": arr_len(&p.watch_data, "favorites"),
            "following": arr_len(&p.watch_data, "following"),
            "progress": arr_len(&p.watch_data, "progress"),
            "history": arr_len(&p.watch_data, "history"),
            "skipMarkers": arr_len(&p.settings, "skip_markers"),
            "plugins": p.plugins.len(),
            "providers": arr_len(&p.providers, "third_party"),
        },
        "plugins": p.plugins.iter()
            .map(|(k, v)| serde_json::json!({"name": k, "bytes": v.len()}))
            .collect::<Vec<_>>(),
    }))
}

/// 备份的默认文件名（含设备 id 与日期）
pub fn backup_default_name(state: &AppState) -> Result<String, String> {
    Ok(crate::backup::default_backup_name(&state.device_id))
}

/// 导出备份到指定路径
pub fn backup_export(
    state: &AppState,
    path: &str,
) -> Result<serde_json::Value, String> {
    let payload = build_backup_payload(state)?;
    let p = std::path::PathBuf::from(path);
    let size = crate::backup::write_backup(&p, &payload)?;
    log::info!("已导出备份到 {path}（{size} 字节）");
    Ok(serde_json::json!({ "path": path, "bytes": size }))
}

/// 检视一个备份文件（不导入，只报告内容）
///
/// ⚠️ 不需要 AppState —— 纯读文件。
pub fn backup_inspect(path: &str) -> Result<serde_json::Value, String> {
    let c = crate::backup::read_backup(std::path::Path::new(path))?;
    Ok(serde_json::json!({
        "version": c.manifest.version,
        "deviceId": c.manifest.device_id,
        "appVersion": c.manifest.app_version,
        "exportedAt": c.manifest.exported_at,
        "counts": {
            "favorites": arr_len(&c.watch_data, "favorites"),
            "following": arr_len(&c.watch_data, "following"),
            "progress": arr_len(&c.watch_data, "progress"),
            "history": arr_len(&c.watch_data, "history"),
            "skipMarkers": arr_len(&c.settings, "skip_markers"),
            "plugins": c.plugins.len(),
            "providers": arr_len(&c.providers, "third_party"),
        },
        "plugins": c.plugins.iter()
            .map(|(k, v)| serde_json::json!({"name": k, "bytes": v.len()}))
            .collect::<Vec<_>>(),
    }))
}

/// 抓取平台自带历史并保存为备份镜像（**只读，不回写**）
pub async fn backup_platform_history(
    state: &AppState,
    provider: &str,
    device_id: Option<String>,
) -> Result<usize, String> {
    let p = state
        .registry
        .get(provider)
        .ok_or_else(|| format!("找不到 Provider: {provider}"))?;

    let records = p.platform_history().await.map_err(|e| e.message)?;
    let dev = device_id.unwrap_or_else(|| "default".into());
    state
        .db
        .save_platform_history(provider, &dev, &records)
}

// ═══════════════════════════════════════════════════════════════════════
//  导入（本批次最厚的一个 —— 173 行）
// ═══════════════════════════════════════════════════════════════════════
//
// # ★★ 核心语义：**按时间戳合并，不是覆盖**
//
// ```text
// 已存在 → 只在新数据更「新」时更新（updated_at 是判据）
// 不存在 → 新增
// ```
// 这样"另一台机器上刚加的关注"能覆盖本机很久以前的记录，
// 反之不会倒退。
//
// **不能简化成"导入即覆盖"** —— 那会把用户本机较新的进度打回旧值。
// 这是"导入备份"最容易写错的地方：直觉上"导入 = 恢复成备份里的样子"，
// 但备份可能是三天前的，而本机这两天又看了几集。
//
// # 六类数据的合并策略各不相同
//
// ```text
// ① 收藏/追更  按 updated_at 取新；**保留本机的分组/别名**
// ② 进度       按 updated_at 取新（不倒退）
// ③ 历史       直接追加（"看过"的记录无冲突概念）
// ④ 片头片尾   按 updated_at 取新
// ⑤ 源配置     只补新的，**同 id 保留本机的**
// ⑥ 插件       同名内容相同则跳过；不同才改名保存
// ```
/// ★ 真正的导入实现（同步）—— **不要直接调它**，用 [`backup_import`]
///
/// 抽出来的原因见下面 `backup_import` 的注释：导入末尾要重新注册插件，
/// 而那是 async 的（要执行 JS）。本函数只负责 ①～⑥ 段的数据合并。
fn backup_import_sync(
    state: &AppState,
    path: &str,
) -> Result<crate::backup::ImportSummary, String> {
    let c = crate::backup::read_backup(std::path::Path::new(path))?;
    let mut sum = crate::backup::ImportSummary::default();

    // ── ① 收藏 / 追更：合并 ──
    //
    // 闭包捕获 `sum` 与 `state` 的可变/不可变借用，
    // 用局部闭包避免写两遍几乎相同的代码。
    {
        let mut merge_favs = |arr: Option<&Vec<serde_json::Value>>, is_follow: bool| {
            let Some(arr) = arr else { return };
            for item in arr {
                let Ok(mut f) =
                    serde_json::from_value::<crate::store::Favorite>(item.clone())
                else {
                    sum.skipped.push("有一条收藏格式不符，已跳过".into());
                    continue;
                };
                let existed = state.db.get_favorite(&f.key).ok().flatten();
                match &existed {
                    None => {
                        if is_follow {
                            sum.following_added += 1;
                        } else {
                            sum.favorites_added += 1;
                        }
                    }
                    Some(old) => {
                        /*
                         * 已存在 → **只在新数据更「新」时更新**
                         *
                         * `updated_at` 是判据。这样"另一台机器上刚加的关注"
                         * 能覆盖本机很久以前的记录，反之不会倒退。
                         */
                        if f.updated_at <= old.updated_at {
                            continue;
                        }
                        // 合并时保留本机的分组/别名（用户可能在本机整理过）
                        if f.group_name.is_none() {
                            f.group_name = old.group_name.clone();
                        }
                        if f.note.is_none() {
                            f.note = old.note.clone();
                        }
                        sum.favorites_updated += 1;
                    }
                }
                if let Err(e) = state.db.upsert_favorite(&f) {
                    sum.skipped.push(format!("收藏 {} 写入失败: {e}", f.key));
                }
            }
        };

        let wd = &c.watch_data;
        merge_favs(wd.get("favorites").and_then(|x| x.as_array()), false);
        merge_favs(wd.get("following").and_then(|x| x.as_array()), true);
    }

    // ── ② 进度：按时间戳取新 ──
    if let Some(arr) = c.watch_data.get("progress").and_then(|x| x.as_array()) {
        for item in arr {
            let Ok(p) = serde_json::from_value::<crate::store::Progress>(item.clone())
            else {
                sum.skipped.push("有一条进度格式不符，已跳过".into());
                continue;
            };
            let old = state.db.get_progress(&p.key).ok().flatten();
            /*
             * 本机更新 → 跳过（不倒退）
             *
             * 草稿：「同一集两台机器都看过，取看得更晚的那次」。
             */
            if let Some(o) = &old {
                if p.updated_at <= o.updated_at {
                    continue;
                }
            }
            if state.db.upsert_progress(&p).is_ok() {
                sum.progress_updated += 1;
            }
        }
    }

    // ── ③ 历史：合并（history 表是"看过"的记录，无冲突概念）──
    if let Some(arr) = c.watch_data.get("history").and_then(|x| x.as_array()) {
        for item in arr {
            let Ok(h) =
                serde_json::from_value::<crate::store::HistoryEntry>(item.clone())
            else {
                continue;
            };
            if state.db.add_history(&h).is_ok() {
                sum.history_added += 1;
            }
        }
    }

    // ── ④ 片头片尾：按时间戳取新 ──
    if let Some(arr) = c.settings.get("skip_markers").and_then(|x| x.as_array()) {
        for item in arr {
            let Ok(m) = serde_json::from_value::<crate::store::SkipMarker>(item.clone())
            else {
                sum.skipped.push("有一条片头片尾设置格式不符，已跳过".into());
                continue;
            };
            let old = state.db.get_skip_marker(&m.key).ok().flatten();
            if let Some(o) = &old {
                if m.updated_at <= o.updated_at {
                    continue;
                }
            }
            if state.db.upsert_skip_marker(&m).is_ok() {
                sum.skip_updated += 1;
            }
        }
    }

    // ── ⑤ 源配置：合并（只补新的，不覆盖本机已有的）──
    if let Some(arr) = c.providers.get("third_party").and_then(|x| x.as_array()) {
        let mut list = state
            .third_party
            .read()
            .map_err(|_| "第三方源列表被污染（锁中毒）".to_string())?
            .clone();
        for item in arr {
            let Ok(pp) =
                serde_json::from_value::<crate::model::PersistedProvider>(item.clone())
            else {
                continue;
            };
            /*
             * 同 id 视为同一个源 —— **保留本机的**（用户可能在本机改过地址）
             *
             * 草稿说「源配置让用户选：合并 / 覆盖」，
             * 这里实现的是**安全默认**（合并且不动本机已有的）：
             * 覆盖是破坏性的，应该让用户明确选一次；
             * 而"合并"永远不会丢数据，所以选它当默认。
             *
             * ⚠️ `PersistedProvider` 是 enum（Declarative / Http），
             *    用它的 `id()` 方法取 id（字段名两边不同，不能直接点出来）。
             */
            if list.iter().any(|x| x.id() == pp.id()) {
                continue;
            }
            list.push(pp);
            sum.providers_imported += 1;
        }
        if sum.providers_imported > 0 {
            *state
                .third_party
                .write()
                .map_err(|_| "第三方源列表被污染（锁中毒）".to_string())? = list.clone();
            crate::persist::save_persisted(&state.data_dir, &list)?;
        }
    }

    // ── ⑥ 插件：同名时**内容相同就跳过**，不同才改名保存 ──
    let pdir = plugins_dir(&state.data_dir);
    for (name, bytes) in &c.plugins {
        match crate::backup::write_plugin_file(&pdir, name, bytes) {
            Ok((final_name, renamed, skipped)) => {
                if skipped {
                    // 幂等：重复导入同一个包不会产生副本（实测踩到的坑）
                    continue;
                }
                if renamed {
                    sum.plugins_renamed.push(final_name);
                } else {
                    sum.plugins_written.push(final_name);
                }
            }
            Err(e) => sum.skipped.push(format!("插件 {name} 写入失败: {e}")),
        }
    }

    log::info!(
        "已导入备份 {path}：收藏 +{} 更新{}，进度更新{}，历史 +{}，跳过点更新{}，插件 {}+{}",
        sum.favorites_added,
        sum.favorites_updated,
        sum.progress_updated,
        sum.history_added,
        sum.skip_updated,
        sum.plugins_written.len(),
        sum.plugins_renamed.len()
    );
    Ok(sum)
}

/// 导入备份（★ 唯一入口 —— 会顺带**重新注册刚写进来的插件**）
///
/// ══════════════════════════════════════════════════════════════════
/// ★★★ 2026-10-08（业主报的 bug）：⑥ 段写完 .js 之后**必须**重新注册
/// ══════════════════════════════════════════════════════════════════
///
/// ```text
/// 现象（业主原话）：
///   「导入备份之后出现这个错误,点击重新加载插件才加载成功」
///   —— 「JS 插件」页里 24 个条目全红：`xxx.js · 已解析但未注册`
///
/// 根因：
///   原实现（现在的 backup_import_sync）只把 .js **写到盘上**，
///   从不往 `state.registry` 里注册。而 `list_plugins()`
///   （commands_provider.rs:341-416）的判据是
///     registered = state.registry.manifests()
///     loaded     = crate::plugins::load_plugins(&dir)
///   ⇒ 文件能解析（loaded 里有）但 registered 里找不到
///   ⇒ 走进 :396 那个分支，文案「已解析但未注册」
///     （那里的注释原文就写着「不应该发生，记下来便于排查」）
///
///   UI 上点一次「重新加载插件」就好了 —— 因为那条路走的是
///   commands_provider::reload_plugins()，它才是对的。
/// ```
///
/// # 为什么不像 `reload_plugins` 那样「先摘再挂」
///
/// 这里是**新装的**插件（磁盘上刚出现、registry 里本来就没有同名 id），
/// 摘一次没有意义；而 `reload_plugins` 要「先摘」是因为它面对的是
/// **已经在册**的插件，不摘会有两份实例（注释见 commands_provider.rs:252）。
///
/// ⚠️ 重复导入同一个包时 ⑥ 段会 `skipped = true` 直接 continue，
///    但注册这一步仍然要跑 —— 幂等靠 `registry.register` 覆盖同名 id。
///
/// # 为什么要 async
///
/// `load_plugins_hydrated` 要执行 JS 拿能力位，是 async 的
/// （与 `reload_plugins` 同因）。ffi 那边对应改走 `with_state_async`。
pub async fn backup_import(
    state: &AppState,
    path: &str,
) -> Result<crate::backup::ImportSummary, String> {
    let mut sum = backup_import_sync(state, path)?;

    // ── ⑦ 插件注册（⑥ 段写完盘之后）──
    let dir = plugins_dir(&state.data_dir);
    let (plugins, failed) =
        crate::plugins::load_plugins_hydrated(&dir, Some(state.proxy.clone())).await;
    for (f, why) in &failed {
        log::warn!("插件 {f} 加载失败: {why}");
    }
    for p in plugins {
        let id = crate::provider::MediaProvider::manifest(&p).id.clone();
        state.registry.register(std::sync::Arc::new(p));
        sum.plugins_registered += 1;
        log::info!("导入后已注册插件 {id}");
    }

    /*
     * ★ 标记「内容源配置刚被改过」
     *
     * 漏掉它的表现：导入完源配置，云同步时被误判成「远端更新」，
     * 把用户刚导入的源打回云端那份（同 remove_provider 的注释）。
     */
    if sum.providers_imported > 0 {
        crate::commands_provider::touch_providers(state);
    }

    Ok(sum)
}

// ═══════════════════════════════════════════════════════════════════════
//  云盘同步（WebDAV）
// ═══════════════════════════════════════════════════════════════════════

/// 配置 WebDAV 同步
///
/// # ★ 顺序不能反：先 `prepare()` 再 `test()`（原版 2026-09-15 修的 bug）
///
/// `test()` 会 PROPFIND **含 `remote_dir` 的完整路径**，
/// 而该目录此时还不存在 → 返回 404 →
/// 报「路径不存在：请确认 WebDAV 地址包含目标目录」——
/// **用户明明填对了地址却被告知路径错**（原版实测踩到）。
///
/// `prepare()` 会把 `remote_dir` 逐级建出来（已存在则无操作），
/// 之后 `test()` 就能正确判定「地址/凭据是否可用」。
///
/// # 密码为空时沿用钥匙串里已存的
///
/// 支持"用户只改地址"的场景 —— 否则改地址就得重新输密码。
pub async fn configure_webdav(
    state: &AppState,
    base_url: String,
    username: String,
    password: String,
    remote_dir: Option<String>,
) -> Result<String, String> {
    // 密码为空时沿用钥匙串里已存的（用户只改地址的场景）
    let password = if password.is_empty() {
        crate::sync::webdav_credential::get("webdav").unwrap_or_default()
    } else {
        crate::sync::webdav_credential::set("webdav", &password)?;
        password
    };

    let cfg = crate::sync::WebdavConfig {
        base_url,
        username,
        password,
        remote_dir: remote_dir.unwrap_or_default(),
    };
    // ★ 落盘要用的三个字段 —— `cfg` 马上会被 move 进引擎，先留副本
    let saved_base = cfg.base_url.clone();
    let saved_user = cfg.username.clone();
    let saved_dir = cfg.remote_dir.clone();
    let engine =
        crate::sync::SyncEngine::new_webdav(cfg, state.db.clone(), state.device_id.clone())?;

    // ★ 先建目录，再自检（顺序不能反 —— 见函数文档）
    engine.prepare().await?;

    // ★ 立即自检：配错地址/密码当场就能发现，而不是等到同步时才报错
    let msg = engine.test().await?;

    *state.sync.write().await = Some(std::sync::Arc::new(engine));

    /*
     * ★ 持久化连接字段（契约 §3①，2026-09-29）
     *
     * 改之前 `WebdavConfig` **只在内存**：重启后 `sync_status` 必然
     * connected:false ⇒ 用户每次开机都要重配一遍，自动备份根本无从谈起。
     *
     * ⚠️ 只写这三个字段 —— 偏好字段（保留份数 / 自动开关…）属于同一个
     *    文件，`load_settings` 已经读到了最新值，逐字段赋值不会把它们覆盖成旧的。
     *    ★ 密码**不在这里**（钥匙串，见文件头）。
     */
    let mut s = crate::sync::load_settings(&state.data_dir);
    s.base_url = saved_base;
    s.username = saved_user;
    s.remote_dir = saved_dir;
    crate::sync::save_settings(&state.data_dir, &s)?;

    // ★ 起自动同步循环（幂等：`auto_loop_started` 守着）
    //    只有真正配好之后才需要它 —— bootstrap 恢复失败时也就不会起。
    if let Some(arc) = crate::ffi::state() {
        spawn_auto_sync(arc);
    }
    Ok(msg)
}

/// 断开云盘（清除内存里的引擎，**不动钥匙串里的凭据**）
pub async fn disconnect_sync(state: &AppState) -> Result<(), String> {
    *state.sync.write().await = None;

    /*
     * ★ 修订 #1（2026-09-29）：只清**连接字段**，保留**偏好字段**。
     *
     * 清掉 baseUrl / username / remoteDir 就足以让 bootstrap 不再重建引擎
     * （它的判据正是这两个非空 + 钥匙串里有密码）。
     *
     * ⚠️ 早先的写法是「删掉整个 sync-settings.json」—— 那会把用户刚设好的
     *    保留份数与自动备份开关一起删掉，Dart 侧读回只剩默认值，
     *    用户会觉得「设置没保存」。所以四个偏好字段必须原样留着。
     */
    let mut s = crate::sync::load_settings(&state.data_dir);
    s.base_url.clear();
    s.username.clear();
    s.remote_dir.clear();
    crate::sync::save_settings(&state.data_dir, &s)?;
    log::info!("已断开云盘（连接字段已清空，保留份数与自动备份设定保留）");
    Ok(())
}

/// 同步状态（设置页据此显示「已连接 / 未配置」）
pub async fn sync_status(state: &AppState) -> Result<serde_json::Value, String> {
    let settings = crate::sync::load_settings(&state.data_dir);
    let (connected, backend) = {
        let guard = state.sync.read().await;
        match guard.as_ref() {
            // ★ 必须 `to_string()` —— `backend_name()` 返回 `&str`，借用自 `guard`，而它马上要被 drop
            Some(e) => (true, Some(e.backend_name().to_string())),
            None => (false, None),
        }
    };

    /*
     * ★ 返回值从「内存里有没有引擎」扩成了**设置文件的内容**（契约 §2）。
     *
     * 原因：`configure_webdav` 现在会把连接字段落盘、bootstrap 会读回来，
     * 所以设置文件才是**权威**（重启之后引擎也是从它建出来的）。
     * 设置页同时需要保留份数 / 自动开关这些字段，一次读完最省事。
     *
     * ⚠️ 但 `deviceId` / `backend` **必须保留** ——
     *    `tests/batch6_backup.rs` 断言 `s["deviceId"].is_string()`，
     *    而 Dart 侧 `SyncStatus.deviceId` 与设置页、关于页都在显示它。
     *    它们不属于设置文件，所以在这里补进去（而不是塞进
     *    `to_public_json`）。
     */
    let mut v = settings.to_public_json(connected);
    if let Some(o) = v.as_object_mut() {
        o.insert(
            "deviceId".to_string(),
            serde_json::json!(state.device_id.clone()),
        );
        if let Some(b) = backend {
            o.insert("backend".to_string(), serde_json::json!(b));
        }
    }
    Ok(v)
}

/// 测试云盘连通性
pub async fn test_sync(state: &AppState) -> Result<String, String> {
    let e = state
        .sync
        .read()
        .await
        .clone()
        .ok_or_else(|| "尚未配置云盘".to_string())?;
    e.test().await
}

/// 立即同步
///
/// # 三步
///
/// ```text
/// 1) 收藏 + 进度 + manifest
/// 2) 内容源配置（LWW 合并）
/// 3) ★ 若远端胜出，把合并结果**真正生效**
/// ```
///
/// ⚠️ 第 3 步的 `if merged != local` 判断不能省 ——
/// 否则**每次同步都重建全部源**（几十个插件重新加载，
/// 用户会看到界面卡一下，而且没必要）。
pub async fn sync_now(
    state: &AppState,
) -> Result<Vec<crate::sync::SyncSummary>, String> {
    let e = state
        .sync
        .read()
        .await
        .clone()
        .ok_or_else(|| "尚未配置云盘".to_string())?;

    // 1) 收藏 + 进度 + manifest
    let mut out = e.sync_all().await?;

    // 2) 内容源配置
    let (local, local_at) = {
        let list = state
            .third_party
            .read()
            .map_err(|_| "第三方源列表被污染".to_string())?;
        (
            list.clone(),
            state
                .providers_updated_at
                .load(std::sync::atomic::Ordering::SeqCst),
        )
    };

    let (merged, summary) = e.sync_provider_configs(local.clone(), local_at).await?;
    out.push(summary);

    // 3) 若远端胜出，需要把合并结果**真正生效**
    //    仅当内容与本地不同才动手，避免每次同步都重建全部源
    if merged != local {
        apply_merged_providers(state, merged).await?;
        log::info!("内容源配置已按云端版本更新");
    }

    Ok(out)
}

/// 把合并后的源配置应用到运行时
///
/// # 要做的三件事
///
/// ```text
/// ① 更新内存里的 third_party 清单
/// ② 落盘（否则重启后又变回旧的）
/// ③ 重新注册到 registry（否则用户看不到变化）
/// ```
/// 漏掉 ③ 的表现是「同步说成功了，但界面上的源没变」——
/// 要等重启才生效，用户会以为同步坏了。
async fn apply_merged_providers(
    state: &AppState,
    merged: Vec<crate::model::PersistedProvider>,
) -> Result<(), String> {
    // ① 更新内存
    {
        let mut list = state
            .third_party
            .write()
            .map_err(|_| "第三方源列表被污染（锁中毒）".to_string())?;
        *list = merged.clone();
    }
    // ② 落盘
    crate::persist::save_persisted(&state.data_dir, &merged)?;

    // ③ 重新注册 —— 摘掉所有 kind=="js" 的，再按新清单重建
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
    let dir = plugins_dir(&state.data_dir);
    let (plugins, _failed) =
        crate::plugins::load_plugins_hydrated(&dir, Some(state.proxy.clone())).await;
    for p in plugins {
        state.registry.register(std::sync::Arc::new(p));
    }

    crate::commands_provider::touch_providers(state);
    Ok(())
}

/// 同步某源的平台历史（同时存本地镜像）
pub async fn sync_platform_history(
    state: &AppState,
    provider: &str,
) -> Result<usize, String> {
    let e = state
        .sync
        .read()
        .await
        .clone()
        .ok_or_else(|| "尚未配置云盘".to_string())?;

    let p = state
        .registry
        .get(provider)
        .ok_or_else(|| format!("找不到 Provider: {provider}"))?;

    let records = p.platform_history().await.map_err(|e| e.message)?;
    let n = e.backup_platform_history(provider, &records).await?;

    // 同时存进本地备份平面（本地也留一份镜像）
    state
        .db
        .save_platform_history(provider, &state.device_id, &records)?;

    Ok(n)
}


// ══════════════════════════════════════════════════════════════════════
//  ★ 云盘设置 / 整体备份 / 自动同步（契约 §1 §6，2026-09-29 task-75）
// ═══════════════════════════════════════════════════════════════════
//
// 这一组命令与上面「批次 6」的差别：它们**不需要已连接**。
// Dart 侧首次进设置页就会调 `sync_settings_get`，那时用户还没配云盘；
// 一报错 UI 就得走降级分支（契约 §3.1）。

/// 读云盘设置 —— ★ **永不失败**（契约 §3.1）
///
/// 纯本地文件读，不碰网络：文件不存在 / JSON 坏 / 字段缺 ⇒ 一律返回
/// 默认值（`load_settings` 自己就是这么写的）。
///
/// ⚠️ 返回 `Result` 只是因为 FFI 层的统一签名（`with_state_async` 要求
///    `Result<T, String>`）—— **实际上不会返回 `Err`**。
pub async fn sync_settings_get(state: &AppState) -> Result<serde_json::Value, String> {
    let s = crate::sync::load_settings(&state.data_dir);
    let connected = state.sync.read().await.is_some();
    Ok(s.to_public_json(connected))
}

/// 改云盘设置（只改传进来的字段，`None` = 不动）—— ★ **不需要已连接**
///
/// 返回改完之后的**完整设置**（同 §2），Dart 侧拿到就可以直接刷 UI，
/// 不用再调一次 `sync_settings_get`。
pub async fn sync_settings_set(
    state: &AppState,
    retain_count: Option<u32>,
    auto_enabled: Option<bool>,
    auto_interval_minutes: Option<u32>,
    auto_on_change: Option<bool>,
    auto_backup_interval_minutes: Option<u32>,
) -> Result<serde_json::Value, String> {
    let mut s = crate::sync::load_settings(&state.data_dir);
    if let Some(v) = retain_count {
        s.retain_count = v;
    }
    if let Some(v) = auto_enabled {
        s.auto_enabled = v;
    }
    if let Some(v) = auto_interval_minutes {
        s.auto_interval_minutes = v;
    }
    if let Some(v) = auto_on_change {
        s.auto_on_change = v;
    }
    if let Some(v) = auto_backup_interval_minutes {
        s.auto_backup_interval_minutes = v;
    }
    crate::sync::save_settings(&state.data_dir, &s)?;
    log::info!(
        "云盘设置已更新：保留 {} 份 / 自动 {} / 增量 {} 分钟 / 变动即同步 {} / 整包 {} 分钟",
        s.retain_count,
        s.auto_enabled,
        s.auto_interval_minutes,
        s.auto_on_change,
        s.auto_backup_interval_minutes
    );
    let connected = state.sync.read().await.is_some();
    Ok(s.to_public_json(connected))
}

/// 立即上传一份**整体备份**到云盘，并按保留份数清理旧份
///
/// # 为什么打包在这里、传输在 `SyncEngine`
///
/// 打包要读 `AppState`（registry / 插件目录 / 各张表），那是命令层的事；
/// `SyncEngine::backup_snapshot` 只管「传上去 + 清理旧的」。
///
/// ★ 内容与「导出备份」是**同一份字节**（都经 `write_backup_to_vec`）。
pub async fn sync_backup_now(state: &AppState) -> Result<crate::sync::BackupOutcome, String> {
    let engine = state
        .sync
        .read()
        .await
        .clone()
        .ok_or_else(|| "尚未配置云盘".to_string())?;

    let s = crate::sync::load_settings(&state.data_dir);
    let name = crate::backup::default_backup_name(&state.device_id);
    let payload = build_backup_payload(state)?;
    let bytes = crate::backup::write_backup_to_vec(&payload)?;
    let outcome = engine.backup_snapshot(&name, &bytes, s.retain_count).await?;

    /*
     * ★ 手动备份也要推进水位 + 记下签名。
     *
     * 否则自动循环下一轮发现 `now - lastBackupAt` 超过间隔，
     * 会**立刻再传一份内容完全相同的 zip** ——
     * 用户刚点完「立即备份」就看到云端多了两份，会以为程序有 bug。
     * 同样的道理，`last_backup_signature` 也要跟上（契约 §5 的跳过规则）。
     *
     * ⚠️ 这里读不到当前签名也不能让备份本身报错（它已经传上去了）
     *    ⇒ 失败时空串，下一轮会重新算。
     */
    let mut s2 = s;
    s2.last_backup_at = chrono::Utc::now().timestamp_millis();
    s2.last_backup_signature = crate::sync::data_signature(&state.db).unwrap_or_default();
    if let Err(e) = crate::sync::save_settings(&state.data_dir, &s2) {
        log::warn!("备份已完成，但水位没写进设置文件（下一轮可能多传一份）: {e}");
    }
    Ok(outcome)
}

/// 列出云端的整体备份（新的在前）
///
/// ★ 契约 §3.1：**没有引擎时返回空数组 `[]`**，不是报错 ——
/// UI 会无条件调它（设置页一进来就拉列表）。
pub async fn sync_backup_list(
    state: &AppState,
) -> Result<Vec<serde_json::Value>, String> {
    let Some(engine) = state.sync.read().await.clone() else {
        return Ok(Vec::new());
    };
    let entries = engine.list_snapshots().await?;
    Ok(entries
        .into_iter()
        .map(|e| {
            serde_json::json!({
                "name": e.name,
                "bytes": e.bytes,
                // 契约 §1：毫秒时间戳，解析不出填 0
                "modified": e.modified_ms,
            })
        })
        .collect())
}

/// 删除云端某一份备份（`{"deleted": bool}`）
///
/// 名字不合规（不是 `dsh-backup-*.zip`）时 `SyncEngine::delete_snapshot` 会拒绝
/// 并返回 `Ok(false)` —— **不报错**，让 UI 自己决定怎么提示。
pub async fn sync_backup_delete(
    state: &AppState,
    name: &str,
) -> Result<serde_json::Value, String> {
    let engine = state
        .sync
        .read()
        .await
        .clone()
        .ok_or_else(|| "尚未配置云盘".to_string())?;
    let deleted = engine.delete_snapshot(name).await?;
    Ok(serde_json::json!({ "deleted": deleted }))
}

// ────────────────────── 自动同步循环（契约 §6）─────────────────────

/// 自动同步循环的 tick 间隔（契约 §6：每 60 秒醒一次）
const AUTO_TICK_SECS: u64 = 60;

/// 单次 tick 里所有网络操作的超时（契约 §6：建议 120s）
///
/// ★ 没有它的后果：一次请求卡死（如网络半开）会让整个循环
/// **永久停摆** —— 后面再也不会同步，而用户只会看到「自动同步不工作」。
const AUTO_TICK_TIMEOUT_SECS: u64 = 120;

/// ★ 起自动同步循环（**幂等**）
///
/// # 幂等靠 `AppState::auto_loop_started` 的 `compare_exchange`
///
/// 两个调用点（`bootstrap` 恢复成功 / `configure_webdav` 配好）可能先后都跑到，
/// 没有守卫就会起两个循环 ⇒ 每分钟两次同步、两次备份。
///
/// # 为什么不在这里判 `autoEnabled`
///
/// 用户可能**先配云盘、后开自动开关**（设置页上是两个独立操作）。
/// 这里就 return 的话，循环永远不会起，用户打开开关也没用。
/// 所以**只要有引擎就起**，开关的判断放在每一轮 tick 里（重读设置文件）。
pub fn spawn_auto_sync(state: &std::sync::Arc<AppState>) {
    use std::sync::atomic::Ordering;
    if state
        .auto_loop_started
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return; // 已经有一个循环在跑
    }

    let st = state.clone();
    tokio::spawn(async move {
        log::info!("自动同步循环已启动（每 {AUTO_TICK_SECS} 秒检查一次是否到期）");
        loop {
            /*
             * ★ 先睡再干活。
             *
             * 启动瞬间首页正在拉数据，这时去同步会跟用户抢网络与
             * 数据库锁。而且刚启动时 `lastSignature` 还是上次退出前的值，
             * 立刻同步反而会多一次没必要的拉取。
             */
            tokio::time::sleep(std::time::Duration::from_secs(AUTO_TICK_SECS)).await;
            if let Err(e) = run_auto_tick(&st).await {
                // 契约 §6：失败只 warn，**不更新 lastSyncAt**（下一轮 60 秒后重试）
                log::warn!("自动同步本轮跳过（下一轮重试）: {e}");
            }
        }
    });
}

/// 一次自动同步 tick（契约 §6 的三步）
///
/// 为什么抽成独立函数：`spawn_auto_sync` 里那个 `loop` 无法单测，
/// 而「到期判断」是整个特性里最容易出错的地方。
pub async fn run_auto_tick(state: &AppState) -> Result<(), String> {
    // ① 重读设置（用户可能刚改了）
    let mut s = crate::sync::load_settings(&state.data_dir);
    if !s.auto_enabled {
        return Ok(());
    }
    let Some(engine) = state.sync.read().await.clone() else {
        return Ok(()); // 还没配云盘：不是错误，继续睡
    };

    let now = chrono::Utc::now().timestamp_millis();
    let interval_ms = (s.auto_interval_minutes as i64).saturating_mul(60_000);
    let due_by_interval = s.auto_interval_minutes > 0 && now.saturating_sub(s.last_sync_at) >= interval_ms;

    let sig = crate::sync::data_signature(&state.db)?;
    // 签名不变 ⇒ **一次请求都不发**（这就是「耗很低的流量」）
    let due_by_change = s.auto_on_change && sig != s.last_signature;
    if !due_by_interval && !due_by_change {
        return Ok(());
    }
    log::debug!(
        "自动同步到期：间隔={due_by_interval} 变动={due_by_change}"
    );

    /*
     * ★ 增量同步（与 `sync_now` 等价，但不报错给用户）
     *
     * 全包在一个 `timeout` 里：一次卡住不能让循环永久停摆（契约 §6）。
     */
    let work = async {
        engine.sync_all().await?;
        let (local, local_at) = {
            let list = state
                .third_party
                .read()
                .map_err(|_| "第三方源列表被污染（锁中毒）".to_string())?;
            (
                list.clone(),
                state
                    .providers_updated_at
                    .load(std::sync::atomic::Ordering::SeqCst),
            )
        };
        let (merged, _summary) = engine.sync_provider_configs(local.clone(), local_at).await?;
        // ★ 这个判断不能省 —— 否则每轮都重建全部源
        if merged != local {
            apply_merged_providers(state, merged).await?;
            log::info!("内容源配置已按云端版本更新（自动同步）");
        }
        Ok::<(), String>(())
    };

    match tokio::time::timeout(std::time::Duration::from_secs(AUTO_TICK_TIMEOUT_SECS), work).await {
        Ok(Ok(())) => {}
        Ok(Err(e)) => return Err(e),
        Err(_) => {
            return Err(format!(
                "超时（超过 {AUTO_TICK_TIMEOUT_SECS} 秒，已放弃本轮）"
            ))
        }
    }

    /*
     * ★ 到这里增量同步已成功 ⇒ 才能推进水位。
     *
     * 签名**重算**（而不用上面的 `sig`）：这一轮可能从云端拉回了新数据，
     * 用旧签名会让下一轮又判定「变动了」，白多一轮请求。
     */
    let sig_after = crate::sync::data_signature(&state.db).unwrap_or(sig);
    s.last_sync_at = now;
    s.last_signature = sig_after.clone();

    // ② 整包备份（★ 独立节奏：`autoBackupIntervalMinutes`，0 = 关）
    if s.auto_backup_interval_minutes > 0 {
        let backup_ms = (s.auto_backup_interval_minutes as i64).saturating_mul(60_000);
        if now.saturating_sub(s.last_backup_at) >= backup_ms {
            if !s.last_backup_signature.is_empty() && s.last_backup_signature == sig_after {
                /*
                 * 契约 §5：数据自上次备份以来没变 ⇒ 跳过上传，
                 * 但**仍然推进 `lastBackupAt`** —— 否则每 60 秒重试一次。
                 */
                s.last_backup_at = now;
                log::debug!("自动备份：数据自上次备份以来无变化，跳过整包上传");
            } else {
                let name = crate::backup::default_backup_name(&state.device_id);
                let payload = build_backup_payload(state)?;
                let bytes = crate::backup::write_backup_to_vec(&payload)?;
                let up = engine.backup_snapshot(&name, &bytes, s.retain_count);
                match tokio::time::timeout(
                    std::time::Duration::from_secs(AUTO_TICK_TIMEOUT_SECS),
                    up,
                )
                .await
                {
                    Ok(Ok(o)) => {
                        s.last_backup_at = now;
                        s.last_backup_signature = sig_after;
                        log::info!(
                            "自动整包备份完成：{}（{} 字节，清理 {} 份）",
                            o.name,
                            o.bytes,
                            o.pruned.len()
                        );
                    }
                    // ★ 备份失败不影响增量同步的成果（它已经推进了水位）
                    Ok(Err(e)) => {
                        log::warn!("自动整包备份失败（下一轮重试）: {e}")
                    }
                    Err(_) => log::warn!(
                        "自动整包备份超时（超过 {AUTO_TICK_TIMEOUT_SECS} 秒，下一轮重试）"
                    ),
                }
            }
        }
    }

    // ③ 落盘水位
    if let Err(e) = crate::sync::save_settings(&state.data_dir, &s) {
        log::warn!("自动同步已完成，但水位没写进设置文件: {e}");
    }
    Ok(())
}
