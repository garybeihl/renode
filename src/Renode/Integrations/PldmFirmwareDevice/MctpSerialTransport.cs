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
    // MCTP serial transport binding (DSP0238)
    // Frame format: [0x7E][version][length][escaped data][FCS_hi][FCS_lo][0x7E]
    // Byte stuffing: 0x7E → 0x7D 0x5E, 0x7D → 0x7D 0x5D (data bytes only)
    // FCS bytes are sent/received raw (no escaping) per Linux kernel mctp-serial
    public class MctpSerialTransport
    {
        public const byte FrameFlag = 0x7E;
        public const byte EscapeByte = 0x7D;
        public const byte SerialVersion = 0x01;
        private const int MaxFrameData = 255;

        private enum RxState
        {
            WaitSync,
            ReadVersion,
            ReadLength,
            ReadData,
            ReadFcsHi,
            ReadFcsLo,
        }

        private RxState rxState;
        private byte rxVersion;
        private byte rxLength;
        private byte[] rxBuffer;
        private int rxPos;
        private bool rxEscape;
        private byte rxFcsHi;

        private readonly IEmulationElement logger;
        private readonly Action<byte[]> onFrameReceived;
        private readonly Action<byte> sendByte;

        public MctpSerialTransport(IEmulationElement logger, Action<byte[]> onFrameReceived, Action<byte> sendByte)
        {
            this.logger = logger;
            this.onFrameReceived = onFrameReceived;
            this.sendByte = sendByte;
            rxBuffer = new byte[MaxFrameData];
            Reset();
        }

        public void Reset()
        {
            rxState = RxState.WaitSync;
            rxPos = 0;
            rxEscape = false;
        }

        // Feed one byte from the UART into the receive state machine
        public void ProcessByte(byte b)
        {
            switch(rxState)
            {
                case RxState.WaitSync:
                    if(b == FrameFlag)
                    {
                        rxState = RxState.ReadVersion;
                        rxPos = 0;
                        rxEscape = false;
                    }
                    break;

                case RxState.ReadVersion:
                    if(b == FrameFlag)
                    {
                        // Another sync, stay in ReadVersion
                        break;
                    }
                    rxVersion = b;
                    if(rxVersion != SerialVersion)
                    {
                        logger.Log(LogLevel.Warning, "MCTP serial: unexpected version 0x{0:X2}", rxVersion);
                        rxState = RxState.WaitSync;
                        break;
                    }
                    rxState = RxState.ReadLength;
                    break;

                case RxState.ReadLength:
                    rxLength = b;
                    if(rxLength == 0 || rxLength > MaxFrameData)
                    {
                        logger.Log(LogLevel.Warning, "MCTP serial: invalid length {0}", rxLength);
                        rxState = RxState.WaitSync;
                        break;
                    }
                    rxPos = 0;
                    rxEscape = false;
                    rxState = RxState.ReadData;
                    break;

                case RxState.ReadData:
                    if(rxEscape)
                    {
                        rxEscape = false;
                        b = (byte)(b | 0x20); // undo escape: 0x5E→0x7E, 0x5D→0x7D
                        if(rxPos < rxLength)
                        {
                            rxBuffer[rxPos++] = b;
                        }
                    }
                    else if(b == EscapeByte)
                    {
                        rxEscape = true;
                    }
                    else if(b == FrameFlag)
                    {
                        // Unexpected flag in data, abort
                        logger.Log(LogLevel.Warning, "MCTP serial: unexpected flag in data at pos {0}/{1}", rxPos, rxLength);
                        rxState = RxState.WaitSync;
                    }
                    else
                    {
                        if(rxPos < rxLength)
                        {
                            rxBuffer[rxPos++] = b;
                        }
                    }

                    if(rxPos >= rxLength)
                    {
                        rxState = RxState.ReadFcsHi;
                    }
                    break;

                case RxState.ReadFcsHi:
                    // FCS bytes are NOT byte-stuffed (matches Linux kernel mctp-serial
                    // STATE_TRAILER which sends/receives FCS raw, per DSP0238 + kernel)
                    rxFcsHi = b;
                    rxState = RxState.ReadFcsLo;
                    break;

                case RxState.ReadFcsLo:
                    ushort receivedFcs = (ushort)((rxFcsHi << 8) | b);
                    ushort computedFcs = CrcCcitt.ComputeByte(CrcCcitt.InitialValue, rxVersion);
                    computedFcs = CrcCcitt.ComputeByte(computedFcs, rxLength);
                    computedFcs = CrcCcitt.Compute(computedFcs, rxBuffer, 0, rxLength);

                    if(receivedFcs != computedFcs)
                    {
                        logger.Log(LogLevel.Warning, "MCTP serial: FCS mismatch: received 0x{0:X4}, computed 0x{1:X4}", receivedFcs, computedFcs);
                        rxState = RxState.WaitSync;
                        break;
                    }

                    // Deliver complete frame
                    var data = new byte[rxLength];
                    Array.Copy(rxBuffer, 0, data, 0, rxLength);
                    rxState = RxState.WaitSync;
                    onFrameReceived(data);
                    break;
            }
        }

        // Send an MCTP packet as a serial frame
        public void SendFrame(byte[] data)
        {
            if(data == null || data.Length == 0 || data.Length > MaxFrameData)
            {
                logger.Log(LogLevel.Warning, "MCTP serial: cannot send frame of length {0}", data != null ? data.Length : 0);
                return;
            }

            // Compute FCS over version + length + unescaped data
            var length = (byte)data.Length;
            ushort fcs = CrcCcitt.ComputeByte(CrcCcitt.InitialValue, SerialVersion);
            fcs = CrcCcitt.ComputeByte(fcs, length);
            fcs = CrcCcitt.Compute(fcs, data, 0, data.Length);

            // Send frame: flag, version, length
            sendByte(FrameFlag);
            sendByte(SerialVersion);
            sendByte(length);

            // Send data with byte stuffing
            for(int i = 0; i < data.Length; i++)
            {
                if(data[i] == FrameFlag || data[i] == EscapeByte)
                {
                    sendByte(EscapeByte);
                    sendByte((byte)(data[i] & ~0x20));
                }
                else
                {
                    sendByte(data[i]);
                }
            }

            // Send FCS (high byte first) raw, then trailing flag.
            // FCS bytes are NOT byte-stuffed — matches Linux kernel mctp-serial
            // STATE_TRAILER which sends/receives FCS raw (positional parsing).
            sendByte((byte)(fcs >> 8));
            sendByte((byte)(fcs & 0xFF));
            sendByte(FrameFlag);

            logger.Log(LogLevel.Debug, "MCTP serial: sent {0} byte frame ({1} byte MCTP packet)", 7 + data.Length, data.Length);
        }
    }
}
