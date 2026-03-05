#=============================================================================
# Script:  uart_controller.tcl
# Project: UART Controller — Arty A7-100T
#
# Purpose: Build the entire FPGA design from source files to bitstream in
#          one command.  No Vivado GUI project needed, this script is the
#          project definition.
#
# Usage (from the repo root directory):
#   vivado -mode batch -source vivado/uart_controller.tcl
#
# What it does:
#   1. Reads all Verilog source files and constraints
#   2. Synthesizes the design (converts Verilog → logic gates)
#   3. Implements the design (optimizes, places gates, routes wires)
#   4. Generates timing and utilization reports
#   5. Writes the bitstream (.bit file to program the FPGA)
#
# Output files:
#   vivado/reports/timing_summary.rpt    — Did we meet 100 MHz timing?
#   vivado/reports/utilization.rpt       — How much of the FPGA did we use?
#   vivado/reports/utilization_hier.rpt  — Per-module resource breakdown
#   vivado/reports/drc.rpt               — Design rule check results
#   vivado/output/uart_top.bit           — The bitstream to program the FPGA
#   vivado/output/uart_top.dcp           — Design checkpoint (for later debug)
#
# Non-project mode vs. project mode:
#   Vivado has two flows:
#
#   PROJECT MODE (.xpr file):
#     - Creates a binary project file that tracks everything
#     - The .xpr file is not human-readable and doesn't version-control well
#     - Great for interactive GUI work, bad for reproducible builds
#
#   NON-PROJECT MODE (this script):
#     - No .xpr file — the TCL script defines everything
#     - Fully reproducible: same script + same sources = same bitstream
#     - Version-controllable: TCL is plain text, diffs are meaningful
#     - Industry standard for CI/CD and automated builds
#     - Trade-off: no GUI state saved (open the .dcp checkpoint instead)
#
#   We use non-project mode because this is a learning project and we want
#   to understand exactly what Vivado does at each step.
#=============================================================================


#=============================================================================
# Configuration
#
# All paths are relative to where Vivado is launched (the repo root).
# We need to hange these if we reorganize the directory structure.
#=============================================================================

# FPGA part number — must match the physical chip on our board exactly.
#
#   xc7a100t  = Artix-7, 100T variant (101,440 logic cells)
#   csg324    = 324-pin CSG package (the BGA package on the Arty)
#   -1        = Speed grade 1 (slowest, but cheapest — what the Arty ships)
#
# Get this wrong and Vivado will either refuse to synthesize or produce
# a bitstream that doesn't match the chip's pin layout.
set part "xc7a100tcsg324-1"

# Top-level module — the one that has ports matching the XDC constraints.
# Vivado needs to know which module is the "entry point" for the design.
set top_module "uart_top"

# Source directories (relative to repo root)
set src_dir    "src"
set constr_dir "constraints"

# Output directories — created automatically if they don't exist.
# These are in .gitignore — generated files should never be committed.
set report_dir "vivado/reports"
set output_dir "vivado/output"


#=============================================================================
# Create output directories
#
# Vivado won't create directories for us — if the -file path doesn't
# exist, the command fails silently or errors out.
#=============================================================================
file mkdir $report_dir
file mkdir $output_dir


#=============================================================================
# Step 1: Read source files
#
# read_verilog loads Verilog files into Vivado's in-memory design.
# read_xdc loads timing constraints and pin assignments.
#
# We read each file explicitly rather than using glob (*.v) so the build
# is deterministic — the order files are read can occasionally matter for
# `define macros, and glob order depends on the filesystem.
#
# In non-project mode, files are read into memory.  There's no "project"
# on disk — everything lives in RAM until we write a checkpoint or report.
#=============================================================================
puts "================================================================"
puts "  UART Controller — Vivado Build Script"
puts "  Part: $part"
puts "  Top:  $top_module"
puts "================================================================"
puts ""
puts "--- Step 1: Reading source files ---"

# Core modules
read_verilog $src_dir/baud_gen.v
read_verilog $src_dir/uart_tx.v
read_verilog $src_dir/uart_rx.v
read_verilog $src_dir/led_pulse.v
read_verilog $src_dir/uart_top.v

