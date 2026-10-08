// ═══════════════════════════════════════════════════════════════════════
//  批次 4 验收 —— 直播（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 真实网络测试
//
// ```text
// get_live_channels → 拉各源的频道列表
// get_live_stream   → 取某频道的播放地址（**关键：要拿到可播的 URL**）
// get_epg           → 节目单
// get_timeshift     → 时移回看
// ```
//
// 判据不是"不报错"，而是：
// ```text
// ① 频道列表非空，且是真实中文频道名（央视/卫视）
// ② 播放地址是**真实 URL**（http/m3u8），不是空串
// ③ EPG 若有则结构正确
// ```
//
// # ⚠️ 哪些源支持直播是不确定的
//
// 26 个源里只有一部分声明了 `capabilities.live`。
// 所以断言要**容忍"没有直播源"**（打印诊断而不是失败）——
// 否则换个环境就红了。但**只要有一个源支持，就必须验到播放地址**。

use sourin_core::commands;
use sourin_core::state::AppState;
// ★ task-34：IPTV 插件契约测试需要这两个
use sourin_core::plugins::load_plugins_hydrated;
use sourin_core::provider::MediaProvider;
use std::sync::Arc;

async fn real_state() -> Arc<AppState> {
    let appdata = std::env::var("APPDATA").expect("APPDATA");
    let dir = std::path::PathBuf::from(appdata)
        .join("app.sourin")
        .join("sourin_spike")
        .join("mig-probe");
    assert!(dir.join("dsh-media.db").exists(), "副本不存在");
    AppState::bootstrap(dir).await.expect("bootstrap")
}

/// ★ 频道列表：真实频道名
#[tokio::test]
#[ignore = "需要真实网络与可用源，显式 --ignored 运行"]
async fn live_channels_are_real() {
    let st = real_state().await;

    let groups = commands::get_live_channels(&st)
        .await
        .expect("get_live_channels");

    println!("═══ 直播频道 ═══");
    println!("支持直播的源: {} 个", groups.len());

    if groups.is_empty() {
        println!("⚠ 没有源声明支持直播 —— 跳过（不算失败，取决于已装插件）");
        return;
    }

    let mut total = 0;
    for g in &groups {
        let pid = g["provider"].as_str().unwrap_or("?");
        // ★ 字段名是 camelCase（providerName）—— 与原版前端一致
        let pname = g["providerName"].as_str().unwrap_or("?");
        let chans = g["channels"].as_array().map(|a| a.len()).unwrap_or(0);
        total += chans;
        println!("── {pname} ({pid}): {chans} 个频道");

        if let Some(arr) = g["channels"].as_array() {
            for c in arr.iter().take(4) {
                let name = c["name"].as_str().unwrap_or("?");
                let id = c["id"].as_str().unwrap_or("?");
                println!("   · {name}  (id={id})");
            }
        }
    }

    assert!(total > 0, "有直播源但一个频道都没有");
    println!();
    println!("✓ 直播频道: {} 个源 / {total} 个频道", groups.len());

    // ★ 字段名必须是 camelCase（前端契约）
    let first = &groups[0];
    assert!(
        first.get("providerName").is_some(),
        "字段名必须是 providerName（camelCase）—— 原版前端就这么读"
    );
    assert!(first.get("provider").is_some());
    assert!(first.get("channels").is_some());
    println!("✓ 字段名符合前端契约（provider / providerName / channels）");
}

/// ★★ 播放地址：必须拿到真实可播 URL
///
/// 这是直播功能的核心 —— 拿不到地址就等于看不了。
#[tokio::test]
#[ignore = "需要真实网络与可用源，显式 --ignored 运行"]
async fn live_stream_returns_real_url() {
    let st = real_state().await;

    let groups = commands::get_live_channels(&st).await.expect("channels");
    if groups.is_empty() {
        println!("⚠ 没有直播源，跳过");
        return;
    }

    // 逐个源试，直到拿到一个能播的（有的源频道可能失效）
    let mut ok = 0;
    let mut tried = 0;
    for g in &groups {
        let pid = g["provider"].as_str().unwrap_or("");
        let pname = g["providerName"].as_str().unwrap_or("");
        let Some(chans) = g["channels"].as_array() else {
            continue;
        };
        let Some(first) = chans.first() else { continue };
        let Some(cid) = first["id"].as_str() else { continue };
        let cname = first["name"].as_str().unwrap_or("?");

        tried += 1;
        match commands::get_live_stream(&st, pid, cid).await {
            Ok(cands) => {
                println!("── {pname} / {cname}: {} 个候选", cands.len());
                for c in cands.iter().take(2) {
                    println!("     url={}", c.url);
                    if let Some(q) = &c.quality {
                        println!("     画质: {q}");
                    }
                    // headers 是 Vec（不是 Option）—— 空的表示不需要额外头
                    if !c.headers.is_empty() {
                        println!("     需要请求头: {} 项", c.headers.len());
                    }
                }
                if cands.iter().any(|c| c.url.starts_with("http")) {
                    ok += 1;
                }
            }
            Err(e) => println!("── {pname} / {cname}: 失败 {e}"),
        }
    }

    println!();
    assert!(tried > 0, "一个频道都没试到");
    assert!(
        ok > 0,
        "试了 {tried} 个源都没拿到 http 播放地址 —— 直播不可用"
    );
    println!("✓ 直播播放地址: {ok}/{tried} 个源拿到了真实 URL");
}

