//! 统一领域模型 —— 所有 Provider 的输出都归一化到这里
//!
//! **设计原则**：UI 层完全不知道上游是什么协议（央视私有 API / 苹果 CMS / drpy / 进程外 HTTP），
//! 只消费本模块定义的类型。接入新站点 = 新增一个 Provider 实现，UI 零改动。

use serde::{Deserialize, Serialize};

// ─────────────────────────── 标识 ───────────────────────────

/// 带来源前缀的复合 ID，避免跨平台冲突
///
/// 序列化为 `"{provider}:{native}"`，例如 `"cctv:c4447dc4..."`。
///
/// ⚠️ **这条「序列化为字符串」不是装饰性说明，是前后端的硬契约**：
/// 前端 `src/api/types.ts` 把 id 声明为 `MediaKey = string`，
/// 且 `HomeView.splitKey()` / `SearchView` / `BrowseView` 都按 `indexOf(":")` 切分。
/// 若直接 `derive(Serialize)`，输出的会是 `{provider, native}` **对象**，
/// 前端一切分就抛 `TypeError: key.indexOf is not a function` —— 点海报没反应。
/// 故此处手写 serde 实现，锁定为字符串形态（这也是本文件注释一直承诺的形态）。
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct MediaId {
    pub provider: String,
    pub native: String,
}

impl Serialize for MediaId {
    fn serialize<S: serde::Serializer>(&self, s: S) -> std::result::Result<S::Ok, S::Error> {
        s.serialize_str(&self.as_key())
    }
}

impl<'de> Deserialize<'de> for MediaId {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        use serde::de::Error;

        // 既接受 `"cctv:xxx"` 字符串，也兼容旧的 `{provider, native}` 对象形态
        // （落库数据 / 旧前端可能仍是对象，不能一升级就崩）
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Repr {
            Key(String),
            Obj { provider: String, native: String },
        }

        match Repr::deserialize(d)? {
            Repr::Key(s) => MediaId::parse(&s)
                .ok_or_else(|| D::Error::custom(format!("非法 MediaId: {s:?}"))),
            Repr::Obj { provider, native } => Ok(MediaId { provider, native }),
        }
    }
}

impl MediaId {
    pub fn new(provider: impl Into<String>, native: impl Into<String>) -> Self {
        Self {
            provider: provider.into(),
            native: native.into(),
        }
    }

    /// 解析 `"{provider}:{native}"`。native 中可能含 `:`，故只切第一个。
    pub fn parse(s: &str) -> Option<Self> {
        let (provider, native) = s.split_once(':')?;
        if provider.is_empty() || native.is_empty() {
            return None;
        }
        Some(Self::new(provider, native))
    }

    pub fn as_key(&self) -> String {
        format!("{}:{}", self.provider, self.native)
    }
}

impl std::fmt::Display for MediaId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}:{}", self.provider, self.native)
    }
}

// ─────────────────────────── 内容 ───────────────────────────

/// 内容类型
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MediaKind {
    /// 电影 / 单集
    Movie,
    /// 剧集 / 番剧（有多集）
    Series,
    /// 直播频道
    Live,
    /// 综艺 / 纪录片 / 动画等（视作 Series 的别名，便于 UI 归类）
    Variety,
    /// 合集 / 栏目
    Collection,
}

impl Default for MediaKind {
    fn default() -> Self {
        MediaKind::Movie
    }
}

/// 统一媒体条目 —— 列表页/搜索结果都用它
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaItem {
    pub id: MediaId,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover: Option<String>,
    /// 副标题，如「更新至第 12 集」「2026-09-14」
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
    /// 角标，如「1080P」「直播中」「VIP」「会员」
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub badges: Vec<String>,
    #[serde(default)]
    pub kind: MediaKind,
    /// 原始描述（可空）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// 分类
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Category {
    pub id: String,
    pub name: String,
    /// 嵌套子分类（部分站点有二级分类）
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub children: Vec<Category>,
}

/// 首页分区（一个横向滚动的区块）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Section {
    pub id: String,
    pub title: String,
    /// 该区块如何取数据（UI 据此懒加载）
    pub source: SectionSource,
    /// 若 Provider 已预取，可直接带数据
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub items: Vec<MediaItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum SectionSource {
    /// 该分类的列表
    Category { category_id: String },
    /// 榜单
    Rank { rank_id: String },
    /// 最近更新
    Recent,
    /// 自定义（Provider 自己解释）
    Custom { key: String },
    /// 静态（items 已带数据）
    Static,
}

/// 分页结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Page<T> {
    pub items: Vec<T>,
    pub page: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub page_count: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total: Option<u64>,
}

// ─────────────────────────── 播放源（多源换源）───────────────────────────

/// 播放源 / 线路 —— **支持任意深度嵌套**（对应「嵌套选择」需求）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaySource {
    /// 该源的唯一编码，用于拉取剧集（如 cycani 的 `cychub`）
    pub code: String,
    pub title: String,
    /// 该源下的剧集数量（0 表示未知）
    #[serde(default)]
    pub count: u32,
    /// ★ 嵌套：线路里还有线路
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub nested: Vec<PlaySource>,
}

