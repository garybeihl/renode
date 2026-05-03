//
// Copyright (c) 2010-2020 Antmicro
//
// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
//

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Net;
using System.Net.NetworkInformation;

using Antmicro.Renode.Core;
using Antmicro.Renode.Core.Structure;
using Antmicro.Renode.Exceptions;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Network;

using PacketDotNet;

namespace Antmicro.Renode.Network
{
    public static class NetworkServerExtensions
    {
        public static void CreateNetworkServer(this Emulation emulation, string name, string ipAddress)
        {
            emulation.ExternalsManager.AddExternal(new NetworkServer(ipAddress), name);
        }
    }

    public class NetworkServer : IExternal, IMACInterface, IHasChildren<IServerModule>
    {
        public NetworkServer(string ipAddress, string macAddress = null)
        {
            if(!IPAddress.TryParse(ipAddress, out var parsedIP))
            {
                new ConstructionException($"Invalid IP address: {ipAddress}");
            }

            if(macAddress != null)
            {
                if(!MACAddress.TryParse(macAddress, out var parsedMAC))
                {
                    new ConstructionException($"Invalid MAC address: {macAddress}");
                }
                MAC = parsedMAC;
            }
            else
            {
                MAC = new MACAddress(0xdeadbeef);
            }

            IP = parsedIP;

            arpTable = new Dictionary<IPAddress, PhysicalAddress>();
            modules = new Dictionary<int, IServerModule>();
            modulesNames = new Dictionary<string, int>();
            tcpConnections = new ConcurrentDictionary<TcpConnectionKey, TcpConnection>();
            portForwarder = null;

            this.Log(LogLevel.Info, "Network server started at IP {0}", IP);
        }

        public IEnumerable<string> GetNames()
        {
            return modulesNames.Keys;
        }

        public IServerModule TryGetByName(string name, out bool success)
        {
            if(!modulesNames.TryGetValue(name, out var port))
            {
                success = false;
                return null;
            }

            success = true;
            return modules[port];
        }

        public bool RegisterModule(IServerModule module, int port, string name)
        {
            if(modules.ContainsKey(port))
            {
                this.Log(LogLevel.Error, "Couldn't register module on port {0} as it's already used", port);
                return false;
            }

            if(modulesNames.ContainsKey(name))
            {
                this.Log(LogLevel.Error, "Couldn't register module by name {0} as it's already used", name);
                return false;
            }

            this.Log(LogLevel.Noisy, "Registering module on port {0}", port);
            modules[port] = module;
            modulesNames[name] = port;
            return true;
        }

        public void ReceiveFrame(EthernetFrame frame)
        {
            var ethernetPacket = frame.UnderlyingPacket;

            // Ignore our own frames reflected by the switch
            if(ethernetPacket.SourceHwAddress.Equals((PhysicalAddress)MAC))
            {
                return;
            }

            this.Log(LogLevel.Noisy, "Ethernet packet details: {0}", frame);
#if DEBUG_PACKETS
            this.Log(LogLevel.Noisy, Misc.PrettyPrintCollectionHex(frame.Bytes));
#endif

            switch(ethernetPacket.Type)
            {
            case EthernetPacketType.Arp:
                if(TryHandleArp((ARPPacket)ethernetPacket.PayloadPacket, out var arpResponse))
                {
                    var ethernetResponse = new EthernetPacket((PhysicalAddress)MAC, ethernetPacket.SourceHwAddress, EthernetPacketType.None);
                    ethernetResponse.PayloadPacket = arpResponse;

                    this.Log(LogLevel.Noisy, "Sending response: {0}", ethernetResponse);
                    EthernetFrame.TryCreateEthernetFrame(ethernetResponse.Bytes, true, out var response);
                    FrameReady?.Invoke(response);
                }
                break;

            case EthernetPacketType.IpV4:
                var ipv4Packet = (IPv4Packet)ethernetPacket.PayloadPacket;
                arpTable[ipv4Packet.SourceAddress] = ethernetPacket.SourceHwAddress;
                HandleIPv4(ipv4Packet);
                break;

            default:
                this.Log(LogLevel.Warning, "Unsupported packet type: {0}", ethernetPacket.Type);
                break;
            }
        }

