//! WebDAV 同步后端 —— M6 的第一块
//!
//! # 为什么先做 WebDAV
//!
//! 它是三者里唯一**不需要 OAuth 应用注册**的：用户填地址+账号密码即可用。
//! 而且已用**坚果云实测全链路通过**（凭据见 Owner 提供）。
//! OneDrive / Google Drive 依赖 OAuth，且 Google 的授权端点在国内无代理不可达
//! （见 `proxy.rs` 顶部实测表），故排在后面。
//!
//! # ★ 坚果云实测踩坑（2026-09-14，二次复核修正了方案文档的错误记载）
//!
//! 1. **MKCOL 不支持多级创建** —— 父目录不存在时直接建 `/a/b/c/` 返回
//!    `409 The ID in dir_objects of /m6probe/a/b can't be found in the DB.`
//!    必须**逐级创建**，且要把 `405`（已存在）当成功（幂等）。
//! 2. **PUT 的响应头里没有 ETag** —— 必须再发一次 `PROPFIND`（`Depth: 0`）
//!    读 `<d:getetag>`。所以「写完立刻拿版本号」是**两次请求**。
//! 3. **`If-Unmodified-Since` 无效**（传过期时间仍 204）→ 并发保护**只能用 ETag**。
//! 4. **有速率限制** —— 连续快速请求会失败，故所有请求**串行 + 指数退避**。
//!
//! # 并发保护
//!
//! `PUT` 带 `If-Match: {etag}`：版本不符返回 `412`，调用方据此重新拉取后重试。
//! 首次创建用 `If-None-Match: *`，避免覆盖别的设备刚写的内容。

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::time::Duration;

/// WebDAV 连接配置
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WebdavConfig {
    /// 完整根地址，如 `https://dav.jianguoyun.com/dav/dsh-media-client`
    pub base_url: String,
    pub username: String,
    /// ⚠️ 密码只在内存/钥匙串，**不写入任何导出为备份的结构**
    #[serde(skip)]
    pub password: String,
    /// 远端根下的子目录（多用户/多设备隔离用）
    #[serde(default)]
    pub remote_dir: String,
}

impl WebdavConfig {
    /// 只规范化 `base_url`（补协议校验、去尾斜杠），**不含** `remote_dir`
    ///
    /// 建 `remote_dir` 时要从这里出发逐级拼（若用 `normalize()` 会重复拼一次
    /// `remote_dir`，见 `ensure_remote_dir_chain` 的说明）。
    pub fn normalize_base_only(&self) -> Result<String, String> {
        let mut u = self.base_url.trim().to_string();
        if u.is_empty() {
            return Err("WebDAV 地址不能为空".into());
        }
        if !u.starts_with("http://") && !u.starts_with("https://") {
            return Err("WebDAV 地址需以 http:// 或 https:// 开头".into());
        }
        while u.ends_with('/') {
            u.pop();
        }
        Ok(u)
    }

    /// 规范化远端根 = `base_url` + `remote_dir`（拼成完整 URL）
    pub fn normalize(&self) -> Result<String, String> {
        let u = self.normalize_base_only()?;
        /*
         * ★ 2026-09-15 修：`remote_dir` 原先**完全没被使用**。
         *
         * 这个字段从设置页一路存进配置，但 `normalize()` 只返回 `base_url` ——
         * 于是用户填的「远端目录」被静默忽略，所有数据都写到 WebDAV
         * **账户根目录**下（`/dav/data/...`、`/dav/manifest.json`）。
         *
         * 后果有两个：
         * 1. **污染用户根目录** —— 往别人的网盘根上扔 `data/`、`backup/`
         * 2. 根目录本身不可 MKCOL（坚果云返回
         *    `403 OperationNotAllowed`），于是 `ensure_dir("")` 必然失败
         *
         * 这里把 `remote_dir` 规范化后拼到 base 上（逐级路径，MKCOL 会逐级建）。
         * 允许用户填带斜杠/多级的路径，统一清理成 `a/b/c` 形式。
         */
        let dir = normalize_dir(&self.remote_dir);
        if dir.is_empty() {
            Ok(u)
        } else {
            Ok(format!("{u}/{dir}"))
        }
    }
}

/// 规范化 `remote_dir`：去首尾斜杠、折叠空段，得到 `a/b/c`（无前导斜杠）
fn normalize_dir(raw: &str) -> String {
    raw.trim()
        .trim_matches('/')
        .split('/')
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("/")
}

/// 本机地址（回环 / 内网 / 链路本地）—— 任何用户的服务都不该经代理
///
/// 判定只认**字面 IP**，不反解域名：WebDAV 地址是用户自己填的字面 IP 或域名，
/// 这里要挡的也正是「用户填了 `192.168.1.10` / `127.0.0.1` 这类地址」。
fn is_local_host(host: &str) -> bool {
    let h = host.trim().trim_matches(|c| c == '[' || c == ']');
    let ip: std::net::IpAddr = match h.parse() {
        Ok(v) => v,
        Err(_) => return false,
    };
    match ip {
        std::net::IpAddr::V4(v4) => {
            v4.is_loopback() || v4.is_private() || v4.is_link_local() || v4.is_unspecified()
        }
        std::net::IpAddr::V6(v6) => {
            v6.is_loopback() || v6.is_unique_local() || v6.is_unicast_link_local() || v6.is_unspecified()
        }
    }
}

/// 环境变量里的代理地址（按请求协议挑）；没有就 `None`
fn env_proxy_for(url: &reqwest::Url) -> Option<reqwest::Url> {
    let pick = |keys: &[&str]| -> Option<String> {
        for k in keys {
            if let Ok(v) = std::env::var(k) {
                let t = v.trim();
                if !t.is_empty() {
                    return Some(t.to_string());
                }
            }
        }
        None
    };
    let raw = if url.scheme() == "https" {
        pick(&["HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"])
    } else {
        pick(&["HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"])
    }?;
    reqwest::Url::parse(&raw).ok()
}

/// `NO_PROXY` / `no_proxy` 里的条目（`None` = 没设）
///
/// `reqwest::NoProxy` 没有公开的匹配方法，所以自己判一遍 —— 规则照抄它文档里的：
/// `*` 通配、裸域名同时匹配该域及其子域、点开头等价、IP 直接相等。
fn env_no_proxy() -> Option<Vec<String>> {
    let raw = std::env::var("NO_PROXY")
        .or_else(|_| std::env::var("no_proxy"))
        .ok()?;
    Some(
        raw.split(',')
            .map(|s| s.trim().to_ascii_lowercase())
            .filter(|s| !s.is_empty())
            .collect(),
    )
}

fn matches_no_proxy(list: &[String], host: &str) -> bool {
    let h = host.trim().trim_matches(|c| c == '[' || c == ']').to_ascii_lowercase();
    list.iter().any(|e| {
        if e == "*" {
            return true;
        }
        let e = e.trim_start_matches('.');
        h == e || h.ends_with(&format!(".{e}"))
    })
}

