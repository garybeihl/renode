//
// Copyright (c) 2026 Microsoft
//
// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
//
using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;
using Antmicro.Renode.Logging;

namespace Antmicro.Renode.Integrations
{
    // SPDM 1.1/1.2 responder protocol handler (DSP0274)
    // Implements: GET_VERSION, GET_CAPABILITIES, NEGOTIATE_ALGORITHMS,
    //             GET_DIGESTS, GET_CERTIFICATE, CHALLENGE, GET_MEASUREMENTS
    public class SpdmProtocolHandler
    {
        // SPDM request codes
        private const byte RequestGetVersion = 0x84;
        private const byte RequestGetCapabilities = 0xE1;
        private const byte RequestNegotiateAlgorithms = 0xE3;
        private const byte RequestGetDigests = 0x81;
        private const byte RequestGetCertificate = 0x82;
        private const byte RequestChallenge = 0x83;
        private const byte RequestGetMeasurements = 0xE0;

        // SPDM response codes
        private const byte ResponseVersion = 0x04;
        private const byte ResponseCapabilities = 0x61;
        private const byte ResponseAlgorithms = 0x63;
        private const byte ResponseDigests = 0x01;
        private const byte ResponseCertificate = 0x02;
        private const byte ResponseChallengeAuth = 0x03;
        private const byte ResponseMeasurements = 0x60;
        private const byte ResponseError = 0x7F;

        // Error codes
        private const byte ErrorInvalidRequest = 0x01;
        private const byte ErrorUnexpectedRequest = 0x03;
        private const byte ErrorUnsupportedRequest = 0x41;

        // SPDM versions
        private const byte SpdmVersion10 = 0x10;
        private const byte SpdmVersion11 = 0x11;
        private const byte SpdmVersion12 = 0x12;

        // Capabilities flags (responder)
        private const uint CapCert = 0x02;        // CERT_CAP
        private const uint CapChal = 0x04;        // CHAL_CAP
        private const uint CapMeasSig = 0x10;     // MEAS_CAP = 10b (with signature)

        // Algorithm selections
        private const uint AlgoSha256 = 0x00000001;
        private const uint AlgoEcdsaP256 = 0x00000010;
        private const byte MeasSpecDmtf = 0x01;

        // Transport limits
        // Default: MCTP serial max frame data = 255, minus MCTP header (5) minus CERTIFICATE header (8)
        private const int DefaultMaxCertChunkSize = 242;

        // Signing constants
        private const int Sha256DigestSize = 32;
        private const int EcdsaP256SignatureSize = 64;
        private static readonly byte[] SigningPrefixString = Encoding.ASCII.GetBytes("dmtf-spdm-v1.2.*");
        private const string ChallengeAuthContext = "responder-challenge_auth signing";
        private const string MeasurementsContext = "responder-measurements signing";

        // State machine
        private enum State { NotStarted, AfterVersion, AfterCapabilities, Negotiated }
        private State state = State.NotStarted;
        private byte negotiatedVersion = SpdmVersion12;

        // Crypto
        private ECDsa ecdsa;
        private byte[] certChainBuffer;  // spdm_cert_chain_t format
        private byte[] certChainHash;    // SHA-256 of certChainBuffer

        // Transcript tracking for signing
        private List<byte> vcaTranscript;
        private List<byte> certTranscript;

        private readonly SpdmScenarioConfig config;
        private readonly IEmulationElement logger;

        public SpdmProtocolHandler(SpdmScenarioConfig config, IEmulationElement logger)
        {
            this.config = config;
            this.logger = logger;
            vcaTranscript = new List<byte>();
            certTranscript = new List<byte>();

            InitializeCrypto();
        }

