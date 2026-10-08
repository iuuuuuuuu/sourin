// ═══════════════════════════════════════════════════════════════════════
//  详情与播放链路 —— 从 Tauri lib.rs 搬过来的（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条链路是什么
//
// ```text
// 点开一个片子
//   → get_detail      拿详情（简介、剧集、封面）
//   → get_sources     列可用播放源（多源换源的一级）
//   → get_episodes    按源拉剧集（多源换源的二级）
//   → resolve_stream  ★ 拿真实流地址（播放的最后一步）
//   → media_kit 播放
// ```
//
// # ★ 为什么 `resolve_stream` 特别重要
//
// 它是**唯一会改写流地址**的地方，而改写的原因是防盗链：
//
// ```text
// B 站 CDN 实测：
//   无 UA            → 403
//   带 UA 无 Referer → 403
//   错误 Referer     → 403
//   正确 Referer+UA  → 206 ✓
// ```
// `<video>` 标签的请求头由浏览器决定，**JS 改不了** ——
// 所以必须把流地址换成**本地代理地址**，由代理带上正确的头转发。
//
// 这条逻辑放在这里而不是各个 provider 里，因为「取流」是所有源的
// 必经之路（与 `ensure_session` 同理）—— 放这里，新接入的源只要
// 按契约声明 `notWebReady` + `headers` 就自动获得此能力。

use std::sync::Arc;

use crate::model::{Episode, MediaDetail, MediaId, PlayRequest, PlaySource, StreamCandidate};
use crate::state::AppState;

/// 取媒体详情
///
/// 源：原版 `lib.rs` 的 `get_detail`
///
/// # ★ 封面也要走代理（原版注释记录的一个真 bug）
///
/// 「实测漏掉一处：只改了 `get_list` / `get_rank`，
///   详情页的封面还是裸 URL → 列表项能显示、点进去大图裂开。
///   这种『只修了一半』的 bug 很容易漏，因为列表页看起来已经好了。」
///
/// 所以这里必须调 `proxy_cover_one`。
pub async fn get_detail(
    state: &AppState,
    provider: &str,
    id: &str,
) -> Result<MediaDetail, String> {
    let mid = MediaId::new(provider, id);
    let p = state
        .registry
        .route(&mid)
        .ok_or_else(|| format!("无法路由: {provider}:{id}"))?;
    let mut d = p.detail(&mid).await.map_err(|e| e.message)?;
    proxy_cover_one(state, provider, &mut d.cover).await;
    Ok(d)
}

/// 列出可用播放源（多源换源的一级）
///
/// 源：原版 `lib.rs` 的 `get_sources`
pub async fn get_sources(
    state: &AppState,
    provider: &str,
    id: &str,
) -> Result<Vec<PlaySource>, String> {
    let mid = MediaId::new(provider, id);
    let p = state
        .registry
        .route(&mid)
        .ok_or_else(|| format!("无法路由: {provider}:{id}"))?;
    p.sources(&mid).await.map_err(|e| e.message)
}

/// 按播放源拉取剧集（多源换源的二级）
///
/// 源：原版 `lib.rs` 的 `get_episodes`
///
/// # 参数名的坑
///
/// 原版前端传 `sourceCode`（camelCase），Rust 签名是 `source_code`。
/// `Args` 会自动兼容（见 `args.rs`）。
pub async fn get_episodes(
    state: &AppState,
    provider: &str,
    id: &str,
    source_code: &str,
) -> Result<Vec<Episode>, String> {
    let mid = MediaId::new(provider, id);
    let p = state
        .registry
        .route(&mid)
        .ok_or_else(|| format!("无法路由: {provider}:{id}"))?;
    p.episodes(&mid, source_code)
        .await
        .map_err(|e| e.message)
}

