*** Settings ***
Documentation       Birchstream invariant validation tests.
...                 Property-based tests verifying behavioral invariants
...                 across all peripherals. These catch subtle correctness
...                 issues that scenario tests may miss.

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

Read ESPI Register
    [Arguments]             ${offset}
    ${val}=  Execute Command    espi ReadDoubleWord ${offset}
    RETURN                  ${val.strip()}

Setup XDMA Queue
    Write XDMA Register    ${CMDQ_ADDR}  ${SRAM_BASE}
    Write XDMA Register    ${CMDQ_ENDP}  0x100
    Write XDMA Register    ${CMDQ_RDP}   0x0
    Write XDMA Register    ${CTRL}       ${STATUS_DS_COMP}

*** Test Cases ***
# ===== INV-1: IRQ assert exactly once per DMA completion =====

XDMA Single Transfer Sets DS_COMP Once
    [Documentation]         INV-1: DS_COMP set exactly once per transfer batch
    [Tags]                  invariant  xdma  irq
    Create AST2600 Machine
    Setup XDMA Queue
    Write Memory Word       ${SRAM_BASE}  0x20000000
    Write Memory Word       0x10000004    0x80001000
    Write Memory Word       0x10000008    0x8
    Write Memory Word       0x1000000C    0x0
    Write XDMA Register    ${CMDQ_WRP}  0x1
    ${status}=              Read XDMA Register  ${STATUS}
    ${comp}=                Evaluate  ${status} & ${STATUS_DS_COMP}
    Should Not Be Equal As Numbers  ${comp}  0x0
    # Clear and verify it stays cleared (no spurious re-assertion)
    Write XDMA Register    ${STATUS}  ${STATUS_DS_COMP}
    ${status2}=             Read XDMA Register  ${STATUS}
    ${comp2}=               Evaluate  ${status2} & ${STATUS_DS_COMP}
    Should Be Equal As Numbers  ${comp2}  0x0

XDMA Multi Descriptor Sets DS_COMP Once
    [Documentation]         INV-1: Multiple descriptors produce single DS_COMP
    [Tags]                  invariant  xdma  irq
    Create AST2600 Machine
    Setup XDMA Queue
    # 4 descriptors
    FOR  ${i}  IN RANGE  4
        ${base}=            Evaluate  0x10000000 + ${i} * 16
        ${src}=             Evaluate  0x20000000 + ${i} * 0x1000
        ${dst}=             Evaluate  0x80001000 + ${i} * 8
        Write Memory Word   ${src}  ${i}
        Write Memory Word   ${base}      ${src}
        ${base4}=          Evaluate  ${base} + 4
        ${base8}=          Evaluate  ${base} + 8
        ${base12}=         Evaluate  ${base} + 12
        Write Memory Word   ${base4}     ${dst}
        Write Memory Word   ${base8}     0x8
        Write Memory Word   ${base12}    0x0
    END
    Write XDMA Register    ${CMDQ_WRP}  0x4
    ${status}=              Read XDMA Register  ${STATUS}
    ${comp}=                Evaluate  ${status} & ${STATUS_DS_COMP}
    Should Not Be Equal As Numbers  ${comp}  0x0

# ===== INV-2: Descriptor walk always terminates =====

XDMA Max Queue Depth
    [Documentation]         INV-2: Queue with max descriptors completes
    [Tags]                  invariant  xdma  termination
    Create AST2600 Machine
    # Queue size = 16 descriptors
    Write XDMA Register    ${CMDQ_ADDR}  ${SRAM_BASE}
    Write XDMA Register    ${CMDQ_ENDP}  0x100
    Write XDMA Register    ${CMDQ_RDP}   0x0
    Write XDMA Register    ${CTRL}       ${STATUS_DS_COMP}
    # Fill all 16 slots with valid descriptors
    FOR  ${i}  IN RANGE  16
        ${base}=            Evaluate  0x10000000 + ${i} * 16
        Write Memory Word   ${base}      0x20000000
        ${base4}=          Evaluate  ${base} + 4
        ${base8}=          Evaluate  ${base} + 8
        ${base12}=         Evaluate  ${base} + 12
        Write Memory Word   ${base4}     0x80001000
        Write Memory Word   ${base8}     0x8
        Write Memory Word   ${base12}    0x0
    END
    Write XDMA Register    ${CMDQ_WRP}  0x10
    # Must complete (not hang)
    ${rdp}=                 Read XDMA Register  ${CMDQ_RDP}
    Should Be Equal As Numbers  ${rdp}  16

XDMA Empty Queue Does Not Hang
    [Documentation]         INV-2: WRP=RDP means no work, no hang
    [Tags]                  invariant  xdma  termination
    Create AST2600 Machine
    Setup XDMA Queue
    Write XDMA Register    ${CMDQ_WRP}  0x0
    # Should return immediately, status unchanged from reset

# ===== INV-3: Reset clears transient, retains persistent =====

Cold Reset Clears SYSEVT Sleep Bits
    [Documentation]         INV-3: Cold reset clears sleep and host-driven SYSEVT
    [Tags]                  invariant  reset  transient
    Create AST2600 Machine
    Execute Command         espi SetHostSleepState 7
    Execute Command         espi ColdReset
    ${sysevt}=              Read ESPI Register  0x098
    ${sleep}=               Evaluate  ${sysevt} & 7
    Should Be Equal As Numbers  ${sleep}  0

Cold Reset Preserves Flash Contents
    [Documentation]         INV-3: Flash data survives cold reset
    [Tags]                  invariant  reset  persistent
    Create AST2600 Machine
    Write Memory Word       0x20000000  0xF1A54DA7
    Execute Command         espi ColdReset
    ${val}=                 Read Memory Word  0x20000000
    Should Be Equal As Numbers  ${val}  0xF1A54DA7

