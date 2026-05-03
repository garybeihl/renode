*** Comments ***
# AST2600 SPDM Attestation E2E Tests
# Boots OpenBMC, sets up MCTP serial, attaches SpdmResponderDevice,
# and verifies spdmd completes the full SPDM 1.2 attestation flow.
#
# Uses Renode-internal SpdmResponderDevice — no sudo, no external process,
# deterministic virtual time via emulation RunFor.
#
# NOTE: emulation RunFor requires the emulation to be paused (IsStarted=false).
# Wait For Line On Uart starts the emulation and leaves it running.
# Must call "pause" before each RunFor after any Wait For Line On Uart.
#
# Boot/login state is snapshotted via Provides/Requires.  SpdmResponderDevice
# does not survive serialization, so it is attached after each Requires restore.
#
# UART RX duplication symptom (e.g. "Componeent", "AssignEnndpointStatic")
# is the BMC kernel's TTY soft line-wrap at column 80 — the kernel echoes
# `<char>[CR]<char>` when the cursor would push past col 80, and TerminalTester
# drops the bare CR (TreatLineFeedAsEndLine), leaving spurious duplicate chars
# in the captured line buffer. The `stty cols 1000` issued in Boot And Login
# disables this soft-wrap so long shell lines (curl POSTs, busctl, etc.) echo
# cleanly. See ~/.claude/.../memory/feedback-renode-tty-soft-wrap.md.

*** Settings ***
Suite Setup         Setup
Suite Teardown      Teardown

*** Variables ***
${UART5}                    sysbus.uart5
${SPDM_SCENARIO}            ${CURDIR}/spdm-scenarios/scenario.json
${SPDM_BAD_KEY_SCENARIO}    ${CURDIR}/spdm-scenarios/scenario-bad-key.json
${SPDM_SCENARIO_2}              ${CURDIR}/spdm-scenarios/scenario-2.json
${SPDM_SCENARIO_2_BAD_KEY}      ${CURDIR}/spdm-scenarios/scenario-2-bad-key.json
${SPDM_SCENARIO_MID_DISCONNECT}    ${CURDIR}/spdm-scenarios/scenario-mid-disconnect.json
${SPDM_SCENARIO_LARGE_CHAIN}       ${CURDIR}/spdm-scenarios/scenario-large-chain.json
${SPDM_SCENARIO_MULTI_MEAS}        ${CURDIR}/spdm-scenarios/scenario-multi-meas.json
${SPDM_SCENARIO_V11}               ${CURDIR}/spdm-scenarios/scenario-v11.json
${SPDM_SCENARIO_SMALL_CHUNK}       ${CURDIR}/spdm-scenarios/scenario-small-chunk.json
${SPDM_SCENARIO_NO_SPDM}          ${CURDIR}/spdm-scenarios/scenario-no-spdm.json

*** Keywords ***
Create Base Machine
    [Documentation]    Create AST2600 machine without SpdmResponderDevice
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
    # Enable VFP so ECDSA-P256 signature verification works (OpenSSL uses VFP instructions)
    Execute Command     cpu0 FpuEnabled true
    Create Terminal Tester    ${UART5}    timeout=120

Attach SPDM Device
    [Documentation]    Create SpdmResponderDevice and connect to a UART
    [Arguments]    ${scenario}=${SPDM_SCENARIO}    ${name}=spdm_dev    ${uart}=uart1
    Execute Command     emulation CreateSpdmResponderDevice "${name}" @${scenario}
    Execute Command     connector Connect ${uart} ${name}
    Execute Command     logLevel -1 ${name}

Pause And Run For
    [Documentation]    Pause emulation then run for specified virtual time
    [Arguments]        ${time}
    Execute Command    pause
    Execute Command    emulation RunFor "${time}"

Boot And Login
    [Documentation]    Boot OpenBMC, interrupt autoboot, configure kernel, login
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
    # Disable kernel TTY soft line-wrap at column 80. Without this, the kernel
    # echoes <char>[CR]<char> on input that pushes the cursor past column 80,
    # and TerminalTester drops the CR (TreatLineFeedAsEndLine), leaving the
    # captured line buffer with spurious duplicate chars ("Componeent",
    # "AssignEnndpointStatic", "TrransferComplete", "codeconnstruct"). cols=1000
    # is plenty for any realistic test command. See memory note
    # feedback-renode-tty-soft-wrap.md for the full diagnosis.
    Write Line To Uart    stty cols 1000    waitForEcho=false
    Pause And Run For    2

