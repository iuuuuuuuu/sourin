//! 追更引擎 —— 定期检测收藏内容的更新
//!
//! # 工作方式
//!
//! ```text
//! 1. 取出所有 following=1 的收藏（按 last_checked_at 升序，优先查最久没查的）
//! 2. 逐条调用对应 Provider 的 detail() 取当前剧集数
//! 3. 与新集数比较：
//!    新增 = 当前集数 - 上次记录集数
//!    若有新增 → 累加 unread_count，更新 last_episode_count / last_episode_title
//! 4. 结果汇总返回，UI 显示"有 N 部更新"
//! ```
//!
//! # 关键工程约束
//!
//! - **错误隔离**：单个站点失败不能中断整轮巡检（yt-dlp 的 `except: continue` 做法）
//! - **限速**：站点访问要串行 + 间隔，避免被风控（实测央视连打 15 次无限流，
//!   但坚果云等有速率限制，故统一加间隔）
//! - **超时保护**：单个 provider 超时不影响其他

use crate::model::MediaId;
use crate::registry::Registry;
use crate::store::{Db, Favorite, UpdateInfo};
use std::sync::Arc;
use std::time::Duration;

/// 本模块统一用 `String` 作为错误类型（追更巡检不应因类型转换而复杂化）
type Res<T> = std::result::Result<T, String>;

/// 追更引擎
pub struct FollowEngine {
    registry: Arc<Registry>,
    db: Arc<Db>,
}

impl FollowEngine {
    pub fn new(registry: Arc<Registry>, db: Arc<Db>) -> Self {
        Self { registry, db }
    }

    /// 检查全部追更条目
    ///
    /// `max_items` 限制单轮检查数量（避免一次请求过多被风控）。
    pub async fn check_all(&self, max_items: usize) -> Res<Vec<UpdateInfo>> {
        let following = self.db.list_following()?;
        let mut updates = Vec::new();

        for fav in following.into_iter().take(max_items) {
            // 单个失败不中断整轮（错误隔离）
            match self.check_one(&fav).await {
                Ok(Some(info)) => updates.push(info),
                Ok(None) => {}
                Err(e) => {
                    log::warn!("追更检查失败 {}: {e}", fav.key);
                }
            }
            // 串行 + 间隔，避免触发站点风控
            tokio::time::sleep(Duration::from_millis(400)).await;
        }

        // 记录巡检时间
        let now = chrono::Utc::now().timestamp_millis();
        let _ = self.db.set_meta("last_follow_check", &now.to_string());

        Ok(updates)
    }

    /// 检查单个收藏
    ///
    /// 返回 `Some(UpdateInfo)` 表示有新集；`None` 表示无更新。
    pub async fn check_one(&self, fav: &Favorite) -> Res<Option<UpdateInfo>> {        let provider = self
            .registry
            .get(&fav.provider)
            .ok_or_else(|| format!("找不到 Provider: {}", fav.provider))?;

        // 站点已标记失效则跳过
        if !provider.manifest().working {
            return Err("该源已失效，跳过".into());
        }

        let id = MediaId::new(&fav.provider, &fav.native_id);

        // 超时保护
        let detail = tokio::time::timeout(Duration::from_secs(20), provider.detail(&id))
            .await
            .map_err(|_| "详情请求超时".to_string())?
            .map_err(|e| e.message.clone())?;

        let new_count = detail.episodes.len() as u32;
        let old_count = fav.last_episode_count;

        let now = chrono::Utc::now().timestamp_millis();
        let mut updated = fav.clone();
        updated.last_checked_at = now;

        // 首次检查：只记录基线，不算更新（避免刚收藏就报"更新 24 集"）
        if old_count == 0 {
            updated.last_episode_count = new_count;
            updated.last_episode_title = detail.episodes.last().map(|e| e.title.clone());
            updated.updated_at = now;
            self.db.upsert_favorite(&updated)?;
            return Ok(None);
        }

        if new_count > old_count {
            let added = new_count - old_count;
            let latest_title = detail.episodes.last().map(|e| e.title.clone());

            updated.last_episode_count = new_count;
            updated.last_episode_title = latest_title.clone();
            // 累加未读（而非覆盖）—— 用户可能一直没看
            updated.unread_count = fav.unread_count + added;
            /*
             * ★★ 记下「检测到更新的时间」—— 追更页**按它排序**
             *
             * Owner 的要求：
             * > 而且按照最近有更新的进行一个排序才对
             *
             * ⚠️ 不能用下面的 `last_checked_at` 代替：它每轮巡检都变，
             *    会让列表顺序自己乱跳（用户刚看到的"更新了"下次刷新就换位）。
             *    只有在**真的有新集**时才推进这个时间。
             */
            updated.last_update_at = now;
            updated.updated_at = now;
            self.db.upsert_favorite(&updated)?;

            return Ok(Some(UpdateInfo {
                key: fav.key.clone(),
                title: fav.title.clone(),
                cover: detail.cover.clone().or_else(|| fav.cover.clone()),
                provider: fav.provider.clone(),
                old_count,
                new_count,
                added,
                latest_title,
            }));
        }

        // 无更新，但更新检查时间（用于轮转）
        updated.updated_at = if fav.updated_at > 0 {
            fav.updated_at
        } else {
            now
        };
        self.db.upsert_favorite(&updated)?;
        Ok(None)
    }
}

