// 窗口投影实现 —— 见 window_shadow.h 顶部的完整说明（含实测数据）
//
// ★ 这个文件的注释密度很高，因为它是"三条路都被否掉之后"的第四条路。
//   删掉任何一段解释，后人都可能重走前面三条死路。

#include "window_shadow.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace sourin {
namespace {

// -- 阴影参数（改这几个数就能整体调观感）--------------------------------
//
// ★ 这些值是从 .probe/shadow_proto3.py 原型里"照着 QQ 量出来的观感"调的：
//   QQ 实测（.probe/orch_qq5.txt）：阴影宽 13px，最深处比背景暗 30 级
//   我们这里：MARGIN=24（画布留白）、SIGMA=8（模糊半径）、ALPHA=0.45（最深）
//   ⇒ 实测渐变 255->200（暗 55 级），比 QQ 略深一点，但形状一致
constexpr int kShadowMargin = 24;      ///< 阴影向外扩展的像素（逻辑）
constexpr double kShadowSigma = 8.0;   ///< 高斯模糊 sigma（逻辑像素）
constexpr double kShadowAlpha = 0.45;  ///< 最深处的不透明度
constexpr double kCornerRadius = 10.0; ///< 与 `kWindowCornerRadius` 一致

/// ★ 首帧门控的兜底超时（毫秒）—— 见 `WindowShadow::NotifyFirstFrameReady`
///
/// ```text
/// 为什么需要兜底：首帧回调可能永远不来（Dart 侧崩了、window_manager 卡住）。
/// 那时如果不放行，用户得到的是"一个永远没有阴影的窗口" —— 比"阴影早 187ms"
/// 严重得多。
/// ★ 起点不是 Attach（≈150ms），而是"主窗口首次变为可见"（实测 2821.275ms）：
///   以 Attach 为起点的话 1650ms 就开火，而首帧实测 3043.2ms ⇒ 兜底会先开火，
///   把 bug 原样带回来。
/// ```
constexpr UINT kFirstFrameFallbackMs = 1500;

/// 兜底定时器 id（挂在**阴影窗口**上，由 `ShadowWindowProc` 接）
constexpr UINT_PTR kFirstFrameFallbackTimerId = 0x5A01;

/// 逐帧重同步的拍间隔
///
/// ```text
/// 16ms 约等于一帧 @60Hz。SetTimer 的最小分辨率约 15.6ms（USER_TIMER_MINIMUM），
/// 所以取 16 就够「逐帧」，再小也不会更快。
/// ```
constexpr UINT kResyncIntervalMs = 16;

/// 逐帧重同步的总拍数 —— **必须是有界的**
///
/// ```text
/// 这是「逐帧」节奏：一旦忘了杀，就变成常驻空转（每拍一次
/// GetWindowRect + SetWindowPos）。参照 win32_window.cpp 的自愈定时器
/// （kSelfHealTicks = 15，只在前 15 个 tick 里校正，之后自动 KillTimer），
/// 这里同样只跑有限拍。
/// 20 拍 x 16ms 约 320ms 的依据：实测最大化/还原的最长 >1px 偏差窗口是
/// 89.89ms（before 臂，.probe/t51_result.md 2.5），取约 3.5 倍余量。
/// 拖动过程中 win32_window.cpp 每帧都会重新布防（续期），所以 320ms 只约束
/// 「最后一次尺寸变化之后还要跟多久」。
/// ```
constexpr int kResyncTicks = 20;

/// 逐帧重同步定时器 id（同样挂在**阴影窗口**上，由 `ShadowWindowProc` 接）
constexpr UINT_PTR kResyncTimerId = 0x5A02;

/// 环境变量开关（便于 A/B 对照；默认开启）
///
/// ```text
/// SOURIN_WIN_SHADOW=0  ⇒ 关闭阴影（用于对照实验）
/// ```
/// ★ 与 `SOURIN_WIN_NOSHADOW`（那是"无边框化"的开关）**不是一回事**，
///   名字故意区分开，避免混淆。
bool ReadEnabledFromEnv() {
  char buf[8] = {};
  const DWORD n = ::GetEnvironmentVariableA("SOURIN_WIN_SHADOW", buf,
                                            sizeof(buf));
  if (n == 0 || n >= sizeof(buf)) {
    return true;  // 默认开启
  }
  return buf[0] != '0';
}

/// ★ 红度证明开关（**只**用于 A/B 对照，默认关）
///
/// ```text
/// SOURIN_WIN_SHADOW_LEGACY=1  ⇒ 强制走"逐像素"旧循环（实测慢 1.89~2.06 倍）
/// ```
/// ★ 两条路径的输出**逐位相同** —— `.probe/bench/t51_blur_bench.cpp` 的
///   PART 1 在 7 组尺寸 × 3 个 scale = 21 组上逐 float `memcmp`，全部
///   `identical`。⇒ 这个开关**不可能**改变观感，只改变耗时 ⇒ 是干净的
///   对照臂：同一个 exe、同一台机器、同一把尺子，只翻一个环境变量。
/// ★ 为什么要留它：否则"新循环更快"只能靠**跨构建**比较（构建间方差、
///   机器负载都会混进来），那是弱证据。
bool LegacyLoopsFromEnv() {
  static const bool legacy = [] {
    char buf[8] = {};
    const DWORD n = ::GetEnvironmentVariableA("SOURIN_WIN_SHADOW_LEGACY", buf,
                                              sizeof(buf));
    return n > 0 && n < sizeof(buf) && buf[0] == '1';
  }();
  return legacy;
}

/// 分离式高斯模糊（对单通道 float 缓冲）—— **精确版**（全分辨率）
///
/// ★ 这是原始实现，现在由 [GaussianBlur] 在 sigma 较小时走它；
///   大 sigma 走降采样版（见 [GaussianBlur] 上方那段长注释说明原因）。
void GaussianBlurExact(std::vector<float>& data, int w, int h, double sigma) {
  if (sigma <= 0.0) {
    return;
  }
  const int radius = static_cast<int>(sigma * 3.0);
  std::vector<float> kernel(radius * 2 + 1);
  double sum = 0.0;
  for (int i = -radius; i <= radius; ++i) {
    const double v = std::exp(-(i * i) / (2.0 * sigma * sigma));
    kernel[i + radius] = static_cast<float>(v);
    sum += v;
  }
  for (auto& v : kernel) {
    v = static_cast<float>(v / sum);
  }

  std::vector<float> tmp(data.size());
  // 水平
  for (int y = 0; y < h; ++y) {
    const int base = y * w;
    for (int x = 0; x < w; ++x) {
      float acc = 0.0f;
      for (int i = -radius; i <= radius; ++i) {
        const int xx = x + i;
        if (xx >= 0 && xx < w) {
          acc += data[base + xx] * kernel[i + radius];
        }
      }
      tmp[base + x] = acc;
    }
  }
  // 垂直
  for (int y = 0; y < h; ++y) {
    for (int x = 0; x < w; ++x) {
      float acc = 0.0f;
      for (int i = -radius; i <= radius; ++i) {
        const int yy = y + i;
        if (yy >= 0 && yy < h) {
          acc += tmp[yy * w + x] * kernel[i + radius];
        }
      }
      data[y * w + x] = acc;
    }
  }
}

/// 面积平均降采样（= box 滤波，同时起到抗锯齿作用）
///
/// ★ 用**面积平均**而不是"隔点抽样"：圆角矩形的角落是**阶跃**，
///   抽样会让阶跃走样；面积平均把它平滑掉，与后续高斯叠加后
///   与"先精确模糊再降采样"几乎不可分辨（有数值证明，见探针）。
void DownsampleAlpha(const std::vector<float>& src, int w, int h, int factor,
                     std::vector<float>& dst, int* out_w, int* out_h) {
  const int sw = (w + factor - 1) / factor;
  const int sh = (h + factor - 1) / factor;
  dst.assign(static_cast<size_t>(sw) * sh, 0.0f);
  for (int sy = 0; sy < sh; ++sy) {
    const int y0 = sy * factor;
    const int y1 = std::min(y0 + factor, h);
    for (int sx = 0; sx < sw; ++sx) {
      const int x0 = sx * factor;
      const int x1 = std::min(x0 + factor, w);
      float acc = 0.0f;
      for (int y = y0; y < y1; ++y) {
        const int base = y * w;
        for (int x = x0; x < x1; ++x) {
          acc += src[base + x];
        }
      }
      // 边缘那块可能不满 factor×factor ⇒ 除以**实际**个数
      dst[static_cast<size_t>(sy) * sw + sx] =
          acc / static_cast<float>((x1 - x0) * (y1 - y0));
    }
  }
  *out_w = sw;
  *out_h = sh;
}

/// 双线性放大回原尺寸（边界 clamp）
///
/// ⚠️ 映射用像素**中心对齐**：`f = (dst + 0.5) / factor - 0.5`。
///    用 `dst / factor` 会让整幅图偏移半个小像素（放大后被 factor 倍放大成
///    明显的位移）。
void UpsampleAlphaBilinear(const std::vector<float>& src, int sw, int sh,
                           int factor, std::vector<float>& dst, int w, int h) {
  if (LegacyLoopsFromEnv()) {
    // ★ 旧循环（红度证明的对照臂）：每个像素都重算 x 映射。
    for (int y = 0; y < h; ++y) {
      const double fy = (y + 0.5) / factor - 0.5;
      int y0 = static_cast<int>(std::floor(fy));
      const double ty = fy - y0;
      int y1 = y0 + 1;
      y0 = std::min(std::max(y0, 0), sh - 1);
      y1 = std::min(std::max(y1, 0), sh - 1);
      for (int x = 0; x < w; ++x) {
        const double fx = (x + 0.5) / factor - 0.5;
        int x0 = static_cast<int>(std::floor(fx));
        const double tx = fx - x0;
        int x1 = x0 + 1;
        x0 = std::min(std::max(x0, 0), sw - 1);
        x1 = std::min(std::max(x1, 0), sw - 1);
        const double a = src[static_cast<size_t>(y0) * sw + x0];
        const double b = src[static_cast<size_t>(y0) * sw + x1];
        const double c = src[static_cast<size_t>(y1) * sw + x0];
        const double d = src[static_cast<size_t>(y1) * sw + x1];
        const double top = a + (b - a) * tx;
        const double bot = c + (d - c) * tx;
        dst[static_cast<size_t>(y) * w + x] =
            static_cast<float>(top + (bot - top) * ty);
      }
    }
    return;
  }

  /*
   * ★★★ 2026-09-30 快路径（判据 1 归因后加）
   *
   * 实测（`.probe/bench/t51_blur_bench.cpp`，median of 9 / 5）：
   *   1328x848 : 这个循环 8.59 ms = 整次重建的 34.9%（第一大热点）
   *   2584x1464: 这个循环 30.68 ms = 35.1%
   * ⇒ 它是 BuildBitmap 里最贵的一段，比高斯模糊（10.3%）贵三倍多。
   *
   * 贵的**不是**插值本身，而是每个像素都在重算**只跟 x 有关**的东西：
   * `fx`、`floor`、两次 clamp、`tx`。这些量在一行之内**逐像素重复**
   * （w 次），而它们只依赖 x ⇒ 提到 y 循环外预计算一次即可。
   *
   * ★ 为什么敢说"逐位相同"：内层剩下的运算顺序、操作数类型（double）
   *   与旧版**逐字一致**，只是把预计算好的整数下标/权重喂进去。探针在
   *   7 组尺寸 × 3 个 scale = 21 组上逐 float `memcmp` ⇒ 全部 identical。
   */
  std::vector<int> xs0(static_cast<size_t>(w));
  std::vector<int> xs1(static_cast<size_t>(w));
  std::vector<double> txv(static_cast<size_t>(w));
  for (int x = 0; x < w; ++x) {
    const double fx = (x + 0.5) / factor - 0.5;
    int x0 = static_cast<int>(std::floor(fx));
    const double tx = fx - x0;
    int x1 = x0 + 1;
    x0 = std::min(std::max(x0, 0), sw - 1);
    x1 = std::min(std::max(x1, 0), sw - 1);
    xs0[static_cast<size_t>(x)] = x0;
    xs1[static_cast<size_t>(x)] = x1;
    txv[static_cast<size_t>(x)] = tx;
  }

  for (int y = 0; y < h; ++y) {
    const double fy = (y + 0.5) / factor - 0.5;
    int y0 = static_cast<int>(std::floor(fy));
    const double ty = fy - y0;
    int y1 = y0 + 1;
    y0 = std::min(std::max(y0, 0), sh - 1);
    y1 = std::min(std::max(y1, 0), sh - 1);
    const float* r0 = &src[static_cast<size_t>(y0) * sw];
    const float* r1 = &src[static_cast<size_t>(y1) * sw];
    float* out = &dst[static_cast<size_t>(y) * w];
    for (int x = 0; x < w; ++x) {
      const size_t ix0 = static_cast<size_t>(xs0[static_cast<size_t>(x)]);
      const size_t ix1 = static_cast<size_t>(xs1[static_cast<size_t>(x)]);
      const double tx = txv[static_cast<size_t>(x)];
      const double a = r0[ix0];
      const double b = r0[ix1];
      const double c = r1[ix0];
      const double d = r1[ix1];
      const double top = a + (b - a) * tx;
      const double bot = c + (d - c) * tx;
      out[x] = static_cast<float>(top + (bot - top) * ty);
    }
  }
}

/// 圆角矩形的硬边 alpha（1.0 = 不透明，0.0 = 透明）—— 阴影的**形状**
///
/// ★ 2026-09-30 从 `BuildBitmap()` 里**提取出来**，唯一目的是让探针能直接
///   测**发布代码本身**：原先它内联在 `BuildBitmap()` 内部，而那个函数要
///   真窗口、真 DC 才能跑 ⇒ 探针只能测"我手抄的一份副本"，而副本等价
///   **证明不了**发布代码等价。提取后 `.probe/bench` 直接调这个函数。
///
/// ⚠️ `margin` 是**物理像素**（调用方已乘过 DPI scale），`radius` 也是。
void BuildCornerMask(std::vector<float>& alpha, int width, int height,
                     int margin, double radius) {
  alpha.assign(static_cast<size_t>(width) * height, 0.0f);
  const double x0 = margin;
  const double y0 = margin;
  const double x1 = width - margin;
  const double y1 = height - margin;

  if (LegacyLoopsFromEnv()) {
    // ★ 旧循环（红度证明的对照臂）：每个像素都做一遍 double 数学。
    for (int y = 0; y < height; ++y) {
      for (int x = 0; x < width; ++x) {
        if (x >= x0 && x <= x1 && y >= y0 && y <= y1) {
          const double cx =
              std::min(std::max(static_cast<double>(x), x0 + radius),
                       x1 - radius);
          const double cy =
              std::min(std::max(static_cast<double>(y), y0 + radius),
                       y1 - radius);
          const double dx = x - cx;
          const double dy = y - cy;
          if (dx * dx + dy * dy <= radius * radius) {
            alpha[static_cast<size_t>(y) * width + x] = 1.0f;
          }
        }
      }
    }
    return;
  }

  /*
   * ★★★ 2026-09-30 分带快路径（判据 1 归因后加）
   *
   * 实测（`.probe/bench/t51_blur_bench.cpp`）：
   *   1328x848 : 这个循环 7.30 ms = 整次重建的 29.7%（第二大热点）
   *   2584x1464: 23.14 ms = 26.5%
   *
   * 贵的**不是**圆角判定，而是它对**每一个**像素都做一遍 double 数学，
   * 而绝大多数像素的答案是"平凡的"：
   *   * 行：`y < y0 || y > y1` ⇒ 整行保持 0（向量已经清零）
   *   * 列：`x ∈ [x0+radius, x1-radius]` ⇒ clamp 是恒等 ⇒ `dx == 0`
   *     ⇒ 判定退化成 `dy*dy <= radius*radius`，而 y 已在 [y0,y1] 内
   *     ⇒ **恒为真** ⇒ 这一整段可以直接写 1.0f
   *   * 只剩四个角附近的两条竖带需要**逐像素**判定（保留原表达式）
   * ⇒ 每像素的 double 数学只发生在约 `2*radius` 列上，其余走整数赋值。
   *
   * ★ 为什么敢说"逐位相同"：中间带被证明恒为 1.0f；两个角带保留**逐字**
   *   原表达式 ⇒ 浮点结果不变。探针在 7 组尺寸 × 3 个 scale = 21 组上逐
   *   float `memcmp` ⇒ 全部 identical。
   */
  const int ix_lo = static_cast<int>(std::ceil(x0));
  const int ix_hi = static_cast<int>(std::floor(x1));
  const int mid_lo = std::max(ix_lo, static_cast<int>(std::ceil(x0 + radius)));
  const int mid_hi = std::min(ix_hi, static_cast<int>(std::floor(x1 - radius)));

  for (int y = 0; y < height; ++y) {
    if (y < y0 || y > y1) {
      continue;  // 整行都在圆角矩形之外 ⇒ 保持 0
    }
    const double cy = std::min(std::max(static_cast<double>(y), y0 + radius),
                               y1 - radius);
    const double dy = y - cy;
    float* row = &alpha[static_cast<size_t>(y) * width];
    for (int x = mid_lo; x <= mid_hi; ++x) {
      row[x] = 1.0f;  // 已证：dx == 0 且 dy*dy <= radius*radius
    }
    for (int x = ix_lo; x <= std::min(mid_lo - 1, ix_hi); ++x) {
      const double cx = std::min(std::max(static_cast<double>(x), x0 + radius),
                                 x1 - radius);
      const double dx = x - cx;
      if (dx * dx + dy * dy <= radius * radius) {
        row[x] = 1.0f;
      }
    }
    for (int x = std::max(mid_hi + 1, ix_lo); x <= ix_hi; ++x) {
      const double cx = std::min(std::max(static_cast<double>(x), x0 + radius),
                                 x1 - radius);
      const double dx = x - cx;
      if (dx * dx + dy * dy <= radius * radius) {
        row[x] = 1.0f;
      }
    }
  }
}

/// 高斯模糊（对单通道 float 缓冲）—— ★ 大 sigma 走**降采样**快路径
///
/// ═══════════════════════════════════════════════════════════════════════
/// ★★★ 为什么要有快路径（2026-09-25，用户报「放大缩小非常卡顿」）
/// ═══════════════════════════════════════════════════════════════════════
///
/// # 实测的代价（`.probe/resize_cost.py`，三配置 A/B/C 分解）
///
/// ```text
/// A  region + 阴影（用户实际跑的）  190.9 ms/次缩放
/// B  只有 region（关阴影）           41.1 ms/次
/// C  两者都关                        35.4 ms/次
/// ─────────────────────────────────────────────
/// A - B = 149.7 ms/次  ⇒ ★ **阴影（本文件）占 78%**
/// B - C =   5.7 ms/次  ⇒ 圆角 region 只占 3%
/// ```
/// ⇒ ★ 用户「**放大 缩小 非常卡顿**」的主体**就在这里**，
///   而**不是**在 region 那边（那边我加了缓存，实测对缩放无效）。
///
/// # 原实现的规模（算出来的，可复核）
///
/// ```text
/// 位图   = (1280+48) × (800+48) = 1328 × 848 = 1,126,144 px
/// sigma  = 8.0 ⇒ radius = sigma*3 = 24 ⇒ 核 49 taps
/// 两趟   = 2 × 1,126,144 × 49 ≈ **1.1 亿次乘加**
/// ★ 垂直趟跨行步长 1328 float = 5.3 KB ⇒ 每次 tap 几乎必然 cache miss
/// ```
/// ⇒ 150 ms/次 与这个规模吻合（水平趟顺序访问、垂直趟随机访问）。
///
/// # 快路径原理：阴影是**低频**的
///
/// 阴影是 sigma=8px 的高斯渐变 —— 它的**最高空间频率远低于像素级**。
/// 所以完全可以：**降采样 → 在同比例的小图上用同样的高斯 → 双线性放大**。
/// ```text
/// factor = 4 时：小图 332×212 = 70,384 px
///                radius = 24/4 = 6 ⇒ 13 taps
///                2 × 70,384 × 13 ≈ 183 万次（**降 60 倍**）
/// ```
/// ★ 关键：sigma 同时除以 factor ⇒ **模糊的物理半径不变**（仍是 8 逻辑像素），
///   所以放大回来后形状与精确版一致（数值证明见 `.probe/blur_ab.py`）。
///
/// ⚠️ factor=1（sigma 小）时退回精确版 —— 小 sigma 下小图精度不足，
///    而且它本来就便宜，没必要冒险。
///
/// ⚠️ `SOURIN_WIN_SHADOW_FAST=0` 强制走精确版（A/B 对照用）。
void GaussianBlur(std::vector<float>& data, int w, int h, double sigma) {
  if (sigma <= 0.0) {
    return;
  }
  /*
   * 降采样因子：sigma 越大越划算，但也越"本来就低频"。
   * 要求 sigma/factor >= 2 ⇒ 小图里仍有足够宽的核（否则退化成一个点模糊）。
   */
  int factor = 1;
  if (sigma >= 8.0) {
    factor = 4;
  } else if (sigma >= 4.0) {
    factor = 2;
  }
  static const bool fast = [] {
    char buf[8] = {};
    const DWORD n = ::GetEnvironmentVariableA("SOURIN_WIN_SHADOW_FAST", buf,
                                              sizeof(buf));
    return n == 0 || n >= sizeof(buf) || buf[0] != '0';
  }();
  if (factor <= 1 || !fast) {
    GaussianBlurExact(data, w, h, sigma);
    return;
  }

  /*
   * ⚠️⚠️ 变量名**不能**叫 `small` —— `windows.h`（经 `rpcndr.h`）里有
   *      `#define small char`（MIDL 的历史遗留宏）。
   *      实测报错：
   *      ```text
   *      GaussianBlurExact(small, sw, sh, sigma / factor);
   *        error C2059: 语法错误:“,”        ← `small` 被展开成 `char`
   *      UpsampleAlphaBilinear(small, ...);
   *        error C2144: 语法错误:“char”的前面应有“)”
   *      ```
   *      ⇒ 这是**预处理器宏**，编译器不会提示"宏展开"，只能靠认出来。
   *      同理危险的名字还有 `hyper`、`near`/`far`（旧式）。
   */
  std::vector<float> lowres;
  int sw = 0;
  int sh = 0;
  DownsampleAlpha(data, w, h, factor, lowres, &sw, &sh);
  GaussianBlurExact(lowres, sw, sh, sigma / factor);
  UpsampleAlphaBilinear(lowres, sw, sh, factor, data, w, h);
}

/// 阴影窗口的消息处理 —— 接**两个**挂在阴影窗口上的定时器。
///
/// ```text
/// 原先 lpfnWndProc = DefWindowProcW（"阴影窗口不需要处理任何消息"），
/// 但定时器必须有个消息入口：定时器挂在阴影窗口上，WM_TIMER 会被
/// 主消息循环（main.cpp 的 GetMessage/DispatchMessage）投递到这里。
/// ★ 与 win32_window.cpp 的自愈定时器同一机制（那个已被日志证明可达）。
///
/// 两个 id 是**并列**关系，不是复用关系：
///   0x5A01 首帧兜底（一次性，1500ms 后放行）
///   0x5A02 逐帧重同步（有界，最多 kResyncTicks 拍）
/// 所以这里必须按 wparam 分派，不能只判 message == WM_TIMER。
/// ```
LRESULT CALLBACK ShadowWindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) {
  if (message == WM_TIMER && wparam == kFirstFrameFallbackTimerId) {
    WindowShadow::Instance().OnFirstFrameFallbackTimeout();
    return 0;
  }
  if (message == WM_TIMER && wparam == kResyncTimerId) {
    WindowShadow::Instance().OnResyncTimeout();
    return 0;
  }
  return ::DefWindowProcW(hwnd, message, wparam, lparam);
}


}  // namespace

