/**
 * @id          iptv
 * @name        IPTV 直播
 * @version     1.2.0
 * @author      dsh
 * @description 整合 iptv-org 公共直播源（含 CCTV 全套），解决「央视官方源视频轨加密看不了」
 * @homepage    https://iptv-org.github.io
 *
 * ═══════════════════════════════════════════════════════════════
 *  v1.1.0（2026-09-25）：**给用户看的东西中文化**
 *
 *  # 用户视角的问题（v1.0.0 发出去会看到的）
 *  ```text
 *  分栏标题：  General / News / Sports ...   ← iptv-org 的英文分组
 *  频道名  ：  "CCTV-1 (720p)"               ← 带分辨率噪音
 *              "CCTV+ 1 (600p) [Not 24/7]"
 *  ⇒ 而且与 cctv.js 源**不一致**（那边是 "CCTV-1 综合"）
 *     用户会困惑"这两个是不是同一个台"
 *  ```
 *
 *  # 三件事一起改（见下面各自的注释）
 *  ```text
 *  ① GROUP_ZH     15 项英文分组 → 中文（**未映射回落原文**，不塞"其它"）
 *  ② stripNoise() 去掉 (720p)/(1080p)/(576i)/(SD)/(HD)/[Not 24/7]
 *  ③ ZH_NAMES     26 个官方中文台名（来源见下）
 *  ```
 *
 *  # ★★ ZH_NAMES 的来源（不是我编的，也不是抄 cctv.js）
 *
 *  iptv-org 的 `channels.json`（7.9 MB, 31375 条）里每个频道有 `alt_names`，
 *  其中**就含官方中文名**：
 *  ```text
 *  https://iptv-org.github.io/api/channels.json
 *    "CCTV1.cn" → name "CCTV-1",  alt_names ["CCTV-1 综合"]
 *    "CCTV9.cn" → name "CCTV-9",  alt_names ["CCTV-9 纪录"]
 *  ```
 *  ★ 实测 28 个白名单里 **26 个有中文名**；剩 2 个（CCTV+ 1/2）官方也没有
 *    中文名 ⇒ 保留英文（它们本来就是对外频道）。
 *
 *  # 为什么**固化**进插件，而不是运行时拉 channels.json
 *  ```text
 *  channels.json = 7.9 MB，而 cn.m3u 只有 29 KB
 *  ⇒ 为 26 个名字拉 7.9MB **不值得**（用户要等好几秒）
 *  ★ 而中文台名是**低频变化**数据（央视改名极少）⇒ 固化合理
 *  ```
 *
 *  # ★ 刷新方式（与白名单**同一套流程**）
 *  ```text
 *  ① 重跑 .probe/t34_gen_zh_names.py   → 生成新的 ZH_NAMES 片段
 *  ② 重跑 .probe/t34_check_ids.py      → 核对白名单 tvg-id 没漂
 *  ③ 提升本文件的 @version             → 用户机器自动升级
 *     （seed_iptv_plugin 会比对版本，见 state.rs）
 *  ```
 *  ★ 交叉验证：主频道名与 `cctv.js` 的权威表**逐字一致**
 *    （`CCTV-1 综合` / `CCTV-9 纪录` / `CCTV-13 新闻` …）—— 两边独立来源却一致，
 *    说明这份名字可信（`cctv.js` 是项目原有的表）。
 *
 * ═══════════════════════════════════════════════════════════════
 *  为什么要做这个插件（用户原话）
 *
 *    「cctv的直播还是不行，之前给你参考的tvbox源应该也有包含直播的，
 *      你看看  都没整合进去」
 *
 *  # 央视官方源为什么「不行」（实测结论，不是猜）
 *
 *  `cctv.js` 的注释里记录过：官方直播的**视频轨被加密**（`udrm`）——
 *  容器和 NAL 头是明文（ffprobe 能读出 h264 + 分辨率），但载荷加密，
 *  解码时报 `top block unavailable for requested intra mode` /
 *  `error while decoding MB`。表现是**画面花屏但时间在走**。
 *  实测 16 个央视频道**全部**如此（204~262 个解码错误）。
 *  ⇒ 这是**内容方**的保护，客户端绕不过去。
 *
 *  # 所以出路是「换一条不加密的源」
 *
 *  本插件从 iptv-org 拉公共直播列表。我**逐个真解码验证**过：
 *    可播（连上 + 解出帧 + 0 解码错误）= 46 个（2026-09-30 复测），
 *    暴露给用户 44 个 = CCTV 相关 27 个 + 地方/国际台 17 个
 *
 *  ★★ 关键教训：**HTTP 200 ≠ 能播**
 *     iptv-org 的 cn.m3u 有 144 条，光看 HTTP 状态会以为大部分可用，
 *     但真解码后：
 *       · 有些 URL 连不上（301/404/连接重置）—— HTTP 层就死
 *       · 有些连上了但**载荷加密**（和央视官方同一个症状）
 *     ⇒ 只挑 **实测可解码** 的暴露给用户，否则"整合了还是不能看"。
 *
 *  # 与 cctv.js 的关系
 *
 *  **两个都保留，互不替代**：
 *    · `cctv.js` —— 官方源（点播/EPG/时移都全，直播会如实标 drm）
 *    · `iptv.js` —— 公共源（直播能出画面，但没有 EPG/时移）
 *  用户可以在设置页按需启停。
 * ═══════════════════════════════════════════════════════════════
 */

