//! 局域网遥控 —— 手机浏览器遥控正在播放的客户端 / TV
//!
//! # 为什么做这个
//!
//! Owner 提的需求：TV 或客户端上播着视频，想用手机**快速操作**
//! 「下一集 / 搜索 / 换个视频看」。TV 遥控器打字搜索非常痛苦，
//! 而手机就在手边。
//!
//! 做法：客户端在局域网里起一个 HTTP 服务，手机浏览器打开即用 ——
//! **不用装 App**，扫码或输网址就能连。
//!
//! # 架构
//!
//! ```text
//! 手机浏览器 ──HTTP──> 本模块（axum 服务）
//!                        │
//!                        ├── /api/state   ← 播放器上报的当前状态（内存）
//!                        ├── /api/cmd     → 命令队列（前端轮询取走并执行）
//!                        └── /            → 内置遥控页面（单文件 HTML）
//! ```
//!
//! **为什么用「前端轮询命令队列」而不是 WebSocket / SSE**：
//!   · 播放器状态在前端 Vue 里，Rust 拿不到 —— 必须由前端上报
//!   · 命令要前端执行（换集、切源、跳转都在 Vue 的播放器里）
//!   · 轮询 800ms 一次，延迟对「遥控」这个场景完全够（人按按钮的感知阈值）
//!   · 换来的是**没有长连接**：断线、重连、僵尸连接这些麻烦都不存在
//!
//! # 安全边界（重要）
//!
//! · **只监听局域网网卡**（不做 0.0.0.0 公网暴露）
//! · **必须带配对码**才能操作（防止同网段的其他人乱控）
//! · 配对码每次启动随机生成，显示在客户端界面上
//! · 不提供任何「读取本地文件 / 执行命令」的接口 ——
//!   命令是**白名单枚举**，不是任意字符串

use std::collections::VecDeque;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

pub mod server;

/// 遥控服务默认端口
///
/// 选 8642 而不是 8080/3000：那些太常见，容易和开发服务器撞。
pub const DEFAULT_PORT: u16 = 8642;

/// 命令队列上限
///
/// 手机连点或前端卡住时，队列不能无限涨（会吃内存）。
/// 超了丢最旧的 —— 遥控命令是「越新越有意义」的。
const MAX_QUEUE: usize = 32;

// ─────────────────────────── 数据模型 ───────────────────────────

/// 手机可以发来的命令（**白名单枚举**）
///
/// ⚠️ 刻意做成枚举而不是自由字符串：
/// 前端执行时是 `match` 分发，**未知命令直接丢弃**。
/// 若做成 `{action: String}` 再动态分发，等于把前端的控制权
/// 开放给任何能访问这个端口的人。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum RemoteCommand {
    /// 播放 / 暂停切换
    TogglePlay,
    /// 上一集
    PrevEpisode,
    /// 下一集
    NextEpisode,
    /// 跳到第 N 集（1 基）
    GotoEpisode { order: u32 },
    /// 快退 / 快进（秒，可为负）
    Seek { delta: i64 },
    /// 跳到指定进度（秒）
    SeekTo { position: i64 },
    /// 切换播放源（线路）
    SwitchSource { code: String },

    /*
     * ══════════════════════════════════════════════════════════════
     * ★★ 内容源排序（遥控端）
     * ══════════════════════════════════════════════════════════════
     *
     * # 为什么要有这条命令（Owner 明确要求）
     *
     * 用户原话：「内容源调整顺序也要支持可拖动排序……**也可以通过
     * 遥控面板来排序**」。
     *
     * ⚠️ **原版没有这条命令** —— 原版 `RemoteCommand` 的 12 个变体
     *    （TogglePlay / PrevEpisode / … / SkipToggleAuto）里没有任何排序。
     *    这是 Owner 拍板「原版没有也要加」之后**新增的协议**。
     *
     * # 为什么是「相对移动一格」而不是「下发完整顺序」
     *
     * 手机端看到的源列表是**上一次轮询的快照**，可能已经过期
     * （用户刚在客户端装/删了一个源）。如果下发完整顺序：
     * ```text
     * 手机端快照 [A, B, C]   客户端实际 [A, B, C, D]
     * 用户把 B 上移 → 手机发 [B, A, C]
     * 客户端照单全收 → D **被静默丢掉**（用户没删它）
     * ```
     * 发「把 B 上移一格」则天然安全：客户端拿**自己**当前的顺序换位，
     * 手机端只需要知道 `id` 与方向 —— 快照过期最多是「点了个不存在的源」，
     * 那是个无害的 no-op，而不是丢数据。
     */
    /// 上移 / 下移某个内容源（遥控端排序）
    ///
    /// # 边界由**执行方**处理（照 `PrevEpisode` 的做法）
    ///
    /// 本模块**不校验** `delta` 的取值，也不校验 `id` 是否存在 ——
    /// 这与 `PrevEpisode` 完全一致：它在第一集时也只是被前端
    /// 「拿到 `prevEpisode` 为空 → 什么都不做」，协议层不报错。
    ///
    /// 理由：Rust 侧**看不到**源列表的当前顺序（那是前端的
    /// `registry` / `get_provider_order`），在这里判越界只能靠猜。
    /// 硬要判就会变成「客户端说越界、手机端说没越界」的双份真相。
    ///
    /// 所以：
    /// ```text
    /// delta < 0  → 上移（在第一项时 = 无操作，前端静默忽略）
    /// delta > 0  → 下移（在最后一项时 = 无操作）
    /// delta == 0 → 无操作
    /// id 不存在   → 无操作 + **如实记日志**（不 panic、不报错）
    /// ```
    MoveProvider {
        /// 要移动的内容源 id（如 `cycani`）
        id: String,
        /// `-1` 上移一格，`+1` 下移一格
        ///
        /// 用 `i32` 而不是枚举：与 `Seek { delta: i64 }` 同一风格，
        /// 且将来若要做「移到顶部」可以复用同一个字段（传一个大负数）。
        delta: i32,
    },

    /// 直接播放某个视频（手机端搜索结果点进来的场景）
    ///
    /// `title` 是**可选**的：手机端搜索结果里本来就带标题，
    /// 传过来能让播放页立刻显示，而不是先空一下再补。
    /// 省略时（老版本手机端）播放页会自己去取详情，不影响功能。
    PlayItem {
        provider: String,
        id: String,
        #[serde(default)]
        title: Option<String>,
    },
    /// 音量（0~100）
    SetVolume { value: u8 },
    /// 静音切换
    ToggleMute,

    /*
     * ══════════════════════════════════════════════════════════════
     * ★★ 直播切频道（2026-09-25 新增，用户要求）
     * ══════════════════════════════════════════════════════════════
     *
     * 用户原话：
     * > 在直播页面  应该可以往下循环切换直播，并且可以在遥控上控制
     *
     * # ★★★ 为什么**不复用** `NextEpisode` / `PrevEpisode`
     *
     * ```text
     * ① **前端语义不同**
     *    NextEpisode 绑的是播放器的 `_episodes`（`List<Episode>`）——
     *    那是**点播剧集**的概念（有集号、有标题、有播放进度）。
     *    直播页**没有** `_episodes`，它有的是频道列表。
     * ② **复用会污染一个纯点播概念**
     *    `_PlayerPageState._gotoNextEpisode()` 就得被迫理解
     *    "我现在到底是剧集还是直播频道" ⇒ 双语义判据
     *    （这正是「别把两件事塞进一个判据」要避免的）
     * ③ ★ **边界语义相反**
     *    NextEpisode 在最后一集：**什么都不做**（`_nextEpisode == null`）
     *    NextChannel 在最后一个频道：**回到第一个**（用户明确说"循环"）
     *    ⇒ 同一条命令要两种边界行为，只能靠"再传一个 flag"，更乱
     * ```
     *
     * # 边界由**执行方**处理（照 `PrevEpisode` 的既有做法）
     *
     * 本模块**不校验**当前是不是最后一个频道 —— Rust 侧看不到前端的
     * 频道列表（那是 `get_live_channels` 的运行时结果）。
     * 在这里判越界只能靠猜，会变成"客户端说循环了、手机说没有"的双份真相。
     * ⇒ 协议层只表达意图，**循环语义由直播页实现**。
     *
     * # 与 `GotoEpisode { order }` 的关系
     *
     * 直播也想要"跳到第 N 个频道" ⇒ 复用 `GotoEpisode`？
     * ★ **不复用**：`order` 是**1 基集号**，直播里是**频道序号**，
     *   语义不同（且频道的"序号"会随列表变化而漂移，集号相对稳定）。
     *   将来若真需要，再加 `GotoChannel { order }`。
     */
    /// 下一个直播频道（**循环**：最后一个之后回到第一个）
    NextChannel,
    /// 上一个直播频道（**循环**：第一个之前回到最后一个）
    PrevChannel,
    /// 跳到指定直播频道（按 `id`）
    ///
    /// 与 `GotoChannel { order }`（按序号）分开：频道 id 是稳定的，
    /// 序号会随列表刷新漂移 —— 手机端的频道列表是快照，用 id 才不会跳错台。
    GotoChannel { id: String },

    // ── 播放设置（遥控端能做的都在这儿）──

    /// 设置播放倍速（1.0 / 1.25 / 1.5 / 2.0 …）
    ///
    /// ⚠️ 用 `f32` 而不是整数倍：媒体内核接受 1.25 这类倍率，
    /// 取整会把用户能选的档位砍掉一半。
    SetSpeed { value: f32 },
    /// 弹幕开关（开 = 取弹幕并叠层，关 = 清空）
    ToggleDanmaku,
    /// 全屏切换（客户端侧切，不是手机自己的全屏）
    ToggleFullscreen,
    /// 选清晰度 / 线路（`index` 是候选列表的下标，0 基）
    ///
    /// ⚠️ 发下标而不是 url —— url 可能有几百字符，
    /// 而且里面常带一次性签名，下标更短也更稳定。
    SetQuality { index: i64 },

    // ── 查询类（前端执行后把结果回填到 hub，手机端再取）──
    //
    // 为什么查询也走命令队列：搜索/首页内容只有前端拿得到
    // （它要调 Provider 并处理缓存）。与其在 Rust 侧再实现一遍，
    // 不如让前端顺手做了 —— **一套通道，两种用途**。
    /// 请前端执行搜索
    QuerySearch { keyword: String },
    /// 请前端刷新首页
    QueryHome,

    /*
     * ══════════════════════════════════════════════════════════════
     * ★★ 片头 / 片尾（Owner 要求「遥控端也要能配置 + 能取消」）
     * ══════════════════════════════════════════════════════════════
     *
     * 命令名与语义对齐 `docs/片头片尾设置草稿.html` §三。
     *
     * ⚠️ 为什么这些命令必须存在（而不是"让用户在电脑上设"）：
     *    草稿的场景是「人在客厅看电视」—— 电脑可能不在手边，
     *    手机才是他手上的设备。没有这些命令，
     *    遥控端就只能看不能配，等于功能残缺。
     */
    /// 让客户端打开片头片尾设置弹窗
    SkipConfigOpen { target: SkipKind },
    /// 让客户端跳到某秒（手机微调时用）
    SkipPreview { position: i64 },
    /// 锁定「片头/片尾」为当前预览位置
    SkipConfirm { target: SkipKind },
    /// 清除本剧的跳过设置
    SkipClear,
    /// 开关「自动跳过」
    SkipToggleAuto { on: bool },
}

