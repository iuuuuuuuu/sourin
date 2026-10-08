// ═══════════════════════════════════════════════════════════════════════
//  设备描述（device description XML）解析 —— task-27
// ═══════════════════════════════════════════════════════════════════════
//
// SSDP 只告诉我们"有这么一台设备，描述文档在 LOCATION"。
// 要真正下发指令，还得再 GET 一次那份 XML，从里面挖出两样东西：
//
// ```text
//   friendlyName          "客厅的小米电视"      ← 设备列表显示给人看
//   AVTransport controlURL http://…/AVTransport  ← SOAP 往这里 POST
// ```
//
// # 为什么手写解析而不是引 xml 包
//
// ```text
// 1. pub.dev 本机不可达（实测 curl → code=000），依赖加不进来；
// 2. 本项目 pubspec 里没有 xml 包，加依赖要动 pubspec.yaml（不在写作用域内）；
// 3. 我们只需要 6 个字段，而且是"挖到就完事"，不需要命名空间、不需要 schema
//    校验 —— 用 xml 包反而要处理 NamespaceAware 这些噪音。
// ```
//
// ⚠️ 但"手写正则"不等于"可以乱来"。UPnP 的 XML 有三个真坑，本文件都处理了：
// ```text
//   a) 标签可能带属性   <serviceType x="1">…</serviceType>
//   b) 中间可能有换行   <friendlyName>\n  客厅电视\n</friendlyName>
//   c) 实体转义         &amp; &lt; &gt; &quot; &apos; 以及 &#38; / &#x26;
// ```
// 少处理任何一条，就会出现"设备名显示成 &amp; 或带一堆换行"这种尴尬。

import 'dart:io';

import 'dlna_http.dart';

// ═══════════════════════════════════════════════════════════════════════
//  模型
// ═══════════════════════════════════════════════════════════════════════

/// 一台设备自报的家底
class DeviceDescription {
  DeviceDescription({
    required this.location,
    required this.friendlyName,
    required this.manufacturer,
    required this.modelName,
    required this.udn,
    required this.deviceType,
    required this.avTransportControlUrl,
    required this.serviceTypes,
  });

  /// 描述文档地址（原样带回，SOAP 出错时日志要能定位是哪台设备）
  final String location;

  /// 给人看的名字（"客厅的小米电视"）
  final String friendlyName;

  final String manufacturer;
  final String modelName;

  /// `uuid:xxxx` —— 设备唯一 ID，跨重启稳定（IP 会变，它不会）
  final String udn;

  /// `urn:schemas-upnp-org:device:MediaRenderer:1`
  final String deviceType;

  /// AVTransport 服务端点；**null = 这台设备没有 AVTransport**
  ///
  /// ★ 这是全文件最重要的一个 null。很多 UPnP 设备（路由器、NAS、
  ///   MediaServer）能被 SSDP 发现、也有描述文档，但**就是不能收投屏指令**。
  ///   此时必须如实告诉用户"这台设备不支持投屏"，
  ///   绝不能拿一个别的 controlURL 硬发 SetAVTransportURI 然后显示"投屏中"。
  final String? avTransportControlUrl;

  /// 文档里列出的全部 serviceType（诊断用："它有 RenderingControl 但没有 AVTransport"）
  final List<String> serviceTypes;

  /// 能不能投屏
  bool get canCast => avTransportControlUrl != null;

  /// 列表上显示的一行字：名字 + 型号（型号空则只有名字）
  String get displayName {
    final n = friendlyName.isNotEmpty ? friendlyName : '未命名设备';
    return modelName.isEmpty ? n : '$n · $modelName';
  }

  @override
  String toString() => 'DeviceDescription($friendlyName, $udn, avTransport=$avTransportControlUrl)';
}

// ═══════════════════════════════════════════════════════════════════════
//  解析
// ═══════════════════════════════════════════════════════════════════════

/// 取第一个 `<name ...>文本</name>` 的文本（剥空白 + 解实体）；没有则 null
String? _tagText(String xml, String name) {
  final re = RegExp('<$name(\\s[^>]*)?>(.*?)</$name>', caseSensitive: false, dotAll: true);
  final m = re.firstMatch(xml);
  if (m == null) return null;
  return _unescape(m.group(2) ?? '').trim();
}

