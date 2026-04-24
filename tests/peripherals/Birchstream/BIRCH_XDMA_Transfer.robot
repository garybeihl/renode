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
    [Arguments]             ${base}=${SRAM_BASE}  ${size}=0x100
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

*** Test Cases ***
Misaligned Source Address Should Error
    [Documentation]         Source address not 8-byte aligned sets DS_DIRTY
    [Tags]                  aspeed  xdma  boot  alignment
    Create AST2600 Machine
    Setup Command Queue
    # src=0x20000001 (misaligned), dst=0x80001000, len=8
    Write Descriptor        ${SRAM_BASE}  0  0x20000001  0x80001000  0x8
    Write XDMA Register    ${CMDQ_WRP}  0x1
    ${status}=              Read XDMA Register  ${STATUS}
    ${dirty}=               Evaluate  ${status} & ${STATUS_DS_DIRTY}
    Should Not Be Equal As Numbers  ${dirty}  0x0

Misaligned Destination Address Should Error
    [Documentation]         Destination address not 8-byte aligned sets DS_DIRTY
    [Tags]                  aspeed  xdma  boot  alignment
    Create AST2600 Machine
    Setup Command Queue
    # src=0x20000000, dst=0x80001003 (misaligned), len=8
    Write Descriptor        ${SRAM_BASE}  0  0x20000000  0x80001003  0x8
    Write XDMA Register    ${CMDQ_WRP}  0x1
    ${status}=              Read XDMA Register  ${STATUS}
    ${dirty}=               Evaluate  ${status} & ${STATUS_DS_DIRTY}
    Should Not Be Equal As Numbers  ${dirty}  0x0

Large Multi Descriptor Boot Transfer
    [Documentation]         4-descriptor scatter-gather simulating 2MB OS image transfer
    [Tags]                  aspeed  xdma  boot  transfer
    Create AST2600 Machine

    # Write unique patterns at 4 locations in flash
    Write Memory Word       0x20000000  0xBOOT0001
    Write Memory Word       0x20001000  0xBOOT0002
    Write Memory Word       0x20002000  0xBOOT0003
    Write Memory Word       0x20003000  0xBOOT0004

    Setup Command Queue     ${SRAM_BASE}  0x200

    # 4 descriptors: each transfers 8 bytes (small for test speed)
    Write Descriptor        ${SRAM_BASE}  0  0x20000000  0x80010000  0x8
    Write Descriptor        ${SRAM_BASE}  1  0x20001000  0x80010008  0x8
    Write Descriptor        ${SRAM_BASE}  2  0x20002000  0x80010010  0x8
    Write Descriptor        ${SRAM_BASE}  3  0x20003000  0x80010018  0x8

    Write XDMA Register    ${CMDQ_WRP}  0x4

    # Verify completion
    ${status}=              Read XDMA Register  ${STATUS}
    ${comp}=                Evaluate  ${status} & ${STATUS_DS_COMP}
    Should Not Be Equal As Numbers  ${comp}  0x0

    # Verify all 4 segments transferred
    ${v1}=                  Read Memory Word  0x80010000
    ${v2}=                  Read Memory Word  0x80010008
    ${v3}=                  Read Memory Word  0x80010010
    ${v4}=                  Read Memory Word  0x80010018
    Should Be Equal As Numbers  ${v1}  0xBOOT0001
    Should Be Equal As Numbers  ${v2}  0xBOOT0002
    Should Be Equal As Numbers  ${v3}  0xBOOT0003
    Should Be Equal As Numbers  ${v4}  0xBOOT0004

    # RDP should have advanced to 4
    ${rdp}=                 Read XDMA Register  ${CMDQ_RDP}
    Should Be Equal As Numbers  ${rdp}  0x4

Error Halts Chain At Failing Descriptor
    [Documentation]         Error on 2nd descriptor should complete 1st but not 3rd
    [Tags]                  aspeed  xdma  boot  error
    Create AST2600 Machine
    Write Memory Word       0x20000000  0x11111111
    Write Memory Word       0x20002000  0x33333333

    Setup Command Queue

    # Desc 0: valid (8 bytes)
    Write Descriptor        ${SRAM_BASE}  0  0x20000000  0x80001000  0x8
    # Desc 1: invalid (misaligned src)
    Write Descriptor        ${SRAM_BASE}  1  0x20000001  0x80001008  0x8
    # Desc 2: valid (would succeed if reached)
    Write Descriptor        ${SRAM_BASE}  2  0x20002000  0x80001010  0x8

    Write XDMA Register    ${CMDQ_WRP}  0x3

    # First descriptor should have completed
    ${v1}=                  Read Memory Word  0x80001000
    Should Be Equal As Numbers  ${v1}  0x11111111

    # Third descriptor should NOT have executed (chain halted)
    ${v3}=                  Read Memory Word  0x80001010
    Should Be Equal As Numbers  ${v3}  0x0

    # DS_DIRTY should be set
    ${status}=              Read XDMA Register  ${STATUS}
    ${dirty}=               Evaluate  ${status} & ${STATUS_DS_DIRTY}
    Should Not Be Equal As Numbers  ${dirty}  0x0

    # RDP should be at 1 (stopped after first descriptor)
    ${rdp}=                 Read XDMA Register  ${CMDQ_RDP}
    Should Be Equal As Numbers  ${rdp}  0x1
