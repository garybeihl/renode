//
// Copyright (c) 2026 Microsoft
//
// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
//
using System;
using System.Collections.Generic;
using Antmicro.Renode.Backends.Terminals;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.UART;

namespace Antmicro.Renode.Integrations
{
    public static class PldmFirmwareDeviceExtensions
    {
        public static void CreatePldmFirmwareDevice(this Emulation emulation,
            string name, string scenarioPath = null)
        {
            emulation.ExternalsManager.AddExternal(new PldmFirmwareDevice(scenarioPath), name);
        }
    }

    // Renode-internal PLDM firmware device that connects to a UART and simulates
    // a PLDM firmware device. Replaces external pldm_sim process.
    //
    // Usage in .resc or Robot Framework:
    //   emulation CreatePldmFirmwareDevice "pldm_fd" @/path/to/scenario.json
    //   connector Connect uart1 pldm_fd
    public class PldmFirmwareDevice : BackendTerminal, IDisposable
    {
        private readonly ScenarioConfig config;
        private readonly MctpSerialTransport transport;
        private readonly PldmFirmwareUpdateHandler fwupHandler;
        private readonly PldmPlatformHandler platformHandler;

        private IMachine machine;
        private byte uaEid; // BMC / UA endpoint ID, learned from incoming packets
        private byte fdTag; // tag counter for FD-initiated requests

        // MCTP multi-packet message reassembly state
        private List<byte> reassemblyBuffer;
        private byte reassemblyMsgType;
        private MctpPacket reassemblyFirstPkt;

        public PldmFirmwareDevice(string scenarioPath = null)
        {
            if(!string.IsNullOrEmpty(scenarioPath))
            {
                config = ScenarioConfig.LoadFromFile(scenarioPath);
                this.Log(LogLevel.Info, "PldmFirmwareDevice: loaded scenario from {0}", scenarioPath);
            }
            else
            {
                config = ScenarioConfig.LoadDefaults();
                this.Log(LogLevel.Info, "PldmFirmwareDevice: using default scenario");
            }

            transport = new MctpSerialTransport(this, OnFrameReceived, SendByteToUart);
            fwupHandler = new PldmFirmwareUpdateHandler(config, this);
            if(config.PlatformEnabled)
            {
                platformHandler = new PldmPlatformHandler(config, this);
            }

            this.Log(LogLevel.Info, "PldmFirmwareDevice: EID={0}, TID={1}, components={2}",
                config.Eid, config.Tid, config.Components.Count);
        }

        public override void AttachTo(IUART uart)
        {
            machine = uart.GetMachine();
            base.AttachTo(uart);
            this.Log(LogLevel.Info, "PldmFirmwareDevice: attached to UART");
        }

        public override void DetachFrom(IUART uart)
        {
            base.DetachFrom(uart);
            machine = null;
            this.Log(LogLevel.Info, "PldmFirmwareDevice: detached from UART");
        }

        // Called when guest UART sends a byte out (guest → us)
        public override void WriteChar(byte value)
        {
            byteCount++;
            if(byteCount <= 10 || (byteCount % 100 == 0))
            {
                this.Log(LogLevel.Debug, "WriteChar: byte #{0} = 0x{1:X2}", byteCount, value);
            }
            transport.ProcessByte(value);
        }

        private int byteCount;

        public void Dispose()
        {
            transport.Reset();
        }

        // Send a byte to the guest UART (us → guest)
        private void SendByteToUart(byte value)
        {
            CallCharReceived(value);
        }