/// 剧集
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Episode {
    pub id: String,
    pub title: String,
    /// 排序号
    #[serde(default)]
    pub order: u32,
    /// 同源下的多线路标识（可选）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub player_id: Option<String>,
}

/// 详情（含多源 + 剧集）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaDetail {
    pub id: MediaId,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub badges: Vec<String>,
    #[serde(default)]
    pub kind: MediaKind,
    /// 扩展元数据（年份/地区/评分/演员等，由 Provider 自行填充）
    #[serde(default, skip_serializing_if = "serde_json::Map::is_empty")]
    pub meta: serde_json::Map<String, serde_json::Value>,
    /// ★ 播放源列表（多源换源的一级）
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub sources: Vec<PlaySource>,
    /// ★ 剧集列表（二级）
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub episodes: Vec<Episode>,
}

// ─────────────────────────── 取流 ───────────────────────────

/// 流类型 —— 把「WebEmbed 兜底」「音频降级」抽象为通用能力
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StreamKind {
    /// HLS (.m3u8)
    Hls,
    /// DASH (.mpd)
    Dash,
    /// 直链 MP4
    Mp4,
    /// 只能用 WebView 内嵌网页播放
    WebEmbed,
    /// 仅音频（降级/广播模式）
    AudioOnly,
}

impl StreamKind {
    /// 按 URL 推断流的类型（**仅作兜底**，优先用 `from_content_type`）
    ///
    /// # 为什么这里只做保守判断
    ///
    /// URL 后缀**根本不可靠** —— 实测 cycani 的 MP4 直链被站点伪装成 `.mp3`：
    ///
    /// ```text
    /// https://x.cycstream.com/<base64>.mp3?expires=..&md5=..
    ///   ↑ 后缀 .mp3，但响应头是 content-type: video/mp4，文件头 ftypisom
    ///   解码 base64 后的真实文件名：xxx01zm.mp4
    /// ```
    ///
    /// 靠后缀猜的后果（两个方向都踩过）：
    ///   · 曾把无扩展名的 http 链接一律当 HLS → MP4 被交给 hls.js → **无限转圈**
    ///   · 修成「按后缀判断」后又把 `.mp3` 判成 `AudioOnly` → 同样播不了
    ///
    /// 所以现在的策略是**最小假设**：
    ///   · 只有明确见到 `.m3u8` / `.mpd` 才认定 HLS / DASH（这两个格式
    ///     必须走 MSE，判错代价大，且实践中不会伪装）
    ///   · **其余一律 `Mp4`（走原生 `<video>`）** —— 这是容错最高的兜底：
    ///     浏览器自己会根据响应头与文件内容决定怎么解，
    ///     即使实际是别的格式也多半能播；而错误地走 MSE 是硬失败。
    ///   · 绝不因为后缀是音频就降级为 `AudioOnly`（会被伪装骗到）
    pub fn from_url(url: &str) -> Self {
        // 剥掉 query / fragment，只看路径
        let path = url.split(['?', '#']).next().unwrap_or(url).to_lowercase();

        if path.contains(".m3u8") {
            StreamKind::Hls
        } else if path.contains(".mpd") {
            StreamKind::Dash
        } else {
            // 其余全部按直链处理（交由 <video> 原生加载）
            StreamKind::Mp4
        }
    }

    /// ★ 按 HTTP `Content-Type` 判断（**比 URL 后缀可靠得多**）
    ///
    /// Provider 若已拿到响应头，应当优先用这个，再用 `from_url` 兜底。
    /// 实测 cycani 返回 `video/mp4`，而 URL 后缀是 `.mp3` —— 只有看响应头才对。
    pub fn from_content_type(ct: &str) -> Option<Self> {
        let ct = ct.to_lowercase();
        // 取分号前的主类型
        let main = ct.split(';').next().unwrap_or("").trim().to_string();

        if main.contains("mpegurl") || main.contains("x-mpegurl") {
            // application/vnd.apple.mpegurl, application/x-mpegURL
            Some(StreamKind::Hls)
        } else if main.contains("dash") {
            Some(StreamKind::Dash)
        } else if main.starts_with("video/") {
            // video/mp4、video/webm、video/x-flv… 都交给 <video> 原生播放
            Some(StreamKind::Mp4)
        } else if main.starts_with("audio/") {
            // ⚠️ 注意：`audio/mpeg` 也可能是**伪装**的 MP4（cycani 就出现过
            //    content-type 是 video/mp4 而后缀是 .mp3，反过来也可能）。
            //    所以这里只标 AudioOnly，**播放器仍应尝试原生加载**。
            Some(StreamKind::AudioOnly)
        } else {
            None
        }
    }
}

#[cfg(test)]
mod stream_kind_tests {
    use super::StreamKind;

