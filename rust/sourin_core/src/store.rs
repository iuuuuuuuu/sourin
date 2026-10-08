//! 本地数据层 —— 收藏 / 追更 / 观看进度 / 观看历史
//!
//! # 数据平面（Owner 确认的边界）
//!
//! | 平面 | 数据 | 方向 | 冲突策略 |
//! |---|---|---|---|
//! | **独立平面** | 我们的**收藏 + 追更 + 进度** | 多设备**双向同步** | LWW + 墓碑 |
//! | **备份平面** | 第三方站点**自带**的历史 | 平台 → 云盘**单向镜像** | 按平台时间戳覆盖 |
//!
//! 两者混在一起会互相打架；分开后互不干扰，模型反而更简单。
//!
//! # 为什么本地 SQLite 是真相源
//!
//! 离线优先：断网不影响使用；云盘（WebDAV/OneDrive/GDrive）只是同步通道。

use crate::provider::UserRecord;
use rusqlite::{params, Connection, OptionalExtension};
use std::path::Path;
use std::sync::{Arc, Mutex};

/// `favorites` 的列清单 —— **唯一来源**，避免多处 SELECT 漂移
///
/// ★ 加字段时只改这里（配合 `row_to_favorite`），
///   不要在每个 SELECT 里手抄一遍。
///
/// ⚠️ 这个教训是踩出来的：`favorites` 的列清单原先在**四个** SELECT 里
///    各抄了一份（list_favorites 两个分支 + list_following + get_favorite），
///    加列时漏一个就会出现「某个入口读出来是新字段、另一个是默认值」——
///    这次加 `last_update_at` 时若手抄，就会有 1/4 的概率漏。
///
/// ⚠️ 顺序必须与 [`row_to_favorite`] 的 `r.get(N)` 下标**逐一对齐**。
const FAV_COLS: &str = "key,provider,native_id,title,cover,group_name,kind,favorited,following,\
     last_episode_count,last_episode_title,unread_count,last_checked_at,last_update_at,\
     note,created_at,updated_at,deleted";

/// `progress` 的列清单 —— **唯一来源**（理由同 [`FAV_COLS`]）
///
/// ⚠️ 顺序必须与 [`row_to_progress`] 的 `r.get(N)` 下标**逐一对齐**。
const PROG_COLS: &str = "key,provider,native_id,title,cover,episode_id,episode_title,\
     position,duration,finished,updated_at";

/// `history` 的列清单 —— **唯一来源**（理由同 [`FAV_COLS`]）
///
/// ⚠️ 顺序必须与 [`row_to_history`] 的 `r.get(N)` 下标**逐一对齐**。
const HIST_COLS: &str = "key,provider,native_id,title,cover,episode_title,\
     position,duration,watched_at";

/// 追更列表的排序（**给界面看的**）
///
/// # Owner 的要求
///
/// > 而且按照最近有更新的进行一个排序才对
///
/// # 规则
///
/// ```text
/// ① 有未读的排最前（unread_count > 0）
///     —— 用户打开追更页最想看的就是"哪些更新了"
/// ② 都无未读时，按**最近检测到更新**的时间降序（last_update_at DESC）
/// ③ 再按开启追更的时间（updated_at DESC）兜底
/// ```
///
/// ⚠️ **绝不能**用 `last_checked_at` 排 —— 它每轮巡检都变，
///    顺序会自己乱跳（详见 `Favorite::last_update_at` 的说明）。
const FOLLOW_ORDER: &str = "ORDER BY (unread_count > 0) DESC, last_update_at DESC, updated_at DESC";

/// 巡检队列的排序（**给轮询用的**，与界面排序不同）
///
/// 语义：**最久没检查的排最前** —— 保证每个条目都有机会被检查到，
/// 而不是总检查最近更新的那几个（那样冷门条目永远不更新）。
const FOLLOW_CHECK_ORDER: &str = "ORDER BY last_checked_at ASC";

/// `#[serde(default = "...")]` 用的常量 true
///
/// 单独抽出来是因为 serde 的 `default = "路径"` 只接受**函数路径**，
/// 不能直接写 `true` 字面量。
///
/// ⚠️ 它只是缺省值，**不保证不变量** —— 旧格式的墓碑行会因此拿到
/// `favorited=true`，必须由 [`Normalize::normalize`] 再清成 false。
/// 详见 [`Favorite::favorited`]。
fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Favorite {
    /// `"{provider}:{native_id}"`
    pub key: String,
    pub provider: String,
    pub native_id: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover: Option<String>,
    /// 用户自己的分组（与平台的 want/watching 无关）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub group_name: Option<String>,
    /// 内容类型：movie | series | variety
    pub kind: String,
    // ── 两种**互相独立**的状态 ──
    //
    // ★★★ 2026-09-20：收藏与追更彻底拆开（Owner 两次纠正）
    //
    // Owner 的原话：
    // > 收藏和追更是两个语义，我发现我现在点击收藏就会触发追更
    // > 这是两个完全不同的功能啊
    // > 收藏是仅仅收藏
    // > 而追更，是 收藏的时候是多少集，当更新的时候，
    // > 要在追更那个页面，显示出来这个更新了，
    // > 而且按照最近有更新的进行一个排序才对
    //
    // 紧接着纠正（我当时理解成"追更 ⊆ 收藏"，错了）：
    // > **追更并不代表就要收藏，这是独立的状态**
    //
    // # 正确的模型（四个组合都合法）
    //
    // ```text
    // favorited  following   含义
    //    ✅         ❌       只是收藏了，不关心更新
    //    ❌         ✅       ★ 只追更，不收藏（"我在等它更新"）
    //    ✅         ✅       既收藏又追更
    //    ❌         ❌       行已无用 → deleted=1（墓碑）
    // ```
    //
    // # 为什么必须新增 `favorited` 字段
    //
    // 原先用 `deleted` **同时**表达"取消收藏"与"行已删除"两件事 ——
    // 于是取消收藏必然把追更一起杀掉（`list_following` 要过滤 deleted=0）。
    // 拆开后：
    // ```text
    // favorited  是否在收藏列表里
    // following  是否在追更列表里
    // deleted    ★ 只表示"这一行两个状态都没了，可以当墓碑"
    // ```
    /// 是否在**收藏列表**里（与追更独立）
    ///
    /// ★ `#[serde(default)]` 是**必须的**（2026-09-21 实测补上）：
    ///   这个字段是后加的，而它要反序列化的对象**不只是本地库**，
    ///   还有云盘上 `data/favorites.jsonl` 与备份 zip 里**升级前写下的旧行**。
    ///   没有 default 时旧行会直接解析失败 —— 实测
    ///   `jsonl_ignores_blank_lines` 报
    ///   `JSONL 全部 1 行都无法解析，可能不是本应用的备份`，
    ///   而该报错会让**整份远端同步中断**（`parse_jsonl` 的错误向上传播，
    ///   见 `sync_favorites` 与 `put_with_remerge`）。
    ///
    /// ⚠️ 缺省值取 `true`，但**光靠它不够** —— 必须配合 [`Normalize`]：
    /// ```text
    /// 旧行两类          缺省成     normalize 后
    /// deleted=0         true      true    ← 可见收藏，保留
    /// deleted=1         true  ✗   false   ← 墓碑，必须清掉
    /// ```
    /// 若缺省成 `false`，可见收藏会变成「行还活着但不在收藏列表里」，
    /// 用户的收藏会**在界面上凭空消失**；
    /// 若只有 `true` 而没有 normalize，墓碑会变成
    /// `favorited=1, deleted=1`，而 [`Self::list_favorites`] 只按
    /// `favorited=1` 过滤（**不带 deleted 条件**）——
    /// 于是**用户删掉的收藏会重新出现**（同时违反本文件反复声明的不变量
    /// `deleted=1 ⇔ !favorited && !following`）。
    #[serde(default = "default_true")]
    pub favorited: bool,
    /// 是否在**追更列表**里（与收藏独立）
    pub following: bool,
    /// 最近一次已知的集数 —— **开启追更时记下基准**，之后由检查更新
    ///
    /// ⚠️ 语义是"用户上次看到的集数"（基准），不是"最新的集数"。
    ///    新增集数 = 平台当前集数 − 这个值。
    pub last_episode_count: u32,
    /// 上次见到的最新集标题
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_episode_title: Option<String>,
    /// ★ 未读更新数（新集数 - 上次已读）
    pub unread_count: u32,
    /*
     * ★★ 两个时间字段，**用途不同，不能混用**（2026-09-20 新增后者）
     *
     * ```text
     * last_checked_at  最近一次"检查"的时间 —— 轮询队列用（最久没查的优先）
     * last_update_at   ★ 最近一次"检测到更新"的时间 —— 界面排序用
     * ```
     *
     * ⚠️ 为什么排序不能用 `last_checked_at`：
     *    它**每轮巡检都会变**，于是追更列表的顺序会自己乱跳 ——
     *    用户刚看到的"《X》更新了"下次刷新就跑到别处去了。
     *
     *    而 `last_update_at` 只在**真有新集**时才变，
     *    所以"最近有更新的排最前"是稳定且符合直觉的。
     */
    pub last_checked_at: i64,
    /// ★ 最近一次**检测到更新**的时间（毫秒）—— 追更页排序依据
    ///
    /// 0 表示"从未检测到更新"（刚开启追更、或一直没更新）。
    /// 排序时这些排在**有更新的之后**，再按开启时间兜底。
    ///
    /// ★ `#[serde(default)]` 同样是必须的 —— 理由同 [`Self::favorited`]：
    ///   旧 JSONL / 旧备份里没有这个字段。缺省 0 正好是
    ///   "从未检测到更新"的既有语义，排序时会自然沉到后面。
    #[serde(default)]
    pub last_update_at: i64,
    /// 备注
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    /// 创建时间（毫秒）
    pub created_at: i64,
    /// 更新时间（毫秒）—— LWW 依据
    pub updated_at: i64,
    /// ★ 墓碑：删除不真删，否则会被其他设备的旧数据复活
    pub deleted: bool,
}

/**
 * 反序列化后强制恢复 `Favorite` 的不变量
 *
 * # 为什么需要（2026-09-21 实测发现的真 bug）
 *
 * `favorited` / `last_update_at` 是**后加**的字段，而 `Favorite` 要反序列化的
 * 不只是本地库，还有**升级前**写到云盘 `data/favorites.jsonl` 与备份 zip 里的旧行。
 * 给它们加 `#[serde(default)]` 能让旧行解析成功（否则整份同步中断），
 * 但**缺省值对墓碑是错的**：
 *
 * ```text
 * 旧行              serde 缺省     本函数修正后
 * deleted=0        favorited=true   favorited=true    ← 正确
 * deleted=1        favorited=true   favorited=false   ★ 必须清掉
 * ```
 *
 * 若不清掉，墓碑会落成 `favorited=1, deleted=1`，而
 * [`Db::list_favorites`] **只按 `favorited=1` 过滤**（不带 `deleted` 条件），
 * 于是**用户删掉的收藏会重新出现在列表里** —— 正是墓碑机制要防的事。
 *
 * # 为什么放在反序列化而不是各个写入点
 *
 * 写入点有 4 处（`sync_favorites` 的两条分支、`put_with_remerge` 的回调、
 * `follow.rs` 的巡检），**漏一个就复现**。放在这里一次兜住所有入口，
 * 与 `MediaId` 手写 `Serialize` 锁定契约是同一个思路：
 * **把不变量钉在类型边界上，而不是指望每个调用方记得**。
 */
pub trait Normalize {
    /// 修正反序列化后可能违反的不变量（就地修改）
    fn normalize(&mut self);
}

impl Normalize for Favorite {
    fn normalize(&mut self) {
        if self.deleted {
            /*
             * 墓碑：两个"在列表里"的状态都必须为假。
             *
             * `unread_count` 一并清零 —— 墓碑不该带着未读角标，
             * 这与数据库迁移里的回填口径一致（见 `Db::migrate`）。
             */
            self.favorited = false;
            self.following = false;
            self.unread_count = 0;
        } else if !self.favorited && !self.following {
            /*
             * 两个状态都为假、又不是墓碑 → 这一行没有任何意义。
             *
             * ⚠️ 这里**不能**自作主张翻成 favorited=true：
             *    那会把"只追更不收藏"以外的未知状态猜成收藏。
             *    只把 deleted 补上，语义与 `tombstone_favorite` 一致。
             */
            self.deleted = true;
        }
    }
}

/// `Progress` 没有后加的字段，无需修正 —— 但要让 `parse_jsonl` 的泛型约束成立
impl Normalize for Progress {
    fn normalize(&mut self) {}
}

/// 观看进度
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Progress {
    pub key: String,
    pub provider: String,
    pub native_id: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover: Option<String>,
    /// 剧集 id（点播单集时为 None）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub episode_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub episode_title: Option<String>,
    /// 播放位置（秒）
    pub position: u64,
    /// 总时长（秒）
    pub duration: u64,
    /// 是否已看完
    pub finished: bool,
    pub updated_at: i64,
}

/// 观看历史（我们自己的，独立平面）
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct HistoryEntry {
    pub key: String,
    pub provider: String,
    pub native_id: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub episode_title: Option<String>,
    pub position: u64,
    pub duration: u64,
    pub watched_at: i64,
}

/// ★★ 片头/片尾跳过点（按**作品**存）
///
/// # 为什么按作品而不是按集
///
/// 同一部剧每集的片头位置基本一致 —— 按集存会让用户每集都设一次。
/// 实测夸克视频也是按作品记的。
///
/// # 为什么进数据库
///
/// 这是「用户数据」，应该参与云盘同步（换设备不用重设）。
/// 原先只在 localStorage，换设备就丢。
///
/// ══════════════════════════════════════════════════════════════════════
/// ★★★ 2026-09-19 改成**区间**语义（Owner 给了参照图）
/// ══════════════════════════════════════════════════════════════════════
///
/// Owner 原话：
/// > 设置片头片尾应该是独立的…点击后如图，
/// > 是可以配置**开始是从 xx 秒开始 xx 秒跳转**的，结尾也是一样，
/// > 不是简单粗暴设置个片头的时间、片尾的时间就结束了。
///
/// 参照图（某播放器的「设置片头片尾」弹窗）：
/// ```text
/// 片头时长37秒，片尾时长35秒
/// [============|———————————————|=============]
/// 片头 00:00:12 - 00:00:49          01:44:12 - 01:44:47 片尾
/// 仅针对同一文件夹选集生效
///                            [重置]  [确认设置]
/// ```
///
/// ## 我上一版错在哪
///
/// 只存了 `intro_end` / `outro_start` 两个**单点** ——
/// 那只能表达"从这里开始跳"，表达不了"**哪一段**是片头"。
/// 用户看不到"片头从 12 秒到 49 秒"这个区间，
/// 也就无法判断设得对不对（参照图里那个蓝色区间块就是给人看的）。
///
/// ## 现在的语义
///
/// | 字段 | 含义 | 播放时的行为 |
/// |---|---|---|
/// | `intro_start` / `intro_end` | 片头**区间** | 播到 `intro_start` → 跳到 `intro_end` |
/// | `outro_start` / `outro_end` | 片尾**区间** | 播到 `outro_start` → 跳到 `outro_end` |
///
/// ⚠️ 兼容旧数据：上一版只写了 `intro_end`（单点）。
///    读出来时若 `intro_start` 为空，视为 `0`（从开头就是片头）——
///    那正是旧版本的隐含语义。
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SkipMarker {
    /// `provider:native_id`
    pub key: String,
    pub provider: String,
    pub native_id: String,
    pub title: String,
    /// 片头**开始**位置（秒）。`None` = 未设置
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub intro_start: Option<u64>,
    /// 片头**结束**位置（秒）—— 播到这里就跳过去
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub intro_end: Option<u64>,
    /// 片尾**开始**位置（秒）—— 播到这里就跳
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outro_start: Option<u64>,
    /// 片尾**结束**位置（秒）。`None` = 跳到视频结尾
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outro_end: Option<u64>,
    /// 本作品是否启用自动跳过。`None` = 跟随全局开关
    #[serde(skip_serializing_if = "Option::is_none")]
    pub auto_skip: Option<bool>,
    pub updated_at: i64,
}

/// 追更检查结果
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct UpdateInfo {
    pub key: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover: Option<String>,
    pub provider: String,
    /// 之前记录的集数
    pub old_count: u32,
    /// 现在检测到的集数
    pub new_count: u32,
    /// 新增集数
    pub added: u32,
    /// 最新一集标题
    #[serde(skip_serializing_if = "Option::is_none")]
    pub latest_title: Option<String>,
}

/// 本地数据库
pub struct Db {
    conn: Arc<Mutex<Connection>>,
}

impl Db {
    /// 打开（或创建）数据库
    pub fn open(path: impl AsRef<Path>) -> Result<Self, String> {
        let conn = Connection::open(path).map_err(|e| format!("打开数据库失败: {e}"))?;
        let db = Self {
            conn: Arc::new(Mutex::new(conn)),
        };
        db.migrate()?;
        Ok(db)
    }

    /// 内存库（测试用）
    pub fn in_memory() -> Result<Self, String> {
        let conn = Connection::open_in_memory().map_err(|e| format!("建库失败: {e}"))?;
        let db = Self {
            conn: Arc::new(Mutex::new(conn)),
        };
        db.migrate()?;
        Ok(db)
    }