        private void InitializeCrypto()
        {
            if(config.PrivateKeyDer != null)
            {
                ecdsa = ECDsa.Create();
                ecdsa.ImportPkcs8PrivateKey(config.PrivateKeyDer, out _);
                logger.Log(LogLevel.Info, "SPDM: loaded ECDSA-P256 private key ({0} bytes)", config.PrivateKeyDer.Length);
            }
            else
            {
                logger.Log(LogLevel.Warning, "SPDM: no private key loaded, signing will fail");
            }

            if(config.CertChainDer != null)
            {
                BuildCertChainBuffer();
                logger.Log(LogLevel.Info, "SPDM: built cert chain buffer ({0} bytes)", certChainBuffer.Length);
            }
            else
            {
                logger.Log(LogLevel.Warning, "SPDM: no cert chain loaded, certificate operations will fail");
            }
        }

        private void BuildCertChainBuffer()
        {
            // spdm_cert_chain_t: [length: uint16 LE][reserved: uint16][root_hash: 32B][DER data]
            var certDer = config.CertChainDer;
            int totalLength = 4 + Sha256DigestSize + certDer.Length;

            // Hash the first (root CA) certificate for root_hash field
            byte[] rootCertDer = ExtractFirstDerCert(certDer);
            byte[] rootHash;
            using(var sha = SHA256.Create())
            {
                rootHash = sha.ComputeHash(rootCertDer);
            }

            certChainBuffer = new byte[totalLength];
            WriteUInt16LE(certChainBuffer, 0, (ushort)totalLength);
            // bytes 2-3 = reserved (0)
            Array.Copy(rootHash, 0, certChainBuffer, 4, Sha256DigestSize);
            Array.Copy(certDer, 0, certChainBuffer, 4 + Sha256DigestSize, certDer.Length);

            // Hash the entire cert chain buffer for DIGESTS response
            using(var sha = SHA256.Create())
            {
                certChainHash = sha.ComputeHash(certChainBuffer);
            }
        }

        // Extract the first DER certificate from a concatenated chain
        private static byte[] ExtractFirstDerCert(byte[] derChain)
        {
            if(derChain == null || derChain.Length < 2 || derChain[0] != 0x30)
            {
                return derChain ?? new byte[0];
            }

            int pos = 1;
            int contentLength;
            int headerLength;

            byte lenByte = derChain[pos];
            if(lenByte < 0x80)
            {
                contentLength = lenByte;
                headerLength = 2;
            }
            else if(lenByte == 0x81)
            {
                if(pos + 1 >= derChain.Length) return derChain;
                contentLength = derChain[pos + 1];
                headerLength = 3;
            }
            else if(lenByte == 0x82)
            {
                if(pos + 2 >= derChain.Length) return derChain;
                contentLength = (derChain[pos + 1] << 8) | derChain[pos + 2];
                headerLength = 4;
            }
            else if(lenByte == 0x83)
            {
                if(pos + 3 >= derChain.Length) return derChain;
                contentLength = (derChain[pos + 1] << 16) | (derChain[pos + 2] << 8) | derChain[pos + 3];
                headerLength = 5;
            }
            else
            {
                return derChain;
            }

            int certLength = headerLength + contentLength;
            if(certLength > derChain.Length)
            {
                certLength = derChain.Length;
            }

            var cert = new byte[certLength];
            Array.Copy(derChain, 0, cert, 0, certLength);
            return cert;
        }

