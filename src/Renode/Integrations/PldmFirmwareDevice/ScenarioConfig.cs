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
using System.Text;

namespace Antmicro.Renode.Integrations
{
    public class ComponentConfig
    {
        public ushort Id;
        public ushort Classification = 10;
        public string Version = "";
        public bool CanUpdate = true;
        public byte RejectReason = PldmEncoder.CompCanBeUpdated;
        public byte VerifyResult = PldmEncoder.VerifySuccess;
        public byte ApplyResult = PldmEncoder.ApplySuccess;
        public bool ActivateSelf = true;
        // Test-only: truncate the UpdateComponent response so the BMC's
        // decode_update_component_resp() fails. Used to exercise the decode
        // failure path in pldmd.
        public bool MalformedUpdateComponentResponse = false;
    }

    public class SensorConfig
    {
        public ushort Id = 1;
        public byte DataSize = PldmEncoder.SensorDataSizeUint32;
        public long Value;
        public byte BaseUnit = 0; // unitless
        public sbyte UnitModifier = 0;
    }

    public class ScenarioConfig
    {
        public byte Eid = 20;
        public byte Tid = 1;
        public byte[] Uuid = { 0x16, 0x20, 0x23, 0xC9, 0x3E, 0xC5, 0x41, 0x15,
                                0x95, 0xF4, 0x48, 0x70, 0x1D, 0x49, 0xD6, 0x75 };
        public string Name = "MockDevice";
        public ushort EntityType = 0x0045; // PLDM_ENTITY_BOARD
        public uint MaxTransferSize = 4096;
        public byte[] PldmVersion = { 0xF1, 0xF1, 0xF0 }; // 1.1.0
        public string ImageSetVersion = "1.0.0";
        public List<ComponentConfig> Components = new List<ComponentConfig>();
        public List<SensorConfig> Sensors = new List<SensorConfig>();
        public bool PlatformEnabled = false;

        public static ScenarioConfig LoadDefaults()
        {
            var cfg = new ScenarioConfig();
            cfg.Components.Add(new ComponentConfig
            {
                Id = 100, Classification = 10, Version = "RejectMe1.0",
                CanUpdate = false, RejectReason = PldmEncoder.CompNotSupported
            });
            cfg.Components.Add(new ComponentConfig
            {
                Id = 200, Classification = 10, Version = "AcceptMe1.0",
                CanUpdate = true
            });
            return cfg;
        }

