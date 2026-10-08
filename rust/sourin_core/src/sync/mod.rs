//! 同步引擎 —— 把「两个平面」落到实处
//!
//! # 两个平面（Owner 确认的边界，勿混）
//!
//! | 平面 | 数据 | 方向 | 冲突策略 |
//! |---|---|---|---|
//! | **独立平面** | 我们的收藏 + 追更 + 进度 | 多设备**双向** | LWW（`updated_at`）+ 墓碑 |
//! | **备份平面** | 第三方站点自带的历史 | 平台 → 云盘**单向镜像** | 按平台时间戳覆盖 |
//!
//! 混在一起会互相打架：平台改了历史 vs 本地改了进度，谁是真相？
//! 分开后各自简单。
//!
//! # 远端布局
//!
//! ```text
//! {webdav_root}/
//! ├─ manifest.json                      # 索引：schema 版本 / 最后同步时间 / 设备
//! ├─ data/
//! │  ├─ favorites.jsonl                 # 独立平面：收藏 + 追更
//! │  └─ progress.jsonl                  # 独立平面：进度
//! └─ backup/
//!    └─ {provider}/history-{device}.jsonl   # 备份平面：按设备分文件
//! ```
//!
//! **为什么收藏/进度用「整文件覆盖」而不是追加**：
//! 我们要的是 LWW 合并结果，追加会让文件无限增长且要每次全读。
//! 单文件 + ETag 乐观锁在数据量（几百条）下完全够用，
//! 且「读-合并-写」的语义清晰。JSONL 只是便于人工查看/增量解析。

use crate::store::{Db, Favorite, Normalize, Progress};
use crate::sync::webdav::{SyncBackend, WebdavBackend};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

pub mod webdav;

/*
 * ★ 把 WebdavConfig 以 `pub use` 引入（2026-09-22）
 *
 * 原本写的是 `use ...::{..., WebdavConfig}` —— 那是**私有导入**，
 * 模块外写 `crate::sync::WebdavConfig` 会报
 * "struct import `WebdavConfig` is private"。
 *
 * 命令层的 `configure_webdav` 需要构造它，所以必须对外可见。
 *
 * ⚠️ 注意**不能**既 `use` 又 `pub use` 同一个名字 ——
 *    会报 `E0252: the name is defined multiple times`。
 *    正确做法是把那一项从私有 use 里**移出来**，只留这条 pub use。
 *    （`pub use` 本身也把名字引入了当前作用域，内部照常能用。）
 */
pub use crate::sync::webdav::WebdavConfig;

/// 远端目录条目（`list()` 的返回元素）—— 命令层要构造它的 JSON，故对外可见
pub use crate::sync::webdav::RemoteEntry;

/// 云盘凭据：与登录令牌同策略，走系统钥匙串，**不落库、不进导出**
pub mod webdav_credential {
    /// keyring 服务名
    ///
    /// ⚠️ **不要跟着应用改名一起改** —— 见 `proxy.rs` 里
    /// `KEYRING_SERVICE` 上方的详细说明。
    /// 改了会让用户已保存的 WebDAV 密码读不到。
    const SERVICE: &str = "dsh-media-client-sync";

    fn entry(key: &str) -> Result<keyring::Entry, String> {
        keyring::Entry::new(SERVICE, key).map_err(|e| format!("钥匙串不可用: {e}"))
    }

    /// 写入并回传（便于调用方立即使用，避免再读一次）
    pub fn set(key: &str, password: &str) -> Result<String, String> {
        let e = entry(key)?;
        if password.is_empty() {
            let _ = e.delete_credential();
            return Ok(String::new());
        }
        e.set_password(password)
            .map_err(|err| format!("写入钥匙串失败: {err}"))?;
        Ok(password.to_string())
    }

    pub fn get(key: &str) -> Option<String> {
        entry(key).ok()?.get_password().ok()
    }

    pub fn clear(key: &str) -> Result<(), String> {
        let e = entry(key)?;
        let _ = e.delete_credential();
        Ok(())
    }
}

// ═══════════════════════ 云盘同步设置（持久化）═══════════════════════

/// 设置文件名（在 `$data_dir` 下）
pub const SYNC_SETTINGS_FILE: &str = "sync-settings.json";

/// ★ 整体备份快照在**远端**的目录（契约 §5）
///
/// 用子目录而不是 `backup/` 根：根下已有 `backup/{provider}/history-*.jsonl`，
/// 混在一起会让「列出备份」把平台历史也列出来。
pub const SNAPSHOT_DIR: &str = "backup/snapshots";

/// 备份文件名前缀 —— 保留清理的**安全护栏**：只删我们自己写的文件
pub const SNAPSHOT_PREFIX: &str = "dsh-backup-";
/// 备份文件名后缀（同样是护栏的一部分）
pub const SNAPSHOT_SUFFIX: &str = ".zip";

/// ★ 云盘同步的设置 —— **持久化在磁盘上**（2026-09-29，task-75）
///
/// # 为什么必须落盘（修的是一个硬阻塞）
///
/// 改之前 `WebdavConfig` **只在内存**里（`state.rs` 的
/// `sync: RwLock::new(None)`），于是：
/// ```text
/// 用户配好云盘 → 能用
/// 重启        → sync_status() 必然 connected:false
///             ⇒ 每次开机都要重新配一遍，自动备份根本无从谈起
/// ```
///
/// # 字段命名：文件里是 camelCase
///
/// Dart 侧直接读这份 JSON（`sync_settings_get`），所以**两边的名字必须一致**。
/// `#[serde(rename_all = "camelCase")]` 让 Rust 侧照常写 snake_case，
/// 存盘/出参自动变成 `baseUrl` / `retainCount` / `autoEnabled` …
///
/// # `#[serde(default)]`（容器级）是**容错**的关键
///
/// 它让「字段缺失」回退到 [`Default`] 而不是解析失败。契约 §3.1 要求
/// `sync_settings_get` **永不失败** —— 用户可能有一个上个版本写的、
/// 只有一半字段的文件，或者手改坏了。缺字段给默认值，坏 JSON 也给默认值。
///
/// ⚠️ **密码绝不写进这个文件** —— 它仍只在系统钥匙串
///    （服务名 `dsh-media-client-sync`，键 `webdav`）。
///    这个文件是明文 JSON，用户可能同步到网盘/发给人看。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", default)]
pub struct SyncSettings {
    /// WebDAV 基址（连接字段）
    pub base_url: String,
    /// 账号（连接字段）
    pub username: String,
    /// 远端目录（连接字段）
    pub remote_dir: String,
    /// 云端最多保留几份整体备份（默认 10）—— **偏好字段**
    pub retain_count: u32,
    /// 自动同步**总开关**（默认 false）—— **偏好字段**
    pub auto_enabled: bool,
    /// 增量同步节奏：多久看一眼云端（分钟，默认 30）—— **偏好字段**
    pub auto_interval_minutes: u32,
    /// 数据变动就同步（默认 true）—— **偏好字段**
    pub auto_on_change: bool,
    /// ★ 整体备份节奏（分钟，默认 1440 = 1 天，**0 = 关**）—— **偏好字段**
    ///
    /// 与 `auto_interval_minutes` **刻意分开**：增量同步传的是几 KB 的
    /// JSONL，整体备份传的是整包 zip。用同一个间隔会让用户开自动同步后
    /// 每 30 分钟整包上传一次 —— 正是 Owner 说的「耗流量」。
    /// 阅读 App（Legado）也是这么分的：进度 5 分钟 debounce，zip 24 小时一次。
    pub auto_backup_interval_minutes: u32,
    /// 上次整体备份时间（毫秒）—— 内部水位
    pub last_backup_at: i64,
    /// 上次增量同步时间（毫秒）—— 内部水位
    pub last_sync_at: i64,
    /// 上次同步时的本地数据签名 —— 内部字段，**不出现在 `sync_settings_get` 里**
    pub last_signature: String,
    /// 上次备份时的本地数据签名 —— 内部字段，**不出现**在返回里
    pub last_backup_signature: String,
}

impl Default for SyncSettings {
    fn default() -> Self {
        Self {
            base_url: String::new(),
            username: String::new(),
            remote_dir: String::new(),
            retain_count: 10,
            auto_enabled: false,
            auto_interval_minutes: 30,
            auto_on_change: true,
            auto_backup_interval_minutes: 1440,
            last_backup_at: 0,
            last_sync_at: 0,
            last_signature: String::new(),
            last_backup_signature: String::new(),
        }
    }
}

