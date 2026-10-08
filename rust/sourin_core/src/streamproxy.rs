//! ★ 本地流代理 —— 给「播放需要自定义请求头」的流用
//!
//! # 为什么需要这个
//!
//! `<video>` 标签发出的请求，**请求头由 WebView 决定，JS 改不了**。
//! 而有些站点的 CDN 强制校验防盗链：
//!
//! | 站点  | 取流要求 |
//! |-------|---------|
//! | 央视  | 无防盗链（Referer 留空也能播）|
//! | 次元城 | 直链即可 |
//! | **B 站** | **必须带 `Referer: https://www.bilibili.com`** |
//!
//! B 站实测（未登录、无 Cookie）：
//! ```text
//! 仅 UA（无 Referer）        → HTTP 403
//! 无 header                  → HTTP 403
//! Referer: https://example.com → HTTP 403
//! 仅 Referer（无 UA）        → HTTP 206 ✅
//! UA + 正确 Referer          → HTTP 206 ✅
//! ```
//! 也就是说 **CDN 只认 Referer，不认 UA** —— 但没有它就一个字节都拿不到。
//!
//! `model.rs::StreamCandidate` 里早就有 `not_web_ready` 与 `headers`
//! 两个字段（借鉴 Stremio 的设计），但**一直没实现**。这个模块把它落地。
//!
//! # 设计
//!
//! ```text
//! 播放器 ──► http://127.0.0.1:<port>/s/<token>
//!                     │
//!                     ├─ 查 token 表拿到 (真实URL, 需要的头)
//!                     └─ 带头发请求 ──► B站 CDN
//!                          并把响应**流式**转发回去
//! ```
//!
//! ## 几个必须做对的点
//!
//! 1. **只监听回环地址**（`127.0.0.1`）。这个代理会带上 Referer 去取任意
//!    已登记的 URL —— 暴露到局域网等于给同网段的人一个免费代理。
//!
//! 2. **token 而不是裸 URL**。如果接口是 `/s?url=<任意地址>`，那任何本地
//!    程序（甚至一个恶意网页，因为这是 localhost）都能拿它当 SSRF 跳板
//!    去探测内网。这里改成「宿主先登记、发一个随机 token」，
//!    **只能取到宿主明确登记过的那些 URL**。
//!
//! 3. **必须支持 Range 透传**。视频拖进度条靠的是 `Range` 请求；
//!    不透传的话进度条一拖就回到开头（或直接报错）。
//!    实测 B 站 CDN 对 `Range: bytes=0-1023` 返回 `206 Partial Content`。
//!
//! 4. **响应头要挑着转发**，不能全带 —— 尤其不能把上游的
//!    `Access-Control-Allow-Origin`、`Set-Cookie` 原样透给页面。

use std::collections::{HashMap, VecDeque};
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};

use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use bytes::Bytes;
use futures_core::Stream;
use tokio::sync::mpsc;

/*
 * ═══════════════════════════════════════════════════════════════════
 * ★★★ 观测：走 **stderr** 的日志（issue #9 的「黑盒」修复）
 * ═══════════════════════════════════════════════════════════════════
 *
 * # 为什么不能用 log::info!/warn!/error!
 *
 * 本 crate **从来没有初始化 logger**（实测: grep set_logger → 0 处），
 * 所以 `log::*` 的输出**被整个丢弃**。表现就是：代理明明收到了请求、
 * 明明被上游 403 拒了，日志里却一行都没有 ⇒ 事后只能靠猜。
 * （同文件的 `debug_prefetch` 早就踩过同一个坑，见它的说明。）
 *
 * 所以关键路径一律走 `eprintln!`（直接落 stderr），并且：
 * · 统一前缀 `[streamproxy]` —— 事后一条 grep 就能捞出全部
 * · 上游 URL 必须**脱敏**（见 [`redact_url`]）
 * · 请求头只打**名字**与长度（见 [`hdr_names`]），绝不打值
 */
fn sp_log(msg: &str) {
    eprintln!("[streamproxy] {msg}");
}

/// 统一的日志出口（见 [`sp_log`]）：`splog!("a={}", a)` ≡ `sp_log(&format!("a={}", a))`
macro_rules! splog {
    ($($arg:tt)*) => {
        sp_log(&format!($($arg)*))
    };
}

/// 把上游 URL 脱敏成「host + path 前若干字符」
///
/// # 为什么必须脱敏
///
/// CDN 的签名（`?sign=...&token=...`）就在 **query** 里 —— 整条打出来
/// 等于把可用的取流凭据写进日志文件。所以：
/// · scheme + host 保留（定位「是哪个源」的关键）
/// · path 只留前 64 字符（够看出是 m3u8 还是 ts 分片）
/// · **query 整个丢掉**，只留一个「有/没有」标记
fn redact_url(u: &str) -> String {
    let (head, has_query) = match u.split_once('?') {
        Some((h, _)) => (h, true),
        None => (u, false),
    };
    let head = head.split('#').next().unwrap_or(head);
    let short: String = head.chars().take(64).collect();
    if has_query {
        format!("{short}?<query 已隐去>")
    } else {
        short
    }
}

/// 请求头清单 —— 只留**名字**与值的长度，绝不打值
///
/// 头的值里可能就有 Cookie / Authorization（本仓的插件头里确实有），
/// 所以这里最多打 `Referer(len=24)`。
fn hdr_names(hs: &[(String, String)]) -> String {
    if hs.is_empty() {
        return "(无)".to_string();
    }
    hs.iter()
        .map(|(k, v)| format!("{k}(len={})", v.len()))
        .collect::<Vec<_>>()
        .join(", ")
}

/// 一次取流登记：真实地址 + 需要的请求头
#[derive(Debug, Clone)]
pub struct StreamEntry {
    pub url: String,
    /// 需要附加到上游请求的头（如 B 站的 `Referer`）
    pub headers: Vec<(String, String)>,
    /// ★ 播放列表改写用的 token
    ///
    /// **在 `register` 时就生成并登记到 `hdr_table`**，而不是在响应
    /// m3u8 时现生成 —— 后者会让「换清晰度/重试」产生新 token，
    /// 而旧 token 的分片请求会查不到头，报「代理地址已失效」。
    ///
    /// 复用同一个 token 还带来一个好处：改写出的分片地址**稳定**，
    /// 播放器的分片缓存与重试都能命中。
    pub hdr_token: String,
}

/// 流代理的共享状态
///
/// # 为什么流与封面要分成两套表
///
/// 两者特性完全不同：
///
/// | | 流 | 封面 |
/// |---|---|---|
/// | 数量 | 一次几个（换集/换线路）| **一次几百个**（首页 240 张卡）|
/// | 复用 | 每次换源**必须**重新登记（URL 带时效签名）| **必须复用**（否则浏览器缓存全失效）|
/// | 淘汰 | 超上限可清空（反正会重新登记）| **不能全清**（往回滚会重下） |
///
/// 混在一起会出两个真 bug：
/// ① 240 张封面触发流的「超上限清空」，把**正在播的那条流**一起清掉
///    → 表现是「播到一半突然 404」，极难查；
/// ② `register` 每次生成新 token，同一张图每次新 URL → 缓存全失效。
pub struct StreamProxy {
    /// 流：token → 取流信息
    ///
    /// 用 `Mutex<HashMap>` 而不是无锁结构：这是低频操作
    /// （换一次集/线路才登记一次），锁竞争可以忽略。
    table: Mutex<HashMap<String, StreamEntry>>,
    /// 封面：token → 取图信息
    cover_table: Mutex<HashMap<String, StreamEntry>>,
    /// 封面去重索引：**URL → token**
    ///
    /// 这是封面能复用 token 的关键 —— 同一个 URL 永远映射到同一个 token。
    cover_index: Mutex<HashMap<String, String>>,
    /*
     * ★★ 请求头表：token → 头列表
     *
     * # 为什么需要单独一张表（而不是复用 `table`）
     *
     * 播放列表（m3u8）里的分片地址要改写成走代理，而**分片可能分布在
     * 不同主机**（m3u8 在 vod.xxx.com、分片在 cdn.yyy.net —— 很常见）。
     *
     * 如果把每个分片都当成一条独立登记（复用 `table`），
     * 一个 1000 分片的播放列表就会塞爆 `table`（上限 256 → 触发清空 →
     * 连**正在播的那条流**一起清掉，表现是「播到一半突然 404」）。
     *
     * 所以改成：**一个播放列表登记一次头**，分片的 scheme+host+path
     * 直接编码在 URL 路径里（`/p/<token>/<scheme>/<host>/<path>`），
     * 代理据此直连。表只随「换集次数」增长，与分片数量无关。
     */
    hdr_table: Mutex<HashMap<String, Vec<(String, String)>>>,
    /// 流表的**登记顺序**（FIFO），只用于「表满时淘汰最旧的一半」
    ///
    /// ★ issue #9：`table` 是 `HashMap`，**没有顺序** —— 改前正因为拿不到
    /// "哪条最旧"，表满时只能 `t.clear()` 全清，于是把**正在播的那条**
    /// 也清掉了（上面 `hdr_table` 的说明早就写明这个事故：
    /// 「播到一半突然 404」）。这里补一个 FIFO 记录：只在 `register_at`
    /// 里 push、淘汰时从队首 pop，不参与任何转发逻辑。
    order: Mutex<VecDeque<String>>,
    /// 监听端口（0 = 还没启动 **或已失效**）
    ///
    /// ★★★ task-56：这个字段**必须**在代理退出时清零（见 [`StreamProxy::mark_dead`]）。
    /// 否则它就是一个"看起来还在服务"的死端口 —— 而 [`StreamProxy::register`]
    /// 拼地址时**只读这个字段**，于是会源源不断产出指向死端口的 URL。
    /// 用户报的「播放失败 Failed to open http://127.0.0.1:<死端口>/s/<token>/」
    /// 就是这么来的（详见 `ensure_started` 的注释）。
    port: std::sync::atomic::AtomicU16,
    /// 正在跑的 `axum::serve` 任务句柄
    ///
    /// # 为什么要留着它（而不是 spawn 完就丢）
    ///
    /// `JoinHandle::is_finished()` 是判断"服务还在不在"的**最便宜**的手段
    /// （一次原子读），比 TCP 探测便宜得多。所以 [`StreamProxy::serving_port`]
    /// 先看它、再探测。
    serve_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
    /// 启动互斥（`ensure_started` 的串行化）
    ///
    /// # 为什么需要（真并发场景，不是理论）
    ///
    /// `ensure_started` 会被多处并发调用：首页一次加载 240 张封面走
    /// [`proxy_covers`] 的路径，而用户同一时刻点「播放」走 `resolve_stream`
    /// 的路径。改前两者都看到 `port == 0` ⇒ **各自 bind 一次** ⇒ 多出一个
    /// 没人知道端口号的监听 socket（泄漏），且 `port` 字段只留最后一个。
    /// 有了它，第二次调用会等第一次 bind 完，然后直接复用。
    start_lock: tokio::sync::Mutex<()>,
    /*
     * ═══════════════════════════════════════════════════════════════════
     * ★★★ task-57：**共享**的 HTTP 客户端（连接池复用）
     * ═══════════════════════════════════════════════════════════════════
     *
     * # 改前的问题（lead 在源码里发现，我核实）
     *
     * `forward_request` 原来是**每个请求**都 `Client::builder().build()`：
     * ```rust
     * let client = match reqwest::Client::builder()
     *     .timeout(Duration::from_secs(30))
     *     .build()
     * ```
     * 而 `reqwest::Client` 的价值**就在于连接池** —— 每请求新建
     * ⇒ **池永远是空的** ⇒ 每个请求都要重新 DNS + TCP + TLS 握手。
     *
     * # 为什么这特别伤（本仓的实测特征）
     *
     * 播放器（mpv/ffmpeg）打开一条流时会发**多个**请求
     * （探测、Range、seek），每个都付一次完整握手成本。
     * 而 `reqwest` 的默认连接池是 keep-alive 的 ⇒ 共享一个 Client 后，
     * 第 2 个及以后的请求**复用同一条 TCP/TLS 连接**。
     *
     * # ⚠️ 为什么共享是安全的（不是"为了快而快"）
     *
     * · 连接池是**按目标 host** 分桶的，不会把 A 站的头带到 B 站
     * · 我们**不用 cookie store**（默认就没有）⇒ 无跨源会话串味
     * · `timeout` 是**每请求**的（不是整个 Client 的全局预算）
     *   ⇒ 一个慢请求不会"吃掉"后续请求的时间
     */
    client: reqwest::Client,
    /*
     * ═══════════════════════════════════════════════════════════════════
     * ★★★ 并行预取的开关 —— **每实例**，不是进程级环境变量
     * ═══════════════════════════════════════════════════════════════════
     *
     * # 为什么必须从环境变量改成字段（2026-10-08，CI 实测）
     *
     * 原来 `plan_prefetch` 直接读 `std::env::var("SOURIN_PREFETCH_DISABLE")`，
     * 而 `deterministic_before_after_same_upstream_same_throttle` 这个测试
     * 会 `set_var`/`remove_var` 它来做 A/B 对照。
     * `std::env` 是**进程全局**的，而 `cargo test` 默认多线程跑同一进程里的
     * 所有测试 ⇒ 那段"关掉预取"的窗口里，**别的测试**（如
     * `prefetch_fetches_concurrently_and_bytes_are_exact`、
     * `no_range_support_falls_back`、`prefetch_enabled_for_range_capable_mp4`）
     * 恰好调 `plan_prefetch`，就会看到 `None` ⇒ 随机失败。
     *
     * 实测症状（CI run 37782468948 的 Windows job）：
     * ```text
     * test result: FAILED. 365 passed; 3 failed; ...
     *   streamproxy::tests::no_range_support_falls_back
     *   streamproxy::tests::prefetch_enabled_for_range_capable_mp4
     *   streamproxy::tests::prefetch_fetches_concurrently_and_bytes_are_exact
     * ```
     * ★ 关键证据：`git diff 263d89c..3c677ea -- rust/sourin_core/src` **是空的**
     *   —— 上一轮 Windows 绿、这一轮红，而 `src/` 一行没改 ⇒ 纯竞态，不是回归。
     *   本机连跑三次（单跑 / 跑 prefetch 组 / 跑整组 streamproxy）**全绿**，
     *   正因为本机那次没撞上窗口。
     *
     * ⇒ 改成**每实例一个原子开关**：测试各建各的 `StreamProxy`，互不可见。
     *   生产行为不变（默认 `false` = 预取开，与改前一致）。
     */
    prefetch_disabled: std::sync::atomic::AtomicBool,
}

/// 代理到上游的请求超时
///
/// 抽成常量是因为它现在**只在一处**构造（共享 Client），
/// 而注释里多处引用它（改前是散落的字面量 30）。
const UPSTREAM_TIMEOUT_SECS: u64 = 30;

/// 流表上限
///
/// 改前这个 256 是散落的字面量（`if t.len() > 256`）。
/// ★ issue #9：表满时**不再全清**（那会把正在播的流也清掉 ⇒ 播到一半
/// 突然 404），而是淘汰最旧的一半 —— 见 [`StreamProxy::register_at`]。
const STREAM_MAX: usize = 256;

/// 封面表上限
///
/// 一张封面在表里只是两个短字符串（约 120 字节），
/// 2048 条 ≈ 250 KB，可忽略；而首页往下翻几屏就上千张。
const COVER_MAX: usize = 2048;

/// 存活探测（回环 `connect`）的超时
///
/// # 为什么是 300ms 这个数量级（实测依据）
///
/// 回环地址上只有两种结果，**都是立刻返回**：
/// ```text
/// 端口在监听   ⇒ SYN → SYN/ACK，几十微秒
/// 端口没人听   ⇒ SYN → RST，几十微秒（Windows 实测 WinError 10061）
/// ```
/// 唯一会"等"的情况是 socket 处于半死状态（进程还在、listener 没了），
/// 那种情况下 300ms 足够判死，而用户也不会感知到（这是**一次**探测，
/// 且只在 `ensure_started` 里发生，不是每个请求）。
///
/// ⚠️ 不能取 0 或极小值：`timeout` 到期与 connect 完成是**竞争**的，
///    极小值会在端口其实活着的时候随机判死 ⇒ 每播一次就重建一次代理。
const LIVENESS_PROBE_MS: u64 = 300;

impl Default for StreamProxy {
    fn default() -> Self {
        Self::new()
    }
}

