//
// Copyright (c) 2026 Microsoft
//
// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
//
using System;
using System.Text;
using Antmicro.Renode.Logging;

namespace Antmicro.Renode.Integrations
{
    // PLDM Platform Monitoring & Control handler (DSP0248)
    // Handles: GetPDR
    public class PldmPlatformHandler
    {
        private readonly ScenarioConfig config;
        private readonly IEmulationElement logger;
        private byte[][] pdrRecords;

        public PldmPlatformHandler(ScenarioConfig config, IEmulationElement logger)
        {
            this.config = config;
            this.logger = logger;
            BuildPdrRepository();
        }

        public byte[] Handle(byte[] pldmMsg)
        {
            if(pldmMsg == null || pldmMsg.Length < 3)
            {
                return null;
            }

            byte instanceId, pldmType, command;
            bool request, datagram;
            PldmEncoder.ParseHeader(pldmMsg, out instanceId, out request, out datagram, out pldmType, out command);

            if(command != PldmEncoder.CmdGetPdr)
            {
                logger.Log(LogLevel.Debug, "PLDM Platform: unsupported command 0x{0:X2}", command);
                var errResp = new byte[4];
                var errHdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypePlatform, command);
                Array.Copy(errHdr, 0, errResp, 0, 3);
                errResp[3] = PldmEncoder.ErrorUnsupportedPldmCmd;
                return errResp;
            }

            return HandleGetPdr(instanceId, pldmMsg);
        }