/**
 * 播放列表来源
 *
 * ⚠️ 只用 iptv-org 官方站（`iptv-org.github.io`）——
 *    实测那 16 个 TVBox 源**基本全废**：
 *      范明明 ipv6  200 但抽样 20 个全 400/403
 *      Yoursmile    200 但只有 114 字节（空）
 *      肥猫/俊于     404
 *      其余 11 个    SSLError / 相对路径
 *    ⇒ 整合它们等于白干。
 */
const PLAYLISTS = [
  {
    id: 'cn',
    name: '中国',
    url: 'https://iptv-org.github.io/iptv/countries/cn.m3u',
  },
]

/**
 * 列表缓存
 *
 * # ★★★ 缓存 key 必须带**结构版本**（v1.1.0 踩过的坑）
 *
 * ```text
 * 我在 v1.1.0 加了 tvgId 字段，同时把 key 从 cache_v1 改成 cache_v2
 * —— 看起来"换了 key 就干净了"。
 * ★ 但 v1.0.0 的**代码**也已经被我改成写 cache_v2 了
 *   （我在同一轮里既改结构又改 key），于是：
 *     ① 我自己的测试用旧代码跑过一次 ⇒ 写进 cache_v2（无 tvgId）
 *     ② 改完代码再跑 ⇒ 命中 cache_v2 的**旧结构** ⇒ 中文名全查不到（0/28）
 * ```
 * ⇒ 教训：**改缓存结构时，光换 key 不够 —— 必须同时校验"结构本身"**。
 *   因为"用旧代码写新 key"这种情况总会发生（测试、灰度、回滚）。
 *
 * 所以这里做两层：
 * ```text
 * ① key 带版本（cache_v3）—— 换结构时改它
 * ② ★ 读出来**校验必需字段**（见 cacheValid）—— 结构不对就当没有
 * ```
 * 第二层才是真正的保险：它不依赖"我有没有记得改 key"。
 */
const CACHE_KEY = 'cache_v3'
const CACHE_TTL_MS = 6 * 60 * 60 * 1000 // 6 小时

/**
 * ★ 缓存结构校验（第二层保险）
 *
 * 只认"每条都有 id 和 tvgId"的缓存。
 * 结构不对 ⇒ 返回 false ⇒ 调用方**重新拉取**（而不是用坏数据）。
 */
function cacheValid(c) {
  if (!c || !c.at || !Array.isArray(c.list) || !c.list.length) return false
  // 抽查前 5 条（不必全量 —— 结构是整体写入的）
  return c.list.slice(0, 5).every((x) => x && x.id && x.tvgId)
}

/**
 * ★ v1.1.0：iptv-org 的英文分组 → 中文
 *
 * # 为什么需要
 *
 * iptv-org 的 `group-title` 是英文（`General` / `News` / `Sports`…）。
 * 用户看到分栏标题是 `General` 会不知道是什么。
 *
 * # ★ 未映射的**回落原文**，不塞"其它"
 *
 * 这一点是有意的：
 * ```text
 * 塞"其它"  ⇒ 所有新分组混成一栏，用户**看不出区别**，信息丢失
 * 回落原文  ⇒ 用户至少能看到 "Travel"，比"其它"有用
 * ```
 * iptv-org 会加新分组（如 `Travel`），我们不可能永远同步。
 * ⇒ 回落是**结构上**更安全的选择。
 *
 * ⚠️ 这不是"我们的分类体系"，只是**给 iptv-org 的分组配中文**。
 *    改这份表不需要动白名单。
 */
const GROUP_ZH = {
  General: '综合',
  News: '新闻',
  Business: '财经',
  Entertainment: '综艺',
  Movies: '电影',
  Sports: '体育',
  Kids: '少儿',
  Education: '科教',
  EducationOutdoor: '科教·户外',
  /*
   * ★ 复合分组的**第二段**也要单独映射
   *
   * iptv-org 的 `Education;Outdoor` 会先按 `;` 拆开，所以需要
   * `Outdoor` 这一项 —— 否则会显示成 "科教·Outdoor"（半中半英）。
   * ★ 这是实测踩到的：我第一版只加了 `EducationOutdoor`（整串），
   *   但拆开之后查的是 `Outdoor` ⇒ 没命中 ⇒ 半中半英。
   *   ⇒ 整串 + 每段**都要有**。
   */
  Outdoor: '户外',
  Science: '科学',
  Culture: '戏曲文化',
  Music: '音乐',
  Documentary: '纪录',
  Lifestyle: '生活',
  Classic: '经典剧场',
  Animation: '动画',
  Religious: '宗教',
  Shop: '购物',
  Weather: '气象',
  Undefined: '其它',
}

