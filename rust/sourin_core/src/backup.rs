//! ★★ 备份导出 / 导入（`docs/播放器改版草稿.html` §五）
//!
//! # 为什么是 zip 而不是一个 JSON
//!
//! 草稿原话：
//! > JS 插件是完整源码文件，塞进 JSON 要转义成一坨字符串 ——
//! > 用户既看不懂也没法单独取出某个插件。
//! > zip 解压开就是能直接看的文件，甚至能手动改完再打回去。
//!
//! 所以结构是：
//! ```text
//! dsh-backup-20260917.zip
//! ├── manifest.json    版本号 + 导出时间 + 设备名 + 各文件校验和
//! ├── watch-data.json  收藏 / 追更 / 进度 / 历史
//! ├── providers.json   声明式源 + 第三方源配置
//! ├── settings.json    片头片尾 / 同步元数据
//! └── plugins/         插件 .js 全文
//!     ├── bilibili.js
//!     └── ...
//! ```
//!
//! # 导入的冲突策略（草稿 §五③，这步最容易出事）
//!
//! 草稿原话：
//! > 导入的本质是"用文件覆盖本机数据"。不能默默覆盖 ——
//! > 用户可能只是想把另一台机器的收藏合过来，结果本机进度全没了。
//!
//! | 数据 | 策略 | 原因 |
//! |---|---|---|
//! | 收藏 / 追更 | **合并（并集）** | 可累加，多一条不亏 |
//! | 播放进度 | **按时间戳取新** | 同一集两台都看过，取看得更晚的 |
//! | 源配置 | 让用户选（合并/覆盖） | 结构性配置，合并可能拼出谁都没测过的组合 |
//! | 插件文件 | 同名时**保留两者**（加后缀） | 不静默覆盖用户的文件 |
//!
//! ⚠️ **绝不删除**本机已有的数据 —— 导入是"加"和"更新"，
//!    不是"替换"。这是最容易被实现成破坏性操作的地方。

use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// 备份格式版本
///
/// 导入时校验：**只接受 <= 当前版本**的包（更高版本可能有不认识的字段，
/// 强行导入会丢数据）。见 `import_backup` 的版本检查。
pub const BACKUP_VERSION: u32 = 1;

/// `manifest.json` —— 包的元信息
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackupManifest {
    /// 格式版本
    pub version: u32,
    /// 导出时间（毫秒时间戳）
    pub exported_at: i64,
    /// 导出设备标识（方便用户分辨"这是哪台机器的包"）
    pub device_id: String,
    /// 应用版本
    pub app_version: String,
    /// 各文件条目与大小（`路径 → 字节数`）—— 供导入前预览
    pub entries: Vec<BackupEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackupEntry {
    pub path: String,
    pub bytes: u64,
}

/// 导入结果（供界面展示"合进来多少条"）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ImportSummary {
    /// 收藏新增数
    pub favorites_added: usize,
    /// 收藏被更新的数（远端更新）
    pub favorites_updated: usize,
    /// 追更新增数
    pub following_added: usize,
    /// 进度被更新的数
    pub progress_updated: usize,
    /// 历史新增数
    pub history_added: usize,
    /// 片头片尾被更新的数
    pub skip_updated: usize,
    /// 写入的插件文件名
    pub plugins_written: Vec<String>,
    /// 同名被改名保存的插件
    pub plugins_renamed: Vec<String>,
    /// ★ 导入后**重新注册**成功的 JS 插件数（2026-10-08 修「已解析但未注册」）
    ///
    /// 见 `commands_backup::backup_import` 的 ⑦ 段 —— 不重新注册的话，
    /// 导入完插件列表里每条都会显示「已解析但未注册」，要点一次
    /// 「重新加载插件」才好。
    pub plugins_registered: usize,
    /// 导入的源数量
    pub providers_imported: usize,
    /// 跳过项与原因（**必须展示** —— 用户要知道什么没进来）
    pub skipped: Vec<String>,
}

// ═══════════════════════════ 导出 ═══════════════════════════

/// 把要打包的内容收集起来
///
/// 分成"结构化数据"（JSON）与"原始文件"（插件源码）两类 ——
/// 后者的字节要**原样保留**，不能经 JSON 转义。
pub struct BackupPayload {
    pub manifest: BackupManifest,
    pub watch_data: serde_json::Value,
    pub providers: serde_json::Value,
    pub settings: serde_json::Value,
    /// `(文件名, 源码字节)` —— 原样写入 `plugins/` 下
    pub plugins: Vec<(String, Vec<u8>)>,
}

