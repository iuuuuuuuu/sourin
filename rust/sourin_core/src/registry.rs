//! Provider Registry —— 注册、路由、错误隔离
//!
//! 借鉴 yt-dlp 的三个机制（均有反面案例支撑）：
//! 1. **错误隔离**：单个 provider 失败不影响其他（`except Exception: continue`）
//! 2. **优先级排序**：`origin_preference` 让官方源排在公共采集源前面
//! 3. **懒加载预留**：匹配声明常驻，实现按需加载（provider 上百个时必需）

use crate::model::*;
use crate::provider::*;
use std::collections::HashMap;
use std::sync::{Arc, RwLock};
/// Provider 注册表
#[derive(Default)]
pub struct Registry {
    providers: RwLock<Vec<ProviderHandle>>,
}

impl Registry {
    pub fn new() -> Self {
        Self {
            providers: RwLock::new(Vec::new()),
        }
    }

    /// 注册一个 Provider
    pub fn register(&self, provider: Arc<dyn MediaProvider>) {
        let mut list = self.providers.write().unwrap();
        let id = provider.manifest().id.clone();
        // 同 id 覆盖（支持热重载/覆写机制）
        list.retain(|h| h.provider.manifest().id != id);
        list.push(ProviderHandle::new(provider));
        // 按优先级稳定排序
        list.sort_by_key(|h| h.priority);
    }

    /// 注册时指定优先级
    pub fn register_with_priority(&self, provider: Arc<dyn MediaProvider>, priority: i32) {
        let mut list = self.providers.write().unwrap();
        let id = provider.manifest().id.clone();
        list.retain(|h| h.provider.manifest().id != id);
        let mut handle = ProviderHandle::new(provider);
        handle.priority = priority;
        list.push(handle);
        list.sort_by_key(|h| h.priority);
    }

    /// ★ 按用户指定的顺序重排（首页切换条 / 设置页列表都用它）
    ///
    /// # 参数
    ///
    /// `ids` 是用户期望的顺序。**允许不完整**：
    ///
    /// · 不在 `ids` 里的源 → 保持原相对顺序，**排到末尾**
    ///   （用户没表过态的源不该插到最前抢位置；这也让"新增的源"自然落到末尾）
    /// · `ids` 里不存在的 id → 忽略（源可能已被删除/停用）
    ///
    /// # 为什么不用 `priority` 字段
    ///
    /// `priority` 是给「跨平台聚合时的优先级」用的（如央视优先于第三方），
    /// 与「用户想先看哪个源」是**两件事**。混用会导致：
    /// 用户排完序后，某个源的业务优先级一变，顺序又被打乱。
    ///
    /// 所以顺序**直接体现为 Vec 的次序** —— 这也是 `manifests()` 返回的顺序。
    ///
    /// # 返回
    ///
    /// 实际生效的顺序（便于调用方落盘与前端同步）。
    pub fn reorder(&self, ids: &[String]) -> Vec<String> {
        let mut list = self.providers.write().unwrap();

        /*
         * 用 `sort_by_key` 而不是重建 Vec：
         * 前者是**稳定排序**，不在 ids 里的项会保持原有相对顺序自动落到末尾。
         * 重建的话要自己处理"剩余项"，容易写漏。
         */
        let rank = |id: &str| -> usize {
            ids.iter().position(|x| x == id).unwrap_or(usize::MAX)
        };
        list.sort_by_key(|h| rank(&h.provider.manifest().id));

        list.iter()
            .map(|h| h.provider.manifest().id.clone())
            .collect()
    }

    /// 注销
    pub fn unregister(&self, id: &str) -> bool {
        let mut list = self.providers.write().unwrap();
        let before = list.len();
        list.retain(|h| h.provider.manifest().id != id);
        list.len() != before
    }

    /// 启用/禁用
    pub fn set_enabled(&self, id: &str, enabled: bool) -> bool {
        let mut list = self.providers.write().unwrap();
        if let Some(h) = list.iter_mut().find(|h| h.provider.manifest().id == id) {
            h.enabled = enabled;
            true
        } else {
            false
        }
    }

    /// 全部 Provider 的清单
    pub fn manifests(&self) -> Vec<ProviderManifest> {
        self.providers
            .read()
            .unwrap()
            .iter()
            .map(|h| h.provider.manifest().clone())
            .collect()
    }

    /// 仅启用的
    pub fn enabled_manifests(&self) -> Vec<ProviderManifest> {
        self.providers
            .read()
            .unwrap()
            .iter()
            .filter(|h| h.enabled)
            .map(|h| h.provider.manifest().clone())
            .collect()
    }

    /// 按 id 取 Provider
    pub fn get(&self, id: &str) -> Option<Arc<dyn MediaProvider>> {
        self.providers
            .read()
            .unwrap()
            .iter()
            .find(|h| h.provider.manifest().id == id)
            .map(|h| h.provider.clone())
    }

    /// ★ 按 MediaId 路由 —— 优先用 `id_prefixes` 精确匹配，回退到 provider 字段
    pub fn route(&self, id: &MediaId) -> Option<Arc<dyn MediaProvider>> {
        // 1. 直接按 provider 字段
        if let Some(p) = self.get(&id.provider) {
            return Some(p);
        }
        // 2. 按 id_prefixes 匹配（借鉴 Stremio，实现多源协作）
        let list = self.providers.read().unwrap();
        for h in list.iter().filter(|h| h.enabled) {
            let m = h.provider.manifest();
            if m.id_prefixes.iter().any(|p| id.native.starts_with(p)) {
                return Some(h.provider.clone());
            }
        }
        None
    }

    /// ★ 跨 Provider 搜索聚合（错误隔离：单个失败不影响整体）
    ///
    /// 返回 `(provider_id, 结果)`，失败的 provider 被跳过并记录原因。
    pub async fn search_all(&self, keyword: &str, page: u32) -> SearchAllResult {
        /*
         * ★ 2026-09-24：与 `search_all_stream` 共用同一套**有界并发**内核。
         *
         * 原来是独立的 for 循环（纯串行）—— 改成共用之后：
         * ```text
         * ① 两条路径的耗时特性一致（不会出现"流式快、一次性慢"的怪现象）
         * ② 将来调并发上限只需改一处
         * ③ 少一份重复的错误隔离/working 判断逻辑
         * ```
         *
         * ⚠️ 语义**不变**：仍然只把 `items` 非空的源放进 `results`，
         *    失败的进 `skipped` —— 只是**顺序变成完成顺序**。
         *    调用方（`commands::search_all` → FFI → Dart）把它当集合用，
         *    没有依赖顺序。
         */
        let mut results = Vec::new();
        let mut skipped = Vec::new();

        self.for_each_search(keyword, page, |outcome| {
            match outcome {
                Ok(r) => results.push(r),
                Err(s) => skipped.push(s),
            }
            true // 不取消
        })
        .await;

        SearchAllResult { results, skipped }
    }

