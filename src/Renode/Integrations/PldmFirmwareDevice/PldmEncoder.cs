//
// Copyright (c) 2026 Microsoft
//
// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
//
using System;

namespace Antmicro.Renode.Integrations
{
    // PLDM message header encoding/decoding (DSP0240 v1.1.0)
    // Byte 0: [Rq:1 | D:1 | HdrVer:1 | InstanceID:5]  (bit 7 = Rq, bits 4:0 = instance)
    // Byte 1: [Reserved:2 | Type:6]                     (bits 5:0 = PLDM type)
    // Byte 2: Command code
    public static class PldmEncoder
    {
        // PLDM types
        public const byte TypeBase = 0x00;
        public const byte TypePlatform = 0x02;
        public const byte TypeFirmwareUpdate = 0x05;

        // Common completion codes
        public const byte Success = 0x00;
        public const byte Error = 0x01;
        public const byte ErrorNotReady = 0x02;
        public const byte ErrorUnsupportedPldmCmd = 0x05;
        public const byte ErrorInvalidPldmType = 0x20;

        // PLDM Base commands
        public const byte CmdSetTid = 0x01;
        public const byte CmdGetTid = 0x02;
        public const byte CmdGetPldmVersion = 0x03;
        public const byte CmdGetPldmTypes = 0x04;
        public const byte CmdGetPldmCommands = 0x05;

        // PLDM Firmware Update commands
        public const byte CmdQueryDeviceIdentifiers = 0x01;
        public const byte CmdGetFirmwareParameters = 0x02;
        public const byte CmdRequestUpdate = 0x10;
        public const byte CmdPassComponentTable = 0x13;
        public const byte CmdUpdateComponent = 0x14;
        public const byte CmdRequestFirmwareData = 0x15;
        public const byte CmdTransferComplete = 0x16;
        public const byte CmdVerifyComplete = 0x17;
        public const byte CmdApplyComplete = 0x18;
        public const byte CmdActivateFirmware = 0x1A;
        public const byte CmdGetStatus = 0x1B;
        public const byte CmdCancelUpdateComponent = 0x1C;
        public const byte CmdCancelUpdate = 0x1D;

        // PLDM Platform commands
        public const byte CmdGetPdr = 0x51;

        // Firmware update completion codes
        public const byte FwupNotInUpdateMode = 0x80;
        public const byte FwupAlreadyInUpdateMode = 0x81;
        public const byte FwupInvalidStateForCommand = 0x84;

        // Transfer result codes
        public const byte TransferSuccess = 0x00;

        // Verify result codes
        public const byte VerifySuccess = 0x00;
        public const byte VerifyErrorVerificationFailure = 0x01;
        public const byte VerifyErrorVersionMismatch = 0x02;
        public const byte VerifyFailedFdSecurityChecks = 0x03;
        public const byte VerifyErrorImageIncomplete = 0x04;

        // Apply result codes
        public const byte ApplySuccess = 0x00;
        public const byte ApplySuccessWithActivationMethod = 0x01;
        public const byte ApplyFailureMemoryIssue = 0x02;

        // Component response codes
        public const byte CompCanBeUpdated = 0x00;
        public const byte CompNotSupported = 0x06;

        // Descriptor types
        public const ushort DescriptorTypeUuid = 0x0002;

        // Transfer flags
        public const byte TransferStart = 0x01;
        public const byte TransferMiddle = 0x02;
        public const byte TransferEnd = 0x04;
        public const byte TransferStartAndEnd = 0x05;

        // Platform PDR types
        public const byte PdrTerminusLocator = 1;
        public const byte PdrEntityAuxNames = 9;

        // Platform error codes
        public const byte PlatformInvalidRecordHandle = 0x83;

        public static void ParseHeader(byte[] pldmMsg, out byte instanceId, out bool request,
            out bool datagram, out byte pldmType, out byte command)
        {
            byte b0 = pldmMsg[0];
            instanceId = (byte)(b0 & 0x1F);       // bits 4:0
            request = (b0 & 0x80) != 0;            // bit 7
            datagram = (b0 & 0x40) != 0;           // bit 6
            pldmType = (byte)(pldmMsg[1] & 0x3F);  // bits 5:0
            command = pldmMsg[2];
        }