    /// ★ 实测回归：cycani 把 MP4 直链伪装成 `.mp3`
    ///
    /// 真实情况：URL 以 `.mp3` 结尾，但 `content-type: video/mp4`、
    /// 文件头 `ftypisom`，base64 解码后文件名是 `xxx01zm.mp4`。
    /// 曾因后缀被判成 `AudioOnly` 而无法播放。
    #[test]
    fn disguised_mp3_extension_is_not_audio_only() {
        let url = "https://x.cycstream.com/YWJjMDF6bS5tcDQ.mp3?expires=1&md5=abc";
        assert_ne!(StreamKind::from_url(url), StreamKind::AudioOnly);
    }

    /// 带签名的 MP4 直链必须识别为 Mp4（前一轮踩的坑）
    #[test]
    fn signed_mp4_direct_link_is_mp4() {
        assert_eq!(
            StreamKind::from_url("https://x.cycstream.com/abc123.mp4?expires=1&md5=deadbeef"),
            StreamKind::Mp4
        );
    }

    #[test]
    fn hls_with_query_is_hls() {
        assert_eq!(
            StreamKind::from_url("https://x.com/live/2000.m3u8?token=abc"),
            StreamKind::Hls
        );
    }

    #[test]
    fn dash_is_dash() {
        assert_eq!(
            StreamKind::from_url("https://x.com/a.mpd?t=1"),
            StreamKind::Dash
        );
    }

    /// 无扩展名的 http 链接**不该**默认当 HLS（否则又会转圈）
    #[test]
    fn extensionless_http_is_not_assumed_hls() {
        assert_ne!(
            StreamKind::from_url("https://x.com/stream/abc123"),
            StreamKind::Hls
        );
    }

    // ── from_content_type ──

    /// 这是识破伪装的正解：URL 说 mp3，响应头说 video/mp4 → 信响应头
    #[test]
    fn content_type_wins_over_extension() {
        assert_eq!(
            StreamKind::from_content_type("video/mp4"),
            Some(StreamKind::Mp4)
        );
    }

    #[test]
    fn content_type_hls_variants() {
        assert_eq!(
            StreamKind::from_content_type("application/vnd.apple.mpegurl"),
            Some(StreamKind::Hls)
        );
        assert_eq!(
            StreamKind::from_content_type("application/x-mpegURL; charset=utf-8"),
            Some(StreamKind::Hls)
        );
    }

    #[test]
    fn content_type_unknown_returns_none() {
        assert_eq!(StreamKind::from_content_type("application/octet-stream"), None);
    }
}

/// 播放候选流
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StreamCandidate {
    pub url: String,
    pub kind: StreamKind,
    /// 清晰度标签，如 "1080P"
    #[serde(skip_serializing_if = "Option::is_none")]
    pub quality: Option<String>,
    /// 线路名，如 "官方 HLS" / "CDN 直连"
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    /// ★ 播放该流需要的请求头（借鉴 Stremio 的 proxyHeaders）
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub headers: Vec<(String, String)>,
    /// ★ 声明「WebView 播不了，需宿主代理」（借鉴 Stremio 的 notWebReady）
    #[serde(default)]
    pub not_web_ready: bool,
    /// ★★ 该流受 **DRM 保护**，客户端无法解码
    ///
    /// 实测背景（2026-09-15）：央视直播的视频轨被 `udrm` 加密 ——
    /// 容器与 NAL 头是明文（ffprobe 能看到 `h264` + `1024x576`），
    /// 但**载荷被加密**，解码时报
    /// `top block unavailable for requested intra mode` /
    /// `error while decoding MB`。
    ///
    /// 对照实验（同一台机器、同一个 ffmpeg）：
    ///   · 公开测试 HLS        → 0 个解码错误
    ///   · 央视**音频**流       → 0 个解码错误
    ///   · 央视**视频**流（全线路）→ 61~80 个解码错误
    /// ⇒ 网络与工具都正常，**是流本身加密**。
    ///
    /// 为什么要在模型里显式声明：这类流的表现是**画面花屏/绿屏但时间在走**，
    /// 用户完全不知道发生了什么（也不像 HEVC 那样能靠探测解决）。
    /// 标出来之后 UI 才能如实说「该源受 DRM 保护，暂不支持」，
    /// 而不是让用户对着绿屏猜。
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub drm_protected: bool,

    /// ★★★ 独立的**音频轨**地址（DASH 用）
    ///
    /// # 为什么需要它（B 站 1080P 的实测结论，2026-09-19）
    ///
    /// B 站的 `playurl` 接口有两种返回：
    ///
    /// ```text
    /// fnval=1  (durl)  → 音视频**已合并**的 mp4，但**恒为 720P**
    ///                    实测：传 qn=80/116/120 都一样，ffprobe 确认 1280x720
    ///                    format 字段是 "mp4720"
    ///
    /// fnval=16 (DASH)  → 能拿到 **1920x1080**（avc1.640032）
    ///                    但视频轨与音频轨是**两个文件**
    /// ```
    ///
    /// 实测 15/15 个热门视频：不带 `try_look=1` 时 DASH 最高只有 480P，
    /// 加上之后 **15/15 拿到 1080P**。也就是说
    /// 「要 1080P 就必须走 DASH，而 DASH 必然音视频分离」。
    ///
    /// # 播放器怎么用它
    ///
    /// `<video src=url>` 播视频轨（它自带音轨时正常，不带时静音），
    /// 再用一个 `<audio src=audio_url>` 播声音，两者同步。
    ///
    /// 之所以可行（实测确认）：
    ///   · B 站的 DASH 轨是**单个 fMP4 文件**（不是分片列表），
    ///     `moov` 在最前面（偏移 36）→ `<video>` 能直接流式播
    ///   · MSE 支持 `avc1.640032`（1080P H.264）与 `mp4a.40.2`（AAC）
    ///   · ⚠️ **不支持** `hvc1.1.6.L150.90`（HEVC）→
    ///     所以插件必须挑 `avc1` 那条，不能挑 HEVC（挑了会黑屏）
    ///
    /// `None` = 音视频已合并在 `url` 里（绝大多数源的正常情况）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio_url: Option<String>,
}

