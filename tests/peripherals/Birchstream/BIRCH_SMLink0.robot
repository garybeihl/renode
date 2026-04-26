*** Settings ***
Documentation       Birchstream I2C SMLink0 host management bridge tests.
...                 Tests ME firmware version, command/response,
...                 temperature sensing, and error handling.

*** Keywords ***
Create AST2600 Machine
    Execute Command         mach create "ast2600"
    Execute Command         machine LoadPlatformDescription @platforms/boards/ast2600/ast2600-evb.repl

Read SMLink Register
    [Arguments]             ${offset}
    ${val}=  Execute Command    smlink0 ReadDoubleWord ${offset}
    RETURN                  ${val.strip()}

Write SMLink Register
    [Arguments]             ${offset}  ${value}
    Execute Command         smlink0 WriteDoubleWord ${offset} ${value}

*** Test Cases ***
ME Version Default
    [Documentation]         Default ME firmware version is 11.5.1.0
    [Tags]                  birchstream  smlink  me  version
    Create AST2600 Machine
    ${ver}=                 Read SMLink Register  0x14
    Should Be Equal As Numbers  ${ver}  0x0B050100

Temperature Default
    [Documentation]         Default temperature is 35.0C (350)
    [Tags]                  birchstream  smlink  temperature
    Create AST2600 Machine
    ${temp}=                Read SMLink Register  0x1C
    Should Be Equal As Numbers  ${temp}  350

Get ME Version Command
    [Documentation]         Execute Get ME Version command
    [Tags]                  birchstream  smlink  command
    Create AST2600 Machine
    Write SMLink Register   0x08  0x01
    Write SMLink Register   0x00  0x01
    ${status}=              Read SMLink Register  0x04
    ${complete}=            Evaluate  ${status} & 1
    Should Be Equal As Numbers  ${complete}  1
    ${resp}=                Read SMLink Register  0x10
    Should Be Equal As Numbers  ${resp}  0x0B050100

Heartbeat Command
    [Documentation]         Heartbeat returns alive (1)
    [Tags]                  birchstream  smlink  command  heartbeat
    Create AST2600 Machine
    ${resp}=  Execute Command    smlink0 SendCommand 0x04 0x0
    Should Be Equal As Numbers  ${resp.strip()}  1

Unknown Command Returns Error
    [Documentation]         Unknown command sets error status
    [Tags]                  birchstream  smlink  command  error
    Create AST2600 Machine
    Write SMLink Register   0x08  0xFF
    Write SMLink Register   0x00  0x01
    ${status}=              Read SMLink Register  0x04
    ${error}=               Evaluate  ${status} & 2
    Should Not Be Equal As Numbers  ${error}  0
    ${resp}=                Read SMLink Register  0x10
    Should Be Equal As Numbers  ${resp}  0xFFFFFFFF

Custom Command Response
    [Documentation]         Set custom response for a command
    [Tags]                  birchstream  smlink  command  custom
    Create AST2600 Machine
    Execute Command         smlink0 SetCommandResponse 0x10 0xDEADBEEF
    ${resp}=  Execute Command    smlink0 SendCommand 0x10 0x0
    Should Be Equal As Numbers  ${resp.strip()}  0xDEADBEEF

Set Temperature
    [Documentation]         Configure temperature sensor value
    [Tags]                  birchstream  smlink  temperature  config
    Create AST2600 Machine
    Execute Command         smlink0 SetTemperature 725
    ${temp}=                Read SMLink Register  0x1C
    Should Be Equal As Numbers  ${temp}  725

Set ME Version
    [Documentation]         Configure ME firmware version
    [Tags]                  birchstream  smlink  me  config
    Create AST2600 Machine
    Execute Command         smlink0 SetMeVersion 0x0C010200
    ${ver}=                 Read SMLink Register  0x14
    Should Be Equal As Numbers  ${ver}  0x0C010200

Status W1C
    [Documentation]         Writing 1 to status bits clears them
    [Tags]                  birchstream  smlink  status  w1c
    Create AST2600 Machine
    Write SMLink Register   0x08  0x01
    Write SMLink Register   0x00  0x01
    ${before}=              Read SMLink Register  0x04
    Should Not Be Equal As Numbers  ${before}  0
    Write SMLink Register   0x04  ${before}
    ${after}=               Read SMLink Register  0x04
    Should Be Equal As Numbers  ${after}  0

Host State Update
    [Documentation]         Update host power state via register
    [Tags]                  birchstream  smlink  hoststate
    Create AST2600 Machine
    Write SMLink Register   0x18  0x05
    ${state}=               Read SMLink Register  0x18
    Should Be Equal As Numbers  ${state}  5