    fn migrate(&self) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute_batch(
            r#"
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;

            -- 收藏 + 追更（独立平面）
            CREATE TABLE IF NOT EXISTS favorites (
                key                 TEXT PRIMARY KEY,
                provider            TEXT NOT NULL,
                native_id           TEXT NOT NULL,
                title               TEXT NOT NULL,
                cover               TEXT,
                group_name          TEXT,
                kind                TEXT NOT NULL DEFAULT 'series',
                -- ★ 两个独立状态（2026-09-20 拆开，原先只有 following）
                favorited           INTEGER NOT NULL DEFAULT 1,
                following           INTEGER NOT NULL DEFAULT 0,
                last_episode_count  INTEGER NOT NULL DEFAULT 0,
                last_episode_title  TEXT,
                unread_count        INTEGER NOT NULL DEFAULT 0,
                last_checked_at     INTEGER NOT NULL DEFAULT 0,
                -- ★ 最近一次"检测到更新"的时间（界面排序用，与 last_checked_at 不同）
                last_update_at      INTEGER NOT NULL DEFAULT 0,
                note                TEXT,
                created_at          INTEGER NOT NULL,
                updated_at          INTEGER NOT NULL,
                deleted             INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_fav_updated ON favorites(updated_at);
            CREATE INDEX IF NOT EXISTS idx_fav_following ON favorites(following, deleted);

            -- 观看进度（独立平面）
            CREATE TABLE IF NOT EXISTS progress (
                key             TEXT PRIMARY KEY,
                provider        TEXT NOT NULL,
                native_id       TEXT NOT NULL,
                title           TEXT NOT NULL,
                cover           TEXT,
                episode_id      TEXT,
                episode_title   TEXT,
                position        INTEGER NOT NULL DEFAULT 0,
                duration        INTEGER NOT NULL DEFAULT 0,
                finished        INTEGER NOT NULL DEFAULT 0,
                updated_at      INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_prog_updated ON progress(updated_at DESC);

            -- 观看历史（独立平面，我们自己的）
            CREATE TABLE IF NOT EXISTS history (
                key             TEXT PRIMARY KEY,
                provider        TEXT NOT NULL,
                native_id       TEXT NOT NULL,
                title           TEXT NOT NULL,
                cover           TEXT,
                episode_title   TEXT,
                position        INTEGER NOT NULL DEFAULT 0,
                duration        INTEGER NOT NULL DEFAULT 0,
                watched_at      INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_hist_time ON history(watched_at DESC);

            -- 平台自带历史的备份镜像（备份平面，只读）
            CREATE TABLE IF NOT EXISTS platform_history (
                key             TEXT PRIMARY KEY,
                provider        TEXT NOT NULL,
                native_id       TEXT NOT NULL,
                title           TEXT NOT NULL,
                cover           TEXT,
                episode_title   TEXT,
                position        INTEGER NOT NULL DEFAULT 0,
                duration        INTEGER NOT NULL DEFAULT 0,
                platform_time   INTEGER NOT NULL,
                captured_at     INTEGER NOT NULL,
                device_id       TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS idx_phist_provider ON platform_history(provider, platform_time DESC);

            -- 同步元数据（LWW 水位）
            CREATE TABLE IF NOT EXISTS sync_meta (
                k TEXT PRIMARY KEY,
                v TEXT NOT NULL
            );

            -- ★★ 片头/片尾跳过点（按**作品**存，不是按集）
            --
            -- 为什么按作品：同一部剧每集的片头位置基本一致，
            -- 按集存会让用户每集都要设一次（实测夸克也是按作品）。
            --
            -- 为什么进数据库而不是 localStorage：
            -- 这两个值属于「用户数据」，应该参与云盘同步 ——
            -- 换设备后不该重新设一遍。见 sync/mod.rs 的独立平面说明。
            --
            -- ★★★ 2026-09-19：改成**区间**语义（Owner 给了参照图）
            --
            -- 参照图里是 `片头 00:00:12 - 00:00:49` —— **两个端点**。
            -- 我上一版只存了"片头结束位置"一个点，表达不了那个区间，
            -- 用户也就看不到"片头到底是从哪到哪"。
            CREATE TABLE IF NOT EXISTS skip_markers (
                key         TEXT PRIMARY KEY,   -- provider:native_id
                provider    TEXT NOT NULL,
                native_id   TEXT NOT NULL,
                title       TEXT NOT NULL DEFAULT '',
                -- 片头**区间**：播到 intro_start → 跳到 intro_end
                intro_start INTEGER,
                intro_end   INTEGER,
                -- 片尾**区间**：播到 outro_start → 跳到 outro_end
                outro_start INTEGER,
                outro_end   INTEGER,
                -- 本作品是否启用自动跳过（NULL = 跟随全局开关）
                auto_skip   INTEGER,
                updated_at  INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_skip_updated ON skip_markers(updated_at DESC);
            "#,
        )
        .map_err(|e| format!("建表失败: {e}"))?;

        /*
         * ★ 老库补列（`CREATE TABLE IF NOT EXISTS` 不会给已存在的表加列）
         *
         * ⚠️ SQLite 没有 `ADD COLUMN IF NOT EXISTS`，重复执行会报
         *    "duplicate column name" —— 所以**必须先查 PRAGMA 再决定加不加**，
         *    不能无脑 execute 然后忽略错误（那会掩盖真正的错误）。
         */
        let columns_of = |table: &str| -> Result<Vec<String>, String> {
            let mut stmt = conn
                .prepare(&format!("PRAGMA table_info({table})"))
                .map_err(|e| format!("读取 {table} 表结构失败: {e}"))?;
            let rows = stmt
                .query_map([], |r| r.get::<_, String>(1))
                .map_err(|e| e.to_string())?;
            Ok(rows.filter_map(|r| r.ok()).collect())
        };

        let existing = columns_of("skip_markers")?;
        for col in ["intro_start", "outro_end"] {
            if !existing.iter().any(|c| c == col) {
                conn.execute(
                    &format!("ALTER TABLE skip_markers ADD COLUMN {col} INTEGER"),
                    [],
                )
                .map_err(|e| format!("补列 {col} 失败: {e}"))?;
                log::info!("skip_markers 已补列 {col}");
            }
        }

        /*
         * ★★ favorites 补 `last_update_at`（2026-09-20）
         *
         * 为「追更页按最近有更新排序」而加。老库里的值默认 0
         * （表示"从未检测到更新"）—— 排序时会排在**有更新的之后**，
         * 这是合理的老数据语义：既然没记过，就当没更新过。
         */
        let fav_cols = columns_of("favorites")?;
        if !fav_cols.iter().any(|c| c == "last_update_at") {
            conn.execute(
                "ALTER TABLE favorites ADD COLUMN last_update_at INTEGER NOT NULL DEFAULT 0",
                [],
            )
            .map_err(|e| format!("favorites 补列 last_update_at 失败: {e}"))?;
            log::info!("favorites 已补列 last_update_at");
        }

        /*
         * ★★ favorites 补 `favorited`（2026-09-20）
         *
         * # 为什么需要（Owner 的第二次纠正）
         *
         * > 追更并不代表就要收藏，这是独立的状态
         *
         * 原先 `deleted` 一个字段同时表达"取消收藏"与"行已删除"，
         * 导致「取消收藏」必然杀掉追更。拆出 `favorited` 后两者独立。
         *
         * # 回填规则（老数据的语义翻译）
         *
         * ```text
         * deleted=0  → favorited=1   可见的收藏，当然在收藏列表里
         * deleted=1  → favorited=0   墓碑，当作已取消收藏
         * ```
         *
         * ⚠️ 默认值给 1 是有意的：`ALTER TABLE ADD COLUMN ... DEFAULT 1`
         *    会把**已有行**也填成 1，正好符合 `deleted=0` 那批的语义；
         *    然后立刻用一条 UPDATE 把墓碑修正成 0。
         *    这样两步后老库的 (favorited, following) 组合与原来一致。
         */
        if !fav_cols.iter().any(|c| c == "favorited") {
            conn.execute(
                "ALTER TABLE favorites ADD COLUMN favorited INTEGER NOT NULL DEFAULT 1",
                [],
            )
            .map_err(|e| format!("favorites 补列 favorited 失败: {e}"))?;

            /*
             * ── 回填（把老数据翻译成新模型）──
             *
             * # 老数据的实际形态（迁移前实测）
             *
             * ```text
             * deleted=0                    → 可见的收藏
             * deleted=1, following=0       → 干净的墓碑
             * deleted=1, following=1       ★ 不一致：墓碑但 following 还留着
             * ```
             *
             * 第三种是**老代码留下的脏数据**：老版 `tombstone` 只写
             * `deleted=1`，**没有清 following**；而 `list_following`
             * 过滤 `deleted=0`，所以那个 following 永远看不到 ——
             * 它一直是"隐形"的。
             *
             * # 翻译规则：以**老模型下可观测的行为**为准
             *
             * ```text
             * 老：favorited 看 deleted        新：favorited = (deleted=0)
             * 老：追更列表 = deleted=0 AND following=1
             * 新：追更列表 = deleted=0 AND following=1   ← 保持同一个 WHERE
             * ```
             *
             * 所以对 `deleted=1` 的行**把 following 也清成 0**：
             * ```text
             * ① 保证新不变量成立：deleted=1 ⇔ !favorited && !following
             * ② 避免一个隐患：那些行若被"重新收藏"复活，
             *    favorited 变 1、following 仍是 1 →
             *    ★ 会**突然出现在追更列表**里，而用户从没做过这个操作
             * ```
             */
            conn.execute(
                "UPDATE favorites SET favorited = 0, following = 0, unread_count = 0 \
                 WHERE deleted = 1",
                [],
            )
            .map_err(|e| format!("回填 favorited 失败: {e}"))?;
            log::info!("favorites 已补列 favorited，并按 deleted 回填（含清理脏 following）");
        }

        /*
         * ★ 不变量修复（每次启动都跑，幂等）
         *
         * 新模型的硬性不变量：
         * ```text
         * deleted=1  ⇔  !favorited && !following
         * ```
         *
         * 为什么要单独跑一次（而不是只在补列时做）：
         * 补列只发生**一次**，但老库里的脏数据（`deleted=1, following=1`）
         * 在那之前就存在了；而且万一将来某个分支又写出不一致的行，
         * 这里能兜住。
         *
         * ⚠️ 只修**违反不变量**的行，不碰任何合法行 —— 所以幂等且无害。
         */
        let fixed = conn
            .execute(
                "UPDATE favorites SET following=0, unread_count=0 \
                 WHERE deleted=1 AND following=1",
                [],
            )
            .map_err(|e| format!("修复 favorites 不变量失败: {e}"))?;
        if fixed > 0 {
            log::info!("favorites 修复了 {fixed} 行不一致（墓碑却还开着追更）");
        }

        Ok(())
    }

    // ─────────────────── 收藏 + 追更 ───────────────────

    pub fn upsert_favorite(&self, f: &Favorite) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            r#"INSERT INTO favorites
                (key,provider,native_id,title,cover,group_name,kind,favorited,following,
                 last_episode_count,last_episode_title,unread_count,last_checked_at,
                 last_update_at,
                 note,created_at,updated_at,deleted)
               VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18)
               ON CONFLICT(key) DO UPDATE SET
                 title=excluded.title, cover=excluded.cover, group_name=excluded.group_name,
                 kind=excluded.kind, favorited=excluded.favorited,
                 following=excluded.following,
                 last_episode_count=excluded.last_episode_count,
                 last_episode_title=excluded.last_episode_title,
                 unread_count=excluded.unread_count,
                 last_checked_at=excluded.last_checked_at,
                 last_update_at=excluded.last_update_at,
                 note=excluded.note, updated_at=excluded.updated_at, deleted=excluded.deleted"#,
            params![
                f.key, f.provider, f.native_id, f.title, f.cover, f.group_name, f.kind,
                f.favorited as i32, f.following as i32,
                f.last_episode_count, f.last_episode_title,
                f.unread_count, f.last_checked_at, f.last_update_at,
                f.note, f.created_at, f.updated_at,
                f.deleted as i32
            ],
        )
        .map_err(|e| format!("写入收藏失败: {e}"))?;
        Ok(())
    }

    /// 收藏列表（**只看 favorited**，与追更无关）
    pub fn list_favorites(&self, include_deleted: bool) -> Result<Vec<Favorite>, String> {
        let conn = self.conn.lock().unwrap();
        /*
         * ★ 用 `favorited=1` 而不是 `deleted=0`
         *
         * 语义差别（Owner 的第二次纠正）：
         * ```text
         * deleted=0             "行还活着"（可能只是追更、没收藏）
         * favorited=1           ★ "在收藏列表里"
         * ```
         * 只追更不收藏的条目 deleted=0 但 favorited=0，
         * 用 deleted=0 过滤会把它错误地显示在收藏列表里。
         */
        let sql = if include_deleted {
            format!("SELECT {FAV_COLS} FROM favorites ORDER BY updated_at DESC")
        } else {
            format!("SELECT {FAV_COLS} FROM favorites WHERE favorited=1 ORDER BY updated_at DESC")
        };
        let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], row_to_favorite)
            .map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
    }

    /// 仅追更中的（用于巡检）
    ///
    /// ⚠️ 排序是 [`FOLLOW_CHECK_ORDER`]（最久没查的优先），
    ///    **不是**界面要的顺序 —— 界面用 [`Self::list_following_for_ui`]。
    ///
    /// ★ 2026-09-20 拆分：原先界面与巡检**共用**这一个查询，
    ///   于是想给界面改排序就会把巡检的公平性搞坏（冷门条目永远轮不到）。
    ///
    /// ★ 过滤条件用 `following=1`（不看 `favorited`）——
    ///    **只追更不收藏**的条目也要被巡检。
    pub fn list_following(&self) -> Result<Vec<Favorite>, String> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {FAV_COLS} FROM favorites \
                 WHERE deleted=0 AND following=1 {FOLLOW_CHECK_ORDER}"
            ))
            .map_err(|e| e.to_string())?;
        let rows = stmt.query_map([], row_to_favorite).map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
    }

    /// 追更列表（**给界面看的排序**）
    ///
    /// 排序规则见 [`FOLLOW_ORDER`] —— Owner 要求「按最近有更新的排前面」。
    pub fn list_following_for_ui(&self) -> Result<Vec<Favorite>, String> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {FAV_COLS} FROM favorites \
                 WHERE deleted=0 AND following=1 {FOLLOW_ORDER}"
            ))
            .map_err(|e| e.to_string())?;
        let rows = stmt.query_map([], row_to_favorite).map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
    }

    pub fn get_favorite(&self, key: &str) -> Result<Option<Favorite>, String> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            &format!("SELECT {FAV_COLS} FROM favorites WHERE key=?1"),
            params![key],
            row_to_favorite,
        )
        .optional()
        .map_err(|e| e.to_string())
    }

    /// 标记已读（清空未读计数）
    pub fn mark_favorite_read(&self, key: &str, now: i64) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE favorites SET unread_count=0, updated_at=?1 WHERE key=?2",
            params![now, key],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    /// 取消收藏（**不影响追更**）—— Owner 的第二次纠正
    ///
    /// # 语义（两个状态独立）
    ///
    /// ```text
    /// 取消收藏 → favorited=0，following **原样保留**
    ///            「我不收藏了，但还想盯着看它更新」
    /// ```
    ///
    /// ★ 只有当**两个状态都为 0** 时，这一行才没有意义 → 写墓碑。
    ///   这样墓碑的语义就干净了：`deleted=1 ⇔ !favorited && !following`。
    ///
    /// ⚠️ 不能再无条件 `deleted=1` —— 那会把追更一起杀掉，
    ///    正是 Owner 说的"追更不代表就要收藏，这是独立的状态"。
    pub fn unfavorite(&self, key: &str, now: i64) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE favorites \
             SET favorited=0, \
                 deleted = CASE WHEN following=0 THEN 1 ELSE 0 END, \
                 updated_at=?1 \
             WHERE key=?2",
            params![now, key],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    /// 关闭追更（**不影响收藏**）
    ///
    /// 同理：两个都为 0 才写墓碑。
    pub fn unfollow(&self, key: &str, now: i64) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE favorites \
             SET following=0, unread_count=0, \
                 deleted = CASE WHEN favorited=0 THEN 1 ELSE 0 END, \
                 updated_at=?1 \
             WHERE key=?2",
            params![now, key],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    /// 彻底删除（**两个状态一起清**）—— 用于"从追更页彻底移除"这类明确意图
    pub fn tombstone_favorite(&self, key: &str, now: i64) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE favorites \
             SET favorited=0, following=0, unread_count=0, deleted=1, updated_at=?1 \
             WHERE key=?2",
            params![now, key],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    /// 清理过期墓碑（默认 90 天）
    pub fn purge_tombstones(&self, before_ms: i64) -> Result<usize, String> {
        let conn = self.conn.lock().unwrap();
        let n = conn
            .execute(
                "DELETE FROM favorites WHERE deleted=1 AND updated_at < ?1",
                params![before_ms],
            )
            .map_err(|e| e.to_string())?;
        Ok(n)
    }

    /// 全部收藏的总未读数（Tab 角标用）
    pub fn total_unread(&self) -> Result<u32, String> {
        let conn = self.conn.lock().unwrap();
        let n: i64 = conn
            .query_row(
                "SELECT COALESCE(SUM(unread_count),0) FROM favorites WHERE deleted=0",
                [],
                |r| r.get(0),
            )
            .map_err(|e| e.to_string())?;
        Ok(n as u32)
    }

    // ─────────────────── 进度 ───────────────────

    pub fn upsert_progress(&self, p: &Progress) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        /*
         * ════════════════════════════════════════════════════════════════
         * ★★★ 2026-09-26：`title` / `cover` **不得**被空值覆盖
         * ════════════════════════════════════════════════════════════════
         *
         * # 为什么（Owner 报的「播放记录显示 ？，没有封面没有名字」）
         *
         * 原语句是 `title=excluded.title, cover=excluded.cover` —— **无条件覆盖**。
         * 而写库的调用方可能**还不知道**标题/封面：
         * ```text
         * 合并页一进页就起播（要立刻记进度），但标题要等详情 IPC 回来才知道
         * ⇒ 那几秒内 `title` 是空串、`cover` 是 None
         * ⇒ 每次这样的写入都把一个**本来正确的**标题/封面**清成空**
         * ```
         * ★ 实测用户真实库：3 条记录 `title=''` + `cover=NULL`
         *   （`.probe/ROOTCAUSE-panel-and-history.md`）
         *
         * # 修法：`CASE WHEN` 守卫 —— **新值为空时保留旧值**
         *
         * ```sql
         * title = CASE WHEN excluded.title <> '' THEN excluded.title ELSE title END
         * cover = COALESCE(excluded.cover, cover)
         * ```
         * ★ 放在**存储层**而不是调用方，理由：
         * ```text
         * ① 这是**数据完整性**约束，不是某个调用方的业务逻辑
         * ② 调用方有多个（播放器定时/退出、遥控、同步）—— 逐个改必然漏
         * ③ 空标题**永远**不是有效更新 ⇒ 该约束对任何调用方都成立
         * ```
         * ⚠️ 反向影响：**无法用空值清空标题**（那本来也不是有效操作）。
         *    真要清空得走别的路径（删除记录），语义上更正确。
         *
         * ⚠️ `position`/`duration`/`episode_id` **不加**守卫 ——
         *    它们是"当前播放状态"，本来就该被最新值覆盖（position=0 是合法的）。
         */
        conn.execute(
            r#"INSERT INTO progress
                 (key,provider,native_id,title,cover,episode_id,episode_title,position,duration,finished,updated_at)
               VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
               ON CONFLICT(key) DO UPDATE SET
                 title=CASE WHEN excluded.title <> '' THEN excluded.title ELSE title END,
                 cover=COALESCE(excluded.cover, cover),
                 episode_id=excluded.episode_id, episode_title=excluded.episode_title,
                 position=excluded.position, duration=excluded.duration,
                 finished=excluded.finished, updated_at=excluded.updated_at"#,
            params![
                p.key, p.provider, p.native_id, p.title, p.cover, p.episode_id,
                p.episode_title, p.position, p.duration, p.finished as i32, p.updated_at
            ],
        )
        .map_err(|e| format!("写入进度失败: {e}"))?;
        Ok(())
    }

    /// 续播入口：最近在看的
    pub fn continue_watching(&self, limit: u32) -> Result<Vec<Progress>, String> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT key,provider,native_id,title,cover,episode_id,episode_title,position,duration,finished,updated_at
                 FROM progress WHERE finished=0 AND position > 5
                 ORDER BY updated_at DESC LIMIT ?1",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map(params![limit], row_to_progress)
            .map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
    }

    /// 全部进度记录（**同步用**：需要全量，不能只看「最近在看的」）
    ///
    /// 与 `continue_watching` 的区别：那个带 `finished=0 AND position>5` 的业务过滤，
    /// 只适合首页展示；同步必须拿到全量，否则已看完的记录永远推不到其他设备。
    pub fn list_all_progress(&self) -> Result<Vec<Progress>, String> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT key,provider,native_id,title,cover,episode_id,episode_title,position,duration,finished,updated_at
                 FROM progress ORDER BY updated_at DESC",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], row_to_progress)
            .map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
    }

    pub fn get_progress(&self, key: &str) -> Result<Option<Progress>, String> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT key,provider,native_id,title,cover,episode_id,episode_title,position,duration,finished,updated_at FROM progress WHERE key=?1",
            params![key],
            row_to_progress,
        )
        .optional()
        .map_err(|e| e.to_string())
    }

    // ─────────────────── 历史（我们自己的） ───────────────────

    pub fn add_history(&self, h: &HistoryEntry) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            r#"INSERT INTO history
                 (key,provider,native_id,title,cover,episode_title,position,duration,watched_at)
               VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)
               ON CONFLICT(key) DO UPDATE SET
                 episode_title=excluded.episode_title, position=excluded.position,
                 duration=excluded.duration, watched_at=excluded.watched_at"#,
            params![
                h.key, h.provider, h.native_id, h.title, h.cover, h.episode_title,
                h.position, h.duration, h.watched_at
            ],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn list_history(&self, limit: u32) -> Result<Vec<HistoryEntry>, String> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {HIST_COLS} FROM history ORDER BY watched_at DESC LIMIT ?1"
            ))
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map(params![limit], row_to_history)
            .map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
    }

    /**
     * 清空播放历史
     *
     * ★★★ **必须同时清两张表**（真 bug，2026-09-19 实测发现）
     *
     * # 数据模型：两张表分工不同
     *
     * ```text
     * history   历史流水   每次播放追加一条，用于「播放历史」列表
     *                       （list_history）
     * progress  进度记录   每个内容一行（key 唯一），存"看到第几秒"
     *                       用于「继续观看」与续播（continue_watching）
     * ```
     *
     * `continue_watching` 读的是 **progress**，
     * 而原先这里只 `DELETE FROM history` —— **两张表互不影响**。
     *
     * # 实测到的现象
     *
     * 界面里「我的」的「播放历史」tab 用的是 `continue_watching`，
     * 于是点了「清空历史」之后：
     *
     * ```text
     * apiListHistory:       0    ← 清掉了
     * apiContinueWatching: 12    ← ★ 一条没动
     * 标签显示「播放历史 12」，但下面的卡片是空的
     * ```
     *
     * 用户看到的是「清空成功了」+「还剩 12 条」两个矛盾的信号。
     *
     * # 为什么两张都要清
     *
     * 用户的意图是"别再显示我看过什么了" ——
     * 只清一张等于**只做了一半**：
     * · 只清 history → 列表还留着（本 bug）
     * · 只清 progress → "继续观看"还留着，首页还在推荐
     *
     * 而且历史条目本身是隐私敏感的（反映看过什么），
     * 清不干净等于这个功能没有意义。
     *
     * ⚠️ 用事务包起来：两张表要么都清、要么都不清。
     *    否则中途失败会留下"一半清了一半没有"的诡异状态。
     */
    pub fn clear_history(&self) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute("BEGIN", []).map_err(|e| e.to_string())?;
        let r = (|| -> Result<(), String> {
            conn.execute("DELETE FROM history", [])
                .map_err(|e| e.to_string())?;
            /*
             * progress 表同时承担"续播位置"这个职责 ——
             * 清空历史时一并清掉才符合用户预期
             * （否则点开一个看过的片子还会从上次的位置续播）。
             */
            conn.execute("DELETE FROM progress", [])
                .map_err(|e| e.to_string())?;
            Ok(())
        })();
        match r {
            Ok(()) => {
                conn.execute("COMMIT", []).map_err(|e| e.to_string())?;
                Ok(())
            }
            Err(e) => {
                // 失败要回滚，不能留一半
                let _ = conn.execute("ROLLBACK", []);
                Err(e)
            }
        }
    }

    // ─────────────────── 片头/片尾跳过点 ───────────────────

    /// 把一行 `skip_markers` 转成 `SkipMarker`
    ///
    /// ⚠️ 抽出来是因为有**三处**（get / list / 将来的导出）要按同样的
    ///    列顺序解析 —— 列顺序一变就要改三处，很容易漏。
    ///    这里集中一处，SQL 里的 SELECT 也用同一个常量。
    const SKIP_COLS: &'static str =
        "key,provider,native_id,title,intro_start,intro_end,outro_start,outro_end,auto_skip,updated_at";

    fn row_to_skip(r: &rusqlite::Row<'_>) -> rusqlite::Result<SkipMarker> {
        Ok(SkipMarker {
            key: r.get(0)?,
            provider: r.get(1)?,
            native_id: r.get(2)?,
            title: r.get(3)?,
            intro_start: r.get::<_, Option<i64>>(4)?.map(|v| v as u64),
            intro_end: r.get::<_, Option<i64>>(5)?.map(|v| v as u64),
            outro_start: r.get::<_, Option<i64>>(6)?.map(|v| v as u64),
            outro_end: r.get::<_, Option<i64>>(7)?.map(|v| v as u64),
            auto_skip: r.get::<_, Option<i64>>(8)?.map(|v| v != 0),
            updated_at: r.get(9)?,
        })
    }

    /// 读某作品的跳过点（不存在返回 `None`）
    pub fn get_skip_marker(&self, key: &str) -> Result<Option<SkipMarker>, String> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {} FROM skip_markers WHERE key=?1",
                Self::SKIP_COLS
            ))
            .map_err(|e| e.to_string())?;
        let mut rows = stmt.query_map(params![key], Self::row_to_skip).map_err(|e| e.to_string())?;
        match rows.next() {
            Some(Ok(m)) => Ok(Some(m)),
            Some(Err(e)) => Err(e.to_string()),
            None => Ok(None),
        }
    }

    /// 列出全部跳过点（同步用：需要全量）
    pub fn list_skip_markers(&self) -> Result<Vec<SkipMarker>, String> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {} FROM skip_markers ORDER BY updated_at DESC",
                Self::SKIP_COLS
            ))
            .map_err(|e| e.to_string())?;
        let rows = stmt.query_map([], Self::row_to_skip).map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
    }

    /// 写入/更新跳过点
    ///
    /// ⚠️ 用**部分更新**语义：`None` 表示"这次不动这一项"，
    ///    而不是"把它清空"。清空要用 `clear_skip_marker`。
    ///
    /// 为什么：用户可能只重设片头，那时不该把片尾也抹掉。
    pub fn upsert_skip_marker(&self, m: &SkipMarker) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            r#"INSERT INTO skip_markers
                (key,provider,native_id,title,intro_start,intro_end,outro_start,outro_end,auto_skip,updated_at)
               VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)
               ON CONFLICT(key) DO UPDATE SET
                 title       = excluded.title,
                 -- ★ COALESCE：新值为 NULL 时保留旧值（部分更新语义）
                 intro_start = COALESCE(excluded.intro_start, skip_markers.intro_start),
                 intro_end   = COALESCE(excluded.intro_end,   skip_markers.intro_end),
                 outro_start = COALESCE(excluded.outro_start, skip_markers.outro_start),
                 outro_end   = COALESCE(excluded.outro_end,   skip_markers.outro_end),
                 auto_skip   = COALESCE(excluded.auto_skip,   skip_markers.auto_skip),
                 updated_at  = excluded.updated_at"#,
            params![
                m.key,
                m.provider,
                m.native_id,
                m.title,
                m.intro_start.map(|v| v as i64),
                m.intro_end.map(|v| v as i64),
                m.outro_start.map(|v| v as i64),
                m.outro_end.map(|v| v as i64),
                m.auto_skip.map(|b| if b { 1i64 } else { 0i64 }),
                m.updated_at,
            ],
        )
        .map_err(|e| format!("写入跳过点失败: {e}"))?;
        Ok(())
    }

    /// 清除某作品的跳过设置（「取消跳过」用）
    pub fn clear_skip_marker(&self, key: &str) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM skip_markers WHERE key=?1", params![key])
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    // ═══════════════════════════════════════════════════════════════════
    //  ★★★ 换源：把记录从旧 key 搬到新 key（task-67 需求⑤）
    // ═══════════════════════════════════════════════════════════════════

    /**
     * 把 `from_key` 的四张表记录**搬到** `to_key`，并删掉旧行
     *
     * # 为什么需要它（Owner 原话）
     *
     * > 追更收藏历史，当我换源之后，这三个记录却没有更新，
     * > 返回再进去却还是老的源，这也是错误的
     *
     * # 根因（实测确认）
     *
     * 四张表的 key 全是 `<provider>:<native_id>`（见 `commands_write::item_key`）：
     * ```text
     * 换源 ⇒ provider 变 ⇒ ★ key 变 ⇒ 写入是【新行】，旧行原样留着
     * 全项目没有任何 repoint / alias 路径
     * ```
     * 实测用户库：`progress` 16 行但只有 15 个不同标题 ——
     * 《老舅》同时有 `360:86969`（pos=4）与 `caiji:74774`（pos=1）。
     *
     * # ★ 为什么是**一个原子操作**（而不是 Dart 侧"删+写"两步）
     *
     * ```text
     * 两步之间崩溃/断电 ⇒ 记录**直接丢失**（删了但没写成功）
     * ⇒ 必须在一个事务里做完四张表
     * ```
     *
     * # ★★ 合并策略（Lead 已逐条裁决，不是我的自由发挥）
     *
     * ## 前提：progress / history 走**三态**，不是一刀切
     *
     * ```text
     * ① TO 无行                 ⇒ FROM 行【整行】搬到 TO 的 key（原值照搬）
     * ② TO 有行 + 集号【匹配】   ⇒ 保留 TO 那一行，只把 position 覆盖为 max
     * ③ TO 有行 + 集号【不匹配】 ⇒ TO 行**完全不动**，FROM 行删掉
     *                              （= "只保留新源自己的记录"）
     * ```
     *
     * ★ m00753 ④：为什么 TO 无行时**不**重置为 0
     * ```text
     * ① 裁决里那句"集号不同 ⇒ 只保留新源自己的记录"是【冲突消解】规则；
     *    TO 无行时**不存在**"新源自己的记录" ⇒ 前提不成立 ⇒ 不触发
     * ② ★★ TO 无行是**最常见**的触发场景（用户因为当前源卡/坏而换源，
     *    新源从没看过）。在那里重置为 0 ⇒ 每次换源都丢进度 ⇒ 功能变成有害的
     * ③ "宁可从头，不要错位"约束的是"我们**知道**会错位"的情形
     *    （两边都有行且集号不同），不是"我们不知道"的情形
     * ```
     *
     * ★ m00753 ⑤：集号匹配的三态判定
     * ```text
     * 两边都解析不出集号（都 null） ⇒ **视为匹配**（单片：position 是同一段
     *                                视频的时间偏移，携带有意义）
     * 只有一侧 null               ⇒ **不匹配**（取保守侧）
     * 两边都有且相等              ⇒ 匹配
     * 两边都有且不等              ⇒ 不匹配
     * ```
     * ⇒ 实现上就是 `ep_f == ep_t` 的 `Option` 比较：`None == None` 为真，
     *   `None == Some(_)` 为假 —— **恰好**就是上面四条。
     *
     * ## 字段级规则
     *
     * | 字段 | 取值 | 理由 |
     * |---|---|---|
     * | `position` | **max(FROM, TO)** | ★ m00753 ③：单调不减 —— 换源不该让进度**倒退**（与 Legado 在 (chapterIndex, chapterPos) 上取单调 max 一致）。m00370 的"取 FROM"是**没有集号概念时**定的，已被取代 |
     * | `following` / `favorited` | **OR** | 两者是**独立位**（`store.rs` 与 `detail_page.dart` 的长注释） |
     * | `title` / `cover` / `episode_id` / `episode_title` / `duration` | **TO 的** | 行现在属于新源，内容元数据应反映新源（m00753 ⑦） |
     * | `unread_count` | **max** | 别把"有新集"这个信息丢了 |
     * | `created_at` | **min** | 保留最早那次 |
     * | `updated_at` | **max** | LWW 依据（m00753 ⑦：用户正在看时周期性保存会自然刷新它） |
     * | `last_episode_count` / `last_episode_title` | **TO 的** | 巡检会刷新它 |
     * | `finished` | **FROM 的** | ✅ **已裁决**（m01279 第四节，见下）—— 取 TO 的会让"继续观看"立刻消失 |
     * | `history.watched_at` | **max** | 最近一次观看（m00589 裁决，m00753 ⑦ 未涉及） |
     * | `skip_markers` 四个端点 | **FROM 的非 null 优先，缺的用 TO 补** | "我看到的设置不该变"比"新源上可能有的旧设置"更可预测 |
     *
     * ## ✅ `finished` 取 **FROM 的** —— 已裁决（m01279 第四节）
     *
     * ```text
     * m00753 ⑦ 说"保留 TO 那一行，只把 position 覆盖为 max"——
     *   字面读 ⇒ finished 取 TO 的；
     *   但它的括注只列了 duration / episode_title / updated_at（**内容**列），
     *   理由是"行现在属于新源" ⇒ 那是**内容身份**论证，对**用户状态**列不成立。
     *
     * ★ Lead 已就此补一条裁决（m01279 第四节）：
     *   「`finished` **保持取 FROM 的**，与 ⑦『只覆盖 position』的字面不同，
     *     理由是**行为**：TO.finished=true + FROM=false 时若取 TO，
     *     `continue_watching` 的 `finished=0` 过滤会把这一行**立刻从
     *     「继续观看」里抹掉** —— 用户刚换源就看到记录"消失"，
     *     正是 task-67 要消灭的那类症状。」
     * ```
     *
     * ⇒ **已裁决：取 FROM 的**（`finished: f.finished`）。这不是待复核项，
     *   而是最终规格 —— 谁要改成 TO 的，必须先推翻上面那条**行为**论证。
     *
     * # ★ 旧行 **DELETE**，不是 tombstone
     *
     * ```text
     * ① progress / history **根本没有 deleted 列** ⇒ 墓碑那套在它们身上不适用；
     *    若 favorites 单独留墓碑，三个表口径就不一致
     * ② 留墓碑会让 list_favorites(include_deleted:true)（**备份导出**在用）
     *    把同一部作品数成两条 ⇒ 备份里出现重复 ⇒ 与"合并"目标自相矛盾
     * ```
     *
     * # 幂等 / 边界
     *
     * ```text
     * · from_key == to_key        ⇒ 直接返回（什么都不做）
     * · from 四张表都没有记录      ⇒ 什么都不做（**不报错**）
     * · to 已有行（如《老舅》）    ⇒ 按上表合并，★ 不丢字段、不产生重复
     * ```
     */
    pub fn repoint_item(&self, from_key: &str, to_key: &str) -> Result<(), String> {
        if from_key == to_key {
            return Ok(());
        }
        /*
         * ★ provider / native_id 从 **to_key 解析**，而不是让调用方传 ——
         *   理由是"新行的 provider 必须与新 key 一致"是**不变量**，
         *   让调用方传就多了一个能传错的自由度（且传错不报错，只会静默不一致）。
         */
        let (to_provider, to_native_id) = split_item_key(to_key)?;
        /*
         * ★ `from_key` 也要**校验**（不只是 to_key）
         *
         * 若只校验 to_key：一个拼错的 from_key（如漏了冒号）会**静默地**
         * 什么都不做 —— 用户以为记录搬过去了，实际没有。
         * 本项目反复强调"失败要响亮，不许静默吞掉" ⇒ 两个都校验。
         */
        let _ = split_item_key(from_key)?;

        let conn = self.conn.lock().unwrap();

        /*
         * ⚠️ `unchecked_transaction` 而不是 `transaction`：
         *    `transaction()` 要 `&mut Connection`，而这里只借到 `MutexGuard`。
         *    与 `save_platform_history` 用的是同一个手法（本文件已有先例）。
         */
        let tx = conn
            .unchecked_transaction()
            .map_err(|e| format!("换源迁移开启事务失败: {e}"))?;

        // ── ① favorites（收藏 + 追更，两个独立位取 OR）──
        {
            let from: Option<Favorite> = tx
                .query_row(
                    &format!("SELECT {FAV_COLS} FROM favorites WHERE key=?1"),
                    params![from_key],
                    row_to_favorite,
                )
                .optional()
                .map_err(|e| format!("换源迁移：读 favorites 失败: {e}"))?;

            if let Some(f) = from {
                let to: Option<Favorite> = tx
                    .query_row(
                        &format!("SELECT {FAV_COLS} FROM favorites WHERE key=?1"),
                        params![to_key],
                        row_to_favorite,
                    )
                    .optional()
                    .map_err(|e| format!("换源迁移：读 favorites(目标) 失败: {e}"))?;

                let merged = match to {
                    None => Favorite {
                        key: to_key.to_string(),
                        provider: to_provider.clone(),
                        native_id: to_native_id.clone(),
                        ..f
                    },
                    Some(t) => Favorite {
                        key: to_key.to_string(),
                        provider: to_provider.clone(),
                        native_id: to_native_id.clone(),
                        // ★ 标题/封面取 TO 的（用户正在看新源）
                        title: t.title,
                        cover: t.cover,
                        group_name: t.group_name,
                        kind: t.kind,
                        // ★ 两个独立位取 OR
                        favorited: f.favorited || t.favorited,
                        following: f.following || t.following,
                        // ★ 巡检基准取 TO 的
                        last_episode_count: t.last_episode_count,
                        last_episode_title: t.last_episode_title,
                        // ★ 未读取 max
                        unread_count: f.unread_count.max(t.unread_count),
                        last_checked_at: f.last_checked_at.max(t.last_checked_at),
                        last_update_at: f.last_update_at.max(t.last_update_at),
                        note: t.note.or(f.note),
                        // ★ created 取 min，updated 取 max
                        created_at: f.created_at.min(t.created_at),
                        updated_at: f.updated_at.max(t.updated_at),
                        // ★ 合并后这行必须"活着"（否则用户会看到收藏凭空消失）
                        deleted: f.deleted && t.deleted,
                    },
                };
                tx.execute(
                    &format!(
                        "INSERT INTO favorites ({FAV_COLS}) \
                         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18) \
                         ON CONFLICT(key) DO UPDATE SET \
                           provider=excluded.provider, native_id=excluded.native_id, \
                           title=excluded.title, cover=excluded.cover, \
                           group_name=excluded.group_name, kind=excluded.kind, \
                           favorited=excluded.favorited, following=excluded.following, \
                           last_episode_count=excluded.last_episode_count, \
                           last_episode_title=excluded.last_episode_title, \
                           unread_count=excluded.unread_count, \
                           last_checked_at=excluded.last_checked_at, \
                           last_update_at=excluded.last_update_at, \
                           note=excluded.note, created_at=excluded.created_at, \
                           updated_at=excluded.updated_at, deleted=excluded.deleted"
                    ),
                    params![
                        merged.key,
                        merged.provider,
                        merged.native_id,
                        merged.title,
                        merged.cover,
                        merged.group_name,
                        merged.kind,
                        merged.favorited as i32,
                        merged.following as i32,
                        merged.last_episode_count as i64,
                        merged.last_episode_title,
                        merged.unread_count as i64,
                        merged.last_checked_at,
                        merged.last_update_at,
                        merged.note,
                        merged.created_at,
                        merged.updated_at,
                        merged.deleted as i32,
                    ],
                )
                .map_err(|e| format!("换源迁移：写 favorites 失败: {e}"))?;

                tx.execute("DELETE FROM favorites WHERE key=?1", params![from_key])
                    .map_err(|e| format!("换源迁移：删旧 favorites 失败: {e}"))?;
            }
        }

        // ── ② progress（★ 三态：TO 无行照搬 / 匹配取 max / 不匹配不携带）──
        {
            let from: Option<Progress> = tx
                .query_row(
                    &format!("SELECT {PROG_COLS} FROM progress WHERE key=?1"),
                    params![from_key],
                    row_to_progress,
                )
                .optional()
                .map_err(|e| format!("换源迁移：读 progress 失败: {e}"))?;

            if let Some(f) = from {
                let to: Option<Progress> = tx
                    .query_row(
                        &format!("SELECT {PROG_COLS} FROM progress WHERE key=?1"),
                        params![to_key],
                        row_to_progress,
                    )
                    .optional()
                    .map_err(|e| format!("换源迁移：读 progress(目标) 失败: {e}"))?;

                /*
                 * ══════════════════════════════════════════════════════════
                 * ★★★ 三态（m00753 ④⑤⑦）—— 不是一刀切
                 * ══════════════════════════════════════════════════════════
                 *
                 * ```text
                 * TO 无行                 ⇒ 整行搬到 TO 的 key（原值照搬，不重置）
                 * TO 有行 + 集号【匹配】   ⇒ 保留 TO 行，只把 position 覆盖为 max
                 * TO 有行 + 集号【不匹配】 ⇒ TO 行完全不动，FROM 行删掉
                 * ```
                 *
                 * ★ 集号匹配的判定就是 `ep_f == ep_t`（`Option` 比较）：
                 * ```text
                 * 两边都解析不出 ⇒ None == None      ⇒ 匹配（单片：position 是
                 *                                    同一段视频的时间偏移，有意义）
                 * 只有一侧 null ⇒ None != Some(_)   ⇒ 不匹配（保守侧，m00753 ⑤）
                 * ```
                 */
                let merged = match to {
                    None => Progress {
                        key: to_key.to_string(),
                        provider: to_provider.clone(),
                        native_id: to_native_id.clone(),
                        ..f
                    },
                    Some(t) => {
                        let ep_f = episode_number_from_title(f.episode_title.as_deref());
                        let ep_t = episode_number_from_title(t.episode_title.as_deref());
                        if ep_f == ep_t {
                            Progress {
                                key: to_key.to_string(),
                                provider: to_provider.clone(),
                                native_id: to_native_id.clone(),
                                /*
                                 * ★★★ position 取 **max**（m00753 ③）
                                 *
                                 * 单调不减 —— 换源不该让进度**倒退**。
                                 * 与 Legado 在 (chapterIndex, chapterPos) 上取
                                 * 单调 max 一致，不是 LWW。
                                 *
                                 * ⚠️ 这条**取代**了 m00370 的"取 FROM 的"：
                                 *    那条是**没有集号概念时**定的。
                                 *    无职转生那组（FROM=91 / max=766）就是本规则
                                 *    的**唯一可区分锚点** —— 其余样本两条规则同值。
                                 */
                                position: f.position.max(t.position),
                                /*
                                 * ✅ `finished` 取 **FROM** 的 —— **已裁决**
                                 *    （m01279 第四节）。完整论证见 `repoint_item`
                                 *    文档的「`finished` 取 FROM 的」一节。
                                 *    一句话：若 TO.finished=true 而 FROM=false，
                                 *    取 TO 会让 `continue_watching` 的 `finished=0`
                                 *    把这条**刚恢复的进度**直接滤掉 ——
                                 *    用户刚换源就看到记录"消失"。
                                 */
                                finished: f.finished,
                                // ★ 其余列（title/cover/episode_id/episode_title/
                                //   duration/updated_at）保持 **TO** 的（m00753 ⑦）
                                ..t
                            }
                        } else {
                            /*
                             * ★ 集号不匹配 ⇒ TO 行**完全不动**（`t` 原样返回），
                             *   FROM 行在下面照常 DELETE
                             *   ⇒ 就是裁决要的"只保留**新源自己的**记录"。
                             *
                             * ⚠️ 这里仍然走下面的 INSERT：对同一行是一次
                             *    **幂等 upsert**（写回刚读出来的值）。
                             *    代价可忽略，换来"四条分支共用一条写路径"
                             *    —— 少一条分支就少一处能写错的地方。
                             */
                            t
                        }
                    }
                };
                /*
                 * ⚠️ 这里**不能**复用 `upsert_progress` —— 它带
                 *    `title = CASE WHEN excluded.title <> '' ...` 的空值守卫，
                 *    而本操作要的是**精确写入合并结果**（守卫会让"TO 的标题"
                 *    在为空时保留 FROM 的，与裁决的"取 TO 的"不一致）。
                 */
                tx.execute(
                    &format!(
                        "INSERT INTO progress ({PROG_COLS}) \
                         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11) \
                         ON CONFLICT(key) DO UPDATE SET \
                           provider=excluded.provider, native_id=excluded.native_id, \
                           title=excluded.title, cover=excluded.cover, \
                           episode_id=excluded.episode_id, \
                           episode_title=excluded.episode_title, \
                           position=excluded.position, duration=excluded.duration, \
                           finished=excluded.finished, updated_at=excluded.updated_at"
                    ),
                    params![
                        merged.key,
                        merged.provider,
                        merged.native_id,
                        merged.title,
                        merged.cover,
                        merged.episode_id,
                        merged.episode_title,
                        merged.position as i64,
                        merged.duration as i64,
                        merged.finished as i32,
                        merged.updated_at,
                    ],
                )
                .map_err(|e| format!("换源迁移：写 progress 失败: {e}"))?;

                tx.execute("DELETE FROM progress WHERE key=?1", params![from_key])
                    .map_err(|e| format!("换源迁移：删旧 progress 失败: {e}"))?;
            }
        }

        // ── ③ history（与 progress 同一套三态；watched_at 取 max）──
        {
            let from: Option<HistoryEntry> = tx
                .query_row(
                    &format!("SELECT {HIST_COLS} FROM history WHERE key=?1"),
                    params![from_key],
                    row_to_history,
                )
                .optional()
                .map_err(|e| format!("换源迁移：读 history 失败: {e}"))?;

            if let Some(f) = from {
                let to: Option<HistoryEntry> = tx
                    .query_row(
                        &format!("SELECT {HIST_COLS} FROM history WHERE key=?1"),
                        params![to_key],
                        row_to_history,
                    )
                    .optional()
                    .map_err(|e| format!("换源迁移：读 history(目标) 失败: {e}"))?;

                /*
                 * ★ history 走**与 progress 完全相同**的三态 —— 理由：
                 *   两张表的 (position, duration, episode_title) 语义一致，
                 *   若只给 progress 加集号守卫，同一部作品在两张表里会
                 *   **各说各话**（一张携带、一张不携带）⇒ 更难解释的 bug。
                 */
                let merged = match to {
                    None => HistoryEntry {
                        key: to_key.to_string(),
                        provider: to_provider.clone(),
                        native_id: to_native_id.clone(),
                        ..f
                    },
                    Some(t) => {
                        let ep_f = episode_number_from_title(f.episode_title.as_deref());
                        let ep_t = episode_number_from_title(t.episode_title.as_deref());
                        if ep_f == ep_t {
                            HistoryEntry {
                                key: to_key.to_string(),
                                provider: to_provider.clone(),
                                native_id: to_native_id.clone(),
                                // ★★ 与 progress 同一规则：单调不减（m00753 ③）
                                position: f.position.max(t.position),
                                // ★ 最近一次观看取 max（m00589 裁决，未被取代）
                                watched_at: f.watched_at.max(t.watched_at),
                                // ★ title / cover / episode_title / duration 保持 TO 的
                                ..t
                            }
                        } else {
                            // ★ 集号不匹配 ⇒ TO 行完全不动（同 progress）
                            t
                        }
                    }
                };
                tx.execute(
                    &format!(
                        "INSERT INTO history ({HIST_COLS}) \
                         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9) \
                         ON CONFLICT(key) DO UPDATE SET \
                           provider=excluded.provider, native_id=excluded.native_id, \
                           title=excluded.title, cover=excluded.cover, \
                           episode_title=excluded.episode_title, \
                           position=excluded.position, duration=excluded.duration, \
                           watched_at=excluded.watched_at"
                    ),
                    params![
                        merged.key,
                        merged.provider,
                        merged.native_id,
                        merged.title,
                        merged.cover,
                        merged.episode_title,
                        merged.position as i64,
                        merged.duration as i64,
                        merged.watched_at,
                    ],
                )
                .map_err(|e| format!("换源迁移：写 history 失败: {e}"))?;

                tx.execute("DELETE FROM history WHERE key=?1", params![from_key])
                    .map_err(|e| format!("换源迁移：删旧 history 失败: {e}"))?;
            }
        }

        // ── ④ skip_markers（★ 同一个坑，别漏：也是 provider:id 分键）──
        {
            let from: Option<SkipMarker> = tx
                .query_row(
                    &format!("SELECT {} FROM skip_markers WHERE key=?1", Self::SKIP_COLS),
                    params![from_key],
                    Self::row_to_skip,
                )
                .optional()
                .map_err(|e| format!("换源迁移：读 skip_markers 失败: {e}"))?;

            if let Some(f) = from {
                let to: Option<SkipMarker> = tx
                    .query_row(
                        &format!("SELECT {} FROM skip_markers WHERE key=?1", Self::SKIP_COLS),
                        params![to_key],
                        Self::row_to_skip,
                    )
                    .optional()
                    .map_err(|e| format!("换源迁移：读 skip_markers(目标) 失败: {e}"))?;

                /*
                 * ★ 四个端点：**FROM 的非 null 优先，缺的用 TO 补**
                 *   论证（Lead 裁决）：用户刚设好的片头片尾要**跟着内容走**；
                 *   换源后"我看到的设置不该变"比"新源上可能存在的旧设置"更可预测。
                 */
                let merged = match to {
                    None => SkipMarker {
                        key: to_key.to_string(),
                        provider: to_provider.clone(),
                        native_id: to_native_id.clone(),
                        ..f
                    },
                    Some(t) => SkipMarker {
                        key: to_key.to_string(),
                        provider: to_provider.clone(),
                        native_id: to_native_id.clone(),
                        title: t.title,
                        intro_start: f.intro_start.or(t.intro_start),
                        intro_end: f.intro_end.or(t.intro_end),
                        outro_start: f.outro_start.or(t.outro_start),
                        outro_end: f.outro_end.or(t.outro_end),
                        auto_skip: f.auto_skip.or(t.auto_skip),
                        updated_at: f.updated_at.max(t.updated_at),
                    },
                };
                tx.execute(
                    &format!(
                        "INSERT INTO skip_markers ({}) \
                         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10) \
                         ON CONFLICT(key) DO UPDATE SET \
                           provider=excluded.provider, native_id=excluded.native_id, \
                           title=excluded.title, intro_start=excluded.intro_start, \
                           intro_end=excluded.intro_end, outro_start=excluded.outro_start, \
                           outro_end=excluded.outro_end, auto_skip=excluded.auto_skip, \
                           updated_at=excluded.updated_at",
                        Self::SKIP_COLS
                    ),
                    params![
                        merged.key,
                        merged.provider,
                        merged.native_id,
                        merged.title,
                        merged.intro_start.map(|v| v as i64),
                        merged.intro_end.map(|v| v as i64),
                        merged.outro_start.map(|v| v as i64),
                        merged.outro_end.map(|v| v as i64),
                        merged.auto_skip.map(|v| v as i32),
                        merged.updated_at,
                    ],
                )
                .map_err(|e| format!("换源迁移：写 skip_markers 失败: {e}"))?;

                /*
                 * ★★★ 旧行必须删掉（与 favorites / progress / history 三张表一致）
                 *
                 * ══════════════════════════════════════════════════════
                 * ⚠️ 这一行曾被**变异测试脚本删掉**且**没有还原**
                 *    （原地留了一句 `// MUT: skip_markers 的旧行没删`）
                 * ══════════════════════════════════════════════════════
                 *
                 * # 后果（不是"少删一行数据"这么轻）
                 * ```text
                 * 换源后：新键有 merged 行 ✓，旧键**还留着原行**
                 * ⇒ `list_skip_markers()` 返回**两条**同一部作品
                 * ⇒ 用户在片头片尾页看到重复条目；
                 *   且**两个 key 的端点可能不同**（合并时是 FROM 优先，
                 *   但旧行没动 ⇒ 旧行保持原样）⇒ 「我设的片头怎么变了/多了一条」
                 * ```
                 *
                 * # 为什么两条 Rust 测试当场就红了
                 * ```text
                 * store::tests::repoint_moves_all_four_tables_and_deletes_old_rows
                 *   panicked: 旧跳过点必须删掉
                 * store::tests::repoint_skip_markers_prefers_from_and_fills_from_to
                 *   panicked: 旧行必须删掉
                 * ```
                 * ★ 也就是说：**测试一直在守着这条**，是变异脚本没还原干净。
                 * ⇒ 教训（本仓铁律）：**变异脚本必须能证明自己还原干净**
                 *   （逐字节哈希 + 复跑全绿），否则它会**把缺陷留在代码里**。
                 */
                tx.execute("DELETE FROM skip_markers WHERE key=?1", params![from_key])
                    .map_err(|e| format!("换源迁移：删旧 skip_markers 失败: {e}"))?;
            }
        }

        tx.commit()
            .map_err(|e| format!("换源迁移提交事务失败: {e}"))?;
        Ok(())
    }

    // ─────────────────── 平台历史备份（备份平面） ───────────────────

    pub fn save_platform_history(
        &self,
        provider: &str,
        device_id: &str,
        records: &[UserRecord],
    ) -> Result<usize, String> {
        let conn = self.conn.lock().unwrap();
        let now = chrono::Utc::now().timestamp_millis();
        let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
        let mut n = 0;
        for r in records {
            tx.execute(
                r#"INSERT INTO platform_history
                     (key,provider,native_id,title,cover,episode_title,position,duration,platform_time,captured_at,device_id)
                   VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
                   ON CONFLICT(key) DO UPDATE SET
                     position=excluded.position, duration=excluded.duration,
                     platform_time=excluded.platform_time, captured_at=excluded.captured_at"#,
                params![
                    r.key, provider, r.native_id, r.title, r.cover,
                    r.payload.get("episode_title").and_then(|v| v.as_str()),
                    r.position.unwrap_or(0) as i64,
                    r.duration.unwrap_or(0) as i64,
                    // 平台自己的时间戳优先
                    r.payload.get("platform_time").and_then(|v| v.as_i64()).unwrap_or(r.updated_at),
                    now, device_id
                ],
            )
            .map_err(|e| e.to_string())?;
            n += 1;
        }
        tx.commit().map_err(|e| e.to_string())?;
        Ok(n)
    }

    pub fn list_platform_history(&self, limit: u32) -> Result<Vec<serde_json::Value>, String> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT key,provider,native_id,title,cover,episode_title,position,duration,platform_time,captured_at
                 FROM platform_history ORDER BY platform_time DESC LIMIT ?1",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map(params![limit], |r| {
                Ok(serde_json::json!({
                    "key": r.get::<_, String>(0)?,
                    "provider": r.get::<_, String>(1)?,
                    "native_id": r.get::<_, String>(2)?,
                    "title": r.get::<_, String>(3)?,
                    "cover": r.get::<_, Option<String>>(4)?,
                    "episode_title": r.get::<_, Option<String>>(5)?,
                    "position": r.get::<_, i64>(6)?,
                    "duration": r.get::<_, i64>(7)?,
                    "platform_time": r.get::<_, i64>(8)?,
                    "captured_at": r.get::<_, i64>(9)?,
                }))
            })
            .map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
    }

    // ─────────────────── 同步元数据 ───────────────────

    pub fn set_meta(&self, k: &str, v: &str) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO sync_meta(k,v) VALUES(?1,?2) ON CONFLICT(k) DO UPDATE SET v=excluded.v",
            params![k, v],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn get_meta(&self, k: &str) -> Result<Option<String>, String> {
        let conn = self.conn.lock().unwrap();
        conn.query_row("SELECT v FROM sync_meta WHERE k=?1", params![k], |r| r.get(0))
            .optional()
            .map_err(|e| e.to_string())
    }
}