/// 片头 / 片尾（遥控命令与状态回传共用）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SkipKind {
    Intro,
    Outro,
}

/// 一个内容源在手机端排序面板里的样子
///
/// # 为什么用结构体而不是像 `sources` / `episodes` 那样用元组
///
/// `sources: Vec<(String, String)>` 是 `(code, 名称)`，两个字段都是
/// 字符串，看代码能猜出来。而这里要带一个 `bool` ——
/// `("cycani", "次元城", true)` 里那个 `true` 是什么？
/// 看的人（和写 Dart 的人）都猜不到，只能回来翻 Rust 定义。
///
/// 排序面板是**手机上要显示完整名字**的界面，字段名值得多这几行。
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct ProviderEntry {
    /// 内容源 id（排序命令里传的就是它）
    pub id: String,
    /// 显示名称（手机端直接渲染，不查表）
    pub name: String,
    /// 是否启用
    ///
    /// ⚠️ **停用的源也在列表里** —— 与设置页的排序面板一致：
    ///    停用只是「首页不显示它」，位置仍然保留着（用户可能只是
    ///    临时关掉）。手机端把它渲染成暗色即可，**不参与过滤**，
    ///    否则用户会看到"手机上少了一个源"而对不上号。
    #[serde(default = "default_enabled")]
    pub enabled: bool,
}

/// `enabled` 的缺省值 —— 缺省即启用
///
/// 不能直接用 `Default::default()`（那是 `false`）：老版本手机端
/// 或精简过的上报里不带这个字段时，把源全画成"停用"是明显的错。
fn default_enabled() -> bool {
    true
}

/// 播放器上报的状态（手机端据此渲染界面）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RemoteState {
    /// 是否正在播放
    pub playing: bool,
    /// 当前视频标题
    pub title: String,
    /// 当前是第几集（1 基；非剧集为 0）
    pub episode_order: u32,
    /// 总集数（非剧集为 0）
    pub episode_count: u32,
    /// 当前进度（秒）
    pub position: i64,
    /// 总时长（秒）
    pub duration: i64,
    /// 音量 0~100
    pub volume: u8,
    pub muted: bool,
    /// 可用播放源（线路）`(code, 名称)`
    pub sources: Vec<(String, String)>,
    /// 当前播放源 code
    pub current_source: String,
    /// 剧集列表（供手机端选集）`(order, 标题)`
    pub episodes: Vec<(u32, String)>,
    /// 是否有视频在播（false 时手机端提示「去客户端打开一个视频」）
    pub has_media: bool,

    /*
     * ★★ 内容源列表（手机端排序面板用）—— 2026-09-25 新增
     *
     * # 为什么与 `sources` 是两个不同的字段（别搞混）
     *
     * ```text
     * sources   当前这部片子的**播放线路**（如「线路1 / 线路2」）——
     *           随片子变，手机端用来 `switch_source`。
     * providers **全局内容源**（央视 / 次元城 / …）的显示顺序 ——
     *           与应用当前在播什么**无关**，手机端用来排序。
     * ```
     * 名字接近但语义完全不同：`sources` 是「这个片子的第几路流」，
     * `providers` 是「首页各个内容站点的先后」。
     *
     * # 为什么让前端上报而不是 Rust 侧自己读
     *
     * `get_provider_order` 是 Rust 侧的现成命令，但**手机端的列表
     * 必须与设置页看到的一致** —— 而设置页的顺序是前端 `registry`
     * 算出来的（`reorder()` 会对齐到实际注册的源、剔除幽灵项）。
     * Rust 侧再算一遍就有两份真相，装/删源之后必然漂移。
     *
     * 所以与前缀里的设计原则一致：**一套通道，前端上报**。
     *
     * ⚠️ `#[serde(default)]`：老版本客户端（Dart `toJson` 里没有这个
     *    字段）上报时反序列化不能失败 —— 否则遥控**整个**挂掉。
     *    缺省为空列表时手机端只是不显示排序面板，其余功能不受影响。
     */
    /// 全部内容源 `(id, 名称, 是否启用)`，**顺序即显示顺序**
    #[serde(default)]
    pub providers: Vec<ProviderEntry>,

    /*
     * ★★ 片头片尾状态回传 —— 手机端靠这几个字段知道"现在是什么情况"
     *
     * 草稿原话：「状态回传也要加字段（手机才知道现在是什么情况）：
     *            introSkip / outroSkip / autoSkip / skipEditing」
     *
     * ⚠️ 用 `Option<i64>` + `#[serde(default)]`：
     *    老版本手机端页面不带这些字段时反序列化不会失败。
     */
    /// 片头结束位置（秒）；`None` = 未设置
    #[serde(default)]
    pub intro_skip: Option<i64>,
    /// 片尾开始位置（秒）；`None` = 未设置
    #[serde(default)]
    pub outro_skip: Option<i64>,
    /// 是否启用自动跳过
    #[serde(default)]
    pub auto_skip: bool,
    /// 正在编辑哪一项（手机端据此高亮）；`None` = 没在编辑
    #[serde(default)]
    pub skip_editing: Option<SkipKind>,

    /*
     * ══════════════════════════════════════════════════════════════
     * ★★ 手机端遥控页重做新增的状态（全部 `#[serde(default)]`）
     * ══════════════════════════════════════════════════════════════
     *
     * 为什么这里只加字段、不改已有字段的名字与类型：
     * 老版本客户端的 `toJson()` 少这些字段，反序列化必须照样成功
     * ——否则**整个遥控**会因为一个缺字段而挂掉（`providers` 就是这么处理的）。
     * 手机端对缺省值的表现就是「那一项按钮不画」。
     */

    /// 当前片子的封面图 URL（手机端「正在播放」卡片显示）
    #[serde(default)]
    pub cover: Option<String>,

    /// **当前是直播**（而不是点播）
    ///
    /// 手机端据此把「选集」换成「频道列表」——直播没有集数的概念。
    #[serde(default)]
    pub is_live: bool,

    /// 当前直播频道 id
    #[serde(default)]
    pub live_channel_id: String,

    /// 直播频道列表 `(id, 名称)`，供手机端选台
    #[serde(default)]
    pub live_channels: Vec<(String, String)>,

    /// 当前播放倍速（1.0 = 正常）
    #[serde(default = "default_speed")]
    pub speed: f32,

    /// 弹幕是否开着
    #[serde(default)]
    pub danmaku: bool,

    /// 客户端是否处于全屏
    #[serde(default)]
    pub fullscreen: bool,

    /// 可选的清晰度 / 线路候选（显示名）
    ///
    /// ⚠️ 只给**显示名**：地址常带一次性签名，回传给手机既长又不安全。
    /// 手机端按下标发 `set_quality`，由客户端自己取自己那份真值。
    #[serde(default)]
    pub qualities: Vec<String>,
}

