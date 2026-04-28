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
    // MCTP control message handler (DSP0236 v1.3.1)
    // Handles: SetEID, GetEID, GetUUID, GetMCTPVersionSupport, GetMessageTypeSupport
    public static class MctpControlHandler
    {
        private const byte CmdSetEid = 0x01;
        private const byte CmdGetEid = 0x02;
        private const byte CmdGetUuid = 0x03;
        private const byte CmdGetVersionSupport = 0x04;
        private const byte CmdGetMsgTypeSupport = 0x05;

        // SetEID operation types (DSP0236 Table 14)
        private const byte SetEidOpSetEid = 0x00;
        private const byte SetEidOpForceEid = 0x01;
        private const byte SetEidOpResetEid = 0x02;
        private const byte SetEidOpSetDiscovered = 0x03;

        // Handle an MCTP control message
        // payload = MCTP message body after msg_type byte:
        //   [0] rq_flags: [7] Rq, [6:5] D, [4:0] instance_id
        //   [1] command
        //   [2+] command-specific data
        // Returns response payload (same format, Rq=0)
        public static byte[] Handle(byte[] payload, ScenarioConfig config, IEmulationElement logger)
        {
            if(payload == null || payload.Length < 2)
            {
                return null;
            }

            byte rqFlags = payload[0];
            byte cmd = payload[1];
            byte instance = (byte)(rqFlags & 0x1F);

            // Check Rq bit
            if((rqFlags & 0x80) == 0)
            {
                return null; // not a request
            }

            // Response: Rq=0, same instance
            byte respFlags = instance;

            switch(cmd)
            {
                case CmdSetEid:
                    return HandleSetEid(payload, respFlags, cmd, config, logger);

                case CmdGetEid:
                    logger.Log(LogLevel.Debug, "MCTP Control: Get Endpoint ID -> EID={0}", config.RuntimeEid);
                    return new byte[]
                    {
                        respFlags,
                        cmd,
                        0x00,              // completion code
                        config.RuntimeEid, // current runtime EID
                        0x00,              // EID type: simple endpoint, no pool
                        0x00               // medium-specific info
                    };

                case CmdGetUuid:
                    logger.Log(LogLevel.Debug, "MCTP Control: Get Endpoint UUID");
                    var resp = new byte[3 + 16];
                    resp[0] = respFlags;
                    resp[1] = cmd;
                    resp[2] = 0x00; // completion code
                    Array.Copy(config.Uuid, 0, resp, 3, 16);
                    return resp;

                case CmdGetVersionSupport:
                    return HandleGetVersionSupport(payload, respFlags, cmd, config, logger);

                case CmdGetMsgTypeSupport:
                    logger.Log(LogLevel.Debug, "MCTP Control: Get Message Type Support");
                    return new byte[]
                    {
                        respFlags,
                        cmd,
                        0x00, // completion code
                        2,    // message type count
                        0x00, // MCTP control
                        0x01  // PLDM
                    };

                default:
                    logger.Log(LogLevel.Debug, "MCTP Control: Unknown command 0x{0:X2}", cmd);
                    return new byte[]
                    {
                        respFlags,
                        cmd,
                        0x05  // error: unsupported command
                    };
            }
        }

        private static byte[] HandleSetEid(byte[] payload, byte respFlags, byte cmd,
            ScenarioConfig config, IEmulationElement logger)
        {
            // DSP0236 Table 14: Set Endpoint ID
            // payload[2] = [7:2] reserved, [1:0] operation
            // payload[3] = EID to set
            byte operation = (byte)(payload.Length > 2 ? (payload[2] & 0x03) : 0);
            byte requestedEid = (byte)(payload.Length > 3 ? payload[3] : 0);
            byte assignmentStatus = 0x00; // accepted
            byte allocStatus = 0x00; // no pool

            switch(operation)
            {
                case SetEidOpSetEid:
                case SetEidOpForceEid:
                    if(requestedEid == 0x00 || requestedEid == 0xFF)
                    {
                        // Null/broadcast EID not valid for assignment
                        logger.Log(LogLevel.Warning, "MCTP Control: SetEID rejected invalid EID 0x{0:X2}", requestedEid);
                        assignmentStatus = 0x01; // rejected
                    }
                    else
                    {
                        config.RuntimeEid = requestedEid;
                        logger.Log(LogLevel.Debug, "MCTP Control: SetEID op={0} -> EID={1}", operation, requestedEid);
                    }
                    break;

                case SetEidOpResetEid:
                    config.RuntimeEid = config.Eid; // reset to static default
                    logger.Log(LogLevel.Debug, "MCTP Control: SetEID reset -> EID={0}", config.RuntimeEid);
                    break;

                case SetEidOpSetDiscovered:
                    // Mark as discovered — no EID change for simple endpoint
                    logger.Log(LogLevel.Debug, "MCTP Control: SetEID set-discovered");
                    break;
            }

            return new byte[]
            {
                respFlags,
                cmd,
                0x00,              // completion code = success
                assignmentStatus,  // 0=accepted, 1=rejected
                config.RuntimeEid, // current EID setting
                allocStatus        // EID pool size = 0 (simple endpoint)
            };
        }

        private static byte[] HandleGetVersionSupport(byte[] payload, byte respFlags, byte cmd,
            ScenarioConfig config, IEmulationElement logger)
        {
            // DSP0236 Table 9: Get MCTP Version Support
            // payload[2] = message type number to query
            byte queryType = (byte)(payload.Length > 2 ? payload[2] : 0xFF);

            logger.Log(LogLevel.Debug, "MCTP Control: GetMCTPVersionSupport for type 0x{0:X2}", queryType);

            if(queryType == 0xFF)
            {
                // Query for MCTP Base Spec version
                return new byte[]
                {
                    respFlags,
                    cmd,
                    0x00,  // completion code
                    1,     // version count
                    0xF1, 0xF3, 0xF1, 0x00  // MCTP base spec v1.3.1 (encoded per DSP0236)
                };
            }
            else if(queryType == 0x00)
            {
                // MCTP control message version
                return new byte[]
                {
                    respFlags,
                    cmd,
                    0x00,
                    1,
                    0xF1, 0xF3, 0xF1, 0x00  // same as base
                };
            }
            else if(queryType == 0x01)
            {
                // PLDM over MCTP version
                return new byte[]
                {
                    respFlags,
                    cmd,
                    0x00,
                    1,
                    0xF1, 0xF1, 0xF0, 0x00  // PLDM v1.1.0
                };
            }
            else
            {
                // Unsupported message type
                return new byte[]
                {
                    respFlags,
                    cmd,
                    0x80  // error: message type not supported
                };
            }
        }
    }
}