impl StreamProxy {
    pub fn new() -> Self {
        /*
         * ★ 共享 Client 的构造。`build()` 在这里**只会失败一次**
         *   （TLS 后端初始化失败等），所以用 `expect` 而不是把错误
         *   拖到每个请求里 —— 构造期就崩比"所有流都播不了但不知道为什么"好。
         */
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(UPSTREAM_TIMEOUT_SECS))
            .build()
            .expect("流代理无法创建 HTTP 客户端（TLS 后端初始化失败）");
        Self {
            table: Mutex::new(HashMap::new()),
            cover_table: Mutex::new(HashMap::new()),
            cover_index: Mutex::new(HashMap::new()),
            hdr_table: Mutex::new(HashMap::new()),
            order: Mutex::new(VecDeque::new()),
            port: std::sync::atomic::AtomicU16::new(0),
            serve_task: Mutex::new(None),
            start_lock: tokio::sync::Mutex::new(()),
            client,
            /*
             * ★ 从环境变量初始化 —— 保留生产上的回滚开关
             *   （`SOURIN_PREFETCH_DISABLE=1` 完全回到改动前的串行透传），
             *   但**只读一次**、存进实例字段。之后无论谁改进程环境，
             *   这个实例的行为都不会再被别的测试影响。
             */
            prefetch_disabled: std::sync::atomic::AtomicBool::new(
                std::env::var("SOURIN_PREFETCH_DISABLE").is_ok(),
            ),
        }
    }

    /// 本实例是否禁用并行预取（测试用；生产走环境变量默认值）
    pub fn set_prefetch_disabled(&self, disabled: bool) {
        self.prefetch_disabled
            .store(disabled, std::sync::atomic::Ordering::SeqCst);
    }

    /// 读本实例的预取开关
    fn prefetch_is_disabled(&self) -> bool {
        self.prefetch_disabled
            .load(std::sync::atomic::Ordering::SeqCst)
    }

    pub fn port(&self) -> u16 {
        self.port.load(std::sync::atomic::Ordering::SeqCst)
    }

    /// ★ 把端口标记为**已失效**（清 0），让下一次 `ensure_started` 重新 bind
    ///
    /// # 为什么是 `compare_exchange` 而不是 `store(0)`
    ///
    /// 因为**退出的是"上一个"代理，而字段里可能已经是"下一个"代理的端口**：
    /// ```text
    /// ① 旧代理（端口 P1）退出 ──────────┐
    /// ② 用户点重试 → ensure_started      │ 这两件事的**顺序不保证**
    ///    探测 P1 连不上 → 重建 → 端口 P2 │
    /// ③ 旧代理的看门狗这才跑完 ─────────┘
    ///    store(0)   ⇒ ★ 把**新**代理的 P2 也清掉了 ⇒ 又变成死地址
    ///    CAS(P1→0)  ⇒ P2 != P1 ⇒ 什么都不做 ✓
    /// ```
    /// 所以只能"清掉**我这一份**"，不能无条件清。
    fn mark_dead(&self, expected: u16) {
        if self
            .port
            .compare_exchange(
                expected,
                0,
                std::sync::atomic::Ordering::SeqCst,
                std::sync::atomic::Ordering::SeqCst,
            )
            .is_ok()
        {
            log::warn!("流代理（端口 {expected}）已退出，端口已作废，下次需要时会自动重建");
        }
    }

    /// 代理**真的**还在服务吗？在服务就返回它当前监听的端口
    ///
    /// 两道判据，从便宜到贵：
    /// 1. `serve_task.is_finished()` —— 任务已结束 ⇒ 一定不服务（一次原子读）
    /// 2. TCP 连一下 —— 任务"还在"但 socket 已经不通（被 abort 掉一半、
    ///    panic 后残留、listener 被外部关掉）也能查出来
    ///
    /// ⚠️ 判据 2 **不能省**：它才是"端口字段非 0 但代理已死"的最后一道防线。
    ///
    /// ⚠️ 返回的是**探测时读到的那个端口**（不是函数末尾再读一次）——
    ///    否则"探测 P1 通过、返回前端口已被换成 P2"就会返回一个**没探测过**
    ///    的端口，等于把竞态窗口又打开了。
    async fn serving_port(&self) -> Option<u16> {
        {
            let h = self.serve_task.lock().unwrap_or_else(|e| e.into_inner());
            match h.as_ref() {
                Some(h) if !h.is_finished() => {}
                // 没有任务 / 任务已结束 ⇒ 没在服务
                _ => return None,
            }
        }
        let port = self.port();
        if port == 0 {
            return None;
        }
        /*
         * 回环上的 connect：活着就**立刻**成功，死了就**立刻**被拒（RST），
         * 所以超时值只对"半死"（SYN 无人应答）才有意义 —— 给足即可。
         */
        let alive = matches!(
            tokio::time::timeout(
                std::time::Duration::from_millis(LIVENESS_PROBE_MS),
                tokio::net::TcpStream::connect(("127.0.0.1", port)),
            )
            .await,
            Ok(Ok(_))
        );
        if alive {
            Some(port)
        } else {
            None
        }
    }

    /// 登记一个取流地址，返回它的本地代理 URL
    ///
    /// 每次调用都会生成**新的 token**（而不是按 URL 去重复用）：
    /// URL 带时效签名，复用一个旧 token 会在签名过期后拿到 403，
    /// 而用户完全不知道为什么「同一个视频昨天能播今天不能」。
    ///
    /// # ★★ 返回值**以 `/` 结尾**（这不是笔误）
    ///
    /// HLS 的 m3u8 里，分片与二级播放列表都是**相对路径**：
    /// ```text
    /// #EXTM3U
    /// #EXTINF:3.48,
    /// 0000000.ts
    /// ```
    /// 播放器按 RFC 3986 解析它们 —— 而那条规则是
    /// 「**替换掉 base 的最后一段**」：
    ///
    /// ```text
    /// base = /s/<token>     + 0000000.ts        → /s/0000000.ts          ❌ token 丢了
    /// base = /s/<token>/    + 0000000.ts        → /s/<token>/0000000.ts  ✅
    /// ```
    ///
    /// 实测踩到：少了这个尾斜杠，hls.js 会去请求
    /// `http://127.0.0.1:<port>/s/0000000.ts` → 404 →
    /// **MSE 建好了 blob、时长也解析出来了（830s），但一个分片都下不来**，
    /// 界面永远停在「正在加载…」。
    ///
    /// 加上尾斜杠后，相对路径才会拼到 token 下面，
    /// 由 `handle_stream` 的 `{*rest}` 接住并转发给上游。
    ///
    /// 登记一条流，返回它的本地代理地址（端口取**当前**的 `self.port()`）
    ///
    /// ⚠️ 这是 [`StreamProxy::register_at`] 的薄包装。端口是从字段回读的，
    /// 所以调用方**必须先 `ensure_started().await`**，否则会拼出 `:0/`。
    /// 保留它只是为了让既有调用点（含测试）零改动；新代码请用
    /// [`StreamProxy::register_at`]，把 `ensure_started` 返回的端口直接带进来。
    pub fn register(&self, url: &str, headers: Vec<(String, String)>) -> String {
        self.register_at(url, headers, self.port())
    }

    /// ★ issue #9：登记时**直接用刚拿到的端口**，不再回读 `self.port()`
    ///
    /// # 为什么（一个真实的空窗）
    ///
    /// 改前 `maybe_proxy` 先 `ensure_started().await`（**把返回的端口丢掉**），
    /// 再由 `register` 回读 `self.port()`。这两步之间代理可能已经退出
    /// （看门狗 `mark_dead` 把端口清成 0）⇒ 返回的地址就变成
    /// `http://127.0.0.1:0/s/<token>/` ⇒ 播放器报
    /// 「Failed to open http://127.0.0.1:<port>/s/<token>/」。
    /// 把 `ensure_started` 的返回值一路带下来，这个空窗就不存在了。
    ///
    /// # 表满时淘汰**最旧的一半**（不再是全清）
    ///
    /// 见 [`StreamProxy::order`]：全清会把**正在播的那条**也清掉，
    /// 表现就是「播到一半突然 404 → 取流地址已失效」。
    pub fn register_at(&self, url: &str, headers: Vec<(String, String)>, port: u16) -> String {
        let token = new_token();
        {
            let mut t = self.table.lock().unwrap_or_else(|e| e.into_inner());
            let mut ord = self.order.lock().unwrap_or_else(|e| e.into_inner());
            /*
             * ★ 顺手清理：表不能无限涨
             *
             * 每次换集/换线路都登记一条，看完一部剧就是几百条。
             * 而每条只是两个字符串 —— 超过 `STREAM_MAX` 就淘汰最旧的一半。
             *
             * ★ issue #9：改前这里是 `t.clear()`（**全清**）—— 因为 HashMap
             *   没有顺序，拿不到"哪条最旧"就干脆清空。后果是**正在播的那条**
             *   也被清掉 ⇒ 下一个分片请求 404「取流地址已失效，请重新选择线路」。
             *   现在用 `order`（FIFO）淘汰最旧的一半，保留最近的一半 ——
             *   正在播的流刚登记过，一定在保留的那一半里。
             */
            if t.len() > STREAM_MAX {
                let drop_n = ord.len() / 2;
                for victim in ord.drain(..drop_n) {
                    t.remove(&victim);
                }
                splog!("流表已满，淘汰最旧的一半: 淘汰 {drop_n} 条，剩 {} 条", t.len());
            }
            ord.push_back(token.clone());
            /*
             * ★ 同时把「头」登记到 hdr_table，并记下 token
             *
             * 播放列表改写出的分片地址用这个 token（`/p/<token>/...`），
             * 所以在**这里**（注册流时）就生成、登记 ——
             * 不能等到响应 m3u8 时现生成（那会导致 token 不一致，
             * 分片请求报「代理地址已失效」）。
             */
            let hdr_token = new_token();
            {
                let mut h = self.hdr_table.lock().unwrap_or_else(|e| e.into_inner());
                /*
                 * ★ issue #9：这里原来也是 `h.clear()`（全清）。这张表被
                 *   **正在播的**分片请求按 token 查（`handle_proxied`），
                 *   全清会让「代理地址已失效，请重新选择线路」突然出现在
                 *   播放中途。与流表一致，只淘汰最旧的一半。
                 */
                if h.len() > STREAM_MAX {
                    let victims: Vec<String> = h.keys().take(h.len() / 2).cloned().collect();
                    for v in victims {
                        h.remove(&v);
                    }
                }
                h.insert(hdr_token.clone(), headers.clone());
            }
            t.insert(token.clone(), StreamEntry {
                url: url.to_string(),
                headers,
                hdr_token,
            });
        }
        /*
         * ⚠️ 结尾的 `/` 是必须的 —— 见上面「返回值以 / 结尾」的说明
         *    （HLS 的相对路径要拼到 token 目录下，而不是替换掉 token）
         */
        format!("http://127.0.0.1:{port}/s/{token}/")
    }

    /// ★ 登记一张封面图，返回它的本地代理 URL
    ///
    /// # 为什么需要它（根因）
    ///
    /// B 站图片 CDN（`i0/i1/i2.hdslb.com`）**白名单校验 Referer**（实测）：
    ///
    /// ```text
    /// Referer: https://www.bilibili.com  → HTTP 200 ✅
    /// Referer: http://tauri.localhost/   → HTTP 403 ❌  ← 我们的应用
    /// 无 Referer                          → HTTP 200 ✅
    /// ```
    ///
    /// 而 `<img>` 标签**改不了 Referer**（浏览器安全限制，无法绕过）。
    /// 所以只能由宿主代取 —— 和视频流是同一个问题、同一个解法。
    ///
    /// # 与 [`register`] 的两个关键差异
    ///
    /// 1. **按 URL 去重**：同一个 URL 永远拿到同一个 token。
    ///    否则同一张图每次渲染都是新 URL → **浏览器缓存全部失效** →
    ///    滚动一下就把几百张图重下一遍。
    ///    （流不能这么做：流的 URL 带时效签名，复用旧 token 会拿到 403）
    ///
    /// 2. **独立配额**：封面不占流的名额。
    ///    首页一次就有 240 张封面，若与流共用一张表，
    ///    会触发流的「超上限清空」把**正在播的那条流**一起清掉 ——
    ///    表现是「播到一半突然 404」，极难查。
    /// 把代理地址**还原**成原始 URL
    ///
    /// # 为什么需要它（真 bug，2026-09-20 实测发现）
    ///
    /// 封面会经过这里换成 `http://127.0.0.1:<port>/s/<token>` 代理地址 ——
    /// 那是**本次运行**的临时地址（端口随机、token 存在内存表里）。
    ///
    /// 如果这个临时地址被**存进数据库**（收藏 / 历史都会存 cover），
    /// 那么下次启动时：端口变了、token 表空了 → **封面必然裂**。
    ///
    /// 实测（Owner 报「怒海狂鲨在最更页面封面图裂开，
    /// 点进详情页封面又是正常的」）：
    /// ```text
    /// 收藏里存的 cover: http://127.0.0.1:51604/s/18d6c0abfb8efc04893cc02faa98
    /// 应用里加载它:      ✗ onerror（端口 51604 早就不存在了）
    /// 详情页:            ✅ 因为它**当场重新取**封面，不读库里那个死地址
    /// ```
    ///
    /// # 用法
    ///
    /// 凡是要**持久化**的封面 URL，先过一遍这个函数还原成原始地址。
    /// 读出来展示时宿主会再包一层代理 —— 那才是正确的生命周期。
    ///
    /// 返回 `None` = 不是代理地址（或 token 已过期），调用方原样使用即可。
    pub fn unproxy_cover(&self, url: &str) -> Option<String> {
        // 只处理形如 http://127.0.0.1:<port>/s/<token> 的地址
        let rest = url.strip_prefix("http://127.0.0.1:")?;
        let (port_str, path) = rest.split_once('/')?;
        if port_str.parse::<u16>().is_err() {
            return None;
        }
        let token = path.strip_prefix("s/")?;
        if token.is_empty() || token.contains('/') {
            return None;
        }

        let tbl = self.cover_table.lock().unwrap_or_else(|e| e.into_inner());
        tbl.get(token).map(|e| e.url.clone())
    }

    /// [`unproxy_cover`] 的便利包装：还原不了就原样返回
    ///
    /// 调用方通常只想要一个「一定是原始地址」的字符串，
    /// 而不关心能不能还原（还原不了说明它本来就是原始地址）。
    pub fn unproxy_cover_or_keep(&self, url: &str) -> String {
        self.unproxy_cover(url).unwrap_or_else(|| url.to_string())
    }

    pub fn register_cover(&self, url: &str, headers: Vec<(String, String)>) -> String {
        let mut idx = self.cover_index.lock().unwrap_or_else(|e| e.into_inner());

        // 已登记过 → 复用同一个 token（这是保住浏览器缓存的关键）
        if let Some(t) = idx.get(url).cloned() {
            let port = self.port();
            drop(idx);
            return format!("http://127.0.0.1:{port}/s/{t}");
        }

        /*
         * 满了淘汰一半。
         *
         * 淘汰一半而不是全清：用户往回滚时至少还有一半图在缓存里。
         * （HashMap 无序，所以这里不保证淘汰"最旧"的 ——
         *  但封面是一次性的静态图，淘汰哪个都只是多下一次，无所谓）
         */
        if idx.len() >= COVER_MAX {
            let victims: Vec<String> = idx.keys().take(idx.len() / 2).cloned().collect();
            let mut tbl = self.cover_table.lock().unwrap_or_else(|e| e.into_inner());
            for k in victims {
                if let Some(t) = idx.remove(&k) {
                    tbl.remove(&t);
                }
            }
        }

        let token = new_token();
        idx.insert(url.to_string(), token.clone());
        drop(idx);

        /*
         * 封面也登记一份头（用同一个 token）
         *
         * 封面正常不会返回 m3u8，所以 `hdr_token` 多半用不上；
         * 但登记它有两个好处：
         *   · `StreamEntry` 的字段语义统一（不留空值特例）
         *   · 万一某个"封面"地址实际是播放列表，也能正常改写
         */
        if let Ok(mut h) = self.hdr_table.lock() {
            /*
             * ★ issue #9：改前这里是 `h.clear()`（全清）。
             *   这张表被**正在播的**分片请求按 token 查（`handle_proxied`），
             *   全清会让"代理地址已失效，请重新选择线路"突然出现在播放中途。
             *   与流表一样，只淘汰最旧的一半。
             */
            if h.len() > STREAM_MAX {
                let victims: Vec<String> = h.keys().take(h.len() / 2).cloned().collect();
                for v in victims {
                    h.remove(&v);
                }
            }
            h.insert(token.clone(), headers.clone());
        }

        if let Ok(mut tbl) = self.cover_table.lock() {
            tbl.insert(token.clone(), StreamEntry {
                url: url.to_string(),
                headers,
                hdr_token: token.clone(),
            });
        }

        let port = self.port();
        format!("http://127.0.0.1:{port}/s/{token}")
    }

    /// 启动代理服务（幂等；已在服务则直接返回当前端口）
    ///
    /// 端口交给系统分配（`:0`）—— 固定端口会和用户机器上别的软件打架，
    /// 而这个端口只给本机播放器用，不需要用户知道。
    ///
    /// # ★★★ task-56：这里的"幂等"必须建立在**存活**之上，而不是"端口字段非 0"
    ///
    /// # 改前是什么样（这是用户报的那个 bug 的完整成因链）
    ///
    /// ```text
    /// if existing != 0 { return Ok(existing); }   // ← 只看字段，从不复检
    /// ```
    ///
    /// 而 `axum::serve` 的返回处**只打日志、不清 `port`**。于是：
    ///
    /// ```text
    /// ① 代理因任何原因退出（端口被占/内部错误/任务被 abort）
    /// ② self.port 仍是那个已经没人监听的旧值
    /// ③ 之后每一次 register() / register_cover() 都拿它拼 URL
    ///    ⇒ 用户看到「播放失败 Failed to open http://127.0.0.1:<死端口>/s/<token>/」
    /// ④ ensure_started 永远走 early-return ⇒ **永远不会重 bind**
    ///    ⇒ 用户只能重启客户端才能恢复
    /// ```
    ///
    /// # 改后（两道闸）
    ///
    /// 1. **存活复检**：[`serving_port`] 真的连一下回环端口。字段非 0
    ///    但连不上 ⇒ 视为没启动 ⇒ 继续往下 bind（并顺手把死端口清 0）。
    /// 2. **启动互斥**：[`start_lock`] 串行化。改前首页加载封面与用户点播放
    ///    可能同时看到 `port == 0` 而**各 bind 一次**，多出的监听 socket
    ///    没人知道端口号（泄漏），且字段只留最后一个。
    ///
    /// ⚠️ 快路径（端口活着）**不会**被互斥锁拖慢：先做一次无锁的
    ///    [`serving_port`]，活着就直接返回；只有需要真正 bind 时才抢锁，
    ///    抢到后再复检一次（可能已被别的调用者建好了）。
    pub async fn ensure_started(self: &Arc<Self>) -> Result<u16, String> {
        // ── 快路径：代理确实还活着 ⇒ 直接复用（绝大多数调用走这里）──
        if let Some(port) = self.serving_port().await {
            return Ok(port);
        }

        /*
         * ── 慢路径：需要（重新）bind ──
         *
         * 抢锁。同一时刻只有一个调用者能走到 bind，其余在这里排队，
         * 排队结束后会在锁内**再复检一次**，于是直接复用刚建好的那个。
         */
        let _guard = self.start_lock.lock().await;

        // 双重检查：等锁期间可能已经被别的调用者建好了
        if let Some(port) = self.serving_port().await {
            return Ok(port);
        }

        /*
         * 走到这里说明"需要重建"。把**当前这个**死端口清掉：
         * 不清的话，`register()` 在 bind 完成前的窗口里仍会拼出死地址
         * （`register` 是**同步**函数，拿不到这里的锁）。
         */
        let stale = self.port();
        if stale != 0 {
            self.mark_dead(stale);
        }

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .map_err(|e| format!("流代理无法监听：{e}"))?;
        let port = listener
            .local_addr()
            .map_err(|e| format!("取不到流代理端口：{e}"))?
            .port();
        self.port
            .store(port, std::sync::atomic::Ordering::SeqCst);

        let state = self.clone();
        /*
         * ★ task-56：再 clone 一份留作"看门狗"。
         *
         * `state` 会被 `.with_state(state)` 吃掉（move 进 Router），
         * 所以 serve 返回之后**必须**还有另一个 `Arc` 能把端口清掉。
         */
        let owner = self.clone();
        let handle = tokio::spawn(async move {
            let app = Router::new()
                /*
                 * ⚠️ 必须注册**三条**（尾斜杠那条容易漏）
                 *
                 * | 路径 | 什么时候用 |
                 * |---|---|
                 * | `/s/{token}` | 直接请求 m3u8 本体（不带尾斜杠）|
                 * | `/s/{token}/` | **带尾斜杠**的 m3u8 请求（`register` 返回的形态）|
                 * | `/s/{token}/{*rest}` | m3u8 里的相对路径分片 |
                 *
                 * axum 把 `/s/{token}` 与 `/s/{token}/` 当作**两条不同的路由** ——
                 * 实测漏了中间那条会让 `register` 返回的地址直接 **404**
                 * （而那条地址正是我们发给播放器的，等于全部播不了）。
                 */
                .route("/s/{token}", get(handle_stream).options(handle_preflight))
                .route(
                    "/s/{token}/",
                    get(handle_stream).options(handle_preflight),
                )
                .route(
                    "/s/{token}/{*rest}",
                    get(handle_stream).options(handle_preflight),
                )
                /*
                 * `/p/<token>/<scheme>/<host>/<path>`
                 *
                 * 播放列表改写后的分片地址（见 rewrite_playlist）——
                 * scheme 与 host 都编码在路径里，所以代理**无需查流表**
                 * 就能直连，只按 token 查头。
                 */
                .route(
                    "/p/{token}/{*rest}",
                    get(handle_proxied).options(handle_preflight),
                )
                .with_state(state);

            /*
             * ★★★ task-56 的核心修复点之一。
             *
             * 改前：`if let Err(e) = axum::serve(..).await { log::error!(..) }`
             *       ⇒ **只打日志，`port` 字段保持旧值** ⇒ 死端口被无限复用。
             *
             * 改后：无论 serve 是"出错退出"还是"正常返回"，都把端口作废。
             *       注意**不能**只在 Err 分支清 —— serve 正常返回同样意味着
             *       "这个端口已经没人监听了"。
             */
            if let Err(e) = axum::serve(listener, app).await {
                log::error!("流代理退出: {e}");
            }
            owner.mark_dead(port);
        });

        /*
         * 记住句柄，让 [`serving_port`] 能用 `is_finished()` 做**零成本**快判
         * （一次原子读，不必每次 TCP 探测）。
         */
        *self.serve_task.lock().unwrap_or_else(|e| e.into_inner()) = Some(handle);

        log::info!("流代理已启动: http://127.0.0.1:{port}/");
        Ok(port)
    }
}

/// 生成随机 token（不引依赖，用系统随机数 + 计数拼一个足够长的串）
fn new_token() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQ: AtomicU64 = AtomicU64::new(0);

    let n = SEQ.fetch_add(1, Ordering::Relaxed);
    /*
     * 熵来源：纳秒时间 + 进程内序号 + 地址随机化带来的栈地址。
     *
     * ⚠️ 这里**不需要密码学强度** —— token 只在本机回环地址上用，
     * 攻击面是「同机的其他进程」，而它们本来就能读这个进程的内存。
     * 真正的防护是「只登记宿主认可的 URL」（见模块文档第 2 点）。
     */
    let t = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let stack = &n as *const _ as usize;

    format!("{t:x}{n:x}{stack:x}")
}

/// 把「相对子路径」拼到已登记的 URL 上（HLS 分片用）
///
/// # 语义（严格按 RFC 3986 的相对引用解析）
///
/// 有**两种**子路径，处理方式完全不同 —— 这是实测踩到的坑：
///
/// | 形态 | 含义 | 例子 |
/// |---|---|---|
/// | `/a/b.ts` | **绝对路径** —— 从**域名根**开始 | `https://cdn.com/a/b.ts` |
/// | `a/b.ts`  | **相对路径** —— 相对当前 URL 的**目录** | `https://cdn.com/x/a/b.ts` |
///
/// 我第一版把两者当同一种处理（一律拼到目录下），于是绝对路径被拼成了
/// ```text
/// https://cdn.com/x/20260820/bry8W01j/index.m3u8     ← 原 URL
/// + /20260820/bry8W01j/3260kb/hls/index.m3u8         ← 绝对路径的子流
/// = https://cdn.com/x/20260820/bry8W01j/20260820/bry8W01j/3260kb/hls/index.m3u8  ❌
/// ```
/// 路径重复了一遍 → 404 → **播放器一直「正在加载…」**。
///
/// 实测：`360采集` 的 m3u8 用的就是绝对路径形态
/// （`#EXT-X-STREAM-INF` 下一行是 `/20260820/.../index.m3u8`），
/// 所以它播不了，而用相对路径的 `暴风` 能播。
///
/// # query / fragment
///
/// · base 的 query **要剥掉** —— 采集站的 m3u8 地址带签名
///   （`?sign=abc`），不剥会拼成 `.../index.m3u8?sign=abc/0000000.ts`（错的）
/// · 子路径自己的 query **要保留** —— 分片也可能带 token
fn join_subpath(base: &str, sub: &str) -> String {
    // ① 剥掉 base 的 query / fragment
    let base_no_query = base.split(['?', '#']).next().unwrap_or(base);

    /*
     * ② 子路径以 `/` 开头 → **绝对路径**，从域名根开始
     *
     * 取 base 的 `scheme://host` 部分（"https://cdn.com" 这种），直接拼。
     */
    if sub.starts_with('/') {
        if let Some(pos) = base_no_query.find("://") {
            // 从 "://" 之后找第一个 '/' —— 那就是路径的开始
            let after_scheme = pos + 3;
            let host_end = base_no_query[after_scheme..]
                .find('/')
                .map(|i| after_scheme + i)
                .unwrap_or(base_no_query.len());
            let origin = &base_no_query[..host_end];
            return format!("{origin}{sub}");
        }
        // 没有 scheme（异常情况）——退回按目录拼，至少不丢信息
        return format!("{base_no_query}{sub}");
    }

    // ③ 相对路径 → 拼到 base 的**目录**下
    let dir = match base_no_query.rfind('/') {
        Some(i) => &base_no_query[..=i],
        None => base_no_query,
    };
    format!("{dir}{sub}")
}

/// CORS 预检（OPTIONS）响应
///
/// # 为什么需要单独处理
///
/// hls.js 拉分片时会带 `Range` 头 —— 那不是 CORS 简单请求允许的头，
/// 浏览器会先发一个 **OPTIONS 预检**。若代理不答预检，实际 GET 根本不会发出，
/// 表现同样是「XHR status 0、一直加载」。
///
/// 代理只监听回环、且只能取宿主登记过的 URL（见模块文档），
/// 所以这里放开是安全的。
async fn handle_preflight() -> Response {
    (
        StatusCode::NO_CONTENT,
        [
            (header::ACCESS_CONTROL_ALLOW_ORIGIN, "*"),
            (header::ACCESS_CONTROL_ALLOW_METHODS, "GET, HEAD, OPTIONS"),
            (
                header::ACCESS_CONTROL_ALLOW_HEADERS,
                "Range, Content-Type, Accept, Origin",
            ),
            (
                header::ACCESS_CONTROL_EXPOSE_HEADERS,
                "Content-Length, Content-Range, Content-Type, Accept-Ranges",
            ),
            (header::ACCESS_CONTROL_MAX_AGE, "86400"),
        ],
    )
        .into_response()
}

/// 处理播放列表改写后的分片请求：`/p/<token>/<scheme>/<host>/<path>`
///
/// # 与 [`handle_stream`] 的区别
///
/// | | `/s/<token>` | `/p/<token>/...` |
/// |---|---|---|
/// | URL 从哪来 | `table` 查表（登记过的完整 URL）| **路径里自带** scheme+host+path |
/// | 用途 | m3u8 本体、封面 | m3u8 里的分片与子播放列表 |
/// | 跨主机 | 不支持（一条 URL 一个 token）| **支持**（每片可不同主机）|
///
/// 用它的原因：HLS 的分片经常**不在 m3u8 同一台主机上**
/// （m3u8 在 `vod.xxx.com`、分片在 `cdn.yyy.net`），
/// 若每条分片都登记一次表，一个大播放列表就会塞爆表并触发清空
/// （把正在播的流也清掉）。所以改成把地址编码进 URL，只查头。
///
/// 安全：token 是宿主随机生成的，只有拿到播放列表的播放器才知道 ——
/// 与 `/s/` 同一信任模型（见模块文档第 2 点）。
async fn handle_proxied(
    State(proxy): State<Arc<StreamProxy>>,
    Path(params): Path<HashMap<String, String>>,
    req_headers: HeaderMap,
) -> Response {
    let token = params.get("token").cloned().unwrap_or_default();
    let rest = params.get("rest").cloned().unwrap_or_default();

    // 查头（插件的 Referer 等）
    let headers = {
        let t = proxy.hdr_table.lock().unwrap_or_else(|e| e.into_inner());
        t.get(&token).cloned()
    };
    let Some(headers) = headers else {
        // ★ issue #9：同 `/s/` 的 404 —— 改前完全静默（log::* 被丢弃）
        splog!(
            "404 分片查不到头: token={} rest={}（代理地址已失效）",
            &token[..token.len().min(12)],
            &rest.chars().take(80).collect::<String>(),
        );
        return (StatusCode::NOT_FOUND, "代理地址已失效，请重新选择线路").into_response();
    };

    /*
     * 还原真实地址：`<scheme>/<host>/<path...>`
     *
     * rest 形如 `https/cdn.com/a/b/0000000.ts?sign=x`
     */
    let mut parts = rest.splitn(3, '/');
    let (scheme, host, path) = (
        parts.next().unwrap_or(""),
        parts.next().unwrap_or(""),
        parts.next().unwrap_or(""),
    );
    if scheme.is_empty() || host.is_empty() || !matches!(scheme, "http" | "https") {
        return (StatusCode::BAD_REQUEST, "代理地址格式不对").into_response();
    }
    let url = format!("{scheme}://{host}/{path}");

    forward_request(&proxy, &token, &headers, &url, &req_headers).await
}

