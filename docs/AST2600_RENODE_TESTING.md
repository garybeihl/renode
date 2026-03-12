# AST2600 Renode Testing Guide

## Overview

This document describes how to build, run, and extend the Renode AST2600 test suite,
including how to build the firmware binaries required for integration tests.

The platform models an Aspeed AST2600 BMC SoC:

| Peripheral | Address      | Size   | IRQ     | Description |
|------------|-------------|--------|---------|-------------|
| Boot ROM   | 0x00000000  | 32MB   | —       | SPI flash alias at reset |
| SRAM       | 0x10000000  | 90KB   | —       | Internal SRAM |
| FMC        | 0x1E620000  | 0x200  | 39      | SPI flash controller with DMA |
| Flash      | 0x20000000  | 128MB  | —       | Memory-mapped flash window |
| SDMC       | 0x1E6E0000  | 0x1000 | —       | DRAM memory controller |
| SCU        | 0x1E6E2000  | 0x1000 | 12      | System Configuration Unit |
| SBC        | 0x1E6F2000  | 0x1000 | —       | Secure Boot Controller |
| GPIO 3.3V  | 0x1E780000  | 0x800  | 40      | GPIO (7 sets, 208 pins) |
| GPIO 1.8V  | 0x1E780800  | 0x800  | 11      | GPIO (2 sets, 36 pins) |
| Timer      | 0x1E782000  | 0x100  | 16-23   | 8-channel timer |
| UART5      | 0x1E784000  | —      | 63      | NS16550 serial console |
| WDT1-4     | 0x1E785000+ | 0x40   | 24      | 4 watchdog timers |
| I2C        | 0x1E78A000  | 0x1000 | 110-125 | 16-bus I2C controller |
| RTC        | 0x1E781000  | 0x18   | 13      | Real-time clock |
| PWM        | 0x1E610000  | 0x1000 | 44      | PWM/Fan tachometer |
| PECI       | 0x1E78B000  | 0x1000 | 38      | Platform Environment Control Interface |
| HACE       | 0x1E6D0000  | 0x1000 | 4       | Hash and Crypto Engine (SHA/MD5) |
| XDMA       | 0x1E6E7000  | 0x1000 | 6       | DMA engine |
| DRAM       | 0x80000000  | 1 GiB  | —       | DDR4 |
| GIC        | 0x40461000  | 0x1000 | —       | ARM GICv2 |
| GenTimer   | @ cpu0/cpu1 | —      | PPI     | ARM Generic Timer (1.125 GHz) |

## Prerequisites

- Ubuntu 22.04+ (or WSL2)
- .NET 8.0 SDK
- Python 3.8+ with `robotframework`
- ARM cross-compiler (`arm-linux-gnueabi-gcc-12`)
- `u-boot-tools` package (for `mkimage`)

### Install on Ubuntu/WSL2

```bash
# .NET SDK
wget https://dot.net/v1/dotnet-install.sh -O dotnet-install.sh
chmod +x dotnet-install.sh
./dotnet-install.sh --channel 8.0
export PATH="$HOME/.dotnet:$PATH"

# ARM cross-compiler and tools
sudo apt install gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi u-boot-tools

# Ensure cross-compiler is accessible (symlink if needed)
mkdir -p ~/bin
ln -sf /usr/bin/arm-linux-gnueabi-gcc-12 ~/bin/arm-linux-gnueabi-gcc
ln -sf /usr/bin/arm-linux-gnueabi-as ~/bin/arm-linux-gnueabi-as
ln -sf /usr/bin/arm-linux-gnueabi-ld ~/bin/arm-linux-gnueabi-ld
ln -sf /usr/bin/arm-linux-gnueabi-objcopy ~/bin/arm-linux-gnueabi-objcopy
export PATH="$HOME/bin:$PATH"

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

## Building Firmware

### 1. Build u-boot from Source

u-boot is required for the full boot integration tests. Clone and build:

```bash
# Clone u-boot (if not already present)
cd ~
git clone https://source.denx.de/u-boot/u-boot.git
cd ~/u-boot

# Configure for AST2600 EVB
make CROSS_COMPILE=arm-linux-gnueabi- evb-ast2600_defconfig

