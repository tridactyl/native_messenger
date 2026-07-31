#!/usr/bin/env python3
import hashlib
import json
import os
import queue
import socket
import struct
import subprocess
import threading
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / ("native_main.exe" if os.name == "nt" else "native_main")
MAX_CLI_FRAME = 1024 * 1024
MAX_NATIVE_FRAME = 64 * 1024 * 1024


def frame(payload):
    if not isinstance(payload, bytes):
        payload = json.dumps(payload, separators=(",", ":")).encode()
    return struct.pack("<I", len(payload)) + payload


def native_frame(payload):
    if not isinstance(payload, bytes):
        payload = json.dumps(payload, separators=(",", ":")).encode()
    return struct.pack("=I", len(payload)) + payload


def read_exact(stream, size):
    data = bytearray()
    while len(data) < size:
        chunk = stream.read(size - len(data))
        if not chunk:
            raise EOFError(f"wanted {size} bytes, got {len(data)}")
        data.extend(chunk)
    return bytes(data)


def read_message(stream):
    size = struct.unpack("=I", read_exact(stream, 4))[0]
    return json.loads(read_exact(stream, size))


def recv_exact(sock, size):
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise EOFError(f"wanted {size} bytes, got {len(data)}")
        data.extend(chunk)
    return bytes(data)


def recv_message(sock):
    size = struct.unpack("<I", recv_exact(sock, 4))[0]
    return json.loads(recv_exact(sock, size))


def authenticate(sock, record):
    challenge = os.urandom(16).hex()
    sock.sendall(frame({"protocol": 1, "challenge": challenge}))
    response = recv_message(sock)
    expected = hashlib.sha1((record["token"] + challenge).encode()).hexdigest()
    if (
        response.get("protocol") != 1
        or response.get("instance") != record["instance"]
        or response.get("proof", "").lower() != expected
    ):
        raise AssertionError("control host failed authentication")


