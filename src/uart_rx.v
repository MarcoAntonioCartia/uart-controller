//=============================================================================
// Module:  uart_rx
// Project: UART Controller — Arty A7-100T
//
// Purpose: Receive an 8N1 UART frame from an asynchronous serial input.
//          Uses tick_sample (16x baud rate) from baud_gen for oversampling.
//          The entire design stays in the 100 MHz system clock domain.
//
// RX is harder than TX.  The transmitter controls when bits go out, but the
// receiver must *discover* when bits arrive on an asynchronous line.  This
// module handles three things TX never needs:
//
//   1. A 2-stage synchronizer to prevent metastability on the rx input.
//   2. Falling-edge detection to find the start bit.
//   3. 16x oversampling to locate the center of each bit period.
//
// Frame format (8N1), as seen by the receiver:
//
//       idle   start   D0  D1  D2  D3  D4  D5  D6  D7   stop   idle
// rx: ~~^^^~~~______~XXXX~XXXX~XXXX~XXXX~XXXX~XXXX~XXXX~XXXX~~~^^^~~~
//               |<------------- LSB first ------------>|
//               ^               ^                       ^
//        falling edge     sample at center       verify stop = high
//      (detect here)      of each bit period     (framing error if low)
//
// Oversampling strategy:
//   Each bit period = 16 tick_sample pulses.
//   After detecting the start bit falling edge:
//     1. Count 8 ticks  → center of start bit (half a bit period)
//     2. Verify rx is still low (reject glitches)
//     3. Count 16 ticks → center of each subsequent data/stop bit
//     4. Sample the line at each center point
//
// Interface:
//   rx_data — holds the received byte.  Valid when rx_done pulses.
//             Retains its value until the next byte overwrites it.
//
//   rx_done — single-cycle pulse when a complete byte has been received.
//             Same convention as tx_done in uart_tx.
//
//   rx_err  — single-cycle pulse when the stop bit reads low (framing error).
//             rx_data is still output — the caller decides whether to use it.
//
// Reset: Synchronous, active-high.  The synchronizer resets to 1 (idle-high)
//        to prevent a false start-bit detection on reset release.
//=============================================================================

