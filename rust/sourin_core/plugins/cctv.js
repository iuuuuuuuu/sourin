/**
 * @id          cctv
 * @name        央视网
 * @version     1.0.0
 * @author      dsh
 * @description 央视网点播、直播、搜索、节目单、时移回看
 * @homepage    https://tv.cctv.com
 *
 * ═══════════════════════════════════════════════════════════════
 *  本插件是 `src-tauri/src/providers/cctv.rs` 的外置版本。
 *
 *  为什么要外置：原先它是编译进 exe 的 Rust 代码，用户看不到也改不了。
 *  现在它是一个普通的 .js 文件 —— 你能打开看、能改、能照着写自己的源。
 *
 *  所有接口都是 2026-09 实测确认过的，踩过的坑都写在注释里（别删）。
 * ═══════════════════════════════════════════════════════════════
 */

/** 央视接口对 Referer 有校验，缺了会返回错误页 */
const REFERER = 'https://tv.cctv.com/'

/** 栏目搜索接口 —— 拿到央视全部栏目（实测 343 个） */
const COLUMN_SEARCH = 'https://api.cntv.cn/lanmu/columnSearch'

/** 首页最多展示几个栏目区块（央视有 343 个，全放上去首页没法看） */
const HOME_COLUMN_LIMIT = 8

/** 动态栏目拉不到时的兜底（这几个是实测存活的） */
const COLUMNS_FALLBACK = [
  ['TOPC1451528971114112', '新闻联播'],
  ['TOPC1451558976694518', '焦点访谈'],
  ['TOPC1451559025546574', '动画大放映'],
]

/**
 * 直播频道表
 *
 * ⚠️ 官方 `getChannelList` 返回「拒绝访问」，故内置。
 *
 * 每项：`[直播id, EPG id, 显示名, 分组]`
 *
 * ★ `cctv9` / `cctv14` 在**直播接口里必须用别名** `cctvjilu` / `cctvchild`
 *   （实测），但 **EPG 接口用的是 `cctv9` / `cctv14`** —— 两套 id 不同，
 *   所以这张表要存两个字段。
 */
const CHANNELS = [
  ['cctv1', 'cctv1', 'CCTV-1 综合', '央视'],
  ['cctv2', 'cctv2', 'CCTV-2 财经', '央视'],
  ['cctv3', 'cctv3', 'CCTV-3 综艺', '央视'],
  ['cctv4', 'cctv4', 'CCTV-4 中文国际', '央视'],
  ['cctv5', 'cctv5', 'CCTV-5 体育', '央视'],
  ['cctv5plus', 'cctv5plus', 'CCTV-5+ 体育赛事', '央视'],
  ['cctv6', 'cctv6', 'CCTV-6 电影', '央视'],
  ['cctv7', 'cctv7', 'CCTV-7 国防军事', '央视'],
  ['cctv8', 'cctv8', 'CCTV-8 电视剧', '央视'],
  ['cctvjilu', 'cctv9', 'CCTV-9 纪录', '央视'],
  ['cctv10', 'cctv10', 'CCTV-10 科教', '央视'],
  ['cctv11', 'cctv11', 'CCTV-11 戏曲', '央视'],
  ['cctv12', 'cctv12', 'CCTV-12 社会与法', '央视'],
  ['cctv13', 'cctv13', 'CCTV-13 新闻', '央视'],
  ['cctvchild', 'cctv14', 'CCTV-14 少儿', '央视'],
  ['cctv15', 'cctv15', 'CCTV-15 音乐', '央视'],
  ['cctv16', 'cctv16', 'CCTV-16 奥林匹克', '央视'],
  ['cctv17', 'cctv17', 'CCTV-17 农业农村', '央视'],
  ['cctvamerica', 'cctvamerica', 'CCTV-4 美洲版', '国际'],
  ['cctveurope', 'cctveurope', 'CCTV-4 欧洲版', '国际'],
]