impl SyncSettings {
    /// ★ 给 Dart 侧看的 JSON（契约 §2 的字段表）
    ///
    /// ⚠️ **刻意不含** `lastSignature` / `lastBackupSignature` ——
    ///    那是我们内部的判据（数据指纹），对 UI 无意义，
    ///    露出去反而容易被误当成"状态"去显示。
    pub fn to_public_json(&self, connected: bool) -> serde_json::Value {
        serde_json::json!({
            "connected": connected,
            "baseUrl": self.base_url.clone(),
            "username": self.username.clone(),
            "remoteDir": self.remote_dir.clone(),
            "retainCount": self.retain_count,
            "autoEnabled": self.auto_enabled,
            "autoIntervalMinutes": self.auto_interval_minutes,
            "autoOnChange": self.auto_on_change,
            "autoBackupIntervalMinutes": self.auto_backup_interval_minutes,
            "lastBackupAt": self.last_backup_at,
            "lastSyncAt": self.last_sync_at,
        })
    }
}

/// 读设置 —— ★ **永不失败**（契约 §3.1）
///
/// 文件不存在 / JSON 坏 / 字段缺 ⇒ 一律回退默认值。
/// 理由：Dart 侧**首次进设置页就会调它**（比用户配云盘早得多），
/// 它一报错 UI 就得走降级分支。
pub fn load_settings(data_dir: &std::path::Path) -> SyncSettings {
    let path = data_dir.join(SYNC_SETTINGS_FILE);
    let Ok(text) = std::fs::read_to_string(&path) else {
        // 首次使用：文件还不存在，这**不是**错误
        return SyncSettings::default();
    };
    match serde_json::from_str::<SyncSettings>(&text) {
        Ok(s) => s,
        Err(e) => {
            log::warn!("sync-settings.json 解析失败（已回退默认值，不影响其它功能）: {e}");
            SyncSettings::default()
        }
    }
}

/// 写设置（只有真正写盘失败才返回 `Err`）
pub fn save_settings(data_dir: &std::path::Path, s: &SyncSettings) -> Result<(), String> {
    let path = data_dir.join(SYNC_SETTINGS_FILE);
    let body = serde_json::to_vec_pretty(s).map_err(|e| format!("序列化设置失败: {e}"))?;
    std::fs::write(&path, &body).map_err(|e| format!("写入 {} 失败: {e}", path.display()))
}

/// ★ 本地数据签名 —— 「有数据变动就保存」的判据（契约 §6）
///
/// ```text
/// favorites: 条数 + max(updated_at)
/// following: 同
/// progress:  同
/// ```
/// 数据没动 ⇒ 签名不变 ⇒ **一次请求都不发**。这就是 Owner 要的
/// 「耗很低的流量」—— 靠的是"没变就不传"，而不是"传得小"。
///
/// ⚠️ 用「条数 + 最大时间戳」而不是逐条哈希：前者 O(n) 且不分配，
///    后者要拼一整个字符串再算摘要。签名只需要**区分"变了没"**，
///    不需要抗碰撞 —— 两处都变了但条数与最大时间戳都相同的概率极低，
///    而万一撞上，代价只是「这一轮少同步一次」，下一轮数据再动就会补上。
pub fn data_signature(db: &Db) -> Result<String, String> {
    let favs = db.list_favorites(true)?;
    let foll = db.list_following()?;
    let progs = db.list_all_progress()?;

    fn one<T, F: Fn(&T) -> i64>(items: &[T], at: F) -> (usize, i64) {
        (items.len(), items.iter().map(at).max().unwrap_or(0))
    }

    let (fc, ft) = one(&favs, |f| f.updated_at);
    let (lc, lt) = one(&foll, |f| f.updated_at);
    let (pc, pt) = one(&progs, |p| p.updated_at);

    Ok(format!(
        "favorites:{fc}:{ft}|following:{lc}:{lt}|progress:{pc}:{pt}"
    ))
}

/// 一次整体备份的结果（`sync_backup_now` 的返回，契约 §1）
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BackupOutcome {
    /// 文件名（`dsh-backup-<device>-<yyyyMMdd-HHmmss>.zip`）
    pub name: String,
    /// 上传字节数
    pub bytes: u64,
    /// 远端完整路径（`backup/snapshots/<name>`）
    pub path: String,
    /// 本次被清理掉的旧备份名（可能为空）
    pub pruned: Vec<String>,
    /// ★ 清理**之后**云端还剩下几份
    ///
    /// 契约 §1 只写了 `total:int` 没说含义，这里取「剩下的份数」——
    /// UI 上「云端现有 N 份 / 最多保留 M 份」是最能说明状态的数字。
    /// （另一个候选「列出时共几份」等于 `total + pruned.len()`，可由 UI 自算。）
    pub total: usize,
}

/// 这个名字是不是**我们自己写的**整体备份？
///
/// ★ 这是保留清理的**安全护栏**（契约 §5②）：云盘目录里可能有用户自己
/// 放的文件、别的 App 的备份、我们早期的 `backup/<provider>/history-*.jsonl`。
/// 只要有一个不符合前缀/后缀就不删 —— 「少删」最多浪费点空间，
/// 「多删」是删用户的数据。
pub fn is_snapshot_name(name: &str) -> bool {
    name.starts_with(SNAPSHOT_PREFIX) && name.ends_with(SNAPSHOT_SUFFIX) && name.len() > SNAPSHOT_PREFIX.len() + SNAPSHOT_SUFFIX.len()
}

/// 从「云端现有的备份」里挑出**该删掉的**（纯函数，便于单测）
///
/// 规则（契约 §5）：
/// 1. 只考虑 [`is_snapshot_name`] 为真的（别人的文件一律不动）
/// 2. 按名字**降序**（`yyyyMMdd-HHmmss` 定长 ⇒ 字典序即时间序）
/// 3. 保留前 `max(1, retain_count)` 个，其余都删
///
/// ★ 下限为什么是 1 而不是 0：用户把「最多保留」设成 0 时，
///   若按字面执行就会**把刚上传的那份也删掉** —— 备份功能原地失效，
///   而且是静默的（UI 还显示"备份成功"）。所以下限锁死 1。
pub fn snapshots_to_prune(entries: &[RemoteEntry], retain_count: u32) -> Vec<String> {
    let keep = std::cmp::max(1, retain_count) as usize;
    let mut names: Vec<&str> = entries
        .iter()
        .map(|e| e.name.as_str())
        .filter(|n| is_snapshot_name(n))
        .collect();
    names.sort_unstable_by(|a, b| b.cmp(a)); // 降序：新的在前
    names.into_iter().skip(keep).map(|s| s.to_string()).collect()
}

/// 同步结果摘要（给 UI 展示「拉了多少 / 推了多少 / 多少冲突」）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncSummary {
    /// 平面名：favorites | progress | providers
    pub plane: String,
    /// 从远端拉取的新条目数
    pub pulled: usize,
    /// 推送到远端的条目数
    pub pushed: usize,
    /// 因远端更新而被覆盖的条数
    pub conflicts: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

/// ★ 内容源配置的**云备份载荷**（第 3 个平面）
///
/// 为什么要单独备份：用户手写的声明式 JSON / HTTP 插件地址
/// 是**纯本地数据** —— 换机器、重装、清数据就全没了，
/// 而它们往往比收藏更难重建（要重新去站点抓接口、写 JSONPath 映射）。
///
/// # 合并策略：整文件 LWW（**不是**逐条合并）
///
/// 与收藏/进度不同，源配置**不做逐条合并**，理由：
/// 1. 它是**结构性配置**，不是可累加的记录 ——
///    两台设备各改一半再合并，可能拼出一个谁都没测过的配置
/// 2. 条目数很少（通常几个到几十个），整文件覆盖的代价可以忽略
/// 3. 「哪台设备最后改的」就是用户的真实意图
///
/// 所以按 `updated_at` 整体取新的一份，旧的那份直接丢弃。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ProviderConfigBundle {
    /// 内容最后修改时间（毫秒）—— LWW 的判据
    pub updated_at: i64,
    /// 写入设备（诊断用）
    #[serde(default)]
    pub device: String,
    /// 第三方源配置（内置源不参与 —— 它们是程序的一部分，无需备份）
    pub providers: Vec<crate::PersistedProvider>,
}

/// 远端 manifest —— 结构版本 + 水位
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Manifest {
    pub schema_version: u32,
    /// 最后一次同步完成时间（毫秒）
    #[serde(default)]
    pub last_sync_at: i64,
    /// 写入过数据的设备（便于诊断「哪台设备改的」）
    #[serde(default)]
    pub devices: Vec<String>,
}

pub const SCHEMA_VERSION: u32 = 1;

impl Default for Manifest {
    fn default() -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            last_sync_at: 0,
            devices: Vec::new(),
        }
    }
}

/// 同步引擎（持有当前后端）
pub struct SyncEngine {
    backend: Arc<dyn SyncBackend>,
    db: Arc<Db>,
    /// 本机标识（写进 manifest，便于诊断）
    device_id: String,
}

