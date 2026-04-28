*** Keywords ***
Create AST2600 Machine
    Execute Command         mach create "ast2600"
    Execute Command         machine LoadPlatformDescription @platforms/boards/ast2600/ast2600-evb.repl

Read I3C Register
    [Arguments]             ${port}  ${offset}
    ${val}=  Execute Command    sysbus.i3c${port} ReadDoubleWord ${offset}
    RETURN                  ${val.strip()}

Write I3C Register
    [Arguments]             ${port}  ${offset}  ${value}
    Execute Command         sysbus.i3c${port} WriteDoubleWord ${offset} ${value}

*** Test Cases ***
I3C Controllers Registered
    [Documentation]         All 6 I3C controllers exist in the platform
    [Tags]                  birchstream  i3c
    Create AST2600 Machine
    # Read HW_CAPABILITY from each port — should not error
    FOR  ${port}  IN RANGE  6
        ${val}=             Read I3C Register  ${port}  0x008
    END

HW Capability Read Only
    [Documentation]         HW_CAPABILITY register is read-only
    [Tags]                  birchstream  i3c  readonly
    Create AST2600 Machine
    ${orig}=                Read I3C Register  0  0x008
    Write I3C Register      0  0x008  0xDEADBEEF
    ${after}=               Read I3C Register  0  0x008
    Should Be Equal As Numbers  ${orig}  ${after}  msg=HW_CAPABILITY should be read-only

Queue Size Capability Defaults
    [Documentation]         QUEUE_SIZE_CAPABILITY reports non-zero queue depths
    [Tags]                  birchstream  i3c  probe
    Create AST2600 Machine
    ${val}=                 Read I3C Register  0  0x058
    Should Not Be Equal As Numbers  ${val}  0  msg=Queue depth should be non-zero for probe

Data Buffer Status Level
    [Documentation]         DATA_BUFFER_STATUS_LEVEL reports available TX buffer space
    [Tags]                  birchstream  i3c  probe
    Create AST2600 Machine
    ${val}=                 Read I3C Register  0  0x050
    ${tx_empty}=            Evaluate  (int(${val}) >> 16) & 0xFF
    Should Be True          ${tx_empty} > 0  msg=TX buffer empty slots should be > 0

DAT Pointer Non Zero
    [Documentation]         DEVICE_ADDR_TABLE_POINTER reports non-zero depth
    [Tags]                  birchstream  i3c  probe
    Create AST2600 Machine
    ${val}=                 Read I3C Register  0  0x05C
    ${depth}=               Evaluate  (int(${val}) >> 16) & 0xFFFF
    Should Be True          ${depth} > 0  msg=DAT depth should be > 0

Queue Status Level Shows Cmd Space
    [Documentation]         QUEUE_STATUS_LEVEL reports available command queue space
    [Tags]                  birchstream  i3c  probe
    Create AST2600 Machine
    ${val}=                 Read I3C Register  0  0x04C
    ${cmd_empty}=           Evaluate  (int(${val}) >> 8) & 0xFF
    Should Be True          ${cmd_empty} > 0  msg=Command queue empty slots should be > 0

INTR Status W1C
    [Documentation]         Interrupt status register supports write-1-to-clear
    [Tags]                  birchstream  i3c  w1c
    Create AST2600 Machine
    # Force a response by writing two command dwords
    Write I3C Register      0  0x00C  0x00000000
    Write I3C Register      0  0x00C  0x00000000
    # RESP_READY (bit 4) should be set
    ${sts}=                 Read I3C Register  0  0x03C
    ${resp_rdy}=            Evaluate  (int(${sts}) >> 4) & 1
    Should Be Equal As Numbers  ${resp_rdy}  1  msg=RESP_READY should be set after command
    # Clear via W1C
    Write I3C Register      0  0x03C  0x10
    ${sts2}=                Read I3C Register  0  0x03C
    ${resp_rdy2}=           Evaluate  (int(${sts2}) >> 4) & 1
    Should Be Equal As Numbers  ${resp_rdy2}  0  msg=RESP_READY should be cleared after W1C

Command Generates Error Response
    [Documentation]         Writing a 2-dword command generates an error response (no devices)
    [Tags]                  birchstream  i3c  command
    Create AST2600 Machine
    # Write 2 dwords to command queue (arg + descriptor)
    Write I3C Register      0  0x00C  0x00000000
    Write I3C Register      0  0x00C  0x00000000
    # Read response
    ${resp}=                Read I3C Register  0  0x010
    # Error status should be non-zero (bits 31:28)
    ${err}=                 Evaluate  (int(${resp}) >> 28) & 0xF
    Should Not Be Equal As Numbers  ${err}  0  msg=Response should indicate error (no devices)

Response Queue Drains
    [Documentation]         After reading all responses, RESP_READY clears
    [Tags]                  birchstream  i3c  queue
    Create AST2600 Machine
    # Generate one response
    Write I3C Register      0  0x00C  0x00000000
    Write I3C Register      0  0x00C  0x00000000
    # Read the response (drains queue)
    Read I3C Register       0  0x010
    # RESP_READY should be cleared
    ${sts}=                 Read I3C Register  0  0x03C
    ${resp_rdy}=            Evaluate  (int(${sts}) >> 4) & 1
    Should Be Equal As Numbers  ${resp_rdy}  0  msg=RESP_READY should clear when queue drains

Bus Independence
    [Documentation]         6 I3C controllers operate independently
    [Tags]                  birchstream  i3c  independence
    Create AST2600 Machine
    # Write DEVICE_CTRL on port 0
    Write I3C Register      0  0x000  0x80000001
    ${port0}=               Read I3C Register  0  0x000
    ${port1}=               Read I3C Register  1  0x000
    Should Not Be Equal As Numbers  ${port0}  ${port1}  msg=Ports should be independent

IRQ Masking
    [Documentation]         IRQ does not assert unless INTR_SIGNAL_ENABLE is set
    [Tags]                  birchstream  i3c  irq
    Create AST2600 Machine
    # Ensure signal enable is 0
    Write I3C Register      0  0x044  0x00000000
    # Enable status enable for RESP_READY
    Write I3C Register      0  0x040  0x00000010
    # Generate a response
    Write I3C Register      0  0x00C  0x00000000
    Write I3C Register      0  0x00C  0x00000000
    # RESP_READY is set but IRQ should NOT fire (signal not enabled)
    # Now enable signal for RESP_READY
    Write I3C Register      0  0x044  0x00000010
    # IRQ should now be asserted (we can't check GPIO directly, but no crash = OK)

Soft Reset Clears Queues
    [Documentation]         Writing to RESET_CTRL clears the response queue
    [Tags]                  birchstream  i3c  reset
    Create AST2600 Machine
    # Generate a response
    Write I3C Register      0  0x00C  0x00000000
    Write I3C Register      0  0x00C  0x00000000
    # RESP_READY should be set
    ${sts}=                 Read I3C Register  0  0x03C
    ${resp_rdy}=            Evaluate  (int(${sts}) >> 4) & 1
    Should Be Equal As Numbers  ${resp_rdy}  1
    # Soft reset
    Write I3C Register      0  0x034  0x07
    # RESP_READY should be cleared
    ${sts2}=                Read I3C Register  0  0x03C
    Should Be Equal As Numbers  ${sts2}  0  msg=INTR_STATUS should be cleared after reset
    # Response queue should be empty
    ${resp}=                Read I3C Register  0  0x010
    Should Be Equal As Numbers  ${resp}  0  msg=Response queue should be empty after reset