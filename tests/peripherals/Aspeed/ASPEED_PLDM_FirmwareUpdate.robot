*** Comments ***
# AST2600 PLDM Firmware Update E2E Tests
# Boots OpenBMC, sets up MCTP serial, runs firmware update scenarios
#
# Uses Renode-internal PldmFirmwareDevice — no sudo, no external process,
# deterministic virtual time via emulation RunFor.
#
# NOTE: emulation RunFor requires the emulation to be paused (IsStarted=false).
# Wait For Line On Uart starts the emulation and leaves it running.
# Must call "pause" before each RunFor after any Wait For Line On Uart.
#
# Boot/login state is snapshotted via Provides/Requires.  PldmFirmwareDevice
# does not survive serialization, so it is attached after each Requires restore.

*** Settings ***
Suite Setup         Setup
Suite Teardown      Teardown

*** Variables ***
${UART5}                    sysbus.uart5
${FW_PKG}                   ${CURDIR}/../../../../pldm-sim/test_fw_pkg.pldm
${DEFAULT_SCENARIO}         ${CURDIR}/../../../../pldm-sim/scenarios/gpu-terminus.json
${REJECT_SCENARIO}          ${CURDIR}/../../../../pldm-sim/scenarios/reject-update.json
${VERIFY_FAIL_SCENARIO}     ${CURDIR}/../../../../pldm-sim/scenarios/verify-failure-renode.json

*** Keywords ***
Create Base Machine
    [Documentation]    Create AST2600 machine without PldmFirmwareDevice
    Execute Command     mach create "ast2600"
    Execute Command     machine LoadPlatformDescription @platforms/boards/ast2600/ast2600-evb.repl
    # Load firmware into bootrom (0x0), flash backing store (0x60000000), and DRAM (0x88000000)
    Execute Command     sysbus LoadBinary @tests/peripherals/Aspeed/firmware/openbmc-image.bin 0x0
    Execute Command     sysbus LoadBinary @tests/peripherals/Aspeed/firmware/openbmc-image.bin 0x60000000
    Execute Command     sysbus LoadBinary @tests/peripherals/Aspeed/firmware/openbmc-image.bin 0x88000000
    # Silence unmapped peripheral regions to prevent driver probe hangs
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
    [Documentation]    Create PldmFirmwareDevice and connect to uart1
    [Arguments]    ${scenario}
    Execute Command     emulation CreatePldmFirmwareDevice "pldm_fd" "${scenario}"
    Execute Command     connector Connect uart1 pldm_fd
    Execute Command     logLevel -1 pldm_fd

Pause And Run For
    [Documentation]    Pause emulation then run for specified virtual time
    [Arguments]        ${time}
    Execute Command    pause
    Execute Command    emulation RunFor "${time}"

Boot And Login
    [Documentation]    Boot OpenBMC, interrupt autoboot, configure kernel, login
    Execute Command    emulation RunFor "5"
    Wait For Line On Uart    U-Boot SPL    timeout=30
    Wait For Line On Uart    autoboot    timeout=30    includeUnfinishedLine=true
    Write Line To Uart
    Wait For Line On Uart    ast#    timeout=10    includeUnfinishedLine=true
    Write Line To Uart    setenv bootargs console=ttyS4,115200n8 earlycon=uart8250,mmio32,0x1e784000,115200n8 nosmp maxcpus=1 panic=-1
    Wait For Line On Uart    ast#    timeout=10    includeUnfinishedLine=true
    Write Line To Uart    bootm 88100000
    Wait For Line On Uart    login:    timeout=300    includeUnfinishedLine=true
    # Advance virtual time for systemd services (Phosphor User Manager for PAM)
    Pause And Run For    60
    # Login
    Write Line To Uart    root
    Wait For Line On Uart    Password:    timeout=60    includeUnfinishedLine=true
    Write Line To Uart    0penBmc    waitForEcho=false
    Wait For Line On Uart    root@    timeout=60    includeUnfinishedLine=true

Configure MCTP
    [Documentation]    Set up MCTP serial link, address, route, and endpoint
    # mctp link serial blocks — must background it
    # Use waitForEcho=false throughout since Pause And Run For advances time
    Write Line To Uart    nohup mctp link serial /dev/ttyS0 &    waitForEcho=false
    Pause And Run For    3
    Write Line To Uart    mctp link set mctpserial0 up    waitForEcho=false
    Pause And Run For    1
    Write Line To Uart    mctp addr add 8 dev mctpserial0    waitForEcho=false
    Pause And Run For    1
    Write Line To Uart    mctp route add 20 via mctpserial0    waitForEcho=false
    Pause And Run For    1
    # Assign endpoint — PldmFirmwareDevice responds to SetEID/GetEID
    # Long commands use waitForEcho=false to avoid garbled echo match failures
    Write Line To Uart    busctl call au.com.codeconstruct.MCTP1 /au/com/codeconstruct/mctp1/interfaces/mctpserial0 au.com.codeconstruct.MCTP.BusOwner1 AssignEndpointStatic ayy 0 20    waitForEcho=false
    Pause And Run For    10

