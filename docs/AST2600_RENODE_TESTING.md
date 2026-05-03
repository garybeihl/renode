# AST2600 Renode Testing Guide

## Overview

This document describes how to build, run, and extend the Renode AST2600 test suite,
including how to build the firmware binaries required for integration tests.

The platform models an Aspeed AST2600 BMC SoC:

| Peripheral | Address      | Size   | IRQ     | Description |
|------------|-------------|--------|---------|-------------|
| Boot ROM   | 0x00000000  | 32MB   | —       | SPI flash alias at reset |
| SRAM       | 0x10000000  | 90KB   | —       | Internal SRAM |
| FMC regs   | 0x1E620000  | 0x200  | 39      | SPI flash controller (registers) |
| FMC flash  | 0x20000000  | 64MB   | —       | FMC memory-mapped flash window |
| Flash mem  | 0x60000000  | 64MB   | —       | Flash backing store (for sysbus LoadBinary) |
| SDMC       | 0x1E6E0000  | 0x1000 | —       | DRAM memory controller |
| SCU        | 0x1E6E2000  | 0x1000 | 12      | System Configuration Unit |
| SBC        | 0x1E6F2000  | 0x1000 | —       | Secure Boot Controller |
| GPIO 3.3V  | 0x1E780000  | 0x800  | 40      | GPIO (7 sets, 208 pins) |
| GPIO 1.8V  | 0x1E780800  | 0x800  | 11      | GPIO (2 sets, 36 pins) |
| Timer      | 0x1E782000  | 0x100  | 16-23   | 8-channel timer |
| UART5      | 0x1E784000  | —      | 8       | NS16550 serial console |
| WDT1-4     | 0x1E785000+ | 0x40   | 24      | 4 watchdog timers |
| I2C        | 0x1E78A000  | 0x1000 | 110-125 | 16-bus I2C controller |
| RTC        | 0x1E781000  | 0x18   | 13      | Real-time clock |
| PWM        | 0x1E610000  | 0x1000 | 44      | PWM/Fan tachometer |
| PECI       | 0x1E78B000  | 0x1000 | 38      | Platform Environment Control Interface |
| HACE       | 0x1E6D0000  | 0x1000 | 4       | Hash and Crypto Engine (SHA/MD5) |
| XDMA       | 0x1E6E7000  | 0x1000 | 6       | DMA engine |
| eSPI       | 0x1E6EE000  | 0x1000 | 42      | eSPI slave controller |
| ADC        | 0x1E6E9000  | 0x1000 | 46      | Dual-engine 16-channel ADC |
| LPC/KCS    | 0x1E789000  | 0x1000 | 35      | LPC host interface with 4 KCS channels |
| ETH1       | 0x1E660000  | 0x1000 | 2       | FTGMAC100 Ethernet MAC |
| ETH2       | 0x1E680000  | 0x1000 | 3       | FTGMAC100 Ethernet MAC |
| ETH3       | 0x1E670000  | 0x1000 | 32      | FTGMAC100 Ethernet MAC |
| ETH4       | 0x1E690000  | 0x1000 | 33      | FTGMAC100 Ethernet MAC |
| DRAM       | 0x80000000  | 1 GiB  | —       | DDR4 |
| GIC        | 0x40461000  | 0x1000 | —       | ARM GICv2 |
| GenTimer   | @ cpu0/cpu1 | —      | PPI     | ARM Generic Timer (1.2 GHz) |

The FMC uses `BusMultiRegistration` to register at two bus regions: "registers"
(0x1E620000) for control/DMA and "flash" (0x20000000) for the memory-mapped
flash window. In normal mode, flash window reads return data from the backing
`MappedMemory`. In user mode (CE0 Control type=3), reads/writes send SPI bytes
to an internal `GenericSpiFlash` (Winbond W25Q512JV, JEDEC ID 0xEF 0x40 0x20),
enabling the Linux `spi-aspeed-smc` driver to identify the flash chip.

The flash backing store at 0x60000000 is the same `MappedMemory` object the FMC
references internally. It is registered on the sysbus solely so that
`sysbus LoadBinary` can populate it quickly at boot. Address 0x60000000 is unused
in the real AST2600 memory map.

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

