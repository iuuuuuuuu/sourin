//! JS 插件运行时 —— 把「外置 JS 文件」变成可用的 `MediaProvider`
//!
//! # 为什么做这个
//!
//! 原先 cctv / cycani 是**编译进程序**的 Rust 代码，用户看不到也改不了。
//! 现在把它们搬到外置 JS 文件，好处：
//!   · 用户能打开文件看「这个源是怎么写的」
//!   · 改一行不用重新编译
//!   · 别人能发布自己的插件（GitHub 导入）
//!
//! # 契约
//!
//! 详见 `research/插件API契约设计.md`。要点：
//!   · 脚本头部注释声明元信息（`@id` / `@name` / `@version`）
//!   · 脚本给 `globalThis.plugin` 赋一个对象，方法名对应 `MediaProvider` 的方法
//!   · 宿主注入 `host.http` / `host.store` / `host.crypto` / `host.log`
//!
//! # 实测得出的三条硬规则
//!
//! 1. **等 JS Promise 必须用 `async_with!` 宏** ——
//!    `ctx.with()` 不能返回 future（rquickjs 源码注释写明），
//!    而 `ctx.async_with()` 要手动 `Pin<Box<...>>`。宏是最好用的封装。
//!
//! 2. **熔断按「墙钟时间」而不是 tick 次数** ——
//!    第一版写「tick > 300 万次就中断」，实测**跑了 168 秒**才触发。
//!    tick 回调不是每条 VM 指令都调。改看时间后精确按预算终止。
//!
//! 3. **每次调用新建 Runtime** —— 实测建一个只要 **0.16 毫秒**，
//!    相对网络请求可忽略，换来最好的隔离性（插件状态不跨调用泄漏）。

use crate::model::*;
use crate::provider::*;
use async_trait::async_trait;
use rquickjs::function::Async;
use rquickjs::{async_with, AsyncContext, AsyncRuntime, Function, Object, Promise};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

/// 插件执行预算（毫秒）—— 防止死循环卡死应用
///
/// 实测：按 tick 计数的方式要 168 秒才触发，**必须按时间**。
/// 取 10 秒：正常插件调用（含网络）远小于此，死循环也能及时掐掉。
const SCRIPT_BUDGET_MS: u64 = 10_000;

/// 插件 HTTP 默认超时
const HTTP_TIMEOUT_SECS: u64 = 15;

// ─────────────────────────── 元信息 ───────────────────────────

/// 从脚本头部注释解析出的元信息
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct PluginMeta {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub version: String,
    #[serde(default)]
    pub author: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub homepage: String,
}

/// 解析脚本头部的 `@key value` 元信息
///
/// ⚠️ **必须全局扫描而不是按行首前缀匹配**。
/// 实测：真实写法常把多个 tag 放同一行 ——
/// `/** @name 央视网 @version 1.0.0 @author dsh @id cctv */`
/// 按行首匹配**一个都匹配不到**。
///
/// 值取到「下一个 `@` / 换行 / 注释结束符」为止。
pub fn parse_meta(src: &str) -> PluginMeta {
    // 只看开头 2KB（元信息约定在文件头部）
    let head: String = src.chars().take(2048).collect();

    let get = |key: &str| -> String {
        let tag = format!("@{key}");
        let Some(pos) = head.find(&tag) else {
            return String::new();
        };
        let rest = &head[pos + tag.len()..];
        let end = [
            rest.find('@'),
            rest.find('\n'),
            rest.find("*/"),
        ]
        .into_iter()
        .flatten()
        .min()
        .unwrap_or(rest.len());
        rest[..end].trim().to_string()
    };

    PluginMeta {
        id: get("id"),
        name: get("name"),
        version: get("version"),
        author: get("author"),
        description: get("description"),
        homepage: get("homepage"),
    }
}

/// 从插件源码里提取**上游接口地址**（只服务界面显示，不参与插件运行）
///
/// # 为什么需要它（Owner 缺陷 5）
///
/// > 你既然已经支持了 tvbox，那么就应该把所有的 tvbox 插件都还原成原本的
/// > 链接，而不是现在转换后的插件
///
/// ★ 事实是**链接从来没丢过** —— TVBox 转换器把原始接口逐字写进了生成的
///   `.js` 文件里（模板见 `tvbox.rs`），只是**界面从来没显示过**。
///   实测本机 28 个插件：22 个 `tvbox-convert` 的头部注释与正文
///   `const API` **逐字节相同**，6 个 `dsh` 里 2 个有 `const API`。
///
/// # 为什么只认头部注释的「上游接口」
///
/// ```text
/// 头部注释：` * 上游接口（苹果CMS v10）：http://tyyszy.com/api.php/provide/vod`
///   ⇒ 转换器专门写给人看的**来源说明**，22 个转换插件全有 ⇒ 认
///
/// 正文常量：`const API = 'https://api.bilibili.com'`
///   ⇒ 这是**接口地址**，不是来源 ⇒ ✗ 不认（2026-10-09 修掉的 bug）
/// ```
///
/// ⚠️ 曾经也认正文那条，结果手写插件的「接口地址」被当成了「安装来源」，
///    UI 据此把它判成「按链接安装的插件」⇒ 编辑框预填接口地址、
///    保存时当成链接去重新安装 ⇒ **覆盖坏用户的本地插件**。细节见函数体里的注释。
///
/// ★ 手写插件返回空串是**正确**的：它的来源就是用户自己写的，没有"来源链接"。
///   真正按链接安装的来源存在 `plugins/.meta/<id>.json` 的 `source_url` 里。
///
/// # ⚠️ 为什么不改 `parse_meta` 而是单开一个函数
///
/// `parse_meta` 的语义是「解析 `@key value` 形式的元信息」，它的结果进
/// `PluginMeta` 并参与插件注册。`上游接口` **不是** `@key`，塞进
/// `parse_meta` 会让「元信息解析」多一条隐式规则，将来改 tag 扫描逻辑时
/// 容易连坐。这里只读源码、只返回字符串，**零副作用**。
///
/// ⚠️ 只认 `http://` / `https://` 开头 —— 否则像
///    `const API = '/api.php/provide/vod'`（相对路径）这种会被当成链接显示，
///    用户复制出来是个**不能用的东西**。
pub fn upstream_of(src: &str) -> String {
    // ① 头部注释（只看开头 2KB，与 `parse_meta` 同一个约定）
    let head: String = src.chars().take(2048).collect();
    if let Some(i) = head.find("上游接口") {
        let rest = &head[i..];
        // 全角「：」是转换器写的；半角「:」兼容手写插件
        let start = match rest.find('：') {
            Some(p) => Some(p + '：'.len_utf8()),
            None => rest.find(':').map(|p| p + 1),
        };
        if let Some(p) = start {
            // 取到行尾，并容忍「行尾就是注释结束符 */」的写法
            let line = rest[p..].lines().next().unwrap_or("");
            let url = line.trim().trim_end_matches("*/").trim();
            if url.starts_with("http://") || url.starts_with("https://") {
                return url.to_string();
            }
        }
    }

    /*
     * ⚠️⚠️ 这里**故意**没有「正文 `const API` 回退」—— 那是 2026-10-09 修掉的 bug。
     *
     * 原来还有一条：找不到头部注释时，去正文找 `const API = 'https://…'` 当上游。
     * 但那个常量是**接口地址**，不是**安装来源**，两者根本不是一回事：
     * ```text
     * bilibili.js 正文第 91 行  const API = 'https://api.bilibili.com'
     *   ⇒ upstream = "https://api.bilibili.com"
     *   ⇒ 编辑对话框判成「链接型」⇒ 预填这个地址、类型锁死
     *   ⇒ 用户点保存会去拉 api.bilibili.com 当插件装 ⇒ **本地插件被覆盖坏**
     * ```
     * 手写插件（bilibili 就是）根本没有"安装来源"这个概念 ——
     * 它的来源是用户自己写的。宁可为空，也不能编一个。
     *
     * ★ 真正的安装来源在 `plugins/.meta/<id>.json` 的 `source_url`
     *   （见 `install_plugin` / `list_plugin_sources`），与这里无关。
     */

    String::new()
}

// ─────────────────────────── 熔断 ───────────────────────────

/// 生成一个「按墙钟时间」判断的中断处理器
///
/// 返回 `true` 时 QuickJS 会中断当前执行。
///
/// ⚠️ 必须是 `Send` —— 开了 rquickjs 的 `parallel` feature 后
/// `InterruptHandler` 要求 `Send`。当前实现只捕获一个 `Instant`，天然满足。
fn make_interrupt(deadline_ms: u64) -> impl FnMut() -> bool + Send + 'static {
    let start = std::time::Instant::now();
    move || start.elapsed().as_millis() as u64 > deadline_ms
}

// ─────────────────────────── 命名风格转换 ───────────────────────────
//
// ★ 契约承诺「插件写 camelCase，宿主自动转 snake_case」，这里就是那一层。
//
// 为什么不让 Rust 侧直接 `#[serde(rename_all = "camelCase")]`：
// 那些模型结构体**同时用于前后端通信**（Tauri 命令的返回值），
// 改 serde 命名会**一并改掉给前端的线上格式**，把已有界面全打挂。
// 所以转换只发生在「插件边界」这一层。

/// `categoryId` → `category_id`
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

/// `category_id` → `categoryId`
fn snake_to_camel(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut up = false;
    for c in s.chars() {
        if c == '_' {
            up = true;
        } else if up {
            out.push(c.to_ascii_uppercase());
            up = false;
        } else {
            out.push(c);
        }
    }
    out
}

/// 把插件返回的 JSON 转成 Rust 侧结构能吃的形态
///
/// 做两件事：
/// 1. **键名 camelCase → snake_case**（递归，含嵌套对象与数组元素）
/// 2. **`headers` 从对象转成键值对数组**
///    Rust 侧是 `Vec<(String, String)>`，而插件按契约写
///    `{ Referer: 'x' }` 这种对象 —— serde 会报
///    `invalid type: map, expected a sequence`
fn js_value_to_rust(v: serde_json::Value) -> serde_json::Value {
    match v {
        serde_json::Value::Object(map) => {
            let mut out = serde_json::Map::new();
            for (k, val) in map {
                let key = camel_to_snake(&k);
                // headers 特例：对象 → [[k, v], ...]
                let val = if key == "headers" {
                    match val {
                        serde_json::Value::Object(h) => serde_json::Value::Array(
                            h.into_iter()
                                .map(|(hk, hv)| {
                                    serde_json::Value::Array(vec![
                                        serde_json::Value::String(hk),
                                        hv,
                                    ])
                                })
                                .collect(),
                        ),
                        other => js_value_to_rust(other),
                    }
                } else {
                    js_value_to_rust(val)
                };
                out.insert(key, val);
            }
            serde_json::Value::Object(out)
        }
        serde_json::Value::Array(arr) => {
            serde_json::Value::Array(arr.into_iter().map(js_value_to_rust).collect())
        }
        other => other,
    }
}

/// 把 Rust 侧的值转成插件习惯的形态（反向）
///
/// 用在「宿主传给插件的参数」方向，如 `PlayRequest` → `resolve(id, req)`。
/// 插件作者写 `req.episodeId` 比 `req.episode_id` 自然。
fn rust_value_to_js(v: serde_json::Value) -> serde_json::Value {
    match v {
        serde_json::Value::Object(map) => {
            let mut out = serde_json::Map::new();
            for (k, val) in map {
                out.insert(snake_to_camel(&k), rust_value_to_js(val));
            }
            serde_json::Value::Object(out)
        }
        serde_json::Value::Array(arr) => {
            serde_json::Value::Array(arr.into_iter().map(rust_value_to_js).collect())
        }
        other => other,
    }
}

// ─────────────────────────── 插件 Provider ───────────────────────────

/// 一个由 JS 文件驱动的 Provider
///
/// `Debug` 是必需的（测试里 `unwrap_err()` 要求 `T: Debug`）。
/// 手动实现而不用 derive：**源码可能很长**，
/// derive 会把整个脚本打进日志，排查时反而看不清。
pub struct JsPluginProvider {
    manifest: ProviderManifest,
    /// 插件源码（每次调用新建 Runtime 时重新求值）
    source: String,
    /// 站点代理（插件通过 host.http 发的请求走它）
    proxy: Option<Arc<crate::proxy::ProxyStore>>,
    /// 插件私有数据目录（`host.store` 落盘位置）
    ///
    /// 由加载方（`load_plugins_hydrated`）注入 —— 模块本身不知道
    /// 应用数据目录在哪，这是有意的（便于测试时用临时目录）。
    data_dir: Option<std::path::PathBuf>,
}

impl std::fmt::Debug for JsPluginProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("JsPluginProvider")
            .field("id", &self.manifest.id)
            .field("name", &self.manifest.name)
            .field("source_bytes", &self.source.len())
            .finish()
    }
}

impl JsPluginProvider {
    /// ★ 剥掉 `"{provider}:"` 前缀，得到插件自己的 native id
    ///
    /// 宿主给插件返回的条目**加了前缀**（见 `prefix_media_ids`），
    /// 前端把带前缀的 id 传回来时（`detail` / `resolve` / `sources` /
    /// `episodes`），必须还原成插件认识的那个 id。
    ///
    /// ⚠️ **漏掉这一步的后果**（实测踩到）：
    /// 插件收到 `cctv:c899032a...` 却拿它当 pid 去请求，接口返回空，
    /// 于是详情页标题显示成一串 guid、剧集列表为空 ——
    /// 但**不报错**，看起来像「这个视频本来就没信息」，极难排查。
    ///
    /// 只剥自己那一份前缀：`cctv:xxx` → `xxx`；
    /// 其它形态（无前缀、别的 provider 前缀）原样返回。
    fn strip_prefix(&self, id: &str) -> String {
        let prefix = format!("{}:", self.manifest.id);
        id.strip_prefix(&prefix).unwrap_or(id).to_string()
    }

    /// 从脚本源码构建
    ///
    /// 会先解析元信息并校验 —— **不执行脚本**就能判断它是不是合法插件。
    ///
    /// ⚠️ 返回 `std::result::Result` 而不是 crate 的 `Result<T>` 别名 ——
    /// 加载阶段的错误是「文件格式问题」（字符串），不是运行时的
    /// `ProviderError`。用字符串让调用方（扫描目录）能直接把
    /// 「哪个文件、为什么失败」展示给用户。
    ///
    /// ⚠️ **能力位此时还拿不到** —— 插件把 `capabilities` 写在
    /// `globalThis.plugin` 里，要执行脚本才知道。
    /// 所以能力位默认全 false，由 `hydrate_capabilities()` 在注册前补齐。
    /// （**踩过**：默认给了 `vod: true` 而 `live/search` 留在 false，
    /// 导致直播页与搜索完全看不到这个源 —— registry 是按
    /// `manifest().capabilities.live` 过滤的。）
    /// resolve 的**第一个参数**该传什么（抽出来是为了可单测）
    ///
    /// # ★★★ 为什么要有这个函数（Owner 报的 bug）
    ///
    /// > 播放第二集,实际还是第一集,这是bug
    ///
    /// tvbox 转换插件的 detail() 里剧集 id **就是剧集地址**
    /// （`154.js:369  id: e.url`），而它的 resolve(id) 只认第一个参数、
    /// **完全忽略 req**（`154.js:392`，见 resolve 里的长注释）。
    /// 宿主原来传 id.native（条目 id，如 "150758"）⇒ 插件去查详情、
    /// 取 eps[0] ⇒ 无论点第几集都返回第一集。
    ///
    /// ⇒ **episode_id 明确是 http(s) URL 时，用它当第一个参数。**
    ///
    /// # ⚠️ 判据必须精确（不许无条件替换）
    ///
    /// 别的插件用 episode_id 表达**别的东西** —— 最典型的是 cycani，
    /// 它拿它当 section_id（纯数字 51463）。一律替换会把次元城打坏。
    /// ⇒ 只有 `starts_http` 为真才替换；否则**原样**返回条目 id
    ///   （= 改动前行为，逐字相同）。
    fn resolve_first_arg(&self, id: &MediaId, req: &PlayRequest) -> String {
        match req.episode_id.as_deref() {
            Some(ep) if crate::tvbox::starts_http(ep) => ep.to_string(),
            _ => self.strip_prefix(&id.native),
        }
    }
    pub fn from_source(source: &str) -> std::result::Result<Self, String> {
        let meta = parse_meta(source);
        if meta.id.is_empty() {
            return Err("插件缺少 @id（头部注释里必须有，如 `@id cctv`）".into());
        }
        if meta.name.is_empty() {
            return Err(format!("插件 {} 缺少 @name", meta.id));
        }

        let manifest = ProviderManifest {
            id: meta.id.clone(),
            name: meta.name.clone(),
            version: if meta.version.is_empty() {
                "1.0.0".into()
            } else {
                meta.version.clone()
            },
            kind: "js".into(),
            description: if meta.description.is_empty() {
                None
            } else {
                Some(meta.description.clone())
            },
            icon: None,
            id_prefixes: vec![format!("{}:", meta.id)],
            /*
             * 能力位此时**只能是保守值**。
             *
             * 插件把 capabilities 写在 `globalThis.plugin` 里，
             * 不执行脚本读不到。若在这里写死 `vod: true`，
             * 而 registry 是按 `manifest().capabilities.live` 过滤的
             * （见 `live_all` / `search_all`），
             * 结果就是**直播页与搜索页完全看不到这个源**（实测踩到）。
             *
             * 所以全部默认 false，注册前用 `hydrate_capabilities()` 补齐。
             */
            capabilities: Capabilities::default(),
            /*
             * 配置项同样要**执行脚本才拿得到**（插件写在 `globalThis.plugin.config`），
             * 由 `hydrate_capabilities()` 一并填充。
             */
            cover_headers: Vec::new(),
            config: Vec::new(),
            api_version: 1,
            theme_color: None,
            working: true,
            broken_reason: None,
            // 启用状态由 `list_providers` 在出口处统一填（Provider 不关心）
            enabled: None,
        };

        Ok(Self {
            manifest,
            source: source.to_string(),
            proxy: None,
            data_dir: None,
        })
    }

    /// 注入插件私有数据目录（`host.store` 的落盘位置）
    pub fn with_data_dir(mut self, dir: std::path::PathBuf) -> Self {
        self.data_dir = Some(dir);
        self
    }

    /// 把插件声明的 `config` 装进 manifest
    ///
    /// # ⚠️ 为什么不能直接 `serde_json::from_value`
    ///
    /// `call_js` 的出口会对**所有**对象键做 `camel_to_snake` 转换。
    /// 那对能力位（`loginRequired` → `login_required`）是对的，
    /// 但对**用户配置的键名是灾难**：
    ///
    /// ```text
    /// 插件声明  key: 'proxyUrl'
    /// 到达这里  变成  proxy_url
    /// 插件再读  host.config.get('proxyUrl')  → 永远读不到！
    /// ```
    ///
    /// 而且这个转换**对非 ASCII 键会写坏**（项目已知：
    /// `camel_to_snake('UP主')` → `_u_p主`，不可逆）。
    ///
    /// 所以配置项的 `key` 必须在**插件源码里原样保留**。
    /// 做法：不用转换后的值，而是重新从插件源码里读一遍？
    /// —— 那太脆弱。
    ///
    /// **采用的办法**：让插件把 key 也写成 ASCII snake_case 就
    /// 不会被转换（`camel_to_snake` 对已经是 snake 的串是幂等的）。
    /// 同时在契约文档里写明这个约束，并在加载时**检测**
    /// 「声明里出现了被转换过的键」并给出明确警告。
    ///
    /// 见 `research/插件API契约设计.md` 的「配置键命名」一节。
    fn hydrate_config(&mut self, cfg: &serde_json::Value) {
        let Some(arr) = cfg.as_array() else {
            if !cfg.is_null() {
                log::warn!(
                    "插件 {} 的 config 不是数组，已忽略",
                    self.manifest.id
                );
            }
            return;
        };

        let mut fields: Vec<crate::model::ConfigField> = Vec::new();
        let mut warnings: Vec<String> = Vec::new();

        for item in arr {
            match serde_json::from_value::<crate::model::ConfigField>(item.clone()) {
                Ok(mut f) => {
                    /*
                     * 检测「键被 camel_to_snake 改过」的迹象。
                     *
                     * 判据：key 里含 `_` 但其前后是小写字母+数字
                     * （即形如 `proxy_url`），而插件源码里写的多半是
                     * `proxyUrl`。我们无法 100% 确定，所以只**提示**
                     * 而不改 —— 因为 snake_case 本身是允许的写法。
                     */
                    if f.key.contains('_') && f.key.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_') {
                        warnings.push(format!(
                            "配置项「{}」的 key 是 `{}`。\
                             ⚠️ 若你源码里写的是驼峰（如 `proxyUrl`），\
                             它已被宿主转成蛇形 —— 请把源码里的 key 也改成蛇形，\
                             否则 `host.config.get('proxyUrl')` 读不到。",
                            f.label, f.key
                        ));
                    }

                    f.sanitize(&mut warnings);
                    // 去掉重复 key（后者覆盖前者，但只保留一个）
                    if fields.iter().any(|x| x.key == f.key) {
                        warnings.push(format!("配置项 key「{}」重复，已忽略后一个", f.key));
                        continue;
                    }
                    fields.push(f);
                }
                Err(e) => warnings.push(format!("配置项解析失败（已跳过）: {e}")),
            }
        }

        if !fields.is_empty() {
            log::info!(
                "插件 {} 声明了 {} 项配置",
                self.manifest.id,
                fields.len()
            );
        }
        for w in &warnings {
            log::warn!("插件 {} 的配置声明有问题：{w}", self.manifest.id);
        }

