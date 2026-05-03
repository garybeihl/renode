*** Comments ***
# Unit tests for SpdmResponderDevice component
# Tests device creation, MCTP control messages, SPDM protocol handlers,
# and out-of-order state machine error handling.
#
# Uses split send/check pattern with emulation RunFor between send and read,
# matching the proven spdm_smoke_test.resc approach.

*** Settings ***
Suite Setup         Setup
Suite Teardown      Teardown

*** Variables ***
${UART_BASE}        0x1e783000
${SCENARIO}         ${CURDIR}/spdm-scenarios/scenario.json
${SCENARIO_V11}     ${CURDIR}/spdm-scenarios/scenario-v11.json
${SCENARIO_MID}     ${CURDIR}/spdm-scenarios/scenario-mid-disconnect.json
${HELPER}           ${CURDIR}/spdm_mctp_helper.py

*** Keywords ***
Create SPDM Test Machine
    [Documentation]    Create minimal machine with halted CPU (needed for RunFor) and UART
    [Arguments]        ${scenario}=${SCENARIO}
    Execute Command     mach create "test"
    Execute Command     machine LoadPlatformDescriptionFromString "cpu: CPU.ARMv7A @ sysbus { cpuType: \\"cortex-a7\\" }; uart1: UART.NS16550 @ sysbus ${UART_BASE}"
    Execute Command     cpu IsHalted true
    Execute Command     emulation CreateSpdmResponderDevice "spdm_dev" @${scenario}
    Execute Command     connector Connect uart1 spdm_dev

Load Helper
    Execute Command     python "exec(open('${HELPER}').read())"

SPDM Send And Check
    [Documentation]    Send SPDM request, advance time, check response via named function
    [Arguments]        ${send_func}    ${check_func}
    Execute Command    python "${send_func}"
    Execute Command    emulation RunFor "0:0:0.001"
    ${result}=    Execute Command    python "${check_func}; print(_last_result)"
    Should Contain    ${result}    PASS
    RETURN    ${result}

SPDM Send And Check Error
    [Documentation]    Send SPDM request, advance time, verify ERROR response
    [Arguments]        ${send_func}    ${expected_code}
    Execute Command    python "${send_func}"
    Execute Command    emulation RunFor "0:0:0.001"
    ${result}=    Execute Command    python "check_spdm_error_response(${expected_code}); print(_last_result)"
    Should Contain    ${result}    PASS
    RETURN    ${result}

Run Full Negotiation
    [Documentation]    Complete VERSION + CAPABILITIES + ALGORITHMS sequence
    SPDM Send And Check    test_spdm_get_version()    check_spdm_get_version()
    SPDM Send And Check    test_spdm_get_capabilities()    check_spdm_get_capabilities()
    SPDM Send And Check    test_spdm_negotiate_algorithms()    check_spdm_negotiate_algorithms()

Run Full Negotiation V11
    [Documentation]    Complete VERSION + CAPABILITIES + ALGORITHMS for SPDM 1.1 device
    SPDM Send And Check    test_spdm_get_version()    check_spdm_get_version_v11()
    SPDM Send And Check    test_spdm_get_capabilities_v11()    check_spdm_get_capabilities_v11()
    SPDM Send And Check    test_spdm_negotiate_algorithms()    check_spdm_negotiate_algorithms()

SPDM Send And Check No Response
    [Documentation]    Send SPDM request, advance time, verify NO response
    [Arguments]        ${send_func}
    Execute Command    python "${send_func}"
    Execute Command    emulation RunFor "0:0:0.001"
    ${result}=    Execute Command    python "check_no_spdm_response(); print(_last_result)"
    Should Contain    ${result}    PASS
    RETURN    ${result}

*** Test Cases ***

# --- Smoke / happy-path tests ---

Should Create And Attach SpdmResponderDevice
    [Documentation]    Verify component creates, loads scenario, attaches to UART
    [Tags]             spdm    unit    smoke
    Create SPDM Test Machine
    ${output}=    Execute Command    lastLog 10
    Should Contain    ${output}    SpdmResponderDevice: attached to UART
    Should Contain    ${output}    SPDM: loaded ECDSA-P256 private key
    Should Contain    ${output}    SPDM: built cert chain buffer

Should Report SPDM Message Type Support
    [Documentation]    Verify MCTP GetMessageTypeSupport returns Control + SPDM
    [Tags]             spdm    unit    mctp
    Create SPDM Test Machine
    Load Helper
    SPDM Send And Check    test_mctp_get_msg_type_support()    check_mctp_get_msg_type_support()

Should Respond To GET_VERSION
    [Documentation]    Verify SPDM VERSION response with 1.1 and 1.2 entries
    [Tags]             spdm    unit    protocol
    Create SPDM Test Machine
    Load Helper
    ${result}=    SPDM Send And Check    test_spdm_get_version()    check_spdm_get_version()
    Should Contain    ${result}    count=2

