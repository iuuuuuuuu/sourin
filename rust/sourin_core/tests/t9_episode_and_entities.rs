// ═══════════════════════════════════════════════════════════════════════
//  task-9 ③ 验收 —— 「播放第二集，实际还是第一集」（Owner 2026-10-09）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话
//
// > 播放第二集,实际还是第一集,这是bug
//
// # 根因（两条路都要覆盖）
//
// ```text
// ① 插件路（用户目录里那 28 个 tvbox 转换插件，模板 tools/tvbox-convert.mjs）
//    · detail() 里剧集 id **就是剧集地址**（插件自己写 id: e.url）
//    · 但 resolve(id) 只认第一个参数、**完全忽略 req** ⇒ 拿条目 id 去查详情
//      ⇒ url = eps[0].url ⇒ 永远第一集
//    · 宿主原来传的正是**条目 id**（plugins/mod.rs:2114）
//
// ② 原生路（应用内直接导入 TVBox 配置，rust/sourin_core/src/tvbox.rs）
//    · 同构：detail() 的 Episode.id = 剧集地址（:1233）
//    · resolve(id, _req) **忽略 req** ⇒ 同样永远取 episodes.first()
// ```
//
// # 修法（宿主侧适配，不改用户数据目录里的插件文件）
//
// ```text
// req.episode_id 是 http(s) URL ⇒ 它就是**剧集地址**，直接用它
// 否则（None / 空 / 纯数字条目 id）⇒ 维持原行为（取第一集）
// ```
//
// ⚠️ 判据必须精确：别的 provider 用 episode_id 表达别的东西
//    （cycani 拿它当 section_id），所以只有明确是 http(s) URL 才替换。
//
// # 本文件怎么验（不依赖真实网络，可重复）
//
// 起一个**本地假苹果CMS接口**（TcpListener），按 ids= 返回多集数据；
// 然后对**原生 Provider**（TvboxAppleCmsProvider）跑三组：
// ```text
// ① episodeId = 第1/2/3集地址 ⇒ 返回的 url 三者互不相同，且与入参对应
// ② 反向控制：episodeId = 条目 id（非 URL）⇒ 与改前逐字相同（取第一集）
// ③ 反向控制：episodeId = None ⇒ 同上
// ```

use sourin_core::model::{MediaId, PlayRequest};
use sourin_core::provider::MediaProvider;
use sourin_core::tvbox::{decode_entities, strip_tags, starts_http, TvboxAppleCmsProvider};
use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::sync::Arc;

/// 本地假苹果CMS接口 —— 只实现 `ac=videolist&ids=` 这一条
///
/// 返回一个 3 集的条目（剧集地址 e1/e2/e3.m3u8）。
/// ⚠️ 剧集地址用 **.m3u8 结尾** —— 原生 resolve 里"不是 m3u8 就去网页找"
///    那条分支会发真实请求，本地假服务不实现它 ⇒ 用 m3u8 直接短路。
fn spawn_fake_apple_cms() -> (String, Arc<std::sync::atomic::AtomicUsize>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().unwrap().port();
    let hits = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let hits2 = hits.clone();

    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut s) = stream else { continue };
            let mut reader = BufReader::new(s.try_clone().unwrap());
            let mut line = String::new();
            if reader.read_line(&mut line).is_err() {
                continue;
            }
            // 读掉请求头
            loop {
                let mut h = String::new();
                if reader.read_line(&mut h).unwrap_or(0) == 0 || h == "\r\n" {
                    break;
                }
            }
            hits2.fetch_add(1, std::sync::atomic::Ordering::SeqCst);

            let body = r#"{"code":1,"list":[{"vod_id":"150758","vod_name":"测试剧","vod_pic":"","vod_remarks":"",
"vod_content":"<p>介绍&nbsp;文本&amp;更多</p>",
"vod_play_url":"第1集$https://cdn.test/e1.m3u8#第2集$https://cdn.test/e2.m3u8#第3集$https://cdn.test/e3.m3u8",
"type_id":1,"type_id_1":1}]}"#;
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.as_bytes().len(),
                body
            );
            let _ = s.write_all(resp.as_bytes());
            let _ = s.flush();
        }
    });

    (format!("http://127.0.0.1:{port}/api.php/provide/vod"), hits)
}

fn provider(api: &str) -> TvboxAppleCmsProvider {
    TvboxAppleCmsProvider::new("t9", "T9测试源", api, Vec::new()).expect("provider")
}

