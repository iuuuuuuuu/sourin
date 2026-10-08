//! 央视网 Provider —— 第一个内置 Provider，也是插件契约的**验证用例**
//!
//! 所有接口均于 2026-09-14 实测验证：
//!
//! - **直播**：`pd://` 前缀 + `client=iosapp` 才能拿到真实地址（`pa://`+`html5` 只给占位符）
//!   实测 **20/24 频道**直接命中，`cctv9→cctvjilu`、`cctv14→cctvchild` 为别名映射
//! - **点播**：`guid` 可直接拼 HLS（绕过 getHttpVideoInfo）
//! - **时移回看**：直播地址 + `?begintimeabs={st*1000}&endtimeabs={et*1000}`
//! - **无防盗链**：Referer 留空亦可播放；`cdrm` 前缀是虚标（子列表无 `#EXT-X-KEY`）
//! - **多 CDN**：同一频道每次可能返回不同 CDN，必须容错

use crate::model::*;
use crate::provider::*;
use async_trait::async_trait;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::OnceLock;
use std::time::Duration;

const REFERER: &str = "https://tv.cctv.com/";
const UA_MOBILE: &str = "Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";

static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();

/// 内置直连客户端（未配置站点代理时的默认值）
fn default_client() -> &'static reqwest::Client {
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .user_agent(UA_MOBILE)
            .timeout(Duration::from_secs(20))
            // ⚠️ 必须显式 no_proxy()：否则即使没配代理，
            //    reqwest 仍会读环境变量 HTTP_PROXY，与「未配置=直连」的约定相反
            .no_proxy()
            .build()
            .expect("build http client")
    })
}

/// 用指定客户端发请求（供「按站点代理」复用）
async fn get_json_with(client: &reqwest::Client, url: &str) -> Result<Value> {
    let resp = client
        .get(url)
        .header("Referer", REFERER)
        .header("Accept", "application/json, text/plain, */*")
        .send()
        .await
        .map_err(|e| ProviderError::network(format!("请求失败: {e}")))?;

    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| ProviderError::network(format!("读取响应失败: {e}")))?;

    if !status.is_success() {
        return Err(ProviderError::network(format!(
            "HTTP {status}: {}",
            truncate(&text, 160)
        )));
    }
    serde_json::from_str(&text)
        .map_err(|e| ProviderError::parse(format!("{e} — {}", truncate(&text, 160))))
}

fn truncate(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

/// 剥掉搜索结果标题里的 HTML 高亮标签
///
/// ⚠️ 央视搜索返回的 `title` 形如
/// `《<font color="red">老</font><font color="red">舅</font>》霍晓阳…`
/// —— 会把命中的关键词用 `<font>` 包起来。
/// 不剥离的话界面上会出现裸 HTML（实测样本确认）。
///
/// 实现说明：这里只处理 `<...>` 形式的标签，并把常见实体还原。
/// 不用正则库是为了少一个依赖（标签结构非常固定，逐字符扫描足够）。
fn strip_html_tags(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut in_tag = false;
    for ch in raw.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(ch),
            _ => {}
        }
    }
    // 常见实体还原（标题里可能出现 &amp; &quot; 等）
    out.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
        .trim()
        .to_string()
}

/// 从 `imglink` 里取出 32 位十六进制的 **guid**
///
/// ★ 这是一个**实测得出的简化**（2026-09-15）：
/// 央视搜索的 `imglink` 形如
/// `https://p1.img.cctvpic.com/fmspic/2026/01/28/5dbb582b20f848378a906316d212afcb-1.jpg`，
/// 其中那串 hash **就是取流接口要的 `pid`/`guid`**。
///
/// 验证方式：拿该 hash 直接调
/// `vdn.apps.cntv.cn/api/getHttpVideoInfo.do?pid={hash}` → `ack: yes`，
/// 返回的 `title` 与搜索结果一致、`hls_url` 可用。
///
/// 因此**不需要**再请求 `urllink` 那个 `.shtml` 页面去解析 guid
/// （省一次网络往返，也少一处解析失败点）。
/// 若将来 imglink 结构变了，再退回「请求 urllink 页面找 guid」的方案。
fn guid_from_imglink(imglink: &str) -> Option<String> {
    // 取最后一段路径里的 `<32位hex>-<n>.jpg`
    let file = imglink.rsplit('/').next()?;
    let hash = file.split('-').next()?;
    if hash.len() == 32 && hash.chars().all(|c| c.is_ascii_hexdigit()) {
        Some(hash.to_string())
    } else {
        None
    }
}

/// 从标题里解析「剧名 + 集号」
///
/// 央视搜索的结果标题有两种形态（实测）：
/// - **正片剧集**：`《老舅》 第5集` / `《老舅》 第27集（大结局）`
/// - **片段/花絮**：`《老舅》霍晓阳向同学们宣传老舅生产的眼镜`
/// - **栏目报道**：`[中国电影报道]《老舅》主演郭京飞：…`
///
/// 只有第一种能被识别为剧集（必须带 `第N集`），
/// 后两种保持为独立条目 —— 否则会把花絮误并进剧集里。
///
/// 返回 `(剧名, 集号)`。
fn parse_episode_title(title: &str) -> Option<(String, u32)> {
    let t = title.trim();
    // 必须以《剧名》开头
    let rest = t.strip_prefix('《')?;
    let end = rest.find('》')?;
    let brand = rest[..end].trim().to_string();
    if brand.is_empty() {
        return None;
    }
    // 书名号之后必须紧跟「第N集」
    let after = rest[end + '》'.len_utf8()..].trim_start();
    let ep_part = after.strip_prefix('第')?;
    let num_end = ep_part.find('集')?;
    let num_str = ep_part[..num_end].trim();
    let ep: u32 = num_str.parse().ok()?;
    if ep == 0 {
        return None;
    }
    Some((brand, ep))
}

/// 把剧集分组收敛成单个条目
///
/// 抽出来是为了让 `search()` 主体保持可读（聚合逻辑本身较长）。
fn push_album_item(items: &mut Vec<MediaItem>, brand: &str, eps: &mut Vec<(u32, String, Option<String>, String)>) {
    eps.sort_by_key(|(e, _, _, _)| *e);
    eps.dedup_by_key(|(e, _, _, _)| *e);

    let count = eps.len();
    let (first_ep, first_guid, cover, _) = &eps[0];
    let last_ep = eps.last().map(|(e, _, _, _)| *e).unwrap_or(*first_ep);

    items.push(MediaItem {
        // ★ 用**集号最小的一集**的 guid 作为整部剧的入口。
        //   detail() 会从它反查同剧全部剧集。
        id: MediaId::new("cctv", first_guid),
        title: format!("《{brand}》"),
        cover: cover.clone(),
        subtitle: Some(if count > 1 {
            format!("全 {count} 集（第{first_ep}–{last_ep}集）")
        } else {
            format!("第{first_ep}集")
        }),
        badges: if count > 1 {
            vec![format!("{count} 集")]
        } else {
            vec![]
        },
        // ★ 标成剧集：前端会走「详情页选剧集」而不是直接播
        kind: MediaKind::Series,
        description: None,
    });
}

