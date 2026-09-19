#!/usr/bin/env python3
"""The network peer: a separate container, so its traffic crosses the box's eth0 exactly as an LLM API or a
client on the internet would (loopback is invisible to a provider's network-idle timer). First line of each
connection selects the behaviour:

  HOLD                       accept and hold the connection idle until the client closes (a keepalive)
  SLOW <wait> <stream>       stay silent for <wait> s, then send ~5 lines/s for <stream> s, then close
  HIT <host> <port> <period> <duration>
                             act as a CLIENT: GET / on host:port every <period> s for <duration> s
                             (returns OK at once; the hitting runs in the background)
"""

import socket
import socketserver
import threading
import time


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        parts = self.rfile.readline().decode().split()
        if not parts:
            return
        cmd = parts[0]
        if cmd == "HOLD":
            while self.request.recv(1):
                pass
        elif cmd == "SLOW":
            time.sleep(float(parts[1]))
            end = time.monotonic() + float(parts[2])
            while time.monotonic() < end:
                self.wfile.write(b"token token token token\n")
                self.wfile.flush()
                time.sleep(0.2)
        elif cmd == "HIT":
            host, port, period, duration = parts[1], int(parts[2]), float(parts[3]), float(parts[4])
            self.wfile.write(b"OK\n")
            self.wfile.flush()
            threading.Thread(target=hit, args=(host, port, period, duration), daemon=True).start()
            time.sleep(duration + 1)


def hit(host, port, period, duration):
    end = time.monotonic() + duration
    while time.monotonic() < end:
        try:
            with socket.create_connection((host, port), timeout=5) as s:
                s.sendall(b"GET / HTTP/1.0\r\nHost: box\r\n\r\n")
                while s.recv(65536):
                    pass
        except OSError:
            pass
        time.sleep(period)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


Server(("0.0.0.0", 9000), Handler).serve_forever()
