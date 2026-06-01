//
// Copyright (c) 2026 Microsoft
//
// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
//
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;

namespace Antmicro.Renode.Integrations
{
    public static class SpdmTcpResponderDeviceExtensions
    {
        public static void CreateSpdmTcpResponderDevice(this Emulation emulation,
            string name, int port, string scenarioPath = null, string keyDir = null,
            string bindAddress = "127.0.0.1")
        {
            emulation.ExternalsManager.AddExternal(
                new SpdmTcpResponderDevice(port, bindAddress, scenarioPath, keyDir), name);
        }
    }

    // Renode-internal SPDM responder device that listens on a TCP port and
    // speaks the DSP0287 SPDM-over-TCP binding (v1.0.0).  Sits next to the
    // MCTP-based SpdmResponderDevice and re-uses the same transport-agnostic
    // SpdmProtocolHandler + SpdmScenarioConfig.
    //
    // Usage in .resc or Robot Framework:
    //   emulation CreateSpdmTcpResponderDevice "spdm_tcp" 2323 @scenario.json "/path/to/keys"
    //
    // The guest BMC reaches this listener via Renode's user-mode NAT proxy
    // (NatProxy.cs) when spdmd opens a TCP connection to the gateway IP on
    // the same port number.
    public class SpdmTcpResponderDevice : IExternal, IDisposable
    {
        // ---- DSP0287 SPDM TCP binding header (spec-compliant) ----
        //   uint16_t payload_length;   // little-endian, bytes after the header
        //   uint8_t  binding_version;  // 0x01
        //   uint8_t  message_type;
        private const int BindingHeaderSize = 4;
        private const byte BindingVersion = 0x01;

        // DSP0287 message types from spdm_tcp_binding.h
        private const byte MessageTypeOutOfSession = 0x05;
        private const byte MessageTypeInSession = 0x06;
        private const byte MessageTypeRoleInquiry = 0xBF;
        private const byte MessageTypeErrorNotSupported = 0xC1;
        private const byte MessageTypeErrorCannotOperateAsResponder = 0xC3;

        // ---- spdm_emu legacy "platform header" wrapper (NOT DSP0287) ----
        // DMTF/spdm-emu's existing TCP-socket framing, pre-dating DSP0287.
        // OpenBMC spdmd's tcp_helper.hpp uses this wrapper to interop with
        // spdm_responder_emu during testing.  See memory note
        // spdm-tcp-dsp0287-compliance-gap for the upstream fix tracking.
        //
        // On-wire layout:
        //   uint32_t command;          // big-endian, e.g. NORMAL=0x0001
        //   uint32_t transport_type;   // big-endian, TCP=0x0003
        //   uint32_t payload_size;     // big-endian, bytes that follow
        //   uint8_t  payload[payload_size];
        //
        // The payload is whatever the inner transport produces.  For
        // libspdm-over-TCP that's typically the 4-byte DSP0287 binding
        // header + SPDM message; for libspdm-over-MCTP-over-TCP-test it
        // would be MCTP framing.  We pass the payload through to the
        // SPDM protocol handler unchanged after stripping the DSP0287
        // binding header — the handler expects raw SPDM bytes.
        private const int PlatformHeaderSize = 12;
        private const uint SocketCmdNormal = 0x00000001;
        private const uint SocketCmdContinue = 0x0000FFFD;
        private const uint SocketCmdShutdown = 0x0000FFFE;
        private const uint SocketTransportTcp = 0x00000003;

        // Max payload we'll accept on the wire — guards against a runaway
        // length field allocating gigabytes.  Real SPDM messages are well
        // under this; pick something that comfortably covers a CERT chain
        // plus the secured-message envelope.
        private const int MaxPayloadSize = 16 * 1024;

        private readonly SpdmScenarioConfig config;
        private readonly SpdmProtocolHandler spdmHandler;
        private readonly int port;
        private readonly IPAddress bindIp;

        private TcpListener listener;
        private Thread acceptThread;
        private readonly List<Thread> connectionThreads = new List<Thread>();
        private readonly object connectionThreadsLock = new object();
        private volatile bool stopping;

