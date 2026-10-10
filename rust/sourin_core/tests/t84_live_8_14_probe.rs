// ═══════════════════════════════════════════════════════════════════════
//  临时探针：Owner 缺陷 8（央视直播整组只能黑屏 → 应直接不出现）
//           + Owner 缺陷 14（同一源下部分作品报「没有可播放的地址」）
// ═══════════════════════════════════════════════════════════════════════
//
// 与 t79 的区别：t79 只统计「有没有报错」，本探针把**核心返回的原始候选逐条打出来**
// （条数 / drm_protected / url 是否空 / not_web_ready / kind / quality），
// 用来区分三种病因：
//   (a) 源站没给地址      → 候选 0 条，或候选全空 url
//   (b) 我们过滤掉了      → 候选有、url 非空、drm=false，却被某处丢掉
//   (c) 候选被标 DRM      → drm_protected=true（央视视频线）
//
// 运行（真网络，必须 --ignored）：
//   cargo test --manifest-path rust/sourin_core/Cargo.toml --test t84_live_8_14_probe -- --ignored --nocapture --test-threads=1
//
// ★ 只读用户目录：plugins 从 %APPDATA%\app.sourin.player\plugins 复制到临时目录，
//   绝不写入用户目录（全队硬规则 2）。

use sourin_core::commands as cmds;
use sourin_core::commands_provider as cp;
use sourin_core::model::{MediaId, PlayRequest};
use sourin_core::provider::ListRequest;
use sourin_core::state::AppState;
use std::sync::Arc;

fn head(s: &str, n: usize) -> String {
    s.chars().take(n).collect::<String>()
}

fn host_of(u: &str) -> String {
    let s = u
        .strip_prefix("https://")
        .or_else(|| u.strip_prefix("http://"))
        .unwrap_or(u);
    s.split(['/', '?']).next().unwrap_or("").to_string()
}

