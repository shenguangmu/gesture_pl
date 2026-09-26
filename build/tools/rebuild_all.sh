#!/usr/bin/env bash
# =====================================================================
#  rebuild_all.sh —— 从源码到比特流，一键重建（清掉所有缓存）
#
#  为什么需要这个脚本
#  ---------------------------------------------------------------------
#  2026-09-23 踩的坑：csim/cosim 全过、RTL 里 roi_y 明明用上了，
#  但板上那份 bit 行为等同 roi_y=0 —— **Vivado 构建时取了旧 IP**。
#
#  根因有三条，脚本逐条堵死：
#    1. HLS 导出的 IP 版本号**永远是 "1.0"**（run_gesture.tcl 里写死），
#       新旧 IP 的 VLNV 完全相同 → Vivado 不会察觉换了实现
#    2. HLS 产物（gesture_comp/）不在仓库里，**容易忘跑**
#    3. 工程目录里有多处 IP 缓存（.cache / .gen / .runs），只删一处不够
#
#  所以：每次都**全清 + 顺序重跑**。宁可多花 5 分钟，不要一个错的 bit。
#
#  用法（在仓库根目录）：
#      bash build/tools/rebuild_all.sh            # 只重建
#      bash build/tools/rebuild_all.sh --upload   # 重建 + 传板并校验 md5
#
#  ⚠ 目录约定（2026-09-26 重排后）
#      <repo>/src/HLS/          HLS 源码
#      <repo>/src/RTL/          RTL 源码
#      <repo>/gesture_comp/     HLS 产物 —— ⚠ 在**仓库根**，不在 build/ 下
#      <repo>/build/            构建脚本与 Vivado 产物
#        ├── vivado/            工程与脚本
#        ├── rebuild_*.log      构建日志
#        └── tools/             本脚本
#
#  ⚠⚠ 为什么 gesture_comp/ 不在 build/ 下（别"顺手整理"回去）：
#     Vitis HLS 2025.2 在工程目录比仓库根深两级时，会把设计文件的注册
#     路径算错成 `../src/HLS/gesture_preproc.cpp`（解析后指向不存在的
#     build/src/HLS/）→ 设计文件不进 csim 编译清单 → 链接失败。
#     放回仓库根就正常。详见 src/HLS/run_gesture.tcl 的 comp_dir 注释。
# =====================================================================
set -euo pipefail

# ⚠ 本脚本在 <repo>/build/tools/ 下 → 仓库根要上溯**两级**
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BLD="$REPO/build"
HLS_COMP="$REPO/gesture_comp"

# =====================================================================
#  工具链定位（**不写死路径** —— 那会让"可复现"变成空话）
#
#  赛题 §3.3.4 要求「工程可由他人从零复现」。原先这里把 Vitis/Vivado
#  的绝对路径写死到开发机的 D 盘，**换台机器直接跑不起来**，
#  而且报错是"找不到文件"，看不出是路径问题。
#
#  按下面顺序找，第一个命中的就用：
#    ① 环境变量（Xilinx 官方 settings64 会设这两个，最标准）
#    ② 本机已知位置（开发机的盘符，**只作便捷回退**）
#    ③ PATH 里直接能调到的命令
#
#  ⚠ 想手工指定就用环境变量：
#      VITIS_RUN=/path/to/vitis-run VIVADO=/path/to/vivado bash build/tools/rebuild_all.sh
# =====================================================================
find_tool() {
    # $1 = 环境变量给的路径（可为空）  $2 = 候选路径列表  $3 = 命令名
    #
    # ⚠ 为什么用 `-f` 而不是 `-x` 判断候选：
    #   Windows 的启动器 `.bat` 在 Git Bash 里是 `-rw-r--r--`（**没有可执行位**），
    #   用 `-x` 判断会**永远失败**。而 Xilinx 同时装了无扩展名的
    #   `vitis-run`（bash 脚本，有 +x）和 `vitis-run.bat` 两个版本。
    #   所以：候选只要有**这个文件**就接受（能不能跑由调用方决定）。
    [ -n "$1" ] && [ -f "$1" ] && { echo "$1"; return; }
    for c in $2; do
        [ -f "$c" ] && { echo "$c"; return; }
    done
    command -v "$3" 2>/dev/null && return
    echo ""
}