/// 把 `<provider>:<native_id>` 拆成两半
///
/// # 为什么用 `split_once` 而不是 `split(':')`
///
/// `native_id` **本身可能含冒号** —— 实测用户库里有：
/// ```text
/// bilibili:av:BV1Bfex6tEEH        provider=bilibili  native_id=av:BV1Bfex6tEEH
/// bilibili:bilibili:av:BV1B8ZJYTEPg  ★ provider=bilibili  native_id=bilibili:av:BV1B8ZJYTEPg
/// ```
/// ⇒ 只能按**第一个**冒号切。用 `split(':')` 取第二段会把
///   `native_id` 截断成 `av`（**静默**写错 provider/native_id）。
///
/// ★ 与 `commands_write::item_key`（`format!("{provider}:{id}")`）是**逆运算**，
///   两处必须同时成立。
fn split_item_key(key: &str) -> Result<(String, String), String> {
    match key.split_once(':') {
        Some((p, id)) if !p.is_empty() && !id.is_empty() => {
            Ok((p.to_string(), id.to_string()))
        }
        _ => Err(format!("非法的记录 key（应为 <provider>:<id>）: {key:?}")),
    }
}

// ─────────────── 集号解析（换源合并用，必须与 Dart 逐字一致）───────────────

/// ECMAScript `\s` 的**显式**等价类 —— 必须逐字对齐 Dart 的 `RegExp` 语义
///
/// # ★★ 为什么**不能**用 Rust 的 `\s`
///
/// ```text
/// Dart 的 RegExp 是 **ECMAScript** 语义；Rust 的 regex 默认 **Unicode** 语义。
/// 两者的 `\s` **不等价**，实测（.probe/t67u_ws_probe.dart）：
///
///   U+0085 NEL   Dart 不认（⇒ null）   Rust `\s` = \p{White_Space} **认**  ⇒ 分歧
///   U+FEFF BOM   Dart **认**（⇒ 1）     Rust `\s` **不认**              ⇒ 分歧
/// ```
/// ⇒ 若照抄 Dart 的 `\s`，Rust 侧会在两个字符上**静默**给出不同答案，
///   而分歧只在"换源合并到底携不携带进度"上体现 —— 最难发现的一类。
///
/// # ECMAScript 的 `\s` = WhiteSpace ∪ LineTerminator
///
/// ```text
/// U+0009 TAB   U+000A LF    U+000B VT    U+000C FF    U+000D CR   U+0020 SP
/// U+00A0 NBSP  U+1680 OGHAM SP
/// U+2000..U+200A（EN QUAD .. HAIR SP）
/// U+2028 LS    U+2029 PS    U+202F NNBSP U+205F MMSP U+3000 IDEOGRAPHIC SP
/// U+FEFF ZWNBSP（★ 是 WhiteSpace，虽然名字叫"零宽"）
/// ```
/// ⚠️ **不含** U+0085（NEL）、**不含** U+200B（ZWSP）—— 实测两者都不匹配。
const ECMA_WS: &str = "\t\n\x0B\x0C\r \u{00A0}\u{1680}\u{2000}-\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}";

