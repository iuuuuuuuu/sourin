// ═══════════════════════════════════════════════════════════════════════
//  批次 2 · 写入命令 —— 从 Tauri lib.rs 搬过来的（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独一个文件
//
// 批次 1（只读）放在 `commands.rs` 里就够了（每个都是 1-3 行）。
// 但写入命令带**大量语义注释**（两个原版真机测出来的 bug 修复），
// 塞进 `commands.rs` 会让那个文件失去「薄适配层」的可读性。
//
// # 这批的纪律
//
// ```text
// 只读命令  → 可以直接对真实库验证
// 写入命令  → **必须**用隔离数据目录（绝不能在用户库上试写）
// ```
//
// # 两个必须逐字保留的原版修复（抄漏就重现 bug）
//
// ```text
// ① 封面 URL 必须先 unproxy 再落库
//    否则下次启动端口变了 → 封面必然裂
//
// ② 「追更」与「收藏」是**独立状态**
//    追更不要求先收藏；取消收藏不动追更
// ```
//
// # 为什么命令是 `async fn`
//
// `set_favorite` / `set_following` 在开启追更时要调平台的 `detail()`
// （网络请求）来记基准集数。所以它们是 `async`，
// 在 `ffi.rs` 里必须走 `with_state_async`。

use crate::state::AppState;
use crate::store::{Favorite, HistoryEntry, Progress, SkipMarker};

/// progress / skip_marker / favorite 的统一主键格式
///
/// ⚠️ 这个格式是**契约**：原版全项目都是 `"{provider}:{id}"`。
/// 拼错不会报错，只会静默查不到（返回 None）——
/// 所以只在**一处**定义，不允许多处各写一遍。
fn item_key(provider: &str, id: &str) -> String {
    format!("{provider}:{id}")
}

// ═══════════════════════════════════════════════════════════════════════
//  播放进度
// ═══════════════════════════════════════════════════════════════════════

/// 保存播放进度（**同时写一条历史**）
///
/// # 原版行为（`lib.rs` save_progress）
///
/// ```text
/// ① 封面 URL 先还原成原始地址 —— 见下
/// ② upsert_progress
/// ③ **再 add_history 一条**（历史与进度是两套数据，都要写）
/// ```
///
/// # ★ 为什么要 unproxy 封面
///
/// 真 bug（原版 2026-09-20 实测发现）：详情页拿到的 cover 已被换成
/// **流代理地址**：
/// ```text
/// http://127.0.0.1:61522/s/18d6e2dc5080d6b809cc4efb368
/// ```
/// 那是**本次运行**的临时地址（端口随机、token 存在内存表里）。
/// 直接落库 → 下次启动端口变了、token 表空了 → **封面必然裂**。
///
/// 实测表现（原版注释记录）：重启后「继续观看」页 16 张图里 1 张裂，
/// `complete=true` 但 `naturalWidth=0`。
///
/// 修法：持久化只存**原始 URL**；展示时代理层重新包一层 ——
/// 临时地址不落库，每次运行现生成。这才是正确的生命周期。
#[allow(clippy::too_many_arguments)]
pub fn save_progress(
    state: &AppState,
    provider: &str,
    id: &str,
    title: &str,
    cover: Option<String>,
    episode_id: Option<String>,
    episode_title: Option<String>,
    position: u64,
    duration: u64,
    finished: Option<bool>,
) -> Result<(), String> {
    let key = item_key(provider, id);
    let now = chrono::Utc::now().timestamp_millis();

    // ★ 落库前还原封面原始地址
    let cover = cover.map(|c| state.stream_proxy.unproxy_cover_or_keep(&c));

    state.db.upsert_progress(&Progress {
        key: key.clone(),
        provider: provider.to_string(),
        native_id: id.to_string(),
        title: title.to_string(),
        cover: cover.clone(),
        episode_id,
        episode_title: episode_title.clone(),
        position,
        duration,
        /*
         * 观看超过 95% 自动标记看完
         *
         * ⚠️ `duration.max(1)` 不能省 —— 直播/未知时长的 duration 是 0，
         *    不防就会除零 panic，而 panic 跨 FFI 边界是 UB。
         */
        finished: finished.unwrap_or(duration > 0 && position * 100 / duration.max(1) >= 95),
        updated_at: now,
    })?;

    // 同时写一条历史（原版如此）
    state.db.add_history(&HistoryEntry {
        key,
        provider: provider.to_string(),
        native_id: id.to_string(),
        title: title.to_string(),
        cover,
        episode_title,
        position,
        duration,
        watched_at: now,
    })
}

/// 清空观看历史
pub fn clear_history(state: &AppState) -> Result<(), String> {
    state.db.clear_history()
}

// ═══════════════════════════════════════════════════════════════════════
//  片头 / 片尾跳过点
// ═══════════════════════════════════════════════════════════════════════

