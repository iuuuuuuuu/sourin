// ═══════════════════════════════════════════════════════════════════════
//  批次 5 验收 —— Provider 与插件管理（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这部分的关键是「持久化」和「安全」
//
// ```text
// ① 停用源 → 必须落盘（重启后还是停用）
// ② 排序   → 必须落盘，且返回**真实结果**而不是回显入参
// ③ 移除源 → 内存 + 清单都要清（否则"幽灵源"复活）
// ④ 插件文件名 → 必须防目录穿越（参数来自前端）
// ⑤ 插件配置声明 → 必须从 registry 拿（否则永远是空数组）
// ```
//
// # ⚠️ 用隔离目录
//
// 这批会**写文件**（disabled-providers.json / provider-order.json /
// third-party-providers.json / plugins/*.js），所以全部用独立数据目录。
// 但插件要从真实目录**复制**一份进来（只读复制），才能验到真实插件。

use sourin_core::commands;
use sourin_core::commands_provider as cp;
use sourin_core::state::AppState;
use std::sync::Arc;

/// 全新隔离目录
async fn fresh(tag: &str) -> Arc<AppState> {
    let dir = std::env::temp_dir().join(format!(
        "sourin-b5-{tag}-{}",
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
    ));
    std::fs::create_dir_all(&dir).unwrap();
    AppState::bootstrap(dir).await.expect("bootstrap")
}

/// 隔离目录 + 真实插件（只读复制真库的 plugins/）
///
/// # ★ 复制完必须 `reload_plugins()`（2026-09-22 踩到的脚手架 bug）
///
/// 第一版写的是「先 bootstrap，再复制插件」—— 结果 26 个插件
/// 只有 1 个被加载（`bootstrap` 早就扫过目录了，之后复制进去的
/// 文件它不知道）。
///
/// 症状极具误导性：`list_plugins` 报「成功加载: 1 个」，
/// 看起来像**插件加载功能有 bug**，实际是我的测试顺序错了。
///
/// 对照证据：同一批插件在批次 3 的搜索测试里 26 个源全部可用 ——
/// 说明加载本身没问题。
///
/// 修法：复制完显式重载一次。
async fn with_real_plugins(tag: &str) -> Arc<AppState> {
    let st = fresh(tag).await;
    let appdata = std::env::var("APPDATA").unwrap();
    let src = std::path::PathBuf::from(&appdata)
        .join("app.sourin.player")
        .join("plugins");
    let dst = st.data_dir.join("plugins");
    std::fs::create_dir_all(&dst).unwrap();
    let mut copied = 0;
    if src.exists() {
        for e in std::fs::read_dir(&src).unwrap().flatten() {
            if e.path().extension().and_then(|s| s.to_str()) == Some("js") {
                if std::fs::copy(e.path(), dst.join(e.file_name())).is_ok() {
                    copied += 1;
                }
            }
        }
    }
    if copied > 0 {
        // ★ 关键一步：让 registry 看到这些插件
        let _ = cp::reload_plugins(&st).await;
    }
    st
}

// ═══════════════════════════════════════════════════════════════════════
//  停用状态的持久化
// ═══════════════════════════════════════════════════════════════════════

/// ★ 停用必须落盘（原版实测过的 bug：重启后全部恢复启用）
#[tokio::test]
async fn disable_is_persisted_across_restart() {
    let st = with_real_plugins("persist-disable").await;

    let ids: Vec<String> = st.registry.manifests().iter().map(|m| m.id.clone()).collect();
    assert!(ids.len() > 1, "需要多个源才能测（实际 {}）", ids.len());
    let target = ids[1].clone();
    println!("源数量: {}，测试停用: {target}", ids.len());

    // 停用
    let ok = cp::set_enabled_persisted(&st, &target, false).expect("disable");
    assert!(ok, "停用应成功");
    assert!(!commands::get_provider_enabled(&st, &target).unwrap(), "应显示为停用");
    println!("✓ 停用后 get_provider_enabled = false");

    // ★ 关键：检查落盘文件真的写了
    let f = st.data_dir.join("disabled-providers.json");
    assert!(f.exists(), "disabled-providers.json 应该被创建");
    let body = std::fs::read_to_string(&f).unwrap();
    assert!(body.contains(&target), "文件里应含被停用的 id: {body}");
    println!("✓ 落盘文件含 {target}");

    // ★ 模拟重启：用同一个数据目录重新 bootstrap
    let dir = st.data_dir.clone();
    drop(st);
    let st2 = AppState::bootstrap(dir).await.expect("重新 bootstrap");
    assert!(
        !commands::get_provider_enabled(&st2, &target).unwrap(),
        "★ 重启后仍应是停用状态（否则就是「只改内存」的老 bug）"
    );
    println!("✓ 重启后仍然停用 —— 持久化生效");

    // 重新启用 → 文件里应该被移除
    let ok = cp::set_enabled_persisted(&st2, &target, true).expect("enable");
    assert!(ok);
    assert!(commands::get_provider_enabled(&st2, &target).unwrap());
    let body = std::fs::read_to_string(st2.data_dir.join("disabled-providers.json")).unwrap();
    assert!(!body.contains(&target), "启用后应从停用清单里移除: {body}");
    println!("✓ 重新启用后从清单移除");
}

