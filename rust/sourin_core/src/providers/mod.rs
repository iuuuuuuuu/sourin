//! 内置 Provider 集合
//!
//! 央视网 Provider —— 见 `providers/cctv.rs`
pub mod cctv;
/// 次元城动画 Provider（cycani.org）—— 见 `providers/cycani.rs`
pub mod cycani;
/// 声明式 Provider（用户写 JSON 接入标准站）
pub mod declarative;
/// HTTP Provider（进程外插件契约）—— 见 `providers/http.rs`
pub mod http;

pub use cctv::CctvProvider;
pub use cycani::CycaniProvider;
pub use declarative::DeclarativeProvider;
pub use http::HttpProvider;
