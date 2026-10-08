// ═══════════════════════════════════════════════════════════════════════
//  批次 3 验收 —— 搜索（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这是**真实网络测试**
//
// 与前两批不同：
// ```text
// 批次 1  只读 SQLite        → 离线可测
// 批次 2  写 SQLite          → 离线可测
// 批次 3  真实跨源 HTTP 搜索 → **必须有网、且源可用**
// ```
// 所以这些测试标 `#[ignore]` —— 网络不稳时不该让 CI 变红。
// 显式 `--ignored` 运行，并**打印实测到的数据**（而不是只断言）。
//
// # 用什么数据目录
//
// 用 `%APPDATA%\app.sourin\sourin_spike\mig-probe`（**真实库的副本**）——
// 这样插件也是真实的 26 个，搜索到的才是真实源。
// ⚠️ 用户真实库全程只读，本测试只碰副本。
//
// # 判据
//
// ```text
// ① search_all 真的返回了结果（不是空列表）
// ② 结果的 provider 名 / 标题是真实中文内容
// ③ 封面 URL 被代理（若该源声明了 coverHeaders）
// ④ 流式版：事件逐个到达，最后有 done
// ⑤ 取消语义：回调返回 false 时提前停止
// ```

use sourin_core::commands::{self, SearchStreamEvent};
use sourin_core::state::AppState;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::sync::Mutex;

/// 用真实库副本（含 26 个真实插件）
async fn real_state() -> Arc<AppState> {
    let appdata = std::env::var("APPDATA").expect("APPDATA");
    let dir = std::path::PathBuf::from(appdata)
        .join("app.sourin")
        .join("sourin_spike")
        .join("mig-probe");
    assert!(
        dir.join("dsh-media.db").exists(),
        "真实数据副本不存在: {}",
        dir.display()
    );
    AppState::bootstrap(dir).await.expect("bootstrap")
}

/// ★ search_all：真实跨源搜索
#[tokio::test]
#[ignore = "需要真实网络与可用源，显式 --ignored 运行"]
async fn search_all_returns_real_results() {
    let st = real_state().await;

    let n = st.registry.manifests().len();
    println!("已加载源: {n} 个");
    assert!(n > 1, "应该有真实插件（>1 个源）");

    let kw = "庆余年"; // 常见剧名，多数源都该有
    println!("搜索关键词: {kw}");

    let r = commands::search_all(&st, kw, 1).await.expect("search_all");

    println!();
    println!("═══ 搜索结果 ═══");
    println!("命中源数: {}", r.results.len());
    println!("跳过源数: {}", r.skipped.len());

    // 打印每个命中源的前几条（这是**实测证据**，不只是断言）
    let mut total_items = 0;
    for (pid, pname, pg) in &r.results {
        total_items += pg.items.len();
        println!();
        println!("── {pname} ({pid}) ──");
        println!("   {} 条结果", pg.items.len());
        if let Some(pc) = pg.page_count {
            println!("   总页数: {pc}");
        }
        if let Some(t) = pg.total {
            println!("   总数: {t}");
        }
        for it in pg.items.iter().take(3) {
            println!("   · 《{}》 id={}", it.title, it.id);
            if let Some(c) = &it.cover {
                // ★ 封面是否被代理（本地地址说明 coverHeaders 生效）
                let proxied = c.starts_with("http://127.0.0.1:");
                println!("     封面: {} {}", if proxied { "[已代理]" } else { "[直连]" }, c);
            }
        }
    }

    if !r.skipped.is_empty() {
        println!();
        println!("═══ 跳过的源（UI 应显示原因）═══");
        for (pid, reason) in r.skipped.iter().take(10) {
            println!("   {pid}: {reason}");
        }
    }

    println!();
    assert!(
        !r.results.is_empty() || !r.skipped.is_empty(),
        "既没命中也没跳过 —— 说明搜索根本没跑"
    );
    assert!(total_items > 0, "所有源都返回 0 条结果，搜索可能没生效");
    println!("✓ search_all: {} 个源命中，共 {total_items} 条结果", r.results.len());
}

