// ═══════════════════════════════════════════════════════════════════════
//  task-38 诊断③：session() **读取失败** 时，有凭据也报 expired（真 bug）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独测这个
//
// `registry.rs:643` 的 `Err(_) => Some(SessionState::Expired)` **不看凭据**。
// 而上面几条分支都看了：
// ```text
// L613  有过期会话 + can_auto_login → Expiring   （能自愈，不吓用户）
// L626  无会话     + can_auto_login → Expiring   （能自愈）
// L643  session() Err(_)            → Expired    ★★ 唯一没看凭据的分支
// ```
//
// 用户看到「可能需要验证码」= `Expired`。所以只要 `session()` **报错**
//（而不是干净地返回 None），有凭据的次元城也会被说成"需人工登录"。
//
// # 怎么让 `session()` 报错（真实可达的路径）
//
// `cycani.js` 的 `session()` 里有 `JSON.parse(raw)` ——
// **store 里的 session 值被写坏时它抛异常**，`call_js` 把它变成 `Err`。
// 什么时候会写坏？历史版本 / 别的工具动过 / 写盘中途断电。
// 本机 users 目录里已有一堆 `backup-*` / `.rescue-*`，说明这种脏数据**现实存在**。

use sourin_core::plugins::JsPluginProvider;
use sourin_core::provider::MediaProvider;
use sourin_core::provider::SessionState;
use sourin_core::registry::Registry;
use std::sync::Arc;

mod support;
use support::real_creds_required_echo;

const REAL_STORE: &str = r"C:\Users\iuuuuuuuu\AppData\Roaming\app.sourin.player\plugins\.data";

fn probe_dir(tag: &str) -> std::path::PathBuf {
    let d = std::path::PathBuf::from(format!(
        r"D:\WishProject\sourin-flutter-spike\.probe\t38-{tag}"
    ));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

async fn cycani_at(dir: std::path::PathBuf) -> JsPluginProvider {
    let src =
        std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/plugins/cycani.js"))
            .unwrap();
    let mut p = JsPluginProvider::from_source(&src).unwrap().with_data_dir(dir);
    p.hydrate_capabilities().await;
    p
}

#[ignore = "走真实网络 + 真实第三方账号重登链路：站点随时可能改接口/弹验证码，结果不稳定（且需要开发机上的真实凭据）。手动跑：cargo test -- --ignored --nocapture"]
#[tokio::test]
async fn t38_corrupt_session_with_credentials_reports_expired() {
    // ★ 需要开发机上的真实凭据；本机没有就跳过（见 tests/support/mod.rs）
    if let Some(_why) = real_creds_required_echo("t38_corrupt_session_with_credentials_reports_expired") {
        return;
    }
    let dir = probe_dir("corrupt");
    let src = std::path::PathBuf::from(REAL_STORE).join("cycani.json");
    std::fs::copy(&src, dir.join("cycani.json")).unwrap();

    // ── 把 `session` 写坏（保留 credentials 完好）──
    let path = dir.join("cycani.json");
    let raw = std::fs::read_to_string(&path).unwrap();
    let mut v: serde_json::Value = serde_json::from_str(&raw).unwrap();
    v["session"] = serde_json::Value::String("{ 这不是合法 JSON".to_string());
    std::fs::write(&path, serde_json::to_string_pretty(&v).unwrap()).unwrap();

    let p = cycani_at(dir.clone()).await;

    println!("\n=========== ★ session 值损坏 + 凭据完好 ===========");
    println!("can_auto_login() = {}", p.can_auto_login().await);

    let s = p.session().await;
    match &s {
        Ok(Some(_)) => println!("session()        = Ok(Some)"),
        Ok(None) => println!("session()        = Ok(None)  ← 干净地'没有会话'"),
        Err(e) => println!("session()        = Err({})  ★★ 报错了", e.message),
    }
    println!("session_expired()= {}", p.session_expired().await);

    let reg = Registry::new();
    reg.register(Arc::new(p));
    let st = reg.session_state("cycani").await;
    println!("session_state()  = {st:?}");

    let ok = reg.ensure_session("cycani").await;
    println!("ensure_session() = {ok:?}   ★ 凭据还在，能不能救活？");

    /*
     * ★★★ 核心断言：凭据完好 → 无论 session 读成什么样，
     *      都不该告诉用户"需要人工登录"。
     *
     * 这里**故意写成"期望 Expiring"**（即当前实现会红）。
     * 红了才证明 `Err(_) => Expired` 是真 bug；
     * 如果它绿，说明这条路径走不到，我再换一个真实触发点。
     */
    println!("\n★ 判定 vs 期望：");
    println!("   实际 session_state = {st:?}");
    println!("   期望（凭据在，不该吓用户）= Some(Expiring)");
    assert_eq!(
        ok,
        Some(true),
        "★ 凭据完好 → 自动重登必须成功（session 读坏不影响 autoLogin 用凭据）"
    );
    assert_eq!(
        st,
        Some(SessionState::Expiring),
        "★★★ 有凭据时**不该**报 Expired —— Expired 会让 UI 说\
         「需重新登录（可能需要验证码）」，而实际下一行就能自动救活。\
         实际 = {st:?}"
    );
}