/// 编译好的集号正则（只编译一次）
///
/// 等价于 Dart 的 `RegExp(r'第\s*(\d+)\s*[集话話]')`，但：
/// ```text
/// \s ⇒ 显式 ECMA_WS 字符类（见上）
/// \d ⇒ [0-9]（★ 不能用 \d：Rust 的 \d = \p{Nd}，会认阿拉伯-印度数字
///              '第٣集' ⇒ Dart null / Rust 3 ⇒ 分歧）
/// ```
/// ★ 语义也是 leftmost-first（与 ECMAScript 相同）⇒
///   `第1集第2集` 两侧都取**第一个**匹配（实测 = 1）。
fn episode_re() -> &'static regex::Regex {
    static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| {
        regex::Regex::new(&format!(
            "第[{ws}]*([0-9]+)[{ws}]*[集话話]",
            ws = ECMA_WS
        ))
        .expect("集号正则必须能编译（写错了就是编译期以外最响的失败）")
    })
}

/// 从「第NN集」这类标题里解析集号（1-based）；解析不出返回 `None`
///
/// # ★★★ 这是 `lib/core/models.dart:1577 episodeNumberFromTitle` 的 **Rust 镜像**
///
/// ```text
/// 两份实现必须**逐字等价** —— 因为换源合并发生在 Rust 侧，
/// 而 Dart 侧手上只有 FROM 那一半（TO 的行只有 Rust 读得到）。
/// 让 Dart 去查 TO 的行会变成"两次 FFI + TOCTOU"，更糟（m00753 ⑥ 的裁决）。
/// ⇒ 两份实现被**同一张夹具**钉住：
///      test/fixtures/episode_number_cases.json
///    Dart 侧：test/t67_episode_fixture_test.dart
///    Rust 侧：本文件的 episode_number_fixture_matches_dart
///   夹具漂了 ⇒ 两侧一起红。
/// ```
///
/// # 与 Dart 版逐条对齐的三个点（都是实测出来的，不是照抄）
///
/// ```text
/// ① 全角数字先归一化（'第０１集' ⇒ '第01集'）—— 与 Dart 的
///    replaceAllMapped(RegExp(r'[０-９]'), -0xFEE0) 同一手法
/// ② 解析用 **i64**：Dart 的 int 在 64 位平台是 i64，
///    int.tryParse('9223372036854775808') ⇒ null（溢出）
///    Rust 若用 u64/u128 会解析成功 ⇒ 分歧（实测钉在夹具里）
/// ③ 前导零：两侧都跳过再判溢出（'09223372036854775808' ⇒ null；
///    '09223372036854775807' ⇒ 9223372036854775807）—— 已实测一致
/// ```
fn episode_number_from_title(title: Option<&str>) -> Option<i64> {
    let t = title?;
    if t.is_empty() {
        return None;
    }
    // ── ① 全角数字 U+FF10..=U+FF19 ⇒ ASCII '0'..='9' ──
    let normalized: String = t
        .chars()
        .map(|c| {
            let u = c as u32;
            if (0xFF10..=0xFF19).contains(&u) {
                char::from_u32(u - 0xFEE0).unwrap_or(c)
            } else {
                c
            }
        })
        .collect();

    // ── ② 匹配（firstMatch 语义由 regex 的 leftmost-first 保证）──
    let caps = episode_re().captures(&normalized)?;
    // ── ③ i64 解析（溢出 ⇒ None，与 Dart int.tryParse 一致）──
    let n: i64 = caps.get(1)?.as_str().parse().ok()?;
    // ── ④ 守卫：0 与负数都不算集号（'第000集' ⇒ None）──
    if n <= 0 {
        return None;
    }
    Some(n)
}

