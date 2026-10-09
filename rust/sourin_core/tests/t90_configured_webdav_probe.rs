//! T90 — 用户**已配置**的 WebDAV（坚果云）真机实测 + 进度同步往返
//!
//! # 为什么单独写这一个（与 t76 / zz_t7 的区别）
//!
//! ```text
//! t76_webdav_e2e.rs       需要 T76_DAV_URL 环境变量 ⇒ 本机**没有** ⇒ 从不运行
//! zz_t7_jianguoyun_probe  需要 T7_DAV_URL 环境变量 ⇒ 本机**没有** ⇒ 从不运行
//! ★ 本文件（T90）         直接从**系统钥匙串**读用户已经配好的凭据
//! ```
//!
//! Owner 原话（2026-10-09）：
//! > 还有,我配置的webdav也没有实测,记得跑一下实测
//! > 然后这个播放记录如果有网的话,也要同步到webdav和本地的
//!
//! 前两个探针都因为「环境变量没设」而从未真正跑过 —— 这就是「没有实测」的真相。
//! 本文件把「凭据从哪来」换成**用户真实配置**，于是它能在本机真的跑起来。
//!
//! # 安全（三条，逐条与仓库的只读纪律对齐）
//!
//! ```text
//! ① **只读钥匙串**：只调 `webdav_credential::get("webdav")`，
//!    从不调 `configure_webdav` / `webdav_credential::set` ⇒ 用户的密码一个字节都不改。
//! ② **绝不碰 `%APPDATA%\app.sourin.player`**：
//!    数据目录用 `.probe/` 下每次运行**唯一**的临时目录（AppState::bootstrap 到那里）。
//! ③ **远端子目录唯一**：`sourin-t90-{nanos}` ⇒ 不覆盖用户云盘上任何已有文件；
//!    跑完删掉本次写的文件（G 段）。
//! ```
//!
//! # 覆盖的链路（对齐 Owner 的两条要求）
//!
//! ```text
//! A 配置   用户已配的 base_url / username / remote_dir 真能连上（test()）
//!          + 阳性对照：错密码必须被服务器拒绝（证明认证真的生效）
//! B 本地上传 设备 A 落一条**播放进度** → sync_progress() → PUT 到 progress.jsonl
//! C 云端下载 设备 B（另一个隔离数据目录）sync_progress() → GET 回来
//! D 恢复     设备 B 的库里真的出现那条进度，且**字段逐项相等**
//! E 播放记录 ★ Owner 第二条的直接判据：
//!            进度（position/duration/finished/episode_id）往返后**逐项一致**
//! F 幂等     设备 A 再同步一次：pushed=0（没有变动就不该重写远端）
//! G 清理     删掉本次写的远端文件
//! ```
use sourin_core::state::AppState;
use sourin_core::store::Progress;
use sourin_core::sync::webdav::{SyncBackend, WebdavBackend};
use sourin_core::sync::{SyncEngine, WebdavConfig};

const KEY: &str = "t90:progress-roundtrip";
const REMOTE_FILE: &str = "data/progress.jsonl";

// ───────────────────────────── 凭据 / 脱敏 ─────────────────────────────

struct Creds {
    url: String,
    user: String,
    pass: String,
    remote_dir: String,
}

impl Creds {
    /// 把账号与密码（以及邮箱 @ 前的本地部分）从任何将要打印的字符串里抹掉
    fn redact(&self, s: &str) -> String {
        let mut out = s
            .replace(&self.pass, "<redacted>")
            .replace(&self.user, "<redacted>");
        if let Some(local) = self.user.split('@').next() {
            if local.len() >= 3 {
                out = out.replace(local, "<redacted>");
            }
        }
        out
    }
}

