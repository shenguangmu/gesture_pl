#=====================================================================
# 手势预处理链 —— HLS 工程构建脚本
#
# 用法（Vitis 2025.2 没有 vitis_hls 命令，只有 vitis-run）：
#   cd <工程根>
#   vitis-run --mode hls --tcl src/HLS/run_gesture.tcl
#
# 脚本不接受命令行参数：--tcl 后面再跟参数会报
#   "option '--input_file' cannot be specified more than once"
# 需要传参请用环境变量（原工程踩过这个坑）。
#
# 可选环境变量：
#   GESTURE_CSIM=0    跳过 C 仿真，只跑综合
#   GESTURE_COSIM=1   额外跑 C/RTL 协同仿真
#   GESTURE_CLOCK=8   覆盖时钟周期(ns)，默认 10 (=100MHz)
#=====================================================================

set script_dir [file dirname [file normalize [info script]]]
# ⚠ 目录重排（2026-09-26）后本脚本从 <repo>/src/HLS/ 运行。
#   HLS 产物是**构建时生成**的，不该污染 src/ —— 约定落在
#   <repo>/build/gesture_comp/。create_project.tcl 按同一约定找 IP。
set repo_root  [file normalize [file join $script_dir .. ..]]

set part_name  "xc7z020clg400-1"

set top_name   "gesture_preproc"
set syn_file   "${script_dir}/gesture_preproc.cpp"
set ref_file   "${script_dir}/gesture_ref.cpp"
set hdr_files  "${script_dir}"

# ⚠ testbench 在目录重排（2026-09-26）后移到了 <repo>/sim/tb/。
#   与 src/RTL/run_iverilog.sh 的 TB 目录处理保持同一思路：
#   先找新位置，找不到再回退旧位置（与源码同目录）。
#   ⚠ 两处都找不到时必须**显式报错** —— 否则 Vitis 只会打印一行
#     "找不到源文件"然后退出，看不出真正原因是目录结构变了。
set tb_file ""
foreach _cand [list "${repo_root}/sim/tb/tb_gesture.cpp" \
                    "${script_dir}/tb_gesture.cpp"] {
    if {[file exists $_cand]} { set tb_file $_cand; break }
}
if {$tb_file eq ""} {
    puts "ERROR: 找不到 tb_gesture.cpp（试过 sim/tb/ 与 src/HLS/）"
    exit 1
}

set do_csim    1
set do_cosim   0
set clock_ns   10

if {[info exists ::env(GESTURE_CSIM)]}  { set do_csim  $::env(GESTURE_CSIM) }
if {[info exists ::env(GESTURE_COSIM)]} { set do_cosim $::env(GESTURE_COSIM) }
if {[info exists ::env(GESTURE_CLOCK)]} { set clock_ns $::env(GESTURE_CLOCK) }

# 综合产物目录（.gitignore 已忽略 *_comp/）
set comp_dir   "${repo_root}/gesture_comp"

# ⚠⚠ comp_dir 必须在**仓库根**（只深一层），**不要**挪到 build/ 下。
#
#   2026-09-26 实测：Vitis HLS 2025.2 在 comp_dir 比仓库根深**两级**时，
#   会把设计文件的注册路径算错 —— hls.app 里变成
#       name="../src/HLS/gesture_preproc.cpp"     ← 带 `..`
#   该路径解析后指向 `build/src/HLS/gesture_preproc.cpp`（不存在），
#   于是设计文件**不进 csim 的编译清单**（csim.mk 的 HLS_SOURCES
#   只剩 ref + tb 两项），链接期报
#       undefined symbol: gesture_preproc(hls::stream<...>&, ...)
#
#   ⚠ 注意分工：TB 与参考实现注册的是**绝对路径**，不受影响；
#     只有 `add_files`（设计文件）那条被转成了相对路径 —— 所以现象
#     是"只有设计文件丢了"，很容易误判成 TB 或文件集的问题。
#
#   **对照实验**（同一脚本，只改 comp_dir）：放回仓库根 → hls.app 里
#     变成 `src/HLS/gesture_preproc.cpp`（无 `..`），csim.mk 恢复三项，
#     全流程通过。所以这不是配置问题，是 Vitis 的行为，只能顺着它。
#
#   ⚠ 改这里要同步改：create_project.tcl 的 IP 搜索路径、.gitignore、
#     build/tools/rebuild_all.sh 的清理与查找路径。
set sol_name   "solution1"