class Host:
    def __init__(self, env):
        self.process = subprocess.Popen(
            [BINARY],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        assert self.process.stderr is not None
        self.stdin = self.process.stdin
        self.stdout = self.process.stdout
        self.stderr_stream = self.process.stderr
        self.messages = queue.Queue()
        self.reader = threading.Thread(target=self._read_messages, daemon=True)
        self.reader.start()

    def _read_messages(self):
        try:
            while True:
                self.messages.put(read_message(self.stdout))
        except EOFError:
            pass
        except Exception as error:
            self.messages.put(error)

    def send(self, message):
        self.stdin.write(native_frame(message))
        self.stdin.flush()

    def receive(self):
        message = self.messages.get(timeout=5)
        if isinstance(message, Exception):
            raise message
        return message

    def request(self, message):
        self.send(message)
        return self.receive()

    def close_stdin(self):
        self.stdin.close()

    def wait(self):
        return self.process.wait(timeout=5)

    def stderr(self):
        return self.stderr_stream.read().decode(errors="replace")

    def cleanup(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        self.reader.join(timeout=1)
        for stream in (self.stdin, self.stdout, self.stderr_stream):
            stream.close()


class NativeControlTest(unittest.TestCase):
    def setUp(self):
        if not BINARY.exists():
            self.fail("native_main is missing; run `nimble build` before this test")
        self.cache = tempfile.TemporaryDirectory()
        self.addCleanup(self.cache.cleanup)
        self.env = os.environ.copy()
        self.env["XDG_CACHE_HOME"] = self.cache.name
        self.env["LOCALAPPDATA"] = self.cache.name
        self.env["HOME"] = self.cache.name
        self.env["USERPROFILE"] = self.cache.name

    def records(self):
        return list(Path(self.cache.name).glob("**/native-control/*.json"))

    def start_cli(self, command, instance=None):
        args = [BINARY, "--request", command]
        if instance:
            args.extend(["--instance", instance])
        return subprocess.Popen(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=self.env,
        )

    def run_cli(self, command, instance=None):
        return self.start_cli(command, instance).communicate(timeout=5)

    def assert_no_native_output(self, host):
        with self.assertRaises(queue.Empty):
            host.messages.get(timeout=0.2)

    def test_legacy_control_cli_and_shutdown(self):
        host = Host(self.env)
        self.addCleanup(host.cleanup)

        version = host.request({"cmd": "version"})
        self.assertEqual(version["cmd"], "version")
        self.assertEqual(version["version"], "0.6.0")
        self.assertEqual(version["code"], 0)
        self.assertIn("control-port-v1", version["capabilities"])
        self.assertEqual(self.records(), [])

        stdout, stderr = self.run_cli("tabopen example.com")
        self.assertEqual(stdout, "")
        self.assertIn("no opted-in native host", stderr.lower())

        host.send(b"{not-json")
        malformed = host.receive()
        self.assertEqual(malformed["cmd"], "error")
        self.assertIn("malformed", malformed["error"].lower())
        malformed = host.request({"cmd": "run"})
        self.assertEqual(malformed["cmd"], "error")
        self.assertEqual(host.request({"cmd": "version"})["version"], "0.6.0")
        invalid_protocol = host.request(
            {"type": "control.handshake", "protocol": 2**40, "enable": True}
        )
        self.assertFalse(invalid_protocol["enabled"])
        self.assertEqual(host.request({"cmd": "version"})["version"], "0.6.0")

        disabled = host.request(
            {"type": "control.handshake", "protocol": 1, "enable": False}
        )
        self.assertEqual(
            disabled,
            {"type": "control.handshake", "protocol": 1, "enabled": False},
        )
        self.assertEqual(self.records(), [])

        enabled = host.request(
            {"type": "control.handshake", "protocol": 1, "enable": True}
        )
        self.assertTrue(enabled["enabled"])
        instance = enabled["instance"]
        record_path = self.records()[0]
        discovery_dir = record_path.parent
        record = json.loads(record_path.read_text())
        self.assertEqual(record["instance"], instance)
        self.assertEqual(record["protocol"], 1)
        if os.name == "posix":
            self.assertEqual(record_path.stat().st_mode & 0o077, 0)
            self.assertEqual(discovery_dir.stat().st_mode & 0o077, 0)

        saturated = [
            socket.create_connection(("127.0.0.1", record["port"]), timeout=1)
            for _ in range(40)
        ]
        try:
            stdout, stderr = self.run_cli("tabopen saturated.example")
            self.assertEqual(stdout, "")
            self.assertIn("no opted-in native host", stderr.lower())
            self.assertTrue(record_path.exists())
        finally:
            for client in saturated:
                client.close()

        with socket.create_connection(("127.0.0.1", record["port"]), timeout=1) as sock:
            authenticate(sock, record)
            sock.sendall(
                frame(
                    {
                        "protocol": 1,
                        "token": "wrong",
                        "operation": "ex",
                        "command": "quitall",
                    }
                )
            )
            self.assertFalse(recv_message(sock)["ok"])
        self.assert_no_native_output(host)

        with socket.create_connection(("127.0.0.1", record["port"]), timeout=1) as sock:
            authenticate(sock, record)
            sock.sendall(struct.pack("<I", MAX_CLI_FRAME + 1))
            self.assertFalse(recv_message(sock)["ok"])
        self.assert_no_native_output(host)

        reset = socket.create_connection(("127.0.0.1", record["port"]), timeout=1)
        authenticate(reset, record)
        reset.sendall(
            frame(
                {
                    "protocol": 1,
                    "token": "wrong",
                    "operation": "ex",
                    "command": "quitall",
                }
            )
        )
        reset.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        reset.close()
        self.assertEqual(host.request({"cmd": "version"})["version"], "0.6.0")

        stale_path = discovery_dir / ("0" * 32 + ".json")
        stale_path.write_text(
            json.dumps(
                {
                    "protocol": 1,
                    "instance": "0" * 32,
                    "port": 1,
                    "token": "0" * 64,
                    "pid": 999999999,
                }
            )
        )
        os.chmod(stale_path, 0o600)
        invalid_pid_path = discovery_dir / ("1" * 32 + ".json")
        invalid_pid_path.write_text(
            json.dumps(
                {
                    "protocol": 1,
                    "instance": "1" * 32,
                    "port": 1,
                    "token": "1" * 64,
                    "pid": 2**31,
                }
            )
        )
        os.chmod(invalid_pid_path, 0o600)

        second = Host(self.env)
        self.addCleanup(second.cleanup)
        second_enabled = second.request(
            {"type": "control.handshake", "protocol": 1, "enable": True}
        )
        second_instance = second_enabled["instance"]
        stdout, stderr = self.run_cli("tabopen wrong.example")
        self.assertEqual(stdout, "")
        self.assertIn("multiple opted-in native hosts", stderr.lower())
        self.assertIn(instance, stderr)
        self.assertIn(second_instance, stderr)
        self.assertFalse(stale_path.exists())
        self.assertFalse(invalid_pid_path.exists())
        self.assert_no_native_output(host)
        self.assert_no_native_output(second)

        cli = self.start_cli("tabopen example.com", instance[:8])
        request = host.receive()
        self.assertEqual(request["type"], "control.request")
        self.assertEqual(request["protocol"], 1)
        self.assertEqual(request["operation"], "ex")
        self.assertEqual(request["command"], "tabopen example.com")
        self.assert_no_native_output(second)
        host.send(
            {
                "type": "control.response",
                "protocol": 1,
                "id": "not-" + request["id"],
                "ok": True,
                "result": "wrong",
            }
        )
        time.sleep(0.1)
        self.assertIsNone(cli.poll())
        host.send(
            {
                "type": "control.response",
                "protocol": 1,
                "id": request["id"],
                "ok": True,
                "result": "opened",
            }
        )
        stdout, stderr = cli.communicate(timeout=5)
        self.assertEqual(cli.returncode, 0)
        self.assertEqual(stdout, "opened\n")
        self.assertEqual(stderr, "")

        second.close_stdin()
        self.assertEqual(second.wait(), 0, second.stderr())
        self.assertFalse(any(second_instance in path.name for path in self.records()))

        cli = self.start_cli("broken command")
        request = host.receive()
        host.send(
            {
                "type": "control.response",
                "protocol": 1,
                "id": request["id"],
                "ok": False,
                "error": "command rejected",
            }
        )
        stdout, stderr = cli.communicate(timeout=5)
        self.assertNotEqual(cli.returncode, 0)
        self.assertEqual(stdout, "")
        self.assertIn("command rejected", stderr)

        cli_one = self.start_cli("first concurrent command")
        cli_two = self.start_cli("second concurrent command")
        concurrent = [host.receive(), host.receive()]
        by_command = {request["command"]: request for request in concurrent}
        for command, result in (
            ("second concurrent command", "second"),
            ("first concurrent command", "first"),
        ):
            host.send(
                {
                    "type": "control.response",
                    "protocol": 1,
                    "id": by_command[command]["id"],
                    "ok": True,
                    "result": result,
                }
            )
        self.assertEqual(cli_one.communicate(timeout=5), ("first\n", ""))
        self.assertEqual(cli_two.communicate(timeout=5), ("second\n", ""))

        pending_one = self.start_cli("first pending command")
        pending_two = self.start_cli("second pending command")
        self.assertEqual(host.receive()["operation"], "ex")
        self.assertEqual(host.receive()["operation"], "ex")
        slow_client = socket.create_connection(("127.0.0.1", record["port"]), timeout=1)
        slow_client.sendall(b"\x01")
        host.close_stdin()
        for cli in (pending_one, pending_two):
            stdout, stderr = cli.communicate(timeout=5)
            self.assertNotEqual(cli.returncode, 0)
            self.assertEqual(stdout, "")
            self.assertIn("extension disconnected", stderr.lower())
        self.assertEqual(host.wait(), 0, host.stderr())
        slow_client.close()
        self.assertEqual(self.records(), [])

    def test_legacy_one_shot(self):
        version = subprocess.run(
            [BINARY, "--version"],
            check=True,
            capture_output=True,
            text=True,
            env=self.env,
        )
        self.assertEqual(version.stdout, "0.6.0\n")
        help_output = subprocess.run(
            [BINARY, "--help"],
            check=True,
            capture_output=True,
            text=True,
            env=self.env,
        )
        self.assertIn("--request COMMAND", help_output.stdout)
        with subprocess.Popen(
            [BINARY, "firefox-manifest", "extension-id"], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env,
        ) as process:
            stdout, stderr = process.communicate(
                native_frame({"cmd": "version"}), timeout=5
            )
            self.assertEqual(process.returncode, 0, stderr.decode(errors="replace"))
        size = struct.unpack("=I", stdout[:4])[0]
        response = json.loads(stdout[4 : 4 + size])
        self.assertEqual(response["version"], "0.6.0")
        self.assertEqual(len(stdout), size + 4)
        self.assertEqual(self.records(), [])

    def test_oversized_native_frame_is_rejected(self):
        host = Host(self.env)
        self.addCleanup(host.cleanup)

        host.stdin.write(struct.pack("=I", MAX_NATIVE_FRAME + 1))
        host.stdin.flush()

        self.assertEqual(host.wait(), 0)
        self.assertIn("exceeds maximum frame length", host.stderr())


if __name__ == "__main__":
    unittest.main()