fn row_to_favorite(r: &rusqlite::Row<'_>) -> rusqlite::Result<Favorite> {    Ok(Favorite {
        key: r.get(0)?,
        provider: r.get(1)?,
        native_id: r.get(2)?,
        title: r.get(3)?,
        cover: r.get(4)?,
        group_name: r.get(5)?,
        kind: r.get(6)?,
        favorited: r.get::<_, i32>(7)? != 0,
        following: r.get::<_, i32>(8)? != 0,
        last_episode_count: r.get::<_, i64>(9)? as u32,
        last_episode_title: r.get(10)?,
        unread_count: r.get::<_, i64>(11)? as u32,
        last_checked_at: r.get(12)?,
        last_update_at: r.get(13)?,
        note: r.get(14)?,
        created_at: r.get(15)?,
        updated_at: r.get(16)?,
        deleted: r.get::<_, i32>(17)? != 0,
    })
}

fn row_to_progress(r: &rusqlite::Row<'_>) -> rusqlite::Result<Progress> {
    Ok(Progress {
        key: r.get(0)?,
        provider: r.get(1)?,
        native_id: r.get(2)?,
        title: r.get(3)?,
        cover: r.get(4)?,
        episode_id: r.get(5)?,
        episode_title: r.get(6)?,
        position: r.get::<_, i64>(7)? as u64,
        duration: r.get::<_, i64>(8)? as u64,
        finished: r.get::<_, i32>(9)? != 0,
        updated_at: r.get(10)?,
    })
}

/// `history` 行 → [`HistoryEntry`]
///
/// ⚠️ 下标必须与 [`HIST_COLS`] **逐一对齐**（原先这段是内联在
///    `list_history` 的闭包里的，`repoint_item` 要复用 ⇒ 抽出来）。
fn row_to_history(r: &rusqlite::Row<'_>) -> rusqlite::Result<HistoryEntry> {
    Ok(HistoryEntry {
        key: r.get(0)?,
        provider: r.get(1)?,
        native_id: r.get(2)?,
        title: r.get(3)?,
        cover: r.get(4)?,
        episode_title: r.get(5)?,
        position: r.get::<_, i64>(6)? as u64,
        duration: r.get::<_, i64>(7)? as u64,
        watched_at: r.get(8)?,
    })
}

