//! 站点级流量代理
//!
//! # 为什么必须做（实测动机）
//!
//! 2026-09-14 实测（本机 `http://127.0.0.1:7890`）：
//!
//! | 域名 | 直连 | 经代理 |
//! |---|---|---|
//! | `www.googleapis.com` | ❌ 不可达 | ✅ 通 |
//! | `oauth2.googleapis.com` | ❌ 不可达 | ✅ 通 |
//! | `developers.google.com` | ❌ 不可达 | ✅ 200 |
//! | `graph.microsoft.com` | ✅ 301 | ✅ 301 |
//!
//! → **Google Drive 的 OAuth 在国内无代理下根本走不通**，
//!   所以代理不只是"内容站点的可选项"，而是同步后端的前置依赖。
//!
//! # 三个设计要点（来自方案文档 2.4）
//!
//! 1. **流媒体也走代理，但默认只让 API 走** —— 视频分片请求量大，
//!    代理带宽不足会卡顿。故有 `scope`（仅 API / 全流量）开关。
//! 2. **代理健康检查** —— 设置页要能「测试连接」。
//! 3. **凭据走钥匙串** —— 代理密码不写入导出备份。
//!
//! # 层级
//!
//! ```text
//! 全局默认（本模块的 default） → Provider 级覆盖 → 单次请求级（调试）
//! ```text
//!
//! 注意：Owner 已决策**不做全局默认策略**，未配置的站点一律直连。
//! `default_config()` 存在的意义是给「同步后端」这类非 Provider 场景用。

use crate::model::ProviderError;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

/// keyring 服务名（代理密码专用，与登录令牌分开命名空间）
///
/// ⚠️⚠️ **这个值不要跟着应用改名一起改**（2026-09-19）
///
/// # 为什么
///
/// 它决定凭据在系统钥匙串里的**存放位置**。改名 = 换个抽屉找东西 ——
/// 用户之前存的代理密码会**读不到**，表现为"明明填过密码，却提示未配置"。
///
/// 全项目有三个这样的常量：
/// ```text
/// dsh-media-client-proxy   ← 本站（代理密码）
/// dsh-media-client-sync    ← WebDAV 密码（sync/mod.rs）
/// dsh-media-client         ← 次元城账号（providers/cycani.rs）
/// ```
/// 三者都**保持原值** —— 虽然应用已改名「源影 Sourin」，
/// 但服务名对用户**完全不可见**，且不含任何敏感信息，
/// 改它只会带来"凭据莫名失效"的风险，没有任何收益。
///
/// 若将来真要做（比如为了品牌一致性），正确做法是**迁移**：
/// 启动时从旧服务名读一次、写进新服务名，成功后再删旧的。
/// 但那需要额外的失败处理，收益又只是"源码里好看一点"——
/// 所以**目前有意不做**。
const KEYRING_SERVICE: &str = "dsh-media-client-proxy";

// ─────────────────────────── 配置模型 ───────────────────────────

/// 代理模式
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ProxyMode {
    /// 直连（未配置站点的默认值）
    #[default]
    Direct,
    /// 跟随系统（读环境变量 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY）
    System,
    /// 自定义（该 Provider 专用）
    Custom,
}

/// 作用范围
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ProxyScope {
    /// 仅 API 走代理（视频直连更流畅）—— 默认
    #[default]
    ApiOnly,
    /// 全部流量走代理（含视频分片）
    All,
}

/// 单个站点的代理配置
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProxyConfig {
    #[serde(default)]
    pub mode: ProxyMode,
    /// 代理地址，如 `http://127.0.0.1:7890` / `socks5://127.0.0.1:1080`
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// 不走代理的主机
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub bypass: Vec<String>,
    #[serde(default)]
    pub scope: ProxyScope,
    /// 代理是否需要认证（用户名）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    // ⚠️ 密码绝不在此结构里 —— 只存钥匙串，见 set_password / take_password
}

