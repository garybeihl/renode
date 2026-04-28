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
    [Arguments]             ${dest_eid}  ${src_eid}  ${tag}  ${instance_id}  ${ctrl_cmd}  @{extra_payload}
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
    # Extra payload bytes (if any)
    FOR  ${b}  IN  @{extra_payload}
        Write OOB TX Byte   ${b}
    END
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
    Send MCTP PLDM Via OOB TX  20  8  0  0  0  2
    # TX completion should fire
    Verify OOB TX Completion

PLDM GetTID Via OOB
    [Documentation]         Send PLDM GetTID via OOB TX and verify response in OOB RX
    [Tags]                  birchstream  pldm  espi  oob  gettid
    Create Birchstream With PLDM
    # dest=FD_EID(9), src=BMC_EID(8), tag=0, iid=0, type=Base(0), cmd=GetTID(2)
    Send MCTP PLDM Via OOB TX  20  8  0  0  0  2
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
    Send MCTP PLDM Via OOB TX  20  8  0  1  0  1  0x42
    Verify OOB RX Completion
    # Now GetTID should return 0x42
    Clear OOB RX Status
    Send MCTP PLDM Via OOB TX  20  8  0  2  0  2
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
    Send MCTP PLDM Via OOB TX  20  8  0  3  0  4
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
    Send MCTP PLDM Via OOB TX  20  8  0  4  0  2
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
    Send MCTP PLDM Via OOB TX  20  8  0  5  0  2
    Verify OOB RX Completion
    Clear OOB RX Status
    # Request 2: GetTypes
    Send MCTP PLDM Via OOB TX  20  8  1  6  0  4
    Verify OOB RX Completion
    Clear OOB RX Status
    # Request 3: SetTID
    Send MCTP PLDM Via OOB TX  20  8  2  7  0  1  0x10
    Verify OOB RX Completion

MCTP Control GetEID Via OOB
    [Documentation]         Send MCTP Control GetEID via OOB (message type 0x00)
    [Tags]                  birchstream  pldm  espi  oob  mctp  control
    Create Birchstream With PLDM
    # MCTP Control GetEID: ctrl_cmd=0x02
    Send MCTP Control Via OOB TX  20  8  0  8  2
    Verify OOB RX Completion

Different Instance IDs Tracked
    [Documentation]         PLDM responses preserve the instance ID from the request
    [Tags]                  birchstream  pldm  espi  oob  instanceid
    Create Birchstream With PLDM
    # Send GetTID with instance_id=15
    Send MCTP PLDM Via OOB TX  20  8  0  15  0  2
    Verify OOB RX Completion
    # Read past MCTP header (5 bytes) to PLDM header byte 0
    FOR  ${i}  IN RANGE  5
        Read OOB RX Byte
    END
    ${pldm_hdr}=            Read OOB RX Byte
    ${iid}=                 Evaluate  int(${pldm_hdr}) & 0x1F
    Should Be Equal As Numbers  ${iid}  15  msg=Instance ID should be preserved in response


SetEID Then GetEID Shows New EID
    [Documentation]         After SetEID, GetEID returns the newly assigned EID
    [Tags]                  birchstream  pldm  espi  mctp  discovery  seteid
    Create Birchstream With PLDM
    # SetEID: MCTP Control msg (type=0x00)
    # Control payload: [Rq=1|iid=0 => 0x80][cmd=SetEID(0x01)][operation=0x00][eid=0x30]
    Send MCTP Control Via OOB TX  20  8  0  0  1  0x00  0x30
    Verify OOB RX Completion
    # Read SetEID response to verify acceptance
    FOR  ${i}  IN RANGE  5
        Read OOB RX Byte
    END
    # Byte 5: Control resp hdr (iid)
    ${resp_hdr}=            Read OOB RX Byte
    # Byte 6: cmd (0x01)
    ${resp_cmd}=            Read OOB RX Byte
    Should Be Equal As Numbers  ${resp_cmd}  1  msg=SetEID response command should be 0x01
    # Byte 7: completion code
    ${cc}=                  Read OOB RX Byte
    Should Be Equal As Numbers  ${cc}  0  msg=SetEID completion code should be SUCCESS
    # Byte 8: assignment status (0=accepted)
    ${assign_sts}=          Read OOB RX Byte
    Should Be Equal As Numbers  ${assign_sts}  0  msg=EID assignment should be accepted
    # Byte 9: EID setting (should be 0x30)
    ${eid_val}=             Read OOB RX Byte
    Should Be Equal As Numbers  ${eid_val}  0x30  msg=EID should be set to 0x30
    Clear OOB RX Status
    # Now GetEID should return 0x30
    # Must address the device at its NEW EID (0x30)
    Send MCTP Control Via OOB TX  0x30  8  1  1  2
    Verify OOB RX Completion
    # Read GetEID response
    FOR  ${i}  IN RANGE  5
        Read OOB RX Byte
    END
    ${resp_hdr2}=           Read OOB RX Byte
    ${resp_cmd2}=           Read OOB RX Byte
    ${cc2}=                 Read OOB RX Byte
    Should Be Equal As Numbers  ${cc2}  0  msg=GetEID completion code should be SUCCESS
    ${new_eid}=             Read OOB RX Byte
    Should Be Equal As Numbers  ${new_eid}  0x30  msg=GetEID should return new EID 0x30