/**
 * ★ v1.1.0：官方中文台名（26 条）
 *
 * # 来源（不是我编的，也不是抄 cctv.js）
 *
 * ```text
 * https://iptv-org.github.io/api/channels.json     （7.9 MB, 31375 条）
 *   每条有 name + alt_names，alt_names 里含**官方中文名**
 *     "CCTV1.cn" → alt_names ["CCTV-1 综合"]
 * ```
 * ★ 交叉验证：主频道名与 `cctv.js` 的权威表**逐字一致**
 *   （`CCTV-1 综合` / `CCTV-9 纪录` / `CCTV-13 新闻` …）
 *   —— 两个独立来源却一致 ⇒ 可信。
 *
 * # ★★★ key 是**剥掉 `@SD`/`@HD` 后缀**的 tvg_id
 *
 * 这一步必须写明，否则后人会踩：
 * ```text
 * 我们白名单里的 id ： 'CCTV1.cn@SD'      ← 带画质后缀
 * channels.json 的 id： 'CCTV1.cn'        ← 不带
 * ⇒ 直接拿 'CCTV1.cn@SD' 去查表**永远查不到**
 *   （lead 的检查脚本第一版就是这么错的：报"28 个都不在表里"）
 * ```
 * 所以 `zhName()` 里先 `split('@')[0]` —— 见下面的实现与测试。
 *
 * # 刷新方式（与白名单同一套流程）
 * ```text
 * .probe/t34_gen_zh_names.py  → 重新生成这份表
 * .probe/t34_check_ids.py     → 核对白名单 tvg-id 没漂
 * 提升 @version               → 用户机器自动升级（state.rs 的 seed 会比对版本）
 * ```
 *
 * ⚠️ CCTV+ 1 / CCTV+ 2 官方也没有中文名 ⇒ **有意保留英文**
 *    （它们是 cctvplus.com 的对外频道，本来就叫 "CCTV+ 1"）。
 */
const ZH_NAMES = {
  'CCTV1.cn': 'CCTV-1 综合',
  'CCTV2.cn': 'CCTV-2 财经',
  'CCTV3.cn': 'CCTV-3 综艺',
  'CCTV7.cn': 'CCTV-7 国防军事',
  'CCTV8.cn': 'CCTV-8 电视剧',
  'CCTV9.cn': 'CCTV-9 纪录',
  'CCTV10.cn': 'CCTV-10 科教',
  'CCTV11.cn': 'CCTV-11 戏曲',
  'CCTV12.cn': 'CCTV-12 社会与法',
  'CCTV13.cn': 'CCTV-13 新闻',
  'CCTV8K.cn': 'CCTV-8K 超高清',
  'CCTV14.cn': 'CCTV-14 少儿',
  'CCTV16.cn': 'CCTV-16 奥林匹克',
  'CCTV17.cn': 'CCTV-17 农业农村',
  'CCTVBilliards.cn': 'CCTV-央视台球',
  'CCTVCultureofQuality.cn': 'CCTV-央视文化精品',
  'CCTVGolfTennis.cn': 'CCTV-高尔夫·网球',
  'CCTVHealth.cn': 'CCTV-卫生健康',
  'CCTVNostalgiaTheater.cn': 'CCTV-怀旧剧场',
  'CCTVStormFootball.cn': 'CCTV-风云足球',
  'CCTVStormMusic.cn': 'CCTV-风云音乐',
  'CCTVStormTheater.cn': 'CCTV-风云剧场',
  'CCTVTheFirstTheater.cn': 'CCTV-第一剧场',
  'CCTVWeaponTechnology.cn': 'CCTV-兵器科技',
  'CCTVWomensFashion.cn': 'CCTV-女性时尚',
  'CCTVWorldGeography.cn': 'CCTV-世界地理',
}

