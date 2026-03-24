//
// Copyright (c) 2026 Microsoft
//
// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
//

namespace Antmicro.Renode.Integrations
{
    // CRC-CCITT with polynomial 0x8408 (reflected form)
    // Used by MCTP serial binding (DSP0238)
    public static class CrcCcitt
    {
        public const ushort InitialValue = 0xFFFF;

        public static ushort ComputeByte(ushort crc, byte b)
        {
            crc ^= b;
            for(int i = 0; i < 8; i++)
            {
                if((crc & 1) != 0)
                {
                    crc = (ushort)((crc >> 1) ^ 0x8408);
                }
                else
                {
                    crc >>= 1;
                }
            }
            return crc;
        }

        public static ushort Compute(ushort crc, byte[] data, int offset, int length)
        {
            for(int i = 0; i < length; i++)
            {
                crc = ComputeByte(crc, data[offset + i]);
            }
            return crc;
        }

        public static ushort Compute(byte[] data)
        {
            return Compute(InitialValue, data, 0, data.Length);
        }
    }
}
