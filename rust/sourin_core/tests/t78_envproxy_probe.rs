// ═══════════════════════════════════════════════════════════════════════
//  临时探针：环境变量代理是否污染插件 HTTP 出口（task-3 ⑤ 回归 bug）
// ═══════════════════════════════════════════════════════════════════════
//
// 目的：**能翻红**地判定「插件取不到 m3u8」是不是因为进程读了
// HTTPS_PROXY 而把播放页域名也送进了代理。
//
// A/B 两跑：
//   cargo test --test t78_envproxy_probe -- --nocapture            （继承 HTTPS_PROXY）
//   $env:HTTPS_PROXY=''; cargo test ... -- --nocapture             （清掉）
// 两次结果不同 ⇒ 环境变量代理就是原因。

use sourin_core::commands_provider as cp;
use sourin_core::model::{MediaId, PlayRequest};
use sourin_core::state::AppState;
use std::sync::Arc;

async fn with_real_plugins(tag: &str) -> Arc<AppState> {
    let dir = std::env::temp_dir().join(format!(
        "sourin-t78-{tag}-{}",
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
    println!("[probe] 复制插件 {copied} 个；已注册源 {}", st.registry.manifests().len());
    st
}

#[tokio::test]
#[ignore = "真网络探针，显式 --ignored 运行"]
async fn env_proxy_breaks_plugin_resolve() {
    for k in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY"] {
        println!("[probe] env {k} = {:?}", std::env::var(k).ok());
    }
    let st = with_real_plugins("envproxy").await;

    // 用户库里存过的真实分享页（直连 curl 实测 200 且含 index.m3u8）
    let cases = [
        ("cj", "https://svip.feifei-play.com/share/786bb5e43995b615a831bdb225bc15fb"),
        ("cj", "https://super.ffzy-online6.com/share/110375fbd8973253ed4a4b7a43837ba8"),
        ("cj-2", "https://v.cdnlz11.com/share/c6663e689b7d1495526d8c7403ccc67f"),
        ("hongniuzy2", "https://hn.bfvvs.com/play/dwp0Pqre"),
    ];

    let mut ok = 0;
    let mut bad = 0;
    for (prov, url) in cases {
        let mid = MediaId::new(prov, url);
        let req = PlayRequest::default();
        let p = st.registry.route(&mid).expect("route");
        match p.resolve(&mid, &req).await {
            Ok(list) => {
                let u = list.first().map(|c| c.url.clone()).unwrap_or_default();
                println!("[probe] ✓ {prov} {} -> {}", &url[..48.min(url.len())], &u[..80.min(u.len())]);
                ok += 1;
            }
            Err(e) => {
                println!("[probe] ✗ {prov} {} -> {}: {}", &url[..48.min(url.len())], e.kind as u8 as char as u8 as u8, e.message);
                println!("[probe]    kind={:?} message={}", e.kind, e.message);
                bad += 1;
            }
        }
    }
    println!("[probe] 结果：成功 {ok} 失败 {bad}");
    assert!(ok > 0, "★ 一条都没解出来 —— 环境变量代理假设成立（{ok} 成功 / {bad} 失败）");
}
