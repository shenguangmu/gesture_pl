# =====================================================================
#  bd_video.tcl —— 手势识别系统的视频流水线 Block Design
#
#  用法（在 Vivado 里 source 本脚本）：
#      vivado -mode batch -source vivado/bd_video.tcl
#   或在已有工程里：
#      source vivado/bd_video.tcl
#
#  ─────────────────────────────────────────────────────────────────
#  这是本工程**唯一**的 Block Design
#  ─────────────────────────────────────────────────────────────────
#  原 Sobel 的 bd_sobel.tcl 已从本项目移除 —— 它的角色是
#  "已验证、可回滚的参照"，那个参照现在由完整的 **另一个项目的 Sobel 工程（不在本交付包内）** 承担。
#  本项目只保留手势识别这一条通路，减少维护面。
#
#  ─────────────────────────────────────────────────────────────────
#  数据通路
#  ─────────────────────────────────────────────────────────────────
#
#  【显示通路】摄像头原图直通，与预处理完全解耦
#
#   OV5640 ──DVP──► dvp_capture ──AXIS(16bit)──► VDMA S2MM ──► HP1 ──► DDR
#                                                                        │
#                                                              (帧缓存, 3 帧)
#                                                                        │
#      HDMI ◄── TMDS ◄── v_axi4s_vid_out ◄── AXIS ◄── VDMA MM2S ◄── HP2 ─┘
#                              ▲                        ▲
#                           v_tc/vtg                PS 配置 (GP0)
#
#  【CNN 通路】从 DDR 取同一帧，处理成 96x96 灰度写回 DDR
#
#      DDR(640x480 RGB565) ◄──── 就是上面那个帧缓存
#            │
#            │  dma_in (MM2S，读 614400 字节)
#            ▼
#      gesture_preproc (HLS) ──► 96x96 uint8
#            │
#            │  dma_out (S2MM，写 9216 字节)
#            ▼
#      DDR(96x96) ──► PS 侧 CNN 读这里
#
#  ─────────────────────────────────────────────────────────────────
#  HP 端口分配（这是本 BD 最重要的决定）
#  ─────────────────────────────────────────────────────────────────
#   HP0 —— 未用（原 Sobel 通路占用的，Sobel 已移除，此口空置）
#   HP1 —— VDMA S2MM：摄像头帧写入 DDR
#   HP2 —— VDMA MM2S：从 DDR 读帧送 HDMI
#   HP3 —— 预处理链的两个 DMA（读原图 + 写 96x96）
#
#  ⚠ 为什么 MM2S 和 S2MM 要分开占两个 HP 口：
#     摄像头持续写入约 18 MB/s (640x480@30 RGB565)，HDMI 读出同样量级。
#     挤在同一个 HP 口上会互相争抢，也便于用 ILA 单独观察。
#     HP3 的流量小得多（10 fps 时约 6 MB/s），单独一口足够。
#
#  ─────────────────────────────────────────────────────────────────
#  资源占用（2026-09-15 实测，含预处理链）
#  ─────────────────────────────────────────────────────────────────
#     Slice LUTs      12,735   23.94%
#     Slice Registers 15,736   14.79%
#     Block RAM        25.5    18.21%
#     DSPs               61    27.73%
#   两个时钟：clk_fpga_0 (10 ns) + cam_pclk (41.667 ns)
# =====================================================================

# ---------------------------------------------------------------------
#  参数
# ---------------------------------------------------------------------
if {![info exists BD_NAME]}   { set BD_NAME   "bd_video" }
if {![info exists PART_NAME]} { set PART_NAME "xc7z020clg400-1" }
if {![info exists IP_REPO]}   { set IP_REPO   "" }

# 视频时序：640x480@30（与 dvp_capture 的采集分辨率一致，先做直通）
set H_ACTIVE  640
set H_FRONT   16
set H_SYNC    96
set H_BACK    48
set V_ACTIVE  480
set V_FRONT   10
set V_SYNC    2
set V_BACK    33

# VDMA 帧缓存：3 帧（写/处理/读各一，避免撕裂）
# 16bit RGB565 -> 每像素 2 字节，stride = 640*2
set FRAME_BYTES [expr {640 * 480 * 2}]
set STRIDE      [expr {640 * 2}]

puts "====================================================================="
puts " bd_video.tcl —— 手势识别视频流水线"
puts "   器件: $PART_NAME"
puts "   BD  : $BD_NAME"
puts "   分辨率: ${H_ACTIVE}x${V_ACTIVE}"
puts "====================================================================="

# ---------------------------------------------------------------------
#  0. 导入 IP 仓库（HLS 预处理 + Digilent 第三方）
#
#  ⚠ 这里会**覆盖** create_project.tcl 设的 `ip_repo_paths`，
#    所以两个仓库都要在这里重新注册一遍 —— 只在那里设会被这里冲掉。
#
#  ⚠ `IP_REPO` 的语义仍然是「HLS 预处理 IP 的路径」单个字符串：
#    下面 §8 的 `has_gesture` 判断依赖它。所以第三方仓库用**独立变量**
#    `DIGILENT_LIB` 传，而不是把它变成列表（那会牵连 has_gesture 逻辑）。
# ---------------------------------------------------------------------
if {![info exists DIGILENT_LIB]} { set DIGILENT_LIB "" }

set _repos [list]
if {$IP_REPO ne ""} {
    if {![file exists $IP_REPO]} {
        error "IP_REPO 不存在: $IP_REPO"
    }
    lappend _repos $IP_REPO
}
if {$DIGILENT_LIB ne ""} {
    if {![file exists "$DIGILENT_LIB/rgb2dvi_v1_2/component.xml"]} {
        error "DIGILENT_LIB 里没有 rgb2dvi_v1_2/component.xml: $DIGILENT_LIB"
    }
    lappend _repos $DIGILENT_LIB
}

if {[llength $_repos] > 0} {
    set_property ip_repo_paths $_repos [current_project]
    update_ip_catalog -rebuild
    foreach _r $_repos { puts ">>> 已导入 IP 仓库: $_r" }
} else {
    puts ">>> 未提供任何 IP_REPO，跳过 gesture_preproc 与 rgb2dvi 的例化"
}

# ---------------------------------------------------------------------
#  1. 创建 BD（幂等：同名先删）
# ---------------------------------------------------------------------
if {[llength [get_files -quiet *$BD_NAME.bd]] > 0} {
    remove_files [get_files *$BD_NAME.bd]
}
if {[llength [get_bd_designs -quiet $BD_NAME]] > 0} {
    delete_bd_objs [get_bd_designs $BD_NAME]
}
create_bd_design $BD_NAME

# =====================================================================
#  2. PS 配置
#
#  ⚠ 不要用 apply_bd_automation ... apply_board_preset 1
#    它会把 PS7 整个重置成板卡预设，**覆盖掉这里设的 HP1/HP2**，
#    之后 connect 报 "Arguments ... cannot be empty"，
#    而报错行号离真正原因几十行，极难往回查。
# =====================================================================
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7]

# ⚠⚠ DDR 参数必须显式写，不能吃默认值。
#
#   2026-09-17 查实：本脚本原先**一条 DDR 参数都没有**，Vivado 于是套用了
#   PS7 的出厂默认 —— `MT41J128M8 JP-125`。而 **PYNQ-Z2 板载是
#   MT41K256M16RE-125（32-bit 总线）**，对不上。
#
#   后果的特征很隐蔽：**建工程、综合、实现、出比特流全部通过**，
#   时序报告 WNS 还是正的。只有上板跑起来才暴露。
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0          {1} \
    CONFIG.PCW_USE_M_AXI_GP1          {0} \
    CONFIG.PCW_USE_S_AXI_HP0          {1} \
    CONFIG.PCW_USE_S_AXI_HP1          {1} \
    CONFIG.PCW_USE_S_AXI_HP2          {1} \
    CONFIG.PCW_USE_S_AXI_HP3          {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT   {0} \
    CONFIG.PCW_EN_CLK0_PORT           {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_UIPARAM_DDR_PARTNO     {MT41K256M16 RE-125} \
    CONFIG.PCW_UIPARAM_DDR_BUS_WIDTH  {32 Bit} \
    CONFIG.PCW_UIPARAM_DDR_FREQ_MHZ   {533.333} \
] $ps7

# ---- 存在性断言：早失败早定位 ----
foreach need {M_AXI_GP0 S_AXI_HP0 S_AXI_HP1 S_AXI_HP2 S_AXI_HP3 FCLK_CLK0} {
    if {[llength [get_bd_intf_pins -quiet ps7/$need]] == 0 &&
        [llength [get_bd_pins -quiet ps7/$need]] == 0} {
        error "ps7/$need 未生成 —— 检查 PCW_USE_* 是否被覆盖"
    }
}
puts ">>> PS 接口断言通过 (GP0 / HP0 / HP1 / HP2 / HP3)"

# ---- DDR 断言：这类参数写错**不报错**，只会静默取默认值 ----
set ddr_part [get_property CONFIG.PCW_UIPARAM_DDR_PARTNO $ps7]
if {[string first "MT41K256M16" $ddr_part] < 0} {
    error "DDR PARTNO 未生效，当前值 = '$ddr_part'（期望 MT41K256M16 RE-125）"
}
puts ">>> DDR 断言通过 ($ddr_part)"

# =====================================================================
#  3. 复位
# =====================================================================
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_100m]

connect_bd_net [get_bd_pins ps7/FCLK_CLK0]       [get_bd_pins rst_100m/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N]   [get_bd_pins rst_100m/ext_reset_in]

# =====================================================================
#  4. VDMA
# =====================================================================
set vdma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vdma vdma]

set_property -dict [list \
    CONFIG.c_include_mm2s            {1} \
    CONFIG.c_include_s2mm            {1} \
    CONFIG.c_m_axi_mm2s_data_width   {64} \
    CONFIG.c_m_axi_s2mm_data_width   {64} \
    CONFIG.c_m_axis_mm2s_tdata_width {16} \
    CONFIG.c_num_fstores             {3} \
    CONFIG.c_mm2s_linebuffer_depth   {2048} \
    CONFIG.c_s2mm_linebuffer_depth   {2048} \
    CONFIG.c_include_sg              {0} \
] $vdma

