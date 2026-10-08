# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(sourin_spike LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "sourin_spike")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# ═══════════════════════════════════════════════════════════════════════════
#  ★★★ Rust 核心 `sourin_core.dll` —— 必须进构建链（2026-09-23 编排者补）
# ═══════════════════════════════════════════════════════════════════════════
#
# # 为什么必须加这段
#
# 在此之前，`sourin_core.dll` **完全不在构建链里** ——
# 它只在最初被手工拷进 `build\windows\x64\runner\Release\` 一次，
# 之后 `flutter build windows` **永远不会更新它**。
#
# 实测（这是我踩到的，代价很大）：
# ```text
# rust\target\release\sourin_core.dll    20:15:29   8780288 字节  ← cargo 刚编译的
# build\...\runner\Release\sourin_core.dll  01:53:29   8757248 字节  ← bundle 里的（旧）
# 两者 SHA256 不同 → bundle 里跑的是【旧核心】
# ```
#
# # 后果（为什么这是 P0）
#
# **所有针对 Rust 侧修复的"实测验证"全部失效** ——
# 你改了 `state.rs`、跑 `cargo build` 成功、再 `flutter build windows`，
# 打出来的包里**还是旧 DLL**。于是：
#   · 修复看起来"没生效"  → 白排查
#   · 或者更糟：旧行为看起来"正常" → 误判成修好了
#
# 已记录受影响的验证：第三方源重启恢复（`state.rs` 的 ⑨-b 注册）
# 等一切 Rust 侧改动。
#
# # 为什么用 `install(FILES ...)` 而不是 `add_custom_command`
#
# 与上面 `FLUTTER_LIBRARY` / `AOT_LIBRARY` 同样的机制：CMake 的 install
# 阶段会把文件放进 bundle。**不需要**在 CMake 里调 cargo —— 那样会
# 让构建依赖 Rust 工具链，破坏"只改 Dart 也能构建"的能力。
# 约定：**改 Rust 后手动 `cargo build --release`，它落到 target/release，
# 再由这里安装进 bundle。**
#
# ⚠️ 路径必须是绝对路径（`install(FILES)` 相对路径是相对
#    `CMAKE_CURRENT_SOURCE_DIR`，而那是 `windows/`，不是项目根）。
set(SOURIN_CORE_DLL
  "${CMAKE_CURRENT_SOURCE_DIR}/../rust/sourin_core/target/release/sourin_core.dll")

# 文件可能不存在（还没跑过 cargo，或只做纯 Dart 构建）——
# 不存在就**安静跳过**，不能报错让构建挂掉。
if(EXISTS "${SOURIN_CORE_DLL}")
  install(FILES "${SOURIN_CORE_DLL}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
  message(STATUS "sourin_core.dll: 将安装 ${SOURIN_CORE_DLL}")
else()
  message(WARNING
    "找不到 ${SOURIN_CORE_DLL} —— 包里不会有 Rust 核心。"
    "先跑: cargo build --release --manifest-path rust/sourin_core/Cargo.toml")
endif()

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
