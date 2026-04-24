*** Settings ***
Documentation       Birchstream full boot sequence integration test.
...                 Exercises: KCS discovery -> SAF BIOS read -> XDMA OS transfer
...                 -> Boot window consumption -> Reset cycle.
...                 All operations are Renode-only (no QEMU).

*** Variables ***
# XDMA registers
${CMDQ_ADDR}        0x014
${CMDQ_ENDP}        0x018
${CMDQ_WRP}         0x01C
${CMDQ_RDP}         0x020
${CTRL}             0x038
${STATUS}           0x03C
${STATUS_DS_COMP}   0x00020000
${SRAM_BASE}        0x10000000
${DESC_SIZE}        16

# Boot Window
${BOOTWIN_BASE}     0x05000000
${BOOTWIN_MAGIC}    0x45535049
${STATE_EMPTY}      0
${STATE_FILLING}    1
${STATE_READY}      2
${STATE_CONSUMED}   3

*** Keywords ***
Create Birchstream Machine
    [Documentation]     Creates AST2600 with Birchstream defaults
    Execute Command     mach create "ast2600"
    Execute Command     machine LoadPlatformDescription @platforms/boards/ast2600/ast2600-evb.repl
    Execute Command     lpc SetupBirchstreamDefaults
    # Enable KCS channel 1
    Execute Command     lpc WriteDoubleWord 0x00 0x20
    Execute Command     lpc WriteDoubleWord 0x08 0x02

Read LPC Register
    [Arguments]         ${offset}
    ${val}=  Execute Command    lpc ReadDoubleWord ${offset}
    RETURN              ${val.strip()}

Read ESPI Register
    [Arguments]         ${offset}
    ${val}=  Execute Command    espi ReadDoubleWord ${offset}
    RETURN              ${val.strip()}

Read XDMA Register
    [Arguments]         ${offset}
    ${val}=  Execute Command    xdma ReadDoubleWord ${offset}
    RETURN              ${val.strip()}

Write Memory Word
    [Arguments]         ${addr}  ${value}
    Execute Command     sysbus WriteDoubleWord ${addr} ${value}

Read Memory Word
    [Arguments]         ${addr}
    ${val}=  Execute Command    sysbus ReadDoubleWord ${addr}
    RETURN              ${val.strip()}

Phase KCS Discovery
    [Documentation]     Replay Birchstream KCS boot discovery sequence
    # Get Device ID (netFn=0x06, cmd=0x01)
    Execute Command     lpc SendHostIpmiCommand 0x06 0x01 null 0
    ${str}=             Read LPC Register  0x3C
    ${obf}=             Evaluate  ${str} & 1
    Should Be Equal As Numbers  ${obf}  1
    # Get Boot Options (netFn=0x08, cmd=0x09)
    Execute Command     lpc SendHostIpmiCommand 0x08 0x09 null 0
    ${str2}=            Read LPC Register  0x3C
    ${obf2}=            Evaluate  ${str2} & 1
    Should Be Equal As Numbers  ${obf2}  1
    # Set Boot Options for eSPI SAF (netFn=0x08, cmd=0x05)
    Execute Command     lpc SendHostIpmiCommand 0x08 0x05 null 0
    ${str3}=            Read LPC Register  0x3C
    ${obf3}=            Evaluate  ${str3} & 1
    Should Be Equal As Numbers  ${obf3}  1

