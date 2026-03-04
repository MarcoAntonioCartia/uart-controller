//=============================================================================
// Module:  led_pulse
// Project: UART Controller — Arty A7-100T
//
// Purpose: Stretch a single-cycle pulse into a visible LED blink.
//
// Problem: UART events like rx_done and tx_done are single-cycle pulses —
//          10 ns at 100 MHz.  An LED driven by a 10 ns pulse is completely
//          invisible to the human eye (persistence of vision needs ~10 ms
//          minimum).
//
// Solution: A down-counter that loads DURATION on any trigger pulse, then
//           counts down to zero.  The output stays high while the counter
//           is non-zero.
//
//                  trigger
//                     │
//                     │       
//                     v
//           ┌──────────────────┐
//           │  if trigger:     │
//           │    cnt = DURATION│
//           │  else if cnt>0:  │
//           │    cnt = cnt - 1 │
//           └──────────────────┘
//                     │
//                     v
//             out = (cnt != 0)
//
// Re-triggering: If a new trigger arrives while the counter is still
//                counting, it reloads to DURATION.  This means rapid
//                byte traffic keeps the LED solidly lit — exactly what
//                we want for an "activity" indicator.
//
// Default DURATION: 1,000,000 clocks = 10 ms at 100 MHz.
//   At 115200 baud, one byte takes ~86.8 us = 8,680 clocks.
//   10 ms = ~115 byte-times — a comfortable visible blink even for
//   a single byte, and sustained glow during continuous traffic.
//
// Resource cost: One 20-bit counter + one LUT for the output.
//                Four instances (one per LED) use negligible FPGA resources.
//
// Reset: Synchronous, active-high.  Counter clears to 0, output goes low.
//=============================================================================

module led_pulse #(
    parameter DURATION = 1_000_000   // Hold time in clock cycles (10 ms @ 100 MHz)
) (
    input  wire clk,       // System clock (100 MHz)
    input  wire rst,       // Synchronous reset, active-high
    input  wire trigger,   // Single-cycle input pulse (e.g., rx_done)
    output wire out        // Active-high output — drives LED
);

    // -------------------------------------------------------------------------
    // Counter width — just wide enough to hold DURATION.
    //
    // $clog2(1_000_000) = 20 bits.  Same pattern as baud_gen's counters.
    // If someone changes DURATION, the counter auto-sizes.
    // -------------------------------------------------------------------------
    localparam CNT_W = $clog2(DURATION + 1);

    reg [CNT_W-1:0] cnt;

    // -------------------------------------------------------------------------
    // Down-counter logic
    //
    // Priority: trigger > counting > idle.
    //
    // On trigger: reload counter to DURATION (even if already counting).
    //             This makes the LED "re-triggerable" — continuous traffic
    //             keeps it solidly lit.
    //
    // Otherwise:  if counter is non-zero, decrement.  When it reaches zero,
    //             the LED goes dark.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            cnt <= 0;
        end else if (trigger) begin
            cnt <= DURATION;
        end else if (cnt != 0) begin
            cnt <= cnt - 1'b1;
        end
    end

    // Output: LED is on whenever counter is non-zero.
    // Continuous assign — no flip-flop, just a comparator.
    // The one-cycle delay between trigger and out going high (due to the
    // registered counter) is completely imperceptible for LED driving.
    assign out = (cnt != 0);

endmodule
