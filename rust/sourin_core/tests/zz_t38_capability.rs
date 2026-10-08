// ═══════════════════════════════════════════════════════════════════════
//  task-38：`canAutoLogin` 能力位 —— 端到端 + 默认值 + 红度证明
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么这些断言是必要的
//
// `hydrate_capabilities` 是**逐字段**读的（`mod.rs` 里注释强调过三次）——
// 往 `Capabilities` 加字段**不会**自动生效。漏了赋值那一行：
// ```text
// 插件声明 canAutoLogin: true
//   → capabilities.can_auto_login 恒为 false
//   → UI 继续显示「可能需要验证码，请手动完成」
//   → ★ Owner 报的 bug 原封不动回来，而且不报任何错
// ```
// 所以"声明 → 解析 → 传给前端"这三段都要锁住。

use sourin_core::plugins::JsPluginProvider;
use sourin_core::provider::MediaProvider;

const REAL_STORE: &str =
    r"C:\Users\iuuuuuuuu\AppData\Roaming\app.sourin.player\plugins\.data";

fn tmp(tag: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!(
        "sourin-t38-{tag}-{}",
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
    ));
    std::fs::create_dir_all(&d).unwrap();
    d
}

async fn hydrate(src: &str, dir: std::path::PathBuf) -> JsPluginProvider {
    let mut p = JsPluginProvider::from_source(src).unwrap().with_data_dir(dir);
    p.hydrate_capabilities().await;
    p
}

/// ★ 真实的 `cycani.js` 必须声明并解析出 `can_auto_login == true`
///
/// 这是"用户不再看到验证码"的**唯一前提**。
#[tokio::test]
async fn real_cycani_declares_can_auto_login() {
    let src = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/plugins/cycani.js"
    ))
    .expect("读真实 cycani.js");

    // ① 源码里必须**声明**（否则能力位无从谈起）
    assert!(
        src.contains("canAutoLogin: true"),
        "★★ cycani.js 必须声明 canAutoLogin: true —— \
         漏了它，UI 会继续对用户说「可能需要验证码」（Owner 报的正是这个）"
    );

    // ② 解析后必须为 true（这一条锁住 hydrate_capabilities 里那行赋值）
    let p = hydrate(&src, tmp("real")).await;
    assert!(
        p.manifest().capabilities.can_auto_login,
        "★★★ 声明了 canAutoLogin: true，但 hydrate 后 can_auto_login 仍是 false —— \
         `hydrate_capabilities` 里漏了 `c.can_auto_login = flag(\"can_auto_login\")`。\
         表现：插件明明能自动重登，设置页却还说「可能需要验证码」"
    );
    println!(
        "[真实 cycani] can_auto_login = {}",
        p.manifest().capabilities.can_auto_login
    );
}

/// ★★ 默认必须是 **false** —— 没声明的老插件不能显示「正在自动重新登录」
///
/// 默认 true 的后果：老插件（没实现 `autoLogin()`）也被承诺"正在自动重登"
/// → 用户干等一个**永远不会发生**的重登 → 比原文案**更糟**（撒谎）。
#[tokio::test]
async fn undeclared_defaults_to_false() {
    // 模拟一个 26 个老插件那样的：只声明 vod/loginRequired，**没有** canAutoLogin
    let src = r#"
/** @id legacy @name 老插件 */
globalThis.plugin = {
  id: 'legacy',
  capabilities: { vod: true, loginRequired: true },
  async session() { return null; },
  async resolve() { return []; },
};
"#;
    let p = hydrate(src, tmp("legacy")).await;
    assert!(
        !p.manifest().capabilities.can_auto_login,
        "★★ 没声明 canAutoLogin 的插件，can_auto_login 必须是 **false** —— \
         否则会给用户一个永远不会兑现的承诺（'正在自动重新登录'）"
    );
    println!("[老插件] can_auto_login = false（默认值正确）✓");
}

/// ★ 声明 `false` 也要被尊重（不是"看到字段就 true"）
#[tokio::test]
async fn explicit_false_is_respected() {
    let src = r#"
/** @id nocaptcha @name 显式声明不能自动重登 */
globalThis.plugin = {
  id: 'nocaptcha',
  capabilities: { vod: true, loginRequired: true, canAutoLogin: false },
  async session() { return null; },
  async resolve() { return []; },
};
"#;
    let p = hydrate(src, tmp("false")).await;
    assert!(!p.manifest().capabilities.can_auto_login);
    println!("[显式 false] 被正确尊重 ✓");
}

/// ★ camelCase → snake_case 必须通了（`canAutoLogin` → `can_auto_login`）
///
/// `call_js` 会把 JS 返回值的键做 camel→snake 转换，
/// 能力位是按 `can_auto_login` 查的 —— 这一步断了，前面都白做。
#[tokio::test]
async fn camel_case_key_is_converted() {
    // 故意用 camelCase 写（插件作者就是这么写的）
    let src = r#"
/** @id cc @name 驼峰键 */
globalThis.plugin = {
  id: 'cc',
  capabilities: { vod: true, canAutoLogin: true },
  async resolve() { return []; },
};
"#;
    let p = hydrate(src, tmp("camel")).await;
    assert!(
        p.manifest().capabilities.can_auto_login,
        "★ `canAutoLogin`（camelCase）必须能转成 `can_auto_login` —— \
         真实插件写的就是驼峰，转换断了整个功能静默失效"
    );
    println!("[驼峰] canAutoLogin → can_auto_login ✓");
}

/// ★★ 序列化给前端的 JSON 里必须带 `can_auto_login` 且是 true
///
/// 前端 `models.dart` 读的是 `j['can_auto_login']`。
/// 这一条锁住"后端 → 前端"那段契约。
#[tokio::test]
async fn serialized_json_exposes_can_auto_login() {
    let src = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/plugins/cycani.js"
    ))
    .unwrap();
    let p = hydrate(&src, tmp("json")).await;

    let m = p.manifest();
    let j = serde_json::to_value(&m).expect("序列化 manifest");
    /*
     * ⚠️ 能力位嵌在 `capabilities` **里面**，不是顶层 ——
     *    第一版我写成 `j.get("can_auto_login")` 得到 `None`（测试自己的 bug）。
     *    这正是"前端契约"要测的形态：前端读的是 `capabilities.can_auto_login`。
     */
    let caps = j.get("capabilities").expect("manifest 应有 capabilities");
    println!(
        "[序列化] capabilities.can_auto_login = {:?}",
        caps.get("can_auto_login")
    );

    assert_eq!(
        caps.get("can_auto_login").and_then(|v| v.as_bool()),
        Some(true),
        "★★★ 序列化后的 JSON 里 `capabilities.can_auto_login` 必须是 true —— \
         前端 `models.dart` 读的就是这个键；缺了它前端 `?? false` 兜底成 false，\
         文案又变回「可能需要验证码」"
    );
}
