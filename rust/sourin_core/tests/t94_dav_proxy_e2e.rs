//! T94 —— WebDAV 的代理行为与协议健壮性：**端到端**（真 TCP，不依赖外网、不依赖 Python）
//!
//! # ① 这个测试锁住的是**实测发现的缺陷**
//!
//! `WebdavBackend::new` 原来用 `reqwest::Client::builder()` 裸建客户端，
//! 而 reqwest 默认 `auto_sys_proxy = true` ⇒ 会读 `HTTP_PROXY` / `HTTPS_PROXY`
//! 环境变量。于是在装了代理软件的机器上：
//!
//! ```text
//! 用户把地址填成 http://127.0.0.1:18091/（本机 WebDAV）或
//!                 http://192.168.1.10:5006/（群晖）
//!     → 请求被系统代理截走 → 代理上没有这个主机 → HTTP 502
//!     → 界面报「重试 4 次后仍失败: HTTP 502」
//! ```
//!
//! 症状极具误导性：**地址和凭据全对，却连不上本机 / 内网的服务器**，
//! 而且日志里只有 502，看不出是代理干的。
//! （实测读数：本仓环境设了 `HTTP_PROXY=http://127.0.0.1:7890`，
//!  于是一个「空端口的回环地址」返回的是 `HTTP 502` 而不是「无法连接」——
//!  这就是被代理截走的铁证。）
//!
//! # ② 怎么测才不是假绿
//!
//! 本文件自带两个**跑在回环上**的仪器：
//!
//! - [`FakeProxy`]：一台只会回 `502` 的 HTTP 服务器，扮演系统代理。
//! - [`mini_dav`]：一台**最小但真实**的 WebDAV 服务器（Basic 认证 +
//!   MKCOL/PUT/GET/PROPFIND/DELETE，且故意用**大写 `D:` 前缀**发 XML）。
//!
//! 于是每条判据都是「答案从**哪台**服务器来」：
//! 走了代理 ⇒ 502（假代理的签名）；绕过了 ⇒ 真服务器的 207/201/404。
//! 「读到 502」证明确实走了代理，「读到 207」证明确实没走 ——
//! 两个读数互为反证，不存在只测一侧的假绿。
//!
//! # ③ 为什么**只有一个** `#[test]`
//!
//! 环境变量是**进程级全局**的。并行改 `HTTP_PROXY` 会让读数互相污染，
//! 而且任何一次失败都可能把变量留在脏状态、连累同进程里其它用例。
//! 所以所有依赖环境变量的步骤**串成一条**（每步之间复原），
//! 纯协议步骤（③④⑤⑥）在同一条里也照样跑。
//!
//! 纯函数的规则判定（哪些地址算「本机/内网」、`NO_PROXY` 怎么匹配）
//! 在 `src/sync/webdav.rs` 的单元测试里，不受这里的串行约束。

use sourin_core::sync::webdav::{SyncBackend, WebdavBackend, WebdavConfig};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

// ═══════════════════════ 仪器 ①：假代理（永远回 502）═══════════════════════

/// 一台「只回 502」的 HTTP 服务器 —— 它扮演系统代理
///
/// 命中它 = 请求被代理截走了（缺陷的症状）；不命中 = 直连成功。
struct FakeProxy {
    addr: SocketAddr,
    hits: Arc<AtomicUsize>,
    stop: Arc<Mutex<bool>>,
}

impl FakeProxy {
    fn start() -> Self {
        let l = TcpListener::bind("127.0.0.1:0").expect("bind fake proxy");
        let addr = l.local_addr().expect("local_addr");
        let hits = Arc::new(AtomicUsize::new(0));
        let stop = Arc::new(Mutex::new(false));
        let (h, s) = (hits.clone(), stop.clone());
        std::thread::spawn(move || {
            for conn in l.incoming() {
                if *s.lock().unwrap() {
                    break;
                }
                let Ok(mut c) = conn else { continue };
                h.fetch_add(1, Ordering::SeqCst);
                // 读掉请求头（到空行为止）—— 读不读都要回 502，
                // 读是为了让客户端的写侧不至于立刻拿到 RST
                let mut br = BufReader::new(c.try_clone().expect("clone stream"));
                loop {
                    let mut line = String::new();
                    match br.read_line(&mut line) {
                        Ok(0) | Err(_) => break,
                        Ok(_) if line == "\r\n" || line == "\n" => break,
                        Ok(_) => {}
                    }
                }
                let _ = c.write_all(
                    b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                );
                let _ = c.flush();
            }
        });
        Self { addr, hits, stop }
    }