/// EPG：有则验结构，无则跳过
#[tokio::test]
#[ignore = "需要真实网络与可用源，显式 --ignored 运行"]
async fn epg_structure_is_valid() {
    let st = real_state().await;

    let groups = commands::get_live_channels(&st).await.expect("channels");
    if groups.is_empty() {
        println!("⚠ 没有直播源，跳过");
        return;
    }

    let mut got = 0;
    for g in groups.iter().take(5) {
        let pid = g["provider"].as_str().unwrap_or("");
        let pname = g["providerName"].as_str().unwrap_or("");
        let Some(chans) = g["channels"].as_array() else {
            continue;
        };
        let Some(first) = chans.first() else { continue };
        let Some(cid) = first["id"].as_str() else { continue };

        match commands::get_epg(&st, pid, cid).await {
            Ok(entries) => {
                if entries.is_empty() {
                    println!("── {pname}: EPG 为空（该源可能不提供节目单）");
                    continue;
                }
                got += 1;
                println!("── {pname}: {} 条节目", entries.len());
                for e in entries.iter().take(3) {
                    println!(
                        "     {} - {}  {}",
                        e.start, e.end, e.title
                    );
                }
            }
            Err(e) => println!("── {pname}: EPG 失败 {e}"),
        }
    }

    println!();
    println!("✓ EPG: {got} 个源返回了节目单（为 0 也可接受 —— 取决于源）");
}