# ① 环境变量（官方 settings64.sh 设的）
VITIS_HINT="${XILINX_VITIS:+$XILINX_VITIS/bin/vitis-run.bat}"
VIVADO_HINT="${XILINX_VIVADO:+$XILINX_VIVADO/bin/vivado.bat}"

# ② 本机已知位置（开发机；换机器时把这里改成你自己的，或用环境变量）
LOCAL_CAND="/d/BaiduNetdiskDownload/2025.2 /c/Xilinx/2025.2 /opt/Xilinx/2025.2"

VITIS_RUN=$(find_tool "$VITIS_HINT" \
    "$(for d in $LOCAL_CAND; do echo "$d/Vitis/bin/vitis-run.bat"; done | tr '\n' ' ')" \
    vitis-run)
VIVADO=$(find_tool "$VIVADO_HINT" \
    "$(for d in $LOCAL_CAND; do echo "$d/Vivado/bin/vivado.bat"; done | tr '\n' ' ')" \
    vivado)

if [ -z "$VITIS_RUN" ] || [ -z "$VIVADO" ]; then
    echo "!!! 找不到工具链 —— 需要 Vitis + Vivado **2025.2**"
    [ -z "$VITIS_RUN" ] && echo "    缺: vitis-run"
    [ -z "$VIVADO" ]    && echo "    缺: vivado"
    echo "    解决方式（任选）："
    echo "      a) source <Xilinx>/settings64.sh   （官方方式，会设 XILINX_VITIS/VIVADO）"
    echo "      b) 显式指定：VITIS_RUN=... VIVADO=... bash build/tools/rebuild_all.sh"
    echo "      c) 改本脚本里的 LOCAL_CAND 为你的安装目录"
    exit 1
fi

# ⚠ 板子地址：换网络/换板子时改它，或设 BOARD_ADDR 环境变量
BOARD="${BOARD_ADDR:-xilinx@192.168.2.99}"
BOARD_DIR="/home/xilinx"

UPLOAD=0
[ "${1:-}" = "--upload" ] && UPLOAD=1

say() { printf '\n\033[1m>>> %s\033[0m\n' "$*"; }

echo "  仓库根 : $REPO"
echo "  构建区 : $BLD"

# ---------------------------------------------------------------------
# ⚠⚠ 前置检查：不能有 Vivado 进程存活
#
#   两件事会留下孤儿 Vivado：
#     ① 中途 Ctrl-C / TaskStop —— 那杀的是 bash，vivado.bat 继续跑
#     ② 上一次构建异常退出
#   它们在跑时会**锁住** impl_1/vivado.jou、runme.log 等文件，
#   于是下面的 rm 失败、脚本半途而废，**还会在残缺目录上继续跑**，
#   产出一个不可信的比特流。2026-09-23 就是这么栽的。
# ---------------------------------------------------------------------
if command -v tasklist >/dev/null 2>&1; then
    if tasklist 2>/dev/null | grep -qi "vivado.exe"; then
        echo "!!! 检测到 vivado.exe 还在运行 —— 它会锁住工程文件，先关掉它再重建"
        tasklist 2>/dev/null | grep -i "vivado.exe"
        exit 1
    fi
fi

# ---------------------------------------------------------------------
say "0/5  清理全部缓存（HLS + Vivado）"
# ⚠ 三处都要删：只删工程目录不够，还有 HLS 产物、.Xil、残留的 .hls.failed
rm -rf "$HLS_COMP" "$REPO/.hls.failed" "$BLD/vivado/gesture_system"
rm -rf "$BLD/vivado/.Xil" "$REPO/.Xil"
echo "    已删: gesture_comp/  build/vivado/gesture_system/  .Xil/"

# ⚠⚠ 确认真的删干净了。`rm -rf` 遇到占用文件会**部分失败**并继续 ——
#   若不查，就会在**残缺的工程目录**上继续构建，产出不可信的比特流。
#   2026-09-23 的教训：上面那道进程检查没拦住时，这一道是最后的防线。
for d in "$HLS_COMP" "$BLD/vivado/gesture_system"; do
    if [ -e "$d" ]; then
        echo "!!! 清理失败，$d 仍然存在 —— 多半是有进程占着文件"
        echo "    先关掉 Vivado（tasklist | grep -i vivado）再重跑"
        exit 1
    fi