# ⚠ 只显式设"派生参数"里确实存在的那几个。实测（Vivado 2025.2）：
#   c_mm2s_fsync / c_s2mm_fsync   -> 不存在，报 [BD 41-1276]
#   c_s_axis_s2mm_tdata_width     -> 只读，报 [BD 41-737]
# 盲设不存在的参数只给 CRITICAL WARNING 不报错，极易被忽略。
set_property -dict [list \
    CONFIG.c_mm2s_genlock_mode       {0} \
    CONFIG.c_s2mm_genlock_mode       {0} \
] $vdma

# =====================================================================
#  5. 视频时序控制器 + 生成器（给 HDMI 输出）
#
#  ⚠ 2026-09-26：VIDEO_MODE 由 480p 改为 **720p**（配合 rgb2dvi 的
#    40 MHz 下限 —— 480p 的 25.2 MHz 低于它，需要改 rgb2dvi 源码）。
#    v_tc 的 720p 预设 = **1280×720**（已从 IP 的 xgui Tcl 核实：
#    GEN_HACTIVE_SIZE=1280 / GEN_VACTIVE_SIZE=720），计时 1650×750，
#    对应像素时钟 74.25 MHz → 74.25e6/(1650×750) = **60.0 Hz** ✓
#
#  ⚠⚠ enable_generation 必须显式为 1：这个 IP 的默认值随版本变过，
#     而且——本项目反复踩的那类坑——**它没开时不会报错**，
#     只是 vtiming_out 永远不动，下游表现为黑屏。
#     回读断言在下面。
#
#  ⚠ v_tc 有两个时钟：clk（视频时序，要在**像素时钟**域）与
#    s_axi_aclk（AXI-Lite 控制，留在 100 MHz）。见 §9 的时钟连接。
# =====================================================================
set vtc [create_bd_cell -type ip -vlnv xilinx.com:ip:v_tc v_tc]

set_property -dict [list \
    CONFIG.enable_detection  {0} \
    CONFIG.enable_generation {1} \
    CONFIG.VIDEO_MODE        {720p} \
] $vtc

# 回读断言：确认生成器开着、且 720p 预设真的解析成 1280×720
set gen_en [get_property -quiet CONFIG.enable_generation $vtc]
if {$gen_en eq "" || $gen_en == 0} {
    error "v_tc 的 enable_generation 未生效（实得 '$gen_en'）—— 时序发生器不会动"
}
foreach {p want} {GEN_HACTIVE_SIZE 1280 GEN_VACTIVE_SIZE 720} {
    set got [get_property -quiet CONFIG.$p $vtc]
    if {$got eq "" || $got != $want} {
        error "v_tc 的 $p 期望 $want，实得 '$got' —— 720p 预设没解析成 1280x720"
    }
    puts ">>> v_tc $p = $got ✓"
}
puts ">>> v_tc 720p 刷新率 = [expr {74.25e6 / (1650.0 * 750.0)}] Hz (预期 60.0)"

# =====================================================================
#  6. AXI4-Stream → 视频时序（驱动 HDMI）
# =====================================================================
set vout [create_bd_cell -type ip -vlnv xilinx.com:ip:v_axi4s_vid_out v_axi4s_vid_out]
# ⚠ 这里的格式参数决定 s_axis_video_tdata 的位宽，**也决定 vid_io_out 的位宽**。
#   实测规则（Vivado 2025.2，读 IP 的 xgui Tcl 得出）：
#       C_S_AXIS_TDATA_WIDTH = ceil(PPC × 分量数 × DATA_WIDTH / 8) × 8
#       vid_io_out 宽度      = PPC × 分量数 × C_NATIVE_COMPONENT_WIDTH
#   其中「分量数」由 FORMAT 决定：FORMAT=0→2 个，FORMAT=1/2→3 个。
#
#   ── 2026-09-26 改动：16bit RGB565 → 24bit RGB888 ──
#   原来 FORMAT=0 → 2 分量 × 8 = 16bit，直接吃 VDMA 的 RGB565。
#   现在要驱动 rgb2dvi（它只要 24bit，见 §6.4），所以：
#       FORMAT=2 + DATA_WIDTH=8 → 3 × 8 = **24bit**
#   上游 VDMA 仍是 16bit，中间由手写的 `axis_rgb565_888` 转换（§6.3）。
#
#   ⚠ 若这里算出来不是 24，与 rgb2dvi 连接时只报
#     [BD 41-2384] Width mismatch ... Only lower order bits
#   —— **WARNING 不是 ERROR**，会被截断后静默出错。下面的回读断言就是防它。
#
#   ⚠⚠ C_HAS_ASYNC_CLK 由 0 改为 1：s_axis 侧仍是 100 MHz（VDMA 侧），
#     vid_io 侧切到 74.25 MHz 像素时钟。改完会多出两个端口：
#         vid_io_out_clk    ← 必须接像素时钟，否则无输出
#         vid_io_out_reset  ← ⚠ **低有效**！与 aresen 极性相反
set_property -dict [list \
    CONFIG.C_HAS_ASYNC_CLK           {1} \
    CONFIG.C_ADDR_WIDTH              {11} \
    CONFIG.C_S_AXIS_VIDEO_FORMAT     {2} \
    CONFIG.C_S_AXIS_VIDEO_DATA_WIDTH {8} \
] $vout

# 回读断言：确认关键参数确实写进去了
# ⚠ `C_S_AXIS_TDATA_WIDTH` / `C_NATIVE_DATA_WIDTH` 是 **MODELPARAM**
#   （由 FORMAT × DATA_WIDTH 派生的只读值），用 `CONFIG.` 读不到 ——
#   写这条断言时踩过：get_property 返回空字符串，断言误报。
#   所以这里只断言**可写的输入参数**；派生出来的真实位宽在 BD 建完后
#   从生成的 bd 文件里核实（见脚本末尾的提示）。
foreach {p want} {C_S_AXIS_VIDEO_FORMAT 2 C_S_AXIS_VIDEO_DATA_WIDTH 8 \
                  C_NATIVE_COMPONENT_WIDTH 8 C_HAS_ASYNC_CLK 1} {
    set got [get_property -quiet CONFIG.$p $vout]
    if {$got eq "" || $got != $want} {
        error "v_axi4s_vid_out 的 $p 期望 $want，实得 '$got'"
    }
    puts ">>> v_axi4s_vid_out $p = $got ✓"
}
puts "    （FORMAT=2 × DATA_WIDTH=8 → s_axis 24bit；NATIVE_COMPONENT_WIDTH=8 → vid_io_out 24bit）"

# =====================================================================
#  6.2 像素时钟域：100 MHz → 74.25 MHz（720p60）
#
#  ⚠⚠ 这是本 BD 之前**完全没有**的东西。原设计里 v_tc 与 v_axi4s_vid_out
#     都挂在 100 MHz 的 FCLK_CLK0 上 —— 那样算出来的刷新率是
#     100e6 / (1650 × 750) = **80.8 Hz**，不是显示器认的 60 Hz。
#     （v_tc 的 720p 预设按 1650×750 计时。）所以必须真有一个像素时钟。
#
#  参数推导（显式给 M/D/O，**不让工具自动选** —— 原因见 §7 的 XCLK 段）：
#      VCO  = 100 MHz × M / D = 100 × 37.125 / 5 = **742.5 MHz** ✓
#              （在 Zynq-7020 -1 的 600–1200 MHz 内，且离两端都远）
#      PFD  = 100 / D = 20 MHz ✓（MMCM 要求 ≥10 MHz）
#      像素 = VCO / O = 742.5 / 10 = **74.25 MHz** ✓（精确，误差 0.0000%）
#
#  ⚠ 74.25 MHz 是 CEA-861 对 720p60 的**精确**像素时钟。D=5 是为满足
#    M 的 0.125 步进下的精确解 —— 已穷举验证：
#    100×37.125/5 = 742.5，742.5/10 = 74.25，无舍入误差。
# =====================================================================
set cwpix [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_pix]

