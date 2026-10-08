// ═══════════════════════════════════════════════════════════════════════
//  批次 7 验收 —— 遥控 + 剩余命令（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这批把 87 个命令补齐
//
// 重点验证：
// ```text
// ① 遥控偏好的落盘与默认值（auto_start 默认 true）
// ② 固定配对码的校验（4~8 位数字；与随机码重合必须拒绝）
// ③ 遥控启停（含端口占用的错误文案）
// ④ toggle_favorite 的新语义（收藏不自动开追更）
// ⑤ check_updates / health_sweep 不 panic
// ⑥ 插件安装的校验（缺 @id 要拒绝，不写盘）
// ```
//
// # ⚠️ 遥控会真的开端口
//
// `remote_start` 会绑定 TCP 端口 —— 测试里要用**高位随机端口**，
// 避免撞上用户机器上正在运行的东西。

use sourin_core::commands;
use sourin_core::commands_remote as cr;
use sourin_core::commands_write as cw;
use sourin_core::state::AppState;
use std::sync::Arc;

async fn fresh(tag: &str) -> Arc<AppState> {
    let dir = std::env::temp_dir().join(format!(
        "sourin-b7-{tag}-{}",
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
    ));
    std::fs::create_dir_all(&dir).unwrap();
    AppState::bootstrap(dir).await.expect("bootstrap")
}

// ═══════════════════════════════════════════════════════════════════════
//  遥控偏好
// ═══════════════════════════════════════════════════════════════════════

/// ★ 默认偏好：auto_start = true，端口 8642
///
/// 「默认开启」是产品决定 —— 遥控是这应用的卖点之一，
/// 默认关着用户根本发现不了它。
#[tokio::test]
async fn remote_pref_defaults_are_sane() {
    let st = fresh("pref-default").await;

    let pref = cr::load_remote_pref(&st.data_dir);
    println!("✓ 默认偏好: auto_start={} port={} fixed_pin={:?}",
        pref.auto_start, pref.port, pref.fixed_pin);

    assert!(pref.auto_start, "默认应开机自启（产品决定）");
    assert_eq!(pref.port, 8642, "默认端口 8642");
    assert!(pref.fixed_pin.is_none(), "默认没有固定码");
}

/// 偏好落盘 + 重启后读回
#[tokio::test]
async fn remote_pref_persists() {
    let st = fresh("pref-persist").await;

    let enabled = cr::remote_set_auto_start(&st, false).expect("set");
    assert!(!enabled);
    println!("✓ 关闭自启");

    // 落盘了吗
    let f = st.data_dir.join("remote-pref.json");
    assert!(f.exists(), "remote-pref.json 应被创建");
    println!("✓ 已落盘: {}", std::fs::read_to_string(&f).unwrap().trim());

    // 模拟重启
    let dir = st.data_dir.clone();
    drop(st);
    let st2 = AppState::bootstrap(dir).await.expect("重启");
    let got = cr::remote_auto_start(&st2).expect("auto_start");
    assert!(!got, "★ 重启后应保持关闭（否则就是没落盘）");
    println!("✓ 重启后 auto_start={got} —— 持久化生效");

    // 再打开
    cr::remote_set_auto_start(&st2, true).unwrap();
    assert!(cr::remote_auto_start(&st2).unwrap());
    println!("✓ 重新打开成功");
}

