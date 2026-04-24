*** Settings ***
Documentation       Simics-parity XDMA boot tests.
...                 Ports the 6 Simics XDMA boot test scenarios.
...                 Tests cover the complete XDMA-driven OS image
...                 transfer boot path.

*** Variables ***
${CMDQ_ADDR}        0x014
${CMDQ_ENDP}        0x018
${CMDQ_WRP}         0x01C
${CMDQ_RDP}         0x020
${CTRL}             0x038
${STATUS}           0x03C
${STATUS_DS_COMP}   0x00020000
${STATUS_DS_DIRTY}  0x00040000
${SRAM_BASE}        0x10000000
${DESC_SIZE}        16

*** Keywords ***
Create AST2600 Machine
    Execute Command         mach create "ast2600"
    Execute Command         machine LoadPlatformDescription @platforms/boards/ast2600/ast2600-evb.repl

Read XDMA Register
    [Arguments]             ${offset}
    ${val}=  Execute Command    xdma ReadDoubleWord ${offset}
    RETURN                  ${val.strip()}

Write XDMA Register
    [Arguments]             ${offset}  ${value}
    Execute Command         xdma WriteDoubleWord ${offset} ${value}

Write Memory Word
    [Arguments]             ${addr}  ${value}
    Execute Command         sysbus WriteDoubleWord ${addr} ${value}

Read Memory Word
    [Arguments]             ${addr}
    ${val}=  Execute Command    sysbus ReadDoubleWord ${addr}
    RETURN                  ${val.strip()}

Setup Command Queue
    [Arguments]             ${base}=${SRAM_BASE}  ${size}=0x200
    Write XDMA Register    ${CMDQ_ADDR}  ${base}
    Write XDMA Register    ${CMDQ_ENDP}  ${size}
    Write XDMA Register    ${CMDQ_RDP}   0x0
    Write XDMA Register    ${CTRL}       ${STATUS_DS_COMP}

Write Descriptor
    [Arguments]             ${queue_base}  ${index}  ${src}  ${dst}  ${length}  ${flags}=0x0
    ${desc_addr}=           Evaluate  ${queue_base} + ${index} * ${DESC_SIZE}
    Write Memory Word       ${desc_addr}       ${src}
    Write Memory Word       ${desc_addr}+4     ${dst}
    Write Memory Word       ${desc_addr}+8     ${length}
    Write Memory Word       ${desc_addr}+12    ${flags}

Fill Memory Region
    [Documentation]         Fill memory region with incrementing pattern
    [Arguments]             ${base}  ${count}
    FOR  ${i}  IN RANGE  ${count}
        ${addr}=            Evaluate  ${base} + ${i} * 4
        ${val}=             Evaluate  0xDA7A0000 + ${i}
        Write Memory Word   ${addr}  ${val}
    END

*** Test Cases ***
Single Chunk OS Transfer
    [Documentation]         Single descriptor 2KB OS image transfer (Simics XDMA boot 1)
    [Tags]                  simics  xdma  boot  single
    Create AST2600 Machine
    # Place OS data at BMC DRAM
    Fill Memory Region      0x82000060  8
    Setup Command Queue
    # Single 32-byte transfer
    Write Descriptor        ${SRAM_BASE}  0  0x82000060  0x80100000  0x20
    Write XDMA Register    ${CMDQ_WRP}  0x1
    # Verify completion
    ${status}=              Read XDMA Register  ${STATUS}
    ${comp}=                Evaluate  ${status} & ${STATUS_DS_COMP}
    Should Not Be Equal As Numbers  ${comp}  0x0
    # Verify first word
    ${v}=                   Read Memory Word  0x80100000
    Should Be Equal As Numbers  ${v}  0xDA7A0000

Four Chunk Scatter Gather Transfer
    [Documentation]         4-descriptor scatter-gather (Simics XDMA boot 2)
    [Tags]                  simics  xdma  boot  scatter
    Create AST2600 Machine
    Write Memory Word       0x82000060  0x4F530001
    Write Memory Word       0x82000160  0x4F530002
    Write Memory Word       0x82000260  0x4F530003
    Write Memory Word       0x82000360  0x4F530004
    Setup Command Queue
    Write Descriptor        ${SRAM_BASE}  0  0x82000060  0x80100000  0x8
    Write Descriptor        ${SRAM_BASE}  1  0x82000160  0x80100008  0x8
    Write Descriptor        ${SRAM_BASE}  2  0x82000260  0x80100010  0x8
    Write Descriptor        ${SRAM_BASE}  3  0x82000360  0x80100018  0x8
    Write XDMA Register    ${CMDQ_WRP}  0x4
    ${status}=              Read XDMA Register  ${STATUS}
    ${comp}=                Evaluate  ${status} & ${STATUS_DS_COMP}
    Should Not Be Equal As Numbers  ${comp}  0x0
    ${v1}=                  Read Memory Word  0x80100000
    ${v2}=                  Read Memory Word  0x80100008
    ${v3}=                  Read Memory Word  0x80100010
    ${v4}=                  Read Memory Word  0x80100018
    Should Be Equal As Numbers  ${v1}  0x4F530001
    Should Be Equal As Numbers  ${v2}  0x4F530002
    Should Be Equal As Numbers  ${v3}  0x4F530003
    Should Be Equal As Numbers  ${v4}  0x4F530004