        public SpdmTcpResponderDevice(int port, string bindAddress = "127.0.0.1",
            string scenarioPath = null, string keyDir = null)
        {
            this.port = port;
            this.bindIp = IPAddress.Parse(bindAddress);

            if(!string.IsNullOrEmpty(scenarioPath))
            {
                config = SpdmScenarioConfig.LoadFromFile(scenarioPath, keyDir);
                this.Log(LogLevel.Info,
                    "SpdmTcpResponderDevice: loaded scenario from {0}", scenarioPath);
            }
            else
            {
                config = SpdmScenarioConfig.LoadDefaults();
                this.Log(LogLevel.Info,
                    "SpdmTcpResponderDevice: using default scenario");
            }

            spdmHandler = new SpdmProtocolHandler(config, this);
            this.Log(LogLevel.Info,
                "SpdmTcpResponderDevice: EID={0}, name={1}, measurements={2}, listening on {3}:{4}",
                config.Eid, config.Name, config.Measurements.Count, bindAddress, port);

            Start();
        }

        private void Start()
        {
            listener = new TcpListener(bindIp, port);
            listener.Start();

            acceptThread = new Thread(AcceptLoop)
            {
                IsBackground = true,
                Name = $"SpdmTcpResponderDevice-accept-{port}",
            };
            acceptThread.Start();
        }

        private void AcceptLoop()
        {
            while(!stopping)
            {
                TcpClient client;
                try
                {
                    client = listener.AcceptTcpClient();
                }
                catch(SocketException) when(stopping)
                {
                    return;
                }
                catch(ObjectDisposedException)
                {
                    return;
                }
                catch(Exception ex)
                {
                    this.Log(LogLevel.Error,
                        "SpdmTcpResponderDevice: accept failed: {0}", ex.Message);
                    return;
                }

                var connThread = new Thread(() => HandleConnection(client))
                {
                    IsBackground = true,
                    Name = $"SpdmTcpResponderDevice-conn-{port}",
                };

                lock(connectionThreadsLock)
                {
                    connectionThreads.Add(connThread);
                }

                connThread.Start();
            }
        }

        private void HandleConnection(TcpClient client)
        {
            var remote = client.Client.RemoteEndPoint?.ToString() ?? "<unknown>";
            this.Log(LogLevel.Debug,
                "SpdmTcpResponderDevice: connection from {0}", remote);

            // Auto-detect protocol on first read.  The first 4 bytes are
            // either a spdm_emu "command" field (BE u32, value 0x0000_00XX)
            // or a DSP0287 binding header (payload_length:2 LE + version:1
            // + type:1; version is always 0x01 so byte[2] = 0x01).  These
            // patterns are easy to distinguish: spdm_emu commands start
            // with [00 00], DSP0287 headers don't.
            bool usePlatformWrapper = false;
            bool detected = false;

            try
            {
                using(client)
                using(var stream = client.GetStream())
                {
                    while(!stopping)
                    {
                        var firstWord = ReadExactly(stream, 4);
                        if(firstWord == null)
                        {
                            return;
                        }

                        if(!detected)
                        {
                            // Big-endian u32 starting with 0x00 0x00 is a
                            // spdm_emu command field.  DSP0287 binding
                            // headers never have that pattern (version
                            // byte is at offset 2, always 0x01).
                            usePlatformWrapper =
                                firstWord[0] == 0x00 && firstWord[1] == 0x00;
                            this.Log(LogLevel.Info,
                                "SpdmTcpResponderDevice: detected protocol from {0}: {1}",
                                remote,
                                usePlatformWrapper
                                    ? "spdm_emu legacy wrapper"
                                    : "DSP0287 binding header");
                            detected = true;
                        }

                        if(usePlatformWrapper)
                        {
                            if(!HandlePlatformFrame(stream, firstWord, remote))
                            {
                                return;
                            }
                        }
                        else
                        {
                            if(!HandleDsp0287Frame(stream, firstWord, remote))
                            {
                                return;
                            }
                        }
                    }
                }
            }
            catch(IOException ex)
            {
                this.Log(LogLevel.Debug,
                    "SpdmTcpResponderDevice: I/O error from {0}: {1}", remote, ex.Message);
            }
            catch(Exception ex)
            {
                this.Log(LogLevel.Error,
                    "SpdmTcpResponderDevice: unhandled exception on connection from {0}: {1}",
                    remote, ex);
            }
            finally
            {
                this.Log(LogLevel.Debug,
                    "SpdmTcpResponderDevice: connection from {0} closed", remote);
            }
        }