WindowShadow& WindowShadow::Instance() {
  static WindowShadow instance;
  return instance;
}

WindowShadow::~WindowShadow() { DestroyShadowWindow(); }

bool WindowShadow::Enabled() {
  static const bool enabled = ReadEnabledFromEnv();
  return enabled;
}

void WindowShadow::Attach(HWND main_window) {
  if (main_window == nullptr || !Enabled()) {
    return;
  }
  main_ = main_window;
  if (shadow_ == nullptr) {
    if (!CreateShadowWindow()) {
      return;  // 失败不抛：阴影是锦上添花
    }
  }
  Update();
}

void WindowShadow::Update() {
  if (shadow_ == nullptr || main_ == nullptr || !::IsWindow(main_)) {
    return;
  }
  if (!::IsWindowVisible(main_) || ::IsIconic(main_)) {
    // 主窗口不可见 ⇒ 阴影也藏起来（否则最小化后屏幕上留一块阴影）
    ::ShowWindow(shadow_, SW_HIDE);
    return;
  }

  // ★ 首帧兜底的**布防点**：主窗口首次变为可见（不是 Attach —— 见
  //   kFirstFrameFallbackMs 顶部对"起点"的说明）。
  if (!first_frame_ready_ && !fallback_armed_) {
    if (::SetTimer(shadow_, kFirstFrameFallbackTimerId, kFirstFrameFallbackMs,
                   nullptr) != 0) {
      fallback_armed_ = true;
    } else {
      // ★ 布防失败 ⇒ 不能冒"永远没有阴影"的险：直接放行（退化成旧行为）
      std::printf(
          "[SHADOW] fallback timer could not be armed -> gate released\n");
      std::fflush(stdout);
      first_frame_ready_ = true;
    }
  }

  RECT rect = {};
  ::GetWindowRect(main_, &rect);
  const int w = rect.right - rect.left;
  const int h = rect.bottom - rect.top;
  if (w <= 0 || h <= 0) {
    return;
  }

  // DPI 缩放（阴影位图按物理像素画）
  HDC screen = ::GetDC(nullptr);
  const int dpi = screen != nullptr ? ::GetDeviceCaps(screen, LOGPIXELSX) : 96;
  if (screen != nullptr) {
    ::ReleaseDC(nullptr, screen);
  }
  const double scale = dpi / 96.0;

  const int margin = static_cast<int>(kShadowMargin * scale + 0.5);
  const int bw = w + margin * 2;
  const int bh = h + margin * 2;

  // 尺寸变了才重建位图（这是性能关键：只在 resize 时重算高斯模糊）
  if (bw != width_ || bh != height_ || bitmap_ == nullptr) {
    if (!BuildBitmap(bw, bh)) {
      return;
    }
    width_ = bw;
    height_ = bh;
  }

  // ★ 首帧门控：客户区画出第一帧之前**只定位、不显示**。
  //   否则用户看到的是"先一块阴影、再出现客户端"（实测阴影比首帧早 187.1ms
  //   可见）。放行入口见 NotifyFirstFrameReady / kFirstFrameFallbackMs。
  const UINT flags =
      first_frame_ready_ ? (SWP_NOACTIVATE | SWP_SHOWWINDOW) : SWP_NOACTIVATE;

  // ★ 顺序：先定位再显示。
  //   反过来会让阴影在旧位置闪一帧（用户能看到"拖影"）。
  ::SetWindowPos(shadow_, main_, rect.left - margin, rect.top - margin, bw, bh,
                 flags);
}

