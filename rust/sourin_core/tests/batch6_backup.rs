// ═══════════════════════════════════════════════════════════════════════
//  批次 6 验收 —— 登录 / 代理 / 备份 / 同步（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 重点：备份的**合并语义**
//
// 最容易写错的地方：把导入当成"覆盖"。
// 实际是**按时间戳合并**：
// ```text
// 已存在 → 只在新数据更「新」时更新（updated_at 是判据）
// 不存在 → 新增
// ```
// 这里用真实的往返测试（导出 → 改本机 → 导入 → 验证没倒退）来守住它。
//
// # 全部用隔离目录
//
// 这批会写文件（备份、插件、第三方源清单），所以绝不碰真实库。

use sourin_core::commands;
use sourin_core::commands_backup as cb;
use sourin_core::commands_write as cw;
use sourin_core::state::AppState;
use std::sync::Arc;

async fn fresh(tag: &str) -> Arc<AppState> {
    let dir = std::env::temp_dir().join(format!(
        "sourin-b6-{tag}-{}",
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
    ));
    std::fs::create_dir_all(&dir).unwrap();
    AppState::bootstrap(dir).await.expect("bootstrap")
}

// ═══════════════════════════════════════════════════════════════════════
//  备份
// ═══════════════════════════════════════════════════════════════════════

/// 备份预览：报告"会导出什么"（不写盘）
#[tokio::test]
async fn backup_preview_reports_counts() {
    let st = fresh("preview").await;

    // 造点数据
    cw::save_progress(&st, "cycani", "1", "剧A", None, None, Some("第1集".into()), 100, 1000, None)
        .unwrap();
    cw::save_progress(&st, "cycani", "2", "剧B", None, None, None, 200, 1000, None).unwrap();
    cw::set_favorite(&st, "cycani", "1", true, Some("剧A".into()), None, None, None)
        .await
        .unwrap();
    cw::set_skip_marker(&st, "cycani", "1", Some("剧A".into()), Some(0), Some(60), None, None, None)
        .unwrap();

    let p = cb::backup_preview(&st).expect("preview");
    println!("{}", serde_json::to_string_pretty(&p).unwrap());

    assert_eq!(p["counts"]["favorites"], 1, "1 条收藏");
    assert_eq!(p["counts"]["progress"], 2, "2 条进度");
    assert_eq!(p["counts"]["history"], 2, "save_progress 各写一条历史");
    assert_eq!(p["counts"]["skipMarkers"], 1, "1 个跳过点");
    assert!(p["version"].is_number());
    assert!(p["deviceId"].is_string());
    println!();
    println!("✓ 备份预览计数正确");
}

/// ★ 导出 → 导入 往返（同一份数据）
#[tokio::test]
async fn backup_round_trip() {
    let st = fresh("roundtrip").await;

    cw::save_progress(&st, "cycani", "1", "剧A", None, Some("ep1".into()), Some("第1集".into()), 100, 1000, None).unwrap();
    cw::set_favorite(&st, "cycani", "1", true, Some("剧A".into()), None, None, None).await.unwrap();
    cw::set_skip_marker(&st, "cycani", "1", Some("剧A".into()), Some(0), Some(60), None, None, Some(true)).unwrap();

    let backup_path = st.data_dir.join("test-backup.json");
    let exported = cb::backup_export(&st, backup_path.to_str().unwrap()).expect("export");
    println!("✓ 导出: {} 字节 → {}", exported["bytes"], exported["path"]);
    assert!(backup_path.exists(), "备份文件应存在");
    assert!(exported["bytes"].as_u64().unwrap() > 0);

    // 检视
    let insp = cb::backup_inspect(backup_path.to_str().unwrap()).expect("inspect");
    println!("✓ 检视: 收藏 {} / 进度 {} / 跳过点 {}",
        insp["counts"]["favorites"], insp["counts"]["progress"], insp["counts"]["skipMarkers"]);
    assert_eq!(insp["counts"]["favorites"], 1);
    assert_eq!(insp["counts"]["progress"], 1);

    // 在**新的**隔离目录里导入（模拟"另一台机器"）
    let st2 = fresh("roundtrip-target").await;
    assert_eq!(commands::list_all_progress(&st2).unwrap().len(), 0, "新库应该是空的");

    let sum = cb::backup_import(&st2, backup_path.to_str().unwrap()).await.expect("import");
    println!("✓ 导入汇总:");
    println!("   收藏 +{} 更新{}", sum.favorites_added, sum.favorites_updated);
    println!("   追更 +{}", sum.following_added);
    println!("   进度更新{}", sum.progress_updated);
    println!("   历史 +{}", sum.history_added);
    println!("   跳过点更新{}", sum.skip_updated);
    println!("   插件 {}+{}", sum.plugins_written.len(), sum.plugins_renamed.len());
    if !sum.skipped.is_empty() {
        println!("   跳过: {:?}", sum.skipped);
    }

    // 数据应该都在新库里
    let p = commands::get_progress(&st2, "cycani", "1").unwrap().expect("应有进度");
    assert_eq!(p.position, 100);
    assert_eq!(p.duration, 1000);
    println!("✓ 进度已恢复: pos={} dur={}", p.position, p.duration);

    let favs = commands::list_favorites(&st2, false).await.unwrap();
    assert_eq!(favs.len(), 1, "收藏应恢复");
    println!("✓ 收藏已恢复: {}", favs[0].title);

    let m = commands::get_skip_marker(&st2, "cycani", "1").unwrap().expect("应有跳过点");
    assert_eq!(m.intro_end, Some(60));
    println!("✓ 跳过点已恢复: intro_end={:?}", m.intro_end);
}