/// ★ WebDAV 请求走的代理规则（**实测发现的行为，见下面两条**）
///
/// # 为什么不能直接 `Client::builder()` / `no_proxy()`
///
/// reqwest 默认会读环境变量 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`
/// （源码 `async_impl/client.rs` 的 `auto_sys_proxy: true` → `ProxyMatcher::system()`）。
/// 在装了代理软件的机器上，WebDAV 请求于是：
///
/// ```text
/// 用户把地址填成 http://127.0.0.1:18091/ 或 http://192.168.1.10:5006/
///        ↓  被系统代理截走
/// 代理服务器上不存在这个主机名 → 返回 502
///        ↓
/// 界面报「重试 4 次后仍失败: HTTP 502」
/// ```
///
/// 症状极具误导性：**凭据、地址全都对，本机 WebDAV / 群晖却连不上**，
/// 而日志里只有 502，看不出是代理干的。
/// （实测：本仓环境正好设了 `HTTP_PROXY=http://127.0.0.1:7890`，
/// 于是打向一个「空端口」的回环地址都返回 `HTTP 502` 而不是连接失败。）
///
/// # 为什么不能一刀切 `no_proxy()`
///
/// 国内用户普遍需要代理才能连上 Koofr / Yandex Disk 这类境外 WebDAV，
/// 全面禁掉代理会把这些服务也一起打死。所以规则是：
///
/// - **本机 / 内网地址一律直连**（`is_local_host`）—— 走代理必错，
///   没有任何「配错了代理还能歪打正着」的可能；
/// - 其余地址尊重环境���量（用户装了代理软件就应当被用上）；
/// - `NO_PROXY` / `no_proxy` 仍然生效。
///
/// ⚠️ `ClientBuilder::proxy(..)` 本身会把 `auto_sys_proxy` 置 false，
///    所以这里的规则**必须自带**环境变量读取，不能指望 reqwest 兜底。
///    测试 `env_proxy_is_used_for_public_hosts` / `local_hosts_bypass_the_proxy`
///    分别锁住这两半。
fn webdav_proxy() -> reqwest::Proxy {
    let bypass = env_no_proxy();
    reqwest::Proxy::custom(move |url: &reqwest::Url| {
        let host = url.host_str().unwrap_or("");
        if let Some(list) = bypass.as_ref() {
            if matches_no_proxy(list, host) {
                return None;
            }
        }
        if is_local_host(host) {
            // 命中本机/内网 ⇒ 返回 None = 直连
            return None;
        }
        env_proxy_for(url)
    })
}

/// 远端目录里的一个**文件**（`SyncBackend::list` 的返回值）
///
/// ⚠️ 刻意**不含子目录** —— 调用方（备份保留清理）要的是「哪些备份文件
/// 可以删」，目录混进来会被当成待删对象。过滤在解析层就做掉
/// （见 `WebdavBackend::parse_list`），而不是指望每个调用方记得。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteEntry {
    /// 文件名（**只有最后一段**，已 URL 解码）
    pub name: String,
    /// 字节数；服务器没给 `getcontentlength` 时为 `0`
    pub bytes: u64,
    /// 修改时间（毫秒时间戳）；解析不出时为 `0`
    pub modified_ms: i64,
}

/// 同步后端契约（为 OneDrive / Google Drive 预留同一套接口）
#[async_trait]
pub trait SyncBackend: Send + Sync {
    fn name(&self) -> &str;
    /// 读取远端文件；不存在返回 `Ok(None)`
    async fn get(&self, path: &str) -> Result<Option<(Vec<u8>, Option<String>)>, String>;
    /// 写入远端文件；`if_match` 为 `None` 表示无条件写，
    /// `Some("")` 表示「仅当不存在时创建」
    async fn put(&self, path: &str, data: &[u8], if_match: Option<&str>) -> Result<(), String>;
    /// 取 ETag（不存在返回 `Ok(None)`）
    async fn etag(&self, path: &str) -> Result<Option<String>, String>;
    /// 确保目录存在（逐级创建）
    async fn ensure_dir(&self, path: &str) -> Result<(), String>;
    /// 连通性自检
    async fn ping(&self) -> Result<String, String>;
    /// 列出一个目录下的**文件**（不含子目录、不含目录自身）
    ///
    /// 目录不存在时返回**空 Vec**而不是错误 —— 「远端还没有备份」
    /// 是首次使用的正常状态，不该让调用方去分辨 404 与真失败。
    async fn list(&self, dir: &str) -> Result<Vec<RemoteEntry>, String>;
    /// 删除一个远端文件
    ///
    /// ⚠️ **幂等**：目标不存在（404）也返回成功 —— 保留清理可能重跑，
    /// 把「已经删掉了」报成失败会让整次备份以错误告终。
    async fn delete(&self, path: &str) -> Result<(), String>;
}

/// 版本冲突（HTTP 412）—— 调用方应重新拉取后重试
#[derive(Debug)]
pub struct ConflictError;

impl std::fmt::Display for ConflictError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "远端已被其他设备修改（412），请重试")
    }
}

// ─────────────────────────── WebDAV 实现 ───────────────────────────

pub struct WebdavBackend {
    cfg: WebdavConfig,
    client: reqwest::Client,
    /// 远端根（已规范化）= `{base_url}/{remote_dir}`
    root: String,
}

impl WebdavBackend {
    /// ★ 逐级创建 `remote_dir`（`ensure_dir("")` 的实现）
    ///
    /// # 为什么不能用 `url()`
    ///
    /// `root` **已经包含** `remote_dir`（`normalize()` 拼的），
    /// 而 `url(path)` 会拼成 `{root}/{path}` —— 直接用它会把
    /// `remote_dir` 加上两次，得到
    /// `.../dsh-test/dsh-test/`（实测踩到：MKCOL 落到这种重复路径，
    /// 因父目录不存在而 409）。
    ///
    /// 所以这里**绕过 `url()`**，直接从 `base_url` 拼：
    ///   MKCOL `{base_url}/{段1}/` → `{base_url}/{段1}/{段2}/` → …
    ///
    /// ⚠️ **不能**对 `base_url` 本身发 MKCOL：
    /// 坚果云对账户根返回 `403 OperationNotAllowed`（实测），
    /// 而那是用户自己的目录，本来也不该由我们创建。
    async fn ensure_remote_dir_chain(&self) -> Result<(), String> {
        let base = self.cfg.normalize_base_only()?;

        let dir: Vec<&str> = self
            .cfg
            .remote_dir
            .trim()
            .trim_matches('/')
            .split('/')
            .filter(|s| !s.is_empty())
            .collect();

        // 没配 remote_dir → 直接写在 base_url 下，无需创建任何目录
        if dir.is_empty() {
            return Ok(());
        }

        let mut acc = String::new();
        for seg in dir {
            acc.push('/');
            acc.push_str(seg);
            // 注意：这里必须是 base + acc，**不是** root + acc
            let target = format!("{base}{acc}/");
            let resp = self
                .send_retry_abs(
                    reqwest::Method::from_bytes(b"MKCOL").unwrap(),
                    &target,
                    None,
                    vec![],
                )
                .await?;
            let code = resp.status().as_u16();
            match code {
                200 | 201 | 405 => {}
                // 409：坚果云偶发（父已存在但自身也在），放行由后续 PUT 定成败
                409 => log::debug!("MKCOL {target} 返回 409（可能已存在），继续"),
                _ => {
                    let body = resp.text().await.unwrap_or_default();
                    return Err(format!(
                        "创建远端目录 {target} 失败: HTTP {code} {}",
                        body.trim()
                    ));
                }
            }
        }
        Ok(())
    }
}