Should Complete Full Negotiation
    [Documentation]    Run GET_VERSION + GET_CAPABILITIES + NEGOTIATE_ALGORITHMS
    [Tags]             spdm    unit    protocol
    Create SPDM Test Machine
    Load Helper
    Run Full Negotiation

Should Return Certificate Digests
    [Documentation]    After negotiation, GET_DIGESTS should return slot 0 hash
    [Tags]             spdm    unit    protocol
    Create SPDM Test Machine
    Load Helper
    Run Full Negotiation
    ${result}=    SPDM Send And Check    test_spdm_get_digests()    check_spdm_get_digests()
    Should Contain    ${result}    slot_mask=0x01

Should Return Certificate Chain
    [Documentation]    After negotiation, GET_CERTIFICATE should return cert chain data
    [Tags]             spdm    unit    protocol
    Create SPDM Test Machine
    Load Helper
    Run Full Negotiation
    ${result}=    SPDM Send And Check    test_spdm_get_certificate()    check_spdm_get_certificate()
    Should Contain    ${result}    portion=

# --- Out-of-order state machine error tests ---

Should Reject GET_CAPABILITIES Before GET_VERSION
    [Documentation]    GET_CAPABILITIES in NotStarted state returns ErrorUnexpectedRequest
    [Tags]             spdm    unit    state-machine    error
    Create SPDM Test Machine
    Load Helper
    SPDM Send And Check Error    test_spdm_get_capabilities()    0x03

Should Reject NEGOTIATE_ALGORITHMS Before GET_CAPABILITIES
    [Documentation]    NEGOTIATE_ALGORITHMS in AfterVersion state returns ErrorUnexpectedRequest
    [Tags]             spdm    unit    state-machine    error
    Create SPDM Test Machine
    Load Helper
    # Advance to AfterVersion state
    SPDM Send And Check    test_spdm_get_version()    check_spdm_get_version()
    # NEGOTIATE_ALGORITHMS requires AfterCapabilities, not AfterVersion
    SPDM Send And Check Error    test_spdm_negotiate_algorithms()    0x03

Should Reject GET_DIGESTS Before Negotiation
    [Documentation]    GET_DIGESTS in NotStarted state returns ErrorUnexpectedRequest
    [Tags]             spdm    unit    state-machine    error
    Create SPDM Test Machine
    Load Helper
    SPDM Send And Check Error    test_spdm_get_digests()    0x03

Should Reject GET_CERTIFICATE Before Negotiation
    [Documentation]    GET_CERTIFICATE in NotStarted state returns ErrorUnexpectedRequest
    [Tags]             spdm    unit    state-machine    error
    Create SPDM Test Machine
    Load Helper
    SPDM Send And Check Error    test_spdm_get_certificate()    0x03

Should Reject CHALLENGE Before Negotiation
    [Documentation]    CHALLENGE in NotStarted state returns ErrorUnexpectedRequest
    [Tags]             spdm    unit    state-machine    error
    Create SPDM Test Machine
    Load Helper
    SPDM Send And Check Error    test_spdm_challenge()    0x03

Should Reject GET_MEASUREMENTS Before Negotiation
    [Documentation]    GET_MEASUREMENTS in NotStarted state returns ErrorUnexpectedRequest
    [Tags]             spdm    unit    state-machine    error
    Create SPDM Test Machine
    Load Helper
    SPDM Send And Check Error    test_spdm_get_measurements_count()    0x03

Should Reject Unsupported Request Code
    [Documentation]    Unknown SPDM request code returns ErrorUnsupportedRequest
    [Tags]             spdm    unit    state-machine    error
    Create SPDM Test Machine
    Load Helper
    SPDM Send And Check Error    test_spdm_unsupported_request()    0x41

Should Reset State On GET_VERSION Mid-Session
    [Documentation]    GET_VERSION after full negotiation resets state for re-negotiation
    [Tags]             spdm    unit    state-machine
    Create SPDM Test Machine
    Load Helper
    # Complete initial negotiation
    Run Full Negotiation
    # GET_VERSION should reset state
    SPDM Send And Check    test_spdm_get_version()    check_spdm_get_version()
    # Should be able to negotiate again from scratch
    SPDM Send And Check    test_spdm_get_capabilities()    check_spdm_get_capabilities()
    SPDM Send And Check    test_spdm_negotiate_algorithms()    check_spdm_negotiate_algorithms()

# --- Malformed message handling tests ---