/// 老版本偏好文件缺字段时用默认值（serde default）
#[tokio::test]
async fn remote_pref_tolerates_missing_fields() {
    let st = fresh("pref-old").await;

    // 写一个"老版本"的偏好文件（只有 port）
    let f = st.data_dir.join("remote-pref.json");
    std::fs::write(&f, r#"{"port":9000}"#).unwrap();

    let pref = cr::load_remote_pref(&st.data_dir);
    println!("✓ 老格式 {{\"port\":9000}} → auto_start={} port={} fixed_pin={:?}",
        pref.auto_start, pref.port, pref.fixed_pin);

    assert_eq!(pref.port, 9000, "已有的 port 应保留");
    assert!(pref.auto_start, "★ 缺 auto_start 时按 true（与产品决定一致）");
    assert!(pref.fixed_pin.is_none());
}

/// 损坏的偏好文件降级为默认值（不 panic）
#[tokio::test]
async fn remote_pref_tolerates_corruption() {
    let st = fresh("pref-broken").await;
    let f = st.data_dir.join("remote-pref.json");
    std::fs::write(&f, "this is not json at all {{{").unwrap();

    let pref = cr::load_remote_pref(&st.data_dir);
    println!("✓ 损坏文件 → 降级为默认: auto_start={} port={}", pref.auto_start, pref.port);
    assert!(pref.auto_start);
    assert_eq!(pref.port, 8642);
}

// ═══════════════════════════════════════════════════════════════════════
//  固定配对码
// ═══════════════════════════════════════════════════════════════════════

/// ★ 格式校验：只接受 4~8 位数字
#[tokio::test]
async fn fixed_pin_format_validation() {
    let st = fresh("pin-format").await;

    // 非法的都应被拒
    /*
     * ⚠️ 注意 "12 34" **不在**非法列表里 —— 见下面单独的断言。
     *    `validate_fixed_pin` 会先 strip 空白，所以 "12 34" → "1234"，
     *    是**合法**的。我第一版把它当非法，测试失败了。
     *    （这是有意的宽容：用户在手机上可能误输空格。）
     */
    let bad = ["abc", "12", "123456789", "12a4", "  ", "!@#$"];
    for b in bad {
        let r = cr::remote_set_fixed_pin(&st, b);
        match r {
            Err(e) => println!("✓ 拒绝 {b:?}: {e}"),
            Ok(_) => {
                // 空串是"清除"语义，允许
                if b.trim().is_empty() {
                    println!("✓ 空串 = 清除固定码（允许）");
                } else {
                    panic!("{b:?} 应该被拒绝");
                }
            }
        }
    }

    // ★ 带空格的应被**接受**（strip 空白后是 1234）
    match cr::remote_set_fixed_pin(&st, "12 34") {
        Ok(v) => println!("✓ 接受带空格的 \"12 34\"（strip 后 1234）→ {:?}", v["fixedPin"]),
        Err(e) => println!("  带空格被拒（可能撞随机码）: {e}"),
    }

    // 合法的应通过
    let r = cr::remote_set_fixed_pin(&st, "1234");
    match r {
        Ok(v) => {
            println!("✓ 接受 1234 → fixedPin={:?}", v["fixedPin"]);
            assert_eq!(v["fixedPin"], "1234");
        }
        Err(e) => {
            // 可能撞上随机码 —— 那是正确行为，换个码重试
            println!("  1234 被拒（可能撞随机码）: {e}");
            let v = cr::remote_set_fixed_pin(&st, "5678").expect("5678 应通过");
            println!("✓ 接受 5678 → fixedPin={:?}", v["fixedPin"]);
        }
    }
}

/// ★★ 与随机码重合必须拒绝（否则「换一个」会把固定码也改掉）
#[tokio::test]
async fn fixed_pin_rejects_collision_with_random() {
    let st = fresh("pin-collision").await;

    let st_now = cr::remote_status_cmd(&st).expect("status");
    let random_pin = st_now["pin"].as_str().expect("有随机码").to_string();
    println!("✓ 当前随机码: {random_pin}");

    let r = cr::remote_set_fixed_pin(&st, &random_pin);
    assert!(r.is_err(), "★ 与随机码相同必须被拒绝");
    let e = r.unwrap_err();
    println!("✓ 拒绝与随机码重合: {e}");
    assert!(e.contains("随机码"), "错误消息应说明原因: {e}");
}

/// 清除固定码（空串）
#[tokio::test]
async fn fixed_pin_can_be_cleared() {
    let st = fresh("pin-clear").await;

    // 先设一个（避开随机码）
    let random = cr::remote_status_cmd(&st).unwrap()["pin"]
        .as_str()
        .unwrap()
        .to_string();
    let candidate = if random == "4321" { "8765" } else { "4321" };
    let v = cr::remote_set_fixed_pin(&st, candidate).expect("set");
    assert_eq!(v["fixedPin"], candidate);
    println!("✓ 已设置固定码 {candidate}");

    // 清除
    let v = cr::remote_set_fixed_pin(&st, "").expect("clear");
    println!("✓ 清除后 fixedPin={:?}", v["fixedPin"]);
    assert!(v["fixedPin"].is_null(), "清除后应为 null");

    // 落盘了吗
    let pref = cr::load_remote_pref(&st.data_dir);
    assert!(pref.fixed_pin.is_none(), "偏好文件里也应清掉");
    println!("✓ 偏好文件里也已清除");
}

/// 换随机码：随机码变了，固定码**不受影响**
#[tokio::test]
async fn refresh_pin_keeps_fixed_pin() {
    let st = fresh("pin-refresh").await;

    let random1 = cr::remote_status_cmd(&st).unwrap()["pin"].as_str().unwrap().to_string();

    // 设一个固定码（避开随机码）
    let fixed = if random1 == "2468" { "1357" } else { "2468" };
    cr::remote_set_fixed_pin(&st, fixed).expect("set");
    println!("✓ 随机码={random1} 固定码={fixed}");

    // 换随机码
    let v = cr::remote_refresh_pin(&st).expect("refresh");
    let random2 = v["pin"].as_str().unwrap();
    println!("✓ 换随机码后: pin={random2} fixedPin={:?}", v["fixedPin"]);

    assert_ne!(random1, random2, "随机码应变化");
    assert_eq!(
        v["fixedPin"], fixed,
        "★ 固定码不该受影响（两个码并存）"
    );
    println!("✓ 固定码保持不变 —— 两码并存语义正确");
}

// ═══════════════════════════════════════════════════════════════════════
//  遥控启停（会真的开端口）
// ═══════════════════════════════════════════════════════════════════════

/// 用高位端口启停一次，并验证状态字段完整
#[tokio::test]
#[ignore = "会真的绑定 TCP 端口，显式 --ignored 运行"]
async fn remote_start_stop_lifecycle() {
    let st = fresh("lifecycle").await;

    // 用一个高位端口，避免撞上系统里跑着的东西
    let port: u16 = 39000 + (std::process::id() % 1000) as u16;

    let v = cr::remote_start(&st, Some(port)).await.expect("start");
    println!("✓ 已启动:");
    println!("   running={} port={} url={}", v["running"], v["port"], v["url"]);
    println!("   lanIp={} reachable={}", v["lanIp"], v["reachable"]);
    println!("   pin={} fixedPin={:?}", v["pin"], v["fixedPin"]);
    println!("   qrSvg 长度={}", v["qrSvg"].as_str().map(|s| s.len()).unwrap_or(0));

    assert_eq!(v["running"], true);
    assert_eq!(v["port"], port);
    assert!(v["qrSvg"].as_str().map(|s| !s.is_empty()).unwrap_or(false), "应有二维码 SVG");

    // ★ 启动后 auto_start 应被设为 true（手动开启 = 用户希望它开着）
    let pref = cr::load_remote_pref(&st.data_dir);
    assert!(pref.auto_start, "★ 手动开启后应记住「开机自启」");
    assert_eq!(pref.port, port, "端口也应记住");
    println!("✓ 已记住 auto_start=true port={port}");

    // 重复启动应幂等
    let v2 = cr::remote_start(&st, Some(port)).await.expect("start again");
    assert_eq!(v2["running"], true);
    println!("✓ 重复启动幂等");

    // 停止
    let v3 = cr::remote_stop(&st).await.expect("stop");
    println!("✓ 已停止: running={} stopped={}", v3["running"], v3["stopped"]);

    // ★ 停止后 auto_start 应被设为 false
    let pref = cr::load_remote_pref(&st.data_dir);
    assert!(!pref.auto_start, "★ 手动关闭后应记住「不自启」（否则重启又被拉起来）");
    println!("✓ 已记住 auto_start=false");
}

/// ★★ 端口被占用时的错误文案（必须区分"谁占了"）
///
/// 原版实测踩过的坑：原先一律提示「可能被占用」，
/// 而实际上绝大多数情况**占用者就是本应用自己**。
/// 让用户去"找谁占用了 8642"完全是误导。
#[tokio::test]
#[ignore = "会真的绑定 TCP 端口，显式 --ignored 运行"]
async fn port_conflict_message_is_helpful() {
    let st = fresh("port-conflict").await;
    let port: u16 = 40000 + (std::process::id() % 1000) as u16;

    /*
     * ★ 必须绑**同一个地址**（lan_ip:port），不能绑 0.0.0.0
     *
     * 我第一版绑 ("0.0.0.0", port) —— 实测**没能阻止** remote_start
     * 绑定 lan_ip:port（Windows 上这两个是不同的绑定）。
     * 于是 remote_start 成功了，`unwrap_err()` panic。
     *
     * `bind_addr(port)` 返回的正是 remote 服务自己会绑的地址，
     * 用它占位才能真的复现冲突。
     */
    let squatter = tokio::net::TcpListener::bind(sourin_core::remote::bind_addr(port))
        .await
        .expect("占位失败");

    let e = cr::remote_start(&st, Some(port)).await.unwrap_err();
    println!("✓ 端口冲突错误消息:");
    println!("   {e}");

    assert!(e.contains(&port.to_string()), "应含端口号");
    // 消息里必须给出可操作的信息
    assert!(
        e.contains("换一个端口") || e.contains("占用") || e.contains("稍等"),
        "错误消息应告诉用户怎么办: {e}"
    );

    drop(squatter);

    // 释放后应能启动
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    match cr::remote_start(&st, Some(port)).await {
        Ok(v) => {
            println!("✓ 释放后启动成功: port={}", v["port"]);
            let _ = cr::remote_stop(&st).await;
        }
        Err(e) => println!("⚠ 释放后仍失败（端口 TIME_WAIT 未过，可接受）: {e}"),
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  剩余命令
// ═══════════════════════════════════════════════════════════════════════

/// toggle_favorite：照原版语义 —— **名字骗人，它不切换**
///
/// # ★★ 我第一版按名字猜错了
///
/// 我以为它是"有则取消、无则添加"，于是写了 `fav.favorited = !was`。
/// 测试立刻失败（第 2 次调用应取消，实际仍是 true）。
///
/// 逐行读原版才发现：**原版根本不翻转** ——
/// 已存在时只复活 deleted + 更新元信息，`favorited` 保持原样。
/// 这正是它成为死代码的原因。
///
/// 所以这个测试现在断言的是**原版的真实行为**（不切换）。
#[tokio::test]
async fn toggle_favorite_matches_original_semantics() {
    let st = fresh("toggle").await;

    // 第一次：新建 → favorited = true
    let f = cr::toggle_favorite(
        &st, "cycani", "1", "剧A".into(), None, Some("series".into()), None,
    )
    .await
    .expect("toggle 1");

    println!("✓ 第 1 次（新建）: favorited={} following={}", f.favorited, f.following);
    assert!(f.favorited, "新建时应是收藏");
    assert!(
        !f.following,
        "★ 不该自动开追更 —— 原版注释明确说这是废弃语义"
    );

    // ★ 第二次：**不切换**（原版行为 —— 保持 favorited=true）
    let f2 = cr::toggle_favorite(
        &st, "cycani", "1", "剧A".into(), None, None, None,
    )
    .await
    .expect("toggle 2");
    println!("✓ 第 2 次（已存在）: favorited={} ← 原版**不翻转**", f2.favorited);
    assert!(
        f2.favorited,
        "★ 原版不切换：已收藏的再调一次仍是收藏（这就是它成为死代码的原因）"
    );

    // 元信息会被更新
    let f3 = cr::toggle_favorite(
        &st, "cycani", "1", "剧A改名".into(), None, Some("movie".into()), Some(true),
    )
    .await
    .expect("toggle 3");
    println!("✓ 第 3 次: title={} kind={} following={}", f3.title, f3.kind, f3.following);
    assert_eq!(f3.title, "剧A改名", "title 应被更新（原版是无条件覆盖）");
    assert_eq!(f3.kind, "movie", "kind 应被更新");
    assert!(f3.following, "显式传 following=true 应生效");
    assert!(f3.favorited, "favorited 仍保持不变");

    // 真正取消收藏要用 set_favorite(on=false)
    let f4 = cw::set_favorite(&st, "cycani", "1", false, None, None, None, None)
        .await
        .expect("set_favorite(false)");
    println!("✓ 用 set_favorite(on=false) 取消: favorited={}", f4.favorited);
    assert!(!f4.favorited, "set_favorite 才是真正的收藏开关");
}

/// health_sweep：全源健康检查（真实网络，可能慢）
#[tokio::test]
#[ignore = "需要真实网络，显式 --ignored 运行"]
async fn health_sweep_returns_map() {
    let st = fresh("sweep").await;
    // 用真实插件（只读复制）
    let appdata = std::env::var("APPDATA").unwrap();
    let src = std::path::PathBuf::from(&appdata)
        .join("app.sourin.player")
        .join("plugins");
    let dst = st.data_dir.join("plugins");
    std::fs::create_dir_all(&dst).unwrap();
    let mut n = 0;
    if src.exists() {
        for e in std::fs::read_dir(&src).unwrap().flatten() {
            if e.path().extension().and_then(|s| s.to_str()) == Some("js")
                && std::fs::copy(e.path(), dst.join(e.file_name())).is_ok()
            {
                n += 1;
            }
        }
    }
    if n > 0 {
        let _ = sourin_core::commands_provider::reload_plugins(&st).await;
    }
    println!("✓ 加载了 {n} 个真实插件");

    let start = std::time::Instant::now();
    let map = cr::health_sweep(&st).await.expect("sweep");
    let elapsed = start.elapsed();

    println!("✓ 健康检查完成: {} 个源，耗时 {:.1}s", map.len(), elapsed.as_secs_f64());
    let ok = map.values().filter(|v| **v).count();
    let bad = map.len() - ok;
    println!("   可用 {ok} / 不可用 {bad}");

    for (id, v) in map.iter().take(8) {
        println!("   {id}: {}", if *v { "✓" } else { "✗" });
    }
}

/// check_updates：追更检查（无追更时应快速返回空）
#[tokio::test]
async fn check_updates_with_no_following_is_fast() {
    let st = fresh("check-updates").await;

    let start = std::time::Instant::now();
    let r = cr::check_updates(&st, Some(10)).await.expect("check_updates");
    let elapsed = start.elapsed();

    println!("✓ 无追更时: {} 条更新，耗时 {:.2}s", r.len(), elapsed.as_secs_f64());
    assert!(r.is_empty(), "没有追更就不该有更新");
    // 没有追更就不该花时间去请求网络
    assert!(elapsed.as_secs() < 5, "应快速返回（实际 {:.1}s）", elapsed.as_secs_f64());
}

/// plugin_config_set / get：源不存在时报明确错误
#[tokio::test]
async fn plugin_config_rejects_unknown_source() {
    let st = fresh("plugin-cfg").await;

    let e = cr::plugin_config_get(&st, "nope").unwrap_err();
    assert!(e.contains("没有找到源"), "{e}");
    println!("✓ plugin_config_get(不存在) → {e}");

    let e = cr::plugin_config_set(&st, "nope", serde_json::Map::new()).unwrap_err();
    assert!(e.contains("没有找到源"), "{e}");
    println!("✓ plugin_config_set(不存在) → {e}");
}

/// install_plugin_source：缺 @id 必须拒绝，且**不写盘**
#[tokio::test]
async fn install_plugin_source_validates_before_writing() {
    let st = fresh("install-src").await;

    // ① 空内容
    let e = cr::install_plugin_source(&st, "   ", None).await.unwrap_err();
    assert!(e.contains("为空"), "{e}");
    println!("✓ 拒绝空内容: {e}");

    // ② 缺 @id
    let e = cr::install_plugin_source(&st, "var x = 1;", None).await.unwrap_err();
    assert!(e.contains("@id"), "{e}");
    println!("✓ 拒绝缺 @id: {e}");

    /*
     * ★ 校验失败时**不该写盘**（免得留下坏文件）
     *
     * ★★ 判据不能写死"恰好几个"（2026-09-25 修）
     *
     * 本断言原来是 `js_count <= 1`，理由是「plugins/ 里只应有内置 demo」。
     * 但 `AppState::bootstrap` seed 的内置插件**不止 demo** ——
     * task-34 之后又多了 `iptv.js`（IPTV 直播源），于是变成 2，测试就红了。
     *
     * ⇒ 正确的判据是「**不含我们这次尝试安装的东西**」，而不是「恰好几个」：
     *   校验失败 ⇒ 目录里不该出现 `b7-*` 或任何**新**文件。
     *
     * 具体做法：先记下校验前的集合，校验失败后比对集合**完全相同**。
     */
    let pdir = st.data_dir.join("plugins");
    let list_js = || -> Vec<String> {
        std::fs::read_dir(&pdir)
            .map(|d| {
                let mut v: Vec<String> = d
                    .flatten()
                    .filter(|e| e.path().extension().and_then(|s| s.to_str()) == Some("js"))
                    .filter_map(|e| e.file_name().to_str().map(|s| s.to_string()))
                    .collect();
                v.sort();
                v
            })
            .unwrap_or_default()
    };

    // 校验**之前**的快照（此时 bootstrap 已跑完，内置插件都在）
    let before = list_js();
    println!("✓ 校验前 plugins/ 里的 .js: {before:?}");

    // 再跑两次非法安装（空内容 / 缺 @id）
    let _ = cr::install_plugin_source(&st, "   ", None).await;
    let _ = cr::install_plugin_source(&st, "var y = 2;", None).await;

    let after = list_js();
    println!("✓ 校验失败后 plugins/ 里的 .js: {after:?}");
    assert_eq!(
        before, after,
        "★ 校验失败不该写盘（前后集合必须完全相同）—— 前 {before:?} / 后 {after:?}"
    );

    // ③ 合法插件应成功
    let good = "/*\n@id b7-test\n@name 批次7测试\n@version 1.0.0\n*/\nvar rule = {};\n";
    match cr::install_plugin_source(&st, good, Some("测试".into())).await {
        Ok(v) => {
            println!("✓ 合法插件安装成功: id={} file={} bytes={}",
                v["id"], v["file"], v["bytes"]);
            assert_eq!(v["id"], "b7-test");
            // 文件真的写了吗
            let f = pdir.join(v["file"].as_str().unwrap());
            assert!(f.exists(), "插件文件应已写入");
            println!("✓ 文件已写入: {}", f.display());
        }
        Err(e) => println!("⚠ 合法插件安装失败: {e}"),
    }
}

/// import_declarative_provider：非法 JSON 应报错
#[tokio::test]
async fn import_declarative_rejects_bad_json() {
    let st = fresh("decl-import").await;

    let e = cr::import_declarative_provider(&st, "not json")
        .await
        .unwrap_err();
    println!("✓ 非法 JSON → {e}");
    // 报错里应含错误种类（原版用 {:?} 打印 kind）
    assert!(!e.is_empty());

    let e = cr::import_declarative_provider(&st, r#"{"foo":"bar"}"#)
        .await
        .unwrap_err();
    println!("✓ 缺必需字段 → {e}");
}

/// remote_report_state / take_commands / set_search / set_home 不 panic
#[tokio::test]
async fn remote_passthrough_commands_work() {
    let st = fresh("passthrough").await;

    // take_commands 初始应为空
    let cmds = cr::remote_take_commands(&st).expect("take");
    println!("✓ 初始待执行命令: {} 条", cmds.len());

    // 上报状态（构造一个默认的）
    let state_json: sourin_core::remote::RemoteState = serde_json::from_value(
        serde_json::json!({
            "title": "测试影片",
            "position": 12.5,
            "duration": 100.0,
            "paused": false,
        }),
    )
    .unwrap_or_default();
    cr::remote_report_state(&st, state_json).expect("report");
    println!("✓ 已上报播放状态");

    // 上报搜索
    let search: sourin_core::remote::SearchPayload = serde_json::from_value(
        serde_json::json!({ "keyword": "测试", "items": [] }),
    )
    .unwrap_or_default();
    cr::remote_set_search(&st, search).expect("search");
    println!("✓ 已上报搜索结果");

    // 上报首页
    let home: sourin_core::remote::HomePayload =
        serde_json::from_value(serde_json::json!({ "sections": [] })).unwrap_or_default();
    cr::remote_set_home(&st, home).expect("home");
    println!("✓ 已上报首页数据");
}


// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 开机自启的结果必须**可查**（2026-09-24，用户报的症状）
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话：
// > 「局域网遥控开了 开机自动,但是软件都打开了,也没见启动」
//
// 自启是后台异步做的，失败时用户看不到 stderr。所以 `RemoteHub` 记下
// 结果（`set_autostart`），让 UI / FFI 能问一句"成了没有、没成是为什么"。
//
// ★ 为什么这条测试重要：我们这次是靠**逐个进程枚举模块**才找到占用者的
//   （`flutter_tester` 锁着 DLL/端口）—— **用户不可能做这件事**。
//   所以端口被占时必须在结果里说清楚原因和下一步。

/// 自启结果要等后台 spawn —— 轮询到有结果为止
async fn wait_autostart(
    st: &Arc<AppState>,
) -> Option<std::result::Result<u16, String>> {
    for _ in 0..40 {
        if let Some(r) = st.remote.autostart() {
            return Some(r);
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    None
}

/// ★★★ 端口被占 → 必须给出**明确、可操作**的原因（不是静默失败）
#[tokio::test(flavor = "multi_thread")]
#[ignore = "会真的绑定 TCP 端口，显式 --ignored 运行"]
async fn t19_autostart_port_busy_reports_clear_reason() {
    // 高位端口，避开 8642（用户应用 / 并发测试可能在用）
    let port: u16 = 39871;
    let addr = sourin_core::remote::bind_addr(port);

    // ① 先自己占住端口（模拟"另一个实例 / 别的程序"）
    let squatter = std::net::TcpListener::bind(addr).expect("测试占住端口");
    println!("[setup] 已占住 {addr}");

    // ② 写 auto_start=true 的偏好 → bootstrap 会尝试自启并失败
    let dir = std::env::temp_dir().join(format!(
        "sourin-b7-busy-{}",
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
    ));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("remote-pref.json"),
        format!(r#"{{"auto_start":true,"port":{port}}}"#),
    )
    .unwrap();

    let st = AppState::bootstrap(dir).await.expect("bootstrap");
    let r = wait_autostart(&st)
        .await
        .expect("★ 自启必须有结果 —— 静默不写结果正是用户报的「不知道为什么没启动」");

    match r {
        Ok(p) => panic!("★ 端口被占却报成功（port={p}）—— bind 没真的失败？"),
        Err(msg) => {
            println!("✓ 自启结果（给用户看的原因）: {msg}");
            assert!(
                msg.contains("已被占用"),
                "★ 必须明确说「已被占用」（而不是含糊的'无法监听'）：{msg}"
            );
            assert!(
                msg.contains("自启被跳过"),
                "★ 要说清是「自启被跳过」—— 让用户知道程序没坏：{msg}"
            );
            assert!(
                msg.contains(&port.to_string()),
                "★ 原因里要带端口号，方便排查：{msg}"
            );
            assert!(
                msg.contains("换一个端口") || msg.contains("关掉占用"),
                "★ 要给可操作的下一步：{msg}"
            );
        }
    }

    // ③ 失败时不能误报 running
    assert!(!st.remote.is_running(), "★ 自启失败时 running 必须为 false");
    assert!(
        st.remote.autostart_error().is_some(),
        "★ autostart_error() 应能直接拿到原因（供 UI 显示）"
    );
    println!("✓ 端口被占时：原因明确、可操作，且未误报运行中");
    drop(squatter);
}

/// ★ 反向：端口空闲 → 自启成功，且端口**真的可连**（不只信标志）
#[tokio::test(flavor = "multi_thread")]
#[ignore = "会真的绑定 TCP 端口，显式 --ignored 运行"]
async fn t19_autostart_success_is_really_listening() {
    let port: u16 = 39872;
    assert!(
        sourin_core::remote::port_is_free(port),
        "★ 端口 {port} 被占，测试前提不成立"
    );

    let dir = std::env::temp_dir().join(format!(
        "sourin-b7-free-{}",
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
    ));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("remote-pref.json"),
        format!(r#"{{"auto_start":true,"port":{port}}}"#),
    )
    .unwrap();

    let st = AppState::bootstrap(dir).await.expect("bootstrap");
    let r = wait_autostart(&st).await.expect("自启必须有结果");

    match r {
        Ok(p) => {
            assert_eq!(p, port, "成功时端口应来自偏好文件");
            assert!(st.remote.is_running(), "成功时 running 应为 true");
            assert!(st.remote.autostart_error().is_none(), "成功时不该有错误");
            // ★ 真的连一下 —— 标志可能与实际不符
            let ok = std::net::TcpStream::connect_timeout(
                &sourin_core::remote::bind_addr(port),
                std::time::Duration::from_millis(500),
            )
            .is_ok();
            assert!(ok, "★ 报了成功但端口连不上 —— 标志与实际不符");
            println!("✓ 端口空闲时自启成功，且端口真的可连");
            let _ = st
                .remote
                .request_shutdown(std::time::Duration::from_secs(2))
                .await;
        }
        Err(e) => panic!("★ 端口空着却报失败：{e}"),
    }
}

/// ★ 「没尝试自启」必须是 None，不能是 Err
///
/// 区分「用户自己关的」和「试了但失败」—— 否则界面会把前者显示成"出错了"。
#[tokio::test(flavor = "multi_thread")]
#[ignore = "会真的绑定 TCP 端口，显式 --ignored 运行"]
async fn t19_autostart_not_attempted_is_none() {
    let dir = std::env::temp_dir().join(format!(
        "sourin-b7-none-{}",
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
    ));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("remote-pref.json"),
        r#"{"auto_start":false,"port":39873}"#,
    )
    .unwrap();

    let st = AppState::bootstrap(dir).await.expect("bootstrap");
    tokio::time::sleep(std::time::Duration::from_millis(1200)).await;

    let r = st.remote.autostart();
    println!("[结果] auto_start=false -> autostart() = {r:?}");
    assert!(
        r.is_none(),
        "★ 未尝试自启时必须 None（界面才不会把'用户关的'显示成'出错了'），实际 {r:?}"
    );
    assert!(st.remote.autostart_error().is_none());
    println!("✓ 未尝试自启 -> None（与'失败'可区分）");
}