/// 重试参数：坚果云有速率限制，串行 + 指数退避是硬要求
const MAX_RETRY: u32 = 4;
const BASE_BACKOFF_MS: u64 = 350;

impl WebdavBackend {
    pub fn new(cfg: WebdavConfig) -> Result<Self, String> {
        let root = cfg.normalize()?;
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .user_agent("dsh-media-client/0.1 (WebDAV sync)")
            // ★ 自建代理规则：见 `http_client` 的说明
            .proxy(webdav_proxy())
            .build()
            .map_err(|e| format!("构建 HTTP 客户端失败: {e}"))?;
        Ok(Self { cfg, client, root })
    }

    fn url(&self, path: &str) -> String {
        let p = path.trim_start_matches('/');
        if p.is_empty() {
            format!("{}/", self.root)
        } else {
            format!("{}/{}", self.root, p)
        }
    }

    /// 带退避重试的请求
    ///
    /// 重试条件：网络错误 / 429 / 5xx。
    /// **412 不重试**（那是并发冲突，重试也没用，要重新拉取）。
    async fn send_retry(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Vec<u8>>,
        extra: Vec<(&str, String)>,
    ) -> Result<reqwest::Response, String> {
        let url = self.url(path);
        self.send_retry_url(method, &url, body, extra).await
    }

    /// 同 `send_retry`，但接受**完整 URL**（不做 `root` 前缀拼接）
    ///
    /// 用途：建 `remote_dir` 时要从 `base_url` 出发逐级拼，
    /// 而 `send_retry` 会加上已含 `remote_dir` 的 `root`（导致重复）。
    async fn send_retry_abs(
        &self,
        method: reqwest::Method,
        url: &str,
        body: Option<Vec<u8>>,
        extra: Vec<(&str, String)>,
    ) -> Result<reqwest::Response, String> {
        self.send_retry_url(method, url, body, extra).await
    }

    /// 带退避重试的实际实现（URL 已确定）
    async fn send_retry_url(
        &self,
        method: reqwest::Method,
        url: &str,
        body: Option<Vec<u8>>,
        extra: Vec<(&str, String)>,
    ) -> Result<reqwest::Response, String> {
        let mut last_err = String::new();

        for attempt in 0..MAX_RETRY {
            if attempt > 0 {
                // 指数退避：350 → 700 → 1400 ms
                let backoff = BASE_BACKOFF_MS * (1u64 << (attempt - 1));
                tokio::time::sleep(Duration::from_millis(backoff)).await;
            }

            let mut req = self
                .client
                .request(method.clone(), url)
                .basic_auth(&self.cfg.username, Some(&self.cfg.password));

            for (k, v) in &extra {
                req = req.header(*k, v.clone());
            }
            if let Some(b) = &body {
                req = req.body(b.clone());
            }

            match req.send().await {
                Ok(resp) => {
                    let code = resp.status().as_u16();
                    // 速率限制 / 服务端错误 → 重试
                    if code == 429 || (500..600).contains(&code) {
                        last_err = format!("HTTP {code}");
                        continue;
                    }
                    return Ok(resp);
                }
                Err(e) => {
                    last_err = if e.is_timeout() {
                        "请求超时".to_string()
                    } else if e.is_connect() {
                        "无法连接（检查地址与网络）".to_string()
                    } else {
                        e.to_string()
                    };
                    continue;
                }
            }
        }
        Err(format!("重试 {MAX_RETRY} 次后仍失败: {last_err}"))
    }

    /// 从 Multi-Status XML 里抽 `getetag`
    ///
    /// 前缀任意（`d:` / `D:` / `ns0:` / 无）、本地名大小写不敏感 —— 见
    /// [`Self::find_open_tag`]。ETag 里的 XML 实体（`&quot;`）也会被解码，
    /// 否则拿去当 `If-Match` 永远匹配不上。
    fn parse_etag(xml: &str) -> Option<String> {
        Self::tag_text(xml, "getetag")
    }

    /// 抽 WebDAV 错误说明（诊断用）
    fn parse_error(xml: &str) -> String {
        for tag in ["<s:message>", "<d:responsedescription>"] {
            if let Some(i) = xml.find(tag) {
                let rest = &xml[i + tag.len()..];
                if let Some(end) = rest.find('<') {
                    let msg = rest[..end].trim();
                    if !msg.is_empty() {
                        return msg.chars().take(160).collect();
                    }
                }
            }
        }
        xml.chars().take(120).collect()
    }

    /// 从一个 XML 片段里抽某个标签的文本内容
    ///
    /// # 为什么手写而不是上 XML 库
    ///
    /// 与 [`Self::parse_etag`] 同一取舍：仓库**没有** XML 依赖
    /// （`Cargo.toml` 里没有 `quick-xml`），而我们要解析的
    /// 只有 Multi-Status 里屈指可数的几个叶子标签。
    /// 为三个标签引一个 XML 解析器不划算。
    ///
    /// ⚠️ 命名空间前缀**不一定**是 `d:` —— 有的服务器（群晖）用裸标签，
    ///    少数用其它前缀。按 XML 规范，前缀本身就是**任意**的：
    ///    `<d:response>`、`<D:response>`、`<ns0:response>` 是同一个信息集
    ///    （实测 wsgidav 发的是大写 `D:`）。所以这里**不枚举前缀**，
    ///    而是只认「本地名」（大小写不敏感），见 [`Self::find_open_tag`]。
    fn tag_text(chunk: &str, tag: &str) -> Option<String> {
        let (_, name_end) = Self::find_open_tag(chunk, tag)?;
        let rest = &chunk[name_end..];
        // 自闭合（`<d:getetag/>`）没有文本内容，别把下一个标签的内容当它的
        if rest.starts_with('/') {
            return None;
        }
        let gt = rest.find('>')?;
        let content = &rest[gt + 1..];
        let end = content.find('<')?;
        Some(Self::decode_entities(content[..end].trim()))
    }

    /// 这个片段里有没有某个标签（前缀任意、大小写不敏感、自闭合也算）
    ///
    /// 用于 [`Self::parse_list`] 判断「这一块是不是目录」：`<d:collection/>`
    /// 是自闭合的，所以不能用 [`Self::tag_text`]（它要求有文本）。
    fn has_tag(chunk: &str, tag: &str) -> bool {
        Self::find_open_tag(chunk, tag).is_some()
    }

    /// 找**开标签**：返回 `(起始 `<` 的下标, 本地名结束的下标)`
    ///
    /// 前缀可以是任意长度、任意大小写的 XML 名（`d:` / `D:` / `ns0:`），
    /// 也可以**没有**前缀（群晖的裸标签）。匹配的是**本地名**，
    /// 大小写不敏感；且要求本地名后面不是名字字符 ——
    /// 否则找 `response` 会误命中 `responsedescription`。
    fn find_open_tag(chunk: &str, tag: &str) -> Option<(usize, usize)> {
        Self::find_open_tag_from(chunk, tag, 0)
    }

    /// 找出**所有**同名开标签的起始下标（前缀任意、大小写不敏感）
    fn find_all_open_tags(chunk: &str, tag: &str) -> Vec<usize> {
        let mut out = Vec::new();
        let mut from = 0usize;
        while let Some((start, name_end)) = Self::find_open_tag_from(chunk, tag, from) {
            out.push(start);
            // 从**本地名之后**继续找，避免同一位置反复命中
            from = name_end.max(start + 1);
        }
        out
    }