/// ★ search_all_stream：事件逐个到达 + 最后 done
#[tokio::test]
#[ignore = "需要真实网络与可用源，显式 --ignored 运行"]
async fn search_all_stream_emits_events_then_done() {
    let st = real_state().await;

    /*
     * ★★ 计数器必须用 Arc<AtomicUsize>（2026-09-22 踩到两次）
     *
     * 我第一版写的是裸 `let mut hits = 0;` 然后 `move |ev| { hits += 1 }`。
     * **外层读到的永远是 0** —— 因为 `usize`/`i32` 实现了 `Copy`，
     * `move` 闭包捕获的是**一份拷贝**，改了不影响外层。
     *
     * 症状极具误导性：测试报「命中: 0 个源」，看起来像
     * **代码没送到事件**，实际是测试读不到计数。
     * （`Arc<Mutex<Vec>>` 那种不会踩到 —— Vec 不 Copy，
     *   所以同一个测试里"事件列表"是对的、"计数器"是错的，
     *   更容易误判成代码问题。）
     *
     * 诊断文件 `batch3_diag.rs` 用 AtomicUsize 已证明代码正确：
     *   取消 → 0.68s 返回
     *   首个事件 0.25s / 总耗时 28.19s
     */
    let hits = Arc::new(AtomicUsize::new(0));
    let misses = Arc::new(AtomicUsize::new(0));
    let total_items = Arc::new(AtomicUsize::new(0));
    let first_at = Arc::new(Mutex::new(None::<f64>));
    let events: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let (h, m, ti, fa, ev2) = (
        hits.clone(),
        misses.clone(),
        total_items.clone(),
        first_at.clone(),
        events.clone(),
    );
    let start = std::time::Instant::now();

    commands::search_all_stream(&st, "庆余年", 1, move |ev| {
        match &ev {
            SearchStreamEvent::Hit {
                provider_name,
                items,
                page,
                page_count,
                total,
                ..
            } => {
                h.fetch_add(1, Ordering::SeqCst);
                ti.fetch_add(items.len(), Ordering::SeqCst);
                {
                    let mut g = fa.lock().unwrap();
                    if g.is_none() {
                        // ★ 记录第一个结果到达的时间 —— 流式版的核心价值
                        *g = Some(start.elapsed().as_secs_f64());
                    }
                }
                println!(
                    "  [hit] {provider_name}: {} 条 (page={page} page_count={:?} total={:?})",
                    items.len(),
                    page_count,
                    total
                );
                ev2.lock().unwrap().push(format!("hit:{provider_name}"));
            }
            SearchStreamEvent::Miss { provider, reason } => {
                m.fetch_add(1, Ordering::SeqCst);
                println!("  [miss] {provider}: {reason}");
                ev2.lock().unwrap().push(format!("miss:{provider}"));
            }
        }
        true // 不取消
    })
    .await
    .expect("search_all_stream");

    let elapsed = start.elapsed();
    let (hv, mv, tiv) = (
        hits.load(Ordering::SeqCst),
        misses.load(Ordering::SeqCst),
        total_items.load(Ordering::SeqCst),
    );
    println!();
    println!("═══ 流式搜索汇总 ═══");
    println!("命中: {hv} 个源，共 {tiv} 条");
    println!("失败: {mv} 个源");
    println!("总耗时: {:.2}s", elapsed.as_secs_f64());
    if let Some(f) = *first_at.lock().unwrap() {
        println!(
            "★ 首个结果到达: {f:.2}s（比总耗时早 {:.2}s —— 这就是流式的价值）",
            elapsed.as_secs_f64() - f
        );
    }

    assert!(hv + mv > 0, "一个事件都没收到");
    assert!(hv > 0, "没有任何源命中");
    println!("✓ 流式搜索: {hv} hit + {mv} miss");
}

/// ★★ 取消语义：回调返回 false 应立即停止
///
/// 这是**用户体验的关键**：用户关掉搜索页后不该继续跑几十个请求。
#[tokio::test]
#[ignore = "需要真实网络与可用源，显式 --ignored 运行"]
async fn stream_callback_false_stops_early() {
    let st = real_state().await;

    // ★ 同样必须用 AtomicUsize（见上面流式测试的注释）
    let count = Arc::new(AtomicUsize::new(0));
    let c2 = count.clone();
    let start = std::time::Instant::now();

    commands::search_all_stream(&st, "测试", 1, move |_ev| {
        let c = c2.fetch_add(1, Ordering::SeqCst) + 1;
        // ★ 收到第 2 个事件后就取消
        c < 2
    })
    .await
    .expect("search_all_stream");

    let elapsed = start.elapsed();
    let got = count.load(Ordering::SeqCst);
    println!("收到 {got} 个事件后取消，耗时 {:.2}s", elapsed.as_secs_f64());

    assert_eq!(got, 2, "应在第 2 个事件后停止（got={got}）");

    /*
     * ★★ 关键断言：取消必须**立即**返回，而不是等剩余源跑完
     *
     * 实测过这个 bug：第一版取消后仍等 32.82s 才返回
     *（因为 break 后还 `producer.await`，且当前源不会被打断）。
     * 修法是 `producer.abort()` —— 修复后 0.68s。
     *
     * 这里设 5 秒阈值：正常应 <1s，给网络抖动留余量。
     * 若退回 30s 说明 abort 被误删了。
     */
    assert!(
        elapsed.as_secs_f64() < 5.0,
        "取消后应立即返回（实测 {:.2}s）—— 超过 5s 说明没 abort 生产者",
        elapsed.as_secs_f64()
    );
    println!("✓ 取消生效：恰好 2 个事件，{:.2}s 返回（立即停止）", elapsed.as_secs_f64());
}

/// 空关键词 / 无结果关键词不该 panic
#[tokio::test]
#[ignore = "需要真实网络与可用源，显式 --ignored 运行"]
async fn search_handles_weird_keywords() {
    let st = real_state().await;

    // 一个几乎不可能有结果的关键词
    let weird = "zzzzqqqq不存在的片名9999";
    let r = commands::search_all(&st, weird, 1).await;
    match r {
        Ok(r) => {
            let items: usize = r.results.iter().map(|(_, _, p)| p.items.len()).sum();
            println!("✓ 无结果关键词: {} 源命中 / {} 源跳过 / {items} 条结果", r.results.len(), r.skipped.len());
        }
        Err(e) => {
            // 全部源都失败也算合理（网络问题），但不该 panic
            println!("✓ 无结果关键词返回错误（可接受）: {e}");
        }
    }

    // 空关键词
    let r = commands::search_all(&st, "", 1).await;
    println!(
        "✓ 空关键词: {}",
        match &r {
            Ok(x) => format!("{} 源命中", x.results.len()),
            Err(e) => format!("错误（可接受）: {e}"),
        }
    );
}
