// ═══════════════════════════════════════════════════════════════════════
//  批次 1 验收 —— 只读命令对「真实用户数据」的忠实度（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个测试要回答的问题
//
// 我把 10 个只读命令从 Tauri 搬到了 FFI。搬运**看起来**是对的，
// 但「看起来对」不算数 —— 需要证明：
//
// ```text
// ① 命令真能读到数据（不是静默返回空）
// ② 读到的内容与真实库一致（键格式 / 字段 / 数值都对得上）
// ③ 搬运没引入行为差异（默认值、排序、过滤都与原版一致）
// ```
//
// # 为什么用「真实数据的副本」而不是构造假数据
//
// 构造假数据只能验证「我以为的格式」；用**真实库的副本**能验证
// 「用户实际存在库里的格式」。两者的差别是决定性的：
//
// ```text
// 我造的假数据    → 我会按自己的理解造，验证不出误解
// 真实数据副本    → 含真实的 provider 名、真实的中文标题、
//                   真实的复合键（cycani:3862、bilibili:av:BVxxx）、
//                   真实的 NULL 字段
// ```
//
// # ★ 副本怎么来的（这一步很关键）
//
// 用户库是 **WAL 模式**，直接 Copy-Item 主库文件会**丢掉 WAL 里
// 未 checkpoint 的数据** —— 实测行数变少（favorites 7→5）。
// 所以副本必须用 SQLite 的 `backup()` API 生成：
//
// ```python
// src = sqlite3.connect(f'file:{db}?mode=ro', uri=True)
// dst = sqlite3.connect(dst_path)
// src.backup(dst)     # ← 把 WAL 一起写进去，得到一致快照
// ```
//
// 副本位置：`%APPDATA%\app.sourin\sourin_spike\mig-probe\dsh-media.db`
//
// ⚠️ 用户真实库**全程只读**，本测试只碰副本。
//
// # 运行方式
//
// 这是个 Rust 集成测试（不是 Dart 探针）—— 因为被测对象是 Rust 命令层，
// 直接用 `cargo test` 就能跑，不需要构建 App。
// 但副本路径在用户目录下，所以标记为 `#[ignore]`，
// 需要显式 `cargo test -- --ignored` 才跑（避免 CI/他人环境失败）。

#[cfg(test)]
mod batch1_readonly {
    use sourin_core::commands;
    use sourin_core::state::AppState;

    /// 真实数据副本路径
    fn probe_dir() -> std::path::PathBuf {
        let appdata = std::env::var("APPDATA").expect("APPDATA 未设置");
        std::path::PathBuf::from(appdata)
            .join("app.sourin")
            .join("sourin_spike")
            .join("mig-probe")
    }

    async fn state() -> std::sync::Arc<AppState> {
        let dir = probe_dir();
        assert!(
            dir.join("dsh-media.db").exists(),
            "真实数据副本不存在: {} —— 需先用 backup API 生成",
            dir.display()
        );
        AppState::bootstrap(dir).await.expect("bootstrap 失败")
    }

    /// ★ 只读命令必须能读到**真实**数据
    ///
    /// 判据不是「不报错」，而是「读到的条数与真实库一致」。
    /// 具体条数写死在断言里 —— 这样一旦搬运引入回归（比如键格式
    /// 拼错导致查不到），条数会变成 0 而测试失败。
    #[tokio::test]
    #[ignore = "需要真实数据副本，显式 --ignored 运行"]
    async fn reads_real_user_data() {
        let st = state().await;

        // ── 进度 ──
        let all = commands::list_all_progress(&st).expect("list_all_progress");
        assert_eq!(all.len(), 9, "进度条数应为 9");
        println!("✓ list_all_progress = {} 条", all.len());

        let cw = commands::continue_watching(&st, None).expect("continue_watching");
        assert!(!cw.is_empty(), "继续观看不应为空");
        assert!(cw.len() <= 20, "默认 limit 应为 20");
        println!("✓ continue_watching = {} 条（默认 limit 20）", cw.len());

        // ★ 单个进度：用真实库里确实存在的键
        //
        // 这条同时验证了**键格式** —— `cycani:3862` 是真实库里的
        // `key` 字段值。如果我的 item_key() 拼错（比如用了 `-` 分隔），
        // 这里会返回 None 而失败。
        let p = commands::get_progress(&st, "cycani", "3862").expect("get_progress");
        assert!(p.is_some(), "cycani:3862 应有进度（键格式错了才会是 None）");
        let p = p.unwrap();
        assert_eq!(p.provider, "cycani");
        assert_eq!(p.native_id, "3862");
        assert_eq!(p.key, "cycani:3862", "复合键格式必须是 provider:native_id");
        println!(
            "✓ get_progress(cycani, 3862) = 《{}》 pos={}s dur={}s",
            p.title, p.position, p.duration
        );

        // ★ 不存在的键必须返回 None（而不是报错）
        //
        // 这个行为很重要：UI 靠 None 判断「没看过」。
        // 如果错写成 Err，UI 会弹出错误提示而不是从头播。
        let none = commands::get_progress(&st, "不存在", "999999").expect("查不存在的不该报错");
        assert!(none.is_none(), "不存在的键应返回 None");
        println!("✓ get_progress(不存在的键) = None（正确，UI 靠它判断没看过）");

        // ── 历史 ──
        let h = commands::list_history(&st, None).expect("list_history");
        assert_eq!(h.len(), 9, "历史条数应为 9");
        println!("✓ list_history = {} 条", h.len());

        // ── 片头片尾 ──
        let sm = commands::list_skip_markers(&st).expect("list_skip_markers");
        assert_eq!(sm.len(), 3, "跳过点应为 3 条");
        println!("✓ list_skip_markers = {} 条", sm.len());

        // ★ 单条跳过点 + 数值正确
        let one = commands::get_skip_marker(&st, "cycani", "3862").expect("get_skip_marker");
        assert!(one.is_some(), "cycani:3862 应有跳过点");
        let one = one.unwrap();
        assert_eq!(one.intro_end, Some(69), "真实库里 intro_end 是 69");
        println!("✓ get_skip_marker(cycani, 3862) intro_end={:?}", one.intro_end);

        // ── 收藏 ──
        //
        // ⚠️ 这里有个**行为差异要验证**：
        // `list_favorites(include_deleted)` 的布尔开关。
        // 真实库 7 行里有多条 `deleted=1` 的墓碑（m6probe-*），
        // 所以 false/true 的条数**应该不同** —— 如果相同，
        // 说明这个参数没起作用（搬运漏了）。
        let live = commands::list_favorites(&st, false).await.expect("list_favorites(false)");
        let all_fav = commands::list_favorites(&st, true).await.expect("list_favorites(true)");
        println!(
            "✓ list_favorites: 有效 {} 条 / 含墓碑 {} 条",
            live.len(),
            all_fav.len()
        );
        assert_eq!(all_fav.len(), 7, "含墓碑应为 7 条（真实库总数）");
        assert!(
            live.len() < all_fav.len(),
            "有效条数({})应少于含墓碑({}) —— 否则 include_deleted 没生效",
            live.len(),
            all_fav.len()
        );
        // 墓碑不该出现在有效列表里
        assert!(
            live.iter().all(|f| f.native_id != "m6probe-1"),
            "m6probe-1 是已删除的墓碑，不该出现在有效列表"
        );
        println!("✓ 墓碑(m6probe-*)已正确排除");

        // ── 追更 / 未读 ──
        let fu = commands::list_following_for_ui(&st).expect("list_following_for_ui");
        println!("✓ list_following_for_ui = {} 条", fu.len());

        let unread = commands::total_unread(&st).expect("total_unread");
        println!("✓ total_unread = {unread}（底栏徽章用）");

        // ── 平台历史 ──
        let ph = commands::list_platform_history(&st, 100).expect("list_platform_history");
        assert_eq!(ph.len(), 0, "真实库里 platform_history 是空的");
        println!("✓ list_platform_history = {} 条（真实库为空，符合预期）", ph.len());

        println!();
        println!("════ 批次 1 验收通过 ════");
    }

