//
// Copyright (c) 2026 Microsoft
//
// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
//
using System;
using Antmicro.Renode.Logging;

namespace Antmicro.Renode.Integrations
{
    // PLDM Base message handler (DSP0240)
    // Handles: GetTID, SetTID, GetPLDMTypes, GetPLDMVersion, GetPLDMCommands
    public static class PldmBaseHandler
    {
        // Handle a PLDM base message
        // pldmMsg = full PLDM message: [hdr_byte0][type][command][payload...]
        // Returns response PLDM message (same format)
        public static byte[] Handle(byte[] pldmMsg, ScenarioConfig config, IEmulationElement logger)
        {
            if(pldmMsg == null || pldmMsg.Length < 3)
            {
                return null;
            }

            byte instanceId, pldmType, command;
            bool request, datagram;
            PldmEncoder.ParseHeader(pldmMsg, out instanceId, out request, out datagram, out pldmType, out command);

            logger.Log(LogLevel.Debug, "PLDM Base: command 0x{0:X2}, instance {1}", command, instanceId);

            switch(command)
            {
                case PldmEncoder.CmdGetTid:
                    return BuildGetTidResponse(instanceId, config.Tid, logger);

                case PldmEncoder.CmdSetTid:
                    return BuildSetTidResponse(instanceId, pldmMsg, config, logger);

                case PldmEncoder.CmdGetPldmTypes:
                    return BuildGetTypesResponse(instanceId, config, logger);

                case PldmEncoder.CmdGetPldmVersion:
                    return BuildGetVersionResponse(instanceId, config, logger);

                case PldmEncoder.CmdGetPldmCommands:
                    return BuildGetCommandsResponse(instanceId, pldmMsg, config, logger);

                default:
                    logger.Log(LogLevel.Debug, "PLDM Base: unsupported command 0x{0:X2}", command);
                    return BuildErrorResponse(instanceId, command, PldmEncoder.ErrorUnsupportedPldmCmd);
            }
        }

        private static byte[] BuildGetTidResponse(byte instanceId, byte tid, IEmulationElement logger)
        {
            logger.Log(LogLevel.Debug, "  -> GetTID: responding TID={0}", tid);
            // Header(3) + CC(1) + TID(1) = 5 bytes
            var resp = new byte[5];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypeBase, PldmEncoder.CmdGetTid);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = PldmEncoder.Success;
            resp[4] = tid;
            return resp;
        }

