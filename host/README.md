# host/ —— 板上运行的 PL 驱动与验证脚本

> ⚠ 这个目录**推翻了本工程原来的边界声明**（"本目录不含 Python"）。
> 理由见下。**是有意的，不是漏进来的。**

---

## 为什么这里会有 Python

`HANDOFF.md` 原本写着「本目录不含 Python —— PL 的交付物是比特流 + `.hwh` +
报告，语言无关」。那条边界**对 PC 侧的工具有效**：

- PC 侧 golden 参考实现、造数据、ROI 分析 → 仍在完整仓库的 `host/`
- CNN / 游戏逻辑 → 队友负责，不在这里

**但"调 PL 硬件"的驱动是另一回事** —— 它和比特流是**同一个交付物**的两面：
`.bit` 是硬件描述，驱动是**说怎么用它**。没有驱动，比特流没法验证。

所以本目录的范围是：

> **只在 PYNQ 板上运行、且用于驱动/验证 PL 的代码。**

（PS 侧的 C 驱动 `src/sw/` 同理，也在本仓库。）

---

## 目录内容

| 文件 | 作用 | 能在 PC 上跑吗 |
|---|---|---|
| `gesture_overlay.py` | **PL 驱动本体** —— `GesturePipeline` 类，封装预处理链 + 两个 DMA | ⚠ 不能（要真的 overlay），但可离线自检 |
| `test_overlay_offline.py` | 驱动**离线自检**（70 项），不进 pynq | ✅ 能（已挂 CI）|
| `usb_camera_run.py` | USB(UVC) 摄像头 → PL 预处理链 | ⚠ 探测模式能，喂数据不能 |
| `run_static_frame_on_board.py` | 静态图喂 DDR + 与 golden 对拍（最小示例）| ⚠ 不能 |
| `hdmi_bringup.py` | **HDMI 分步 bring-up**：配 v_tc → 配 vdma → 写彩条 | ⚠ 不能 |

**不在本目录**（属 PC 侧，仍在完整仓库）：`gesture_golden.py`（golden 参考实现）、
`auto_roi.py`、`capture_frame.py`、`bench_ps_baseline.py` 等。

---

## ⚠ 与完整仓库的重复问题（**必须知道**）

本目录的 `gesture_overlay.py` / `usb_camera_run.py` / `test_overlay_offline.py` /
`run_static_frame_on_board.py` **是从完整仓库 `complete_project_source/host/`
原样复制来的**（搬运时逐字节一致，md5 已核）。

**完整仓库里那 5 个消费者脚本**（`bringup_check.py` / `push.py` / `run.py`
/ `run_static_frame_on_board.py` / `test_overlay_offline.py`）**仍然 import 它**。

**∴ 现在有两份 `gesture_overlay.py`，改了会分叉。**

| 改了哪里 | 要做什么 |
|---|---|
| 在**本仓库**改了驱动 | **必须**同步回完整仓库（否则那边的脚本会用到旧驱动）|
| 在完整仓库改了驱动 | **必须**同步过来 |

⚠ 在解决之前，**改驱动后请比对两处 md5**：

```bash
md5sum host/gesture_overlay.py \
       /e/complete_project_source/host/gesture_overlay.py
```

> **根治方向**（尚未做，需要更大的决定）：让完整仓库的那 5 个消费者脚本
> 直接 import 本仓库的驱动（去掉副本），或者干脆把驱动职责整个收敛到一处。
> 现在这样做是因为**当时的任务只要求搬 `usb_camera_run.py`**，
> 而它依赖驱动 —— 所以驱动是跟着进来的，不是重新决定的。

---

## `hdmi_bringup.py` 用法

```bash
# 全部跑（阶段1 + 阶段2）
sudo -E /usr/local/share/pynq-venv/bin/python3 hdmi_bringup.py

# 只配时序（先看显示器认不认信号）
sudo -E /usr/local/share/pynq-venv/bin/python3 hdmi_bringup.py --stage 1

# 只写彩条
sudo -E /usr/local/share/pynq-venv/bin/python3 hdmi_bringup.py --stage 2
```

⚠ **必须 `sudo -E` + 写全 pynq-venv 的 python 路径** ——
`sudo` 会重置 PATH。（Jupyter 里不用，内核本来就是 root。）

### ⚠⚠ 烧完比特流显示器什么都不会有

