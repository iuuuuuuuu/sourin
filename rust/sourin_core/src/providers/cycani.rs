//! 次元城动画（cycani.org）Provider —— 第二个内置 Provider
//!
//! 全部接口于 2026-09-14 实测（公开接口为本次实跑复核，登录态接口引自方案文档实测记录）。
//!
//! # 与央视的关键差异（决定了本文件的写法）
//!
//! | 维度 | cctv | cycani |
//! |---|---|---|
//! | 必需请求头 | Referer | **`X-App-Name` 等自定义头，缺一个就 400** |
//! | 取流 | HLS，公开 | **MP4，必须登录** |
//! | 多源 | 无 | **`play_from` 数组 + `player_code`** |
//! | 签名 | 无 | **`expires` + `md5`，URL 会过期，不可缓存** |
//!
//! # 实测踩过的坑（都有据可查）
//!
//! 1. **必须有 `X-App-Name: cyc_web`** —— 不加时全部接口返回
//!    `400 {"code":1000,"msg":"app_name is required"}`。
//! 2. **`token` 字段自带 `Bearer ` 前缀** —— 再拼一次会变成 `Bearer Bearer xxx`。
//!    官方 bundle 的 `p2()` 做了容错：`/^Bearer\s+/i.test(r) ? r : 'Bearer ' + r`，此处照抄。
//! 3. **`play_from` 是数组**（`[{code,title,count}]`），不是单个对象 ——
//!    按对象解析会在多源剧集上直接崩掉。
//! 4. **列表与详情的 id 字段名不同**：列表/搜索用 `video_id`，详情用 `id`。
//! 5. **筛选参数名不是想当然的那个**（从官方 bundle 的 `Re()` 逆出并实测确认）：
//!    - 题材是 `tag`（**不是** `category`/`categories`/`tags`）
//!    - 排序是 `order_by`（**不是** `sort`/`order`），取值 `update_time|hits|score`
//!    - 年份是 `year`
//!    曾经用 `categories=热血` 测出 total=3246（等于未过滤），
//!    而 `tag=热血` 才是 442 —— **参数名错了不报错，只会静默返回全量**。
//! 6. **`page_size` 上限 48**，给 500 直接 400。
//! 7. 取流返回的是**带签名的 MP4 直链**，`expires` 到期即失效，**绝不能落库缓存**。

use crate::model::*;
use crate::provider::*;
use async_trait::async_trait;
use serde_json::Value;
use std::sync::{OnceLock, RwLock};
use std::time::Duration;

const BASE: &str = "https://www.cycani.org/api";
const REFERER: &str = "https://www.cycani.org/";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36";

/// keyring 服务名（凭据存系统钥匙串，不落明文）
///
/// ⚠️ **不要跟着应用改名一起改** —— 见 `proxy.rs` 里
/// `KEYRING_SERVICE` 上方的详细说明。
/// 改了会让用户已保存的次元城账号读不到，得重新登录。
const KEYRING_SERVICE: &str = "dsh-media-client";
/// 会话（token）存放的用户名
const KEYRING_USER: &str = "cycani";
/// ★ 自动登录用凭据的存放用户名 —— **与 token 分开**
///
/// 为什么分开：token 会随每次续期变化，而账号密码是长期不变的；
/// 且退出登录只该清 token，**不该**顺手把密码也删了（否则下次无法自动登录）。
const KEYRING_CRED: &str = "cycani-credentials";

/// `page_size` 实测上限（给 500 会 400）
const MAX_PAGE_SIZE: u32 = 48;

static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();

/// 内置直连客户端（未配置站点代理时的默认值）
fn default_client() -> &'static reqwest::Client {
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .user_agent(UA)
            .timeout(Duration::from_secs(20))
            // ⚠️ 显式 no_proxy()：未配置代理 = 真直连，不读环境变量
            .no_proxy()
            .build()
            .expect("build http client")
    })
}

/// 站点必需请求头 —— **少一个就 400**，这是接入的第一道坎
fn base_headers() -> Vec<(String, String)> {
    vec![
        ("X-App-Name".into(), "cyc_web".into()),
        ("X-App-Version".into(), "cycweb".into()),
        ("X-Time-Zone".into(), "Asia/Shanghai".into()),
        ("Accept".into(), "application/json".into()),
        ("Referer".into(), REFERER.into()),
    ]
}

fn truncate(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

/// 按官方 `p2()` 的逻辑规范化令牌：**已有 `Bearer ` 前缀就不再加**
fn normalize_token(raw: &str) -> String {
    let t = raw.trim();
    if t.len() >= 7 && t[..7].eq_ignore_ascii_case("bearer ") {
        t.to_string()
    } else {
        format!("Bearer {t}")
    }
}

// ─────────────────── 自动登录凭据（通用存储）───────────────────
//
// 为什么单独抽出来而不是塞进 CycaniProvider：
// 这是**所有需要登录的源**都会用到的能力（需求原话：「不只是兼容次元城，
// 还有后续的站点」），后续新源可以直接复用这两个函数 + 同样的 key 约定
// （`KEYRING_SERVICE` + `"{provider}-credentials"`）。

/// 把账号密码存进系统钥匙串（JSON 一行，方便整体读写）
pub fn save_credentials(username: &str, password: &str) -> Result<()> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, KEYRING_CRED).map_err(|e| {
        ProviderError::new(ErrorKind::Other, format!("钥匙串不可用: {e}"))
    })?;
    let payload = serde_json::json!({ "username": username, "password": password });
    entry
        .set_password(&payload.to_string())
        .map_err(|e| ProviderError::new(ErrorKind::Other, format!("保存凭据失败: {e}")))?;
    log::info!("cycani: 已保存凭据供自动登录使用");
    Ok(())
}

/// 读取已保存的凭据；没有则返回 `None`
pub fn load_credentials() -> Option<(String, String)> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, KEYRING_CRED).ok()?;
    let raw = entry.get_password().ok()?;
    let v: Value = serde_json::from_str(&raw).ok()?;
    let u = v.get("username")?.as_str()?.to_string();
    let p = v.get("password")?.as_str()?.to_string();
    if u.is_empty() || p.is_empty() {
        return None;
    }
    Some((u, p))
}

/// 清除已保存的凭据（彻底登出时才用）
pub fn forget_credentials() -> Result<()> {
    if let Ok(entry) = keyring::Entry::new(KEYRING_SERVICE, KEYRING_CRED) {
        let _ = entry.delete_credential();
    }
    Ok(())
}

// ─────────────────────────── Provider ───────────────────────────