        private static byte[] BuildSetTidResponse(byte instanceId, byte[] pldmMsg,
            ScenarioConfig config, IEmulationElement logger)
        {
            byte tid = 0;
            if(pldmMsg.Length > 3)
            {
                tid = pldmMsg[3];
            }
            logger.Log(LogLevel.Debug, "  -> SetTID: accepting TID={0}", tid);
            config.Tid = tid;

            // Header(3) + CC(1) = 4 bytes
            var resp = new byte[4];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypeBase, PldmEncoder.CmdSetTid);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = PldmEncoder.Success;
            return resp;
        }

        private static byte[] BuildGetTypesResponse(byte instanceId, ScenarioConfig config, IEmulationElement logger)
        {
            // Supported types bitfield: 8 bytes
            byte typeByte0 = (byte)((1 << PldmEncoder.TypeBase) | (1 << PldmEncoder.TypeFirmwareUpdate));
            if(config.PlatformEnabled)
            {
                typeByte0 |= (1 << PldmEncoder.TypePlatform);
            }
            logger.Log(LogLevel.Debug, "  -> GetPLDMTypes: 0x{0:X2}", typeByte0);

            // Header(3) + CC(1) + types(8) = 12 bytes
            var resp = new byte[12];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypeBase, PldmEncoder.CmdGetPldmTypes);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = PldmEncoder.Success;
            resp[4] = typeByte0;
            // bytes 5-11 are 0 (no types above 7)
            return resp;
        }

        private static byte[] BuildGetVersionResponse(byte instanceId, ScenarioConfig config, IEmulationElement logger)
        {
            logger.Log(LogLevel.Debug, "  -> GetPLDMVersion");

            // Header(3) + CC(1) + next_transfer_handle(4) + transfer_flag(1) + version(4) = 13 bytes
            var resp = new byte[13];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypeBase, PldmEncoder.CmdGetPldmVersion);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = PldmEncoder.Success;
            // next_transfer_handle = 0 (no more data)
            resp[4] = 0; resp[5] = 0; resp[6] = 0; resp[7] = 0;
            resp[8] = PldmEncoder.TransferStartAndEnd;
            // ver32_t: [alpha][update][minor][major] in LE
            resp[9] = 0x00; // alpha
            resp[10] = config.PldmVersion[2]; // update
            resp[11] = config.PldmVersion[1]; // minor
            resp[12] = config.PldmVersion[0]; // major
            return resp;
        }

        private static byte[] BuildGetCommandsResponse(byte instanceId, byte[] pldmMsg,
            ScenarioConfig config, IEmulationElement logger)
        {
            byte reqType = 0;
            if(pldmMsg.Length > 3)
            {
                reqType = pldmMsg[3];
            }
            logger.Log(LogLevel.Debug, "  -> GetPLDMCommands for type {0}", reqType);

            // Header(3) + CC(1) + commands(32) = 36 bytes
            var resp = new byte[36];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypeBase, PldmEncoder.CmdGetPldmCommands);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = PldmEncoder.Success;

            // Commands bitfield starts at resp[4], 32 bytes = 256 bits
            if(reqType == PldmEncoder.TypeBase)
            {
                // Base commands: SetTID(1), GetTID(2), GetVersion(3), GetTypes(4), GetCommands(5)
                resp[4] = (1 << PldmEncoder.CmdSetTid) | (1 << PldmEncoder.CmdGetTid) |
                          (1 << PldmEncoder.CmdGetPldmVersion) | (1 << PldmEncoder.CmdGetPldmTypes) |
                          (1 << PldmEncoder.CmdGetPldmCommands);
            }
            else if(reqType == PldmEncoder.TypeFirmwareUpdate)
            {
                // FWUP byte 0 (commands 0x00-0x07): QDI(1), GFP(2)
                resp[4] = (1 << PldmEncoder.CmdQueryDeviceIdentifiers) |
                          (1 << PldmEncoder.CmdGetFirmwareParameters);
                // FWUP byte 2 (commands 0x10-0x17):
                // RequestUpdate(0x10), PassComponentTable(0x13), UpdateComponent(0x14),
                // RequestFirmwareData(0x15), TransferComplete(0x16), VerifyComplete(0x17)
                resp[6] = (byte)(
                    (1 << (PldmEncoder.CmdRequestUpdate & 7)) |
                    (1 << (PldmEncoder.CmdPassComponentTable & 7)) |
                    (1 << (PldmEncoder.CmdUpdateComponent & 7)) |
                    (1 << (PldmEncoder.CmdRequestFirmwareData & 7)) |
                    (1 << (PldmEncoder.CmdTransferComplete & 7)) |
                    (1 << (PldmEncoder.CmdVerifyComplete & 7)));
                // FWUP byte 3 (commands 0x18-0x1F):
                // ApplyComplete(0x18), ActivateFirmware(0x1A), GetStatus(0x1B),
                // CancelUpdateComponent(0x1C), CancelUpdate(0x1D)
                resp[7] = (byte)(
                    (1 << (PldmEncoder.CmdApplyComplete & 7)) |
                    (1 << (PldmEncoder.CmdActivateFirmware & 7)) |
                    (1 << (PldmEncoder.CmdGetStatus & 7)) |
                    (1 << (PldmEncoder.CmdCancelUpdateComponent & 7)) |
                    (1 << (PldmEncoder.CmdCancelUpdate & 7)));
            }
            else if(reqType == PldmEncoder.TypePlatform && config.PlatformEnabled)
            {
                // Platform: GetSensorReading(0x11) → byte 2, bit 1
                resp[4 + 2] = (byte)(1 << (PldmEncoder.CmdGetSensorReading & 7));
                // Platform: GetPDR(0x51) → byte 10, bit 1
                resp[4 + 10] = (byte)(1 << (PldmEncoder.CmdGetPdr & 7));
            }

            return resp;
        }

        private static byte[] BuildErrorResponse(byte instanceId, byte command, byte errorCode)
        {
            var resp = new byte[4];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypeBase, command);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = errorCode;
            return resp;
        }
    }
}