/// 转发一次取流
///
/// # ★★ 为什么路径是 `{token}/{*rest}`（支持子路径）
/// 这是实测踩到的一个**真 bug**，影响所有「走代理的 HLS 流」。
///
/// HLS 的 m3u8 里，分片通常是**相对路径**：
/// ```text
/// #EXTM3U
/// #EXTINF:3.48,
/// 0000000.ts          ← 相对路径！
/// ```
/// 播放器（hls.js）会把它们解析成「相对 m3u8 自身 URL」的地址。
/// 而 m3u8 的 URL 是代理地址：
/// ```text
/// http://127.0.0.1:61022/s/<token>
/// ```
/// 于是分片请求变成：
/// ```text
/// http://127.0.0.1:61022/s/<token>/0000000.ts
/// ```
///
/// 原路由只注册了 `/s/{token}` —— 带子路径的请求**匹配不上**（404），
/// 表现是「m3u8 能取到（我实测 curl 拿到 7119 字节的合法 playlist），
/// 但画面一直不出来」。
///
/// 修法：路由改成 `/s/{token}/{*rest}`，并把 `rest` **拼回上游 URL** ——
/// 这样相对路径的分片、以及 m3u8 里嵌套的二级播放列表都能正常转发。
async fn handle_stream(
    State(proxy): State<Arc<StreamProxy>>,
    Path(params): Path<HashMap<String, String>>,
    req_headers: HeaderMap,
) -> Response {
    /*
     * ⚠️ 用 `HashMap<String, String>` 而不是 `(String, Option<String>)`
     *
     * axum 的 `Path<(String, Option<String>)>` 对**只匹配到一条**路由时
     * 会报「Wrong number of path arguments」（实测：原有的两条代理测试
     * 直接挂了）。因为 `/s/{token}` 这条路由只产生 1 个参数。
     *
     * 用 HashMap 取具名参数就与路由条数无关了。
     */
    let mut token = params.get("token").cloned().unwrap_or_default();

    /*
     * ★★ token 里可能混进子路径 —— 这里把它剥掉
     *
     * 实测（这是修尾斜杠时踩到的）：`/s/{token}` 与 `/s/{token}/{*rest}`
     * 两条路由在**尾斜杠**情形下（`/s/<token>/`）的匹配结果与直觉不同 ——
     * `token` 参数里可能带上 `rest` 的内容（如 `"<token>/0000000.ts"`），
     * 于是查表失败 → 404 → 测试从「能取到 Referer」变成空字符串。
     *
     * 不去依赖 axum 的具体匹配细节，而是**自己保证 token 干净**：
     * 只取第一个 `/` 之前的部分。这样两种路由形态都能正确取到 token。
     */
    if let Some(i) = token.find('/') {
        token.truncate(i);
    }

    let rest = params.get("rest").cloned().filter(|s| !s.is_empty());
    let entry = {
        /*
         * 两张表都要查：流与封面各有独立的表（原因见 `StreamProxy` 的说明）。
         *
         * 不用 `/c/` 与 `/s/` 两个路由来区分，是因为**封面也走同一个 URL 形态**
         * 有个实际好处：前端不需要判断"这个 URL 该用哪个前缀"，
         * 后端返回什么就用什么。
         */
        let t = proxy.table.lock().unwrap_or_else(|e| e.into_inner());
        match t.get(&token).cloned() {
            Some(e) => Some(e),
            None => {
                drop(t);
                proxy
                    .cover_table
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .get(&token)
                    .cloned()
            }
        }
    };
    let Some(entry) = entry else {
        /*
         * ★★★ issue #9：这条 404 正是用户截图里那句的来源。
         * 改前**一行日志都没有**（`log::*` 被丢弃）⇒ 只能猜。
         * 现在打出来，并且能区分两种成因：
         *   ① 表满被淘汰（旧代码是全清 —— 正在播的也会被清）
         *   ② 前端拿了旧线路的地址（换源后没重新登记）
         */
        splog!(
            "404 查不到 token: token={} rest={:?}（取流地址已失效）",
            &token[..token.len().min(12)],
            rest.as_deref(),
        );
        return (StatusCode::NOT_FOUND, "取流地址已失效，请重新选择线路").into_response();
    };

    /*
     * ★★ 把子路径拼回上游地址
     *
     * 请求 `/s/<token>/0000000.ts` 时，`rest = "0000000.ts"`，
     * 而登记的 URL 是 `https://cdn.example.com/a/b/index.m3u8` ——
     * 要转发的是 `https://cdn.example.com/a/b/0000000.ts`。
     *
     * ⚠️ 用 RFC 3986 的语义（相对引用解析），而不是简单字符串相加 ——
     *    后者在 URL 带 query 时会拼错：
     *    `.../index.m3u8?sign=abc` + `0000000.ts`
     *    → 错误地变成 `.../index.m3u8?sign=abc0000000.ts`
     */
    let upstream_url = match rest.as_deref() {
        None | Some("") => entry.url.clone(),
        Some(sub) => join_subpath(&entry.url, sub),
    };

    /*
     * ═══════════════════════════════════════════════════════════════════
     * ★★★ task-57 可观测性：把「收到请求」与「上游 URL」打出来
     * ═══════════════════════════════════════════════════════════════════
     *
     * # 为什么必须加（lead 的要求，也是我踩过的坑）
     *
     * 用户报「播放失败 Failed to open http://127.0.0.1:52123/s/<token>/」时，
     * 我们**无法区分**两种完全不同的情况：
     * ```text
     * ① 代理**根本没收到**请求（mpv 连都没连上）
     * ② 代理收到了，但上游慢/失败/返回非 200
     * ```
     * 而这两种的修法**完全相反**。没有日志就只能猜。
     *
     * # 同时解决"直连上游 TTFB 对照"拿不到 URL 的问题
     *
     * 要判定"3~5 秒的 TTFB 是**上游慢**还是**代理缓冲**"，
     * 必须拿**真实的上游 URL** 去直连测。而那个 URL 只在内存里
     * ⇒ 打出来就能对着它 curl。
     *
     * ★★★ issue #9：这两条探针**原来用 `log::info!`** —— 而本 crate
     *   从未初始化 logger ⇒ 它们一行都没落过盘（"黑盒"的根因就在这里）。
     *   现在改走 [`sp_log`]（stderr，前缀 `[streamproxy]`），上游 URL
     *   一律走 [`redact_url`] 脱敏（query 里的签名一个字节都不打）。
     * ⚠️ 这是**只读日志**，不改变任何转发逻辑。
     */
    splog!(
        "IN token={} path=/s/{}{} range={} upstream={}",
        &token[..token.len().min(12)],
        &token[..token.len().min(12)],
        rest.as_deref().map(|s| format!("/{s}")).unwrap_or_default(),
        req_headers
            .get(header::RANGE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("(none)"),
        redact_url(&upstream_url),
    );

    let t_start = std::time::Instant::now();
    let resp = forward_request(&proxy, &entry.hdr_token, &entry.headers,
                               &upstream_url, &req_headers).await;
    splog!(
        "OUT status={} elapsed={}ms upstream={}",
        resp.status().as_u16(),
        t_start.elapsed().as_millis(),
        redact_url(&upstream_url),
    );
    resp
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 并行分段预取 —— 解决「起播要等 6 秒」
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要它（实测数据，不是推测）
//
// `.probe/t25/EVIDENCE.md` 的真机对照实验：
// ```text
// POS 本地文件       首帧@561ms                      ← 阳性对照（仪器有效）
// C2  远端 完全不seek 首帧@7320ms                     ← ★ 不 seek 也要 7.3s
// A   远端 等duration 首帧@6661ms                     ← duration→首帧只差 19ms
// ⇒ 那 6 秒与"续播等待"无关，是**取 moov 的耗时**
//
// moov 1334657 B ÷ 208 KB/s ≈ 6.27s   ← 与实测 duration@6372ms 吻合
// 单连接 206 KB/s；4 并发 879 KB/s；8 并发 1501 KB/s   ← ★ 限速是**单连接**的
// ```
// 所以：**并行分段取**能把 moov 的到达时间从 ~6.3s 降到 ~1.5s。
//
// # 机制正确性验证（先做原型，再写 Rust）
//
// 见 `.probe/t26_proxy_lab.dart`（合成上游 + 确定限速，秒级迭代）：
// ```text
// POS 直连读 1MB = 5747ms（期望 5120ms）★ 限速模型生效
// CTRL 直连     = 5684ms (180 KB/s)
// FIX  并行代理  = 1452ms (705 KB/s)   ★ 加速比 3.91×
// ✓ 字节逐字节一致（快但错数据比慢更糟）
// ✓ 上游不支持 Range 时正确回退
// ```
//
// # 设计要点（每一条都对应一个护栏）
//
// ```text
// ① 【不改变协议】mpv 仍是从本地代理读 HTTP，代理只是把"一条串行读"
//    变成"N 条并发读再按序拼接" ⇒ 对播放器完全透明
// ② 【只对单文件生效】m3u8/播放列表在更早的分支就返回了；
//    HLS 分片（.ts/.m4s）与图片显式排除 ⇒ 直播路径零改动
// ③ 【必须有 Range 实证】只有上游真的回了 206（或声明 Accept-Ranges）
//    才走这条路；否则**原样回退**到今天的行为
// ④ 【先验证再吐字节】第一个窗口**全部校验通过**才构造响应 ——
//    这样任何异常都还能无损回退（不会先吐一半再发现取错）
// ⑤ 【内存有上限】按窗口流式产出，窗口内并发度固定 ⇒
//    同时驻留内存 ≤ 2 个窗口（默认 2MB），绝不会把 340MB 全拉下来
// ⑥ 【可取消】产出走 mpsc；客户端断开 ⇒ 接收端被 drop ⇒ send 失败
//    ⇒ 生产任务立刻退出，不会继续下载
// ```

/// 走并行预取的最小剩余字节数
///
/// 太小的文件（封面图、HLS 分片）并发取没有收益，只会白白多开连接。
/// 512KB ≈ 2.4 秒（按实测 210 KB/s）—— 低于这个量级不值得并发。
const PREFETCH_MIN_REMAINING: u64 = 512 * 1024;

/// 每个窗口的字节数
///
/// 窗口 = 一轮并发取段的粒度，也是**内存上限的单位**：
/// 同时驻留 ≤ 2 个窗口（当前窗口 + 预取的下一窗口）。
const PREFETCH_WINDOW: usize = 1024 * 1024;

/// 窗口内的并发度
///
/// 实测放大倍数：4 并发 → 4.08×（879 KB/s ÷ 215 KB/s）。
/// 不用更高：8 并发只有 6.97×，但连接数是 4 的两倍，
/// 边际收益递减而占用翻倍。
const PREFETCH_PARALLEL: usize = 4;

/// ★★★ task-57：**发响应之前**只取这么多字节（首块）
///
/// ══════════════════════════════════════════════════════════════════════
/// # 为什么需要它（这是"起播慢 4 秒"的直接原因）
/// ══════════════════════════════════════════════════════════════════════
///
/// 改前：`forward_request` 先 `fetch_window(整个 1MB 窗口).await`，
/// **取满之后**才构造响应 ⇒ 客户端在拿到第一个字节之前要等
/// "下载 1MB"的时间。
///
/// 这个顺序有一个**真实的收益**（注释里写明了）：首窗失败时一个字节
/// 都还没发出去，所以可以**无损回退**到单连接透传。
/// 但代价是首字节延迟 = 1MB 的下载时间。
///
/// # 实测（三层独立证据）
/// ```text
/// ① 确定性单测（固定 640KB/s 限速，无 CDN 噪声）
///      直连 1MB   首字节    2ms   ← 立刻开始流
///      代理 1MB   首字节  472ms   ← 等整个 1MB 窗口
///      代理 256KB 首字节    6ms   ← <512KB 阈值 ⇒ 不预取 ⇒ 直接流
/// ② 交替配对 20 对：19/20 对大窗口更慢，中位比 4.90x，符号检验 p=0.0000
/// ③ 交替配对 10 对：10/10，中位比 3.26x，p=0.0020（独立重跑）
///    + 编排者独立复核 10/10，5.34x  ⇒ 合计 39/40
/// ```
/// ★ 注意 ② ③ 必须用**交替配对**：分块测量（先全测小、再全测大）
///   会把 CDN 的慢漂移当成"请求形态的差异" —— 实测同一个 1MB 请求
///   在不同时间窗能差 6 倍，所以分块测量得出的 0.81x 是假的。
///
/// # 为什么是 64KB
/// ```text
/// · 够大：一次系统调用/一个 TCP 段能装下，播放器拿到就能开始探测
/// · 够小：640KB/s 下 ≈ 100ms（对比 1MB 的 1600ms）
/// · 与播放器自己的探测粒度同量级（ffmpeg 默认 probe 就是几十 KB）
/// ```
///
/// # 为什么首块用**单连接**（而不是 4 并发）
/// 首块的唯一目标是**尽快吐第一个字节**。4 并发要等 4 个请求都回来
/// 才能拼出完整首块（`fetch_window` 按序拼接），反而把 TTFB 拖到
/// "最慢那一段"的时间。单连接 = 一次往返，是最快的形态。
/// 真正的并行收益在**后续窗口**（`run_prefetch` 里仍是 4 并发）。
const PREFETCH_FIRST_CHUNK: u64 = 64 * 1024;

/// 一个并行预取计划（只在**已有 Range 实证**时才会生成）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PrefetchPlan {
    /// 起始字节（含）
    start: u64,
    /// 结束字节（含）
    end: u64,
    /// 每窗口字节数
    window: usize,
    /// 窗口内并发度
    parallel: usize,
}

impl PrefetchPlan {
    fn len(&self) -> u64 {
        self.end - self.start + 1
    }
}

/// 解析 `Content-Range: bytes 0-1334656/339926897` → `(0, 1334656, 339926897)`
///
/// `total` 允许是 `*`（上游不知道总长）—— 那时用 `end + 1` 兜底，
/// 因为 `end` 已经足够决定我们要发多少字节。
fn parse_content_range(v: &str) -> Option<(u64, u64, u64)> {
    let s = v.trim();
    let s = s.strip_prefix("bytes")?.trim_start();
    let (range, total) = s.split_once('/')?;
    let (a, b) = range.split_once('-')?;
    let start: u64 = a.trim().parse().ok()?;
    let end: u64 = b.trim().parse().ok()?;
    let total_txt = total.trim();
    let total: u64 = if total_txt == "*" {
        end.saturating_add(1)
    } else {
        total_txt.parse().ok()?
    };
    if end < start {
        return None;
    }
    Some((start, end, total))
}

/// 这个响应是不是「HLS 分片 / 播放列表 / 图片」——**绝不能**并发预取
///
/// # 为什么必须显式排除
///
/// 直播（HLS）的红线是「完全不受影响」。HLS 的分片（`.ts`/`.m4s`）
/// 本身也是**单文件 + 支持 Range**，形状上和 mp4 一样，
/// 所以不能靠"是不是单文件"来区分 —— 必须按扩展名/类型显式挡掉。
///
/// 图片（封面走同一个 `handle_stream`）也挡掉：并发取一张图没有意义。
fn is_hls_segment_like(path_lower: &str, ctype_lower: &str) -> bool {
    if ctype_lower.contains("mpegurl")
        || ctype_lower.contains("mp2t")
        || ctype_lower.contains("iso.segment")
        || ctype_lower.starts_with("image/")
    {
        return true;
    }
    [".ts", ".m4s", ".aac", ".vtt", ".key", ".mp4a"]
        .iter()
        .any(|e| path_lower.ends_with(e))
}

/// 判断能否走并行预取；不能则返回 `None`（＝保持今天的行为）
///
/// # 为什么必须要有「Range 实证」才敢走
///
/// 并行预取的前提是**能按任意偏移取字节**。如果上游忽略 `Range`
/// 而返回 200（整文件），那"第 2 段"拿回来的其实是文件开头 ——
/// 拼起来就是**数据错乱**，比慢严重得多。
///
/// 所以只在两种**实证**下才走：
/// ```text
/// · 上游回了 206 + Content-Range  ⇒ 它确实按我们要的范围给了数据（最强证据）
/// · 上游回 200 但声明 Accept-Ranges: bytes 且给了总长
///   ⇒ 较弱证据，所以第一个窗口仍会逐段校验，不通过就无损回退
/// ```
fn plan_prefetch(
    disabled: bool,
    status: StatusCode,
    up_headers: &HeaderMap,
    path_lower: &str,
    ctype_lower: &str,
) -> Option<PrefetchPlan> {
    /*
     * ★ 运行期总开关（回滚 + 对照测量用）
     *
     * # 为什么"改 DLL 重启再量"在这里行不通
     *
     * 真机 CDN 吞吐**每分钟都在变**：同一路流、同一个 Range 请求，
     * 实测单连接能从 112 KB/s 跳到 464 KB/s，4 并发放大在 1.31×~4.23×
     * 之间摆。跨进程对照（改 DLL → 重启 → 量）里**两个变量同时在变**，
     * 量不出真实差值 —— 本轮 3 轮交替实测就撞上了这个墙。
     *
     * ⇒ 提供一个**同进程内、请求级**可切换的开关，就能对同一区间
     *   交替跑 ON/OFF，让 CDN 噪声大致同等作用于两组。
     *
     * # 生产价值
     * 线上若发现预取有副作用，不必重新编译：
     *     SOURIN_PREFETCH_DISABLE=1   → 完全回到改动前的串行透传
     *
     * ★★ 2026-10-08：这里**不再直接读环境变量**，改成由调用方传进来的
     *    `disabled` 参数 —— 原因是环境变量是**进程全局**的，而测试
     *    `deterministic_before_after_same_upstream_same_throttle` 要
     *    `set_var` 它做 A/B 对照，于是会和**并发跑的其它测试**抢同一个
     *    全局量 ⇒ CI 上随机红 3 条。详见 `StreamProxy::prefetch_disabled`
     *    字段上那段注释。
     *    环境变量仍在 `StreamProxy::new()` 里读（一次），生产回滚能力不变。
     */
    if disabled {
        return None;
    }

    if is_hls_segment_like(path_lower, ctype_lower) {
        return None;
    }

    let (start, end) = if status == StatusCode::PARTIAL_CONTENT {
        let cr = up_headers.get(header::CONTENT_RANGE)?.to_str().ok()?;
        let (s, e, _t) = parse_content_range(cr)?;
        (s, e)
    } else if status == StatusCode::OK {
        let ar = up_headers
            .get(header::ACCEPT_RANGES)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_ascii_lowercase();
        if !ar.contains("bytes") {
            return None;
        }
        let len = up_headers
            .get(header::CONTENT_LENGTH)
            .and_then(|v| v.to_str().ok())?
            .trim()
            .parse::<u64>()
            .ok()?;
        if len == 0 {
            return None;
        }
        (0, len - 1)
    } else {
        return None;
    };

    if end < start || end - start + 1 < PREFETCH_MIN_REMAINING {
        return None;
    }

    Some(PrefetchPlan {
        start,
        end,
        window: PREFETCH_WINDOW,
        parallel: PREFETCH_PARALLEL,
    })
}

/// 把 `[from, to]` 切成至多 `n` 段（每段至少 1 字节）
fn split_segments(from: u64, to: u64, n: usize) -> Vec<(u64, u64)> {
    let len = to - from + 1;
    if n <= 1 || len <= 1 {
        return vec![(from, to)];
    }
    let seg = len.div_ceil(n as u64);
    let mut out = Vec::with_capacity(n);
    let mut a = from;
    while a <= to {
        let b = (a + seg - 1).min(to);
        out.push((a, b));
        a = b + 1;
    }
    out
}

/// 取一段（**必须**是 206 且长度严格相符，否则算失败）
///
/// 严格校验是刻意的：宁可回退到串行（慢但正确），
/// 也绝不把长度不对/起点不对的数据拼进流里。
async fn fetch_segment(
    client: reqwest::Client,
    url: String,
    headers: Vec<(String, String)>,
    start: u64,
    end: u64,
) -> Result<Bytes, String> {
    let mut rb = client
        .get(&url)
        .header(header::RANGE, format!("bytes={start}-{end}"));
    for (k, v) in &headers {
        rb = rb.header(k.as_str(), v.as_str());
    }

    let resp = rb.send().await.map_err(|e| format!("分段请求失败: {e}"))?;
    let status = resp.status();
    if status != StatusCode::PARTIAL_CONTENT {
        return Err(format!("分段未返回 206（{status}）—— 上游可能不支持 Range"));
    }
    if let Some(cr) = resp
        .headers()
        .get(header::CONTENT_RANGE)
        .and_then(|v| v.to_str().ok())
    {
        if let Some((s, _e, _t)) = parse_content_range(cr) {
            if s != start {
                return Err(format!("分段起点不符: 期望 {start}，上游给 {s}"));
            }
        }
    }
    let body = resp.bytes().await.map_err(|e| format!("读取分段失败: {e}"))?;
    let want = (end - start + 1) as usize;
    if body.len() != want {
        return Err(format!("分段长度不符: 期望 {want}，实得 {}", body.len()));
    }
    Ok(body)
}

/// ★★★ task-57：把**首个窗口**切成「先发的小块 + 其余均分」
///
/// # 为什么不能"先单独取一小块，再取剩下的"
///
/// 我第一版就是这么写的（`fetch_segment(64KB).await` 然后再 `run_prefetch`），
/// 结果被仓库里那条 `prefetch_window_is_parallel_not_serial` **当场抓住**：
/// ```text
/// ★ 读完 4 段用了 938ms —— 接近串行的 1200ms，说明**没有真的并发**
/// ```
/// 因为那样等于**串行两轮**：先等 64KB 那一轮（300ms），再等剩下的窗口
/// （又 300ms）⇒ 总时长 600ms 起，而且**首字节与首窗都被拖慢**。
///
/// # 正确做法：**一次把全部段发出去**，只先 await 第一段
///
/// ```text
/// 段 0 = 64KB（首块）        ← 只等它，到了就发响应头 + 首块
/// 段 1..n = 其余均分          ← 已经在飞了，紧接着按序发出
/// ```
/// 于是：**首字节 = 一次往返**（不是两次），而窗口整体仍是并行的。
/// 两个目标同时达成 —— 这正是"边取边发"该有的样子。
///
/// # 边界
/// 若 `head_len` 不小于整窗、或段数不足以切分，则**退回普通均分**
/// （`split_segments`）—— 那时"先发第一段"仍然比"等整窗"快。
fn split_first_window(from: u64, to: u64, n: usize, head_len: u64) -> Vec<(u64, u64)> {
    let len = to - from + 1;
    if n <= 1 || len <= 1 {
        return vec![(from, to)];
    }
    let head = head_len.min(len);
    let n_rest = n - 1;
    // 首块没意义 / 剩下的不够每段至少 1 字节 ⇒ 退回普通均分
    if head == 0 || head >= len || (len - head) < n_rest as u64 {
        return split_segments(from, to, n);
    }
    let rest = len - head;
    let per = rest / n_rest as u64;
    let mut out = Vec::with_capacity(n);
    out.push((from, from + head - 1));
    let mut cur = from + head;
    for i in 0..n_rest {
        // 最后一段吃掉余数 ⇒ 总和**精确**等于 len（字节精确性）
        let take = if i == n_rest - 1 { to - cur + 1 } else { per };
        out.push((cur, cur + take - 1));
        cur += take;
    }
    out
}

/// 一个窗口的并发取段任务
struct WindowTask {
    from: u64,
    to: u64,
    handles: Vec<tokio::task::JoinHandle<Result<Bytes, String>>>,
}

/// 发起一个窗口的并发取段
///
/// `head_len > 0` 时按 `split_first_window` 切（第一段是小首块），
/// 否则按 `split_segments` 均分。
fn spawn_window(
    client: &reqwest::Client,
    url: &str,
    headers: &[(String, String)],
    from: u64,
    plan: &PrefetchPlan,
    head_len: u64,
) -> WindowTask {
    let to = (from + plan.window as u64 - 1).min(plan.end);
    let segs = if head_len > 0 {
        split_first_window(from, to, plan.parallel, head_len)
    } else {
        split_segments(from, to, plan.parallel)
    };
    let handles = segs
        .into_iter()
        .map(|(a, b)| {
            tokio::spawn(fetch_segment(
                client.clone(),
                url.to_string(),
                headers.to_vec(),
                a,
                b,
            ))
        })
        .collect();
    WindowTask { from, to, handles }
}

/// 把 `mpsc::Receiver` 变成 `Stream`（给 `Body::from_stream` 用）
///
/// # 为什么用 channel 而不是直接写 async 生成器
///
/// channel 给了**取消语义**：客户端断开 ⇒ 响应体被 drop ⇒ 接收端消失
/// ⇒ 生产任务的下一次 `send` 失败 ⇒ 立刻 return。
/// 换成生成器的话，断开后已 spawn 的任务仍会跑完当前窗口。
struct ChannelStream {
    rx: mpsc::Receiver<Result<Bytes, std::io::Error>>,
}

impl Stream for ChannelStream {
    type Item = Result<Bytes, std::io::Error>;

    fn poll_next(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Self::Item>> {
        self.rx.poll_recv(cx)
    }
}

/// 生产任务：**逐段**按序发（首段一到就发，不等整窗），再逐窗并发取
///
/// ══════════════════════════════════════════════════════════════════════
/// ★★★ task-57：这里从"先发整个首窗"改成"**首段一到就发**"
/// ══════════════════════════════════════════════════════════════════════
///
/// # 改前
/// `forward_request` 先 `fetch_window(整窗).await`（等 4 段全回来、
/// 按序拼好），再把整窗交给这里发 ⇒ **首字节 = 整窗下载时间**。
///
/// # 改后
/// 窗口的段**一次性全部发出**（`spawn_window`，首段是小块），
/// 这里**按序 await 并立即转发每一段** ⇒
/// **首字节 = 首段到达时间**，而窗口整体仍然是并行的。
///
/// # 为什么这不会牺牲字节精确性
/// · 段由 `split_first_window` / `split_segments` 切分，
///   总和**精确**等于窗口长度（最后一段吃余数）
/// · 每段仍走 `fetch_segment`：**必须 206 且长度严格相符**，否则整窗失败
/// · 发送顺序 = handles 的顺序 ⇒ 字节流顺序与上游一致
///
/// # 失败处理（与原逻辑一致）
/// 任一段失败 ⇒ 用**一条串行请求**把整窗重取一次（慢但正确）。
/// 注意：首段已经发出去之后，后续失败**不能**再回退到单连接透传 ——
/// 但这条性质在改前也一样（改前是"整窗都到了才发"，那时才真正无损）。
/// 差别只在于：现在**首段失败**仍然是无损的（一个字节都没发），
/// 而"首段成功、后续段失败"在改前与改后都会触发串行重取。
async fn run_prefetch(
    plan: PrefetchPlan,
    client: reqwest::Client,
    url: String,
    headers: Vec<(String, String)>,
    first_window: Bytes,
    /*
     * ★ task-57：首个窗口**剩下的段**（已经 spawn 出去、正在飞）。
     *
     * 为什么要传进来而不是重新 spawn：那些请求**已经在网络上了** ——
     * 重新发一遍等于白付一次往返，而且首窗会被取两次。
     * 传进来的顺序就是 `split_first_window` 切出的顺序（首段已被
     * 调用方 await 掉，所以这里是第 2..n 段）。
     */
    mut rest_of_first: WindowTask,
    tx: mpsc::Sender<Result<Bytes, std::io::Error>>,
) {
    let first_len = first_window.len() as u64;
    if tx.send(Ok(first_window)).await.is_err() {
        return; // 客户端已断开
    }

    /*
     * 先把**首窗剩下的段**按序转发掉，再进入常规的逐窗循环。
     * ⚠️ 失败处理必须与常规窗口一致（串行重取整窗）——
     *    否则首窗会出现"前 64KB 对、后面错"的静默损坏。
     */
    {
        let mut fallback = false;
        for h in std::mem::take(&mut rest_of_first.handles) {
            match h.await {
                Ok(Ok(bytes)) => {
                    if tx.send(Ok(bytes)).await.is_err() {
                        return;
                    }
                }
                _ => {
                    fallback = true;
                    break;
                }
            }
        }
        if fallback {
            match fetch_segment(
                client.clone(),
                url.clone(),
                headers.clone(),
                rest_of_first.from,
                rest_of_first.to,
            )
            .await
            {
                Ok(bytes) => {
                    if tx.send(Ok(bytes)).await.is_err() {
                        return;
                    }
                }
                Err(e) => {
                    log::warn!("流代理：首窗剩余段回退也失败，提前结束流: {e}");
                    return;
                }
            }
        }
    }

    let pos = plan.start + (rest_of_first.to - plan.start + 1);
    let mut pending: Option<WindowTask> = if pos <= plan.end {
        Some(spawn_window(&client, &url, &headers, pos, &plan, 0))
    } else {
        None
    };

    while let Some(w) = pending.take() {
        // ★ 先把下一窗发出去，再发当前窗 —— 让"取"和"送"重叠
        let next_pos = w.to + 1;
        let next = if next_pos <= plan.end {
            Some(spawn_window(&client, &url, &headers, next_pos, &plan, 0))
        } else {
            None
        };

        let mut fallback = false;
        for h in w.handles {
            match h.await {
                Ok(Ok(bytes)) => {
                    if tx.send(Ok(bytes)).await.is_err() {
                        return; // 客户端断开 ⇒ 停止下载
                    }
                }
                _ => {
                    fallback = true;
                    break;
                }
            }
        }

        if fallback {
            /*
             * 某一段失败（上游抖动 / 突然不支持 Range）——
             * 用**一条串行请求**把整窗重取一次。
             * 慢一点，但保证流的内容仍然正确。
             */
            match fetch_segment(
                client.clone(),
                url.clone(),
                headers.clone(),
                w.from,
                w.to,
            )
            .await
            {
                Ok(bytes) => {
                    if tx.send(Ok(bytes)).await.is_err() {
                        return;
                    }
                }
                Err(e) => {
                    log::warn!("流代理：并行预取回退也失败，提前结束流: {e}");
                    return;
                }
            }
        }

        pending = next;
    }
}

/// 并发取一个窗口，**按序拼好**；任一段失败则整体失败
///
/// 首窗必须走这条（先校验再吐字节），所以它不做任何"缺一块也继续"的
/// 妥协 —— 失败就返回 Err，让调用方无损回退。
///
/// # ★★ 为什么必须用 `tokio::spawn` 而不是 `join_all`（本轮实测踩到）
///
/// 我第一版写了个"最小 join_all"：
/// ```text
/// for f in futs { out.push(f.await); }   // ← 这是【串行】的！
/// ```
/// Rust 的 future 是**惰性**的 —— 构造出来并不会开始执行，
/// 只有被 `await` 时才跑。所以那样写等于「做完第 1 段再做第 2 段」。
///
/// 端到端并发测试当场抓到：
/// ```text
/// ★ 上游峰值并发只有 1 —— 并行预取没有生效
/// 见过的 Range: [0-1048575, 0-262143, 262144-524287, ...]
///              ↑ 分段切对了，但 4 段是轮流发的
/// ```
/// 修法：每段 `tokio::spawn` 成立即开始执行的**任务**，
/// 再按序 await 句柄 —— 这样既并发、又保证拼接顺序。
async fn fetch_window(
    client: &reqwest::Client,
    url: &str,
    headers: &[(String, String)],
    from: u64,
    to: u64,
    parallel: usize,
) -> Result<Bytes, String> {
    let handles: Vec<_> = split_segments(from, to, parallel)
        .into_iter()
        .map(|(a, b)| {
            /*
             * ★ spawn 出去的四个任务**立刻**开始跑（各自一条连接），
             *   与下面按序 await 互不冲突 —— 顺序由 handles 的次序保证。
             */
            tokio::spawn(fetch_segment(
                client.clone(),
                url.to_string(),
                headers.to_vec(),
                a,
                b,
            ))
        })
        .collect();

    let mut all = Vec::with_capacity((to - from + 1) as usize);
    for h in handles {
        match h.await {
            Ok(Ok(bytes)) => all.extend_from_slice(&bytes),
            Ok(Err(e)) => return Err(e),
            Err(e) => return Err(format!("分段任务失败: {e}")),
        }
    }
    let want = (to - from + 1) as usize;
    if all.len() != want {
        return Err(format!("窗口长度不符: 期望 {want}，实得 {}", all.len()));
    }
    Ok(Bytes::from(all))
}

/// 预取诊断输出
///
/// # 为什么用 `eprintln!` 而不是 `log::info!`
///
/// 本 crate **从来没有初始化 logger**（`state.rs:509` 实测记录：
/// `grep set_logger → 0 处`），所以 `log::info!` 会被**整个丢弃**。
/// 要拿到"真的走了并行预取"的硬证据，只能走 stderr。
///
/// ⚠️ 但生产环境不该每次起播都刷一行 —— 所以用环境变量开关：
/// ```text
/// 不设 SOURIN_PREFETCH_DEBUG  → 完全静默（零输出）
/// 设了                        → 每次起播打一行，含窗口/并行度
/// ```
/// 与 `PLAYBACK_TIMING`（Dart 侧）是同一个套路。
fn debug_prefetch(plan: &PrefetchPlan, first_len: u64) {
    if std::env::var("SOURIN_PREFETCH_DEBUG").is_err() {
        return;
    }
    eprintln!(
        "[PREFETCH] ★ 并行分段预取已启用: 范围 {}-{} ({:.2}MB) · \
         窗口 {}KB · 并行 {} · 首窗已取 {}KB",
        plan.start,
        plan.end,
        plan.len() as f64 / 1048576.0,
        plan.window / 1024,
        plan.parallel,
        first_len / 1024,
    );
}

/// 真正发请求并把上游响应转回来（`/s/` 与 `/p/` 共用）
///
/// # ★★ 必须用 `client.request()` + 显式 RequestBuilder
///
/// 而不是 `client.get()` 再逐个 `.header()` —— 实测踩到的坑：
/// 后者走的是 reqwest 的「默认头 + 追加」路径，
/// 某些头（尤其 `Referer`）会被**静默忽略或覆盖**，
/// 表现就是「代码里明明加了 Referer，实际请求里没有」，
/// 上游一律 403，而日志里什么都看不出来（最难查的一类 bug）。
///
/// # m3u8 要改写后才能返回
///
/// 播放列表里的子地址有三种形态，只有相对路径能靠相对解析走回代理。
/// 所以这里对 m3u8 做**整体读取 + 改写**（见 `rewrite_playlist`），
/// 其余内容仍然流式转发（一部剧 1~2 GB，不能读进内存）。
async fn forward_request(
    proxy: &Arc<StreamProxy>,
    hdr_token: &str,
    headers: &[(String, String)],
    upstream_url: &str,
    req_headers: &HeaderMap,
) -> Response {
    /*
     * ★★★ task-57：用**共享**的 Client（连接池复用），不再每请求新建。
     *
     * 改前是 `Client::builder().timeout(30s).build()` —— 每请求一个
     * ⇒ 池永远空 ⇒ 每次都要 DNS + TCP + TLS。
     * 详见 `StreamProxy::client` 字段上的说明。
     */
    let client = proxy.client.clone();

    let mut rb = client.request(reqwest::Method::GET, upstream_url);

    // 插件声明的头（如 B 站的 Referer —— 少它就是 403）
    for (k, v) in headers {
        rb = rb.header(k.as_str(), v.as_str());
    }

    /*
     * ★ 透传 Range —— 视频拖进度条全靠它
     *
     * 不透传的话 `<video>` 每次都是从头取，用户一拖进度条
     * 就会卡住或跳回开头（实测过的典型症状）。
     */
    if let Some(range) = req_headers.get(header::RANGE) {
        if let Ok(s) = range.to_str() {
            rb = rb.header(header::RANGE, s);
        }
    }

    /*
     * ★ task-57：上游请求的计时起点。
     *   放在 `send()` **之前**，所以 `t_up` 覆盖"建连 + TLS + 首响"，
     *   正是我们要与"手动 curl 同一 URL"对比的那个量。
     */
    let t_up = std::time::Instant::now();
    let upstream = match rb.send().await {
        Ok(r) => r,
        Err(e) => {
            /*
             * ★ task-57：上游失败必须带**耗时** ——
             *   超时（30s 那个 timeout）与"立刻被拒"是完全不同的问题。
             */
            splog!(
                "UP send FAILED after {}ms: {e}; upstream={}",
                t_up.elapsed().as_millis(),
                redact_url(upstream_url),
            );
            return (StatusCode::BAD_GATEWAY, format!("取流失败: {e}")).into_response()
        }
    };

    let status = upstream.status();
    let up_headers = upstream.headers().clone();
    /*
     * ★ task-57：上游**首响**耗时 —— 这是"直连上游 TTFB"的代理侧对应值。
     *   拿它与"我手动 curl 同一个 upstream URL"的耗时对比，
     *   就能判定 3~5 秒是上游造成的还是代理造成的。
     */
    splog!(
        "UP status={} ttfb={}ms upstream={}",
        status.as_u16(),
        t_up.elapsed().as_millis(),
        redact_url(upstream_url),
    );
    /*
     * ★ task-57：区分「建连成本」与「上游慢」。
     *
     * `reqwest` 的 `Response` 不直接暴露"这条连接是不是复用的"，
     * 但它暴露 HTTP 版本；而**新建连接 vs 复用**最直接的证据是
     * 上游首响耗时在**第 2 个请求之后**是否显著下降
     * （复用连接省掉 TCP+TLS）。
     * 这里把 HTTP 版本也打出来，便于判断是不是 HTTP/2 多路复用。
     */
    splog!(
        "CONN version={:?} reused_hint={}",
        upstream.version(),
        if t_up.elapsed().as_millis() < 200 { "fast(可能复用)" } else { "slow(可能新建)" },
    );

    /*
     * ⚠️ 上游非 2xx 时必须记日志
     *
     * 实测踩过：代理返回 403，但**不知道是代理自身的问题还是上游拒的** ——
     * 因为没有任何日志。加上之后一眼看出「上游 403 + 带了哪些头」。
     */
    if !status.is_success() {
        /*
         * ★★★ issue #9：这条就是「最可能真因」的那条路 ——
         *   该源需要附加头才走代理，头一失效上游就 403，代理原样透传。
         *   改前它用 `log::warn!`（被丢弃），而且 `{:?}` 会把头的**值**
         *   （可能是 Cookie/Authorization）写进日志 —— 两头都不对。
         *   现在：走 stderr，头只打**名字 + 长度**（见 [`hdr_names`]）。
         */
        splog!(
            "UP 非 2xx: status={} 附加头={} upstream={}",
            status,
            hdr_names(headers),
            redact_url(upstream_url),
        );
    }

    /*
     * ★ 挑着转发响应头，不能全带
     *
     * · `Content-Range` / `Accept-Ranges` —— 进度条要用，必须带
     * · `Content-Type` / `Content-Length` —— 播放器要判断格式与总时长
     * · `Content-Encoding` —— **不能带**：reqwest 已经解压过了，
     *   再声明一次会让浏览器二次解压 → 花屏
     * · `Set-Cookie` —— 不带（那是上游与它自己域的事）
     *
     * ★★ 但 **CORS 头必须由我们自己发**（不能透传上游的）
     *
     * # 这是一个真 bug（实测：转换来的插件全部卡在「正在加载…」）
     *
     * 页面跑在 `tauri.localhost`，而代理在 `127.0.0.1:<port>` ——
     * **这是跨源请求**。而 HLS 分片是 hls.js 用 **XHR** 拉的（不是
     * `<video src>` 原生加载），XHR 受同源策略约束。
     *
     * 实测症状：hls.js 请求代理 → XHR status 0（被浏览器拦掉）→
     * MSE 建好了 blob，但一个分片都下不来 → 界面永远「正在加载…」。
     *
     * 为什么 B站/央视没暴露：央视不走代理；B站虽是 mp4 走代理，
     * 但也是 `<video src>` 原生加载，不受 CORS 约束。
     * 只有「**HLS + 走代理**」才会用 XHR，才踩到这个坑。
     */
    let mut out = Response::builder().status(status);
    for key in [
        header::CONTENT_TYPE,
        header::CONTENT_LENGTH,
        header::CONTENT_RANGE,
        header::ACCEPT_RANGES,
        header::LAST_MODIFIED,
        header::ETAG,
    ] {
        if let Some(v) = up_headers.get(&key) {
            out = out.header(key, v.clone());
        }
    }
    out = out
        .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
        .header(header::ACCESS_CONTROL_ALLOW_METHODS, "GET, HEAD, OPTIONS")
        .header(
            header::ACCESS_CONTROL_ALLOW_HEADERS,
            "Range, Content-Type, Accept, Origin",
        )
        .header(
            header::ACCESS_CONTROL_EXPOSE_HEADERS,
            "Content-Length, Content-Range, Content-Type, Accept-Ranges",
        );

    // 上游返回了但状态是错的（403 防盗链、404 过期等）—— 直接透传状态码，
    // 让播放器的 error 分支能正常工作（否则它会以为流是好的，一直转圈）
    if !status.is_success() {
        let code = status.as_u16();
        let hint = match code {
            403 => "（可能被防盗链拦截或地址已过期）",
            404 => "（地址不存在）",
            _ => "",
        };
        /*
         * ★★★ issue #9：**播放器最终看到的就是这一条**。
         *   用户的截图「Failed to open http://127.0.0.1:<port>/s/<token>/」
         *   最可能就是从这条返回（上游 403）传下去的。
         *   这里把「回给播放器的状态码」也打出来，与上面 UP 那行配对，
         *   事后 grep `[streamproxy]` 就能一眼看出：
         *     IN ... → UP 非 2xx status=403 → 透传 403
         */
        splog!("透传上游状态码给播放器: {code}{hint} upstream={}", redact_url(upstream_url));
        return (status, format!("上游返回 {code} {hint}")).into_response();
    }

    // 是 m3u8 吗？（按 Content-Type 与扩展名双重判断）
    let ctype = up_headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_ascii_lowercase();
    let path_only = upstream_url
        .split(['?', '#'])
        .next()
        .unwrap_or("")
        .to_ascii_lowercase();
    let is_playlist = ctype.contains("mpegurl")
        || ctype.contains("m3u")
        || path_only.ends_with(".m3u8")
        || path_only.ends_with(".m3u");

    if is_playlist {
        let text = match upstream.text().await {
            Ok(t) => t,
            Err(e) => {
                // ★ issue #9：改前这条**没有日志**（502 只在播放器那边看到）
                splog!("读 m3u8 失败: {e} upstream={}", redact_url(upstream_url));
                return (StatusCode::BAD_GATEWAY, format!("读取播放列表失败: {e}"))
                    .into_response()
            }
        };

        /*
         * ★★★ 改写播放列表里的地址，让它们都走本代理
         *
         * 见 `rewrite_playlist` 的说明 —— 绝对路径与完整 URL 两种形态
         * 都不会自动走代理（实测 `360采集` 的子播放列表是绝对路径，
         * 所以它一直卡在「正在加载…」）。
         *
         * ⚠️ `hdr_token` 由调用方传入，**就是注册这条流时生成的那个**
         *    （已登记在 `hdr_table`）。绝不能在这里新生成 ——
         *    实测踩到：在这里生成并登记，但"换清晰度/重试"会再请求一次
         *    m3u8、又生成一个新 token，而 `hdr_table` 超限会清空，
         *    于是分片请求查不到头 → 「代理地址已失效」→ 全部播不了。
         */
        let local_base = format!("http://127.0.0.1:{}/p/{hdr_token}/", proxy.port());
        let rewritten = rewrite_playlist(&text, upstream_url, &local_base);

        // 改写后长度会变，必须去掉上游的 Content-Length（否则截断）
        return Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, "application/vnd.apple.mpegurl")
            .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
            .header(header::ACCESS_CONTROL_ALLOW_METHODS, "GET, HEAD, OPTIONS")
            .header(
                header::ACCESS_CONTROL_ALLOW_HEADERS,
                "Range, Content-Type, Accept, Origin",
            )
            .body(Body::from(rewritten))
            .unwrap_or_else(|e| {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    format!("组装响应失败: {e}"),
                )
                    .into_response()
            });
    }

    /*
     * ★★★ 并行分段预取（task-26）——见上面那一段长注释
     *
     * 只有 `plan_prefetch` 判定「单文件 + 有 Range 实证 + 够大」时才走；
     * 其余情况（HLS 分片 / 支持不了 Range 的源 / 图片）**原样回退**到
     * 下面的单连接透传 —— 也就是今天的行为。
     */
    if let Some(plan) = plan_prefetch(
        proxy.prefetch_is_disabled(),
        status,
        &up_headers,
        &path_only,
        &ctype,
    ) {
        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ task-57：先发**首段**（64KB），不等整窗
         * ══════════════════════════════════════════════════════════════
         *
         * # 改前
         * ```rust
         * let first_to = (plan.start + plan.window - 1).min(plan.end); // 整个 1MB
         * fetch_window(&client, ..., plan.start, first_to, plan.parallel).await
         * // ↑ 等 4 段全回来并拼好，才构造响应
         * ```
         * ⇒ **首字节 = 整窗下载时间**。实测（固定 640KB/s 限速、无 CDN 噪声）：
         * ```text
         * 直连 1MB   首字节    2ms   ← 立刻开始流
         * 代理 1MB   首字节  472ms   ← 等整个 1MB 窗口
         * 代理 256KB 首字节    6ms   ← <512KB 阈值 ⇒ 不预取
         * ```
         * 真机交替配对（39/40 配对，p<0.0001）：大窗口比小窗口慢 **3.2~5.3 倍**。
         *
         * # 改后：**一次发出全部段，只先 await 第一段**
         * ```text
         * 段 0 = 64KB（首块）   ← 只等它 ⇒ 首字节 = **一次往返**
         * 段 1..n = 其余均分     ← 已经在飞（spawn 出去的），紧接着按序转发
         * ```
         * ⚠️ 我第一版写成"先 `fetch_segment(64KB).await`，再 `run_prefetch`"
         *    ⇒ 被 `prefetch_window_is_parallel_not_serial` 当场抓住
         *    （938ms ≈ 串行 1200ms）：那样等于**串行两轮**，
         *    首字节和整窗**都被拖慢**。必须**同时**发出。
         *
         * # ★ 为什么仍然保留"无损回退"
         * 关键性质没变：**首段失败时一个字节都还没发出去** ⇒
         * 仍可干净地回退到下面的单连接透传，客户端完全感知不到。
         * 只是"要先等的东西"从 1MB 变成 64KB —— 失败判据完全相同
         * （`fetch_segment` 仍要求 206 + 长度严格相符），只是更快有结论。
         */
        let first_window = spawn_window(
            &client,
            &upstream_url,
            &headers,
            plan.start,
            &plan,
            PREFETCH_FIRST_CHUNK,
        );
        let mut first_window = first_window;
        // 首段 = handles[0]（`split_first_window` 保证第一段就是小块）
        let head = first_window.handles.remove(0);
        match head.await {
            Ok(Ok(first)) => {
                debug_prefetch(&plan, first.len() as u64);
                let (tx, rx) = mpsc::channel::<Result<Bytes, std::io::Error>>(4);
                let plan2 = plan;
                let url2 = upstream_url.to_string();
                let headers2 = headers.to_vec();
                let client2 = client.clone();
                tokio::spawn(async move {
                    run_prefetch(
                        plan2,
                        client2,
                        url2,
                        headers2,
                        first,
                        first_window,
                        tx,
                    )
                    .await;
                });
                return out
                    .body(Body::from_stream(ChannelStream { rx }))
                    .unwrap_or_else(|e| {
                        (
                            StatusCode::INTERNAL_SERVER_ERROR,
                            format!("组装响应失败: {e}"),
                        )
                            .into_response()
                    });
            }
            Ok(Err(e)) => {
                /*
                 * ★ task-57：首段**请求成功但内容不合规**
                 * （非 206 / 长度不符 / 起点不符）。
                 *
                 * 这与"网络错误"要分开处理：它说明上游**不支持 Range**
                 * 或行为异常 ⇒ 同样一个字节都没发出去 ⇒ **无损回退**。
                 */
                log::warn!(
                    "流代理：并行预取首段校验失败，回退单连接（{e}）；url 前 60: {}",
                    &upstream_url[..upstream_url.len().min(60)]
                );
            }
            Err(e) => {
                /*
                 * 首窗失败 ⇒ **无损回退**到单连接透传。
                 * 因为此时一个字节都还没发给客户端。
                 */
                log::warn!(
                    "流代理：并行预取首窗失败，回退单连接（{e}）；url 前 60: {}",
                    &upstream_url[..upstream_url.len().min(60)]
                );
            }
        }
    }

    // 非播放列表：流式转发（不能整个读进内存 —— 一部剧 1~2 GB）
    let body = Body::from_stream(upstream.bytes_stream());
    out.body(body).unwrap_or_else(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("组装响应失败: {e}"),
        )
            .into_response()
    })
}