        // DSP0287 single-frame handler.  Returns true to keep the
        // connection alive, false to close.
        private bool HandleDsp0287Frame(NetworkStream stream, byte[] header, string remote)
        {
            int payloadLen = header[0] | (header[1] << 8);
            byte version = header[2];
            byte msgType = header[3];

            if(version != BindingVersion)
            {
                this.Log(LogLevel.Warning,
                    "SpdmTcpResponderDevice: unsupported binding version 0x{0:X2} from {1}, closing",
                    version, remote);
                return false;
            }

            if(payloadLen < 0 || payloadLen > MaxPayloadSize)
            {
                this.Log(LogLevel.Warning,
                    "SpdmTcpResponderDevice: payload length {0} from {1} out of range, closing",
                    payloadLen, remote);
                return false;
            }

            byte[] payload = null;
            if(payloadLen > 0)
            {
                payload = ReadExactly(stream, payloadLen);
                if(payload == null)
                {
                    return false;
                }
            }

            this.Log(LogLevel.Debug,
                "SpdmTcpResponderDevice: rx DSP0287 from {0}: type=0x{1:X2}, payload={2} bytes",
                remote, msgType, payloadLen);

            DispatchMessage(stream, msgType, payload);
            return true;
        }

        // spdm_emu legacy wrapper single-frame handler.  Frame layout:
        //   [4 BE: command][4 BE: transport_type][4 BE: payload_size][payload]
        //
        // For NORMAL TCP traffic the payload is libspdm's TCP transport
        // output: [4 LE DSP0287 binding header][SPDM message].  We strip
        // both layers, hand the raw SPDM to the protocol handler, then
        // rewrap the response in both layers for the reply.
        //
        // Returns true to keep the connection alive, false to close.
        private bool HandlePlatformFrame(NetworkStream stream, byte[] cmdBytes, string remote)
        {
            uint command = ReadBeU32(cmdBytes, 0);

            var transportBytes = ReadExactly(stream, 4);
            if(transportBytes == null) return false;
            uint transportType = ReadBeU32(transportBytes, 0);

            var sizeBytes = ReadExactly(stream, 4);
            if(sizeBytes == null) return false;
            long payloadSize = ReadBeU32(sizeBytes, 0);

            this.Log(LogLevel.Debug,
                "SpdmTcpResponderDevice: rx platform from {0}: cmd=0x{1:X8}, transport=0x{2:X8}, size={3}",
                remote, command, transportType, payloadSize);

            if(transportType != SocketTransportTcp)
            {
                this.Log(LogLevel.Warning,
                    "SpdmTcpResponderDevice: unsupported transport_type 0x{0:X8}, expected TCP (0x{1:X8})",
                    transportType, SocketTransportTcp);
                return false;
            }

            if(payloadSize < 0 || payloadSize > MaxPayloadSize)
            {
                this.Log(LogLevel.Warning,
                    "SpdmTcpResponderDevice: platform payload_size {0} out of range, closing",
                    payloadSize);
                return false;
            }

            byte[] payload = null;
            if(payloadSize > 0)
            {
                payload = ReadExactly(stream, (int)payloadSize);
                if(payload == null) return false;
            }

            if(command == SocketCmdShutdown)
            {
                this.Log(LogLevel.Info,
                    "SpdmTcpResponderDevice: SHUTDOWN from {0}", remote);
                return false;
            }

            if(command != SocketCmdNormal && command != SocketCmdContinue)
            {
                this.Log(LogLevel.Warning,
                    "SpdmTcpResponderDevice: unsupported platform command 0x{0:X8}",
                    command);
                return false;
            }

            // payload should start with the DSP0287 binding header
            // produced by libspdm_transport_tcp_encode_message.
            if(payload == null || payload.Length < BindingHeaderSize)
            {
                this.Log(LogLevel.Warning,
                    "SpdmTcpResponderDevice: platform payload too short for DSP0287 header ({0} bytes)",
                    payload?.Length ?? 0);
                return false;
            }

            // Debug: dump first 32 bytes of the inner payload
            int dumpLen = Math.Min(payload.Length, 32);
            var hex = new System.Text.StringBuilder();
            for(int i = 0; i < dumpLen; i++)
            {
                hex.AppendFormat("{0:X2} ", payload[i]);
            }
            this.Log(LogLevel.Info,
                "SpdmTcpResponderDevice: inner payload ({0}B): {1}",
                payload.Length, hex.ToString().TrimEnd());

            int innerPayloadLen = payload[0] | (payload[1] << 8);
            byte innerVersion = payload[2];
            byte innerMsgType = payload[3];

            if(innerVersion != BindingVersion)
            {
                this.Log(LogLevel.Warning,
                    "SpdmTcpResponderDevice: inner DSP0287 version 0x{0:X2} unsupported",
                    innerVersion);
                return false;
            }

            // Use the platform header's payload_size as source-of-truth
            // for the actual byte count.  libspdm's binding-header
            // payload_length field has been observed to include space
            // reserved for the secured-message cipher header even when
            // unused — trust the outer size.
            int spdmLen = payload.Length - BindingHeaderSize;
            byte[] spdm = null;
            if(spdmLen > 0)
            {
                spdm = new byte[spdmLen];
                Array.Copy(payload, BindingHeaderSize, spdm, 0, spdmLen);
            }
            this.Log(LogLevel.Info,
                "SpdmTcpResponderDevice: binding hdr says payload_len={0}, taking {1} bytes from outer wrapper, msg_type=0x{2:X2}",
                innerPayloadLen, spdmLen, innerMsgType);

            byte[] spdmResponse = null;
            byte responseMsgType = innerMsgType;

            switch(innerMsgType)
            {
                case MessageTypeRoleInquiry:
                    // Echo with zero-length payload.
                    spdmResponse = null;
                    responseMsgType = MessageTypeRoleInquiry;
                    break;

                case MessageTypeOutOfSession:
                    if(spdm == null || spdm.Length < 4)
                    {
                        this.Log(LogLevel.Warning,
                            "SpdmTcpResponderDevice: SPDM payload too short ({0} bytes)",
                            spdm?.Length ?? 0);
                        return false;
                    }
                    try
                    {
                        spdmResponse = spdmHandler.HandleRequest(spdm);
                    }
                    catch(Exception ex)
                    {
                        this.Log(LogLevel.Error,
                            "SpdmTcpResponderDevice: handler exception: {0}", ex.Message);
                        spdmResponse = new byte[] { spdm[0], 0x7F, 0x05, 0x00 };
                    }
                    responseMsgType = MessageTypeOutOfSession;
                    break;

                case MessageTypeInSession:
                    this.Log(LogLevel.Warning,
                        "SpdmTcpResponderDevice: IN_SESSION not supported");
                    spdmResponse = null;
                    responseMsgType = MessageTypeErrorNotSupported;
                    break;

                default:
                    this.Log(LogLevel.Warning,
                        "SpdmTcpResponderDevice: unknown inner msg_type 0x{0:X2}",
                        innerMsgType);
                    spdmResponse = null;
                    responseMsgType = MessageTypeErrorNotSupported;
                    break;
            }

            // Wrap response: DSP0287 binding then platform wrapper.
            int respLen = spdmResponse?.Length ?? 0;
            var dsp0287Frame = new byte[BindingHeaderSize + respLen];
            dsp0287Frame[0] = (byte)(respLen & 0xFF);
            dsp0287Frame[1] = (byte)((respLen >> 8) & 0xFF);
            dsp0287Frame[2] = BindingVersion;
            dsp0287Frame[3] = responseMsgType;
            if(respLen > 0)
            {
                Array.Copy(spdmResponse, 0, dsp0287Frame,
                    BindingHeaderSize, respLen);
            }

            SendPlatformWrapped(stream, SocketCmdNormal, dsp0287Frame);
            return true;
        }