### All Tests (185 tests)

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

python3 tests/run_tests.py --skip-building --net tests/peripherals/Aspeed/ASPEED_ADC.robot
python3 tests/run_tests.py --skip-building --net tests/peripherals/Aspeed/ASPEED_LPC.robot
python3 tests/run_tests.py --skip-building --net tests/peripherals/Aspeed/ASPEED_FTGMAC100.robot

# Integration tests (require firmware)
python3 tests/run_tests.py --skip-building --net tests/peripherals/Aspeed/ASPEED_SPL_Boot.robot
python3 tests/run_tests.py --skip-building --net tests/peripherals/Aspeed/ASPEED_UBoot.robot
python3 tests/run_tests.py --skip-building --net tests/peripherals/Aspeed/ASPEED_OpenBMC.robot
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
| ASPEED_HACE    | 8     | No                | Register reset, address masking, W1C, key buffer |
| ASPEED_PWM     | 5     | No                | General control, duty cycle, defaults, write/read |
| ASPEED_PECI    | 7     | No                | Fire command, auto-complete, IRQ W1C, data buffer |
| ASPEED_RTC     | 8     | No                | Counter enable, date/time, lock, alarm W1C |
| ASPEED_XDMA    | 6     | No                | IRQ status W1C, control mask, command queue |
| ASPEED_ESPI    | 20    | No                | Reset values, W1C, capabilities, TX completion, SYSEVT, DMA, MMBI |
| ASPEED_ADC     | 15    | No                | Dual engine, channel data, thresholds, W1C |
| ASPEED_LPC     | 15    | No                | KCS channels, IBF/OBF, IRQ, dual-gate |
| ASPEED_FTGMAC100| 15   | No                | PHY MII, ISR W1C, MACCR SW_RST, link up |
| ASPEED_OpenBMC | 7     | OpenBMC MTD image | Full Linux boot: SPL → kernel → systemd |
| ASPEED_PLDM_FirmwareUpdate | 4 | OpenBMC MTD image + pldm-sim | PLDM firmware update: happy path, reject, verify failure |
| **Total**      | **189**|                   |                |

## PLDM Firmware Update E2E Tests

### Overview

The PLDM E2E test suite exercises the full PLDM firmware update flow on an
emulated AST2600 BMC: boot OpenBMC, establish MCTP serial transport, discover
the firmware device via pldmd, and run a firmware update over D-Bus.

Everything runs inside Renode — no external processes, no sudo, no real
hardware. A C# component called `PldmFirmwareDevice` emulates a PLDM firmware
device on UART1 (`/dev/ttyS0` in the guest). Different JSON scenario files
control the device's behavior (accept, reject, verification failure).

```
┌──────────────────────────────────────────┐
│              Renode Emulation             │
│                                          │
│  ┌─────────────────┐   ┌──────────────┐ │
│  │  AST2600 Guest   │   │ PldmFirmware │ │
│  │                  │   │   Device     │ │
│  │  OpenBMC Linux   │   │  (C# class)  │ │
│  │  ┌────────────┐  │   │              │ │
│  │  │   pldmd    │──│───│─ UART1/MCTP ─│ │
│  │  └────────────┘  │   │              │ │
│  │  ┌────────────┐  │   │  Scenario:   │ │
│  │  │   mctpd    │  │   │  *.json      │ │
│  │  └────────────┘  │   └──────────────┘ │
│  │     UART5 ───────│──→ Terminal Tester  │
│  └─────────────────┘                     │
└──────────────────────────────────────────┘
```

### Quick Start (From Scratch)

If you're new to Renode, follow these steps to get from zero to running the
PLDM E2E tests.

#### 1. Install Prerequisites

```bash
# .NET 8.0 SDK (required to build Renode)
wget https://dot.net/v1/dotnet-install.sh -O dotnet-install.sh
chmod +x dotnet-install.sh
./dotnet-install.sh --channel 8.0
export PATH="$HOME/.dotnet:$PATH"
export DOTNET_ROOT="$HOME/.dotnet"

# Python 3.8+ and Robot Framework
sudo apt install python3 python3-pip python3-venv
```

#### 2. Clone and Build Renode