# Build (produces spl/u-boot-spl.bin and u-boot ELF)
make CROSS_COMPILE=arm-linux-gnueabi- -j$(nproc)

# Extract flat binary from ELF
arm-linux-gnueabi-objcopy -O binary u-boot u-boot.bin
```

Key outputs:
- `spl/u-boot-spl.bin` — SPL binary (~53KB), runs from flash at reset
- `u-boot.bin` — Full u-boot binary (~450KB), loaded by SPL into DRAM
- `dts/dt.dtb` — Device tree blob for AST2600 EVB (~37KB)

### 2. Build the FIT Image

SPL expects a FIT (Flattened Image Tree) at flash offset 0x10000. Create it:

```bash
cd ~/u-boot

# Create FIT image description
cat > u-boot.its << 'EOF'
/dts-v1/;

/ {
    description = "U-Boot FIT image for AST2600";
    #address-cells = <1>;

    images {
        uboot {
            description = "U-Boot";
            data = /incbin/("u-boot.bin");
            type = "firmware";
            arch = "arm";
            os = "u-boot";
            compression = "none";
            load = <0x80000000>;
            entry = <0x80000000>;
        };
        fdt {
            description = "AST2600 EVB DTB";
            data = /incbin/("dts/dt.dtb");
            type = "flat_dt";
            arch = "arm";
            compression = "none";
        };
    };

    configurations {
        default = "conf";
        conf {
            description = "AST2600 EVB";
            firmware = "uboot";
            fdt = "fdt";
        };
    };
};
EOF

# Build the FIT image
mkimage -f u-boot.its u-boot.itb
```

Output: `u-boot.itb` (~489KB) — contains u-boot + device tree.

### 3. Build the Combined Flash Image (flash.bin)

The combined flash image places SPL at offset 0 and the FIT at offset 0x10000,
mimicking a real SPI NOR flash layout:

```bash
cd ~/u-boot

# Create 32MB flash image (zero-filled)
dd if=/dev/zero of=flash.bin bs=1M count=32

# Write SPL at offset 0 (CPU reset vector)
dd if=spl/u-boot-spl.bin of=flash.bin conv=notrunc

# Write FIT at offset 0x10000 (CONFIG_SPL_LOAD_FIT_ADDRESS)
dd if=u-boot.itb of=flash.bin bs=1 seek=65536 conv=notrunc
```

Flash layout:
```
Offset    Size     Content
0x00000   ~53KB    u-boot SPL (padded to 64KB)
0x10000   ~489KB   u-boot FIT image (u-boot.bin + dt.dtb)
0x88000+  unused   Available for kernel, rootfs, environment
```

### 4. Install Firmware for Tests

Copy the flash image to the Renode test firmware directory:

```bash
cp flash.bin ~/renode-ast2600/tests/peripherals/Aspeed/firmware/flash.bin
```

### 5. Rebuild the SPL Stub (Unit Tests Only)

The SPL stub is a minimal 204-byte ARM assembly program used by unit tests.
It does not require u-boot:

```bash
cd ~/renode-ast2600/tests/peripherals/Aspeed/firmware
make clean && make
```

Requires `arm-linux-gnueabi-as`, `arm-linux-gnueabi-ld`, `arm-linux-gnueabi-objcopy`.

### Quick Rebuild Script

To rebuild everything from scratch:

```bash
#!/bin/bash
set -e

# Build u-boot
cd ~/u-boot
make CROSS_COMPILE=arm-linux-gnueabi- evb-ast2600_defconfig
make CROSS_COMPILE=arm-linux-gnueabi- -j$(nproc)
arm-linux-gnueabi-objcopy -O binary u-boot u-boot.bin

# Build FIT
mkimage -f u-boot.its u-boot.itb

# Build flash image
dd if=/dev/zero of=flash.bin bs=1M count=32
dd if=spl/u-boot-spl.bin of=flash.bin conv=notrunc
dd if=u-boot.itb of=flash.bin bs=1 seek=65536 conv=notrunc

# Install
cp flash.bin ~/renode-ast2600/tests/peripherals/Aspeed/firmware/flash.bin

