// ═══════════════════════════════════════════════════════════════════════
//  task-13 决定性 A/B：影视建安（154）「有的时候能播有的时候不能」
// ═══════════════════════════════════════════════════════════════════════
//
// # 现象（Owner 第三批第 4 条）
//   > 影视建安这个是邮的时候能播放有的时候不能播放
//
// # 已定位的嫌疑（.probe/t13_* 里逐条量过）
//
//   ┌──────────────────────────────────────────────────────────────┐
//   │ ① 上游 API 30 次连打：100% HTTP 502、len=0   ⇒ 看起来"源挂了" │
//   │ ② 但**裸 TCP** 手写同一请求：8/8 HTTP 200、body 288 KB 真数据 │
//   │ ③ A/B 同进程交替（排环境漂移）：                              │
//   │      http.request（会读 HTTP_PROXY） => 8/8 HTTP 502          │
//   │      raw tcp    （绕过代理）         => 8/8 HTTP 200          │
//   │ ④ 那个 502 响应带 proxy-connection: keep-alive                │
//   │      ⇒ 是**本地代理**回的，不是源站回的                        │
//   └──────────────────────────────────────────────────────────────┘
//
// ⇒ 判据：进程若继承了 HTTP_PROXY，插件 HTTP 出口被送进代理，
//   而该代理对 154.219.117.232:9981（裸 IP + 非标端口）返回 502。
//
// # 为什么叫「有的时候」
//   代理是否可达 / 是否放行该目标随环境与时间变化 ⇒ 同一作品在
//   **代理可用时失败、代理不可用时成功** ⇒ 用户感知成"有时能有时不能"。
//
// # 本文件怎么验（真跑，不是推理）
//   A 组：继承代理环境变量 → 跑真实 154 插件（分组跑）
//   B 组：清掉代理环境变量 → 跑同一个 154 插件（分组跑）
//   C 组：同一作品连跑 N 次，统计占比（"有的时候"的量化）
//
// 两组必须**分进程**跑（环境变量是进程级的），命令见 .probe/t13_run.ps1。

use sourin_core::commands_provider as cp;
use sourin_core::model::{MediaId, PlayRequest};
use sourin_core::provider::{ListRequest, MediaProvider};
use sourin_core::state::AppState;
use std::sync::Arc;
use std::time::Duration;

async fn with_real_plugins(tag: &str) -> Arc<AppState> {
    let dir = std::env::temp_dir().join(format!(
        "sourin-t13b-{tag}-{}",
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

fn proxy_env() -> Vec<(String, String)> {
    let mut v = Vec::new();
    for k in [
        "HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy",
        "NO_PROXY", "no_proxy",
    ] {
        let s = std::env::var(k).unwrap_or_else(|_| "(未设置)".into());
        v.push((k.to_string(), s));
    }
    v
}

fn short(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

#[tokio::test]
#[ignore = "真网络探针，显式 --ignored 运行"]
async fn a_154_through_real_plugin() {
    println!("\n════════ 代理环境变量（本进程实际继承到的）════════");
    for (k, v) in proxy_env() {
        println!("  {k:<12} = {v}");
    }

    let st = with_real_plugins("154").await;
    let pid = MediaId::new("154", "1");
    let Some(p) = st.registry.route(&pid) else {
        panic!("154 未注册（插件目录里有 154.js 吗）");
    };

    println!("\n════ ① categories() ════");
    let cats = match p.categories().await {
        Ok(c) => c,
        Err(e) => {
            println!("  ✗ categories 失败: {}", short(&e.message, 200));
            println!("\n  ★ 结论：上游连**分类**都拿不到 ⇒ 这一层就断了");
            return;
        }
    };
    println!("  成功，分类数 = {}", cats.len());
    for c in cats.iter().take(5) {
        println!("    {} {}", c.id, c.name);
    }

    println!("\n════ ② list() ════");
    let cat = cats.iter().find(|c| !c.id.is_empty()).expect("无分类");
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
            println!("  ✗ list 失败: {}", short(&e.message, 250));
            println!("\n  ★ 结论：列表拿不到 ⇒ 上游 API 这一层就断了");
            return;
        }
    };
    println!("  成功，条目数 = {}", page.items.len());
    for it in page.items.iter().take(3) {
        println!("    {} {}", it.id.native, it.title);
    }

    println!("\n════ ③ detail() + resolve() ════");
    let item = page.items.first().expect("列表为空");
    let d = match p.detail(&item.id).await {
        Ok(d) => d,
        Err(e) => {
            println!("  ✗ detail 失败: {}", short(&e.message, 250));
            return;
        }
    };
    println!("  detail 成功，集数 = {}", d.episodes.len());
    let Some(ep) = d.episodes.first() else {
        println!("  ✗ 0 集");
        return;
    };
    println!("  第一集地址 = {}", short(&ep.id, 110));
    let mid = MediaId::new("154", ep.id.clone());
    match p.resolve(&mid, &PlayRequest::default()).await {
        Ok(list) => {
            println!("  ✓ resolve 成功，候选 {} 个", list.len());
            if let Some(s) = list.first() {
                println!("     {}", short(&s.url, 110));
            }
        }
        Err(e) => {
            println!("  ✗ resolve 失败: {}", short(&e.message, 250));
            println!("\n  ★ 结论：上游列表通了，但**取流**这一层断了（分享页/解析服务）");
        }
    }
}

#[tokio::test]
#[ignore = "真网络探针，显式 --ignored 运行"]
async fn b_154_same_item_n_times() {
    println!("\n════════ 时间维度：同一作品连跑 12 次 ════════");
    let st = with_real_plugins("154n").await;
    let pid = MediaId::new("154", "1");
    let Some(p) = st.registry.route(&pid) else {
        panic!("154 未注册");
    };

    let n = 12;
    let mut ok = 0usize;
    let mut fail = 0usize;
    let mut first_err: Option<String> = None;

    for i in 1..=n {
        match p.categories().await {
            Ok(c) => {
                ok += 1;
                println!("  第{i:>2} 次: ✓ 分类 {} 个", c.len());
            }
            Err(e) => {
                fail += 1;
                let m = short(&e.message, 90);
                if first_err.is_none() {
                    first_err = Some(e.message.clone());
                }
                println!("  第{i:>2} 次: ✗ {m}");
            }
        }
        if i < n {
            tokio::time::sleep(Duration::from_millis(1200)).await;
        }
    }
    println!("\n  ── 汇总 ──");
    println!("    成功 {ok} / 失败 {fail}  (共 {n} 次)");
    if let Some(e) = first_err {
        println!("    首次错误: {}", short(&e, 220));
    }
    println!("\n  ★ 同一作品 {n} 次里 {fail} 次失败");
}