        // Called when a complete MCTP serial frame has been received.
        // Handles multi-packet message reassembly (DSP0236 Section 9.4.1).
        // SOM=1,EOM=1: single-packet message — dispatch directly
        // SOM=1,EOM=0: first fragment — start reassembly buffer
        // SOM=0,EOM=0: middle fragment — append to buffer
        // SOM=0,EOM=1: last fragment — append and dispatch complete message
        private void OnFrameReceived(byte[] data)
        {
            var packet = MctpPacket.Parse(data, 0, data.Length);
            if(packet == null)
            {
                this.Log(LogLevel.Warning, "PldmFirmwareDevice: failed to parse MCTP packet");
                return;
            }

            // Learn UA EID from incoming packets
            if(packet.SrcEid != 0)
            {
                uaEid = packet.SrcEid;
            }

            bool som = packet.SOM;
            bool eom = packet.EOM;

            if(som && eom)
            {
                // Single-packet message — most common case
                this.Log(LogLevel.Debug, "PldmFirmwareDevice: received MCTP packet: dest={0}, src={1}, type={2}, len={3}",
                    packet.DestEid, packet.SrcEid, packet.MessageType, packet.Payload != null ? packet.Payload.Length : 0);
                DispatchMessage(packet);
            }
            else if(som)
            {
                // First fragment of multi-packet message
                reassemblyMsgType = packet.MessageType;
                reassemblyBuffer = new List<byte>(packet.Payload ?? new byte[0]);
                reassemblyFirstPkt = packet;
                this.Log(LogLevel.Debug, "PldmFirmwareDevice: multi-packet SOM: type={0}, frag={1} bytes",
                    packet.MessageType, packet.Payload != null ? packet.Payload.Length : 0);
            }
            else if(reassemblyBuffer != null)
            {
                // Continuation fragment
                if(packet.Payload != null)
                {
                    reassemblyBuffer.AddRange(packet.Payload);
                }
                this.Log(LogLevel.Debug, "PldmFirmwareDevice: multi-packet {0}: +{1} bytes, total={2}",
                    eom ? "EOM" : "MID", packet.Payload != null ? packet.Payload.Length : 0, reassemblyBuffer.Count);

                if(eom)
                {
                    // Last fragment — build complete message and dispatch
                    var complete = new MctpPacket();
                    complete.DestEid = reassemblyFirstPkt.DestEid;
                    complete.SrcEid = reassemblyFirstPkt.SrcEid;
                    // Merge flags: SOM+EOM, preserve tag and TO from first packet
                    complete.FlagsTag = (byte)(MctpPacket.FlagSOM | MctpPacket.FlagEOM |
                        (reassemblyFirstPkt.FlagsTag & (MctpPacket.TagMask | MctpPacket.FlagTO)));
                    complete.MessageType = reassemblyMsgType;
                    complete.Payload = reassemblyBuffer.ToArray();
                    reassemblyBuffer = null;
                    reassemblyFirstPkt = null;

                    this.Log(LogLevel.Debug, "PldmFirmwareDevice: reassembled MCTP message: type={0}, len={1}",
                        complete.MessageType, complete.Payload.Length);
                    DispatchMessage(complete);
                }
            }
            else
            {
                this.Log(LogLevel.Warning, "PldmFirmwareDevice: continuation packet without SOM, dropping");
            }
        }

        // Dispatch a complete (possibly reassembled) MCTP message
        private void DispatchMessage(MctpPacket packet)
        {
            switch(packet.MessageType)
            {
                case MctpPacket.MessageTypeControl:
                    var responsePayload = MctpControlHandler.Handle(packet.Payload, config, this);
                    if(responsePayload != null)
                    {
                        SendMctpResponse(packet, MctpPacket.MessageTypeControl, responsePayload);
                    }
                    break;

                case MctpPacket.MessageTypePldm:
                    if(packet.Payload != null && packet.Payload.Length > 0)
                    {
                        this.Log(LogLevel.Debug, "PLDM raw ({0} bytes): {1}",
                            packet.Payload.Length,
                            packet.Payload.Length <= 64 ? BitConverter.ToString(packet.Payload) : BitConverter.ToString(packet.Payload, 0, 64) + "...");
                    }
                    HandlePldmPacket(packet);
                    break;

                default:
                    this.Log(LogLevel.Warning, "PldmFirmwareDevice: unknown message type 0x{0:X2}", packet.MessageType);
                    break;
            }
        }

