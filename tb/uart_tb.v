//=============================================================================
// Testbench: uart_tb
// Project:   UART Controller — Arty A7-100T
//
// Purpose: Verify the complete TX → RX data path using loopback.
//          TX serializes a byte, the wire connects directly to RX, and RX
//          deserializes it.  If the received byte matches, both modules work.
//
// Test cases:
//   1. Single byte (0xA5) — basic loopback sanity
//   2. All-zeros (0x00) and all-ones (0xFF) — shift register edge cases
//   3. Alternating bits (0x55, 0xAA) — max transitions, timing stress
//   4. Back-to-back TX (0x12, 0x34) — consecutive frames, no idle gap
//   5. tx_start while busy — verify interference is ignored
//
// Simulation:
//   iverilog -o sim tb/uart_tb.v src/baud_gen.v src/uart_tx.v src/uart_rx.v
//   vvp sim
//
// Waveform viewing:
//   The testbench writes a VCD (Value Change Dump) file called uart_tb.vcd.
//   Open it with GTKWave to see all signals over time:
//     gtkwave uart_tb.vcd
//
// IMPORTANT: This file is simulation-only.  It uses initial blocks, #delays,
// $display, and other constructs that cannot be synthesized to hardware.
// That is normal — testbenches are never put on the FPGA.
//=============================================================================

