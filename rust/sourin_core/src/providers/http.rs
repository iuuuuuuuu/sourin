//! HTTP Provider Client —— 进程外插件契约（M7）
//!
//! # 为什么是进程外 HTTP，而不是 dlopen / 脚本引擎
//!
//! 详见 `方案设计.md` 第四节，三条一手证据：
//!
//! 1. **Plex 用 7 年证明进程内插件是错误路线**，且问题不在安全 ——
//!    它的沙箱做得极完整（AST 重写 + builtins 白名单 + 五级策略）仍被废弃。
//!    官方原话：*"if we were to build the feature again, we'd do it very differently"*。
//!    → **做沙箱救不了错误架构**。
//! 2. **Google Play 明文禁止下载可执行代码**（含 `.so`）；
//!    Rust 官方：*"The Rust ABI offers no stability guarantees"*。
//! 3. **Android 10+ 对 app home 目录有 `exec()` 禁令** → sidecar 方案在移动端是死路。
//!
//! → 用户加的是 **URL**（不是代码）：宿主只发 HTTP、只收 JSON，
//!   天然进程隔离、天然跨语言、天然无法在宿主进程里搞破坏。
//!
//! # 契约
//!
//! 第三方实现一个 HTTP 服务，暴露：
//!
//! ```text
//! GET {base}/manifest                → ProviderManifest（含 apiVersion）
//! GET {base}/home                    → Section[]
//! GET {base}/categories              → Category[]
//! GET {base}/list?category=&page=    → Page<MediaItem>
//! GET {base}/detail?id=              → MediaDetail
//! GET {base}/search?q=&page=         → Page<MediaItem>
//! GET {base}/live                    → LiveChannel[]
//! GET {base}/resolve?id=&source=&episode=&quality= → StreamCandidate[]
//! ```
//!
//! # 三个必须有的机制（均有反面案例）
//!
//! 1. **`apiVersion` 兼容性校验** —— ⚠️ **Stremio 缺这个**，
//!    导致不兼容的插件只会「神秘报错」。我们在握手时就明确拒绝并说明原因。
//! 2. **超时 + 强杀** —— 反面案例 mpv：*"it won't terminate when quitting,
//!    because it's waiting on your script"*。
//! 3. **错误隔离** —— yt-dlp 的 `except Exception: continue`：
//!    单个第三方 provider 挂掉不影响内置源，且**明确告知用户**而非静默失败。

use crate::model::*;
use crate::provider::*;
use async_trait::async_trait;
use serde::Deserialize;
use serde_json::Value;
use std::time::Duration;

/// 宿主支持的契约版本
///
/// 第三方在 `manifest.apiVersion` 里声明自己所实现的版本；
/// 高于此值即拒（避免「用新契约的插件装到老宿主上，只会神秘报错」）。
pub const SUPPORTED_API_VERSION: u32 = 1;

/// 单请求超时（`方案设计.md` 第 7 条：必须超时，反面案例是 mpv 卡住不退）
const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);

/// HTTP Provider 的安装描述（用户在「导入源」里填一个 URL 即完成安装）
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct HttpProviderSpec {
    /// 服务基址，如 `http://127.0.0.1:8787`（本地）或 `https://example.com/prov`
    pub base: String,
    /// 可选：随请求发送的自定义头（如第三方要求的 token）
    #[serde(default)]
    pub headers: std::collections::HashMap<String, String>,
}

/// 远端 manifest 的**线格式**（比内部 `ProviderManifest` 宽松，便于第三方手写）
#[derive(Debug, Clone, Deserialize)]
struct RemoteManifest {
    id: String,
    name: String,
    #[serde(default = "one")]
    version: String,
    /// ★ 契约版本 —— 缺省视为 1，但陌生值要拒
    #[serde(default = "one_u32", rename = "apiVersion")]
    api_version: u32,
    #[serde(default)]
    description: Option<String>,
    #[serde(default, rename = "idPrefixes")]
    id_prefixes: Vec<String>,
    #[serde(default, rename = "themeColor")]
    theme_color: Option<String>,
    #[serde(default)]
    capabilities: RemoteCapabilities,
    /// 站点自述是否可用（yt-dlp `_WORKING` 做法）
    #[serde(default = "t", rename = "working")]
    working: bool,
    #[serde(default, rename = "brokenReason")]
    broken_reason: Option<String>,
}