impl SyncEngine {
    pub fn new_webdav(cfg: WebdavConfig, db: Arc<Db>, device_id: String) -> Result<Self, String> {
        let backend = WebdavBackend::new(cfg)?;
        Ok(Self {
            backend: Arc::new(backend),
            db,
            device_id,
        })
    }

    pub fn new(backend: Arc<dyn SyncBackend>, db: Arc<Db>, device_id: String) -> Self {
        Self {
            backend,
            db,
            device_id,
        }
    }

    pub fn backend_name(&self) -> &str {
        self.backend.name()
    }

    /// 连通性自检（设置页「测试连接」）
    pub async fn test(&self) -> Result<String, String> {
        self.backend.ping().await
    }

    /// ★ 准备远端目录（配置云盘时先调用，再调 `test()`）
    ///
    /// 顺序很重要：`test()` 会 PROPFIND **含 `remote_dir` 的完整路径**，
    /// 目录还不存在时会返回 404，被误报成
    /// 「路径不存在：请确认 WebDAV 地址包含目标目录」——
    /// 用户明明填对了地址。
    ///
    /// 所以配置流程是：**先 `prepare()` 建目录 → 再 `test()` 验凭据**。
    pub async fn prepare(&self) -> Result<(), String> {
        self.ensure_layout().await
    }

    /// 确保远端目录结构存在
    ///
    /// ⚠️ 必须**逐级**创建 —— 坚果云对多级 MKCOL 返回 409（见 `webdav.rs` 说明）。
    /// `ensure_dir` 内部已做了逐级拆分。
    ///
    /// ★ 2026-09-15 修：**根目录（`remote_dir`）自己也要建**
    ///
    /// 原先只建了 `data/` 与 `backup/`，但 `manifest.json` 写在**根目录下** ——
    /// 而 WebDAV 的 MKCOL 要求父目录已存在，根目录不存在时：
    ///   · 建 `data/` 会失败（父目录没有）
    ///   · 写 `manifest.json` 报 **HTTP 404**
    ///
    /// 实测踩到：配置好云盘后第一次同步直接失败
    /// （`PUT manifest.json 失败: HTTP 404 The resource of this location does not exist`）。
    /// 手动对该目录发一次 MKCOL 后立刻恢复正常。
    ///
    /// 用空路径 `""` 表示根目录（`WebdavBackend::url` 会拼成 `{root}/`）。
    async fn ensure_layout(&self) -> Result<(), String> {
        // 根目录优先 —— 它是其余一切的前提
        self.backend.ensure_dir("").await?;
        self.backend.ensure_dir("data").await?;
        self.backend.ensure_dir("backup").await?;
        /*
         * ★ 整体备份的专属子目录（2026-09-29，task-75）
         *
         * 刻意**不用** `backup/` 根目录：那底下已经有
         * `backup/{provider}/history-{device}.jsonl`（平台历史镜像）。
         * 混在一起会让「列出备份」把平台历史也列出来当成一份备份 ——
         * 而保留清理是按份数删的，数错就会删错。
         */
        self.backend.ensure_dir(SNAPSHOT_DIR).await?;
        Ok(())
    }

    // ─────────────────── 独立平面：双向同步 ───────────────────

    /// ★ 收藏 + 追更 双向同步
    pub async fn sync_favorites(&self) -> Result<SyncSummary, String> {
        self.ensure_layout().await?;
        let path = "data/favorites.jsonl";

        // 1) 拉远端
        let remote_raw = self.backend.get(path).await?;
        let (remote_had, remote_etag) = match &remote_raw {
            Some((bytes, etag)) => {
                let text = String::from_utf8_lossy(bytes);
                (parse_jsonl::<Favorite>(&text)?, etag.clone())
            }
            None => (Vec::new(), None),
        };
        // 留一份「合并前远端的快照」，用于精确统计 pushed
        let remote_had_keys: Vec<String> = remote_had.iter().map(|f| f.key.clone()).collect();
        let remote_had = remote_had.clone();

        // 2) 拉本地
        let local = self.db.list_favorites(true)?;

        // 3) LWW 合并
        let merged = merge_lww(local, remote_had.clone(), |f| f.key.clone(), |f| f.updated_at);

        // 4) 写回本地（合并结果落库），并统计**真正来自远端的新增**
        let mut pulled = 0usize;
        let local_keys: std::collections::HashSet<String> =
            self.db.list_favorites(true)?.into_iter().map(|f| f.key).collect();
        for f in &merged.items {
            if f.deleted {
                // 墓碑：同步进来的删除也要落成本地墓碑
                self.db.tombstone_favorite(&f.key, f.updated_at)?;
            } else {
                self.db.upsert_favorite(f)?;
            }
            if !local_keys.contains(&f.key) {
                pulled += 1;
            }
        }

        // 5) 写回远端（带回退重试：冲突则重拉再合并）
        let body = to_jsonl(&merged.items)?;
        /*
         * ★★ 低流量改造（契约 §7，2026-09-29 task-75）
         *
         * # 改之前是什么样
         *
         * 每次都无条件 `PUT` 全文 —— 哪怕一个字节都没变。
         * 用户开着自动同步（默认 30 分钟）时，一天就是 48 次
         * 白白上传同样的内容。这正是 Owner 说的「耗流量」的根源。
         *
         * # 判据必须拿**远端原始字节**比
         *
         * `remote_raw` 是 `get()` 返回的**原样**字节。若拿
         * `to_jsonl()` 重新序列化再跟 `body` 比，那是自己跟自己比
         * （同一个函数、同一份数据）⇒ **恒等** ⇒ 永远跳过 PUT，
         * 连首次上传都不会发生。这是这条改动最容易写错的地方。
         *
         * # `remote_had == false` 必须照常 PUT
         *
         * 远端还没有这个文件（首次上传，或用户在云端删了它）
         * ⇒ 必须写上去，否则本地数据永远同步不出去。
         *
         * ⚠️ 跳过 PUT **不影响**上面的第 4 步：pull 到的远端变更
         *    已经落进本地 DB 了，只是不回传而已。
         *    `SyncSummary.pushed` 也照常算 —— 它表达的是
         *    「本轮真正需要推送的量」，跳过时天然为 0。
         */
        // 远端**原始字节**（None = 远端还没有这个文件）
        let remote_bytes: Option<&[u8]> = remote_raw.as_ref().map(|(b, _)| b.as_slice());
        if remote_bytes == Some(body.as_bytes()) {
            log::debug!("sync: {path} 内容与远端逐字节相同，跳过 PUT（省一次上传）");
        } else {
            // 内容不同，或远端还没有（首次上传）⇒ 必须写
            self.put_with_remerge(path, body.as_bytes(), remote_etag.as_deref(), |local_again, remote_again| {
                merge_lww(local_again, remote_again, |f: &Favorite| f.key.clone(), |f: &Favorite| f.updated_at)
            }, || -> Result<Vec<Favorite>, String> { self.db.list_favorites(true) },
               |items: &[Favorite]| -> Result<(), String> {
                   for f in items { self.db.upsert_favorite(f)?; }
                   Ok(())
               })
            .await?;
        }

        // ★ `pushed` 必须是「本轮真正需要推送的量」，而不是「文件里总共有多少条」。
        //   否则每次同步都报同样的数字，用户会以为一直在重传。
        //   真正需要推送 = 本地侧存在、且远端没有或比本地旧。
        let remote_keys: std::collections::HashSet<String> =
            remote_had_keys.iter().cloned().collect();
        let remote_updated: std::collections::HashMap<String, i64> = remote_had
            .iter()
            .map(|f| (f.key.clone(), f.updated_at))
            .collect();
        let pushed = merged
            .items
            .iter()
            .filter(|m| match remote_keys.contains(&m.key) {
                false => true, // 远端没有 → 需要推送
                true => remote_updated.get(&m.key).copied().unwrap_or(i64::MIN) < m.updated_at,
            })
            .count();

        Ok(SyncSummary {
            plane: "favorites".into(),
            pulled,
            pushed,
            conflicts: merged.conflicts,
            note: None,
        })
    }