impl StreamCandidate {
    /// 构造一个普通（可播放）的候选流
    ///
    /// 存在的意义：`StreamCandidate` 有 7 个字段、7 处构造点，
    /// 每次加字段都要改 7 个地方（且容易漏掉某个 provider 导致编译失败）。
    /// 用构造器把「大多数情况」收口，新增字段时只改这里。
    ///
    /// `not_web_ready` 与 `drm_protected` 默认 `false`；
    /// 前者目前无消费方（保留字段），后者由央视直播显式设置。
    pub fn new(url: impl Into<String>, kind: StreamKind) -> Self {
        Self {
            url: url.into(),
            kind,
            quality: None,
            label: None,
            headers: Vec::new(),
            not_web_ready: false,
            drm_protected: false,
            audio_url: None,
        }
    }

    pub fn with_quality(mut self, q: impl Into<String>) -> Self {
        self.quality = Some(q.into());
        self
    }

    pub fn with_label(mut self, l: impl Into<String>) -> Self {
        self.label = Some(l.into());
        self
    }

    pub fn with_headers(mut self, h: Vec<(String, String)>) -> Self {
        self.headers = h;
        self
    }

    /// 标记为 DRM 保护（客户端无法解码）
    pub fn drm(mut self) -> Self {
        self.drm_protected = true;
        self
    }

    /// 指定独立的音频轨（DASH 音视频分离时用，见字段说明）
    pub fn with_audio(mut self, a: impl Into<String>) -> Self {
        self.audio_url = Some(a.into());
        self
    }
}

/// 取流请求 —— 支持指定源与剧集（三级嵌套选择）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PlayRequest {
    /// 二级：播放源 code
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_code: Option<String>,
    /// 三级：剧集 id
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub episode_id: Option<String>,
    /// 指定清晰度
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quality: Option<String>,
}

// ─────────────────────────── 直播 & EPG ───────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LiveChannel {
    pub id: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub logo: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
    /// 当前节目名（若已知）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub now_playing: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EpgEntry {
    pub title: String,
    /// Unix 秒
    pub start: i64,
    pub end: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub show_time: Option<String>,
    #[serde(default)]
    pub duration: i64,
    /// 是否可回看
    #[serde(default)]
    pub replayable: bool,
}

// ─────────────────────────── Provider 能力 ───────────────────────────

