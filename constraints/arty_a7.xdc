## =============================================================================
## Constraints file for the UART Controller project
## Board: Digilent Arty A7-100T (Rev. D / Rev. E)
## FPGA:  Xilinx Artix-7 XC7A100TCSG324-1
##
## Pin assignments sourced from:
##   https://github.com/Digilent/digilent-xdc/blob/master/Arty-A7-100-Master.xdc
##   https://digilent.com/reference/programmable-logic/arty-a7/reference-manual
##
## All I/O banks on the Arty A7 are powered at 3.3V → LVCMOS33 everywhere.
##
## Only pins used by this design are constrained.  Constraining unused pins
## causes "unconnected port" warnings in Vivado.  Unused resources are listed
## at the bottom (commented out) for future reference.
## =============================================================================


## =============================================================================
## System Clock — 100 MHz oscillator
##
## Pin E3 connects to the on-board 100 MHz crystal oscillator.
## The create_clock constraint tells Vivado's timing analyzer the clock
## frequency.  Without it, Vivado skips all setup/hold timing checks and
## we could get mysterious hardware failures.
##
## Period = 10.00 ns = 100 MHz.  Waveform {0 5} means: rise at 0 ns, fall
## at 5 ns (50% duty cycle).
## =============================================================================
set_property -dict { PACKAGE_PIN E3    IOSTANDARD LVCMOS33 } [get_ports { clk }];
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports { clk }];


## =============================================================================
## Reset — Push button BTN0
##
## The Arty A7 has 4 push buttons (active-high: pressed = 1, released = 0).
## BTN0 (pin D9) drives our active-high rst signal directly — no inverter
## needed.  Press the button to reset all state machines to IDLE.
## =============================================================================
set_property -dict { PACKAGE_PIN D9    IOSTANDARD LVCMOS33 } [get_ports { rst }];


## =============================================================================
## USB-UART Bridge — PC communication via on-board FTDI chip
##
## IMPORTANT — the Digilent master XDC names these from the FTDI chip's
## perspective, which is backwards from the FPGA's perspective:
##
##   Digilent name     Pin    FPGA direction    Our name
##   ─────────────     ───    ──────────────    ────────
##   uart_txd_in       D10    OUTPUT            usb_tx   (FPGA sends TO PC)
##   uart_rxd_out      A9     INPUT             usb_rx   (FPGA receives FROM PC)
##
## "uart_txd_in" means "TXD input to the FTDI chip" = output from the FPGA.
## We use FPGA-perspective names to avoid confusion.
##
## Data path:  FPGA usb_tx (D10) → FTDI chip → USB cable → PC terminal
##             PC terminal → USB cable → FTDI chip → FPGA usb_rx (A9)
## =============================================================================
set_property -dict { PACKAGE_PIN D10   IOSTANDARD LVCMOS33 } [get_ports { usb_tx }];
set_property -dict { PACKAGE_PIN A9    IOSTANDARD LVCMOS33 } [get_ports { usb_rx }];


## =============================================================================
## Pmod Header JA — Raspberry Pi Pico UART connection
##
## We use two pins from Pmod JA for a second UART channel to the Pico.
## JA is on the board edge, easy to reach with jumper wires.
##
## Pmod JA pinout (top row):
##   Pin 1 = JA[0] = G13    ← FPGA TX to Pico
##   Pin 2 = JA[1] = B11    ← FPGA RX from Pico
##   Pin 3 = JA[2] = A11    (unused)
##   Pin 4 = JA[3] = D12    (unused)
##   Pin 5 = GND
##   Pin 6 = VCC (3.3V)
##
## Wiring to Raspberry Pi Pico:
##
##   Arty JA Pin 1 (G13, pmod_tx) ──────► Pico GP1 (UART0 RX)
##   Arty JA Pin 2 (B11, pmod_rx) ◄────── Pico GP0 (UART0 TX)
##   Arty JA Pin 5 (GND)          ──────── Pico GND
##
## NOTE: Both the Arty (3.3V I/O) and the Pico (3.3V I/O) use the same
## voltage level.  No level shifter needed.
## =============================================================================
set_property -dict { PACKAGE_PIN G13   IOSTANDARD LVCMOS33 } [get_ports { pmod_tx }];
set_property -dict { PACKAGE_PIN B11   IOSTANDARD LVCMOS33 } [get_ports { pmod_rx }];


