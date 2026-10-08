// ═══════════════════════════════════════════════════════════════════════
//  task-38：量出「运行时探测 canAutoLogin」的**实际开销**
// ═══════════════════════════════════════════════════════════════════════
//
// Lead 要求③：「探测的**开销要量**（你说"微秒级"，但要实测）……
//               判据：量出**中位数**，并写进注释」
//
// # 为什么值得量
//
// `hydrate_capabilities` 在**插件加载时**跑一次
// （`load_plugins_hydrated` → 每个插件一次，不是每次请求）。
// 但探测本身要**新建一个 QuickJS 运行时 + 重跑整个插件脚本**（`call_js` 的实现），
// 所以它**不是**"读个文件"那么便宜 —— 必须量出来。
//
// # 量什么
//
// ```text
// ① 只 hydrate（读 capabilities）           ← 基线
// ② hydrate + 探测（login 源，声明缺失时）  ← 本次新增的代价
// 差值 = 探测的真实开销
// ```
//
// ⚠️ 用**部署版真实插件**（那份没有声明 ⇒ 真会走探测分支）。

use sourin_core::plugins::JsPluginProvider;
// ★ `manifest()` 是 `MediaProvider` 的方法 —— 不引入 trait 会
//   `error[E0599]: no method named manifest found`
use sourin_core::provider::MediaProvider;
use std::time::Instant;

const REAL_PLUGINS: &str =
    r"C:\Users\iuuuuuuuu\AppData\Roaming\app.sourin.player\plugins";

fn tmp(tag: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("sourin-t38perf-{tag}"));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    if v.is_empty() {
        return 0.0;
    }
    let n = v.len();
    if n % 2 == 1 {
        v[n / 2]
    } else {
        (v[n / 2 - 1] + v[n / 2]) / 2.0
    }
}

#[tokio::test]
async fn measure_probe_cost() {
    let dir = tmp("perf");
    let dep = std::fs::read_to_string(
        std::path::PathBuf::from(REAL_PLUGINS).join("cycani.js"),
    )
    .expect("读部署版");

    // 前置：确认它**没有**声明（否则不会走探测分支，量不到东西）
    assert!(
        !dep.contains("canAutoLogin: true"),
        "★ 前提：部署版必须没有声明，才量得到探测分支的开销"
    );

    // 数据目录（含凭据 ⇒ canAutoLogin() 会返回 true）
    let data = dir.join(".data");
    std::fs::create_dir_all(&data).unwrap();
    let real_data = std::path::PathBuf::from(REAL_PLUGINS).join(".data");
    if real_data.join("cycani.json").exists() {
        std::fs::copy(real_data.join("cycani.json"), data.join("cycani.json")).unwrap();
    }

    let make = |d: std::path::PathBuf| {
        JsPluginProvider::from_source(&dep)
            .expect("解析")
            .with_data_dir(d)
    };

    // ── ① 基线：只 hydrate（无探测 —— 用一个"不支持登录"的变体关掉门控）──
    /*
     * ⚠️ 关掉门控的办法：把 `loginRequired` 从源码里改掉。
     *    这样同一份插件、同样的脚本体积，只是**不触发**探测 ——
     *    差值是干净的"探测本身"的代价（不含脚本解析等共同成本）。
     */
    let no_login = dep.replace("loginRequired: true", "loginRequired: false");
    assert_ne!(no_login, dep, "★ 应能关掉 loginRequired（否则量不准）");

    const N: usize = 15;

    let mut base = Vec::new();
    for _ in 0..N {
        let mut p = JsPluginProvider::from_source(&no_login)
            .unwrap()
            .with_data_dir(data.clone());
        let t = Instant::now();
        p.hydrate_capabilities().await;
        base.push(t.elapsed().as_secs_f64() * 1000.0);
    }

    // ── ② 带探测 ──
    let mut withprobe = Vec::new();
    for _ in 0..N {
        let mut p = make(data.clone());
        let t = Instant::now();
        p.hydrate_capabilities().await;
        withprobe.push(t.elapsed().as_secs_f64() * 1000.0);
        // 顺带确认探测真的生效了
        assert!(
            p.manifest().capabilities.can_auto_login,
            "★ 这次 hydrate 应通过探测拿到 true"
        );
    }

    let mb = median(base.clone());
    let mp = median(withprobe.clone());
    println!("\n================ 探测开销实测（n={N}）================");
    println!("基线（不触发探测）      中位数 = {mb:.3} ms");
    println!("带探测（缺声明 ⇒ 走探测）中位数 = {mp:.3} ms");
    println!("★ 探测净开销            中位数 = {:.3} ms", mp - mb);
    println!(
        "   基线范围 = [{:.3}, {:.3}] ms",
        base.iter().cloned().fold(f64::INFINITY, f64::min),
        base.iter().cloned().fold(0.0, f64::max)
    );
    println!(
        "   带探测范围 = [{:.3}, {:.3}] ms",
        withprobe.iter().cloned().fold(f64::INFINITY, f64::min),
        withprobe.iter().cloned().fold(0.0, f64::max)
    );

    /*
     * ★ 判据（不是"必须 <1ms"那种武断的阈值）：
     *
     * ```text
     * ① 这个开销发生在**插件加载时**（不是每次请求）
     *    —— 26 个插件 × 每个一次 ≈ 一次性成本
     * ② 它换来的是"修复真的到用户手里"（否则整个 task-38 白做）
     * ③ 所以只要不是**数量级**上的问题（比如 >100ms/插件 ⇒ 26 个要 2.6 秒）
     *    就可以接受
     * ```
     * 这里断言一个**宽松上界**（50ms），
     * 意图是"若哪天变成秒级，测试会红并提醒去看"。
     */
    let cost = mp - mb;
    assert!(
        cost < 50.0,
        "★ 探测净开销 {cost:.3} ms 超过 50ms —— 26 个插件会变成秒级加载。\
         需要改成缓存或懒加载（但**不能**首次懒加载：那会让首次显示错文案）"
    );
    println!("\n★ 结论：净开销 {cost:.3} ms/插件，发生在**加载时**（非每次请求）—— 可接受");
}