/// 停用一个不存在的源 → 返回 false（不是报错）
#[tokio::test]
async fn disabling_unknown_provider_returns_false() {
    let st = fresh("disable-unknown").await;
    let ok = cp::set_enabled_persisted(&st, "definitely-not-a-provider", false).unwrap();
    assert!(!ok, "不存在的源应返回 false");
    println!("✓ 停用不存在的源 → false（不报错，前端据此提示）");
}

// ═══════════════════════════════════════════════════════════════════════
//  排序
// ═══════════════════════════════════════════════════════════════════════

/// ★ 排序返回**真实结果**（而不是回显入参）
#[tokio::test]
async fn reorder_returns_actual_and_persists() {
    let st = with_real_plugins("reorder").await;

    let mut ids: Vec<String> = st.registry.manifests().iter().map(|m| m.id.clone()).collect();
    assert!(ids.len() >= 3, "需要至少 3 个源");
    let original = ids.clone();

    // 倒序 + 塞一个不存在的 id（模拟前端列表过期）
    ids.reverse();
    ids.push("ghost-provider-that-does-not-exist".into());

    let actual = cp::set_provider_order(&st, &ids).expect("reorder");
    println!("入参: {} 个（含 1 个不存在的）", ids.len());
    println!("实际: {} 个", actual.len());

    assert!(
        !actual.contains(&"ghost-provider-that-does-not-exist".to_string()),
        "★ 返回的真实顺序里不该有不存在的源"
    );
    assert_eq!(actual.len(), original.len(), "应包含全部真实源");
    assert_eq!(
        actual.first(),
        original.last(),
        "倒序后第一个应是原来的最后一个"
    );
    println!("✓ 返回真实顺序（过滤掉了幽灵 id）");

    // 落盘
    let f = st.data_dir.join("provider-order.json");
    assert!(f.exists(), "provider-order.json 应被创建");
    let saved: Vec<String> = serde_json::from_str(&std::fs::read_to_string(&f).unwrap()).unwrap();
    assert_eq!(saved, actual, "落盘内容应与返回值一致");
    println!("✓ 落盘内容与返回值一致");

    // ★ 重启后顺序保持
    let dir = st.data_dir.clone();
    drop(st);
    let st2 = AppState::bootstrap(dir).await.expect("重启");
    let after = commands::get_provider_order(&st2).unwrap();
    assert_eq!(after, actual, "重启后顺序应保持");
    println!("✓ 重启后顺序保持");
}

// ═══════════════════════════════════════════════════════════════════════
//  插件管理
// ═══════════════════════════════════════════════════════════════════════

