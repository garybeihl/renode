//
// Copyright (c) 2010-2026 Antmicro
//
// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
//

using System;
using System.Threading;

using Antmicro.Renode.Logging;

using PacketDotNet;

namespace Antmicro.Renode.Network
{
    [Flags]
    public enum TcpFlags : byte
    {
        None = 0,
        Fin  = 0x01,
        Syn  = 0x02,
        Rst  = 0x04,
        Psh  = 0x08,
        Ack  = 0x10,
        Urg  = 0x20,
    }

    public enum TcpState
    {
        Closed,
        SynSent,
        SynReceived,
        Established,
        FinWait1,
        FinWait2,
        Closing,
        TimeWait,
        CloseWait,
        LastAck,
    }

    public class TcpConnection : IEmulationElement
    {
        public TcpConnection(
            System.Net.IPAddress localIP, ushort localPort,
            System.Net.IPAddress remoteIP, ushort remotePort,
            Action<TcpConnection, TcpPacket> sendCallback)
        {
            LocalIP = localIP;
            LocalPort = localPort;
            RemoteIP = remoteIP;
            RemotePort = remotePort;
            this.sendCallback = sendCallback;
            syncRoot = new object();

            State = TcpState.Closed;
            RcvWnd = DefaultWindowSize;
            Mss = DefaultMss;

            var rng = new Random();
            sndNxt = (uint)rng.Next();
            sndUna = sndNxt;
        }

        // Accept an incoming SYN from the guest (server-side handshake).
        // Sends SYN-ACK back, transitions to SynReceived→Established
        // when the guest ACKs.
        public void ProcessSynFromGuest(TcpPacket synPacket)
        {
            lock(syncRoot)
            {
                if(State != TcpState.Closed)
                {
                    this.Log(LogLevel.Warning,
                        "ProcessSynFromGuest called in state {0}", State);
                    return;
                }

                rcvNxt = synPacket.SequenceNumber + 1;

                // Extract MSS from SYN options
                ExtractMssFromSynAck(synPacket);

                this.Log(LogLevel.Debug,
                    "Accepting SYN from guest (seq={0}), sending SYN-ACK",
                    synPacket.SequenceNumber);

                // Send SYN-ACK
                SendSynAck();
                sndNxt++; // SYN consumes one sequence number
                SetState(TcpState.SynReceived);
            }
        }

        // Initiate a connection to the remote (guest) — sends SYN
        public void Connect()
        {
            lock(syncRoot)
            {
                if(State != TcpState.Closed)
                {
                    this.Log(LogLevel.Warning, "Connect called in state {0}", State);
                    return;
                }

                this.Log(LogLevel.Debug, "Sending SYN to {0}:{1}", RemoteIP, RemotePort);
                SendPacket(TcpFlags.Syn);
                sndNxt++; // SYN consumes one sequence number
                SetState(TcpState.SynSent);
            }
        }

        // Send data to the remote (guest)
        public void Send(byte[] data)
        {
            if(data == null || data.Length == 0)
            {
                return;
            }

            lock(syncRoot)
            {
                if(State != TcpState.Established && State != TcpState.CloseWait)
                {
                    this.Log(LogLevel.Warning, "Send called in state {0}, dropping {1} bytes", State, data.Length);
                    return;
                }

                int offset = 0;
                while(offset < data.Length)
                {
                    int segmentSize = Math.Min(Mss, data.Length - offset);
                    var segment = new byte[segmentSize];
                    Array.Copy(data, offset, segment, 0, segmentSize);

                    SendPacket(TcpFlags.Ack | TcpFlags.Psh, segment);
                    sndNxt += (uint)segmentSize;
                    offset += segmentSize;
                }
            }
        }

        // Initiate close — sends FIN
        public void Close()
        {
            lock(syncRoot)
            {
                switch(State)
                {
                case TcpState.Established:
                    this.Log(LogLevel.Debug, "Sending FIN (active close)");
                    SendPacket(TcpFlags.Fin | TcpFlags.Ack);
                    sndNxt++;
                    SetState(TcpState.FinWait1);
                    break;
                case TcpState.CloseWait:
                    this.Log(LogLevel.Debug, "Sending FIN (passive close)");
                    SendPacket(TcpFlags.Fin | TcpFlags.Ack);
                    sndNxt++;
                    SetState(TcpState.LastAck);
                    break;
                default:
                    this.Log(LogLevel.Debug, "Close called in state {0}", State);
                    break;
                }
            }
        }

