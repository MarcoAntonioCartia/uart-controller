//=============================================================================
// Module:  uart_top
// Project: UART Controller — Arty A7-100T
//
// Purpose: Top-level module that wires everything together for the FPGA.
//          This is the module that will be synthesized by Vivado and mapped to real pins.
//
// Architecture, Dual-Channel Echo:
//
//   The FPGA runs TWO independent UART echo channels:
//
//   Channel 1 (USB — PC communication):
//     PC terminal ──► usb_rx (A9) ──► uart_rx ──► uart_tx ──► usb_tx (D10) ──► PC
//
//   Channel 2 (Pmod JA — Raspberry Pi Pico):
//     Pico ──► pmod_rx (B11) ──► uart_rx ──► uart_tx ──► pmod_tx (G13) ──► Pico
//
//   Each channel independently echoes received bytes back to the sender.
//   The two channels share nothing — separate baud generators, separate
//   state machines.  They can operate simultaneously without interference.
//
// Echo logic:
//   When uart_rx fires rx_done (single-cycle pulse), we connect it directly
//   to uart_tx's tx_start.  rx_data feeds tx_data.  The byte echoes back.
//   No FIFO needed — single-byte echo is just wiring.
//
// LEDs:
//   LED[0] = RX activity   (blinks on any rx_done from either channel)
//   LED[1] = TX activity   (blinks on any tx_done from either channel)
//   LED[2] = Framing error (blinks on any rx_err from either channel)
//   LED[3] = Heartbeat     (1 Hz toggle — "board is alive" indicator)
//
//   All event LEDs use led_pulse to stretch single-cycle pulses to ~10 ms
//   visible blinks.
//
// ILA Debug Probes:
//   Key internal signals are marked with (* mark_debug = "true" *) so
//   Vivado's Integrated Logic Analyzer can capture them on the real FPGA.
//   This is our "software oscilloscope" — see the actual serial waveforms,
//   state machine transitions, and received data in Vivado's waveform viewer.
//
//   HOW TO USE (after this file is synthesized in Vivado):
//     1. Run Synthesis
//     2. Open Synthesized Design → Set Up Debug (in the Flow Navigator)
//     3. Vivado auto-detects all (* mark_debug *) signals
//     4. Click through the wizard:
//        - Sample depth: 2048 (or 4096 for longer captures)
//        - Clock domain: clk (100 MHz — auto-detected)
//     5. Save constraints (File → Save Constraints)
//     6. Run Implementation → Generate Bitstream
//     7. Program FPGA → Open Hardware Manager
//     8. The ILA dashboard appears automatically
//     9. Set trigger: e.g., usb_rx_done == rising edge
//    10. Arm the trigger → send a byte from PC terminal
//    11. ILA captures the waveform — zoom in to see every bit!
//
//   Sample depth math:
//     2048 samples at 100 MHz = 20.48 µs capture window.
//     One UART bit at 115200 baud = 8.68 µs.
//     So 2048 samples captures ~2.4 bit periods around the trigger.
//     Use 4096 for ~4.7 bit periods, or 8192 for a full byte frame.
//     The trigger centers the capture, so we see context before and after.
//
// Port names match constraints/arty_a7.xdc exactly.
//=============================================================================

