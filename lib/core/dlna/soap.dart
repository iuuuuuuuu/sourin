// ═══════════════════════════════════════════════════════════════════════
//  UPnP AVTransport SOAP 调用 —— task-27
// ═══════════════════════════════════════════════════════════════════════
//
// UPnP 的控制指令是 SOAP over HTTP：往描述文档给的 controlURL POST 一段
// XML，XML 外面套 SOAP 信封，动作名放在 body 里，动作名再重复一遍在
// `SOAPAction` 头上（**带引号**，这是最容易漏的一步）。
//
// ```text
//   POST /upnp/control/AVTransport HTTP/1.1
//   SOAPAction: "urn:schemas-upnp-org:service:AVTransport:1#Play"   ← 引号不能少
//   Content-Type: text/xml; charset="utf-8"
//
//   <s:Envelope …><s:Body><u:Play xmlns:u="urn:…:AVTransport:1">
//     <InstanceID>0</InstanceID><Speed>1</Speed></u:Play></s:Body></s:Envelope>
// ```
//
// # 三个真机上的坑（本文件都处理了）
//
// ```text
// 1. 失败是 HTTP 500 而不是 200 —— 设备把错误写在 body 里（UPnPError）。
//    所以**不能按状态码判断成败**，必须解析 body（见 SoapResult）。
// 2. 错误码是给人看的唯一线索 —— 714 = Illegal MIME-type、716 = Resource
//    not found（★ 就是"renderer 拉不到那个 URL"，投屏最常见的失败）。
//    直接把 errorCode 丢给用户等于没说，所以本文件有一张中文对照表。
// 3. InstanceID 必须是 0（MediaRenderer 只有一路）。
// ```

import 'dart:io';

import 'dlna_http.dart';

// ═══════════════════════════════════════════════════════════════════════
//  常量
// ═══════════════════════════════════════════════════════════════════════

/// AVTransport:1 的服务类型（SOAPAction 头与 xmlns:u 都要用）
const String kAvTransportService = 'urn:schemas-upnp-org:service:AVTransport:1';

/// MediaRenderer 只有一路播放，UPnP 规定 InstanceID 恒为 0
const String kInstanceId = '0';

/// 我们在投屏时给 renderer 的 DIDL-Lite 里用的协议信息
const String _kDidlNamespace = 'urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/';
const String _kDcNamespace = 'http://purl.org/dc/elements/1.1/';
const String _kUpnpNamespace = 'urn:schemas-upnp-org:metadata-1-0/upnp/';

// ═══════════════════════════════════════════════════════════════════════
//  构造
// ═══════════════════════════════════════════════════════════════════════

/// XML 文本转义
///
/// ★ 必须做：`CurrentURI` 里带 `&` 的 URL 极其常见（`?a=1&b=2`），
///   不转义的话设备收到的是非法 XML，回一个 500 + `Invalid Args`，
///   而你会以为是"设备不支持这个格式"。
String escapeXml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// 构造 SOAP 信封
///
/// [action] 是动作名（`Play` / `SetAVTransportURI` …），
/// [args] 会按插入顺序拼成 `<key>value</key>`（Dart 的 Map 保序，
/// UPnP 不要求参数顺序，但保序让日志与测试可复现）。
String buildEnvelope(
  String action, {
  String serviceType = kAvTransportService,
  required Map<String, String> args,
}) {
  final sb = StringBuffer();
  sb.write('<?xml version="1.0" encoding="utf-8"?>');
  sb.write('<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" ');
  sb.write('s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">');
  sb.write('<s:Body>');
  sb.write('<u:$action xmlns:u="$serviceType">');
  args.forEach((k, v) {
    sb.write('<$k>${escapeXml(v)}</$k>');
  });
  sb.write('</u:$action>');
  sb.write('</s:Body>');
  sb.write('</s:Envelope>');
  return sb.toString();
}

/// SOAPAction 头的值 —— **必须带双引号**
///
/// 实测：去掉引号后部分设备回 400/500，且错误信息完全看不出是头的问题。
String soapActionHeader(String action, {String serviceType = kAvTransportService}) =>
    '"$serviceType#$action"';