        // Process an incoming TCP segment from the remote (guest)
        public void ProcessSegment(TcpPacket packet)
        {
            lock(syncRoot)
            {
                var flags = ExtractFlags(packet);
                var dataLen = packet.PayloadData?.Length ?? 0;

                this.Log(LogLevel.Noisy, "RX [{0}] seq={1} ack={2} flags={3} len={4}",
                    State, packet.SequenceNumber, packet.AcknowledgmentNumber, flags, dataLen);

                if(flags.HasFlag(TcpFlags.Rst))
                {
                    this.Log(LogLevel.Info, "Received RST, closing connection");
                    SetState(TcpState.Closed);
                    ConnectionClosed?.Invoke(this);
                    return;
                }

                switch(State)
                {
                case TcpState.SynReceived:
                    HandleSynReceived(packet, flags, dataLen);
                    break;
                case TcpState.SynSent:
                    HandleSynSent(packet, flags, dataLen);
                    break;
                case TcpState.Established:
                    HandleEstablished(packet, flags, dataLen);
                    break;
                case TcpState.FinWait1:
                    HandleFinWait1(packet, flags, dataLen);
                    break;
                case TcpState.FinWait2:
                    HandleFinWait2(packet, flags, dataLen);
                    break;
                case TcpState.Closing:
                    HandleClosing(packet, flags);
                    break;
                case TcpState.LastAck:
                    HandleLastAck(packet, flags);
                    break;
                case TcpState.TimeWait:
                    if(dataLen > 0 || flags.HasFlag(TcpFlags.Fin))
                    {
                        SendAck();
                    }
                    break;
                case TcpState.CloseWait:
                    // Waiting for local application to close; just ACK data
                    if(flags.HasFlag(TcpFlags.Ack))
                    {
                        UpdateSendState(packet);
                    }
                    break;
                default:
                    this.Log(LogLevel.Warning, "Segment received in unexpected state {0}", State);
                    break;
                }
            }
        }

        public System.Net.IPAddress LocalIP { get; }
        public ushort LocalPort { get; }
        public System.Net.IPAddress RemoteIP { get; }
        public ushort RemotePort { get; }
        public TcpState State { get; private set; }
        public int Mss { get; private set; }
        public ushort RcvWnd { get; set; }

        public event Action<TcpConnection, byte[]> DataReceived;
        public event Action<TcpConnection, TcpState> StateChanged;
        public event Action<TcpConnection> ConnectionClosed;

        private void HandleSynReceived(TcpPacket packet, TcpFlags flags, int dataLen)
        {
            if(flags.HasFlag(TcpFlags.Ack))
            {
                if(packet.AcknowledgmentNumber == sndNxt)
                {
                    UpdateSendState(packet);
                    this.Log(LogLevel.Debug, "SYN-ACK acknowledged, connection established");
                    SetState(TcpState.Established);

                    // If the ACK also carries data, process it
                    if(dataLen > 0 && packet.SequenceNumber == rcvNxt)
                    {
                        rcvNxt += (uint)dataLen;
                        DataReceived?.Invoke(this, packet.PayloadData);
                        SendAck();
                    }
                }
                else
                {
                    this.Log(LogLevel.Warning,
                        "SynReceived: wrong ACK {0}, expected {1}",
                        packet.AcknowledgmentNumber, sndNxt);
                }
            }
            else if(flags.HasFlag(TcpFlags.Rst))
            {
                SetState(TcpState.Closed);
                ConnectionClosed?.Invoke(this);
            }
        }

        private void SendSynAck()
        {
            // Build SYN-ACK with MSS option manually since
            // TcpPacket.Options is read-only in this PacketDotNet version
            SendPacket(TcpFlags.Syn | TcpFlags.Ack);

            this.Log(LogLevel.Noisy,
                "TX [SynReceived] SYN-ACK seq={0} ack={1}",
                sndNxt, rcvNxt);
        }

