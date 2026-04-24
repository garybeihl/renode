*** Variables ***
${FLASH_BASE}       0x20000000
${DRAM_BASE}        0x80000000
${ESPI_INT_STS}     0x008
${ESPI_FLASH_RX_CTRL}  0x064

*** Keywords ***
Create AST2600 Machine
    Execute Command         mach create "ast2600"
    Execute Command         machine LoadPlatformDescription @platforms/boards/ast2600/ast2600-evb.repl

Write Memory Word
    [Arguments]             ${addr}  ${value}
    Execute Command         sysbus WriteDoubleWord ${addr} ${value}

Read Memory Byte
    [Arguments]             ${addr}
    ${val}=  Execute Command    sysbus ReadByte ${addr}
    RETURN                  ${val.strip()}

Read ESPI Register
    [Arguments]             ${offset}
    ${val}=  Execute Command    espi ReadDoubleWord ${offset}
    RETURN                  ${val.strip()}

Trigger SAF Read
    [Documentation]         Invoke HandleSafRead on the eSPI controller
    [Arguments]             ${host_addr}  ${length}  ${tag}=0
    Execute Command         espi HandleSafRead ${host_addr} ${length} ${tag}

Read Flash RX Byte
    [Documentation]         Read one byte from Flash RX FIFO (offset 0x068)
    ${val}=  Execute Command    espi ReadDoubleWord 0x068
    RETURN                  ${val.strip()}

*** Test Cases ***
SAF Read From BIOS Region
    [Documentation]         Read 4 bytes from host addr 0x0 -> FMC flash @ 0x20000000
    [Tags]                  aspeed  espi  saf
    Create AST2600 Machine

    # Write test pattern to FMC flash window
    Write Memory Word       0x20000000  0xAABBCCDD

    # Trigger SAF read: host addr 0x0, 4 bytes
    Trigger SAF Read        0x0  4

    # Verify Flash RX completion interrupt
    ${sts}=                 Read ESPI Register  ${ESPI_INT_STS}
    ${flash_rx}=            Evaluate  (${sts} >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1

SAF Read From OS DRAM Region
    [Documentation]         Read 4 bytes from host addr 0x01000000 -> DRAM @ 0x82000000
    [Tags]                  aspeed  espi  saf
    Create AST2600 Machine

    # Write test pattern to DRAM at OS region base
    Write Memory Word       0x82000000  0x12345678

    # Trigger SAF read: host addr 0x01000000 (OS region start), 4 bytes
    Trigger SAF Read        0x01000000  4

    # Verify Flash RX completion
    ${sts}=                 Read ESPI Register  ${ESPI_INT_STS}
    ${flash_rx}=            Evaluate  (${sts} >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1

SAF Read From Hole Returns 0xFF
    [Documentation]         Read from unmapped region (0x30000000+) returns 0xFF
    [Tags]                  aspeed  espi  saf  hole
    Create AST2600 Machine

    # Trigger SAF read from hole region
    Trigger SAF Read        0x30000000  4

    # Verify Flash RX completion
    ${sts}=                 Read ESPI Register  ${ESPI_INT_STS}
    ${flash_rx}=            Evaluate  (${sts} >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1

    # Read Flash RX data - should be 0xFF
    ${val}=                 Read Flash RX Byte
    Should Be Equal As Numbers  ${val}  0xFF

SAF Cross Boundary Read
    [Documentation]         Read spanning BIOS/OS boundary at 16MB
    [Tags]                  aspeed  espi  saf  boundary
    Create AST2600 Machine

    # Write pattern at end of BIOS region (flash offset 0xFFFFFC = 16MB - 4)
    Write Memory Word       0x20FFFFFC  0xAAAAAAAA

    # Write pattern at start of OS region (DRAM @ 0x82000000)
    Write Memory Word       0x82000000  0xBBBBBBBB

    # Read 8 bytes crossing the 16MB boundary: 4 from BIOS, 4 from OS
    Trigger SAF Read        0x00FFFFFC  8

    # Verify Flash RX completion
    ${sts}=                 Read ESPI Register  ${ESPI_INT_STS}
    ${flash_rx}=            Evaluate  (${sts} >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1

SAF Read At OS Region End
    [Documentation]         Read near the end of OS region (boundary to hole)
    [Tags]                  aspeed  espi  saf  boundary
    Create AST2600 Machine

    # Write pattern at end of OS region
    # OS region: host 0x01000000-0x2FFFFFFF -> DRAM offset = host - 0x01000000
    # Host 0x2FFFFFFC -> DRAM 0x82000000 + 0x1EFFFFFC = 0xA0FFFFFC
    # This may exceed our DRAM size (1GB ends at 0xC0000000), but should work

    # Trigger SAF read at boundary between OS and hole
    # Read 8 bytes: 4 from OS region, 4 from hole
    Trigger SAF Read        0x2FFFFFFC  8

    # Verify completion (data is mix of DRAM content and 0xFF fill)
    ${sts}=                 Read ESPI Register  ${ESPI_INT_STS}
    ${flash_rx}=            Evaluate  (${sts} >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1

SAF Rejects Oversized Read
    [Documentation]         Read > 64 bytes should be rejected
    [Tags]                  aspeed  espi  saf  error
    Create AST2600 Machine

    # Attempt 65-byte read (exceeds eSPI max burst of 64)
    Trigger SAF Read        0x0  65

    # Flash RX completion should NOT be set (read was rejected)
    ${sts}=                 Read ESPI Register  ${ESPI_INT_STS}
    ${flash_rx}=            Evaluate  (${sts} >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  0
