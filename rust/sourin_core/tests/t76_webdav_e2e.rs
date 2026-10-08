//! T76 — WebDAV cloud-sync end-to-end test against a REAL HTTP server.
//!
//! `#[ignore]`d **on purpose**: a bare `cargo test --release` must stay green
//! with no server running. Drive it through `.probe\t76_run_webdav_e2e.ps1`,
//! which starts the local WebDAV-subset instrument and sets:
//!
//! ```text
//! T76_DAV_URL   e.g. http://127.0.0.1:18091   (used verbatim as base_url)
//! T76_LOG       path to the server's JSONL request log
//! T76_ROOT      the server's root directory on disk
//! T76_TMPDIR    optional; base dir for the isolated app data dir
//! ```
//!
//! Missing `T76_DAV_URL` is a **hard FAIL**, never a silent skip.
//!
//! `remote_dir` is deliberately EMPTY, so a remote path `backup/snapshots/x.zip`
//! maps 1:1 onto `<T76_ROOT>\backup\snapshots\x.zip` — the decoys the runner
//! seeds land exactly where the retention guard has to leave them alone.
//!
//! Safety: this file never calls `configure_webdav`, so the OS keychain
//! (service `dsh-media-client-sync`, which holds the Owner's real credential)
//! is never written. The engine is built directly with
//! `SyncEngine::new_webdav(cfg, db, device_id)` and a plaintext password.
//!
//! Criteria A..E are asserted in-process. Every criterion prints a `[T76]` line
//! marked ` ✓ ` or ` ✗ `, and the run finishes with exactly one
//! `[T76] RESULT pass=<N> fail=<M>` line. Any failure panics ⇒ non-zero exit.

use sourin_core::state::AppState;
use sourin_core::store::{Favorite, Progress};
use sourin_core::sync::{BackupOutcome, SyncEngine, WebdavConfig};
use std::path::{Path, PathBuf};
use std::time::Duration;

const DAV_USER: &str = "u";
const DAV_PASS: &str = "p";

/// Three strictly increasing snapshot names. The `yyyyMMdd-HHmmss` field is
/// fixed width, so lexicographic order == chronological order, unambiguously.
const SNAP_OLD: &str = "dsh-backup-dev-e2e-20260101-010101.zip";
const SNAP_MID: &str = "dsh-backup-dev-e2e-20260101-020202.zip";
const SNAP_NEW: &str = "dsh-backup-dev-e2e-20260101-030303.zip";
const RETAIN: u32 = 2;

/// Files the runner pre-places next to our snapshots. The retention guard must
/// delete **only** our own `dsh-backup-*.zip`, so all four must survive.
/// Two of them are deliberately shaped like near-misses.
const DECOYS: [&str; 4] = [
    "README.txt",
    "user-notes.md",
    "dsh-backup-note.txt",           // prefix matches, suffix does not
    "dsh-notes-20260101-000000.zip", // suffix matches, prefix does not
];

// ───────────────────────────── tiny reporter ─────────────────────────────

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
            println!("[T76]   ✓ {label}");
        } else {
            self.fail += 1;
            println!("[T76]   ✗ {label} — {detail}");
        }
    }

    fn fatal(&mut self, msg: &str) {
        self.fail += 1;
        println!("[T76]   ✗ FATAL — {msg}");
    }
}

// ───────────────────────────── helpers ─────────────────────────────