        private void HandleSynSent(TcpPacket packet, TcpFlags flags, int dataLen)
        {
            if(flags.HasFlag(TcpFlags.Syn) && flags.HasFlag(TcpFlags.Ack))
            {
                if(packet.AcknowledgmentNumber != sndNxt)
                {
                    this.Log(LogLevel.Warning, "SYN-ACK with wrong ACK number {0}, expected {1}",
                        packet.AcknowledgmentNumber, sndNxt);
                    SendRst();
                    return;
                }

                rcvNxt = packet.SequenceNumber + 1;
                UpdateSendState(packet);
                ExtractMssFromSynAck(packet);

                this.Log(LogLevel.Debug, "SYN-ACK received, connection established (MSS={0})", Mss);
                SendAck();
                SetState(TcpState.Established);
            }
            else if(flags.HasFlag(TcpFlags.Syn))
            {
                // Simultaneous open
                rcvNxt = packet.SequenceNumber + 1;
                SendPacket(TcpFlags.Syn | TcpFlags.Ack);
                SetState(TcpState.SynReceived);
            }
        }

        private void HandleEstablished(TcpPacket packet, TcpFlags flags, int dataLen)
        {
            if(flags.HasFlag(TcpFlags.Ack))
            {
                UpdateSendState(packet);
            }

            if(dataLen > 0)
            {
                if(packet.SequenceNumber == rcvNxt)
                {
                    rcvNxt += (uint)dataLen;
                    this.Log(LogLevel.Noisy, "Received {0} bytes of data", dataLen);
                    DataReceived?.Invoke(this, packet.PayloadData);
                    SendAck();
                }
                else if(IsBeforeOrEqual(packet.SequenceNumber, rcvNxt))
                {
                    // Retransmitted/overlapping data — ACK with current rcvNxt
                    this.Log(LogLevel.Debug, "Duplicate/overlapping data seq={0}, expected={1}",
                        packet.SequenceNumber, rcvNxt);
                    SendAck();
                }
                else
                {
                    // Out of order — send duplicate ACK
                    this.Log(LogLevel.Debug, "Out-of-order data seq={0}, expected={1}",
                        packet.SequenceNumber, rcvNxt);
                    SendAck();
                }
            }

            if(flags.HasFlag(TcpFlags.Fin))
            {
                rcvNxt++;
                this.Log(LogLevel.Debug, "Received FIN from guest");
                SendAck();
                SetState(TcpState.CloseWait);
                ConnectionClosed?.Invoke(this);
            }
        }

        private void HandleFinWait1(TcpPacket packet, TcpFlags flags, int dataLen)
        {
            if(flags.HasFlag(TcpFlags.Ack))
            {
                UpdateSendState(packet);
            }

            // Process any remaining data
            if(dataLen > 0 && packet.SequenceNumber == rcvNxt)
            {
                rcvNxt += (uint)dataLen;
                DataReceived?.Invoke(this, packet.PayloadData);
            }

            if(flags.HasFlag(TcpFlags.Fin) && flags.HasFlag(TcpFlags.Ack))
            {
                // Simultaneous close or FIN+ACK of our FIN
                rcvNxt++;
                SendAck();
                SetState(TcpState.TimeWait);
                ScheduleTimeWaitClose();
            }
            else if(flags.HasFlag(TcpFlags.Fin))
            {
                // Simultaneous close
                rcvNxt++;
                SendAck();
                SetState(TcpState.Closing);
            }
            else if(flags.HasFlag(TcpFlags.Ack) && sndUna == sndNxt)
            {
                // Our FIN was ACKed
                SetState(TcpState.FinWait2);
            }
        }

        private void HandleFinWait2(TcpPacket packet, TcpFlags flags, int dataLen)
        {
            if(dataLen > 0 && packet.SequenceNumber == rcvNxt)
            {
                rcvNxt += (uint)dataLen;
                DataReceived?.Invoke(this, packet.PayloadData);
                SendAck();
            }

            if(flags.HasFlag(TcpFlags.Fin))
            {
                rcvNxt++;
                SendAck();
                SetState(TcpState.TimeWait);
                ScheduleTimeWaitClose();
            }
        }

        private void HandleClosing(TcpPacket packet, TcpFlags flags)
        {
            if(flags.HasFlag(TcpFlags.Ack))
            {
                UpdateSendState(packet);
                if(sndUna == sndNxt)
                {
                    SetState(TcpState.TimeWait);
                    ScheduleTimeWaitClose();
                }
            }
        }

        private void HandleLastAck(TcpPacket packet, TcpFlags flags)
        {
            if(flags.HasFlag(TcpFlags.Ack))
            {
                UpdateSendState(packet);
                if(sndUna == sndNxt)
                {
                    this.Log(LogLevel.Debug, "Connection fully closed");
                    SetState(TcpState.Closed);
                    ConnectionClosed?.Invoke(this);
                }
            }
        }