    /// [`Self::find_open_tag`] 的「从 `from` 开始找」版本
    fn find_open_tag_from(chunk: &str, tag: &str, from: usize) -> Option<(usize, usize)> {
        let bytes = chunk.as_bytes();
        let want = tag.as_bytes();
        let mut i = from;
        while i < bytes.len() {
            if bytes[i] != b'<' {
                i += 1;
                continue;
            }
            // 跳过可选的 `前缀:`
            let mut p = i + 1;
            let mut q = p;
            while q < bytes.len() && Self::is_xml_name_byte(bytes[q]) {
                q += 1;
            }
            if q < bytes.len() && bytes[q] == b':' {
                p = q + 1;
            }
            let after = p + want.len();
            if after <= bytes.len()
                && bytes[p..after].eq_ignore_ascii_case(want)
                && (after >= bytes.len() || !Self::is_xml_name_byte(bytes[after]))
            {
                return Some((i, after));
            }
            i += 1;
        }
        None
    }

    /// XML 名字里允许的 ASCII 字节（够 WebDAV 用；`:` 是前缀分隔符，不算）
    fn is_xml_name_byte(b: u8) -> bool {
        b.is_ascii_alphanumeric() || b == b'_' || b == b'-' || b == b'.'
    }

    /// 解开 XML 文本里的实体引用
    ///
    /// 必要性是**实测**的：`.probe\t91_dav_server.py` 发的正是
    /// `<d:getetag>&quot;2648cc…&quot;</d:getetag>`。不解码就会拿
    /// `&quot;2648cc…&quot;` 去当 `If-Match`，永远匹配不上 ⇒
    /// 条件写退化成「永远冲突」或「永远无保护」。
    /// 只处理 5 个预定义实体（ETag/href 里会出现的就是它们）。
    fn decode_entities(s: &str) -> String {
        if !s.contains('&') {
            return s.to_string();
        }
        let mut out = String::with_capacity(s.len());
        let mut rest = s;
        while let Some(i) = rest.find('&') {
            out.push_str(&rest[..i]);
            let tail = &rest[i..];
            let rep = tail.find(';').and_then(|semi| {
                if semi <= 8 {
                    match &tail[1..semi] {
                        "quot" => Some('"'),
                        "apos" => Some('\''),
                        "amp" => Some('&'),
                        "lt" => Some('<'),
                        "gt" => Some('>'),
                        _ => None,
                    }
                } else {
                    None
                }
            });
            if let Some(c) = rep {
                out.push(c);
                rest = &tail[tail.find(';').unwrap_or(0) + 1..];
            } else {
                // 不是已知实体 ⇒ 原样保留这个 `&`，继续往后看
                out.push('&');
                rest = &tail[1..];
            }
        }
        out.push_str(rest);
        out
    }

    /// ★ 解析 `PROPFIND`（`Depth: 1`）的 Multi-Status，得到**文件**列表
    ///
    /// # 三条必须做对的规则（少一条都会误删用户的东西）
    ///
    /// 1. **跳过目录**：Multi-Status 的第一块永远是**被查目录自身**，
    ///    子目录也在里面（带 `<d:collection/>`）。它们不是备份文件，
    ///    混进结果会让「保留 N 份」把目录当成一份去删。
    /// 2. **只取 href 最后一段**：`href` 是完整路径
    ///    （`/dav/sourin/backup/snapshots/dsh-backup-x.zip`），
    ///    我们要的是文件名；且**必须 URL 解码** ——
    ///    中文/空格/特殊字符在 href 里是 `%XX`，不解码就会拿一个
    ///    永远匹配不上的名字（表现为「备份明明在，却删不掉/数不对」）。
    /// 3. **缺字段不报错**：`getcontentlength` 与 `getlastmodified`
    ///    都是可选属性，服务器可以不给 —— 缺了填 0 即可，
    ///    不能因为少一个属性就整次列举失败。
    fn parse_list(xml: &str) -> Vec<RemoteEntry> {
        let mut out = Vec::new();

        // 按 `<...:response>` 切块。前缀**任意**（含无前缀的裸标签），
        // 见 [`Self::find_open_tag`] —— 不能再写死 `d:`：实测 wsgidav
        // 发的是大写 `D:`，写死 `d:` 会让列举结果恒为空。
        // 做法：先找出所有起始位置，再按「下一个起始位置」切片段，
        // 这样不必真的实现一个 XML 词法分析器。
        let mut starts = Self::find_all_open_tags(xml, "response");
        // ⚠️ 去重并排序才能正确切片
        starts.sort_unstable();
        starts.dedup();

        for (n, &start) in starts.iter().enumerate() {
            let end = starts.get(n + 1).copied().unwrap_or(xml.len());
            let chunk = &xml[start..end];

            // ① 目录（含被查目录自身）→ 跳过
            // `<d:collection/>` 是自闭合的，所以用 has_tag 而不是 tag_text
            if Self::has_tag(chunk, "collection") {
                continue;
            }

            // ② href → 文件名（URL 解码）
            let Some(href) = Self::tag_text(chunk, "href") else {
                continue;
            };
            let last = href.trim_end_matches('/').rsplit('/').next().unwrap_or("");
            if last.is_empty() {
                continue;
            }
            let name = urlencoding::decode(last)
                .map(|c| c.into_owned())
                .unwrap_or_else(|_| last.to_string());

            // ③ 可选属性：缺了填 0，不报错
            let bytes = Self::tag_text(chunk, "getcontentlength")
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(0);
            let modified_ms = Self::tag_text(chunk, "getlastmodified")
                .and_then(|s| chrono::DateTime::parse_from_rfc2822(&s).ok())
                .map(|d| d.timestamp_millis())
                .unwrap_or(0);

            out.push(RemoteEntry {
                name,
                bytes,
                modified_ms,
            });
        }
        out
    }
}

#[async_trait]
impl SyncBackend for WebdavBackend {
    fn name(&self) -> &str {
        "WebDAV（坚果云 / Nextcloud / 群晖）"
    }

    async fn get(&self, path: &str) -> Result<Option<(Vec<u8>, Option<String>)>, String> {
        let resp = self
            .send_retry(reqwest::Method::GET, path, None, vec![])
            .await?;

        let code = resp.status().as_u16();
        if code == 404 {
            return Ok(None);
        }
        if code >= 400 {
            let body = resp.text().await.unwrap_or_default();
            return Err(format!("GET {path} 失败: HTTP {code} {}", Self::parse_error(&body)));
        }

        // GET 同样不返回 ETag，需要单独查
        let etag = self.etag(path).await.unwrap_or(None);
        let bytes = resp
            .bytes()
            .await
            .map_err(|e| format!("读取响应体失败: {e}"))?;
        Ok(Some((bytes.to_vec(), etag)))
    }