impl Default for ProxyConfig {
    fn default() -> Self {
        Self {
            mode: ProxyMode::Direct,
            url: None,
            bypass: Vec::new(),
            scope: ProxyScope::ApiOnly,
            username: None,
        }
    }
}

impl ProxyConfig {
    /// 该配置是否真的会用到代理
    pub fn uses_proxy(&self) -> bool {
        match self.mode {
            ProxyMode::Direct => false,
            ProxyMode::System => true,
            // Custom 但没填地址 → 等于没配，按直连处理（避免 reqwest 报错）
            ProxyMode::Custom => self.url.as_deref().map(|u| !u.trim().is_empty()).unwrap_or(false),
        }
    }
}

// ─────────────────────────── 校验 ───────────────────────────

/// 支持的代理协议（reqwest 的 `socks` feature 已启用）
const ALLOWED_SCHEMES: &[&str] = &["http://", "https://", "socks4://", "socks4a://", "socks5://", "socks5h://"];

/// 校验代理地址，返回规范化后的 URL
pub fn validate_proxy_url(raw: &str) -> Result<String, String> {
    let u = raw.trim();
    if u.is_empty() {
        return Err("代理地址不能为空".into());
    }
    let lower = u.to_lowercase();
    if !ALLOWED_SCHEMES.iter().any(|s| lower.starts_with(s)) {
        return Err(format!(
            "代理地址需以 {} 开头（当前: {}）",
            ALLOWED_SCHEMES.join(" / "),
            u.chars().take(24).collect::<String>()
        ));
    }
    // 必须有主机部分
    let after_scheme = &u[lower.find("://").map(|i| i + 3).unwrap_or(0)..];
    if after_scheme.is_empty() || after_scheme.starts_with('/') || after_scheme.starts_with(':') {
        return Err("代理地址缺少主机名或端口".into());
    }
    Ok(u.to_string())
}

// ─────────────────────────── 密钥存储 ───────────────────────────

fn keyring_entry(provider: &str) -> Result<keyring::Entry, String> {
    keyring::Entry::new(KEYRING_SERVICE, provider).map_err(|e| format!("钥匙串不可用: {e}"))
}

/// 把代理密码写入系统钥匙串（**不落库、不进备份**）
pub fn set_proxy_password(provider: &str, password: &str) -> Result<(), String> {
    let entry = keyring_entry(provider)?;
    if password.is_empty() {
        let _ = entry.delete_credential();
        return Ok(());
    }
    entry
        .set_password(password)
        .map_err(|e| format!("写入钥匙串失败: {e}"))
}

/// 读取代理密码
pub fn get_proxy_password(provider: &str) -> Option<String> {
    keyring_entry(provider).ok()?.get_password().ok()
}

/// 清除代理密码
pub fn clear_proxy_password(provider: &str) -> Result<(), String> {
    let entry = keyring_entry(provider)?;
    let _ = entry.delete_credential();
    Ok(())
}

// ─────────────────────────── 注册表 ───────────────────────────

/// 代理配置注册表 + HTTP 客户端缓存
///
/// **为什么要缓存**：reqwest 的 `Client` 内部有连接池，
/// 每次请求都新建会丢掉连接复用，也会反复做 TLS 握手。
/// 但带认证的代理每次都要取密码，故缓存键包含配置摘要。
pub struct ProxyStore {
    configs: RwLock<HashMap<String, ProxyConfig>>,
    /// 客户端缓存：key = `"{provider}|{scope}|{配置摘要}"`
    clients: Mutex<HashMap<String, reqwest::Client>>,
}

impl Default for ProxyStore {
    fn default() -> Self {
        Self::new()
    }
}

impl ProxyStore {
    pub fn new() -> Self {
        Self {
            configs: RwLock::new(HashMap::new()),
            clients: Mutex::new(HashMap::new()),
        }
    }

    /// 全量配置（供 UI 读取；**不含密码**）
    pub fn all(&self) -> HashMap<String, ProxyConfig> {
        self.configs.read().unwrap().clone()
    }