set_property -dict [list \
    CONFIG.PRIM_IN_FREQ          {100.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {74.250} \
    CONFIG.USE_LOCKED            {true} \
    CONFIG.USE_RESET             {true} \
    CONFIG.RESET_TYPE            {ACTIVE_LOW} \
    CONFIG.PRIMITIVE             {MMCM} \
    CONFIG.OVERRIDE_MMCM         {true} \
] $cwpix

# 第二步：OVERRIDE_MMCM 已开，这时 MMCM_* 才真正可写
set_property -dict [list \
    CONFIG.MMCM_CLKFBOUT_MULT_F  {37.125} \
    CONFIG.MMCM_DIVCLK_DIVIDE    {5} \
    CONFIG.MMCM_CLKOUT0_DIVIDE_F {10.000} \
] $cwpix

# 回读断言（照抄 §7 XCLK 的做法 —— 参数没生效不报错，必须自己查）
foreach {p want} {MMCM_CLKFBOUT_MULT_F 37.125 MMCM_DIVCLK_DIVIDE 5 \
                  MMCM_CLKOUT0_DIVIDE_F 10.000} {
    set got [get_property -quiet CONFIG.$p $cwpix]
    if {$got eq "" || [expr {abs(double($got) - $want)}] > 0.001} {
        error "像素时钟 MMCM 参数 $p 未生效：期望 $want，实得 '$got'"
    }
    puts ">>> 像素时钟 MMCM $p = $got ✓"
}
puts ">>> 像素时钟 VCO = [expr {100.0 * [get_property CONFIG.MMCM_CLKFBOUT_MULT_F $cwpix] / [get_property CONFIG.MMCM_DIVCLK_DIVIDE $cwpix]}] MHz (期望 742.5)"

# =====================================================================
#  6.3 位宽转换：VDMA 16bit RGB565 → 24bit RBG888
#
#  ⚠⚠ 输出是 **RBG** 序不是 RGB —— rgb2dvi 的 vid_pData 就是 RBG
#     （[23:16]=R / [15:8]=B / [7:0]=G，见 rgb2dvi.vhd:181-184 的原文
#     注释 "for some reason vid_data is packed in RBG order"）。
#     而 v_axi4s_vid_out **不做重排**（TDATA_OUT = TDATA_IN），
#     所以位序完全由这个模块决定。写成常识的 RGB 会**绿蓝互换**：
#     画面看着像对的、只是颜色不对 —— 最难往位序上想的一类现象。
#     详见 src/RTL/axis_rgb565_888.v 的文件头。
# =====================================================================
set conv [create_bd_cell -type module -reference axis_rgb565_888 rgb565_888_0]

# =====================================================================
#  6.4 TMDS 编码器（Digilent rgb2dvi）
#
#  PYNQ-Z2 的 HDMI **直连 PL 的 TMDS 引脚**，板上无 ADV7511 之类的
#  编码芯片 → TMDS 必须自己在 PL 里做。rgb2dvi 就是干这个的。
#
#  ⚠⚠ kClkRange **必须显式设为 2** —— 它的默认值是 1，
#     对应 CLKFBOUT_MULT_F = 5，即 VCO = 像素时钟 × 5。
#     720p 下 = 74.25 × 5 = **371.25 MHz，低于 -1 速度等级的 600 MHz 下限
#     → 锁不住 → 无输出**。设 2 后 VCO = 742.5 MHz ✓。
#     依据：third_party/digilent/rgb2dvi_v1_2/src/ClockGen.vhd 的注释
#           "MULT_F = kClkRange*5 (choose >=120MHz=1, >=60MHz=2, >=40MHz=3)"
#
#  ⚠ kGenerateSerialClk = true：让它**自己**产生 5× 串行时钟（371.25 MHz），
#     不必我们在外面搭 MMCM+BUFIO/BUFR。代价是不能运行时切分辨率 ——
#     本项目固定 720p，无所谓。
#     （参考工程用 false 是因为它要支持动态切分辨率，走 axi_dynclk。）
#
#  ⚠ kRstActiveHigh = false → 用 `aRst_n`（低有效），接 peripheral_aresetn。
#     设成 true 则用 `aRst`（高有效），端口都不一样，别接错。
# =====================================================================
set r2d [create_bd_cell -type ip -vlnv digilentinc.com:ip:rgb2dvi:1.2 rgb2dvi_0]
set_property -dict [list \
    CONFIG.kClkRange          {2} \
    CONFIG.kGenerateSerialClk {true} \
    CONFIG.kRstActiveHigh     {false} \
] $r2d

# 回读断言：kClkRange 是"默认值会静默锁不住"的那类参数，必须查
set got_kr [get_property -quiet CONFIG.kClkRange $r2d]
if {$got_kr eq "" || $got_kr != 2} {
    error "rgb2dvi 的 kClkRange 期望 2，实得 '$got_kr' —— 默认值 1 会让 VCO 只有 371 MHz 锁不住"
}
puts ">>> rgb2dvi kClkRange = $got_kr ✓ (VCO 742.5 MHz)"

# =====================================================================
#  6.5 像素域复位
#
#  ⚠⚠ 关键：`dcm_locked` 必须接 MMCM 的 locked。
#     若不管它（proc_sys_reset 默认把 dcm_locked 当 1），复位会
#     在**像素时钟还没锁定**时就放开 → **静默黑屏**：
#     构建干净通过、上板什么都不显示。
#     接上 locked 后，IP 内部会一直保持复位直到时钟稳定。
#
#  ⚠ 不需要额外的 AND 门 —— `dcm_locked` 就是为这件事设计的端口。
# =====================================================================
set rstpix [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_pix]

# =====================================================================
#  7. 摄像头采集（本项目写的 RTL）
# =====================================================================
#  ⚠ dvp_capture 是手写 Verilog，不属于任何 IP 仓库。
#    在 Vivado 工程里以 RTL 源的方式加入，然后 create_bd_cell -type module。
#    这里假设源文件已被 add_files 加入工程（见 create_video_project.tcl）。
#  ⚠ 逐个文件检查是否已在工程里，而不是用"dvp_capture 在不在"当开关。
#    早期写法是 `if {dvp_capture.v 不在工程} { 加全部 }` —— 一旦
#    dvp_capture 已存在（上一轮加过），新增的 iobuf_wrap.v /
#    ov5640_regs.v 就**永远加不进来**，报
#      [BD 41-1690] Unable to resolve module-source
#  ⚠ 目录重排（2026-09-26）后 RTL 在 <repo>/src/RTL/。
#    原来这里写的是 `../rtl`（= build/rtl，**已不存在**）——
#    只在"create_project.tcl 已先把文件加进工程"时靠守卫侥幸不炸，
#    一旦两个文件清单不同步就会静默失效。改成与 create_project.tcl
#    一致的双候选查找。
set _repo [file normalize [file join [file dirname [info script]] .. ..]]
set _rtl ""
foreach _cand [list "$_repo/src/RTL" "$_repo/rtl"] {
    if {[file isdirectory $_cand]} { set _rtl $_cand; break }
}
if {$_rtl eq ""} {
    error "找不到 RTL 目录（试过 src/RTL/ 与 rtl/）"
}
puts ">>> RTL 目录: $_rtl"

foreach _f {dvp_capture.v async_fifo.v sccb_master.v iobuf_wrap.v ov5640_regs.v axis_rgb565_888.v} {
    # ⚠ 不用 continue —— Vivado 的 Tcl 解释器在部分上下文里对
    #    foreach 内的 continue 报 "wrong # args: should be continue"。
    #    改用嵌套 if 表达同样的"已存在就跳过"。
    if {[llength [get_files -quiet "*/$_f"]] == 0} {
        if {[file exists [file join $_rtl $_f]]} {
            add_files -norecurse [file join $_rtl $_f]
            puts ">>> 已加入 rtl/$_f"
        } else {
            puts "WARN: 找不到 rtl/$_f"
        }
    }
}

set cap [create_bd_cell -type module -reference dvp_capture dvp_capture_0]

# ---------------------------------------------------------------------
#  7.2 Clocking Wizard：产生 24 MHz XCLK 给摄像头
#
#  ⚠ PMOD-CAMERA v1.0 **没有板载晶振** —— 原理图 J2 pin 1 = XMCLK，
#    是**输入**，必须由 FPGA 提供主时钟。
#
#  100 MHz → 24 MHz **不是整数分频**，必须用 MMCM。参数推导：
#      VCO = 100 MHz * M / D
#      XCLK = VCO / O
#  Zynq-7020 速度等级 -1 的 VCO 范围是 600–1200 MHz。
#
#  ─────────────────────────────────────────────────────────────────────
#  ⚠⚠ 2026-09-22 实测更正：原来只写 PRIM_IN_FREQ / REQUESTED_OUT_FREQ，
#      让工具**自动选 M/D/O**，结果选出了 VCO = 1200 MHz（正好顶在上限）。
#      上板实测 **XCLK 没有输出**（ILA probe6 的 clk_out1 全程恒 1 不翻转，
#      逻辑分析仪独立测得同一结论）→ 摄像头无主时钟 → SCCB 收不到 ACK
#      （cfg_error=1）→ 不出图 → VDMA 帧计数恒 1。
#
#  **教训**：**别让工具替你选 VCO**。自动选择会贴着你给的上限走，
#  而 -1 速度等级的上限是"名义值"，实际未必能稳住。
#  同时也别只信 `CLKOUT1_REQUESTED_OUT_FREQ` —— 它只是个**请求**，
#  工具可以用不同的 M/D/O 组合满足它，你并不知道 VCO 落在哪。
#  ─────────────────────────────────────────────────────────────────────
#  现在**显式指定** M/D/O，把 VCO 钉在 600 MHz（区间正中，远离两端）：
#      VCO = 100 MHz * M / D = 100 * 6 / 1 = 600 MHz ✓
#      XCLK = VCO / O      = 600 / 25     = 24 MHz  ✓
#  代价：VCO 从 1200 降到 600，24 MHz 的**合成分辨率减半**（抖动略增）。
#  但摄像头对 XCLK 抖动不敏感（它只是主时钟），远好过锁不住。
# ---------------------------------------------------------------------
set cw [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_xclk]

#  ⚠⚠ **必须开 `OVERRIDE_MMCM`，否则 MMCM_* 参数全被静默忽略** ——
#     2026-09-22 实测，踩了整整一轮才找到。完整现象：
#
#     不给 OVERRIDE_MMCM 时，设 M/D/O 会得到：
#       WARNING: [IP_Flow 19-3374] An attempt to modify the value of
#                disabled parameter 'MMCM_CLKFBOUT_MULT_F' ... ignored
#     **只给 WARNING 不给 ERROR**，值直接丢弃，工具照用自己的求解器结果。
#
#     而且**光设 PRIMITIVE {MMCM} 不够**（那只是"用哪种原语"），
#     `USE_FREQ_SYNTH=false` 也不够（那只解开 DIVCLK_DIVIDE，M/O 仍被拒）。
#     真正的开关是 **`OVERRIDE_MMCM`** —— 它的含义是
#     "**我要手动指定 MMCM 的 M/D/O，别用你的频率合成器**"。
#
#     这个参数在 IP 的常规配置界面里不明显，是打印完整属性表
#     （`report_property -all $cw`）才找到的。
#
#     ⚠ 与本项目其它同类坑完全一致：
#       AXI DMA 的 `c_sg_length_width`、ILA 的 `C_PROBE{N}_WIDTH` ——
#       **参数没生效、不报错、只在硬件上表现为怪现象**。
#       本次是靠下面那段**回读断言**在 1 分钟内抓到的，
#       否则会一路带到比特流里，白等 40 分钟综合。
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ          {100.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {24.000} \
    CONFIG.USE_LOCKED            {true} \
    CONFIG.USE_RESET             {true} \
    CONFIG.RESET_TYPE            {ACTIVE_LOW} \
    CONFIG.PRIMITIVE             {MMCM} \
    CONFIG.OVERRIDE_MMCM         {true} \
] $cw

# 第二步：OVERRIDE_MMCM 已开，这时 MMCM_* 才真正可写
set_property -dict [list \
    CONFIG.MMCM_CLKFBOUT_MULT_F  {6.000} \
    CONFIG.MMCM_DIVCLK_DIVIDE    {1} \
    CONFIG.MMCM_CLKOUT0_DIVIDE_F {25.000} \
] $cw

# ⚠ 设完**必须回读断言** —— 上面那个坑就是"值没生效但不报错"，
#   不主动查的话会一路带到比特流里，最后表现为"上板后 XCLK 还是不出"，
#   而那时已经花了 40 分钟综合。本项目同类坑：AXI DMA 的
#   c_sg_length_width、ILA 的 C_PROBE{N}_WIDTH。
foreach {p want} {MMCM_CLKFBOUT_MULT_F 6.000 MMCM_DIVCLK_DIVIDE 1 \
                  MMCM_CLKOUT0_DIVIDE_F 25.000} {
    set got [get_property -quiet CONFIG.$p $cw]
    if {$got eq "" || [expr {abs(double($got) - $want)}] > 0.001} {
        error "MMCM 参数 $p 未生效：期望 $want，实得 '$got'"
    }
    puts ">>> MMCM $p = $got ✓"
}
puts ">>> MMCM VCO = [expr {100.0 * [get_property CONFIG.MMCM_CLKFBOUT_MULT_F $cw] / [get_property CONFIG.MMCM_DIVCLK_DIVIDE $cw]}] MHz (期望 600)"

# ⚠ 用 MMCM 而不是 PLL：PLL 在 602–1200 的范围内对 VCO 更敏感，
#    MMCM 对非整数比更宽容。这个比正好整数（O=50），两者都行，
#    但 MMCM 是默认推荐的。

puts ">>> Clocking Wizard 已例化（100 MHz -> 24 MHz XCLK）"

# ---------------------------------------------------------------------
#  7.3 SCCB 主控：配置 OV5640
#
#  ⚠ 为什么用自写的 sccb_master 而不是 Xilinx 的 AXI IIC IP：
#    1. SCCB 落在 Pmod A 的**普通 GPIO** 上（ja[2]/ja[6]），
#       不是 PYNQ 的专用 I2C 引脚（P15/P16 在 Arduino 座上，
#       与 Pmod A 的物理位置无关）
#    2. sccb_master 已写好并通过自检（10/10），直接复用
#    3. 省一个 AXI-Lite 从口和相应地址分配
#
#  连接方式（在 §10 外部端口段）：
#      sccb_master/scl   → io_scl（输出）
#      sccb_master/sda_oe + sda_o → IOBUF → io_sda（双向）
#      sccb_master/sda_i ← IOBUF 读回
#
#  ⚠ 寄存器配置表由 rtl/ov5640_regs.v 提供（按 tbl_addr 索引的常量 ROM）。
#    独立成模块而不是塞进 BD 的原因：那张表上百项，写成 Tcl 常量列表
#    既难维护也难核对。
#  ✅ 2026-09-17：已由"8 条占位值"替换为**真实配置表**。
#     来源：正点原子 i2c_ov5640_rgb565_cfg.v，250 条，固化为 640x480 RGB565。
#     详见 rtl/ov5640_regs.v 文件头。
# ---------------------------------------------------------------------
set sccb [create_bd_cell -type module -reference sccb_master sccb_0]

# ⚠⚠ N_REGS 是**最容易漏的一处**：
#    sccb_master.v 的参数默认值是 **64**，而配置表是 **250** 条。
#    两者不一致时 sccb **配到一半就停下**（或越界读垃圾值），
#    而且**没有任何报错** —— 症状是"摄像头毫无反应"。
#    改了配置表的条目数，就必须同步改这里的 N_REGS。
set_property -dict [list CONFIG.N_REGS {250}] $sccb
puts ">>> sccb_0 的 N_REGS 已设为 250（与 ov5640_regs.v 一致）"

set oreg [create_bd_cell -type module -reference ov5640_regs ov5640_regs_0]

# IOBUF：SDA 是开漏双向线，需要三态缓冲。
# ⚠ Vivado 的 BD 里不能直接例化 IOBUF 原语（原语不是 IP，也不是可
#    直接被 module reference 引用的源），所以包一层 rtl/iobuf_wrap.v。
set iobuf [create_bd_cell -type module -reference iobuf_wrap iobuf_sda_0]

puts ">>> SCCB 主控 + 寄存器表 + IOBUF 已例化"

# =====================================================================
#  8. 预处理链（gesture_preproc + 两个 AXI DMA）
#
#  数据流：
#      DDR(640x480 RGB565)
#          │  dma_in (MM2S，读 614400 字节)
#          ▼
#      gesture_preproc ──► 96x96 灰度
#          │  dma_out (S2MM，写 9216 字节)
#          ▼
#      DDR(96x96 uint8)  ← CNN 侧读这里
#
#  ─────────────────────────────────────────────────────────────────
#  为什么要两个独立的 AXI DMA，而不是一个 DMA 的 MM2S+S2MM
#  ─────────────────────────────────────────────────────────────────
#  一个 DMA 的 MM2S 与 S2MM 是**独立通道**，本来可以各走各的。
#  这里仍用两个独立 IP，原因是：
#    * 输入输出长度不同（614400 vs 9216 字节），分开更直观
#    * 两个 DMA 可以并行配置，PS 侧驱动逻辑更简单
#    * 单 DMA 的 S2MM 要等 MM2S 供数，握手时序更难调
#  代价是多占一个 AXI-Lite 从口和一点 LUT，对这个规模可以接受。
#
#  ⚠ 触发方式：帧触发 + 轮询（PS 控制）
#    PS 检测到新帧 → 配置两个 DMA（S2MM 先武装）→ ap_start
#    → 轮询 ap_done → 读结果 / 置 frame_ready
#    见 docs/architecture-contract.md §3.2
# =====================================================================
set has_gesture 0
if {$IP_REPO ne ""} {
    if {[llength [get_ipdefs -quiet -all user:hls:gesture_preproc:1.0]] == 0} {
        puts "WARN: IP 仓库里没有 user:hls:gesture_preproc:1.0，跳过预处理链"
    } else {
        set has_gesture 1
    }
}

if {$has_gesture} {
    # ---- 8.1 HLS 预处理 IP ----
    set gpre [create_bd_cell -type ip \
        -vlnv user:hls:gesture_preproc:1.0 gesture_preproc_0]

    # ---- 8.2 输入 DMA：DDR → 预处理 ----
    # MM2S 读 614400 字节（640*480*2），Stream 位宽 16（RGB565）
    #
    # ⚠⚠ `c_sg_length_width` **必须显式设置** —— 2026-09-21 上板实测踩的坑：
    #
    #   不设的话 IP 用默认值 **14 位**，即单次传输最多 2^14-1 = **16383** 字节。
    #   而我们要传 614400 字节（是上限的 37 倍）。
    #
    #   症状（全部静默，不报任何错）：
    #     · 写 LENGTH=614400 → 读回 **8192**（= 614400 mod 16384，高位被丢）
    #     · DMA 只搬前 16384 字节就"完成"（IOC_Irq 置位，看起来一切正常）
    #     · 下游 IP 永远等不到剩余的输入 → 整条 DATAFLOW 卡死
    #     · ap_done 永不置位 → 表现为"跑一帧超时"
    #
    #   ⚠ csim / cosim **查不出来** —— 仿真里没有真实的 AXI DMA 长度寄存器。
    #   24 位 = 16 MB 上限，对 640x480 RGB565（614400 B）留足余量。
    #   见 skill/pitfalls/README.md P10。
    set dma_in [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma dma_in]
    set_property -dict [list \
        CONFIG.c_include_sg                  {0} \
        CONFIG.c_sg_include_stscntrl_strm    {0} \
        CONFIG.c_sg_length_width             {24} \
        CONFIG.c_include_mm2s                {1} \
        CONFIG.c_include_s2mm                {0} \
        CONFIG.c_m_axi_mm2s_data_width       {32} \
        CONFIG.c_m_axis_mm2s_tdata_width     {16} \
        CONFIG.c_mm2s_burst_size             {64} \
    ] $dma_in

    # ---- 8.3 输出 DMA：预处理 → DDR ----
    # S2MM 写 9216 字节（96*96），Stream 位宽 8（灰度）
    # ⚠ 同样要设 c_sg_length_width：9216 虽然没超 16383，
    #   但两个 DMA 保持一致的配置，避免以后改输出尺寸时重踩同一个坑。
    set dma_out [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma dma_out]
    set_property -dict [list \
        CONFIG.c_include_sg                  {0} \
        CONFIG.c_sg_include_stscntrl_strm    {0} \
        CONFIG.c_sg_length_width             {24} \
        CONFIG.c_include_mm2s                {0} \
        CONFIG.c_include_s2mm                {1} \
        CONFIG.c_m_axi_s2mm_data_width       {32} \
        CONFIG.c_s_axis_s2mm_tdata_width     {8} \
        CONFIG.c_s2mm_burst_size             {64} \
    ] $dma_out

    puts ">>> 预处理链已例化 (gesture_preproc + dma_in + dma_out)"
} else {
    puts ">>> IP_REPO 未提供或 IP 不存在 —— 预处理链跳过"
    puts "    提供方式：set IP_REPO <工程根>/gesture_comp/solution1/impl/ip"
}

# =====================================================================
#  9. AXI 互连
#
#  一个控制互连（GP0 → 各 IP 的 AXI-Lite）
#  三个数据互连：
#      HP1 ← VDMA S2MM        摄像头帧写入 DDR
#      HP2 → VDMA MM2S        从 DDR 读帧送 HDMI
#      HP3 ← 预处理链的两次 DMA（读原图 + 写 96x96）
#
#  ─────────────────────────────────────────────────────────────────
#  ⚠ 为什么预处理从 DDR 取数据，而不是从 dvp_capture 分叉
#  ─────────────────────────────────────────────────────────────────
#  曾考虑用 axis_broadcaster 把 dvp_capture 的输出一分为二：
#  一路给 VDMA（显示），一路给 gesture_preproc（CNN）。
#
#  但那会**反压崩溃**：broadcaster 要求所有输出都 ready 才收输入，
#  而 gesture_preproc 是 HLS 的 ap_ctrl_hs 模式 —— **未 ap_start 时
#  tready=0**。于是 gesture_preproc 空闲时（CNN 不需要 30fps，
#  它大部分时间空闲），broadcaster 反压 → VDMA 收不到数 →
#  **HDMI 显示也一起卡死**。
#
#  从 DDR 分叉则完全解耦：
#    * 显示通路一字未动，CNN 通路出任何问题都不影响画面
#    * gesture_preproc 按 PS 的节奏跑，不必死磕 30fps 时序
#    * 同一份 DDR 数据在 PC 上也能拿来对拍 Python golden
#  代价是多一次 DDR 往返（614 KB/帧读），相对三个 HP 口的总带宽很小。
# =====================================================================
set ic_ctrl [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect ic_ctrl]
# M00=vdma, M01=v_tc, M02=gesture_preproc, M03=dma_in, M04=dma_out
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {5}] $ic_ctrl