        self.manifest.config = fields;
    }

    /// ★ 执行插件脚本，把它的 `capabilities` 读进 manifest
    ///
    /// **必须在注册进 Registry 之前调用** —— `live_all()` / `search_all()`
    /// 都按 `manifest().capabilities.*` 过滤，能力位不对的话
    /// 直播页与搜索页会看不到这个源。
    ///
    /// 失败时不报错（保持保守默认值）：能列出分类但仍声明不了能力，
    /// 总比整个插件加载失败好。
    pub async fn hydrate_capabilities(&mut self) {
        /*
         * ★ 一次调用同时取 capabilities / config / coverHeaders
         *
         * 为什么要合并：`call_js` 每次都要建一个 QuickJS 运行时并执行
         * 整个插件脚本（实测有几百毫秒）。分成多次调用等于白跑几遍。
         */
        let json = match self
            .call_js(
                "({ capabilities: plugin.capabilities ?? {}, \
                   config: plugin.config ?? [], \
                   coverHeaders: plugin.coverHeaders ?? null })",
            )
            .await
        {
            Ok(j) => j,
            Err(e) => {
                log::warn!("插件 {} 能力位读取失败（按默认值）: {}", self.manifest.id, e.message);
                return;
            }
        };

        let Ok(v) = serde_json::from_str::<serde_json::Value>(&json) else {
            return;
        };

        // ── 抓封面需要的请求头 ──
        //
        // ⚠️ 读的键名是 **snake_case** 的 `cover_headers` ——
        // `call_js` 出口已统一做过 camelCase → snake_case（与能力位同一原因）。
        //
        // ⚠️ 另外：`js_value_to_rust` 只对**名为 `headers`** 的键做
        // 「对象 → 键值对数组」特例，`coverHeaders` **不走那个特例**。
        // 所以插件必须直接写成数组：`coverHeaders: [['Referer','https://…']]`
        if let Some(h) = v.get("cover_headers") {
            match serde_json::from_value::<Vec<(String, String)>>(h.clone()) {
                Ok(list) if !list.is_empty() => {
                    log::info!(
                        "插件 {} 声明了 {} 个封面请求头",
                        self.manifest.id,
                        list.len()
                    );
                    self.manifest.cover_headers = list;
                }
                Ok(_) => {}
                Err(e) => log::warn!(
                    "插件 {} 的 coverHeaders 格式不对（应为 [[名, 值], ...]）：{e}",
                    self.manifest.id
                ),
            }
        }

        // ── 配置项（先做，因为它与 capabilities 独立）──
        if let Some(cfg) = v.get("config") {
            self.hydrate_config(cfg);
        }

        let Some(caps) = v.get("capabilities") else {
            return;
        };

        let flag = |key: &str| caps.get(key).and_then(|b| b.as_bool()).unwrap_or(false);

        /*
         * ★★ 提前把"这个源是否支持登录"取出来（2026-09-25，task-38）
         *
         * # 为什么不能等到下面再读
         *
         * 下面有 `let c = &mut self.manifest.capabilities;` —— 那是个
         * **可变借用**。而"运行时探测 canAutoLogin"要调 `self.call_js(...)`
         * （`&self` 不可变借用）。两者**不能共存**：
         * ```text
         * error[E0502]: cannot borrow `*self` as immutable
         *              because it is also borrowed as mutable
         * ```
         * ⇒ 所以在可变借用**之前**把需要的两个布尔值取出来（它们就是 `bool`，Copy）。
         */
        let supports_login = flag("login_required") || flag("login_supported");

        /*
         * ⚠️ 这里读的键名是 **snake_case**，不是插件源码里写的 camelCase。
         *
         * 因为 `call_js` 出口已经统一做过 camelCase → snake_case 转换
         * （见 `js_value_to_rust`）。插件写 `loginRequired`，
         * 到这里已经变成 `login_required`。
         *
         * **实测踩过**：第一版按 `loginRequired` 读，永远读到 false，
         * 于是 cycani 的 `loginRequired: true` 完全没生效 ——
         * 表现是「界面上不显示登录入口」「会话状态是 not_required」，
         * 用户根本没法登录这个源。
         */
        /*
         * ★★★ 运行时探测 `canAutoLogin`（2026-09-25，task-38）
         *
         * ⚠️ **必须在 `let c = &mut self.manifest.capabilities;` 之前做** ——
         *    `c` 是可变借用，而探测要 `self.call_js(..)`（不可变借用），
         *    同一作用域里共存会 `error[E0502]`。
         *    所以先把探测结果存进 `probed_auto_login`，再进借用区。
         *
         * 详见下面（写回处）那段长注释：为什么需要运行时兜底。
         */
        let declared_auto_login = flag("can_auto_login");
        let mut probed_auto_login = false;

        /*
         * ⚠️ 先把声明值取到**局部变量**里再探测 ——
         *    `c` 是 `&mut self.manifest.capabilities`（可变借用），
         *    而探测要 `self.call_js(...)`（不可变借用），两者不能共存。
         *    读成 bool（Copy）之后这个借用就不再需要了；
         *    探测完再写回 `c`。
         */
        if !declared_auto_login {
            /*
             * ★ 只在**可能有关**时才探测：必须支持登录。
             *
             * 不设这个门的话，25 个没有登录能力的插件（api/ffj/iptv/…）
             * 每次加载都要白跑一次 JS 求值 —— 纯浪费。
             */
            if supports_login {
                match self
                    .call_js("(plugin.canAutoLogin ? plugin.canAutoLogin() : false)")
                    .await
                {
                    Ok(v) if v == "true" => {
                        probed_auto_login = true;
                        log::info!(
                            "插件 {} 未声明 canAutoLogin，但**运行时探测为真** —— \
                             按其实现为准（声明可能只是没跟上）",
                            self.manifest.id
                        );
                    }
                    Ok(_) => { /* 探测为假：方法不存在 / 返回 false —— 正常 */ }
                    Err(e) => {
                        /*
                         * ★ 纪律 ③：探测失败要留痕。
                         *
                         * 不记的话，将来"某个插件探测失败"就是**静默的假 false** ——
                         * 用户又回到"看到验证码却说不出为什么"。
                         */
                        log::warn!(
                            "插件 {} 的 canAutoLogin 探测失败，按 false 处理: {}",
                            self.manifest.id,
                            e.message
                        );
                    }
                }
            }
        }


        let c = &mut self.manifest.capabilities;
        c.vod = flag("vod");
        c.live = flag("live");
        c.epg = flag("epg");
        c.search = flag("search");
        c.login_required = flag("login_required");
        c.multi_source = flag("multi_source");
        c.server_side_history = flag("server_side_history");
        c.favorites = flag("favorites");
        c.timeshift = flag("timeshift");
        c.danmaku = flag("danmaku");

        /*
         * ★★ 登录三项（2026-09-20 新增）—— **必须在这里逐个赋，不能只加字段**
         *
         * 这个函数是**逐字段**读的（不是整体 `serde::from_value`），
         * 所以往 `Capabilities` 结构体加字段**不会**自动生效 ——
         * 实测踩到：加了 `login_supported` 但插件侧一直是 false，
         * 表现是「B站 声明了 loginSupported: true，登录入口却不出现」。
         *
         * ⚠️ 键名同理是 snake_case（`call_js` 已做过 camelCase 转换）。
         */
        c.login_supported = flag("login_supported");
        c.login_hint = caps
            .get("login_hint")
            .and_then(|h| h.as_str())
            .map(|s| s.to_string());
        /*
         * ⚠️ `login_needs_username` 的**默认值是 true**（不是 false）——
         *    老插件没声明这一项时要保持原有行为（显示账号框）。
         *    用 `flag()`（默认 false）会把所有源的账号框都隐藏掉。
         */
        c.login_needs_username = caps
            .get("login_needs_username")
            .and_then(|b| b.as_bool())
            .unwrap_or(true);

        /*
         * ★ 扫码登录（2026-09-21）
         *
         * 与上面三项同一个坑：这个函数是**逐字段**读的，
         * 加了结构体字段**不会**自动生效，必须在这里显式赋值。
         * 忘了写的话表现是「插件声明了 loginQrSupported: true，
         * 登录弹窗却没有扫码页签」—— 且不报任何错。
         *
         * ⚠️ 默认 false（老插件没有这个能力）。
         */
        c.login_qr_supported = flag("login_qr_supported");

        /*
         * ★★★ 能用保存的凭据自动重登（2026-09-25，task-38）
         *
         * # 两层来源：「声明」或「运行时探测」（**取或**）
         *
         * ```text
         * ① 声明     插件写 `capabilities.canAutoLogin: true`
         *            → 零开销（这里就是读它）
         * ② 运行时探测 直接问插件 `canAutoLogin()` 方法
         *            → 兜底，见下面「为什么必须有兜底」
         * ```
         *
         * # ★★★ 为什么必须有运行时兜底（实测发现的关键问题）
         *
         * 声明**不一定送得到用户手里**。实测：
         * ```text
         * repo    rust/sourin_core/plugins/cycani.js     17882 B  声明在
         * deployed %APPDATA%\...\plugins\cycani.js       17457 B  声明**不在**
         * ```
         * 根因：`cycani.js`（和 `cctv.js`）**从来不由程序投放** ——
         * `state.rs` 只有 `seed_demo_plugin` / `seed_iptv_plugin` 两个，
         * 而那里自己的注释就写着：
         * > 但**没有** `iptv.js` —— 因为 `cctv.js` / `cycani.js` 都是**人工放进去**的
         *
         * ⇒ 所以「等插件声明」= **等一次永远不会发生的插件更新**
         *   （插件是人工投放的，没有升级通道）
         * ⇒ 只靠声明，用户**永远**看不到「正在自动重新登录」，
         *   Owner 报的那句「还提示 验证码」原封不动。
         *
         * ★ 但**运行时方法**在用户那份插件里**是存在的**
         *   （`cycani.js` L309 `async canAutoLogin()`）——
         *   直接问它就能立刻拿到正确答案。
         *
         * # 语义：声明是"缓存"，实现是"真相"
         *
         * ```text
         * 声明 = 实现的镜像（可能过期/缺失）
         * 实现 = 真相
         * ⇒ 两者都在时以**实现**为准；声明只是"省一次调用"的优化
         * ```
         * 所以这里是 `声明 || 探测`：已声明的插件**零额外开销**（短路）。
         *
         * # ⚠️ 三条纪律（Lead 明确要求）
         *
         * ```text
         * ① 探测**必须容错**：抛异常 / 方法不存在 / 超时 → 一律当 **false**
         *    （不能当 true —— 否则显示"正在自动重新登录"然后失败，
         *      比原来那句通用文案**更糟**：从"误导"变成"撒谎"）
         * ② 探测**只在这里做一次**（插件加载时），**不进 `session_state`**
         *    ⇒ 读会话状态的路径零额外开销（那是高频路径）
         * ③ 探测失败要**可观测**（log::warn）——
         *    否则"某个插件探测失败"会变成**静默的假 false**，回到今天的问题
         * ```
         */
        /*
         * ★ 声明 或 探测（取或）—— 探测已在**借用 `c` 之前**做完，
         *   结果放在 `probed_auto_login` 里（见上面那段长注释）。
         */
        /*
         * ══════════════════════════════════════════════════════════════
         * ★★ 实测开销（2026-09-25 实测，n=15，**部署版真实插件**）
         * ══════════════════════════════════════════════════════════════
         *
         * 见 `tests/zz_t38_perf.rs`（可复现）。中位数：
         * ```text
         * 基线（不触发探测）        中位数 = 1.461 ms
         * 带探测（缺声明 → 走探测） 中位数 = 3.453 ms
         * ★ 探测净开销              中位数 ≈ **2 ms / 插件**
         * ```
         *
         * # 为什么这个代价可以接受
         *
         * ```text
         * ① 它发生在**插件加载时**（本函数由 `load_plugins_hydrated` 调用，
         *    每个插件**一次**）—— 不是每次请求
         * ② 它被**门控**限制：只有 `login_required || login_supported`
         *    的插件才会走探测（见上面的 if）
         * ```
         * ⇒ 总代价 = **「有登录能力的插件数」× 2 ms**，
         *    **不是** × 全部插件数（门控正是为此）。
         *    实测本机 27 个插件里只有 2 个有登录能力（cycani / bilibili）
         *    ⇒ 约 **4 ms 一次性**，一次进程生命周期只付一次。
         *
         * ⚠️ **绝不能**把这段探测搬到 `can_auto_login()` 或 `session_state()` ——
         *    那两个在**读会话状态**时被反复调用（设置页每次刷新都调），
         *    2 ms/次 就完全不可接受了。
         *    本文件里 `plugin.canAutoLogin` 的求值**只允许出现在本函数里**，
         *    `test/probe_cost_documented_test.dart` 有断言守着这一点。
         */
        c.can_auto_login = declared_auto_login || probed_auto_login;

        log::info!(
            "插件 {} 能力位: vod={} live={} epg={} search={} timeshift={} \
             login={} qr={} autoLogin={}",
            self.manifest.id,
            c.vod,
            c.live,
            c.epg,
            c.search,
            c.timeshift,
            c.login_required,
            c.login_qr_supported,
            c.can_auto_login
        );
    }

    pub fn with_proxy(mut self, proxy: Arc<crate::proxy::ProxyStore>) -> Self {
        self.proxy = Some(proxy);
        self
    }

    /// ★ 核心：在 JS 里执行一次插件方法
    ///
    /// `expr` 是求值表达式，形如 `plugin.home()`。
    /// 返回 JS 侧 JSON.stringify 后的字符串。
    ///
    /// # ⚠️ 传进来的表达式**必须整体加括号**（如果含三元运算符）
    ///
    /// `call_js` 内部会把它拼进 `await <expr>`。而 JS 里
    /// **`await` 比三元运算符 `?:` 结合更紧**，于是：
    ///
    /// ```js
    /// await plugin.rank ? plugin.rank("1",1) : fallback
    /// // 被解析成：
    /// (await plugin.rank) ? plugin.rank("1",1) : fallback
    /// //            ↑ await 的是**函数对象**（真值）
    /// //              于是返回一个**未 await 的 Promise**
    /// ```
    ///
    /// 而 `JSON.stringify(Promise)` 得到 `{}` —— 报错会是
    /// `missing field 'items' at line 1 column 2`（`{}` 的第 2 列），
    /// **完全看不出是优先级问题**（实测踩过）。
    ///
    /// 正解：`(plugin.rank ? plugin.rank(...) : fallback)`
    async fn call_js(&self, expr: &str) -> Result<String> {
        let rt = AsyncRuntime::new()
            .map_err(|e| ProviderError::new(ErrorKind::Other, format!("创建 JS 运行时失败: {e}")))?;

        // ★ 熔断：按墙钟时间（tick 计数方式实测要 168 秒才触发）
        rt.set_interrupt_handler(Some(Box::new(make_interrupt(SCRIPT_BUDGET_MS))))
            .await;

        let ctx = AsyncContext::full(&rt)
            .await
            .map_err(|e| ProviderError::new(ErrorKind::Other, format!("创建 JS 上下文失败: {e}")))?;

        // 注入 host API
        let proxy = self.proxy.clone();
        let plugin_id = self.manifest.id.clone();
        // 未注入时退回「当前目录下的 .plugin-data」（测试场景）；
        // 正常运行时由 `with_data_dir` 指定应用数据目录
        let data_dir = self
            .data_dir
            .clone()
            .unwrap_or_else(|| std::path::PathBuf::from(".plugin-data"));
        ctx.with(move |ctx| {
            let g = ctx.globals();

            // host.http
            let http = Object::new(ctx.clone())?;
            let px = proxy.clone();
            http.set(
                "get",
                Function::new(
                    ctx.clone(),
                    Async(move |url: String, headers: Option<Object>| {
                        let px = px.clone();
                        // ★ 必须在 async 块**之前**把 Object 转成 owned 的 HashMap ——
                        //   `Object<'js>` 借用上下文，跨 await 会报 lifetime 错误
                        let h = headers.map(|o| object_to_headers(&o)).unwrap_or_default();
                        async move { do_http(&px, "GET", &url, &h, None).await }
                    }),
                )?,
            )?;
            let px2 = proxy.clone();
            http.set(
                "post",
                Function::new(
                    ctx.clone(),
                    Async(move |url: String, body: Option<String>, headers: Option<Object>| {
                        let px = px2.clone();
                        let h = headers.map(|o| object_to_headers(&o)).unwrap_or_default();
                        async move { do_http(&px, "POST", &url, &h, body).await }
                    }),
                )?,
            )?;

            /*
             * ★★ `host.http.raw` —— 带**响应头**的请求（2026-09-20 新增）
             *
             * # 为什么需要（扫码登录的前提）
             *
             * `get`/`post` 只返回响应体。而 B站 扫码登录成功时，
             * 凭据是通过 **`Set-Cookie` 响应头**下发的 —— 不在 body 里。
             * 没有这个 API，插件就拿不到登录态。
             *
             * # 返回结构
             * ```js
             * const r = await host.http.raw('GET', url, { headers })
             * // r = { status: 200, body: '…', setCookie: ['SESSDATA=…; Path=/', …] }
             * ```
             *
             * ⚠️ `setCookie` 是**数组**：Cookie 的 `Expires` 里含逗号，
             *    拼成一个串再切分会有歧义（见 `HttpFull` 的说明）。
             *
             * ⚠️ 新增 API 而不是改 `get`/`post` ——
             *    那 26 个现有插件都按「返回字符串」写的，
             *    改返回值会**全部坏掉**。
             */
            let px3 = proxy.clone();
            http.set(
                "raw",
                Function::new(
                    ctx.clone(),
                    Async(move |method: String, url: String, headers: Option<Object>| {
                        let px = px3.clone();
                        let h = headers.map(|o| object_to_headers(&o)).unwrap_or_default();
                        async move {
                            let r = do_http_full(&px, &method, &url, &h, None).await;
                            /*
                             * 手搓 JSON —— 与其它出口一致（都用 serde_json::json!），
                             * 避免手写转义出错。
                             */
                            serde_json::json!({
                                "status": r.status,
                                "body": r.body,
                                "setCookie": r.set_cookie,
                            })
                            .to_string()
                        }
                    }),
                )?,
            )?;
            g.set("host_http", http)?;

            /*
             * host.store —— 插件私有存储（按插件 id 隔离）
             *
             * 用途：存 token、cookie、缓存。每个插件一个文件
             * （`plugins/.data/<id>.json`），互相看不见。
             *
             * ★ 同步实现（不是 Async）：
             *   本地文件读写是微秒级的，套一层 Promise 只会让插件
             *   写起来更啰嗦（每个 get 都要 await）。宿主侧一次性
             *   读进内存，之后就是内存查表。
             *
             * ⚠️ 这里**不走系统钥匙串**：插件的 token 是插件自己的凭据，
             *   与应用级凭据（如 cycani 的登录态）分开存放，
             *   避免插件互相读到对方的敏感值。
             */
            let store = Object::new(ctx.clone())?;
            let data_dir = data_dir.clone();
            let pid_for_store = plugin_id.clone();

            let dir_get = data_dir.clone();
            let pid_get = pid_for_store.clone();
            store.set(
                "get",
                Function::new(ctx.clone(), move |key: String| -> Option<String> {
                    store_read(&dir_get, &pid_get, &key)
                })?,
            )?;

            let dir_set = data_dir.clone();
            let pid_set = pid_for_store.clone();
            store.set(
                "set",
                Function::new(ctx.clone(), move |key: String, value: String| {
                    let _ = store_write(&dir_set, &pid_set, &key, Some(value));
                })?,
            )?;

            let dir_del = data_dir.clone();
            let pid_del = pid_for_store.clone();
            store.set(
                "remove",
                Function::new(ctx.clone(), move |key: String| {
                    let _ = store_write(&dir_del, &pid_del, &key, None);
                })?,
            )?;
            g.set("host_store", store)?;

            /*
             * ★ host.config —— 插件读取**用户在界面上配置的值**
             *
             * 这是「1080P / 代理 / 登录都做在插件里」的最后一环：
             * 插件声明 config（宿主渲染界面）→ 用户填 → 插件用这里读。
             *
             * # 为什么读的时候要**现查磁盘**
             *
             * `call_js` 每次都会新建 QuickJS 运行时并重跑插件脚本，
             * 所以每次调用都重新读一遍是**正确且必要**的 ——
             * 否则用户在界面上改了配置，插件要等下次重启才看到。
             *
             * # 与 host.store 的区别
             *
             * · `host.store.get(k)`  → 返回**字符串**（插件自己序列化）
             * · `host.config.get(k)` → 返回**原生类型**（布尔/数字/字符串），
             *   因为配置是界面控件直接写进去的
             */
            let cfg_dir = data_dir.clone();
            let cfg_pid = plugin_id.clone();
            let config = Object::new(ctx.clone())?;
            {
                // 每次 clone —— 闭包要 `move`，共用一个变量会被第一个闭包吃掉
                let d = cfg_dir.clone();
                let p = cfg_pid.clone();
                config.set(
                    "get",
                    Function::new(ctx.clone(), move |key: String| -> rquickjs::Result<String> {
                        /*
                         * 返回 **JSON 文本**而不是 JS 值。
                         *
                         * 原因：rquickjs 的 `Function` 返回值要能转成 Rust 类型，
                         * 而配置值类型不定（bool/number/string）。统一走
                         * JSON 字符串最省事，插件侧由 `host.config.parse()`
                         * 或直接按需转型。
                         *
                         * ⚠️ 但这样插件写起来别扭，所以下面还提供了
                         * `getBool` / `getNumber` / `getString` 三个便捷方法。
                         */
                        Ok(match config_read(&d, &p, &key) {
                            Some(v) => serde_json::to_string(&v).unwrap_or_else(|_| "null".into()),
                            None => "null".into(),
                        })
                    })?,
                )?;
            }
            // 便捷读取：省得插件每次 JSON.parse
            {
                let d = cfg_dir.clone();
                let p = cfg_pid.clone();
                config.set(
                    "getBool",
                    Function::new(ctx.clone(), move |key: String, def: bool| {
                        config_read(&d, &p, &key)
                            .and_then(|v| v.as_bool())
                            .unwrap_or(def)
                    })?,
                )?;
            }
            {
                let d = cfg_dir.clone();
                let p = cfg_pid.clone();
                config.set(
                    "getNumber",
                    Function::new(ctx.clone(), move |key: String, def: f64| {
                        config_read(&d, &p, &key)
                            .and_then(|v| v.as_f64())
                            .unwrap_or(def)
                    })?,
                )?;
            }
            {
                let d = cfg_dir.clone();
                let p = cfg_pid.clone();
                config.set(
                    "getString",
                    Function::new(ctx.clone(), move |key: String, def: String| {
                        config_read(&d, &p, &key)
                            .and_then(|v| v.as_str().map(String::from))
                            .unwrap_or(def)
                    })?,
                )?;
            }
            {
                // 一次拿全部（插件想问"用户到底配了什么"时用）
                let d = cfg_dir.clone();
                let p = cfg_pid.clone();
                config.set(
                    "all",
                    Function::new(ctx.clone(), move || -> rquickjs::Result<String> {
                        let map = store_load(&d, &p);
                        let mut out = serde_json::Map::new();
                        for (k, v) in map {
                            if let Some(real) = k.strip_prefix(CONFIG_PREFIX) {
                                out.insert(real.to_string(), v);
                            }
                        }
                        Ok(serde_json::to_string(&out).unwrap_or_else(|_| "{}".into()))
                    })?,
                )?;
            }
            g.set("host_config", config)?;

            // host.log
            let log = Object::new(ctx.clone())?;
            let pid = plugin_id.clone();
            for level in ["debug", "info", "warn", "error"] {
                let pid2 = pid.clone();
                let lv = level.to_string();
                log.set(
                    level,
                    Function::new(ctx.clone(), move |msg: String| {
                        match lv.as_str() {
                            "error" => log::error!("[plugin:{pid2}] {msg}"),
                            "warn" => log::warn!("[plugin:{pid2}] {msg}"),
                            "debug" => log::debug!("[plugin:{pid2}] {msg}"),
                            _ => log::info!("[plugin:{pid2}] {msg}"),
                        }
                    })?,
                )?;
            }
            g.set("host_log", log)?;

            /*
             * 组装成契约里的 `host` 对象
             *
             * ⚠️ 这里**必须把 options 透传下去**。
             * 第一版写的是 `get: (u, o) => host_http.get(u)` ——
             * 把第二个参数（headers）**丢掉了**，
             * 于是插件的 `Referer` 从来没发出去过（央视接口要它）。
             * 这种 bug 不报错、只是偶尔拿到错误页，极难查。
             */
            ctx.eval::<(), _>(
                r#"
                globalThis.host = {
                  http: {
                    get: (url, options) => host_http.get(url, (options && options.headers) || null),
                    post: (url, body, options) => host_http.post(
                      url,
                      typeof body === 'string' ? body : JSON.stringify(body ?? null),
                      (options && options.headers) || null,
                    ),
                    /*
                     * ★★ 带**响应头**的请求（2026-09-20 新增，为扫码登录）
                     *
                     * 返回 **JSON 文本**（与 host.config.get 一致的做法：
                     * QuickJS 里跨边界传对象不如传字符串稳），插件要
                     * 自己 JSON.parse：
                     *
                     *   const r = JSON.parse(await host.http.raw('GET', url, { headers }))
                     *   // r = { status, body, setCookie: [...] }
                     *
                     * ⚠️ `setCookie` 是数组 —— Cookie 的 Expires 里含逗号，
                     *    拼成一个串再切分会有歧义。
                     */
                    raw: (method, url, options) => host_http.raw(
                      method,
                      url,
                      (options && options.headers) || null,
                    ),
                  },
                  log: host_log,
                  store: host_store,
                  /*
                   * ★ 用户配置（插件声明 → 宿主渲染界面 → 用户填 → 这里读）
                   *
                   * `get(k)` 返回 **JSON 文本或 'null'**（因为值类型不定），
                   * 所以优先用下面三个便捷方法，它们已经处理好默认值：
                   *
                   *   host.config.getBool('proxy', false)
                   *   host.config.getNumber('quality', 720)
                   *   host.config.getString('proxyUrl', '')
                   */
                  config: {
                    get: (k) => host_config.get(k),
                    getBool: (k, d) => host_config.getBool(k, d),
                    getNumber: (k, d) => host_config.getNumber(k, d),
                    getString: (k, d) => host_config.getString(k, d),
                    all: () => host_config.all(),
                  },
                  util: {
                    urlEncode: (s) => encodeURIComponent(String(s)),
                    urlDecode: (s) => decodeURIComponent(String(s)),
                    sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
                  },
                };
                "#,
            )?;
            Ok::<_, rquickjs::Error>(())
        })
        .await
        .map_err(|e| ProviderError::new(ErrorKind::Other, format!("注入 host API 失败: {e}")))?;

        // 执行插件脚本 + 调用目标方法
        let source = self.source.clone();
        let expr = expr.to_string();
        let out = async_with!(ctx => |ctx| {
            /*
             * 1) 加载插件本体
             *
             * ⚠️ **必须在单独的一步里做，且失败要能与其他错误区分开**。
             *
             * 实测踩到（编辑插件保存时）：语法错误（如括号不配对）
             * 会让 `eval` 抛 QuickJS 自身的异常 —— 而下游的错误分类
             * 把「QuickJS 异常」一律当成**中断超时**，
             * 于是用户看到「保存失败：插件执行超时（超过 10000 ms）」，
             * 完全看不出是**语法写错了**。
             *
             * 所以这里先求值一次；失败就直接返回 `SyntaxError`，
             * 不进下面的 Promise 流程。
             */
            match ctx.eval::<(), _>(source.as_str()) {
                Ok(()) => {}
                Err(_) => {
                    // 取回真实错误消息（rquickjs 的 Error 不带消息）
                    let msg = ctx
                        .catch()
                        .as_exception()
                        .and_then(|e| e.message())
                        .unwrap_or_else(|| "语法错误".to_string());
                    return Err(rquickjs::Error::new_from_js_message(
                        "SyntaxError",
                        "plugin",
                        msg,
                    ));
                }
            }

            /*
             * 2) 调方法并等 Promise
             *
             * ★ 关键：在 **JS 侧**把异常转成带标记的返回值，
             * 而不是让异常穿透到 Rust。
             *
             * 为什么：rquickjs 把 JS 抛的错统一变成 `Error::Exception`，
             * **消息体丢失**（实测只拿到字符串 "Exception"）——
             * 那样 `map_js_error()` 完全没法按前缀分类，
             * 用户也看不到「插件到底为什么失败」。
             *
             * 这里 catch 住真实消息再带出来。
             */
            let code = format!(
                r#"(async () => {{
                    try {{
                        const r = await {expr};
                        return JSON.stringify({{ ok: true, data: r ?? null }});
                    }} catch (e) {{
                        const msg = (e && e.message) ? e.message : String(e);
                        return JSON.stringify({{ ok: false, error: msg }});
                    }}
                }})()"#
            );
            let p: Promise = ctx.eval(code.as_str())?;
            p.into_future::<String>().await
        })
        .await;

        let raw = match out {
            Ok(s) => s,
            Err(e) => {
                /*
                 * 走到这里有三类原因，**必须分开报**（实测都踩过）：
                 *
                 * 1. **语法错误** —— 脚本求值就失败了（括号不配对等）。
                 *    我们上面主动包成了 `SyntaxError`，`{e}` 里带真实消息。
                 *    ⚠️ 不区分的话会被误报成「执行超时」，
                 *    用户去查超时原因，永远查不到（其实是写错了）。
                 *
                 * 2. **执行超时** —— QuickJS 被中断处理器掐断，
                 *    抛的是 `Exception generated by QuickJS`，
                 *    消息里**没有** "interrupted" 字样，
                 *    第一版按 `contains("interrupted")` 判断导致误报。
                 *
                 * 3. **其他加载失败** —— 如 host API 注入失败。
                 *
                 * 判据顺序很重要：先看语法错误的前缀，再看 `is_exception()`。
                 */
                let msg = format!("{e}");

                return Err(if msg.contains("SyntaxError") {
                    /*
                     * 从 rquickjs 的包装里取出**真正的 JS 报错**。
                     *
                     * 原始消息形如：
                     * ```
                     * Error converting from js 'SyntaxError' into type 'plugin':
                     * Unexpected token 'const'
                     * ```
                     * 冒号**之后**那段才是用户要看的。
                     * 前面那段是 rquickjs 的内部细节，对用户毫无意义
                     * （而且会让人以为是插件的什么 "plugin" 类型出了问题）。
                     */
                    let detail = msg
                        .rsplit_once(':')
                        .map(|(_, rest)| rest.trim())
                        .filter(|s| !s.is_empty())
                        .unwrap_or(msg.as_str());
                    ProviderError::new(
                        ErrorKind::Parse,
                        format!("语法错误，未保存：{detail}"),
                    )
                } else if e.is_exception() {
                    ProviderError::new(
                        ErrorKind::Other,
                        format!("插件执行超时（超过 {SCRIPT_BUDGET_MS} ms 被强制终止）"),
                    )
                } else {
                    ProviderError::new(ErrorKind::Other, format!("插件加载失败: {msg}"))
                });
            }
        };

        // 拆开 JS 侧包的 { ok, data } / { ok, error }
        let wrapped: serde_json::Value = serde_json::from_str(&raw)
            .map_err(|e| ProviderError::parse(format!("插件返回值无法解析: {e}")))?;

        if wrapped.get("ok").and_then(|b| b.as_bool()) != Some(true) {
            let msg = wrapped
                .get("error")
                .and_then(|s| s.as_str())
                .unwrap_or("插件未返回错误信息");
            return Err(map_js_error(msg));
        }

        let data = wrapped
            .get("data")
            .cloned()
            .unwrap_or(serde_json::Value::Null);

        // ★ 命名风格 + headers 形态转换（见模块顶部说明）
        let mut rust = js_value_to_rust(data);

        // ★ 给插件返回的条目补上 provider 前缀
        //
        // 契约承诺「插件只写自己的 id，宿主自动加前缀」——
        // 插件作者不该关心 `MediaId` 是 `"cctv:xxx"` 这种形态。
        self.prefix_media_ids(&mut rust);

        serde_json::to_string(&rust)
            .map_err(|e| ProviderError::parse(format!("转换返回值失败: {e}")))
    }

    /// 递归给 `id` 字段补上 `"{provider}:"` 前缀
    ///
    /// 只处理**形如媒体条目**的对象（含 `id` 且同时有 `title`），
    /// 避免误伤 `Section.id` / `PlaySource.code` 这类普通标识 ——
    /// 它们只是字符串，不是 `MediaId`。
    ///
    /// 已经带前缀的不重复加（插件可能自己拼了，或数据来自往返）。
    fn prefix_media_ids(&self, v: &mut serde_json::Value) {
        let prefix = format!("{}:", self.manifest.id);

        match v {
            serde_json::Value::Object(map) => {
                /*
                 * ★ 只给**媒体条目**加前缀，不能误伤剧集（实测踩到）
                 *
                 * `MediaItem` 的特征是「有 `id`，且有 `title`/`cover`」。
                 * 但 `Episode` 也长这样 —— `{id, title, order}` ——
                 * 于是剧集 id 被加了前缀变成 `cycani:51463`，
                 * 前端把它放进 `PlayRequest.episode_id` 传回来，
                 * 插件拿它当数字 id 用 → 服务端报
                 * `bind uri "section_id": parsing "cycani:51463": invalid syntax`
                 * （Owner 实测报的错）。
                 *
                 * 判据：`Episode` **一定带 `order`**（契约里是必填），
                 * 而 `MediaItem` 没有这个字段。所以见到 `order` 就跳过。
                 *
                 * 另一条判据：`PlaySource` 有 `code`/`count`，
                 * `Section` 有 `source` —— 都不该加前缀，也一并排除。
                 */
                let is_episode = map.contains_key("order");
                let is_source = map.contains_key("code") && map.contains_key("count");
                let is_section = map.contains_key("source");

                let looks_like_item = !is_episode
                    && !is_source
                    && !is_section
                    && map.contains_key("id")
                    && (map.contains_key("title") || map.contains_key("cover"));

                if looks_like_item {
                    if let Some(serde_json::Value::String(id)) = map.get_mut("id") {
                        /*
                         * ★★ 判据必须是「有没有**本插件的**前缀」，而不是「含不含冒号」
                         *
                         * # 这是一个真 bug（Owner 报「B站的这些点开，显示没有路由」）
                         *
                         * 原实现是 `if !id.contains(':')` —— 本意是"已带前缀的不重复加"，
                         * 但**冒号不等于前缀**：
                         *
                         * ```text
                         * 插件返回 id = "av:BV1u9ew6yEEP"      ← B 站插件的内部命名空间
                         * contains(':') == true
                         *   → 判定"已有前缀"，跳过
                         *   → 前端拿到 "av:BV1u9ew6yEEP"
                         *   → splitKey 切第一个冒号 → provider = "av"
                         *   → 后端 route("av") 找不到 → 「无法路由: av:BV1u9ew6yEEP」
                         * ```
                         *
                         * 对照：央视插件返回 `1f6ed843…`（不含冒号）→ 正常加上 `cctv:`
                         * 前缀 → 一直正常。**所以只有 B 站坏，而且坏得很隐蔽。**
                         *
                         * # 为什么"含冒号"这个判据根本不成立
                         *
                         * 插件的 id **允许含冒号**（契约里只要求非空字符串）。
                         * 用"含冒号"去猜"有没有加过前缀"，等于要求插件作者
                         * **永远不要在 id 里用冒号** —— 而这条约束从来没写进契约，
                         * 插件作者也不可能知道。
                         *
                         * 正解：直接比对**本插件的前缀**。这也是幂等的 ——
                         * 无论调多少次都不会重复加。
                         */
                        if !id.starts_with(&prefix) {
                            *id = format!("{prefix}{id}");
                        }
                    }
                }

                for (_, child) in map.iter_mut() {
                    self.prefix_media_ids(child);
                }
            }
            serde_json::Value::Array(arr) => {
                for child in arr.iter_mut() {
                    self.prefix_media_ids(child);
                }
            }
            _ => {}
        }
    }
}