void WindowShadow::NotifyFirstFrameReady() {
  if (first_frame_ready_) {
    return;  // ★ 幂等（SetNextFrameCallback 本身就是一次性的，这是防御）
  }
  first_frame_ready_ = true;
  if (fallback_armed_ && shadow_ != nullptr) {
    ::KillTimer(shadow_, kFirstFrameFallbackTimerId);
    fallback_armed_ = false;
  }
  // 首帧就绪这一刻不一定有新的 WM_SIZE/WM_WINDOWPOSCHANGED ⇒ 自己补一次
  Update();
}

void WindowShadow::OnFirstFrameFallbackTimeout() {
  if (shadow_ != nullptr) {
    ::KillTimer(shadow_, kFirstFrameFallbackTimerId);
  }
  fallback_armed_ = false;
  if (first_frame_ready_) {
    return;  // 正常路径已放行，只是定时器还没来得及杀
  }
  first_frame_ready_ = true;
  // ★ 超时必须留痕：否则我们不知道兜底是否生效（全项目 C++ 日志都是 ASCII）
  std::printf(
      "[SHADOW] first-frame fallback fired after %u ms -> showing shadow "
      "anyway\n",
      static_cast<unsigned>(kFirstFrameFallbackMs));
  std::fflush(stdout);
  Update();
}

