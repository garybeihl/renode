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
    /// <summary>
    /// MCTP transport binding for eSPI OOB channel.
    /// Unlike serial transport (DSP0238), OOB delivers complete MCTP packets
    /// without byte-stuffing or FCS framing — the eSPI hardware handles integrity.
    /// </summary>
    public class MctpOobTransport : IMctpTransport
    {
        private readonly IEmulationElement logger;
        private readonly Action<byte[]> sendPacket;

        public MctpOobTransport(IEmulationElement logger, Action<byte[]> sendPacket)
        {
            this.logger = logger;
            this.sendPacket = sendPacket;
        }

        public void SendFrame(byte[] data)
        {
            if(data == null || data.Length == 0)
            {
                logger.Log(LogLevel.Warning, "MCTP OOB: cannot send empty packet");
                return;
            }
            logger.Log(LogLevel.Debug, "MCTP OOB TX: {0} bytes", data.Length);
            sendPacket(data);
        }

        public void Reset()
        {
            // No buffered state to clear — OOB delivers complete packets
        }
    }
}