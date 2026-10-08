// ═══════════════════════════════════════════════════════════════════════
//  批次 7 · 局域网遥控 + 剩余命令（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这批把 87 个命令补齐
//
// ```text
// 遥控      9 个  remote（局域网手机遥控电脑播放）
// 追更      1 个  check_updates
// 健康检查  1 个  health_sweep
// 收藏切换  1 个  toggle_favorite
// 插件安装  4 个  install_plugin / install_plugin_source
//                  install_declarative_provider / install_http_provider
// 插件配置  1 个  plugin_config_set
// ```
//
// # ★★ 遥控的「配对码」设计（这批最需要注意的地方）
//
// ```text
// 随机码  每次启动/刷新都变，显示在电脑屏幕上
// 固定码  用户在设置里自己设（4~8 位数字），与随机码**并存**
// ```
// 两个码**都能进** —— 固定码是为了"用户不想每次看屏幕抄"。
//
// ⚠️ 但固定码**不应该进备份** —— 备份文件要传来传去，
//    里面的配对码等于把遥控入口一起送出去了。
//
// # ★★ 端口占用错误文案必须区分"谁占了"（原版实测踩过）
//
// 原先一律提示「可能被占用」—— 实测发现绝大多数情况下
// **占用者就是本应用自己**（关闭遥控时旧套接字没释放）。
// 让用户去"找谁占用了 8642"完全是误导，他会去查模拟器、
// 查别的软件，永远找不到。所以先问一句「我们自己是不是还在监听」。

use crate::state::AppState;

/// 插件目录
fn plugins_dir(data_dir: &std::path::Path) -> std::path::PathBuf {
    crate::state::plugins_dir(data_dir)
}

/// 插件**私有数据**目录（`plugins/.data/`）—— 插件的 `host.store` / `host.config`
/// 都落在这里的 `<插件id>.json`。
///
/// ★★★ 为什么必须单独有这个函数（2026-10-05 修的真 bug）
///
/// `plugin_config_set` / `plugin_config_get` 原来把 `&state.data_dir`
/// **直接**传给了 `config_write_many` / `resolved_config`，于是：
/// ```text
/// 设置页写的是   <dataDir>/emby.json                ← 错
/// 插件读的是     <dataDir>/plugins/.data/emby.json  ← 对（见 plugins/mod.rs
///                                                    load_plugins_hydrated
///                                                    里的 dir.join(".data")）
/// ```
/// 后果是**用户在设置页填的值，插件永远读不到** —— 而且两边都不报错：
/// 保存返回「已保存 N 项」，插件读到的是空字符串。
/// 这是 Emby 接入（task-35）实测撞出来的：只有手写
/// `plugins/.data/<id>.json` 插件才认。
///
/// ⚠️ 与 `plugins_dir` 的分工：`plugins_dir` 是**插件源码**（.js）的目录，
///    本函数是**插件数据**（.json）的目录，两者差一层 `.data`。
fn plugin_data_dir(data_dir: &std::path::Path) -> std::path::PathBuf {
    plugins_dir(data_dir).join(".data")
}

// ═══════════════════════════════════════════════════════════════════════
//  遥控偏好（落盘）
// ═══════════════════════════════════════════════════════════════════════

fn default_true() -> bool {
    true
}

fn default_remote_port() -> u16 {
    8642
}

/// 遥控偏好（存在数据目录的 `remote-pref.json`）
///
/// # 为什么固定码存在**文件**而不是钥匙串
///
/// 原版注释：
/// > 它本来就是要显示在电视屏幕上给用户抄的，不是秘密存储。
///
/// ⚠️ 但它**不应该进备份** —— 见模块头部的说明。
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct RemotePref {
    /// 开机是否自动开启遥控
    ///
    /// `#[serde(default = "default_true")]`：老版本升级上来的偏好文件里
    /// 没有这个字段时按 `true` 处理 —— 与「默认开启」的产品决定一致。
    #[serde(default = "default_true")]
    pub auto_start: bool,
    /// 上次使用的端口
    #[serde(default = "default_remote_port")]
    pub port: u16,
    /// 用户自设的固定配对码（没设时为 `None`）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fixed_pin: Option<String>,
}

