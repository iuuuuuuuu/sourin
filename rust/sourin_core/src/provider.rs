//! Provider 契约 —— 插件体系的核心
//!
//! # 设计依据（来自开源调研，均有据可查）
//!
//! - **Plex 用 7 年证明进程内插件是错误路线**：其沙箱做得极完整（AST 重写 + 白名单 + 五级策略），
//!   仍被废弃。官方原话 *"if we were to build the feature again, we'd do it very differently"*。
//!   → 问题不在安全，在架构。
//! - **TVBox 的反面教训**：用户无法新增 `csp_Xxx`（编译进 jar 的 Java 类），且 DexClassLoader
//!   是 Android 专属 → 桌面端完全无法复用。
//! - **Stremio / Plex 新架构的正确做法**：进程外 HTTP 契约，用户填一个 URL 即安装，任意语言实现。
//!
//! # 本项目的双轨制
//!
//! | 层 | 机制 | 说明 |
//! |---|---|---|
//! | 内置 Provider | 编译期实现本 trait | 央视 / cycani 等复杂场景 |
//! | HTTP Provider | 进程外 HTTP 契约 | 第三方，任意语言，天然隔离 |
//! | 声明式 Provider | JSON 描述 + JSONPath | 标准 CMS，用户零代码 |
//!
//! **绝不做进程内 dlopen**：Google Play 明文禁止下载可执行代码（含 `.so`），
//! 且 Rust 官方明确 *"The Rust ABI offers no stability guarantees"*。
//!
//! # 长期维护三件套（借鉴 yt-dlp，均有反面案例支撑）
//!
//! 1. **覆写机制**（`plugin_ies_overrides`）—— 社区可在官方发版前修好被站点改版打挂的 provider
//! 2. **错误隔离**（`except Exception: continue`）—— 单个 provider 失败不影响其他
//! 3. **`working` 标记** —— 站点失效时明确告知用户，而非静默失败

// 显式导入（不用 glob）：glob 会把 `model::Result` 别名带进来，遮蔽标准库 `Result<T, E>`，
// 也会让 `ProviderManifest` 等类型变成"私有重导出"，调用方无法直接从本模块导入。
use crate::model::{
    Category, Episode, EpgEntry, LiveChannel, MediaDetail, MediaId, MediaItem, Page, PlayRequest,
    PlaySource, ProviderError, ProviderManifest, Section, StreamCandidate,
};
// `Result<T>` 是领域层的单参数别名（错误固定为 ProviderError）
use crate::model::Result;
use async_trait::async_trait;
use serde::{Deserialize, Serialize};

/// 列表请求
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ListRequest {
    /// 分类 id
    #[serde(default)]
    pub category_id: String,
    #[serde(default = "default_page")]
    pub page: u32,
    /// 附加筛选（分类筛选器）
    #[serde(default)]
    pub filters: std::collections::HashMap<String, String>,
}

fn default_page() -> u32 {
    1
}

/// 登录凭据
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Credentials {
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub password: String,
    /// 其他自定义字段（各站点不同）
    #[serde(default)]
    pub extra: std::collections::HashMap<String, String>,
}

/// 登录会话
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    /// 令牌（不落盘明文，走系统钥匙串）
    pub token: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub avatar: Option<String>,
}

impl Session {
    /// ★ 会话的**有效到期时间**（Unix 秒）
    ///
    /// 优先用插件显式给的 `expires_at`；**缺失时从 JWT 的 `exp` 声明兜底**。
    ///
    /// # 为什么必须兜底（2026-09-24 用户报的 bug）
    ///
    /// 插件契约允许只返回 `token` 而不返回 `expires_at`（`cycani.js` 里
    /// `expiresAt: … ? … : undefined` 就会产生这种会话）。旧逻辑遇到
    /// `expires_at == None` 一律当作「永不过期」：
    /// ```text
    /// expires_at = None → session_needs_refresh() = false
    ///                   → session_state() = Active
    ///                   → 界面显示「已登录」
    /// 而 token 其实早就死了 → 点播才报 unauthorized
    /// ```
    /// 这正是用户说的「明明已登录，实际不能播」。
    ///
    /// JWT 自带 `exp`，用它兜底后「过期与否」就有了判据，
    /// **不再依赖插件是否愿意返回 `expires_at`**。
    pub fn effective_expires_at(&self) -> Option<i64> {
        self.expires_at.or_else(|| jwt_exp_secs(&self.token))
    }

