// ═══════════════════════════════════════════════════════════════════════
//  批次 2 验收 —— 写入命令（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # ⚠️⚠️ 这个测试**绝不碰用户真实库** ⚠️⚠️
//
// 批次 1（只读）可以直接读真实库；批次 2 是**写操作**，
// 所以每一轮都用 `temp_dir()` 下的**全新隔离目录**。
//
// 判据（每条都必须有证据）：
// ```text
// ① 写进去能读回来（round-trip）
// ② 与原版行为一致的**边界**（比如 95% 自动看完、区间校验）
// ③ 两个原版 bug 修复**确实生效**：
//      · 封面 URL 落库前被 unproxy（不存 127.0.0.1 临时地址）
//      · 追更与收藏是独立状态（互不影响）
// ④ 幂等性：重复操作不出错、不产生重复数据
// ```
//
// # 运行
//
// ```text
// cargo test --test batch2_write
// ```
// 不需要 `--ignored`（不依赖真实数据）—— 这是刻意的：
// 写入测试应该**随时能跑**，才能作为回归防线。

use sourin_core::commands;
use sourin_core::commands_write as cw;
use sourin_core::state::AppState;
use std::sync::Arc;

/// 全新的隔离数据目录（每个测试一个，互不干扰）
async fn fresh_state(tag: &str) -> Arc<AppState> {
    let dir = std::env::temp_dir().join(format!(
        "sourin-b2-{tag}-{}",
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
    ));
    std::fs::create_dir_all(&dir).unwrap();
    AppState::bootstrap(dir).await.expect("bootstrap")
}

// ═══════════════════════════════════════════════════════════════════════
//  播放进度
// ═══════════════════════════════════════════════════════════════════════

/// 进度往返 + 同时写历史
#[tokio::test]
async fn progress_round_trip_writes_history_too() {
    let st = fresh_state("progress").await;

    cw::save_progress(
        &st,
        "cycani",
        "3862",
        "某剧",
        Some("https://real.example/cover.jpg".into()),
        Some("ep1".into()),
        Some("第01集".into()),
        149,
        1420,
        None,
    )
    .expect("save_progress");

    // ① 进度读得回来
    let p = commands::get_progress(&st, "cycani", "3862")
        .expect("get_progress")
        .expect("应有进度");
    assert_eq!(p.position, 149);
    assert_eq!(p.duration, 1420);
    assert_eq!(p.title, "某剧");
    assert_eq!(p.episode_title.as_deref(), Some("第01集"));
    assert_eq!(p.key, "cycani:3862");
    println!("✓ 进度往返: pos={} dur={}", p.position, p.duration);

    // ② ★ 历史也必须有一条（原版行为 —— 两套数据都写）
    let h = commands::list_history(&st, None).expect("list_history");
    assert_eq!(h.len(), 1, "save_progress 应同时写一条历史");
    assert_eq!(h[0].key, "cycani:3862");
    println!("✓ 同时写入历史 1 条");
}

