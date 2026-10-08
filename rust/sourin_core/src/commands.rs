// ═══════════════════════════════════════════════════════════════════════
//  命令实现 —— 从 Tauri lib.rs 搬过来的（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 搬运规则（机械但必须一致）
//
// ```text
// 原版：async fn xxx(state: tauri::State<'_, AppState>, a: T, b: U) -> Result<R, String>
// 这里：pub async fn xxx(state: &AppState, a: T, b: U) -> Result<R, String>
// ```
// 只改签名，**函数体一行不动** —— 这样行为才和原版完全一致
//（Owner 的要求：操作逻辑保持一样）。
//
// # 与 FFI 层的分工
//
// ```text
// 本文件        → 纯 Rust，参数是 Rust 类型，返回 Result<T, String>
// ffi.rs        → 负责 JSON ↔ Rust 类型的转换与分发
// ```
// 分开的好处：本文件可以被单元测试直接调用（不需要造 JSON），
// 而 FFI 层只做薄薄一层适配。
//
// # 已搬 / 待搬
//
// 90 个命令不可能一轮搬完。这里按「先只读、后写入」的顺序搬：
// ```text
// 只读类（无副作用，最好验证）  ← 先搬这些
// 写入类（改数据，要小心）
// 网络类（异步、要真发请求）
// ```
// 每搬一个就在 `ffi.rs` 的 dispatch 里挂上，**边搬边验证**。

use crate::state::AppState;

// ═══════════════════════════════════════════════════════════════════════
//  源的启停与顺序（持久化文件）
// ═══════════════════════════════════════════════════════════════════════
//
// 原版 lib.rs:185-260。这几个 helper 是 list_providers /
// set_provider_enabled / set_provider_order 的共同依赖。

fn disabled_file(dir: &std::path::Path) -> std::path::PathBuf {
    dir.join("disabled-providers.json")
}

fn order_file(dir: &std::path::Path) -> std::path::PathBuf {
    dir.join("provider-order.json")
}

