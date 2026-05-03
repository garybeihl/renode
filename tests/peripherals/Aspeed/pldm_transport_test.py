"""
PldmFirmwareDevice transport layer test.
Run from Renode monitor:
  include @tests/peripherals/Aspeed/pldm_transport_test.py
"""

UART_BASE = 0x1e783000

def crc_ccitt_byte(crc, b):
    crc ^= b
    for _ in range(8):
        if crc & 1:
            crc = (crc >> 1) ^ 0x8408
        else:
            crc >>= 1
    return crc & 0xFFFF

def crc_ccitt(data):
    crc = 0xFFFF
    for b in data:
        crc = crc_ccitt_byte(crc, b)
    return crc

def send_mctp_serial_frame(sysbus, data):
    """Send an MCTP serial frame (with CRC and byte stuffing) to the UART."""
    version = 0x01
    length = len(data)

    # Compute FCS
    fcs = crc_ccitt_byte(0xFFFF, version)
    fcs = crc_ccitt_byte(fcs, length)
    for b in data:
        fcs = crc_ccitt_byte(fcs, b)

    # Send frame
    sysbus.WriteByte(UART_BASE, 0x7E)  # flag
    sysbus.WriteByte(UART_BASE, version)
    sysbus.WriteByte(UART_BASE, length)

    # Data with byte stuffing
    for b in data:
        if b in (0x7E, 0x7D):
            sysbus.WriteByte(UART_BASE, 0x7D)
            sysbus.WriteByte(UART_BASE, b & ~0x20)
        else:
            sysbus.WriteByte(UART_BASE, b)

    # FCS (high byte first) + trailing flag
    sysbus.WriteByte(UART_BASE, (fcs >> 8) & 0xFF)
    sysbus.WriteByte(UART_BASE, fcs & 0xFF)
    sysbus.WriteByte(UART_BASE, 0x7E)

def read_response_bytes(sysbus, max_bytes=256):
    """Read available bytes from the UART RX buffer."""
    result = []
    for _ in range(max_bytes):
        try:
            b = sysbus.ReadByte(UART_BASE)
            result.append(b)
        except:
            break
    return result

def parse_mctp_serial_frame(raw_bytes):
    """Parse an MCTP serial frame from raw bytes. Returns the MCTP packet data or None."""
    if len(raw_bytes) < 7:  # minimum: flag + ver + len + 1 data + fcs_hi + fcs_lo + flag
        return None

    # Find frame start
    idx = 0
    while idx < len(raw_bytes) and raw_bytes[idx] != 0x7E:
        idx += 1
    if idx >= len(raw_bytes):
        return None
    idx += 1  # skip flag

    # Skip consecutive flags
    while idx < len(raw_bytes) and raw_bytes[idx] == 0x7E:
        idx += 1

    if idx + 2 >= len(raw_bytes):
        return None

    version = raw_bytes[idx]; idx += 1
    length = raw_bytes[idx]; idx += 1

    # Read data (un-escape)
    data = []
    escape = False
    while len(data) < length and idx < len(raw_bytes):
        b = raw_bytes[idx]; idx += 1
        if escape:
            data.append(b | 0x20)
            escape = False
        elif b == 0x7D:
            escape = True
        elif b == 0x7E:
            break  # unexpected flag
        else:
            data.append(b)

    if len(data) != length:
        return None

    # Read FCS
    if idx + 1 >= len(raw_bytes):
        return None
    fcs_hi = raw_bytes[idx]; idx += 1
    fcs_lo = raw_bytes[idx]; idx += 1
    received_fcs = (fcs_hi << 8) | fcs_lo

    # Verify FCS
    computed_fcs = crc_ccitt_byte(0xFFFF, version)
    computed_fcs = crc_ccitt_byte(computed_fcs, length)
    for b in data:
        computed_fcs = crc_ccitt_byte(computed_fcs, b)

    if received_fcs != computed_fcs:
        print("[TEST] FCS mismatch: received 0x%04X, computed 0x%04X" % (received_fcs, computed_fcs))
        return None

    return data