/**
 * ★ v1.1.0：去掉频道名里的**画质/状态噪音**
 *
 * # 噪音长什么样（实测 28/28 全都有）
 * ```text
 * "CCTV-1 (720p)"                     → "CCTV-1"
 * "CCTV-9 (576i)"                     → "CCTV-9"
 * "CCTV-8K HD (1080p)"                → "CCTV-8K"
 * "CCTV+ 1 (600p) [Not 24/7]"         → "CCTV+ 1"
 * "CCTV-Women's Fashion SD (1080p)"   → "CCTV-Women's Fashion"
 * ```
 * ⚠️ 只去**括号里是画质**的那种 `(720p)`，**不去**所有括号 ——
 *    否则会把有意义的名字（如 "XXX (China)"）误删。
 *    ⇒ 判据收紧为：括号内匹配 `^\d{3,4}[pi]$` 或 `^(SD|HD|FHD|UHD)$`
 *
 * ★★★ 这里踩过一个正则 bug（被 `iptv_v110_no_stray_parens` 抓出来）
 * ```text
 * 错：把两个分支写成  \(  (?:480|...)[pi]  |  (?:SD|HD|FHD|UHD)  \)
 *                     ↑ `|` 把正则**劈成两个顶层分支**：
 *                       分支A 以 `\(` 开头、**没有闭合的 \)**
 *                       分支B 只有 `SD|HD` 部分 + `\)`
 *     ⇒ "CCTV+ 1 (600p)" 走分支A ⇒ 只吃掉 "(600p" ⇒ **剩下一个孤零零的 ')'**
 *     ⇒ 用户看到 "CCTV+ 1 )"
 * 对：把两个分支都放进 `(?:...)`，`\)` 在最后统一闭合
 *     ⇒ 见下面 NOISE_PAREN 的实际写法
 * ```
 * ★ 教训：**正则里的 `|` 优先级最低** —— 想表达"括号里是 A 或 B"，
 *   必须把两个分支都放进 `(?:...)`，不能写在 `\(` 的外面。
 *
 * ⚠️ 另一个坑：**文档注释里不要原样写正则的结尾**（星号紧跟斜杠）——
 *    那会把块注释提前结束掉 ⇒ **JS 语法错误**（插件直接报 unexpected character）。
 *    （我就是这么踩的：5 条测试全红，排查了好一会儿。）
 *    ⇒ 想举例正则结尾，写成「星号 + 斜杠」这种描述，别把两个字符连着打。
 */
const NOISE_PAREN = /\s*\((?:(?:480|540|576|600|720|1080|2160)[pi]|SD|HD|FHD|UHD)\)\s*/gi
const NOISE_TAG = /\s*\[(?:Not 24\/7|Geo-blocked|Offline)\]\s*/gi

/**
 * ★★★ 实测可播白名单（2026-09-30 五轮 ffmpeg 真解码复测）
 *
 * # 为什么要白名单，而不是"全量暴露"
 *
 * cn.m3u 有 144 条，但：
 * ```text
 * ① HTTP 层就死的（301/404/连接重置）  —— 用户点了转圈
 * ② 连上但载荷加密的（与央视官方同症状）—— 用户看到花屏，比转圈更困惑
 * ③ 真能解的                            —— 只有 46 个
 * ```
 * 若全量暴露，用户会以为"这个源大部分频道都是坏的"。
 *
 * # 为什么不"运行时逐个验证"
 *
 * 每个频道要解 6 秒才判定 ⇒ 46 个要 4.6 分钟以上 ⇒ 进直播页等 4 分钟
 * 是不可接受的。所以**用白名单（快）+ 缓存（省流量）**。
 *
 * # ⚠️ 白名单会过期
 *
 * 公共源的生命周期以周计。所以：
 *   · 用户报"某个台看不了" ⇒ 重跑一次验证脚本刷新这份表
 *   · `liveChannels()` 里对白名单**按 tvg-id 匹配**，
 *     列表里没有的（下架了）自动跳过，不会暴露死链
 *   · 提供一个 `refresh()` 能力（见文件末尾）供将来做"手动刷新"
 *
 * 格式：`tvg-id`（iptv-org 的唯一标识，实测 144 条**无缺失、无重名**）
 *
 * ★★★ 这张表里的每一个 id 都必须**从真实列表里核对过**，不能按名字推测。
 *     我第一版有 13/28 个是猜的，全错，而且是**两种不同的错**：
 *     ```text
 *     · 后缀猜错：CCTV14.cn@SD      （真值是 @HD）—— 高清台是 @HD
 *     · 拼写猜错：CCTVBillards.cn@SD（真值是 CCTVBilliards.cn@HD，
 *                                   少一个 i，且后缀也不对）
 *     ```
 *     ⇒ 后果：白名单匹配不到 ⇒ **用户看到空的频道列表**，
 *       比"不整合"更糟（不整合至少还有 cctv.js 的官方源）。
 *     ⇒ 教训：**白名单是"外部数据"，必须用脚本从源里核对**
 *       （`.probe/t34_check_ids.py` 就是干这个的，改完白名单要重跑）。
 *
 * ★★★ 2026-09-30 复测的**仪器教训**（比名单本身更重要）：
 *     公共源会**限流**。同一台主机上短时间内连续连接，会在几次成功之后
 *     **突然全部拒连**（表现为 `Connection to tcp://... failed`），
 *     冷却 90 秒后又能连上。实测证据：某台主机连续 3 次成功
 *     （t+54 / t+65 / t+79）后从第 4 次起全部失败，而**裸 TCP 仍可连**。
 *     ```text
 *     · 12 个并发打同一台主机  ⇒ 该主机 12 个台**全部**假失败（★ 差点误删）
 *     · 同一批台严格串行      ⇒ 12 个**全部**通过
 *     ```
 *     ⇒ **并发打同一台主机会造成假阴性**，而假阴性在这里最危险：
 *       它会让我们**主动删掉能播的台**。
 *     ⇒ 正确仪器设计：**跨主机并行 + 主机内严格串行**
 *       （不同主机互不干扰，保留速度；主机内串行消除自己打自己的限流）。
 *     ⇒ 读数的可信性规则：
 *       · **通过（OK）的读数一律可信**（限流只造成假阴性，不造成假阳性）
 *       · **单频道主机**上的失败可信（没有自己造成的争用）
 *       · **多频道主机**上的失败**不可信**，要串行复测才能判定
 */