/// 把 JS 异常映射成 `ProviderError`
///
/// 插件按契约用前缀声明错误类型：
/// `unauthorized:` / `not_found:` / `unsupported:` / `network:`
fn map_js_error(msg: &str) -> ProviderError {
    let lower = msg.to_lowercase();
    if lower.contains("unauthorized") || lower.contains("401") {
        ProviderError::unauthorized("需要登录或登录已失效")
    } else if lower.contains("not_found") || lower.contains("404") {
        ProviderError::new(ErrorKind::NotFound, msg.to_string())
    } else if lower.contains("unsupported") {
        ProviderError::unsupported(msg.to_string())
    } else if lower.contains("network") || lower.contains("timeout") {
        ProviderError::network(msg.to_string())
    } else {
        ProviderError::new(ErrorKind::Other, format!("插件报错: {msg}"))
    }
}

/// 插件 HTTP 请求（走站点代理配置）
///
/// 返回**响应文本**，失败返回 `__ERR__<原因>` 前缀串。
/// ⚠️ 为什么不用 `Result`（让 JS 侧 throw）：
/// rquickjs 抛出的异常在 Rust 侧只剩 `Error::Exception`（消息丢失），
/// 所以错误信息走返回值这条通道，由插件的 `getJson` 判断前缀再抛。
async fn do_http(
    proxy: &Option<Arc<crate::proxy::ProxyStore>>,
    method: &str,
    url: &str,
    headers: &HashMap<String, String>,
    body: Option<String>,
) -> String {
    let client = match proxy {
        Some(px) => px.client_for("plugin", None).unwrap_or_else(|_| default_client()),
        None => default_client(),
    };

    let mut req = if method == "POST" {
        client.post(url)
    } else {
        client.get(url)
    };

    /*
     * ★ POST 且调用方没指定 Content-Type 时，默认 `application/json`
     *
     * 实测踩过：reqwest 的 `.body(String)` 默认发 `text/plain`，
     * 而几乎所有 JSON 接口（次元城、苹果 CMS 系）都要求
     * `application/json` —— 服务端会报
     * `Username is a required field` 这种**看起来像参数没传**的错误，
     * 实际是 body 根本没被解析。这类问题极难从报错里看出来。
     *
     * 调用方显式给了 Content-Type 就尊重它（有站点要 form-urlencoded）。
     */
    let has_ct = headers
        .keys()
        .any(|k| k.eq_ignore_ascii_case("content-type"));
    if method == "POST" && !has_ct {
        req = req.header("Content-Type", "application/json");
    }
    for (k, v) in headers {
        req = req.header(k, v);
    }
    if let Some(b) = body {
        req = req.body(b);
    }

    match req.send().await {
        Ok(r) => {
            let status = r.status();
            match r.text().await {
                Ok(t) => {
                    if status.is_success() {
                        t
                    } else {
                        // 把 HTTP 状态带出去，插件可据此判断 401/404 并抛对应的前缀错误
                        format!("__ERR__HTTP {status}: {}", t.chars().take(200).collect::<String>())
                    }
                }
                Err(e) => format!("__ERR__读取响应失败: {e}"),
            }
        }
        Err(e) => format!("__ERR__请求失败: {e}"),
    }
}

/// HTTP 响应（**含响应头**）—— 给 `host.http.raw` 用
///
/// # 为什么需要它（2026-09-20，为扫码登录加）
///
/// [`do_http`] 只返回响应体，**响应头被丢掉**。
/// 而 B站 扫码登录成功时，凭据是通过 **`Set-Cookie` 响应头**下发的：
/// ```text
/// POST/GET passport.bilibili.com/x/passport-login/web/qrcode/poll
///   ← Set-Cookie: SESSDATA=…; bili_jct=…; DedeUserID=…
/// ```
/// 那些值**不在 body 里** —— 所以光有 `do_http` 读不到登录态。
///
/// ⚠️ `set_cookie` 必须是**数组**，不能拼成一个字符串 ——
///    Cookie 的 `Expires` 属性里含逗号（`Expires=Wed, 21 Oct…`），
///    拼接后再按逗号切分会产生歧义。reqwest 的 `get_all` 已经帮我们
///    按正确的边界切好了。
pub struct HttpFull {
    pub status: u16,
    pub body: String,
    /// 每一条 `Set-Cookie`（原样，未解析）
    pub set_cookie: Vec<String>,
}

/// 与 [`do_http`] 相同，但**保留响应头**
pub async fn do_http_full(
    proxy: &Option<Arc<crate::proxy::ProxyStore>>,
    method: &str,
    url: &str,
    headers: &HashMap<String, String>,
    body: Option<String>,
) -> HttpFull {
    let client = match proxy {
        Some(px) => px.client_for("plugin", None).unwrap_or_else(|_| default_client()),
        None => default_client(),
    };

    let mut req = if method.eq_ignore_ascii_case("POST") {
        client.post(url)
    } else {
        client.get(url)
    };

    let has_ct = headers
        .keys()
        .any(|k| k.eq_ignore_ascii_case("content-type"));
    if method.eq_ignore_ascii_case("POST") && !has_ct {
        req = req.header("Content-Type", "application/json");
    }
    for (k, v) in headers {
        req = req.header(k, v);
    }
    if let Some(b) = body {
        req = req.body(b);
    }

    match req.send().await {
        Ok(r) => {
            let status = r.status().as_u16();
            /*
             * ⚠️ 必须在 `.text()` **之前**取头 —— `text()` 会消费响应。
             */
            let set_cookie: Vec<String> = r
                .headers()
                .get_all(reqwest::header::SET_COOKIE)
                .iter()
                .filter_map(|v| v.to_str().ok())
                .map(|s| s.to_string())
                .collect();
            let body = r.text().await.unwrap_or_default();
            HttpFull {
                status,
                body,
                set_cookie,
            }
        }
        Err(e) => HttpFull {
            status: 0,
            body: format!("__ERR__请求失败: {e}"),
            set_cookie: Vec::new(),
        },
    }
}

/// 把 `null` / `"null"` 解析成 `None`，其余解析成 `Some(Session)`
fn parse_optional_session(json: &str, what: &str) -> Result<Option<Session>> {
    if json == "null" || json.is_empty() {
        return Ok(None);
    }
    serde_json::from_str::<Session>(json)
        .map(Some)
        .map_err(|e| ProviderError::parse(format!("{what}() 返回格式不符: {e}")))
}

/// 插件私有存储的读写（`plugins/.data/<id>.json`）
///
/// 一个插件一个文件，键值都是字符串 —— 插件自己决定怎么序列化。
/// 读失败/文件损坏一律当「没有这个键」（不报错）：插件存储是**尽力而为**的，
/// 不该因为它坏了就整个插件用不了。
fn store_path(dir: &std::path::Path, plugin_id: &str) -> std::path::PathBuf {
    dir.join(format!("{plugin_id}.json"))
}

/// 读插件数据文件（**故意不取 `STORE_LOCK`**）
///
/// ⚠️ 不取锁是**有意的**，不是漏了：
/// ```text
/// ① store_write / config_write 会先调它再写回 —— 若这里也取锁，
///    就是同一把**非可重入** Mutex 的自我死锁（整个数据层永久挂住）。
/// ② 读侧的正确性由 store_write_atomic 的"临时文件 + rename"保证：
///    rename 原子 ⇒ 读到的要么旧、要么新，不会是半截。
/// ③ 读是高频路径（每次 call_js 都可能读 config）——
///    加锁会让所有插件的读串行化，纯亏。
/// ```
/// ⚠️ 坏文件 / 空文件一律兜底成**空 map**。调用方据此得到"没有凭据" ——
///    方向是**安全**的（宁可让用户重新登录，也不要拿半截数据去发请求）。
fn store_load(dir: &std::path::Path, plugin_id: &str) -> serde_json::Map<String, serde_json::Value> {
    let p = store_path(dir, plugin_id);
    std::fs::read_to_string(&p)
        .ok()
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default()
}

fn store_read(dir: &std::path::Path, plugin_id: &str, key: &str) -> Option<String> {
    store_load(dir, plugin_id)
        .get(key)
        .and_then(|v| v.as_str())
        .map(String::from)
}

/// 插件数据文件的**进程内写锁**（2026-09-25，task-38）
///
/// # 为什么需要（真存在的数据丢失窗口）
///
/// `store_write` / `config_write` 都是 **读-改-写**：
/// ```text
/// ① 读整个 JSON 进内存
/// ② 改一个键
/// ③ 把**整个** JSON 写回
/// ```
/// 而 `store`（`session` / `credentials`）与 `config`（`cfg:*`）
/// **共用同一个文件**（见下面 `CONFIG_PREFIX` 的说明）。
///
/// 于是两个调用交错时（都是 async 任务，`call_js` 每次新建运行时）
/// 会出现**丢失更新**：
/// ```text
/// 任务 A（写 session）        任务 B（写 credentials）
/// ─────────────────────      ─────────────────────
/// ① 读 {session: 旧}
///                            ① 读 {session: 旧, credentials: 旧}
/// ② 改 session
///                            ② 改 credentials
/// ③ 写 {session: 新}   ← 丢了 credentials
///                            ③ 写 {session: 旧!, credentials: 新}
///                                   ↑ ↑ 把 A 刚写的 session 覆盖回**旧值**
/// ```
/// 表现：**刚登录完 token 又变回旧的**（用户看到"登录了但马上又失效"）。
///
/// # 为什么是全局一把锁而不是按插件分
///
/// ```text
/// ① 同一个插件的数据才可能撞（不同插件是不同文件）——
///    但按插件分锁要一张 HashMap<PathBuf, Mutex>，而**地图本身也要锁**，
///    复杂度上去了，收益只是"不同插件能并行写"。
/// ② 写盘本身是微秒级（几十 KB 的 JSON），串行化完全无感。
/// ③ 这个文件的并发度本来就极低（用户点登录/改配置才写）。
/// ⇒ 全局一把：简单、不会错。**真出现性能问题再按插件分。**
/// ```
///
/// ⚠️ 这只是**进程内**锁。同一个数据目录被**两个进程**打开时（理论上
///    不该发生，但用户可能双击两次）仍会互相覆盖 —— 那需要文件锁，
///    超出本任务范围。这里只消掉**同一进程内**的交错。
static STORE_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// 插件数据文件的**进程内写锁**（2026-09-25，task-38）
///
/// # 为什么需要（真存在的数据丢失窗口）
///
/// `store_write` / `config_write` 都是 **读-改-写**：
/// ```text
/// ① 读整个 JSON 进内存
/// ② 改一个键
/// ③ 把**整个** JSON 写回
/// ```
/// 而 `store`（`session` / `credentials`）与 `config`（`cfg:*`）
/// **共用同一个文件**（见下面 `CONFIG_PREFIX` 的说明）。
///
/// 两个调用交错时会**丢失更新**：
/// ```text
/// 任务 A（写 session）        任务 B（写 credentials）
/// ─────────────────────      ─────────────────────
/// ① 读 {session: 旧}
///                            ① 读 {session: 旧, credentials: 旧}
/// ② 改 session
///                            ② 改 credentials
/// ③ 写 {session: 新}
///                            ③ 写 {session: 旧, credentials: 新}
///                                   ↑ 把 A 刚写的**新 session 覆盖回旧值**
/// ```
/// 表现：**刚登录完 token 又变回旧的** → 用户看到"登录了但马上又失效"。
///
/// # 为什么是全局一把锁
///
/// 写盘是微秒级（几十 KB JSON），而写操作本身极低频
/// （用户点登录 / 改配置才发生）⇒ 串行化完全无感。
/// 按插件分锁要维护 `HashMap<PathBuf, Mutex>`，而**那张表自己也要锁**，
/// 复杂度换来的只是"不同插件能并行写"—— 不值。
fn store_guard() -> std::sync::MutexGuard<'static, ()> {
    /*
     * ⚠️ `lock()` 返回 `Err` 只发生在**前一个持锁者 panic** 时（中毒）。
     *    那种情况下数据文件可能写了一半 —— 但我们**不该因此让插件彻底不能用**：
     *    继续执行（`unwrap_or_else(|e| e.into_inner())`）比"整个插件数据层瘫痪"好。
     *    这里不 unwrap：宁可拿到中毒的锁也要让用户能继续操作。
     */
    STORE_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