// ---------------------------------------------------------------------------
// `timescale directive
//
// This tells the simulator what real-world time #1 represents.
//   `timescale 1ns / 1ps  means:
//     - #1  = 1 nanosecond
//     - #0.001 = 1 picosecond (the smallest resolvable step)
//
// Our 100 MHz clock has a 10 ns period, so we toggle every #5.
// Without `timescale, the simulator has no concept of real time units.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module uart_tb;

    // -------------------------------------------------------------------------
    // Parameters — use real hardware values.
    //
    // At 100 MHz and 115200 baud, one UART frame (10 bits) takes:
    //   10 × 868 = 8,680 clock cycles = 86.8 us
    //
    // Five test cases with ~10 frames total: under 1 ms of sim time.
    // Icarus Verilog handles this in well under a second.
    // -------------------------------------------------------------------------
    localparam CLK_FREQ  = 100_000_000;
    localparam BAUD_RATE = 115_200;

    // Timeout: if RX doesn't respond within this many clocks, something is
    // stuck.  200,000 clocks = ~2 ms — far longer than any single frame.
    localparam TIMEOUT = 200_000;

    // -------------------------------------------------------------------------
    // Testbench signals
    //
    // In a testbench, we declare regs for signals we drive (inputs to the DUT)
    // and wires for signals the DUT drives (outputs from the DUT).
    // -------------------------------------------------------------------------
    reg        clk;
    reg        rst;
    reg        tx_start;
    reg  [7:0] tx_data;

    wire       tx_serial;      // The loopback wire: TX output → RX input
    wire       tx_busy;
    wire       tx_done;
    wire [7:0] rx_data;
    wire       rx_done;
    wire       rx_err;
    wire       tick_baud;
    wire       tick_sample;

    // Test tracking
    integer tests_passed;
    integer tests_total;

    // -------------------------------------------------------------------------
    // Clock generation
    //
    // An always block with no sensitivity list and a #delay creates a free-
    // running oscillator.  #5 means toggle every 5 ns → 10 ns period → 100 MHz.
    //
    // This runs forever in the background.  The initial block controls when
    // the simulation ends with $finish.
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;      // 100 MHz: 5 ns high, 5 ns low

    // -------------------------------------------------------------------------
    // VCD waveform dump
    //
    // $dumpfile creates a file that records every signal transition.
    // $dumpvars(0, uart_tb) dumps ALL signals in the uart_tb module and all
    // its sub-modules (depth 0 = unlimited depth).
    //
    // Open the resulting file with GTKWave:
    //   gtkwave uart_tb.vcd
    //
    // This is our software oscilloscope — we can zoom into any bit period
    // and see exactly what tx, rx, the state machines, and counters are doing.
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("uart_tb.vcd");
        $dumpvars(0, uart_tb);
    end

    // -------------------------------------------------------------------------
    // Module instantiation
    //
    // We create one instance of each module and wire them together.
    // The key connection is the loopback: tx_serial feeds directly into
    // uart_rx's rx input.
    //
    //   baud_gen ──tick_baud──► uart_tx ──tx_serial──► uart_rx
    //            └─tick_sample──────────────────────────┘
    // -------------------------------------------------------------------------
    baud_gen #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) u_baud_gen (
        .clk(clk),
        .rst(rst),
        .tick_baud(tick_baud),
        .tick_sample(tick_sample)
    );

    uart_tx u_tx (
        .clk(clk),
        .rst(rst),
        .tick_baud(tick_baud),
        .tx_start(tx_start),
        .tx_data(tx_data),
        .tx(tx_serial),         // TX output
        .tx_busy(tx_busy),
        .tx_done(tx_done)
    );

    uart_rx u_rx (
        .clk(clk),
        .rst(rst),
        .tick_sample(tick_sample),
        .rx(tx_serial),         // Loopback: wired directly to TX output
        .rx_data(rx_data),
        .rx_done(rx_done),
        .rx_err(rx_err)
    );

    // =========================================================================
    // Helper tasks
    //
    // Tasks are like functions, but they can contain #delays and @(posedge clk)
    // waits.  This makes them perfect for testbench operations that span
    // multiple clock cycles.
    //
    // Without tasks, we would copy-paste the same send/wait/check sequence
    // for every test — tedious and error-prone.
    // =========================================================================

    // -------------------------------------------------------------------------
    // send_byte: Wait for TX to be idle, then pulse tx_start for one cycle.
    //
    // WHY WAIT FOR !tx_busy?
    //   RX and TX use different counters (tick_sample vs tick_baud), so they
    //   finish at different times.  RX can fire rx_done up to ~500 clocks
    //   BEFORE TX returns to IDLE.  If we pulse tx_start while TX is still
    //   in its STOP state, TX ignores it (it only checks tx_start in IDLE).
    //   The byte is silently lost.
    //
    //   This mirrors real firmware practice: always check the busy flag
    //   before writing a new byte to the UART.
    //
    // THE #1 DELAY:
    //   At a posedge clk, both the DUT's always block and this initial block
    //   wake up.  Verilog does NOT guarantee which runs first.  The #1 (1 ns)
    //   delay advances past the DUT's non-blocking assignment (NBA) update
    //   region, so we always read/write the correct values.
    //
    //   This is a simulation-only concern.  Real hardware has no race —
    //   flip-flops sample inputs at the clock edge deterministically.
    // -------------------------------------------------------------------------
    task send_byte;
        input [7:0] data;
        begin
            // Wait until TX is idle — safe to send
            while (tx_busy) begin
                @(posedge clk); #1;
            end
            @(posedge clk); #1;     // Sync to edge, then wait past NBA region
            tx_data  = data;
            tx_start = 1'b1;
            @(posedge clk); #1;     // DUT latches data on this edge
            tx_start = 1'b0;        // Safe to de-assert — DUT already saw it
        end
    endtask

    // -------------------------------------------------------------------------
    // wait_rx_done: Spin until rx_done pulses, with a timeout guard.
    //
    // If RX never responds (bug in the design), the timeout prevents the
    // simulation from hanging forever.  The timeout counter is generous —
    // 200,000 clocks is ~23x longer than one frame should take.
    //
    // The #1 delay after @(posedge clk) ensures we read rx_done AFTER the
    // DUT's non-blocking assignments have updated it.  Without this, we
    // might check the OLD value of rx_done and miss a single-cycle pulse.
    // -------------------------------------------------------------------------
    task wait_rx_done;
        integer countdown;
        begin
            countdown = TIMEOUT;
            while (!rx_done && countdown > 0) begin
                @(posedge clk); #1;
                countdown = countdown - 1;
            end
            if (countdown == 0) begin
                $display("  ERROR: Timeout waiting for rx_done!");
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // check_rx: Compare rx_data against an expected value.
    //           Print PASS or FAIL with hex values.  Update test counters.
    // -------------------------------------------------------------------------
    task check_rx;
        input [7:0] expected;
        begin
            tests_total = tests_total + 1;
            if (rx_data === expected && !rx_err) begin
                $display("  PASS: sent=0x%02h, received=0x%02h", expected, rx_data);
                tests_passed = tests_passed + 1;
            end else begin
                $display("  FAIL: sent=0x%02h, received=0x%02h, rx_err=%b",
                         expected, rx_data, rx_err);
            end
        end
    endtask

    // =========================================================================
    // Main test sequence
    //
    // This initial block is the "test script".  It runs once from top to
    // bottom.  Each section applies stimulus, waits for the result, and checks
    // the output.
    //
    // The pattern for every test is:
    //   1. send_byte(data)    — give TX a byte to transmit
    //   2. wait_rx_done       — wait for RX to receive it (with timeout)
    //   3. check_rx(expected) — verify the received byte matches
    // =========================================================================
    initial begin
        // -----------------------------------------------------------------
        // Setup: initialize all inputs and apply reset.
        //
        // We hold rst high for 10 clock cycles.  This gives all modules
        // time to reach a known state.  In simulation, flip-flops start at
        // 'x' (unknown) — reset forces them to defined values.
        // -----------------------------------------------------------------
        $display("");
        $display("==============================================");
        $display("  UART Loopback Testbench");
        $display("  CLK_FREQ = %0d Hz, BAUD_RATE = %0d", CLK_FREQ, BAUD_RATE);
        $display("==============================================");

        tests_passed = 0;
        tests_total  = 0;
        tx_start     = 1'b0;
        tx_data      = 8'h00;
        rst          = 1'b1;        // Assert reset

        repeat (10) @(posedge clk); // Hold reset for 10 clocks
        rst = 1'b0;                 // Release reset

        repeat (10) @(posedge clk); // Let things settle

        // =================================================================
        // Test 1: Single byte loopback (0xA5)
        //
        // The most basic test: send one byte, verify it comes back.
        // 0xA5 = 10100101 — a mix of 1s and 0s to exercise the shift
        // register in both directions.
        // =================================================================
        $display("");
        $display("--- Test 1: Single byte (0xA5) ---");
        send_byte(8'hA5);
        wait_rx_done;
        check_rx(8'hA5);

        // Small gap between tests
        repeat (100) @(posedge clk);

        // =================================================================
        // Test 2: All-zeros (0x00) and all-ones (0xFF)
        //
        // 0x00: Every data bit is low.  After the start bit (also low),
        //       the line stays low for 9 consecutive bit periods.  This
        //       tests whether RX correctly counts bits instead of getting
        //       confused by the extended low period.
        //
        // 0xFF: Every data bit is high.  The line goes low for the start
        //       bit, then immediately back high for 8 data bits + stop.
        //       This tests whether RX correctly detects the start bit
        //       when the data all looks like idle.
        // =================================================================
        $display("");
        $display("--- Test 2: All-zeros (0x00) ---");
        send_byte(8'h00);
        wait_rx_done;
        check_rx(8'h00);

        repeat (100) @(posedge clk);

        $display("");
        $display("--- Test 2: All-ones (0xFF) ---");
        send_byte(8'hFF);
        wait_rx_done;
        check_rx(8'hFF);

        repeat (100) @(posedge clk);

        // =================================================================
        // Test 3: Alternating bits (0x55, 0xAA)
        //
        // 0x55 = 01010101 and 0xAA = 10101010.  These produce the maximum
        // number of transitions on the wire — the signal toggles every bit
        // period.  This is the hardest pattern for timing-sensitive designs.
        // If the sampling point drifts even slightly, we get the wrong bit.
        // =================================================================
        $display("");
        $display("--- Test 3: Alternating bits (0x55) ---");
        send_byte(8'h55);
        wait_rx_done;
        check_rx(8'h55);

        repeat (100) @(posedge clk);

        $display("");
        $display("--- Test 3: Alternating bits (0xAA) ---");
        send_byte(8'hAA);
        wait_rx_done;
        check_rx(8'hAA);

        repeat (100) @(posedge clk);

        // =================================================================
        // Test 4: Back-to-back transmission (0x12, then 0x34)
        //
        // Send two bytes with minimal gap.  As soon as tx_busy drops
        // (the first frame's stop bit is complete), we fire the second
        // byte immediately.  This tests:
        //   - TX can restart without needing extra idle time
        //   - RX handles consecutive frames without losing sync
        //   - Both bytes arrive in the correct order
        // =================================================================
        $display("");
        $display("--- Test 4: Back-to-back (0x12, 0x34) ---");

        // Send first byte
        send_byte(8'h12);
        wait_rx_done;
        check_rx(8'h12);

        // Wait for TX to finish (tx_busy goes low), then send immediately
        while (tx_busy) begin
            @(posedge clk); #1;
        end
        send_byte(8'h34);
        wait_rx_done;
        check_rx(8'h34);

        repeat (100) @(posedge clk);

        // =================================================================
        // Test 5: tx_start while busy (should be ignored)
        //
        // Send 0xBE, then while TX is still transmitting, assert tx_start
        // with a DIFFERENT byte (0xEF).  The TX module should ignore the
        // second request because it only checks tx_start in S_IDLE.
        //
        // We verify that 0xBE arrives (not 0xEF).
        // =================================================================
        $display("");
        $display("--- Test 5: tx_start while busy ---");

        // Start transmitting 0xBE
        send_byte(8'hBE);

        // Wait a few clocks (TX is now in START or DATA state)
        repeat (50) @(posedge clk);

        // Try to interfere: assert tx_start with different data
        @(posedge clk); #1;
        tx_data  = 8'hEF;          // Different byte
        tx_start = 1'b1;
        @(posedge clk); #1;
        tx_start = 1'b0;

        // Wait for the original byte to be received
        wait_rx_done;
        check_rx(8'hBE);           // Should be 0xBE, NOT 0xEF

        repeat (100) @(posedge clk);

        // =================================================================
        // Final report
        // =================================================================
        $display("");
        $display("==============================================");
        if (tests_passed == tests_total)
            $display("  ALL TESTS PASSED (%0d/%0d)", tests_passed, tests_total);
        else
            $display("  SOME TESTS FAILED (%0d/%0d passed)", tests_passed, tests_total);
        $display("==============================================");
        $display("");

        // -----------------------------------------------------------------
        // $finish terminates the simulation.  Without it, the clock
        // generator (always #5 clk = ~clk) would run forever.
        // -----------------------------------------------------------------
        $finish;
    end

endmodule
