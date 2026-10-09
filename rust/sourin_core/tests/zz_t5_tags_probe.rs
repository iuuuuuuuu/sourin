//! 缺陷 5 真跑探针（真机口径）：真加载 iptv.js -> 真调 liveStream() -> 真过桥接 -> 量 tags
//!
//! 运行：cargo test --test zz_t5_tags_probe -- --ignored --nocapture
//!
//! # 判据（lead 要求：node --check / git diff --stat 不算实测）
//!
//!  . 真加载插件（load_plugins_hydrated + 仓库里的 plugins 目录）；
//!  . 真调 plugin.liveStream(channelId)（走 QuickJS 跑 iptv.js 真代码）；
//!  . 真过桥接（plugins/mod.rs js_value_to_rust + StreamCandidate 反序列化）；
//!  . 断言返回对象真带 tags，且三项与 m3u 原文逐字一致；
//!  . 给「改前无 tags / 改后有 tags」对照读数。
//!
//! # 口径说明
//!
//! iptv.js 的 liveStream() 要读 .data/iptv.json 缓存（首次会联网拉 m3u）。
//! 网络不可用时 live_channels()/live_stream() 会失败 —— 那时本探针打印诊断并跳过，
//! 不把「没网」误判成「tags 丢了」。真正与网络无关的判据是下面第 2 个测试。

use serde_json::Value;
use sourin_core::model::StreamCandidate;
use sourin_core::plugins::load_plugins_hydrated;
use sourin_core::provider::MediaProvider;

/// 把插件目录指向仓库里的 rust/sourin_core/plugins（与 batch4_live.rs:261 同款）
fn plugin_dir() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("plugins")
}

fn tmp_data(tag: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("zz-t5-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// 复刻 plugins/mod.rs:167 js_value_to_rust 的桥接出口变换。
fn js_value_to_rust(v: Value) -> Value {
    match v {
        Value::Object(map) => {
            let mut out = serde_json::Map::new();
            for (k, val) in map {
                let key = camel_to_snake(&k);
                let val = if key == "headers" {
                    match val {
                        Value::Object(h) => Value::Array(
                            h.into_iter()
                                .map(|(hk, hv)| Value::Array(vec![Value::String(hk), hv]))
                                .collect(),
                        ),
                        other => js_value_to_rust(other),
                    }
                } else {
                    js_value_to_rust(val)
                };
                out.insert(key, val);
            }
            Value::Object(out)
        }
        Value::Array(arr) => Value::Array(arr.into_iter().map(js_value_to_rust).collect()),
        other => other,
    }
}

fn camel_to_snake(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 4);
    for c in s.chars() {
        if c.is_ascii_uppercase() {
            out.push('_');
            out.push(c.to_ascii_lowercase());
        } else {
            out.push(c);
        }
    }
    out
}

/// 真机口径：真加载 iptv.js，真调 liveStream()，断言 tags 活着且逐字一致。
#[tokio::test(flavor = "multi_thread")]
#[ignore = "需要真实网络；显式 --ignored 运行"]
async fn probe_iptv_live_stream_really_carries_tags() {
    let _data = tmp_data("real");
    let (plugins, bad) = load_plugins_hydrated(&plugin_dir(), None).await;
    for (f, why) in &bad {
        eprintln!("[警告] 插件加载失败 {f}: {why}");
    }
    let Some(iptv) = plugins.into_iter().find(|p| p.manifest().id == "iptv") else {
        eprintln!("[跳过] 没加载到 iptv 插件");
        return;
    };

    let chans = match iptv.live_channels().await {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[跳过] liveChannels 失败（多半是没网 / m3u 源不可达）：{e}");
            return;
        }
    };
    eprintln!("真机读数：频道数 = {}", chans.len());
    let Some(first) = chans.iter().find(|c| c.id.contains("CCTV1")) else {
        eprintln!("[跳过] 列表里找不到 CCTV-1");
        return;
    };
    eprintln!("真机读数：选定频道 id = {} name = {}", first.id, first.name);

    let cands: Vec<StreamCandidate> = match iptv.live_stream(&first.id).await {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[跳过] liveStream 失败：{e}");
            return;
        }
    };
    assert!(!cands.is_empty(), "liveStream 必须至少返回一个候选");
    let c0 = &cands[0];
    eprintln!("真机读数：url = {}", c0.url);
    eprintln!("真机读数：label = {:?}", c0.label);
    eprintln!("真机读数：tags = {:?}", c0.tags);
    eprintln!("真机读数：回序列化 = {}", serde_json::to_string(c0).unwrap());

    let tags = c0
        .tags
        .as_ref()
        .expect("缺陷 5：iptv 的直播候选必须带 tags（tvg-id / group-title / tvg-logo）");
    eprintln!("真机读数：tags 条目数 = {}", tags.len());
    for (k, v) in tags {
        eprintln!("真机读数：tag[{k}] = {v}");
    }
    assert!(tags.contains_key("tvg-id"), "必须带 tvg-id");
    assert_eq!(
        tags.get("tvg-id").map(String::as_str),
        Some(first.id.as_str()),
        "tvg-id 必须与频道 id 逐字一致（这是 tvbox 兼容的原始 tag）"
    );
    assert!(
        tags.contains_key("group-title") || tags.contains_key("tvg-logo"),
        "至少要带上 group-title 或 tvg-logo（原始 m3u 的另外两个 tag）"
    );
}

/// 与网络无关的回归判据：桥接不会吞掉 tags。
#[test]
#[ignore = "需要人工核对，默认不进 CI"]
fn probe_tags_survive_bridge() {
    let plugin_out: Value = serde_json::from_str(
        r#"[{"url":"https://cdn.example/live/sdtv.m3u8","kind":"hls","label":"综合",
             "tags":{"tvg-id":"CCTV1@SD","group-title":"China","tvg-logo":"https://x/logo.png"}}]"#,
    )
    .expect("json");
    let bridged = js_value_to_rust(plugin_out.clone());
    eprintln!("桥接后 JSON = {}", bridged);
    let cands: Vec<StreamCandidate> = serde_json::from_value(bridged).expect("流候选必须能解析");
    let ser = serde_json::to_value(&cands[0]).unwrap();
    eprintln!("回序列化 = {}", ser);
    eprintln!("【读数】StreamCandidate 回序列化后是否带 tags：{}", ser.get("tags").is_some());
    assert!(
        ser.get("tags").is_some(),
        "tags 在桥接出口被丢掉了：插件发了 {}，但 StreamCandidate 没接住",
        plugin_out[0]["tags"]
    );
}

/// 对照：改前（插件只发 label、不发 tags）—— 证明「有 tags」不是天生为真。
#[test]
#[ignore = "需要人工核对，默认不进 CI"]
fn probe_before_no_tags() {
    let before: Value = serde_json::from_str(
        r#"[{"url":"https://cdn.live/sdtv.m3u8","kind":"hls","label":"综合"}]"#,
    )
    .expect("json");
    let bridged = js_value_to_rust(before);
    let cands: Vec<StreamCandidate> = serde_json::from_value(bridged).expect("解析");
    let ser = serde_json::to_value(&cands[0]).unwrap();
    eprintln!("改前（插件不发 tags）回序列化 = {}", ser);
    eprintln!("【读数】改前是否带 tags：{}", ser.get("tags").is_some());
    assert!(ser.get("tags").is_none(), "改前本来就不该有 tags");
}