impl Default for RemotePref {
    fn default() -> Self {
        Self {
            auto_start: true,
            port: default_remote_port(),
            fixed_pin: None,
        }
    }
}

fn remote_pref_file(dir: &std::path::Path) -> std::path::PathBuf {
    dir.join("remote-pref.json")
}

pub fn load_remote_pref(dir: &std::path::Path) -> RemotePref {
    std::fs::read_to_string(remote_pref_file(dir))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

pub fn save_remote_pref(dir: &std::path::Path, p: &RemotePref) -> Result<(), String> {
    let path = remote_pref_file(dir);
    let tmp = path.with_extension("json.tmp");
    let body = serde_json::to_string_pretty(p).map_err(|e| e.to_string())?;
    std::fs::write(&tmp, body).map_err(|e| format!("写入失败: {e}"))?;
    std::fs::rename(&tmp, &path).map_err(|e| format!("替换失败: {e}"))
}

// ═══════════════════════════════════════════════════════════════════════
//  遥控状态与启停
// ═══════════════════════════════════════════════════════════════════════

/// 组装遥控状态（UI 据此显示地址 / 二维码 / 配对码）
///
/// `reachable` 的判据是「局域网 IP 不是环回地址」——
/// 如果是 127.0.0.1，说明**没连上局域网**（比如网线没插），
/// 手机根本连不到这台机器。UI 应该提示这一点，
/// 而不是给用户一个抄了也没用的地址。
pub fn remote_status(hub: &crate::remote::RemoteHub) -> serde_json::Value {
    let ip = crate::remote::lan_ip();
    let reachable = !ip.is_loopback();
    serde_json::json!({
        "running": hub.is_running(),
        "url": crate::remote::remote_url(hub.port()),
        "port": hub.port(),
        "pin": hub.pin(),
        "fixedPin": hub.fixed_pin(),
        "lanIp": ip.to_string(),
        "reachable": reachable,
        "qrSvg": crate::remote::qr_svg(hub.port()),
    })
}

/// 真正把遥控服务跑起来（`remote_start` 与开机自启共用）
///
/// # 启动前先探测端口能否绑定
///
/// 直接 spawn 的话，绑定失败只会在后台任务里打条日志 ——
/// 用户看到「已开启」但手机连不上，非常难查。
/// 所以这里**同步试绑一次**，失败当场报错。
///
/// # ★★ 错误文案必须区分"谁占了端口"
///
/// 原先一律提示「可能被占用」—— 实测发现绝大多数情况下
/// **占用者就是本应用自己**（关闭遥控时旧套接字没释放）。
/// 让用户去"找谁占用了 8642"完全是误导，
/// 他会去查模拟器、查别的软件，永远找不到。
///
/// 所以先问一句「我们自己是不是还在监听」：
/// ```text
/// 是 → 明确告诉用户等几秒或重启，并说明原因
/// 否 → 才提示"可能被别的程序占用"
/// ```
pub async fn spawn_remote_server(
    hub: &std::sync::Arc<crate::remote::RemoteHub>,
    port: u16,
) -> Result<(), String> {
    if hub.is_running() {
        return Ok(());
    }

    let addr = crate::remote::bind_addr(port);
    let probe = tokio::net::TcpListener::bind(addr).await.map_err(|e| {
        /*
         * ★★ 按**错误类型**给不同文案（2026-09-24，用户报的症状）
         *
         * 用户原话：
         * > 「局域网遥控开了 开机自动,但是软件都打开了,也没见启动」
         *
         * 原因就是端口被占时**没有可读的原因**。这里把 `AddrInUse`
         * 单独拎出来，并明确告诉用户"自启被跳过"（而不是含糊的"失败"）——
         * 因为这两种情况用户要做的事完全不同：
         * ```text
         * AddrInUse  → 有别的程序占着，用户需要关掉它 / 换端口
         * 其它错误    → 通常是没网卡 / 权限问题，换端口也没用
         * ```
         */
        let is_in_use = e.kind() == std::io::ErrorKind::AddrInUse;
        if hub.is_running() {
            // 自己的旧套接字还没释放（实测过的真 bug）
            format!(
                "端口 {port} 仍被本应用的旧连接占用（遥控刚关闭，正在释放）。\
                 请稍等几秒后重试。原始错误：{e}"
            )
        } else if is_in_use {
            /*
             * ★ 这是最可能被用户碰到的情况，所以文案要说人话：
             *   · 说清"自启被跳过"（不是"程序坏了"）
             *   · 给出**具体**的两个可能（另一个实例 / 其它软件）
             *   · 给出**可操作的下一步**（换端口）
             *   · ⚠️ 不自动换端口 —— 遥控靠固定端口让手机连，
             *     悄悄换端口会让"手机连不上"变成更难查的问题
             */
            format!(
                "端口 {port} 已被占用，遥控自启被跳过 —— \
                 可能是另一个本应用实例正在运行，或该端口被其它程序占用。\
                 请在设置页换一个端口，或关掉占用它的程序。原始错误：{e}"
            )
        } else {
            format!(
                "端口 {port} 无法监听（不是端口占用，而是 {e}）—— \
                 请检查网络连接是否正常，或换一个端口试试。"
            )
        }
    })?;
    drop(probe);

    hub.set_port(port);
    hub.set_running(true);

    // 后台跑服务；退出时把 running 置回 false
    let h = hub.clone();
    tokio::spawn(async move {
        if let Err(e) = crate::remote::server::serve(h.clone(), port).await {
            log::error!("遥控服务结束: {e}");
        }
        h.set_running(false);
    });

    log::info!("遥控已开启: {}", crate::remote::remote_url(port));
    Ok(())
}

/// 开启遥控
///
/// # ★ 手动开启 = 用户希望它开着 → 记住「开机自启」
///
/// 这样用户不必再去别处找开关：开着的时候重启，它自己就回来了。
pub async fn remote_start(
    state: &AppState,
    port: Option<u16>,
) -> Result<serde_json::Value, String> {
    if state.remote.is_running() {
        return Ok(remote_status(&state.remote));
    }

    let port = port.unwrap_or_else(|| load_remote_pref(&state.data_dir).port);
    spawn_remote_server(&state.remote, port).await?;

    let mut pref = load_remote_pref(&state.data_dir);
    pref.auto_start = true;
    pref.port = port;
    if let Err(e) = save_remote_pref(&state.data_dir, &pref) {
        // 存不下不影响本次使用，只记日志
        log::warn!("保存遥控偏好失败: {e}");
    }

    Ok(remote_status(&state.remote))
}

/// 关闭遥控
///
/// # ★ 记住「不自动开启」
///
/// 这是默认开启之后**必须**有的一步：
/// 遥控默认开机自启，如果用户明确关掉了、下次开机又被拉起来，
/// 那是直接无视用户的意愿 —— 比「不默认开」更烦人。
///
/// # 超时要如实告诉用户
///
/// 原版注释：
/// > 超时了要**如实告诉用户**，而不是假装成功 ——
/// > 否则他下一次点「开启遥控」会撞 10048，又是一头雾水。
pub async fn remote_stop(state: &AppState) -> Result<serde_json::Value, String> {
    /*
     * 等端口释放，最多 3 秒。
     *
     * 正常情况 <50ms 就完成；给 3 秒是容忍"手机端有长连接
     * 正在传输"这种需要等 graceful shutdown 收尾的情况。
     */
    let stopped = state
        .remote
        .request_shutdown(std::time::Duration::from_secs(3))
        .await;

    let mut pref = load_remote_pref(&state.data_dir);
    pref.auto_start = false;
    if let Err(e) = save_remote_pref(&state.data_dir, &pref) {
        log::warn!("保存遥控偏好失败: {e}");
    }

    if stopped {
        log::info!("遥控已关闭，端口 {} 已释放", state.remote.port());
    } else {
        log::warn!(
            "遥控关闭超时（端口 {} 可能仍被占用）",
            state.remote.port()
        );
    }

    let mut st = remote_status(&state.remote);
    // 如实告知是否真的停了
    st["stopped"] = serde_json::json!(stopped);
    Ok(st)
}

/// 换一个随机配对码
pub fn remote_refresh_pin(state: &AppState) -> Result<serde_json::Value, String> {
    let p = state.remote.refresh_pin();
    log::info!("遥控配对码已更新为 {p}");
    Ok(remote_status(&state.remote))
}

/// 设置/清除固定配对码
///
/// # ★ 与随机码重合时必须拒绝
///
/// 原版注释：
/// > 与随机码重合时要拒绝：否则「换一个随机码」之后
/// > 用户会以为固定码还有效，实际两个码变成同一个了
///
/// # 格式校验在服务端做
///
/// 原版注释：
/// > 在服务端做，避免前端被绕过
///
/// 4~8 位数字 —— 校验逻辑在 `remote::validate_fixed_pin`。
pub fn remote_set_fixed_pin(
    state: &AppState,
    pin: &str,
) -> Result<serde_json::Value, String> {
    let raw = pin.trim();

    if raw.is_empty() {
        // 清除：只留随机码
        state.remote.set_fixed_pin(None);
        let mut pref = load_remote_pref(&state.data_dir);
        pref.fixed_pin = None;
        save_remote_pref(&state.data_dir, &pref)?;
        log::info!("已清除固定配对码（只剩随机码）");
        return Ok(remote_status(&state.remote));
    }

    // 校验格式（4~8 位数字）—— 在服务端做，避免前端被绕过
    let ok = crate::remote::validate_fixed_pin(raw)?;

    // ⚠️ 与随机码重合时要拒绝
    if ok == state.remote.pin() {
        return Err(
            "这个码和当前随机码相同，请换一个（否则「换一个」会把它也改掉）".into(),
        );
    }

    state.remote.set_fixed_pin(Some(ok.clone()));

    let mut pref = load_remote_pref(&state.data_dir);
    pref.fixed_pin = Some(ok.clone());
    save_remote_pref(&state.data_dir, &pref)?;

    log::info!("已设置固定配对码（随机码仍然有效）");
    Ok(remote_status(&state.remote))
}

/// 设置开机自启（只改偏好，不影响当前是否在跑）
pub fn remote_set_auto_start(state: &AppState, enabled: bool) -> Result<bool, String> {
    let mut pref = load_remote_pref(&state.data_dir);
    pref.auto_start = enabled;
    save_remote_pref(&state.data_dir, &pref)?;
    Ok(enabled)
}

/// 开机时读偏好（供宿主在启动阶段调用）
pub fn remote_auto_start(state: &AppState) -> Result<bool, String> {
    Ok(load_remote_pref(&state.data_dir).auto_start)
}

/// ★★ 查询**开机自启的结果**（2026-09-24 新增）
///
/// # 为什么需要这个命令
///
/// 用户原话：
/// > 「局域网遥控开了 开机自动,但是软件都打开了,也没见启动」
///
/// 自启是后台异步做的，失败时**用户看不到 stderr**，界面也不知道。
/// 这个命令让界面能问一句"自启到底成了没有、没成是为什么"：
/// ```text
/// { "attempted": true,  "ok": true,  "port": 8642 }
/// { "attempted": true,  "ok": false, "error": "端口 8642 已被占用，遥控自启被跳过 …" }
/// { "attempted": false }                     ← 用户关过 auto_start，没尝试
/// ```
/// ★ 界面拿到 `ok:false` 时可以直接把 `error` 显示给用户 ——
///   而不用让他自己去查"谁占了 8642"（我们这次是靠逐个进程枚举
///   模块才找到的，用户不可能做这件事）。
pub fn remote_autostart_status(state: &AppState) -> Result<serde_json::Value, String> {
    use serde_json::json;
    Ok(match state.remote.autostart() {
        Some(Ok(port)) => json!({ "attempted": true, "ok": true, "port": port }),
        Some(Err(e)) => json!({ "attempted": true, "ok": false, "error": e }),
        None => json!({ "attempted": false }),
    })
}

/// 上报本机播放状态给遥控服务（手机端据此显示"正在播什么"）
pub fn remote_report_state(
    state: &AppState,
    st: crate::remote::RemoteState,
) -> Result<(), String> {
    state.remote.update_state(st);
    Ok(())
}

/// 取待执行的遥控命令（宿主轮询这个）
pub fn remote_take_commands(
    state: &AppState,
) -> Result<Vec<crate::remote::RemoteCommand>, String> {
    Ok(state.remote.take_commands())
}

/// 上报搜索结果给遥控服务（手机端显示）
pub fn remote_set_search(
    state: &AppState,
    payload: crate::remote::SearchPayload,
) -> Result<(), String> {
    state.remote.set_search(payload);
    Ok(())
}

/// 上报首页数据给遥控服务（手机端显示）
pub fn remote_set_home(
    state: &AppState,
    payload: crate::remote::HomePayload,
) -> Result<(), String> {
    state.remote.set_home(payload);
    Ok(())
}

// ═══════════════════════════════════════════════════════════════════════
//  剩余命令
// ═══════════════════════════════════════════════════════════════════════

/// 手动触发追更检查
pub async fn check_updates(
    state: &AppState,
    max_items: Option<usize>,
) -> Result<Vec<crate::store::UpdateInfo>, String> {
    let engine = crate::follow::FollowEngine::new(state.registry.clone(), state.db.clone());
    engine.check_all(max_items.unwrap_or(50)).await
}

/// 全源健康检查（返回 id → 是否可用）
pub async fn health_sweep(
    state: &AppState,
) -> Result<std::collections::HashMap<String, bool>, String> {
    Ok(state.registry.health_sweep().await)
}

/// 添加收藏并更新元信息 —— ⚠️ **注意它其实不"切换"**
///
/// # ★★ 名字骗人：这不是 toggle
///
/// 原版逐行读下来的真实语义：
/// ```text
/// 库里没有 → 新建，favorited = true
/// 库里已有 → favorited **保持不变**（只复活 deleted、更新元信息）
/// ```
/// 也就是说：**已收藏的条目再调一次，还是收藏状态，不会取消。**
///
/// # 这就是它成为死代码的原因
///
/// 原版注释：
/// > 这是死代码（全项目无调用点）。保留改后的值只为与新语义一致 ——
/// > 万一将来有人翻到它，不该看到"收藏默认开追更"这种已经废弃的语义。
///
/// 一个"叫 toggle 但不 toggle"的命令没法用。真正做收藏/取消的是
/// `set_favorite(on: bool)` —— 那是修「取消收藏后又出现」那个 bug
///（原版 2026-09-19）时加的。
///
/// # 为什么仍然照抄这个"坏"语义
///
/// Owner 的硬性要求是「操作逻辑和原版**完全一致**」。
/// 不能因为"觉得它应该 toggle"就改行为 —— 那会让将来对照两版时
/// 出现无法解释的差异。（我第一版就是按名字猜的，测试立刻失败。）
pub async fn toggle_favorite(
    state: &AppState,
    provider: &str,
    id: &str,
    title: String,
    cover: Option<String>,
    kind: Option<String>,
    following: Option<bool>,
) -> Result<crate::store::Favorite, String> {
    let key = format!("{provider}:{id}");
    let now = chrono::Utc::now().timestamp_millis();

    let cover = cover.map(|c| state.stream_proxy.unproxy_cover_or_keep(&c));

    // 已存在 → 更新；不存在 → 新建
    let mut fav = state
        .db
        .get_favorite(&key)?
        .unwrap_or_else(|| crate::store::Favorite {
            key: key.clone(),
            provider: provider.to_string(),
            native_id: id.to_string(),
            title: title.clone(),
            cover: cover.clone(),
            group_name: None,
            kind: kind.clone().unwrap_or_else(|| "series".into()),
            // 新语义：收藏不自动开追更
            favorited: true,
            following: false,
            last_episode_count: 0,
            last_episode_title: None,
            unread_count: 0,
            last_checked_at: 0,
            last_update_at: 0,
            note: None,
            created_at: now,
            updated_at: now,
            deleted: false,
        });

    /*
     * ★★★ 这里**不翻转** `favorited` —— 与原版严格一致
     *
     * # 我第一版写错了（2026-09-22）
     *
     * 我按命令名 `toggle_favorite` 想当然地实现了"切换"：
     * ```rust
     * let was = fav.favorited;
     * fav.favorited = !was;      // ✗ 原版没有这两行
     * ```
     * 测试立刻失败（第 2 次调用应取消收藏，实际仍是 true）。
     *
     * 去逐行读原版才发现：**原版根本不切换**。
     * ```text
     * 不存在 → 新建，favorited = true
     * 已存在 → favorited 保持不变（只复活 deleted、更新元信息）
     * ```
     *
     * # 这恰恰解释了它为什么是死代码
     *
     * 原版注释说：
     * > 这是死代码（全项目无调用点）
     *
     * 原因就在这里：一个"叫 toggle 但不 toggle"的命令没法用。
     * 真正做收藏/取消的是 `set_favorite(on: bool)`（见其长注释，
     * 那是修「取消收藏后又出现」那个 bug 时加的）。
     *
     * # 为什么我还要照抄这个坏语义
     *
     * Owner 的硬性要求是「操作逻辑和原版**完全一致**」。
     * 我不能因为"觉得它应该 toggle"就改行为 ——
     * 那会让将来对照两版时出现无法解释的差异。
     * 正确做法：**照抄 + 注释说明它为什么是死的**。
     */
    // 已存在但之前被删除 → 复活
    if fav.deleted {
        fav.deleted = false;
    }
    // ⚠️ 原版是 `fav.title = title;`（无条件覆盖），照抄
    fav.title = title;
    fav.cover = cover.or(fav.cover);
    if let Some(k) = kind {
        fav.kind = k;
    }
    if let Some(f) = following {
        fav.following = f;
    }
    fav.updated_at = now;

    state.db.upsert_favorite(&fav)?;
    Ok(fav)
}

/// 安装插件（从 URL 下载）
///
/// # 三道校验（顺序不能换）
///
/// ```text
/// ① resolve_plugin_url  —— 解析各种"插件市场"的 URL 形态
/// ② parse_meta          —— 缺 @id / @name 就拒绝
/// ③ 先校验后写盘         —— 不合法的内容**不写盘**
///                          （免得留下一个坏文件，下次扫描时报错）
/// ```
/// 最后立即重载，让新插件马上可用。
pub async fn install_plugin(
    state: &AppState,
    url: &str,
) -> Result<serde_json::Value, String> {
    let resolved = crate::plugins::resolve_plugin_url(url)?;
    let (source, used_url) =
        crate::plugins::fetch_plugin_source(Some(&state.proxy), &resolved).await?;

    // 先解析元信息校验 —— 不合法的内容不写盘（免得留下一个坏文件）
    let meta = crate::plugins::parse_meta(&source);
    if meta.id.is_empty() {
        return Err("下载到的内容不是合法插件（缺少 @id 头部注释）".into());
    }
    if meta.name.is_empty() {
        return Err(format!("插件 {} 缺少 @name", meta.id));
    }

    let dir = plugins_dir(&state.data_dir);
    let (file, bytes) = crate::plugins::save_plugin(&dir, &meta.id, &source)?;

    /*
     * ★★ 记住安装来源（task-23）—— 这是「通过链接检测更新」的**唯一前提**
     *
     * 实测缺口：本函数一直**返回** `resolvedUrl`（见下面 json），
     * 但**从不落盘** → 装完之后就再也找不到"去哪查新版"，
     * 于是「检测更新」根本无从下手（没有源可查）。
     *
     * 存在 sidecar（`plugins/.meta/<id>.json`）而**不改插件本体** ——
     * 理由见 `PluginSourceMeta` 的文档（.js 是用户/作者的地盘）。
     *
     * ⚠️ 存 `used_url`（最终解析地址）而不是用户输入的 `url`：
     *    原始链接可能是"插件市场页"，真正能 GET 到 JS 的是解析后的地址；
     *    检测更新时直接 GET 它，不用再解析一次（也避免解析规则变化）。
     *
     * ⚠️ 写失败**不影响安装本身**（插件已经装好了）→ 只记日志。
     *    代价是那个插件以后"查不了更新"，但绝不因此让安装报错。
     */
    let src_meta = crate::plugins::PluginSourceMeta {
        source_url: Some(used_url.clone()),
        installed_version: meta.version.clone(),
        installed_at: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0),
        file: file.clone(),
    };
    if let Err(e) = crate::plugins::write_plugin_meta(&dir, &meta.id, &src_meta) {
        log::warn!("记录插件安装来源失败（不影响安装）: {e}");
    }

    // 立即重载，让新插件马上可用
    let n = crate::commands_provider::reload_plugins(state).await?;

    log::info!("已安装插件 {}（{file}, {bytes} 字节），当前共 {n} 个", meta.id);

    Ok(serde_json::json!({
        "id": meta.id,
        "name": meta.name,
        "version": meta.version,
        "file": file,
        "resolvedUrl": used_url,
        "bytes": bytes,
    }))
}