/// 搜索一页并返回**原始 JSON**（供 `search` 复用来补抓多页）
impl CctvProvider {
    /// ★ 动态获取首页要展示的栏目（返回 `(TOPC id, 栏目名)`）
    ///
    /// 流程见 `home()` 的说明。失败时返回 `COLUMNS_FALLBACK`。
    ///
    /// **性能**：栏目页要逐个访问（每个约 2KB），8 个栏目就是 8 次请求。
    /// 用 `futures` 的并发（这里用 tokio::join 手动分组太笨，
    /// 故串行但**只抓前 N 个候选**）—— 实测每次约 100~200ms，
    /// 8 个串行约 1~2 秒，可接受（首页本来就要等网络）。
    async fn fetch_home_columns(&self) -> Vec<(String, String)> {
        let fallback = || -> Vec<(String, String)> {
            COLUMNS_FALLBACK
                .iter()
                .map(|(id, n)| (id.to_string(), n.to_string()))
                .collect()
        };

        // 1) 拿栏目清单。多取一些候选，因为部分栏目解析不出 TOPC，会被跳过
        let url = format!(
            "{}?&fl=&p=1&n=40&serviceId=tvcctv",
            COLUMN_SEARCH
        );
        let Ok(json) = self.get_json(&url).await else {
            log::warn!("cctv: 栏目清单拉取失败，首页退回内置栏目");
            return fallback();
        };

        let docs = json
            .get("response")
            .and_then(|r| r.get("docs"))
            .and_then(|d| d.as_array());
        let Some(docs) = docs else {
            log::warn!("cctv: 栏目清单结构异常，首页退回内置栏目");
            return fallback();
        };

        // 2) 逐个解析栏目页里的 TOPC id
        let mut out: Vec<(String, String)> = Vec::new();
        for d in docs {
            if out.len() >= HOME_COLUMN_LIMIT {
                break;
            }
            let name = d.get("column_name").and_then(|v| v.as_str()).unwrap_or("");
            let site = d
                .get("column_website")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            if name.is_empty() || !site.starts_with("http") {
                continue;
            }

            match self.fetch_html(site).await {
                Ok(html) => {
                    if let Some(topic) = parse_topic_id(&html) {
                        out.push((topic, name.to_string()));
                    }
                    // 解析不出 topicID = 该栏目没有视频专题，跳过（不是错误）
                }
                Err(e) => {
                    log::debug!("cctv: 栏目页 {name} 抓取失败（跳过）: {}", e.message);
                }
            }
        }

        if out.is_empty() {
            log::warn!("cctv: 所有栏目都没解析出 topicID，首页退回内置栏目");
            return fallback();
        }
        log::info!("cctv: 首页动态获取到 {} 个栏目", out.len());
        out
    }

    /// 抓一段 HTML（栏目页只有 2KB 左右，直接读文本）
    async fn fetch_html(&self, url: &str) -> Result<String> {
        let resp = self
            .http()
            .get(url)
            .header("Referer", REFERER)
            .send()
            .await
            .map_err(|e| ProviderError::network(format!("请求失败: {e}")))?;
        if !resp.status().is_success() {
            return Err(ProviderError::network(format!(
                "HTTP {}",
                resp.status()
            )));
        }
        resp.text()
            .await
            .map_err(|e| ProviderError::network(format!("读取响应失败: {e}")))
    }

    async fn search_raw(&self, kw: &str, page: u32) -> Result<Value> {
        const PAGE_SIZE: u32 = 20;
        // 参数名从 pub.js 的 get_data() 抄来；qtext 需要 URL 编码，
        // qtext_str 传原文（接口两个都要）
        let url = format!(
            "https://search.cctv.com/ifsearch.php?page={}&qtext={}&qtext_str={}&sort=relevance&pageSize={}&type=video&vtime=-1&datepid=1&channel=&pageflag=0",
            page.max(1),
            urlencoding::encode(kw),
            urlencoding::encode(kw),
            PAGE_SIZE
        );
        self.get_json(&url).await
    }

    /// ★ 按剧名回搜，收集该剧的全部剧集
    ///
    /// 返回 `(集号, guid, 封面)` 列表（可能重复，调用方需去重）。
    ///
    /// 为什么用「回搜」而不是专辑接口：
    /// 央视的 `getVideoListByAlbumId` **实测返回「拒绝访问」**
    /// （`{"errcode":"1100","msg":"拒绝访问"}`），
    /// 所以只能反过来按剧名搜索 —— 好在剧名就在标题里（`《老舅》 第5集`）。
    ///
    /// ⚠️ **页数不能少，也不能提前收工**：实测「老舅」全剧 27 集，
    ///   逐页分布是这样的（每页 20 条，剧集与花絮混排）：
    ///
    ///   | 页 | 本页剧集 | 累计 |
    ///   |---|---|---|
    ///   | 1 | 13 集 | 13 |
    ///   | 2 | 11 集 | 24 |
    ///   | 3 | **0 集** | 24 |
    ///   | 4 | 3 集（**含第 1 集**） | 27 |
    ///
    /// 两个都踩过的坑：
    ///   1. 只抓 3 页 → 缺第 1 集（用户看到「从第 2 集开始」的残缺剧集）
    ///   2. 「某页没有新剧集就提前收工」→ 会在**第 3 页**停下，
    ///      同样漏掉第 4 页的第 1 集（这个优化是错的，已移除）
    ///
    /// **剧集分布是稀疏的**，不能用「本页无新集」判断后面没有了。
    /// 故固定抓 4 页，不做提前退出。
    async fn album_episodes(&self, brand: &str) -> Result<Vec<(u32, String, Option<String>)>> {
        /// 抓取页数：实测 4 页才能凑齐 27 集的剧（第 4 页才有第 1 集）
        const MAX_PAGES: u32 = 4;

        let mut out: Vec<(u32, String, Option<String>)> = Vec::new();
        let mut seen: std::collections::HashSet<u32> = std::collections::HashSet::new();

        for p in 1..=MAX_PAGES {
            let Ok(json) = self.search_raw(brand, p).await else {
                continue;
            };
            let Some(list) = json.get("list").and_then(|v| v.as_array()) else {
                continue;
            };
            for it in list {
                let Some(guid) = it
                    .get("imglink")
                    .and_then(|v| v.as_str())
                    .and_then(guid_from_imglink)
                else {
                    continue;
                };
                let raw_title = it
                    .get("title")
                    .and_then(|v| v.as_str())
                    .map(strip_html_tags)
                    .unwrap_or_default();

                // 只收**同一部剧**的剧集：剧名必须完全一致，
                // 避免把《老舅》与《老舅的朋友》混在一起
                if let Some((b, ep)) = parse_episode_title(&raw_title) {
                    if b == brand && seen.insert(ep) {
                        out.push((
                            ep,
                            guid,
                            it.get("imglink").and_then(|v| v.as_str()).map(String::from),
                        ));
                    }
                }
            }
        }

        if out.is_empty() {
            return Err(ProviderError::new(
                ErrorKind::NotFound,
                format!("未找到《{brand}》的剧集"),
            ));
        }
        Ok(out)
    }
}

fn hdr() -> Vec<(String, String)> {
    vec![("Referer".to_string(), REFERER.to_string())]
}

// ─────────────────────────── 频道表 ───────────────────────────
//
// ⚠️ 官方 `getChannelList` 返回「拒绝访问」，故内置。
//    cctv9 / cctv14 在直播接口里必须用 cctvjilu / cctvchild（实测别名）。

const CHANNELS: &[(&str, &str, &str, &str)] = &[
    ("cctv1", "cctv1", "CCTV-1 综合", "央视"),
    ("cctv2", "cctv2", "CCTV-2 财经", "央视"),
    ("cctv3", "cctv3", "CCTV-3 综艺", "央视"),
    ("cctv4", "cctv4", "CCTV-4 中文国际", "央视"),
    ("cctv5", "cctv5", "CCTV-5 体育", "央视"),
    ("cctv5plus", "cctv5plus", "CCTV-5+ 体育赛事", "央视"),
    ("cctv6", "cctv6", "CCTV-6 电影", "央视"),
    ("cctv7", "cctv7", "CCTV-7 国防军事", "央视"),
    ("cctv8", "cctv8", "CCTV-8 电视剧", "央视"),
    ("cctvjilu", "cctv9", "CCTV-9 纪录", "央视"),
    ("cctv10", "cctv10", "CCTV-10 科教", "央视"),
    ("cctv11", "cctv11", "CCTV-11 戏曲", "央视"),
    ("cctv12", "cctv12", "CCTV-12 社会与法", "央视"),
    ("cctv13", "cctv13", "CCTV-13 新闻", "央视"),
    ("cctvchild", "cctv14", "CCTV-14 少儿", "央视"),
    ("cctv15", "cctv15", "CCTV-15 音乐", "央视"),
    ("cctv16", "cctv16", "CCTV-16 奥林匹克", "央视"),
    ("cctv17", "cctv17", "CCTV-17 农业农村", "央视"),
    ("cctvamerica", "cctvamerica", "CCTV-4 美洲版", "国际"),
    ("cctveurope", "cctveurope", "CCTV-4 欧洲版", "国际"),
];

