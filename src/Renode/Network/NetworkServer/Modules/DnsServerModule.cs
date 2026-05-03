// SPDX-License-Identifier: MIT
// Minimal DNS responder for Renode user-mode networking.
// Resolves configured hostnames to the gateway IP; returns
// NXDOMAIN for everything else. UDP only (standard DNS).

using System;
using System.Collections.Generic;
using System.Net;

using Antmicro.Renode;
using Antmicro.Renode.Logging;
using PacketDotNet;

namespace Antmicro.Renode.Network
{
    public class DnsServerModule : IServerModule, IEmulationElement
    {
        private readonly IPAddress gatewayIP;
        private readonly Dictionary<string, IPAddress> records;

        public DnsServerModule(IPAddress gatewayIP)
        {
            this.gatewayIP = gatewayIP;
            records = new Dictionary<string, IPAddress>(
                StringComparer.OrdinalIgnoreCase);
        }

        public void AddRecord(string hostname, string ip)
        {
            records[hostname] = IPAddress.Parse(ip);
        }

        public void HandleUdp(IPEndPoint source, UdpPacket packet,
            Action<IPEndPoint, UdpPacket> sendResponse)
        {
            var query = packet.PayloadData;
            if(query == null || query.Length < 12)
            {
                return;
            }

            // Parse DNS header
            ushort txId = (ushort)((query[0] << 8) | query[1]);
            // Parse question: skip header (12 bytes), read QNAME
            string qname = ParseQName(query, 12, out int qnameEnd);

            IPAddress resolved = null;
            if(qname != null && records.TryGetValue(qname, out resolved))
            {
                this.Log(LogLevel.Debug, "DNS: {0} → {1}", qname, resolved);
            }
            else if(qname != null)
            {
                // Default: resolve to gateway
                resolved = gatewayIP;
                this.Log(LogLevel.Debug, "DNS: {0} → {1} (default)",
                    qname, resolved);
            }

            byte[] response = BuildResponse(txId, query, 12, qnameEnd,
                resolved);

            var udpResponse = new UdpPacket(53, (ushort)source.Port);
            udpResponse.PayloadData = response;
            sendResponse(source, udpResponse);
        }

        private static string ParseQName(byte[] data, int offset,
            out int endOffset)
        {
            var parts = new List<string>();
            endOffset = offset;

            while(endOffset < data.Length)
            {
                int len = data[endOffset];
                if(len == 0)
                {
                    endOffset++; // skip null terminator
                    break;
                }
                if(endOffset + 1 + len > data.Length)
                {
                    return null;
                }
                parts.Add(System.Text.Encoding.ASCII.GetString(
                    data, endOffset + 1, len));
                endOffset += 1 + len;
            }

            // Skip QTYPE (2) + QCLASS (2)
            endOffset += 4;

            return parts.Count > 0 ? string.Join(".", parts) : null;
        }

        private static byte[] BuildResponse(ushort txId, byte[] query,
            int qnameStart, int qnameEnd, IPAddress ip)
        {
            // Response = header (12) + question (copy) + answer (variable)
            int questionLen = qnameEnd - qnameStart;
            int answerLen = ip != null ? 16 : 0; // name ptr(2)+type(2)+class(2)+ttl(4)+rdlen(2)+rdata(4)
            var resp = new byte[12 + questionLen + answerLen];

            // Header
            resp[0] = (byte)(txId >> 8);
            resp[1] = (byte)(txId & 0xFF);
            resp[2] = 0x81; // QR=1, Opcode=0, AA=1, TC=0, RD=1
            resp[3] = (byte)(ip != null ? 0x80 : 0x83); // RA=1, RCODE=0 or 3 (NXDOMAIN)
            resp[4] = 0; resp[5] = 1; // QDCOUNT = 1
            resp[6] = 0; resp[7] = (byte)(ip != null ? 1 : 0); // ANCOUNT
            // NSCOUNT=0, ARCOUNT=0

            // Copy question section
            Array.Copy(query, qnameStart, resp, 12, questionLen);

            if(ip != null)
            {
                int a = 12 + questionLen;
                // Name pointer to question
                resp[a] = 0xC0; resp[a + 1] = 0x0C;
                // Type A
                resp[a + 2] = 0; resp[a + 3] = 1;
                // Class IN
                resp[a + 4] = 0; resp[a + 5] = 1;
                // TTL = 60
                resp[a + 6] = 0; resp[a + 7] = 0;
                resp[a + 8] = 0; resp[a + 9] = 60;
                // RDLENGTH = 4
                resp[a + 10] = 0; resp[a + 11] = 4;
                // RDATA = IP
                var ipBytes = ip.GetAddressBytes();
                resp[a + 12] = ipBytes[0];
                resp[a + 13] = ipBytes[1];
                resp[a + 14] = ipBytes[2];
                resp[a + 15] = ipBytes[3];
            }

            return resp;
        }
    }
}