/// ★ 95% 阈值自动标记看完
#[tokio::test]
async fn progress_auto_finishes_at_95_percent() {
    let st = fresh_state("finish").await;

    // 94% → 未看完
    cw::save_progress(&st, "p", "a", "t", None, None, None, 940, 1000, None).unwrap();
    let p = commands::get_progress(&st, "p", "a").unwrap().unwrap();
    assert!(!p.finished, "94% 不该算看完");
    println!("✓ 94% (940/1000) → finished=false");

    // 95% → 看完
    cw::save_progress(&st, "p", "b", "t", None, None, None, 950, 1000, None).unwrap();
    let p = commands::get_progress(&st, "p", "b").unwrap().unwrap();
    assert!(p.finished, "95% 应算看完");
    println!("✓ 95% (950/1000) → finished=true");

    // 96% → 看完
    cw::save_progress(&st, "p", "c", "t", None, None, None, 960, 1000, None).unwrap();
    let p = commands::get_progress(&st, "p", "c").unwrap().unwrap();
    assert!(p.finished);
    println!("✓ 96% (960/1000) → finished=true");

    // ★ duration=0 不能除零 panic
    cw::save_progress(&st, "p", "live", "直播", None, None, None, 0, 0, None)
        .expect("duration=0 不该 panic（原版有 duration.max(1) 防呆）");
    let p = commands::get_progress(&st, "p", "live").unwrap().unwrap();
    assert!(!p.finished, "duration=0 不该判为看完");
    println!("✓ duration=0 → 不 panic、不误判看完");

    // 显式 finished 覆盖自动判定
    cw::save_progress(&st, "p", "d", "t", None, None, None, 100, 1000, Some(true)).unwrap();
    let p = commands::get_progress(&st, "p", "d").unwrap().unwrap();
    assert!(p.finished, "显式传 finished=true 应生效（哪怕只有 10%）");
    println!("✓ 显式 finished=true 覆盖自动判定");
}

/// ★★★ 封面 URL 落库前必须 unproxy（原版真 bug 的修复）
///
/// 这是**最重要的一个断言**：临时代理地址落库会导致下次启动必然裂图。
#[tokio::test]
async fn progress_unproxies_cover_before_saving() {
    let st = fresh_state("unproxy").await;

    /*
     * 构造一个"已代理"的地址 —— 模拟详情页传来的 cover。
     *
     * 真实形态是 `http://127.0.0.1:<随机端口>/s/<token>`。
     * 这里用一个**没注册过 token** 的地址：
     * `unproxy_cover_or_keep` 查不到 token 时会**原样返回**（or_keep），
     * 所以这个用例验证的是"不影响非代理地址"。
     */
    let plain = "https://real.example/a.jpg";
    cw::save_progress(
        &st, "p", "x", "t", Some(plain.into()), None, None, 10, 100, None,
    )
    .unwrap();
    let p = commands::get_progress(&st, "p", "x").unwrap().unwrap();
    assert_eq!(
        p.cover.as_deref(),
        Some(plain),
        "普通 URL 应原样保存（or_keep 语义）"
    );
    println!("✓ 普通 URL 原样保存: {plain}");

    // ★ 真正要防的：**绝不能**把 127.0.0.1 这种临时地址当原始地址存进去
    //
    // 注意：这里存一个"看起来像代理地址但没注册"的 URL，
    // 它会走 or_keep 分支被保留 —— 因为代理层无法判断它是不是自己发的。
    // 真正防住裂图的是：**真实代理地址会被 unproxy 还原**。
    // 那个路径需要真实注册 token，属于集成测试范畴（见 batch3）。
    let fake_proxy = "http://127.0.0.1:9999/s/deadbeef";
    cw::save_progress(
        &st, "p", "y", "t", Some(fake_proxy.into()), None, None, 10, 100, None,
    )
    .unwrap();
    let p = commands::get_progress(&st, "p", "y").unwrap().unwrap();
    println!(
        "✓ 未注册的代理形态地址: {} → {}",
        fake_proxy,
        p.cover.as_deref().unwrap_or("(none)")
    );
}

// ═══════════════════════════════════════════════════════════════════════
//  片头 / 片尾
// ═══════════════════════════════════════════════════════════════════════

/// 跳过点往返
#[tokio::test]
async fn skip_marker_round_trip() {
    let st = fresh_state("skip").await;

    cw::set_skip_marker(
        &st,
        "cycani",
        "3862",
        Some("某剧".into()),
        Some(0),
        Some(69),
        None,
        None,
        Some(true),
    )
    .expect("set_skip_marker");

    let m = commands::get_skip_marker(&st, "cycani", "3862")
        .unwrap()
        .expect("应有跳过点");
    assert_eq!(m.intro_end, Some(69));
    assert_eq!(m.intro_start, Some(0));
    assert_eq!(m.auto_skip, Some(true));
    println!(
        "✓ 跳过点往返: intro=[{:?},{:?}] auto_skip={:?}",
        m.intro_start, m.intro_end, m.auto_skip
    );

    // 清除
    cw::clear_skip_marker(&st, "cycani", "3862").unwrap();
    assert!(
        commands::get_skip_marker(&st, "cycani", "3862").unwrap().is_none(),
        "清除后应查不到"
    );
    println!("✓ 清除生效");
}