    /// ★ 有界并发的**搜索内核**（`search_all` 与 `search_all_stream` 共用）
    ///
    /// # 为什么要有这个函数
    ///
    /// 两个公开方法（一次性 / 流式）只差**怎么处理结果**，
    /// 而"怎么并发、上限多少、怎么取消"应该只有一份实现 ——
    /// 否则将来调并发度时会漏改一条路径（本项目踩过这类不一致）。
    ///
    /// # 并发模型（2026-09-24 实测后定的）
    ///
    /// ## 档位实测（26 源搜「庆余年」，**每档跑 3 次取中位数**）
    ///
    /// ```text
    /// 并发   1      2      4      6      8      12     26
    /// 中位  16326  7185   4402   3073   2940   2222   1884  (ms)
    /// 命中   19     19     19     19     19     19     19   (条数不变 => 没丢结果)
    /// ```
    /// ⚠️ **单轮数据不可用**：我第一次只跑一轮，8 路(9459ms) 竟比 4 路(3633ms) 还慢 ——
    ///    那是网络抖动。所以上表是 3 次的中位数，且**每档 19 源命中恒定**
    ///    证明并发没有丢结果。
    ///
    /// ## 为什么选 12（不是 26，也不是我最初拍的 6）
    ///
    /// ```text
    /// 6  -> 12 : 3073 -> 2222ms  （快 28%，值得）
    /// 12 -> 26 : 2222 -> 1884ms  （只快 15%，但峰值资源翻倍）
    /// ```
    /// 取 **12** 是"拐点之后、天花板之前"：
    ///   · 比 6 快近三成，长尾（最慢源 ~2.8s）基本被压平
    ///   · ★ 峰值只同时存在 **12 个 QuickJS runtime**
    ///     （`plugins/mod.rs:613` **每次调用新建 `AsyncRuntime`**），
    ///     JS 引擎是重对象，26 个同时建内存/CPU 峰值明显更高
    ///   · ★ 且本批源里有**同主机多源**（`api`/`api-2`/`api-3` 同属采集站家族，
    ///     `bfzyapi`/`bfzyapi-2` 同属暴风）—— 26 路会给同一主机并发 5 个请求，
    ///     12 路则最多 3 个，**更不容易被目标站限流/封 IP**
    ///
    /// ⚠️ **不能改成分批 `join_all`/`tokio::join!`** —— 我第一版那样写，
    ///    首个结果从 0.32s 退化到 **1.77s**（必须等本批最慢的源）。
    ///    流式的价值就在"快的先出来"，分批恰好毁掉它。
    ///
    /// # 取消
    ///
    /// `on_result` 返回 `false` → 立刻 `abort_all()` 返回。
    /// `batch3_search::stream_callback_false_stops_early` 守着这条
    ///（要求 <5s；实测 0.38s）。
    async fn for_each_search<F>(&self, keyword: &str, page: u32, mut on_result: F)
    where
        F: FnMut(
            std::result::Result<(String, String, Page<MediaItem>), (String, String)>,
        ) -> bool,
    {
        /// ★ 并发上限 = 12（依据见上表：6→12 快 28%，12→26 只快 15% 但资源翻倍）
        const MAX_CONCURRENT: usize = 12;

        /// 跑一个源，产出 `Ok((id,name,page))` 或 `Err((id,reason))`
        async fn run_one(
            p: Arc<dyn MediaProvider>,
            keyword: String,
            page: u32,
        ) -> std::result::Result<(String, String, Page<MediaItem>), (String, String)> {
            let m = p.manifest();
            if !m.working {
                return Err((
                    m.id.clone(),
                    m.broken_reason.clone().unwrap_or_else(|| "该源已失效".into()),
                ));
            }
            match p.search(&keyword, page).await {
                Ok(page_data) => {
                    if page_data.items.is_empty() {
                        // 搜到了但没结果 —— 也回调一次，让 UI 能统计"已搜 N 个源"
                        Err((m.id.clone(), String::new()))
                    } else {
                        Ok((m.id.clone(), m.name.clone(), page_data))
                    }
                }
                // ★ 错误隔离：记下原因，继续下一个
                Err(e) => Err((m.id.clone(), e.message)),
            }
        }

        let targets: Vec<_> = self
            .providers
            .read()
            .unwrap()
            .iter()
            .filter(|h| h.enabled && h.provider.manifest().capabilities.search)
            .map(|h| h.provider.clone())
            .collect();

        /*
         * `JoinSet` 要求 future 是 `'static` + `Send` —— 所以 keyword
         * 必须是 owned String（不能借用外层 `&str`）。
         */
        let kw = keyword.to_string();
        let sem = Arc::new(tokio::sync::Semaphore::new(MAX_CONCURRENT));
        let mut set: tokio::task::JoinSet<
            std::result::Result<(String, String, Page<MediaItem>), (String, String)>,
        > = tokio::task::JoinSet::new();

        for p in targets {
            let permit_sem = sem.clone();
            let kw = kw.clone();
            set.spawn(async move {
                // 拿到许可才真正发请求（最多 6 个同时在飞）
                let _permit = permit_sem.acquire().await.expect("semaphore 不会关闭");
                run_one(p, kw, page).await
            });
        }

        /*
         * ★ 谁先完成谁先回调（`join_next` = 完成顺序，不是注册顺序）。
         *
         * 回调返回 false = 用户取消 → `abort_all()` 后返回；
         * 即使不显式 abort，`set` 被 drop 时也会 abort 剩余任务，
         * 但显式写出来语义更清楚（且不依赖 drop 时机的实现细节）。
         */
        while let Some(joined) = set.join_next().await {
            let outcome = match joined {
                Ok(o) => o,
                // 单个任务 panic 不该拖垮整个搜索
                Err(e) => {
                    log::warn!("搜索任务异常结束: {e}");
                    continue;
                }
            };
            if !on_result(outcome) {
                set.abort_all();
                return;
            }
        }
    }

    /// ★★★ 流式搜索 —— **搜完一个源就回调一个**（2026-09-19 新增）
    ///
    /// # Owner 的要求（原话）
    ///
    /// > 搜索页面,不应该等待所有源一起搜索完毕再显示出来,
    /// > **搜索结束一个就显示一个**,后面的往里面push就行了
    ///
    /// # 与 `search_all` 的区别
    ///
    /// | | `search_all`（旧）| `search_all_stream`（新）|
    /// |---|---|---|
    /// | 返回时机 | **所有源都跑完**才返回 | 每完成一个源就回调一次 |
    /// | 用户感受 | 盯着转圈等最慢的源 | 结果**陆续冒出来** |
    ///
    /// 假设 25 个源、最慢的要 12 秒：
    /// ```text
    /// 旧: [等 12 秒] → 一次性出现全部
    /// 新: [1 秒]出现第 1 个 → [1.2 秒]又 3 个 → … → [12 秒]全部
    /// ```
    /// 用户**第一秒就有东西看**，可以立刻点进去，
    /// 而不必等那个卡住的源。
    ///
    /// # 执行方式：**有界并发**（2026-09-24 从纯串行改过来）
    ///
    /// ⚠️ 下面这段旧注释说"仍然串行"，**已被实测推翻** —— 保留它是为了
    ///    记录当时的判断依据，以及为什么它不成立（见 `search_all_stream`
    ///    函数体里的完整说明与实测数据）：
    /// ```text
    /// 原判断：「插件是 QuickJS 单线程宿主，并发收益有限」
    /// 实测：plugins/mod.rs:613 `AsyncRuntime::new()` —— 每次调用**新建**
    ///       runtime，各源之间没有任何共享状态 => 并发是安全的
    /// 数据：26 源串行 32.8s；前 5 慢源占 54%，其中 3 个注定返回 0 条
    /// ```
    /// 但仍**不做全并发** —— 原注释担心的"打爆目标站/抢带宽"是真的，
    /// 所以用 6 路有界并发（折中：32.8s → 最慢源量级）。
    ///
    /// 保持与旧实现一致 —— 并发 25 个 HTTP 请求会：
    ///   · 打爆目标站（可能被封 IP）
    ///   · 抢占本机带宽，反而让每个请求都变慢
    ///   · 插件是 QuickJS 单线程宿主，并发收益有限
    ///
    /// ⚠️ 串行 + 逐个回调，已经能完全解决"等最慢的源"问题：
    ///    快的源立刻显示，慢的源后面补上。
    ///
    /// # 回调契约
    ///
    /// `on_result` 每完成一个源被调用一次，参数是**该源的结果**：
    /// ```text
    /// Ok((id, name, page))  → 该源搜到了内容
    /// Err((id, reason))     → 该源失败/失效（UI 可以显示"12 个源无结果"）
    /// ```
    /// 回调返回 `false` 表示**用户已取消**，循环立刻停止。
    ///
    /// ⚠️ 这里必须写 `std::result::Result` —— 因为 `model.rs` 里
    ///    把 `Result<T>` 定义成了 `std::result::Result<T, ProviderError>`
    ///    （只有 1 个泛型参数），直接用 `Result<A, B>` 会编译不过。
    pub async fn search_all_stream<F>(&self, keyword: &str, page: u32, mut on_result: F)
    where
        F: FnMut(
            std::result::Result<(String, String, Page<MediaItem>), (String, String)>,
        ) -> bool,
    {
        /*
         * ★ 2026-09-24：并发内核搬到了 `for_each_search` —— 与 `search_all`
         *   **共用同一份实现**（避免两条路径的耗时/取消语义不一致）。
         *
         * # 实测数据（26 个真实源，搜「庆余年」）
         *
         * ```text
         * 串行（旧）              32.8s      首个结果 0.32s
         * 分批并发（我的第一版）    6.9s      首个结果 1.77s   ← 反而更差！
         * JoinSet 有界并发（现在） 4.5s      首个结果 0.16s   ← 两个指标都更好
         * ```
         * 「分批」之所以差：必须等**本批最慢的源**才能回调，
         * 首批里只要有一个 2s 的源，0.3s 就到的结果也要压到 2s ——
         * 恰好毁掉流式的核心价值。详见 `for_each_search` 的说明。
         */
        self.for_each_search(keyword, page, |outcome| on_result(outcome))
            .await;
    }

