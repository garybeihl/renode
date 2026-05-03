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
    public static class SpdmResponderDeviceExtensions
    {
        public static void CreateSpdmResponderDevice(this Emulation emulation,
            string name, string scenarioPath = null, string keyDir = null)
        {
            emulation.ExternalsManager.AddExternal(new SpdmResponderDevice(scenarioPath, keyDir), name);
        }
    }

    // Renode-internal SPDM responder device that connects to a UART and simulates
    // an SPDM-capable device for attestation testing.
    //
    // Usage in .resc or Robot Framework:
    //   emulation CreateSpdmResponderDevice "spdm_dev" @/path/to/scenario.json "/path/to/keys"
    //   connector Connect uart1 spdm_dev
    public class SpdmResponderDevice : BackendTerminal, IDisposable
    {
        private readonly SpdmScenarioConfig config;
        private readonly MctpSerialTransport transport;
        private readonly SpdmProtocolHandler spdmHandler;

        private IMachine machine;

        // MCTP multi-packet message reassembly state
        private List<byte> reassemblyBuffer;
        private byte reassemblyMsgType;
        private MctpPacket reassemblyFirstPkt;

        public SpdmResponderDevice(string scenarioPath = null, string keyDir = null)
        {
            if(!string.IsNullOrEmpty(scenarioPath))
            {
                config = SpdmScenarioConfig.LoadFromFile(scenarioPath, keyDir);
                this.Log(LogLevel.Info, "SpdmResponderDevice: loaded scenario from {0}", scenarioPath);
            }
            else
            {
                config = SpdmScenarioConfig.LoadDefaults();
                this.Log(LogLevel.Info, "SpdmResponderDevice: using default scenario");
            }

            transport = new MctpSerialTransport(this, OnFrameReceived, SendByteToUart);
            spdmHandler = new SpdmProtocolHandler(config, this);

            this.Log(LogLevel.Info, "SpdmResponderDevice: EID={0}, name={1}, measurements={2}",
                config.Eid, config.Name, config.Measurements.Count);
        }

        public override void AttachTo(IUART uart)
        {
            machine = uart.GetMachine();
            base.AttachTo(uart);
            this.Log(LogLevel.Info, "SpdmResponderDevice: attached to UART");
        }

        public override void DetachFrom(IUART uart)
        {
            base.DetachFrom(uart);
            machine = null;
            this.Log(LogLevel.Info, "SpdmResponderDevice: detached from UART");
        }

        // Called when guest UART sends a byte out (guest -> us)
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
        private int spdmResponseCount;

        public void Dispose()
        {
            transport.Reset();
        }

        // Send a byte to the guest UART (us -> guest)
        private void SendByteToUart(byte value)
        {
            CallCharReceived(value);
        }

        // Called when a complete MCTP serial frame has been received.
        // Handles multi-packet message reassembly (DSP0236 Section 9.4.1).
        private void OnFrameReceived(byte[] data)
        {
            var packet = MctpPacket.Parse(data, 0, data.Length);
            if(packet == null)
            {
                this.Log(LogLevel.Warning, "SpdmResponderDevice: failed to parse MCTP packet");
                return;
            }

            bool som = packet.SOM;
            bool eom = packet.EOM;

            if(som && eom)
            {
                // Single-packet message
                this.Log(LogLevel.Debug, "SpdmResponderDevice: received MCTP packet: dest={0}, src={1}, type=0x{2:X2}, len={3}",
                    packet.DestEid, packet.SrcEid, packet.MessageType, packet.Payload != null ? packet.Payload.Length : 0);
                DispatchMessage(packet);
            }
            else if(som)
            {
                // First fragment of multi-packet message
                reassemblyMsgType = packet.MessageType;
                reassemblyBuffer = new List<byte>(packet.Payload ?? new byte[0]);
                reassemblyFirstPkt = packet;
                this.Log(LogLevel.Debug, "SpdmResponderDevice: multi-packet SOM: type=0x{0:X2}, frag={1} bytes",
                    packet.MessageType, packet.Payload != null ? packet.Payload.Length : 0);
            }
            else if(reassemblyBuffer != null)
            {
                // Continuation fragment
                if(packet.Payload != null)
                {
                    reassemblyBuffer.AddRange(packet.Payload);
                }
                this.Log(LogLevel.Debug, "SpdmResponderDevice: multi-packet {0}: +{1} bytes, total={2}",
                    eom ? "EOM" : "MID", packet.Payload != null ? packet.Payload.Length : 0, reassemblyBuffer.Count);

                if(eom)
                {
                    var complete = new MctpPacket();
                    complete.DestEid = reassemblyFirstPkt.DestEid;
                    complete.SrcEid = reassemblyFirstPkt.SrcEid;
                    complete.FlagsTag = (byte)(MctpPacket.FlagSOM | MctpPacket.FlagEOM |
                        (reassemblyFirstPkt.FlagsTag & (MctpPacket.TagMask | MctpPacket.FlagTO)));
                    complete.MessageType = reassemblyMsgType;
                    complete.Payload = reassemblyBuffer.ToArray();
                    reassemblyBuffer = null;
                    reassemblyFirstPkt = null;

                    this.Log(LogLevel.Debug, "SpdmResponderDevice: reassembled MCTP message: type=0x{0:X2}, len={1}",
                        complete.MessageType, complete.Payload.Length);
                    DispatchMessage(complete);
                }
            }
            else
            {
                this.Log(LogLevel.Warning, "SpdmResponderDevice: continuation packet without SOM, dropping");
            }
        }

        // Dispatch a complete MCTP message based on message type
        private void DispatchMessage(MctpPacket packet)
        {
            switch(packet.MessageType)
            {
                case MctpPacket.MessageTypeControl:
                    var controlResp = SpdmMctpControlHandler.Handle(packet.Payload, config, this);
                    if(controlResp != null)
                    {
                        SendMctpResponse(packet, MctpPacket.MessageTypeControl, controlResp);
                    }
                    break;

                case MctpPacket.MessageTypeSpdm:
                    if(packet.Payload != null && packet.Payload.Length > 0)
                    {
                        this.Log(LogLevel.Debug, "SPDM raw ({0} bytes): {1}",
                            packet.Payload.Length,
                            packet.Payload.Length <= 64
                                ? BitConverter.ToString(packet.Payload)
                                : BitConverter.ToString(packet.Payload, 0, 64) + "...");
                    }
                    HandleSpdmPacket(packet);
                    break;

                default:
                    this.Log(LogLevel.Warning, "SpdmResponderDevice: unknown message type 0x{0:X2}", packet.MessageType);
                    break;
            }
        }

        private void HandleSpdmPacket(MctpPacket packet)
        {
            if(packet.Payload == null || packet.Payload.Length < 4)
            {
                this.Log(LogLevel.Warning, "SpdmResponderDevice: SPDM message too short");
                return;
            }

            // Check if we've exceeded the response limit (for mid-flow disconnect testing)
            if(config.MaxSpdmResponses > 0 && spdmResponseCount >= config.MaxSpdmResponses)
            {
                this.Log(LogLevel.Warning, "SpdmResponderDevice: max_responses={0} reached, ignoring request 0x{1:X2}",
                    config.MaxSpdmResponses, packet.Payload[1]);
                return;
            }

            byte[] responseMsg;
            try
            {
                responseMsg = spdmHandler.HandleRequest(packet.Payload);
            }
            catch(Exception ex)
            {
                this.Log(LogLevel.Error, "HandleSpdmPacket: handler exception: {0}", ex.Message);
                // Return SPDM ERROR response so exceptions don't propagate and hang the monitor
                responseMsg = new byte[] { packet.Payload[0], 0x7F, 0x05, 0x00 }; // Unspecified error
            }

            if(responseMsg != null)
            {
                spdmResponseCount++;
                SendMctpResponse(packet, MctpPacket.MessageTypeSpdm, responseMsg);
            }
        }

        // MCTP serial MTU (DSP0253): 68 bytes = 4 (transport header) + 64 (message body)
        private const int MctpSerialMtu = 68;
        private const int MctpHeaderSize = 4;
        // Max message body: first fragment includes msg_type byte (63 payload), others don't (64 payload)
        private const int FirstFragMaxPayload = MctpSerialMtu - MctpHeaderSize - 1; // 63
        private const int NextFragMaxPayload = MctpSerialMtu - MctpHeaderSize;      // 64

        private void SendMctpResponse(MctpPacket request, byte messageType, byte[] payload)
        {
            int totalFrameSize = MctpHeaderSize + 1 + (payload != null ? payload.Length : 0);

            if(totalFrameSize <= MctpSerialMtu)
            {
                // Fits in a single frame — no fragmentation needed
                var response = MctpPacket.BuildResponse(request, config.Eid, messageType, payload);
                transport.SendFrame(response.Build());
                return;
            }

            // Fragment the MCTP message per DSP0236 Section 9.4.1
            byte destEid = request.SrcEid;
            byte srcEid = config.Eid;
            byte tag = (byte)(request.FlagsTag & MctpPacket.TagMask);
            int offset = 0;
            int payloadLen = payload != null ? payload.Length : 0;
            byte seq = 0;
            bool first = true;
            int fragCount = 0;

            while(offset < payloadLen)
            {
                int maxChunk = first ? FirstFragMaxPayload : NextFragMaxPayload;
                int chunkSize = Math.Min(payloadLen - offset, maxChunk);
                bool last = (offset + chunkSize >= payloadLen);

                byte flags = (byte)((seq & 0x03) << 4); // Seq in bits [5:4]
                if(first) flags |= MctpPacket.FlagSOM;
                if(last) flags |= MctpPacket.FlagEOM;
                flags |= tag; // bits [2:0], TO=0 (responder clears tag owner)

                byte[] frameData;
                if(first)
                {
                    // First fragment: [header(4)][msg_type(1)][payload_chunk]
                    frameData = new byte[MctpHeaderSize + 1 + chunkSize];
                    frameData[0] = MctpPacket.HeaderVersion;
                    frameData[1] = destEid;
                    frameData[2] = srcEid;
                    frameData[3] = flags;
                    frameData[4] = messageType;
                    if(chunkSize > 0)
                    {
                        Array.Copy(payload, offset, frameData, 5, chunkSize);
                    }
                }
                else
                {
                    // Continuation fragment: [header(4)][payload_chunk] (no msg_type)
                    frameData = new byte[MctpHeaderSize + chunkSize];
                    frameData[0] = MctpPacket.HeaderVersion;
                    frameData[1] = destEid;
                    frameData[2] = srcEid;
                    frameData[3] = flags;
                    if(chunkSize > 0)
                    {
                        Array.Copy(payload, offset, frameData, 4, chunkSize);
                    }
                }

                transport.SendFrame(frameData);
                offset += chunkSize;
                seq = (byte)((seq + 1) & 0x03);
                first = false;
                fragCount++;
            }

            this.Log(LogLevel.Debug, "MCTP serial: fragmented {0} byte message into {1} frames",
                payloadLen + 1, fragCount);
        }
    }
}
