//
// Copyright (c) 2026 Microsoft
//
// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
//
using System;
using System.Collections.Generic;
using System.Text;
using Antmicro.Renode.Logging;

namespace Antmicro.Renode.Integrations
{
    // PLDM Platform Monitoring & Control handler (DSP0248)
    // Handles: GetPDR, GetSensorReading
    public class PldmPlatformHandler
    {
        private readonly ScenarioConfig config;
        private readonly IEmulationElement logger;
        private byte[][] pdrRecords;
        private readonly Dictionary<ushort, SensorConfig> sensorMap = new Dictionary<ushort, SensorConfig>();

        public PldmPlatformHandler(ScenarioConfig config, IEmulationElement logger)
        {
            this.config = config;
            this.logger = logger;
            BuildPdrRepository();
        }

        public byte[] Handle(byte[] pldmMsg)
        {
            if(pldmMsg == null || pldmMsg.Length < 3)
            {
                return null;
            }

            byte instanceId, pldmType, command;
            bool request, datagram;
            PldmEncoder.ParseHeader(pldmMsg, out instanceId, out request, out datagram, out pldmType, out command);

            switch(command)
            {
                case PldmEncoder.CmdGetPdr:
                    return HandleGetPdr(instanceId, pldmMsg);
                case PldmEncoder.CmdGetSensorReading:
                    return HandleGetSensorReading(instanceId, pldmMsg);
                default:
                    logger.Log(LogLevel.Debug, "PLDM Platform: unsupported command 0x{0:X2}", command);
                    var errResp = new byte[4];
                    var errHdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypePlatform, command);
                    Array.Copy(errHdr, 0, errResp, 0, 3);
                    errResp[3] = PldmEncoder.ErrorUnsupportedPldmCmd;
                    return errResp;
            }
        }