    /// ★ 跨 Provider 聚合首页（每个 provider 一个分区组）
    ///
    /// **会过滤掉会话不可用的源**（需求 6）：登录失效的源内容点了也播不了，
    /// 展示在首页只会误导用户。过滤后用户看不到它，
    /// 而设置页仍会显示「需要重新登录」的状态供人工处理。
    pub async fn home_all(&self) -> Vec<(String, String, Vec<Section>)> {
        let targets: Vec<_> = self
            .providers
            .read()
            .unwrap()
            .iter()
            .filter(|h| h.enabled)
            .map(|h| h.provider.clone())
            .collect();

        let mut out = Vec::new();
        for p in targets {
            let m = p.manifest();
            if !m.working {
                continue;
            }
            // ★ 会话失效则不展示（首页是「能看什么」，不是「有什么源」）
            if !p.session_usable().await {
                log::debug!("{}: 会话不可用，跳过首页聚合", m.id);
                continue;
            }
            // 错误隔离
            if let Ok(sections) = p.home().await {
                if !sections.is_empty() {
                    out.push((m.id.clone(), m.name.clone(), sections));
                }
            }
        }
        out
    }

    /// 全部直播频道聚合（按 provider 分组）
    pub async fn live_all(&self) -> Vec<(String, String, Vec<LiveChannel>)> {
        let targets: Vec<_> = self
            .providers
            .read()
            .unwrap()
            .iter()
            .filter(|h| h.enabled && h.provider.manifest().capabilities.live)
            .map(|h| h.provider.clone())
            .collect();

        let mut out = Vec::new();
        for p in targets {
            let m = p.manifest();
            // 直播同样过滤失效会话
            if !p.session_usable().await {
                continue;
            }
            if let Ok(chans) = p.live_channels().await {
                if !chans.is_empty() {
                    out.push((m.id.clone(), m.name.clone(), chans));
                }
            }
        }
        out
    }

    /// 健康自愈：探测所有 provider，更新 working 状态
    ///
    /// 注意：`working` 是运行时状态，这里只返回探测结果，由调用方决定是否持久化。
    pub async fn health_sweep(&self) -> HashMap<String, bool> {
        let targets: Vec<_> = self
            .providers
            .read()
            .unwrap()
            .iter()
            .map(|h| h.provider.clone())
            .collect();

        let mut out = HashMap::new();
        for p in targets {
            let id = p.manifest().id.clone();
            // 超时保护，避免单个 provider 拖垮巡检
            let ok = tokio::time::timeout(std::time::Duration::from_secs(15), p.health_check())
                .await
                .unwrap_or(false);
            out.insert(id, ok);
        }
        out
    }