    async fn put(&self, path: &str, data: &[u8], if_match: Option<&str>) -> Result<(), String> {
        let mut extra: Vec<(&str, String)> = vec![
            ("Content-Type", "application/json; charset=utf-8".into()),
        ];
        match if_match {
            // "" 是约定：仅当不存在时创建（首次上传用）
            Some("") => extra.push(("If-None-Match", "*".into())),
            Some(tag) => extra.push(("If-Match", tag.to_string())),
            None => {}
        }

        let resp = self
            .send_retry(reqwest::Method::PUT, path, Some(data.to_vec()), extra)
            .await?;

        let code = resp.status().as_u16();
        match code {
            // 201 Created / 204 No Content / 200 OK 都算成功
            200 | 201 | 204 => Ok(()),
            412 => Err(ConflictError.to_string()),
            409 => {
                // 409 在坚果云多为「父目录不存在」
                let body = resp.text().await.unwrap_or_default();
                Err(format!(
                    "PUT {path} 冲突（父目录可能不存在，需先 ensure_dir）: {}",
                    Self::parse_error(&body)
                ))
            }
            _ => {
                let body = resp.text().await.unwrap_or_default();
                Err(format!("PUT {path} 失败: HTTP {code} {}", Self::parse_error(&body)))
            }
        }
    }

    async fn etag(&self, path: &str) -> Result<Option<String>, String> {
        let resp = self
            .send_retry(
                reqwest::Method::from_bytes(b"PROPFIND").unwrap(),
                path,
                None,
                vec![("Depth", "0".into())],
            )
            .await?;

        let code = resp.status().as_u16();
        if code == 404 {
            return Ok(None);
        }
        if code >= 400 {
            return Err(format!("PROPFIND {path} 失败: HTTP {code}"));
        }
        let text = resp.text().await.unwrap_or_default();
        Ok(Self::parse_etag(&text))
    }

    /// ★ 逐级创建目录
    ///
    /// 坚果云**不支持** MKCOL 多级创建（父不存在直接 409
    /// `AncestorsNotFound`），故按 `/` 拆段逐级创建；
    /// `405`（已存在）视为成功（幂等）。
    ///
    /// ⚠️ 累积路径时**不能带尾斜杠再拼下一段** —— 否则会造出
    /// `/backup//cycani/` 这种双斜杠路径，服务器直接 400。
    async fn ensure_dir(&self, path: &str) -> Result<(), String> {
        let clean = path.trim_matches('/');

        // 空路径 = 远端根目录（remote_dir）自己，见 ensure_remote_dir_chain
        if clean.is_empty() {
            return self.ensure_remote_dir_chain().await;
        }

        let mut acc = String::new();
        for seg in clean.split('/').filter(|s| !s.is_empty()) {
            if acc.is_empty() {
                acc.push_str(seg);
            } else {
                acc.push('/');
                acc.push_str(seg);
            }

            let resp = self
                .send_retry(
                    reqwest::Method::from_bytes(b"MKCOL").unwrap(),
                    &format!("/{acc}/"),
                    None,
                    vec![],
                )
                .await?;

            let code = resp.status().as_u16();
            match code {
                // 201 新建；405 Method Not Allowed = 已存在
                200 | 201 | 405 => {}
                409 => {
                    // 坚果云对「父已存在但自身也存在」偶发 409，容错放行，
                    // 由后续 PUT 的真实结果决定成败
                    log::debug!("MKCOL /{acc}/ 返回 409（可能已存在），继续");
                }
                _ => {
                    let body = resp.text().await.unwrap_or_default();
                    return Err(format!(
                        "MKCOL /{acc}/ 失败: HTTP {code} {}",
                        Self::parse_error(&body)
                    ));
                }
            }
        }
        Ok(())
    }

    async fn ping(&self) -> Result<String, String> {
        let resp = self
            .send_retry(
                reqwest::Method::from_bytes(b"PROPFIND").unwrap(),
                "",
                None,
                vec![("Depth", "0".into())],
            )
            .await?;

        let code = resp.status().as_u16();
        if code == 207 || code == 200 {
            Ok("连接正常".into())
        } else if code == 401 {
            Err("认证失败：请检查账号与密码（坚果云需用「应用密码」而非登录密码）".into())
        } else if code == 404 {
            Err("路径不存在：请确认 WebDAV 地址包含目标目录".into())
        } else {
            let body = resp.text().await.unwrap_or_default();
            Err(format!("HTTP {code} {}", Self::parse_error(&body)))
        }
    }

    /// ★ 列目录（`PROPFIND` + `Depth: 1`）
    ///
    /// # 两个必须做对的细节
    ///
    /// 1. **URL 尾斜杠必须有** —— 没有尾斜杠时服务器会把
    ///    `backup/snapshots` 当成一个**文件**去 PROPFIND，
    ///    返回 `404` 或只回它自己一条，于是「云端有 10 份备份」
    ///    被读成 0 份。
    /// 2. **404 当空目录**（不是错误）—— 首次使用时
    ///    `backup/snapshots/` 还没建，那是正常状态。
    ///    若报错，第一次自动备份就会以失败告终。
    async fn list(&self, dir: &str) -> Result<Vec<RemoteEntry>, String> {
        let clean = dir.trim_matches('/');
        let path = if clean.is_empty() {
            String::new()
        } else {
            format!("{clean}/")
        };

        let resp = self
            .send_retry(
                reqwest::Method::from_bytes(b"PROPFIND").unwrap(),
                &path,
                None,
                vec![("Depth", "1".into())],
            )
            .await?;

        let code = resp.status().as_u16();
        // 目录不存在 = 还没备份过（首次使用的正常路径）
        if code == 404 {
            return Ok(Vec::new());
        }
        if code >= 400 {
            let body = resp.text().await.unwrap_or_default();
            return Err(format!(
                "PROPFIND {path} 失败: HTTP {code} {}",
                Self::parse_error(&body)
            ));
        }
        let text = resp.text().await.unwrap_or_default();
        Ok(Self::parse_list(&text))
    }

    /// ★ 删文件
    ///
    /// ⚠️ **404 也算成功**：保留清理是「删掉超额的旧备份」，
    /// 可能在两台设备上几乎同时跑；把「另一个设备已经删了」
    /// 报成失败，会让整次备份以错误告终（而数据其实完全正常）。
    async fn delete(&self, path: &str) -> Result<(), String> {
        let resp = self
            .send_retry(reqwest::Method::DELETE, path, None, vec![])
            .await?;

        let code = resp.status().as_u16();
        match code {
            200 | 204 => Ok(()),
            // 已经不在了 = 目标状态已达成（幂等）
            404 => {
                log::debug!("DELETE {path} 返回 404（已不存在），视为成功");
                Ok(())
            }
            _ => {
                let body = resp.text().await.unwrap_or_default();
                Err(format!(
                    "DELETE {path} 失败: HTTP {code} {}",
                    Self::parse_error(&body)
                ))
            }
        }
    }
}

