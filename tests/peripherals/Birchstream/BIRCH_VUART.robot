*** Settings ***
Documentation       Birchstream SOL/VUART console tests.
...                 Tests host COM1 -> BMC UART9 serial console bridge.

*** Keywords ***
Create AST2600 Machine
    Execute Command         mach create "ast2600"
    Execute Command         machine LoadPlatformDescription @platforms/boards/ast2600/ast2600-evb.repl

Read VUART Register
    [Arguments]             ${offset}
    ${val}=  Execute Command    vuart ReadDoubleWord ${offset}
    RETURN                  ${val.strip()}

Write VUART Register
    [Arguments]             ${offset}  ${value}
    Execute Command         vuart WriteDoubleWord ${offset} ${value}

*** Test Cases ***
VUART Reset State
    [Documentation]         Verify default register values after reset
    [Tags]                  birchstream  vuart  reset
    Create AST2600 Machine
    # LSR should show TX empty (THRE + TEMT = 0x60)
    ${lsr}=                 Read VUART Register  0x14
    ${thre}=                Evaluate  ${lsr} & 0x60
    Should Be Equal As Numbers  ${thre}  96
    # LCR default 8-N-1 = 0x03
    ${lcr}=                 Read VUART Register  0x0C
    Should Be Equal As Numbers  ${lcr}  3
    # RX FIFO count should be 0
    ${rxcnt}=               Read VUART Register  0x2C
    Should Be Equal As Numbers  ${rxcnt}  0

Host Inject Single Byte
    [Documentation]         Host injects a byte, BMC reads it from RBR
    [Tags]                  birchstream  vuart  rx
    Create AST2600 Machine
    Execute Command         vuart InjectHostByte 0x41
    # Data Ready in LSR
    ${lsr}=                 Read VUART Register  0x14
    ${dr}=                  Evaluate  ${lsr} & 1
    Should Be Equal As Numbers  ${dr}  1
    # Read the byte from RBR
    ${data}=                Read VUART Register  0x00
    Should Be Equal As Numbers  ${data}  65

Host Inject String
    [Documentation]         Host injects a string, BMC reads characters
    [Tags]                  birchstream  vuart  rx  string
    Create AST2600 Machine
    Execute Command         vuart InjectHostString "Hi"
    # RX count should be 2
    ${rxcnt}=               Read VUART Register  0x2C
    Should Be Equal As Numbers  ${rxcnt}  2
    # Read first byte
    ${b1}=                  Read VUART Register  0x00
    Should Be Equal As Numbers  ${b1}  72
    # Read second byte
    ${b2}=                  Read VUART Register  0x00
    Should Be Equal As Numbers  ${b2}  105

BMC TX To Host
    [Documentation]         BMC writes to THR, host reads from TX FIFO
    [Tags]                  birchstream  vuart  tx
    Create AST2600 Machine
    # BMC writes 'A' to THR
    Write VUART Register    0x00  0x41
    # TX count should be 1
    ${txcnt}=               Read VUART Register  0x28
    Should Be Equal As Numbers  ${txcnt}  1
    # Read back via host method
    ${byte}=  Execute Command    vuart ReadHostByte
    Should Be Equal As Numbers  ${byte.strip()}  65

BMC TX String Read By Host
    [Documentation]         BMC writes multiple chars, host reads string
    [Tags]                  birchstream  vuart  tx  string
    Create AST2600 Machine
    Write VUART Register    0x00  0x4F
    Write VUART Register    0x00  0x4B
    ${str}=  Execute Command    vuart ReadHostString
    Should Contain          ${str}  OK

VUART DLAB Divisor Access
    [Documentation]         DLAB mode accesses baud rate divisor
    [Tags]                  birchstream  vuart  dlab
    Create AST2600 Machine
    # Set DLAB (LCR bit 7)
    Write VUART Register    0x0C  0x83
    # Write divisor low = 0x01, high = 0x00
    Write VUART Register    0x00  0x01
    Write VUART Register    0x04  0x00
    # Read back divisor
    ${dl}=                  Read VUART Register  0x00
    Should Be Equal As Numbers  ${dl}  1
    # Clear DLAB
    Write VUART Register    0x0C  0x03

VUART Host IO Port Config
    [Documentation]         ADDL/ADDH configure host I/O port (COM1 = 0x3F8)
    [Tags]                  birchstream  vuart  config
    Create AST2600 Machine
    ${addl}=                Read VUART Register  0x20
    # Low byte of I/O port in bits [15:8]
    ${iolow}=               Evaluate  (${addl} >> 8) & 0xFF
    # SIRQ in bits [7:0]
    ${sirq}=                Evaluate  ${addl} & 0xFF
    Should Be Equal As Numbers  ${sirq}  4
    ${addh}=                Read VUART Register  0x24
    # High byte of I/O port
    Should Be Equal As Numbers  ${addh}  3

VUART RX Interrupt
    [Documentation]         RX data available triggers interrupt
    [Tags]                  birchstream  vuart  interrupt
    Create AST2600 Machine
    # Enable RX interrupt (IER bit 0)
    Write VUART Register    0x04  0x01
    # Inject data
    Execute Command         vuart InjectHostByte 0x42
    # IIR should show RX data available (0x04)
    ${iir}=                 Read VUART Register  0x08
    Should Be Equal As Numbers  ${iir}  4

VUART TX Disable
    [Documentation]         TX disable prevents data from entering TX FIFO
    [Tags]                  birchstream  vuart  config  txdisable
    Create AST2600 Machine
    # Set TX disable (ADDH bit 8)
    ${addh}=                Read VUART Register  0x24
    ${newaddh}=             Evaluate  ${addh} | 0x100
    Write VUART Register    0x24  ${newaddh}
    # Write to THR
    Write VUART Register    0x00  0x41
    # TX count should remain 0
    ${txcnt}=               Read VUART Register  0x28
    Should Be Equal As Numbers  ${txcnt}  0

VUART Bidirectional Loopback
    [Documentation]         Host -> BMC -> Host roundtrip
    [Tags]                  birchstream  vuart  loopback  e2e
    Create AST2600 Machine
    # Host sends 'X'
    Execute Command         vuart InjectHostByte 0x58
    # BMC reads it
    ${rx}=                  Read VUART Register  0x00
    Should Be Equal As Numbers  ${rx}  88
    # BMC echoes it back
    Write VUART Register    0x00  ${rx}
    # Host reads it
    ${echo}=  Execute Command    vuart ReadHostByte
    Should Be Equal As Numbers  ${echo.strip()}  88