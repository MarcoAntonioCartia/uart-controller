# uart-controller

Serial communication from scratch — UART TX/RX on an Arty A7-100T.

This is project 1.1 from the FPGA series. The goal is a clean,
well-documented UART implementation that verifies the full Vivado workflow:
synthesis, implementation, timing analysis, and hardware-in-the-loop testing.

No third-party IP cores. No shortcuts. Just state machines, timing math, and a
blinking LED to prove it works.

---

## What's in here

```
uart-controller/
├── src/                    # Verilog source
│   ├── baud_gen.v          # Clock divider — 100 MHz → 115200 baud
│   ├── uart_tx.v           # Transmit state machine
│   └── uart_rx.v           # Receive state machine with oversampling
├── tb/
│   └── uart_tb.v           # Testbench — loopback + edge cases
├── constraints/
│   └── arty_a7.xdc         # Pin assignments for Arty A7-100T
├── docs/
│   └── block_diagram.png   # Architecture overview
└── vivado/
    └── uart_controller.tcl # Project rebuild script
```

The Vivado project folder is not committed. Run the TCL script to regenerate it.

---

## Specs

| Parameter       | Value                        |
|-----------------|------------------------------|
| Target board    | Arty A7-100T                 |
| FPGA            | Xilinx Artix-7 XC7A100T      |
| System clock    | 100 MHz                      |
| Baud rate       | 115200                       |
| Data format     | 8N1 (8 bits, no parity, 1 stop) |
| Language        | Verilog                      |
| Toolchain       | Vivado 2024.x                |

---

## How to build

**Recreate the Vivado project:**
```bash
vivado -mode batch -source vivado/uart_controller.tcl
```

**Run the testbench (Icarus Verilog):**
```bash
iverilog -o sim tb/uart_tb.v src/baud_gen.v src/uart_tx.v src/uart_rx.v
vvp sim
```

---

## Hardware setup

The demo runs between the Arty A7 and a Raspberry Pi Pico over UART. The Pico
acts as a serial terminal — it sends a string, the FPGA echoes it back, and
onboard LEDs confirm received bytes.

Wiring:

```
Arty TX  ──────────────►  Pico RX (GP1)
Arty RX  ◄──────────────  Pico TX (GP0)
Arty GND ────────────────  Pico GND
```

Use Vivado ILA for waveform capture in hardware. No oscilloscope needed.

---

## Status

- [ ] Baud rate generator
- [ ] UART TX
- [ ] UART RX
- [ ] Testbench
- [ ] Constraints file
- [ ] ILA integration
- [ ] Timing + utilization reports
- [ ] README block diagram

---

## License

MIT. Do whatever you want with it.
