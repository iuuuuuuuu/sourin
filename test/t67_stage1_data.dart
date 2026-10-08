// ═══════════════════════════════════════════════════════════════════════
//  task-67 阶段 1 —— **用户真实行**（自动生成，请勿手改）
// ═══════════════════════════════════════════════════════════════════════
//
// 来源：`.probe/dbcopy-t67b/dsh-media.db`
//   = 用 SQLite **backup API** 从**正在运行的**用户库做的一致性快照
//     （源库以 `mode=ro` 只读打开，绝不写用户数据）
//
// ★★ 为什么必须重做快照（这是一个**方法论**教训）
// ```text
// Lead 给的 `.probe/dbcopy-t67/` **只有 dsh-media.db，没有 -wal / -shm**
//   实测：主库 mtime = 10:13:08（此后未再写）
//         -wal  = 4,132,392 B，mtime = 13:21:20（**仍在增长**）
//   ⇒ 10:13 之后的所有写入**全在 WAL 里**，那份副本读不到
//   实测差异：progress/history 里 `cycani:3862` 的 position
//             快照 = 1168（真值）  陈旧副本 = 643
// ```
// ⚠️ 行数**相同**（16 行）却**内容不同** ⇒ ★「行数一致」不能证明「快照一致」。
//
// 生成脚本：`.probe/t67h_gen_data.py`
// ═══════════════════════════════════════════════════════════════════════

/// 追更列表 —— `favorites WHERE deleted=0 AND following=1`（`store.rs:764`）
const List<Map<String, dynamic>> t67RealFollowing = [
  {
    "key": "cycani:3862",
    "provider": "cycani",
    "native_id": "3862",
    "title": "无职转生 第三季 ～到了异世界就拿出真本事～",
    "cover": "https://gimg1.baidu.com/gimg/app=2001&src=img2.cycimg.me/pic/cover/l/1f/9e/501963_bXlEP.jpg",
    "group_name": null,
    "kind": "series",
    "favorited": false,
    "following": true,
    "last_episode_count": 13,
    "last_episode_title": null,
    "unread_count": 0,
    "last_checked_at": 1790485426252,
    "last_update_at": 0,
    "note": null,
    "created_at": 1789553774970,
    "updated_at": 1790381577455,
    "deleted": false
  }
];

/// 收藏列表 —— `favorites WHERE favorited=1`（`store.rs:730`）
const List<Map<String, dynamic>> t67RealFavorites = [
  {
    "key": "caiji:74774",
    "provider": "caiji",
    "native_id": "74774",
    "title": "老舅",
    "cover": "https://img.dytt-tupian.com/upload/vod/20251215-1/fc0817219f8ea0b8a81b4c77e1bf19c2.jpg",
    "group_name": null,
    "kind": "movie",
    "favorited": true,
    "following": false,
    "last_episode_count": 0,
    "last_episode_title": null,
    "unread_count": 0,
    "last_checked_at": 0,
    "last_update_at": 0,
    "note": null,
    "created_at": 1790483528104,
    "updated_at": 1790483528104,
    "deleted": false
  }
];