        // Main entry point: handle an SPDM request message, return response
        public byte[] HandleRequest(byte[] spdmMessage)
        {
            if(spdmMessage == null || spdmMessage.Length < 4)
            {
                logger.Log(LogLevel.Warning, "SPDM: message too short ({0} bytes)",
                    spdmMessage != null ? spdmMessage.Length : 0);
                return BuildError(SpdmVersion10, ErrorInvalidRequest, 0);
            }

            byte version = spdmMessage[0];
            byte requestCode = spdmMessage[1];

            logger.Log(LogLevel.Debug, "SPDM: request code=0x{0:X2}, version=0x{1:X2}, len={2}",
                requestCode, version, spdmMessage.Length);

            switch(requestCode)
            {
                case RequestGetVersion:
                    return HandleGetVersion(spdmMessage);
                case RequestGetCapabilities:
                    return HandleGetCapabilities(spdmMessage);
                case RequestNegotiateAlgorithms:
                    return HandleNegotiateAlgorithms(spdmMessage);
                case RequestGetDigests:
                    return HandleGetDigests(spdmMessage);
                case RequestGetCertificate:
                    return HandleGetCertificate(spdmMessage);
                case RequestChallenge:
                    return HandleChallenge(spdmMessage);
                case RequestGetMeasurements:
                    return HandleGetMeasurements(spdmMessage);
                default:
                    logger.Log(LogLevel.Warning, "SPDM: unsupported request code 0x{0:X2}", requestCode);
                    return BuildError(negotiatedVersion, ErrorUnsupportedRequest, 0);
            }
        }

        private byte[] HandleGetVersion(byte[] req)
        {
            // GET_VERSION resets state and transcripts
            state = State.NotStarted;
            vcaTranscript = new List<byte>();
            certTranscript = new List<byte>();

            vcaTranscript.AddRange(req);

            bool v11Only = config.MaxSpdmVersion == SpdmVersion11;

            // VERSION response: header + reserved + count + entries
            int entryCount = v11Only ? 1 : 2;
            var resp = new byte[6 + entryCount * 2];
            resp[0] = SpdmVersion10;
            resp[1] = ResponseVersion;
            // resp[2] = 0; param1 reserved
            // resp[3] = 0; param2 reserved
            // resp[4] = 0; reserved
            resp[5] = (byte)entryCount;

            // Entry for SPDM 1.1: LE uint16 = 0x0011
            resp[6] = 0x00; // alpha + update
            resp[7] = 0x11; // minor + major

            if(!v11Only)
            {
                // Entry for SPDM 1.2: LE uint16 = 0x0012
                resp[8] = 0x00;
                resp[9] = 0x12;
            }

            vcaTranscript.AddRange(resp);
            state = State.AfterVersion;

            logger.Log(LogLevel.Debug, "SPDM: VERSION response ({0})",
                v11Only ? "1.1 only" : "1.1, 1.2");
            return resp;
        }

        private byte[] HandleGetCapabilities(byte[] req)
        {
            if(state != State.AfterVersion)
            {
                logger.Log(LogLevel.Warning, "SPDM: GET_CAPABILITIES in unexpected state {0}", state);
                return BuildError(SpdmVersion10, ErrorUnexpectedRequest, 0);
            }

            vcaTranscript.AddRange(req);

            // Use the version from the request (requester's selected version)
            negotiatedVersion = req[0];

            bool is12 = negotiatedVersion >= SpdmVersion12;
            int respLen = is12 ? 20 : 12;
            var resp = new byte[respLen];
            resp[0] = negotiatedVersion;
            resp[1] = ResponseCapabilities;
            // resp[2..3] = reserved
            // resp[4] = reserved
            // resp[5] = ct_exponent = 0

            // Flags: CERT + CHAL + MEAS_SIG
            uint flags = CapCert | CapChal | CapMeasSig;
            WriteUInt32LE(resp, 8, flags);

            if(is12)
            {
                // SPDM 1.2: without CHUNK_CAP, data_transfer_size must equal
                // max_spdm_msg_size (libspdm rejects mismatched values).
                WriteUInt32LE(resp, 12, 4096);   // data_transfer_size
                WriteUInt32LE(resp, 16, 4096);   // max_spdm_msg_size
            }

            vcaTranscript.AddRange(resp);
            state = State.AfterCapabilities;

            logger.Log(LogLevel.Debug, "SPDM: CAPABILITIES response (flags=0x{0:X8})", flags);
            return resp;
        }

