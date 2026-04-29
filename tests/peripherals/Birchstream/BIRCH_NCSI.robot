*** Settings ***
Documentation       NCSI (NC-SI) network sideband tests
...                 Validates NcsiResponder protocol handling per DSP0222.
...                 Tests use monitor extension methods to inject NCSI commands
...                 and verify state transitions and response codes.

*** Variables ***
# NCSI command types (DSP0222)
${CMD_CLEAR_INIT}       0
${CMD_SELECT_PKG}       1
${CMD_DESELECT_PKG}     2
${CMD_ENABLE_CH}        3
${CMD_DISABLE_CH}       4
${CMD_RESET_CH}         5
${CMD_GET_VERSION}      8
${CMD_GET_CAPS}         9
${CMD_GET_PARAMS}       10
${CMD_GET_LINK}         14
${CMD_GET_MAC}          23

# Channel IDs (package 0, channel N)
${CH_0}                 0
${CH_1}                 1
${CH_2}                 2
${CH_3}                 3

# Response codes
${RSP_OK}               0
${RSP_FAIL}             1
${RSP_UNSUPPORTED}      2

*** Keywords ***
Create NCSI Test Environment
    Execute Command         mach create "ast2600"
    Execute Command         machine LoadPlatformDescription @platforms/boards/ast2600/ast2600-evb.repl
    Execute Command         emulation CreateNcsiResponder "ncsi"

Inject NCSI Command
    [Arguments]             ${cmd}  ${channel}=0  ${instance}=1
    ${rsp}=                 Execute Command    emulation NcsiInject "ncsi" ${cmd} ${channel} ${instance}
    RETURN                  ${rsp}

Get Response Code
    ${rsp}=                 Execute Command    emulation NcsiGetResponseCode "ncsi"
    RETURN                  ${rsp}

Get Reason Code
    ${rsp}=                 Execute Command    emulation NcsiGetReasonCode "ncsi"
    RETURN                  ${rsp}

Is Package Selected
    ${val}=                 Execute Command    emulation NcsiIsPackageSelected "ncsi"
    RETURN                  ${val}

Is Channel Enabled
    [Arguments]             ${channel}
    ${val}=                 Execute Command    emulation NcsiIsChannelEnabled "ncsi" ${channel}
    RETURN                  ${val}

Is Init Cleared
    ${val}=                 Execute Command    emulation NcsiIsInitCleared "ncsi"
    RETURN                  ${val}

Is Link Up
    ${val}=                 Execute Command    emulation NcsiIsLinkUp "ncsi"
    RETURN                  ${val}

Get Command Count
    ${val}=                 Execute Command    emulation NcsiGetCommandCount "ncsi"
    RETURN                  ${val}

Get Instance Id
    ${val}=                 Execute Command    emulation NcsiGetLastInstanceId "ncsi"
    RETURN                  ${val}

Do Clear Initial State
    Inject NCSI Command     ${CMD_CLEAR_INIT}  ${CH_0}  1

Do Select Package
    Inject NCSI Command     ${CMD_SELECT_PKG}  ${CH_0}  2

*** Test Cases ***
NCSI Clear Initial State
    [Documentation]         Clear Initial State is required before other commands
    [Tags]                  ncsi
    Create NCSI Test Environment

    ${rsp}=                 Inject NCSI Command    ${CMD_CLEAR_INIT}  ${CH_0}  1
    Should Contain          ${rsp}  0

    ${cleared}=             Is Init Cleared
    Should Contain          ${cleared}  True

NCSI Command Before Clear Init Fails
    [Documentation]         Commands fail with reason InitRequired if init not cleared
    [Tags]                  ncsi
    Create NCSI Test Environment

    # Try Select Package without clearing init first
    ${rsp}=                 Inject NCSI Command    ${CMD_SELECT_PKG}  ${CH_0}  1
    Should Contain          ${rsp}  1

    ${reason}=              Get Reason Code
    Should Contain          ${reason}  3

NCSI Select Package
    [Documentation]         Select Package 0 succeeds after init cleared
    [Tags]                  ncsi
    Create NCSI Test Environment
    Do Clear Initial State

    ${rsp}=                 Inject NCSI Command    ${CMD_SELECT_PKG}  ${CH_0}  2
    Should Contain          ${rsp}  0

    ${sel}=                 Is Package Selected
    Should Contain          ${sel}  True

NCSI Deselect Package
    [Documentation]         Deselect Package clears selection
    [Tags]                  ncsi
    Create NCSI Test Environment
    Do Clear Initial State
    Do Select Package

    ${rsp}=                 Inject NCSI Command    ${CMD_DESELECT_PKG}  ${CH_0}  3
    Should Contain          ${rsp}  0

    ${sel}=                 Is Package Selected
    Should Contain          ${sel}  False

NCSI Enable Channel
    [Documentation]         Enable Channel 0 after package selected
    [Tags]                  ncsi
    Create NCSI Test Environment
    Do Clear Initial State
    Do Select Package

    ${rsp}=                 Inject NCSI Command    ${CMD_ENABLE_CH}  ${CH_0}  3
    Should Contain          ${rsp}  0

    ${en}=                  Is Channel Enabled    0
    Should Contain          ${en}  True

NCSI Enable Channel Without Package Fails
    [Documentation]         Enable Channel fails if package not selected
    [Tags]                  ncsi
    Create NCSI Test Environment
    Do Clear Initial State

    ${rsp}=                 Inject NCSI Command    ${CMD_ENABLE_CH}  ${CH_0}  3
    Should Contain          ${rsp}  1

    ${reason}=              Get Reason Code
    Should Contain          ${reason}  5