/// 能力位 —— UI 据此自适应显示/隐藏功能
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Capabilities {
    pub vod: bool,
    pub live: bool,
    pub epg: bool,
    pub search: bool,
    /// 需要登录才能取流（如 cycani）
    pub login_required: bool,
    /// 支持平台内多播放源（如 cycani 的 play_from）
    pub multi_source: bool,
    /// 平台自带服务端观看历史
    pub server_side_history: bool,
    /// 支持收藏
    pub favorites: bool,
    /// 支持时移回看
    pub timeshift: bool,
    /// 支持弹幕
    pub danmaku: bool,

    // ─────────── 登录（2026-09-20 新增，为 B站这类"游客也能用"的源）───────────
    /// **可以登录，但不是必须** —— 游客态照样能用
    ///
    /// # 为什么需要它与 `login_required` 分开
    ///
    /// 「必须登录」与「支持登录」是**两件事**：
    /// ```text
    /// cycani  必须登录才能取流        → login_required = true
    /// bilibili 游客就能看 1080P，
    ///          但登录后能同步关注/收藏 → login_supported = true
    /// ```
    ///
    /// ⚠️ **绝不能**给 B站 设 `login_required = true`：
    ///    `Registry::ensure_session` 会因此**挡住游客播放**
    ///    （`if !login_required { return Some(true) }` 那条捷径失效），
    ///    而「不登录就能看 1080P」正是 Owner 明确要的能力。
    ///
    /// 所以设置页的登录入口过滤条件是
    /// `login_required || login_supported`，
    /// 而会话校验只看 `login_required`。
    #[serde(default)]
    pub login_supported: bool,
    /// 登录弹窗里的一段说明（告诉用户该怎么操作）
    ///
    /// 例：B站要「从浏览器复制 Cookie 粘进来」，不写清楚用户不知道做什么。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub login_hint: Option<String>,
    /// 登录是否需要「账号」字段（默认 true）
    ///
    /// B站的 Cookie 导入**不需要账号**，只有密码框（用来粘 Cookie）。
    /// 设 false 时前端隐藏账号框，也**不再要求它非空**
    /// （否则登录按钮永远是禁用状态）。
    #[serde(default = "default_true", alias = "loginNeedsUsername")]
    pub login_needs_username: bool,

    /// ★ 是否支持**扫码登录**（2026-09-21）
    ///
    /// 为 true 时登录弹窗会出现「扫码」页签（默认页），
    /// 调 `provider_qr_login_start` / `provider_qr_login_poll`。
    ///
    /// ⚠️ 与 `login_supported` 的关系：扫码是**登录方式之一**，
    ///    不是独立能力 —— 所以设了它也必须设 `login_supported: true`，
    ///    否则设置页的登录入口根本不出现（那个过滤条件不看本字段）。
    ///
    /// ⚠️ 默认 false：老插件没声明这一项时保持原行为（只有账号/密码表单）。
    #[serde(default)]
    pub login_qr_supported: bool,

    /// ★★ 是否能**用保存的凭据自动重新登录**（2026-09-25，task-38）
    ///
    /// # 为什么需要这个能力位（Owner 报的真问题）
    ///
    /// > 次元城登录失效 明明不需要验证码就可以自动登录，还提示 验证码
    ///
    /// 登录态失效时，设置页原本对**所有源**都写同一句话：
    /// ```text
    /// 「需重新登录（可能需要验证码，请手动完成）」
    /// ```
    /// 那是原版 `SettingsView.vue:175` 的**通用文案**（给真有验证码的源用的）。
    ///
    /// 但对**实现了 `autoLogin()` 的插件**（如次元城：账号密码存在
    /// `plugins/.data/<id>.json`，token 一过期就能自己重登）这句话是**误导**：
    /// ```text
    /// 用户看到「可能需要验证码，请手动完成」
    ///   → 以为必须人工介入，于是不管它（或白跑一趟设置页手填账号密码）
    /// 而实际：他只要**点一下播放**，宿主就会自动重登（实测 0.46 秒成功）
    /// ```
    /// ⇒ 文案叫他"手动完成"，但他**什么都不用做**。
    ///
    /// # 与插件方法 `canAutoLogin()` 的关系
    ///
    /// 本字段是那个方法的**声明式镜像** —— 插件实现了 `canAutoLogin()`
    /// 就顺手声明 `canAutoLogin: true`，宿主据此选文案。
    ///
    /// ⚠️ 宿主**不**用本字段去决定"要不要真的调 autoLogin"
    ///    （那个判据始终是插件实际有没有实现方法 + 凭据在不在）；
    ///    本字段**只影响文案**。两者故意分开：
    ///    ```text
    ///    真调不调 → 运行时事实（凭据在不在）—— 猜错会真的登不上
    ///    说什么话 → 声明式能力位          —— 猜错只是措辞不准
    ///    ```
    ///
    /// ⚠️ **默认必须是 `false`**（不能 true）。
    ///    默认 true 的后果：没实现 `autoLogin()` 的老插件也会被承诺
    ///    「正在自动重新登录」→ 用户干等一个**永远不会发生**的重登
    ///    ⇒ 比原来那句通用文案**更糟**（从"误导"变成"撒谎"）。
    #[serde(default)]
    pub can_auto_login: bool,
}

// ─────────────────────────── 插件配置声明 ───────────────────────────

/// 插件声明的**一项**配置
///
/// # 设计来源
///
/// 需求方指定的参考是「阅读（Legado）的书源」与 Stremio 的 `manifest.config`：
/// **宿主只提供「渲染能力」，界面由插件自己描述**。
/// 插件作者加一个配置项不需要宿主改代码，几百个插件共用同一套设置界面。
///
/// # 为什么是声明式而不是「插件自己画界面」
///
/// 让插件写 HTML 意味着：宿主要做沙箱、XSS 防护、样式隔离，
/// 而且各插件的界面会长得五花八门（与项目「卡片尺寸必须全站统一」的
/// 既有要求直接冲突）。声明式则只需要一个**受控的控件白名单**。
///
/// # ⚠️ 与「做在插件里而不是软件内置」的关系
///
/// 这条能力正是 Owner 那个要求的**技术前提**：
/// 「1080P 做在插件里」「代理做在插件里」——
/// 软件端只渲染控件 + 存值，**一行站点相关代码都没有**。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfigField {
    /// 键名（插件用 `host.config.get('这个')` 读）
    pub key: String,
    /// 显示名
    pub label: String,
    /// 控件类型：switch | select | text | password | number | info
    ///
    /// ⚠️ 用字符串而不是 enum：插件是 JS 写的，传错值时
    /// 我们希望**降级成一个提示**而不是整个插件加载失败。
    /// 校验在 [`ConfigField::normalized_kind`] 里做。
    ///
    /// # ⚠️ `type` 与 `kind` 都接受（`alias`）
    ///
    /// 插件作者自然会写 `type: 'select'`（Stremio/Legado 的契约都用 `type`），
    /// 但 `type` 在 Rust 里是关键字、在 JSON Schema 里是保留字，
    /// 所以结构体字段叫 `kind`。
    ///
    /// **实测踩过**：只认 `kind` 时，插件写 `type` 会被 serde 当成未知字段
    /// 直接丢掉，于是 `kind` 落到默认值 `"text"` ——
    /// 表现是「select 渲染成了输入框」，而且**不报错**。
    /// 加 `alias` 后两种写法都能用。
    ///
    /// 序列化出去时仍用 `kind`（前端按 `kind` 读）。
    #[serde(default = "default_kind", alias = "type")]
    pub kind: String,
    /// 默认值（JSON，因为类型随 kind 变）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default: Option<serde_json::Value>,
    /// `select` 的选项
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub options: Vec<ConfigOption>,
    /// 说明文字（显示在控件下方）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hint: Option<String>,
    /// `text` / `password` / `number` 的占位符
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub placeholder: Option<String>,
    /// 条件显示：只有这些键**为真**时才显示本项
    ///
    /// 例：`proxyUrl` 配 `show_if: {"proxy": true}` ——
    /// 没开代理时不显示地址输入框，界面不被无关项塞满。
    #[serde(default, skip_serializing_if = "std::collections::HashMap::is_empty")]
    pub show_if: std::collections::HashMap<String, serde_json::Value>,
    /// 数值范围（`number` 用）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub min: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max: Option<f64>,
}