async fn with_real_plugins(tag: &str) -> Arc<AppState> {
    let dir = std::env::temp_dir().join(format!(
        "sourin-t84-{tag}-{}",
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
    println!("[t84] 隔离目录 {} | 复制插件 {copied} 个", st.data_dir.display());
    st
}

/// 逐条打印核心返回的原始候选（这是「源站没给 / 我们过滤掉 / 被标 DRM」的判据）
fn dump_candidates(prefix: &str, list: &[sourin_core::model::StreamCandidate]) {
    println!("[t84]   {prefix} → 候选 {} 条", list.len());
    for (i, c) in list.iter().enumerate() {
        let j = serde_json::to_value(c).unwrap_or(serde_json::Value::Null);
        println!(
            "[t84]     #{i} kind={:?} quality={:?} label={:?} drm={} not_web_ready={} url_len={} url={} | audio_url={} | raw={}",
            c.kind,
            c.quality,
            c.label,
            c.drm_protected,
            c.not_web_ready,
            c.url.len(),
            head(&c.url, 110),
            c.audio_url.as_deref().map(|u| head(u, 60)).unwrap_or_else(|| "-".into()),
            head(&j.to_string(), 220),
        );
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  A. 缺陷 8：央视直播频道真实可用性（真调核心 get_live_channels / get_live_stream）
// ═══════════════════════════════════════════════════════════════════════
#[tokio::test]
#[ignore = "真网络探针，显式 --ignored 运行"]
async fn cctv_live_availability_matrix() {
    let st = with_real_plugins("live").await;
    let all = cmds::get_live_channels(&st).await.expect("get_live_channels");
    println!("[t84] 直播源 {} 个", all.len());
    for v in &all {
        let prov = v["provider"].as_str().unwrap_or("?");
        let chs = v["channels"].as_array().cloned().unwrap_or_default();
        println!(
            "[t84]   源 {prov:<14} 频道 {} 个 | 字段 {:?}",
            chs.len(),
            chs.first()
                .and_then(|c| c.as_object())
                .map(|o| o.keys().cloned().collect::<Vec<_>>())
                .unwrap_or_default()
        );
    }

    let cctv = all
        .iter()
        .find(|v| v["provider"].as_str() == Some("cctv"))
        .cloned();
    let Some(cctv) = cctv else {
        println!("[t84] ★ cctv 源未注册（插件未加载）—— 探针终止");
        return;
    };
    let chs = cctv["channels"].as_array().cloned().unwrap_or_default();
    println!("[t84] ==== cctv 频道表 {} 个，逐个真取流 ====", chs.len());

    let mut n_ok_any = 0usize;
    let mut n_playable = 0usize;
    let mut n_only_audio = 0usize;
    let mut n_err = 0usize;
    let mut n_empty = 0usize;
    let mut rows: Vec<String> = Vec::new();

    for c in &chs {
        let id = c["id"].as_str().unwrap_or("").to_string();
        let name = c["name"].as_str().unwrap_or("").to_string();
        let group = c["group"].as_str().unwrap_or("").to_string();
        let t0 = std::time::Instant::now();
        match cmds::get_live_stream(&st, "cctv", &id).await {
            Ok(list) => {
                let playable: Vec<_> = list
                    .iter()
                    .filter(|s| !s.drm_protected && !s.url.is_empty())
                    .collect();
                let video_playable = playable
                    .iter()
                    .filter(|s| {
                        let q = format!(
                            "{}{}",
                            s.quality.as_deref().unwrap_or(""),
                            s.label.as_deref().unwrap_or("")
                        );
                        let q = q.to_lowercase();
                        !(q.contains("音频") || q.contains("广播") || q.contains("audio"))
                    })
                    .count();
                if list.is_empty() {
                    n_empty += 1;
                } else {
                    n_ok_any += 1;
                }
                if video_playable > 0 {
                    n_playable += 1;
                } else if !playable.is_empty() {
                    n_only_audio += 1;
                }
                let drm_n = list.iter().filter(|s| s.drm_protected).count();
                println!(
                    "[t84] {group:<8} {name:<12} id={id:<8} 候选 {} | playable {} | 非DRM视频线 {} | DRM {} | {}ms",
                    list.len(),
                    playable.len(),
                    video_playable,
                    drm_n,
                    t0.elapsed().as_millis()
                );
                for (i, s) in list.iter().enumerate() {
                    println!(
                        "[t84]      #{i} quality={:?} label={:?} drm={} url={}",
                        s.quality,
                        s.label,
                        s.drm_protected,
                        head(&s.url, 130)
                    );
                }
                rows.push(format!(
                    "{name}|{id}|{}|{}|{}|{}",
                    list.len(),
                    playable.len(),
                    video_playable,
                    drm_n
                ));
            }
            Err(e) => {
                n_err += 1;
                println!("[t84] {group:<8} {name:<12} id={id:<8} ★核心报错: {e}");
                rows.push(format!("{name}|{id}|ERR|0|0|0|{e}"));
            }
        }
    }
    println!(
        "[t84] ==== cctv 汇总：频道 {} | 有候选 {} | 有非DRM视频线 {} | 仅音频 {} | 空候选 {} | 报错 {}",
        chs.len(),
        n_ok_any,
        n_playable,
        n_only_audio,
        n_empty,
        n_err
    );
    println!("[t84] ==== 逐频道行（name|id|候选数|playable数|非DRM视频线数|DRM数）");
    for r in &rows {
        println!("[t84]   {r}");
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  B. 缺陷 14：多源 × 多作品 resolve，统计空候选比例 + 打印失败样本原始候选
// ═══════════════════════════════════════════════════════════════════════
#[tokio::test]
#[ignore = "真网络探针，显式 --ignored 运行"]
async fn resolve_empty_candidate_matrix() {
    let st = with_real_plugins("resolve").await;
    let provs = ["cj", "ffzy", "caiji", "jszyapi", "suoniapi", "tyyszy", "360", "api"];
    let per_src = 8usize;

    let mut tot_ok = 0usize;
    let mut tot_empty = 0usize;
    let mut tot_all_drm = 0usize;
    let mut tot_err = 0usize;

    for prov in provs {
        let pid = MediaId::new(prov, "1");
        let Some(p) = st.registry.route(&pid) else {
            println!("[t84] -- {prov}: 未注册");
            continue;
        };
        let cats = p.categories().await.unwrap_or_default();
        let Some(cat) = cats.iter().find(|c| !c.id.is_empty()) else {
            println!("[t84] -- {prov}: 无可用分类（{} 个）", cats.len());
            continue;
        };
        let page = match p
            .list(ListRequest {
                category_id: cat.id.clone(),
                page: 1,
                filters: Default::default(),
            })
            .await
        {
            Ok(pg) => pg,
            Err(e) => {
                println!("[t84] -- {prov}: list 失败 {}", e.message);
                continue;
            }
        };
        let items: Vec<_> = page.items.into_iter().take(per_src).collect();
        println!("[t84] ==== 源 {prov} 分类 {:?} 取 {} 条 ====", cat.name, items.len());
        let (mut ok, mut empty, mut alldrm, mut err) = (0usize, 0usize, 0usize, 0usize);
        for it in &items {
            let ep_url = match p.detail(&it.id).await {
                Ok(d) => d.episodes.first().map(|e| e.id.clone()).unwrap_or_default(),
                Err(e) => {
                    println!("[t84]   × {} detail 失败: {}", head(&it.title, 24), e.message);
                    err += 1;
                    continue;
                }
            };
            let mid = MediaId::new(prov, ep_url.clone());
            match p.resolve(&mid, &PlayRequest::default()).await {
                Ok(list) => {
                    if list.is_empty() {
                        empty += 1;
                        println!(
                            "[t84]   ⚠ {} | ep={} → ★候选 0 条（核心没报错但也没地址）",
                            head(&it.title, 24),
                            head(&ep_url, 80)
                        );
                    } else if list.iter().all(|s| s.drm_protected || s.url.is_empty()) {
                        alldrm += 1;
                        println!(
                            "[t84]   ⚠ {} | ep={} → 候选全不可播",
                            head(&it.title, 24),
                            head(&ep_url, 80)
                        );
                        dump_candidates("失败样本原始候选", &list);
                    } else {
                        ok += 1;
                        if ok <= 2 {
                            println!(
                                "[t84]   ✓ {} | ep_host={} → {} 条",
                                head(&it.title, 24),
                                host_of(&ep_url),
                                list.len()
                            );
                            dump_candidates("样本原始候选", &list);
                        }
                    }
                }
                Err(e) => {
                    err += 1;
                    println!(
                        "[t84]   × {} | ep={} | host={} → 核心抛错: {}",
                        head(&it.title, 24),
                        head(&ep_url, 80),
                        host_of(&ep_url),
                        e.message
                    );
                }
            }
        }
        println!(
            "[t84] {prov:<11} 共 {} 条 | 有候选 {ok} | 空候选 {empty} | 全DRM/空url {alldrm} | 抛错 {err}",
            items.len()
        );
        tot_ok += ok;
        tot_empty += empty;
        tot_all_drm += alldrm;
        tot_err += err;
    }
    println!(
        "[t84] ==== 合计 有候选 {tot_ok} / 空候选 {tot_empty} / 全DRM或空url {tot_all_drm} / 抛错 {tot_err}"
    );
}

// ═══════════════════════════════════════════════════════════════════════
//  C. 缺陷 8 的决定性证据：直接抓央视 hls1（标 DRM 的那条）看是否真被加密
//     判据：ffprobe 能列出 h264 视频轨，但 ffmpeg 解码 3 秒出现
//           error while decoding MB / top block unavailable ⇒ 载荷加密
// ═══════════════════════════════════════════════════════════════════════
fn ffprobe_path() -> String {
    if let Ok(p) = std::env::var("SOURIN_FFPROBE") {
        return p;
    }
    let cand = "C:\\Users\\iuuuuuuuu\\AppData\\Local\\Programs\\ffmpeg\\ffmpeg-2026-05-28-git-7b46c6a2a3-full_build\\bin\\ffprobe.exe";
    if std::path::Path::new(cand).exists() {
        return cand.to_string();
    }
    "ffprobe".to_string()
}

fn ffmpeg_path() -> String {
    if let Ok(p) = std::env::var("SOURIN_FFMPEG") {
        return p;
    }
    let cand = "C:\\Users\\iuuuuuuuu\\AppData\\Local\\Programs\\ffmpeg\\ffmpeg-2026-05-28-git-7b46c6a2a3-full_build\\bin\\ffmpeg.exe";
    if std::path::Path::new(cand).exists() {
        return cand.to_string();
    }
    "ffmpeg".to_string()
}

async fn run_cmd(mut cmd: tokio::process::Command) -> String {
    match cmd.output().await {
        Ok(o) => format!(
            "exit={:?}\n  stdout: {}\n  stderr: {}",
            o.status.code(),
            head(&String::from_utf8_lossy(&o.stdout), 500),
            head(&String::from_utf8_lossy(&o.stderr), 700)
        ),
        Err(e) => format!("spawn 失败: {e}"),
    }
}

#[tokio::test]
#[ignore = "真网络探针，显式 --ignored 运行"]
async fn cctv_hls_drm_decode_probe() {
    let st = with_real_plugins("drm").await;
    let chs = cmds::get_live_channels(&st).await.expect("channels");
    let cctv = chs
        .iter()
        .find(|v| v["provider"].as_str() == Some("cctv"))
        .cloned()
        .expect("cctv 源");
    let ids: Vec<String> = cctv["channels"]
        .as_array()
        .unwrap()
        .iter()
        .take(2)
        .map(|c| c["id"].as_str().unwrap_or("").to_string())
        .collect();

    for id in ids {
        let list = match cmds::get_live_stream(&st, "cctv", &id).await {
            Ok(l) => l,
            Err(e) => {
                println!("[t84] 频道 {id} 取流失败: {e}");
                continue;
            }
        };
        println!("[t84] ==== 频道 {id} 候选 {} 条，逐条 ffprobe/ffmpeg ====", list.len());
        for c in list.iter().take(4) {
            println!(
                "[t84] -- {:?}/{:?} drm={} url={}",
                c.quality,
                c.label,
                c.drm_protected,
                head(&c.url, 120)
            );
            let hdr = c
                .headers
                .iter()
                .map(|(k, v)| format!("{k}: {v}\r\n"))
                .collect::<String>();
            let mut fp = tokio::process::Command::new(ffprobe_path());
            fp.args([
                "-hide_banner",
                "-v",
                "error",
                "-print_format",
                "json",
                "-show_streams",
                "-show_format",
                "-read_intervals",
                "%+2",
                "-rw_timeout",
                "15000000",
            ]);
            if !hdr.is_empty() {
                fp.arg("-headers").arg(&hdr);
            }
            fp.arg(&c.url);
            println!("[t84]    ffprobe: {}", run_cmd(fp).await);

            let mut fm2 = tokio::process::Command::new(ffmpeg_path());
            fm2.args([
                "-hide_banner",
                "-v",
                "error",
                "-stats",
                "-i",
                &c.url,
                "-t",
                "3",
                "-f",
                "null",
                "-",
            ]);
            if !hdr.is_empty() {
                let mut fm3 = tokio::process::Command::new(ffmpeg_path());
                fm3.args([
                    "-hide_banner",
                    "-v",
                    "error",
                    "-headers",
                    &hdr,
                    "-i",
                    &c.url,
                    "-t",
                    "3",
                    "-f",
                    "null",
                    "-",
                ]);
                println!("[t84]    ffmpeg(带headers): {}", run_cmd(fm3).await);
            } else {
                println!("[t84]    ffmpeg: {}", run_cmd(fm2).await);
            }
        }
    }
}
