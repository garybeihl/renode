//
// Copyright (c) 2010-2026 Antmicro
//
// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
//

using System;
using System.Net;

using Antmicro.Renode.Logging;

using PacketDotNet;

namespace Antmicro.Renode.Network
{
    public static class DhcpServerExtensions
    {
        public static void StartDHCP(this NetworkServer server, string guestIP, string subnetMask = "255.255.255.0",
            int leaseTime = 86400, string name = "dhcp")
        {
            var module = new DhcpServerModule(server.IP, IPAddress.Parse(guestIP),
                IPAddress.Parse(subnetMask), leaseTime);
            if(!server.RegisterModule(module, DhcpServerModule.ServerPort, name))
            {
                throw new Antmicro.Renode.Exceptions.RecoverableException(
                    $"Couldn't start DHCP server on port {DhcpServerModule.ServerPort}");
            }
        }
    }

    // Minimal DHCP server that assigns a single IP to the guest.
    // Handles: DISCOVER→OFFER, REQUEST→ACK
    public class DhcpServerModule : IServerModule, IEmulationElement
    {
        public DhcpServerModule(IPAddress serverIP, IPAddress guestIP,
            IPAddress subnetMask, int leaseTimeSec)
        {
            this.serverIP = serverIP;
            this.guestIP = guestIP;
            this.subnetMask = subnetMask;
            this.leaseTimeSec = leaseTimeSec;

            this.Log(LogLevel.Info, "DHCP server: will offer {0} (gateway {1}, mask {2})",
                guestIP, serverIP, subnetMask);
        }

        public void HandleUdp(IPEndPoint source, UdpPacket packet, Action<IPEndPoint, UdpPacket> callback)
        {
            var data = packet.PayloadData;
            if(data == null || data.Length < MinDhcpLength)
            {
                this.Log(LogLevel.Warning, "DHCP packet too short ({0} bytes)", data?.Length ?? 0);
                return;
            }

            byte messageType = GetDhcpMessageType(data);
            var xid = new byte[4];
            Array.Copy(data, 4, xid, 0, 4);
            var clientMac = new byte[6];
            Array.Copy(data, 28, clientMac, 0, 6);

            this.Log(LogLevel.Debug, "DHCP message type {0} from {1}",
                messageType, BitConverter.ToString(clientMac));

            byte[] response = null;
            switch(messageType)
            {
            case DhcpDiscover:
                response = BuildDhcpResponse(DhcpOffer, xid, clientMac);
                this.Log(LogLevel.Info, "DHCP OFFER {0} to {1}",
                    guestIP, BitConverter.ToString(clientMac));
                break;
            case DhcpRequest:
                response = BuildDhcpResponse(DhcpAck, xid, clientMac);
                this.Log(LogLevel.Info, "DHCP ACK {0} to {1}",
                    guestIP, BitConverter.ToString(clientMac));
                break;
            default:
                this.Log(LogLevel.Debug, "Ignoring DHCP message type {0}", messageType);
                return;
            }

            if(response != null)
            {
                var udpResponse = new UdpPacket(ServerPort, ClientPort);
                udpResponse.PayloadData = response;
                // DHCP responses go to broadcast (client doesn't have IP yet)
                var broadcastEndpoint = new IPEndPoint(IPAddress.Broadcast, ClientPort);
                callback(broadcastEndpoint, udpResponse);
            }
        }

        private byte[] BuildDhcpResponse(byte msgType, byte[] xid, byte[] clientMac)
        {
            // BOOTP/DHCP response: 240 bytes base + options
            var resp = new byte[300];

            resp[0] = 2; // op: BOOTREPLY
            resp[1] = 1; // htype: Ethernet
            resp[2] = 6; // hlen: 6
            resp[3] = 0; // hops

            // Transaction ID
            Array.Copy(xid, 0, resp, 4, 4);

            // secs, flags
            resp[10] = 0x80; // Broadcast flag

            // yiaddr (your IP address — the offered IP)
            var yiaddr = guestIP.GetAddressBytes();
            Array.Copy(yiaddr, 0, resp, 16, 4);

            // siaddr (server IP)
            var siaddr = serverIP.GetAddressBytes();
            Array.Copy(siaddr, 0, resp, 20, 4);

            // chaddr (client MAC)
            Array.Copy(clientMac, 0, resp, 28, 6);

            // Magic cookie: 99.130.83.99
            resp[236] = 99; resp[237] = 130; resp[238] = 83; resp[239] = 99;

            int offset = 240;

            // Option 53: DHCP Message Type
            resp[offset++] = 53; resp[offset++] = 1; resp[offset++] = msgType;

            // Option 54: Server Identifier
            resp[offset++] = 54; resp[offset++] = 4;
            Array.Copy(siaddr, 0, resp, offset, 4); offset += 4;

            // Option 51: Lease Time
            resp[offset++] = 51; resp[offset++] = 4;
            resp[offset++] = (byte)(leaseTimeSec >> 24);
            resp[offset++] = (byte)(leaseTimeSec >> 16);
            resp[offset++] = (byte)(leaseTimeSec >> 8);
            resp[offset++] = (byte)(leaseTimeSec);

            // Option 1: Subnet Mask
            resp[offset++] = 1; resp[offset++] = 4;
            var mask = subnetMask.GetAddressBytes();
            Array.Copy(mask, 0, resp, offset, 4); offset += 4;

            // Option 3: Router (gateway = our server IP)
            resp[offset++] = 3; resp[offset++] = 4;
            Array.Copy(siaddr, 0, resp, offset, 4); offset += 4;

            // Option 6: DNS Server (use gateway as DNS, or 8.8.8.8)
            resp[offset++] = 6; resp[offset++] = 4;
            Array.Copy(siaddr, 0, resp, offset, 4); offset += 4;

            // End option
            resp[offset++] = 255;

            // Trim to actual size
            var result = new byte[offset];
            Array.Copy(resp, result, offset);
            return result;
        }

        private static byte GetDhcpMessageType(byte[] data)
        {
            // DHCP options start at offset 240 (after magic cookie at 236)
            if(data.Length < 241)
            {
                return 0;
            }

            // Verify magic cookie
            if(data[236] != 99 || data[237] != 130 || data[238] != 83 || data[239] != 99)
            {
                return 0;
            }

            int i = 240;
            while(i < data.Length)
            {
                byte option = data[i];
                if(option == 255) break; // End
                if(option == 0) { i++; continue; } // Padding
                if(i + 1 >= data.Length) break;
                byte length = data[i + 1];
                if(option == 53 && length == 1 && i + 2 < data.Length)
                {
                    return data[i + 2];
                }
                i += 2 + length;
            }
            return 0;
        }

        private readonly IPAddress serverIP;
        private readonly IPAddress guestIP;
        private readonly IPAddress subnetMask;
        private readonly int leaseTimeSec;

        public const ushort ServerPort = 67;
        public const ushort ClientPort = 68;

        private const int MinDhcpLength = 240;

        private const byte DhcpDiscover = 1;
        private const byte DhcpOffer = 2;
        private const byte DhcpRequest = 3;
        private const byte DhcpAck = 5;
    }
}