/// 播放历史 —— ★ 注意：这是 **progress 表**，不是 history 表！
/// `continueWatching` = `WHERE finished=0 AND position > 5`（`store.rs:945`）
/// 首页「我的」用 `limit: 12`（`my_shelf.dart:425`）
const List<Map<String, dynamic>> t67RealHistory = [
  {
    "key": "cycani:3862",
    "provider": "cycani",
    "native_id": "3862",
    "title": "无职转生 第三季 ～到了异世界就拿出真本事～",
    "cover": "https://gimg1.baidu.com/gimg/app=2001&src=img2.cycimg.me/pic/cover/l/1f/9e/501963_bXlEP.jpg",
    "episode_id": "51463",
    "episode_title": "第01集",
    "position": 1168,
    "duration": 1420,
    "finished": false,
    "updated_at": 1790486650760
  },
  {
    "key": "cycani:3841",
    "provider": "cycani",
    "native_id": "3841",
    "title": "",
    "cover": null,
    "episode_id": null,
    "episode_title": null,
    "position": 122,
    "duration": 1422,
    "finished": false,
    "updated_at": 1790430571527
  },
  {
    "key": "cycani:3611",
    "provider": "cycani",
    "native_id": "3611",
    "title": "剧场版 鬼灭之刃 无限城篇 第一章 猗窝座再袭",
    "cover": "https://gimg1.baidu.com/gimg/app=2001&src=img2.cycimg.me/pic/cover/l/f6/0b/501958_VZs4W.jpg",
    "episode_id": "48884",
    "episode_title": "正片",
    "position": 2971,
    "duration": 9285,
    "finished": false,
    "updated_at": 1790331352097
  },
  {
    "key": "bilibili:bilibili:av:BV1B8ZJYTEPg",
    "provider": "bilibili",
    "native_id": "bilibili:av:BV1B8ZJYTEPg",
    "title": "现代修仙，没钱纯靠自律【自律狠人】【第一季超长电影版】",
    "cover": "https://i2.hdslb.com/bfs/archive/bd88ddaef2e676a386be293c12de0b9becab9f82.jpg",
    "episode_id": "BV1B8ZJYTEPg|29165686089",
    "episode_title": "现代修仙，没钱纯靠自律【自律狠人】【第一季超长电影版】",
    "position": 15,
    "duration": 2958,
    "finished": false,
    "updated_at": 1790143040293
  },
  {
    "key": "bilibili:av:BV1YDhJ6ZEL6",
    "provider": "bilibili",
    "native_id": "av:BV1YDhJ6ZEL6",
    "title": "《柯洁围棋入门课》",
    "cover": "https://i2.hdslb.com/bfs/archive/35baeae957483b53d75c1dd12eecb7e6d2f498c4.jpg",
    "episode_id": "BV1YDhJ6ZEL6|42108063716",
    "episode_title": "《柯洁围棋入门课》",
    "position": 28,
    "duration": 498,
    "finished": false,
    "updated_at": 1790138648425
  },
  {
    "key": "154:59466",
    "provider": "154",
    "native_id": "59466",
    "title": "揭秘日",
    "cover": "https://vcover-vt-pic.puui.qpic.cn/vcover_vt_pic/0/mzc00200gexv9lm1766049185742/0",
    "episode_id": "https://v.qq.com/x/cover/mzc00200gexv9lm/h41028xc0lf.html",
    "episode_title": "原声版",
    "position": 3663,
    "duration": 8582,
    "finished": false,
    "updated_at": 1790134300460
  },
  {
    "key": "cycani:3885",
    "provider": "cycani",
    "native_id": "3885",
    "title": "最强废渣皇子暗中活跃于帝位之争",
    "cover": "https://gimg1.baidu.com/gimg/app=2001&src=img2.cycimg.me/pic/cover/l/a7/a6/456081_Bs2nE.jpg",
    "episode_id": "51558",
    "episode_title": "第01集",
    "position": 148,
    "duration": 1420,
    "finished": false,
    "updated_at": 1790011629676
  },
  {
    "key": "bilibili:av:BV1SveU6GExV",
    "provider": "bilibili",
    "native_id": "av:BV1SveU6GExV",
    "title": "【微电影】星河外卖员：平台战争",
    "cover": "https://i2.hdslb.com/bfs/archive/aec1a2db1f328dcb45c58eae13809b2da108b1a6.jpg",
    "episode_id": null,
    "episode_title": null,
    "position": 36,
    "duration": 1206,
    "finished": false,
    "updated_at": 1789869728775
  },
  {
    "key": "bilibili:av:BV1Bfex6tEEH",
    "provider": "bilibili",
    "native_id": "av:BV1Bfex6tEEH",
    "title": "探厂红旗｜走进千万硬核声学实验室！详解全新红旗H7车载音响！",
    "cover": "https://i0.hdslb.com/bfs/archive/0c7ceb91e27337a5760be089e2586ff5f03d3405.jpg",
    "episode_id": null,
    "episode_title": null,
    "position": 12,
    "duration": 1315,
    "finished": false,
    "updated_at": 1789862326730
  }
];

