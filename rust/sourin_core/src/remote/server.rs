//! 遥控 HTTP 服务（axum）
//!
//! 路由很少，全部在局域网内使用：
//!
//! | 方法 | 路径 | 用途 |
//! |---|---|---|
//! | GET | `/` | 遥控页面（内置单文件 HTML） |
//! | GET | `/api/state` | 播放器当前状态（手机轮询） |
//! | POST | `/api/cmd` | 下发命令（**需配对码**） |
//! | POST | `/api/search` | 搜索（**需配对码**，转发给前端执行） |
//! | GET | `/api/search` | 取搜索结果 |
//! | GET | `/api/home` | 取首页分区（手机端「发现」页） |
//! | POST | `/api/pin` | 校验配对码（手机端首次进入时） |
//!
//! # 为什么状态用「前端上报 + 手机轮询」而不是服务端推送
//!
//! 播放器状态在 Vue 里，Rust 拿不到。前端每 800ms 上报一次，
//! 手机每 800ms 拉一次 —— 遥控场景下这个延迟完全够用，
//! 而且**没有长连接**（断线/重连/僵尸连接这些麻烦都不存在）。

use axum::{
    extract::State,
    http::StatusCode,
    response::{Html, IntoResponse, Json},
    routing::{get, post},
    Router,
};
use serde::Deserialize;
use std::sync::Arc;

use super::{HomePayload, RemoteCommand, RemoteHub, RemoteState, SearchPayload};

/// 遥控页面（编译进二进制，不依赖外部文件）
const PAGE: &str = include_str!("page.html");

/// 启动 HTTP 服务
///
/// 返回实际监听的端口。**调用方负责把 `hub.set_running(true)`**——
/// 这里只管起服务，不改进程外的可观测状态。
///
/// # ★★ 优雅关闭（这是"关掉后能再开"的关键）
///
/// 以前这里直接 `axum::serve(listener, app).await`，
/// **没有停止途径** —— 于是 `remote_stop` 只能翻个标志位，
/// 监听套接字一直绑着，用户「关闭 → 再开启」必然撞
/// `os error 10048`（地址被自己占用），只能重启应用。
///
/// 现在用 `axum::serve(...).with_graceful_shutdown(...)` 订阅
/// `hub` 的关闭信号，收到后 axum 会**停止接受新连接并 drop listener**，
/// 端口随即释放。
///
/// ⚠️ `with_graceful_shutdown` 会等**已建立的连接**结束才返回。
///    手机端如果保持着长连接（遥控页面会轮询），可能拖一会儿。
///    所以调用方（`request_shutdown`）是**轮询端口是否可绑**，
///    而不是死等这个 future —— 只要 listener 释放了就算成功。
pub async fn serve(hub: Arc<RemoteHub>, port: u16) -> Result<(), String> {
    let shutdown_rx = hub.resubscribe_shutdown();
    let app = build_router(hub);

    let addr = super::bind_addr(port);
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .map_err(|e| format!("无法监听 {addr}：{e}"))?;

    log::info!("遥控服务已启动: http://{addr}/");

    axum::serve(listener, app)
        .with_graceful_shutdown(wait_for_shutdown(shutdown_rx))
        .await
        .map_err(|e| format!("遥控服务异常退出: {e}"))?;

    log::info!("遥控服务已停止，端口 {port} 已释放");
    Ok(())
}

/// 等 `hub` 发出关闭信号
///
/// `watch::Receiver::changed()` 在**值变化**时返回。
/// 已启动的服务拿到的是 `resubscribe_shutdown()` 给的新接收端
/// （信号被复位为 `false`），所以第一次 `changed()` 就是真正的关闭请求。
///
/// ⚠️ 若 sender 被 drop（理论上进程退出时），`changed()` 返回 `Err`，
///    这里也当作"该退出了"处理 —— 不能让服务变成收不到信号的孤儿。
async fn wait_for_shutdown(mut rx: tokio::sync::watch::Receiver<bool>) {
    loop {
        if *rx.borrow() {
            return;
        }
        if rx.changed().await.is_err() {
            return;
        }
    }
}

/// 组装路由（抽出来是为了能在测试里直接打请求）
fn build_router(hub: Arc<RemoteHub>) -> Router {
    // 中间件要单独持一份 Arc（它不能与 `with_state` 共用同一个所有权）
    let guard_hub = hub.clone();

    Router::new()
        .route("/", get(page))
        .route("/api/state", get(get_state))
        .route("/api/cmd", post(post_cmd))
        .route("/api/search", get(get_search).post(post_search))
        .route("/api/home", get(get_home).post(post_home))
        .route("/api/pin", post(check_pin))
        /*
         * ★★ 必须先过「是否已关闭」这道闸
         *
         * 实测踩到的**安全问题**：用户点「关闭遥控」后，
         * 监听套接字并没有释放（axum 的 serve 没有停止句柄，
         * 这是刻意的取舍，见 lib.rs 的说明），而路由**完全不检查**
         * `is_running` —— 于是「关掉」之后端口照样能访问，
         * 任何拿到配对码的人仍能控制播放。
         *
         * 用户以为关了、实际还开着，这比不能关更糟。
         *
         * `from_fn_with_state` 会在所有路由**之前**执行，
         * 关掉后一律 503。
         */
        .layer(axum::middleware::from_fn_with_state(
            guard_hub,
            require_running,
        ))
        .with_state(hub)
}