```bash
git clone https://github.com/renode/renode.git
cd renode

# Build (headless, .NET, skip submodule fetch if already present)
./build.sh --net --no-gui --skip-fetch

# Set up Python virtual environment for test runner
python3 -m venv .venv
source .venv/bin/activate
pip install -r tests/requirements.txt
```

Build output goes to `output/bin/Release/`. Verify the build:

```bash
dotnet output/bin/Release/Renode.dll --version
```

#### 3. Obtain Firmware and Test Artifacts

The PLDM E2E tests require two things beyond a base Renode build:

**OpenBMC image** — a Yocto-built MTD image placed at:
```
tests/peripherals/Aspeed/firmware/openbmc-image.bin
```

This is the same image used by the `ASPEED_OpenBMC` test suite. See
"Building Firmware" above for the flash image layout. The OpenBMC image
must be built from the OpenBMC Yocto build system targeting `evb-ast2600`.

**pldm-sim artifacts** — the PLDM firmware package and scenario files. These
live in a sibling `pldm-sim/` directory relative to the Renode repo:

```
<workspace>/
├── renode/                     ← this repo
└── pldm-sim/
    ├── test_fw_pkg.pldm        ← firmware package (binary)
    └── scenarios/
        ├── gpu-terminus.json           ← happy path
        ├── reject-update.json          ← component rejection
        └── verify-failure-renode.json  ← verification failure
```

The Robot test references these via `${CURDIR}/../../../../pldm-sim/`. If
your directory layout differs, adjust the paths in the `*** Variables ***`
section of the `.robot` file.

#### 4. Run the Tests

```bash
cd renode
source .venv/bin/activate

# Run all PLDM E2E tests (~40 minutes)
python3 tests/run_tests.py \
    --robot-framework-remote-server-full-directory output/bin/Release \
    --robot-framework-remote-server-name Renode \
    --css-file "" \
    --include pldm \
    tests/peripherals/Aspeed/ASPEED_PLDM_FirmwareUpdate.robot
```

Results are written to `tests/tests/report.html`.

### Running Individual Tests

Use Robot Framework tags to select specific scenarios:

```bash
# Happy path only
python3 tests/run_tests.py ... --include firmware-update \
    tests/peripherals/Aspeed/ASPEED_PLDM_FirmwareUpdate.robot

# Component rejection only
python3 tests/run_tests.py ... --include reject \
    tests/peripherals/Aspeed/ASPEED_PLDM_FirmwareUpdate.robot

# Verify failure only
python3 tests/run_tests.py ... --include verify-failure \
    tests/peripherals/Aspeed/ASPEED_PLDM_FirmwareUpdate.robot
```

Note: each scenario test requires the boot test (`--include boot`). Robot
Framework's `Requires` keyword automatically pulls in the boot test when
a scenario test is selected.

### Test Scenarios

| Test Case | Tag | Scenario File | What It Tests |
|-----------|-----|---------------|---------------|
| Should Boot And Login To OpenBMC | `boot` | — | Boots OpenBMC, logs in, snapshots state |
| Should Complete PLDM Firmware Update | `firmware-update` | `gpu-terminus.json` | Single component, update succeeds |
| Should Handle Component Rejection | `reject` | `reject-update.json` | Component 100 rejected (COMP_NOT_SUPPORTED), component 200 accepted and updated |
| Should Handle Verify Failure | `verify-failure` | `verify-failure-renode.json` | Transfer succeeds, VerifyComplete returns VERIFICATION_FAILURE |

### Test Architecture

#### Provides/Requires (Boot Snapshot)

Booting OpenBMC takes ~7 minutes of wall-clock time. To avoid repeating
this for each scenario, the boot test uses Robot Framework's
`Provides`/`Requires` mechanism:

1. **Boot test** boots OpenBMC, logs in, pauses the emulation, then calls
   `Provides booted-state` to snapshot the full machine state.
2. **Each scenario test** calls `Requires booted-state` to restore from
   the snapshot, then attaches a fresh `PldmFirmwareDevice` with its
   scenario JSON.