/// **原子**写插件数据文件（先写临时文件再 rename）
///
/// # 为什么要原子替换（不只是"好看"）
///
/// `std::fs::write` 是**截断后写** —— 执行期间另一个**不取锁**的读操作
/// （`store_read` / `resolved_config`）会读到**写了一半的 JSON**，
/// `serde_json::from_str` 失败 → `store_load` 兜底成**空 map**。
///
/// 后果很隐蔽：
/// ```text
/// 读到的 {credentials: …} 变成 {} → can_auto_login() 返回 false
///                                → UI 说「可能需要验证码，请手动完成」
/// ```
/// 也就是**本轮用户报的那个现象**，成因却是"读到半截文件"。
///
/// `rename` 在同一文件系统内是**原子**的 ⇒ 读侧要么看到旧内容、
/// 要么看到新内容，**永远不会看到半截**。
///
/// ⚠️ 临时文件用 `.json.tmp` 扩展名 —— **不是** `.js`，
///    所以 `load_plugins` 扫 `*.js` 时不会把它当插件（否则会报一堆坏插件）。
fn store_write_atomic(path: &std::path::Path, body: &str) -> std::result::Result<(), String> {
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, body).map_err(|e| format!("写入临时文件失败: {e}"))?;
    /*
     * ⚠️ Windows 的 `rename` 在**目标已存在**时会失败（不像 POSIX 会覆盖）——
     *    所以先删目标。删与改名之间有极小窗口（目标短暂不存在），
     *    读侧那时拿到"文件不存在" → 同样兜底成空 map。
     *    这比"读到半截 JSON"好：**不存在**是明确的，半截是**欺骗性**的。
     */
    let _ = std::fs::remove_file(path);
    std::fs::rename(&tmp, path).map_err(|e| format!("替换数据文件失败: {e}"))
}

fn store_write(
    dir: &std::path::Path,
    plugin_id: &str,
    key: &str,
    value: Option<String>,
) -> std::result::Result<(), String> {
    // ★ 读-改-写**全程持锁**（否则并发写互相覆盖，见 STORE_LOCK）
    let _g = store_guard();
    let mut map = store_load(dir, plugin_id);
    match value {
        Some(v) => {
            map.insert(key.to_string(), serde_json::Value::String(v));
        }
        None => {
            map.remove(key);
        }
    }
    std::fs::create_dir_all(dir).map_err(|e| format!("创建插件数据目录失败: {e}"))?;
    let body = serde_json::to_string_pretty(&map).map_err(|e| e.to_string())?;
    // ★ 原子替换（免得读侧拿到半截 JSON，见 store_write_atomic）
    store_write_atomic(&store_path(dir, plugin_id), &body)
        .map_err(|e| format!("写入插件数据失败: {e}"))
}

// ─────────────────────── 插件配置的读写 ───────────────────────

/*
 * 配置与 `host.store` **共用同一个数据文件**，但值的 JSON 类型不同：
 *
 *   · `host.store`  —— 值一律是**字符串**（插件自己序列化）
 *   · `host.config` —— 值是**原生 JSON**（布尔 / 数字 / 字符串），
 *                      因为界面控件要按类型渲染与回写
 *
 * 为什么共用文件：一个插件的数据集中在一处，备份/排查/清理都简单。
 * 键名加 `cfg:` 前缀避免与 store 的键撞车。
 */
const CONFIG_PREFIX: &str = "cfg:";

/// 读一个配置值（返回原生 JSON）
fn config_read(
    dir: &std::path::Path,
    plugin_id: &str,
    key: &str,
) -> Option<serde_json::Value> {
    store_load(dir, plugin_id)
        .get(&format!("{CONFIG_PREFIX}{key}"))
        .cloned()
}

/// 写一个配置值
fn config_write(
    dir: &std::path::Path,
    plugin_id: &str,
    key: &str,
    value: serde_json::Value,
) -> std::result::Result<(), String> {
    // ★ 与 store_write **共用同一把锁** —— 它们写的是**同一个文件**
    let _g = store_guard();
    let mut map = store_load(dir, plugin_id);
    map.insert(format!("{CONFIG_PREFIX}{key}"), value);
    std::fs::create_dir_all(dir).map_err(|e| format!("创建插件数据目录失败: {e}"))?;
    let body = serde_json::to_string_pretty(&map).map_err(|e| e.to_string())?;
    store_write_atomic(&store_path(dir, plugin_id), &body)
        .map_err(|e| format!("写入插件数据失败: {e}"))
}

/// 读出某插件的**全部**配置（已填默认值）
///
/// 这是给界面用的：用户没改过的项也要显示默认值，
/// 否则界面上是一堆空控件，用户不知道本来是什么。
pub fn resolved_config(
    dir: &std::path::Path,
    fields: &[crate::model::ConfigField],
    plugin_id: &str,
) -> serde_json::Map<String, serde_json::Value> {
    let mut out = serde_json::Map::new();
    for f in fields {
        let v = config_read(dir, plugin_id, &f.key).unwrap_or_else(|| f.effective_default());
        out.insert(f.key.clone(), v);
    }
    out
}

/// 写多个配置值（只接受**已声明**的键 —— 防止插件/前端塞垃圾）
///
/// 返回真正被写入的键数。
pub fn config_write_many(
    dir: &std::path::Path,
    fields: &[crate::model::ConfigField],
    plugin_id: &str,
    values: &serde_json::Map<String, serde_json::Value>,
) -> std::result::Result<usize, String> {
    let mut n = 0;
    for (k, v) in values {
        let Some(field) = fields.iter().find(|f| &f.key == k) else {
            // ⚠️ 未声明的键**直接忽略**而不是报错：
            // 插件升级后删掉某个配置项时，旧值不该让写入整体失败
            log::debug!("插件 {plugin_id} 收到未声明的配置键 {k}，已忽略");
            continue;
        };
        if !config_value_ok(field, v) {
            return Err(format!("配置项「{}」的值类型不对", field.label));
        }
        config_write(dir, plugin_id, k, v.clone())?;
        n += 1;
    }
    Ok(n)
}

/// 值是否符合该控件的类型
///
/// **必须在写盘前校验** —— 否则界面传个字符串给 `switch`，
/// 插件读到的就不是布尔，会出现"开关打开了但没生效"这种难查的问题。
fn config_value_ok(field: &crate::model::ConfigField, v: &serde_json::Value) -> bool {
    match field.kind.as_str() {
        "switch" => v.is_boolean(),
        "number" => {
            if !v.is_number() {
                return false;
            }
            let n = v.as_f64().unwrap_or(0.0);
            field.min.map(|m| n >= m).unwrap_or(true) && field.max.map(|m| n <= m).unwrap_or(true)
        }
        "select" => v
            .as_str()
            .map(|s| field.options.iter().any(|o| o.value == s))
            .unwrap_or(false),
        "text" | "password" => v.is_string(),
        // `info` 不接收值
        _ => false,
    }
}


/// 把 JS 对象转成请求头表（字符串值，非字符串跳过）
fn object_to_headers(o: &Object) -> HashMap<String, String> {
    let mut m = HashMap::new();
    for entry in o.props::<String, rquickjs::Value>() {
        if let Ok((k, v)) = entry {
            if let Some(s) = v.as_string().and_then(|s| s.to_string().ok()) {
                m.insert(k, s);
            }
        }
    }
    m
}

fn default_client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
        .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/143.0.0.0")
        .build()
        .expect("build http client")
}

// ─────────────────────────── MediaProvider 实现 ───────────────────────────

#[async_trait]
impl MediaProvider for JsPluginProvider {
    fn manifest(&self) -> &ProviderManifest {
        &self.manifest
    }

    /// 首页分区 —— 调插件的 `plugin.home()`
    async fn home(&self) -> Result<Vec<Section>> {
        let json = self.call_js("plugin.home()").await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("home() 返回格式不符: {e}")))
    }

    /// 分类列表
    ///
    /// ★ `categories` 在这个生态里有**两种合法形态**，两种都要认：
    ///   · **方法** —— `async categories() { ... }`（内置 `cctv.js` 这样写）
    ///   · **数据数组** —— `categories: [ { id, name }, ... ]`
    ///     （`tools/tvbox-convert.mjs` 生成的插件这样写 —— 分类是
    ///      转换时探测到的固定清单，苹果CMS 的分类很少变）
    ///
    /// # 症状（Owner 报的「tvbox源的确实没做完」里剩下的那一处）
    /// ```text
    /// get_categories("360")  =>  {"error":"插件报错: not a function"}
    /// => 浏览页顶部的分类切换栏是空的（列表本身照常显示）
    /// ```
    /// 实测：22 个转换来的 TVBox 源**全部**报这一条；而内置 `cctv`
    /// （`categories` 是方法）在同一台宿主上取到 8 个真分类 => 链是好的。
    /// 取证：`.probe/t359_vod_final.py`（`RESULT pass=14 fail=0`）。
    ///
    /// # 为什么用三元而不是 try/catch
    /// 与 `rank()` / `epg()` 同一条纪律（见本文件 L2213 的长注释）：
    /// **先判形态再取值**，让「方法存在但内部报错」原样透出，
    /// 不被「捕获所有错误都返回空数组」吞掉。
    ///
    /// ⚠️ 这**不是**我们这次改写引入的回归：旧宿主
    ///    `src-tauri/src/plugins/mod.rs:1562` 是同一行 `plugin.categories()`。
    async fn categories(&self) -> Result<Vec<Category>> {
        let json = self
            .call_js(
                "(typeof plugin.categories === 'function' ? plugin.categories() : (plugin.categories || []))",
            )
            .await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("categories() 返回格式不符: {e}")))
    }

    /// 分类内容
    async fn list(&self, req: ListRequest) -> Result<Page<MediaItem>> {
        let expr = format!(
            "plugin.list({})",
            serde_json::json!({
                "categoryId": req.category_id,
                "page": req.page,
            })
        );
        let json = self.call_js(&expr).await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("list() 返回格式不符: {e}")))
    }

    /// 搜索
    async fn search(&self, keyword: &str, page: u32) -> Result<Page<MediaItem>> {
        let expr = format!(
            "plugin.search({}, {})",
            serde_json::to_string(keyword).unwrap_or_else(|_| "\"\"".into()),
            page
        );
        let json = self.call_js(&expr).await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("search() 返回格式不符: {e}")))
    }

    /// ★ 榜单内容（首页 `SectionSource::Rank` 区块用）
    ///
    /// ⚠️ **漏掉这个方法会静默出错**（实测踩到）：
    /// 次元城的 `home()` 声明了两个 `SectionSource::Rank` 区块
    /// （「TV番组榜」「剧场番组榜」），插件里也实现了 `rank()`，
    /// 但宿主没桥接 → 走 trait 默认实现 → 返回
    /// `Unsupported("该源不支持榜单")` → **首页那两个区块永远空白**，
    /// 而插件作者完全不知道为什么自己写的 rank 没被调用。
    async fn rank(&self, rank_id: &str, page: u32) -> Result<Page<MediaItem>> {
        let expr = format!(
            "(plugin.rank ? plugin.rank({}, {}) : Promise.reject(new Error('unsupported: 该源不支持榜单')))",
            serde_json::to_string(rank_id).unwrap_or_else(|_| "\"\"".into()),
            page
        );
        let json = self.call_js(&expr).await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("rank() 返回格式不符: {e}")))
    }

    /// 详情
    async fn detail(&self, id: &MediaId) -> Result<MediaDetail> {
        let expr = format!(
            "plugin.detail({})",
            serde_json::to_string(&self.strip_prefix(&id.native))
                .unwrap_or_else(|_| "\"\"".into())
        );
        let json = self.call_js(&expr).await?;
        let mut d: MediaDetail = serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("detail() 返回格式不符: {e}")))?;

        /*
         * ★ 把返回的 id 归一化成带前缀的形态。
         *
         * 插件不知道前缀的存在（契约里它只写自己的 id），
         * 所以它回传的 `id` 可能是**裸的**（没有冒号）——
         * 而 `MediaId` 的反序列化要求 `provider:native` 形态，
         * 裸 id 会直接报「非法 MediaId」。
         *
         * 这里统一重建：provider 用本插件的 id，native 用剥掉前缀后的值。
         */
        let raw = d.id.as_key();
        let native = self.strip_prefix(&raw);
        d.id = MediaId::new(&self.manifest.id, native);
        Ok(d)
    }

    /// ★ 按播放源取剧集
    ///
    /// ⚠️ 漏桥接的后果（与 `rank` 同类）：trait 默认实现会去调 `detail()`，
    /// 而插件可能**只为某个特定源实现了 `episodes()`**（如 cycani 的
    /// `/videos/{id}/sections?player_code=`）—— 用 detail 的结果代替，
    /// 用户切换线路后会看到**上一个线路的剧集**。
    async fn episodes(&self, id: &MediaId, source_code: &str) -> Result<Vec<Episode>> {
        let native =
            serde_json::to_string(&self.strip_prefix(&id.native)).unwrap_or_else(|_| "\"\"".into());
        let expr = format!(
            "(plugin.episodes ? plugin.episodes({native}, {}) : plugin.detail({native}).then(d => d.episodes))",
            serde_json::to_string(source_code).unwrap_or_else(|_| "\"\"".into()),
        );
        let json = self.call_js(&expr).await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("episodes() 返回格式不符: {e}")))
    }

    /// 列出可用播放源
    ///
    /// 默认实现从 `detail()` 取（大多数插件只需这样），
    /// 但插件若实现了 `sources()` 就用它的 —— 有些站点要单独请求。
    async fn sources(&self, id: &MediaId) -> Result<Vec<PlaySource>> {
        let native =
            serde_json::to_string(&self.strip_prefix(&id.native)).unwrap_or_else(|_| "\"\"".into());
        let expr = format!(
            "(plugin.sources ? plugin.sources({native}) : plugin.detail({native}).then(d => d.sources))"
        );
        let json = self.call_js(&expr).await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("sources() 返回格式不符: {e}")))
    }

    /// 取流
    ///
    /// `req` 是 Rust 侧的 `PlayRequest`（字段是 snake_case），
    /// 要转成 camelCase 再给插件 —— 契约里插件写的是
    /// `req.episodeId` 而不是 `req.episode_id`。
    ///
    /// # ⚠️ 必须剥掉 `episode_id` 上的 provider 前缀（实测踩到）
    ///
    /// `detail()` 返回的 `episodes[].id` 会经 `prefix_media_ids` 被加上
    /// `"{provider}:"` 前缀（那是给**媒体条目**用的，避免跨源撞 id）。
    /// 但 `Episode.id` 在 Rust 侧是**普通字符串**，前端把它原样放进
    /// `PlayRequest.episode_id` 传回来时，插件收到的是 `cycani:51463`。
    ///
    /// 后果（Owner 实测报的错）：
    /// ```text
    /// bind uri "section_id": parsing "cycani:51463": invalid syntax
    /// ```
    /// 次元城的取流接口拿它当数字 id 用，直接 400。
    ///
    /// 所以这里要把前缀剥掉再给插件。
    async fn resolve(&self, id: &MediaId, req: &PlayRequest) -> Result<Vec<StreamCandidate>> {
        let mut req_js = rust_value_to_js(
            serde_json::to_value(req).unwrap_or(serde_json::Value::Object(Default::default())),
        );

        // 剥掉 episode_id 上的前缀（剧集 id 是插件自己的数字/字符串 id）
        if let Some(serde_json::Value::String(ep)) = req_js.get_mut("episodeId") {
            *ep = self.strip_prefix(ep);
        }

        /*
         * ★★★ 第一个参数：tvbox 转换插件要的是**剧集地址**，不是条目 id
         *
         * # Owner 报的 bug
         * > 播放第二集,实际还是第一集,这是bug
         *
         * # 根因（逐行核对过）
         *
         * tvbox 转换插件的 detail() 里，剧集的 id **就是剧集地址**
         * （154.js:369  id: e.url,  // 直接存 URL），而它的 resolve(id)
         * **只认第一个参数、完全忽略第二个 req**：
         * ```text
         * 154.js:392  async resolve(id) {
         * 154.js:415    let url = String(id)
         * 154.js:417    if (!/^https?:\/\//i.test(url)) {
         * 154.js:419      const j = await getJson(...ids=${url})   // ← 拿它当**条目 id**
         * 154.js:425      url = eps[0].url                          // ★★★ 永远第一集
         * 154.js:426    }
         * ```
         * 宿主原来把 id.native（条目 id，如 "150758"）当第一个参数传下去，
         * 于是插件每次都在第 419 行去查详情、在第 425 行取 eps[0]
         * ⇒ **无论点第几集都返回第一集**，与 Owner 的描述完全吻合。
         *
         * # 为什么改成"看 episode_id 是不是 URL"而不是别的判据
         *
         * 宿主**不能**改用户数据目录里的插件文件（那是用户数据），
         * 所以只能在这一层做适配。而 PlayRequest.episode_id 在
         * tvbox 转换插件里**就是剧集地址**（上面那行 id: e.url），
         * 所以：**它是 http(s) URL 时，就用它当第一个参数**。
         *
         * # ⚠️ 判据必须**精确**：只有明确是 http(s) URL 才替换
         *
         * 别的插件用 episode_id 表达**别的东西** ——
         * 最典型的是 cycani：它拿 episode_id 当 section_id
         * （见上面那段前缀坑，插件要的是纯数字 51463）。
         * 若不加判断地一律替换，次元城那条路会被打坏。
         * ⇒ 用 starts_http（与 tvbox.rs 同一份语义：大小写不敏感、
         *   必须是完整 http:// / https:// 前缀），
         *   不是 URL 就**原样**传条目 id（= 改前行为，逐字相同）。
         *
         * # 反向控制（必须逐字不变）
         *
         * episode_id 为 None / 空串 / "150758" / "cycani:51463"
         * 时，走的都是 else 分支 ⇒ 第一个参数仍是 strip_prefix(id.native)
         * ⇒ 与改动前**完全一致**，不影响从播放历史/追更直接续播的路径。
         */
        let first_arg = self.resolve_first_arg(id, req);

        let expr = format!(
            "plugin.resolve({}, {})",
            serde_json::to_string(&first_arg).unwrap_or_else(|_| "\"\"".into()),
            serde_json::to_string(&req_js).unwrap_or_else(|_| "{}".into())
        );
        let json = self.call_js(&expr).await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("resolve() 返回格式不符: {e}")))
    }

    // ── 登录（可选能力）──
    //
    // ⚠️ 每个方法都要先判断插件**是否实现了它**。
    //    不判断的话，一个不需要登录的插件（如央视）被问到
    //    `session()` 时会抛 `plugin.session is not a function` ——
    //    而宿主在启动时会普遍地问一遍，于是**每次启动都刷一堆错误日志**，
    //    真正的问题反而被淹没。

    async fn login(&self, cred: Credentials) -> Result<Session> {
        let expr = format!(
            "plugin.login({}, {})",
            serde_json::to_string(&cred.username).unwrap_or_else(|_| "\"\"".into()),
            serde_json::to_string(&cred.password).unwrap_or_else(|_| "\"\"".into())
        );
        let json = self.call_js(&expr).await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("login() 返回格式不符: {e}")))
    }

    async fn logout(&self) -> Result<()> {
        // 没实现就当作「已经登出」，不是错误
        self.call_js("(plugin.logout ? plugin.logout() : null)")
            .await?;
        Ok(())
    }

    async fn session(&self) -> Result<Option<Session>> {
        let json = self
            .call_js("(plugin.session ? plugin.session() : null)")
            .await?;
        parse_optional_session(&json, "session")
    }

    async fn refresh_session(&self) -> Result<Option<Session>> {
        let json = self
            .call_js("(plugin.refreshSession ? plugin.refreshSession() : null)")
            .await?;
        parse_optional_session(&json, "refreshSession")
    }

    async fn can_auto_login(&self) -> bool {
        matches!(
            self.call_js("(plugin.canAutoLogin ? plugin.canAutoLogin() : false)")
                .await
                .as_deref(),
            Ok("true")
        )
    }

    /// ★ 用已保存的凭据自动重新登录
    ///
    /// Owner 报「登录失效，像这种没有验证码的，应该自动重登」——
    /// 宿主在「token 过期且续期失败」时会走这里。
    async fn auto_login(&self) -> Result<Option<Session>> {
        let json = self
            .call_js("(plugin.autoLogin ? plugin.autoLogin() : null)")
            .await?;
        parse_optional_session(&json, "autoLogin")
    }

    /// 彻底忘记凭据（插件版存在插件私有存储里）
    async fn forget_credentials(&self) -> Result<()> {
        self.call_js("(plugin.forgetCredentials ? plugin.forgetCredentials() : null)")
            .await?;
        Ok(())
    }

    // ── 扫码登录（2026-09-21）───────────────────────────────────
    //
    // 契约见 `provider.rs` 的 `QrLoginStart` 说明。
    // 宿主只做两件事：① 调插件拿 url 与状态 ② 把 url 画成二维码。

    /// ★ 申请登录二维码
    ///
    /// ⚠️ 插件**没有**实现 `qrLoginStart` 时返回 `unsupported`，
    ///    而不是空值 —— 宿主据此决定登录弹窗里显不显示「扫码」页签。
    ///    这与 `has_method("qrLoginStart")` 是两条互补的判据：
    ///    `has_method` 用于**渲染前**判断要不要显示入口，
    ///    这里用于**真的调用时**给出明确错误。
    async fn qr_login_start(&self) -> Result<crate::provider::QrLoginStart> {
        let json = self
            .call_js("(plugin.qrLoginStart ? plugin.qrLoginStart() : null)")
            .await?;
        if json == "null" {
            return Err(ProviderError::unsupported("该插件不支持扫码登录"));
        }
        let mut start: crate::provider::QrLoginStart = serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("qrLoginStart() 返回格式不符: {e}")))?;

        /*
         * ★★★ 二维码由**宿主**渲染（不是插件）
         *
         * QuickJS 里没有 canvas / DOM，插件画不出二维码。
         * 而宿主已经有 `qrcode` 依赖（局域网遥控的二维码就在用同一套）。
         *
         * ⚠️ 渲染失败**不能**让整个扫码流程失败 —— 界面仍可把 url
         *    当文本显示（虽然不好扫，但用户至少能看到出了什么事）。
         *    所以这里是 `unwrap_or_default()` 而不是 `?`。
         */
        start.svg = crate::remote::qr_svg_for(&start.url).unwrap_or_default();
        Ok(start)
    }

    /// ★ 轮询扫码状态
    async fn qr_login_poll(&self, key: &str) -> Result<crate::provider::QrLoginPoll> {
        let expr = format!(
            "(plugin.qrLoginPoll ? plugin.qrLoginPoll({}) : null)",
            serde_json::to_string(key).unwrap_or_else(|_| "\"\"".into())
        );
        let json = self.call_js(&expr).await?;
        if json == "null" {
            return Err(ProviderError::unsupported("该插件不支持扫码登录"));
        }
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("qrLoginPoll() 返回格式不符: {e}")))
    }

    /// 该插件是否实现了某个方法（供宿主分派可选能力）
    ///
    /// 用 `typeof` 判断而不是「调用后看有没有报错」——
    /// 后者分不清「没实现」与「实现了但出错」。
    async fn has_method(&self, name: &str) -> bool {
        // 名字来自宿主代码（不是用户输入），但仍做一次白名单校验，
        // 避免将来有人把外部字符串传进来导致注入
        if !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
            return false;
        }
        matches!(
            self.call_js(&format!("typeof plugin.{name} === 'function'"))
                .await
                .as_deref(),
            Ok("true")
        )
    }

    // ── 直播与节目单 ──
    //
    // ⚠️ 这几个**必须实现**，不能靠 trait 默认值。
    //    默认值是 `Unsupported`，而 `Registry::live_all()` 会
    //    吞掉错误直接跳过 —— 表现是「插件明明声明了 live: true，
    //    直播页却完全看不到它」（实测踩到，很难查）。

    async fn live_channels(&self) -> Result<Vec<LiveChannel>> {
        let json = self.call_js("plugin.liveChannels()").await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("liveChannels() 返回格式不符: {e}")))
    }

    async fn live_stream(&self, channel_id: &str) -> Result<Vec<StreamCandidate>> {
        let expr = format!(
            "plugin.liveStream({})",
            serde_json::to_string(channel_id).unwrap_or_else(|_| "\"\"".into())
        );
        let json = self.call_js(&expr).await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("liveStream() 返回格式不符: {e}")))
    }

    async fn epg(&self, channel_id: &str, day: Option<&str>) -> Result<Vec<EpgEntry>> {
        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ 可选方法要优雅降级（2026-09-25 修的真 bug）
         * ══════════════════════════════════════════════════════════════
         *
         * # 症状
         * ```text
         * 用户切台时每次都刷一条：
         *   [LIVE] 该频道暂无节目单: SourinCoreException(other): 插件报错: not a function
         * ```
         * 复现（`.probe/t42_epg_repro.py`，真实 FFI）：
         * ```text
         * get_epg("iptv", …)  ⇒ {"error":"插件报错: not a function"}   ★ 失败
         * get_epg("cctv", …)  ⇒ [{"title":"…","start":…}]              ★ 阳性对照通过
         * ```
         *
         * # 根因：**能力位声明 false，但桥接层无条件调用**
         * ```text
         * `plugins/iptv.js` 声明 `capabilities: { …, epg: false }`，
         * ★ 且**根本没有** `epg` 方法（公共源没有 EPG 数据）。
         * 而本函数无条件拼 `plugin.epg(...)` 去执行 ⇒ 调用不存在的方法
         * ⇒ JS 抛 `TypeError: plugin.epg is not a function`。
         * ```
         *
         * # 为什么必须在这里（桥接层）降级
         * ```text
         * 本文件 L3336 早就写明了原则：
         *   「插件**没实现**的可选方法要优雅降级，不能报「is not a function」」
         * —— `session()` / `logout()` / `rank()` 都照做了，
         * ★ 只有 `epg()`（和 `timeshift()`）漏了。
         * ⇒ 与管理「哪些方法可选」的知识放在**同一层**，最不容易再漏。
         * ```
         *
         * # 为什么用三元表达式而不是 try/catch
         * ```text
         * `rank()` 用的就是 `plugin.rank ? … : Promise.reject(unsupported…)`
         * —— **先判存在再调用**。照抄它能保证：
         *   ① 方法**不存在** ⇒ 明确报 `unsupported`（语义准确）
         *   ② 方法**存在但内部报错** ⇒ 错误**原样透出**（不被误吞）
         * ★ 若改成"捕获所有错误都返回空数组"，
         *   那会把插件真正的 bug 也吞掉（用户看到"没有节目单"而不是报错）
         *   ⇒ 那是**更坏的**选择。
         * ```
         *
         * ⚠️ 与 `rank()` 的差别：`rank` 的"没实现"是**真错误**
         *    （首页区块会永远空白，L1907 记录过），所以它 `reject`。
         *    而 EPG **本来就是可选**的（没有节目单是正常状态）⇒
         *    这里返回**空数组**更贴合语义 ——
         *    Flutter 侧那句注释就是 `// 失败就空`，
         *    调用方本来也把"取不到"当成"暂无节目单"。
         */
        let expr = match day {
            Some(d) => format!(
                "(plugin.epg ? plugin.epg({}, {}) : [])",
                serde_json::to_string(channel_id).unwrap_or_else(|_| "\"\"".into()),
                serde_json::to_string(d).unwrap_or_else(|_| "null".into())
            ),
            None => format!(
                "(plugin.epg ? plugin.epg({}) : [])",
                serde_json::to_string(channel_id).unwrap_or_else(|_| "\"\"".into())
            ),
        };
        let json = self.call_js(&expr).await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("epg() 返回格式不符: {e}")))
    }

    async fn timeshift(
        &self,
        channel_id: &str,
        start: i64,
        end: i64,
    ) -> Result<StreamCandidate> {
        /*
         * ★★ 与 `epg()` **同一个形态**的漏洞（2026-09-25 一并修）
         *
         * # 复现（我实测，`.probe/t42_epg_repro.py`）
         * ```text
         * get_timeshift("iptv", …)  ⇒ ★ **空响应**（不是报错，也不是流）
         * get_timeshift("cctv", …)  ⇒ {"url":"https://…index.m3u8","kind":"hls",…}
         * ```
         * ★ iptv.js 同样声明 `timeshift` 未实现（只声明了 `live: true`）
         * ⇒ 无条件调用 ⇒ `plugin.timeshift is not a function`。
         *
         * ⚠️ 与 `epg` 的**关键差别**：这里**不能**用"返回空值"降级 ——
         *    `timeshift` 的返回类型是 `StreamCandidate`（**非 Option**），
         *    没有"空流"这种合法值。
         * ⇒ 必须报**明确的不支持错误**（`unsupported`），
         *    让调用方能区分"这个源不支持时移"与"时移失败了"。
         *    ★ 与 `rank()` 的处理方式一致（它也是"没实现 ⇒ unsupported"）。
         */
        let expr = format!(
            "(plugin.timeshift ? plugin.timeshift({}, {}, {}) \
             : Promise.reject(new Error('unsupported: 该源不支持时移回看')))",
            serde_json::to_string(channel_id).unwrap_or_else(|_| "\"\"".into()),
            start,
            end
        );
        let json = self.call_js(&expr).await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("timeshift() 返回格式不符: {e}")))
    }
}

