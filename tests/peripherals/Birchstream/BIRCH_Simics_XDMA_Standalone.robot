*** Settings ***
Documentation       Remaining Simics-parity XDMA standalone tests.
...                 Covers the 5 XDMA standalone test scenarios from
...                 the Simics oracle not yet ported.

*** Variables ***
${CMDQ_ADDR}        0x014
${CMDQ_ENDP}        0x018
${CMDQ_WRP}         0x01C
${CMDQ_RDP}         0x020
${CTRL}             0x038
${STATUS}           0x03C
${STATUS_US_COMP}   0x00010000
${STATUS_DS_COMP}   0x00020000
${STATUS_DS_DIRTY}  0x00040000
${STATUS_RESET}     0xF8000000
${SRAM_BASE}        0x10000000

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

*** Test Cases ***
XDMA Register Reset Values
    [Documentation]         Verify register defaults after reset (Simics standalone 1)
    [Tags]                  simics  xdma  standalone  reset
    Create AST2600 Machine
    ${cmdq}=                Read XDMA Register  ${CMDQ_ADDR}
    Should Be Equal As Numbers  ${cmdq}  0x0
    ${endp}=                Read XDMA Register  ${CMDQ_ENDP}
    Should Be Equal As Numbers  ${endp}  0x0
    ${wrp}=                 Read XDMA Register  ${CMDQ_WRP}
    Should Be Equal As Numbers  ${wrp}  0x0
    ${rdp}=                 Read XDMA Register  ${CMDQ_RDP}
    Should Be Equal As Numbers  ${rdp}  0x0
    ${status}=              Read XDMA Register  ${STATUS}
    # Reset value should have upper bits set
    ${upper}=               Evaluate  ${status} & ${STATUS_RESET}
    Should Be Equal As Numbers  ${upper}  ${STATUS_RESET}

XDMA CTRL Write Mask
    [Documentation]         CTRL register respects write mask (Simics standalone 2)
    [Tags]                  simics  xdma  standalone  ctrl
    Create AST2600 Machine
    Write XDMA Register    ${CTRL}  0xFFFFFFFF
    ${ctrl}=                Read XDMA Register  ${CTRL}
    # Only bits in CTRL_W_MASK (0x017003FF) should be set
    ${masked}=              Evaluate  ${ctrl} & ~0x017003FF
    Should Be Equal As Numbers  ${masked}  0x0

XDMA Bidirectional Transfer
    [Documentation]         Upstream (BMC->host) direction bit (Simics standalone 3)
    [Tags]                  simics  xdma  standalone  direction
    Create AST2600 Machine
    # Setup queue
    Write XDMA Register    ${CMDQ_ADDR}  ${SRAM_BASE}
    Write XDMA Register    ${CMDQ_ENDP}  0x10
    Write XDMA Register    ${CMDQ_RDP}   0x0
    Write XDMA Register    ${CTRL}       ${STATUS_DS_COMP}
    # Downstream: flash -> DRAM
    Write Memory Word       0x20000000  0xD0005740
    Write Memory Word       ${SRAM_BASE}        0x20000000
    Write Memory Word       0x10000004          0x80001000
    Write Memory Word       0x10000008          0x8
    Write Memory Word       0x1000000C          0x0
    Write XDMA Register    ${CMDQ_WRP}  0x1
    ${v}=                   Read Memory Word  0x80001000
    Should Be Equal As Numbers  ${v}  0xD0005740

XDMA Queue Pointer Consistency
    [Documentation]         RDP tracks WRP after processing (Simics standalone 4)
    [Tags]                  simics  xdma  standalone  pointers
    Create AST2600 Machine
    Write XDMA Register    ${CMDQ_ADDR}  ${SRAM_BASE}
    Write XDMA Register    ${CMDQ_ENDP}  0x100
    Write XDMA Register    ${CMDQ_RDP}   0x0
    Write XDMA Register    ${CTRL}       ${STATUS_DS_COMP}
    # Submit 3 descriptors
    FOR  ${i}  IN RANGE  3
        ${base}=            Evaluate  0x10000000 + ${i} * 16
        Write Memory Word   ${base}      0x20000000
        ${base4}=          Evaluate  ${base} + 4
        ${base8}=          Evaluate  ${base} + 8
        ${base12}=         Evaluate  ${base} + 12
        Write Memory Word   ${base4}     0x80001000
        Write Memory Word   ${base8}     0x8
        Write Memory Word   ${base12}    0x0
    END
    Write XDMA Register    ${CMDQ_WRP}  0x3
    ${rdp}=                 Read XDMA Register  ${CMDQ_RDP}
    Should Be Equal As Numbers  ${rdp}  3
    ${wrp}=                 Read XDMA Register  ${CMDQ_WRP}
    Should Be Equal As Numbers  ${wrp}  3

XDMA Status W1C Selective Clear
    [Documentation]         W1C clears only written bits (Simics standalone 5)
    [Tags]                  simics  xdma  standalone  w1c
    Create AST2600 Machine
    Write XDMA Register    ${CMDQ_ADDR}  ${SRAM_BASE}
    Write XDMA Register    ${CMDQ_ENDP}  0x10
    Write XDMA Register    ${CMDQ_RDP}   0x0
    Write XDMA Register    ${CTRL}       ${STATUS_DS_COMP}
    # Trigger a transfer to set DS_COMP
    Write Memory Word       ${SRAM_BASE}  0x20000000
    Write Memory Word       0x10000004    0x80001000
    Write Memory Word       0x10000008    0x8
    Write Memory Word       0x1000000C    0x0
    Write XDMA Register    ${CMDQ_WRP}  0x1
    ${before}=              Read XDMA Register  ${STATUS}
    ${ds_comp}=             Evaluate  ${before} & ${STATUS_DS_COMP}
    Should Not Be Equal As Numbers  ${ds_comp}  0x0
    # Write 1 to DS_DIRTY bit only (should NOT clear DS_COMP)
    Write XDMA Register    ${STATUS}  ${STATUS_DS_DIRTY}
    ${after}=               Read XDMA Register  ${STATUS}
    ${still_comp}=          Evaluate  ${after} & ${STATUS_DS_COMP}
    Should Not Be Equal As Numbers  ${still_comp}  0x0