/**
 * @id          tvbox-live
 * @name        TVBox Live
 * @version     1.0.0
 * @author      dsh
 * @description Live channels from TVBox playlists, individually verified decodable.
 */

/*
 * Every channel below was verified with ffprobe (FFmpeg -- the same decode
 * layer the player uses) on 2026-09-30. A channel that merely answered HTTP
 * is NOT listed here: reachability is not playability.
 *
 * Only individually verified channels are emitted. Sources that failed
 * verification are deliberately not recorded here, not even as comments:
 * this file runs on the user's machine, it is not our ledger.
 *
 * The list is hardcoded on purpose. Fetching an upstream playlist at runtime
 * would add a network dependency to a path the user expects to open instantly,
 * and would let unverified channels back in.
 */

const GROUP = 'TVBox \u76f4\u64ad'

/* id | name | url */
const CHANNELS = [
  { id: 'cztv-007', name: '\u6d59\u6c5f\u65b0\u95fb', url: 'https://ali-m-l.cztv.com/channels/lantian/channel007/1080p.m3u8' },
  { id: 'cztv-010', name: '\u6d59\u6c5f\u56fd\u9645', url: 'https://ali-m-l.cztv.com/channels/lantian/channel010/1080p.m3u8' },
  { id: 'cztv-008', name: '\u6d59\u6c5f\u5c11\u513f', url: 'https://ali-m-l.cztv.com/channels/lantian/channel008/1080p.m3u8' },
  { id: 'cztv-004', name: '\u6d59\u6c5f\u6559\u79d1', url: 'https://ali-m-l.cztv.com/channels/lantian/channel004/1080p.m3u8' },
  { id: 'cztv-012', name: '\u4e4b\u6c5f\u7eaa\u5f55', url: 'https://ali-m-l.cztv.com/channels/lantian/channel012/1080p.m3u8' },
  { id: 'cztv-006', name: '\u6d59\u6c5f\u6c11\u751f', url: 'https://ali-m-l.cztv.com/channels/lantian/channel006/1080p.m3u8' },
  { id: 'cztv-003', name: '\u6d59\u6c5f\u7ecf\u6d4e', url: 'https://ali-m-l.cztv.com/channels/lantian/channel003/1080p.m3u8' },
  { id: 'cztv-002', name: '\u6d59\u6c5f\u94b1\u6c5f', url: 'https://ali-m-l.cztv.com/channels/lantian/channel002/1080p.m3u8' },
  { id: 'cgtn-en', name: 'CGTN\u82f1\u8bed', url: 'https://0472.org/hls/cgtn.m3u8' },
  { id: 'cgtn-doc', name: 'CGTN\u8bb0\u5f55', url: 'https://0472.org/hls/cgtnd.m3u8' },
  { id: 'cgtn-es', name: 'CGTN\u897f\u8bed', url: 'https://0472.org/hls/cgtnx.m3u8' },
  { id: 'cgtn-ar', name: 'CGTN\u963f\u8bed', url: 'https://0472.org/hls/cgtna.m3u8' },
]

globalThis.plugin = {
  id: 'tvbox-live',

  capabilities: {
    vod: false,
    live: true,
    epg: false,
    search: false,
  },

  /**
   * Live channel list.
   *
   * Only the verified set is returned -- no filtering at runtime, because
   * there is nothing to filter: dead entries were never written in.
   */
  async liveChannels() {
    return CHANNELS.map((c) => ({ id: c.id, name: c.name, group: GROUP }))
  },

  /**
   * Live stream for one channel.
   *
   * The URL comes straight from the hardcoded table: entering the player is a
   * hot path and must not wait on the network.
   */
  async liveStream(channelId) {
    const c = CHANNELS.find((x) => x.id === channelId)
    if (!c) {
      throw new Error('not_found: ' + channelId + ' is not in the verified list')
    }
    return [{ url: c.url, kind: 'hls', label: GROUP }]
  },
}