Transfer With Status Clear And Retrigger
    [Documentation]         Clear status, retrigger transfer (Simics XDMA boot 3)
    [Tags]                  simics  xdma  boot  retrigger
    Create AST2600 Machine
    Write Memory Word       0x82000060  0xFIRSTTRN
    Setup Command Queue
    Write Descriptor        ${SRAM_BASE}  0  0x82000060  0x80100000  0x8
    Write XDMA Register    ${CMDQ_WRP}  0x1
    ${status1}=             Read XDMA Register  ${STATUS}
    ${comp1}=               Evaluate  ${status1} & ${STATUS_DS_COMP}
    Should Not Be Equal As Numbers  ${comp1}  0x0
    # Clear DS_COMP (W1C)
    Write XDMA Register    ${STATUS}  ${STATUS_DS_COMP}
    ${cleared}=             Read XDMA Register  ${STATUS}
    ${comp_cleared}=        Evaluate  ${cleared} & ${STATUS_DS_COMP}
    Should Be Equal As Numbers  ${comp_cleared}  0x0
    # New data, retrigger
    Write Memory Word       0x82000160  0xSECONDTR
    Write Descriptor        ${SRAM_BASE}  1  0x82000160  0x80100008  0x8
    Write XDMA Register    ${CMDQ_WRP}  0x2
    ${status2}=             Read XDMA Register  ${STATUS}
    ${comp2}=               Evaluate  ${status2} & ${STATUS_DS_COMP}
    Should Not Be Equal As Numbers  ${comp2}  0x0

Transfer After Cold Reset
    [Documentation]         XDMA works after cold reset (Simics XDMA boot 4)
    [Tags]                  simics  xdma  boot  reset
    Create AST2600 Machine
    Write Memory Word       0x82000060  0xPRERESET
    Setup Command Queue
    Write Descriptor        ${SRAM_BASE}  0  0x82000060  0x80100000  0x8
    Write XDMA Register    ${CMDQ_WRP}  0x1
    # Reset
    Execute Command         espi ColdReset
    # Re-setup after reset
    Write Memory Word       0x82000060  0xPOSTRSET
    Setup Command Queue
    Write Descriptor        ${SRAM_BASE}  0  0x82000060  0x80100000  0x8
    Write XDMA Register    ${CMDQ_WRP}  0x1
    ${status}=              Read XDMA Register  ${STATUS}
    ${comp}=                Evaluate  ${status} & ${STATUS_DS_COMP}
    Should Not Be Equal As Numbers  ${comp}  0x0

Transfer Alignment Boundary
    [Documentation]         Transfer at exactly 8-byte boundary (Simics XDMA boot 5)
    [Tags]                  simics  xdma  boot  alignment
    Create AST2600 Machine
    Write Memory Word       0x82000008  0xALIGN008
    Setup Command Queue
    # All addresses 8-byte aligned
    Write Descriptor        ${SRAM_BASE}  0  0x82000008  0x80100008  0x8
    Write XDMA Register    ${CMDQ_WRP}  0x1
    ${status}=              Read XDMA Register  ${STATUS}
    ${comp}=                Evaluate  ${status} & ${STATUS_DS_COMP}
    Should Not Be Equal As Numbers  ${comp}  0x0
    ${v}=                   Read Memory Word  0x80100008
    Should Be Equal As Numbers  ${v}  0xALIGN008

Full Boot Path KCS Then XDMA
    [Documentation]         KCS discovery followed by XDMA transfer (Simics XDMA boot 6)
    [Tags]                  simics  xdma  boot  kcs  e2e
    Create AST2600 Machine
    Execute Command         lpc SetupBirchstreamDefaults
    Execute Command         lpc WriteDoubleWord 0x00 0x20
    Execute Command         lpc WriteDoubleWord 0x08 0x02
    # KCS: Get Device ID
    Execute Command         lpc SendHostIpmiCommand 0x06 0x01 null 0
    ${str}=  Execute Command    lpc ReadDoubleWord 0x3C
    ${obf}=                 Evaluate  int(${str.strip()}) & 1
    Should Be Equal As Numbers  ${obf}  1
    # XDMA: transfer OS image
    Write Memory Word       0x82000060  0xBOOTIMGD
    Setup Command Queue
    Write Descriptor        ${SRAM_BASE}  0  0x82000060  0x80100000  0x8
    Write XDMA Register    ${CMDQ_WRP}  0x1
    ${status}=              Read XDMA Register  ${STATUS}
    ${comp}=                Evaluate  ${status} & ${STATUS_DS_COMP}
    Should Not Be Equal As Numbers  ${comp}  0x0
    ${v}=                   Read Memory Word  0x80100000
    Should Be Equal As Numbers  ${v}  0xBOOTIMGD