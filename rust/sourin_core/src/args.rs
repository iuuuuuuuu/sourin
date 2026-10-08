// ═══════════════════════════════════════════════════════════════════════
//  命令参数解码 —— 契约的**唯一所有者**（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这个文件
//
// 起因是 `.trellis/spec/guides/cross-layer-thinking-guide.md` 里的
// **Mistake 4**：
//
// > **Bad**：每个消费者各自解析同一份 payload
// > ```typescript
// > const thread = (ev as { thread?: string }).thread;  // 每个命令一份私有契约
// > ```
// > 看起来是局部的，但这意味着**每个消费者都拥有一份私有的事件契约**。
// > 下一次字段变更会改到一个命令、漏掉另一个。
// >
// > **Good**：在边界处解码一次，然后导出带类型的投影。
// >
// > **Rule**：对 JSON 流 / RPC payload / 配置文件，
// > 指定**一个所有者**负责：类型定义、类型守卫与归一化。
//
// 我第一版写的就是那个 Bad 模式：
// ```rust
// // ffi.rs 的 dispatch_inner 里，每个命令各自取参
// let Some(id) = args.get("id").and_then(|x| x.as_str()) else {
//     return err_json("get_provider_enabled 缺少 id 参数", "other");
// };
// ```
// 90 个命令各写一遍 → 字段名拼错、错误文案不一致、
// 加个可选参数要改 N 处。所以单独抽成这个文件。
//
// # 它拥有什么
//
// ```text
// ① 从 unknown(serde_json::Value) 到 Rust 类型的归一化
// ② 缺参数/类型不对时的**统一**错误文案
// ③ 参数名的唯一真相（改字段名只改这里）
// ```
//
// # 它**不**拥有什么
//
// ```text
// ✗ 业务校验（如「id 必须存在于 registry」）→ 留给命令自己
// ✗ 序列化（那是 with_state 的事）
// ```
// 保持它只做「JSON → 类型」这一件事。

use serde_json::Value;

/// 命令参数的解码器
///
/// # 用法
///
/// ```text
/// let a = Args::new(&args);
/// let id = a.str("id")?;              // 必填字符串
/// let page = a.u32_or("page", 1);     // 可选 u32，默认 1
/// let silent = a.bool_or("silent", false);
/// ```
///
/// # 为什么返回 `Result<String, String>` 而不是 `Option`
///
/// 错误文案要**统一且可操作**：
/// ```text
/// ✓ "命令 get_provider_enabled 缺少参数 id（收到的参数: []）"
/// ✗ "缺少参数"              ← 不知道缺哪个
/// ✗ "invalid argument"      ← 不知道是哪个命令、哪个参数
/// ```
/// 调用方把命令名传进来，才能生成前者。
pub struct Args<'a> {
    /// 原始 JSON（保留下来用于生成「收到了什么」的诊断信息）
    raw: &'a Value,
    /// 当前命令名（用于错误文案）
    cmd: &'a str,
}

impl<'a> Args<'a> {
    /// 从 `{cmd, args}` 请求里取出某个命令的参数
    ///
    /// 取不到时用 `Value::Null` —— 这样「调用方没传 args」
    /// 与「传了空 args」走同一条路径，不会出现两个分支。
    pub fn new(req: &'a Value, cmd: &'a str) -> Self {
        Self {
            raw: req.get("args").unwrap_or(&Value::Null),
            cmd,
        }
    }

