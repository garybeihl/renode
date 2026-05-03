//
// Copyright (c) 2010-2026 Antmicro
//
// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
//

using System.Net;

using Antmicro.Renode.Core;
using Antmicro.Renode.Exceptions;
using Antmicro.Renode.Logging;

namespace Antmicro.Renode.Network
{
    public static class UserNetworkExtensions
    {
        // Creates a user-mode network with DHCP server, virtual switch,
        // and connects it to the specified machine ethernet interface.
        //
        // Usage from Renode monitor:
        //   emulation CreateUserNetwork "net" "10.0.2.2" "10.0.2.15"
        //   connector Connect net switch
        //
        // Or the all-in-one helper:
        //   emulation CreateUserNetworkWithSwitch "net" "switch" "10.0.2.2" "10.0.2.15"
        public static void CreateUserNetwork(this Emulation emulation,
            string name, string gatewayIP, string guestIP,
            string subnetMask = "255.255.255.0")
        {
            var server = new NetworkServer(gatewayIP);
            emulation.ExternalsManager.AddExternal(server, name);

            // Start DHCP to auto-assign guest IP
            server.StartDHCP(guestIP, subnetMask);

            // Start DNS that resolves all queries to the gateway
            var dns = new DnsServerModule(IPAddress.Parse(gatewayIP));
            server.RegisterModule(dns, 53, "dns");

            Logger.Log(LogLevel.Info,
                "User network '{0}': gateway={1}, guest={2}, mask={3}",
                name, gatewayIP, guestIP, subnetMask);
        }

        // Adds a port forwarding rule to an existing user network.
        //
        // Usage from Renode monitor:
        //   net AddPortForward "127.0.0.1" 2443 "10.0.2.15" 443
        public static void AddPortForward(this NetworkServer server,
            string hostAddress, int hostPort, string guestAddress, int guestPort)
        {
            server.AddPortForward(hostAddress, hostPort, guestAddress, guestPort);
        }

        // Enable guest→host NAT. When the guest opens a TCP connection to
        // the gateway IP, Renode proxies it to 127.0.0.1 on the same port.
        //
        // Usage from Renode monitor:
        //   net EnableNat
        public static void EnableNat(this NetworkServer server)
        {
            server.EnableNat();
        }
    }
}