// ─────────────────────────── 扫描插件目录 ───────────────────────────

/// 扫描目录下所有 `.js` 插件（**只做静态解析，不执行脚本**）
///
/// 返回 `(成功加载的插件, 失败原因列表)` —— **隔离失败**：
/// 一个坏插件不该影响其它插件可用。
///
/// ⚠️ 能力位还没补齐（要执行脚本才知道），
/// 调用方注册前必须逐个 `hydrate_capabilities()`。
pub fn load_plugins(dir: &std::path::Path) -> (Vec<JsPluginProvider>, Vec<(String, String)>) {
    let mut ok = Vec::new();
    let mut bad = Vec::new();

    let Ok(entries) = std::fs::read_dir(dir) else {
        return (ok, bad);
    };

    for e in entries.flatten() {
        let path = e.path();
        if path.extension().and_then(|s| s.to_str()) != Some("js") {
            continue;
        }
        let fname = path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("?")
            .to_string();

        match std::fs::read_to_string(&path) {
            Ok(src) => match JsPluginProvider::from_source(&src) {
                Ok(p) => ok.push(p),
                Err(e) => bad.push((fname, e)),
            },
            Err(e) => bad.push((fname, format!("读取失败: {e}"))),
        }
    }

    (ok, bad)
}

/// 扫描 + 补齐能力位（**注册进 Registry 前用这个**）
///
/// 相比 `load_plugins` 多一步：执行脚本读 `capabilities`。
/// 少了这一步，插件在直播页/搜索页会完全不可见。
pub async fn load_plugins_hydrated(
    dir: &std::path::Path,
    proxy: Option<Arc<crate::proxy::ProxyStore>>,
) -> (Vec<JsPluginProvider>, Vec<(String, String)>) {
    let (plugins, bad) = load_plugins(dir);
    let mut out = Vec::with_capacity(plugins.len());
    // 插件私有数据放 `plugins/.data/`
    let data_dir = dir.join(".data");

    for mut p in plugins {
        if let Some(px) = proxy.clone() {
            p = p.with_proxy(px);
        }
        p = p.with_data_dir(data_dir.clone());
        p.hydrate_capabilities().await;
        out.push(p);
    }

    (out, bad)
}

/// 校验插件源码能否加载（**真的执行一次**，但不调用任何方法）
///
/// 用途：编辑插件后保存前先验证 —— 语法错误（括号不配对、少个逗号）
/// 只有真正求值才能发现，光看 `@id` 是拦不住的。
///
/// 不会执行插件的方法（`home`/`resolve` 等），所以**不产生网络请求**，
/// 也不会因为插件逻辑本身有问题而误判为「语法错误」。
pub async fn validate_source(source: &str) -> std::result::Result<(), String> {
    let p = JsPluginProvider::from_source(source)?;

    // 只求值脚本本体 + 确认 plugin 对象存在，不调任何业务方法
    match p.call_js("(typeof plugin === 'object' && plugin !== null)").await {
        Ok(_) => Ok(()),
        Err(e) => Err(e.message),
    }
}

// ─────────────────────── 在线安装（GitHub → CDN）───────────────────────

/// 把用户粘贴的地址解析成**真正可下载的直链**
///
/// # 为什么要做这层
///
/// 用户复制的是 GitHub **页面**地址（`github.com/user/repo`），
/// 而 `raw.githubusercontent.com` 在国内**直连不通**（实测 12 秒超时）。
/// 实测可用的 CDN：
///
/// | 来源 | 实测（直连，不挂代理）|
/// |---|---|
/// | `cdn.jsdelivr.net` | ✅ 200，1.1 秒 ← 默认走这个 |
/// | `fastly.jsdelivr.net` | ✅ 200，1.5 秒 |
/// | `gcore.jsdelivr.net` | ✅ 200，2.7 秒 |
/// | `raw.githubusercontent.com` | ❌ 12 秒超时 |
///
/// 所以**默认走 jsDelivr**，用户不需要懂 raw 与 CDN 的区别，
/// 也不需要为此配代理。
///
/// # 支持的输入形态
///
/// | 用户粘贴 | 解析为 |
/// |---|---|
/// | `https://github.com/u/r` | `https://cdn.jsdelivr.net/gh/u/r@main/index.js` |
/// | `https://github.com/u/r/blob/main/src/x.js` | `.../gh/u/r@main/src/x.js` |
/// | `u/r` | 同上（补全）|
/// | 任意 `http(s)` 直链 | 原样返回 |
pub fn resolve_plugin_url(input: &str) -> std::result::Result<String, String> {
    let s = input.trim();
    if s.is_empty() {
        return Err("请填写插件地址".into());
    }

    if let Some(rest) = s
        .strip_prefix("https://github.com/")
        .or_else(|| s.strip_prefix("http://github.com/"))
    {
        return github_to_cdn(rest);
    }

    // 已经是直链（jsDelivr / raw / 自建服务器）→ 原样用
    if s.starts_with("http://") || s.starts_with("https://") {
        return Ok(s.to_string());
    }

    // `owner/repo` 简写
    if s.matches('/').count() == 1 && !s.contains(' ') {
        return github_to_cdn(s);
    }

    Err("无法识别的地址。支持：GitHub 仓库地址、owner/repo，或任意 http(s) 直链".into())
}

/// `owner/repo` 或 `owner/repo/blob/branch/path` → jsDelivr CDN 地址
fn github_to_cdn(rest: &str) -> std::result::Result<String, String> {
    let rest = rest.trim_end_matches('/');
    let parts: Vec<&str> = rest.split('/').filter(|s| !s.is_empty()).collect();
    if parts.len() < 2 {
        return Err("GitHub 地址至少要包含 owner/repo".into());
    }
    let (owner, repo) = (parts[0], parts[1]);

    // 形如 owner/repo/blob/<branch>/<path...>
    if parts.len() >= 5 && (parts[2] == "blob" || parts[2] == "raw") {
        let branch = parts[3];
        let path = parts[4..].join("/");
        return Ok(format!(
            "https://cdn.jsdelivr.net/gh/{owner}/{repo}@{branch}/{path}"
        ));
    }

    // 仓库根 → 默认入口文件 index.js。
    // 分支名固定试 main；下载失败会自动退到 master（见 fetch_plugin_source）——
    // GitHub 已改默认分支名，让用户记得自己用哪个是不现实的。
    Ok(format!(
        "https://cdn.jsdelivr.net/gh/{owner}/{repo}@main/index.js"
    ))
}

/// 下载插件源码（CDN 失败时自动退到另一分支名与 raw）
///
/// 返回 `(源码, 实际使用的地址)` —— 地址要回传给用户，
/// 否则出问题（如「装的还是旧版」）没法排查。
pub async fn fetch_plugin_source(
    proxy: Option<&Arc<crate::proxy::ProxyStore>>,
    url: &str,
) -> std::result::Result<(String, String), String> {
    let client = match proxy {
        Some(px) => px
            .client_for("plugin", None)
            .unwrap_or_else(|_| default_client()),
        None => default_client(),
    };

    /* 候选地址，按「最可能成功」排序
     *
     * 1. 解析出来的（默认 jsDelivr）
     * 2. 换另一个分支名 —— 仓库默认分支是 main 还是 master，用户不会记得
     * 3. raw（国内通常不通，但用户配了代理就能用）
     */
    let mut candidates = vec![url.to_string()];
    if url.contains("cdn.jsdelivr.net/gh/") {
        if url.contains("@main/") {
            candidates.push(url.replace("@main/", "@master/"));
        } else if url.contains("@master/") {
            candidates.push(url.replace("@master/", "@main/"));
        }
        candidates.push(
            url.replace("https://cdn.jsdelivr.net/gh/", "https://raw.githubusercontent.com/")
                .replace('@', "/"),
        );
    }

    let mut tried = Vec::new();
    for c in candidates {
        tried.push(c.clone());
        match client.get(&c).send().await {
            Ok(r) if r.status().is_success() => match r.text().await {
                Ok(t) => {
                    // ★ 校验拿到的确实是插件，而不是 CDN 返回的 HTML 错误页
                    //   （jsDelivr 对不存在的路径会返回 HTML，直接写盘会得到一个坏插件）
                    if !t.contains("@id") {
                        continue;
                    }
                    return Ok((t, c));
                }
                Err(_) => continue,
            },
            _ => continue,
        }
    }

    Err(format!(
        "下载失败，已尝试 {} 个地址：\n{}\n\n\
         可能原因：地址写错、仓库里没有 index.js、或网络受限。\n\
         若网络受限，可在「网络代理」里给插件下载配置代理。",
        tried.len(),
        tried.join("\n")
    ))
}

// ═══════════════════════════════════════════════════════════════════════
//  插件「安装来源 / 版本历史 / 回滚」（task-23，2026-09-25）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这一块
//
// 用户拍板：
// > 通过链接检测更新,可以进行回滚
// > 插件市场暂时不做  github raw 暂时不做
//
// 「通过链接检测更新」的技术前提是**得知道当初是哪个链接装的** ——
// 而实测发现：`install_plugin` 一直**返回** `resolvedUrl`，
// 却**从不落盘** → 装完之后就再也找不到"去哪查新版"。
// 所以这一块的第一件事是把来源记住。
//
// # 磁盘布局（**全是 sidecar，绝不改插件本体**）
//
// ```text
// <dataDir>/plugins/
//   ├── 154.js                     ← 插件本体（用户能直接看/改，不动它）
//   ├── .data/154.json             ← 插件私有配置（已有，绝不能碰）
//   ├── .meta/154.json             ← ★ 本模块：安装来源
//   └── .versions/                 ← ★ 本模块：历史版本
//         ├── 154@1.0.0.js
//         └── 154@2.0.0.js
// ```
//
// ⚠️ 为什么用 `.meta/` 而不是把来源写进 `.js` 的头部注释：
// ```text
// ① 插件本体是**用户的文件**（用户能"打开看、自己改"）——
//    我们往里塞字段，用户改完保存就会丢掉，或产生 diff 噪音
// ② `.js` 的头部注释是**插件作者**的地盘（@id/@name/@version），
//    宿主往里写东西等于篡改作者的产物
// ③ 分离之后：删掉 .meta 只是"忘了来源"，插件照样能用（优雅降级）
// ```
//
// ⚠️ 目录名以 `.` 开头是有意的：`load_plugins` 只扫 `*.js`，
//    点目录天然不会被打扰；用户也不容易误删。

/// 插件安装来源（`plugins/.meta/<id>.json`）
///
/// # 字段与理由
///
/// ```text
/// source_url    当初安装用的**最终解析地址**（install_plugin 的 resolvedUrl）
///               ⚠️ 存 resolvedUrl 而不是用户输入的原始链接：
///                  原始链接可能是"插件市场页"，而真正能 GET 到 JS 的是解析后的地址。
///                  检测更新时直接 GET 这个，不用再解析一次（也避免解析规则变化）。
///
/// installed_version  安装/更新时插件声明的 @version
///                    用于"远端版本 vs 本地版本"的比较基准
///
/// installed_at  Unix 秒。给界面显示"什么时候装的"
/// file          装成了哪个文件名（`154.js`）—— 回滚要写回这个文件
/// ```
///
/// ⚠️ 没有 `sha256` 字段：实测 `sha2` 不在依赖树里，加它要动 `Cargo.toml`。
///    "内容没变就别覆盖"这个需求的**实质**是"比对内容"，
///    而**直接逐字节比对**比 hash 更准（无碰撞可能）且零依赖 ——
///    见 `same_content()`。
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct PluginSourceMeta {
    /// 安装来源链接（`None` = 没有来源，例如用户手动丢进目录的）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_url: Option<String>,
    #[serde(default)]
    pub installed_version: String,
    /// Unix 秒
    #[serde(default)]
    pub installed_at: i64,
    /// 装成的文件名（`154.js`）
    #[serde(default)]
    pub file: String,
}

/// `plugins/.meta/` 目录
pub fn plugin_meta_dir(dir: &std::path::Path) -> std::path::PathBuf {
    dir.join(".meta")
}

/// `plugins/.versions/` 目录
pub fn plugin_versions_dir(dir: &std::path::Path) -> std::path::PathBuf {
    dir.join(".versions")
}

/// `<dir>/.meta/<id>.json` 的路径
///
/// ⚠️ `id` 直接进文件名 → 必须过滤字符集，否则 `../../x` 能写到插件目录外。
///    与 `save_plugin()` 用**同一套**规则（那里已经踩过一次，见其注释）。
fn plugin_source_meta_path(dir: &std::path::Path, id: &str) -> Option<std::path::PathBuf> {
    if !id
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        || id.is_empty()
    {
        return None;
    }
    Some(plugin_meta_dir(dir).join(format!("{id}.json")))
}

/// 当前 Unix 秒（读 meta 时用来兜底 `installed_at == 0` 的老数据）
fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// 读安装来源
///
/// # ★ 老数据必须优雅处理（本机 26 个插件全都没有 meta）
///
/// ```text
/// 文件不存在      → Ok(None)      ← 不是错误！"没有来源"是完全正常的状态
/// JSON 坏了       → Ok(None) + 警告日志（不能因为一个坏文件就让设置页打不开）
/// id 非法         → Ok(None)
/// ```
/// ⚠️ 一律**不返回 Err**：调用方（设置页）要能无条件列出全部插件，
///    某个插件缺 meta 只是"查不了更新"，不该让整个列表失败。
pub fn read_plugin_meta(dir: &std::path::Path, id: &str) -> Option<PluginSourceMeta> {
    let path = plugin_source_meta_path(dir, id)?;
    let raw = std::fs::read_to_string(&path).ok()?;
    match serde_json::from_str::<PluginSourceMeta>(&raw) {
        Ok(m) => Some(m),
        Err(e) => {
            // ★ 坏文件只记日志、不算错 —— 见上面的说明
            log::warn!("插件 meta 解析失败（忽略，当作没有来源）: {path:?}: {e}");
            None
        }
    }
}

/// 写安装来源（自动建目录）
pub fn write_plugin_meta(
    dir: &std::path::Path,
    id: &str,
    meta: &PluginSourceMeta,
) -> std::result::Result<(), String> {
    let path = plugin_source_meta_path(dir, id)
        .ok_or_else(|| format!("插件 @id 含非法字符（只允许字母/数字/-/_）: {id}"))?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("创建 .meta 目录失败: {e}"))?;
    }
    let body = serde_json::to_string_pretty(meta).map_err(|e| format!("序列化失败: {e}"))?;
    std::fs::write(&path, body).map_err(|e| format!("写入 {path:?} 失败: {e}"))
}

/// 「内容没变」判定 —— **直接逐字节比对**（不引入 hash 依赖）
///
/// # 为什么不用 sha256（这是有意的技术选择，不是省事）
///
/// 需求的实质是"内容没变就别覆盖"。两条路：
/// ```text
/// ① 存 sha256 再比指纹 —— 理论上有碰撞（虽然极小），且**要加依赖**
///    （实测 `sha2` 不在依赖树里，加它要改 Cargo.toml）
/// ② 直接比内容         —— **精确**（无碰撞概念），零依赖
/// ```
/// 这里选 ②：下载回来的源码本来就在内存里，本地文件也就几十 KB，
/// 直接 `==` 比读一遍文件再算哈希**更快**（少一趟哈希计算）。
pub fn same_content(a: &str, b: &str) -> bool {
    /*
     * ⚠️ 行尾差异要归一化：远端仓库可能是 CRLF，本地写盘后是原样字节。
     *    不归一化的话，"内容其实一样"会被判成"有更新"，
     *    然后白白覆盖一次、还多存一个历史档 —— 用户看到的是
     *    "版本号没变却提示更新了"。所以按行比较、忽略 \r。
     */
    let norm = |s: &str| -> Vec<String> {
        s.lines().map(|l| l.trim_end_matches('\r').to_string()).collect()
    };
    norm(a) == norm(b)
}