def build_mctp_packet(dest_eid, src_eid, flags_tag, msg_type, payload):
    """Build an MCTP packet (transport header + message body)."""
    return [0x01, dest_eid, src_eid, flags_tag, msg_type] + payload

def test_crc():
    """Test CRC computation against known values."""
    # Test with empty (just version + length)
    crc = crc_ccitt_byte(0xFFFF, 0x01)
    crc = crc_ccitt_byte(crc, 0x01)
    crc = crc_ccitt_byte(crc, 0xAA)
    print("[TEST] CRC test: 0x%04X" % crc)

    # Test roundtrip: build a frame, parse it back
    test_data = [0x01, 0x00, 0x08, 0xC8, 0x00, 0x80, 0x01]
    version = 0x01
    length = len(test_data)
    fcs = crc_ccitt_byte(0xFFFF, version)
    fcs = crc_ccitt_byte(fcs, length)
    for b in test_data:
        fcs = crc_ccitt_byte(fcs, b)

    # Build raw frame bytes
    raw = [0x7E, version, length]
    for b in test_data:
        if b in (0x7E, 0x7D):
            raw.append(0x7D)
            raw.append(b & ~0x20)
        else:
            raw.append(b)
    raw.append((fcs >> 8) & 0xFF)
    raw.append(fcs & 0xFF)
    raw.append(0x7E)

    parsed = parse_mctp_serial_frame(raw)
    if parsed == test_data:
        print("[TEST] CRC roundtrip: PASS")
    else:
        print("[TEST] CRC roundtrip: FAIL (got %s, expected %s)" % (parsed, test_data))

def test_mctp_set_eid(sysbus):
    """Test MCTP SetEID command."""
    print("[TEST] === MCTP SetEID ===")

    # Build SetEID request:
    # MCTP header: ver=0x01, dest=0x00(null), src=0x08(BMC), flags=0xC8(SOM+EOM+TO,tag=0)
    # MCTP control: msg_type=0x00, rq_flags=0x80(Rq), cmd=0x01(SetEID), op=0x00, eid=0x14(20)
    payload = [0x80, 0x01, 0x00, 0x14]  # MCTP control: rq|instance, cmd, operation, eid
    pkt = build_mctp_packet(0x00, 0x08, 0xC8, 0x00, payload)
    send_mctp_serial_frame(sysbus, pkt)

    # Read response
    resp_raw = read_response_bytes(sysbus)
    print("[TEST] Response raw bytes (%d): %s" % (len(resp_raw), ["0x%02X" % b for b in resp_raw]))

    resp_data = parse_mctp_serial_frame(resp_raw)
    if resp_data is None:
        print("[TEST] SetEID: FAIL (no valid response frame)")
        return False

    print("[TEST] Response MCTP packet (%d): %s" % (len(resp_data), ["0x%02X" % b for b in resp_data]))

    # Expected response:
    # MCTP header: ver=0x01, dest=0x08, src=0x14(our EID), flags=0xC0(SOM+EOM, tag=0, no TO)
    # MCTP control: msg_type=0x00, instance, cmd=0x01, cc=0x00, eid_assignment=0x00, eid=0x14, pool=0x00
    if len(resp_data) >= 11:  # 5 header + 6 control response
        msg_type = resp_data[4] & 0x7F
        cmd = resp_data[6]
        cc = resp_data[7]
        eid = resp_data[9]
        if msg_type == 0x00 and cmd == 0x01 and cc == 0x00 and eid == 0x14:
            print("[TEST] SetEID: PASS (EID=%d)" % eid)
            return True
        else:
            print("[TEST] SetEID: FAIL (msg_type=0x%02X, cmd=0x%02X, cc=0x%02X, eid=0x%02X)" %
                  (msg_type, cmd, cc, eid))
    else:
        print("[TEST] SetEID: FAIL (response too short: %d bytes)" % len(resp_data))
    return False

