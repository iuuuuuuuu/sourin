
; ═══════════════════════════════════════════════════════════════════════
;  源影 (Sourin) — Windows 安装程序
;
;  ★ 口径（照抄老 Tauri 交付物的决定，见 src-tauri/tauri.conf.json）：
;     productName  = 源影
;     identifier   = app.sourin.player
;     installMode  = currentUser   ⇒ 装到 %LOCALAPPDATA%\Programs\源影
;     languages    = SimpChinese + English
;
;  ★★ 绝不动用户数据：%APPDATA%\app.sourin.player\ 由卸载程序原样保留。
;      用户库里是收藏/历史/进度/片头片尾标记，删了不可恢复。
; ═══════════════════════════════════════════════════════════════════════

Unicode true

!define APP_NAME      "源影"
!define APP_NAME_EN   "Sourin"
!define APP_EXE       "sourin_spike.exe"
!define APP_ID        "app.sourin.player"
; ★★ 版本号可由 CI 注入：`makensis -DAPP_VERSION=1.0.0 -DOUTFILE=Sourin-Setup-1.0.0.exe ...`
;    没有注入时用下面的默认值。这样发版时版本号来自 git tag，
;    不需要每次手改这个文件（手改是漏改的常见来源）。
!ifndef APP_VERSION
  !define APP_VERSION   "0.1.0"
!endif
!define APP_PUBLISHER "Sourin"
!define APP_URL       "https://github.com/"
!define UNINST_KEY    "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}"

Name "${APP_NAME}"
; 同理，产物文件名也可注入（CI 里带上版本号，便于用户分辨）
!ifndef OUTFILE
  !define OUTFILE "Sourin-Setup.exe"
!endif
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\${APP_NAME}"
InstallDirRegKey HKCU "Software\${APP_ID}" "InstallDir"
RequestExecutionLevel user
ShowInstDetails show
ShowUninstDetails show

SetCompressor /SOLID lzma
SetCompressorDictSize 64

VIProductVersion "0.1.0.0"
VIAddVersionKey /LANG=2052 "ProductName"     "${APP_NAME}"
VIAddVersionKey /LANG=2052 "FileDescription" "${APP_NAME} 安装程序"
VIAddVersionKey /LANG=2052 "FileVersion"     "0.1.0.0"
VIAddVersionKey /LANG=2052 "ProductVersion"  "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "CompanyName"     "${APP_PUBLISHER}"
VIAddVersionKey /LANG=2052 "LegalCopyright"  "${APP_PUBLISHER}"

!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"

!define MUI_ICON   "app_icon.ico"
!define MUI_UNICON "app_icon.ico"
!define MUI_ABORTWARNING

!define MUI_WELCOMEPAGE_TITLE "欢迎安装 ${APP_NAME}"
!define MUI_WELCOMEPAGE_TEXT  "${APP_NAME}（${APP_NAME_EN}）—— 跨端视频客户端。$\r$\n$\r$\n本向导将把 ${APP_NAME} 安装到你的用户目录（无需管理员权限），并创建开始菜单快捷方式。$\r$\n$\r$\n★ 你的收藏、历史、播放进度与设置保存在 $\"%APPDATA%\app.sourin.player$\"，安装与卸载都不会动它。"
!define MUI_DIRECTORYPAGE_TEXT_TOP "选择 ${APP_NAME} 的安装位置。$\r$\n$\r$\n默认装在当前用户的 Programs 目录下，不需要管理员权限。"

!define MUI_FINISHPAGE_TITLE "${APP_NAME} 安装完成"
!define MUI_FINISHPAGE_TEXT  "${APP_NAME} 已经装好了。$\r$\n$\r$\n你的数据仍然在 $\"%APPDATA%\app.sourin.player$\"，升级安装不会覆盖它。"
!define MUI_FINISHPAGE_RUN "$INSTDIR\${APP_EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "立即运行 ${APP_NAME}"

!define MUI_UNCONFIRMPAGE_TEXT_TOP "将从本机移除 ${APP_NAME}。$\r$\n$\r$\n★ 你的收藏、历史、播放进度与设置（$\"%APPDATA%\app.sourin.player$\"）会原样保留，不会被删除。"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

