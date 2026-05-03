//
// Copyright (c) 2010-2026 Antmicro
//
// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
//

using System;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using Antmicro.Renode.Network;

using Antmicro.Renode.Logging;

namespace Antmicro.Renode.Network
{
    /// <summary>
    /// Proxies a guest TCP connection to a real host TCP socket, providing
    /// guest→host NAT for the user-mode network. When the guest connects
    /// to the gateway IP, NatProxy opens a real socket to 127.0.0.1 on
    /// the same port and bridges data bidirectionally.
    /// </summary>
    public class NatProxy : IEmulationElement
    {
        public NatProxy(NetworkServer server, TcpConnection guestConn,
            string hostAddress, int hostPort)
        {
            this.server = server;
            this.guestConn = guestConn;
            this.hostAddress = hostAddress;
            this.hostPort = hostPort;
            establishedEvent = new ManualResetEventSlim(false);

            // Wire guest→host: data from guest arrives via TcpConnection
            guestConn.DataReceived += OnGuestData;
            guestConn.ConnectionClosed += OnGuestClosed;
            guestConn.StateChanged += OnStateChanged;
        }

        /// <summary>
        /// Initiate the host-side TCP connection and complete the
        /// SYN-ACK handshake with the guest.
        /// </summary>
        /// <returns>true if the host connection succeeded</returns>
        public bool Start()
        {
            try
            {
                hostSocket = new TcpClient();
                hostSocket.Connect(hostAddress, hostPort);
                hostStream = hostSocket.GetStream();

                this.Log(LogLevel.Debug, "Connected to host {0}:{1}",
                    hostAddress, hostPort);

                // Start reading from host socket in background
                hostReadThread = new Thread(HostReadLoop)
                {
                    IsBackground = true,
                    Name = $"NatProxy-{hostAddress}:{hostPort}"
                };
                hostReadThread.Start();

                return true;
            }
            catch(Exception ex)
            {
                this.Log(LogLevel.Warning,
                    "Failed to connect to host {0}:{1}: {2}",
                    hostAddress, hostPort, ex.Message);
                return false;
            }
        }

        public void Stop()
        {
            closed = true;
            try { hostStream?.Close(); } catch { }
            try { hostSocket?.Close(); } catch { }
        }

        // Guest sent data → forward to host socket
        private void OnGuestData(TcpConnection conn, byte[] data)
        {
            if(closed || hostStream == null)
            {
                return;
            }

            try
            {
                hostStream.Write(data, 0, data.Length);
                this.Log(LogLevel.Info,
                    "NAT proxy: guest→host {0} bytes", data.Length);
            }
            catch(Exception ex)
            {
                this.Log(LogLevel.Warning,
                    "NAT proxy: write to host failed: {0}", ex.Message);
                guestConn.Close();
                Stop();
            }
        }

        // Guest closed connection — respond with our FIN
        private void OnGuestClosed(TcpConnection conn)
        {
            this.Log(LogLevel.Debug, "Guest closed, sending our FIN");
            guestConn.Close();
            Stop();
        }

        // TcpConnection state changed — signal Established
        private void OnStateChanged(TcpConnection conn, TcpState newState)
        {
            if(newState == TcpState.Established)
            {
                this.Log(LogLevel.Debug, "Established, unblocking host read");
                establishedEvent.Set();
            }
        }

        // Background thread: read from host socket → send to guest
        private void HostReadLoop()
        {
            // Wait for the TCP handshake to complete before reading.
            // Without this, the host may send data (e.g. TLS ServerHello)
            // while we're still in SynReceived, causing Send() to drop it.
            if(!establishedEvent.Wait(5000))
            {
                this.Log(LogLevel.Warning, "Timed out waiting for Established");
                return;
            }

            var buffer = new byte[4096];
            try
            {
                while(!closed && hostSocket.Connected)
                {
                    int n = hostStream.Read(buffer, 0, buffer.Length);
                    if(n <= 0)
                    {
                        this.Log(LogLevel.Debug,
                            "Host EOF, will forward FIN to guest (state={0})",
                            guestConn.State);
                        break;
                    }

                    var data = new byte[n];
                    Array.Copy(buffer, data, n);

                    this.Log(LogLevel.Debug,
                        "host→guest {0} bytes (state={1})", n, guestConn.State);
                    guestConn.Send(data);
                }
            }
            catch(Exception ex)
            {
                if(!closed)
                {
                    this.Log(LogLevel.Warning, "Host read error: {0}", ex.Message);
                }
            }

            // Forward the host's FIN to the guest.
            //
            // TCP guarantees in-order delivery within a stream: every data
            // segment we sent via guestConn.Send() above received a sequence
            // number strictly less than the FIN's, so the guest's TCP stack
            // delivers the bytes to the application *before* signaling EOF.
            //
            // For TLS this means OpenSSL reads close_notify (carried inside
            // the data stream) before seeing the socket EOF, so the
            // SSL_R_UNEXPECTED_EOF_WHILE_READING / "premature EOF" path is
            // not triggered.
            //
            // Without this Close(), the guest application sees end-of-stream
            // at the TLS layer but its TCP socket stays in FIN_WAIT_2 forever
            // — curl on the guest reports CURLE_OPERATION_TIMEDOUT (RC=28)
            // even though every byte arrived correctly.
            if(!closed)
            {
                guestConn.Close();
            }
        }

        private readonly NetworkServer server;
        private readonly TcpConnection guestConn;
        private readonly string hostAddress;
        private readonly int hostPort;
        private readonly ManualResetEventSlim establishedEvent;

        private TcpClient hostSocket;
        private NetworkStream hostStream;
        private Thread hostReadThread;
        private volatile bool closed;
    }
}