`PldmFirmwareDevice` is created **after** the restore because it does not
implement Renode's serialization interface (`ISerializable`). Since UART1
is unused during boot (the console is UART5), its state is clean after
restore, and the freshly attached device works correctly.

#### Test Flow Per Scenario

After the boot snapshot is restored, each scenario test runs these phases:

1. **Attach PLDM Device** — create `PldmFirmwareDevice` with the scenario
   JSON, connect to UART1, enable verbose logging
2. **Configure MCTP** — start `mctp link serial /dev/ttyS0`, assign
   addresses and routes, register endpoint via `AssignEndpointStatic`
3. **Start pldmd** — `systemctl start pldmd`, verify it is running
4. **Transfer firmware package** — send `test_fw_pkg.pldm` to the guest
   via `printf` hex escapes (no `base64` on this image)
5. **Trigger update** — D-Bus `StartUpdate` call, wait 120s virtual time
6. **Assert** — grep pldmd journal for expected log messages

### Firmware Package Compatibility

The firmware package (`test_fw_pkg.pldm`) contains:
- **Device UUID**: `162023C9-3EC5-4115-95F4-48701D49D675`
- **Component 100**: `RejectMe1.0`
- **Component 200**: `AcceptMe1.0`

pldmd matches firmware devices by UUID and components by ID. Scenario JSON
files must use a matching UUID and component IDs or the update won't be
attempted. The `verify-failure-renode.json` scenario uses matching IDs
(unlike the standalone `verify-failure.json` which uses different IDs for
pldm-sim unit testing).

### Adding a New Scenario

1. **Create the scenario JSON** in `pldm-sim/scenarios/`. Use the firmware
   package UUID (`162023C9-3EC5-4115-95F4-48701D49D675`) and component IDs
   (100 and/or 200) so pldmd matches the device. See existing scenarios for
   the schema.

2. **Add a variable** in the Robot file's `*** Variables ***` section:
   ```
   ${MY_SCENARIO}    ${CURDIR}/../../../../pldm-sim/scenarios/my-scenario.json
   ```

3. **Add a test case** in `*** Test Cases ***`:
   ```
   Should Handle My Scenario
       [Documentation]    Description of what this tests
       [Tags]             pldm    my-tag
       Requires           booted-state
       Attach PLDM Device    ${MY_SCENARIO}
       Configure MCTP
       Start Pldmd
       Transfer Firmware Package
       Trigger Firmware Update
       Assert Journal Contains    expected log pattern    MARKER
   ```

4. **Run the test** with `--include my-tag` to verify.

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

### OpenBMC Linux Boot

The full OpenBMC boot requires a Yocto-built MTD image (not the u-boot
`flash.bin` above). The boot script loads firmware into three locations:

1. **0x0** (bootrom) — u-boot SPL executes from here at reset
2. **0x60000000** (flash backing) — populates flash data for kernel MTD driver
3. **0x88000000** (DRAM) — pre-loaded FIT image for fast `bootm` (bypasses
   SHA-256 hash verification issue)

```bash
dotnet output/bin/Release/Renode.dll --disable-xwt --plain \
    --execute "include @scripts/openbmc-diag9.resc"
```

The boot sequence takes ~180s of emulated time:
- u-boot SPL → FIT → u-boot prompt (interrupted by autoboot)
- `bootm 88100000` → Linux kernel with `nosmp maxcpus=1`
- initramfs → squashfs rootfs (MTD) → jffs2 overlayfs → switch_root
- systemd → OpenBMC services (bmcweb, pldmd, phosphor-inventory-manager)
- Serial getty on ttyS4 → login prompt

Known issues during Linux boot:
- eth0 timeout (90s, no network emulation)
- jffs2 rwfs corruption warnings (harmless, flash image artifact)

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
    │  bootm loads FIT from DRAM (kernel + DTB + initramfs)
    │
    ▼
Linux kernel (nosmp, single CPU)
    │  Mounts devtmpfs, sysfs, proc
    │  spi-aspeed-smc driver: JEDEC ID → W25Q512JV recognized
    │  MTD partitions created from device tree
    │
    ▼
initramfs /init script
    │  Mounts squashfs rootfs (MTD rofs partition)
    │  Mounts jffs2 read-write fs (MTD rwfs partition)
    │  Creates overlayfs (rofs + rwfs)
    │  switch_root to /root with systemd
    │
    ▼
