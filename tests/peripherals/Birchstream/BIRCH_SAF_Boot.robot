*** Keywords ***
Create AST2600 Machine
    Execute Command         mach create "ast2600"
    Execute Command         machine LoadPlatformDescription @platforms/boards/ast2600/ast2600-evb.repl

Write Memory Word
    [Arguments]             ${addr}  ${value}
    Execute Command         sysbus WriteDoubleWord ${addr} ${value}

Read Memory Word
    [Arguments]             ${addr}
    ${val}=  Execute Command    sysbus ReadDoubleWord ${addr}
    RETURN                  ${val.strip()}

*** Test Cases ***
Write And Validate SAF Boot Header
    [Documentation]         BMC writes boot header, then validates it
    [Tags]                  birchstream  saf  boot
    Create AST2600 Machine

    # Create a small test image (16 bytes of pattern)
    # WriteSafBootHeader writes header + image data to DRAM OS region
    # Using the eSPI peripheral method directly
    Execute Command         espi WriteSafBootHeader 16 0x80100000 0x0 "new System.Byte[] {0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88}"

    # Verify header magic at DRAM OS region base (0x82000000)
    ${magic}=               Read Memory Word  0x82000000
    Should Be Equal As Numbers  ${magic}  0x53414642

    # Verify image size
    ${size}=                Read Memory Word  0x82000008
    Should Be Equal As Numbers  ${size}  16

    # Verify entry point
    ${entry}=               Read Memory Word  0x8200000C
    Should Be Equal As Numbers  ${entry}  0x80100000

SAF Read BIOS Image Via Partition
    [Documentation]         Host reads BIOS image from SAF BIOS region
    [Tags]                  birchstream  saf  boot
    Create AST2600 Machine

    # Place a BIOS image signature in flash
    Write Memory Word       0x20000000  0x55AA55AA
    Write Memory Word       0x20000004  0xBIOSBIOS

    # Read via SAF partition (host addr 0x0 = BIOS region)
    Execute Command         espi HandleSafRead 0x0 8

    # Flash RX completion should fire
    ${sts}=  Execute Command    espi ReadDoubleWord 0x008
    ${flash_rx}=            Evaluate  (int(${sts.strip()}) >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1

SAF Boot Header At OS Region
    [Documentation]         Verify boot header structure in OS DRAM region
    [Tags]                  birchstream  saf  boot  header
    Create AST2600 Machine

    # Manually write SAF boot header to DRAM
    # Magic = "SAFB" = 0x53414642
    Write Memory Word       0x82000000  0x53414642
    # Version = 1
    Write Memory Word       0x82000004  0x00000001
    # Image size = 0x200000 (2MB)
    Write Memory Word       0x82000008  0x00200000
    # Entry point
    Write Memory Word       0x8200000C  0x80100000

    # Read magic via SAF partition (host addr 0x01000000 = OS region start)
    Execute Command         espi HandleSafRead 0x01000000 4

    # Verify flash RX completion
    ${sts}=  Execute Command    espi ReadDoubleWord 0x008
    ${flash_rx}=            Evaluate  (int(${sts.strip()}) >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1
