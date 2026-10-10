// ═══════════════════════════════════════════════════════════════════════
//  task-13 探针：影视建安（154）「有的时候能播有的时候不能」
// ═══════════════════════════════════════════════════════════════════════
//
// Owner 原话（第三批第 4 条）：
//   > 影视建安这个是邮的时候能播放有的时候不能播放
// 第一批第 14 条同现象：
//   > 同一个源下的有些可以看,有些提示 这个源没有课播放的地址
//
// # 要回答两个问题
//
// ¤¤¤text
// ① 三个候选环节，谁在"有的时候"失效？
//    a) 上游 API 间歇抽风（videolist 空/超时）
//    b) 分享页（爱奇艺/优酷网页）间歇拿不到 m3u8
//    c) tryParsers 第三方解析接口间歇不可用
// ② 「有的能看有的不能」取决于**作品**还是**时间**？
// ¤¤¤
//
// # 三个维度分开测（不混在一起，否则说不清是哪一层）
//
// ¤¤¤text
// A 时间维度：同一作品连续 N 次 detail+resolve ⇒ 失败占比 = "有的时候"的量化
// B 作品维度：同源取 M 个不同作品，各跑一次 ⇒ 看成败是否与作品绑定
// C 环节维度：把三级回退各自单独打，定位是哪一级断的
// ¤¤¤
//
// ★ 只读纪律：拷真实插件到**隔离目录**，绝不写 %APPDATA%。
//
// 用法：
//   cargo test --test t13_154_flaky -- --ignored --nocapture
//   cargo test --test t13_154_flaky -- --ignored --nocapture -- 时间

use sourin_core::commands_provider as cp;
use sourin_core::model::{MediaId, PlayRequest};
use sourin_core::provider::MediaProvider;
use sourin_core::state::AppState;
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