systemd (PID 1)
    │  Starts OpenBMC services: bmcweb, pldmd,
    │  phosphor-inventory-manager, phosphor-network-manager
    │  Serial getty on ttyS4
    │
    ▼
Login prompt
```

## Repository Structure

```
platforms/boards/ast2600/
    ast2600-evb.repl                  # Platform description

src/Infrastructure/src/Emulator/Peripherals/Peripherals/
    Miscellaneous/Aspeed_SCU.cs       # System Configuration Unit
    Miscellaneous/Aspeed_SDMC.cs      # DRAM Memory Controller
    Miscellaneous/Aspeed_SBC.cs       # Secure Boot Controller
    Miscellaneous/Aspeed_ADC.cs       # Dual-engine ADC
    Miscellaneous/Aspeed_LPC.cs       # LPC/KCS host interface
    Miscellaneous/Aspeed_FTGMAC100.cs # FTGMAC100 Ethernet MAC stub
    Miscellaneous/Aspeed_HACE.cs      # Hash and Crypto Engine
    Miscellaneous/Aspeed_PWM.cs       # PWM/Fan tachometer
    Miscellaneous/Aspeed_PECI.cs      # Platform Environment Control Interface
    Miscellaneous/Aspeed_XDMA.cs      # DMA engine
    Miscellaneous/Aspeed_RTC.cs       # Real-time clock
    Miscellaneous/Aspeed_eSPI.cs      # eSPI slave controller
    GPIOPort/Aspeed_GPIO.cs           # GPIO controller
    I2C/Aspeed_I2C.cs                 # I2C 16-bus controller
    Timers/Aspeed_Timer.cs            # 8-channel timer
    Timers/Aspeed_WDT.cs              # Watchdog timer
    SPI/Aspeed_FMC.cs                 # Flash Memory Controller with DMA + SPI user mode

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
    ASPEED_ADC.robot                  # ADC register tests
    ASPEED_LPC.robot                  # LPC/KCS register tests
    ASPEED_FTGMAC100.robot            # Ethernet MAC register tests
    ASPEED_SPL_Boot.robot             # SPL stub integration tests
    ASPEED_UBoot.robot                # Full u-boot boot tests
    ASPEED_OpenBMC.robot              # OpenBMC Linux boot test
    ASPEED_PLDM_FirmwareUpdate.robot  # PLDM firmware update E2E tests
    ast2600-spl-boot.resc             # SPL stub boot script
    firmware/
        ast2600_spl_stub.S            # SPL stub source (assembly)
        ast2600_spl_stub.bin          # Pre-built stub (204 bytes)
        Makefile                      # Stub build rules
        flash.bin                     # Combined flash image (not in git)
        openbmc-image.bin             # OpenBMC MTD image (not in git)

src/Renode/Integrations/PldmFirmwareDevice/
    PldmFirmwareDevice.cs             # Main device class (MCTP serial + PLDM)
    PldmFirmwareUpdateResponder.cs    # Firmware update state machine
    McptSerialTransport.cs            # MCTP serial framing/deframing
    ...                               # 10 .cs files total

../pldm-sim/                          # Sibling repo: PLDM device simulator
    test_fw_pkg.pldm                  # Firmware package for E2E tests
    scenarios/
        gpu-terminus.json             # Happy path: single-component update
        reject-update.json            # Component rejection scenario
        verify-failure-renode.json    # Verification failure (Renode-compatible)
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

### Userspace output missing (only kernel messages visible)
Verify UART5 IRQ is `gic@8` (GIC SPI 8) in the `.repl` file. An incorrect
IRQ mapping breaks interrupt-driven TX: printk works (polled mode) but
userspace tty output (systemd, login prompt) requires THRE interrupts.

### Timer-related delays seem too long
Verify the ARM Generic Timer frequency is 1,200,000,000 Hz in the `.repl` file.
u-boot calculates delays based on CNTFRQ — a mismatch causes proportional slowdown.