/// 把备份包写进内存（不落盘）
///
/// # 为什么要把内核抽出来（2026-09-29，task-75）
///
/// 「上传到云盘」这条路径**不需要本地文件** —— 它要的是字节，
/// 而 `write_backup` 只能写文件（`ZipWriter` 要 `Write + Seek`）。
///
/// 原先的做法会是「先写临时文件 → 读回来 → 上传 → 删临时文件」：
/// 多两次磁盘 I/O，还要处理临时文件残留与并发同名。
/// 直接把内核做成「写 `Cursor<Vec<u8>>`」最干净 ——
/// `Cursor<Vec<u8>>` 同时实现了 `Write` 与 `Seek`，正是 `ZipWriter` 要求的。
///
/// ★ `write_backup` 现在就是「调本函数 + 落盘」，
///   **两个入口产出的字节完全一致**（有单测锁着）。
pub fn write_backup_to_vec(payload: &BackupPayload) -> Result<Vec<u8>, String> {
    let mut zw = zip::ZipWriter::new(std::io::Cursor::new(Vec::<u8>::new()));
    let opts: zip::write::SimpleFileOptions =
        zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

    let mut add_json = |name: &str, v: &serde_json::Value| -> Result<(), String> {
        let body = serde_json::to_string_pretty(v).map_err(|e| e.to_string())?;
        zw.start_file(name, opts)
            .map_err(|e| format!("写入 {name} 失败: {e}"))?;
        zw.write_all(body.as_bytes())
            .map_err(|e| format!("写入 {name} 失败: {e}"))?;
        Ok(())
    };

    add_json("manifest.json", &serde_json::to_value(&payload.manifest).unwrap())?;
    add_json("watch-data.json", &payload.watch_data)?;
    add_json("providers.json", &payload.providers)?;
    add_json("settings.json", &payload.settings)?;

    for (name, bytes) in &payload.plugins {
        zw.start_file(format!("plugins/{name}"), opts)
            .map_err(|e| format!("写入插件 {name} 失败: {e}"))?;
        zw.write_all(bytes)
            .map_err(|e| format!("写入插件 {name} 失败: {e}"))?;
    }

    let cursor = zw.finish().map_err(|e| format!("收尾失败: {e}"))?;
    Ok(cursor.into_inner())
}

/// 写出 zip 包
///
/// # 为什么用 `zip` 的 `SimpleFileOptions` 而不是默认压缩
///
/// 插件源码本身已经是文本，`deflate` 能压到 ~25%；
/// 但 `manifest.json` 很小，压不压差别不大 —— 统一用 deflate 简单些。
///
/// ★ 内容一律经 [`write_backup_to_vec`] 生成，本函数只负责落盘 ——
///   保证「导出到文件」与「上传到云盘」是**同一份字节**。
pub fn write_backup(path: &Path, payload: &BackupPayload) -> Result<u64, String> {
    let bytes = write_backup_to_vec(payload)?;
    std::fs::write(path, &bytes).map_err(|e| format!("创建备份文件失败: {e}"))?;
    Ok(bytes.len() as u64)
}

// ═══════════════════════════ 读取 ═══════════════════════════

/// 读出的 zip 内容（全部塞进内存 —— 备份包通常只有几 MB）
///
/// ⚠️ 加了 `Debug` —— 单元测试里用 `.expect()` / `assert!` 时
///    `Result::unwrap_err` 要求 `T: Debug`，否则编译不过。
#[derive(Debug)]
pub struct BackupContents {
    pub manifest: BackupManifest,
    pub watch_data: serde_json::Value,
    pub providers: serde_json::Value,
    pub settings: serde_json::Value,
    pub plugins: Vec<(String, Vec<u8>)>,
}