/// 语义化版本比较：`a` 是否**比** `b` 新
///
/// # ★ 为什么不能直接比字符串（这是本模块最容易写错的地方）
///
/// ```text
/// "1.10.0" > "1.9.0"  字符串比较 → false  ★ 错！（"1" < "9"）
/// "1.10.0" > "1.9.0"  按数字段比 → true   ✓
/// "1.2.3"  > "1.2.10" 字符串比较 → true   ★ 错！
/// "1.2.3"  > "1.2.10" 按数字段比 → false  ✓
/// ```
/// 版本号是**数字段序列**，必须逐段转数字比。这是经典陷阱
///（用户装的插件里 `1.10.0` 和 `1.9.0` 同时存在时就会踩到）。
///
/// # 规则（够用且不会误判）
///
/// ```text
/// · 按 `.` 切段，每段取**开头的数字**（"3-beta" → 3）
/// · 逐段比数字；段数不同时缺的段按 0 算（"1.2" == "1.2.0"）
/// · 段里有非数字前缀（"v1.2"）也能解析出来（取第一段数字）
/// · 无法解析的段按 0（宁可判"没有新版"，也不要误报更新）
/// ```
///
/// ⚠️ 不处理 `-alpha`/`+build` 这类**预发布**语义（`1.0.0-beta < 1.0.0`）——
///    插件生态里没人用；真遇到时按"数字段相等"处理，即**不提示更新**（保守）。
pub fn version_is_newer(remote: &str, local: &str) -> bool {
    fn segment(s: &str) -> u64 {
        let digits: String = s
            .trim_start_matches(|c: char| !c.is_ascii_digit())
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect();
        digits.parse::<u64>().unwrap_or(0)
    }
    let r: Vec<u64> = remote.split('.').map(segment).collect();
    let l: Vec<u64> = local.split('.').map(segment).collect();
    let n = r.len().max(l.len());
    for i in 0..n {
        // 缺的段按 0：这样 "1.2" 与 "1.2.0" 相等（不会假报更新）
        let a = *r.get(i).unwrap_or(&0);
        let b = *l.get(i).unwrap_or(&0);
        if a != b {
            return a > b;
        }
    }
    false
}

/// `.versions` 每个插件**保留几档**历史
///
/// # 为什么是 5（判断说明，不是随手定的数）
///
/// ```text
/// 用户的诉求是「可以回滚」—— 实际场景是"升级后发现不好用，退回去"，
/// 也就是**回一档**占 95%。留 5 档的余量是为了：
///   ① 连续两次踩坑（升了 A 不好 → 回滚 → 又装了 B 不好 → 再回滚）
///   ② 用户可能想看看"三个版本前是什么样"
///
/// 磁盘：单个插件约 10~60KB → 5 档 ≈ 最多 300KB/插件。
///       26 个插件最坏 26 × 300KB ≈ 7.8MB —— 可接受。
///       留 20 档就是 31MB，只是为了极罕见的场景，不值得。
/// ```
pub const MAX_PLUGIN_VERSIONS: usize = 5;

/// 把**当前**插件内容归档为一档历史
///
/// 返回归档文件路径（失败返回 Err —— 调用方决定是否让整个更新失败）。
///
/// ⚠️ 文件名用 `<id>@<version>.js`：
/// ```text
/// · 带 version 让用户/我们一眼看出这是哪一版（比时间戳可读得多）
/// · 同版本重复归档会**覆盖**同一个文件 —— 这是有意的：
///   同版本内容不同只可能是"作者改了内容没改版本号"，
///   留两份同名版本反而让"回滚到 vX"变成歧义
/// ```
pub fn archive_plugin_version(
    dir: &std::path::Path,
    id: &str,
    version: &str,
    source: &str,
) -> std::result::Result<std::path::PathBuf, String> {
    if !id
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        || id.is_empty()
    {
        return Err(format!("插件 @id 含非法字符: {id}"));
    }
    // 版本号进文件名 → 同样要过滤（版本号是插件作者写的，不可信）
    let v: String = version
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '-' || *c == '_')
        .collect();
    let v = if v.is_empty() { "unknown".to_string() } else { v };

    let vdir = plugin_versions_dir(dir);
    std::fs::create_dir_all(&vdir).map_err(|e| format!("创建 .versions 失败: {e}"))?;
    let path = vdir.join(format!("{id}@{v}.js"));
    std::fs::write(&path, source).map_err(|e| format!("归档历史版本失败: {e}"))?;
    Ok(path)
}

/// 列出某个插件的全部历史档（**新→旧**排序）
///
/// 返回 `(version, 文件路径)`。
///
/// ⚠️ 排序按 `version_is_newer` 而不是文件名字符串 ——
///    否则 `1.10.0` 会排在 `1.9.0` 前面（同一条版本比较陷阱）。
///    解析不出文件名格式的（用户手动放进来的）按 "0" 处理、排最后。
pub fn list_plugin_versions(
    dir: &std::path::Path,
    id: &str,
) -> Vec<(String, std::path::PathBuf)> {
    let vdir = plugin_versions_dir(dir);
    let Ok(rd) = std::fs::read_dir(&vdir) else {
        return Vec::new(); // 目录不存在 = 没有历史（正常，不是错误）
    };
    let prefix = format!("{id}@");
    let mut out: Vec<(String, std::path::PathBuf)> = Vec::new();
    for e in rd.flatten() {
        let path = e.path();
        if path.extension().and_then(|s| s.to_str()) != Some("js") {
            continue;
        }
        let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        let Some(rest) = stem.strip_prefix(&prefix) else {
            continue; // 不是这个插件的
        };
        out.push((rest.to_string(), path));
    }
    // 新 → 旧
    out.sort_by(|a, b| {
        if version_is_newer(&a.0, &b.0) {
            std::cmp::Ordering::Less
        } else if version_is_newer(&b.0, &a.0) {
            std::cmp::Ordering::Greater
        } else {
            std::cmp::Ordering::Equal
        }
    });
    out
}

/// 清理 `.versions`，每个插件只留最近 [`MAX_PLUGIN_VERSIONS`] 档
///
/// 返回被删掉的文件数。
///
/// # 为什么每次归档后都调（而不是定时任务）
///
/// ```text
/// ① 归档是**低频**操作（用户点"更新"才发生）→ 顺便清理零成本
/// ② 定时任务要额外状态（上次清理时间），还可能被用户关掉
/// ③ 每次归档后立刻清理 → **.versions 永远有界**，
///    不存在"涨到几个 GB 才发现"的窗口
/// ```
///
/// ⚠️ 删的是**最旧**的档（`list_plugin_versions` 已是新→旧）。
pub fn prune_plugin_versions(dir: &std::path::Path, id: &str) -> usize {
    let all = list_plugin_versions(dir, id);
    if all.len() <= MAX_PLUGIN_VERSIONS {
        return 0;
    }
    let mut removed = 0;
    for (v, path) in all.into_iter().skip(MAX_PLUGIN_VERSIONS) {
        match std::fs::remove_file(&path) {
            Ok(_) => {
                removed += 1;
                log::info!("清理旧版本档 {id}@{v}");
            }
            Err(e) => log::warn!("清理 {path:?} 失败: {e}"),
        }
    }
    removed
}

/// 写入插件文件（文件名由 id 派生，避免覆盖别人的插件）
pub fn save_plugin(
    dir: &std::path::Path,
    id: &str,
    source: &str,
) -> std::result::Result<(String, u64), String> {
    if id.is_empty() {
        return Err("插件缺少 @id".to_string());
    }
    // ★ 防目录穿越：id 会进文件名，必须限制字符集
    if !id
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err(format!("插件 @id 含非法字符（只允许字母/数字/-/_）: {id}"));
    }

    std::fs::create_dir_all(dir).map_err(|e| format!("创建插件目录失败: {e}"))?;
    let file = format!("{id}.js");
    std::fs::write(dir.join(&file), source).map_err(|e| format!("写入失败: {e}"))?;

    Ok((file, source.len() as u64))
}