/// ★★ 关键：导入**不会倒退**本机更新的数据
///
/// 这是"导入即覆盖"会踩的坑：备份是三天前的，
/// 而本机这两天又看了几集 —— 覆盖回去就把进度打回去了。
#[tokio::test]
async fn import_does_not_regress_newer_local_data() {
    let st = fresh("merge-newer").await;

    // 机器 A：看到 100 秒
    cw::save_progress(&st, "p", "1", "剧", None, None, None, 100, 1000, None).unwrap();
    let backup = st.data_dir.join("old.json");
    cb::backup_export(&st, backup.to_str().unwrap()).unwrap();
    println!("✓ 机器 A 导出备份（进度 100 秒）");

    // 机器 B：同一部片看到 900 秒（更新）
    let st2 = fresh("merge-target").await;
    cw::save_progress(&st2, "p", "1", "剧", None, None, None, 900, 1000, None).unwrap();
    let before = commands::get_progress(&st2, "p", "1").unwrap().unwrap();
    println!("✓ 机器 B 本机进度: {} 秒（updated_at={}）", before.position, before.updated_at);

    // ★ 导入旧备份
    let sum = cb::backup_import(&st2, backup.to_str().unwrap()).await.unwrap();
    println!("✓ 导入旧备份: 进度更新 {} 条", sum.progress_updated);

    let after = commands::get_progress(&st2, "p", "1").unwrap().unwrap();
    assert_eq!(
        after.position, 900,
        "★ 本机更新的进度不该被旧备份覆盖回 100（这就是合并 vs 覆盖的区别）"
    );
    assert_eq!(sum.progress_updated, 0, "旧数据不该算作「更新」");
    println!("✓ 本机进度保持 900 秒 —— 未倒退");

    /*
     * 反向：本机较旧 → 备份较新 → 应该更新
     *
     * ★ 这个场景**不能**靠"在新库上写一次进度"来构造：
     *   `save_progress` 会把 `updated_at` 设成**当前时刻**，
     *   那必然比备份里的时间戳新 —— 于是永远走"跳过"分支。
     *   我第一版就是这么写的，断言失败（实测 50 秒没被更新成 100）。
     *
     * 正确构造：直接写库，把本机的 `updated_at` 设成**很久以前**。
     */
    let st3 = fresh("merge-older").await;
    cw::save_progress(&st3, "p", "1", "剧", None, None, None, 50, 1000, None).unwrap();
    {
        let mut p = commands::get_progress(&st3, "p", "1").unwrap().unwrap();
        // 把本机时间戳调到 2000 年（远早于备份）
        p.updated_at = 946_684_800_000;
        st3.db.upsert_progress(&p).unwrap();
        println!("✓ 机器 C 本机进度 50 秒，updated_at 手动调成 2000 年（故意做旧）");
    }

    let sum2 = cb::backup_import(&st3, backup.to_str().unwrap()).await.unwrap();
    let a3 = commands::get_progress(&st3, "p", "1").unwrap().unwrap();
    println!("✓ 导入后 {} 秒（进度更新 {} 条）", a3.position, sum2.progress_updated);
    assert_eq!(a3.position, 100, "本机较旧时，备份的值应被采用");
    assert_eq!(sum2.progress_updated, 1, "应计为 1 条更新");
}