// ─────────────────────────── 测试 ───────────────────────────

// ═══════════════════════════════════════════════════════════════════════
//  ★ 共享 helper：取某条目当前的最新集数
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么做成自由函数（而不是塞进某个命令里）
//
// 这段逻辑有**两个调用方**：
// ```text
// ① FollowEngine::check_one  —— 巡检时比对集数
// ② set_following 命令        —— 开启追更时记基准
// ```
// 按 code-reuse guide 的 Pattern 4（「同一段逻辑出现两次就该抽出来」），
// 必须只有一个 owner —— 否则两边的超时值、`.max(1)` 之类的细节
// 会各自漂移，而**漂移不会报错**，只会让「基准集数」和「巡检比对」
// 用了不同口径，表现为假的更新提示。
//
// # 与原版的一致性
//
// 原版 `lib.rs` 的 `current_episode_count` 与 `follow.rs` 的 `check_one`
// 也是各写了一份（同样的 20 秒超时、同样的 `.max(1)`）。
// 这里合并成一处，**行为不变** —— 只是去掉重复。
//
// # 两个必须保留的细节
//
// ```text
// · 20 秒超时 —— 用户在界面上点「追更」时会同步等这个调用，
//                站点卡住会让按钮一直转圈（原版注释明确）
// · episodes.len().max(1) —— 电影/单集没有剧集列表，
//                            当 1 集处理，否则会变成 0
//                            （0 会触发"首次检查"分支，逻辑就错了）
// ```
pub async fn current_episode_count(
    registry: &crate::registry::Registry,
    fav: &Favorite,
) -> Res<u32> {
    let provider = registry
        .get(&fav.provider)
        .ok_or_else(|| format!("找不到 Provider: {}", fav.provider))?;

    /*
     * ⚠️ `detail` 要的是 `MediaId`（provider + native），不是一个字符串。
     *    照抄 `check_one` 的构造方式，别自己拼。
     */
    let id = MediaId::new(&fav.provider, &fav.native_id);
    let detail = tokio::time::timeout(Duration::from_secs(20), provider.detail(&id))
        .await
        .map_err(|_| "取详情超时".to_string())?
        .map_err(|e| e.message.clone())?;

    // 有剧集列表就用它的长度；没有（电影/单集）就当 1
    Ok(detail.episodes.len().max(1) as u32)
}
#[cfg(test)]
mod tests {
    use super::*;
    // 注意：不要 glob 导入 crate::provider::*，它会带入 model::Result 别名，
    // 遮蔽标准库 Result，导致 `Result<T, E>` 两参数形式编译失败。
    use crate::model::{
        Capabilities, Episode, MediaDetail, MediaKind, PlayRequest, ProviderError,
        ProviderManifest, StreamCandidate,
    };
    use crate::provider::MediaProvider;
    use async_trait::async_trait;

    /// 可编程的假 Provider，用于测试追更逻辑
    struct FakeProvider {
        manifest: ProviderManifest,
        episode_count: std::sync::Mutex<usize>,
        fail: std::sync::Mutex<bool>,
    }

    impl FakeProvider {
        fn new(count: usize) -> Self {
            Self {
                manifest: ProviderManifest {
                    id: "fake".into(),
                    name: "测试源".into(),
                    version: "1".into(),
                    kind: "builtin".into(),
                    description: None,
                    icon: None,
                    id_prefixes: vec![],
                    capabilities: Capabilities::default(),
                    cover_headers: Vec::new(),
                    config: Vec::new(),
                    api_version: 1,
                    theme_color: None,
                    working: true,
                    broken_reason: None,
                    enabled: None,
                },
                episode_count: std::sync::Mutex::new(count),
                fail: std::sync::Mutex::new(false),
            }
        }
        fn set_count(&self, n: usize) {
            *self.episode_count.lock().unwrap() = n;
        }
        fn set_fail(&self, f: bool) {
            *self.fail.lock().unwrap() = f;
        }
    }

    #[async_trait]
    impl MediaProvider for FakeProvider {
        fn manifest(&self) -> &ProviderManifest {
            &self.manifest
        }

        async fn detail(&self, id: &MediaId) -> crate::model::Result<MediaDetail> {
            if *self.fail.lock().unwrap() {
                return Err(ProviderError::network("模拟失败"));
            }
            let n = *self.episode_count.lock().unwrap();
            Ok(MediaDetail {
                id: id.clone(),
                title: "测试剧".into(),
                cover: None,
                description: None,
                badges: vec![],
                kind: MediaKind::Series,
                meta: serde_json::Map::new(),
                sources: vec![],
                episodes: (1..=n)
                    .map(|i| Episode {
                        id: i.to_string(),
                        title: format!("第{i:02}集"),
                        order: i as u32,
                        player_id: None,
                    })
                    .collect(),
            })
        }