/// 栏目表（实测 `getVideoListByColumn` 可用）
///
/// ⚠️ **这是「动态栏目拉不到时的兜底」，不再作为首页的唯一来源。**
///
/// 原先首页区块就是写死这张表的前 4 个 —— 实测踩到两个问题：
/// 1. **表里的栏目会失效**：写死的 5 个里「电视剧」「纪录片」
///    两个已经返回空数据（央视改版后 TOPC id 变了）
/// 2. 用户永远只能看到这 4 个栏目，而央视实际有 **343 个**
///
/// 现在首页改为**动态拉取**（见 `fetch_columns`），这张表只在
/// 动态拉取失败时兜底 —— 至少保证首页还有内容，而不是空白。
const COLUMNS_FALLBACK: &[(&str, &str)] = &[
    ("TOPC1451528971114112", "新闻联播"),
    ("TOPC1451558976694518", "焦点访谈"),
    ("TOPC1451559025546574", "动画大放映"),
];

/// 首页最多展示多少个栏目区块
///
/// 央视有 343 个栏目，全放上去首页会长得没法看。
/// 取 8 个：既体现「内容很多」，又不至于滚动很久。
const HOME_COLUMN_LIMIT: usize = 8;

/// 栏目搜索接口（返回可用的栏目清单）
///
/// ★ 2026-09-15 实测发现。从「栏目大全」页
/// （`tv.cctv.com/lm/index.shtml`）里找到它被调用：
/// `api.cntv.cn/lanmu/columnSearch?&fl=&p=1&n=50&serviceId=tvcctv`
///
/// 返回 `{"response":{"docs":[...],"numFound":343}}`，
/// 每个 doc 有 `column_id`（EPGM 格式）/ `column_name` /
/// `channel_name` / `column_website` / `column_firstclass`。
///
/// ⚠️ **`column_id` 不能直接用于取流** —— 取流接口要的是 `TOPC` 格式，
/// 两者是不同体系。所以还要再用 `column_website` 去抓一次
/// （见 `resolve_column_topic`）。
const COLUMN_SEARCH: &str = "https://api.cntv.cn/lanmu/columnSearch";

/// 从栏目页里解析出取流用的 `TOPC` id
///
/// 实测：栏目页（如 `tv.cctv.com/lm/xwlb/index.shtml`）里有
/// ```html
/// <script> var topicID = 'TOPC1451528971114112'; </script>
/// ```
/// 这就是取流要的那个 id。实测 10 个随机栏目：**8 个能取到且取流成功**，
/// 2 个「没有 topicID」——那是该栏目本身没有视频专题（正常，跳过即可）。
///
/// ⚠️ 必须**精确匹配 `topicID =`**，不能笼统地找 `TOPC\d+`：
/// 页面里可能出现其它形式的 TOPC 串，宽泛匹配会抓到错的。
fn parse_topic_id(html: &str) -> Option<String> {
    // 不用正则库：这里只需要找 "topicID" 后的第一个引号串
    let idx = html.find("topicID")?;
    let rest = &html[idx..];
    // 跳过等号与空白、引号
    let after_eq = rest.split_once('=')?.1;
    let trimmed = after_eq.trim_start();
    let quote = trimmed.chars().next()?;
    let s = if quote == '\'' || quote == '"' {
        let body = &trimmed[quote.len_utf8()..];
        &body[..body.find(quote)?]
    } else {
        // 没有引号：取到分号
        let end = trimmed.find(';')?;
        &trimmed[..end]
    };
    let id = s.trim();
    if id.starts_with("TOPC") && id.len() > 4 {
        Some(id.to_string())
    } else {
        None
    }
}

// ─────────────────────────── Provider 实现 ───────────────────────────

pub struct CctvProvider {
    manifest: ProviderManifest,
    /// 站点代理存储。为 `None` 时走内置直连客户端。
    ///
    /// **为什么要持有它**：央视本身不需要代理，但底座必须让「任何 Provider
    /// 都能按站点走代理」—— 否则 M5 的能力就只对新写的 Provider 生效。
    proxy: Option<std::sync::Arc<crate::proxy::ProxyStore>>,
}

impl Default for CctvProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl CctvProvider {
    pub fn new() -> Self {
        Self {
            proxy: None,
            manifest: ProviderManifest {
                id: "cctv".into(),
                name: "央视网".into(),
                version: "0.1.0".into(),
                kind: "builtin".into(),
                description: Some("中央电视台官网，24 个频道直播 + 栏目点播 + 节目单".into()),
                icon: None,
                // ★ 借鉴 Stremio 的 idPrefixes
                id_prefixes: vec!["TOPC".into()],
                capabilities: Capabilities {
                    vod: true,
                    live: true,
                    epg: true,
                    // ★ 2026-09-15 改为 true：原先写 false 是**错误结论**
                    //   （当时只试了 api.cntv.cn/search 就断言"无公开接口"）。
                    //   实测 search.cctv.com/ifsearch.php 返回合法 JSON，
                    //   且能搜到电视剧与电影。
                    search: true,
                    login_required: false,
                    multi_source: false, // 央视单源，但 CDN 多线路
                    server_side_history: false,
                    favorites: false,
                    timeshift: true, // 时移回看已实测
                    danmaku: false,
                    // 央视无需登录，也不提供登录
                    login_supported: false,
                    login_hint: None,
                    login_needs_username: true,
                    // 内置源不支持扫码登录（那是插件侧的能力）
                    login_qr_supported: false,
                    // task-38：央视源 login_required=false，本字段对它无意义
                    can_auto_login: false,
                },
                // 内置 Provider 无可配置项（插件走 hydrate 填充）
                cover_headers: Vec::new(),
                config: Vec::new(),
                api_version: 1,
                theme_color: Some("#e63946".into()),
                working: true,
                broken_reason: None,
                enabled: None,
            },
        }
    }

    /// 注入站点代理（用于「任何 Provider 都能按站点走代理」）
    pub fn with_proxy(mut self, proxy: std::sync::Arc<crate::proxy::ProxyStore>) -> Self {
        self.proxy = Some(proxy);
        self
    }

    /// 取该站点的 HTTP 客户端（按站点代理配置；未配置则直连）
    fn http(&self) -> reqwest::Client {
        match self.proxy.as_ref() {
            Some(store) => store.client_for("cctv", None).unwrap_or_else(|e| {
                log::warn!("cctv: 构建代理客户端失败，回退直连: {}", e.message);
                default_client().clone()
            }),
            None => default_client().clone(),
        }
    }

    /// 统一请求入口（走站点代理配置）
    async fn get_json(&self, url: &str) -> Result<Value> {
        get_json_with(&self.http(), url).await
    }