Should Drop Empty SPDM Payload
    [Documentation]    0-byte SPDM payload is silently dropped (no response)
    [Tags]             spdm    unit    malformed
    Create SPDM Test Machine
    Load Helper
    Execute Command    python "test_spdm_empty_payload()"
    Execute Command    emulation RunFor "0:0:0.001"
    ${result}=    Execute Command    python "check_no_spdm_response(); print(_last_result)"
    Should Contain    ${result}    PASS

Should Drop 3 Byte SPDM Payload
    [Documentation]    3-byte SPDM payload (under 4-byte minimum) is silently dropped
    [Tags]             spdm    unit    malformed
    Create SPDM Test Machine
    Load Helper
    Execute Command    python "test_spdm_short_payload_3()"
    Execute Command    emulation RunFor "0:0:0.001"
    ${result}=    Execute Command    python "check_no_spdm_response(); print(_last_result)"
    Should Contain    ${result}    PASS

Should Reject Short GET_CERTIFICATE 4 Bytes
    [Documentation]    GET_CERTIFICATE with 4-byte header only (need 8) returns ErrorInvalidRequest
    [Tags]             spdm    unit    malformed    error
    Create SPDM Test Machine
    Load Helper
    Run Full Negotiation
    SPDM Send And Check Error    test_spdm_short_certificate_4()    0x01

Should Reject Short GET_CERTIFICATE 7 Bytes
    [Documentation]    GET_CERTIFICATE with 7 bytes (one short of 8) returns ErrorInvalidRequest
    [Tags]             spdm    unit    malformed    error
    Create SPDM Test Machine
    Load Helper
    Run Full Negotiation
    SPDM Send And Check Error    test_spdm_short_certificate_7()    0x01

Should Reject Short CHALLENGE 4 Bytes
    [Documentation]    CHALLENGE with 4-byte header only (need 36) returns ErrorInvalidRequest
    [Tags]             spdm    unit    malformed    error
    Create SPDM Test Machine
    Load Helper
    Run Full Negotiation
    SPDM Send And Check Error    test_spdm_short_challenge_4()    0x01

Should Reject Short CHALLENGE 35 Bytes
    [Documentation]    CHALLENGE with 35 bytes (one short of 36) returns ErrorInvalidRequest
    [Tags]             spdm    unit    malformed    error
    Create SPDM Test Machine
    Load Helper
    Run Full Negotiation
    SPDM Send And Check Error    test_spdm_short_challenge_35()    0x01

# --- MCTP control command tests ---

Should Respond To SET_EID
    [Documentation]    MCTP Set Endpoint ID assigns new EID and returns success
    [Tags]             spdm    unit    mctp
    Create SPDM Test Machine
    Load Helper
    SPDM Send And Check    test_mctp_set_eid()    check_mctp_set_eid()

Should Respond To GET_EID
    [Documentation]    MCTP Get Endpoint ID returns the configured EID
    [Tags]             spdm    unit    mctp
    Create SPDM Test Machine
    Load Helper
    SPDM Send And Check    test_mctp_get_eid()    check_mctp_get_eid()

Should Respond To GET_UUID
    [Documentation]    MCTP Get Endpoint UUID returns 16-byte UUID from scenario
    [Tags]             spdm    unit    mctp
    Create SPDM Test Machine
    Load Helper
    SPDM Send And Check    test_mctp_get_uuid()    check_mctp_get_uuid()

Should Reject Unknown MCTP Control Command
    [Documentation]    Unknown MCTP control command returns error cc=0x05
    [Tags]             spdm    unit    mctp    error
    Create SPDM Test Machine
    Load Helper
    SPDM Send And Check    test_mctp_unknown_command()    check_mctp_unknown_command()

Should Ignore MCTP Non-Request
    [Documentation]    MCTP control message with Rq bit cleared produces no response
    [Tags]             spdm    unit    mctp
    Create SPDM Test Machine
    Load Helper
    Execute Command    python "test_mctp_non_request()"
    Execute Command    emulation RunFor "0:0:0.001"
    ${result}=    Execute Command    python "check_no_mctp_control_response(); print(_last_result)"
    Should Contain    ${result}    PASS

Should Ignore Short MCTP Control Payload
    [Documentation]    1-byte MCTP control payload produces no response
    [Tags]             spdm    unit    mctp
    Create SPDM Test Machine
    Load Helper
    Execute Command    python "test_mctp_short_control()"
    Execute Command    emulation RunFor "0:0:0.001"
    ${result}=    Execute Command    python "check_no_mctp_control_response(); print(_last_result)"
    Should Contain    ${result}    PASS

# --- GET_CERTIFICATE edge case tests ---

Should Return Certificate At Offset
    [Documentation]    GET_CERTIFICATE with offset=100 returns remaining cert chain data
    [Tags]             spdm    unit    protocol    certificate
    Create SPDM Test Machine
    Load Helper
    Run Full Negotiation
    SPDM Send And Check    test_spdm_get_certificate_offset()    check_spdm_get_certificate_offset()