/// 倍速的缺省值 —— 缺省即正常速度
///
/// 不能用 `Default::default()`（那是 `0.0`）：媒体内核会拒绝 0 倍速，
/// 老客户端上报的状态会让客户端**放不下去**。
fn default_speed() -> f32 {
    1.0
}

/// 手机端的搜索/浏览请求要转发给前端执行 —— 复用命令通道
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum RemoteQuery {
    /// 搜索（前端执行后把结果写回 state）
    Search { keyword: String },
    /// 加载首页分区（手机端「发现」页）
    Home,
}

// ─────────────────────────── 共享状态 ───────────────────────────

/// 遥控服务的共享状态
pub struct RemoteHub {
    /// 是否已开启
    running: AtomicBool,
    /// 实际监听端口
    port: AtomicU16,
    /// ★ 随机配对码（每次启动重新生成）
    ///
    /// 保留它的理由：默认就该是随机的 —— 用户什么都不用配，
    /// 而且**重启即失效**，安全性最好。
    pin: Mutex<String>,
    /// ★ 固定配对码（用户自己设的，可选）
    ///
    /// # 为什么要有这个（Owner 要求）
    ///
    /// 「每次都要随机太麻烦了」—— 电视上开着遥控，手机扫完码还要
    /// 抬头抄一遍六位数字，每次重启都变。设一个固定的就不用重复抄。
    ///
    /// # 为什么两个都保留，而不是二选一
    ///
    /// 固定码方便但**长期有效**（写在手机上就一直能用），
    /// 随机码安全但麻烦。两者**各自有适用场景**：
    ///   · 自己家里长期用 → 固定码
    ///   · 临时给别人用一下 → 用随机码，用完关掉遥控即可
    ///
    /// 所以 `check_pin` **两个都接受**，用户想用哪个用哪个。
    fixed_pin: Mutex<Option<String>>,
    /// 播放器上报的状态
    state: Mutex<RemoteState>,
    /// 待执行命令队列
    queue: Mutex<VecDeque<RemoteCommand>>,
    /// 搜索结果（前端回填，手机端读取）
    search: Mutex<Option<SearchPayload>>,
    /// 首页分区（同上）
    home: Mutex<Option<HomePayload>>,
    /// ★★ 关闭信号（真正让 `serve` 退出并释放监听套接字）
    ///
    /// # 为什么必须有它（实测复现的真 bug）
    ///
    /// 原先 `remote_stop` 只做 `running = false`，**套接字不释放**。
    /// 实测「开启 → 关闭 → 再开启」的第三步：
    ///
    /// ```text
    /// ① 初始      8642 FREE
    /// ② 开启后    8642 LISTENING(1)   ✅
    /// ③ 关闭后    8642 LISTENING(1)   ❌ 关掉了端口还在监听
    /// ④ 再开启    端口 8642 无法监听（可能被占用）：…
    ///             (os error 10048)
    /// ```
    ///
    /// 因为 `spawn_remote_server` 重新开启时要 `TcpListener::bind`，
    /// 而端口还被**自己这个进程**占着 —— 必然失败。
    /// 用户唯一的出路是**重启应用**，而且完全猜不到要这么做。
    ///
    /// # 为什么是 `tokio::sync::watch` 而不是别的
    ///
    /// · `oneshot` 只能发一次，而遥控可以反复开/关 → 不行
    /// · `Notify` 有"通知丢失"问题（先发后等就收不到）→ 不适合
    /// · `watch` 保留**最新值**，新订阅者立刻能读到当前状态 →
    ///   即使 `serve` 启动得比 `stop` 晚也不会漏掉关闭信号
    ///
    /// 值语义：`true` = 请求关闭。
    shutdown: tokio::sync::watch::Sender<bool>,
    /// 与上面配对的接收端（`serve` 里订阅它）
    ///
    /// ⚠️ 用 `Sender::subscribe()` 也能拿到，但存一份在手边
    ///    可以避免"没有任何接收者时 send 失败"的边界情况。
    shutdown_rx: Mutex<tokio::sync::watch::Receiver<bool>>,
    /// ★★ 开机自启的**结果**（`None` = 还没试过 / 用户关掉了自启）
    ///
    /// # 为什么需要它（2026-09-24，用户报的症状）
    ///
    /// 用户原话：
    /// > 「局域网遥控开了 开机自动,但是软件都打开了,也没见启动」
    ///
    /// 自启是**后台异步**做的（`bootstrap` 里 `tokio::spawn`），
    /// 所以它失败时**没人能告诉用户**：
    /// ```text
    /// 端口被别的程序占着 → bind 失败 → 只打了一行日志 → 用户看到"没启动"
    /// ```
    /// 更糟的是：**用户不可能知道"端口被占"这件事** ——
    /// 我们这次是靠"逐个进程枚举模块"才找到占用者的。
    ///
    /// 所以把结果**存进 hub**，让 UI / FFI 能查：
    /// ```text
    /// Some(Ok(port))   → 自启成功，正在监听 port
    /// Some(Err(reason))→ 自启失败，reason 是给用户看的**中文原因**
    /// None             → 没有尝试自启（用户关过 auto_start）
    /// ```
    autostart: Mutex<Option<std::result::Result<u16, String>>>,
}

/// 搜索结果载荷（由前端回填）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SearchPayload {
    pub keyword: String,
    pub items: Vec<RemoteItem>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct HomePayload {
    pub sections: Vec<RemoteSection>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RemoteSection {
    pub title: String,
    pub items: Vec<RemoteItem>,
}

/// 手机端展示用的条目（只带必要字段，避免传输大对象）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RemoteItem {
    pub provider: String,
    pub id: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
}

impl Default for RemoteHub {
    fn default() -> Self {
        Self::new()
    }
}

impl RemoteHub {
    pub fn new() -> Self {
        let (shutdown, shutdown_rx) = tokio::sync::watch::channel(false);
        Self {
            running: AtomicBool::new(false),
            port: AtomicU16::new(DEFAULT_PORT),
            pin: Mutex::new(generate_pin()),
            fixed_pin: Mutex::new(None),
            state: Mutex::new(RemoteState::default()),
            queue: Mutex::new(VecDeque::new()),
            search: Mutex::new(None),
            home: Mutex::new(None),
            shutdown,
            shutdown_rx: Mutex::new(shutdown_rx),
            autostart: Mutex::new(None),
        }
    }

    /// 记录开机自启的结果（成功=端口，失败=给用户看的原因）
    pub fn set_autostart(&self, r: std::result::Result<u16, String>) {
        *self.autostart.lock().unwrap() = Some(r);
    }

    /// 读取开机自启的结果（`None` = 没有尝试自启）
    pub fn autostart(&self) -> Option<std::result::Result<u16, String>> {
        self.autostart.lock().unwrap().clone()
    }