/// 设置片头/片尾跳过点
///
/// # ★ 区间校验（后端也挡一道，不能只靠前端）
///
/// 原版注释记录的真实原因：
/// > 前端会挡，但**遥控端可能直接发命令**，不经过前端校验 ——
/// > 上一版就是这样漏掉了 `skip_confirm` 的防呆，
/// > 结果把整个视频（1420 秒）设成了片头（实测踩到）。
///
/// 规则：
/// ```text
/// ① 每个区间内部：start < end
/// ② 片头整体在片尾之前：intro_end <= outro_start
/// ```
#[allow(clippy::too_many_arguments)]
pub fn set_skip_marker(
    state: &AppState,
    provider: &str,
    id: &str,
    title: Option<String>,
    intro_start: Option<u64>,
    intro_end: Option<u64>,
    outro_start: Option<u64>,
    outro_end: Option<u64>,
    auto_skip: Option<bool>,
) -> Result<(), String> {
    if let (Some(s), Some(e)) = (intro_start, intro_end) {
        if s >= e {
            return Err("片头的开始必须早于结束".into());
        }
    }
    if let (Some(s), Some(e)) = (outro_start, outro_end) {
        if s >= e {
            return Err("片尾的开始必须早于结束".into());
        }
    }
    if let (Some(ie), Some(os)) = (intro_end, outro_start) {
        if ie > os {
            return Err("片头必须结束于片尾开始之前".into());
        }
    }

    state.db.upsert_skip_marker(&SkipMarker {
        key: item_key(provider, id),
        provider: provider.to_string(),
        native_id: id.to_string(),
        title: title.unwrap_or_default(),
        intro_start,
        intro_end,
        outro_start,
        outro_end,
        auto_skip,
        updated_at: chrono::Utc::now().timestamp_millis(),
    })
}

/// 清除某作品的跳过点
pub fn clear_skip_marker(state: &AppState, provider: &str, id: &str) -> Result<(), String> {
    state.db.clear_skip_marker(&item_key(provider, id))
}

// ═══════════════════════════════════════════════════════════════════════
//  收藏 / 追更
// ═══════════════════════════════════════════════════════════════════════

/// 把收藏标记为已读（清未读计数）
pub fn mark_favorite_read(state: &AppState, key: &str) -> Result<(), String> {
    state
        .db
        .mark_favorite_read(key, chrono::Utc::now().timestamp_millis())
}

/// 取消收藏
///
/// # ★ 写墓碑而不是真删
///
/// 原版注释：
/// > 写墓碑而非真删（否则会被其他设备的旧数据复活）
///
/// 这是**同步**场景的必要设计：真删了，另一端（或云端）还以为这条
/// 存在，下次同步会把它"复活"回来。墓碑是一条 `deleted=1` 的记录，
/// 能把删除动作同步出去。
pub fn remove_favorite(state: &AppState, key: &str) -> Result<(), String> {
    state
        .db
        .tombstone_favorite(key, chrono::Utc::now().timestamp_millis())
}