void WindowShadow::NotifySizeChangeInFlight() {
  // ★ 门控：阴影窗口还没有 / 首帧还没放行 => 不需要逐帧重同步
  //   （首帧之前 Update() 本来就只定位不显示，补节奏没有意义）
  if (shadow_ == nullptr || !first_frame_ready_) {
    return;
  }
  resync_tick_ = 0;  // 可续期：拖动时每帧都会进这里，拍数不断归零
  if (resync_armed_) {
    return;  // ★ 已在布防中：只重置拍数，绝不重复 SetTimer
  }
  if (::SetTimer(shadow_, kResyncTimerId, kResyncIntervalMs, nullptr) != 0) {
    resync_armed_ = true;
  }
  // 失败不抛：逐帧重同步是锦上添花（与 Attach 里 CreateShadowWindow 失败同策略）
}

void WindowShadow::OnResyncTimeout() {
  if (++resync_tick_ >= kResyncTicks) {
    if (shadow_ != nullptr) {
      ::KillTimer(shadow_, kResyncTimerId);
    }
    resync_armed_ = false;
    resync_tick_ = 0;
  }
  // ★ 直接复用 Update()：它的「尺寸没变就复用位图」短路保证
  //   没有真实尺寸变化时每拍只花一次 GetWindowRect + SetWindowPos
  Update();
}