/// 读取并解析备份包
///
/// # 校验（都做了，缺一不可）
///
/// 1. `manifest.json` 必须存在且能解析
/// 2. `version` 必须 **<=** [`BACKUP_VERSION`] —— 更高版本可能有不认识的字段
/// 3. 其它文件缺失时**降级为空对象**而不是报错 ——
///    老版本的包可能没有 `settings.json`，那不该让整个导入失败
///
/// ⚠️ 第 3 条是"宽容读取"：**导入是尽力而为的操作**，
///    能进来多少是多少，比整个失败好。
pub fn read_backup(path: &Path) -> Result<BackupContents, String> {
    let f = std::fs::File::open(path).map_err(|e| format!("打开备份失败: {e}"))?;
    let mut ar = zip::ZipArchive::new(f).map_err(|e| format!("这不是有效的 zip 备份: {e}"))?;

    /*
     * ⚠️ 不能用**闭包**读文件
     *
     * 原因：闭包会捕获 `&mut ar`，而 Rust 的借用检查不允许
     * 在闭包存活期间再次借用 `ar`（下面扫插件列表也要用）。
     * 实测报错：
     * ```text
     * error[E0502]: cannot borrow `ar` as immutable because it is also borrowed as mutable
     * error[E0499]: cannot borrow `ar` as mutable more than once at a time
     * ```
     *
     * 所以改成**普通函数**：每次调用独立借一次，用完立刻释放。
     */
    fn read_named(ar: &mut zip::ZipArchive<std::fs::File>, name: &str) -> Option<Vec<u8>> {
        let mut zf = ar.by_name(name).ok()?;
        let mut buf = Vec::new();
        zf.read_to_end(&mut buf).ok()?;
        Some(buf)
    }

    // ① manifest 必须存在
    let man_bytes = read_named(&mut ar, "manifest.json")
        .ok_or_else(|| "备份包里没有 manifest.json（可能不是本软件的备份）".to_string())?;
    let manifest: BackupManifest =
        serde_json::from_slice(&man_bytes).map_err(|e| format!("manifest.json 解析失败: {e}"))?;

    // ② 版本检查
    if manifest.version > BACKUP_VERSION {
        return Err(format!(
            "这个备份是更高版本导出的（v{}，本软件支持到 v{}）——\
             强行导入可能丢数据，请先升级软件",
            manifest.version, BACKUP_VERSION
        ));
    }

    // ③ 其余文件宽容读取
    let parse_or_empty = |bytes: Option<Vec<u8>>, what: &str| -> (serde_json::Value, Option<String>) {
        match bytes {
            None => (serde_json::json!({}), Some(format!("备份里没有 {what}，已跳过"))),
            Some(b) => match serde_json::from_slice::<serde_json::Value>(&b) {
                Ok(v) => (v, None),
                Err(e) => (serde_json::json!({}), Some(format!("{what} 解析失败（已跳过）: {e}"))),
            },
        }
    };

    let (watch_data, _) = parse_or_empty(read_named(&mut ar, "watch-data.json"), "watch-data.json");
    let (providers, _) = parse_or_empty(read_named(&mut ar, "providers.json"), "providers.json");
    let (settings, _) = parse_or_empty(read_named(&mut ar, "settings.json"), "settings.json");

    // ④ 插件：先收集**名字**（读完就释放借用），再逐个读内容
    let mut names: Vec<String> = Vec::new();
    for i in 0..ar.len() {
        let Ok(zf) = ar.by_index(i) else { continue };
        let name = zf.name().to_string();
        drop(zf); // ★ 显式释放，下面 read_named 还要可变借用
        if !name.starts_with("plugins/") || !name.ends_with(".js") {
            continue;
        }
        let Some(fname) = name.strip_prefix("plugins/") else { continue };
        // 防目录穿越（备份包可能是别人给的，不能信任）
        if fname.contains('/') || fname.contains('\\') || fname.contains("..") {
            continue;
        }
        names.push(name);
    }

    let mut plugins = Vec::new();
    for name in names {
        if let Some(bytes) = read_named(&mut ar, &name) {
            let fname = name.strip_prefix("plugins/").unwrap_or(&name).to_string();
            plugins.push((fname, bytes));
        }
    }

    Ok(BackupContents {
        manifest,
        watch_data,
        providers,
        settings,
        plugins,
    })
}

// ═══════════════════════════ 插件落盘（含改名保底）═══════════════════════════