    /// 直播取流（内部复用）
    ///
    /// # ⚠️ 关于 DRM（实测，2026-09-15）
    ///
    /// 央视直播的**视频轨被 `udrm` 加密**，客户端无法解码。证据：
    ///   · 容器与 NAL 头是明文（ffprobe 读出 `h264` + `1024x576`）
    ///   · 但载荷加密 → ffmpeg 解码报
    ///     `top block unavailable for requested intra mode` /
    ///     `error while decoding MB`（实测 61~80 次/3 秒）
    ///   · 对照实验（同机同 ffmpeg）：公开测试流 0 错误、
    ///     央视**音频**流 0 错误 ⇒ 网络与工具正常，是流本身加密
    ///   · 所有视频线路（hls1/hls2/hls4）都加密，只有 `hls6`（纯音频）可解
    ///
    /// 表现是**画面绿屏/花屏但时间在走**，用户完全看不懂。
    /// 故这里把候选**照常返回**（音频轨仍可听，且将来若央视放开可直接播），
    /// 但标上 `drm_protected`，由 UI 如实告知。
    async fn live_urls(&self, channel_id: &str) -> Result<Vec<StreamCandidate>> {
        // ★ 关键：pd:// + client=iosapp
        let url = format!(
            "https://vdn.live.cntv.cn/api2/live.do?channel=pd://cctv_p2p_hd{channel_id}&client=iosapp"
        );
        let json = self.get_json(&url).await?;

        let mut out = Vec::new();
        if let Some(hls) = json.get("hls_url") {
            for (key, label) in [("hls1", "高清"), ("hls2", "标清")] {
                if let Some(u) = hls.get(key).and_then(|v| v.as_str()) {
                    // 过滤占位符（实测 pa:// + html5 会返回 yangshi?group&drm=0&zbzx）
                    if u.starts_with("http") {
                        out.push(
                            StreamCandidate::new(u, StreamKind::Hls)
                                .with_quality(label)
                                .with_label(format!("{label}线路"))
                                .with_headers(hdr())
                                .drm(),
                        );
                    }
                }
            }

            // 纯音频线路（实测**未加密**，是当前唯一能正常出声的画外选择）
            if let Some(u) = hls.get("hls6").and_then(|v| v.as_str()) {
                if u.starts_with("http") {
                    out.push(
                        StreamCandidate::new(u, StreamKind::Hls)
                            .with_quality("仅音频")
                            .with_label("广播")
                            .with_headers(hdr()),
                    );
                }
            }
        }

        if out.is_empty() {
            return Err(ProviderError::new(
                ErrorKind::NotFound,
                format!("频道 {channel_id} 未返回可用地址（可能是 4K/8K 频道）"),
            ));
        }
        Ok(out)
    }
}

#[async_trait]
impl MediaProvider for CctvProvider {
    fn manifest(&self) -> &ProviderManifest {
        &self.manifest
    }

    /// ★ 分类 = 央视的真实栏目（动态拉取，2026-09-15 改）
    ///
    /// 原先返回写死的 `COLUMNS` —— 于是浏览页只有 5 个栏目可选，
    /// 而央视实际有 343 个。改为与首页用同一份动态清单。
    ///
    /// 栏目多、逐个解析 TOPC 有成本，所以这里**直接复用首页那份**；
    /// 首屏没拉到就退回内置表（`fetch_home_columns` 内部已兜底）。
    async fn categories(&self) -> Result<Vec<Category>> {
        Ok(self
            .fetch_home_columns()
            .await
            .into_iter()
            .map(|(id, name)| Category {
                id,
                name,
                children: vec![],
            })
            .collect())
    }

    /// ★ 首页：**动态拉取真实栏目**（2026-09-15 重写）
    ///
    /// # 此前是错的
    ///
    /// 原实现直接把写死的 `COLUMNS` 常量取前 4 个当区块，
    /// 而央视实际有 **343 个栏目**。写死的代价实测暴露：
    /// 「电视剧」「纪录片」两个已失效返回空数据，用户看到两个空区块。
    ///
    /// # 现在的链路
    ///
    /// 1. 调 `COLUMN_SEARCH` 拿栏目清单（343 个，含名称与栏目页地址）
    /// 2. 并发访问各栏目页，解析出取流用的 `TOPC` id
    /// 3. 只保留**能解析出 TOPC 的**栏目（解析不出的没有视频专题，跳过）
    /// 4. 取前 `HOME_COLUMN_LIMIT` 个作为首页区块
    ///
    /// **失败兜底**：任何一步出错都退回 `COLUMNS_FALLBACK`，
    /// 保证首页至少有内容 —— 动态数据拿不到时不该给用户一个空首页。
    async fn home(&self) -> Result<Vec<Section>> {
        // 首页：每个栏目一个横向区块（静态声明 source，UI 懒加载）
        let mut sections = vec![Section {
            id: "cctv-live".into(),
            title: "正在直播".into(),
            source: SectionSource::Custom {
                key: "live".into(),
            },
            items: vec![],
        }];

        let columns = self.fetch_home_columns().await;

        for (id, name) in columns {
            sections.push(Section {
                id: format!("cctv-col-{id}"),
                title: name,
                source: SectionSource::Category { category_id: id },
                items: vec![],
            });
        }
        Ok(sections)
    }

    async fn list(&self, req: ListRequest) -> Result<Page<MediaItem>> {
        let page_size = 20u32;
        let url = format!(
            "https://api.cntv.cn/NewVideo/getVideoListByColumn?id={}&n={}&p={}&sort=desc&mode=0&serviceId=tvcctv",
            req.category_id, page_size, req.page
        );
        let json = self.get_json(&url).await?;

        let data = json.get("data").ok_or_else(|| {
            ProviderError::parse(format!("未返回 data: {}", truncate(&json.to_string(), 160)))
        })?;

        let total = data.get("total").and_then(|v| v.as_u64());

        let mut items = Vec::new();
        if let Some(list) = data.get("list").and_then(|v| v.as_array()) {
            for it in list {
                let guid = it
                    .get("guid")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default();
                if guid.is_empty() {
                    continue;
                }
                items.push(MediaItem {
                    id: MediaId::new("cctv", guid),
                    title: it
                        .get("title")
                        .and_then(|v| v.as_str())
                        .unwrap_or("未知标题")
                        .into(),
                    cover: it.get("image").and_then(|v| v.as_str()).map(String::from),
                    subtitle: it.get("time").and_then(|v| v.as_str()).map(String::from),
                    badges: vec![],
                    kind: MediaKind::Movie,
                    description: None,
                });
            }
        }

        let page_count = total.map(|t| ((t as f64) / (page_size as f64)).ceil() as u32);

        Ok(Page {
            items,
            page: req.page,
            page_count,
            total,
        })
    }