### SHA-256 hash verification fails during bootm
Earlier versions had hash mismatches because the flash window at 0x20000000
was a standalone `MappedMemory` that didn't properly handle FMC controller
state. With the FMC `BusMultiRegistration` rework (flash region + user mode),
booting from the DRAM pre-loaded FIT (`bootm 88100000`) passes all SHA-256
checks. If verification still fails, ensure the firmware is loaded at all
three addresses (0x0, 0x60000000, 0x88000000).

### Linux boot hangs at "Starting kernel"
Ensure `nosmp maxcpus=1` is in bootargs. The second CPU (cpu1) is halted but
its dirty address list can grow unbounded, causing OOM. The Machine.cs fix
skips halted CPUs during dirty address broadcast.

### Robot tests fail with "Required state booted-state not found"
The u-boot autoboot interrupt failed. The old approach (`Wait For Line On Uart
autoboot` then `Write Line To Uart`) is timing-dependent — by the time the
terminal tester returns from the wait and sends the keypress, the 2-second
countdown may have already expired.

**Fix:** Use a CR spam loop instead. This sends CR every 0.5 virtual seconds
throughout u-boot init, guaranteeing at least one keypress during the
countdown window:

```robot
FOR    ${i}    IN RANGE    20
    Execute Command    emulation RunFor "0.5"
    Execute Command    uart5 WriteChar 0xD
END
Wait For Line On Uart    ast#    timeout=30    includeUnfinishedLine=true
```

This matches the `.resc` script pattern and is reliable across different
u-boot versions and boot timing variations. Applied to both
`ASPEED_SPDM_Attestation.robot` and `ASPEED_PLDM_FirmwareUpdate.robot`.

### Multi-endpoint Robot tests fail (ATTEST_CNT, SKIP_PASS)
The `evb-ast2600-renode` machine config must enable all UARTs used by the
tests. Single-endpoint tests use uart1 (/dev/ttyS0). Multi-endpoint tests
also use uart2 (/dev/ttyS1). If a UART is not enabled in the device tree,
the kernel registers it as `uart:unknown` and `/dev/ttySN` returns I/O errors.

The `aspeed-ast2600-evb-renode.dts` enables both:
```dts
&uart1 { status = "okay"; };
&uart2 { status = "okay"; };
```

---

## Renode User-Mode Networking (SLiRP-like)

Renode includes a built-in user-mode network stack (NetworkServer) that provides
DHCP, ARP, ICMP, and TCP without requiring host TAP devices or sudo. This is
analogous to QEMU's SLiRP networking. Port forwarding bridges host TCP sockets
to guest TCP connections through the emulated network.

### Architecture

```
Host                              Renode                           Guest (OpenBMC)
────                              ──────                           ─────
curl/RSV                     NetworkServer (10.0.2.2)          bmcweb (:443)
  │                            ├── ARP responder                   │
  │  TCP to 127.0.0.1:2443    ├── DHCP server (10.0.2.15)        │
  └──────────────────────────► ├── ICMP echo                      │
     PortForwarder             ├── TCP state machine               │
     (host socket ↔            └── PortForwarder                   │
      TcpConnection)                │                              │
                                    │  Ethernet frames via Switch  │
                                    └──────────────────────────────┘
                                         FTGMAC100 (eth1 in .repl = eth0 in Linux)
```

### Quick Start

```bash
cd ~/claude/renode
PATH="$HOME/.dotnet:$PATH" DOTNET_ROOT="$HOME/.dotnet" \
  dotnet output/bin/Release/Renode.dll --disable-xwt --plain \
  --execute "include @scripts/openbmc-rsv-test.resc"
```

After boot (~4-5 minutes real time), the emulation enters continuous execution.
From another terminal:

```bash
# Verify Redfish is reachable
curl -sk -u root:0penBmc https://127.0.0.1:2443/redfish/v1/
```

### .resc Script Setup

The `openbmc-rsv-test.resc` script configures networking:

```
# Create user-mode network gateway at 10.0.2.2
emulation CreateNetworkServer "net" "10.0.2.2"
net StartDHCP "10.0.2.15"

# Forward host port 2443 to guest port 443 (bmcweb HTTPS)
net AddPortForward "127.0.0.1" 2443 "10.0.2.15" 443

# Connect via a virtual switch
emulation CreateSwitch "switch"
connector Connect net switch
connector Connect sysbus.eth1 switch
```