## =============================================================================
## Status LEDs — active-high (drive 1 to light up)
##
## The Arty A7 has 4 green LEDs (LD4–LD7) directly driven by FPGA pins.
## (LD0–LD3 are RGB LEDs with separate R/G/B pins — not used here.)
##
##   LED[0] (H5)  = RX activity    — pulses when a byte is received (rx_done)
##   LED[1] (J5)  = TX activity    — pulses when a byte is sent (tx_done)
##   LED[2] (T9)  = Framing error  — pulses on rx_err (bad stop bit)
##   LED[3] (T10) = Reserved       — active-low for heartbeat or unused
## =============================================================================
set_property -dict { PACKAGE_PIN H5    IOSTANDARD LVCMOS33 } [get_ports { led[0] }];
set_property -dict { PACKAGE_PIN J5    IOSTANDARD LVCMOS33 } [get_ports { led[1] }];
set_property -dict { PACKAGE_PIN T9    IOSTANDARD LVCMOS33 } [get_ports { led[2] }];
set_property -dict { PACKAGE_PIN T10   IOSTANDARD LVCMOS33 } [get_ports { led[3] }];


## =============================================================================
## Unused resources — commented out for future reference.
## Uncomment and rename ports as needed.
## =============================================================================

## Switches
# set_property -dict { PACKAGE_PIN A8    IOSTANDARD LVCMOS33 } [get_ports { sw[0] }];
# set_property -dict { PACKAGE_PIN C11   IOSTANDARD LVCMOS33 } [get_ports { sw[1] }];
# set_property -dict { PACKAGE_PIN C10   IOSTANDARD LVCMOS33 } [get_ports { sw[2] }];
# set_property -dict { PACKAGE_PIN A10   IOSTANDARD LVCMOS33 } [get_ports { sw[3] }];

## Buttons (BTN1–BTN3, BTN0 used as reset above)
# set_property -dict { PACKAGE_PIN C9    IOSTANDARD LVCMOS33 } [get_ports { btn[1] }];
# set_property -dict { PACKAGE_PIN B9    IOSTANDARD LVCMOS33 } [get_ports { btn[2] }];
# set_property -dict { PACKAGE_PIN B8    IOSTANDARD LVCMOS33 } [get_ports { btn[3] }];

## Pmod JA — remaining pins (JA[2]–JA[7])
# set_property -dict { PACKAGE_PIN A11   IOSTANDARD LVCMOS33 } [get_ports { ja[2] }];
# set_property -dict { PACKAGE_PIN D12   IOSTANDARD LVCMOS33 } [get_ports { ja[3] }];
# set_property -dict { PACKAGE_PIN D13   IOSTANDARD LVCMOS33 } [get_ports { ja[4] }];
# set_property -dict { PACKAGE_PIN B18   IOSTANDARD LVCMOS33 } [get_ports { ja[5] }];
# set_property -dict { PACKAGE_PIN A18   IOSTANDARD LVCMOS33 } [get_ports { ja[6] }];
# set_property -dict { PACKAGE_PIN K16   IOSTANDARD LVCMOS33 } [get_ports { ja[7] }];

## Pmod JB
# set_property -dict { PACKAGE_PIN E15   IOSTANDARD LVCMOS33 } [get_ports { jb[0] }];
# set_property -dict { PACKAGE_PIN E16   IOSTANDARD LVCMOS33 } [get_ports { jb[1] }];
# set_property -dict { PACKAGE_PIN D15   IOSTANDARD LVCMOS33 } [get_ports { jb[2] }];
# set_property -dict { PACKAGE_PIN C15   IOSTANDARD LVCMOS33 } [get_ports { jb[3] }];
# set_property -dict { PACKAGE_PIN J17   IOSTANDARD LVCMOS33 } [get_ports { jb[4] }];
# set_property -dict { PACKAGE_PIN J18   IOSTANDARD LVCMOS33 } [get_ports { jb[5] }];
# set_property -dict { PACKAGE_PIN K15   IOSTANDARD LVCMOS33 } [get_ports { jb[6] }];
# set_property -dict { PACKAGE_PIN J15   IOSTANDARD LVCMOS33 } [get_ports { jb[7] }];