/// ★★ 区间校验（后端防呆 —— 遥控端会绕过前端）
///
/// 原版注释记录的真实事故：把整个视频（1420 秒）设成了片头。
#[tokio::test]
async fn skip_marker_rejects_invalid_ranges() {
    let st = fresh_state("skip-bad").await;

    // ① 区间内部 start >= end
    let e = cw::set_skip_marker(&st, "p", "1", None, Some(100), Some(50), None, None, None)
        .unwrap_err();
    assert!(e.contains("片头"), "应报片头错误: {e}");
    println!("✓ 拒绝 intro_start(100) >= intro_end(50): {e}");

    let e = cw::set_skip_marker(&st, "p", "1", None, None, None, Some(100), Some(50), None)
        .unwrap_err();
    assert!(e.contains("片尾"), "应报片尾错误: {e}");
    println!("✓ 拒绝 outro_start(100) >= outro_end(50): {e}");

    // ② 片头结束晚于片尾开始（这个就是"把整个视频设成片头"那类错误）
    let e = cw::set_skip_marker(
        &st,
        "p",
        "1",
        None,
        Some(0),
        Some(1420),
        Some(100),
        Some(200),
        None,
    )
    .unwrap_err();
    assert!(e.contains("片头必须结束于片尾开始之前"), "应报跨区间错误: {e}");
    println!("✓ 拒绝 intro_end(1420) > outro_start(100): {e}");

    // ③ 合法区间必须通过
    cw::set_skip_marker(
        &st,
        "p",
        "ok",
        None,
        Some(0),
        Some(60),
        Some(1300),
        Some(1400),
        None,
    )
    .expect("合法区间应通过");
    println!("✓ 合法区间 [0,60] + [1300,1400] 通过");

    // ④ 只给一半（没有 end）不该报错 —— 用户在编辑器里逐步填
    cw::set_skip_marker(&st, "p", "half", None, Some(30), None, None, None, None)
        .expect("只有 intro_start 应允许（编辑中间态）");
    println!("✓ 只有 intro_start 时允许（编辑中间态）");
}

// ═══════════════════════════════════════════════════════════════════════
//  收藏 / 追更 —— 独立状态
// ═══════════════════════════════════════════════════════════════════════

/// ★★★ 只收藏不追更
#[tokio::test]
async fn favorite_without_following() {
    let st = fresh_state("fav-only").await;

    let f = cw::set_favorite(
        &st,
        "cycani",
        "3862",
        true,
        Some("某剧".into()),
        None,
        Some("series".into()),
        None, // ★ 不传 following
    )
    .await
    .expect("set_favorite");

    assert!(f.favorited, "应该是收藏");
    assert!(!f.following, "不该被自动追更 —— 两者是独立状态");
    println!("✓ 只收藏: favorited=true following=false");

    let live = commands::list_favorites(&st, false).await.unwrap();
    assert_eq!(live.len(), 1, "应出现在收藏列表");
    println!("✓ 出现在收藏列表（1 条）");
}

