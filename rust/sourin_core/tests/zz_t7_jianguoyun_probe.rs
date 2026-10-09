//! T7 — 坚果云 WebDAV **全链路实测**（真服务器 / 真凭据 / 真往返）
//!
//! # 为什么 \`#[ignore]\`
//!
//! 凭据只从环境变量读，裸 \`cargo test\` 必须保持绿。
//!
//! # 环境变量（三个都必需，缺一个 = 硬 FAIL，绝不静默跳过）
//!
//! \`\`\`text
//! T7_DAV_URL    WebDAV 根地址，例如 https://dav.jianguoyun.com/dav/
//! T7_DAV_USER   账号
//! T7_DAV_PASS   应用密码
//! T7_TMPDIR     可选：隔离数据目录的父目录（默认 <repo>/.probe）
//! \`\`\`
//!
//! # 安全
//!
//! * 本文件**从不**调用 \`configure_webdav\` ⇒ 系统钥匙串
//!   （服务名 \`dsh-media-client-sync\`，里面存着 Owner 的真实凭据）**零写入**。
//! * **从不**碰 \`%APPDATA%\app.sourin.player\` —— 两处 \`AppState::bootstrap\`
//!   用的都是 \`.probe\` 下每次运行唯一的临时目录。
//! * 所有打印都过 \`redact()\`：账号与密码（含邮箱 @ 前的本地部分）
//!   在输出里一律替换成 \`<redacted>\`。
//!
//! # 覆盖的链路
//!
//! \`\`\`text
//! A 配置    prepare() 逐级 MKCOL 真建目录 → test() 自检
//!           + 阳性对照：错密码必须被服务器拒绝
//! B 上传    设备 A 落一条收藏 → sync_favorites() → PUT
//! C 下载    设备 B（另一个隔离数据目录）sync_favorites() → GET
//! D 恢复    设备 B 的库里真的出现那条收藏，关键字段逐项相等
//! E 一致性  远端原始字节 逐字节相等 + 长度 + FNV-1a 读数
//! F 幂等    设备 A 再同步一次：pushed=0 且 ETag 未变 ⇒ 没有发生写入
//! G 清理    删掉本次写的远端文件，并确认目录已空
//! \`\`\`

use sourin_core::state::AppState;
use sourin_core::store::Favorite;
use sourin_core::sync::webdav::{SyncBackend, WebdavBackend};
use sourin_core::sync::{SyncEngine, WebdavConfig};
use std::path::{Path, PathBuf};

const FAV_KEY: &str = "t7:e2e-jianguoyun";
const REMOTE_FILE: &str = "data/favorites.jsonl";

// ───────────────────────────── 凭据 / 脱敏 ─────────────────────────────

struct Creds {
    url: String,
    user: String,
    pass: String,
}

impl Creds {
    /// 把账号与密码（以及邮箱 @ 前的本地部分）从任何将要打印的字符串里抹掉
    fn redact(&self, s: &str) -> String {
        let mut out = s.replace(&self.pass, "<redacted>").replace(&self.user, "<redacted>");
        if let Some(local) = self.user.split('@').next() {
            if local.len() >= 3 {
                out = out.replace(local, "<redacted>");
            }
        }
        out
    }
}

fn read_envs() -> Result<Creds, String> {
    let get = |k: &str| {
        std::env::var(k)
            .ok()
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
    };
    let url = get("T7_DAV_URL");
    let user = get("T7_DAV_USER");
    let pass = get("T7_DAV_PASS");
    let (hu, huser, hp) = (url.is_some(), user.is_some(), pass.is_some());
    match (url, user, pass) {
        (Some(u), Some(n), Some(p)) => Ok(Creds {
            url: u,
            user: n,
            pass: p,
        }),
        _ => Err(format!(
            "必需环境变量缺失 — T7_DAV_URL set={hu} T7_DAV_USER set={huser} \
             T7_DAV_PASS set={hp}。本测试打真服务器，**绝不静默跳过**。"
        )),
    }
}

// ───────────────────────────── 小工具 ─────────────────────────────

struct Report {
    pass: usize,
    fail: usize,
}

impl Report {
    fn new() -> Self {
        Report { pass: 0, fail: 0 }
    }