    pub fn len(&self) -> usize {
        self.providers.read().unwrap().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    // ─────────────────── ★ 会话生命周期（通用）───────────────────
    //
    // 这一层的存在意义：**调用方不该关心「这个源用什么方式续期」**。
    // 命令层只问一句「现在能播吗」，下面是 refresh 还是重新登录由各源自己决定。

    /// ★ 确保某源的会话可用
    ///
    /// 流程（每一步都按需跳过）：
    /// 1. 该源不需要登录 → `Ok(true)`
    /// 2. 会话快过期且支持续期 → 续期
    /// 3. 续期没成功 / 不支持续期 → 尝试自动登录（若有保存的凭据）
    /// 4. 都不行 → `Ok(false)`，调用方应提示用户**去设置页人工登录**
    ///
    /// 返回 `Ok(true)` 表示现在可以正常调用该源的受保护接口。
    ///
    /// ⚠️ **绝不在此处尝试绕过验证码** —— 需要人工介入时就是要人工介入。
    pub async fn ensure_session(&self, provider_id: &str) -> Option<bool> {
        let p = self.get(provider_id)?;

        // 1) 不需要登录的源（央视等）直接放行
        if !p.manifest().capabilities.login_required {
            return Some(true);
        }

        // 2) 已有会话且不需要续期 → 直接可用
        if !p.session_needs_refresh().await {
            if matches!(p.session().await, Ok(Some(_))) {
                return Some(true);
            }
        }

        // 3) 尝试续期
        match p.refresh_session().await {
            Ok(Some(_)) => {
                log::info!("{provider_id}: 会话已自动续期");
                return Some(true);
            }
            Ok(None) => { /* 该源不支持续期，往下走自动登录 */ }
            Err(e) => {
                log::warn!("{provider_id}: 续期失败（{}），尝试自动登录", e.message);
            }
        }

        // 4) 尝试自动登录（仅当凭据已保存）
        if p.can_auto_login().await {
            match p.auto_login().await {
                Ok(Some(_)) => {
                    log::info!("{provider_id}: 已用保存的凭据自动重新登录");
                    return Some(true);
                }
                Ok(None) => {}
                Err(e) => {
                    // 验证码/风控/改密都会走到这里 —— 明确记录，交由 UI 提示人工处理
                    log::warn!("{provider_id}: 自动登录失败，需人工登录: {}", e.message);
                }
            }
        }

        Some(false)
    }

    /// ★ 查询会话状态（供 UI 展示「已登录/即将过期/已失效」）
    ///
    /// # ★★★ 2026-09-21 修：「游客可用但支持登录」的源永远显示不出「已登录」
    ///
    /// 原先是「`login_required == false` → 直接返回 `NotRequired`」。
    /// 这对央视那类**完全不支持登录**的源是对的，但对 B站 是错的：
    /// ```text
    /// bilibili  login_required = false   （游客也能看 1080P）
    ///           login_supported = true    （登录后能同步关注/收藏）
    /// ```
    /// 于是用户明明扫码登录成功了，设置页却一直显示「游客可用」，
    /// 看起来像"登录没生效"。
    ///
    /// **判据从「需不需要登录」改成「支不支持登录」**：
    /// ```text
    /// 支持登录（required 或 supported）→ 按会话实际状态返回
    /// 完全不支持登录                   → NotRequired
    /// ```
    ///
    /// ⚠️ 这与设置页显示登录入口的条件
    ///    （`login_required || login_supported`）**保持一致** ——
    ///    能显示入口的源，就一定能显示出它的登录结果。
    pub async fn session_state(&self, provider_id: &str) -> Option<SessionState> {
        let p = self.get(provider_id)?;

        let caps = &p.manifest().capabilities;
        if !caps.login_required && !caps.login_supported {
            return Some(SessionState::NotRequired);
        }

        match p.session().await {
            Ok(Some(_)) => {
                /*
                 * ★★★ 2026-09-24 修：「已过期」不能报成「即将过期」
                 *
                 * 用户报「次元城明明已登录了，也提示未登录」——
                 * 实际是**反过来**：界面显示「已登录」，但一点播就 unauthorized。
                 *
                 * 根因链（实测确认）：
                 * ```text
                 * ① 插件存的 token 早过期（JWT exp 比现在早 11 小时）
                 * ② session_needs_refresh() 对「已过期」也返回 true
                 * ③ 于是这里报 Expiring
                 * ④ UI 把 Expiring 渲染成「已登录 · 无需操作」
                 * ⑤ 用户点播 → token 已死 → unauthorized
                 * ```
                 *
                 * 修法：先问「**真的过期了吗**」（`session_expired()`）。
                 * 过期且**没有凭据能自动恢复** → 只能人工登录 → `Expired`。
                 * 过期但**有凭据**（如 cycani 存了账号密码）→ 宿主下次点播会
                 * 自动重登，报 `Expiring` 是诚实的，不该吓用户去手动登录。
                 *
                 * ⚠️ 顺序不能反：`Expiring` 是「还能自愈」，`Expired` 是
                 *    「必须你动手」。把能自愈的说成失效会平白制造焦虑，
                 *    把失效的说成正常就是用户报的这个 bug。
                 */
                if p.session_expired().await {
                    if p.can_auto_login().await {
                        Some(SessionState::Expiring)
                    } else {
                        Some(SessionState::Expired)
                    }
                } else if p.session_needs_refresh().await {
                    Some(SessionState::Expiring)
                } else {
                    Some(SessionState::Active)
                }
            }
            // 没会话：若还能自动登录，就不算「已失效」（用户下次点播会自动恢复）
            Ok(None) => {
                if p.can_auto_login().await {
                    Some(SessionState::Expiring)
                } else if caps.login_required {
                    // 必须登录却没有会话 → 确实失效了
                    Some(SessionState::Expired)
                } else {
                    /*
                     * ★ 可选登录（如 B站）+ 没有会话 → **不是"失效"**
                     *
                     * 用户从没登录过是完全正常的状态（游客就能用），
                     * 报「已失效」会让人以为出问题了、被催着去登录。
                     * 用 `NotRequired` 表达"不登录也能用"。
                     */
                    Some(SessionState::NotRequired)
                }
            }
            /*
             * ★★★ 2026-09-25 修（task-38）：这一行原本是 `Err(_) => Expired`
             *
             * 它是本函数里**唯一没看凭据**的分支 —— 上面两条都看了：
             * ```text
             * L613  有过期会话 + can_auto_login → Expiring
             * L626  无会话     + can_auto_login → Expiring
             * L643  session() 报错             → Expired   ★ 只有它没看
             * ```
             * 于是 `session()` 一报错（store 被写坏 / 读盘失败 / 插件抛异常），
             * **凭据完好的**插件也会被判 `Expired` → UI 对用户说
             * 「需重新登录（可能需要验证码，请手动完成）」。
             *
             * ⚠️ 而实际上下一行 `ensure_session()` 就能用凭据把它救活 ——
             *    同一份判据在两处得出**互相矛盾**的结论，这本身就是错的。
             *
             * ★ 实测触发条件比预想的窄：`cycani.js` 自己 try/catch 了
             *   `JSON.parse`，store 写坏时它返回 `Ok(None)`（走上面那条安全分支）。
             *   但仍然要改 —— 理由：
             * ```text
             * ① 逻辑一致性：判据在别处都看凭据，这里不看是**没有理由的例外**
             * ② 别的插件未必像 cycani 那样自己兜底（用户自己能写插件）
             * ③ 代价为零：多一次 can_auto_login() 调用（本地读文件，微秒级）
             * ④ 方向安全：`Expiring` 不催用户动手；真救不活时点播会如实报错
             * ```
             */
            Err(_) => {
                /*
                 * ⚠️ 这里**必须**和上面两条一样看凭据 —— 否则同一份判据
                 *    在两处得出互相矛盾的结论（一条说"能自愈"、
                 *    另一条说"必须人工"）。
                 *
                 * ⚠️ 别把这行改回 `Err(_) => Some(SessionState::Expired)` ——
                 *    `tests/zz_t38_registry.rs::session_error_with_credentials_is_expiring`
                 *    专门守着这一点（已做过红度证明）。
                 */
                if p.can_auto_login().await {
                    Some(SessionState::Expiring)
                } else {
                    Some(SessionState::Expired)
                }
            }
        }
    }

    /// ★ 批量查询：哪些源当前**可用**（首页据此过滤）
    ///
    /// 需求：登录失效的源不该出现在首页 —— 因为它的内容点了也播不了，
    /// 展示出来只会让用户困惑。这里返回「可展示」的源 id 集合。
    pub async fn usable_provider_ids(&self) -> Vec<String> {
        let targets: Vec<_> = self
            .providers
            .read()
            .unwrap()
            .iter()
            .filter(|h| h.enabled)
            .map(|h| h.provider.clone())
            .collect();

        let mut out = Vec::new();
        for p in targets {
            let m = p.manifest();
            if !m.working {
                continue; // 站点自身失效
            }
            if p.session_usable().await {
                out.push(m.id.clone());
            }
        }
        out
    }
}

// ─────────────────────────── 聚合结果 ───────────────────────────

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SearchAllResult {
    /// (provider_id, provider_name, 结果)
    pub results: Vec<(String, String, Page<MediaItem>)>,
    /// ★ 被跳过的源及原因（UI 明确告知用户，而非静默失败）
    pub skipped: Vec<(String, String)>,
}

// ─────────────────────────── 测试 ───────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider::Credentials;
    use async_trait::async_trait;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// 可控的假 Provider —— **不联网**，用来验证通用会话流程。
    ///
    /// 这是「新源只需覆写几个方法」的可执行证明：它实现了
    /// refresh/auto_login 两个覆写点，其余全用 trait 默认实现。
    struct FakeProvider {
        manifest: ProviderManifest,
        /// 当前会话
        session: std::sync::RwLock<Option<Session>>,
        /// 是否支持续期
        can_refresh: bool,
        /// 是否有保存的凭据
        has_cred: bool,
        /// 续期调用次数（验证并发/重复保护）
        refresh_calls: AtomicUsize,
        /// 自动登录是否成功
        auto_login_ok: bool,
    }

