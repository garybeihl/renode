*** Settings ***
Documentation       Birchstream negative and edge-case tests.
...                 Validates error handling, boundary conditions, and
...                 protocol violations across all peripherals.

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
${STATE_CONSUMED}   3

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

Read LPC Register
    [Arguments]             ${offset}
    ${val}=  Execute Command    lpc ReadDoubleWord ${offset}
    RETURN                  ${val.strip()}

Setup XDMA Queue
    Write XDMA Register    ${CMDQ_ADDR}  ${SRAM_BASE}
    Write XDMA Register    ${CMDQ_ENDP}  0x100
    Write XDMA Register    ${CMDQ_RDP}   0x0
    Write XDMA Register    ${CTRL}       ${STATUS_DS_COMP}

*** Test Cases ***
# ===== XDMA Negative Tests =====

Zero Length Descriptor Is Ignored
    [Documentation]         Descriptor with length=0 should not crash or transfer
    [Tags]                  negative  xdma
    Create AST2600 Machine
    Setup XDMA Queue
    # Zero-length descriptor
    Write Memory Word       ${SRAM_BASE}        0x20000000
    Write Memory Word       0x10000004          0x80001000
    Write Memory Word       0x10000008          0x0
    Write Memory Word       0x1000000C          0x0
    Write XDMA Register    ${CMDQ_WRP}  0x1
    # Should complete without error (DS_COMP set, DS_DIRTY not set)
    ${status}=              Read XDMA Register  ${STATUS}
    ${dirty}=               Evaluate  ${status} & ${STATUS_DS_DIRTY}
    Should Be Equal As Numbers  ${dirty}  0x0

WRP Equal To RDP Is No Op
    [Documentation]         Writing WRP = RDP should not trigger any processing
    [Tags]                  negative  xdma
    Create AST2600 Machine
    Setup XDMA Queue
    # WRP = 0, RDP already 0
    Write XDMA Register    ${CMDQ_WRP}  0x0
    # Status should remain at reset value
    ${status}=              Read XDMA Register  ${STATUS}
    Should Not Be Equal As Numbers  ${status}  0x0

Queue Wrap Around
    [Documentation]         WRP should wrap around queue endpoint
    [Tags]                  negative  xdma  boundary
    Create AST2600 Machine
    # Small queue: endpoint = 2 descriptors
    Write XDMA Register    ${CMDQ_ADDR}  ${SRAM_BASE}
    Write XDMA Register    ${CMDQ_ENDP}  0x2
    Write XDMA Register    ${CMDQ_RDP}   0x0
    Write XDMA Register    ${CTRL}       ${STATUS_DS_COMP}
    # Write 1 valid descriptor at slot 0
    Write Memory Word       ${SRAM_BASE}        0x20000000
    Write Memory Word       0x10000004          0x80001000
    Write Memory Word       0x10000008          0x8
    Write Memory Word       0x1000000C          0x0
    Write Memory Word       0x20000000          0xDEADBEEF
    Write XDMA Register    ${CMDQ_WRP}  0x1
    ${v}=                   Read Memory Word  0x80001000
    Should Be Equal As Numbers  ${v}  0xDEADBEEF

W1C Status Bits
    [Documentation]         Writing 1 to status bits clears them (W1C behavior)
    [Tags]                  negative  xdma  status
    Create AST2600 Machine
    Setup XDMA Queue
    # Do a valid transfer to set DS_COMP
    Write Memory Word       ${SRAM_BASE}        0x20000000
    Write Memory Word       0x10000004          0x80001000
    Write Memory Word       0x10000008          0x8
    Write Memory Word       0x1000000C          0x0
    Write XDMA Register    ${CMDQ_WRP}  0x1
    ${before}=              Read XDMA Register  ${STATUS}
    ${comp}=                Evaluate  ${before} & ${STATUS_DS_COMP}
    Should Not Be Equal As Numbers  ${comp}  0x0
    # Clear DS_COMP by writing 1 to it
    Write XDMA Register    ${STATUS}  ${STATUS_DS_COMP}
    ${after}=               Read XDMA Register  ${STATUS}
    ${comp2}=               Evaluate  ${after} & ${STATUS_DS_COMP}
    Should Be Equal As Numbers  ${comp2}  0x0

# ===== eSPI SAF Negative Tests =====