        private static uint ReadBeU32(byte[] buf, int offset)
        {
            return ((uint)buf[offset] << 24) |
                   ((uint)buf[offset + 1] << 16) |
                   ((uint)buf[offset + 2] << 8) |
                   buf[offset + 3];
        }

        private static void WriteBeU32(byte[] buf, int offset, uint value)
        {
            buf[offset] = (byte)((value >> 24) & 0xFF);
            buf[offset + 1] = (byte)((value >> 16) & 0xFF);
            buf[offset + 2] = (byte)((value >> 8) & 0xFF);
            buf[offset + 3] = (byte)(value & 0xFF);
        }

        private void SendPlatformWrapped(NetworkStream stream, uint command,
            byte[] payload)
        {
            int payloadLen = payload?.Length ?? 0;
            var frame = new byte[PlatformHeaderSize + payloadLen];
            WriteBeU32(frame, 0, command);
            WriteBeU32(frame, 4, SocketTransportTcp);
            WriteBeU32(frame, 8, (uint)payloadLen);
            if(payloadLen > 0)
            {
                Array.Copy(payload, 0, frame, PlatformHeaderSize, payloadLen);
            }
            try
            {
                stream.Write(frame, 0, frame.Length);
            }
            catch(IOException ex)
            {
                this.Log(LogLevel.Debug,
                    "SpdmTcpResponderDevice: platform write failed: {0}", ex.Message);
                throw;
            }
            this.Log(LogLevel.Debug,
                "SpdmTcpResponderDevice: tx platform cmd=0x{0:X8}, inner={1} bytes",
                command, payloadLen);
        }