    fn crit(&mut self, label: &str, ok: bool, detail: &str) {
        if ok {
            self.pass += 1;
            println!("[T7]   OK   {label}");
        } else {
            self.fail += 1;
            println!("[T7]   FAIL {label} — {detail}");
        }
    }
}

/// FNV-1a 64：只为打印一个可人工比对的短读数（不是密码学哈希）
fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        h ^= *b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

fn work_base() -> PathBuf {
    if let Ok(v) = std::env::var("T7_TMPDIR") {
        let t = v.trim();
        if !t.is_empty() {
            return PathBuf::from(t);
        }
    }
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join(".probe")
}

fn sample_favorite(now: i64) -> Favorite {
    Favorite {
        key: FAV_KEY.to_string(),
        provider: "t7".to_string(),
        native_id: "e2e-jianguoyun-1".to_string(),
        title: "T7 坚果云全链路实测".to_string(),
        cover: None,
        group_name: None,
        kind: "series".to_string(),
        favorited: true,
        following: true,
        last_episode_count: 12,
        last_episode_title: Some("第 12 集".to_string()),
        unread_count: 3,
        last_checked_at: now,
        last_update_at: now,
        note: Some("t7-e2e".to_string()),
        created_at: now,
        updated_at: now,
        deleted: false,
    }
}

// ───────────────────────────── 主流程 ─────────────────────────────