/// 安装插件（从本地内容）
///
/// 与 `install_plugin` 同一套校验 —— 只是来源是字符串而不是 URL。
pub async fn install_plugin_source(
    state: &AppState,
    source: &str,
    name_hint: Option<String>,
) -> Result<serde_json::Value, String> {
    if source.trim().is_empty() {
        return Err("插件内容为空".into());
    }

    let meta = crate::plugins::parse_meta(source);
    if meta.id.is_empty() {
        return Err("这不是合法插件（缺少 @id 头部注释）".into());
    }
    if meta.name.is_empty() {
        return Err(format!("插件 {} 缺少 @name", meta.id));
    }

    let dir = plugins_dir(&state.data_dir);
    let (file, bytes) = crate::plugins::save_plugin(&dir, &meta.id, source)?;
    let n = crate::commands_provider::reload_plugins(state).await?;

    log::info!(
        "已安装插件 {}（{file}, {bytes} 字节，来源: {}），当前共 {n} 个",
        meta.id,
        name_hint.as_deref().unwrap_or("本地文件"),
    );

    Ok(serde_json::json!({
        "id": meta.id,
        "name": meta.name,
        "version": meta.version,
        "file": file,
        "resolvedUrl": null,
        "bytes": bytes,
    }))
}

/// 导入声明式源（JSON 配置）
///
/// # ★ 必须记住来源，否则用户每次开机都要重装
///
/// 光 `registry.register()` 只影响内存 —— 重启后新源就没了。
/// 所以同时写进 `third_party` 清单并落盘。
///
/// 同 id 覆盖：支持用户改了 JSON 再导入。
pub async fn import_declarative_provider(
    state: &AppState,
    json: &str,
) -> Result<crate::model::ProviderManifest, String> {
    let p = crate::providers::DeclarativeProvider::from_json(json)
        .map_err(|e| format!("{:?}: {}", e.kind, e.message))?;
    let manifest = crate::provider::MediaProvider::manifest(&p).clone();
    state.registry.register(std::sync::Arc::new(p));

    // ★ 记住来源，重启后自动重建（否则用户每次开机都要重装）
    {
        let mut list = state
            .third_party
            .write()
            .map_err(|_| "第三方源列表被污染".to_string())?;
        // 同 id 覆盖：支持用户改了 JSON 再导入
        list.retain(|x| x.id() != manifest.id);
        list.push(crate::model::PersistedProvider::Declarative {
            id: manifest.id.clone(),
            json: json.to_string(),
        });
    }
    crate::commands_provider::persist_from_registry(state)?;
    // 标记改动时间：云同步据此判断「本地是新的」
    crate::commands_provider::touch_providers(state);

    Ok(manifest)
}