NCSI Disable Channel
    [Documentation]         Disable Channel clears enabled state
    [Tags]                  ncsi
    Create NCSI Test Environment
    Do Clear Initial State
    Do Select Package
    Inject NCSI Command     ${CMD_ENABLE_CH}  ${CH_0}  3

    ${rsp}=                 Inject NCSI Command    ${CMD_DISABLE_CH}  ${CH_0}  4
    Should Contain          ${rsp}  0

    ${en}=                  Is Channel Enabled    0
    Should Contain          ${en}  False

NCSI Reset Channel
    [Documentation]         Reset Channel disables the channel
    [Tags]                  ncsi
    Create NCSI Test Environment
    Do Clear Initial State
    Do Select Package
    Inject NCSI Command     ${CMD_ENABLE_CH}  ${CH_1}  3

    ${rsp}=                 Inject NCSI Command    ${CMD_RESET_CH}  ${CH_1}  4
    Should Contain          ${rsp}  0

    ${en}=                  Is Channel Enabled    1
    Should Contain          ${en}  False

NCSI Get Version ID
    [Documentation]         Get Version ID returns NCSI version and firmware info
    [Tags]                  ncsi
    Create NCSI Test Environment
    Do Clear Initial State

    ${rsp}=                 Inject NCSI Command    ${CMD_GET_VERSION}  ${CH_0}  5
    Should Contain          ${rsp}  0

NCSI Get Capabilities
    [Documentation]         Get Capabilities returns channel count and filter info
    [Tags]                  ncsi
    Create NCSI Test Environment
    Do Clear Initial State

    ${rsp}=                 Inject NCSI Command    ${CMD_GET_CAPS}  ${CH_0}  6
    Should Contain          ${rsp}  0

NCSI Get Link Status
    [Documentation]         Get Link Status returns link up by default
    [Tags]                  ncsi
    Create NCSI Test Environment
    Do Clear Initial State

    ${rsp}=                 Inject NCSI Command    ${CMD_GET_LINK}  ${CH_0}  7
    Should Contain          ${rsp}  0

    ${up}=                  Is Link Up
    Should Contain          ${up}  True

NCSI Link Down
    [Documentation]         Link status reflects SetLinkUp(false)
    [Tags]                  ncsi
    Create NCSI Test Environment
    Do Clear Initial State

    Execute Command         emulation NcsiSetLinkUp "ncsi" false
    ${up}=                  Is Link Up
    Should Contain          ${up}  False

NCSI Get MAC Address
    [Documentation]         Get MAC Address returns the responder MAC
    [Tags]                  ncsi
    Create NCSI Test Environment
    Do Clear Initial State

    ${rsp}=                 Inject NCSI Command    ${CMD_GET_MAC}  ${CH_0}  8
    Should Contain          ${rsp}  0

NCSI Unsupported Command
    [Documentation]         Unknown command type returns Unsupported response
    [Tags]                  ncsi
    Create NCSI Test Environment
    Do Clear Initial State

    ${rsp}=                 Inject NCSI Command    127  ${CH_0}  9
    Should Contain          ${rsp}  2

NCSI Instance ID Echo
    [Documentation]         Response echoes the request instance ID
    [Tags]                  ncsi
    Create NCSI Test Environment

    Inject NCSI Command     ${CMD_CLEAR_INIT}  ${CH_0}  42
    ${id}=                  Get Instance Id
    Should Contain          ${id}  0x0000002A

NCSI Command Count
    [Documentation]         Command counter increments with each command
    [Tags]                  ncsi
    Create NCSI Test Environment

    Inject NCSI Command     ${CMD_CLEAR_INIT}  ${CH_0}  1
    Inject NCSI Command     ${CMD_SELECT_PKG}  ${CH_0}  2
    Inject NCSI Command     ${CMD_GET_VERSION}  ${CH_0}  3

    ${count}=               Get Command Count
    Should Contain          ${count}  3

NCSI Multiple Channels
    [Documentation]         Enable multiple channels independently
    [Tags]                  ncsi
    Create NCSI Test Environment
    Do Clear Initial State
    Do Select Package

    Inject NCSI Command     ${CMD_ENABLE_CH}  ${CH_0}  3
    Inject NCSI Command     ${CMD_ENABLE_CH}  ${CH_1}  4
    Inject NCSI Command     ${CMD_ENABLE_CH}  ${CH_2}  5

    ${en0}=                 Is Channel Enabled    0
    Should Contain          ${en0}  True
    ${en1}=                 Is Channel Enabled    1
    Should Contain          ${en1}  True
    ${en2}=                 Is Channel Enabled    2
    Should Contain          ${en2}  True
    ${en3}=                 Is Channel Enabled    3
    Should Contain          ${en3}  False

NCSI Reset Clears State
    [Documentation]         NcsiReset clears all protocol state
    [Tags]                  ncsi
    Create NCSI Test Environment
    Do Clear Initial State
    Do Select Package
    Inject NCSI Command     ${CMD_ENABLE_CH}  ${CH_0}  3

    Execute Command         emulation NcsiReset "ncsi"

    ${cleared}=             Is Init Cleared
    Should Contain          ${cleared}  False
    ${sel}=                 Is Package Selected
    Should Contain          ${sel}  False
    ${en}=                  Is Channel Enabled    0
    Should Contain          ${en}  False