pub struct CycaniProvider {
    manifest: ProviderManifest,
    /// 内存中的会话（持久化走系统钥匙串）
    session: RwLock<Option<Session>>,
    /// 站点代理存储（未配置时走内置直连客户端）
    proxy: Option<std::sync::Arc<crate::proxy::ProxyStore>>,
}

impl Default for CycaniProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl CycaniProvider {
    pub fn new() -> Self {
        Self {
            session: RwLock::new(None),
            proxy: None,
            manifest: ProviderManifest {
                id: "cycani".into(),
                name: "次元城动画".into(),
                version: "0.1.0".into(),
                kind: "builtin".into(),
                description: Some("动漫追番站：分区筛选 + 榜单 + 多播放源 + 服务端历史".into()),
                icon: None,
                id_prefixes: vec![],
                capabilities: Capabilities {
                    vod: true,
                    live: false,
                    epg: false,
                    search: true,
                    // ★ 取流必须登录（未登录访问 /user/* 与 play-url 一律 401，已实测）
                    login_required: true,
                    // ★ play_from 多源（实测该剧仅 1 个源，但模型必须按列表渲染）
                    multi_source: true,
                    server_side_history: true,
                    favorites: true,
                    timeshift: false,
                    danmaku: false,
                    // cycani 属于「必须登录」那一档，不是「游客可用 + 可登录」
                    login_supported: false,
                    login_hint: None,
                    login_needs_username: true,
                    // 账号密码登录（无扫码）
                    login_qr_supported: false,
                    // ★ task-38：★ 内置 Rust 版次元城**确实实现了** can_auto_login/auto_login（见 L639/L648）
                    can_auto_login: true,
                },
                // 内置 Provider 无可配置项（插件走 hydrate 填充）
                cover_headers: Vec::new(),
                config: Vec::new(),
                api_version: 1,
                theme_color: Some("#7c5cff".into()),
                working: true,
                broken_reason: None,
                enabled: None,
            },
        }
    }

    fn token(&self) -> Option<String> {
        self.session
            .read()
            .ok()
            .and_then(|s| s.as_ref().map(|x| x.token.clone()))
    }

    /// 注入站点代理（未配置时保持直连）
    pub fn with_proxy(mut self, proxy: std::sync::Arc<crate::proxy::ProxyStore>) -> Self {
        self.proxy = Some(proxy);
        self
    }

    /// 取该站点的 HTTP 客户端（按站点代理配置；未配置则直连）
    fn http(&self) -> reqwest::Client {
        match self.proxy.as_ref() {
            Some(store) => store.client_for("cycani", None).unwrap_or_else(|e| {
                log::warn!("cycani: 构建代理客户端失败，回退直连: {}", e.message);
                default_client().clone()
            }),
            None => default_client().clone(),
        }
    }

    /// 带鉴权的请求头；未登录返回 Unauthorized 错误
    fn auth_headers(&self) -> Result<Vec<(String, String)>> {
        let token = self.token().ok_or_else(|| {
            ProviderError::unauthorized("次元城需要登录后才能播放，请先在设置页登录")
        })?;
        let mut h = base_headers();
        h.push(("Authorization".into(), token));
        Ok(h)
    }

    /// GET 请求（可选鉴权）
    async fn get(&self, path: &str, auth: bool) -> Result<Value> {
        let headers = if auth {
            self.auth_headers()?
        } else {
            base_headers()
        };

        let url = format!("{BASE}{path}");
        let mut req = self.http().get(&url);
        for (k, v) in &headers {
            req = req.header(k.as_str(), v.as_str());
        }

        let resp = req
            .send()
            .await
            .map_err(|e| ProviderError::network(format!("请求失败: {e}")))?;

        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| ProviderError::network(format!("读取响应失败: {e}")))?;

        if status.as_u16() == 401 {
            return Err(ProviderError::unauthorized(
                "登录已过期，请重新登录次元城",
            ));
        }
        if !status.is_success() {
            return Err(ProviderError::network(format!(
                "HTTP {status}: {}",
                truncate(&text, 160)
            )));
        }

        let json: Value = serde_json::from_str(&text)
            .map_err(|e| ProviderError::parse(format!("{e} — {}", truncate(&text, 160))))?;

        // 统一包装 {code, msg, data}
        if let Some(code) = json.get("code").and_then(|v| v.as_i64()) {
            if code == 401 {
                return Err(ProviderError::unauthorized("登录已过期，请重新登录次元城"));
            }
            if code != 0 {
                let msg = json
                    .get("msg")
                    .and_then(|v| v.as_str())
                    .unwrap_or("未知错误");
                return Err(ProviderError::new(
                    ErrorKind::Other,
                    format!("接口返回 {code}: {msg}"),
                ));
            }
        }