/// 安装 HTTP 源（连上去读契约，自动生成 manifest）
///
/// # 为什么要连一次
///
/// HTTP 源的 manifest 由**服务端契约**决定（`/api/manifest` 之类），
/// 所以必须先连上才能知道它叫什么、支持哪些能力。
///
/// # 去重比声明式源多一条
///
/// ```text
/// 除了「同 id 覆盖」还要「同 base_url 覆盖」
/// ```
/// 因为用户在界面上填的是 URL，改一次地址可能 id 也变了 ——
/// 只按 id 去重会留下两条指向同一服务器的记录。
pub async fn install_http_provider(
    state: &AppState,
    base_url: String,
    headers: Option<std::collections::HashMap<String, String>>,
) -> Result<crate::model::ProviderManifest, String> {
    let headers = headers.unwrap_or_default();
    let p = crate::providers::HttpProvider::connect(
        crate::providers::http::HttpProviderSpec {
            base: base_url.clone(),
            headers: headers.clone(),
        },
    )
    .await
    .map_err(|e| format!("{:?}: {}", e.kind, e.message))?;

    let manifest = crate::provider::MediaProvider::manifest(&p).clone();
    let proxy = state.proxy.clone();
    /*
     * ⚠️ `with_proxy` 是 **HttpProvider 的固有方法**（`p.with_proxy(proxy)`），
     *    **不是** `MediaProvider` trait 的方法。
     *
     * 我第一版写成 `MediaProvider::with_proxy(&p, proxy)` —— 编译报
     * `E0782: expected a type, found a trait`（trait 不能当类型用）。
     * 照抄原版的 `p.with_proxy(proxy)` 即可。
     */
    state
        .registry
        .register(std::sync::Arc::new(p.with_proxy(proxy)));

    // ★ 记住来源（含 id），重启后自动重连
    {
        let mut list = state
            .third_party
            .write()
            .map_err(|_| "第三方源列表被污染".to_string())?;
        list.retain(|x| {
            x.id() != manifest.id
                && !matches!(x, crate::model::PersistedProvider::Http { base_url: b, .. } if b == &base_url)
        });
        list.push(crate::model::PersistedProvider::Http {
            id: manifest.id.clone(),
            base_url: base_url.clone(),
            headers,
        });
    }
    crate::commands_provider::persist_from_registry(state)?;
    crate::commands_provider::touch_providers(state);

    log::info!(
        "已安装 HTTP Provider「{}」（契约 v{}）",
        manifest.name,
        manifest.api_version
    );
    Ok(manifest)
}

