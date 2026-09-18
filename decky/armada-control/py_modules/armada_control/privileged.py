import json
import socket

SOCKET = "/run/armada/control.sock"


def call(action, **payload):
    request = {"action": action, **payload}
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(30)
            sock.connect(SOCKET)
            sock.sendall((json.dumps(request, separators=(",", ":")) + "\n").encode("utf-8"))
            data = b""
            while b"\n" not in data:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                data += chunk
    except (FileNotFoundError, ConnectionRefusedError):
        # armada-control.service isn't up (or its socket path changed). Give
        # the UI something actionable instead of a raw errno message.
        raise RuntimeError("Couldn't reach the Armada system service")
    except socket.timeout:
        raise RuntimeError("The Armada system service didn't respond (timed out)")
    try:
        response = json.loads(data.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise RuntimeError("The Armada system service returned an unexpected response")
    if not response.get("ok"):
        raise RuntimeError(response.get("error") or "privileged call failed")
    return response.get("result", {})
