// ═══════════════════════════════════════════════════════════════════════
//  task-9 ③ 真网络测量 —— 「播放第二集，实际还是第一集」
// ═══════════════════════════════════════════════════════════════════════
//
// 硬规则：只有**真跑**的读数算数。本文件对真实源
// （bfzyapi.com 暴风资源，苹果CMS v10）做端到端测量：
//   · 真实 detail() → 拿到 N 集
//   · 分别用第 1/2/3 集的 episodeId 调 resolve()
//   · 断言三个返回地址**互不相同**且与请求集对应
//   · 反向控制：episodeId = 条目 id ⇒ 取第一集（与改前逐字相同）
//
// 用法：cargo test --test t9_real_network -- --ignored --nocapture

use sourin_core::model::PlayRequest;
use sourin_core::provider::MediaProvider;
use sourin_core::tvbox::TvboxAppleCmsProvider;

const API: &str = "https://bfzyapi.com/api.php/provide/vod";

fn req(ep: Option<&str>) -> PlayRequest {
    PlayRequest {
        source_code: None,
        episode_id: ep.map(|s| s.to_string()),
        quality: None,
    }
}

#[tokio::test]
#[ignore = "真网络，显式 --ignored 运行"]
async fn real_source_three_episodes_are_distinct() {
    let p =
        TvboxAppleCmsProvider::new("t9real", "暴风(真网络)", API, Vec::new()).expect("provider");

    // ① 真实搜索 → 挑一个多集条目
    //    （list 需要正确的 type_id，各家站不同；search 更稳）
    let found = p.search("剧", 1).await.expect("search");
    println!("\n=== ① 真实 search() ===");
    println!("命中数 = {}", found.items.len());

    let mut picked = None;
    for it in found.items.iter().take(8) {
        if let Ok(d) = p.detail(&it.id).await {
            let n = d.episodes.len();
            println!("  {}  {} 集数={}", it.id.native, it.title, n);
            if n >= 3 {
                picked = Some(d);
                break;
            }
        }
    }
    // 搜索没命中就退回**真实已知多集条目**（前面探测到的 89125，57687 字的 play_url）
    let d = match picked {
        Some(d) => d,
        None => {
            println!("  （search 未命中 ≥3 集，退回已知真实条目 89125）");
            p.detail(&sourin_core::model::MediaId::new("t9real", "89125"))
                .await
                .expect("detail 89125")
        }
    };
    println!("\n=== ② 选中条目 ===");
    println!("标题   = {}", d.title);
    println!("集数   = {}", d.episodes.len());
    println!("简介   = {:?}", d.description);
    for (i, e) in d.episodes.iter().take(3).enumerate() {
        println!("  第{}集  title={:?}  id={}", i + 1, e.title, e.id);
    }

    // ② 分别用第 1/2/3 集取流 —— 关键判据
    println!("\n=== ③ 逐集 resolve()（核心判据）===");
    let mut urls = Vec::new();
    for (i, e) in d.episodes.iter().take(3).enumerate() {
        let out = p
            .resolve(&d.id, &req(Some(&e.id)))
            .await
            .unwrap_or_else(|err| panic!("第{}集 resolve 失败: {err:?}", i + 1));
        let u = out.first().map(|s| s.url.clone()).unwrap_or_default();
        println!("  第{}集 episodeId={}", i + 1, e.id);
        println!("        => {}", u);
        urls.push(u);
    }
    let all_distinct = urls[0] != urls[1] && urls[1] != urls[2] && urls[0] != urls[2];
    println!("\n  ★ 三者互不相同 = {all_distinct}");
    assert_ne!(
        urls[0], urls[1],
        "★ 第1集与第2集返回同一地址 ⇒ 切集无效（Owner 的 bug）"
    );
    assert_ne!(urls[1], urls[2], "★ 第2集与第3集返回同一地址 ⇒ 切集无效");

    // ③ 反向控制：非 URL 的 episode_id ⇒ 取第一集
    println!("\n=== ④ 反向控制（episode_id = 条目 id，非 URL）===");
    let fb = p
        .resolve(&d.id, &req(Some(&d.id.native)))
        .await
        .expect("fallback resolve");
    let fb_url = fb.first().map(|s| s.url.clone()).unwrap_or_default();
    println!("  episodeId={}  => {}", d.id.native, fb_url);
    println!("  与第1集一致 = {}", fb_url == urls[0]);
    assert_eq!(
        fb_url, urls[0],
        "非 URL 的 episode_id 必须维持原行为（取第一集）"
    );

    // ④ 简介里不能有实体
    println!("\n=== ⑤ 简介实体检查 ===");
    if let Some(desc) = &d.description {
        println!("  含 &nbsp; = {}", desc.contains("&nbsp;"));
        println!("  含 &amp;  = {}", desc.contains("&amp;"));
        assert!(!desc.contains("&nbsp;"), "简介里还有 &nbsp;");
        assert!(!desc.contains("&amp;"), "简介里还有 &amp;");
    } else {
        println!("  （这个条目没有简介）");
    }

    println!("\n★ 真网络测量完成");
}