/// `select` 的一个选项
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfigOption {
    pub value: String,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hint: Option<String>,
}

fn default_kind() -> String {
    "text".into()
}

/// 受支持的控件类型白名单
///
/// **只认这六种** —— 插件写了别的就降级成 `info`（纯文字），
/// 而不是报错让整个插件加载失败。
pub const CONFIG_KINDS: &[&str] = &["switch", "select", "text", "password", "number", "info"];

impl ConfigField {
    /// 归一化控件类型（不认识的一律当 `info`）
    pub fn normalized_kind(&self) -> &str {
        let k = self.kind.trim().to_ascii_lowercase();
        if CONFIG_KINDS.contains(&k.as_str()) {
            // 返回静态串，避免借用临时 String
            CONFIG_KINDS[CONFIG_KINDS.iter().position(|x| *x == k).unwrap()]
        } else {
            "info"
        }
    }

    /// 校验并修正（加载插件时调用一次）
    ///
    /// 目的：**把错误挡在渲染之前**。比如 `select` 没有 options
    /// 会渲染出一个空下拉框，用户完全不知道怎么办 —— 不如直接
    /// 降级成 `info` 并说明原因。
    pub fn sanitize(&mut self, warn: &mut Vec<String>) {
        if self.key.trim().is_empty() {
            warn.push(format!("配置项「{}」缺少 key，已忽略", self.label));
            self.kind = "info".into();
            return;
        }

        let k = self.kind.trim().to_ascii_lowercase();
        if !CONFIG_KINDS.contains(&k.as_str()) {
            warn.push(format!(
                "配置项「{}」的 type「{}」不受支持，已降级为说明文字（支持：{}）",
                self.label,
                self.kind,
                CONFIG_KINDS.join(" / ")
            ));
            self.kind = "info".into();
            return;
        }
        self.kind = k;

        // `select` 必须有选项，否则渲染出空下拉框
        if self.kind == "select" && self.options.is_empty() {
            warn.push(format!("配置项「{}」是 select 但没有 options，已降级为说明文字", self.label));
            self.kind = "info".into();
        }

        // `select` 的默认值必须在选项里，否则界面显示空
        if self.kind == "select" {
            if let Some(d) = self.default.as_ref().and_then(|v| v.as_str()) {
                if !self.options.iter().any(|o| o.value == d) {
                    warn.push(format!(
                        "配置项「{}」的默认值「{}」不在选项里，已改用第一项",
                        self.label, d
                    ));
                    self.default = self.options.first().map(|o| serde_json::Value::String(o.value.clone()));
                }
            } else {
                // 没给默认值 → 用第一项（比留空好）
                self.default = self.options.first().map(|o| serde_json::Value::String(o.value.clone()));
            }
        }

        // `switch` 的默认值必须是布尔
        if self.kind == "switch" && self.default.is_some() && !self.default.as_ref().unwrap().is_boolean() {
            warn.push(format!("配置项「{}」是 switch 但默认值不是布尔，已改用 false", self.label));
            self.default = Some(serde_json::Value::Bool(false));
        }

        // 数值范围反了就交换（min > max 会让滑块或校验行为诡异）
        if let (Some(a), Some(b)) = (self.min, self.max) {
            if a > b {
                warn.push(format!("配置项「{}」的 min/max 写反了，已交换", self.label));
                self.min = Some(b);
                self.max = Some(a);
            }
        }
    }

    /// 取默认值（没声明时按 kind 给一个合理值）
    pub fn effective_default(&self) -> serde_json::Value {
        if let Some(d) = &self.default {
            return d.clone();
        }
        match self.kind.as_str() {
            "switch" => serde_json::Value::Bool(false),
            "number" => serde_json::Value::from(0),
            _ => serde_json::Value::String(String::new()),
        }
    }
}