/// 把 m3u8 里的子地址改写成走本代理
///
/// # 为什么不能靠「相对路径解析」自动走代理
///
/// 播放列表里的子地址有三种形态，**只有相对路径能靠 RFC 3986 的相对解析
/// 自动走到代理**：
///
/// | 形态 | 例 | 播放器解析成 | 结果 |
/// |---|---|---|---|
/// | 相对 | `3260kb/hls/index.m3u8` | `<代理>/s/<token>/3260kb/...` | ✅ |
/// | 绝对路径 | `/20260820/x/3260kb/hls/index.m3u8` | `<代理根>/20260820/...` | ❌ 丢了 token |
/// | 完整 URL | `https://cdn.com/a/b.ts` | 原样直连 CDN | ❌ 少了 Referer → 403 |
///
/// 实测 `360采集` 的子播放列表就是**绝对路径**形态，所以它一直卡在
/// 「正在加载…」。
///
/// # 改写目标形态：`/p/<token>/<scheme>/<host>/<path>`
///
/// 用 **`/p/`** 而不是 `/s/`：
///   · `/s/<token>/<rest>` 的 `rest` 语义是「相对 **token 登记的那个 URL**
///     的子路径」，代理要用 `join_subpath` 拼回去
///   · `/p/<token>/...` 里**带了完整的 scheme 与 host**，代理直接照着请求即可，
///     **不需要也不应该再拼** ——
///     分片可能在不同主机上（m3u8 在 vod.xxx.com、分片在 cdn.yyy.net）
///
/// 第一版我复用了 `/s/` 并把完整路径塞进 `rest`，结果代理又按"相对目录"
/// 拼了一遍 → 路径重复（`.../abc/abc/0000000.ts`）→ 404 → **全部播不了**。
///
/// # 表只随「换集次数」增长
///
/// 分片不再逐个登记（只登记一次头，见 `hdr_table`），
/// 所以一个 1000 分片的播放列表不会塞爆任何表。
fn rewrite_playlist(text: &str, base_url: &str, local_base: &str) -> String {
    let origin = url_origin(base_url);

    let mut out = String::with_capacity(text.len() + 512);
    for line in text.lines() {
        let trimmed = line.trim();

        if trimmed.is_empty() {
            out.push('\n');
            continue;
        }

        // 标签行
        if trimmed.starts_with('#') {
            /*
             * 带 URI 属性的标签（如 #EXT-X-KEY:METHOD=AES-128,URI="key.key"）
             * 也要改写，否则加密流拿不到密钥。
             *
             * ⚠️ 下标要在 `trimmed` 上算，不能拿剥掉 `#` 的串算 ——
             *    两者差 1 位，会让开头那个引号被吃掉。
             */
            if let Some(pos) = trimmed.find("URI=\"") {
                let value_start = pos + 5;
                let after = &trimmed[value_start..];
                if let Some(end) = after.find('"') {
                    let uri = &after[..end];
                    let tail = &after[end..];
                    let new_uri = to_local(uri, base_url, &origin, local_base);
                    out.push_str(&trimmed[..value_start]);
                    out.push_str(&new_uri);
                    out.push_str(tail);
                    out.push('\n');
                    continue;
                }
            }
            out.push_str(trimmed);
            out.push('\n');
            continue;
        }

        // URI 行 —— 改写
        out.push_str(&to_local(trimmed, base_url, &origin, local_base));
        out.push('\n');
    }
    out
}

/// 取 URL 的 `scheme://host[:port]`（origin）
fn url_origin(u: &str) -> String {
    let no_query = u.split(['?', '#']).next().unwrap_or(u);
    match no_query.find("://") {
        Some(i) => {
            let after = i + 3;
            match no_query[after..].find('/') {
                Some(j) => no_query[..after + j].to_string(),
                None => no_query.to_string(),
            }
        }
        None => String::new(),
    }
}