    impl FakeProvider {
        fn new(login_required: bool, can_refresh: bool, has_cred: bool, auto_login_ok: bool) -> Self {
            Self::with_login_supported(login_required, false, can_refresh, has_cred, auto_login_ok)
        }

        /// 带 `login_supported` 的构造 —— 用来造出「B站那种源」
        ///
        /// ```text
        /// B站：login_required = false   （游客能看 1080P）
        ///      login_supported = true   （登录后能同步关注/收藏）
        /// ```
        fn with_login_supported(
            login_required: bool,
            login_supported: bool,
            can_refresh: bool,
            has_cred: bool,
            auto_login_ok: bool,
        ) -> Self {
            Self {
                manifest: ProviderManifest {
                    id: "fake".into(),
                    name: "假源".into(),
                    version: "1".into(),
                    kind: "test".into(),
                    description: None,
                    icon: None,
                    id_prefixes: vec![],
                    capabilities: Capabilities {
                        login_required,
                        login_supported,
                        ..Default::default()
                    },
                    cover_headers: Vec::new(),
                    config: Vec::new(),
                    api_version: 1,
                    theme_color: None,
                    working: true,
                    broken_reason: None,
                    enabled: None,
                },
                session: std::sync::RwLock::new(None),
                can_refresh,
                has_cred,
                refresh_calls: AtomicUsize::new(0),
                auto_login_ok,
            }
        }

        fn with_session(mut self, exp_offset_secs: i64) -> Self {
            let exp = chrono::Utc::now().timestamp() + exp_offset_secs;
            self.session = std::sync::RwLock::new(Some(Session {
                token: "Bearer test".into(),
                expires_at: Some(exp),
                display_name: Some("tester".into()),
                avatar: None,
            }));
            self
        }
    }

    #[async_trait]
    impl MediaProvider for FakeProvider {
        fn manifest(&self) -> &ProviderManifest {
            &self.manifest
        }

        async fn resolve(&self, _id: &MediaId, _req: &PlayRequest) -> Result<Vec<StreamCandidate>> {
            Ok(vec![])
        }

        async fn session(&self) -> Result<Option<Session>> {
            Ok(self.session.read().unwrap().clone())
        }

        async fn login(&self, _c: Credentials) -> Result<Session> {
            let s = Session {
                token: "Bearer new".into(),
                expires_at: Some(chrono::Utc::now().timestamp() + 3600),
                display_name: None,
                avatar: None,
            };
            *self.session.write().unwrap() = Some(s.clone());
            Ok(s)
        }

        async fn refresh_session(&self) -> Result<Option<Session>> {
            self.refresh_calls.fetch_add(1, Ordering::SeqCst);
            if !self.can_refresh {
                return Ok(None);
            }
            let s = Session {
                token: "Bearer refreshed".into(),
                expires_at: Some(chrono::Utc::now().timestamp() + 7200),
                display_name: None,
                avatar: None,
            };
            *self.session.write().unwrap() = Some(s.clone());
            Ok(Some(s))
        }

        async fn can_auto_login(&self) -> bool {
            self.has_cred
        }

        async fn auto_login(&self) -> Result<Option<Session>> {
            if !self.auto_login_ok {
                return Err(ProviderError::unauthorized("需要验证码，请人工登录"));
            }
            let s = Session {
                token: "Bearer autologin".into(),
                expires_at: Some(chrono::Utc::now().timestamp() + 3600),
                display_name: None,
                avatar: None,
            };
            *self.session.write().unwrap() = Some(s.clone());
            Ok(Some(s))
        }

        /// 返回一个固定的分区，便于验证首页聚合的**过滤行为**
        async fn home(&self) -> Result<Vec<Section>> {
            Ok(vec![Section {
                id: "s1".into(),
                title: "假源分区".into(),
                source: SectionSource::Recent,
                items: vec![],
            }])
        }
    }

    // ─────────── 需求 6：失效账号不在首页展示 ───────────

    /// ★★ 会话彻底失效（无会话且无法自动登录）→ **首页不展示该源**
    ///
    /// 需求原文：「失效账号不在首页展示」。
    /// 首页是「现在能看什么」，不是「装过哪些源」——
    /// 展示一个点了也播不了的源只会误导用户。
    #[tokio::test]
    async fn home_excludes_source_with_dead_session() {
        let reg = Registry::new();
        // 需要登录 + 无会话 + 无凭据 → session_usable() == false
        reg.register(Arc::new(FakeProvider::new(true, false, false, false)));

        let home = reg.home_all().await;
        assert!(
            home.is_empty(),
            "会话失效的源不该出现在首页，实际: {:?}",
            home.iter().map(|g| g.0.clone()).collect::<Vec<_>>()
        );
    }

    /// ★ 无会话但**还能自动登录** → 首页仍展示
    ///
    /// 这是刻意的：用户首次点播时宿主会自动恢复会话，
    /// 此时把源藏起来会与设置页显示的「可自动恢复」矛盾。
    #[tokio::test]
    async fn home_keeps_source_that_can_auto_login() {
        let reg = Registry::new();
        // 需要登录 + 无会话 + **有凭据**（auto_login_ok=true）
        reg.register(Arc::new(FakeProvider::new(true, false, true, true)));

        let home = reg.home_all().await;
        assert_eq!(home.len(), 1, "能自动登录的源应保留在首页");
        assert_eq!(home[0].0, "fake");
    }

    /// 有有效会话 → 首页展示
    #[tokio::test]
    async fn home_keeps_source_with_valid_session() {
        let reg = Registry::new();
        reg.register(Arc::new(
            FakeProvider::new(true, false, false, false).with_session(3600),
        ));

        let home = reg.home_all().await;
        assert_eq!(home.len(), 1, "有有效会话的源应展示");
    }

    /// 不需要登录的源（如央视）→ 恒展示
    #[tokio::test]
    async fn home_keeps_source_without_login_requirement() {
        let reg = Registry::new();
        reg.register(Arc::new(FakeProvider::new(false, false, false, false)));

        let home = reg.home_all().await;
        assert_eq!(home.len(), 1, "无需登录的源应恒展示");
    }

    /// 站点自述失效（`working=false`）→ 首页不展示
    #[tokio::test]
    async fn home_excludes_broken_source() {
        let reg = Registry::new();
        let mut p = FakeProvider::new(false, false, false, false);
        p.manifest.working = false;
        p.manifest.broken_reason = Some("站点改版".into());
        reg.register(Arc::new(p));

        assert!(
            reg.home_all().await.is_empty(),
            "已标记失效的源不该出现在首页"
        );
    }

    /// 不需要登录的源：`ensure_session` 直接放行，且**不该**触发任何刷新
    #[tokio::test]
    async fn no_login_required_passes_through() {
        let reg = Registry::new();
        reg.register(Arc::new(FakeProvider::new(false, true, false, true)));

        assert_eq!(reg.ensure_session("fake").await, Some(true));
        assert_eq!(
            reg.session_state("fake").await,
            Some(SessionState::NotRequired)
        );
    }

