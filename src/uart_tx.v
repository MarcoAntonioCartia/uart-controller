//=============================================================================
// Module:  uart_tx
// Project: UART Controller — Arty A7-100T
//
// Purpose: Serialize an 8-bit byte into a UART frame (8N1) and drive the TX
//          line.  Uses tick_baud from baud_gen as a clock enable — the entire
//          design stays in the 100 MHz system clock domain.
//
// Frame format (8N1):
//
//        idle   start   D0  D1  D2  D3  D4  D5  D6  D7   stop   idle
//  tx: ~~^^^~~~______~XXXX~XXXX~XXXX~XXXX~XXXX~XXXX~XXXX~XXXX~~~^^^~~~
//                |<------------- LSB first ------------>|
//                ^                                       ^
//         falling edge                              back to high
//       (receiver syncs here)
//
// Interface:
//   tx_start — assert for >= 1 clk cycle while tx_busy is low.
//              tx_data is latched internally on that edge, so the caller
//              can change tx_data freely on the next cycle.
//
//   tx_busy  — high during START, DATA, and STOP states.
//              Check this before asserting tx_start.
//              tx_start during busy is silently ignored.
//
//   tx_done  — single-cycle pulse when the stop bit completes.
//              Same convention as tick_baud in baud_gen.
//
// Reset: Synchronous, active-high.  tx is driven high on reset to prevent
//        the receiver from seeing a false start bit.
//=============================================================================