    /// ★ 按名字取原始值 —— **自动兼容 camelCase 与 snake_case**
    ///
    /// # 为什么必须兼容（这是 Tauri 的一个隐式契约）
    ///
    /// 原版前端这样调：
    /// ```ts
    /// // src/api/index.ts L496
    /// call<Page<MediaItem>>("get_list", { provider, categoryId, page })
    ///                                                       ^^^^^^^^^^
    /// ```
    /// 而对应的 Rust 命令签名是：
    /// ```text
    /// async fn get_list(..., category_id: String, page: u32)
    ///                    ^^^^^^^^^^^
    /// ```
    /// **参数名不一样，但能正常工作** —— 因为 Tauri v2 在
    /// invoke 边界上自动把 camelCase 转成 snake_case。
    ///
    /// 实测证据（原版前端 vs Rust 侧）：
    /// ```text
    /// 前端 categoryId  →  Rust category_id    （get_list）
    /// 前端 rankId      →  Rust rank_id        （get_rank）
    /// 前端 channelId   →  Rust channel_id     （直播相关）
    /// ```
    ///
    /// # 不兼容会怎样
    ///
    /// 我的 FFI 层没有 Tauri 那层自动转换。如果不处理，
    /// Dart 侧照搬原版前端代码传 `categoryId`，而 Rust 读 `category_id`
    /// → **永远取不到值** → 报「缺少参数 category_id」，
    /// 而调用方会一脸困惑："我明明传了 categoryId 啊"。
    ///
    /// 这类 bug 特别难查，因为两边的代码**看起来都是对的**。
    ///
    /// # 兼容方向
    ///
    /// 两种写法都接受：
    /// ```text
    /// snake_case  →  原生（Rust 侧的自然写法）
    /// camelCase   →  原版前端的历史写法，必须继续支持
    /// ```
    /// 优先 snake_case（若两者同时出现，以 Rust 的写法为准）。
    fn get(&self, name: &str) -> Option<&'a Value> {
        // 先按原名找
        if let Some(v) = self.raw.get(name) {
            if !v.is_null() {
                return Some(v);
            }
        }
        // 再按 camelCase 找（只在名字含下划线时有意义）
        if name.contains('_') {
            let camel = to_camel_case(name);
            if let Some(v) = self.raw.get(&camel) {
                if !v.is_null() {
                    return Some(v);
                }
            }
        }
        None
    }

    /// 必填字符串参数
    ///
    /// # ★ 为什么要把「没传」和「类型不对」分开报
    ///
    /// 第一版把两者都报成「缺少参数」，结果错误消息自相矛盾：
    /// ```text
    /// 命令 x 缺少参数 id（期望字符串；实际收到的参数: [id]）
    ///                                        ^^^^^^^^^^^^^^^
    ///                          说「缺少」，却把 id 列在"收到的参数"里
    /// ```
    /// 这条是**单元测试抓出来的**（`wrong_type_is_rejected`）。
    ///
    /// 对调用方来说这两种情况要采取的行动完全不同：
    /// ```text
    /// 没传      → 调用方漏了参数 → 改调用代码
    /// 类型不对  → 调用方传错了类型（如传数字当字符串）→ 改传参格式
    /// ```
    /// 混在一起报会让排查方向跑偏。
    pub fn str(&self, name: &str) -> Result<&'a str, String> {
        let Some(v) = self.get(name) else {
            return Err(self.missing(name, "字符串"));
        };
        v.as_str().ok_or_else(|| self.bad_type(name, "字符串", v))
    }

    /// 可选字符串参数
    pub fn str_or<'d>(&self, name: &str, default: &'d str) -> &'d str
    where
        'a: 'd,
    {
        self.get(name).and_then(|v| v.as_str()).unwrap_or(default)
    }

    /// 必填 u32 参数
    ///
    /// ⚠️ 数字类型要小心：JSON 的数字可能被解析成 u64 / i64 / f64。
    ///    `as_u64` 对 `1.0` 会失败（那是 f64），所以先试 u64 再试 f64。
    pub fn u32(&self, name: &str) -> Result<u32, String> {
        let v = self.get(name).ok_or_else(|| self.missing(name, "整数"))?;
        if let Some(n) = v.as_u64() {
            return u32::try_from(n).map_err(|_| self.bad_type(name, "整数", v));
        }
        // 容忍 1.0 这种写法（Dart 的 num 可能是 double）
        if let Some(f) = v.as_f64() {
            if f.fract() == 0.0 && f >= 0.0 && f <= u32::MAX as f64 {
                return Ok(f as u32);
            }
        }
        Err(self.bad_type(name, "整数", v))
    }

    /// 可选 u32 参数
    pub fn u32_or(&self, name: &str, default: u32) -> u32 {
        self.u32(name).unwrap_or(default)
    }

    /// 可选 u32 参数 —— **缺省时返回 None，而不是用默认值**
    ///
    /// # 与 `u32_or` 的区别（很重要）
    ///
    /// ```text
    /// u32_or("limit", 20)  → 缺省时返回 20
    /// u32_opt("limit")     → 缺省时返回 None
    /// ```
    /// 看起来后者更麻烦，但**语义不同**：
    ///
    /// 很多原版命令的签名是 `limit: Option<u32>`，然后在函数体里
    /// 决定默认值（如 `limit.unwrap_or(20)`）。如果我在 FFI 层就用
    /// `u32_or` 填上默认值，那么**默认值的归属就从命令层跑到了适配层** ——
    /// 一旦原版改了默认值（20 → 50），我这边不会跟着变，
    /// 而且这种不一致**不会报错**，只会静默返回不同数量的数据。
    ///
    /// 所以：**原版是 `Option<T>` 的，适配层就用 `*_opt`**，
    /// 把「默认值是多少」这个决定留给命令层。
    ///
    /// ⚠️ 类型错误（比如传了字符串）仍会返回 None ——
    ///    与 `u32_or` 一致。这样「参数写错」和「参数没传」
    ///    在这一层无法区分，但命令层本来也不区分（都走默认值）。
    pub fn u32_opt(&self, name: &str) -> Option<u32> {
        self.u32(name).ok()
    }

    /// u64 参数（播放位置 / 时长用 —— 它们可能超过 u32）
    ///
    /// # 为什么单独有 u64 而不是全用 u32
    ///
    /// ```text
    /// position / duration 单位是秒
    ///   u32 上限 4294967295 秒 ≈ 136 年 —— 看起来够用
    /// ```
    /// 但原版的 `Progress.position` / `duration` 字段**就是 u64**，
    /// 而 `save_progress` 的签名也是 `position: u64`。
    /// 适配层如果降成 u32，超长内容（比如 24 小时直播录播）会被截断，
    /// 而且是**静默溢出**（Rust 的 as 转换不 panic）。
    ///
    /// 所以：**原版是什么类型，适配层就用什么类型**。
    pub fn u64(&self, name: &str) -> Result<u64, String> {
        let v = self.get(name).ok_or_else(|| self.missing(name, "整数"))?;
        if let Some(n) = v.as_u64() {
            return Ok(n);
        }
        // 容忍 1.0 这种写法（Dart 的 num 可能是 double）
        if let Some(f) = v.as_f64() {
            if f.fract() == 0.0 && f >= 0.0 {
                return Ok(f as u64);
            }
        }
        Err(self.bad_type(name, "整数", v))
    }

    /// 可选 u64 参数（缺省时 None）
    pub fn u64_opt(&self, name: &str) -> Option<u64> {
        self.u64(name).ok()
    }

    /// 可选 u64 参数（缺省时用默认值）
    pub fn u64_or(&self, name: &str, default: u64) -> u64 {
        self.u64(name).unwrap_or(default)
    }

    /// i64 参数（**可以为负** —— Unix 时间戳 / 时区偏移用）
    ///
    /// # 为什么必须有 i64 而不是复用 u64
    ///
    /// 时间戳理论上可以是负数（1970 之前，或时区计算错误时）。
    /// 用 u64 接会把 `-1` 变成 `18446744073709551615` ——
    /// **静默**产生一个荒谬的请求（服务器要么报错，要么返回空）。
    ///
    /// 原版 `get_timeshift(start: i64, end: i64)` 就是 i64，照抄。
    pub fn i64(&self, name: &str) -> Result<i64, String> {
        let v = self.get(name).ok_or_else(|| self.missing(name, "整数"))?;
        if let Some(n) = v.as_i64() {
            return Ok(n);
        }
        // 容忍 1.0 这种写法（Dart 的 num 可能是 double）
        if let Some(f) = v.as_f64() {
            if f.fract() == 0.0 {
                return Ok(f as i64);
            }
        }
        Err(self.bad_type(name, "整数", v))
    }

    /// 可选 i64 参数（缺省时用默认值）
    pub fn i64_or(&self, name: &str, default: i64) -> i64 {
        self.i64(name).unwrap_or(default)
    }

    /// 可选 bool 参数
    pub fn bool_or(&self, name: &str, default: bool) -> bool {
        self.get(name).and_then(|v| v.as_bool()).unwrap_or(default)
    }

    /// 必填 bool 参数
    ///
    /// 同 [`str`](Self::str)：「没传」与「类型不对」分开报。
    pub fn bool(&self, name: &str) -> Result<bool, String> {
        let Some(v) = self.get(name) else {
            return Err(self.missing(name, "布尔值"));
        };
        v.as_bool().ok_or_else(|| self.bad_type(name, "布尔值", v))
    }

    /// 必填字符串数组
    ///
    /// 同 [`str`](Self::str)：「没传」「不是数组」「元素类型不对」
    /// 三种情况分开报，因为要采取的行动不同。
    pub fn str_list(&self, name: &str) -> Result<Vec<String>, String> {
        let Some(v) = self.get(name) else {
            return Err(self.missing(name, "字符串数组"));
        };
        let arr = v.as_array().ok_or_else(|| self.bad_type(name, "数组", v))?;
        let mut out = Vec::with_capacity(arr.len());
        for (i, item) in arr.iter().enumerate() {
            let s = item
                .as_str()
                .ok_or_else(|| format!("命令 `{}` 的参数 `{name}[{i}]` 不是字符串", self.cmd))?;
            out.push(s.to_string());
        }
        Ok(out)
    }

    // ── 错误文案 ──

    /// 「缺参数」的统一文案
    ///
    /// ★ 带上「实际收到了什么」—— 这是排查的关键。
    ///   经验：调用方报「我明明传了 id 啊」时，99% 是拼写不同
    ///   （`Id` / `ID` / `provider_id`）。列出收到的键名，
    ///   一眼就能看出来。
    fn missing(&self, name: &str, expect: &str) -> String {
        format!(
            "命令 `{}` 缺少参数 `{name}`（期望{expect}；实际收到的参数: {}）",
            self.cmd,
            self.received_keys()
        )
    }

    /// 「类型不对」的统一文案
    fn bad_type(&self, name: &str, expect: &str, got: &Value) -> String {
        format!(
            "命令 `{}` 的参数 `{name}` 类型不对（期望{expect}，实际收到 {}）",
            self.cmd,
            json_kind(got)
        )
    }

    /// 列出实际收到的参数名（诊断用）
    fn received_keys(&self) -> String {
        match self.raw {
            Value::Object(m) if !m.is_empty() => {
                let mut keys: Vec<&str> = m.keys().map(|s| s.as_str()).collect();
                keys.sort_unstable();
                format!("[{}]", keys.join(", "))
            }
            Value::Object(_) => "[]".to_string(),
            Value::Null => "（完全没传 args）".to_string(),
            other => format!("非对象: {}", json_kind(other)),
        }
    }
}