/// 中间件：遥控已关闭时拒绝一切请求
async fn require_running(
    State(hub): State<Arc<RemoteHub>>,
    req: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    use axum::response::IntoResponse;

    if !hub.is_running() {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "遥控已关闭（请在客户端重新开启）",
        )
            .into_response();
    }
    next.run(req).await
}

async fn page() -> impl IntoResponse {
    Html(PAGE)
}

async fn get_state(State(hub): State<Arc<RemoteHub>>) -> Json<RemoteState> {
    Json(hub.state())
}

#[derive(Deserialize)]
struct CmdBody {
    pin: String,
    #[serde(flatten)]
    command: RemoteCommand,
}

/// 下发命令 —— **必须带正确配对码**
async fn post_cmd(
    State(hub): State<Arc<RemoteHub>>,
    Json(body): Json<CmdBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !hub.check_pin(&body.pin) {
        // 不区分「码错」与「没带码」—— 少给爆破者一点信息
        return Err((StatusCode::UNAUTHORIZED, "配对码不正确".into()));
    }
    hub.push_command(body.command);
    Ok(Json(serde_json::json!({ "ok": true })))
}

#[derive(Deserialize)]
struct PinBody {
    pin: String,
}

/// 校验配对码（手机端首次进入时调，成功后就把它存本地）
async fn check_pin(
    State(hub): State<Arc<RemoteHub>>,
    Json(body): Json<PinBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if hub.check_pin(&body.pin) {
        Ok(Json(serde_json::json!({ "ok": true })))
    } else {
        Err((StatusCode::UNAUTHORIZED, "配对码不正确".into()))
    }
}

async fn get_search(State(hub): State<Arc<RemoteHub>>) -> Json<Option<SearchPayload>> {
    Json(hub.search())
}

#[derive(Deserialize)]
struct SearchBody {
    pin: String,
    keyword: String,
}

/// 搜索：把关键词交给前端执行（前端有完整的搜索能力），
/// 手机端稍后再 `GET /api/search` 取结果。
async fn post_search(
    State(hub): State<Arc<RemoteHub>>,
    Json(body): Json<SearchBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !hub.check_pin(&body.pin) {
        return Err((StatusCode::UNAUTHORIZED, "配对码不正确".into()));
    }
    // 清掉上一次结果，避免手机端把旧结果当新的
    hub.set_search(SearchPayload {
        keyword: body.keyword.clone(),
        items: Vec::new(),
    });
    // 走命令通道交给前端执行（它才有 Provider 与缓存）
    hub.push_command(RemoteCommand::QuerySearch {
        keyword: body.keyword,
    });
    Ok(Json(serde_json::json!({ "ok": true })))
}

async fn get_home(State(hub): State<Arc<RemoteHub>>) -> Json<Option<HomePayload>> {
    Json(hub.home())
}

#[derive(Deserialize)]
struct HomeBody {
    pin: String,
}

/// 请求前端刷新首页（手机端「发现」页进入时调）
async fn post_home(
    State(hub): State<Arc<RemoteHub>>,
    Json(body): Json<HomeBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !hub.check_pin(&body.pin) {
        return Err((StatusCode::UNAUTHORIZED, "配对码不正确".into()));
    }
    hub.push_command(RemoteCommand::QueryHome);
    Ok(Json(serde_json::json!({ "ok": true })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::Request;
    use tower::ServiceExt;

    /// 打一个请求，返回状态码
    async fn hit(app: Router, path: &str) -> StatusCode {
        let res = app
            .oneshot(
                Request::builder()
                    .uri(path)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        res.status()
    }

    /// ★★ 「关闭遥控」后**必须真的访问不了**（实测踩到的安全问题）
    ///
    /// 背景：axum 的 `serve` 没有停止句柄，关闭时只是把状态置为未运行，
    /// **监听套接字仍在**（端口要等进程退出才释放，这是刻意的取舍）。
    ///
    /// 而路由原先**完全不检查** `is_running` —— 于是用户点了「关闭遥控」，
    /// 端口照样能访问，任何拿到配对码的人仍能控制播放。
    /// 用户以为关了、实际还开着，**这比不能关更糟**。
    ///
    /// 这条测试锁死：关闭后所有端点一律 503。
    #[tokio::test]
    async fn stopped_hub_rejects_everything() {
        let hub = Arc::new(RemoteHub::new());
        let app = build_router(hub.clone());

        // 1) 开启状态：首页正常（200）
        hub.set_running(true);
        assert_eq!(
            hit(app.clone(), "/").await,
            StatusCode::OK,
            "开启时首页应可访问"
        );

        // 2) 关闭后：**所有**端点都必须拒绝
        hub.set_running(false);
        for path in ["/", "/api/state", "/api/search", "/api/home"] {
            assert_eq!(
                hit(app.clone(), path).await,
                StatusCode::SERVICE_UNAVAILABLE,
                "关闭遥控后 {path} 必须拒绝访问（否则「关了还开着」）"
            );
        }
    }
}
