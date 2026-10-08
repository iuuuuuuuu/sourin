// ═══════════════════════════════════════════════════════════════════════
//  独立验证（fix-autoscroll）—— `not a function` 的**四象限**实测
// ═══════════════════════════════════════════════════════════════════════
//
// # 任务来源
//
// Lead 要求（逐字）：
// ```text
// ② ★ 验**边界**：
//    · 声明 false + 不实现 ⇒ 应该？ （期望：降级，不报错）
//    · 声明 true  + 实现   ⇒ 应该？ （期望：正常返回）
//    · 声明 true  + 不实现 ⇒ 应该？ （期望：**报错**还是降级？—— 那是设计决定）
//    · 声明 false + 实现   ⇒ 应该？
// ③ ★★ 并**顺手查**其它可选方法（timeshift / search / …）
//    有没有**同样的形态**（声明 false + 不实现 + 无条件调用）
// ★ 判据：★ **四象限都要有实测读数**（不是推理）
// ```
//
// # 为什么用**独立**文件（不改生产代码）
// ```text
// `JsPluginProvider::from_source` 是 **pub** ⇒ 我可以在 `tests/` 里
// 独立构造四种插件形态，**不需要**动 `src/plugins/mod.rs`。
// ★ 这与 owner 那条 `unimplemented_epg_and_timeshift_degrade_gracefully`
//   （在 src 的 `#[cfg(test)] mod tests` 里）**不同源** ⇒ 是真正的独立验证。
// ```
//
// # ★ 四象限（2×2：capabilities 声明 × 是否实现）
// ```text
//                      实现 epg           不实现 epg
//   声明 epg: true     Q2 正常返回        Q3 ★ 争议象限（设计决定）
//   声明 epg: false    Q4 ★ 少见          Q1 ★ 本 bug 的形态（iptv.js）
// ```
// ★ Lead 特别点了 Q3："期望：报错还是降级？—— 那是设计决定"
//   ⇒ 我**实测**它现在的行为，并**指出**它是设计决定（不擅自判定对错）。
//
// # 为什么**只验行为，不验实现**
// ```text
// 我不去断言"代码里有 `plugin.epg ?` 这个三元"（那是**静态**判据，
// 会被注释匹配 / 写法变化干扰）。
// ⇒ 而是**真的调一次** `p.epg(...)` 看返回什么 ⇒ 行为层判据（更硬）。
// ```

use sourin_core::model::ErrorKind;
use sourin_core::plugins::JsPluginProvider;
// ★★ 必须把 `MediaProvider` trait 引入作用域 —— `epg()` / `timeshift()` /
//    `search()` 都是 **trait 方法**（不是 `JsPluginProvider` 的固有方法）
//    ⇒ 我第一版漏了这个 import ⇒ 8 个 E0599（no method named ...）
//    ⇒ 第二版又猜成了 `Provider`，实际名字是 **`MediaProvider`**
//       （★ 这又是"先查真实名字，别猜"—— 铁律 116 的适用面比 UI 更广）
use sourin_core::provider::MediaProvider;

/// 构造一个插件：`epg_declared` 控制能力位声明，`epg_impl` 控制是否实现
fn plugin_src(epg_declared: &str, epg_impl: bool, timeshift_impl: bool) -> String {
    let mut s = String::new();
    s.push_str("/** @id q @name 四象限探针 */\n");
    s.push_str("globalThis.plugin = {\n");
    s.push_str("  id: 'q',\n");
    s.push_str(&format!(
        "  capabilities: {{ vod: true, live: true, epg: {} }},\n",
        epg_declared
    ));
    s.push_str("  async liveChannels() { return [{ id: 'c1', name: '频道一' }]; },\n");
    s.push_str("  async liveStream() { return [{ url: 'https://x/a.m3u8', kind: 'hls' }]; },\n");
    if epg_impl {
        // ★ 实现的 epg 返回**可区分**的哨兵值，便于断言"真的调到了我的实现"
        s.push_str(
            "  async epg(id) { return [{ title: 'SENTINEL-' + id, start: 1, end: 2 }]; },\n",
        );
    }
    if timeshift_impl {
        s.push_str(
            "  async timeshift(id) { return { url: 'https://x/ts.m3u8', kind: 'hls' }; },\n",
        );
    }
    s.push_str("};\n");
    s
}