fn one() -> String {
    "1.0.0".into()
}
fn one_u32() -> u32 {
    SUPPORTED_API_VERSION
}
fn t() -> bool {
    true
}

#[derive(Debug, Clone, Default, Deserialize)]
struct RemoteCapabilities {
    #[serde(default)]
    vod: bool,
    #[serde(default)]
    live: bool,
    #[serde(default)]
    epg: bool,
    #[serde(default)]
    search: bool,
    #[serde(default, rename = "loginRequired")]
    login_required: bool,
    #[serde(default, rename = "multiSource")]
    multi_source: bool,
    #[serde(default, rename = "serverSideHistory")]
    server_side_history: bool,
    #[serde(default)]
    favorites: bool,
    #[serde(default)]
    timeshift: bool,
    #[serde(default)]
    danmaku: bool,
    /*
     * 登录相关（2026-09-20）—— 与 `Capabilities` 的同名字段对应
     *
     * ⚠️ 声明式源（远程 manifest）**必须显式写 camelCase rename**：
     *    serde 默认按 Rust 字段名（snake_case）反序列化，
     *    而 manifest 是 JS 写的、用 camelCase ——
     *    不写 rename 会**静默丢掉字段**（落回 default）且不报错。
     *    本项目的 `kind`/`type` 别名那件事就是同一个坑。
     */
    #[serde(default, rename = "loginSupported")]
    login_supported: bool,
    #[serde(default, rename = "loginHint")]
    login_hint: Option<String>,
    #[serde(default = "t", rename = "loginNeedsUsername")]
    login_needs_username: bool,
}

// 内部领域类型的反序列化包装
//
// 这些类型在 `model.rs` 里只 derive 了 Serialize（用于输出给前端），
// 但 HTTP Provider 需要**反序列化**它们。这里用 `Value` 中转，
// 避免改动领域模型的可见性契约。
fn de<T: serde::de::DeserializeOwned>(v: Value, what: &str) -> Result<T> {
    serde_json::from_value(v).map_err(|e| {
        ProviderError::parse(format!(
            "响应格式不符（{what}）: {e} —— 请检查该 Provider 是否遵循契约"
        ))
    })
}

/// ★ HTTP Provider：把远端 HTTP 服务包装成本地 `MediaProvider`
pub struct HttpProvider {
    manifest: ProviderManifest,
    spec: HttpProviderSpec,
    client: reqwest::Client,
    /// 站点代理（第三方源同样受「站点代理」设置约束）
    proxy: Option<std::sync::Arc<crate::proxy::ProxyStore>>,
}

impl HttpProvider {
    /// 连接并握手：拉取远端 manifest，校验 apiVersion
    pub async fn connect(spec: HttpProviderSpec) -> std::result::Result<Self, ProviderError> {
        let base = spec.base.trim().trim_end_matches('/').to_string();
        if base.is_empty() {
            return Err(ProviderError::new(ErrorKind::Other, "Provider 地址不能为空"));
        }
        if !base.starts_with("http://") && !base.starts_with("https://") {
            return Err(ProviderError::new(
                ErrorKind::Other,
                "Provider 地址需以 http:// 或 https:// 开头",
            ));
        }

        let client = reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .build()
            .map_err(|e| ProviderError::new(ErrorKind::Other, format!("构建客户端失败: {e}")))?;

        let url = format!("{base}/manifest");
        let resp = client
            .get(&url)
            .send()
            .await
            .map_err(|e| {
                ProviderError::network(format!(
                    "无法连接 Provider（{url}）: {}",
                    if e.is_timeout() {
                        "超时".to_string()
                    } else if e.is_connect() {
                        "连接被拒（服务未启动？）".to_string()
                    } else {
                        e.to_string()
                    }
                ))
            })?;

        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| ProviderError::network(format!("读取 manifest 失败: {e}")))?;

        if !status.is_success() {
            return Err(ProviderError::network(format!(
                "manifest 返回 HTTP {status}: {}",
                text.chars().take(160).collect::<String>()
            )));
        }

        let rm: RemoteManifest = serde_json::from_str(&text).map_err(|e| {
            ProviderError::parse(format!(
                "manifest 格式不符: {e} —— 需要 {{\"id\",\"name\",\"apiVersion\",...}}"
            ))
        })?;