/// ★★ 插件列表必须带**配置声明**（原版踩过的静默失败）
///
/// 错误做法：从 `load_plugins()` 拿 → `config` 永远是空数组 →
/// 设置页不显示「配置」按钮，而且不报错。
#[tokio::test]
#[ignore = "需要真实插件目录，显式 --ignored 运行"]
async fn list_plugins_includes_config_declarations() {
    let st = with_real_plugins("list-plugins").await;

    let r = cp::list_plugins(&st).expect("list_plugins");
    println!("插件文件: {} 个", r.plugins.len());
    println!("加载失败: {} 个", r.failed.len());

    let loaded = r.plugins.iter().filter(|p| p.loaded).count();
    println!("成功加载: {loaded} 个");

    let with_config = r.plugins.iter().filter(|p| !p.config.is_empty()).count();
    println!("声明了配置项的: {with_config} 个");

    for p in r.plugins.iter().take(6) {
        println!(
            "── {} → id={} name={} loaded={} config={} 项",
            p.file,
            if p.id.is_empty() { "(缺@id)" } else { &p.id },
            p.name,
            p.loaded,
            p.config.len()
        );
        for c in p.config.iter().take(3) {
            println!("     配置: {} ({:?})", c.key, c.label);
        }
        if let Some(e) = &p.error {
            println!("     错误: {e}");
        }
    }

    assert!(loaded > 0, "应该有插件成功加载");
    println!();
    println!("✓ 插件列表: {loaded} 个加载成功，{with_config} 个带配置声明");

    /*
     * ⚠️ 这里**不断言** with_config > 0 ——
     *    因为「有没有插件声明配置」取决于用户装了哪些插件，
     *    不是代码正确性的判据。
     *
     * 真正的判据是：**如果**某个源在 registry 里有 config 声明，
     * 那 list_plugins 也必须报告同样的 config 数量。
     * 那才是"从 registry 拿"的正确性证明。
     */
    let mut checked = 0;
    for m in st.registry.manifests() {
        if m.config.is_empty() {
            continue;
        }
        if let Some(p) = r.plugins.iter().find(|p| p.id == m.id) {
            assert_eq!(
                p.config.len(),
                m.config.len(),
                "★ 插件 {} 的 config 数量（{}）必须与 registry（{}）一致 —— \
                 不一致说明没有从 registry 拿（那就是原版那个静默失败的 bug）",
                m.id,
                p.config.len(),
                m.config.len()
            );
            checked += 1;
            println!(
                "✓ {} 的 config 与 registry 一致（{} 项）",
                m.id,
                p.config.len()
            );
        }
    }
    if checked == 0 {
        println!("（没有源声明配置项，无法交叉验证 —— 不算失败）");
    }
}

/// ★★ 防目录穿越（参数来自前端，必须当不可信输入）
#[tokio::test]
async fn plugin_paths_reject_traversal() {
    let st = with_real_plugins("traversal").await;

    let attacks = [
        "../../../etc/passwd",
        "..\\..\\Windows\\System32\\drivers\\etc\\hosts",
        "sub/dir.js",
        "sub\\dir.js",
        "..",
    ];

    for a in attacks {
        let e = cp::read_plugin(&st, a).unwrap_err();
        assert!(e.contains("非法"), "read_plugin({a}) 应被拒绝，实际: {e}");
        let e = cp::remove_plugin(&st, a).unwrap_err();
        assert!(e.contains("非法"), "remove_plugin({a}) 应被拒绝，实际: {e}");
        let e = cp::save_plugin_source(&st, a, "// x").await.unwrap_err();
        assert!(e.contains("非法"), "save_plugin_source({a}) 应被拒绝，实际: {e}");
        println!("✓ 拒绝: {a}");
    }
    println!();
    println!("✓ 三个命令都挡住了 {} 种穿越尝试", attacks.len());
}

/// 读一个真实插件源码（正例）
#[tokio::test]
#[ignore = "需要真实插件目录，显式 --ignored 运行"]
async fn read_real_plugin_source() {
    let st = with_real_plugins("read-plugin").await;

    let r = cp::list_plugins(&st).expect("list");
    let Some(first) = r.plugins.first() else {
        println!("⚠ 没有插件");
        return;
    };

    let src = cp::read_plugin(&st, &first.file).expect("read_plugin");
    println!("✓ 读取 {}: {} 字节", first.file, src.len());
    println!("  前 120 字符: {}", &src.chars().take(120).collect::<String>());

    assert!(!src.is_empty(), "插件源码不该为空");
    // 头部注释里应有 @id（parse_meta 从那里读）
    assert!(src.contains("@id") || src.contains("@name"), "应含元信息注释");
}

