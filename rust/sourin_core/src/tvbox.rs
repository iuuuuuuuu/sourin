// ═══════════════════════════════════════════════════════════════════════
//  TVBox 配置导入（task-5）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个模块干什么
//
// TVBox 生态里分享的配置是一份 JSON，里面有：
//
// ```text
// sites[]  站点列表（type 字段决定协议：0 纯 JSON / 1 苹果CMS / 3 spider / 4 其它）
// lives[]  直播源（m3u/txt）
// parses[] 第三方网页解析接口
// ```
//
// 本模块把其中 **type=1（苹果CMS v10）** 的站点就地转成 sourin 的
// MediaProvider（不是生成 JS 插件，见下），其余类型如实报告「转不了」。
//
// # 为什么不生成 JS 插件（与 tools/tvbox-convert.mjs 的差别）
//
// 外部工具 tvbox-convert.mjs 的做法是「生成一份 .js 插件源码，丢给
// QuickJS 跑」。应用内**不走那条路**，而是直接实现 Rust 原生 Provider：
//
// ```text
// · 少一层「生成 JS → 沙箱执行 → 解析 JSON」的翻译，链路短、失败点少
// · 不受 QuickJS 10s 脚本预算限制（大分类扫描要连发多页请求）
// · 纯逻辑（JSON 宽松解析 / URL 归一化 / 剧集切分）可直接单测
// ```
//
// 协议映射规则与 tvbox-convert.mjs **逐条等价**（那份工具踩过的坑都在
// 这里复刻了，包括 normalizeApiUrl 必须剥查询串、分类兜底绝不能退回
// 全站最新、PARSE_SERVICES 出错必须 continue 而不是 throw）。
//
// # 苹果CMS v10 协议
//
// ```text
// 分类 {api}?ac=list
// 列表 {api}?ac=videolist&t={typeId}&pg={page}
// 详情 {api}?ac=videolist&ids={id}
// 搜索 {api}?ac=videolist&wd={关键词}&pg={page}
// 响应 { code, page, pagecount, total, class:[...], list:[{vod_id,vod_name,
//        vod_pic,vod_play_url,vod_content,vod_blurb,vod_remarks,type_id,type_id_1}] }
// ```

use crate::model::{
    Capabilities, Category, Episode, ErrorKind, MediaDetail, MediaId, MediaItem, MediaKind, Page,
    PlayRequest, PlaySource, ProviderError, ProviderManifest, Result, Section, SectionSource,
    StreamCandidate, StreamKind, TvboxCategoryEntry,
};
use crate::provider::{ListRequest, MediaProvider};
use async_trait::async_trait;
use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

/// 与 TVBox / tvbox-convert.mjs 保持一致的 UA
pub const TVBOX_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) \
AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36";

/// 下载 **TVBox 配置**时用的 UA（与上面那个不同，是有原因的）
///
/// # ★ 实测（2026-10-04）：同一个 URL，UA 决定拿到的是配置还是网页
///
/// 站点 `https://tv.xn--yhqu5zs87a.top`（菜妮丝）做了内容协商：
/// ```text
/// UA = Mozilla/5.0 (Chrome)  → 200 text/html          13.8KB 「FongMi 影视APP 下载页」
/// UA = okhttp/3.12.13        → 200 application/json   19.3KB  真配置
/// UA = 完全不发              → 200 text/html          13.8KB  下载页
/// ```
/// 逐项排除过：HTTP/1.1 与 HTTP/2、Accept、Accept-Encoding 都不影响结果，
/// **只有 UA 影响**（诊断见 `real_sites::diagnose_content_negotiation`）。
///
/// 为什么不能把全局 [TVBOX_UA] 也改成 okhttp：那是解析/播放链路在用的 UA，
/// 有 task5 的实测约束（假源站与真解析服务都按它验过），改它属于越界改动。
/// 所以**只给「下载配置」这一条路径**用 TVBox 生态自己的 UA。
///
/// ⚠️ 不这么做的后果（真实症状）：用户在浏览器里明明看到的是 JSON，
///    导入时报「配置不是合法 JSON」，而错误里看不到任何线索 ——
///    因为服务端回的是**一个完全合法的 HTML 页面**。
pub const TVBOX_CONFIG_UA: &str = "okhttp/3.12.13";

/// 下载一份 TVBox 配置（带上面那个 UA）
///
/// 与 [get_text_with] 的区别只有 UA —— 但这个区别是**功能性的**，不是风格。
pub async fn fetch_config_text(
    client: &reqwest::Client,
    url: &str,
) -> std::result::Result<String, String> {
    let resp = client
        .get(url)
        .header(reqwest::header::USER_AGENT, TVBOX_CONFIG_UA)
        .header(reqwest::header::ACCEPT, "*/*")
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = resp.status();
    let text = resp.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(format!("HTTP {}", status.as_u16()));
    }
    Ok(text)
}
/// 第三方网页解析服务（前缀 + urlencoded(目标页)）
///
/// 来源：tvbox-convert.mjs 里收集 15 个 type=1 接口实测后**只剩这两个活着**。
/// 2026-10-02 复测：gimy 活着（能返回真 m3u8），huaqi 已失效（返回
/// {"code":"404",...,"msg":"解析失败"}，没有 url 字段 → 自动 continue）。
pub const PARSE_SERVICES: [&str; 2] = [
    "https://player.gimy.bot/u/parse.php?url=",
    "https://api.huaqi.pro/api/?key=5bd0db7c858ba9f999373450f3651af7&url=",
];

/// 单次 HTTP 超时（探测与取列表共用）
const HTTP_TIMEOUT_SECS: u64 = 20;
/// 导入时并发探测的上限（站点多时不要打爆网络）
const MAX_PROBE_CONCURRENCY: usize = 12;
/// 分类兜底扫描的最大页数（服务端不认 t= 时用）
const SCAN_MAX_PAGES: u32 = 8;
/// 分类兜底扫描最多收集多少条
const SCAN_MAX_ITEMS: usize = 20;
/// 首页最多放几个分类区块
const HOME_SECTIONS: usize = 8;

// ═══════════════════════════════════════════════════════════════════════
//  纯函数区（全部可单测，无网络、无 IO）
// ═══════════════════════════════════════════════════════════════════════

/// 是否以 http:// 或 https:// 开头（大小写不敏感）
pub fn starts_http(s: &str) -> bool {
    match s.get(..7) {
        Some(p) if p.eq_ignore_ascii_case("http://") => true,
        _ => matches!(s.get(..8), Some(p) if p.eq_ignore_ascii_case("https://")),
    }
}

/// 拆出 (scheme, origin)，如 ("https:", "https://a.com")
///
/// 手写而不是用 url crate —— 本项目依赖树里**没有 url crate**
/// （Cargo.toml 只有 urlencoding / regex）。
pub fn split_origin(base: &str) -> Option<(String, String)> {
    let rest = if let Some(r) = base.strip_prefix("https://") {
        ("https:", r)
    } else if let Some(r) = base.strip_prefix("http://") {
        ("http:", r)
    } else {
        return None;
    };
    let (scheme, host_and_path) = rest;
    let end = host_and_path
        .find(|c| c == '/' || c == '?' || c == '#')
        .unwrap_or(host_and_path.len());
    let host = &host_and_path[..end];
    if host.is_empty() {
        return None;
    }
    Some((scheme.to_string(), format!("{scheme}//{host}")))
}

/// 取 host（不含端口之后的路径）
fn host_of(url: &str) -> Option<String> {
    let rest = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))?;
    let end = rest
        .find(|c| c == '/' || c == '?' || c == '#')
        .unwrap_or(rest.len());
    let host = &rest[..end];
    if host.is_empty() {
        None
    } else {
        Some(host.to_string())
    }
}

/// 宽松 JSON 解析 —— 直接对应 tvbox-convert.mjs 的 parseLooseJson
///
/// TVBox 配置在野外的真实形态经常不是严格 JSON：
///
/// ```text
/// · 带 UTF-8 BOM（Windows 记事本另存）
/// · JSONP 包裹     foo({...});
/// · 整行 // 注释
/// · 对象/数组末尾多余逗号
/// · ★ 字符串字面量里直接换行（裸控制字符）—— 2026-10-04 实测两条真配置栽在这
/// ```
pub fn parse_loose_json(text: &str) -> std::result::Result<serde_json::Value, String> {
    let s = text.trim_start_matches('\u{feff}').trim();
    let s = strip_jsonp(s);
    // ★ 顺序关键：必须在逐行剥注释之前先把字符串里的裸控制字符转义掉，
    //   否则「整行 // 注释」会把字符串内部那半行也一并删掉。
    let escaped = escape_control_chars_in_strings(s);
    let mut cleaned = String::with_capacity(escaped.len());
    for line in escaped.lines() {
        if line.trim_start().starts_with("//") {
            continue;
        }
        cleaned.push_str(line);
        cleaned.push('\n');
    }
    let cleaned = remove_trailing_commas(&cleaned);
    serde_json::from_str(&cleaned).map_err(|e| e.to_string())
}

/// 把字符串字面量里的裸控制字符补成转义序列
///
/// ★ 为什么需要它（2026-10-04 实测，两条真实 TVBox 配置因此导入失败）：
///
/// · http://xhztv.top/4k.json          字符串内 3 个裸 0x0A，形如 "优<LF>酷"
/// · https://gh-proxy.com/…/svip.json  字符串内 1 个裸 0x0A，形如 "简介": "…安静<LF>       "
///
/// 两份配置用 Python json.loads(strict=False)（宽松模式）都能解析、strict=True 都失败
/// ⇒ 字符串内的裸控制字符是**唯一**的拦路虎，其余（BOM / // 注释 / 尾逗号）我们本来就已处理。
///
/// RFC 8259 规定字符串里不许出现 U+0000-U+001F，serde_json 严格执行；
/// 但配置作者的本意显然只是「这里有个换行」，所以按最保守的方式补成转义序列：
/// 能用短转义的用 \b \f \n \r \t，其余（如 0x01、0x1F）用 \uXXXX。
///
/// ★ 必须认字符串状态：字符串外的空白（含 CRLF 里的 \r）保持原样，交给后面的逐行处理。
fn escape_control_chars_in_strings(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_string = false;
    let mut escaped = false;
    for c in s.chars() {
        if !in_string {
            if c == '"' {
                in_string = true;
            }
            out.push(c);
            continue;
        }
        if escaped {
            // 上一个字符是反斜杠，当前字符是字面量（含 \" 与 \\），原样保留
            escaped = false;
            out.push(c);
            continue;
        }
        match c {
            '\\' => {
                escaped = true;
                out.push(c);
            }
            '"' => {
                in_string = false;
                out.push(c);
            }
            c if (c as u32) < 0x20 => {
                let esc = match c as u32 {
                    0x08 => "\\b".to_string(),
                    0x0c => "\\f".to_string(),
                    0x0a => "\\n".to_string(),
                    0x0d => "\\r".to_string(),
                    0x09 => "\\t".to_string(),
                    n => format!("\\u{:04x}", n),
                };
                out.push_str(&esc);
            }
            c => out.push(c),
        }
    }
    out
}

/// JSONP 拆壳：foo.bar({...}); → {...}
fn strip_jsonp(s: &str) -> &str {
    let open = match s.find('(') {
        Some(i) => i,
        None => return s,
    };
    let head = &s[..open];
    if head.is_empty()
        || !head
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '$' || c == '.')
    {
        return s;
    }
    let t = s.trim_end();
    let t = t.strip_suffix(';').map(|x| x.trim_end()).unwrap_or(t);
    if !t.ends_with(')') {
        return s;
    }
    let close = t.len() - 1;
    if close <= open {
        return s;
    }
    &s[open + 1..close]
}

/// 去掉逗号后紧跟 } / ] 的尾逗号
///
/// ★ 必须认字符串状态：早期版本逐字符扫、不认字符串，
/// 字符串里形如 "a,\n}" 的逗号会被误删（真配置里有这种文本）。
fn remove_trailing_commas(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut out = String::with_capacity(s.len());
    let mut i = 0usize;
    let mut in_string = false;
    let mut escaped = false;
    while i < chars.len() {
        let c = chars[i];
        if in_string {
            if escaped {
                escaped = false;
            } else if c == '\\' {
                escaped = true;
            } else if c == '"' {
                in_string = false;
            }
            out.push(c);
            i += 1;
            continue;
        }
        if c == '"' {
            in_string = true;
            out.push(c);
            i += 1;
            continue;
        }
        if c == ',' {
            let mut j = i + 1;
            while j < chars.len() && chars[j].is_whitespace() {
                j += 1;
            }
            if j < chars.len() && (chars[j] == '}' || chars[j] == ']') {
                i += 1;
                continue;
            }
        }
        out.push(c);
        i += 1;
    }
    out
}

/// 归一化接口地址 —— ★ 必须剥掉自带查询串
///
/// 实测踩过的坑：TVBox 配置里常见
/// https://api.apibdzy.com/api.php/provide/vod?ac=list，
/// 直接拼 ?ac=videolist&pg=1 会变成 ...vod?ac=list?ac=videolist&pg=1，
/// 站端认不出 → **所有分类都是 0 条**（看起来像「这个源没内容」）。
pub fn normalize_api_url(api: &str) -> String {
    let raw = api.trim();
    if raw.is_empty() {
        return String::new();
    }
    let cut = raw.split(|c| c == '?' || c == '#').next().unwrap_or("");
    cut.trim_end_matches('/').to_string()
}

/// 把相对接口地址按配置来源地址补全（对应 resolveApi）
pub fn resolve_api(api: &str, base_url: &str) -> Option<String> {
    let a = api.trim();
    if a.is_empty() {
        return None;
    }
    if starts_http(a) {
        return Some(a.to_string());
    }
    let (scheme, origin) = split_origin(base_url)?;
    // ★ 协议相对地址：拼 scheme 时**必须保留**原来的两条斜杠
    //   （JS 版是 scheme + 原串；剥掉再拼会得到 "https:b.com/x"）
    if a.starts_with("//") {
        return Some(format!("{scheme}{a}"));
    }
    if a.starts_with('/') {
        return Some(format!("{origin}{a}"));
    }
    let no_query = base_url
        .split(|c| c == '?' || c == '#')
        .next()
        .unwrap_or("");
    match no_query.rfind('/') {
        Some(i) => Some(format!("{}{}", &no_query[..i + 1], a)),
        None => Some(format!("{origin}/{a}")),
    }
}

/// 相对地址补全 —— ★ **纯字符串实现**
///
/// 不能依赖 url crate（依赖树里没有），而且这段逻辑要跟
/// tvbox-convert.mjs 里的 absolutize 逐条对齐（那边是给 QuickJS 用的，
/// 同样不能用 new URL）。
pub fn absolutize(r: &str, base_url: &str) -> String {
    let r = r.trim();
    if r.is_empty() {
        return String::new();
    }
    if starts_http(r) {
        return r.to_string();
    }
    let (scheme, origin) = match split_origin(base_url) {
        Some(x) => x,
        None => return r.to_string(),
    };
    // ★ 同上：协议相对地址要保留 "//"
    if r.starts_with("//") {
        return format!("{scheme}{r}");
    }
    if r.starts_with('/') {
        return format!("{origin}{r}");
    }
    let no_query = base_url
        .split(|c| c == '?' || c == '#')
        .next()
        .unwrap_or("");
    match no_query.rfind('/') {
        Some(i) => format!("{}{}", &no_query[..i + 1], r),
        None => format!("{origin}/{r}"),
    }
}

/// 从网页里挖第一个 m3u8 地址（对应 extractM3u8）
pub fn extract_m3u8(html: &str, page_url: &str) -> Option<String> {
    let chars: Vec<(usize, char)> = html.char_indices().collect();
    let mut k = 0usize;
    while k < chars.len() {
        let (start, c) = chars[k];
        if c == '"' || c == '\'' {
            let mut j = k + 1;
            while j < chars.len() && chars[j].1 != c {
                j += 1;
            }
            if j >= chars.len() {
                return None;
            }
            let inner = &html[start + c.len_utf8()..chars[j].0];
            if inner.contains(".m3u8") {
                return Some(absolutize(inner, page_url));
            }
            k = j + 1;
            continue;
        }
        k += 1;
    }
    None
}

/// 剧集串切分：第1集$http://a.m3u8#第2集$http://b.m3u8
///
/// 返回 (集名, 地址)，只保留 http(s) 的地址（对应 parseEpisodes）。
pub fn parse_episodes(s: &str) -> Vec<(String, String)> {
    s.split('#')
        .filter_map(|part| {
            let (name, url) = match part.find('$') {
                Some(i) => (
                    part[..i].trim().to_string(),
                    part[i + 1..].trim().to_string(),
                ),
                None => (String::new(), part.trim().to_string()),
            };
            if starts_http(&url) {
                Some((name, url))
            } else {
                None
            }
        })
        .collect()
}

/// 去 HTML 标签（对应 stripTags：/<[^>]+>/g）
pub fn strip_tags(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut tag = String::new();
    let mut in_tag = false;
    for ch in s.chars() {
        if in_tag {
            if ch == '>' {
                in_tag = false;
                if tag.is_empty() {
                    // <> 在 JS 正则里不算标签（要求 [^>]+）→ 原样保留
                    out.push('<');
                    out.push('>');
                }
                tag.clear();
            } else {
                tag.push(ch);
            }
            continue;
        }
        if ch == '<' {
            in_tag = true;
            tag.clear();
            continue;
        }
        out.push(ch);
    }
    if in_tag {
        out.push('<');
        out.push_str(&tag);
    }
    out.trim().to_string()
}

/// 由站名/域名生成源 id（对应 toId）
///
/// ★ **绝不返回固定值** —— 第一版写成 || 'src'，结果 4 个中文源
/// 全变成 "src" 互相覆盖，最后只剩一个。
///
/// ```text
/// ① 站名里的 ASCII 字母数字，长度 ≥2 → 小写
/// ② 否则取 api 域名（去 www.）第一段，长度 ≥2 → 小写
/// ③ 兜底 tvbox{index+1}
/// ```
pub fn to_id(name: &str, api: &str, index: usize) -> String {
    let from_name: String = name
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .collect::<String>()
        .to_lowercase();
    if from_name.len() >= 2 {
        return from_name;
    }
    if let Some(host) = host_of(api) {
        let h = host.strip_prefix("www.").unwrap_or(&host);
        let seg = h.split('.').next().unwrap_or("");
        let from_host: String = seg
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .collect::<String>()
            .to_lowercase();
        if from_host.len() >= 2 {
            return from_host;
        }
    }
    format!("tvbox{}", index + 1)
}

/// 撞名就加 -2 / -3（对应 uniqueId）
pub fn unique_id(base: &str, used: &mut HashSet<String>) -> String {
    if used.insert(base.to_string()) {
        return base.to_string();
    }
    let mut n = 2usize;
    loop {
        let cand = format!("{base}-{n}");
        if used.insert(cand.clone()) {
            return cand;
        }
        n += 1;
    }
}

/// serde_json::Value 取字符串（对应 JS 的 String(x.k)）
fn jstr(v: &serde_json::Value, key: &str) -> String {
    match v.get(key) {
        Some(serde_json::Value::String(s)) => s.clone(),
        Some(serde_json::Value::Number(n)) => n.to_string(),
        Some(serde_json::Value::Bool(b)) => b.to_string(),
        _ => String::new(),
    }
}

