"""An HTTP proxy that accepts CONNECT and then fails the TLS handshake with a
fatal unrecognized_name alert, as a corporate proxy does for an internal name
it cannot serve. Every CONNECT target is logged.

  python3 tests/sni_reject_proxy.py <log> <port>
"""

import socketserver
import sys

LOG, PORT = sys.argv[1], int(sys.argv[2])
# TLS record: alert, TLS 1.2, length 2, level fatal, unrecognized_name (112)
ALERT = bytes([0x15, 0x03, 0x03, 0x00, 0x02, 0x02, 0x70])


class H(socketserver.StreamRequestHandler):
    def handle(self):
        line = self.rfile.readline().decode("latin-1").strip()
        while self.rfile.readline() not in (b"\r\n", b"\n", b""):
            pass
        with open(LOG, "a") as f:
            f.write(line + "\n")
        if not line.startswith("CONNECT "):
            self.wfile.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
            return
        self.wfile.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
        self.wfile.flush()
        self.request.recv(65536)  # the client hello
        self.wfile.write(ALERT)


socketserver.ThreadingTCPServer.allow_reuse_address = True
socketserver.ThreadingTCPServer(("127.0.0.1", PORT), H).serve_forever()
