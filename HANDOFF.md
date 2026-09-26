# 交接说明 —— 第一次打开请看这一页

> **这份文件只解决一个问题**：你刚拿到这个仓库，**从哪开始**。

---

## 零、这个项目是什么

**2026 全国大学生嵌入式芯片与系统设计竞赛 · AMD 赛道 · 自主选题 · 初级组**。

一块 **PYNQ-Z2**（XC7Z020）上跑**手势识别的图像预处理链**：

```
OV5640 摄像头 ─► PL 预处理链 ─► 96×96 灰度写进 DDR ─► （PS 侧 CNN）
                 本工程                     ↑ 两侧唯一边界：9216 字节
```

**本工程的范围：PL 侧**（Verilog / HLS / BD / 约束 / 报告）。

---

## ⚠ 先看这两条边界（别多找）

### 1. 本目录**不含 Python**

PL 的交付物是**比特流 + `.hwh` + 报告**，都是语言无关的。
**主机侧与 PS 侧的 Python 由其他人维护，不在本目录内。**

所以这里**没有**：PC 侧 golden 参考实现、板上驱动、数据转换脚本、
上板脚本。需要它们请联系 PS 侧负责人。

### 2. 本目录**不含比特流**

`gesture_system.xsa`（含 `.bit` + `.hwh`）是**构建产物**，
跑一次 `build/tools/rebuild_all.sh` 就会生成。

**要拿现成比特流上板**：xsa 是个 zip，解压即可 ——
见 `report/docs/board-bringup-guide.md` §4.0。

> ⚠ **PYNQ 要的是 `.bit` + 改名后的 `.hwh`**：xsa 里那个文件叫
> `bd_video.hwh`，必须改名成 `gesture_system.hwh`。名字不一致时 PYNQ
> **不报「找不到 hwh」**，而是只认出 `default` 一个 IP，现象很难往回追。

---

## 一、先做这一步（**不需要 license，秒级**）

不管你想干什么，先确认这个工程在你机器上是活的：

```bash
# 在仓库根目录
bash src/RTL/run_iverilog.sh
```

**期望看到**：

```
回归汇总: 3 通过, 0 失败
*** ALL RTL TESTS PASSED ***
```

这**不需要 Vivado license、不需要板子**，秒级完成。

> 它**已经挂进 CI**（`.github/workflows/`）。你 push 之后看仓库的
> **Actions** 页 —— 那就是赛题 §3.3.4「保证工程可由他人从零复现」的
> **直接证据**，比文档里写"验证过了"有力。

---

## 二、按你的目的选一条路

### 🅰 我要**跑出比特流 / 上板**

```bash
bash build/tools/rebuild_all.sh              # 全清缓存 → HLS → Vivado → 校验（20–40 min）
bash build/tools/rebuild_all.sh --upload     # 再传板 + 核 md5
```

**前置**：Vitis + Vivado **2025.2**，器件 `xc7z020clg400-1`。

> ⚠ **为什么必须用脚本、不能手敲两条命令** —— 三个坑它都堵了：
>
> 1. HLS 导出的 IP **版本号永远叫 `1.0`** → 新旧实现 VLNV 相同
>    → Vivado 取了旧 IP **不报错，默默用错实现**
> 2. `gesture_comp/`（HLS 产物）不在仓库里，且工程下有**三处** IP 缓存
> 3. 脚本**硬性校验三条**：`use_ila=0` / DMA 位宽 24 / 时序两侧为正

**详细的**：`report/docs/board-bringup-guide.md`（上电前必读）

### 🅱 我要**改 PL 代码**

先读 **`report/docs/architecture-contract.md`** ——
里面记了**哪些方案被否掉了、为什么**，避免你重复论证。

改之前要知道的几件事：