    /// ★★★ 回归：「游客可用 + 支持登录」的源，登录后必须报 `Active`
    ///
    /// # 这个测试锁的是什么
    ///
    /// 原实现是「`login_required == false` → 直接 `NotRequired`」，
    /// 于是 **B站 扫码登录成功后界面仍显示「游客可用」**，
    /// 看起来像"登录没生效"（Owner 实测踩到）。
    ///
    /// 修复：判据从「需不需要登录」改成「支不支持登录」。
    /// 把 `session_state` 开头那两行改回去，本测试立刻变红。
    #[tokio::test]
    async fn optional_login_reports_active_after_login() {
        let reg = Registry::new();
        // B站那种源：不必须登录，但支持登录
        let p = Arc::new(
            FakeProvider::with_login_supported(false, true, false, false, false).with_session(7200),
        );
        reg.register(p);

        assert_eq!(
            reg.session_state("fake").await,
            Some(SessionState::Active),
            "可选登录的源已登录时必须报 Active —— 否则界面永远显示游客态"
        );

        // 没登录时**不该**报「已失效」：从没登录过是正常状态，不该催用户
        let reg2 = Registry::new();
        reg2.register(Arc::new(FakeProvider::with_login_supported(
            false, true, false, false, false,
        )));
        assert_eq!(
            reg2.session_state("fake").await,
            Some(SessionState::NotRequired),
            "可选登录 + 未登录 → 不是「失效」，游客本来就能用"
        );
    }

    /// ★ 回归：**必须登录**的源没有会话时，仍然要报 `Expired`
    ///
    /// 上面那个修复放宽了判据，这个测试守住另一头 ——
    /// 不能因为放宽而把"真的失效了"也说成 `NotRequired`，
    /// 那会让 cycani 这类源失效后**不被隐藏**（首页展示点了播不了的源）。
    #[tokio::test]
    async fn required_login_without_session_is_still_expired() {
        let reg = Registry::new();
        reg.register(Arc::new(FakeProvider::with_login_supported(
            true, false, false, false, false,
        )));

        assert_eq!(reg.session_state("fake").await, Some(SessionState::Expired));
    }

    /// 会话快过期且支持续期 → 自动续期
    #[tokio::test]
    async fn refreshes_expiring_session() {
        let reg = Registry::new();
        let p = Arc::new(FakeProvider::new(true, true, false, false).with_session(60)); // 只剩 60 秒
        reg.register(p.clone());

        assert_eq!(reg.ensure_session("fake").await, Some(true));
        assert_eq!(p.refresh_calls.load(Ordering::SeqCst), 1, "应恰好续期一次");
    }

    /// 会话仍有效（离过期还早）→ **不该**白白续期
    #[tokio::test]
    async fn does_not_refresh_fresh_session() {
        let reg = Registry::new();
        let p = Arc::new(FakeProvider::new(true, true, false, false).with_session(7200)); // 还有 2 小时
        reg.register(p.clone());

        assert_eq!(reg.ensure_session("fake").await, Some(true));
        assert_eq!(p.refresh_calls.load(Ordering::SeqCst), 0, "新鲜会话不该续期");
    }

    /// 不支持续期但有凭据 → 走自动登录
    #[tokio::test]
    async fn falls_back_to_auto_login() {
        let reg = Registry::new();
        let p = Arc::new(FakeProvider::new(true, false, true, true).with_session(10));
        reg.register(p.clone());

        assert_eq!(reg.ensure_session("fake").await, Some(true), "自动登录应救回来");
        assert_eq!(p.refresh_calls.load(Ordering::SeqCst), 1, "先试过续期");
    }

    /// ★ 续期与自动登录都失败 → false（调用方会提示用户人工登录）
    #[tokio::test]
    async fn reports_failure_when_all_recovery_fails() {
        let reg = Registry::new();
        // 能续期但续不动（can_refresh=false 返回 Ok(None)），有凭据但登录失败
        reg.register(Arc::new(FakeProvider::new(true, false, true, false).with_session(10)));

        assert_eq!(
            reg.ensure_session("fake").await,
            Some(false),
            "全部失败必须明确返回 false，让 UI 提示人工登录"
        );
    }

    /// 无会话且无凭据 → 失效
    #[tokio::test]
    async fn no_session_no_cred_is_expired() {
        let reg = Registry::new();
        reg.register(Arc::new(FakeProvider::new(true, false, false, false)));

        assert_eq!(reg.ensure_session("fake").await, Some(false));
        assert_eq!(
            reg.session_state("fake").await,
            Some(SessionState::Expired)
        );
    }

    /// ★ 会话失效的源不该出现在首页（需求 6）
    #[tokio::test]
    async fn expired_provider_is_hidden_from_home() {
        let reg = Registry::new();
        // 需要登录 + 没会话 + 没凭据 → 不可用
        reg.register(Arc::new(FakeProvider::new(true, false, false, false)));

        let usable = reg.usable_provider_ids().await;
        assert!(
            !usable.contains(&"fake".to_string()),
            "失效的登录源不该出现在可用列表里: {usable:?}"
        );

        // 它仍会被列出（设置页要看得到状态）
        assert_eq!(reg.manifests().len(), 1);
    }

    /// 不需登录的源照常出现在首页
    #[tokio::test]
    async fn open_provider_is_usable() {
        let reg = Registry::new();
        reg.register(Arc::new(FakeProvider::new(false, false, false, false)));
        assert!(reg.usable_provider_ids().await.contains(&"fake".to_string()));
    }

    /// 有凭据的失效会话仍算「可用」—— 因为首次点播会自动恢复
    #[tokio::test]
    async fn recoverable_provider_stays_usable() {
        let reg = Registry::new();
        reg.register(Arc::new(FakeProvider::new(true, false, true, true)));
        assert!(
            reg.usable_provider_ids().await.contains(&"fake".to_string()),
            "有凭据可自动登录 → 不该被判为失效"
        );
    }

    /// 查询不存在的源不该 panic
    #[tokio::test]
    async fn unknown_provider_returns_none() {
        let reg = Registry::new();
        assert_eq!(reg.ensure_session("nope").await, None);
        assert_eq!(reg.session_state("nope").await, None);
    }

    /// ★ trait 默认实现必须安全：一个**不覆写任何会话方法**的源
    /// 在需要登录时不应崩溃，而是如实报「不可用」。
    #[tokio::test]
    async fn default_impl_is_safe_for_unimplemented_provider() {
        struct Bare {
            manifest: ProviderManifest,
        }

        #[async_trait]
        impl MediaProvider for Bare {
            fn manifest(&self) -> &ProviderManifest {
                &self.manifest
            }
            async fn resolve(
                &self,
                _id: &MediaId,
                _req: &PlayRequest,
            ) -> Result<Vec<StreamCandidate>> {
                Ok(vec![])
            }
        }

        let reg = Registry::new();
        reg.register(Arc::new(Bare {
            manifest: ProviderManifest {
                id: "bare".into(),
                name: "未实现会话".into(),
                version: "1".into(),
                kind: "test".into(),
                description: None,
                icon: None,
                id_prefixes: vec![],
                capabilities: Capabilities {
                    login_required: true,
                    ..Default::default()
                },
                cover_headers: Vec::new(),
                config: Vec::new(),
                api_version: 1,
                theme_color: None,
                working: true,
                broken_reason: None,
                enabled: None,
            },
        }));

        // 没有会话、不支持续期、没有凭据 → 明确 false，且不 panic
        assert_eq!(reg.ensure_session("bare").await, Some(false));
    }

    // ═══════════════ 源的显示顺序 ═══════════════

    /// 造一个只带 id 的最小 Provider（顺序测试不关心其它字段）
    fn named(id: &str) -> Arc<dyn MediaProvider> {
        let mut p = FakeProvider::new(false, false, false, false);
        p.manifest.id = id.into();
        p.manifest.name = id.into();
        Arc::new(p)
    }