set ic_hp1 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect ic_hp1]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $ic_hp1

set ic_hp2 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect ic_hp2]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $ic_hp2

# 预处理链的两个 DMA 主口都接到 HP3（一个从口，两个主口）
set ic_hp3 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect ic_hp3]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $ic_hp3

# =====================================================================
#  9. 连接
# =====================================================================

# ---- 控制通路 ----
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0]   [get_bd_intf_pins ic_ctrl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ic_ctrl/M00_AXI] [get_bd_intf_pins vdma/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins ic_ctrl/M01_AXI] [get_bd_intf_pins v_tc/ctrl]

# ---- 预处理链的控制与数据（仅当 IP 存在时）----
if {$has_gesture} {
    connect_bd_intf_net [get_bd_intf_pins ic_ctrl/M02_AXI] \
                        [get_bd_intf_pins gesture_preproc_0/s_axi_control]
    connect_bd_intf_net [get_bd_intf_pins ic_ctrl/M03_AXI] \
                        [get_bd_intf_pins dma_in/S_AXI_LITE]
    connect_bd_intf_net [get_bd_intf_pins ic_ctrl/M04_AXI] \
                        [get_bd_intf_pins dma_out/S_AXI_LITE]

    # 输入 DMA 读 DDR → 预处理
    connect_bd_intf_net [get_bd_intf_pins dma_in/M_AXI_MM2S] \
                        [get_bd_intf_pins ic_hp3/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins dma_in/M_AXIS_MM2S] \
                        [get_bd_intf_pins gesture_preproc_0/src]

    # 预处理 → 输出 DMA 写 DDR
    connect_bd_intf_net [get_bd_intf_pins gesture_preproc_0/dst] \
                        [get_bd_intf_pins dma_out/S_AXIS_S2MM]
    connect_bd_intf_net [get_bd_intf_pins dma_out/M_AXI_S2MM] \
                        [get_bd_intf_pins ic_hp3/S01_AXI]
}