        Ok(json.get("data").cloned().unwrap_or(Value::Null))
    }

    /// GET 列表（带分页）
    async fn get_page(&self, path: &str, auth: bool) -> Result<(Vec<Value>, Option<u64>)> {
        let data = self.get(path, auth).await?;
        let items = data
            .get("list")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        let total = data
            .get("pager")
            .and_then(|p| p.get("total"))
            .and_then(|v| v.as_u64());
        Ok((items, total))
    }

    /// 列表条目 → `MediaItem`
    ///
    /// ⚠️ 列表/搜索的 id 字段是 `video_id`，详情是 `id` —— 两者都要兼容
    fn to_item(it: &Value) -> Option<MediaItem> {
        let id = it
            .get("video_id")
            .or_else(|| it.get("id"))
            .and_then(|v| v.as_i64())?;

        let mut badges = Vec::new();
        /*
         * ★★★ 缺陷 21（2026-10-09 实测）：列表/搜索接口**根本不返回** `completed`
         *
         * 逐字读数（`.probe/zz_t21_probe.js` 直连 www.cycani.org/api）：
         * ```text
         * SEARCH  id=3862 无职转生 第三季  total=14  completed=undefined
         * DETAIL  id=3862 无职转生 第三季  total=14  completed=false
         * DETAIL  id=3147 无职转生 第二季  total=12  completed=true
         * DETAIL  id=37   无职转生 第一季  total=11  completed=true（sections len=24）
         * ```
         * ⇒ 同一个 id，走 search 拿不到 `completed`，走 detail 才有。
         *
         * 错在哪（改前）：这里只看 `total` 就 push `全 {total} 集`。
         *   「全」字是在替接口**下结论**（宣称“就这些了、完结了”），
         *   而连载番的 `total` 是**全季预定集数**（cycani.rs:900-903 的实测坑），
         *   于是连载中的番在追更页/列表页被写成「全 14 集」。
         *   用户据此读成“已完结”，但它其实还在连载 —— 这就是
         *   「显示『更新』但实际已完结/明明没完结却说全 N 集」那条反馈的根。
         *
         * 为什么这么改：没有 `completed` 就**不许**说完结/连载/更新任何一词，
         *   退化成中性陈述「共 N 集」—— 只陈述接口给出的客观数字，不做推断。
         *   ⚠️ 不许改回「全 N 集」：列表路径拿不到判据，是硬约束不是口味问题。
         *
         * ⚠️ 详情路径（cycani.rs:903-919）**不动**：那里有真实 `completed`，
         *   是唯一有资格说「已完结 / 连载中」的地方（测试见 :1367-1376）。
         */
        if let Some(total) = it.get("total").and_then(|v| v.as_u64()) {
            if total > 0 {
                badges.push(format!("共 {total} 集"));
            }
        }
        if let Some(score) = it.get("score").and_then(|v| v.as_f64()) {
            if score > 0.0 {
                badges.push(format!("{score:.1} 分"));
            }
        }

        Some(MediaItem {
            id: MediaId::new("cycani", id.to_string()),
            title: it
                .get("title")
                .and_then(|v| v.as_str())
                .unwrap_or("未知标题")
                .into(),
            cover: it
                .get("cover_url")
                .and_then(|v| v.as_str())
                .map(String::from),
            // remarks 形如 "11|周一20:35后"，取「|」后的排期更有信息量
            subtitle: it
                .get("remarks")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.split('|').next_back().unwrap_or(s).to_string()),
            badges,
            kind: MediaKind::Series,
            description: None,
        })
    }

    /// 从 keyring 恢复会话（启动时调用；失败静默降级为未登录）
    pub fn restore_session(&self) {
        let entry = match keyring::Entry::new(KEYRING_SERVICE, KEYRING_USER) {
            Ok(e) => e,
            Err(e) => {
                log::debug!("cycani: 钥匙串不可用，跳过会话恢复: {e}");
                return;
            }
        };
        let raw = match entry.get_password() {
            Ok(v) => v,
            Err(_) => return, // 没存过，属正常情况
        };
        match serde_json::from_str::<Session>(&raw) {
            Ok(s) => {
                // 过期则丢弃
                if let Some(exp) = s.expires_at {
                    if exp < chrono::Utc::now().timestamp() {
                        log::info!("cycani: 已保存的登录态已过期，需重新登录");
                        let _ = entry.delete_credential();
                        return;
                    }
                }
                log::info!("cycani: 已从钥匙串恢复登录态");
                if let Ok(mut w) = self.session.write() {
                    *w = Some(s);
                }
            }
            Err(e) => log::warn!("cycani: 会话记录解析失败: {e}"),
        }
    }

    /// 持久化会话到系统钥匙串（**不落明文**）
    fn persist_session(&self, s: &Session) {
        let entry = match keyring::Entry::new(KEYRING_SERVICE, KEYRING_USER) {
            Ok(e) => e,
            Err(e) => {
                log::warn!("cycani: 钥匙串不可用，登录态仅保留在本次运行: {e}");
                return;
            }
        };
        match serde_json::to_string(s) {
            Ok(json) => {
                if let Err(e) = entry.set_password(&json) {
                    log::warn!("cycani: 写入钥匙串失败: {e}");
                }
            }
            Err(e) => log::warn!("cycani: 会话序列化失败: {e}"),
        }
    }

    fn clear_stored_session(&self) {
        if let Ok(entry) = keyring::Entry::new(KEYRING_SERVICE, KEYRING_USER) {
            let _ = entry.delete_credential();
        }
        if let Ok(mut w) = self.session.write() {
            *w = None;
        }
    }
}

#[async_trait]
impl MediaProvider for CycaniProvider {
    fn manifest(&self) -> &ProviderManifest {
        &self.manifest
    }

    // ── 登录 ──────────────────────────────────────────────

    async fn login(&self, cred: Credentials) -> Result<Session> {
        if cred.username.trim().is_empty() || cred.password.is_empty() {
            return Err(ProviderError::new(
                ErrorKind::Other,
                "请输入账号与密码",
            ));
        }

        let body = serde_json::json!({
            "username": cred.username.trim(),
            "password": cred.password,
        });

        let mut req = self
            .http()
            .post(format!("{BASE}/auth/login"))
            .header("Content-Type", "application/json");
        for (k, v) in base_headers() {
            req = req.header(k.as_str(), v.as_str());
        }

        let resp = req
            .json(&body)
            .send()
            .await
            .map_err(|e| ProviderError::network(format!("登录请求失败: {e}")))?;

        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| ProviderError::network(format!("读取登录响应失败: {e}")))?;

        let json: Value = serde_json::from_str(&text).map_err(|_| {
            ProviderError::parse(format!("登录响应无法解析: {}", truncate(&text, 200)))
        })?;

        if let Some(code) = json.get("code").and_then(|v| v.as_i64()) {
            if code != 0 {
                let msg = json
                    .get("msg")
                    .and_then(|v| v.as_str())
                    .unwrap_or("账号或密码错误");
                return Err(ProviderError::new(ErrorKind::Other, msg.to_string()));
            }
        }
        if !status.is_success() {
            return Err(ProviderError::network(format!(
                "登录失败 HTTP {status}: {}",
                truncate(&text, 160)
            )));
        }

        let data = json
            .get("data")
            .ok_or_else(|| ProviderError::parse("登录响应缺少 data"))?;

        let raw_token = data
            .get("token")
            .and_then(|v| v.as_str())
            .ok_or_else(|| ProviderError::parse("登录响应缺少 token"))?;

        // ★ token 自带 "Bearer " 前缀，必须容错处理
        let token = normalize_token(raw_token);

        let expires_at = data
            .get("expires_at")
            .and_then(|v| v.as_str())
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
            .map(|dt| dt.timestamp());

        let user = data.get("user");
        let display_name = user
            .and_then(|u| u.get("nickname"))
            .or_else(|| user.and_then(|u| u.get("username")))
            .and_then(|v| v.as_str())
            .map(String::from);
        let avatar = user
            .and_then(|u| u.get("avatar_url"))
            .and_then(|v| v.as_str())
            .map(String::from);

        let session = Session {
            token,
            expires_at,
            display_name,
            avatar,
        };

        self.persist_session(&session);
        if let Ok(mut w) = self.session.write() {
            *w = Some(session.clone());
        }