done
echo "    清理已确认"

# ---------------------------------------------------------------------
say "1/5  HLS：csim + csynth + 导出 IP"
cd "$REPO"
GESTURE_CSIM=1 GESTURE_COSIM=0 "$VITIS_RUN" --mode hls --tcl src/HLS/run_gesture.tcl \
    > "$BLD/rebuild_hls.log" 2>&1 || {
        echo "!!! HLS 失败，看 build/rebuild_hls.log"
        tail -20 "$BLD/rebuild_hls.log"; exit 1; }
grep -q "TB PASSED" "$BLD/rebuild_hls.log" || {
    echo "!!! csim 没有 PASS —— 不要往下走"
    tail -30 "$BLD/rebuild_hls.log"; exit 1; }
echo "    csim PASSED"

# 记录 IP 指纹 —— 重建后对比用
IP_FP=$(find "$HLS_COMP/solution1/impl/ip" -name "*.v" -o -name "component.xml" \
        | sort | xargs cat 2>/dev/null | md5sum | cut -c1-16)
echo "    IP 指纹: $IP_FP"

# ---------------------------------------------------------------------
say "2/5  Vivado：BD + 综合 + 实现 + 比特流"
cd "$BLD/vivado"
"$VIVADO" -mode batch -source create_project.tcl -notrace > "$BLD/rebuild_vivado.log" 2>&1 || {
    echo "!!! Vivado 失败，看 build/rebuild_vivado.log"
    tail -20 "$BLD/rebuild_vivado.log"; exit 1; }

BIT="$BLD/vivado/gesture_system/gesture_system.runs/impl_1/bd_video_wrapper.bit"
XSA="$BLD/vivado/gesture_system/gesture_system.xsa"
[ -f "$BIT" ] || { echo "!!! 没生成比特流"; exit 1; }

# ---------------------------------------------------------------------
say "3/5  校验产物（时序 / DRC / use_ila / DMA 位宽）"
grep -E "WNS|WHS" "$BLD/rebuild_vivado.log" | tail -2

# ⚠⚠ 时序硬校验（2026-09-26 补）
#
#   原来这里**只打印不判定** —— 脚本的"硬校验三条"里其实只有两条
#   （use_ila / DMA 位宽），时序那条从来没生效。2026-09-26 一次改动
#   引入了 WNS −4.436 ns 的违例，脚本**照样跑完并报"完成"**，
#   产出一个不能用的比特流。这就是补它的原因。
#
#   判据：WNS 与 WHS 都必须 ≥ 0。脚本已经会 grep 出这两行，这里再解析。
WNS=$(grep -oE "WNS=[-0-9.]+" "$BLD/rebuild_vivado.log" | tail -1 | cut -d= -f2)
WHS=$(grep -oE "WHS=[-0-9.]+" "$BLD/rebuild_vivado.log" | tail -1 | cut -d= -f2)
if [ -z "$WNS" ]; then
    echo "!!! 日志里找不到 WNS —— 无法判定时序，不能当作通过"; exit 1
fi
# ⚠ 用 awk 比较浮点（bash 只支持整数比较）
awk -v w="$WNS" 'BEGIN{ exit (w < 0) ? 1 : 0 }' || {
    echo "!!! WNS = $WNS ns（负）—— 时序违例，这个比特流不能用"; \
    echo "    查最差路径: build/vivado/gesture_system/gesture_system.runs/impl_1/bd_video_wrapper_timing_summary_routed.rpt"; \
    exit 1; }
if [ -n "$WHS" ]; then
    awk -v w="$WHS" 'BEGIN{ exit (w < 0) ? 1 : 0 }' || {
        echo "!!! WHS = $WHS ns（负）—— hold 违例"; exit 1; }
fi
echo "    时序 OK：WNS = $WNS ns${WHS:+ / WHS = $WHS ns}"

