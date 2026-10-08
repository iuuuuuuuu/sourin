// ═══════════════════════════════════════════════════════════════════════
//  配置落盘目录回归测试（2026-10-05，task-35 Emby 接入撞出来的真 bug）
// ═══════════════════════════════════════════════════════════════════════
//
// # 症状
// ```text
// 用户在设置页填了 Emby 地址 → 点保存 → 提示「已保存 N 项」
// 插件里 host.config.getString('server_url', '') → 仍然是空串
// ```
// **两边都不报错**，所以只能靠端到端测试钉住。
//
// # 根因
// `plugin_config_set` / `plugin_config_get` 把 `&state.data_dir` 直接传给了
// `config_write_many` / `resolved_config`，于是：
// ```text
// 设置页写的是   <dataDir>/emby.json                ← 错
// 插件读的是     <dataDir>/plugins/.data/emby.json  ← 对
//                （plugins/mod.rs load_plugins_hydrated 里 dir.join('.data')）
// ```
//
// # 为什么必须走 Registry 而不是只查文件
//
// 查文件只能证明「写对地方了」；用户真正关心的是
// **插件自己读得到**。所以这里装一个「把配置读出来当 home() 返回值」的
// 插件，再用真 Registry 拿 provider 调 home()。

use sourin_core::commands_remote as cr;
use sourin_core::provider::MediaProvider;
use sourin_core::state::AppState;
use std::sync::Arc;

async fn fresh(tag: &str) -> Arc<AppState> {
    let dir = std::env::temp_dir().join(format!(
        "sourin-b7cfg-{tag}-{}",
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
    ));
    std::fs::create_dir_all(&dir).unwrap();
    AppState::bootstrap(dir).await.expect("bootstrap")
}

/// 插件源码：声明两项配置（text + switch），home() 把读到的值原样吐回来
///
/// ⚠️ 用 `r#` 原始字符串 —— 里面全是 JS 代码，含引号与反斜杠，
///    普通字符串会被转义搞乱。
const CFG_PLUGIN: &str = r#"
/** @id b7cfg @name 配置目录测试 @version 1.0.0 */
globalThis.plugin = {
  id: 'b7cfg',
  capabilities: { vod: true },
  config: [
    { key: 'server_url', label: '服务器地址', kind: 'text', default: '' },
    { key: 'enable_proxy', label: '走代理', kind: 'switch', default: false },
  ],
  async home() {
    const addr = host.config.getString('server_url', '(空)');
    const flag = host.config.getBool('enable_proxy', false);
    const all = host.config.all();
    return [{
      id: 'cfg',
      title: 'ADDR=' + addr + '|BOOL=' + flag + '|ALL=' + all,
      source: { type: 'static' },
    }];
  },
};
"#;

#[tokio::test]
async fn plugin_config_lands_where_the_plugin_reads_it() {
    let st = fresh("dir").await;

    // ① 装插件
    let v = cr::install_plugin_source(&st, CFG_PLUGIN, None)
        .await
        .expect("装插件");
    assert_eq!(v["id"], "b7cfg");
    println!("[1] 已装插件 file={} bytes={}", v["file"], v["bytes"]);

    // ② 声明读得回来（同时验证出口键名是 kind）
    let cfg = cr::plugin_config_get(&st, "b7cfg").expect("config_get");
    let fields = cfg["fields"].as_array().expect("fields 应为数组");
    assert_eq!(fields.len(), 2, "应声明 2 项，实际 {fields:?}");
    println!("[2] 声明: {}", serde_json::to_string(&cfg["fields"]).unwrap());
    assert_eq!(fields[0]["kind"], "text", "★ 出口键名必须是 kind（不是 type）");
    assert_eq!(fields[1]["kind"], "switch", "★ switch 不能被降级成 text");

    // ③ 保存（模拟设置页那一跳）
    let mut values = serde_json::Map::new();
    values.insert("server_url".into(), serde_json::json!("http://10.0.2.2:8096"));
    values.insert("enable_proxy".into(), serde_json::json!(true));
    let n = cr::plugin_config_set(&st, "b7cfg", values).expect("config_set");
    assert_eq!(n, 2, "应写入 2 项");
    println!("[3] 已保存 {n} 项");

    // ④ 落盘位置：必须在 plugins/.data/，且**不能**在 <dataDir>/
    let right = st.data_dir.join("plugins").join(".data").join("b7cfg.json");
    let wrong = st.data_dir.join("b7cfg.json");
    println!("[4] 正确位置 {} exists={}", right.display(), right.exists());
    println!("    修前位置 {} exists={}", wrong.display(), wrong.exists());
    assert!(right.exists(), "★ 配置必须落在 plugins/.data/ —— 插件读的就是这里");
    assert!(
        !wrong.exists(),
        "★ 不能落在 <dataDir>/<id>.json —— 那是修前的错误路径，插件永远读不到"
    );
    println!("    内容: {}", std::fs::read_to_string(&right).unwrap().trim());

    // ⑤ 插件自己读得到（用户视角的验收）
    let p = st.registry.get("b7cfg").expect("插件应已注册");
    let secs = p.home().await.expect("home()");
    assert_eq!(secs.len(), 1);
    println!("[5] 插件读到的: {}", secs[0].title);
    assert!(
        secs[0].title.contains("ADDR=http://10.0.2.2:8096"),
        "★ 插件必须读到用户在设置页填的值（实际 {}）",
        secs[0].title
    );
    assert!(
        secs[0].title.contains("BOOL=true"),
        "★ switch 项也必须读到（实际 {}）",
        secs[0].title
    );

    // ⑥ plugin_config_get 从同一处读回（否则界面显示的还是旧值）
    let again = cr::plugin_config_get(&st, "b7cfg").expect("config_get 2");
    assert_eq!(again["values"]["server_url"], "http://10.0.2.2:8096");
    assert_eq!(again["values"]["enable_proxy"], true);
    println!("[6] 读回: {}", serde_json::to_string(&again["values"]).unwrap());

    // ⑦ 重启后仍在（跨实例持久化 —— 用的还是同一个文件）
    let dir = st.data_dir.clone();
    drop(st);
    let st2 = AppState::bootstrap(dir).await.expect("重启");
    let p2 = st2.registry.get("b7cfg").expect("重启后插件应在");
    let secs2 = p2.home().await.expect("home() 2");
    println!("[7] 重启后插件读到的: {}", secs2[0].title);
    assert!(
        secs2[0].title.contains("ADDR=http://10.0.2.2:8096"),
        "★ 重启后仍要读得到（否则就是没落盘）: {}",
        secs2[0].title
    );
}