/// 写入插件配置项的值
///
/// # 两道前置检查（都在服务端做）
///
/// ```text
/// ① 源必须存在        否则报"没有找到源 {id}"
/// ② 必须有可配置项    否则报"源 {id} 没有可配置项"
/// ```
/// ② 这条很重要：如果源没声明任何配置，静默接受会让用户以为
/// 配置保存了，实际什么都没发生。
pub fn plugin_config_set(
    state: &AppState,
    id: &str,
    values: serde_json::Map<String, serde_json::Value>,
) -> Result<usize, String> {
    let m = state
        .registry
        .manifests()
        .into_iter()
        .find(|m| m.id == id)
        .ok_or_else(|| format!("没有找到源 {id}"))?;

    if m.config.is_empty() {
        return Err(format!("源 {id} 没有可配置项"));
    }

    // ★ 插件配置落盘在 plugins/.data/（与插件的 host.config 读同一处）
    crate::plugins::config_write_many(&plugin_data_dir(&state.data_dir), &m.config, id, &values)
}

/// 读插件配置项（声明 + 当前值）
///
/// # 返回两个东西，而不是只返回值
///
/// ```text
/// fields  → 插件声明的配置项（设置页据此**渲染表单**）
/// values  → 每项的当前值（可能来自用户设置，也可能是默认值）
/// ```
/// 为什么要一起返回：**设置页在打开的那一刻就需要两者**。
/// 分两次命令会有一个中间态（声明到了、值还没到），
/// 表现为表单先画出来再"跳"一下。
///
/// # `resolved_config` 做了什么
///
/// 它把「用户设过的值」与「声明里的默认值」合并 ——
/// 用户没设过的项用默认值。所以调用方拿到的一定是**完整**的一组值，
/// 不用自己判断哪项缺失。
pub fn plugin_config_get(
    state: &AppState,
    id: &str,
) -> Result<serde_json::Value, String> {
    let m = state
        .registry
        .manifests()
        .into_iter()
        .find(|m| m.id == id)
        .ok_or_else(|| format!("没有找到源 {id}"))?;

    // ★ 与 plugin_config_set 同一处：plugins/.data/
    let values = crate::plugins::resolved_config(&plugin_data_dir(&state.data_dir), &m.config, id);

    Ok(serde_json::json!({
        "fields": m.config,
        "values": values,
    }))
}

/// 读遥控状态（不改任何东西）
///
/// 与 `remote_start` 的区别：后者会**启动服务并改偏好**，
/// 这个只是读当前状态。UI 轮询用这个（不会有意外的副作用）。
pub fn remote_status_cmd(state: &AppState) -> Result<serde_json::Value, String> {
    Ok(remote_status(&state.remote))
}