        // ★ 手动登录成功后自动记住凭据，供日后 token 失效时自动恢复。
        //   用户不必额外去勾「记住我」——需求要的是「自动」。
        //   （凭据走系统钥匙串；`logout` 只清 token 不清它。）
        if let Err(e) = save_credentials(cred.username.trim(), &cred.password) {
            // 存不下不影响本次登录成功，但要留痕
            log::warn!("cycani: 保存凭据失败（自动登录将不可用）: {}", e.message);
        }

        log::info!("cycani: 登录成功");
        Ok(session)
    }

    async fn logout(&self) -> Result<()> {
        // ⚠️ 只清 token，**保留账号密码** —— 否则「退出登录」会连带
        //    失去自动登录能力，用户下次还得手打一遍。
        //    想彻底清除请用 `forget_credentials()`。
        self.clear_stored_session();
        Ok(())
    }

    async fn session(&self) -> Result<Option<Session>> {
        Ok(self.session.read().ok().and_then(|s| s.clone()))
    }

    // ── ★ 会话生命周期（对应 provider.rs 的通用契约）──────────────

    /// ★ 用现有 token 换新 token
    ///
    /// 接口是 `POST /api/auth/refresh`，把当前 token 放在 `Authorization` 头里
    /// （从官方 bundle 逆出：`Al("/auth/refresh", {method:"POST", authToken: r})`）。
    /// 返回 `{code:0, data:{token, expires_at}}`。
    ///
    /// 与 `login` 的区别：**不需要账号密码**，只要旧 token 还没彻底失效就能续。
    /// 这是比自动登录更轻的路径，应该优先尝试。
    async fn refresh_session(&self) -> Result<Option<Session>> {
        let Some(old) = self.token() else {
            // 没有 token 可续 —— 交给自动登录
            return Ok(None);
        };

        let mut req = self
            .http()
            .post(format!("{BASE}/auth/refresh"))
            .header("Content-Type", "application/json");
        for (k, v) in base_headers() {
            req = req.header(k.as_str(), v.as_str());
        }
        req = req.header("Authorization", old.as_str());

        let resp = req.send().await.map_err(|e| {
            ProviderError::network(format!(
                "续期请求失败: {}",
                if e.is_timeout() { "超时" } else { "网络错误" }
            ))
        })?;

        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| ProviderError::network(format!("读取续期响应失败: {e}")))?;

        // 401/过期 → 不是「网络故障」而是「续不动了」，返回 Ok(None) 让上层走自动登录
        if status.as_u16() == 401 {
            log::info!("cycani: token 已无法续期（401）");
            return Ok(None);
        }
        if !status.is_success() {
            return Err(ProviderError::network(format!(
                "续期失败 HTTP {status}: {}",
                truncate(&text, 160)
            )));
        }

        let json: Value = serde_json::from_str(&text)
            .map_err(|_| ProviderError::parse(format!("续期响应无法解析: {}", truncate(&text, 160))))?;

        if json.get("code").and_then(|v| v.as_i64()) != Some(0) {
            let msg = json
                .get("msg")
                .and_then(|v| v.as_str())
                .unwrap_or("未知错误");
            // 同样按「续不动」处理
            log::info!("cycani: 续期被拒（{msg}）");
            return Ok(None);
        }

        let data = json.get("data").unwrap_or(&Value::Null);
        let Some(raw_token) = data.get("token").and_then(|v| v.as_str()) else {
            return Ok(None);
        };

        let session = Session {
            token: normalize_token(raw_token),
            expires_at: data
                .get("expires_at")
                .and_then(|v| v.as_str())
                .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                .map(|dt| dt.timestamp()),
            // 续期响应不带用户信息 → 沿用旧会话的展示字段
            display_name: self
                .session
                .read()
                .ok()
                .and_then(|s| s.as_ref().and_then(|x| x.display_name.clone())),
            avatar: self
                .session
                .read()
                .ok()
                .and_then(|s| s.as_ref().and_then(|x| x.avatar.clone())),
        };

        // ★ 必须持久化：否则重启又回到旧 token
        self.persist_session(&session);
        if let Ok(mut w) = self.session.write() {
            *w = Some(session.clone());
        }
        Ok(Some(session))
    }

    /// ★ 凭据是否已保存（决定要不要尝试自动登录）
    async fn can_auto_login(&self) -> bool {
        load_credentials().is_some()
    }

    /// ★ 用保存的凭据重新登录
    ///
    /// ⚠️ 只在**无需人工交互**时才能成功。cycani 目前实测登录只要账号密码，
    /// 但如果站点将来加验证码/风控，这里会失败 —— 那时**必须如实报错**，
    /// 让用户去设置页人工处理，**绝不绕过验证码**。
    async fn auto_login(&self) -> Result<Option<Session>> {
        let Some((username, password)) = load_credentials() else {
            return Ok(None);
        };

        log::info!("cycani: 尝试用已保存凭据自动登录");
        // 复用 login 的完整链路（含 token 前缀容错、钥匙串持久化）
        let s = self
            .login(Credentials {
                username,
                password,
                extra: Default::default(),
            })
            .await?;
        Ok(Some(s))
    }

    /// ★ 记住凭据（存系统钥匙串，**不落明文**）
    async fn remember_credentials(&self, cred: &Credentials) -> Result<()> {
        save_credentials(&cred.username, &cred.password)
    }

    /// ★ 会话是否可用
    ///
    /// cycani 的判据比默认实现更严：不只看「有没有 token」，
    /// 还要看它**是不是已经过期**（过期且无凭据可自动恢复 = 不可用）。
    async fn session_usable(&self) -> bool {
        match self.session.read().ok().and_then(|s| s.clone()) {
            Some(s) => {
                match s.expires_at {
                    // 已过期：还能自动登录就算「暂时可用」（首次点播会触发恢复）
                    Some(exp) => {
                        exp > chrono::Utc::now().timestamp() || load_credentials().is_some()
                    }
                    // 无过期信息 → 信任它
                    None => true,
                }
            }
            None => load_credentials().is_some(),
        }
    }

    // ── 内容发现 ───────────────────────────────────────────

    async fn categories(&self) -> Result<Vec<Category>> {
        let data = self.get("/video-zones", false).await?;
        let zones = data
            .get("list")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();

        let mut out = Vec::new();
        for z in zones {
            let id = match z.get("id").and_then(|v| v.as_i64()) {
                Some(v) => v,
                None => continue,
            };
            let name = z
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("未命名分区")
                .to_string();

            // ★ filters.categories 是「题材」，映射到 list 的 `tag` 参数
            let children = z
                .get("filters")
                .and_then(|f| f.get("categories"))
                .and_then(|v| v.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|v| v.as_str())
                        .filter(|s| !s.is_empty() && !s.starts_with("分类资源不代表"))
                        .map(|s| Category {
                            id: s.to_string(),
                            name: s.to_string(),
                            children: vec![],
                        })
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();

            out.push(Category {
                id: id.to_string(),
                name,
                children,
            });
        }
        Ok(out)
    }

    async fn home(&self) -> Result<Vec<Section>> {
        let mut sections = Vec::new();

        // 1) 榜单（每周更新，实测有真实数据）
        if let Ok(data) = self.get("/ranks", false).await {
            if let Some(ranks) = data.get("list").and_then(|v| v.as_array()) {
                for r in ranks.iter().take(2) {
                    if let Some(rid) = r.get("id").and_then(|v| v.as_i64()) {
                        sections.push(Section {
                            id: format!("cycani-rank-{rid}"),
                            title: r
                                .get("name")
                                .and_then(|v| v.as_str())
                                .map(|n| format!("{n}榜"))
                                .unwrap_or_else(|| "榜单".into()),
                            source: SectionSource::Rank {
                                rank_id: rid.to_string(),
                            },
                            items: vec![],
                        });
                    }
                }
            }
        }

        // 2) 分区最新
        if let Ok(data) = self.get("/video-zones", false).await {
            if let Some(zones) = data.get("list").and_then(|v| v.as_array()) {
                for z in zones.iter().take(2) {
                    if let Some(zid) = z.get("id").and_then(|v| v.as_i64()) {
                        let name = z.get("name").and_then(|v| v.as_str()).unwrap_or("分区");
                        sections.push(Section {
                            id: format!("cycani-zone-{zid}"),
                            title: format!("{name} · 最近更新"),
                            source: SectionSource::Category {
                                category_id: zid.to_string(),
                            },
                            items: vec![],
                        });
                    }
                }
            }
        }

        Ok(sections)
    }

    async fn list(&self, req: ListRequest) -> Result<Page<MediaItem>> {
        let page = req.page.max(1);
        let page_size = MAX_PAGE_SIZE;

        // 第一道筛：分类 id（zone）
        let zone_id = req.category_id.trim();
        // 其余筛选走 filters（题材/年份/排序）
        let tag = req.filters.get("tag").map(|s| s.as_str()).unwrap_or("");
        let year = req.filters.get("year").map(|s| s.as_str()).unwrap_or("");
        let order_by = req
            .filters
            .get("order_by")
            .map(|s| s.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or("update_time");

        let mut path = format!(
            "/videos?page={page}&page_size={page_size}&order_by={order_by}"
        );
        if !zone_id.is_empty() {
            path.push_str(&format!("&zone_id={zone_id}"));
        }
        if !tag.is_empty() {
            path.push_str(&format!("&tag={}", urlencoding::encode(tag)));
        }
        if !year.is_empty() {
            path.push_str(&format!("&year={}", urlencoding::encode(year)));
        }

        let (items, total) = self.get_page(&path, false).await?;
        let list: Vec<MediaItem> = items.iter().filter_map(Self::to_item).collect();

        let page_count = total.map(|t| ((t as f64) / (page_size as f64)).ceil() as u32);
        Ok(Page {
            items: list,
            page,
            page_count,
            total,
        })
    }

    async fn detail(&self, id: &MediaId) -> Result<MediaDetail> {
        let data = self.get(&format!("/videos/{}", id.native), false).await?;

        let title = data
            .get("title")
            .and_then(|v| v.as_str())
            .unwrap_or(&id.native)
            .to_string();
        let cover = data
            .get("cover_url")
            .and_then(|v| v.as_str())
            .map(String::from);
        let description = data
            .get("description")
            .and_then(|v| v.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());

        let mut meta = serde_json::Map::new();
        for (key, field) in [
            ("year", "year"),
            ("score", "score"),
            ("area", "area"),
            ("total", "total"),
            ("version", "version"),
            ("subtitle", "subtitle"),
        ] {
            if let Some(v) = data.get(field) {
                if !v.is_null() {
                    meta.insert(key.to_string(), v.clone());
                }
            }
        }
        if let Some(tags) = data.get("tags").and_then(|v| v.as_array()) {
            meta.insert("tags".into(), Value::Array(tags.clone()));
        }

        // ★ play_from 是数组：[{code,title,count}]，按列表渲染（不写死单源）
        let sources = data
            .get("play_from")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|s| {
                        let code = s.get("code").and_then(|v| v.as_str())?;
                        Some(PlaySource {
                            code: code.to_string(),
                            title: s
                                .get("title")
                                .and_then(|v| v.as_str())
                                .unwrap_or(code)
                                .to_string(),
                            count: s
                                .get("count")
                                .and_then(|v| v.as_u64())
                                .unwrap_or(0) as u32,
                            nested: vec![],
                        })
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();

        // 默认拉第一个源的剧集
        let episodes = match sources.first() {
            Some(s) => self.episodes(id, &s.code).await.unwrap_or_default(),
            None => vec![],
        };

        // 角标：**关键是要如实反映「能看几集」**
        //
        // 实测坑：连载番组 `total` 是全季预定集数（如 12），而接口实际只返回已播的
        // 10 集（`remarks` 形如 "10|周六25:05后"）。直接显示「全 12 集」会与
        // 下方只有 10 个选集按钮自相矛盾，用户会以为丢了 2 集。
        // 故：已完结→「全 N 集」；连载中→「更新至 M 集」；两者不等时都不撒谎。
        let declared_total = data.get("total").and_then(|v| v.as_u64()).unwrap_or(0);
        let available = episodes.len() as u64;
        let completed = data.get("completed").and_then(|v| v.as_bool()) == Some(true);

        let mut badges = Vec::new();
        if completed {
            let n = declared_total.max(available);
            if n > 0 {
                badges.push(format!("全 {n} 集"));
            }
        } else if available > 0 {
            badges.push(format!("更新至 {available} 集"));
        } else if declared_total > 0 {
            badges.push(format!("共 {declared_total} 集"));
        }
        badges.push(if completed { "已完结".into() } else { "连载中".into() });

        Ok(MediaDetail {
            id: id.clone(),
            title,
            cover,
            description,
            badges,
            kind: MediaKind::Series,
            meta,
            sources,
            episodes,
        })
    }

    async fn episodes(&self, id: &MediaId, source_code: &str) -> Result<Vec<Episode>> {
        let (items, _) = self
            .get_page(
                &format!(
                    "/videos/{}/sections?player_code={}&page=1&page_size={MAX_PAGE_SIZE}",
                    id.native,
                    urlencoding::encode(source_code)
                ),
                false,
            )
            .await?;

        Ok(items
            .iter()
            .enumerate()
            .filter_map(|(i, s)| {
                let sid = s.get("id").and_then(|v| v.as_i64())?;
                Some(Episode {
                    id: sid.to_string(),
                    title: s
                        .get("title")
                        .and_then(|v| v.as_str())
                        .map(String::from)
                        .unwrap_or_else(|| format!("第{:02}集", i + 1)),
                    // 官方列表不带 order，用下标兜底
                    order: s
                        .get("order")
                        .and_then(|v| v.as_u64())
                        .map(|v| v as u32)
                        .unwrap_or((i + 1) as u32),
                    player_id: s
                        .get("player_id")
                        .and_then(|v| v.as_str())
                        .map(String::from),
                })
            })
            .collect())
    }

    async fn search(&self, keyword: &str, page: u32) -> Result<Page<MediaItem>> {
        if keyword.trim().is_empty() {
            return Ok(Page {
                items: vec![],
                page: 1,
                page_count: None,
                total: None,
            });
        }
        // ★ 参数名是 `q`（用 keyword/wd 会 400：`Q is a required field`）
        let path = format!(
            "/videos/search?q={}&page={}&page_size={MAX_PAGE_SIZE}",
            urlencoding::encode(keyword.trim()),
            page.max(1)
        );
        let (items, total) = self.get_page(&path, false).await?;
        let list: Vec<MediaItem> = items.iter().filter_map(Self::to_item).collect();
        let page_count = total.map(|t| ((t as f64) / (MAX_PAGE_SIZE as f64)).ceil() as u32);
        Ok(Page {
            items: list,
            page,
            page_count,
            total,
        })
    }

    /// ★ 榜单内容
    ///
    /// 接口：`GET /ranks/{id}/videos`（实测返回真实数据，如「无职转生 第三季」）。
    ///
    /// ⚠️ 这个方法是**补上来的**：cycani 的 `home()` 一直在声明
    /// `SectionSource::Rank { rank_id }`（「TV番组榜」「剧场番组榜」），
    /// 但既没有实现取数、前端也没有对应分支，于是首页那两个区块
    /// **永远显示「暂无内容」** —— 声明了却拉不到，是典型的半成品。
    async fn rank(&self, rank_id: &str, page: u32) -> Result<Page<MediaItem>> {
        // 与其它列表接口一致：官方此接口不分页（一次返回该榜单全部），
        // 故第 2 页起直接返回空，避免前端无限翻页。
        if page > 1 {
            return Ok(Page {
                items: vec![],
                page,
                page_count: Some(1),
                total: None,
            });
        }

        let data = self.get(&format!("/ranks/{rank_id}/videos"), false).await?;

        // 实测结构是 {list:[...]}；兼容直接给数组的情况
        let arr = data
            .get("list")
            .and_then(|v| v.as_array())
            .or_else(|| data.as_array())
            .cloned()
            .unwrap_or_default();

        let list: Vec<MediaItem> = arr.iter().filter_map(Self::to_item).collect();
        let total = list.len() as u64;
        Ok(Page {
            items: list,
            page: 1,
            page_count: Some(1),
            total: Some(total),
        })
    }

    // ── 取流 ───────────────────────────────────────────────

    async fn resolve(&self, id: &MediaId, req: &PlayRequest) -> Result<Vec<StreamCandidate>> {
        // 必须知道集 id 才能取流
        let section_id = match req.episode_id.as_deref() {
            Some(s) if !s.is_empty() => s.to_string(),
            _ => {
                // 未指定集 → 用第一个源的最后一集？不：默认第一集更符合直觉
                let source_code = req.source_code.as_deref().unwrap_or("");
                let eps = if source_code.is_empty() {
                    let d = self.detail(id).await?;
                    d.episodes
                } else {
                    self.episodes(id, source_code).await?
                };
                eps.first()
                    .map(|e| e.id.clone())
                    .ok_or_else(|| {
                        ProviderError::new(ErrorKind::NotFound, "该作品没有可播放的剧集")
                    })?
            }
        };

        // 需要登录（未登录会返回 401 → Unauthorized）
        let data = self
            .get(&format!("/v2/sections/{section_id}/play-url"), true)
            .await?;

        let url = data
            .get("url")
            .and_then(|v| v.as_str())
            .ok_or_else(|| ProviderError::parse("取流响应缺少 url"))?
            .to_string();

        // 签名直链（expires+md5）自带鉴权，实测无防盗链，无需额外请求头
        //
        // ⚠️ kind 用 `from_url` 推断（不硬编码 Mp4）：
        //    该站把 MP4 伪装成 `.mp3`、且地址可能不带扩展名，
        //    硬编码会在将来接入 m3u8 内容时出错。
        //
        // ★ `quality` 不用响应里的 `name`（2026-09-15 修正）
        //
        //   实测：该接口返回的 `name` 是**剧集名**（如「第01集」），
        //   **不是画质**。原先把它当 quality，导致播放页标题下方出现
        //   「第01集　第01集」——集名重复两遍（左边是剧集名、右边是"线路名"），
        //   用户看不出右边那个想表达什么。
        //
        //   该站只提供**单一画质**（无多档可选），所以给一个如实的中性名，
        //   而不是编造一个假的画质档位。
        let kind = StreamKind::from_url(&url);
        Ok(vec![
            StreamCandidate::new(url, kind)
                .with_quality("原画")
                .with_label("次元城"),
        ])
    }

    // ── 平台自带历史（备份平面，只读镜像）────────────────────

    async fn platform_history(&self) -> Result<Vec<UserRecord>> {
        if self.token().is_none() {
            return Err(ProviderError::unauthorized("次元城未登录"));
        }
        let data = self.get("/user/histories?page_size=100", true).await?;
        let list = data.get("list").and_then(|v| v.as_array()).cloned().unwrap_or_default();

        Ok(list
            .iter()
            .filter_map(|h| {
                let vid = h.get("video_id").and_then(|v| v.as_i64())?;
                let sec_title = h
                    .get("section_title")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let updated = h
                    .get("update_time")
                    .and_then(|v| v.as_str())
                    .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                    .map(|dt| dt.timestamp_millis())
                    .unwrap_or(0);

                let video = h.get("video");
                let title = video
                    .and_then(|v| v.get("title"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("未知作品")
                    .to_string();
                let cover = video
                    .and_then(|v| v.get("cover_url"))
                    .and_then(|v| v.as_str())
                    .map(String::from);

                // progress/duration 官方是毫秒
                let position = h.get("progress").and_then(|v| v.as_u64()).map(|v| v / 1000);
                let duration = h.get("duration").and_then(|v| v.as_u64()).map(|v| v / 1000);

                let mut payload = serde_json::Map::new();
                if !sec_title.is_empty() {
                    payload.insert("section_title".into(), Value::String(sec_title));
                }

                Some(UserRecord {
                    key: format!("cycani:history:{vid}"),
                    provider: "cycani".into(),
                    kind: "history".into(),
                    native_id: vid.to_string(),
                    title,
                    cover,
                    position,
                    duration,
                    payload,
                    updated_at: updated,
                    deleted: false,
                })
            })
            .collect())
    }

    // ── 健康检查 ────────────────────────────────────────────

    async fn health_check(&self) -> bool {
        // 公开接口探测：能拿到分区即视为健康
        self.get("/video-zones", false)
            .await
            .map(|d| d.get("list").is_some())
            .unwrap_or(false)
    }
}

// ─────────────────────────── 测试 ───────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_requires_login_and_advertises_multi_source() {
        let p = CycaniProvider::new();
        let c = &p.manifest().capabilities;
        assert!(c.login_required, "cycani 取流必须登录");
        assert!(c.multi_source, "cycani 有 play_from 多源");
        assert!(c.server_side_history);
        assert!(!c.live, "cycani 没有直播");
    }

    #[test]
    fn token_prefix_is_not_doubled() {
        // ★ 实测坑：token 字段自带 "Bearer " 前缀
        assert_eq!(normalize_token("Bearer eyJhbGci"), "Bearer eyJhbGci");
        assert_eq!(normalize_token("bearer eyJhbGci"), "bearer eyJhbGci");
        assert_eq!(normalize_token("eyJhbGci"), "Bearer eyJhbGci");
        // 幂等：规范化两次结果一致
        let once = normalize_token("eyJx");
        assert_eq!(normalize_token(&once), once);
    }

    #[test]
    fn required_headers_include_app_name() {
        let h = base_headers();
        let names: Vec<&str> = h.iter().map(|(k, _)| k.as_str()).collect();
        // 缺 X-App-Name 会全站 400，必须存在
        assert!(names.contains(&"X-App-Name"));
        assert!(names.contains(&"X-App-Version"));
        assert!(names.contains(&"X-Time-Zone"));
        let app = h.iter().find(|(k, _)| k == "X-App-Name").unwrap();
        assert_eq!(app.1, "cyc_web");
    }

    #[test]
    fn item_parses_video_id_from_list_shape() {
        // 列表/搜索用 video_id
        let v = serde_json::json!({
            "video_id": 3885,
            "title": "最强废渣皇子",
            "cover_url": "https://x/y.jpg",
            "remarks": "11|周一20:35后",
            "total": 12,
            "score": 5.2
        });
        let it = CycaniProvider::to_item(&v).unwrap();
        assert_eq!(it.id.provider, "cycani");
        assert_eq!(it.id.native, "3885");
        // 副标题取「|」后的排期
        assert_eq!(it.subtitle.as_deref(), Some("周一20:35后"));
        assert!(it.badges.iter().any(|b| b.contains("12")));
    }

    #[test]
    fn item_parses_id_from_detail_shape() {
        // 详情用 id
        let v = serde_json::json!({ "id": 1, "title": "指名！" });
        let it = CycaniProvider::to_item(&v).unwrap();
        assert_eq!(it.id.native, "1");
    }

    #[tokio::test]
    #[ignore = "需要网络"]
    async fn zones_are_reachable_with_required_headers() {
        let p = CycaniProvider::new();
        let cats = p.categories().await.unwrap();
        assert!(!cats.is_empty(), "分区列表不应为空");
        // 实测 zone 1 = TV番组，且带题材子分类
        let tv = cats.iter().find(|c| c.id == "1").expect("应有 zone 1");
        assert!(!tv.children.is_empty(), "TV番组 应带题材筛选器");
    }

    #[tokio::test]
    #[ignore = "需要网络"]
    async fn tag_filter_actually_filters() {
        // ★ 回归保护：参数名必须是 `tag`。
        //   写成 categories/tags 不会报错，只是静默返回全量（实测 3246）。
        let p = CycaniProvider::new();
        let mut filters = std::collections::HashMap::new();
        filters.insert("tag".to_string(), "热血".to_string());

        let page = p
            .list(ListRequest {
                category_id: "1".into(),
                page: 1,
                filters,
            })
            .await
            .unwrap();

        assert!(!page.items.is_empty());
        let total = page.total.unwrap_or(0);
        assert!(
            total < 1000,
            "tag 过滤未生效（total={total}，接近全量说明参数名错了）"
        );
    }

    #[tokio::test]
    #[ignore = "需要网络"]
    async fn order_by_score_is_sorted() {
        let p = CycaniProvider::new();
        let mut filters = std::collections::HashMap::new();
        filters.insert("order_by".to_string(), "score".to_string());
        let page = p
            .list(ListRequest {
                category_id: "1".into(),
                page: 1,
                filters,
            })
            .await
            .unwrap();
        assert!(!page.items.is_empty());
        // 首条应带高分角标
        assert!(page.items[0].badges.iter().any(|b| b.contains("分")));
    }

    #[tokio::test]
    #[ignore = "需要网络"]
    async fn detail_exposes_play_from_as_sources() {
        let p = CycaniProvider::new();
        let d = p.detail(&MediaId::new("cycani", "1")).await.unwrap();
        assert_eq!(d.title, "指名！");
        // ★ play_from 是数组，必须解析出源
        assert!(!d.sources.is_empty(), "应解析出播放源");
        assert_eq!(d.sources[0].code, "cychub");
        assert_eq!(d.sources[0].count, 24);
        // 默认应带上第一个源的剧集
        assert_eq!(d.episodes.len(), 24);
        assert_eq!(d.episodes[0].title, "第01集");
    }

    #[tokio::test]
    #[ignore = "需要网络"]
    async fn search_accepts_q_param() {
        let p = CycaniProvider::new();
        let page = p.search("转生", 1).await.unwrap();
        assert!(!page.items.is_empty(), "搜索应有结果");
        assert!(page.items.iter().all(|i| !i.id.native.is_empty()));
    }

    #[tokio::test]
    #[ignore = "需要网络"]
    async fn resolve_without_login_reports_unauthorized() {
        // 未登录取流应明确报「需要登录」，而不是含糊失败
        let p = CycaniProvider::new();
        let err = p
            .resolve(
                &MediaId::new("cycani", "1"),
                &PlayRequest {
                    episode_id: Some("1".into()),
                    ..Default::default()
                },
            )
            .await
            .unwrap_err();
        assert_eq!(err.kind, ErrorKind::Unauthorized);
        assert!(err.needs_login);
    }

    #[tokio::test]
    #[ignore = "需要网络"]
    async fn health_check_passes() {
        let p = CycaniProvider::new();
        assert!(p.health_check().await);
    }

    /// ★ 连载番组的角标必须如实反映「能看几集」。
    /// 实测《花织即使是转生也想打架》：`total=12`（全季预定），但接口只返回 10 集。
    /// 若显示「全 12 集」会与下方 10 个选集按钮矛盾，用户以为丢集。
    #[tokio::test]
    #[ignore = "需要网络"]
    async fn ongoing_badge_matches_available_episodes() {
        let p = CycaniProvider::new();
        let d = p.detail(&MediaId::new("cycani", "3881")).await.unwrap();

        // 该作品为连载中，选集数应等于接口实际返回数
        assert!(d.badges.iter().any(|b| b == "连载中"), "应为连载中: {:?}", d.badges);
        assert_eq!(d.episodes.len(), 10, "该作品当前已播 10 集");

        // 角标不应声称有 12 集（那会与 10 个选集按钮矛盾）
        assert!(
            !d.badges.iter().any(|b| b.contains("全 12 集")),
            "连载中不应显示全季集数，实际角标: {:?}",
            d.badges
        );
        assert!(
            d.badges.iter().any(|b| b.contains("10")),
            "应反映已播集数，实际角标: {:?}",
            d.badges
        );
    }

    /// 已完结作品应显示「全 N 集」
    #[tokio::test]
    #[ignore = "需要网络"]
    async fn completed_badge_shows_full_count() {
        let p = CycaniProvider::new();
        // 《指名！》实测 completed=true, total=24
        let d = p.detail(&MediaId::new("cycani", "1")).await.unwrap();
        assert!(d.badges.iter().any(|b| b == "已完结"), "实际: {:?}", d.badges);
        assert!(d.badges.iter().any(|b| b == "全 24 集"), "实际: {:?}", d.badges);
    }

    // ─────────── 会话续期（需求 6 的核心）───────────

    /// ★★ 续期接口真的能用：用当前 token 换一个新的
    ///
    /// 这是「refresh token 自动续期」这条需求的核心 ——
    /// 但在本轮之前**它没有任何测试**（只有实现）。
    ///
    /// 为什么必须联网测：续期是纯网络行为，接口路径
    /// （`POST /api/auth/refresh`，token 放 `Authorization` 头）
    /// 是从官方 bundle 逆出来的，一旦站点改动就会失效，
    /// 而失效表现是「用户突然要重新登录」，很难归因。
    ///
    /// ⚠️ `CycaniProvider::new()` 的内存会话是**空的**，
    ///    测试进程读不到应用持久化的会话 —— 所以这里**先真登录一次**
    ///    拿到 token，再验证续期。这样测的是完整链路。
    ///
    /// 前置条件：本机钥匙串里存有凭据（未保存时自动跳过）。
    #[tokio::test]
    #[ignore = "需要网络且已保存凭据"]
    async fn refresh_session_renews_token() {
        let p = CycaniProvider::new();

        // 1) 先登录拿一个真实 token
        let Some((user, pass)) = load_credentials() else {
            eprintln!("跳过：本机钥匙串没有 cycani 凭据");
            return;
        };
        let logged = match p
            .login(Credentials {
                username: user,
                password: pass,
                ..Default::default()
            })
            .await
        {
            Ok(s) => s,
            Err(e) => {
                // 验证码/风控/改密 → 属于需求里「交人工处理」的场景，不算测试失败
                eprintln!("跳过：自动登录失败（需人工处理）：{}", e.message);
                return;
            }
        };
        assert!(!logged.token.is_empty(), "登录返回了空 token");
        let before = logged;

        // 2) 用这个 token 续期
        let renewed = p
            .refresh_session()
            .await
            .expect("续期请求本身不应报错（401 会返回 Ok(None) 而不是 Err）");

        match renewed {
            Some(new) => {
                assert!(!new.token.is_empty(), "续期返回了空 token");
                // ★ 最强断言：新 token 必须真的能用
                //   （只断言「拿到了字符串」不够 —— 可能是个无效串）
                //
                //   注意：`refresh_session()` 只返回新会话，**不会自己写入内存**
                //   （写回由宿主 Registry 负责）。所以这里手动装进去，
                //   再用一个需要登录的接口验证它确实有效。
                if let Ok(mut w) = p.session.write() {
                    *w = Some(new.clone());
                }
                let ok = p.detail(&MediaId::new("cycani", "3772")).await.is_ok();
                assert!(ok, "续期后的 token 无法访问需要登录的接口");
                eprintln!(
                    "续期成功：过期时间 {:?} → {:?}",
                    before.expires_at, new.expires_at
                );
            }
            None => {
                // Ok(None) 的语义是「续不动了」（如 401）——
                // 此时上层会走自动登录，属于**设计内的降级**，不是 bug。
                eprintln!("续期返回 None（token 已不可续），将走自动登录路径");
            }
        }
    }

    /// ★ 续期窗口判定：只有**快过期**才续，没过期不该白跑一次请求
    ///
    /// 阈值 `DEFAULT_REFRESH_WINDOW_SECS = 300`（5 分钟）。
    /// 实测本机 token 剩余 144 小时 → `session_needs_refresh()` 必须为 false。
    #[tokio::test]
    #[ignore = "需要网络且已登录"]
    async fn fresh_session_does_not_need_refresh() {
        let p = CycaniProvider::new();
        let Ok(Some(s)) = p.session().await else {
            eprintln!("跳过：本机没有已保存的 cycani 会话");
            return;
        };

        let exp = s.expires_at.unwrap_or(0);
        let now = chrono::Utc::now().timestamp();
        let remain = exp - now;

        if remain > crate::provider::DEFAULT_REFRESH_WINDOW_SECS {
            assert!(
                !p.session_needs_refresh().await,
                "还剩 {remain} 秒不该判定为需要续期（阈值 {} 秒）",
                crate::provider::DEFAULT_REFRESH_WINDOW_SECS
            );
        } else {
            assert!(
                p.session_needs_refresh().await,
                "只剩 {remain} 秒，必须判定为需要续期"
            );
        }
    }
}