# ⚠ 硬性检查：这三条错一个，比特流就是废的
grep -q "^set use_ila 0" bd_video.tcl || {
    echo "!!! bd_video.tcl 的 use_ila 不是 0 —— 会引入 hold 违例，且报告资源虚高"; exit 1; }
grep -q '"c_sg_length_width": \[ { "value": "24"' \
    gesture_system/gesture_system.srcs/sources_1/bd/bd_video/ip/bd_video_dma_in_0/bd_video_dma_in_0.xci \
    || { echo "!!! DMA c_sg_length_width 不是 24 —— 上板会卡死"; exit 1; }
echo "    use_ila=0 ✓   c_sg_length_width=24 ✓"

# ---- HDMI / TMDS 通路（2026-09-26 新增）----
#
# ⚠ 这几条针对的都是「参数没生效但不报错、只在上板表现为怪现象」的坑
#   —— 本项目的 AXI DMA 位宽、MMCM 参数都栽过同一类。
BDDIR="$BLD/vivado/gesture_system/gesture_system.srcs/sources_1/bd/bd_video"

# ① 豁免文件必须已删除 —— 它们会把引脚漏配的错误**掩盖掉**
for f in "$BLD/vivado/constraints/video_io_hdmi_tmp.xdc" \
         "$BLD/vivado/constraints/hdmi_drc_hook.tcl"; do
    [ -e "$f" ] && { echo "!!! HDMI DRC 豁免文件又出现了: $f"; \
                     echo "    它会让引脚漏配静默通过 —— 方案 B 已完成，不该再有它"; exit 1; }
done

# ② rgb2dvi 必须实例化，且 kClkRange=2
#    ⚠ 默认值 1 → VCO=像素时钟×5=371 MHz < 600 MHz 下限 → 锁不住 → 无输出
#    ⚠ 用 glob 找而不是硬编码目录名 —— BD 生成的实例目录名带后缀
#      （实际是 bd_video_rgb2dvi_0_0，不是 bd_video_rgb2dvi_0）
R2D=$(ls "$BDDIR"/ip/*rgb2dvi*/*.xci 2>/dev/null | head -1)
[ -n "$R2D" ] || { echo "!!! 找不到 rgb2dvi 实例（HDMI 通路没建起来）"; exit 1; }
grep -q '"kClkRange": \[ { "value": "2"' "$R2D" || {
    echo "!!! rgb2dvi 的 kClkRange 不是 2 —— VCO 会低于 600 MHz 锁不住，HDMI 无输出"; exit 1; }

# ③ vid_io_out 必须解析成 24 位（与 rgb2dvi 的 vid_pData 对齐）
#    ⚠ 不一定是 24 时只报 [BD 41-2384] WARNING 然后**截断**，颜色静默出错
VO=$(ls "$BDDIR"/ip/*v_axi4s_vid_out*/*.xci 2>/dev/null | head -1)
[ -n "$VO" ] || { echo "!!! 找不到 v_axi4s_vid_out 实例"; exit 1; }
grep -q '"C_NATIVE_DATA_WIDTH": \[ { "value": "24"' "$VO" || {
    echo "!!! vid_io_out 不是 24 位 —— 与 rgb2dvi 对不上（会静默截断）"; exit 1; }
grep -q '"C_S_AXIS_TDATA_WIDTH": \[ { "value": "24"' "$VO" || {
    echo "!!! s_axis 不是 24 位 —— 与 rgb565_888_0 的输出对不上"; exit 1; }

# ④ 像素时钟 MMCM 参数（同样会被静默忽略的那类）
PIX=$(ls "$BDDIR"/ip/*clk_wiz_pix*/*.xci 2>/dev/null | head -1)
[ -n "$PIX" ] || { echo "!!! 找不到像素时钟 clk_wiz_pix —— 刷新率会不对"; exit 1; }
grep -q '"MMCM_CLKFBOUT_MULT_F": \[ { "value": "37.125"' "$PIX" && \
grep -q '"MMCM_DIVCLK_DIVIDE": \[ { "value": "5"'       "$PIX" || {
    echo "!!! 像素时钟 MMCM 参数不对 —— 74.25 MHz 出不来（期望 M=37.125 / D=5）"; exit 1; }