/// 隔离目录 + 真实插件（只读复制）
async fn with_real_plugins(tag: &str) -> Arc<AppState> {
    let dir = std::env::temp_dir().join(format!(
        "sourin-t13-{tag}-{}",
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let st = AppState::bootstrap(dir).await.expect("bootstrap");
    let appdata = std::env::var("APPDATA").unwrap();
    let src = std::path::PathBuf::from(&appdata)
        .join("app.sourin.player")
        .join("plugins");
    let dst = st.data_dir.join("plugins");
    std::fs::create_dir_all(&dst).unwrap();
    let mut copied = 0;
    for e in std::fs::read_dir(&src).unwrap().flatten() {
        if e.path().extension().and_then(|s| s.to_str()) == Some("js") {
            if std::fs::copy(e.path(), dst.join(e.file_name())).is_ok() {
                copied += 1;
            }
        }
    }
    if copied > 0 {
        let _ = cp::reload_plugins(&st).await;
    }
    st
}

/// 一次「取第一集地址 → resolve」的结果分类
#[derive(Debug, Clone, PartialEq, Eq)]
enum Outcome {
    /// 拿到了看起来能播的地址
    Ok(String),
    /// 报"没有可直接播放的地址"
    NoAddr,
    /// 报"只提供爱奇艺/优酷等站点的网页链接"（解析服务全挂）
    ThirdPartyOnly,
    /// 上游列表/详情就失败了
    Upstream(String),
    /// 别的错
    Other(String),
}

impl Outcome {
    fn kind(&self) -> &'static str {
        match self {
            Outcome::Ok(_) => "ok",
            Outcome::NoAddr => "noaddr",
            Outcome::ThirdPartyOnly => "thirdparty",
            Outcome::Upstream(_) => "upstream",
            Outcome::Other(_) => "other",
        }
    }
}

async fn once(p: &dyn MediaProvider, id: &MediaId) -> Outcome {
    let d = match p.detail(id).await {
        Ok(d) => d,
        Err(e) => return Outcome::Upstream(e.message),
    };
    let Some(ep) = d.episodes.first() else {
        return Outcome::Upstream("详情里 0 集".into());
    };
    let mid = MediaId::new(id.provider.clone(), ep.id.clone());
    match p.resolve(&mid, &PlayRequest::default()).await {
        Ok(list) => Outcome::Ok(list.first().map(|c| c.url.clone()).unwrap_or_default()),
        Err(e) => {
            let m = &e.message;
            if m.contains("没有可直接播放的地址") {
                Outcome::NoAddr
            } else if m.contains("需要在线解析服务") || m.contains("只提供爱奇艺") {
                Outcome::ThirdPartyOnly
            } else if m.contains("请求失败") || m.contains("network") || m.contains("超时") {
                Outcome::Upstream(m.clone())
            } else {
                Outcome::Other(m.clone())
            }
        }
    }
}

fn short(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

// ═══════════════════════════════════════════════════════════════════════
//  A 时间维度：同一作品连跑 N 次
// ═══════════════════════════════════════════════════════════════════════

#[tokio::test]
#[ignore = "真网络探针，显式 --ignored 运行"]
async fn a_time_dimension_same_item_20_times() {
    let st = with_real_plugins("154time").await;
    let pid = MediaId::new("154", "1");
    let p = st.registry.route(&pid).expect("154 未注册");

    // 先拿一个真实作品
    let cats = p.categories().await.unwrap_or_default();
    let cat = cats.iter().find(|c| !c.id.is_empty()).expect("无分类");
    let page = p
        .list(ListRequest2::make(&cat.id))
        .await
        .expect("list 失败");
    let item = page.items.into_iter().next().expect("列表为空");
    println!("\n════ A 时间维度 ════");
    println!("作品 = {}  (id={})", item.title, item.id.native);

    let n = 20;
    let mut stat: BTreeMap<&'static str, usize> = BTreeMap::new();
    let mut detail_stat: BTreeMap<&'static str, usize> = BTreeMap::new();
    let mut sample: Vec<String> = Vec::new();

    for i in 1..=n {
        // 单独记录 detail 这一层（区分"上游抽风"和"解析抽风"）
        let d = p.detail(&item.id).await;
        let dkind = match &d {
            Ok(dd) if !dd.episodes.is_empty() => "detail-ok",
            Ok(_) => "detail-0集",
            Err(_) => "detail-失败",
        };
        *detail_stat.entry(dkind).or_insert(0) += 1;

        let o = once(p.as_ref(), &item.id).await;
        *stat.entry(o.kind()).or_insert(0) += 1;
        let line = format!("  第{i:>2} 次: {:<11} {}", o.kind(), match &o {
            Outcome::Ok(u) => short(u, 70),
            Outcome::NoAddr => "「没有可直接播放的地址」".into(),
            Outcome::ThirdPartyOnly => "「需要在线解析服务」".into(),
            Outcome::Upstream(m) => format!("上游: {}", short(m, 60)),
            Outcome::Other(m) => format!("其它: {}", short(m, 60)),
        });
        println!("{line}");
        sample.push(line);
        if i < n {
            tokio::time::sleep(Duration::from_millis(2500)).await;
        }
    }

    println!("\n  ── 汇总（{n} 次）──");
    for (k, v) in &stat {
        println!("    {k:<12} {v:>2} 次  ({:.0}%)", *v as f64 * 100.0 / n as f64);
    }
    println!("  ── detail 这一层 ──");
    for (k, v) in &detail_stat {
        println!("    {k:<12} {v:>2} 次");
    }
    let ok = *stat.get("ok").unwrap_or(&0);
    println!("\n  ★ 同一作品 {n} 次里 {ok} 次成功，{} 次失败", n - ok);
}

/// 小工具：ListRequest 构造（避免在测试里到处写 filters）
struct ListRequest2;
impl ListRequest2 {
    fn make(cat: &str) -> sourin_core::provider::ListRequest {
        sourin_core::provider::ListRequest {
            category_id: cat.to_string(),
            page: 1,
            filters: Default::default(),
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  B 作品维度：同源多个作品，各跑一次
// ═══════════════════════════════════════════════════════════════════════

#[tokio::test]
#[ignore = "真网络探针，显式 --ignored 运行"]
async fn b_item_dimension_many_items() {
    let st = with_real_plugins("154item").await;
    let pid = MediaId::new("154", "1");
    let p = st.registry.route(&pid).expect("154 未注册");

    let cats = p.categories().await.unwrap_or_default();
    println!("\n════ B 作品维度 ════");
    println!("分类数 = {}", cats.len());

    let mut all: Vec<(String, String, Outcome)> = Vec::new();
    // 跨分类取样（避免只碰到同一类作品）
    for c in cats.iter().take(4) {
        let Ok(page) = p.list(ListRequest2::make(&c.id)).await else {
            println!("  [{}] list 失败", c.name);
            continue;
        };
        for it in page.items.iter().take(6) {
            let o = once(p.as_ref(), &it.id).await;
            let ep = p
                .detail(&it.id)
                .await
                .ok()
                .and_then(|d| d.episodes.first().map(|e| e.id.clone()))
                .unwrap_or_default();
            println!(
                "  [{}] {:<28} {:<11} {}",
                c.name,
                short(&it.title, 26),
                o.kind(),
                short(&ep, 62)
            );
            all.push((it.title.clone(), ep, o));
        }
    }

    println!("\n  ── 汇总 ──");
    let mut stat: BTreeMap<&'static str, usize> = BTreeMap::new();
    for (_, _, o) in &all {
        *stat.entry(o.kind()).or_insert(0) += 1;
    }
    let tot = all.len();
    for (k, v) in &stat {
        println!("    {k:<12} {v:>2} 次  ({:.0}%)", *v as f64 * 100.0 / tot as f64);
    }

    // 按"地址形态"分类统计 —— 这才是"有的能看有的不能"的真正解释
    println!("\n  ── 按剧集地址形态 ──");
    let mut form: BTreeMap<&'static str, (usize, usize)> = BTreeMap::new();
    for (_, ep, o) in &all {
        let k = if ep.is_empty() {
            "（无地址）"
        } else if ep.to_lowercase().contains(".m3u8") {
            "直链 m3u8"
        } else if ep.to_lowercase().contains(".mp4") {
            "直链 mp4"
        } else if ep.contains("iqiyi") || ep.contains("youku") || ep.contains("qq.com")
            || ep.contains("mgtv") || ep.contains("bilibili") || ep.contains("le.com")
            || ep.contains("sohu")
        {
            "第三方网页（需解析）"
        } else if ep.starts_with("http") {
            "其它网页"
        } else {
            "非 http"
        };
        let e = form.entry(k).or_insert((0, 0));
        if matches!(o, Outcome::Ok(_)) {
            e.0 += 1;
        } else {
            e.1 += 1;
        }
    }
    println!("    {:<22} {:>6} {:>6}", "形态", "成功", "失败");
    for (k, (ok, bad)) in &form {
        println!("    {k:<22} {ok:>6} {bad:>6}");
    }
    println!("\n  ★ 共 {tot} 个作品");
}

// ═══════════════════════════════════════════════════════════════════════
//  C 环节维度：分别打上游 API / 分享页 / 解析服务
// ═══════════════════════════════════════════════════════════════════════

#[tokio::test]
#[ignore = "真网络探针，显式 --ignored 运行"]
async fn c_stage_dimension() {
    println!("\n════ C 环节维度 ════");
    let api = "http://154.219.117.232:9981/jacloudapi.php/provide/vod";
    let cli = reqwest::Client::builder()
        .user_agent(sourin_core::tvbox::TVBOX_UA)
        .timeout(Duration::from_secs(15))
        .build()
        .unwrap();

    // ① 上游 API 本身
    println!("\n  ① 上游 API（ac=videolist&pg=1）连打 10 次");
    let mut s: BTreeMap<String, usize> = BTreeMap::new();
    for i in 1..=10 {
        let k = match cli.get(format!("{api}?ac=videolist&pg=1")).send().await {
            Ok(r) => {
                let code = r.status().as_u16();
                let body = r.text().await.unwrap_or_default();
                let n = serde_json::from_str::<serde_json::Value>(&body)
                    .ok()
                    .and_then(|v| v.get("list").and_then(|l| l.as_array()).map(|a| a.len()));
                match n {
                    Some(n) => format!("HTTP {code} list={n}"),
                    None => format!("HTTP {code} 非JSON(len={})", body.len()),
                }
            }
            Err(e) => format!("传输错误 {}", if e.is_timeout() { "超时" } else { "其它" }),
        };
        *s.entry(k.clone()).or_insert(0) += 1;
        if i <= 3 || i == 10 {
            println!("     第{i:>2} 次: {k}");
        }
        tokio::time::sleep(Duration::from_millis(800)).await;
    }
    println!("     ── 分布 ──");
    for (k, v) in &s {
        println!("       {k:<26} {v} 次");
    }

    // ② 解析服务（插件里那两个）
    println!("\n  ② 第三方解析服务可用性（对同一个网页 URL 各试 3 次）");
    let probe_page = "https://www.iqiyi.com/v_1hn0p07xxls.html";
    for base in [
        "https://player.gimy.bot/u/parse.php?url=",
        // ★ 2026-10-10：这里原来还有 `api.huaqi.pro/api/?key=<真实凭据>`。
        //   那是**付费服务的真实密钥**，被硬编码进了公开仓库；而产品侧早已把它
        //   从 `PARSE_SERVICES` 里删掉（实测 2026-10-02 起它就返回 404 不再工作）。
        //   ⇒ 这里一并删除，不要把任何人的密钥写进仓库。
    ] {
        let url = format!("{base}{}", urlencoding(probe_page));
        let host = base.split('/').nth(2).unwrap_or("?");
        for i in 1..=3 {
            match cli.get(&url).send().await {
                Ok(r) => {
                    let code = r.status().as_u16();
                    let body = r.text().await.unwrap_or_default();
                    println!(
                        "     {host:<18} 第{i} 次: HTTP {code} len={} 前80字={}",
                        body.len(),
                        short(&body.replace(['\n', '\r'], " "), 80)
                    );
                    break; // 一个服务通了就够了，省时间
                }
                Err(e) => {
                    println!(
                        "     {host:<18} 第{i} 次: {}",
                        if e.is_timeout() { "超时".into() } else { format!("错误 {e}").chars().take(70).collect::<String>() }
                    );
                }
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
    }
    println!("\n  ★ 环节维度完成");
}

fn urlencoding(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}