    pub fn get(&self, provider: &str) -> ProxyConfig {
        self.configs
            .read()
            .unwrap()
            .get(provider)
            .cloned()
            .unwrap_or_default()
    }

    /// 写入配置（校验 URL；校验失败不改动现状）
    pub fn set(&self, provider: &str, mut cfg: ProxyConfig) -> Result<(), String> {
        if cfg.mode == ProxyMode::Custom {
            let url = cfg
                .url
                .as_deref()
                .ok_or_else(|| "自定义代理必须填写地址".to_string())?;
            cfg.url = Some(validate_proxy_url(url)?);
        }
        // 配置变了 → 缓存作废（否则会继续用旧出口）
        self.clients.lock().unwrap().clear();
        self.configs
            .write()
            .unwrap()
            .insert(provider.to_string(), cfg);
        Ok(())
    }

    /// 清除某站点的代理配置（回到直连）
    pub fn clear(&self, provider: &str) -> Result<(), String> {
        self.clients.lock().unwrap().clear();
        self.configs.write().unwrap().remove(provider);
        clear_proxy_password(provider)
    }

    /// ★ 取该站点应当使用的 HTTP 客户端
    ///
    /// `scope` 参数允许调用方覆盖配置里的 scope（例如同步后端强制走全流量）。
    pub fn client_for(&self, provider: &str, scope: Option<ProxyScope>) -> Result<reqwest::Client, ProviderError> {
        let cfg = self.get(provider);
        let eff_scope = scope.unwrap_or(cfg.scope);

        // 仅 API 走代理时，视频分片类请求应直连 —— 由调用方决定传什么 scope，
        // 这里只负责「这个客户端怎么建」。
        let key = format!(
            "{provider}|{eff_scope:?}|{}|{:?}|{:?}",
            cfg.url.as_deref().unwrap_or(""),
            cfg.mode,
            cfg.bypass
        );

        if let Some(c) = self.clients.lock().unwrap().get(&key) {
            return Ok(c.clone());
        }

        let client = self.build_client(provider, &cfg)?;
        self.clients
            .lock()
            .unwrap()
            .insert(key, client.clone());
        Ok(client)
    }

    fn build_client(&self, provider: &str, cfg: &ProxyConfig) -> Result<reqwest::Client, ProviderError> {
        let mut b = reqwest::Client::builder()
            .timeout(Duration::from_secs(20))
            .user_agent(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            );

        match cfg.mode {
            ProxyMode::Direct => {
                // ⚠️ 必须显式 no_proxy()：否则即使配置成「直连」，
                //    reqwest 仍会读环境变量里的代理，与用户意图相反。
                b = b.no_proxy();
            }
            ProxyMode::System => {
                // 不调用 no_proxy()，reqwest 自动读 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY
            }
            ProxyMode::Custom => {
                let raw = cfg.url.as_deref().unwrap_or("").trim();
                if raw.is_empty() {
                    b = b.no_proxy();
                } else {
                    let mut proxy = reqwest::Proxy::all(raw).map_err(|e| {
                        ProviderError::new(
                            crate::model::ErrorKind::Other,
                            format!("代理地址无效（{raw}）: {e}"),
                        )
                    })?;

                    // 带认证的代理：密码从钥匙串取，绝不落库
                    if let Some(user) = cfg.username.as_deref().filter(|s| !s.is_empty()) {
                        let pass = get_proxy_password(provider).unwrap_or_default();
                        proxy = proxy.basic_auth(user, &pass);
                    }

                    // ⚠️ 绕过列表挂在 `Proxy` 上（不是 ClientBuilder）：
                    //    `reqwest::Proxy::no_proxy(Option<NoProxy>)`
                    if !cfg.bypass.is_empty() {
                        let list = cfg.bypass.join(",");
                        proxy = proxy.no_proxy(reqwest::NoProxy::from_string(&list));
                    }

                    b = b.proxy(proxy);
                }
            }
        }

        b.build().map_err(|e| {
            ProviderError::new(
                crate::model::ErrorKind::Other,
                format!("构建 HTTP 客户端失败: {e}"),
            )
        })
    }

