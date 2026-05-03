//
// Copyright (c) 2010-2026 Antmicro
//
// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
//

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

using Antmicro.Renode.Logging;

namespace Antmicro.Renode.Network
{
    public class PortForwardRule
    {
        public IPAddress HostAddress { get; set; }
        public int HostPort { get; set; }
        public IPAddress GuestAddress { get; set; }
        public int GuestPort { get; set; }
    }

    // Bridges host TCP sockets to emulated TCP connections through the NetworkServer.
    // For each port-forward rule, listens on a host TCP port and creates a
    // TcpConnection to the guest when a host client connects.
    public class PortForwarder : IDisposable, IEmulationElement
    {
        public PortForwarder(NetworkServer server)
        {
            this.server = server;
            listeners = new List<TcpListener>();
            activeBridges = new ConcurrentDictionary<TcpConnection, BridgeState>();
            cts = new CancellationTokenSource();
        }

        public void AddRule(PortForwardRule rule)
        {
            var listener = new TcpListener(rule.HostAddress, rule.HostPort);
            listener.Start();
            listeners.Add(listener);

            this.Log(LogLevel.Info, "Port forward: {0}:{1} → guest {2}:{3}",
                rule.HostAddress, rule.HostPort, rule.GuestAddress, rule.GuestPort);

            Task.Run(() => AcceptLoop(listener, rule, cts.Token), cts.Token);
        }

        public void Dispose()
        {
            cts.Cancel();
            foreach(var listener in listeners)
            {
                try { listener.Stop(); } catch { }
            }
            foreach(var kvp in activeBridges)
            {
                try { kvp.Value.HostSocket?.Close(); } catch { }
                try { kvp.Key.Close(); } catch { }
            }
            activeBridges.Clear();
        }

        private async Task AcceptLoop(TcpListener listener, PortForwardRule rule, CancellationToken ct)
        {
            while(!ct.IsCancellationRequested)
            {
                try
                {
                    var client = await listener.AcceptTcpClientAsync();
                    this.Log(LogLevel.Info, "Host connection on port {0}, forwarding to guest {1}:{2}",
                        rule.HostPort, rule.GuestAddress, rule.GuestPort);

                    _ = Task.Run(() => HandleConnection(client, rule, ct), ct);
                }
                catch(ObjectDisposedException)
                {
                    break;
                }
                catch(Exception ex)
                {
                    if(!ct.IsCancellationRequested)
                    {
                        this.Log(LogLevel.Warning, "Accept error: {0}", ex.Message);
                    }
                }
            }
        }

        private void HandleConnection(TcpClient client, PortForwardRule rule, CancellationToken ct)
        {
            var ephemeralPort = (ushort)Interlocked.Increment(ref nextEphemeralPort);
            if(nextEphemeralPort > 65000) nextEphemeralPort = 49152;

            var conn = server.CreateTcpConnection(
                ephemeralPort,
                rule.GuestAddress,
                (ushort)rule.GuestPort);

            if(conn == null)
            {
                this.Log(LogLevel.Warning, "Failed to create TCP connection");
                client.Close();
                return;
            }

            var bridge = new BridgeState
            {
                HostClient = client,
                HostSocket = client.Client,
                Connection = conn,
                Ct = ct,
            };
            activeBridges[conn] = bridge;

            // When guest sends data, forward to host socket
            conn.DataReceived += (c, data) =>
            {
                try
                {
                    if(bridge.HostSocket.Connected)
                    {
                        bridge.HostSocket.Send(data);
                    }
                }
                catch(Exception ex)
                {
                    this.Log(LogLevel.Debug, "Error writing to host socket: {0}", ex.Message);
                    CleanupBridge(conn);
                }
            };

            // When guest closes, close host socket
            conn.ConnectionClosed += c =>
            {
                this.Log(LogLevel.Debug, "Guest closed connection");
                CleanupBridge(c);
            };

            // When connection is established, start reading from host socket
            conn.StateChanged += (c, state) =>
            {
                if(state == TcpState.Established)
                {
                    this.Log(LogLevel.Info, "TCP connection established to guest {0}:{1}",
                        rule.GuestAddress, rule.GuestPort);
                    _ = Task.Run(() => HostReadLoop(bridge), ct);
                }
            };

            // Initiate TCP handshake with guest
            conn.Connect();

            // Wait for connection or timeout
            var timeout = DateTime.UtcNow.AddSeconds(ConnectTimeoutSec);
            while(conn.State == TcpState.SynSent && DateTime.UtcNow < timeout && !ct.IsCancellationRequested)
            {
                Thread.Sleep(10);
            }

            if(conn.State != TcpState.Established)
            {
                this.Log(LogLevel.Warning, "TCP handshake failed (state={0})", conn.State);
                CleanupBridge(conn);
            }
        }

        private void HostReadLoop(BridgeState bridge)
        {
            var buffer = new byte[ReadBufferSize];
            try
            {
                while(!bridge.Ct.IsCancellationRequested && bridge.HostSocket.Connected)
                {
                    int bytesRead = bridge.HostSocket.Receive(buffer);
                    if(bytesRead == 0)
                    {
                        this.Log(LogLevel.Debug, "Host socket closed (EOF)");
                        bridge.Connection.Close();
                        break;
                    }

                    var data = new byte[bytesRead];
                    Array.Copy(buffer, data, bytesRead);
                    bridge.Connection.Send(data);
                }
            }
            catch(SocketException ex)
            {
                this.Log(LogLevel.Debug, "Host socket error: {0}", ex.Message);
            }
            catch(ObjectDisposedException)
            {
                // Socket was closed
            }
            finally
            {
                CleanupBridge(bridge.Connection);
            }
        }

        private void CleanupBridge(TcpConnection conn)
        {
            if(activeBridges.TryRemove(conn, out var bridge))
            {
                try { bridge.HostClient?.Close(); } catch { }
                if(conn.State == TcpState.Established || conn.State == TcpState.CloseWait)
                {
                    try { conn.Close(); } catch { }
                }
                server.RemoveTcpConnection(conn);
                this.Log(LogLevel.Debug, "Bridge cleaned up");
            }
        }

        private class BridgeState
        {
            public TcpClient HostClient;
            public Socket HostSocket;
            public TcpConnection Connection;
            public CancellationToken Ct;
        }

        private readonly NetworkServer server;
        private readonly List<TcpListener> listeners;
        private readonly ConcurrentDictionary<TcpConnection, BridgeState> activeBridges;
        private readonly CancellationTokenSource cts;

        private int nextEphemeralPort = 49152;

        private const int ConnectTimeoutSec = 10;
        private const int ReadBufferSize = 32768;
    }
}
