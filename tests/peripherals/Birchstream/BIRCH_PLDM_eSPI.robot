*** Settings ***
Documentation       PLDM over MCTP over eSPI OOB transport tests
...                 Validates the MCTP OOB binding for PLDM firmware device communication.
...                 BMC sends MCTP/PLDM requests via eSPI OOB TX; PLDM device responds via OOB RX.

*** Variables ***
${INT_STS}          0x008
${OOB_RX_CTRL}      0x044
${OOB_RX_DATA}      0x048
${OOB_TX_CTRL}      0x054
${OOB_TX_DATA}      0x058
${TRIG_PEND}        0x80000000
${INT_OOB_RX}       0x10
${INT_OOB_TX}       0x20
${SERV_PEND}        0x80000000

*** Keywords ***
Create Birchstream With PLDM
    Execute Command         mach create "ast2600"
    Execute Command         machine LoadPlatformDescription @platforms/boards/ast2600/ast2600-evb.repl
    Execute Command         emulation CreatePldmFirmwareDevice "pldm_fd"
    Execute Command         emulation ConnectPldmToEspi "pldm_fd" sysbus.espi

Write OOB TX Byte
    [Arguments]             ${byte_val}
    Execute Command         sysbus.espi WriteDoubleWord ${OOB_TX_DATA} ${byte_val}

Trigger OOB TX
    [Documentation]         Set TRIG_PEND bit in OOB_TX_CTRL to complete OOB TX
    Execute Command         sysbus.espi WriteDoubleWord ${OOB_TX_CTRL} ${TRIG_PEND}

Send MCTP PLDM Via OOB TX
    [Documentation]         Send MCTP-encapsulated PLDM request via eSPI OOB TX FIFO.
    ...                     Writes each byte to OOB_TX_DATA, then triggers OOB TX.
    ...                     The PLDM FD processes the request and responds via OOB RX.
    [Arguments]             ${dest_eid}  ${src_eid}  ${tag}  ${instance_id}  ${pldm_type}  ${pldm_cmd}  @{extra_payload}
    # MCTP header: [HeaderVersion(0x01)][DestEID][SrcEID][FlagsTag]
    # FlagsTag = SOM(0x80) | EOM(0x40) | TO(0x08) | tag
    ${flags}=               Evaluate  0xC8 | (${tag} & 0x07)
    Write OOB TX Byte       1
    Write OOB TX Byte       ${dest_eid}
    Write OOB TX Byte       ${src_eid}
    Write OOB TX Byte       ${flags}
    # MCTP message type = PLDM (0x01)
    Write OOB TX Byte       1
    # PLDM header: [Rq=1|iid][type][command]
    ${pldm_hdr}=            Evaluate  0x80 | (${instance_id} & 0x1F)
    Write OOB TX Byte       ${pldm_hdr}
    Write OOB TX Byte       ${pldm_type}
    Write OOB TX Byte       ${pldm_cmd}
    # Extra payload bytes (if any)
    FOR  ${b}  IN  @{extra_payload}
        Write OOB TX Byte   ${b}
    END
    Trigger OOB TX

Send MCTP Control Via OOB TX
    [Documentation]         Send MCTP Control message via eSPI OOB TX FIFO.
    [Arguments]             ${dest_eid}  ${src_eid}  ${tag}  ${instance_id}  ${ctrl_cmd}
    ${flags}=               Evaluate  0xC8 | (${tag} & 0x07)
    Write OOB TX Byte       1
    Write OOB TX Byte       ${dest_eid}
    Write OOB TX Byte       ${src_eid}
    Write OOB TX Byte       ${flags}
    # MCTP message type = Control (0x00)
    Write OOB TX Byte       0
    # Control header: [Rq=1|D=0|iid][command]
    ${ctrl_hdr}=            Evaluate  0x80 | (${instance_id} & 0x1F)
    Write OOB TX Byte       ${ctrl_hdr}
    Write OOB TX Byte       ${ctrl_cmd}
    Trigger OOB TX

Read ESPI Register
    [Arguments]             ${offset}
    ${val}=     Execute Command    sysbus.espi ReadDoubleWord ${offset}
    RETURN      ${val.strip()}

Verify OOB RX Completion
    [Documentation]         Verify that OOB RX completion interrupt is set (PLDM responded)
    ${sts}=                 Read ESPI Register  ${INT_STS}
    ${oob_rx}=              Evaluate  (int(${sts}) >> 4) & 1
    Should Be Equal As Numbers  ${oob_rx}  1  msg=OOB RX completion not set — PLDM device did not respond