        private byte[] HandleNegotiateAlgorithms(byte[] req)
        {
            if(state != State.AfterCapabilities)
            {
                logger.Log(LogLevel.Warning, "SPDM: NEGOTIATE_ALGORITHMS in unexpected state {0}", state);
                return BuildError(negotiatedVersion, ErrorUnexpectedRequest, 0);
            }

            vcaTranscript.AddRange(req);

            // ALGORITHMS response:
            // [header 4B][length 2B][meas_spec_sel 1B][other_params_sel 1B]
            // [meas_hash_algo 4B][base_asym_sel 4B][base_hash_sel 4B]
            // [reserved 12B][ext_asym_count 1B][ext_hash_count 1B][reserved 2B]
            int respLen = 36;
            var resp = new byte[respLen];
            resp[0] = negotiatedVersion;
            resp[1] = ResponseAlgorithms;
            // resp[2] = 0; param1 = num_alg_struct_tables
            // resp[3] = 0; param2 reserved

            WriteUInt16LE(resp, 4, (ushort)respLen);
            resp[6] = MeasSpecDmtf;              // measurement_specification_sel
            // resp[7] = 0;                      // other_params_support_sel

            WriteUInt32LE(resp, 8, AlgoSha256);    // measurement_hash_algo
            WriteUInt32LE(resp, 12, AlgoEcdsaP256); // base_asym_sel
            WriteUInt32LE(resp, 16, AlgoSha256);    // base_hash_sel

            // reserved 12B at offset 20..31 (zero)
            // ext_asym_sel_count=0, ext_hash_sel_count=0 at offset 32..33
            // reserved 2B at offset 34..35

            vcaTranscript.AddRange(resp);
            state = State.Negotiated;

            logger.Log(LogLevel.Debug, "SPDM: ALGORITHMS response (SHA-256, ECDSA-P256)");
            return resp;
        }

        private byte[] HandleGetDigests(byte[] req)
        {
            if(state != State.Negotiated)
            {
                return BuildError(negotiatedVersion, ErrorUnexpectedRequest, 0);
            }

            if(certChainHash == null)
            {
                return BuildError(negotiatedVersion, ErrorUnexpectedRequest, 0);
            }

            certTranscript.AddRange(req);

            // DIGESTS response: [header 4B][digest for slot 0: 32B]
            var resp = new byte[4 + Sha256DigestSize];
            resp[0] = negotiatedVersion;
            resp[1] = ResponseDigests;
            // resp[2] = 0; param1 reserved
            resp[3] = 0x01; // param2 = slot_mask (slot 0 only)

            Array.Copy(certChainHash, 0, resp, 4, Sha256DigestSize);

            certTranscript.AddRange(resp);

            logger.Log(LogLevel.Debug, "SPDM: DIGESTS response (slot 0)");
            return resp;
        }

        private byte[] HandleGetCertificate(byte[] req)
        {
            if(state != State.Negotiated)
            {
                return BuildError(negotiatedVersion, ErrorUnexpectedRequest, 0);
            }

            if(certChainBuffer == null)
            {
                return BuildError(negotiatedVersion, ErrorUnexpectedRequest, 0);
            }

            if(req.Length < 8)
            {
                return BuildError(negotiatedVersion, ErrorInvalidRequest, 0);
            }

            certTranscript.AddRange(req);

            byte slotId = req[2]; // param1
            ushort offset = ReadUInt16LE(req, 4);
            ushort length = ReadUInt16LE(req, 6);

            // Clamp to cert chain buffer bounds and configured max chunk size
            int maxChunk = config.MaxCertChunkSize > 0 ? config.MaxCertChunkSize : DefaultMaxCertChunkSize;
            int available = certChainBuffer.Length - offset;
            if(available < 0) available = 0;
            int portionLength = Math.Min(Math.Min((int)length, available), maxChunk);
            int remainder = certChainBuffer.Length - offset - portionLength;
            if(remainder < 0) remainder = 0;

            // CERTIFICATE response: [header 4B][portion_length 2B][remainder_length 2B][data]
            var resp = new byte[8 + portionLength];
            resp[0] = negotiatedVersion;
            resp[1] = ResponseCertificate;
            resp[2] = slotId; // param1 = slot_id
            // resp[3] = 0;   // param2 reserved

            WriteUInt16LE(resp, 4, (ushort)portionLength);
            WriteUInt16LE(resp, 6, (ushort)remainder);

            if(portionLength > 0)
            {
                Array.Copy(certChainBuffer, offset, resp, 8, portionLength);
            }

            certTranscript.AddRange(resp);

            logger.Log(LogLevel.Debug, "SPDM: CERTIFICATE response (offset={0}, portion={1}, remainder={2})",
                offset, portionLength, remainder);
            return resp;
        }