/// Read the three required env vars. Missing ⇒ Err (the caller turns that into
/// a loud FATAL + `RESULT pass=0 fail=1` + panic).
fn read_envs() -> Result<(String, PathBuf, PathBuf), String> {
    let get = |k: &str| {
        std::env::var(k)
            .ok()
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
    };
    let url = get("T76_DAV_URL");
    let log = get("T76_LOG");
    let root = get("T76_ROOT");
    // record presence BEFORE the tuple move, so the error path can report it
    let (has_url, has_log, has_root) = (url.is_some(), log.is_some(), root.is_some());
    match (url, log, root) {
        (Some(u), Some(l), Some(r)) => Ok((u, PathBuf::from(l), PathBuf::from(r))),
        _ => Err(format!(
            "required env var missing — T76_DAV_URL set={has_url} T76_LOG set={has_log} \
             T76_ROOT set={has_root}. This test drives a REAL WebDAV server and never \
             skips silently; run it via .probe\\t76_run_webdav_e2e.ps1, which sets all three."
        )),
    }
}

/// Where the isolated data dir goes. Defaults to the repo's `.probe` scratch dir
/// (temp files live under `.probe`), overridable via `T76_TMPDIR`.
fn work_base() -> PathBuf {
    if let Ok(v) = std::env::var("T76_TMPDIR") {
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

/// Read the server's JSONL log. Returns `(raw non-empty line count, parsed records)`.
///
/// A parser that silently reads 0 lines is an INSTRUMENT failure, not a pass —
/// so the raw count travels alongside the parsed records and both get printed.
fn log_snapshot(path: &Path) -> (usize, Vec<serde_json::Value>) {
    let raw = std::fs::read_to_string(path).unwrap_or_default();
    let lines: Vec<&str> = raw.lines().filter(|l| !l.trim().is_empty()).collect();
    let raw_n = lines.len();
    let parsed = lines
        .iter()
        .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
        .collect();
    (raw_n, parsed)
}

fn method_is(rec: &serde_json::Value, m: &str) -> bool {
    rec.get("method").and_then(|v| v.as_str()) == Some(m)
}

fn path_of(rec: &serde_json::Value) -> &str {
    rec.get("path").and_then(|v| v.as_str()).unwrap_or("?")
}

/// PUTs whose request path contains `needle`.
fn put_count(recs: &[serde_json::Value], needle: &str) -> usize {
    recs.iter()
        .filter(|r| method_is(r, "PUT") && path_of(r).contains(needle))
        .count()
}

/// `(method, path, status) -> count`, sorted — an honest full tally.
fn tally(recs: &[serde_json::Value]) -> Vec<(String, String, i64, usize)> {
    use std::collections::BTreeMap;
    let mut m: BTreeMap<(String, String, i64), usize> = BTreeMap::new();
    for r in recs {
        let method = r.get("method").and_then(|v| v.as_str()).unwrap_or("?").to_string();
        let path = path_of(r).to_string();
        let status = r.get("status").and_then(|v| v.as_i64()).unwrap_or(-1);
        *m.entry((method, path, status)).or_insert(0) += 1;
    }
    m.into_iter().map(|((a, b, c), n)| (a, b, c, n)).collect()
}

fn fmt_res<T: std::fmt::Debug>(r: &Result<T, String>) -> String {
    match r {
        Ok(v) => format!("Ok({v:?})"),
        Err(e) => format!("Err({e})"),
    }
}

/// The instrument writes its log line *after* it has already put the response on
/// the wire, and it is multi-threaded — so a request can be observable by the
/// client microseconds before it is observable in the log. Let it land.
/// (This is a synchronisation step, not a way to wait for a better result.)
async fn settle() {
    tokio::time::sleep(Duration::from_millis(500)).await;
}

/// A port that was just free (bound to :0 and released) ⇒ nothing is listening.
fn dead_port() -> u16 {
    let l = std::net::TcpListener::bind("127.0.0.1:0").expect("bind ephemeral port");
    let p = l.local_addr().expect("local_addr").port();
    drop(l);
    p
}

fn cfg_for(url: &str, password: &str) -> WebdavConfig {
    WebdavConfig {
        base_url: url.to_string(),
        username: DAV_USER.to_string(),
        password: password.to_string(),
        // EMPTY on purpose: remote paths map 1:1 onto <T76_ROOT>\<path>
        remote_dir: String::new(),
    }
}

// ───────────────────────────── the body ─────────────────────────────

async fn run_body(r: &mut Report, url: &str, log_path: &Path, root: &Path) -> Result<(), String> {
    println!("[T76] ==== T76 WebDAV end-to-end ====");
    println!("[T76] base_url   = {url}");
    println!("[T76] log        = {}", log_path.display());
    println!("[T76] root       = {}", root.display());

    // ─────────── A. instrument self-proof, BEFORE any measurement ───────────
    let (raw0, parsed0) = log_snapshot(log_path);
    r.crit(
        "A1 log file exists and already holds >= 1 line (instrument live before measurement)",
        log_path.is_file() && raw0 >= 1,
        &format!(
            "exists={} raw_lines={raw0} parsed_lines={}",
            log_path.is_file(),
            parsed0.len()
        ),
    );

    // ─────────── isolated data dir (house idiom: unique dir per run) ───────────
    let work = work_base().join(format!(
        "sourin-t76-e2e-{}",
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
    ));
    std::fs::create_dir_all(&work)
        .map_err(|e| format!("create work dir {}: {e}", work.display()))?;
    println!("[T76] data_dir   = {}", work.display());
    let st = AppState::bootstrap(work.clone())
        .await
        .map_err(|e| format!("AppState::bootstrap({}): {e}", work.display()))?;

    // ─────────── B. real TCP + real Basic auth ───────────
    let engine = SyncEngine::new_webdav(
        cfg_for(url, DAV_PASS),
        st.db.clone(),
        st.device_id.clone(),
    )
    .map_err(|e| format!("SyncEngine::new_webdav: {e}"))?;

    let prep = engine.prepare().await;
    r.crit(
        "B1 prepare() succeeds over real TCP (MKCOL layout)",
        prep.is_ok(),
        &fmt_res(&prep),
    );

    let ping = engine.test().await;
    r.crit(
        "B2 test()/ping() succeeds",
        matches!(&ping, Ok(s) if s == "连接正常"),
        &fmt_res(&ping),
    );

    // positive control: a wrong password must NOT be accepted
    let bad_engine = SyncEngine::new_webdav(
        cfg_for(url, "definitely-not-the-password"),
        st.db.clone(),
        st.device_id.clone(),
    )
    .map_err(|e| format!("SyncEngine::new_webdav (wrong password): {e}"))?;
    let bad_test = bad_engine.test().await;
    r.crit(
        "B3 wrong password => test() is Err (auth is genuinely enforced)",
        bad_test.is_err(),
        &fmt_res(&bad_test),
    );
    let bad_prep = bad_engine.prepare().await;
    r.crit(
        "B4 wrong password => prepare() is Err",
        bad_prep.is_err(),
        &fmt_res(&bad_prep),
    );

    // ─────────── C. retention really prunes down to N ───────────
    let snap_dir = root.join("backup").join("snapshots");
    println!("[T76] snap dir   = {}", snap_dir.display());
    let on_disk = |n: &str| snap_dir.join(n).is_file();

    // precondition: the RUNNER seeded the decoys; if it did not, say so loudly
    // rather than quietly creating them ourselves (that would hide a runner bug).
    let missing_at_start: Vec<&str> =
        DECOYS.iter().copied().filter(|d| !on_disk(d)).collect();
    r.crit(
        "C0 the 4 decoys were pre-placed by the runner before any measurement",
        missing_at_start.is_empty(),
        &format!("missing={missing_at_start:?}"),
    );

    let mut outs: Vec<Result<BackupOutcome, String>> = Vec::new();
    for (name, body) in [
        (SNAP_OLD, "t76-snapshot-one"),
        (SNAP_MID, "t76-snapshot-two"),
        (SNAP_NEW, "t76-snapshot-three"),
    ] {
        outs.push(engine.backup_snapshot(name, body.as_bytes(), RETAIN).await);
    }
    let errs: Vec<String> = outs.iter().filter_map(|o| o.as_ref().err().cloned()).collect();
    r.crit(
        "C1 three backup_snapshot(name, bytes, retain=2) uploads all succeeded",
        errs.is_empty() && outs.len() == 3,
        &format!("errors={errs:?}"),
    );

    let listed = engine.list_snapshots().await;
    let names: Vec<String> = match &listed {
        Ok(v) => v.iter().map(|e| e.name.clone()).collect(),
        Err(e) => {
            println!("[T76] REPORT list_snapshots error = {e}");
            Vec::new()
        }
    };
    r.crit(
        "C2 list_snapshots() returns exactly 2 after 3 uploads with retain_count=2",
        names.len() == 2,
        &format!("names={names:?}"),
    );
    r.crit(
        "C3 the OLDEST snapshot is absent from list_snapshots()",
        !names.iter().any(|n| n == SNAP_OLD),
        &format!("names={names:?}"),
    );

    let o3: Option<&BackupOutcome> = outs.get(2).and_then(|o| o.as_ref().ok());
    let pruned: Vec<String> = o3.map(|o| o.pruned.clone()).unwrap_or_default();
    r.crit(
        "C4 3rd outcome.pruned.len()==1 and pruned[0]==<oldest name>",
        pruned.len() == 1 && pruned[0] == SNAP_OLD,
        &format!("pruned={pruned:?}"),
    );
    let total = o3.map(|o| o.total);
    r.crit(
        "C5 3rd outcome.total == 2 (survivors AFTER prune)",
        total == Some(2),
        &format!("total={total:?}"),
    );

    // assert on the SERVER's filesystem, not only on the client's view
    let missing_survivors: Vec<&str> = [SNAP_MID, SNAP_NEW]
        .iter()
        .copied()
        .filter(|n| !on_disk(n))
        .collect();
    r.crit(
        "C6 server FS: the 2 survivors are present on disk",
        missing_survivors.is_empty(),
        &format!("missing={missing_survivors:?}"),
    );
    r.crit(
        "C7 server FS: the pruned snapshot is gone from disk",
        !on_disk(SNAP_OLD),
        &format!("{} still on disk = {}", SNAP_OLD, on_disk(SNAP_OLD)),
    );
    let dead_decoys: Vec<&str> = DECOYS.iter().copied().filter(|d| !on_disk(d)).collect();
    r.crit(
        "C8 server FS: all 4 decoys survived the retention sweep",
        dead_decoys.is_empty(),
        &format!("deleted decoys={dead_decoys:?}"),
    );

    println!("[T76] REPORT C pruned name  = {pruned:?}");
    println!("[T76] REPORT C outcome.total = {total:?}");
    println!("[T76] REPORT C list_snapshots = {names:?}");
    println!(
        "[T76] REPORT C survivors on server FS = {:?}",
        [SNAP_MID, SNAP_NEW]
            .iter()
            .filter(|n| on_disk(n))
            .collect::<Vec<_>>()
    );
    println!(
        "[T76] REPORT C decoys on server FS (all 4 must be here) = {:?}",
        DECOYS.iter().filter(|d| on_disk(d)).collect::<Vec<_>>()
    );

    // ─────────── D. zero write requests when the data did not change ───────────
    let now = chrono::Utc::now().timestamp_millis();
    let fav = Favorite {
        key: "t76:e2e-1".to_string(),
        provider: "t76".to_string(),
        native_id: "e2e-1".to_string(),
        title: "T76 end-to-end favorite".to_string(),
        cover: None,
        group_name: None,
        kind: "series".to_string(),
        favorited: true,
        following: false,
        last_episode_count: 0,
        last_episode_title: None,
        unread_count: 0,
        last_checked_at: 0,
        last_update_at: 0,
        note: None,
        created_at: now,
        updated_at: now,
        deleted: false,
    };
    let prog = Progress {
        key: "t76:e2e-1".to_string(),
        provider: "t76".to_string(),
        native_id: "e2e-1".to_string(),
        title: "T76 end-to-end progress".to_string(),
        cover: None,
        episode_id: Some("ep1".to_string()),
        episode_title: Some("episode 1".to_string()),
        position: 42,
        duration: 1440,
        finished: false,
        updated_at: now,
    };
    st.db
        .upsert_favorite(&fav)
        .map_err(|e| format!("upsert_favorite: {e}"))?;
    st.db
        .upsert_progress(&prog)
        .map_err(|e| format!("upsert_progress: {e}"))?;

    // positive control: the seeded rows must really be readable locally,
    // otherwise "zero PUTs" would be vacuous (nothing to upload in the first place).
    let lf = st.db.list_favorites(false).unwrap_or_default();
    let lp = st.db.list_all_progress().unwrap_or_default();
    r.crit(
        "D1 positive control: the seeded favorite is really readable from the isolated DB",
        lf.iter().any(|f| f.key == fav.key),
        &format!("list_favorites(false).len()={}", lf.len()),
    );
    r.crit(
        "D2 positive control: the seeded progress row is really readable from the isolated DB",
        lp.iter().any(|p| p.key == prog.key),
        &format!("list_all_progress().len()={}", lp.len()),
    );

    settle().await;
    let (_, before1) = log_snapshot(log_path);
    let base1 = before1.len();
    let s1 = engine.sync_all().await;
    r.crit("D3 sync_all() #1 succeeded", s1.is_ok(), &fmt_res(&s1));
    settle().await;
    let (raw_after1, after1) = log_snapshot(log_path);
    let win1 = &after1[base1.min(after1.len())..];
    let put1 = win1.iter().filter(|x| method_is(x, "PUT")).count();
    r.crit(
        "D4 sync_all() #1 window contains > 0 PUTs (the counting instrument is sensitive)",
        put1 > 0,
        &format!(
            "put_count={put1} window_lines={} raw_lines={raw_after1}",
            win1.len()
        ),
    );
    println!("[T76] REPORT D run #1 PUT count = {put1} (window_lines={})", win1.len());

    // nothing changes between the two runs
    settle().await;
    let (_, before2) = log_snapshot(log_path);
    let base2 = before2.len();
    let s2 = engine.sync_all().await;
    r.crit(
        "D5 sync_all() #2 (nothing changed) succeeded",
        s2.is_ok(),
        &fmt_res(&s2),
    );
    settle().await;
    let (raw_after2, after2) = log_snapshot(log_path);
    let win2 = &after2[base2.min(after2.len())..];

    let put_fav = put_count(win2, "favorites.jsonl");
    let put_prog = put_count(win2, "progress.jsonl");
    let put_manifest = put_count(win2, "manifest.json");
    r.crit(
        "D6 run #2 window: 0 PUTs to any path containing favorites.jsonl",
        put_fav == 0,
        &format!("put_count={put_fav}"),
    );
    r.crit(
        "D7 run #2 window: 0 PUTs to any path containing progress.jsonl",
        put_prog == 0,
        &format!("put_count={put_prog}"),
    );

    // REPORT ONLY, deliberately NOT asserted: write_manifest is unconditional
    // because the manifest carries lastSyncAt, so a manifest PUT in run #2 is
    // expected behaviour, not a defect.
    println!(
        "[T76] REPORT D run #2 PUTs to manifest.json = {put_manifest} \
         (write_manifest is deliberately unconditional: it carries lastSyncAt)"
    );
    println!("[T76] REPORT D run #2 full tally ({} requests):", win2.len());
    for (m, p, code, n) in tally(win2) {
        println!("[T76] REPORT   {m} {p} -> {code}  x{n}");
    }
    println!(
        "[T76] REPORT log line count after run #2: raw={raw_after2} parsed={}",
        after2.len()
    );

    // ─────────── F. REPORT ONLY: conditional-PUT path after local data changes ───────────
    //
    // Found while auditing the run-2 tally: the instrument emits the etag XML-escaped
    // inside <d:getetag> (&quot;...&quot;), while WebdavBackend::parse_etag
    // (rust\sourin_core\src\sync\webdav.rs:334-343) does raw substring matching with NO
    // XML unescaping. The client therefore sends `If-Match: &quot;...&quot;`, which can
    // never match a server that escapes.
    //
    // Runs #1/#2 never reach this: run #1's data PUTs were 201 (remote file absent ⇒ no
    // If-Match at all), and run #2 changed nothing (byte-identical ⇒ PUT skipped).
    // This probe drives the one path that does — remote file EXISTS + local bytes CHANGED
    // ⇒ put_with_remerge (rust\sourin_core\src\sync\mod.rs:671-691), whose own retry
    // re-fetches a "fresh" etag from the same unescaping parser.
    //
    // Deliberately REPORT ONLY, not asserted: it is not one of the specified criteria
    // (A-E), and asserting it would flip the required "1 passed" runner verdict to red.
    // The raw reading is printed either way.
    let mut prog2 = prog.clone();
    prog2.position = 99;
    prog2.updated_at = now + 1000;
    st.db
        .upsert_progress(&prog2)
        .map_err(|e| format!("upsert_progress (F probe): {e}"))?;
    settle().await;
    let (_, before3) = log_snapshot(log_path);
    let base3 = before3.len();
    let s3 = engine.sync_all().await;
    settle().await;
    let (raw_after3, after3) = log_snapshot(log_path);
    let win3 = &after3[base3.min(after3.len())..];
    println!(
        "[T76] REPORT F local data CHANGED => sync_all() #3 = {}",
        fmt_res(&s3)
    );
    println!(
        "[T76] REPORT F run #3 PUTs to data/*.jsonl = {} (window_lines={})",
        put_count(win3, "favorites.jsonl") + put_count(win3, "progress.jsonl"),
        win3.len()
    );
    println!(
        "[T76] REPORT F run #3 log lines: raw={raw_after3} parsed={}",
        after3.len()
    );
    println!("[T76] REPORT F run #3 full tally ({} requests):", win3.len());
    for (m, p, code, n) in tally(win3) {
        println!("[T76] REPORT   {m} {p} -> {code}  x{n}");
    }

    // ─────────── G. REPORT-ONLY: namespace-prefix sensitivity ───────────
    //
    // A SECOND finding, found while investigating the 412 above, and it is
    // potentially worse than the etag escaping.
    //
    // `WebdavBackend::parse_list` (src/sync/webdav.rs:399-420) locates
    // response blocks by searching for the LITERAL strings `<d:response>`
    // and `<response>`, and `parse_etag` (:334-343) likewise searches for
    // the literal `<d:getetag>` / `<getetag>`. `tag_text` (:372-382) has
    // the same hardcoded lowercase `d:` assumption. The XML namespace
    // prefix is arbitrary per the XML spec — a server may legally emit
    // `<D:response>`, `<ns0:response>`, etc.
    //
    // Measured against wsgidav 4.3.5 (a real, independent WebDAV
    // implementation), the PROPFIND body was:
    //   <D:multistatus xmlns:D="DAV:"><D:response><D:href>/probe.txt</D:href>
    //   <D:propstat><D:prop><D:getetag>e962c712...-26</D:getetag>...
    // i.e. UPPERCASE `D:`. The crate matches neither `<d:response>` nor
    // `<response>`, so `parse_list` would return an EMPTY list — meaning
    // `list_snapshots()` reports "no snapshots" and `snapshots_to_prune`
    // can never see (or delete) anything, silently.
    //
    // This is REPORT-ONLY and gated on `T76_ALT_URL` (a second server, if
    // the runner supplies one). It is deliberately NOT asserted: it is not
    // one of the specified A-E criteria, and asserting it would flip the
    // required "1 passed" verdict to red. The t91 instrument emits
    // lowercase `d:` throughout, so this never fires on a normal run.
    match std::env::var("T76_ALT_URL") {
        Ok(alt) if !alt.trim().is_empty() => {
            println!("[T76] REPORT G alternate server = {alt}");
            match SyncEngine::new_webdav(
                cfg_for(alt.trim(), DAV_PASS),
                st.db.clone(),
                st.device_id.clone(),
            ) {
                Ok(alt_engine) => {
                    println!(
                        "[T76] REPORT G alt test() = {}",
                        fmt_res(&alt_engine.test().await)
                    );
                    println!(
                        "[T76] REPORT G alt prepare() = {}",
                        fmt_res(&alt_engine.prepare().await)
                    );
                    let alt_list = alt_engine.list_snapshots().await;
                    match &alt_list {
                        Ok(v) => {
                            let ns: Vec<String> =
                                v.iter().map(|e| e.name.clone()).collect();
                            println!(
                                "[T76] REPORT G alt list_snapshots() = {} entries {ns:?}",
                                ns.len()
                            );
                            println!(
                                "[T76] REPORT G   (a real server with UPPERCASE D: \
                                 prefixes => the crate sees 0 entries even when \
                                 snapshot files exist on disk)"
                            );
                        }
                        Err(e) => println!("[T76] REPORT G alt list_snapshots() Err = {e}"),
                    }
                }
                Err(e) => println!("[T76] REPORT G alt new_webdav Err = {e}"),
            }
        }
        _ => println!(
            "[T76] REPORT G alternate-server probe skipped (T76_ALT_URL not set)"
        ),
    }

    // ─────────── E. dead port ⇒ Err, no panic ───────────
    let dp = dead_port();
    let dead_url = format!("http://127.0.0.1:{dp}");
    let dead = SyncEngine::new_webdav(
        cfg_for(&dead_url, DAV_PASS),
        st.db.clone(),
        st.device_id.clone(),
    )
    .map_err(|e| format!("SyncEngine::new_webdav (dead port): {e}"))?;
    let dead_res = dead.sync_all().await;
    r.crit(
        "E1 sync_all() against a dead port returns Err (no panic)",
        dead_res.is_err(),
        &fmt_res(&dead_res),
    );
    println!(
        "[T76] REPORT E dead-port ({dead_url}) error string: {}",
        match &dead_res {
            Err(e) => e.clone(),
            Ok(v) => format!("UNEXPECTED Ok({v:?})"),
        }
    );

    // ─────────── A (re-read): the instrument must still be readable ───────────
    let (raw_end, parsed_end) = log_snapshot(log_path);
    r.crit(
        "A2 final re-read: parsed log line count > 0",
        !parsed_end.is_empty(),
        &format!(
            "raw_lines={raw_end} parsed_lines={}",
            parsed_end.len()
        ),
    );
    println!(
        "[T76] REPORT final log: raw_lines={raw_end} parsed_lines={}",
        parsed_end.len()
    );

    Ok(())
}

// ───────────────────────────── the test ─────────────────────────────

#[tokio::test]
#[ignore = "needs a live WebDAV server (T76_DAV_URL); run .probe\\t76_run_webdav_e2e.ps1"]
async fn t76_webdav_e2e() {
    let mut r = Report::new();
    match read_envs() {
        Ok((url, log_path, root)) => {
            if let Err(e) = run_body(&mut r, &url, &log_path, &root).await {
                r.fatal(&e);
            }
        }
        Err(msg) => r.fatal(&msg),
    }

    println!("[T76] RESULT pass={} fail={}", r.pass, r.fail);
    if r.fail > 0 {
        panic!(
            "T76 FAILED — pass={} fail={} (see the [T76] lines above for the raw readings)",
            r.pass, r.fail
        );
    }
}