// ─────────────────────────── 工具函数 ───────────────────────────

/** 请求头（央视接口要 Referer） */
const HDRS = { Referer: REFERER }

/**
 * 发 GET 并解析 JSON
 *
 * 央视接口都是公开的，但**必须带 Referer**，否则可能返回错误页。
 */
async function getJson(url) {
  const text = await host.http.get(url, { headers: HDRS })
  if (text.startsWith('__ERR__')) throw new Error('network: ' + text.slice(7))
  try {
    return JSON.parse(text)
  } catch (e) {
    throw new Error('parse: 返回不是合法 JSON — ' + text.slice(0, 120))
  }
}

/**
 * 剥掉搜索结果标题里的 HTML 高亮标签
 *
 * ⚠️ 央视搜索返回的 `title` 形如
 * `《<font color="red">老</font><font color="red">舅</font>》霍晓阳…`
 * —— 会把命中的关键词用 `<font>` 包起来。
 * 不剥离的话界面上会出现裸 HTML。
 */
function stripHtml(raw) {
  let out = ''
  let inTag = false
  for (const ch of raw) {
    if (ch === '<') inTag = true
    else if (ch === '>') inTag = false
    else if (!inTag) out += ch
  }
  return out
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&nbsp;/g, ' ')
    .trim()
}

/**
 * 从 `imglink` 里取出 32 位十六进制的 guid
 *
 * ★ 这是一个**实测得出的简化**：央视搜索的 `imglink` 形如
 * `https://p1.img.cctvpic.com/fmspic/2026/01/28/5dbb582b20f848378a906316d212afcb-1.jpg`，
 * 其中那串 hash **就是取流接口要的 pid/guid**。
 *
 * 验证方式：拿该 hash 直接调 `getHttpVideoInfo.do?pid={hash}` → `ack: yes`，
 * 返回的 title 与搜索结果一致、hls_url 可用。
 *
 * 因此**不需要**再请求 `urllink` 那个 .shtml 页面去解析 guid
 * （省一次网络往返，也少一处解析失败点）。
 */
function guidFromImglink(imglink) {
  if (!imglink) return null
  const parts = imglink.split('/')
  const file = parts[parts.length - 1]
  const hash = (file || '').split('-')[0]
  return /^[0-9a-f]{32}$/i.test(hash) ? hash : null
}

/**
 * 从标题里解析「剧名 + 集号」
 *
 * 央视搜索的结果标题有三种形态（实测）：
 *   · **正片剧集**：`《老舅》 第5集` / `《老舅》 第27集（大结局）`
 *   · **片段/花絮**：`《老舅》霍晓阳向同学们宣传老舅生产的眼镜`
 *   · **栏目报道**：`[中国电影报道]《老舅》主演郭京飞：…`
 *
 * 只有第一种能被识别为剧集（**必须带 `第N集`**），
 * 后两种保持为独立条目 —— 否则会把花絮误并进剧集里。
 */
function parseEpisodeTitle(title) {
  const t = (title || '').trim()
  if (!t.startsWith('《')) return null
  const end = t.indexOf('》')
  if (end < 0) return null
  const brand = t.slice(1, end).trim()
  if (!brand) return null

  const after = t.slice(end + 1).trimStart()
  if (!after.startsWith('第')) return null
  const epPart = after.slice(1)
  const numEnd = epPart.indexOf('集')
  if (numEnd < 0) return null
  const ep = parseInt(epPart.slice(0, numEnd).trim(), 10)
  if (!Number.isFinite(ep) || ep <= 0) return null
  return { brand, ep }
}

/**
 * 从栏目页解析出取流用的 `TOPC` id
 *
 * 实测：栏目页（如 `tv.cctv.com/lm/xwlb/index.shtml`）里有
 * ```html
 * <script> var topicID = 'TOPC1451528971114112'; </script>
 * ```
 *
 * ⚠️ **必须精确匹配 `topicID`**，不能笼统地找 `TOPC\d+`：
 * 页面里可能出现其它形式的 TOPC 串，宽泛匹配会抓到错的
 * （第一版就是这么错的，大量栏目返回 total=0）。
 */