void WindowShadow::Detach() {
  DestroyShadowWindow();
  main_ = nullptr;
}

bool WindowShadow::CreateShadowWindow() {
  static const wchar_t kClassName[] = L"SourinShadowWindow";

  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(wc);
  // ★ 自定义 proc：只为接**首帧兜底定时器**（WM_TIMER）。
  //   原先是 DefWindowProcW（"阴影窗口不需要处理任何消息"），
  //   但兜底必须有个消息入口 —— 见 kFirstFrameFallbackMs。
  wc.lpfnWndProc = &ShadowWindowProc;
  wc.hInstance = ::GetModuleHandleW(nullptr);
  wc.lpszClassName = kClassName;
  // ★ 幂等：类已注册时 RegisterClassExW 返回 0 + ERROR_CLASS_ALREADY_EXISTS
  if (::RegisterClassExW(&wc) == 0 &&
      ::GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    return false;
  }

  /*
   * ★★★ 样式位的选择（每一个都有理由）
   *
   * ```text
   * WS_EX_LAYERED       —— 必须。UpdateLayeredWindow 的前提
   * WS_EX_TOOLWINDOW    —— 不在任务栏/Alt-Tab 里出现
   * WS_EX_NOACTIVATE    —— 点击阴影不抢焦点（否则主窗口会失焦）
   * WS_EX_TRANSPARENT   —— ★ 鼠标穿透。阴影区域在【主窗口外】，
   *                        若不吃穿透，用户点"窗口边缘外一点"会被阴影吃掉
   * WS_POPUP            —— 无标题栏
   * ```
   */
  shadow_ = ::CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT,
      kClassName, L"", WS_POPUP, 0, 0, 0, 0, nullptr, nullptr,
      ::GetModuleHandleW(nullptr), nullptr);
  return shadow_ != nullptr;
}