/// 读**用户真实配置** —— 唯一来源是磁盘上的 sync-settings.json + 系统钥匙串。
///
/// ⚠️ 这里**不读环境变量**：环境变量正是 t76 / zz_t7 从未跑起来的原因。
fn read_user_config() -> Result<Creds, String> {
    let appdata = std::env::var("APPDATA")
        .map_err(|_| "APPDATA 未设置（本探针只在 Windows 真机上跑）".to_string())?;
    let dir = std::path::PathBuf::from(appdata).join("app.sourin.player");
    let f = dir.join("sync-settings.json");
    if !f.exists() {
        return Err(format!("用户没配过云盘：{} 不存在", f.display()));
    }
    let s = sourin_core::sync::load_settings(&dir);
    if s.base_url.is_empty() || s.username.is_empty() {
        return Err("sync-settings.json 里 base_url / username 为空（已断开）".to_string());
    }
    let pass = sourin_core::sync::webdav_credential::get("webdav")
        .filter(|p| !p.is_empty())
        .ok_or_else(|| "钥匙串里没有 webdav 密码（服务名 dsh-media-client-sync）".to_string())?;
    Ok(Creds {
        url: s.base_url,
        user: s.username,
        pass,
        remote_dir: s.remote_dir,
    })
}

fn work_base() -> std::path::PathBuf {
    let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join(".probe");
    std::fs::create_dir_all(&p).ok();
    p
}

// ───────────────────────────── 报告 ─────────────────────────────

struct Report {
    pass: u32,
    fail: u32,
}

impl Report {
    fn new() -> Self {
        Self { pass: 0, fail: 0 }
    }
    fn crit(&mut self, name: &str, ok: bool, detail: &str) {
        if ok {
            self.pass += 1;
            println!("[T90]   PASS  {name}  | {detail}");
        } else {
            self.fail += 1;
            println!("[T90]   FAIL  {name}  | {detail}");
        }
    }
    fn finish(&self) {
        println!("[T90] RESULT pass={} fail={}", self.pass, self.fail);
    }
}

// ───────────────────────────── 主流程 ─────────────────────────────

