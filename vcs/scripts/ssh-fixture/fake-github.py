#!/usr/bin/env python3
"""The fixture's GitHub (#252), so a workroom can be shown to fetch and push on its own, with no
Mac attached.

GitHub, on https://github.com (entrypoint.sh maps the name to 127.0.0.1, and the image trusts this
certificate for github.com only): git's smart HTTP through git-http-backend, over the repositories
under /srv. A request without the token it accepts is answered 401 with a Basic challenge, which is
what makes git ask its credential helper (git-credential-fixture, standing in for a provider's). It
accepts the clone token baked into the image, and nothing else.

Fixture only. It binds 443 as the ssh user with CAP_NET_BIND_SERVICE (entrypoint.sh).
"""

import base64
import http.server
import ssl
import subprocess

CONFIG = "/etc/workroom-fixture"
with open(f"{CONFIG}/clone-token", encoding="utf-8") as handle:
    CLONE_TOKEN = handle.read().strip()


class GitHub(http.server.BaseHTTPRequestHandler):
    def authorized(self):
        scheme, _, credentials = self.headers.get("Authorization", "").partition(" ")
        if scheme.lower() != "basic":
            return False
        try:
            user, _, token = base64.b64decode(credentials).decode().partition(":")
        except ValueError:
            return False
        return user == "x-access-token" and token == CLONE_TOKEN

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
    github = http.server.ThreadingHTTPServer(("127.0.0.1", 443), GitHub)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(f"{CONFIG}/github.pem", f"{CONFIG}/github.key")
    github.socket = context.wrap_socket(github.socket, server_side=True)
    github.serve_forever()


if __name__ == "__main__":
    main()