        private byte[] HandleChallenge(byte[] req)
        {
            if(state != State.Negotiated)
            {
                return BuildError(negotiatedVersion, ErrorUnexpectedRequest, 0);
            }

            if(req.Length < 36) // 4 header + 32 nonce
            {
                return BuildError(negotiatedVersion, ErrorInvalidRequest, 0);
            }

            if(ecdsa == null || certChainHash == null)
            {
                return BuildError(negotiatedVersion, ErrorUnexpectedRequest, 0);
            }

            byte slotId = req[2]; // param1
            byte measSummaryType = req[3]; // param2

            // Compute measurement summary hash if requested
            byte[] measSummaryHash = null;
            int measHashLen = 0;
            if(measSummaryType == 0x01 || measSummaryType == 0xFF)
            {
                measSummaryHash = ComputeMeasurementSummaryHash(measSummaryType);
                measHashLen = Sha256DigestSize;
            }

            // CHALLENGE_AUTH response (without signature):
            // [header 4B][cert_chain_hash 32B][nonce 32B][meas_summary 0/32B][opaque_len 2B]
            int respLenNoSig = 4 + Sha256DigestSize + 32 + measHashLen + 2;
            int respLen = respLenNoSig + EcdsaP256SignatureSize;

            var resp = new byte[respLen];
            resp[0] = negotiatedVersion;
            resp[1] = ResponseChallengeAuth;
            resp[2] = (byte)(slotId & 0x0F); // param1 = slot_id
            resp[3] = 0x01; // param2 = slot_mask

            // cert_chain_hash (slot 0)
            Array.Copy(certChainHash, 0, resp, 4, Sha256DigestSize);

            // Random nonce
            var nonce = new byte[32];
            using(var rng = RandomNumberGenerator.Create())
            {
                rng.GetBytes(nonce);
            }
            Array.Copy(nonce, 0, resp, 4 + Sha256DigestSize, 32);

            // Measurement summary hash (if requested)
            int pos = 4 + Sha256DigestSize + 32;
            if(measSummaryHash != null)
            {
                Array.Copy(measSummaryHash, 0, resp, pos, Sha256DigestSize);
                pos += Sha256DigestSize;
            }

            // opaque_length = 0
            WriteUInt16LE(resp, pos, 0);

            // Sign the challenge auth transcript
            logger.Log(LogLevel.Warning, "SPDM CHALLENGE_AUTH: VCA transcript={0} bytes, cert transcript={1} bytes",
                vcaTranscript.Count, certTranscript.Count);
            logger.Log(LogLevel.Warning, "SPDM CHALLENGE_AUTH: request={0} bytes, resp_no_sig={1} bytes",
                req.Length, respLenNoSig);
            logger.Log(LogLevel.Warning, "SPDM CHALLENGE_AUTH: VCA first 16B: {0}",
                BitConverter.ToString(vcaTranscript.GetRange(0, Math.Min(16, vcaTranscript.Count)).ToArray()));
            logger.Log(LogLevel.Warning, "SPDM CHALLENGE_AUTH: VCA last 16B: {0}",
                BitConverter.ToString(vcaTranscript.GetRange(Math.Max(0, vcaTranscript.Count - 16), Math.Min(16, vcaTranscript.Count)).ToArray()));
            logger.Log(LogLevel.Warning, "SPDM CHALLENGE_AUTH: cert first 16B: {0}",
                BitConverter.ToString(certTranscript.GetRange(0, Math.Min(16, certTranscript.Count)).ToArray()));
            logger.Log(LogLevel.Warning, "SPDM CHALLENGE_AUTH: req hex: {0}",
                req.Length <= 64 ? BitConverter.ToString(req) : BitConverter.ToString(req, 0, 64) + "...");
            logger.Log(LogLevel.Warning, "SPDM CHALLENGE_AUTH: resp_no_sig first 16B: {0}",
                BitConverter.ToString(resp, 0, Math.Min(16, respLenNoSig)));

            byte[] signature = SignTranscript(ChallengeAuthContext,
                vcaTranscript, certTranscript, req, resp, respLenNoSig);
            Array.Copy(signature, 0, resp, respLenNoSig, EcdsaP256SignatureSize);

            logger.Log(LogLevel.Debug, "SPDM: CHALLENGE_AUTH response (signed, meas_summary_type={0})",
                measSummaryType);
            return resp;
        }

