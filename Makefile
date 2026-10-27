# ============================================================================
#  Thin wrapper around scripts/build.ps1 and scripts/prog.ps1.
#
#  There is deliberately no build logic here.  The RTL file list lives in
#  fpga.yaml and is read by scripts/sources.ps1; scripts/build.ps1 turns it
#  into a Gowin EDA (gw_sh) run.  Nothing here is needed: the scripts run as
#  they are, and make is only shorthand for them.
# ============================================================================

# The recipes below are written for cmd.exe -- `if exist` and `rmdir /s /q` in
# clean are its syntax -- and GNU make silently switches to POSIX sh if an
# sh.exe is on PATH, which Git Bash or MSYS2 would add.  Pin it, so what a
# recipe means cannot change because a shell got installed.
SHELL := cmd.exe

PWSH  = C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass
BUILD = scripts/build.ps1
PROG  = scripts/prog.ps1
SIM   = sim/run.ps1
ROM   = scripts/fetch-rom.ps1

all: build

# Synthesis, place & route and the bitstream: build/bitstream/<name>.fs
build:
	$(PWSH) -File $(BUILD)

# Load into SRAM: fast, lost on power cycle.
load:
	$(PWSH) -File $(PROG)

# Write the external config flash: slower, survives power cycles.
flash:
	$(PWSH) -File $(PROG) -Flash

# Fetch the ZX Spectrum 48K ROM (not distributable from this repo; see
# roms/README.md).  build and sim need it.
rom:
	$(PWSH) -File $(ROM)

# Testbenches (iverilog).  tb_zx and tb_ddr need the ROM / the DDR3 model.
sim:
	$(PWSH) -File $(SIM)

# Remove everything the tools generate.
clean:
	if exist build rmdir /s /q build
	if exist impl rmdir /s /q impl

.PHONY: all build load flash rom sim clean