// ═══════════════════════════════════════════════════════════════════════
//  Q1 ★ 声明 false + 不实现 —— **本 bug 的形态**（iptv.js 就是这样）
// ═══════════════════════════════════════════════════════════════════════
#[tokio::test]
async fn q1_declared_false_not_implemented_must_degrade() {
    let p = JsPluginProvider::from_source(&plugin_src("false", false, false)).unwrap();

    // ★ 核心：不能是 Err("not a function")
    let r = p.epg("c1", None).await;
    match &r {
        Ok(v) => {
            println!("Q1|epg ⇒ Ok(len={})", v.len());
            assert!(v.is_empty(), "★ 声明 false 且不实现 ⇒ 应降级为空列表");
        }
        Err(e) => {
            println!("Q1|epg ⇒ Err(kind={:?}, msg={})", e.kind, e.message);
            assert!(
                !e.message.contains("not a function"),
                "★★ Q1 失败：这就是真机刷的那条错误！ msg={}",
                e.message
            );
            panic!("★ 声明 false 且不实现 ⇒ 不该报错（应降级），实际 Err: {}", e.message);
        }
    }

    // timeshift：必须 Unsupported（不是 not a function）
    let t = p.timeshift("c1", 0, 100).await;
    match &t {
        Err(e) => {
            println!("Q1|timeshift ⇒ Err(kind={:?}, msg={})", e.kind, e.message);
            assert_eq!(e.kind, ErrorKind::Unsupported,
                "★ timeshift 没实现 ⇒ 必须是 Unsupported，实际 {:?}", e.kind);
            assert!(!e.message.contains("not a function"),
                "★★ Q1 失败：timeshift 报 not a function: {}", e.message);
        }
        Ok(c) => panic!("★ timeshift 没实现 ⇒ 不该 Ok，实际 {:?}", c.url),
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Q2 声明 true + 实现 —— 正常路径（阳性对照）
// ═══════════════════════════════════════════════════════════════════════
#[tokio::test]
async fn q2_declared_true_and_implemented_returns_data() {
    let p = JsPluginProvider::from_source(&plugin_src("true", true, true)).unwrap();

    let v = p.epg("c1", None).await.expect("★ 实现了 epg ⇒ 必须成功");
    println!("Q2|epg ⇒ Ok(len={}) title={:?}", v.len(), v.first().map(|e| &e.title));
    // ★ 断言"真的调到了我的实现"（哨兵值）—— 否则"成功"可能来自别的路径
    assert_eq!(v.len(), 1, "★ 应拿到实现返回的 1 条");
    assert!(v[0].title.contains("SENTINEL-c1"),
        "★★ 必须是插件**实现**返回的哨兵值（证明真的调到了它），实际 {:?}", v[0].title);

    let c = p.timeshift("c1", 0, 100).await.expect("★ 实现了 timeshift ⇒ 必须成功");
    println!("Q2|timeshift ⇒ Ok(url={})", c.url);
    assert!(c.url.contains("ts.m3u8"), "★ 应是实现返回的 url，实际 {}", c.url);
}

// ═══════════════════════════════════════════════════════════════════════
//  Q3 ★★ 声明 true + 不实现 —— Lead 点名的"设计决定"象限
// ═══════════════════════════════════════════════════════════════════════
//
// ```text
// Lead：「声明 true + 不实现 ⇒ 应该？（期望：**报错**还是降级？—— 那是设计决定）」
//
// ★ 我不擅自判定"应该"哪个 —— 我**实测现在的行为**并**指出**它是设计决定：
//     · 若降级为空数组 ⇒ "声明"与"实现"不一致时**以实现为准**
//     · 若报错         ⇒ "声明"是**契约**，违背它要报错
// ⇒ 两种都自洽；关键是**要有意识**地选，而不是碰巧。
// ```
#[tokio::test]
async fn q3_declared_true_not_implemented_records_actual_behavior() {
    let p = JsPluginProvider::from_source(&plugin_src("true", false, false)).unwrap();

    let r = p.epg("c1", None).await;
    match &r {
        Ok(v) => {
            println!("Q3|epg ⇒ Ok(len={}) —— ★ 以**实现**为准（降级），声明 true 但没实现也不报错", v.len());
            assert!(v.is_empty(), "★ 降级 ⇒ 空列表");
        }
        Err(e) => {
            println!("Q3|epg ⇒ Err(kind={:?}, msg={}) —— ★ 以**声明**为准（报错）", e.kind, e.message);
            assert!(!e.message.contains("not a function"),
                "★★ 即使报错也不能是 not a function（那是宿主没守卫）: {}", e.message);
        }
    }

    let t = p.timeshift("c1", 0, 100).await;
    match &t {
        Ok(c) => println!("Q3|timeshift ⇒ Ok(url={}) —— ★ 以实现为准", c.url),
        Err(e) => {
            println!("Q3|timeshift ⇒ Err(kind={:?}, msg={})", e.kind, e.message);
            assert!(!e.message.contains("not a function"),
                "★★ 不能是 not a function: {}", e.message);
        }
    }

    // ★ 无论哪种，**这一条必须成立**：用户不该看到 "not a function"
    println!("Q3|⇒ 实测行为已记录；这是**设计决定**，我不判定对错");
}

// ═══════════════════════════════════════════════════════════════════════
//  Q4 声明 false + 实现 —— 少见象限
// ═══════════════════════════════════════════════════════════════════════
//
// ```text
// 语义上"声明 false 但实现了"= 插件作者**自愿**多提供了一个能力，
//   但没在能力位里声明。
// ★ 关键问题：宿主**会不会**去调它？
//   · 若调 ⇒ 拿到**真实数据**（实现优先）
//   · 若不调 ⇒ 拿到空/降级（声明优先）
// ⇒ 这决定了"能力位到底是**权威**还是**提示**"。
// ```
#[tokio::test]
async fn q4_declared_false_but_implemented_records_actual_behavior() {
    let p = JsPluginProvider::from_source(&plugin_src("false", true, true)).unwrap();

    let r = p.epg("c1", None).await;
    match &r {
        Ok(v) if !v.is_empty() => {
            println!("Q4|epg ⇒ Ok(len={}) title={:?} —— ★ 宿主**仍会调用**实现（能力位不是硬闸门）",
                v.len(), v.first().map(|e| &e.title));
            assert!(v[0].title.contains("SENTINEL"),
                "★ 应是实现返回的哨兵值");
        }
        Ok(v) => {
            println!("Q4|epg ⇒ Ok 但**空**(len={}) —— ★ 声明 false ⇒ 未调用实现", v.len());
        }
        Err(e) => {
            println!("Q4|epg ⇒ Err(kind={:?}, msg={})", e.kind, e.message);
            assert!(!e.message.contains("not a function"),
                "★★ 不能是 not a function: {}", e.message);
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★ 补充：`search` 的闸门验证（Lead 要求 ③ 的一部分）
// ═══════════════════════════════════════════════════════════════════════
//
// ```text
// 我静态审计发现：`plugin.search` 在桥接层**无守卫**（和 epg 修前一样）。
// ★ 那它为什么**没有**在真机上刷 not a function？
//
// 因为 `search_all` 在 **registry 层按能力位过滤了 provider**：
//     registry.rs L273  .filter(|h| h.enabled && capabilities.search)
// ⇒ iptv 声明 `search: false` ⇒ **根本不进 targets**
//   ⇒ `run_one` 收不到它 ⇒ `p.search()` **永远不会被调用**
//
// ★★ 而我全局 grep 确认：`p.search(` 在 src/ 里**只有一处**调用点
//    （registry.rs L254，在 `run_one` 内）⇒ ★ 唯一的路径**有闸门**。
// ```
//
// # ★ 所以本测试的**正确判据**是什么（我第一版写错了）
// ```text
// ✗ 我第一版断言"直接调 search() 也不能报 not a function"
//   ⇒ 那是**比生产要求更强的断言** ⇒ 必然失败（而且**不该**通过）
//   ★ 因为生产路径**根本不会**直接调 search() —— 有 registry 闸门。
//
// ✓ 正确的断言：
//   ① 记录**实际行为**（实测 = Err(not a function)）
//   ② ★ 断言**生产可达性**：唯一的调用点在 `run_one` 内，
//      而 `run_one` 的输入已被能力位过滤
//   ⇒ 结论：**同形态但不可达** ⇒ 不是漏洞（与 epg/timeshift 的关键差别）
// ```
//
// ★ 这正是铁律 115 的**第二次应用**：静态"无守卫"必须配可达性验证。
#[tokio::test]
async fn bonus_search_unimplemented_direct_call_is_unreachable_in_production() {
    // 插件：声明 search:false 且不实现 search（= iptv.js 的形态）
    let src = "/** @id ns @name 无搜索 */\n\
globalThis.plugin = {\n\
  id: 'ns',\n\
  capabilities: { vod: true, search: false },\n\
  async resolve() { return [{ url: 'https://x/a.mp4', kind: 'mp4' }]; },\n\
};\n";
    let p = JsPluginProvider::from_source(src).unwrap();

    // ── ① 记录**实际**行为（不断言"不该报错"——那是过强的断言）──
    let r = p.search("kw", 1).await;
    let actual = match &r {
        Ok(pg) => format!("Ok(items={})", pg.items.len()),
        Err(e) => format!("Err(kind={:?}, msg={})", e.kind, e.message),
    };
    println!("search|直接调用的**实际**行为 ⇒ {actual}");

    /*
     * ② ★★ 断言"生产可达性"而不是"不该报错"
     *
     * ```text
     * `p.search(` 在 src/ 里只有一处调用点：registry.rs L254（在 `run_one` 内）。
     * 而 `run_one` 的调用方 targets 已被过滤：
     *     registry.rs L273  .filter(... capabilities.search)
     * ⇒ 声明 search:false 的 provider **不会**进 targets
     *   ⇒ 它的 search() **永不被调用** ⇒ 不构成生产漏洞。
     *
     * ★ 我用**源码断言**把这条"可达性"钉住 —— 若哪天有人加了**不带闸门**的
     *   直接调用点（就像 epg/timeshift 那样），这条**会红**（提醒补桥接层守卫）。
     * ```
     */
    let reg = std::fs::read_to_string(
        concat!(env!("CARGO_MANIFEST_DIR"), "/src/registry.rs"),
    )
    .expect("读 registry.rs");

    assert!(
        reg.contains("capabilities.search"),
        "★★ registry 必须按 capabilities.search 过滤 provider —— \
         这是 `search` 不构成漏洞的**唯一依据**。若这条没了 ⇒ \
         声明 search:false 的插件会被调 search() ⇒ 刷 not a function"
    );

    // ★ 且"唯一的直接调用点"在 run_one 内（有闸门的路径上）
    let call_sites = reg.matches("p.search(").count();
    println!("search|registry.rs 里 `p.search(` 调用点 = {call_sites}");
    assert_eq!(
        call_sites, 1,
        "★★ `p.search(` 的调用点数量变了（现在 {call_sites} 处）—— \
         若有**新增**的调用点不在能力位闸门后面 ⇒ 需要重新评估可达性"
    );

    // ── ③ 记录：实际行为是 not a function（潜在脆弱性，但不可达）──
    if let Err(e) = &r {
        if e.message.contains("not a function") {
            println!(
                "search|⇒ ★ 直接调用会抛 not a function（桥接层**无守卫**）——\n\
                 search|  但生产**唯二**路径（search_all / search_all_stream）\n\
                 search|  都经 registry 能力位过滤 ⇒ **不可达** ⇒ 不是漏洞。\n\
                 search|  ★ 但它是**潜在脆弱性**：谁若新增『直调 provider.search』\n\
                 search|  的路径，就会立刻复现 not a function —— 与 epg 同族。"
            );
        }
    }
}
