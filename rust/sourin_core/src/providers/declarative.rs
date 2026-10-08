//! 声明式 Provider —— 用户写一个 JSON 即可接入标准视频站，**零代码**
//!
//! # 适用场景
//!
//! 覆盖中文影视生态的绝大多数站点（苹果 CMS / MacCMS 系列），其接口是标准的：
//! ```text
//! GET {base}?ac=class                     → 分类列表
//! GET {base}?ac=videolist&t={cat}&pg={n}  → 分类内容
//! GET {base}?ac=detail&ids={id}           → 详情
//! GET {base}?wd={kw}&ac=videolist         → 搜索
//! ```
//!
//! # 设计依据
//!
//! - **借鉴 zyfun 的适配器模式**（8895★）：源用统一数据结构 + `type` 字段区分适配器
//! - **借鉴 Stremio 的字段设计**：`idPrefixes` / `proxyHeaders` / `notWebReady`
//! - **借鉴 Legado 的教训**：规则引擎必须**避免自研小语言失控**。Legado 的规则语法演化成
//!   6 种前缀 + 3 种组合符 + 6 种插值的自研语言，官方教程标题是《从入门到入土》，
//!   最终不得不加 `mainJs` 全代码逃生舱（其 `BookSource.kt` L99）。
//!   → 我们**只用 JSONPath**（成熟标准），不发明新语法。
//! - **必须支持「两级取值」**：央视就是「先取列表的 guid，再套 URL 模板」。
//!   故 `resolve` 支持 `from_list` + `url_template` 两阶段。

use crate::model::*;
use crate::provider::*;
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::time::Duration;

// ─────────────────────────── 描述文件格式 ───────────────────────────

/// 声明式 Provider 描述文件
///
/// 用户写这样一个 JSON 就能接入新站点。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeclarativeSpec {
    pub id: String,
    pub name: String,
    #[serde(default = "one")]
    pub version: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub icon: Option<String>,
    #[serde(default)]
    pub theme_color: Option<String>,

    /// API 基址
    pub base: String,

    /// 默认请求头（防盗链场景）
    #[serde(default)]
    pub headers: HashMap<String, String>,

    /// 自定义 UA
    #[serde(default)]
    pub user_agent: Option<String>,

    /// 该源处理的 ID 前缀
    #[serde(default)]
    pub id_prefixes: Vec<String>,

    #[serde(default)]
    pub capabilities: DeclarativeCapabilities,

    /// 各端点定义
    pub endpoints: Endpoints,
}