module uart_tx (
    input  wire       clk,        // System clock (100 MHz)
    input  wire       rst,        // Synchronous reset, active-high
    input  wire       tick_baud,  // 1x baud rate tick from baud_gen
    input  wire       tx_start,   // Pulse high to begin transmission
    input  wire [7:0] tx_data,    // Byte to transmit (latched on tx_start)
    output reg        tx,         // Serial output — idles high
    output reg        tx_busy,    // High while frame is in progress
    output reg        tx_done     // Single-cycle pulse on frame completion
);

    // -------------------------------------------------------------------------
    // State definitions
    //
    // Four states map 1:1 to the phases of a UART frame.  We use localparam
    // (not parameter or `define) so they are module-scoped and cannot be
    // accidentally overridden.
    //
    // Vivado's synthesizer will detect this as an FSM and re-encode the states
    // to one-hot, which is optimal for Xilinx 7-series LUT6 architecture.
    // we can verify this in the synthesis log ("FSM Encoding" section).
    // -------------------------------------------------------------------------
    localparam S_IDLE  = 2'd0;  // Waiting for tx_start
    localparam S_START = 2'd1;  // Driving start bit (low) for one baud period
    localparam S_DATA  = 2'd2;  // Shifting out 8 data bits, LSB first
    localparam S_STOP  = 2'd3;  // Driving stop bit (high) for one baud period

    // -------------------------------------------------------------------------
    // Internal registers
    // -------------------------------------------------------------------------
    reg [1:0] state;        // Current FSM state
    reg [7:0] shift_reg;    // Data byte being shifted out (right-shift)
    reg [2:0] bit_idx;      // Counts 0..7 — which data bit we are sending

    // -------------------------------------------------------------------------
    // Main state machine — single always block
    //
    // Why one block instead of separate combinational + sequential blocks?
    // With a single synchronous block, every output (tx, tx_busy, tx_done)
    // is a registered flip-flop output.  This means:
    //   - No combinational glitches on the tx line
    //   - Simple timing — outputs update on the clock edge, always clean
    //   - One-cycle latency vs. combinational outputs, but that's <0.12%
    //     of a bit period at 115200 baud — completely negligible
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            // ---------------------------------------------------------------
            // Reset: go to idle.  tx MUST go high — if it were low, the
            // receiver would see a false start bit during/after reset.
            // ---------------------------------------------------------------
            state     <= S_IDLE;
            tx        <= 1'b1;      // Idle = high
            tx_busy   <= 1'b0;
            tx_done   <= 1'b0;
            shift_reg <= 8'h00;
            bit_idx   <= 3'd0;
        end else begin
            // Default: tx_done is a single-cycle pulse, so clear it every
            // cycle.  It only gets set to 1 for one cycle in the STOP case.
            tx_done <= 1'b0;

            case (state)
                // -----------------------------------------------------------
                // IDLE: tx line is high.  Wait for tx_start.
                //
                // When tx_start fires:
                //   1. Latch tx_data into shift_reg.  This is critical —
                //      without latching, the data could change mid-frame
                //      if the caller updates tx_data.
                //   2. Reset bit_idx to 0.
                //   3. Drive tx low — the start bit begins NOW.
                //   4. Set tx_busy so the caller knows not to send again.
                //   5. Transition to S_START.
                //
                // We do NOT wait for tick_baud.  The start bit begins
                // immediately.  The baud counter is free-running, so this
                // first start bit may be shorter than a full baud period.
                // That's fine — the receiver synchronizes on the falling
                // edge, then samples at bit centers.  All subsequent bits
                // are perfectly spaced by tick_baud.
                // -----------------------------------------------------------
                S_IDLE: begin
                    if (tx_start) begin
                        shift_reg <= tx_data;   // Latch the byte
                        bit_idx   <= 3'd0;
                        tx        <= 1'b0;      // Start bit = low
                        tx_busy   <= 1'b1;
                        state     <= S_START;
                    end
                end

                // -----------------------------------------------------------
                // START: tx is already low (driven when leaving IDLE).
                //        Hold it for one baud period.
                //
                // On tick_baud:
                //   - Start bit has been held long enough.
                //   - Drive tx with shift_reg[0] (the first data bit, LSB).
                //   - Move to S_DATA.
                // -----------------------------------------------------------
                S_START: begin
                    if (tick_baud) begin
                        tx    <= shift_reg[0];  // First data bit (LSB)
                        state <= S_DATA;
                    end
                end

                // -----------------------------------------------------------
                // DATA: shift out 8 bits, one per tick_baud.
                //
                // On each tick_baud:
                //   - If bit_idx == 7: all 8 bits sent.  Drive tx high
                //     (stop bit) and move to S_STOP.
                //   - Otherwise: right-shift the register and output the
                //     next bit.  Increment bit_idx.
                //
                // Shift register detail:
                //   shift_reg <= {1'b0, shift_reg[7:1]}  — right shift
                //   tx        <= shift_reg[1]             — next bit
                //
                //   Why shift_reg[1] and not shift_reg[0]?
                //   Non-blocking assignments (<=) read the OLD value of
                //   shift_reg on the right-hand side.  So shift_reg[1]
                //   in the old register is the SAME as shift_reg[0] in
                //   the new (post-shift) register.  Both lines execute
                //   "simultaneously" — the shift hasn't happened yet when
                //   tx reads shift_reg[1].
                // -----------------------------------------------------------
                S_DATA: begin
                    if (tick_baud) begin
                        if (bit_idx == 3'd7) begin
                            tx    <= 1'b1;      // Stop bit = high
                            state <= S_STOP;
                        end else begin
                            shift_reg <= {1'b0, shift_reg[7:1]};
                            tx        <= shift_reg[1];
                            bit_idx   <= bit_idx + 3'd1;
                        end
                    end
                end

                // -----------------------------------------------------------
                // STOP: tx is high (driven when leaving DATA).
                //       Hold it for one baud period.
                //
                // On tick_baud:
                //   - Stop bit complete.  Pulse tx_done for one cycle.
                //   - Clear tx_busy — ready for the next byte.
                //   - Return to S_IDLE.  tx stays high (idle state).
                //
                // If tx_start is asserted at this exact moment, it will be
                // caught on the NEXT clock cycle in S_IDLE.  This guarantees
                // the stop bit is always a full baud period — no shortcuts.
                // -----------------------------------------------------------
                S_STOP: begin
                    if (tick_baud) begin
                        tx_done <= 1'b1;        // Pulse: frame complete
                        tx_busy <= 1'b0;
                        state   <= S_IDLE;
                    end
                end

                // -----------------------------------------------------------
                // Default: should never be reached.  If it does (e.g., a
                // bit-flip in the state register due to radiation or noise),
                // recover gracefully to IDLE with tx high.  Defensive coding
                // for synthesized logic.
                // -----------------------------------------------------------
                default: begin
                    state <= S_IDLE;
                    tx    <= 1'b1;
                end
            endcase
        end
    end

endmodule
