// ═══════════════════════════════════════════════════════════════════════
//  task-38：运行时探测兜底（声明 或 探测）—— 端到端 + 红度
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件锁住"修复真的到用户手里"
//
// 实测发现的关键问题：
// ```text
// repo    rust/sourin_core/plugins/cycani.js     有 canAutoLogin: true 声明
// deployed %APPDATA%\...\plugins\cycani.js       **没有**（cycani.js 从不自动投放）
// ⇒ 只靠声明 ⇒ 用户永远看不到「正在自动重新登录」 ⇒ Owner 报的 bug 不变
// ```
// 所以 `hydrate_capabilities` 现在做「**声明 或 运行时探测**」。
//
// # ⚠️ 这些测试全部用**真实部署版插件**（读用户目录）
//
// 因为要证明的正是"用户那份（没有声明的）也能被正确识别"。
// 用仓库版测会**假绿** —— 那份有声明，探测分支根本不会跑。

use sourin_core::plugins::load_plugins_hydrated;
use sourin_core::provider::MediaProvider;

const REAL_PLUGINS: &str =
    r"C:\Users\iuuuuuuuu\AppData\Roaming\app.sourin.player\plugins";

fn tmp(tag: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!(
        "sourin-t38p-{tag}-{}",
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
    ));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// 把真实 plugins/（含 .data 凭据）复制到隔离目录
fn seed_real(tag: &str) -> std::path::PathBuf {
    let root = tmp(tag);
    let dst = root.join("plugins");
    std::fs::create_dir_all(&dst).unwrap();
    let src = std::path::PathBuf::from(REAL_PLUGINS);
    for e in std::fs::read_dir(&src).unwrap().flatten() {
        let p = e.path();
        let name = p.file_name().unwrap();
        if p.is_file() {
            let _ = std::fs::copy(&p, dst.join(name));
        } else if p.is_dir() {
            // .data/
            let d2 = dst.join(name);
            std::fs::create_dir_all(&d2).unwrap();
            for e2 in std::fs::read_dir(&p).unwrap().flatten() {
                let _ = std::fs::copy(e2.path(), d2.join(e2.file_name()));
            }
        }
    }
    dst
}

/// ★★★ 核心：**部署版**（无声明）也必须被探测出 can_auto_login = true
#[tokio::test]
async fn deployed_plugin_gets_can_auto_login_via_probe() {
    let dir = seed_real("deployed");

    // 先确认前提：部署版**真的没有**声明（否则本测试变成假绿）
    let dep = std::fs::read_to_string(dir.join("cycani.js")).unwrap();
    println!(
        "\n[前提] 部署版含 `canAutoLogin: true` 声明 = {}",
        dep.contains("canAutoLogin: true")
    );
    println!(
        "[前提] 部署版实现了 `async canAutoLogin()` = {}",
        dep.contains("async canAutoLogin()")
    );
    assert!(
        !dep.contains("canAutoLogin: true"),
        "★ 前提不成立：部署版**居然有**声明 —— 那本测试就测不到探测分支了。\
         说明用户那份插件被更新过了（或本机状态变了），请重新确认"
    );
    assert!(
        dep.contains("async canAutoLogin()"),
        "★ 前提：部署版必须有 canAutoLogin **方法**（探测的目标）"
    );

    // ── 加载（走真实路径：load_plugins_hydrated）──
    let (plugins, bad) = load_plugins_hydrated(&dir, None).await;
    println!("[加载] 成功 {} 个，失败 {} 个", plugins.len(), bad.len());

    let cycani = plugins
        .iter()
        .find(|p| p.manifest().id == "cycani")
        .expect("应加载到 cycani");

    let caps = &cycani.manifest().capabilities;
    println!(
        "[结果] can_auto_login = {}  ← 声明=false 但探测应为 true",
        caps.can_auto_login
    );

    assert!(
        caps.can_auto_login,
        "★★★ 部署版**没有声明**但**实现了** canAutoLogin() —— \
         运行时探测必须把它识别为 true。\
         实测为 false ⇒ 探测没生效 ⇒ 用户仍然会看到「可能需要验证码」"
    );

    // ★ 运行时方法本身也应为 true（与上面互相印证）
    assert!(
        cycani.can_auto_login().await,
        "★ 运行时方法本身应是 true"
    );
}