        private byte[] HandleGetPdr(byte instanceId, byte[] pldmMsg)
        {
            // Parse request: record_handle(4) + data_transfer_handle(4) +
            //   transfer_op_flag(1) + request_count(2) + record_change_number(2) = 13
            if(pldmMsg.Length < 16)
            {
                return BuildPdrError(instanceId, PldmEncoder.Error);
            }

            uint recordHandle = PldmEncoder.ReadLE32(pldmMsg, 3);
            // data_transfer_handle at 7, transfer_op_flag at 11 — not used for small PDRs
            ushort requestCount = PldmEncoder.ReadLE16(pldmMsg, 12);

            logger.Log(LogLevel.Debug, "PLDM Platform: GetPDR, record_handle={0}, request_count={1}",
                recordHandle, requestCount);

            // Map record handle to index (handle 0 = first record, handle N = record N-1)
            int idx = recordHandle == 0 ? 0 : (int)recordHandle - 1;

            if(idx < 0 || idx >= pdrRecords.Length)
            {
                logger.Log(LogLevel.Debug, "  -> Record not found");
                return BuildPdrError(instanceId, PldmEncoder.PlatformInvalidRecordHandle);
            }

            uint nextHandle = 0;
            if(idx + 1 < pdrRecords.Length)
            {
                nextHandle = (uint)(idx + 2);
            }

            var record = pdrRecords[idx];
            ushort respCount = (ushort)record.Length;

            logger.Log(LogLevel.Debug, "  -> Returning record {0} ({1} bytes), next_handle={2}",
                idx + 1, respCount, nextHandle);

            // Response: Header(3) + CC(1) + next_record_handle(4) + next_data_transfer_handle(4) +
            //   transfer_flag(1) + response_count(2) + record_data(N) = 15 + N
            // (transfer_change_number omitted for single-part transfer)
            var resp = new byte[15 + respCount];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypePlatform, PldmEncoder.CmdGetPdr);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = PldmEncoder.Success;
            PldmEncoder.WriteLE32(resp, 4, nextHandle);
            PldmEncoder.WriteLE32(resp, 8, 0); // next_data_transfer_handle
            resp[12] = PldmEncoder.TransferStartAndEnd;
            PldmEncoder.WriteLE16(resp, 13, respCount);
            Array.Copy(record, 0, resp, 15, respCount);
            return resp;
        }

        private byte[] BuildPdrError(byte instanceId, byte errorCode)
        {
            // Minimal GetPDR error response: Header(3) + CC(1) + next_handle(4) +
            //   next_data_handle(4) + transfer_flag(1) + response_count(2) = 15
            var resp = new byte[15];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypePlatform, PldmEncoder.CmdGetPdr);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = errorCode;
            return resp;
        }

        private void BuildPdrRepository()
        {
            int sensorCount = config.Sensors.Count;
            int totalRecords = 2 + sensorCount;
            pdrRecords = new byte[totalRecords][];
            uint handle = 1;
            pdrRecords[0] = BuildTerminusLocatorPdr(handle++, config.Eid, config.Tid);
            pdrRecords[1] = BuildEntityAuxNamesPdr(handle++, config.EntityType, config.Name);

            for(int i = 0; i < sensorCount; i++)
            {
                var sensor = config.Sensors[i];
                pdrRecords[2 + i] = BuildNumericSensorPdr(handle++, sensor, config.EntityType);
                sensorMap[sensor.Id] = sensor;
            }

            logger.Log(LogLevel.Debug, "PLDM Platform: PDR repository: {0} records ({1} sensors)",
                pdrRecords.Length, sensorCount);
        }

        // Build terminus locator PDR (DSP0248 Table 10)
        private static byte[] BuildTerminusLocatorPdr(uint recordHandle, byte eid, byte tid)
        {
            // PDR header (10 bytes) + data (9 bytes) = 19 bytes
            const int dataLen = 9;
            const int pdrHdrLen = 10;
            var buf = new byte[pdrHdrLen + dataLen];

            // PDR header
            PldmEncoder.WriteLE32(buf, 0, recordHandle);
            buf[4] = 0x01; // PDR version
            buf[5] = PldmEncoder.PdrTerminusLocator; // PDR type
            buf[6] = 0x00; // record change number (lo)
            buf[7] = 0x00; // record change number (hi)
            PldmEncoder.WriteLE16(buf, 8, (ushort)dataLen);

            // Terminus locator data
            int d = pdrHdrLen;
            buf[d + 0] = 0x01; // PLDMTerminusHandle (lo)
            buf[d + 1] = 0x00; // PLDMTerminusHandle (hi)
            buf[d + 2] = 0x01; // validity (valid)
            buf[d + 3] = tid;  // TID
            buf[d + 4] = 0x00; // container_id (lo)
            buf[d + 5] = 0x00; // container_id (hi)
            buf[d + 6] = 0x01; // terminus_locator_type = MCTP EID
            buf[d + 7] = 0x01; // terminus_locator_value_size
            buf[d + 8] = eid;  // EID

            return buf;
        }

        // Build entity auxiliary names PDR (DSP0248 Table 95)
        private static byte[] BuildEntityAuxNamesPdr(uint recordHandle, ushort entityType, string name)
        {
            var nameBytes = Encoding.ASCII.GetBytes(name);
            // Fixed fields: entityType(2) + instanceNum(2) + containerID(2) +
            //   sharedNameCount(1) + nameStringCount(1) = 8
            // Tag "en" + NUL = 3 bytes; name in UTF-16BE + NUL = nameLen*2+2
            int tagLen = 3;
            int u16NameBytes = nameBytes.Length * 2 + 2;
            int dataLen = 8 + tagLen + u16NameBytes;
            int pdrHdrLen = 10;
            var buf = new byte[pdrHdrLen + dataLen];

            // PDR header
            PldmEncoder.WriteLE32(buf, 0, recordHandle);
            buf[4] = 0x01; // PDR version
            buf[5] = PldmEncoder.PdrEntityAuxNames; // PDR type
            buf[6] = 0x00; // record change number (lo)
            buf[7] = 0x00; // record change number (hi)
            PldmEncoder.WriteLE16(buf, 8, (ushort)dataLen);

            // Entity aux names data
            int d = pdrHdrLen;
            PldmEncoder.WriteLE16(buf, d, entityType);
            PldmEncoder.WriteLE16(buf, d + 2, 1); // entityInstanceNumber
            PldmEncoder.WriteLE16(buf, d + 4, 0); // entityContainerID
            buf[d + 6] = 0; // sharedNameCount
            buf[d + 7] = 1; // nameStringCount

            // Language tag "en\0"
            buf[d + 8] = (byte)'e';
            buf[d + 9] = (byte)'n';
            buf[d + 10] = 0;

            // Name in UTF-16BE
            int np = d + 11;
            for(int i = 0; i < nameBytes.Length; i++)
            {
                buf[np + i * 2] = 0x00;
                buf[np + i * 2 + 1] = nameBytes[i];
            }
            // NUL terminator
            buf[np + nameBytes.Length * 2] = 0x00;
            buf[np + nameBytes.Length * 2 + 1] = 0x00;

            return buf;
        }

        private byte[] HandleGetSensorReading(byte instanceId, byte[] pldmMsg)
        {
            // Request: header(3) + sensor_id(2) + rearm_event_state(1) = 6
            if(pldmMsg.Length < 6)
            {
                return BuildSensorReadingError(instanceId, PldmEncoder.Error);
            }

            ushort sensorId = PldmEncoder.ReadLE16(pldmMsg, 3);

            logger.Log(LogLevel.Debug, "PLDM Platform: GetSensorReading, sensor_id={0}", sensorId);

            if(!sensorMap.ContainsKey(sensorId))
            {
                logger.Log(LogLevel.Debug, "  -> Sensor not found");
                return BuildSensorReadingError(instanceId, 0x80); // PLDM_PLATFORM_INVALID_SENSOR_ID
            }

            var sensor = sensorMap[sensorId];
            int valueSize = GetSensorValueSize(sensor.DataSize);

            // Response: header(3) + CC(1) + data_size(1) + op_state(1) + event_msg_enable(1) +
            //   present_state(1) + previous_state(1) + event_state(1) + present_reading(N)
            var resp = new byte[10 + valueSize];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypePlatform, PldmEncoder.CmdGetSensorReading);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = PldmEncoder.Success;
            resp[4] = sensor.DataSize;
            resp[5] = PldmEncoder.SensorOpStateEnabled;
            resp[6] = 0x00; // event_message_enable: no event generation
            resp[7] = 0x02; // present_state: normalRange
            resp[8] = 0x02; // previous_state: normalRange
            resp[9] = 0x02; // event_state: normalRange

            WriteSensorValue(resp, 10, sensor.DataSize, sensor.Value);

            logger.Log(LogLevel.Debug, "  -> Returning value {0} (data_size={1})", sensor.Value, sensor.DataSize);
            return resp;
        }

        private byte[] BuildSensorReadingError(byte instanceId, byte errorCode)
        {
            var resp = new byte[4];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypePlatform, PldmEncoder.CmdGetSensorReading);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = errorCode;
            return resp;
        }

        // Build numeric sensor PDR (DSP0248 Table 78)
        // Wire format: all fields packed at fixed offsets using the sensor_data_size
        // and range_field_format to determine value widths.
        private static byte[] BuildNumericSensorPdr(uint recordHandle, SensorConfig sensor, ushort entityType)
        {
            int sensorValSize = GetSensorValueSize(sensor.DataSize);
            byte rangeFieldFormat = SensorDataSizeToRangeFormat(sensor.DataSize);
            int rangeFieldSize = GetRangeFieldSize(rangeFieldFormat);

            // PDR header (10 bytes) + fixed fields (30 bytes) +
            //   hysteresis(sensorValSize) + thresholds_support(1) + threshold_volatility(1) +
            //   state_transition_interval(4) + update_interval(4) +
            //   max_readable(sensorValSize) + min_readable(sensorValSize) +
            //   range_field_format(1) + range_field_support(1) +
            //   9 range values * rangeFieldSize
            const int pdrHdrLen = 10;
            const int fixedDataLen = 35;
            int variableLen = sensorValSize + 1 + 1 + 4 + 4 + sensorValSize + sensorValSize + 1 + 1 + 9 * rangeFieldSize;
            int dataLen = fixedDataLen + variableLen;
            var buf = new byte[pdrHdrLen + dataLen];

            // PDR header
            PldmEncoder.WriteLE32(buf, 0, recordHandle);
            buf[4] = 0x01; // PDR version
            buf[5] = PldmEncoder.PdrNumericSensor; // PDR type
            buf[6] = 0x00; // record change number (lo)
            buf[7] = 0x00; // record change number (hi)
            PldmEncoder.WriteLE16(buf, 8, (ushort)dataLen);

            // Numeric sensor PDR data (DSP0248 Table 78)
            int d = pdrHdrLen;
            PldmEncoder.WriteLE16(buf, d, 0x0001); d += 2; // PLDMTerminusHandle
            PldmEncoder.WriteLE16(buf, d, sensor.Id); d += 2; // sensorID
            PldmEncoder.WriteLE16(buf, d, entityType); d += 2; // entityType
            PldmEncoder.WriteLE16(buf, d, 1); d += 2; // entityInstanceNumber
            PldmEncoder.WriteLE16(buf, d, 0); d += 2; // containerID
            buf[d++] = 0x00; // sensorInit = noInit
            buf[d++] = 0x00; // sensorAuxiliaryNamesPDR = false
            buf[d++] = sensor.BaseUnit; // baseUnit
            buf[d++] = (byte)sensor.UnitModifier; // unitModifier (signed)
            buf[d++] = 0x00; // rateUnit = none
            buf[d++] = 0x00; // baseOEMUnitHandle
            buf[d++] = 0x00; // auxUnit
            buf[d++] = 0x00; // auxUnitModifier
            buf[d++] = 0x00; // auxRateUnit
            buf[d++] = 0x00; // rel (isLinear=false)
            buf[d++] = 0x00; // auxOEMUnitHandle
            buf[d++] = 0x01; // isLinear = true
            buf[d++] = sensor.DataSize; // sensorDataSize

            // resolution (real32) = 1.0
            PldmEncoder.WriteReal32LE(buf, d, 1.0f); d += 4;
            // offset (real32) = 0.0
            PldmEncoder.WriteReal32LE(buf, d, 0.0f); d += 4;

            PldmEncoder.WriteLE16(buf, d, 0); d += 2; // accuracy
            buf[d++] = 0; // plusTolerance
            buf[d++] = 0; // minusTolerance

            // hysteresis (sensor_data_size width, all zeros)
            d += sensorValSize;

            buf[d++] = 0x00; // supported_thresholds
            buf[d++] = 0x00; // threshold_and_hysteresis_volatility

            // state_transition_interval (real32) = 0
            PldmEncoder.WriteReal32LE(buf, d, 0.0f); d += 4;
            // update_interval (real32) = 1.0
            PldmEncoder.WriteReal32LE(buf, d, 1.0f); d += 4;

            // max_readable
            WriteSensorValue(buf, d, sensor.DataSize, GetMaxReadable(sensor.DataSize));
            d += sensorValSize;

            // min_readable
            WriteSensorValue(buf, d, sensor.DataSize, GetMinReadable(sensor.DataSize));
            d += sensorValSize;

            buf[d++] = rangeFieldFormat; // range_field_format
            buf[d++] = 0x00; // range_field_support (none)

            // 9 range field values (all zeros — nominal, normal_max, normal_min,
            //   warning_high, warning_low, critical_high, critical_low, fatal_high, fatal_low)
            // Already zero from array initialization

            return buf;
        }

        private static int GetSensorValueSize(byte dataSize)
        {
            switch(dataSize)
            {
                case PldmEncoder.SensorDataSizeUint8:
                case PldmEncoder.SensorDataSizeSint8:
                    return 1;
                case PldmEncoder.SensorDataSizeUint16:
                case PldmEncoder.SensorDataSizeSint16:
                    return 2;
                case PldmEncoder.SensorDataSizeUint32:
                case PldmEncoder.SensorDataSizeSint32:
                    return 4;
                case PldmEncoder.SensorDataSizeUint64:
                case PldmEncoder.SensorDataSizeSint64:
                    return 8;
                default:
                    return 4;
            }
        }

        private static byte SensorDataSizeToRangeFormat(byte dataSize)
        {
            switch(dataSize)
            {
                case PldmEncoder.SensorDataSizeUint8: return PldmEncoder.RangeFieldFormatUint8;
                case PldmEncoder.SensorDataSizeSint8: return PldmEncoder.RangeFieldFormatSint8;
                case PldmEncoder.SensorDataSizeUint16: return PldmEncoder.RangeFieldFormatUint16;
                case PldmEncoder.SensorDataSizeSint16: return PldmEncoder.RangeFieldFormatSint16;
                case PldmEncoder.SensorDataSizeUint32: return PldmEncoder.RangeFieldFormatUint32;
                case PldmEncoder.SensorDataSizeSint32: return PldmEncoder.RangeFieldFormatSint32;
                case PldmEncoder.SensorDataSizeUint64: return PldmEncoder.RangeFieldFormatUint64;
                case PldmEncoder.SensorDataSizeSint64: return PldmEncoder.RangeFieldFormatSint64;
                default: return PldmEncoder.RangeFieldFormatUint32;
            }
        }

        private static int GetRangeFieldSize(byte rangeFormat)
        {
            switch(rangeFormat)
            {
                case PldmEncoder.RangeFieldFormatUint8:
                case PldmEncoder.RangeFieldFormatSint8:
                    return 1;
                case PldmEncoder.RangeFieldFormatUint16:
                case PldmEncoder.RangeFieldFormatSint16:
                    return 2;
                case PldmEncoder.RangeFieldFormatUint32:
                case PldmEncoder.RangeFieldFormatSint32:
                case PldmEncoder.RangeFieldFormatReal32:
                    return 4;
                case PldmEncoder.RangeFieldFormatUint64:
                case PldmEncoder.RangeFieldFormatSint64:
                    return 8;
                default:
                    return 4;
            }
        }

        private static void WriteSensorValue(byte[] buf, int offset, byte dataSize, long value)
        {
            switch(dataSize)
            {
                case PldmEncoder.SensorDataSizeUint8:
                case PldmEncoder.SensorDataSizeSint8:
                    buf[offset] = (byte)value;
                    break;
                case PldmEncoder.SensorDataSizeUint16:
                case PldmEncoder.SensorDataSizeSint16:
                    PldmEncoder.WriteLE16(buf, offset, (ushort)value);
                    break;
                case PldmEncoder.SensorDataSizeUint32:
                case PldmEncoder.SensorDataSizeSint32:
                    PldmEncoder.WriteLE32(buf, offset, (uint)value);
                    break;
                case PldmEncoder.SensorDataSizeUint64:
                case PldmEncoder.SensorDataSizeSint64:
                    PldmEncoder.WriteLE64(buf, offset, (ulong)value);
                    break;
            }
        }

        private static long GetMaxReadable(byte dataSize)
        {
            switch(dataSize)
            {
                case PldmEncoder.SensorDataSizeUint8: return byte.MaxValue;
                case PldmEncoder.SensorDataSizeSint8: return sbyte.MaxValue;
                case PldmEncoder.SensorDataSizeUint16: return ushort.MaxValue;
                case PldmEncoder.SensorDataSizeSint16: return short.MaxValue;
                case PldmEncoder.SensorDataSizeUint32: return uint.MaxValue;
                case PldmEncoder.SensorDataSizeSint32: return int.MaxValue;
                case PldmEncoder.SensorDataSizeUint64: return long.MaxValue;
                case PldmEncoder.SensorDataSizeSint64: return long.MaxValue;
                default: return uint.MaxValue;
            }
        }

        private static long GetMinReadable(byte dataSize)
        {
            switch(dataSize)
            {
                case PldmEncoder.SensorDataSizeSint8: return sbyte.MinValue;
                case PldmEncoder.SensorDataSizeSint16: return short.MinValue;
                case PldmEncoder.SensorDataSizeSint32: return int.MinValue;
                case PldmEncoder.SensorDataSizeSint64: return long.MinValue;
                default: return 0;
            }
        }
    }
}