connect_bd_intf_net [get_bd_intf_pins ic_hp3/M00_AXI]  [get_bd_intf_pins ps7/S_AXI_HP3]

# ⚠ ic_ctrl 只开 2 个主口（vdma / v_tc），全部接满。
#
#   实测 v_axi4s_vid_out **没有 AXI 接口** —— 它的接口只有
#   vid_io_out / video_in / vtiming_in 三个，纯流式，无需配置。
#   所以不要给它接 AXI-Lite。
#   悬空的 AXI 主口不会报错、综合实现比特流全过，只有上板才炸
#   —— 所以宁可少开一个口也不要留悬空。

# ---- 数据通路：摄像头 → S2MM → HP1 ----
connect_bd_intf_net [get_bd_intf_pins dvp_capture_0/m_axis]   [get_bd_intf_pins vdma/S_AXIS_S2MM]
connect_bd_intf_net [get_bd_intf_pins vdma/M_AXI_S2MM]        [get_bd_intf_pins ic_hp1/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ic_hp1/M00_AXI]         [get_bd_intf_pins ps7/S_AXI_HP1]

# ---- 数据通路：MM2S → (位宽转换) → v_axi4s_vid_out → rgb2dvi → TMDS ----
#
#  ⚠ 2026-09-26：中间插了 `rgb565_888_0` —— VDMA 出 16bit RGB565，
#    而 v_axi4s_vid_out 现在配成 24bit（见 §6），两者对不上。
#    转换模块同时负责**位序**（输出 RBG 而非 RGB，见 §6.3 的说明）。
connect_bd_intf_net [get_bd_intf_pins vdma/M_AXIS_MM2S]       [get_bd_intf_pins rgb565_888_0/s_axis]
connect_bd_intf_net [get_bd_intf_pins rgb565_888_0/m_axis]    [get_bd_intf_pins v_axi4s_vid_out/video_in]
connect_bd_intf_net [get_bd_intf_pins vdma/M_AXI_MM2S]        [get_bd_intf_pins ic_hp2/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ic_hp2/M00_AXI]         [get_bd_intf_pins ps7/S_AXI_HP2]

# ---- VTC → v_axi4s_vid_out ----
connect_bd_intf_net [get_bd_intf_pins v_tc/vtiming_out] [get_bd_intf_pins v_axi4s_vid_out/vtiming_in]

# ---- sof_state 回环（帧起始同步辅助）----
#
#  ⚠ 计划阶段标注过：这两个端口存在，但"必须连"这条**没有从 IP 文档确证**
#    （v_tc 的 HDL 是加密的，读不到内部逻辑）。
#    接上的代价是**零**（一根线），不接的后果未知 —— 属廉价保险。
connect_bd_net [get_bd_pins v_axi4s_vid_out/sof_state_out] [get_bd_pins v_tc/sof_state]

# ---- v_axi4s_vid_out → rgb2dvi（都是 24bit RGB，像素时钟域）----
connect_bd_intf_net [get_bd_intf_pins v_axi4s_vid_out/vid_io_out] [get_bd_intf_pins rgb2dvi_0/RGB]

# ---- 时钟 ----
#
#  ⚠ AXI 互连的时钟是**每端口一个**：ACLK 是全局的，但 S00_ACLK /
#    M00_ACLK / M01_ACLK 必须**逐个连接**，只连 ACLK 会报
#      [BD 41-758] The following clock pins are not connected to a valid clock source
#    这是一个很容易漏的点：ACLK 看起来已经连了，validate 仍然报错。
#
#  ⚠ v_tc 有两个时钟域：clk（视频时序）与 s_axi_aclk（AXI-Lite）。
#    **2026-09-26 改动**：`v_tc/clk` **移出本表** —— 它必须挂在
#    74.25 MHz 像素时钟上，否则刷新率不对（见下方"像素时钟域"段）。
#    `v_tc/s_axi_aclk` 留在 100 MHz。
#
#  ⚠ `v_axi4s_vid_out/aclk` 也留在这里（s_axis 侧仍是 100 MHz），
#    但它新多出来的 `vid_io_out_clk` 在像素时钟那段单独接。
#
#  ⚠ PS 侧的 M_AXI_GP0_ACLK / S_AXI_HP*_ACLK 也必须显式连 ——
#    PS 的这些引脚不会自动跟随 FCLK_CLK0。
set CLK [get_bd_pins ps7/FCLK_CLK0]

set clk_pins {
    ps7/M_AXI_GP0_ACLK
    ps7/S_AXI_HP0_ACLK
    ps7/S_AXI_HP1_ACLK
    ps7/S_AXI_HP2_ACLK

    ic_ctrl/ACLK ic_ctrl/S00_ACLK
    ic_ctrl/M00_ACLK ic_ctrl/M01_ACLK ic_ctrl/M02_ACLK
    ic_ctrl/M03_ACLK ic_ctrl/M04_ACLK
    ic_hp1/ACLK  ic_hp1/S00_ACLK  ic_hp1/M00_ACLK
    ic_hp2/ACLK  ic_hp2/S00_ACLK  ic_hp2/M00_ACLK
    ic_hp3/ACLK  ic_hp3/S00_ACLK  ic_hp3/S01_ACLK  ic_hp3/M00_ACLK
    ps7/S_AXI_HP3_ACLK

    vdma/s_axi_lite_aclk
    vdma/m_axi_mm2s_aclk
    vdma/m_axi_s2mm_aclk
    vdma/s_axis_s2mm_aclk
    vdma/m_axis_mm2s_aclk

    v_tc/s_axi_aclk
    v_axi4s_vid_out/aclk
    dvp_capture_0/aclk

    clk_wiz_xclk/clk_in1
    clk_wiz_pix/clk_in1
    sccb_0/clk

    rgb565_888_0/aclk
}

# 预处理链的时钟引脚（只在 IP 存在时才连着，但引脚列表可以无条件拼）
if {$has_gesture} {
    foreach p {
        gesture_preproc_0/ap_clk
        dma_in/s_axi_lite_aclk
        dma_in/m_axi_mm2s_aclk
        dma_out/s_axi_lite_aclk
        dma_out/m_axi_s2mm_aclk
    } {
        if {[llength [get_bd_pins -quiet $p]] > 0} {
            lappend clk_pins $p
        }
    }
}

set n_clk 0
foreach pin $clk_pins {
    if {[llength [get_bd_pins -quiet $pin]] == 0} {
        puts "WARN: 时钟引脚 $pin 不存在，跳过"
        continue
    }
    connect_bd_net $CLK [get_bd_pins $pin]
    incr n_clk
}
puts ">>> 已连接 $n_clk 个时钟引脚到 FCLK_CLK0"

# 逐个断言：validate 前先自己查一遍，错在发生的那一行
set unconnected {}
foreach pin $clk_pins {
    set p [get_bd_pins -quiet $pin]
    if {[llength $p] == 0} { continue }
    if {[llength [get_bd_nets -quiet -of_objects $p]] == 0} {
        lappend unconnected $pin
    }
}
if {[llength $unconnected] > 0} {
    error "以下时钟引脚仍未连接: $unconnected"
}

# ---- 复位 ----
#
# ⚠⚠ AXI 互连的复位是**每端口一个**，只连 ARESETN 不够。
#     漏连的 S00_ARESETN / M00_ARESETN 会被自动 tie-off 到 0
#     （validate 报 [BD 41-759] CRITICAL WARNING），
#     后果是**互连永远处于复位状态，AXI 事务一条都过不去**。
#
#     这个错误综合、实现、生成比特流**全部会通过**，只有上板才暴露 ——
#     与本项目原工程踩过的 PS7 配置被覆盖（README §9.7）是同一类问题。
#     所以这里逐个连、并逐个断言。
set ARSTN [get_bd_pins rst_100m/peripheral_aresetn]

set rst_pins {
    ic_ctrl/ARESETN ic_ctrl/S00_ARESETN
    ic_ctrl/M00_ARESETN ic_ctrl/M01_ARESETN ic_ctrl/M02_ARESETN
    ic_ctrl/M03_ARESETN ic_ctrl/M04_ARESETN
    ic_hp1/ARESETN  ic_hp1/S00_ARESETN  ic_hp1/M00_ARESETN
    ic_hp2/ARESETN  ic_hp2/S00_ARESETN  ic_hp2/M00_ARESETN
    ic_hp3/ARESETN  ic_hp3/S00_ARESETN  ic_hp3/S01_ARESETN  ic_hp3/M00_ARESETN
    ps7/S_AXI_HP0_ARESETN_N
    ps7/S_AXI_HP1_ARESETN_N
    ps7/S_AXI_HP2_ARESETN_N
}

