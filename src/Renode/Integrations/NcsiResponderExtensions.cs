// Copyright (c) 2026 Microsoft
// Licensed under the MIT license.
//
// Extension methods for creating and controlling NcsiResponder from Renode monitor.
// Usage:
//   emulation CreateNcsiResponder "ncsi"
//   emulation ConnectNcsiToMac "ncsi" sysbus.eth3
//   emulation NcsiInject "ncsi" 0 0 1       # returns response code
//   emulation NcsiGetState "ncsi"            # returns state summary

using System;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals.Network;

namespace Antmicro.Renode.Integrations
{
    public static class NcsiResponderExtensions
    {
        public static void CreateNcsiResponder(this Emulation emulation, string name)
        {
            emulation.ExternalsManager.AddExternal(new NcsiResponder(), name);
        }

        public static void ConnectNcsiToMac(this Emulation emulation,
            string ncsiName, IMACInterface mac)
        {
            var ncsi = GetNcsi(emulation, ncsiName);
            mac.FrameReady += frame => ncsi.ReceiveFrame(frame);
            ncsi.FrameReady += frame => mac.ReceiveFrame(frame);
        }

        public static int NcsiInject(this Emulation emulation,
            string ncsiName, int cmdType, int channelId, int instanceId)
        {
            var ncsi = GetNcsi(emulation, ncsiName);
            ncsi.InjectNcsiCommand(cmdType, channelId, instanceId);
            return ncsi.GetLastResponseCode();
        }

        public static int NcsiGetResponseCode(this Emulation emulation, string ncsiName)
        {
            return GetNcsi(emulation, ncsiName).GetLastResponseCode();
        }

        public static int NcsiGetReasonCode(this Emulation emulation, string ncsiName)
        {
            return GetNcsi(emulation, ncsiName).GetLastReasonCode();
        }

        public static bool NcsiIsPackageSelected(this Emulation emulation, string ncsiName)
        {
            return GetNcsi(emulation, ncsiName).IsPackageSelected();
        }

        public static bool NcsiIsChannelEnabled(this Emulation emulation,
            string ncsiName, int channel)
        {
            return GetNcsi(emulation, ncsiName).IsChannelEnabled(channel);
        }

        public static bool NcsiIsInitCleared(this Emulation emulation, string ncsiName)
        {
            return GetNcsi(emulation, ncsiName).IsInitialStateCleared();
        }

        public static bool NcsiIsLinkUp(this Emulation emulation, string ncsiName)
        {
            return GetNcsi(emulation, ncsiName).IsLinkUp();
        }

        public static void NcsiSetLinkUp(this Emulation emulation,
            string ncsiName, bool up)
        {
            GetNcsi(emulation, ncsiName).SetLinkUp(up);
        }

        public static int NcsiGetCommandCount(this Emulation emulation, string ncsiName)
        {
            return GetNcsi(emulation, ncsiName).GetCommandCount();
        }

        public static int NcsiGetResponseCount(this Emulation emulation, string ncsiName)
        {
            return GetNcsi(emulation, ncsiName).GetResponseCount();
        }

        public static int NcsiGetLastInstanceId(this Emulation emulation, string ncsiName)
        {
            return GetNcsi(emulation, ncsiName).GetLastInstanceId();
        }

        public static void NcsiReset(this Emulation emulation, string ncsiName)
        {
            GetNcsi(emulation, ncsiName).Reset();
        }

        private static NcsiResponder GetNcsi(Emulation emulation, string name)
        {
            IExternal ext;
            if(!emulation.ExternalsManager.TryGetByName(name, out ext))
            {
                throw new Antmicro.Renode.Exceptions.RecoverableException(
                    string.Format("NCSI responder '{0}' not found", name));
            }
            var ncsi = ext as NcsiResponder;
            if(ncsi == null)
            {
                throw new Antmicro.Renode.Exceptions.RecoverableException(
                    string.Format("'{0}' is not an NcsiResponder", name));
            }
            return ncsi;
        }
    }
}
