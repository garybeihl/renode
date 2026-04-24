*** Variables ***
${BW_MAGIC}         0x45535049
${BW_STATE_EMPTY}   0x0
${BW_STATE_FILLING} 0x1
${BW_STATE_READY}   0x2
${BW_STATE_CONSUMED}  0x3

*** Keywords ***
Create Boot Window Machine
    [Documentation]         Create machine with boot window at 0x05000000
    Execute Command         mach create "ast2600"
    Execute Command         machine LoadPlatformDescription @platforms/boards/ast2600/ast2600-evb.repl
    # Add boot window dynamically
    Execute Command         machine LoadPlatformDescriptionFromString "bootwindow: Miscellaneous.Aspeed_eSPI_BootWindow @ sysbus 0x05000000"

Read BW Register
    [Arguments]             ${offset}
    ${val}=  Execute Command    bootwindow ReadDoubleWord ${offset}
    RETURN                  ${val.strip()}

Write BW Register
    [Arguments]             ${offset}  ${value}
    Execute Command         bootwindow WriteDoubleWord ${offset} ${value}

*** Test Cases ***
Boot Window Should Have Magic
    [Documentation]         Verify magic value at offset 0x00
    [Tags]                  aspeed  bootwindow
    Create Boot Window Machine
    ${val}=                 Read BW Register  0x0
    Should Be Equal As Numbers  ${val}  ${BW_MAGIC}

Boot Window Should Start Empty
    [Documentation]         State should be EMPTY after reset
    [Tags]                  aspeed  bootwindow
    Create Boot Window Machine
    ${val}=                 Read BW Register  0x4
    Should Be Equal As Numbers  ${val}  ${BW_STATE_EMPTY}

Full State Machine Cycle
    [Documentation]         EMPTY -> FILLING -> READY -> CONSUMED
    [Tags]                  aspeed  bootwindow  statemachine
    Create Boot Window Machine

    # Begin fill (totalSize=256)
    Execute Command         bootwindow BeginFill 256

    # Verify FILLING state
    ${state}=               Read BW Register  0x4
    Should Be Equal As Numbers  ${state}  ${BW_STATE_FILLING}

    # Verify total size
    ${total}=               Read BW Register  0x10
    Should Be Equal As Numbers  ${total}  256

    # Mark ready
    Execute Command         bootwindow MarkReady

    # Verify READY state
    ${state2}=              Read BW Register  0x4
    Should Be Equal As Numbers  ${state2}  ${BW_STATE_READY}

    # Verify CRC is non-zero
    ${crc}=                 Read BW Register  0x14
    Should Not Be Equal As Numbers  ${crc}  0x0

    # Host writes CONSUMED
    Write BW Register       0x4  ${BW_STATE_CONSUMED}
    ${state3}=              Read BW Register  0x4
    Should Be Equal As Numbers  ${state3}  ${BW_STATE_CONSUMED}

Invalid Transition Should Be Rejected
    [Documentation]         Cannot go from EMPTY to READY directly
    [Tags]                  aspeed  bootwindow  statemachine
    Create Boot Window Machine

    # Try to write READY while in EMPTY state
    Write BW Register       0x4  ${BW_STATE_READY}

    # State should still be EMPTY
    ${state}=               Read BW Register  0x4
    Should Be Equal As Numbers  ${state}  ${BW_STATE_EMPTY}

Reset To Empty
    [Documentation]         Writing EMPTY resets the boot window
    [Tags]                  aspeed  bootwindow  statemachine
    Create Boot Window Machine

    # Go through FILLING
    Execute Command         bootwindow BeginFill 128
    ${state}=               Read BW Register  0x4
    Should Be Equal As Numbers  ${state}  ${BW_STATE_FILLING}

    # Reset to EMPTY
    Write BW Register       0x4  ${BW_STATE_EMPTY}
    ${state2}=              Read BW Register  0x4
    Should Be Equal As Numbers  ${state2}  ${BW_STATE_EMPTY}

    # Magic should still be present
    ${magic}=               Read BW Register  0x0
    Should Be Equal As Numbers  ${magic}  ${BW_MAGIC}