/// Provider 身份
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderManifest {
    /// 唯一 id，如 "cctv" / "cycani"
    ///
    /// ⚠️ **设计要求：id 由内容派生（稳定），不要用序号。**
    /// NewPipe 的扩展 PR（#4054，2020 年被否决）作者亲自承认：
    /// *"the DB uses service ID, which could change, so that doesn't work well
    /// if you add/remove extensions"* —— 序号 ID 被数据库引用后，增删即错位。
    /// Tachiyomi 的做法是由 `名称/语言/版本` 派生哈希，值得借鉴。
    pub id: String,
    pub name: String,
    pub version: String,
    /// 来源类型：builtin | http | declarative
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    /// ★ 该 Provider 处理哪些 ID 前缀（借鉴 Stremio idPrefixes，用于多源路由/去重）
    #[serde(default)]
    pub id_prefixes: Vec<String>,
    pub capabilities: Capabilities,
    /// ★ 抓封面图时需要附加的请求头（插件声明）
    ///
    /// # 为什么需要（实测根因）
    ///
    /// B 站图片 CDN（`i0/i1/i2.hdslb.com`）**白名单校验 Referer**：
    ///
    /// ```text
    /// Referer: https://www.bilibili.com  → HTTP 200 ✅
    /// Referer: http://tauri.localhost/   → HTTP 403 ❌  ← 我们的应用
    /// ```
    ///
    /// 而 `<img>` 标签**改不了 Referer**（浏览器安全限制，无法绕过），
    /// 所以封面必须由宿主**代取**——和视频流是同一个问题、同一个解法。
    ///
    /// # 为什么由插件声明而不是宿主内置
    ///
    /// 宿主不知道哪个站的图床要什么头。让插件声明：
    /// **软件端一行站点代码都没有**（与 `config` 同一个原则）。
    /// 不需要防盗链的站点（如次元城走百度 CDN）声明空对象即可，
    /// 宿主会直接放行原始 URL（少一跳、更快）。
    ///
    /// # 与 `StreamCandidate.headers` 的关系
    ///
    /// 两者用途相同（都是"这个 URL 需要这些头才能取"），
    /// 但作用对象不同：那个是**单条流**，这个是**该源的所有封面**。
    /// 封面数量大（首页 240 张），逐张声明不现实。
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub cover_headers: Vec<(String, String)>,
    /// ★ 插件声明的**配置项**（宿主据此渲染设置界面）
    ///
    /// 这是「1080P / 代理 / 登录都做在插件里」的技术前提 ——
    /// 软件端只按声明渲染控件并存值，不含任何站点逻辑。
    ///
    /// 空数组表示该 Provider 没有可配置项（界面不显示「配置」入口）。
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub config: Vec<ConfigField>,
    /// ★ 协议版本，用于兼容性校验（Stremio 缺这个，我们要加）
    #[serde(default = "default_api_version")]
    pub api_version: u32,
    /// 站点主题色（UI 可据此微调配色）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub theme_color: Option<String>,
    /// ★ 是否可用（yt-dlp 的 _WORKING 做法：站点失效时明确告知，而非静默失败）
    #[serde(default = "default_true")]
    pub working: bool,
    /// 不可用原因
    #[serde(skip_serializing_if = "Option::is_none")]
    pub broken_reason: Option<String>,
    /// ★ 用户是否启用（可停用某个源；状态持久化）
    ///
    /// 与 `working` 的区别：
    ///   · `working` —— **站点自身**是否可用（探测得出，用户改不了）
    ///   · `enabled` —— **用户**是否要使用它（用户的选择，存盘）
    ///
    /// `Option` 而不是 `bool`：manifest 由各 Provider 构造，
    /// 它们不该关心启用状态（那是 Registry 与用户的事）——
    /// 由 `list_providers` 在出口处统一填。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
}

fn default_api_version() -> u32 {
    1
}
fn default_true() -> bool {
    true
}

// ─────────────────────────── 错误 ───────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderError {
    pub kind: ErrorKind,
    pub message: String,
    /// 是否需要用户先登录
    #[serde(default)]
    pub needs_login: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    /// 网络/超时
    Network,
    /// 解析失败（上游改版）
    Parse,
    /// 需要登录
    Unauthorized,
    /// 内容不存在
    NotFound,
    /// 地区限制
    GeoBlocked,
    /// 站点已失效
    Broken,
    /// 未实现的能力
    Unsupported,
    /// 其他
    Other,
}

impl ProviderError {
    pub fn new(kind: ErrorKind, msg: impl Into<String>) -> Self {
        Self {
            kind,
            message: msg.into(),
            needs_login: matches!(kind, ErrorKind::Unauthorized),
        }
    }
    pub fn network(msg: impl Into<String>) -> Self {
        Self::new(ErrorKind::Network, msg)
    }
    pub fn parse(msg: impl Into<String>) -> Self {
        Self::new(ErrorKind::Parse, msg)
    }
    pub fn unsupported(msg: impl Into<String>) -> Self {
        Self::new(ErrorKind::Unsupported, msg)
    }
    pub fn unauthorized(msg: impl Into<String>) -> Self {
        Self::new(ErrorKind::Unauthorized, msg)
    }
}