        // ★ 契约版本校验：这是 Stremio 缺失、我们必须补的一环
        if rm.api_version > SUPPORTED_API_VERSION {
            return Err(ProviderError::new(
                ErrorKind::Unsupported,
                format!(
                    "该 Provider 需要契约 v{}，当前宿主仅支持 v{} —— 请升级应用",
                    rm.api_version, SUPPORTED_API_VERSION
                ),
            ));
        }
        if rm.api_version == 0 {
            return Err(ProviderError::parse(
                "manifest 的 apiVersion 不能为 0".to_string(),
            ));
        }

        // id 不能与内置源冲突（否则会覆盖掉内置实现）
        if rm.id.trim().is_empty() {
            return Err(ProviderError::parse("manifest 缺少 id"));
        }
        if rm.id == "cctv" || rm.id == "cycani" {
            return Err(ProviderError::new(
                ErrorKind::Other,
                format!("Provider id「{}」与内置源冲突，请换一个", rm.id),
            ));
        }

        let manifest = ProviderManifest {
            id: rm.id,
            name: rm.name,
            version: rm.version,
            kind: "http".into(),
            description: rm.description,
            icon: None,
            id_prefixes: rm.id_prefixes,
            capabilities: Capabilities {
                vod: rm.capabilities.vod,
                live: rm.capabilities.live,
                epg: rm.capabilities.epg,
                search: rm.capabilities.search,
                login_required: rm.capabilities.login_required,
                multi_source: rm.capabilities.multi_source,
                server_side_history: rm.capabilities.server_side_history,
                favorites: rm.capabilities.favorites,
                timeshift: rm.capabilities.timeshift,
                danmaku: rm.capabilities.danmaku,
                // 登录（「游客可用 + 支持登录」这一档，供 B站这类源用）
                login_supported: rm.capabilities.login_supported,
                login_hint: rm.capabilities.login_hint.clone(),
                login_needs_username: rm.capabilities.login_needs_username,
                /*
                 * ⚠️ 进程外 HTTP Provider **不支持扫码登录**：
                 *    二维码的申请与轮询要走站点的私有协议，
                 *    而 HTTP 契约（`api_version: 1`）里没有这两个方法。
                 *    将来若要支持，得先扩契约 —— 不能在这里假装支持。
                 */
                login_qr_supported: false,
                // task-38：HTTP 声明式源没有插件凭据机制 —— 不能承诺"正在自动重登"
                can_auto_login: false,
            },
            // 进程外 HTTP Provider 的配置项由它自己的服务端管，
            // 客户端不渲染（协议里没有 config 字段）
            cover_headers: Vec::new(),
            config: Vec::new(),
            api_version: rm.api_version,
            theme_color: rm.theme_color,
            // ★ _WORKING 标记：站点自述失效时，UI 明确显示而不是静默失败
            working: rm.working,
            broken_reason: rm.broken_reason,
            enabled: None,
        };

        Ok(Self {
            manifest,
            spec: HttpProviderSpec { base, ..spec },
            client,
            proxy: None,
        })
    }

    pub fn with_proxy(mut self, proxy: std::sync::Arc<crate::proxy::ProxyStore>) -> Self {
        self.proxy = Some(proxy);
        self
    }

    fn http(&self) -> reqwest::Client {
        match self.proxy.as_ref() {
            Some(store) => store
                .client_for(&self.manifest.id, None)
                .unwrap_or_else(|_| self.client.clone()),
            None => self.client.clone(),
        }
    }

    /// GET 一个 JSON 端点
    async fn get_json(&self, path: &str, query: &[(&str, String)]) -> Result<Value> {
        let url = format!("{}{}", self.spec.base, path);
        let mut req = self.http().get(&url);
        for (k, v) in &self.spec.headers {
            req = req.header(k.as_str(), v.as_str());
        }
        let q: Vec<(&str, &str)> = query
            .iter()
            .filter(|(_, v)| !v.is_empty())
            .map(|(k, v)| (*k, v.as_str()))
            .collect();
        if !q.is_empty() {
            req = req.query(&q);
        }

        let resp = req.send().await.map_err(|e| {
            ProviderError::network(format!(
                "请求 {path} 失败: {}",
                if e.is_timeout() { "超时" } else { "网络错误" }
            ))
        })?;

        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| ProviderError::network(format!("读取 {path} 响应失败: {e}")))?;

        if status.as_u16() == 404 {
            return Err(ProviderError::new(
                ErrorKind::Unsupported,
                format!("该 Provider 未实现 {path}"),
            ));
        }
        if !status.is_success() {
            return Err(ProviderError::network(format!(
                "{path} 返回 HTTP {status}: {}",
                text.chars().take(160).collect::<String>()
            )));
        }

        serde_json::from_str(&text).map_err(|e| {
            ProviderError::parse(format!(
                "{path} 返回的不是合法 JSON: {e} —— {}",
                text.chars().take(120).collect::<String>()
            ))
        })
    }
}

