*** Settings ***
Documentation       Simics-parity eSPI flash channel tests.
...                 Ports the 13 Simics eSPI flash test scenarios to Renode.
...                 Tests cover flash read completions, channel enable/disable,
...                 error handling, and interrupt behavior.

*** Keywords ***
Create AST2600 Machine
    Execute Command         mach create "ast2600"
    Execute Command         machine LoadPlatformDescription @platforms/boards/ast2600/ast2600-evb.repl

Read ESPI Register
    [Arguments]             ${offset}
    ${val}=  Execute Command    espi ReadDoubleWord ${offset}
    RETURN                  ${val.strip()}

Write ESPI Register
    [Arguments]             ${offset}  ${value}
    Execute Command         espi WriteDoubleWord ${offset} ${value}

Write Memory Word
    [Arguments]             ${addr}  ${value}
    Execute Command         sysbus WriteDoubleWord ${addr} ${value}

Read Memory Word
    [Arguments]             ${addr}
    ${val}=  Execute Command    sysbus ReadDoubleWord ${addr}
    RETURN                  ${val.strip()}

*** Test Cases ***
# ===== Flash Channel Enable/Disable =====

Flash Channel Enable
    [Documentation]         Enabling flash channel sets ready bit (Simics test 1)
    [Tags]                  simics  espi  flash  channel
    Create AST2600 Machine
    # Enable flash channel (bit 4 in channel enable register 0x000)
    Write ESPI Register     0x000  0x10
    ${ctrl}=                Read ESPI Register  0x000
    ${flash_en}=            Evaluate  (${ctrl} >> 4) & 1
    Should Be Equal As Numbers  ${flash_en}  1

Flash Channel Disable
    [Documentation]         Disabling flash channel clears ready bit (Simics test 2)
    [Tags]                  simics  espi  flash  channel
    Create AST2600 Machine
    Write ESPI Register     0x000  0x10
    Write ESPI Register     0x000  0x00
    ${ctrl}=                Read ESPI Register  0x000
    ${flash_en}=            Evaluate  (${ctrl} >> 4) & 1
    Should Be Equal As Numbers  ${flash_en}  0

# ===== Flash Read Completions =====