// ─────────────────────────── 测试 ───────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn fav(key: &str, following: bool) -> Favorite {
        Favorite {
            key: key.into(),
            provider: "cctv".into(),
            native_id: key.split(':').nth(1).unwrap_or("x").into(),
            title: format!("测试 {key}"),
            cover: None,
            group_name: None,
            kind: "series".into(),
            // 这些用例都在验证「收藏列表」的行为，故必须是真收藏
            favorited: true,
            following,
            last_episode_count: 10,
            last_episode_title: Some("第10集".into()),
            unread_count: 0,
            last_checked_at: 0,
            last_update_at: 0,
            note: None,
            created_at: 1000,
            updated_at: 1000,
            deleted: false,
        }
    }

    #[test]
    fn favorite_roundtrip() {
        let db = Db::in_memory().unwrap();
        db.upsert_favorite(&fav("cctv:a", true)).unwrap();
        let list = db.list_favorites(false).unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].title, "测试 cctv:a");
        assert!(list[0].following);
    }

    #[test]
    fn tombstone_hides_but_keeps() {
        let db = Db::in_memory().unwrap();
        db.upsert_favorite(&fav("cctv:a", false)).unwrap();
        db.tombstone_favorite("cctv:a", 2000).unwrap();

        // 正常查询看不到
        assert_eq!(db.list_favorites(false).unwrap().len(), 0);
        // 但记录仍在（墓碑）
        let all = db.list_favorites(true).unwrap();
        assert_eq!(all.len(), 1);
        assert!(all[0].deleted);
    }

    #[test]
    fn tombstone_purge_respects_cutoff() {
        let db = Db::in_memory().unwrap();
        db.upsert_favorite(&fav("cctv:old", false)).unwrap();
        db.tombstone_favorite("cctv:old", 1000).unwrap();
        // cutoff 之后，不应被清理
        assert_eq!(db.purge_tombstones(500).unwrap(), 0);
        // cutoff 之前，应被清理
        assert_eq!(db.purge_tombstones(2000).unwrap(), 1);
        assert_eq!(db.list_favorites(true).unwrap().len(), 0);
    }

    /// ★★★ 取消收藏**不得**影响追更（Owner 报的真 bug，2026-09-21）
    ///
    /// # Owner 原话
    ///
    /// > 在追更和收藏都打开的情况下，无法取消收藏
    /// > 必须要取消追更，才能取消收藏，**这两个是不需要联动的**
    ///
    /// # 这个用例锁的是"数据库层不联动"
    ///
    /// 前端当时用 `!deleted` 当"是否已收藏"，而 `unfavorite` 在
    /// `following=1` 时**故意不写墓碑**（`deleted` 保持 0）——
    /// 于是前端算出 `isFav=true`，表现为"取消不掉"。
    ///
    /// ⚠️ 关键断言是 **`deleted` 仍为 0** ——
    ///    它不是 bug，而是本文件反复声明的不变量
    ///    （`deleted=1 ⇔ !favorited && !following`）。
    ///    真正要修的是**消费方用错了字段**（前端已改为读 `favorited`）。
    ///    若哪天有人"顺手"把这里改成无条件写墓碑，
    ///    这个用例会红 —— 那正是为了防止把联动又加回来。
    #[test]
    fn unfavorite_does_not_touch_following() {
        let db = Db::in_memory().unwrap();
        // 既收藏又追更
        db.upsert_favorite(&fav("cctv:a", true)).unwrap();

        db.unfavorite("cctv:a", 2000).unwrap();

        let f = db.get_favorite("cctv:a").unwrap().expect("行应仍在");
        assert!(!f.favorited, "收藏应被取消");
        assert!(f.following, "★ 追更必须原样保留 —— 两个状态不联动");
        assert!(
            !f.deleted,
            "★ 追更还开着时不能写墓碑（不变量：deleted=1 ⇔ 两者皆假）"
        );

        // 收藏列表里没有了，但追更列表里还在
        assert_eq!(db.list_favorites(false).unwrap().len(), 0);
        assert_eq!(db.list_following_for_ui().unwrap().len(), 1);
    }

    /// 反过来：关闭追更**不得**影响收藏
    #[test]
    fn unfollow_does_not_touch_favorited() {
        let db = Db::in_memory().unwrap();
        db.upsert_favorite(&fav("cctv:a", true)).unwrap();

        db.unfollow("cctv:a", 2000).unwrap();

        let f = db.get_favorite("cctv:a").unwrap().expect("行应仍在");
        assert!(f.favorited, "★ 收藏必须原样保留 —— 两个状态不联动");
        assert!(!f.following, "追更应被关闭");
        assert!(!f.deleted, "收藏还开着时不能写墓碑");

        assert_eq!(db.list_favorites(false).unwrap().len(), 1);
        assert_eq!(db.list_following_for_ui().unwrap().len(), 0);
    }

    /// ★ 两个都关掉之后**才**写墓碑（不变量成立）
    #[test]
    fn tombstone_only_after_both_states_off() {
        let db = Db::in_memory().unwrap();
        db.upsert_favorite(&fav("cctv:a", true)).unwrap();

        db.unfavorite("cctv:a", 2000).unwrap();
        assert!(!db.get_favorite("cctv:a").unwrap().unwrap().deleted);

        db.unfollow("cctv:a", 3000).unwrap();
        let f = db.get_favorite("cctv:a").unwrap().unwrap();
        assert!(f.deleted, "两个状态都没了 → 才写墓碑");
        assert!(!f.favorited && !f.following);
    }

    /// ★ 「只追更不收藏」必须能被追更列表查到
    ///
    /// 这是解耦后新引入的合法状态，也是首页「最近追更」原先**漏掉**的那批：
    /// 后端 `list_favorites(false)` 的 SQL 是 `WHERE favorited=1`，
    /// 所以只追更的条目在收藏查询里**查不到**，必须走
    /// `list_following_for_ui()`。前端 MyShelf 原先只查前者。
    #[test]
    fn follow_only_row_is_listed_in_following_not_favorites() {
        let db = Db::in_memory().unwrap();
        let mut f = fav("cctv:only-follow", true);
        f.favorited = false; // ★ 只追更、不收藏
        db.upsert_favorite(&f).unwrap();

        assert_eq!(
            db.list_favorites(false).unwrap().len(),
            0,
            "只追更不收藏 → 不在收藏列表里"
        );
        assert_eq!(
            db.list_following_for_ui().unwrap().len(),
            1,
            "★ 但必须在追更列表里（否则首页追更 tab 看不到它）"
        );
    }

    #[test]
    fn follow_list_and_unread() {
        let db = Db::in_memory().unwrap();
        db.upsert_favorite(&fav("cctv:a", true)).unwrap();
        db.upsert_favorite(&fav("cctv:b", false)).unwrap();

        assert_eq!(db.list_following().unwrap().len(), 1);

        // 模拟追更：新增 2 集，未读 2
        let mut f = db.get_favorite("cctv:a").unwrap().unwrap();
        f.unread_count = 2;
        f.last_episode_count = 12;
        db.upsert_favorite(&f).unwrap();
        assert_eq!(db.total_unread().unwrap(), 2);

        db.mark_favorite_read("cctv:a", 3000).unwrap();
        assert_eq!(db.total_unread().unwrap(), 0);
    }

    #[test]
    fn progress_continue_watching_filters_early_exit() {
        let db = Db::in_memory().unwrap();
        // position <= 5 的不应出现在续播（避免误点即记录）
        db.upsert_progress(&Progress {
            key: "cctv:x".into(),
            provider: "cctv".into(),
            native_id: "x".into(),
            title: "X".into(),
            cover: None,
            episode_id: None,
            episode_title: None,
            position: 3,
            duration: 100,
            finished: false,
            updated_at: 1,
        })
        .unwrap();
        assert_eq!(db.continue_watching(10).unwrap().len(), 0);

        // 正常进度应出现
        db.upsert_progress(&Progress {
            key: "cctv:y".into(),
            provider: "cctv".into(),
            native_id: "y".into(),
            title: "Y".into(),
            cover: None,
            episode_id: None,
            episode_title: None,
            position: 60,
            duration: 100,
            finished: false,
            updated_at: 2,
        })
        .unwrap();
        let cw = db.continue_watching(10).unwrap();
        assert_eq!(cw.len(), 1);
        assert_eq!(cw[0].title, "Y");
    }

    #[test]
    fn history_and_platform_backup_are_separate_planes() {
        let db = Db::in_memory().unwrap();

        // 独立平面：我们自己的历史
        db.add_history(&HistoryEntry {
            key: "cctv:a".into(),
            provider: "cctv".into(),
            native_id: "a".into(),
            title: "我们的记录".into(),
            cover: None,
            episode_title: Some("第1集".into()),
            position: 30,
            duration: 100,
            watched_at: 5000,
        })
        .unwrap();
        assert_eq!(db.list_history(10).unwrap().len(), 1);

        // 备份平面：平台自带历史（镜像）
        let rec = UserRecord {
            key: "cycani:history:51720".into(),
            provider: "cycani".into(),
            kind: "history".into(),
            native_id: "51720".into(),
            title: "平台番剧".into(),
            cover: None,
            position: Some(167556),
            duration: Some(1439916),
            payload: serde_json::json!({"episode_title":"第18集","platform_time": 1789385000})
                .as_object()
                .unwrap()
                .clone(),
            updated_at: 1789385000000,
            deleted: false,
        };
        assert_eq!(
            db.save_platform_history("cycani", "dev1", &[rec]).unwrap(),
            1
        );
        assert_eq!(db.list_platform_history(10).unwrap().len(), 1);
        // 两个平面互不干扰
        assert_eq!(db.list_history(10).unwrap().len(), 1);
    }

    #[test]
    fn meta_roundtrip() {
        let db = Db::in_memory().unwrap();
        assert!(db.get_meta("watermark").unwrap().is_none());
        db.set_meta("watermark", "12345").unwrap();
        assert_eq!(db.get_meta("watermark").unwrap().unwrap(), "12345");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  ★★★ 2026-09-26：`upsert_progress` 的"空值不得覆盖"守卫
    // ═══════════════════════════════════════════════════════════════════
    //
    // # 用户原话（Owner）
    //
    // > 还有，播放记录多了几个 显示 ？ 的记录，没有封面没有名字点进去才知道是什么
    //
    // # 为什么要这几条测试
    //
    // 原语句 `title=excluded.title, cover=excluded.cover` 是**无条件覆盖**，
    // 而合并页"一进页就起播、标题要等详情 IPC"⇒ 那几秒内写库会把
    // **本来正确的**标题/封面清成空。
    //
    // ★ 实测用户真实库（`.probe/ROOTCAUSE-panel-and-history.md`）：
    //   15 行里 3 行 `title='' + cover=NULL`，正是这么来的。
    //
    // ⚠️ 反向也要测（第 3 条）：**非空的新值必须能覆盖**
    //    —— 否则"修复"就变成了"标题永远改不了"，那是另一个 bug。

    /// 造一条进度记录（测试用）
    fn prog(key: &str, title: &str, cover: Option<&str>, pos: u64) -> Progress {
        Progress {
            key: key.into(),
            provider: "cycani".into(),
            native_id: key.split(':').nth(1).unwrap_or("x").into(),
            title: title.into(),
            cover: cover.map(|s| s.to_string()),
            episode_id: None,
            episode_title: None,
            position: pos,
            duration: 1000,
            finished: false,
            updated_at: 1000,
        }
    }

    #[test]
    fn empty_title_must_not_overwrite_existing() {
        let db = Db::in_memory().unwrap();
        // ① 先写入**正确**的标题与封面
        db.upsert_progress(&prog("cycani:3862", "无职转生", Some("https://x/c.jpg"), 77))
            .unwrap();
        // ② 再写入**还不知道标题**的一次（合并页起播那几秒的真实形态）
        db.upsert_progress(&prog("cycani:3862", "", None, 80)).unwrap();

        let list = db.list_all_progress().unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(
            list[0].title, "无职转生",
            "★ 空标题**不得**覆盖已有标题 —— 否则播放记录又变成「？」"
        );
        assert_eq!(
            list[0].cover.as_deref(),
            Some("https://x/c.jpg"),
            "★ None 封面**不得**覆盖已有封面"
        );
        // ★ 但 position 必须**照常更新**（它是"当前播放状态"，本就该被最新值覆盖）
        assert_eq!(list[0].position, 80, "★ position 必须仍然被更新（只有 title/cover 加守卫）");
    }

    #[test]
    fn nonempty_title_and_cover_still_update() {
        let db = Db::in_memory().unwrap();
        db.upsert_progress(&prog("cycani:a", "旧名", Some("https://x/old.jpg"), 10))
            .unwrap();
        db.upsert_progress(&prog("cycani:a", "新名", Some("https://x/new.jpg"), 20))
            .unwrap();

        let list = db.list_all_progress().unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(
            list[0].title, "新名",
            "★ 非空新值**必须**能覆盖 —— 否则修成了「标题永远改不了」"
        );
        assert_eq!(list[0].cover.as_deref(), Some("https://x/new.jpg"));
        assert_eq!(list[0].position, 20);
    }

    #[test]
    fn empty_title_on_first_insert_stays_empty() {
        let db = Db::in_memory().unwrap();
        // 首次插入（没有旧行可保留）⇒ 守卫**不**适用 ⇒ 就是空
        // ★ 这条防的是"守卫写成了无条件 COALESCE(旧值)"那种越界修复。
        db.upsert_progress(&prog("cycani:b", "", None, 5)).unwrap();
        let list = db.list_all_progress().unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].title, "", "首次插入没有旧值可保留 ⇒ 空就是空");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  ★★★ task-67 需求⑤：换源迁移（repoint_item）
    // ═══════════════════════════════════════════════════════════════════

    /// 造一条带完整字段的 `Favorite`（用于验证 OR / min / max 的合并）
    fn fav_full(
        key: &str,
        favorited: bool,
        following: bool,
        unread: u32,
        created: i64,
        updated: i64,
    ) -> Favorite {
        Favorite {
            key: key.into(),
            provider: key.split(':').next().unwrap_or("x").into(),
            native_id: key.split_once(':').map(|(_, b)| b).unwrap_or("x").into(),
            title: format!("标题 {key}"),
            cover: Some(format!("https://x/{key}.jpg")),
            group_name: None,
            kind: "series".into(),
            favorited,
            following,
            last_episode_count: 12,
            last_episode_title: Some("第12集".into()),
            unread_count: unread,
            last_checked_at: 0,
            last_update_at: 0,
            note: None,
            created_at: created,
            updated_at: updated,
            deleted: false,
        }
    }

    fn prog_full(key: &str, title: &str, pos: u64, dur: u64, finished: bool) -> Progress {
        Progress {
            key: key.into(),
            provider: key.split(':').next().unwrap_or("x").into(),
            native_id: key.split_once(':').map(|(_, b)| b).unwrap_or("x").into(),
            title: title.into(),
            cover: Some(format!("https://x/{key}.jpg")),
            episode_id: Some("ep-1".into()),
            episode_title: Some("第01集".into()),
            position: pos,
            duration: dur,
            finished,
            updated_at: 1000,
        }
    }

    /// 造一条**指定集名**的 `Progress` —— 换源合并的集号匹配测试要用它
    ///
    /// ★ 与 [`prog_full`] 的区别：`prog_full` 的集名**恒为** `'第01集'`，
    ///   而集号匹配的三种情形（相同 / 不同 / 一侧 null / 两侧 null）
    ///   必须能**逐个构造**，否则测不到守卫。
    fn prog_ep(
        key: &str,
        title: &str,
        pos: u64,
        dur: u64,
        finished: bool,
        ep: &str,
    ) -> Progress {
        Progress {
            episode_title: Some(ep.into()),
            ..prog_full(key, title, pos, dur, finished)
        }
    }

    fn hist(key: &str, pos: u64, watched_at: i64) -> HistoryEntry {
        HistoryEntry {
            key: key.into(),
            provider: key.split(':').next().unwrap_or("x").into(),
            native_id: key.split_once(':').map(|(_, b)| b).unwrap_or("x").into(),
            title: format!("标题 {key}"),
            cover: None,
            episode_title: Some("第01集".into()),
            position: pos,
            duration: 2700,
            watched_at,
        }
    }

    /// 造一条**指定集名**的 `HistoryEntry` —— history 段的集号匹配测试要用它
    ///
    /// ★ 与 [`hist`] 的区别：`hist` 的集名**恒为** `'第01集'`，
    ///   而 "集号写法不同但**语义相同**"（`'第01集'` vs `'第1集'`，
    ///   都解析成 1）这种情形必须能**逐个构造**，否则测不出 `..t` / `..f` 的区别。
    fn hist_ep(key: &str, pos: u64, watched_at: i64, ep: &str) -> HistoryEntry {
        HistoryEntry {
            episode_title: Some(ep.into()),
            ..hist(key, pos, watched_at)
        }
    }

    #[test]
    fn split_item_key_handles_colons_inside_native_id() {
        // ★ 实测用户库里真的有这种 key（bilibili 的 native_id 自带 "av:"）
        assert_eq!(
            split_item_key("bilibili:av:BV1Bfex6tEEH").unwrap(),
            ("bilibili".to_string(), "av:BV1Bfex6tEEH".to_string()),
            "★ 只能按**第一个**冒号切 —— 否则 native_id 会被截断成 av"
        );
        assert!(split_item_key("nocolon").is_err());
        assert!(split_item_key(":x").is_err());
        assert!(split_item_key("x:").is_err());
    }

    #[test]
    fn repoint_moves_all_four_tables_and_deletes_old_rows() {
        let db = Db::in_memory().unwrap();
        db.upsert_favorite(&fav_full("360:86969", true, true, 0, 100, 200))
            .unwrap();
        db.upsert_progress(&prog_full("360:86969", "老舅", 600, 2777, false))
            .unwrap();
        db.add_history(&hist("360:86969", 600, 5000)).unwrap();
        db.upsert_skip_marker(&SkipMarker {
            key: "360:86969".into(),
            provider: "360".into(),
            native_id: "86969".into(),
            title: "老舅".into(),
            intro_start: Some(0),
            intro_end: Some(90),
            outro_start: None,
            outro_end: None,
            auto_skip: Some(true),
            updated_at: 700,
        })
        .unwrap();

        db.repoint_item("360:86969", "caiji:74774").unwrap();

        // ① 旧行**必须**全部消失
        assert!(db.get_favorite("360:86969").unwrap().is_none(), "旧收藏行必须删掉");
        assert!(db.get_progress("360:86969").unwrap().is_none(), "旧进度行必须删掉");
        assert!(
            db.get_skip_marker("360:86969").unwrap().is_none(),
            "旧跳过点必须删掉"
        );
        assert_eq!(
            db.list_history(100).unwrap().iter().filter(|h| h.key == "360:86969").count(),
            0,
            "旧历史行必须删掉"
        );

        // ② 新行**必须**全部存在，且 provider/native_id 与新 key 一致
        let f = db.get_favorite("caiji:74774").unwrap().expect("新收藏行必须存在");
        assert_eq!(f.provider, "caiji");
        assert_eq!(f.native_id, "74774");
        let p = db.get_progress("caiji:74774").unwrap().expect("新进度行必须存在");
        assert_eq!((p.provider.as_str(), p.native_id.as_str()), ("caiji", "74774"));
        let s = db.get_skip_marker("caiji:74774").unwrap().expect("新跳过点必须存在");
        assert_eq!((s.provider.as_str(), s.native_id.as_str()), ("caiji", "74774"));
        assert_eq!(
            db.list_history(100).unwrap().iter().filter(|h| h.key == "caiji:74774").count(),
            1,
            "新历史行必须恰好一条"
        );

        // ③ 数量不增不减（不重复）
        assert_eq!(db.list_favorites(true).unwrap().len(), 1);
        assert_eq!(db.list_all_progress().unwrap().len(), 1);
        assert_eq!(db.list_history(100).unwrap().len(), 1);
        assert_eq!(db.list_skip_markers().unwrap().len(), 1);
    }

    /// ★★★ 《老舅》真实例子：**TO 行已存在** ⇒ 合并后不丢、不重
    #[test]
    fn repoint_merges_when_target_row_already_exists_laojiu_case() {
        let db = Db::in_memory().unwrap();

        // FROM = 360:86969（用户在 360 看到 600 秒）
        /*
         * ★★★ 这些数值是**刻意选**的 —— 为了让每条合并规则都有**分辨力**
         *
         * # 我第一版选的数值让两条断言**没有分辨力**（红度证明 M10 抓到的）
         * ```text
         * 第一版：FROM unread=0 / TO unread=3
         *   max(0,3) = 3，而"取 TO 的" = 3  ⇒ ★ 两者**同值** ⇒ 断言分不出来
         *   ⇒ 把 `max` 改成"取 TO 的"，测试**照样绿**（M10 实测仍绿）
         * 第一版：FROM updated=200 / TO updated=950
         *   max(200,950) = 950，而"取 TO 的" = 950 ⇒ ★ 同样分不出来
         * ```
         * ⇒ 现在刻意让 **FROM 的值更大**（unread 7>3、updated 2000>950），
         *   于是 max 与"取 TO"**必然不同** ⇒ 断言才有分辨力。
         * ★ 教训：**"合并规则"的测试里，两侧的值必须让规则产生可观测差异** ——
         *   否则测到的是"两条路径恰好同值"，不是"规则正确"。
         *   ★★ 而这类缺陷**只有红度证明能发现**：测试本身全绿，看起来完美。
         */
        db.upsert_favorite(&fav_full("360:86969", true, false, 7, 100, 2000))
            .unwrap();
        db.upsert_progress(&prog_full("360:86969", "老舅(360)", 600, 2777, false))
            .unwrap();
        db.add_history(&hist("360:86969", 600, 5000)).unwrap();

        // TO = caiji:74774（已存在：追更中、有 3 条未读、position 只有 100）
        let mut to_fav = fav_full("caiji:74774", false, true, 3, 900, 950);
        to_fav.title = "老舅(新源)".into();
        db.upsert_favorite(&to_fav).unwrap();
        db.upsert_progress(&prog_full("caiji:74774", "老舅(新源)", 100, 2759, false))
            .unwrap();
        db.add_history(&hist("caiji:74774", 100, 1000)).unwrap();

        db.repoint_item("360:86969", "caiji:74774").unwrap();

        // ① 不重复
        assert_eq!(db.list_favorites(true).unwrap().len(), 1, "★ 不许出现两行");
        assert_eq!(db.list_all_progress().unwrap().len(), 1, "★ 不许出现两行");
        assert_eq!(db.list_history(100).unwrap().len(), 1, "★ 不许出现两行");

        // ② favorited/following 取 OR
        let f = db.get_favorite("caiji:74774").unwrap().unwrap();
        assert!(f.favorited, "★ OR：FROM 收藏过 ⇒ 合并后仍是收藏");
        assert!(f.following, "★ OR：TO 在追更 ⇒ 合并后仍在追更");

        // ③ ★★ unread 取 **max(7,3)=7** —— 刻意让 FROM 更大，否则与"取 TO 的"同值
        assert_eq!(
            f.unread_count, 7,
            "★ unread 取 max —— 别把'有新集'丢了。\
             ⚠️ FROM=7 > TO=3 是**刻意**的：若取 TO 的会得到 3 ⇒ 断言能分辨"
        );
        assert_eq!(f.created_at, 100, "★ created_at 取 min（保留最早那次）");
        // ④ ★★ updated 取 **max(2000,950)=2000** —— 同样刻意让 FROM 更大
        assert_eq!(
            f.updated_at, 2000,
            "★ updated_at 取 max（LWW 依据）。\
             ⚠️ FROM=2000 > TO=950 是刻意的：若取 TO 的会得到 950 ⇒ 断言能分辨"
        );

        // ④ title/cover 取 TO 的（用户正在看新源）
        let p = db.get_progress("caiji:74774").unwrap().unwrap();
        assert_eq!(p.title, "老舅(新源)", "★ 标题取 TO 的（详情页会回填真标题）");
        assert_eq!(p.provider, "caiji");

        /*
         * ⑤ ★★ position 取 **max(600,100)=600**
         *
         * ⚠️ ★★★ 这条断言**只能分辨一半** —— 必须知道它的边界：
         * ```text
         * max(600,100) = 600 == FROM  ⇒ 能分辨"取 max" vs "取 TO 的"(100)
         *                            ⇒ ✗ **不能**分辨"取 max" vs "取 FROM 的"
         * ```
         * 数学上无解：`max` 不可能同时不等于两个操作数。
         * ⇒ "取 max" vs "取 FROM" 这一半**只能**由 **TO > FROM** 的样本分辨，
         *   那个样本是《无职转生》（FROM=91 / TO=766）——
         *   见 `repoint_position_takes_max_when_to_is_larger_mushoku_case`。
         * ★ 这也正是 m00753 ③ 说"无职转生那组是红度证明的唯一锚点"的原因。
         */
        assert_eq!(
            p.position, 600,
            "★★ position 取 max(600,100)=600 —— \
             ⚠️ 本样本 FROM>TO ⇒ 只能分辨'取 max' vs '取 TO 的'；\
             '取 max' vs '取 FROM 的'由无职转生那组分辨"
        );
        // ⑥ ★ 集号匹配（两边都是 '第01集'）⇒ 走合并分支；finished 取 FROM 的
        assert!(!p.finished, "★ finished 取 FROM 的（决策点，见 repoint_item 文档）");

        // ⑦ history：watched_at 取 max（5000），position 取 max(600,100)=600
        let h = &db.list_history(100).unwrap()[0];
        assert_eq!(h.watched_at, 5000, "★ watched_at 取 max（最近一次观看）");
        assert_eq!(h.position, 600, "★ 观看位置同样取 max（与 progress 同一规则）");
    }

    /// ★★★ 《无职转生》样本：**TO > FROM** ⇒ 这是"取 max" vs "取 FROM" 的**唯一锚点**
    ///
    /// # 为什么必须单独一条（不是重复劳动）
    ///
    /// ```text
    /// 《老舅》那组：FROM=600 > TO=100 ⇒ max=600=FROM
    ///   ⇒ 能分辨 "取 max" vs "取 TO 的"，但**分辨不出** "取 max" vs "取 FROM 的"
    /// ```
    /// ★ `max` **不可能**同时不等于两个操作数 ⇒ 必须**两个方向各一个样本**：
    /// ```text
    /// 《老舅》      FROM > TO  ⇒ 守住"别退回到 TO"
    /// 《无职转生》  TO   > FROM ⇒ 守住"别退回到 FROM"  ← 本用例
    /// ```
    /// # 真实读数（`.probe/dbcopy-t67c`）
    ///
    /// ```text
    /// cycani:3862      pos=91    dur=...  （旧源）
    /// 另一源同作品      pos=766             （新源）
    /// ⇒ 换源后必须 = 766（单调不减）；若取 FROM 的会**倒退**成 91
    /// ```
    /// ★ 用户会因为"进度从 766 退到 91"而立刻发现 —— 这正是本任务要修的
    ///   那类"换源后记录不对"的症状。
    #[test]
    fn repoint_position_takes_max_when_to_is_larger_mushoku_case() {
        let db = Db::in_memory().unwrap();

        // FROM = 旧源，只看到 91 秒
        db.upsert_progress(&prog_ep("cycani:3862", "无职转生", 91, 1440, false, "第01集"))
            .unwrap();
        // TO = 新源，已经看到 766 秒（★ 刻意让 TO 更大）
        db.upsert_progress(&prog_ep("other:999", "无职转生", 766, 1440, false, "第01集"))
            .unwrap();

        db.repoint_item("cycani:3862", "other:999").unwrap();

        let p = db.get_progress("other:999").unwrap().expect("合并后必须有行");
        assert_eq!(
            p.position, 766,
            "★★★ position 取 **max(91,766)=766** —— \
             ★ 这是「取 max」与「取 FROM」的**唯一可区分样本**：\
             若取 FROM 的会得到 91 ⇒ 用户进度**倒退** 675 秒"
        );
        // ★ 反向：确认这个样本真的有分辨力（91 ≠ 766）
        assert_ne!(
            91, 766,
            "★ 仪器自检：两个数必须不同，否则本用例失去分辨力"
        );
        assert_eq!(db.list_all_progress().unwrap().len(), 1, "★ 不许出现两行");
    }

    /// ★★★ 集号**不匹配** ⇒ TO 行完全不动，FROM 行删掉（m00753 ⑦ 第二条）
    ///
    /// ```text
    /// 裁决原文：TO 有行 + 不匹配（集号不同 / 一侧 null）
    ///           ⇒ TO 行完全不动，FROM 行删掉
    ///             （= "只保留新源自己的记录"）
    /// ```
    /// ★ 真实形态：时光代理人那组（FROM='第08集' / TO='第01集'）。
    ///   若**携带**了，用户会看到"第08集的进度出现在第01集上" —— **错位**，
    ///   比从头开始更糟。
    #[test]
    fn repoint_does_not_carry_when_episode_numbers_differ() {
        let db = Db::in_memory().unwrap();

        // FROM 看到第 8 集 700 秒
        db.upsert_progress(&prog_ep("a:1", "时光代理人", 700, 1440, false, "第08集"))
            .unwrap();
        // TO 只看过第 1 集 30 秒
        db.upsert_progress(&prog_ep("b:2", "时光代理人", 30, 1440, false, "第01集"))
            .unwrap();

        db.repoint_item("a:1", "b:2").unwrap();

        let p = db.get_progress("b:2").unwrap().expect("TO 行必须还在");
        assert_eq!(
            p.position, 30,
            "★★★ 集号不同（8 vs 1）⇒ **不许携带** ⇒ TO 的 30 秒原样保留。\
             ⚠️ 若携带（取 max 得 700）⇒ 用户会在'第01集'上看到第08集的进度 ⇒ 错位"
        );
        assert_eq!(
            p.episode_title.as_deref(),
            Some("第01集"),
            "★ TO 行的 episode_title 不许被 FROM 覆盖"
        );
        assert!(db.get_progress("a:1").unwrap().is_none(), "★ FROM 行必须删掉");
        assert_eq!(db.list_all_progress().unwrap().len(), 1, "★ 只剩一条");
    }

    /// ★★ 集号：**只有一侧 null** ⇒ 不匹配（保守侧，m00753 ⑤）
    #[test]
    fn repoint_does_not_carry_when_only_one_side_has_episode_number() {
        let db = Db::in_memory().unwrap();
        db.upsert_progress(&prog_ep("a:1", "某片", 500, 1440, false, "正片"))
            .unwrap();
        db.upsert_progress(&prog_ep("b:2", "某片", 20, 1440, false, "第01集"))
            .unwrap();

        db.repoint_item("a:1", "b:2").unwrap();

        let p = db.get_progress("b:2").unwrap().unwrap();
        assert_eq!(
            p.position, 20,
            "★★ 一侧 null（'正片' 解析不出）⇒ 不匹配 ⇒ 取保守侧（不携带）。\
             ★ 若写成'都 null 才不匹配'，这里会错误地携带 500 秒"
        );
    }

    /// ★★ 集号：**两边都 null** ⇒ 视为匹配（单片，m00753 ⑤）
    #[test]
    fn repoint_carries_when_both_sides_have_no_episode_number() {
        let db = Db::in_memory().unwrap();
        db.upsert_progress(&prog_ep("a:1", "某电影", 500, 5400, false, "正片"))
            .unwrap();
        db.upsert_progress(&prog_ep("b:2", "某电影", 20, 5400, false, "原声版"))
            .unwrap();

        db.repoint_item("a:1", "b:2").unwrap();

        let p = db.get_progress("b:2").unwrap().unwrap();
        assert_eq!(
            p.position, 500,
            "★★ 两边都解析不出集号 ⇒ **视为匹配**（单片：position 是同一段视频的\
             时间偏移，携带有意义）⇒ 取 max(500,20)=500。\
             ★ 若判成不匹配，用户换源后单片进度会**每次丢光**"
        );
    }

    /// ★★★★ 匹配分支下 **`episode_title` 取 TO 的**（真回归锁，m01279 要求）
    ///
    /// ══════════════════════════════════════════════════════════════════
    /// ★ 为什么必须新增这一条：现有的匹配分支样本**全都分辨不出**
    ///   `..t` 与 `..f` 的区别
    /// ══════════════════════════════════════════════════════════════════
    ///
    /// ```text
    /// repoint_position_takes_max_when_to_is_larger_mushoku_case
    ///     两侧 episode_title **都是 "第01集"** ⇒ 同值 ⇒ 改 ..t→..f 看不出来
    /// repoint_does_not_carry_when_episode_numbers_differ
    ///     走 `else { t }` 分支 ⇒ 与 ..t 无关
    /// repoint_carries_whole_row_when_target_has_no_row
    ///     走 None 分支（用 `..f`，本来就是对的）
    /// repoint_carries_when_both_sides_have_no_episode_number
    ///     ★ 唯一的匹配分支异字符串样本（"正片" / "原声版"），
    ///       但它**只断言了 position** ⇒ 仍然分辨不出 episode_title
    /// ```
    ///
    /// ⇒ 本用例两侧集名**写法不同、语义相同**（都解析成 1 ⇒ 进匹配分支），
    ///   然后断言合并结果里的 `episode_title` 是 **TO 的 `'第1集'`**。
    ///   ★ 一旦把 `..t` 改成 `..f`，这条**立刻变红** —— 它才是真的回归锁。
    #[test]
    fn repoint_matched_arm_keeps_target_episode_title() {
        let db = Db::in_memory().unwrap();
        // ★ FROM 用 "第01集"、TO 用 "第1集" —— 字符串**不同**，
        //   但 episode_number_from_title 都得到 Some(1) ⇒ 进匹配分支。
        //   ★ 这正是**真实用户库**里的写法（cycani 写 "第01集"、
        //     hongniuzy2 写 "第1集"，见 .probe/dbcopy-t67c 的读数）。
        db.upsert_progress(&prog_ep("a:1", "某片", 100, 1440, false, "第01集"))
            .unwrap();
        db.upsert_progress(&prog_ep("b:2", "某片", 766, 1440, false, "第1集"))
            .unwrap();

        // ★ 仪器自检：两个集名字符串必须不同，否则本用例失去分辨力
        assert_ne!(
            "第01集", "第1集",
            "★ 仪器自检：两侧集名字符串必须不同"
        );
        // ★ 仪器自检：必须都解析成 Some(1)（否则走的是 else 分支，测不到 ..t）
        assert_eq!(episode_number_from_title(Some("第01集")), Some(1));
        assert_eq!(episode_number_from_title(Some("第1集")), Some(1));

        db.repoint_item("a:1", "b:2").unwrap();

        let p = db.get_progress("b:2").unwrap().unwrap();
        assert_eq!(
            p.episode_title.as_deref(),
            Some("第1集"),
            "★★★★ 匹配分支下 episode_title 必须取 **TO 的**（'第1集'）。\
             ★ 若得到 '第01集' ⇒ 合并臂退化成了 `..f`（取 FROM 的）—— \
             行现在属于新源，集名必须跟着行所属的源走。\
             ⚠️ 旧断言对此**零分辨力**：Progress 臂里本来就没有任何 \
             会命中的正则，`..t`→`..f` 改前改后都不命中（m01279 一节的量化）"
        );
        // ★ position 仍取 max（本样本 TO=766 > FROM=100）
        assert_eq!(p.position, 766, "★ position 取 max(100,766)=766");
        // ★ duration 也来自 TO（本样本两侧同值 1440 ⇒ 无分辨力，仅作存在性检查）
        assert_eq!(p.duration, 1440, "★ duration 来自 TO 的（本样本两侧同值）");
    }

    /// ★★★★ history 段的同构回归锁：匹配分支下 `episode_title` 取 TO 的
    ///
    /// ★ 为什么 progress 那条不够：history 是**另一条** `Some(t) =>` 臂、
    ///   另一份源码。只锁 progress 的话，history 臂被人改成 `..f` 仍然全绿。
    ///   （这正是 m01279 说的"该用例对 progress 段的合并语义零分辨力"的同型问题。）
    #[test]
    fn repoint_matched_arm_keeps_target_episode_title_in_history() {
        let db = Db::in_memory().unwrap();
        db.add_history(&hist_ep("a:1", 100, 5000, "第01集")).unwrap();
        db.add_history(&hist_ep("b:2", 766, 1000, "第1集")).unwrap();

        // ★ 仪器自检：与 progress 那条同款 —— 字符串不同、集号相同
        assert_eq!(episode_number_from_title(Some("第01集")), Some(1));
        assert_eq!(episode_number_from_title(Some("第1集")), Some(1));

        db.repoint_item("a:1", "b:2").unwrap();

        let h = db
            .list_history(100)
            .unwrap()
            .into_iter()
            .find(|h| h.key == "b:2")
            .expect("★ TO 行必须还在");
        assert_eq!(
            h.episode_title.as_deref(),
            Some("第1集"),
            "★★★★ history 匹配分支下 episode_title 必须取 TO 的 —— \
             若得到 '第01集' ⇒ HistoryEntry 臂退化成了 `..f`"
        );
        assert_eq!(h.position, 766, "★ history 的 position 也取 max(100,766)");
        assert_eq!(
            h.watched_at, 5000,
            "★ watched_at 取 max(5000,1000)=5000（history 特有列）"
        );
    }

    /// ★★★ TO **无行** ⇒ FROM 行**整行**搬到 TO 的 key（原值照搬，不重置为 0）
    ///
    /// m00753 ④：这是**最常见**的触发场景（用户因为当前源卡/坏而换源，
    /// 新源从没看过）。在那里重置为 0 ⇒ 每次换源都丢进度 ⇒ 功能反而有害。
    #[test]
    fn repoint_carries_whole_row_when_target_has_no_row() {
        let db = Db::in_memory().unwrap();
        db.upsert_progress(&prog_ep("a:1", "某片", 512, 1440, false, "第03集"))
            .unwrap();

        db.repoint_item("a:1", "b:2").unwrap();

        let p = db.get_progress("b:2").unwrap().expect("必须搬到新 key");
        assert_eq!(p.position, 512, "★★★ 原值照搬 —— 不许重置为 0");
        assert_eq!(p.duration, 1440, "★ duration 一并带过来");
        assert_eq!(p.episode_title.as_deref(), Some("第03集"), "★ 集名一并带过来");
        assert_eq!(p.title, "某片", "★ 标题一并带过来");
        assert!(db.get_progress("a:1").unwrap().is_none(), "★ 旧行删掉");
    }

    /// ★★★ 集号解析器必须与 Dart 侧**逐字一致**（读**同一张**夹具）
    ///
    /// # 夹具位置与两侧读法
    ///
    /// ```text
    /// 夹具：test/fixtures/episode_number_cases.json
    ///   Dart 侧：test/t67_episode_fixture_test.dart
    ///   Rust 侧：本测试
    /// ```
    /// ⚠️ ★ 路径必须是 `../../test/...`（**两个** `..`）——
    ///   `cargo test` 的 cwd 是**包根** `rust/sourin_core/`，
    ///   一个 `..` 会落到 `rust/` 下（那里没有 `test/`）。
    ///   实测：`rust/sourin_core/../test/fixtures/...` ⇒ **不存在**；
    ///         `rust/sourin_core/../../test/fixtures/...` ⇒ 存在。
    ///   失败信息里会打印 cwd，就是为了让这个错误一眼可诊断。
    /// ★ 夹具是**静态**的（不是 Dart 测试落盘生成）——
    ///   生成式夹具会**自愈**：Dart 解析器一旦漂移，测试就把漂移后的结果
    ///   写进夹具 ⇒ Dart 侧永远绿、只剩 Rust 侧变红，夹具再也说不清
    ///   "原本约定了什么"。静态夹具让两份实现都被同一个第三方钉住。
    #[test]
    fn episode_number_fixture_matches_dart() {
        let path = std::path::Path::new("../../test/fixtures/episode_number_cases.json");
        let raw = std::fs::read_to_string(path).unwrap_or_else(|e| {
            panic!(
                "★★★ 夹具读不到: {} （{e}）\n\
                 cwd = {:?}\n\
                 ★ 夹具是 Dart/Rust 两份集号实现的**唯一**共同契约，缺了它\
                 两侧会静默分歧",
                path.display(),
                std::env::current_dir()
            )
        });
        let v: serde_json::Value =
            serde_json::from_str(&raw).expect("夹具必须是合法 JSON");
        let cases = v["cases"].as_array().expect("夹具必须有 cases 数组");

        // ★ 仪器自检：夹具不许被删空（空夹具 ⇒ 断言空洞，永远绿）
        assert!(
            cases.len() >= 20,
            "★ 仪器自检：夹具只有 {} 条（应 ≥20）—— 空夹具会让本测试失去意义",
            cases.len()
        );

        let mut mismatches: Vec<String> = Vec::new();
        for c in cases {
            let input = c["input"].as_str();
            let expected = if c["expected"].is_null() {
                None
            } else {
                c["expected"].as_i64()
            };
            let actual = episode_number_from_title(input);
            if actual != expected {
                mismatches.push(format!(
                    "  input={:?}\n    Dart 夹具 = {:?}\n    Rust 实测 = {:?}",
                    input, expected, actual
                ));
            }
        }
        assert!(
            mismatches.is_empty(),
            "★★★ Rust 集号解析与 Dart 不一致（{} / {} 条）：\n{}\n\
             ★ 两份实现必须逐字等价 —— 否则换源时\"携不携带进度\"会静默分歧。\n\
             ★ 若**有意**改了集号语义，必须同时更新夹具 + 重跑 Dart 侧\
             （dart run .probe/t67t_ep_probe.dart）。",
            mismatches.len(),
            cases.len(),
            mismatches.join("\n")
        );
    }

    /// ★★★ `split_item_key` 必须容忍**双前缀**（生产数据里真实存在）
    ///
    /// # 实据
    ///
    /// `.probe/dbcopy-t67c` 里有这条 key：
    /// ```text
    /// bilibili:bilibili:av:BV1B8ZJYTEPg
    ///   ^^^^^^^^  ^^^^^^^^ ^^^^^^^^^^^^
    ///   provider  多余前缀  native_id 的真身
    /// ```
    /// ⇒ 按**第一个**冒号切 ⇒ native_id = `bilibili:av:BV1B8ZJYTEPg`（完整）。
    ///
    /// ⚠️ 若用 `split(':')` 取第二段 ⇒ native_id 变成 `bilibili`
    ///   ⇒ 换源迁移会把它**迁到错误的作品**上（静默、且不可逆）。
    /// ★ 这是 m00753 ② 点名要单独加的一条。
    #[test]
    fn split_item_key_keeps_double_prefixed_native_id_intact() {
        assert_eq!(
            split_item_key("bilibili:bilibili:av:BV1B8ZJYTEPg").unwrap(),
            (
                "bilibili".to_string(),
                "bilibili:av:BV1B8ZJYTEPg".to_string()
            ),
            "★★★ 双前缀行：provider 取第一段，native_id 必须是**剩下全部**。\
             截断成 'bilibili' 会把记录迁到错误作品上"
        );
        // ★ 与既有单前缀用例并存，证明两种形态都对
        assert_eq!(
            split_item_key("bilibili:av:BV1Bfex6tEEH").unwrap(),
            ("bilibili".to_string(), "av:BV1Bfex6tEEH".to_string()),
        );
    }

    /// ★★ skip_markers：**FROM 的非 null 优先，缺的用 TO 补**
    #[test]
    fn repoint_skip_markers_prefers_from_and_fills_from_to() {
        let db = Db::in_memory().unwrap();
        // FROM 只设了片头
        db.upsert_skip_marker(&SkipMarker {
            key: "360:86969".into(),
            provider: "360".into(),
            native_id: "86969".into(),
            title: "老舅".into(),
            intro_start: Some(5),
            intro_end: Some(95),
            outro_start: None,
            outro_end: None,
            auto_skip: None,
            updated_at: 100,
        })
        .unwrap();
        // TO 只设了片尾
        db.upsert_skip_marker(&SkipMarker {
            key: "caiji:74774".into(),
            provider: "caiji".into(),
            native_id: "74774".into(),
            title: "老舅".into(),
            intro_start: None,
            intro_end: None,
            outro_start: Some(2500),
            outro_end: Some(2700),
            auto_skip: Some(false),
            updated_at: 200,
        })
        .unwrap();

        db.repoint_item("360:86969", "caiji:74774").unwrap();

        let s = db.get_skip_marker("caiji:74774").unwrap().unwrap();
        assert_eq!(s.intro_start, Some(5), "★ FROM 有值 ⇒ 用 FROM 的");
        assert_eq!(s.intro_end, Some(95), "★ FROM 有值 ⇒ 用 FROM 的");
        assert_eq!(s.outro_start, Some(2500), "★ FROM 是 null ⇒ 用 TO 补");
        assert_eq!(s.outro_end, Some(2700), "★ FROM 是 null ⇒ 用 TO 补");
        assert_eq!(s.auto_skip, Some(false), "★ FROM 是 null ⇒ 用 TO 补");
        assert!(db.get_skip_marker("360:86969").unwrap().is_none(), "旧行必须删掉");
    }

    #[test]
    fn repoint_is_idempotent_and_noop_when_source_missing() {
        let db = Db::in_memory().unwrap();

        // ① from 四张表都没有 ⇒ 什么都不做，**不报错**
        db.repoint_item("ghost:1", "caiji:74774")
            .expect("from 不存在时必须成功（空操作），不许报错");
        assert_eq!(db.list_favorites(true).unwrap().len(), 0);

        // ② from == to ⇒ 空操作（不删自己）
        db.upsert_progress(&prog_full("caiji:74774", "老舅", 300, 2700, false))
            .unwrap();
        db.repoint_item("caiji:74774", "caiji:74774").unwrap();
        assert_eq!(
            db.list_all_progress().unwrap().len(),
            1,
            "★ from == to 必须原样保留（若写成'先删后写'会把唯一那行删掉）"
        );

        // ③ 非法 key ⇒ 报错（不 panic）
        assert!(db.repoint_item("nocolon", "caiji:74774").is_err());
        assert!(db.repoint_item("caiji:74774", "nocolon").is_err());
    }

    /// ★★ 合并后**不许**留下墓碑 —— 否则备份导出会把同一部作品数成两条
    #[test]
    fn repoint_leaves_no_tombstone_in_favorites() {
        let db = Db::in_memory().unwrap();
        db.upsert_favorite(&fav_full("360:86969", true, true, 0, 100, 200))
            .unwrap();
        db.repoint_item("360:86969", "caiji:74774").unwrap();

        // include_deleted=true 是**备份导出**用的口径
        let all = db.list_favorites(true).unwrap();
        assert_eq!(
            all.len(),
            1,
            "★★ 备份口径下也**只能有一条** —— 留墓碑会让备份里出现重复，\
             与'合并'目标自相矛盾"
        );
        assert!(!all[0].deleted, "合并后的行必须是活行");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  ★★★ 真实数据实测（默认 #[ignore]，需显式 --ignored 才跑）
    // ═══════════════════════════════════════════════════════════════════

    /// 在**用户真实数据的只读副本**上跑一次真实换源
    ///
    /// # 为什么 `#[ignore]`
    ///
    /// 它依赖 `.probe/dbcopy-t67c/`（含 WAL 的一致性快照）。
    /// 那个目录是**取证件**，不该成为单测的硬依赖 ——
    /// 缺了它会让 `cargo test --release --lib` 基线**变红**，
    /// 而基线是全队的判据。⇒ 默认跳过，显式 `--ignored` 才跑。
    ///
    /// # ★★ 基准为什么是 `t67c` 而不是 `t67` / `t67b`
    ///
    /// `.probe/dbcopy-t67/` 手工复制时**漏了 `-wal`/`-shm`** ⇒ 陈旧快照
    /// （16 行 vs 活库 27 行，少 11 行）。Lead 曾拿它当基准，已纠正。
    /// 手工复制 db+wal+shm 在写入进行中还会拿到**撕裂**快照。
    /// ⇒ 唯一有效基准是 **`t67c`**（SQLite backup API + 源库 `mode=ro` 取的）。
    /// 旧那份留着但标注"无效基准"，别删。
    ///
    /// # 跑法
    ///
    /// ```powershell
    /// cargo test --release --lib real_user_data_repoint -- --ignored --nocapture
    /// ```
    ///
    /// # ★ 为什么必须在**副本**上跑
    ///
    /// 用户真实库 `%APPDATA%\app.sourin.player\` **绝不能碰**
    /// （本仓铁律；而且它此刻正被运行中的客户端持有）。
    /// 快照由 `.probe/t67e_live_snapshot.py` 用 SQLite backup API 取，
    /// 源库以 `mode=ro` 只读打开。
    ///
    /// # ★★ 这条测的正是《老舅》那个真实形态
    ///
    /// ```text
    /// 360:86969     pos=4    dur=2777   （旧源）
    /// caiji:74774   pos=1    dur=2759   （新源，★ TO 行**已存在**）
    /// ⇒ 换源后：两条变一条、且指向 caiji
    /// ```
    #[test]
    #[ignore = "依赖 .probe/dbcopy-t67c/ 取证件；用 --ignored 显式跑"]
    fn real_user_data_repoint_laojiu() {
        let snap = std::path::Path::new(
            r"D:\WishProject\sourin-flutter-spike\.probe\dbcopy-t67c\dsh-media.db",
        );
        if !snap.exists() {
            eprintln!("[SKIP] 快照不存在: {}", snap.display());
            return;
        }

        // ★ 在**临时副本**上跑 —— 绝不改动取证件本身
        let tmp = std::env::temp_dir().join(format!(
            "t67_e2e_{}_{}.db",
            std::process::id(),
            chrono::Utc::now().timestamp_millis()
        ));
        let _ = std::fs::remove_file(&tmp);
        std::fs::copy(snap, &tmp).expect("复制快照失败");

        let db = Db::open(&tmp).unwrap();

        // ── 前置：确认快照里确实是那两条 ──
        let before: Vec<Progress> = db
            .list_all_progress()
            .unwrap()
            .into_iter()
            .filter(|p| p.title == "老舅")
            .collect();
        assert_eq!(
            before.len(),
            3,
            "前置：t67c 里《老舅》必须是 **3** 条（360:86969 + caiji:74774 + caiji-2:74774）—— \
             ⚠️ 无效基准 t67 里只有 2 条，若这里变成 2 说明快照又用错了"
        );
        let from = before.iter().find(|p| p.key == "360:86969").expect("360 行");
        let to = before.iter().find(|p| p.key == "caiji:74774").expect("caiji 行");
        eprintln!(
            "[E2E] 迁移前: 360:86969 pos={} dur={} | caiji:74774 pos={} dur={}",
            from.position, from.duration, to.position, to.duration
        );
        /*
         * ★ 仪器自检：两侧 duration 必须**不同**，否则下面那条
         *   「duration 取 TO 的」断言**失去分辨力**（两条规则同值 ⇒ 假证据）。
         *   实测 t67c：FROM.duration=2777 / TO.duration=2759 ⇒ 可分辨。
         */
        assert_ne!(
            from.duration, to.duration,
            "★ 仪器自检：两侧 duration 必须不同（FROM={} TO={}），\
             否则「duration 取 TO 的」这条断言无法分辨",
            from.duration, to.duration
        );
        // ★ 前置：favorites 里只有 caiji 那条（360 没有 favorites 行）
        let fav_before = db.list_favorites(true).unwrap();
        assert!(
            fav_before.iter().any(|f| f.key == "caiji:74774"),
            "前置：favorites 里必须有 caiji:74774"
        );
        assert!(
            !fav_before.iter().any(|f| f.key == "360:86969"),
            "前置：360:86969 本来不在 favorites 里"
        );

        // ── ★ 执行真实迁移（生产代码路径）──
        db.repoint_item("360:86969", "caiji:74774").unwrap();

        // ── 后置 ①：progress 里《老舅》**只剩一条**，且指向 caiji ──
        let after: Vec<Progress> = db
            .list_all_progress()
            .unwrap()
            .into_iter()
            .filter(|p| p.title == "老舅")
            .collect();
        assert_eq!(
            after.len(),
            2,
            "★★★ 迁移后《老舅》剩 **2** 条（caiji:74774 合并后仍在 + caiji-2:74774 未被碰）—— \
             360:86969 必须消失、caiji:74774 必须留下，两条并一条"
        );
        let a = after
            .iter()
            .find(|p| p.key == "caiji:74774")
            .expect("★ 合并后的 caiji:74774 行必须在");
        assert_eq!(a.key, "caiji:74774", "★ 合并目标必须指向**新源**");
        assert_eq!(a.provider, "caiji");
        assert_eq!(a.native_id, "74774");
        eprintln!(
            "[E2E] 迁移后: key={} pos={} dur={} title={:?}",
            a.key, a.position, a.duration, a.title
        );
        /*
         * ★★ m00753 ③④⑦：TO 有行 + 集号匹配（两侧都是 '第01集' ⇒ 1 == 1）
         *    ⇒ 保留 TO 那一行，只把 position 覆盖为 max(FROM, TO)。
         *
         * ⚠️ 本组的**分辨力有限**，如实记录：
         *    FROM.position=4 / TO.position=1 ⇒ max = 4 = **恰好等于** from.position
         *    ⇒ 这条断言只能分辨「取 max」vs「取 TO 的」，**不能**分辨
         *      「取 max」vs「取 FROM 的」—— 数学上 max 不可能同时不等于两个操作数。
         *    ⇒ 「取 max」vs「取 FROM 的」由下面的**无职转生**那组分辨
         *      （FROM=91 / TO=766 ⇒ max=766 ≠ 91）。
         */
        assert_eq!(
            a.position,
            from.position.max(to.position),
            "★★ position 必须取 **max(FROM={}, TO={})={}**（m00753 ③）—— \
             单调不减，绝不丢进度",
            from.position,
            to.position,
            from.position.max(to.position)
        );
        // ★ 反向断言：不许取 TO 的（若取 TO 的这里会得到 1）
        assert_ne!(
            a.position, to.position,
            "★★ 不许取 **TO 的** position（{}）—— 那会让用户进度倒退",
            to.position
        );
        /*
         * ★★ m00753 ⑦：TO 有行 + 匹配 ⇒ 除 position 外**其余列保持 TO 的**。
         *    本组 FROM.duration=2777 ≠ TO.duration=2759 ⇒ **有分辨力**
         *    （上面的 assert_ne! 仪器自检已确认两者不同）。
         */
        assert_eq!(
            a.duration, to.duration,
            "★★★ duration 必须取 **TO** 的（{}）—— 行现在属于新源，\
             duration 应反映新源（FROM 的是 {}）",
            to.duration, from.duration
        );
        assert_ne!(
            from.duration, to.duration,
            "★ 仪器自检：两侧 duration 必须不同，否则上一条断言无分辨力"
        );

        // ── 后置 ②：旧 key 在**四张表**里都不存在了 ──
        assert!(db.get_progress("360:86969").unwrap().is_none(), "旧 progress 行必须没了");
        assert!(db.get_favorite("360:86969").unwrap().is_none(), "旧 favorites 行必须没了");
        assert!(
            !db.list_history(100_000)
                .unwrap()
                .iter()
                .any(|h| h.key == "360:86969"),
            "旧 history 行必须没了"
        );
        assert!(
            db.get_skip_marker("360:86969").unwrap().is_none(),
            "旧 skip_markers 行必须没了"
        );

        // ── 后置 ③：history 里《老舅》也剩 2 条（同一套三态语义）──
        let hist: Vec<_> = db
            .list_history(100_000)
            .unwrap()
            .into_iter()
            .filter(|h| h.title == "老舅")
            .collect();
        assert_eq!(
            hist.len(),
            2,
            "★★ history 里《老舅》剩 2 条（caiji:74774 + caiji-2:74774）—— \
             ★ progress 与 history 必须**同一套语义**，否则同一作品两表各说各话"
        );
        let h = hist
            .iter()
            .find(|h| h.key == "caiji:74774")
            .expect("★ 合并后的 caiji:74774 history 行必须在");
        assert_eq!(
            h.position,
            from.position.max(to.position),
            "★★ history 的 position 同样取 **max**（m00753 ③）"
        );
        assert_eq!(
            h.duration, to.duration,
            "★★ history 的 duration 同样取 **TO** 的（m00753 ⑦）"
        );

        // ── 后置 ④：favorites 那条仍在（OR 合并：本来就有的不能丢）──
        let fav_after = db.list_favorites(true).unwrap();
        let hit = fav_after
            .iter()
            .find(|f| f.key == "caiji:74774")
            .expect("★★ caiji:74774 的收藏行必须还在（不能因为迁移把它弄丢）");
        assert!(hit.favorited, "★ 原本 favorited=1 ⇒ 合并后仍为真");
        assert_eq!(
            fav_after.iter().filter(|f| f.title == "老舅").count(),
            1,
            "★★ favorites 里《老舅》只能一条（caiji-2:74774 本来就没有 favorites 行）"
        );

        // ── 后置 ⑤：★ 全表行数守恒（27 行 → 26 行，不是 27 也不是 25）──
        let n_prog = db.list_all_progress().unwrap().len();
        eprintln!("[E2E] progress 总行数 = {n_prog}（迁移前 27）");
        assert_eq!(
            n_prog, 26,
            "★★★ 迁移后 progress 必须**少一行**（27 → 26）—— \
             360:86969 并进已存在的 caiji:74774，且旧行已删"
        );

        // ═══════════════════════════════════════════════════════════════
        //  ★★★★ m00753 ③ 的**唯一可区分锚点**：无职转生那组
        //
        //  FROM = cycani:3862        pos=91   dur=1420  ep='第01集' ⇒ 集号 1
        //  TO   = hongniuzy2:150722  pos=766  dur=1420  ep='第1集'  ⇒ 集号 1
        //  ⇒ 集号**匹配** ⇒ position = max(91, 766) = **766**
        //
        //  ★ 为什么必须用它：老舅那组 FROM=4 > TO=1 ⇒ max 恰好等于 FROM，
        //    分辨不出「取 max」与「取 FROM 的」。只有**本组** FROM < TO，
        //    两条规则给出**不同**答案（91 vs 766）⇒ 有分辨力。
        //    ⚠️ 若这里得到 91，说明实现退化回 m00370 的"取 FROM"。
        // ═══════════════════════════════════════════════════════════════
        let m_from_key = "cycani:3862";
        let m_to_key = "hongniuzy2:150722";

        let m_before: Vec<Progress> = db
            .list_all_progress()
            .unwrap()
            .into_iter()
            .filter(|p| p.key == m_from_key || p.key == m_to_key)
            .collect();
        assert_eq!(m_before.len(), 2, "前置：无职转生那组必须两条都在");
        let mf = m_before.iter().find(|p| p.key == m_from_key).expect("cycani 行");
        let mt = m_before.iter().find(|p| p.key == m_to_key).expect("hongniuzy2 行");
        eprintln!(
            "[E2E] 无职转生 改前: cycani:3862 pos={} dur={} ep={:?} | \
             hongniuzy2:150722 pos={} dur={} ep={:?}",
            mf.position, mf.duration, mf.episode_title, mt.position, mt.duration, mt.episode_title
        );
        // ★ 仪器自检：两个 position 必须**不同**，且 FROM < TO —— 否则失去分辨力
        assert_ne!(
            mf.position, mt.position,
            "★ 仪器自检：无职转生那组两侧 position 必须不同（FROM={} TO={}）",
            mf.position, mt.position
        );
        assert!(
            mf.position < mt.position,
            "★★ 仪器自检：必须 FROM < TO（FROM={} TO={}）—— \
             只有这个方向才能分辨「取 max」与「取 FROM 的」；\
             若反向，两条规则同值 ⇒ 本用例失去分辨力",
            mf.position, mt.position
        );
        // ★ 仪器自检：两侧集号必须都解析成 1（否则走的不是"匹配"分支）
        assert_eq!(
            episode_number_from_title(mf.episode_title.as_deref()),
            Some(1),
            "★ 仪器自检：FROM 的集名 {:?} 必须解析成 1",
            mf.episode_title
        );
        assert_eq!(
            episode_number_from_title(mt.episode_title.as_deref()),
            Some(1),
            "★ 仪器自检：TO 的集名 {:?} 必须解析成 1（'第1集' 没有前导零）",
            mt.episode_title
        );
        // ★ 前置：favorites 与 skip_markers 里只有 FROM 侧（TO 侧无行）
        let m_fav_before = db.list_favorites(true).unwrap();
        assert!(
            m_fav_before.iter().any(|f| f.key == m_from_key),
            "前置：favorites 里必须有 cycani:3862（following=1 那行）"
        );
        assert!(
            !m_fav_before.iter().any(|f| f.key == m_to_key),
            "前置：favorites 里**没有** hongniuzy2:150722 ⇒ 走「整行搬过去」分支"
        );
        assert!(
            db.get_skip_marker(m_from_key).unwrap().is_some(),
            "前置：skip_markers 里必须有 cycani:3862"
        );
        assert!(
            db.get_skip_marker(m_to_key).unwrap().is_none(),
            "前置：skip_markers 里**没有** hongniuzy2:150722 ⇒ 整行搬过去"
        );

        // ── ★ 执行第二组真实迁移 ──
        db.repoint_item(m_from_key, m_to_key).unwrap();

        // ── 后置 ⑥：★ 无职转生 position 91 → **766**（唯一可区分锚点）──
        let m_after = db
            .get_progress(m_to_key)
            .unwrap()
            .expect("★ hongniuzy2:150722 的行必须在");
        eprintln!(
            "[E2E] 无职转生 改后: {} pos={} dur={} ep={:?}",
            m_after.key, m_after.position, m_after.duration, m_after.episode_title
        );
        assert_eq!(
            m_after.position, 766,
            "★★★★ 无职转生：position 必须 = max(91, 766) = **766** —— \
             ⚠️ 若得到 91，说明实现退化回 m00370 的「取 FROM 的」\
             （用户进度倒退 675 秒）。这是全库**唯一**能分辨两条规则的样本。\
             改前={} 改后={}",
            mf.position, m_after.position
        );
        assert_eq!(m_after.position, mf.position.max(mt.position), "★ 同上，用 max 表达式复核");
        assert_ne!(
            m_after.position, mf.position,
            "★★ 反向断言：不许等于 FROM 的 91 —— 那正是被取代的旧规则"
        );
        // ★ 其余列保持 TO 的（本组两侧 duration 都是 1420，**无分辨力**，如实记录）
        assert_eq!(m_after.duration, mt.duration, "★ duration 取 TO 的（本组两侧同值 1420，无分辨力）");
        assert_eq!(
            m_after.episode_title, mt.episode_title,
            "★★ episode_title 必须保持 **TO** 的（'第1集'）—— 行属于新源"
        );
        // ★★ `updated_at` 取 **TO 的**，不是 max —— m00753 ⑦ 明确列了
        //    「其余列（duration / episode_title / updated_at）保持 TO 的」。
        //    ★ 本组两侧 updated_at 恰好**不同**（TO=1790593398542 <
        //      FROM=1790657967225）⇒ 这条断言**有分辨力**：
        //      取 max 会得到 1790657967225 ⇒ 立刻变红。
        //      （我第一版这里写成了 `max`，E2E 当场抓出来了 —— 见下面的自检。）
        assert_ne!(
            mf.updated_at, mt.updated_at,
            "★ 仪器自检：两侧 updated_at 必须不同，否则本断言失去分辨力"
        );
        assert_eq!(
            m_after.updated_at, mt.updated_at,
            "★★ progress 的 updated_at 取 **TO 的**（m00753 ⑦：其余列保持 TO 的）—— \
             行现在属于新源，时间戳由新源后续的周期性保存自然刷新。\
             ⚠️ 若得到 {}（= max）说明写成了 `max`",
            mt.updated_at.max(mf.updated_at)
        );
        // ★ 旧行必须消失
        assert!(
            db.get_progress(m_from_key).unwrap().is_none(),
            "★★ cycani:3862 的 progress 行必须被删（不丢进度也不能留重影）"
        );

        // ── 后置 ⑦：history 同步（同一套三态）──
        let m_hist: Vec<_> = db
            .list_history(100_000)
            .unwrap()
            .into_iter()
            .filter(|h| h.key == m_from_key || h.key == m_to_key)
            .collect();
        assert_eq!(
            m_hist.len(),
            1,
            "★★ history 里无职转生那组也必须只剩 **一条**（两条并一条）"
        );
        assert_eq!(m_hist[0].key, m_to_key);
        assert_eq!(
            m_hist[0].position, 766,
            "★★★★ history 的 position 同样必须 = **766**（与 progress 一致）"
        );
        assert_eq!(
            m_hist[0].episode_title, mt.episode_title,
            "★★ history 的 episode_title 同样保持 TO 的"
        );

        // ── 后置 ⑧：favorites 的 cycani:3862 行**整行搬**到 hongniuzy2:150722 ──
        let m_fav_after = db.list_favorites(true).unwrap();
        assert!(
            m_fav_after.iter().all(|f| f.key != m_from_key),
            "★★ favorites 里 cycani:3862 必须没了"
        );
        let m_fav_new = m_fav_after
            .iter()
            .find(|f| f.key == m_to_key)
            .expect("★★★ favorites 里必须出现 hongniuzy2:150722（TO 无行 ⇒ 整行搬）");
        assert!(
            m_fav_new.following,
            "★★ following=1 必须带过来（追更标记不能丢）—— 这正是本任务报的症状之一"
        );
        assert_eq!(
            m_fav_new.unread_count, 1,
            "★ unread_count=1 必须带过来"
        );
        assert_eq!(
            m_fav_new.last_episode_count, 14,
            "★ last_episode_count=14 必须带过来"
        );
        assert_eq!(
            m_fav_new.last_episode_title.as_deref(),
            Some("第14集"),
            "★ last_episode_title 必须带过来"
        );
        assert!(
            !m_fav_new.favorited,
            "★ 原本 favorited=0 ⇒ 搬过来仍是 0（TO 无行，没有 OR 对象）"
        );

        // ── 后置 ⑨：skip_markers 的 cycani:3862 行整行搬到 hongniuzy2:150722 ──
        assert!(
            db.get_skip_marker(m_from_key).unwrap().is_none(),
            "★★ skip_markers 里 cycani:3862 必须没了"
        );
        let m_skip = db
            .get_skip_marker(m_to_key)
            .unwrap()
            .expect("★★★ skip_markers 里必须出现 hongniuzy2:150722（TO 无行 ⇒ 整行搬）");
        assert_eq!(m_skip.intro_end, Some(69), "★ intro_end=69 必须带过来");
        assert_eq!(m_skip.intro_start, Some(0), "★ intro_start=0 必须带过来");

        // ═══════════════════════════════════════════════════════════════
        //  ★★ m00753 ②：双前缀坏行必须**完整保留** native_id
        //
        //  t67c 里 `bilibili:bilibili:av:BV1B8ZJYTEPg` 与
        //  `bilibili:av:BV1B8ZJYTEPg` **并存**（前者是生产数据里已有的坏行）。
        //  `split_item_key` 用 `split_once(':')` ⇒
        //      provider='bilibili', native_id='bilibili:av:BV1B8ZJYTEPg'
        //  ★ 若用 `split(':')` 取第二段，native_id 会被截成 'bilibili'
        //    ⇒ 迁到**错误作品**。
        // ═══════════════════════════════════════════════════════════════
        let dbl = "bilibili:bilibili:av:BV1B8ZJYTEPg";
        let single = "bilibili:av:BV1B8ZJYTEPg";
        let dbl_row = db
            .get_progress(dbl)
            .unwrap()
            .expect("★★ 前置：t67c 里必须存在双前缀那条 progress 行");
        assert_eq!(
            dbl_row.native_id, "bilibili:av:BV1B8ZJYTEPg",
            "★★★ 双前缀行的 native_id 必须**完整**（含内层 'bilibili:'）—— \
             截断成 'bilibili' 会把它迁到错误作品"
        );
        assert_eq!(dbl_row.provider, "bilibili", "★ provider 仍是第一段");
        assert_eq!(dbl_row.position, 15, "★ 双前缀行 pos=15（对照单前缀行 pos=6）");
        let single_row = db
            .get_progress(single)
            .unwrap()
            .expect("★ 前置：t67c 里必须存在单前缀那条 progress 行");
        assert_eq!(single_row.native_id, "av:BV1B8ZJYTEPg", "★ 单前缀行 native_id='av:BV1B8ZJYTEPg'");
        assert_eq!(single_row.position, 6, "★ 单前缀行 pos=6");
        assert_ne!(
            dbl_row.position, single_row.position,
            "★ 仪器自检：两条 position 必须不同（15 vs 6），否则无法分辨它们是否被混淆"
        );
        /*
         * ★ 两者 provider **相同**（都是 'bilibili'）⇒
         *   `commands_write::repoint_item` 的 `from_provider == to_provider`
         *   守卫会**正确拦住** —— 它们不该被迁移（同一源内的 id 漂移）。
         *   这里直接调 `Db::repoint_item`（无守卫），所以只验证
         *   `split_item_key` 的解析结果，不验证守卫（守卫由 Dart 契约测试覆盖）。
         */
        let (dp, dn) = split_item_key(dbl).unwrap();
        assert_eq!(
            (dp.as_str(), dn.as_str()),
            ("bilibili", "bilibili:av:BV1B8ZJYTEPg"),
            "★★★ split_item_key 必须用 split_once：双前缀 ⇒ native_id 完整不丢"
        );

        drop(db);
        let _ = std::fs::remove_file(&tmp);
        eprintln!("[E2E] ✓ 真实数据实测通过（副本已删，用户库未被碰）");
    }
}