    /// ★ 搜索（2026-09-15 实现，接口已实测）
    ///
    /// # 背景：这里曾经是错的
    ///
    /// manifest 原先写着 `search: false`，注释是
    /// 「无公开 JSON 搜索接口（实测 api.cntv.cn/search 拒绝访问）」——
    /// **当时只试了一个域名就下了结论**。
    ///
    /// 实际上央视搜索页 `search.cctv.com` 有可用的 JSON 接口，
    /// 从 `js/pub.js` 的 `get_data()` 反出端点：
    /// `GET https://search.cctv.com/ifsearch.php`
    ///
    /// 实测（搜「老舅」）：`total: 348`、18 页，
    /// 结果含「CCTV电视剧 205 条 + CCTV-6电影频道 7 条」
    /// —— **确实能搜到电视剧与电影**。
    ///
    /// # 两个实测要点
    ///
    /// 1. `title` 含 `<font color="red">` 高亮标签 → 必须剥离
    /// 2. `imglink` 里的 32 位 hash **就是取流要的 guid** →
    ///    不需要再请求 `urllink` 页面（见 `guid_from_imglink`）
    async fn search(&self, keyword: &str, page: u32) -> Result<Page<MediaItem>> {
        let kw = keyword.trim();
        if kw.is_empty() {
            return Ok(Page {
                items: vec![],
                page: 1,
                page_count: None,
                total: None,
            });
        }

        const PAGE_SIZE: u32 = 20;

        let page = page.max(1);
        let first = self.search_raw(kw, page).await?;
        let total = first.get("total").and_then(|v| v.as_u64());

        // 把结果转成「中间形态」，便于聚合
        let mut loose: Vec<MediaItem> = Vec::new();
        // 剧名 → 该剧的集（集号, guid, 封面, 标题）
        let mut albums: HashMap<String, Vec<(u32, String, Option<String>, String)>> = HashMap::new();

        let mut consume = |list: &[Value],
                           loose: &mut Vec<MediaItem>,
                           albums: &mut HashMap<String, Vec<(u32, String, Option<String>, String)>>| {
            for it in list {
                // guid 优先从 imglink 推（实测可行）；推不出来就跳过 ——
                // 没有 guid 就无法取流，列出来点了也播不了
                let Some(guid) = it
                    .get("imglink")
                    .and_then(|v| v.as_str())
                    .and_then(guid_from_imglink)
                else {
                    continue;
                };

                let title = it
                    .get("title")
                    .and_then(|v| v.as_str())
                    .map(strip_html_tags)
                    .filter(|s| !s.is_empty())
                    .unwrap_or_else(|| "未知标题".into());

                let cover = it.get("imglink").and_then(|v| v.as_str()).map(String::from);
                let channel = it.get("channel").and_then(|v| v.as_str()).map(String::from);

                // ★ 正片剧集 → 归入剧名分组（不直接进结果列表）
                if let Some((brand, ep)) = parse_episode_title(&title) {
                    albums
                        .entry(brand)
                        .or_default()
                        .push((ep, guid, cover, title));
                    continue;
                }

                // durations 是**秒**（实测 38 / 60 / 120），不是毫秒
                let subtitle = it
                    .get("durations")
                    .and_then(|v| v.as_u64())
                    .map(|sec| format!("{}:{:02}", sec / 60, sec % 60))
                    .or_else(|| channel.clone());

                loose.push(MediaItem {
                    id: MediaId::new("cctv", &guid),
                    title,
                    cover,
                    subtitle,
                    badges: channel.map(|c| vec![c]).unwrap_or_default(),
                    kind: MediaKind::Movie,
                    description: None,
                });
            }
        };

        let first_list = first
            .get("list")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        consume(&first_list, &mut loose, &mut albums);

        /*
         * ★ 发现剧集后再补抓几页，把整部剧凑齐。
         *
         * 为什么必须补抓：实测「老舅」全剧 27 集，但**一页只有 20 条**，
         * 且首页里混着花絮与报道 —— 只取一页只能凑到十几集，
         * 用户会看到「缺集」的剧（实测第 1 页缺 11/24 集）。
         *
         * ⚠️ **必须与 `album_episodes()` 抓同样多的页数**（那里是 4 页）。
         *    曾经这里只补 2 页（合计 3 页）→ 列表页显示
         *    「全 24 集（第2–27集）」，而点进详情页显示 27 集
         *    —— **同一部剧两个数字**（实测发现的不一致）。
         *    第 4 页才有第 1 集，少抓一页就少一集且从第 2 集开始。
         *
         * 补抓失败不影响主流程（剧集不全总比搜索报错好）。
         */
        if !albums.is_empty() {
            /// 与 `album_episodes()` 的 MAX_PAGES 保持一致
            const SEARCH_MAX_PAGES: u32 = 4;
            for p in (page + 1)..=SEARCH_MAX_PAGES {
                if let Ok(next) = self.search_raw(kw, p).await {
                    if let Some(list) = next.get("list").and_then(|v| v.as_array()) {
                        consume(list, &mut loose, &mut albums);
                    }
                }
            }
        }

        // ★ 把剧集分组收敛成单个条目
        let mut items: Vec<MediaItem> = Vec::new();
        for (brand, mut eps) in albums {
            push_album_item(&mut items, &brand, &mut eps);
        }

        // 聚合条目排前面（更像"作品"），散条在后
        items.sort_by_key(|i| if i.kind == MediaKind::Series { 0 } else { 1 });
        items.extend(loose);

        Ok(Page {
            items,
            page,
            page_count: total.map(|t| ((t as f64) / (PAGE_SIZE as f64)).ceil() as u32),
            total,
        })
    }

    async fn detail(&self, id: &MediaId) -> Result<MediaDetail> {
        let guid = &id.native;
        let url =
            format!("https://vdn.apps.cntv.cn/api/getHttpVideoInfo.do?pid={guid}&client=flash");


        // 官方接口失败不致命 —— guid 仍可直接拼流
        let json = self.get_json(&url).await.ok();

        let mut meta = serde_json::Map::new();
        let mut title = guid.clone();
        let mut cover = None;
        let mut description = None;

        if let Some(j) = json.as_ref() {
            if j.get("ack").and_then(|v| v.as_str()) == Some("yes") {
                title = j
                    .get("title")
                    .and_then(|v| v.as_str())
                    .unwrap_or(&title)
                    .to_string();
                cover = j.get("image").and_then(|v| v.as_str()).map(String::from);
                description = j
                    .get("tag")
                    .and_then(|v| v.as_str())
                    .map(String::from);

                for (k, field) in [
                    ("column", "column"),
                    ("play_channel", "playChannel"),
                    ("duration", "duration"),
                    ("editor", "editor"),
                ] {
                    if let Some(v) = j.get(field).or_else(|| {
                        // duration 在 video.totalLength 里
                        if field == "duration" {
                            j.get("video").and_then(|v| v.get("totalLength"))
                        } else {
                            None
                        }
                    }) {
                        meta.insert(k.to_string(), v.clone());
                    }
                }
            }
        }

        // ★ 多清晰度候选（实测 2000/1200/850/450 可用，270 不可用）
        let mut sources = Vec::new();

        // 源 1：官方 HLS（域名每次可能变，动态读取）
        if let Some(j) = json.as_ref() {
            if let Some(u) = j.get("hls_url").and_then(|v| v.as_str()) {
                if u.starts_with("http") {
                    sources.push(PlaySource {
                        code: "official".into(),
                        title: "官方 HLS".into(),
                        count: 1,
                        nested: vec![],
                    });
                }
            }
        }
        // 源 2：CDN 直连（guid 拼多档）
        sources.push(PlaySource {
            code: "cdn".into(),
            title: "CDN 直连".into(),
            count: 4,
            nested: vec![],
        });

        if sources.is_empty() {
            return Err(ProviderError::new(
                ErrorKind::NotFound,
                format!("未能解析 {guid}"),
            ));
        }

        /*
         * ★ 剧集展开（2026-09-15 新增）
         *
         * 原先这里写死 `episodes: vec![]`，注释是「点播为单集，无剧集列表」——
         * 对**单个视频**成立，但电视剧是**多集**的：
         * 搜索结果里 `《老舅》 第5集`、`《老舅》 第19集` 各是一条独立记录，
         * 聚合后只留下了第 2 集的 guid。若不在这里展开，
         * 用户点进《老舅》只能看到「一集」，无法选其他集。
         *
         * 做法：**没有专辑接口可用**（实测 `getVideoListByAlbumId` 返回
         * 「拒绝访问」），只能反过来用**剧名回搜** —— 而剧名就在标题里
         * （形如 `《老舅》 第5集`）。这也是搜索页自己能聚合的唯一依据。
         *
         * 代价：详情页会多打 2~3 次搜索请求。可接受 ——
         * 详情页本来就只进一次，且结果可以靠前端缓存（见 api/cache.ts）。
         */
        let mut episodes: Vec<Episode> = Vec::new();
        let mut series_brand: Option<String> = None;
        if let Some((brand, _)) = parse_episode_title(&title) {
            if let Ok(mut found) = self.album_episodes(&brand).await {
                // 集号升序，用户从上往下看
                found.sort_by_key(|(n, _, _)| *n);
                episodes = found
                    .into_iter()
                    .map(|(n, guid, _cover)| Episode {
                        id: guid,
                        title: format!("第{n}集"),
                        order: n,
                        player_id: None,
                    })
                    .collect();
                if episodes.len() > 1 {
                    series_brand = Some(brand);
                }
            }
        }

        let is_series = series_brand.is_some();

        /*
         * ★ 剧集详情页的标题要显示**剧名**，而不是「第2集」
         *
         * 聚合条目的 guid 是「集号最小的一集」，于是 `title` 会是
         * `《老舅》 第2集` —— 用户点进《老舅》却看到「第2集」当标题，
         * 与列表页显示的《老舅》对不上（实测发现的体验问题）。
         * 既然是剧集，标题就用剧名，并标注总集数。
         */
        if let Some(brand) = series_brand.as_ref() {
            title = format!("《{brand}》");
        }

        Ok(MediaDetail {
            id: id.clone(),
            title,
            cover,
            description,
            /*
             * ⚠️ 这里**不要**再加「N 集」角标。
             *
             * 前端 DetailView 已经会渲染 `{{ episodes.length }} 集`
             * （见 `DetailView.vue` 的 `.hero__badges`），
             * 后端再加一个就会出现「27 集 27 集」重复显示
             * —— 实测截图确认的显示问题。
             */
            badges: vec![],
            kind: if is_series {
                MediaKind::Series
            } else {
                MediaKind::Movie
            },
            meta,
            sources,
            episodes,
        })
    }