Key points:
- `sysbus.eth1` is the Renode peripheral name for MAC0 at 0x1E660000 (Linux's
  `eth0`). The `.repl` names MACs as eth1-eth4.
- The NetworkServer handles ARP, DHCP, ICMP, and TCP at the IP level.
- Port forwarding creates real host TCP listeners that bridge to emulated TCP
  connections through the NetworkServer's TCP state machine.
- No sudo required — all networking is in-process.

### How Link Detection Works

The AST2600 EVB device tree configures `mac0` with an RTL8211F PHY on external
`mdio0`. The Linux `ftgmac100` driver uses `phylib` to poll the PHY's BMSR and
PHYSR registers for link status. The `Aspeed_MDIO` emulation provides:

- **BMSR** (register 1): Always returns link up + auto-negotiation complete
- **PHYSR** (page 0xa43, register 0x12): Returns `0x2C` = 1Gbps, full-duplex,
  link up. The speed field uses bits [5:4] where `10` = 1000Mbps.

The kernel sees `Link is Up - 1Gbps/Full` at boot and `systemd-networkd`
configures eth0 via DHCP from the NetworkServer.

**Bug history**: The original PHYSR value was `0x3C` (bits [5:4] = `11`) which
doesn't match any speed case in the RTL8211F driver's `rtlgen_decode_physr()`.
This left `phydev->speed = 0`, causing `ftgmac100_adjust_link()` to report no
link and `netif_carrier_off()` to persist. Fixed by changing to `0x2C`.

### Adding More Port Forwards

```
# Forward host 8080 to guest 80 (HTTP)
net AddPortForward "127.0.0.1" 8080 "10.0.2.15" 80

# Forward host 2222 to guest 22 (SSH — if dropbear is running)
net AddPortForward "127.0.0.1" 2222 "10.0.2.15" 22
```

### Limitations

- **TCP only** — UDP port forwarding is not implemented. DNS resolution from the
  guest fails (the NetworkServer logs "Received UDP packet on port 53, but no
  service is active").
- **No outbound internet** — the guest cannot reach external hosts. The
  NetworkServer only handles traffic to/from its own IP (10.0.2.2).
- **TLS passthrough** — the PortForwarder bridges raw TCP bytes. TLS termination
  happens in bmcweb on the guest. Use `curl -k` or `--no_cert_check` for RSV.

---

## Redfish Service Validator (RSV)

The [DMTF Redfish Service Validator](https://github.com/DMTF/Redfish-Service-Validator)
tests Redfish protocol conformance against the DMTF schema. With Renode
networking, RSV can validate bmcweb running inside the emulated OpenBMC.

### Install RSV

```bash
python3 -m venv ~/claude/rsv-venv
source ~/claude/rsv-venv/bin/activate
pip install redfish_service_validator
```

### Run RSV

1. Start Renode with the networking script (see Quick Start above)
2. Wait for boot to complete and verify Redfish responds:
   ```bash
   curl -sk -u root:0penBmc https://127.0.0.1:2443/redfish/v1/
   ```
3. Run the validator:
   ```bash
   source ~/claude/rsv-venv/bin/activate
   rf_service_validator \
     --auth Session \
     -i https://127.0.0.1:2443 \
     -u root -p 0penBmc \
     --no_cert_check
   ```

### RSV Options

| Option | Purpose |
|--------|---------|
| `--auth Session` | Use Redfish session authentication (recommended) |
| `--auth Basic` | Use HTTP Basic auth |
| `--no_cert_check` | Skip TLS certificate verification (self-signed) |
| `--logdir /tmp/rsv` | Save detailed results to directory |
| `--uri /redfish/v1/Managers/bmc` | Test a single URI instead of crawling |

### Expected Results

On a stock evb-ast2600 image, RSV will report some failures. These are typically:
- Missing optional properties that the evb-ast2600 image doesn't populate
- Schema version mismatches between bmcweb and the RSV schema bundle
- Properties that require real hardware (sensors, FRU data)

The primary value is catching regressions in bmcweb Redfish compliance during
development.