    /// ★ 会话是否**已经过期**（注意与「即将过期」区分）
    ///
    /// 没有到期信息（既无 `expires_at` 也解不出 JWT `exp`）时返回 `false` ——
    /// 那种情况无从判断，**不能凭空说人家过期了**，否则会把正常会话
    /// 误报成失效，反而制造新的「提示未登录但其实能播」。
    pub fn is_expired_at(&self, now: i64) -> bool {
        matches!(self.effective_expires_at(), Some(exp) if exp <= now)
    }
}

/// 从 JWT 的 payload 里读出 `exp`（Unix 秒）
///
/// ⚠️ **刻意不校验签名**：这里只回答「这个 token 自己声明的有效期过了没」，
///    用来决定界面该显示「已登录」还是「登录已失效」。
///    真正的鉴权在服务端，本地校验签名没有任何安全收益，只会引入
///    「密钥从哪来」的问题。所以只做 base64url + JSON 解析。
///
/// 解析不出（不是 JWT、没有 `exp`、编码坏了）一律返回 `None` ——
/// 调用方据此回退到「无到期信息」的保守分支。
fn jwt_exp_secs(token: &str) -> Option<i64> {
    // `Bearer xxx` → `xxx`（cycani 的 token 是带前缀存的）
    let t = token.trim();
    let t = t
        .strip_prefix("Bearer ")
        .or_else(|| t.strip_prefix("bearer "))
        .unwrap_or(t);

    let mut parts = t.split('.');
    let _header = parts.next()?;
    let payload = parts.next()?;
    // JWT 至少要有 header.payload.signature 三段；少一段说明不是 JWT
    parts.next()?;
    if payload.is_empty() {
        return None;
    }

    let bytes = base64url_decode(payload)?;
    let v: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    v.get("exp")?.as_i64()
}