/// ★★ 声明优先：有声明时**不探测**（零额外开销）
///
/// 用一个"声明 true 但方法返回 false"的假插件验证：
/// 结果必须是 **true**（说明走的是声明、没去问方法）。
#[tokio::test]
async fn declaration_wins_and_skips_probe() {
    let dir = tmp("decl-wins");
    std::fs::write(
        dir.join("decl.js"),
        r#"
/** @id decl @name 声明优先 */
globalThis.plugin = {
  id: 'decl',
  capabilities: { vod: true, loginRequired: true, canAutoLogin: true },
  // ★ 方法故意返回 false —— 若**探测**了，结果会是 false
  async canAutoLogin() { return false; },
  async resolve() { return []; },
};
"#,
    )
    .unwrap();

    let (plugins, _) = load_plugins_hydrated(&dir, None).await;
    let p = plugins.iter().find(|p| p.manifest().id == "decl").unwrap();
    let v = p.manifest().capabilities.can_auto_login;
    println!("\n[声明优先] can_auto_login = {v}（方法返回 false）");
    assert!(
        v,
        "★ 声明为 true 时应**短路**、不去探测 —— 结果必须是 true。\
         若为 false 说明探测覆盖了声明（顺序反了，且白跑一次 JS）"
    );
}

/// ★ 探测**容错**：方法抛异常 ⇒ 当 false（不能当 true）
#[tokio::test]
async fn probe_failure_is_treated_as_false() {
    let dir = tmp("probe-throw");
    std::fs::write(
        dir.join("boom.js"),
        r#"
/** @id boom @name 探测会抛 */
globalThis.plugin = {
  id: 'boom',
  capabilities: { vod: true, loginRequired: true },
  async canAutoLogin() { throw new Error('探测失败'); },
  async resolve() { return []; },
};
"#,
    )
    .unwrap();

    let (plugins, _) = load_plugins_hydrated(&dir, None).await;
    let p = plugins.iter().find(|p| p.manifest().id == "boom").unwrap();
    let v = p.manifest().capabilities.can_auto_login;
    println!("\n[探测抛异常] can_auto_login = {v}（应为 false）");
    assert!(
        !v,
        "★★ 探测**抛异常**时必须当 false —— 当 true 会显示「正在自动重新登录」\
         然后失败，**比原来那句通用文案更糟**（从「误导」变成「撒谎」）"
    );
}

/// ★ 没有 `canAutoLogin` 方法的插件 ⇒ false（不报错）
#[tokio::test]
async fn plugin_without_method_is_false() {
    let dir = tmp("no-method");
    std::fs::write(
        dir.join("plain.js"),
        r#"
/** @id plain @name 没实现 */
globalThis.plugin = {
  id: 'plain',
  capabilities: { vod: true, loginRequired: true },
  async resolve() { return []; },
};
"#,
    )
    .unwrap();

    let (plugins, _) = load_plugins_hydrated(&dir, None).await;
    let p = plugins.iter().find(|p| p.manifest().id == "plain").unwrap();
    println!(
        "\n[无方法] can_auto_login = {}",
        p.manifest().capabilities.can_auto_login
    );
    assert!(!p.manifest().capabilities.can_auto_login);
}

/// ★★ 门控：**不支持登录**的插件**不做探测**（避免 25 个源白跑）
///
/// 判据：给它写一个"方法返回 true"但**没有登录能力**的插件 ——
/// 结果必须是 **false**（说明被门控挡住了，压根没问）。
#[tokio::test]
async fn probe_is_gated_on_login_support() {
    let dir = tmp("gate");
    std::fs::write(
        dir.join("nologin.js"),
        r#"
/** @id nologin @name 不涉及登录 */
globalThis.plugin = {
  id: 'nologin',
  capabilities: { vod: true },
  // ★ 故意返回 true —— 但本插件不支持登录，不该被探测
  async canAutoLogin() { return true; },
  async resolve() { return []; },
};
"#,
    )
    .unwrap();

    let (plugins, _) = load_plugins_hydrated(&dir, None).await;
    let p = plugins.iter().find(|p| p.manifest().id == "nologin").unwrap();
    let v = p.manifest().capabilities.can_auto_login;
    println!("\n[门控] can_auto_login = {v}（不支持登录 ⇒ 不探测 ⇒ false）");
    assert!(
        !v,
        "★ 不支持登录的源不该被探测（`login_required`/`login_supported` 都为 false）—— \
         否则 25 个无关插件每次加载都白跑一次 JS 求值"
    );
}

/// ★ 整机视角：真实 26 个插件里，**恰好 cycani 一个**拿到 can_auto_login
#[tokio::test]
async fn only_cycani_gets_auto_login_among_real_plugins() {
    let dir = seed_real("real-all");
    let (plugins, _) = load_plugins_hydrated(&dir, None).await;

    let mut yes = Vec::new();
    for p in &plugins {
        if p.manifest().capabilities.can_auto_login {
            yes.push(p.manifest().id.clone());
        }
    }
    println!(
        "\n[整机] {} 个插件里有 can_auto_login 的: {yes:?}",
        plugins.len()
    );
    assert_eq!(
        yes,
        vec!["cycani".to_string()],
        "★ 真实插件里应**只有** cycani（它实现了 canAutoLogin + store 里有凭据）。\
         bilibili 既没实现方法也没凭据 ⇒ 必须是 false。实际 {yes:?}"
    );
}
