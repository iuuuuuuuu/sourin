# 源影 v__VERSION__

跨端视频聚合客户端 —— **Windows / macOS / Android（含 Android TV）**。

后端业务逻辑全部在 Rust 核心（`sourin_core`），Flutter 只做 UI，
两者通过 `dart:ffi` 直接调用（无 IPC、无本地服务）。

---

## 下载

| 平台 | 文件 | 说明 |
|---|---|---|
| **Windows 10/11 (x64)** | `Sourin-Setup-__VERSION__.exe` | **安装版**（推荐）：双击 → 下一步 → 开始菜单与桌面快捷方式、可在「应用和功能」里卸载。免管理员权限 |
| **Windows 10/11 (x64)** | `sourin-windows-v__VERSION__.zip` | **免安装版**：解压到任意目录 → 双击 `sourin_spike.exe` |
| **macOS 12+** | `sourin-macos-v__VERSION__.dmg` | **安装镜像**（推荐）：双击打开 → 把 `sourin_spike.app` 拖进 `Applications` → 完成。⚠️ 见下方【macOS 首次打开】 |
| **macOS 12+** | `sourin-macos-v__VERSION__.zip` | 压缩包版（给脚本 / CI / 受限环境）。解压后手动把 `.app` 放进「应用程序」 |
| **Android 手机 / 平板** | `sourin-android-arm64-v__VERSION__.apk` | 现代设备（近 5 年基本都是这个） |
| **Android TV / 电视盒子** | `sourin-android-armv7-v__VERSION__.apk` | 较老的 32 位设备；TV 版**同一个 APK**，装上即出现在 TV 主界面 |

### Windows 安装版与免安装版有什么区别

| | 安装版（`Sourin-Setup-*.exe`） | 免安装版（`.zip`） |
|---|---|---|
| 安装方式 | 双击走安装向导 | 解压到任意目录即可 |
| 快捷方式 | 自动建开始菜单 + 桌面 | 无（自己建） |
| 卸载 | 「设置 → 应用 → 已安装的应用」里能卸载 | 直接删目录 |
| 需要管理员权限 | **不需要**（装到 `%LOCALAPPDATA%\Programs\源影`） | 不需要 |
| 数据目录 | 同一个 `%APPDATA%\app.sourin.player` | 同一个 |

**两个版本的内容完全一样**（同一个 commit 构建，同一份 Release 目录打出来的）。
macOS 侧的 `.dmg` 与 `.zip` 同理 —— 内容同源，只是分发形态不同。
装过一次之后想换成免安装版，直接卸载再解压即可，**收藏/历史/进度都不会丢**
（它们在 `%APPDATA%` 下，安装与卸载都不碰）。

> **Android TV 不需要单独的版本** —— 同一个 APK 里 `AndroidManifest` 同时声明了
> `LAUNCHER`（手机桌面）与 `LEANBACK_LAUNCHER`（TV 主界面），
> 运行时靠系统 feature 判定设备类型，UI 自动切换成 TV 形态（大字距、焦点环、72px 底栏）。

---

## 功能

### 内容聚合
- **多源聚合**：内置站点 + 第三方 JS 插件 + 声明式 JSON 源 + 进程外 HTTP 源
- **跨源搜索**：一次搜索并发打全部源，**边搜边出**（流式返回，不等最慢的那个）
- **跨源换源**：同一部剧在别的源也能看，按标题相似度排序，带进度迁移
- **TVBox 直连**：直接填 TVBox 配置**地址**或 JSON，内部解析成源，不需要转换脚本
- **B 站**：扫码登录、搜索、弹幕（含分 P）、自动更新
- **Emby / Jellyfin**：登录、媒体库、直接播放
- **IPTV 直播**：iptv-org 频道表、分组、上下键切台
- **CCTV**：央视栏目与直播（DRM 流如实提示「仅音频可播」）

### 播放
- **内核**：libmpv（media_kit），硬解 d3d11va / MediaCodec
- **格式**：HEVC / H.264 / AV1、AC3 / DTS / AAC、ASS / SRT 字幕
- **字幕**：内封轨切换、外挂字幕、ASS 样式（字号/颜色/位置）、Assrt 字幕库
- **弹幕**：B 站弹幕、自定义弹幕服务器，速度/透明度/密度/区域可调
- **手势**：PC 与触摸两套（双击全屏、长按倍速、左右滑动跳转、上下滑音量/亮度）
- **控件自动隐藏**：鼠标停手 3 秒后**顶栏与底栏一起淡出**（同一个动画源），一晃动一起回来
- **画中画**：独立窗口，可从播放页一键切出
- **投屏**：DLNA 投到电视（自动改写 m3u8 内嵌地址）
- **遥控**：手机当遥控器（局域网 HTTP + 二维码配对）

### 下载
- **整片下载**：把 HLS 播放列表里的**全部分片**拼成一个文件（不是存清单）
- **按组存放**：一部剧一个文件夹
- **单集 / 全部集**：详情页头部的「下载」菜单；全部集走**串行**队列
- **片段缓存**：播放页「下载本集到缓存」，独立目录 + 上限淘汰