    async fn resolve(&self, id: &MediaId, req: &PlayRequest) -> Result<Vec<StreamCandidate>> {
        let guid = &id.native;
        let mut out = Vec::new();

        // ★★ 直播频道必须先分流
        //
        // 实测（2026-09-15）：直播频道的 id（`cctv1`…）与点播 guid（32 位十六进制）
        // 完全不同，但前端两个入口都可能调到这里。若不分流，
        // 直播会被套进下面的**点播 CDN 模板**，拼出
        // `https://hls.cntv.lxdns.com/asp/hls/2000/.../cctv1/2000.m3u8` ——
        // 该地址**返回 404**（央视已把直播迁到阿里云 CDN），
        // 表现为「直播一直转圈、无错误提示」（实测踩到）。
        //
        // 直播必须走 `vdn.live.cntv.cn/api2/live.do`（见 `live_urls()`），
        // 它返回的是可用的 `ldncctv*.v.myalicdn.com` 地址。
        if CHANNELS.iter().any(|(cid, _, _, _)| cid == guid) {
            return self.live_urls(guid).await;
        }

        // 官方 HLS 优先（若源指定或未指定）
        if req.source_code.as_deref() != Some("cdn") {
            let url =
                format!("https://vdn.apps.cntv.cn/api/getHttpVideoInfo.do?pid={guid}&client=flash");
            if let Ok(j) = self.get_json(&url).await {
                if let Some(u) = j.get("hls_url").and_then(|v| v.as_str()) {
                    if u.starts_with("http") {
                        out.push(
                            StreamCandidate::new(
                                u.split('?').next().unwrap_or(u),
                                StreamKind::Hls,
                            )
                            .with_quality("自适应")
                            .with_label("官方 HLS")
                            .with_headers(hdr()),
                        );
                    }
                }
            }
        }

        // CDN 直连多档
        if req.source_code.as_deref() != Some("official") {
            for (br, label) in [
                ("2000", "超清 2000k"),
                ("1200", "高清 1200k"),
                ("850", "标清 850k"),
                ("450", "流畅 450k"),
            ] {
                out.push(
                    StreamCandidate::new(
                        format!(
                            "https://hls.cntv.lxdns.com/asp/hls/{br}/0303000a/3/default/{guid}/{br}.m3u8"
                        ),
                        StreamKind::Hls,
                    )
                    .with_quality(label)
                    .with_label("CDN 直连")
                    .with_headers(hdr()),
                );
            }
        }

        if out.is_empty() {
            return Err(ProviderError::new(
                ErrorKind::NotFound,
                "未解析出播放地址",
            ));
        }
        Ok(out)
    }

    async fn live_channels(&self) -> Result<Vec<LiveChannel>> {
        Ok(CHANNELS
            .iter()
            .map(|(id, _epg, name, group)| LiveChannel {
                id: id.to_string(),
                name: name.to_string(),
                logo: None,
                group: Some(group.to_string()),
                now_playing: None,
            })
            .collect())
    }

    async fn live_stream(&self, channel_id: &str) -> Result<Vec<StreamCandidate>> {
        self.live_urls(channel_id).await
    }

    async fn epg(&self, channel_id: &str, _day: Option<&str>) -> Result<Vec<EpgEntry>> {
        // channel_id 可能是直播 id（cctvjilu），需转成 EPG id（cctv9）
        let epg_id = CHANNELS
            .iter()
            .find(|(id, _, _, _)| *id == channel_id)
            .map(|(_, epg, _, _)| *epg)
            .unwrap_or(channel_id);

        let url = format!("https://api.cntv.cn/epg/epginfo3?serviceId=shiyi&c={epg_id}");
        let json = self.get_json(&url).await?;

        let node = json
            .get(epg_id)
            .ok_or_else(|| ProviderError::parse(format!("EPG 无 {epg_id} 数据")))?;

        let mut out = Vec::new();
        if let Some(list) = node.get("program").and_then(|v| v.as_array()) {
            for p in list {
                let start = p.get("st").and_then(|v| v.as_i64()).unwrap_or(0);
                let end = p.get("et").and_then(|v| v.as_i64()).unwrap_or(0);
                out.push(EpgEntry {
                    title: p
                        .get("t")
                        .and_then(|v| v.as_str())
                        .unwrap_or("未知节目")
                        .into(),
                    start,
                    end,
                    show_time: p.get("showTime").and_then(|v| v.as_str()).map(String::from),
                    duration: p.get("duration").and_then(|v| v.as_i64()).unwrap_or(0),
                    // 实测：回看 = 直播地址 + 时间区间，故均可回看
                    replayable: start > 0 && end > start,
                });
            }
        }
        Ok(out)
    }

    async fn timeshift(&self, channel_id: &str, start: i64, end: i64) -> Result<StreamCandidate> {
        let live = self.live_urls(channel_id).await?;
        let base = live
            .first()
            .ok_or_else(|| ProviderError::new(ErrorKind::NotFound, "无可用直播地址"))?
            .url
            .clone();
        let base = base.split('?').next().unwrap_or(&base).to_string();

        // ★ 实测：begintimeabs / endtimeabs 为毫秒
        Ok(
            StreamCandidate::new(
                format!("{base}?begintimeabs={}&endtimeabs={}", start * 1000, end * 1000),
                StreamKind::Hls,
            )
            .with_quality("回看")
            .with_label("时移回看")
            .with_headers(hdr()),
        )
    }

    async fn health_check(&self) -> bool {
        // 探测一个已知 guid 的取流接口
        self.get_json("https://vdn.apps.cntv.cn/api/getHttpVideoInfo.do?pid=c4447dc4803741e193c72e86f34e5932&client=flash")
            .await
            .map(|j| j.get("ack").and_then(|v| v.as_str()) == Some("yes"))
            .unwrap_or(false)
    }
}

