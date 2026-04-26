*** Settings ***
Documentation       Birchstream GPIO power signal tests.
...                 Tests CPUPWRGD, PSPWROK (BMC outputs) and
...                 CATERR, ERR0-2 (host error inputs).

*** Keywords ***
Create AST2600 Machine
    Execute Command         mach create "ast2600"
    Execute Command         machine LoadPlatformDescription @platforms/boards/ast2600/ast2600-evb.repl

*** Test Cases ***
CPUPWRGD Assert And Deassert
    [Documentation]         BMC asserts and deasserts CPU power good
    [Tags]                  birchstream  gpio  power  cpupwrgd
    Create AST2600 Machine
    # Start from G3 so power signals are deasserted
    Execute Command         espi MechanicalOff
    ${state}=  Execute Command    espi GetPowerSignalState
    ${pwrgd}=               Evaluate  int(${state.strip()}) & 1
    Should Be Equal As Numbers  ${pwrgd}  0
    # Assert
    Execute Command         espi AssertCpuPowerGood
    ${state2}=  Execute Command    espi GetPowerSignalState
    ${pwrgd2}=              Evaluate  int(${state2.strip()}) & 1
    Should Be Equal As Numbers  ${pwrgd2}  1
    # Deassert
    Execute Command         espi DeassertCpuPowerGood
    ${state3}=  Execute Command    espi GetPowerSignalState
    ${pwrgd3}=              Evaluate  int(${state3.strip()}) & 1
    Should Be Equal As Numbers  ${pwrgd3}  0

PSPWROK Assert And Deassert
    [Documentation]         BMC asserts and deasserts power supply OK
    [Tags]                  birchstream  gpio  power  pspwrok
    Create AST2600 Machine
    Execute Command         espi AssertPsPowerOk
    ${state}=  Execute Command    espi GetPowerSignalState
    ${psok}=                Evaluate  (int(${state.strip()}) >> 1) & 1
    Should Be Equal As Numbers  ${psok}  1
    Execute Command         espi DeassertPsPowerOk
    ${state2}=  Execute Command    espi GetPowerSignalState
    ${psok2}=               Evaluate  (int(${state2.strip()}) >> 1) & 1
    Should Be Equal As Numbers  ${psok2}  0

CATERR Inject And Clear
    [Documentation]         Host injects catastrophic error, BMC reads it
    [Tags]                  birchstream  gpio  error  caterr
    Create AST2600 Machine
    Execute Command         espi InjectCatErr
    ${state}=  Execute Command    espi GetPowerSignalState
    ${cat}=                 Evaluate  (int(${state.strip()}) >> 2) & 1
    Should Be Equal As Numbers  ${cat}  1
    Execute Command         espi ClearCatErr
    ${state2}=  Execute Command    espi GetPowerSignalState
    ${cat2}=                Evaluate  (int(${state2.strip()}) >> 2) & 1
    Should Be Equal As Numbers  ${cat2}  0

Host Error Bits
    [Documentation]         Inject ERR0-ERR2 individually and combined
    [Tags]                  birchstream  gpio  error
    Create AST2600 Machine
    # ERR0 only
    Execute Command         espi InjectHostError 1
    ${state}=  Execute Command    espi GetPowerSignalState
    ${err0}=                Evaluate  (int(${state.strip()}) >> 3) & 1
    Should Be Equal As Numbers  ${err0}  1
    # ERR0 + ERR2
    Execute Command         espi InjectHostError 5
    ${state2}=  Execute Command    espi GetPowerSignalState
    ${err}=                 Evaluate  (int(${state2.strip()}) >> 3) & 7
    Should Be Equal As Numbers  ${err}  5
    # Clear all
    Execute Command         espi ClearHostError
    ${state3}=  Execute Command    espi GetPowerSignalState
    ${err3}=                Evaluate  (int(${state3.strip()}) >> 3) & 7
    Should Be Equal As Numbers  ${err3}  0

Full Power Signal State
    [Documentation]         All signals active simultaneously
    [Tags]                  birchstream  gpio  power  combined
    Create AST2600 Machine
    Execute Command         espi AssertCpuPowerGood
    Execute Command         espi AssertPsPowerOk
    Execute Command         espi InjectCatErr
    Execute Command         espi InjectHostError 7
    ${state}=  Execute Command    espi GetPowerSignalState
    # All bits: CPUPWRGD(1) + PSPWROK(2) + CATERR(4) + ERR0-2(0x38) = 0x3F
    Should Be Equal As Numbers  ${state.strip()}  63

Power Signals Survive Warm Reset
    [Documentation]         Power signals persist across warm reset
    [Tags]                  birchstream  gpio  power  reset
    Create AST2600 Machine
    Execute Command         espi AssertCpuPowerGood
    Execute Command         espi AssertPsPowerOk
    Execute Command         espi WarmReset
    ${state}=  Execute Command    espi GetPowerSignalState
    ${pwrgd}=               Evaluate  int(${state.strip()}) & 1
    Should Be Equal As Numbers  ${pwrgd}  1
    ${psok}=                Evaluate  (int(${state.strip()}) >> 1) & 1
    Should Be Equal As Numbers  ${psok}  1

CATERR During Active Boot
    [Documentation]         CATERR injection while power signals are active
    [Tags]                  birchstream  gpio  error  boot
    Create AST2600 Machine
    Execute Command         espi AssertCpuPowerGood
    Execute Command         espi AssertPsPowerOk
    Execute Command         espi InjectCatErr
    ${state}=  Execute Command    espi GetPowerSignalState
    # CPUPWRGD + PSPWROK + CATERR = 7
    ${combined}=            Evaluate  int(${state.strip()}) & 7
    Should Be Equal As Numbers  ${combined}  7