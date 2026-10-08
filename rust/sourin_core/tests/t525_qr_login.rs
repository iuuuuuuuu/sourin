
// ═══════════════════════════════════════════════════════════════════════
//  t525 —— B站扫码登录（2026-10-05 补的命令层）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要有这个测试
//
// `provider_qr_login_start` / `provider_qr_login_poll` 这两条命令在 spike 里
// **曾经一直没注册**（`ffi.rs` 里 grep 0 命中），而插件层（`bilibili.js`）与
// 契约层（`provider.rs` 的 `QrLoginStart` / `QrLoginPoll`）早就写好了。
// 这个测试就是补上那一段并**用真请求**验收。
//
// ★ 2026-10-05 已补齐：命令层 `commands_backup.rs:154` / `:176`，注册在 `ffi.rs:1498` / `:1507`；
//   Dart 包装 `lib\core\sourin_api.dart:1110` / `:1128`；UI 扫码页签
//   `lib\ui\widgets\provider_login_panel.dart`。下面四条就是补齐后的验收记录。
//
// # 证据分级（重要，别把两者混起来）
//
// ```text
// ① start  → 真请求 passport.bilibili.com/x/passport-login/web/qrcode/generate
//            ⇒ 可离线验收（只要机器能上网）
// ② poll   → 真请求 …/qrcode/poll?qrcode_key=…
//            刚申请完必然是 pending(86101)
//            ⇒ 可离线验收
// ③ scanned / confirmed
//            ⇒ **必须真人拿手机扫**，本测试**不覆盖**，不要在结论里
//              把它写成"已验收"
// ```
//
// # ⚠️ 用隔离目录 + 只复制 bilibili.js
//
// 与 batch5 同一个理由：测试会写文件，所以用独立数据目录。
// 但这里**只**复制 `bilibili.js`（不复制 26 个），因为：
//   ① 少复制 = 少一次 reload 的干扰
//   ② 断言"只有 bilibili 支持扫码"时不会被别的插件干扰
//
// # ⚠️ 复制完必须 `reload_plugins()`
//
// 见 batch5_provider.rs:38-50 的注释 —— bootstrap 早就扫过目录了，
// 之后复制进去的文件它不知道。

use sourin_core::commands_backup as cb;
use sourin_core::provider::QrLoginStatus;
use sourin_core::state::AppState;
use std::sync::Arc;

/// 隔离目录
async fn fresh(tag: &str) -> Arc<AppState> {
    let dir = std::env::temp_dir().join(format!(
        "sourin-t525-{tag}-{}",
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
    ));
    std::fs::create_dir_all(&dir).unwrap();
    AppState::bootstrap(dir).await.expect("bootstrap")
}

/// 隔离目录 + 真实 `bilibili.js`（从 %APPDATA% 只读复制）
async fn with_bilibili(tag: &str) -> Arc<AppState> {
    let st = fresh(tag).await;
    let appdata = std::env::var("APPDATA").expect("APPDATA");
    let src = std::path::PathBuf::from(&appdata)
        .join("app.sourin.player")
        .join("plugins")
        .join("bilibili.js");
    assert!(
        src.exists(),
        "找不到真实插件：{}（本测试需要已部署的 bilibili.js）",
        src.display()
    );
    let dst = st.data_dir.join("plugins");
    std::fs::create_dir_all(&dst).unwrap();
    std::fs::copy(&src, dst.join("bilibili.js")).expect("copy bilibili.js");
    let n = sourin_core::commands_provider::reload_plugins(&st)
        .await
        .expect("reload_plugins");
    println!(
        "[t525] 复制插件 {} B，reload 后共 {} 个源",
        std::fs::metadata(&src).unwrap().len(),
        n
    );
    st
}

/// 网络测试的开关：离线机器上 `SOURIN_SKIP_NET=1` 可跳过
fn net_ok() -> bool {
    std::env::var("SOURIN_SKIP_NET").as_deref() != Ok("1")
}

