// =====================================================================
//  tb_axis_rgb565_888.v —— AXIS RGB565 → RGB888 位宽转换自检
//
//  运行：
//      iverilog -g2012 -o tb.vvp tb_axis_rgb565_888.v ../../src/RTL/axis_rgb565_888.v
//      vvp tb.vvp
//
//  ⚠ 必须看到 *** TB PASSED ***
//
//  ─────────────────────────────────────────────────────────────────
//  这个 TB 验什么、不验什么
//  ─────────────────────────────────────────────────────────────────
//  **不验**"上板后颜色对不对" —— 那取决于 VDMA 送出来的字节序，
//  只能上板用标准彩条看。本 TB 验的是**本模块自己的契约**。
//
//  **验四件事，它们错了都会静默出错**：
//
//    1. **输出是 RBG 序，不是 RGB**（本 TB 最有价值的一条）
//       rgb2dvi 的 vid_pData 是 [23:16]=R / [15:8]=B / [7:0]=G。
//       写成常识的 R-G-B 会导致**绿蓝互换** —— 画面看着像对的、
//       只是颜色不对，是最难往"位序"上想的一类现象。
//       本 TB 用纯色（纯红/纯绿/纯蓝）断言，纯色最容易看出错位。
//
//    2. **位扩展满量程映射到满量程**
//       r5=31 必须 → 255（不是 248）。否则白色发灰、灰色偏暗。
//
//    3. **握手零延迟**
//       tvalid/tready/tlast 必须与输入**同一拍**，不能有寄存器。
//       有延迟会让 SOF/EOL 错位 → 画面撕裂。
//       ⚠ 这条用"同一时刻采样"来验：在同一个 #1 步进里改变输入，
//         立即检查输出 —— 组合逻辑应当当拍就跟上。
//
//    4. **背压下不丢拍**
//       tready=0 时下游不该看到新数据；且不发散（无锁存）。

//  写法说明（沿用本项目 TB 的约定）：
//    * 所有 reg/wire/integer 声明必须在**所有过程块之前**。
//    * **不在 initial 块内部声明 reg**（iverilog 报 invalid module item）。
//    * 判定只看英文标记 `*** TB PASSED ***`，中文在部分终端会乱码。
// =====================================================================

