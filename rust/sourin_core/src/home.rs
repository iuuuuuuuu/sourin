// ═══════════════════════════════════════════════════════════════════════
//  首页链路命令 —— 从 Tauri lib.rs 搬过来的（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独一个文件
//
// 首页是「用户打开应用看到的第一个东西」。它跑通了，
// 才能验证「操作逻辑与原版一致」这条硬要求。
//
// 这条链路涉及：
// ```text
// get_home       跨源聚合首页（错误隔离）
// get_categories 某源的分类列表
// get_rank       榜单内容（cycani 这类源用）
// ```
//
// # 搬运规则（同 commands.rs）
//
// ```text
// 原版：async fn xxx(state: tauri::State<'_, AppState>, a: T) -> Result<R, String>
// 这里：pub async fn xxx(state: &AppState, a: T) -> Result<R, String>
// ```
// **函数体不动**，只改签名与 `state` 的用法（`state.` 而不是 `state.0.`）。

use crate::state::AppState;

/// 跨 Provider 聚合首页
///
/// 源：原版 `lib.rs` 的 `get_home`
///
/// # ★ 关键：错误隔离
///
/// `registry.home_all()` 内部对每个源做了错误隔离 ——
/// 一个源挂了（比如 cycani 需要登录），**不该让整个首页白屏**。
/// 这是实测踩出来的：原先没有隔离时，cycani 未登录会导致
/// 首页完全没有内容。
///
/// # 返回结构
///
/// ```json
/// [ { "provider": "cctv", "providerName": "央视网", "sections": [...] } ]
/// ```
/// 前端按 provider 分组渲染（首页的源切换条就是这么来的）。
pub async fn get_home(state: &AppState) -> Result<Vec<serde_json::Value>, String> {
    let groups = state.registry.home_all().await;
    Ok(groups
        .into_iter()
        .map(|(id, name, sections)| {
            serde_json::json!({ "provider": id, "providerName": name, "sections": sections })
        })
        .collect())
}

/// 取某个源的分类列表
///
/// 源：原版 `lib.rs` 的 `get_categories`
pub async fn get_categories(
    state: &AppState,
    provider: &str,
) -> Result<Vec<crate::model::Category>, String> {
    let p = state
        .registry
        .get(provider)
        .ok_or_else(|| format!("找不到 Provider: {provider}"))?;
    p.categories().await.map_err(|e| e.message)
}

/// ★ 榜单内容（首页 `SectionSource::Rank` 区块用）
///
/// 源：原版 `lib.rs` 的 `get_rank`
///
/// # 缺少这个命令的后果（原版注释记录）
///
/// 「声明了榜单的源（cycani）在首页会**永远显示「暂无内容」**」
pub async fn get_rank(
    state: &AppState,
    provider: &str,
    rank_id: &str,
    page: u32,
) -> Result<crate::model::Page<crate::model::MediaItem>, String> {
    let p = state
        .registry
        .get(provider)
        .ok_or_else(|| format!("找不到 Provider: {provider}"))?;
    let mut r = p.rank(rank_id, page).await.map_err(|e| e.message)?;
    proxy_covers(state, provider, &mut r.items).await;
    Ok(r)
}

/// ★ 分类列表（首页 `SectionSource::Category` 区块用）
///
/// 源：原版 `lib.rs` 的 `get_list`
///
/// # 参数名的坑（★ 跨层契约）
///
/// 原版前端这样调（`src/api/index.ts` L496）：
/// ```ts
/// call<Page<MediaItem>>("get_list", { provider, categoryId, page })
///                                                 ^^^^^^^^^^
/// ```
/// 而 Rust 命令签名是 `category_id: String`。
/// **Tauri 在 invoke 边界自动做了 camelCase → snake_case 转换。**
///
/// 到了这里：`ffi.rs` 用 `Args::str("category_id")` 读，
/// 而 `Args` 会自动兼容两种写法（见 `args.rs` 的 `get`）。
/// 所以 Dart 侧可以照搬原版前端的写法。
pub async fn get_list(
    state: &AppState,
    provider: &str,
    category_id: &str,
    page: u32,
) -> Result<crate::model::Page<crate::model::MediaItem>, String> {
    let p = state
        .registry
        .get(provider)
        .ok_or_else(|| format!("找不到 Provider: {provider}"))?;
    let mut r = p
        .list(crate::provider::ListRequest {
            category_id: category_id.to_string(),
            page,
            filters: Default::default(),
        })
        .await
        .map_err(|e| e.message)?;
    proxy_covers(state, provider, &mut r.items).await;
    Ok(r)
}

/// 把条目里的封面 URL 换成本地代理地址
///
/// 源：原版 `lib.rs` 的 `proxy_covers`
///
/// # 为什么必须代理封面
///
/// 部分源（尤其 B 站）的图片 CDN **白名单校验 Referer** ——
/// 直接请求返回 403，界面上就是一片裂图。
///
/// # 三个关键细节（原版实测得来）
///
/// ```text
/// ① 该源没声明 cover_headers → 直连，什么都不做（不做无用功）
/// ② 代理起不来 → 保持原 URL，让用户看到"图挂了"而不是白屏
///     （静默失败比可见的失败更糟：用户不知道发生了什么）
/// ③ 已经是本地代理地址 → 跳过（幂等）
///     —— 否则重复包一层，URL 会越来越长
/// ```
pub async fn proxy_covers(
    state: &AppState,
    provider: &str,
    items: &mut [crate::model::MediaItem],
) {
    // ① 该源没声明封面头 → 直连
    let Some(m) = state.registry.manifests().into_iter().find(|m| m.id == provider) else {
        return;
    };
    if m.cover_headers.is_empty() {
        return;
    }

    // ② 代理没起来就尽力启动一次
    if let Err(e) = state.stream_proxy.ensure_started().await {
        log::warn!("封面代理启动失败，封面将直连（很可能 403）: {e}");
        return;
    }

    for it in items.iter_mut() {
        if let Some(c) = it.cover.as_ref() {
            // ③ 已经是本地代理地址就别重复包一层（幂等）
            if c.starts_with("http://127.0.0.1:") {
                continue;
            }
            it.cover = Some(
                state
                    .stream_proxy
                    .register_cover(c, m.cover_headers.clone()),
            );
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    /// ★ 首页必须做错误隔离的「回归保护」
    ///
    /// 这条测试验证的是**设计意图**而不是具体实现：
    /// `get_home` 里不能出现 `?` 把单个源的错误往外抛 ——
    /// 那会让整个首页白屏。
    ///
    /// 做法：直接检查源码文本里有没有「未隔离」的写法。
    /// 这比造一个会失败的 provider 简单得多，且意图更清晰。
    #[test]
    fn get_home_must_not_propagate_single_provider_error() {
        let src = include_str!("home.rs");

        // 找到 get_home 函数体
        let start = src.find("pub async fn get_home").expect("找不到 get_home");
        let rest = &src[start..];
        let end = rest.find("\n}\n").unwrap_or(rest.len());
        let body = &rest[..end];

        /*
         * 允许出现的：
         *   state.registry.home_all().await      ← 内部已做隔离
         *
         * 不允许：对单个源的调用加 `?`
         *   （本函数里除了 home_all 不该有别的 async 调用）
         */
        assert!(
            body.contains("home_all"),
            "get_home 应该用已经做了错误隔离的 home_all()"
        );
        assert!(
            !body.contains(".map_err(|e| e.message)?"),
            "get_home 里不该对单个源的错误做 ? 传播 —— 那会让首页整体失败"
        );
    }
}