        public static ScenarioConfig LoadFromFile(string path)
        {
            var text = File.ReadAllText(path);
            var cfg = new ScenarioConfig();
            var root = SimpleJsonParser.Parse(text);

            if(root.ContainsKey("device"))
            {
                var dev = root["device"] as Dictionary<string, object>;
                if(dev != null)
                {
                    if(dev.ContainsKey("eid")) cfg.Eid = ToByte(dev["eid"]);
                    if(dev.ContainsKey("tid")) cfg.Tid = ToByte(dev["tid"]);
                    if(dev.ContainsKey("name")) cfg.Name = dev["name"] as string ?? cfg.Name;
                    if(dev.ContainsKey("entity_type")) cfg.EntityType = ToUInt16(dev["entity_type"]);
                    if(dev.ContainsKey("max_transfer_size")) cfg.MaxTransferSize = ToUInt32(dev["max_transfer_size"]);
                    if(dev.ContainsKey("uuid"))
                    {
                        cfg.Uuid = ParseUuid(dev["uuid"] as string);
                    }
                }
            }

            if(root.ContainsKey("firmware_update"))
            {
                var fw = root["firmware_update"] as Dictionary<string, object>;
                if(fw != null)
                {
                    if(fw.ContainsKey("image_set_version"))
                    {
                        cfg.ImageSetVersion = fw["image_set_version"] as string ?? cfg.ImageSetVersion;
                    }
                    if(fw.ContainsKey("components"))
                    {
                        var comps = fw["components"] as List<object>;
                        if(comps != null)
                        {
                            cfg.Components.Clear();
                            foreach(var item in comps)
                            {
                                var jc = item as Dictionary<string, object>;
                                if(jc == null) continue;
                                var sc = new ComponentConfig();
                                if(jc.ContainsKey("id")) sc.Id = ToUInt16(jc["id"]);
                                if(jc.ContainsKey("classification")) sc.Classification = ToUInt16(jc["classification"]);
                                if(jc.ContainsKey("version")) sc.Version = jc["version"] as string ?? "";
                                if(jc.ContainsKey("can_update")) sc.CanUpdate = (bool)jc["can_update"];
                                if(jc.ContainsKey("activate_self")) sc.ActivateSelf = (bool)jc["activate_self"];
                                if(jc.ContainsKey("reject_reason"))
                                {
                                    sc.RejectReason = ParseRejectReason(jc["reject_reason"] as string);
                                }
                                if(jc.ContainsKey("verify_result"))
                                {
                                    sc.VerifyResult = ParseVerifyResult(jc["verify_result"] as string);
                                }
                                if(jc.ContainsKey("apply_result"))
                                {
                                    sc.ApplyResult = ParseApplyResult(jc["apply_result"] as string);
                                }
                                if(jc.ContainsKey("malformed_update_component_response"))
                                {
                                    sc.MalformedUpdateComponentResponse = (bool)jc["malformed_update_component_response"];
                                }
                                cfg.Components.Add(sc);
                            }
                        }
                    }
                }
            }

            if(root.ContainsKey("platform"))
            {
                var plat = root["platform"] as Dictionary<string, object>;
                if(plat != null)
                {
                    if(plat.ContainsKey("enabled"))
                    {
                        cfg.PlatformEnabled = (bool)plat["enabled"];
                    }
                    if(plat.ContainsKey("sensors"))
                    {
                        var sensors = plat["sensors"] as List<object>;
                        if(sensors != null)
                        {
                            foreach(var item in sensors)
                            {
                                var js = item as Dictionary<string, object>;
                                if(js == null) continue;
                                var sc = new SensorConfig();
                                if(js.ContainsKey("id")) sc.Id = ToUInt16(js["id"]);
                                if(js.ContainsKey("data_size"))
                                {
                                    sc.DataSize = ParseDataSize(js["data_size"] as string);
                                }
                                if(js.ContainsKey("value"))
                                {
                                    sc.Value = Convert.ToInt64(js["value"]);
                                }
                                if(js.ContainsKey("base_unit")) sc.BaseUnit = ToByte(js["base_unit"]);
                                if(js.ContainsKey("unit_modifier"))
                                {
                                    sc.UnitModifier = (sbyte)Convert.ToInt32(js["unit_modifier"]);
                                }
                                cfg.Sensors.Add(sc);
                            }
                        }
                    }
                }
            }

            if(cfg.Components.Count == 0)
            {
                return LoadDefaults();
            }

            return cfg;
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

        private static byte ParseRejectReason(string s)
        {
            switch(s)
            {
                case "COMP_NOT_SUPPORTED": return 0x06;
                case "COMP_COMPARISON_STAMP_IDENTICAL": return 0x01;
                case "COMP_COMPARISON_STAMP_LOWER": return 0x02;
                case "COMP_CONFLICT": return 0x03;
                case "COMP_PREREQUISITES_NOT_MET": return 0x04;
                case "COMP_SECURITY_RESTRICTIONS": return 0x09;
                case "COMP_VER_STR_IDENTICAL": return 0x0A;
                case "COMP_VER_STR_LOWER": return 0x0B;
                default: return 0x06; // COMP_NOT_SUPPORTED
            }
        }

        private static byte ParseVerifyResult(string s)
        {
            switch(s)
            {
                case "SUCCESS": return PldmEncoder.VerifySuccess;
                case "VERIFICATION_FAILURE": return PldmEncoder.VerifyErrorVerificationFailure;
                case "VERSION_MISMATCH": return PldmEncoder.VerifyErrorVersionMismatch;
                case "FAILED_FD_SECURITY_CHECKS": return PldmEncoder.VerifyFailedFdSecurityChecks;
                case "IMAGE_INCOMPLETE": return PldmEncoder.VerifyErrorImageIncomplete;
                default: return PldmEncoder.VerifySuccess;
            }
        }

        private static byte ParseApplyResult(string s)
        {
            switch(s)
            {
                case "SUCCESS": return PldmEncoder.ApplySuccess;
                case "SUCCESS_WITH_ACTIVATION_METHOD": return PldmEncoder.ApplySuccessWithActivationMethod;
                case "FAILURE_MEMORY_ISSUE": return PldmEncoder.ApplyFailureMemoryIssue;
                default: return PldmEncoder.ApplySuccess;
            }
        }

        private static byte ParseDataSize(string s)
        {
            switch(s)
            {
                case "UINT8": return PldmEncoder.SensorDataSizeUint8;
                case "SINT8": return PldmEncoder.SensorDataSizeSint8;
                case "UINT16": return PldmEncoder.SensorDataSizeUint16;
                case "SINT16": return PldmEncoder.SensorDataSizeSint16;
                case "UINT32": return PldmEncoder.SensorDataSizeUint32;
                case "SINT32": return PldmEncoder.SensorDataSizeSint32;
                case "UINT64": return PldmEncoder.SensorDataSizeUint64;
                case "SINT64": return PldmEncoder.SensorDataSizeSint64;
                default: return PldmEncoder.SensorDataSizeUint32;
            }
        }

        private static byte ToByte(object o) { return Convert.ToByte(o); }
        private static ushort ToUInt16(object o) { return Convert.ToUInt16(o); }
        private static uint ToUInt32(object o) { return Convert.ToUInt32(o); }
    }

