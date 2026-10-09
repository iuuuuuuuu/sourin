//! T77 — XML namespace-prefix agnosticism of the WebDAV Multi-Status parser.
//!
//! # The defect this test pins down
//!
//! XML namespace prefixes are **arbitrary**: `<d:response xmlns:d="DAV:">` and
//! `<D:response xmlns:D="DAV:">` are the *identical* XML Infoset. The shipped
//! parser sliced responses with hardcoded lowercase literals
//! (`"<d:response>"`, `"<response>"`, `"<d:getetag>"`), so a server that picks a
//! different prefix yields an empty listing.
//!
//! `wsgidav` — a real, independent, widely used Python WebDAV server — emits
//! UPPERCASE `<D:` prefixes. Measured through the crate's own public API, the
//! symptom is:
//!
//! ```text
//! list_snapshots() -> 0 entries   (while 2 snapshot files genuinely exist)
//! etag(path)       -> None        (so no If-Match => no lost-update detection)
//! ```
//!
//! An empty listing is not cosmetic: `list_snapshots()` feeds
//! `snapshots_to_prune()`, so retention silently stops pruning and cloud
//! backups accumulate forever, while the UI cheerfully reports success.
//!
//! # Why this test spawns two servers
//!
//! A negative reading is only evidence when the instrument is proven sensitive,
//! so the test carries its own positive control:
//!
//! * **UPPER** — `wsgidav` (real third-party server), uppercase `<D:` prefixes.
//! * **LOWER** — `.probe\t91_dav_server.py` (this project's own instrument),
//!   lowercase `<d:` prefixes. This is the *positive control*: the same code
//!   path must work here, so the test proves "both spellings work" rather than
//!   "we swapped which one is broken".
//!
//! Both servers are started by this test and stopped **by PID** (via the child
//! handle) in `Drop`. Nothing is ever killed by image name.
//!
//! # Safety
//!
//! * Never calls `configure_webdav` ⇒ the OS keychain (service
//!   `dsh-media-client-sync`, holding the Owner's real credential) is untouched.
//! * Never points at a real cloud account — both servers are `127.0.0.1`.
//! * All scratch state lives under an isolated `.probe\t77-run-<nanos>` dir.
//!
//! `#[ignore]`d on purpose: a bare `cargo test --release` must stay green with
//! no Python available. Drive it with:
//!
//! ```text
//! cargo test --release --test t77_dav_prefix -- --ignored --nocapture
//! ```
//!
//! Optional env: `T77_PYTHON` (default `python`), `T77_TMPDIR`.

use sourin_core::store::Db;
use sourin_core::sync::webdav::{SyncBackend, WebdavBackend};
use sourin_core::sync::{SyncEngine, WebdavConfig};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

const DAV_USER: &str = "u";
const DAV_PASS: &str = "p";

/// Two strictly increasing snapshot names. The `yyyyMMdd-HHmmss` field is fixed
/// width, so lexicographic order == chronological order unambiguously.
const SNAP_A: &str = "dsh-backup-t77-20260101-010101.zip";
const SNAP_B: &str = "dsh-backup-t77-20260101-020202.zip";
const SNAPS: [&str; 2] = [SNAP_A, SNAP_B];

/// A directory listing with `Depth: 1` holds the collection itself plus the two
/// files ⇒ exactly three `<...:response>` elements. Asserting this on the RAW
/// wire body is what makes a `0` from `list_snapshots()` a parser failure rather
/// than an empty directory.
const EXPECTED_RESPONSE_BLOCKS: usize = 3;

// ───────────────────────────── tiny reporter ─────────────────────────────

struct Report {
    pass: usize,
    fail: usize,
}

impl Report {
    fn new() -> Self {
        Report { pass: 0, fail: 0 }
    }

    /// ASCII markers on purpose: this output is captured through a Windows
    /// console redirect, and box-drawing glyphs do not survive every codepage.
    fn crit(&mut self, label: &str, ok: bool, detail: &str) {
        if ok {
            self.pass += 1;
            println!("[T77]   PASS  {label}");
        } else {
            self.fail += 1;
            println!("[T77]   FAIL  {label} -- {detail}");
        }
    }
}

