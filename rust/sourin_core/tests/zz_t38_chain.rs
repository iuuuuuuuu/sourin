// ═══════════════════════════════════════════════════════════════════════
//  task-38 诊断②：用**真 Registry** 走完整链路（含"token 已过期"场景）
// ═══════════════════════════════════════════════════════════════════════
//
// 诊断① 已确认：用户当前 store 里 token **还有效**（7 天），
// `can_auto_login()=true`、`auto_login()` 也**真的成功**。
// 所以"现在这一刻"用户不该看到"验证码"文案。
//
// ★ 这个诊断回答的是**用户实际遇到的那个场景**：
// ```text
// token **真的过期了** → ensure_session() 能救活吗？
//                      → session_state() 报什么？
//                      → UI 会显示"验证码"吗？
// ```
//
// 做法：把探针 store 里的 token 换成一个**已过期的**（伪造 exp），
// 然后走真 `Registry::ensure_session()` / `session_state()`。

use sourin_core::plugins::JsPluginProvider;
use sourin_core::provider::MediaProvider;
use sourin_core::registry::Registry;
use std::sync::Arc;

const REAL_STORE: &str = r"C:\Users\iuuuuuuuu\AppData\Roaming\app.sourin.player\plugins\.data";

fn probe_dir(tag: &str) -> std::path::PathBuf {
    let d = std::path::PathBuf::from(format!(
        r"D:\WishProject\sourin-flutter-spike\.probe\t38-{tag}"
    ));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn seed(dir: &std::path::Path) {
    let src = std::path::PathBuf::from(REAL_STORE).join("cycani.json");
    std::fs::copy(&src, dir.join("cycani.json")).expect("copy real store");
}

/// ⚠️ **必须**调 `hydrate_capabilities()`（实测踩到）
///
/// `from_source()` 只做静态解析，`capabilities` 是 `Capabilities::default()`
/// → `login_required == false`。而 `session_state()` 开头就是：
/// ```rust
/// if !caps.login_required && !caps.login_supported { return NotRequired }
/// ```
/// 于是**无论 token 死活都返回 NotRequired**，整个判定链根本没跑。
///
/// 第一版探针漏了这步，得到 `session_state() = NotRequired`，
/// 看起来像"状态判定坏了"，实际是**探针自己少调了一步**
///（真实应用走 `load_plugins_hydrated`，它内部会调）。
/// ⚠️ 这正是 VERIFY-LESSONS 里"假红/假绿"那一类：**先确认脚手架对了再信结论**。
async fn cycani_at(dir: std::path::PathBuf) -> JsPluginProvider {
    let src = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/plugins/cycani.js"
    ))
    .unwrap();
    let mut p = JsPluginProvider::from_source(&src).unwrap().with_data_dir(dir);
    // 与 `load_plugins_hydrated` 同一步（真实应用就是这样拿能力位的）
    p.hydrate_capabilities().await;
    p
}

/// 把一个合法 JWT 的 `exp` 改成**过去**（签名失效，但解析仍得出生效时间）
///
/// ⚠️ 站点会拒绝这个 token（签名对不上），这正是我们要的 ——
///    "token 已死"就是用户遇到的场景。
fn make_expired_token(orig: &str) -> String {
    let bare = orig.trim_start_matches("Bearer ").trim();
    let parts: Vec<&str> = bare.split('.').collect();
    if parts.len() != 3 {
        return orig.to_string();
    }
    // 用 base64 解出 payload、把 exp 改到昨天、再编回去（不改签名）
    let pad = |s: &str| {
        let mut t = s.to_string();
        while t.len() % 4 != 0 {
            t.push('=');
        }
        t
    };
    let payload = b64url_decode(&pad(parts[1]));
    let payload = match payload {
        Some(v) => String::from_utf8_lossy(&v).to_string(),
        None => return orig.to_string(),
    };
    // 粗糙但够用：把 "exp":<数字> 换成一个过去的时间戳
    let yesterday = chrono::Utc::now().timestamp() - 86400;
    let new_payload = match payload.find("\"exp\":") {
        Some(i) => {
            let rest = &payload[i + 6..];
            let end = rest
                .find(|c: char| !c.is_ascii_digit())
                .unwrap_or(rest.len());
            format!(
                "{}\"exp\":{}{}",
                &payload[..i],
                yesterday,
                &rest[end..]
            )
        }
        None => payload.clone(),
    };
    format!(
        "Bearer {}.{}.{}",
        parts[0],
        b64url_encode(new_payload.as_bytes()),
        parts[2]
    )
}

fn b64url_decode(s: &str) -> Option<Vec<u8>> {
    // 不引依赖：手写 base64url
    const T: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = Vec::new();
    let mut buf = 0u32;
    let mut bits = 0;
    for c in s.bytes() {
        if c == b'=' {
            break;
        }
        let v = T.iter().position(|&x| x == c)? as u32;
        buf = (buf << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buf >> bits) as u8);
        }
    }
    Some(out)
}

fn b64url_encode(data: &[u8]) -> String {
    const T: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::new();
    for chunk in data.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(T[((n >> 18) & 63) as usize] as char);
        out.push(T[((n >> 12) & 63) as usize] as char);
        if chunk.len() > 1 {
            out.push(T[((n >> 6) & 63) as usize] as char);
        }
        if chunk.len() > 2 {
            out.push(T[(n & 63) as usize] as char);
        }
    }
    out
}

