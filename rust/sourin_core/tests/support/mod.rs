//  实机依赖门控：这批诊断测试需要**真实凭据 + 真实第三方站点**
//
//  为什么需要它
//
// `zz_t38_chain.rs` / `zz_t38_corrupt.rs` / `zz_t38_diag.rs` 做的是**端到端诊断**：
// 从开发机的 `%APPDATA%\app.sourin.player\plugins\.data` 拷一份真实的
// `cycani.json`，伪造一个过期 token，然后让真 Registry 去**真的重新登录**那个站点。
//
// 两个条件缺一不可：
// ① 本机有那份真实凭据文件；
// ② 能连上那个第三方站点，且**它没有changed**：站点随时可能改接口、弹验证码、
//    加风控 —— 2026-10-10 实测就���在 `ensure_session()` 返回 `Some(false)`
//    （自动重登链路断了，但那既可能是代码问题、也可能是站点变了，
//    单看这条测试分不出来）。
//
// ⇒ 两条都不满足时**跳过**并说明原因。
//   这不是「放宽断言」：断言本身一个字没动，只是把它从「每次 cargo test 都跑」
//   改成「明确知道自己在跑什么的时候才跑」。
//   本仓 CI（GitHub Actions）跑的是 Linux runner —— 那个路径根本不存在，
//   这条测试在 CI 上**必然**红。
//
// 手动跑（在那台有凭据、且愿意承担站点变动风险的开发机上）：
// ```text
// cargo test --test zz_t38_chain -- --ignored --nocapture
// ```
pub fn real_creds_required() -> Option<&'static str> {
    let p = std::path::Path::new(super::REAL_STORE).join("cycani.json");
    if !p.exists() {
        return Some(
            "需要开发机上的真实凭据（REAL_STORE/cycani.json）+ 能连上该第三方站点。\
             本机没有凭据 ⇒ 跳过。手动跑：cargo test -- --ignored --nocapture",
        );
    }
    None
}

/// 同上，但打印跳过原因（`--nocapture` 时能看清为什么没跑）
pub fn real_creds_required_echo(tag: &str) -> Option<&'static str> {
    let r = real_creds_required();
    if let Some(why) = r {
        println!("[T38:{tag}] 跳过 —— {why}");
    } else {
        println!(
            "[T38:{tag}] ★ 将走**真实网络 + 真实账号**重登链路（结果可能随站点变动而变）"
        );
    }
    r
}