fn req_with(ep: Option<&str>) -> PlayRequest {
    PlayRequest {
        source_code: None,
        episode_id: ep.map(|s| s.to_string()),
        quality: None,
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ① 核心判据：三集地址必须得到三个**不同**的 url
// ═══════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn episode_id_url_selects_that_episode() {
    let (api, _hits) = spawn_fake_apple_cms();
    let p = provider(&api);

    let mut got = Vec::new();
    for n in 1..=3 {
        let ep = format!("https://cdn.test/e{n}.m3u8");
        let out = p
            .resolve(&MediaId::new("t9", "150758"), &req_with(Some(&ep)))
            .await
            .unwrap_or_else(|e| panic!("第{n}集 resolve 失败: {e:?}"));
        assert!(!out.is_empty(), "第{n}集没有候选流");
        got.push(out[0].url.clone());
        assert_eq!(
            out[0].url, ep,
            "★ 第{n}集请求 episodeId={ep}，返回的却是 {} —— 切集没生效",
            out[0].url
        );
    }

    // ★★ 三者互不相同（这条就是 Owner 报的 bug 的反面）
    assert_ne!(got[0], got[1], "第1集与第2集返回同一个地址 ⇒ 切集无效");
    assert_ne!(got[1], got[2], "第2集与第3集返回同一个地址 ⇒ 切集无效");
    assert_ne!(got[0], got[2], "第1集与第3集返回同一个地址 ⇒ 切集无效");
}

// ═══════════════════════════════════════════════════════════════════════
//  ② 反向控制：episode_id **不是** URL ⇒ 与改前逐字相同（取第一集）
// ═══════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn non_url_episode_id_falls_back_to_first() {
    let (api, hits) = spawn_fake_apple_cms();
    let p = provider(&api);

    // 条目 id（纯数字，非 URL）—— 从播放历史/追更续播时就是这个形态
    let out = p
        .resolve(&MediaId::new("t9", "150758"), &req_with(Some("150758")))
        .await
        .expect("resolve");
    assert_eq!(
        out[0].url, "https://cdn.test/e1.m3u8",
        "非 URL 的 episode_id 必须维持原行为（取第一集）"
    );
    // 它必须**真的去查了详情**（而不是把 "150758" 当地址用）
    assert!(
        hits.load(std::sync::atomic::Ordering::SeqCst) >= 1,
        "非 URL 的 episode_id 应当走详情请求"
    );

    // 空串同理
    let out2 = p
        .resolve(&MediaId::new("t9", "150758"), &req_with(Some("")))
        .await
        .expect("resolve 空串");
    assert_eq!(out2[0].url, "https://cdn.test/e1.m3u8");

    // None 同理
    let out3 = p
        .resolve(&MediaId::new("t9", "150758"), &req_with(None))
        .await
        .expect("resolve None");
    assert_eq!(out3[0].url, "https://cdn.test/e1.m3u8");
}

// ═══════════════════════════════════════════════════════════════════════
//  ③ 判据本身：starts_http 必须**大小写不敏感**且只认完整前缀
// ═══════════════════════════════════════════════════════════════════════

#[test]
fn starts_http_judgement_is_precise() {
    // 正例
    assert!(starts_http("http://a.com/x.m3u8"));
    assert!(starts_http("https://a.com/x.m3u8"));
    assert!(starts_http("HTTP://A.COM/x"));
    assert!(starts_http("HtTpS://a.com/x"));

    // 反例 —— 这些**绝不能**被当成剧集地址
    assert!(!starts_http("150758"), "纯数字条目 id");
    assert!(!starts_http("cycani:51463"), "★ cycani 的 section_id（带前缀）");
    assert!(!starts_http("51463"), "★ cycani 的裸 section_id");
    assert!(!starts_http(""), "空串");
    assert!(!starts_http("ftp://a.com/x"), "非 http(s) 协议");
    assert!(!starts_http("//a.com/x"), "协议相对");
    assert!(!starts_http("httpx://a.com"), "httpx 不是 http");
    assert!(!starts_http("ahttps://b.com"), "前缀必须是开头");
}

// ═══════════════════════════════════════════════════════════════════════
//  ④ 详情页简介：实体必须在**数据源头**就解掉
// ═══════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn detail_description_has_no_html_entities() {
    let (api, _hits) = spawn_fake_apple_cms();
    let p = provider(&api);
    let d = p.detail(&MediaId::new("t9", "150758")).await.expect("detail");

    let desc = d.description.unwrap_or_default();
    assert!(
        !desc.contains("&nbsp;"),
        "★ 简介里还有 &nbsp;（Owner 截图报的 bug）: {desc:?}"
    );
    assert!(!desc.contains("&amp;"), "简介里还有 &amp;: {desc:?}");
    assert_eq!(desc, "介绍 文本&更多");
}

/// 纯函数层再钉一遍（不依赖网络）
#[test]
fn strip_tags_decodes_entities() {
    assert_eq!(strip_tags("<p>介绍&nbsp;文本</p>"), "介绍 文本");
    assert_eq!(strip_tags("A&amp;B"), "A&B");
    assert_eq!(strip_tags("&lt;p&gt;x&lt;/p&gt;"), "<p>x</p>");
    // ★ 顺序：&amp; 最后 ⇒ &amp;nbsp; 停在字面量
    assert_eq!(strip_tags("&amp;nbsp;"), "&nbsp;");
    assert_eq!(decode_entities("&#39;&#x2913;"), "'\u{2913}");
}