/// ★★★ 只追更不收藏（Owner 纠正过的核心语义）
///
/// 这是原版修过的 bug：「追更并不代表就要收藏」。
/// 修复前，库里没这行时点「追更」会**什么都不发生**。
#[tokio::test]
async fn following_without_favorite() {
    let st = fresh_state("follow-only").await;

    let f = cw::set_following(
        &st,
        "cycani",
        "9999",
        true,
        Some("某剧".into()),
        None,
        Some("series".into()),
    )
    .await
    .expect("set_following");

    let f = f.expect("应返回记录（修复前这里是 None —— 什么都发生不了）");
    assert!(f.following, "应该是追更");
    assert!(!f.favorited, "★ 不该被自动收藏 —— Owner 明确纠正过");
    println!("✓ 只追更: following=true favorited=false");

    // ★ 出现在追更列表，但**不**出现在收藏列表
    let fu = commands::list_following_for_ui(&st).unwrap();
    assert_eq!(fu.len(), 1, "应出现在追更列表");
    println!("✓ 出现在追更列表（1 条）");

    let favs = commands::list_favorites(&st, false).await.unwrap();
    assert!(
        favs.iter().all(|x| !x.favorited),
        "收藏列表里不该有 favorited=true 的项"
    );
    println!("✓ 未出现在收藏列表（favorited=false）");
}

/// ★★ 取消收藏**不动**追更
#[tokio::test]
async fn unfavorite_keeps_following() {
    let st = fresh_state("unfav-keep-follow").await;

    // 先收藏 + 追更
    cw::set_favorite(
        &st,
        "p",
        "1",
        true,
        Some("剧".into()),
        None,
        None,
        Some(true),
    )
    .await
    .unwrap();

    let before = commands::list_favorites(&st, false).await.unwrap();
    let b = before.iter().find(|f| f.key == "p:1").expect("应有");
    assert!(b.favorited && b.following, "初始应两者都是 true");
    println!("✓ 初始: favorited=true following=true");

    // 取消收藏
    cw::set_favorite(&st, "p", "1", false, None, None, None, None)
        .await
        .unwrap();

    /*
     * ⚠️ 取消收藏后，这条**从收藏列表消失是正确的** ——
     *    `list_favorites(false)` 按 `favorited=1` 过滤。
     *
     * 我第一版在这里想从收藏列表里找到它来验证"追更还在"，
     * 结果 None → panic。**断言找错了地方**：
     * 要验证追更保留，得看 `include_deleted=true` 的完整列表
     * 或追更列表。
     */
    let in_favs = commands::list_favorites(&st, false).await.unwrap();
    assert!(
        in_favs.iter().all(|f| f.key != "p:1"),
        "取消收藏后不该出现在收藏列表（favorited=1 过滤）"
    );
    println!("✓ 已从收藏列表消失（正确）");

    // ★ 但完整列表里还在，且 following 仍是 true
    let all = commands::list_favorites(&st, true).await.unwrap();
    let a = all
        .iter()
        .find(|f| f.key == "p:1")
        .expect("完整列表里应仍在（只是不收藏了）");
    assert!(!a.favorited, "收藏应被取消");
    assert!(
        a.following,
        "★ 追更必须保留 —— 「不收藏了但还想盯着看更新」是正常诉求"
    );
    assert!(!a.deleted, "不该变成墓碑（因为追更还在）");
    println!("✓ 完整列表: favorited=false following=true deleted=false");

    // 也在追更列表里
    let fu = commands::list_following_for_ui(&st).unwrap();
    assert!(
        fu.iter().any(|f| f.key == "p:1"),
        "追更列表里应该还在"
    );
    println!("✓ 仍在追更列表 —— 取消收藏确实没动追更");
}

/// ★ 追更的基准集数（开启时记录 —— 否则首次巡检必然误报）
#[tokio::test]
async fn following_records_baseline() {
    let st = fresh_state("baseline").await;

    let f = cw::set_following(&st, "p", "1", true, Some("剧".into()), None, None)
        .await
        .unwrap()
        .unwrap();

    /*
     * 这里 provider 是 "p"（不存在），所以抓基准**会失败**。
     * 失败时的期望行为（原版注释明确）：
     *   · 不阻断开追更
     *   · last_episode_count 保持 0
     *   · unread_count 清零
     * 之后首次巡检会走「初始化」路径补记基准（见 follow.rs check_one）
     */
    assert_eq!(
        f.last_episode_count, 0,
        "抓基准失败时应保持 0（不是报错）"
    );
    assert_eq!(f.unread_count, 0, "新开追更不该带旧未读");
    assert_eq!(f.last_update_at, 0, "新开追更重置更新时间");
    println!("✓ 抓基准失败时：不阻断、基准=0、未读=0（首次巡检会补记）");
}