; ───────────────────────────────────────────────────────────────────────
;  关进程助手：装进 $PLUGINSDIR（NSIS 启动时建、退出时删的临时目录）
;
;  ★★ 为什么不直接 `taskkill /IM sourin_spike.exe`：
;     那是**按进程名**杀 —— 会把机器上任何同名进程都杀掉，包括从别的
;     目录起的调试实例。我们自己在实测时就踩过这个坑（探针脚本按名字
;     杀，误伤了队友正在跑的实例，见 lesson #396）。
;     安装器只该关掉**它自己要覆盖的那一份**，判据必须是路径。
; ───────────────────────────────────────────────────────────────────────
!macro SOURIN_KILL_SETUP
  InitPluginsDir
  File /oname=$PLUGINSDIR\kill_sourin.ps1 "kill_sourin.ps1"
!macroend

Function .onInit
  !insertmacro SOURIN_KILL_SETUP
FunctionEnd

Function un.onInit
  !insertmacro SOURIN_KILL_SETUP
FunctionEnd

!macro SOURIN_CLOSE_RUNNING
  nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$PLUGINSDIR\kill_sourin.ps1" -InstallDir "$INSTDIR"'
  Pop $0
  Sleep 1000
!macroend

; ───────────────────────────────────────────────────────────────────────
;  正在运行的实例必须先退出：否则 exe / dll 被占用，覆盖会失败
;
;  ★ 判据用「能不能以追加方式打开自己的 exe」—— 运行中的映像被加载器
;    以 FILE_SHARE_READ|DELETE 打开，追加写会拿到共享冲突。
;    这比按进程名查更准：它只认**这个目录里的这个文件**。
; ───────────────────────────────────────────────────────────────────────
Function CloseRunningApp
  ${If} ${FileExists} "$INSTDIR\${APP_EXE}"
    ClearErrors
    FileOpen $9 "$INSTDIR\${APP_EXE}" a
    ${If} ${Errors}
      DetailPrint "检测到 ${APP_NAME} 正在运行，正在请求它正常退出…"
      !insertmacro SOURIN_CLOSE_RUNNING
      ClearErrors
      FileOpen $9 "$INSTDIR\${APP_EXE}" a
      ${If} ${Errors}
        DetailPrint "它还在运行 —— 见上面 kill_sourin.ps1 的输出"
      ${Else}
        FileClose $9
      ${EndIf}
    ${Else}
      FileClose $9
    ${EndIf}
  ${EndIf}
FunctionEnd