| 你改这里 | 必须同步改 |
|---|---|
| `src/HLS/gesture_preproc.h` 的几何/寄存器常量 | PS 驱动的**常量副本**（该文件**不 include** 这个头文件） |
| `src/HLS/gesture_preproc.h` 或 `.cpp` 的**实现** | ⚠ **必须全清重建** —— IP 版本号不变，Vivado 会用旧的 |
| `src/RTL/*.v` 的端口 | 对应 TB 与 `build/vivado/bd_video.tcl` 的连线 |
| `build/vivado/constraints/video_io.xdc` 的引脚 | `report/docs/hardware-checklist.md` 的引脚表 |
| `src/RTL/ov5640_regs.v` 的 `N_REGS` | ⚠ BD 里 `sccb_0` 的 `N_REGS`（必须同为 250） |

### 🅲 我要**看验证怎么做**

判据分三层，每层的通过标记与**它证明不了什么**都在源码注释里：

| 层 | 命令 | 通过标记 |
|---|---|---|
| RTL 模块 | `bash src/RTL/run_iverilog.sh` | `*** ALL RTL TESTS PASSED ***` |
| HLS 处理链 | 随 `rebuild_all.sh` 自动跑 csim | `TB PASSED` |
| PS 驱动控制流 | `bash src/sw/build_preproc_sim.sh` | `*** PREPROC DRIVER SIM PASSED ***` |

> ⚠ **三个坑都写在源码注释里**，读的时候别跳过：
> `src/RTL/README.md`（跨域 FIFO 的判据）、`src/HLS/README.md`
> （**csim 全绿但实现是错的**那种）、`src/sw/README.md`
> （`preproc_sim.c` 是**朴素 C 实现**，只证"数据流没断"，
> **不证 PL 算得对** —— 别把它当上板证明）。

---

## 三、目录说明

| 目录 | 内容 |
|---|---|
| **`src/HLS/`** | 图像预处理链（`gesture_preproc.cpp`）+ 参考实现 + csim TB + 综合脚本 |
| **`src/RTL/`** | Verilog：DVP 采集 / SCCB / 异步 FIFO / IOBUF / 配置 ROM + 回归脚本 |
| **`src/sw/`** | PS 侧 C 驱动（`preproc_driver.c/.h`）+ 主机自检 |
| **`build/`** | 一键构建、BD 与约束 Tcl、**综合实现报告**、资源报告 |
| **`data/`** | 测试向量（输入帧 + **硬件实测对过的** golden） |
| **`sim/tb/`** | 各模块的 testbench（**跟着源码放**：HLS 的在 `src/HLS/`） |
| **`skill/`** | 踩坑清单 / 纠错方法论 |
| **`report/`** | 设计报告 + 大模型协作记录 + `docs/`（工程过程文档） |

> ⚠ 本仓库**不含 `host/` 与 `scripts/`** —— 那是 **Python 侧**
> （PC 侧 golden、板上驱动、数据转换、文档生成脚本）。
> 见开头「两处边界」。`.github/workflows/` 里因此只有 2 个 job，不是漏配。

**`report/docs/` 里几份最该看的**：

| 文件 | 用途 |
|---|---|
| `architecture-contract.md` | 分工边界 + 数据契约 + **决策记录** |
| `board-bringup-guide.md` | 上板流程（含"没仪器时怎么办"） |
| `board-cheatsheet.md` | 板上日常操作速查 |
| `hardware-checklist.md` | 采购 + 引脚 + **上电前验证** |
| `board-test-log-2026-09-2{1,2,3}.md` | 三次上板实测记录 |

---

## 四、关键性能指标

| 指标 | 值 |
|---|---|
| 时序 | WNS **+0.079** / WHS **+0.050** ns（2026-09-26 含 HDMI）|
| 时钟 | 系统 **100 MHz** + 摄像头 24 MHz + **像素 74.25 MHz**；HLS 流水线 csynth 估 **143.31 MHz**（`morph_stage`）/ **122.95 MHz**（全设计） |
| 吞吐 | 单帧 **0.006 s**（板上实测）；所有循环 `II = 1` |
| 资源 | LUT **48.98%** / BRAM **18.21%** / DSP **27.73%** |
| 显示 | **1280×720@60 HDMI** —— ⚠ **尚未上板验证** |