puts "====================================================================="
puts " 手势预处理链 —— Vitis HLS 构建"
puts "   顶层    : $top_name"
puts "   器件    : $part_name"
puts "   时钟    : $clock_ns ns ([expr 1000.0 / $clock_ns] MHz)"
puts "   工程目录: $comp_dir"
puts "   csim=$do_csim  cosim=$do_cosim"
puts "====================================================================="

# ---------------------------------------------------------------------
# 检查源文件
# ---------------------------------------------------------------------
foreach f [list $syn_file $tb_file $ref_file] {
    if {![file exists $f]} {
        puts "ERROR: 找不到源文件 $f"
        exit 1
    }
}

# ---------------------------------------------------------------------
# 建工程
# ---------------------------------------------------------------------
open_project -reset $comp_dir

set_top $top_name

# ---------------------------------------------------------------------
# 加入源文件（顺序与完整仓库一致，不要改）
# ---------------------------------------------------------------------
add_files -cflags "-I${hdr_files}" $syn_file

# testbench 与参考实现一起加。参考实现里的函数不带 HLS pragma，
# 不会被当作顶层；gesture_ref.cpp 整体被 #ifndef __SYNTHESIS__ 包住，
# 综合阶段不会进入。
add_files -tb -cflags "-I${hdr_files}" $tb_file
add_files -tb -cflags "-I${hdr_files}" $ref_file

open_solution -reset $sol_name

set_part $part_name
create_clock -period $clock_ns -name default

# ---------------------------------------------------------------------
# C 仿真
# ---------------------------------------------------------------------
if {$do_csim} {
    puts "\n>>> C 仿真 (csim)"
    if {[catch {csim_design -clean -O} err]} {
        puts "\n==========================================================="
        puts " C 仿真失败："
        puts " $err"
        puts "==========================================================="
        exit 1
    }
    puts ">>> C 仿真通过"
}

# ---------------------------------------------------------------------
# 综合
# ---------------------------------------------------------------------
puts "\n>>> C 综合 (csynth)"
if {[catch {csynth_design} err]} {
    puts "\n==========================================================="
    puts " 综合失败："
    puts " $err"
    puts "==========================================================="
    exit 1
}

# ---------------------------------------------------------------------
# C/RTL 协同仿真（可选，慢但能验证时序行为）
# ---------------------------------------------------------------------
if {$do_cosim} {
    puts "\n>>> C/RTL 协同仿真 (cosim)"
    if {[catch {cosim_design -trace_level none -rtl verilog} err]} {
        puts "\n==========================================================="
        puts " 协同仿真失败："
        puts " $err"
        puts "==========================================================="
        exit 1
    }
    puts ">>> 协同仿真通过"
}

# ---------------------------------------------------------------------
# 导出 IP
# ---------------------------------------------------------------------
puts "\n>>> 导出 IP (ip_catalog)"
if {[catch {export_design -format ip_catalog -description "Gesture Preprocessing Pipeline" -vendor "user" -library "hls" -version "1.0"} err]} {
    puts "\n==========================================================="
    puts " 导出失败："
    puts " $err"
    puts "==========================================================="
    exit 1
}

set ip_dir "${comp_dir}/${sol_name}/impl/ip"
puts "\n====================================================================="
puts " 完成"
puts "   IP 目录: $ip_dir"
puts ""
puts " 导入 Vivado 的正确方式（不是 read_ip）："
puts "   set_property ip_repo_paths $ip_dir \[current_project\]"
puts "   update_ip_catalog -rebuild"
puts ""
puts " 连 BD 前先确认 axis 端口名 —— 它是 C 函数参数名，不是 s_axis_video。"
puts " 查法：grep busInterface ${ip_dir}/component.xml"
puts "====================================================================="

exit 0