/// ★★★ 解析真实流地址 —— 播放链路的最后一步
///
/// 源：原版 `lib.rs` 的 `resolve_stream`
///
/// # 三件必须做的事（顺序都有讲究）
///
/// ```text
/// ① 取流前先确保会话可用（按需续期 → 必要时自动登录）
/// ② 拿到候选流后，把「需要自定义头」的流换成**本地代理地址**
/// ③ ★ 独立音轨（audio_url）也要走同一个代理
/// ```
///
/// ## ① 为什么会话检查放这里
///
/// 原版注释：「取流是所有源的必经之路 —— 在这里兜住，
/// 新接入的源只要覆盖 refresh_session/auto_login 就自动获得此能力。」
///
/// ## ② 为什么必须换代理（实测数据）
///
/// ```text
/// 无 UA            → 403
/// 带 UA 无 Referer → 403
/// 错误 Referer     → 403
/// 正确 Referer+UA  → 206 ✓
/// ```
/// CDN 只认 Referer，没有它一个字节都拿不到。
///
/// ## ③ ★ 音轨是最容易漏的（实测踩过）
///
/// DASH 分发时音视频分离，插件用 `audioUrl` 声明音频轨。
/// `<audio>` 和 `<video>` 一样改不了请求头 —— 音轨不注册代理的表现是：
///
/// ```text
/// 画面正常、但完全没有声音（而且不报错，只是静音）
/// ```
///
/// 这种「只坏一半」的问题最难查，所以在这里一并处理。
/// 音轨与视频轨来自同一个 CDN，防盗链要求完全一样，
/// 所以直接用同一个 headers 与 not_web_ready。
///
/// # 幂等性
///
/// `maybe_proxy` 内部会跳过已经是本地代理地址的 URL，
/// 所以重复调用不会把地址套娃（URL 越套越长）。
pub async fn resolve_stream(
    state: &AppState,
    provider: &str,
    id: &str,
    req: Option<PlayRequest>,
) -> Result<Vec<StreamCandidate>, String> {
    // ① 取流前先确保会话可用
    if let Some(false) = state.registry.ensure_session(provider).await {
        return Err("登录已失效，请到「设置 → 账号登录」重新登录".into());
    }

    let mid = MediaId::new(provider, id);
    let p = state
        .registry
        .route(&mid)
        .ok_or_else(|| format!("无法路由: {provider}:{id}"))?;
    let mut list = p
        .resolve(&mid, &req.unwrap_or_default())
        .await
        .map_err(|e| e.message)?;

    // ②③ 逐个候选流处理：流地址 + 独立音轨
    for c in &mut list {
        if let Some(local) =
            crate::streamproxy::maybe_proxy(&state.stream_proxy, &c.url, &c.headers, c.not_web_ready)
                .await
        {
            c.url = local;
        }

        // ★ 独立音轨也要走同一个代理（漏了就是"有画面没声音"）
        if let Some(audio) = c.audio_url.clone() {
            if let Some(local) = crate::streamproxy::maybe_proxy(
                &state.stream_proxy,
                &audio,
                &c.headers,
                c.not_web_ready,
            )
            .await
            {
                c.audio_url = Some(local);
            }
        }
    }

    Ok(list)
}

/// 给**单个**封面 URL 套代理（详情页用）
///
/// 源：原版 `lib.rs` 的 `proxy_cover_one`
///
/// # 与 `proxy_covers`（复数）的区别
///
/// ```text
/// proxy_covers   → 列表页，批量处理 items 里每个封面
/// proxy_cover_one→ 详情页，只有一个封面
/// ```
/// 两者的跳过条件与代理启动逻辑完全一致 ——
/// 这里抽成共用实现，避免「改了一个忘了另一个」。
pub async fn proxy_cover_one(state: &AppState, provider: &str, cover: &mut Option<String>) {
    let Some(c) = cover.as_ref() else { return };
    // 已经是本地代理地址 → 跳过（幂等）
    if c.starts_with("http://127.0.0.1:") {
        return;
    }
    let Some(m) = state.registry.manifests().into_iter().find(|m| m.id == provider) else {
        return;
    };
    if m.cover_headers.is_empty() {
        return;
    }
    if let Err(e) = state.stream_proxy.ensure_started().await {
        log::warn!("封面代理启动失败: {e}");
        return;
    }
    *cover = Some(
        state
            .stream_proxy
            .register_cover(c, m.cover_headers.clone()),
    );
}

/// 便利函数：解析并返回**第一个可播流**
///
/// # 为什么加这个（原版没有）
///
/// 原版前端要自己从 `Vec<StreamCandidate>` 里挑第一个能播的。
/// Flutter 侧同理会很啰嗦：
/// ```dart
/// final list = await SourinApi.resolveStream(...);
/// final playable = list.firstWhere((s) => !s.isDrm, orElse: () => ...);
/// ```
/// 但**这个挑选逻辑必须与原版一致**，否则可能选到 DRM 流导致黑屏。
///
/// ⚠️ 所以这里只做「跳过 DRM」这一条与源注释一致的过滤，
///    其余顺序完全保留（不排序、不按清晰度挑）——
///    排序是产品决策，不该由这一层偷偷决定。
pub async fn resolve_first_playable(
    state: &AppState,
    provider: &str,
    id: &str,
    req: Option<PlayRequest>,
) -> Result<Option<StreamCandidate>, String> {
    let list = resolve_stream(state, provider, id, req).await?;
    Ok(list.into_iter().find(|c| !c.drm_protected))
}