        async fn resolve(
            &self,
            _id: &MediaId,
            _r: &PlayRequest,
        ) -> crate::model::Result<Vec<StreamCandidate>> {
            Ok(vec![])
        }
    }

    fn setup(count: usize) -> (FollowEngine, Arc<FakeProvider>, Arc<Db>) {
        let registry = Arc::new(Registry::new());
        let fake = Arc::new(FakeProvider::new(count));
        registry.register(fake.clone() as Arc<dyn MediaProvider>);
        let db = Arc::new(Db::in_memory().unwrap());
        (FollowEngine::new(registry, db.clone()), fake, db)
    }

    fn fav() -> Favorite {
        Favorite {
            key: "fake:show1".into(),
            provider: "fake".into(),
            native_id: "show1".into(),
            title: "测试剧".into(),
            cover: None,
            group_name: None,
            kind: "series".into(),
            // 「既收藏又追更」——最常见的用户状态
            favorited: true,
            following: true,
            last_episode_count: 0,
            last_episode_title: None,
            unread_count: 0,
            last_checked_at: 0,
            last_update_at: 0,
            note: None,
            created_at: 1,
            updated_at: 1,
            deleted: false,
        }
    }

    #[tokio::test]
    async fn first_check_sets_baseline_without_alerting() {
        let (engine, _fake, db) = setup(10);
        db.upsert_favorite(&fav()).unwrap();

        // ★ 首次检查不应报"更新 10 集"，只建立基线
        let r = engine.check_one(&db.get_favorite("fake:show1").unwrap().unwrap()).await.unwrap();
        assert!(r.is_none(), "首次检查不应产生更新提示");

        let f = db.get_favorite("fake:show1").unwrap().unwrap();
        assert_eq!(f.last_episode_count, 10);
        assert_eq!(f.unread_count, 0);
    }

    #[tokio::test]
    async fn detects_new_episodes() {
        let (engine, fake, db) = setup(10);
        db.upsert_favorite(&fav()).unwrap();
        // 建立基线
        engine.check_one(&db.get_favorite("fake:show1").unwrap().unwrap()).await.unwrap();

        // 更新到 13 集
        fake.set_count(13);
        let r = engine
            .check_one(&db.get_favorite("fake:show1").unwrap().unwrap())
            .await
            .unwrap()
            .expect("应检测到更新");

        assert_eq!(r.added, 3);
        assert_eq!(r.old_count, 10);
        assert_eq!(r.new_count, 13);
        assert_eq!(r.latest_title.as_deref(), Some("第13集"));

        let f = db.get_favorite("fake:show1").unwrap().unwrap();
        assert_eq!(f.unread_count, 3);
    }

    #[tokio::test]
    async fn unread_accumulates_across_checks() {
        let (engine, fake, db) = setup(10);
        db.upsert_favorite(&fav()).unwrap();
        engine.check_one(&db.get_favorite("fake:show1").unwrap().unwrap()).await.unwrap();

        // 第一次更新 +2
        fake.set_count(12);
        engine.check_one(&db.get_favorite("fake:show1").unwrap().unwrap()).await.unwrap();
        assert_eq!(db.get_favorite("fake:show1").unwrap().unwrap().unread_count, 2);

        // 第二次更新 +1 → 累计 3（而不是被覆盖为 1）
        fake.set_count(13);
        engine.check_one(&db.get_favorite("fake:show1").unwrap().unwrap()).await.unwrap();
        assert_eq!(
            db.get_favorite("fake:show1").unwrap().unwrap().unread_count,
            3,
            "未读应累加而非覆盖"
        );
    }

    #[tokio::test]
    async fn no_update_returns_none() {
        let (engine, _fake, db) = setup(10);
        db.upsert_favorite(&fav()).unwrap();
        engine.check_one(&db.get_favorite("fake:show1").unwrap().unwrap()).await.unwrap();

        let r = engine.check_one(&db.get_favorite("fake:show1").unwrap().unwrap()).await.unwrap();
        assert!(r.is_none());
    }

    #[tokio::test]
    async fn check_all_isolates_failures() {
        let (engine, fake, db) = setup(10);
        // 两个收藏，一个会失败
        db.upsert_favorite(&fav()).unwrap();
        let mut f2 = fav();
        f2.key = "fake:show2".into();
        f2.native_id = "show2".into();
        db.upsert_favorite(&f2).unwrap();

        engine.check_all(10).await.unwrap();

        // 让 provider 失败
        fake.set_fail(true);
        fake.set_count(20);
        // ★ 不应 panic / 不应中断，只是没有更新结果
        let updates = engine.check_all(10).await.unwrap();
        assert!(updates.is_empty(), "provider 失败时不应产生更新，但也不应崩溃");
    }
}