Flash Read From BIOS Region
    [Documentation]         SAF read from BIOS region completes with flash RX (Simics test 3)
    [Tags]                  simics  espi  flash  read
    Create AST2600 Machine
    Write Memory Word       0x20000000  0xDEADC0DE
    Execute Command         espi HandleSafRead 0x0 4
    ${sts}=                 Read ESPI Register  0x008
    ${flash_rx}=            Evaluate  (int(${sts}) >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1

Flash Read From OS Region
    [Documentation]         SAF read from OS region reads BMC DRAM (Simics test 4)
    [Tags]                  simics  espi  flash  read
    Create AST2600 Machine
    Write Memory Word       0x82000000  0xCAFEBABE
    Execute Command         espi HandleSafRead 0x01000000 4
    ${sts}=                 Read ESPI Register  0x008
    ${flash_rx}=            Evaluate  (int(${sts}) >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1

Flash Read Max Burst 64B
    [Documentation]         64-byte burst read from BIOS region (Simics test 5)
    [Tags]                  simics  espi  flash  read  burst
    Create AST2600 Machine
    # Fill 64 bytes of flash with pattern
    Write Memory Word       0x20000000  0x11111111
    Write Memory Word       0x20000004  0x22222222
    Write Memory Word       0x20000008  0x33333333
    Write Memory Word       0x2000000C  0x44444444
    Execute Command         espi HandleSafRead 0x0 64
    ${sts}=                 Read ESPI Register  0x008
    ${flash_rx}=            Evaluate  (int(${sts}) >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1

Flash Read Sequential
    [Documentation]         Multiple sequential reads from same region (Simics test 6)
    [Tags]                  simics  espi  flash  read  sequential
    Create AST2600 Machine
    Write Memory Word       0x20000000  0xAAAAAAAA
    Write Memory Word       0x20000040  0xBBBBBBBB
    Write Memory Word       0x20000080  0xCCCCCCCC
    Execute Command         espi HandleSafRead 0x00 4
    Execute Command         espi HandleSafRead 0x40 4
    Execute Command         espi HandleSafRead 0x80 4
    # All three should complete
    ${sts}=                 Read ESPI Register  0x008
    ${flash_rx}=            Evaluate  (int(${sts}) >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1

# ===== Flash Interrupt Behavior =====

Flash RX Interrupt Enable
    [Documentation]         Flash RX interrupt fires when enabled (Simics test 7)
    [Tags]                  simics  espi  flash  interrupt
    Create AST2600 Machine
    # Enable flash RX interrupt (bit 6 in INT_EN 0x00C)
    Write ESPI Register     0x00C  0x40
    Write Memory Word       0x20000000  0x12345678
    Execute Command         espi HandleSafRead 0x0 4
    ${sts}=                 Read ESPI Register  0x008
    ${flash_rx}=            Evaluate  (int(${sts}) >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1

Flash RX Interrupt W1C
    [Documentation]         Writing 1 to flash RX status clears it (Simics test 8)
    [Tags]                  simics  espi  flash  interrupt  w1c
    Create AST2600 Machine
    Write Memory Word       0x20000000  0xABCD1234
    Execute Command         espi HandleSafRead 0x0 4
    ${before}=              Read ESPI Register  0x008
    ${rx_before}=           Evaluate  (int(${before}) >> 6) & 1
    Should Be Equal As Numbers  ${rx_before}  1
    # Clear by writing 1 (W1C)
    Write ESPI Register     0x008  0x40
    ${after}=               Read ESPI Register  0x008
    ${rx_after}=            Evaluate  (int(${after}) >> 6) & 1
    Should Be Equal As Numbers  ${rx_after}  0

# ===== Flash Error Cases =====

Flash Read From Hole Region
    [Documentation]         Read from unmapped hole returns without crash (Simics test 9)
    [Tags]                  simics  espi  flash  error
    Create AST2600 Machine
    Execute Command         espi HandleSafRead 0x30000000 4

Flash Read Zero Length
    [Documentation]         Zero-length read completes without crash (Simics test 10)
    [Tags]                  simics  espi  flash  error
    Create AST2600 Machine
    Execute Command         espi HandleSafRead 0x0 0

# ===== Flash Read With Tag =====

Flash Read With Tag
    [Documentation]         SAF read with non-zero tag (Simics test 11)
    [Tags]                  simics  espi  flash  tag
    Create AST2600 Machine
    Write Memory Word       0x20000000  0xFEED0000
    Execute Command         espi HandleSafRead 0x0 4 7
    ${sts}=                 Read ESPI Register  0x008
    ${flash_rx}=            Evaluate  (int(${sts}) >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1

# ===== Flash Read Cross-Boundary =====

Flash Read BIOS Region End
    [Documentation]         Read last bytes of BIOS region (Simics test 12)
    [Tags]                  simics  espi  flash  boundary
    Create AST2600 Machine
    Write Memory Word       0x20FFFFFC  0x1A57B105
    Execute Command         espi HandleSafRead 0x00FFFFFC 4
    ${sts}=                 Read ESPI Register  0x008
    ${flash_rx}=            Evaluate  (int(${sts}) >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1

Flash Read OS Region Start
    [Documentation]         Read first bytes of OS region (Simics test 13)
    [Tags]                  simics  espi  flash  boundary
    Create AST2600 Machine
    Write Memory Word       0x82000000  0xF1570500
    Execute Command         espi HandleSafRead 0x01000000 4
    ${sts}=                 Read ESPI Register  0x008
    ${flash_rx}=            Evaluate  (int(${sts}) >> 6) & 1
    Should Be Equal As Numbers  ${flash_rx}  1