bool WindowShadow::BuildBitmap(int width, int height) {
  if (bitmap_ != nullptr) {
    ::DeleteObject(bitmap_);
    bitmap_ = nullptr;
    bits_ = nullptr;
  }

  HDC screen = ::GetDC(nullptr);
  if (screen == nullptr) {
    return false;
  }
  HDC mem = ::CreateCompatibleDC(screen);

  BITMAPINFO bmi = {};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = width;
  bmi.bmiHeader.biHeight = -height;  // 负 = 自上而下
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HBITMAP bmp = ::CreateDIBSection(mem, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (bmp == nullptr || bits == nullptr) {
    if (bmp != nullptr) {
      ::DeleteObject(bmp);
    }
    ::DeleteDC(mem);
    ::ReleaseDC(nullptr, screen);
    return false;
  }

  // -- 1) 圆角矩形的硬边 alpha ------------------------------------------
  HDC screen2 = screen;  // 复用，避免重复取 DC
  const int dpi = ::GetDeviceCaps(screen2, LOGPIXELSX);
  const double scale = dpi / 96.0;
  const int margin = static_cast<int>(kShadowMargin * scale + 0.5);
  const double radius = kCornerRadius * scale;

  std::vector<float> alpha;
  BuildCornerMask(alpha, width, height, margin, radius);

  // -- 2) 高斯模糊 ------------------------------------------------------
  GaussianBlur(alpha, width, height, kShadowSigma * scale);

  // -- 3) 组装 32bpp premultiplied BGRA（纯黑阴影）-----------------------
  /*
   * ★ premultiplied：B=G=R=0 时，预乘后的颜色仍是 0，所以只需写 alpha。
   *   若将来要改成"彩色阴影"，这里要写 `color * alpha`。
   */
  std::memset(bits, 0, static_cast<size_t>(width) * height * 4);
  auto* px = static_cast<unsigned char*>(bits);
  for (size_t i = 0; i < alpha.size(); ++i) {
    double a = alpha[i] * kShadowAlpha;
    a = std::min(1.0, std::max(0.0, a));
    px[i * 4 + 3] = static_cast<unsigned char>(a * 255.0 + 0.5);
  }

  // -- 4) UpdateLayeredWindow -------------------------------------------
  HGDIOBJ old = ::SelectObject(mem, bmp);

  // ★★★ pptDst 必须是 **NULL**：位置由 Update() 末尾的 SetWindowPos 负责。
  //     传 &dst（哪怕 dst = {0,0}）会让 UpdateLayeredWindow 把阴影窗口
  //     **移到屏幕 (0,0)**，下一行的 SetWindowPos 才把它放回去 ⇒ 中间阴影
  //     真的在左上角闪一整块（实测 830 个"可见且在 (0,0)"样本）。
  //     MS Learn: "If the current position is not changing, pptDst can be NULL."
  // ★★★ SIZE 是 8 字节（两个 LONG），不是 4 字节 ——
  //     原型第一版用 c_ulong 传 ⇒ 返回 0 / GetLastError=31。
  SIZE size = {width, height};
  POINT src = {0, 0};
  BLENDFUNCTION blend = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};

  const BOOL ok = ::UpdateLayeredWindow(shadow_, screen, nullptr, &size, mem,
                                        &src, 0, &blend, ULW_ALPHA);
  ::SelectObject(mem, old);
  ::DeleteDC(mem);
  ::ReleaseDC(nullptr, screen);

  if (ok == FALSE) {
    ::DeleteObject(bmp);
    return false;
  }
  bitmap_ = bmp;
  bits_ = bits;
  return true;
}

void WindowShadow::DestroyShadowWindow() {
  if (bitmap_ != nullptr) {
    ::DeleteObject(bitmap_);
    bitmap_ = nullptr;
    bits_ = nullptr;
  }
  if (shadow_ != nullptr) {
    ::DestroyWindow(shadow_);  // 定时器随窗口销毁
    shadow_ = nullptr;
  }
  // ★ 窗口没了，定时器也就没了 ⇒ 布防标记必须复位（否则重建窗口后
  //   会以为兜底还在，而实际上永远不会触发）
  fallback_armed_ = false;
  // ★ 同理：逐帧重同步定时器也随窗口销毁 => 布防标记与拍数必须一起复位
  //   （否则重建窗口后 resync_armed_ 仍是 true，就永远不会再布防）
  resync_armed_ = false;
  resync_tick_ = 0;
  // ★ 门控状态与窗口同生命周期：重建窗口后必须重新等首帧（兜底仍在）
  first_frame_ready_ = false;
  width_ = 0;
  height_ = 0;
}

}  // namespace sourin