Should Return Empty Certificate Beyond Bounds
    [Documentation]    GET_CERTIFICATE with offset=65535 returns portion=0, remainder=0
    [Tags]             spdm    unit    protocol    certificate
    Create SPDM Test Machine
    Load Helper
    Run Full Negotiation
    SPDM Send And Check    test_spdm_get_certificate_beyond()    check_spdm_get_certificate_beyond()

Should Echo Slot ID In Certificate Response
    [Documentation]    GET_CERTIFICATE with slot=1 echoes slot_id=1 in response param1
    [Tags]             spdm    unit    protocol    certificate
    Create SPDM Test Machine
    Load Helper
    Run Full Negotiation
    SPDM Send And Check    test_spdm_get_certificate_slot1()    check_spdm_get_certificate_slot1()

# --- GET_MEASUREMENTS variation tests ---

Should Return Single Measurement By Index
    [Documentation]    GET_MEASUREMENTS with operation=1 returns exactly 1 block
    [Tags]             spdm    unit    protocol    measurements
    Create SPDM Test Machine
    Load Helper
    Run Full Negotiation
    SPDM Send And Check    test_spdm_get_measurements_index1()    check_spdm_get_measurements_index1()

Should Return Empty For Invalid Measurement Index
    [Documentation]    GET_MEASUREMENTS with invalid index returns 0 blocks
    [Tags]             spdm    unit    protocol    measurements
    Create SPDM Test Machine
    Load Helper
    Run Full Negotiation
    SPDM Send And Check    test_spdm_get_measurements_invalid_index()    check_spdm_get_measurements_invalid_index()

Should Return Unsigned Measurements
    [Documentation]    GET_MEASUREMENTS with attributes=0 returns all blocks without signature
    [Tags]             spdm    unit    protocol    measurements
    Create SPDM Test Machine
    Load Helper
    Run Full Negotiation
    SPDM Send And Check    test_spdm_get_measurements_all_unsigned()    check_spdm_get_measurements_all_unsigned()

# --- SPDM 1.1 version-specific tests ---

Should Return Single Version Entry For V11 Device
    [Documentation]    v1.1-only device VERSION response has exactly 1 entry (1.1)
    [Tags]             spdm    unit    protocol    version
    Create SPDM Test Machine    ${SCENARIO_V11}
    Load Helper
    ${result}=    SPDM Send And Check    test_spdm_get_version()    check_spdm_get_version_v11()
    Should Contain    ${result}    count=1

Should Return 12 Byte Capabilities For V11 Device
    [Documentation]    v1.1 device CAPABILITIES is 12 bytes (no data_transfer_size/max_spdm_msg_size)
    [Tags]             spdm    unit    protocol    version
    Create SPDM Test Machine    ${SCENARIO_V11}
    Load Helper
    SPDM Send And Check    test_spdm_get_version()    check_spdm_get_version_v11()
    SPDM Send And Check    test_spdm_get_capabilities_v11()    check_spdm_get_capabilities_v11()

Should Complete Full V11 Negotiation
    [Documentation]    v1.1 device completes VERSION + CAPABILITIES + ALGORITHMS
    [Tags]             spdm    unit    protocol    version
    Create SPDM Test Machine    ${SCENARIO_V11}
    Load Helper
    Run Full Negotiation V11

# --- CHALLENGE with measurement summary tests ---

Should Return Challenge Auth With TCB Summary
    [Documentation]    CHALLENGE with meas_summary_type=0x01 includes 32B TCB measurement hash (166 bytes total)
    [Tags]             spdm    unit    protocol    challenge
    Create SPDM Test Machine
    Load Helper
    Run Full Negotiation
    SPDM Send And Check    test_spdm_challenge_tcb_summary()    check_spdm_challenge_with_summary()

Should Return Challenge Auth With All Summary
    [Documentation]    CHALLENGE with meas_summary_type=0xFF includes 32B all-measurement hash (166 bytes total)
    [Tags]             spdm    unit    protocol    challenge
    Create SPDM Test Machine
    Load Helper
    Run Full Negotiation
    SPDM Send And Check    test_spdm_challenge_all_summary()    check_spdm_challenge_with_summary()

# --- MaxSpdmResponses limit test ---

Should Stop Responding After MaxSpdmResponses
    [Documentation]    Device with max_responses=3 stops after negotiation; 4th request gets no response
    [Tags]             spdm    unit    protocol    limit
    Create SPDM Test Machine    ${SCENARIO_MID}
    Load Helper
    Run Full Negotiation
    SPDM Send And Check No Response    test_spdm_get_digests()
