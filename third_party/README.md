# third_party/ —— 第三方 IP（非本项目编写）

> ⚠ 本目录下的代码**不是本项目写的**，改之前先看这里的出处和许可。
> 放进仓库是为了**自包含**：赛题 §3.3.4 要求「工程可由他人从零复现」，
> 依赖仓库外的绝对路径会破坏这一条。

---

## digilent/ —— Digilent vivado-library（部分）

只取了 HDMI 输出需要的最小集合。

| 路径 | 是什么 |
|---|---|
| `digilent/rgb2dvi_v1_2/` | **RGB → DVI/HDMI TMDS 编码器**（VLNV `digilentinc.com:ip:rgb2dvi:1.2`）|
| `digilent/if/tmds_v1_0/` | rgb2dvi 依赖的 `tmds` 接口定义（`if/` 是 IP 仓库的接口子目录）|

**没取的**：`vid_io` / `clock` / `reset` 这几个接口是 **Xilinx 自带**的
（在 Vivado 安装目录里），不需要随仓库带。

### 来源

```
Digilent/vivado-library  →  ip/rgb2dvi_v1_2  +  ip/if/tmds_v1_0
```

本机取副本自（2026-09-26）：

```
C:\Users\xiaomu\Desktop\prepare\paulgeorge66_2025\src\yolov2\ip\
```

那是 **PYNQ base overlay** 的源码树，里面就带着一份完整的 Digilent IP 仓库。
它同时也是一个有用的**接线范例** —— `rebuild_100MHz.tcl` 里有 rgb2dvi
的实例化与连线写法（本项目 `bd_video.tcl` 的 HDMI 段参考了它）。

### 许可

**BSD 3-clause（Revised BSD）** —— 从 IP 源文件的版权头**逐字核实**的
（`rgb2dvi_v1_2/src/rgb2dvi.vhd` 开头）：

> `(c) 2014 Copyright Digilent Incorporated / All Rights Reserved`
>
> `This program is free software; distributed under the terms of BSD 3-clause
> license ("Revised BSD License", "New BSD License", or "Modified BSD License")`

**允许再分发**，条件是三条：

| 条件 | 本仓库是否满足 |
|---|---|
| ① 源码再分发必须保留版权声明、条件列表、免责声明 | ✅ **原样保留了源文件的版权头** |
| ② 二进制再分发须在文档中复制版权声明 | ✅ 本条即说明，随比特流一并交付 |
| ③ 不得用 Digilent 或其贡献者名义背书 | ✅ 未用于背书 |

> ⚠ 这条**很关键且是新增的**：本项目自身是 **Apache-2.0**，
> 而这里引入了 **BSD-3** 的第三方代码 —— **两种许可并存是允许的**
> （都属宽松许可，BSD-3 与 Apache-2.0 兼容），但**必须保留
> Digilent 的版权头**。**不要**因为"统一许可"而删掉那些头。

> ⚠ 上游 `Digilent/vivado-library` 仓库根有它自己的 LICENSE，但
> **IP 单文件也自带版权头** —— 以**文件头**为准（那就是再分发的依据）。

### 版本

| 项 | 值 |
|---|---|
| rgb2dvi | **1.2** |
| 依赖的 tmds 接口 | 1.0 |
| 上游最后修改 | 见 `component.xml` 内的 `xilinx_vhdlsynthesis` 校验和 |

---

## 本项目如何使用它

`build/vivado/create_project.tcl` 把它注册为**第二个 IP 仓库**：

```tcl
set_property ip_repo_paths [list $HLS_IP_DIR $REPO_ROOT/third_party/digilent] $PROJ
```

⚠ **两处都要设** —— `bd_video.tcl` 里还有一处会**覆盖**这个属性
（见该文件的 `IP_REPO` 处理），只改一处会被静默盖掉。

---

## ⚠ 一个已知的坑（别踩第二遍）

`rgb2dvi` 的 `kClkRange` 参数**默认值是 1**，对应
`CLKFBOUT_MULT_F = 5`，即 VCO = 像素时钟 × 5。

720p 的像素时钟是 74.25 MHz → VCO = **371.25 MHz**，
**低于 Zynq-7020 MMCM 的 600 MHz 下限 → 锁不住 → 无输出**。

**必须显式设 `kClkRange = 2`**（VCO = 742.5 MHz，落在 600–1200 内）。

依据：`digilent/rgb2dvi_v1_2/src/ClockGen.vhd` 的注释
「MULT_F = kClkRange*5 (choose >=120MHz=1, >=60MHz=2, >=40MHz=3)」。