/// JSON 值的类型名（错误文案用）
fn json_kind(v: &Value) -> &'static str {
    match v {
        Value::Null => "null",
        Value::Bool(_) => "布尔值",
        Value::Number(_) => "数字",
        Value::String(_) => "字符串",
        Value::Array(_) => "数组",
        Value::Object(_) => "对象",
    }
}

/// `snake_case` → `camelCase`
///
/// # 为什么要这个
///
/// 见 [`Args::get`] 的说明 —— Tauri v2 在 invoke 边界上做这个转换，
/// 我们的 FFI 层必须自己补上，否则原版前端的调用代码照搬过来会失效。
///
/// # 规则
///
/// 只处理**下划线后跟字母**的情况，且**不处理首字母大写**：
/// ```text
/// category_id  → categoryId
/// rank_id      → rankId
/// channel_id   → channelId
/// page         → page        （无下划线，原样）
/// _private     → _private    （前导下划线不转，避免变成 Private）
/// ```
fn to_camel_case(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut upper_next = false;
    for (i, c) in s.chars().enumerate() {
        if c == '_' {
            // 前导下划线保留（如 `_private`），后面的下划线用来大写下一个字母
            if i == 0 {
                out.push('_');
                continue;
            }
            upper_next = true;
            continue;
        }
        if upper_next {
            out.extend(c.to_uppercase());
            upper_next = false;
        } else {
            out.push(c);
        }
    }
    out
}

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn req(args: Value) -> Value {
        json!({ "cmd": "test_cmd", "args": args })
    }

    #[test]
    fn reads_required_string() {
        let r = req(json!({ "id": "cycani" }));
        let a = Args::new(&r, "test_cmd");
        assert_eq!(a.str("id").unwrap(), "cycani");
    }

    /// ★ 缺参数的错误必须包含三样东西：命令名、参数名、实际收到的键
    ///
    /// 这条是**为了排查效率**而立的：只报「缺少参数」时，
    /// 调用方要来回翻代码找是哪个命令、哪个参数。
    #[test]
    fn missing_arg_error_is_diagnostic() {
        let r = req(json!({ "wrongName": 1 }));
        let a = Args::new(&r, "get_provider_enabled");
        let e = a.str("id").unwrap_err();

        assert!(e.contains("get_provider_enabled"), "应含命令名: {e}");
        assert!(e.contains("id"), "应含参数名: {e}");
        assert!(e.contains("wrongName"), "应列出实际收到的键（这才是排查关键）: {e}");
    }

    /// 完全没传 args 时也要给出可读的诊断
    #[test]
    fn missing_args_entirely() {
        let r = json!({ "cmd": "x" });
        let a = Args::new(&r, "x");
        let e = a.str("id").unwrap_err();
        assert!(e.contains("完全没传"), "应说明压根没传 args: {e}");
    }

    /// 类型不对时也要报错（而不是静默取默认值）
    #[test]
    fn wrong_type_is_rejected() {
        let r = req(json!({ "id": 123 }));
        let a = Args::new(&r, "x");
        let e = a.str("id").unwrap_err();
        assert!(e.contains("字符串"), "应说明期望的类型: {e}");
        assert!(e.contains("数字"), "应说明实际类型: {e}");
    }

    /// ★ 回归：「类型不对」不能说成「缺少参数」（自相矛盾的错误消息）
    ///
    /// # 这个 bug 是怎么被发现的
    ///
    /// 第一版的 `str()` 把「没传」和「类型不对」都归到 `missing()`，
    /// 于是传 `{"id": 123}` 报出来的是：
    /// ```text
    /// 命令 x 缺少参数 id（期望字符串；实际收到的参数: [id]）
    ///                                      ^^^^^^^^^^^^^^^
    ///                       说「缺少」，却把 id 列在"收到的参数"里
    /// ```
    /// 是 `wrong_type_is_rejected` 这条测试抓出来的。
    ///
    /// # 为什么要为「错误消息的措辞」单独写测试
    ///
    /// 错误消息是**调用方唯一的排查线索**。措辞自相矛盾时，
    /// 排查方向会被带偏（去看"为什么没传 id"，而实际是类型错了）。
    /// 这类缺陷不会让程序崩溃，所以只有专门的测试能拦住。
    #[test]
    fn wrong_type_must_not_be_reported_as_missing() {
        let cases = [
            (json!({ "id": 123 }), "id"),
            (json!({ "id": true }), "id"),
            (json!({ "id": ["a"] }), "id"),
        ];
        for (args, name) in cases {
            let r = req(args.clone());
            let a = Args::new(&r, "test_cmd");
            let e = a.str(name).unwrap_err();
            assert!(
                !e.contains("缺少"),
                "类型不对时不该说「缺少参数」（自相矛盾）。参数={args}，错误={e}"
            );
            assert!(
                e.contains("类型不对"),
                "应该说清是类型问题。参数={args}，错误={e}"
            );
        }
    }

    /// bool / 数组也要遵守「不把类型问题说成缺少」这条
    #[test]
    fn wrong_type_for_bool_and_list_also_clear() {
        let r = req(json!({ "b": "yes", "ids": "not-an-array" }));
        let a = Args::new(&r, "x");
        let eb = a.bool("b").unwrap_err();
        let el = a.str_list("ids").unwrap_err();
        assert!(!eb.contains("缺少"), "bool 类型错不该说缺少: {eb}");
        assert!(!el.contains("缺少"), "数组类型错不该说缺少: {el}");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  camelCase 兼容（Tauri 的隐式契约）
    // ═══════════════════════════════════════════════════════════════════

    /// 转换函数本身的规则
    #[test]
    fn camel_case_conversion_rules() {
        assert_eq!(to_camel_case("category_id"), "categoryId");
        assert_eq!(to_camel_case("rank_id"), "rankId");
        assert_eq!(to_camel_case("channel_id"), "channelId");
        assert_eq!(to_camel_case("provider"), "provider"); // 无下划线
        assert_eq!(to_camel_case("a_b_c"), "aBC");
        assert_eq!(to_camel_case("_private"), "_private"); // 前导下划线保留
        assert_eq!(to_camel_case("trailing_"), "trailing"); // 尾下划线丢弃
    }

    /// ★ 核心契约：原版前端传 camelCase，Rust 侧按 snake_case 读
    ///
    /// # 这个测试保护的是什么
    ///
    /// 原版前端（`src/api/index.ts`）这样调：
    /// ```ts
    /// call<Page<MediaItem>>("get_list", { provider, categoryId, page })
    /// ```
    /// 而 Rust 命令签名是 `category_id: String`。
    /// **两者名字不同却能工作** —— 全靠 Tauri 在 invoke 边界做转换。
    ///
    /// 我们的 FFI 层没有那一层，所以必须自己兼容。
    /// 不兼容的症状：Dart 侧照搬原版代码传 `categoryId`，
    /// Rust 读 `category_id` 取不到 → 报「缺少参数」，
    /// 而调用方坚称"我传了" —— **两边代码看起来都对**，极难排查。
    #[test]
    fn accepts_camel_case_from_frontend() {
        // 原版前端的真实调用形状
        let cases: &[(&str, Value)] = &[
            ("category_id", json!({ "categoryId": "TOP123" })),
            ("rank_id", json!({ "rankId": "rank-A" })),
            ("channel_id", json!({ "channelId": "cctv1" })),
        ];
        for (rust_name, args) in cases {
            let r = req(args.clone());
            let a = Args::new(&r, "test_cmd");
            let got = a
                .str(rust_name)
                .unwrap_or_else(|e| panic!("{rust_name} 应能从 {args} 取到，却报: {e}"));
            assert!(!got.is_empty());
        }
    }

    /// snake_case 仍然优先（两者同时出现时以 Rust 的写法为准）
    #[test]
    fn snake_case_takes_priority() {
        let r = req(json!({ "category_id": "snake", "categoryId": "camel" }));
        let a = Args::new(&r, "x");
        assert_eq!(a.str("category_id").unwrap(), "snake");
    }

    /// camelCase 在整数/bool/数组上也要生效
    #[test]
    fn camel_case_works_for_all_types() {
        let r = req(json!({ "pageNum": 3, "isSilent": true, "idList": ["a"] }));
        let a = Args::new(&r, "x");
        assert_eq!(a.u32("page_num").unwrap(), 3);
        assert!(a.bool("is_silent").unwrap());
        assert_eq!(a.str_list("id_list").unwrap(), vec!["a"]);
    }

    /// 值为 null 时应当作「没传」处理
    ///
    /// 为什么：Dart 侧 `{'id': null}` 是常见写法（可选参数直接传 null），
    /// 不处理的话会报「类型不对（期望字符串，实际收到 null）」，
    /// 而调用方的意图其实是"没传"。
    #[test]
    fn null_value_treated_as_missing() {
        let r = req(json!({ "id": null }));
        let a = Args::new(&r, "x");
        let e = a.str("id").unwrap_err();
        assert!(e.contains("缺少"), "null 应视作没传: {e}");
    }

    /// null 时 camelCase 回退也要生效
    #[test]
    fn null_snake_falls_back_to_camel() {
        let r = req(json!({ "category_id": null, "categoryId": "TOP1" }));
        let a = Args::new(&r, "x");
        assert_eq!(
            a.str("category_id").unwrap(),
            "TOP1",
            "snake_case 为 null 时应回退到 camelCase"
        );
    }

    /// ★ 整数要容忍 `1.0` 这种写法
    ///
    /// 为什么：Dart 侧 `num` 可能是 double，`jsonEncode(1.0)` 出来是 `1.0`，
    /// 而 `Value::as_u64()` 对它返回 None。不容忍的话
    /// Dart 传 `page: 1.0` 就会被拒 —— 一个很难查的跨语言类型坑。
    #[test]
    fn integer_tolerates_float_form() {
        for v in [json!(1), json!(1.0), json!(3)] {
            let r = req(json!({ "page": v }));
            let a = Args::new(&r, "x");
            assert_eq!(a.u32("page").unwrap(), if v == json!(3) { 3 } else { 1 });
        }
    }

    /// 真的小数要拒绝（1.5 不是整数）
    #[test]
    fn non_integral_number_rejected() {
        let r = req(json!({ "page": 1.5 }));
        let a = Args::new(&r, "x");
        assert!(a.u32("page").is_err(), "1.5 不该被当成整数");
    }

    /// 负数要拒绝
    #[test]
    fn negative_rejected() {
        let r = req(json!({ "page": -1 }));
        let a = Args::new(&r, "x");
        assert!(a.u32("page").is_err(), "负数不该被当成页码");
    }

    #[test]
    fn defaults_work() {
        let r = req(json!({}));
        let a = Args::new(&r, "x");
        assert_eq!(a.u32_or("page", 7), 7);
        assert!(!a.bool_or("silent", false));
        assert_eq!(a.str_or("q", "默认"), "默认");
    }

    #[test]
    fn string_list_works() {
        let r = req(json!({ "ids": ["a", "b"] }));
        let a = Args::new(&r, "x");
        assert_eq!(a.str_list("ids").unwrap(), vec!["a", "b"]);
    }

    /// 数组里混了非字符串 → 要指出是第几个（而不是笼统报错）
    #[test]
    fn string_list_points_at_bad_index() {
        let r = req(json!({ "ids": ["a", 42] }));
        let a = Args::new(&r, "x");
        let e = a.str_list("ids").unwrap_err();
        assert!(e.contains("ids[1]"), "应指出是哪个下标出错: {e}");
    }
}