SetEID Reset Restores Default
    [Documentation]         SetEID with reset operation restores the default static EID
    [Tags]                  birchstream  pldm  espi  mctp  discovery  seteid
    Create Birchstream With PLDM
    # First set EID to 0x30
    Send MCTP Control Via OOB TX  20  8  0  0  1  0x00  0x30
    Verify OOB RX Completion
    Clear OOB RX Status
    # Now reset: operation=0x02 (ResetEid), EID doesn't matter
    Send MCTP Control Via OOB TX  0x30  8  1  1  1  0x02  0x00
    Verify OOB RX Completion
    # Response should show EID back to 20 (default)
    FOR  ${i}  IN RANGE  5
        Read OOB RX Byte
    END
    Read OOB RX Byte
    Read OOB RX Byte
    ${cc}=                  Read OOB RX Byte
    Should Be Equal As Numbers  ${cc}  0
    Read OOB RX Byte
    ${eid_val}=             Read OOB RX Byte
    Should Be Equal As Numbers  ${eid_val}  20  msg=EID should be reset to default 20

EID Validation Drops Wrong Dest
    [Documentation]         Packets addressed to wrong EID are dropped (no response)
    [Tags]                  birchstream  pldm  espi  mctp  discovery  eid
    Create Birchstream With PLDM
    # Send to EID 99 — not our device (default is 20)
    Send MCTP PLDM Via OOB TX  99  8  0  0  0  2
    # OOB TX completion should fire (we wrote to TX)
    Verify OOB TX Completion
    # But OOB RX should NOT fire (packet dropped)
    ${sts}=                 Read ESPI Register  ${INT_STS}
    ${oob_rx}=              Evaluate  (int(${sts}) >> 4) & 1
    Should Be Equal As Numbers  ${oob_rx}  0  msg=OOB RX should NOT fire for wrong EID

Broadcast EID Accepted
    [Documentation]         Packets with broadcast EID (0xFF) are accepted
    [Tags]                  birchstream  pldm  espi  mctp  discovery  broadcast
    Create Birchstream With PLDM
    # Send GetTID to broadcast EID 0xFF
    Send MCTP PLDM Via OOB TX  0xFF  8  0  0  0  2
    Verify OOB RX Completion

Null EID Accepted
    [Documentation]         Packets with null EID (0x00) are accepted (pre-assignment discovery)
    [Tags]                  birchstream  pldm  espi  mctp  discovery  null
    Create Birchstream With PLDM
    # Send GetTID to null EID 0x00
    Send MCTP PLDM Via OOB TX  0x00  8  0  1  0  2
    Verify OOB RX Completion