        private byte[] HandleGetMeasurements(byte[] req)
        {
            if(state != State.Negotiated)
            {
                return BuildError(negotiatedVersion, ErrorUnexpectedRequest, 0);
            }

            if(req.Length < 4)
            {
                return BuildError(negotiatedVersion, ErrorInvalidRequest, 0);
            }

            byte attributes = req[2]; // param1
            byte operation = req[3];  // param2
            bool generateSig = (attributes & 0x01) != 0;

            // Build measurement record based on operation
            byte[] measurementRecord;
            byte numberOfBlocks;
            byte totalCount = (byte)config.Measurements.Count;

            if(operation == 0x00)
            {
                // Return total number of measurement indices (no blocks)
                numberOfBlocks = 0;
                measurementRecord = new byte[0];
            }
            else if(operation == 0xFF)
            {
                // Return all measurements
                BuildAllMeasurements(out measurementRecord, out numberOfBlocks);
            }
            else
            {
                // Return specific measurement by index
                BuildSingleMeasurement(operation, out measurementRecord, out numberOfBlocks);
            }

            // Calculate response size
            // [header 4B][number_of_blocks 1B][record_length 3B][record...][nonce 32B if sig][opaque_len 2B][sig 64B if sig]
            int respLenNoSig = 4 + 1 + 3 + measurementRecord.Length;
            if(generateSig)
            {
                respLenNoSig += 32; // nonce
            }
            respLenNoSig += 2; // opaque_length

            int respLen = respLenNoSig;
            if(generateSig)
            {
                respLen += EcdsaP256SignatureSize;
            }

            var resp = new byte[respLen];
            resp[0] = negotiatedVersion;
            resp[1] = ResponseMeasurements;

            if(generateSig)
            {
                resp[2] = 0x00; // param1: slot_id = 0
            }

            // param2: total number of measurement indices (for operation=0x00) or content_changed
            if(operation == 0x00)
            {
                resp[3] = totalCount;
            }

            int pos = 4;
            resp[pos++] = numberOfBlocks;

            // measurement_record_length (3 bytes LE, 24-bit)
            int recordLen = measurementRecord.Length;
            resp[pos++] = (byte)(recordLen & 0xFF);
            resp[pos++] = (byte)((recordLen >> 8) & 0xFF);
            resp[pos++] = (byte)((recordLen >> 16) & 0xFF);

            if(measurementRecord.Length > 0)
            {
                Array.Copy(measurementRecord, 0, resp, pos, measurementRecord.Length);
                pos += measurementRecord.Length;
            }

            if(generateSig)
            {
                // Random nonce
                var nonce = new byte[32];
                using(var rng = RandomNumberGenerator.Create())
                {
                    rng.GetBytes(nonce);
                }
                Array.Copy(nonce, 0, resp, pos, 32);
                pos += 32;
            }

            // opaque_length = 0
            WriteUInt16LE(resp, pos, 0);

            if(generateSig)
            {
                if(ecdsa == null)
                {
                    logger.Log(LogLevel.Warning, "SPDM: cannot sign measurements, no private key");
                    return BuildError(negotiatedVersion, ErrorUnexpectedRequest, 0);
                }

                // Measurements transcript: VCA + request + response (no sig)
                byte[] signature = SignTranscript(MeasurementsContext,
                    vcaTranscript, null, req, resp, respLenNoSig);
                Array.Copy(signature, 0, resp, respLenNoSig, EcdsaP256SignatureSize);
            }

            logger.Log(LogLevel.Debug, "SPDM: MEASUREMENTS response (op={0}, blocks={1}, signed={2})",
                operation, numberOfBlocks, generateSig);
            return resp;
        }

