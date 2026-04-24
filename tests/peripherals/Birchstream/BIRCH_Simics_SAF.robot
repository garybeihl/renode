*** Settings ***
Documentation       Simics-parity SAF orchestrator tests.
...                 Ports the 18 Simics SAF orchestrator test scenarios.
...                 Tests cover boot header lifecycle, image transfer,
...                 partition routing, and error recovery.

*** Keywords ***
Create AST2600 Machine
    Execute Command         mach create "ast2600"
    Execute Command         machine LoadPlatformDescription @platforms/boards/ast2600/ast2600-evb.repl

Read ESPI Register
    [Arguments]             ${offset}
    ${val}=  Execute Command    espi ReadDoubleWord ${offset}
    RETURN                  ${val.strip()}

Write Memory Word
    [Arguments]             ${addr}  ${value}
    Execute Command         sysbus WriteDoubleWord ${addr} ${value}

Read Memory Word
    [Arguments]             ${addr}
    ${val}=  Execute Command    sysbus ReadDoubleWord ${addr}
    RETURN                  ${val.strip()}

Write SAF Header
    [Documentation]         Write a standard SAF boot header to DRAM OS region
    [Arguments]             ${image_size}=0x200000  ${entry}=0x80100000
    # Magic = "SAFB" = 0x53414642
    Write Memory Word       0x82000000  0x53414642
    # Version = 1
    Write Memory Word       0x82000004  0x00000001
    # Image size
    Write Memory Word       0x82000008  ${image_size}
    # Entry point
    Write Memory Word       0x8200000C  ${entry}
    # CRC placeholder
    Write Memory Word       0x82000010  0x00000000
    # Flags = 0
    Write Memory Word       0x82000014  0x00000000

*** Test Cases ***
# ===== SAF Boot Header Lifecycle =====

SAF Header Magic Verification
    [Documentation]         Verify SAF boot header magic is correct (Simics SAF test 1)
    [Tags]                  simics  saf  header
    Create AST2600 Machine
    Write SAF Header
    ${magic}=               Read Memory Word  0x82000000
    Should Be Equal As Numbers  ${magic}  0x53414642

SAF Header Version Check
    [Documentation]         Header version field is 1 (Simics SAF test 2)
    [Tags]                  simics  saf  header
    Create AST2600 Machine
    Write SAF Header
    ${ver}=                 Read Memory Word  0x82000004
    Should Be Equal As Numbers  ${ver}  0x1

SAF Header Image Size
    [Documentation]         Image size matches written value (Simics SAF test 3)
    [Tags]                  simics  saf  header
    Create AST2600 Machine
    Write SAF Header  0x400000
    ${size}=                Read Memory Word  0x82000008
    Should Be Equal As Numbers  ${size}  0x400000

SAF Header Entry Point
    [Documentation]         Entry point matches written value (Simics SAF test 4)
    [Tags]                  simics  saf  header
    Create AST2600 Machine
    Write SAF Header  0x200000  0x80200000
    ${entry}=               Read Memory Word  0x8200000C
    Should Be Equal As Numbers  ${entry}  0x80200000

# ===== SAF Partition Routing =====

