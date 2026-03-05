# uart-controller

Serial communication from scratch — UART TX/RX on an Arty A7-100T.

This is project 1.1 from the FPGA series. The goal is a clean,
well-documented UART implementation that verifies the full Vivado workflow:
synthesis, implementation, timing analysis, and hardware-in-the-loop testing.

No third-party IP cores. No shortcuts. Just state machines, timing math, and a
blinking LED to prove it works.

---

## Architecture

The FPGA runs two independent UART echo channels. Each channel receives a byte
and immediately transmits it back to the sender. Four LEDs show activity.

```
                          uart_top (FPGA — Arty A7-100T)
    ┌─────────────────────────────────────────────────────────────────────┐
    │                                                                     │
    │   USB Channel                        Pmod Channel                   │
    │   ───────────                        ────────────                   │
    │                                                                     │
    │   ┌──────────┐    ┌──────────┐       ┌──────────┐    ┌──────────┐  │
    │   │ baud_gen │    │ baud_gen │       │ baud_gen │    │ baud_gen │  │
    │   │ (1x TX)  │    │ (16x RX) │       │ (1x TX)  │    │ (16x RX) │  │
    │   └────┬─────┘    └────┬─────┘       └────┬─────┘    └────┬─────┘  │
    │        │               │                   │               │        │
    │   ┌────▼─────┐    ┌────▼─────┐       ┌────▼─────┐    ┌────▼─────┐  │
    │   │ uart_tx  │    │ uart_rx  │       │ uart_tx  │    │ uart_rx  │  │
    │   │          │    │  2-stage │       │          │    │  2-stage │  │
    │   │  shift   │◄───│  sync +  │       │  shift   │◄───│  sync +  │  │
    │   │  reg out │echo│ 16x over │       │  reg out │echo│ 16x over │  │
    │   └────┬─────┘    └────┬─────┘       └────┬─────┘    └────┬─────┘  │
    │        │               │                   │               │        │
    ├────────┼───────────────┼───────────────────┼───────────────┼────────┤
    │   usb_tx (D10)    usb_rx (A9)        pmod_tx (G13)   pmod_rx (B11) │
    └────────┼───────────────┼───────────────────┼───────────────┼────────┘
             │               │                   │               │
             ▼               │                   ▼               │
        ┌─────────┐          │              ┌─────────┐          │
        │  FTDI   │          │              │  Pico   │          │
        │  chip   │──────────┘              │  GP1/   │──────────┘
        └────┬────┘                         │  GP0    │
             │ USB                          └─────────┘
             ▼
        ┌─────────┐
        │   PC    │
        │terminal │
        └─────────┘

    LEDs (active-high, accent by led_pulse stretchers):
      LED[0] = RX activity     (H5)    LED[2] = Framing error  (T9)
      LED[1] = TX activity     (J5)    LED[3] = Heartbeat ~1Hz (T10)
```

Each `baud_gen` instance produces tick pulses from the 100 MHz system clock.
The TX path uses a 1x tick (every 868 clocks = 115200 Hz). The RX path uses
a 16x tick (every 54 clocks) for oversampling — we sample each bit 16 times
to find its center, rejecting noise and glitches.

The echo wiring is direct: `rx_done` drives `tx_start`, `rx_data` drives
`tx_data`. No FIFO needed for single-byte echo.

---

## What's in here

```
uart-controller/
├── src/
│   ├── baud_gen.v          # Clock divider — 100 MHz → 115200 baud ticks
│   ├── uart_tx.v           # Transmit state machine (8N1, LSB-first)
│   ├── uart_rx.v           # Receive with 2-stage sync + 16x oversampling
│   ├── led_pulse.v         # Pulse stretcher — 10 ns event → 10 ms LED blink
│   └── uart_top.v          # Top-level: dual-channel echo + ILA debug probes
├── tb/
│   └── uart_tb.v           # Loopback testbench — 8 test cases
├── constraints/
│   └── arty_a7.xdc         # Pin assignments for Arty A7-100T
├── docs/
│   └── .gitkeep
└── vivado/
    └── uart_controller.tcl # Non-project-mode build: source → bitstream
```

The Vivado project folder is not committed. Run the TCL script to regenerate it.

---

## Specs

| Parameter       | Value                            |
|-----------------|----------------------------------|
| Target board    | Arty A7-100T                     |
| FPGA            | Xilinx Artix-7 XC7A100TCSG324-1 |
| System clock    | 100 MHz                          |
| Baud rate       | 115200                           |
| Data format     | 8N1 (8 bits, no parity, 1 stop)  |
| Language        | Verilog (not SystemVerilog)       |
| Toolchain       | Vivado 2024.x                    |

---

## How to build

**Synthesize and generate bitstream (requires Vivado):**
```powershell
vivado -mode batch -source vivado/uart_controller.tcl
```

This runs synthesis, implementation, and generates:
- `vivado/reports/timing_summary.rpt` — timing analysis (WNS should be positive)
- `vivado/reports/utilization.rpt` — resource usage (expect <1% of LUTs)
- `vivado/output/uart_top.bit` — bitstream to program the FPGA

**Run the testbench (requires Icarus Verilog):**
```powershell
iverilog -o sim tb/uart_tb.v src/baud_gen.v src/uart_tx.v src/uart_rx.v
vvp sim
```

Expected output: `ALL TESTS PASSED (8/8)`.

---

## Hardware setup

### Channel 1 — PC via USB-UART bridge

No external wiring needed. The Arty's on-board FTDI chip connects the FPGA
to the PC over USB. Open any serial terminal (PuTTY, Tera Term, minicom)
at 115200 baud, 8N1. Type characters — they echo back.

### Channel 2 — Raspberry Pi Pico via Pmod JA

```
Arty JA Pin 1 (G13, pmod_tx) ──────► Pico GP1 (UART0 RX)
Arty JA Pin 2 (B11, pmod_rx) ◄────── Pico GP0 (UART0 TX)
Arty JA Pin 5 (GND)          ──────── Pico GND
```

Both devices run at 3.3V — no level shifter needed. Configure the Pico's
UART0 at 115200 baud and send bytes. The FPGA echoes them back.

### LEDs

| LED | Pin | Function |
|-----|-----|----------|
| LD4 | H5  | RX activity — blinks when a byte is received |
| LD5 | J5  | TX activity — blinks when a byte is sent |
| LD6 | T9  | Framing error — blinks on bad stop bit |
| LD7 | T10 | Heartbeat — ~0.75 Hz toggle (board is alive) |

### ILA debug

We use Vivado's Integrated Logic Analyzer instead of an oscilloscope.
Key signals are marked with `(* mark_debug = "true" *)` in `uart_top.v`.
After synthesis, use Vivado's Set Up Debug wizard to configure the ILA
core, then capture real waveforms from the running FPGA over JTAG.

---

## Status

- [x] Baud rate generator
- [x] UART TX state machine
- [x] UART RX state machine
- [x] Testbench (8/8 passing)
- [x] Constraints file (.xdc)
- [x] Top-level module + ILA integration
- [x] TCL build script + timing/utilization reports
- [x] README block diagram

---

## License

MIT. Do whatever you want with it.