/// 构造 DIDL-Lite 元数据
///
/// # 为什么要它（能不能传空串？）
///
/// ```text
/// 规范允许 SetAVTransportURI 的 CurrentURIMetaData 传空串，很多设备也认。
/// 但三星/部分 LG 电视只认 DIDL-Lite —— 传空串会回 714 Illegal MIME-type。
/// 传 DIDL 的代价只是几百字节，所以**默认就带**。
/// ```
String buildDidlLite(
  String url, {
  String title = '投屏',
  String mimeType = 'video/mp4',
  String protocolInfo = 'http-get:*:video/mp4:*',
}) {
  final sb = StringBuffer();
  sb.write('<DIDL-Lite xmlns="$_kDidlNamespace" xmlns:dc="$_kDcNamespace" ');
  sb.write('xmlns:upnp="$_kUpnpNamespace">');
  sb.write('<item id="0" parentID="-1" restricted="1">');
  sb.write('<dc:title>${escapeXml(title)}</dc:title>');
  sb.write('<dc:creator>sourin</dc:creator>');
  sb.write('<upnp:class>object.item.videoItem</upnp:class>');
  sb.write('<res protocolInfo="${escapeXml(protocolInfo)}" ');
  sb.write('mimeType="${escapeXml(mimeType)}">${escapeXml(url)}</res>');
  sb.write('</item></DIDL-Lite>');
  return sb.toString();
}

// ═══════════════════════════════════════════════════════════════════════
//  响应
// ═══════════════════════════════════════════════════════════════════════

/// 一次 SOAP 调用的结果
///
/// ★ 成败判据是 **body**，不是 HTTP 状态码（设备用 500 表达 SOAP Fault）。
class SoapResult {
  SoapResult({
    required this.statusCode,
    required this.body,
    required this.faultCode,
    required this.faultString,
    required this.errorCode,
    required this.errorDescription,
  });

  final int statusCode;
  final String body;

  /// `<faultcode>`（如 `s:Client`）；没有 Fault 时为 null
  final String? faultCode;

  /// `<faultstring>`（如 `UPnPError`）
  final String? faultString;

  /// UPnP 错误号（701/714/716…）；不是 UPnPError 时为 null
  final int? errorCode;

  /// `<errorDescription>`（设备自己的英文说明）
  final String? errorDescription;

  /// 有 Fault 段就是失败（不管 HTTP 是 200 还是 500）
  bool get isFault => faultString != null || errorCode != null;

  bool get ok => !isFault && statusCode >= 200 && statusCode < 300;

  /// 面向用户的中文失败原因
  ///
  /// ★ 优先用错误码查表 —— 设备的 `errorDescription` 是英文，
  ///   而且经常就是 `UPnPError` 这种没信息的词。
  String get message {
    if (errorCode != null) {
      final known = upnpErrorText(errorCode!);
      // ★ 把**原始错误码**一起带上：人话是给用户看的，码是给报障/日志用的。
      //   （实测：只给人话时，用户截图过来我们无法判断到底是 716 还是 714）
      final dev = errorDescription == null ? '' : '；设备说：$errorDescription';
      if (known != null) {
        return '$known（UPnP $errorCode$dev）';
      }
      return '设备返回 UPnP 错误 $errorCode'
          '${errorDescription == null ? '' : '（$errorDescription）'}';
    }
    if (faultString != null) return '设备返回 SOAP 故障：$faultString';
    return '设备返回 HTTP $statusCode';
  }

  @override
  String toString() => 'SoapResult(ok=$ok, http=$statusCode, code=$errorCode, $faultString)';
}

/// UPnP AVTransport 错误码 → 中文人话
///
/// 只列投屏链路上真会遇到的；查不到返回 null（调用方退化成"错误 7xx"）。
/// 表来源：UPnP AVTransport:1 规范 2.4.3 节（错误码是规范固定值，不是设备自定义）。
String? upnpErrorText(int code) {
  switch (code) {
    case 401:
      return '设备拒绝了这次操作（参数非法）';
    case 402:
      return '设备的参数列表不合法（不同版本 AVTransport 的常见问题）';
    case 501:
      return '设备不支持这个动作';
    case 701:
      return '设备当前状态不允许这个操作（比如正在播放中收到 Stop）';
    case 702:
      return '设备不支持这个操作';
    case 703:
      return '设备没有可播放的内容';
    case 704:
      return '设备无法播放这个媒体格式';
    case 705:
      return '设备无法读取这段媒体的描述信息';
    case 706:
      return '设备无法读取这段媒体的连接信息';
    case 710:
      return '设备的 Seek 模式不支持（比如视频不支持拖进度）';
    case 711:
      return '设备拒绝这次 Seek（位置超出范围）';
    case 712:
      return '设备不支持播放速度调整';
    case 713:
      return '设备不支持这个传输状态';
    case 714:
      return '设备不接受这段媒体的类型（换直链或换设备试试）';
    case 715:
      return '设备拒绝这段媒体（内容被设备判为非法）';
    case 716:
      return '★ 设备打不开这个地址（资源不存在或取不到）—— 投屏失败最常见的原因';
    case 718:
      return 'InstanceID 非法';
    case 719:
      return '设备已经有一路播放任务了（不支持多路）';
    default:
      return null;
  }
}

