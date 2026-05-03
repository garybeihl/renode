//
// Copyright (c) 2026 Microsoft
//
// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
//
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;

namespace Antmicro.Renode.Integrations
{
    public class SpdmMeasurementConfig
    {
        public byte Index;
        public byte Type;         // 0=ImmutableROM, 1=MutableFirmware, 2=HwConfig, 3=FwConfig
        public string Description;
        public byte[] Value;      // Raw hash bytes (32 for SHA-256)
    }

    public class SpdmScenarioConfig
    {
        public byte Eid = 20;
        public byte[] Uuid = { 0x16, 0x20, 0x23, 0xC9, 0x3E, 0xC5, 0x41, 0x15,
                                0x95, 0xF4, 0x48, 0x70, 0x1D, 0x49, 0xD6, 0x75 };
        public string Name = "SPDM-Device";
        public string KeyDirectory;
        public string CertChainFile;
        public string PrivateKeyFile;
        public List<SpdmMeasurementConfig> Measurements = new List<SpdmMeasurementConfig>();

        // Optional: stop responding after this many SPDM messages (0 = unlimited)
        public int MaxSpdmResponses;

        // Optional: max cert chain bytes per GET_CERTIFICATE response (0 = use default 242)
        public int MaxCertChunkSize;

        // Optional: max SPDM version to advertise (0x11 = 1.1 only, 0 or 0x12 = 1.1+1.2)
        public byte MaxSpdmVersion;

        // Optional: advertise SPDM message type in GetMessageTypeSupport (default true)
        public bool AdvertiseSpdm = true;

        // Populated after loading from files
        public byte[] CertChainDer;   // Raw DER cert chain
        public byte[] PrivateKeyDer;  // PKCS#8 DER private key

        public static SpdmScenarioConfig LoadDefaults()
        {
            var cfg = new SpdmScenarioConfig();
            cfg.Measurements.Add(new SpdmMeasurementConfig
            {
                Index = 1,
                Type = 0, // ImmutableROM
                Description = "Boot ROM firmware hash",
                Value = new byte[32] // all zeros placeholder
            });
            return cfg;
        }

