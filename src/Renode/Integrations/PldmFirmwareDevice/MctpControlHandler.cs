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
    // MCTP control message handler (DSP0236)
    // Handles: SetEID, GetEID, GetUUID, GetMessageTypeSupport
    public static class MctpControlHandler
    {
        private const byte CmdSetEid = 0x01;
        private const byte CmdGetEid = 0x02;
        private const byte CmdGetUuid = 0x03;
        private const byte CmdGetMsgTypeSupport = 0x05;

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
                    logger.Log(LogLevel.Debug, "MCTP Control: Set Endpoint ID");
                    return new byte[]
                    {
                        respFlags,  // instance, Rq=0
                        cmd,        // command
                        0x00,       // completion code = success
                        0x00,       // EID assignment status
                        config.Eid, // EID setting
                        0x00        // EID pool size
                    };

                case CmdGetEid:
                    logger.Log(LogLevel.Debug, "MCTP Control: Get Endpoint ID");
                    return new byte[]
                    {
                        respFlags,
                        cmd,
                        0x00,       // completion code
                        config.Eid, // EID
                        0x00,       // EID type (simple)
                        0x00        // medium-specific info
                    };

                case CmdGetUuid:
                    logger.Log(LogLevel.Debug, "MCTP Control: Get Endpoint UUID");
                    var resp = new byte[4 + 16];
                    resp[0] = respFlags;
                    resp[1] = cmd;
                    resp[2] = 0x00; // completion code
                    // 16-byte UUID follows at offset 3
                    // Note: GetUUID response has CC at [2], UUID at [3..18]
                    Array.Copy(config.Uuid, 0, resp, 3, 16);
                    return resp;

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
    }
}
