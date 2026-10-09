/**
 * @id          demo
 * @name        示例源
 * @version     1.0.0
 * @author      dsh
 * @description 最小可运行的插件示例 —— 照着它写你自己的源
 * @homepage    https://example.com
 *
 * ═══════════════════════════════════════════════════════════════
 *  这是随程序发布的最小 demo，**它真的能跑**（不是伪代码）。
 *
 *  写插件只需要三步：
 *    1. 头部注释声明元信息（@id 和 @name 必填）
 *    2. 给 globalThis.plugin 赋一个对象
 *    3. 实现你支持的方法（用不到的不用写）
 *
 *  完整契约见 plugins/README.md（若仓库未附该文件，见
 *  `.github/release-notes.md` 的「插件」一节）
 * ═══════════════════════════════════════════════════════════════
 */

/*
 * 宿主注入的 API（不用 import，直接用）：
 *
 *   host.http.get(url, opts)        → Promise<string>  发 GET，返回响应文本
 *   host.http.post(url, body, opts) → Promise<string>  发 POST
 *   host.log.info/warn/error()      → 打日志（带插件 id 前缀）
 *   host.util.urlEncode / urlDecode / sleep
 *
 * ⚠️ host.http **不抛异常**：网络失败时它返回以 `__ERR__` 开头的字符串。
 *    所以**必须**用下面这个 getJson() 包一层 ——
 *    直接 `JSON.parse(resp)` 会得到 `unexpected token: '__ERR__'`
 *    这种毫无意义的报错（实测踩过：demo 指向不存在的域名时，
 *    报错信息完全看不出是网络问题）。
 */

const API = 'https://api.example.com'

/** 请求头（很多站点要 Referer，缺了会返回错误页） */
const HDRS = { Referer: 'https://example.com/' }

/**
 * 发 GET 并解析 JSON
 *
 * ★ 必须检查 `__ERR__` 前缀 —— 那是宿主约定的失败标记。
 *   把它转成带 `network:` 前缀的异常，宿主才能映射成 ErrorKind::Network
 *   并让界面显示「网络问题」而不是「解析失败」。
 */
async function getJson(url) {
  const text = await host.http.get(url, { headers: HDRS })
  if (text.startsWith('__ERR__')) {
    throw new Error('network: ' + text.slice(7))
  }
  try {
    return JSON.parse(text)
  } catch {
    throw new Error('parse: 返回不是合法 JSON — ' + text.slice(0, 120))
  }
}

globalThis.plugin = {
  id: 'demo',

  /*
   * 能力声明 —— 宿主据此决定界面上显示什么。
   * 只声明你真正实现的，声明了却没实现会导致界面上出现「永远空白」的区块。
   */
  capabilities: {
    vod: true, // 点播
    search: true, // 搜索
    // live: true,        // 直播（需要实现 liveChannels/liveStream）
    // loginRequired: true, // 需要登录才能取流
  },

  /**
   * 首页分区
   *
   * 返回的每个 Section 只是「区块声明」，**不含内容** ——
   * 宿主会按 source 里的 categoryId 再去调 list() 懒加载。
   * 这样首页首屏不用等所有区块都拉完。
   */
  async home() {
    const data = await getJson(`${API}/home`)

    return data.sections.map((s) => ({
      id: `demo-${s.id}`,
      title: s.title,
      source: { type: 'category', categoryId: String(s.id) },
    }))
  },

  /** 分类列表（浏览页左侧用） */
  async categories() {
    const data = await getJson(`${API}/categories`)
    return data.list.map((c) => ({ id: String(c.id), name: c.name, children: [] }))
  },

  /**
   * 分类内容（分页）
   *
   * ⚠️ 返回的 items 里 `id` 是**插件内部的 id**，
   *    宿主会自动加 `demo:` 前缀，你不用自己拼。
   */
  async list(req) {
    const d = await getJson(
      `${API}/list?cat=${encodeURIComponent(req.categoryId)}&page=${req.page}`,
    )

    return {
      items: d.list.map((x) => ({
        id: String(x.id),
        title: x.name,
        cover: x.pic,
        subtitle: x.remarks,
        kind: 'movie',
      })),
      page: req.page,
      total: d.total,
    }
  },

  /** 搜索 */
  async search(keyword, page) {
    const d = await getJson(
      `${API}/search?wd=${encodeURIComponent(keyword)}&page=${page}`,
    )

    return {
      items: d.list.map((x) => ({ id: String(x.id), title: x.name, cover: x.pic })),
      page,
      total: d.total,
    }
  },

  /** 详情（含播放源与剧集） */
  async detail(id) {
    const d = await getJson(`${API}/detail?id=${encodeURIComponent(id)}`)

    return {
      id,
      title: d.name,
      cover: d.pic,
      description: d.content,
      kind: 'series',
      // 多播放源（线路）
      sources: (d.playFrom || []).map((s) => ({
        code: s.code,
        title: s.name,
        count: (s.episodes || []).length,
      })),
      episodes: (d.playFrom?.[0]?.episodes || []).map((e, i) => ({
        id: String(e.id),
        title: e.name,
        order: i + 1,
      })),
    }
  },

  /**
   * 取流 —— **唯一必须实现的方法**
   *
   * 返回候选列表（多清晰度/多线路），宿主或 UI 择优。
   *
   * ⚠️ 两条实测教训（来自内置源的经验）：
   *   · `quality` 才是用来显示的字段 —— 有些站点所有线路的
   *     `label` 都一样，只有 `quality` 能区分（央视就是这样）
   *   · `kind` 要如实填（'hls' / 'mp4'）。填错会让宿主用错解码路径，
   *     表现是「一直转圈但没有任何报错」，很难排查
   */
  async resolve(id) {
    const d = await getJson(`${API}/play?id=${encodeURIComponent(id)}`)

    return [
      {
        url: d.url,
        quality: d.quality || '原画',
        kind: d.url.includes('.m3u8') ? 'hls' : 'mp4',
        // headers: { Referer: '...' },   // 需要防盗链时加
        // drmProtected: false,           // 受保护的内容标 true，UI 会如实告知
      },
    ]
  },
}