; ───────────────────────────────────────────────────────────────────────
;  安装
; ───────────────────────────────────────────────────────────────────────
Section "!${APP_NAME}（必需）" SecMain
  SectionIn RO
  Call CloseRunningApp

  SetOutPath "$INSTDIR"
  SetOverwrite on

  ; ── 顶层：exe + 全部插件 dll + 运行时 dll
  ;    这里原本还有一行 `File "payload\*.json"`（为「原生资产清单」）。
  ;    现代 Flutter SDK 不再往顶层写 json：它产出的是
  ;    data\flutter_assets\NativeAssetsManifest.json，已被下面那句
  ;    `File /r "payload\data\flutter_assets\*.*"` 递归扫走。
  ;    而 NSIS 的 File 通配符「一个都没匹配到」是致命错误（不是警告）：
  ;    File: "payload\*.json" -> no files found. / aborting creation process
  ;    ⇒ payload 顶层一旦没有 json，makensis 就整个中止、安装包静默留在旧版。
  ;    所以这行删掉。卸载段仍保留 `Delete "$INSTDIR\*.json"`，
  ;    负责清掉老安装遗留在顶层的那个 json。
  File "payload\${APP_EXE}"
  File "payload\*.dll"

  ; ── 原生资产清单：Flutter 在 Release 根目录也留了一份 native_assets.json。
  ;    data\flutter_assets\NativeAssetsManifest.json 由下面那句 File /r 扫走，
  ;    但顶层这份没有任何 File 指令覆盖 —— 而它确实在运行目录里，交付 zip 里
  ;    也有。安装包少这一件，t385 [4] 的「every delivery file is inside the
  ;    installer」就会红（实测 missing=['native_assets.json']）。⇒ 补上。
  ;    ★ 用 /nonfatal：NSIS 的 File 通配符「一个都没匹配到」是**致命**错误
  ;      （见上面那段注释），加 /nonfatal 后退化成 warning 7010，不会中止编译
  ;      （本机 makensis v3.11 实测 exit=0）。
  File /nonfatal "payload\native_assets.json"


  ; ── data\：AOT 快照 + ICU 数据
  SetOutPath "$INSTDIR\data"
  File "payload\data\app.so"
  File "payload\data\icudtl.dat"

  ; ── data\flutter_assets\：字体 / 着色器 / 资源清单 / 许可
  SetOutPath "$INSTDIR\data\flutter_assets"
  File /r "payload\data\flutter_assets\*.*"

  ; ── 图标：快捷方式与「应用和功能」列表用它
  SetOutPath "$INSTDIR"
  File "/oname=${APP_NAME}.ico" "app_icon.ico"

  ; ── 卸载程序
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  ; ── 开始菜单
  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
  CreateShortCut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" \
    "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_NAME}.ico" 0 SW_SHOWNORMAL "" "${APP_NAME} —— 跨端视频客户端"
  CreateShortCut "$SMPROGRAMS\${APP_NAME}\卸载 ${APP_NAME}.lnk" \
    "$INSTDIR\Uninstall.exe" "" "$INSTDIR\Uninstall.exe" 0

  ; ── 桌面快捷方式（2026-10-08 业主报「安装之后也没有创建桌面快捷方式」）
  ;
  ; ★ 只加安装侧：卸载段早就有 Delete "$DESKTOP\${APP_NAME}.lnk"（:225），
  ;   当初就是**防御性**写的 —— 那时安装侧根本没建过，所以那条 Delete 一直是空转。
  ;   现在两侧对上了。
  CreateShortCut "$DESKTOP\${APP_NAME}.lnk" \
    "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_NAME}.ico" 0 SW_SHOWNORMAL "" "${APP_NAME} —— 跨端视频客户端"

  ; ── 注册表：安装位置 + 「应用和功能」条目
  WriteRegStr HKCU "Software\${APP_ID}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\${APP_ID}" "Version"    "${APP_VERSION}"

  WriteRegStr   HKCU "${UNINST_KEY}" "DisplayName"     "${APP_NAME}"
  WriteRegStr   HKCU "${UNINST_KEY}" "DisplayVersion"  "${APP_VERSION}"
  WriteRegStr   HKCU "${UNINST_KEY}" "Publisher"       "${APP_PUBLISHER}"
  WriteRegStr   HKCU "${UNINST_KEY}" "DisplayIcon"     "$INSTDIR\${APP_NAME}.ico"
  WriteRegStr   HKCU "${UNINST_KEY}" "UninstallString" "$\"$INSTDIR\Uninstall.exe$\""
  WriteRegStr   HKCU "${UNINST_KEY}" "QuietUninstallString" "$\"$INSTDIR\Uninstall.exe$\" /S"
  WriteRegStr   HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1

  ; ── 体积（「应用和功能」列表里显示的大小）
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "${UNINST_KEY}" "EstimatedSize" "$0"
SectionEnd

; ───────────────────────────────────────────────────────────────────────
;  卸载
; ───────────────────────────────────────────────────────────────────────
Section "Uninstall"
  ${If} ${FileExists} "$INSTDIR\${APP_EXE}"
    ClearErrors
    FileOpen $9 "$INSTDIR\${APP_EXE}" a
    ${If} ${Errors}
      nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$PLUGINSDIR\kill_sourin.ps1" -InstallDir "$INSTDIR"'
      Pop $0
      Sleep 1000
    ${Else}
      FileClose $9
    ${EndIf}
  ${EndIf}

  Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\卸载 ${APP_NAME}.lnk"
  RMDir  "$SMPROGRAMS\${APP_NAME}"
  Delete "$DESKTOP\${APP_NAME}.lnk"

  RMDir /r "$INSTDIR\data"
  Delete "$INSTDIR\*.dll"
  Delete "$INSTDIR\*.json"
  Delete "$INSTDIR\${APP_NAME}.ico"
  Delete "$INSTDIR\${APP_EXE}"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"

  DeleteRegKey HKCU "${UNINST_KEY}"
  DeleteRegKey HKCU "Software\${APP_ID}"

  ; ★★ 不碰 %APPDATA%\app.sourin.player（原样保留，不删除）
  DetailPrint "★ 用户数据（$%APPDATA%\app.sourin.player）已原样保留。"
SectionEnd