/// 把一个插件文件写进插件目录
///
/// # 同名时的三种处理（按优先级）
///
/// ## ① 内容**完全相同** → 跳过，不产生副本
///
/// ⚠️⚠️ 这是实测发现的问题：最初只做了「同名就加后缀」，
/// 结果**同一个备份包重复导入会无限产生副本** ——
/// 实测一次验收跑完，插件目录从 26 个涨到 78 个
/// （`154.js` / `154-imported-1.js` / `154-imported-2.js` …）。
///
/// 用户完全可能"导入两次确认一下"，或者从云盘恢复后又导了一次 ——
/// 每次多一份副本显然不对。所以**先比内容**：
/// 字节一样就是同一个文件，直接跳过。
///
/// ## ② 内容不同 + 已存在**同源的导入副本** → 覆盖那个副本
///
/// 如果之前导入过 `<stem>-imported-<n>.js`，而这次内容又不一样
/// （比如原包更新过），应该**覆盖那个副本**而不是再加一份。
/// 否则"导入新版"会越积越多。
///
/// ## ③ 内容不同 + 没有副本 → 加后缀新建
///
/// 用户本机的 `<stem>.js` 可能是**改过的版本**，不能覆盖，
/// 所以保留两者，并在结果里报告改名（界面会展示）。
///
/// 返回 `(最终文件名, 是否改名, 是否跳过)`
pub fn write_plugin_file(
    dir: &Path,
    name: &str,
    bytes: &[u8],
) -> Result<(String, bool, bool), String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("创建插件目录失败: {e}"))?;

    let target = dir.join(name);

    // ① 完全一样 → 跳过（幂等：重复导入同一个包不会产生副本）
    if target.exists() {
        if let Ok(existing) = std::fs::read(&target) {
            if existing == bytes {
                return Ok((name.to_string(), false, true));
            }
        }
    } else {
        std::fs::write(&target, bytes).map_err(|e| format!("写入 {name} 失败: {e}"))?;
        return Ok((name.to_string(), false, false));
    }

    /*
     * ② 找已有的"导入副本"：内容不同就覆盖它，避免越积越多
     *
     * 只认我们自己起的后缀名（`-imported-<n>.js`），
     * 不动用户手写的其它文件。
     */
    let stem = name.strip_suffix(".js").unwrap_or(name);
    for n in 1..100 {
        let candidate = format!("{stem}-imported-{n}.js");
        let p = dir.join(&candidate);
        if p.exists() {
            // 内容一样 → 这个副本就是当前版本，跳过
            if let Ok(cur) = std::fs::read(&p) {
                if cur == bytes {
                    return Ok((candidate, true, true));
                }
            }
            // 内容不同 → 覆盖它（同一个"导入槽位"）
            std::fs::write(&p, bytes).map_err(|e| format!("更新 {candidate} 失败: {e}"))?;
            return Ok((candidate, true, false));
        }
    }

    // ③ 没有副本槽位 → 新建一个
    for n in 1..100 {
        let candidate = format!("{stem}-imported-{n}.js");
        let p = dir.join(&candidate);
        if !p.exists() {
            std::fs::write(&p, bytes).map_err(|e| format!("写入 {candidate} 失败: {e}"))?;
            return Ok((candidate, true, false));
        }
    }
    Err(format!("{name} 同名文件太多，无法自动改名"))
}

/// 生成默认的备份文件名
pub fn default_backup_name(device_id: &str) -> String {
    let ts = chrono::Local::now().format("%Y%m%d-%H%M%S");
    // 设备 id 可能含不适合文件名的字符，简单过滤
    let safe: String = device_id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .take(16)
        .collect();
    if safe.is_empty() {
        format!("dsh-backup-{ts}.zip")
    } else {
        format!("dsh-backup-{safe}-{ts}.zip")
    }
}

/// 备份文件常用的候选目录（供界面提示用户去哪找）
pub fn suggested_dirs() -> Vec<PathBuf> {
    let mut v = Vec::new();
    if let Some(d) = dirs_download() {
        v.push(d);
    }
    if let Some(d) = dirs_desktop() {
        v.push(d);
    }
    v
}

fn dirs_download() -> Option<PathBuf> {
    let h = std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from)?;
    let d = h.join("Downloads");
    if d.is_dir() { Some(d) } else { None }
}

