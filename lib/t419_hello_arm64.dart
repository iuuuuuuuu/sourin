/**
 * t419 负控制：最小可渲染程序（arm64 对照）。
 *
 * 为什么需要它
 * ------------
 * 交付的 `源影-Android-arm64-20260930.apk` 装在 `emulator-5556`（Android TV，
 * 带 `libndk_translation.so` ARM 翻译）上时，`screencap` 恒为**纯黑**
 * （10,608 B / every-8px uniqueColours=1），但同一台车换成 x86_64 包
 * （同一世代 Dart 代码）立刻渲染出完整 TV 界面（111,479 B / 155 色）。
 *
 * 两者之间只差一个 ABI，所以有两种可能：
 *   (a) 翻译层跑不动 Flutter 的 arm64 渲染路径 ⇒ 是**车**的问题；
 *   (b) 我们的 arm64 产物本身渲染不出来 ⇒ 是**产品**的问题。
 *
 * 本文件用来把这两者分开：它**不含任何产品代码**，只有一层
 * `Directionality → ColoredBox → Center → Text`（连 material 都不 import）。
 * 如果它在同一台车上也黑 ⇒ (a)；如果它正常显示蓝底白字 ⇒ (b)。
 *
 * ⚠️ 这是探针文件，不是产品入口。产品入口是 `lib/shell.dart`。
 * 构建命令：
 *   flutter build apk --release --target-platform android-arm64 -t lib/t419_hello_arm64.dart
 */
import 'package:flutter/widgets.dart';

void main() {
  runApp(
    const Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: Color(0xFF1E63C8), // 独特的蓝，便于像素判读
        child: Center(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Text(
              'HELLO ARM64 TV',
              style: TextStyle(
                fontSize: 96,
                color: Color(0xFFFFE800), // 亮黄
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