SAF BIOS Region Routing
    [Documentation]         Host addr 0x0 routes to FMC flash (Simics SAF test 5)
    [Tags]                  simics  saf  partition
    Create AST2600 Machine
    Write Memory Word       0x20000000  0xBIOSDATA
    Execute Command         espi HandleSafRead 0x0 4
    ${sts}=                 Read ESPI Register  0x008
    ${flash_rx}=            Evaluate  (int(${sts}) >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1

SAF OS Region Routing
    [Documentation]         Host addr 0x01000000 routes to DRAM (Simics SAF test 6)
    [Tags]                  simics  saf  partition
    Create AST2600 Machine
    Write Memory Word       0x82000000  0x4F534441
    Execute Command         espi HandleSafRead 0x01000000 4
    ${sts}=                 Read ESPI Register  0x008
    ${flash_rx}=            Evaluate  (int(${sts}) >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1

SAF BIOS Region At 8MB Offset
    [Documentation]         Read from middle of BIOS region (Simics SAF test 7)
    [Tags]                  simics  saf  partition
    Create AST2600 Machine
    Write Memory Word       0x20800000  0x4D494442
    Execute Command         espi HandleSafRead 0x00800000 4
    ${sts}=                 Read ESPI Register  0x008
    ${flash_rx}=            Evaluate  (int(${sts}) >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1

SAF OS Region Deep Offset
    [Documentation]         Read from deep within OS region (Simics SAF test 8)
    [Tags]                  simics  saf  partition
    Create AST2600 Machine
    Write Memory Word       0x82100000  0xDEEPDATA
    Execute Command         espi HandleSafRead 0x01100000 4
    ${sts}=                 Read ESPI Register  0x008
    ${flash_rx}=            Evaluate  (int(${sts}) >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1

SAF Hole Region
    [Documentation]         Read from hole region (Simics SAF test 9)
    [Tags]                  simics  saf  partition  hole
    Create AST2600 Machine
    Execute Command         espi HandleSafRead 0x30000000 4

# ===== SAF Multi-Read Sequences =====

SAF Sequential BIOS Reads
    [Documentation]         4 sequential reads from BIOS region (Simics SAF test 10)
    [Tags]                  simics  saf  sequential
    Create AST2600 Machine
    Write Memory Word       0x20000000  0x11111111
    Write Memory Word       0x20000040  0x22222222
    Write Memory Word       0x20000080  0x33333333
    Write Memory Word       0x200000C0  0x44444444
    Execute Command         espi HandleSafRead 0x00 64
    Execute Command         espi HandleSafRead 0x40 64
    Execute Command         espi HandleSafRead 0x80 64
    Execute Command         espi HandleSafRead 0xC0 64

SAF Sequential OS Reads
    [Documentation]         4 sequential reads from OS region (Simics SAF test 11)
    [Tags]                  simics  saf  sequential
    Create AST2600 Machine
    Write Memory Word       0x82000000  0xAA000001
    Write Memory Word       0x82000040  0xAA000002
    Write Memory Word       0x82000080  0xAA000003
    Write Memory Word       0x820000C0  0xAA000004
    Execute Command         espi HandleSafRead 0x01000000 64
    Execute Command         espi HandleSafRead 0x01000040 64
    Execute Command         espi HandleSafRead 0x01000080 64
    Execute Command         espi HandleSafRead 0x010000C0 64

SAF Mixed Region Reads
    [Documentation]         Alternating BIOS and OS region reads (Simics SAF test 12)
    [Tags]                  simics  saf  mixed
    Create AST2600 Machine
    Write Memory Word       0x20000000  0xBIOSBIOS
    Write Memory Word       0x82000000  0x4F534441
    Execute Command         espi HandleSafRead 0x0 4
    Execute Command         espi HandleSafRead 0x01000000 4
    Execute Command         espi HandleSafRead 0x4 4
    Execute Command         espi HandleSafRead 0x01000004 4

# ===== SAF Boot Header Via eSPI Method =====

SAF WriteSafBootHeader
    [Documentation]         WriteSafBootHeader creates valid header (Simics SAF test 13)
    [Tags]                  simics  saf  header  method
    Create AST2600 Machine
    Execute Command         espi WriteSafBootHeader 16 0x80100000 0x0 "new System.Byte[] {0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88}"
    ${magic}=               Read Memory Word  0x82000000
    Should Be Equal As Numbers  ${magic}  0x53414642

SAF ValidateSafBootHeader
    [Documentation]         ValidateSafBootHeader checks magic and version (Simics SAF test 14)
    [Tags]                  simics  saf  header  validation
    Create AST2600 Machine
    Write SAF Header
    ${result}=  Execute Command    espi ValidateSafBootHeader
    Should Contain          ${result}  True

SAF ValidateSafBootHeader Bad Magic
    [Documentation]         Validation fails with wrong magic (Simics SAF test 15)
    [Tags]                  simics  saf  header  validation  negative
    Create AST2600 Machine
    Write Memory Word       0x82000000  0xDEADDEAD
    Write Memory Word       0x82000004  0x00000001
    ${result}=  Execute Command    espi ValidateSafBootHeader
    Should Contain          ${result}  False

# ===== SAF Error Recovery =====

SAF Read After Status Clear
    [Documentation]         SAF read after clearing INT_STS (Simics SAF test 16)
    [Tags]                  simics  saf  recovery
    Create AST2600 Machine
    Write Memory Word       0x20000000  0x11111111
    Execute Command         espi HandleSafRead 0x0 4
    # Clear flash RX status
    Execute Command         espi WriteDoubleWord 0x008 0x40
    # Read again
    Execute Command         espi HandleSafRead 0x0 4
    ${sts}=                 Read ESPI Register  0x008
    ${flash_rx}=            Evaluate  (int(${sts}) >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1

SAF Read After Reset
    [Documentation]         SAF read works after cold reset (Simics SAF test 17)
    [Tags]                  simics  saf  recovery  reset
    Create AST2600 Machine
    Write Memory Word       0x20000000  0xBEEFBEEF
    Execute Command         espi HandleSafRead 0x0 4
    Execute Command         espi ColdReset
    # Re-read after reset
    Execute Command         espi HandleSafRead 0x0 4
    ${sts}=                 Read ESPI Register  0x008
    ${flash_rx}=            Evaluate  (int(${sts}) >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1

SAF Rapid Fire Reads
    [Documentation]         10 rapid sequential reads without clearing status (Simics SAF test 18)
    [Tags]                  simics  saf  stress
    Create AST2600 Machine
    Write Memory Word       0x20000000  0xRAPIDDAT
    FOR  ${i}  IN RANGE  10
        ${offset}=          Evaluate  ${i} * 4
        Execute Command     espi HandleSafRead ${offset} 4
    END
    ${sts}=                 Read ESPI Register  0x008
    ${flash_rx}=            Evaluate  (int(${sts}) >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1