    /// 自启失败的原因（成功或未尝试时为 `None`）
    ///
    /// ★ 这是给 UI 用的：用户报「开了自启但没启动」时，
    ///   界面可以直接显示这句话，而不用让他去查端口占用。
    pub fn autostart_error(&self) -> Option<String> {
        match self.autostart() {
            Some(Err(e)) => Some(e),
            _ => None,
        }
    }

    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::SeqCst)
    }

    pub fn set_running(&self, v: bool) {
        self.running.store(v, Ordering::SeqCst);
    }

    /// ★★ 请求关闭遥控服务，并**等待监听套接字真正释放**
    ///
    /// # 为什么需要它（实测复现的真 bug）
    ///
    /// 原先 `remote_stop` 只调 `set_running(false)` —— 那只是让
    /// 路由返回 503，**套接字仍然绑着**。于是「关闭后再开启」
    /// 必然撞 `os error 10048`（地址已被自己占用），
    /// 用户只能重启应用。详见 `shutdown` 字段的说明。
    ///
    /// # 为什么要 await
    ///
    /// 发完信号就返回的话，`serve` 那边可能还没来得及 drop listener，
    /// 紧接着的 `TcpListener::bind` 仍会失败 —— **竞态**。
    /// 所以这里轮询等 `is_running` 被 `serve` 的收尾逻辑置回 false
    /// （见 `spawn_remote_server` 里的 spawn 闭包），
    /// 最多等 `timeout`，超时也不阻塞用户（返回 false 让调用方提示）。
    ///
    /// # 返回值
    ///
    /// `true` = 已确认停止（套接字应已释放）
    /// `false` = 超时（调用方应当提示用户，而不是假装成功）
    pub async fn request_shutdown(&self, timeout: std::time::Duration) -> bool {
        // 先把路由闸门关上（立刻生效，手机端马上 503）
        self.set_running(false);

        // 再发关闭信号（`serve` 收到后 drop listener 并退出）
        let _ = self.shutdown.send(true);

        // 等 `serve` 的收尾逻辑确认停止
        let step = std::time::Duration::from_millis(20);
        let mut waited = std::time::Duration::ZERO;
        while waited < timeout {
            /*
             * ⚠️ 判据用的是 `running` 被 serve 的收尾置回 false ——
             *    但上面我们自己已经置过 false 了，所以这里不能只看它。
             *    改用「端口能否重新绑定」这个**真正重要的**事实来判断。
             */
            if crate::remote::port_is_free(self.port()) {
                return true;
            }
            tokio::time::sleep(step).await;
            waited += step;
        }
        false
    }

    /// 订阅关闭信号（`serve` 用它来知道何时该退出）
    ///
    /// 每次开启服务前调一次，拿到一个**全新**的接收端，
    /// 并把信号复位为 `false`（否则上一次的关闭信号会让新服务立刻退出）。
    pub fn resubscribe_shutdown(&self) -> tokio::sync::watch::Receiver<bool> {
        let _ = self.shutdown.send(false);
        self.shutdown.subscribe()
    }

    pub fn port(&self) -> u16 {
        self.port.load(Ordering::SeqCst)
    }

    pub fn set_port(&self, p: u16) {
        self.port.store(p, Ordering::SeqCst);
    }

    /// 当前配对码（随机那个）
    pub fn pin(&self) -> String {
        self.pin.lock().map(|p| p.clone()).unwrap_or_default()
    }

    /// 当前固定配对码（没设时为 `None`）
    pub fn fixed_pin(&self) -> Option<String> {
        self.fixed_pin.lock().ok().and_then(|p| p.clone())
    }

    /// 设置（或清除）固定配对码
    ///
    /// 传 `None` 表示清除 —— 清除后只有随机码能进。
    pub fn set_fixed_pin(&self, p: Option<String>) {
        if let Ok(mut g) = self.fixed_pin.lock() {
            *g = p;
        }
    }

    /// 重新生成配对码（用户可主动换一个）
    ///
    /// ⚠️ 只换**随机**那个 —— 固定码是用户自己设的，
    /// 点「换一个」不应该把它清掉（那会让人以为设置丢了）。
    pub fn refresh_pin(&self) -> String {
        let p = generate_pin();
        if let Ok(mut g) = self.pin.lock() {
            *g = p.clone();
        }
        p
    }

    /// 校验配对码
    ///
    /// ★ **随机码与固定码都接受** —— 用户想用哪个用哪个。
    ///
    /// 两者都不是空的才比较；用「异或累积」而不是 `==`，
    /// 避免逐字节短路比较带来的时序侧信道（虽然同网段风险很低，
    /// 但这是零成本的正确写法）。
    pub fn check_pin(&self, given: &str) -> bool {
        let given = given.trim();
        if given.is_empty() {
            return false;
        }

        // 1) 随机码
        let random = self.pin();
        if constant_eq(&random, given) {
            return true;
        }

        // 2) 固定码（没设就跳过）
        if let Some(fixed) = self.fixed_pin() {
            if constant_eq(&fixed, given) {
                return true;
            }
        }

        false
    }

    /// 播放器上报状态（前端定期调）
    pub fn update_state(&self, s: RemoteState) {
        if let Ok(mut g) = self.state.lock() {
            *g = s;
        }
    }

    pub fn state(&self) -> RemoteState {
        self.state.lock().map(|s| s.clone()).unwrap_or_default()
    }

    /// 手机端发来命令 → 入队
    pub fn push_command(&self, c: RemoteCommand) {
        if let Ok(mut q) = self.queue.lock() {
            if q.len() >= MAX_QUEUE {
                q.pop_front();
            }
            q.push_back(c);
        }
    }

    /// 前端取走全部待执行命令
    pub fn take_commands(&self) -> Vec<RemoteCommand> {
        self.queue
            .lock()
            .map(|mut q| q.drain(..).collect())
            .unwrap_or_default()
    }

    /// 前端回填搜索结果
    pub fn set_search(&self, p: SearchPayload) {
        if let Ok(mut g) = self.search.lock() {
            *g = Some(p);
        }
    }

    pub fn search(&self) -> Option<SearchPayload> {
        self.search.lock().ok().and_then(|g| g.clone())
    }

    /// 前端回填首页
    pub fn set_home(&self, p: HomePayload) {
        if let Ok(mut g) = self.home.lock() {
            *g = Some(p);
        }
    }

    pub fn home(&self) -> Option<HomePayload> {
        self.home.lock().ok().and_then(|g| g.clone())
    }
}

/// 常量时间比较（避免按时序猜码）
///
/// 长度不同直接 false —— 长度本身不是秘密（4~8 位），
/// 但相同长度时**不能短路**：逐字节累积异或，走完全程再判断。
fn constant_eq(a: &str, b: &str) -> bool {
    if a.is_empty() || a.len() != b.len() {
        return false;
    }
    a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// 校验配对码格式（固定码用）
///
/// 只允许 4~8 位数字：手机上是数字键盘输入的，夹字母会很难打；
/// 太短（<4）容易被同网段的人猜中。
pub fn validate_fixed_pin(raw: &str) -> Result<String, String> {
    let s: String = raw.chars().filter(|c| !c.is_whitespace()).collect();
    if s.is_empty() {
        return Err("配对码不能为空".into());
    }
    if !s.chars().all(|c| c.is_ascii_digit()) {
        return Err("配对码只能是数字（手机上是数字键盘）".into());
    }
    if s.len() < 4 || s.len() > 8 {
        return Err(format!("配对码需要 4~8 位数字，当前 {} 位", s.len()));
    }
    Ok(s)
}

/// 生成 6 位数字配对码
///
/// 不用字母：手机上手输时数字最省事（而且这个码只在同网段有效，很短时间）。
fn generate_pin() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos() as u64 + d.as_secs())
        .unwrap_or(12345);
    // 简单混一下，避免连续启动得到相近的码
    let mixed = nanos.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    format!("{:06}", (mixed >> 33) % 1_000_000)
}

// ─────────────────────────── 本机局域网 IP ───────────────────────────

/// 取本机在局域网里的 IPv4 地址
///
/// # 做法
///
/// 对候选目标各发一次 UDP `connect`（**不会真的发包**），
/// 内核会选出「到那个地址会走哪张网卡」，于是 `local_addr()`
/// 就是那张网卡的地址。
///
/// ⚠️ 不用 `hostname`/`getifaddrs` 那套：那些会返回一堆虚拟网卡
/// （VMware / Docker / VPN / WSL），还得猜哪个是「真正的」网卡。
/// UDP connect 由内核路由表决定。
///
/// # ★★ 为什么不能只探测 `8.8.8.8`（实测的真 bug）
///
/// 原实现只对 `8.8.8.8` 探测，注释里写着「内核路由表永远是对的」。
/// **那个假设在装了 TUN 模式代理时不成立。**
///
/// 实测（本机装了 Mihomo，TUN 模式接管默认路由）：
///
/// ```text
/// 目标               内核选出的本机地址    说明
/// 8.8.8.8       →   198.18.0.1          ❌ Mihomo 的虚拟网卡（假 IP 段）
/// 1.1.1.1       →   198.18.0.1          ❌ 同上
/// 114.114.114.114 → 198.18.0.1          ❌ 同上
/// 10.168.1.1    →   10.168.1.115        ✅ 真实局域网 IP
/// ```
///
/// 后果：**遥控地址显示成 `http://198.18.0.1:8642/`，手机根本连不上**
/// （那是代理内部的假地址，只在代理进程内有意义）。
/// 而且服务真的绑到了那张网卡上 —— 所以是彻底不可用，不只是显示错。
///
/// # 修法：先探测「同网段」，再退回公网
///
/// 局域网遥控的语义就是「**同网段**的手机能连上」，
/// 所以探测目标**必须落在真实局域网里** —— 那样内核必然选真实网卡。
///
/// 但代码事先不知道用户的网段是什么，于是：
///   1. 枚举常见私网网段的网关地址（`192.168.x.1` / `10.x.x.1` …）
///   2. **同时**探测公网地址作为兜底
///   3. 从结果里**优先选私网地址**（`is_private()`），
///      且**排除 CGNAT 假 IP 段**（`198.18.0.0/15` 等，见 `is_fake_ip`）
///
/// 拿不到时退回 `127.0.0.1`（只本机可用），并如实告知用户。
pub fn lan_ip() -> IpAddr {
    let mut fallback: Option<IpAddr> = None;

    for target in PROBE_TARGETS {
        let Ok(sock) = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)) else {
            continue;
        };
        if sock.connect((*target, 80)).is_err() {
            continue;
        }
        let Ok(addr) = sock.local_addr() else { continue };
        let ip = addr.ip();

        // 拿到真实私网地址 → 直接用（这是我们想要的）
        if is_usable_lan_ip(&ip) {
            return ip;
        }
        // 否则先记下来，继续找更好的
        if fallback.is_none() && !ip.is_loopback() {
            fallback = Some(ip);
        }
    }

    fallback.unwrap_or(IpAddr::V4(Ipv4Addr::LOCALHOST))
}