Clear OOB RX Status
    Execute Command         sysbus.espi WriteDoubleWord ${INT_STS} ${INT_OOB_RX}

Verify OOB TX Completion
    [Documentation]         Verify that OOB TX completion interrupt is set
    ${sts}=                 Read ESPI Register  ${INT_STS}
    ${oob_tx}=              Evaluate  (int(${sts}) >> 5) & 1
    Should Be Equal As Numbers  ${oob_tx}  1  msg=OOB TX completion not set

Read OOB RX Byte
    [Documentation]         Read one byte from OOB RX FIFO
    ${val}=                 Read ESPI Register  ${OOB_RX_DATA}
    RETURN                  ${val}

*** Test Cases ***
PLDM Device Connected To eSPI OOB
    [Documentation]         Verify PldmFirmwareDevice creates and connects to eSPI OOB
    [Tags]                  birchstream  pldm  espi  oob
    Create Birchstream With PLDM

OOB TX Triggers Handler
    [Documentation]         Writing to OOB TX FIFO and triggering sends data to PLDM handler
    [Tags]                  birchstream  pldm  espi  oob  tx
    Create Birchstream With PLDM
    # Write a minimal MCTP packet to TX FIFO (GetTID)
    Send MCTP PLDM Via OOB TX  9  8  0  0  0  2
    # TX completion should fire
    Verify OOB TX Completion

PLDM GetTID Via OOB
    [Documentation]         Send PLDM GetTID via OOB TX and verify response in OOB RX
    [Tags]                  birchstream  pldm  espi  oob  gettid
    Create Birchstream With PLDM
    # dest=FD_EID(9), src=BMC_EID(8), tag=0, iid=0, type=Base(0), cmd=GetTID(2)
    Send MCTP PLDM Via OOB TX  9  8  0  0  0  2
    Verify OOB RX Completion
    # OOB RX CTRL should have SERV_PEND set
    ${ctrl}=                Read ESPI Register  ${OOB_RX_CTRL}
    ${serv}=                Evaluate  (int(${ctrl}) >> 31) & 1
    Should Be Equal As Numbers  ${serv}  1  msg=OOB RX SERV_PEND not set
    # Read response: MCTP header + PLDM response
    # Byte 0: HeaderVersion=0x01
    ${b0}=                  Read OOB RX Byte
    Should Be Equal As Numbers  ${b0}  1  msg=MCTP HeaderVersion should be 0x01
    # Byte 1: DestEID (should be requester=8)
    ${b1}=                  Read OOB RX Byte
    Should Be Equal As Numbers  ${b1}  8  msg=Response DestEID should be BMC(8)
    # Byte 2: SrcEID (should be FD=9)
    ${b2}=                  Read OOB RX Byte
    Should Be Equal As Numbers  ${b2}  20  msg=Response SrcEID should be FD (default EID=20)
    # Byte 3: FlagsTag — SOM|EOM set, TO cleared (responder)
    ${b3}=                  Read OOB RX Byte
    ${som_eom}=             Evaluate  (int(${b3}) >> 6) & 3
    Should Be Equal As Numbers  ${som_eom}  3  msg=SOM and EOM should both be set
    # Byte 4: MessageType = PLDM (0x01)
    ${b4}=                  Read OOB RX Byte
    Should Be Equal As Numbers  ${b4}  1  msg=MessageType should be PLDM(0x01)
    # Byte 5: PLDM hdr byte 0 (Rq=0 for response, iid=0)
    ${b5}=                  Read OOB RX Byte
    ${rq_bit}=              Evaluate  (int(${b5}) >> 7) & 1
    Should Be Equal As Numbers  ${rq_bit}  0  msg=Response should have Rq=0
    # Byte 6: PLDM type = Base (0x00)
    ${b6}=                  Read OOB RX Byte
    Should Be Equal As Numbers  ${b6}  0  msg=PLDM type should be Base(0x00)
    # Byte 7: PLDM command = GetTID (0x02)
    ${b7}=                  Read OOB RX Byte
    Should Be Equal As Numbers  ${b7}  2  msg=PLDM command should be GetTID(0x02)
    # Byte 8: Completion code = SUCCESS (0x00)
    ${b8}=                  Read OOB RX Byte
    Should Be Equal As Numbers  ${b8}  0  msg=Completion code should be SUCCESS(0x00)