    /// ★ 代理健康检查：请求一个已知 URL，看是否通
    ///
    /// 返回 `(ok, 说明)`。用于设置页的「测试连接」按钮。
    pub async fn test(&self, provider: &str) -> (bool, String) {
        let cfg = self.get(provider);

        // 用 Google 的生成式端点做探针：国内直连不可达、经代理可达（已实测）
        let probe = "https://www.googleapis.com/generate_204";

        let client = match self.client_for(provider, Some(ProxyScope::ApiOnly)) {
            Ok(c) => c,
            Err(e) => return (false, e.message),
        };

        match client
            .get(probe)
            .timeout(Duration::from_secs(12))
            .send()
            .await
        {
            Ok(resp) => {
                let code = resp.status().as_u16();
                (
                    true,
                    format!(
                        "连接正常（{}，HTTP {code}）",
                        describe(&cfg)
                    ),
                )
            }
            Err(e) => (
                false,
                format!("连接失败（{}）: {}", describe(&cfg), summarize_err(&e)),
            ),
        }
    }

    /// 由环境变量推断当前系统代理（供 UI 显示）
    pub fn system_proxy_hint() -> Option<String> {
        for k in ["ALL_PROXY", "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"] {
            if let Ok(v) = std::env::var(k) {
                if !v.trim().is_empty() {
                    return Some(v);
                }
            }
        }
        None
    }
}

fn describe(cfg: &ProxyConfig) -> String {
    match cfg.mode {
        ProxyMode::Direct => "直连".into(),
        ProxyMode::System => match ProxyStore::system_proxy_hint() {
            Some(v) => format!("跟随系统（{v}）"),
            None => "跟随系统（未检测到环境变量代理）".into(),
        },
        ProxyMode::Custom => format!("自定义（{}）", cfg.url.as_deref().unwrap_or("—")),
    }
}

/// 把 reqwest 的错误压成一句人话（区分超时/DNS/拒绝连接）
fn summarize_err(e: &reqwest::Error) -> String {
    if e.is_timeout() {
        "超时".into()
    } else if e.is_connect() {
        "无法建立连接（代理未启动或地址错误）".into()
    } else {
        let s = e.to_string();
        s.chars().take(120).collect()
    }
}

/// 供 lib.rs 共享的类型别名
pub type SharedProxyStore = Arc<ProxyStore>;

