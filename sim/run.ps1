# ============================================================================
#  sim/run.ps1 -- build and run every testbench with iverilog.
#
#  Run from anywhere; tools run from the repo root so `include and $readmemh
#  paths resolve.  tb_zx needs the ROM image in roms/ (make rom).
#
#  The RTL file list is fpga.yaml, read through scripts/sources.ps1.
#
#    sim\run.ps1                 every testbench
#    sim\run.ps1 -Target tb_zx   one testbench
# ============================================================================
param(
    [string]$Target = '',
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
. (Join-Path $root 'scripts\toolchain.ps1')

New-Item -ItemType Directory -Force -Path (Join-Path $root 'build') | Out-Null

function Run-Tb {
    param(
        [string]$Name,
        [string[]]$Files,
        [string]$Gen = '2012',
        [string[]]$Defines = @(),
        [string[]]$PlusArgs = @()
    )
    if ($Target -and $Name -ne $Target) { return }
    Write-Host "=== $Name ==="
    # On Windows iverilog -o writes a vvp script whatever the extension is, so
    # name the output .vvp and run it through vvp explicitly.
    $outVvp = Join-Path $root "build\$Name.vvp"
    $tbFile = Join-Path $root "sim\$Name.v"

    # The array brackets matter: "-g$Gen" + @() would join the two into one
    # string, and iverilog would read "-g2005-o" as the generation.
    $iverilogArgs = @("-g$Gen") + @($Defines) + @('-o', $outVvp, $tbFile) + $Files
    Invoke-Tool 'iverilog' $iverilogArgs

    $logFile = Join-Path $root "build\$Name.log"
    $vvp = if ($OssCadBin) { Join-Path $OssCadBin 'vvp.exe' } else { 'vvp' }

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $vvp $outVvp $PlusArgs > $logFile 2>&1
    } finally {
        $ErrorActionPreference = $prevEAP
    }

    Get-Content $logFile | Write-Host
    if ($LASTEXITCODE -ne 0) {
        throw "FAILED: $Name exited with code $LASTEXITCODE"
    }

    $logContent = Get-Content $logFile -Raw
    if ($logContent -match '(?m)^FAIL' -or $logContent -notmatch 'PASS') {
        throw "FAILED: $Name did not report PASS"
    }
    Write-Host ""
}

# Guard against this list drifting from fpga.yaml (the same files the build
# compiles).
$allSources = & (Join-Path $root 'scripts\sources.ps1')
$core = @('src/zx_core.v', 'src/zx_snap.v', 'src/zx_scr_cap.v', 'src/zx_video.v', 'src/zx_input.v') +
        ($allSources | Where-Object { $_ -like 'src/z80/*' })
$hdmi = $allSources | Where-Object { $_ -like 'src/hdmi/*' }

# The ROM is copyright and is not in the repo; tb_zx needs it (make rom).
if (-not (Test-Path (Join-Path $root 'roms\zx48.hex'))) {
    if ($Target -and $Target -ne 'tb_zx') {
        Write-Host "== skipping tb_zx: no roms\zx48.hex (make rom)"
    } else {
        & (Join-Path $root 'scripts\fetch-rom.ps1')
        if ($LASTEXITCODE -ne 0) { throw "tb_zx needs roms\zx48.hex" }
    }
}

# The HDMI stack's own suite is Verilog-2005 (as in the sibling project);
# iverilog -g2012 crashes on tb_data_island.
Run-Tb 'tb_tmds_encoder' @('src/hdmi/hdmi_tmds_encoder.v') -Gen '2005'
Run-Tb 'tb_packet_ecc'   @('src/hdmi/hdmi_packet_ecc.v') -Gen '2005'
Run-Tb 'tb_packets'      @('src/hdmi/hdmi_packets.v') -Gen '2005'
Run-Tb 'tb_data_island'  @('src/hdmi/hdmi_data_island.v', 'src/hdmi/hdmi_packet_ecc.v', 'src/hdmi/hdmi_tmds_encoder.v') -Gen '2005'
Run-Tb 'tb_input'        @('src/zx_input.v')
Run-Tb 'tb_ddr'          @('src/zx_ddr.v', 'sim/models/ddr3_model.v')
Run-Tb 'tb_video'        @('src/zx_video.v')
Run-Tb 'tb_tv_fx'        @('src/zx_tv_fx.v')
Run-Tb 'tb_tape'         @('src/tap_player.v')
Run-Tb 'tb_scr_cap'      @('src/zx_scr_cap.v')
Run-Tb 'tb_raw_bridge'   @('src/sd/sd_raw_bridge.v')
Run-Tb 'tb_mem_min'      @('src/zx_tape_mem.v')
Run-Tb 'tb_tape_mem'     @('src/zx_tape_mem.v', 'src/zx_ddr.v', 'sim/models/ddr3_model.v')
Run-Tb 'tb_tape_deck'    @('src/zx_tape_mem.v', 'src/tap_player.v', 'src/zx_ddr.v', 'sim/models/ddr3_model.v')

if (Test-Path (Join-Path $root 'roms\zx48.hex')) {
    # +fast=2 runs the CPU at 27 MHz instead of 3.5: the ROM is
    # speed-independent (the ULA's 50 Hz interrupt is a fixed clock count), so
    # the boot takes ~1/8 of the simulated time and the suite stays usable.
    # It is also the memory path's minimum margin (T1->T3 is then exactly the
    # two clocks a registered BSRAM read needs), so it is the stricter run.
    # The ROM reaches the editor by ~240 ms of machine time; 300 leaves the
    # margin for the frame capture.  Run tb_zx with +fast=0 +ms=1800 for the
    # honest full-rate boot.
    Run-Tb 'tb_zx' $core -PlusArgs @('+fast=2', '+ms=300')

    # tb_type types the LOAD "" macro into the real ROM with the page's
    # pacing (typeText) and checks the editor line plus the tape_load pulse;
    # +rpt=140 mirrors the page's repeatGapMs default.
    Run-Tb 'tb_type' $core -PlusArgs @('+fast=2', '+quiet=1', '+rpt=140')
} else {
    if ($Target -eq 'tb_zx' -or $Target -eq 'tb_top') { throw "tb_zx/tb_top need roms\zx48.hex (make rom)" }
}

# The whole top level, with the Gowin primitives modelled and the DDR3 IP
# stood in for: proves the real file list elaborates and the HDMI pipeline
# produces a locked raster.  It contains the ROM, so it needs the hex too.
if (Test-Path (Join-Path $root 'roms\zx48.hex')) {
    $topSources = $allSources | Where-Object { $_ -notlike 'src/ddr3_memory_interface/*' }
    Run-Tb 'tb_top' (@('sim/models/gowin_prims.v', 'sim/models/ddr3_model.v') + $topSources)
}

Write-Host "all testbenches passed"
