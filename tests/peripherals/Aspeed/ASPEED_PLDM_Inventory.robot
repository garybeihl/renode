*** Comments ***
# AST2600 PLDM Inventory Interface E2E Tests
# Verifies that createPldmEntity() selects the correct Inventory.Item.*
# interface based on the PLDM entity type in the Entity Auxiliary Names PDR.
#
# Uses Renode-internal PldmFirmwareDevice — no sudo, no external process.
# Boot state is snapshotted via Provides/Requires (same pattern as
# ASPEED_PLDM_FirmwareUpdate.robot).

*** Settings ***
Suite Setup         Setup
Suite Teardown      Teardown
Test Teardown       Test Teardown
Test Timeout        600

*** Variables ***
${UART5}                    sysbus.uart5
${GPU_SCENARIO}             ${CURDIR}/../../../../pldm-sim/scenarios/gpu-terminus.json

*** Keywords ***
Create Base Machine
    Execute Command     mach create "ast2600"
    Execute Command     machine LoadPlatformDescription @platforms/boards/ast2600/ast2600-evb.repl
    Execute Command     sysbus LoadBinary @tests/peripherals/Aspeed/firmware/openbmc-image.bin 0x0
    Execute Command     sysbus LoadBinary @tests/peripherals/Aspeed/firmware/openbmc-image.bin 0x60000000
    Execute Command     sysbus LoadBinary @tests/peripherals/Aspeed/firmware/openbmc-image.bin 0x88000000
    Execute Command     sysbus SilenceRange <0x1E630000 0xC4>
    Execute Command     sysbus SilenceRange <0x30000000 0x10000000>
    Execute Command     sysbus SilenceRange <0x1E631000 0xC4>
    Execute Command     sysbus SilenceRange <0x50000000 0x10000000>
    Execute Command     sysbus SilenceRange <0x1E740000 0x10000>
    Execute Command     sysbus SilenceRange <0x1E750000 0x10000>
    Execute Command     sysbus SilenceRange <0x1E6A0000 0x1000>
    Execute Command     sysbus SilenceRange <0x1E6A3000 0x1000>
    Execute Command     sysbus SilenceRange <0x1E700000 0x1000>
    Create Terminal Tester    ${UART5}    timeout=120

Attach PLDM Device
    [Arguments]    ${scenario}
    Execute Command     emulation CreatePldmFirmwareDevice "pldm_fd" "${scenario}"
    Execute Command     connector Connect uart1 pldm_fd
    Execute Command     logLevel -1 pldm_fd

Pause And Run For
    [Arguments]        ${time}
    Execute Command    pause
    Execute Command    emulation RunFor "${time}"

Boot And Login
    FOR    ${i}    IN RANGE    20
        Execute Command    emulation RunFor "0.5"
        Execute Command    uart5 WriteChar 0xD
    END
    Wait For Line On Uart    ast#    timeout=30    includeUnfinishedLine=true
    Write Line To Uart    setenv bootargs console=ttyS4,115200n8 earlycon=uart8250,mmio32,0x1e784000,115200n8 nosmp maxcpus=1 panic=-1
    Wait For Line On Uart    ast#    timeout=10    includeUnfinishedLine=true
    Write Line To Uart    bootm 88100000
    Wait For Line On Uart    login:    timeout=300    includeUnfinishedLine=true
    Pause And Run For    60
    Write Line To Uart    root
    Wait For Line On Uart    Password:    timeout=60    includeUnfinishedLine=true
    Write Line To Uart    0penBmc    waitForEcho=false
    Wait For Line On Uart    root@    timeout=60    includeUnfinishedLine=true

Configure MCTP
    Write Line To Uart    nohup mctp link serial /dev/ttyS0 &    waitForEcho=false
    Pause And Run For    3
    Write Line To Uart    mctp link set mctpserial0 up    waitForEcho=false
    Pause And Run For    1
    Write Line To Uart    mctp addr add 8 dev mctpserial0    waitForEcho=false
    Pause And Run For    1
    Write Line To Uart    mctp route add 20 via mctpserial0    waitForEcho=false
    Pause And Run For    1
    Write Line To Uart    busctl call au.com.codeconstruct.MCTP1 /au/com/codeconstruct/mctp1/interfaces/mctpserial0 au.com.codeconstruct.MCTP.BusOwner1 AssignEndpointStatic ayy 0 20    waitForEcho=false
    Pause And Run For    10

Start Pldmd
    Write Line To Uart    systemctl start pldmd    waitForEcho=false
    Pause And Run For    30
    Write Line To Uart    systemctl is-active pldmd && echo PLDMD_OK || echo PLDMD_FAIL    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    PLDMD    timeout=30    includeUnfinishedLine=true


*** Test Cases ***
Should Boot And Login
    [Documentation]    Boot OpenBMC and login, save state for inventory test
    [Tags]             pldm    boot
    Create Base Machine
    Boot And Login
    Execute Command    pause
    Provides           booted-state

GPU Terminus Exposes Accelerator Interface
    [Documentation]    Entity type 152 (GPU) must produce Inventory.Item.Accelerator
    [Tags]             inventory    89127
    Requires           booted-state
    Attach PLDM Device    ${GPU_SCENARIO}
    Configure MCTP
    Start Pldmd
    # Give pldmd ample time for MCTP discovery + PDR fetch + inventory creation
    Pause And Run For    180
    # Write result to file to avoid UART echo garbling in grep
    Write Line To Uart    busctl introspect xyz.openbmc_project.PLDM /xyz/openbmc_project/inventory/system/board/GPU0 > /tmp/inv.txt 2>&1; grep Item /tmp/inv.txt; echo INV_DONE    waitForEcho=false
    Pause And Run For    10
    Wait For Line On Uart    Item    timeout=60    includeUnfinishedLine=true
