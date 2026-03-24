//
// Copyright (c) 2026 Microsoft
//
// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
//
using System;

namespace Antmicro.Renode.Integrations
{
    // MCTP transport packet (DSP0236)
    // Transport header: [version][dest_eid][src_eid][flags_tag]
    // Message body:     [msg_type][payload...]
    public class MctpPacket
    {
        public const byte HeaderVersion = 0x01; // MCTP version 1 (raw byte, matches kernel)
        public const byte FlagSOM = 0x80;
        public const byte FlagEOM = 0x40;
        public const byte FlagTO = 0x08;
        public const byte TagMask = 0x07;

        public const byte MessageTypeControl = 0x00;
        public const byte MessageTypePldm = 0x01;

        public byte DestEid;
        public byte SrcEid;
        public byte FlagsTag;
        public byte MessageType;
        public byte[] Payload; // message content after msg_type byte

        public bool IsRequest
        {
            get
            {
                if(MessageType == MessageTypeControl)
                {
                    // MCTP control: Rq bit is bit 7 of first payload byte
                    return Payload != null && Payload.Length > 0 && (Payload[0] & 0x80) != 0;
                }
                if(MessageType == MessageTypePldm)
                {
                    // PLDM: request bit is bit 0 of first payload byte (PLDM header byte 0)
                    return Payload != null && Payload.Length > 0 && (Payload[0] & 0x01) != 0;
                }
                return false;
            }
        }

        public byte Tag { get { return (byte)(FlagsTag & TagMask); } }
        public bool TagOwner { get { return (FlagsTag & FlagTO) != 0; } }
        public bool SOM { get { return (FlagsTag & FlagSOM) != 0; } }
        public bool EOM { get { return (FlagsTag & FlagEOM) != 0; } }

        public static MctpPacket Parse(byte[] data, int offset, int length)
        {
            if(length < 4)
            {
                return null;
            }

            var pkt = new MctpPacket();
            // byte 0 is header version, skip (should be 0x01)
            pkt.DestEid = data[offset + 1];
            pkt.SrcEid = data[offset + 2];
            pkt.FlagsTag = data[offset + 3];

            bool som = (pkt.FlagsTag & FlagSOM) != 0;
            if(som && length >= 5)
            {
                // SOM packet: byte 4 is IC(1)|MessageType(7), payload starts at byte 5
                pkt.MessageType = (byte)(data[offset + 4] & 0x7F);
                pkt.Payload = new byte[length - 5];
                Array.Copy(data, offset + 5, pkt.Payload, 0, length - 5);
            }
            else if(length > 4)
            {
                // Continuation packet (SOM=0): no message type byte, all body is payload
                pkt.MessageType = 0xFF;
                pkt.Payload = new byte[length - 4];
                Array.Copy(data, offset + 4, pkt.Payload, 0, length - 4);
            }
            else
            {
                pkt.MessageType = 0xFF;
                pkt.Payload = new byte[0];
            }
            return pkt;
        }

        public byte[] Build()
        {
            var data = new byte[5 + (Payload != null ? Payload.Length : 0)];
            data[0] = HeaderVersion;
            data[1] = DestEid;
            data[2] = SrcEid;
            data[3] = FlagsTag;
            data[4] = MessageType; // IC=0
            if(Payload != null)
            {
                Array.Copy(Payload, 0, data, 5, Payload.Length);
            }
            return data;
        }

        // Build a response packet for a given request
        public static MctpPacket BuildResponse(MctpPacket request, byte srcEid, byte messageType, byte[] payload)
        {
            var resp = new MctpPacket();
            resp.DestEid = request.SrcEid;
            resp.SrcEid = srcEid;
            // Response: SOM+EOM, same tag, clear TO
            resp.FlagsTag = (byte)(FlagSOM | FlagEOM | (request.FlagsTag & TagMask));
            resp.MessageType = messageType;
            resp.Payload = payload;
            return resp;
        }

        // Build an FD-initiated request packet
        public static MctpPacket BuildFdRequest(byte destEid, byte srcEid, byte tag, byte messageType, byte[] payload)
        {
            var req = new MctpPacket();
            req.DestEid = destEid;
            req.SrcEid = srcEid;
            // Request: SOM+EOM, TO set, our tag
            req.FlagsTag = (byte)(FlagSOM | FlagEOM | FlagTO | (tag & TagMask));
            req.MessageType = messageType;
            req.Payload = payload;
            return req;
        }
    }
}
