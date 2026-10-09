/**
 * @id          cycani
 * @name        次元城动画
 * @version     1.0.0
 * @author      dsh
 * @description 次元城动画 —— 点播、搜索、榜单、平台历史
 * @homepage    https://www.cycani.org
 *
 * ═══════════════════════════════════════════════════════════════
 *  本插件是 `src-tauri/src/providers/cycani.rs` 的外置版本。
 *
 *  ⚠️ 与央视不同，这个源**需要登录**才能取流：
 *     · 登录后 token 存进 host.store（插件私有，别的插件看不到）
 *     · 取流走 `/v2/sections/{id}/play-url`，**必须带 Authorization**
 *     · 返回的是**签名直链**（expires + md5），会过期，不可缓存
 * ═══════════════════════════════════════════════════════════════
 */

const BASE = 'https://www.cycani.org/api'
const REFERER = 'https://www.cycani.org/'

/** 接口单页上限（官方实测值） */
const MAX_PAGE_SIZE = 20

/**
 * 基础请求头
 *
 * ★ 这四个头是**站点识别客户端**用的，缺了会被拒或返回异常数据。
 *   实测：只带 User-Agent 会被当成未知客户端。
 */
const BASE_HEADERS = {
  'X-App-Name': 'cyc_web',
  'X-App-Version': 'cycweb',
  'X-Time-Zone': 'Asia/Shanghai',
  Accept: 'application/json',
  Referer: REFERER,
}

/** token 在插件私有存储里的键名 */
const TOKEN_KEY = 'session'
/**
 * 凭据在插件私有存储里的键名
 *
 * ★ 为什么要存凭据（而不是只存 token）
 *
 * Owner 报「登录失效，像这种没有验证码的，应该自动重登」——
 * 次元城登录**没有验证码**，只要账号密码还在就能直接重新登录。
 * 只存 token 的话，token 一过期用户就得手动重登，很烦。
 *
 * 存哪：插件私有存储（`plugins/.data/cycani.json`），
 * 与应用级钥匙串分开 —— 它是插件自己的凭据。
 */
const CRED_KEY = 'credentials'

// ─────────────────────────── 工具 ───────────────────────────

/**
 * 规范化令牌：**已有 `Bearer ` 前缀就不再加**
 *
 * ⚠️ 实测坑：登录接口返回的 `token` 字段**已经包含** `Bearer ` 前缀。
 *   若再拼一次会变成 `Bearer Bearer xxx`，服务端返回 401，
 *   而错误信息完全看不出是前缀重复导致的。
 *   （官方 bundle 里的 `p2()` 就是做这个兼容的。）
 */
function normalizeToken(raw) {
  const t = String(raw || '').trim()
  return /^Bearer\s+/i.test(t) ? t : 'Bearer ' + t
}

/** 读取已保存的 token（未登录返回 null） */
function token() {
  const raw = host.store.get(TOKEN_KEY)
  if (!raw) return null
  try {
    const s = JSON.parse(raw)
    return s && s.token ? normalizeToken(s.token) : null
  } catch {
    return null
  }
}

/**
 * 发请求并解包 `{code, msg, data}` 信封
 *
 * ★ 官方所有接口都套这一层信封，且 **`code !== 0` 就是失败**
 *   （HTTP 仍是 200）。只看 HTTP 状态会把错误当成功，
 *   然后在后面某处莫名其妙地崩掉。
 */
async function api(method, path, opts = {}) {
  const url = BASE + path
  const headers = Object.assign({}, BASE_HEADERS, opts.headers || {})

  if (opts.auth) {
    const t = token()
    if (!t) {
      throw new Error('unauthorized: 次元城需要登录后才能播放，请先在设置页登录')
    }
    headers.Authorization = t
  }

  const text =
    method === 'POST'
      ? await host.http.post(url, opts.body == null ? '' : JSON.stringify(opts.body), { headers })
      : await host.http.get(url, { headers })

  if (text.startsWith('__ERR__')) {
    const detail = text.slice(7)
    // 401 要转成 unauthorized，宿主才会触发续期/重新登录
    if (/\b401\b/.test(detail)) {
      throw new Error('unauthorized: 登录已失效（' + detail + '）')
    }
    throw new Error('network: ' + detail)
  }

  let json
  try {
    json = JSON.parse(text)
  } catch {
    throw new Error('parse: 返回不是合法 JSON — ' + text.slice(0, 120))
  }

  if (typeof json.code === 'number' && json.code !== 0) {
    const msg = json.msg || '未知错误'
    if (json.code === 401) throw new Error('unauthorized: ' + msg)
    throw new Error(msg)
  }

  return json.data === undefined ? null : json.data
}