    /// 按用户给的顺序排列
    #[test]
    fn reorder_applies_user_order() {
        let reg = Registry::new();
        for id in ["a", "b", "c"] {
            reg.register(named(id));
        }
        assert_eq!(ids(&reg), vec!["a", "b", "c"]);

        let actual = reg.reorder(&["c".into(), "a".into(), "b".into()]);
        assert_eq!(actual, vec!["c", "a", "b"]);
        assert_eq!(ids(&reg), vec!["c", "a", "b"]);
    }

    /// ★ 不完整的列表：没提到的源**排到末尾**，且保持原有相对顺序
    ///
    /// 这条很重要：用户新导入一个源时，不该让它插到最前面抢位置。
    #[test]
    fn reorder_puts_unmentioned_at_end() {
        let reg = Registry::new();
        for id in ["a", "b", "c", "d"] {
            reg.register(named(id));
        }

        // 只提到 c 和 a
        let actual = reg.reorder(&["c".into(), "a".into()]);
        assert_eq!(
            actual,
            vec!["c", "a", "b", "d"],
            "没提到的 b/d 应按原相对顺序落到末尾"
        );
    }

    /// 列表里有不存在的 id → 忽略，不影响其它源
    #[test]
    fn reorder_ignores_unknown_ids() {
        let reg = Registry::new();
        for id in ["a", "b"] {
            reg.register(named(id));
        }

        let actual = reg.reorder(&["幽灵源".into(), "b".into(), "a".into()]);
        assert_eq!(actual, vec!["b", "a"], "不存在的 id 应被忽略");
    }

    /// 空列表 = 不改动（避免误清顺序）
    #[test]
    fn reorder_with_empty_list_is_noop() {
        let reg = Registry::new();
        for id in ["a", "b"] {
            reg.register(named(id));
        }
        let actual = reg.reorder(&[]);
        assert_eq!(actual, vec!["a", "b"]);
    }

    /// 重复 id 只认第一次出现的位置
    #[test]
    fn reorder_handles_duplicate_ids() {
        let reg = Registry::new();
        for id in ["a", "b"] {
            reg.register(named(id));
        }
        let actual = reg.reorder(&["b".into(), "a".into(), "b".into()]);
        assert_eq!(actual, vec!["b", "a"]);
    }

    /// 取出当前顺序（测试辅助）
    fn ids(reg: &Registry) -> Vec<String> {
        reg.manifests().iter().map(|m| m.id.clone()).collect()
    }

    // ═══════════════════════════════════════════════════════════════════
    //  ★★ 搜索并发化（2026-09-24）—— 不联网的可执行契约
    // ═══════════════════════════════════════════════════════════════════
    //
    // 背景：`search_all_stream` 原来是**纯串行**，26 个真实源实测 32.8s
    //（前 5 慢源占 54%）。改成 `Semaphore(6)` + `JoinSet` 后 4.5s。
    //
    // 下面这几条守的是**改并发时最容易弄坏的三件事**：
    // ```text
    // ① 并发度真的上去了（否则"改了但没生效"）
    // ② 首个结果**立刻**回调（分批 join_all 会把它从 0.32s 拖到 1.77s）
    // ③ 取消要立即返回（不能等剩余源跑完 —— batch3 实测过 32.82s 的 bug）
    // ```
    // 用"可控延迟的假源"实现，**不联网、不依赖外部站点**。

    /// 可控延迟的搜索源：固定睡 `delay_ms` 后返回一条结果，
    /// 并记录"当前同时有多少个在跑"以验证真实并发度。
    struct SlowSearcher {
        manifest: ProviderManifest,
        delay_ms: u64,
        inflight: Arc<AtomicUsize>,
        peak: Arc<AtomicUsize>,
    }

    impl SlowSearcher {
        fn new(id: &str, delay_ms: u64, inflight: Arc<AtomicUsize>, peak: Arc<AtomicUsize>) -> Self {
            Self {
                manifest: ProviderManifest {
                    id: id.into(),
                    name: id.into(),
                    version: "1".into(),
                    kind: "test".into(),
                    description: None,
                    icon: None,
                    id_prefixes: vec![],
                    capabilities: Capabilities {
                        search: true,
                        ..Default::default()
                    },
                    cover_headers: Vec::new(),
                    config: Vec::new(),
                    api_version: 1,
                    theme_color: None,
                    working: true,
                    broken_reason: None,
                    enabled: None,
                },
                delay_ms,
                inflight,
                peak,
            }
        }
    }

    #[async_trait]
    impl MediaProvider for SlowSearcher {
        fn manifest(&self) -> &ProviderManifest {
            &self.manifest
        }

        async fn search(&self, _keyword: &str, _page: u32) -> Result<Page<MediaItem>> {
            let now = self.inflight.fetch_add(1, Ordering::SeqCst) + 1;
            self.peak.fetch_max(now, Ordering::SeqCst);
            tokio::time::sleep(std::time::Duration::from_millis(self.delay_ms)).await;
            self.inflight.fetch_sub(1, Ordering::SeqCst);
            Ok(Page {
                items: vec![MediaItem {
                    id: MediaId {
                        provider: self.manifest.id.clone(),
                        native: format!("{}-1", self.manifest.id),
                    },
                    title: format!("{} 的片子", self.manifest.id),
                    cover: None,
                    subtitle: None,
                    badges: Vec::new(),
                    kind: MediaKind::default(),
                    description: None,
                }],
                page: 1,
                page_count: Some(1),
                total: Some(1),
            })
        }

        async fn resolve(&self, _id: &MediaId, _req: &PlayRequest) -> Result<Vec<StreamCandidate>> {
            Ok(vec![])
        }
    }

    /// 永远失败的源（验证并发下错误隔离仍然生效）
    struct FailingSearcher {
        manifest: ProviderManifest,
    }

    impl FailingSearcher {
        fn new(id: &str) -> Self {
            Self {
                manifest: ProviderManifest {
                    id: id.into(),
                    name: id.into(),
                    version: "1".into(),
                    kind: "test".into(),
                    description: None,
                    icon: None,
                    id_prefixes: vec![],
                    capabilities: Capabilities {
                        search: true,
                        ..Default::default()
                    },
                    cover_headers: Vec::new(),
                    config: Vec::new(),
                    api_version: 1,
                    theme_color: None,
                    working: true,
                    broken_reason: None,
                    enabled: None,
                },
            }
        }
    }

    #[async_trait]
    impl MediaProvider for FailingSearcher {
        fn manifest(&self) -> &ProviderManifest {
            &self.manifest
        }

        async fn search(&self, _keyword: &str, _page: u32) -> Result<Page<MediaItem>> {
            Err(ProviderError::new(ErrorKind::Network, "假装网络失败"))
        }

        async fn resolve(&self, _id: &MediaId, _req: &PlayRequest) -> Result<Vec<StreamCandidate>> {
            Ok(vec![])
        }
    }

    /// 造 n 个各睡 delay_ms 的源
    fn slow_reg(n: usize, delay_ms: u64, peak: Arc<AtomicUsize>) -> Registry {
        let reg = Registry::new();
        let inflight = Arc::new(AtomicUsize::new(0));
        for i in 0..n {
            reg.register(Arc::new(SlowSearcher::new(
                &format!("s{i}"),
                delay_ms,
                inflight.clone(),
                peak.clone(),
            )));
        }
        reg
    }