# Build SPL stub
cd ~/renode-ast2600/tests/peripherals/Aspeed/firmware
make clean && make

echo "All firmware built successfully"
```

## Running Tests

### All Tests (79 tests)

```bash
cd ~/renode-ast2600
python3 tests/run_tests.py --skip-building --net \
    tests/peripherals/Aspeed/ASPEED_*.robot
```

### Individual Test Suites

```bash
# Unit tests (no firmware required)
python3 tests/run_tests.py --skip-building --net tests/peripherals/Aspeed/ASPEED_SCU.robot
python3 tests/run_tests.py --skip-building --net tests/peripherals/Aspeed/ASPEED_SDMC.robot
python3 tests/run_tests.py --skip-building --net tests/peripherals/Aspeed/ASPEED_WDT.robot
python3 tests/run_tests.py --skip-building --net tests/peripherals/Aspeed/ASPEED_Timer.robot
python3 tests/run_tests.py --skip-building --net tests/peripherals/Aspeed/ASPEED_FMC.robot
python3 tests/run_tests.py --skip-building --net tests/peripherals/Aspeed/ASPEED_SBC.robot
python3 tests/run_tests.py --skip-building --net tests/peripherals/Aspeed/ASPEED_GPIO.robot
python3 tests/run_tests.py --skip-building --net tests/peripherals/Aspeed/ASPEED_I2C.robot

# Integration tests (require firmware)
python3 tests/run_tests.py --skip-building --net tests/peripherals/Aspeed/ASPEED_SPL_Boot.robot
python3 tests/run_tests.py --skip-building --net tests/peripherals/Aspeed/ASPEED_UBoot.robot
```

### Test Suite Summary

| Suite          | Tests | Firmware Required | What It Covers |
|----------------|-------|-------------------|----------------|
| ASPEED_SCU     | 10    | No                | Protection key, silicon rev, clocks, straps |
| ASPEED_SDMC    | 7     | No                | Protection key, DRAM config, PHY status |
| ASPEED_WDT     | 7     | No                | Counter, restart magic, control, all 4 WDTs |
| ASPEED_Timer   | 7     | No                | Reload, counter, match, shared CTRL, W1C |
| ASPEED_FMC     | 10    | No                | Config, CE0, segments, DMA operations |
| ASPEED_SBC     | 7     | No                | Status idle/not-secured, R/W, read-only |
| ASPEED_GPIO    | 10    | No                | Data R/W, INT_STATUS W1C, direction, sets |
| ASPEED_I2C     | 11    | No                | Bus R/W, AC timing mask, NAK, W1C, 16 buses |
| ASPEED_SPL_Boot| 7     | SPL stub          | End-to-end: UART, WFI, SCU/SDMC, WDT, DRAM |
| ASPEED_UBoot   | 3     | flash.bin         | Full u-boot: SPL→FIT→DRAM→autoboot prompt |
| **Total**      | **79**|                   |                |

## Interactive Boot

### Full u-boot Boot

```bash
cd ~/renode-ast2600
dotnet output/bin/Release/Renode.dll --disable-xwt --console --plain
```

In the Renode monitor:

```
include @scripts/uboot-full.resc
start
```

Expected UART output (captured to `/tmp/uboot-full.txt`):
```
U-Boot SPL 2026.04-rc4 (Mar 11 2026 - 16:23:28 -0400)
Trying to boot from RAM
## Checking hash(es) for config conf ... OK
## Checking hash(es) for Image uboot ... OK
## Checking hash(es) for Image fdt ... OK

U-Boot 2026.04-rc4 (Mar 11 2026 - 16:23:28 -0400)
Model: Aspeed BMC
DRAM:  1008 MiB (capacity:1024 MiB, VGA:64 MiB), ECC off
Core:  266 devices, 24 uclasses, devicetree: separate
WDT:   Started watchdog@1e785000 with servicing every 1000ms (60s timeout)
...
Hit any key to stop autoboot: 0
=>
```

### SPL Stub Boot (Lightweight)

```
include @tests/peripherals/Aspeed/ast2600-spl-boot.resc
start
```

## Boot Flow

The AST2600 boot sequence in Renode mirrors the real hardware:

```
CPU reset (PC=0x0)
    │
    ▼