        // Build all measurement blocks
        private void BuildAllMeasurements(out byte[] record, out byte count)
        {
            var buf = new List<byte>();
            count = (byte)config.Measurements.Count;

            foreach(var m in config.Measurements)
            {
                AppendMeasurementBlock(buf, m);
            }

            record = buf.ToArray();
        }

        // Build a single measurement block by index
        private void BuildSingleMeasurement(byte index, out byte[] record, out byte count)
        {
            var buf = new List<byte>();
            count = 0;

            foreach(var m in config.Measurements)
            {
                if(m.Index == index)
                {
                    AppendMeasurementBlock(buf, m);
                    count = 1;
                    break;
                }
            }

            record = buf.ToArray();
        }

        // Append a DMTF measurement block to the buffer
        // Format: [index 1B][spec 1B][meas_size 2B LE][dmtf_type 1B][value_size 2B LE][value...]
        private static void AppendMeasurementBlock(List<byte> buf, SpdmMeasurementConfig m)
        {
            byte dmtfType = (byte)(0x80 | m.Type); // bit 7 = hash/digest
            int valueSize = m.Value.Length;
            int measDataSize = 1 + 2 + valueSize; // dmtf_type + value_size + value

            buf.Add(m.Index);
            buf.Add(MeasSpecDmtf); // measurement_specification = DMTF
            buf.Add((byte)(measDataSize & 0xFF));
            buf.Add((byte)((measDataSize >> 8) & 0xFF));

            buf.Add(dmtfType);
            buf.Add((byte)(valueSize & 0xFF));
            buf.Add((byte)((valueSize >> 8) & 0xFF));
            buf.AddRange(m.Value);
        }

        // Compute measurement summary hash for CHALLENGE_AUTH
        private byte[] ComputeMeasurementSummaryHash(byte summaryType)
        {
            // Hash(concatenation of measurement blocks for selected types)
            var concat = new List<byte>();

            foreach(var m in config.Measurements)
            {
                bool include = false;
                if(summaryType == 0xFF)
                {
                    include = true; // all measurements
                }
                else if(summaryType == 0x01)
                {
                    // TCB: ImmutableROM (0) and MutableFirmware (1)
                    include = (m.Type == 0 || m.Type == 1);
                }

                if(include)
                {
                    AppendMeasurementBlock(concat, m);
                }
            }

            if(concat.Count == 0)
            {
                return new byte[Sha256DigestSize];
            }

            using(var sha = SHA256.Create())
            {
                return sha.ComputeHash(concat.ToArray());
            }
        }

