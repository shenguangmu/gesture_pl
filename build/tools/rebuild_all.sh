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
#      <repo>/build/            **所有构建产物**（不入版本控制）
#        ├── gesture_comp/      HLS 产物（run_gesture.tcl 输出到这里）
#        ├── vivado/            工程与脚本
#        ├── rebuild_*.log      构建日志
#        └── tools/             本脚本
# =====================================================================
set -euo pipefail

# ⚠ 本脚本在 <repo>/build/tools/ 下 → 仓库根要上溯**两级**
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BLD="$REPO/build"
VITIS_RUN="/d/BaiduNetdiskDownload/2025.2/Vitis/bin/vitis-run.bat"
VIVADO="/d/BaiduNetdiskDownload/2025.2/Vivado/bin/vivado.bat"
BOARD="xilinx@192.168.2.99"
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
rm -rf "$BLD/gesture_comp" "$REPO/.hls.failed" "$BLD/vivado/gesture_system"
rm -rf "$BLD/vivado/.Xil" "$REPO/.Xil"
echo "    已删: build/gesture_comp/  build/vivado/gesture_system/  .Xil/"

# ⚠⚠ 确认真的删干净了。`rm -rf` 遇到占用文件会**部分失败**并继续 ——
#   若不查，就会在**残缺的工程目录**上继续构建，产出不可信的比特流。
#   2026-09-23 的教训：上面那道进程检查没拦住时，这一道是最后的防线。
for d in "$BLD/gesture_comp" "$BLD/vivado/gesture_system"; do
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
IP_FP=$(find "$BLD/gesture_comp/solution1/impl/ip" -name "*.v" -o -name "component.xml" \
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

# ⚠ 硬性检查：这三条错一个，比特流就是废的
grep -q "^set use_ila 0" bd_video.tcl || {
    echo "!!! bd_video.tcl 的 use_ila 不是 0 —— 会引入 hold 违例，且报告资源虚高"; exit 1; }
grep -q '"c_sg_length_width": \[ { "value": "24"' \
    gesture_system/gesture_system.srcs/sources_1/bd/bd_video/ip/bd_video_dma_in_0/bd_video_dma_in_0.xci \
    || { echo "!!! DMA c_sg_length_width 不是 24 —— 上板会卡死"; exit 1; }
echo "    use_ila=0 ✓   c_sg_length_width=24 ✓"

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