const get = (path, auth = false) => api('GET', path, { auth })
const post = (path, body, auth = false) => api('POST', path, { body, auth })

/** 列表接口统一是 `{list, pager:{total}}`，这里抽出来 */
function unpackPage(data) {
  if (!data) return { items: [], total: undefined }
  const items = Array.isArray(data.list) ? data.list : Array.isArray(data) ? data : []
  const total = data.pager && typeof data.pager.total === 'number' ? data.pager.total : undefined
  return { items, total }
}

/**
 * 列表项 → 手机/前端认识的条目
 *
 * ⚠️ `remarks` 形如 `"11|周一20:35后"`，取 `|` **后面**那段更有信息量
 *   （前面那个数字是「更新到第几集」，与 badges 重复）。
 */
function toItem(it) {
  const id = it.video_id != null ? it.video_id : it.id
  if (id == null) return null

  const badges = []
  if (typeof it.total === 'number' && it.total > 0) badges.push(`全 ${it.total} 集`)
  if (typeof it.score === 'number' && it.score > 0) badges.push(`${it.score.toFixed(1)} 分`)

  let subtitle
  if (typeof it.remarks === 'string' && it.remarks) {
    const parts = it.remarks.split('|')
    subtitle = parts[parts.length - 1]
  }

  return {
    id: String(id),
    title: it.title || '未知标题',
    cover: it.cover_url || undefined,
    subtitle,
    badges,
    kind: 'series',
  }
}

// ─────────────────────────── 登录 ───────────────────────────

/**
 * 登录并保存会话
 *
 * 返回的 `token` 已含 `Bearer ` 前缀（见 `normalizeToken` 的说明）。
 * 存进 `host.store`（插件私有）—— 别的插件读不到，
 * 也不占用应用的系统钥匙串条目。
 */
async function login(username, password) {
  const data = await post('/auth/login', { username, password })
  if (!data || !data.token) {
    throw new Error('parse: 登录响应缺少 token')
  }

  const session = {
    token: data.token,
    expiresAt: data.expires_at || null,
    displayName: (data.user && (data.user.nickname || data.user.username)) || username,
    avatar: (data.user && data.user.avatar_url) || null,
  }
  host.store.set(TOKEN_KEY, JSON.stringify(session))

  /*
   * ★ 同时保存凭据，供 token 过期后**自动重新登录**
   *
   * 次元城登录没有验证码，凭据在就能直接重登。
   * 这样用户不会遇到「看着看着提示登录失效」的打断。
   */
  host.store.set(CRED_KEY, JSON.stringify({ username, password }))

  return {
    token: session.token,
    expiresAt: session.expiresAt ? Math.floor(new Date(session.expiresAt).getTime() / 1000) : undefined,
    displayName: session.displayName,
    avatar: session.avatar,
  }
}

/** 读已保存的凭据（没有返回 null） */
function credentials() {
  const raw = host.store.get(CRED_KEY)
  if (!raw) return null
  try {
    const c = JSON.parse(raw)
    return c && c.username ? c : null
  } catch {
    return null
  }
}

/** 用现有 token 续期 */
async function refreshSession() {
  const raw = host.store.get(TOKEN_KEY)
  if (!raw) return null
  try {
    const data = await post('/auth/refresh', null, true)
    if (!data || !data.token) return null
    const s = JSON.parse(raw)
    s.token = data.token
    if (data.expires_at) s.expiresAt = data.expires_at
    host.store.set(TOKEN_KEY, JSON.stringify(s))
    return {
      token: s.token,
      expiresAt: s.expiresAt ? Math.floor(new Date(s.expiresAt).getTime() / 1000) : undefined,
      displayName: s.displayName,
      avatar: s.avatar,
    }
  } catch {
    return null
  }
}

// ─────────────────────────── 插件对象 ───────────────────────────

