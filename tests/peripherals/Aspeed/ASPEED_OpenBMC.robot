*** Comments ***
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: Apache-2.0
#
# AST2600 OpenBMC Boot Tests
# Tests full OpenBMC boot: SPL -> u-boot -> Linux kernel -> userspace

*** Settings ***
Suite Setup         Setup
Suite Teardown      Teardown
Test Teardown       Test Teardown
Resource            /src/Renode/RobotFrameworkEngine/renode-keywords.robot

*** Variables ***
${UART5}            sysbus.uart5

*** Keywords ***
Setup
    Execute Command     mach create "ast2600"
    Execute Command     machine LoadPlatformDescription @platforms/boards/ast2600/ast2600-evb.repl
    Execute Command     sysbus LoadBinary @tests/peripherals/Aspeed/firmware/openbmc-image.bin 0x0
    Execute Command     sysbus LoadBinary @tests/peripherals/Aspeed/firmware/openbmc-image.bin 0x20000000
    Create Terminal Tester    ${UART5}    timeout=120

*** Test Cases ***
Should Boot SPL
    [Documentation]     Verify SPL starts and loads FIT image
    [Tags]              openbmc    boot    spl
    Execute Command     emulation RunFor "5"
    Wait For Line On Uart    U-Boot SPL    timeout=30
    Wait For Line On Uart    Trying to boot from    timeout=10

Should Load U-Boot
    [Documentation]     Verify u-boot loads and initializes hardware
    [Tags]              openbmc    boot    uboot
    Wait For Line On Uart    U-Boot 2019    timeout=30
    Wait For Line On Uart    DRAM:    timeout=15
    Wait For Line On Uart    Model: AST2600 EVB    timeout=10

Should Detect Peripherals In U-Boot
    [Documentation]     Verify u-boot probes key peripherals
    [Tags]              openbmc    boot    peripherals
    Wait For Line On Uart    MMC:    timeout=15
    Wait For Line On Uart    Net:    timeout=15
    Wait For Line On Uart    eth0:    timeout=10

Should Start Kernel
    [Documentation]     Verify u-boot loads and starts Linux kernel
    [Tags]              openbmc    boot    kernel
    Wait For Line On Uart    Loading kernel from FIT    timeout=30
    Wait For Line On Uart    Starting kernel    timeout=60

Should Boot Linux Kernel
    [Documentation]     Verify Linux kernel starts and prints banner
    [Tags]              openbmc    boot    linux
    Wait For Line On Uart    Linux version    timeout=120
    Wait For Line On Uart    Booting Linux on    timeout=10

Should Mount Root Filesystem
    [Documentation]     Verify rootfs mounts successfully
    [Tags]              openbmc    boot    rootfs
    Wait For Line On Uart    VFS: Mounted root    timeout=120

Should Reach Login Prompt
    [Documentation]     Verify system boots to login prompt
    [Tags]              openbmc    boot    login
    Wait For Line On Uart    login:    timeout=300