impl std::fmt::Display for ProviderError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}: {}", self.kind, self.message)
    }
}

impl std::error::Error for ProviderError {}

pub type Result<T> = std::result::Result<T, ProviderError>;

// ─────────────────────────── 测试 ───────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// ★ 铁律：MediaId 必须序列化成 `"provider:native"` 字符串。
    /// 一旦退回 derive 的对象形态，前端 `indexOf(":")` 全线崩溃（点海报没反应）。
    #[test]
    fn media_id_serializes_as_prefixed_string() {
        let id = MediaId::new("cctv", "abc123");
        let json = serde_json::to_string(&id).unwrap();
        assert_eq!(json, "\"cctv:abc123\"", "必须是字符串，不能是对象");

        // 且必须能嵌在结构体里保持同一形态（前端读的是 item.id）
        #[derive(Serialize)]
        struct Wrap {
            id: MediaId,
        }
        let w = serde_json::to_string(&Wrap { id }).unwrap();
        assert_eq!(w, "{\"id\":\"cctv:abc123\"}");
    }

    #[test]
    fn media_id_roundtrips() {
        let id = MediaId::new("cycani", "3885");
        let json = serde_json::to_string(&id).unwrap();
        let back: MediaId = serde_json::from_str(&json).unwrap();
        assert_eq!(back, id);
    }

    /// native 里可能含 `:`（部分站点 id 带冒号），只切第一个冒号
    #[test]
    fn media_id_handles_colon_in_native() {
        let id = MediaId::new("cycani", "a:b:c");
        assert_eq!(id.as_key(), "cycani:a:b:c");
        let back: MediaId = serde_json::from_str("\"cycani:a:b:c\"").unwrap();
        assert_eq!(back.provider, "cycani");
        assert_eq!(back.native, "a:b:c");
    }

    /// 向后兼容：旧的 `{provider, native}` 对象形态仍应能反序列化
    /// （避免升级后读到旧数据直接崩）
    #[test]
    fn media_id_accepts_legacy_object_form() {
        let back: MediaId =
            serde_json::from_str(r#"{"provider":"cctv","native":"x1"}"#).unwrap();
        assert_eq!(back, MediaId::new("cctv", "x1"));
    }

    #[test]
    fn media_id_rejects_garbage() {
        assert!(serde_json::from_str::<MediaId>("\"no-colon\"").is_err());
        assert!(serde_json::from_str::<MediaId>("\":empty-provider\"").is_err());
        assert!(serde_json::from_str::<MediaId>("\"empty-native:\"").is_err());
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  PersistedProvider —— 从 lib.rs 搬过来的（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要搬
//
// 它原来定义在 `lib.rs:3119`（Tauri 层），但 `sync/mod.rs` 三处
// 引用 `crate::PersistedProvider` —— 抽核心时暴露出来：
// **它本质是数据模型，不是 UI 层的东西**。
//
// # 原注释保留（说明了设计意图）
//
// **为什么不存「实例」**：声明式源存原始 JSON、HTTP 源存 base URL，
// 启动时**重新构造**。这样上游改了契约/数据格式，重启即生效，
// 不会出现「旧实例带着旧逻辑跑」的问题。
//
// **为什么带上 `id`**：移除源时要知道该删哪一条。
// 声明式源的 id 虽可从 JSON 反解，但 HTTP 源的 id 来自远端 manifest，
// 本地不冗余存一份就无法可靠删除（会留下「幽灵源」在重启后复活）。
/// TVBox 配置导入的源：一个苹果CMS 分类（对应上游的 type_id）
///
/// 分类表在**导入时探测一次**就固化下来（见 `tvbox::probe_apple_cms`），
/// 重启不再联网 —— 上游分类临时挂掉不该让本地源变成「没有分类的空壳」。
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct TvboxCategoryEntry {
    pub id: String,
    pub name: String,
    /// 父分类 id（苹果CMS 的 type_pid；0 / null 都归一成 None）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PersistedProvider {
    /// 声明式 JSON 源：存原始描述
    Declarative { id: String, json: String },
    /// 进程外 HTTP 源：存基址与自定义头
    Http {
        id: String,
        base_url: String,
        #[serde(default)]
        headers: std::collections::HashMap<String, String>,
    },
    /// TVBox 配置导入的苹果CMS 源：存接口地址与导入时探测到的分类
    ///
    /// 存 api + categories 而不是「原始配置 JSON」：一份 TVBox 配置里
    /// 可能有几十个站点，只留下真正可用的那几个，重启时不必再筛一遍。
    Tvbox {
        id: String,
        name: String,
        api: String,
        #[serde(default)]
        categories: Vec<TvboxCategoryEntry>,
    },
}

impl PersistedProvider {
    /// ⚠️ 原工程里是私有的 `fn id`；抽出来后 sync 模块要用，改成 pub
    pub fn id(&self) -> &str {
        match self {
            PersistedProvider::Declarative { id, .. } => id,
            PersistedProvider::Http { id, .. } => id,
            PersistedProvider::Tvbox { id, .. } => id,
        }
    }
}