PLDM SetTID Via OOB
    [Documentation]         Send PLDM SetTID via OOB TX and verify response
    [Tags]                  birchstream  pldm  espi  oob  settid
    Create Birchstream With PLDM
    # SetTID: type=Base(0), cmd=SetTID(1), payload=[TID=0x42]
    Send MCTP PLDM Via OOB TX  9  8  0  1  0  1  0x42
    Verify OOB RX Completion
    # Now GetTID should return 0x42
    Clear OOB RX Status
    Send MCTP PLDM Via OOB TX  9  8  0  2  0  2
    Verify OOB RX Completion
    # Read past MCTP+PLDM headers (8 bytes) to get completion code + TID
    FOR  ${i}  IN RANGE  8
        Read OOB RX Byte
    END
    ${cc}=                  Read OOB RX Byte
    Should Be Equal As Numbers  ${cc}  0  msg=GetTID completion code should be SUCCESS
    ${tid}=                 Read OOB RX Byte
    Should Be Equal As Numbers  ${tid}  0x42  msg=TID should be 0x42 after SetTID

PLDM GetTypes Via OOB
    [Documentation]         Send PLDM GetPLDMTypes via OOB TX and verify response
    [Tags]                  birchstream  pldm  espi  oob  gettypes
    Create Birchstream With PLDM
    # GetPLDMTypes: type=Base(0), cmd=GetTypes(4)
    Send MCTP PLDM Via OOB TX  9  8  0  3  0  4
    Verify OOB RX Completion
    # Read past headers to completion code
    FOR  ${i}  IN RANGE  8
        Read OOB RX Byte
    END
    ${cc}=                  Read OOB RX Byte
    Should Be Equal As Numbers  ${cc}  0  msg=GetTypes completion code should be SUCCESS
    # Next byte: type bitmask — bit 0 (Base) and bit 5 (FW Update) should be set
    ${types}=               Read OOB RX Byte
    ${has_base}=            Evaluate  int(${types}) & 1
    Should Be Equal As Numbers  ${has_base}  1  msg=Base type (bit 0) should be set
    ${has_fwup}=            Evaluate  (int(${types}) >> 5) & 1
    Should Be Equal As Numbers  ${has_fwup}  1  msg=FW Update type (bit 5) should be set

W1C Clears OOB RX Status
    [Documentation]         OOB RX completion can be cleared via W1C
    [Tags]                  birchstream  pldm  espi  oob  w1c
    Create Birchstream With PLDM
    Send MCTP PLDM Via OOB TX  9  8  0  4  0  2
    Verify OOB RX Completion
    Clear OOB RX Status
    ${sts}=                 Read ESPI Register  ${INT_STS}
    ${oob_rx}=              Evaluate  (int(${sts}) >> 4) & 1
    Should Be Equal As Numbers  ${oob_rx}  0  msg=OOB RX should be cleared after W1C

Sequential PLDM Requests Via OOB
    [Documentation]         Multiple PLDM requests via OOB TX work sequentially
    [Tags]                  birchstream  pldm  espi  oob  sequential
    Create Birchstream With PLDM
    # Request 1: GetTID
    Send MCTP PLDM Via OOB TX  9  8  0  5  0  2
    Verify OOB RX Completion
    Clear OOB RX Status
    # Request 2: GetTypes
    Send MCTP PLDM Via OOB TX  9  8  1  6  0  4
    Verify OOB RX Completion
    Clear OOB RX Status
    # Request 3: SetTID
    Send MCTP PLDM Via OOB TX  9  8  2  7  0  1  0x10
    Verify OOB RX Completion

MCTP Control GetEID Via OOB
    [Documentation]         Send MCTP Control GetEID via OOB (message type 0x00)
    [Tags]                  birchstream  pldm  espi  oob  mctp  control
    Create Birchstream With PLDM
    # MCTP Control GetEID: ctrl_cmd=0x02
    Send MCTP Control Via OOB TX  9  8  0  8  2
    Verify OOB RX Completion

Different Instance IDs Tracked
    [Documentation]         PLDM responses preserve the instance ID from the request
    [Tags]                  birchstream  pldm  espi  oob  instanceid
    Create Birchstream With PLDM
    # Send GetTID with instance_id=15
    Send MCTP PLDM Via OOB TX  9  8  0  15  0  2
    Verify OOB RX Completion
    # Read past MCTP header (5 bytes) to PLDM header byte 0
    FOR  ${i}  IN RANGE  5
        Read OOB RX Byte
    END
    ${pldm_hdr}=            Read OOB RX Byte
    ${iid}=                 Evaluate  int(${pldm_hdr}) & 0x1F
    Should Be Equal As Numbers  ${iid}  15  msg=Instance ID should be preserved in response