Start Pldmd
    [Documentation]    Start pldmd and verify it is running
    Write Line To Uart    systemctl start pldmd    waitForEcho=false
    Pause And Run For    30
    Write Line To Uart    systemctl is-active pldmd && echo PLDMD_OK || echo PLDMD_FAIL    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    PLDMD    timeout=30    includeUnfinishedLine=true

Transfer Firmware Package
    [Documentation]    Transfer firmware package to guest via printf hex escapes
    # Each chunk: 200 bytes = 800 hex chars, ~850 total cmd chars (under 1024 ash limit)
    ${data}=    Evaluate    list(open(r'${FW_PKG}', 'rb').read())
    ${total}=    Evaluate    len($data)
    ${num_chunks}=    Evaluate    ($total + 199) // 200
    FOR    ${i}    IN RANGE    ${num_chunks}
        ${start}=    Evaluate    $i * 200
        ${end}=      Evaluate    min($start + 200, $total)
        ${hex}=      Evaluate    ''.join([rf'\\x{b:02x}' for b in $data[$start:$end]])
        ${op}=       Set Variable If    ${i} == 0    >    >>
        Write Line To Uart    printf '${hex}' ${op} /tmp/test_fw_pkg.pldm    waitForEcho=false
        Pause And Run For    2
    END
    # Verify file size
    Write Line To Uart    wc -c < /tmp/test_fw_pkg.pldm    waitForEcho=false
    Pause And Run For    2
    Wait For Line On Uart    ${total}    timeout=30    includeUnfinishedLine=true

Trigger Firmware Update
    [Documentation]    Trigger firmware update via D-Bus StartUpdate call
    Write Line To Uart    exec 5</tmp/test_fw_pkg.pldm && busctl call xyz.openbmc_project.PLDM /xyz/openbmc_project/software/pldm xyz.openbmc_project.Software.Update StartUpdate hs 5 xyz.openbmc_project.Software.ApplyTime.RequestedApplyTimes.Immediate && exec 5<&-    waitForEcho=false
    Pause And Run For    120

Assert Journal Contains
    [Documentation]    Assert pldmd journal contains a pattern
    [Arguments]    ${pattern}    ${marker}
    Write Line To Uart    journalctl -u pldmd --no-pager | grep -q "${pattern}" && echo ${marker}_YES || echo ${marker}_NO    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    ${marker}_YES    timeout=30    includeUnfinishedLine=true

Assert Journal Does Not Contain
    [Documentation]    Assert pldmd journal does NOT contain a pattern
    [Arguments]    ${pattern}    ${marker}
    Write Line To Uart    journalctl -u pldmd --no-pager | grep -q "${pattern}" && echo ${marker}_YES || echo ${marker}_NO    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    ${marker}_NO    timeout=30    includeUnfinishedLine=true

*** Test Cases ***
Should Boot And Login To OpenBMC
    [Documentation]    Boot OpenBMC and login, save state for subsequent tests
    [Tags]             pldm    boot
    Create Base Machine
    Boot And Login
    Execute Command    pause
    Provides           booted-state

Should Complete PLDM Firmware Update
    [Documentation]    Happy path: single-component firmware update succeeds
    [Tags]             pldm    firmware-update
    Requires           booted-state
    Attach PLDM Device    ${DEFAULT_SCENARIO}
    Configure MCTP
    Start Pldmd
    Transfer Firmware Package
    Trigger Firmware Update
    Assert Journal Contains    Firmware update time    FW_TIME

Should Handle Component Rejection
    [Documentation]    pldmd handles rejected component and updates accepted one
    [Tags]             pldm    reject
    Requires           booted-state
    Attach PLDM Device    ${REJECT_SCENARIO}
    Configure MCTP
    Start Pldmd
    Transfer Firmware Package
    Trigger Firmware Update
    # Component 100 should be rejected
    Assert Journal Contains    cannot be updated, response code    REJECT
    # Component 200 should complete successfully
    Assert Journal Contains    Firmware update time    FW_TIME

Should Handle Verify Failure
    [Documentation]    pldmd handles firmware verification failure
    [Tags]             pldm    verify-failure
    Requires           booted-state
    Attach PLDM Device    ${VERIFY_FAIL_SCENARIO}
    Configure MCTP
    Start Pldmd
    Transfer Firmware Package
    Trigger Firmware Update
    # Verify failure should be logged
    Assert Journal Contains    Failed to verify component    VERIFY_FAIL
    # Update should NOT have completed
    Assert Journal Does Not Contain    Firmware update time    FW_TIME