GetMCTPVersionSupport Base Spec
    [Documentation]         GetMCTPVersionSupport for base spec (type 0xFF) returns version
    [Tags]                  birchstream  pldm  espi  mctp  discovery  version
    Create Birchstream With PLDM
    # GetMCTPVersionSupport: ctrl_cmd=0x04, extra payload: type=0xFF (base spec)
    Send MCTP Control Via OOB TX  20  8  0  0  4  0xFF
    Verify OOB RX Completion
    # Read response: skip MCTP header (5 bytes)
    FOR  ${i}  IN RANGE  5
        Read OOB RX Byte
    END
    ${resp_hdr}=            Read OOB RX Byte
    ${resp_cmd}=            Read OOB RX Byte
    Should Be Equal As Numbers  ${resp_cmd}  4  msg=Response command should be GetVersionSupport(0x04)
    ${cc}=                  Read OOB RX Byte
    Should Be Equal As Numbers  ${cc}  0  msg=Completion code should be SUCCESS
    ${count}=               Read OOB RX Byte
    Should Be Equal As Numbers  ${count}  1  msg=Should have 1 version entry
    # Version bytes: F1 F3 F1 00 = MCTP base spec v1.3.1
    ${v0}=                  Read OOB RX Byte
    ${v1}=                  Read OOB RX Byte
    ${v2}=                  Read OOB RX Byte
    ${v3}=                  Read OOB RX Byte
    Should Be Equal As Numbers  ${v0}  0xF1
    Should Be Equal As Numbers  ${v1}  0xF3
    Should Be Equal As Numbers  ${v2}  0xF1
    Should Be Equal As Numbers  ${v3}  0x00

GetMCTPVersionSupport PLDM
    [Documentation]         GetMCTPVersionSupport for PLDM (type 0x01) returns PLDM version
    [Tags]                  birchstream  pldm  espi  mctp  discovery  version
    Create Birchstream With PLDM
    # GetMCTPVersionSupport for PLDM message type (0x01)
    Send MCTP Control Via OOB TX  20  8  0  1  4  0x01
    Verify OOB RX Completion
    FOR  ${i}  IN RANGE  5
        Read OOB RX Byte
    END
    Read OOB RX Byte
    ${resp_cmd}=            Read OOB RX Byte
    ${cc}=                  Read OOB RX Byte
    Should Be Equal As Numbers  ${cc}  0  msg=CC should be SUCCESS
    ${count}=               Read OOB RX Byte
    Should Be Equal As Numbers  ${count}  1
    # PLDM version: F1 F1 F0 00 = v1.1.0
    ${v0}=                  Read OOB RX Byte
    ${v1}=                  Read OOB RX Byte
    ${v2}=                  Read OOB RX Byte
    Should Be Equal As Numbers  ${v0}  0xF1
    Should Be Equal As Numbers  ${v1}  0xF1
    Should Be Equal As Numbers  ${v2}  0xF0

GetMCTPVersionSupport Unsupported Type
    [Documentation]         GetMCTPVersionSupport for unsupported type returns error
    [Tags]                  birchstream  pldm  espi  mctp  discovery  version
    Create Birchstream With PLDM
    # Query for unknown type 0x55
    Send MCTP Control Via OOB TX  20  8  0  2  4  0x55
    Verify OOB RX Completion
    FOR  ${i}  IN RANGE  5
        Read OOB RX Byte
    END
    Read OOB RX Byte
    ${resp_cmd}=            Read OOB RX Byte
    ${cc}=                  Read OOB RX Byte
    Should Be Equal As Numbers  ${cc}  0x80  msg=Unsupported type should return error 0x80

PLDM Response Uses New EID After SetEID
    [Documentation]         After SetEID, PLDM responses use the new source EID
    [Tags]                  birchstream  pldm  espi  mctp  discovery  eid
    Create Birchstream With PLDM
    # Set EID to 0x30
    Send MCTP Control Via OOB TX  20  8  0  0  1  0x00  0x30
    Verify OOB RX Completion
    Clear OOB RX Status
    # Send PLDM GetTID to new EID 0x30
    Send MCTP PLDM Via OOB TX  0x30  8  0  0  0  2
    Verify OOB RX Completion
    # Read MCTP header — SrcEID should be 0x30
    Read OOB RX Byte
    ${dest}=                Read OOB RX Byte
    Should Be Equal As Numbers  ${dest}  8  msg=Response dest should be BMC(8)
    ${src}=                 Read OOB RX Byte
    Should Be Equal As Numbers  ${src}  0x30  msg=Response src should be new EID 0x30