#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
collect_directions.py —— 采集 12 个方向的样本，并**验证可分性**

=====================================================================
 这个脚本解决什么问题
=====================================================================
任务已定为「12 个方向分类」，但那只是**纸面上的定义**。
**没人验证过：这条预处理链对方向到底区分得开吗？**

如果 1 点和 2 点产生的特征图几乎一样，CNN 再强也分不开 ——
**队友会白训**。这个脚本在花时间造数据、训模型**之前**回答这个问题。

输出两样东西：
  1. 12 组样本（`.bin` 特征图 + `.png` 摄像头原图）
  2. **两两相似度矩阵** —— 直接告诉你哪几类容易混

=====================================================================
 用法（Jupyter 里，或命令行）
=====================================================================
    %run collect_directions.py

流程：摆好手 → 回车 → 自动抓帧 + 跑 PL + 存图 → 下一个方向
12 个方向采完，自动打印相似度矩阵与 ASCII 预览。

    # 只重采某几个方向
    %run collect_directions.py --only 3,7,11

    # 换输出目录
    %run collect_directions.py --outdir /home/xilinx/dir_samples

⚠ **Jupyter 里不用 sudo**（内核本来就是 root）。
⚠ **命令行要 sudo**：`sudo -E /usr/local/share/pynq-venv/bin/python3 collect_directions.py`

=====================================================================
 ⚠ 取景要求（**这一步做错，后面全白费**）
=====================================================================
  · **手要占满画面的大半** —— 太小的话 ROI 里全是背景，
    特征图就是噪声（看到非零数很低的样本 = 手太远）
  · **手腕在画面中心附近，手指朝外** —— 这样"方向"才有意义
  · **背景尽量干净**（单色墙面/桌面最好）—— 杂物会出大量边缘
  · **光照均匀** —— 二值化本身抗光照，但**强烈侧光**会在手上出阴影边缘
  · **每个方向摆的姿势要一致**，只改指向 —— 否则 CNN 学到的是
    "手的形状"而不是"方向"

=====================================================================
 ⚠ 这**不是**训练集，是**探针**