// ─────────────────────────── 测试 ───────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// ★ 元信息解析：多个 tag 在同一行也要能解析
    ///
    /// 实测踩过：按「行首前缀」匹配时**一个都匹配不到**，
    /// 因为真实写法常是 `/** @name 央视网 @version 1.0.0 @id cctv */`。
    #[test]
    fn parses_meta_on_single_line() {
        let src = "/** @name 央视网 @version 1.0.0 @author dsh @id cctv */\ncode";
        let m = parse_meta(src);
        assert_eq!(m.id, "cctv");
        assert_eq!(m.name, "央视网");
        assert_eq!(m.version, "1.0.0");
        assert_eq!(m.author, "dsh");
    }

    // ═══════════════════════════════════════════════════════════════
    //  task-5：上游接口地址提取（缺陷 5）
    // ═══════════════════════════════════════════════════════════════

    /// ★★ 转换器生成的插件：头部注释里的上游接口要能提出来
    ///
    /// 这是缺陷 5 的主路径 —— 本机 22 个 `tvbox-convert` 插件**全部**
    /// 靠这条拿到链接（实测 22/22 命中）。
    #[test]
    fn upstream_from_head_comment() {
        // 真实文件 `tyyszy.js` 的头部（逐字抄，只截了相关几行）
        let src = "/**\n * 影视天涯 —— 由 TVBox 源自动转换\n *\n * @id tyyszy\n * @author tvbox-convert\n *\n * 上游接口（苹果CMS v10）：http://tyyszy.com/api.php/provide/vod\n *\n * ⚠️ 这是**自动生成**的插件。\n */\nconst API = \"http://tyyszy.com/api.php/provide/vod\";";
        assert_eq!(upstream_of(src), "http://tyyszy.com/api.php/provide/vod");
    }

    /// ★★★ 手写插件**不能**拿正文 `const API` 当来源（2026-10-09 修掉的 bug）
    ///
    /// Owner 报的症状（截图）：源码装的 `bilibili` 插件，点「编辑」显示成了
    /// 「链接安装」并预填 `https://api.bilibili.com` —— 那是**接口地址**。
    ///
    /// # 原实现与危害
    /// ```text
    /// 原来这条回退是"预期行为"，还配了单测（本测试的旧版本）。
    /// 但 upstream 被 UI 用来判「这个插件是不是按链接装的」（plugin_edit_dialog.dart:197）
    /// ⇒ 误判成链接型 ⇒ 编辑框预填接口地址 + 类型锁死
    /// ⇒ 点保存走 install_plugin(那个地址) ⇒ **把本地插件覆盖坏**。
    /// ```
    ///
    /// ⇒ 现在只认头部注释的「上游接口」；正文常量一律不认，返回空串。
    ///   `bilibili` 属于"用户自己写的源码"，本来就没有安装来源。
    #[test]
    fn upstream_ignores_body_const_api() {
        // ① 头部只有元信息、正文有 const API ⇒ 必须为空（这正是 bilibili 的形状）
        let bili = "/** @id bilibili @name 哔哩哔哩 @author dsh */\nconst API = 'https://api.bilibili.com';";
        assert_eq!(upstream_of(bili), "", "接口地址不能被当成安装来源");
        // ② 三种引号都不认（整条回退都删了，不是只改一种）
        assert_eq!(upstream_of("const API = \"https://a.example.com\""), "");
        assert_eq!(upstream_of("const API = `https://b.example.com`"), "");
        // ③ 但头部有「上游接口」时照常认 —— 转换器插件的主路径不受影响
        let conv = "/**\n * 影视天涯\n * 上游接口（苹果CMS v10）：http://tyyszy.com/api.php/provide/vod\n */\nconst API = \"http://tyyszy.com/api.php/provide/vod\";";
        assert_eq!(upstream_of(conv), "http://tyyszy.com/api.php/provide/vod");
    }

    /// ★★ 宁可为空也不能给错 —— 界面会把它当"上游链接"展示并可复制
    ///
    /// 三类的拒绝理由：
    /// ```text
    /// ① 相对路径    用户复制出来是个不能用的东西
    /// ② 非 http 协议 file:// / javascript: 之类不该出现在"上游"位置
    /// ③ 没有链接     本机 4 个内置源（cctv/cycani/iptv/tvbox-live）就是这种
    /// ```
    #[test]
    fn upstream_is_empty_rather_than_wrong() {
        // ① 相对路径
        assert_eq!(upstream_of("const API = '/api.php/provide/vod'"), "");
        // ② 非 http(s)
        assert_eq!(upstream_of("const API = 'ftp://x.example.com'"), "");
        // ③ 完全没有
        assert_eq!(upstream_of("globalThis.plugin = { id: 'cctv' };"), "");
        // ④ 头部那行是相对路径时，**不再**去看正文 —— 正文那条已删（会误判成来源）
        let src = "/** 上游接口（苹果CMS v10）：/api.php/provide/vod */\nconst API = 'https://real.example.com';";
        assert_eq!(upstream_of(src), "", "相对路径照旧不认，且不回头扫正文");
    }

    /// ★ 拼接式 `const API = base + "/x"` 也不能被扫出来（这条回退整个删了）
    ///
    /// 原来专门有个"只认第一个引号"的逻辑来防它 —— 现在不需要了，
    /// 因为正文常量一律不看。保留断言是为了锁住"不会哪天又加回来"。
    #[test]
    fn upstream_ignores_concatenated_const_api() {
        let src = "const API = base + \"/api.php/provide/vod\";";
        assert_eq!(upstream_of(src), "");
    }

    // ═══════════════════════════════════════════════════════════════
    //  task-23：版本比较 / 元数据 / 历史档 / 老数据兼容
    // ═══════════════════════════════════════════════════════════════

    /// ★★ 版本比较必须按**数字段**比，不能按字符串
    ///
    /// 这是本任务最容易写错的地方 —— 验收明确要求这两条：
    /// ```text
    /// 1.10.0 > 1.9.0   字符串比较会得 false（"1" < "9"）★ 错
    /// 1.2.3 > 1.2.10   字符串比较会得 true              ★ 错
    /// ```
    #[test]
    fn version_compare_is_numeric() {
        assert!(
            version_is_newer("1.10.0", "1.9.0"),
            "1.10.0 应比 1.9.0 新（字符串比较会判错）"
        );
        assert!(
            !version_is_newer("1.2.3", "1.2.10"),
            "1.2.3 不应比 1.2.10 新（字符串比较会判错）"
        );
        // 常规
        assert!(version_is_newer("2.0.0", "1.9.9"));
        assert!(version_is_newer("1.0.1", "1.0.0"));
        assert!(!version_is_newer("1.0.0", "1.0.0"), "相等不算更新");
        assert!(!version_is_newer("1.0.0", "1.0.1"), "更旧不算更新");
        // 段数不同：缺的段按 0（"1.2" == "1.2.0"，不假报更新）
        assert!(!version_is_newer("1.2", "1.2.0"));
        assert!(!version_is_newer("1.2.0", "1.2"));
        assert!(version_is_newer("1.2.1", "1.2"));
        // 容错：前缀非数字 / 段里有非数字后缀
        assert!(version_is_newer("v1.3.0", "v1.2.0"), "带 v 前缀也要能比");
        assert!(version_is_newer("1.3.0-beta", "1.2.0"), "带后缀要取到数字");
        // 极端：完全解析不出来的按 0 → 保守（不报更新）
        assert!(!version_is_newer("abc", "def"));
        assert!(!version_is_newer("", "1.0.0"));
    }

    /// 「内容没变」判定：忽略行尾差异，但不忽略真实差异
    #[test]
    fn same_content_normalizes_line_endings() {
        assert!(same_content("a\nb\n", "a\nb\n"));
        assert!(same_content("a\r\nb\r\n", "a\nb\n"), "CRLF / LF 视为同一内容");
        assert!(!same_content("a\nb\n", "a\nc\n"));
        assert!(!same_content("a\n", "a\nb\n"), "多一行就是不同");
    }

    /// 元数据 sidecar 往返 + **老数据（没有 meta）不报错**
    #[test]
    fn meta_roundtrip_and_missing_is_ok() {
        let dir = std::env::temp_dir().join(format!("sourin_meta_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        // ★ 老数据：本机 26 个插件全都没有 meta → 必须返回 None，不是 Err
        assert!(
            read_plugin_meta(&dir, "nonexistent").is_none(),
            "没有 meta 是**正常状态**（手动放入的插件），不能报错"
        );

        let m = PluginSourceMeta {
            source_url: Some("https://example.com/x.js".into()),
            installed_version: "1.2.3".into(),
            installed_at: 1234567,
            file: "x.js".into(),
        };
        write_plugin_meta(&dir, "x", &m).unwrap();
        let got = read_plugin_meta(&dir, "x").expect("应能读回");
        assert_eq!(got.source_url.as_deref(), Some("https://example.com/x.js"));
        assert_eq!(got.installed_version, "1.2.3");
        assert_eq!(got.installed_at, 1234567);

        // ★ 坏 JSON 也不能让调用方失败（设置页要能列出全部插件）
        std::fs::write(plugin_meta_dir(&dir).join("bad.json"), "{ not json").unwrap();
        assert!(read_plugin_meta(&dir, "bad").is_none(), "坏 meta 当作没有来源");

        // ★ id 含非法字符 → 不能写出目录外（防目录穿越）
        let evil = PluginSourceMeta::default();
        assert!(write_plugin_meta(&dir, "../escape", &evil).is_err());
        assert!(read_plugin_meta(&dir, "../escape").is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 历史档：归档 → 列出（新→旧）→ 超过上限自动清理
    #[test]
    fn versions_archive_list_and_prune() {
        let dir = std::env::temp_dir().join(format!("sourin_ver_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        // 没有历史 → 空列表（不是错误）
        assert!(list_plugin_versions(&dir, "p").is_empty());

        // ★ 归档 7 档（超过 MAX=5）验证清理
        for v in ["1.0.0", "1.1.0", "1.2.0", "1.9.0", "1.10.0", "1.11.0", "2.0.0"] {
            archive_plugin_version(&dir, "p", v, &format!("// {v}")).unwrap();
        }
        let all = list_plugin_versions(&dir, "p");
        assert_eq!(all.len(), 7, "清理前应有 7 档");

        // ★ 排序必须是**版本序**而不是文件名字符串序：
        //   1.10.0 要排在 1.9.0 **前面**（字符串序会反过来）
        let vs: Vec<&str> = all.iter().map(|(v, _)| v.as_str()).collect();
        assert_eq!(
            vs,
            vec!["2.0.0", "1.11.0", "1.10.0", "1.9.0", "1.2.0", "1.1.0", "1.0.0"],
            "历史档必须按版本号新→旧（不能按文件名字符串）"
        );

        // 清理：只留最近 5 档
        let removed = prune_plugin_versions(&dir, "p");
        assert_eq!(removed, 2, "7 档留 5 → 应删 2");
        let after: Vec<String> = list_plugin_versions(&dir, "p")
            .into_iter()
            .map(|(v, _)| v)
            .collect();
        assert_eq!(after, vec!["2.0.0", "1.11.0", "1.10.0", "1.9.0", "1.2.0"]);
        assert_eq!(MAX_PLUGIN_VERSIONS, 5);
        // 再清一次不动（幂等）
        assert_eq!(prune_plugin_versions(&dir, "p"), 0);

        // 别的插件的档不能被误删/误列
        archive_plugin_version(&dir, "q", "9.9.9", "// q").unwrap();
        assert_eq!(list_plugin_versions(&dir, "q").len(), 1);
        assert_eq!(list_plugin_versions(&dir, "p").len(), 5);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 归档的版本号含非法字符要过滤（版本号来自插件作者，不可信）
    #[test]
    fn archive_sanitizes_version_in_filename() {
        let dir = std::env::temp_dir().join(format!("sourin_san_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let p = archive_plugin_version(&dir, "p", "../../evil/1.0", "// x").unwrap();
        // 必须还在 .versions/ 里（没穿出去）
        assert!(
            p.starts_with(plugin_versions_dir(&dir)),
            "版本号里的路径分隔符必须被过滤掉：{p:?}"
        );
        // 非法 id 直接拒绝
        assert!(archive_plugin_version(&dir, "../x", "1.0", "// x").is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 多行写法同样支持
    #[test]
    fn parses_meta_multi_line() {
        let src = "/**\n * @id demo\n * @name 示例源\n * @description 这是一个示例\n */\n";
        let m = parse_meta(src);
        assert_eq!(m.id, "demo");
        assert_eq!(m.name, "示例源");
        assert_eq!(m.description, "这是一个示例");
    }

    /// 缺 @id 必须报错（没有唯一标识就无法注册）
    #[test]
    fn rejects_plugin_without_id() {
        let err = JsPluginProvider::from_source("/** @name 无 id */").unwrap_err();
        assert!(err.contains("@id"), "错误信息应指出缺 @id，实际: {err}");
    }

    /// 缺 @name 也要报错（界面上无法展示）
    #[test]
    fn rejects_plugin_without_name() {
        let err = JsPluginProvider::from_source("/** @id x */").unwrap_err();
        assert!(err.contains("@name"), "实际: {err}");
    }

    /// 正常插件应能构建，且元信息落到 manifest
    #[test]
    fn builds_provider_from_valid_source() {
        let src = "/** @id cctv @name 央视网 @version 2.0.0 */\n";
        let p = JsPluginProvider::from_source(src).unwrap();
        let m = p.manifest();
        assert_eq!(m.id, "cctv");
        assert_eq!(m.name, "央视网");
        assert_eq!(m.version, "2.0.0");
        assert_eq!(m.kind, "js");
        // id 前缀要带上，避免与其它源撞 id
        assert_eq!(m.id_prefixes, vec!["cctv:".to_string()]);
    }

    /// 缺版本号时给默认值（不阻断加载）
    #[test]
    fn defaults_version_when_missing() {
        let p = JsPluginProvider::from_source("/** @id x @name X */").unwrap();
        assert_eq!(p.manifest().version, "1.0.0");
    }

    /// 错误映射：插件抛的前缀要转成对应的 ErrorKind
    #[test]
    fn maps_prefixed_js_errors() {
        assert_eq!(
            map_js_error("unauthorized: token 过期").kind,
            ErrorKind::Unauthorized
        );
        assert_eq!(map_js_error("not_found: 没有这个视频").kind, ErrorKind::NotFound);
        assert_eq!(map_js_error("unsupported: 不支持搜索").kind, ErrorKind::Unsupported);
        assert_eq!(map_js_error("network: 站点无响应").kind, ErrorKind::Network);
    }

    // ─────────── ★ 端到端：插件真的能跑 ───────────

    /// ★★ 最核心的一条：插件能返回结构化数据，宿主能解析
    ///
    /// 这条测试覆盖「JS 求值 → JSON.stringify → Rust 反序列化」全链路。
    /// 不需要网络（插件里不调 http）。
    #[tokio::test]
    async fn plugin_returns_sections_without_network() {
        let src = r#"
/** @id t1 @name 测试源 */
globalThis.plugin = {
  async home() {
    return [
      { id: 'a', title: '区块A', source: { type: 'category', categoryId: '1' } },
      { id: 'b', title: '区块B', source: { type: 'rank', rankId: '9' } },
    ];
  },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();
        let sections = p.home().await.expect("home() 应成功");

        assert_eq!(sections.len(), 2);
        assert_eq!(sections[0].title, "区块A");
        // SectionSource 是带 tag 的枚举，确认解析到了正确的变体
        match &sections[0].source {
            SectionSource::Category { category_id } => assert_eq!(category_id, "1"),
            other => panic!("第一个区块应是 Category，实际 {other:?}"),
        }
        match &sections[1].source {
            SectionSource::Rank { rank_id } => assert_eq!(rank_id, "9"),
            other => panic!("第二个区块应是 Rank，实际 {other:?}"),
        }
    }

    /// 插件返回列表页时，字段要能正确映射到 `Page<MediaItem>`
    #[tokio::test]
    async fn plugin_returns_paged_items() {
        let src = r#"
/** @id t2 @name 测试源 */
globalThis.plugin = {
  async list(req) {
    return {
      items: [
        { id: 'v1', title: '影片一', cover: 'https://x/1.jpg', kind: 'movie' },
        { id: 'v2', title: '影片二' },
      ],
      page: req.page,
      total: 42,
    };
  },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();
        let page = p
            .list(ListRequest {
                category_id: "cat1".into(),
                page: 3,
                filters: Default::default(),
            })
            .await
            .expect("list() 应成功");

        assert_eq!(page.items.len(), 2);
        assert_eq!(page.items[0].title, "影片一");
        assert_eq!(page.page, 3, "插件应收到并回传请求里的页码");
        assert_eq!(page.total, Some(42));
    }

    /// ★ 熔断必须生效：插件写死循环要能被终止，且**不能等太久**
    ///
    /// 实测教训：按 tick 计数的方式跑了 **168 秒**才触发，
    /// 一个坏插件能卡死应用近 3 分钟。改成按墙钟时间后精确终止。
    /// 这条测试锁死「必须按时间」这个结论。
    #[tokio::test]
    async fn infinite_loop_is_interrupted_quickly() {
        let src = r#"
/** @id bad @name 坏插件 */
globalThis.plugin = {
  async home() {
    while (true) {}   // 故意死循环
  },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();

        let t0 = std::time::Instant::now();
        let r = p.home().await;
        let ms = t0.elapsed().as_millis();

        assert!(r.is_err(), "死循环必须报错而不是永远挂着");
        assert!(
            ms < 20_000,
            "中断耗时 {ms} ms，太慢了（预算 {SCRIPT_BUDGET_MS} ms）—— \
             检查中断处理器是不是改回按 tick 计数了"
        );
        // 错误信息要让用户看得懂
        let msg = format!("{}", r.unwrap_err());
        assert!(msg.contains("超时"), "错误信息应说明是超时，实际: {msg}");
    }

    /// 插件抛异常时，错误要能被映射成合适的 ErrorKind
    #[tokio::test]
    async fn plugin_exception_maps_to_error_kind() {
        let src = r#"
/** @id t3 @name 测试源 */
globalThis.plugin = {
  async home() { throw new Error('unauthorized: 登录已失效'); },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();
        let err = p.home().await.unwrap_err();
        assert_eq!(err.kind, ErrorKind::Unauthorized);
    }

    /// ★ 插件真的能发 HTTP 并解析响应
    ///
    /// 打真实站点（央视栏目接口，公开无需鉴权）。
    /// 这条通过 = 「插件自己发请求 → 解析 → 返回结构化数据」全链路可用，
    /// 也就是 cctv 能被搬成插件的前提。
    #[tokio::test]
    #[ignore = "需要网络"]
    async fn plugin_can_fetch_and_parse_real_http() {
        let src = r#"
/** @id net @name 联网测试 */
const API = 'https://api.cntv.cn/lanmu/columnSearch?&fl=&p=1&n=3&serviceId=tvcctv';
globalThis.plugin = {
  async home() {
    const raw = await host.http.get(API);
    const j = JSON.parse(raw);
    return j.response.docs.map(d => ({
      id: 'col-' + d.column_id,
      title: d.column_name,
      source: { type: 'category', categoryId: d.column_id },
    }));
  },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();
        let sections = p.home().await.expect("联网取栏目应成功");

        assert!(!sections.is_empty(), "应至少拿到一个栏目");
        // 央视「新闻联播」是稳定存在的栏目
        let titles: Vec<&str> = sections.iter().map(|s| s.title.as_str()).collect();
        assert!(
            titles.iter().any(|t| t.contains("新闻联播")),
            "应包含新闻联播，实际: {titles:?}"
        );
    }

    /// ★★ POST 必须带 `Content-Type: application/json`
    ///
    /// 实测踩过（cycani 登录）：reqwest 的 `.body(String)` 默认发
    /// `text/plain`，服务端解析不了 JSON body，报的却是
    /// `Username is a required field` —— **看起来像参数没传**，
    /// 实际是 body 根本没被解析。这类问题极难从报错里看出来。
    ///
    /// 这条测试打一个回显请求头的服务，确认 Content-Type 正确。
    #[tokio::test]
    #[ignore = "需要网络"]
    async fn post_sends_json_content_type() {
        // httpbin 的回显接口会返回我们发过去的头
        let out = do_http(
            &None,
            "POST",
            "https://httpbin.org/post",
            &HashMap::new(),
            Some(r#"{"a":1}"#.to_string()),
        )
        .await;

        if out.starts_with("__ERR__") {
            // 网络不可达时跳过（不让环境问题把测试判成失败）
            eprintln!("跳过：httpbin 不可达 — {}", &out[..out.len().min(80)]);
            return;
        }
        assert!(
            out.to_lowercase().contains("application/json"),
            "POST 应带 application/json，实际响应: {}",
            &out[..out.len().min(300)]
        );
    }

    /// ★ 插件私有存储：读写与删除
    #[test]
    fn plugin_store_roundtrip() {
        let dir = std::env::temp_dir().join(format!("dsh-pl-store-{}", std::process::id()));

        // 未写过 → None
        assert!(store_read(&dir, "p1", "token").is_none());

        store_write(&dir, "p1", "token", Some("abc".into())).unwrap();
        assert_eq!(store_read(&dir, "p1", "token").as_deref(), Some("abc"));

        // ★ 插件之间必须隔离（p2 读不到 p1 的值）
        assert!(
            store_read(&dir, "p2", "token").is_none(),
            "不同插件的存储必须隔离"
        );

        // 多键共存
        store_write(&dir, "p1", "other", Some("x".into())).unwrap();
        assert_eq!(store_read(&dir, "p1", "token").as_deref(), Some("abc"));
        assert_eq!(store_read(&dir, "p1", "other").as_deref(), Some("x"));

        // 删除只删指定键
        store_write(&dir, "p1", "token", None).unwrap();
        assert!(store_read(&dir, "p1", "token").is_none());
        assert_eq!(store_read(&dir, "p1", "other").as_deref(), Some("x"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 存储文件损坏时应当作「空」而不是让插件崩掉
    #[test]
    fn plugin_store_survives_corrupt_file() {
        let dir = std::env::temp_dir().join(format!("dsh-pl-corrupt-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(store_path(&dir, "p1"), "{ 这不是 JSON").unwrap();

        // 读到 None 而不是 panic
        assert!(store_read(&dir, "p1", "k").is_none());
        // 而且还能正常写入（覆盖掉坏文件）
        store_write(&dir, "p1", "k", Some("v".into())).unwrap();
        assert_eq!(store_read(&dir, "p1", "k").as_deref(), Some("v"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★★ 插件的每个可选方法都必须**真的被桥接**
    ///
    /// 实测踩过两次同类问题：
    ///   · `rank()` —— cycani 首页声明了「TV番组榜」区块、插件也实现了
    ///     `rank()`，但宿主漏桥接 → 走 trait 默认实现 →
    ///     首页那两个区块**永远空白**，插件作者完全不知道为什么
    ///   · `episodes()` / `sources()` —— 同理
    ///
    /// 这类 bug **不报错、只是没内容**，最难发现。
    /// 这条测试用一个「实现了全部可选方法」的插件逐个调一遍。
    #[tokio::test]
    async fn all_optional_methods_are_bridged() {
        let src = r#"
/** @id full @name 全方法插件 */
globalThis.plugin = {
  id: 'full',
  capabilities: { vod: true, live: true, epg: true, timeshift: true, search: true },
  async home() { return []; },
  async categories() { return []; },
  async list() { return { items: [], page: 1 }; },
  async rank(rankId, page) {
    return { items: [{ id: 'r1', title: '榜单项' }], page: page, total: 1 };
  },
  async search() { return { items: [], page: 1 }; },
  async detail(id) {
    return { id: id, title: '详情', sources: [{ code: 's1', title: '线路一', count: 2 }], episodes: [] };
  },
  async episodes(id, code) {
    return [{ id: 'e1', title: '第1集', order: 1 }, { id: 'e2', title: '第2集', order: 2 }];
  },
  async sources(id) {
    return [{ code: 's1', title: '线路一', count: 2 }];
  },
  async resolve(id, req) { return [{ url: 'https://x/a.m3u8', quality: '原画', kind: 'hls' }]; },
  async liveChannels() { return [{ id: 'c1', name: '频道一' }]; },
  async liveStream(cid) { return [{ url: 'https://x/l.m3u8', kind: 'hls' }]; },
  async epg(cid) { return [{ title: '节目', start: 1, end: 2, duration: 1, replayable: true }]; },
  async timeshift(cid, s, e) { return { url: 'https://x/t.m3u8', kind: 'hls' }; },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();
        let id = MediaId::new("full", "v1");

        // rank —— 曾经漏桥接的那个
        let r = p.rank("1", 1).await.expect("rank 必须被桥接");
        assert_eq!(r.items.len(), 1);
        assert_eq!(r.items[0].title, "榜单项");

        // episodes —— 曾经漏桥接
        let eps = p.episodes(&id, "s1").await.expect("episodes 必须被桥接");
        assert_eq!(eps.len(), 2, "应拿到插件返回的 2 集，而不是 detail 的空列表");

        // sources
        let srcs = p.sources(&id).await.expect("sources 必须被桥接");
        assert_eq!(srcs.len(), 1);
        assert_eq!(srcs[0].title, "线路一");

        // live / epg / timeshift
        let chans = p.live_channels().await.expect("liveChannels 必须被桥接");
        assert_eq!(chans.len(), 1);
        let live = p.live_stream("c1").await.expect("liveStream 必须被桥接");
        assert_eq!(live.len(), 1);
        let epg = p.epg("c1", None).await.expect("epg 必须被桥接");
        assert_eq!(epg.len(), 1);
        let ts = p
            .timeshift("c1", 1, 2)
            .await
            .expect("timeshift 必须被桥接");
        assert!(ts.url.contains("t.m3u8"));
    }

    /// ★★★ `epg` / `timeshift` 未实现时必须优雅降级（2026-09-25 修的真 bug）
    ///
    /// # 为什么单独一条（`missing_optional_methods_degrade_gracefully` 没覆盖到）
    /// ```text
    /// 那条测的是 session/logout/rank 等；而 `epg`/`timeshift` **漏了**。
    /// ★ 上面 `bridges_live_epg_timeshift`（L3397）用的是**实现了 epg 的插件**
    ///   ⇒ 「声明 false 且不实现」这条路径**从来没有被测过**
    ///   ⇒ 所以 bug 上线了（真机切台每次刷 `插件报错: not a function`）。
    /// ```
    ///
    /// # 真实复现（`.probe/t42_epg_repro.py`，走真实 FFI）
    /// ```text
    /// get_epg("iptv", …)  ⇒ {"error":"插件报错: not a function"}   ← 修前
    /// get_epg("cctv", …)  ⇒ [{"title":…}]                          ← 阳性对照
    /// ```
    ///
    /// # 两者的**不同**降级方式（不是笔误，是刻意区分）
    /// ```text
    /// · `epg()`      → `Ok(vec![])`      —— EPG **本来就是可选的**
    ///                   （"没有节目单"是正常状态，不是错误）
    /// · `timeshift()`→ `Err(unsupported)` —— 返回类型 `StreamCandidate`
    ///                   **没有"空流"这种合法值** ⇒ 必须让调用方区分
    ///                   "这个源不支持时移" 与 "时移失败了"
    /// ```
    #[tokio::test]
    async fn unimplemented_epg_and_timeshift_degrade_gracefully() {
        let src = r#"
/** @id nolive @name 没有 EPG 的插件 */
globalThis.plugin = {
  id: 'nolive',
  // ★ 声明 false 且**不实现** —— 正是 iptv.js 的形态
  capabilities: { vod: true, live: true, epg: false },
  async liveChannels() { return [{ id: 'c1', name: '频道一' }]; },
  async liveStream() { return [{ url: 'https://x/a.m3u8', kind: 'hls' }]; },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();

        /*
         * ① EPG：必须返回**空列表**，不是错误
         *
         * ⚠️ 修前这里会拿到 `Err("插件报错: not a function")`
         *    ⇒ 每次切台都刷一条错误日志（真机实测）。
         */
        let epg = p
            .epg("c1", None)
            .await
            .expect("★ 没实现 epg ⇒ 返回空列表，**不是** Err（否则用户每次切台都看到报错）");
        assert!(epg.is_empty(), "没实现 epg ⇒ 空列表，实际 {} 条", epg.len());

        /*
         * ② timeshift：必须返回**明确的 unsupported**，也不是「not a function」
         *
         * ★ 为什么要区分 `kind`：
         *   调用方据此决定"隐藏时移按钮"（不支持）还是"提示重试"（失败）。
         *   若报成 `Other`，UI 会当成"出错了" ⇒ 给用户一个无意义的报错。
         */
        let err = p
            .timeshift("c1", 0, 100)
            .await
            .expect_err("没实现 timeshift ⇒ 必须报错（没有「空流」这种合法值）");
        assert_eq!(
            err.kind,
            ErrorKind::Unsupported,
            "★ 必须是 Unsupported（让调用方能区分「不支持」与「失败」），实际: {:?} / {}",
            err.kind,
            err.message
        );
        assert!(
            !err.message.contains("not a function"),
            "★ 绝不能是「not a function」—— 那是宿主没做守卫的锅，不该让用户看到: {}",
            err.message
        );
    }

    /// 插件**没实现**的可选方法要优雅降级，不能报「is not a function」
    ///
    /// 宿主在启动与聚合时会普遍地问一遍（如 `session()`），
    /// 一个不需要登录的插件被问到不该刷错误日志。
    #[tokio::test]
    async fn missing_optional_methods_degrade_gracefully() {
        let src = r#"
/** @id mini @name 最小插件 */
globalThis.plugin = {
  id: 'mini',
  capabilities: { vod: true },
  async resolve() { return [{ url: 'https://x/a.mp4', kind: 'mp4' }]; },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();
        let id = MediaId::new("mini", "v1");

        // 这些都不该 panic / 报 "is not a function"
        assert!(p.session().await.unwrap().is_none(), "没实现 session → None");
        assert!(p.logout().await.is_ok(), "没实现 logout → Ok");
        assert!(
            p.refresh_session().await.unwrap().is_none(),
            "没实现 refreshSession → None"
        );
        assert!(!p.can_auto_login().await, "没实现 canAutoLogin → false");
        assert!(
            p.rank("1", 1).await.is_err(),
            "没实现 rank → 报「不支持」而不是崩"
        );

        // episodes/sources 没实现时退回 detail（trait 的语义）
        // —— mini 也没实现 detail，所以这里应报错而不是 panic
        assert!(p.episodes(&id, "s1").await.is_err());
    }

    /// ★★ 自动重登链路必须完整（Owner 报「没有验证码的应该自动重登」）
    ///
    /// `Registry::ensure_session()` 的链路是：
    /// ```
    /// login_required? → session_needs_refresh? → refresh_session()
    ///   → 失败 → can_auto_login() → auto_login()
    /// ```
    /// 任何一环没桥接，自动重登都不会发生 —— 而**不会报错**，
    /// 只是用户每次 token 过期都要手动重登。
    #[tokio::test]
    async fn auto_login_chain_is_bridged() {
        let src = r#"
/** @id auto @name 自动重登测试 */
globalThis.plugin = {
  id: 'auto',
  capabilities: { vod: true, loginRequired: true },
  async session() { return null; },
  async refreshSession() { return null; },   // 续期失败
  async canAutoLogin() { return true; },     // ★ 有凭据，能重登
  async autoLogin() {
    return { token: 'Bearer new-token', displayName: 'tester' };
  },
  async resolve() { return []; },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();

        // 1) 这几个方法都要被识别为「已实现」
        assert!(p.has_method("session").await);
        assert!(p.has_method("refreshSession").await);
        assert!(p.has_method("canAutoLogin").await);
        assert!(p.has_method("autoLogin").await);
        assert!(
            !p.has_method("forgetCredentials").await,
            "没实现的方法不该报 true"
        );

        // 2) 续期返回 None（插件表示「不支持续期」）
        assert!(p.refresh_session().await.unwrap().is_none());

        // 3) ★ 关键：canAutoLogin 必须为 true，否则宿主不会去 autoLogin
        assert!(
            p.can_auto_login().await,
            "canAutoLogin 必须被桥接 —— 否则自动重登永远不会发生"
        );

        // 4) ★ 关键：autoLogin 必须能拿到新会话
        let s = p
            .auto_login()
            .await
            .expect("autoLogin 必须被桥接")
            .expect("应返回会话");
        assert_eq!(s.token, "Bearer new-token");
        assert_eq!(s.display_name.as_deref(), Some("tester"));
    }

    /// ★★ 语法错误必须报「语法错误」，不能报「执行超时」
    ///
    /// 实测踩到（编辑插件保存时）：语法错误（括号不配对）会让 `eval` 抛
    /// QuickJS 自身异常，而错误分类把「QuickJS 异常」一律当成**中断超时** →
    /// 用户看到「插件执行超时（超过 10000 ms）」，跑去查超时原因，
    /// **永远查不到**（其实是写错了）。
    ///
    /// 这条测试锁死「两种错误必须分开报」。
    #[tokio::test]
    async fn syntax_error_is_not_reported_as_timeout() {
        // 故意写坏：括号不配对
        let src = r#"
/** @id broken @name 坏插件 */
globalThis.plugin = {
  async resolve() { return []; },
(((
"#;
        let p = JsPluginProvider::from_source(src).unwrap();
        let err = p.resolve(&MediaId::new("broken", "x"), &PlayRequest::default()).await;
        let e = err.unwrap_err();
        let msg = e.message.clone();

        assert!(
            msg.contains("语法错误"),
            "语法错误必须如实说明，实际: {msg}"
        );
        assert!(
            !msg.contains("超时"),
            "语法错误**不能**被误报成超时（那会让用户查错方向），实际: {msg}"
        );
    }

    /// 对照：真正的死循环**必须**报超时（不能被当成语法错误）
    #[tokio::test]
    async fn real_infinite_loop_reports_timeout() {
        let src = r#"
/** @id loop2 @name 死循环 */
globalThis.plugin = {
  async home() { while (true) {} },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();
        let e = p.home().await.unwrap_err();
        assert!(
            e.message.contains("超时"),
            "死循环必须报超时，实际: {}",
            e.message
        );
    }

    /// ★ 随程序发布的 demo.js 必须是**合法且真的能加载**的
    ///
    /// demo 是用户照着写插件的模板 —— 它自己要是坏的，用户会被误导。
    #[test]
    fn shipped_demo_is_loadable() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("plugins/demo.js");
        let src = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("读不到 {}: {e}", path.display()));

        let p = JsPluginProvider::from_source(&src)
            .unwrap_or_else(|e| panic!("demo.js 不是合法插件: {e}"));

        assert_eq!(p.manifest().id, "demo");
        assert!(!p.manifest().name.is_empty());
    }

    /// 一个坏插件不能影响其它插件加载（扫描目录时隔离失败）
    #[test]
    fn bad_plugin_does_not_block_others() {
        let dir = std::env::temp_dir().join(format!("dsh-plugin-test-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);

        std::fs::write(dir.join("good.js"), "/** @id good @name 好插件 */\n").unwrap();
        std::fs::write(dir.join("bad.js"), "// 没有 @id，应被拒绝\n").unwrap();
        std::fs::write(dir.join("notjs.txt"), "忽略非 .js 文件").unwrap();

        let (ok, bad) = load_plugins(&dir);
        let _ = std::fs::remove_dir_all(&dir);

        assert_eq!(ok.len(), 1, "好插件应被加载");
        assert_eq!(ok[0].manifest().id, "good");
        assert_eq!(bad.len(), 1, "坏插件应被记录而不是拖垮整体");
        assert_eq!(bad[0].0, "bad.js");
    }

    // ─────────── 命名风格转换（契约承诺「宿主自动转」）───────────

    /// `categoryId` → `category_id`，递归含嵌套与数组
    #[test]
    fn converts_camel_case_to_snake_recursively() {
        let js = serde_json::json!({
            "id": "a",
            "title": "区块A",
            "source": { "type": "category", "categoryId": "1" },
            "items": [{ "id": "v1", "pageCount": 3 }],
        });
        let rust = js_value_to_rust(js);

        assert_eq!(rust["source"]["category_id"], "1");
        assert_eq!(rust["items"][0]["page_count"], 3);
        // 原本就是小写的键不受影响
        assert_eq!(rust["source"]["type"], "category");
        assert_eq!(rust["title"], "区块A");
    }

    /// ★ `headers` 必须从对象转成键值对数组
    ///
    /// Rust 侧是 `Vec<(String, String)>`，插件按契约写 `{ Referer: 'x' }`，
    /// 不转的话 serde 会报 `invalid type: map, expected a sequence`。
    #[test]
    fn converts_headers_object_to_pairs() {
        let js = serde_json::json!({
            "url": "https://x/a.m3u8",
            "headers": { "Referer": "https://x/", "User-Agent": "UA" },
        });
        let rust = js_value_to_rust(js);

        let h = rust["headers"].as_array().expect("headers 应转成数组");
        assert_eq!(h.len(), 2);
        // 每项是 [key, value]
        assert!(h.iter().all(|p| p.as_array().map(|a| a.len()) == Some(2)));
    }

    /// 反向：Rust → 插件（`episode_id` → `episodeId`）
    #[test]
    fn converts_snake_case_to_camel_for_plugin_args() {
        let rust = serde_json::json!({
            "source_code": "line1",
            "episode_id": "ep5",
        });
        let js = rust_value_to_js(rust);
        assert_eq!(js["sourceCode"], "line1");
        assert_eq!(js["episodeId"], "ep5");
        // 不应残留 snake_case 键
        assert!(js.get("episode_id").is_none());
    }

    /// ★ 能力位必须能读到（含多词字段）
    ///
    /// 实测踩过：`hydrate_capabilities` 读的是 `loginRequired`，
    /// 但 `call_js` 出口已经把键转成 `login_required` 了 ——
    /// 于是 cycani 的 `loginRequired: true` **完全没生效**：
    /// 界面不显示登录入口、会话状态是 `not_required`，用户没法登录。
    ///
    /// 这条测试覆盖「插件写 camelCase → 能力位正确落到 manifest」全链路。
    #[tokio::test]
    async fn hydrates_capabilities_including_multiword() {
        let src = r#"
/** @id caps @name 能力测试 */
globalThis.plugin = {
  capabilities: {
    vod: true,
    search: true,
    loginRequired: true,
    multiSource: true,
    serverSideHistory: true,
  },
};
"#;
        let mut p = JsPluginProvider::from_source(src).unwrap();
        // 执行前是保守默认值
        assert!(!p.manifest().capabilities.login_required);

        p.hydrate_capabilities().await;

        let c = &p.manifest().capabilities;
        assert!(c.vod, "vod 应被读到");
        assert!(c.search, "search 应被读到");
        assert!(
            c.login_required,
            "★ loginRequired 必须读到（多词字段，转换后是 login_required）"
        );
        assert!(c.multi_source, "★ multiSource 必须读到");
        assert!(c.server_side_history, "★ serverSideHistory 必须读到");
        // 没声明的要保持 false
        assert!(!c.live, "未声明的 live 不该变成 true");
    }

    // ═══════════════════════════════════════════════════════════════
    //  task-9 ③：resolve 的**第一个参数**选谁（Owner：「播放第二集实际还是第一集」）
    // ═══════════════════════════════════════════════════════════════

    /// ★★★ episode_id 是 http(s) URL ⇒ 用它当第一个参数
    ///
    /// # 为什么
    ///
    /// tvbox 转换插件的 ¤detail()¤ 里剧集 id **就是剧集地址**
    /// （¤154.js:369  id: e.url¤），而它的 ¤resolve(id)¤ 只认第一个参数、
    /// **完全忽略 req**（¤154.js:392¤）⇒ 宿主若传条目 id，它就去查详情、
    /// 取 ¤eps[0]¤ ⇒ **永远第一集**（Owner 报的 bug）。
    #[test]
    fn resolve_first_arg_uses_episode_url() {
        let src = "/** @id t9tvbox @name 测试 */\n";
        let p = JsPluginProvider::from_source(src).unwrap();

        // 插件把收到的第一个参数原样回吐（探针插件）
        let req = PlayRequest {
            source_code: None,
            episode_id: Some("https://cdn.test/e2.m3u8".into()),
            quality: None,
        };
        let arg = p.resolve_first_arg(&MediaId::new("t9tvbox", "150758"), &req);
        assert_eq!(
            arg, "https://cdn.test/e2.m3u8",
            "★ 第2集地址必须原样成为第一个参数（否则插件会退回第一集）"
        );
    }

    /// ★★ 反向控制：episode_id **不是** URL ⇒ 与改前**逐字相同**（传条目 id）
    ///
    /// 这条是"不许把次元城打坏"的护栏：cycani 拿 ¤episode_id¤ 当 section_id，
    /// 若不加判断地一律替换，它收到的东西就变了。
    #[test]
    fn resolve_first_arg_keeps_native_id_for_non_url() {
        let src = "/** @id cycani @name 测试 */\n";
        let p = JsPluginProvider::from_source(src).unwrap();
        let id = MediaId::new("cycani", "51463");

        for ep in [Some("51463"), Some("cycani:51463"), Some(""), None] {
            let req = PlayRequest {
                source_code: None,
                episode_id: ep.map(|s| s.to_string()),
                quality: None,
            };
            assert_eq!(
                p.resolve_first_arg(&id, &req),
                "51463",
                "episode_id={ep:?} 时必须维持原行为（传剥过前缀的条目 id）"
            );
        }
    }

    /// ★ 前缀剥除仍然生效（改动的另一条护栏）
    #[test]
    fn resolve_first_arg_still_strips_prefix() {
        let src = "/** @id cycani @name 测试 */\n";
        let p = JsPluginProvider::from_source(src).unwrap();
        let req = PlayRequest {
            source_code: None,
            episode_id: Some("cycani:51463".into()),
            quality: None,
        };
        // 条目 id 带自己的前缀 ⇒ 剥掉
        assert_eq!(
            p.resolve_first_arg(&MediaId::new("cycani", "cycani:51463"), &req),
            "51463"
        );
        // 别的 provider 的前缀不动
        assert_eq!(
            p.resolve_first_arg(&MediaId::new("cycani", "other:abc"), &req),
            "other:abc"
        );
    }

    /// ★★ 前缀只能加在**媒体条目**上，不能误伤剧集/线路/区块
    ///
    /// 实测踩到（Owner 报「从追更进入报错」）：
    /// `Episode` 也长着 `{id, title}` 的样子，于是剧集 id 被加前缀
    /// 变成 `cycani:51463`，前端放进 `PlayRequest.episode_id` 传回来，
    /// 插件拿它当数字 id → 服务端报
    /// `bind uri "section_id": parsing "cycani:51463": invalid syntax`。
    #[test]
    fn prefix_only_applies_to_media_items() {
        let src = "/** @id cycani @name 测试 */\n";
        let p = JsPluginProvider::from_source(src).unwrap();

        let mut v = serde_json::json!({
            // 媒体条目 → 应加前缀
            "items": [{ "id": "900", "title": "作品", "cover": "x.jpg" }],
            // 剧集 → **不该**加（有 order）
            "episodes": [
                { "id": "51463", "title": "第01集", "order": 1 },
                { "id": "51464", "title": "第02集", "order": 2 }
            ],
            // 播放源 → 不该加（有 code + count）
            "sources": [{ "code": "CYC_Main", "title": "线路", "count": 12 }],
            // 区块 → 不该加（有 source）
            "sections": [
                { "id": "cycani-rank-1", "title": "榜单", "source": { "type": "rank", "rankId": "1" } }
            ]
        });
        p.prefix_media_ids(&mut v);

        // 媒体条目：加了
        assert_eq!(v["items"][0]["id"], "cycani:900", "媒体条目应加前缀");

        // ★ 剧集：必须保持原样（这是 bug 的核心）
        assert_eq!(
            v["episodes"][0]["id"], "51463",
            "剧集 id 不能加前缀 —— 加了会让取流接口报 invalid syntax"
        );
        assert_eq!(v["episodes"][1]["id"], "51464");

        // 播放源 / 区块：保持原样
        assert_eq!(v["sources"][0]["code"], "CYC_Main");
        assert_eq!(v["sections"][0]["id"], "cycani-rank-1");
    }

    /// ★ 转换函数本身要正确（含边界）
    #[test]
    fn naming_helpers_are_correct() {
        assert_eq!(camel_to_snake("categoryId"), "category_id");
        assert_eq!(camel_to_snake("id"), "id");
        assert_eq!(camel_to_snake("notWebReady"), "not_web_ready");
        assert_eq!(camel_to_snake("drmProtected"), "drm_protected");

        assert_eq!(snake_to_camel("category_id"), "categoryId");
        assert_eq!(snake_to_camel("id"), "id");
        assert_eq!(snake_to_camel("not_web_ready"), "notWebReady");
    }

    // ─────────── 在线安装的地址解析 ───────────

    /// ★ GitHub 页面地址必须转成 **CDN 直链**
    ///
    /// 实测 `raw.githubusercontent.com` 国内直连 **12 秒超时**，
    /// 而 `cdn.jsdelivr.net` 1.1 秒可用 —— 所以默认必须走 jsDelivr，
    /// 否则用户粘了 GitHub 地址会一直转圈。
    #[test]
    fn converts_github_url_to_cdn() {
        assert_eq!(
            resolve_plugin_url("https://github.com/user/repo").unwrap(),
            "https://cdn.jsdelivr.net/gh/user/repo@main/index.js"
        );
        // 带 .git 后缀也要能处理
        assert_eq!(
            resolve_plugin_url("https://github.com/user/repo/").unwrap(),
            "https://cdn.jsdelivr.net/gh/user/repo@main/index.js"
        );
        // owner/repo 简写
        assert_eq!(
            resolve_plugin_url("user/repo").unwrap(),
            "https://cdn.jsdelivr.net/gh/user/repo@main/index.js"
        );
    }

    /// 指向具体文件的 GitHub 地址要保留路径与分支
    #[test]
    fn keeps_path_and_branch_for_blob_url() {
        assert_eq!(
            resolve_plugin_url("https://github.com/u/r/blob/main/src/x.js").unwrap(),
            "https://cdn.jsdelivr.net/gh/u/r@main/src/x.js"
        );
        assert_eq!(
            resolve_plugin_url("https://github.com/u/r/blob/dev/plugins/a.js").unwrap(),
            "https://cdn.jsdelivr.net/gh/u/r@dev/plugins/a.js"
        );
    }

    /// 已经是直链的原样返回（含自建服务器、jsDelivr、raw）
    #[test]
    fn passes_through_direct_urls() {
        for u in [
            "https://cdn.jsdelivr.net/gh/u/r@main/x.js",
            "https://raw.githubusercontent.com/u/r/main/x.js",
            "https://my-server.local/plugin.js",
        ] {
            assert_eq!(resolve_plugin_url(u).unwrap(), u, "直链不应被改写: {u}");
        }
    }

    /// 非法输入要给出**可操作的**提示，而不是笼统报错
    #[test]
    fn rejects_unrecognizable_input() {
        assert!(resolve_plugin_url("").unwrap_err().contains("请填写"));
        let e = resolve_plugin_url("这不是地址").unwrap_err();
        assert!(e.contains("GitHub") || e.contains("http"), "提示应说明支持什么，实际: {e}");
    }

    /// ★ 文件名由 id 派生，必须挡住目录穿越
    #[test]
    fn save_plugin_rejects_path_traversal() {
        let dir = std::env::temp_dir().join(format!("dsh-pl-save-{}", std::process::id()));
        // 这些 id 会拼出 `../../x.js` 之类，必须拒绝
        for bad in ["../evil", "a/b", "a\\b", "..", "a b"] {
            let r = save_plugin(&dir, bad, "/** @id x */");
            assert!(r.is_err(), "id={bad:?} 应被拒绝");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 正常 id 要能写入，且文件名可预期
    #[test]
    fn save_plugin_writes_expected_file() {
        let dir = std::env::temp_dir().join(format!("dsh-pl-ok-{}", std::process::id()));
        let (file, bytes) = save_plugin(&dir, "my-plugin_2", "/** @id my-plugin_2 */").unwrap();
        assert_eq!(file, "my-plugin_2.js");
        assert!(bytes > 0);
        assert!(dir.join(&file).exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ═══════════════ 插件配置（声明式）═══════════════

    /// 造一个测试用的配置项
    fn field(key: &str, kind: &str) -> crate::model::ConfigField {
        crate::model::ConfigField {
            key: key.into(),
            label: format!("测试项 {key}"),
            kind: kind.into(),
            default: None,
            options: Vec::new(),
            hint: None,
            placeholder: None,
            show_if: std::collections::HashMap::new(),
            min: None,
            max: None,
        }
    }

    /// ★ 核心行为：**没配过就返回默认值**，配过就返回配置值
    ///
    /// 为什么这条重要：界面上如果没配过的项显示空白，
    /// 用户不知道"本来应该是什么"，也不敢乱改。
    #[test]
    fn config_returns_default_until_set() {
        let dir = std::env::temp_dir().join(format!("dsh-cfg-def-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        let mut quality = field("quality", "select");
        quality.options = vec![crate::model::ConfigOption {
            value: "720".into(),
            label: "720P".into(),
            hint: None,
        }];
        quality.default = Some(serde_json::json!("720"));
        quality.sanitize(&mut Vec::new());

        let fields = vec![quality];

        // 没配过 → 拿到默认值
        let r = resolved_config(&dir, &fields, "p1");
        assert_eq!(r.get("quality"), Some(&serde_json::json!("720")));

        // 配过 → 拿到配置值
        let mut vals = serde_json::Map::new();
        vals.insert("quality".into(), serde_json::json!("720"));
        config_write_many(&dir, &fields, "p1", &vals).unwrap();
        let r = resolved_config(&dir, &fields, "p1");
        assert_eq!(r.get("quality"), Some(&serde_json::json!("720")));

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★ 类型校验：给 `switch` 传字符串必须被拒
    ///
    /// 为什么必须校验：界面传错类型的话，插件读到的不是布尔，
    /// 表现是"开关打开了但没生效"—— 这种 bug 极难查。
    #[test]
    fn config_rejects_wrong_type() {
        let dir = std::env::temp_dir().join(format!("dsh-cfg-type-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        let fields = vec![field("proxy", "switch")];

        let mut bad = serde_json::Map::new();
        bad.insert("proxy".into(), serde_json::json!("true")); // 字符串！不是布尔
        assert!(
            config_write_many(&dir, &fields, "p1", &bad).is_err(),
            "给 switch 传字符串必须被拒"
        );

        let mut good = serde_json::Map::new();
        good.insert("proxy".into(), serde_json::json!(true));
        assert!(config_write_many(&dir, &fields, "p1", &good).is_ok());

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `select` 的值必须在选项里（否则界面上显示不出来）
    #[test]
    fn config_select_value_must_be_in_options() {
        let dir = std::env::temp_dir().join(format!("dsh-cfg-sel-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        let mut f = field("quality", "select");
        f.options = vec![
            crate::model::ConfigOption { value: "720".into(), label: "720P".into(), hint: None },
            crate::model::ConfigOption { value: "1080".into(), label: "1080P".into(), hint: None },
        ];
        let fields = vec![f];

        let mut bad = serde_json::Map::new();
        bad.insert("quality".into(), serde_json::json!("4k")); // 不在选项里
        assert!(config_write_many(&dir, &fields, "p1", &bad).is_err());

        let mut good = serde_json::Map::new();
        good.insert("quality".into(), serde_json::json!("1080"));
        assert!(config_write_many(&dir, &fields, "p1", &good).is_ok());

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★ 未声明的键被忽略而不是报错
    ///
    /// 场景：插件升级后删掉了某个配置项，但旧的 store 里还有那个值。
    /// 如果报错，用户会遇到"升级插件后一个都存不进去"。
    #[test]
    fn config_ignores_undeclared_keys() {
        let dir = std::env::temp_dir().join(format!("dsh-cfg-und-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        let fields = vec![field("proxy", "switch")];

        let mut vals = serde_json::Map::new();
        vals.insert("proxy".into(), serde_json::json!(true));       // 已声明
        vals.insert("幽灵项".into(), serde_json::json!("x"));        // 未声明

        let n = config_write_many(&dir, &fields, "p1", &vals).unwrap();
        assert_eq!(n, 1, "只应写入已声明的那一个");

        // 未声明的值不该被写进去
        let r = resolved_config(&dir, &fields, "p1");
        assert!(r.get("幽灵项").is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 配置与 `host.store` **互不干扰**（同一文件、不同前缀）
    #[test]
    fn config_and_store_do_not_collide() {
        let dir = std::env::temp_dir().join(format!("dsh-cfg-mix-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        // store 写一个字符串
        store_write(&dir, "p1", "quality", Some("store的值".into())).unwrap();
        // config 写同名键（应落在 `cfg:` 前缀下）
        let fields = vec![field("quality", "text")];
        let mut vals = serde_json::Map::new();
        vals.insert("quality".into(), serde_json::json!("config的值"));
        config_write_many(&dir, &fields, "p1", &vals).unwrap();

        // 两者各自独立
        assert_eq!(store_read(&dir, "p1", "quality").as_deref(), Some("store的值"));
        assert_eq!(
            config_read(&dir, "p1", "quality"),
            Some(serde_json::json!("config的值"))
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★ `sanitize` 把不合法的声明**降级**而不是让插件加载失败
    #[test]
    fn field_sanitize_degrades_bad_declarations() {
        let mut warn = Vec::new();

        // 不认识的 type → info
        let mut a = field("x", "colorpicker");
        a.sanitize(&mut warn);
        assert_eq!(a.kind, "info", "不认识的 type 应降级为 info");

        // select 但没有选项 → info（否则渲染出空下拉框）
        let mut b = field("y", "select");
        b.sanitize(&mut warn);
        assert_eq!(b.kind, "info", "无选项的 select 应降级");

        // select 默认值不在选项里 → 改用第一项
        let mut c = field("z", "select");
        c.options = vec![crate::model::ConfigOption {
            value: "a".into(), label: "A".into(), hint: None,
        }];
        c.default = Some(serde_json::json!("not-in-options"));
        c.sanitize(&mut warn);
        assert_eq!(c.default, Some(serde_json::json!("a")));

        // switch 默认值不是布尔 → false
        let mut d = field("w", "switch");
        d.default = Some(serde_json::json!("yes"));
        d.sanitize(&mut warn);
        assert_eq!(d.default, Some(serde_json::json!(false)));

        // min/max 写反 → 交换
        let mut e = field("n", "number");
        e.min = Some(100.0);
        e.max = Some(10.0);
        e.sanitize(&mut warn);
        assert_eq!(e.min, Some(10.0));
        assert_eq!(e.max, Some(100.0));

        // 每一处降级都应产生警告（用户/作者要知道）
        assert!(warn.len() >= 5, "应产生足够多的警告，实际 {}", warn.len());
    }

    /// 配置写入后能**跨实例**读到（模拟重启）
    #[test]
    fn config_persists_across_instances() {
        let dir = std::env::temp_dir().join(format!("dsh-cfg-persist-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        let fields = vec![field("proxyUrl", "text")];
        let mut vals = serde_json::Map::new();
        vals.insert("proxyUrl".into(), serde_json::json!("http://127.0.0.1:7890"));
        config_write_many(&dir, &fields, "p1", &vals).unwrap();

        // 重新构造 fields（模拟重启后从插件源码重新声明）
        let fields2 = vec![field("proxyUrl", "text")];
        let r = resolved_config(&dir, &fields2, "p1");
        assert_eq!(
            r.get("proxyUrl"),
            Some(&serde_json::json!("http://127.0.0.1:7890")),
            "配置必须跨重启保留"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ═══════════════ 媒体 id 前缀 ═══════════════

    /// 造一个用于测前缀的插件（只关心 manifest.id）
    fn provider_with_id(id: &str) -> JsPluginProvider {
        let src = format!(
            r#"/** @id {id} @name 测试 @version 1.0.0 */
globalThis.plugin = {{ id: '{id}', async home() {{ return [] }} }};"#
        );
        JsPluginProvider::from_source(&src).unwrap()
    }

    /// ★★ id **含冒号**时也必须加前缀（Owner 报「B站点开显示没有路由」的根因）
    ///
    /// 原实现用 `!id.contains(':')` 判断"是否已加过前缀"，
    /// 于是 B 站插件的 `av:BV1u9ew6yEEP` 被误判为"已有前缀"而跳过 →
    /// 前端切第一个冒号拿到 `provider="av"` → 后端路由不到。
    #[test]
    fn prefix_added_even_when_id_contains_colon() {
        let p = provider_with_id("bilibili");

        let mut v = serde_json::json!({
            "items": [
                { "id": "av:BV1u9ew6yEEP", "title": "《鸣潮》先约电台" },
                { "id": "BV1cSec6tEux", "title": "不带冒号的 id" },
            ]
        });
        p.prefix_media_ids(&mut v);

        let items = v.get("items").unwrap().as_array().unwrap();
        assert_eq!(
            items[0].get("id").unwrap().as_str().unwrap(),
            "bilibili:av:BV1u9ew6yEEP",
            "★ 含冒号的 id 也必须加前缀（否则前端切出来 provider=av）"
        );
        assert_eq!(
            items[1].get("id").unwrap().as_str().unwrap(),
            "bilibili:BV1cSec6tEux"
        );
    }

    /// 幂等：已经带**本插件**前缀的不重复加
    ///
    /// 数据会往返（前端把带前缀的 id 传回来，插件可能原样返回），
    /// 所以这个函数必须能被安全地反复调用。
    #[test]
    fn prefix_is_idempotent() {
        let p = provider_with_id("bilibili");

        let mut v = serde_json::json!({
            "items": [{ "id": "bilibili:av:BV1u9ew6yEEP", "title": "已带前缀" }]
        });
        p.prefix_media_ids(&mut v);
        p.prefix_media_ids(&mut v);

        assert_eq!(
            v["items"][0]["id"].as_str().unwrap(),
            "bilibili:av:BV1u9ew6yEEP",
            "反复调用不能变成 bilibili:bilibili:..."
        );
    }

    /// 别的 provider 的前缀不该被当成"自己的前缀"而跳过
    ///
    /// 场景：跨源协作时 A 插件返回了 B 源的 id。那种 id 对 A 来说
    /// **不是**自己的前缀，应当照常加上 A 的前缀（由 A 负责解释它）。
    #[test]
    fn prefix_of_other_provider_is_not_treated_as_own() {
        let p = provider_with_id("bilibili");

        let mut v = serde_json::json!({
            "items": [{ "id": "cctv:abc123", "title": "别的源的 id" }]
        });
        p.prefix_media_ids(&mut v);

        assert_eq!(
            v["items"][0]["id"].as_str().unwrap(),
            "bilibili:cctv:abc123",
            "别人的前缀不是我的前缀 —— 判据必须精确匹配"
        );
    }

    /// 前缀 ↔ 剥前缀必须**严格互逆**（往返不能丢信息）
    ///
    /// 这是最核心的不变量：加完再剥必须回到原样，
    /// 否则详情/取流/剧集全都拿不到数据（而且不报错，极难查）。
    #[test]
    fn prefix_and_strip_are_inverse() {
        let p = provider_with_id("bilibili");

        for native in [
            "av:BV1u9ew6yEEP", // 含冒号（B 站真实形态）
            "BV1cSec6tEux",    // 不含冒号
            "a:b:c:d",         // 多冒号
            "中文id",           // 非 ASCII
            "a/b?c#d",         // 各种特殊字符
        ] {
            let mut v = serde_json::json!({ "id": native, "title": "x" });
            p.prefix_media_ids(&mut v);
            let prefixed = v["id"].as_str().unwrap();

            assert_eq!(
                p.strip_prefix(prefixed),
                native,
                "往返失败：{native} → {prefixed} → {}",
                p.strip_prefix(prefixed)
            );
        }
    }

    /// 剧集 / 播放源 / 分区**不能**被加前缀（回归保护）
    ///
    /// 实测踩过：`Episode` 也有 `{id, title}`，被加前缀后
    /// 插件拿 `cycani:51463` 当数字 id 用 → 服务端报
    /// `parsing "cycani:51463": invalid syntax`。
    #[test]
    fn non_media_objects_are_not_prefixed() {
        let p = provider_with_id("cycani");

        let mut v = serde_json::json!({
            "episodes": [{ "id": "51463", "title": "第 1 集", "order": 1 }],
            "sources": [{ "code": "default", "name": "线路", "count": 3 }],
            "sections": [{ "id": "rank-1", "title": "榜单", "source": { "type": "rank" } }]
        });
        p.prefix_media_ids(&mut v);

        assert_eq!(v["episodes"][0]["id"].as_str().unwrap(), "51463", "剧集不该加前缀");
        assert_eq!(v["sections"][0]["id"].as_str().unwrap(), "rank-1", "分区不该加前缀");
    }
}