        private byte[] HandleGetPdr(byte instanceId, byte[] pldmMsg)
        {
            // Parse request: record_handle(4) + data_transfer_handle(4) +
            //   transfer_op_flag(1) + request_count(2) + record_change_number(2) = 13
            if(pldmMsg.Length < 16)
            {
                return BuildPdrError(instanceId, PldmEncoder.Error);
            }

            uint recordHandle = PldmEncoder.ReadLE32(pldmMsg, 3);
            // data_transfer_handle at 7, transfer_op_flag at 11 — not used for small PDRs
            ushort requestCount = PldmEncoder.ReadLE16(pldmMsg, 12);

            logger.Log(LogLevel.Debug, "PLDM Platform: GetPDR, record_handle={0}, request_count={1}",
                recordHandle, requestCount);

            // Map record handle to index (handle 0 = first record, handle N = record N-1)
            int idx = recordHandle == 0 ? 0 : (int)recordHandle - 1;

            if(idx < 0 || idx >= pdrRecords.Length)
            {
                logger.Log(LogLevel.Debug, "  -> Record not found");
                return BuildPdrError(instanceId, PldmEncoder.PlatformInvalidRecordHandle);
            }

            uint nextHandle = 0;
            if(idx + 1 < pdrRecords.Length)
            {
                nextHandle = (uint)(idx + 2);
            }

            var record = pdrRecords[idx];
            ushort respCount = (ushort)record.Length;

            logger.Log(LogLevel.Debug, "  -> Returning record {0} ({1} bytes), next_handle={2}",
                idx + 1, respCount, nextHandle);

            // Response: Header(3) + CC(1) + next_record_handle(4) + next_data_transfer_handle(4) +
            //   transfer_flag(1) + response_count(2) + record_data(N) = 15 + N
            // (transfer_change_number omitted for single-part transfer)
            var resp = new byte[15 + respCount];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypePlatform, PldmEncoder.CmdGetPdr);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = PldmEncoder.Success;
            PldmEncoder.WriteLE32(resp, 4, nextHandle);
            PldmEncoder.WriteLE32(resp, 8, 0); // next_data_transfer_handle
            resp[12] = PldmEncoder.TransferStartAndEnd;
            PldmEncoder.WriteLE16(resp, 13, respCount);
            Array.Copy(record, 0, resp, 15, respCount);
            return resp;
        }

        private byte[] BuildPdrError(byte instanceId, byte errorCode)
        {
            // Minimal GetPDR error response: Header(3) + CC(1) + next_handle(4) +
            //   next_data_handle(4) + transfer_flag(1) + response_count(2) = 15
            var resp = new byte[15];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypePlatform, PldmEncoder.CmdGetPdr);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = errorCode;
            return resp;
        }

        private void BuildPdrRepository()
        {
            pdrRecords = new byte[2][];
            pdrRecords[0] = BuildTerminusLocatorPdr(1, config.Eid, config.Tid);
            pdrRecords[1] = BuildEntityAuxNamesPdr(2, config.EntityType, config.Name);
            logger.Log(LogLevel.Debug, "PLDM Platform: PDR repository: {0} records", pdrRecords.Length);
        }

        // Build terminus locator PDR (DSP0248 Table 10)
        private static byte[] BuildTerminusLocatorPdr(uint recordHandle, byte eid, byte tid)
        {
            // PDR header (10 bytes) + data (9 bytes) = 19 bytes
            const int dataLen = 9;
            const int pdrHdrLen = 10;
            var buf = new byte[pdrHdrLen + dataLen];

            // PDR header
            PldmEncoder.WriteLE32(buf, 0, recordHandle);
            buf[4] = 0x01; // PDR version
            buf[5] = PldmEncoder.PdrTerminusLocator; // PDR type
            buf[6] = 0x00; // record change number (lo)
            buf[7] = 0x00; // record change number (hi)
            PldmEncoder.WriteLE16(buf, 8, (ushort)dataLen);

            // Terminus locator data
            int d = pdrHdrLen;
            buf[d + 0] = 0x01; // PLDMTerminusHandle (lo)
            buf[d + 1] = 0x00; // PLDMTerminusHandle (hi)
            buf[d + 2] = 0x01; // validity (valid)
            buf[d + 3] = tid;  // TID
            buf[d + 4] = 0x00; // container_id (lo)
            buf[d + 5] = 0x00; // container_id (hi)
            buf[d + 6] = 0x01; // terminus_locator_type = MCTP EID
            buf[d + 7] = 0x01; // terminus_locator_value_size
            buf[d + 8] = eid;  // EID

            return buf;
        }

        // Build entity auxiliary names PDR (DSP0248 Table 95)
        private static byte[] BuildEntityAuxNamesPdr(uint recordHandle, ushort entityType, string name)
        {
            var nameBytes = Encoding.ASCII.GetBytes(name);
            // Fixed fields: entityType(2) + instanceNum(2) + containerID(2) +
            //   sharedNameCount(1) + nameStringCount(1) = 8
            // Tag "en" + NUL = 3 bytes; name in UTF-16BE + NUL = nameLen*2+2
            int tagLen = 3;
            int u16NameBytes = nameBytes.Length * 2 + 2;
            int dataLen = 8 + tagLen + u16NameBytes;
            int pdrHdrLen = 10;
            var buf = new byte[pdrHdrLen + dataLen];

            // PDR header
            PldmEncoder.WriteLE32(buf, 0, recordHandle);
            buf[4] = 0x01; // PDR version
            buf[5] = PldmEncoder.PdrEntityAuxNames; // PDR type
            buf[6] = 0x00; // record change number (lo)
            buf[7] = 0x00; // record change number (hi)
            PldmEncoder.WriteLE16(buf, 8, (ushort)dataLen);

            // Entity aux names data
            int d = pdrHdrLen;
            PldmEncoder.WriteLE16(buf, d, entityType);
            PldmEncoder.WriteLE16(buf, d + 2, 1); // entityInstanceNumber
            PldmEncoder.WriteLE16(buf, d + 4, 0); // entityContainerID
            buf[d + 6] = 0; // sharedNameCount
            buf[d + 7] = 1; // nameStringCount

            // Language tag "en\0"
            buf[d + 8] = (byte)'e';
            buf[d + 9] = (byte)'n';
            buf[d + 10] = 0;

            // Name in UTF-16BE
            int np = d + 11;
            for(int i = 0; i < nameBytes.Length; i++)
            {
                buf[np + i * 2] = 0x00;
                buf[np + i * 2 + 1] = nameBytes[i];
            }
            // NUL terminator
            buf[np + nameBytes.Length * 2] = 0x00;
            buf[np + nameBytes.Length * 2 + 1] = 0x00;

            return buf;
        }
    }
}