`v_tc` / `vdma` 在 BD 里开了 AXI-Lite，按 AMD PG016 **必须用软件配置**
（寄存器复位后默认全 0）。**这不是坏，是正常的。**

| 阶段 | 做什么 | 期望看到 |
|---|---|---|
| **1** | 配 v_tc 720p60 + 使能发生器 | 显示器**识别到 1280×720@60**，但**画面是黑的** |
| **2** | 配 vdma + 写彩条 + 启动 | 出现**标准彩条** |

**阶段 1 是最大的坎** —— 过了说明 TMDS 编码 / 像素时钟 / 引脚**全对**。

### ⚠⚠ 彩条是位序的"试纸"

`src/RTL/axis_rgb565_888.v` 输出的是 **RBG 序**（不是常识的 R-G-B），
因为 Digilent rgb2dvi 的 `vid_pData` 就是 RBG。

**位序若写错，绿蓝会互换**，彩条变成（已用代码验证）：

| 正确 | 位序错 |
|---|---|
| **黄** | **品红** ← 一眼看出 |
| **绿** | **蓝** |
| **品红** | **黄** |
| **蓝** | **绿** |

（白/青/红/黑不变）

**只看"黄色条是不是变成品红"就够了。**
⚠ 若是**红蓝**互换 → DDR 里 RGB565 字节序反了，把 `IN_BYTE_SWAP` 置 1。

---

## `usb_camera_run.py` 用法

**USB 摄像头是绕开 DVP 硬件的一条输入路径**（DVP 仍卡在 SCCB 无 ACK）：

```
DVP 方案: 摄像头 --DVP--> PL(dvp_capture) --> 预处理链 --> DDR
USB 方案: 摄像头 --USB--> PS CPU --> DDR --> dma_in --> 预处理链 --> DDR
                                    ↑ 从"写进 DDR"这步起与方案 A 完全相同
⚠ PL 侧一行都不用改。
```

```bash
# ⚠ 先只探测摄像头，不碰 PL
sudo -E ... usb_camera_run.py --probe

# 采集一帧 → 喂进 PL 链 → 存输出
sudo -E ... usb_camera_run.py

# 连续 5 帧（看时序稳不稳）
sudo -E ... usb_camera_run.py --frames 5

# 顺便存下摄像头原始画面，肉眼确认取景
sudo -E ... usb_camera_run.py --save-preview p.png
```

> ⚠ **`--probe` 模式不需要 overlay**（`gesture_overlay` 是函数内 import 的），
> 所以在驱动还没就位时可以单独跑它排查摄像头。

⚠ **`--probe` 从未在任何机器上跑过**（截至 2026-09-26，摄像头尚未到手）。
第一次跑请从它开始。

---

## 寄存器来源（不猜）

`hdmi_bringup.py` 里所有寄存器偏移与位定义都有出处：

| IP | 来源 |
|---|---|
| `v_tc` | Xilinx 官方驱动 `xvtc_hw.h` / `xvtc.c`（embeddedsw 仓库）|
| `vdma` | Xilinx 官方驱动 `xaxivdma_hw.h` / `xaxivdma.c` |

⚠ 两处**极容易用错**，脚本里都标了：

1. **`XVtc_SetGenerator` 有 `OriginMode` 0/1 两个分支，算法不同**
   （mode 0 用 `HTotal+1`；mode 1 直接用各 Start 值）。
   驱动实际走 **mode 1**。用错分支寄存器值全错。
2. **VDMA 寄存器直通模式下 MM2S 的两块不连续**：
   控制块 `base+0x00`、参数块 `base+0x50`。写错地方**不报错**，只是静默不工作。

另外**没有**用头文件的 `XVTC_CTL_ALLSS_MASK` —— 实测它不含全部源选择位
（缺 `HBPSS`、却含 `INTERLACE` 位），改为逐位显式列出。

---

## 验证状态（如实）

| 脚本 | 状态 |
|---|---|
| `gesture_overlay.py` | ✅ 板上实测过（2026-09-21，11/11；09-23 与 golden 逐字节一致）|
| `test_overlay_offline.py` | ✅ 70 项全过（本机 + CI）|
| `run_static_frame_on_board.py` | ✅ 板上实测过（09-23 对拍）|
| `hdmi_bringup.py` | ⚠ **从未上板** —— 只验过语法、720p 寄存器推导、彩条生成 |
| `usb_camera_run.py` | ⚠ **从未跑过** —— 连 `--probe` 都没跑过（摄像头未到手）|