def test_mctp_get_eid(sysbus):
    """Test MCTP GetEID command."""
    print("[TEST] === MCTP GetEID ===")

    payload = [0x81, 0x02]  # rq_flags=0x80|instance=1, cmd=0x02(GetEID)
    pkt = build_mctp_packet(0x14, 0x08, 0xC9, 0x00, payload)  # tag=1
    send_mctp_serial_frame(sysbus, pkt)

    resp_raw = read_response_bytes(sysbus)
    resp_data = parse_mctp_serial_frame(resp_raw)
    if resp_data is None:
        print("[TEST] GetEID: FAIL (no valid response)")
        return False

    print("[TEST] Response: %s" % ["0x%02X" % b for b in resp_data])

    if len(resp_data) >= 11:
        msg_type = resp_data[4] & 0x7F
        cmd = resp_data[6]
        cc = resp_data[7]
        eid = resp_data[8]
        if msg_type == 0x00 and cmd == 0x02 and cc == 0x00 and eid == 0x14:
            print("[TEST] GetEID: PASS (EID=%d)" % eid)
            return True
        else:
            print("[TEST] GetEID: FAIL (msg_type=0x%02X, cmd=0x%02X, cc=0x%02X, eid=0x%02X)" %
                  (msg_type, cmd, cc, eid))
    else:
        print("[TEST] GetEID: FAIL (response too short)")
    return False

def test_pldm_get_tid(sysbus):
    """Test PLDM GetTID command."""
    print("[TEST] === PLDM GetTID ===")

    # PLDM header: instance=0, request=1, type=BASE(0), cmd=GetTID(2)
    # Byte 0: (0 << 3) | 0x01 = 0x01
    # Byte 1: 0x00 (PLDM_BASE)
    # Byte 2: 0x02 (PLDM_GET_TID)
    pldm_payload = [0x01, 0x00, 0x02]  # PLDM header only, no payload for GetTID
    pkt = build_mctp_packet(0x14, 0x08, 0xCA, 0x01, pldm_payload)  # msg_type=PLDM(0x01), tag=2
    send_mctp_serial_frame(sysbus, pkt)

    resp_raw = read_response_bytes(sysbus)
    resp_data = parse_mctp_serial_frame(resp_raw)
    if resp_data is None:
        print("[TEST] GetTID: FAIL (no valid response)")
        return False

    print("[TEST] Response: %s" % ["0x%02X" % b for b in resp_data])

    # Expected: MCTP header(4) + msg_type(1) + PLDM response(5)
    # PLDM response: hdr_byte0(instance, rq=0), type=0x00, cmd=0x02, cc=0x00, tid=0x01
    if len(resp_data) >= 10:
        msg_type = resp_data[4] & 0x7F
        pldm_rq = resp_data[5] & 0x01
        pldm_type = resp_data[6] & 0x3F
        pldm_cmd = resp_data[7]
        cc = resp_data[8]
        tid = resp_data[9]
        if msg_type == 0x01 and pldm_rq == 0 and pldm_type == 0x00 and pldm_cmd == 0x02 and cc == 0x00 and tid == 0x01:
            print("[TEST] GetTID: PASS (TID=%d)" % tid)
            return True
        else:
            print("[TEST] GetTID: FAIL (type=0x%02X, rq=%d, pldm_type=%d, cmd=0x%02X, cc=%d, tid=%d)" %
                  (msg_type, pldm_rq, pldm_type, pldm_cmd, cc, tid))
    else:
        print("[TEST] GetTID: FAIL (response too short: %d bytes)" % len(resp_data))
    return False