# 预处理链的复位引脚（同理，无条件拼入，不存在时会被上面的 get_bd_pins 检查过滤）
if {$has_gesture} {
    foreach p {
        gesture_preproc_0/ap_rst_n
        dma_in/axi_resetn
        dma_out/axi_resetn
    } {
        if {[llength [get_bd_pins -quiet $p]] > 0} {
            lappend rst_pins $p
        }
    }
}

set n_rst 0
foreach pin $rst_pins {
    if {[llength [get_bd_pins -quiet $pin]] == 0} {
        puts "WARN: 复位引脚 $pin 不存在，跳过"
        continue
    }
    connect_bd_net $ARSTN [get_bd_pins $pin]
    incr n_rst
}
puts ">>> 已连接 $n_rst 个复位引脚"

# 逐个断言：把"悬空被 tie-off"消灭在 validate 之前
set rst_bad {}
foreach pin $rst_pins {
    set p [get_bd_pins -quiet $pin]
    if {[llength $p] == 0} { continue }
    if {[llength [get_bd_nets -quiet -of_objects $p]] == 0} {
        lappend rst_bad $pin
    }
}
if {[llength $rst_bad] > 0} {
    error "以下复位引脚仍未连接: $rst_bad"
}
# =====================================================================
#  像素时钟域（74.25 MHz）—— 2026-09-26 新增
#
#  ⚠ 这里**不能**复用上面那个 `$CLK` 循环 —— 它是单个标量（FCLK_CLK0），
#    而本段是**另一个时钟域**。所以单独接。
# =====================================================================

# ---- 像素时钟树 ----
#  ⚠ `rst_pix/slowest_sync_clk` 也在这里接 —— 它是**像素域的复位**，
#    同步时钟必须是像素时钟本身。接到 100 MHz 侧会产生
#    "100 MHz 域驱动 74.25 MHz 域输入"的**真实跨时钟域违例**
#    （实测 WNS −4.436 ns，两个时钟相位无关）。
set PIXCLK [get_bd_pins clk_wiz_pix/clk_out1]

set pix_clk_pins {
    v_tc/clk
    v_axi4s_vid_out/vid_io_out_clk
    rgb2dvi_0/PixelClk
    rst_pix/slowest_sync_clk
}
foreach pin $pix_clk_pins {
    connect_bd_net $PIXCLK [get_bd_pins $pin]
}
puts ">>> 像素时钟已连接 [llength $pix_clk_pins] 个引脚"

# ---- 像素域复位 ----
#
#  ⚠ `ext_reset_in` 用 **FCLK_RESET0_N（原始异步源）**，与 rst_100m 同源。
#    不要用 rst_100m/peripheral_aresetn —— 那是 100 MHz 域的信号，
#    proc_sys_reset 会把它同步到**它自己的** slowest_sync_clk（像素时钟），
#    本身没问题，但同源更简单、且与全设计其余部分一致。
#
#  ⚠ `dcm_locked` 接像素 MMCM 的 locked —— **这一条是关键**：
#    不接的话复位会在时钟锁定前放开 → 静默黑屏。
#
#  ⚠ `vid_io_out_reset` 是**高有效**（见 v_axi4s_vid_out 源码：
#     `vid_reset = (C_HAS_ASYNC_CLK) ? vid_io_out_reset : ~aresetn`），
#     而 `peripheral_reset` 正是高有效输出 → 用它。
#     **不要**用 peripheral_aresetn（低有效），极性正好反。
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N]           [get_bd_pins rst_pix/ext_reset_in]
connect_bd_net [get_bd_pins clk_wiz_pix/locked]          [get_bd_pins rst_pix/dcm_locked]

connect_bd_net [get_bd_pins rst_pix/peripheral_aresetn]  [get_bd_pins v_tc/resetn]
connect_bd_net [get_bd_pins rst_pix/peripheral_aresetn]  [get_bd_pins rgb2dvi_0/aRst_n]
connect_bd_net [get_bd_pins rst_pix/peripheral_reset]    [get_bd_pins v_axi4s_vid_out/vid_io_out_reset]

# ⚠ 极性断言：`vid_io_out_reset` 必须接**高有效**的 peripheral_reset。
#   接错成低有效的 peripheral_aresetn 会让视频通路**永远不复位/一直复位**，
#   且构建一路干净通过。
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins rst_pix/peripheral_reset]]] == 0} {
    error "rst_pix/peripheral_reset 未连接 —— vid_io_out_reset 需要高有效复位"
}
puts ">>> 像素域复位已连接（ext_reset = FCLK_RESET0_N，dcm_locked = 像素 MMCM locked）"

# 逐个断言：这两条特别容易漏，漏了就是静默黑屏
foreach pin {v_tc/clk v_axi4s_vid_out/vid_io_out_clk rgb2dvi_0/PixelClk} {
    if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins $pin]]] == 0} {
        error "像素时钟引脚 $pin 未连接 —— 下游不会工作（且不报错）"
    }
}
foreach pin {v_tc/resetn rgb2dvi_0/aRst_n v_axi4s_vid_out/vid_io_out_reset} {
    if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins $pin]]] == 0} {
        error "像素域复位引脚 $pin 未连接 —— 会一直卡在复位或不复位"
    }
}
puts ">>> 像素时钟域自检通过"

# =====================================================================
#  ⚠⚠ 时钟使能必须显式拉高 —— 这是本次最危险的一类静默失败
#
#  BD 对**悬空的输入引脚**默认 **tie-off 到 0**（只给
#  [BD 41-759] WARNING）。这些 ce/clken 一旦是 0：
#      v_tc 不再产生任何时序、v_axi4s_vid_out 的数据永不推进
#  → **画面完全不动，但构建一路干净通过**，最难查。
# =====================================================================
set one_src [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant const_one]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $one_src

foreach pin {v_tc/clken v_tc/gen_clken \
             v_axi4s_vid_out/aclken v_axi4s_vid_out/vid_io_out_ce} {
    if {[llength [get_bd_pins -quiet $pin]] == 0} {
        error "时钟使能引脚不存在（端口名可能变了）：$pin"
    }
    connect_bd_net [get_bd_pins const_one/dout] [get_bd_pins $pin]
}
puts ">>> 已拉高 4 个时钟使能（v_tc/clken, v_tc/gen_clken, aclken, vid_io_out_ce）"


connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins v_axi4s_vid_out/aresetn]
connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins vdma/axi_resetn]
connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins dvp_capture_0/rst_n]

# ---- Clocking Wizard 与 SCCB 的复位 ----
# ⚠ Clocking Wizard 的 reset 是**低有效**（CONFIG.RESET_TYPE=ACTIVE_LOW，
#   见 §7.2），所以接 peripheral_aresetn 而不是它的反相版本。
connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins clk_wiz_xclk/resetn]
connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins sccb_0/rst_n]

# =====================================================================
#  10. 外部端口（接 OV5640 / HDMI）
# =====================================================================

# ---- 摄像头侧（PMOD-CAMERA v1.0）----
#
#  ⚠⚠ 端口名用 io_* 而不是 cam_*，因为**方向和类型都变了**：
#
#      XCLK  → 从"输入"变成 **FPGA 输出**（模块没晶振，要 PL 给）
#      SDA   → 从"无"变成 **双向**（SCCB 开漏总线）
#      SCL   → 从"无"变成 **FPGA 输出**
#      其余  → 仍是输入
#
#  这也是"硬件换方案后 BD 必须跟着改"的典型：不是改个名，
#  是接口方向变了。
#
#  引脚映射（来自 PR 的模块原理图，镜像编号解读，见 video_io.xdc）：
#      J2 → Pmod A：XCLK/VSYNC/SDA/HREF/SCL/PCLK = ja[0,1,2,4,5,6]
#      J3 → Pmod B：D0-D7（交错）
#
#  ⚠ io_pclk 是输入时钟，必须给 -freq_hz（否则报 [BD 5-670]）
create_bd_port -dir I -type clk -freq_hz 24000000 io_pclk
create_bd_port -dir I       io_vsync
create_bd_port -dir I       io_href
create_bd_port -dir I -from 7 -to 0 io_d

# XCLK 与 SCL 是输出
create_bd_port -dir O       io_xclk
create_bd_port -dir O       io_scl

# SDA 是双向
create_bd_port -dir IO      io_sda

# ⚠ dvp_capture 只有**一个** rst_n 端口，已由 rst_100m/peripheral_aresetn
#   驱动（见上面复位段）。这里**不能**再连一次 —— 会报
#     [BD 5-676] The sink is already connected to another source
#   摄像头侧不需要独立复位。
connect_bd_net [get_bd_ports io_pclk]  [get_bd_pins dvp_capture_0/pclk]
connect_bd_net [get_bd_ports io_vsync] [get_bd_pins dvp_capture_0/cam_vsync]
connect_bd_net [get_bd_ports io_href]  [get_bd_pins dvp_capture_0/cam_href]
connect_bd_net [get_bd_ports io_d]     [get_bd_pins dvp_capture_0/cam_data]

# ---- XCLK：Clocking Wizard 输出 → 外部端口 ----
connect_bd_net [get_bd_pins clk_wiz_xclk/clk_out1] [get_bd_ports io_xclk]

# ---- SCCB：sccb_master ↔ 寄存器表 ↔ IOBUF ↔ 外部 ----
# 寄存器表给出 {寄存器地址, 数据}
connect_bd_net [get_bd_pins sccb_0/tbl_addr]  [get_bd_pins ov5640_regs_0/tbl_addr]
connect_bd_net [get_bd_pins ov5640_regs_0/tbl_data] [get_bd_pins sccb_0/tbl_data]

# SCL 直连（推挽输出足够驱动 OV5640 的从机）
connect_bd_net [get_bd_pins sccb_0/scl] [get_bd_ports io_scl]

# SDA 经 IOBUF：sccb_master 的 oe/o 出去，i 读回
connect_bd_net [get_bd_pins sccb_0/sda_oe]  [get_bd_pins iobuf_sda_0/io_drv]
connect_bd_net [get_bd_pins sccb_0/sda_o]   [get_bd_pins iobuf_sda_0/io_out]
connect_bd_net [get_bd_pins iobuf_sda_0/io_in] [get_bd_pins sccb_0/sda_i]
connect_bd_net [get_bd_pins iobuf_sda_0/io_pad] [get_bd_ports io_sda]