    fn url(&self) -> String {
        format!("http://{}", self.addr)
    }

    fn hits(&self) -> usize {
        self.hits.load(Ordering::SeqCst)
    }
}

impl Drop for FakeProxy {
    fn drop(&mut self) {
        *self.stop.lock().unwrap() = true;
        let _ = TcpStream::connect(self.addr); // 只是让 accept 醒来
    }
}

// ═══════════════════════ 仪器 ②：真 WebDAV（回环）═══════════════════════════

/// 一个**最小但真实**的 WebDAV 服务器
///
/// 真 Basic 认证、真 MKCOL/PUT/GET/PROPFIND/DELETE，文件落在磁盘上 ——
/// 所以「客户端以为写成功了」和「磁盘上真的有」可以互相印证。
/// XML **故意用大写 `D:` 前缀**（与 wsgidav / 坚果云一致），
/// 免得这个仪器在「前缀无关」这件事上给出虚假的安心感。
struct MiniDav {
    addr: SocketAddr,
    root: PathBuf,
    stop: Arc<Mutex<bool>>,
}

impl MiniDav {
    fn start(root: PathBuf, user: &str, pass: &str) -> Self {
        std::fs::create_dir_all(&root).expect("create dav root");
        let l = TcpListener::bind("127.0.0.1:0").expect("bind dav");
        let addr = l.local_addr().expect("local_addr");
        let stop = Arc::new(Mutex::new(false));
        let (u, p, s, root2) = (
            user.to_string(),
            pass.to_string(),
            stop.clone(),
            root.clone(),
        );
        std::thread::spawn(move || {
            for conn in l.incoming() {
                if *s.lock().unwrap() {
                    break;
                }
                let Ok(c) = conn else { continue };
                let (u, p) = (u.clone(), p.clone());
                let root = root2.clone();
                std::thread::spawn(move || {
                    let _ = handle(c, &root, &u, &p);
                });
            }
        });
        Self { addr, root, stop }
    }

    fn url(&self) -> String {
        format!("http://{}", self.addr)
    }
}

impl Drop for MiniDav {
    fn drop(&mut self) {
        *self.stop.lock().unwrap() = true;
        let _ = TcpStream::connect(self.addr);
    }
}

/// 远端路径 → 磁盘路径（并挡住 `..` 逃逸）
fn to_disk(root: &std::path::Path, path: &str) -> PathBuf {
    let rel: PathBuf = path
        .split('?')
        .next()
        .unwrap_or("/")
        .split('/')
        .filter(|s| !s.is_empty() && *s != "." && *s != "..")
        .collect();
    root.join(rel)
}

fn base64_decode(s: &str) -> Option<Vec<u8>> {
    const T: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = Vec::new();
    let (mut buf, mut bits) = (0u32, 0u32);
    for ch in s.bytes() {
        if ch == b'=' || ch == b'\n' || ch == b'\r' {
            continue;
        }
        let v = T.iter().position(|&c| c == ch)? as u32;
        buf = (buf << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(((buf >> bits) & 0xFF) as u8);
            // ★ 必须只留**还没取走**的那几位，否则下一轮会把已消耗的位
            //   一起算进去，解出来的第 2 个及以后的字节全是错的
            buf &= (1u32 << bits) - 1;
        }
    }
    Some(out)
}