function parseTopicId(html) {
  const idx = html.indexOf('topicID')
  if (idx < 0) return null
  const rest = html.slice(idx)
  const eq = rest.indexOf('=')
  if (eq < 0) return null
  let s = rest.slice(eq + 1).trimStart()
  const q = s[0]
  if (q === "'" || q === '"') {
    const e = s.indexOf(q, 1)
    if (e < 0) return null
    s = s.slice(1, e)
  } else {
    const e = s.indexOf(';')
    s = e < 0 ? s : s.slice(0, e)
  }
  const id = s.trim()
  return id.startsWith('TOPC') && id.length > 4 ? id : null
}

// ─────────────────────────── 接口实现 ───────────────────────────

/** 搜索一页，返回原始 JSON */
async function searchRaw(kw, page) {
  const PAGE_SIZE = 20
  const q = encodeURIComponent(kw)
  return getJson(
    `https://search.cctv.com/ifsearch.php?page=${Math.max(1, page)}` +
      `&qtext=${q}&qtext_str=${q}&sort=relevance&pageSize=${PAGE_SIZE}` +
      `&type=video&vtime=-1&datepid=1&channel=&pageflag=0`,
  )
}

/**
 * 按剧名回搜，收集该剧的全部剧集
 *
 * 为什么用「回搜」而不是专辑接口：央视的 `getVideoListByAlbumId`
 * **实测返回「拒绝访问」**，只能反过来按剧名搜索 —— 好在剧名就在标题里。
 *
 * ⚠️ **页数不能少，也不能提前收工**：实测「老舅」全剧 27 集，
 *   逐页分布是这样的（每页 20 条，剧集与花絮混排）：
 *
 *   | 页 | 本页剧集 | 累计 |
 *   |---|---|---|
 *   | 1 | 13 集 | 13 |
 *   | 2 | 11 集 | 24 |
 *   | 3 | **0 集** | 24 |
 *   | 4 | 3 集（**含第 1 集**） | 27 |
 *
 * 两个都踩过的坑：
 *   1. 只抓 3 页 → 缺第 1 集（用户看到「从第 2 集开始」的残缺剧集）
 *   2. 「某页没有新剧集就提前收工」→ 会在**第 3 页**停下，
 *      同样漏掉第 4 页的第 1 集（这个优化是错的，已移除）
 *
 * **剧集分布是稀疏的**，不能用「本页无新集」判断后面没有了。
 */
async function albumEpisodes(brand) {
  const MAX_PAGES = 4
  const out = []
  const seen = new Set()

  for (let p = 1; p <= MAX_PAGES; p++) {
    let json
    try {
      json = await searchRaw(brand, p)
    } catch {
      continue
    }
    const list = json && json.list
    if (!Array.isArray(list)) continue

    for (const it of list) {
      const guid = guidFromImglink(it.imglink)
      if (!guid) continue
      const parsed = parseEpisodeTitle(stripHtml(it.title || ''))
      // 只收**同一部剧**的剧集：剧名必须完全一致，
      // 避免把《老舅》与《老舅的朋友》混在一起
      if (parsed && parsed.brand === brand && !seen.has(parsed.ep)) {
        seen.add(parsed.ep)
        out.push({ ep: parsed.ep, guid, cover: it.imglink })
      }
    }
  }
  return out
}

/**
 * 动态获取首页要展示的栏目
 *
 * 链路：栏目清单 → 逐个访问栏目页解析 TOPC → 只保留解析成功的。
 * 任何一步失败都退回内置表（拿不到动态数据也不该给用户空首页）。
 */