// ─────────────────────────── 测试 ───────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_advertises_timeshift() {
        let p = CctvProvider::new();
        // 时移回看已实测可用，能力位必须为 true
        assert!(p.manifest().capabilities.timeshift);
        assert!(p.manifest().capabilities.live);
        assert!(p.manifest().capabilities.epg);
    }

    #[test]
    fn channel_table_uses_alias_for_cctv9_and_14() {
        let chans: Vec<_> = CHANNELS.iter().collect();
        let c9 = chans.iter().find(|(_, epg, _, _)| *epg == "cctv9").unwrap();
        assert_eq!(c9.0, "cctvjilu");
        let c14 = chans.iter().find(|(_, epg, _, _)| *epg == "cctv14").unwrap();
        assert_eq!(c14.0, "cctvchild");
    }

    /// 未注入代理时必须能建出客户端（且是真直连）
    #[test]
    fn builds_client_without_proxy() {
        let p = CctvProvider::new();
        let _c = p.http();
        assert!(p.proxy.is_none());
    }

    // ─────────── 搜索相关（2026-09-15 新增）───────────

    /// ★ 实测回归：搜索结果的 title 里带 `<font color="red">` 高亮
    ///
    /// 真实样本（搜「老舅」）：
    /// `《<font color="red">老</font><font color="red">舅</font>》霍晓阳向同学们宣传…`
    /// 不剥离的话界面上会出现裸 HTML 标签。
    #[test]
    fn strips_search_highlight_tags() {
        let raw = "《<font color=\"red\">老</font><font color=\"red\">舅</font>》霍晓阳向同学们宣传老舅生产的眼镜";
        assert_eq!(strip_html_tags(raw), "《老舅》霍晓阳向同学们宣传老舅生产的眼镜");
        // 不该残留任何尖括号
        assert!(!strip_html_tags(raw).contains('<'));
    }

    #[test]
    fn strip_html_handles_entities_and_plain_text() {
        assert_eq!(strip_html_tags("A &amp; B"), "A & B");
        assert_eq!(strip_html_tags("  无标签  "), "无标签");
        assert_eq!(strip_html_tags("<b>粗</b>体"), "粗体");
    }

    /// ★★ 实测回归：`imglink` 里的 32 位 hash **就是取流用的 guid**
    ///
    /// 真实样本：
    /// `https://p1.img.cctvpic.com/fmspic/2026/01/28/5dbb582b20f848378a906316d212afcb-1.jpg`
    /// → guid = `5dbb582b20f848378a906316d212afcb`
    /// （实测用该值调取流接口返回 `ack: yes` 且 hls_url 可用）
    #[test]
    fn extracts_guid_from_imglink() {
        let img = "https://p1.img.cctvpic.com/fmspic/2026/01/28/5dbb582b20f848378a906316d212afcb-1.jpg";
        assert_eq!(
            guid_from_imglink(img).as_deref(),
            Some("5dbb582b20f848378a906316d212afcb")
        );
    }

    /// 结构不符时必须返回 None（宁可少一条结果，也不要拼出播不了的 id）
    #[test]
    fn guid_extraction_rejects_malformed_imglink() {
        // hash 长度不对
        assert!(guid_from_imglink("https://x.com/abc-1.jpg").is_none());
        // 不是十六进制
        assert!(guid_from_imglink("https://x.com/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-1.jpg").is_none());
        // 空串
        assert!(guid_from_imglink("").is_none());
    }

    /// 能力位必须声明支持搜索（此前误标为 false）
    #[test]
    fn manifest_advertises_search() {
        let p = CctvProvider::new();
        assert!(
            p.manifest().capabilities.search,
            "搜索接口已实测可用（search.cctv.com/ifsearch.php），能力位必须为 true"
        );
    }

    // ─────────── 首页动态栏目（2026-09-15）───────────

    /// ★ 栏目页里的 `topicID` 必须能解析出来
    ///
    /// 真实样本（`tv.cctv.com/lm/xwlb/index.shtml`）：
    /// `<script> var topicID = 'TOPC1451528971114112'; </script>`
    #[test]
    fn parses_topic_id_from_column_page() {
        let html = r#"<div></div><script>   var topicID = 'TOPC1451528971114112'; </script><div></div>"#;
        assert_eq!(
            parse_topic_id(html).as_deref(),
            Some("TOPC1451528971114112")
        );

        // 双引号也要支持
        let html2 = r#"var topicID = "TOPC1570026172793162";"#;
        assert_eq!(parse_topic_id(html2).as_deref(), Some("TOPC1570026172793162"));

        // 无引号形式
        let html3 = "var topicID = TOPC1451466072378425;";
        assert_eq!(parse_topic_id(html3).as_deref(), Some("TOPC1451466072378425"));
    }

    /// 解析不出 TOPC 时必须返回 None（栏目没有视频专题，应跳过而非报错）
    #[test]
    fn topic_id_parser_rejects_non_topic_pages() {
        assert!(parse_topic_id("<html>no topic here</html>").is_none());
        assert!(parse_topic_id("").is_none());
        // topicID 存在但值不是 TOPC 格式
        assert!(parse_topic_id("var topicID = 'EPGM1387361853673102';").is_none());
        // 只有等号没有值
        assert!(parse_topic_id("var topicID =").is_none());
    }

    /// ★★ 首页栏目必须是**动态**的，不能退回写死的那 4 个
    ///
    /// 实测基准：央视有 343 个栏目，动态链路能解析出 8 个以上。
    /// 这个断言防止将来有人「优化」回硬编码。
    #[tokio::test]
    #[ignore = "需要网络"]
    async fn home_columns_are_dynamic_not_hardcoded() {
        let p = CctvProvider::new();
        let sections = p.home().await.unwrap();

        // 第一个是「正在直播」，其余是栏目
        let cols: Vec<&str> = sections
            .iter()
            .skip(1)
            .map(|s| s.title.as_str())
            .collect();
        assert!(
            cols.len() >= 6,
            "动态栏目太少（{} 个: {cols:?}）—— 可能退回了内置兜底表",
            cols.len()
        );

        // 内置兜底表只有 3 个，动态至少 6 个；再多一层保险：
        // 至少要有 1 个**不在**兜底表里的栏目
        let fb: Vec<&str> = COLUMNS_FALLBACK.iter().map(|(_, n)| *n).collect();
        let novel: Vec<&&str> = cols.iter().filter(|c| !fb.contains(c)).collect();
        assert!(
            !novel.is_empty(),
            "所有栏目都来自内置兜底表 {fb:?} —— 说明动态拉取失败了"
        );
    }

    /// 动态拿到的栏目必须**真的能取到内容**（否则首页会出现空区块）
    #[tokio::test]
    #[ignore = "需要网络"]
    async fn dynamic_columns_have_content() {
        let p = CctvProvider::new();
        let sections = p.home().await.unwrap();

        let mut checked = 0;
        for s in sections.iter().skip(1).take(3) {
            let SectionSource::Category { category_id } = &s.source else {
                continue;
            };
            let page = p
                .list(ListRequest {
                    category_id: category_id.clone(),
                    page: 1,
                    filters: Default::default(),
                })
                .await
                .unwrap_or_else(|e| panic!("栏目「{}」取列表失败: {}", s.title, e.message));
            assert!(
                !page.items.is_empty(),
                "栏目「{}」({category_id}) 返回空列表 —— 不该出现在首页",
                s.title
            );
            checked += 1;
        }
        assert!(checked > 0, "没有可校验的栏目");
    }

    /// 注入代理存储后仍能正常构建客户端（直连配置下不应 panic）
    #[test]
    fn uses_proxy_store_when_injected() {
        let store = std::sync::Arc::new(crate::proxy::ProxyStore::new());
        let p = CctvProvider::new().with_proxy(store);
        assert!(p.proxy.is_some());
        let _c = p.http();
    }

    #[tokio::test]
    #[ignore = "需要网络"]
    async fn live_returns_real_url_not_placeholder() {
        let p = CctvProvider::new();
        let s = p.live_stream("cctv1").await.unwrap();
        assert!(!s.is_empty());
        // ★ 核心断言：不能拿到占位符
        assert!(
            !s[0].url.contains("yangshi"),
            "拿到占位符！说明 pd:// 或 client=iosapp 失效"
        );
    }

    #[tokio::test]
    #[ignore = "需要网络"]
    async fn vod_resolve_produces_candidates() {
        let p = CctvProvider::new();
        let id = MediaId::new("cctv", "c4447dc4803741e193c72e86f34e5932");
        let s = p.resolve(&id, &PlayRequest::default()).await.unwrap();
        assert!(!s.is_empty());
    }

    /// ★ 联网验证：搜索接口真的能用（纯函数绿 ≠ 接口可用）
    ///
    /// 实测基准（2026-09-15 手工验证）：搜「老舅」返回 total 348 条。
    /// 这里不断言具体条数（内容会变），只断言**结构性事实**：
    /// 有结果、id 是 32 位 guid、标题已剥离 HTML、能取到流。
    #[tokio::test]
    #[ignore = "需要网络"]
    async fn search_returns_usable_results() {
        let p = CctvProvider::new();
        let page = p.search("老舅", 1).await.unwrap();

        assert!(!page.items.is_empty(), "搜索结果为空，接口可能已变");
        assert!(page.total.unwrap_or(0) > 0, "total 应为正数");

        let first = &page.items[0];
        // 标题必须已剥离 HTML（否则界面会出现裸标签）
        assert!(
            !first.title.contains('<'),
            "标题仍含 HTML 标签: {}",
            first.title
        );
        assert_eq!(first.id.provider, "cctv");
        assert_eq!(first.id.native.len(), 32, "guid 应为 32 位");
        assert!(
            first.id.native.chars().all(|c| c.is_ascii_hexdigit()),
            "guid 应为十六进制: {}",
            first.id.native
        );

        // ★ 最强断言：拿搜索结果的 id **真的能取到流**
        //   （这验证了「imglink hash 就是 guid」这个简化成立）
        let streams = p
            .resolve(&first.id, &PlayRequest::default())
            .await
            .expect("搜索结果的 id 取流失败 —— imglink→guid 的假设可能已失效");
        assert!(!streams.is_empty(), "取流返回空");
    }

    /// ★★ 联网验证：列表页与详情页的**集数必须一致**
    ///
    /// 实测踩到的真实 bug：`search()` 只补抓到第 3 页（24 集），
    /// 而 `album_episodes()` 抓 4 页（27 集）→
    /// **列表页写「全 24 集（第2–27集）」，点进去却是 27 集**。
    /// 用户会以为少了 3 集，或以为列表骗人。
    ///
    /// 两处抓取页数必须一致（都取 4 页，因为第 4 页才有第 1 集）。
    #[tokio::test]
    #[ignore = "需要网络"]
    async fn search_and_detail_agree_on_episode_count() {
        let p = CctvProvider::new();
        let page = p.search("老舅", 1).await.unwrap();

        let drama = page
            .items
            .iter()
            .find(|i| i.kind == MediaKind::Series)
            .expect("没有聚合出剧集条目");

        // 从列表页副标题里解析出「全 N 集」
        let sub = drama.subtitle.as_deref().unwrap_or("");
        let listed: u32 = sub
            .split("全 ")
            .nth(1)
            .and_then(|s| s.split_whitespace().next())
            .and_then(|n| n.parse().ok())
            .unwrap_or_else(|| panic!("副标题里没有集数: {sub}"));

        // 详情页的真实集数
        let detail = p.detail(&drama.id).await.unwrap();
        let actual = detail.episodes.len() as u32;

        assert_eq!(
            listed, actual,
            "列表页写「全 {listed} 集」，详情页却是 {actual} 集 —— \
             两处抓取页数不一致（search 与 album_episodes 必须同为 4 页）"
        );
    }

    /// ★★ 联网验证：电视剧必须**聚合成一部**，而不是散成一堆单集
    ///
    /// 这是 Owner 实际反馈的问题：「这不是一个集合么？怎么拆分成一集一集的了」。
    ///
    /// 实测基准：搜「老舅」原本返回 20 条全是单集，
    /// 聚合后应出现 **1 个 `kind = series` 的条目**（《老舅》），
    /// 且它的 `detail()` 能展开出多集。
    #[tokio::test]
    #[ignore = "需要网络"]
    async fn search_aggregates_tv_series_into_one_item() {
        let p = CctvProvider::new();
        let page = p.search("老舅", 1).await.unwrap();

        // 必须存在剧集型条目
        let series: Vec<_> = page
            .items
            .iter()
            .filter(|i| i.kind == MediaKind::Series)
            .collect();
        assert!(
            !series.is_empty(),
            "没有聚合出任何剧集条目 —— 散集问题没解决。前几条: {:?}",
            page.items.iter().take(5).map(|i| &i.title).collect::<Vec<_>>()
        );

        let drama = series[0];
        assert!(
            drama.title.contains("老舅"),
            "聚合条目标题异常: {}",
            drama.title
        );
        assert!(
            drama.subtitle.as_deref().unwrap_or("").contains("集"),
            "副标题应说明集数，实际: {:?}",
            drama.subtitle
        );

        // ★ 点进去必须能展开出多集（否则聚合等于没用）
        let detail = p
            .detail(&drama.id)
            .await
            .expect("聚合条目的详情加载失败");
        assert!(
            detail.episodes.len() > 1,
            "详情只展开出 {} 集 —— 用户还是没法选集",
            detail.episodes.len()
        );
        assert_eq!(detail.kind, MediaKind::Series);

        // ★ 详情标题应是**剧名**而不是「第N集」
        //   （聚合条目用的是「集号最小的一集」的 guid，
        //     若不改写标题，用户点《老舅》会看到「第2集」当标题）
        assert!(
            detail.title.contains("老舅"),
            "详情标题应为剧名，实际: {}",
            detail.title
        );
        assert!(
            !detail.title.contains("第"),
            "详情标题不该带集号，实际: {}",
            detail.title
        );

        // ★★ 剧集应**尽量**从第 1 集开始，且集号基本连续
        //
        // ⚠️ 这里**不能断言绝对连续**。实测发现央视搜索结果是**动态的**：
        //   同一查询在不同时刻返回的分页内容不同，
        //   有时某几集（如 2~5 集）会落在第 5 页之外而抓不到。
        //   曾经写成 `assert_eq!(w[1], w[0]+1)` 导致测试**偶发失败**
        //   （同一份代码一次通过一次失败），这是典型的脆弱断言。
        //
        // 所以只断言**稳定的性质**：
        //   · 至少 5 集（确认聚合真的生效了，不是单集）
        //   · 从第 1 集开始（抓够页数的核心收益）
        //   · 集号严格递增（去重与排序正确）
        //   · 覆盖到最后一集（长剧能抓全）
        let orders: Vec<u32> = detail.episodes.iter().map(|e| e.order).collect();
        assert!(
            orders.len() >= 5,
            "只聚合出 {} 集，聚合逻辑可能失效",
            orders.len()
        );
        assert_eq!(
            orders.first().copied(),
            Some(1),
            "剧集应从第 1 集开始，实际从 {:?} 开始（抓取页数可能不够）",
            orders.first()
        );
        // 严格递增（已排序 + 已去重）
        for w in orders.windows(2) {
            assert!(w[1] > w[0], "剧集号未严格递增：{} 之后是 {}", w[0], w[1]);
        }
        // 应覆盖到较后的集（说明确实抓了多页，而不是只有首页那十几集）
        assert!(
            *orders.last().unwrap() >= 20,
            "最后一集只到 {}，多页抓取可能失效",
            orders.last().unwrap()
        );

        // 每一集的 id 都应能取流（抽查第一集）
        let first_ep = MediaId::new("cctv", &detail.episodes[0].id);
        let streams = p
            .resolve(&first_ep, &PlayRequest::default())
            .await
            .expect("剧集取流失败");
        assert!(!streams.is_empty());
    }

    /// 空关键词不应打网络请求（防御性）
    #[tokio::test]
    async fn search_empty_keyword_returns_empty_without_network() {
        let p = CctvProvider::new();
        let page = p.search("   ", 1).await.unwrap();
        assert!(page.items.is_empty());
        assert_eq!(page.total, None);
    }

    // ─────────── 剧集聚合（2026-09-15 新增）───────────

    /// ★ 正片剧集必须能被识别（这是聚合的基础）
    #[test]
    fn parses_episode_titles() {
        // 实测样本
        assert_eq!(
            parse_episode_title("《老舅》 第5集"),
            Some(("老舅".into(), 5))
        );
        assert_eq!(
            parse_episode_title("《老舅》 第27集（大结局）"),
            Some(("老舅".into(), 27))
        );
        // 无空格
        assert_eq!(
            parse_episode_title("《狂飙》第1集"),
            Some(("狂飙".into(), 1))
        );
    }

    /// ★★ 片段/花絮**不能**被当成剧集
    ///
    /// 实测央视搜索里同一部剧会混着：
    ///   · `《老舅》霍晓阳向同学们宣传老舅生产的眼镜`  ← 片段
    ///   · `[中国电影报道]《老舅》主演郭京飞：…`       ← 栏目报道
    /// 若误判成剧集，会把它们并进剧集列表，用户点「第38集」看到的是花絮。
    #[test]
    fn rejects_non_episode_titles() {
        assert_eq!(parse_episode_title("《老舅》霍晓阳向同学们宣传老舅生产的眼镜"), None);
        assert_eq!(parse_episode_title("[中国电影报道]《老舅》主演郭京飞"), None);
        assert_eq!(parse_episode_title("《老舅》 第零集"), None); // 非数字
        assert_eq!(parse_episode_title("《老舅》 第0集"), None); // 集号 0 无意义
        assert_eq!(parse_episode_title("没有书名号 第5集"), None);
        assert_eq!(parse_episode_title("《》 第5集"), None); // 空剧名
        assert_eq!(parse_episode_title(""), None);
    }

    /// 剧名里的书名号必须正确剥离（含中文标点的字节边界）
    #[test]
    fn episode_parser_handles_chinese_punctuation() {
        // 剧名本身带标点
        assert_eq!(
            parse_episode_title("《与奔驰于透明之夜的你，谈一场看不见的恋爱》 第3集"),
            Some(("与奔驰于透明之夜的你，谈一场看不见的恋爱".into(), 3))
        );
    }
}