/// base64url 解码（JWT 用的是**无填充** base64url）
///
/// 手写而不是引入 `base64` crate：这里只需要解 40 来个字节，
/// 而实现只有 20 行、已被 3 个单测锁住（无填充 / 带填充 / url-safe / 非法字符）。
/// 加依赖不减代码量也不降出错面 —— 按「加了有没有用」的标准，不值得。
///
/// 同时接受 `+` `/`（标准 base64）—— 有些站点发的 token 并不严格是 url-safe。
fn base64url_decode(s: &str) -> Option<Vec<u8>> {
    fn val(c: u8) -> Option<u32> {
        match c {
            b'A'..=b'Z' => Some((c - b'A') as u32),
            b'a'..=b'z' => Some((c - b'a') as u32 + 26),
            b'0'..=b'9' => Some((c - b'0') as u32 + 52),
            b'-' | b'+' => Some(62),
            b'_' | b'/' => Some(63),
            _ => None,
        }
    }

    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let mut acc: u32 = 0;
    let mut bits: u32 = 0;
    for &c in s.as_bytes() {
        // 无填充编码，但兼容带 `=` 的写法
        if c == b'=' {
            break;
        }
        let v = val(c)?;
        acc = (acc << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Some(out)
}

/// 用户数据条目（观看历史 / 收藏 / 进度）
///
/// 注意：**平台自带历史 = 备份平面（单向镜像）；我们自己的收藏与进度 = 独立平面（双向同步）**。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserRecord {
    /// `"{provider}:{kind}:{native_id}"`
    pub key: String,
    pub provider: String,
    /// history | favorite | progress
    pub kind: String,
    pub native_id: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover: Option<String>,
    /// 播放进度（秒）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub position: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration: Option<u64>,
    /// 平台特有字段（如 cycani 的 category: want/watching/watched）
    #[serde(default, skip_serializing_if = "serde_json::Map::is_empty")]
    pub payload: serde_json::Map<String, serde_json::Value>,
    /// ★ 毫秒时间戳，冲突解决（LWW）依据
    pub updated_at: i64,
    /// ★ 墓碑标记 —— 删除不真删，否则会被其他设备的旧数据复活
    #[serde(default)]
    pub deleted: bool,
}

// ─────────────────────────── 核心 Trait ───────────────────────────

/// 媒体 Provider 契约
///
/// **实现者注意**：
/// - 所有方法默认返回 `Unsupported`，按能力位选择性实现
/// - 不要 panic，一律返回 `Result`
/// - 网络请求应有超时（建议 20s）
#[async_trait]
pub trait MediaProvider: Send + Sync {
    /// 身份与能力声明
    fn manifest(&self) -> &ProviderManifest;

    // ── 内容发现 ────────────────────────────────────────────

    /// 首页分区（横向滚动区块）
    async fn home(&self) -> Result<Vec<Section>> {
        Ok(vec![])
    }

    /// 分类列表
    async fn categories(&self) -> Result<Vec<Category>> {
        Ok(vec![])
    }

    /// 分类内容列表（分页）
    async fn list(&self, _req: ListRequest) -> Result<Page<MediaItem>> {
        Err(ProviderError::unsupported("该源不支持分类列表"))
    }

    /// 详情（含多播放源与剧集）
    async fn detail(&self, _id: &MediaId) -> Result<MediaDetail> {
        Err(ProviderError::unsupported("该源不支持详情"))
    }

    /// 搜索
    async fn search(&self, _keyword: &str, _page: u32) -> Result<Page<MediaItem>> {
        Err(ProviderError::unsupported("该源不支持搜索"))
    }

    /// ★ 榜单内容（对应 `SectionSource::Rank`）
    ///
    /// 为什么单独一个方法而不是复用 `list`：
    /// 榜单是**独立资源**（有自己的 id 与分页），跟「分类」的维度不同 ——
    /// cycani 的 `/ranks/{id}/videos` 与 `/videos?zone_id=` 就是两条不同的接口。
    ///
    /// 默认不支持：只有声明了 `SectionSource::Rank` 区块的源才需要实现，
    /// 否则它的首页会出现「永远空白」的区块（本项目踩过这个坑）。
    async fn rank(&self, _rank_id: &str, _page: u32) -> Result<Page<MediaItem>> {
        Err(ProviderError::unsupported("该源不支持榜单"))
    }

    // ── 播放源（多源换源，支持嵌套）────────────────────────────

    /// 列出可用播放源。
    ///
    /// 默认实现从 `detail()` 提取，Provider 可覆写以支持按需拉取。
    async fn sources(&self, id: &MediaId) -> Result<Vec<PlaySource>> {
        Ok(self.detail(id).await?.sources)
    }

    /// 按播放源拉取剧集
    async fn episodes(&self, id: &MediaId, _source_code: &str) -> Result<Vec<Episode>> {
        Ok(self.detail(id).await?.episodes)
    }

    // ── 取流 ───────────────────────────────────────────────

    /// 解析播放地址。返回**候选列表**（多清晰度/多线路），由 UI 或解析链择优。
    async fn resolve(&self, id: &MediaId, req: &PlayRequest) -> Result<Vec<StreamCandidate>>;

    // ── 直播 ───────────────────────────────────────────────

    async fn live_channels(&self) -> Result<Vec<LiveChannel>> {
        Err(ProviderError::unsupported("该源不支持直播"))
    }

    /// 直播取流
    async fn live_stream(&self, _channel_id: &str) -> Result<Vec<StreamCandidate>> {
        Err(ProviderError::unsupported("该源不支持直播"))
    }

    /// 节目单
    async fn epg(&self, _channel_id: &str, _day: Option<&str>) -> Result<Vec<EpgEntry>> {
        Err(ProviderError::unsupported("该源不支持节目单"))
    }

    /// 时移回看
    async fn timeshift(
        &self,
        _channel_id: &str,
        _start: i64,
        _end: i64,
    ) -> Result<StreamCandidate> {
        Err(ProviderError::unsupported("该源不支持时移回看"))
    }

    // ── 登录（可选）─────────────────────────────────────────

    async fn login(&self, _cred: Credentials) -> Result<Session> {
        Err(ProviderError::unsupported("该源无需登录"))
    }

    async fn logout(&self) -> Result<()> {
        Ok(())
    }

    /// 当前会话（未登录返回 `None`）
    async fn session(&self) -> Result<Option<Session>> {
        Ok(None)
    }

    // ── 扫码登录（可选；2026-09-21）─────────────────────────────
    //
    // 默认「不支持」—— 只有实现了它的源才会在登录弹窗里出现「扫码」入口。
    // 这与 `has_method("qrLoginStart")` 配合，让宿主能区分
    // 「这个源不支持扫码」与「扫码这一步失败了」。

    /// ★ 申请一个登录二维码
    ///
    /// 返回的 `url` 由**宿主**画成二维码（插件不画，见 [`QrLoginStart`]）。
    async fn qr_login_start(&self) -> Result<QrLoginStart> {
        Err(ProviderError::unsupported("该源不支持扫码登录"))
    }

    /// ★ 轮询扫码状态
    ///
    /// ⚠️ 宿主会以约 2 秒的间隔调用它，直到拿到
    ///    `Confirmed` / `Expired` / `Failed` 为止。
    ///    插件实现**不应该**自己在内部 sleep —— 那会占住 QuickJS 线程。
    async fn qr_login_poll(&self, _key: &str) -> Result<QrLoginPoll> {
        Err(ProviderError::unsupported("该源不支持扫码登录"))
    }

    // ── ★ 会话生命周期（通用能力，新源只需覆写这几个方法）──────────
    //
    // 设计目标：**「token 会不会过期、过期了怎么续」不该是每个源各写一遍**。
    // 宿主（Registry / 命令层）只依赖下面这套契约，具体站点用哪种续期机制
    // （refresh_token、sliding expiration、重新登录…）由各源自己决定。
    //
    // 典型调用方是 `Registry::ensure_session()`：
    //   需要登录 → 快过期？→ refresh_session() → 还不行？→ auto_login()
    //
    // 默认实现面向「不需要登录」的源（如央视），它们天然满足，无需覆写。

    /// ★ 会话是否**需要**续期
    ///
    /// 默认策略：有会话且能算出到期时间，且距今不足安全窗口 → 需要。
    /// 没有到期信息时视为长期有效（`None`），**不主动刷** ——
    /// 盲目刷新会让不支持该接口的源每次都多打一次网络请求。
    ///
    /// ⚠️ 到期时间走 [`Session::effective_expires_at`]：`expires_at` 缺失时
    ///    会从 JWT 的 `exp` 兜底。以前这里直接读 `expires_at`，插件不返回
    ///    该字段时恒为 `false` → 已死的 token 被当成「无需续期」→
    ///    界面显示「已登录」但一点就 unauthorized（2026-09-24 用户报的 bug）。
    ///
    /// ⚠️ 本方法把「**已经过期**」和「**即将过期**」都算 `true`（都要续期）。
    ///    要区分二者请用 [`Session::is_expired_at`]，`Registry::session_state`
    ///    就是靠它把「已失效」和「即将过期」分开的。
    ///
    /// 各源可覆写：有的站点返回的是「有效期秒数」而非绝对时间戳，
    /// 有的需要在到期前更早刷新（例如 30 分钟）。
    async fn session_needs_refresh(&self) -> bool {
        match self.session().await {
            Ok(Some(s)) => match s.effective_expires_at() {
                Some(exp) => {
                    let now = chrono::Utc::now().timestamp();
                    exp - now < DEFAULT_REFRESH_WINDOW_SECS
                }
                None => false,
            },
            _ => false,
        }
    }

    /// ★ 会话是否**已经过期**（不是「即将过期」）
    ///
    /// # 为什么单独开一个方法（2026-09-24 用户报的 bug）
    ///
    /// `session_needs_refresh()` 对「已过期」和「即将过期」都返回 `true` ——
    /// 这对**续期决策**是对的（两种情况都该刷），但对**界面展示**是灾难：
    /// `Registry::session_state` 只能据此报 `Expiring`，而 UI 把 `Expiring`
    /// 渲染成「已登录 · 无需操作」。于是 token 明明已经死了 11 个小时，
    /// 界面却笃定地说「已登录」，用户一点播就 `unauthorized`。
    ///
    /// 这就是用户报的「显示已登录，但实际不能播」。
    ///
    /// 默认实现看 [`Session::is_expired_at`]（`expires_at`，缺失则 JWT `exp` 兜底）。
    /// 各源若有自己的判据（如服务端返回的 `expired` 标志）可覆写。
    async fn session_expired(&self) -> bool {
        match self.session().await {
            Ok(Some(s)) => s.is_expired_at(chrono::Utc::now().timestamp()),
            // 无会话不算「已过期」—— 那是「未登录」，由 session_state 另判
            _ => false,
        }
    }

    /// ★ 用**现有凭据**续期（如 `POST /auth/refresh`）
    ///
    /// 返回：
    /// - `Ok(Some(session))` —— 续期成功，新会话（宿主会负责持久化）
    /// - `Ok(None)` —— 该源不支持续期（宿主会转而尝试自动登录）
    /// - `Err(..)` —— 续期失败（宿主同样会转自动登录）
    ///
    /// 默认不支持。
    async fn refresh_session(&self) -> Result<Option<Session>> {
        Ok(None)
    }

    /// ★ 是否具备自动登录条件（凭据已保存）
    ///
    /// 宿主据此决定「续期失败后要不要试着重新登录」。
    /// 默认没有凭据。
    async fn can_auto_login(&self) -> bool {
        false
    }

    /// ★ 用**已保存的凭据**自动登录
    ///
    /// ⚠️ 只在「无需人工交互」时才能成功。遇到验证码 / 二次验证 / 风控时
    /// **必须明确报错**（错误信息要让用户知道该去设置页人工登录），
    /// **绝不要尝试绕过验证码** —— 那是站点明确要求人工介入的信号。
    ///
    /// 返回 `Ok(None)` 表示该源不支持自动登录。
    async fn auto_login(&self) -> Result<Option<Session>> {
        Ok(None)
    }

    /// ★ 把凭据存起来供自动登录用（**必须走系统钥匙串，不落明文**）
    ///
    /// 默认不做任何事：不需要登录的源没有凭据。
    async fn remember_credentials(&self, _cred: &Credentials) -> Result<()> {
        Ok(())
    }

    /// ★ 彻底忘记已保存的凭据（登出且不再自动登录）
    ///
    /// 与 `logout()` 的区别（这个区分对用户体验很重要）：
    /// · `logout()`   —— 只清 token，**保留凭据**，下次仍能自动重登。
    ///   多数人点「登出」只是想换个账号试试。
    /// · 本方法 —— 连凭据一起清掉，此后必须手动输入账号密码。
    ///
    /// 默认不支持：由各源自己实现（插件版存在插件私有存储里）。
    async fn forget_credentials(&self) -> Result<()> {
        Err(ProviderError::unsupported("该源不支持凭据管理"))
    }

    /// ★ 该源是否实现了某个可选方法
    ///
    /// **为什么需要这个**：宿主在分派可选能力（如清理凭据）时，
    /// 要知道「该走插件路径还是内置回退路径」。
    /// 直接调用再吞掉「未实现」的错误也能work，但那样
    /// **真的出错**与**没实现**就分不清了，排查时很痛苦。
    ///
    /// 默认 `false`（trait 的默认实现都算「没实现」）。
    async fn has_method(&self, _name: &str) -> bool {
        false
    }

    /// ★ 会话是否「可用」—— 供 UI 决定要不要在首页展示该源
    ///
    /// 语义：需要登录的源在会话**彻底失效**时返回 false（首页不展示它的内容，
    /// 因为点了也播不了）；不需要登录的源恒为 true。
    ///
    /// ⚠️ 「无会话」不等于「不可用」：**只要还能自动登录**就仍算可用 ——
    /// 用户首次点播时宿主会自动恢复会话。这一点必须与
    /// `Registry::session_state` 保持一致（那里把这种情况判为 `Expiring`
    /// 而非 `Expired`），否则会出现「首页把它藏了，但设置页说它还能自动恢复」的矛盾。
    ///
    /// ★★★ 2026-09-24：「会话已过期但无凭据」**故意仍返回 true**
    ///
    /// 按上面「彻底失效就不展示」的字面意思，这种情况该返回 false。
    /// 但那样会把源从首页**整个藏掉**，用户连点进去的入口都没有 ——
    /// 而本轮刚给播放失败页加了「登录」按钮（用户明确要求），
    /// 「点进去 → 看到登录按钮 → 就地登录 → 重试」才是我们要的恢复路径。
    /// 藏掉它等于把用户唯一能自救的入口也拿掉了。
    ///
    /// 所以这里的判据是「**有没有可能被用户救活**」而不是「现在能不能播」：
    /// ```text
    /// 有会话（哪怕已过期）→ true   （失败页会给出登录按钮）
    /// 无会话但能自动登录   → true   （宿主点播时自动恢复）
    /// 无会话且无凭据       → false  （首页展示也没意义）
    /// ```
    /// ⚠️ 本方法**只做首页过滤，不向用户展示任何状态文案** ——
    ///    真正告诉用户「登录已失效」的是 `Registry::session_state`，
    ///    两者职责不同，不要混淆。
    async fn session_usable(&self) -> bool {
        if !self.manifest().capabilities.login_required {
            return true;
        }
        match self.session().await {
            // 有过期与否都算「可救」：失败页的登录按钮就是补救入口
            Ok(Some(_)) => true,
            // 无会话 / 读取出错 → 看有没有凭据能自救
            _ => self.can_auto_login().await,
        }
    }

    // ── 平台自带历史（备份平面，只读镜像）──────────────────────

    /// 拉取平台历史的**快照**，用于备份。
    ///
    /// ⚠️ 注意边界：这是**只读镜像**，我们只备份不回写（已由 Owner 确认）。
    async fn platform_history(&self) -> Result<Vec<UserRecord>> {
        Ok(vec![])
    }

    // ── 健康检查 ────────────────────────────────────────────

    /// 探测是否可用（用于自愈与"站点失效"提示）
    async fn health_check(&self) -> bool {
        true
    }
}

/// 默认的续期安全窗口（秒）
///
/// 为什么是 5 分钟：太小（如 30 秒）会在长视频播放中途才刷新，
/// 一旦网络抖动就可能续期失败导致中断；太大（如 1 小时）会让
/// 每次启动都白刷一次。5 分钟是「足够提前、又不浪费」的折中。
pub const DEFAULT_REFRESH_WINDOW_SECS: i64 = 300;

/// 会话状态（供 UI 展示，见 `Registry::session_state`）
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionState {
    /// 该源不需要登录
    NotRequired,
    /// 已登录且可用
    Active,
    /// 已登录但即将过期（宿主会尝试自动续期）
    Expiring,
    /// 登录已失效，且无法自动恢复 —— **需要用户去设置页人工登录**
    Expired,
}

// ─────────────────────────── 扫码登录（2026-09-21）───────────────────────────
//
// # 为什么做成**通用契约**而不是「B站专用」
//
// 扫码登录不是 B站 独有的（B站 / 优酷 / 腾讯视频 / 网易云…都是这套）：
// ```text
// ① 申请二维码  → 拿到 { key, url }
// ② 把 url 画成二维码给用户扫
// ③ 轮询 key    → 未扫 / 已扫待确认 / 确认成功 / 已失效
// ④ 成功时凭据通常在 Set-Cookie 头里（不在 body）
// ```
// 各站差别只在**状态码的数值**与**取凭据的方式**，而那些属于站点知识 ——
// 按本项目的架构（宿主不含站点逻辑），**全部留在插件里**：
//
// ```text
// 插件 qrLoginStart()          → { key, url }     插件知道去哪个域名申请
// 插件 qrLoginPoll(key)        → { status, ... }  插件知道 86101 是什么意思
// 宿主                          → 只负责把 url 画成 SVG、把状态转给界面
// ```
//
// ⚠️ **二维码 SVG 由宿主画**（不是插件）：QuickJS 里没有 canvas，
//    而宿主已经有 `qrcode` 依赖（局域网遥控的二维码就在用）。
//    插件只交出 url 字符串。

/// 扫码登录：一次「申请二维码」的结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QrLoginStart {
    /// 轮询用的凭据（各站叫法不同：qrcode_key / uuid / ticket）
    pub key: String,
    /// 二维码里要编码的地址（用户扫的就是它）
    pub url: String,
    /// **由宿主渲染**的二维码 SVG（插件不提供）
    #[serde(default)]
    pub svg: String,
    /// 提示语（插件可给，如"请用 B站 App 扫码"）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hint: Option<String>,
}