// ───────────────────────────── paths / env ─────────────────────────────

fn python_exe() -> String {
    std::env::var("T77_PYTHON")
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| "python".to_string())
}

/// `rust\sourin_core` -> repo root -> `.probe`
fn probe_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join(".probe")
}

fn run_dir() -> PathBuf {
    let base = std::env::var("T77_TMPDIR")
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(probe_dir);
    base.join(format!(
        "t77-run-{}",
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
    ))
}

/// Two ports that were free a moment ago. Both listeners are held open until
/// BOTH ports are known, so the OS cannot hand back the same ephemeral port
/// twice (a real risk on Windows, which reuses recently-freed ports).
fn two_free_ports() -> (u16, u16) {
    let a = std::net::TcpListener::bind("127.0.0.1:0").expect("bind ephemeral port a");
    let b = std::net::TcpListener::bind("127.0.0.1:0").expect("bind ephemeral port b");
    let (pa, pb) = (
        a.local_addr().expect("local_addr a").port(),
        b.local_addr().expect("local_addr b").port(),
    );
    assert_ne!(pa, pb, "ephemeral allocator handed back the same port twice");
    drop(a);
    drop(b);
    (pa, pb)
}

// ───────────────────────────── server harness ─────────────────────────────

/// A server this test started. Stopped **by PID** (the child handle) on drop —
/// never by image name, which would risk other processes.
struct Server {
    label: String,
    port: u16,
    child: std::process::Child,
}

impl Drop for Server {
    fn drop(&mut self) {
        let pid = self.child.id();
        let _ = self.child.kill();
        let _ = self.child.wait();
        println!("[T77] stopped {} (pid {pid}, port {})", self.label, self.port);
    }
}

/// Spawn with stdout/stderr redirected **to files** (never pipes): a pipe can
/// deadlock once the server writes more than the pipe buffer, and files double
/// as evidence for the report.
fn spawn_to_log(program: &str, args: &[String], log: &Path) -> Result<std::process::Child, String> {
    let out = std::fs::File::create(log).map_err(|e| format!("create {}: {e}", log.display()))?;
    let err = out
        .try_clone()
        .map_err(|e| format!("clone handle for {}: {e}", log.display()))?;
    std::process::Command::new(program)
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::from(out))
        .stderr(std::process::Stdio::from(err))
        .spawn()
        .map_err(|e| format!("spawn {program} {args:?}: {e}"))
}

/// Block until the port accepts a TCP connection, or fail loudly.
async fn wait_port(port: u16, label: &str, timeout: Duration) -> Result<(), String> {
    let deadline = Instant::now() + timeout;
    loop {
        if std::net::TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "{label}: 127.0.0.1:{port} not accepting connections after {timeout:?}"
            ));
        }
        tokio::time::sleep(Duration::from_millis(150)).await;
    }
}

fn seed_snapshots(root: &Path) -> Result<PathBuf, String> {
    let snap_dir = root.join("backup").join("snapshots");
    std::fs::create_dir_all(&snap_dir)
        .map_err(|e| format!("create {}: {e}", snap_dir.display()))?;
    for (n, name) in SNAPS.iter().enumerate() {
        let body = format!("t77-snapshot-{n}");
        std::fs::write(snap_dir.join(name), body.as_bytes())
            .map_err(|e| format!("write {name}: {e}"))?;
    }
    Ok(snap_dir)
}

// ───────────────────────────── measurement helpers ─────────────────────────────

fn occ(hay: &str, needle: &str) -> usize {
    hay.matches(needle).count()
}

/// A raw `PROPFIND Depth: 1` straight to the server, bypassing the crate — this
/// is the instrument-sensitivity probe: it proves what the server *actually*
/// sent before we ask the parser anything.
async fn raw_propfind(url: &str) -> Result<(u16, String), String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .build()
        .map_err(|e| format!("build raw client: {e}"))?;
    let resp = client
        .request(reqwest::Method::from_bytes(b"PROPFIND").unwrap(), url)
        .basic_auth(DAV_USER, Some(DAV_PASS))
        .header("Depth", "1")
        .send()
        .await
        .map_err(|e| format!("raw PROPFIND {url}: {e}"))?;
    let code = resp.status().as_u16();
    let body = resp.text().await.unwrap_or_default();
    Ok((code, body))
}