/// 探测目标：**先同网段网关，后公网**
///
/// 顺序有意义：同网段目标一定走真实网卡，公网目标在 TUN 代理下会走假网卡。
/// 前面的先命中就先返回（见 `lan_ip` 的循环）。
const PROBE_TARGETS: &[Ipv4Addr] = &[
    // ── 常见私网网段的网关（覆盖家用/办公 99% 的情况）──
    Ipv4Addr::new(192, 168, 0, 1),
    Ipv4Addr::new(192, 168, 1, 1),
    Ipv4Addr::new(192, 168, 2, 1),
    Ipv4Addr::new(192, 168, 31, 1),
    Ipv4Addr::new(10, 0, 0, 1),
    Ipv4Addr::new(10, 0, 1, 1),
    Ipv4Addr::new(10, 1, 1, 1),
    Ipv4Addr::new(10, 168, 0, 1),
    Ipv4Addr::new(10, 168, 1, 1),
    Ipv4Addr::new(172, 16, 0, 1),
    // ── 公网兜底（无代理时它能选对；有代理时会被 is_usable_lan_ip 排除）──
    Ipv4Addr::new(223, 5, 5, 5),
    Ipv4Addr::new(8, 8, 8, 8),
];

/// 这个地址能不能用来做「局域网遥控地址」
///
/// 要同时满足：私网 + 不是代理软件的假 IP 段。
fn is_usable_lan_ip(ip: &IpAddr) -> bool {
    let IpAddr::V4(v4) = ip else { return false };
    v4.is_private() && !is_fake_ip(v4)
}

/// ★ 代理软件常用的「假 IP 段」（TUN / fake-ip 模式）
///
/// 这些地址**看起来是私网**（`is_private()` 为 true），
/// 但只存在于代理进程内部，局域网里的手机**永远路由不到**。
///
/// | 网段 | 谁在用 |
/// |---|---|
/// | `198.18.0.0/15` | Mihomo / Clash **fake-ip 默认段**（实测本机就是它）|
/// | `198.19.0.0/16` | 同上（RFC 2544 基准测试段）|
/// | `240.0.0.0/4` | 保留段，部分 TUN 实现会用到 |
///
/// ⚠️ `198.18.0.0/15` 在 RFC 里是「网络设备基准测试」保留段，
/// 不是私网 —— 但 `is_private()` 对它的判定**依赖 Rust 版本**
/// （`is_private` 只认 RFC 1918 三段，所以它其实会返回 false）。
/// 这里仍显式列出，是为了**不依赖那个细节**：
/// 万一将来标准库把 CGNAT/保留段也纳入 `is_private`，
/// 这段代码的行为不会跟着变。
fn is_fake_ip(ip: &Ipv4Addr) -> bool {
    let [a, b, ..] = ip.octets();
    // 198.18.0.0/15 —— Mihomo / Clash fake-ip 默认段
    (a == 198 && (b == 18 || b == 19))
        // 240.0.0.0/4 —— 保留段
        || a >= 240
}

/// 遥控页面的访问地址（给用户扫/输的）
pub fn remote_url(port: u16) -> String {
    format!("http://{}:{port}/", lan_ip())
}

/// ★ 生成遥控地址的二维码（SVG 字符串）
///
/// 手机扫码直连，用户不用手输 `192.168.x.x:8642` 这种地址 ——
/// 那个在手机浏览器里输起来很痛苦，而且容易输错。
///
/// 返回 SVG 而不是 PNG：
///   · 矢量，放大不糊（TV 上要放大展示给远处的人扫）
///   · 前端直接 `v-html` 渲染，不需要转 base64 或落盘
///
/// ⚠️ 二维码**不含配对码** —— 配对码要用户看着客户端手输。
///   若把配对码也编进去，任何能看到这个二维码的人（拍照、
///   甚至从屏幕反光）就能直接控制，等于没有防护。
///   现在的设计是「扫码打开页面 + 手输 6 位码」，两步都需要接触实物。
pub fn qr_svg(port: u16) -> Option<String> {
    qr_svg_for(&remote_url(port))
}

/// 把**任意文本**渲染成二维码 SVG
///
/// # 为什么从 `qr_svg` 抽出来（2026-09-21）
///
/// 扫码登录要画的是**站点给的 url**（如 B站的
/// `account.bilibili.com/h5/account-h5/auth/scan-web?...`），
/// 与遥控的 url 只是"内容不同"，渲染要求完全一样：
/// ```text
/// · 留白 ≥4 模块（QR 规范，少了识别率明显下降）
/// · 深色用近黑而非纯黑（与深色主题协调）
/// · 最小 200×200（太小手机对不上焦）
/// ```
/// 复制一份必然漂移，所以让 `qr_svg` 也走这里。
///
/// ⚠️ 返回 `None` 表示"内容太长/渲染失败" —— 调用方应降级
///    （例如把 url 当纯文本显示），而不是让整个流程失败。
/// 把**任意文本**渲染成二维码 SVG
///
/// # 为什么要 pub
///
/// Flutter 侧要**自己解析**这个 SVG 来画二维码 —— 不引入 `flutter_svg`
/// （那是一个平台插件，会增大安装包，违反硬性指标③ Windows <50MB）。
/// 解析逻辑依赖 SVG 的确切结构，所以测试需要能直接拿到它。
pub fn qr_svg_for(text: &str) -> Option<String> {
    use qrcode::render::svg;
    use qrcode::QrCode;

    let code = QrCode::new(text.as_bytes()).ok()?;

    Some(
        code.render::<svg::Color>()
            .min_dimensions(200, 200)
            // 留白（quiet zone）：QR 规范要求四周至少 4 模块，
            // 少了扫码识别率会明显下降
            .quiet_zone(true)
            // 深色模块用近黑而不是纯黑：与应用的深色主题更协调
            .dark_color(svg::Color("#0b0d12"))
            .light_color(svg::Color("#ffffff"))
            .build(),
    )
}

/// 服务监听地址 —— **只绑局域网 IP**，不绑 0.0.0.0
///
/// 这是有意的安全选择：绑 `0.0.0.0` 会连同「公网网卡 / VPN 网卡」
/// 一起暴露。只绑局域网 IP 意味着即使机器有公网地址，这个端口
/// 也不会出现在公网上。
pub fn bind_addr(port: u16) -> SocketAddr {
    SocketAddr::new(lan_ip(), port)
}

/// 探测端口现在能不能绑定（= 上一个监听套接字是否已释放）
///
/// # 为什么需要它
///
/// `remote_stop` 要等 `serve` 真正 drop 掉 listener 才能返回，
/// 而"drop 了没有"这件事**没有直接的可观测信号**。
/// 最可靠的判据就是**试着绑一次**：
///   · 绑得上 → 上一个确实释放了
///   · 绑不上 → 还占着
///
/// ⚠️ 探测用的监听器**立刻 drop**，所以不会真的占用端口 ——
///    但这也意味着探测与真正的 `bind` 之间有极小的竞态窗口。
///    这个窗口在实践中无害（同一进程内只有我们自己在绑定），
///    而且真正的 `bind` 失败时仍会有明确的错误提示。
///
/// 用**同步** socket 而不是 `tokio::net::TcpListener`：
/// 这个函数在轮询里被反复调用，同步版本不需要 await、
/// 也不需要在 runtime 上下文里跑（`RemoteHub` 的测试就是同步的）。
pub fn port_is_free(port: u16) -> bool {
    use std::net::TcpListener;
    match TcpListener::bind(bind_addr(port)) {
        Ok(l) => {
            drop(l);
            true
        }
        Err(_) => false,
    }
}