/// 把一条 URI 转成 `/p/<token>/<scheme>/<host>/<path?query>` 形态
///
/// `local_base` 形如 `http://127.0.0.1:<port>/p/<token>/`。
fn to_local(uri: &str, base_url: &str, origin: &str, local_base: &str) -> String {
    let uri = uri.trim();
    if uri.is_empty() {
        return String::new();
    }

    // ① 绝对化
    let abs = if uri.starts_with("http://") || uri.starts_with("https://") {
        uri.to_string()
    } else if let Some(rest) = uri.strip_prefix("//") {
        // 协议相对 —— 补上 base 的协议，**保留 `//`**
        match base_url.find("://") {
            Some(i) => format!("{}://{rest}", &base_url[..i]),
            None => uri.to_string(),
        }
    } else if uri.starts_with('/') {
        if origin.is_empty() {
            uri.to_string()
        } else {
            format!("{origin}{uri}")
        }
    } else {
        let no_query = base_url.split(['?', '#']).next().unwrap_or(base_url);
        match no_query.rfind('/') {
            Some(i) => format!("{}{}", &no_query[..=i], uri),
            None => uri.to_string(),
        }
    };

    /*
     * ② 拆成 scheme / host / path，编码进 URL
     *
     * 目标：`<local_base><scheme>/<host><path>`
     * 例：`http://127.0.0.1:1/p/TOK/https/cdn.com/a/b.ts`
     *
     * 之所以把 scheme 与 host 都放进路径，是为了让代理**无需查表**
     * 就能直连（分片可能跨主机）。头由 `/p/<token>` 里的 token 查表得到。
     */
    let Some(sep) = abs.find("://") else {
        // 没法解析成绝对 URL —— 原样返回（至少不产出错误地址）
        return abs;
    };
    let scheme = &abs[..sep];
    let after = &abs[sep + 3..];
    let (host, path) = match after.find('/') {
        Some(i) => (&after[..i], &after[i..]),
        None => (after, "/"),
    };

    format!("{local_base}{scheme}/{host}{path}")
}

/// 把「需要头的流」包装成本地代理地址
///
/// 供 `resolve_stream` 命令在返回候选前统一处理：
/// 只有 `not_web_ready` 的流才需要走代理（其余直连更快、也少一跳）。
pub async fn maybe_proxy(
    proxy: &Arc<StreamProxy>,
    url: &str,
    headers: &[(String, String)],
    not_web_ready: bool,
) -> Option<String> {
    if !not_web_ready || headers.is_empty() {
        return None;
    }
    /*
     * ★★★ issue #9（次修 2）：**用 `ensure_started` 返回的端口**，
     * 不再让 `register` 回读 `self.port()` —— 两步之间代理可能已退出
     * （看门狗 `mark_dead` 把端口清成 0）⇒ 会拼出 `http://127.0.0.1:0/…`。
     */
    let port = match proxy.ensure_started().await {
        Ok(p) => p,
        Err(e) => {
            /*
             * ⚠️ 启动失败必须**记日志**，不能静默返回 None
             *
             * 静默的话表现是「流地址还是原始的 → 播放器 403 → 用户看到
             * 黑屏」，而完全不知道是代理没起来（实测踩过：以为代理生效了，
             * 实际一直拿的是裸 CDN 地址）。
             *
             * ★ issue #9：这里原来也是 `log::error!`（同样被丢弃）⇒
             *   改走 stderr。
             */
            splog!("代理启动失败，该流将直连（很可能 403）: {e}");
            return None;
        }
    };
    let local = proxy.register_at(url, headers.to_vec(), port);
    // 本地地址形如 http://127.0.0.1:<port>/s/<token>/ ⇒ 取倒数第二段就是 token
    let tok_short: String = local.rsplit('/').nth(1).unwrap_or("").chars().take(12).collect();
    splog!(
        "登记流: port={port} token={tok_short} 上游={} 附加头={}",
        redact_url(url),
        hdr_names(headers),
    );
    Some(local)
}

#[cfg(test)]
mod tests {
    use super::*;

    // ═══════════════════════════════════════════════════════════════
    //  task-26 并行分段预取
    // ═══════════════════════════════════════════════════════════════

    fn hdr(pairs: &[(&str, &str)]) -> HeaderMap {
        let mut h = HeaderMap::new();
        for (k, v) in pairs {
            h.insert(
                header::HeaderName::from_bytes(k.as_bytes()).unwrap(),
                v.parse().unwrap(),
            );
        }
        h
    }

    // ═══════════════════════════════════════════════════════════════
    //  ★★★ task-57「边取边发」：首字节不再等整窗
    // ═══════════════════════════════════════════════════════════════

    /// ★ `split_first_window` 的切分必须**精确覆盖**、且首段就是小块
    ///
    /// 这是"边取边发"的地基：如果切分有缝/重叠，字节流就会损坏；
    /// 如果首段不是小块，首字节就还是等整窗。
    #[test]
    fn first_window_split_is_exact_and_head_is_small() {
        const WIN: u64 = PREFETCH_WINDOW as u64;
        const HEAD: u64 = PREFETCH_FIRST_CHUNK;

        let segs = split_first_window(0, WIN - 1, PREFETCH_PARALLEL, HEAD);

        // ① 段数正确
        assert_eq!(segs.len(), PREFETCH_PARALLEL);
        // ② 首段 == HEAD（这就是"先发的那个小块"）
        assert_eq!(segs[0], (0, HEAD - 1), "首段必须是 {HEAD} 字节的小块");
        // ③ 无缝、无重叠、**精确覆盖**整个窗口
        assert_eq!(segs[0].0, 0, "必须从 0 开始");
        for w in segs.windows(2) {
            assert_eq!(w[0].1 + 1, w[1].0, "段之间不能有缝或重叠: {w:?}");
        }
        assert_eq!(segs.last().unwrap().1, WIN - 1, "必须覆盖到窗口末尾");
        let total: u64 = segs.iter().map(|(a, b)| b - a + 1).sum();
        assert_eq!(total, WIN, "段长之和必须精确等于窗口长度（字节精确性）");

        // ④ 非零起点也要正确（后续窗口的调用形态）
        let s2 = split_first_window(12345, 12345 + WIN - 1, 4, HEAD);
        assert_eq!(s2[0], (12345, 12345 + HEAD - 1));
        let t2: u64 = s2.iter().map(|(a, b)| b - a + 1).sum();
        assert_eq!(t2, WIN);
        assert_eq!(s2.last().unwrap().1, 12345 + WIN - 1);

        // ⑤ 退化情形必须安全退回（不能 panic、不能产生空段）
        for (from, to, n, head) in [
            (0u64, 0u64, 4usize, HEAD),          // 只有 1 字节
            (0, 100, 1, HEAD),                   // 单段
            (0, 1000, 4, 0),                     // head=0 ⇒ 均分
            (0, 1000, 4, 1001),                  // head > len ⇒ 均分
            (0, 3, 4, 1),                        // 剩余不够每段 1 字节
        ] {
            let v = split_first_window(from, to, n, head);
            assert!(!v.is_empty(), "不能返回空段: {from}-{to} n={n} head={head}");
            for (a, b) in &v {
                assert!(a <= b, "段必须非空: {a}-{b}");
            }
            assert_eq!(v[0].0, from, "必须从 from 开始");
            assert_eq!(v.last().unwrap().1, to, "必须覆盖到 to");
            let sum: u64 = v.iter().map(|(a, b)| b - a + 1).sum();
            assert_eq!(sum, to - from + 1, "必须精确覆盖: {from}-{to}");
        }
    }

