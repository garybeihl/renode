*** Settings ***
Documentation       Birchstream ACPI power state machine tests.
...                 Tests S0/S3/S4/S5/G3 transitions, WDT resets,
...                 and power signal coordination.

*** Keywords ***
Create AST2600 Machine
    Execute Command         mach create "ast2600"
    Execute Command         machine LoadPlatformDescription @platforms/boards/ast2600/ast2600-evb.repl

Read ESPI Register
    [Arguments]             ${offset}
    ${val}=  Execute Command    espi ReadDoubleWord ${offset}
    RETURN                  ${val.strip()}

Get ACPI State
    ${state}=  Execute Command    espi GetAcpiState
    RETURN              ${state.strip()}

Get Power Signals
    ${state}=  Execute Command    espi GetPowerSignalState
    RETURN              ${state.strip()}

*** Test Cases ***
# ===== Basic State Transitions =====

Default State Is S0
    [Documentation]         Machine starts in S0 (working)
    [Tags]                  birchstream  acpi  state
    Create AST2600 Machine
    ${state}=               Get ACPI State
    Should Be Equal As Numbers  ${state}  0

Power On From G3
    [Documentation]         G3 -> S5 -> S0 power on sequence
    [Tags]                  birchstream  acpi  poweron
    Create AST2600 Machine
    # Go to G3 first
    Execute Command         espi MechanicalOff
    ${state}=               Get ACPI State
    Should Be Equal As Numbers  ${state}  6
    # Power on
    Execute Command         espi PowerOn
    ${state2}=              Get ACPI State
    Should Be Equal As Numbers  ${state2}  0
    # Power signals should be asserted
    ${psig}=                Get Power Signals
    ${pwrgd}=               Evaluate  int(${psig}) & 1
    ${psok}=                Evaluate  (int(${psig}) >> 1) & 1
    Should Be Equal As Numbers  ${pwrgd}  1
    Should Be Equal As Numbers  ${psok}  1

Graceful Shutdown S0 To S5
    [Documentation]         S0 -> S5 graceful shutdown
    [Tags]                  birchstream  acpi  shutdown
    Create AST2600 Machine
    Execute Command         espi GracefulShutdown
    ${state}=               Get ACPI State
    Should Be Equal As Numbers  ${state}  5
    # S5 sleep bit should be set
    ${sysevt}=              Read ESPI Register  0x098
    ${s5}=                  Evaluate  (${sysevt} >> 2) & 1
    Should Be Equal As Numbers  ${s5}  1
    # CPUPWRGD should be deasserted
    ${psig}=                Get Power Signals
    ${pwrgd}=               Evaluate  int(${psig}) & 1
    Should Be Equal As Numbers  ${pwrgd}  0

# ===== Suspend/Resume =====

Suspend To RAM S0 To S3
    [Documentation]         S0 -> S3 suspend to RAM
    [Tags]                  birchstream  acpi  suspend  s3
    Create AST2600 Machine
    Execute Command         espi SuspendToRam
    ${state}=               Get ACPI State
    Should Be Equal As Numbers  ${state}  3
    # S3 sleep bit set
    ${sysevt}=              Read ESPI Register  0x098
    ${s3}=                  Evaluate  ${sysevt} & 1
    Should Be Equal As Numbers  ${s3}  1

Resume From S3
    [Documentation]         S3 -> S0 resume from suspend
    [Tags]                  birchstream  acpi  resume  s3
    Create AST2600 Machine
    Execute Command         espi SuspendToRam
    ${state}=               Get ACPI State
    Should Be Equal As Numbers  ${state}  3
    Execute Command         espi Resume
    ${state2}=              Get ACPI State
    Should Be Equal As Numbers  ${state2}  0
    # Sleep bits cleared
    ${sysevt}=              Read ESPI Register  0x098
    ${s3}=                  Evaluate  ${sysevt} & 1
    Should Be Equal As Numbers  ${s3}  0
    # PLTRST deasserted, power good
    ${pltrst}=              Evaluate  (${sysevt} >> 5) & 1
    Should Be Equal As Numbers  ${pltrst}  1

Suspend To Disk S0 To S4
    [Documentation]         S0 -> S4 suspend to disk
    [Tags]                  birchstream  acpi  suspend  s4
    Create AST2600 Machine
    ${result}=  Execute Command    espi TransitionAcpiState 4
    Should Contain          ${result}  True
    ${state}=               Get ACPI State
    Should Be Equal As Numbers  ${state}  4

