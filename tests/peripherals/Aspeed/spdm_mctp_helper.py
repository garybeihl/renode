# SPDM/MCTP test helper for Renode Python environment
# Provides functions to send MCTP-framed SPDM messages via UART sysbus
# and read/parse response frames.
#
# IMPORTANT: Between send and read, virtual time must advance.
# Call emulation RunFor "0:0:0.001" from the .resc script between
# send_spdm_request() and read_spdm_response().

UART_BASE = 0x1e783000

def _crc_ccitt(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8408 if crc & 1 else crc >> 1
    return crc

def _send_mctp_serial_frame(bus, pkt_bytes):
    """Send an MCTP serial frame: [0x7E][ver][len][escaped data][FCS][0x7E]"""
    ver = 0x01
    length = len(pkt_bytes)
    fcs = _crc_ccitt([ver, length] + list(pkt_bytes))

    bus.WriteByte(UART_BASE, 0x7E)
    bus.WriteByte(UART_BASE, ver)
    bus.WriteByte(UART_BASE, length)

    for b in pkt_bytes:
        if b in (0x7E, 0x7D):
            bus.WriteByte(UART_BASE, 0x7D)
            bus.WriteByte(UART_BASE, b & ~0x20)
        else:
            bus.WriteByte(UART_BASE, b)

    # FCS bytes are sent RAW (not escaped), matching Linux kernel mctp-serial
    # and the C# MctpSerialTransport receiver.
    bus.WriteByte(UART_BASE, (fcs >> 8) & 0xFF)
    bus.WriteByte(UART_BASE, fcs & 0xFF)

    bus.WriteByte(UART_BASE, 0x7E)

def _read_mctp_serial_frame(bus):
    """Read one MCTP serial frame using positional parsing.

    Frame: [0x7E][ver][len][escaped_data][FCS_hi][FCS_lo][0x7E]
    Data bytes are byte-stuffed (0x7E->0x7D,0x5E; 0x7D->0x7D,0x5D).
    FCS bytes and trailing flag are raw (not byte-stuffed), matching
    the C# MctpSerialTransport state machine and Linux kernel mctp-serial.
    """
    def _rb():
        lsr = bus.ReadByte(UART_BASE + 5)
        if (lsr & 0x01) == 0:
            return -1
        return bus.ReadByte(UART_BASE)

    # Wait for opening 0x7E flag
    for _ in range(4096):
        b = _rb()
        if b < 0:
            return None
        if b == 0x7E:
            break
    else:
        return None

    # Skip consecutive 0x7E flags (inter-frame fill)
    ver = -1
    for _ in range(16):
        b = _rb()
        if b < 0:
            return None
        if b != 0x7E:
            ver = b
            break

    if ver != 0x01:
        return None

    length = _rb()
    if length <= 0:
        return None

    # Read exactly `length` unescaped data bytes (with byte-stuffing)
    data = []
    for _ in range(length * 2 + 16):
        if len(data) >= length:
            break
        b = _rb()
        if b < 0:
            break
        if b == 0x7D:
            b2 = _rb()
            if b2 < 0:
                break
            data.append(b2 | 0x20)
        else:
            data.append(b)

    if len(data) != length:
        return None

    # Read 2 FCS bytes (raw, not byte-stuffed)
    _rb()  # FCS hi
    _rb()  # FCS lo

    # Read trailing 0x7E flag
    _rb()

    return data

def hex_str(byte_list):
    """Convert byte list to hex string."""
    if byte_list is None:
        return "None"
    return " ".join(["%02X" % b for b in byte_list])

# --- Send functions (call these before emulation RunFor) ---

def send_mctp_control(control_payload, dest_eid=0x14, src_eid=0x08):
    """Send an MCTP control request frame."""
    bus = self.Machine["sysbus"]
    pkt = [0x01, dest_eid, src_eid, 0xC8, 0x00] + list(control_payload)
    _send_mctp_serial_frame(bus, pkt)

def send_spdm_request(spdm_bytes, dest_eid=0x14, src_eid=0x08):
    """Send an MCTP-framed SPDM request."""
    bus = self.Machine["sysbus"]
    pkt = [0x01, dest_eid, src_eid, 0xC8, 0x05] + list(spdm_bytes)
    _send_mctp_serial_frame(bus, pkt)

# --- Read functions (call these after emulation RunFor) ---

def _read_mctp_message(bus):
    """Read a complete MCTP message, reassembling multi-frame responses.

    MCTP serial fragments large messages across multiple frames (DSP0236 9.4.1).
    Each frame has SOM/EOM flags in byte 3: SOM=0x80, EOM=0x40.
    - SOM+EOM: single-frame message
    - SOM only: first fragment (has msg_type byte at offset 4)
    - Neither: middle fragment (no msg_type byte)
    - EOM only: last fragment (no msg_type byte)

    Returns reassembled packet in single-frame format:
    [ver, dest, src, flags, msg_type, full_payload...]
    """
    first = _read_mctp_serial_frame(bus)
    if first is None or len(first) < 4:
        return None

    flags = first[3]
    som = (flags & 0x80) != 0
    eom = (flags & 0x40) != 0

    if not som:
        # Stale continuation fragment — drain until EOM or FIFO empty
        while not eom:
            frag = _read_mctp_serial_frame(bus)
            if frag is None or len(frag) < 4:
                break
            eom = (frag[3] & 0x40) != 0
        return None

    if eom:
        # Single-frame message, return as-is
        return first

    # Multi-frame: first frame has [ver, dest, src, flags, msg_type, payload...]
    msg_type = first[4] if len(first) > 4 else 0xFF
    payload = list(first[5:]) if len(first) > 5 else []

    # Read continuation frames until EOM
    for _ in range(256):
        frag = _read_mctp_serial_frame(bus)
        if frag is None or len(frag) < 4:
            break
        frag_eom = (frag[3] & 0x40) != 0
        # Continuation frames: [ver, dest, src, flags, payload...] (no msg_type)
        if len(frag) > 4:
            payload.extend(frag[4:])
        if frag_eom:
            break

    # Reassemble into single-message format
    return [first[0], first[1], first[2],
            (first[3] | 0xC0),  # set SOM+EOM
            msg_type] + payload

def read_mctp_response():
    """Read and return a complete MCTP message from UART RX, with multi-frame reassembly."""
    bus = self.Machine["sysbus"]
    return _read_mctp_message(bus)

def read_spdm_response():
    """Read MCTP response and extract SPDM message bytes."""
    data = read_mctp_response()
    if data is None or len(data) < 5:
        return None
    # data: [ver, dest, src, flags, msg_type, payload...]
    return data[5:]  # SPDM message bytes (after MCTP header + msg_type)

def read_mctp_control_response():
    """Read MCTP response and extract control payload bytes."""
    data = read_mctp_response()
    if data is None or len(data) < 5:
        return None
    return data[5:]  # control payload after MCTP header + msg_type

# --- Combined send-read helpers for use from .resc ---
# These store the last result in a global variable for checking.

_last_result = ""

def test_mctp_get_msg_type_support():
    """Send GetMessageTypeSupport, store result in _last_result."""
    send_mctp_control([0x80, 0x05])

def check_mctp_get_msg_type_support():
    """Check the response to GetMessageTypeSupport."""
    global _last_result
    resp = read_mctp_control_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if len(resp) < 4:
        _last_result = "FAIL: response too short: " + hex_str(resp)
        return
    cc = resp[2]
    count = resp[3]
    types = [resp[4 + i] for i in range(count) if 4 + i < len(resp)]
    types_str = ",".join(["0x%02X" % t for t in types])
    if cc != 0:
        _last_result = "FAIL: cc=%d" % cc
    elif count != 2 or 0x00 not in types or 0x05 not in types:
        _last_result = "FAIL: expected Control+SPDM, got count=%d types=%s" % (count, types_str)
    else:
        _last_result = "PASS: count=%d types=%s" % (count, types_str)

def test_spdm_get_version():
    """Send GET_VERSION."""
    send_spdm_request([0x10, 0x84, 0x00, 0x00])

def check_spdm_get_version():
    """Check VERSION response."""
    global _last_result
    resp = read_spdm_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if len(resp) < 6:
        _last_result = "FAIL: too short: " + hex_str(resp)
        return
    if resp[1] != 0x04:
        _last_result = "FAIL: code=0x%02X expected 0x04" % resp[1]
        return
    count = resp[5]
    versions = []
    for i in range(count):
        off = 6 + i * 2
        if off + 1 < len(resp):
            major = (resp[off + 1] >> 4) & 0xF
            minor = resp[off + 1] & 0xF
            versions.append("%d.%d" % (major, minor))
    if count != 2 or "1.1" not in versions or "1.2" not in versions:
        _last_result = "FAIL: versions=%s" % ",".join(versions)
    else:
        _last_result = "PASS: count=%d versions=%s" % (count, ",".join(versions))

def test_spdm_get_capabilities():
    """Send GET_CAPABILITIES (SPDM 1.2)."""
    req = [0x12, 0xE1, 0x00, 0x00,
           0x00, 0x00, 0x00, 0x00,
           0x00, 0x00, 0x00, 0x00,
           0x00, 0x10, 0x00, 0x00,
           0x00, 0x00, 0x01, 0x00]
    send_spdm_request(req)

def check_spdm_get_capabilities():
    """Check CAPABILITIES response."""
    global _last_result
    resp = read_spdm_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if len(resp) < 12:
        _last_result = "FAIL: too short (%d): %s" % (len(resp), hex_str(resp))
        return
    if resp[1] != 0x61:
        _last_result = "FAIL: code=0x%02X expected 0x61" % resp[1]
        return
    flags = resp[8] | (resp[9] << 8) | (resp[10] << 16) | (resp[11] << 24)
    expected = 0x16  # CERT(0x02) | CHAL(0x04) | MEAS_SIG(0x10)
    if flags != expected:
        _last_result = "FAIL: flags=0x%08X expected 0x%08X" % (flags, expected)
    else:
        _last_result = "PASS: flags=0x%08X" % flags

def test_spdm_negotiate_algorithms():
    """Send NEGOTIATE_ALGORITHMS."""
    req = [0x12, 0xE3, 0x00, 0x00,
           0x24, 0x00, 0x01, 0x00,
           0x10, 0x00, 0x00, 0x00,
           0x01, 0x00, 0x00, 0x00,
           0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
           0x00, 0x00, 0x00, 0x00,
           0x00, 0x00, 0x00, 0x00,
           0x00, 0x00, 0x00, 0x00]
    send_spdm_request(req)

def check_spdm_negotiate_algorithms():
    """Check ALGORITHMS response."""
    global _last_result
    resp = read_spdm_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if len(resp) < 20:
        _last_result = "FAIL: too short (%d): %s" % (len(resp), hex_str(resp))
        return
    if resp[1] != 0x63:
        _last_result = "FAIL: code=0x%02X expected 0x63" % resp[1]
        return
    base_asym = resp[12] | (resp[13] << 8) | (resp[14] << 16) | (resp[15] << 24)
    base_hash = resp[16] | (resp[17] << 8) | (resp[18] << 16) | (resp[19] << 24)
    if base_asym != 0x10 or base_hash != 0x01:
        _last_result = "FAIL: asym=0x%08X hash=0x%08X" % (base_asym, base_hash)
    else:
        _last_result = "PASS: ECDSA-P256 + SHA-256"

def test_spdm_get_digests():
    """Send GET_DIGESTS."""
    send_spdm_request([0x12, 0x81, 0x00, 0x00])

def check_spdm_get_digests():
    """Check DIGESTS response."""
    global _last_result
    resp = read_spdm_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if resp[1] != 0x01:
        _last_result = "FAIL: code=0x%02X expected 0x01" % resp[1]
        return
    slot_mask = resp[3]
    if slot_mask != 0x01:
        _last_result = "FAIL: slot_mask=0x%02X expected 0x01" % slot_mask
    elif len(resp) < 36:
        _last_result = "FAIL: response too short for digest (%d bytes)" % len(resp)
    else:
        _last_result = "PASS: slot_mask=0x%02X digest=%s" % (slot_mask, hex_str(resp[4:36]))

def test_spdm_get_certificate():
    """Send GET_CERTIFICATE (offset=0, length=4096)."""
    send_spdm_request([0x12, 0x82, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10])

def check_spdm_get_certificate():
    """Check CERTIFICATE response."""
    global _last_result
    resp = read_spdm_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if resp[1] != 0x02:
        _last_result = "FAIL: code=0x%02X expected 0x02" % resp[1]
        return
    portion = resp[4] | (resp[5] << 8)
    remainder = resp[6] | (resp[7] << 8)
    total = portion + remainder
    if total == 0:
        _last_result = "FAIL: cert chain empty"
    else:
        _last_result = "PASS: portion=%d remainder=%d total=%d" % (portion, remainder, total)

def test_spdm_challenge():
    """Send CHALLENGE (slot 0, no measurement summary)."""
    # Deterministic nonce for reproducibility
    nonce = [i % 256 for i in range(32)]
    send_spdm_request([0x12, 0x83, 0x00, 0x00] + nonce)

def check_spdm_challenge():
    """Check CHALLENGE_AUTH response structure and signature."""
    global _last_result
    resp = read_spdm_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if len(resp) < 4:
        _last_result = "FAIL: too short (%d bytes)" % len(resp)
        return
    if resp[1] == 0x7F:
        _last_result = "FAIL: got ERROR response, code=0x%02X data=0x%02X" % (resp[2], resp[3])
        return
    if resp[1] != 0x03:
        _last_result = "FAIL: code=0x%02X expected 0x03 (CHALLENGE_AUTH)" % resp[1]
        return
    # meas_summary_type=0: 4B hdr + 32B cert_hash + 32B nonce + 2B opaque_len + 64B sig = 134
    expected_len = 134
    if len(resp) != expected_len:
        _last_result = "FAIL: length=%d expected %d" % (len(resp), expected_len)
        return
    slot_id = resp[2] & 0x0F
    slot_mask = resp[3]
    opaque_len = resp[68] | (resp[69] << 8)
    sig = resp[70:134]
    if slot_id != 0:
        _last_result = "FAIL: slot_id=%d expected 0" % slot_id
    elif slot_mask != 0x01:
        _last_result = "FAIL: slot_mask=0x%02X expected 0x01" % slot_mask
    elif opaque_len != 0:
        _last_result = "FAIL: opaque_len=%d expected 0" % opaque_len
    elif all(b == 0 for b in sig):
        _last_result = "FAIL: signature is all zeros"
    else:
        _last_result = "PASS: len=%d slot=%d sig_bytes=%s..." % (len(resp), slot_id, hex_str(sig[:4]))

def test_spdm_get_measurements_count():
    """Send GET_MEASUREMENTS (operation=0x00, no signature)."""
    send_spdm_request([0x12, 0xE0, 0x00, 0x00])

def check_spdm_get_measurements_count():
    """Check MEASUREMENTS response for count-only operation."""
    global _last_result
    resp = read_spdm_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if len(resp) < 4:
        _last_result = "FAIL: too short (%d bytes)" % len(resp)
        return
    if resp[1] == 0x7F:
        _last_result = "FAIL: got ERROR response, code=0x%02X data=0x%02X" % (resp[2], resp[3])
        return
    if resp[1] != 0x60:
        _last_result = "FAIL: code=0x%02X expected 0x60 (MEASUREMENTS)" % resp[1]
        return
    total_count = resp[3]  # param2 = total number of indices
    num_blocks = resp[4]
    record_len = resp[5] | (resp[6] << 8) | (resp[7] << 16)
    # operation=0x00: returns count in param2, no blocks, no record
    # Expected: 4B hdr + 1B num_blocks + 3B record_len + 2B opaque_len = 10 bytes
    if num_blocks != 0:
        _last_result = "FAIL: num_blocks=%d expected 0" % num_blocks
    elif record_len != 0:
        _last_result = "FAIL: record_len=%d expected 0" % record_len
    elif total_count != 2:
        _last_result = "FAIL: total_count=%d expected 2" % total_count
    else:
        _last_result = "PASS: total_count=%d num_blocks=%d" % (total_count, num_blocks)

def test_spdm_get_measurements_all_signed():
    """Send GET_MEASUREMENTS (operation=0xFF, all blocks, with signature)."""
    # attributes bit 0 = generate signature
    nonce = [(i + 0x40) % 256 for i in range(32)]
    send_spdm_request([0x12, 0xE0, 0x01, 0xFF] + nonce)

def check_spdm_get_measurements_all_signed():
    """Check MEASUREMENTS response with all blocks and ECDSA-P256 signature."""
    global _last_result
    resp = read_spdm_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if len(resp) < 4:
        _last_result = "FAIL: too short (%d bytes)" % len(resp)
        return
    if resp[1] == 0x7F:
        _last_result = "FAIL: got ERROR response, code=0x%02X data=0x%02X" % (resp[2], resp[3])
        return
    if resp[1] != 0x60:
        _last_result = "FAIL: code=0x%02X expected 0x60 (MEASUREMENTS)" % resp[1]
        return
    num_blocks = resp[4]
    record_len = resp[5] | (resp[6] << 8) | (resp[7] << 16)
    # 2 measurement blocks: each = 1B idx + 1B spec + 2B meas_size + 1B dmtf_type + 2B value_size + 32B value = 39 bytes
    # Total record = 78 bytes
    # Response: 4B hdr + 1B blocks + 3B record_len + 78B record + 32B nonce + 2B opaque_len + 64B sig = 184
    expected_record_len = 78
    expected_len = 184
    if num_blocks != 2:
        _last_result = "FAIL: num_blocks=%d expected 2" % num_blocks
        return
    if record_len != expected_record_len:
        _last_result = "FAIL: record_len=%d expected %d" % (record_len, expected_record_len)
        return
    if len(resp) != expected_len:
        _last_result = "FAIL: len=%d expected %d" % (len(resp), expected_len)
        return
    sig_start = expected_len - 64
    sig = resp[sig_start:expected_len]
    if all(b == 0 for b in sig):
        _last_result = "FAIL: signature is all zeros"
    else:
        _last_result = "PASS: blocks=%d record_len=%d len=%d sig_bytes=%s..." % (num_blocks, record_len, len(resp), hex_str(sig[:4]))

# --- Combined send+read functions for Robot Framework unit tests ---
# These send a request and immediately read the response in a single
# Python call.  Works because sysbus WriteByte -> UART -> device ->
# UART RX FIFO is synchronous within Renode's peripheral model.

# SPDM error codes
_ERROR_RESPONSE = 0x7F
_ERROR_UNEXPECTED_REQUEST = 0x03
_ERROR_UNSUPPORTED_REQUEST = 0x41

def spdm_send_and_read(spdm_bytes):
    """Send SPDM request, immediately read response. Returns response bytes or None."""
    send_spdm_request(spdm_bytes)
    return read_spdm_response()

def spdm_check_error(resp, expected_code):
    """Check if response is SPDM ERROR with expected error code. Returns result string."""
    if resp is None:
        return "FAIL: no response"
    if len(resp) < 4:
        return "FAIL: too short (%d bytes)" % len(resp)
    if resp[1] != _ERROR_RESPONSE:
        return "FAIL: expected ERROR (0x7F), got code=0x%02X" % resp[1]
    actual_code = resp[2]
    if actual_code != expected_code:
        return "FAIL: expected error 0x%02X, got 0x%02X" % (expected_code, actual_code)
    return "OK: ERROR response with code 0x%02X" % actual_code

def mctp_get_message_type_support():
    """Combined send+read for MCTP GetMessageTypeSupport."""
    send_mctp_control([0x80, 0x05])
    resp = read_mctp_control_response()
    if resp is None:
        return "FAIL: no response"
    if len(resp) < 4:
        return "FAIL: response too short: " + hex_str(resp)
    cc = resp[2]
    count = resp[3]
    types = [resp[4 + i] for i in range(count) if 4 + i < len(resp)]
    types_str = ",".join(["0x%02X" % t for t in types])
    if cc != 0:
        return "FAIL: cc=%d" % cc
    return "OK: count=%d types=%s" % (count, types_str)

def spdm_get_version():
    """Combined send+read for GET_VERSION."""
    resp = spdm_send_and_read([0x10, 0x84, 0x00, 0x00])
    if resp is None:
        return "FAIL: no response"
    if len(resp) < 6:
        return "FAIL: too short: " + hex_str(resp)
    if resp[1] != 0x04:
        return "FAIL: code=0x%02X expected 0x04" % resp[1]
    count = resp[5]
    versions = []
    for i in range(count):
        off = 6 + i * 2
        if off + 1 < len(resp):
            major = (resp[off + 1] >> 4) & 0xF
            minor = resp[off + 1] & 0xF
            versions.append("%d.%d" % (major, minor))
    return "OK: version_count=%d versions=%s" % (count, ",".join(versions))

def spdm_get_capabilities():
    """Combined send+read for GET_CAPABILITIES (SPDM 1.2)."""
    req = [0x12, 0xE1, 0x00, 0x00,
           0x00, 0x00, 0x00, 0x00,
           0x00, 0x00, 0x00, 0x00,
           0x00, 0x10, 0x00, 0x00,
           0x00, 0x00, 0x01, 0x00]
    resp = spdm_send_and_read(req)
    if resp is None:
        return "FAIL: no response"
    if resp[1] == _ERROR_RESPONSE:
        return "FAIL: got ERROR code=0x%02X" % resp[2]
    if resp[1] != 0x61:
        return "FAIL: code=0x%02X expected 0x61" % resp[1]
    return "OK: capabilities_received"

def spdm_negotiate_algorithms():
    """Combined send+read for NEGOTIATE_ALGORITHMS."""
    req = [0x12, 0xE3, 0x00, 0x00,
           0x24, 0x00, 0x01, 0x00,
           0x10, 0x00, 0x00, 0x00,
           0x01, 0x00, 0x00, 0x00,
           0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
           0x00, 0x00, 0x00, 0x00,
           0x00, 0x00, 0x00, 0x00,
           0x00, 0x00, 0x00, 0x00]
    resp = spdm_send_and_read(req)
    if resp is None:
        return "FAIL: no response"
    if resp[1] == _ERROR_RESPONSE:
        return "FAIL: got ERROR code=0x%02X" % resp[2]
    if len(resp) < 20:
        return "FAIL: too short (%d): %s" % (len(resp), hex_str(resp))
    if resp[1] != 0x63:
        return "FAIL: code=0x%02X expected 0x63" % resp[1]
    base_asym = resp[12] | (resp[13] << 8) | (resp[14] << 16) | (resp[15] << 24)
    base_hash = resp[16] | (resp[17] << 8) | (resp[18] << 16) | (resp[19] << 24)
    return "OK negotiation_complete: base_asym=0x%08X base_hash=0x%08X" % (base_asym, base_hash)

def run_full_negotiation():
    """Run GET_VERSION + GET_CAPABILITIES + NEGOTIATE_ALGORITHMS."""
    r = spdm_get_version()
    if not r.startswith("OK"):
        return "FAIL at GET_VERSION: " + r
    r = spdm_get_capabilities()
    if not r.startswith("OK"):
        return "FAIL at GET_CAPABILITIES: " + r
    return spdm_negotiate_algorithms()

def spdm_get_digests():
    """Combined send+read for GET_DIGESTS."""
    resp = spdm_send_and_read([0x12, 0x81, 0x00, 0x00])
    if resp is None:
        return "FAIL: no response"
    if resp[1] == _ERROR_RESPONSE:
        return "FAIL: got ERROR code=0x%02X" % resp[2]
    if resp[1] != 0x01:
        return "FAIL: code=0x%02X expected 0x01" % resp[1]
    slot_mask = resp[3]
    if len(resp) < 36:
        return "FAIL: too short for digest (%d bytes)" % len(resp)
    return "OK: slot_mask=0x%02X digest=%s" % (slot_mask, hex_str(resp[4:36]))

def spdm_get_certificate():
    """Combined send+read for GET_CERTIFICATE (offset=0, length=4096)."""
    resp = spdm_send_and_read([0x12, 0x82, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10])
    if resp is None:
        return "FAIL: no response"
    if resp[1] == _ERROR_RESPONSE:
        return "FAIL: got ERROR code=0x%02X" % resp[2]
    if resp[1] != 0x02:
        return "FAIL: code=0x%02X expected 0x02" % resp[1]
    portion = resp[4] | (resp[5] << 8)
    remainder = resp[6] | (resp[7] << 8)
    return "OK: portion_length=%d remainder=%d total=%d" % (portion, remainder, portion + remainder)

# --- Out-of-order / error test helpers ---
# Use the split pattern: call test_*(), emulation RunFor, then check_*()

def check_spdm_error_response(expected_code):
    """Read SPDM response and verify it is ERROR with the expected error code.

    Uses _last_result so Robot Framework can print and assert.
    Call: python "check_spdm_error_response(0x03); print(_last_result)"
    """
    global _last_result
    resp = read_spdm_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if len(resp) < 4:
        _last_result = "FAIL: too short (%d bytes): %s" % (len(resp), hex_str(resp))
        return
    if resp[1] != 0x7F:
        _last_result = "FAIL: expected ERROR (0x7F), got code=0x%02X" % resp[1]
        return
    actual_code = resp[2]
    if actual_code != expected_code:
        _last_result = "FAIL: expected error 0x%02X, got 0x%02X" % (expected_code, actual_code)
        return
    _last_result = "PASS: ERROR response with code 0x%02X" % actual_code

def test_spdm_unsupported_request():
    """Send unknown SPDM request code 0xAA."""
    send_spdm_request([0x12, 0xAA, 0x00, 0x00])

# --- Malformed message test helpers ---
# HandleSpdmPacket silently drops SPDM payloads < 4 bytes (no response).
# Per-handler length checks return ErrorInvalidRequest (0x01).

def check_no_spdm_response():
    """Verify that no SPDM response was received (RX FIFO empty).

    Used for payloads too short to even reach HandleRequest.
    """
    global _last_result
    resp = read_spdm_response()
    if resp is None:
        _last_result = "PASS: no response (as expected)"
    else:
        _last_result = "FAIL: unexpected response: %s" % hex_str(resp)

def test_spdm_empty_payload():
    """Send SPDM MCTP packet with 0-byte SPDM payload."""
    send_spdm_request([])

def test_spdm_short_payload_3():
    """Send SPDM packet with 3-byte payload (one short of 4-byte minimum)."""
    send_spdm_request([0x10, 0x84, 0x00])

def test_spdm_short_certificate_4():
    """Send GET_CERTIFICATE with only 4-byte header (need 8: header + offset + length)."""
    send_spdm_request([0x12, 0x82, 0x00, 0x00])

def test_spdm_short_certificate_7():
    """Send GET_CERTIFICATE with 7 bytes (one short of 8-byte minimum)."""
    send_spdm_request([0x12, 0x82, 0x00, 0x00, 0x00, 0x00, 0x00])

def test_spdm_short_challenge_4():
    """Send CHALLENGE with only 4-byte header (need 36: header + 32-byte nonce)."""
    send_spdm_request([0x12, 0x83, 0x00, 0x00])

def test_spdm_short_challenge_35():
    """Send CHALLENGE with 35 bytes (one short of 36-byte minimum)."""
    send_spdm_request([0x12, 0x83, 0x00, 0x00] + [0x42] * 31)

# --- MCTP control command test helpers ---

def test_mctp_set_eid():
    """Send MCTP Set Endpoint ID (cmd=0x01) assigning EID 0x30."""
    # [rqFlags=0x80, cmd=0x01, operation=0x00(set), eid=0x30]
    send_mctp_control([0x80, 0x01, 0x00, 0x30])

def check_mctp_set_eid():
    """Check Set Endpoint ID response — should return success with assigned EID."""
    global _last_result
    resp = read_mctp_control_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if len(resp) < 5:
        _last_result = "FAIL: too short (%d bytes): %s" % (len(resp), hex_str(resp))
        return
    cmd = resp[1]
    cc = resp[2]
    eid = resp[4]
    if cmd != 0x01:
        _last_result = "FAIL: cmd=0x%02X expected 0x01" % cmd
    elif cc != 0x00:
        _last_result = "FAIL: cc=0x%02X expected 0x00" % cc
    elif eid != 0x30:
        _last_result = "FAIL: eid=0x%02X expected 0x30" % eid
    else:
        _last_result = "PASS: SET_EID success, eid=0x%02X" % eid

def test_mctp_get_eid():
    """Send MCTP Get Endpoint ID (cmd=0x02)."""
    send_mctp_control([0x80, 0x02])

def check_mctp_get_eid():
    """Check Get Endpoint ID response — EID should match scenario config (0x14)."""
    global _last_result
    resp = read_mctp_control_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if len(resp) < 4:
        _last_result = "FAIL: too short (%d bytes): %s" % (len(resp), hex_str(resp))
        return
    cmd = resp[1]
    cc = resp[2]
    eid = resp[3]
    if cmd != 0x02:
        _last_result = "FAIL: cmd=0x%02X expected 0x02" % cmd
    elif cc != 0x00:
        _last_result = "FAIL: cc=0x%02X expected 0x00" % cc
    else:
        _last_result = "PASS: GET_EID eid=0x%02X" % eid

def test_mctp_get_uuid():
    """Send MCTP Get Endpoint UUID (cmd=0x03)."""
    send_mctp_control([0x80, 0x03])

def check_mctp_get_uuid():
    """Check Get Endpoint UUID response — should return 16-byte UUID."""
    global _last_result
    resp = read_mctp_control_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if len(resp) < 19:  # respFlags + cmd + cc + 16 UUID bytes
        _last_result = "FAIL: too short (%d bytes): %s" % (len(resp), hex_str(resp))
        return
    cmd = resp[1]
    cc = resp[2]
    uuid = resp[3:19]
    if cmd != 0x03:
        _last_result = "FAIL: cmd=0x%02X expected 0x03" % cmd
    elif cc != 0x00:
        _last_result = "FAIL: cc=0x%02X expected 0x00" % cc
    elif all(b == 0 for b in uuid):
        _last_result = "FAIL: UUID is all zeros"
    else:
        _last_result = "PASS: UUID=%s" % hex_str(uuid)

def test_mctp_unknown_command():
    """Send unknown MCTP control command 0xFE."""
    send_mctp_control([0x80, 0xFE])

def check_mctp_unknown_command():
    """Check unknown command response — should return error cc=0x05."""
    global _last_result
    resp = read_mctp_control_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if len(resp) < 3:
        _last_result = "FAIL: too short (%d bytes): %s" % (len(resp), hex_str(resp))
        return
    cmd = resp[1]
    cc = resp[2]
    if cmd != 0xFE:
        _last_result = "FAIL: cmd=0x%02X expected 0xFE" % cmd
    elif cc != 0x05:
        _last_result = "FAIL: cc=0x%02X expected 0x05 (unsupported)" % cc
    else:
        _last_result = "PASS: unknown cmd error cc=0x%02X" % cc

def test_mctp_non_request():
    """Send MCTP control message with Rq bit cleared (not a request)."""
    # rqFlags=0x00 (bit 7 = 0 = response, not request)
    send_mctp_control([0x00, 0x05])

def test_mctp_short_control():
    """Send MCTP control message with only 1 byte (under 2-byte minimum)."""
    send_mctp_control([0x80])

def check_no_mctp_control_response():
    """Verify no MCTP control response was received."""
    global _last_result
    resp = read_mctp_control_response()
    if resp is None:
        _last_result = "PASS: no response (as expected)"
    else:
        _last_result = "FAIL: unexpected response: %s" % hex_str(resp)

# --- GET_CERTIFICATE edge case test helpers ---

def test_spdm_get_certificate_offset():
    """Send GET_CERTIFICATE with offset=100, length=4096."""
    # [ver, code, slot=0, reserved, offset_lo, offset_hi, length_lo, length_hi]
    send_spdm_request([0x12, 0x82, 0x00, 0x00, 0x64, 0x00, 0x00, 0x10])

def check_spdm_get_certificate_offset():
    """Check CERTIFICATE response with non-zero offset — portion+remainder should cover the rest."""
    global _last_result
    resp = read_spdm_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if len(resp) < 8:
        _last_result = "FAIL: too short (%d bytes)" % len(resp)
        return
    if resp[1] == 0x7F:
        _last_result = "FAIL: got ERROR code=0x%02X" % resp[2]
        return
    if resp[1] != 0x02:
        _last_result = "FAIL: code=0x%02X expected 0x02" % resp[1]
        return
    portion = resp[4] | (resp[5] << 8)
    remainder = resp[6] | (resp[7] << 8)
    if portion == 0:
        _last_result = "FAIL: portion=0 (expected data from offset 100)"
    elif remainder < 0:
        _last_result = "FAIL: invalid remainder=%d" % remainder
    else:
        _last_result = "PASS: offset=100 portion=%d remainder=%d" % (portion, remainder)

def test_spdm_get_certificate_beyond():
    """Send GET_CERTIFICATE with offset=65535 (beyond cert chain)."""
    send_spdm_request([0x12, 0x82, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x10])

def check_spdm_get_certificate_beyond():
    """Check CERTIFICATE response with offset beyond chain — portion=0, remainder=0."""
    global _last_result
    resp = read_spdm_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if len(resp) < 8:
        _last_result = "FAIL: too short (%d bytes)" % len(resp)
        return
    if resp[1] == 0x7F:
        _last_result = "FAIL: got ERROR code=0x%02X" % resp[2]
        return
    if resp[1] != 0x02:
        _last_result = "FAIL: code=0x%02X expected 0x02" % resp[1]
        return
    portion = resp[4] | (resp[5] << 8)
    remainder = resp[6] | (resp[7] << 8)
    if portion != 0:
        _last_result = "FAIL: portion=%d expected 0" % portion
    elif remainder != 0:
        _last_result = "FAIL: remainder=%d expected 0" % remainder
    else:
        _last_result = "PASS: beyond offset portion=0 remainder=0"

def test_spdm_get_certificate_slot1():
    """Send GET_CERTIFICATE requesting slot 1."""
    send_spdm_request([0x12, 0x82, 0x01, 0x00, 0x00, 0x00, 0x00, 0x10])

def check_spdm_get_certificate_slot1():
    """Check CERTIFICATE response echoes slot_id=1 in param1."""
    global _last_result
    resp = read_spdm_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if len(resp) < 8:
        _last_result = "FAIL: too short (%d bytes)" % len(resp)
        return
    if resp[1] == 0x7F:
        _last_result = "FAIL: got ERROR code=0x%02X" % resp[2]
        return
    if resp[1] != 0x02:
        _last_result = "FAIL: code=0x%02X expected 0x02" % resp[1]
        return
    slot_id = resp[2]
    if slot_id != 0x01:
        _last_result = "FAIL: slot_id=0x%02X expected 0x01" % slot_id
    else:
        portion = resp[4] | (resp[5] << 8)
        _last_result = "PASS: slot_id=0x%02X portion=%d" % (slot_id, portion)

# --- GET_MEASUREMENTS variation test helpers ---

def test_spdm_get_measurements_index1():
    """Send GET_MEASUREMENTS for specific index 1 (no signature)."""
    send_spdm_request([0x12, 0xE0, 0x00, 0x01])

def check_spdm_get_measurements_index1():
    """Check MEASUREMENTS response for single index — should have 1 block."""
    global _last_result
    resp = read_spdm_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if len(resp) < 8:
        _last_result = "FAIL: too short (%d bytes)" % len(resp)
        return
    if resp[1] == 0x7F:
        _last_result = "FAIL: got ERROR code=0x%02X data=0x%02X" % (resp[2], resp[3])
        return
    if resp[1] != 0x60:
        _last_result = "FAIL: code=0x%02X expected 0x60" % resp[1]
        return
    num_blocks = resp[4]
    record_len = resp[5] | (resp[6] << 8) | (resp[7] << 16)
    if num_blocks != 1:
        _last_result = "FAIL: num_blocks=%d expected 1" % num_blocks
    elif record_len == 0:
        _last_result = "FAIL: record_len=0 (expected measurement data)"
    else:
        _last_result = "PASS: index=1 num_blocks=%d record_len=%d" % (num_blocks, record_len)

def test_spdm_get_measurements_invalid_index():
    """Send GET_MEASUREMENTS for index 99 (not in config)."""
    send_spdm_request([0x12, 0xE0, 0x00, 0x63])

def check_spdm_get_measurements_invalid_index():
    """Check MEASUREMENTS response for invalid index — 0 blocks, 0 record length."""
    global _last_result
    resp = read_spdm_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if len(resp) < 8:
        _last_result = "FAIL: too short (%d bytes)" % len(resp)
        return
    if resp[1] == 0x7F:
        _last_result = "FAIL: got ERROR code=0x%02X data=0x%02X" % (resp[2], resp[3])
        return
    if resp[1] != 0x60:
        _last_result = "FAIL: code=0x%02X expected 0x60" % resp[1]
        return
    num_blocks = resp[4]
    record_len = resp[5] | (resp[6] << 8) | (resp[7] << 16)
    if num_blocks != 0:
        _last_result = "FAIL: num_blocks=%d expected 0" % num_blocks
    elif record_len != 0:
        _last_result = "FAIL: record_len=%d expected 0" % record_len
    else:
        _last_result = "PASS: invalid_index num_blocks=0 record_len=0"

def test_spdm_get_measurements_all_unsigned():
    """Send GET_MEASUREMENTS for all blocks, no signature (attributes=0x00)."""
    send_spdm_request([0x12, 0xE0, 0x00, 0xFF])

def check_spdm_get_measurements_all_unsigned():
    """Check MEASUREMENTS response with all blocks, unsigned — 2 blocks, no signature."""
    global _last_result
    resp = read_spdm_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if len(resp) < 8:
        _last_result = "FAIL: too short (%d bytes)" % len(resp)
        return
    if resp[1] == 0x7F:
        _last_result = "FAIL: got ERROR code=0x%02X data=0x%02X" % (resp[2], resp[3])
        return
    if resp[1] != 0x60:
        _last_result = "FAIL: code=0x%02X expected 0x60" % resp[1]
        return
    num_blocks = resp[4]
    record_len = resp[5] | (resp[6] << 8) | (resp[7] << 16)
    # 2 blocks, each 39 bytes = 78 total. Response: 4 + 1 + 3 + 78 + 2(opaque) = 88 bytes (no nonce, no sig)
    expected_record_len = 78
    expected_len = 88
    if num_blocks != 2:
        _last_result = "FAIL: num_blocks=%d expected 2" % num_blocks
    elif record_len != expected_record_len:
        _last_result = "FAIL: record_len=%d expected %d" % (record_len, expected_record_len)
    elif len(resp) != expected_len:
        _last_result = "FAIL: len=%d expected %d (unsigned)" % (len(resp), expected_len)
    else:
        _last_result = "PASS: unsigned all blocks=%d record_len=%d len=%d" % (num_blocks, record_len, len(resp))

# --- SPDM 1.1 version-specific test helpers ---

def check_spdm_get_version_v11():
    """Check VERSION response for v1.1-only device — exactly 1 entry (1.1)."""
    global _last_result
    resp = read_spdm_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if len(resp) < 6:
        _last_result = "FAIL: too short: " + hex_str(resp)
        return
    if resp[1] != 0x04:
        _last_result = "FAIL: code=0x%02X expected 0x04" % resp[1]
        return
    count = resp[5]
    versions = []
    for i in range(count):
        off = 6 + i * 2
        if off + 1 < len(resp):
            major = (resp[off + 1] >> 4) & 0xF
            minor = resp[off + 1] & 0xF
            versions.append("%d.%d" % (major, minor))
    if count != 1:
        _last_result = "FAIL: count=%d expected 1" % count
    elif "1.1" not in versions:
        _last_result = "FAIL: versions=%s (expected 1.1)" % ",".join(versions)
    else:
        _last_result = "PASS: count=%d versions=%s" % (count, ",".join(versions))

def test_spdm_get_capabilities_v11():
    """Send GET_CAPABILITIES for SPDM 1.1 (12-byte request)."""
    req = [0x11, 0xE1, 0x00, 0x00,
           0x00, 0x00, 0x00, 0x00,
           0x00, 0x10, 0x00, 0x00]
    send_spdm_request(req)

def check_spdm_get_capabilities_v11():
    """Check CAPABILITIES response for SPDM 1.1 — 12 bytes, no data_transfer_size."""
    global _last_result
    resp = read_spdm_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if resp[1] == 0x7F:
        _last_result = "FAIL: got ERROR code=0x%02X" % resp[2]
        return
    if resp[1] != 0x61:
        _last_result = "FAIL: code=0x%02X expected 0x61" % resp[1]
        return
    if len(resp) != 12:
        _last_result = "FAIL: len=%d expected 12 (v1.1 format)" % len(resp)
        return
    # Check version byte is 0x11
    if resp[0] != 0x11:
        _last_result = "FAIL: version=0x%02X expected 0x11" % resp[0]
        return
    flags = resp[8] | (resp[9] << 8) | (resp[10] << 16) | (resp[11] << 24)
    expected = 0x16  # CERT(0x02) | CHAL(0x04) | MEAS_SIG(0x10)
    if flags != expected:
        _last_result = "FAIL: flags=0x%08X expected 0x%08X" % (flags, expected)
    else:
        _last_result = "PASS: v1.1 caps len=%d version=0x%02X flags=0x%08X" % (len(resp), resp[0], flags)

# --- CHALLENGE with measurement summary test helpers ---

def test_spdm_challenge_tcb_summary():
    """Send CHALLENGE with meas_summary_type=0x01 (TCB measurements only)."""
    nonce = [i % 256 for i in range(32)]
    send_spdm_request([0x12, 0x83, 0x00, 0x01] + nonce)

def test_spdm_challenge_all_summary():
    """Send CHALLENGE with meas_summary_type=0xFF (all measurements)."""
    nonce = [i % 256 for i in range(32)]
    send_spdm_request([0x12, 0x83, 0x00, 0xFF] + nonce)

def check_spdm_challenge_with_summary():
    """Check CHALLENGE_AUTH response with measurement summary hash (166 bytes).

    With meas_summary_type != 0, response includes 32B measurement summary hash:
    4B hdr + 32B cert_hash + 32B nonce + 32B meas_summary + 2B opaque_len + 64B sig = 166
    """
    global _last_result
    resp = read_spdm_response()
    if resp is None:
        _last_result = "FAIL: no response"
        return
    if len(resp) < 4:
        _last_result = "FAIL: too short (%d bytes)" % len(resp)
        return
    if resp[1] == 0x7F:
        _last_result = "FAIL: got ERROR response, code=0x%02X data=0x%02X" % (resp[2], resp[3])
        return
    if resp[1] != 0x03:
        _last_result = "FAIL: code=0x%02X expected 0x03 (CHALLENGE_AUTH)" % resp[1]
        return
    expected_len = 166  # 134 + 32 (meas_summary_hash)
    if len(resp) != expected_len:
        _last_result = "FAIL: length=%d expected %d" % (len(resp), expected_len)
        return
    # Measurement summary hash at offset 68 (4+32+32), 32 bytes
    meas_summary = resp[68:100]
    if all(b == 0 for b in meas_summary):
        _last_result = "FAIL: measurement summary hash is all zeros"
        return
    # Signature at end (166-64=102)
    sig = resp[102:166]
    if all(b == 0 for b in sig):
        _last_result = "FAIL: signature is all zeros"
        return
    _last_result = "PASS: len=%d meas_summary=%s... sig=%s..." % (len(resp), hex_str(meas_summary[:4]), hex_str(sig[:4]))