/// Basic 认证头解析（只认 RFC 7617 的 `base64(user:pass)`）
fn authorized(head: &str, user: &str, pass: &str) -> bool {
    let Some(v) = head
        .lines()
        .find(|l| l.to_ascii_lowercase().starts_with("authorization:"))
        .map(|l| l.splitn(2, ':').nth(1).unwrap_or("").trim().to_string())
    else {
        return false;
    };
    // ⚠️ 只有方案名（`Basic`）可以忽略大小写；**base64 本体不能** ——
    //    把它一起小写，解出来就是空/乱码，认证永远失败。
    let scheme_ok = v.len() > 6 && v[..6].eq_ignore_ascii_case("basic ");
    if !scheme_ok {
        return false;
    }
    let decoded = base64_decode(v[6..].trim()).unwrap_or_default();
    String::from_utf8(decoded).map(|s| s == format!("{user}:{pass}")).unwrap_or(false)
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn respond(c: &mut TcpStream, code: u16, reason: &str, body: &[u8], ctype: &str) {
    let head = format!(
        "HTTP/1.1 {code} {reason}\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\n\
         Connection: close\r\n\r\n",
        body.len()
    );
    let _ = c.write_all(head.as_bytes());
    let _ = c.write_all(body);
    let _ = c.flush();
}

/// `Depth: 1` 的 Multi-Status：被查目录自身 + 子目录 + 文件
fn multistatus(dir: &std::path::Path, depth: &str) -> String {
    let mut s =
        String::from("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">");
    s.push_str(
        "<D:response><D:href>/</D:href><D:propstat><D:prop>\
         <D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>",
    );
    if let Ok(rd) = std::fs::read_dir(dir) {
        let mut names: Vec<String> = rd
            .flatten()
            .filter_map(|e| e.file_name().to_str().map(|s| s.to_string()))
            .collect();
        names.sort();
        for n in names {
            // `Depth: 0` 只回目录自身（不列子项）—— 真实服务器也这样
            if depth.trim() == "0" {
                break;
            }
            let meta = match dir.join(&n).metadata() {
                Ok(m) => m,
                Err(_) => continue,
            };
            if meta.is_dir() {
                s.push_str(&format!(
                    "<D:response><D:href>/{n}/</D:href><D:propstat><D:prop>\
                     <D:resourcetype><D:collection/></D:resourcetype></D:prop>\
                     </D:propstat></D:response>",
                    n = esc(&n)
                ));
            } else {
                // ★ ETag 用 XML 实体转义（与坚果云一致）
                //   ⇒ 不解码实体就永远匹配不上 If-Match
                s.push_str(&format!(
                    "<D:response><D:href>/{n}</D:href><D:propstat><D:prop>\
                     <D:getcontentlength>{len}</D:getcontentlength>\
                     <D:getlastmodified>{lm}</D:getlastmodified>\
                     <D:getetag>&quot;{tag}&quot;</D:getetag>\
                     </D:prop></D:propstat></D:response>",
                    n = esc(&n),
                    len = meta.len(),
                    lm = "Tue, 29 Sep 2026 10:33:52 GMT",
                    tag = meta.len(),
                ));
            }
        }
    }
    s.push_str("</D:multistatus>");
    s
}

/// 单个**文件**资源的 Multi-Status（`PROPFIND` 打在一个文件上时回这个）
///
/// 与 `multistatus` 里文件那一支同形，只是没有目录自身那一块。
/// ETag 同样用 XML 实体转义（坚果云的实测行为）。
fn single_status(disk: &std::path::Path, target: &str) -> String {
    let len = disk.metadata().map(|m| m.len()).unwrap_or(0);
    format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>
<D:multistatus xmlns:D=\"DAV:\">         <D:response><D:href>{href}</D:href><D:propstat><D:prop>         <D:getcontentlength>{len}</D:getcontentlength>         <D:getlastmodified>Tue, 29 Sep 2026 10:33:52 GMT</D:getlastmodified>         <D:getetag>&quot;{tag}&quot;</D:getetag>         </D:prop></D:propstat></D:response></D:multistatus>",
        href = esc(target),
        len = len,
        tag = len,
    )
}

fn handle(mut c: TcpStream, root: &std::path::Path, user: &str, pass: &str) -> std::io::Result<()> {
    c.set_read_timeout(Some(std::time::Duration::from_secs(20)))?;
    let mut br = BufReader::new(c.try_clone()?);

    let mut head = String::new();
    if br.read_line(&mut head)? == 0 {
        return Ok(());
    }
    let mut parts = head.split_whitespace();
    let method = parts.next().unwrap_or("").to_string();
    let target = parts.next().unwrap_or("/").to_string();

    // ★ 头部必须**累积**进 `head`：`authorized()` 只读 `head`，
    //   把各头行归到另一个变量就永远认不出 Authorization
    let mut len = 0usize;
    loop {
        let mut l = String::new();
        if br.read_line(&mut l)? == 0 || l == "\r\n" || l == "\n" {
            break;
        }
        if let Some(v) = l.to_ascii_lowercase().strip_prefix("content-length:") {
            len = v.trim().parse().unwrap_or(0);
        }
        head.push_str(&l);
    }

    if !authorized(&head, user, pass) {
        let _ = c.write_all(
            b"HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"dav\"\r\n\
              Content-Length: 0\r\nConnection: close\r\n\r\n",
        );
        return Ok(());
    }

    let disk = to_disk(root, &target);
    // `Depth` 头决定回什么：1 = 连子项一起回（列目录），0 / 缺省 = 只回它自己
    let depth = head
        .lines()
        .find(|l| l.to_ascii_lowercase().starts_with("depth:"))
        .map(|l| l.splitn(2, ':').nth(1).unwrap_or("").trim().to_string())
        .unwrap_or_else(|| "0".into());
    match method.as_str() {
        "PROPFIND" => {
            if disk.is_dir() {
                respond(&mut c, 207, "Multi-Status", multistatus(&disk, &depth).as_bytes(), "application/xml");
            } else if disk.is_file() {
                // ★ 单个资源的 Multi-Status（真实服务器都这么回，坚果云 / wsgidav 亦然）
                //   少了这一支，`etag()` 恒为 None ⇒ 条件写退化成无条件写
                respond(&mut c, 207, "Multi-Status", single_status(&disk, &target).as_bytes(), "application/xml");
            } else {
                respond(&mut c, 404, "Not Found", b"no such resource", "text/plain");
            }
        }
        "MKCOL" => {
            if disk.exists() {
                respond(&mut c, 405, "Method Not Allowed", b"exists", "text/plain");
            } else if disk.parent().map(|p| p.is_dir()).unwrap_or(false) {
                std::fs::create_dir_all(&disk)?;
                respond(&mut c, 201, "Created", b"", "text/plain");
            } else {
                respond(&mut c, 409, "Conflict", b"parent missing", "text/plain");
            }
        }
        "PUT" => {
            let mut body = vec![0u8; len];
            if len > 0 {
                br.read_exact(&mut body)?;
            }
            if let Some(p) = disk.parent() {
                std::fs::create_dir_all(p)?;
            }
            std::fs::write(&disk, &body)?;
            respond(&mut c, 201, "Created", b"", "text/plain");
        }
        "GET" => match std::fs::read(&disk) {
            Ok(b) => respond(&mut c, 200, "OK", &b, "application/octet-stream"),
            Err(_) => respond(&mut c, 404, "Not Found", b"", "text/plain"),
        },
        "DELETE" => {
            if disk.is_file() {
                std::fs::remove_file(&disk)?;
                respond(&mut c, 204, "No Content", b"", "text/plain");
            } else {
                respond(&mut c, 404, "Not Found", b"", "text/plain");
            }
        }
        _ => respond(&mut c, 405, "Method Not Allowed", b"", "text/plain"),
    }
    Ok(())
}

// ═══════════════════════ 环境变量护栏 ═══════════════════════

/// 改环境变量，`Drop` 时复原
struct EnvGuard {
    old: Vec<(&'static str, Option<String>)>,
}

impl EnvGuard {
    /// 设 / 清一批代理相关变量（`None` = 清掉）
    ///
    /// ⚠️ Windows 的环境变量名**大小写不敏感**，
    ///    所以设 `HTTP_PROXY` 前必须先把 `http_proxy` 抹掉，否则残留值会被读到。
    fn set(pairs: &[(&'static str, Option<&str>)]) -> Self {
        let mut old = Vec::new();
        for (k, v) in pairs {
            old.push((*k, std::env::var(k).ok()));
            for variant in [k.to_uppercase(), k.to_lowercase()] {
                if variant != *k {
                    let _ = std::env::remove_var(variant);
                }
            }
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
        Self { old }
    }

    /// 「用户没装代理软件」的基线：清空全部代理相关变量
    fn clean() -> Self {
        Self::set(&[
            ("HTTP_PROXY", None),
            ("HTTPS_PROXY", None),
            ("ALL_PROXY", None),
            ("NO_PROXY", None),
        ])
    }
}

impl Drop for EnvGuard {
    fn drop(&mut self) {
        for (k, v) in self.old.drain(..) {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
    }
}

/// 从错误串里抽出 HTTP 状态码（旧实现的缺陷症状就是 `HTTP 502`）
fn http_code_in(err: &str) -> Option<u16> {
    let idx = err.find("HTTP ")? + 5;
    let digits: String = err[idx..].chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

fn work_dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!(
        "sourin-t94-{tag}-{}",
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
    ));
    std::fs::create_dir_all(&d).expect("create work dir");
    d
}

fn cfg(url: &str, pass: &str, remote_dir: &str) -> WebdavConfig {
    WebdavConfig {
        base_url: url.to_string(),
        username: "u".to_string(),
        password: pass.to_string(),
        remote_dir: remote_dir.to_string(),
    }
}

/// 极小的断言计数（一个文件一条用例，串行跑，报告直接读 stdout）
struct Report {
    pass: usize,
    fail: usize,
}

impl Report {
    fn crit(&mut self, label: &str, ok: bool, detail: &str) {
        if ok {
            self.pass += 1;
            println!("[T94]   ✓ {label}");
        } else {
            self.fail += 1;
            println!("[T94]   ✗ {label} — {detail}");
        }
    }
}

// ═══════════════════════ 用例（串行，见文件头 ③）═══════════════════════

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn t94_webdav_proxy_and_protocol_e2e() {
    let mut r = Report { pass: 0, fail: 0 };
    println!("[T94] ==== T94 WebDAV 代理 / 协议端到端 ====");

    // ───────── ① 自检：两个仪器都活着，且假代理真的会回 502 ─────────
    let proxy = FakeProxy::start();
    {
        let c = reqwest::Client::new();
        let code = c
            .get(proxy.url())
            .send()
            .await
            .map(|x| x.status().as_u16())
            .unwrap_or(0);
        r.crit(
            "S1 假代理仪器自检：它确实回 502",
            code == 502,
            &format!("读到 HTTP {code}（want 502）"),
        );
    }

    let root = work_dir("dav");
    let dav = MiniDav::start(root.clone(), "u", "p");
    {
        // 真服务器的阳性对照：能 ping 通（不经假代理）
        let be = WebdavBackend::new(cfg(&dav.url(), "p", "")).expect("WebdavBackend::new");
        let ping = be.ping().await;
        r.crit(
            "S2 真 WebDAV 仪器自检：ping() 成功",
            matches!(&ping, Ok(s) if s == "连接正常"),
            &format!("{ping:?}"),
        );
    }

    // ───────── ② ★ 缺陷本体：设了 HTTP_PROXY 之后，回环地址必须仍然直连 ─────────
    //
    // 旧实现下这里的读数是 `HTTP 502`（被假代理截走）；新实现必须是 404/None
    // （真服务器的正常回答）。
    {
        let _g = EnvGuard::set(&[("HTTP_PROXY", Some(&proxy.url()))]);
        // 只看本步的增量（S1 自检也打过假代理一次，那不算）
        let baseline = proxy.hits();
        let be = WebdavBackend::new(cfg(&dav.url(), "p", "")).expect("WebdavBackend::new");
        let got = be.etag("manifest.json").await;
        let direct = matches!(&got, Ok(None)); // 真服务器：文件不存在 ⇒ Ok(None)
        let proxied = match &got {
            Err(e) => http_code_in(e) == Some(502),
            Ok(_) => false,
        };
        r.crit(
            "★ E1 设了 HTTP_PROXY 之后，回环 WebDAV 仍直连（不被系统代理截走）",
            direct && proxy.hits() == baseline,
            &format!(
                "etag={got:?}；假代理本步被命中 {} 次（want 0）",
                proxy.hits() - baseline
            ),
        );
        r.crit(
            "E2 上面这条是「没走代理」的正读数：绝不是假代理的 502",
            !proxied,
            "读到了 502，说明请求被代理截走了（缺陷仍在）",
        );
        // 反向自检：把同一个代理**不用**任何绕过规则地去打公网 IP
        let before = proxy.hits();
        let be_pub = WebdavBackend::new(cfg("http://203.0.113.7", "p", ""))
            .expect("WebdavBackend::new (public)");
        let pubres = be_pub.etag("manifest.json").await;
        r.crit(
            "★ E3 反证：公网地址**确实**会用环境变量里的代理",
            proxy.hits() > before,
            &format!("假代理命中数没涨（before={before} now={}）", proxy.hits()),
        );
        r.crit(
            "E4 反证成立时读到的必须是假代理的 502",
            match &pubres {
                Err(e) => http_code_in(e) == Some(502),
                Ok(v) => {
                    let _ = v;
                    false
                }
            },
            &format!("{pubres:?}"),
        );
    }

    // ───────── ③ `NO_PROXY` 仍然生效 ─────────
    {
        let _g = EnvGuard::set(&[
            ("HTTP_PROXY", Some(&proxy.url())),
            ("NO_PROXY", Some("dav.jianguoyun.com")),
        ]);
        let before = proxy.hits();
        let be = WebdavBackend::new(cfg("http://dav.jianguoyun.com", "p", ""))
            .expect("WebdavBackend::new (no_proxy)");
        let _ = be.etag("manifest.json").await;
        r.crit(
            "E5 NO_PROXY 里列出的域名不被代理截走",
            proxy.hits() == before,
            &format!("命中数从 {before} 涨到 {}", proxy.hits()),
        );
    }

    // ───────── ④ 没配代理时，完整一轮协议流程（阳性对照）─────────
    {
        let _g = EnvGuard::clean();
        let be = WebdavBackend::new(cfg(&dav.url(), "p", "")).expect("WebdavBackend::new");
        be.ensure_dir("data").await.expect("ensure_dir");
        be.put("data/a.json", b"hello", None).await.expect("put");
        let got = be.get("data/a.json").await.expect("get");
        r.crit(
            "P1 PUT 之后 GET 读回同样的字节",
            got.as_ref().map(|(b, _)| b.as_slice()) == Some(&b"hello"[..]),
            &format!("{got:?}"),
        );

        let tag = be.etag("data/a.json").await.expect("etag");
        r.crit(
            "P2 写完拿得到 ETag（PUT 响应头里没有，必须另发 PROPFIND）",
            tag.is_some(),
            &format!("etag = {tag:?}"),
        );

        let list = be.list("data").await.expect("list");
        r.crit(
            "P3 列目录认得大写 D: 前缀，且只列文件不列目录",
            list.iter().map(|e| e.name.as_str()).collect::<Vec<_>>() == vec!["a.json"]
                && list[0].bytes == 5,
            &format!("{list:?}"),
        );

        be.delete("data/a.json").await.expect("delete");
        r.crit(
            "P4 删掉后再 GET 得到 None",
            be.get("data/a.json").await.expect("get after delete").is_none(),
            "删了还读得到",
        );

        // 幂等：再删一次（404）必须当成功，否则保留清理会整次失败
        let again = be.delete("data/a.json").await;
        r.crit(
            "P5 重复删除（404）视为成功 —— 保留清理可能重跑",
            again.is_ok(),
            &format!("{again:?}"),
        );
    }

    // ───────── ⑤ 错密码 ⇒ 401，文案指向「凭据」而不是「网络」 ─────────
    {
        let _g = EnvGuard::clean();
        let bad = WebdavBackend::new(cfg(&dav.url(), "wrong-password", ""))
            .expect("WebdavBackend::new (bad pass)");
        let err = bad.ping().await.expect_err("错密码必须是 Err");
        r.crit(
            "A1 错密码被拒，且提示指向认证而不是网络",
            err.contains("认证失败") || err.contains("401"),
            &format!("{err}"),
        );
        // 服务不可达（真的空端口）：必须是「连不上」而不是别的
        let dead = {
            let l = TcpListener::bind("127.0.0.1:0").expect("bind ephemeral");
            let p = l.local_addr().expect("addr").port();
            drop(l);
            p
        };
        let gone =
            WebdavBackend::new(cfg(&format!("http://127.0.0.1:{dead}"), "p", ""))
                .expect("WebdavBackend::new (dead port)");
        let derr = gone.ping().await.expect_err("服务不可达必须是 Err");
        r.crit(
            "A2 服务不可达：报「连不上」而不是 HTTP 码",
            derr.contains("连接") || derr.contains("超时"),
            &format!("{derr}"),
        );
    }

    // ───────── ⑥ 子路径前缀（remote_dir）：逐级建目录，文件落在前缀之下 ─────────
    {
        let _g = EnvGuard::clean();
        let sub = work_dir("sub");
        let sub_dav = MiniDav::start(sub.clone(), "u", "p");
        let be = WebdavBackend::new(cfg(&sub_dav.url(), "p", "sourin/dav"))
            .expect("WebdavBackend::new (remote_dir)");
        be.ensure_dir("").await.expect("建出 remote_dir 链");
        be.ensure_dir("data").await.expect("建 data");
        be.put("data/x.json", b"sub", None).await.expect("put");

        r.crit(
            "★ R1 remote_dir 多级：目录被逐级建出，文件落在前缀之下",
            sub.join("sourin").join("dav").join("data").join("x.json").is_file(),
            &format!(
                "磁盘上没有 sourin/dav/data/x.json；实际内容 = {:?}",
                std::fs::read_dir(&sub)
                    .map(|d| d.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect::<Vec<_>>())
                    .unwrap_or_default()
            ),
        );
        let ping = be.ping().await;
        r.crit(
            "R2 配好之后 ping() 成功（目录已存在，不该报「路径不存在」）",
            matches!(&ping, Ok(s) if s == "连接正常"),
            &format!("{ping:?}"),
        );
        // 对照：目录**没建**时 ping 必须明确说路径问题
        let missing = WebdavBackend::new(cfg(&sub_dav.url(), "p", "not/created/yet"))
            .expect("WebdavBackend::new (missing dir)");
        let merr = missing.ping().await.expect_err("目录不存在必须是 Err");
        r.crit(
            "R3 对照：目录没建时 ping 明确提示路径问题",
            merr.contains("路径不存在") || merr.contains("404"),
            &format!("{merr}"),
        );
    }

    // ───────── ⑦ 中文路径往返 ─────────
    {
        let _g = EnvGuard::clean();
        let cn = work_dir("cn");
        let cn_dav = MiniDav::start(cn.clone(), "u", "p");
        let be = WebdavBackend::new(cfg(&cn_dav.url(), "p", "")).expect("cn engine");
        be.ensure_dir("backup/snapshots").await.expect("mkdir");
        let name = "dsh-backup-\u{5ba2}\u{5385}-20260929-101112.zip";
        be.put(&format!("backup/snapshots/{name}"), "内容".as_bytes(), None)
            .await
            .expect("put 中文名");

        let list = be.list("backup/snapshots").await.expect("list");
        let names: Vec<&str> = list.iter().map(|e| e.name.as_str()).collect();
        r.crit(
            "★ C1 中文文件名原样列回来（href 里的 %XX 必须解码）",
            names == vec![name] && list[0].bytes == "内容".len() as u64,
            &format!("names={names:?} bytes={:?}", list.first().map(|e| e.bytes)),
        );
    }

    // ───────── ⑧ 大文件（8 MB）往返 ─────────
    {
        let _g = EnvGuard::clean();
        let big = work_dir("big");
        let big_dav = MiniDav::start(big.clone(), "u", "p");
        let be = WebdavBackend::new(cfg(&big_dav.url(), "p", "")).expect("big engine");
        be.ensure_dir("backup/snapshots").await.expect("mkdir");

        // 内容可验证（非全 0），且首尾各放一个哨兵 ——
        // 「长度对但内容错」这种损坏必须被这版断言抓住
        let n = 8 * 1024 * 1024;
        let mut body: Vec<u8> = (0usize..n).map(|i: usize| (i.wrapping_mul(31) ^ (i >> 7)) as u8).collect();
        body[0] = 0xA5;
        body[n - 1] = 0x5A;
        let name = "dsh-backup-pc-20260929-101112.zip";
        be.put(&format!("backup/snapshots/{name}"), &body, None)
            .await
            .expect("put 8MB");

        let back = be
            .get(&format!("backup/snapshots/{name}"))
            .await
            .expect("get 8MB")
            .expect("必须存在");
        r.crit(
            "★ B1 8 MB 整体备份往返：长度、首尾哨兵、逐字节全对",
            back.0.len() == n && back.0 == body,
            &format!(
                "len={} want={n} 首={:#04x} 尾={:#04x}",
                back.0.len(),
                back.0.first().copied().unwrap_or(0),
                back.0.last().copied().unwrap_or(0)
            ),
        );
        let list = be.list("backup/snapshots").await.expect("list");
        r.crit(
            "B2 列目录报的大小与实际一致",
            list.first().map(|e| e.bytes) == Some(n as u64),
            &format!("{:?}", list.first().map(|e| e.bytes)),
        );
    }

    // ───────── ⑨ 服务器返回非标准 XML / 垃圾响应体：不能崩、不能误判 ─────────
    {
        let _g = EnvGuard::clean();
        let weird = work_dir("weird");
        let weird_dav = MiniDav::start(weird.clone(), "u", "p");
        let be = WebdavBackend::new(cfg(&weird_dav.url(), "p", "")).expect("weird engine");
        be.ensure_dir("backup/snapshots").await.expect("mkdir");
        be.put("backup/snapshots/dsh-backup-a-20260101-010101.zip", b"x", None)
            .await
            .expect("put");

        // ① 仪器必须真的在发 XML（否则下面的读数是空的）
        let body = reqwest::Client::new()
            .request(
                reqwest::Method::from_bytes(b"PROPFIND").unwrap(),
                format!("{}/backup/snapshots/", weird_dav.url()),
            )
            .basic_auth("u", Some("p"))
            .header("Depth", "1")
            .send()
            .await
            .expect("raw propfind")
            .text()
            .await
            .unwrap_or_default();
        r.crit(
            "X0 仪器自检：它真的回了 Multi-Status",
            body.contains("getcontentlength"),
            &format!("body[:200]={:?}", &body[..body.len().min(200)]),
        );

        // ② 子目录（`old/`）绝不能被当成一份备份 ——
        //    否则「保留 N 份」会去删目录（这是最危险的一类解析错误）
        be.ensure_dir("backup/snapshots/old").await.expect("mkdir 子目录");
        let list = be.list("backup/snapshots").await.expect("list");
        let names: Vec<&str> = list.iter().map(|e| e.name.as_str()).collect();
        r.crit(
            "★ X1 子目录绝不会被列成一份备份",
            names == vec!["dsh-backup-a-20260101-010101.zip"],
            &format!("names={names:?}"),
        );
    }

    // ───────── ⑩ 保留清理的安全护栏：只删我们自己的 dsh-backup-*.zip ─────────
    {
        let _g = EnvGuard::clean();
        let prune = work_dir("prune");
        let prune_dav = MiniDav::start(prune.clone(), "u", "p");
        let snap = prune.join("backup").join("snapshots");
        std::fs::create_dir_all(&snap).expect("seed dir");

        let decoys = [
            "README.txt",
            "my-photos.zip",
            "dsh-backup-note.txt",        // 前缀像、后缀不像
            "dsh-notes-20260101-000000.zip", // 后缀像、前缀不像
            "dsh-backup-x.zip.bak",       // 后缀多一截
        ];
        for d in decoys {
            std::fs::write(snap.join(d), b"decoy").expect("seed decoy");
        }

        let be = WebdavBackend::new(cfg(&prune_dav.url(), "p", "")).expect("prune engine");
        let engine =
            sourin_core::sync::SyncEngine::new(Arc::new(be), Arc::new(
                sourin_core::store::Db::in_memory().expect("in-memory db"),
            ), "t94".to_string());

        for name in [
            "dsh-backup-pc-20260101-010101.zip",
            "dsh-backup-pc-20260101-020202.zip",
            "dsh-backup-pc-20260101-030303.zip",
        ] {
            engine
                .backup_snapshot(name, b"zip-bytes", 2)
                .await
                .unwrap_or_else(|e| panic!("上传 {name} 失败: {e}"));
        }

        let dead: Vec<&str> = decoys
            .iter()
            .copied()
            .filter(|d| !snap.join(d).is_file())
            .collect();
        r.crit(
            "★ G1 保留清理之后，5 个「像备份但不是我们写的」文件一个都没被删",
            dead.is_empty(),
            &format!("被误删 = {dead:?}"),
        );
        let left: Vec<String> = std::fs::read_dir(&snap)
            .expect("read snap dir")
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.ends_with(".zip") && n.starts_with("dsh-backup-"))
            .collect();
        r.crit(
            "G2 云端只剩 2 份自己的备份（3 份上传，保留 2）",
            left.len() == 2,
            &format!("left={left:?}"),
        );

        // 删除别人的文件必须被拒绝（名字不合规 ⇒ 一律 Ok(false)，不报错）
        let refused = engine.delete_snapshot("README.txt").await;
        r.crit(
            "G3 名字不合规的删除被拒绝（返回 Ok(false)，不报错）",
            matches!(refused, Ok(false)),
            &format!("{refused:?}"),
        );
        r.crit(
            "G4 被拒绝之后 README.txt 仍在磁盘上",
            snap.join("README.txt").is_file(),
            "护栏失效了",
        );
    }

    println!("[T94] RESULT pass={} fail={}", r.pass, r.fail);
    assert_eq!(
        r.fail, 0,
        "T94: {} 条判据未通过（看上面的 [T94] 行）",
        r.fail
    );
}