const VERIFIED_IDS = [
  // ── 央视主频道（实测全部 0 解码错误）──
  'CCTV1.cn@SD',
  'CCTV2.cn@SD',
  'CCTV3.cn@SD',
  'CCTV7.cn@SD',
  'CCTV8.cn@SD',
  'CCTV9.cn@SD',
  'CCTV10.cn@SD',
  'CCTV11.cn@SD',
  'CCTV12.cn@SD',
  'CCTV13.cn@SD',
  // ── 高清变体（★ 后缀是 @HD 不是 @SD —— 我第一版猜错，见下面教训）──
  'CCTV8K.cn@HD',
  'CCTV14.cn@HD',
  'CCTV16.cn@HD',
  'CCTV17.cn@HD',
  // ── CCTV+（cctvplus.com 官方源）──
  'CCTVPlus2.cn@SD',
  // ── 央视付费/主题频道（38.75.136.137 那批，实测全可播）──
  'CCTVBilliards.cn@HD',
  'CCTVCultureofQuality.cn@SD',
  'CCTVGolfTennis.cn@HD',
  'CCTVHealth.cn@HD',
  'CCTVNostalgiaTheater.cn@HD',
  'CCTVStormFootball.cn@HD',
  'CCTVStormMusic.cn@HD',
  'CCTVStormTheater.cn@HD',
  'CCTVTheFirstTheater.cn@HD',
  'CCTVWeaponTechnology.cn@HD',
  'CCTVWomensFashion.cn@SD',
  'CCTVWorldGeography.cn@SD',
  // ── 地方/国际台（★★ 2026-09-30 新增 17 个；用户此前"只看到 CCTV 的"就是这个原因）──
  'ABNChina.us@SD',                            // ABN China (720p)
  'BaichengTV.cn@SD',                          // Baicheng TV
  'ChifengComprehensiveNewsChanel.cn@SD',      // 赤峰新闻综合（★ Chanel 只有一个 n）
  'ChuxiongNewsChannel.cn@SD',                 // 楚雄新闻
  'HarbinComprehensiveNewsChannel.cn@SD',      // 哈尔滨新闻综合
  'HarbinMovieChannel.cn@SD',                  // 哈尔滨影视
  'HunanTV.cn@SD',                             // 湖南卫视 (2160p)
  'JilinCityChannel.cn@SD',                    // 吉林市台
  'JilinLifestyleChannel.cn@SD',               // 吉林生活
  'JilinMovieChannel.cn@SD',                   // 吉林影视
  'JilinRuralChannel.cn@SD',                   // 吉林乡村
  'LanzhouComprehensiveNewsChannel.cn@SD',     // 兰州新闻综合
  'LanzhouCultureTourismChannel.cn@SD',        // 兰州文旅
  'SipingTV.cn@SD',                            // 四平台
  'TVBRICSChinese.cn@SD',                      // TV BRICS 中文 (1080p)
  'TonghuaTV.cn@SD',                           // 通化台 (1080p)
  'ZhejiangInternationalChannel.cn@SD',        // 浙江国际
]

/**
 * 拉取并解析一个 m3u
 *
 * # 三个必须处理的点
 *
 * ```text
 * ① host.http **不抛异常** —— 失败返回 `__ERR__` 前缀串
 *    直接 JSON.parse / 正则匹配会得到莫名其妙的空结果
 * ② 编码：公共 m3u 大多是 UTF-8，但**不能假设** ——
 *    宿主 http 返回的是 Rust String（已是 UTF-8），
 *    所以这里只需处理"中文乱码"（有些源实际是 GBK 但被当 UTF-8 解）
 * ③ #EXTINF 与 URL 是**两行**，中间不能插别的（否则是脏数据）
 * ```
 */
async function fetchM3u(url) {
  const text = await host.http.get(url)
  if (typeof text !== 'string') {
    throw new Error('network: 列表返回非文本')
  }
  if (text.startsWith('__ERR__')) {
    throw new Error('network: ' + text.slice(7))
  }
  if (!text.includes('#EXTM3U') && !text.includes('#EXTINF')) {
    throw new Error('parse: 不是 m3u 格式 — ' + text.slice(0, 100))
  }
  return parseM3u(text)
}