/// 读取「已停用」的源 id 列表
///
/// 文件不存在或损坏 → 空列表（即「全部启用」）——
/// 这是安全的默认值：宁可多显示一个源，也不要让用户以为源丢了。
pub fn load_disabled(dir: &std::path::Path) -> Vec<String> {
    std::fs::read_to_string(disabled_file(dir))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

/// 保存「已停用」列表（原子写）
pub fn save_disabled(dir: &std::path::Path, list: &[String]) -> Result<(), String> {
    let p = disabled_file(dir);
    let tmp = p.with_extension("json.tmp");
    let body = serde_json::to_string_pretty(list).map_err(|e| e.to_string())?;
    std::fs::write(&tmp, body).map_err(|e| format!("写入失败: {e}"))?;
    std::fs::rename(&tmp, &p).map_err(|e| format!("替换失败: {e}"))
}

/// 读取用户保存的源顺序
pub fn load_order(dir: &std::path::Path) -> Vec<String> {
    std::fs::read_to_string(order_file(dir))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

/// 保存源顺序（原子写）
pub fn save_order(dir: &std::path::Path, list: &[String]) -> Result<(), String> {
    let p = order_file(dir);
    let tmp = p.with_extension("json.tmp");
    let body = serde_json::to_string_pretty(list).map_err(|e| e.to_string())?;
    std::fs::write(&tmp, body).map_err(|e| format!("写入失败: {e}"))?;
    std::fs::rename(&tmp, &p).map_err(|e| format!("替换失败: {e}"))
}

// ═══════════════════════════════════════════════════════════════════════
//  命令实现
// ═══════════════════════════════════════════════════════════════════════

/// 列出所有内容源（含启用状态）
///
/// 源：原版 `lib.rs` 的 `list_providers`
///
/// # ★ 为什么「是否启用」从**文件**读而不是从 registry 读
///
/// ```text
/// 两种做法：
///   a) 从 disabled-providers.json 读（持久化的真相）
///   b）从 registry 的 handle 读（运行时的真相）
/// ```
/// 选 (a)：它同时覆盖「刚改还没落盘」与「重启后恢复」两种情况，
/// 且不会因为某个源没注册上而漏掉。
pub fn list_providers(state: &AppState) -> Result<Vec<crate::model::ProviderManifest>, String> {
    let disabled = load_disabled(&state.data_dir);
    let mut list = state.registry.manifests();
    for m in &mut list {
        m.enabled = Some(!disabled.iter().any(|x| x == &m.id));
    }
    Ok(list)
}

/// 读取某个源是否启用
pub fn get_provider_enabled(state: &AppState, id: &str) -> Result<bool, String> {
    let disabled = load_disabled(&state.data_dir);
    Ok(!disabled.iter().any(|x| x == id))
}

/// 读取当前源顺序（未设置过时返回注册顺序）
pub fn get_provider_order(state: &AppState) -> Result<Vec<String>, String> {
    let saved = load_order(&state.data_dir);
    if saved.is_empty() {
        // 没设过 → 用注册顺序
        return Ok(state.registry.manifests().into_iter().map(|m| m.id).collect());
    }
    /*
     * ★★★ 必须与**实际注册的源**对齐后再返回
     *     （2026-09-23 发现并修正的移植错误）
     *
     * # 我第一版漏了什么
     *
     * 我直接 `Ok(saved)` 把文件里的原始列表返回了。但那个文件是**历史**
     * —— 里面可能有：
     * ```text
     * · 已经被删掉的源（卸载了插件）
     * · 刚装的新源（还没进这个文件）
     * ```
     *
     * 实测踩到的表现（真数据）：
     * ```text
     * provider-order.json 里有 27 条
     * 但实际只有 26 个源
     * → 设置页的排序面板会显示 27 行，其中一行是**不存在的源**
     * → 用户点「保存」后，那行幽灵项被清掉，顺序「莫名其妙」变了
     * ```
     *
     * 原版用 `registry.reorder()` 做对齐 —— 它是个**稳定排序**：
     * 不在 ids 里的项保持原有相对顺序自动落到末尾。
     */
    Ok(state.registry.reorder(&saved))
}

/// 是否已启动
pub fn is_started() -> bool {
    super::ffi::state().is_some()
}

// ═══════════════════════════════════════════════════════════════════════
//  批次 1 · 只读命令（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么先搬只读命令
//
// ```text
// 只读 → 无副作用 → 可以直接对**真实用户库**验证（只读安全）
// 写入 → 有副作用 → 必须用独立数据目录
// ```
// 先做只读的，能在不碰用户数据的前提下确认「搬运是否正确」。
//
// # 搬运规则（与原版严格一致）
//
// 原版（`src-tauri/src/lib.rs`）：
// ```rust
// #[tauri::command]
// async fn get_progress(state: State<AppState>, provider: String, id: String)
//     -> Result<Option<Progress>, String> {
//     state.db.get_progress(&format!("{provider}:{id}"))
// }
// ```
// 这里改成 `(state: &AppState, ...)`，**函数体一行不改** ——
// 行为才和原版完全一致（Owner 要求「操作逻辑保持一样」）。
//
// # ★ 复合键的格式必须一致
//
// ```text
// "{provider}:{id}"
// ```
// 原版所有按作品索引的表（progress / skip_marker / favorite /
// following）都用这个格式。**格式错了会静默查不到**（不报错、
// 只是返回 None），所以每个命令都要照抄这段 format，不能自己发挥。

/// progress 表的主键格式（原版全项目统一）
///
/// 单独抽出来是为了**只在一处定义** —— 这是契约，
/// 分散写两次就可能不一致，而后果是静默查不到。
fn item_key(provider: &str, id: &str) -> String {
    format!("{provider}:{id}")
}

/// 读播放进度
pub fn get_progress(
    state: &AppState,
    provider: &str,
    id: &str,
) -> Result<Option<crate::store::Progress>, String> {
    state.db.get_progress(&item_key(provider, id))
}

/// 继续观看列表
pub fn continue_watching(
    state: &AppState,
    limit: Option<u32>,
) -> Result<Vec<crate::store::Progress>, String> {
    state.db.continue_watching(limit.unwrap_or(20))
}

/// 全部进度（同步用）
pub fn list_all_progress(
    state: &AppState,
) -> Result<Vec<crate::store::Progress>, String> {
    state.db.list_all_progress()
}

/// 观看历史
pub fn list_history(
    state: &AppState,
    limit: Option<u32>,
) -> Result<Vec<crate::store::HistoryEntry>, String> {
    state.db.list_history(limit.unwrap_or(100))
}

/// 读片头/片尾跳过点
pub fn get_skip_marker(
    state: &AppState,
    provider: &str,
    id: &str,
) -> Result<Option<crate::store::SkipMarker>, String> {
    state.db.get_skip_marker(&item_key(provider, id))
}

/// 列出全部跳过点（同步用；设置页做统计也用）
pub fn list_skip_markers(
    state: &AppState,
) -> Result<Vec<crate::store::SkipMarker>, String> {
    state.db.list_skip_markers()
}

/// 收藏列表
/// 收藏列表
///
/// ⚠️ `list_favorites(include_deleted)` 的布尔参数是**墓碑开关**：
/// ```text
/// false → 只返回有效的（UI 用这个）
/// true  → 连已删除的墓碑一起返回（同步用，否则删除同步不出去）
/// ```
/// 原版命令层传的是什么要看调用点 —— 这里保留为参数，
/// 默认 false（UI 语义）。
pub async fn list_favorites(
    state: &AppState,
    following_only: bool,
) -> Result<Vec<crate::store::Favorite>, String> {
    /*
     * ★★★ 参数是 `following_only`，**不是** `include_deleted`
     *     （2026-09-23 发现并修正的移植错误）
     *
     * # 我第一版写错了
     *
     * 我把它当成 `list_favorites(include_deleted)` 直接透传给
     * 数据库层。但原版这个命令的参数语义完全不同 ——
     * 它是一个**二选一的分派**：
     * ```text
     * following_only = true  → list_following_for_ui()  追更列表（UI 排序）
     * following_only = false → list_favorites(false)    收藏列表
     * ```
     *
     * # 为什么这个错误很隐蔽
     *
     * 两个参数都是 `bool`，**编译期完全看不出来**。
     * 而传错的表现是：
     * ```text
     * 追更页调 list_favorites(true)
     *   → 我这边返回"全部行（含墓碑）"
     *   → 追更页会显示一堆已删除的内容 ★
     * ```
     * 只有真跑界面才能发现。
     *
     * # 为什么用 `list_following_for_ui` 而不是 `list_following`
     *
     * 原版注释：
     * > 用**界面排序**的那个查询（按最近有更新排前面）
     * > ⚠️ 不要用 `list_following()` —— 那是**巡检队列**的顺序
     * >    （最久没查的优先），给用户看会显得毫无规律。
     * >    两者在 2026-09-20 拆分，各有各的语义。
     */
    let mut list = if following_only {
        state.db.list_following_for_ui()?
    } else {
        state.db.list_favorites(false)?
    };

    /*
     * ★★★ 读出来时**重新包一层封面代理**
     *     （真 bug 的另一半，原版 2026-09-20 实测发现）
     *
     * # 为什么需要（我第一版漏了这段）
     *
     * 库里存的是**原始 URL**（`set_favorite` 里刻意 unproxy 过 ——
     * 临时代理地址不能落库，端口每次启动都变）。但展示时如果直接用原始 URL：
     * ```text
     * B站封面 https://i1.hdslb.com/...  + 页面 Referer = tauri.localhost
     *   → HTTP 403（实测确认，CDN 有防盗链）
     * ```
     * 所以必须在这里重新登记一次代理，前端拿到的才是能加载的地址。
     *
     * 这也正是「**详情页正常、收藏列表裂开**」的另一半原因：
     * 详情页每次都走 `proxy_cover_one`，而这里原先什么都没做。
     *
     * ⚠️ 每个源用它自己的 `cover_headers` —— 不同 CDN 要的头不一样
     *    （B站要 Referer，其他源可能不要）。
     *    没有声明 `coverHeaders` 的源跳过（直连本来就能加载）。
     *
     * ⚠️ 代理启动失败时**保持原 URL 不变** ——
     *    让用户看到"图挂了"，而不是整个列表报错。
     */
    for fav in list.iter_mut() {
        let Some(c) = fav.cover.clone() else { continue };

        /*
         * ★★★ 自愈：清掉历史遗留的**失效代理地址**
         *     （一次性数据修复，原版 2026-09-20）
         *
         * 修好"临时地址不落库"之后，**之前已经写进库里的那些死地址**还在
         *（实测用户库里就有 `http://127.0.0.1:51604/s/18d6c...`）。
         * 那些 token 在重启后已经不存在了，代理层也还原不出原始 URL
         *（内存表是空的）—— 所以只能**置空**。
         *
         * 置空后前端会显示首字占位（不显示破图），
         * 用户重新收藏一次就会写入正确的原始 URL。
         *
         * ⚠️ 为什么不尝试"猜"原始 URL：做不到。
         *    token 是随机串，映射表在内存里、重启即失。
         *    诚实置空 > 留一个永远裂开的地址。
         *
         * ⚠️ 只在**还原不出来**时置空 —— 如果代理还活着（同一次运行内），
         *    `unproxy_cover` 会正常还原，不该误伤。
         */
        if c.starts_with("http://127.0.0.1:") {
            match state.stream_proxy.unproxy_cover(&c) {
                // 还活着 → 还原成原始地址（正常路径）
                Some(raw) => fav.cover = Some(raw),
                // 已失效 → 置空，让界面显示占位而不是破图
                None => {
                    log::debug!("收藏封面是一个已失效的代理地址，已清空（等用户重新收藏）");
                    fav.cover = None;
                }
            }
            continue;
        }

        let Some(m) = state
            .registry
            .manifests()
            .into_iter()
            .find(|m| m.id == fav.provider)
        else {
            continue;
        };
        if m.cover_headers.is_empty() {
            continue;
        }
        if let Err(e) = state.stream_proxy.ensure_started().await {
            log::warn!("封面代理启动失败，收藏封面将直连（很可能 403）: {e}");
            break;
        }
        fav.cover = Some(
            state
                .stream_proxy
                .register_cover(&c, m.cover_headers.clone()),
        );
    }

    Ok(list)
}

/// 追更列表（UI 形态，带未读）
pub fn list_following_for_ui(
    state: &AppState,
) -> Result<Vec<crate::store::Favorite>, String> {
    state.db.list_following_for_ui()
}

/// 未读总数（底栏徽章用）
pub fn total_unread(state: &AppState) -> Result<u32, String> {
    state.db.total_unread()
}

/// 平台历史镜像列表
/// 平台历史镜像（原始 JSON —— 这是「备份平面」，结构由各平台决定）
pub fn list_platform_history(
    state: &AppState,
    limit: u32,
) -> Result<Vec<serde_json::Value>, String> {
    state.db.list_platform_history(limit)
}

// ═══════════════════════════════════════════════════════════════════════
//  批次 3 · 搜索（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 搜索结果也要代取封面
//
// 原版注释：
// > 与详情页同理 —— 这是**第三个（也是最后一个）**会出现封面的出口。
// > 三处都覆盖到才算完整：`get_list` / `get_rank` / `get_detail` / `search_all`
//
// 漏掉这里的后果是「搜索页的 B 站结果全是裂图」，而列表页正常 ——
// 那种"只有某个页面裂"的表现很难联想到代理，值得记住这条注释。

/// 跨源搜索（等全部源返回后一次性给结果）
///
/// # 与原版一致的行为
///
/// ```text
/// ① 并发/串行由 `registry.search_all` 决定（已搬）
/// ② 结果里每个源的封面都走 proxy_covers
/// ③ `skipped` 字段列出**被跳过的源及原因** ——
///    UI 据此明确告知用户「哪些源没搜到」，而不是静默失败
/// ```
pub async fn search_all(
    state: &AppState,
    keyword: &str,
    page: u32,
) -> Result<crate::registry::SearchAllResult, String> {
    let mut r = state.registry.search_all(keyword, page).await;

    /*
     * ★ 搜索结果的封面也要代取
     *
     * 与详情页同理 —— 这是第三个（也是最后一个）会出现封面的出口。
     * 三处都覆盖到才算完整：get_list / get_rank / get_detail / search_all。
     */
    for (pid, _pname, pg) in r.results.iter_mut() {
        crate::home::proxy_covers(state, pid, &mut pg.items).await;
    }

    Ok(r)
}

/// 流式搜索的一帧（对应原版 `SearchStreamEvent`）
///
/// # 为什么传「整个 Page」而不是拆开的字段
///
/// 原版注释：
/// > channel 里传「整个 Page」而不是拆开的字段 ——
/// > 这样 `items` / `page_count` / `total` 不会各自漂移。
///
/// 这是个好设计：如果事件里逐个字段传，将来 Page 加字段时
/// 事件定义要跟着改，而**忘了改不会报错**（只是新字段丢失）。
#[derive(Debug, Clone, serde::Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SearchStreamEvent {
    /// 该源搜到了内容
    Hit {
        provider: String,
        provider_name: String,
        items: Vec<crate::model::MediaItem>,
        page: u32,
        /*
         * ⚠️ 这两个是 `Option` + `skip_serializing_if`
         *
         * 我第一版写成了裸 `u32` / `u64`，编译直接报
         * `expected u32, found Option<u32>` —— 这是好事，
         * 类型系统挡住了我"想当然"。
         *
         * 为什么原版是 Option：**很多源不返回总数**（尤其第三方接口），
         * 这时 UI 应该不显示「共 N 条」而不是显示「共 0 条」。
         * `skip_serializing_if` 让字段在 None 时**整个不出现在 JSON 里**，
         * Dart 侧 `json['page_count']` 得 null —— 语义清晰。
         */
        #[serde(skip_serializing_if = "Option::is_none")]
        page_count: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        total: Option<u64>,
    },
    /// 该源失败 / 无结果 / 已失效
    Miss { provider: String, reason: String },
}

/// 流式搜索 —— 每完成一个源就回调一次
///
/// # 为什么需要流式版
///
/// `search_all` 要等**所有**源返回才给结果。而源有几十个，
/// 最慢的那个决定整体等待时间（实测有的源要 10 秒以上）。
/// 流式版让用户**边搜边看**，体验差别很大。
///
/// # 回调返回 false = 用户关掉了搜索页
///
/// 原版注释：
/// > send 失败 = 前端不听了 → 返回 false 提前停止
///
/// 这个提前停止很重要：用户已经离开搜索页了，
/// 还在后台跑几十个网络请求是纯浪费（而且可能触发站点的频率限制）。
///
/// # ★ 为什么中间要一个 channel（照抄原版结构）
///
/// 两个约束在打架：
/// ```text
/// ① registry.search_all_stream 的回调是**同步**的（FnMut）
/// ② 取封面 proxy_covers 是**异步**的（要 await 网络/启动代理）
/// ```
/// 同步回调里不能 await，所以必须把「搜索」与「取封面」拆成两条
/// 并发的任务，中间用一个 channel 连起来 —— 这正是原版的做法：
/// ```text
/// 生产者：跑搜索，每完成一个源就 tx.send
/// 消费者：rx.recv → await 取封面 → 回调给前端
/// tokio::join! 让两者并发（取封面不阻塞后面的源开始搜索）
/// ```
/// 我第一版试图让回调直接发事件（不取封面），并把这个差异写进注释 ——
/// 但那是**功能缺失**（搜索页的 B 站封面会全裂），不是可以接受的近似。
/// 所以按原版结构重做。
/// # ★★ 为什么生产者必须 `tokio::spawn`（2026-09-22 实测踩到死锁）
///
/// 我第一版照抄原版结构写了 `tokio::join!(search_fut, drain_fut)`，
/// 结果**挂死**。实测证据：
/// ```text
/// 取消测试: 收到 2 事件，耗时 29.7s
///   → 若真并发，2 个事件应在 ~2s 内到、然后立刻取消
///   → 实际 29.7s ≈ 整个搜索耗时
///   ★ drain_fut 被**饿死**，事件全堆在 channel 里
///
/// 完整流式: 超时挂死
/// ```
///
/// **根因**：`tokio::join!` 把两个 future 跑在**同一个任务**上，
/// 只是交替 poll —— 不是真并发。于是：
/// ```text
/// ① search_fut 长时间在 await 网络 → drain_fut 很少被 poll
/// ② search_fut 跑完后，它持有的 `tx`（被 move 进闭包）
///    仍未释放（future 还没被 drop，因为 join! 要等两边都完成）
/// ③ drain_fut 的 `rx.recv()` 于是永远 Pending → 死锁
/// ```
///
/// **修法**：`tokio::spawn` 让生产者成为**独立任务**：
/// ```text
/// · 真正并发 → 事件即时送达（这才是流式的意义）
/// · 生产者任务结束时其 future 被 drop → tx 释放
///   → rx.recv() 返回 None → drain 正常结束
/// ```
///
/// ⚠️ 注意：**不能照抄原版的 `join!`**。原版能工作是因为
///    Tauri 的 `Channel` 由框架持有，`tx` 的生命周期与 future 无关；
///    而这里的 `tx` 是被闭包捕获的，生命周期就绑在 future 上。
///    这是「结构相同但语义不同」的典型陷阱。
pub async fn search_all_stream<F>(
    state: &AppState,
    keyword: &str,
    page: u32,
    mut on_event: F,
) -> Result<(), String>
where
    F: FnMut(SearchStreamEvent) -> bool,
{
    /*
     * channel 里传「整个 Page」而不是拆开的字段 ——
     * 这样 `items` / `page_count` / `total` 不会各自漂移。
     * 没结果的源用 `None`。
     */
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<(
        String,
        String,
        Option<crate::model::Page<crate::model::MediaItem>>,
    )>();

    /*
     * ★ 生产者：**spawn 成独立任务**（不是 join!）—— 见上面的说明。
     *
     * `Registry` 是 `Arc<Registry>`（`AppState.registry`），
     * 内部用 `RwLock`，可以跨任务共享。
     */
    let registry = state.registry.clone();
    let keyword_owned = keyword.to_string();
    let producer = tokio::spawn(async move {
        registry
            .search_all_stream(&keyword_owned, page, |outcome| {
                let msg = match outcome {
                    Ok((pid, pname, pg)) => (pid, pname, Some(pg)),
                    Err((pid, reason)) => (pid, reason, None),
                };
                // send 失败 = 消费者不听了（已 break）→ 提前停止
                tx.send(msg).is_ok()
            })
            .await;
    });

    /*
     * 消费者循环：从 channel 取结果 → 代取封面 → 推给前端。
     *
     * `rx.recv()` 返回 None 有两种情况：
     * ```text
     * ① 生产者正常跑完 → tx 被 drop → None（正常结束）
     * ② 生产者任务被 abort → tx 被 drop → None
     * ```
     */
    let mut cancelled = false;
    while let Some((pid, pname, pg)) = rx.recv().await {
        let ev = match pg {
            Some(pg) => {
                let mut items = pg.items;
                /*
                 * ★ 搜索结果的封面也要代取
                 *
                 * 与详情页同理 —— 这是第三个（也是最后一个）
                 * 会出现封面的出口。三处都覆盖到才算完整：
                 * get_list / get_rank / get_detail / search_all(+本流式版)
                 */
                crate::home::proxy_covers(state, &pid, &mut items).await;
                SearchStreamEvent::Hit {
                    provider: pid,
                    provider_name: pname,
                    items,
                    page: pg.page,
                    page_count: pg.page_count,
                    total: pg.total,
                }
            }
            None => SearchStreamEvent::Miss {
                provider: pid,
                reason: pname,
            },
        };

        if !on_event(ev) {
            cancelled = true;
            break;
        }
    }

    /*
     * ★★ 取消时必须 **abort** 生产者，而不是 await 它
     *（2026-09-22 实测踩到：取消后仍等了 32 秒）
     *
     * # 为什么 `await` 不行
     *
     * 实测数据：
     * ```text
     * 取消测试: 收到 2 事件，耗时 32.82s
     * ```
     * 收到 2 个事件后 `break` 了，但整个函数**仍要等 30 秒**才返回。
     *
     * 原因有两层：
     * ```text
     * ① 我 break 后写了 `producer.await` —— 那会**等生产者跑完**
     *    剩下的源（每个 1-20 秒）→ 直接拖 30 秒
     *
     * ② 即便去掉 await，生产者也不会立刻停：
     *    `tx.send` 失败才能让 search_all_stream 提前 return，
     *    而**当前正在跑的那个源**（`p.search().await`）不会被打断 ——
     *    必须等它跑完（可能 20 秒）才轮到下一次 send
     * ```
     *
     * # 所以必须 abort
     *
     * `abort()` 会在下一个 await 点直接丢弃该任务的 future ——
     * 正在进行的网络请求随之取消（reqwest 的 future drop 会关闭连接）。
     *
     * # ⚠️ 这与原版有行为差异（诚实记录）
     *
     * 原版用 `tokio::join!(search_fut, drain_fut)`：
     * ```text
     * 前端 drop 接收端 → Channel::send 失败 → search 循环 return
     * → search_fut 完成 → join! 结束
     * ```
     * 它**能**提前结束，因为 Tauri 的 `Channel` 是框架对象，
     * 前端 drop 后 send 立刻失败；而且当时那个源的请求同样不会被打断，
     * 所以原版其实也要等「当前源跑完」。
     *
     * 我这里 abort 更彻底（连当前源也取消）—— 对用户是更好的体验，
     * 且**不改变任何结果语义**（取消就是不要结果了）。
     */
    if cancelled {
        producer.abort();
        /*
         * abort 后仍要 await 一次：`abort()` 只是"请求取消"，
         * 任务真正结束前它的 Drop 不会跑。await 保证 tx 已释放、
         * 不会留下悬空任务。
         *
         * 这里 await 是**安全的**（不会长等）：abort 后任务会在
         * 下一个 await 点立刻结束。
         */
        let _ = producer.await;
    } else if let Err(e) = producer.await {
        // 生产者 panic 不该传播到 FFI 边界（那是 UB）
        log::warn!("流式搜索的生产者任务异常结束: {e}");
    }

    Ok(())
}

// ═══════════════════════════════════════════════════════════════════════
//  批次 4 · 直播（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 四个命令都是薄适配器
//
// ```text
// get_live_channels → registry.live_all()
// get_live_stream   → provider.live_stream(channel_id)
// get_epg           → provider.epg(channel_id, None)
// get_timeshift     → provider.timeshift(channel_id, start, end)
// ```
// 底层（`Registry::live_all` / `Provider` trait 的四个方法）都已在
// 早前的搬运里完成，所以这批只是接线。
//
// # ⚠️ 一个必须保留的细节：`epg` 的第二个参数是 `None`
//
// ```text
// p.epg(&channel_id, None)
//                    ^^^^ 这个 None 是**刻意的**
// ```
// 原版就是这样调的。它表示"不带日期参数，取默认（今天）"。
// 不要"顺手"补一个日期参数 —— 那会改变行为，
// 而不同源对日期的解析方式不一致，容易踩坑。

/// 全部直播频道（按源分组）
///
/// # 返回结构是**手搓 JSON** 而不是结构体
///
/// 原版用 `serde_json::json!` 现场构造：
/// ```text
/// { "provider": id, "providerName": name, "channels": [...] }
/// ```
/// 注意字段名是 **camelCase**（`providerName`）—— 这是给前端直接用的，
/// 原版前端就是读 `providerName`。所以这里**照抄**，不改成 snake_case
///（改了前端要跟着改，而"操作逻辑保持一致"要求前端尽量能照搬）。
pub async fn get_live_channels(
    state: &AppState,
) -> Result<Vec<serde_json::Value>, String> {
    let groups = state.registry.live_all().await;
    Ok(groups
        .into_iter()
        .map(|(id, name, channels)| {
            serde_json::json!({
                "provider": id,
                "providerName": name,
                "channels": channels
            })
        })
        .collect())
}

/// 取某频道的播放地址（可能多个候选）
pub async fn get_live_stream(
    state: &AppState,
    provider: &str,
    channel_id: &str,
) -> Result<Vec<crate::model::StreamCandidate>, String> {
    let p = state
        .registry
        .get(provider)
        .ok_or_else(|| format!("找不到 Provider: {provider}"))?;
    p.live_stream(channel_id).await.map_err(|e| e.message)
}

/// 取电子节目单（EPG）
///
/// ⚠️ 第二个参数固定传 `None` —— 见本批次开头的说明。
pub async fn get_epg(
    state: &AppState,
    provider: &str,
    channel_id: &str,
) -> Result<Vec<crate::model::EpgEntry>, String> {
    let p = state
        .registry
        .get(provider)
        .ok_or_else(|| format!("找不到 Provider: {provider}"))?;
    p.epg(channel_id, None).await.map_err(|e| e.message)
}

/// 时移回看（取某个时间段的流）
///
/// `start` / `end` 是 Unix 时间戳（秒）。
pub async fn get_timeshift(
    state: &AppState,
    provider: &str,
    channel_id: &str,
    start: i64,
    end: i64,
) -> Result<crate::model::StreamCandidate, String> {
    let p = state
        .registry
        .get(provider)
        .ok_or_else(|| format!("找不到 Provider: {provider}"))?;
    p.timeshift(channel_id, start, end)
        .await
        .map_err(|e| e.message)
}

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_dir(tag: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!(
            "sourin-cmd-test-{tag}-{}",
            chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
        ));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// ★ 损坏的停用清单必须降级为「全部启用」
    ///
    /// 为什么这个默认值是对的：如果反过来（损坏 = 全部停用），
    /// 用户会看到「所有源都没了」而不知道原因 —— 那是灾难性的。
    /// 宁可多显示一个源。
    #[test]
    fn corrupt_disabled_list_means_all_enabled() {
        let dir = tmp_dir("corrupt-disabled");
        std::fs::write(disabled_file(&dir), "not json at all").unwrap();
        let got = load_disabled(&dir);
        assert!(got.is_empty(), "损坏的停用清单应降级为『全部启用』");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 停用列表的写入/读回
    #[test]
    fn disabled_roundtrip() {
        let dir = tmp_dir("disabled-rt");
        save_disabled(&dir, &["cycani".into(), "cctv".into()]).unwrap();
        let back = load_disabled(&dir);
        assert_eq!(back.len(), 2);
        assert!(back.contains(&"cycani".to_string()));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 顺序的写入/读回
    #[test]
    fn order_roundtrip() {
        let dir = tmp_dir("order-rt");
        save_order(&dir, &["a".into(), "b".into(), "c".into()]).unwrap();
        assert_eq!(load_order(&dir), vec!["a", "b", "c"]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 两个清单用**不同文件**，不能串
    #[test]
    fn disabled_and_order_use_different_files() {
        let dir = tmp_dir("separate");
        save_disabled(&dir, &["x".into()]).unwrap();
        save_order(&dir, &["y".into()]).unwrap();
        assert_eq!(load_disabled(&dir), vec!["x"]);
        assert_eq!(load_order(&dir), vec!["y"]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 原子写不留临时文件
    #[test]
    fn saves_are_atomic() {
        let dir = tmp_dir("atomic2");
        save_disabled(&dir, &[]).unwrap();
        save_order(&dir, &[]).unwrap();
        assert!(!disabled_file(&dir).with_extension("json.tmp").exists());
        assert!(!order_file(&dir).with_extension("json.tmp").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