    /// ★ 播放进度 双向同步
    pub async fn sync_progress(&self) -> Result<SyncSummary, String> {
        self.ensure_layout().await?;
        let path = "data/progress.jsonl";

        let remote_raw = self.backend.get(path).await?;
        let (remote_had, remote_etag) = match &remote_raw {
            Some((bytes, etag)) => {
                let text = String::from_utf8_lossy(bytes);
                (parse_jsonl::<Progress>(&text)?, etag.clone())
            }
            None => (Vec::new(), None),
        };
        let remote_had_keys: std::collections::HashSet<String> =
            remote_had.iter().map(|p| p.key.clone()).collect();
        let remote_updated: std::collections::HashMap<String, i64> = remote_had
            .iter()
            .map(|p| (p.key.clone(), p.updated_at))
            .collect();

        let local = self.db.list_all_progress()?;
        let merged = merge_lww(local, remote_had, |p| p.key.clone(), |p| p.updated_at);

        let local_keys: std::collections::HashSet<String> =
            self.db.list_all_progress()?.into_iter().map(|p| p.key).collect();
        let mut pulled = 0usize;
        for p in &merged.items {
            if !local_keys.contains(&p.key) {
                pulled += 1;
            }
            self.db.upsert_progress(p)?;
        }

        let body = to_jsonl(&merged.items)?;
        // ★★ 低流量改造（契约 §7）—— 与 sync_favorites 同构，理由见那里的长注释：
        //   ① 判据必须拿 `get()` 返回的**远端原始字节**比，不能拿 `to_jsonl()` 再序列化一遍（恒等）；
        //   ② `remote_bytes == None`（远端还没有这个文件）**必须照常 PUT**，否则永远同步不出去；
        //   ③ 跳过 PUT 不影响上面的落库：pull 到的远端变更已经写进本地 DB 了。
        let remote_bytes: Option<&[u8]> = remote_raw.as_ref().map(|(b, _)| b.as_slice());
        if remote_bytes == Some(body.as_bytes()) {
            log::debug!("sync: {path} 内容与远端逐字节相同，跳过 PUT（省一次上传）");
        } else {
            self.put_with_remerge(path, body.as_bytes(), remote_etag.as_deref(), |l, r| {
                merge_lww(l, r, |p: &Progress| p.key.clone(), |p: &Progress| p.updated_at)
            }, || self.db.list_all_progress(),
               |items: &[Progress]| -> Result<(), String> {
                   for p in items { self.db.upsert_progress(p)?; }
                   Ok(())
               })
            .await?;
        }

        // 同 favorites：pushed 只算**本轮真正要推的**（远端缺失或更旧）
        let pushed = merged
            .items
            .iter()
            .filter(|m| match remote_had_keys.contains(&m.key) {
                false => true,
                true => remote_updated.get(&m.key).copied().unwrap_or(i64::MIN) < m.updated_at,
            })
            .count();

        Ok(SyncSummary {
            plane: "progress".into(),
            pulled,
            pushed,
            conflicts: merged.conflicts,
            note: None,
        })
    }

    /// 写远端，遇 412（别的设备抢先写了）就重拉+重新合并+再写
    ///
    /// 这是「多设备同时同步」不至于丢数据的关键：
    /// 冲突不报错给用户，而是**自动重合并**（LWW 是可交换的，重合并是安全的）。
    async fn put_with_remerge<T, FMerge, FLoad, FApply>(
        &self,
        path: &str,
        body: &[u8],
        etag: Option<&str>,
        remrege: FMerge,
        load_local: FLoad,
        apply_merged: FApply,
    ) -> Result<(), String>
    where
        // ★ `Normalize` 是 `parse_jsonl` 的约束（旧格式行的不变量修正）
        T: Serialize + for<'de> Deserialize<'de> + Clone + Normalize,
        FMerge: Fn(Vec<T>, Vec<T>) -> MergeOutcome<T>,
        FLoad: Fn() -> Result<Vec<T>, String>,
        FApply: Fn(&[T]) -> Result<(), String>,
    {
        match self.backend.put(path, body, etag).await {
            Ok(()) => Ok(()),
            Err(e) if e.contains("412") || e.contains("已被其他设备") => {
                // 别人抢先了：重拉远端，与本地重新合并后再写一次
                log::info!("sync: {path} 发生并发写，自动重新合并");
                let fresh = self.backend.get(path).await?;
                let remote: Vec<T> = match fresh {
                    Some((b, _)) => parse_jsonl(&String::from_utf8_lossy(&b))?,
                    None => Vec::new(),
                };
                let local = load_local()?;
                let merged = remrege(local, remote);
                apply_merged(&merged.items)?;

                let new_body = to_jsonl(&merged.items)?;
                let new_etag = self.backend.etag(path).await?;
                self.backend
                    .put(path, new_body.as_bytes(), new_etag.as_deref())
                    .await
            }
            Err(e) => Err(e),
        }
    }

    // ─────────────────── 备份平面：单向镜像 ───────────────────

    /// ★ 把某平台的「自带历史」镜像到远端（**只读备份，绝不回写平台**）
    ///
    /// 按设备分文件，避免多设备互相覆盖各自的视角。
    pub async fn backup_platform_history(
        &self,
        provider: &str,
        records: &[crate::provider::UserRecord],
    ) -> Result<usize, String> {
        self.backend.ensure_dir(&format!("backup/{provider}")).await?;

        let path = format!("backup/{provider}/history-{}.jsonl", self.device_id);
        // 快照语义：平台历史是「当前状态」，直接覆盖即可（无需 LWW）
        let body = to_jsonl(records)?;
        self.backend.put(&path, body.as_bytes(), None).await?;

        log::info!("已镜像 {} 条 {provider} 历史到 {path}", records.len());
        Ok(records.len())
    }

    // ─────────────── 整体备份快照（契约 §5，2026-09-29）───────────────

    /// ★ 传一份整体备份到云端，然后跑一遍保留清理
    ///
    /// # 与「增量同步」是**两条不相干的通道**
    ///
    /// 增量同步传的是几 KB 的 JSONL（`data/*.jsonl`），这里传的是
    /// 整个 zip（用户数据 + 源配置 + 插件）。Owner 说的
    /// 「整体备份和别的备份是拆分开的」就是这个意思 ——
    /// 阅读 App（Legado）亦然。所以本函数的节奏由
    /// `autoBackupIntervalMinutes` 单独控制，**不跟** `autoIntervalMinutes`。
    ///
    /// # `bytes` 由调用方打好包传进来
    ///
    /// 打包要读 `AppState`（registry / 插件目录），那是命令层的事；
    /// 这里只管「传上去 + 清理旧的」。
    pub async fn backup_snapshot(
        &self,
        name: &str,
        bytes: &[u8],
        retain_count: u32,
    ) -> Result<BackupOutcome, String> {
        self.ensure_layout().await?;
        if !is_snapshot_name(name) {
            // 文件名是我们自己生成的（`default_backup_name`），
            // 走到这里说明调用方拼错了 —— 早报错，别把脏名字写进云端
            return Err(format!("备份文件名不合规: {name}"));
        }
        let path = format!("{SNAPSHOT_DIR}/{name}");
        // 名字带秒级时间戳 ⇒ 不会撞；也无所谓覆盖谁，所以无条件写
        self.backend.put(&path, bytes, None).await?;

        let entries = self.list_snapshots_inner().await?;
        let doomed = snapshots_to_prune(&entries, retain_count);
        let mut pruned: Vec<String> = Vec::new();
        for old in doomed {
            let p = format!("{SNAPSHOT_DIR}/{old}");
            /*
             * 删不掉**不算备份失败**（契约 §5④）。
             *
             * 常见情形：坚果云对某些扩展名/配额有限制，或网络抖了一下。
             * 备份本体已经传上去了 —— 那是用户真正要保存的东西；
             * 为了「腾地方」失败而把整次备份报成失败，是主次颠倒
             * （用户会以为数据没备上，其实已经备上了）。
             */
            match self.backend.delete(&p).await {
                Ok(()) => {
                    log::info!("已清理旧备份 {p}");
                    pruned.push(old);
                }
                Err(e) => log::warn!("删除旧备份 {p} 失败（不影响本次备份，下次再试）: {e}"),
            }
        }
        let total = entries.len().saturating_sub(pruned.len());
        log::info!(
            "整体备份已上传：{path}（{} 字节），清理 {} 份，云端现有 {} 份",
            bytes.len(),
            pruned.len(),
            total
        );
        Ok(BackupOutcome {
            name: name.to_string(),
            bytes: bytes.len() as u64,
            path,
            pruned,
            total,
        })
    }

    /// 列出云端的整体备份（**已过滤**成我们自己的 `dsh-backup-*.zip`，新的在前）
    pub async fn list_snapshots(&self) -> Result<Vec<RemoteEntry>, String> {
        self.ensure_layout().await?;
        self.list_snapshots_inner().await
    }

    /// 内部版：不跑 `ensure_layout`（`backup_snapshot` 已经跑过了）
    async fn list_snapshots_inner(&self) -> Result<Vec<RemoteEntry>, String> {
        let mut entries: Vec<RemoteEntry> = self
            .backend
            .list(SNAPSHOT_DIR)
            .await?
            .into_iter()
            .filter(|e| is_snapshot_name(&e.name))
            .collect();
        // 名字里是定长的 `yyyyMMdd-HHmmss` ⇒ 字典序即时间序；降序 = 新的在前
        entries.sort_by(|a, b| b.name.cmp(&a.name));
        Ok(entries)
    }