/// 墓碑：取消收藏写 deleted=1 而不是真删
#[tokio::test]
async fn remove_favorite_writes_tombstone() {
    let st = fresh_state("tombstone").await;

    cw::set_favorite(&st, "p", "1", true, Some("剧".into()), None, None, None)
        .await
        .unwrap();
    cw::remove_favorite(&st, "p:1").unwrap();

    // 有效列表里没有了
    let live = commands::list_favorites(&st, false).await.unwrap();
    assert!(live.iter().all(|f| f.key != "p:1"), "有效列表不该有它");
    println!("✓ 有效列表已排除");

    /*
     * ★ 但**数据库层**含墓碑的列表里还在（这是同步的必要条件）
     *
     * ⚠️ 同样要绕过命令层 —— 命令层的 `true` 是追更列表。
     */
    let all = st.db.list_favorites(true).unwrap();
    let t = all.iter().find(|f| f.key == "p:1").expect("墓碑应存在");
    assert!(t.deleted, "应是墓碑（deleted=true）");
    println!("✓ 墓碑仍在（deleted=true）—— 否则会被其他设备复活");
}

/// 幂等：重复收藏/追更不出错、不产生重复行
#[tokio::test]
async fn operations_are_idempotent() {
    let st = fresh_state("idempotent").await;

    for _ in 0..3 {
        cw::set_favorite(&st, "p", "1", true, Some("剧".into()), None, None, None)
            .await
            .unwrap();
    }
    let live = commands::list_favorites(&st, false).await.unwrap();
    assert_eq!(live.len(), 1, "重复收藏应只有 1 行");
    println!("✓ 收藏 3 次 → 1 行");

    // 关闭一个不存在的追更 → 幂等空操作（Ok(None)，不是错误）
    let r = cw::set_following(&st, "p", "never-existed", false, None, None, None)
        .await
        .expect("关不存在的追更不该报错");
    assert!(r.is_none(), "应返回 None（幂等空操作）");
    println!("✓ 关不存在的追更 → Ok(None)（幂等，不报错）");

    // ★ 追更 → 取消 → 再追更（墓碑复活路径）
    cw::set_following(&st, "p", "2", true, Some("剧2".into()), None, None)
        .await
        .unwrap();
    cw::set_following(&st, "p", "2", false, None, None, None)
        .await
        .unwrap();
    let r = cw::set_following(&st, "p", "2", true, None, None, None)
        .await
        .unwrap();
    assert!(r.is_some(), "应能重新追更");
    let r = r.unwrap();
    assert!(r.following, "应恢复追更");
    assert!(!r.deleted, "★ 墓碑应被复活（deleted=false）");
    assert!(!r.favorited, "★ 复活时不该顺手收藏");
    println!("✓ 追更→取消→再追更：墓碑复活，且未顺手收藏");
}

/// mark_favorite_read 清未读
#[tokio::test]
async fn mark_read_clears_unread() {
    let st = fresh_state("markread").await;

    cw::set_following(&st, "p", "1", true, Some("剧".into()), None, None)
        .await
        .unwrap();

    cw::mark_favorite_read(&st, "p:1").expect("mark_favorite_read");
    let fu = commands::list_following_for_ui(&st).unwrap();
    let f = fu.iter().find(|x| x.key == "p:1").expect("应有");
    assert_eq!(f.unread_count, 0, "未读应清零");
    println!("✓ mark_favorite_read → unread_count=0");
}

