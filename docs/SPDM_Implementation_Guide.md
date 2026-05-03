# SPDM Attestation for OpenBMC: Implementation Guide

This document describes the complete SPDM (Security Protocol and Data Model)
attestation implementation, covering the OpenBMC daemon (`spdmd`), the Renode
test device (`SpdmResponderDevice`), and the test infrastructure that validates
the entire flow end-to-end.

## Table of Contents

1. [Background](#background)
2. [Architecture Overview](#architecture-overview)
3. [The SPDM Protocol](#the-spdm-protocol)
4. [spdmd — The OpenBMC SPDM Requester Daemon](#spdmd--the-openbmc-spdm-requester-daemon)
5. [SpdmResponderDevice — The Renode Test Device](#spdmresponderdevice--the-renode-test-device)
6. [Test Scenario Configuration](#test-scenario-configuration)
7. [Test Infrastructure](#test-infrastructure)
8. [How the E2E Test Works Step by Step](#how-the-e2e-test-works-step-by-step)
9. [File Inventory](#file-inventory)

---

## Background

### What is SPDM?

SPDM (defined in DMTF DSP0274) is a standard protocol for authenticating
hardware components. A BMC (Board Management Controller) acting as an SPDM
*requester* can verify that attached devices (GPUs, NICs, storage controllers)
are running genuine firmware by:

1. Requesting the device's certificate chain
2. Challenging the device with a random nonce
3. Verifying the device's cryptographic signature over the challenge
4. Reading the device's firmware measurements (hashes of its firmware images)

If all signatures verify and the measurements match expected values, the device
is "attested" — proven to be running authentic, untampered firmware.

### What is MCTP?

MCTP (Management Component Transport Protocol, DMTF DSP0236) is a transport
layer that carries SPDM messages between the BMC and devices. MCTP can run
over various physical links — PCIe, I2C/SMBus, USB, or serial. In this
implementation, MCTP runs over a UART serial link (DSP0238), which Renode can
emulate without any host hardware.

### What is Renode?

Renode is an open-source hardware emulation framework. It can emulate an
entire AST2600 BMC SoC running a full OpenBMC Linux image. We extend Renode
with a custom C# device (`SpdmResponderDevice`) that behaves like a real
SPDM-capable hardware device, connected to the emulated BMC via UART.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│  Renode AST2600 Emulation                                │
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │  Guest Linux (OpenBMC)                            │   │
│  │                                                    │   │
│  │  ┌─────────┐    ┌─────────┐    ┌──────────────┐  │   │
│  │  │  spdmd  │───>│ AF_MCTP │───>│ mctp-serial  │  │   │
│  │  │(C++,    │    │ socket  │    │ /dev/ttyS0   │  │   │
│  │  │ OpenSSL)│    └─────────┘    └──────┬───────┘  │   │
│  │  └─────────┘         ▲               │           │   │
│  │       │              │               ▼           │   │
│  │  ┌────┴────┐    ┌────┴────┐    ┌──────────┐     │   │
│  │  │ mctpd   │    │ kernel  │    │  UART1   │     │   │
│  │  │ (D-Bus) │    │ AF_MCTP │    │ hardware │     │   │
│  │  └─────────┘    └─────────┘    └────┬─────┘     │   │
│  └─────────────────────────────────────┼────────────┘   │
│                                         │                │
│                              ┌──────────┴──────────┐    │
│                              │ SpdmResponderDevice  │    │
│                              │ (C#, Renode external) │    │
│                              │                       │    │
│                              │  MctpSerialTransport  │    │
│                              │  SpdmMctpControlHandler│   │
│                              │  SpdmProtocolHandler   │    │
│                              │  SpdmScenarioConfig    │    │
│                              └───────────────────────┘    │
└──────────────────────────────────────────────────────────┘
```

**Data flow for an SPDM attestation:**

1. `spdmd` opens an `AF_MCTP` socket and sends an SPDM message (e.g.,
   GET_VERSION)
2. The Linux kernel's MCTP stack routes it through `mctp-serial` to UART1
3. UART1 bytes flow through the Renode connector to `SpdmResponderDevice`
4. `SpdmResponderDevice` decodes the MCTP serial frame, extracts the SPDM
   message, processes it, and sends the response back through UART1
5. The kernel delivers the response to `spdmd` via the `AF_MCTP` socket

---

## The SPDM Protocol

SPDM attestation consists of 7 request-response exchanges, always in this
order. Each message is a binary packet with a 4-byte header:
`[version, code, param1, param2]`.

### Step 1: GET_VERSION → VERSION

The requester discovers which SPDM versions the responder supports.

```
Request:  [0x10, 0x84, 0x00, 0x00]    (always SPDM 1.0)
Response: [0x10, 0x04, 0x00, 0x00, 0x00, count, entries...]
```

Each version entry is a 2-byte LE value encoding major.minor. Our responder
advertises versions 1.1 and 1.2. The requester selects the highest common
version (1.2).

### Step 2: GET_CAPABILITIES → CAPABILITIES

The requester and responder exchange capability flags indicating which SPDM
features they support.

```
Request:  [0x12, 0xE1, ...padding...]  (20 bytes for SPDM 1.2)
Response: [0x12, 0x61, 0x00, 0x00, ...flags...]
```

Our responder reports three capabilities:
- `CERT_CAP` (0x02) — can provide certificate chains
- `CHAL_CAP` (0x04) — can respond to cryptographic challenges
- `MEAS_CAP` (0x10) — can provide signed firmware measurements

### Step 3: NEGOTIATE_ALGORITHMS → ALGORITHMS

Both sides agree on which cryptographic algorithms to use.

```
Request:  [0x12, 0xE3, ...algo preferences...]  (32+ bytes)
Response: [0x12, 0x63, ...selected algos...]     (36 bytes)
```

Our implementation negotiates:
- **Base hash**: SHA-256 (`0x00000001`)
- **Base asymmetric**: ECDSA-P256 (`0x00000010`)
- **Measurement hash**: SHA-256
- **Measurement specification**: DMTF

After this step, both sides have agreed on crypto algorithms. Steps 1-3 form
the "VCA transcript" (Version, Capabilities, Algorithms) which is included
in later signature computations.

### Step 4: GET_DIGESTS → DIGESTS

The requester asks for SHA-256 hashes of each certificate chain slot.

```
Request:  [0x12, 0x81, 0x00, 0x00]
Response: [0x12, 0x01, 0x00, slot_mask, digest(32 bytes)...]
```

Our responder has a single certificate chain in slot 0, so `slot_mask = 0x01`
and the response includes one 32-byte SHA-256 digest.

### Step 5: GET_CERTIFICATE → CERTIFICATE (possibly multiple rounds)

The requester retrieves the full certificate chain, which may require
multiple request-response rounds if the chain is larger than one MCTP frame.

```
Request:  [0x12, 0x82, slot, 0x00, offset(2B LE), length(2B LE)]
Response: [0x12, 0x02, slot, 0x00, portion_length(2B), remainder(2B), data...]
```

The certificate data is in `spdm_cert_chain_t` format:
```
[total_length: 2B LE][reserved: 2B][root_hash: 32B SHA-256][DER certificates...]
```

The requester loops, incrementing `offset`, until `remainder_length == 0`.
It then extracts the leaf certificate's public key for signature verification.

### Step 6: CHALLENGE → CHALLENGE_AUTH

The requester sends a random 32-byte nonce. The responder signs the entire
conversation transcript (VCA + certificate exchanges + this challenge) with
its private key.

```
Request:  [0x12, 0x83, slot, meas_summary_type, nonce(32B)]
Response: [0x12, 0x03, slot, slot_mask,
           cert_chain_hash(32B), responder_nonce(32B),
           opaque_length(2B), signature(64B)]
```

The signature covers the SPDM 1.2 "to-be-signed" (TBS) structure:
```
[prefix: 64B = "dmtf-spdm-v1.2.*" × 4]
[context: 36B = "responder-challenge_auth signing" + zero padding]
[SHA-256(full transcript): 32B]
```

The requester verifies this signature using the public key extracted from
the certificate chain. If it verifies, the device has proven possession of
the private key corresponding to its certificate — it is who it claims to be.

### Step 7: GET_MEASUREMENTS → MEASUREMENTS (two rounds)

**Round 1 — Count only** (no signature):
```
Request:  [0x12, 0xE0, 0x00, 0x00]  (attributes=0, operation=0)
Response: [0x12, 0x60, 0x00, total_count, 0x00, 0x00, 0x00, 0x00, ...]
```

**Round 2 — All measurements with signature**:
```
Request:  [0x12, 0xE0, 0x01, 0xFF, nonce(32B)]
Response: [0x12, 0x60, slot, 0x00, num_blocks, record_length(3B),
           measurement_blocks..., nonce(32B), opaque_len(2B), signature(64B)]
```

Each measurement block has the DMTF format:
```
[index: 1B][spec: 1B][meas_size: 2B LE][dmtf_type: 1B][value_size: 2B LE][hash: 32B]
```

The requester verifies the measurement signature the same way as the
challenge signature, using `"responder-measurements signing"` as the context
string (and only VCA transcript, not certificate transcript).

If all 7 steps succeed, `spdmd` logs:
```
SPDM attestation PASSED for EID 20: version=1.2, measurements=2
```

---

## spdmd — The OpenBMC SPDM Requester Daemon

### Source Files

| File | Purpose |
|------|---------|
| `spdm/requester/spdmd.cpp` | `main()` — creates async context, starts discovery |
| `spdm/requester/spdmd.hpp` | D-Bus service name and object path constants |
| `spdm/requester/spdm_discovery.cpp` | Orchestrates transport-agnostic discovery |
| `spdm/requester/spdm_discovery.hpp` | `SPDMDiscovery` class, `ResponderInfo`, transport concepts |
| `spdm/requester/mctp_transport_discovery.cpp` | MCTP-specific endpoint discovery |
| `spdm/requester/mctp_transport_discovery.hpp` | `MCTPTransportDiscovery` class |
| `spdm/requester/spdm_requester.cpp` | Full SPDM 1.2 requester: 7-step attestation + crypto |
| `spdm/requester/spdm_requester.hpp` | `SpdmRequester`, `AttestationResult` |
| `spdm/service/spdmd.service` | systemd unit file |
| `spdm/meson.build` | Build configuration |

### How spdmd Works

**Startup sequence:**

1. `main()` creates an sdbusplus async context
2. `MCTPTransportDiscovery` is spawned as an async coroutine
3. Discovery waits 3 seconds for `mctpd` to populate endpoints
4. It queries the D-Bus mapper for all objects implementing
   `au.com.codeconstruct.MCTP.Endpoint1`
5. For each discovered endpoint, it extracts the EID from the D-Bus path
6. It creates a `SpdmRequester` and calls `attest()`

**SpdmRequester::attest():**

The `attest()` method (in `spdm_requester.cpp`) executes the 7 SPDM steps
in sequence. Each step:

- Builds a request message
- Sends it via `AF_MCTP` socket (`sendto`)
- Reads the response (`recvfrom`)
- Validates the response code and structure
- Appends request/response to the appropriate transcript (VCA or cert)

After step 5 (GET_CERTIFICATE), `extractPeerPublicKey()` parses the DER
certificate chain using OpenSSL's `d2i_X509()`, iterates through all
certificates, and extracts the public key from the leaf (last) certificate.

Steps 6 and 7 verify ECDSA-P256 signatures. The signature verification
(`verifySignature()`) works as follows:

1. Concatenates the relevant transcript (VCA + optionally cert transcript +
   request + response-without-signature)
2. Hashes the concatenation with SHA-256
3. Builds the SPDM 1.2 TBS: `prefix(64B) + context(36B) + hash(32B)` = 132
   bytes
4. Converts the P1363 signature format (R||S, 64 bytes) to DER for OpenSSL
5. Calls `EVP_DigestVerifyInit/Update/Final` to verify

**D-Bus integration:**

`spdmd` is a D-Bus service (`xyz.openbmc_project.spdmd`) started by systemd
after `mctpd.service`. It exposes discovered devices under the
`/xyz/openbmc_project/attestation/` object path namespace.

---

## SpdmResponderDevice — The Renode Test Device

### Source Files

All in `src/Renode/Integrations/SpdmResponderDevice/`:

| File | Lines | Purpose |
|------|-------|---------|
| `SpdmResponderDevice.cs` | ~200 | Main device: UART attachment, MCTP framing, message dispatch |
| `SpdmMctpControlHandler.cs` | ~90 | MCTP control message handler (SET_EID, GET_EID, etc.) |
| `SpdmProtocolHandler.cs` | ~530 | Full SPDM 1.2 responder state machine + crypto |
| `SpdmScenarioConfig.cs` | ~180 | JSON scenario loader, key file loading, measurement config |

### SpdmResponderDevice.cs — The Outer Shell

This class extends Renode's `BackendTerminal`, meaning it connects to a UART
peripheral the same way a terminal emulator would. It receives bytes from the
guest OS via `WriteChar()` and sends bytes back via `CallCharReceived()`.

**Key responsibilities:**

- **MCTP serial framing**: Delegates to `MctpSerialTransport` (shared with
  the PLDM device). This handles the DSP0238 serial binding: `0x7E` framing
  bytes, version byte, length byte, CRC-CCITT, and byte-stuffing for `0x7E`
  and `0x7D` within the frame.

- **Multi-packet reassembly**: MCTP messages larger than one frame are split
  into multiple packets with SOM (Start of Message) and EOM (End of Message)
  flags. The device reassembles these into complete messages before dispatch.

- **Message dispatch**: Routes complete MCTP messages by message type:
  - `0x00` (Control) → `SpdmMctpControlHandler`
  - `0x05` (SPDM) → `SpdmProtocolHandler`

- **Exception safety**: If the SPDM handler throws an exception, the device
  catches it and returns an SPDM ERROR response instead of propagating the
  exception (which would hang the Renode monitor).

**Registration**: The `SpdmResponderDeviceExtensions` class provides the
extension method `CreateSpdmResponderDevice()` on the `Emulation` class,
allowing it to be invoked from Renode's monitor:

```
emulation CreateSpdmResponderDevice "spdm_dev" @/path/to/scenario.json
connector Connect uart1 spdm_dev
```

### SpdmMctpControlHandler.cs — MCTP Control Messages

Before SPDM can begin, the BMC's `mctpd` daemon needs to discover and
configure the MCTP endpoint. It sends MCTP control messages (message type
`0x00`) to:

- **Set Endpoint ID** (`0x01`): Assigns EID 20 to the device
- **Get Endpoint ID** (`0x02`): Reads back the assigned EID
- **Get UUID** (`0x03`): Returns the device's 16-byte UUID
- **Get Message Type Support** (`0x05`): Returns supported message types
  (Control `0x00` and SPDM `0x05`)

This handler is stateless — each control message is handled independently
based on the command byte in the payload.

### SpdmProtocolHandler.cs — The SPDM State Machine

This is the core of the responder. It implements all 7 SPDM response types
with a simple state machine:

```
NotStarted → AfterVersion → AfterCapabilities → Negotiated
```

Requests received out of order return SPDM ERROR with `UnexpectedRequest`.

**Initialization**: On construction, the handler:

1. Loads the ECDSA-P256 private key from the PKCS#8 DER file specified in
   the scenario
2. Builds the `spdm_cert_chain_t` buffer: `[total_length][reserved][root_hash][DER certs]`
3. Pre-computes the SHA-256 hash of the cert chain buffer (used in DIGESTS
   responses)

The root hash is computed by extracting the first DER certificate from the
chain and hashing it. `ExtractFirstDerCert()` parses the ASN.1 length encoding
(handling 1-4 byte length forms) to find where the first certificate ends.

**Transcript tracking**: The handler maintains two transcript buffers:
- `vcaTranscript`: accumulates GET_VERSION, GET_CAPABILITIES, and
  NEGOTIATE_ALGORITHMS request/response pairs
- `certTranscript`: accumulates GET_DIGESTS and GET_CERTIFICATE
  request/response pairs

These transcripts are used when computing signatures for CHALLENGE_AUTH and
MEASUREMENTS responses.

**Signing** (`SignTranscript()`):

1. Concatenates the relevant transcripts + current request + current response
   (without the signature field)
2. Hashes the concatenation with SHA-256
3. Builds the SPDM 1.2 TBS (to-be-signed) structure:
   - 64 bytes: `"dmtf-spdm-v1.2.*"` repeated 4 times
   - 36 bytes: context string (e.g., `"responder-challenge_auth signing"`)
     followed by zero padding
   - 32 bytes: SHA-256 of the transcript
4. Signs the 132-byte TBS with ECDSA-P256 using .NET's `ECDsa.SignData()`,
   producing a 64-byte IEEE P1363 signature (R||S concatenation)

**Measurement blocks**: Each measurement is encoded in DMTF format:
```
[index: 1B][spec: 1B (0x01=DMTF)][meas_data_size: 2B LE]
[dmtf_type: 1B (0x80 | type)][value_size: 2B LE][value: 32B hash]
```

The `0x80` bit in `dmtf_type` indicates the value is a raw
hash/digest rather than a raw bitstream.

### SpdmScenarioConfig.cs — Configuration

Loads a JSON scenario file that specifies:

```json
{
    "device": {
        "eid": 20,
        "uuid": "162023C9-3EC5-4115-95F4-48701D49D675",
        "name": "GPU0-SPDM"
    },
    "spdm": {
        "key_dir": "/path/to/sample_key",
        "cert_chain": "ecp256/bundle_responder.certchain.der",
        "private_key": "ecp256/end_responder.key.p8",
        "measurements": [
            {
                "index": 1,
                "type": "ImmutableROM",
                "description": "Boot ROM firmware hash",
                "value": "AABBCCDD..."
            }
        ]
    }
}
```

The JSON parser is a minimal hand-written recursive-descent parser
(`SimpleJsonParser`) to avoid external dependencies in the Renode C# project.

Measurement types map to DMTF codes:
- `ImmutableROM` → 0
- `MutableFirmware` → 1
- `HardwareConfiguration` → 2
- `FirmwareConfiguration` → 3

---

## Test Scenario Configuration

The test scenario (`spdm-test-scenario.json`) configures a simulated GPU
("GPU0-SPDM") at MCTP endpoint ID 20 with:

- **Certificate chain**: `ecp256/bundle_responder.certchain.der` from the
  libspdm test key directory — a chain of ECDSA-P256 certificates (root CA →
  intermediate → leaf)
- **Private key**: `ecp256/end_responder.key.p8` — the leaf certificate's
  PKCS#8 private key
- **Two measurements**:
  1. Index 1, ImmutableROM: a fixed 32-byte hash representing the boot ROM
  2. Index 2, MutableFirmware: a fixed 32-byte hash representing runtime firmware

These are the same test keys used by the DMTF's reference implementation
(libspdm), ensuring interoperability.

---

## Test Infrastructure

### Unit Tests (SPDM_unit_test.robot)

The unit tests verify the `SpdmResponderDevice` in isolation — no OpenBMC
boot, no Linux kernel, just a bare UART connected to the device.

**Setup**: Creates a minimal machine with a single NS16550 UART and attaches
the `SpdmResponderDevice`. A Python helper (`spdm_mctp_helper.py`) injects
raw bytes into the UART register and reads response bytes back.

**Python helper** (`spdm_mctp_helper.py`):

The helper provides functions to construct and send MCTP serial frames by
writing bytes directly to the UART's transmit register at `0x1E783000`. It
handles:
- MCTP serial framing (0x7E delimiters, version, length, CRC-CCITT)
- Byte-stuffing (escaping 0x7E and 0x7D within the frame)
- MCTP packet headers (version, dest EID, src EID, flags, message type)
- SPDM message construction and response parsing

Key functions:
- `send_mctp_control(payload)` — sends an MCTP control request
- `send_spdm_request(spdm_bytes)` — sends an SPDM message in MCTP framing
- `read_mctp_response()` — reads and unescapes a response frame from UART RX
- `test_*() / check_*()` — paired send/verify functions for each SPDM message

**Test cases** (7 total):

| Test | What It Verifies |
|------|------------------|
| Should Create And Attach | Device creates, loads keys, attaches to UART |
| Should Report SPDM Message Type Support | MCTP control returns types Control + SPDM |
| Should Respond To GET_VERSION | Returns SPDM 1.1 and 1.2 |
| Should Complete Full Negotiation | GET_VERSION + GET_CAPABILITIES + NEGOTIATE_ALGORITHMS |
| Should Return Certificate Digests | GET_DIGESTS returns slot 0 hash |
| Should Return Certificate Chain | GET_CERTIFICATE returns non-empty cert chain |

These tests run in about 2 seconds since there is no OS boot.

### E2E Test (ASPEED_SPDM_Attestation.robot)

The E2E test boots a complete OpenBMC image in a Renode-emulated AST2600 and
runs the full attestation flow with `spdmd` as the requester.

**Test cases** (2):

1. **Should Boot And Login To OpenBMC** — boots OpenBMC, logs in, saves state
2. **Should Complete SPDM Attestation** — restores state, attaches device,
   configures MCTP, restarts spdmd, verifies attestation success in journal

The boot test uses Renode's `Provides/Requires` mechanism to snapshot the
machine state after boot. This means the second test doesn't need to re-boot
— it restores the snapshot and only spends time on the SPDM-specific steps.

---

## How the E2E Test Works Step by Step

### Phase 1: Boot (test case 1)

1. **Create Base Machine**: Load the AST2600 platform description and the
   OpenBMC firmware image at three memory addresses:
   - `0x00000000` — bootrom (SPL starts here)
   - `0x60000000` — flash backing store
   - `0x88000000` — DRAM (U-Boot expects `bootm` image here)

2. **Silence unmapped regions**: Several hardware peripherals not yet modeled
   in Renode would cause driver probe hangs. `SilenceRange` makes reads
   return zero and ignores writes.

3. **U-Boot interrupt**: Wait for `autoboot` prompt, press Enter to interrupt,
   set kernel boot args (`nosmp maxcpus=1` for stable emulation), then `bootm`.

4. **Login**: Wait for `login:` prompt, type `root` / `0penBmc`.

5. **Snapshot**: `Provides booted-state` saves the entire machine state.

### Phase 2: SPDM Attestation (test case 2)

1. **Restore**: `Requires booted-state` restores the snapshot.

2. **Attach SPDM Device**: Create the `SpdmResponderDevice` with the test
   scenario and connect it to `uart1`. The device is attached *after* restore
   because Renode external devices don't survive serialization.

3. **Configure MCTP** (5 shell commands with virtual time advances between):
   ```
   nohup mctp link serial /dev/ttyS0 &   # start mctp-serial daemon
   mctp link set mctpserial0 up           # bring up the MCTP link
   mctp addr add 8 dev mctpserial0        # assign local EID 8
   mctp route add 20 via mctpserial0      # route EID 20 through serial
   busctl call ... AssignEndpointStatic ayy 0 20  # tell mctpd about EID 20
   ```

   The `AssignEndpointStatic` D-Bus call triggers `mctpd` to send MCTP
   control messages (SET_EID, GET_EID) through the serial link. The
   `SpdmResponderDevice` responds to these, completing endpoint setup.

4. **Restart spdmd**: `systemctl restart spdmd` triggers a fresh MCTP endpoint
   discovery. This is necessary because `spdmd` started at boot before any
   MCTP endpoints were configured — it found nothing and went idle. The
   restart makes it re-query the D-Bus mapper, find the newly configured
   endpoint at EID 20, and begin attestation.

5. **Wait**: 30 seconds of virtual time for spdmd to:
   - Start up (3s initial sleep waiting for mctpd)
   - Query D-Bus for MCTP endpoints
   - Run the 7-step SPDM attestation over `AF_MCTP` socket

6. **Assert**: Check `journalctl -u spdmd` for the string
   `attestation PASSED`. The full log message is:
   ```
   SPDM attestation PASSED for EID 20: version=1.2, measurements=2
   ```

### Timing and Virtual Time

Renode uses deterministic virtual time, not wall-clock time. The test uses
`Pause And Run For` to advance virtual time by specific amounts:

- 3s after `mctp link serial` — let the daemon start
- 1s between each `mctp` configuration command
- 10s after `AssignEndpointStatic` — allow MCTP control message exchange
- 30s after `systemctl restart spdmd` — allow full attestation
- 5s after `journalctl` check command — let output appear

Total virtual time for the attestation phase: ~51 seconds.
Total wall-clock time: ~180 seconds (Renode emulation overhead).

---

## File Inventory

### OpenBMC spdmd (C++, built into the BMC image)

```
spdm/
├── meson.build                          # Build config (C++23, OpenSSL, sdbusplus)
├── requester/
│   ├── spdmd.cpp                        # main() — async context + discovery
│   ├── spdmd.hpp                        # D-Bus name/path constants
│   ├── spdm_discovery.cpp               # Transport-agnostic discovery orchestrator
│   ├── spdm_discovery.hpp               # SPDMDiscovery, ResponderInfo, concepts
│   ├── mctp_transport_discovery.cpp      # MCTP endpoint discovery via D-Bus
│   ├── mctp_transport_discovery.hpp      # MCTPTransportDiscovery class
│   ├── spdm_requester.cpp               # 7-step SPDM attestation + signature verify
│   ├── spdm_requester.hpp               # SpdmRequester, AttestationResult
│   └── utils/
│       └── mapper.cpp                   # D-Bus mapper query utility
└── service/
    └── spdmd.service                    # systemd unit (Type=dbus, After=mctpd)
```

### Renode SpdmResponderDevice (C#, Renode plugin)

```
src/Renode/Integrations/SpdmResponderDevice/
├── SpdmResponderDevice.cs               # UART attachment, MCTP dispatch, reassembly
├── SpdmMctpControlHandler.cs            # MCTP control: SET_EID, GET_EID, UUID, types
├── SpdmProtocolHandler.cs               # SPDM 1.2 state machine, crypto, signing
└── SpdmScenarioConfig.cs               # JSON config loader, key/cert file loading
```

### Shared infrastructure (used by both SPDM and PLDM devices)

```
src/Renode/Integrations/PldmFirmwareDevice/
├── MctpSerialTransport.cs               # DSP0238 serial framing, CRC, byte-stuffing
└── MctpPacket.cs                        # MCTP packet build/parse, SOM/EOM flags
```

### Test files

```
tests/peripherals/Aspeed/
├── SPDM_unit_test.robot                 # 7 unit tests (no OS boot)
├── ASPEED_SPDM_Attestation.robot        # 2 E2E tests (full OpenBMC boot)
├── spdm_mctp_helper.py                  # Python helper for injecting MCTP/SPDM bytes
└── firmware/
    └── openbmc-image.bin → ...          # Symlink to built OpenBMC image with spdmd

spdm-test-scenario.json                  # Device config: EID 20, ECDSA-P256, 2 measurements
```