    /// ★★★ 必须并发（12×100ms 串行 1200ms；6 路并发 ≈200ms）
    #[tokio::test(flavor = "multi_thread", worker_threads = 8)]
    async fn search_stream_runs_concurrently_not_serially() {
        let peak = Arc::new(AtomicUsize::new(0));
        /*
         * ★ 用 40 个源（不是 12）—— 这样**并发上限**与"源总数"拉得足够开，
         *   测试才能区分"有上限"和"全并发"。12 个源时若上限是 12，
         *   恰好跑满一批，`peak` 只能证明 >1，证明不了"有上限"。
         */
        let n_src = 40usize;
        let reg = slow_reg(n_src, 100, peak.clone());

        let t = std::time::Instant::now();
        let hits = Arc::new(AtomicUsize::new(0));
        let h = hits.clone();
        reg.search_all_stream("x", 1, move |o| {
            if o.is_ok() {
                h.fetch_add(1, Ordering::SeqCst);
            }
            true
        })
        .await;
        let ms = t.elapsed().as_millis();

        assert_eq!(hits.load(Ordering::SeqCst), n_src, "所有源都应命中");
        /*
         * ★ 阈值按"**串行**要 40×100ms=4000ms"来定，取 1500ms：
         *   远低于串行（能证明并发），又给 CI 调度留足余量（防 flaky）。
         *
         * ⚠️ 这里**不写死**"应该是几批"—— 并发上限是可调参数，
         *    写死批次数会把"调并发度"变成假回归（本项目踩过）。
         */
        assert!(
            ms < 1500,
            "★ 应该并发执行（{n_src}x100ms 串行要 4000ms，实测 {ms}ms）—— \
             若超时说明 Semaphore/JoinSet 被改回串行"
        );
        let peak_v = peak.load(Ordering::SeqCst);
        assert!(peak_v > 1, "★ 峰值并发应 >1（实测 {peak_v}）");
        /*
         * ★★ 核心不变式：**必须有上限**（不是 40 个全并发）。
         *    这里断言 peak < 源总数，而**不**断言某个具体数字 ——
         *    上限值可以按实测调整（我按数据从 6 调到了 12），
         *    但"有界"这个性质不能丢：无界并发会打爆目标站/被封 IP。
         */
        assert!(
            peak_v < n_src,
            "★★ 并发必须是**有界**的（实测峰值 {peak_v}，源总数 {n_src}）—— \
             若相等说明 Semaphore 上限没生效，变成了全并发（会打爆目标站）"
        );
    }

    /// ★★ 首个结果必须**立刻**回调，不能等一批跑完
    ///
    /// 守的是我第一版的错误：分批 `tokio::join!` 让首个结果
    /// 从 0.32s 退化到 **1.77s**（必须等本批最慢的源）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 8)]
    async fn search_stream_emits_first_result_immediately() {
        let reg = Registry::new();
        let inflight = Arc::new(AtomicUsize::new(0));
        let peak = Arc::new(AtomicUsize::new(0));
        // 快源 30ms + 5 个 800ms 的慢源 —— 分批实现会等 800ms 才回调
        reg.register(Arc::new(SlowSearcher::new(
            "fast",
            30,
            inflight.clone(),
            peak.clone(),
        )));
        for i in 0..5 {
            reg.register(Arc::new(SlowSearcher::new(
                &format!("slow{i}"),
                800,
                inflight.clone(),
                peak.clone(),
            )));
        }

        let t = std::time::Instant::now();
        let first = Arc::new(std::sync::Mutex::new(None::<u128>));
        let f = first.clone();
        reg.search_all_stream("x", 1, move |_o| {
            let mut g = f.lock().unwrap();
            if g.is_none() {
                *g = Some(t.elapsed().as_millis());
            }
            true
        })
        .await;

        let first_ms = first.lock().unwrap().unwrap_or(9999);
        assert!(
            first_ms < 300,
            "★★ 首个结果应**立刻**回调（fast 源 30ms），实测 {first_ms}ms —— \
             若接近 800ms 说明改成了分批等待（首个结果被最慢的同批源拖住）"
        );
    }

    /// ★★ 取消必须**立即**返回（不等剩余源）
    ///
    /// ⚠️ 设计要点：**必须有快源**，否则测的是"等第一个结果"而不是"取消"。
    ///    我第一版全用 2000ms 的源，得到 2013ms —— 那不是 bug，
    ///    是"第一个结果本来就要 2 秒才到"。这里改成：
    /// ```text
    /// 1 个 30ms 的源 + 11 个 3000ms 的源
    /// 期望：30ms 内拿到第一个事件 -> 取消 -> 立即返回（<300ms）
    /// 若没 abort：要等那 11 个跑完 ≈ 3000ms（6 路并发 = 2 批 = 6000ms）
    /// ```
    #[tokio::test(flavor = "multi_thread", worker_threads = 8)]
    async fn search_stream_cancel_returns_immediately() {
        let reg = Registry::new();
        let inflight = Arc::new(AtomicUsize::new(0));
        let peak = Arc::new(AtomicUsize::new(0));
        // ★ 一个快源保证"取消"发生在很早期
        reg.register(Arc::new(SlowSearcher::new(
            "quick",
            30,
            inflight.clone(),
            peak.clone(),
        )));
        for i in 0..11 {
            reg.register(Arc::new(SlowSearcher::new(
                &format!("slow{i}"),
                3000,
                inflight.clone(),
                peak.clone(),
            )));
        }

        let t = std::time::Instant::now();
        let n = Arc::new(AtomicUsize::new(0));
        let c = n.clone();
        reg.search_all_stream("x", 1, move |_o| {
            c.fetch_add(1, Ordering::SeqCst);
            false // ★ 第一个事件就取消
        })
        .await;
        let ms = t.elapsed().as_millis();

        assert_eq!(n.load(Ordering::SeqCst), 1, "取消后不该再有回调");
        assert!(
            ms < 300,
            "★★ 取消后应**立即**返回（实测 {ms}ms）—— \
             若接近 3000ms 说明没有 abort_all，剩余 11 个慢源还在跑"
        );
    }

    /// ★ `search_all`（一次性）与流式**共用内核**，也必须并发
    #[tokio::test(flavor = "multi_thread", worker_threads = 8)]
    async fn search_all_also_runs_concurrently() {
        let peak = Arc::new(AtomicUsize::new(0));
        // ★ 用 40 个源，让"串行(4000ms)"与"并发"差距足够大，判据才稳
        let reg = slow_reg(40, 100, peak.clone());

        let t = std::time::Instant::now();
        let r = reg.search_all("x", 1).await;
        let ms = t.elapsed().as_millis();

        assert_eq!(r.results.len(), 40, "所有源都应有结果");
        assert!(r.skipped.is_empty(), "没有失败源");
        assert!(ms < 1500, "★ search_all 也应并发（串行要 4000ms，实测 {ms}ms）");
    }

    /// ★ 失败隔离（并发后语义不变）
    #[tokio::test(flavor = "multi_thread", worker_threads = 8)]
    async fn search_all_error_isolation_survives_concurrency() {
        let reg = Registry::new();
        let inflight = Arc::new(AtomicUsize::new(0));
        let peak = Arc::new(AtomicUsize::new(0));
        reg.register(Arc::new(SlowSearcher::new(
            "ok1",
            10,
            inflight.clone(),
            peak.clone(),
        )));
        reg.register(Arc::new(SlowSearcher::new(
            "ok2",
            10,
            inflight.clone(),
            peak.clone(),
        )));
        reg.register(Arc::new(FailingSearcher::new("bad")));

        let r = reg.search_all("x", 1).await;
        assert_eq!(r.results.len(), 2, "两个好源仍应出结果（错误隔离）");
        assert_eq!(r.skipped.len(), 1, "坏源进 skipped");
        assert_eq!(r.skipped[0].0, "bad");
    }

}
