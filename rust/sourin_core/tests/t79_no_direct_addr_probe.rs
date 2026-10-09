// ═══════════════════════════════════════════════════════════════════════
//  临时探针：⑤ 回归 bug「同一个源下有些能看、有些报没有可播地址」
// ═══════════════════════════════════════════════════════════════════════
//
// 走**真实插件路径**（registry → JsPluginProvider），对每个源：
//   categories() → 取第一个分类 → list(page=1) 拿 10 条
//   → 每条 detail() 拿第一集地址 → 用该地址 resolve()
// 统计「成功 / 报没有可直接播放的地址 / 其它」，并打印失败条目的 host。
//
// ★ 这是能翻红的判据：若某个源 10/10 全成功，就说明它没病；
//   若某个源一半成功一半报错，且失败条目的 host 与成功条目不同，
//   就证明是**分享页本身已失效**，不是代码回归。

use sourin_core::commands_provider as cp;
use sourin_core::model::{MediaId, PlayRequest};
use sourin_core::provider::ListRequest;
use sourin_core::state::AppState;
use std::collections::HashMap;
use std::sync::Arc;

async fn with_real_plugins(tag: &str) -> Arc<AppState> {
    let dir = std::env::temp_dir().join(format!(
        "sourin-t79-{tag}-{}",
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let st = AppState::bootstrap(dir).await.expect("bootstrap");
    let appdata = std::env::var("APPDATA").unwrap();
    let src = std::path::PathBuf::from(&appdata)
        .join("app.sourin.player")
        .join("plugins");
    let dst = st.data_dir.join("plugins");
    std::fs::create_dir_all(&dst).unwrap();
    let mut copied = 0;
    for e in std::fs::read_dir(&src).unwrap().flatten() {
        if e.path().extension().and_then(|s| s.to_str()) == Some("js") {
            if std::fs::copy(e.path(), dst.join(e.file_name())).is_ok() {
                copied += 1;
            }
        }
    }
    if copied > 0 {
        let _ = cp::reload_plugins(&st).await;
    }
    st
}

fn host_of(u: &str) -> String {
    let s = u
        .strip_prefix("https://")
        .or_else(|| u.strip_prefix("http://"))
        .unwrap_or(u);
    s.split(['/', '?']).next().unwrap_or("").to_string()
}

#[tokio::test]
#[ignore = "真网络探针，显式 --ignored 运行"]
async fn some_items_fail_with_no_direct_address() {
    let st = with_real_plugins("noaddr").await;
    let provs = [
        "cj", "cj-2", "ffzy", "caiji", "caiji-2", "hongniuzy2", "jszyapi", "sdzyapi", "api", "api-2",
        "api-4", "tyyszy", "suoniapi", "bfzyapi", "360",
    ];

    let mut tot_ok = 0usize;
    let mut tot_noaddr = 0usize;
    let mut tot_other = 0usize;
    let mut host_stat: HashMap<String, (usize, usize)> = HashMap::new(); // host -> (ok, fail)

    for prov in provs {
        let pid = MediaId::new(prov, "1");
        let Some(p) = st.registry.route(&pid) else {
            println!("[probe] -- {prov}: 未注册");
            continue;
        };
        let cats = p.categories().await.unwrap_or_default();
        let cat = match cats.iter().find(|c| !c.id.is_empty()) {
            Some(c) => c,
            None => {
                println!("[probe] -- {prov}: 无可用分类（{} 个）", cats.len());
                continue;
            }
        };
        let page = match p
            .list(ListRequest {
                category_id: cat.id.clone(),
                page: 1,
                filters: Default::default(),
            })
            .await
        {
            Ok(pg) => pg,
            Err(e) => {
                println!("[probe] -- {prov}: list 失败 {}", e.message);
                continue;
            }
        };
        let items: Vec<_> = page.items.into_iter().take(10).collect();
        let mut ok = 0;
        let mut noaddr = 0;
        let mut other = 0;
        let mut noaddr_hosts: Vec<String> = Vec::new();
        let mut ok_hosts: Vec<String> = Vec::new();
        for it in &items {
            let ep_url = match p.detail(&it.id).await {
                Ok(d) => d.episodes.first().map(|e| e.id.clone()).unwrap_or_default(),
                Err(_) => String::new(),
            };
            let h = host_of(&ep_url);
            let mid = MediaId::new(prov, ep_url.clone());
            match p.resolve(&mid, &PlayRequest::default()).await {
                Ok(list) => {
                    ok += 1;
                    ok_hosts.push(h.clone());
                    let e = host_stat.entry(h).or_insert((0, 0));
                    e.0 += 1;
                    let u = list.first().map(|c| c.url.clone()).unwrap_or_default();
                    if ok <= 2 {
                        println!(
                            "[probe]    ✓ {} | {} -> {}",
                            it.title,
                            &ep_url[..60.min(ep_url.len())],
                            &u[..70.min(u.len())]
                        );
                    }
                }
                Err(e) => {
                    if e.message.contains("没有可直接播放的地址") {
                        noaddr += 1;
                        noaddr_hosts.push(h.clone());
                        let s = host_stat.entry(h).or_insert((0, 0));
                        s.1 += 1;
                    } else {
                        other += 1;
                        if other <= 2 {
                            println!("[probe]    ? {} | {} -> {}", it.title, &ep_url[..50.min(ep_url.len())], e.message);
                        }
                    }
                }
            }
        }
        println!(
            "[probe] {prov:<11} 共 {} 条 | 成功 {ok} | 无可播地址 {noaddr} | 其它 {other}",
            items.len()
        );
        if !noaddr_hosts.is_empty() {
            println!("[probe]    失败 host: {:?}", noaddr_hosts);
        }
        if !ok_hosts.is_empty() {
            println!("[probe]    成功 host: {:?}", ok_hosts);
        }
        tot_ok += ok;
        tot_noaddr += noaddr;
        tot_other += other;
    }
    println!("[probe] ==== 合计 成功 {tot_ok} / 无可播地址 {tot_noaddr} / 其它 {tot_other}");
    println!("[probe] ==== host 维度（成功/失败）");
    let mut v: Vec<_> = host_stat.into_iter().collect();
    v.sort_by(|a, b| (b.1 .1).cmp(&a.1 .1));
    for (h, (ok, bad)) in v {
        println!("[probe]    {h:<34} ok={ok} fail={bad}");
    }
}