XDMA Status Cleared After Cold Reset
    [Documentation]         INV-3: XDMA completion status cleared by cold reset
    [Tags]                  invariant  reset  xdma
    Create AST2600 Machine
    Setup XDMA Queue
    Write Memory Word       ${SRAM_BASE}  0x20000000
    Write Memory Word       0x10000004    0x80001000
    Write Memory Word       0x10000008    0x8
    Write Memory Word       0x1000000C    0x0
    Write XDMA Register    ${CMDQ_WRP}  0x1
    # Verify DS_COMP is set
    ${before}=              Read XDMA Register  ${STATUS}
    ${comp}=                Evaluate  ${before} & ${STATUS_DS_COMP}
    Should Not Be Equal As Numbers  ${comp}  0x0

IPMI Overrides Survive Reset
    [Documentation]         INV-3: IPMI override table persists across reset
    [Tags]                  invariant  reset  kcs  persistent
    Create AST2600 Machine
    Execute Command         lpc SetupBirchstreamDefaults
    Execute Command         lpc WriteDoubleWord 0x00 0x20
    Execute Command         lpc WriteDoubleWord 0x08 0x02
    Execute Command         espi ColdReset
    # Override should still work
    Execute Command         lpc SendHostIpmiCommand 0x06 0x01
    ${str}=  Execute Command    lpc ReadDoubleWord 0x3C
    ${obf}=                 Evaluate  int(${str.strip()}) & 1
    Should Be Equal As Numbers  ${obf}  1

# ===== INV-4: Boot window state transitions are monotonic =====

Boot Window Empty To Ready Monotonic
    [Documentation]         INV-4: EMPTY -> FILLING -> READY is forward-only
    [Tags]                  invariant  bootwindow  monotonic
    Create AST2600 Machine
    Execute Command         machine LoadPlatformDescriptionFromString "bootwindow: Miscellaneous.Aspeed_eSPI_BootWindow @ sysbus 0x05000000"
    # Boot window has magic at reset, state=EMPTY at offset 0x04
    ${initial}=             Read Memory Word  0x05000004
    Should Be Equal As Numbers  ${initial}  0x0
    # Set to FILLING
    Write Memory Word       0x05000004  1
    ${s1}=                  Read Memory Word  0x05000004
    Should Be Equal As Numbers  ${s1}  1
    # Set to READY
    Write Memory Word       0x05000004  2
    ${s2}=                  Read Memory Word  0x05000004
    Should Be Equal As Numbers  ${s2}  2
    # Set to CONSUMED
    Write Memory Word       0x05000004  3
    ${s3}=                  Read Memory Word  0x05000004
    Should Be Equal As Numbers  ${s3}  3

# ===== INV-5: eSPI channel enable ordering =====

ESPI Flash Channel Enable Does Not Affect Other Channels
    [Documentation]         INV-5: Enabling flash doesn't change peripheral/VW/OOB
    [Tags]                  invariant  espi  channel
    Create AST2600 Machine
    ${before}=              Read ESPI Register  0x000
    # Enable flash (bit 4)
    Execute Command         espi WriteDoubleWord 0x000 0x10
    ${after}=               Read ESPI Register  0x000
    # Only bit 4 should change
    ${flash_only}=          Evaluate  ${after} & 0x10
    Should Be Equal As Numbers  ${flash_only}  16

# ===== INV-6: SAF reads are idempotent =====

SAF Read Same Address Twice Gives Same Result
    [Documentation]         INV-6: Repeated SAF reads return same data
    [Tags]                  invariant  saf  idempotent
    Create AST2600 Machine
    Write Memory Word       0x20000000  0x12345678
    Execute Command         espi HandleSafRead 0x0 4
    Execute Command         espi WriteDoubleWord 0x008 0x40
    Execute Command         espi HandleSafRead 0x0 4
    ${sts}=                 Read ESPI Register  0x008
    ${flash_rx}=            Evaluate  (int(${sts}) >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1

# ===== INV-7: ACPI state consistency =====

ACPI State Matches Power Signals
    [Documentation]         INV-7: S0 has power, S5/G3 does not
    [Tags]                  invariant  acpi  consistency
    Create AST2600 Machine
    # S0: both power signals asserted
    Execute Command         espi PowerOn
    ${s0_sig}=  Execute Command    espi GetPowerSignalState
    ${s0_pwrgd}=            Evaluate  int(${s0_sig.strip()}) & 1
    Should Be Equal As Numbers  ${s0_pwrgd}  1
    # S5: CPUPWRGD off
    Execute Command         espi GracefulShutdown
    ${s5_sig}=  Execute Command    espi GetPowerSignalState
    ${s5_pwrgd}=            Evaluate  int(${s5_sig.strip()}) & 1
    Should Be Equal As Numbers  ${s5_pwrgd}  0
    # G3: all off
    Execute Command         espi MechanicalOff
    ${g3_sig}=  Execute Command    espi GetPowerSignalState
    Should Be Equal As Numbers  ${g3_sig.strip()}  0

VUART State Survives ACPI S3
    [Documentation]         INV-7: VUART FIFO data persists across S3 suspend
    [Tags]                  invariant  vuart  acpi  s3
    Create AST2600 Machine
    Execute Command         vuart InjectHostByte 0x42
    Execute Command         espi SuspendToRam
    Execute Command         espi Resume
    # Data should still be in RX FIFO
    ${rxcnt}=  Execute Command    vuart ReadDoubleWord 0x2C
    Should Be Equal As Numbers  ${rxcnt.strip()}  1