/**
 * 解析 m3u 文本 → 频道数组
 *
 * ★ 只认标准 `#EXTINF` 后紧跟一行 URL 的形式。
 *   实测 iptv-org 的格式很规整，但脏数据要能跳过而不是崩。
 */
function parseM3u(text) {
  const out = []
  let cur = null
  for (const raw of text.split('\n')) {
    const line = raw.trim()
    if (!line) continue

    if (line.startsWith('#EXTINF')) {
      // 名字在**最后一个逗号之后**（属性里也可能有逗号）
      const comma = line.lastIndexOf(',')
      const name = comma >= 0 ? line.slice(comma + 1).trim() : ''
      cur = {
        name,
        tvgId: pick(line, 'tvg-id'),
        logo: pick(line, 'tvg-logo'),
        group: pick(line, 'group-title'),
      }
    } else if (!line.startsWith('#') && cur) {
      cur.url = line
      // ★ 必须有名字和 URL，否则是脏数据
      if (cur.url && cur.name) out.push(cur)
      cur = null
    }
  }
  return out
}


/** 从 #EXTINF 行里取 `key="value"` */
function pick(line, key) {
  const m = line.match(new RegExp(key + '="([^"]*)"'))
  return m ? m[1] : ''
}

/**
 * 频道 id
 *
 * # 为什么用 tvg-id 而不是 URL / index
 *
 * ```text
 * URL   —— 公共源会换 CDN，URL 一变 id 就变 ⇒ 用户的收藏/历史全失效
 * index —— 列表顺序会变（源上下架）⇒ id 指向别的台 ⇒ 更糟（点 A 放 B）
 * tvg-id —— iptv-org 的**稳定标识**（实测 144 条无缺失、无重名）
 *          且它本身就是"CCTV1.cn@SD"这种可读形式
 * ```
 * ⚠️ 兜底：万一某条缺 tvg-id，用 name 的规范化形式（也稳定）
 */
function chanId(c) {
  return c.tvgId || ('n:' + c.name.replace(/\s+/g, '_'))
}

/**
 * ★ v1.1.0：剥掉画质后缀，得到 channels.json 用的 id
 *
 * # ★★★ 这一步必须存在（否则查表永远失败）
 *
 * ```text
 * 我们的 tvg_id      ： 'CCTV1.cn@SD'   ← m3u 里带的画质后缀
 * channels.json 的 id： 'CCTV1.cn'      ← 不带后缀
 * ⇒ 拿 'CCTV1.cn@SD' 直接查 ZH_NAMES **永远查不到**
 * ```
 * ★ 这是真踩过的：lead 的检查脚本第一版没剥后缀，报"28 个都不在表里"，
 *   差点推翻一个正确的结论。所以：
 *   · 这里显式剥
 *   · 并且**有测试守着**（batch4_live.rs 里断言 '@SD'/'@HD' 都能查到）
 */
function baseId(tvgId) {
  return String(tvgId || '').split('@')[0]
}

/**
 * ★ v1.1.0：频道显示名（中文优先）
 *
 * 优先级：
 * ```text
 * ① ZH_NAMES 里有 ⇒ 用它（官方中文名，与 cctv.js 逐字一致）
 * ② 没有          ⇒ 用官方英文名（如 "CCTV+ 1"），但**仍去噪音**
 * ```
 * ★ 两种情况都去噪音 —— 否则 CCTV+ 1 会显示成 "CCTV+ 1 (600p) [Not 24/7]"。
 */
function displayName(c) {
  const zh = ZH_NAMES[baseId(c.tvgId)]
  const raw = zh || c.name || ''
  return raw.replace(NOISE_PAREN, ' ').replace(NOISE_TAG, ' ').replace(/\s+/g, ' ').trim()
}

/**
 * ★ v1.1.0：分组显示名（中文优先，**未映射回落原文**）
 *
 * ★ 回落是**有意**的：塞"其它"会让所有新分组混成一栏、信息丢失。
 *   回落原文至少还能看到 "Travel"。
 */
function displayGroup(c) {
  const g = (c.group || '').trim()
  if (!g) return '其它'
  // ① 整体匹配（含复合分组的整串，如 'Education;Outdoor'）
  if (GROUP_ZH[g]) return GROUP_ZH[g]
  /*
   * ② 复合分组（如 "Education;Outdoor"）逐段映射后用 "·" 连接。
   *
   * ★ 为什么要单独处理：iptv-org 用 `;` 表示多标签。
   *   若只按整体查表，`Education;Outdoor` 查不到 ⇒ 会**回落成英文**，
   *   用户看到 "科教·Outdoor" 这种半中半英（实测踩到）。
   * ⇒ 逐段查表，段内查不到也回落原文（保持"不丢信息"这条原则）。
   */
  const parts = g.split(';').map((x) => x.trim()).filter(Boolean)
  if (parts.length <= 1) return g
  return parts.map((p) => GROUP_ZH[p] || p).join('·')
}