#[tokio::test]
#[ignore = "打真实 WebDAV（用户已配的坚果云）；凭据来自钥匙串，不读环境变量"]
async fn t90_configured_webdav_and_progress_roundtrip() {
    let creds = match read_user_config() {
        Ok(c) => c,
        Err(e) => {
            println!("[T90]   FAIL FATAL — {e}");
            println!("[T90] RESULT pass=0 fail=1");
            panic!("{e}");
        }
    };
    let mut r = Report::new();

    let tag = chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0);
    // ★ 每次运行一个**唯一**的远端子目录 ⇒ 绝不覆盖用户云盘上任何东西
    let remote_dir = format!("sourin-t90-{tag}");

    let cfg = WebdavConfig {
        base_url: creds.url.clone(),
        username: creds.user.clone(),
        password: creds.pass.clone(),
        remote_dir: remote_dir.clone(),
    };

    println!("[T90] ==== T90 用户已配 WebDAV 真机实测 ====");
    println!("[T90] base_url   = {}", creds.redact(&creds.url));
    println!("[T90] username   = {}", creds.redact(&creds.user));
    println!("[T90] remote_dir = {}（用户配置）+ {remote_dir}（本次隔离子目录）", creds.remote_dir);
    println!("[T90] 密码长度   = {} 字节（不回显）", creds.pass.len());

    // ───────── A. 连通性 + 阳性对照 ─────────
    let base = work_base();
    let dir_a = base.join(format!("t90-a-{tag}"));
    let dir_b = base.join(format!("t90-b-{tag}"));
    for d in [&dir_a, &dir_b] {
        if let Err(e) = std::fs::create_dir_all(d) {
            println!("[T90]   FAIL FATAL — create {}: {e}", d.display());
            println!("[T90] RESULT pass=0 fail=1");
            panic!("create work dir");
        }
    }
    println!("[T90] data_dir A = {}", dir_a.display());
    println!("[T90] data_dir B = {}", dir_b.display());

    let st_a = match AppState::bootstrap(dir_a.clone()).await {
        Ok(s) => s,
        Err(e) => {
            println!("[T90]   FAIL FATAL — bootstrap(A): {}", creds.redact(&e));
            println!("[T90] RESULT pass=0 fail=1");
            panic!("bootstrap A");
        }
    };
    let st_b = match AppState::bootstrap(dir_b.clone()).await {
        Ok(s) => s,
        Err(e) => {
            println!("[T90]   FAIL FATAL — bootstrap(B): {}", creds.redact(&e));
            println!("[T90] RESULT pass=0 fail=1");
            panic!("bootstrap B");
        }
    };

    let engine_a = match SyncEngine::new_webdav(cfg.clone(), st_a.db.clone(), st_a.device_id.clone())
    {
        Ok(e) => e,
        Err(e) => {
            println!("[T90]   FAIL FATAL — new_webdav(A): {}", creds.redact(&e));
            println!("[T90] RESULT pass=0 fail=1");
            panic!("new_webdav A");
        }
    };
    let engine_b = match SyncEngine::new_webdav(cfg.clone(), st_b.db.clone(), st_b.device_id.clone())
    {
        Ok(e) => e,
        Err(e) => {
            println!("[T90]   FAIL FATAL — new_webdav(B): {}", creds.redact(&e));
            println!("[T90] RESULT pass=0 fail=1");
            panic!("new_webdav B");
        }
    };

    let prep = engine_a.prepare().await;
    r.crit(
        "A1 prepare() 逐级 MKCOL 成功（用户配置的路径下能建目录）",
        prep.is_ok(),
        &creds.redact(&format!("{prep:?}")),
    );

    let ping = engine_a.test().await;
    let ping_txt = match &ping {
        Ok(s) => s.clone(),
        Err(e) => creds.redact(e),
    };
    r.crit(
        "A2 ★ test() 自检通过（用户配的 WebDAV 真的连得上）",
        matches!(&ping, Ok(s) if s == "连接正常"),
        &ping_txt,
    );

    // 阳性对照：仪器必须对错凭据有反应
    let bad_cfg = WebdavConfig {
        password: "t90-definitely-not-the-password".to_string(),
        ..cfg.clone()
    };
    let bad_engine =
        SyncEngine::new_webdav(bad_cfg, st_a.db.clone(), st_a.device_id.clone()).unwrap();
    let bad = bad_engine.test().await;
    let bad_txt = match &bad {
        Ok(s) => s.clone(),
        Err(e) => creds.redact(e),
    };
    r.crit(
        "A3 阳性对照：错密码 ⇒ test() 是 Err（认证真由服务器把关）",
        bad.is_err(),
        &bad_txt,
    );

    // ───────── B. 设备 A 落一条**播放进度**并上传 ─────────
    //
    // ★ 这一条是 Owner 第二条「播放记录要同步到 webdav」的直接判据。
    //   字段刻意给全（position/duration/finished/episode_id/episode_title），
    //   这样 D 段能逐项比对，而不是只比一个 key。
    let now_ms = chrono::Utc::now().timestamp_millis();
    let p = Progress {
        key: KEY.to_string(),
        provider: "t90-provider".to_string(),
        native_id: "t90-native-1".to_string(),
        title: "T90 播放记录往返".to_string(),
        cover: Some("https://example.com/t90.jpg".to_string()),
        episode_id: Some("ep-07".to_string()),
        episode_title: Some("第07集".to_string()),
        position: 1234,
        duration: 5678,
        finished: false,
        updated_at: now_ms,
    };
    let up_local = st_a.db.upsert_progress(&p);
    r.crit(
        "B1 设备 A 本地落一条播放进度（upsert_progress）",
        up_local.is_ok(),
        &format!("{:?}", up_local.err()),
    );

    let sum_a = engine_a.sync_progress().await;
    let sum_a_txt = match &sum_a {
        Ok(s) => format!("pushed={} pulled={} conflicts={}", s.pushed, s.pulled, s.conflicts),
        Err(e) => creds.redact(e),
    };
    r.crit(
        "B2 ★ sync_progress() 上传成功（播放记录真的推到了 webdav）",
        sum_a.is_ok(),
        &sum_a_txt,
    );
    if let Ok(s) = &sum_a {
        r.crit(
            "B3 本次确实推了东西（pushed >= 1，不是空转）",
            s.pushed >= 1,
            &format!("pushed={}", s.pushed),
        );
    }

    // ───────── C/D/E. 设备 B 拉回来并逐项比对 ─────────
    let sum_b = engine_b.sync_progress().await;
    let sum_b_txt = match &sum_b {
        Ok(s) => format!("pushed={} pulled={} conflicts={}", s.pushed, s.pulled, s.conflicts),
        Err(e) => creds.redact(e),
    };
    r.crit(
        "C1 ★ 设备 B sync_progress() 拉取成功（云端读得回来）",
        sum_b.is_ok(),
        &sum_b_txt,
    );

    let got = st_b.db.get_progress(KEY).ok().flatten();
    r.crit(
        "D1 ★ 设备 B 库里出现这条进度（真的落库了）",
        got.is_some(),
        &format!("{:?}", got.as_ref().map(|g| g.key.clone())),
    );

    if let Some(g) = &got {
        // E 段：Owner 第二条的核心 —— 播放记录必须**逐项**一致
        r.crit(
            "E1 provider 一致",
            g.provider == p.provider,
            &format!("{} vs {}", g.provider, p.provider),
        );
        r.crit(
            "E2 native_id 一致",
            g.native_id == p.native_id,
            &format!("{} vs {}", g.native_id, p.native_id),
        );
        r.crit(
            "E3 title 一致",
            g.title == p.title,
            &format!("{} vs {}", g.title, p.title),
        );
        r.crit(
            "E4 cover 一致",
            g.cover == p.cover,
            &format!("{:?} vs {:?}", g.cover, p.cover),
        );
        r.crit(
            "E5 ★ episode_id 一致（换集后同步的集号不能丢）",
            g.episode_id == p.episode_id,
            &format!("{:?} vs {:?}", g.episode_id, p.episode_id),
        );
        r.crit(
            "E6 ★ episode_title 一致",
            g.episode_title == p.episode_title,
            &format!("{:?} vs {:?}", g.episode_title, p.episode_title),
        );
        r.crit(
            "E7 ★ position 一致（看到第几秒必须一模一样）",
            g.position == p.position,
            &format!("{} vs {}", g.position, p.position),
        );
        r.crit(
            "E8 ★ duration 一致",
            g.duration == p.duration,
            &format!("{} vs {}", g.duration, p.duration),
        );
        r.crit(
            "E9 finished 一致",
            g.finished == p.finished,
            &format!("{} vs {}", g.finished, p.finished),
        );
        r.crit(
            "E10 updated_at 一致（LWW 的判据就是它）",
            g.updated_at == p.updated_at,
            &format!("{} vs {}", g.updated_at, p.updated_at),
        );
    }

    // ───────── F. 幂等：A 再同步一次不该重写 ─────────
    let sum_a2 = engine_a.sync_progress().await;
    let (ok2, txt2) = match &sum_a2 {
        Ok(s) => (s.pushed == 0, format!("pushed={}（应为 0）", s.pushed)),
        Err(e) => (false, creds.redact(e)),
    };
    r.crit("F1 设备 A 再同步：pushed == 0（幂等，没白写云端）", ok2, &txt2);

    // ───────── G. 清理 ─────────
    let backend = WebdavBackend::new(cfg.clone()).unwrap();
    let del = backend.delete(REMOTE_FILE).await;
    println!("[T90] 清理 {REMOTE_FILE}: {del:?}（远端子目录 {remote_dir} 里的临时文件）");
    let list = backend.list("data").await;
    println!("[T90] 清理后 data/ 剩余: {:?}", list.map(|v| v.len()));

    // 本地临时目录也清掉
    for d in [&dir_a, &dir_b] {
        let _ = std::fs::remove_dir_all(d);
    }

    r.finish();
    if r.fail > 0 {
        panic!("T90 有 {} 条判据失败", r.fail);
    }
}