/// 扫码登录：轮询到的状态
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum QrLoginStatus {
    /// 还没人扫
    Pending,
    /// 已扫码，等用户在手机上点「确认」
    Scanned,
    /// 确认成功（此时 `session` 必定有值）
    Confirmed,
    /// 二维码过期，要重新申请一个
    Expired,
    /// 出错（`message` 里有原因）
    Failed,
}

/// 扫码登录：一次「轮询」的结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QrLoginPoll {
    pub status: QrLoginStatus,
    /// 给用户看的一句话（直接用站点返回的 message 或宿主补的说明）
    #[serde(default)]
    pub message: String,
    /// 仅在 `status == Confirmed` 时有值
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<Session>,
}


// ─────────────────────────── 辅助类型 ───────────────────────────

/// 带能力的 Provider 句柄（Registry 中存放）
pub struct ProviderHandle {
    pub provider: std::sync::Arc<dyn MediaProvider>,
    /// 优先级（数字小的优先；用于跨平台聚合时排序）
    pub priority: i32,
    /// 是否启用
    pub enabled: bool,
}

impl ProviderHandle {
    pub fn new(provider: std::sync::Arc<dyn MediaProvider>) -> Self {
        Self {
            provider,
            priority: 100,
            enabled: true,
        }
    }
}

