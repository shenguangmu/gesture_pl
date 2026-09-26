#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
hdmi_bringup.py —— HDMI 输出通路的板上分步验证（PYNQ-Z2 / gesture_pl）

=====================================================================
 这个脚本解决什么问题
=====================================================================
2026-09-26 把 HDMI 的**硬件通路**做完了（TMDS 编码器 rgb2dvi + 74.25MHz
像素时钟 + 位宽转换），比特流也构建通过。但烧进去**显示器不会亮** ——
因为 v_tc / vdma 都是**要在软件里配置**的 IP，不是烧完就有输出。

本脚本把"从烧完比特流到屏幕上出现彩条"之间的所有软件步骤串起来，
并**分阶段**执行，让每一步的成败都能单独判定。

=====================================================================
 分三个阶段（★ 按顺序，不要跳）
=====================================================================
  阶段 1  配置 v_tc 720p60 时序 + 使能发生器
          期望：显示器**识别到 1280×720@60 信号**并切过去，但**画面是黑的**
          ★ 这一关过了 = TMDS 编码/像素时钟/引脚**全对**，是最难的一关

  阶段 2  配置 vdma MM2S + 往帧缓存写标准彩条 + 启动
          期望：屏幕上出现**标准彩条**
          验证：颜色顺序（位序对不对）+ 有无撕裂（同步对不对）

  阶段 3  只显示不刷新（静态保持）—— 可选，用于截图/取证

=====================================================================
 ⚠⚠ 彩条是位序的"试纸" —— 这是本脚本最主要的价值
=====================================================================
`axis_rgb565_888.v` 输出的是 **RBG 序**（不是常识的 R-G-B），
因为 Digilent rgb2dvi 的 vid_pData 就是 RBG（源码 rgb2dvi.vhd:181
原文 "for some reason vid_data is packed in RBG order"）。

**如果位序搞错了**，绿蓝通道会互换，彩条会变成：

    正确            位序错（绿蓝互换）
    ─────           ─────────────────
    白              白（不变）
    黄              品红    ← 一眼就能看出
    青              青（不变）
    绿              蓝
    品红            黄
    红              红（不变）
    蓝              绿
    黑              黑（不变）

**所以只要看"黄色条是不是变成了品红"，就能判定位序对不对。**

⚠ 如果发现的是**红蓝**互换（不是绿蓝），那是另一回事 ——
  DDR 里 RGB565 的字节序反了，把 `axis_rgb565_888.v` 的参数
  `IN_BYTE_SWAP` 置 1 后重建。

=====================================================================
 用法（在 PYNQ 板上）
=====================================================================
    # 全部跑（阶段1 + 阶段2）
    sudo -E /usr/local/share/pynq-venv/bin/python3 hdmi_bringup.py

    # 只配时序（先看显示器认不认信号）
    sudo -E ... hdmi_bringup.py --stage 1

    # 只写彩条（时序已配好的情况下）
    sudo -E ... hdmi_bringup.py --stage 2

    # 指定 overlay
    sudo -E ... hdmi_bringup.py --bit /home/xilinx/gesture_system.bit

    # 换彩条样式 / 存一张参考图到 PC
    sudo -E ... hdmi_bringup.py --pattern bars

⚠ overlay 需与本脚本同目录（`gesture_system.bit` + `gesture_system.hwh`）。
⚠ 必须用 `sudo -E`：**`sudo` 会重置 PATH**，所以要写全 pynq-venv 的
  python 路径（Jupyter 里不用，内核本来就是 root）。

=====================================================================
 寄存器来源（全部有据可查，不是我推的）
=====================================================================
  · v_tc  ：Xilinx 官方驱动 `xvtc_hw.h` / `xvtc.c`（embeddedsw 仓库）
            各寄存器的组装逻辑逐行移植自 `XVtc_SetGenerator` 的
            **OriginMode=1 分支**（驱动实际走的就是这个分支）。
            ⚠ 那个函数有两个分支，算法不同 —— 用错分支寄存器值全错。
  · vdma ：Xilinx 官方驱动 `xaxivdma_hw.h` / `xaxivdma.c`
            寄存器直通模式（`c_include_sg=0`）：
            MM2S 的**控制块在 base+0x00**、**参数块在 base+0x50**
            （驱动里 `ChanBase = BaseAddr + TX_OFFSET(0x00)`、
             `StartAddrBase = BaseAddr + MM2S_ADDR_OFFSET(0x50)`）
            注意两者**不是**同一块连续区域，别混。