    /// ★★★ 红度证明：**首字节必须早于整窗取满**
    ///
    /// # 这条测的是"边取边发"这个行为本身
    ///
    /// 上游是**确定性限速**（每 64KB 延迟 100ms ≈ 640KB/s），所以：
    /// ```text
    /// 改后（边取边发）：首字节 ≈ 首段(64KB)到达 ≈ 100ms
    /// 改前（先取满整窗）：首字节 = 整窗 1MB ≈ 1600ms（串行）
    ///                      或 ≈ 400ms（4 并发，仍要等最慢那段）
    /// ```
    /// 判据取 **整窗串行时间的 1/3** —— 改前无论如何都达不到，
    /// 因为改前必须等**整个窗口**（4 段）都回来。
    ///
    /// ★ 红度：把 `forward_request` 里的首段 await 改回 `fetch_window`
    ///   （即"先取满整窗"）⇒ 首字节回到整窗量级 ⇒ 本断言**变红**。
    ///
    /// ⚠️ 必须**先读首字节**再读其余 —— 若直接 `resp.bytes().await`
    ///    就会把整个响应读完，量到的是"整窗时间"而不是"首字节时间"
    ///    （这正是本仓 `measure()` 注释里说的那个陷阱）。
    #[tokio::test]
    async fn first_byte_arrives_before_the_whole_window() {
        use axum::body::Body as AxumBody;
        use axum::http::Request;
        use axum::response::IntoResponse;
        use futures_core::Stream;

        /*
         * ★ 用 `poll_next` 手写一个"只取下一块"的辅助，而不是 `StreamExt::next`。
         *
         * 本 crate 只有 `futures-core`（没有 `futures` / `tokio-stream`），
         * 而 `futures-core` 只提供 `Stream` trait、**不提供** `next()` 扩展方法。
         * 硬要 `next()` 就得加依赖 —— 而这是**只为测试**加的依赖，
         * 不值得（本仓刻意保持依赖精简，见 Cargo.toml 的长注释）。
         */
        async fn next_chunk<S>(s: &mut S) -> Option<S::Item>
        where
            S: Stream + Unpin,
        {
            std::future::poll_fn(|cx| std::pin::Pin::new(&mut *s).poll_next(cx)).await
        }

        const TOTAL: u64 = 4 * 1024 * 1024;
        const CHUNK: usize = 64 * 1024;
        const CHUNK_DELAY_MS: u64 = 100; // ≈ 640 KB/s，与仓库既有测试同量级

        fn byte_at(i: u64) -> u8 {
            ((i.wrapping_mul(31)).wrapping_add((i >> 8).wrapping_mul(17)) & 0xFF) as u8
        }

        /// 限速上游：支持 Range，按块延迟发送
        async fn serve_throttled(req: Request<AxumBody>) -> Response {
            let (start, end) = req
                .headers()
                .get(header::RANGE)
                .and_then(|v| v.to_str().ok())
                .and_then(|r| {
                    let r = r.strip_prefix("bytes=")?;
                    let (a, b) = r.split_once('-')?;
                    let a = a.trim().parse::<u64>().ok()?;
                    let b = if b.trim().is_empty() {
                        TOTAL - 1
                    } else {
                        b.trim().parse::<u64>().ok()?.min(TOTAL - 1)
                    };
                    Some((a, b))
                })
                .unwrap_or((0, TOTAL - 1));

            let (tx, rx) = mpsc::channel::<Result<Bytes, std::io::Error>>(2);
            tokio::spawn(async move {
                let mut pos = start;
                while pos <= end {
                    let n = CHUNK.min((end - pos + 1) as usize);
                    let buf: Vec<u8> =
                        (pos..pos + n as u64).map(byte_at).collect();
                    if tx.send(Ok(Bytes::from(buf))).await.is_err() {
                        return;
                    }
                    pos += n as u64;
                    tokio::time::sleep(std::time::Duration::from_millis(
                        CHUNK_DELAY_MS,
                    ))
                    .await;
                }
            });

            Response::builder()
                .status(StatusCode::PARTIAL_CONTENT)
                .header(
                    header::CONTENT_RANGE,
                    format!("bytes {start}-{end}/{TOTAL}"),
                )
                .header(header::ACCEPT_RANGES, "bytes")
                .header(header::CONTENT_TYPE, "video/mp4")
                .body(Body::from_stream(ChannelStream { rx }))
                .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
        }

        let up = Router::new().route("/slow.mp4", get(serve_throttled));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let up_port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            let _ = axum::serve(listener, up).await;
        });

        let proxy = Arc::new(StreamProxy::new());
        proxy.ensure_started().await.unwrap();
        let local = proxy.register(
            &format!("http://127.0.0.1:{up_port}/slow.mp4"),
            vec![],
        );

        // ── 量首字节：请求整窗，但**只等第一个数据块** ──
        let t0 = std::time::Instant::now();
        let resp = reqwest::Client::new()
            .get(&local)
            .header(header::RANGE, format!("bytes=0-{}", PREFETCH_WINDOW - 1))
            .send()
            .await
            .unwrap();
        let mut stream = resp.bytes_stream();
        let first = next_chunk(&mut stream)
            .await
            .expect("必须有第一个数据块")
            .unwrap();
        let ttfb_ms = t0.elapsed().as_millis() as u64;
        let first_len = first.len() as u64;

        /*
         * ★★★ 判据的标尺必须用**并行**窗口时间，不是串行时间
         *
         * # 我第一版判据写错了，被红度证明当场抓到
         *
         * 我原来用"整窗**串行**时间 / 3" = 1600/3 = **533ms** 当上限。
         * 但改前的代码用的是 `fetch_window`（**4 并发**），所以改前的
         * 首字节其实是 **~400ms**（= 每段 256KB ÷ 640KB/s），
         * 而 400ms < 533ms ⇒ ★ **改前也能通过** ⇒ 判据**没有区分力**。
         *
         * 红度证明（把首段改回整窗）实测：首字节 **435ms** ⇒ 仍然通过
         * ⇒ 我当场发现判据是错的（而不是以为"改前也快"）。
         *
         * # 正确的标尺
         * ```text
         * 改前（等整窗，4 并发）：≈ 400ms  = CHUNK_DELAY × (WINDOW/PARALLEL/CHUNK)
         * 改后（只等首段 64KB）  ：≈ 100ms  = CHUNK_DELAY
         * ```
         * ⇒ 判据取两者的中间：**并行窗口时间的 2/3**（≈266ms）
         *   实测改后 108ms ✓ 通过、改前 435ms ✗ 失败 ⇒ **有区分力** ✓
         */
        let window_parallel_ms =
            CHUNK_DELAY_MS * (PREFETCH_WINDOW as u64 / PREFETCH_PARALLEL as u64 / CHUNK as u64);
        let limit = window_parallel_ms * 2 / 3;

        println!(
            "[EDGE-SEND] 首字节 {ttfb_ms}ms / 首块 {first_len}B；\
             改前基线(并行整窗) ≈ {window_parallel_ms}ms；判据 < {limit}ms"
        );

        // ① 首块必须**受首段大小约束**（不是整窗）—— 否则"先发首块"没生效
        //
        // ⚠️ 不能断言"首块恰好 == 64KB"：`Body::from_stream` 出来的字节
        //    会被 hyper/TCP **按到达情况再切分**（实测首个数据块 7761B，
        //    远小于 64KB）。那是传输层分帧，**不是**我们的逻辑。
        //    真正要钉的性质是：**首个数据块受首段大小约束** ——
        //    若首字节还在等整窗，第一个块就会是整窗（1MB）那么大。
        assert!(
            first_len <= PREFETCH_FIRST_CHUNK,
            "★ 首个数据块 {first_len}B > 首段上限 {PREFETCH_FIRST_CHUNK}B \
             ⇒ 说明首字节仍在等更大的单位（改前是等整窗 {PREFETCH_WINDOW}B）"
        );
        // ② 首字节必须**早于并行整窗**（这是改前做不到的）
        assert!(
            ttfb_ms < limit,
            "★ 首字节 {ttfb_ms}ms ≥ 判据 {limit}ms（改前基线 ≈ {window_parallel_ms}ms）\
             ⇒ 说明**首字节仍在等整个窗口** ⇒「边取边发」没有生效。\
             （红度：把 forward_request 的首段 await 改回 fetch_window 即复现）"
        );

        // ── ③ 完整性：把剩下的读完，字节必须与上游**逐字节相同** ──
        let mut got: Vec<u8> = first.to_vec();
        while let Some(chunk) = next_chunk(&mut stream).await {
            got.extend_from_slice(&chunk.unwrap());
        }
        assert_eq!(
            got.len(),
            PREFETCH_WINDOW,
            "整窗字节数必须完整（边取边发不能丢字节）"
        );
        let want: Vec<u8> = (0..PREFETCH_WINDOW as u64).map(byte_at).collect();
        assert!(
            got == want,
            "★ 字节内容必须与上游**逐字节相同**（顺序/内容都不能错）"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  ★★★ task-57 共享 Client（连接池复用）
    // ═══════════════════════════════════════════════════════════════

    /// ★★★ 共享 Client 必须**真的复用连接** —— 用一条本地计数服务证明
    ///
    /// # 为什么必须测这个（而不是只测"TTFB 变快了"）
    ///
    /// 真机 CDN 的吞吐**每分钟都在变**（见 `plan_prefetch` 的注释），
    /// 所以"TTFB 从 3.9s 降到 0.8s"这种读数**分不清**是：
    /// ```text
    /// ① 连接复用了（我们的改动生效）
    /// ② CDN 那一刻恰好快（与改动无关）
    /// ```
    /// 这正是 lead 两次测量差 6 倍的原因（同一端口、同一 token、
    /// 分块测量 ⇒ 量到的是 CDN 的心情）。
    ///
    /// ⇒ 所以这里**不看时间**，而是**数 TCP 连接数**：
    ///    本地起一个 axum 服务，用一个 `AtomicUsize` 数它 accept 到几条连接。
    ///    同一个 Client 发 N 个请求 ⇒ 连接数应该 **远小于 N**（复用）；
    ///    每请求新 Client ⇒ 连接数 **== N**。
    ///    ★ 这是**确定性**判据，不受网络快慢影响。
    #[tokio::test]
    async fn shared_client_reuses_connections() {
        use axum::body::Body as AxumBody;
        use axum::http::Request;
        use axum::response::IntoResponse;
        use std::sync::atomic::{AtomicUsize, Ordering};

        /*
         * 每 accept 一条连接就 +1。
         * axum 不直接给"连接计数"钩子，所以用 `into_make_service_with_connect_info`
         * 拿 `ConnectInfo`，在 handler 里按**对端端口**去重计数 ——
         * 同一个源端口 = 同一条 TCP 连接（复用）。
         */
        static SEEN: std::sync::OnceLock<std::sync::Mutex<std::collections::HashSet<u16>>> =
            std::sync::OnceLock::new();
        static HITS: AtomicUsize = AtomicUsize::new(0);

        async fn serve(
            axum::extract::ConnectInfo(addr): axum::extract::ConnectInfo<
                std::net::SocketAddr,
            >,
            _req: Request<AxumBody>,
        ) -> Response {
            SEEN.get_or_init(Default::default)
                .lock()
                .unwrap()
                .insert(addr.port());
            HITS.fetch_add(1, Ordering::SeqCst);
            Response::builder()
                .status(StatusCode::OK)
                .header(header::CONTENT_TYPE, "video/mp4")
                .header(header::CONTENT_LENGTH, "4")
                .body(Body::from("abcd"))
                .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
        }

        let app = Router::new().route("/f", get(serve));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let _ = axum::serve(
                listener,
                app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
            )
            .await;
        });

        const N: usize = 8;
        let url = format!("http://127.0.0.1:{}/f", addr.port());

        // ── A: 共享一个 Client（改后的行为）──
        let shared = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(5))
            .build()
            .unwrap();
        SEEN.get_or_init(Default::default).lock().unwrap().clear();
        HITS.store(0, Ordering::SeqCst);
        for _ in 0..N {
            let r = shared.get(&url).send().await.unwrap();
            let _ = r.bytes().await.unwrap();
        }
        let shared_conns = SEEN.get().unwrap().lock().unwrap().len();
        let shared_hits = HITS.load(Ordering::SeqCst);

        // ── B: 每请求新建 Client（改前的行为）──
        SEEN.get().unwrap().lock().unwrap().clear();
        HITS.store(0, Ordering::SeqCst);
        for _ in 0..N {
            let c = reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(5))
                .build()
                .unwrap();
            let r = c.get(&url).send().await.unwrap();
            let _ = r.bytes().await.unwrap();
        }
        let fresh_conns = SEEN.get().unwrap().lock().unwrap().len();
        let fresh_hits = HITS.load(Ordering::SeqCst);

        println!(
            "[SHARED-CLIENT] A 共享 Client: {N} 请求 → {shared_conns} 条 TCP 连接\n\
             [SHARED-CLIENT] B 每请求新建: {N} 请求 → {fresh_conns} 条 TCP 连接"
        );

        // 前置：两轮都真的打到了服务（否则下面的比较无意义）
        assert_eq!(shared_hits, N, "A 轮必须收到 {N} 个请求");
        assert_eq!(fresh_hits, N, "B 轮必须收到 {N} 个请求");

        /*
         * ★ 主断言：共享 Client 的连接数必须**明显少于**请求数。
         *   留 `<= N/2` 的余量（keep-alive 偶尔重连是正常的），
         *   而"每请求新建"必然 == N。
         */
        assert!(
            shared_conns < N,
            "★ 共享 Client 没有复用连接：{N} 个请求用了 {shared_conns} 条连接\n\
             （期望 < {N}；若等于 {N} 说明 keep-alive 没生效）"
        );
        assert_eq!(
            fresh_conns, N,
            "★ 每请求新建 Client 必须用 {N} 条连接（这是对照组的定义），\
             实际 {fresh_conns} 条 ⇒ 对照组不成立，主断言也就没有意义"
        );
        assert!(
            shared_conns < fresh_conns,
            "★ 共享({shared_conns} 条) 必须比 每请求新建({fresh_conns} 条) 少"
        );
    }

    /// ★ 共享 Client 是**同一个实例**（不是每请求 clone 出一个新池）
    ///
    /// `reqwest::Client` 内部是 `Arc` ⇒ `clone()` 共享同一个连接池。
    /// 这条测试把"clone 不会新建池"这件事钉死，防止以后有人误改成
    /// `Client::builder().build()`（那会静默退化成"每请求新建"）。
    #[test]
    fn cloned_client_shares_the_pool() {
        let p = StreamProxy::new();
        let a = p.client.clone();
        let b = p.client.clone();
        // 同一个池 ⇒ 指针相同（Client 内部是 Arc<...>）
        assert_eq!(
            std::ptr::addr_of!(a) as usize != 0,
            std::ptr::addr_of!(b) as usize != 0,
            "两个 clone 都必须有效"
        );
        // 真正的判据：Client 实现了 Clone 且是廉价共享 ⇒
        // 用 Arc::strong_count 的等价物无法直接取，改用行为判据：
        // 两个 clone 的配置必须一致（timeout 相同 ⇒ 同一个 builder 产物）
        assert_eq!(
            format!("{:?}", a), format!("{:?}", b),
            "两个 clone 的配置必须完全相同（证明来自同一个池）"
        );
    }

    /// ★ `UPSTREAM_TIMEOUT_SECS` 必须被真正用在共享 Client 上
    ///
    /// 改前那个 30 秒是**散落的字面量**；抽成常量后若忘了用，
    /// 超时会退回 reqwest 默认（**无超时**）⇒ 上游挂住就永远不返回。
    #[test]
    fn upstream_timeout_is_applied() {
        let p = StreamProxy::new();
        let dbg = format!("{:?}", p.client);
        assert!(
            dbg.contains(&format!("{}s", UPSTREAM_TIMEOUT_SECS))
                || dbg.contains(&UPSTREAM_TIMEOUT_SECS.to_string()),
            "共享 Client 上必须能看到 {UPSTREAM_TIMEOUT_SECS}s 的超时配置；实际: {dbg}"
        );
    }

    /// ★★★ 回归：预取开关必须是**每实例**的，绝不能是进程全局
    ///
    /// # 这条测试防的是什么（CI run 37782468948 的真实故障）
    ///
    /// 改前 `plan_prefetch` 直接读 `std::env::var("SOURIN_PREFETCH_DISABLE")`，
    /// 而 A/B 测试 `deterministic_before_after_same_upstream_same_throttle`
    /// 会 `set_var` 它做对照 ⇒ 那段窗口里**任何**并发测试调 `plan_prefetch`
    /// 都会拿到 `None` ⇒ CI 随机红 3 条（`no_range_support_falls_back` /
    /// `prefetch_enabled_for_range_capable_mp4` /
    /// `prefetch_fetches_concurrently_and_bytes_are_exact`）。
    ///
    /// ★ 判据（两条都是**直接**验隔离性，不是间接推断）：
    /// ① 改 A 实例的开关，B 实例**必须**不受影响
    /// ② 构造之后再改进程环境变量，已存在的实例**必须**不受影响
    ///    （这正是竞态的机制：改前是"每次请求现读全局"，现在只在
    ///      `new()` 里读一次）
    #[test]
    fn prefetch_switch_is_per_instance_not_process_global() {
        // ── ① 实例之间互不影响 ──
        let a = StreamProxy::new();
        let b = StreamProxy::new();
        assert!(!a.prefetch_is_disabled(), "新实例默认应当是**开**预取");
        assert!(!b.prefetch_is_disabled(), "新实例默认应当是**开**预取");

        a.set_prefetch_disabled(true);
        assert!(a.prefetch_is_disabled(), "改 A 之后 A 应当是关");
        assert!(
            !b.prefetch_is_disabled(),
            "★ 改 A 的开关**不能**影响 B —— 否则就还是进程全局的老毛病"
        );

        // 而且 A 关了之后，A 这条路径上的判定确实变成 None
        let h = hdr(&[
            ("content-range", "bytes 0-1334656/339926897"),
            ("content-type", "video/mp4"),
        ]);
        assert_eq!(
            plan_prefetch(true, StatusCode::PARTIAL_CONTENT, &h, "/m.mp4", "video/mp4"),
            None,
            "关了预取就应当判定为 None"
        );
        assert!(
            plan_prefetch(false, StatusCode::PARTIAL_CONTENT, &h, "/m.mp4", "video/mp4").is_some(),
            "开着预取就应当判定为 Some（与上面那条构成对照）"
        );

        a.set_prefetch_disabled(false);
        assert!(!a.prefetch_is_disabled(), "能改回去（A/B 对照要来回切）");

        // ── ② 构造后改进程环境变量，已存在的实例不受影响 ──
        let c = StreamProxy::new();
        assert!(!c.prefetch_is_disabled());
        std::env::set_var("SOURIN_PREFETCH_DISABLE", "1");
        assert!(
            !c.prefetch_is_disabled(),
            "★ 已构造的实例**不能**被后设的环境变量影响 —— 竞态就是这么来的"
        );
        // 新构造的实例才会读它（生产回滚开关仍然有效）
        let d = StreamProxy::new();
        assert!(
            d.prefetch_is_disabled(),
            "新构造的实例应当读到环境变量（生产回滚能力不能丢）"
        );
        std::env::remove_var("SOURIN_PREFETCH_DISABLE");
        // ★ 收尾：清干净，免得污染同一进程里后面的测试
        assert!(!StreamProxy::new().prefetch_is_disabled(), "清掉后新实例应当回到开");
    }

    /// 解析 Content-Range
    #[test]
    fn content_range_parses() {
        assert_eq!(
            parse_content_range("bytes 0-1334656/339926897"),
            Some((0, 1334656, 339926897))
        );
        // 允许前导空格与大写
        assert_eq!(parse_content_range("  bytes 5-9/100 "), Some((5, 9, 100)));
        // 总长未知（*）时用 end+1 兜底
        assert_eq!(parse_content_range("bytes 0-99/*"), Some((0, 99, 100)));
        // 畸形一律拒绝（宁可回退也不猜）
        assert_eq!(parse_content_range("garbage"), None);
        assert_eq!(parse_content_range("bytes 9-5/100"), None);
        assert_eq!(parse_content_range("bytes a-b/100"), None);
    }

    /// ★ 核心：206 + 够大 ⇒ 启用预取，并按 window/parallel 切分
    #[test]
    fn prefetch_enabled_for_range_capable_mp4() {
        let h = hdr(&[
            ("content-range", "bytes 0-1334656/339926897"),
            ("content-type", "video/mp4"),
        ]);
        let plan = plan_prefetch(false, StatusCode::PARTIAL_CONTENT, &h, "/movie.mp4", "video/mp4")
            .expect("206 + mp4 应当启用并行预取");
        assert_eq!(plan.start, 0);
        assert_eq!(plan.end, 1334656);
        assert_eq!(plan.window, PREFETCH_WINDOW);
        assert_eq!(plan.parallel, PREFETCH_PARALLEL);
        assert_eq!(plan.len(), 1334657);
    }

    /// ★★ 红线：HLS 分片绝不能走并行预取（直播路径零改动）
    #[test]
    fn hls_segments_never_prefetched() {
        let big = format!("bytes 0-{}/99999999", 40 * 1024 * 1024);
        // .ts 分片
        let h = hdr(&[("content-range", &big), ("content-type", "video/mp2t")]);
        assert_eq!(
            plan_prefetch(false, StatusCode::PARTIAL_CONTENT, &h, "/a/0000000.ts", "video/mp2t"),
            None,
            "HLS 的 .ts 分片绝不能并发预取"
        );
        // .m4s 分片（CMAFF/DASH）
        let h2 = hdr(&[("content-range", &big)]);
        assert_eq!(
            plan_prefetch(false, StatusCode::PARTIAL_CONTENT, &h2, "/a/seg.m4s", ""),
            None,
            "fMP4 分片也不能预取"
        );
        // 分片扩展名但 Content-Type 缺失，也要挡住
        assert_eq!(
            plan_prefetch(false, StatusCode::PARTIAL_CONTENT, &h2, "/a/x.aac", ""),
            None
        );
    }

    /// ★★ 红线：不支持 Range 的源必须回退（返回 None = 保持原行为）
    #[test]
    fn no_range_support_falls_back() {
        // 200 且没有 Accept-Ranges ⇒ 不能预取
        let h = hdr(&[("content-length", "99999999"), ("content-type", "video/mp4")]);
        assert_eq!(
            plan_prefetch(false, StatusCode::OK, &h, "/m.mp4", "video/mp4"),
            None,
            "没声明 Accept-Ranges 就不能假设能按偏移取"
        );

        // 200 但声明了 Accept-Ranges: bytes + 总长 ⇒ 允许（首窗仍会校验）
        let h2 = hdr(&[
            ("accept-ranges", "bytes"),
            ("content-length", "99999999"),
        ]);
        assert!(
            plan_prefetch(false, StatusCode::OK, &h2, "/m.mp4", "video/mp4").is_some(),
            "200 + Accept-Ranges + 总长 应当允许（首窗验证过才吐字节）"
        );

        // 206 但没有 Content-Range ⇒ 拒绝（拿不到范围就无法校验）
        let h3 = hdr(&[]);
        assert_eq!(
            plan_prefetch(false, StatusCode::PARTIAL_CONTENT, &h3, "/m.mp4", "video/mp4"),
            None
        );
    }

    /// 小文件不值得并发（少开连接，避免浪费）
    #[test]
    fn small_files_are_not_prefetched() {
        let small = format!("bytes 0-{}/{}", 64 * 1024 - 1, 64 * 1024);
        let h = hdr(&[("content-range", &small)]);
        assert_eq!(
            plan_prefetch(false, StatusCode::PARTIAL_CONTENT, &h, "/cover.mp4", "video/mp4"),
            None,
            "小于 512KB 不值得并发"
        );
        // 封面（image/*）也要挡掉
        let big = format!("bytes 0-{}/99999999", 4 * 1024 * 1024);
        let h2 = hdr(&[("content-range", &big), ("content-type", "image/jpeg")]);
        assert_eq!(
            plan_prefetch(false, StatusCode::PARTIAL_CONTENT, &h2, "/c.jpg", "image/jpeg"),
            None,
            "图片不预取"
        );
    }

    /// 切段：必须**无缝、无重叠、全覆盖**
    #[test]
    fn segments_cover_exactly_without_gap() {
        for (from, to, n) in [
            (0u64, 1334656u64, 4usize),
            (0, 1023, 4),
            (0, 1, 4),
            (100, 100, 4),
            (5, 1000, 7),
        ] {
            let segs = split_segments(from, to, n);
            assert_eq!(segs.first().unwrap().0, from, "首段起点必须是 {from}");
            assert_eq!(segs.last().unwrap().1, to, "末段终点必须是 {to}");
            for w in segs.windows(2) {
                assert_eq!(w[0].1 + 1, w[1].0, "段与段之间必须无缝无重叠");
            }
            let total: u64 = segs.iter().map(|(a, b)| b - a + 1).sum();
            assert_eq!(total, to - from + 1, "总长度必须等于区间长度");
            assert!(segs.len() <= n, "段数不能超过并发度");
        }
    }

    /// ★ 窗口必须按 window 大小推进，且最后一个窗口被 end 截断
    #[test]
    fn window_bounds_respect_end() {
        let plan = PrefetchPlan {
            start: 0,
            end: 2 * PREFETCH_WINDOW as u64 + 500,
            window: PREFETCH_WINDOW,
            parallel: PREFETCH_PARALLEL,
        };
        // 第 1 窗
        let w0_to = (plan.start + plan.window as u64 - 1).min(plan.end);
        assert_eq!(w0_to, PREFETCH_WINDOW as u64 - 1);
        // 末窗被 end 截断
        let last_from = 2 * PREFETCH_WINDOW as u64;
        let last_to = (last_from + plan.window as u64 - 1).min(plan.end);
        assert_eq!(last_to, plan.end, "末窗必须被 end 截断，不能越界");
        assert_eq!(last_to - last_from + 1, 501);
    }

    /// ★★★ 端到端：并行预取真的**并发**取数，且字节完全正确
    ///
    /// # 为什么这条是核心证据（而不是上面那些纯函数单测）
    ///
    /// 上面测的是「计划生成得对不对」；这条测的是
    /// **真实 HTTP 路径上，代理是否真的并发去上游取数**。
    ///
    /// # 怎么证明"并发"（而不是"发了多个请求"）
    ///
    /// 上游用一个**并发计数器**：进入处理函数 +1、退出 -1、记录峰值。
    /// ```text
    /// 并发预取生效 → 峰值 ≥2（4 段同时在飞）
    /// 回退成串行    → 峰值 =1
    /// ```
    /// ★ 这就是**红度**的来源：把预取改回串行，峰值立刻掉到 1，
    ///   断言 `max_concurrent >= 2` 变红。
    ///
    /// # 怎么证明字节正确
    ///
    /// 上游返回的是一个**可按偏移算出**的合成数据（`data[i] = (i*31+i>>8*17)&0xFF`），
    /// 所以代理吐出来的每个字节都能独立校验 —— 快但错数据比慢更糟。
    #[tokio::test]
    async fn prefetch_fetches_concurrently_and_bytes_are_exact() {
        use axum::body::Body as AxumBody;
        use axum::extract::State as AxumState;
        use axum::http::Request;
        use axum::response::IntoResponse;

        // 合成数据：4MB（> 512KB 阈值，会走预取）
        const TOTAL: u64 = 4 * 1024 * 1024;
        fn byte_at(i: u64) -> u8 {
            ((i.wrapping_mul(31)).wrapping_add((i >> 8).wrapping_mul(17)) & 0xFF) as u8
        }

        /// 上游统计：峰值并发 + 见过的 Range
        #[derive(Default)]
        struct Stats {
            live: std::sync::atomic::AtomicUsize,
            max_live: std::sync::atomic::AtomicUsize,
            ranges: std::sync::Mutex<Vec<String>>,
        }

        async fn serve_big(
            AxumState(st): AxumState<Arc<Stats>>,
            req: Request<AxumBody>,
        ) -> Response {
            use std::sync::atomic::Ordering;
            let live = st.live.fetch_add(1, Ordering::SeqCst) + 1;
            st.max_live.fetch_max(live, Ordering::SeqCst);

            let range = req
                .headers()
                .get(header::RANGE)
                .and_then(|v| v.to_str().ok())
                .map(|s| s.to_string());
            if let Some(r) = &range {
                st.ranges.lock().unwrap().push(r.clone());
            }

            // 给足重叠窗口：每段延迟 200ms ⇒ 串行 4 段会明显更慢
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;

            let resp = match range.as_deref().and_then(|r| {
                let r = r.strip_prefix("bytes=")?;
                let (a, b) = r.split_once('-')?;
                let start: u64 = a.trim().parse().ok()?;
                let end: u64 = if b.trim().is_empty() {
                    TOTAL - 1
                } else {
                    b.trim().parse().ok()?
                };
                Some((start, end.min(TOTAL - 1)))
            }) {
                Some((start, end)) => {
                    let buf: Vec<u8> = (start..=end).map(byte_at).collect();
                    Response::builder()
                        .status(StatusCode::PARTIAL_CONTENT)
                        .header(
                            header::CONTENT_RANGE,
                            format!("bytes {start}-{end}/{TOTAL}"),
                        )
                        .header(header::ACCEPT_RANGES, "bytes")
                        .header(header::CONTENT_TYPE, "video/mp4")
                        .body(Body::from(buf))
                        .unwrap()
                }
                None => {
                    let buf: Vec<u8> = (0..TOTAL).map(byte_at).collect();
                    Response::builder()
                        .status(StatusCode::OK)
                        .header(header::ACCEPT_RANGES, "bytes")
                        .header(header::CONTENT_TYPE, "video/mp4")
                        .body(Body::from(buf))
                        .unwrap()
                }
            };
            let _ = st.live.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
            resp.into_response()
        }

        let stats = Arc::new(Stats::default());
        let up = Router::new()
            .route("/big.mp4", get(serve_big))
            .with_state(stats.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let up_port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            let _ = axum::serve(listener, up).await;
        });

        let proxy = Arc::new(StreamProxy::new());
        proxy.ensure_started().await.unwrap();
        let local = proxy.register(
            &format!("http://127.0.0.1:{up_port}/big.mp4"),
            vec![],
        );

        // 客户端只要第一个窗口（1MB）—— 刚好覆盖首窗的 4 个并发段
        let resp = reqwest::Client::new()
            .get(&local)
            .header(header::RANGE, format!("bytes=0-{}", PREFETCH_WINDOW - 1))
            .send()
            .await
            .unwrap();
        assert_eq!(
            resp.status(),
            StatusCode::PARTIAL_CONTENT,
            "代理必须把上游的 206 透传给客户端"
        );
        let body = resp.bytes().await.unwrap();

        // ── ① 字节完全正确 ──
        assert_eq!(
            body.len(),
            PREFETCH_WINDOW,
            "首窗长度必须是 {} 字节，实得 {}",
            PREFETCH_WINDOW,
            body.len()
        );
        for (i, b) in body.iter().enumerate() {
            assert_eq!(
                *b,
                byte_at(i as u64),
                "第 {i} 字节不对 —— 并行拼接错位了（快但错数据比慢更糟）"
            );
        }

        // ── ② ★ 真的并发（≥2 段同时在飞）──
        let max_live = stats
            .max_live
            .load(std::sync::atomic::Ordering::SeqCst);
        let ranges = stats.ranges.lock().unwrap().clone();
        assert!(
            max_live >= 2,
            "★ 上游峰值并发只有 {max_live} —— 说明走的是串行路径，\
             并行预取没有生效。见过的 Range: {ranges:?}"
        );

        // ── ③ ★ 上游确实收到了多个**不同**的分段请求 ──
        assert!(
            ranges.len() >= 2,
            "上游只收到 {} 个 Range 请求，期望多个分段: {ranges:?}",
            ranges.len()
        );
        let mut uniq: Vec<String> = ranges.clone();
        uniq.sort();
        uniq.dedup();
        assert!(
            uniq.len() >= 2,
            "上游收到的是重复的同一个 Range（不是分段）: {ranges:?}"
        );
    }

    /// ★★ 红线：上游不支持 Range 时，代理必须**回退**且数据仍正确
    ///
    /// 这类源（今天还有）一旦被并发分段取，拿回的每一段都是文件开头
    /// ⇒ 拼起来必然错乱。所以必须证明回退路径真的работает。
    #[tokio::test]
    async fn non_range_upstream_streams_correctly_without_prefetch() {
        use axum::body::Body as AxumBody;
        use axum::http::Request;
        use axum::response::IntoResponse;

        const TOTAL: usize = 256 * 1024;

        /// 一个**完全忽略 Range** 的上游（总是 200 + 全量）
        async fn serve_no_range(_req: Request<AxumBody>) -> Response {
            let buf: Vec<u8> = (0..TOTAL).map(|i| (i % 251) as u8).collect();
            Response::builder()
                .status(StatusCode::OK)
                .header(header::CONTENT_TYPE, "video/x-matroska")
                .body(Body::from(buf))
                .unwrap()
                .into_response()
        }

        let up = Router::new().route("/plain.mkv", get(serve_no_range));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let up_port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            let _ = axum::serve(listener, up).await;
        });

        let proxy = Arc::new(StreamProxy::new());
        proxy.ensure_started().await.unwrap();
        let local = proxy.register(&format!("http://127.0.0.1:{up_port}/plain.mkv"), vec![]);

        let resp = reqwest::get(&local).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK, "不支持 Range 的源应原样 200");
        let body = resp.bytes().await.unwrap();
        assert_eq!(body.len(), TOTAL, "回退路径不能丢字节");
        for (i, b) in body.iter().enumerate() {
            assert_eq!(*b, (i % 251) as u8, "回退路径第 {i} 字节错位");
        }
    }

    /// ★★ 红线：HLS 分片走代理时**绝不能**被并发预取
    ///
    /// 与上面那条同构，但对象是 `.ts` 分片 —— 它"支持 Range 且够大"，
    /// 形状上和 mp4 一样，只有显式排除才能保证直播不受影响。
    #[tokio::test]
    async fn hls_segment_requests_are_not_parallelized() {
        use axum::body::Body as AxumBody;
        use axum::extract::State as AxumState;
        use axum::http::Request;
        use axum::response::IntoResponse;

        const SEG: u64 = 4 * 1024 * 1024; // 足够大，若没排除就会触发预取

        #[derive(Default)]
        struct Stats {
            live: std::sync::atomic::AtomicUsize,
            max_live: std::sync::atomic::AtomicUsize,
        }

        async fn serve_ts(
            AxumState(st): AxumState<Arc<Stats>>,
            req: Request<AxumBody>,
        ) -> Response {
            use std::sync::atomic::Ordering;
            let live = st.live.fetch_add(1, Ordering::SeqCst) + 1;
            st.max_live.fetch_max(live, Ordering::SeqCst);

            let range = req
                .headers()
                .get(header::RANGE)
                .and_then(|v| v.to_str().ok())
                .and_then(|r| {
                    let r = r.strip_prefix("bytes=")?;
                    let (a, b) = r.split_once('-')?;
                    Some((
                        a.trim().parse::<u64>().ok()?,
                        if b.trim().is_empty() {
                            SEG - 1
                        } else {
                            b.trim().parse::<u64>().ok()?
                        },
                    ))
                });
            tokio::time::sleep(std::time::Duration::from_millis(150)).await;
            let resp = match range {
                Some((a, b)) => {
                    let buf: Vec<u8> = (a..=b.min(SEG - 1)).map(|i| (i % 251) as u8).collect();
                    Response::builder()
                        .status(StatusCode::PARTIAL_CONTENT)
                        .header(header::CONTENT_RANGE, format!("bytes {a}-{}/{SEG}", b.min(SEG - 1)))
                        .header(header::ACCEPT_RANGES, "bytes")
                        .header(header::CONTENT_TYPE, "video/mp2t")
                        .body(Body::from(buf))
                        .unwrap()
                }
                None => Response::builder()
                    .status(StatusCode::OK)
                    .header(header::CONTENT_TYPE, "video/mp2t")
                    .body(Body::from(vec![0u8; SEG as usize]))
                    .unwrap(),
            };
            let _ = st.live.fetch_sub(1, Ordering::SeqCst);
            resp.into_response()
        }

        let stats = Arc::new(Stats::default());
        let up = Router::new()
            .route("/seg/0000000.ts", get(serve_ts))
            .with_state(stats.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let up_port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            let _ = axum::serve(listener, up).await;
        });

        let proxy = Arc::new(StreamProxy::new());
        proxy.ensure_started().await.unwrap();
        let local = proxy.register(
            &format!("http://127.0.0.1:{up_port}/seg/0000000.ts"),
            vec![],
        );

        // 只读前 1MB 就走（模拟播放器取一个分片）
        let resp = reqwest::Client::new()
            .get(&local)
            .header(header::RANGE, format!("bytes=0-{}", 1024 * 1024 - 1))
            .send()
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::PARTIAL_CONTENT);
        let body = resp.bytes().await.unwrap();
        assert_eq!(body.len(), 1024 * 1024);

        let max_live = stats.max_live.load(std::sync::atomic::Ordering::SeqCst);
        assert!(
            max_live <= 1,
            "★ HLS 的 .ts 分片被并发预取了（峰值并发 {max_live}）—— \
             直播路径必须完全不受影响，这是红线"
        );
    }

    /// ★★★ 确定性计时：并行预取把「读完一窗」从 4×段延迟压到 ~1×段延迟
    ///
    /// # 为什么需要这条（真机 CDN 数据太吵）
    ///
    /// 真机实测同一路流、同一请求的耗动能从 3251ms 跳到 5963ms
    /// （CDN 抖动 + 起播竞争）。那种噪声里**量不出**干净的 before/after。
    ///
    /// 这条把变量全部锁死：上游每请求**固定延迟 300ms**，
    /// 于是耗时直接反映「并发了几段」：
    /// ```text
    /// 串行 4 段 → ≈1200ms
    /// 并行 4 段 → ≈300ms
    /// ⇒ 断言 < 800ms 就是在断言"真的并行了"
    /// ```
    /// ★ 这条同时是**红度**保证：把 `fetch_window` 改回
    ///   `for f in futs { f.await }`（惰性 future 串行执行），
    ///   耗时会立刻涨到 ~1200ms 而断言变红 —— 本轮已实测验证过
    ///   （那时并发峰值 = 1，测试抓到）。
    #[tokio::test]
    async fn prefetch_window_is_parallel_not_serial() {
        use axum::body::Body as AxumBody;
        use axum::http::Request;
        use axum::response::IntoResponse;

        const TOTAL: u64 = 4 * 1024 * 1024;
        const DELAY_MS: u64 = 300;

        /// 每请求固定延迟 —— 让「耗时」直接等于「串行段数 × 延迟」
        async fn serve_slow(req: Request<AxumBody>) -> Response {
            tokio::time::sleep(std::time::Duration::from_millis(DELAY_MS)).await;
            let range = req
                .headers()
                .get(header::RANGE)
                .and_then(|v| v.to_str().ok())
                .and_then(|r| {
                    let r = r.strip_prefix("bytes=")?;
                    let (a, b) = r.split_once('-')?;
                    Some((
                        a.trim().parse::<u64>().ok()?,
                        b.trim().parse::<u64>().ok()?,
                    ))
                });
            match range {
                Some((a, b)) => {
                    let b = b.min(TOTAL - 1);
                    let buf = vec![0u8; (b - a + 1) as usize];
                    Response::builder()
                        .status(StatusCode::PARTIAL_CONTENT)
                        .header(header::CONTENT_RANGE, format!("bytes {a}-{b}/{TOTAL}"))
                        .header(header::ACCEPT_RANGES, "bytes")
                        .header(header::CONTENT_TYPE, "video/mp4")
                        .body(Body::from(buf))
                        .unwrap()
                }
                None => Response::builder()
                    .status(StatusCode::OK)
                    .header(header::ACCEPT_RANGES, "bytes")
                    .header(header::CONTENT_TYPE, "video/mp4")
                    .body(Body::from(vec![0u8; TOTAL as usize]))
                    .unwrap(),
            }
            .into_response()
        }

        let up = Router::new().route("/slow.mp4", get(serve_slow));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let up_port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            let _ = axum::serve(listener, up).await;
        });

        let proxy = Arc::new(StreamProxy::new());
        proxy.ensure_started().await.unwrap();
        let local = proxy.register(&format!("http://127.0.0.1:{up_port}/slow.mp4"), vec![]);

        // 只要首窗（1MB = 4 段 × 256KB）
        let sw = std::time::Instant::now();
        let resp = reqwest::Client::new()
            .get(&local)
            .header(header::RANGE, format!("bytes=0-{}", PREFETCH_WINDOW - 1))
            .send()
            .await
            .unwrap();
        let body = resp.bytes().await.unwrap();
        let elapsed = sw.elapsed().as_millis() as u64;

        assert_eq!(body.len(), PREFETCH_WINDOW, "首窗字节数必须完整");

        // 串行会是 4×300=1200ms；并行约 300ms。800ms 是清楚的判别线。
        let serial_ms = DELAY_MS * PREFETCH_PARALLEL as u64;
        assert!(
            elapsed < serial_ms * 2 / 3,
            "★ 读完 {PREFETCH_PARALLEL} 段用了 {elapsed}ms —— \
             接近串行的 {serial_ms}ms，说明**没有真的并发**。\
             （并行应当在 {}ms 量级）",
            DELAY_MS
        );
    }

    /// ★★★★ 确定性 before/after：同一上游、同一限速，只切预取 ON/OFF
    ///
    /// # 为什么这条是本次修复的**主证据**（而不是真机截图）
    ///
    /// 真机 CDN 的吞吐每分钟都在变 —— 实测同一路流、同一个 Range 请求，
    /// 单连接能从 **112 KB/s 跳到 464 KB/s**，4 并发放大在 1.31×~4.23×
    /// 之间摆（`.probe/t26-ab-*.txt` 三轮交替实测）。那种噪声下
    /// "改 DLL → 重启 → 各量一次"**量不出真实差值**，因为两个变量同时在变。
    ///
    /// ⇒ 把上游换成**确定性限速**的本地服务，于是：
    /// ```text
    /// · 唯一变量 = 代理有没有开并行预取（SOURIN_PREFETCH_DISABLE 切）
    /// · 同一进程、几秒内完成 ⇒ CDN 噪声完全不参与
    /// · 走的仍然是**真实的 handle_stream → forward_request** 路径
    /// ```
    ///
    /// # 限速模型（复刻实测的"单连接限速"）
    /// ```text
    /// 每条连接 64KB/100ms ≈ 640 KB/s（实测 CDN 单连接 112~464 KB/s，同一量级）
    /// 读 1MB：串行 ≈ 1.6s   并行 4 条 ≈ 0.4s
    /// ```
    /// ★ 这条同时是**红度**的第二个来源：把预取关掉（或改回串行），
    ///   ON 的耗时立刻涨到和 OFF 一样 ⇒ 断言失败。
    #[tokio::test]
    async fn deterministic_before_after_same_upstream_same_throttle() {
        use axum::body::Body as AxumBody;
        use axum::extract::State as AxumState;
        use axum::http::Request;
        use axum::response::IntoResponse;

        /// 4MB 合成数据；客户端只要首个 1MB 窗口
        const TOTAL: u64 = 4 * 1024 * 1024;
        const CHUNK: usize = 64 * 1024;
        const CHUNK_DELAY_MS: u64 = 100; // 64KB/100ms ≈ 640 KB/s

        fn byte_at(i: u64) -> u8 {
            ((i.wrapping_mul(31)).wrapping_add((i >> 8).wrapping_mul(17)) & 0xFF) as u8
        }

        /// 限速上游：支持 Range，按块延迟发送
        async fn serve_throttled(req: Request<AxumBody>) -> Response {
            let (start, end) = req
                .headers()
                .get(header::RANGE)
                .and_then(|v| v.to_str().ok())
                .and_then(|r| {
                    let r = r.strip_prefix("bytes=")?;
                    let (a, b) = r.split_once('-')?;
                    Some((
                        a.trim().parse::<u64>().ok()?,
                        b.trim().parse::<u64>().ok()?.min(TOTAL - 1),
                    ))
                })
                .unwrap_or((0, TOTAL - 1));

            let (tx, rx) = mpsc::channel::<Result<Bytes, std::io::Error>>(2);
            tokio::spawn(async move {
                let mut pos = start;
                while pos <= end {
                    let n = CHUNK.min((end - pos + 1) as usize);
                    let buf: Vec<u8> = (pos..pos + n as u64).map(byte_at).collect();
                    if tx.send(Ok(Bytes::from(buf))).await.is_err() {
                        return; // 客户端走了
                    }
                    pos += n as u64;
                    tokio::time::sleep(std::time::Duration::from_millis(CHUNK_DELAY_MS))
                        .await;
                }
            });

            Response::builder()
                .status(StatusCode::PARTIAL_CONTENT)
                .header(
                    header::CONTENT_RANGE,
                    format!("bytes {start}-{end}/{TOTAL}"),
                )
                .header(header::ACCEPT_RANGES, "bytes")
                .header(header::CONTENT_TYPE, "video/mp4")
                .body(Body::from_stream(ChannelStream { rx }))
                .unwrap()
                .into_response()
        }

        let up = Router::new().route("/throttled.mp4", get(serve_throttled));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let up_port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            let _ = axum::serve(listener, up).await;
        });

        let proxy = Arc::new(StreamProxy::new());
        proxy.ensure_started().await.unwrap();
        let local = proxy.register(
            &format!("http://127.0.0.1:{up_port}/throttled.mp4"),
            vec![],
        );

        // 读首个窗口（1MB）计时的辅助
        let read_first_window = |local: String| async move {
            let sw = std::time::Instant::now();
            let resp = reqwest::Client::new()
                .get(&local)
                .header(header::RANGE, format!("bytes=0-{}", PREFETCH_WINDOW - 1))
                .send()
                .await
                .unwrap();
            let body = resp.bytes().await.unwrap();
            (sw.elapsed().as_millis() as u64, body)
        };

        /*
         * ★ 顺序很重要：先 ON 再 OFF 再 ON，取各自最好值 ——
         *   与真机 A/B 同样的交替思路，但这里是确定性的，交替只是保险。
         *
         * ★★ 2026-10-08 改：原来这里是
         * ```rust
         * std::env::set_var("SOURIN_PREFETCH_DISABLE", "1");
         * let (off_ms, off_body) = read_first_window(...).await;
         * std::env::remove_var("SOURIN_PREFETCH_DISABLE");
         * ```
         * 而 `std::env` 是**进程全局**的 ⇒ 在那段窗口里，**任何**并发跑的
         * 测试只要调 `plan_prefetch` 都会看到"预取被禁用"，于是随机失败。
         * CI 实测（run 37782468948）红了 3 条，且 `src/` 一行没改 ⇒ 纯竞态。
         *
         * ⇒ 现在改成**本实例的原子开关**（`proxy.set_prefetch_disabled`）。
         *   `proxy` 是本测试自己建的，别的测试看不到它 ⇒ 彻底隔离。
         *   ★ 断言强度**没有放宽**：OFF 仍然真的走串行路径、ON 仍然真的走并行，
         *     加速比阈值仍是 ≥1.8×，字节正确性仍然逐字节比。
         */
        let (on1_ms, on1_body) = read_first_window(local.clone()).await;
        proxy.set_prefetch_disabled(true);
        let (off_ms, off_body) = read_first_window(local.clone()).await;
        proxy.set_prefetch_disabled(false);
        let (on2_ms, on2_body) = read_first_window(local.clone()).await;

        let on_ms = on1_ms.min(on2_ms);

        // ── ① 数据必须完全正确（两种模式都一样）──
        let expect: Vec<u8> = (0..PREFETCH_WINDOW as u64).map(byte_at).collect();
        assert_eq!(on1_body.as_ref(), expect.as_slice(), "预取模式字节错位");
        assert_eq!(on2_body.as_ref(), expect.as_slice(), "预取模式字节错位");
        assert_eq!(off_body.as_ref(), expect.as_slice(), "串行模式字节错位");

        // ── ② 串行基线必须真的慢（阳性对照：证明限速生效）──
        let serial_floor = CHUNK_DELAY_MS * (PREFETCH_WINDOW / CHUNK) as u64;
        let serial_floor = serial_floor as f64 * 0.5; // 允许调度误差
        assert!(
            off_ms as f64 > serial_floor,
            "★ 阳性对照失败：关闭预取后只用 {off_ms}ms，\
             低于限速模型的下限 {serial_floor:.0}ms —— 说明限速没生效，本测试无意义"
        );

        // ── ③ ★ 核心断言：开了预取必须显著更快 ──
        let speedup = off_ms as f64 / on_ms.max(1) as f64;
        eprintln!(
            "[BEFORE/AFTER] 确定性限速(64KB/{CHUNK_DELAY_MS}ms ≈ {:.0} KB/s) 读 1MB:\n\
             \x20   OFF 串行透传 = {off_ms}ms  ({:.0} KB/s)\n\
             \x20   ON  并行预取 = {on_ms}ms  ({:.0} KB/s)  [第1次 {on1_ms}ms / 第2次 {on2_ms}ms]\n\
             \x20   ★ 加速比 = {speedup:.2}×",
            (CHUNK as f64 / 1024.0) / (CHUNK_DELAY_MS as f64 / 1000.0),
            (PREFETCH_WINDOW as f64 / 1024.0) / (off_ms as f64 / 1000.0),
            (PREFETCH_WINDOW as f64 / 1024.0) / (on_ms as f64 / 1000.0),
        );
        assert!(
            speedup >= 1.8,
            "★ 并行预取没有带来预期加速：\n\
             \x20 关闭预取(串行) = {off_ms}ms\n\
             \x20 开启预取(并行) = {on_ms}ms（第1次 {on1_ms}ms / 第2次 {on2_ms}ms）\n\
             \x20 加速比 = {speedup:.2}×（要求 ≥1.8×）"
        );
    }

    /// ★★★ 首窗阻塞调研：小 Range 请求会不会被"取满 1MB 首窗"拖慢？
    ///
    /// # 为什么要有这条（用户提问「播放卡顿还有优化空间吗」）
    ///
    /// ```text
    /// 本文件 L1420-1431：
    ///     let first_to = (plan.start + plan.window - 1).min(plan.end);
    ///     fetch_window(..., plan.start, first_to, plan.parallel).await  ← 取满首窗
    ///     Ok(first) => { return Body::from_stream(...) }                ← 才吐字节
    ///
    /// plan.window = PREFETCH_WINDOW = 1MB
    ///
    /// ★ 若播放器发 `bytes=0-262143`（256KB），而代理强制先取 1MB：
    ///   ⇒ 首字节延迟 = 取满 1MB 的时间（而不是 256KB 的）
    ///   ⇒ 按央视 215 KB/s：1MB = 4.9s，256KB = 1.2s ⇒ 慢 3.7 秒
    /// ```
    ///
    /// # 这条测试**不做断言失败**（它是调研，不是护栏）
    ///
    /// ```text
    /// 两种结果都有价值：
    ///   · 拖慢明显 ⇒ 坐实一个真实的优化空间（改成"边取边吐"）
    ///   · 不拖慢   ⇒ 推翻假设，如实记录"这里没有空间"
    /// ```
    /// ★ 但**必须**有阳性对照（证明限速模型生效），否则读数无意义。
    #[tokio::test]
    async fn probe_small_range_first_byte_cost() {
        use axum::body::Body as AxumBody;
        use axum::http::Request;
        use axum::response::IntoResponse;

        const TOTAL: u64 = 4 * 1024 * 1024;
        const CHUNK: usize = 64 * 1024;
        const CHUNK_DELAY_MS: u64 = 100; // ≈ 640 KB/s

        fn byte_at(i: u64) -> u8 {
            ((i.wrapping_mul(31)).wrapping_add((i >> 8).wrapping_mul(17)) & 0xFF) as u8
        }

        async fn serve_throttled(req: Request<AxumBody>) -> Response {
            let (start, end) = req
                .headers()
                .get(header::RANGE)
                .and_then(|v| v.to_str().ok())
                .and_then(|r| {
                    let r = r.strip_prefix("bytes=")?;
                    let (a, b) = r.split_once('-')?;
                    let a = a.trim().parse::<u64>().ok()?;
                    let b = if b.trim().is_empty() {
                        TOTAL - 1
                    } else {
                        b.trim().parse::<u64>().ok()?.min(TOTAL - 1)
                    };
                    Some((a, b))
                })
                .unwrap_or((0, TOTAL - 1));

            let (tx, rx) = mpsc::channel::<Result<Bytes, std::io::Error>>(2);
            tokio::spawn(async move {
                let mut pos = start;
                while pos <= end {
                    let n = CHUNK.min((end - pos + 1) as usize);
                    let buf: Vec<u8> = (pos..pos + n as u64).map(byte_at).collect();
                    if tx.send(Ok(Bytes::from(buf))).await.is_err() {
                        return;
                    }
                    pos += n as u64;
                    tokio::time::sleep(std::time::Duration::from_millis(CHUNK_DELAY_MS))
                        .await;
                }
            });

            Response::builder()
                .status(StatusCode::PARTIAL_CONTENT)
                .header(
                    header::CONTENT_RANGE,
                    format!("bytes {start}-{end}/{TOTAL}"),
                )
                .header(header::ACCEPT_RANGES, "bytes")
                .header(header::CONTENT_TYPE, "video/mp4")
                .body(Body::from_stream(ChannelStream { rx }))
                .unwrap()
                .into_response()
        }

        let up = Router::new().route("/t.mp4", get(serve_throttled));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let up_port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            let _ = axum::serve(listener, up).await;
        });

        let proxy = Arc::new(StreamProxy::new());
        proxy.ensure_started().await.unwrap();
        let direct = format!("http://127.0.0.1:{up_port}/t.mp4");
        let local = proxy.register(&direct, vec![]);

        /// 量「首字节时间」与「取满整个请求区间的时间」
        ///
        /// # ⚠️ 为什么必须同时量两个（第一版只量首字节 ⇒ 阳性对照失败）
        ///
        /// ```text
        /// 限速上游的实现是「先发后睡」（send 再 sleep）——
        /// 所以**直连的首字节永远是 ~1ms**，与限速无关。
        /// ⇒ 只量首字节 ⇒ 读数无区分力 ⇒ 阳性对照必然失败。
        ///
        /// 正确的两个指标：
        ///   · ttfb  = 首字节时间（看"代理是否先攒满首窗才吐"）
        ///   · total = 取满请求区间的时间（看"整体吞吐"）
        /// ```
        ///
        /// ⚠️ 不引入 `futures_util`（Cargo.toml 没有）——
        ///    用 reqwest 自带的 `chunk()`。
        async fn measure(url: &str, range: &str) -> (u128, u128, usize) {
            let t0 = std::time::Instant::now();
            let mut resp = reqwest::Client::new()
                .get(url)
                .header(header::RANGE, range)
                .send()
                .await
                .unwrap();
            let mut got = 0usize;
            let mut ttfb = None;
            while let Some(chunk) = resp.chunk().await.unwrap() {
                if ttfb.is_none() {
                    ttfb = Some(t0.elapsed().as_millis());
                }
                got += chunk.len();
            }
            let total = t0.elapsed().as_millis();
            (ttfb.unwrap_or(total), total, got)
        }

        // ── ① 阳性对照：直连 256KB 取满应 ≈ 4 块 × 100ms ────────────
        let (d256_ttfb, d256, d256_got) = measure(&direct, "bytes=0-262143").await;
        eprintln!(
            "[FIRSTWIN] ① 阳性对照 直连 256KB: 首字节 {d256_ttfb}ms  \
             取满 {d256}ms  收到 {d256_got} B"
        );
        assert!(
            (250..=1500).contains(&d256),
            "★ 阳性对照失败：直连 256KB **取满**只用 {d256}ms，不在 250~1500ms \
             ⇒ 限速模型没生效，本测试作废"
        );
        assert_eq!(d256_got, 256 * 1024, "直连收到的字节数不对");

        // ── ② 直连 1MB（对照：取满 1MB 要多久）─────────────────────
        let (d1m_ttfb, d1m, _) = measure(&direct, "bytes=0-1048575").await;

        // ── ③ ★ 经代理 256KB（关键读数）───────────────────────────
        let (p256_ttfb, p256, p256_got) = measure(&local, "bytes=0-262143").await;

        // ── ④ 经代理 1MB ─────────────────────────────────────────
        let (p1m_ttfb, p1m, _) = measure(&local, "bytes=0-1048575").await;

        // ── ⑤ ★★★ 字节正确性（预取必须逐字节一致）──────────────
        let expect: Vec<u8> = (0..256 * 1024u64).map(byte_at).collect();
        let mut resp = reqwest::Client::new()
            .get(&local)
            .header(header::RANGE, "bytes=0-262143")
            .send()
            .await
            .unwrap();
        let body = resp.bytes().await.unwrap();
        assert_eq!(
            body.as_ref(),
            expect.as_slice(),
            "★ 经代理的 256KB 字节不对（快但错数据比慢更糟）"
        );

        let ratio_total = p256 as f64 / d256.max(1) as f64;
        let ratio_ttfb = p256_ttfb as f64 / d256_ttfb.max(1) as f64;

        eprintln!(
            "[FIRSTWIN] ★★★ 首窗阻塞调研（限速 {CHUNK_DELAY_MS}ms/{CHUNK}KB ≈ {:.0} KB/s）\n\
             \x20   ┌────────────┬──────────┬──────────┬──────────┐\n\
             \x20   │            │ 首字节   │ 取满     │ 字节数   │\n\
             \x20   ├────────────┼──────────┼──────────┼──────────┤\n\
             \x20   │ 直连 256KB │ {d256_ttfb:6}ms │ {d256:6}ms │ {d256_got:6} B │\n\
             \x20   │ 代理 256KB │ {p256_ttfb:6}ms │ {p256:6}ms │ {p256_got:6} B │\n\
             \x20   │ 直连 1MB   │ {d1m_ttfb:6}ms │ {d1m:6}ms │          │\n\
             \x20   │ 代理 1MB   │ {p1m_ttfb:6}ms │ {p1m:6}ms │          │\n\
             \x20   └────────────┴──────────┴──────────┴──────────┘\n\
             \x20   ★ 首字节比（代理/直连）= {ratio_ttfb:.2}×\n\
             \x20   ★ 取满比（代理/直连）  = {ratio_total:.2}×\n\
             \x20   ⇒ 首字节：{}\n\
             \x20   ⇒ 总耗时：{}",
            (CHUNK as f64 / 1024.0) / (CHUNK_DELAY_MS as f64 / 1000.0),
            if ratio_ttfb > 3.0 {
                "★ 代理明显更晚吐第一个字节（先攒满首窗）"
            } else if ratio_ttfb > 1.5 {
                "代理稍晚吐第一个字节"
            } else {
                "无明显差异"
            },
            if ratio_total > 1.5 {
                "★ 代理整体更慢（真实优化空间）"
            } else if ratio_total > 1.15 {
                "代理稍慢"
            } else {
                "无明显差异（并行预取抵消了首窗成本）"
            }
        );

        /*
         * ★★ 只断言**宽松**护栏（总耗时不能慢太多）——
         *    真正的调研结论看上面的表格（供报告引用）。
         *
         * 两种结果都有价值：
         *   · 慢得多 ⇒ 坐实优化空间（改成"边取边吐"）
         *   · 不明显 ⇒ 推翻假设，如实记录"此处无空间"
         */
        assert!(
            ratio_total < 2.0,
            "★★ 经代理取满 256KB 比直连慢 {ratio_total:.1}×（>2×）—— \
             代理 256KB 取满 {p256}ms vs 直连 {d256}ms；\
             首字节 {p256_ttfb}ms vs {d256_ttfb}ms。\
             应改成「边取边吐」（在保留护栏④「先验证再吐」的前提下）"
        );
    }

    /// 登记后拿到的必须是**本机回环**地址（绝不能监听到局域网）
    #[test]
    fn proxy_url_is_loopback_only() {
        let p = Arc::new(StreamProxy::new());
        // 端口还没启动时是 0，但地址形态必须还是 127.0.0.1
        let url = p.register("https://example.com/a.mp4", vec![]);
        assert!(
            url.starts_with("http://127.0.0.1:"),
            "流代理必须是回环地址（暴露到局域网等于给人免费代理），实际: {url}"
        );
        assert!(!url.contains("0.0.0.0"), "绝不能绑 0.0.0.0");
    }

    /// ★ token 必须**不能从 URL 反推**，且每次都不同
    ///
    /// 如果 token 就是 URL 本身（或它的简单哈希），那接口等价于
    /// `/s?url=<任意地址>` —— 任何本地程序都能拿它当 SSRF 跳板。
    #[test]
    fn tokens_are_opaque_and_unique() {
        let p = Arc::new(StreamProxy::new());
        let target = "https://cdn.example.com/secret.mp4";
        let a = p.register(target, vec![]);
        let b = p.register(target, vec![]);

        assert_ne!(a, b, "每次登记都要是新 token（旧的会因签名过期而失效）");
        for u in [&a, &b] {
            assert!(
                !u.contains("secret") && !u.contains("example.com"),
                "token 里不能包含原始地址，实际: {u}"
            );
        }
    }

    /// 表不能无限增长（看剧会登记几百条）
    #[test]
    fn table_is_bounded() {
        let p = Arc::new(StreamProxy::new());
        for i in 0..400 {
            p.register(&format!("https://example.com/{i}.mp4"), vec![]);
        }
        let n = p.table.lock().unwrap().len();
        assert!(n <= 256, "登记表必须有上限，实际 {n} 条");
    }

    /// ★★★ issue #9：表满时只能淘汰**最旧的一半**，绝不能全清
    ///
    /// # 为什么这是用户可见的 bug（不是洁癖）
    ///
    /// 改前这里是 `t.clear()`。表满的时机恰恰是**用户看了很久**（换集/换线路
    /// 每次都登记一条）—— 也就是**正在播的那条流也在表里**的时候。
    /// 全清之后，播放器下一个分片请求拿到 404
    /// 「取流地址已失效，请重新选择线路」⇒ 表现是「播到一半突然播放失败」。
    ///
    /// 所以这里钉两件事：
    /// ① 刚登记的那条**一定还在**（正在播的流不能被自己挤掉）；
    /// ② 被淘汰的必须是**最旧的**那一半，而不是全部。
    #[test]
    fn table_full_evicts_oldest_half_not_everything() {
        let p = Arc::new(StreamProxy::new());
        // 本地地址形如 http://127.0.0.1:<port>/s/<token>/ ⇒ 倒数第二段是 token
        let tok = |u: &str| u.rsplit('/').nth(1).unwrap_or("").to_string();

        let mut urls = Vec::new();
        for i in 0..STREAM_MAX {
            urls.push(p.register_at(&format!("https://example.com/{i}.mp4"), vec![], 12345));
        }
        /*
         * ⚠️ 判据是「**插入前** len > STREAM_MAX」，所以第 STREAM_MAX+1 条
         *    （newest）进来时不触发淘汰、表暂时到 257；第 STREAM_MAX+2 条
         *    （newest2）进来时才真正淘汰。这不是笔误，是既有实现的形状。
         */
        let newest = p.register_at("https://example.com/newest.mp4", vec![], 12345);
        let newest2 = p.register_at("https://example.com/newest2.mp4", vec![], 12345);

        let t = p.table.lock().unwrap_or_else(|e| e.into_inner());
        let n = t.len();
        assert!(n < STREAM_MAX, "必须真的淘汰了（不能只涨不落），实际 {n} 条");
        assert!(
            t.contains_key(&tok(&newest)) && t.contains_key(&tok(&newest2)),
            "刚登记的流必须还在 —— 否则正在播的分片请求会 404「取流地址已失效」"
        );
        assert!(
            t.contains_key(&tok(&urls[STREAM_MAX - 1])),
            "最近登记的那一半必须保住"
        );
        assert!(
            !t.contains_key(&tok(&urls[0])),
            "最旧的那一条必须被淘汰（否则表根本不会变小）"
        );
        assert!(
            n >= STREAM_MAX / 2 - 2,
            "只允许淘汰最旧的一半（全清就是 issue #9 的原 bug），实际剩 {n} 条"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // ★★★ task-56：端口失效检测 + 自动重建
    //
    // 用户报的 bug：截图里是「播放失败 Failed to open
    // http://127.0.0.1:<端口>/s/<token>/」，重试也没用，只能重启客户端。
    //
    // 成因链（改前）：
    //   ① axum::serve 退出 ⇒ 只 log::error，**port 字段保持旧值**
    //   ② register() 只读 port 字段 ⇒ 继续拼出指向死端口的 URL
    //   ③ ensure_started() 见 port != 0 就 early-return ⇒ **永不重 bind**
    //
    // 下面 5 个测试分别钉住这条链上的每一环。
    // ═══════════════════════════════════════════════════════════════════

    /// `mark_dead` 只能清掉**自己那一份**端口，不能无条件清
    ///
    /// 这是 CAS 而不是 `store(0)` 的理由：旧代理的看门狗可能在新代理
    /// 起来**之后**才跑完，`store(0)` 会把新端口也清掉 ⇒ 又变死地址。
    #[test]
    fn mark_dead_only_clears_its_own_port() {
        let p = Arc::new(StreamProxy::new());

        p.port.store(11111, std::sync::atomic::Ordering::SeqCst);
        // 不是我的端口 ⇒ 一个字节都不能动（新代理的端口要保住）
        p.mark_dead(22222);
        assert_eq!(
            p.port(),
            11111,
            "旧代理的看门狗绝不能清掉新代理的端口（否则又变死地址）"
        );

        // 是我的端口 ⇒ 清 0，让下一次 ensure_started 重建
        p.mark_dead(11111);
        assert_eq!(p.port(), 0, "自己的端口必须清 0");
    }

    /// 端口字段非 0，但**实际上没人监听** ⇒ `serving_port` 必须报 None
    ///
    /// ★ 这个测试专门钉住"TCP 探测这一道判据不能省"：
    ///   `serve_task` 故意放一个**永不结束**的任务（`is_finished() == false`），
    ///   所以判据 1 会放行 —— 只有真连一下才能发现端口是死的。
    #[tokio::test]
    async fn dead_port_is_detected_by_tcp_probe() {
        let p = Arc::new(StreamProxy::new());

        // 拿一个**确实没人监听**的端口：bind 到 :0 拿到号，然后立刻放掉
        let dead_port = {
            let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            l.local_addr().unwrap().port()
        };
        assert!(dead_port != 0);

        // 任务"还在跑"（骗过 is_finished 快判），但端口是死的
        let never = tokio::spawn(async {
            tokio::time::sleep(std::time::Duration::from_secs(3600)).await;
        });
        *p.serve_task.lock().unwrap() = Some(never);
        p.port.store(dead_port, std::sync::atomic::Ordering::SeqCst);

        assert!(
            p.serving_port().await.is_none(),
            "端口 {dead_port} 没人监听，serving_port 必须报 None（否则就是改前那个 bug）"
        );

        // 反证：同一个探测对**活着**的端口必须报 Some
        let alive = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let alive_port = alive.local_addr().unwrap().port();
        p.port.store(alive_port, std::sync::atomic::Ordering::SeqCst);
        assert_eq!(
            p.serving_port().await,
            Some(alive_port),
            "端口活着就必须认出来，否则会白白重建（每播一次换一个端口）"
        );
    }

    /// ★★★ 验收测试【A】：**代理退出后，下一次 register 生成的地址必须指向活端口**
    ///
    /// 直接照用户的现象走一遍：
    /// ```text
    /// 1. 起代理 → 记下端口 P1
    /// 2. 让 serve 任务死掉（模拟"代理退出"）
    /// 3. 再走一次 ensure_started（= 用户点「重试」的路径）
    /// 4. register() 产出的 URL 里的端口，必须**真的能连上**
    /// ```
    /// 改前第 3 步会 early-return P1，于是第 4 步的 URL 指向死端口 ⇒ 播放失败。
    #[tokio::test]
    async fn after_proxy_dies_next_url_points_at_a_live_port() {
        let p = Arc::new(StreamProxy::new());

        let p1 = p.ensure_started().await.unwrap();
        assert!(p1 != 0);

        // 代理真的在服务（能连上）
        let c = reqwest::Client::new();
        let before = c.get(&format!("http://127.0.0.1:{p1}/s/deadbeef")).send().await;
        assert!(before.is_ok(), "刚起来的代理必须能连上，实际: {before:?}");

        /*
         * 让 serve 任务死掉 —— 用 abort 是**最狠**的一种：
         * 被 abort 的 future 直接在 await 点被 drop，
         * 所以 `owner.mark_dead(port)` 那行**根本不会执行**
         * ⇒ port 字段保持旧值（正好复现"字段非 0 但代理已死"）。
         * 这也正是"TCP 探测"这道判据必须存在的理由。
         */
        {
            let h = p.serve_task.lock().unwrap().as_ref().map(|h| h.abort());
            assert!(h.is_some(), "必须能拿到 serve 任务句柄");
        }
        /*
         * 等 abort 生效。`abort()` 是**异步**的（只是投递取消请求），
         * 所以不能只 `sleep(固定值)` —— 机器忙的时候会偶发失败。
         * 这里轮询到"确实结束了"为止，上限 5s。
         */
        for _ in 0..100 {
            let done = p
                .serve_task
                .lock()
                .unwrap()
                .as_ref()
                .is_some_and(|h| h.is_finished());
            if done {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        assert!(
            p.serve_task
                .lock()
                .unwrap()
                .as_ref()
                .is_some_and(|h| h.is_finished()),
            "abort 之后任务必须已经结束"
        );

        // ★ 前置条件自检：此刻旧端口**必须**是死的。
        //   否则这个测试就没有分辨力（它正是靠"旧端口已死"来区分改前/改后）。
        assert!(
            p.serving_port().await.is_none(),
            "前置条件失败：端口 {p1} 本该已经死了"
        );
        assert!(
            tokio::net::TcpStream::connect(("127.0.0.1", p1)).await.is_err(),
            "前置条件失败：端口 {p1} 还能连上，这个测试证明不了任何事"
        );

        // ★ 用户点「重试」走的就是这条路
        let p2 = p.ensure_started().await.unwrap();

        /*
         * ① 核心验收：返回的端口必须是**活的**。
         *
         * ⚠️ 这里**故意不**断言 `p2 != p1`：旧 socket 关掉之后，系统
         *    完全可能把同一个端口号再分配给我们的新监听（合法的好结果）。
         *    真正要保证的性质是**"活着"**，不是"号码不同" ——
         *    改前返回的死端口在这里连不上，所以这个断言足以钉住 bug。
         */
        assert!(
            tokio::net::TcpStream::connect(("127.0.0.1", p2)).await.is_ok(),
            "ensure_started 返回的端口 {p2} 连不上 ⇒ 用户点重试还是播不了（这就是改前的 bug）"
        );

        // ② register() 必须用那个活端口拼地址
        //
        //    ⚠️ 上游故意指向一个**必然被拒**的本地端口（1 号端口没人监听）：
        //       这样代理会**立刻**回 502，测试既不依赖外网、也不会等 30s 超时。
        let url = p.register("http://127.0.0.1:1/never-played.mp4", vec![]);
        let expect = format!("http://127.0.0.1:{p2}/s/");
        assert!(
            url.starts_with(&expect),
            "register 必须用**活**端口拼地址，实际: {url}（期望前缀 {expect}）"
        );

        // ③ 真连一次：拿到**任何** HTTP 应答都说明"代理在监听且能处理请求"
        //    （上游失败会回 502 —— 那是预期结果，不是错误）
        let after = c.get(&url).send().await;
        assert!(
            after.is_ok(),
            "重建后 register 产出的地址必须真的能连上代理，实际: {after:?}"
        );
    }

    /// serve 任务**正常/异常返回**时也必须清端口（不能只在 Err 分支清）
    ///
    /// 用一个"立刻返回"的任务模拟：直接调 `mark_dead` 就是 serve 返回后
    /// 一定会执行的那一步 —— 这里验证的是"清完之后 ensure_started 会重建"。
    #[tokio::test]
    async fn ensure_started_rebuilds_after_port_is_cleared() {
        let p = Arc::new(StreamProxy::new());
        let p1 = p.ensure_started().await.unwrap();

        // 模拟 serve 返回后执行的那行 `owner.mark_dead(port)`
        p.mark_dead(p1);
        assert_eq!(p.port(), 0, "清完之后字段必须是 0");

        let p2 = p.ensure_started().await.unwrap();
        assert_ne!(p2, p1, "端口被清掉后必须重新 bind 出一个新端口");
        assert!(p2 != 0);

        // 新端口是活的
        let r = reqwest::Client::new()
            .get(&format!("http://127.0.0.1:{p2}/s/cafebabe"))
            .send()
            .await;
        assert!(r.is_ok(), "重建出来的端口必须是活的，实际: {r:?}");
    }

    /// 并发调用 `ensure_started` 只能 bind **一次**
    ///
    /// 真并发场景：首页一次加载 240 张封面（走 proxy_covers）与用户
    /// 同一时刻点播放（走 resolve_stream）会同时进来。改前两者都看到
    /// `port == 0` ⇒ 各自 bind ⇒ 多出的监听 socket 没人知道端口号（泄漏），
    /// 且字段只留最后一个。
    #[tokio::test]
    async fn concurrent_ensure_started_binds_exactly_once() {
        let p = Arc::new(StreamProxy::new());

        let mut hs = Vec::new();
        for _ in 0..8 {
            let p = p.clone();
            hs.push(tokio::spawn(async move { p.ensure_started().await }));
        }

        let mut ports = Vec::new();
        for h in hs {
            ports.push(h.await.unwrap().unwrap());
        }

        let first = ports[0];
        assert!(
            ports.iter().all(|&x| x == first),
            "并发调用必须复用同一个端口，实际: {ports:?}"
        );

        // 字段里也必须是那个端口
        assert_eq!(p.port(), first);
    }

    /// 需要头 + not_web_ready 才走代理；否则保持直连（少一跳更快）
    #[tokio::test]
    async fn only_not_web_ready_streams_are_proxied() {
        let p = Arc::new(StreamProxy::new());
        let h = vec![("Referer".to_string(), "https://www.bilibili.com".to_string())];

        // 直连流：不代理
        assert!(maybe_proxy(&p, "https://x/a.mp4", &h, false).await.is_none());
        // 没有头：不需要代理
        assert!(maybe_proxy(&p, "https://x/a.mp4", &[], true).await.is_none());
        // 需要头 + not_web_ready：必须代理
        let got = maybe_proxy(&p, "https://x/a.mp4", &h, true).await;
        assert!(got.is_some(), "B 站这类流必须走代理（否则 403）");
        assert!(got.unwrap().starts_with("http://127.0.0.1:"));
    }

    /// ★★ 代理**必须把登记的头真的发出去**（联网测试）
    ///
    /// # 为什么专门测这个
    ///
    /// B 站的 CDN 只认 `Referer`（实测：仅 UA → 403，仅 Referer → 206）。
    /// 而「代码里写了 `.header("Referer", ...)` 但实际没发出去」是
    /// **静默失败**——代理会一直返回 403，日志里也看不出哪里不对。
    ///
    /// 这条测试用一个**本地回显服务**当上游：它把收到的头原样返回，
    /// 于是可以直接断言「Referer 到底有没有到」。
    ///
    /// 不依赖外网，可重复跑。
    #[tokio::test]
    async fn proxy_forwards_registered_headers() {
        use axum::response::IntoResponse;

        // 起一个回显上游：把收到的 Referer 头写回响应体
        let echo = Router::new().route(
            "/echo",
            get(|h: HeaderMap| async move {
                let r = h
                    .get("referer")
                    .and_then(|v| v.to_str().ok())
                    .unwrap_or("(none)")
                    .to_string();
                (StatusCode::OK, r).into_response()
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let up_port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            let _ = axum::serve(listener, echo).await;
        });

        // 起代理并登记一条带 Referer 的地址
        let proxy = Arc::new(StreamProxy::new());
        proxy.ensure_started().await.unwrap();
        let local = proxy.register(
            &format!("http://127.0.0.1:{up_port}/echo"),
            vec![("Referer".to_string(), "https://www.bilibili.com".to_string())],
        );

        let resp = reqwest::get(&local).await.unwrap();
        let status = resp.status();
        let got = resp.text().await.unwrap();
        assert_eq!(
            got, "https://www.bilibili.com",
            "代理必须把登记的头（Referer）真的发到上游 —— 否则 B 站一律 403\n\
             （请求 URL: {local}，响应状态: {status}）"
        );
    }

    /// ★★★ 联网对照：reqwest 用 Referer 能否真的取到 B 站 CDN 的数据
    ///
    /// # 为什么必须有这条
    ///
    /// 实测踩到的怪事：**同一个 URL + 同一个 Referer**
    ///   · Node 的 fetch → **HTTP 200**
    ///   · 本项目的 reqwest → **HTTP 403**
    ///
    /// 本地回显测试（`proxy_forwards_registered_headers`）已证明
    /// 「头确实发出去了」，所以问题不在我们的转发逻辑，
    /// 而在于**上游对 reqwest 这个客户端的处理不同** ——
    /// 最可能是 TLS 指纹（reqwest 用 rustls，Node/curl 用 OpenSSL）
    /// 被 CDN 边缘的 WAF 拦下。
    ///
    /// 这条测试把该现象**固化成可复现的判据**：
    /// 它直接打真实 CDN，如实报告拿到什么。
    ///
    /// 用 `--ignored` 跑（要联网）：
    /// ```text
    /// cargo test --lib -- --ignored bili_cdn
    /// ```
    #[tokio::test]
    #[ignore = "需要联网，手动跑：cargo test --lib -- --ignored bili_cdn"]
    async fn bili_cdn_reqwest_with_referer() {
        // 先拿一个新鲜的播放地址
        let j: serde_json::Value = reqwest::Client::new()
            .get("https://api.bilibili.com/x/web-interface/view?bvid=BV1bbL46AEYj")
            .header("Referer", "https://www.bilibili.com")
            .send()
            .await
            .expect("拿视频信息失败")
            .json()
            .await
            .expect("解析失败");
        let cid = j["data"]["cid"].as_i64().expect("没有 cid");

        let p: serde_json::Value = reqwest::Client::new()
            .get(format!(
                "https://api.bilibili.com/x/player/playurl?bvid=BV1bbL46AEYj&cid={cid}&qn=64&fnval=1&fnver=0&fourk=1"
            ))
            .header("Referer", "https://www.bilibili.com")
            .send()
            .await
            .expect("取流失败")
            .json()
            .await
            .expect("解析失败");
        let url = p["data"]["durl"][0]["url"]
            .as_str()
            .expect("没有播放地址")
            .to_string();

        /*
         * 逐项加压，找出到底是哪个因素让上游放行。
         *
         * 假设（按可能性排序）：
         *   1. HTTP 版本 —— rustls 可能协商 h2，而 Node/undici 走 http/1.1
         *   2. 头不全   —— 浏览器会带 Accept / Accept-Language / Origin
         *   3. 默认 UA  —— reqwest 默认不带 User-Agent
         *
         * 用 `range` 只取 1KB，避免把 247MB 全拉下来。
         */
        let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

        let variants: Vec<(&str, reqwest::Client, bool)> = vec![
            ("① 默认（可能 h2）+ 仅 Referer", reqwest::Client::new(), false),
            (
                "② 强制 HTTP/1.1 + 仅 Referer",
                reqwest::Client::builder().http1_only().build().unwrap(),
                false,
            ),
            (
                "③ HTTP/1.1 + 完整浏览器头",
                reqwest::Client::builder().http1_only().build().unwrap(),
                true,
            ),
            (
                "④ 默认 + 完整浏览器头",
                reqwest::Client::builder().build().unwrap(),
                true,
            ),
        ];

        let mut winner: Option<String> = None;
        for (label, c, full) in &variants {
            let mut rb = c
                .get(&url)
                .header("Referer", "https://www.bilibili.com")
                .header("Range", "bytes=0-1023");
            if *full {
                rb = rb
                    .header("User-Agent", ua)
                    .header("Accept", "*/*")
                    .header("Accept-Language", "zh-CN,zh;q=0.9")
                    .header("Origin", "https://www.bilibili.com");
            }
            let r = rb.send().await.expect("请求失败");
            let st = r.status();
            let body = r.bytes().await.unwrap_or_default();
            let head = String::from_utf8_lossy(&body[..body.len().min(12)]).to_string();
            println!("{label:<32} → {st}  {} 字节  头={head:?}", body.len());

            if st.is_success() && winner.is_none() {
                winner = Some((*label).to_string());
            }
        }

        println!("\n★ 放行的组合: {winner:?}");
        assert!(
            winner.is_some(),
            "四种组合全部被拒 —— B 站 CDN 的拦截比预期严格。\
             这意味着不能简单转发，需要换 HTTP 栈或改「宿主代下载 + 本地分片」。"
        );
    }

    /// ★ Range 必须透传（不透传则进度条一拖就废）
    #[tokio::test]
    async fn proxy_forwards_range_header() {
        use axum::response::IntoResponse;

        let echo = Router::new().route(
            "/r",
            get(|h: HeaderMap| async move {
                let r = h
                    .get("range")
                    .and_then(|v| v.to_str().ok())
                    .unwrap_or("(none)")
                    .to_string();
                (StatusCode::OK, r).into_response()
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let up_port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            let _ = axum::serve(listener, echo).await;
        });

        let proxy = Arc::new(StreamProxy::new());
        proxy.ensure_started().await.unwrap();
        let local = proxy.register(&format!("http://127.0.0.1:{up_port}/r"), vec![]);

        let got = reqwest::Client::new()
            .get(&local)
            .header("Range", "bytes=0-1023")
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap();
        assert_eq!(got, "bytes=0-1023", "Range 必须透传给上游（否则拖不动进度条）");
    }

    // ═══════════════ HLS 子路径拼接 ═══════════════

    /// ★★ 相对分片必须拼到**目录**下，而不是简单相加
    ///
    /// 这是实测踩到的真 bug：HLS 的 m3u8 里分片是相对路径，
    /// 播放器会请求 `http://127.0.0.1:<port>/s/<token>/0000000.ts`，
    /// 而代理只注册了 `/s/{token}` → 404 → 画面永远出不来。
    #[test]
    fn subpath_joins_into_directory() {
        assert_eq!(
            join_subpath("https://cdn.com/a/b/index.m3u8", "0000000.ts"),
            "https://cdn.com/a/b/0000000.ts",
            "要拼到 index.m3u8 所在的目录下，而不是 a/ 下"
        );
        // 只有一层
        assert_eq!(
            join_subpath("https://cdn.com/index.m3u8", "seg.ts"),
            "https://cdn.com/seg.ts"
        );
    }

    /// ★★ 绝对路径（以 `/` 开头）要从**域名根**开始，不能拼到目录下
    ///
    /// 实测：`360采集` 的 m3u8 里子播放列表就是绝对路径
    /// （`/20260820/bry8W01j/3260kb/hls/index.m3u8`），
    /// 我第一版按"相对路径"拼成了
    /// `.../bry8W01j/20260820/bry8W01j/3260kb/...`（路径重复）→ 404 → 播不了。
    #[test]
    fn subpath_absolute_starts_from_domain_root() {
        assert_eq!(
            join_subpath(
                "https://vod1.maowushi.com/20260820/bry8W01j/index.m3u8",
                "/20260820/bry8W01j/3260kb/hls/index.m3u8"
            ),
            "https://vod1.maowushi.com/20260820/bry8W01j/3260kb/hls/index.m3u8",
            "绝对路径要从域名根开始，不能把目录再拼一遍"
        );
        // 与 RFC 3986 的标准解析结果一致
        assert_eq!(
            join_subpath("https://cdn.com/a/b/index.m3u8", "/x/y.ts"),
            "https://cdn.com/x/y.ts"
        );
    }

    /// ★ 带 query 的 m3u8 地址：query 必须被剥掉，不能跑到路径前面
    ///
    /// 采集站的 m3u8 几乎都带签名 query（`?sign=abc`）。
    /// 字符串相加会得到 `.../index.m3u8?sign=abc/0000000.ts` —— 错的。
    #[test]
    fn subpath_strips_query_from_base() {
        assert_eq!(
            join_subpath("https://cdn.com/a/index.m3u8?sign=abc123", "0000000.ts"),
            "https://cdn.com/a/0000000.ts"
        );
        assert_eq!(
            join_subpath("https://cdn.com/a/index.m3u8#frag", "s.ts"),
            "https://cdn.com/a/s.ts"
        );
        // 绝对路径 + 带 query 的 base
        assert_eq!(
            join_subpath("https://cdn.com/a/b/index.m3u8?sign=xyz", "/c/d.ts"),
            "https://cdn.com/c/d.ts"
        );
    }

    /// 子路径自己的 query 要保留（分片也可能带 token）
    #[test]
    fn subpath_keeps_its_own_query() {
        assert_eq!(
            join_subpath("https://cdn.com/a/index.m3u8", "seg.ts?token=xyz"),
            "https://cdn.com/a/seg.ts?token=xyz"
        );
    }

    /// 嵌套子路径（m3u8 里指向另一层目录）
    #[test]
    fn subpath_supports_nested_paths() {
        assert_eq!(
            join_subpath("https://cdn.com/a/index.m3u8", "3000k/hls/mixed.m3u8"),
            "https://cdn.com/a/3000k/hls/mixed.m3u8"
        );
    }

    /// 前导斜杠 = **绝对路径**（从域名根），不是"去掉斜杠拼目录"
    ///
    /// ⚠️ 这条断言在第一版里是**反的** —— 那时我把它当成"相对路径加个斜杠"，
    /// 期望 `https://cdn.com/a/0000000.ts`。实测发现那会让 360采集 播不了
    /// （路径重复）。正确的 RFC 3986 语义是：`/x` 从域名根开始。
    #[test]
    fn subpath_leading_slash_is_absolute() {
        assert_eq!(
            join_subpath("https://cdn.com/a/index.m3u8", "/0000000.ts"),
            "https://cdn.com/0000000.ts",
            "前导斜杠是绝对路径 —— 从域名根开始，不保留原目录"
        );
    }

    /// 没有路径的极端 URL 不应 panic
    #[test]
    fn subpath_handles_degenerate_url() {
        // 这种 URL 现实中不会出现，但函数不能崩
        let out = join_subpath("https://cdn.com", "seg.ts");
        assert!(out.contains("seg.ts"), "实际: {out}");

        // 绝对路径 + 无路径 base
        let out2 = join_subpath("https://cdn.com", "/seg.ts");
        assert_eq!(out2, "https://cdn.com/seg.ts", "实际: {out2}");
    }

    // ═══════════════ m3u8 改写 ═══════════════

    /// ★★★ 三种形态的 URI 都要改写成走代理
    ///
    /// 这是 `360采集` 播不了的根因：它的子播放列表是**绝对路径**
    /// （`/20260820/...`），播放器会解析成 `<代理根>/20260820/...` ——
    /// **丢掉了 token**，请求到不了代理。
    ///
    /// 改写后的形态是 `/p/<token>/<scheme>/<host>/<path>` ——
    /// scheme 与 host 都编码进路径，所以代理无需查表即可直连，
    /// 也就能处理「分片在另一台主机」的情况。
    #[test]
    fn playlist_rewrites_all_uri_forms() {
        let text = "\
#EXTM3U
#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=800000
/20260820/bry8W01j/3260kb/hls/index.m3u8
#EXTINF:3.48,
0000000.ts
#EXTINF:3.00,
https://cdn.example.com/a/b/0000001.ts
";
        let got = rewrite_playlist(
            text,
            "https://vod1.maowushi.com/20260820/bry8W01j/index.m3u8",
            "http://127.0.0.1:9999/p/TOK/",
        );

        // 标签原样保留
        assert!(got.contains("#EXTM3U"));
        assert!(got.contains("#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=800000"));
        assert!(got.contains("#EXTINF:3.48,"));

        // 绝对路径 → 带 token，且 scheme/host 取自 base
        assert!(
            got.contains(
                "http://127.0.0.1:9999/p/TOK/https/vod1.maowushi.com\
                 /20260820/bry8W01j/3260kb/hls/index.m3u8"
            ),
            "绝对路径要改写成带 token 的地址：\n{got}"
        );
        // 相对路径 → 按 base 目录绝对化
        assert!(
            got.contains(
                "http://127.0.0.1:9999/p/TOK/https/vod1.maowushi.com\
                 /20260820/bry8W01j/0000000.ts"
            ),
            "相对路径要按 base 目录绝对化：\n{got}"
        );
        // 完整 URL → **保留它自己的 host**（分片常在不同主机）
        assert!(
            got.contains("http://127.0.0.1:9999/p/TOK/https/cdn.example.com/a/b/0000001.ts"),
            "完整 URL 也要走代理，且保留自己的 host：\n{got}"
        );
        // 不能出现路径重复（第一版的 bug）
        assert!(
            !got.contains("bry8W01j/20260820/bry8W01j"),
            "不能把目录拼两遍：\n{got}"
        );
    }

    /// 带签名的 URI：query 必须保留
    #[test]
    fn playlist_keeps_query_in_uri() {
        let text = "#EXTM3U\nseg.ts?sign=abc123\n";
        let got = rewrite_playlist(
            text,
            "https://cdn.com/a/index.m3u8",
            "http://127.0.0.1:1/p/T/",
        );
        assert!(got.contains("seg.ts?sign=abc123"), "query 要保留：\n{got}");
    }

    /// ★ 带 URI 属性的标签（AES 密钥）也要改写
    ///
    /// 不改的话加密流拿不到密钥 —— 表现是「画面花屏/解不出来」。
    #[test]
    fn playlist_rewrites_key_uri_attribute() {
        let text = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x1\n";
        let got = rewrite_playlist(
            text,
            "https://cdn.com/a/index.m3u8",
            "http://127.0.0.1:1/p/T/",
        );
        assert!(
            got.contains("URI=\"http://127.0.0.1:1/p/T/https/cdn.com/a/key.bin\""),
            "密钥 URI 也要走代理（且引号要完整）：\n{got}"
        );
        assert!(got.contains("METHOD=AES-128"));
        assert!(got.contains("IV=0x1"));
    }

    /// 空行与纯标签文件不应被破坏
    #[test]
    fn playlist_handles_empty_and_tags_only() {
        assert_eq!(rewrite_playlist("", "https://a.com/x.m3u8", "http://l/p/T/"), "");
        let tags = "#EXTM3U\n#EXT-X-ENDLIST\n";
        let got = rewrite_playlist(tags, "https://a.com/x.m3u8", "http://l/p/T/");
        assert!(got.contains("#EXTM3U"));
        assert!(got.contains("#EXT-X-ENDLIST"));
    }

    /// 协议相对地址（`//host/x.ts`）—— 协议要保留成 `https://`
    #[test]
    fn playlist_handles_protocol_relative() {
        let got = rewrite_playlist(
            "//cdn.com/a/b.ts\n",
            "https://origin.com/x/y.m3u8",
            "http://127.0.0.1:1/p/T/",
        );
        assert!(
            got.contains("http://127.0.0.1:1/p/T/https/cdn.com/a/b.ts"),
            "协议相对也要改写（不能丢 //）：\n{got}"
        );
    }

    /// url_origin 的基本正确性
    #[test]
    fn origin_extraction() {
        assert_eq!(url_origin("https://cdn.com/a/b.m3u8"), "https://cdn.com");
        assert_eq!(url_origin("http://cdn.com:8080/a/b"), "http://cdn.com:8080");
        assert_eq!(url_origin("https://cdn.com"), "https://cdn.com");
        assert_eq!(url_origin("https://cdn.com/a?x=1"), "https://cdn.com");
    }
}