    /// 删除云端某一份备份；返回「是否真的删了」
    ///
    /// ★ **安全护栏**：只认 `dsh-backup-*.zip`。这个函数的名字由 UI 传进来，
    /// 若不加护栏，一个拼错的/恶意的名字就能删掉用户云盘里**别的**文件。
    /// 名字不合规 ⇒ 返回 `Ok(false)`（没删），而不是报错 ——
    /// 让 UI 自己决定怎么提示。
    pub async fn delete_snapshot(&self, name: &str) -> Result<bool, String> {
        if !is_snapshot_name(name) {
            log::warn!("拒绝删除非备份文件: {name}");
            return Ok(false);
        }
        self.ensure_layout().await?;
        let path = format!("{SNAPSHOT_DIR}/{name}");
        match self.backend.delete(&path).await {
            Ok(()) => Ok(true),
            Err(e) => {
                log::warn!("删除备份 {path} 失败: {e}");
                Err(e)
            }
        }
    }

    // ─────────────────── manifest ───────────────────

    pub async fn read_manifest(&self) -> Result<Manifest, String> {
        match self.backend.get("manifest.json").await? {
            Some((b, _)) => {
                let text = String::from_utf8_lossy(&b);
                serde_json::from_str(&text).map_err(|e| format!("manifest 解析失败: {e}"))
            }
            None => Ok(Manifest::default()),
        }
    }

    pub async fn write_manifest(&self, m: &Manifest) -> Result<(), String> {
        let body = serde_json::to_vec_pretty(m).map_err(|e| e.to_string())?;
        let etag = self.backend.etag("manifest.json").await?;
        match self.backend.put("manifest.json", &body, etag.as_deref()).await {
            Ok(()) => Ok(()),
            // manifest 只是索引，冲突了就直接覆盖，不值得为它做重合并
            Err(e) if e.contains("412") || e.contains("已被其他设备") => {
                self.backend.put("manifest.json", &body, None).await
            }
            Err(e) => Err(e),
        }
    }

    /// ★ 内容源配置双向同步（第 3 个平面）
    ///
    /// `local` 是调用方（lib.rs）从 `state.third_party` 取出的当前配置快照。
    /// 返回**合并后应当生效的配置**，由调用方负责写回 registry 与磁盘。
    ///
    /// 合并策略见 [`ProviderConfigBundle`] 的说明：**整文件 LWW**，
    /// 不做逐条合并。
    pub async fn sync_provider_configs(
        &self,
        local: Vec<crate::PersistedProvider>,
        local_updated_at: i64,
    ) -> Result<(Vec<crate::PersistedProvider>, SyncSummary), String> {
        self.ensure_layout().await?;
        let path = "data/providers.json";

        // 1) 拉远端
        let remote_raw = self.backend.get(path).await?;
        let remote: Option<ProviderConfigBundle> = match &remote_raw {
            Some((bytes, _)) => {
                let text = String::from_utf8_lossy(bytes);
                // 远端格式坏了不该让同步整体失败 —— 当成「没有远端」，
                // 本地那份会重新推上去（自愈）
                match serde_json::from_str::<ProviderConfigBundle>(&text) {
                    Ok(b) => Some(b),
                    Err(e) => {
                        log::warn!("远端 providers.json 解析失败（将用本地覆盖）: {e}");
                        None
                    }
                }
            }
            None => None,
        };

        let local_bundle = ProviderConfigBundle {
            updated_at: local_updated_at,
            device: self.device_id.clone(),
            providers: local.clone(),
        };

        // 2) 整文件 LWW：谁新用谁
        let (winner, conflicts, pulled, pushed) = match &remote {
            Some(r) if r.updated_at > local_bundle.updated_at => {
                // 远端更新 → 采用远端
                (r.clone(), 1usize, r.providers.len(), 0usize)
            }
            Some(_) => {
                // 本地更新或相同 → 采用本地
                (local_bundle.clone(), 0, 0, local.len())
            }
            None => {
                // 远端还没有 → 推送本地
                (local_bundle.clone(), 0, 0, local.len())
            }
        };

        // 3) 写回远端（冲突则重试一次，直接覆盖 —— 整文件语义下重合并没有意义）
        let body = serde_json::to_vec_pretty(&winner).map_err(|e| e.to_string())?;
        /*
         * ★★ 低流量改造（契约 §7，2026-09-29 task-75）—— 与 sync_favorites / sync_progress 同构
         *
         * 判据 = 「即将写上去的字节」与「远端**原始**字节」逐字节相同
         *        ⇒ 这次 PUT 纯属浪费，跳过。
         *
         * `remote_raw` 是 `get()` 的**原样**返回（上面第 1 步拿到的），
         * 不是重新序列化的结果 —— 拿 `to_vec_pretty(&winner)` 跟它自己比是恒等，
         * 会连首次上传都跳过。
         *
         * `remote_bytes == None`（远端还没有 providers.json）⇒ 必须照常 PUT。
         */
        let remote_bytes: Option<&[u8]> = remote_raw.as_ref().map(|(b, _)| b.as_slice());
        if remote_bytes == Some(body.as_slice()) {
            log::debug!("sync: {path} 内容与远端逐字节相同，跳过 PUT（省一次上传）");
        } else {
            let etag = self.backend.etag(path).await?;
            match self.backend.put(path, &body, etag.as_deref()).await {
                Ok(()) => {}
                Err(e) if e.contains("412") || e.contains("已被其他设备") => {
                    log::info!("providers.json 被其他设备抢先写入，用本地版本覆盖");
                    self.backend.put(path, &body, None).await?;
                }
                Err(e) => return Err(e),
            }
        }

        let summary = SyncSummary {
            plane: "providers".into(),
            pulled,
            pushed,
            conflicts,
            note: Some(format!("共 {} 个第三方源", winner.providers.len())),
        };

        Ok((winner.providers, summary))
    }

    /// 一次完整同步（独立平面两个文件 + 内容源配置 + manifest）
    pub async fn sync_all(&self) -> Result<Vec<SyncSummary>, String> {
        let mut out = Vec::new();
        out.push(self.sync_favorites().await?);
        out.push(self.sync_progress().await?);

        let mut m = self.read_manifest().await.unwrap_or_default();
        m.schema_version = SCHEMA_VERSION;
        m.last_sync_at = chrono::Utc::now().timestamp_millis();
        if !m.devices.contains(&self.device_id) {
            m.devices.push(self.device_id.clone());
        }
        self.write_manifest(&m).await?;

        Ok(out)
    }
}

// ─────────────────────────── LWW 合并 ───────────────────────────

/// 合并结果
#[derive(Debug, Clone)]
pub struct MergeOutcome<T> {
    pub items: Vec<T>,
    /// 被另一侧覆盖的条数（诊断用）
    pub conflicts: usize,
}

/// ★ Last-Write-Wins 合并
///
/// 规则（严格按方案文档 2.2）：
/// 1. 同一 key，`updated_at` 大者胜
/// 2. **删除写墓碑**（`deleted=true`），否则会被其他设备的旧数据复活
/// 3. 时间戳完全相同时，本地优先（保证幂等：重复同步结果一致）
///
/// 关键性质：**可交换**（local/remote 换序结果相同，除同时刻的平手），
/// 因此并发冲突时「重拉+重合并」是安全的。
pub fn merge_lww<T, K, U>(local: Vec<T>, remote: Vec<T>, key_of: K, updated_of: U) -> MergeOutcome<T>
where
    T: Clone,
    K: Fn(&T) -> String,
    U: Fn(&T) -> i64,
{
    use std::collections::HashMap;

    let mut map: HashMap<String, (T, bool)> = HashMap::new(); // (item, from_local)
    let mut conflicts = 0usize;

    for it in local {
        map.insert(key_of(&it), (it, true));
    }

    for r in remote {
        let k = key_of(&r);
        match map.get(&k) {
            None => {
                map.insert(k, (r, false));
            }
            Some((l, _)) => {
                let lt = updated_of(l);
                let rt = updated_of(&r);
                if rt > lt {
                    // 远端更新 → 远端胜（这是一次「被覆盖」）
                    conflicts += 1;
                    map.insert(k, (r, false));
                } else if rt == lt {
                    // 平手：本地优先，保证可重复执行结果稳定
                } else {
                    // 本地更新 → 本地胜，保持不动
                }
            }
        }
    }

    MergeOutcome {
        items: map.into_values().map(|(v, _)| v).collect(),
        conflicts,
    }
}

// ─────────────────────────── JSONL 读写 ───────────────────────────

