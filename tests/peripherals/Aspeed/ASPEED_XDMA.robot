*** Variables ***
${CMDQ_ADDR}        0x014
${CMDQ_ENDP}        0x018
${CMDQ_WRP}         0x01C
${CMDQ_RDP}         0x020
${CTRL}             0x038
${STATUS}           0x03C
${STATUS_RESET}     0xF8000000
${CTRL_MASK}        0x017003FF

# Status bits (AST2600)
${STATUS_US_COMP}   0x00010000
${STATUS_DS_COMP}   0x00020000
${STATUS_DS_DIRTY}  0x00040000

# Memory regions for DMA testing
${FLASH_BASE}       0x20000000
${DRAM_BASE}        0x80000000
${SRAM_BASE}        0x10000000

# Descriptor size
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
    [Documentation]         Configure XDMA command queue in SRAM
    [Arguments]             ${base}=${SRAM_BASE}  ${size}=0x100
    Write XDMA Register    ${CMDQ_ADDR}  ${base}
    Write XDMA Register    ${CMDQ_ENDP}  ${size}
    Write XDMA Register    ${CMDQ_RDP}   0x0
    # Enable DS_COMP IRQ in CTRL
    Write XDMA Register    ${CTRL}       ${STATUS_DS_COMP}

Write Descriptor
    [Documentation]         Write a 16-byte descriptor at queue entry index
    [Arguments]             ${queue_base}  ${index}  ${src}  ${dst}  ${length}  ${flags}=0x0
    ${desc_addr}=           Evaluate  ${queue_base} + ${index} * ${DESC_SIZE}
    Write Memory Word       ${desc_addr}       ${src}
    Write Memory Word       ${desc_addr}+4     ${dst}
    Write Memory Word       ${desc_addr}+8     ${length}
    Write Memory Word       ${desc_addr}+12    ${flags}

Trigger DMA
    [Documentation]         Write WRP to trigger DMA processing
    [Arguments]             ${wrp_value}
    Write XDMA Register    ${CMDQ_WRP}  ${wrp_value}

*** Test Cases ***
Should Load Platform With XDMA
    [Documentation]         Verify XDMA is accessible after platform load
    [Tags]                  aspeed  xdma  platform
    Create AST2600 Machine
    ${val}=                 Read XDMA Register  ${STATUS}
    Should Not Be Equal As Numbers  ${val}  0xFFFFFFFF

IRQ Status Should Reset To F8000000
    [Documentation]         QEMU resets IRQ_STATUS to 0xF8000000
    [Tags]                  aspeed  xdma  register
    Create AST2600 Machine
    ${val}=                 Read XDMA Register  ${STATUS}
    Should Be Equal As Numbers  ${val}  ${STATUS_RESET}

IRQ Status Should Be W1C
    [Documentation]         Writing 1 clears STATUS bits
    [Tags]                  aspeed  xdma  interrupt
    Create AST2600 Machine
    Write XDMA Register    ${STATUS}  0x08000000
    ${val}=                 Read XDMA Register  ${STATUS}
    Should Be Equal As Numbers  ${val}  0xF0000000

IRQ Control Should Mask High Bits
    [Documentation]         CTRL write mask is 0x017003FF
    [Tags]                  aspeed  xdma  register
    Create AST2600 Machine
    Write XDMA Register    ${CTRL}  0xFFFFFFFF
    ${val}=                 Read XDMA Register  ${CTRL}
    Should Be Equal As Numbers  ${val}  ${CTRL_MASK}

Command Queue Registers Should Be Writable
    [Documentation]         CMDQ address and endpoint are R/W
    [Tags]                  aspeed  xdma  register
    Create AST2600 Machine
    Write XDMA Register    ${CMDQ_ADDR}  0x10000000
    ${val}=                 Read XDMA Register  ${CMDQ_ADDR}
    Should Be Equal As Numbers  ${val}  0x10000000
    Write XDMA Register    ${CMDQ_ENDP}  0x10001000
    ${val}=                 Read XDMA Register  ${CMDQ_ENDP}
    Should Be Equal As Numbers  ${val}  0x10001000

Other Registers Should Default To Zero
    [Documentation]         Non-status registers default to 0
    [Tags]                  aspeed  xdma  register
    Create AST2600 Machine
    ${val}=                 Read XDMA Register  ${CMDQ_ADDR}
    Should Be Equal As Numbers  ${val}  0x0
    ${val}=                 Read XDMA Register  ${CTRL}
    Should Be Equal As Numbers  ${val}  0x0

