*** Keywords ***
Create AST2600 Machine
    Execute Command         mach create "ast2600"
    Execute Command         machine LoadPlatformDescription @platforms/boards/ast2600/ast2600-evb.repl

Read ESPI Register
    [Arguments]             ${offset}
    ${val}=  Execute Command    espi ReadDoubleWord ${offset}
    RETURN                  ${val.strip()}

*** Test Cases ***
PLTRST Deasserted After Reset
    [Documentation]         After machine reset, PLTRST# should be deasserted (host running)
    [Tags]                  birchstream  reset  pltrst
    Create AST2600 Machine
    # SYSEVT register at 0x098, PLTRST# is bit 5
    ${sysevt}=              Read ESPI Register  0x098
    ${pltrst}=              Evaluate  (${sysevt} >> 5) & 1
    # Deasserted = bit set (active low signal)
    Should Be Equal As Numbers  ${pltrst}  1

Assert Platform Reset
    [Documentation]         AssertPlatformReset clears PLTRST# bit
    [Tags]                  birchstream  reset  pltrst
    Create AST2600 Machine
    # Verify PLTRST# starts deasserted
    ${sysevt}=              Read ESPI Register  0x098
    ${pltrst}=              Evaluate  (${sysevt} >> 5) & 1
    Should Be Equal As Numbers  ${pltrst}  1
    # Assert PLTRST# (host reset)
    Execute Command         espi AssertPlatformReset
    ${sysevt2}=             Read ESPI Register  0x098
    ${pltrst2}=             Evaluate  (${sysevt2} >> 5) & 1
    Should Be Equal As Numbers  ${pltrst2}  0

Deassert Platform Reset
    [Documentation]         DeassertPlatformReset restores PLTRST# bit
    [Tags]                  birchstream  reset  pltrst
    Create AST2600 Machine
    Execute Command         espi AssertPlatformReset
    Execute Command         espi DeassertPlatformReset
    ${sysevt}=              Read ESPI Register  0x098
    ${pltrst}=              Evaluate  (${sysevt} >> 5) & 1
    Should Be Equal As Numbers  ${pltrst}  1

Cold Reset Sequence
    [Documentation]         ColdReset asserts then deasserts PLTRST#
    [Tags]                  birchstream  reset  cold
    Create AST2600 Machine
    # Enable SYSEVT interrupt to detect transition
    Execute Command         espi WriteDoubleWord 0x094 0x20
    Execute Command         espi WriteDoubleWord 0x00C 0x100
    # Execute cold reset
    Execute Command         espi ColdReset
    # After cold reset, PLTRST# should be deasserted (host restarted)
    ${sysevt}=              Read ESPI Register  0x098
    ${pltrst}=              Evaluate  (${sysevt} >> 5) & 1
    Should Be Equal As Numbers  ${pltrst}  1
    # SYSEVT INT_STS should have fired (bit 8 in INT_STS)
    ${sts}=                 Read ESPI Register  0x008
    ${vw_sts}=              Evaluate  (${sts} >> 8) & 1
    Should Be Equal As Numbers  ${vw_sts}  1

Warm Reset Preserves PLTRST State
    [Documentation]         WarmReset sequence ends with PLTRST# deasserted
    [Tags]                  birchstream  reset  warm
    Create AST2600 Machine
    Execute Command         espi WarmReset
    ${sysevt}=              Read ESPI Register  0x098
    ${pltrst}=              Evaluate  (${sysevt} >> 5) & 1
    Should Be Equal As Numbers  ${pltrst}  1

Host Sleep State
    [Documentation]         SetHostSleepState sets S3/S4/S5 bits in SYSEVT
    [Tags]                  birchstream  reset  sleep
    Create AST2600 Machine
    # Set S3 sleep (bit 0)
    Execute Command         espi SetHostSleepState 1
    ${sysevt}=              Read ESPI Register  0x098
    ${s3}=                  Evaluate  ${sysevt} & 1
    Should Be Equal As Numbers  ${s3}  1
    # Set S5 sleep (bit 2)
    Execute Command         espi SetHostSleepState 4
    ${sysevt2}=             Read ESPI Register  0x098
    ${s5}=                  Evaluate  (${sysevt2} >> 2) & 1
    Should Be Equal As Numbers  ${s5}  1
    # S3 should be cleared now
    ${s3_2}=                Evaluate  ${sysevt2} & 1
    Should Be Equal As Numbers  ${s3_2}  0