#[tokio::test]
#[ignore = "打真实 WebDAV 服务器（坚果云），凭据由 T7_DAV_* 环境变量提供"]
async fn t7_jianguoyun_end_to_end() {
    let creds = match read_envs() {
        Ok(c) => c,
        Err(e) => {
            println!("[T7]   FAIL FATAL — {e}");
            println!("[T7] RESULT pass=0 fail=1");
            panic!("{e}");
        }
    };
    let mut r = Report::new();

    let tag = chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0);
    // ★ 每次运行一个**唯一**的远端子目录 ⇒ 绝不覆盖用户已有的任何东西
    let remote_dir = format!("t7-e2e-{tag}");

    let cfg = WebdavConfig {
        base_url: creds.url.clone(),
        username: creds.user.clone(),
        password: creds.pass.clone(),
        remote_dir: remote_dir.clone(),
    };

    let root = cfg.normalize().unwrap_or_default();
    println!("[T7] ==== T7 坚果云 WebDAV 全链路实测 ====");
    println!("[T7] remote root = {}", creds.redact(&root));
    println!("[T7] remote_dir  = {remote_dir}");

    // ───────── A. 配置：建目录 + 自检 + 阳性对照 ─────────
    let base = work_base();
    let dir_a = base.join(format!("sourin-t7-a-{tag}"));
    let dir_b = base.join(format!("sourin-t7-b-{tag}"));
    for d in [&dir_a, &dir_b] {
        if let Err(e) = std::fs::create_dir_all(d) {
            println!("[T7]   FAIL FATAL — create {}: {e}", d.display());
            println!("[T7] RESULT pass=0 fail=1");
            panic!("create work dir");
        }
    }
    println!("[T7] data_dir A = {}", dir_a.display());
    println!("[T7] data_dir B = {}", dir_b.display());

    let st_a = match AppState::bootstrap(dir_a.clone()).await {
        Ok(s) => s,
        Err(e) => {
            println!("[T7]   FAIL FATAL — AppState::bootstrap(A): {}", creds.redact(&e));
            println!("[T7] RESULT pass=0 fail=1");
            panic!("bootstrap A");
        }
    };

    let engine_a = match SyncEngine::new_webdav(cfg.clone(), st_a.db.clone(), st_a.device_id.clone())
    {
        Ok(e) => e,
        Err(e) => {
            println!("[T7]   FAIL FATAL — new_webdav: {}", creds.redact(&e));
            println!("[T7] RESULT pass=0 fail=1");
            panic!("new_webdav");
        }
    };

    let prep = engine_a.prepare().await;
    r.crit(
        "A1 prepare() 逐级 MKCOL 成功（远端目录真建出来了）",
        prep.is_ok(),
        &creds.redact(&format!("{prep:?}")),
    );

    let ping = engine_a.test().await;
    let ping_txt = match &ping {
        Ok(s) => s.clone(),
        Err(e) => creds.redact(e),
    };
    r.crit(
        "A2 test() 自检通过（读到的是「连接正常」）",
        matches!(&ping, Ok(s) if s == "连接正常"),
        &format!("{ping_txt}"),
    );

    // 阳性对照：仪器必须对错凭据有反应，否则「通过」可能只是因为它从不检查
    let bad_cfg = WebdavConfig {
        password: "t7-definitely-not-the-password".to_string(),
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
        "A3 阳性对照：错密码 ⇒ test() 是 Err（认证真的由服务器把关）",
        bad.is_err(),
        &format!("{bad_txt}"),
    );

    let backend = match WebdavBackend::new(cfg.clone()) {
        Ok(b) => b,
        Err(e) => {
            println!("[T7]   FAIL FATAL — WebdavBackend::new: {}", creds.redact(&e));
            println!("[T7] RESULT pass=0 fail=1");
            panic!("backend");
        }
    };

    // ───────── B. 上传 ─────────
    let now = chrono::Utc::now().timestamp_millis();
    let fav = sample_favorite(now);
    if let Err(e) = st_a.db.upsert_favorite(&fav) {
        println!("[T7]   FAIL FATAL — upsert_favorite: {}", creds.redact(&e));
        println!("[T7] RESULT pass=0 fail=1");
        panic!("upsert");
    }

    let sum_a = engine_a.sync_favorites().await;
    match &sum_a {
        Ok(s) => println!(
            "[T7] REPORT B sync#1(A) plane={} pulled={} pushed={} conflicts={}",
            s.plane, s.pulled, s.pushed, s.conflicts
        ),
        Err(e) => println!("[T7] REPORT B sync#1(A) ERR = {}", creds.redact(e)),
    }
    r.crit(
        "B1 设备 A sync_favorites() 成功，且 pushed==1 / pulled==0",
        matches!(&sum_a, Ok(s) if s.pushed == 1 && s.pulled == 0),
        &creds.redact(&format!("{sum_a:?}")),
    );

    let raw1 = backend.get(REMOTE_FILE).await;
    let (bytes1, etag1) = match &raw1 {
        Ok(Some((b, e))) => (b.clone(), e.clone()),
        other => {
            println!(
                "[T7]   FAIL B2 远端读不到刚上传的文件 — {}",
                creds.redact(&format!("{other:?}"))
            );
            println!("[T7] RESULT pass={} fail={}", r.pass, r.fail + 1);
            panic!("no remote file");
        }
    };
    r.crit(
        "B2 远端 data/favorites.jsonl 真的存在，且内容是刚上传的那条",
        String::from_utf8_lossy(&bytes1).contains(FAV_KEY),
        &format!("len={}", bytes1.len()),
    );
    println!(
        "[T7] REPORT B remote {} len={} bytes fnv1a64={:016x} etag={}",
        REMOTE_FILE,
        bytes1.len(),
        fnv1a64(&bytes1),
        creds.redact(&format!("{etag1:?}"))
    );

    // ───────── C. 下载：另一台设备（另一个隔离数据目录） ─────────
    let st_b = match AppState::bootstrap(dir_b.clone()).await {
        Ok(s) => s,
        Err(e) => {
            println!("[T7]   FAIL FATAL — AppState::bootstrap(B): {}", creds.redact(&e));
            println!("[T7] RESULT pass={} fail={}", r.pass, r.fail + 1);
            panic!("bootstrap B");
        }
    };
    let engine_b = match SyncEngine::new_webdav(cfg.clone(), st_b.db.clone(), st_b.device_id.clone())
    {
        Ok(e) => e,
        Err(e) => {
            println!("[T7]   FAIL FATAL — new_webdav(B): {}", creds.redact(&e));
            println!("[T7] RESULT pass={} fail={}", r.pass, r.fail + 1);
            panic!("new_webdav B");
        }
    };
    let sum_b = engine_b.sync_favorites().await;
    match &sum_b {
        Ok(s) => println!(
            "[T7] REPORT C sync#2(B) plane={} pulled={} pushed={} conflicts={}",
            s.plane, s.pulled, s.pushed, s.conflicts
        ),
        Err(e) => println!("[T7] REPORT C sync#2(B) ERR = {}", creds.redact(e)),
    }
    r.crit(
        "C1 设备 B sync_favorites() 成功，且 pulled==1 / pushed==0（真的下载了）",
        matches!(&sum_b, Ok(s) if s.pulled == 1 && s.pushed == 0),
        &creds.redact(&format!("{sum_b:?}")),
    );

    // ───────── D. 恢复：B 的本地库里逐字段核对 ─────────
    let restored = st_b.db.list_favorites(true).unwrap_or_default();
    let hit = restored.iter().find(|f| f.key == FAV_KEY);
    let same = hit
        .map(|f| {
            f.title == fav.title
                && f.provider == fav.provider
                && f.native_id == fav.native_id
                && f.updated_at == fav.updated_at
                && f.favorited == fav.favorited
                && f.following == fav.following
                && f.note == fav.note
                && !f.deleted
        })
        .unwrap_or(false);
    r.crit(
        "D1 设备 B 的本地库里出现该收藏，且 title/provider/native_id/updated_at/favorited/following/note 逐项相等",
        same,
        &creds.redact(&format!("{hit:?}")),
    );
    println!("[T7] REPORT D B 库内条数 = {}，命中 = {}", restored.len(), hit.is_some());

    // ───────── E. 往返一致性 ─────────
    let raw2 = backend.get(REMOTE_FILE).await;
    let (bytes2, _etag2) = match &raw2 {
        Ok(Some((b, e))) => (b.clone(), e.clone()),
        other => (Vec::new(), {
            println!("[T7]   WARN E1 二次读失败 {}", creds.redact(&format!("{other:?}")));
            None
        }),
    };
    r.crit(
        "E1 往返一致性：二次读回的远端字节与首次逐字节相同，且长度相等",
        bytes2 == bytes1 && bytes2.len() == bytes1.len(),
        &format!("len1={} len2={}", bytes1.len(), bytes2.len()),
    );
    println!(
        "[T7] REPORT E len1={} fnv1a64={:016x} | len2={} fnv1a64={:016x}",
        bytes1.len(),
        fnv1a64(&bytes1),
        bytes2.len(),
        fnv1a64(&bytes2)
    );

    // ───────── F. 幂等：内容没变时不该再写 ─────────
    let sum_a2 = engine_a.sync_favorites().await;
    match &sum_a2 {
        Ok(s) => println!(
            "[T7] REPORT F sync#3(A) plane={} pulled={} pushed={} conflicts={}",
            s.plane, s.pulled, s.pushed, s.conflicts
        ),
        Err(e) => println!("[T7] REPORT F sync#3(A) ERR = {}", creds.redact(e)),
    }
    r.crit(
        "F1 设备 A 再同步一次：pushed==0（内容逐字节相同 ⇒ 跳过 PUT）",
        matches!(&sum_a2, Ok(s) if s.pushed == 0),
        &creds.redact(&format!("{sum_a2:?}")),
    );
    let etag3 = backend.etag(REMOTE_FILE).await.unwrap_or(None);
    r.crit(
        "F2 该文件的 ETag 与 F 之前相同 ⇒ 确实没有发生写入",
        etag3 == etag1,
        &format!(
            "before={} after={}",
            creds.redact(&format!("{etag1:?}")),
            creds.redact(&format!("{etag3:?}"))
        ),
    );

    // ───────── G. 清理 ─────────
    let del = backend.delete(REMOTE_FILE).await;
    r.crit(
        "G1 远端文件删除成功（幂等接口）",
        del.is_ok(),
        &creds.redact(&format!("{del:?}")),
    );
    let after = backend.list("data").await.unwrap_or_default();
    r.crit(
        "G2 删除后 list(\"data\") 为空（清理干净，没给用户留垃圾）",
        after.is_empty(),
        &format!("left={:?}", after.iter().map(|e| e.name.clone()).collect::<Vec<_>>()),
    );

    println!("[T7] RESULT pass={} fail={}", r.pass, r.fail);
    assert_eq!(r.fail, 0, "T7 有 {0} 条判据未通过", r.fail);
}