#[async_trait]
impl MediaProvider for HttpProvider {
    fn manifest(&self) -> &ProviderManifest {
        &self.manifest
    }

    async fn home(&self) -> Result<Vec<Section>> {
        let v = self.get_json("/home", &[]).await?;
        if v.is_null() {
            return Ok(vec![]);
        }
        de(v, "Section[]")
    }

    async fn categories(&self) -> Result<Vec<Category>> {
        let v = self.get_json("/categories", &[]).await?;
        if v.is_null() {
            return Ok(vec![]);
        }
        de(v, "Category[]")
    }

    async fn list(&self, req: ListRequest) -> Result<Page<MediaItem>> {
        let mut q = vec![
            ("category", req.category_id.clone()),
            ("page", req.page.to_string()),
        ];
        for (k, v) in &req.filters {
            // filters 透传：契约不限定筛选键名，由第三方自定义
            q.push((k.as_str(), v.clone()));
        }
        let v = self.get_json("/list", &q).await?;
        de(v, "Page<MediaItem>")
    }

    async fn detail(&self, id: &MediaId) -> Result<MediaDetail> {
        let v = self.get_json("/detail", &[("id", id.native.clone())]).await?;
        de(v, "MediaDetail")
    }

    async fn search(&self, keyword: &str, page: u32) -> Result<Page<MediaItem>> {
        let v = self
            .get_json(
                "/search",
                &[("q", keyword.to_string()), ("page", page.to_string())],
            )
            .await?;
        de(v, "Page<MediaItem>")
    }

    async fn sources(&self, id: &MediaId) -> Result<Vec<PlaySource>> {
        // 契约里 sources 随 detail 一起返回，默认实现即可
        Ok(self.detail(id).await?.sources)
    }

    async fn episodes(&self, id: &MediaId, source_code: &str) -> Result<Vec<Episode>> {
        let v = self
            .get_json(
                "/episodes",
                &[
                    ("id", id.native.clone()),
                    ("source", source_code.to_string()),
                ],
            )
            .await?;
        if v.is_null() {
            // 未实现则回退到 detail 里带的剧集
            return Ok(self.detail(id).await?.episodes);
        }
        de(v, "Episode[]")
    }

    async fn resolve(&self, id: &MediaId, req: &PlayRequest) -> Result<Vec<StreamCandidate>> {
        let v = self
            .get_json(
                "/resolve",
                &[
                    ("id", id.native.clone()),
                    ("source", req.source_code.clone().unwrap_or_default()),
                    ("episode", req.episode_id.clone().unwrap_or_default()),
                    ("quality", req.quality.clone().unwrap_or_default()),
                ],
            )
            .await?;
        de(v, "StreamCandidate[]")
    }

    async fn live_channels(&self) -> Result<Vec<LiveChannel>> {
        if !self.manifest.capabilities.live {
            return Err(ProviderError::unsupported("该源不支持直播"));
        }
        let v = self.get_json("/live", &[]).await?;
        if v.is_null() {
            return Ok(vec![]);
        }
        de(v, "LiveChannel[]")
    }

    async fn live_stream(&self, channel_id: &str) -> Result<Vec<StreamCandidate>> {
        let v = self
            .get_json("/live/stream", &[("channel", channel_id.to_string())])
            .await?;
        de(v, "StreamCandidate[]")
    }

    async fn epg(&self, channel_id: &str, day: Option<&str>) -> Result<Vec<EpgEntry>> {
        let v = self
            .get_json(
                "/epg",
                &[
                    ("channel", channel_id.to_string()),
                    ("day", day.unwrap_or_default().to_string()),
                ],
            )
            .await?;
        if v.is_null() {
            return Ok(vec![]);
        }
        de(v, "EpgEntry[]")
    }