/// 设置/取消收藏
///
/// # ★★ 两条 Owner 明确纠正过的语义（抄漏就重现 bug）
///
/// **① 追更与收藏是独立状态**
/// > 「追更并不代表就要收藏，这是独立的状态」
///
/// 所以「取消收藏」**只清 favorited，不动 following** ——
/// 用户可能"不收藏了，但还想盯着看它更新"。
///
/// **② 封面必须先 unproxy 再落库**
/// 同 `save_progress` —— 临时代理地址落库必然导致下次启动裂图。
///
/// ⚠️ unproxy 放在函数**最前面**（而不是某个分支里）——
///    这样"收藏"与"取消收藏"两条路径都覆盖到，
///    而且返回值里带的也是干净地址。
pub async fn set_favorite(
    state: &AppState,
    provider: &str,
    id: &str,
    on: bool,
    title: Option<String>,
    cover: Option<String>,
    kind: Option<String>,
    following: Option<bool>,
) -> Result<Favorite, String> {
    let key = item_key(provider, id);
    let now = chrono::Utc::now().timestamp_millis();

    let cover = cover.map(|c| state.stream_proxy.unproxy_cover_or_keep(&c));

    let mut fav = match state.db.get_favorite(&key)? {
        Some(f) => f,
        None => {
            /*
             * 库里没这行 → 需要新建
             *
             * ⚠️ 取消收藏一个本来就不存在的条目 = **幂等空操作**。
             *    原版 `set_favorite` 在这种情况下返回 Err（前端不会这么调），
             *    但遥控端可能重复发命令 —— 报错会让 UI 弹红条。
             *    这里保持与原版一致返回 Err，因为原版就是 Err
             *    （行为一致优先，见 Owner 要求）。
             */
            if !on {
                return Err(format!("{key} 不在收藏里"));
            }
            Favorite {
                key: key.clone(),
                provider: provider.to_string(),
                native_id: id.to_string(),
                title: title.clone().unwrap_or_default(),
                cover: cover.clone(),
                group_name: None,
                kind: kind.clone().unwrap_or_else(|| "series".into()),
                favorited: false,
                following: false,
                last_episode_count: 0,
                last_episode_title: None,
                unread_count: 0,
                last_checked_at: 0,
                last_update_at: 0,
                note: None,
                created_at: now,
                updated_at: now,
                deleted: false,
            }
        }
    };

    // 墓碑行要复活（用户重新收藏以前删过的内容，是正常操作）
    if fav.deleted {
        fav.deleted = false;
    }

    // 补全元信息（详情页会传；列表页可能只传 key）
    if let Some(t) = title {
        if !t.is_empty() && fav.title.is_empty() {
            fav.title = t;
        }
    }
    fav.cover = fav.cover.or(cover);

    // ★ 只动 favorited —— following 保持原样（独立状态）
    fav.favorited = on;

    /*
     * 显式传了 following 才动它
     *
     * 注意这里**不是**「取消收藏就关追更」—— 那是被明确纠正过的错误行为。
     * 只有调用方**明确传了** `following` 才改。
     */
    if let Some(f) = following {
        if fav.following != f {
            fav.following = f;
            if f {
                // 新开追更 → 记基准集数（理由同 set_following）
                match crate::follow::current_episode_count(&state.registry, &fav).await {
                    Ok(n) => fav.last_episode_count = n,
                    // 抓不到就不设基准，首次巡检会补记
                    Err(_) => fav.last_episode_count = 0,
                }
                fav.unread_count = 0;
                fav.last_update_at = 0;
                fav.last_episode_title = None;
            }
        }
    }

    fav.updated_at = now;
    state.db.upsert_favorite(&fav)?;
    Ok(fav)
}