# Constraints (pin assignments + clock definition)
read_xdc $constr_dir/arty_a7.xdc

puts "  All sources read successfully."
puts ""


#=============================================================================
# Step 2: Synthesis
#
# synth_design converts our behavioral Verilog (if/else, case, always
# blocks) into a netlist of logic primitives (LUTs, flip-flops, carry
# chains) that exist on the physical FPGA.
#
# This is the "compilation" step.  After synthesis, our design is a
# graph of interconnected logic elements, but they haven't been assigned
# to specific locations on the chip yet.
#
# Key flags:
#   -top uart_top     — which module is the entry point
#   -part xc7a100t... — which chip to target (determines available resources)
#
# Vivado's synthesis log will show:
#   - FSM encoding decisions (it re-encodes our 2-bit states to one-hot)
#   - Resource estimates (LUTs, FFs, etc.)
#   - Any warnings about inferred latches, unconnected ports, etc.
#
# After synthesis, we generate an early utilization estimate.  These
# numbers aren't final (placement and routing change them slightly),
# but they give a quick sanity check.
#=============================================================================
puts "--- Step 2: Synthesis ---"

synth_design -top $top_module -part $part

puts "  Synthesis complete."

# Post-synthesis utilization — early estimate, useful for quick checks.
# The final numbers come after routing (Step 3).
report_utilization -file $report_dir/synth_utilization.rpt
puts "  Post-synthesis utilization saved to $report_dir/synth_utilization.rpt"
puts ""


#=============================================================================
# Step 3: Implementation (Optimize → Place → Route)
#
# Implementation takes the synthesized netlist and maps it onto the
# physical FPGA.  Three sub-steps:
#
# opt_design — Logic optimization
#   Simplifies the netlist: removes redundant logic, merges equivalent
#   nets, propagates constants.  Like a compiler optimization pass.
#   Usually reduces LUT count by 5-20%.
#
# place_design — Placement
#   Assigns each logic element to a specific physical location (slice)
#   on the FPGA die.  The placer tries to minimize wire length — logic
#   that talks to each other gets placed nearby.
#
#   For our tiny design, placement is trivial — everything fits in a
#   small corner of the chip.  For large designs, placement is THE
#   critical step that determines whether timing is met.
#
# route_design — Routing
#   Connects the placed elements with actual metal wires on the FPGA.
#   The router picks which switch-matrix paths to use.  After routing,
#   we know the EXACT wire delays, so timing analysis is accurate.
#
#   This is the only step that gives us real timing numbers.  Post-
#   synthesis timing uses estimated delays; post-route timing uses
#   actual delays from the physical wire paths.
#=============================================================================
puts "--- Step 3: Implementation ---"

puts "  Running opt_design (logic optimization)..."
opt_design

puts "  Running place_design (physical placement)..."
place_design

puts "  Running route_design (wire routing)..."
route_design

puts "  Implementation complete."
puts ""