fn head_chars(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

fn cfg_for(url: &str) -> WebdavConfig {
    WebdavConfig {
        base_url: url.to_string(),
        username: DAV_USER.to_string(),
        password: DAV_PASS.to_string(),
        // EMPTY on purpose: remote paths map 1:1 onto <root>\<path>, so the
        // snapshot files we seeded land exactly where the code looks for them.
        remote_dir: String::new(),
    }
}

// ───────────────────────────── the body ─────────────────────────────

async fn run_body(r: &mut Report) -> Result<(), String> {
    let py = python_exe();
    let work = run_dir();
    std::fs::create_dir_all(&work).map_err(|e| format!("create {}: {e}", work.display()))?;

    let upper_root = work.join("upper-root");
    let lower_root = work.join("lower-root");
    let upper_snaps = seed_snapshots(&upper_root)?;
    let lower_snaps = seed_snapshots(&lower_root)?;

    let (upper_port, lower_port) = two_free_ports();
    let upper_url = format!("http://127.0.0.1:{upper_port}");
    let lower_url = format!("http://127.0.0.1:{lower_port}");

    println!("[T77] ==== T77 WebDAV namespace-prefix ====");
    println!("[T77] python     = {py}");
    println!("[T77] work       = {}", work.display());
    println!("[T77] upper root = {}  ({upper_url})", upper_root.display());
    println!("[T77] lower root = {}  ({lower_url})", lower_root.display());

    // ─────────── A. instrument self-proof, BEFORE any measurement ───────────
    for (label, dir) in [("upper", &upper_snaps), ("lower", &lower_snaps)] {
        let present: Vec<&str> = SNAPS
            .iter()
            .copied()
            .filter(|n| dir.join(n).is_file())
            .collect();
        r.crit(
            &format!("A0 {label}: the 2 snapshot files exist on disk before measuring"),
            present.len() == SNAPS.len(),
            &format!("dir={} present={present:?}", dir.display()),
        );
    }

    // ─────────── start both servers ───────────
    //
    // ★ 阳性对照的仪器**已入库**（`tests/support/mini_dav_server.py`）。
    //   原先它住在 `.probe/t91_dav_server.py`，而 `.probe/` 在 .gitignore 里
    //   ⇒ 那个文件从没进过仓库 ⇒ 这条测试对**任何人**都必然红在
    //   「positive-control instrument missing」，永远跑不起来。
    let script = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("support")
        .join("mini_dav_server.py");
    if !script.is_file() {
        return Err(format!(
            "positive-control instrument missing: {} (expected this project's \
             lowercase-prefix WebDAV server)",
            script.display()
        ));
    }

    let upper_log = work.join("wsgidav.out.txt");
    let upper = spawn_to_log(
        &py,
        &[
            "-m".to_string(),
            "wsgidav.server.server_cli".to_string(),
            "--host=127.0.0.1".to_string(),
            format!("--port={upper_port}"),
            format!("--root={}", upper_root.display()),
            "--auth=anonymous".to_string(),
            "--server=cheroot".to_string(),
        ],
        &upper_log,
    )?;
    let upper = Server {
        label: "wsgidav (UPPERCASE <D:>)".to_string(),
        port: upper_port,
        child: upper,
    };
    println!("[T77] started {} pid {}", upper.label, upper.child.id());

    let lower_log = work.join("t91.out.txt");
    let lower = spawn_to_log(
        &py,
        &[
            script.display().to_string(),
            "--root".to_string(),
            lower_root.display().to_string(),
            "--port".to_string(),
            lower_port.to_string(),
            "--log".to_string(),
            work.join("t91-requests.jsonl").display().to_string(),
            "--user".to_string(),
            DAV_USER.to_string(),
            "--password".to_string(),
            DAV_PASS.to_string(),
        ],
        &lower_log,
    )?;
    let lower = Server {
        label: "mini_dav_server.py (lowercase <d:>)".to_string(),
        port: lower_port,
        child: lower,
    };
    println!("[T77] started {} pid {}", lower.label, lower.child.id());

    // ─────────── B. raw wire proof: which prefix did each server really send? ───────────
    let upper_snap_url = format!("{upper_url}/backup/snapshots/");
    let lower_snap_url = format!("{lower_url}/backup/snapshots/");

    wait_port(upper_port, "wsgidav", Duration::from_secs(30)).await?;
    wait_port(lower_port, "t91", Duration::from_secs(30)).await?;

    let (ucode, ubody) = raw_propfind(&upper_snap_url).await?;
    let (lcode, lbody) = raw_propfind(&lower_snap_url).await?;

    println!("[T77] ---- raw UPPER body (wsgidav), HTTP {ucode}, {} bytes ----", ubody.len());
    println!("{}", head_chars(&ubody, 900));
    println!("[T77] ---- raw LOWER body (t91), HTTP {lcode}, {} bytes ----", lbody.len());
    println!("{}", head_chars(&lbody, 900));

    // ★ wsgidav 的前缀**随版本变**：4.3.5 实测发 `ns0:`，更早的版本发大写 `D:`。
    //   所以这里判的是「前缀**不是**小写 `d:`」这件事（也就是本测试要证的
    //   前缀无关性），而不是死认某一个具体前缀 —— 否则换个 wsgidav 版本
    //   这条测试就会假红，而被测的解析器其实一直是好的。
    let u_upper_response = occ(&ubody, "<D:response") + occ(&ubody, "<ns0:response");
    let u_lower_response = occ(&ubody, "<d:response");
    let u_upper_getetag = occ(&ubody, "<D:getetag") + occ(&ubody, "<ns0:getetag");
    let u_prefix = if occ(&ubody, "<ns0:response") > 0 {
        "ns0:"
    } else {
        "D:"
    };
    println!("[T77] UPPER 实际前缀 = {u_prefix}");
    let l_lower_response = occ(&lbody, "<d:response");
    let l_lower_getetag = occ(&lbody, "<d:getetag");

    r.crit(
        "B1 UPPER server really emits a NON-lowercase response prefix (3 blocks)",
        ucode == 207 && u_upper_response == EXPECTED_RESPONSE_BLOCKS,
        &format!("http={ucode} prefix={u_prefix} response count={u_upper_response} (want {EXPECTED_RESPONSE_BLOCKS})"),
    );
    r.crit(
        "B2 UPPER server emits ZERO lowercase <d:response> -- the literal the old parser searched for",
        u_lower_response == 0,
        &format!("<d:response count={u_lower_response} (want 0)"),
    );
    r.crit(
        "B3 UPPER server emits getetag under that same non-lowercase prefix",
        u_upper_getetag >= 1,
        &format!("prefix={u_prefix} getetag count={u_upper_getetag}"),
    );
    r.crit(
        "B4 LOWER control server emits lowercase <d:response> (3 blocks) + <d:getetag>",
        lcode == 207 && l_lower_response == EXPECTED_RESPONSE_BLOCKS && l_lower_getetag >= 1,
        &format!(
            "http={lcode} <d:response count={l_lower_response} <d:getetag count={l_lower_getetag}"
        ),
    );

    // ─────────── C. the crate's OWN public API, through a real HTTP round trip ───────────
    //
    // An isolated in-memory Db on purpose: `AppState::bootstrap` also starts the
    // remote-control listener on port 8642 (documented at state.rs:492-520), and
    // this test must not fight the Owner's live client for that port. The Db is
    // not part of what we measure — `list_snapshots`/`etag` only touch the
    // backend — so the minimal side-effect-free choice is also the honest one.
    let db = Arc::new(Db::in_memory().map_err(|e| format!("Db::in_memory: {e}"))?);
    let device_id = "t77-test-device".to_string();

    let upper_engine = SyncEngine::new_webdav(cfg_for(&upper_url), db.clone(), device_id.clone())
        .map_err(|e| format!("SyncEngine::new_webdav (upper): {e}"))?;
    let lower_engine = SyncEngine::new_webdav(cfg_for(&lower_url), db.clone(), device_id.clone())
        .map_err(|e| format!("SyncEngine::new_webdav (lower): {e}"))?;

    // Connectivity first: a 0 must not be explainable as "the server was down".
    let u_test = upper_engine.test().await;
    r.crit(
        "B5 UPPER test()/ping() succeeds (connectivity established before listing)",
        matches!(&u_test, Ok(s) if s == "连接正常"),
        &format!("{u_test:?}"),
    );
    let l_test = lower_engine.test().await;
    r.crit(
        "B6 LOWER test()/ping() succeeds (positive control is live)",
        matches!(&l_test, Ok(s) if s == "连接正常"),
        &format!("{l_test:?}"),
    );

    // ★ the defect: a real server with arbitrary prefixes must still be listed.
    let u_listed = upper_engine.list_snapshots().await;
    let u_names: Vec<String> = match &u_listed {
        Ok(v) => v.iter().map(|e| e.name.clone()).collect(),
        Err(_) => Vec::new(),
    };
    r.crit(
        "C1 UPPER list_snapshots() returns the 2 snapshots that exist on disk",
        u_listed.as_ref().map(|v| v.len()).unwrap_or(0) == SNAPS.len(),
        &format!(
            "got {} entries {u_names:?} from {u_listed:?} (disk has {:?})",
            u_names.len(),
            SNAPS
        ),
    );

    // positive control: identical code path, lowercase prefixes.
    let l_listed = lower_engine.list_snapshots().await;
    let l_names: Vec<String> = match &l_listed {
        Ok(v) => v.iter().map(|e| e.name.clone()).collect(),
        Err(_) => Vec::new(),
    };
    r.crit(
        "C2 LOWER list_snapshots() returns the same 2 snapshots (positive control)",
        l_listed.as_ref().map(|v| v.len()).unwrap_or(0) == SNAPS.len(),
        &format!("got {} entries {l_names:?} from {l_listed:?}", l_names.len()),
    );

    // ★ second half of the defect: without an etag there is no If-Match, so a
    // conditional PUT silently degrades to an unconditional one (lost update
    // instead of a detectable 412).
    let u_be = WebdavBackend::new(cfg_for(&upper_url))
        .map_err(|e| format!("WebdavBackend::new (upper): {e}"))?;
    let u_etag = u_be
        .etag(&format!("backup/snapshots/{SNAP_A}"))
        .await;
    r.crit(
        "C3 UPPER etag() is Some(...) (an etag-less read means no If-Match => no lost-update detection)",
        matches!(&u_etag, Ok(Some(_))),
        &format!("{u_etag:?}"),
    );

    let l_be = WebdavBackend::new(cfg_for(&lower_url))
        .map_err(|e| format!("WebdavBackend::new (lower): {e}"))?;
    let l_etag = l_be
        .etag(&format!("backup/snapshots/{SNAP_A}"))
        .await;
    r.crit(
        "C4 LOWER etag() is Some(...) (positive control)",
        matches!(&l_etag, Ok(Some(_))),
        &format!("{l_etag:?}"),
    );

    // ─────────── D. retention consequence, stated in the report ───────────
    println!(
        "[T77] retention view: upper={} snapshots listed, lower={} snapshots listed \
         (a 0 on the upper side means snapshots_to_prune() sees nothing and never deletes)",
        u_names.len(),
        l_names.len()
    );

    Ok(())
}

#[tokio::test]
#[ignore = "spawns local WebDAV servers (wsgidav UPPERCASE <D:> + tests/support/mini_dav_server.py lowercase <d:>); run: cargo test --test t77_dav_prefix -- --ignored --nocapture"]
async fn t77_namespace_prefix_agnostic_listing() {
    let mut r = Report::new();
    if let Err(e) = run_body(&mut r).await {
        r.fail += 1;
        println!("[T77]   FATAL {e}");
    }
    println!("[T77] RESULT pass={} fail={}", r.pass, r.fail);
    assert_eq!(
        r.fail, 0,
        "T77: {} criteria failed -- see the [T77] FAIL lines above",
        r.fail
    );
}