`timescale 1ns / 1ps

module tb_axis_rgb565_888;

    reg  [15:0] s_tdata;
    reg         s_tvalid;
    wire        s_tready;
    reg         s_tlast;

    wire [23:0] m_tdata;
    wire        m_tvalid;
    reg         m_tready;
    wire        m_tlast;

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // ---- DUT ----
    axis_rgb565_888 dut (
        .aclk          (1'b0),        // 逻辑上未使用，仅给 BD 关联时钟用
        .s_axis_tdata  (s_tdata),
        .s_axis_tvalid (s_tvalid),
        .s_axis_tready (s_tready),
        .s_axis_tlast  (s_tlast),
        .m_axis_tdata  (m_tdata),
        .m_axis_tvalid (m_tvalid),
        .m_axis_tready (m_tready),
        .m_axis_tlast  (m_tlast)
    );

    task check;
        input             ok;
        input [8*64-1:0]  name;
        begin
            if (ok) pass_cnt = pass_cnt + 1;
            else begin
                fail_cnt = fail_cnt + 1;
                $display("  FAIL : %0s", name);
            end
        end
    endtask

    // 把 R/G/B 分量打包成输入用的 RGB565 字
    //   {R[4:0], G[5:0], B[4:0]}
    function [15:0] pack565;
        input [4:0] r;
        input [5:0] g;
        input [4:0] b;
        begin
            pack565 = {r, g, b};
        end
    endfunction

    // 期望的 RBG 输出：[23:16]=R, [15:8]=B, [7:0]=G
    function [23:0] expect_rbg;
        input [7:0] r;
        input [7:0] g;
        input [7:0] b;
        begin
            expect_rbg = {r, b, g};
        end
    endfunction

    initial begin
        s_tdata  = 16'h0000;
        s_tvalid = 1'b0;
        s_tlast  = 1'b0;
        m_tready = 1'b1;

        #10;

        // -------------------------------------------------------------
        //  用例 1：握手信号的组合直通（零延迟）
        // -------------------------------------------------------------
        $display("\n[1] handshake passthrough (zero latency)");
        s_tvalid = 1'b1; s_tlast = 1'b0; m_tready = 1'b1;
        #1;
        check(m_tvalid === 1'b1, "tvalid must follow input combinationally");
        check(m_tlast  === 1'b0, "tlast must follow input combinationally");
        check(s_tready === 1'b1, "tready must reflect downstream combinationally");

        m_tready = 1'b0;
        #1;
        check(s_tready === 1'b0, "tready=0 downstream must drive tready=0 upstream");

        m_tready = 1'b1;
        s_tlast  = 1'b1;
        #1;
        check(m_tlast === 1'b1, "tlast must follow input combinationally (high)");
        s_tlast = 1'b0;

        // -------------------------------------------------------------
        //  用例 2：⚠ 输出是 RBG 序（本 TB 最关键的一条）
        //
        //  用三种纯色，它的特点是：即使位序搞错，非零分量数也不变，
        //  但**落在哪个字节**会变 —— 所以能精确定位错在哪。
        // -------------------------------------------------------------
        $display("\n[2] output bit order must be RBG (rgb2dvi requires it)");

        // 纯红：R=31, G=0, B=0
        s_tdata = pack565(5'd31, 6'd0, 5'd0);
        #1;
        $display("      pure RED   in=%04h out=%06h", s_tdata, m_tdata);
        check(m_tdata === expect_rbg(8'hFF, 8'h00, 8'h00),
              "pure red  must be [23:16]=FF [15:8]=00 [7:0]=00");

        // 纯绿：R=0, G=63, B=0  →  绿色必须落在 [7:0]，不是 [15:8]
        s_tdata = pack565(5'd0, 6'd63, 5'd0);
        #1;
        $display("      pure GREEN in=%04h out=%06h", s_tdata, m_tdata);
        check(m_tdata === expect_rbg(8'h00, 8'hFF, 8'h00),
              "pure green must be [23:16]=00 [15:8]=00 [7:0]=FF  (NOT [15:8])");

        // 纯蓝：R=0, G=0, B=31  →  蓝色必须落在 [15:8]，不是 [7:0]
        s_tdata = pack565(5'd0, 6'd0, 5'd31);
        #1;
        $display("      pure BLUE  in=%04h out=%06h", s_tdata, m_tdata);
        check(m_tdata === expect_rbg(8'h00, 8'h00, 8'hFF),
              "pure blue  must be [23:16]=00 [15:8]=FF [7:0]=00  (NOT [7:0])");

        // -------------------------------------------------------------
        //  用例 3：位扩展 —— 满量程必须映射到满量程
        // -------------------------------------------------------------
        $display("\n[3] bit expansion: full scale -> full scale");
        s_tdata = pack565(5'd31, 6'd63, 5'd31);   // 全白
        #1;
        $display("      pure WHITE in=%04h out=%06h", s_tdata, m_tdata);
        check(m_tdata === 24'hFFFFFF, "all-ones must map to all-ones (255/255/255)");

        s_tdata = pack565(5'd0, 6'd0, 5'd0);      // 全黑
        #1;
        check(m_tdata === 24'h000000, "all-zeros must map to all-zeros");

        // 已知中间值抽查：取 r5=b5=16、g6=32
        //   R5=16=10000 → {10000, 100}   = 10000100 = 0x84
        //   G6=32=100000 → {100000, 10}  = 10000010 = 0x82
        //   ⚠ 这里的期望值**必须按规则手算并写对** ——
        //     本 TB 第一版就把 G 算成了 0x88（那是另一种规则的产物），
        //     被 TB 自己抓出来。核验方法：线性缩放
        //         R: 16 × 255/31 = 131.6 → 132 = 0x84 ✓
        //         G: 32 × 255/63 = 129.5 → 130 = 0x82 ✓
        //     两种算法一致，说明位复制规则确实是"接近线性"的。
        s_tdata = pack565(5'd16, 6'd32, 5'd16);
        #1;
        $display("      mid        in=%04h out=%06h (R/B=%02h G=%02h)",
                 s_tdata, m_tdata, m_tdata[23:16], m_tdata[7:0]);
        check(m_tdata[23:16] === 8'h84, "R5=16 must expand to 8'h84 (132, ~= 16*255/31)");
        check(m_tdata[7:0]   === 8'h82, "G6=32 must expand to 8'h82 (130, ~= 32*255/63)");
        check(m_tdata[15:8]  === 8'h84, "B5=16 must expand to 8'h84 (132, ~= 16*255/31)");

        // -------------------------------------------------------------
        //  用例 4：背压时不丢拍、不发散
        // -------------------------------------------------------------
        $display("\n[4] backpressure: data must be held, not lost");
        s_tdata  = pack565(5'd31, 6'd0, 5'd0);   // 纯红
        s_tvalid = 1'b1;
        m_tready = 1'b0;
        #1;
        check(m_tdata === expect_rbg(8'hFF, 8'h00, 8'h00),
              "data must still be presented while tready=0");
        // 保持背压，多个周期后数据不应改变
        #20;
        check(m_tdata === expect_rbg(8'hFF, 8'h00, 8'h00),
              "data must be stable under sustained backpressure");
        check(m_tvalid === 1'b1, "tvalid must stay high while waiting");
        // 释放背压
        m_tready = 1'b1;
        #1;
        check(s_tready === 1'b1, "tready must release combinationally");

        // -------------------------------------------------------------
        //  用例 5：tvalid=0 时下游不该认为数据有效
        // -------------------------------------------------------------
        $display("\n[5] tvalid=0 passthrough");
        s_tvalid = 1'b0;
        #1;
        check(m_tvalid === 1'b0, "tvalid=0 must propagate as tvalid=0");

        // ---- 汇总 ----
        $display("\n=== TB DONE: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("*** TB PASSED ***");
        else
            $display("*** TB FAILED ***");

        $finish;
    end

    initial begin
        #100000;
        $display("\n*** TB TIMEOUT ***");
        $finish;
    end

endmodule