        private void HandlePldmPacket(MctpPacket packet)
        {
            if(packet.Payload == null || packet.Payload.Length < 3)
            {
                this.Log(LogLevel.Warning, "PldmFirmwareDevice: PLDM message too short");
                return;
            }

            byte pldmType = (byte)(packet.Payload[1] & 0x3F);
            bool isRequest = (packet.Payload[0] & 0x80) != 0;

            byte[] responseMsg = null;

            if(!isRequest)
            {
                // This is a response to our FD-initiated request
                this.Log(LogLevel.Debug, "PldmFirmwareDevice: routing as PLDM response (byte0=0x{0:X2}, type={1}, len={2})",
                    packet.Payload[0], pldmType, packet.Payload.Length);
                responseMsg = fwupHandler.HandleRequest(packet.Payload);
                // Check for follow-up FD request
                SendPendingFdRequest();
                return;
            }

            switch(pldmType)
            {
                case PldmEncoder.TypeBase:
                    responseMsg = PldmBaseHandler.Handle(packet.Payload, config, this);
                    break;

                case PldmEncoder.TypeFirmwareUpdate:
                    responseMsg = fwupHandler.HandleRequest(packet.Payload);
                    break;

                case PldmEncoder.TypePlatform:
                    if(platformHandler != null)
                    {
                        responseMsg = platformHandler.Handle(packet.Payload);
                    }
                    else
                    {
                        this.Log(LogLevel.Warning, "PldmFirmwareDevice: platform type not enabled");
                        responseMsg = BuildPldmTypeError(packet.Payload);
                    }
                    break;

                default:
                    this.Log(LogLevel.Warning, "PldmFirmwareDevice: unsupported PLDM type {0}", pldmType);
                    responseMsg = BuildPldmTypeError(packet.Payload);
                    break;
            }

            if(responseMsg != null)
            {
                SendMctpResponse(packet, MctpPacket.MessageTypePldm, responseMsg);
            }

            // After sending response, check if FD has a pending request to send
            SendPendingFdRequest();
        }

        private void SendMctpResponse(MctpPacket request, byte messageType, byte[] payload)
        {
            // Fragment if the response exceeds the serial link MTU. The Linux
            // kernel's mctp_serial driver hard-caps mctpserial0's MTU at 68
            // bytes (cannot be raised), so any PLDM response larger than ~63
            // bytes (e.g. multi-component GetFirmwareParameters per DSP0267
            // §6.5.6) must be split across multiple MCTP packets carrying
            // SOM / EOM / sequence-number flags per DSP0236 §8.2.4.
            // Response: same tag as request, TO cleared.
            var fragments = MctpPacket.Fragment(
                request.SrcEid, config.Eid, request.Tag, /*tagOwner=*/false,
                messageType, payload);
            foreach(var pkt in fragments)
            {
                transport.SendFrame(pkt.Build());
            }
        }

        private void SendPendingFdRequest()
        {
            var fdRequest = fwupHandler.GetPendingFdRequest();
            if(fdRequest == null)
            {
                return;
            }

            byte destEid = uaEid != 0 ? uaEid : (byte)8; // default BMC EID
            // Fragment FD-initiated requests too — most are short (RequestFirmwareData
            // ~11 bytes, TransferComplete ~4 bytes) so this is a no-op single packet
            // for them, but keeps a uniform send path.
            var fragments = MctpPacket.Fragment(
                destEid, config.Eid, fdTag, /*tagOwner=*/true,
                MctpPacket.MessageTypePldm, fdRequest);
            fdTag = (byte)((fdTag + 1) & MctpPacket.TagMask);

            foreach(var pkt in fragments)
            {
                transport.SendFrame(pkt.Build());
            }

            this.Log(LogLevel.Debug, "PldmFirmwareDevice: sent FD-initiated request (cmd=0x{0:X2}, {1} fragment(s))",
                fdRequest.Length >= 3 ? fdRequest[2] : 0, fragments.Count);
        }

        private static byte[] BuildPldmTypeError(byte[] request)
        {
            if(request == null || request.Length < 3) return null;
            byte instanceId = (byte)(request[0] & 0x1F);
            byte pldmType = (byte)(request[1] & 0x3F);
            byte command = request[2];
            var resp = new byte[4];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, pldmType, command);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = PldmEncoder.ErrorInvalidPldmType;
            return resp;
        }
    }
}