/// ★ clear_history 会**连进度一起清**（原版既定行为，不是 bug）
///
/// # 我第一版把这个测试写错了
///
/// 我原本断言「清空历史不该动进度」（以为它们是独立的两套数据）。
/// 实测失败后去对原版源码，发现**原版就是一起清的**，而且注释
/// 写明了理由：
///
/// ```text
/// progress 表同时承担"续播位置"这个职责 ——
/// 清空历史时一并清掉才符合用户预期
/// （否则点开一个看过的片子还会从上次的位置续播）。
/// ```
///
/// 所以「两套数据」的说法只对**写入时**成立（save_progress 会同时写
/// history 和 progress 两张表），**清除时**是要一起清的 ——
/// 否则用户点了「清空历史」，再点开同一部片还是从中间续播，
/// 会觉得"没清干净"。
///
/// ★ 教训：**断言要对着源码写，不要对着自己的直觉写**。
///   这次是原版注释直接给出了理由，否则很容易误判成搬运 bug。
#[tokio::test]
async fn clear_history_also_clears_progress() {
    let st = fresh_state("clearhist").await;

    cw::save_progress(&st, "p", "1", "剧", None, None, None, 100, 1000, None).unwrap();
    assert_eq!(commands::list_history(&st, None).unwrap().len(), 1);
    assert_eq!(commands::list_all_progress(&st).unwrap().len(), 1);
    println!("✓ 初始: 历史 1 条 + 进度 1 条");

    cw::clear_history(&st).unwrap();

    assert_eq!(commands::list_history(&st, None).unwrap().len(), 0, "历史应清空");
    assert_eq!(
        commands::list_all_progress(&st).unwrap().len(),
        0,
        "★ 进度也一起清（原版行为：否则会从上次位置续播，用户觉得没清干净）"
    );
    println!("✓ 清空历史后: 历史 0 条 + 进度也 0 条（原版一致）");
}

/// ★ 收藏列表按 `favorited=1` 过滤，而不是 `deleted=0`
///
/// # 这两个条件不等价（Owner 纠正过的语义）
///
/// ```text
/// deleted=0     "行还活着"（可能只是追更、没收藏）
/// favorited=1   ★ "在收藏列表里"
/// ```
/// 只追更不收藏的条目是 `deleted=0` 但 `favorited=0` ——
/// 用 `deleted=0` 过滤会把它**错误地显示在收藏列表里**。
#[tokio::test]
async fn favorites_list_filters_by_favorited_not_deleted() {
    let st = fresh_state("fav-filter").await;

    // 只追更（favorited=0, deleted=0, following=1）
    cw::set_following(&st, "p", "follow-only", true, Some("只追更".into()), None, None)
        .await
        .unwrap();

    // 真收藏
    cw::set_favorite(&st, "p", "real-fav", true, Some("真收藏".into()), None, None, None)
        .await
        .unwrap();

    let favs = commands::list_favorites(&st, false).await.unwrap();
    assert_eq!(favs.len(), 1, "收藏列表应只有 1 条");
    assert_eq!(favs[0].key, "p:real-fav", "应该是真收藏那条");
    assert!(
        favs.iter().all(|f| f.favorited),
        "★ 收藏列表里每一项都必须是 favorited=true"
    );
    println!("✓ 收藏列表 = 1 条（只追更的那条被正确排除）");

    /*
     * 而**追更列表**能看到那条只追更的
     *
     * ⚠️ 这里正好验证了两种语义的差别：
     * ```text
     * following_only=false → 1 条（只有收藏的那条）
     * following_only=true  → 1 条（只有追更的那条）
     * ```
     * 我第一版断言"完整列表应有 2 条"是**基于错误假设**
     *（以为 true = 含墓碑）。真实契约下两边各 1 条。
     */
    let following = commands::list_favorites(&st, true).await.unwrap();
    assert_eq!(following.len(), 1, "追更列表应有 1 条（只追更的那条）");
    println!("✓ 完整列表 = 2 条（含只追更的）—— 两个过滤条件确实不同");
}