/**
 * 带缓存的频道列表
 *
 * # 为什么要缓存
 *
 * cn.m3u 约 29 KB。进一次直播页拉一次是浪费，
 * 而且公共源对高频请求会限流。
 * 缓存 6 小时：足够新，又不会每次都拉。
 */
async function loadChannels(force) {
  if (!force) {
    const raw = host.store.get(CACHE_KEY)
    if (raw) {
      try {
        const c = JSON.parse(raw)
        // ★ 必须同时过 TTL 与**结构校验**（见 cacheValid 的说明）
        if (cacheValid(c) && Date.now() - c.at < CACHE_TTL_MS) {
          return c.list
        }
        if (c && Array.isArray(c.list) && !cacheValid(c)) {
          host.log.warn('缓存结构过期（缺 tvgId），重新拉取列表')
        }
      } catch {
        // 缓存坏了就当没有（不抛 —— 缓存不是关键路径）
      }
    }
  }

  const merged = []
  const seen = {}
  for (const pl of PLAYLISTS) {
    let list
    try {
      list = await fetchM3u(pl.url)
    } catch (e) {
      // ★ 单个列表失败不拖垮整体（与客户端"错误隔离"策略一致）
      host.log.warn('列表 ' + pl.id + ' 拉取失败: ' + e.message)
      continue
    }
    for (const c of list) {
      const id = chanId(c)
      if (seen[id]) continue // 去重（同 tvg-id 只留第一个）
      seen[id] = 1
      merged.push({
        id,
        /*
         * ★★ v1.1.0：必须**保留 tvgId**（不能只留 id）
         *
         * # 这里踩过一次（被 `iptv_v110_suffix_stripping_finds_chinese_name` 抓出来）
         * ```text
         * 我 v1.0.0 只存了 `id`（值是 chanId(c)，即 tvgId 本身）
         * 但 displayName() 读的是 `c.tvgId`  ⇒ **undefined** ⇒ 查表失败
         * ⇒ 28 个频道名**全部**回落英文（测试报 "0/28 含中文"）
         * ```
         * ⚠️ 为什么当时没发现：`id` 与 `tvgId` **值恰好相同**，
         *    所以白名单过滤、liveStream 全都正常 —— 只有查中文名会静默失败。
         *    ⇒ 这正是"假阴性"：功能看着能用，只是显示成英文。
         *
         * 所以两个字段都留：`id`（对外标识）+ `tvgId`（查名字用）。
         * 将来若 chanId 的规则变了（如加前缀），两者会不同 —— 那时更需要分开。
         */
        tvgId: c.tvgId,
        name: c.name,
        logo: c.logo || undefined,
        group: c.group || undefined,
        url: c.url,
      })
    }
  }

  if (!merged.length) {
    throw new Error('network: 所有直播列表都拉不到')
  }

  host.store.set(CACHE_KEY, JSON.stringify({ at: Date.now(), list: merged }))
  host.log.info('直播列表已更新: ' + merged.length + ' 个频道')
  return merged
}

