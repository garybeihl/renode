*** Keywords ***
Create AST2600 Machine
    Execute Command         mach create "ast2600"
    Execute Command         machine LoadPlatformDescription @platforms/boards/ast2600/ast2600-evb.repl

Read LPC Register
    [Arguments]             ${offset}
    ${val}=  Execute Command    lpc ReadDoubleWord ${offset}
    RETURN                  ${val.strip()}

*** Test Cases ***
Setup Birchstream Defaults
    [Documentation]         SetupBirchstreamDefaults configures IPMI overrides
    [Tags]                  birchstream  kcs  boot
    Create AST2600 Machine
    Execute Command         lpc SetupBirchstreamDefaults

Get Device ID Via KCS
    [Documentation]         Host sends Get Device ID, gets auto-response
    [Tags]                  birchstream  kcs  ipmi
    Create AST2600 Machine
    Execute Command         lpc SetupBirchstreamDefaults
    # Enable KCS channel 1
    Execute Command         lpc WriteDoubleWord 0x00 0x20
    Execute Command         lpc WriteDoubleWord 0x08 0x02
    # Send Get Device ID (netFn=0x06, cmd=0x01)
    Execute Command         lpc SendHostIpmiCommand 0x06 0x01 null 0
    # ODR should have response data (OBF set in STR1)
    ${str}=                 Read LPC Register  0x3C
    ${obf}=                 Evaluate  ${str} & 1
    Should Be Equal As Numbers  ${obf}  1

Get Boot Options Via KCS
    [Documentation]         Host sends Get Boot Options, gets eSPI SAF response
    [Tags]                  birchstream  kcs  ipmi  boot
    Create AST2600 Machine
    Execute Command         lpc SetupBirchstreamDefaults
    Execute Command         lpc WriteDoubleWord 0x00 0x20
    Execute Command         lpc WriteDoubleWord 0x08 0x02
    # Send Get Boot Options (netFn=0x08, cmd=0x09)
    Execute Command         lpc SendHostIpmiCommand 0x08 0x09 null 0
    # ODR should have response
    ${str}=                 Read LPC Register  0x3C
    ${obf}=                 Evaluate  ${str} & 1
    Should Be Equal As Numbers  ${obf}  1

XDMA Metadata Properties
    [Documentation]         XDMA base and size properties should be configurable
    [Tags]                  birchstream  kcs  xdma
    Create AST2600 Machine
    # Verify defaults
    ${base}=  Execute Command    lpc XdmaBaseAddress
    ${size}=  Execute Command    lpc XdmaTransferSize
    Should Contain          ${base}    0x80001000
    Should Contain          ${size}    0x200000

Custom IPMI Override
    [Documentation]         Set custom override and verify auto-response
    [Tags]                  birchstream  kcs  ipmi
    Create AST2600 Machine
    Execute Command         lpc WriteDoubleWord 0x00 0x20
    Execute Command         lpc WriteDoubleWord 0x08 0x02
    # Set custom override for netFn=0x2C cmd=0x42
    Execute Command         lpc SetIpmiOverride 0x2C 0x42 "System.Array.Empty<System.Byte>()"
    # Send the command
    Execute Command         lpc SendHostIpmiCommand 0x2C 0x42 null 0
    # Should get auto-response (OBF set)
    ${str}=                 Read LPC Register  0x3C
    ${obf}=                 Evaluate  ${str} & 1
    Should Be Equal As Numbers  ${obf}  1

No Override Falls Through
    [Documentation]         Command without override leaves data for BMC software
    [Tags]                  birchstream  kcs  ipmi
    Create AST2600 Machine
    Execute Command         lpc WriteDoubleWord 0x00 0x20
    Execute Command         lpc WriteDoubleWord 0x08 0x02
    # Send command with no override configured (netFn=0x30, cmd=0x99)
    Execute Command         lpc SendHostIpmiCommand 0x30 0x99 null 0
    # IBF should be set (data waiting for BMC), but no auto-response
    ${str}=                 Read LPC Register  0x3C
    ${ibf}=                 Evaluate  (${str} >> 1) & 1
    Should Be Equal As Numbers  ${ibf}  1