/// 序列化为 JSONL（每行一个 JSON 对象）
///
/// 用 JSONL 而非单个 JSON 数组：**便于人工查看与增量解析**，
/// 出问题时能直接 tail 看最后几条。
pub fn to_jsonl<T: Serialize>(items: &[T]) -> Result<String, String> {
    let mut out = String::new();
    for it in items {
        let line = serde_json::to_string(it).map_err(|e| format!("序列化失败: {e}"))?;
        out.push_str(&line);
        out.push('\n');
    }
    Ok(out)
}

/// 解析 JSONL；**跳过空行与坏行**而不是整体失败
///
/// 为什么容错：云端文件可能被其他工具手动编辑过，
/// 因为一行坏数据就整份同步失败，用户体验很差。
///
/// ★ 解析成功后对每条调用 [`Normalize::normalize`]（2026-09-21 补）：
///   这是**所有**远端/备份读取的唯一入口（`sync_favorites`、
///   `sync_progress`、`put_with_remerge` 都走它），
///   把"旧格式行的缺省字段可能违反不变量"这件事
///   集中在一个点上修掉，而不是指望每个调用方记得。
pub fn parse_jsonl<T>(text: &str) -> Result<Vec<T>, String>
where
    T: for<'de> Deserialize<'de> + Normalize,
{
    let mut out = Vec::new();
    let mut bad = 0usize;
    for (i, line) in text.lines().enumerate() {
        let t = line.trim();
        if t.is_empty() {
            continue;
        }
        match serde_json::from_str::<T>(t) {
            Ok(mut v) => {
                v.normalize();
                out.push(v);
            }
            Err(e) => {
                bad += 1;
                log::warn!("JSONL 第 {} 行解析失败（已跳过）: {e}", i + 1);
            }
        }
    }
    if bad > 0 && out.is_empty() {
        return Err(format!("JSONL 全部 {bad} 行都无法解析，可能不是本应用的备份"));
    }
    Ok(out)
}