fn nonempty(s: String) -> Option<String> {
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

fn contains_ci(hay: &str, needle: &str) -> bool {
    hay.to_lowercase().contains(&needle.to_lowercase())
}

// ═══════════════════════════════════════════════════════════════════════
//  配置解析（纯函数，可单测）
// ═══════════════════════════════════════════════════════════════════════

/// 一个待探测的 type=1 站点
#[derive(Debug, Clone)]
pub struct SiteJob {
    /// 在 sites 数组里的下标（决定 id 兜底序号）
    pub index: usize,
    /// sites[] 里的 key —— 更新对比时用来认出「还是同一个站」
    ///
    /// ⚠️ 可能为空（有些配置只写 name）—— 空 key 在 diff_sites 里退化为按 api 配对。
    pub key: String,
    pub name: String,
    pub api: String,
    /// 原始 type（仅用于报告）
    pub kind: Option<i64>,
}

fn site_type(v: &serde_json::Value) -> Option<i64> {
    match v.get("type") {
        Some(serde_json::Value::Number(n)) => n.as_i64(),
        Some(serde_json::Value::String(s)) => s.trim().parse::<i64>().ok(),
        _ => None,
    }
}

/// 不支持的类型说明（对应 TYPE_DESC）
pub fn skip_reason(kind: Option<i64>) -> String {
    match kind {
        Some(1) => "苹果CMS（可转换）".to_string(),
        Some(3) => "spider（Java JAR / drpy JS）—— 需要 Java 运行时，本项目不支持".to_string(),
        Some(0) => "纯 JSON API（各家格式不同，需要手工适配）".to_string(),
        Some(4) => "其它（非标准协议）".to_string(),
        Some(n) => format!("未知类型 type={n}"),
        None => "配置未声明 type".to_string(),
    }
}

/// 扫描配置：挑出 type=1 的站点，其余分类归档
///
/// 返回值：(待探测站点, 跳过清单, 直播源清单)
pub fn collect_sites(
    cfg: &serde_json::Value,
    base_url: &str,
) -> (
    Vec<SiteJob>,
    Vec<serde_json::Value>,
    Vec<serde_json::Value>,
) {
    let mut jobs = Vec::new();
    let mut skipped = Vec::new();
    let sites = cfg
        .get("sites")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    for (i, s) in sites.iter().enumerate() {
        let raw_name = {
            let n = jstr(s, "name");
            if n.is_empty() {
                let k = jstr(s, "key");
                if k.is_empty() {
                    "TVBox 源".to_string()
                } else {
                    k
                }
            } else {
                n
            }
        };
        let kind = site_type(s);
        let raw_api = jstr(s, "api");
        let api = if base_url.is_empty() {
            raw_api.clone()
        } else {
            resolve_api(&raw_api, base_url).unwrap_or(raw_api.clone())
        };
        if kind == Some(1) {
            jobs.push(SiteJob {
                index: i,
                key: jstr(s, "key"),
                name: raw_name,
                api,
                kind,
            });
        } else {
            skipped.push(serde_json::json!({
                "name": raw_name,
                "type": kind,
                "stage": "type",
                "reason": skip_reason(kind),
            }));
        }
    }
    let lives = cfg
        .get("lives")
        .and_then(|v| v.as_array())
        .map(|a| {
            a.iter()
                .map(|l| {
                    serde_json::json!({
                        "name": jstr(l, "name"),
                        "url": jstr(l, "url"),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    (jobs, skipped, lives)
}

// ═══════════════════════════════════════════════════════════════════════
//  探测（联网）
// ═══════════════════════════════════════════════════════════════════════

#[derive(Debug, Clone)]
pub struct ProbeOk {
    pub classes: Vec<TvboxCategoryEntry>,
    pub total: u64,
}

pub fn probe_client() -> reqwest::Client {
    reqwest::Client::builder()
        .user_agent(TVBOX_UA)
        .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
        .build()
        .expect("build tvbox http client")
}

async fn get_text_with(
    client: &reqwest::Client,
    url: &str,
) -> std::result::Result<String, String> {
    let resp = client
        .get(url)
        .header(reqwest::header::USER_AGENT, TVBOX_UA)
        // ★ 必须显式带 Accept（reqwest 默认**不发**这个头）
        //
        // 实测（2026-10-04）：不带 Accept 请求 https://tv.xn--yhqu5zs87a.top 时，
        // 站点返回的是**下载页 HTML**（13.5KB，<title>FongMi - 影视APP - 下载</title>）
        // 而不是同一 URL 的配置 JSON（18.5KB）—— 站点按 Accept 做了内容协商。
        // 表现为「明明在浏览器/其它客户端里是 JSON，我们这边说不是合法 JSON」。
        .header(reqwest::header::ACCEPT, "*/*")
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = resp.status();
    let text = resp.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(format!("HTTP {}", status.as_u16()));
    }
    Ok(text)
}

/// 探测一个苹果CMS接口是否可用（对应 probeAppleCms）
///
/// 两道关：分类接口要能出 class，列表接口要能出 list。
/// 只有都通过才认为可用 —— 只看分类会放进一堆「有分类但没内容」的死站。
pub async fn probe_apple_cms(
    client: &reqwest::Client,
    api: &str,
) -> std::result::Result<ProbeOk, String> {
    let base = normalize_api_url(api);
    if base.is_empty() {
        return Err("接口地址为空".to_string());
    }
    let list_url = format!("{base}?ac=list");
    let text = get_text_with(client, &list_url)
        .await
        .map_err(|e| format!("分类接口 {e}"))?;
    let j = parse_loose_json(&text).map_err(|_| "分类响应不是 JSON".to_string())?;
    let classes: Vec<TvboxCategoryEntry> = j
        .get("class")
        .and_then(|v| v.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|c| {
                    let id = jstr(c, "type_id");
                    if id.is_empty() {
                        return None;
                    }
                    Some(TvboxCategoryEntry {
                        id,
                        name: jstr(c, "type_name"),
                        pid: pid_of(c),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    if classes.is_empty() {
        return Err("分类为空".to_string());
    }

    let video_url = format!("{base}?ac=videolist&pg=1");
    let vtext = get_text_with(client, &video_url)
        .await
        .map_err(|e| format!("列表接口 {e}"))?;
    let vj = parse_loose_json(&vtext).map_err(|_| "列表响应不是 JSON".to_string())?;
    let list = vj
        .get("list")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    if list.is_empty() {
        return Err("列表为空".to_string());
    }
    let total = vj.get("total").and_then(|v| v.as_u64()).unwrap_or(0);
    Ok(ProbeOk { classes, total })
}

/// type_pid：null / 0 表示没有父类
fn pid_of(c: &serde_json::Value) -> Option<String> {
    match c.get("type_pid") {
        None | Some(serde_json::Value::Null) => None,
        Some(serde_json::Value::Number(n)) => {
            if n.as_i64() == Some(0) {
                None
            } else {
                Some(n.to_string())
            }
        }
        Some(serde_json::Value::String(s)) => {
            if s.is_empty() || s == "0" {
                None
            } else {
                Some(s.clone())
            }
        }
        _ => None,
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Provider
// ═══════════════════════════════════════════════════════════════════════

pub struct TvboxAppleCmsProvider {
    manifest: ProviderManifest,
    /// 已归一化的接口地址
    api: String,
    classes: Vec<TvboxCategoryEntry>,
    client: reqwest::Client,
    proxy: Option<Arc<crate::proxy::ProxyStore>>,
}

impl TvboxAppleCmsProvider {
    pub fn new(
        id: impl Into<String>,
        name: impl Into<String>,
        api: &str,
        classes: Vec<TvboxCategoryEntry>,
    ) -> std::result::Result<Self, String> {
        let id = id.into();
        let name = name.into();
        let api = normalize_api_url(api);
        if id.is_empty() {
            return Err("源 id 为空".to_string());
        }
        if api.is_empty() {
            return Err("接口地址为空".to_string());
        }
        if !starts_http(&api) {
            return Err(format!("接口地址不是 http(s)：{api}"));
        }
        let client = reqwest::Client::builder()
            .user_agent(TVBOX_UA)
            .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
            .build()
            .map_err(|e| format!("HTTP 客户端创建失败：{e}"))?;
        let capabilities = Capabilities {
            vod: true,
            search: true,
            ..Default::default()
        };
        let manifest = ProviderManifest {
            id,
            name,
            version: "1.0.0".to_string(),
            // ★ 与 js / declarative / http 并列的第四种来源类型
            kind: "tvbox".to_string(),
            description: Some(format!("由 TVBox 配置导入（苹果CMS v10）：{api}")),
            icon: None,
            id_prefixes: Vec::new(),
            capabilities,
            cover_headers: vec![("User-Agent".to_string(), TVBOX_UA.to_string())],
            config: Vec::new(),
            api_version: 1,
            theme_color: None,
            working: true,
            broken_reason: None,
            enabled: None,
        };
        Ok(Self {
            manifest,
            api,
            classes,
            client,
            proxy: None,
        })
    }

    /// ★ 固有方法（**不是** trait 方法）—— 照抄 HttpProvider 的写法
    pub fn with_proxy(mut self, proxy: Arc<crate::proxy::ProxyStore>) -> Self {
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

    async fn get_text(&self, url: &str) -> Result<String> {
        let resp = self
            .http()
            .get(url)
            .header(reqwest::header::USER_AGENT, TVBOX_UA)
            .send()
            .await
            .map_err(|e| ProviderError::network(format!("请求失败：{e}")))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| ProviderError::network(format!("读取响应失败：{e}")))?;
        if !status.is_success() {
            let head: String = text.chars().take(160).collect();
            return Err(ProviderError::network(format!(
                "HTTP {}：{head}",
                status.as_u16()
            )));
        }
        Ok(text)
    }

    async fn get_json(&self, url: &str) -> Result<serde_json::Value> {
        let text = self.get_text(url).await?;
        parse_loose_json(&text)
            .map_err(|e| ProviderError::parse(format!("接口返回的不是 JSON —— {e}")))
    }

    fn to_item(&self, x: &serde_json::Value) -> MediaItem {
        MediaItem {
            id: MediaId::new(&self.manifest.id, jstr(x, "vod_id")),
            title: jstr(x, "vod_name"),
            cover: nonempty(jstr(x, "vod_pic")),
            subtitle: nonempty(jstr(x, "vod_remarks")),
            badges: Vec::new(),
            kind: MediaKind::Movie,
            description: nonempty(strip_tags(&jstr(x, "vod_blurb"))),
        }
    }

    fn items_of(&self, j: &serde_json::Value) -> Vec<MediaItem> {
        j.get("list")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().map(|x| self.to_item(x)).collect())
            .unwrap_or_default()
    }

    fn page_of(&self, j: &serde_json::Value, items: Vec<MediaItem>, page: u32) -> Page<MediaItem> {
        let page_count = j
            .get("pagecount")
            .and_then(|v| v.as_u64())
            .unwrap_or(1)
            .max(1) as u32;
        let total = j.get("total").and_then(|v| v.as_u64()).unwrap_or(0);
        Page {
            items,
            page,
            page_count: Some(page_count),
            total: Some(total),
        }
    }

    /// Referer = 接口地址去掉 /api.php 及其后的部分 + /
    fn referer(&self) -> String {
        match self.api.find("/api.php") {
            Some(i) => format!("{}/", &self.api[..i]),
            None => format!("{}/", self.api.trim_end_matches('/')),
        }
    }

    /// 依次试第三方解析服务（对应 tryParsers）
    ///
    /// ★ 任何一个环节出错都 **continue** 而不是抛出 —— 解析服务挂掉是常态，
    /// 不该让整次播放解析崩在这里。
    async fn try_parsers(&self, page_url: &str) -> Option<String> {
        self.try_parsers_with(page_url, &PARSE_SERVICES).await
    }

    /// 与 [`Self::try_parsers`] 完全相同，只是解析服务前缀由调用方给出。
    ///
    /// ★ 存在的唯一理由：`PARSE_SERVICES` 是编译期常量、指向公网。测试要覆盖
    /// 「解析服务失败就 continue」这条分支，必须能把前缀换成 127.0.0.1 上的假解析服务。
    /// 生产路径只有 `try_parsers` 一个入口，行为与重构前逐字节一致。
    async fn try_parsers_with(&self, page_url: &str, bases: &[&str]) -> Option<String> {
        for base in bases.iter() {
            let u = format!("{}{}", base, urlencoding::encode(page_url));
            let text = match self.get_text(&u).await {
                Ok(t) => t,
                Err(e) => {
                    log::debug!("解析服务 {base} 失败（换下一个）：{}", e.message);
                    continue;
                }
            };
            if text.is_empty() {
                continue;
            }
            let mut found = match parse_loose_json(&text) {
                Ok(j) => json_parse_url(&j),
                Err(_) => first_media_url(&text),
            };
            if found.is_none() {
                // JSON 解析成功但里面没有可用字段时，再从原文里挖一次
                found = first_media_url(&text);
            }
            let f = match found {
                Some(f) if !f.is_empty() => f,
                _ => continue,
            };
            if contains_ci(&f, "error")
                || contains_ci(&f, "placeholder")
                || contains_ci(&f, "default.mp4")
            {
                continue;
            }
            let f = if f.starts_with('/') {
                match split_origin(base) {
                    Some((_, origin)) => format!("{origin}{f}"),
                    None => continue,
                }
            } else {
                f
            };
            if !starts_http(&f) {
                continue;
            }
            return Some(f);
        }
        None
    }
}

/// 从解析服务返回的 JSON 里取地址（对应 j.url || j.m3u8 || j.data?.url ...）
fn json_parse_url(j: &serde_json::Value) -> Option<String> {
    for k in ["url", "m3u8"] {
        if let Some(s) = j.get(k).and_then(|v| v.as_str()) {
            if !s.is_empty() {
                return Some(s.to_string());
            }
        }
    }
    if let Some(d) = j.get("data") {
        for k in ["url", "m3u8", "playUrl"] {
            if let Some(s) = d.get(k).and_then(|v| v.as_str()) {
                if !s.is_empty() {
                    return Some(s.to_string());
                }
            }
        }
        if let Some(s) = d.as_str() {
            if starts_http(s) {
                return Some(s.to_string());
            }
        }
    }
    None
}

/// 从文本里挖第一个媒体地址（解析服务返回非 JSON 时的兜底）
fn first_media_url(text: &str) -> Option<String> {
    let mut from = 0usize;
    while from < text.len() {
        let rel = match text[from..].find("http") {
            Some(r) => r,
            None => return None,
        };
        let start = from + rel;
        let rest = &text[start..];
        if rest.starts_with("http://") || rest.starts_with("https://") {
            let end = rest
                .find(|c: char| {
                    c.is_whitespace() || c == '"' || c == '\'' || c == '<' || c == '>' || c == ')'
                })
                .unwrap_or(rest.len());
            let tok = &rest[..end];
            let low = tok.to_lowercase();
            if low.contains(".m3u8") || low.contains(".mp4") || low.contains(".flv") {
                return Some(tok.to_string());
            }
            from = start + end.max(1);
        } else {
            from = start + 4;
        }
    }
    None
}

#[async_trait]
impl MediaProvider for TvboxAppleCmsProvider {
    fn manifest(&self) -> &ProviderManifest {
        &self.manifest
    }

    async fn home(&self) -> Result<Vec<Section>> {
        Ok(self
            .classes
            .iter()
            .take(HOME_SECTIONS)
            .map(|c| Section {
                id: format!("{}-{}", self.manifest.id, c.id),
                title: c.name.clone(),
                source: SectionSource::Category {
                    category_id: c.id.clone(),
                },
                items: Vec::new(),
            })
            .collect())
    }

    async fn categories(&self) -> Result<Vec<Category>> {
        Ok(self
            .classes
            .iter()
            .map(|c| Category {
                id: c.id.clone(),
                name: c.name.clone(),
                children: Vec::new(),
            })
            .collect())
    }

    async fn list(&self, req: ListRequest) -> Result<Page<MediaItem>> {
        let page = if req.page == 0 { 1 } else { req.page };
        let cat = req.category_id.clone();

        // ① 服务端认 t= 就直接用（一次请求搞定）
        let first_url = format!(
            "{}?ac=videolist&t={}&pg={}",
            self.api,
            urlencoding::encode(&cat),
            page
        );
        let first = self.get_json(&first_url).await;
        if let Ok(j) = &first {
            let items = self.items_of(j);
            if !items.is_empty() {
                return Ok(self.page_of(j, items, page));
            }
        } else if let Err(e) = &first {
            log::debug!(
                "TVBox 源 {} 带分类参数取列表失败：{}",
                self.manifest.id, e.message
            );
        }

        // ② 服务端不认 t= → 客户端按分类过滤（两级：子类 type_id / 父类 type_id_1）
        //
        // ★★ 极端兜底**返回空列表**，绝不退回「全站最新」——
        //    那正是「所有分类点进去数据一模一样」这个 bug 的根源。
        let mut picked: Vec<serde_json::Value> = Vec::new();
        let mut scanned = 0u32;
        let mut last_page_count = 1u32;
        let mut scan_err: Option<ProviderError> = None;
        for p in 1..=SCAN_MAX_PAGES {
            if picked.len() >= SCAN_MAX_ITEMS {
                break;
            }
            let u = format!("{}?ac=videolist&pg={}", self.api, p);
            match self.get_json(&u).await {
                Ok(jj) => {
                    scanned = p;
                    last_page_count = jj
                        .get("pagecount")
                        .and_then(|v| v.as_u64())
                        .unwrap_or(1)
                        .max(1) as u32;
                    let list = jj
                        .get("list")
                        .and_then(|v| v.as_array())
                        .cloned()
                        .unwrap_or_default();
                    if list.is_empty() {
                        break;
                    }
                    for it in list {
                        let hit = jstr(&it, "type_id") == cat || jstr(&it, "type_id_1") == cat;
                        if hit
                            && !picked
                                .iter()
                                .any(|x| jstr(x, "vod_id") == jstr(&it, "vod_id"))
                        {
                            picked.push(it);
                        }
                    }
                    if p >= last_page_count {
                        break;
                    }
                }
                Err(e) => {
                    scan_err = Some(e);
                    break;
                }
            }
        }
        if scanned == 0 {
            // 扫描第一页就失败：如实抛出（优先用带 t= 那次的原因）
            if let Err(e) = first {
                return Err(e);
            }
            if let Some(e) = scan_err {
                return Err(e);
            }
        }
        let page_count = ((last_page_count as f64 / scanned.max(1) as f64).ceil() as u32).max(1);
        let items: Vec<MediaItem> = picked.iter().map(|x| self.to_item(x)).collect();
        Ok(Page {
            items,
            page,
            page_count: Some(page_count),
            total: Some(picked.len() as u64),
        })
    }

    async fn search(&self, keyword: &str, page: u32) -> Result<Page<MediaItem>> {
        let page = if page == 0 { 1 } else { page };
        let url = format!(
            "{}?ac=videolist&wd={}&pg={}",
            self.api,
            urlencoding::encode(keyword),
            page
        );
        let j = self.get_json(&url).await?;
        let items = self.items_of(&j);
        Ok(self.page_of(&j, items, page))
    }

    async fn detail(&self, id: &MediaId) -> Result<MediaDetail> {
        let native = id.native.clone();
        let url = format!(
            "{}?ac=videolist&ids={}",
            self.api,
            urlencoding::encode(&native)
        );
        let j = self.get_json(&url).await?;
        let d = j
            .get("list")
            .and_then(|v| v.as_array())
            .and_then(|a| a.first())
            .cloned()
            .ok_or_else(|| {
                ProviderError::new(ErrorKind::NotFound, "取不到详情（上游没有返回这个条目）")
            })?;

        // vod_play_url 可能有多组线路（$$$ 分隔）—— 与转换器一致，只取第一组
        let play = jstr(&d, "vod_play_url");
        let first_group = play.split("$$$").next().unwrap_or("").to_string();
        let eps = parse_episodes(&first_group);
        let episodes: Vec<Episode> = eps
            .iter()
            .enumerate()
            .map(|(i, (nm, u))| Episode {
                id: u.clone(),
                title: if nm.is_empty() {
                    format!("第{}集", i + 1)
                } else {
                    nm.clone()
                },
                order: (i + 1) as u32,
                player_id: None,
            })
            .collect();

        let vid = {
            let v = jstr(&d, "vod_id");
            if v.is_empty() {
                native.clone()
            } else {
                v
            }
        };
        let desc_src = {
            let c = jstr(&d, "vod_content");
            if c.is_empty() {
                jstr(&d, "vod_blurb")
            } else {
                c
            }
        };
        Ok(MediaDetail {
            id: MediaId::new(&self.manifest.id, vid),
            title: jstr(&d, "vod_name"),
            cover: nonempty(jstr(&d, "vod_pic")),
            description: nonempty(strip_tags(&desc_src)),
            badges: Vec::new(),
            kind: MediaKind::Movie,
            meta: serde_json::Map::new(),
            // ★ 字段名是 title 不是 name
            sources: vec![PlaySource {
                code: "default".to_string(),
                title: self.manifest.name.clone(),
                count: episodes.len() as u32,
                nested: Vec::new(),
            }],
            episodes,
        })
    }

    async fn resolve(&self, id: &MediaId, _req: &PlayRequest) -> Result<Vec<StreamCandidate>> {
        let mut url = id.native.clone();

        // ① 不是 URL → 当成条目 id，去取详情拿第一集
        if !starts_http(&url) {
            let d = self
                .detail(&MediaId::new(&self.manifest.id, url.clone()))
                .await?;
            let first = d.episodes.first().ok_or_else(|| {
                ProviderError::new(ErrorKind::NotFound, "这个条目没有可播放的剧集")
            })?;
            url = first.id.clone();
        }

        // ② 不是 m3u8 → 先当网页找 m3u8，找不到再上第三方解析
        if !url.to_lowercase().contains(".m3u8") {
            let page_url = url.clone();
            let mut found = match self.get_text(&page_url).await {
                Ok(html) => extract_m3u8(&html, &page_url),
                Err(e) => {
                    log::debug!("取播放页失败（继续试解析服务）：{}", e.message);
                    None
                }
            };
            if found.is_none() {
                found = self.try_parsers(&page_url).await;
            }
            match found {
                Some(u) => url = u,
                None => {
                    let is_third_party = [
                        "iqiyi.", "youku", "qq.com", "mgtv", "bilibili", "le.com", "sohu",
                    ]
                    .iter()
                    .any(|k| contains_ci(&page_url, k));
                    let msg = if is_third_party {
                        "这个源只提供爱奇艺/优酷等站点的网页链接，需要在线解析服务才能播放（当前所有解析接口都不可用）"
                    } else {
                        "这个源没有可直接播放的地址（可能需要专用解析）"
                    };
                    return Err(ProviderError::new(ErrorKind::Unsupported, msg));
                }
            }
        }

        // ③ kind：只有明确的媒体文件才判 mp4，其余一律 hls
        let lower = {
            let s = url.split('?').next().unwrap_or(&url);
            let s = s.split('#').next().unwrap_or(s);
            s.to_lowercase()
        };
        let is_direct = [".mp4", ".mkv", ".mov", ".avi", ".webm", ".flv", ".m4v"]
            .iter()
            .any(|e| lower.ends_with(e));
        let kind = if is_direct {
            StreamKind::Mp4
        } else {
            StreamKind::Hls
        };
        let headers = vec![
            ("User-Agent".to_string(), TVBOX_UA.to_string()),
            ("Referer".to_string(), self.referer()),
        ];
        Ok(vec![StreamCandidate::new(url, kind)
            .with_label(self.manifest.name.clone())
            .with_quality("自动")
            .with_headers(headers)])
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  导入入口
// ═══════════════════════════════════════════════════════════════════════

/// 导入 TVBox 配置
///
/// input 可以是**配置 JSON 文本**，也可以是**配置地址**（http/https）。
///
/// 流程：解析 → 分类（type=1 留，其余归档）→ 并发探测 type=1 站点
/// → 可用的注册成 Provider 并持久化 → 返回导入报告。
pub async fn import_tvbox_config(
    state: &crate::state::AppState,
    input: &str,
) -> std::result::Result<serde_json::Value, String> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err("TVBox 配置内容为空".to_string());
    }

    // 允许直接贴配置地址
    let (text, base_url) = if starts_http(trimmed) && !trimmed.starts_with('{') {
        let client = probe_client();
        let t = fetch_config_text(&client, trimmed)
            .await
            .map_err(|e| format!("下载配置失败（{trimmed}）：{e}"))?;
        (t, trimmed.to_string())
    } else {
        (trimmed.to_string(), String::new())
    };

    let cfg = parse_loose_json(&text).map_err(|e| format!("配置不是合法 JSON：{e}"))?;

    // 多仓配置：只有 urls，没有 sites
    //
    // ★ task-12 改了这里：原来是直接 Err（把子仓清单塞进错误文案里），
    //   现在是**结构化返回** {multiRepo:true, repos:[...]} —— 界面据此
    //   列出子仓供用户选一个继续导入，而不是让用户自己从一段红字错误里
    //   抠链接。
    //   ```text
    //   旧：弹一个红字错误框，里面是「请打开其中某个子仓…· 名称 链接」
    //   新：正常面板里列出「子仓」清单，每条可点（界面把它的链接填回输入框）
    //   ```
    //   ⚠️ 仍然**不会**把多仓当成可导入的配置（那是假装有能力）——
    //      只是把「转不了」说清楚，并给出下一步能用的东西。
    if cfg.get("sites").and_then(|v| v.as_array()).is_none() {
        let repos = multi_repo_repos(&cfg, &base_url);
        if !repos.is_empty() {
            return Ok(serde_json::json!({
                "totalSites": 0,
                "imported": [],
                "skipped": [],
                "lives": [],
                "multiRepo": true,
                "repos": repos,
            }));
        }
        return Err("配置里没有 sites 段（这可能是直播源配置或空配置）".to_string());
    }

    let (jobs, mut skipped, lives) = collect_sites(&cfg, &base_url);
    if jobs.is_empty() {
        return Ok(serde_json::json!({
            "totalSites": cfg.get("sites").and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0),
            "imported": [],
            "skipped": skipped,
            "lives": lives,
        }));
    }

    // ── 并发探测（保序：结果按下标回填，保证 id 生成稳定）────────────
    let client = probe_client();
    let sem = Arc::new(tokio::sync::Semaphore::new(MAX_PROBE_CONCURRENCY));
    let mut results: Vec<Option<std::result::Result<ProbeOk, String>>> =
        (0..jobs.len()).map(|_| None).collect();
    let mut set = tokio::task::JoinSet::new();
    for (idx, job) in jobs.iter().enumerate() {
        let client = client.clone();
        let sem = sem.clone();
        let api = job.api.clone();
        set.spawn(async move {
            let _permit = sem.acquire_owned().await;
            (idx, probe_apple_cms(&client, &api).await)
        });
    }
    while let Some(joined) = set.join_next().await {
        match joined {
            Ok((idx, r)) => results[idx] = Some(r),
            Err(e) => log::warn!("TVBox 探测任务异常退出：{e}"),
        }
    }

    // ── 生成 Provider 并注册 ────────────────────────────────────────
    //
    // used 预置**已存在的非 tvbox 源 id**：避免 TVBox 源顶掉同名插件；
    // 上一次导入的 tvbox 源不预置 —— 重复导入同一份配置要能原地覆盖。
    let mut used: HashSet<String> = state
        .registry
        .manifests()
        .iter()
        .filter(|m| m.kind != "tvbox")
        .map(|m| m.id.clone())
        .collect();
    let mut imported: Vec<serde_json::Value> = Vec::new();
    let mut to_persist: Vec<crate::model::PersistedProvider> = Vec::new();
    // (源 id, site key, 名称, 接口) —— 只用于落盘订阅来源
    let mut meta_rows: Vec<(String, String, String, String)> = Vec::new();
    for (idx, job) in jobs.iter().enumerate() {
        let ok = match results.get_mut(idx).and_then(|x| x.take()) {
            Some(Ok(ok)) => ok,
            Some(Err(reason)) => {
                skipped.push(serde_json::json!({
                    "name": job.name,
                    "type": job.kind,
                    "stage": "probe",
                    "reason": reason,
                }));
                continue;
            }
            None => {
                skipped.push(serde_json::json!({
                    "name": job.name,
                    "type": job.kind,
                    "stage": "probe",
                    "reason": "探测任务异常",
                }));
                continue;
            }
        };
        let id = unique_id(&to_id(&job.name, &job.api, job.index), &mut used);
        let provider =
            TvboxAppleCmsProvider::new(id.clone(), job.name.clone(), &job.api, ok.classes.clone())
                .map_err(|e| format!("生成源「{}」失败：{e}", job.name))?;
        let manifest = MediaProvider::manifest(&provider).clone();
        state
            .registry
            .register(Arc::new(provider.with_proxy(state.proxy.clone())));
        to_persist.push(crate::model::PersistedProvider::Tvbox {
            id: id.clone(),
            name: manifest.name.clone(),
            api: normalize_api_url(&job.api),
            categories: ok.classes.clone(),
        });
        imported.push(serde_json::json!({
            "id": id,
            "name": manifest.name,
            "api": normalize_api_url(&job.api),
            "categories": ok.classes.len(),
            "total": ok.total,
        }));
        // 记下 (id, site key, 名称, 接口) —— 落盘订阅来源时要用（见下）
        meta_rows.push((
            id.clone(),
            job.key.clone(),
            job.name.clone(),
            normalize_api_url(&job.api),
        ));
    }

    // ── 持久化（重启后自动重建，不需要重新联网探测）──────────────────
    if !to_persist.is_empty() {
        {
            let mut list = state
                .third_party
                .write()
                .map_err(|_| "第三方源列表被污染".to_string())?;
            for p in to_persist {
                let pid = p.id().to_string();
                list.retain(|x| x.id() != pid);
                list.push(p);
            }
        }
        crate::commands_provider::persist_from_registry(state)?;
        // 标记改动时间：云同步据此判断「本地是新的」
        crate::commands_provider::touch_providers(state);
    }

    // ── 记下「这些源是从哪来的」（task-12）───────────────────────────
    //
    // ★ 与插件侧的 plugins/.meta/<id>.json 对称，但有一条**关键区别**：
    //   ```text
    //   插件：没链接 → 什么都不记（也就没有 site key 可言）
    //   TVBox：没链接 → 仍然记 site key / 名称 / 接口，只是 source_url = None
    //   ```
    //   为什么必须记：site key 是**导入那一刻就知道**的事实（来自 sites[]），
    //   与"有没有链接"无关。如果贴文本导入时不记，用户事后用
    //   set_tvbox_source 补上链接，配对就只能退化成按 api 认 ——
    //   而"站换了域名"恰恰是最需要靠 key 认出来的情况。
    //   → 表现为：补完链接后第一次检测，明明只是换了域名，却被报成
    //     「新增一个 + 消失一个」，用户点了更新就会多出一个重复的源。
    //
    // ⚠️ 写 sidecar 失败**不让整次导入失败**（源已经注册好、能用了）——
    //    但必须留日志，不能静默吞掉。
    if !meta_rows.is_empty() {
        let src = if base_url.is_empty() {
            None
        } else {
            Some(base_url.clone())
        };
        for (id, key, name, api) in meta_rows.iter() {
            let meta = TvboxSourceMeta {
                source_url: src.clone(),
                site_key: key.clone(),
                site_name: name.clone(),
                api: api.clone(),
                installed_at: now_secs(),
            };
            if let Err(e) = write_tvbox_meta(&state.data_dir, id, &meta) {
                log::warn!("记录 TVBox 订阅来源失败（{id}）：{e}");
            }
        }
    }

    log::info!(
        "TVBox 配置导入完成：{} 个源可用，{} 条跳过，{} 个直播源未导入",
        imported.len(),
        skipped.len(),
        lives.len()
    );
    Ok(serde_json::json!({
        "totalSites": cfg.get("sites").and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0),
        "imported": imported,
        "skipped": skipped,
        "lives": lives,
    }))
}

// ═══════════════════════════════════════════════════════════════════════
//  订阅链接 + 检测更新（task-12）
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话：
// > 填入 tvbox 源的链接，然后他有更新我们也能收得到，不至于更新失效了
//
// # 与插件那套（plugins/.meta/<id>.json）同构，只差一处
//
// ```text
// 插件    1 个 .js   ↔ 1 个安装链接 → 一个 id 一个 sidecar 文件
// TVBox   1 份配置   ↔ 1 个订阅链接 → 一份配置产出几十个源
//                                    → sidecar 是单文件 map {id: meta}
// ```
//
// 96 个站点写 96 个文件会把数据目录炸掉，所以这里用单文件 map。
//
// # ★★ 产品原则（与 commands_provider.rs 里插件那套同一条）：没有的能力不假装有
//
// ```text
// 直接贴 JSON 文本导入的源 → 没有链接可查
//   → list_tvbox_sources 里 needsSource = true
//   → 界面不显示「检测更新」按钮，只如实说明「无订阅链接」
//   → 绝不显示成「已是最新」（那是假装查过了）
// ```
//
// 用户可以用 set_tvbox_source 事后补一个链接 —— 与插件侧的
// set_plugin_source 对称，同样是真实功能而不是测试开关。

/// 一个 TVBox 源的「订阅来源」sidecar 条目
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TvboxSourceMeta {
    /// 当初导入它的配置链接（None = 贴文本导入的，没有源可查）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_url: Option<String>,
    /// 站点在配置 sites[] 里的 key —— 更新时用来认出「还是同一个站」
    #[serde(default)]
    pub site_key: String,
    #[serde(default)]
    pub site_name: String,
    /// 导入时的接口地址（已归一化）
    #[serde(default)]
    pub api: String,
    /// Unix 秒
    #[serde(default)]
    pub installed_at: i64,
}

/// sidecar 的磁盘形态（带版本号，将来能迁移）
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct TvboxMetaFile {
    #[serde(default = "tvbox_meta_version")]
    version: u32,
    #[serde(default)]
    sources: std::collections::HashMap<String, TvboxSourceMeta>,
}

fn tvbox_meta_version() -> u32 {
    1
}

/// `<data_dir>/tvbox-sources.json`
pub fn tvbox_meta_file(dir: &std::path::Path) -> std::path::PathBuf {
    dir.join("tvbox-sources.json")
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// 读全部订阅来源
///
/// # 容错（与 plugins 的 read_plugin_meta 同一条）
///
/// ```text
/// 文件不存在  → 空 map（从没导入过的正常状态，不是错误）
/// JSON 坏了   → 空 map + 警告日志（不能因为一个坏文件就让设置页打不开）
/// ```
///
/// ⚠️ 一律不返回 Err：调用方要能无条件列出全部 TVBox 源，
///    缺 sidecar 只是「查不了更新」，不该让整个列表失败。
pub fn load_tvbox_metas(
    dir: &std::path::Path,
) -> std::collections::HashMap<String, TvboxSourceMeta> {
    let p = tvbox_meta_file(dir);
    let Ok(raw) = std::fs::read_to_string(&p) else {
        return std::collections::HashMap::new();
    };
    match serde_json::from_str::<TvboxMetaFile>(&raw) {
        Ok(m) => m.sources,
        Err(e) => {
            log::warn!("TVBox 订阅 sidecar 解析失败（忽略，当作没有链接）: {p:?}: {e}");
            std::collections::HashMap::new()
        }
    }
}

/// 读某个源的订阅来源（没有 → None，不是错误）
pub fn read_tvbox_meta(dir: &std::path::Path, id: &str) -> Option<TvboxSourceMeta> {
    load_tvbox_metas(dir).remove(id)
}

/// 原子写回整份 map（先写 .tmp 再 rename —— 与 persist::save_persisted 同一手法）
fn save_tvbox_metas(
    dir: &std::path::Path,
    map: &std::collections::HashMap<String, TvboxSourceMeta>,
) -> std::result::Result<(), String> {
    let p = tvbox_meta_file(dir);
    let tmp = p.with_extension("json.tmp");
    let body = serde_json::to_string_pretty(&TvboxMetaFile {
        version: tvbox_meta_version(),
        sources: map.clone(),
    })
    .map_err(|e| format!("序列化订阅 sidecar 失败: {e}"))?;
    std::fs::write(&tmp, body).map_err(|e| format!("写入订阅 sidecar 临时文件失败: {e}"))?;
    std::fs::rename(&tmp, &p).map_err(|e| format!("替换订阅 sidecar 失败: {e}"))
}

/// 写/覆盖某个源的订阅来源（自动建目录）
pub fn write_tvbox_meta(
    dir: &std::path::Path,
    id: &str,
    meta: &TvboxSourceMeta,
) -> std::result::Result<(), String> {
    if id.is_empty() {
        return Err("源 id 为空，无法记录订阅链接".to_string());
    }
    std::fs::create_dir_all(dir).map_err(|e| format!("创建数据目录失败: {e}"))?;
    let mut map = load_tvbox_metas(dir);
    map.insert(id.to_string(), meta.clone());
    save_tvbox_metas(dir, &map)
}

/// 忘掉某个源的订阅来源（源被移除时调用）
///
/// ⚠️ 幂等：没有这个 id / 文件不存在都算成功 —— 调用方不该为此写错误处理。
pub fn forget_tvbox_meta(dir: &std::path::Path, id: &str) -> std::result::Result<(), String> {
    let mut map = load_tvbox_metas(dir);
    if map.remove(id).is_none() {
        return Ok(());
    }
    save_tvbox_metas(dir, &map)
}

// ── 远端 vs 本地的站点差异 ─────────────────────────────────────────────

/// 远端配置里的一个可转换站点（type=1）
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteSite {
    pub key: String,
    pub name: String,
    pub api: String,
}

/// 本地已注册的 TVBox 源（对比用）
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalSite {
    pub id: String,
    pub key: String,
    pub name: String,
    pub api: String,
    /// 这个源是不是**当前这份订阅**导入的
    ///
    /// # ★ 为什么必须有这个标记（真实场景）
    ///
    /// 两份配置里有同一个站是常态（互相抄）。如果配对池只用"本订阅的源"：
    /// ```text
    /// 远端 A 里有「非凡」 → 本地已有（来自订阅 B）
    /// → 报成 added → 一键更新又注册一个一模一样的源
    /// → 用户看到两张「非凡」卡片
    /// ```
    /// 所以配对池要用**全部** TVBox 源。但反过来，"远端没有的站"只有在
    /// 它**属于本订阅**时才算 removed —— 否则订阅 A 的检测会把订阅 B
    /// 的源全报成"已消失"，用户一勾删除就误删。
    ///
    /// → 配对认全量，报 removed / 应用 changed 只认本订阅（in_link）。
    #[serde(skip_serializing)]
    pub in_link: bool,
}

/// 同一个站点但内容变了
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SiteChange {
    pub id: String,
    pub key: String,
    pub old_name: String,
    pub new_name: String,
    pub old_api: String,
    pub new_api: String,
}

/// 远端 vs 本地的差异
///
/// ⚠️ 不 derive Serialize：带下标（`*_idx`）的内部结构，对外由调用方自己组 JSON。
#[derive(Debug, Clone, Default)]
pub struct SiteDiff {
    /// 远端新增（本地没有）
    pub added: Vec<RemoteSite>,
    /// `added[i]` 在远端站点列表里的下标（探测要用）
    pub added_idx: Vec<usize>,
    /// 远端消失（本地还有）—— ★ 只报告，绝不自动删
    pub removed: Vec<LocalSite>,
    /// 同一个站但接口/名字变了
    pub changed: Vec<SiteChange>,
    /// `changed[i]` 在远端站点列表里的下标
    pub changed_idx: Vec<usize>,
    /// 完全没变的条数（**只算本订阅的**）
    pub unchanged: usize,
    /// 被认出来、但属于**别的订阅**的站（不算本订阅的 unchanged）
    pub unchanged_foreign: usize,
}

/// 对比远端站点列表与本地已注册的源（纯函数，可单测）
///
/// # 配对规则（顺序不能换）
///
/// ```text
/// ① 先按 site key 精确配对   —— 站改名/换域名时仍能认出「还是同一个站」
/// ② 剩下的按归一化 api 配对   —— 老数据没有 key 时的兜底
/// ③ 剩下 = 新增 / 消失
/// ```
///
/// ⚠️ api 比对用 normalize_api_url（剥 ? / # 、去尾斜杠）——
///    配置里常见 .../vod?ac=list 与 .../vod 混用，
///    不归一化会把同一个站报成「新增 + 消失」。
pub fn diff_sites(local: &[LocalSite], remote: &[RemoteSite]) -> SiteDiff {
    let mut used_remote = vec![false; remote.len()];
    let mut used_local = vec![false; local.len()];
    let mut diff = SiteDiff::default();

    // ① 按 key 配对
    for (li, l) in local.iter().enumerate() {
        if l.key.is_empty() {
            continue;
        }
        for (ri, r) in remote.iter().enumerate() {
            if used_remote[ri] || r.key != l.key {
                continue;
            }
            used_local[li] = true;
            used_remote[ri] = true;
            // 别的订阅导入的同名站：认出来（不再重复注册）但**不动它**
            if !l.in_link {
                diff.unchanged_foreign += 1;
                break;
            }
            if normalize_api_url(&r.api) != normalize_api_url(&l.api) || r.name != l.name {
                diff.changed.push(SiteChange {
                    id: l.id.clone(),
                    key: l.key.clone(),
                    old_name: l.name.clone(),
                    new_name: r.name.clone(),
                    old_api: l.api.clone(),
                    new_api: r.api.clone(),
                });
                diff.changed_idx.push(ri);
            } else {
                diff.unchanged += 1;
            }
            break;
        }
    }

    // ② 剩下的按归一化 api 配对（老数据没有 site key）
    for (li, l) in local.iter().enumerate() {
        if used_local[li] {
            continue;
        }
        let la = normalize_api_url(&l.api);
        if la.is_empty() {
            continue;
        }
        for (ri, r) in remote.iter().enumerate() {
            if used_remote[ri] || normalize_api_url(&r.api) != la {
                continue;
            }
            used_local[li] = true;
            used_remote[ri] = true;
            // 命中即算没变化（别的订阅的站同样不动）
            if l.in_link {
                diff.unchanged += 1;
            } else {
                diff.unchanged_foreign += 1;
            }
            break;
        }
    }

    // ③ 剩下的就是新增 / 消失
    for (ri, r) in remote.iter().enumerate() {
        if !used_remote[ri] {
            diff.added.push(r.clone());
            diff.added_idx.push(ri);
        }
    }
    for (li, l) in local.iter().enumerate() {
        // ★ 只有**本订阅**的源才可能算"远端已消失"——
        //   否则订阅 A 的检测会把订阅 B 的源全报成消失。
        if !used_local[li] && l.in_link {
            diff.removed.push(l.clone());
        }
    }
    diff
}

/// 从一份（可能是多仓的）配置里取子仓列表 —— 纯函数
///
/// `urls` 在野外有两种形态：对象数组 `{name,url}` 与纯字符串数组。
/// 两种都收，相对地址按 `base_url` 补全。
pub fn multi_repo_repos(cfg: &serde_json::Value, base_url: &str) -> Vec<serde_json::Value> {
    let Some(arr) = cfg.get("urls").and_then(|v| v.as_array()) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for u in arr.iter().take(50) {
        let (name, url) = match u {
            serde_json::Value::String(s) => (String::new(), s.clone()),
            other => (jstr(other, "name"), jstr(other, "url")),
        };
        if url.trim().is_empty() {
            continue;
        }
        let abs = if base_url.is_empty() {
            url.trim().to_string()
        } else {
            absolutize(&url, base_url)
        };
        out.push(serde_json::json!({
            "name": if name.trim().is_empty() { abs.clone() } else { name.trim().to_string() },
            "url": abs,
        }));
    }
    out
}

/// 从本地已注册的源里挑出 TVBox 源（id / name / api）
fn local_tvbox_sources(
    state: &crate::state::AppState,
) -> std::result::Result<Vec<(String, String, String)>, String> {
    let list = state
        .third_party
        .read()
        .map_err(|_| "第三方源列表被污染（锁中毒）".to_string())?
        .clone();
    let mut out = Vec::new();
    for p in list.iter() {
        if let crate::model::PersistedProvider::Tvbox { id, name, api, .. } = p {
            out.push((id.clone(), name.clone(), api.clone()));
        }
    }
    Ok(out)
}

/// 列出全部 TVBox 源 + 它们有没有订阅链接（纯本地读，零网络）
///
/// # ★ 为什么必须是独立命令（与插件侧 list_plugin_sources 同一个理由）
///
/// ```text
/// 界面要在打开设置页时就知道「哪张卡该显示检测更新按钮」。
/// 若用 check_tvbox_updates 来判断 → 打开设置页会对每个订阅链接发一次 HTTP
/// → 页面要等几秒、还可能被 CDN 限流。
/// ```
pub fn list_tvbox_sources(
    state: &crate::state::AppState,
) -> std::result::Result<serde_json::Value, String> {
    let sources = local_tvbox_sources(state)?;
    let metas = load_tvbox_metas(&state.data_dir);
    let mut out = Vec::new();
    let mut with_source = 0usize;
    for (id, name, api) in sources.iter() {
        let meta = metas.get(id);
        let url = meta
            .and_then(|m| m.source_url.clone())
            .filter(|u| !u.trim().is_empty());
        if url.is_some() {
            with_source += 1;
        }
        out.push(serde_json::json!({
            "id": id,
            "name": name,
            "api": api,
            "sourceUrl": url,
            "needsSource": url.is_none(),
            "siteKey": meta.map(|m| m.site_key.clone()).unwrap_or_default(),
            "installedAt": meta.map(|m| m.installed_at).unwrap_or(0),
        }));
    }
    Ok(serde_json::json!({
        "sources": out,
        "total": sources.len(),
        "withSource": with_source,
    }))
}

/// 给某个 TVBox 源指定/清除订阅链接（纯本地写 sidecar）
///
/// 传空字符串 = 清除链接（回到「贴文本导入」状态，界面据此不再显示检测按钮）。
pub fn set_tvbox_source(
    state: &crate::state::AppState,
    id: &str,
    url: &str,
) -> std::result::Result<serde_json::Value, String> {
    let sources = local_tvbox_sources(state)?;
    let found = sources
        .iter()
        .find(|(sid, _, _)| sid == id)
        .ok_or_else(|| format!("没有找到 TVBox 源 {id}"))?;
    let url = url.trim();

    if url.is_empty() {
        forget_tvbox_meta(&state.data_dir, id)?;
        return Ok(serde_json::json!({
            "id": id, "name": found.1, "sourceUrl": serde_json::Value::Null,
        }));
    }
    if !starts_http(url) {
        return Err(format!("订阅链接必须是 http/https 地址：{url}"));
    }

    let old = read_tvbox_meta(&state.data_dir, id).unwrap_or_default();
    let meta = TvboxSourceMeta {
        source_url: Some(url.to_string()),
        // 老 site_key 保留 —— 换链接不等于换站点身份
        site_key: old.site_key,
        site_name: if old.site_name.is_empty() { found.1.clone() } else { old.site_name },
        api: if old.api.is_empty() { found.2.clone() } else { old.api },
        installed_at: if old.installed_at == 0 { now_secs() } else { old.installed_at },
    };
    write_tvbox_meta(&state.data_dir, id, &meta)?;
    Ok(serde_json::json!({
        "id": id, "name": found.1, "sourceUrl": url,
    }))
}

/// 移除一个 TVBox 源，并**同时忘掉它的订阅链接**
///
/// # ★ 为什么必须同时清 sidecar（不能只调 remove_provider）
///
/// ```text
/// 只删源不删 sidecar → 数据目录里留一条孤儿记录。
/// 将来任何一份配置若恰好产出同一个 id（to_id 是可预测的：
/// 名称的 ASCII 字母 → api 域名首段 → tvboxN），新源就会**继承**
/// 那条陈旧的订阅链接 —— 表现为「刚导入的源却显示有更新可查」，
/// 而那个链接其实属于用户早就删掉的另一个站。
/// ```
///
/// 所以「删源」与「忘链接」必须是**同一个操作**，不能指望调用方记得调两次。
pub fn remove_tvbox_source(
    state: &crate::state::AppState,
    id: &str,
) -> std::result::Result<serde_json::Value, String> {
    let removed = crate::commands_provider::remove_provider(state, id)?;
    // 无论源在不在，都清一次链接（幂等）
    forget_tvbox_meta(&state.data_dir, id)?;
    Ok(serde_json::json!({ "id": id, "removed": removed }))
}

/// 检测订阅链接有没有更新
///
/// # 三种结局，都不许静默（与 check_plugin_update 同一条原则）
///
/// ```text
/// ① 没有订阅链接            → 进 skipped（needsSource），如实说「查不了」
/// ② 网络 / 解析失败          → 该条 error=Some(原因)
/// ③ 查到了                  → added / removed / changed / unchanged
/// ```
///
/// # 为什么按链接分组而不是按源
///
/// 一份配置产出几十个源，它们共用同一个链接 —— 一次下载就能对比全部，
/// 而不是每个源各下一遍（96 个站点就是 96 次请求）。
pub async fn check_tvbox_updates(
    state: &crate::state::AppState,
    only_id: Option<&str>,
) -> std::result::Result<serde_json::Value, String> {
    let sources = local_tvbox_sources(state)?;
    let metas = load_tvbox_metas(&state.data_dir);

    // 按 id 过滤（只查一个源）
    let picked: Vec<(String, String, String)> = match only_id {
        Some(want) => {
            let one = sources
                .iter()
                .find(|(id, _, _)| id == want)
                .ok_or_else(|| format!("没有找到 TVBox 源 {want}"))?;
            vec![one.clone()]
        }
        None => sources.clone(),
    };

    // 某个源属于哪个订阅链接（None = 没有链接，查不了）
    let url_of = |id: &str| -> Option<String> {
        metas
            .get(id)
            .and_then(|m| m.source_url.clone())
            .filter(|u| !u.trim().is_empty())
    };

    // 要查的链接（去重；BTreeSet 保证顺序稳定，结果可复现）
    let mut wanted: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    let mut skipped_ids: Vec<String> = Vec::new();
    for (id, _, _) in picked.iter() {
        match url_of(id) {
            Some(u) => {
                wanted.insert(u);
            }
            None => skipped_ids.push(id.clone()),
        }
    }

    // 每个链接 → 配对池
    //
    // ★ 配对池是**全部** TVBox 源，不只是这个链接下的：
    //   两份配置里出现同一个站是常态，认不出来就会重复注册成两张一样的卡片。
    //   LocalSite::in_link 区分「属于本订阅」（可报 removed / 可应用变更）
    //   与「别的订阅导入的」（只认出来、绝不动它）。
    let mut groups: std::collections::BTreeMap<String, Vec<LocalSite>> =
        std::collections::BTreeMap::new();
    for url in wanted.iter() {
        let pool: Vec<LocalSite> = sources
            .iter()
            .map(|(sid, name, api)| LocalSite {
                id: sid.clone(),
                key: metas.get(sid).map(|m| m.site_key.clone()).unwrap_or_default(),
                name: name.clone(),
                api: api.clone(),
                in_link: url_of(sid).as_deref() == Some(url.as_str()),
            })
            .collect();
        groups.insert(url.clone(), pool);
    }

    let client = probe_client();
    let mut items = Vec::new();
    for (url, locals) in groups.iter() {
        // 这条链接"拥有"的源（别的订阅的源不算在内）
        let mut ids: Vec<String> = locals
            .iter()
            .filter(|l| l.in_link)
            .map(|l| l.id.clone())
            .collect();
        ids.sort();

        let text = match fetch_config_text(&client, url).await {
            Ok(t) => t,
            Err(e) => {
                items.push(serde_json::json!({
                    "sourceUrl": url,
                    "ids": ids,
                    "ok": false,
                    "error": format!("下载配置失败：{e}"),
                }));
                continue;
            }
        };
        let cfg = match parse_loose_json(&text) {
            Ok(c) => c,
            Err(e) => {
                items.push(serde_json::json!({
                    "sourceUrl": url,
                    "ids": ids,
                    "ok": false,
                    "error": format!("配置不是合法 JSON：{e}"),
                }));
                continue;
            }
        };
        // 链接后来变成了「多仓」—— 如实说明，不硬凑一份对比
        if cfg.get("sites").and_then(|v| v.as_array()).is_none() {
            let repos = multi_repo_repos(&cfg, url);
            items.push(serde_json::json!({
                "sourceUrl": url,
                "ids": ids,
                "ok": false,
                "multiRepo": !repos.is_empty(),
                "repos": repos,
                "error": if repos.is_empty() {
                    "远端配置里没有 sites 段（可能是直播源配置或空配置）".to_string()
                } else {
                    "远端链接现在是一份「多仓」配置（只有 urls，没有 sites），无法直接对比站点列表".to_string()
                },
            }));
            continue;
        }

        let (jobs, skipped, _lives) = collect_sites(&cfg, url);
        let remote: Vec<RemoteSite> = jobs
            .iter()
            .map(|j| RemoteSite {
                key: j.key.clone(),
                name: j.name.clone(),
                api: normalize_api_url(&j.api),
            })
            .collect();
        let diff = diff_sites(&locals, &remote);

        items.push(serde_json::json!({
            "sourceUrl": url,
            "ids": ids,
            "ok": true,
            "remoteTotalSites": cfg.get("sites").and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0),
            "remoteConvertible": jobs.len(),
            "remoteUnsupported": skipped.len(),
            "added": diff.added,
            "removed": diff.removed,
            "changed": diff.changed,
            "unchanged": diff.unchanged,
            "unchangedForeign": diff.unchanged_foreign,
        }));
    }

    Ok(serde_json::json!({
        "items": items,
        "checked": groups.len(),
        "skipped": skipped_ids.len(),
        "skippedIds": skipped_ids,
    }))
}

/// 一键应用订阅链接上的更新
///
/// # 语义（用户点的是某张卡，但更新的是整份订阅）
///
/// ```text
/// ① 重新下载这个源所属的订阅链接（同一个链接下的源一起处理）
/// ② 远端还有的站  → 重新探测 → 沿用原 id 原地覆盖
///    （沿用 id 才能保住用户设过的启用状态/排序/收藏）
/// ③ 远端新增的站  → 注册进来（apply_new=false 时只报告）
/// ④ 远端消失的站  → ★ 只报告，默认绝不删（delete_missing=true 才删）
/// ⑤ 探测失败的站  → 如实进 failed，不动本地
/// ```
///
/// ⚠️ 第 ④ 条是这个功能的核心：配置作者临时删掉一个站又加回来是常事，
///    静默删掉用户本地的东西是不可逆的伤害。
pub async fn update_tvbox_source(
    state: &crate::state::AppState,
    id: &str,
    apply_new: bool,
    delete_missing: bool,
) -> std::result::Result<serde_json::Value, String> {
    let sources = local_tvbox_sources(state)?;
    if !sources.iter().any(|(sid, _, _)| sid == id) {
        return Err(format!("没有找到 TVBox 源 {id}"));
    }
    let Some(url) = read_tvbox_meta(&state.data_dir, id)
        .and_then(|m| m.source_url)
        .filter(|u| !u.trim().is_empty())
    else {
        return Err("这个源没有订阅链接，无法更新（请先填入链接）".to_string());
    };

    // ── 下载 + 解析 ─────────────────────────────────────────────────
    let client = probe_client();
    let text = fetch_config_text(&client, &url)
        .await
        .map_err(|e| format!("下载配置失败（{url}）：{e}"))?;
    let cfg = parse_loose_json(&text).map_err(|e| format!("配置不是合法 JSON：{e}"))?;
    if cfg.get("sites").and_then(|v| v.as_array()).is_none() {
        return Err(format!(
            "远端链接 {url} 现在是一份「多仓」配置（只有 urls，没有 sites），\
             不能直接更新。请打开其中某个子仓，把它的链接填进来。"
        ));
    }

    // 配对池 = **全部** TVBox 源，但只有同一个链接下的那些才算「本订阅的」
    // （in_link=true）—— 见 LocalSite::in_link 的说明。
    let metas = load_tvbox_metas(&state.data_dir);
    let in_link = |sid: &str| -> bool {
        metas
            .get(sid)
            .and_then(|m| m.source_url.as_deref())
            .map(|u| u == url)
            .unwrap_or(false)
    };
    let locals: Vec<LocalSite> = sources
        .iter()
        .map(|(sid, name, api)| LocalSite {
            id: sid.clone(),
            key: metas.get(sid).map(|m| m.site_key.clone()).unwrap_or_default(),
            name: name.clone(),
            api: api.clone(),
            in_link: in_link(sid),
        })
        .collect();

    let (jobs, skipped, _lives) = collect_sites(&cfg, &url);
    let remote: Vec<RemoteSite> = jobs
        .iter()
        .map(|j| RemoteSite {
            key: j.key.clone(),
            name: j.name.clone(),
            api: normalize_api_url(&j.api),
        })
        .collect();
    let diff = diff_sites(&locals, &remote);

    let want_delete = delete_missing && !diff.removed.is_empty();
    if diff.added.is_empty() && diff.changed.is_empty() && !want_delete {
        return Ok(serde_json::json!({
            "updated": false,
            "reason": "远端配置与本地一致，无需更新",
            "sourceUrl": url,
            "added": [],
            "changed": [],
            // ★ 即使"没更新"，也要如实报告"远端已经没有的站"——
            //   否则用户会以为一切都对，实际上本地留着几个已经下线的站。
            "removed": diff.removed,
            "deleted": [],
            "failed": [],
            "unchanged": diff.unchanged,
            "unchangedForeign": diff.unchanged_foreign,
            "skippedByType": skipped.len(),
        }));
    }

    // ── 需要（重新）探测的站：新增 + 变更 ────────────────────────────
    //
    // 每项 = (远端站点下标, 要覆盖的本地 id)；新增项本地 id 为 None。
    let mut todos: Vec<(usize, Option<String>)> = Vec::new();
    for (i, _r) in diff.added.iter().enumerate() {
        todos.push((diff.added_idx[i], None));
    }
    for (i, c) in diff.changed.iter().enumerate() {
        todos.push((diff.changed_idx[i], Some(c.id.clone())));
    }

    let sem = Arc::new(tokio::sync::Semaphore::new(MAX_PROBE_CONCURRENCY));
    let mut results: Vec<Option<std::result::Result<ProbeOk, String>>> =
        (0..todos.len()).map(|_| None).collect();
    let mut set = tokio::task::JoinSet::new();
    for (idx, (remote_idx, _)) in todos.iter().enumerate() {
        let client = client.clone();
        let sem = sem.clone();
        let api = jobs.get(*remote_idx).map(|j| j.api.clone()).unwrap_or_default();
        set.spawn(async move {
            let _permit = sem.acquire_owned().await;
            (idx, probe_apple_cms(&client, &api).await)
        });
    }
    while let Some(joined) = set.join_next().await {
        match joined {
            Ok((idx, r)) => results[idx] = Some(r),
            Err(e) => log::warn!("TVBox 更新探测任务异常退出：{e}"),
        }
    }

    // ── 生成要写盘的源 ───────────────────────────────────────────────
    //
    // used 预置**全部已存在的 id**（含别的订阅里的 tvbox 源）：
    // 新增站点绝不顶掉任何已有源；要覆盖的老站直接沿用原 id，不走 unique_id。
    let mut used: HashSet<String> = state
        .registry
        .manifests()
        .iter()
        .map(|m| m.id.clone())
        .collect();

    let mut to_persist: Vec<crate::model::PersistedProvider> = Vec::new();
    let mut meta_writes: Vec<(String, TvboxSourceMeta)> = Vec::new();
    let mut added_out: Vec<serde_json::Value> = Vec::new();
    let mut changed_out: Vec<serde_json::Value> = Vec::new();
    let mut not_applied: Vec<serde_json::Value> = Vec::new();
    let mut failed_out: Vec<serde_json::Value> = Vec::new();

    for (idx, (remote_idx, local_id)) in todos.iter().enumerate() {
        let Some(job) = jobs.get(*remote_idx) else {
            continue;
        };
        let ok = match results.get_mut(idx).and_then(|x| x.take()) {
            Some(Ok(ok)) => ok,
            Some(Err(reason)) => {
                failed_out.push(serde_json::json!({
                    "name": job.name,
                    "api": normalize_api_url(&job.api),
                    "reason": reason,
                }));
                continue;
            }
            None => {
                failed_out.push(serde_json::json!({
                    "name": job.name,
                    "api": normalize_api_url(&job.api),
                    "reason": "探测任务异常",
                }));
                continue;
            }
        };

        let (sid, is_new) = match local_id.clone() {
            Some(existing) => (existing, false),
            None => {
                if !apply_new {
                    // 用户没勾「同时加入新增站点」—— 如实报告，不偷偷加
                    not_applied.push(serde_json::json!({
                        "name": job.name,
                        "api": normalize_api_url(&job.api),
                    }));
                    continue;
                }
                (
                    unique_id(&to_id(&job.name, &job.api, job.index), &mut used),
                    true,
                )
            }
        };

        let provider =
            TvboxAppleCmsProvider::new(sid.clone(), job.name.clone(), &job.api, ok.classes.clone())
                .map_err(|e| format!("生成源「{}」失败：{e}", job.name))?;
        let manifest = MediaProvider::manifest(&provider).clone();
        state
            .registry
            .register(Arc::new(provider.with_proxy(state.proxy.clone())));

        let api_norm = normalize_api_url(&job.api);
        to_persist.push(crate::model::PersistedProvider::Tvbox {
            id: sid.clone(),
            name: manifest.name.clone(),
            api: api_norm.clone(),
            categories: ok.classes.clone(),
        });
        meta_writes.push((
            sid.clone(),
            TvboxSourceMeta {
                source_url: Some(url.clone()),
                site_key: job.key.clone(),
                site_name: job.name.clone(),
                api: api_norm.clone(),
                installed_at: now_secs(),
            },
        ));
        let row = serde_json::json!({
            "id": sid,
            "name": manifest.name,
            "api": api_norm,
            "categories": ok.classes.len(),
            "total": ok.total,
        });
        if is_new {
            added_out.push(row);
        } else {
            changed_out.push(row);
        }
    }

    // ── 先落盘新增/变更，再处理「远端消失」（顺序不能换）──────────────
    //
    // remove_provider 内部会 persist_from_registry —— 它写的是内存里的
    // third_party。若先删后写，新站还没进内存就被写成清单，等于白探测。
    if !to_persist.is_empty() {
        {
            let mut list = state
                .third_party
                .write()
                .map_err(|_| "第三方源列表被污染".to_string())?;
            for p in to_persist {
                let pid = p.id().to_string();
                list.retain(|x| x.id() != pid);
                list.push(p);
            }
        }
        crate::commands_provider::persist_from_registry(state)?;
        crate::commands_provider::touch_providers(state);
    }
    for (sid, meta) in meta_writes.iter() {
        write_tvbox_meta(&state.data_dir, sid, meta)?;
    }

    // ── 远端消失的站：默认只报告 ────────────────────────────────────
    let mut deleted_out: Vec<serde_json::Value> = Vec::new();
    if want_delete {
        for l in diff.removed.iter() {
            // 只在**这一份订阅**里确认它真的没了才删
            if !locals.iter().any(|x| x.id == l.id && x.in_link) {
                continue;
            }
            match crate::commands_provider::remove_provider(state, &l.id) {
                Ok(_) => {
                    let _ = forget_tvbox_meta(&state.data_dir, &l.id);
                    deleted_out.push(serde_json::json!({ "id": l.id, "name": l.name }));
                }
                Err(e) => failed_out.push(serde_json::json!({
                    "name": l.name,
                    "api": normalize_api_url(&l.api),
                    "reason": format!("删除失败：{e}"),
                })),
            }
        }
    }

    let updated = !added_out.is_empty() || !changed_out.is_empty() || !deleted_out.is_empty();
    log::info!(
        "TVBox 订阅更新（{url}）：新增 {} 变更 {} 删除 {} 失败 {} 远端消失 {} 未加入 {} {}",
        added_out.len(),
        changed_out.len(),
        deleted_out.len(),
        failed_out.len(),
        diff.removed.len(),
        not_applied.len(),
        if delete_missing { "" } else { "（未勾选删除，已保留）" }
    );
    Ok(serde_json::json!({
        "updated": updated,
        "sourceUrl": url,
        "added": added_out,
        "changed": changed_out,
        "removed": diff.removed,
        "deleted": deleted_out,
        "notApplied": not_applied,
        "failed": failed_out,
        "unchanged": diff.unchanged,
        "unchangedForeign": diff.unchanged_foreign,
        "skippedByType": skipped.len(),
    }))
}

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"{
  // TVBox 配置示例（含注释与尾逗号 —— 野外真实形态）
  "sites": [
    {"key":"bf","name":"暴风","type":1,"api":"https://bfzyapi.com/api.php/provide/vod?ac=list","searchable":1},
    {"key":"dl","name":"东篱","type":3,"api":"csp_DongLi","jar":"./jar/dongli.jar"},
    {"key":"jx","name":"解析","type":0,"api":"https://jx.example.com/?url="},
    {"key":"cn","name":"中文名源","type":1,"api":"https://www.ffzyapi.com/api.php/provide/vod",},
  ],
  "lives": [{"name":"央视","url":"http://x/y.m3u"},],
  "parses": [{"name":"爱心","type":4,"url":"http://119.91.123.253:2345/Api/yun.php?url="}]
}"#;

    #[test]
    fn loose_json_handles_comments_and_trailing_commas() {
        let v = parse_loose_json(SAMPLE).expect("宽松解析");
        assert_eq!(v.get("sites").unwrap().as_array().unwrap().len(), 4);
    }

    #[test]
    fn loose_json_handles_bom_and_jsonp() {
        let with_bom = format!("\u{feff}{{\"a\":1}}");
        assert_eq!(parse_loose_json(&with_bom).unwrap()["a"], 1);
        let jsonp = parse_loose_json("my.cb({ \"a\": 2 });").unwrap();
        assert_eq!(jsonp["a"], 2);
        // 括号出现在字符串里时不能误拆
        let s = "{\"a\":\"(\"}";
        assert_eq!(parse_loose_json(s).unwrap()["a"], "(");
    }

    #[test]
    fn loose_json_escapes_raw_control_chars_inside_strings() {
        // ★ 实测两条真配置栽在这：http://xhztv.top/4k.json 的 "优<LF>酷"、
        //   gh-proxy 那份 svip.json 的 "喜欢热闹还是喜欢安静<LF>       "。
        //   serde_json 严格执行 RFC 8259（字符串内不许 U+0000-U+001F）⇒ 必须自己补转义。
        let s = "{\"a\":\"优\n酷\",\"b\":\"x\ty\",\"c\":\"p\rq\"}";
        let v = parse_loose_json(s).expect("字符串里的裸控制字符应被补成转义序列");
        assert_eq!(v["a"], "优\n酷");
        assert_eq!(v["b"], "x\ty");
        assert_eq!(v["c"], "p\rq");
        // 没有短转义的控制字符走 \uXXXX
        let v2 = parse_loose_json("{\"a\":\"x\u{1}y\"}").unwrap();
        assert_eq!(v2["a"], "x\u{1}y");
        // ★ 字符串外的空白不能被误伤：CRLF 换行的配置照样解析
        let v3 = parse_loose_json("{\r\n  \"a\": 1\r\n}\r\n").unwrap();
        assert_eq!(v3["a"], 1);
    }

    #[test]
    fn loose_json_keeps_escapes_and_in_string_punctuation_intact() {
        // 已经是转义的 \n 不能被二次转义
        let v = parse_loose_json("{\"a\":\"x\\ny\"}").unwrap();
        assert_eq!(v["a"], "x\ny");
        // 字符串里的 , 与 } 不能被当成结构字符（尾逗号清理必须认字符串状态）
        let v2 = parse_loose_json("{\"a\":\"x,\n}\",\"b\":1,}").unwrap();
        assert_eq!(v2["a"], "x,\n}");
        assert_eq!(v2["b"], 1);
        // 字符串里的 // 不能被当成注释
        let v3 = parse_loose_json("{\"a\":\"http://x/y\"}").unwrap();
        assert_eq!(v3["a"], "http://x/y");
        // 真配置形态：字符串内换行后的续行以 // 开头，也不能被整行注释删掉
        let v4 = parse_loose_json("{\"a\":\"head\n//tail\",\"b\":2}").unwrap();
        assert_eq!(v4["a"], "head\n//tail");
        assert_eq!(v4["b"], 2);
    }

    #[test]
    fn normalize_api_strips_query_string() {
        // ★ 实测踩过的坑：不剥查询串 → 所有分类 0 条
        assert_eq!(
            normalize_api_url("https://api.apibdzy.com/api.php/provide/vod?ac=list"),
            "https://api.apibdzy.com/api.php/provide/vod"
        );
        assert_eq!(
            normalize_api_url("  http://cj.ffzyapi.com/api.php/provide/vod/  "),
            "http://cj.ffzyapi.com/api.php/provide/vod"
        );
        assert_eq!(normalize_api_url(""), "");
    }

    #[test]
    fn to_id_never_returns_constant() {
        // 中文名 → 域名兜底（第一版返回固定 'src' 导致四个源互相覆盖）
        assert_eq!(to_id("暴风", "https://bfzyapi.com/api.php", 0), "bfzyapi");
        assert_eq!(
            to_id("中文名源", "https://www.ffzyapi.com/api.php", 3),
            "ffzyapi"
        );
        // ASCII 名优先
        assert_eq!(to_id("BaoFeng", "https://bfzyapi.com/api.php", 0), "baofeng");
        // 都取不到 → 序号兜底
        assert_eq!(to_id("中文", "", 6), "tvbox7");
        // 两个中文名源不能撞成同一个 id
        assert_ne!(
            to_id("玄珠", "https://a1.com/api.php", 0),
            to_id("小马", "https://a2.com/api.php", 1)
        );
    }

    #[test]
    fn unique_id_appends_suffix() {
        let mut used = HashSet::new();
        assert_eq!(unique_id("bf", &mut used), "bf");
        assert_eq!(unique_id("bf", &mut used), "bf-2");
        assert_eq!(unique_id("bf", &mut used), "bf-3");
    }

    #[test]
    fn parse_episodes_splits_and_filters() {
        let s = "第1集$https://a.com/1.m3u8#第2集$https://a.com/2.m3u8#坏数据$notaurl";
        let eps = parse_episodes(s);
        assert_eq!(eps.len(), 2);
        assert_eq!(eps[0].0, "第1集");
        assert_eq!(eps[1].1, "https://a.com/2.m3u8");
        // 没有 $ 分隔时整段当地址
        let only = parse_episodes("https://a.com/x.m3u8");
        assert_eq!(only.len(), 1);
        assert_eq!(only[0].0, "");
    }

    #[test]
    fn strip_tags_removes_markup() {
        assert_eq!(strip_tags("<p>你好<br/>世界</p>"), "你好世界");
        assert_eq!(strip_tags("  <b>x</b>  "), "x");
        assert_eq!(strip_tags("a < b"), "a < b");
    }

    #[test]
    fn absolutize_handles_all_shapes() {
        let base = "https://a.com/share/abc";
        assert_eq!(
            absolutize("https://b.com/x.m3u8", base),
            "https://b.com/x.m3u8"
        );
        assert_eq!(absolutize("//b.com/x.m3u8", base), "https://b.com/x.m3u8");
        assert_eq!(absolutize("/p/x.m3u8", base), "https://a.com/p/x.m3u8");
        assert_eq!(absolutize("x.m3u8", base), "https://a.com/share/x.m3u8");
        assert_eq!(absolutize("", base), "");
        // base 本身畸形时原样返回
        assert_eq!(absolutize("x.m3u8", "not-a-url"), "x.m3u8");
    }

    #[test]
    fn extract_m3u8_from_html() {
        let html = r#"<script>var u = "/20260718/36834/index.m3u8?sign=abc";</script>"#;
        assert_eq!(
            extract_m3u8(html, "https://super.ffzy-online6.com/share/9f").as_deref(),
            Some("https://super.ffzy-online6.com/20260718/36834/index.m3u8?sign=abc")
        );
        // 没有 m3u8 的页面（真实样本里量子采集有 1 条这种）
        assert!(extract_m3u8("<html>no video here</html>", "https://a.com/p").is_none());
        // 中文内容不应 panic
        assert!(extract_m3u8("中文页面 <div>没有地址</div>", "https://a.com/p").is_none());
    }

    #[test]
    fn collect_sites_classifies_by_type() {
        let cfg = parse_loose_json(SAMPLE).unwrap();
        let (jobs, skipped, lives) = collect_sites(&cfg, "");
        assert_eq!(jobs.len(), 2, "两个 type=1 站点");
        assert_eq!(jobs[0].name, "暴风");
        assert_eq!(jobs[1].name, "中文名源");
        assert_eq!(skipped.len(), 2);
        assert_eq!(lives.len(), 1);
        let reasons: Vec<String> = skipped
            .iter()
            .map(|s| s["reason"].as_str().unwrap().to_string())
            .collect();
        assert!(reasons.iter().any(|r| r.contains("spider")));
        assert!(reasons.iter().any(|r| r.contains("纯 JSON API")));
    }

    #[test]
    fn collect_sites_resolves_relative_api_against_config_url() {
        let cfg = parse_loose_json(
            r#"{"sites":[{"name":"rel","type":1,"api":"/api.php/provide/vod"}]}"#,
        )
        .unwrap();
        let (jobs, _, _) = collect_sites(&cfg, "https://cfg.example.com/tvbox/cfg.json");
        assert_eq!(jobs[0].api, "https://cfg.example.com/api.php/provide/vod");
    }

    #[test]
    fn skip_reason_covers_known_types() {
        assert!(skip_reason(Some(3)).contains("Java"));
        assert!(skip_reason(Some(0)).contains("JSON API"));
        assert!(skip_reason(Some(4)).contains("其它"));
        assert!(skip_reason(Some(9)).contains("type=9"));
        assert!(skip_reason(None).contains("未声明"));
    }

    #[test]
    fn provider_manifest_is_tvbox_kind() {
        let p = TvboxAppleCmsProvider::new(
            "demo",
            "示例",
            "https://a.com/api.php/provide/vod?ac=list",
            vec![TvboxCategoryEntry {
                id: "1".into(),
                name: "电影".into(),
                pid: None,
            }],
        )
        .expect("构造 Provider");
        let m = p.manifest();
        assert_eq!(m.kind, "tvbox");
        assert_eq!(m.id, "demo");
        assert!(m.capabilities.vod && m.capabilities.search);
        // 接口地址必须已归一化（不带查询串）
        assert_eq!(p.api, "https://a.com/api.php/provide/vod");
        assert_eq!(p.referer(), "https://a.com/");
    }

    #[test]
    fn provider_rejects_bad_api() {
        assert!(TvboxAppleCmsProvider::new("x", "x", "", vec![]).is_err());
        assert!(TvboxAppleCmsProvider::new("x", "x", "not-a-url", vec![]).is_err());
    }

    #[tokio::test]
    async fn provider_home_matches_classes() {
        let p = TvboxAppleCmsProvider::new(
            "demo",
            "示例",
            "https://a.com/api.php/provide/vod",
            (0..10)
                .map(|i| TvboxCategoryEntry {
                    id: format!("{i}"),
                    name: format!("分类{i}"),
                    pid: None,
                })
                .collect(),
        )
        .unwrap();
        let secs = MediaProvider::home(&p).await.unwrap();
        assert_eq!(secs.len(), HOME_SECTIONS, "首页最多 8 个区块");
        match &secs[0].source {
            SectionSource::Category { category_id } => assert_eq!(category_id, "0"),
            _ => panic!("应为分类区块"),
        }
        assert_eq!(secs[0].id, "demo-0");
        let cats = MediaProvider::categories(&p).await.unwrap();
        assert_eq!(cats.len(), 10);
        assert_eq!(cats[3].name, "分类3");
    }

    #[test]
    fn json_parse_url_reads_nested_shapes() {
        let j: serde_json::Value =
            serde_json::from_str(r#"{"code":200,"url":"https://q.iisfu.top/a.m3u8"}"#).unwrap();
        assert_eq!(json_parse_url(&j).unwrap(), "https://q.iisfu.top/a.m3u8");
        let j2: serde_json::Value =
            serde_json::from_str(r#"{"data":{"playUrl":"https://x/b.m3u8"}}"#).unwrap();
        assert_eq!(json_parse_url(&j2).unwrap(), "https://x/b.m3u8");
        // 失效解析服务的真实响应：没有 url 字段 → None（调用方 continue）
        let j3: serde_json::Value = serde_json::from_str(
            r#"{"code":"404","type":"hls","msg":"解析失败 https://api.huaqi.pro"}"#,
        )
        .unwrap();
        assert!(json_parse_url(&j3).is_none());
    }

    #[test]
    fn first_media_url_finds_link_in_text() {
        let t = "callback('https://cdn.example.com/x/index.m3u8?sign=1');";
        assert_eq!(
            first_media_url(t).unwrap(),
            "https://cdn.example.com/x/index.m3u8?sign=1"
        );
        assert!(first_media_url("no links here").is_none());
    }

    #[test]
    fn resolve_api_joins_relative() {
        assert_eq!(
            resolve_api("/api.php", "https://a.com/x/y.json").unwrap(),
            "https://a.com/api.php"
        );
        assert_eq!(
            resolve_api("api.php", "https://a.com/x/y.json").unwrap(),
            "https://a.com/x/api.php"
        );
        assert_eq!(
            resolve_api("https://b.com/api.php", "https://a.com/x.json").unwrap(),
            "https://b.com/api.php"
        );
        assert!(resolve_api("", "https://a.com/x.json").is_none());
        assert!(resolve_api("/api.php", "not-a-url").is_none());
    }
}

// ============================================================================
// imports_e2e —— TVBox 导入链路的宿主侧端到端测试
// ============================================================================
//
// 为什么单独开一个模块：上面的 mod tests 全是纯函数单测（解析/拼接/分类），
// 而这里要真的在 127.0.0.1 上起一个 HTTP 假服务、真的用 reqwest 发请求，
// 属于集成级验证；跟纯函数单测混在一起会让失败定位变模糊。
//
// ★ 本模块的两个测试都不碰公网、不碰用户数据、不写任何文件。
#[cfg(test)]
mod imports_e2e {
    use super::*;
    use axum::body::Body as AxumBody;
    use axum::http::{header, Request, StatusCode};
    use axum::response::{IntoResponse, Response};
    use axum::Router;

    fn reply(status: StatusCode, content_type: &str, body: &str) -> Response {
        Response::builder()
            .status(status)
            .header(header::CONTENT_TYPE, content_type)
            .body(AxumBody::from(body.to_string()))
            .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
    }

    /// 取出原始（仍是百分号编码的）query 串。
    ///
    /// ★ 故意不做百分号解码：urlencoding 这个依赖只导出过 encode，decode 的可用性
    /// 没有验证过，所以这里只做「包含某个纯字母数字哨兵」的判断 —— 字母数字一定
    /// 不会被百分号编码，哨兵必然原样出现在 query 里。
    fn raw_query(req: &Request<AxumBody>) -> String {
        req.uri().query().unwrap_or("").to_string()
    }

    /// 假解析服务 A：按 page_url 里的哨兵返回不同形态的响应。
    ///
    /// 覆盖：JSON url / JSON data.playUrl / 非 JSON 原文 / 以 / 开头 /
    ///       含 error、placeholder、default.mp4 的坏地址 / HTTP 500 / 空 body。
    async fn parse_server_a(req: Request<AxumBody>) -> Response {
        let q = raw_query(&req);
        if q.contains("zjson1") {
            return reply(
                StatusCode::OK,
                "application/json",
                r#"{"url":"http://cdn.test/json/a.m3u8"}"#,
            );
        }
        if q.contains("zdata1") {
            return reply(
                StatusCode::OK,
                "application/json",
                r#"{"data":{"playUrl":"http://cdn.test/data/b.m3u8"}}"#,
            );
        }
        if q.contains("ztext1") {
            return reply(
                StatusCode::OK,
                "text/plain",
                r#"window.__p = "http://cdn.test/raw/c/index.m3u8?sign=1";"#,
            );
        }
        if q.contains("zslash1") {
            return reply(
                StatusCode::OK,
                "application/json",
                r#"{"url":"/live/rel.m3u8"}"#,
            );
        }
        if q.contains("zerr1") {
            return reply(
                StatusCode::OK,
                "application/json",
                r#"{"url":"http://a.test/error.mp4"}"#,
            );
        }
        if q.contains("zph1") {
            return reply(
                StatusCode::OK,
                "application/json",
                r#"{"url":"http://a.test/placeholder.mp4"}"#,
            );
        }
        if q.contains("zdef1") {
            return reply(
                StatusCode::OK,
                "application/json",
                r#"{"url":"http://a.test/default.mp4"}"#,
            );
        }
        if q.contains("z500") {
            return reply(StatusCode::INTERNAL_SERVER_ERROR, "text/plain", "boom");
        }
        if q.contains("zempty") {
            return reply(StatusCode::OK, "application/json", "");
        }
        reply(StatusCode::NOT_FOUND, "text/plain", "nope")
    }

    /// 假解析服务 B：无论问什么都给一个能用的地址。
    ///
    /// 用来证明「A 的坏结果被 continue 掉之后，循环真的走到了第二个解析服务」。
    async fn parse_server_b(_req: Request<AxumBody>) -> Response {
        reply(
            StatusCode::OK,
            "application/json",
            r#"{"url":"http://b.test/ok.m3u8"}"#,
        )
    }

    async fn spawn_a() -> u16 {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("绑定假解析服务 A 失败");
        let port = listener.local_addr().expect("取端口失败").port();
        let app = Router::new().fallback(parse_server_a);
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        port
    }

    async fn spawn_b() -> u16 {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("绑定假解析服务 B 失败");
        let port = listener.local_addr().expect("取端口失败").port();
        let app = Router::new().fallback(parse_server_b);
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        port
    }

    /// 源码断言：生产入口 try_parsers 必须只有一行委托，逻辑全在 try_parsers_with。
    ///
    /// 这条断言防的是「以后有人把解析逻辑再抄回 try_parsers」—— 那样公网
    /// PARSE_SERVICES 就会绕过下面那个测试缝，让 E2E 变成在测一个不存在的分支。
    #[test]
    fn production_entry_delegates_to_injectable_seam() {
        let src = include_str!("tvbox.rs");

        let start = src
            .find("async fn try_parsers(")
            .expect("tvbox.rs 里找不到 async fn try_parsers(");
        let rest = &src[start..];
        let end = rest
            .find("\n    }\n")
            .expect("找不到 try_parsers 的函数体结尾");
        let body = &rest[..end];

        assert!(
            body.contains("self.try_parsers_with(page_url, &PARSE_SERVICES).await"),
            "生产入口必须把 PARSE_SERVICES 原样交给 try_parsers_with，实际函数体：\n{body}"
        );
        assert!(
            !body.contains("bases"),
            "生产入口不该自己接 bases 参数，实际函数体：\n{body}"
        );
        assert!(
            !body.contains("for "),
            "生产入口不该自己写循环，实际函数体：\n{body}"
        );
        assert!(
            !body.contains("get_text"),
            "生产入口不该自己发请求，实际函数体：\n{body}"
        );

        // 缝的另一头必须真的有实现，而不是个空壳
        let start2 = src
            .find("async fn try_parsers_with(")
            .expect("tvbox.rs 里找不到 async fn try_parsers_with(");
        let rest2 = &src[start2..];
        let end2 = rest2
            .find("\n    }\n")
            .expect("找不到 try_parsers_with 的函数体结尾");
        let body2 = &rest2[..end2];

        assert!(
            body2.contains("for base in bases.iter()"),
            "try_parsers_with 必须按调用方给的解析服务列表循环，实际函数体：\n{body2}"
        );
        assert!(
            body2.contains("self.get_text(&u).await"),
            "try_parsers_with 必须真的发请求，实际函数体：\n{body2}"
        );
    }

    /// 用 127.0.0.1 上的两个假解析服务，把 try_parsers_with 的每条分支走一遍。
    ///
    /// ★ 被测的是 try_parsers_with —— 也就是生产入口 try_parsers 的唯一实现，
    /// 所以没有任何生产行为被测试代码改写，PARSE_SERVICES 仍然指向公网。
    #[tokio::test]
    async fn try_parsers_with_covers_every_branch() {
        let port_a = spawn_a().await;
        let port_b = spawn_b().await;
        let base_a = format!("http://127.0.0.1:{port_a}/p?u=");
        let base_b = format!("http://127.0.0.1:{port_b}/p?u=");
        let api = format!("http://127.0.0.1:{port_a}/api.php");
        let p = TvboxAppleCmsProvider::new("e2e-parse", "E2E 解析", &api, Vec::new())
            .expect("构造 TvboxAppleCmsProvider 失败");
        let bases: Vec<&str> = vec![base_a.as_str(), base_b.as_str()];
        let only_a: Vec<&str> = vec![base_a.as_str()];
        let page = |tag: &str| format!("http://page.test/{tag}.html");

        // ① 解析服务返回 JSON {"url": ...}
        assert_eq!(
            p.try_parsers_with(&page("zjson1"), &bases).await.as_deref(),
            Some("http://cdn.test/json/a.m3u8"),
            "JSON 的 url 字段应被直接采用"
        );

        // ② 解析服务返回 JSON {"data":{"playUrl": ...}}
        assert_eq!(
            p.try_parsers_with(&page("zdata1"), &bases).await.as_deref(),
            Some("http://cdn.test/data/b.m3u8"),
            "JSON 的 data.playUrl 字段应被采用"
        );

        // ③ 解析服务返回非 JSON 原文，里面埋着媒体直链
        assert_eq!(
            p.try_parsers_with(&page("ztext1"), &bases).await.as_deref(),
            Some("http://cdn.test/raw/c/index.m3u8?sign=1"),
            "非 JSON 原文应走 first_media_url 兜底"
        );

        // ④ 返回以 / 开头的地址 → 必须拼到解析服务自己的 origin 上（端口要保留）
        let expect_slash = format!("http://127.0.0.1:{port_a}/live/rel.m3u8");
        assert_eq!(
            p.try_parsers_with(&page("zslash1"), &only_a)
                .await
                .as_deref(),
            Some(expect_slash.as_str()),
            "以 / 开头的地址应拼到解析服务的 origin 上"
        );

        // ⑤⑥⑦ 坏地址（error / placeholder / default.mp4）必须被跳过，落到第二个解析服务
        assert_eq!(
            p.try_parsers_with(&page("zerr1"), &bases).await.as_deref(),
            Some("http://b.test/ok.m3u8"),
            "含 error 的地址应被跳过"
        );
        assert_eq!(
            p.try_parsers_with(&page("zph1"), &bases).await.as_deref(),
            Some("http://b.test/ok.m3u8"),
            "含 placeholder 的地址应被跳过"
        );
        assert_eq!(
            p.try_parsers_with(&page("zdef1"), &bases).await.as_deref(),
            Some("http://b.test/ok.m3u8"),
            "含 default.mp4 的地址应被跳过"
        );

        // ⑧ 第一个解析服务 HTTP 500 → 必须 continue 而不是 panic
        assert_eq!(
            p.try_parsers_with(&page("z500"), &bases).await.as_deref(),
            Some("http://b.test/ok.m3u8"),
            "解析服务 500 应被跳过"
        );

        // ⑨ 第一个解析服务返回空 body → 必须 continue
        assert_eq!(
            p.try_parsers_with(&page("zempty"), &bases).await.as_deref(),
            Some("http://b.test/ok.m3u8"),
            "解析服务返回空 body 应被跳过"
        );

        // ⑩ 所有解析服务都不可用 → None（不能 panic，也不能编一个地址出来）
        assert_eq!(
            p.try_parsers_with(&page("znone"), &only_a).await.as_deref(),
            None,
            "全部解析服务失败应返回 None"
        );
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// task5_ab_restart —— 本地封闭端到端：A/B 分支对照 + 解析服务 + 重启持久化
//
//   仪器：一个「原始 TCP 假服务」，同时充当假代理与假源站。
//     · http:// 目标经代理 → absolute-form GET，可观察到完整 URL；
//     · https:// 目标经代理 → CONNECT host:443，TLS 无法完成 → 回 502，
//       这正好落进 try_parsers_with 的「解析服务失败 → 换下一个」分支。
//   每条请求在回包【之前】先记账，所以计数不依赖最终 play_url 字符串，
//   也不需要真的连上外网或改一行生产代码。
//
//   A：分享页（无 m3u8）→ 必须真的请求两个解析服务（目标主机/状态码/字节数）
//   A 对照：分享页里已有 m3u8 → 解析服务请求数必须为 0
//   B：直链 .m3u8 → 在 tvbox.rs 的 .m3u8 短路判断处返回，总请求数 0
//   C：导入 → 二次 bootstrap（重启）后源仍在注册表
// ═══════════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod task5_ab_restart {
    use super::*;
    use crate::model::{ErrorKind, MediaId, PlayRequest, StreamKind, TvboxCategoryEntry};
    use crate::provider::MediaProvider;
    use crate::proxy::{ProxyConfig, ProxyMode, ProxyStore};
    use crate::state::AppState;
    use std::io::{BufRead, BufReader, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::{Arc, Mutex};

    // ── 应答体 ────────────────────────────────────────────────────────────
    /// 分享页：全篇不含引号 ⇒ extract_m3u8 的引号扫描一个都找不到 ⇒ None。
    pub(super) const SHARE_PLAIN: &str =
        "<!doctype html><html><head><title>分享页</title></head><body><div id=app>请下载客户端观看</div></body></html>";
    /// 对照分享页：引号里就有一个 m3u8。
    const SHARE_WITH_M3U8: &str =
        "<html><body><script>var s = \"http://cdn.control/ctrl/index.m3u8?sign=9\";</script></body></html>";
    /// 模拟 huaqi 那种「200 但解析失败」的应答（无任何可播放字段）。
    const DEAD_BODY: &str = "{\"code\":\"404\",\"type\":\"hls\",\"msg\":\"解析失败 https://api.huaqi.pro\"}";
    /// 模拟还活着的解析服务。
    const OK_BODY: &str = "{\"url\":\"http://cdn.test/real/ok.m3u8\"}";
    const CLASS_BODY: &str = "{\"class\":[{\"type_id\":\"1\",\"type_name\":\"电影\"}]}";
    const LIST_BODY: &str =
        "{\"page\":1,\"pagecount\":1,\"total\":1,\"list\":[{\"vod_id\":\"1001\",\"vod_name\":\"测试片\"}]}";
    /// task-12：一份**多仓**配置（只有 urls，没有 sites）。
    ///
    /// 用它验证两件事：
    /// ```text
    /// ① import_tvbox_config 不再把它当"错误" —— 而是结构化返回 repos
    /// ② 相对地址（/cfg/sub.json）按配置自身的链接补全成绝对地址
    /// ```
    const MULTI_REPO_BODY: &str =
        "{\"urls\":[{\"name\":\"子仓甲\",\"url\":\"/cfg/sub.json\"},{\"name\":\"子仓乙\",\"url\":\"http://other.test/b.json\"}]}";
    /// task-12：一份**含 sites** 的配置（两个 type=1 站）。
    ///
    /// ⚠️ api 占位符 API_PLACEHOLDER 在运行时被替换成假源站地址 ——
    ///    常量里没法知道端口，所以只能这样。
    const CFG_V2_BODY: &str =
        "{\"sites\":[{\"key\":\"k1\",\"name\":\"甲站\",\"type\":1,\"api\":\"@@API1@@\"},{\"key\":\"k3\",\"name\":\"丙站\",\"type\":1,\"api\":\"@@API3@@\"}]}";
    /// task-12：第 3 版配置 —— k1 **换了接口**（→ changed），k3 没变，k2 仍缺席。
    const CFG_V3_BODY: &str =
        "{\"sites\":[{\"key\":\"k1\",\"name\":\"甲站\",\"type\":1,\"api\":\"@@API9@@\"},{\"key\":\"k3\",\"name\":\"丙站\",\"type\":1,\"api\":\"@@API3@@\"}]}";

    // task-12：本模块的假源站要被 task12_subscription 复用（真发 HTTP），
    //          所以可见性从私有放宽到 pub(super)。
    #[derive(Debug, Clone)]
    pub(super) struct Hit {
        pub(super) method: String,
        pub(super) target: String,
        pub(super) status: u16,
        pub(super) bytes: usize,
    }

    pub(super) struct Sink {
        port: u16,
        hits: Arc<Mutex<Vec<Hit>>>,
    }

    impl Sink {
        pub(super) fn url(&self) -> String {
            format!("http://127.0.0.1:{}", self.port)
        }
        pub(super) fn hits(&self) -> Vec<Hit> {
            self.hits.lock().map(|g| g.clone()).unwrap_or_default()
        }
        fn count_method(&self, m: &str) -> usize {
            self.hits()
                .iter()
                .filter(|h| h.method.eq_ignore_ascii_case(m))
                .count()
        }
        pub(super) fn lines(&self) -> Vec<String> {
            self.hits()
                .into_iter()
                .map(|h| format!("{} {} -> {} ({} bytes)", h.method, h.target, h.status, h.bytes))
                .collect()
        }
    }

    fn status_text(s: u16) -> &'static str {
        match s {
            200 => "OK",
            404 => "Not Found",
            502 => "Bad Gateway",
            _ => "Unknown",
        }
    }

    /// 把 absolute-form（代理）与 origin-form（直连）统一成 path?query。
    fn path_of(target: &str) -> &str {
        let after_scheme = match target.find("://") {
            Some(i) => &target[i + 3..],
            None => target,
        };
        match after_scheme.find('/') {
            Some(i) => &after_scheme[i..],
            None => "/",
        }
    }

    fn route(target: &str, share: &str, host: &str) -> (u16, String, &'static str) {
        let pq = path_of(target);
        if pq.starts_with("/share") {
            (200, share.to_string(), "text/html; charset=utf-8")
        } else if pq.starts_with("/pdead") {
            (200, DEAD_BODY.to_string(), "application/json")
        } else if pq.starts_with("/pok") {
            (200, OK_BODY.to_string(), "application/json")
        } else if pq.contains("ac=list") {
            (200, CLASS_BODY.to_string(), "application/json")
        } else if pq.contains("ac=videolist") {
            (200, LIST_BODY.to_string(), "application/json")
        } else if pq.starts_with("/cfg") {
            // task-12：假的 TVBox 配置 —— 订阅链接指向它
            // api 占位符换成**请求里带的 Host** —— 常量里不知道端口
            let base = format!("http://{host}");
            let body = if pq.contains("/cfg/v2.json") {
                CFG_V2_BODY
                    .replace("@@API1@@", &format!("{base}/api.php/provide/vod"))
                    .replace("@@API3@@", &format!("{base}/api3/vod"))
            } else if pq.contains("/cfg/v3.json") {
                CFG_V3_BODY
                    .replace("@@API9@@", &format!("{base}/api9/vod"))
                    .replace("@@API3@@", &format!("{base}/api3/vod"))
            } else {
                MULTI_REPO_BODY.to_string()
            };
            (200, body, "application/json")
        } else {
            (404, "{\"error\":\"not found in fake sink\"}".to_string(), "application/json")
        }
    }

    fn handle(stream: &mut TcpStream, share: &str, hits: &Arc<Mutex<Vec<Hit>>>) -> std::io::Result<()> {
        let mut reader = BufReader::new(stream.try_clone()?);
        let mut request_line = String::new();
        if reader.read_line(&mut request_line)? == 0 {
            return Ok(());
        }
        let request_line = request_line.trim_end().to_string();
        // 排空请求头，避免客户端还在写就把连接关掉（会变成 RST）
        // ★ task-12：顺手记下 Host —— 假配置里的 api 要用它拼成绝对地址
        let mut host = String::new();
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line)? == 0 {
                break;
            }
            if line == "\r\n" || line == "\n" {
                break;
            }
            let low = line.to_ascii_lowercase();
            if let Some(rest) = low.strip_prefix("host:") {
                host = rest.trim().to_string();
            }
        }
        let mut parts = request_line.split(' ');
        let method = parts.next().unwrap_or("").to_string();
        let target = parts.next().unwrap_or("").to_string();

        let (status, body, ctype) = if method.eq_ignore_ascii_case("CONNECT") {
            (502u16, "fake sink: CONNECT refused\n".to_string(), "text/plain")
        } else {
            route(&target, share, &host)
        };

        // ★ 先记账，再回包：收到即计数，不依赖客户端读成功与否
        if let Ok(mut g) = hits.lock() {
            g.push(Hit { method: method.clone(), target: target.clone(), status, bytes: body.len() });
        }

        let head = format!(
            "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            status,
            status_text(status),
            ctype,
            body.len()
        );
        stream.write_all(head.as_bytes())?;
        stream.write_all(body.as_bytes())?;
        stream.flush()?;
        Ok(())
    }

    pub(super) fn start_sink(share: &'static str) -> Sink {
        let listener = TcpListener::bind("127.0.0.1:0").expect("绑定假服务端口失败");
        let port = listener.local_addr().expect("取端口失败").port();
        let hits = Arc::new(Mutex::new(Vec::new()));
        let hits_bg = hits.clone();
        std::thread::spawn(move || {
            for conn in listener.incoming() {
                match conn {
                    Ok(mut stream) => {
                        let h = hits_bg.clone();
                        let _ = handle(&mut stream, share, &h);
                    }
                    Err(_) => break,
                }
            }
        });
        Sink { port, hits }
    }

    fn make_provider(id: &str, api: &str) -> TvboxAppleCmsProvider {
        TvboxAppleCmsProvider::new(
            id,
            "假CMS",
            api,
            vec![TvboxCategoryEntry { id: "1".to_string(), name: "电影".to_string(), pid: None }],
        )
        .expect("构造 TvboxAppleCmsProvider 失败")
    }

    fn proxied(id: &str, api: &str, sink: &Sink) -> TvboxAppleCmsProvider {
        let store = Arc::new(ProxyStore::new());
        store
            .set(
                id,
                ProxyConfig { mode: ProxyMode::Custom, url: Some(sink.url()), ..Default::default() },
            )
            .expect("配置测试代理失败");
        make_provider(id, api).with_proxy(store)
    }

    pub(super) fn unique_tmp_dir(tag: &str) -> std::path::PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        std::env::temp_dir().join(format!("sourin-task5-{tag}-{}-{nanos}", std::process::id()))
    }

    /// 把仪器记录原样打到 stdout —— 报告里的「真实读数」直接来自这些行。
    pub(super) fn dump_hits(tag: &str, hits: &[Hit]) {
        println!("[EVIDENCE] {tag} hit_count={}", hits.len());
        for (i, h) in hits.iter().enumerate() {
            println!(
                "[EVIDENCE] {tag} #{i} method={} target={} status={} bytes={}",
                h.method, h.target, h.status, h.bytes
            );
        }
    }

    // ── ① 生产代码接缝必须还在（防有人在跑之前把这几个点改掉） ───────────
    #[test]
    fn seam_pins_are_intact() {
        let src = include_str!("tvbox.rs");
        let head = src.split("mod task5_ab_restart").next().expect("split 失败");
        let count = |n: &str| head.matches(n).count();
        assert_eq!(count("pub const PARSE_SERVICES: [&str; 2] = ["), 1, "PARSE_SERVICES 应为硬编码的 2 个解析服务");
        assert_eq!(count("if !url.to_lowercase().contains(\".m3u8\") {"), 1, "resolve 里的 .m3u8 短路判断应存在且唯一");
        assert_eq!(count("found = self.try_parsers(&page_url).await;"), 1, "resolve 必须真的走到 try_parsers");
        assert_eq!(count("https://player.gimy.bot/u/parse.php?url="), 1, "解析服务 1 的地址");
        assert_eq!(count("https://api.huaqi.pro/api/?key="), 1, "解析服务 2 的地址");
    }

    // ── ② A：分享页（无 m3u8）必须真的请求两个解析服务 ────────────────────
    #[tokio::test]
    async fn a_share_page_reaches_parse_services_with_counted_requests() {
        let sink = start_sink(SHARE_PLAIN);
        let id = "task5-ab-a";
        let p = proxied(id, "http://cms.test/api.php/provide/vod", &sink);
        let page = "http://cms.test/share/55b41404d256c30aeee0e2c554dc43f6".to_string();

        let got = p.resolve(&MediaId::new(id, page.clone()), &PlayRequest::default()).await;

        let hits = sink.hits();
        dump_hits("A-share-page-no-m3u8(real PARSE_SERVICES via proxy)", &hits);
        assert_eq!(
            hits.len(),
            3,
            "A 应恰好 3 条真实请求（1×GET 分享页 + 2×CONNECT 解析服务），实际：{:?}",
            sink.lines()
        );
        let g = hits.iter().find(|h| h.method == "GET").expect("缺少分享页 GET");
        assert!(g.target.contains("/share/"), "分享页 GET 目标不对：{}", g.target);
        assert_eq!(g.status, 200, "分享页应回 200");
        assert_eq!(g.bytes, SHARE_PLAIN.len(), "分享页字节数应等于服务端应答体长度");

        assert_eq!(sink.count_method("CONNECT"), 2, "两个解析服务都必须被真实请求，实际：{:?}", sink.lines());
        let targets: Vec<String> =
            hits.iter().filter(|h| h.method == "CONNECT").map(|h| h.target.clone()).collect();
        assert!(targets.iter().any(|t| t == "player.gimy.bot:443"), "应请求 gimy，实际 {targets:?}");
        assert!(targets.iter().any(|t| t == "api.huaqi.pro:443"), "应请求 huaqi，实际 {targets:?}");
        for h in hits.iter().filter(|h| h.method == "CONNECT") {
            assert_eq!(h.status, 502, "CONNECT 应被假服务用 502 拒掉：{}", h.target);
            assert!(h.bytes > 0, "CONNECT 也应有真实回包字节：{}", h.target);
        }

        let e = got.expect_err("分享页刮不出 m3u8 且解析服务全挂，必须报错");
        assert_eq!(e.kind, ErrorKind::Unsupported, "kind 应为 Unsupported，实际 {:?}：{}", e.kind, e.message);
        assert!(e.message.contains("这个源没有可直接播放的地址"), "message 实际：{}", e.message);
        assert!(!e.message.contains("爱奇艺"), "cms.test 不含第三方站点关键词，不该走那句文案：{}", e.message);
    }

    // ── ③ A 对照：分享页里已有 m3u8 ⇒ 解析服务请求数必须为 0 ──────────────
    #[tokio::test]
    async fn a_control_share_page_with_m3u8_never_touches_parse_services() {
        let sink = start_sink(SHARE_WITH_M3U8);
        let id = "task5-ab-a-ctl";
        let p = proxied(id, "http://cms.test/api.php/provide/vod", &sink);

        let got = p
            .resolve(
                &MediaId::new(id, "http://cms.test/share/55b41404d256c30aeee0e2c554dc43f6".to_string()),
                &PlayRequest::default(),
            )
            .await
            .expect("分享页里能刮出 m3u8，应成功");

        let hits = sink.hits();
        dump_hits("A-control-share-page-with-m3u8", &hits);
        assert_eq!(hits.len(), 1, "只该有 1 条分享页请求，实际：{:?}", sink.lines());
        assert_eq!(sink.count_method("CONNECT"), 0, "页面里已经有 m3u8，不该再请求解析服务：{:?}", sink.lines());
        assert_eq!(got.len(), 1);
        assert!(got[0].url.contains("cdn.control"), "刮出的地址应来自页面，实际 {}", got[0].url);
        assert!(got[0].url.contains(".m3u8"), "实际 {}", got[0].url);
        assert_eq!(got[0].kind, StreamKind::Hls);
    }

    // ── ④ B：直链 .m3u8 短路，总请求数 0（与 A 的 3 条构成反转） ──────────
    #[tokio::test]
    async fn b_direct_m3u8_short_circuits_with_zero_requests() {
        let sink = start_sink(SHARE_PLAIN); // 与 A 完全相同的仪器，且已挂上
        let id = "task5-ab-b";
        let p = proxied(id, "http://cms.test/api.php/provide/vod", &sink);
        let direct = "http://cms.test/live/direct/x.m3u8".to_string();

        let got = p
            .resolve(&MediaId::new(id, direct.clone()), &PlayRequest::default())
            .await
            .expect("直链 m3u8 应直接成功");

        let hits = sink.hits();
        dump_hits("B-direct-m3u8-short-circuit", &hits);
        assert_eq!(hits.len(), 0, "B 必须零请求（A 是 3 条），实际：{:?}", sink.lines());
        assert_eq!(sink.count_method("CONNECT"), 0, "B 绝不能碰解析服务");
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].url, direct, "直链必须原样返回");
        assert_eq!(got[0].kind, StreamKind::Hls);
    }

    // ── ⑤ 解析服务：第一个挂（200 但解析失败）→ 换第二个 → 拿到真地址 ──────
    #[tokio::test]
    async fn parse_service_failure_then_success_returns_real_url() {
        let sink = start_sink(SHARE_PLAIN);
        let p = make_provider("task5-ab-parse", "http://cms.test/api.php/provide/vod");
        let dead = format!("{}/pdead?u=", sink.url());
        let ok = format!("{}/pok?u=", sink.url());

        let got = p.try_parsers_with("http://cms.test/share/xxx", &[dead.as_str(), ok.as_str()]).await;
        assert_eq!(got.as_deref(), Some("http://cdn.test/real/ok.m3u8"), "第二个解析服务应被采纳，实际 {got:?}");

        let hits = sink.hits();
        dump_hits("parse-service-fail-then-ok", &hits);
        assert_eq!(hits.len(), 2, "两个解析服务都应被真实请求，实际：{:?}", sink.lines());
        assert!(hits[0].target.contains("/pdead?u="), "第 1 条应是死接口，实际 {}", hits[0].target);
        assert_eq!(hits[0].status, 200);
        assert_eq!(hits[0].bytes, DEAD_BODY.len(), "死接口也要有真实回包字节（200 但无 url 字段）");
        assert!(hits[1].target.contains("/pok?u="), "第 2 条应是可用接口，实际 {}", hits[1].target);
        assert_eq!(hits[1].status, 200);
        assert_eq!(hits[1].bytes, OK_BODY.len());
    }

    // ── ⑥ C：导入 → 重启（同一数据目录二次 bootstrap）后源还在 ─────────────
    #[tokio::test]
    async fn c_import_then_restart_keeps_the_source() {
        // 保险：别让 bootstrap 里的远程自启去等 8642 端口
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");

        let sink = start_sink(SHARE_PLAIN);
        let dir = unique_tmp_dir("c");
        std::fs::create_dir_all(&dir).expect("建临时目录失败");

        let cfg = format!(
            "{{\"sites\":[{{\"key\":\"cms1\",\"name\":\"假CMS\",\"type\":1,\"api\":\"{}/api.php/provide/vod\"}}]}}",
            sink.url()
        );

        let st = AppState::bootstrap(dir.clone()).await.expect("首次 bootstrap 失败");
        let res = import_tvbox_config(&st, &cfg).await.expect("导入失败");
        println!("[EVIDENCE] C-import-result {res}");
        assert_eq!(res["totalSites"], 1u64, "实际 {res}");
        assert_eq!(
            res["imported"].as_array().map(|a| a.len()).unwrap_or(0),
            1,
            "应导入 1 个源（探测失败会进 skipped），实际 {res}"
        );
        let id = res["imported"][0]["id"].as_str().unwrap_or_default().to_string();
        assert!(!id.is_empty(), "导入结果必须带 id，实际 {res}");

        let live = st
            .registry
            .manifests()
            .into_iter()
            .find(|m| m.kind == "tvbox" && m.name == "假CMS")
            .expect("导入当场注册表里就该有这个源");
        assert_eq!(live.id, id, "导入结果里的 id 应与注册表一致");
        assert!(live.working, "刚导入的源应可用");
        println!(
            "[EVIDENCE] C-after-import id={} kind={} name={} working={}",
            live.id, live.kind, live.name, live.working
        );

        let file = crate::persist::providers_file(&dir);
        assert!(file.exists(), "第三方源清单应已落盘：{}", file.display());
        let text = std::fs::read_to_string(&file).unwrap_or_default();
        println!("[EVIDENCE] C-persisted-file {} bytes={}", file.display(), text.len());
        println!("[EVIDENCE] C-persisted-body {text}");
        assert!(text.contains(&id), "清单文件应记录 {id}，实际内容：{text}");
        drop(st);

        // 重启
        let st2 = AppState::bootstrap(dir.clone()).await.expect("重启 bootstrap 失败");
        let again = st2
            .registry
            .manifests()
            .into_iter()
            .find(|m| m.id == id)
            .expect("重启后源应仍在注册表里");
        assert_eq!(again.kind, "tvbox");
        assert_eq!(again.name, "假CMS");
        assert!(again.working, "重启恢复的源应仍为可用状态");
        println!(
            "[EVIDENCE] C-after-restart id={} kind={} name={} working={}",
            again.id, again.kind, again.name, again.working
        );
        drop(st2);

        let _ = std::fs::remove_dir_all(&dir);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  task12_subscription —— TVBox 订阅链接 + 检测更新的端到端测试
// ═══════════════════════════════════════════════════════════════════════════
//
// 与 task5_ab_restart 的区别：
// ```text
// task5   验证「解析 / 播放」链路（假解析服务 + 假源站）
// task12  验证「订阅 / 检测更新」链路（假源站当配置宿主，真发 HTTP）
// ```
// ★ 全部走 127.0.0.1，不碰公网、不碰用户数据目录（unique_tmp_dir）。
#[cfg(test)]
mod task12_subscription {
    use super::*;
    use crate::state::AppState;

    /// 本地已注册的 TVBox 源（按 id 查，返回 (id,name,api)）
    fn local_of(st: &AppState, id: &str) -> Option<(String, String, String)> {
        st.third_party
            .read()
            .ok()?
            .iter()
            .find_map(|x| match x {
                crate::model::PersistedProvider::Tvbox { id: pid, name, api, .. }
                    if pid == id =>
                {
                    Some((pid.clone(), name.clone(), api.clone()))
                }
                _ => None,
            })
    }

    fn remote(key: &str, name: &str, api: &str) -> RemoteSite {
        RemoteSite {
            key: key.to_string(),
            name: name.to_string(),
            api: api.to_string(),
        }
    }

    fn local(id: &str, key: &str, name: &str, api: &str) -> LocalSite {
        LocalSite {
            id: id.to_string(),
            key: key.to_string(),
            name: name.to_string(),
            api: api.to_string(),
            // 单测默认都是"本订阅的"
            in_link: true,
        }
    }

    /// 假源站上「能通过探测」的 api 地址
    fn fake_api(sink: &super::task5_ab_restart::Sink) -> String {
        format!("{}/api.php/provide/vod", sink.url())
    }

    // ── ① 纯函数：diff_sites 的配对规则 ──────────────────────────────────
    #[test]
    fn diff_pairs_by_key_then_api_and_never_hides_removed() {
        let l = vec![
            local("a", "k1", "甲", "http://a.test/vod"),
            local("b", "k2", "乙", "http://b.test/vod"),
            // 老数据：没有 key，只能靠 api 认
            local("c", "", "丙", "http://c.test/vod"),
        ];
        let r = vec![
            // k1 还在，但换了接口和名字 → changed
            remote("k1", "甲（新）", "http://a2.test/vod"),
            // k2 没了 → removed（只在本地）
            // c 靠 api 配上 → unchanged
            remote("", "丙", "http://c.test/vod"),
            // 新增
            remote("k9", "丁", "http://d.test/vod"),
        ];
        let d = diff_sites(&l, &r);
        println!(
            "[EVIDENCE] T12-diff added={:?} removed={:?} changed={:?} unchanged={}",
            d.added.iter().map(|x| &x.name).collect::<Vec<_>>(),
            d.removed.iter().map(|x| &x.name).collect::<Vec<_>>(),
            d.changed
                .iter()
                .map(|x| format!("{} -> {}", x.old_api, x.new_api))
                .collect::<Vec<_>>(),
            d.unchanged
        );
        assert_eq!(d.added.len(), 1, "应识别 1 个新增");
        assert_eq!(d.added[0].name, "丁");
        assert_eq!(d.removed.len(), 1, "应识别 1 个消失");
        assert_eq!(d.removed[0].id, "b", "消失的应是 k2（乙）");
        assert_eq!(d.changed.len(), 1, "应识别 1 个变更");
        assert_eq!(d.changed[0].id, "a", "变更的应是 k1（甲）");
        assert_eq!(d.changed[0].old_api, "http://a.test/vod");
        assert_eq!(d.changed[0].new_api, "http://a2.test/vod");
        assert_eq!(d.unchanged, 1, "丙 应算没变");
        assert_eq!(d.added_idx, vec![2], "新增在远端列表里的下标应为 2");
        assert_eq!(d.changed_idx, vec![0], "变更在远端列表里的下标应为 0");
    }

    /// ⚠️ 归一化：...vod?ac=list 与 ...vod 是**同一个站**，不能报成新增+消失。
    #[test]
    fn diff_normalizes_api_query_string() {
        let l = vec![local("a", "", "甲", "https://a.test/api.php/provide/vod")];
        let r = vec![remote("", "甲", "https://a.test/api.php/provide/vod?ac=list")];
        let d = diff_sites(&l, &r);
        println!(
            "[EVIDENCE] T12-normalize added={} removed={} changed={} unchanged={}",
            d.added.len(),
            d.removed.len(),
            d.changed.len(),
            d.unchanged
        );
        assert!(d.added.is_empty(), "不该报新增（只是带了 ?ac=list）：{:?}", d.added);
        assert!(d.removed.is_empty(), "不该报消失：{:?}", d.removed);
        assert_eq!(d.unchanged, 1);
    }

    /// 站换了域名但 key 没变 → 必须是 changed，而不是「新增 + 消失」。
    #[test]
    fn diff_same_key_new_domain_is_changed_not_added_and_removed() {
        let l = vec![local("a", "k1", "甲", "https://old.test/vod")];
        let r = vec![remote("k1", "甲", "https://new.test/vod")];
        let d = diff_sites(&l, &r);
        assert_eq!(d.added.len(), 0, "换域名不该算新增");
        assert_eq!(d.removed.len(), 0, "换域名不该算消失");
        assert_eq!(d.changed.len(), 1);
        assert_eq!(d.changed[0].id, "a", "必须沿用原 id，否则用户设过的启用状态会丢");
    }

    // ── ② 纯函数：多仓子仓清单 ───────────────────────────────────────────
    #[test]
    fn multi_repo_repos_accepts_objects_and_strings_and_absolutizes() {
        let cfg: serde_json::Value = serde_json::json!({
            "urls": [
                {"name": "子仓甲", "url": "/cfg/sub.json"},
                {"url": "https://b.test/x.json"},
                "https://c.test/y.json"
            ]
        });
        let repos = multi_repo_repos(&cfg, "https://host.test/config.json");
        println!("[EVIDENCE] T12-repos {repos:?}");
        assert_eq!(repos.len(), 3, "两种形态都要收：{repos:?}");
        assert_eq!(repos[0]["name"], "子仓甲");
        assert_eq!(repos[0]["url"], "https://host.test/cfg/sub.json", "相对地址要按配置链接补全");
        assert_eq!(repos[1]["url"], "https://b.test/x.json");
        assert_eq!(repos[1]["name"], "https://b.test/x.json", "没写 name 就用地址兜底");
        assert_eq!(repos[2]["url"], "https://c.test/y.json", "纯字符串形态也要收");
    }

    // ── ③ 端到端：文本导入 → 补链接 → 落盘 → 重启仍在 ───────────────────
    #[tokio::test]
    async fn e2e_subscription_survives_restart() {
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
        let sink = super::task5_ab_restart::start_sink(super::task5_ab_restart::SHARE_PLAIN);
        let api = fake_api(&sink);
        let dir = super::task5_ab_restart::unique_tmp_dir("t12a");
        std::fs::create_dir_all(&dir).expect("建临时目录失败");

        let cfg = format!(
            "{{\"sites\":[\
               {{\"key\":\"k1\",\"name\":\"甲站\",\"type\":1,\"api\":\"{api}\"}},\
               {{\"key\":\"k2\",\"name\":\"乙站\",\"type\":1,\"api\":\"{api}\"}}\
             ]}}"
        );

        let st = AppState::bootstrap(dir.clone()).await.expect("首次 bootstrap 失败");
        // ── ③-1 贴**文本**导入：没有链接可查 ──────────────────────────
        let res = import_tvbox_config(&st, &cfg).await.expect("文本导入失败");
        println!("[EVIDENCE] T12-import-text {res}");
        assert_eq!(res["imported"].as_array().map(|a| a.len()), Some(2), "应导入 2 个源");

        let listed = list_tvbox_sources(&st).expect("列出源失败");
        println!("[EVIDENCE] T12-list-after-text-import {listed}");
        assert_eq!(listed["total"], 2u64);
        assert_eq!(
            listed["withSource"],
            0u64,
            "贴文本导入的源不该有订阅链接（没有的能力不假装有）"
        );
        // ★ site key 是**导入那一刻**就知道的事实（来自 sites[]），
        //   与"有没有链接"无关 —— 必须记，否则事后补链接时配对只能退化成
        //   按 api 认，"换了域名"就会被误报成「新增 + 消失」。
        assert!(
            listed["sources"]
                .as_array()
                .map(|a| a.iter().all(|x| x["siteKey"] != ""))
                .unwrap_or(false),
            "site key 必须随导入一起记下来：{listed}"
        );
        assert!(
            listed["sources"]
                .as_array()
                .map(|a| a
                    .iter()
                    .all(|x| x["needsSource"] == serde_json::Value::Bool(true)))
                .unwrap_or(false),
            "每个源都该如实标 needsSource=true：{listed}"
        );

        let checked0 = check_tvbox_updates(&st, None).await.expect("检测不该报错");
        println!("[EVIDENCE] T12-check-no-source {checked0}");
        assert_eq!(checked0["checked"], 0u64, "没有链接 → 一个链接都不查");
        assert_eq!(checked0["skipped"], 2u64, "两个源都如实进 skipped");
        assert_eq!(checked0["items"].as_array().map(|a| a.len()), Some(0), "不该产出任何条目");

        // ── ③-2 事后补一个订阅链接（set_tvbox_source）─────────────────
        let first_id = res["imported"][0]["id"].as_str().unwrap_or_default().to_string();
        let second_id = res["imported"][1]["id"].as_str().unwrap_or_default().to_string();
        assert!(!first_id.is_empty() && !second_id.is_empty(), "导入结果必须带 id：{res}");
        let cfg_url = format!("{}/cfg/sub.json", sink.url());
        let set = set_tvbox_source(&st, &first_id, &cfg_url).expect("补链接失败");
        println!("[EVIDENCE] T12-set-source {set}");
        assert_eq!(set["sourceUrl"], cfg_url);

        let listed2 = list_tvbox_sources(&st).expect("列出源失败");
        assert_eq!(listed2["withSource"], 1u64, "补完链接后应有 1 个源有链接：{listed2}");

        // 非法链接要如实拒绝
        let bad = set_tvbox_source(&st, &first_id, "not-a-url");
        assert!(bad.is_err(), "非 http 链接应被拒绝：{bad:?}");
        assert!(bad.unwrap_err().contains("http"), "错误文案要说清楚");

        // ── ③-3 链接指向**多仓** → 检测如实报告，不硬凑 ────────────────
        let chk_multi = check_tvbox_updates(&st, None).await.expect("检测失败");
        println!("[EVIDENCE] T12-check-multirepo {chk_multi}");
        assert_eq!(chk_multi["checked"], 1u64, "只该查 1 个链接");
        let item = &chk_multi["items"][0];
        assert_eq!(item["ok"], serde_json::Value::Bool(false), "多仓链接应如实标 ok=false");
        assert_eq!(item["multiRepo"], serde_json::Value::Bool(true), "应标出这是多仓");
        let repos = item["repos"].as_array().cloned().unwrap_or_default();
        assert_eq!(repos.len(), 2, "应列出 2 个子仓：{item}");
        assert_eq!(repos[0]["url"], format!("{}/cfg/sub.json", sink.url()), "相对地址要补全");
        assert_eq!(repos[0]["name"], "子仓甲");
        assert_eq!(repos[1]["name"], "子仓乙");
        assert!(
            item["error"].as_str().unwrap_or("").contains("多仓"),
            "错误文案要说清楚为什么查不了：{item}"
        );
        let hits_cfg = sink.hits();
        super::task5_ab_restart::dump_hits("T12-check-multirepo", &hits_cfg);
        assert!(
            hits_cfg.iter().any(|h| h.target.contains("/cfg/sub.json")),
            "必须真的发过 GET 去下载配置：{:?}",
            sink.lines()
        );

        // ── ③-4 多仓配置**导入**：不再报错，而是列出子仓供选择 ──────────
        let res_multi = import_tvbox_config(&st, &cfg_url).await.expect("多仓导入不该失败");
        println!("[EVIDENCE] T12-import-multirepo {res_multi}");
        assert_eq!(res_multi["multiRepo"], serde_json::Value::Bool(true), "应标 multiRepo=true");
        assert_eq!(
            res_multi["imported"].as_array().map(|a| a.len()),
            Some(0),
            "多仓本身不产出任何源（不假装有能力）"
        );
        let mrepos = res_multi["repos"].as_array().cloned().unwrap_or_default();
        assert_eq!(mrepos.len(), 2, "应列出 2 个子仓：{res_multi}");
        assert_eq!(mrepos[0]["name"], "子仓甲");
        assert_eq!(mrepos[0]["url"], format!("{}/cfg/sub.json", sink.url()));

        // ── ③-5 链接是多仓 → 一键更新如实报错，且**不动本地** ───────────
        set_tvbox_source(&st, &second_id, &cfg_url).expect("给第二个源补链接失败");
        let upd_err = update_tvbox_source(&st, &first_id, true, false).await;
        println!("[EVIDENCE] T12-update-on-multirepo {upd_err:?}");
        assert!(upd_err.is_err(), "链接是多仓时更新应如实报错，而不是假装成功");
        assert!(
            upd_err.as_ref().unwrap_err().contains("多仓"),
            "错误文案要说清楚：{:?}",
            upd_err
        );
        assert!(local_of(&st, &first_id).is_some(), "报错后本地源必须还在");
        assert!(local_of(&st, &second_id).is_some(), "报错后本地源必须还在");

        // ── ③-6 侧车文件真的落盘了，且重启后还在 ────────────────────────
        let sidecar = tvbox_meta_file(&dir);
        assert!(sidecar.exists(), "订阅 sidecar 应已落盘：{}", sidecar.display());
        let raw = std::fs::read_to_string(&sidecar).unwrap_or_default();
        println!("[EVIDENCE] T12-sidecar {} bytes={}", sidecar.display(), raw.len());
        println!("[EVIDENCE] T12-sidecar-body {raw}");
        assert!(raw.contains(&first_id), "sidecar 应记录 {first_id}");
        assert!(raw.contains(&cfg_url), "sidecar 应记录订阅链接 {cfg_url}");
        assert!(raw.contains("siteKey"), "sidecar 应记录 site key：{raw}");
        drop(st);

        let st2 = AppState::bootstrap(dir.clone()).await.expect("重启 bootstrap 失败");
        let listed3 = list_tvbox_sources(&st2).expect("重启后列出源失败");
        println!("[EVIDENCE] T12-list-after-restart {listed3}");
        assert_eq!(listed3["total"], 2u64, "重启后两个源都应在：{listed3}");
        assert_eq!(
            listed3["withSource"],
            2u64,
            "重启后订阅链接必须还在（这正是用户要的「不至于更新失效」）：{listed3}"
        );
        let one = listed3["sources"]
            .as_array()
            .and_then(|a| a.iter().find(|x| x["id"] == first_id.as_str()))
            .cloned()
            .unwrap_or(serde_json::Value::Null);
        assert_eq!(one["sourceUrl"], cfg_url, "重启后链接应与写入时一致：{one}");
        assert_eq!(one["needsSource"], serde_json::Value::Bool(false));
        assert_eq!(one["siteKey"], "k1", "site key 也要能恢复：{one}");
        assert!(local_of(&st2, &first_id).is_some(), "重启后源本体也应还在");
        drop(st2);

        // 清链接：回到「贴文本导入」状态
        let st3 = AppState::bootstrap(dir.clone()).await.expect("三次 bootstrap 失败");
        set_tvbox_source(&st3, &first_id, "").expect("清链接失败");
        let listed4 = list_tvbox_sources(&st3).expect("列出源失败");
        assert_eq!(listed4["withSource"], 1u64, "清掉一个后应剩 1 个：{listed4}");
        drop(st3);

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ── ④ 检测更新 + 一键更新（真发 HTTP，默认只加不删）────────────────
    #[tokio::test]
    async fn e2e_check_and_apply_never_deletes_by_default() {
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
        let sink = super::task5_ab_restart::start_sink(super::task5_ab_restart::SHARE_PLAIN);
        let api = fake_api(&sink);
        let dir = super::task5_ab_restart::unique_tmp_dir("t12b");
        std::fs::create_dir_all(&dir).expect("建临时目录失败");
        let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap 失败");

        // 本地先有两个源：k1 甲站（api1）/ k2 乙站（api2）
        let cfg_local = format!(
            "{{\"sites\":[\
               {{\"key\":\"k1\",\"name\":\"甲站\",\"type\":1,\"api\":\"{api}\"}},\
               {{\"key\":\"k2\",\"name\":\"乙站\",\"type\":1,\"api\":\"{api}\"}}\
             ]}}"
        );
        let res = import_tvbox_config(&st, &cfg_local).await.expect("导入失败");
        let ids: Vec<String> = res["imported"]
            .as_array()
            .map(|a| {
                a.iter()
                    .map(|x| x["id"].as_str().unwrap_or_default().to_string())
                    .collect()
            })
            .unwrap_or_default();
        assert_eq!(ids.len(), 2, "应导入 2 个源：{res}");
        // 直接写 sidecar：记成 k1/k2（两个源共用同一个订阅链接）
        let sub_url = format!("{}/cfg/v2.json", sink.url());
        for (i, id) in ids.iter().enumerate() {
            let meta = TvboxSourceMeta {
                source_url: Some(sub_url.clone()),
                site_key: if i == 0 { "k1".to_string() } else { "k2".to_string() },
                site_name: if i == 0 { "甲站".to_string() } else { "乙站".to_string() },
                api: api.clone(),
                installed_at: now_secs(),
            };
            write_tvbox_meta(&dir, id, &meta).expect("写 sidecar 失败");
        }
        let listed0 = list_tvbox_sources(&st).expect("列出源失败");
        println!("[EVIDENCE] T12-list-before-check {listed0}");
        assert_eq!(listed0["withSource"], 2u64, "两个源都该有链接：{listed0}");

        // ── ④-1 检测：v2 里 k1 不变 / k3 新增 / k2 消失 ────────────────
        let chk = check_tvbox_updates(&st, None).await.expect("检测失败");
        println!("[EVIDENCE] T12-check-v2 {chk}");
        assert_eq!(chk["checked"], 1u64, "两个源共用一个链接 → 只查 1 次");
        let it = &chk["items"][0];
        assert_eq!(it["ok"], serde_json::Value::Bool(true), "v2 应能解析：{it}");
        assert_eq!(it["sourceUrl"], sub_url);
        assert_eq!(it["remoteTotalSites"], 2u64, "v2 里 2 个 site");
        assert_eq!(it["remoteConvertible"], 2u64, "v2 里 2 个 type=1");
        assert_eq!(it["added"].as_array().map(|a| a.len()), Some(1), "k3 应算新增：{it}");
        assert_eq!(it["added"][0]["name"], "丙站");
        assert_eq!(
            it["added"][0]["api"],
            format!("{}/api3/vod", sink.url()),
            "相对/绝对地址要正确：{it}"
        );
        assert_eq!(it["removed"].as_array().map(|a| a.len()), Some(1), "k2 应算消失：{it}");
        assert_eq!(it["unchanged"].as_u64().unwrap_or(0), 1, "k1 应算没变：{it}");
        let hits1 = sink.hits();
        super::task5_ab_restart::dump_hits("T12-check-v2", &hits1);
        assert!(
            hits1.iter().any(|h| h.target.contains("/cfg/v2.json")),
            "检测必须真的联网下载配置：{:?}",
            sink.lines()
        );

        // ── ④-2 一键更新（applyNew=true / deleteMissing=false）──────────
        let upd = update_tvbox_source(&st, &ids[0], true, false).await.expect("更新失败");
        println!("[EVIDENCE] T12-update-apply-new-no-delete {upd}");
        assert_eq!(upd["updated"], serde_json::Value::Bool(true), "应有新增：{upd}");
        assert_eq!(upd["added"].as_array().map(|a| a.len()), Some(1), "应加入 1 个新站：{upd}");
        assert_eq!(upd["added"][0]["name"], "丙站");
        assert_eq!(upd["changed"].as_array().map(|a| a.len()), Some(0), "没有变更：{upd}");
        assert_eq!(upd["deleted"].as_array().map(|a| a.len()), Some(0), "★ 默认绝不删：{upd}");
        assert_eq!(
            upd["removed"].as_array().map(|a| a.len()),
            Some(1),
            "消失的站要如实报告：{upd}"
        );
        assert!(local_of(&st, &ids[1]).is_some(), "★ 消失的站必须还在（没勾删除）");
        let listed1 = list_tvbox_sources(&st).expect("列出源失败");
        println!("[EVIDENCE] T12-list-after-update {listed1}");
        assert_eq!(listed1["total"], 3u64, "更新后应是 3 个源：{listed1}");
        let new_id = upd["added"][0]["id"].as_str().unwrap_or_default().to_string();
        assert!(!new_id.is_empty(), "新加入的站必须带 id：{upd}");
        assert!(local_of(&st, &new_id).is_some(), "新站应已持久化");
        assert!(
            read_tvbox_meta(&dir, &new_id).is_some(),
            "新站的订阅链接也要落盘（否则下次检测不到它）"
        );
        // 新站**绝不能**顶掉已有源
        assert!(local_of(&st, &ids[0]).is_some(), "老站不能被顶掉");
        assert_eq!(local_of(&st, &ids[0]).unwrap().2, api, "老站接口不该变");

        // ── ④-3 再更新一次：应如实说「无需更新」，但仍报告消失的站 ───────
        let upd2 = update_tvbox_source(&st, &ids[0], true, false).await.expect("二次更新失败");
        println!("[EVIDENCE] T12-update-again {upd2}");
        assert_eq!(upd2["updated"], serde_json::Value::Bool(false), "第二次应无变化：{upd2}");
        assert_eq!(upd2["reason"], "远端配置与本地一致，无需更新");
        assert_eq!(
            upd2["removed"].as_array().map(|a| a.len()),
            Some(1),
            "★ 即使没更新也要如实报告远端已消失的站：{upd2}"
        );

        // ── ④-4 变更：链接切到 v3（k1 换接口）→ changed ─────────────────
        let v3 = format!("{}/cfg/v3.json", sink.url());
        set_tvbox_source(&st, &ids[0], &v3).expect("改链接失败");
        let chk3 = check_tvbox_updates(&st, None).await.expect("检测失败");
        println!("[EVIDENCE] T12-check-v3 {chk3}");
        let items3 = chk3["items"].as_array().cloned().unwrap_or_default();
        let i3 = items3
            .iter()
            .find(|x| x["sourceUrl"] == v3.as_str())
            .cloned()
            .expect("应有一条 v3 的检测结果");
        assert_eq!(i3["changed"].as_array().map(|a| a.len()), Some(1), "k1 应算变更：{i3}");
        assert_eq!(i3["changed"][0]["id"], ids[0].as_str(), "变更必须沿用原 id：{i3}");
        assert_eq!(
            i3["changed"][0]["newApi"],
            format!("{}/api9/vod", sink.url()),
            "变更后的接口地址：{i3}"
        );

        let upd3 = update_tvbox_source(&st, &ids[0], true, false).await.expect("更新失败");
        println!("[EVIDENCE] T12-update-changed {upd3}");
        assert_eq!(upd3["changed"].as_array().map(|a| a.len()), Some(1), "应有 1 个变更：{upd3}");
        assert_eq!(upd3["changed"][0]["id"], ids[0].as_str());
        assert_eq!(
            upd3["added"].as_array().map(|a| a.len()),
            Some(0),
            "k3 已在本地，不该再报新增：{upd3}"
        );
        let after = local_of(&st, &ids[0]).expect("源应还在");
        assert_eq!(after.2, format!("{}/api9/vod", sink.url()), "接口应已更新：{after:?}");
        assert_eq!(after.1, "甲站", "名字不该变");

        // ── ④-5 deleteMissing=true 才删（用户明确勾选）──────────────────
        let v2 = format!("{}/cfg/v2.json", sink.url());
        set_tvbox_source(&st, &ids[0], &v2).expect("改回 v2 失败");
        let upd4 = update_tvbox_source(&st, &ids[0], true, true).await.expect("带删除的更新失败");
        println!("[EVIDENCE] T12-update-delete-missing {upd4}");
        assert_eq!(upd4["deleted"].as_array().map(|a| a.len()), Some(1), "勾选后才应删：{upd4}");
        assert_eq!(upd4["deleted"][0]["id"], ids[1].as_str());
        assert!(local_of(&st, &ids[1]).is_none(), "勾选后消失的站应被移除");
        assert!(
            read_tvbox_meta(&dir, &ids[1]).is_none(),
            "删源必须同时清掉它的订阅链接（否则将来 id 复用会继承陈旧链接）"
        );

        // ── ④-6 remove_tvbox_source：删源 + 清链接 ──────────────────────
        let rm = remove_tvbox_source(&st, &ids[0]).expect("删源失败");
        println!("[EVIDENCE] T12-remove {rm}");
        assert_eq!(rm["removed"], serde_json::Value::Bool(true));
        assert!(read_tvbox_meta(&dir, &ids[0]).is_none(), "删源后链接也该没了");
        let listed2 = list_tvbox_sources(&st).expect("列出源失败");
        println!("[EVIDENCE] T12-list-final {listed2}");
        assert_eq!(listed2["total"], 1u64, "删掉 2 个后应剩 1 个：{listed2}");
        // 幂等：再删一次不报错
        let rm2 = remove_tvbox_source(&st, &ids[0]).expect("重复删源不该报错");
        assert_eq!(rm2["removed"], serde_json::Value::Bool(false));

        // ── ④-7 找不到的 id：如实报错 ──────────────────────────────────
        assert!(update_tvbox_source(&st, "no-such-id", true, false).await.is_err());
        assert!(check_tvbox_updates(&st, Some("no-such-id")).await.is_err());
        assert!(set_tvbox_source(&st, "no-such-id", "http://x.test/a.json").is_err());
        drop(st);

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ── ⑤ 坏 sidecar 不能让设置页打不开（容错）──────────────────────────
    #[tokio::test]
    async fn corrupt_sidecar_degrades_to_no_source() {
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
        let dir = super::task5_ab_restart::unique_tmp_dir("t12c");
        std::fs::create_dir_all(&dir).expect("建临时目录失败");
        std::fs::write(tvbox_meta_file(&dir), "{ 这不是 JSON").expect("写坏文件失败");

        let metas = load_tvbox_metas(&dir);
        println!("[EVIDENCE] T12-corrupt-sidecar metas={}", metas.len());
        assert!(metas.is_empty(), "坏文件应退化成空 map，而不是 panic/Err");
        assert!(read_tvbox_meta(&dir, "whatever").is_none());

        // 坏文件存在时仍能正常写入（覆盖掉它）
        let meta = TvboxSourceMeta {
            source_url: Some("http://x.test/a.json".to_string()),
            site_key: "k".to_string(),
            site_name: "甲".to_string(),
            api: "http://x.test/api".to_string(),
            installed_at: 1,
        };
        write_tvbox_meta(&dir, "id1", &meta).expect("覆盖坏文件失败");
        let got = read_tvbox_meta(&dir, "id1").expect("应能读回");
        assert_eq!(got.site_key, "k");
        assert_eq!(got.source_url.as_deref(), Some("http://x.test/a.json"));

        // 幂等删除
        forget_tvbox_meta(&dir, "id1").expect("删除失败");
        forget_tvbox_meta(&dir, "id1").expect("重复删除应幂等");
        assert!(read_tvbox_meta(&dir, "id1").is_none());
        // 空 id 要拒绝
        assert!(write_tvbox_meta(&dir, "", &meta).is_err(), "空 id 应被拒绝");

        // 文件不存在时读也是空（不是错误）
        let dir2 = super::task5_ab_restart::unique_tmp_dir("t12d");
        assert!(load_tvbox_metas(&dir2).is_empty(), "文件不存在应返回空 map");

        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&dir2);
    }
}

// ───────────────────────────────────────────────────────────────────────
//  ⚠️ 以下测试**要联网**，默认不跑（cargo test 会 skip）。
//     手动取证：
//     cargo test --lib real_sites -- --ignored --nocapture --test-threads=1
//
// 为什么不放进默认套件：它们依赖第三方站点是否可达 —— 别人家的站点
// 挂了不该让本仓库的 CI 变红。但它们**必须存在**：
// ```text
// 单元测试只能证明"我写的解析对"，证明不了"真实配置长这样"。
// 前者用假数据自证，后者只能拿真站点跑。
// ```
#[cfg(test)]
mod real_sites {
    use super::*;
    use crate::state::AppState;

    /// 用户实测可用的两个真实 TVBox 配置地址
    const SITES: [(&str, &str); 2] = [
        ("王二小", "https://9280.kstore.vip/newwex.json"),
        ("菜妮丝", "https://tv.xn--yhqu5zs87a.top"),
    ];

    /// 真实下载 + 解析：只证明"我读得懂真实配置"
    #[tokio::test]
    #[ignore = "需要联网，手动跑：cargo test --lib real_sites -- --ignored --nocapture"]
    async fn real_configs_parse_and_report_what_is_convertible() {
        let client = probe_client();
        for (label, url) in SITES.iter() {
            let text = match fetch_config_text(&client, url).await {
                Ok(t) => t,
                Err(e) => {
                    println!("[EVIDENCE] REAL-download {label} 失败（跳过，不算失败）：{e}");
                    continue;
                }
            };
            let cfg = match parse_loose_json(&text) {
                Ok(c) => c,
                Err(e) => {
                    // 如实取证：把**实际拿到的前 300 字节**打出来，
                    // 否则"解析失败"无法定位（是反爬页？是空 body？）
                    let head: String = text.chars().take(300).collect();
                    println!(
                        "[EVIDENCE] REAL-parse {label} 失败：{e}；textLen={} head={:?}",
                        text.len(),
                        head
                    );
                    continue;
                }
            };
            let (jobs, skipped, lives) = collect_sites(&cfg, url);
            let mut by_type: std::collections::BTreeMap<String, usize> = Default::default();
            for s in skipped.iter() {
                let k = s
                    .get("type")
                    .map(|v| v.to_string())
                    .unwrap_or_else(|| "null".to_string());
                *by_type.entry(k).or_insert(0) += 1;
            }
            println!(
                "[EVIDENCE] REAL {label} url={url} bytes={} sites={} convertible={} skipped={} lives={} byType={:?}",
                text.len(),
                cfg.get("sites").and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0),
                jobs.len(),
                skipped.len(),
                lives.len(),
                by_type
            );
            if let Some(j) = jobs.first() {
                println!("[EVIDENCE] REAL {label} first-convertible key={} name={} api={}", j.key, j.name, j.api);
            }
            // 多仓检测：真实配置里也会出现只有 urls 的（那时这里会打印出来）
            let repos = multi_repo_repos(&cfg, url);
            println!("[EVIDENCE] REAL {label} multiRepoRepos={}", repos.len());
        }
    }

    /// 诊断：为什么同一个 URL 在不同客户端上返回不同内容
    ///
    /// 实测（2026-10-04）菜妮丝 https://tv.xn--yhqu5zs87a.top 对 node fetch 回
    /// 18.5KB 的配置 JSON，对 reqwest 回 13.5KB 的**下载页 HTML**。
    /// 这个测试逐个变量排除：HTTP 版本 / Accept / Accept-Encoding / UA。
    #[tokio::test]
    #[ignore = "诊断用，需要联网"]
    async fn diagnose_content_negotiation() {
        let url = "https://tv.xn--yhqu5zs87a.top";
        let variants: Vec<(&str, reqwest::Client)> = vec![
            (
                "default",
                reqwest::Client::builder()
                    .user_agent(TVBOX_UA)
                    .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
                    .build()
                    .unwrap(),
            ),
            (
                "http1_only",
                reqwest::Client::builder()
                    .user_agent(TVBOX_UA)
                    .http1_only()
                    .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
                    .build()
                    .unwrap(),
            ),
            (
                "accept-star",
                reqwest::Client::builder()
                    .user_agent(TVBOX_UA)
                    .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
                    .build()
                    .unwrap(),
            ),
            (
                "ua-chrome",
                reqwest::Client::builder()
                    .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
                    .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
                    .build()
                    .unwrap(),
            ),
            (
                "no-ua",
                reqwest::Client::builder()
                    .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
                    .build()
                    .unwrap(),
            ),
        ];
        for (name, client) in variants.iter() {
            let mut req = client.get(url);
            if *name == "accept-star" {
                req = req.header(reqwest::header::ACCEPT, "*/*");
            }
            let res = match req.send().await {
                Ok(r) => r,
                Err(e) => {
                    println!("[EVIDENCE] DIAG {name}: send 失败 {e}");
                    continue;
                }
            };
            let ver = res.version();
            let status = res.status();
            let ct = res
                .headers()
                .get(reqwest::header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("")
                .to_string();
            let ae = res
                .headers()
                .get(reqwest::header::CONTENT_ENCODING)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("")
                .to_string();
            let text = res.text().await.unwrap_or_default();
            let is_json = text.trim_start().starts_with('{');
            let head: String = text.chars().take(60).collect();
            println!(
                "[EVIDENCE] DIAG {name}: ver={ver:?} status={status} ct={ct} contentEncoding={ae} len={} isJson={is_json} head={:?}",
                text.len(),
                head.replace('\n', " ")
            );
        }
    }

    /// 真实联网跑**生产命令** check_tvbox_updates
    ///
    /// 构造一个"用户昨天导入过菜妮丝配置"的本地状态（一个真实源 + 真实链接），
    /// 然后让生产命令自己去下载、解析、对比 —— 这是端到端取证，不是纯函数自证。
    #[tokio::test]
    #[ignore = "需要联网，手动跑：cargo test --lib real_sites -- --ignored --nocapture"]
    async fn real_check_updates_against_live_site() {
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
        let dir = super::task5_ab_restart::unique_tmp_dir("t12real");
        std::fs::create_dir_all(&dir).expect("建临时目录失败");
        let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap 失败");

        // 用户本地已有的那个源：真实配置里唯一的 type1 站（key=非凡）
        {
            let mut list = st.third_party.write().expect("锁中毒");
            list.push(crate::model::PersistedProvider::Tvbox {
                id: "ffzy".to_string(),
                name: "非凡┃影视".to_string(),
                api: "http://cj.ffzyapi.com/api.php/provide/vod".to_string(),
                categories: Vec::new(),
            });
        }
        crate::commands_provider::persist_from_registry(&st).expect("落盘失败");

        let mut any_ok = false;
        for (label, url) in SITES.iter() {
            write_tvbox_meta(
                &dir,
                "ffzy",
                &TvboxSourceMeta {
                    source_url: Some(url.to_string()),
                    site_key: "非凡".to_string(),
                    site_name: "非凡┃影视".to_string(),
                    api: "http://cj.ffzyapi.com/api.php/provide/vod".to_string(),
                    installed_at: now_secs(),
                },
            )
            .expect("写 sidecar 失败");

            let res = match check_tvbox_updates(&st, None).await {
                Ok(v) => v,
                Err(e) => {
                    println!("[EVIDENCE] REAL-CHECK {label} 命令失败：{e}");
                    continue;
                }
            };
            println!("[EVIDENCE] REAL-CHECK {label} url={url} {res}");
            let it = &res["items"][0];
            if it["ok"] == serde_json::Value::Bool(true) {
                any_ok = true;
                println!(
                    "[EVIDENCE] REAL-CHECK {label} 远端可转换={} 新增={} 消失={} 变更={} 未变={}",
                    it["remoteConvertible"],
                    it["added"].as_array().map(|a| a.len()).unwrap_or(0),
                    it["removed"].as_array().map(|a| a.len()).unwrap_or(0),
                    it["changed"].as_array().map(|a| a.len()).unwrap_or(0),
                    it["unchanged"]
                );
            } else {
                println!("[EVIDENCE] REAL-CHECK {label} 如实报错（不算失败）：{}", it["error"]);
            }
        }

        // 两个站点都不可达（比如本机没网）时**不算失败** —— 这只是取证测试。
        if !any_ok {
            println!("[EVIDENCE] REAL-CHECK 两个真实站点都没查成（可能无网络）—— 本次未取得联网证据");
        }

        drop(st);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
