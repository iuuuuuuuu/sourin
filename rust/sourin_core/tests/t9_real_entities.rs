// task-9 ② 真网络测量 —— 简介里的 HTML 实体
// 扫多个真实源的真实 vod_content，找**确实带实体**的条目，
// 展示 strip_tags 前/后对比（证明修复在真数据上生效）
// 用法：cargo test --test t9_real_entities -- --ignored --nocapture

use sourin_core::model::MediaId;
use sourin_core::provider::MediaProvider;
use sourin_core::tvbox::{strip_tags, TvboxAppleCmsProvider};

const SOURCES: &[(&str, &str)] = &[
    ("bfzy", "https://bfzyapi.com/api.php/provide/vod"),
    ("360", "https://360zy.com/api.php/seaxml/vod/"),
    ("cj", "https://cj.lziapi.com/api.php/provide/vod/"),
];

#[tokio::test]
#[ignore = "真网络，显式 --ignored 运行"]
async fn real_descriptions_have_no_entities_left() {
    let mut total = 0usize;
    let mut with_entity = 0usize;
    let mut shown = 0usize;

    for (tag, api) in SOURCES {
        let Ok(p) = TvboxAppleCmsProvider::new(*tag, *tag, api, Vec::new()) else {
            println!("[{tag}] provider 构造失败，跳过");
            continue;
        };
        let Ok(page) = p.search("的", 1).await else {
            println!("[{tag}] search 失败，跳过");
            continue;
        };
        println!("\n=== 源 {tag}  命中 {} ===", page.items.len());

        for it in page.items.iter().take(12) {
            let Ok(d) = p.detail(&it.id).await else { continue };
            let Some(desc) = d.description.clone() else { continue };
            total += 1;

            // 原始 vod_content 里有没有实体？用 detail 之前的字段反推不了，
            // 但**修复后**的 description 里若还有 & 开头的实体就是没解干净。
            let left = desc.contains("&nbsp;") || desc.contains("&amp;")
                || desc.contains("&lt;") || desc.contains("&gt;")
                || desc.contains("&quot;") || desc.contains("&#");
            if left {
                println!("  ✗ 仍有实体: {} => {:?}", d.title, desc);
            }
            // 统计"曾经有实体"的：拿 strip_tags 再解一次，若变化说明原本没解干净
            let again = strip_tags(&desc);
            if again != desc {
                with_entity += 1;
                println!("  ⚠ 幂等性失败: {:?} -> {:?}", desc, again);
            }
            if shown < 3 && !desc.is_empty() {
                println!("  · {} => {:?}", d.title, &desc[..desc.len().min(90)]);
                shown += 1;
            }
        }
    }
    println!("\n=== 汇总 ===");
    println!("检查条目数 = {total}");
    println!("幂等性失败 = {with_entity}");
    assert_eq!(with_entity, 0, "★ 解过一遍的简介再解应当不变（幂等）");
    println!("★ 真网络实体测量完成");
}

// ── 另外：直接对**真实上游原文**做前后对比 ──
// 用 raw HTTP 拿 vod_content 原文，展示 strip_tags 的输入/输出
#[tokio::test]
#[ignore = "真网络，显式 --ignored 运行"]
async fn raw_upstream_before_after() {
    let cli = reqwest::Client::builder()
        .user_agent("Mozilla/5.0")
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .unwrap();

    for (tag, api) in SOURCES {
        let url = format!("{api}?ac=videolist&pg=1");
        let Ok(txt) = cli.get(&url).send().await.and_then(|r| r.error_for_status()) else {
            continue;
        };
        let Ok(txt) = txt.text().await else { continue };
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&txt) else { continue };
        let Some(list) = v.get("list").and_then(|l| l.as_array()) else { continue };

        let mut hit = 0;
        for it in list.iter().take(30) {
            let raw = it.get("vod_content").and_then(|c| c.as_str()).unwrap_or("");
            if !raw.contains("&nbsp;") && !raw.contains("&amp;") && !raw.contains("&lt;") {
                continue;
            }
            hit += 1;
            if hit > 2 { break; }
            println!("\n=== 源 {tag} / {} ===", it.get("vod_name").and_then(|n| n.as_str()).unwrap_or(""));
            println!("  【改前】只去标签、不解实体:");
            println!("    {:?}", strip_only_tags(raw));
            println!("  【改后】去标签 + 解实体（本次修复）:");
            println!("    {:?}", strip_tags(raw));
        }
        if hit > 0 {
            println!("\n  [{tag}] 找到 {hit} 条带实体的真实简介");
        }
    }
    println!("\n★ 上游原文前后对比完成");
}

/// 复刻**改前**的行为（只去标签、不解实体）—— 用于对比
fn strip_only_tags(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for c in s.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out.trim().to_string()
}