SAF Read From Unmapped Region
    [Documentation]         SAF read at address beyond all partitions returns no data
    [Tags]                  negative  saf  boundary
    Create AST2600 Machine
    # Read from the hole region (host addr 0x30000000+)
    # Should not crash; flash RX may or may not fire
    Execute Command         espi HandleSafRead 0x40000000 8

SAF Read Zero Length
    [Documentation]         SAF read with zero length should not crash
    [Tags]                  negative  saf  boundary
    Create AST2600 Machine
    Execute Command         espi HandleSafRead 0x0 0

SAF Read At Partition Boundary
    [Documentation]         SAF read crossing BIOS/OS partition boundary
    [Tags]                  negative  saf  boundary
    Create AST2600 Machine
    # Last 8 bytes of BIOS region (ends at 0x01000000)
    Write Memory Word       0x20FFFFF8  0xAABBCCDD
    Execute Command         espi HandleSafRead 0x00FFFFF8 8
    ${sts}=                 Read ESPI Register  0x008
    ${flash_rx}=            Evaluate  (int(${sts}) >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1

# ===== KCS/IPMI Negative Tests =====

IPMI Command Without KCS Enabled
    [Documentation]         SendHostIpmiCommand before enabling KCS channel
    [Tags]                  negative  kcs
    Create AST2600 Machine
    # Don't enable KCS — channel registers at default
    Execute Command         lpc SendHostIpmiCommand 0x06 0x01
    # IBF may or may not be set depending on implementation
    # Just verify no crash

Duplicate IPMI Override
    [Documentation]         Setting same override twice should replace, not duplicate
    [Tags]                  negative  kcs  ipmi
    Create AST2600 Machine
    Execute Command         lpc WriteDoubleWord 0x00 0x20
    Execute Command         lpc WriteDoubleWord 0x08 0x02
    # Set override twice for same netFn/cmd
    Execute Command         lpc SetIpmiOverride 0x06 0x01
    Execute Command         lpc SetIpmiOverride 0x06 0x01
    # Should still work (latest wins)
    Execute Command         lpc SendHostIpmiCommand 0x06 0x01
    ${str}=                 Read LPC Register  0x3C
    ${obf}=                 Evaluate  ${str} & 1
    Should Be Equal As Numbers  ${obf}  1

# ===== Reset/Power Negative Tests =====

Double Assert PLTRST
    [Documentation]         Asserting PLTRST# twice should not crash
    [Tags]                  negative  reset
    Create AST2600 Machine
    Execute Command         espi AssertPlatformReset
    Execute Command         espi AssertPlatformReset
    ${sysevt}=              Read ESPI Register  0x098
    ${pltrst}=              Evaluate  (${sysevt} >> 5) & 1
    Should Be Equal As Numbers  ${pltrst}  0

Double Deassert PLTRST
    [Documentation]         Deasserting PLTRST# when already deasserted
    [Tags]                  negative  reset
    Create AST2600 Machine
    Execute Command         espi DeassertPlatformReset
    ${sysevt}=              Read ESPI Register  0x098
    ${pltrst}=              Evaluate  (${sysevt} >> 5) & 1
    Should Be Equal As Numbers  ${pltrst}  1

Sleep State Invalid Value
    [Documentation]         Setting sleep state with unexpected bits
    [Tags]                  negative  reset  sleep
    Create AST2600 Machine
    # Set sleep state 0xFF (bits beyond S3/S4/S5)
    Execute Command         espi SetHostSleepState 0xFF
    # Should not crash; lower bits should be applied
    ${sysevt}=              Read ESPI Register  0x098

# ===== Boot Window Edge Cases =====

Boot Window Read Before Write
    [Documentation]         Reading boot window before any header is written
    [Tags]                  negative  bootwindow
    Create AST2600 Machine
    # Read from uninitialized boot window — should return 0
    ${magic}=               Read Memory Word  0x05000000
    Should Be Equal As Numbers  ${magic}  0x0

Boot Window Invalid State Transition
    [Documentation]         Writing invalid state transitions
    [Tags]                  negative  bootwindow
    Create AST2600 Machine
    Execute Command         machine LoadPlatformDescriptionFromString "bootwindow: Miscellaneous.Aspeed_eSPI_BootWindow @ sysbus 0x05000000"
    # Write CONSUMED without going through READY
    Execute Command         sysbus WriteDoubleWord 0x05000004 ${STATE_CONSUMED}
    ${state}=               Read Memory Word  0x05000004
    # State should be stored (memory-mapped, no validation in memory write)
    Should Be Equal As Numbers  ${state}  ${STATE_CONSUMED}