/// 合并时保留本机的分组 / 别名
#[tokio::test]
async fn import_preserves_local_group_and_note() {
    let st = fresh("merge-preserve").await;

    cw::set_favorite(&st, "p", "1", true, Some("剧".into()), None, None, None).await.unwrap();
    let backup = st.data_dir.join("b.json");
    cb::backup_export(&st, backup.to_str().unwrap()).unwrap();

    // 机器 B：本机整理了分组和备注
    let st2 = fresh("preserve-target").await;
    cw::set_favorite(&st2, "p", "1", true, Some("剧".into()), None, None, None).await.unwrap();
    {
        // 直接改库（模拟用户在 UI 上设了分组/备注）
        let mut f = commands::list_favorites(&st2, false).await.unwrap()[0].clone();
        f.group_name = Some("我的分组".into());
        f.note = Some("很好看".into());
        f.updated_at += 1000; // 让它比备份新，从而触发"更新"分支
        st2.db.upsert_favorite(&f).unwrap();
    }
    println!("✓ 机器 B 本机设了分组「我的分组」+ 备注");

    let sum = cb::backup_import(&st2, backup.to_str().unwrap()).await.unwrap();
    let after = commands::list_favorites(&st2, false).await.unwrap();
    let f = after.iter().find(|x| x.key == "p:1").unwrap();

    println!("✓ 导入后: 分组={:?} 备注={:?}（更新 {} 条）", f.group_name, f.note, sum.favorites_updated);
    assert_eq!(
        f.group_name.as_deref(),
        Some("我的分组"),
        "★ 本机的分组必须保留（用户手动整理过）"
    );
    assert_eq!(f.note.as_deref(), Some("很好看"), "★ 本机的备注必须保留");
}

/// 插件：重复导入同一个包**不产生副本**（幂等）
#[tokio::test]
async fn import_plugins_is_idempotent() {
    let st = fresh("plugin-idem").await;

    // 手写一个插件
    let pdir = st.data_dir.join("plugins");
    std::fs::create_dir_all(&pdir).unwrap();
    let js = "/*\n@id b6-test\n@name 测试插件\n@version 1.0.0\n*/\nvar x = 1;\n";
    std::fs::write(pdir.join("b6.js"), js).unwrap();
    println!("✓ 造了一个插件 b6.js");

    let backup = st.data_dir.join("b.json");
    cb::backup_export(&st, backup.to_str().unwrap()).unwrap();
    let insp = cb::backup_inspect(backup.to_str().unwrap()).unwrap();
    let n_plugins = insp["counts"]["plugins"].as_u64().unwrap();
    println!("✓ 备份里含 {n_plugins} 个插件");

    /*
     * ★ 不要断言 == 1 —— `AppState::bootstrap` 会 `seed_demo_plugin()`
     *   往 plugins/ 里放一个 `demo.js`，所以实际是 2 个（demo + 我造的）。
     *   我第一版写死 1，失败了。
     *
     * 判据应该是「至少含我造的那个」而不是「恰好几个」——
     * 后者会随 bootstrap 行为变化而失效。
     */
    assert!(n_plugins >= 1, "至少应有我造的插件 + 内置 demo");
    let names: Vec<String> = insp["plugins"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|x| x["name"].as_str().map(|s| s.to_string()))
        .collect();
    println!("  插件清单: {names:?}");
    assert!(names.iter().any(|n| n == "b6.js"), "应含我造的 b6.js");

    // 导入到另一个库
    let st2 = fresh("plugin-idem-target").await;
    let sum1 = cb::backup_import(&st2, backup.to_str().unwrap()).await.unwrap();
    println!("✓ 第 1 次导入: 写入 {:?} 改名 {:?}", sum1.plugins_written, sum1.plugins_renamed);
    assert_eq!(sum1.plugins_written.len(), 1, "第 1 次应正常写入");
    assert!(sum1.plugins_renamed.is_empty(), "第 1 次不该改名");

    // ★ 再导入一次同一个包 → 内容相同，应**跳过**（不产生副本）
    let sum2 = cb::backup_import(&st2, backup.to_str().unwrap()).await.unwrap();
    println!("✓ 第 2 次导入: 写入 {:?} 改名 {:?}（都应为空 = 幂等）",
        sum2.plugins_written, sum2.plugins_renamed);
    assert!(
        sum2.plugins_written.is_empty() && sum2.plugins_renamed.is_empty(),
        "★ 重复导入同一个包不该产生副本"
    );

    /*
     * 插件目录里不该出现**副本**（同一份内容被写成 b6-1.js / b6-2.js …）。
     *
     * ★★ 不要把总数写死（2026-09-25 修）
     *
     * 本断言原来是 count <= 2，理由是「demo.js + 我造的 b6.js = 2」。
     * 但 AppState::bootstrap 会 seed 的内置插件**不止 demo** ——
     * task-34 之后又多了 iptv.js（IPTV 直播源），于是变成 3，测试就红了。
     *
     * ⇒ 与上面 L232-237 那段注释**同一个教训**：
     *   判据应该是「**不含我造的插件的副本**」，而不是「恰好几个」——
     *   后者会随 bootstrap 的行为变化而失效。
     *
     * 正确的判据：统计 6 开头的 .js 有几个，应该**恰好 1 个**。
     */
    let js_names: Vec<String> = std::fs::read_dir(st2.data_dir.join("plugins"))
        .unwrap()
        .flatten()
        .filter_map(|e| {
            let p = e.path();
            if p.extension().and_then(|s| s.to_str()) == Some("js") {
                p.file_name().and_then(|s| s.to_str()).map(|s| s.to_string())
            } else {
                None
            }
        })
        .collect();
    let b6_copies = js_names.iter().filter(|n| n.starts_with("b6")).count();
    println!("✓ 插件目录里的 .js: {js_names:?}；其中 b6* 共 {b6_copies} 个");
    assert_eq!(
        b6_copies, 1,
        "★ 我造的插件应恰好 1 份（重复导入不该产生副本），实际 {b6_copies} 份：{js_names:?}"
    );
}