Boot ROM (0x0, alias of SPI flash)
    │  SPL runs from flash, executes in place
    │
    ▼
SPL: DDR training via SDMC
    │  Writes protection key, configures DRAM timing
    │  Reads/writes ECC test, CBR test registers
    │
    ▼
SPL: Load FIT from flash offset 0x10000
    │  CONFIG_SPL_LOAD_FIT_ADDRESS = 0x10000
    │  Verifies SHA hashes for u-boot + DTB
    │
    ▼
SPL: Copy u-boot to DRAM at 0x80000000
    │  memcpy from flash to DRAM
    │
    ▼
Full u-boot starts at 0x80000000
    │  Initializes DRAM, WDT, MMC, UART, Ethernet
    │  Prints banner, reaches autoboot prompt
    │
    ▼
=> (u-boot command prompt)
```

## Repository Structure

```
platforms/boards/ast2600/
    ast2600-evb.repl                  # Platform description

src/Infrastructure/src/Emulator/Peripherals/Peripherals/
    Miscellaneous/Aspeed_SCU.cs       # System Configuration Unit
    Miscellaneous/Aspeed_SDMC.cs      # DRAM Memory Controller
    Miscellaneous/Aspeed_SBC.cs       # Secure Boot Controller
    GPIOPort/Aspeed_GPIO.cs           # GPIO controller
    I2C/Aspeed_I2C.cs                 # I2C 16-bus controller
    Timers/Aspeed_Timer.cs            # 8-channel timer
    Timers/Aspeed_WDT.cs              # Watchdog timer
    SPI/Aspeed_FMC.cs                 # Flash Memory Controller with DMA

scripts/
    uboot-full.resc                   # Full u-boot interactive boot script

tests/peripherals/Aspeed/
    ASPEED_SCU.robot                  # SCU register tests
    ASPEED_SDMC.robot                 # SDMC register tests
    ASPEED_WDT.robot                  # Watchdog tests
    ASPEED_Timer.robot                # Timer tests
    ASPEED_FMC.robot                  # FMC + DMA tests
    ASPEED_SBC.robot                  # Secure Boot Controller tests
    ASPEED_GPIO.robot                 # GPIO tests
    ASPEED_I2C.robot                  # I2C tests
    ASPEED_SPL_Boot.robot             # SPL stub integration tests
    ASPEED_UBoot.robot                # Full u-boot boot tests
    ast2600-spl-boot.resc             # SPL stub boot script
    firmware/
        ast2600_spl_stub.S            # SPL stub source (assembly)
        ast2600_spl_stub.bin          # Pre-built stub (204 bytes)
        Makefile                      # Stub build rules
        flash.bin                     # Combined flash image (not in git)
```

Note: `flash.bin`, `u-boot-spl.bin`, and `u-boot.bin` are listed in `.gitignore`
because they are large binaries built from source. See "Building Firmware" above
to rebuild them.

## Troubleshooting

### Build fails with "dotnet not found"
Ensure .NET is on PATH: `export PATH="$HOME/.dotnet:$PATH"`

### u-boot build fails with "arm-linux-gnueabi-gcc: not found"
Install the cross-compiler and create symlinks:
```bash
sudo apt install gcc-arm-linux-gnueabi
ln -sf /usr/bin/arm-linux-gnueabi-gcc-12 ~/bin/arm-linux-gnueabi-gcc
```

### u-boot boot tests fail with "file not found"
Rebuild `flash.bin` — see "Building Firmware" section above.

### SPL hangs during DDR training
The SDMC model must implement protection key transformation (QEMU-compatible).
Key `0xFC600309` → stored as `0x01` (unlocked). Any other value → `0x00` (locked).
SPL polls until the key reads as 0 after locking.

### UART output not visible in interactive mode
Set log level before starting: `logLevel 3` (errors only).
Use `uart5 CreateFileBackend @/tmp/output.txt true` to capture to file.

### Timer-related delays seem too long
Verify the ARM Generic Timer frequency is 1,125,000,000 Hz in the `.repl` file.
u-boot calculates delays based on CNTFRQ — a mismatch causes proportional slowdown.