globalThis.plugin = {
  id: 'cycani',

  capabilities: {
    vod: true,
    search: true,
    // ★ 需要登录才能取流 —— 界面据此显示登录入口
    loginRequired: true,
    /*
     * ★★ 声明「能用保存的凭据自动重登」（2026-09-25，task-38）
     *
     * # 为什么必须声明（不声明就等于没做这个功能）
     *
     * 下面是本插件**真的有**的能力（`canAutoLogin()` / `autoLogin()` 都实现了），
     * 但那是**运行时方法**；宿主选「登录失效」的文案时需要的是
     * **声明式能力位**（它不该为了选一句话去跑一次插件）。
     *
     * ⚠️ 漏了这一行的表现（实测过）：
     * ```text
     * 插件明明能自动重登，设置页却仍然写
     * 「需重新登录（可能需要验证码，请手动完成）」
     * ⇒ Owner 报的那个 bug **原封不动地回来**，而且不报任何错
     * ```
     */
    canAutoLogin: true,
    multiSource: true,
    serverSideHistory: true,
    favorites: true,
  },

  // ── 登录相关 ──

  login,

  /**
   * 登出
   *
   * ⚠️ 这里**只清 token、保留凭据** —— 这样下次还能自动重登。
   *   用户若想「彻底不再自动登录」，用下面的 `forgetCredentials()`。
   *   两者分开是必要的：否则用户每次登出都会失去自动重登能力，
   *   而「登出」在多数人心里只是「换个账号试试」。
   */
  async logout() {
    host.store.remove(TOKEN_KEY)
  },

  /** ★ 彻底忘记凭据（登出且不再自动登录） */
  async forgetCredentials() {
    host.store.remove(TOKEN_KEY)
    host.store.remove(CRED_KEY)
  },

  async session() {
    const raw = host.store.get(TOKEN_KEY)
    if (!raw) return null
    try {
      const s = JSON.parse(raw)
      return {
        token: s.token,
        expiresAt: s.expiresAt ? Math.floor(new Date(s.expiresAt).getTime() / 1000) : undefined,
        displayName: s.displayName,
        avatar: s.avatar,
      }
    } catch {
      return null
    }
  },

  refreshSession,

  /**
   * ★ 能否自动登录
   *
   * 判据：**凭据还在**就能。次元城登录没有验证码，
   * 账号密码有效就能直接换新 token。
   *
   * 宿主在「token 过期且续期失败」时会问这个 ——
   * 返回 true 才会去调 `autoLogin()`。
   */
  async canAutoLogin() {
    return credentials() !== null
  },

  /**
   * ★ 用已保存的凭据自动重新登录
   *
   * Owner 报「登录失效，像这种没有验证码的，应该自动重登」——
   * 这个方法是那条需求的落地。
   *
   * 失败时**如实抛错**（密码改了、账号被风控…），
   * 宿主会把状态置为 `expired` 并让 UI 提示人工登录。
   * **绝不要在这里假装成功** —— 那样用户会看到「已登录」
   * 但点播放又报未登录，更困惑。
   */
  async autoLogin() {
    const c = credentials()
    if (!c) return null
    try {
      host.log.info('token 已失效，用保存的凭据自动重新登录')
      return await login(c.username, c.password)
    } catch (e) {
      host.log.warn('自动重新登录失败（可能需要人工登录）: ' + e.message)
      throw e
    }
  },

  // ── 内容发现 ──

  /**
   * 首页分区
   *
   * 两个榜单 + 两个分区最新 —— 都是**动态拉取**的，
   * 不像央视那样需要解析页面。
   */
  async home() {
    const sections = []

    // 1) 榜单（每周更新，实测有真实数据）
    try {
      const data = await get('/ranks')
      const ranks = (data && data.list) || []
      for (const r of ranks.slice(0, 2)) {
        if (r.id == null) continue
        sections.push({
          id: `cycani-rank-${r.id}`,
          title: r.name ? `${r.name}榜` : '榜单',
          source: { type: 'rank', rankId: String(r.id) },
        })
      }
    } catch (e) {
      host.log.warn('榜单拉取失败: ' + e.message)
    }

    // 2) 分区最新
    try {
      const data = await get('/video-zones')
      const zones = (data && data.list) || []
      for (const z of zones.slice(0, 2)) {
        if (z.id == null) continue
        sections.push({
          id: `cycani-zone-${z.id}`,
          title: `${z.name || '分区'} · 最近更新`,
          source: { type: 'category', categoryId: String(z.id) },
        })
      }
    } catch (e) {
      host.log.warn('分区拉取失败: ' + e.message)
    }

    return sections
  },

  /** 分类 = 分区（浏览页左侧） */
  async categories() {
    const data = await get('/video-zones')
    const zones = (data && data.list) || []
    return zones.map((z) => ({
      id: String(z.id),
      name: z.name || '未命名',
      children: [],
    }))
  },

  /**
   * 分类内容
   *
   * 第一道筛是 zone_id，其余（题材/年份/排序）走 filters。
   */
  async list(req) {
    const page = Math.max(1, req.page || 1)
    const f = req.filters || {}
    const orderBy = f.order_by || 'update_time'

    let path = `/videos?page=${page}&page_size=${MAX_PAGE_SIZE}&order_by=${encodeURIComponent(orderBy)}`
    const zoneId = (req.categoryId || '').trim()
    if (zoneId) path += `&zone_id=${encodeURIComponent(zoneId)}`
    if (f.tag) path += `&tag=${encodeURIComponent(f.tag)}`
    if (f.year) path += `&year=${encodeURIComponent(f.year)}`

    const { items, total } = unpackPage(await get(path))
    return {
      items: items.map(toItem).filter(Boolean),
      page,
      pageCount: total ? Math.ceil(total / MAX_PAGE_SIZE) : undefined,
      total,
    }
  },

  /**
   * 榜单内容
   *
   * ⚠️ 官方此接口**不分页**（一次返回该榜单全部），
   *   所以第 2 页起直接返回空，避免前端无限翻页。
   */
  async rank(rankId, page) {
    if (page > 1) {
      return { items: [], page, pageCount: 1 }
    }
    const data = await get(`/ranks/${encodeURIComponent(rankId)}/videos`)
    // 实测结构是 {list:[...]}；兼容直接给数组
    const arr = (data && data.list) || (Array.isArray(data) ? data : [])
    const items = arr.map(toItem).filter(Boolean)
    return { items, page: 1, pageCount: 1, total: items.length }
  },

  /**
   * 搜索
   *
   * ★ 参数名是 **`q`** —— 用 `keyword` / `wd` 会 400
   *   （报 `Q is a required field`）。
   */
  async search(keyword, page) {
    const kw = (keyword || '').trim()
    if (!kw) return { items: [], page: 1 }

    const p = Math.max(1, page)
    const path = `/videos/search?q=${encodeURIComponent(kw)}&page=${p}&page_size=${MAX_PAGE_SIZE}`
    const { items, total } = unpackPage(await get(path))
    return {
      items: items.map(toItem).filter(Boolean),
      page: p,
      pageCount: total ? Math.ceil(total / MAX_PAGE_SIZE) : undefined,
      total,
    }
  },

  /**
   * 详情
   *
   * 除基本信息外要展开剧集 —— 不展开的话用户点进来只有「一集」，
   * 无法选其他集。
   */
  async detail(id) {
    const data = await get(`/videos/${encodeURIComponent(id)}`)
    if (!data) throw new Error('not_found: 作品不存在')

    const meta = {}
    for (const k of ['year', 'score', 'area', 'total', 'version', 'subtitle']) {
      if (data[k] !== undefined && data[k] !== null) meta[k] = String(data[k])
    }
    if (Array.isArray(data.tags)) meta.tags = data.tags.join(' / ')

    // ★ play_from 是数组 [{code,title,count}]，按列表渲染（不写死单源）
    const sources = (Array.isArray(data.play_from) ? data.play_from : [])
      .filter((s) => s && s.code)
      .map((s) => ({
        code: String(s.code),
        title: s.title || String(s.code),
        count: typeof s.count === 'number' ? s.count : 0,
      }))

    // 默认拉第一个源的剧集
    let episodes = []
    if (sources.length) {
      episodes = await episodesOf(id, sources[0].code)
    }

    /*
     * ★ 角标要如实反映「能看几集」
     *
     * 实测坑：连载番组 `total` 是**全季预定集数**（如 12），
     * 而接口实际只返回已播的 10 集（`remarks` 形如 "10|周六25:05后"）。
     * 直接显示「全 12 集」会与下方只有 10 个选集按钮**自相矛盾**，
     * 用户会以为丢了 2 集。
     */
    const declared = typeof data.total === 'number' ? data.total : 0
    const available = episodes.length
    const completed = data.completed === true

    /*
     * ★★★ 2026-10-09（Owner 第三批 ①）：已完结却标「正在更新」
     *
     * Owner 原话：
     * > 次元城这个明明是已完结,但是这里还是标示 正在更新
     * （截图副标题「更新至 14 集」，角标「更新至 14 集 / 8 分 / 14 集」）
     *
     * # 真网络取证（.probe/cycani_auth_probe.cjs，登录态，2026-10-09）
     * ```text
     * id=3862「无职转生 第三季」  total=14 available=14 completed=false  => 更新至 14 集  ← 用户看到的现象
     * id=1013「小书痴的下克上」  total=14 available=14 completed=true   => 全 14 集
     * id=242 「CLANNAD AS」     total=24 available=25 completed=true   => 全 24 集
     * ```
     * ⇒ 接口的 `completed` **本身是可靠的**（抽样 32 条里 30 条给了 true，
     *   且 true/false 与 remarks 是否为空一致）。问题出在**判据只看它一个**：
     * ```text
     * 3862 是**当季在播**（weekday=7，2026 年 10 月）且 `total` 是**预先声明的全季集数**，
     * 而源站已把 14 集**全部**放出来了。此时 declared(14) === available(14)
     * 却因为还在播 ⇒ 站方不会把 completed 置 true。
     * 旧判据落到最后一支 `available > 0` ⇒ 「更新至 14 集」——
     * 但既然 14 集全都在了，对用户而言**这一季就是齐的**。
     * ```
     *
     * # 两级判定（completed 优先，自洽信号兜底）
     * ```text
     * ① completed === true            ⇒ 一定完结（站方权威）
     * ② declared > 0 && available >= declared ⇒ **自洽推断**完结
     *    （「声明的集数都已经拿到了」——这不依赖站方是否更新 completed 字段）
     * ```
     * ⚠️ `available >= declared` 而不是 `===`：实测 id=242 的 available(25)
     *    比 declared(24) 还多（多了 OVA），用 `===` 会漏判。
     */
    const selfConsistentComplete = declared > 0 && available >= declared
    const isComplete = completed || selfConsistentComplete

    /*
     * ⚠️ 两个信号结论不同时必须**留下日志**（task-10 明确要求「不要静默改」）
     *
     * 为什么：下次接口又变时（字段改名 / 不再给 total / completed 语义漂移），
     * 只看最终角标是看不出**是哪个信号变了**的。把两个读数都印出来，
     * 一眼就能定位。级别用 debug —— 它只在排查时开。
     */
    if (completed !== selfConsistentComplete) {
      host.log.debug(
        `[cycani] ${id} 完结判据不一致：completed=${completed} ` +
          `declared=${declared} available=${available} ` +
          `=> 采用 ${isComplete ? '完结' : '连载'}（自洽信号${selfConsistentComplete ? '成立' : '不成立'}）`,
      )
    }

    const badges = []
    if (declared > 0) {
      if (isComplete) {
        badges.push(`全 ${declared} 集`)
      } else if (available > 0 && available !== declared) {
        badges.push(`更新至 ${available} 集（预定 ${declared} 集）`)
      } else if (available > 0) {
        badges.push(`更新至 ${available} 集`)
      } else {
        badges.push(`预定 ${declared} 集`)
      }
    }
    if (meta.score) badges.push(`${meta.score} 分`)

    return {
      id: String(id),
      title: data.title || String(id),
      cover: data.cover_url || undefined,
      description: (data.description || '').trim() || undefined,
      badges,
      kind: 'series',
      meta: Object.keys(meta).length ? meta : undefined,
      sources,
      episodes,
    }
  },

  /** 按播放源取剧集 */
  async episodes(id, sourceCode) {
    return episodesOf(id, sourceCode)
  },

  /**
   * 取流
   *
   * ★ 两条硬规则（都是实测踩出来的）：
   *
   * 1. **必须带 `episodeId`** —— 取流接口是按「集 id」给的，
   *    没有集 id 就取不到。没传时退回第一集（比报错友好）。
   *
   * 2. **`quality` 不能用响应里的 `name`** ——
   *    该字段是**剧集名**（如「第01集」）而不是画质。
   *    原先拿它当 quality，播放页会出现「第01集　第01集」
   *    （左边剧集名、右边"线路名"），用户完全看不出右边想表达什么。
   *    该站只有**单一画质**，所以给一个如实的中性名，
   *    而不是编造假的画质档位。
   */
  async resolve(id, req) {
    const r = req || {}
    let sectionId = r.episodeId

    if (!sectionId) {
      // 没指定集 → 用第一集（更符合直觉，也比报错友好）
      const eps = r.sourceCode
        ? await episodesOf(id, r.sourceCode)
        : (await this.detail(id)).episodes
      if (!eps.length) throw new Error('not_found: 该作品没有可播放的剧集')
      sectionId = eps[0].id
    }

    // 需要登录（未登录会抛 unauthorized，宿主会引导去登录）
    const data = await get(
      `/v2/sections/${encodeURIComponent(sectionId)}/play-url`,
      true,
    )
    const url = data && data.url
    if (!url) throw new Error('parse: 取流响应缺少 url')

    /*
     * ⚠️ kind 按 URL 推断而**不硬编码 mp4**：
     *   该站把 MP4 伪装成 `.mp3`、且地址可能不带扩展名，
     *   硬编码会在将来接入 m3u8 内容时出错。
     */
    const lower = url.toLowerCase()
    let kind = 'other'
    if (lower.includes('.m3u8')) kind = 'hls'
    else if (lower.includes('.mp4') || lower.includes('.mp3')) kind = 'mp4'
    else if (lower.includes('.flv')) kind = 'flv'

    /*
     * ★★★ 必须声明请求头 + `notWebReady`，让宿主**走本地代理**
     *
     * # 上一版错在哪（2026-09-20 实测定位）
     *
     * 原来这里写的是：
     * ```text
     * // 签名直链（expires+md5）自带鉴权，实测无防盗链，无需额外请求头
     * return [{ url, quality: '原画', label: '次元城', kind }]
     * ```
     * 那句"无需额外请求头"**只对"能不能取到字节"成立**，
     * 但漏掉了**浏览器能不能播**这一层。
     *
     * # 实测的完整证据链
     *
     * ```text
     * ① 该 CDN 响应头里**没有 Access-Control-Allow-Origin**（实测）
     * ② 于是 <video> 直接加载这个跨域地址 → stalled，readyState=0
     *    （用一个裸 video 元素喂同一个地址复现，154 的地址则 readyState=4）
     * ③ 而 fetch 能拿到 206 —— 所以"取得到字节"不等于"播得了"
     * ```
     *
     * # 为什么声明 headers 就能修好
     *
     * 宿主的规则（`lib.rs` 的 resolve_stream + `streamproxy.rs::maybe_proxy`）：
     * ```text
     * not_web_ready && !headers.is_empty()  →  换成 http://127.0.0.1:port/s/…
     * ```
     * 代理地址是**同源**的（127.0.0.1），所以不存在跨域问题 ——
     * 这也正是 154 / 360 / api-* 那些采集站能播、而次元城不能播的原因。
     *
     * ⚠️ 两个字段**必须一起给**：只给 headers 不给 notWebReady 不会走代理
     *    （`maybe_proxy` 第一行就 `if !not_web_ready || headers.is_empty() return None`）。
     *
     * ⚠️ `Referer` 不能省：实测该 CDN 对**不带 UA** 的请求直接拒连
     *    （curl 无 UA → HTTP 000，带 UA → 206）。
     *    代理会把这些头原样转发，所以在这里给全。
     */
    const PLAY_HDRS = [
      ['User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'],
      ['Referer', 'https://www.cycani.com/'],
      ['Accept', '*/*'],
      ['Accept-Language', 'zh-CN,zh;q=0.9'],
    ]

    return [{
      url,
      quality: '原画',
      label: '次元城',
      kind,
      headers: PLAY_HDRS,
      notWebReady: true,
    }]
  },

  /**
   * 平台自带观看历史（备份平面，只读镜像）
   *
   * 用途：把站点侧的历史拉过来做备份 —— 换设备时不会丢进度。
   */
  async serverHistory() {
    const data = await get('/user/histories?page_size=100', true)
    const arr = (data && data.list) || []
    return arr.map((h) => ({
      videoId: String(h.video_id != null ? h.video_id : h.id),
      title: h.title || '',
      cover: h.cover_url || undefined,
      episodeTitle: h.section_title || undefined,
      position: typeof h.position === 'number' ? h.position : undefined,
      updatedAt: h.updated_at || undefined,
    }))
  },
}

/** 按播放源取剧集（detail 与 resolve 共用） */
async function episodesOf(id, sourceCode) {
  const path = `/videos/${encodeURIComponent(id)}/sections?player_code=${encodeURIComponent(
    sourceCode || '',
  )}&page=1&page_size=${MAX_PAGE_SIZE}`
  const { items } = unpackPage(await get(path))

  return items
    .map((s, i) => {
      if (s.id == null) return null
      return {
        id: String(s.id),
        title: s.title || `第${String(i + 1).padStart(2, '0')}集`,
        // 官方列表不带 order，用下标兜底
        order: typeof s.order === 'number' ? s.order : i + 1,
      }
    })
    .filter(Boolean)
}
