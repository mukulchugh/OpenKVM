#!/usr/bin/env python3
import json
import socket
import struct
import sys

host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 9847
token = sys.argv[3] if len(sys.argv) > 3 else "test-token-123"

message = {
    "action": "querySetup",
    "deviceAddress": None,
    "hostName": "TestClient",
    "token": token,
    "setupStatus": None,
}
body = json.dumps(message).encode("utf-8")
framed = struct.pack(">I", len(body)) + body

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(5)
sock.connect((host, port))
sock.sendall(framed)
header = sock.recv(4)
length = struct.unpack(">I", header)[0]
payload = sock.recv(length)
reply = json.loads(payload.decode("utf-8"))
print(json.dumps(reply, indent=2))
sock.close()