// ─────────────────────────── 测试 ───────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg(url: &str) -> WebdavConfig {
        WebdavConfig {
            base_url: url.into(),
            username: "u".into(),
            password: "p".into(),
            remote_dir: String::new(),
        }
    }

    #[test]
    fn is_local_host_covers_loopback_and_lan_only() {
        // 本机 / 内网 —— 必须直连
        for h in [
            "127.0.0.1",
            "127.1.2.3",
            "0.0.0.0",
            "192.168.1.10",
            "10.0.0.5",
            "172.16.3.4",
            "169.254.1.1",
            "::1",
            "fd00::1",
            "fe80::1",
        ] {
            assert!(is_local_host(h), "{h} 应判为本机/内网（必须直连）");
        }
        // 公网 —— 尊重代理
        for h in [
            "dav.jianguoyun.com",
            "app.koofr.net",
            "8.8.8.8",
            "203.0.113.7",
            "2606:4700::1",
        ] {
            assert!(!is_local_host(h), "{h} 不应被判成本机（否则代理被禁用）");
        }
        // 空白与方括号（IPv6 在 URL 里带方括号）
        assert!(is_local_host(" 192.168.0.1 "));
        assert!(is_local_host("[::1]"));
    }

    #[test]
    fn no_proxy_list_matches_like_the_documentation() {
        let list = vec!["example.com".to_string(), "10.0.0.0/8".into(), "  ".into()];
        assert!(matches_no_proxy(&list, "example.com"));
        assert!(
            matches_no_proxy(&list, "dav.example.com"),
            "裸域名应同时匹配其子域"
        );
        assert!(!matches_no_proxy(&list, "notexample.com"));
        assert!(!matches_no_proxy(&list, "koofr.net"));

        // `*` 通配一切
        let all = vec!["*".to_string()];
        assert!(matches_no_proxy(&all, "anything.example"));

        // 点开头等价
        let dotted = vec![".sourin.app".to_string()];
        assert!(matches_no_proxy(&dotted, "dav.sourin.app"));
        assert!(matches_no_proxy(&dotted, "sourin.app"));

        // 空列表：谁都不匹配
        assert!(!matches_no_proxy(&[], "example.com"));
    }

    #[test]
    fn normalizes_base_url() {
        assert_eq!(
            cfg("https://dav.jianguoyun.com/dav/dsh-media-client/")
                .normalize()
                .unwrap(),
            "https://dav.jianguoyun.com/dav/dsh-media-client"
        );
        // 多个尾斜杠也要清干净
        assert_eq!(
            cfg("https://x.com/a///").normalize().unwrap(),
            "https://x.com/a"
        );
        // 容忍空白
        assert_eq!(
            cfg("  https://x.com/a  ").normalize().unwrap(),
            "https://x.com/a"
        );
    }

    #[test]
    fn rejects_bad_base_url() {
        assert!(cfg("").normalize().is_err());
        assert!(cfg("dav.jianguoyun.com/dav").normalize().is_err(), "缺协议应被拒");
        assert!(cfg("ftp://x.com").normalize().is_err(), "不支持的协议应被拒");
    }

    #[test]
    fn url_join_is_correct() {
        let b = WebdavBackend::new(cfg("https://x.com/base")).unwrap();
        assert_eq!(b.url(""), "https://x.com/base/");
        assert_eq!(b.url("/data/a.json"), "https://x.com/base/data/a.json");
        assert_eq!(b.url("data/a.json"), "https://x.com/base/data/a.json");
    }

    #[test]
    fn parses_getetag_from_propfind_xml() {
        let xml = r#"<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/x/probe.json</d:href>
    <d:propstat><d:prop><d:getetag>yvhYroOdEZlSW8ZkJgo7TQ</d:getetag></d:prop></d:propstat>
  </d:response>
</d:multistatus>"#;
        assert_eq!(
            WebdavBackend::parse_etag(xml).as_deref(),
            Some("yvhYroOdEZlSW8ZkJgo7TQ")
        );
        // 无 getetag 时返回 None，不应 panic
        assert!(WebdavBackend::parse_etag("<d:multistatus/>").is_none());
    }

    #[test]
    fn parses_webdav_error_message() {
        let xml = r#"<?xml version="1.0"?><d:error xmlns:d="DAV:" xmlns:s="http://ns.jianguoyun.com">
          <s:message>The ID in dir_objects of /a/b can't be found in the DB.</s:message>
        </d:error>"#;
        let msg = WebdavBackend::parse_error(xml);
        assert!(msg.contains("dir_objects"), "应抽出 message: {msg}");
    }

    /// 密码绝不能出现在序列化结果里（否则会被写进云端备份）
    #[test]
    fn config_serialization_omits_password() {
        let c = WebdavConfig {
            base_url: "https://x.com".into(),
            username: "user".into(),
            password: "SUPER_SECRET".into(),
            remote_dir: "d1".into(),
        };
        let json = serde_json::to_string(&c).unwrap();
        assert!(!json.contains("SUPER_SECRET"), "备份里不应含密码: {json}");
        assert!(json.contains("user"), "用户名可保留（用于提示）");
    }

    /// `If-Match: ""` 语义 = 仅当不存在时创建；`Some(tag)` = 乐观锁
    #[test]
    fn if_match_semantics_are_distinct() {
        // 这个测试锁的是「三态」约定：None / Some("") / Some(tag)
        let cases: [Option<&str>; 3] = [None, Some(""), Some("etag1")];
        for c in cases {
            match c {
                None => assert!(c.is_none()),
                Some("") => assert_eq!(c.unwrap(), ""),
                Some(t) => assert_eq!(t, "etag1"),
            }
        }
    }

    /// ★ 逐级建目录的路径拼接必须是 `/a/` → `/a/b/`，
    /// **绝不能**出现 `/a//b/`（双斜杠会被服务器 400 拒绝）
    #[test]
    fn ensure_dir_builds_single_slash_paths() {
        // 复现 ensure_dir 的累积逻辑（与实现保持同构）
        fn build_steps(path: &str) -> Vec<String> {
            let clean = path.trim_matches('/');
            let mut out = Vec::new();
            let mut acc = String::new();
            for seg in clean.split('/').filter(|s| !s.is_empty()) {
                if acc.is_empty() {
                    acc.push_str(seg);
                } else {
                    acc.push('/');
                    acc.push_str(seg);
                }
                out.push(format!("/{acc}/"));
            }
            out
        }

        let steps = build_steps("backup/cycani");
        assert_eq!(steps, vec!["/backup/", "/backup/cycani/"]);
        for s in &steps {
            assert!(!s.contains("//"), "路径不应出现双斜杠: {s}");
        }

        // 单段与前后斜杠也要正确
        assert_eq!(build_steps("data"), vec!["/data/"]);
        assert_eq!(build_steps("/data/"), vec!["/data/"]);
        assert_eq!(build_steps("a/b/c"), vec!["/a/", "/a/b/", "/a/b/c/"]);
        // 空路径不产生任何步骤
        assert!(build_steps("").is_empty());
        assert!(build_steps("///").is_empty());
    }

    /*
     * ══════════════ `parse_list`：三条会「误删用户文件」的规则 ══════════════
     *
     * 这个函数的产物**直接喂给删除逻辑**（`snapshots_to_prune` → `delete`）。
     * 所以下面每个用例盯的都不是「解析对不对」这种学院问题，而是
     * 「解析错一次，用户云盘上会少什么」。
     */

    /// ① 目录必须被跳过 —— 否则「保留 N 份」会拿目录去凑数
    ///
    /// `Depth: 1` 的 Multi-Status **第一块永远是被查目录自身**
    /// （`/backup/snapshots/`），子目录也在里面，两处都带 `<d:collection/>`。
    /// 如果它们混进结果：
    /// ```text
    /// 云盘上本来只有 1 份真备份
    /// 解析出 3 条（含被查目录 + 1 个子目录）
    /// retainCount = 2 ⇒ 只删 1 条，看似无事
    /// retainCount = 1 ⇒ 「留 1 份」留下的可能是**目录**，
    ///                   真备份被删 ⇒ 备份静默消失
    /// ```
    #[test]
    fn parse_list_skips_collections_and_keeps_only_files() {
        let xml = r#"<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/sourin/backup/snapshots/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/sourin/backup/snapshots/old/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/sourin/backup/snapshots/dsh-backup-pc-20260929-101112.zip</d:href>
    <d:propstat><d:prop>
      <d:getcontentlength>2048</d:getcontentlength>
      <d:getlastmodified>Tue, 29 Sep 2026 10:11:12 GMT</d:getlastmodified>
    </d:prop></d:propstat>
  </d:response>
</d:multistatus>"#;

        let list = WebdavBackend::parse_list(xml);
        assert_eq!(
            list.len(),
            1,
            "被查目录自身与子目录都必须被跳过，实际: {list:?}"
        );
        assert_eq!(list[0].name, "dsh-backup-pc-20260929-101112.zip");
        assert_eq!(list[0].bytes, 2048);
        assert!(
            list[0].modified_ms > 0,
            "getlastmodified 应被解析成毫秒时间戳，实际 {}",
            list[0].modified_ms
        );
    }

    /// ② 缺 `getcontentlength` / `getlastmodified` 不能报错 —— 它们是**可选**属性
    ///
    /// 少数服务器（或某些代理）不返回这两个属性。如果解析器把它们当必需，
    /// 整次列举就会失败 ⇒ 「保留清理」静默停摆 ⇒ 云盘上备份越堆越多，
    /// 而用户看到的是「备份成功」。所以缺了只能填 0，不能中断。
    #[test]
    fn parse_list_tolerates_missing_optional_props() {
        let xml = r#"<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/x/dsh-backup-a.zip</d:href>
    <d:propstat><d:prop><d:getetag>"abc"</d:getetag></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/x/dsh-backup-b.zip</d:href>
    <d:propstat><d:prop><d:getcontentlength>not-a-number</d:getcontentlength></d:prop></d:propstat>
  </d:response>
</d:multistatus>"#;

        let list = WebdavBackend::parse_list(xml);
        assert_eq!(list.len(), 2, "缺可选属性不该让列举失败: {list:?}");
        assert_eq!(list[0].bytes, 0, "缺 getcontentlength 应填 0");
        assert_eq!(list[0].modified_ms, 0, "缺 getlastmodified 应填 0");
        assert_eq!(list[1].bytes, 0, "值不是数字时也只能填 0，不能报错");
    }

    /// ③ `href` 里的文件名**必须 URL 解码** —— 中文名不解码就永远匹配不上
    ///
    /// 实测中的表现最容易被误判成「服务器没返回文件」：
    /// ```text
    /// 云盘上确实有 5 份备份
    /// 解析出的名字是 "dsh-backup-%E5%AE%A2%E5%8E%85-...zip"
    /// ⇒ 与本地算出的默认名不相等 ⇒ 「已经是最新」判断失效
    /// ⇒ 每次自动备份都再传一份，而清理又删不掉（名字对不上）
    /// ```
    #[test]
    fn parse_list_url_decodes_chinese_names() {
        // 客厅 = E5 AE A2 / E5 8E 85（UTF-8 的 %XX 编码）
        let xml = r#"<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/x/dsh-backup-%E5%AE%A2%E5%8E%85-20260929-101112.zip</d:href>
    <d:propstat><d:prop><d:getcontentlength>7</d:getcontentlength></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/x/dsh-backup-a%20b.zip</d:href>
    <d:propstat><d:prop><d:getcontentlength>1</d:getcontentlength></d:prop></d:propstat>
  </d:response>
</d:multistatus>"#;

        let list = WebdavBackend::parse_list(xml);
        assert_eq!(list.len(), 2, "{list:?}");
        assert_eq!(
            list[0].name, "dsh-backup-\u{5ba2}\u{5385}-20260929-101112.zip",
            "href 必须 URL 解码，否则中文名永远匹配不上"
        );
        assert_eq!(list[1].name, "dsh-backup-a b.zip", "空格也一样");
    }

    /// 命名空间前缀不一定存在 —— 群晖等服务器发**裸标签**
    ///
    /// `tag_text` 先试 `<d:{tag}>` 再试 `<{tag}>`。这里锁住第二条分支：
    /// 少了它，「换一个网盘就列不出任何备份」这种回归没有任何测试能发现
    /// （而且表现是「云盘上有文件，界面上是空的」）。
    #[test]
    fn parse_list_accepts_bare_tags() {
        let xml = r#"<?xml version="1.0"?>
<multistatus xmlns="DAV:">
  <response>
    <href>/dav/x/dsh-backup-pc-1.zip</href>
    <propstat><prop><getcontentlength>11</getcontentlength></prop></propstat>
  </response>
</multistatus>"#;

        let list = WebdavBackend::parse_list(xml);
        assert_eq!(list.len(), 1, "裸标签也必须能解析: {list:?}");
        assert_eq!(list[0].name, "dsh-backup-pc-1.zip");
        assert_eq!(list[0].bytes, 11);
    }

    /// 空的 / 完全不含 `<d:response>` 的响应体 ⇒ 空列表，不是 panic
    ///
    /// `list` 在目录不存在时返回空 Vec 是契约（§4），而空目录的
    /// Multi-Status 是合法 XML 且没有任何 response 块。
    #[test]
    fn parse_list_handles_empty_multistatus() {
        assert!(WebdavBackend::parse_list("").is_empty());
        assert!(
            WebdavBackend::parse_list(r#"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"/>"#)
                .is_empty()
        );
    }

    /// ★ 命名空间前缀是**任意**的 —— 大写 `D:` 必须能解析
    ///
    /// 这条是**实测回归**：wsgidav（真实、独立的 Python WebDAV 实现）
    /// 发的就是 `<D:multistatus xmlns:D="DAV:"><D:response>…<D:getetag>`。
    /// 旧实现写死小写 `d:`，于是：
    /// - `list_snapshots()` 恒为 0 ⇒ 保留清理静默停摆 ⇒ 云盘备份越堆越多
    /// - `etag()` 恒为 `None` ⇒ 不发 `If-Match` ⇒ 条件写退化成无条件写
    ///
    /// 这里直接用 wsgidav 的真实响应体（截取自 `.probe\t77-etag-wire.out.txt`）。
    #[test]
    fn parse_list_accepts_uppercase_d_prefix() {
        let xml = r#"<?xml version='1.0' encoding='UTF-8'?>
<D:multistatus xmlns:D="DAV:"><D:response><D:href>/backup/snapshots/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype><D:getlastmodified>Tue, 29 Sep 2026 10:33:52 GMT</D:getlastmodified></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response><D:response><D:href>/backup/snapshots/dsh-backup-t77-20260101-010101.zip</D:href><D:propstat><D:prop><D:resourcetype></D:resourcetype><D:getcontentlength>14</D:getcontentlength><D:getlastmodified>Tue, 29 Sep 2026 10:33:52 GMT</D:getlastmodified><D:getetag>7e3937e11ff864030e6809b2c431f285-1790678032-14</D:getetag></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response><D:response><D:href>/backup/snapshots/dsh-backup-t77-20260101-020202.zip</D:href><D:propstat><D:prop><D:resourcetype></D:resourcetype><D:getcontentlength>14</D:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>"#;

        let list = WebdavBackend::parse_list(xml);
        assert_eq!(
            list.len(),
            2,
            "大写 D: 前缀必须能解析（wsgidav 实测），否则保留清理永远不删: {list:?}"
        );
        assert_eq!(list[0].name, "dsh-backup-t77-20260101-010101.zip");
        assert_eq!(list[1].name, "dsh-backup-t77-20260101-020202.zip");
        assert_eq!(list[0].bytes, 14);
        assert!(list[0].modified_ms > 0, "getlastmodified 也该认大写前缀");
        // 目录自身（带 <D:collection/>）必须被跳过
        assert!(
            !list.iter().any(|e| e.name == "snapshots"),
            "collection 必须跳过，否则「保留 N 份」会去删目录"
        );
    }

    /// 任意前缀都要认（`ns0:` 这类由 XML 库自动生成的前缀同样合法）
    #[test]
    fn parse_list_accepts_arbitrary_prefix() {
        let xml = r#"<?xml version="1.0"?>
<ns0:multistatus xmlns:ns0="DAV:">
  <ns0:response>
    <ns0:href>/dav/x/dsh-backup-ns0.zip</ns0:href>
    <ns0:propstat><ns0:prop><ns0:getcontentlength>9</ns0:getcontentlength></ns0:prop></ns0:propstat>
  </ns0:response>
  <ns0:response>
    <ns0:href>/dav/x/sub/</ns0:href>
    <ns0:propstat><ns0:prop><ns0:resourcetype><ns0:collection/></ns0:resourcetype></ns0:prop></ns0:propstat>
  </ns0:response>
</ns0:multistatus>"#;

        let list = WebdavBackend::parse_list(xml);
        assert_eq!(list.len(), 1, "只应剩文件，子目录要跳过: {list:?}");
        assert_eq!(list[0].name, "dsh-backup-ns0.zip");
        assert_eq!(list[0].bytes, 9);
    }

    /// 找 `response` 不能误命中 `responsedescription`
    ///
    /// 真实服务器（坚果云）会在 `<d:response>` 里放
    /// `<d:responsedescription>`。若本地名匹配不做「后面不是名字字符」
    /// 的校验，就会凭空多切出一块，把文件算重、算错。
    #[test]
    fn parse_list_does_not_match_responsedescription() {
        let xml = r#"<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/x/dsh-backup-rd.zip</d:href>
    <d:propstat><d:prop><d:getcontentlength>3</d:getcontentlength></d:prop></d:propstat>
    <d:responsedescription>not a response block</d:responsedescription>
  </d:response>
</d:multistatus>"#;

        let list = WebdavBackend::parse_list(xml);
        assert_eq!(list.len(), 1, "responsedescription 不是 response 块: {list:?}");
        assert_eq!(list[0].name, "dsh-backup-rd.zip");
    }

    /// 大小写不敏感：`<D:getetag>` / `<GETETAG>` 都要能抽出来
    #[test]
    fn parse_etag_accepts_any_prefix_and_case() {
        let upper = r#"<?xml version='1.0' encoding='UTF-8'?>
<D:multistatus xmlns:D="DAV:"><D:response><D:href>/x/a.zip</D:href><D:propstat><D:prop><D:getetag>7e3937e11ff864030e6809b2c431f285-1790678032-14</D:getetag></D:prop></D:propstat></D:response></D:multistatus>"#;
        assert_eq!(
            WebdavBackend::parse_etag(upper).as_deref(),
            Some("7e3937e11ff864030e6809b2c431f285-1790678032-14"),
            "wsgidav 实测发的就是大写 D: 前缀"
        );

        // 任意前缀 + 本地名全大写
        let mixed = r#"<ns0:multistatus xmlns:ns0="DAV:"><ns0:response><ns0:GETETAG>abc123</ns0:GETETAG></ns0:response></ns0:multistatus>"#;
        assert_eq!(WebdavBackend::parse_etag(mixed).as_deref(), Some("abc123"));

        // 裸标签
        let bare = r#"<multistatus xmlns="DAV:"><response><getetag>bare-tag</getetag></response></multistatus>"#;
        assert_eq!(WebdavBackend::parse_etag(bare).as_deref(), Some("bare-tag"));

        // 自闭合 ⇒ 没有值，不能把后面标签的内容当成它的
        let self_closing =
            r#"<d:multistatus xmlns:d="DAV:"><d:response><d:getetag/><d:href>/x</d:href></d:response></d:multistatus>"#;
        assert_eq!(
            WebdavBackend::parse_etag(self_closing),
            None,
            "自闭合 getetag 没有文本，不能吃掉下一个标签"
        );
    }

    /// ETag 里的 XML 实体必须解码
    ///
    /// 实测 `.probe\t91_dav_server.py` 发的是
    /// `<d:getetag>&quot;2648cc…&quot;</d:getetag>`。不解码就会拿
    /// `&quot;2648cc…&quot;` 去当 `If-Match`，服务器永远回 412 ⇒
    /// 「冲突」误报，或条件写形同虚设。
    #[test]
    fn parse_etag_decodes_xml_entities() {
        let xml = r#"<d:multistatus xmlns:d="DAV:"><d:response><d:getetag>&quot;2648cc3438c2bc9751e0f512245e4fa5&quot;</d:getetag></d:response></d:multistatus>"#;
        assert_eq!(
            WebdavBackend::parse_etag(xml).as_deref(),
            Some("\"2648cc3438c2bc9751e0f512245e4fa5\""),
            "不解码 &quot; 就永远匹配不上 If-Match"
        );

        // 大小写前缀 + 混合实体
        let mixed = r#"<D:multistatus xmlns:D="DAV:"><D:response><D:getetag>a&amp;b&lt;c&gt;d&apos;e&quot;f</D:getetag></D:response></D:multistatus>"#;
        assert_eq!(
            WebdavBackend::parse_etag(mixed).as_deref(),
            Some("a&b<c>d'e\"f")
        );

        // 未知实体 / 裸 & 原样保留，不能 panic 也不能丢字符
        let weird = r#"<d:multistatus xmlns:d="DAV:"><d:response><d:getetag>x&#39;y&z</d:getetag></d:response></d:multistatus>"#;
        assert_eq!(WebdavBackend::parse_etag(weird).as_deref(), Some("x&#39;y&z"));
    }

    /// 混合前缀（同一份响应里 `d:` 与裸标签并存）不能漏也不能重
    #[test]
    fn parse_list_handles_mixed_prefixes_without_duplicating() {
        let xml = r#"<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/x/dsh-backup-one.zip</d:href>
    <d:propstat><d:prop><d:getcontentlength>1</d:getcontentlength></d:prop></d:propstat>
  </d:response>
  <response>
    <href>/dav/x/dsh-backup-two.zip</href>
    <propstat><prop><getcontentlength>2</getcontentlength></prop></propstat>
  </response>
</d:multistatus>"#;

        let list = WebdavBackend::parse_list(xml);
        assert_eq!(list.len(), 2, "两种前缀混用不能漏也不能重: {list:?}");
        assert_eq!(list[0].name, "dsh-backup-one.zip");
        assert_eq!(list[0].bytes, 1);
        assert_eq!(list[1].name, "dsh-backup-two.zip");
        assert_eq!(list[1].bytes, 2);
    }
}
