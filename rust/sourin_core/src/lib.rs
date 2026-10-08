// ═══════════════════════════════════════════════════════════════════════
//  源影核心 —— lib 入口（脱离 Tauri 的验证）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这一步在验证什么
//
// 「复用 81% 代码」这条硬指标，成败取决于一件事：
// **这些模块能不能脱离 Tauri 编译？**
//
// 如果能 → Flutter 只写 UI，业务层原样复用
// 如果不能 → 要么大改业务层，要么放弃复用
//
// # 为什么先只声明模块、不写逻辑
//
// 这一步只要**编译通过**就证明了：
// ```text
// ① 模块之间没有循环依赖
// ② 没有隐藏的 Tauri 类型渗透到公开签名里
// ③ 依赖清单是完整且自洽的
// ```
// 逻辑封装（FFI 函数）是下一步的事 —— 那要等 UI 端确定需要哪些接口。

#![allow(dead_code)]
#![allow(unused_imports)]
#![allow(clippy::too_many_arguments)]

// ── 数据模型 ──
pub mod model;

/// 重新导出 —— sync/mod.rs 里写的是 crate::PersistedProvider，
/// 抽核心时它从 lib.rs 搬到了 model.rs，这里保持旧路径可用。
pub use model::PersistedProvider;

// ── 内容源 ──
pub mod provider;
pub mod registry;
pub mod providers;

// ── 存储 ──
pub mod store;

// ── 网络 ──
pub mod proxy;
pub mod streamproxy;

// ── 功能 ──
pub mod follow;
pub mod backup;
pub mod sync;

// ── 插件引擎 ──
pub mod plugins;

// ── 局域网遥控 ──
pub mod remote;

// ── 应用状态与启动 ──
//
// 从 Tauri 的 lib.rs 搬过来：AppState 定义 + bootstrap 流程 +
// 数据目录迁移。这是「搬 90 个命令」的前置条件。
pub mod state;

// ── 清单持久化 ──
pub mod persist;

// ── 参数解码（契约的唯一所有者）──
//
// 起因见 .trellis/spec/guides/cross-layer-thinking-guide.md 的 Mistake 4：
// 每个命令各自解析 JSON 字段 = 每个消费者一份私有契约。
pub mod args;

// ── 详情与播放链路 ──
pub mod playback;

// ── 首页链路 ──
pub mod home;

// ── 命令实现 ──
//
// 从 Tauri lib.rs 搬来的业务逻辑。签名从 	auri::State<'_, AppState>改为 &AppState，函数体不动。
pub mod commands;
pub mod commands_write;
pub mod commands_provider;
pub mod commands_backup;
pub mod commands_remote;

// ── TVBox 配置导入（task-5）──
//
// 把 TVBox 配置里的苹果CMS 站点就地转成原生 Provider。
// 为什么不生成 JS 插件：见 tvbox.rs 顶部说明。
pub mod tvbox;

// ── ★ FFI 层（给 Flutter 用）──
//
// Flutter 与核心之间唯一的接口。设计说明（为什么是一个 JSON 入口、
// 内存怎么管、线程模型）见 ffi.rs 顶部。
pub mod ffi;

/// 最早的探针入口 —— 返回 `*const u8`
///
/// ⚠️ 新代码请用 `ffi::sourin_core_version()`（返回 `*const c_char`）。
///    这个保留是因为第一轮验证 FFI 链路时用过它，
///    删掉会让当时的验证记录对不上。功能上两者等价。
#[no_mangle]
pub extern "C" fn sourin_core_version_u8() -> *const u8 {
    // 静态字符串，生命周期是整个进程，返回裸指针是安全的
    static V: &[u8] = b"sourin-core 0.1.0\0";
    V.as_ptr()
}