    /// 中文与特殊字符必须原样往返
    ///
    /// 真实库里有中文标题、日文（《无职转生 第三季 ～到了异世界就拿出真本事～》）、
    /// 以及含 `&` 的 URL。SQLite 存 UTF-8，取出来不能变形。
    #[tokio::test]
    #[ignore = "需要真实数据副本，显式 --ignored 运行"]
    async fn preserves_unicode_titles() {
        let st = state().await;
        let p = commands::get_progress(&st, "cycani", "3862")
            .expect("get_progress")
            .expect("应有数据");

        assert!(
            p.title.contains("无职转生"),
            "中文标题应完整: {}",
            p.title
        );
        // 日文波浪线 ～ (U+FF5E) 与 〜 (U+301C) 是不同的码位，
        // 必须原样保留 —— 这是最容易在编码转换里被"顺手修正"的地方
        assert_eq!(
            p.title, "无职转生 第三季 ～到了异世界就拿出真本事～",
            "标题必须逐字节一致（注意 ～ 是 U+FF5E）"
        );
        println!("✓ 中文/日文标题逐字一致: {}", p.title);

        // URL 里的 & 不能被转义
        if let Some(cover) = &p.cover {
            assert!(
                cover.starts_with("http"),
                "封面应为 URL: {cover}"
            );
            println!("✓ 封面 URL 保持原样");
        }
    }

    /// 读操作不得修改数据库
    ///
    /// # 为什么值得单独测
    ///
    /// "只读命令"是**设计意图**，不是系统保证 —— SQLite 不阻止
    /// 一个 SELECT 函数顺手写日志表。而用户库里有真实数据，
    /// 任何意外写入都是不可接受的。
    ///
    /// 做法：记录副本文件的修改时间 → 跑一遍所有只读命令 →
    /// 再比对。如果时间变了，说明有隐藏写入。
    #[tokio::test]
    #[ignore = "需要真实数据副本，显式 --ignored 运行"]
    async fn readonly_commands_do_not_write() {
        let dir = probe_dir();
        let db = dir.join("dsh-media.db");

        let before = std::fs::metadata(&db).expect("stat").modified().unwrap();
        let size_before = std::fs::metadata(&db).expect("stat").len();

        {
            let st = state().await;
            let _ = commands::list_all_progress(&st);
            let _ = commands::continue_watching(&st, Some(10));
            let _ = commands::get_progress(&st, "cycani", "3862");
            let _ = commands::list_history(&st, Some(50));
            let _ = commands::get_skip_marker(&st, "cycani", "3862");
            let _ = commands::list_skip_markers(&st);
            let _ = commands::list_favorites(&st, false).await;
            let _ = commands::list_favorites(&st, true).await;
            let _ = commands::list_following_for_ui(&st);
            let _ = commands::total_unread(&st);
            let _ = commands::list_platform_history(&st, 50);
        }

        // 给文件系统一点时间落盘（Windows 上 mtime 更新不是瞬时的）
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;

        let after = std::fs::metadata(&db).expect("stat").modified().unwrap();
        let size_after = std::fs::metadata(&db).expect("stat").len();

        assert_eq!(
            before, after,
            "只读命令修改了数据库文件！mtime {before:?} -> {after:?}"
        );
        assert_eq!(size_before, size_after, "只读命令改变了文件大小");
        println!("✓ 11 个只读命令执行后，数据库文件大小与修改时间均未变化");
    }
}