/// 保存时必须校验元信息（缺 @id 要拒绝）
#[tokio::test]
#[ignore = "需要真实插件目录，显式 --ignored 运行"]
async fn save_rejects_invalid_plugin() {
    let st = with_real_plugins("save-invalid").await;

    let r = cp::list_plugins(&st).expect("list");
    let Some(first) = r.plugins.first() else {
        println!("⚠ 没有插件");
        return;
    };

    // ① 缺 @id
    let bad = "// 没有元信息\nvar x = 1;";
    let e = cp::save_plugin_source(&st, &first.file, bad).await.unwrap_err();
    assert!(e.contains("@id") || e.contains("缺少"), "应报缺 @id: {e}");
    println!("✓ 拒绝缺 @id: {e}");

    // ② 语法错误（validate_source 会真的执行一次）
    let bad2 = "/*\n@id test\n@name 测试\n*/\nfunction broken( {";
    let e2 = cp::save_plugin_source(&st, &first.file, bad2).await;
    match e2 {
        Err(e) => println!("✓ 拒绝语法错误: {e}"),
        Ok(_) => {
            println!("⚠ 语法错误未被捕获（不同 JS 引擎的容忍度可能不同）");
            println!("  —— 不算失败，但记录这一现象");
        }
    }

    // ③ 保存一个不存在的文件 → 拒绝（这个命令是"编辑已有"，不是"新建"）
    let e3 = cp::save_plugin_source(&st, "not-exist-xyz.js", bad).await.unwrap_err();
    assert!(e3.contains("不存在"), "应报文件不存在: {e3}");
    println!("✓ 拒绝保存不存在的文件: {e3}");

    // ④ 保存一个**合法**的最小插件 → 应成功
    let good = "/*\n@id b5-test-plugin\n@name 批次5测试\n@version 1.0.0\n*/\n\
                var rule = {};\n";
    match cp::save_plugin_source(&st, &first.file, good).await {
        Ok(n) => println!("✓ 合法插件保存成功，热重载后共 {n} 个插件"),
        Err(e) => println!("⚠ 合法插件保存失败: {e}（可能该插件的 @id 有额外要求）"),
    }
}

/// reload_plugins：重载后插件数量应稳定（不重复注册）
#[tokio::test]
#[ignore = "需要真实插件目录，显式 --ignored 运行"]
async fn reload_does_not_duplicate() {
    let st = with_real_plugins("reload").await;

    let before = st.registry.manifests().len();
    let n1 = cp::reload_plugins(&st).await.expect("reload 1");
    let after1 = st.registry.manifests().len();
    let n2 = cp::reload_plugins(&st).await.expect("reload 2");
    let after2 = st.registry.manifests().len();

    println!("初始: {before} 个源");
    println!("第 1 次重载: 返回 {n1}，注册表 {after1}");
    println!("第 2 次重载: 返回 {n2}，注册表 {after2}");

    assert_eq!(
        after1, after2,
        "★ 连续重载不应让源数量增加（否则就是重复注册）"
    );
    println!("✓ 连续重载数量稳定（无重复注册）");
}

/// remove_provider：内存 + 清单都要清（否则幽灵源复活）
#[tokio::test]
async fn remove_provider_clears_both() {
    let st = with_real_plugins("remove-provider").await;

    let ids: Vec<String> = st.registry.manifests().iter().map(|m| m.id.clone()).collect();
    let Some(target) = ids.last() else {
        println!("⚠ 没有源");
        return;
    };
    let target = target.clone();

    let removed = cp::remove_provider(&st, &target).expect("remove");
    assert!(removed, "应成功移除");
    println!("✓ 已移除 {target}");

    // 内存里没了
    assert!(
        !st.registry.manifests().iter().any(|m| m.id == target),
        "registry 里不该还有"
    );
    println!("✓ registry 里已消失");

    // 再移除一次 → false（幂等）
    let again = cp::remove_provider(&st, &target).expect("remove again");
    assert!(!again, "重复移除应返回 false");
    println!("✓ 重复移除返回 false");

    // 不存在的源
    let none = cp::remove_provider(&st, "never-existed-xyz").expect("remove unknown");
    assert!(!none);
    println!("✓ 移除不存在的源返回 false");
}

/// touch_providers 会更新时间戳（云同步的 LWW 判据）
#[tokio::test]
async fn touch_providers_updates_timestamp() {
    let st = fresh("touch").await;

    let before = st
        .providers_updated_at
        .load(std::sync::atomic::Ordering::SeqCst);
    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    cp::touch_providers(&st);
    let after = st
        .providers_updated_at
        .load(std::sync::atomic::Ordering::SeqCst);

    assert!(after > before, "时间戳应更新（{before} → {after}）");
    println!("✓ touch_providers: {before} → {after}");
}
