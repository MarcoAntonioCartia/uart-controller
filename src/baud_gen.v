//=============================================================================
// Module:  baud_gen
// Project: UART Controller — Arty A7-100T
//
// Purpose: Generate baud-rate tick pulses from the 100 MHz system clock.
//          Two independent outputs:
//            tick_baud   — 1x baud rate tick (for the TX state machine)
//            tick_sample — 16x baud rate tick (for RX oversampling)
//
// Math:
//   1x divisor  = 100,000,000 / 115,200         = 868  (truncated)
//   16x divisor = 100,000,000 / (115,200 * 16)  = 54   (truncated)
//
//   Actual 1x baud  = 100,000,000 / 868 = 115,207.37 Hz  (error: +0.006%)
//   Actual 16x rate = 100,000,000 / 54  = 1,851,851.9 Hz  (error: +0.47%)
//
//   Both errors are well within UART tolerance (~2-3% max).
//   The 1x counter is independent from the 16x counter so that the TX path
//   gets the best possible accuracy, rather than inheriting the 16x error.
//
// Interface:
//   tick_baud and tick_sample are single-cycle pulses (high for exactly one
//   clk cycle). TX/RX modules use them as clock-enable signals:
//
//     always @(posedge clk)
//       if (tick_baud) begin /* advance TX state machine */ end
//
//   This keeps everything in one clock domain — no CDC issues.
//
// Reset: Synchronous, active-high. Xilinx 7-series flip-flops have dedicated
//        synchronous set/reset inputs, making this the recommended style
//        (see Xilinx WP272).
//=============================================================================

module baud_gen #(
    parameter CLK_FREQ  = 100_000_000,  // System clock frequency in Hz
    parameter BAUD_RATE = 115_200       // Target baud rate
) (
    input  wire clk,          // System clock
    input  wire rst,          // Synchronous reset, active-high
    output reg  tick_baud,    // 1x baud tick — one clk cycle wide
    output reg  tick_sample   // 16x baud tick — one clk cycle wide
);

    // -------------------------------------------------------------------------
    // Derived constants — computed at elaboration time, never synthesized.
    // Change CLK_FREQ or BAUD_RATE and these update automatically.
    // -------------------------------------------------------------------------
    localparam BAUD_DIVISOR   = CLK_FREQ / BAUD_RATE;         // 868 @ defaults
    localparam SAMPLE_DIVISOR = CLK_FREQ / (BAUD_RATE * 16);  // 54  @ defaults

    // Counter bit-widths — just wide enough to hold (DIVISOR - 1).
    // $clog2(868) = 10 bits (can represent 0–1023, we only need 0–867).
    // $clog2(54)  = 6 bits  (can represent 0–63, we only need 0–53).
    localparam BAUD_CNT_W   = $clog2(BAUD_DIVISOR);   // 10
    localparam SAMPLE_CNT_W = $clog2(SAMPLE_DIVISOR);  // 6

    // -------------------------------------------------------------------------
    // 1x Baud-rate counter (drives TX)
    //
    // Counts from 0 up to (BAUD_DIVISOR - 1), then wraps back to 0.
    // tick_baud goes high for exactly the one cycle when the counter wraps.
    // Period between consecutive ticks = BAUD_DIVISOR clock cycles = 868.
    // -------------------------------------------------------------------------
    reg [BAUD_CNT_W-1:0] baud_cnt;

    always @(posedge clk) begin
        if (rst) begin
            baud_cnt  <= 0;
            tick_baud <= 1'b0;
        end else if (baud_cnt == BAUD_DIVISOR - 1) begin
            baud_cnt  <= 0;
            tick_baud <= 1'b1;     // Terminal count reached — fire tick
        end else begin
            baud_cnt  <= baud_cnt + 1'b1;
            tick_baud <= 1'b0;     // Not yet — keep tick low
        end
    end

    // -------------------------------------------------------------------------
    // 16x Oversampling counter (drives RX)
    //
    // Same pattern, but fires 16 times faster.
    // The RX state machine uses this to:
    //   1. Detect the start-bit falling edge
    //   2. Count 8 ticks to reach the center of the start bit
    //   3. Count 16 ticks to reach the center of each subsequent bit
    // -------------------------------------------------------------------------
    reg [SAMPLE_CNT_W-1:0] sample_cnt;

    always @(posedge clk) begin
        if (rst) begin
            sample_cnt  <= 0;
            tick_sample <= 1'b0;
        end else if (sample_cnt == SAMPLE_DIVISOR - 1) begin
            sample_cnt  <= 0;
            tick_sample <= 1'b1;   // Terminal count reached — fire tick
        end else begin
            sample_cnt  <= sample_cnt + 1'b1;
            tick_sample <= 1'b0;   // Not yet — keep tick low
        end
    end

endmodule
