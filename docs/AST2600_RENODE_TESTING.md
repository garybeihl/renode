# AST2600 Renode Testing Guide

## Overview

This document describes how to build, run, and extend the Renode AST2600 test suite.
The platform models an Aspeed AST2600 BMC SoC with the following Tier 1 peripherals:

| Peripheral | Address      | Description |
|------------|-------------|-------------|
| Boot ROM   | 0x00000000  | 128KB flash alias at reset |
| SRAM       | 0x10000000  | 90KB internal SRAM |
| FMC        | 0x1E620000  | SPI flash controller with DMA |
| Flash      | 0x20000000  | 128MB memory-mapped flash window |
| SDMC       | 0x1E6E0000  | DRAM memory controller |
| SCU        | 0x1E6E2000  | System Configuration Unit |
| Timer      | 0x1E782000  | 8-channel timer |
| UART5      | 0x1E784000  | NS16550 serial console |
| WDT1-4     | 0x1E785000+ | 4 watchdog timers |
| DRAM       | 0x80000000  | 1 GiB DDR4 |
| GIC        | 0x40461000  | ARM GICv2 interrupt controller |

## Prerequisites

- .NET 8.0 SDK (for building Renode)
- Python 3.8+ with `robotframework` package
- ARM cross-compiler (`arm-linux-gnueabi-gcc`) for rebuilding the SPL stub

### Install on Ubuntu/WSL2

```bash
# .NET SDK
wget https://dot.net/v1/dotnet-install.sh -O dotnet-install.sh
chmod +x dotnet-install.sh
./dotnet-install.sh --channel 8.0
export PATH="$HOME/.dotnet:$PATH"

# ARM cross-compiler
sudo apt install gcc-arm-linux-gnueabi

# Python Robot Framework
pip3 install robotframework
```

## Building Renode

```bash
cd ~/renode-ast2600
export PATH="$HOME/.dotnet:$PATH"
export DOTNET_ROOT="$HOME/.dotnet"
./build.sh --net --no-gui --skip-fetch
```

Build output goes to `output/bin/Release/`.

## Running All Tests

Run the complete AST2600 test suite (48 tests):

```bash
cd ~/renode-ast2600
python3 tests/run_tests.py --skip-building --net \
    tests/peripherals/Aspeed/ASPEED_SCU.robot \
    tests/peripherals/Aspeed/ASPEED_SDMC.robot \
    tests/peripherals/Aspeed/ASPEED_WDT.robot \
    tests/peripherals/Aspeed/ASPEED_Timer.robot \
    tests/peripherals/Aspeed/ASPEED_FMC.robot \
    tests/peripherals/Aspeed/ASPEED_SPL_Boot.robot
```

### Running Individual Test Suites

```bash
# SCU tests only (10 tests)
python3 tests/run_tests.py --skip-building --net tests/peripherals/Aspeed/ASPEED_SCU.robot

# FMC tests only (10 tests)
python3 tests/run_tests.py --skip-building --net tests/peripherals/Aspeed/ASPEED_FMC.robot

# SPL boot integration tests (7 tests)
python3 tests/run_tests.py --skip-building --net tests/peripherals/Aspeed/ASPEED_SPL_Boot.robot
```

## Test Suite Summary

| Suite | Tests | What It Covers |
|-------|-------|----------------|
| ASPEED_SCU | 10 | Protection key, silicon revision, clock/reset registers, straps |
| ASPEED_SDMC | 7 | Protection key, DRAM config (1GiB), PHY status/PLL |
| ASPEED_WDT | 7 | Counter defaults, restart magic (0x4755), control, all 4 WDTs |
| ASPEED_Timer | 7 | Reload, counter, match registers, shared CTRL, IRQ status W1C |
| ASPEED_FMC | 10 | Config, CE0 control, segments, DMA grant/clear/addr/checksum/copy, timings |
| ASPEED_SPL_Boot | 7 | End-to-end boot: UART output, WFI halt, SCU/SDMC unlock, WDT disable, DRAM |

## Interactive Boot Demo

To run the SPL boot stub interactively and see UART output:

```bash
cd ~/renode-ast2600
dotnet output/bin/Release/Renode.dll --disable-xwt --console --plain
```

In the Renode monitor:

```
include @tests/peripherals/Aspeed/ast2600-spl-boot.resc
start
```

You should see `DRAM: 1 GiB` on the UART5 analyzer window.

To inspect machine state after boot:

```
pause
cpu0 PC                              # Should be 0x6C-0x70 (WFI loop)
sysbus ReadDoubleWord 0x80000000     # Should be 0xDEADBEEF
sysbus ReadDoubleWord 0x1E6E2000     # SCU key (0x1688A8A8 = unlocked)
sysbus ReadDoubleWord 0x1E6E0000     # SDMC key (0xFC600309 = unlocked)
```

## SPL Boot Stub

The test firmware is a 204-byte ARM assembly stub at
`tests/peripherals/Aspeed/firmware/ast2600_spl_stub.S`.

It exercises peripherals in realistic u-boot SPL boot order:
1. **SCU** — Unlock with protection key 0x1688A8A8, read silicon revision
2. **SDMC** — Unlock with key 0xFC600309, read DRAM configuration
3. **WDT** — Disable watchdog 1 (clear enable bit)
4. **DRAM** — Write 0xDEADBEEF to base, read back and verify
5. **UART** — Print "DRAM: 1 GiB\r\n" to UART5
6. **WFI** — Halt (boot complete)

### Rebuilding the Stub

```bash
cd tests/peripherals/Aspeed/firmware
make clean && make
```

Requires `arm-linux-gnueabi-as`, `arm-linux-gnueabi-ld`, `arm-linux-gnueabi-objcopy`.

## Repository Structure

```
platforms/boards/ast2600/
    ast2600-evb.repl            # Platform description (.repl)

src/Infrastructure/src/Emulator/Peripherals/Peripherals/
    Miscellaneous/Aspeed_SCU.cs   # System Configuration Unit
    Miscellaneous/Aspeed_SDMC.cs  # DRAM Memory Controller
    Timers/Aspeed_Timer.cs        # 8-channel timer
    Timers/Aspeed_WDT.cs          # Watchdog timer
    SPI/Aspeed_FMC.cs             # Flash Memory Controller with DMA

tests/peripherals/Aspeed/
    ASPEED_SCU.robot              # SCU register tests
    ASPEED_SDMC.robot             # SDMC register tests
    ASPEED_WDT.robot              # Watchdog tests
    ASPEED_Timer.robot            # Timer tests
    ASPEED_FMC.robot              # FMC + DMA tests
    ASPEED_SPL_Boot.robot         # Integration boot tests
    ast2600-spl-boot.resc         # Interactive boot script
    firmware/
        ast2600_spl_stub.S        # SPL stub source
        ast2600_spl_stub.bin      # Pre-built binary (204 bytes)
        Makefile                  # Build rules
```

## Troubleshooting

### Build fails with "dotnet not found"
Ensure .NET is on PATH: `export PATH="$HOME/.dotnet:$PATH"`

### Tests show "CPU abort at 0x0"
The boot ROM region at 0x0 may be missing from the `.repl` file.
Verify `bootrom: Memory.MappedMemory @ sysbus 0x0` is present.

### UART output not visible in interactive mode
Use `showAnalyzer uart5` before `start`, or use the `.resc` script
which includes it automatically.

### DMA tests fail
Ensure FMC DMA address masks use `0xFFFFFFFC` (full sysbus addresses).
Renode uses absolute addressing unlike QEMU's per-device address spaces.