/// XML 实体解码（含数字实体）
///
/// ★ 必须做：设备名里带 `&` 是很常见的（"A&B 电视"），
///   不解码就会在 UI 上原样显示成 `A&amp;B 电视`。
String _unescape(String s) {
  if (!s.contains('&')) return s;
  var out = s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
  out = out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
    final v = int.tryParse(m.group(1)!, radix: 16);
    return v == null ? m.group(0)! : String.fromCharCode(v);
  });
  out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final v = int.tryParse(m.group(1)!);
    return v == null ? m.group(0)! : String.fromCharCode(v);
  });
  return out;
}

/// 从描述 XML 里挖出我们要的东西
///
/// 返回 null 表示"这不是一份设备描述"（比如拿到的是一张 HTML 错误页）——
/// 调用方据此报"设备返回的内容不是 UPnP 描述文档"，而不是显示一个空名字的设备。
DeviceDescription? parseDescription(String xml, String location) {
  if (xml.trim().isEmpty) return null;
  // 必须有 <device> 段，否则不是描述文档
  if (!RegExp('<device(\\s|>)', caseSensitive: false).hasMatch(xml)) return null;

  // ★ 只取第一个 <device> 段来挖名字字段：
  //   root device 才是"这台设备"；嵌套的 <deviceList><device> 是它挂载的子设备
  //   （比如电视的"内置播放器"），名字取错了列表上会出现一个用户不认识的条目。
  final devStart = RegExp('<device(\\s|>)', caseSensitive: false).firstMatch(xml);
  var deviceBlock = xml;
  if (devStart != null) {
    final rest = xml.substring(devStart.start);
    // 到第一个 deviceList 为止（子设备从这里开始）
    final dl = rest.indexOf('<deviceList');
    deviceBlock = dl < 0 ? rest : rest.substring(0, dl);
  }

  final friendly = _tagText(deviceBlock, 'friendlyName') ?? '';
  final manufacturer = _tagText(deviceBlock, 'manufacturer') ?? '';
  final modelName = _tagText(deviceBlock, 'modelName') ?? '';
  final udn = _tagText(deviceBlock, 'UDN') ?? '';
  final deviceType = _tagText(deviceBlock, 'deviceType') ?? '';

  // ── 找 AVTransport 服务 ──
  // ★ 遍历**每一个** <service> 块，按 serviceType 里是否含 'AVTransport' 来挑；
  //   不能"取第一个 service 的 controlURL" —— 真机上第一个往往是
  //   ConnectionManager 或 RenderingControl，投过去会 500。
  final svcRe = RegExp('<service(\\s[^>]*)?>(.*?)</service>', caseSensitive: false, dotAll: true);
  String? avControl;
  final types = <String>[];
  for (final m in svcRe.allMatches(xml)) {
    final block = m.group(2) ?? '';
    final type = _tagText(block, 'serviceType') ?? '';
    if (type.isEmpty) continue;
    types.add(type);
    if (!type.contains('AVTransport')) continue;
    final ctrl = _tagText(block, 'controlURL') ?? '';
    if (ctrl.isEmpty) continue;
    // ★ 相对地址必须相对 **description 文档** 解析（见 dlna_http.resolveUrl）
    avControl = resolveUrl(ctrl, location) ?? ctrl;
    break;
  }

  return DeviceDescription(
    location: location,
    friendlyName: friendly,
    manufacturer: manufacturer,
    modelName: modelName,
    udn: udn,
    deviceType: deviceType,
    avTransportControlUrl: avControl,
    serviceTypes: types,
  );
}

/// 拉取并解析描述文档
///
/// 失败一律抛 [DlnaException]（消息是中文人话，UI 直接显示）。
Future<DeviceDescription> fetchDescription(
  String location, {
  Duration timeout = DlnaHttp.defaultTimeout,
  HttpClient? client,
}) async {
  final xml = await DlnaHttp.getText(
    location,
    timeout: timeout,
    client: client,
    headers: const {'User-Agent': 'sourin-spike/1.0 UPnP/1.1' },
  );
  final d = parseDescription(xml, location);
  if (d == null) {
    throw DlnaException(
      '设备 ${hostOf(location)} 返回的内容不是 UPnP 设备描述（可能不是投屏设备）',
      detail: xml.length > 200 ? xml.substring(0, 200) : xml,
    );
  }
  return d;
}

