----
可复现的构建脚本 + 综合与实现报告
----

## 一键重建

```bash
bash build/tools/rebuild_all.sh              # 全清缓存 → HLS → Vivado → 校验产物
bash build/tools/rebuild_all.sh --upload     # 再传板 + 核 md5
```

**前置**：Vitis + Vivado **2025.2**，器件 `xc7z020clg400-1`（PYNQ-Z2）。
耗时 **20–40 分钟**。

> ⚠ **为什么必须用脚本、不能手敲两条命令** —— 三个坑它都堵了：
>
> 1. HLS 导出的 IP **版本号永远叫 `1.0`** → 新旧实现 VLNV 相同
>    → Vivado 取了旧 IP **不报错，默默用错实现**
> 2. `gesture_comp/`（HLS 产物）不在仓库里，且工程下有**三处** IP 缓存
> 3. 脚本**硬性校验三条**，缺一条 `exit 1`：
>    `use_ila=0` / DMA `c_sg_length_width=24` / 时序两侧为正

只想看 BD 是否合法（约 1 分钟，不跑综合）：

```bash
vivado -mode batch -source build/vivado/create_project.tcl -tclargs --synth 0
```

## 综合与实现报告 —— 资源占用 / 时钟频率 / 关键性能指标

| 指标 | 值 | 出处 |
|---|---|---|
| **时序** | WNS **+0.198** / WHS **+0.051** ns，`All user specified timing constraints are met` | 2026-09-25 实现后 |
| **时钟** | 目标 **100 MHz**；HLS 流水线 csynth 估 **143.31 MHz**（`morph_stage` 阶段）/ **122.95 MHz**（全设计） | csynth 报告 |
| **吞吐** | 单帧 **0.006 s**（板上实测，640×480 → 96×96）；所有 HLS 循环 `II = 1` | 2026-09-25 板测 |
| **资源** | Slice LUT **48.38%** / LUT as Logic 46.75% / Block RAM **18.21%** | `utilization.rpt` |
| **DRC** | 0 Errors | 实现日志 |
| **规模** | 640×480 RGB565 输入 → 96×96 uint8 输出（9216 B） | 接口契约 |

> ⚠ **WNS 逐次波动大**（历史 +0.873 / +1.177 / +0.265 / +0.198）——
> 布线是随机过程，别拿单次值当"设计好坏"。
>
> ⚠⚠ **且该 WNS 属于 AMD `v_tc` IP 内部，不是本设计的余量**：
> 全设计 10 条最差 setup 路径**全部在 `v_tc` 里**（一条布线 9.1 ns、
> 逻辑仅 0.64 ns、扇出 433 的网），改我们的 RTL / HLS 对它零影响。
> 本设计自己的流水线余量是 **+43%**（`morph_stage`）。
> 详见 `build-report.md` §4.5。

## 目录

| 路径 | 内容 |
|---|---|
| `tools/rebuild_all.sh` | 一键重建脚本 |
| `vivado/create_project.tcl` | 建工程 → 建 BD → 综合 → 实现 → 比特流 → 导出 XSA |
| `vivado/bd_video.tcl` | Block Design 构建（含 19 条踩坑记录） |
| `vivado/constraints/video_io.xdc` | 引脚约束（**2026-09-22 按模块丝印重写**，原"镜像"推导全错） |
| `vivado/gesture_system/` | 工程源（BD / IP 配置 / `.xpr`）—— ⚠ **不含构建产物** |
| `vivado/test_*.tcl` | BD 合法性 / 约束的综合前检查 |
| `build-report.md` | **综合与实现报告** |
| `utilization.rpt` | 资源报告（原始输出） |

## ⚠ 构建产物在哪

`gesture_system.xsa`（含比特流 + `.hwh`）**不在本目录** ——
它是构建产物，跑一次 `rebuild_all.sh` 就会生成。

**要拿现成比特流上板**：xsa 是个 zip，解压即可，见
`report/docs/board-bringup-guide.md` §4.0。

> ⚠ **PYNQ 要的是 `.bit` + 改名后的 `.hwh`**：xsa 里那个文件叫
> `bd_video.hwh`，必须改名成 `gesture_system.hwh`。名字不一致时 PYNQ
> **不报「找不到 hwh」**，而是只认出 `default` 一个 IP，
> 然后 `g.ip['preproc']` 找不到 —— 现象很难往回追。

> ⚠ **`.hwh` 与 `.bit` 必须同时替换。** 只换一个（尤其只换 `.bit`）时
> PYNQ 不报错，只会静默降级成"只认出 `default`"。