#=============================================================================
# Step 4: Reports
#
# Now that the design is fully routed, we generate the definitive reports.
# These use real wire delays from the physical routing — the most accurate
# numbers Vivado can give us.
#
# TIMING SUMMARY — The Most Important Report
#
#   This tells us whether our design actually works at 100 MHz.
#   Look for three numbers:
#
#   WNS (Worst Negative Slack):
#     The timing margin on the slowest path in the design.
#     Positive = PASS.  The path finishes before the deadline.
#     Negative = FAIL.  The path is too slow for 100 MHz.
#
#     Example: WNS = +6.5 ns means the slowest path uses only 3.5 ns
#     of the 10 ns clock period.  Plenty of margin.
#
#   TNS (Total Negative Slack):
#     Sum of all timing violations.  Should be 0.000 ns (no violations).
#     If WNS is positive, TNS is automatically zero.
#
#   WHS (Worst Hold Slack):
#     Ensures data doesn't change too quickly after a clock edge.
#     Should be positive.  Hold violations are rare in well-designed
#     single-clock-domain circuits like ours.
#
#   WHAT IS "SLACK"?
#     Slack = Required time − Arrival time
#
#     "Required time" is set by our clock constraint (10 ns for 100 MHz).
#     "Arrival time" is how long the signal actually takes through the logic
#     and wires.  If arrival < required, we have positive slack (margin).
#
#   For our design: we expect WNS around +5 to +8 ns.  The logic is simple
#   (counters, shift registers, comparators) and the paths are short.
#   We're using a tiny fraction of the chip, so routing delays are minimal.
#
# UTILIZATION — How Much FPGA Did We Use?
#
#   Shows resource consumption.  For our design on the XC7A100T:
#     LUTs:       ~300-500 out of 63,400  (<1%)
#     Flip-Flops: ~300-400 out of 126,800 (<1%)
#     BRAM:       0 out of 135 blocks     (we don't use memory)
#     DSP:        0 out of 240 slices     (we don't do math)
#     IO:         11 out of 210 pins      (~5%)
#
#   The hierarchical report (-hierarchical) breaks this down per module.
#   we can see exactly how many LUTs each uart_tx, uart_rx, baud_gen,
#   and led_pulse instance uses.  This is educational — we learn the
#   "cost" of each design choice in hardware resources.
#
# DRC — Design Rule Check
#
#   Vivado's lint for hardware.  Checks for:
#     - Undriven or unconnected pins
#     - Missing I/O constraints
#     - Clock topology issues
#     - Missing input/output delay constraints (expected — we don't
#       have inter-FPGA timing requirements)
#
#   Warnings are normal.  Critical violations (CRITICAL WARNING) should
#   be investigated — they can cause hardware failures.
#=============================================================================
puts "--- Step 4: Generating reports ---"

# Timing — the definitive answer to "does it work at 100 MHz?"
report_timing_summary \
    -delay_type min_max \
    -report_unconstrained \
    -check_timing_verbose \
    -max_paths 10 \
    -input_pins \
    -file $report_dir/timing_summary.rpt

puts "  Timing summary   → $report_dir/timing_summary.rpt"

# Utilization — flat summary
report_utilization -file $report_dir/utilization.rpt
puts "  Utilization       → $report_dir/utilization.rpt"

# Utilization — per-module breakdown
report_utilization -hierarchical -file $report_dir/utilization_hier.rpt
puts "  Utilization (hier)→ $report_dir/utilization_hier.rpt"

# Design Rule Check
report_drc -file $report_dir/drc.rpt
puts "  DRC               → $report_dir/drc.rpt"

puts ""


#=============================================================================
# Step 5: Write bitstream and checkpoint
#
# write_bitstream generates the .bit file — the binary blob that
# configures the FPGA.  This is what we download to the chip via
# Vivado Hardware Manager or the Arty's USB-JTAG interface.
#
# The -force flag overwrites any existing .bit file without asking.
#
# write_checkpoint saves the complete design state (netlist + placement +
# routing) to a .dcp file.  we can open this later in the Vivado GUI
# to inspect the design, run additional reports, or set up ILA debug
# without re-running the entire build.  Think of it as a "save game"
# for the design.
#=============================================================================
puts "--- Step 5: Writing bitstream ---"

write_checkpoint -force $output_dir/$top_module.dcp
puts "  Checkpoint saved  → $output_dir/$top_module.dcp"

write_bitstream -force $output_dir/$top_module.bit
puts "  Bitstream written → $output_dir/$top_module.bit"

puts ""
puts "================================================================"
puts "  Build complete!"
puts ""
puts "  Next steps:"
puts "    1. Check timing:  Open $report_dir/timing_summary.rpt"
puts "       Look for WNS > 0 (positive slack = timing met)"
puts ""
puts "    2. Check resources: Open $report_dir/utilization.rpt"
puts "       Expect <1% LUT usage for this small design"
puts ""
puts "    3. Program the FPGA:"
puts "       Open Vivado Hardware Manager → Auto Connect →"
puts "       Program Device → Select $output_dir/$top_module.bit"
puts ""
puts "    4. Or open the checkpoint for GUI inspection:"
puts "       vivado $output_dir/$top_module.dcp"
puts "================================================================"