async function fetchHomeColumns() {
  const fallback = () => COLUMNS_FALLBACK.map(([id, n]) => ({ id, name: n }))

  let json
  try {
    json = await getJson(`${COLUMN_SEARCH}?&fl=&p=1&n=40&serviceId=tvcctv`)
  } catch (e) {
    host.log.warn('栏目清单拉取失败，首页退回内置栏目: ' + e.message)
    return fallback()
  }

  const docs = json && json.response && json.response.docs
  if (!Array.isArray(docs)) return fallback()

  const out = []
  for (const d of docs) {
    if (out.length >= HOME_COLUMN_LIMIT) break
    const name = d.column_name || ''
    const site = d.column_website || ''
    if (!name || !site.startsWith('http')) continue

    try {
      const html = await host.http.get(site, { headers: HDRS })
      const topic = parseTopicId(html)
      // 解析不出 topicID = 该栏目没有视频专题，跳过（不是错误）
      if (topic) out.push({ id: topic, name })
    } catch {
      // 单个栏目页失败不影响整体
    }
  }

  if (!out.length) {
    host.log.warn('所有栏目都没解析出 topicID，首页退回内置栏目')
    return fallback()
  }
  host.log.info(`首页动态获取到 ${out.length} 个栏目`)
  return out
}

/**
 * 取直播地址
 *
 * ★ 关键：`pd://` + `client=iosapp` —— 换成其它 client 会拿不到可用地址。
 *
 * 返回的 `hls_url.hls1/hls2` 是视频线路，`hls6` 是**纯音频**线路。
 *
 * ⚠️ 央视直播的视频轨有 `udrm` DRM 保护，播放器**解不出来**
 *   （实测 video 轨 61~80 个解码错误）。如实标 `drmProtected: true`，
 *   让 UI 告知用户而不是假装能播。
 *   纯音频线路实测**未加密**，是当前唯一能正常出声的选择。
 */
async function liveUrls(channelId) {
  const json = await getJson(
    `https://vdn.live.cntv.cn/api2/live.do?channel=pd://cctv_p2p_hd${channelId}&client=iosapp`,
  )
  const hls = json && json.hls_url
  const out = []

  if (hls) {
    for (const [key, label] of [
      ['hls1', '高清'],
      ['hls2', '标清'],
    ]) {
      const u = hls[key]
      // 过滤占位符（实测会返回 yangshi?group&drm=0&zbzx 这种非 http 串）
      if (typeof u === 'string' && u.startsWith('http')) {
        out.push({
          url: u,
          quality: label,
          label: label + '线路',
          kind: 'hls',
          headers: HDRS,
          drmProtected: true,
        })
      }
    }

    const audio = hls.hls6
    if (typeof audio === 'string' && audio.startsWith('http')) {
      out.push({
        url: audio,
        quality: '仅音频',
        label: '广播',
        kind: 'hls',
        headers: HDRS,
      })
    }
  }

  if (!out.length) {
    throw new Error(
      `not_found: 频道 ${channelId} 未返回可用地址（可能是 4K/8K 频道）`,
    )
  }
  return out
}

// ─────────────────────────── 插件对象 ───────────────────────────

