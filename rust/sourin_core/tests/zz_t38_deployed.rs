// ═══════════════════════════════════════════════════════════════════════
//  task-38 证据：**用户实际部署的那份** cycani.js 的能力探测
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要单独测"部署版"
//
// 实测发现：`canAutoLogin: true` 这个**声明**只存在于仓库副本里
// （`rust/sourin_core/plugins/cycani.js`），而运行时加载的是
// **用户目录那份**（`%APPDATA%\...\plugins\cycani.js`）——
// 它**没有**那行声明（`cycani.js` 从来不由程序投放，见 state.rs:707）。
//
// ⇒ 所以"声明式能力位"对真实用户**取不到值**。
//
// ★ 这个探针验证：**运行时方法** `canAutoLogin()` 在**部署版**上是否为 true。
//   若为 true ⇒ 说明"直接问插件"（而不是"等它声明"）能立刻拿到正确答案，
//   这为"声明 或 探测"那个方案提供依据。

use sourin_core::plugins::JsPluginProvider;
use sourin_core::provider::MediaProvider;

const REAL_PLUGINS: &str =
    r"C:\Users\iuuuuuuuu\AppData\Roaming\app.sourin.player\plugins";

fn tmp(tag: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("sourin-t38-{tag}"));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

#[tokio::test]
async fn deployed_cycani_reports_can_auto_login_at_runtime() {
    // ── 读**部署版**（用户实际加载的那份）──
    let dep_path = std::path::PathBuf::from(REAL_PLUGINS).join("cycani.js");
    let dep = std::fs::read_to_string(&dep_path).expect("读部署版 cycani.js");

    // ── 也读仓库版，做对比 ──
    let repo = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/plugins/cycani.js"
    ))
    .unwrap();

    println!("\n=========== 部署版 vs 仓库版 ===========");
    println!("部署版 字节 = {}", dep.len());
    println!("仓库版 字节 = {}", repo.len());
    println!(
        "部署版有 `canAutoLogin: true` 声明 = {}",
        dep.contains("canAutoLogin: true")
    );
    println!(
        "仓库版有 `canAutoLogin: true` 声明 = {}",
        repo.contains("canAutoLogin: true")
    );
    println!(
        "部署版实现了 `canAutoLogin()` 方法 = {}",
        dep.contains("async canAutoLogin()")
    );

    // ── 关键：部署版的**运行时探测**结果 ──
    //   数据目录用真实 .data 的副本（那里有 credentials）
    let data = tmp("deployed-data");
    let real_data = std::path::PathBuf::from(REAL_PLUGINS).join(".data");
    if real_data.join("cycani.json").exists() {
        std::fs::copy(real_data.join("cycani.json"), data.join("cycani.json"))
            .expect("复制 store");
        println!("已复制真实 store（含 credentials）");
    }

    let mut p_dep = JsPluginProvider::from_source(&dep)
        .expect("解析部署版")
        .with_data_dir(data.clone());
    p_dep.hydrate_capabilities().await;

    let declared = p_dep.manifest().capabilities.can_auto_login;
    let runtime = p_dep.can_auto_login().await;

    println!("\n=========== 部署版的能力值 ===========");
    println!("声明式 can_auto_login = {declared}   ← 来自 capabilities");
    println!("运行时 can_auto_login() = {runtime}  ← 直接问插件");

    // ── 断言：部署版的**运行时探测**必须为 true ──
    assert!(
        runtime,
        "★★★ 部署版 cycani.js 实现了 canAutoLogin() 且 store 里有凭据 —— \
         运行时探测必须是 true。若为 false，说明凭据不在/插件坏了"
    );

    /*
     * ★★ 记录"声明式取不到值"这个事实（**不**断言它必须为 false ——
     *    那样在仓库版被投放后会假红）。
     *    这里只是把两者的差异打印出来，作为"要不要改成运行时探测"的依据。
     */
    if !declared && runtime {
        println!(
            "\n★★★ 结论：部署版 **声明式取不到值（false）但运行时为 true**\n\
             ⇒ 只靠声明，用户永远看不到「正在自动重新登录」\n\
             ⇒ 「运行时探测」能立刻拿到正确答案"
        );
    }

    // ── 阳性对照：把凭据删掉 → 运行时也必须变 false ──
    let data2 = tmp("deployed-nocred");
    let mut v: serde_json::Value = serde_json::from_str(&dep_store()).unwrap();
    v.as_object_mut().unwrap().remove("credentials");
    std::fs::write(
        data2.join("cycani.json"),
        serde_json::to_string_pretty(&v).unwrap(),
    )
    .unwrap();

    let mut p2 = JsPluginProvider::from_source(&dep)
        .unwrap()
        .with_data_dir(data2);
    p2.hydrate_capabilities().await;
    let runtime2 = p2.can_auto_login().await;
    println!("\n阳性对照（删掉 credentials）: can_auto_login() = {runtime2}");
    assert!(
        !runtime2,
        "★ 没有凭据时运行时探测必须是 false（否则「能不能自动重登」这个判据是坏的）"
    );
}

fn dep_store() -> String {
    std::fs::read_to_string(
        std::path::PathBuf::from(REAL_PLUGINS)
            .join(".data")
            .join("cycani.json"),
    )
    .expect("读真实 store")
}