# ⑤ 位宽转换模块必须存在（VDMA 16bit → vid_out 24bit 的桥）
ls "$BDDIR"/ip/*rgb565_888*/*.xci >/dev/null 2>&1 || {
    echo "!!! 找不到 rgb565_888 转换模块 —— VDMA(16bit) 与 vid_out(24bit) 之间断了"; exit 1; }

# ⑤ 从实现报告确认 TMDS 引脚真的绑上了
#    ⚠ pin 约束写错端口名时是**静默 no-op**（空列表上约束安全跳过），
#      所以必须回读，不能只看"跑完了"。
IMPLLOG=$(ls -t "$BLD/vivado/gesture_system/gesture_system.runs/impl_1/"runme.log 2>/dev/null | head -1)
if [ -n "$IMPLLOG" ]; then
    n_pin=$(grep -c "hdmi_tmds" "$IMPLLOG" 2>/dev/null || echo 0)
    [ "$n_pin" -eq 0 ] && echo "    ⚠ 实现日志里没提到 hdmi_tmds —— 引脚约束可能没生效（上板前请 report_io 复核）"
fi

echo "    rgb2dvi ✓  kClkRange=2 ✓  vid_out 24bit ✓  像素时钟 M=37.125/D=5 ✓  转换模块 ✓"
echo "    HDMI DRC 豁免已清除 ✓"

# ---------------------------------------------------------------------
say "4/5  拆出 .bit / .hwh（PYNQ 要的是**改名后**的 hwh）"
TMP=$(mktemp -d)
cd "$TMP"
unzip -o -q "$XSA"
[ -f bd_video.hwh ] || { echo "!!! xsa 里没有 bd_video.hwh"; exit 1; }
cp bd_video.hwh gesture_system.hwh     # ⚠ 必须同名配对，否则 PYNQ 只认出 default

echo "    .bit md5 : $(md5sum gesture_system.bit | cut -c1-32)"
echo "    .hwh md5 : $(md5sum gesture_system.hwh | cut -c1-32)"
echo "    产物目录 : $TMP"

# ---------------------------------------------------------------------
if [ "$UPLOAD" = "1" ]; then
    say "5/5  上传到板子 $BOARD 并校验"
    # ⚠ 本包是 **PL 侧交付**，只含比特流产物，**不含主机侧 Python 驱动**。
    #   这里只传 .bit / .hwh；驱动请从 PS 侧交付获取。
    scp -o BatchMode=yes gesture_system.bit gesture_system.hwh \
        "$BOARD:$BOARD_DIR/" >/dev/null
    ssh -o BatchMode=yes "$BOARD" "rm -rf $BOARD_DIR/__pycache__ 2>/dev/null || true"

    echo "    --- 板上校验 ---"
    L1=$(md5sum gesture_system.bit | cut -c1-32)
    L2=$(ssh -o BatchMode=yes "$BOARD" "md5sum $BOARD_DIR/gesture_system.bit" | cut -c1-32)
    H1=$(md5sum gesture_system.hwh | cut -c1-32)
    H2=$(ssh -o BatchMode=yes "$BOARD" "md5sum $BOARD_DIR/gesture_system.hwh" | cut -c1-32)
    [ "$L1" = "$L2" ] && echo "    .bit  ✓" || { echo "    .bit  ✗ ($L1 != $L2)"; exit 1; }
    [ "$H1" = "$H2" ] && echo "    .hwh  ✓" || { echo "    .hwh  ✗ ($H1 != $H2)"; exit 1; }
    echo
    echo "    ⚠ 本次只传了 .bit / .hwh ——"
    echo "      主机侧 Python 驱动**不在本交付包内**（见根 README「本目录范围」）。"
    echo "      上板前需从 PS 侧交付取得驱动，与本次传的 .bit/.hwh 配套使用。"
else
    say "5/5  跳过上传（加 --upload 可自动传板并校验）"
fi

say "完成"
echo "  比特流 : $TMP/gesture_system.bit"
echo "  日志   : build/rebuild_hls.log  build/rebuild_vivado.log"
echo
echo "  ⚠ 板上跑之前，务必确认板上的 .bit/.hwh 与这里的 md5 一致 ——"
echo "    2026-09-23 就是因为板上留着旧 bit，排查绕了一大圈。"