> ⚠ **WNS 逐次波动大**（+0.873 / +1.177 / +0.265 / +0.198 / **+0.079**），布线是随机过程。
> 加 HDMI 后从 +0.198 降到 +0.079，仍是正的、0 失败端点。
> ⚠⚠ **且该 WNS 属于 AMD `v_tc` IP 内部，不是本设计的余量** ——
> 全设计 10 条最差 setup 路径**全部在 `v_tc` 里**。
> 详见 `build/build-report.md` §4.5。

---

## 五、当前状态（如实说明）

| 部分 | 状态 |
|---|---|
| HLS 处理链 | ✅ csim + csynth + cosim 全过，所有循环 `II = 1` |
| RTL 外设 | ✅ 3/3 TB PASSED |
| BD / 时序 / 比特流 | ✅ DRC 0 Errors |
| **静态图喂入** | ✅ **板上实测：与 golden 逐字节一致（0/9216）** |
| **摄像头通路** | ⚠ **未通**（卡在 SCCB，`cfg_error=1`）—— **已不是关键路径** |
| HDMI 输出 | ✅ **已实现 720p60** —— ⚠ **但尚未上板验证**（见下）|

> **一句话**：PL 侧功能已验证到**板上输出与 golden 逐字节一致**（静态图通路）。
> 摄像头是量程扩展，不是达标前提。

### HDMI 的现状（2026-09-26 更新：**通路已建好，待上板验证**）

**✅ 已完成（方案 B 全部实现）：**

| 加的 | 是什么 |
|---|---|
| `clk_wiz_pix` | 像素时钟 **74.25 MHz**（720p60），M=37.125/D=5/N=10 → VCO 742.5 MHz |
| `rgb2dvi_0` | Digilent TMDS 编码器，`kClkRange=2`（⚠ 默认 1 会锁不住） |
| `rgb565_888_0` | 手写 `src/RTL/axis_rgb565_888.v`：VDMA 16bit → vid_out 24bit |
| `rst_pix` | 像素域复位，`dcm_locked` 接 MMCM locked（否则静默黑屏） |

导出的端口从 22 根并行信号变成 **8 根 TMDS 差分对**（`hdmi_tmds_*`），
引脚约束在 `build/vivado/constraints/video_io.xdc` 第四层（TMDS_33）。
两个临时豁免文件（`video_io_hdmi_tmp.xdc` / `hdmi_drc_hook.tcl`）**已删除**。

**⚠ 尚未上板验证。** 构建通过 ≠ 显示正常。上板要按顺序：

1. **先证明 TMDS 能出图** —— PS 往 VDMA 帧缓冲写**标准彩条**，看显示器
2. 彩条正确后，再确认**帧率 60 Hz**（游戏需要）
3. 最后接队友的游戏渲染

⚠ 若**颜色不对**（尤其是绿蓝互换），几乎肯定是
`axis_rgb565_888.v` 的**位序**问题 —— rgb2dvi 要的是 **RBG** 不是 RGB
（见该文件头部的说明，那是从 rgb2dvi 源码查实、不是推测）。

⚠ 若**无信号**：查 `report_io` 看 `hdmi_tmds_*` 有没有 LOC
（引脚名写错时 XDC 是静默 no-op）。

---

## 六、⚠ 几条会咬人的（都实际踩过）

| 坑 | 一句话 |
|---|---|
| **`use_ila` 必须为 0** | 开着它会让 BRAM 涨到 52.5%，并引入 **WHS −1.830 ns** 跨异步域违例（物理修不了） |
| **`.hwh` 要改名** | 见 §零 |
| **改 HLS 实现后必须全清重建** | IP 版本号恒为 1.0，Vivado 会用旧的且不报错 |
| **AXI DMA 默认 `C_SG_LENGTH_WIDTH` = 14 位** | 单次只搬 16 KB，**"传输完成"照常置位**，下游静默卡死 |
| **换比特流后要清缓存 + 重启内核** | overlay 不会因为换了文件就失效 |

完整清单见根 `README.md` 与 `skill/pitfalls/`。

---

## 七、许可

Apache-2.0，见 `LICENSE`。