Single Descriptor DMA Transfer
    [Documentation]         DMA 8 bytes from flash to DRAM, verify DRAM contents
    [Tags]                  aspeed  xdma  dma
    Create AST2600 Machine

    # Write test pattern to flash (FMC window at 0x20000000)
    Write Memory Word       0x20000000  0xDEADBEEF
    Write Memory Word       0x20000004  0xCAFEBABE

    # Setup command queue in SRAM
    Setup Command Queue     ${SRAM_BASE}  0x100

    # Write descriptor: src=flash, dst=DRAM+0x1000, len=8
    Write Descriptor        ${SRAM_BASE}  0  0x20000000  0x80001000  0x8

    # Trigger DMA by advancing WRP
    Trigger DMA             0x1

    # Verify DRAM contents
    ${val1}=                Read Memory Word  0x80001000
    Should Be Equal As Numbers  ${val1}  0xDEADBEEF
    ${val2}=                Read Memory Word  0x80001004
    Should Be Equal As Numbers  ${val2}  0xCAFEBABE

    # Verify completion status
    ${status}=              Read XDMA Register  ${STATUS}
    ${masked}=              Evaluate  ${status} & ${STATUS_DS_COMP}
    Should Not Be Equal As Numbers  ${masked}  0x0

    # Verify RDP advanced
    ${rdp}=                 Read XDMA Register  ${CMDQ_RDP}
    Should Be Equal As Numbers  ${rdp}  0x1

Multi Descriptor Chain DMA
    [Documentation]         3-descriptor scatter-gather, verify all segments
    [Tags]                  aspeed  xdma  dma  chain
    Create AST2600 Machine

    # Write patterns to flash
    Write Memory Word       0x20000000  0x11111111
    Write Memory Word       0x20000004  0x22222222
    Write Memory Word       0x20000100  0x33333333
    Write Memory Word       0x20000104  0x44444444
    Write Memory Word       0x20000200  0x55555555
    Write Memory Word       0x20000204  0x66666666

    # Setup command queue
    Setup Command Queue     ${SRAM_BASE}  0x100

    # Write 3 descriptors
    Write Descriptor        ${SRAM_BASE}  0  0x20000000  0x80002000  0x8
    Write Descriptor        ${SRAM_BASE}  1  0x20000100  0x80002008  0x8
    Write Descriptor        ${SRAM_BASE}  2  0x20000200  0x80002010  0x8

    # Trigger: WRP=3 (3 entries to process)
    Trigger DMA             0x3

    # Verify all segments
    ${v1}=                  Read Memory Word  0x80002000
    Should Be Equal As Numbers  ${v1}  0x11111111
    ${v2}=                  Read Memory Word  0x80002008
    Should Be Equal As Numbers  ${v2}  0x33333333
    ${v3}=                  Read Memory Word  0x80002010
    Should Be Equal As Numbers  ${v3}  0x55555555

    # Verify RDP advanced to 3
    ${rdp}=                 Read XDMA Register  ${CMDQ_RDP}
    Should Be Equal As Numbers  ${rdp}  0x3

Zero Length Descriptor Should Error
    [Documentation]         Zero-length descriptor sets DS_DIRTY error
    [Tags]                  aspeed  xdma  dma  error
    Create AST2600 Machine
    Setup Command Queue     ${SRAM_BASE}  0x100

    # Descriptor with length=0
    Write Descriptor        ${SRAM_BASE}  0  0x20000000  0x80001000  0x0

    # Enable DS_DIRTY IRQ
    Write XDMA Register    ${CTRL}  ${STATUS_DS_DIRTY}

    Trigger DMA             0x1

    ${status}=              Read XDMA Register  ${STATUS}
    ${masked}=              Evaluate  ${status} & ${STATUS_DS_DIRTY}
    Should Not Be Equal As Numbers  ${masked}  0x0

Misaligned Length Should Error
    [Documentation]         Non-8-byte-aligned length sets DS_DIRTY error
    [Tags]                  aspeed  xdma  dma  error
    Create AST2600 Machine
    Setup Command Queue     ${SRAM_BASE}  0x100

    # Descriptor with length=5 (not 8-byte aligned)
    Write Descriptor        ${SRAM_BASE}  0  0x20000000  0x80001000  0x5

    Trigger DMA             0x1

    ${status}=              Read XDMA Register  ${STATUS}
    ${masked}=              Evaluate  ${status} & ${STATUS_DS_DIRTY}
    Should Not Be Equal As Numbers  ${masked}  0x0

W1C Should Clear Completion Status
    [Documentation]         Write-1-to-clear on STATUS register
    [Tags]                  aspeed  xdma  interrupt
    Create AST2600 Machine
    Setup Command Queue     ${SRAM_BASE}  0x100
    Write Memory Word       0x20000000  0xAA
    Write Descriptor        ${SRAM_BASE}  0  0x20000000  0x80001000  0x8
    Trigger DMA             0x1

    # Verify DS_COMP is set
    ${status}=              Read XDMA Register  ${STATUS}
    ${masked}=              Evaluate  ${status} & ${STATUS_DS_COMP}
    Should Not Be Equal As Numbers  ${masked}  0x0

    # Clear it via W1C
    Write XDMA Register    ${STATUS}  ${STATUS_DS_COMP}
    ${status2}=             Read XDMA Register  ${STATUS}
    ${masked2}=             Evaluate  ${status2} & ${STATUS_DS_COMP}
    Should Be Equal As Numbers  ${masked2}  0x0