/// 全量 progress（用于对照：哪些行被 `position > 5` 滤掉了）
const List<Map<String, dynamic>> t67RealAllProgress = [
  {
    "key": "cycani:3862",
    "provider": "cycani",
    "native_id": "3862",
    "title": "无职转生 第三季 ～到了异世界就拿出真本事～",
    "cover": "https://gimg1.baidu.com/gimg/app=2001&src=img2.cycimg.me/pic/cover/l/1f/9e/501963_bXlEP.jpg",
    "episode_id": "51463",
    "episode_title": "第01集",
    "position": 1168,
    "duration": 1420,
    "finished": false,
    "updated_at": 1790486650760
  },
  {
    "key": "caiji:74774",
    "provider": "caiji",
    "native_id": "74774",
    "title": "老舅",
    "cover": "https://img.dytt-tupian.com/upload/vod/20251215-1/fc0817219f8ea0b8a81b4c77e1bf19c2.jpg",
    "episode_id": "https://vip.dytt-cine.com/share/bc710915a8b0cd159ff75ae17ebedd5c",
    "episode_title": "第01集",
    "position": 1,
    "duration": 2759,
    "finished": false,
    "updated_at": 1790485737562
  },
  {
    "key": "360:86969",
    "provider": "360",
    "native_id": "86969",
    "title": "老舅",
    "cover": "https://www.imgzy360.com:7788/upload/vod/20251216-1/28de6245d83ec43ce44eaaf7a1398ffd.jpg",
    "episode_id": "https://vod1.maowushi.com/20251215/3WorkiUa/index.m3u8",
    "episode_title": "第01集",
    "position": 4,
    "duration": 2777,
    "finished": false,
    "updated_at": 1790483545164
  },
  {
    "key": "cycani:3841",
    "provider": "cycani",
    "native_id": "3841",
    "title": "",
    "cover": null,
    "episode_id": null,
    "episode_title": null,
    "position": 122,
    "duration": 1422,
    "finished": false,
    "updated_at": 1790430571527
  },
  {
    "key": "cycani:3892",
    "provider": "cycani",
    "native_id": "3892",
    "title": "Re：从零开始的异世界生活 第四季 夺还篇",
    "cover": "https://gimg1.baidu.com/gimg/app=2001&src=img2.cycimg.me/pic/cover/l/43/ca/633836_ql0f3.jpg",
    "episode_id": "51699",
    "episode_title": "第01集",
    "position": 1,
    "duration": 1420,
    "finished": false,
    "updated_at": 1790331442163
  },
  {
    "key": "cycani:3611",
    "provider": "cycani",
    "native_id": "3611",
    "title": "剧场版 鬼灭之刃 无限城篇 第一章 猗窝座再袭",
    "cover": "https://gimg1.baidu.com/gimg/app=2001&src=img2.cycimg.me/pic/cover/l/f6/0b/501958_VZs4W.jpg",
    "episode_id": "48884",
    "episode_title": "正片",
    "position": 2971,
    "duration": 9285,
    "finished": false,
    "updated_at": 1790331352097
  },
  {
    "key": "bilibili:bilibili:av:BV1B8ZJYTEPg",
    "provider": "bilibili",
    "native_id": "bilibili:av:BV1B8ZJYTEPg",
    "title": "现代修仙，没钱纯靠自律【自律狠人】【第一季超长电影版】",
    "cover": "https://i2.hdslb.com/bfs/archive/bd88ddaef2e676a386be293c12de0b9becab9f82.jpg",
    "episode_id": "BV1B8ZJYTEPg|29165686089",
    "episode_title": "现代修仙，没钱纯靠自律【自律狠人】【第一季超长电影版】",
    "position": 15,
    "duration": 2958,
    "finished": false,
    "updated_at": 1790143040293
  },
  {
    "key": "bilibili:av:BV1YDhJ6ZEL6",
    "provider": "bilibili",
    "native_id": "av:BV1YDhJ6ZEL6",
    "title": "《柯洁围棋入门课》",
    "cover": "https://i2.hdslb.com/bfs/archive/35baeae957483b53d75c1dd12eecb7e6d2f498c4.jpg",
    "episode_id": "BV1YDhJ6ZEL6|42108063716",
    "episode_title": "《柯洁围棋入门课》",
    "position": 28,
    "duration": 498,
    "finished": false,
    "updated_at": 1790138648425
  },
  {
    "key": "tyyszy:70260",
    "provider": "tyyszy",
    "native_id": "70260",
    "title": "怒鲨狂潮",
    "cover": "https://tyyswimg2.com/upload/vod/20260919-1/71a874cf973063a070dee4339abf5d3a.jpg",
    "episode_id": null,
    "episode_title": null,
    "position": 123,
    "duration": 2,
    "finished": true,
    "updated_at": 1790138585619
  },
  {
    "key": "bilibili:av:BV1o2eM6kEDT",
    "provider": "bilibili",
    "native_id": "av:BV1o2eM6kEDT",
    "title": "“至此，已成神品！！！”",
    "cover": "https://i2.hdslb.com/bfs/archive/469d4ace3ffa6201208d42e73b9053d7191a1530.jpg",
    "episode_id": "BV1o2eM6kEDT|41961327629",
    "episode_title": "“至此，已成神品！！！”",
    "position": 3,
    "duration": 200,
    "finished": false,
    "updated_at": 1790137536075
  },
  {
    "key": "154:59466",
    "provider": "154",
    "native_id": "59466",
    "title": "揭秘日",
    "cover": "https://vcover-vt-pic.puui.qpic.cn/vcover_vt_pic/0/mzc00200gexv9lm1766049185742/0",
    "episode_id": "https://v.qq.com/x/cover/mzc00200gexv9lm/h41028xc0lf.html",
    "episode_title": "原声版",
    "position": 3663,
    "duration": 8582,
    "finished": false,
    "updated_at": 1790134300460
  },
  {
    "key": "cycani:3885",
    "provider": "cycani",
    "native_id": "3885",
    "title": "最强废渣皇子暗中活跃于帝位之争",
    "cover": "https://gimg1.baidu.com/gimg/app=2001&src=img2.cycimg.me/pic/cover/l/a7/a6/456081_Bs2nE.jpg",
    "episode_id": "51558",
    "episode_title": "第01集",
    "position": 148,
    "duration": 1420,
    "finished": false,
    "updated_at": 1790011629676
  },
  {
    "key": "bilibili:av:BV16veP6eEeC",
    "provider": "bilibili",
    "native_id": "av:BV16veP6eEeC",
    "title": "《花骨朵》亚细亚旷世奇才/洛天依",
    "cover": "https://i1.hdslb.com/bfs/archive/d47d936f14f9fd33f70926014771ae60f75970f1.jpg",
    "episode_id": null,
    "episode_title": null,
    "position": 170,
    "duration": 170,
    "finished": true,
    "updated_at": 1789878686510
  },
  {
    "key": "bilibili:av:BV1SveU6GExV",
    "provider": "bilibili",
    "native_id": "av:BV1SveU6GExV",
    "title": "【微电影】星河外卖员：平台战争",
    "cover": "https://i2.hdslb.com/bfs/archive/aec1a2db1f328dcb45c58eae13809b2da108b1a6.jpg",
    "episode_id": null,
    "episode_title": null,
    "position": 36,
    "duration": 1206,
    "finished": false,
    "updated_at": 1789869728775
  },
  {
    "key": "bilibili:av:BV1cSec6tEux",
    "provider": "bilibili",
    "native_id": "av:BV1cSec6tEux",
    "title": "选哪个？iPhone 18 Pro&Duo深度上手",
    "cover": "https://i1.hdslb.com/bfs/archive/aec12235afcae7c12ed1eb3684c103ed407434bf.jpg",
    "episode_id": null,
    "episode_title": null,
    "position": 2,
    "duration": 1631,
    "finished": false,
    "updated_at": 1789867702902
  },
  {
    "key": "bilibili:av:BV1Bfex6tEEH",
    "provider": "bilibili",
    "native_id": "av:BV1Bfex6tEEH",
    "title": "探厂红旗｜走进千万硬核声学实验室！详解全新红旗H7车载音响！",
    "cover": "https://i0.hdslb.com/bfs/archive/0c7ceb91e27337a5760be089e2586ff5f03d3405.jpg",
    "episode_id": null,
    "episode_title": null,
    "position": 12,
    "duration": 1315,
    "finished": false,
    "updated_at": 1789862326730
  }
];