// ─────────────────────────── 会话过期判定（2026-09-24）───────────────────────────
//
// # 这组测试为什么存在
//
// 用户报「次元城明明已登录了，也提示未登录」+「显示已登录但实际不能播」。
// 实测根因：token 真的过期了，但 `expires_at` 缺失时旧逻辑一律当「永不过期」，
// 于是 `session_state` 报 `Expiring`，UI 渲染成「已登录 · 无需操作」。
//
// ⚠️ 下面用**用户真实那条 token 的形状**做夹具（值已改写，但格式一致）：
//    `Bearer` 前缀 + JWT + `exp` 声明。别把它简化成假字符串 ——
//    「带 Bearer 前缀」和「payload 段」正是解析要处理的两个坑。
#[cfg(test)]
mod session_expiry_tests {
    use super::*;

    /// 造一个带 `exp` 的 JWT（签名段是假的，本模块**刻意不校验签名**）
    fn jwt_with_exp(exp: i64) -> String {
        let header = base64url_encode(br#"{"alg":"HS256","typ":"JWT"}"#);
        let payload = base64url_encode(format!(r#"{{"user_id":1087439,"exp":{exp}}}"#).as_bytes());
        format!("{header}.{payload}.UkjuM_0SjX9HdaNuQMTCYE9JRlN6k0nA1S3GTOGn1us")
    }

    /// 测试专用编码器（生产代码只需要解码）
    fn base64url_encode(b: &[u8]) -> String {
        const T: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        let mut out = String::new();
        for c in b.chunks(3) {
            let n = (c[0] as u32) << 16
                | (*c.get(1).unwrap_or(&0) as u32) << 8
                | (*c.get(2).unwrap_or(&0) as u32);
            out.push(T[(n >> 18) as usize & 63] as char);
            out.push(T[(n >> 12) as usize & 63] as char);
            if c.len() > 1 {
                out.push(T[(n >> 6) as usize & 63] as char);
            }
            if c.len() > 2 {
                out.push(T[n as usize & 63] as char);
            }
        }
        out
    }

    fn session(token: String, expires_at: Option<i64>) -> Session {
        Session {
            token,
            expires_at,
            display_name: Some("wish".into()),
            avatar: None,
        }
    }

    // ── ① expires_at 有值：以它为准，不该去看 JWT ──

    #[test]
    fn explicit_expires_at_wins_over_jwt() {
        // JWT 说 9999 年过期，但 expires_at 说明天就过期 → 必须信 expires_at
        let s = session(format!("Bearer {}", jwt_with_exp(253402300799)), Some(1000));
        assert_eq!(s.effective_expires_at(), Some(1000));
        assert!(s.is_expired_at(2000), "显式 expires_at 已过 → 必须判过期");
    }

    // ── ② ★ 核心：expires_at 缺失时从 JWT exp 兜底 ──

    #[test]
    fn falls_back_to_jwt_exp_when_expires_at_missing() {
        let s = session(format!("Bearer {}", jwt_with_exp(1790165942)), None);
        assert_eq!(
            s.effective_expires_at(),
            Some(1790165942),
            "expires_at 缺失时必须能从 JWT 的 exp 兜底 —— 这是用户报的 bug 的修复点"
        );
        // 用户实测场景：现在 1790208102，exp 1790165942 → 已过期
        assert!(s.is_expired_at(1790208102), "exp 已过 → 必须判过期");
        assert!(!s.is_expired_at(1790165941), "exp 还没到 → 不该判过期");
    }

    #[test]
    fn bearer_prefix_is_stripped() {
        let bare = jwt_with_exp(1790165942);
        let with_prefix = format!("Bearer {bare}");
        assert_eq!(
            session(bare, None).effective_expires_at(),
            session(with_prefix, None).effective_expires_at(),
            "`Bearer ` 前缀不该影响 exp 解析（cycani 存的就是带前缀的 token）"
        );
    }

    // ── ③ ★★ 反向：解不出 exp 时**绝不能**判过期 ──
    //
    // 这是编排者明确提醒的坑：把正常的 opaque token 源误报成「登录已失效」，
    // 比原来的 bug 更糟 —— 用户会去重新登录一个本来好用的源。

    #[test]
    fn opaque_token_is_not_treated_as_expired() {
        // 不是 JWT（没有点分段）
        let s = session("Bearer 8f3a1c9e7b2d4f6a0e5c8b1d3a7f9e2c".into(), None);
        assert_eq!(s.effective_expires_at(), None, "非 JWT 不该解出到期时间");
        assert!(
            !s.is_expired_at(1790208102),
            "★ 解不出 exp 时必须是『不过期』—— 不能把正常源误报成失效"
        );
    }

    #[test]
    fn jwt_without_exp_is_not_treated_as_expired() {
        let header = base64url_encode(br#"{"alg":"HS256"}"#);
        let payload = base64url_encode(br#"{"user_id":1087439}"#); // 没有 exp
        let s = session(format!("Bearer {header}.{payload}.sig"), None);
        assert_eq!(s.effective_expires_at(), None, "没有 exp 声明 → 无从判断");
        assert!(!s.is_expired_at(1790208102), "没有 exp 时不该判过期");
    }

    #[test]
    fn malformed_jwt_is_not_treated_as_expired() {
        for bad in [
            "Bearer only.two",                    // 段数不够
            "Bearer ...",                         // 空 payload
            "Bearer aaa.!!!not-base64!!!.ccc",    // payload 不是 base64
            "Bearer aaa.eyJub3QiOiJqc29u.wrong",  // payload 解出来不是 JSON
            "",                                   // 空 token
        ] {
            let s = session(bad.into(), None);
            assert_eq!(s.effective_expires_at(), None, "畸形 token 应返回 None: {bad:?}");
            assert!(!s.is_expired_at(1790208102), "畸形 token 不该判过期: {bad:?}");
        }
    }

    // ── ④ 边界：正好到期那一刻算过期 ──

    #[test]
    fn expiry_boundary_is_inclusive() {
        let s = session(jwt_with_exp(1000), None);
        assert!(!s.is_expired_at(999), "还没到");
        assert!(s.is_expired_at(1000), "正好到点 → 算过期（<= 而非 <）");
        assert!(s.is_expired_at(1001), "已过");
    }

    #[test]
    fn base64url_decodes_unpadded_and_padded() {
        // 无填充（JWT 标准写法）与带填充都要能解
        assert_eq!(base64url_decode("eyJhIjoxfQ").unwrap(), br#"{"a":1}"#);
        assert_eq!(base64url_decode("eyJhIjoxfQ==").unwrap(), br#"{"a":1}"#);
        // url-safe 的 `-`/`_` 与标准 `+`/`/` 都接受
        assert!(base64url_decode("-_").is_some());
        assert!(base64url_decode("+/").is_some());
        assert!(base64url_decode("!!!").is_none(), "非法字符应返回 None");
    }
}