        private void DispatchMessage(NetworkStream stream, byte msgType, byte[] payload)
        {
            switch(msgType)
            {
                case MessageTypeRoleInquiry:
                    // DSP0287: peer asks "what role are you?" — echo the
                    // same message type back to confirm we're a responder.
                    // No SPDM payload.
                    SendFramed(stream, MessageTypeRoleInquiry, null);
                    break;

                case MessageTypeOutOfSession:
                    HandleSpdmPayload(stream, payload);
                    break;

                case MessageTypeInSession:
                    // Secured-session traffic isn't implemented in this
                    // responder yet.  Tell the requester so it doesn't
                    // wait for a response that will never come.
                    this.Log(LogLevel.Warning,
                        "SpdmTcpResponderDevice: IN_SESSION (0x06) not supported");
                    SendFramed(stream, MessageTypeErrorNotSupported, null);
                    break;

                default:
                    if(msgType >= 0xC0)
                    {
                        // Requester is reporting an error condition (0xC0-0xFF).
                        // Log it; nothing more we can do here.
                        this.Log(LogLevel.Warning,
                            "SpdmTcpResponderDevice: requester error 0x{0:X2} received",
                            msgType);
                    }
                    else
                    {
                        this.Log(LogLevel.Warning,
                            "SpdmTcpResponderDevice: unknown message type 0x{0:X2}",
                            msgType);
                        SendFramed(stream, MessageTypeErrorNotSupported, null);
                    }
                    break;
            }
        }

        private void HandleSpdmPayload(NetworkStream stream, byte[] payload)
        {
            if(payload == null || payload.Length < 4)
            {
                this.Log(LogLevel.Warning,
                    "SpdmTcpResponderDevice: SPDM payload too short ({0} bytes)",
                    payload?.Length ?? 0);
                return;
            }

            byte[] response;
            try
            {
                response = spdmHandler.HandleRequest(payload);
            }
            catch(Exception ex)
            {
                this.Log(LogLevel.Error,
                    "SpdmTcpResponderDevice: handler exception: {0}", ex.Message);
                // SPDM ERROR (unspecified) so the requester doesn't hang.
                // version byte echoes whatever came in.
                response = new byte[] { payload[0], 0x7F, 0x05, 0x00 };
            }

            if(response != null)
            {
                SendFramed(stream, MessageTypeOutOfSession, response);
            }
        }

        private void SendFramed(NetworkStream stream, byte msgType, byte[] payload)
        {
            int payloadLen = payload?.Length ?? 0;
            var frame = new byte[BindingHeaderSize + payloadLen];
            frame[0] = (byte)(payloadLen & 0xFF);
            frame[1] = (byte)((payloadLen >> 8) & 0xFF);
            frame[2] = BindingVersion;
            frame[3] = msgType;
            if(payloadLen > 0)
            {
                Array.Copy(payload, 0, frame, BindingHeaderSize, payloadLen);
            }

            try
            {
                stream.Write(frame, 0, frame.Length);
            }
            catch(IOException ex)
            {
                this.Log(LogLevel.Debug,
                    "SpdmTcpResponderDevice: write failed: {0}", ex.Message);
                throw;
            }

            this.Log(LogLevel.Debug,
                "SpdmTcpResponderDevice: tx type=0x{0:X2}, payload={1} bytes",
                msgType, payloadLen);
        }

        // Returns null on graceful EOF (peer closed before any byte read).
        // Throws IOException on mid-message disconnect.
        private static byte[] ReadExactly(NetworkStream stream, int count)
        {
            var buf = new byte[count];
            int offset = 0;
            while(offset < count)
            {
                int n;
                try
                {
                    n = stream.Read(buf, offset, count - offset);
                }
                catch(IOException) when(offset == 0)
                {
                    return null;
                }

                if(n == 0)
                {
                    if(offset == 0)
                    {
                        return null;
                    }
                    throw new IOException(
                        $"Peer closed mid-message after {offset}/{count} bytes");
                }
                offset += n;
            }
            return buf;
        }

        public void Dispose()
        {
            stopping = true;
            try
            {
                listener?.Stop();
            }
            catch
            {
                // best-effort
            }

            acceptThread?.Join(TimeSpan.FromSeconds(1));

            Thread[] conns;
            lock(connectionThreadsLock)
            {
                conns = connectionThreads.ToArray();
                connectionThreads.Clear();
            }
            foreach(var t in conns)
            {
                t.Join(TimeSpan.FromSeconds(1));
            }
        }
    }
}
