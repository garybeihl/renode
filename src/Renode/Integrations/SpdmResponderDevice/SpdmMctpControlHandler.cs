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
    // MCTP control message handler for SPDM responder device (DSP0236)
    // Reports supported message types: Control (0x00) + SPDM (0x05)
    public static class SpdmMctpControlHandler
    {
        private const byte CmdSetEid = 0x01;
        private const byte CmdGetEid = 0x02;
        private const byte CmdGetUuid = 0x03;
        private const byte CmdGetMsgTypeSupport = 0x05;

        public static byte[] Handle(byte[] payload, SpdmScenarioConfig config, IEmulationElement logger)
        {
            if(payload == null || payload.Length < 2)
            {
                return null;
            }

            byte rqFlags = payload[0];
            byte cmd = payload[1];
            byte instance = (byte)(rqFlags & 0x1F);

            if((rqFlags & 0x80) == 0)
            {
                return null; // not a request
            }

            byte respFlags = instance;

            switch(cmd)
            {
                case CmdSetEid:
                    // Accept the EID assigned by the bus owner (DSP0236 Section 12.3)
                    if(payload.Length >= 4)
                    {
                        byte assignedEid = payload[3];
                        logger.Log(LogLevel.Debug, "SPDM MCTP Control: Set Endpoint ID (assigned EID={0}, was {1})",
                            assignedEid, config.Eid);
                        config.Eid = assignedEid;
                    }
                    else
                    {
                        logger.Log(LogLevel.Debug, "SPDM MCTP Control: Set Endpoint ID (keeping EID={0})", config.Eid);
                    }
                    return new byte[]
                    {
                        respFlags,
                        cmd,
                        0x00,       // completion code = success
                        0x00,       // EID assignment status
                        config.Eid,
                        0x00        // EID pool size
                    };

                case CmdGetEid:
                    logger.Log(LogLevel.Debug, "SPDM MCTP Control: Get Endpoint ID");
                    return new byte[]
                    {
                        respFlags,
                        cmd,
                        0x00,
                        config.Eid,
                        0x00,       // EID type (simple)
                        0x00        // medium-specific info
                    };

                case CmdGetUuid:
                    logger.Log(LogLevel.Debug, "SPDM MCTP Control: Get Endpoint UUID");
                    var resp = new byte[3 + 16];
                    resp[0] = respFlags;
                    resp[1] = cmd;
                    resp[2] = 0x00; // completion code
                    Array.Copy(config.Uuid, 0, resp, 3, 16);
                    return resp;

                case CmdGetMsgTypeSupport:
                    logger.Log(LogLevel.Debug, "SPDM MCTP Control: Get Message Type Support (advertise_spdm={0})",
                        config.AdvertiseSpdm);
                    if(config.AdvertiseSpdm)
                    {
                        return new byte[]
                        {
                            respFlags,
                            cmd,
                            0x00, // completion code
                            2,    // message type count
                            0x00, // MCTP control
                            0x05  // SPDM
                        };
                    }
                    else
                    {
                        return new byte[]
                        {
                            respFlags,
                            cmd,
                            0x00, // completion code
                            1,    // message type count
                            0x00  // MCTP control only
                        };
                    }

                default:
                    logger.Log(LogLevel.Debug, "SPDM MCTP Control: Unknown command 0x{0:X2}", cmd);
                    return new byte[]
                    {
                        respFlags,
                        cmd,
                        0x05  // error: unsupported command
                    };
            }
        }
    }
}