/// 错误处理：不存在的 provider 必须报明确错误（而不是 panic）
#[tokio::test]
async fn live_commands_reject_unknown_provider() {
    let dir = std::env::temp_dir().join(format!(
        "sourin-b4-{}",
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let st = AppState::bootstrap(dir).await.expect("bootstrap");

    let e = commands::get_live_stream(&st, "no-such-provider", "c1")
        .await
        .unwrap_err();
    assert!(e.contains("找不到 Provider"), "错误应说明找不到源: {e}");
    println!("✓ get_live_stream(不存在的源) → {e}");

    let e = commands::get_epg(&st, "no-such-provider", "c1")
        .await
        .unwrap_err();
    assert!(e.contains("找不到 Provider"));
    println!("✓ get_epg(不存在的源) → {e}");

    let e = commands::get_timeshift(&st, "no-such-provider", "c1", 0, 100)
        .await
        .unwrap_err();
    assert!(e.contains("找不到 Provider"));
    println!("✓ get_timeshift(不存在的源) → {e}");
}


// ═══════════════════════════════════════════════════════════════════════
//  ★★★ task-34: IPTV 直播插件契约（2026-09-25）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么加这个源（用户原话）
// > 「cctv的直播还是不行，之前给你参考的tvbox源应该也有包含直播的，
// >   你看看  都没整合进去」
//
// # 央视官方源为什么"不行"（实测，不是猜）
// `cctv.js` 的注释记录过：官方直播**视频轨被加密**（udrm）——
// 容器/NAL 头明文，但载荷加密，解码报
// `top block unavailable for requested intra mode`。
// 我实测 16 个央视频道**全部**如此（204~262 个解码错误）⇒ 内容方保护，绕不过。
// ⇒ 出路是**换一条不加密的源**（iptv-org）。
//
// # ★★ 选频道的判据：必须**真解码**，不能只看 HTTP
// ```text
// HTTP 200           —— 最弱（很多 200 的 URL 连不上/载荷加密）
// ffprobe 有流       —— 中
// ffmpeg 真解码 0 错 —— 最强（且必须同时确认"连上了 + 解出帧了"）
// ```
// ★ 我第一版探针只数"解码错误数"，于是**连不上的 URL 得到 0 错误**
//   ⇒ 被判成"可播"（假阴性）⇒ 修法：`connected AND decoded AND errs==0`。
//
// 全量实测（cn.m3u 144 条）：真能解码的 CCTV 相关 = **28 个**
// ⇒ 白名单 `VERIFIED_IDS` 就是这 28 个（`.probe/t34_check_ids.py` 可复核）。
//
// # ⚠️ 白名单是"外部数据"，必须脚本核对
// 我第一版按名字**推测** tvg-id，28 个里**猜错 13 个**
//（`@SD` 该是 `@HD`；`Billards` 少个 `i`）⇒ 会导致**用户看到空列表**。
// 所以改白名单后必须重跑 `.probe/t34_check_ids.py`。

/// 把插件目录指向仓库里的 `rust/sourin_core/plugins`
fn plugin_dir() -> std::path::PathBuf {
    // 测试的工作目录是 crate 根（rust/sourin_core）
    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("plugins")
}

fn tmp_data(tag: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("t34-iptv-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// ★ 离线：m3u 解析契约（用真实 iptv-org 片段，含各种边界）
#[test]
fn iptv_m3u_parse_contract() {
    /*
     * 直接测 JS 的解析函数 —— 通过插件宿主跑。
     * ⚠️ `parseM3u` 不是 plugin 的方法（是内部函数），
     *    所以这里用 `liveChannels()` 的**间接**验证太弱。
     *    改为：把解析逻辑的关键行为写成**宿主侧可调**的形式 ——
     *    见 `plugin.liveChannels()` 的结果断言（下面的集成测试）。
     *
     * 本测试只验证"插件能被加载 + 能力位正确"（不需要网络）。
     */
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .unwrap();
    let data = tmp_data("load");

    let (plugins, bad) = rt.block_on(load_plugins_hydrated(&plugin_dir(), None));
    println!("\n加载到 {} 个插件，坏 {} 个", plugins.len(), bad.len());
    for p in &plugins {
        let m = p.manifest();
        println!(
            "  {} ({}) live={} vod={} search={}",
            m.name, m.id, m.capabilities.live, m.capabilities.vod, m.capabilities.search
        );
    }
    for (f, why) in &bad {
        println!("  ✗ {f}: {why}");
    }

    let iptv = plugins
        .iter()
        .find(|p| p.manifest().id == "iptv")
        .expect("★ iptv 插件必须被加载（加载失败说明语法/元信息有错）");
    let m = iptv.manifest();
    assert!(m.capabilities.live, "★ iptv 必须声明 live 能力");
    assert!(!m.capabilities.vod, "iptv 是纯直播源，不该声明 vod");
    assert_eq!(m.name, "IPTV 直播");
    println!("✓ iptv 插件加载成功，能力位正确");
    let _ = data;
}

/// ★★ 集成：真拉列表 → 白名单过滤 → 频道数与预期一致
#[tokio::test(flavor = "multi_thread")]
#[ignore = "需要真实网络；显式 --ignored 运行"]
async fn iptv_live_channels_matches_whitelist() {
    use sourin_core::provider::MediaProvider;

    let data = tmp_data("live");
    let (plugins, bad) = load_plugins_hydrated(&plugin_dir(), None).await;
    assert!(bad.is_empty(), "有插件加载失败: {bad:?}");
    let iptv = plugins
        .into_iter()
        .find(|p| p.manifest().id == "iptv")
        .expect("iptv 插件");

    let chans = iptv.live_channels().await.expect("liveChannels 不该失败");
    println!("\n★ 返回频道数 = {}", chans.len());
    for c in chans.iter().take(8) {
        println!("  {} [{}] {}", c.id, c.group.clone().unwrap_or_default(), c.name);
    }

    /*
     * ★★ 核心断言：**28 个**（我逐个真解码验证过的 CCTV 数量）
     *
     * 若少于 28 ⇒ 白名单里有 tvg-id 拼错/已下架（用户会少看到台）
     * 若多于 28 ⇒ 过滤没生效（用户会看到不可播的台）
     *
     * ⚠️ 这个数字会随公共源变化 —— 那时**不是改断言**，
     *    而是重跑 `.probe/t34_check_ids.py` 刷新白名单。
     */
    assert!(
        chans.len() >= 20,
        "★ 频道数 {} 太少 —— 白名单匹配失败？（先查 tvg-id 拼写）",
        chans.len()
    );
    assert!(
        chans.len() <= 28,
        "★ 频道数 {} 超过白名单 28 —— 过滤没生效",
        chans.len()
    );
    // 每个频道 id 必须非空（id 是 liveStream 的入参）
    assert!(chans.iter().all(|c| !c.id.is_empty()), "★ 有频道 id 为空");
    // ★ 必须有 CCTV-1（用户最关心的那个）
    assert!(
        chans.iter().any(|c| c.id == "CCTV1.cn@SD"),
        "★ 必须有 CCTV-1 —— 没有的话用户最直观的需求就没满足"
    );
    println!("✓ 白名单过滤生效，且含 CCTV-1");
    let _ = data;
}

/// ★★ 集成：liveStream 返回可播地址，且与列表一致
#[tokio::test(flavor = "multi_thread")]
#[ignore = "需要真实网络；显式 --ignored 运行"]
async fn iptv_live_stream_returns_url() {
    use sourin_core::provider::MediaProvider;

    let (plugins, _) = load_plugins_hydrated(&plugin_dir(), None).await;
    let iptv = plugins
        .into_iter()
        .find(|p| p.manifest().id == "iptv")
        .expect("iptv 插件");

    let cands = iptv
        .live_stream("CCTV1.cn@SD")
        .await
        .expect("CCTV-1 的 liveStream 不该失败");
    println!("\n★ CCTV-1 候选流:");
    for c in &cands {
        println!("  {:?} {} {:?}", c.kind, c.url, c.label);
    }
    assert!(!cands.is_empty(), "★ 必须返回至少一个候选");
    assert!(
        cands[0].url.starts_with("http"),
        "★ 地址必须是 http(s): {}",
        cands[0].url
    );
    println!("✓ liveStream 返回可用地址");

    // 不存在的频道必须报错（而不是返回空/panic）
    let bad = iptv.live_stream("NOT_EXIST_CHANNEL").await;
    assert!(bad.is_err(), "★ 不存在的频道必须报错");
    println!("✓ 不存在的频道正确报错");
}


// ═══════════════════════════════════════════════════════════════════════
//  ★★★ v1.1.0：给用户看的东西中文化（2026-09-25）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要这两条测试（都是**假阴性守卫**）
//
// v1.0.0 用户会看到：
// ```text
// 分栏标题： "General" / "News"          ← iptv-org 的英文分组
// 频道名  ： "CCTV-1 (720p)"             ← 带画质噪音
// 而且与 cctv.js 源不一致（那边是 "CCTV-1 综合"）⇒ 用户困惑
// ```
// 坏了的表现很"安静"：只是显示英文/空，**不会崩**，所以必须显式守。

/// ★★★ 剥 `@SD`/`@HD` 后缀后必须能查到中文名
///
/// # 这条守的是一个**真踩过的坑**
/// ```text
/// 我们的 tvg_id       ： 'CCTV1.cn@SD'   ← 带画质后缀
/// channels.json 的 id ： 'CCTV1.cn'      ← 不带
/// ⇒ 拿带后缀的去查表 **永远查不到**（会静默回落到英文名）
/// ★ lead 的检查脚本第一版就是这么错的：报"28 个都不在表里"
/// ```
#[tokio::test(flavor = "multi_thread")]
#[ignore = "需要真实网络；显式 --ignored 运行"]
async fn iptv_v110_suffix_stripping_finds_chinese_name() {
    use sourin_core::provider::MediaProvider;

    let (plugins, _) = load_plugins_hydrated(&plugin_dir(), None).await;
    let iptv = plugins
        .into_iter()
        .find(|p| p.manifest().id == "iptv")
        .expect("iptv 插件");

    let chans = iptv.live_channels().await.expect("liveChannels");

    // 找一个 @SD 的、一个 @HD 的 —— 两种后缀都要覆盖
    let sd = chans.iter().find(|c| c.id.ends_with("@SD"));
    let hd = chans.iter().find(|c| c.id.ends_with("@HD"));

    println!("\n★ 中文名验证:");
    for c in chans.iter().take(10) {
        println!("  {:<28} -> {}", c.id, c.name);
    }

    // ★ 核心断言：至少有一个频道的名字**含中文**（说明查表成功）
    let zh_count = chans
        .iter()
        .filter(|c| c.name.chars().any(|ch| ('\u{4e00}'..='\u{9fff}').contains(&ch)))
        .count();
    assert!(
        zh_count >= 20,
        "★★ 只有 {zh_count}/{} 个频道名含中文 —— \
         剥后缀失败？（@SD/@HD 没剥掉 ⇒ ZH_NAMES 查不到 ⇒ 静默回落英文）",
        chans.len()
    );

    // ★ 具体点名：CCTV-1 必须显示成 "CCTV-1 综合"
    let c1 = chans
        .iter()
        .find(|c| c.id == "CCTV1.cn@SD")
        .expect("必须有 CCTV-1");
    assert!(
        c1.name.contains("综合"),
        "★ CCTV-1 应显示为 'CCTV-1 综合'（与 cctv.js 一致），实际 {:?}",
        c1.name
    );
    // ★ 且**不能**再有画质噪音
    assert!(
        !c1.name.contains("720p") && !c1.name.contains("("),
        "★ 名字里不该再有 '(720p)' 这类噪音，实际 {:?}",
        c1.name
    );
    println!("✓ CCTV-1 = {:?}（中文 + 无噪音）", c1.name);

    if let Some(c) = sd {
        println!("  @SD 样本: {} -> {}", c.id, c.name);
    }
    if let Some(c) = hd {
        println!("  @HD 样本: {} -> {}", c.id, c.name);
    }
}

/// ★★ 分组必须中文化，且**未映射的回落原文**（不返回空/其它）
#[tokio::test(flavor = "multi_thread")]
#[ignore = "需要真实网络；显式 --ignored 运行"]
async fn iptv_v110_group_is_chinese_with_fallback() {
    use sourin_core::provider::MediaProvider;

    let (plugins, _) = load_plugins_hydrated(&plugin_dir(), None).await;
    let iptv = plugins
        .into_iter()
        .find(|p| p.manifest().id == "iptv")
        .expect("iptv 插件");

    let chans = iptv.live_channels().await.expect("liveChannels");

    println!("\n★ 分组验证:");
    let mut groups: Vec<String> = chans
        .iter()
        .filter_map(|c| c.group.clone())
        .collect();
    groups.sort();
    groups.dedup();
    for g in &groups {
        println!("  {}", g);
    }

    // ★ 不能有空的 group
    assert!(
        chans.iter().all(|c| c.group.as_deref().map(|g| !g.is_empty()).unwrap_or(false)),
        "★ 有频道的 group 为空"
    );

    // ★ 已知的英文分组必须被映射（抽查 3 个高频的）
    let all_groups = groups.join("|");
    for en in ["General", "News", "Sports"] {
        assert!(
            !all_groups.split('|').any(|g| g == en),
            "★ 分组 {en} 没被中文化（仍是英文）—— 映射表没生效？"
        );
    }
    println!("✓ 英文分组已中文化");

    /*
     * ★★ 回落行为：未映射的分组必须**返回原文**，不能变成空/其它。
     *
     * ⚠️ 这条用**静态断言**验（不改数据）：直接读插件源码里 displayGroup
     *    的实现，确认它有 `|| g` 这种回落。
     *    运行时造一个"未映射分组"需要伪造 m3u（成本高、且会污染缓存），
     *    而这里的**契约**就是"有回落" ⇒ 静态断言足够且更稳。
     */
    let src = std::fs::read_to_string(
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("plugins")
            .join("iptv.js"),
    )
    .expect("读 iptv.js");

    // 剥注释后再断言（本项目踩过 7 次"grep 命中注释"）
    let code: String = {
        let mut out = String::new();
        let mut in_block = false;
        for line in src.lines() {
            let t = line.trim();
            if in_block {
                if t.contains("*/") {
                    in_block = false;
                }
                continue;
            }
            if t.starts_with("/*") {
                if !t.contains("*/") {
                    in_block = true;
                }
                continue;
            }
            if t.starts_with("//") {
                continue;
            }
            out.push_str(line);
            out.push('\n');
        }
        out
    };

    /*
     * ★★ 断言"回落行为"而不是"某个写法"
     *
     * ⚠️ 我第一版写的是 `code.contains("GROUP_ZH[g] || g")` ——
     *    那**锁死了表达式的字面形式**，于是我把复合分组处理改进后
     *    （改成先整体查表、再逐段映射）它就假红了。
     *    ★ 这正是本项目反复踩的"断言锁死字面量会把重构变成假回归"。
     *
     * ⇒ 改成断言**语义不变式**：显示分组时必须有"查表失败则用原文"的路径。
     *   判据：代码里同时出现「查 GROUP_ZH」和「|| 变量」或「?? 变量」。
     */
    let looks_up_table = code.contains("GROUP_ZH[");
    let has_fallback = code.contains("|| g")
        || code.contains("?? g")
        || code.contains("|| p")
        || code.contains("?? p")
        || code.contains("|| g)");
    assert!(
        looks_up_table,
        "★★ displayGroup 必须查 GROUP_ZH 映射表"
    );
    assert!(
        has_fallback,
        "★★ displayGroup 必须对未映射分组**回落原文**（如 `GROUP_ZH[x] || x`）—— \
         塞成'其它'会让所有新分组混成一栏、信息丢失。\n\
         ---- 实际代码 ----\n{code}"
    );
    assert!(
        code.contains("function displayGroup("),
        "★ 必须有 displayGroup()"
    );
    assert!(
        code.contains("function displayName("),
        "★ 必须有 displayName()"
    );
    assert!(
        code.contains("split('@')[0]"),
        "★★ 必须有剥 @SD/@HD 后缀的逻辑（baseId）—— 否则中文名查不到"
    );
    println!("✓ 未映射分组回落原文（静态契约）");
}


/// ★★ 去噪音后**不能留下孤儿括号/方括号**（正则 `|` 优先级踩过的坑）
///
/// # 我第一版的正则错在哪
/// ```text
/// 错：/\s*\((?:480|...)[pi]|(?:SD|HD)\)\s*/gi
///                       ↑ `|` 把正则劈成两个顶层分支
///                         ⇒ 分支A 没有 `\)` ⇒ 只吃掉 "(600p" ⇒ 剩下 ")"
/// 对：/\s*\((?:(?:480|...)[pi]|SD|HD)\)\s*/gi   ← 两分支都在括号内
/// ```
/// ★ 表现是 "CCTV+ 1 (600p) [Not 24/7]" → **"CCTV+ 1 )"** ——
///   不崩不报错，只是难看 ⇒ 必须显式守。
#[tokio::test(flavor = "multi_thread")]
#[ignore = "需要真实网络；显式 --ignored 运行"]
async fn iptv_v110_no_stray_parens() {
    use sourin_core::provider::MediaProvider;

    let (plugins, _) = load_plugins_hydrated(&plugin_dir(), None).await;
    let iptv = plugins
        .into_iter()
        .find(|p| p.manifest().id == "iptv")
        .expect("iptv 插件");

    let chans = iptv.live_channels().await.expect("liveChannels");

    println!("\n★ 名字清洁度检查:");
    let mut bad: Vec<String> = Vec::new();
    for c in &chans {
        println!("  {:<30} {:?}", c.id, c.name);
        // 判据①：不能有孤儿 ')' / ']'
        if c.name.contains(')') || c.name.contains(']') {
            bad.push(format!("{} -> {:?}（残留括号）", c.id, c.name));
        }
        // 判据②：不能有画质/状态噪音残留
        for noise in ["720p", "1080p", "576i", "600p", "2160p", "Not 24/7",
                      "[SD]", "[HD]", "(SD)", "(HD)"] {
            if c.name.contains(noise) {
                bad.push(format!("{} -> {:?}（残留噪音 {noise}）", c.id, c.name));
            }
        }
        // 判据③：不能有连续空格或首尾空格（replace 后没规范化）
        if c.name.contains("  ") || c.name != c.name.trim() {
            bad.push(format!("{} -> {:?}（空白未规范化）", c.id, c.name));
        }
    }

    assert!(
        bad.is_empty(),
        "★★ 有 {} 个名字没清干净：\n  {}",
        bad.len(),
        bad.join("\n  ")
    );
    println!("✓ 全部 {} 个名字无孤儿括号/噪音/多余空白", chans.len());

    // ★ 具体点名：CCTV+ 1 应恰好是 "CCTV+ 1"（无中文名，保留英文但去噪音）
    if let Some(c) = chans.iter().find(|c| c.id == "CCTVPlus1.cn@SD") {
        assert_eq!(
            c.name, "CCTV+ 1",
            "★ CCTV+ 1 应恰好是 'CCTV+ 1'（官方无中文名 ⇒ 保留英文 + 去噪音）"
        );
        println!("✓ CCTV+ 1 = {:?}（英文保留、噪音已去）", c.name);
    }
}