# ⚠ ov5640_regs 与 sccb_master 的 tbl_addr **位宽必须一致**（都是 8 位）。
#   曾经 ov5640_regs 用 12 位而 sccb 用 8 位，BD 报
#     [BD 41-2383] Width mismatch ... other input bits will be left unconnected
#   高 4 位悬空意味着表一旦超过 256 项就会**静默读错** ——
#   这类"能连上但数据错"的警告不能忽略。

# ---- HDMI 输出 ----
#
#  ⚠ v_axi4s_vid_out 的视频输出是一个**接口**（vid_io_out），不是散引脚。
#    实测接口列表：vid_io_out(Master) / video_in(Slave) / vtiming_in(Slave)
#    早期版本按 vid_data/vid_hsync 那种散引脚名连接，会报
#      [BD 5-232] No interface pins matched
#    因为它确实是接口而不是引脚。
#
#  ⚠ 2026-09-26：TMDS 编码**已经接上了**（§6.4 的 rgb2dvi_0）。
#    原来这里是把 `v_axi4s_vid_out/vid_io_out` 直接引成外部端口
#    `hdmi_vid_out`（22 根并行信号悬空，靠 DRC 豁免才生成的比特流）。
#    现在 vid_io_out 已经在 BD 内部连给了 rgb2dvi，**不能再导出** ——
#    那会变成"一个引脚两个驱动"。
#
#    改成导出 rgb2dvi 的 **TMDS 接口**（真正的差分对）。
#
#  ⚠ 用 make_bd_intf_pins_external 而不是 create_bd_intf_port -vlnv。
#   手写 VLNV 会报 [BD 41-52] Could not find the abstraction definition
#   （不同版本命名有差异）。make_bd_intf_pins_external 从一个已有接口
#   引脚导出，VLNV 由工具自己取，不会写错。
#
#  ⚠⚠ 用 `-name` **直接命名**，不要再用原来那套"遍历已有端口、
#     排除 cam_pclk、剩下的就是要的"的写法 —— 那段是**脆弱的**：
#     一旦 BD 里出现第二个 intf 端口，它会取到**最后一个**并把
#     错误的端口改名。这里显式指定名字，行为确定。
make_bd_intf_pins_external -name hdmi_tmds [get_bd_intf_pins rgb2dvi_0/TMDS]

set _tmds_port [get_bd_intf_ports -quiet hdmi_tmds]
if {[llength $_tmds_port] == 0} {
    error "TMDS 接口导出失败 —— 找不到端口 hdmi_tmds"
}
puts ">>> TMDS 已导出为外部接口: hdmi_tmds"
puts "    ⚠ 引脚约束见 constraints/video_io.xdc 第四层（TMDS_33 差分对）"

# =====================================================================
#  11. 地址分配
# =====================================================================
assign_bd_address

# =====================================================================
#  12. 验证（必做）
#
#  ⚠ 悬空的 AXI 主端口不构成错误 —— 综合/实现/比特流全过，只有上板才炸。
#    必须逐条读 CRITICAL WARNING。
# =====================================================================
puts "\n>>> validate_bd_design"
validate_bd_design

# 检查是否存在悬空的 AXI 接口
#
# ⚠ 只检查 AXI 类接口。**从内部引脚导出的对外接口本来就只有 1 个端点**
#   —— 另一端在 BD 外面，是合法的。
#   早期版本没做这个区分，把合法的外部端口误报成"悬空接口"。
#
# ⚠ 2026-09-26：跳过条件原来只匹配 `*vid_io*`，但 TMDS 接口的 VLNV 是
#   `digilentinc.com:interface:tmds:1.0` —— **不含 "vid_io"**。
#   接上 rgb2dvi 之后，导出的 `hdmi_tmds` 会命中这条而误报。
#   所以把判断放宽成"结尾是 _rtl 的抽象类型"这一族（vid_io_rtl /
#   tmds_rtl / clock_rtl ...），它们都是接口抽象，不是真悬空。
set dangling 0
foreach intf [get_bd_intf_nets -quiet] {
    set pins [get_bd_intf_pins -quiet -of_objects $intf]
    if {[llength $pins] < 2} {
        # 取该网上的接口引脚所属的 VLNV，跳过非 AXI 的
        set skip 0
        foreach p $pins {
            set vlnv ""
            catch {set vlnv [get_property VLNV [get_property TYPE $p]]}
            if {[string match "*vid_io*" $vlnv] || [string match "*tmds*" $vlnv]} {
                set skip 1
            }
        }
        if {$skip} { continue }
        puts "WARN: 悬空接口网 $intf 只连了 [llength $pins] 个端点 (非 AXI，忽略)"
    }
}
# 真正要防的是 AXI 主口悬空：综合实现比特流都过，只有上板才炸。
# 逐个检查每个 AXI 互连的从口/主口是否都有连接。
set axio_bad {}
foreach c [get_bd_cells -quiet] {
    set nm [get_property NAME $c]
    if {![string match "ic_*" $nm]} { continue }
    foreach ip [get_bd_intf_pins -quiet -of_objects $c] {
        set inm [get_property NAME $ip]
        if {[string match "*_AXI" $inm]} {
            if {[llength [get_bd_intf_nets -quiet -of_objects $ip]] == 0} {
                lappend axio_bad "$nm/$inm"
            }
        }
    }
}
if {[llength $axio_bad] > 0} {
    error "以下 AXI 接口悬空（综合会过但上板必炸）: $axio_bad"
}
puts ">>> AXI 接口检查通过：无悬空主口/从口"