def test_pldm_get_types(sysbus):
    """Test PLDM GetPLDMTypes command."""
    print("[TEST] === PLDM GetPLDMTypes ===")

    # PLDM header: instance=1, request=1, type=BASE(0), cmd=GetTypes(4)
    pldm_payload = [0x09, 0x00, 0x04]  # (1<<3)|0x01, BASE, GetTypes
    pkt = build_mctp_packet(0x14, 0x08, 0xCB, 0x01, pldm_payload)  # tag=3
    send_mctp_serial_frame(sysbus, pkt)

    resp_raw = read_response_bytes(sysbus)
    resp_data = parse_mctp_serial_frame(resp_raw)
    if resp_data is None:
        print("[TEST] GetTypes: FAIL (no valid response)")
        return False

    print("[TEST] Response: %s" % ["0x%02X" % b for b in resp_data])

    # Expected: MCTP header(4) + msg_type(1) + PLDM response header(3) + CC(1) + types(8) = 17
    if len(resp_data) >= 14:
        cc = resp_data[8]
        types_byte0 = resp_data[9]
        # Should have BASE(0) + FWUP(5) = bit 0 + bit 5 = 0x21
        if cc == 0x00 and (types_byte0 & 0x21) == 0x21:
            print("[TEST] GetTypes: PASS (types_byte0=0x%02X, has BASE+FWUP)" % types_byte0)
            return True
        else:
            print("[TEST] GetTypes: FAIL (cc=%d, types=0x%02X)" % (cc, types_byte0))
    else:
        print("[TEST] GetTypes: FAIL (response too short: %d)" % len(resp_data))
    return False

def test_pldm_query_device_identifiers(sysbus):
    """Test PLDM QueryDeviceIdentifiers command."""
    print("[TEST] === PLDM QueryDeviceIdentifiers ===")

    # PLDM header: instance=2, request=1, type=FWUP(5), cmd=QDI(1)
    pldm_payload = [0x11, 0x05, 0x01]  # (2<<3)|0x01, FWUP, QDI
    pkt = build_mctp_packet(0x14, 0x08, 0xCC, 0x01, pldm_payload)  # tag=4
    send_mctp_serial_frame(sysbus, pkt)

    resp_raw = read_response_bytes(sysbus)
    resp_data = parse_mctp_serial_frame(resp_raw)
    if resp_data is None:
        print("[TEST] QDI: FAIL (no valid response)")
        return False

    print("[TEST] Response: %s" % ["0x%02X" % b for b in resp_data])

    # Expected: header(5) + PLDM hdr(3) + CC(1) + dev_id_len(4) + desc_count(1) +
    #           desc_type(2) + desc_len(2) + UUID(16) = 34 bytes
    if len(resp_data) >= 34:
        cc = resp_data[8]
        desc_count = resp_data[13]
        desc_type = resp_data[14] | (resp_data[15] << 8)
        desc_len = resp_data[16] | (resp_data[17] << 8)
        if cc == 0x00 and desc_count == 1 and desc_type == 0x0002 and desc_len == 16:
            uuid_bytes = resp_data[18:34]
            uuid_hex = "".join("%02X" % b for b in uuid_bytes)
            print("[TEST] QDI: PASS (UUID=%s)" % uuid_hex)
            return True
        else:
            print("[TEST] QDI: FAIL (cc=%d, count=%d, type=0x%04X, len=%d)" %
                  (cc, desc_count, desc_type, desc_len))
    else:
        print("[TEST] QDI: FAIL (response too short: %d)" % len(resp_data))
    return False


# ===== Main test runner =====
print("[TEST] ========================================")
print("[TEST] PldmFirmwareDevice Transport Layer Tests")
print("[TEST] ========================================")

test_crc()

sysbus = self.Machine["sysbus"]

results = []
results.append(("SetEID", test_mctp_set_eid(sysbus)))
results.append(("GetEID", test_mctp_get_eid(sysbus)))
results.append(("GetTID", test_pldm_get_tid(sysbus)))
results.append(("GetTypes", test_pldm_get_types(sysbus)))
results.append(("QDI", test_pldm_query_device_identifiers(sysbus)))

print("[TEST] ========================================")
print("[TEST] Results:")
passed = 0
failed = 0
for name, result in results:
    status = "PASS" if result else "FAIL"
    if result:
        passed += 1
    else:
        failed += 1
    print("[TEST]   %s: %s" % (name, status))
print("[TEST] %d passed, %d failed" % (passed, failed))
print("[TEST] ========================================")