/// 设置/取消追更
///
/// # ★★★ 追更**不要求先收藏**（Owner 的第二次纠正）
///
/// > 追更并不代表就要收藏，这是独立的状态
///
/// # 原先错在哪
///
/// 这条命令原来是「库里没这行就直接返回 None」。但一行只有在
/// "收藏过或追更过"时才存在，所以「只追更不收藏」根本无从建立：
/// ```text
/// ① 用户从没碰过这个内容
/// ② 点「追更」→ 库里没这行 → 返回 None → 什么都没发生 ★
/// ```
///
/// # 现在
///
/// 不存在就**新建一行**，但 `favorited: false` ——
/// 于是它出现在追更列表里，**不出现在收藏列表里**。
///
/// # ★★ 开启追更时必须立刻记基准集数
///
/// Owner 的核心要求：
/// > 而追更，是**收藏的时候是多少集**，当更新的时候，
/// > 要在追更那个页面，显示出来这个更新了
///
/// 「更新了」的判据是 `平台当前集数 > 基准集数`。若不在这里记基准：
/// ```text
/// ① 用户开启追更（基准 = 0）
/// ② 首次巡检 → 平台 10 集 > 0 → 判定"更新了 10 集" ★ 必然误报
/// ```
/// 用户明明只是刚点了「追更」，立刻收到 10 条"更新"——
/// 这是**必然发生**的假更新，不是偶发。
///
/// # 抓基准失败不能阻断开追更
///
/// 抓基准要调平台的 `detail()`（网络请求）。失败就报错不让开追更，
/// 体验很差（断网就不能追更了）。所以：
/// ```text
/// 抓到了 → 用真实值当基准 ✅
/// 抓不到 → 保持 0，但**同时把 unread 清零**，
///          且首次巡检会走"初始化"路径（只记基准、不报更新）
/// ```
/// 见 `follow.rs::check_one` 里 `old_count == 0` 的分支。
pub async fn set_following(
    state: &AppState,
    provider: &str,
    id: &str,
    following: bool,
    title: Option<String>,
    cover: Option<String>,
    kind: Option<String>,
) -> Result<Option<Favorite>, String> {
    let key = item_key(provider, id);
    let now = chrono::Utc::now().timestamp_millis();

    let mut fav = match state.db.get_favorite(&key)? {
        Some(f) => f,
        None => {
            if !following {
                /* 关一个本来就不存在的追更 → 幂等空操作，不是错误 */
                return Ok(None);
            }
            Favorite {
                key: key.clone(),
                provider: provider.to_string(),
                native_id: id.to_string(),
                title: title.clone().unwrap_or_default(),
                cover: cover.clone(),
                group_name: None,
                kind: kind.clone().unwrap_or_else(|| "series".into()),
                // ★ 只追更，不收藏
                favorited: false,
                following: true,
                last_episode_count: 0,
                last_episode_title: None,
                unread_count: 0,
                last_checked_at: 0,
                last_update_at: 0,
                note: None,
                created_at: now,
                updated_at: now,
                deleted: false,
            }
        }
    };

    /*
     * ⚠️ 墓碑行要**复活**（而不是拒绝）
     *
     * 墓碑的含义是"两个状态都为 0"，它是**可复活**的：
     * 用户重新追更一个以前删过的内容，是正常操作。
     *
     * ⚠️ 但复活时**不动 favorited** —— 那样就又变成"偷偷帮他收藏"了。
     */
    if fav.deleted {
        fav.deleted = false;
    }

    // 补全元信息（列表页只有标题时也能建行）
    if let Some(t) = title {
        if !t.is_empty() && fav.title.is_empty() {
            fav.title = t;
        }
    }
    fav.cover = fav.cover.or(cover);

    // ★ 从「不追更」→「追更」= 新开追更，要记基准
    if following && !fav.following {
        match crate::follow::current_episode_count(&state.registry, &fav).await {
            Ok(n) => {
                log::info!("开启追更 {}：基准集数 = {n}", fav.key);
                fav.last_episode_count = n;
                fav.last_episode_title = None;
            }
            Err(e) => {
                log::warn!(
                    "开启追更 {}：抓基准失败（首次巡检时会补记）: {e}",
                    fav.key
                );
                fav.last_episode_count = 0;
            }
        }
        // 新开追更不该带着旧的未读
        fav.unread_count = 0;
        fav.last_update_at = 0;
    }

    fav.following = following;
    fav.updated_at = now;
    state.db.upsert_favorite(&fav)?;
    Ok(Some(fav))
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 换源：把记录搬到新 key（task-67 需求⑤）
// ═══════════════════════════════════════════════════════════════════════

/// 换源时把记录从旧 key **搬到**新 key
///
/// # Owner 原话（逐字）
///
/// ```text
/// 追更收藏历史，当我换源之后，这三个记录却没有更新，
/// 返回再进去却还是老的源，这也是错误的
/// ```
///
/// # 根因
///
/// 四张表（`favorites` / `progress` / `history` / `skip_markers`）的 key
/// 全是 [`item_key`] 拼出来的 `<provider>:<id>`：
/// ```text
/// 换源 ⇒ provider 变 ⇒ ★ key 变 ⇒ 写入是【新行】，旧行原样留着
/// ```
/// 于是列表里那一条仍然指向**旧源**（点进去是旧源的详情页）。
///
/// # ★ 为什么参数是 provider/id 而不是直接给 key
///
/// key 的拼法**只有一处**（[`item_key`]）。让调用方在 Dart 侧自己拼
/// `"$provider:$id"` 就是**第二份实现** —— 本项目反复踩过
/// "两处同构必然漂"的坑，所以这里只接受两半，由本函数拼。
///
/// # ★ 只接受"跨源"的迁移
///
/// ```text
/// fromProvider == toProvider ⇒ 直接返回（**不迁移**）
/// ```
/// 理由（Lead 裁决）：同 provider 内换**线路**（`player_page._remoteSwitchSource`
/// 的 `switch_source`）provider/id 都不变；而"同 provider 不同 id"是**另一部作品**，
/// 迁移会把两部不相干的作品的记录**混在一起**（严重）。
/// ⇒ 唯一合法的迁移是 **provider 变了**。
///
/// # 失败语义
///
/// 迁移失败**不阻断换源** —— 调用方（`media_page._onDetailSwitchSource`）
/// 会 catch 住并如实记日志，然后继续播放。记录搬不动也得让用户能看。
pub fn repoint_item(
    state: &AppState,
    from_provider: &str,
    from_id: &str,
    to_provider: &str,
    to_id: &str,
) -> Result<(), String> {
    /*
     * ★★ 跨源守卫（防误迁移）
     *
     * 这不是"优化"，是**正确性**：同 provider 内换 id 是另一部作品，
     * 迁移会把 A 的进度/收藏写到 B 上。
     */
    if from_provider == to_provider {
        log::debug!(
            "repoint_item: 同一个 provider({from_provider}) ⇒ 不迁移（换线路不是换源）"
        );
        return Ok(());
    }
    if from_id.is_empty() || to_id.is_empty() || to_provider.is_empty() {
        return Err(format!(
            "repoint_item 参数不完整: from={from_provider}:{from_id} to={to_provider}:{to_id}"
        ));
    }

    let from_key = item_key(from_provider, from_id);
    let to_key = item_key(to_provider, to_id);
    if from_key == to_key {
        return Ok(());
    }

    log::info!("★ 换源迁移记录: {from_key} → {to_key}");
    state.db.repoint_item(&from_key, &to_key)
}