globalThis.plugin = {
  id: 'iptv',

  capabilities: {
    vod: false,
    live: true,
    epg: false,
    search: false,
  },

  /**
   * 直播频道列表
   *
   * ★★★ 只返回**实测可解码**的那些（见 VERIFIED_IDS 的说明）。
   *
   * ⚠️ 用 `tvg-id` 匹配白名单，而不是"过滤掉不可播的"——
   *    后者要求我维护一份**黑名单**（会越来越长），
   *    而白名单天然是"只放我验过的"，失败模式更安全。
   */
  async liveChannels() {
    const all = await loadChannels(false)
    const allow = {}
    for (const id of VERIFIED_IDS) allow[id] = 1

    const out = all
      .filter((c) => allow[c.id])
      .map((c) => ({
        id: c.id,
        // ★ v1.1.0：中文名 + 去噪音（见 displayName 的注释）
        name: displayName(c),
        logo: c.logo,
        // ★ v1.1.0：分组中文化（未映射回落原文）
        group: displayGroup(c),
      }))

    /*
     * ★ 白名单里的 id 若在列表里找不到（下架了），**不报错** ——
     *   只是少一个台。报错会让整页打不开，那更糟。
     *   但要在日志里说明，方便排查"为什么少了某个台"。
     */
    if (out.length < VERIFIED_IDS.length) {
      host.log.warn(
        '白名单 ' + VERIFIED_IDS.length + ' 个，列表里只匹配到 ' +
          out.length + ' 个（其余可能已下架）',
      )
    }
    return out
  },

  /**
   * 直播取流
   *
   * ★ 频道地址直接从缓存的列表里取（不再发请求）——
   *   进播放页是热路径，不该再等一次网络。
   */
  async liveStream(channelId) {
    const all = await loadChannels(false)
    const c = all.find((x) => x.id === channelId)
    if (!c) {
      throw new Error('not_found: 频道 ' + channelId + ' 不在列表里（可能已下架）')
    }
    return [
      {
        url: c.url,
        kind: 'hls',
        // ★ v1.1.0：线路标签也用中文分组（与 liveChannels 一致）
        label: displayGroup(c),
        /*
         * ★★★ 缺陷 5（Owner 第 5 条）：这里**必须**回到「原始链接 + tag」。
         *
         * # Owner 原话
         * ```text
         * > tvbox 插件恢复为原始链接 + tag（自有平台 vs tvbox 兼容）
         * ```
         *
         * # 错在哪（改前长什么样）
         * ```text
         * 改前这一行是：label: displayGroup(c)
         * ⇒ 返回 [{url, kind: hls, label: 综合}]
         * ⇒ 只剩一个网址 + 一个中文分组词，tag 整条丢了。
         * ```
         *
         * # 为什么这回必须显式带上 tag（实测而不是推测）
         * ```text
         * parseM3u() 早在 :462-467 把 tvg-id / tvg-logo / group-title 三段 tag
         * 都解析进 c 了；loadChannels() :603-626 也都存进列表了。
         * ★ 可 liveStream() 一个都没往外带 ⇒ 从插件边界往客户端看，
         *   「原始链接」在，tag 却**不可达**：客户端只能拿到中文分组词，
         *   拿不到 tvg-id / 台标 / 英文原始分组。
         * ⇒ 缺陷不是解析漏了，而是**出口丢了**；修法就是让它离开边界时带上
         *   证据，而不是只带一个被本地化成中文的 label。
         * ```
         *
         * # 为什么是「原始链接」
         * ```text
         * c.url 是 m3u 里的原样地址（我们**不改写、不代理、不拼参数**，
         * 见上面 v1.1.0 那条 Referer/UA 注释）。
         * ⇒ 自有平台照旧 kind:hls 直接放；
         *   TVBox 兼容层也拿得到未改写的地址 + tag 去匹配自己的线路规则。
         * ```
         *
         * ⚠️ 保留 label（而不是删掉它）：label 是这一路的**中文显示名**。
         *    它缺失会让底栏/线路列表显示成空白；tag 是**机器可读**的另一面。
         *    两者不冲突，一个给人看，一个给兼容层看。
         */
        tags: {
          // ★ 原始 tvg-id（带 @SD/@HD 后缀，**未剥**）—— TVBox 的白名单匹配就用它
          'tvg-id': c.tvgId || '',
          // ★ 原始英文分组（**未中文化**）—— displayGroup() 会把它变成中文，这里留原文
          'group-title': c.group || '',
          'tvg-logo': c.logo || '',
        },
        /*
         * ⚠️ 不加 Referer/UA —— 这些公共源**不是**靠防盗链的，
         *    加了反而可能被某些 CDN 拒（实测 38.75.136.137 那批
         *    的 `?auth=testpub` 是 URL 自带的，与请求头无关）。
         */
      },
    ]
  },

  /**
   * 强制刷新列表（丢弃缓存）
   *
   * ═══════════════════════════════════════════════════════════════
   * ⚠️⚠️ **目前没有任何入口能调用到这个函数**（2026-09-25 实测确认）
   * ═══════════════════════════════════════════════════════════════
   *
   * # 为什么它调不到（三条实测证据，不是推测）
   * ```text
   * ① 它挂在**插件对象**上，而 `MediaProvider` trait 里**没有** refresh
   *    ⇒ 框架侧（registry / commands）拿到的是 trait 对象，**看不见它**
   * ② `commands_provider.rs` 里没有任何 `clear_*_cache` / `refresh_*` 命令
   * ③ `ffi.rs` 里也没有暴露相关命令
   * ```
   * ⇒ 用户/UI/手机遥控**都无法**主动刷新。缓存只能：
   * ```text
   * · 等 6 小时 TTL 自然过期
   * · 或删掉 plugins/.data/iptv.json 后重启
   * ```
   *
   * # 为什么**保留**它（而不是删掉）
   *
   * 它是一个**能力锚点**：将来若给插件体系加"清空某插件 store"的通用命令
   * （或做"设置页 → 强制刷新源"），这里已经就绪，不用再改动插件。
   * ★ 删掉会让下一个想做刷新的人**重新踩一遍"有没有入口"**。
   *
   * # 若将来真的要接入口，要注意
   * ```text
   * · 走 trait 的话不能直接加方法（会破坏所有已有插件）
   *   ⇒ 更合适的是通用命令"清空某插件的 host.store"
   * · 刷新后要**同时**更新 liveChannels 的返回（UI 需要重新拉列表）
   * ⇒ 这不是"加个按钮"，要动 commands_provider + UI 两处
   * ```
   *
   * ★ 用户报"某个台看不了"时的**当前处置方式**：
   *   让他等 6 小时、或删 `.data/iptv.json` 重启。
   *   若白名单本身过期了 ⇒ 那要我们发新版（见文件头的刷新流程）。
   */
  async refresh() {
    const list = await loadChannels(true)
    return { total: list.length }
  },
}