fn dirs_desktop() -> Option<PathBuf> {
    let h = std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from)?;
    let d = h.join("Desktop");
    if d.is_dir() { Some(d) } else { None }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir() -> PathBuf {
        let d = std::env::temp_dir().join(format!("dsh-bk-test-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&d);
        d
    }

    fn sample_payload() -> BackupPayload {
        BackupPayload {
            manifest: BackupManifest {
                version: BACKUP_VERSION,
                exported_at: 1_700_000_000_000,
                device_id: "dev-abc".into(),
                app_version: "0.1.0".into(),
                entries: vec![],
            },
            watch_data: serde_json::json!({ "favorites": [{ "key": "a:1" }] }),
            providers: serde_json::json!({ "third_party": [] }),
            settings: serde_json::json!({ "skip_markers": [] }),
            plugins: vec![("t.js".into(), b"module.exports = {}".to_vec())],
        }
    }

    #[test]
    fn roundtrip_preserves_plugin_bytes() {
        let d = tmpdir();
        let p = d.join("rt.zip");
        let _ = std::fs::remove_file(&p);
        let n = write_backup(&p, &sample_payload()).expect("写出失败");
        assert!(n > 0, "备份大小应大于 0");

        let c = read_backup(&p).expect("读取失败");
        assert_eq!(c.manifest.device_id, "dev-abc");
        assert_eq!(c.plugins.len(), 1);
        // ★ 字节必须**原样**保留（不能经 JSON 转义）
        assert_eq!(c.plugins[0].1, b"module.exports = {}");
    }

    #[test]
    fn rejects_future_version() {
        let d = tmpdir();
        let p = d.join("future.zip");
        let _ = std::fs::remove_file(&p);
        let mut pl = sample_payload();
        pl.manifest.version = BACKUP_VERSION + 5;
        write_backup(&p, &pl).unwrap();

        let e = read_backup(&p).unwrap_err();
        assert!(e.contains("更高版本"), "应提示版本过高，实际: {e}");
    }

    #[test]
    fn missing_watch_data_is_tolerated() {
        let d = tmpdir();
        let p = d.join("partial.zip");
        let _ = std::fs::remove_file(&p);

        // 手工造一个只有 manifest 的包
        {
            let f = std::fs::File::create(&p).unwrap();
            let mut zw = zip::ZipWriter::new(f);
            let o: zip::write::SimpleFileOptions = Default::default();
            zw.start_file("manifest.json", o).unwrap();
            let m = BackupManifest {
                version: BACKUP_VERSION,
                exported_at: 0,
                device_id: "x".into(),
                app_version: "0".into(),
                entries: vec![],
            };
            zw.write_all(serde_json::to_string(&m).unwrap().as_bytes()).unwrap();
            zw.finish().unwrap();
        }

        // ★ 不该报错 —— 导入是尽力而为
        let c = read_backup(&p).expect("缺文件时应宽容读取");
        assert_eq!(c.watch_data, serde_json::json!({}));
    }

    #[test]
    fn plugin_same_name_gets_renamed_not_overwritten() {
        let d = tmpdir().join("plug");
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();

        let (n1, r1, s1) = write_plugin_file(&d, "x.js", b"original").unwrap();
        assert_eq!(n1, "x.js");
        assert!(!r1 && !s1, "第一次是新建");

        /*
         * ★ 内容不同 → 保留两者（不能覆盖用户改过的文件）
         */
        let (n2, r2, s2) = write_plugin_file(&d, "x.js", b"imported").unwrap();
        assert!(r2, "内容不同应改名");
        assert!(!s2, "内容不同不该跳过");
        assert_ne!(n2, "x.js");
        assert_eq!(std::fs::read(d.join("x.js")).unwrap(), b"original", "原文件不能被覆盖");
        assert_eq!(std::fs::read(d.join(&n2)).unwrap(), b"imported");

        /*
         * ★★ 内容相同 → **跳过**，不产生副本
         *
         * 这是实测发现的问题：最初只做"同名加后缀"，
         * 结果同一个包重复导入会无限产生副本
         * （实测插件目录从 26 涨到 78）。
         */
        let (n3, _r3, s3) = write_plugin_file(&d, "x.js", b"imported").unwrap();
        assert!(s3, "内容相同应跳过（幂等）");
        assert_eq!(n3, n2, "跳过的应是那个已有副本");

        // 文件数没变
        let n = std::fs::read_dir(&d).unwrap().count();
        assert_eq!(n, 2, "重复导入不该新增文件，实际 {n} 个");
    }

    #[test]
    fn plugin_import_is_idempotent() {
        let d = tmpdir().join("plug2");
        let _ = std::fs::remove_dir_all(&d);

        // 连跑 5 次"导入同一个包"
        for _ in 0..5 {
            let _ = write_plugin_file(&d, "a.js", b"AAA").unwrap();
            let _ = write_plugin_file(&d, "b.js", b"BBB").unwrap();
        }
        let n = std::fs::read_dir(&d).unwrap().count();
        assert_eq!(n, 2, "重复导入 5 次后仍应只有 2 个文件，实际 {n} 个");
    }

    #[test]
    fn plugin_updates_existing_import_slot() {
        let d = tmpdir().join("plug3");
        let _ = std::fs::remove_dir_all(&d);

        write_plugin_file(&d, "y.js", b"v1").unwrap();
        // 第一次导入 v2 → 建副本
        write_plugin_file(&d, "y.js", b"v2").unwrap();
        // 再导入 v3 → **覆盖那个副本**，不是再加一份
        write_plugin_file(&d, "y.js", b"v3").unwrap();

        let n = std::fs::read_dir(&d).unwrap().count();
        assert_eq!(n, 2, "更新导入应覆盖副本而不是新增，实际 {n} 个");
        assert_eq!(std::fs::read(d.join("y.js")).unwrap(), b"v1", "原文件不动");
        assert_eq!(
            std::fs::read(d.join("y-imported-1.js")).unwrap(),
            b"v3",
            "副本应是最后一次导入的内容"
        );
    }

    #[test]
    fn rejects_path_traversal_in_backup() {
        let d = tmpdir();
        let p = d.join("evil.zip");
        let _ = std::fs::remove_file(&p);

        // 造一个带 ../ 路径的恶意包
        {
            let f = std::fs::File::create(&p).unwrap();
            let mut zw = zip::ZipWriter::new(f);
            let o: zip::write::SimpleFileOptions = Default::default();
            zw.start_file("manifest.json", o).unwrap();
            let m = BackupManifest {
                version: BACKUP_VERSION, exported_at: 0,
                device_id: "x".into(), app_version: "0".into(), entries: vec![],
            };
            zw.write_all(serde_json::to_string(&m).unwrap().as_bytes()).unwrap();
            zw.start_file("plugins/../../evil.js", o).unwrap();
            zw.write_all(b"evil").unwrap();
            zw.finish().unwrap();
        }

        let c = read_backup(&p).expect("读取应成功");
        assert!(c.plugins.is_empty(), "带目录穿越的插件条目必须被丢弃");
    }

    #[test]
    fn default_name_is_filesystem_safe() {
        let n = default_backup_name("dev/with:bad*chars");
        assert!(n.starts_with("dsh-backup-"), "实际: {n}");
        assert!(n.ends_with(".zip"));
        assert!(!n.contains('/') && !n.contains(':') && !n.contains('*'), "不能含非法字符: {n}");
    }

    /// ★ `write_backup_to_vec` 与 `write_backup` 必须产出**逐字节相同**的包
    ///
    /// # 为什么值得单独锁一个字节相等
    ///
    /// 「导出到文件」与「上传到云盘」现在共用同一条内核，但落盘方式不同：
    /// ```text
    /// write_backup(path, p)  →  write_backup_to_vec(p) + fs::write
    /// 云盘上传               →  write_backup_to_vec(p)          直接当字节发
    /// ```
    /// 若日后有人把 `write_backup` 改回「自己 new 一个 ZipWriter」，
    /// 两条路径的包就会**悄然分叉** —— 症状是「导出的包能导入，
    /// 云盘上那份却报『不是本软件的备份』」，而这种差别在 zip 的
    /// 压缩实现细节里几乎看不出来。所以用字节相等把它钉死。
    #[test]
    fn write_backup_to_vec_matches_write_backup_bytes() {
        let d = tmpdir();
        let p = d.join("bytes-eq.zip");
        let _ = std::fs::remove_file(&p);
        let payload = sample_payload();

        let n = write_backup(&p, &payload).expect("写出失败");
        let on_disk = std::fs::read(&p).expect("读回失败");
        let in_mem = write_backup_to_vec(&payload).expect("生成失败");

        assert_eq!(n as usize, in_mem.len(), "返回值必须等于字节数");
        assert!(!in_mem.is_empty(), "包不该是空的");
        assert_eq!(on_disk, in_mem, "两条路径的字节必须完全一致");

        // 内存版也要能被正常读回（否则「字节一致」只是个巧合）
        let c = read_backup(&p).expect("读取失败");
        assert_eq!(c.manifest.device_id, "dev-abc");
        assert_eq!(c.plugins[0].1, b"module.exports = {}");

        // 同一 payload 连着生成两次必须稳定（否则「内容没变」的判断不可靠）
        assert_eq!(
            write_backup_to_vec(&payload).unwrap(),
            in_mem,
            "同样的输入应产出同样的字节"
        );
    }
}