/// 备份文件名含设备 id 且文件系统安全
#[tokio::test]
async fn backup_default_name_is_safe() {
    let st = fresh("name").await;
    let n = cb::backup_default_name(&st).unwrap();
    println!("✓ 默认文件名: {n}");
    assert!(!n.contains('/') && !n.contains('\\'), "不该含路径分隔符");
    assert!(!n.contains(':'), "不该含冒号（Windows 非法）");

    /*
     * ★ 扩展名是 `.zip` —— 我第一版断言 `.json`/`.sourin`，错了。
     *
     * 备份**真的**是一个 ZIP 归档（`backup::write_backup` 用
     * `zip::ZipWriter`），里面装：
     * ```text
     * manifest.json
     * watch-data.json
     * providers.json
     * settings.json
     * plugins/<name>.js
     * ```
     * 用 ZIP 而不是单个 JSON 是因为要**同时装二进制**（插件源码）
     * 且便于用户自己解压查看。
     */
    assert!(n.ends_with(".zip"), "备份是 ZIP 归档，应以 .zip 结尾: {n}");
}

// ═══════════════════════════════════════════════════════════════════════
//  代理
// ═══════════════════════════════════════════════════════════════════════

/// 代理配置往返
#[tokio::test]
async fn proxy_config_round_trip() {
    let st = fresh("proxy").await;

    let all = cb::list_proxy_configs(&st).expect("list");
    println!("✓ 初始代理配置: {} 条", all.len());

    // 设一个
    let cfg: sourin_core::proxy::ProxyConfig = serde_json::from_value(serde_json::json!({
        "enabled": true,
        "url": "http://127.0.0.1:7890",
    }))
    .expect("构造 ProxyConfig");
    cb::set_proxy_config(&st, "cycani", cfg).expect("set");
    println!("✓ 已设置 cycani 的代理");

    let all = cb::list_proxy_configs(&st).expect("list");
    assert!(all.contains_key("cycani"), "应含 cycani");
    println!("✓ 读回: {} 条", all.len());

    // 清除
    cb::clear_proxy_config(&st, "cycani").expect("clear");
    let all = cb::list_proxy_configs(&st).expect("list");
    println!("✓ 清除后: {} 条", all.len());
}