// ═══════════════════════════════════════════════════════════════════════
//  ① 申请二维码 —— 真请求
// ═══════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn qr_login_start_real_request() {
    if !net_ok() {
        println!("[t525] SOURIN_SKIP_NET=1，跳过");
        return;
    }
    let st = with_bilibili("start").await;

    let r = cb::provider_qr_login_start(&st, "bilibili")
        .await
        .expect("申请二维码失败");

    println!("[t525] key={}", r.key);
    println!("[t525] url={}", r.url);
    println!("[t525] hint={:?}", r.hint);
    println!("[t525] svg len={}", r.svg.len());

    // ① key 是轮询凭据（B站叫 qrcode_key，32 位十六进制）
    assert!(!r.key.is_empty(), "key 不能为空");
    assert_eq!(r.key.len(), 32, "B站 qrcode_key 是 32 位，实际 {}", r.key.len());

    // ② url 是二维码里要编码的地址
    //
    // ⚠️ 实测（2026-10-05）它**不是** passport.bilibili.com，而是
    //    https://account.bilibili.com/h5/account-h5/auth/scan-web?navhide=1
    //        &callback=close&qrcode_key=<key>&from=
    //    所以只断言「是 https + 带着同一个 key」，不写死域名
    //    （站点换域名不该让测试变红）。
    assert!(r.url.starts_with("https://"), "url 不是 https：{}", r.url);
    assert!(
        r.url.contains("qrcode_key="),
        "url 里没有 qrcode_key：{}",
        r.url
    );
    assert!(
        r.url.contains(&r.key),
        "url 里的 qrcode_key 与返回的 key 不一致：url={} key={}",
        r.url,
        r.key
    );

    // ③ ★ svg 由**宿主**画（插件只给 url）—— 这是 spike 与原版一致的关键点
    assert!(!r.svg.is_empty(), "宿主没画出二维码 svg");
    assert!(r.svg.contains("<path"), "svg 里没有模块 path，渲染失败");

    // ④ hint 是插件给的提示语
    let hint = r.hint.unwrap_or_default();
    assert!(!hint.is_empty(), "插件没给 hint");
    println!("[t525] ★ start 通过：key/url/svg/hint 全部有值");
}

// ═══════════════════════════════════════════════════════════════════════
//  ② 轮询 —— 刚申请完必然是 pending
// ═══════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn qr_login_poll_is_pending_right_after_start() {
    if !net_ok() {
        println!("[t525] SOURIN_SKIP_NET=1，跳过");
        return;
    }
    let st = with_bilibili("poll").await;

    let start = cb::provider_qr_login_start(&st, "bilibili")
        .await
        .expect("申请二维码失败");

    let p = cb::provider_qr_login_poll(&st, "bilibili", &start.key)
        .await
        .expect("轮询失败");

    println!("[t525] poll status={:?} message={}", p.status, p.message);
    assert_eq!(
        p.status,
        QrLoginStatus::Pending,
        "刚申请完的二维码应该是 pending，实际 {:?}（message={}）",
        p.status,
        p.message
    );
    assert!(p.session.is_none(), "pending 时不该有 session");
    println!("[t525] ★ poll 通过：拿到 pending + 站点原文 message");
}

// ═══════════════════════════════════════════════════════════════════════
//  ③ 负例 —— 不存在的源 / 不支持扫码的源
// ═══════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn qr_login_unknown_provider_errors() {
    let st = with_bilibili("unknown").await;

    let e = cb::provider_qr_login_start(&st, "__no_such_provider__")
        .await
        .expect_err("不存在的源应该报错");
    println!("[t525] unknown start err={e}");
    assert!(e.contains("找不到 Provider"), "文案不对：{e}");

    let e2 = cb::provider_qr_login_poll(&st, "__no_such_provider__", "k")
        .await
        .expect_err("不存在的源应该报错");
    println!("[t525] unknown poll err={e2}");
    assert!(e2.contains("找不到 Provider"), "文案不对：{e2}");
}

#[tokio::test]
async fn qr_login_unsupported_provider_errors() {
    let st = with_bilibili("unsupported").await;

    // 找一个**不是** bilibili 的源（内置源都没有扫码能力）
    let ids: Vec<String> = st.registry.manifests().iter().map(|m| m.id.clone()).collect();
    println!("[t525] 已加载源：{ids:?}");
    let other = ids
        .iter()
        .find(|id| id.as_str() != "bilibili")
        .cloned()
        .expect("至少要有两个源才能做这个负例");

    let e = cb::provider_qr_login_start(&st, &other)
        .await
        .expect_err("不支持扫码的源应该报错");
    println!("[t525] unsupported({other}) err={e}");
    // ⚠️ 如实透传 unsupported 原文，不要翻译成别的文案
    assert!(
        e.contains("不支持扫码登录") || e.contains("不支持"),
        "文案不对：{e}"
    );
}