Configure MCTP
    [Documentation]    Set up MCTP serial link on /dev/ttyS0 with EID 20
    Configure MCTP Link    /dev/ttyS0    mctpserial0    8    20

Configure MCTP Link
    [Documentation]    Set up MCTP serial link, address, route, and endpoint
    [Arguments]    ${serial_dev}    ${link_name}    ${local_eid}    ${remote_eid}
    Write Line To Uart    nohup mctp link serial ${serial_dev} &    waitForEcho=false
    Pause And Run For    3
    Write Line To Uart    mctp link set ${link_name} up    waitForEcho=false
    Pause And Run For    1
    Write Line To Uart    mctp addr add ${local_eid} dev ${link_name}    waitForEcho=false
    Pause And Run For    1
    Write Line To Uart    mctp route add ${remote_eid} via ${link_name}    waitForEcho=false
    Pause And Run For    1
    Write Line To Uart    busctl call au.com.codeconstruct.MCTP1 /au/com/codeconstruct/mctp1/interfaces/${link_name} au.com.codeconstruct.MCTP.BusOwner1 AssignEndpointStatic ayy 0 ${remote_eid}    waitForEcho=false
    Pause And Run For    10

Start Spdmd
    [Documentation]    Restart spdmd to trigger fresh discovery of the newly configured endpoint
    [Arguments]    ${timeout}=30
    Write Line To Uart    systemctl restart spdmd    waitForEcho=false
    Pause And Run For    ${timeout}
    Write Line To Uart    systemctl is-active spdmd && echo SPDMD_OK || echo SPDMD_FAIL    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    SPDMD    timeout=30    includeUnfinishedLine=true

Dump Spdmd Journal
    [Documentation]    Dump last 20 lines of spdmd journal for debugging
    Write Line To Uart    echo JRNL_START; journalctl -u spdmd --no-pager -n 20; echo JRNL_END    waitForEcho=false
    Pause And Run For    10
    Wait For Line On Uart    JRNL_END    timeout=30    includeUnfinishedLine=true

Assert Spdmd Journal Contains
    [Documentation]    Assert spdmd journal contains a pattern
    [Arguments]    ${pattern}    ${marker}
    Write Line To Uart    echo ${marker}_$(journalctl -u spdmd --no-pager | grep -q "${pattern}" && echo Y || echo N)    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    ${marker}_Y    timeout=30    includeUnfinishedLine=true

Assert Spdmd Journal Does Not Contain
    [Documentation]    Assert spdmd journal does NOT contain a pattern
    [Arguments]    ${pattern}    ${marker}
    Write Line To Uart    echo ${marker}_$(journalctl -u spdmd --no-pager | grep -q "${pattern}" && echo Y || echo N)    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    ${marker}_N    timeout=30    includeUnfinishedLine=true

Assert Dbus ComponentIntegrity
    [Documentation]    Query D-Bus ComponentIntegrity properties via busctl
    [Arguments]    ${eid}=20    ${expected_status}=Success    ${expected_version}=1.2
    ${ci_path}    Set Variable    /xyz/openbmc_project/component_integrity/${eid}
    ${ci_intf}    Set Variable    xyz.openbmc_project.Attestation.ComponentIntegrity
    ${ia_intf}    Set Variable    xyz.openbmc_project.Attestation.IdentityAuthentication
    ${svc}        Set Variable    xyz.openbmc_project.spdmd
    Write Line To Uart    busctl get-property ${svc} ${ci_path} ${ci_intf} Type    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    .SPDM    timeout=30    includeUnfinishedLine=true
    Write Line To Uart    busctl get-property ${svc} ${ci_path} ${ci_intf} TypeVersion    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    ${expected_version}    timeout=30    includeUnfinishedLine=true
    Write Line To Uart    busctl get-property ${svc} ${ci_path} ${ia_intf} ResponderVerificationStatus    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    .${expected_status}    timeout=30    includeUnfinishedLine=true