// ─────────────────────────── 测试 ───────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn fav(key: &str, updated: i64, deleted: bool) -> Favorite {
        Favorite {
            key: key.into(),
            provider: "p".into(),
            native_id: key.into(),
            title: format!("t-{key}"),
            cover: None,
            group_name: None,
            kind: "series".into(),
            /*
             * 不变量（见 store.rs 的 `favorited` 文档）：
             *     deleted=1  ⇔  !favorited && !following
             *
             * 写成从 `deleted` 推导而不是写死，是为了让这个 fixture
             * 在两种墓碑状态下都自洽 —— 否则 merge 用例会拿到
             * 「墓碑却还开着收藏」这种真实数据里不该出现的组合。
             */
            favorited: !deleted,
            following: false,
            last_episode_count: 0,
            last_episode_title: None,
            unread_count: 0,
            last_checked_at: 0,
            last_update_at: 0,
            note: None,
            created_at: 0,
            updated_at: updated,
            deleted,
        }
    }

    fn prog(key: &str, updated: i64, pos: u64) -> Progress {
        Progress {
            key: key.into(),
            provider: "p".into(),
            native_id: key.into(),
            title: format!("t-{key}"),
            cover: None,
            episode_id: None,
            episode_title: None,
            position: pos,
            duration: 100,
            finished: false,
            updated_at: updated,
        }
    }

    /// 远端更新 → 远端胜
    #[test]
    fn newer_remote_wins() {
        let out = merge_lww(
            vec![fav("a", 100, false)],
            vec![fav("a", 200, false)],
            |f| f.key.clone(),
            |f| f.updated_at,
        );
        assert_eq!(out.items.len(), 1);
        assert_eq!(out.items[0].updated_at, 200, "更新的远端应获胜");
        assert_eq!(out.conflicts, 1);
    }

    /// 本地更新 → 本地胜
    #[test]
    fn newer_local_wins() {
        let out = merge_lww(
            vec![fav("a", 300, false)],
            vec![fav("a", 200, false)],
            |f| f.key.clone(),
            |f| f.updated_at,
        );
        assert_eq!(out.items[0].updated_at, 300);
        assert_eq!(out.conflicts, 0);
    }

    /// ★ 墓碑必须能压过旧的「未删除」记录，否则删除会被复活
    #[test]
    fn tombstone_beats_older_alive_record() {
        // 本地：已删除（墓碑，时间戳新）
        // 远端：还以为存在（旧的）
        let out = merge_lww(
            vec![fav("a", 500, true)],
            vec![fav("a", 100, false)],
            |f| f.key.clone(),
            |f| f.updated_at,
        );
        assert!(out.items[0].deleted, "墓碑必须获胜，否则删除会被复活");

        // 反向：远端墓碑更新 → 也要压过本地存活记录
        let out2 = merge_lww(
            vec![fav("a", 100, false)],
            vec![fav("a", 500, true)],
            |f| f.key.clone(),
            |f| f.updated_at,
        );
        assert!(out2.items[0].deleted, "远端墓碑同样要压过本地旧记录");
    }

    /// 平手时本地优先 → 保证重复同步结果稳定（幂等）
    #[test]
    fn tie_prefers_local_and_is_idempotent() {
        let local = vec![fav("a", 100, false)];
        let remote = vec![fav("a", 100, false)];
        let out1 = merge_lww(local.clone(), remote.clone(), |f| f.key.clone(), |f| f.updated_at);
        let out2 = merge_lww(out1.items.clone(), remote, |f| f.key.clone(), |f| f.updated_at);
        assert_eq!(out1.items.len(), 1);
        assert_eq!(out2.items.len(), 1);
        assert_eq!(out1.items[0].updated_at, out2.items[0].updated_at);
    }

    /// 两边独有项都要保留（并集）
    #[test]
    fn union_of_both_sides() {
        let out = merge_lww(
            vec![fav("local-only", 100, false), fav("shared", 100, false)],
            vec![fav("remote-only", 100, false), fav("shared", 50, false)],
            |f| f.key.clone(),
            |f| f.updated_at,
        );
        assert_eq!(out.items.len(), 3, "并集：3 个不同 key");
        let keys: std::collections::HashSet<_> = out.items.iter().map(|f| f.key.clone()).collect();
        assert!(keys.contains("local-only"));
        assert!(keys.contains("remote-only"));
        assert!(keys.contains("shared"));
    }

    /// 合并可交换（除同时刻平手），这是「冲突后重合并」安全的前提
    #[test]
    fn merge_is_commutative_for_distinct_timestamps() {
        let a = vec![fav("x", 100, false), fav("y", 500, false)];
        let b = vec![fav("x", 300, false), fav("z", 200, false)];

        let ab = merge_lww(a.clone(), b.clone(), |f| f.key.clone(), |f| f.updated_at);
        let ba = merge_lww(b, a, |f| f.key.clone(), |f| f.updated_at);

        let mut m1: Vec<(String, i64)> = ab.items.iter().map(|f| (f.key.clone(), f.updated_at)).collect();
        let mut m2: Vec<(String, i64)> = ba.items.iter().map(|f| (f.key.clone(), f.updated_at)).collect();
        m1.sort();
        m2.sort();
        assert_eq!(m1, m2, "不同时间戳下合并必须可交换");
    }

    /// 进度合并（同一套 LWW，验证泛型可用）
    #[test]
    fn progress_uses_same_lww() {
        let out = merge_lww(
            vec![prog("k", 100, 10)],
            vec![prog("k", 900, 500)],
            |p| p.key.clone(),
            |p| p.updated_at,
        );
        assert_eq!(out.items[0].position, 500, "较新的进度应获胜");
    }

    #[test]
    fn jsonl_roundtrip() {
        let items = vec![fav("a", 1, false), fav("b", 2, true)];
        let text = to_jsonl(&items).unwrap();
        assert_eq!(text.lines().count(), 2, "应为两行");
        let back: Vec<Favorite> = parse_jsonl(&text).unwrap();
        assert_eq!(back.len(), 2);
        assert_eq!(back[1].key, "b");
    }

    /// 坏行应被跳过，而不是让整份同步失败
    #[test]
    fn jsonl_skips_bad_lines_but_keeps_good() {
        let text = "{\"key\":\"a\"}\nNOT_JSON\n\n{\"key\":\"b\"}\n";
        // 这两行缺少必填字段，会解析失败 → 全部坏 → 报错
        let r: Result<Vec<Favorite>, _> = parse_jsonl(text);
        assert!(r.is_err(), "全部坏行时应报错，提示不是本应用的备份");

        // 混合场景：好行保留，坏行跳过
        let good = to_jsonl(&[fav("ok", 1, false)]).unwrap();
        let mixed = format!("{good}BADLINE\n");
        let ok: Vec<Favorite> = parse_jsonl(&mixed).unwrap();
        assert_eq!(ok.len(), 1);
        assert_eq!(ok[0].key, "ok");
    }

    #[test]
    fn jsonl_ignores_blank_lines() {
        let text = "\n\n{\"key\":\"a\",\"provider\":\"p\",\"native_id\":\"a\",\"title\":\"t\",\"kind\":\"series\",\"following\":false,\"last_episode_count\":0,\"unread_count\":0,\"last_checked_at\":0,\"created_at\":0,\"updated_at\":1,\"deleted\":false}\n\n";
        let v: Vec<Favorite> = parse_jsonl(text).unwrap();
        assert_eq!(v.len(), 1);
    }

    /// ★★ 升级前的旧 JSONL 必须仍能解析，且语义被正确翻译
    ///
    /// # 这个用例是实测逼出来的（2026-09-21）
    ///
    /// `favorited` / `last_update_at` 是 2026-09-20 新加的字段，
    /// 加完没给 `#[serde(default)]`，于是**升级前写到云盘的
    /// `data/favorites.jsonl` 整份解析失败**，报
    /// `JSONL 全部 N 行都无法解析，可能不是本应用的备份`，
    /// 而 `sync_favorites` 会让这个错误**向上传播 → 整个同步中断**。
    ///
    /// 上面的 `jsonl_ignores_blank_lines` 正是踩到这个才失败的
    /// （它的字面量就是一条旧格式行）。
    ///
    /// # 断言的三件事
    ///
    /// 1. 旧行能解析（不抛错）
    /// 2. `deleted=0` 的旧行 → `favorited=true`（收藏不会凭空消失）
    /// 3. `deleted=1` 的旧行 → `favorited=false`（★ 墓碑不许复活）
    ///
    /// 第 3 条最关键：`list_favorites` **只按 `favorited=1` 过滤**
    /// （不带 `deleted` 条件），所以墓碑若被缺省成 `favorited=true`，
    /// 用户删掉的收藏会重新出现在列表里。
    #[test]
    fn legacy_jsonl_without_new_fields_still_parses() {
        // 升级前的格式：没有 favorited / last_update_at
        let visible = "{\"key\":\"a\",\"provider\":\"p\",\"native_id\":\"a\",\"title\":\"t\",\
                       \"kind\":\"series\",\"following\":false,\"last_episode_count\":0,\
                       \"unread_count\":0,\"last_checked_at\":0,\"created_at\":0,\
                       \"updated_at\":1,\"deleted\":false}";
        let tombstone = "{\"key\":\"b\",\"provider\":\"p\",\"native_id\":\"b\",\"title\":\"t\",\
                         \"kind\":\"series\",\"following\":false,\"last_episode_count\":0,\
                         \"unread_count\":0,\"last_checked_at\":0,\"created_at\":0,\
                         \"updated_at\":2,\"deleted\":true}";
        let text = format!("{visible}\n{tombstone}\n");

        let v: Vec<Favorite> = parse_jsonl(&text).expect("旧格式必须仍可解析");
        assert_eq!(v.len(), 2, "两行都应解析出来");

        // ② 可见收藏：缺省 favorited 必须为 true，否则收藏会消失
        assert!(v[0].favorited, "旧格式的可见收藏应被视为已收藏");
        assert!(!v[0].deleted);
        assert_eq!(v[0].last_update_at, 0, "缺失的新时间字段应缺省为 0");

        // ③ ★ 墓碑：必须被 normalize 清成 !favorited，否则删除会复活
        assert!(v[1].deleted, "墓碑应保持 deleted");
        assert!(
            !v[1].favorited,
            "墓碑绝不能是 favorited —— 否则 list_favorites 会让它复活"
        );
        assert!(!v[1].following, "墓碑不应开着追更");
    }

    /// `Normalize` 的不变量：`deleted=1 ⇔ !favorited && !following`
    #[test]
    fn normalize_enforces_tombstone_invariant() {
        use crate::store::Normalize as _;

        // 墓碑却开着两个状态 → 必须都被清掉
        let mut f = fav("x", 1, true);
        f.favorited = true;
        f.following = true;
        f.unread_count = 5;
        f.normalize();
        assert!(!f.favorited && !f.following && f.unread_count == 0);

        // 两个状态都关、又不是墓碑 → 补成墓碑（该行无意义）
        let mut g = fav("y", 1, false);
        g.favorited = false;
        g.following = false;
        g.normalize();
        assert!(g.deleted, "两个状态都没了的行应当成为墓碑");

        // ★ 「只追更不收藏」是**合法**状态，不许被 normalize 改动
        let mut h = fav("z", 1, false);
        h.favorited = false;
        h.following = true;
        h.normalize();
        assert!(!h.deleted, "只追更不收藏必须保持存活");
        assert!(h.following && !h.favorited);
    }

    /// ★ `pushed` 的语义必须是「本轮真正要推的量」，而不是「合并结果的条数」。
    ///
    /// 否则每次同步都报同一个数字（文件里总共多少条），
    /// 用户会以为一直在重传 —— 这正是实测中发现并修掉的问题。
    #[test]
    fn pushed_counts_only_genuinely_new_or_newer() {
        // 复现 sync_favorites 里 pushed 的计算口径
        fn count_pushed(merged: &[Favorite], remote_had: &[Favorite]) -> usize {
            let remote_keys: std::collections::HashSet<String> =
                remote_had.iter().map(|f| f.key.clone()).collect();
            let remote_updated: std::collections::HashMap<String, i64> =
                remote_had.iter().map(|f| (f.key.clone(), f.updated_at)).collect();
            merged
                .iter()
                .filter(|m| match remote_keys.contains(&m.key) {
                    false => true,
                    true => remote_updated.get(&m.key).copied().unwrap_or(i64::MIN) < m.updated_at,
                })
                .count()
        }

        // 场景一：本地无新增，远端已全部有且一样旧 → 应推 0
        let remote = vec![fav("a", 100, false), fav("b", 200, false)];
        let merged = merge_lww(remote.clone(), remote.clone(), |f| f.key.clone(), |f| f.updated_at);
        assert_eq!(count_pushed(&merged.items, &remote), 0, "无变化时不应报告推送");

        // 场景二：本地新增一条 → 应推 1
        let local2 = vec![fav("a", 100, false), fav("b", 200, false), fav("c", 300, false)];
        let merged2 = merge_lww(local2, remote.clone(), |f| f.key.clone(), |f| f.updated_at);
        assert_eq!(count_pushed(&merged2.items, &remote), 1);

        // 场景三：本地把 a 改新了 → 也应推 1
        let local3 = vec![fav("a", 999, false), fav("b", 200, false)];
        let merged3 = merge_lww(local3, remote.clone(), |f| f.key.clone(), |f| f.updated_at);
        assert_eq!(count_pushed(&merged3.items, &remote), 1);

        // 场景四：全空远端 → 全部都要推
        let merged4 = merge_lww(remote.clone(), vec![], |f| f.key.clone(), |f| f.updated_at);
        assert_eq!(count_pushed(&merged4.items, &[]), 2);
    }

    /// `pulled` 只算「本地原本没有」的条目
    #[test]
    fn pulled_counts_only_new_to_local() {
        let local = vec![fav("a", 100, false)];
        let remote = vec![fav("a", 100, false), fav("b", 200, false), fav("c", 300, false)];
        let merged = merge_lww(local.clone(), remote, |f| f.key.clone(), |f| f.updated_at);

        let local_keys: std::collections::HashSet<String> =
            local.iter().map(|f| f.key.clone()).collect();
        let pulled = merged.items.iter().filter(|f| !local_keys.contains(&f.key)).count();
        assert_eq!(pulled, 2, "只有 b、c 是本地新增");
    }

    // ══════════════ 保留清理（契约 §5）：这里错一次就是删用户的文件 ══════════════

    fn snap(name: &str) -> RemoteEntry {
        RemoteEntry {
            name: name.into(),
            bytes: 100,
            modified_ms: 0,
        }
    }

    /// ★★ 安全护栏：**非** `dsh-backup-*.zip` 的文件永远不进待删名单
    ///
    /// # 这是整个任务里最危险的一段代码
    ///
    /// `snapshots_to_prune` 的返回值会被逐条 `delete` 到**用户的云盘**上。
    /// 用户在同一个目录里放别的东西是完全正常的 —— 自述文件、别的软件的
    /// 备份、随手同步上去的照片。一旦名字过滤写松了，那些文件会被**静默删除**，
    /// 而用户根本不会把「云盘少了个文件」和「播放器自动备份」联系起来。
    ///
    /// 所以护栏**两侧都测**：正例可删、反例永不出现。
    #[test]
    fn prune_never_touches_non_snapshot_names() {
        let entries = vec![
            snap("dsh-backup-pc-20260929-101112.zip"),      // 快照（新）
            snap("dsh-backup-pc-20260928-090000.zip"),      // 快照（旧）
            snap("README.txt"),                             // 别人的文件
            snap("my-photos.zip"),                          // 别人的 zip
            snap("dsh-backup-pc-20260929-101112.zip.bak"),  // 后缀多了一截
            snap("old-dsh-backup-x.zip"),                   // 前缀不对
            snap("dsh-backup-.zip"),                        // 空名字（见下面的边界用例）
            snap("dsh-backup-x.ZIP"),                       // 大小写不同
        ];

        // 无论保留几份，待删名单里**只能**出现合规快照名
        for retain in [0u32, 1, 2, 3, 10, 100] {
            for name in snapshots_to_prune(&entries, retain) {
                assert!(
                    is_snapshot_name(&name),
                    "retain={retain} 时待删名单混进了非快照文件: {name}"
                );
            }
        }

        // retain=1 ⇒ 只删旧的那份快照，其余 6 个文件一个都不动
        assert_eq!(
            snapshots_to_prune(&entries, 1),
            vec!["dsh-backup-pc-20260928-090000.zip".to_string()],
            "除最新快照外只应删旧快照"
        );

        // retain=2 ⇒ 两份都在保留范围内 ⇒ 什么都不删
        assert!(
            snapshots_to_prune(&entries, 2).is_empty(),
            "两份快照都在保留范围内时不该删任何东西"
        );
    }

    /// ★ `retainCount = 0` 的下限：**至少留 1 份**
    ///
    /// # 为什么不做成「0 = 一份都不留」
    ///
    /// 字面实现（`skip(0)`）会把这**刚刚上传成功**的那份也删掉：
    /// ```text
    /// 用户点「立即备份」 → 上传成功 → 清理顺手删掉 → 提示「备份成功」
    /// 云盘上却一份都没有 —— 而且自动备份每小时跑一次，
    /// 每次都删得干干净净，用户直到需要恢复时才发现
    /// ```
    /// 所以下限取 1：设 0 等价于设 1，**永不出现零份**。
    /// 想关掉自动整包备份应该用 `autoBackupIntervalMinutes = 0`（契约 §6）。
    #[test]
    fn prune_keeps_at_least_one_even_with_zero_retain() {
        let entries = vec![
            snap("dsh-backup-a-20260929-010101.zip"),
            snap("dsh-backup-a-20260928-010101.zip"),
            snap("dsh-backup-a-20260927-010101.zip"),
        ];

        // 0 与 1 必须**完全等价** —— 这就是「下限」的定义
        assert_eq!(
            snapshots_to_prune(&entries, 0),
            snapshots_to_prune(&entries, 1)
        );

        let doomed = snapshots_to_prune(&entries, 0);
        assert_eq!(doomed.len(), 2, "3 份里应只留 1 份");
        assert!(
            !doomed.contains(&"dsh-backup-a-20260929-010101.zip".to_string()),
            "留下的必须是**最新**的那份（名字降序的第一条）: {doomed:?}"
        );
        assert!(doomed.contains(&"dsh-backup-a-20260928-010101.zip".to_string()));
        assert!(doomed.contains(&"dsh-backup-a-20260927-010101.zip".to_string()));

        // 空的远端目录 ⇒ 删不掉任何东西（首次使用）
        assert!(snapshots_to_prune(&[], 0).is_empty());
    }

    /// `is_snapshot_name` 的边界：前缀 + **非空名字** + 后缀
    ///
    /// `dsh-backup-.zip` 这种壳必须被判为**不是**快照 —— 否则保留清理
    /// 会真的去 `DELETE` 一个不存在（或更糟：别人正好叫这个名）的文件。
    #[test]
    fn is_snapshot_name_requires_non_empty_middle() {
        // 正例
        assert!(is_snapshot_name("dsh-backup-pc-20260929-101112.zip"));
        assert!(
            is_snapshot_name("dsh-backup-20260929-101112.zip"),
            "device_id 为空时 backup::default_backup_name 会产出这种退化名，它仍是快照"
        );
        assert!(is_snapshot_name("dsh-backup-\u{5ba2}\u{5385}.zip"), "中文设备名合法");

        // 反例
        assert!(!is_snapshot_name("dsh-backup-.zip"), "中间是空的，不是文件名");
        assert!(!is_snapshot_name("dsh-backup-"));
        assert!(!is_snapshot_name(".zip"));
        assert!(!is_snapshot_name("dsh-backup-x.zip.tmp"));
        assert!(!is_snapshot_name("dsh-backup-x.ZIP"), "后缀大小写敏感");
        assert!(!is_snapshot_name("backup-x.zip"));
        assert!(!is_snapshot_name(""));
    }

    /// ★ 内部签名**绝不能**出现在设置页拿到的 JSON 里（契约 §2）
    ///
    /// `lastSignature` / `lastBackupSignature` 是自动循环判断「本地变了没有」
    /// 的内部状态。它们漏出去的**症状极轻**：Dart 侧只是多两个没人读的键，
    /// 不报错、不崩 —— 所以只能靠这个单测锁住（人工 review 很容易看漏）。
    #[test]
    fn public_json_hides_internal_signatures() {
        let mut s = SyncSettings::default();
        s.base_url = "https://dav.example.com/dav/x".into();
        s.username = "me@example.com".into();
        s.last_signature = "favorites:3:99|following:0:0|progress:1:5".into();
        s.last_backup_signature = "favorites:3:100|following:0:0|progress:1:5".into();

        let v = s.to_public_json(true);
        let text = v.to_string();
        assert!(!text.contains("lastSignature"), "内部字段漏出: {text}");
        assert!(!text.contains("lastBackupSignature"), "内部字段漏出: {text}");
        assert!(!text.contains("favorites:3:99"), "内部签名的**值**也漏出了: {text}");

        // 该有的字段一个都不能少 —— Dart 侧 `SyncSettings.fromJson` 按名字读
        for k in [
            "connected",
            "baseUrl",
            "username",
            "remoteDir",
            "retainCount",
            "autoEnabled",
            "autoIntervalMinutes",
            "autoOnChange",
            "autoBackupIntervalMinutes",
            "lastBackupAt",
            "lastSyncAt",
        ] {
            assert!(v.get(k).is_some(), "缺少字段 {k}: {text}");
        }
        assert_eq!(v["connected"], serde_json::json!(true));
        assert_eq!(v["retainCount"], serde_json::json!(10), "默认保留 10 份");
        assert_eq!(v["autoIntervalMinutes"], serde_json::json!(30));
        assert_eq!(v["autoBackupIntervalMinutes"], serde_json::json!(1440));
    }

    /// `load_settings` 对**任何**输入都不能失败（契约 §3.1）
    ///
    /// 一旦它返回 Err，设置页就打不开了 —— 用户连「重新配置」都做不到，
    /// 只能去删文件。三种坏输入各测一次。
    #[test]
    fn load_settings_never_fails_on_broken_input() {
        let dir = std::env::temp_dir().join(format!("dsh-sync-cfg-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let f = dir.join(SYNC_SETTINGS_FILE);

        // ① 文件不存在 → 全默认
        let _ = std::fs::remove_file(&f);
        let s = load_settings(&dir);
        assert_eq!(s.retain_count, 10);
        assert_eq!(s.auto_interval_minutes, 30);
        assert!(s.auto_on_change, "默认应在数据变动时同步");
        assert_eq!(s.auto_backup_interval_minutes, 1440, "默认一天整包一次");
        assert!(!s.auto_enabled, "自动同步默认关（要用户明确打开）");
        assert!(s.base_url.is_empty() && s.username.is_empty());

        // ② 内容不是 JSON → 回退默认（不 panic、不 Err）
        std::fs::write(&f, b"not json at all").unwrap();
        assert_eq!(load_settings(&dir).retain_count, 10, "坏文件必须回退默认值");

        // ③ 是 JSON 但缺字段 → 缺的取默认，**已有的必须保住**
        std::fs::write(
            &f,
            br#"{"baseUrl":"https://dav.example.com/dav/x","retainCount":3}"#,
        )
        .unwrap();
        let s3 = load_settings(&dir);
        assert_eq!(
            s3.base_url, "https://dav.example.com/dav/x",
            "已有字段不能被默认值冲掉"
        );
        assert_eq!(s3.retain_count, 3);
        assert_eq!(s3.auto_interval_minutes, 30, "缺的字段取默认");

        // ④ 存回来再读，值必须一模一样（重启后要能接着用）
        let mut s4 = load_settings(&dir);
        s4.auto_enabled = true;
        s4.auto_interval_minutes = 45;
        s4.last_backup_signature = "sig-1".into();
        save_settings(&dir, &s4).expect("写盘");
        let back = load_settings(&dir);
        assert!(back.auto_enabled);
        assert_eq!(back.auto_interval_minutes, 45);
        assert_eq!(back.last_backup_signature, "sig-1");
        assert_eq!(back.base_url, s4.base_url);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