/// 系统代理提示不该 panic
#[tokio::test]
async fn system_proxy_hint_never_panics() {
    let h = cb::system_proxy_hint().expect("hint");
    println!("✓ 系统代理提示: {h:?}");
    // 有或没有都正常 —— 只验证不 panic
}

/// 代理密码：设置后 has 为 true，且**不返回密码本身**
#[tokio::test]
async fn proxy_password_stored_in_keyring() {
    let provider = "b6-test-provider";

    let before = cb::has_proxy_password(provider).expect("has");
    println!("✓ 设置前 has_proxy_password = {before}");

    match cb::set_proxy_password(provider, "secret-123") {
        Ok(()) => {
            let after = cb::has_proxy_password(provider).expect("has");
            println!("✓ 设置后 has_proxy_password = {after}");
            assert!(after, "设置后应为 true");
        }
        Err(e) => {
            // CI / 无钥匙串的环境会失败 —— 不算代码 bug
            println!("⚠ 钥匙串不可用（环境限制，不算失败）: {e}");
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  同步（未配置时的行为）
// ═══════════════════════════════════════════════════════════════════════

/// 未配置云盘时：status 报告未连接，操作报明确错误
#[tokio::test]
async fn sync_without_config_reports_clearly() {
    let st = fresh("sync-none").await;

    let s = cb::sync_status(&st).await.expect("status");
    println!("✓ 未配置时 sync_status: {s}");
    assert_eq!(s["connected"], false);
    assert!(s["deviceId"].is_string(), "应报告本机 deviceId");

    // 三个操作都应报「尚未配置云盘」（而不是 panic 或静默成功）
    let e = cb::test_sync(&st).await.unwrap_err();
    assert!(e.contains("尚未配置"), "test_sync: {e}");
    println!("✓ test_sync → {e}");

    let e = cb::sync_now(&st).await.unwrap_err();
    assert!(e.contains("尚未配置"), "sync_now: {e}");
    println!("✓ sync_now → {e}");

    let e = cb::sync_platform_history(&st, "x").await.unwrap_err();
    assert!(e.contains("尚未配置"), "sync_platform_history: {e}");
    println!("✓ sync_platform_history → {e}");

    // 断开（本来就没配）→ 幂等成功
    cb::disconnect_sync(&st).await.expect("disconnect");
    println!("✓ disconnect_sync 幂等成功");
}

// ═══════════════════════════════════════════════════════════════════════
//  登录（不存在的源）
// ═══════════════════════════════════════════════════════════════════════

/// 对不存在的源做登录操作 → 报明确错误
#[tokio::test]
async fn login_commands_reject_unknown_provider() {
    let st = fresh("login-unknown").await;

    let e = cb::provider_login(&st, "nope", "u".into(), "p".into()).await.unwrap_err();
    assert!(e.contains("找不到 Provider"), "{e}");
    println!("✓ provider_login → {e}");

    let e = cb::provider_logout(&st, "nope").await.unwrap_err();
    assert!(e.contains("找不到 Provider"));
    println!("✓ provider_logout → {e}");

    let e = cb::provider_session(&st, "nope").await.unwrap_err();
    assert!(e.contains("找不到 Provider"));
    println!("✓ provider_session → {e}");

    let e = cb::ensure_provider_session(&st, "nope").await.unwrap_err();
    assert!(e.contains("找不到 Provider"));
    println!("✓ ensure_provider_session → {e}");

    let e = cb::forget_provider_credentials(&st, "nope").await.unwrap_err();
    assert!(e.contains("找不到 Provider"));
    println!("✓ forget_provider_credentials → {e}");

    // ⚠️ session_state 与上面不同：源不存在返回 None（不是 Err）
    let s = cb::provider_session_state(&st, "nope").await.expect("不该报错");
    assert!(s.is_none(), "源不存在时 session_state 应为 None");
    println!("✓ provider_session_state → None（与其它命令不同，原版如此）");
}

/// 抓平台历史（不存在的源）
#[tokio::test]
async fn platform_history_rejects_unknown_provider() {
    let st = fresh("plat-hist").await;
    let e = cb::backup_platform_history(&st, "nope", None).await.unwrap_err();
    assert!(e.contains("找不到 Provider"), "{e}");
    println!("✓ backup_platform_history → {e}");
}