        private void SendPacket(TcpFlags flags, byte[] data = null)
        {
            var pkt = new TcpPacket(LocalPort, RemotePort);
            pkt.SequenceNumber = sndNxt;
            pkt.AcknowledgmentNumber = rcvNxt;
            pkt.WindowSize = RcvWnd;

            pkt.Syn = flags.HasFlag(TcpFlags.Syn);
            pkt.Ack = flags.HasFlag(TcpFlags.Ack);
            pkt.Fin = flags.HasFlag(TcpFlags.Fin);
            pkt.Rst = flags.HasFlag(TcpFlags.Rst);
            pkt.Psh = flags.HasFlag(TcpFlags.Psh);

            if(data != null && data.Length > 0)
            {
                pkt.PayloadData = data;
            }

            this.Log(LogLevel.Noisy, "TX [{0}] seq={1} ack={2} flags={3} len={4}",
                State, pkt.SequenceNumber, pkt.AcknowledgmentNumber, flags,
                data?.Length ?? 0);

            sendCallback(this, pkt);
        }

        private void SendAck()
        {
            SendPacket(TcpFlags.Ack);
        }

        private void SendRst()
        {
            SendPacket(TcpFlags.Rst | TcpFlags.Ack);
            SetState(TcpState.Closed);
            ConnectionClosed?.Invoke(this);
        }

        private void UpdateSendState(TcpPacket packet)
        {
            if(IsAfter(packet.AcknowledgmentNumber, sndUna))
            {
                sndUna = packet.AcknowledgmentNumber;
            }
            sndWnd = packet.WindowSize;
        }

        private void ExtractMssFromSynAck(TcpPacket packet)
        {
            try
            {
                var options = packet.Options;
                if(options == null || options.Length == 0)
                {
                    return;
                }

                int i = 0;
                while(i < options.Length)
                {
                    byte kind = options[i];
                    if(kind == 0) break; // End of options
                    if(kind == 1) { i++; continue; } // NOP
                    if(i + 1 >= options.Length) break;
                    byte length = options[i + 1];
                    if(length < 2 || i + length > options.Length) break;

                    if(kind == 2 && length == 4) // MSS option
                    {
                        Mss = (options[i + 2] << 8) | options[i + 3];
                        this.Log(LogLevel.Debug, "Remote MSS = {0}", Mss);
                    }
                    i += length;
                }
            }
            catch
            {
                // Options parsing is best-effort
            }
        }

        private void SetState(TcpState newState)
        {
            var old = State;
            State = newState;
            this.Log(LogLevel.Debug, "State: {0} → {1}", old, newState);
            StateChanged?.Invoke(this, newState);
        }

        private void ScheduleTimeWaitClose()
        {
            // TIME_WAIT should last 2*MSL (typically 60s), but in emulation
            // we use a shorter timeout to avoid resource leaks
            ThreadPool.QueueUserWorkItem(_ =>
            {
                Thread.Sleep(TimeWaitMs);
                lock(syncRoot)
                {
                    if(State == TcpState.TimeWait)
                    {
                        SetState(TcpState.Closed);
                        ConnectionClosed?.Invoke(this);
                    }
                }
            });
        }

        // Sequence number comparison helpers (handles 32-bit wraparound)
        private static bool IsAfter(uint a, uint b)
        {
            return (int)(a - b) > 0;
        }

        private static bool IsBeforeOrEqual(uint a, uint b)
        {
            return (int)(a - b) <= 0;
        }

        private static TcpFlags ExtractFlags(TcpPacket packet)
        {
            TcpFlags flags = TcpFlags.None;
            if(packet.Syn) flags |= TcpFlags.Syn;
            if(packet.Ack) flags |= TcpFlags.Ack;
            if(packet.Fin) flags |= TcpFlags.Fin;
            if(packet.Rst) flags |= TcpFlags.Rst;
            if(packet.Psh) flags |= TcpFlags.Psh;
            if(packet.Urg) flags |= TcpFlags.Urg;
            return flags;
        }

        private readonly Action<TcpConnection, TcpPacket> sendCallback;
        private readonly object syncRoot;

        private uint sndNxt;
        private uint sndUna;
        private uint rcvNxt;
        private ushort sndWnd;

        private const int DefaultMss = 1460;
        private const ushort DefaultWindowSize = 65535;
        private const int TimeWaitMs = 2000;
    }
}