Resume From S4
    [Documentation]         S4 -> S0 resume
    [Tags]                  birchstream  acpi  resume  s4
    Create AST2600 Machine
    Execute Command         espi TransitionAcpiState 4
    Execute Command         espi Resume
    ${state}=               Get ACPI State
    Should Be Equal As Numbers  ${state}  0

# ===== Invalid Transitions =====

Invalid S5 To S3
    [Documentation]         Cannot go directly from S5 to S3
    [Tags]                  birchstream  acpi  invalid
    Create AST2600 Machine
    Execute Command         espi GracefulShutdown
    ${result}=  Execute Command    espi TransitionAcpiState 3
    Should Contain          ${result}  False
    ${state}=               Get ACPI State
    Should Be Equal As Numbers  ${state}  5

Invalid S3 To S5
    [Documentation]         Cannot go directly from S3 to S5
    [Tags]                  birchstream  acpi  invalid
    Create AST2600 Machine
    Execute Command         espi SuspendToRam
    ${result}=  Execute Command    espi TransitionAcpiState 5
    Should Contain          ${result}  False

Invalid G3 To S0
    [Documentation]         Cannot skip S5 from G3 to S0
    [Tags]                  birchstream  acpi  invalid
    Create AST2600 Machine
    Execute Command         espi MechanicalOff
    ${result}=  Execute Command    espi TransitionAcpiState 0
    Should Contain          ${result}  False

# ===== Mechanical Off =====

Mechanical Off From Any State
    [Documentation]         G3 is always reachable from any state
    [Tags]                  birchstream  acpi  g3
    Create AST2600 Machine
    Execute Command         espi MechanicalOff
    ${state}=               Get ACPI State
    Should Be Equal As Numbers  ${state}  6
    # All power signals off
    ${psig}=                Get Power Signals
    Should Be Equal As Numbers  ${psig}  0

G3 Clears Errors
    [Documentation]         G3 transition clears CATERR and host errors
    [Tags]                  birchstream  acpi  g3  errors
    Create AST2600 Machine
    Execute Command         espi InjectCatErr
    Execute Command         espi InjectHostError 7
    Execute Command         espi MechanicalOff
    ${psig}=                Get Power Signals
    Should Be Equal As Numbers  ${psig}  0

# ===== WDT Resets =====

WDT1 Triggered Reset
    [Documentation]         WDT1 fires cold reset and records source
    [Tags]                  birchstream  acpi  wdt  reset
    Create AST2600 Machine
    Execute Command         espi WatchdogReset 0
    ${src}=  Execute Command    espi GetLastResetSource
    # WDT1 = 0x10
    Should Be Equal As Numbers  ${src.strip()}  16
    # PLTRST should be deasserted after reset
    ${sysevt}=              Read ESPI Register  0x098
    ${pltrst}=              Evaluate  (${sysevt} >> 5) & 1
    Should Be Equal As Numbers  ${pltrst}  1

WDT4 Triggered Reset
    [Documentation]         WDT4 fires cold reset with correct source
    [Tags]                  birchstream  acpi  wdt  reset
    Create AST2600 Machine
    Execute Command         espi WatchdogReset 3
    ${src}=  Execute Command    espi GetLastResetSource
    # WDT4 = 0x13
    Should Be Equal As Numbers  ${src.strip()}  19

# ===== Full Power Cycle =====

Full Power Cycle
    [Documentation]         G3 -> S5 -> S0 -> S3 -> S0 -> S5 -> G3
    [Tags]                  birchstream  acpi  cycle  e2e
    Create AST2600 Machine
    # Start from G3
    Execute Command         espi MechanicalOff
    ${s}=                   Get ACPI State
    Should Be Equal As Numbers  ${s}  6
    # Power on
    Execute Command         espi PowerOn
    ${s}=                   Get ACPI State
    Should Be Equal As Numbers  ${s}  0
    # Suspend
    Execute Command         espi SuspendToRam
    ${s}=                   Get ACPI State
    Should Be Equal As Numbers  ${s}  3
    # Resume
    Execute Command         espi Resume
    ${s}=                   Get ACPI State
    Should Be Equal As Numbers  ${s}  0
    # Shutdown
    Execute Command         espi GracefulShutdown
    ${s}=                   Get ACPI State
    Should Be Equal As Numbers  ${s}  5
    # Mechanical off
    Execute Command         espi MechanicalOff
    ${s}=                   Get ACPI State
    Should Be Equal As Numbers  ${s}  6