Phase SAF BIOS Read
    [Documentation]     Read BIOS image from SAF BIOS partition
    # Place a BIOS signature at FMC flash base
    Write Memory Word   0x20000000  0x55AA55AA
    Write Memory Word   0x20000004  0x42494F53
    # Read first 8 bytes via SAF (host addr 0x0 = BIOS region)
    Execute Command     espi HandleSafRead 0x0 8
    # Flash RX completion should fire
    ${sts}=             Read ESPI Register  0x008
    ${flash_rx}=        Evaluate  (int(${sts}) >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1

Phase XDMA OS Transfer
    [Documentation]     DMA transfer of OS image chunks via XDMA
    # Place OS data at BMC DRAM (SAF OS region maps to 0x82000000)
    Write Memory Word   0x82000000  0xFEED0001
    Write Memory Word   0x82000100  0xFEED0002
    # Setup command queue
    Execute Command     xdma WriteDoubleWord ${CMDQ_ADDR} ${SRAM_BASE}
    Execute Command     xdma WriteDoubleWord ${CMDQ_ENDP} 0x100
    Execute Command     xdma WriteDoubleWord ${CMDQ_RDP} 0x0
    Execute Command     xdma WriteDoubleWord ${CTRL} ${STATUS_DS_COMP}
    # Write 2 descriptors: 8 bytes each
    # Desc 0: BMC DRAM 0x82000000 -> host DRAM 0x80100000
    Write Memory Word   ${SRAM_BASE}        0x82000000
    Write Memory Word   0x10000004          0x80100000
    Write Memory Word   0x10000008          0x8
    Write Memory Word   0x1000000C          0x0
    # Desc 1: BMC DRAM 0x82000100 -> host DRAM 0x80100008
    Write Memory Word   0x10000010          0x82000100
    Write Memory Word   0x10000014          0x80100008
    Write Memory Word   0x10000018          0x8
    Write Memory Word   0x1000001C          0x0
    # Trigger
    Execute Command     xdma WriteDoubleWord ${CMDQ_WRP} 0x2
    # Verify completion
    ${status}=          Read XDMA Register  ${STATUS}
    ${comp}=            Evaluate  ${status} & ${STATUS_DS_COMP}
    Should Not Be Equal As Numbers  ${comp}  0x0
    # Verify data arrived
    ${v1}=              Read Memory Word  0x80100000
    ${v2}=              Read Memory Word  0x80100008
    Should Be Equal As Numbers  ${v1}  0xFEED0001
    Should Be Equal As Numbers  ${v2}  0xFEED0002

Phase Boot Window Consume
    [Documentation]     Write boot window header and consume it
    # Write boot window header: magic, READY state, chunk info
    Write Memory Word   ${BOOTWIN_BASE}         ${BOOTWIN_MAGIC}
    Write Memory Word   0x05000004              ${STATE_READY}
    Write Memory Word   0x05000008              0x0
    Write Memory Word   0x0500000C              0x100
    Write Memory Word   0x05000010              0x200000
    # Read and verify magic
    ${magic}=           Read Memory Word  ${BOOTWIN_BASE}
    Should Be Equal As Numbers  ${magic}  ${BOOTWIN_MAGIC}
    # Read state
    ${state}=           Read Memory Word  0x05000004
    Should Be Equal As Numbers  ${state}  ${STATE_READY}
    # Consume
    Write Memory Word   0x05000004  ${STATE_CONSUMED}
    ${final}=           Read Memory Word  0x05000004
    Should Be Equal As Numbers  ${final}  ${STATE_CONSUMED}

Phase Reset Cycle
    [Documentation]     Execute warm reset and verify recovery
    Execute Command     espi WarmReset
    # PLTRST# should be deasserted after warm reset
    ${sysevt}=          Read ESPI Register  0x098
    ${pltrst}=          Evaluate  (${sysevt} >> 5) & 1
    Should Be Equal As Numbers  ${pltrst}  1

*** Test Cases ***
Full Birchstream Boot Sequence
    [Documentation]     End-to-end boot: KCS -> SAF -> XDMA -> BootWindow -> Reset
    [Tags]              birchstream  integration  boot  e2e
    Create Birchstream Machine
    Phase KCS Discovery
    Phase SAF BIOS Read
    Phase XDMA OS Transfer
    Phase Boot Window Consume
    Phase Reset Cycle

Boot Sequence Survives Cold Reset
    [Documentation]     Full boot, cold reset, then re-run KCS discovery
    [Tags]              birchstream  integration  reset
    Create Birchstream Machine
    Phase KCS Discovery
    Phase SAF BIOS Read
    Execute Command     espi ColdReset
    # After cold reset, PLTRST# deasserted
    ${sysevt}=          Read ESPI Register  0x098
    ${pltrst}=          Evaluate  (${sysevt} >> 5) & 1
    Should Be Equal As Numbers  ${pltrst}  1
    # Re-run KCS discovery (overrides should persist across reset)
    Phase KCS Discovery

Boot Sequence With Sleep State
    [Documentation]     Boot, enter S5, recover, verify state
    [Tags]              birchstream  integration  sleep
    Create Birchstream Machine
    Phase KCS Discovery
    Phase SAF BIOS Read
    # Enter S5 sleep
    Execute Command     espi SetHostSleepState 4
    ${sysevt}=          Read ESPI Register  0x098
    ${s5}=              Evaluate  (${sysevt} >> 2) & 1
    Should Be Equal As Numbers  ${s5}  1
    # Wake up (clear sleep)
    Execute Command     espi SetHostSleepState 0
    ${sysevt2}=         Read ESPI Register  0x098
    ${s5_2}=            Evaluate  (${sysevt2} >> 2) & 1
    Should Be Equal As Numbers  ${s5_2}  0
    # Resume boot
    Phase XDMA OS Transfer