        // Sign a transcript for CHALLENGE_AUTH or MEASUREMENTS
        // certTrans may be null (for measurements)
        private byte[] SignTranscript(string contextString,
            List<byte> vcaTrans, List<byte> certTrans,
            byte[] request, byte[] response, int responseLenNoSig)
        {
            // m1m2 = VCA (message_a) || message_b || message_c
            var transcript = new List<byte>(
                vcaTrans.Count +
                (certTrans != null ? certTrans.Count : 0) +
                request.Length + responseLenNoSig);

            transcript.AddRange(vcaTrans);
            if(certTrans != null)
            {
                transcript.AddRange(certTrans);
            }
            transcript.AddRange(request);
            for(int i = 0; i < responseLenNoSig; i++)
            {
                transcript.Add(response[i]);
            }

            // TH = SHA-256(m1m2)
            byte[] transcriptHash;
            using(var sha2 = SHA256.Create())
            {
                transcriptHash = sha2.ComputeHash(transcript.ToArray());
            }

            logger.Log(LogLevel.Debug, "SPDM SignTranscript: version=0x{0:X2}, transcript={1} bytes",
                negotiatedVersion, transcript.Count);

            if(negotiatedVersion >= SpdmVersion12)
            {
                // SPDM 1.2+: TBS = prefix(100) + TH(32), verified via asym_verify (hashes internally)
                var tbs = BuildSigningTbs(contextString, transcriptHash);
                return ecdsa.SignData(tbs, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
            }
            else
            {
                // SPDM 1.0/1.1: sign the transcript hash directly — libspdm uses asym_verify_hash
                // which verifies without additional hashing, so we must use SignHash (not SignData)
                return ecdsa.SignHash(transcriptHash, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
            }
        }

        // Build the SPDM 1.2 to-be-signed data (DSP0274 Section 15)
        // [64 bytes: "dmtf-spdm-v1.2.*" x4][context string + zero padding to 100 total][message hash]
        private static byte[] BuildSigningTbs(string contextString, byte[] messageHash)
        {
            var prefix = new byte[100];

            // 4 copies of "dmtf-spdm-v1.2.*" (16 chars each) = 64 bytes
            int prefixLen = SigningPrefixString.Length; // 16
            for(int i = 0; i < 4; i++)
            {
                Array.Copy(SigningPrefixString, 0, prefix, i * prefixLen, prefixLen);
            }

            // Context field is 36 bytes at offset 64: zero padding first, then context string
            // (per SPDM 1.2 spec DSP0274 and libspdm's signing context layout)
            var contextBytes = Encoding.ASCII.GetBytes(contextString);
            int contextFieldOffset = prefixLen * 4; // 64
            int contextFieldLen = 100 - contextFieldOffset; // 36
            int zeroPadLen = contextFieldLen - contextBytes.Length;
            // Bytes [64..64+zeroPadLen-1] are zero (from new byte[100] initialization)
            Array.Copy(contextBytes, 0, prefix, contextFieldOffset + zeroPadLen, contextBytes.Length);

            // TBS = prefix (100) + message_hash
            var tbs = new byte[100 + messageHash.Length];
            Array.Copy(prefix, 0, tbs, 0, 100);
            Array.Copy(messageHash, 0, tbs, 100, messageHash.Length);

            return tbs;
        }

        private static byte[] BuildError(byte version, byte errorCode, byte errorData)
        {
            return new byte[] { version, ResponseError, errorCode, errorData };
        }

        private static void WriteUInt16LE(byte[] buf, int offset, ushort val)
        {
            buf[offset] = (byte)(val & 0xFF);
            buf[offset + 1] = (byte)((val >> 8) & 0xFF);
        }

        private static void WriteUInt32LE(byte[] buf, int offset, uint val)
        {
            buf[offset] = (byte)(val & 0xFF);
            buf[offset + 1] = (byte)((val >> 8) & 0xFF);
            buf[offset + 2] = (byte)((val >> 16) & 0xFF);
            buf[offset + 3] = (byte)((val >> 24) & 0xFF);
        }

        private static ushort ReadUInt16LE(byte[] buf, int offset)
        {
            return (ushort)(buf[offset] | (buf[offset + 1] << 8));
        }
    }
}