fn one() -> String {
    "1.0.0".into()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeclarativeCapabilities {
    /// 默认开启点播（声明式源绝大多数是点播站）
    #[serde(default = "t")]
    pub vod: bool,
    #[serde(default)]
    pub live: bool,
    #[serde(default)]
    pub search: bool,
    #[serde(default)]
    pub multi_source: bool,
}

impl Default for DeclarativeCapabilities {
    fn default() -> Self {
        Self {
            vod: true,
            live: false,
            search: false,
            multi_source: false,
        }
    }
}

fn t() -> bool {
    true
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Endpoints {
    /// 分类列表
    #[serde(default)]
    pub categories: Option<Endpoint>,
    /// 分类内容
    #[serde(default)]
    pub list: Option<Endpoint>,
    /// 详情
    #[serde(default)]
    pub detail: Option<Endpoint>,
    /// 搜索
    #[serde(default)]
    pub search: Option<Endpoint>,
    /// 取流
    #[serde(default)]
    pub resolve: Option<ResolveEndpoint>,
    /// 直播源（m3u）
    #[serde(default)]
    pub live: Option<Endpoint>,
}

/// 一个普通端点：路径 + 参数模板 + 字段映射
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Endpoint {
    /// 路径（可含 `{placeholder}`）
    #[serde(default)]
    pub path: String,
    /// 查询参数模板，如 `{"t": "{category}", "pg": "{page}"}`
    #[serde(default)]
    pub params: HashMap<String, String>,
    /// 字段映射：`{ 目标字段: JSONPath }`
    ///
    /// 目标字段见下方常量；JSONPath 用 `$.` 前缀。
    #[serde(default)]
    pub map: HashMap<String, String>,
    /// 请求方法，默认 GET
    #[serde(default)]
    pub method: Option<String>,
}

/// 取流端点 —— 支持有/无「两级取值」
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ResolveEndpoint {
    /// 方式一：直接从详情响应取地址
    #[serde(default)]
    pub direct: Option<Endpoint>,
    /// 方式二：★ 两级取值 —— 先调列表接口取 id，再套 URL 模板
    #[serde(default)]
    pub from_list: Option<FromListResolve>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct FromListResolve {
    /// 先请求的列表端点
    pub endpoint: Endpoint,
    /// 从列表响应中提取 id 的 JSONPath
    pub id_path: String,
    /// URL 模板，用 `{id}` 占位
    pub url_template: String,
    /// 可选：URL 模板变体（多清晰度），如 `{"2000": "...{id}.../2000.m3u8"}`
    #[serde(default)]
    pub variants: HashMap<String, String>,
}

// ─────────────────────────── 映射目标字段名 ───────────────────────────

const K_ITEMS: &str = "items";
const K_ID: &str = "id";
const K_TITLE: &str = "title";
const K_COVER: &str = "cover";
const K_SUBTITLE: &str = "subtitle";
const K_DESC: &str = "description";
const K_URL: &str = "url";
const K_EPISODES: &str = "episodes";

// ─────────────────────────── Provider 实现 ───────────────────────────

pub struct DeclarativeProvider {
    manifest: ProviderManifest,
    spec: DeclarativeSpec,
    client: reqwest::Client,
}

impl DeclarativeProvider {
    pub fn from_json(json: &str) -> Result<Self> {
        let spec: DeclarativeSpec = serde_json::from_str(json)
            .map_err(|e| ProviderError::parse(format!("描述文件格式错误: {e}")))?;
        Self::new(spec)
    }

    pub fn new(spec: DeclarativeSpec) -> Result<Self> {
        if spec.id.trim().is_empty() {
            return Err(ProviderError::parse("缺少 id 字段"));
        }
        if spec.base.trim().is_empty() {
            return Err(ProviderError::parse("缺少 base 字段"));
        }
        // base 必须是 http(s)
        if !spec.base.starts_with("http://") && !spec.base.starts_with("https://") {
            return Err(ProviderError::parse("base 必须是 http:// 或 https:// 开头"));
        }

        let ua = spec.user_agent.clone().unwrap_or_else(|| {
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36".into()
        });

        let client = reqwest::Client::builder()
            .user_agent(ua)
            .timeout(Duration::from_secs(20))
            .build()
            .map_err(|e| ProviderError::network(format!("构建客户端失败: {e}")))?;

        let caps = Capabilities {
            vod: spec.capabilities.vod,
            live: spec.capabilities.live,
            epg: false,
            search: spec.capabilities.search && spec.endpoints.search.is_some(),
            login_required: false,
            multi_source: spec.capabilities.multi_source,
            server_side_history: false,
            favorites: false,
            timeshift: false,
            danmaku: false,
            // 声明式源的 schema 里还没有登录声明（它是纯 HTTP 拉取模型）
            login_supported: false,
            login_hint: None,
            login_needs_username: true,
            login_qr_supported: false,
            // task-38：声明式源没有登录能力
            can_auto_login: false,
        };

        let manifest = ProviderManifest {
            id: spec.id.clone(),
            name: spec.name.clone(),
            version: spec.version.clone(),
            kind: "declarative".into(),
            description: spec.description.clone(),
            icon: spec.icon.clone(),
            id_prefixes: spec.id_prefixes.clone(),
            capabilities: caps,
            // 声明式源暂不声明配置项（JSON 规则里没有这一块）
            cover_headers: Vec::new(),
            config: Vec::new(),
            api_version: 1,
            theme_color: spec.theme_color.clone(),
            working: true,
            broken_reason: None,
            enabled: None,
        };

        Ok(Self {
            manifest,
            spec,
            client,
        })
    }

    /// 构建完整 URL（替换参数模板）
    fn build_url(&self, ep: &Endpoint, vars: &HashMap<String, String>) -> String {
        let path = subst(&ep.path, vars);
        let mut url = if path.starts_with("http") {
            path
        } else {
            format!("{}{}", self.spec.base.trim_end_matches('/'), ensure_slash(&path))
        };

        if !ep.params.is_empty() {
            let qs: Vec<String> = ep
                .params
                .iter()
                .map(|(k, v)| {
                    format!(
                        "{}={}",
                        urlencoding::encode(k),
                        urlencoding::encode(&subst(v, vars))
                    )
                })
                .collect();
            let sep = if url.contains('?') { '&' } else { '?' };
            url.push(sep);
            url.push_str(&qs.join("&"));
        }
        url
    }

    async fn fetch(&self, ep: &Endpoint, vars: &HashMap<String, String>) -> Result<serde_json::Value> {
        let url = self.build_url(ep, vars);

        let method = ep.method.as_deref().unwrap_or("GET").to_uppercase();
        let mut req = if method == "POST" {
            self.client.post(&url)
        } else {
            self.client.get(&url)
        };

        for (k, v) in &self.spec.headers {
            req = req.header(k, v);
        }

        let resp = req
            .send()
            .await
            .map_err(|e| ProviderError::network(format!("请求失败 {url}: {e}")))?;

        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| ProviderError::network(format!("读取失败: {e}")))?;

        if !status.is_success() {
            return Err(ProviderError::network(format!(
                "HTTP {status}: {}",
                text.chars().take(160).collect::<String>()
            )));
        }

        serde_json::from_str(&text).map_err(|e| {
            ProviderError::parse(format!(
                "响应不是 JSON（站点可能改版或有反爬）: {e} — {}",
                text.chars().take(160).collect::<String>()
            ))
        })
    }

    /// 把映射应用到响应，产出 MediaItem 列表
    fn map_items(&self, json: &serde_json::Value, map: &HashMap<String, String>) -> Vec<MediaItem> {
        // items 是数组的 JSONPath
        let items_path = map.get(K_ITEMS).map(String::as_str).unwrap_or("$.list");
        let arr = select(json, items_path);

        let arr = match arr {
            serde_json::Value::Array(a) => a,
            // 若整体就是数组
            serde_json::Value::Null => return vec![],
            other => vec![other],
        };

        let get = |node: &serde_json::Value, key: &str| -> Option<String> {
            map.get(key)
                .and_then(|p| select(node, p).as_str().map(String::from))
                .filter(|s| !s.is_empty())
        };

        arr.iter()
            .filter_map(|node| {
                let id = get(node, K_ID)?;
                Some(MediaItem {
                    id: MediaId::new(&self.spec.id, &id),
                    title: get(node, K_TITLE).unwrap_or_else(|| id.clone()),
                    cover: get(node, K_COVER),
                    subtitle: get(node, K_SUBTITLE),
                    badges: vec![],
                    kind: MediaKind::Movie,
                    description: get(node, K_DESC),
                })
            })
            .collect()
    }
}

fn ensure_slash(p: &str) -> String {
    if p.starts_with('/') {
        p.to_string()
    } else {
        format!("/{p}")
    }
}

/// 模板替换：`{key}` → vars[key]
fn subst(tpl: &str, vars: &HashMap<String, String>) -> String {
    let mut out = tpl.to_string();
    for (k, v) in vars {
        out = out.replace(&format!("{{{k}}}"), v);
    }
    out
}

// ─────────────────────────── JSONPath 子集 ───────────────────────────

/// 极简 JSONPath 求值 —— 支持 `$.a.b`、`$.a[*]`、`$.a[0]`、裸 `a.b`
///
/// **刻意只支持子集**：Legado 的教训是自研规则语言会失控（最终加了 `mainJs` 逃生舱）。
/// 我们用成熟标准的子集，不发明新语法。
pub fn select<'a>(root: &'a serde_json::Value, path: &str) -> serde_json::Value {
    let p = path.trim();
    let p = p.strip_prefix("$.").or_else(|| p.strip_prefix("$")).unwrap_or(p);
    if p.is_empty() {
        return root.clone();
    }

    let mut cur = root.clone();
    for seg in split_path(p) {
        match seg {
            Seg::Key(k) => {
                cur = cur.get(&k).cloned().unwrap_or(serde_json::Value::Null);
            }
            Seg::Index(i) => {
                cur = cur.get(i).cloned().unwrap_or(serde_json::Value::Null);
            }
            Seg::Wildcard => {
                // 通配返回数组本身，交由调用方迭代
                if !cur.is_array() {
                    if cur.is_null() {
                        return serde_json::Value::Null;
                    }
                    cur = serde_json::Value::Array(vec![cur]);
                }
            }
        }
        if cur.is_null() {
            return serde_json::Value::Null;
        }
    }
    cur
}

enum Seg {
    Key(String),
    Index(usize),
    Wildcard,
}

fn split_path(p: &str) -> Vec<Seg> {
    let mut out = Vec::new();
    for raw in p.split('.') {
        let mut s = raw;
        // 处理 a[0] / a[*] / a[0][1]
        if let Some(bracket) = s.find('[') {
            let key = &s[..bracket];
            if !key.is_empty() {
                out.push(Seg::Key(key.to_string()));
            }
            s = &s[bracket..];
            let mut rest = s;
            while let Some(start) = rest.find('[') {
                let Some(end) = rest[start..].find(']') else {
                    break;
                };
                let idx = &rest[start + 1..start + end];
                if idx == "*" {
                    out.push(Seg::Wildcard);
                } else if let Ok(i) = idx.parse::<usize>() {
                    out.push(Seg::Index(i));
                }
                rest = &rest[start + end + 1..];
            }
        } else if !s.is_empty() {
            out.push(Seg::Key(s.to_string()));
        }
    }
    out
}

// ─────────────────────────── Trait 实现 ───────────────────────────

#[async_trait]
impl MediaProvider for DeclarativeProvider {
    fn manifest(&self) -> &ProviderManifest {
        &self.manifest
    }

    async fn categories(&self) -> Result<Vec<Category>> {
        let Some(ep) = &self.spec.endpoints.categories else {
            return Ok(vec![]);
        };
        let json = self.fetch(ep, &HashMap::new()).await?;

        let path = ep.map.get(K_ITEMS).map(String::as_str).unwrap_or("$.class");
        let arr = match select(&json, path) {
            serde_json::Value::Array(a) => a,
            serde_json::Value::Null => return Ok(vec![]),
            v => vec![v],
        };

        let id_path = ep.map.get(K_ID).map(String::as_str).unwrap_or("$.type_id");
        let name_path = ep
            .map
            .get(K_TITLE)
            .map(String::as_str)
            .unwrap_or("$.type_name");

        Ok(arr
            .iter()
            .filter_map(|n| {
                let id = select(n, id_path).as_str().map(String::from)?;
                let name = select(n, name_path)
                    .as_str()
                    .map(String::from)
                    .unwrap_or_else(|| id.clone());
                Some(Category {
                    id,
                    name,
                    children: vec![],
                })
            })
            .collect())
    }

    async fn list(&self, req: ListRequest) -> Result<Page<MediaItem>> {
        let ep = self
            .spec
            .endpoints
            .list
            .as_ref()
            .ok_or_else(|| ProviderError::unsupported("该源未配置列表端点"))?;

        let mut vars = HashMap::new();
        vars.insert("category".into(), req.category_id.clone());
        vars.insert("page".into(), req.page.to_string());
        for (k, v) in &req.filters {
            vars.insert(k.clone(), v.clone());
        }

        let json = self.fetch(ep, &vars).await?;
        let items = self.map_items(&json, &ep.map);

        // 分页信息（可选）
        let total = select(&json, "$.total").as_u64();
        let page_count = select(&json, "$.pagecount").as_u64().map(|v| v as u32);

        Ok(Page {
            items,
            page: req.page,
            page_count,
            total,
        })
    }

    async fn search(&self, keyword: &str, page: u32) -> Result<Page<MediaItem>> {
        let ep = self
            .spec
            .endpoints
            .search
            .as_ref()
            .ok_or_else(|| ProviderError::unsupported("该源未配置搜索端点"))?;

        let mut vars = HashMap::new();
        vars.insert("keyword".into(), keyword.to_string());
        vars.insert("page".into(), page.to_string());

        let json = self.fetch(ep, &vars).await?;
        Ok(Page {
            items: self.map_items(&json, &ep.map),
            page,
            page_count: None,
            total: None,
        })
    }

    async fn detail(&self, id: &MediaId) -> Result<MediaDetail> {
        let ep = self
            .spec
            .endpoints
            .detail
            .as_ref()
            .ok_or_else(|| ProviderError::unsupported("该源未配置详情端点"))?;

        let mut vars = HashMap::new();
        vars.insert("id".into(), id.native.clone());

        let json = self.fetch(ep, &vars).await?;
        let items = self.map_items(&json, &ep.map);
        let first = items.first();

        // 剧集解析（`vod_play_url` 的 `$$$` / `#` / `$` 分隔符约定 —— TVBox 生态事实标准）
        let mut episodes = Vec::new();
        let mut sources = Vec::new();
        if let Some(ep_path) = ep.map.get(K_EPISODES) {
            if let Some(raw) = select(&json, ep_path).as_str() {
                let parsed = parse_play_url(raw);
                for (idx, (line_name, eps)) in parsed.iter().enumerate() {
                    sources.push(PlaySource {
                        code: format!("line{idx}"),
                        title: line_name.clone(),
                        count: eps.len() as u32,
                        nested: vec![],
                    });
                    for (i, (title, link)) in eps.iter().enumerate() {
                        episodes.push(Episode {
                            id: link.clone(),
                            title: title.clone(),
                            order: (i + 1) as u32,
                            player_id: Some(format!("line{idx}")),
                        });
                    }
                }
            }
        }

        Ok(MediaDetail {
            id: id.clone(),
            title: first.map(|i| i.title.clone()).unwrap_or_else(|| id.native.clone()),
            cover: first.and_then(|i| i.cover.clone()),
            description: first.and_then(|i| i.description.clone()),
            badges: vec![],
            kind: if episodes.is_empty() {
                MediaKind::Movie
            } else {
                MediaKind::Series
            },
            meta: serde_json::Map::new(),
            sources,
            episodes,
        })
    }

    async fn resolve(&self, id: &MediaId, req: &PlayRequest) -> Result<Vec<StreamCandidate>> {
        // 剧集 id 直接就是播放地址（来自 episodes 的 link）
        if let Some(ep_id) = req.episode_id.as_deref() {
            if ep_id.starts_with("http") {
                return Ok(vec![candidate_from_url(ep_id, &self.spec)]);
            }
        }

        let Some(r) = &self.spec.endpoints.resolve else {
            return Err(ProviderError::unsupported("该源未配置取流端点"));
        };

        // 方式一：直接取
        if let Some(direct) = &r.direct {
            let mut vars = HashMap::new();
            vars.insert("id".into(), id.native.clone());
            let json = self.fetch(direct, &vars).await?;
            let url_path = direct.map.get(K_URL).map(String::as_str).unwrap_or("$.url");
            if let Some(u) = select(&json, url_path).as_str() {
                if u.starts_with("http") {
                    return Ok(vec![candidate_from_url(u, &self.spec)]);
                }
            }
        }

        // ★ 方式二：两级取值（央视式）
        if let Some(fl) = &r.from_list {
            let mut vars = HashMap::new();
            vars.insert("id".into(), id.native.clone());
            let json = self.fetch(&fl.endpoint, &vars).await?;

            let node = select(&json, &fl.id_path);
            // 可能是数组（取第一个）或字符串
            let extracted = match &node {
                serde_json::Value::Array(a) => a
                    .first()
                    .and_then(|v| v.as_str())
                    .map(String::from),
                serde_json::Value::String(s) => Some(s.clone()),
                _ => None,
            };

            let Some(v) = extracted else {
                return Err(ProviderError::parse(format!(
                    "两级取值失败：{} 未取到值",
                    fl.id_path
                )));
            };

            let mut out = Vec::new();
            if fl.variants.is_empty() {
                out.push(candidate_from_url(
                    &fl.url_template.replace("{id}", &v),
                    &self.spec,
                ));
            } else {
                for (label, tpl) in &fl.variants {
                    // kind 按 URL 推断而不是硬编码 Hls：
                    // variants 也可能直接给 mp4 直链
                    let u = tpl.replace("{id}", &v);
                    out.push(
                        StreamCandidate::new(&u, StreamKind::from_url(&u))
                            .with_quality(label)
                            .with_label("声明式")
                            .with_headers(spec_headers(&self.spec)),
                    );
                }
            }
            return Ok(out);
        }

        Err(ProviderError::unsupported("取流端点配置不完整"))
    }

    async fn health_check(&self) -> bool {
        // 有 categories 就探它，否则探 list
        let (ep, vars) = if let Some(c) = &self.spec.endpoints.categories {
            (c, HashMap::new())
        } else if let Some(l) = &self.spec.endpoints.list {
            let mut v = HashMap::new();
            v.insert("category".to_string(), "1".to_string());
            v.insert("page".to_string(), "1".to_string());
            (l, v)
        } else {
            return false;
        };

        tokio::time::timeout(
            Duration::from_secs(12),
            self.fetch(ep, &vars),
        )
        .await
        .map(|r| r.is_ok())
        .unwrap_or(false)
    }
}

fn spec_headers(spec: &DeclarativeSpec) -> Vec<(String, String)> {
    spec.headers
        .iter()
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect()
}

fn candidate_from_url(url: &str, spec: &DeclarativeSpec) -> StreamCandidate {
    StreamCandidate::new(url, StreamKind::from_url(url))
        .with_label(spec.name.clone())
        .with_headers(spec_headers(spec))
}

/// 解析 TVBox 生态的 `vod_play_url` 编码（**事实标准**，跨 TVBox/zyfun/CatVod）
///
/// ```text
/// "线路A$$$线路B"          —— `$$$` 分隔线路
/// "第1集$url1#第2集$url2"  —— `#` 分隔剧集，`$` 分隔「剧名与地址」
/// ```
pub fn parse_play_url(raw: &str) -> Vec<(String, Vec<(String, String)>)> {
    raw.split("$$$")
        .enumerate()
        .map(|(li, line)| {
            let name = format!("线路{}", li + 1);
            let eps: Vec<(String, String)> = line
                .split('#')
                .filter(|s| !s.trim().is_empty())
                .map(|item| match item.split_once('$') {
                    Some((t, u)) => (t.trim().to_string(), u.trim().to_string()),
                    None => (item.trim().to_string(), item.trim().to_string()),
                })
                .filter(|(_, u)| !u.is_empty())
                .collect();
            (name, eps)
        })
        .filter(|(_, eps)| !eps.is_empty())
        .collect()
}

// ─────────────────────────── 测试 ───────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jsonpath_subset_works() {
        let v: serde_json::Value = serde_json::json!({
            "class": [{"type_id":"1","type_name":"电影"}],
            "data": {"list": [{"vod_id":"a"},{"vod_id":"b"}]}
        });
        assert_eq!(select(&v, "$.class").as_array().unwrap().len(), 1);
        assert_eq!(select(&v, "$.class[0].type_name").as_str().unwrap(), "电影");
        assert_eq!(select(&v, "$.data.list[1].vod_id").as_str().unwrap(), "b");
        assert_eq!(select(&v, "$.data.list").as_array().unwrap().len(), 2);
        // 裸路径也支持
        assert_eq!(select(&v, "data.list[0].vod_id").as_str().unwrap(), "a");
    }

    #[test]
    fn tvbox_play_url_separators_parsed() {
        // 生态事实标准：$$$ 分线路，# 分集，$ 分「名与址」
        let raw = "第1集$http://a/1.m3u8#第2集$http://a/2.m3u8$$$第1集$http://b/1.m3u8";
        let parsed = parse_play_url(raw);
        assert_eq!(parsed.len(), 2, "应解析出 2 条线路");
        assert_eq!(parsed[0].1.len(), 2, "线路1 应有 2 集");
        assert_eq!(parsed[1].1.len(), 1, "线路2 应有 1 集");
        assert_eq!(parsed[0].1[0].1, "http://a/1.m3u8");
    }

    #[test]
    fn rejects_invalid_spec() {
        assert!(DeclarativeProvider::from_json("{}").is_err());
        assert!(DeclarativeProvider::from_json(
            r#"{"id":"x","name":"X","base":"ftp://bad"}"#
        )
        .is_err());
    }

    #[test]
    fn accepts_valid_spec() {
        let spec = r#"{
            "id":"demo","name":"示例站","base":"https://api.example.com",
            "endpoints":{
                "list":{"path":"/list","params":{"ac":"videolist","t":"{category}","pg":"{page}"},
                        "map":{"items":"$.list","id":"$.vod_id","title":"$.vod_name"}}
            }
        }"#;
        let p = DeclarativeProvider::from_json(spec).unwrap();
        assert_eq!(p.manifest().id, "demo");
        assert!(p.manifest().capabilities.vod);
    }

    #[test]
    fn build_url_substitutes_params() {
        let spec = r#"{
            "id":"demo","name":"D","base":"https://api.x.com",
            "endpoints":{"list":{"path":"/vod","params":{"t":"{category}","pg":"{page}"}}}
        }"#;
        let p = DeclarativeProvider::from_json(spec).unwrap();
        let ep = p.spec.endpoints.list.as_ref().unwrap();
        let mut vars = HashMap::new();
        vars.insert("category".to_string(), "1".to_string());
        vars.insert("page".to_string(), "3".to_string());
        let u = p.build_url(ep, &vars);
        assert!(u.starts_with("https://api.x.com/vod?"));
        assert!(u.contains("t=1"));
        assert!(u.contains("pg=3"));
    }
}
