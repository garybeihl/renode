//
// Copyright (c) 2026 Microsoft
//
// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
//
namespace Antmicro.Renode.Integrations
{
    /// <summary>
    /// Transport abstraction for MCTP packet delivery.
    /// Implementations handle binding-specific framing (serial DSP0238, eSPI OOB, etc.)
    /// while the upper layers (PldmFirmwareDevice) work with raw MCTP packets.
    /// </summary>
    public interface IMctpTransport
    {
        /// <summary>
        /// Send an MCTP packet (built via MctpPacket.Build()) to the remote endpoint.
        /// The transport adds any binding-specific framing.
        /// </summary>
        void SendFrame(byte[] data);

        /// <summary>
        /// Reset transport state (e.g., clear partial frame buffers).
        /// </summary>
        void Reset();
    }
}