        public static byte[] BuildResponseHeader(byte instanceId, byte pldmType, byte command)
        {
            return new byte[]
            {
                (byte)(instanceId & 0x1F),  // Rq=0, D=0, HdrVer=0, instance in bits 4:0
                pldmType,                    // type in bits 5:0
                command
            };
        }

        public static byte[] BuildRequestHeader(byte instanceId, byte pldmType, byte command)
        {
            return new byte[]
            {
                (byte)(0x80 | (instanceId & 0x1F)),  // Rq=1
                pldmType,                              // type in bits 5:0
                command
            };
        }

        // Little-endian helpers
        public static ushort ReadLE16(byte[] buf, int offset)
        {
            return (ushort)(buf[offset] | (buf[offset + 1] << 8));
        }

        public static uint ReadLE32(byte[] buf, int offset)
        {
            return (uint)(buf[offset] | (buf[offset + 1] << 8) |
                (buf[offset + 2] << 16) | (buf[offset + 3] << 24));
        }

        public static void WriteLE16(byte[] buf, int offset, ushort value)
        {
            buf[offset] = (byte)(value & 0xFF);
            buf[offset + 1] = (byte)((value >> 8) & 0xFF);
        }

        public static void WriteLE32(byte[] buf, int offset, uint value)
        {
            buf[offset] = (byte)(value & 0xFF);
            buf[offset + 1] = (byte)((value >> 8) & 0xFF);
            buf[offset + 2] = (byte)((value >> 16) & 0xFF);
            buf[offset + 3] = (byte)((value >> 24) & 0xFF);
        }
        // Platform monitoring commands (DSP0248)
        public const byte CmdGetSensorReading = 0x11;

        // Sensor data size constants
        public const byte SensorDataSizeUint8  = 0x00;
        public const byte SensorDataSizeSint8  = 0x01;
        public const byte SensorDataSizeUint16 = 0x02;
        public const byte SensorDataSizeSint16 = 0x03;
        public const byte SensorDataSizeUint32 = 0x04;
        public const byte SensorDataSizeSint32 = 0x05;
        public const byte SensorDataSizeUint64 = 0x06;
        public const byte SensorDataSizeSint64 = 0x07;

        // Sensor operational state
        public const byte SensorOpStateEnabled  = 0x00;
        public const byte SensorOpStateDisabled = 0x01;

        // PDR types
        public const byte PdrNumericSensor = 0x02;

        public static void WriteReal32LE(byte[] buf, int offset, float value)
        {
            var bytes = System.BitConverter.GetBytes(value);
            if(!System.BitConverter.IsLittleEndian)
                System.Array.Reverse(bytes);
            System.Array.Copy(bytes, 0, buf, offset, 4);
        }
        // Range field format constants (DSP0248 Table 78)
        public const byte RangeFieldFormatUint8   = 0x00;
        public const byte RangeFieldFormatSint8   = 0x01;
        public const byte RangeFieldFormatUint16  = 0x02;
        public const byte RangeFieldFormatSint16  = 0x03;
        public const byte RangeFieldFormatUint32  = 0x04;
        public const byte RangeFieldFormatSint32  = 0x05;
        public const byte RangeFieldFormatUint64  = 0x06;
        public const byte RangeFieldFormatSint64  = 0x07;
        public const byte RangeFieldFormatReal32  = 0x08;

        public static void WriteLE64(byte[] buf, int offset, ulong value)
        {
            buf[offset]     = (byte)(value & 0xFF);
            buf[offset + 1] = (byte)((value >> 8) & 0xFF);
            buf[offset + 2] = (byte)((value >> 16) & 0xFF);
            buf[offset + 3] = (byte)((value >> 24) & 0xFF);
            buf[offset + 4] = (byte)((value >> 32) & 0xFF);
            buf[offset + 5] = (byte)((value >> 40) & 0xFF);
            buf[offset + 6] = (byte)((value >> 48) & 0xFF);
            buf[offset + 7] = (byte)((value >> 56) & 0xFF);
        }
    }
}