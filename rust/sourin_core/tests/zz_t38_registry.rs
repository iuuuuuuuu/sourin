// ═══════════════════════════════════════════════════════════════════════
//  task-38：`session_state` 的四个分支**都必须看凭据**（一致性）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要有这个文件
//
// `Registry::session_state` 是**决定 UI 说什么话**的那一处。
// 它原本有一条分支**没看凭据**：
// ```text
// L613  有过期会话 + can_auto_login → Expiring   ✅ 看了
// L626  无会话     + can_auto_login → Expiring   ✅ 看了
// L643  session() 报错             → Expired    ❌ 没看 ← 本次修掉
// ```
// 后果：`session()` 一报错（store 写坏 / 读盘失败 / 插件抛异常），
// **凭据完好的**插件也被判 `Expired` → UI 对用户说
// 「需重新登录（可能需要验证码，请手动完成）」，
// 而下一行 `ensure_session()` 就能用凭据把它救活 —— **自相矛盾**。
//
// 触发条件实测较窄（`cycani.js` 自己 try/catch 了 `JSON.parse`，
// 写坏时返回 `Ok(None)` 走安全分支），但**别的插件未必兜底**
// （用户自己能写插件），且这一行的存在本身就没有理由。
//
// ⚠️ 这些都是**假 provider**（不联网），锁的是判定逻辑本身。

use async_trait::async_trait;
use sourin_core::model::*;
use sourin_core::provider::*;
use sourin_core::registry::Registry;
use std::sync::Arc;

/// 最小可控 provider —— 直接带一个可配置的 manifest
///
/// 只覆写 `session()` / `can_auto_login()` 两个方法，
/// 其余全用 `MediaProvider` 的默认实现（trait 有默认值）。
struct Simple {
    m: ProviderManifest,
    session_mode: u8,
    can_auto: bool,
}

#[async_trait]
impl MediaProvider for Simple {
    fn manifest(&self) -> &ProviderManifest {
        &self.m
    }
    async fn session(&self) -> Result<Option<Session>> {
        match self.session_mode {
            0 => Ok(Some(Session {
                token: "Bearer t".into(),
                expires_at: Some(1),
                display_name: None,
                avatar: None,
            })),
            1 => Ok(None),
            _ => Err(ProviderError::new(ErrorKind::Other, "store 读坏了")),
        }
    }
    async fn can_auto_login(&self) -> bool {
        self.can_auto
    }

    /// ⚠️ `resolve` 是 trait 的**必填**项（没有默认实现）——
    ///    本文件只测 `session_state` 的判定逻辑，不取流，所以给个空实现。
    async fn resolve(
        &self,
        _id: &MediaId,
        _req: &PlayRequest,
    ) -> Result<Vec<StreamCandidate>> {
        Ok(vec![])
    }
}

fn mk(session_mode: u8, can_auto: bool, login_required: bool) -> Arc<Simple> {
    Arc::new(Simple {
        m: ProviderManifest {
            id: "zz".into(),
            name: "测试".into(),
            version: "1".into(),
            kind: "js".into(),
            description: None,
            icon: None,
            id_prefixes: vec![],
            capabilities: Capabilities {
                vod: true,
                login_required,
                ..Default::default()
            },
            cover_headers: vec![],
            config: vec![],
            api_version: 1,
            theme_color: None,
            working: true,
            broken_reason: None,
            enabled: None,
        },
        session_mode,
        can_auto,
    })
}

/// ★★★ 核心：`session()` **报错** + 有凭据 ⇒ `Expiring`（不是 `Expired`）
///
/// 这是本次修掉的那条分支。它红 ⟺ 有人把 `Err(_)` 改回不看凭据。
#[tokio::test]
async fn session_error_with_credentials_is_expiring() {
    let reg = Registry::new();
    reg.register(mk(2, true, true)); // session 报错 + 有凭据 + 必须登录

    let st = reg.session_state("zz").await;
    println!("[session 报错 + 有凭据] session_state = {st:?}");
    assert_eq!(
        st,
        Some(SessionState::Expiring),
        "★★★ `session()` 报错但有凭据时必须是 `Expiring`（还能自愈）—— \
         报 `Expired` 会让 UI 对用户说「需重新登录（可能需要验证码，请手动完成）」，\
         而下一行 ensure_session() 就能用凭据救活。**同一份判据自相矛盾**。"
    );
}

/// ★ 阳性对照：`session()` 报错 + **没有**凭据 ⇒ 确实 `Expired`
///
/// 没有这一条，上面那条断言可能只是"恒返回 Expiring"的假绿。
#[tokio::test]
async fn session_error_without_credentials_is_expired() {
    let reg = Registry::new();
    reg.register(mk(2, false, true)); // session 报错 + 无凭据

    let st = reg.session_state("zz").await;
    println!("[session 报错 + 无凭据] session_state = {st:?}");
    assert_eq!(
        st,
        Some(SessionState::Expired),
        "★ 没凭据 → 确实救不活 → Expired（此时 UI 说'需人工登录'是**对的**）"
    );
}

/// ★ 另两条已有的分支继续成立（防回归）
#[tokio::test]
async fn expired_session_and_no_session_still_use_credentials() {
    // 有过期会话 + 有凭据 → Expiring
    let reg = Registry::new();
    reg.register(mk(0, true, true));
    assert_eq!(
        reg.session_state("zz").await,
        Some(SessionState::Expiring),
        "有过期会话 + 有凭据 → Expiring（这条本来就有，防回归）"
    );

    // 无会话 + 有凭据 → Expiring
    let reg2 = Registry::new();
    reg2.register(mk(1, true, true));
    assert_eq!(
        reg2.session_state("zz").await,
        Some(SessionState::Expiring),
        "无会话 + 有凭据 → Expiring（这条本来就有，防回归）"
    );

    // 无会话 + 无凭据 + 必须登录 → Expired
    let reg3 = Registry::new();
    reg3.register(mk(1, false, true));
    assert_eq!(
        reg3.session_state("zz").await,
        Some(SessionState::Expired),
    );
    println!("[三条既有分支] 全部保持 ✓");
}