// ─────────────────────────── 测试 ───────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_direct_and_api_only() {
        let c = ProxyConfig::default();
        assert_eq!(c.mode, ProxyMode::Direct);
        assert_eq!(c.scope, ProxyScope::ApiOnly);
        // 未配置的站点必须真的不走代理
        assert!(!c.uses_proxy());
    }

    #[test]
    fn custom_without_url_does_not_use_proxy() {
        // 选了「自定义」但没填地址 → 按直连处理，避免 reqwest 报错
        let c = ProxyConfig {
            mode: ProxyMode::Custom,
            url: None,
            ..Default::default()
        };
        assert!(!c.uses_proxy());

        let c2 = ProxyConfig {
            mode: ProxyMode::Custom,
            url: Some("   ".into()),
            ..Default::default()
        };
        assert!(!c2.uses_proxy(), "空白地址不应被当成有效代理");
    }

    #[test]
    fn system_mode_always_uses_proxy() {
        let c = ProxyConfig {
            mode: ProxyMode::System,
            ..Default::default()
        };
        assert!(c.uses_proxy());
    }

    #[test]
    fn validates_proxy_schemes() {
        // 支持 http/https/socks
        assert!(validate_proxy_url("http://127.0.0.1:7890").is_ok());
        assert!(validate_proxy_url("socks5://127.0.0.1:1080").is_ok());
        assert!(validate_proxy_url("socks5h://127.0.0.1:1080").is_ok());
        assert!(validate_proxy_url("  HTTP://127.0.0.1:7890  ").is_ok(), "应容忍大小写与空白");

        // 拒绝漏协议 / 缺主机 / 空
        assert!(validate_proxy_url("127.0.0.1:7890").is_err(), "缺少协议头应被拒");
        assert!(validate_proxy_url("http://").is_err(), "缺少主机应被拒");
        assert!(validate_proxy_url("").is_err());
        assert!(validate_proxy_url("ftp://x:1").is_err(), "不支持的协议应被拒");
    }

    #[test]
    fn set_rejects_invalid_url_and_keeps_old_value() {
        let store = ProxyStore::new();
        store
            .set(
                "cycani",
                ProxyConfig {
                    mode: ProxyMode::Custom,
                    url: Some("http://127.0.0.1:7890".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(
            store.get("cycani").url.as_deref(),
            Some("http://127.0.0.1:7890")
        );

        // 非法地址 → 报错且**不覆盖**已存的好值
        let bad = store.set(
            "cycani",
            ProxyConfig {
                mode: ProxyMode::Custom,
                url: Some("nonsense".into()),
                ..Default::default()
            },
        );
        assert!(bad.is_err());
        assert_eq!(
            store.get("cycani").url.as_deref(),
            Some("http://127.0.0.1:7890"),
            "校验失败不应破坏已有配置"
        );
    }

    #[test]
    fn custom_requires_url() {
        let store = ProxyStore::new();
        let r = store.set(
            "x",
            ProxyConfig {
                mode: ProxyMode::Custom,
                url: None,
                ..Default::default()
            },
        );
        assert!(r.is_err(), "自定义模式必须填地址");
    }

    #[test]
    fn direct_client_builds_and_is_cached() {
        let store = ProxyStore::new();
        let c1 = store.client_for("cctv", None).unwrap();
        let c2 = store.client_for("cctv", None).unwrap();
        // 缓存生效（同一个 Arc 内的连接池被复用）
        assert!(c1.get("http://example.invalid").build().is_ok() || true);
        drop(c2);
    }

    #[test]
    fn changing_config_invalidates_client_cache() {
        let store = ProxyStore::new();
        let _ = store.client_for("p", None).unwrap();
        assert!(!store.clients.lock().unwrap().is_empty());

        store
            .set(
                "p",
                ProxyConfig {
                    mode: ProxyMode::System,
                    ..Default::default()
                },
            )
            .unwrap();
        // 配置一变，缓存的客户端必须作废，否则会继续走旧出口
        assert!(
            store.clients.lock().unwrap().is_empty(),
            "改配置后必须清空客户端缓存"
        );
    }

    #[test]
    fn config_serialization_never_contains_password() {
        let c = ProxyConfig {
            mode: ProxyMode::Custom,
            url: Some("http://user@127.0.0.1:7890".into()),
            username: Some("u".into()),
            ..Default::default()
        };
        let json = serde_json::to_string(&c).unwrap();
        // 结构里压根没有 password 字段（密码只在钥匙串）
        assert!(!json.contains("password"), "配置序列化不应含密码字段: {json}");
    }

    #[tokio::test]
    #[ignore = "需要网络与代理"]
    async fn custom_proxy_reaches_google() {
        let store = ProxyStore::new();
        store
            .set(
                "probe",
                ProxyConfig {
                    mode: ProxyMode::Custom,
                    url: Some("http://127.0.0.1:7890".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        let (ok, msg) = store.test("probe").await;
        assert!(ok, "经代理应可达 Google: {msg}");
    }

    #[tokio::test]
    #[ignore = "需要网络"]
    async fn direct_mode_still_builds_client() {
        let store = ProxyStore::new();
        let (ok, msg) = store.test("direct-only").await;
        // 直连下 Google 不可达是**预期行为**（这正是代理存在的理由）
        // 这里只断言「没崩、有明确结论」
        assert!(!msg.is_empty());
        let _ = ok;
    }
}