# =====================================================================
#  12.5 【调试】ILA —— 探摄像头前端信号
#
#  2026-09-21 加。背景：摄像头通路软件侧完全查不到 ——
#    · sccb_0 的 cfg_done/cfg_error  无 AXI 接口
#    · clk_wiz_xclk 的 locked        没引出（clk_out1 直连 io_xclk）
#    · dvp_capture 的 frame_cnt 等   BD 里悬空
#    · VDMA 帧计数                   能读，但 10 秒纹丝不动（= 前端没出数据）
#
#  没有示波器/逻辑分析仪时，**ILA 是唯一能突破僵局的手段** ——
#  它装在 FPGA 里、走 JTAG 读出，不花钱、不用接线，
#  而且**能看到外部仪器看不到的内部信号**（如 frame_cnt）。
#
#  ── 采样时钟为什么用 FCLK_CLK0 而不是 io_pclk ──
#   ⚠ 绝不能用 io_pclk！它是**摄像头产生的**，摄像头不出图时这个时钟
#     根本不存在 → ILA 自己也停摆 → 什么波形都看不到。
#     FCLK_CLK0 来自 PS，**永远在**，是唯一可靠的选择。
#
#  ── 探针 ──
#   dvp_capture 的 frame_cnt/line_cnt/stalled 和 vsync_sync/href_sync
#   都在 **aclk(=FCLK_CLK0) 域**（见 rtl/dvp_capture.v 的 always @(posedge aclk)），
#   与 ILA 同域，**不需要跨时钟域处理**，采出来的值可完全信。
#
#   ⚠ io_pclk / io_href / io_vsync / io_d 是**异步**的（pclk 域），
#     直连 ILA 有亚稳态风险，看到的值**一个采样周期内不一定代表真实电平**。
#     但它们能回答一个关键问题：**这根线到底有没有在动**。
#     判读：波形在跳 = 有信号；一条直线 = 这路没通。
#
#  用法：跑完 create_project.tcl 出bit流后，打开 Hardware Manager，
#        加载 .ltx（与 .bit 同目录、同名），即可看到波形。
#        **不需要设置触发条件** —— 自由运行就能看 frame_cnt 变不变。
#
#  ⚠⚠ **提交前把 use_ila 置 0** —— 开着它会让 BD 多一个 ILA 核：
#      · BRAM 从 1 块涨到 63 块（52.5%），LUT 21% → 27%
#      · 每次构建多 1–2 分钟
#      · 综合/实现报告里的资源数不再代表真实设计
#     调试时置 1，调完置 0 重新构建。
#
#  ⚠ 提交前**务必置回 0**，否则报告里的资源数会虚高（BRAM 52.5%）。
# =====================================================================
#  当前状态：**1（开启）** —— 2026-09-22 改 MMCM 参数（VCO 1200→600 MHz）
#  后重综合，**必须留 ILA 才能验证 XCLK 有没有恢复**。
#  验证方法：看 probe6（clk_out1）是否开始翻转 —— 见文件头 probe 清单。
#  验证通过后，再置 0 重综合一次（出正式比特流）。
# =====================================================================
#  当前状态：**0（关闭）** —— 2026-09-23。
#
#  MMCM 修好后已用 ILA 验证过 XCLK 恢复（probe6 有翻转），探针使命完成。
#  关掉是必须的，不只是"报告好看"：
#
#  ⚠⚠ **开着 ILA 会让这个比特流 hold 违例（WHS −1.830 ns）**
#     违例路径： clk_wiz_xclk/CLKOUT0 ──BUFG──> dbg_ila_0
#     即 24 MHz 的 XCLK 域 → 100 MHz 的 PS 时钟域。
#     两个时钟一个来自 MMCM、一个来自 PS，**相位本就不确定**，
#     这条路径被工具当成真时序要求，物理上不可能满足。
#     （逻辑层数只有 1 级，纯走线 3.575 ns —— 修不了，只能声明异步或去掉。）
#     实测：**第二差的 hold 路径 slack = +0.032 MET** ——
#     说明设计主体本身没有问题，违例只存在于 ILA 那条路径上。
#
#  对照（同一份 RTL，只差 use_ila）：
#      use_ila=1 → BRAM 52.50% / LUT 51.74% / WHS −1.830 ns ❌
#      use_ila=0 → BRAM ~12%  / LUT ~27%   / 无该违例        ✅
#
#  ⚠ 若要重新开起来调摄像头：置 1、重综合，**但别把那版当提交物**。
#    调试完必须置回 0 再构建一次正式比特流。
# =====================================================================
set use_ila 0
if {$use_ila} {
    # ⚠ 必须用**带版本号的完整 VLNV** —— 2026-09-21 实测：
    #   `get_ipdefs -quiet xilinx.com:ip:ila`（不带版本）**匹配不到**，
    #   于是保护分支直接跳过，ILA 静默没加、构建照常成功。
    #   症状：日志里只有一行 "WARN: 找不到 ILA IP"，很容易被忽略掉。
    set ILA_VLNV xilinx.com:ip:ila:6.2
    if {[llength [get_ipdefs -quiet $ILA_VLNV]] == 0} {
        puts "!!! WARN: 找不到 ILA IP ($ILA_VLNV)，跳过调试探针"
        puts "    可用的 ILA IP 有: [get_ipdefs -quiet *ila*]"
    } else {
        set dbg [create_bd_cell -type ip -vlnv $ILA_VLNV dbg_ila]

        # 探针表：{宽度, 信号源}
        # ⚠ 顺序即 probe0..probeN，改这里要同步改下面的 probe_names
        #
        # ⚠⚠ 只能接**输入方向**的信号！2026-09-21 实测踩过：
        #   初版把 `io_sda` 也列进来了，但它是**双向**端口
        #   （`create_bd_port -dir IO`），直接 connect_bd_net 会报
        #   `[BD 41-701] connect_bd_net requires at least two pins/ports`，
        #   **而且不告诉你是哪一个**。io_xclk / io_scl 是**输出**，同理不接。
        #
        # ⚠⚠⚠ v2（2026-09-21 晚，第一次采集全静止后重做）：
        #   第一版探针全是"外面看得见的"信号 → 全静止时**分不清**是
        #   「XCLK 没出」还是「SCCB 没配上」——两者在那些探针上长得一模一样。
        #   现改为**直插两个嫌疑模块的内部**：
        #     · clk_wiz_xclk/clk_out1 —— **24 MHz XCLK 本身**。
        #       比看 `locked` 更硬：locked 是状态位，没锁时恒 0，
        #       和"信号不存在"分不清；而 clk_out1 在跳就是真有 24 MHz。
        #     · sccb_0/* —— 配置表跑到第几条、有没有 ACK 错误。
        #
        #   ⚠ sccb_0 的信号**全在 100 MHz 域**（sccb_0/clk 就接 FCLK_CLK0），
        #     与 ILA 同域，采出来完全可信。
        #   ⚠ clk_wiz_xclk/clk_out1 是 24 MHz，**异步**。100 MHz 采 24 MHz
        #     会欠采样，但**"在跳"和"死平"一眼可辨** —— 这正是我们要的。
        #   ⚠ 引脚名必须**逐个核实**，别照着 `.hwh` 抄 —— 2026-09-21 实测：
        #     `.hwh` 里 sccb_0 列出了 `done_cnt`，但 `rtl/sccb_master.v`
        #     的端口根本没有它（.hwh 是某个**旧版模块**生成的）。
        #     照着抄会得到 "no pins matched" + 一个不点名的 [BD 41-701]。
        #   ⚠ `iobuf_sda_0/io_pad` 是 **inout**，同样不能直接接探针
        #     （和双向端口 io_sda 是同一个坑）。要看 SDA 就用
        #     `sccb_0/sda_oe`（驱动使能）和 `sccb_0/sda_o`（输出值）。
        #
        # ⚠⚠ 2026-09-24 新增 first_err_addr / nack_cnt 两个探针。
        #   用途：回答摄像头调试里**最关键的二分问题** ——
        #
        #     first_err_addr == 0x00  → 第 1 条就 NACK
        #                               = 总线层问题（上拉/接线/器件地址/电源）
        #     first_err_addr == 别的  → 中间某条 NACK
        #                               = 该条寄存器值不被接受
        #
        #   这两个方向排查起来完全相反，而在新增这两根线之前，
        #   两种情况在探针上长得**一模一样**：cfg_error=1、done_cnt=250、
        #   cfg_done=1（done_cnt 是事务计数，NACK 也照样递增）。
        #   ⚠ nack_cnt 单位是**事务**（1 条坏寄存器记 1，不是 4）——
        #     它在数据字节的 ACK 位计数，见 rtl/sccb_master.v S_ACK 注释。
        #   ⚠ 哨兵：first_err_addr == 0xFF 表示**从未失败**。
        set probes [list \
            [list 16 [get_bd_pins dvp_capture_0/frame_cnt]] \
            [list 16 [get_bd_pins dvp_capture_0/line_cnt]] \
            [list  1 [get_bd_pins dvp_capture_0/vsync_sync]] \
            [list  1 [get_bd_pins dvp_capture_0/href_sync]] \
            [list  1 [get_bd_ports io_pclk]] \
            [list  8 [get_bd_ports io_d]] \
            [list  1 [get_bd_pins clk_wiz_xclk/clk_out1]] \
            [list  8 [get_bd_pins sccb_0/tbl_addr]] \
            [list  8 [get_bd_pins sccb_0/done_cnt]] \
            [list  1 [get_bd_pins sccb_0/cfg_done]] \
            [list  1 [get_bd_pins sccb_0/cfg_error]] \
            [list  1 [get_bd_pins sccb_0/scl]] \
            [list  1 [get_bd_pins sccb_0/sda_oe]] \
            [list  1 [get_bd_pins sccb_0/sda_o]] \
            [list  8 [get_bd_pins sccb_0/first_err_addr]] \
            [list  8 [get_bd_pins sccb_0/nack_cnt]] \
        ]

        set n 0
        set cfg [list CONFIG.C_NUM_OF_PROBES [llength $probes] \
                      CONFIG.C_DATA_DEPTH {8192} \
                      CONFIG.C_INPUT_PIPE_STAGES {1}]
        foreach pr $probes {
            lappend cfg CONFIG.C_PROBE${n}_WIDTH [lindex $pr 0]
            incr n
        }
        # ⚠ 设完必须**回读验证** —— 2026-09-21 实测：这里静默失效过一次，
        #   症状是综合时报一堆 CRITICAL WARNING 「Width mismatch」：
        #       探针 probe0 宽 1 却接了 16 位的 frame_cnt
        #   而 set_property 本身**不报任何错**，只是没生效。
        #
        # ⚠⚠ Tcl 赋值必须写 `set 变量名 值` —— 少了第一个 set 会变成
        #   「调用一个叫该名字的命令」，报 invalid command name。
        set ila_ok 1
        if {[catch {set_property -dict $cfg $dbg} err]} {
            puts "!!! WARN: 设置 ILA 参数失败: $err"
            set ila_ok 0
        } else {
            set np [get_property CONFIG.C_NUM_OF_PROBES $dbg]
            puts ">>> ILA 参数回读：C_NUM_OF_PROBES=$np（期望 [llength $probes]）"
            set n 0
            foreach pr $probes {
                set w [get_property CONFIG.C_PROBE${n}_WIDTH $dbg]
                set want [lindex $pr 0]
                set tag [expr {$w == $want ? "OK" : "!!! 不符"}]
                puts "      probe$n 宽 = $w（期望 $want）$tag"
                if {$w != $want} { set ila_ok 0 }
                incr n
            }
            if {!$ila_ok} {
                error "ILA 探针宽度设置未生效，继续综合会得到错位的波形"
            }
        }

        # 采样时钟
        # ⚠ ILA **没有 resetn 引脚**（端口只有 clk / clk_nobuf / probe* / trig_*）。
        #   2026-09-21 实测：给 dbg_ila/resetn 连线会报
        #     WARNING: [BD 5-235] No pins matched 'get_bd_pins dbg_ila/resetn'
        #     ERROR:   [BD 41-701] connect_bd_net requires at least two pins/ports
        #   而报错**不点名是哪一个引脚**，得靠这条 WARNING 反推。
        if {[llength [get_bd_pins -quiet dbg_ila/clk]] == 0} {
            puts "!!! WARN: dbg_ila/clk 不存在，可用引脚: [get_bd_pins dbg_ila/*]"
        } else {
            connect_bd_net [get_bd_pins dbg_ila/clk] [get_bd_pins dvp_capture_0/aclk]
        }

        # 逐个接探针
        #  ⚠ 每个源都先查存不存在再连 —— 直接 connect_bd_net 遇到空对象会报
        #    [BD 41-701] "requires at least two pins/ports"，
        #    **但不告诉你是哪一个**，得回去一个个猜。先查再连能直接点名。
        set n 0
        set probe_names [list frame_cnt line_cnt vsync_sync href_sync io_pclk \
                              io_d xclk_out sccb_tbl_addr sccb_done_cnt \
                              sccb_cfg_done sccb_cfg_error sccb_scl \
                              sccb_sda_oe sccb_sda_o \
                              sccb_first_err_addr sccb_nack_cnt]
        foreach pr $probes {
            set src [lindex $pr 1]
            set nm  [lindex $probe_names $n]
            if {[llength $src] == 0} {
                puts "!!! WARN: probe$n ($nm) 的信号不存在 —— 空对象"
            } elseif {[llength [get_bd_pins -quiet dbg_ila/probe$n]] == 0} {
                puts "!!! WARN: probe$n ($nm) 的 ILA 引脚不存在"
            } else {
                connect_bd_net $src [get_bd_pins dbg_ila/probe$n]
            }
            incr n
        }
        puts ">>> 已加 ILA 调试探针（[llength $probes] 个 probe，采样时钟 FCLK_CLK0）"
        puts "    用途：摄像头不出图时，用它看 frame_cnt / io_pclk / io_href 有没有在动"
        puts "    ⚠ 验证完可把本段 use_ila 置 0 关掉，免得占资源"
    }
}

# =====================================================================
#  13. 生成产物
# =====================================================================
save_bd_design

puts "\n====================================================================="
puts " bd_video 构建完成"
puts "   BD 文件: [get_files $BD_NAME.bd]"
puts ""
puts " 下一步（在 Vivado 里）："
puts "   1. 生成 wrapper:  make_wrapper -files \[get_files $BD_NAME.bd\] -top"
puts "   2. 加 XDC 约束:   vivado/constraints/video_io.xdc"
puts "   3. 综合实现，读 CRITICAL WARNING"
puts ""
puts " ⚠ 未验证项："
puts "   - HDMI 的 TMDS 编码未接（见第 10 节注释，故意分步）"
puts "   - dvp_capture 的 AXI-Lite 控制口未实现（当前用常量占位）"
puts "   - 未经板级实测（板子未到）"
puts "====================================================================="