        public MACAddress MAC { get; set; }

        public IPAddress IP { get; set; }

        public event Action<EthernetFrame> FrameReady;

        // Create a TCP connection from this server to a guest endpoint.
        // Used by PortForwarder to initiate connections for port forwarding.
        public TcpConnection CreateTcpConnection(ushort localPort, IPAddress remoteIP, ushort remotePort)
        {
            var key = new TcpConnectionKey(IP, localPort, remoteIP, remotePort);
            if(tcpConnections.ContainsKey(key))
            {
                this.Log(LogLevel.Warning, "TCP connection already exists for {0}:{1} → {2}:{3}",
                    IP, localPort, remoteIP, remotePort);
                return null;
            }

            var conn = new TcpConnection(IP, localPort, remoteIP, remotePort, SendTcpPacket);
            tcpConnections[key] = conn;
            this.Log(LogLevel.Debug,
                "Created TCP connection {0}:{1} → {2}:{3} (count={4})",
                IP, localPort, remoteIP, remotePort, tcpConnections.Count);
            return conn;
        }

        public void RemoveTcpConnection(TcpConnection conn)
        {
            var key = new TcpConnectionKey(conn.LocalIP, conn.LocalPort, conn.RemoteIP, conn.RemotePort);
            this.Log(LogLevel.Debug,
                "Removing TCP connection {0}:{1} → {2}:{3} (count before={4})",
                conn.LocalIP, conn.LocalPort, conn.RemoteIP, conn.RemotePort, tcpConnections.Count);
            tcpConnections.TryRemove(key, out _);
        }

        public void StartPortForwarding()
        {
            if(portForwarder == null)
            {
                portForwarder = new PortForwarder(this);
            }
        }

        public void AddPortForward(string hostAddress, int hostPort, string guestAddress, int guestPort)
        {
            StartPortForwarding();
            portForwarder.AddRule(new PortForwardRule
            {
                HostAddress = IPAddress.Parse(hostAddress),
                HostPort = hostPort,
                GuestAddress = IPAddress.Parse(guestAddress),
                GuestPort = guestPort,
            });
        }

        private void HandleIPv4(IPv4Packet packet)
        {
            this.Log(LogLevel.Noisy, "Handling IPv4 packet: {0}", PacketToString(packet));

            switch(packet.Protocol)
            {
            case PacketDotNet.IPProtocolType.UDP:
                HandleUdp((UdpPacket)packet.PayloadPacket);
                break;

            case PacketDotNet.IPProtocolType.TCP:
                HandleTcp(packet);
                break;

            case PacketDotNet.IPProtocolType.ICMP:
                HandleIcmp(packet);
                break;

            default:
                this.Log(LogLevel.Warning, "Unsupported protocol: {0}", packet.Protocol);
                break;
            }
        }

        private void HandleUdp(UdpPacket packet)
        {
            this.Log(LogLevel.Noisy, "Handling UDP packet: {0}", PacketToString(packet));

            if(!modules.TryGetValue(packet.DestinationPort, out var module))
            {
                this.Log(LogLevel.Warning, "Received UDP packet on port {0}, but no service is active", packet.DestinationPort);
                return;
            }

            var src = new IPEndPoint(((IPv4Packet)packet.ParentPacket).SourceAddress, packet.SourcePort);
            module.HandleUdp(src, packet, (s, r) => HandleUdpResponse(s, r));
        }