module uart_rx (
    input  wire       clk,         // System clock (100 MHz)
    input  wire       rst,         // Synchronous reset, active-high
    input  wire       tick_sample, // 16x baud tick from baud_gen
    input  wire       rx,          // Serial input — asynchronous!
    output reg  [7:0] rx_data,     // Received byte (valid when rx_done pulses)
    output reg        rx_done,     // Single-cycle pulse: byte received
    output reg        rx_err       // Single-cycle pulse: framing error
);

    // -------------------------------------------------------------------------
    // State definitions — same 4-state pattern as uart_tx.
    // -------------------------------------------------------------------------
    localparam S_IDLE  = 2'd0;  // Waiting for falling edge on synchronized rx
    localparam S_START = 2'd1;  // Counting to center of start bit, verifying
    localparam S_DATA  = 2'd2;  // Sampling 8 data bits at their centers
    localparam S_STOP  = 2'd3;  // Sampling stop bit, checking for framing error

    // -------------------------------------------------------------------------
    // 2-stage synchronizer for the asynchronous rx input
    //
    // WHY THIS IS NEEDED:
    //   The rx line comes from an external device with its own clock.  When
    //   our flip-flop samples rx on posedge clk, the signal might be
    //   transitioning at that exact instant — violating setup/hold timing.
    //   The flip-flop enters a "metastable" state: its output is neither a
    //   clean 0 nor a clean 1.  If this garbage value reaches the state
    //   machine, behavior becomes unpredictable.
    //
    // HOW IT WORKS:
    //   rx_meta takes the hit — it may go metastable.  But it has a full
    //   10 ns (one 100 MHz clock period) to settle before rx_sync samples
    //   it.  The probability of still being metastable after 10 ns is
    //   ~10^-20 for Xilinx 7-series flip-flops.  rx_sync is safe to use.
    //
    //                  +---------+      +---------+
    //   rx (async) --->| rx_meta |----->| rx_sync |-----> safe to use
    //                  +---------+      +---------+
    //
    // WHY RESET TO 1:
    //   Idle-high.  If we reset to 0, the edge detector would see a phantom
    //   falling edge on the first post-reset cycle (rx_prev=1, rx_sync=0),
    //   triggering a false start-bit detection.
    // -------------------------------------------------------------------------
    reg rx_meta;    // Stage 1 — may go metastable
    reg rx_sync;    // Stage 2 — clean, safe to use everywhere
    reg rx_prev;    // Previous value of rx_sync — for edge detection

    // -------------------------------------------------------------------------
    // Internal registers
    // -------------------------------------------------------------------------
    reg [1:0] state;        // Current FSM state
    reg [3:0] sample_cnt;   // Counts 0..15 tick_sample pulses within a bit
    reg [2:0] bit_idx;      // Counts 0..7 data bits received
    reg [7:0] shift_reg;    // Accumulates received bits (right-shift, MSB entry)

    // -------------------------------------------------------------------------
    // Synchronizer and edge detector — separate always block
    //
    // This runs EVERY clock cycle, independent of tick_sample.  The
    // synchronizer must sample rx at the full 100 MHz rate to minimize the
    // metastability window.  If we gated it with tick_sample (which fires
    // every 54 clocks), we would lose the benefit of synchronization.
    //
    // The edge detector (rx_prev) is also here for the same reason — we want
    // to detect falling edges at full clock resolution, not at 16x baud
    // resolution.  Gating with tick_sample would add up to 53 clocks of
    // detection latency (6.1% of a bit period).  At full rate, the worst
    // case is 1 clock (0.12% of a bit period).
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            rx_meta <= 1'b1;    // Reset to idle-high
            rx_sync <= 1'b1;
            rx_prev <= 1'b1;
        end else begin
            rx_meta <= rx;          // Stage 1: capture async input
            rx_sync <= rx_meta;     // Stage 2: clean by now
            rx_prev <= rx_sync;     // Remember for edge detection
        end
    end

    // -------------------------------------------------------------------------
    // Main state machine — single always block (matches uart_tx convention)
    //
    // IMPORTANT: State transitions in S_START, S_DATA, S_STOP are gated by
    // tick_sample.  But the falling-edge check in S_IDLE runs every clock
    // cycle for best time resolution.
    //
    // All outputs (rx_data, rx_done, rx_err) are registered — no glitches.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state      <= S_IDLE;
            rx_data    <= 8'h00;
            rx_done    <= 1'b0;
            rx_err     <= 1'b0;
            sample_cnt <= 4'd0;
            bit_idx    <= 3'd0;
            shift_reg  <= 8'h00;
        end else begin
            // Default: rx_done and rx_err are single-cycle pulses.
            // Clear them every cycle.  They only go high for one cycle
            // in the specific case that sets them.
            rx_done <= 1'b0;
            rx_err  <= 1'b0;

            case (state)
                // -----------------------------------------------------------
                // IDLE: Wait for a falling edge on the synchronized rx line.
                //
                // The line idles high.  A start bit begins with a high-to-low
                // transition.  We check every clock cycle (NOT gated by
                // tick_sample) so we detect the edge as soon as possible.
                //
                // On falling edge (rx_prev=1, rx_sync=0):
                //   1. Reset sample_cnt to 0 — start counting toward the
                //      center of the start bit.
                //   2. Go to S_START.
                // -----------------------------------------------------------
                S_IDLE: begin
                    if (rx_prev & ~rx_sync) begin   // Falling edge detected
                        sample_cnt <= 4'd0;
                        state      <= S_START;
                    end
                end

                // -----------------------------------------------------------
                // START: Count to the center of the start bit and verify.
                //
                // We detected the falling edge in IDLE.  The edge was at the
                // BEGINNING of the start bit.  To reach the CENTER, we count
                // 8 tick_sample pulses (half a bit period):
                //
                //   IDLE (high)       START BIT (low)          D0
                //   ~~~~~~~~\___________________________________/XXX
                //            ^              ^                    ^
                //       falling edge   center (8 ticks)    center (16 more)
                //       sample_cnt=0   sample_cnt=7
                //
                // At the center (sample_cnt == 7):
                //   - rx_sync == 0: Valid start bit.  The line is still low,
                //     confirming it was a real start bit, not a glitch.
                //     Reset sample_cnt, go to S_DATA.
                //   - rx_sync == 1: Glitch — the line bounced low then back
                //     high.  Return to S_IDLE silently.  No error output;
                //     glitch rejection is normal operation.
                // -----------------------------------------------------------
                S_START: begin
                    if (tick_sample) begin
                        if (sample_cnt == 4'd7) begin
                            if (~rx_sync) begin
                                // Valid start bit confirmed
                                sample_cnt <= 4'd0;
                                bit_idx    <= 3'd0;
                                state      <= S_DATA;
                            end else begin
                                // Glitch — line went back high
                                state <= S_IDLE;
                            end
                        end else begin
                            sample_cnt <= sample_cnt + 4'd1;
                        end
                    end
                end

                // -----------------------------------------------------------
                // DATA: Sample 8 data bits, one every 16 tick_sample pulses.
                //
                // After confirming the start bit, we count 16 ticks to reach
                // the center of each data bit:
                //
                //   Start verified     D0          D1        ...  D7
                //   ______________/XXXXXXXX\/XXXXXXXX\/      .../XXXXXXXX
                //                 ^        ^         ^           ^
                //              16 ticks  16 ticks  16 ticks   16 ticks
                //
                // At sample_cnt == 15 (center of current data bit):
                //   1. Shift rx_sync into shift_reg from the MSB side:
                //        shift_reg <= {rx_sync, shift_reg[7:1]}
                //
                //      WHY RIGHT-SHIFT WITH NEW BIT AT MSB?
                //      UART sends LSB first.  D0 arrives first, D7 last.
                //      Each new bit enters at position [7] and pushes older
                //      bits toward [0].  After 8 shifts:
                //        D0 (first received) is at position [0]
                //        D7 (last received)  is at position [7]
                //      The byte is in correct binary order.  No reversal.
                //
                //   2. If bit_idx == 7: all 8 bits received.  Go to S_STOP.
                //      Else: increment bit_idx, stay in S_DATA.
                // -----------------------------------------------------------
                S_DATA: begin
                    if (tick_sample) begin
                        if (sample_cnt == 4'd15) begin
                            // Center of current data bit — sample it
                            shift_reg  <= {rx_sync, shift_reg[7:1]};
                            sample_cnt <= 4'd0;
                            if (bit_idx == 3'd7) begin
                                state <= S_STOP;
                            end else begin
                                bit_idx <= bit_idx + 3'd1;
                            end
                        end else begin
                            sample_cnt <= sample_cnt + 4'd1;
                        end
                    end
                end

                // -----------------------------------------------------------
                // STOP: Sample the stop bit at its center.
                //
                // Count 16 ticks to reach the center of the stop bit.
                //
                // At sample_cnt == 15:
                //   1. Copy shift_reg to rx_data — the caller can read it.
                //   2. Pulse rx_done for one cycle.
                //   3. If rx_sync == 0: framing error — the stop bit should
                //      be high.  Possible causes:
                //        - Baud rate mismatch between sender and receiver
                //        - Electrical noise on the line
                //        - Break condition (sender holds line low on purpose)
                //      We still output rx_data.  The 8 data bits may be
                //      correct even if the stop bit is wrong.
                //   4. Return to S_IDLE.
                //
                // NATURAL RE-SYNCHRONIZATION:
                //   If there was a framing error (line is low), the edge
                //   detector in S_IDLE requires a 1-to-0 transition.  Since
                //   the line is already low, no falling edge is detected.
                //   RX waits until the line returns high, then catches the
                //   next real start bit.  No special recovery logic needed.
                // -----------------------------------------------------------
                S_STOP: begin
                    if (tick_sample) begin
                        if (sample_cnt == 4'd15) begin
                            rx_data <= shift_reg;
                            rx_done <= 1'b1;
                            if (~rx_sync) begin
                                rx_err <= 1'b1;     // Framing error
                            end
                            state <= S_IDLE;
                        end else begin
                            sample_cnt <= sample_cnt + 4'd1;
                        end
                    end
                end

                // -----------------------------------------------------------
                // Default: recover to IDLE.  Same defensive pattern as TX.
                // -----------------------------------------------------------
                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