module uart_top (
    input  wire       clk,        // E3  — 100 MHz crystal oscillator
    input  wire       rst,        // D9  — BTN0, active-high push button
    input  wire       usb_rx,     // A9  — Serial input from PC (via FTDI chip)
    output wire       usb_tx,     // D10 — Serial output to PC (via FTDI chip)
    input  wire       pmod_rx,    // B11 — Serial input from Pico (JA pin 2)
    output wire       pmod_tx,    // G13 — Serial output to Pico (JA pin 1)
    output wire [3:0] led         // H5, J5, T9, T10 — Status LEDs
);

    // =========================================================================
    // Internal wires — USB channel
    //
    // These connect the baud generator, TX, and RX for the USB/PC channel.
    // Each wire is named with the usb_ prefix to distinguish from the Pmod
    // channel.
    //
    // The (* mark_debug = "true" *) attribute tells Vivado's synthesizer to
    // preserve these signals and make them available for ILA probing.
    // Without this attribute, synthesis might optimize away intermediate
    // wires (e.g., merge usb_rx_data directly into the TX shift register,
    // making the 8-bit value invisible to the debugger).
    //
    // The (* keep = "true" *) attribute prevents the signal from being
    // absorbed into the next logic stage.  Both attributes together ensure
    // the signal survives synthesis with its exact name and width intact.
    // =========================================================================

    // Baud generator ticks
    wire usb_tick_baud;
    wire usb_tick_sample;

    // TX signals
    (* mark_debug = "true", keep = "true" *) wire       usb_tx_serial;
    (* mark_debug = "true", keep = "true" *) wire       usb_tx_busy;
    (* mark_debug = "true", keep = "true" *) wire       usb_tx_done;

    // RX signals
    (* mark_debug = "true", keep = "true" *) wire [7:0] usb_rx_data;
    (* mark_debug = "true", keep = "true" *) wire       usb_rx_done;
    (* mark_debug = "true", keep = "true" *) wire       usb_rx_err;

    // =========================================================================
    // Internal wires — Pmod channel
    //
    // Same pattern as USB, but for the Pico connection via Pmod JA.
    // We probe fewer signals on this channel — if the USB channel works,
    // the Pmod channel uses identical modules and will behave the same.
    // We can always add more (* mark_debug *) attributes later if needed.
    // =========================================================================

    // Baud generator ticks
    wire pmod_tick_baud;
    wire pmod_tick_sample;

    // TX signals
    (* mark_debug = "true", keep = "true" *) wire       pmod_tx_serial;
    wire                                                 pmod_tx_busy;
    wire                                                 pmod_tx_done;

    // RX signals
    (* mark_debug = "true", keep = "true" *) wire [7:0] pmod_rx_data;
    (* mark_debug = "true", keep = "true" *) wire       pmod_rx_done;
    wire                                                 pmod_rx_err;

    // =========================================================================
    // USB Channel — Baud Generator + TX + RX
    //
    // Three instances wired together, same as the testbench loopback but
    // with real pins instead of a loopback wire.
    //
    //   baud_gen ──tick_baud──► uart_tx ──usb_tx_serial──► usb_tx (pin D10)
    //            └─tick_sample──► uart_rx ◄── usb_rx (pin A9)
    // =========================================================================

    baud_gen #(
        .CLK_FREQ  (100_000_000),
        .BAUD_RATE (115_200)
    ) u_baud_usb (
        .clk         (clk),
        .rst         (rst),
        .tick_baud   (usb_tick_baud),
        .tick_sample (usb_tick_sample)
    );

    uart_tx u_tx_usb (
        .clk       (clk),
        .rst       (rst),
        .tick_baud (usb_tick_baud),
        .tx_start  (usb_rx_done),       // Echo: RX done → start TX
        .tx_data   (usb_rx_data),       // Echo: received byte → transmit byte
        .tx        (usb_tx_serial),
        .tx_busy   (usb_tx_busy),
        .tx_done   (usb_tx_done)
    );

    uart_rx u_rx_usb (
        .clk         (clk),
        .rst         (rst),
        .tick_sample (usb_tick_sample),
        .rx          (usb_rx),          // Pin A9 — serial input from PC
        .rx_data     (usb_rx_data),
        .rx_done     (usb_rx_done),
        .rx_err      (usb_rx_err)
    );

    // Drive the USB TX output pin
    assign usb_tx = usb_tx_serial;

    // =========================================================================
    // Pmod Channel — Baud Generator + TX + RX
    //
    // Identical structure to USB channel, different pins.
    //
    //   baud_gen ──tick_baud──► uart_tx ──pmod_tx_serial──► pmod_tx (pin G13)
    //            └─tick_sample──► uart_rx ◄── pmod_rx (pin B11)
    // =========================================================================

    baud_gen #(
        .CLK_FREQ  (100_000_000),
        .BAUD_RATE (115_200)
    ) u_baud_pmod (
        .clk         (clk),
        .rst         (rst),
        .tick_baud   (pmod_tick_baud),
        .tick_sample (pmod_tick_sample)
    );

    uart_tx u_tx_pmod (
        .clk       (clk),
        .rst       (rst),
        .tick_baud (pmod_tick_baud),
        .tx_start  (pmod_rx_done),      // Echo: RX done → start TX
        .tx_data   (pmod_rx_data),      // Echo: received byte → transmit byte
        .tx        (pmod_tx_serial),
        .tx_busy   (pmod_tx_busy),
        .tx_done   (pmod_tx_done)
    );

    uart_rx u_rx_pmod (
        .clk         (clk),
        .rst         (rst),
        .tick_sample (pmod_tick_sample),
        .rx          (pmod_rx),         // Pin B11 — serial input from Pico
        .rx_data     (pmod_rx_data),
        .rx_done     (pmod_rx_done),
        .rx_err      (pmod_rx_err)
    );

    // Drive the Pmod TX output pin
    assign pmod_tx = pmod_tx_serial;

    // =========================================================================
    // Echo Logic — Why This Works
    // 
    // The echo connection is deceptively simple:
    //   .tx_start (usb_rx_done)    — rx_done IS the tx_start pulse
    //   .tx_data  (usb_rx_data)    — rx_data IS the tx_data byte
    //
    // This works because of how we designed the modules:
    //
    //   1. rx_done is a single-cycle pulse — exactly what tx_start expects.
    //
    //   2. rx_data holds its value until the next byte overwrites it.
    //      So when rx_done fires, rx_data is stable and valid.  uart_tx
    //      latches tx_data into its internal shift_reg on the tx_start
    //      edge, so rx_data can change freely after that.
    //
    //   3. What if TX is busy when rx_done fires?  TX ignores tx_start
    //      when busy (by design — see uart_tx S_IDLE).  The received
    //      byte is lost.  At 115200 baud, this can't happen for echo:
    //      TX finishes the previous byte before RX completes the next one
    //      (both take exactly 10 bit periods).  For higher-speed or
    //      multi-byte protocols, we would need a FIFO — but for echo,
    //      direct wiring is correct and sufficient.
    //
    //   4. No FIFO, no handshaking, no extra state machine.  The echo
    //      path is pure combinational wiring — zero additional logic,
    //      zero additional latency, zero things that can break.
    // =========================================================================

    // =========================================================================
    // LED Drivers
    //
    // Each LED is driven by a led_pulse instance that stretches a single-
    // cycle event into a ~10 ms visible blink.
    //
    // We OR the events from both channels so any activity lights up the LED.
    // In practice, we'll typically use one channel at a time (PC or Pico),
    // so there's no confusion.  If both channels are active simultaneously,
    // the LED just stays lit — which is correct behavior.
    // =========================================================================

    // LED[0]: RX activity — any byte received on either channel
    led_pulse #(.DURATION(1_000_000)) u_led_rx (
        .clk     (clk),
        .rst     (rst),
        .trigger (usb_rx_done | pmod_rx_done),
        .out     (led[0])
    );

    // LED[1]: TX activity — any byte transmitted on either channel
    led_pulse #(.DURATION(1_000_000)) u_led_tx (
        .clk     (clk),
        .rst     (rst),
        .trigger (usb_tx_done | pmod_tx_done),
        .out     (led[1])
    );

    // LED[2]: Framing error — bad stop bit on either channel
    led_pulse #(.DURATION(1_000_000)) u_led_err (
        .clk     (clk),
        .rst     (rst),
        .trigger (usb_rx_err | pmod_rx_err),
        .out     (led[2])
    );

    // =========================================================================
    // LED[3]: Heartbeat — 1 Hz blink ("board is alive")
    //
    // A classic FPGA sanity check.  If LED[3] is blinking at ~1 Hz, we know:
    //   1. The FPGA is programmed (bitstream loaded successfully)
    //   2. The 100 MHz clock is running
    //   3. The design is not stuck in reset
    //
    // Implementation: a 27-bit counter that increments every clock cycle.
    // Bit 26 toggles every 2^26 = 67,108,864 clocks.
    //   Period = 2 × 67,108,864 / 100,000,000 = 1.342 seconds
    //   Frequency ≈ 0.745 Hz — close enough to 1 Hz for a visual heartbeat.
    //
    // Why not exactly 1 Hz?  We'd need a 50,000,000 counter with wrap logic.
    // Using a power-of-two counter is simpler (one adder, no comparator) and
    // the exact frequency doesn't matter — it just needs to visibly blink.
    // =========================================================================
    reg [26:0] heartbeat_cnt;

    always @(posedge clk) begin
        if (rst)
            heartbeat_cnt <= 27'd0;
        else
            heartbeat_cnt <= heartbeat_cnt + 1'b1;
    end

    assign led[3] = heartbeat_cnt[26];

endmodule