    // Minimal JSON parser for our simple scenario format
    internal static class SimpleJsonParser
    {
        public static Dictionary<string, object> Parse(string json)
        {
            int pos = 0;
            return ParseObject(json, ref pos);
        }

        private static void SkipWhitespace(string s, ref int pos)
        {
            while(pos < s.Length && char.IsWhiteSpace(s[pos])) pos++;
        }

        private static Dictionary<string, object> ParseObject(string s, ref int pos)
        {
            var dict = new Dictionary<string, object>();
            SkipWhitespace(s, ref pos);
            if(pos >= s.Length || s[pos] != '{') return dict;
            pos++; // skip '{'

            while(true)
            {
                SkipWhitespace(s, ref pos);
                if(pos >= s.Length || s[pos] == '}') { pos++; break; }
                if(s[pos] == ',') { pos++; continue; }

                var key = ParseString(s, ref pos);
                SkipWhitespace(s, ref pos);
                if(pos < s.Length && s[pos] == ':') pos++;
                SkipWhitespace(s, ref pos);
                var value = ParseValue(s, ref pos);
                dict[key] = value;
            }
            return dict;
        }

        private static List<object> ParseArray(string s, ref int pos)
        {
            var list = new List<object>();
            pos++; // skip '['

            while(true)
            {
                SkipWhitespace(s, ref pos);
                if(pos >= s.Length || s[pos] == ']') { pos++; break; }
                if(s[pos] == ',') { pos++; continue; }
                list.Add(ParseValue(s, ref pos));
            }
            return list;
        }

        private static object ParseValue(string s, ref int pos)
        {
            SkipWhitespace(s, ref pos);
            if(pos >= s.Length) return null;

            switch(s[pos])
            {
                case '"': return ParseString(s, ref pos);
                case '{': return ParseObject(s, ref pos);
                case '[': return ParseArray(s, ref pos);
                case 't':
                    pos += 4; // "true"
                    return true;
                case 'f':
                    pos += 5; // "false"
                    return false;
                case 'n':
                    pos += 4; // "null"
                    return null;
                default:
                    return ParseNumber(s, ref pos);
            }
        }

        private static string ParseString(string s, ref int pos)
        {
            if(s[pos] != '"') return "";
            pos++; // skip opening quote
            var sb = new StringBuilder();
            while(pos < s.Length && s[pos] != '"')
            {
                if(s[pos] == '\\')
                {
                    pos++;
                    if(pos < s.Length)
                    {
                        sb.Append(s[pos]);
                        pos++;
                    }
                }
                else
                {
                    sb.Append(s[pos]);
                    pos++;
                }
            }
            if(pos < s.Length) pos++; // skip closing quote
            return sb.ToString();
        }

        private static object ParseNumber(string s, ref int pos)
        {
            int start = pos;
            if(pos < s.Length && s[pos] == '-') pos++;
            while(pos < s.Length && (char.IsDigit(s[pos]) || s[pos] == '.')) pos++;
            var numStr = s.Substring(start, pos - start);
            if(numStr.Contains("."))
            {
                return double.Parse(numStr, CultureInfo.InvariantCulture);
            }
            long val = long.Parse(numStr, CultureInfo.InvariantCulture);
            return val;
        }
    }
}