        private void HandleUdpResponse(IPEndPoint source, UdpPacket response)
        {
            PhysicalAddress destMac;
            IPAddress destIP = source.Address;

            if(destIP.Equals(IPAddress.Broadcast) || !arpTable.TryGetValue(destIP, out destMac))
            {
                // Broadcast (e.g., DHCP) or unknown destination
                destMac = new PhysicalAddress(new byte[] { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
                if(destIP.Equals(IPAddress.Broadcast))
                {
                    destIP = IPAddress.Broadcast;
                }
            }

            var ipPacket = new IPv4Packet(IP, destIP);
            var ethernetPacket = new EthernetPacket((PhysicalAddress)MAC, destMac, EthernetPacketType.None);

            ipPacket.PayloadPacket = response;
            ethernetPacket.PayloadPacket = ipPacket;
            response.UpdateCalculatedValues();

            this.Log(LogLevel.Noisy, "Sending UDP response: {0}", response);

            EthernetFrame.TryCreateEthernetFrame(ethernetPacket.Bytes, true, out var ethernetFrame);
            ethernetFrame.FillWithChecksums(new EtherType[] { EtherType.IpV4 }, new[] { IPProtocolType.UDP });

            FrameReady?.Invoke(ethernetFrame);
        }

        private void HandleTcp(IPv4Packet ipPacket)
        {
            var tcpPacket = (TcpPacket)ipPacket.PayloadPacket;
            if(tcpPacket == null)
            {
                this.Log(LogLevel.Warning, "Failed to parse TCP packet");
                return;
            }

            this.Log(LogLevel.Noisy, "Handling TCP {0}:{1} → {2}:{3}",
                ipPacket.SourceAddress, tcpPacket.SourcePort,
                ipPacket.DestinationAddress, tcpPacket.DestinationPort);

            // Look up existing connection (guest is the "remote" from our perspective)
            var key = new TcpConnectionKey(
                ipPacket.DestinationAddress, tcpPacket.DestinationPort,
                ipPacket.SourceAddress, tcpPacket.SourcePort);

            if(tcpConnections.TryGetValue(key, out var conn))
            {
                conn.ProcessSegment(tcpPacket);
            }
            else
            {
                this.Log(LogLevel.Debug,
                    "TCP lookup miss for {0}:{1} → {2}:{3} (syn={4}, table={5})",
                    ipPacket.DestinationAddress, tcpPacket.DestinationPort,
                    ipPacket.SourceAddress, tcpPacket.SourcePort,
                    tcpPacket.Syn, tcpConnections.Count);

                // No connection found — send RST for non-SYN packets
                if(!tcpPacket.Syn)
                {
                    this.Log(LogLevel.Debug, "No connection for TCP packet, sending RST");
                    SendTcpRst(ipPacket.SourceAddress, tcpPacket.SourcePort,
                        ipPacket.DestinationAddress, tcpPacket.DestinationPort,
                        tcpPacket.AcknowledgmentNumber, tcpPacket.SequenceNumber + 1);
                }
                else if(enableNat && ipPacket.DestinationAddress.Equals(IP))
                {
                    // Guest→host NAT: proxy the connection to the real host
                    HandleNatSyn(ipPacket, tcpPacket);
                }
                else
                {
                    this.Log(LogLevel.Debug, "Incoming SYN but no listener for port {0}", tcpPacket.DestinationPort);
                    SendTcpRst(ipPacket.SourceAddress, tcpPacket.SourcePort,
                        ipPacket.DestinationAddress, tcpPacket.DestinationPort,
                        0, tcpPacket.SequenceNumber + 1);
                }
            }
        }

        private void HandleIcmp(IPv4Packet ipPacket)
        {
            var icmpData = ipPacket.PayloadData;
            if(icmpData == null || icmpData.Length < 8)
            {
                return;
            }

            byte type = icmpData[0];
            if(type != 8) // Echo Request
            {
                this.Log(LogLevel.Noisy, "Ignoring ICMP type {0}", type);
                return;
            }

            this.Log(LogLevel.Debug, "Replying to ICMP echo request from {0}", ipPacket.SourceAddress);

            // Build echo reply: type=0, code=0, recalculate checksum
            var reply = new byte[icmpData.Length];
            Array.Copy(icmpData, reply, icmpData.Length);
            reply[0] = 0; // Echo Reply
            reply[2] = 0; // Clear checksum
            reply[3] = 0;

            // Calculate ICMP checksum
            uint sum = 0;
            for(int i = 0; i < reply.Length - 1; i += 2)
            {
                sum += (uint)((reply[i] << 8) | reply[i + 1]);
            }
            if(reply.Length % 2 != 0)
            {
                sum += (uint)(reply[reply.Length - 1] << 8);
            }
            while((sum >> 16) != 0)
            {
                sum = (sum & 0xFFFF) + (sum >> 16);
            }
            ushort checksum = (ushort)~sum;
            reply[2] = (byte)(checksum >> 8);
            reply[3] = (byte)(checksum & 0xFF);

            var responseIp = new IPv4Packet(IP, ipPacket.SourceAddress);
            responseIp.Protocol = PacketDotNet.IPProtocolType.ICMP;
            responseIp.PayloadData = reply;

            PhysicalAddress destMac;
            if(!arpTable.TryGetValue(ipPacket.SourceAddress, out destMac))
            {
                destMac = new PhysicalAddress(new byte[] { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
            }

            var ethernetPacket = new EthernetPacket((PhysicalAddress)MAC, destMac, EthernetPacketType.None);
            ethernetPacket.PayloadPacket = responseIp;

            EthernetFrame.TryCreateEthernetFrame(ethernetPacket.Bytes, true, out var frame);
            frame.FillWithChecksums(new EtherType[] { EtherType.IpV4 }, new IPProtocolType[] { });

            FrameReady?.Invoke(frame);
        }

        // Callback used by TcpConnection to send a packet to the guest
        private void SendTcpPacket(TcpConnection conn, TcpPacket tcpPacket)
        {
            PhysicalAddress destMac;
            if(!arpTable.TryGetValue(conn.RemoteIP, out destMac))
            {
                this.Log(LogLevel.Warning, "No ARP entry for {0}, using broadcast", conn.RemoteIP);
                destMac = new PhysicalAddress(new byte[] { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
            }

            var ipPacket = new IPv4Packet(conn.LocalIP, conn.RemoteIP);
            var ethernetPacket = new EthernetPacket((PhysicalAddress)MAC, destMac, EthernetPacketType.None);

            ipPacket.PayloadPacket = tcpPacket;
            ethernetPacket.PayloadPacket = ipPacket;
            tcpPacket.UpdateCalculatedValues();

            EthernetFrame.TryCreateEthernetFrame(ethernetPacket.Bytes, true, out var frame);
            frame.FillWithChecksums(new EtherType[] { EtherType.IpV4 }, new[] { IPProtocolType.TCP });

            FrameReady?.Invoke(frame);
        }

        private void SendTcpRst(IPAddress destIP, ushort destPort, IPAddress srcIP, ushort srcPort,
            uint seqNum, uint ackNum)
        {
            var rst = new TcpPacket(srcPort, destPort);
            rst.SequenceNumber = seqNum;
            rst.AcknowledgmentNumber = ackNum;
            rst.Rst = true;
            rst.Ack = true;
            rst.WindowSize = 0;

            PhysicalAddress destMac;
            if(!arpTable.TryGetValue(destIP, out destMac))
            {
                destMac = new PhysicalAddress(new byte[] { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
            }

            var ipPacket = new IPv4Packet(srcIP, destIP);
            var ethernetPacket = new EthernetPacket((PhysicalAddress)MAC, destMac, EthernetPacketType.None);

            ipPacket.PayloadPacket = rst;
            ethernetPacket.PayloadPacket = ipPacket;
            rst.UpdateCalculatedValues();

            EthernetFrame.TryCreateEthernetFrame(ethernetPacket.Bytes, true, out var frame);
            frame.FillWithChecksums(new EtherType[] { EtherType.IpV4 }, new[] { IPProtocolType.TCP });

            FrameReady?.Invoke(frame);
        }

        private void HandleNatSyn(IPv4Packet ipPacket, TcpPacket tcpPacket)
        {
            var destPort = tcpPacket.DestinationPort;
            this.Log(LogLevel.Info, "NAT: guest SYN → host 127.0.0.1:{0}", destPort);

            // Use the destination port the guest targeted — the SYN-ACK must
            // come FROM the same port the guest connected TO.
            var localPort = destPort;

            // Create a TcpConnection to manage the virtual TCP with the guest
            var conn = CreateTcpConnection(localPort, ipPacket.SourceAddress, tcpPacket.SourcePort);
            if(conn == null)
            {
                this.Log(LogLevel.Warning, "NAT: failed to create virtual connection");
                SendTcpRst(ipPacket.SourceAddress, tcpPacket.SourcePort,
                    ipPacket.DestinationAddress, tcpPacket.DestinationPort,
                    0, tcpPacket.SequenceNumber + 1);
                return;
            }

            // Create the NAT proxy that bridges to the real host socket
            this.Log(LogLevel.Debug,
                "NAT: creating proxy for port {0} (conn {1}:{2} → {3}:{4})",
                destPort, IP, localPort, ipPacket.SourceAddress, tcpPacket.SourcePort);
            var proxy = new NatProxy(this, conn, "127.0.0.1", destPort);
            if(!proxy.Start())
            {
                // Host connection failed — RST to guest
                this.Log(LogLevel.Warning, "NAT: host connection to 127.0.0.1:{0} failed", destPort);
                RemoveTcpConnection(conn);
                SendTcpRst(ipPacket.SourceAddress, tcpPacket.SourcePort,
                    ipPacket.DestinationAddress, tcpPacket.DestinationPort,
                    0, tcpPacket.SequenceNumber + 1);
                return;
            }

            // Complete the SYN handshake: feed the guest SYN into the connection
            // which is in SynReceived-like state. We manually do SYN-ACK.
            conn.ProcessSynFromGuest(tcpPacket);
        }

        private ushort AllocateEphemeralPort()
        {
            var port = nextEphemeralPort;
            nextEphemeralPort++;
            if(nextEphemeralPort > 65000)
            {
                nextEphemeralPort = 49152;
            }
            return port;
        }

        private bool TryHandleArp(ARPPacket packet, out ARPPacket response)
        {
            response = null;
            var packetString = PacketToString(packet);
            this.Log(LogLevel.Noisy, "Handling ARP packet: {0}", packetString);

            if(packet.Operation != ARPOperation.Request)
            {
                this.Log(LogLevel.Warning, "Unsupported ARP packet: {0}", packetString);
                return false;
            }

            if(!packet.TargetProtocolAddress.Equals(IP))
            {
                this.Log(LogLevel.Noisy, "This ARP packet is not directed to me. Ignoring");
                return false;
            }

            response = new ARPPacket(
                ARPOperation.Response,
                packet.SenderHardwareAddress,
                packet.SenderProtocolAddress,
                (PhysicalAddress)MAC,
                IP);

            this.Log(LogLevel.Noisy, "Sending ARP response");
            return true;
        }

        private string PacketToString(Packet packet)
        {
            try
            {
                return packet.ToString();
            }
            catch
            {
                return "<failed to decode packet>";
            }
        }

        public void EnableNat()
        {
            enableNat = true;
            this.Log(LogLevel.Info, "NAT enabled: guest→host TCP connections will be proxied to 127.0.0.1");
        }

        private readonly Dictionary<int, IServerModule> modules;
        private readonly Dictionary<string, int> modulesNames;
        private readonly Dictionary<IPAddress, PhysicalAddress> arpTable;
        private readonly ConcurrentDictionary<TcpConnectionKey, TcpConnection> tcpConnections;
        private PortForwarder portForwarder;
        private bool enableNat;
        private ushort nextEphemeralPort = 49152;
    }

    internal struct TcpConnectionKey : IEquatable<TcpConnectionKey>
    {
        public readonly IPAddress LocalIP;
        public readonly ushort LocalPort;
        public readonly IPAddress RemoteIP;
        public readonly ushort RemotePort;

        public TcpConnectionKey(IPAddress localIP, ushort localPort, IPAddress remoteIP, ushort remotePort)
        {
            LocalIP = localIP;
            LocalPort = localPort;
            RemoteIP = remoteIP;
            RemotePort = remotePort;
        }

        public bool Equals(TcpConnectionKey other)
        {
            return LocalIP.Equals(other.LocalIP) && LocalPort == other.LocalPort
                && RemoteIP.Equals(other.RemoteIP) && RemotePort == other.RemotePort;
        }

        public override bool Equals(object obj)
        {
            return obj is TcpConnectionKey other && Equals(other);
        }

        public override int GetHashCode()
        {
            unchecked
            {
                int hash = 17;
                hash = hash * 31 + LocalIP.GetHashCode();
                hash = hash * 31 + LocalPort.GetHashCode();
                hash = hash * 31 + RemoteIP.GetHashCode();
                hash = hash * 31 + RemotePort.GetHashCode();
                return hash;
            }
        }
    }
}