globalThis.plugin = {
  id: 'cctv',

  capabilities: {
    vod: true,
    live: true,
    epg: true,
    timeshift: true,
    search: true,
    multiSource: true,
  },

  /**
   * 首页：动态拉取真实栏目
   *
   * 第一个区块是「正在直播」（UI 认这个 custom key），
   * 其余是央视的真实栏目。
   */
  async home() {
    const sections = [
      {
        id: 'cctv-live',
        title: '正在直播',
        source: { type: 'custom', key: 'live' },
      },
    ]

    const cols = await fetchHomeColumns()
    for (const c of cols) {
      sections.push({
        id: `cctv-col-${c.id}`,
        title: c.name,
        source: { type: 'category', categoryId: c.id },
      })
    }
    return sections
  },

  /** 分类 = 央视真实栏目（与首页同一份清单） */
  async categories() {
    const cols = await fetchHomeColumns()
    return cols.map((c) => ({ id: c.id, name: c.name, children: [] }))
  },

  /** 栏目的视频列表 */
  async list(req) {
    const PAGE_SIZE = 20
    const json = await getJson(
      `https://api.cntv.cn/NewVideo/getVideoListByColumn` +
        `?id=${encodeURIComponent(req.categoryId)}&n=${PAGE_SIZE}&p=${req.page}` +
        `&sort=desc&mode=0&serviceId=tvcctv`,
    )

    const data = json && json.data
    if (!data) {
      throw new Error('parse: 未返回 data — ' + JSON.stringify(json).slice(0, 160))
    }

    const total = data.total
    const items = []
    if (Array.isArray(data.list)) {
      for (const it of data.list) {
        const guid = it.guid || ''
        if (!guid) continue
        items.push({
          id: guid,
          title: it.title || '未知标题',
          cover: it.image,
          subtitle: it.time,
          kind: 'movie',
        })
      }
    }

    return {
      items,
      page: req.page,
      pageCount: total ? Math.ceil(total / PAGE_SIZE) : undefined,
      total,
    }
  },

  /**
   * 搜索
   *
   * # 这里曾经是错的
   *
   * 原先 manifest 写着 `search: false`，注释是「无公开 JSON 搜索接口」——
   * **当时只试了一个域名就下了结论**。实际上 `search.cctv.com`
   * 有可用的 JSON 接口（实测搜「老舅」返回 total: 348）。
   *
   * # 两个要点
   *
   * 1. `title` 含 `<font color="red">` 高亮标签 → 必须剥离
   * 2. `imglink` 里的 32 位 hash **就是取流要的 guid**
   *
   * # 剧集聚合
   *
   * 正片剧集（`《老舅》 第5集`）不直接进列表，而是按剧名分组，
   * 最后收敛成**一个条目**（显示「全 N 集」）—— 否则搜一部剧
   * 会出现几十条几乎同名的记录。
   */
  async search(keyword, page) {
    const kw = (keyword || '').trim()
    if (!kw) return { items: [], page: 1 }

    const PAGE_SIZE = 20
    const p = Math.max(1, page)
    const first = await searchRaw(kw, p)
    const total = first.total

    const loose = []
    /** 剧名 → [{ep, guid, cover, title}] */
    const albums = new Map()

    const consume = (list) => {
      if (!Array.isArray(list)) return
      for (const it of list) {
        // guid 优先从 imglink 推；推不出来就跳过 ——
        // 没有 guid 就无法取流，列出来点了也播不了
        const guid = guidFromImglink(it.imglink)
        if (!guid) continue

        const title = stripHtml(it.title || '') || '未知标题'
        const channel = it.channel

        // ★ 正片剧集 → 归入剧名分组（不直接进结果列表）
        const parsed = parseEpisodeTitle(title)
        if (parsed) {
          if (!albums.has(parsed.brand)) albums.set(parsed.brand, [])
          albums.get(parsed.brand).push({
            ep: parsed.ep,
            guid,
            cover: it.imglink,
            title,
          })
          continue
        }

        // durations 是**秒**（实测 38 / 60 / 120），不是毫秒
        const dur = it.durations
        const subtitle =
          typeof dur === 'number'
            ? `${Math.floor(dur / 60)}:${String(dur % 60).padStart(2, '0')}`
            : channel

        loose.push({
          id: guid,
          title,
          cover: it.imglink,
          subtitle,
          badges: channel ? [channel] : [],
          kind: 'movie',
        })
      }
    }

    consume(first.list)

    /*
     * ★ 发现剧集后再补抓几页，把整部剧凑齐。
     *
     * 为什么必须补抓：实测「老舅」全剧 27 集，但**一页只有 20 条**，
     * 且首页里混着花絮与报道 —— 只取一页只能凑到十几集。
     *
     * ⚠️ **必须与 albumEpisodes() 抓同样多的页数**（那里是 4 页）。
     *    曾经这里只补 2 页 → 列表页显示「全 24 集」，
     *    而详情页显示 27 集 —— **同一部剧两个数字**（实测发现的不一致）。
     */
    if (albums.size) {
      const SEARCH_MAX_PAGES = 4
      for (let np = p + 1; np <= SEARCH_MAX_PAGES; np++) {
        try {
          const next = await searchRaw(kw, np)
          consume(next.list)
        } catch {
          // 补抓失败不影响主流程（剧集不全总比搜索报错好）
        }
      }
    }

    // ★ 把剧集分组收敛成单个条目
    const items = []
    for (const [brand, eps] of albums) {
      const uniq = new Map()
      for (const e of eps) if (!uniq.has(e.ep)) uniq.set(e.ep, e)
      const sorted = [...uniq.values()].sort((a, b) => a.ep - b.ep)

      const firstEp = sorted[0]
      const lastEp = sorted[sorted.length - 1]
      // 只找到一集的不算剧（可能是标题恰好像「第N集」的单条）
      if (sorted.length < 2) {
        loose.push({
          id: firstEp.guid,
          title: firstEp.title,
          cover: firstEp.cover,
          kind: 'movie',
        })
        continue
      }

      items.push({
        id: firstEp.guid,
        title: brand,
        cover: firstEp.cover,
        // 集号可能不从 1 开始（实测有「第2–27集」的情况），如实显示
        subtitle:
          firstEp.ep === 1
            ? `全 ${sorted.length} 集`
            : `全 ${sorted.length} 集（第${firstEp.ep}–${lastEp.ep}集）`,
        kind: 'series',
      })
    }

    // 聚合条目排前面（更像"作品"），散条在后
    items.push(...loose)

    return {
      items,
      page: p,
      pageCount: total ? Math.ceil(total / PAGE_SIZE) : undefined,
      total,
    }
  },

  /**
   * 详情
   *
   * 除基本信息外，还要展开剧集 —— 电视剧是多集的，
   * 若不展开，用户点进《老舅》只能看到「一集」，无法选其他集。
   */
  async detail(id) {
    const guid = id
    let json = null
    // 官方接口失败不致命 —— guid 仍可直接拼流
    try {
      json = await getJson(
        `https://vdn.apps.cntv.cn/api/getHttpVideoInfo.do?pid=${guid}&client=flash`,
      )
    } catch {
      json = null
    }

    let title = guid
    let cover
    let description
    const meta = {}

    if (json && json.ack === 'yes') {
      title = json.title || title
      cover = json.image
      description = json.tag

      if (json.column) meta.column = json.column
      if (json.play_channel) meta.playChannel = json.play_channel
      if (json.editor) meta.editor = json.editor
      const totalLength = json.video && json.video.totalLength
      if (totalLength) meta.duration = totalLength
    }

    // ★ 多清晰度候选（实测 2000/1200/850/450 可用，270 不可用）
    const sources = []
    if (json && typeof json.hls_url === 'string' && json.hls_url.startsWith('http')) {
      sources.push({ code: 'official', title: '官方 HLS', count: 1 })
    }
    sources.push({ code: 'cdn', title: 'CDN 直连', count: 4 })

    // ★ 剧集展开（用剧名回搜，见 albumEpisodes 的说明）
    let episodes = []
    const parsed = parseEpisodeTitle(title)
    if (parsed) {
      const found = await albumEpisodes(parsed.brand)
      found.sort((a, b) => a.ep - b.ep)
      episodes = found.map((f) => ({
        id: f.guid,
        title: `第${f.ep}集`,
        order: f.ep,
      }))
    }

    return {
      id: guid,
      title,
      cover,
      description,
      kind: episodes.length > 1 ? 'series' : 'movie',
      meta: Object.keys(meta).length ? meta : undefined,
      sources,
      episodes,
    }
  },

  /**
   * 取流
   *
   * ★★ **直播频道必须先分流**
   *
   * 实测：直播频道的 id（`cctv1`…）与点播 guid（32 位十六进制）完全不同，
   * 但前端两个入口都可能调到这里。若不分流，直播会被套进下面的
   * **点播 CDN 模板**，拼出
   * `https://hls.cntv.lxdns.com/asp/hls/2000/.../cctv1/2000.m3u8` ——
   * 该地址**返回 404**（央视已把直播迁到阿里云 CDN），
   * 表现为「直播一直转圈、无错误提示」（实测踩到）。
   */
  async resolve(id, req) {
    const guid = id
    const sourceCode = req && req.sourceCode

    if (CHANNELS.some(([cid]) => cid === guid)) {
      return liveUrls(guid)
    }

    const out = []

    // 官方 HLS 优先（若源指定或未指定）
    if (sourceCode !== 'cdn') {
      try {
        const j = await getJson(
          `https://vdn.apps.cntv.cn/api/getHttpVideoInfo.do?pid=${guid}&client=flash`,
        )
        const u = j && j.hls_url
        if (typeof u === 'string' && u.startsWith('http')) {
          out.push({
            url: u.split('?')[0],
            quality: '自适应',
            label: '官方 HLS',
            kind: 'hls',
            headers: HDRS,
          })
        }
      } catch {
        // 官方接口失败不致命，下面还有 CDN 直连
      }
    }

    // CDN 直连多档
    if (sourceCode !== 'official') {
      for (const [br, label] of [
        ['2000', '超清 2000k'],
        ['1200', '高清 1200k'],
        ['850', '标清 850k'],
        ['450', '流畅 450k'],
      ]) {
        out.push({
          url: `https://hls.cntv.lxdns.com/asp/hls/${br}/0303000a/3/default/${guid}/${br}.m3u8`,
          quality: label,
          label: 'CDN 直连',
          kind: 'hls',
          headers: HDRS,
        })
      }
    }

    if (!out.length) throw new Error('not_found: 未解析出播放地址')
    return out
  },

  /** 直播频道列表 */
  async liveChannels() {
    return CHANNELS.map(([id, , name, group]) => ({
      id,
      name,
      group,
    }))
  },

  /** 直播取流（前端直播页直接调这个） */
  async liveStream(channelId) {
    return liveUrls(channelId)
  },

  /**
   * 节目单
   *
   * ⚠️ `channel_id` 可能是**直播 id**（`cctvjilu`），
   *    而 EPG 接口要的是 **EPG id**（`cctv9`）—— 必须转换。
   */
  async epg(channelId) {
    const found = CHANNELS.find(([id]) => id === channelId)
    const epgId = found ? found[1] : channelId

    const json = await getJson(
      `https://api.cntv.cn/epg/epginfo3?serviceId=shiyi&c=${epgId}`,
    )
    const node = json && json[epgId]
    if (!node) throw new Error(`parse: EPG 无 ${epgId} 数据`)

    const out = []
    if (Array.isArray(node.program)) {
      for (const p of node.program) {
        const start = p.st || 0
        const end = p.et || 0
        out.push({
          title: p.t || '未知节目',
          start,
          end,
          showTime: p.showTime,
          duration: p.duration || 0,
          // 实测：回看 = 直播地址 + 时间区间，故均可回看
          replayable: start > 0 && end > start,
        })
      }
    }
    return out
  },

  /**
   * 时移回看
   *
   * ★ 实测：`begintimeabs` / `endtimeabs` 为**毫秒**（不是秒）。
   */
  async timeshift(channelId, start, end) {
    const live = await liveUrls(channelId)
    const base = live[0].url.split('?')[0]
    return {
      url: `${base}?begintimeabs=${start * 1000}&endtimeabs=${end * 1000}`,
      quality: '回看',
      label: '时移回看',
      kind: 'hls',
      headers: HDRS,
    }
  },
}
