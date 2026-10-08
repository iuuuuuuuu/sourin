// ═══════════════════════════════════════════════════════════════════════
//  task-38 诊断：次元城「自动重登」链路到底走到哪一步、为什么失败
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话：
// > 次元城登录失效 明明不需要验证码就可以自动登录，还提示 验证码
//
// # 这个探针要回答的问题（按证据链排序）
//
// ```text
// ① 凭据还在吗？can_auto_login() 返回什么？
// ② session() 返回什么？过期了吗？
// ③ session_state() 判定成哪个状态？（决定 UI 显示什么）
// ④ refresh_session() 成功吗？
// ⑤ 真到 auto_login() 那一步了吗？成功还是失败？**真实错误是什么**？
// ⑥ ensure_session() 能不能把源救活？
// ```
//
// # ★ 数据隔离
//
// **只读**用户真实 store 的内容，**复制**到 `.probe/t38/<id>.json`，
// 用 `with_data_dir(.probe/t38)` 让插件读写那个副本 ——
// 用户的 `%APPDATA%\app.sourin.player` **零写入**。
//
// ⚠️ 本探针会**真的联网**（cycani.org），因为"自动重登是否成功"
//    只能靠真实站点回答；mock 掉就失去意义了。

use sourin_core::plugins::JsPluginProvider;
// ★ 必须引入 trait —— 这些方法都是 `MediaProvider` 的默认/实现方法，
//   没有它 `p.session()` / `p.can_auto_login()` 全都报 "method not found"
use sourin_core::provider::MediaProvider;

/// 用户真实插件存储（只读取源）
const REAL_STORE: &str = r"C:\Users\iuuuuuuuu\AppData\Roaming\app.sourin.player\plugins\.data";

fn probe_dir() -> std::path::PathBuf {
    let d = std::path::PathBuf::from(
        r"D:\WishProject\sourin-flutter-spike\.probe\t38",
    );
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// 把用户真实 store 复制一份到探针目录（**只读源，不写源**）
fn seed_probe_store(id: &str) -> std::path::PathBuf {
    let dir = probe_dir();
    let src = std::path::PathBuf::from(REAL_STORE).join(format!("{id}.json"));
    let dst = dir.join(format!("{id}.json"));
    if src.exists() {
        std::fs::copy(&src, &dst).expect("copy store");
        println!("[seed] 已复制 {src:?} -> {dst:?}");
    } else {
        println!("[seed] ★ 用户 store 不存在: {src:?}（凭据不在）");
    }
    dir
}

fn load_cycani(dir: std::path::PathBuf) -> JsPluginProvider {
    let src = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/plugins/cycani.js"
    ))
    .expect("读 cycani.js");
    JsPluginProvider::from_source(&src)
        .expect("解析 cycani.js")
        .with_data_dir(dir)
}

