*** Comments ***
# AST2600 PLDM Firmware Update E2E Test
# Boots OpenBMC, sets up MCTP serial, runs firmware update
#
# Uses Renode-internal PldmFirmwareDevice — no sudo, no external process,
# deterministic virtual time via emulation RunFor.
#
# NOTE: emulation RunFor requires the emulation to be paused (IsStarted=false).
# Wait For Line On Uart starts the emulation and leaves it running.
# Must call "pause" before each RunFor after any Wait For Line On Uart.
#
# All phases in one test case because PldmFirmwareDevice does not survive
# Renode's snapshot serialization used by Provides/Requires.

*** Settings ***
Suite Setup         Setup
Suite Teardown      Teardown

*** Variables ***
${UART5}            sysbus.uart5
${FW_PKG}          ${CURDIR}/../../../../pldm-sim/test_fw_pkg.pldm
${SCENARIO}        ${CURDIR}/../../../../pldm-sim/scenarios/gpu-terminus.json

*** Keywords ***
Create PLDM Test Machine
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
    # PLDM firmware device on UART1 (/dev/ttyS0 in guest)
    Execute Command     emulation CreatePldmFirmwareDevice "pldm_fd" "${SCENARIO}"
    Execute Command     connector Connect uart1 pldm_fd
    # Enable verbose logging on the PLDM device
    Execute Command     logLevel -1 pldm_fd
    Create Terminal Tester    ${UART5}    timeout=120

Pause And Run For
    [Documentation]    Pause emulation then run for specified virtual time
    [Arguments]        ${time}
    Execute Command    pause
    Execute Command    emulation RunFor "${time}"

*** Test Cases ***
Should Complete PLDM Firmware Update
    [Documentation]    Boot, login, set up MCTP, start pldmd, run firmware update
    [Tags]             pldm    boot    mctp    firmware-update
    # === Phase 1: Boot and login ===
    Create PLDM Test Machine
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

    # === Phase 2: Set up MCTP serial ===
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

    # === Phase 3: Start pldmd and verify discovery ===
    Write Line To Uart    systemctl start pldmd    waitForEcho=false
    Pause And Run For    30
    # Verify pldmd is running
    Write Line To Uart    systemctl is-active pldmd && echo PLDMD_OK || echo PLDMD_FAIL    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    PLDMD    timeout=30    includeUnfinishedLine=true

    # === Phase 4: Firmware update ===
    # Transfer firmware package via printf hex escapes (no base64 on this image)
    # Each chunk: 200 bytes = 800 hex chars, ~850 total cmd chars (under 1024 ash limit)
    ${data}=    Evaluate    list(open(r'${FW_PKG}', 'rb').read())
    ${total}=    Evaluate    len($data)
    ${hex0}=     Evaluate    ''.join([rf'\\x{b:02x}' for b in $data[0:200]])
    Write Line To Uart    printf '${hex0}' > /tmp/test_fw_pkg.pldm    waitForEcho=false
    Pause And Run For    2
    ${hex1}=     Evaluate    ''.join([rf'\\x{b:02x}' for b in $data[200:400]])
    Write Line To Uart    printf '${hex1}' >> /tmp/test_fw_pkg.pldm    waitForEcho=false
    Pause And Run For    2
    ${hex2}=     Evaluate    ''.join([rf'\\x{b:02x}' for b in $data[400:600]])
    Write Line To Uart    printf '${hex2}' >> /tmp/test_fw_pkg.pldm    waitForEcho=false
    Pause And Run For    2
    ${hex3}=     Evaluate    ''.join([rf'\\x{b:02x}' for b in $data[600:800]])
    Write Line To Uart    printf '${hex3}' >> /tmp/test_fw_pkg.pldm    waitForEcho=false
    Pause And Run For    2
    ${hex4}=     Evaluate    ''.join([rf'\\x{b:02x}' for b in $data[800:1000]])
    Write Line To Uart    printf '${hex4}' >> /tmp/test_fw_pkg.pldm    waitForEcho=false
    Pause And Run For    2
    ${hex5}=     Evaluate    ''.join([rf'\\x{b:02x}' for b in $data[1000:1200]])
    Write Line To Uart    printf '${hex5}' >> /tmp/test_fw_pkg.pldm    waitForEcho=false
    Pause And Run For    2
    ${hex6}=     Evaluate    ''.join([rf'\\x{b:02x}' for b in $data[1200:1400]])
    Write Line To Uart    printf '${hex6}' >> /tmp/test_fw_pkg.pldm    waitForEcho=false
    Pause And Run For    2
    ${hex7}=     Evaluate    ''.join([rf'\\x{b:02x}' for b in $data[1400:1600]])
    Write Line To Uart    printf '${hex7}' >> /tmp/test_fw_pkg.pldm    waitForEcho=false
    Pause And Run For    2
    ${hex8}=     Evaluate    ''.join([rf'\\x{b:02x}' for b in $data[1600:1800]])
    Write Line To Uart    printf '${hex8}' >> /tmp/test_fw_pkg.pldm    waitForEcho=false
    Pause And Run For    2
    ${hex9}=     Evaluate    ''.join([rf'\\x{b:02x}' for b in $data[1800:2000]])
    Write Line To Uart    printf '${hex9}' >> /tmp/test_fw_pkg.pldm    waitForEcho=false
    Pause And Run For    2
    ${hex10}=    Evaluate    ''.join([rf'\\x{b:02x}' for b in $data[2000:2200]])
    Write Line To Uart    printf '${hex10}' >> /tmp/test_fw_pkg.pldm    waitForEcho=false
    Pause And Run For    2
    ${hex11}=    Evaluate    ''.join([rf'\\x{b:02x}' for b in $data[2200:]])
    Write Line To Uart    printf '${hex11}' >> /tmp/test_fw_pkg.pldm    waitForEcho=false
    Pause And Run For    2
    # Verify file size
    Write Line To Uart    wc -c < /tmp/test_fw_pkg.pldm    waitForEcho=false
    Pause And Run For    2
    Wait For Line On Uart    ${total}    timeout=30    includeUnfinishedLine=true
    # Trigger firmware update via D-Bus
    Write Line To Uart    exec 5</tmp/test_fw_pkg.pldm && busctl call xyz.openbmc_project.PLDM /xyz/openbmc_project/software/pldm xyz.openbmc_project.Software.Update StartUpdate hs 5 xyz.openbmc_project.Software.ApplyTime.RequestedApplyTimes.Immediate && exec 5<&-    waitForEcho=false
    Pause And Run For    120
    # Check pldmd journal for successful update
    Write Line To Uart    journalctl -u pldmd --no-pager | tail -40    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    Firmware update time    timeout=60    includeUnfinishedLine=true