### 桌面集成
- **托盘图标**：单击打开、右键菜单
- **关闭确认**：首次点 X 问「最小化到托盘 / 彻底退出 / 取消」，选择被记住
- **自绘标题栏**：可拖动、双击最大化、贴边 Aero Snap
- **窗口几何记忆**：下次启动回到上次的位置和大小
- **云同步**：WebDAV 备份/恢复，多设备共享收藏与进度

---

## 插件

源影自带一份**可直接运行**的示例插件 `demo.js`（不是伪代码）—— 照着它改就能写自己的源。
它是「给人看怎么写插件的模板」，**默认停用**（首次启动时会写进 `disabled-providers.json`，
想用它就在「设置 → 插件」里手动启用）。

**它在哪里**（三条真实路径，任选）：

| 位置 | 怎么拿到 |
|---|---|
| **数据目录**（推荐） | 装好或解压后**首次启动**程序，它会自动释放到 `<数据目录>\plugins\`。Windows 默认是 `%APPDATA%\app.sourin.player\plugins\demo.js` |
| **仓库源码** | [`rust/sourin_core/plugins/demo.js`](https://github.com/iuuuuuuuu/sourin/blob/main/rust/sourin_core/plugins/demo.js) |
| **本页 Source code** | 下载本 Release 页的 `Source code (zip)` / `Source code (tar.gz)`，里面同一路径下有同一份 |

> 无需从安装包或 zip 里翻找 —— 示例插件是**编进核心库**的
> （`rust/sourin_core/src/state.rs` 的 `include_str!("../plugins/demo.js")`），
> 首次启动时由程序自己释放到数据目录，和收藏/历史放在一起。
>
> 想了解插件的**完整 API 契约**（每个方法要返回什么字段）？本仓库目前**没有**单独的
> `plugins/README.md` —— `demo.js` 头部注释里引用的就是它，一并说明：若你的源码包里没有
> 这个文件，请看本页这一节；需要更细的字段说明时，`demo.js` 里每个方法上都有逐字段注释，
> 那是最权威的说明。

---

## ⚠️ 平台注意事项（重要）

### macOS 首次打开
本包**未做代码签名与公证**（没有 Apple 开发者账号）。直接双击会被 Gatekeeper 拦下，
提示「无法打开，因为 Apple 无法检查其是否包含恶意软件」。

**绕过方法**（任选其一）：
1. 右键点 `sourin_spike.app` → **打开** → 在弹窗里再点**打开**（只需一次，之后记住）
2. 系统设置 → 隐私与安全性 → 拉到底 → 点「仍要打开」
3. 命令行：
   ```bash
   xattr -dr com.apple.quarantine /Applications/sourin_spike.app
   ```

### Android
本包用 **Flutter 的 debug 签名**（不是发布密钥）。可以直接装，但：
- 若有旧版本已安装且签名不同，需要先卸载
- 部分国产 ROM 会提示「未知来源」或「应用未经过安全检测」，属正常

### Windows
SmartScreen 可能提示「Windows 已保护你的电脑」——点「更多信息」→「仍要运行」。
（安装包同样未做 EV 代码签名。）

---

## 系统要求

| | 最低 |
|---|---|
| **Windows** | Windows 10 x64（依赖 D3D11；Win7/8 未测试） |
| **macOS** | macOS 12 (Monterey) 及以上 |
| **Android** | Android 7.0 (API 24) 及以上；TV 需支持 Leanback |
| **磁盘** | 约 150 MB（Windows 解压后）；播放缓存另计 |

---

## 数据目录

| 平台 | 路径 |
|---|---|
| Windows | `%APPDATA%\app.sourin.player` |
| macOS | `~/Library/Containers/app.sourin.player/Data/app.sourin.player` |
| Android | 应用私有目录 |

> Windows 上**与原版 Tauri 客户端用同一个目录** —— 从原版迁过来的用户，
> 收藏 / 历史 / 进度 / 插件全都还在。升级安装**不会**覆盖这个目录。

---

## 关于本版本

首个公开版本。三端产物均由 GitHub Actions 在**同一个 commit** 上构建，
每个产物在 CI 里都过了硬门禁（不只是「编译通过」）：

- **Windows**：`flutter analyze` 0 error → 全量 Dart 测试 2243 通过 / 47 跳过 / 0 失败 → Rust 单元测试 → 产物核验
- **macOS**：同上 + 产物必须真的带 `libsourin_core.dylib`（`nm` 数 `sourin_*` 导出符号 ≥ 7）+ 权限声明核验
- **Android**：交叉编译两个 ABI 的 Rust 核心 + 符号数核验 + 用 `aapt` 核验手机入口与 TV 入口**都在**

---

## 许可

MIT —— 见 [LICENSE](https://github.com/iuuuuuuuu/sourin/blob/main/LICENSE)。

## 免责声明

本项目**不提供、不存储、不分发**任何影视内容，只是一个聚合客户端。
所有内容均来自用户自行配置的第三方源。请遵守你所在地区的法律法规，
仅用于学习与技术研究。