=====================================================================
12 张图训不出模型。目的是**回答"分不分得开"**，以及
给队友一个「姿势/取景」的参照。真正的训练集要用同样的取景，
每个方向采几十~几百张。
"""

import argparse
import io
import os
import sys

# ⚠ UTF-8 包装要加守卫 —— Jupyter 的 stdout 是 OutStream，没有 .buffer
if hasattr(getattr(sys.stdout, 'buffer', None), 'write') \
   and getattr(sys.stdout, 'encoding', '').lower() not in ('utf-8', 'utf8'):
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8',
                                  errors='replace')

import numpy as np

# 目录名与方向编号的对应（与 cnn-handoff-12directions.md 一致）
CLOCK_NAMES = ['12点', '1点', '2点', '3点', '4点', '5点',
               '6点', '7点', '8点', '9点', '10点', '11点']


def _load_usb_module():
    """
    从 usb_camera_run.py 复用摄像头与转换逻辑。

    ⚠ 为什么不重写一份：那两个函数（fit_to_frame / rgb888_to_rgb565）
      必须与 PL 契约**逐位一致**。写第二份实现 = 引入分叉源，
      将来改一处忘了另一处，训练分布就和推理分布对不上了。
      本项目在 crop_scale 上吃过"三份实现一起错"的亏。
    """
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    import usb_camera_run as U
    return U


def ascii_preview(feat, size=16):
    """把 96×96 特征图降采样成 size×size 的字符画，便于在终端里一眼比较"""
    step = feat.shape[0] // size
    small = feat.reshape(size, step, size, step).mean(axis=(1, 3))
    return [''.join('#' if v > 127 else ('+' if v > 30 else '.') for v in row)
            for row in small]


def similarity(a, b):
    """
    两个二值特征图的相似度。

    用 **IoU**（交并比）而不是逐位相同率 —— 因为二值图大部分是 0，
    "逐位相同率"会被背景稀释成假的 90%+，看不出差异。
    IoU 只比较前景（非零像素）的重合度，对稀疏二值图更敏感。

    ⚠ 若两张图都全黑（没采到手），IoU 无定义 → 返回 None，
      调用方要**显式报出来**，不能当成"很像"。
    """
    A, B = a > 127, b > 127
    inter = int((A & B).sum())
    union = int((A | B).sum())
    if union == 0:
        return None          # 两张都是空的 —— 无意义
    return inter / union


def main():
    ap = argparse.ArgumentParser(
        description='采集 12 个方向样本并验证可分性')
    ap.add_argument('--outdir', default='/home/xilinx/dir_samples',
                    help='输出目录（默认 /home/xilinx/dir_samples）')
    ap.add_argument('--only', default=None,
                    help='只采某几个方向，逗号分隔（如 3,7,11）')
    ap.add_argument('--camera', type=int, default=0, help='摄像头序号')
    ap.add_argument('--warmup', type=int, default=5,
                    help='每次抓帧前丢弃几帧（摄头 AGC 收敛）')
    args = ap.parse_args()

    U = _load_usb_module()

    which = list(range(12))
    if args.only:
        which = [int(x) for x in args.only.split(',')]

    os.makedirs(args.outdir, exist_ok=True)

    print('=' * 70)
    print('  12 方向样本采集 + 可分性验证')
    print('=' * 70)
    print('  输出目录: %s' % args.outdir)
    print('  本次采集: %s' % ', '.join(CLOCK_NAMES[i] for i in which))
    print()
    print('  ⚠ 取景要求（做错后面全白费）：')
    print('     · 手要占满画面大半（太小 → 特征图全是噪声）')
    print('     · 手腕在中心附近，手指朝外')
    print('     · 背景尽量干净、光照均匀')
    print('     · 每个方向**只改指向**，姿势保持一致')
    print()

    # ---- 摄像头 ----
    #
    # ⚠ `open_camera()` 返回的是 **4 元组** `(cap, aw, ah, got_fourcc)`，
    #   不是单个 cap 对象 —— 必须解包。
    #   （写这个脚本时没核对返回值直接当对象用，板上跑出
    #     `AttributeError: 'tuple' object has no attribute 'read'`。
    #     教训：调用别人的函数前先看它 return 什么。）
    print('[1] 打开摄像头')
    cap, aw, ah, got = U.open_camera(args.camera)
    if cap is None:
        print('!!! 摄像头打不开 —— 先跑 usb_camera_run.py --probe 排查')
        return 1

    # ---- overlay（只加载一次，12 次复用）----
    print('\n[2] 加载 overlay 并分配 DMA')
    from gesture_overlay import GesturePipeline
    g = GesturePipeline()
    g.setup_dma()
    # ⚠ 用全幅 ROI：方向采集时手的位置由人控制，固定 ROI 容易把手切出框。
    #   全幅 + 手占画面大半 = 最稳。若手偏小，改这里的 roi 或让人靠近。
    g.config(roi_x=0, roi_y=0, roi_w=640, roi_h=480)
    print('    已配置 ROI=(0,0) 640x480（全幅）')

    print('\n[3] 开始采集')
    print('    摆好一个方向 → 回车 → 自动抓帧')
    print('    想跳过某个方向就输 s 再回车；想中止就输 q')
    print()

    feats = {}
    try:
        for i in which:
            label = CLOCK_NAMES[i]
            try:
                cmd = input('  [%2d/12] %-4s — 摆好后按回车（s=跳过 q=退出）> '
                            % (i + 1, label)).strip().lower()
            except EOFError:
                cmd = ''
            if cmd == 'q':
                print('    用户中止')
                break
            if cmd == 's':
                print('    跳过')
                continue

            rgb = U.grab_frame(cap, warmup=args.warmup)
            if rgb is None:
                print('    !!! 抓帧失败，跳过')
                continue

            # 摄像头原图存 PNG（肉眼确认取景对不对）
            try:
                import cv2
                cv2.imwrite(os.path.join(args.outdir, 'cam_%02d.png' % i),
                            cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR))
            except Exception as e:
                print('    (原图没存成: %s)' % e)

            # 走 PL 链
            data = U.to_dma_bytes(U.rgb888_to_rgb565(U.fit_to_frame(rgb, U.W, U.H)))
            g.in_buf[:] = np.frombuffer(data, dtype=np.uint8)
            g.run_once()
            feat = np.array(g.out_buf, dtype=np.uint8).reshape(96, 96).copy()

            nz = int((feat != 0).sum())
            feat.tofile(os.path.join(args.outdir, 'feat_%02d.bin' % i))
            feats[i] = feat

            flag = ''
            if nz < 300:
                flag = '   ⚠ 非零很少 —— 手可能太远/不在框内/背景太干净'
            elif nz > 6000:
                flag = '   ⚠ 非零很多 —— 背景杂物太多，会淹没手形'
            print('    存好 feat_%02d.bin + cam_%02d.png   非零 %d/9216%s'
                  % (i, i, nz, flag))
    finally:
        # ⚠ cap 一定是有效的（上面解包后有校验），但 release 仍放进 finally,
        #   保证中途 Ctrl-C / 异常也能释放摄像头
        try:
            cap.release()
        except Exception:
            pass

    if len(feats) < 2:
        print('\n!!! 采到的样本不足 2 个，无法比较')
        return 1

    # ---- 相似度矩阵 ----
    print()
    print('=' * 70)
    print('  可分性分析')
    print('=' * 70)
    keys = sorted(feats)
    print('\n  【A】两两 IoU（前景交并比）—— **越低越好分**')
    print('        > 0.80 说明两张图几乎重合，**这两类很可能分不开**')
    print()

    hdr = '        ' + ''.join('%5s' % CLOCK_NAMES[k] for k in keys)
    print(hdr)
    pairs = []
    for a in keys:
        row = '  %-5s ' % CLOCK_NAMES[a]
        for b in keys:
            if b <= a:
                row += '     ' if b < a else '   — '
                continue
            s = similarity(feats[a], feats[b])
            row += '  n/a' if s is None else '%5.2f' % s
            if s is not None:
                pairs.append((s, a, b))
        print(row)

    pairs.sort(reverse=True)
    print('\n  最容易混的 5 对：')
    shown = 0
    for s, a, b in pairs:
        if shown >= 5:
            break
        warn = '  ⚠⚠ 高度重合' if s > 0.80 else ('  ⚠ 偏高' if s > 0.65 else '')
        print('     %-4s vs %-4s  IoU=%.2f%s'
              % (CLOCK_NAMES[a], CLOCK_NAMES[b], s, warn))
        shown += 1
    if not pairs:
        print('     （没有有效比较 —— 可能所有样本都是空的）')

    # ---- ASCII 预览 ----
    print('\n  【B】特征图预览（每张降采样成 16x16，`#`=前景 `+`=弱 `.`=空）')
    for i in keys:
        print('\n     --- %s ---' % CLOCK_NAMES[i])
        for line in ascii_preview(feats[i]):
            print('     ' + line)

    # ---- 结论 ----
    print()
    print('=' * 70)
    worst = pairs[0][0] if pairs else 0
    if worst > 0.80:
        print('  ⚠ 结论：有方向对高度重合（IoU %.2f）—— 12 类**可能分不开**' % worst)
        print('     先别急着造训练集。可能的原因与对策：')
        print('       · 手太小 / 背景太杂 → 调整取景后重采')
        print('       · 只改指向但姿势也变了 → 保持姿势只改方向')
        print('       · 确实几何上不可分 → 考虑减少类别数（如 8 或 4 类）')
        print('         或改用灰度模式（thresh_mode=0，保留更多信息）')
    elif worst > 0.65:
        print('  ⚠ 结论：最像的一对 IoU=%.2f，偏高但不致命' % worst)
        print('     建议多采几个样本看稳定性，再决定是否减类')
    else:
        print('  ✅ 结论：最像的一对 IoU=%.2f —— 方向区分度良好' % worst)
        print('     可以按计划做 12 类。下一步：按同样的取景批量采训练集。')
    print('=' * 70)

    print('\n  样本已存到: %s' % args.outdir)
    print('  ⚠ 这 12 张是**探针**，不是训练集 —— 训练要每类几十~几百张。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
