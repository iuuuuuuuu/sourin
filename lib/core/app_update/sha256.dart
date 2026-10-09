// ═══════════════════════════════════════════════════════════════════════
//  文件的 SHA-256 摘要（校验更新安装包）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独一个文件
//
// 用 `package:crypto` 的 `sha256.bind(stream).first` 逐块算，内存占用恒定
// —— 安装包动辄 130MB（macOS dmg），**不能**整个读进内存再算。
// 把这条路径单独封装，调用点就只剩一行，也不会到处 copy 那句 `bind`。
//
// # 为什么必须校验
//
// 更新包可能从**第三方加速镜像**下载（见 `route.dart`）。只要走镜像，
// 就必须假定链路上有人可能替换文件 —— 摘要对不上就不给装。

import 'dart:io';

import 'package:crypto/crypto.dart';

/// 文件的十六进制摘要；读文件失败会抛出（调用方负责降级）
Future<String> sha256OfFile(File f) async {
  final d = await sha256.bind(f.openRead()).first;
  return d.toString();
}

/// 内存里一段字节的摘要（测试与小文件）
String sha256OfBytes(List<int> bytes) => sha256.convert(bytes).toString();