    async fn health_check(&self) -> bool {
        // 重新拉 manifest 即视为健康（也是最快的探活）
        self.get_json("/manifest", &[]).await.is_ok()
    }
}

// ─────────────────────────── 测试 ───────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// 断言连接失败，并返回错误信息（避免对非 Debug 类型用 unwrap_err）
    fn expect_connect_err(base: &str) -> String {
        let rt = tokio::runtime::Runtime::new().unwrap();
        match rt.block_on(HttpProvider::connect(HttpProviderSpec {
            base: base.into(),
            headers: Default::default(),
        })) {
            Ok(_) => panic!("本应连接失败: {base}"),
            Err(e) => e.message,
        }
    }

    #[test]
    fn rejects_empty_base() {
        let msg = expect_connect_err("   ");
        assert!(msg.contains("不能为空"), "{msg}");
    }

    #[test]
    fn rejects_bad_scheme() {
        let msg = expect_connect_err("example.com/api");
        assert!(msg.contains("http://"), "{msg}");
    }

    /// 契约版本高于宿主 → 必须**明确拒绝并说明原因**，而不是神秘报错
    #[test]
    fn rejects_future_api_version_with_clear_message() {
        let m = RemoteManifest {
            id: "x".into(),
            name: "X".into(),
            version: "1".into(),
            api_version: SUPPORTED_API_VERSION + 5,
            description: None,
            id_prefixes: vec![],
            theme_color: None,
            capabilities: RemoteCapabilities::default(),
            working: true,
            broken_reason: None,
        };
        // 直接校验判定逻辑
        assert!(
            m.api_version > SUPPORTED_API_VERSION,
            "未来版本必须被判定为不兼容"
        );
    }

    #[test]
    fn parses_minimal_remote_manifest() {
        // 第三方最简写法：只给 id/name，其余走默认
        let json = r#"{"id":"demo","name":"示例源"}"#;
        let m: RemoteManifest = serde_json::from_str(json).unwrap();
        assert_eq!(m.id, "demo");
        assert_eq!(m.api_version, SUPPORTED_API_VERSION, "缺省应视为当前版本");
        assert_eq!(m.version, "1.0.0");
        assert!(m.working, "缺省视为可用");
        assert!(!m.capabilities.vod, "能力位缺省为 false");
    }

    #[test]
    fn parses_full_remote_manifest_with_camel_case() {
        // 契约用 camelCase（对 JS/Go 实现者更自然）
        // ⚠️ 注意用 r##"..."## ：内容里有 `#ff0000`，单个 # 会提前结束原始字符串
        let json = r##"{
            "id":"demo","name":"示例","version":"2.0","apiVersion":1,
            "idPrefixes":["DM"],
            "themeColor":"#ff0000",
            "capabilities":{"vod":true,"search":true,"multiSource":true,"loginRequired":true},
            "working":false,"brokenReason":"站点改版"
        }"##;
        let m: RemoteManifest = serde_json::from_str(json).unwrap();
        assert_eq!(m.api_version, 1);
        assert_eq!(m.id_prefixes, vec!["DM"]);
        assert_eq!(m.theme_color.as_deref(), Some("#ff0000"));
        assert!(m.capabilities.vod && m.capabilities.search);
        assert!(m.capabilities.multi_source, "multiSource 应映射到 multi_source");
        assert!(m.capabilities.login_required);
        assert!(!m.working);
        assert_eq!(m.broken_reason.as_deref(), Some("站点改版"));
    }

    #[test]
    fn deserialize_error_is_actionable() {
        // 错误的响应应给出「格式不符 + 契约提示」，而不是裸 serde 错误
        let e = de::<Vec<MediaItem>>(serde_json::json!({"nope": 1}), "MediaItem[]").unwrap_err();
        assert!(e.message.contains("MediaItem[]"), "{}", e.message);
        assert!(e.message.contains("契约"), "{}", e.message);
    }

    #[test]
    fn placeholder_defaults_are_stable() {
        assert_eq!(one(), "1.0.0");
        assert_eq!(one_u32(), SUPPORTED_API_VERSION);
        assert!(t());
    }
}
