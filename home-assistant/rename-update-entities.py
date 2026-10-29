#!/usr/bin/env python3
"""Rename updates2mqtt entities in Home Assistant to "<container> (<host>)".

updates2mqtt names each update entity "Docker Image for <container> on <host>".
This renames them through HA's entity registry (same as renaming in the UI), so
the Updates page shows e.g. "jellyfin (media)". Entity IDs are not changed.

Usage:
  HA_TOKEN=... ./rename-update-entities.py            # dry run: show what would change
  HA_TOKEN=... ./rename-update-entities.py --apply    # rename

HA_TOKEN: a long-lived access token (HA profile → Security → Long-lived access tokens).
          If unset, you are prompted for it (input hidden).
HA_URL:   default http://homeassistant.local:8123
NAME_FORMAT: default "{app} ({host})", e.g. "{host} - {app}" or "{host} - {app} - Docker"

Run it again after adding containers. Only the Python standard library is used.
"""

import base64
import getpass
import json
import os
import re
import socket
import ssl
import struct
import sys
from urllib.parse import urlparse

PATTERN = re.compile(r"^Docker Image for (?P<app>.+) on (?P<host>.+)$")


class WebSocket:
    """Minimal client: text frames only, enough for HA's websocket API."""

    def __init__(self, url):
        u = urlparse(url)
        secure = u.scheme in ("https", "wss")
        port = u.port or (443 if secure else 80)
        sock = socket.create_connection((u.hostname, port), timeout=30)
        if secure:
            sock = ssl.create_default_context().wrap_socket(sock, server_hostname=u.hostname)
        self.sock = sock
        key = base64.b64encode(os.urandom(16)).decode()
        req = (
            f"GET /api/websocket HTTP/1.1\r\nHost: {u.hostname}:{port}\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        )
        sock.sendall(req.encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = sock.recv(1024)
            if not chunk:
                raise ConnectionError("connection closed during handshake")
            head += chunk
        status = head.split(b"\r\n", 1)[0]
        if b" 101 " not in status:
            raise ConnectionError(f"websocket handshake failed: {status.decode(errors='replace')}")
        self.buf = head.split(b"\r\n\r\n", 1)[1]

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("connection closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send(self, obj):
        data = json.dumps(obj).encode()
        n = len(data)
        if n < 126:
            header = struct.pack("!BB", 0x81, 0x80 | n)
        elif n < 65536:
            header = struct.pack("!BBH", 0x81, 0x80 | 126, n)
        else:
            header = struct.pack("!BBQ", 0x81, 0x80 | 127, n)
        mask = os.urandom(4)
        self.sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def recv(self):
        message = b""
        while True:
            b1, b2 = self._read(2)
            opcode, n = b1 & 0x0F, b2 & 0x7F
            if n == 126:
                n = struct.unpack("!H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", self._read(8))[0]
            payload = self._read(n)
            if opcode == 0x8:
                raise ConnectionError("server closed the connection")
            if opcode == 0x9:  # ping -> pong
                self.sock.sendall(struct.pack("!BB", 0x8A, 0x80 | len(payload)) + b"\0\0\0\0" + payload)
                continue
            if opcode in (0x1, 0x0):
                message += payload
                if b1 & 0x80:  # final fragment
                    return json.loads(message)


def main():
    apply = "--apply" in sys.argv[1:]
    url = os.environ.get("HA_URL", "http://homeassistant.local:8123")
    name_format = os.environ.get("NAME_FORMAT", "{app} ({host})")
    token = os.environ.get("HA_TOKEN") or getpass.getpass("HA long-lived token: ")

    ws = WebSocket(url)
    if ws.recv().get("type") != "auth_required":
        sys.exit("unexpected greeting from Home Assistant")
    ws.send({"type": "auth", "access_token": token})
    if ws.recv().get("type") != "auth_ok":
        sys.exit("authentication failed: check HA_TOKEN")

    msg_id = 0

    def call(**payload):
        nonlocal msg_id
        msg_id += 1
        ws.send({"id": msg_id, **payload})
        while True:
            reply = ws.recv()
            if reply.get("id") == msg_id:
                if not reply.get("success"):
                    raise RuntimeError(reply.get("error"))
                return reply.get("result")

    entries = call(type="config/entity_registry/list")
    changes = []
    for e in entries:
        if not e["entity_id"].startswith("update.") or e.get("platform") != "mqtt":
            continue
        m = PATTERN.match(e.get("original_name") or "")
        if not m:
            continue
        new = name_format.format(host=m["host"], app=m["app"])
        if e.get("name") != new:
            changes.append((e["entity_id"], e.get("name") or e.get("original_name"), new))

    if not changes:
        print("nothing to rename")
        return
    for entity_id, old, new in sorted(changes, key=lambda c: c[2]):
        print(f"{entity_id}: {old!r} -> {new!r}")
        if apply:
            call(type="config/entity_registry/update", entity_id=entity_id, name=new)
    print(f"{len(changes)} renamed" if apply else f"{len(changes)} to rename (dry run; add --apply)")


if __name__ == "__main__":
    main()