Assert Redfish ComponentIntegrity
    [Documentation]    Verify Redfish ComponentIntegrity endpoint via curl
    [Arguments]    ${eid}=20    ${expected_status}=Success
    Write Line To Uart    echo RFCOL_$(curl -sk -u root:0penBmc https://localhost/redfish/v1/ComponentIntegrity | grep -q 'Members@odata.count' && echo Y || echo N)    waitForEcho=false
    Pause And Run For    10
    Wait For Line On Uart    RFCOL_Y    timeout=30    includeUnfinishedLine=true
    Write Line To Uart    echo RFTYPE_$(curl -sk -u root:0penBmc https://localhost/redfish/v1/ComponentIntegrity/${eid} | grep -q 'ComponentIntegrityType' && echo Y || echo N)    waitForEcho=false
    Pause And Run For    10
    Wait For Line On Uart    RFTYPE_Y    timeout=30    includeUnfinishedLine=true
    Write Line To Uart    echo RFVS_$(curl -sk -u root:0penBmc https://localhost/redfish/v1/ComponentIntegrity/${eid} | grep -q '${expected_status}' && echo Y || echo N)    waitForEcho=false
    Pause And Run For    10
    Wait For Line On Uart    RFVS_Y    timeout=30    includeUnfinishedLine=true

Assert Redfish Signed Measurements
    [Documentation]    POST to SPDMGetSignedMeasurements action and verify response contains a non-empty SignedMeasurements field.
    [Arguments]    ${marker}=SIGMEAS    ${eid}=20
    POST Signed Measurements    {"MeasurementIndices":[255],"Nonce":"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff","SlotId":0}    ${eid}
    Assert Signed Measurements Non-Empty    ${marker}

POST Signed Measurements
    [Documentation]    Write the JSON body to a file then POST it.
    [Arguments]    ${body}    ${eid}=20
    ${url}    Set Variable    https://localhost/redfish/v1/ComponentIntegrity/${eid}/Actions/ComponentIntegrity.SPDMGetSignedMeasurements
    Write Line To Uart    printf '%s' '${body}' > /tmp/body.json    waitForEcho=false
    Pause And Run For    3
    Write Line To Uart    curl -sk -u root:0penBmc -X POST -H 'Content-Type: application/json' -d @/tmp/body.json -o /tmp/r ${url}    waitForEcho=false
    Pause And Run For    30

Assert Signed Measurements Non-Empty
    [Documentation]    Verify the last POST response has a non-empty SignedMeasurements field
    [Arguments]    ${marker}
    Write Line To Uart    test ! -s /tmp/r && echo ${marker}_NOFILE || (grep -q '"SignedMeasurements":""' /tmp/r && echo ${marker}_EMPTY || echo ${marker}_NONEMPTY)    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    ${marker}_NONEMPTY    timeout=30    includeUnfinishedLine=true

Dump Response Body
    [Documentation]    Print the last response body for debugging
    [Arguments]    ${marker}
    Write Line To Uart    echo ${marker}_BODY_START; cat /tmp/r; echo ${marker}_BODY_END    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    ${marker}_BODY_END    timeout=30    includeUnfinishedLine=true

Assert Redfish Error
    [Documentation]    Verify the last POST response is a Redfish error.
    [Arguments]    ${marker}
    Write Line To Uart    echo ${marker}_$(grep -q '"@Message.ExtendedInfo"' /tmp/r && echo OK || echo BAD)    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    ${marker}_OK    timeout=30    includeUnfinishedLine=true

*** Test Cases ***
Should Boot And Login To OpenBMC
    [Documentation]    Boot OpenBMC and login, save state for subsequent tests
    [Tags]             spdm    boot
    Create Base Machine
    Boot And Login
    Execute Command    pause
    Provides           booted-state

Should Complete SPDM Attestation
    [Documentation]    Attach SpdmResponderDevice, configure MCTP, restart spdmd, verify attestation passes and Redfish reports success
    [Tags]             spdm    attestation
    Requires           booted-state
    Attach SPDM Device
    Configure MCTP
    Start Spdmd
    Dump Spdmd Journal
    Assert Spdmd Journal Contains    attestation PASSED    ATTEST
    Assert Dbus ComponentIntegrity    expected_status=Success
    Assert Redfish ComponentIntegrity    expected_status=Success

Should Get Signed Measurements Via Redfish
    [Documentation]    After eager attestation, POST SPDMGetSignedMeasurements via Redfish and verify the response contains signed measurements.
    [Tags]             spdm    attestation    measurements    redfish
    Requires           booted-state
    Attach SPDM Device
    Configure MCTP
    Start Spdmd
    Assert Spdmd Journal Contains    attestation PASSED    SMEAS_ATTEST
    Assert Redfish Signed Measurements

Should Get Signed Measurements With Variations
    [Documentation]    Exercise SPDMGetSignedMeasurements with several valid argument variations.
    [Tags]             spdm    attestation    measurements    redfish
    Requires           booted-state
    Attach SPDM Device
    Configure MCTP
    Start Spdmd
    Assert Spdmd Journal Contains    attestation PASSED    VAR_ATTEST
    POST Signed Measurements    {"MeasurementIndices":[1],"Nonce":"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff","SlotId":0}
    Assert Signed Measurements Non-Empty    VAR_IDX1
    POST Signed Measurements    {"MeasurementIndices":[1,2],"Nonce":"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff","SlotId":0}
    Assert Signed Measurements Non-Empty    VAR_IDX12
    POST Signed Measurements    {"MeasurementIndices":[],"Nonce":"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff","SlotId":0}
    Assert Signed Measurements Non-Empty    VAR_EMPTY

Should Reject Invalid Signed Measurements Requests
    [Documentation]    Exercise SPDMGetSignedMeasurements with invalid arguments.
    [Tags]             spdm    attestation    measurements    redfish    failure
    Requires           booted-state
    Attach SPDM Device
    Configure MCTP
    Start Spdmd
    Assert Spdmd Journal Contains    attestation PASSED    REJ_ATTEST
    POST Signed Measurements    {"MeasurementIndices":[255],"Nonce":"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeffEXTRA","SlotId":0}
    Assert Redfish Error    REJ_LONG
    POST Signed Measurements    {"MeasurementIndices":[255],"Nonce":"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff","SlotId":99}
    Assert Redfish Error    REJ_SLOT
    POST Signed Measurements    {"MeasurementIndices":[255],"Nonce":"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff","SlotId":1}
    Assert Redfish Error    REJ_SLOT1

Should Fail Attestation With Wrong Key
    [Documentation]    Responder signs with wrong private key, spdmd signature verification fails, Redfish reports failure
    [Tags]             spdm    attestation    failure
    Requires           booted-state
    Attach SPDM Device    ${SPDM_BAD_KEY_SCENARIO}
    Configure MCTP
    Start Spdmd
    Assert Spdmd Journal Contains             attestation FAILED    ATTEST_FAIL
    Assert Spdmd Journal Does Not Contain     attestation PASSED    ATTEST_PASS
    Assert Dbus ComponentIntegrity    expected_status=Failed
    Assert Redfish ComponentIntegrity    expected_status=Failed

Should Handle Unreachable Device
    [Documentation]    Endpoint registered but device disconnected before SPDM — spdmd handles timeout gracefully
    [Tags]             spdm    attestation    failure
    Requires           booted-state
    Attach SPDM Device
    Configure MCTP
    Execute Command     connector Disconnect uart1 spdm_dev
    Start Spdmd    timeout=60
    Assert Spdmd Journal Contains             attestation FAILED    ATTEST_UNREACH
    Assert Spdmd Journal Does Not Contain     attestation PASSED    ATTEST_NOPASS
    Write Line To Uart    systemctl is-active spdmd && echo ALIVE_Y || echo ALIVE_N    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    ALIVE_Y    timeout=30    includeUnfinishedLine=true
    Assert Dbus ComponentIntegrity    20    Failed    1.1
    Assert Redfish ComponentIntegrity    20    Failed

Should Attest Multiple Endpoints
    [Documentation]    Two SpdmResponderDevices on uart1 and uart2, both attested successfully
    [Tags]             spdm    attestation    multi
    Requires           booted-state
    Attach SPDM Device    ${SPDM_SCENARIO}      spdm_dev1    uart1
    Attach SPDM Device    ${SPDM_SCENARIO_2}    spdm_dev2    uart2
    Configure MCTP Link    /dev/ttyS0    mctpserial0    8    20
    Configure MCTP Link    /dev/ttyS1    mctpserial1    9    21
    Start Spdmd    timeout=180
    Write Line To Uart    echo ATTEST_CNT_$(journalctl -u spdmd --no-pager | grep -c "attestation PASSED")    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    ATTEST_CNT_2    timeout=30    includeUnfinishedLine=true
    Assert Spdmd Journal Does Not Contain    attestation FAILED    ATTEST_NOFAIL
    Assert Dbus ComponentIntegrity    eid=20    expected_status=Success
    Assert Dbus ComponentIntegrity    eid=21    expected_status=Success
    Assert Redfish ComponentIntegrity    eid=20    expected_status=Success
    Assert Redfish ComponentIntegrity    eid=21    expected_status=Success

Should Handle Mixed Attestation Results
    [Documentation]    One valid device and one bad-key device — failure on one must not affect the other
    [Tags]             spdm    attestation    multi    failure
    Requires           booted-state
    Attach SPDM Device    ${SPDM_SCENARIO}              spdm_dev1    uart1
    Attach SPDM Device    ${SPDM_SCENARIO_2_BAD_KEY}    spdm_dev2    uart2
    Configure MCTP Link    /dev/ttyS0    mctpserial0    8    20
    Configure MCTP Link    /dev/ttyS1    mctpserial1    9    21
    Start Spdmd    timeout=180
    Write Line To Uart    echo MIXPASS_$(journalctl -u spdmd --no-pager | grep -c "attestation PASSED")    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    MIXPASS_1    timeout=30    includeUnfinishedLine=true
    Write Line To Uart    echo MIXFAIL_$(journalctl -u spdmd --no-pager | grep -c "attestation FAILED")    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    MIXFAIL_1    timeout=30    includeUnfinishedLine=true
    Assert Dbus ComponentIntegrity    eid=20    expected_status=Success
    Assert Dbus ComponentIntegrity    eid=21    expected_status=Failed
    Assert Redfish ComponentIntegrity    eid=20    expected_status=Success
    Assert Redfish ComponentIntegrity    eid=21    expected_status=Failed

Should Handle Mid-Flow Disconnect
    [Documentation]    Device responds to first 3 SPDM messages then stops — spdmd handles timeout gracefully
    [Tags]             spdm    attestation    failure
    Requires           booted-state
    Attach SPDM Device    ${SPDM_SCENARIO_MID_DISCONNECT}
    Configure MCTP
    Start Spdmd    timeout=60
    Assert Spdmd Journal Contains             attestation FAILED    ATTEST_MID
    Assert Spdmd Journal Does Not Contain     attestation PASSED    ATTEST_NOMID
    Write Line To Uart    systemctl is-active spdmd && echo MIDOK_Y || echo MIDOK_N    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    MIDOK_Y    timeout=30    includeUnfinishedLine=true
    Assert Dbus ComponentIntegrity    expected_status=Failed
    Assert Redfish ComponentIntegrity    expected_status=Failed

Should Re-Attest On Spdmd Restart
    [Documentation]    Restart spdmd after successful attestation — D-Bus and Redfish objects are recreated
    [Tags]             spdm    attestation
    Requires           booted-state
    Attach SPDM Device
    Configure MCTP
    Start Spdmd
    Assert Spdmd Journal Contains    attestation PASSED    ATTEST1
    Assert Dbus ComponentIntegrity    expected_status=Success
    Start Spdmd
    Write Line To Uart    echo REATTEST_$(journalctl -u spdmd --no-pager | grep -c "attestation PASSED")    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    REATTEST_2    timeout=30    includeUnfinishedLine=true
    Assert Dbus ComponentIntegrity    expected_status=Success
    Assert Redfish ComponentIntegrity    expected_status=Success

Should Attest With Large Certificate Chain
    [Documentation]    5-cert chain (3739 bytes DER) — exercises MCTP multi-packet fragmentation with sequence wrapping
    [Tags]             spdm    attestation    fragmentation
    Requires           booted-state
    Attach SPDM Device    ${SPDM_SCENARIO_LARGE_CHAIN}
    Configure MCTP
    Start Spdmd
    Assert Spdmd Journal Contains    attestation PASSED    ATTEST_LARGE
    Assert Dbus ComponentIntegrity    expected_status=Success
    Assert Redfish ComponentIntegrity    expected_status=Success

Should Attest With Multiple Measurements
    [Documentation]    Device reports 5 measurements of 4 different types — exercises GET_MEASUREMENTS with larger record
    [Tags]             spdm    attestation    measurements
    Requires           booted-state
    Attach SPDM Device    ${SPDM_SCENARIO_MULTI_MEAS}
    Configure MCTP
    Start Spdmd
    Assert Spdmd Journal Contains    attestation PASSED    ATTEST_MMEAS
    Assert Dbus ComponentIntegrity    expected_status=Success
    Assert Redfish ComponentIntegrity    expected_status=Success

Should Attest With SPDM 1.1 Only Device
    [Documentation]    Device advertises only SPDM 1.1 — spdmd downgrades and completes attestation (no signing prefix)
    [Tags]             spdm    attestation    version
    Requires           booted-state
    Attach SPDM Device    ${SPDM_SCENARIO_V11}
    Configure MCTP
    Start Spdmd
    Assert Spdmd Journal Contains    attestation PASSED    ATTEST_V11
    Assert Dbus ComponentIntegrity    20    Success    1.1
    Assert Redfish ComponentIntegrity    expected_status=Success

Should Attest With Small Certificate Chunks
    [Documentation]    Device limits GET_CERTIFICATE to 64 bytes/chunk — spdmd retrieves full 1390-byte chain in ~22 round-trips
    [Tags]             spdm    attestation    fragmentation
    Requires           booted-state
    Attach SPDM Device    ${SPDM_SCENARIO_SMALL_CHUNK}
    Configure MCTP
    Start Spdmd
    Assert Spdmd Journal Contains    attestation PASSED    ATTEST_SMALL
    Assert Dbus ComponentIntegrity    expected_status=Success
    Assert Redfish ComponentIntegrity    expected_status=Success

Should Recover After Failed Attestation
    [Documentation]    Bad-key device fails attestation; swap to good device and restart spdmd — attestation passes
    [Tags]             spdm    attestation    recovery
    Requires           booted-state
    Attach SPDM Device    ${SPDM_BAD_KEY_SCENARIO}
    Configure MCTP
    Start Spdmd
    Assert Spdmd Journal Contains             attestation FAILED    REC_FAIL
    Assert Spdmd Journal Does Not Contain     attestation PASSED    REC_NOPASS
    Assert Dbus ComponentIntegrity    expected_status=Failed
    Execute Command     connector Disconnect uart1 spdm_dev
    Attach SPDM Device    ${SPDM_SCENARIO}    spdm_dev_good    uart1
    Start Spdmd
    Assert Spdmd Journal Contains    attestation PASSED    REC_PASS
    Assert Dbus ComponentIntegrity    expected_status=Success
    Assert Redfish ComponentIntegrity    expected_status=Success

Should Skip Endpoint Without SPDM Support
    [Documentation]    Control-only device (no SPDM type) is skipped; SPDM device on second UART attests normally
    [Tags]             spdm    attestation    discovery
    Requires           booted-state
    Attach SPDM Device    ${SPDM_SCENARIO_NO_SPDM}    nospdm_dev    uart1
    Attach SPDM Device    ${SPDM_SCENARIO_2}          spdm_dev2    uart2
    Configure MCTP Link    /dev/ttyS0    mctpserial0    8    23
    Configure MCTP Link    /dev/ttyS1    mctpserial1    9    21
    Start Spdmd    timeout=180
    Write Line To Uart    echo SKIP_PASS_$(journalctl -u spdmd --no-pager | grep -c "attestation PASSED")    waitForEcho=false
    Pause And Run For    5
    Wait For Line On Uart    SKIP_PASS_1    timeout=30    includeUnfinishedLine=true
    Assert Spdmd Journal Does Not Contain    attestation FAILED    SKIP_NOFAIL
    Assert Dbus ComponentIntegrity    eid=21    expected_status=Success
    Assert Redfish ComponentIntegrity    eid=21    expected_status=Success