// ─────────────────────────── 测试 ───────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// ★★ 固定码与随机码**并存**：两个都能进（Owner 要求）
    ///
    /// 「每次都要随机太麻烦了」—— 遥控每次启动换码，手机要反复抄。
    /// 设一个固定的就不用抄了，但**不能因此把随机码废掉** ——
    /// 随机码适合「临时给别人用一下」的场景，两者各有用途。
    #[test]
    fn both_fixed_and_random_pin_work() {
        let h = RemoteHub::new();
        let random = h.pin();

        // 没设固定码时：只有随机码能进
        assert!(h.check_pin(&random), "随机码必须一直有效");
        assert!(!h.check_pin("123456"), "没设固定码时不该有别的码能进");

        // 设一个固定码
        h.set_fixed_pin(Some("8888".into()));

        // ★ 两个都要能进
        assert!(h.check_pin("8888"), "固定码必须能进");
        assert!(
            h.check_pin(&h.pin()),
            "设了固定码之后**随机码仍要有效**（否则就变成二选一了）"
        );

        // 错的还是要拒
        assert!(!h.check_pin("9999"), "错误的码必须拒绝");
        assert!(!h.check_pin(""), "空码必须拒绝");
    }

    /// ★ 「换一个」只换随机码，**不能把固定码弄丢**
    ///
    /// 实测场景：用户看到「换一个」按钮点了一下，
    /// 如果固定码被顺带清掉，他会以为设置丢了 —— 而且找不回来。
    #[test]
    fn refresh_pin_keeps_fixed_pin() {
        let h = RemoteHub::new();
        h.set_fixed_pin(Some("6666".into()));
        let before = h.pin();

        let after = h.refresh_pin();

        assert_ne!(before, after, "随机码应该变了");
        assert_eq!(h.pin(), after);
        assert_eq!(
            h.fixed_pin().as_deref(),
            Some("6666"),
            "「换一个」不能动固定码"
        );
        assert!(h.check_pin("6666"), "换过之后固定码依然能进");
    }

    /// ★★ 关闭后端口必须**真的**释放（回归测试）
    ///
    /// # 这条测试守的是一个实测复现过的真 bug
    ///
    /// 症状（Owner 截图报告）：
    /// ```text
    /// 端口 8642 无法监听（可能被占用）：
    /// 通常每个套接字地址(协议/网络地址/端口)只允许使用一次。(os error 10048)
    /// ```
    ///
    /// 根因：`remote_stop` 只把 `running` 置 false，**监听套接字不释放**。
    /// 于是「开启 → 关闭 → 再开启」的第三步必然绑定失败，
    /// 用户只能重启应用，且界面提示「可能被占用」会把他引向
    /// "谁占了我的端口"这个**错误方向**（实际是自己占的）。
    ///
    /// # 这条测试怎么守
    ///
    /// 用 `port_is_free` 这个判据（试着绑定）来断言：
    /// 在没有服务运行时，端口必须是可绑的。
    ///
    /// ⚠️ 这里只测 `port_is_free` 这个**判据本身**是对的 ——
    ///    完整的"起服务→关服务→端口释放"需要 async runtime
    ///    与真实网络，属于集成测试范畴（见 `.probe/ui/remote_cycle.mjs`
    ///    的人工模拟实测）。
    #[test]
    fn port_is_free_reflects_real_bindability() {
        /*
         * 挑一个几乎不可能被占用的高位端口，
         * 避免与开发机上真实运行的服务冲突。
         */
        let port = 38517;

        // 没人监听时应当可绑
        assert!(
            port_is_free(port),
            "端口 {port} 空闲时 port_is_free 应为 true"
        );

        // 自己占住它，就应当报"不可绑"
        let held = std::net::TcpListener::bind(bind_addr(port))
            .expect("测试用端口应当能绑上（若失败说明该端口被别的程序占了，换个端口）");
        assert!(
            !port_is_free(port),
            "端口 {port} 被占用时 port_is_free 应为 false"
        );

        // 释放后又能绑
        drop(held);
        assert!(
            port_is_free(port),
            "端口 {port} 释放后 port_is_free 应恢复为 true"
        );
    }

    /// ★ 关闭信号能传到 `serve`，且**复位后不会误触发**
    ///
    /// # 为什么要专门测"复位"
    ///
    /// `serve` 用 `resubscribe_shutdown()` 拿接收端，它会把信号
    /// 复位为 `false`。如果忘了复位，第二次开启遥控时
    /// **新服务会立刻收到上次的关闭信号并退出** ——
    /// 表现为"点了开启，闪一下就没了"，比原来的 bug 更难查。
    #[tokio::test]
    async fn shutdown_signal_resets_between_runs() {
        let h = RemoteHub::new();

        // 第一次：拿到接收端 → 此时不该已收到关闭信号
        let mut rx1 = h.resubscribe_shutdown();
        assert!(!*rx1.borrow(), "刚订阅时不该有未处理的关闭信号");

        // 发关闭信号 → 接收端应看到
        let _ = h.shutdown.send(true);
        assert!(
            *rx1.borrow(),
            "发出关闭信号后，已订阅的接收端应当看到 true"
        );

        // 第二次：重新订阅应当**复位**为 false（否则新服务会秒退）
        let rx2 = h.resubscribe_shutdown();
        assert!(
            !*rx2.borrow(),
            "重新订阅后信号必须复位为 false —— 否则第二次开启遥控会立刻退出"
        );
    }

    /// 清除固定码后，它就进不来了（只剩随机码）
    #[test]
    fn clearing_fixed_pin_revokes_it() {
        let h = RemoteHub::new();
        h.set_fixed_pin(Some("4321".into()));
        assert!(h.check_pin("4321"));

        h.set_fixed_pin(None);

        assert!(!h.check_pin("4321"), "清除后旧固定码必须失效");
        assert!(h.check_pin(&h.pin()), "随机码仍要有效");
        assert!(h.fixed_pin().is_none());
    }

    /// 固定码格式校验：4~8 位数字
    ///
    /// 为什么限制 4~8 位：手机上是数字键盘，夹字母很难打；
    /// 太短容易被同网段的人猜中。
    #[test]
    fn fixed_pin_validation() {
        // 合法
        assert_eq!(validate_fixed_pin("1234").unwrap(), "1234");
        assert_eq!(validate_fixed_pin("12345678").unwrap(), "12345678");
        // 顺手去掉空格（用户可能从别处粘贴过来带空格）
        assert_eq!(validate_fixed_pin(" 12 34 ").unwrap(), "1234");

        // 非法
        assert!(validate_fixed_pin("").is_err(), "空要拒");
        assert!(validate_fixed_pin("123").is_err(), "少于 4 位要拒");
        assert!(validate_fixed_pin("123456789").is_err(), "多于 8 位要拒");
        assert!(validate_fixed_pin("12a4").is_err(), "含字母要拒");
        assert!(validate_fixed_pin("12-34").is_err(), "含符号要拒");
    }

    /// 配对码必须是 6 位数字（手机上手输的场景）
    #[test]
    fn pin_is_six_digits() {
        let h = RemoteHub::new();
        let p = h.pin();
        assert_eq!(p.len(), 6, "配对码应为 6 位，实际 {p:?}");
        assert!(p.chars().all(|c| c.is_ascii_digit()), "应全为数字: {p:?}");
    }

    /// 配对码校验要正确，且不能因为「前缀相同」就通过
    #[test]
    fn pin_check_is_exact() {
        let h = RemoteHub::new();
        let real = h.pin();
        assert!(h.check_pin(&real), "正确的码应通过");
        assert!(!h.check_pin(""), "空码必须拒绝");
        assert!(!h.check_pin("000000") || real == "000000");
        assert!(!h.check_pin(&real[..5]), "少一位必须拒绝");
        assert!(!h.check_pin(&format!("{real}0")), "多一位必须拒绝");
        // 改一位
        let mut wrong = real.clone().into_bytes();
        wrong[0] = if wrong[0] == b'9' { b'8' } else { b'9' };
        let wrong = String::from_utf8(wrong).unwrap();
        assert!(!h.check_pin(&wrong), "改一位必须拒绝");
    }

    /// 重新生成配对码后，旧码必须失效
    #[test]
    fn refresh_pin_invalidates_old() {
        let h = RemoteHub::new();
        let old = h.pin();
        let new = h.refresh_pin();
        assert!(h.check_pin(&new));
        if old != new {
            assert!(!h.check_pin(&old), "旧码应失效");
        }
    }

    /// 命令队列要有上限，且丢的是**最旧的**
    #[test]
    fn command_queue_is_bounded_and_drops_oldest() {
        let h = RemoteHub::new();
        for _ in 0..(MAX_QUEUE + 10) {
            h.push_command(RemoteCommand::NextEpisode);
        }
        let cmds = h.take_commands();
        assert_eq!(cmds.len(), MAX_QUEUE, "队列不能无限增长");
        // 取走后应清空（避免重复执行）
        assert!(h.take_commands().is_empty());
    }

    /// 命令要**保序**（连点下一集两次不能变成只执行一次）
    #[test]
    fn commands_keep_order() {
        let h = RemoteHub::new();
        h.push_command(RemoteCommand::GotoEpisode { order: 3 });
        h.push_command(RemoteCommand::TogglePlay);
        h.push_command(RemoteCommand::Seek { delta: -10 });

        let cmds = h.take_commands();
        assert_eq!(cmds.len(), 3);
        assert_eq!(cmds[0], RemoteCommand::GotoEpisode { order: 3 });
        assert_eq!(cmds[1], RemoteCommand::TogglePlay);
        assert_eq!(cmds[2], RemoteCommand::Seek { delta: -10 });
    }

    /// 状态上报与读取要一致
    #[test]
    fn state_roundtrip() {
        let h = RemoteHub::new();
        let s = RemoteState {
            playing: true,
            title: "新闻联播".into(),
            episode_order: 5,
            episode_count: 27,
            position: 120,
            duration: 1800,
            volume: 80,
            muted: false,
            has_media: true,
            ..Default::default()
        };
        h.update_state(s.clone());
        let got = h.state();
        assert_eq!(got.title, "新闻联播");
        assert_eq!(got.episode_order, 5);
        assert!(got.playing);
    }

    /// ★ 监听地址必须是局域网 IP，**不能是 0.0.0.0**
    ///
    /// 绑 0.0.0.0 会把公网网卡/VPN 网卡一起暴露 —— 这是安全底线。
    #[test]
    fn bind_addr_is_not_unspecified() {
        let a = bind_addr(DEFAULT_PORT);
        assert!(
            !a.ip().is_unspecified(),
            "不能绑 0.0.0.0（会暴露到公网网卡），实际 {a}"
        );
        assert_eq!(a.port(), DEFAULT_PORT);
    }

    /// 遥控地址要是能直接粘进手机浏览器的形态
    #[test]
    fn remote_url_is_clickable() {
        let u = remote_url(8642);
        assert!(u.starts_with("http://"), "实际: {u}");
        assert!(u.ends_with(":8642/"), "实际: {u}");
        assert!(!u.contains("0.0.0.0"), "不能给出 0.0.0.0 的地址: {u}");
    }

    // ═══════════════ 局域网 IP 选择 ═══════════════

    /// ★ 代理软件的假 IP 段必须被识别
    ///
    /// 这是实测的真 bug：本机装了 Mihomo（TUN 模式），
    /// 原实现探测 `8.8.8.8` 拿到 `198.18.0.1`，
    /// 于是遥控地址显示成 `http://198.18.0.1:8642/` —— 手机根本连不上。
    #[test]
    fn fake_ip_ranges_are_detected() {
        // Mihomo / Clash fake-ip 默认段
        assert!(is_fake_ip(&Ipv4Addr::new(198, 18, 0, 1)), "198.18.0.1 是假 IP");
        assert!(is_fake_ip(&Ipv4Addr::new(198, 18, 255, 254)));
        assert!(is_fake_ip(&Ipv4Addr::new(198, 19, 0, 1)), "198.19 也属于该 /15");

        // 保留段
        assert!(is_fake_ip(&Ipv4Addr::new(240, 0, 0, 1)));
        assert!(is_fake_ip(&Ipv4Addr::new(255, 255, 255, 255)));

        // 真实局域网地址不能被误判
        assert!(!is_fake_ip(&Ipv4Addr::new(192, 168, 1, 100)));
        assert!(!is_fake_ip(&Ipv4Addr::new(10, 168, 1, 115)));
        assert!(!is_fake_ip(&Ipv4Addr::new(172, 16, 0, 5)));
        assert!(!is_fake_ip(&Ipv4Addr::new(8, 8, 8, 8)));
    }

    /// 可用的局域网地址：私网 + 不是假 IP
    #[test]
    fn usable_lan_ip_requires_private_and_real() {
        // 真实私网 → 可用
        assert!(is_usable_lan_ip(&IpAddr::V4(Ipv4Addr::new(10, 168, 1, 115))));
        assert!(is_usable_lan_ip(&IpAddr::V4(Ipv4Addr::new(192, 168, 1, 50))));
        assert!(is_usable_lan_ip(&IpAddr::V4(Ipv4Addr::new(172, 16, 3, 4))));

        // 假 IP 段 → 不可用（即使它在数值上"像"私网）
        assert!(
            !is_usable_lan_ip(&IpAddr::V4(Ipv4Addr::new(198, 18, 0, 1))),
            "代理假 IP 绝不能当作局域网地址"
        );

        // 公网 → 不可用（手机在同网段，路由不到公网地址上的服务）
        assert!(!is_usable_lan_ip(&IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8))));

        // 回环 → 不可用
        assert!(!is_usable_lan_ip(&IpAddr::V4(Ipv4Addr::LOCALHOST)));
    }

    /// 探测目标必须**先私网后公网**
    ///
    /// 顺序有意义：同网段目标一定走真实网卡，
    /// 公网目标在 TUN 代理下会走假网卡。
    #[test]
    fn probe_targets_prioritize_private_gateways() {
        let first_public = PROBE_TARGETS
            .iter()
            .position(|ip| !ip.is_private())
            .expect("应该至少有一个公网兜底目标");

        let private_count = PROBE_TARGETS
            .iter()
            .filter(|ip| ip.is_private())
            .count();

        assert!(
            private_count >= 8,
            "常见私网网段要覆盖足够多（实际 {private_count} 个）"
        );
        assert_eq!(
            first_public, private_count,
            "所有私网目标必须排在公网目标之前"
        );
    }

    /// 实机探测：拿到的地址必须可用（不能是假 IP / 公网 / 回环）
    ///
    /// ⚠️ 这条依赖真实网络环境，所以**只在能拿到私网地址时才断言** ——
    /// 在 CI 或没网的环境里 `lan_ip()` 会退回 127.0.0.1，那是预期行为。
    #[test]
    fn lan_ip_is_usable_or_loopback() {
        let ip = lan_ip();
        if !ip.is_loopback() {
            assert!(
                is_usable_lan_ip(&ip),
                "拿到的 {ip} 不是可用的局域网地址（假 IP 段/公网？）"
            );
        }
    }

    // ═══════════ 内容源排序（遥控端，2026-09-25 新增协议）═══════════

    /// ★★ wire 格式：**扁平** + snake_case
    ///
    /// # 这条测试守的是跨语言契约，不是内部实现
    ///
    /// 手机端（`page.html` 的 JS）与客户端（Dart `RemoteCommand.fromJson`）
    /// 都是**手写**解析这段 JSON 的，任何一方改字段名都不会有编译错误 ——
    /// 只会表现为「手机上点了没反应」。所以这里把**字节级**的形状钉死。
    ///
    /// ⚠️ Dart 侧 `models.dart` 的 `fromJson` 把 `kind` 以外的**所有字段
    ///    塞进 `args`**，也就是它只认**扁平**结构：
    /// ```text
    /// {"kind":"move_provider","id":"cycani","delta":-1}          ← ✓ 能取到
    /// {"kind":"move_provider","payload":{"id":"…","delta":-1}}   ← ✗ 取不到
    /// ```
    /// 所以这里显式断言**没有** `payload` 这一层。
    #[test]
    fn move_provider_wire_format_is_flat_snake_case() {
        // ── 反序列化：手机端发来的确切 JSON ──
        let raw = r#"{"kind":"move_provider","id":"cycani","delta":-1}"#;
        let cmd: RemoteCommand = serde_json::from_str(raw).expect("手机端这条 JSON 必须能解析");
        assert_eq!(
            cmd,
            RemoteCommand::MoveProvider {
                id: "cycani".into(),
                delta: -1,
            },
            "★ kind 必须是 snake_case 的 move_provider（枚举上没有 rename_all，靠 serde 默认）"
        );

        // ── 序列化：形状必须与上面**逐字一致**（往返不漂移）──
        let back = serde_json::to_value(&cmd).unwrap();
        assert_eq!(
            back,
            serde_json::json!({"kind":"move_provider","id":"cycani","delta":-1}),
            "序列化出来的 JSON 必须与手机端手写的那条同构"
        );
        // ★ 扁平：不能有 payload 这一层（Dart 侧只认扁平）
        assert!(
            back.get("payload").is_none(),
            "必须是扁平结构 —— Dart 的 RemoteCommand.fromJson 取不到嵌套字段"
        );
        assert!(back.get("id").is_some() && back.get("delta").is_some());

        // ── 下移同样是扁平 snake_case ──
        let down: RemoteCommand =
            serde_json::from_str(r#"{"kind":"move_provider","id":"a","delta":1}"#).unwrap();
        assert_eq!(down, RemoteCommand::MoveProvider { id: "a".into(), delta: 1 });

        // ── delta 可以是 0（无操作，但必须是合法命令，不能被拒）──
        let zero: RemoteCommand =
            serde_json::from_str(r#"{"kind":"move_provider","id":"a","delta":0}"#).unwrap();
        assert_eq!(zero, RemoteCommand::MoveProvider { id: "a".into(), delta: 0 });
    }

    /// ★ 未知 kind 仍要被拒（白名单枚举的安全边界不能被这条新协议破坏）
    #[test]
    fn unknown_kind_is_still_rejected() {
        assert!(
            serde_json::from_str::<RemoteCommand>(r#"{"kind":"move_provider"}"#).is_err(),
            "缺 id / delta 必须拒绝（不能默默变成某个默认值）"
        );
        assert!(
            serde_json::from_str::<RemoteCommand>(r#"{"kind":"move_anything"}"#).is_err(),
            "不存在的 kind 必须拒绝"
        );
        // 拼错大小写也不能进（手机端必须发 snake_case）
        assert!(
            serde_json::from_str::<RemoteCommand>(r#"{"kind":"MoveProvider","id":"a","delta":-1}"#)
                .is_err(),
            "驼峰 kind 必须拒绝 —— 协议只有 snake_case 一种写法"
        );
    }

    /// ★★ 边界：越界 / 不存在的 id —— 协议层**一律照收**，不 panic
    ///
    /// # 为什么"照收"而不是"拒绝"
    ///
    /// 照 `PrevEpisode` 的做法：第一集再点上一集，协议层**不报错**，
    /// 由执行方拿到空结果后静默忽略。理由写在 `MoveProvider` 的文档里
    /// —— Rust 侧看不到源列表顺序，在这里判越界只能靠猜。
    ///
    /// 这条测试锁死的是「**协议层不会因为越界/脏数据崩掉**」：
    /// 手机端的列表可能因为轮询间隔而过期，那是正常情况，不是攻击。
    #[test]
    fn move_provider_boundaries_do_not_panic() {
        let h = RemoteHub::new();

        // ① 第一项上移（-1）—— 越界，仍然入队
        h.push_command(RemoteCommand::MoveProvider { id: "first".into(), delta: -1 });
        // ② 最后一项下移（+1）—— 越界，仍然入队
        h.push_command(RemoteCommand::MoveProvider { id: "last".into(), delta: 1 });
        // ③ 不存在的 id（手机端缓存过期）
        h.push_command(RemoteCommand::MoveProvider { id: "ghost-源-🚀".into(), delta: -1 });
        // ④ 极端 delta（不做算术，只透传 —— 不能溢出 panic）
        h.push_command(RemoteCommand::MoveProvider { id: "x".into(), delta: i32::MIN });
        h.push_command(RemoteCommand::MoveProvider { id: "x".into(), delta: i32::MAX });

        let cmds = h.take_commands();
        assert_eq!(cmds.len(), 5, "5 条边界命令都要入队（协议层不判越界）");
        assert_eq!(
            cmds[0],
            RemoteCommand::MoveProvider { id: "first".into(), delta: -1 }
        );
        assert_eq!(
            cmds[2],
            RemoteCommand::MoveProvider { id: "ghost-源-🚀".into(), delta: -1 },
            "中文 + emoji 的 id 也要原样透传（前端才能如实记日志）"
        );

        // 取走后队列清空 —— 不会被重复执行
        assert!(h.take_commands().is_empty());
    }

    /// ★★ `POST /api/cmd` 的请求体形状：`pin` + **扁平**的命令字段
    ///
    /// # 这条测的是什么
    ///
    /// `server.rs` 的 `post_cmd` 用：
    /// ```rust
    /// struct CmdBody { pin: String, #[serde(flatten)] command: RemoteCommand }
    /// ```
    /// **serde 的 `flatten` 遇到内部 tag 枚举是有坑的** ——
    /// flatten 会把剩余字段缓冲成一个 map 再交给 `RemoteCommand`，
    /// 而内部 tag（`#[serde(tag = "kind")]`）在这个路径上的行为
    /// 与直接解析**不完全相同**（字段顺序、数字类型推断都可能不同）。
    ///
    /// 所以我在这里用**与 `post_cmd` 逐字相同**的结构体形状复现一遍，
    /// 把「手机端那条 JSON 能被服务端收下」这件事钉死在 `--lib` 里。
    ///
    /// ⚠️ 这是**形状的副本**，不是 `server.rs` 的那个类型（它是私有的，
    ///    且我不该为了测试去改它的可见性）。
    ///    真·端到端（起真服务 + 真 HTTP POST）由 `tests/` 里的临时集成
    ///    测试覆盖，见本任务报告。
    #[test]
    fn cmd_body_flatten_accepts_flat_move_provider() {
        /// 与 `server.rs::CmdBody` **逐字相同**的形状
        #[derive(serde::Deserialize)]
        struct CmdBody {
            pin: String,
            #[serde(flatten)]
            command: RemoteCommand,
        }

        let body = r#"{"pin":"123456","kind":"move_provider","id":"cycani","delta":-1}"#;
        let parsed: CmdBody = serde_json::from_str(body).expect("flatten + 内部 tag 必须能解析");
        assert_eq!(parsed.pin, "123456", "pin 不能被 flatten 吃掉");
        assert_eq!(
            parsed.command,
            RemoteCommand::MoveProvider { id: "cycani".into(), delta: -1 },
            "★ 命令字段必须是扁平的（同层），不能是嵌套 payload"
        );

        // 嵌套写法必须被拒 —— 这正是要防的那个错误 wire 格式
        let nested = r#"{"pin":"123456","kind":"move_provider","payload":{"id":"a","delta":-1}}"#;
        assert!(
            serde_json::from_str::<CmdBody>(nested).is_err(),
            "嵌套 payload 必须被拒（Dart 侧也取不到它，两边都会坏）"
        );
    }

    /// 排序命令的 `pin` 是 `CmdBody` 的**必需**字段 —— 不能省略
    #[test]
    fn cmd_body_requires_pin() {
        #[derive(serde::Deserialize)]
        struct CmdBody {
            pin: String,
            #[serde(flatten)]
            command: RemoteCommand,
        }
        assert!(
            serde_json::from_str::<CmdBody>(r#"{"kind":"move_provider","id":"a","delta":-1}"#)
                .is_err(),
            "不带 pin 必须被拒（不能变成无鉴权的后门）"
        );
    }

    /// ★ 源列表要能带中文名与启用状态往返（手机端渲染靠它）
    #[test]
    fn provider_entries_roundtrip_with_names() {
        let h = RemoteHub::new();
        let st = RemoteState {
            has_media: true,
            providers: vec![
                ProviderEntry { id: "cycani".into(), name: "次元城".into(), enabled: true },
                ProviderEntry { id: "cctv".into(), name: "央视".into(), enabled: false },
            ],
            ..Default::default()
        };
        h.update_state(st);
        let got = h.state();
        assert_eq!(got.providers.len(), 2);
        assert_eq!(got.providers[0].name, "次元城", "中文名要原样往返");
        assert!(got.providers[0].enabled);
        assert!(!got.providers[1].enabled, "停用的源也在列表里（保留位置）");

        // 序列化给手机端的形状（page.html 按这三个字段读）
        let j = serde_json::to_value(&got).unwrap();
        assert_eq!(
            j["providers"],
            serde_json::json!([
                {"id":"cycani","name":"次元城","enabled":true},
                {"id":"cctv","name":"央视","enabled":false}
            ])
        );
    }

    /// ★★ 老版本客户端上报（没有 `providers` 字段）**不能**让遥控挂掉
    ///
    /// # 这条守的是一个真实风险
    ///
    /// `RemoteState` 是手机端每次轮询都读的接口。如果新加的
    /// `providers` 没有 `#[serde(default)]`，那么**任何**一份不带该字段的
    /// 上报（老版本 Dart、测试夹具、`.probe` 脚本）都会反序列化失败 ——
    /// 而 `remote_report_state` 的失败会让**整个状态上报停摆**，
    /// 表现为「手机上看不到任何播放信息」，远比"少个排序面板"严重。
    ///
    /// ⚠️ 这里必须给**全套既有字段**、只缺 `providers` ——
    ///    否则测的就变成"别的字段有没有 default"了。
    ///    （我第一版只给三个字段，报的是
    ///    `missing field 'episode_order'` —— 那是**既有**行为，
    ///    与本次新增无关，写在这里免得下一个人重踩。）
    #[test]
    fn remote_state_without_providers_still_parses() {
        // 老版本 Dart `RemoteState.toJson()` 的**完整**输出，只是没有 providers
        let old = r#"{
            "playing": true, "title": "新闻联播",
            "episode_order": 3, "episode_count": 27,
            "position": 120, "duration": 1800,
            "volume": 80, "muted": false,
            "sources": [["l1","线路1"]], "current_source": "l1",
            "episodes": [[3,"第3集"]], "has_media": true,
            "intro_start": null, "intro_skip": null,
            "outro_skip": null, "outro_end": null,
            "auto_skip": false, "skip_editing": null
        }"#;
        let st: RemoteState = serde_json::from_str(old).expect("老版本上报必须能解析");
        assert!(st.playing);
        assert_eq!(st.title, "新闻联播");
        assert_eq!(st.episode_order, 3);
        assert!(st.providers.is_empty(), "缺省就是空列表（手机端不显示排序面板）");

        // enabled 缺省应为 true（不能把源画成"停用"）
        let e: ProviderEntry = serde_json::from_str(r#"{"id":"a","name":"A"}"#).unwrap();
        assert!(e.enabled, "enabled 缺省必须是 true");
    }
}
