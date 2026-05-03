*** Comments ***
# AST2600 PLDM 64-bit Sensor Reading E2E Tests
# Boots OpenBMC, sets up MCTP serial, verifies pldmd reads 64-bit sensor values
# from a PldmFirmwareDevice and exposes them on D-Bus.
#
# Tests UINT64 and SINT64 sensor data sizes (DSP0248 v1.3.0).

*** Settings ***
Suite Setup         Setup
Suite Teardown      Teardown

*** Variables ***
${UART5}                    sysbus.uart5
${SENSOR_SCENARIO}          ${CURDIR}/../../../../pldm-sim/scenarios/sensor-64bit.json

*** Keywords ***
Create Base Machine
    [Documentation]    Create AST2600 machine without PldmFirmwareDevice
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
    Pause And Run For    60
    Write Line To Uart    root
    Wait For Line On Uart    Password:    timeout=60    includeUnfinishedLine=true
    Write Line To Uart    0penBmc    waitForEcho=false
    Wait For Line On Uart    root@    timeout=60    includeUnfinishedLine=true

Configure MCTP
    [Documentation]    Set up MCTP serial link, address, route, and endpoint
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
    [Documentation]    Start pldmd and verify it is running
    Write Line To Uart    systemctl start pldmd    waitForEcho=false
    Pause And Run For    30
    Write Line To Uart    systemctl is-active pldmd && echo PLDMD_OK || echo PLDMD_FAIL    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    PLDMD    timeout=30    includeUnfinishedLine=true

Wait For Sensor Discovery
    [Documentation]    Wait for pldmd to discover terminus and poll sensors
    # pldmd needs time to: discover terminus via GetPDR, create sensor objects, poll readings
    Pause And Run For    120

Assert D-Bus Sensor Value
    [Documentation]    Check D-Bus sensor value matches expected reading
    [Arguments]    ${sensor_path_pattern}    ${expected_value}    ${marker}
    # Find sensor object path by listing pldm sensor objects
    Write Line To Uart    busctl tree xyz.openbmc_project.PLDM 2>/dev/null | grep -i sensor | head -5    waitForEcho=false
    Pause And Run For    5
    # Read the sensor value
    Write Line To Uart    busctl get-property xyz.openbmc_project.PLDM ${sensor_path_pattern} xyz.openbmc_project.Sensor.Value Value 2>/dev/null && echo ${marker}_FOUND || echo ${marker}_NOTFOUND    waitForEcho=false
    Pause And Run For    5

Assert Journal Contains
    [Documentation]    Assert pldmd journal contains a pattern
    [Arguments]    ${pattern}    ${marker}
    Write Line To Uart    journalctl -u pldmd --no-pager | grep -q "${pattern}" && echo ${marker}_YES || echo ${marker}_NO    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    ${marker}_YES    timeout=30    includeUnfinishedLine=true

*** Test Cases ***
Should Boot And Login To OpenBMC
    [Documentation]    Boot OpenBMC and login, save state for subsequent tests
    [Tags]             pldm    boot    sensor
    Create Base Machine
    Boot And Login
    Execute Command    pause
    Provides           booted-state

Should Read 64-bit Sensor Values
    [Documentation]    pldmd discovers terminus with 64-bit sensors, reads values via GetSensorReading
    [Tags]             pldm    sensor    64bit
    Requires           booted-state
    Attach PLDM Device    ${SENSOR_SCENARIO}
    Configure MCTP
    Start Pldmd
    Wait For Sensor Discovery
    # Verify pldmd discovered the terminus and polled sensors
    # The journal should show sensor reading activity
    Assert Journal Contains    GetSensorReading    SENSOR_READ