/// 从 SOAP 响应体里抽 Fault / 错误码
///
/// 用正则而不是 xml 包，理由见 description.dart 文件头（pub.dev 不可达 + 只需几个字段）。
SoapResult parseSoapResponse(String body, {int statusCode = 200}) {
  String? pick(String tag) {
    final m = RegExp('<$tag(\\s[^>]*)?>(.*?)</$tag>', caseSensitive: false, dotAll: true)
        .firstMatch(body);
    if (m == null) return null;
    final v = (m.group(2) ?? '').trim();
    return v.isEmpty ? null : v;
  }

  final ec = pick('errorCode');
  return SoapResult(
    statusCode: statusCode,
    body: body,
    faultCode: pick('faultcode'),
    faultString: pick('faultstring'),
    errorCode: ec == null ? null : int.tryParse(ec),
    errorDescription: pick('errorDescription'),
  );
}

// ═══════════════════════════════════════════════════════════════════════
//  发送
// ═══════════════════════════════════════════════════════════════════════

/// 发一条 SOAP 指令
///
/// [controlUrl] 来自 description.dart 挖出来的 AVTransport controlURL。
/// 抛 [DlnaException] 只在"根本没拿到响应"时（超时/连不上）；
/// 设备明确回错（含 SOAP Fault）时**返回** [SoapResult] 让调用方决定怎么说。
Future<SoapResult> invoke(
  String controlUrl,
  String action, {
  Map<String, String> args = const {},
  String serviceType = kAvTransportService,
  Duration timeout = DlnaHttp.defaultTimeout,
  HttpClient? client,
  void Function(String line)? onLog,
}) async {
  final body = buildEnvelope(action, serviceType: serviceType, args: args);
  final headers = <String, String>{
    'Content-Type': 'text/xml; charset="utf-8"',
    'SOAPAction': soapActionHeader(action, serviceType: serviceType),
    'User-Agent': 'sourin-spike/1.0 UPnP/1.1',
    'Connection': 'close',
  };
  onLog?.call('[SOAP] → POST $controlUrl');
  onLog?.call('[SOAP] → SOAPAction: ${headers['SOAPAction']}');
  onLog?.call('[SOAP] → ${body.length} 字节');
  final res = await DlnaHttp.postXml(
    controlUrl,
    body,
    headers: headers,
    timeout: timeout,
    client: client,
  );
  final parsed = parseSoapResponse(res.body, statusCode: res.statusCode);
  onLog?.call('[SOAP] ← HTTP ${res.statusCode}（${res.body.length} 字节）${parsed.ok ? '' : ' 失败：${parsed.message}'}');
  return parsed;
}

// ═══════════════════════════════════════════════════════════════════════
//  具体动作
// ═══════════════════════════════════════════════════════════════════════

/// AVTransport 的封装：一个 controlURL + 一串动作方法
class AvTransport {
  AvTransport({
    required this.controlUrl,
    this.timeout = DlnaHttp.defaultTimeout,
    this.onLog,
  });

  final String controlUrl;
  final Duration timeout;
  final void Function(String line)? onLog;

  Future<SoapResult> _call(String action, Map<String, String> args) =>
      invoke(controlUrl, action, args: args, timeout: timeout, onLog: onLog);

  /// 告诉设备"待会儿放这个地址"（不自动播）
  Future<SoapResult> setAvTransportUri(
    String url, {
    String? metaData,
    String title = '投屏',
  }) =>
      _call('SetAVTransportURI', {
        'InstanceID': kInstanceId,
        'CurrentURI': url,
        'CurrentURIMetaData': metaData ?? buildDidlLite(url, title: title),
      });

  Future<SoapResult> play({String speed = '1'}) => _call('Play', {
        'InstanceID': kInstanceId,
        'Speed': speed,
      });

  Future<SoapResult> pause() => _call('Pause', {'InstanceID': kInstanceId});

  Future<SoapResult> stop() => _call('Stop', {'InstanceID': kInstanceId});

  /// 拖进度。[target] 形如 `00:12:34`
  Future<SoapResult> seek(String target) => _call('Seek', {
        'InstanceID': kInstanceId,
        'Unit': 'REL_TIME',
        'Target': target,
      });

  /// 问设备现在在干什么 —— 返回体里 `<CurrentTransportState>PLAYING</...>`
  Future<SoapResult> getTransportInfo() => _call('GetTransportInfo', {
        'InstanceID': kInstanceId,
      });

  /// 问设备当前播放位置（轮询用；失败返回 null，UI 保持上一次的值）
  Future<String?> getPosition() async {
    final r = await _call('GetPositionInfo', {'InstanceID': kInstanceId});
    if (!r.ok) return null;
    final m = RegExp('<RelTime(\\s[^>]*)?>(.*?)</RelTime>', caseSensitive: false, dotAll: true)
        .firstMatch(r.body);
    final v = (m?.group(2) ?? '').trim();
    return v.isEmpty ? null : v;
  }
}