        public static SpdmScenarioConfig LoadFromFile(string path, string keyDirOverride = null)
        {
            var text = File.ReadAllText(path);
            var cfg = new SpdmScenarioConfig();
            var root = SimpleJsonParser.Parse(text);

            if(root.ContainsKey("device"))
            {
                var dev = root["device"] as Dictionary<string, object>;
                if(dev != null)
                {
                    if(dev.ContainsKey("eid")) cfg.Eid = Convert.ToByte(dev["eid"]);
                    if(dev.ContainsKey("name")) cfg.Name = dev["name"] as string ?? cfg.Name;
                    if(dev.ContainsKey("uuid"))
                    {
                        cfg.Uuid = ParseUuid(dev["uuid"] as string);
                    }
                }
            }

            if(root.ContainsKey("spdm"))
            {
                var spdm = root["spdm"] as Dictionary<string, object>;
                if(spdm != null)
                {
                    if(spdm.ContainsKey("key_dir"))
                    {
                        var raw = spdm["key_dir"] as string;
                        // Relative key_dir resolves against the scenario file's
                        // directory, so scenarios are portable across machines.
                        if(!string.IsNullOrEmpty(raw) && !Path.IsPathRooted(raw))
                        {
                            var baseDir = Path.GetDirectoryName(Path.GetFullPath(path));
                            raw = Path.Combine(baseDir, raw);
                        }
                        cfg.KeyDirectory = raw;
                    }
                    if(spdm.ContainsKey("cert_chain"))
                    {
                        cfg.CertChainFile = spdm["cert_chain"] as string;
                    }
                    if(spdm.ContainsKey("private_key"))
                    {
                        cfg.PrivateKeyFile = spdm["private_key"] as string;
                    }
                    if(spdm.ContainsKey("max_responses"))
                    {
                        cfg.MaxSpdmResponses = Convert.ToInt32(spdm["max_responses"]);
                    }
                    if(spdm.ContainsKey("max_cert_chunk_size"))
                    {
                        cfg.MaxCertChunkSize = Convert.ToInt32(spdm["max_cert_chunk_size"]);
                    }
                    if(spdm.ContainsKey("max_spdm_version"))
                    {
                        var verStr = spdm["max_spdm_version"] as string;
                        if(verStr == "1.1") cfg.MaxSpdmVersion = 0x11;
                        else if(verStr == "1.2") cfg.MaxSpdmVersion = 0x12;
                    }
                    if(spdm.ContainsKey("advertise_spdm"))
                    {
                        cfg.AdvertiseSpdm = Convert.ToBoolean(spdm["advertise_spdm"]);
                    }
                    if(spdm.ContainsKey("measurements"))
                    {
                        var measList = spdm["measurements"] as List<object>;
                        if(measList != null)
                        {
                            cfg.Measurements.Clear();
                            foreach(var item in measList)
                            {
                                var jm = item as Dictionary<string, object>;
                                if(jm == null) continue;
                                var mc = new SpdmMeasurementConfig();
                                if(jm.ContainsKey("index")) mc.Index = Convert.ToByte(jm["index"]);
                                if(jm.ContainsKey("description")) mc.Description = jm["description"] as string ?? "";
                                if(jm.ContainsKey("type"))
                                {
                                    mc.Type = ParseMeasurementType(jm["type"] as string);
                                }
                                if(jm.ContainsKey("value"))
                                {
                                    mc.Value = ParseHexString(jm["value"] as string);
                                }
                                else
                                {
                                    mc.Value = new byte[32];
                                }
                                cfg.Measurements.Add(mc);
                            }
                        }
                    }
                }
            }

            // Override key_dir from constructor parameter if provided
            if(!string.IsNullOrEmpty(keyDirOverride))
            {
                cfg.KeyDirectory = keyDirOverride;
            }

            // Load cert chain and private key files
            cfg.LoadKeyFiles();

            return cfg;
        }

        private void LoadKeyFiles()
        {
            if(string.IsNullOrEmpty(KeyDirectory))
            {
                return;
            }

            if(!string.IsNullOrEmpty(CertChainFile))
            {
                var certPath = Path.Combine(KeyDirectory, CertChainFile);
                if(File.Exists(certPath))
                {
                    CertChainDer = File.ReadAllBytes(certPath);
                }
            }

            if(!string.IsNullOrEmpty(PrivateKeyFile))
            {
                var keyPath = Path.Combine(KeyDirectory, PrivateKeyFile);
                if(File.Exists(keyPath))
                {
                    PrivateKeyDer = File.ReadAllBytes(keyPath);
                }
            }
        }

        private static byte ParseMeasurementType(string s)
        {
            if(s == null) return 0;
            switch(s)
            {
                case "ImmutableROM": return 0;
                case "MutableFirmware": return 1;
                case "HardwareConfiguration": return 2;
                case "FirmwareConfiguration": return 3;
                default: return 0;
            }
        }

        private static byte[] ParseHexString(string s)
        {
            if(s == null || s.Length == 0 || s.Length % 2 != 0)
            {
                return new byte[32];
            }
            var result = new byte[s.Length / 2];
            for(int i = 0; i < result.Length; i++)
            {
                result[i] = byte.Parse(s.Substring(i * 2, 2), NumberStyles.HexNumber);
            }
            return result;
        }

        private static byte[] ParseUuid(string s)
        {
            if(s == null) return new byte[16];
            var hex = s.Replace("-", "");
            if(hex.Length != 32) return new byte[16];
            var result = new byte[16];
            for(int i = 0; i < 16; i++)
            {
                result[i] = byte.Parse(hex.Substring(i * 2, 2), NumberStyles.HexNumber);
            }
            return result;
        }
    }
}