#[tokio::test]
async fn t38_expired_token_full_chain() {
    let dir = probe_dir("expired");
    seed(&dir);

    // ── 把 token 换成已过期的 ──
    let path = dir.join("cycani.json");
    let raw = std::fs::read_to_string(&path).unwrap();
    let mut v: serde_json::Value = serde_json::from_str(&raw).unwrap();
    let sess_str = v["session"].as_str().unwrap().to_string();
    let mut sess: serde_json::Value = serde_json::from_str(&sess_str).unwrap();
    let old = sess["token"].as_str().unwrap().to_string();
    let newtok = make_expired_token(&old);
    sess["token"] = serde_json::Value::String(newtok.clone());
    // expiresAt 也改成过去（两处都要改 —— effective_expires_at 择优）
    sess["expiresAt"] =
        serde_json::Value::String("2020-01-01T00:00:00+08:00".to_string());
    v["session"] = serde_json::Value::String(serde_json::to_string(&sess).unwrap());
    std::fs::write(&path, serde_json::to_string_pretty(&v).unwrap()).unwrap();

    println!("\n=========== ★ 场景：token 已过期 ===========");
    let p = cycani_at(dir.clone()).await;
    println!("login_required = {}", p.manifest().capabilities.login_required);
    println!("login_supported= {}", p.manifest().capabilities.login_supported);
    println!("session_expired()      = {}", p.session_expired().await);
    println!("session_needs_refresh()= {}", p.session_needs_refresh().await);
    println!("can_auto_login()       = {}", p.can_auto_login().await);

    // ── 关键：走真 Registry ──
    let reg = Registry::new();
    reg.register(Arc::new(p));
    println!("Registry::len()        = {}", reg.len());

    let st = reg.session_state("cycani").await;
    println!("session_state()        = {st:?}   ★ 这决定 UI 文案");

    println!("\n--- ensure_session()（播放前会调它）---");
    let ok = reg.ensure_session("cycani").await;
    println!("ensure_session()       = {ok:?}   ★ Some(true) = 救活了");

    let st2 = reg.session_state("cycani").await;
    println!("救活后 session_state() = {st2:?}");

    // ── 救活后磁盘上是什么 ──
    let after = std::fs::read_to_string(&path).unwrap();
    let av: serde_json::Value = serde_json::from_str(&after).unwrap();
    if let Some(s) = av["session"].as_str() {
        let sj: serde_json::Value = serde_json::from_str(s).unwrap();
        println!(
            "救活后 token 前缀 = {}…",
            &sj["token"].as_str().unwrap_or("").chars().take(28).collect::<String>()
        );
        println!("救活后 expiresAt  = {}", sj["expiresAt"]);
    }

    assert_eq!(
        ok,
        Some(true),
        "★★★ 次元城**没有验证码**、凭据还在 → \
         ensure_session() 必须能自动重登成功。返回 {ok:?} 说明自动重登链路断了"
    );
    assert_eq!(
        st2,
        Some(sourin_core::provider::SessionState::Active),
        "★ 救活后应报 Active（UI 显示「已登录」）"
    );
}

/// ★ 阳性对照：**没有凭据**时才该报 expired（UI 显示"需要验证码"）
#[tokio::test]
async fn t38_no_credentials_is_expired() {
    let dir = probe_dir("nocred");
    seed(&dir);

    // 删掉 credentials（模拟"凭据丢了"）
    let path = dir.join("cycani.json");
    let raw = std::fs::read_to_string(&path).unwrap();
    let mut v: serde_json::Value = serde_json::from_str(&raw).unwrap();
    v.as_object_mut().unwrap().remove("credentials");
    std::fs::write(&path, serde_json::to_string_pretty(&v).unwrap()).unwrap();

    // token 也弄过期
    let raw = std::fs::read_to_string(&path).unwrap();
    let mut v: serde_json::Value = serde_json::from_str(&raw).unwrap();
    let sess_str = v["session"].as_str().unwrap().to_string();
    let mut sess: serde_json::Value = serde_json::from_str(&sess_str).unwrap();
    sess["token"] = serde_json::Value::String(make_expired_token(
        sess["token"].as_str().unwrap(),
    ));
    sess["expiresAt"] = serde_json::Value::String("2020-01-01T00:00:00+08:00".into());
    v["session"] = serde_json::Value::String(serde_json::to_string(&sess).unwrap());
    std::fs::write(&path, serde_json::to_string_pretty(&v).unwrap()).unwrap();

    let p = cycani_at(dir).await;
    println!("\n=========== 阳性对照：无凭据 + token 过期 ===========");
    println!("login_required = {}", p.manifest().capabilities.login_required);
    println!("can_auto_login() = {}", p.can_auto_login().await);
    println!("session_expired()= {}", p.session_expired().await);

    let reg = Registry::new();
    reg.register(Arc::new(p));
    let st = reg.session_state("cycani").await;
    println!("session_state()  = {st:?}   ★ 这时才是「登录已失效」");
    let ok = reg.ensure_session("cycani").await;
    println!("ensure_session() = {ok:?}");

    assert_eq!(
        ok,
        Some(false),
        "★ 没凭据 → 确实救不活，如实返回 false"
    );
    assert_eq!(
        st,
        Some(sourin_core::provider::SessionState::Expired),
        "★ 没凭据 + 已过期 → Expired（此时 UI 说'需人工登录'是**对的**）"
    );
    println!("★ ⇒ 只有这种情况 UI 才该说「需重新登录」");
}