⚠ 本脚本**未经上板验证**（2026-09-26 写完即交付）。
  第一次跑请按阶段 1 → 阶段 2 分开跑，别一把梭。
"""

import argparse
import io
import os
import struct
import sys
import time

# ⚠ 这层 UTF-8 包装只在**真实控制台**需要，且必须加守卫。
#   Jupyter/IPython 的 sys.stdout 是 OutStream，**没有 .buffer**，
#   无条件包装会 AttributeError 崩掉 —— 而 %run 在 Jupyter 里是正常用法。
#   （沿用 host/ 下其它脚本的写法，见 usb_camera_run.py）
if hasattr(getattr(sys.stdout, 'buffer', None), 'write') \
   and getattr(sys.stdout, 'encoding', '').lower() not in ('utf-8', 'utf8'):
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8',
                                  errors='replace')

# =====================================================================
#  视频参数：720p60（CEA-861）
#
#  ⚠ 这批数值取自 Xilinx 官方驱动的 720p 模式表
#    （`xvtc.c` 的 `XVTC_VMODE_720P` 分支），不是我按常识写的。
#    总像素时钟周期 = 1650 × 750 × 60 = 74.25 MHz ✓ 与 clk_wiz_pix 一致
# =====================================================================
H_ACTIVE, H_FP, H_SYNC, H_BP = 1280, 110, 40, 220
V_ACTIVE, V_FP, V_SYNC, V_BP = 720, 5, 5, 20
HSYNC_POL = 1        # 高有效
VSYNC_POL = 1

H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP       # 1650
V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP       # 750

# 帧缓存：16bit RGB565，stride = 1280 × 2 = 2560 字节
STRIDE = H_ACTIVE * 2
FRAME_BYTES = STRIDE * V_ACTIVE                 # 1,843,200
N_FSTORES = 3                                   # BD 里 c_num_fstores=3


# =====================================================================
#  v_tc 寄存器（xvtc_hw.h）
# =====================================================================
VTC_CTL, VTC_ISR, VTC_VER = 0x000, 0x004, 0x010
VTC_GASIZE, VTC_GFENC, VTC_GPOL = 0x060, 0x068, 0x06C
VTC_GHSIZE, VTC_GVSIZE, VTC_GHSYNC = 0x070, 0x074, 0x078
VTC_GVBHOFF, VTC_GVSYNC, VTC_GVSHOFF = 0x07C, 0x080, 0x084
VTC_GVBHOFF_F1, VTC_GVSYNC_F1, VTC_GVSHOFF_F1 = 0x088, 0x08C, 0x090
VTC_GASIZE_F1 = 0x094

VTC_CTL_SW = 0x00000001        # 核使能
VTC_CTL_RU = 0x00000002        # 寄存器更新
VTC_CTL_GE = 0x00000004        # ★ 发生器使能
VTC_CTL_DE = 0x00000008        # 检测器使能
# 源选择位：让各信号由**本发生器**驱动（而不是外部引脚）
VTC_SRC_FIPSS, VTC_SRC_ACPSS, VTC_SRC_AVPSS = 0x04000000, 0x02000000, 0x01000000
VTC_SRC_HSPSS, VTC_SRC_VSPSS = 0x00800000, 0x00400000
VTC_SRC_HBPSS, VTC_SRC_VBPSS = 0x00200000, 0x00100000
VTC_SRC_VASS, VTC_SRC_VBSS, VTC_SRC_VSSS = 0x00020000, 0x00010000, 0x00008000
VTC_SRC_VFSS, VTC_SRC_VTSS = 0x00004000, 0x00002000
VTC_SRC_HBSS, VTC_SRC_HSSS = 0x00000800, 0x00000400
VTC_SRC_HFSS, VTC_SRC_HTSS = 0x00000200, 0x00000100
VTC_SRC_VCSS = 0x00040000

# ⚠ 不用头文件里的 XVTC_CTL_ALLSS_MASK(0x03FDEF00) ——
#   实测那个掩码**并不包含全部源选择位**（缺 HBPSS 0x00200000，
#   却含有 INTERLACE 位 0x00080000）。盲用它会让 HBlank 的来源不对。
#   下面显式列出要让发生器驱动的**全部信号**。
VTC_SRC_ALL = (VTC_SRC_AVPSS | VTC_SRC_ACPSS | VTC_SRC_FIPSS |
               VTC_SRC_HSPSS | VTC_SRC_VSPSS | VTC_SRC_HBPSS | VTC_SRC_VBPSS |
               VTC_SRC_HTSS | VTC_SRC_HFSS | VTC_SRC_HSSS | VTC_SRC_HBSS |
               VTC_SRC_VTSS | VTC_SRC_VFSS | VTC_SRC_VSSS | VTC_SRC_VBSS |
               VTC_SRC_VASS | VTC_SRC_VCSS)

# 极性寄存器（xvtc_hw.h）
VTC_POL_FIP, VTC_POL_ACP, VTC_POL_AVP = 0x40, 0x20, 0x10
VTC_POL_HSP, VTC_POL_VSP = 0x08, 0x04
VTC_POL_HBP, VTC_POL_VBP = 0x02, 0x01

# 编码寄存器
VTC_ENC_CPARITY_SHIFT = 8
VTC_ENC_CPARITY_MASK = 0x00000100
VTC_ENC_PROG_MASK = 0x00000040
VTC_ENC_PROG_SHIFT = 6

SB_START_MASK = 0x00003FFF      # 起始（低 16 位）
SB_END_MASK = 0x3FFF0000        # 结束（高 16 位）
SB_END_SHIFT = 16
ASIZE_HORI_MASK = 0x00003FFF
ASIZE_VERT_MASK = 0x3FFF0000
ASIZE_VERT_SHIFT = 16
VSIZE_F0_MASK = 0x00003FFF
VSIZE_F1_MASK = 0x3FFF0000
VSIZE_F1_SHIFT = 16
XVXHOX_HSTART_MASK = 0x00003FFF
XVXHOX_HEND_MASK = 0x3FFF0000
XVXHOX_HEND_SHIFT = 16


# =====================================================================
#  vdma 寄存器（xaxivdma_hw.h）
#
#  ⚠ 寄存器直通模式（c_include_sg=0）下，MM2S 的两块**不连续**：
#      控制块  base + 0x00   （ChanBase = BaseAddr + TX_OFFSET）
#      参数块  base + 0x50   （StartAddrBase = BaseAddr + MM2S_ADDR_OFFSET）
#    写错地方不会报错，只会静默不工作。
# =====================================================================
VDMA_MM2S_CTRL_BASE = 0x00      # 控制块
VDMA_MM2S_PARAM_BASE = 0x50     # 参数块（这个基址是**绝对的**，不再加 0x30）

VDMA_CR = 0x00                  # 控制寄存器（相对控制块）
VDMA_SR = 0x04                  # 状态寄存器
VDMA_HSIZE = 0x04               # 水平尺寸（相对参数块，单位=字节）
VDMA_STRIDE = 0x08              # stride（低16位）+ 帧延迟（高16位）
VDMA_START_ADDR = 0x0C          # 起始地址（相对参数块）
VDMA_VSIZE = 0x00               # 垂直尺寸（相对参数块，单位=行）
VDMA_PARKPTR = 0x28             # Park 指针（全局，不分通道）
VDMA_VERSION = 0x2C             # 版本号（全局）

VDMA_CR_RUNSTOP = 0x00000001
VDMA_CR_TAIL_EN = 0x00000002    # 与 RUNSTOP 一起 = Circular 模式
VDMA_CR_RESET = 0x00000004
VDMA_SR_HALTED = 0x00000001
VDMA_SR_IDLE = 0x00000002
VDMA_SR_ERR_ALL = 0x00000FF0    # 所有错误位


# =====================================================================
#  工具
# =====================================================================
def hx(v):
    return '0x%08X' % (v & 0xFFFFFFFF)


def ok(msg):
    print('  [ OK ] %s' % msg)


def fail(msg):
    print('  [FAIL] %s' % msg)


def info(msg):
    print('         %s' % msg)


def banner(t):
    print('\n' + '=' * 72)
    print('  %s' % t)
    print('=' * 72)


def find_bitfile(explicit=None):
    """按 PYNQ 惯例找 overlay（同目录、同名 .bit/.hwh）"""
    if explicit:
        return explicit
    here = os.path.dirname(os.path.abspath(__file__))
    for d in (here, os.getcwd(), '/home/xilinx'):
        p = os.path.join(d, 'gesture_system.bit')
        if os.path.exists(p):
            return p
    return 'gesture_system.bit'    # 交给 PYNQ 报错


def mmio_of(overlay, name):
    """
    从 PYNQ 的 ip_dict 取一个 IP 的 MMIO 句柄。

    ⚠ 不能用 `overlay.vdma`：PYNQ 3.0.1 的 AxiVDMA 专用驱动构造时要找
      中断，本设计的 vdma **没有接中断**，会抛
        AttributeError: 'AxiVDMA' object has no attribute 's2mm_introut'
      （见 vdma_bypass_test.py 的实测记录）。
    ⚠ 键名是 `phys_addr`，不是 PYNQ 2.x 的 `base_addr` ——
      写错会静默打印 0x00000000 而不报错。
    """
    info_dict = overlay.ip_dict[name]
    base = info_dict['phys_addr']
    rng = info_dict.get('addr_range', 0x10000)
    from pynq import MMIO
    return MMIO(base, rng), base


# =====================================================================
#  阶段 1：配置 v_tc 并产生 720p60 时序
# =====================================================================
def vtc_configure(m):
    """
    逐行移植自 Xilinx 官方 `XVtc_SetGenerator` 的 **OriginMode=1 分支**。

    ⚠ 那个函数有 if(OriginMode==0) / else 两个分支，**算法不同**
      （mode 0 要用 HTotal+1、并用 r_htotal-r_hactive 算 active；
        mode 1 直接用各 Start 值）。驱动实际走的是 **else（mode 1）**。
      用错分支 → 寄存器值全错 → 时序不对。
    """
    # ---- 由视频参数算各信号起始点（OriginMode=1：active 从 0 起算）----
    h_active_start = 0
    h_fp_start = H_ACTIVE                                  # 1280
    h_sync_start = h_fp_start + H_FP                       # 1390
    h_bp_start = h_sync_start + H_SYNC                     # 1430
    h_total_sig = h_bp_start + H_BP                        # 1650

    v_active_start = 0
    v_fp_start = V_ACTIVE                                  # 720
    v_sync_start = v_fp_start + V_FP - 1                   # 724
    v_bp_start = v_sync_start + V_SYNC                     # 729
    v_total_sig = v_bp_start + V_BP + 1                    # 750

    r_htotal = h_total_sig
    r_vtotal = v_total_sig
    r_hactive = h_fp_start      # 注意：mode1 下 active = HFrontPorchStart
    r_vactive = v_fp_start

    info('H: active=%d fp=%d sync=%d bp=%d  total=%d'
         % (H_ACTIVE, H_FP, H_SYNC, H_BP, r_htotal))
    info('V: active=%d fp=%d sync=%d bp=%d  total=%d'
         % (V_ACTIVE, V_FP, V_SYNC, V_BP, r_vtotal))

    # ---- 尺寸寄存器 ----
    m.write(VTC_GHSIZE, r_htotal & SB_START_MASK)
    # 逐行模式：V1Total 与 V0Total 相同
    m.write(VTC_GVSIZE, (r_vtotal & VSIZE_F0_MASK) |
                        ((v_total_sig << VSIZE_F1_SHIFT) & VSIZE_F1_MASK))
    m.write(VTC_GASIZE, (r_hactive & ASIZE_HORI_MASK) |
                        ((r_vactive << ASIZE_VERT_SHIFT) & ASIZE_VERT_MASK))
    m.write(VTC_GASIZE_F1, (r_vactive << ASIZE_VERT_SHIFT) & ASIZE_VERT_MASK)

    # ---- 同步位置寄存器（起始/结束打包）----
    m.write(VTC_GHSYNC, (h_sync_start & SB_START_MASK) |
                        ((h_bp_start << SB_END_SHIFT) & SB_END_MASK))
    m.write(VTC_GVSYNC, (v_sync_start & SB_START_MASK) |
                        ((v_bp_start << SB_END_SHIFT) & SB_END_MASK))
    m.write(VTC_GVSYNC_F1, (v_sync_start & SB_START_MASK) |
                           ((v_bp_start << SB_END_SHIFT) & SB_END_MASK))

    # ---- 编码寄存器：逐行（PROG=0）、chroma parity 清零 ----
    enc = m.read(VTC_GFENC)
    enc &= ~VTC_ENC_CPARITY_MASK
    enc &= ~VTC_ENC_PROG_MASK          # 逐行扫描
    m.write(VTC_GFENC, enc)

    # ---- 水平偏移寄存器（驱动里的默认值）----
    #     VBlank 水平偏移 = r_hactive；VSync 水平偏移 = HSyncStart
    m.write(VTC_GVBHOFF, (r_hactive & XVXHOX_HSTART_MASK) |
                         ((r_hactive << XVXHOX_HEND_SHIFT) & XVXHOX_HEND_MASK))
    m.write(VTC_GVSHOFF, (h_sync_start & XVXHOX_HSTART_MASK) |
                         ((h_sync_start << XVXHOX_HEND_SHIFT) & XVXHOX_HEND_MASK))
    m.write(VTC_GVBHOFF_F1, (r_hactive & XVXHOX_HSTART_MASK) |
                            ((r_hactive << XVXHOX_HEND_SHIFT) & XVXHOX_HEND_MASK))
    m.write(VTC_GVSHOFF_F1, (h_sync_start & XVXHOX_HSTART_MASK) |
                            ((h_sync_start << XVXHOX_HEND_SHIFT) & XVXHOX_HEND_MASK))

    # ---- 极性：全部高有效（与驱动的 720p 表一致）----
    pol = 0
    if 1: pol |= VTC_POL_ACP          # ActiveChroma 恒为 1（驱动写死）
    if 1: pol |= VTC_POL_AVP          # ActiveVideo 恒为 1
    if 1: pol |= VTC_POL_FIP          # FieldId    恒为 1
    if VSYNC_POL: pol |= VTC_POL_VSP | VTC_POL_VBP
    if HSYNC_POL: pol |= VTC_POL_HSP | VTC_POL_HBP
    m.write(VTC_GPOL, pol)


def vtc_enable(m):
    """使能发生器：先写源选择，再置 SW|GE"""
    ctl = m.read(VTC_CTL)
    ctl &= ~VTC_SRC_ALL
    ctl |= VTC_SRC_ALL
    ctl |= VTC_CTL_SW | VTC_CTL_GE
    m.write(VTC_CTL, ctl)
    return ctl


def stage1(overlay):
    banner('阶段 1：配置 v_tc 720p60 时序')
    m, base = mmio_of(overlay, 'v_tc')
    info('v_tc 基地址 = %s' % hx(base))

    ver = m.read(VTC_VER)
    info('VTC VERSION = %s' % hx(ver))
    if ver == 0 or ver == 0xFFFFFFFF:
        fail('读不到 VTC 版本号 —— MMIO 地址可能不对')
        return False
    ok('MMIO 可读')

    vtc_configure(m)
    ctl = vtc_enable(m)
    info('CTL = %s  (SW=%d GE=%d)'
         % (hx(ctl), (ctl >> 0) & 1, (ctl >> 2) & 1))

    # 回读确认
    got_h = m.read(VTC_GHSIZE) & SB_START_MASK
    got_v = m.read(VTC_GVSIZE) & VSIZE_F0_MASK
    if got_h != H_TOTAL or got_v != V_TOTAL:
        fail('尺寸回读不对：H=%d(期望%d) V=%d(期望%d)'
             % (got_h, H_TOTAL, got_v, V_TOTAL))
        return False
    ok('尺寸回读 H=%d V=%d ✓' % (got_h, got_v))
    ok('发生器已使能（GE=1）')

    print()
    info('★ 现在看显示器：应识别到 1280x720@60 并切换过去')
    info('  画面此时是**黑的** —— 这是正常的，还没有帧数据')
    info('  若显示器显示"无信号" → TMDS/时钟/引脚有问题，先查这个再往下走')
    return True


# =====================================================================
#  阶段 2：配置 vdma + 写彩条 + 启动
# =====================================================================
def vdma_setup(m, fbuf_addr, nf=N_FSTORES):
    """配置 MM2S 通道（寄存器直通模式）"""
    ctrl_base = VDMA_MM2S_CTRL_BASE
    prm_base = VDMA_MM2S_PARAM_BASE

    # 先复位通道，确保从干净状态开始
    m.write(ctrl_base + VDMA_CR, VDMA_CR_RESET)
    t0 = time.time()
    while not (m.read(ctrl_base + VDMA_SR) & VDMA_SR_HALTED):
        if time.time() - t0 > 2.0:
            fail('MM2S 复位超时')
            return False
    ok('MM2S 已复位（HALTED=1）')

    # 尺寸
    m.write(prm_base + VDMA_VSIZE, V_ACTIVE)
    m.write(prm_base + VDMA_HSIZE, STRIDE)          # 注意 HSIZE 单位是**字节**
    m.write(prm_base + VDMA_STRIDE, STRIDE & 0xFFFF)  # 低16位=stride，高16位=帧延迟(0)

    # 各帧缓存起始地址（依次相隔一帧）
    for i in range(nf):
        m.write(prm_base + VDMA_START_ADDR + i * 4, fbuf_addr + i * FRAME_BYTES)

    info('帧缓存 0x%08X，%d 帧 × %d 字节' % (fbuf_addr, nf, FRAME_BYTES))
    return True


def vdma_start(m):
    ctrl_base = VDMA_MM2S_CTRL_BASE
    # ⚠ RUNSTOP | TAIL_EN = Circular 模式（循环播放 N 帧）
    #   只写 RUNSTOP 是 Park 模式，停在某一帧不循环
    m.write(ctrl_base + VDMA_CR, VDMA_CR_RUNSTOP | VDMA_CR_TAIL_EN)
    time.sleep(0.05)
    sr = m.read(ctrl_base + VDMA_SR)
    if sr & VDMA_SR_ERR_ALL:
        fail('MM2S 报错 SR=%s（错误位 0x%03X）' % (hx(sr), sr & VDMA_SR_ERR_ALL))
        return False
    if sr & VDMA_SR_HALTED:
        fail('MM2S 仍处于 HALTED，没跑起来 SR=%s' % hx(sr))
        return False
    ok('MM2S 已启动 SR=%s' % hx(sr))
    return True


def make_bars(width, height, bpp_bytes=2):
    """
    生成标准彩条：白 黄 青 绿 品红 红 蓝 黑（8 条竖条）

    ⚠ 颜色按 **RGB565** 打包成 16bit 小端字 —— 这是喂给 VDMA 的格式。
    ⚠ 本函数**只负责 VDMA 侧的数据**；RGB565→RBG888 的位序转换在
      PL 里的 axis_rgb565_888.v 完成。所以屏幕上看到的颜色对不对，
      取决于那个模块的位序（见文件头的说明）。
    """
    # 8 条标准彩条，RGB888 值
    colors888 = [
        (255, 255, 255),   # 白
        (255, 255, 0),     # 黄
        (0, 255, 255),     # 青
        (0, 255, 0),       # 绿
        (255, 0, 255),     # 品红
        (255, 0, 0),       # 红
        (0, 0, 255),       # 蓝
        (0, 0, 0),         # 黑
    ]
    # RGB888 -> RGB565
    bars565 = []
    for (r, g, b) in colors888:
        bars565.append(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3))

    row = bytearray()
    for x in range(width):
        idx = (x * 8) // width
        if idx > 7:
            idx = 7
        row += struct.pack('<H', bars565[idx])     # 小端 16bit

    buf = bytearray()
    for _ in range(height):
        buf += row
    return bytes(buf)


def stage2(overlay):
    banner('阶段 2：配置 vdma + 写彩条 + 启动')
    import numpy as np
    from pynq import allocate

    m, base = mmio_of(overlay, 'vdma')
    info('vdma 基地址 = %s' % hx(base))

    ver = m.read(VDMA_VERSION)
    info('VDMA VERSION = %s' % hx(ver))
    if ver == 0 or ver == 0xFFFFFFFF:
        fail('读不到 VDMA 版本号 —— MMIO 地址可能不对')
        return False
    ok('MMIO 可读')

    # ---- 分配帧缓存（连续、对齐）----
    # ⚠ 用 pynq.allocate 拿物理连续内存；它给出的是 numpy 视图，
    #   底层 device_address 就是 DMA 要的物理地址。
    nf = N_FSTORES
    fbuf = allocate(shape=(nf, V_ACTIVE, H_ACTIVE), dtype=np.uint16)
    fbuf_addr = fbuf.device_address
    info('帧缓存物理地址 = %s（%d 帧）' % (hx(fbuf_addr), nf))

    # ---- 写彩条到每一帧 ----
    bars = make_bars(H_ACTIVE, V_ACTIVE)
    arr = np.frombuffer(bars, dtype=np.uint16).reshape(V_ACTIVE, H_ACTIVE)
    for i in range(nf):
        fbuf[i] = arr
    # ⚠ 必须 flush：否则 DMA 读到的可能是 cache 里的旧数据，
    #   且**不报错**（本项目踩过这个坑）
    fbuf.flush()
    ok('已写入 %d 帧彩条并 flush' % nf)

    # ---- 配置并启动 ----
    if not vdma_setup(m, fbuf_addr, nf):
        return False
    if not vdma_start(m):
        return False

    print()
    info('★ 现在看显示器：应出现**标准彩条**（白 黄 青 绿 品红 红 蓝 黑）')
    info('')
    info('  ⚠ 判读颜色（这一条是本脚本的重点）：')
    info('     若**黄色条变成品红**、绿色条变成蓝色 → 位序错了（绿蓝互换）')
    info('     说明 axis_rgb565_888.v 的输出位序需要改回 R-G-B')
    info('     若**红蓝**互换 → DDR 里 RGB565 字节序反了')
    info('     → 把该模块的 IN_BYTE_SWAP 参数置 1 后重建')
    info('')
    info('  ⚠ 若画面**撕裂/滚动** → VDMA 与 v_tc 没同步好，查帧缓存数目与 stride')

    # 帧缓存要一直活着，否则被回收后 DMA 读到野地址
    return fbuf


# =====================================================================
#  主流程
# =====================================================================
def main():
    ap = argparse.ArgumentParser(
        description='HDMI 输出通路板上分步验证（PYNQ-Z2 / gesture_pl）')
    ap.add_argument('--bit', default=None, help='overlay 路径（默认 gesture_system.bit）')
    ap.add_argument('--stage', type=int, default=0, choices=[0, 1, 2],
                    help='只跑指定阶段（0=全部，默认）')
    ap.add_argument('--pattern', default='bars', choices=['bars'],
                    help='测试图案（目前只有 bars）')
    args = ap.parse_args()

    bit = find_bitfile(args.bit)
    banner('HDMI Bring-up')
    info('overlay : %s' % bit)
    info('阶段    : %s' % ('全部' if args.stage == 0 else args.stage))

    from pynq import Overlay
    ol = Overlay(bit)

    # 确认三个 IP 都认到了
    # ⚠ .hwh 必须与 .bit **同名配对**。名字不一致时 PYNQ 不报"找不到 hwh"，
    #   而是**只认出 default 一个 IP**，现象很难往回追（见 HANDOFF.md）
    want = ['v_tc', 'vdma']
    missing = [n for n in want if n not in ol.ip_dict]
    if missing:
        fail('overlay 里找不到 IP: %s' % missing)
        info('实际认到的: %s' % sorted(ol.ip_dict.keys()))
        info('⚠ 多半是 .hwh 没和 .bit 同名 —— 要叫 gesture_system.hwh')
        return 1
    ok('IP 已认到: %s' % sorted(ol.ip_dict.keys()))

    keep = None
    if args.stage in (0, 1):
        if not stage1(ol):
            return 1
        time.sleep(1.0)

    if args.stage in (0, 2):
        if args.stage == 0:
            input('\n  阶段 1 完成。确认显示器已识别到 720p 信号后按回车继续阶段 2... ')
        keep = stage2(ol)
        if not keep:
            return 1

    banner('完成')
    info('★ 上板后请把**实际看到的画面**记录下来（截图/拍照），')
    info('  尤其是彩条的颜色顺序 —— 那是判断位序对不对的唯一依据。')
    if keep is not None:
        info('')
        info('⚠ 帧缓存要保持引用（keep）不被回收，否则 DMA 会读到野地址。')
        info('  本脚本结束时它会随进程退出而释放 —— 想长时间显示请用 Jupyter 里跑。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
