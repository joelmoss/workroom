#!/usr/bin/env python3
"""The fixture's GitHub and credential broker (#252), so a derived workroom can be shown to fetch
and push on its own, with no Mac attached.

Two listeners in one process, both on the container's own loopback:

- The broker, on http://127.0.0.1:8081: an enrolment is accepted, and each token request mints a
  token. A fixed port, because every container derived from a base keeps the broker URL its agent
  enrolled with.
- GitHub, on https://github.com (entrypoint.sh maps the name to 127.0.0.1, and the image trusts
  this certificate for github.com only): git's smart HTTP through git-http-backend, over the
  repositories under /srv. A request without a token it accepts is answered 401 with a Basic
  challenge, which is what makes git ask its credential helper. It accepts a token this broker
  minted, or the base clone token baked into the image, and nothing else.

Fixture only. It binds 443 as the ssh user with CAP_NET_BIND_SERVICE (entrypoint.sh).
"""

import base64
import datetime
import http.server
import json
import secrets
import ssl
import subprocess
import threading

CONFIG = "/etc/workroom-fixture"
with open(f"{CONFIG}/clone-token", encoding="utf-8") as handle:
    CLONE_TOKEN = handle.read().strip()
MINTED = set()
LOCK = threading.Lock()


class Broker(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path == "/broker/enrolments":
            self.reply(201, {"grant_id": "g1"})
        elif self.path == "/broker/tokens":
            token = "ghs_minted_" + secrets.token_hex(16)
            with LOCK:
                MINTED.add(token)
            expires = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=1)
            self.reply(200, {"token": token, "expires_at": expires.strftime("%Y-%m-%dT%H:%M:%SZ")})
        else:
            self.reply(404, {"error": "not_found"})

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


class GitHub(http.server.BaseHTTPRequestHandler):
    def authorized(self):
        scheme, _, credentials = self.headers.get("Authorization", "").partition(" ")
        if scheme.lower() != "basic":
            return False
        try:
            user, _, token = base64.b64decode(credentials).decode().partition(":")
        except ValueError:
            return False
        with LOCK:
            return user == "x-access-token" and (token in MINTED or token == CLONE_TOKEN)

    def body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            data = b""
            while True:
                size = int(self.rfile.readline().split(b";")[0], 16)
                if size == 0:
                    self.rfile.readline()
                    return data
                data += self.rfile.read(size)
                self.rfile.readline()
        return self.rfile.read(int(self.headers.get("Content-Length") or 0))

    def serve(self):
        if not self.authorized():
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="GitHub"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        path, _, query = self.path.partition("?")
        body = self.body()
        env = {
            "GIT_PROJECT_ROOT": "/srv",
            "GIT_HTTP_EXPORT_ALL": "1",
            # git-http-backend serves receive-pack only to an authenticated user.
            "REMOTE_USER": "x-access-token",
            "REQUEST_METHOD": self.command,
            "PATH_INFO": path,
            "QUERY_STRING": query,
            "CONTENT_TYPE": self.headers.get("Content-Type", ""),
            "CONTENT_LENGTH": str(len(body)),
            "PATH": "/usr/bin:/bin",
        }
        for name, value in self.headers.items():
            env["HTTP_" + name.upper().replace("-", "_")] = value
        output = subprocess.run(
            ["/usr/lib/git-core/git-http-backend"], input=body, env=env, capture_output=True
        ).stdout
        separator = b"\r\n\r\n" if b"\r\n\r\n" in output else b"\n\n"
        head, _, content = output.partition(separator)
        status, headers = 200, []
        for line in head.decode().splitlines():
            name, _, value = line.partition(":")
            if name.lower() == "status":
                status = int(value.split()[0])
            elif name:
                headers.append((name, value.strip()))
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    do_GET = serve
    do_POST = serve

    def log_message(self, *args):
        pass


def main():
    broker = http.server.ThreadingHTTPServer(("127.0.0.1", 8081), Broker)
    github = http.server.ThreadingHTTPServer(("127.0.0.1", 443), GitHub)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(f"{CONFIG}/github.pem", f"{CONFIG}/github.key")
    github.socket = context.wrap_socket(github.socket, server_side=True)
    threading.Thread(target=broker.serve_forever, daemon=True).start()
    github.serve_forever()


if __name__ == "__main__":
    main()