#[tokio::test]
async fn t38_diagnose_auto_login_chain() {
    let dir = seed_probe_store("cycani");
    let p = load_cycani(dir.clone());

    println!("\n================ ① 会话 / 凭据 ================");
    let sess = p.session().await;
    match &sess {
        Ok(Some(s)) => {
            println!("session()      → Some");
            println!("  token         = {}…", &s.token.chars().take(24).collect::<String>());
            println!("  expires_at    = {:?}", s.expires_at);
            println!("  display_name  = {:?}", s.display_name);
            println!("  is_expired_at(now) = {}", s.is_expired_at(chrono::Utc::now().timestamp()));
            println!("  effective_expires_at = {:?}", s.effective_expires_at());
        }
        Ok(None) => println!("session()      → None ★ 没有会话！"),
        Err(e) => println!("session()      → Err({}) ★", e.message),
    }

    let can = p.can_auto_login().await;
    println!("\ncan_auto_login() → {can}   ★★ 这一位决定 UI 说'已登录'还是'要验证码'");
    assert!(
        can,
        "★★★ 用户的 store 里**确实有** credentials —— \
         can_auto_login() 必须为 true。若为 false，说明桥接/读取有 bug"
    );

    let expired = p.session_expired().await;
    let needs = p.session_needs_refresh().await;
    println!("session_expired()      → {expired}");
    println!("session_needs_refresh()→ {needs}");

    println!("\n================ ② refresh_session ================");
    match p.refresh_session().await {
        Ok(Some(s)) => println!(
            "refresh_session() → Ok(Some) token={}…",
            &s.token.chars().take(20).collect::<String>()
        ),
        Ok(None) => println!("refresh_session() → Ok(None)（不支持/没会话）"),
        Err(e) => println!("refresh_session() → Err({})", e.message),
    }

    println!("\n================ ③ auto_login（核心）================");
    match p.auto_login().await {
        Ok(Some(s)) => {
            println!("★★ auto_login() → Ok(Some) 成功！");
            println!("   token        = {}…", &s.token.chars().take(24).collect::<String>());
            println!("   display_name = {:?}", s.display_name);
        }
        Ok(None) => println!("★★ auto_login() → Ok(None) ★ 没凭据，返回了 null"),
        Err(e) => {
            println!("★★ auto_login() → Err ★★★");
            println!("   kind    = {:?}", e.kind);
            println!("   message = {}", e.message);
        }
    }

    println!("\n================ ④ 会话是否被救活 ================");
    match p.session().await {
        Ok(Some(s)) => println!(
            "救活后 session() → token={}… expires={:?}",
            &s.token.chars().take(24).collect::<String>(),
            s.expires_at
        ),
        Ok(None) => println!("★ 救活后 session() 仍是 None"),
        Err(e) => println!("★ 救活后 session() Err({})", e.message),
    }

    println!("\n================ ⑤ 磁盘上写回了什么 ================");
    let after = std::fs::read_to_string(dir.join("cycani.json")).unwrap_or_default();
    let v: serde_json::Value = serde_json::from_str(&after).unwrap_or(serde_json::Value::Null);
    let keys: Vec<String> = v
        .as_object()
        .map(|o| o.keys().cloned().collect())
        .unwrap_or_default();
    println!("探针 store 顶层键 = {keys:?}");
    if let Some(t) = v.get("session").and_then(|x| x.as_str()) {
        println!("session 长度 = {} 字节", t.len());
    }
}

#[tokio::test]
async fn t38_session_state_verdict() {
    /*
     * ★ 这一个直接回答"用户看到的到底是哪个状态"。
     *
     * UI 文案的判据链（见 provider_login_panel.dart）：
     * ```text
     * expired + can_auto_login() == true  → Rust 报 Expiring → UI 说「已登录」
     * expired + can_auto_login() == false → Rust 报 Expired  → UI 说「登录已失效
     *                                                          （可能需要验证码）」
     * ```
     * 所以"看到验证码" ⟺ `can_auto_login() == false`。
     */
    let dir = seed_probe_store("cycani");
    let p = load_cycani(dir);

    let has_session = matches!(p.session().await, Ok(Some(_)));
    let can = p.can_auto_login().await;
    let expired = p.session_expired().await;

    // 复刻 registry.rs::session_state 的判定（L587-644）
    let verdict = if !p.manifest().capabilities.login_required
        && !p.manifest().capabilities.login_supported
    {
        "not_required"
    } else if has_session {
        if expired {
            if can {
                "expiring" // → UI「已登录」
            } else {
                "expired" // → UI「登录已失效（可能需要验证码）」★★ 用户看到的
            }
        } else if p.session_needs_refresh().await {
            "expiring"
        } else {
            "active"
        }
    } else if can {
        "expiring"
    } else if p.manifest().capabilities.login_required {
        "expired"
    } else {
        "not_required"
    };

    println!("\n================ 状态判定 ================");
    println!("has_session   = {has_session}");
    println!("session_expired = {expired}");
    println!("can_auto_login  = {can}");
    println!("★ session_state 判定 = {verdict}");
    if verdict == "expired" {
        println!("★ ⇒ UI 会显示「登录已失效」+「需重新登录（可能需要验证码，请手动完成）」");
    } else if verdict == "expiring" {
        println!("★ ⇒ UI 会显示「已登录」+「登录状态需要刷新，播放时会自动恢复…」");
    }

    assert!(
        can,
        "★★★ 用户 store 里有凭据 → can_auto_login() 必须 true → 判定不该是 expired"
    );
}
