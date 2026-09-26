----
设计源码（RTL / HLS）
----

**PL 侧的「设计源码」就是这两块** —— 主机侧与 PS 侧的代码不在本目录内。

| 目录 | 内容 | 工具 |
|---|---|---|
| `HLS/` | 图像预处理链（crop_scale → 高斯 → Sobel → 阈值 → 形态学） | Vitis HLS (C++) |
| `RTL/` | 手写 Verilog：DVP 采集 / SCCB 主控 / 异步 FIFO / IOBUF / 配置 ROM | Verilog |

## HLS/ —— 唯一的计算 IP

`gesture_preproc.cpp` 内含全部 5 个阶段，导出为单一 IP `user:hls:gesture_preproc:1.0`。

```
RGB565 640x480 ─► crop_scale ─► 96x96 ─┬─► gaussian ─► sobel ─► thresh ─► morph ─► 96x96
                 ★几何在最前★
```

⚠ **几何处理放最前**是关键设计：昂贵算子只在小图上跑，**算力差 33 倍**。
所有流水线阶段 `II = 1`。

`gesture_preproc.h` 是**对外契约**（寄存器映射 / 几何常量），被三处共享：
本目录的 `.cpp` / TB / 参考实现。

> ⚠ PS 侧驱动**不 include** 这个头文件，只**同步常量副本**。
> 改这里的几何常量或寄存器偏移，要同步改 PS 侧那份副本。

`gesture_ref.cpp` 是各阶段的分离参考实现，`tb_gesture.cpp` 是对拍 TB。

## RTL/ —— 手写外设

| 文件 | 作用 | TB |
|---|---|---|
| `dvp_capture.v` | OV5640 DVP 并行采集 | `tb/tb_dvp_capture.v` |
| `sccb_master.v` | SCCB(I2C) 主控，配置 OV5640 | `tb/tb_sccb_master.v` |
| `ov5640_regs.v` | 250 条寄存器配置 ROM（脚本生成，**勿手改**） | `tb/tb_ov5640_regs.v` |
| `async_fifo.v` | 跨时钟域（PCLK → 100 MHz） | — |
| `iobuf_wrap.v` | 双向 SDA 的 IOBUF 封装 | — |

`run_iverilog.sh` 是这三个 TB 的回归入口（**秒级，无需 license**，已挂 CI）。

> ⚠ **改 `ov5640_regs.v` 的 `N_REGS` 必须同步改 BD 里 `sccb_0` 的 `N_REGS`**
> —— 不同步的话 SCCB 配到一半就停。

> ⚠ 引脚约束在 `build/vivado/constraints/video_io.xdc`，
> **改引脚要同步改** `report/docs/hardware-checklist.md` 的引脚表。

## ⚠ 改之前先读

`report/docs/architecture-contract.md` —— 里面记了**哪些方案被否掉了、为什么**，
避免重复论证。
