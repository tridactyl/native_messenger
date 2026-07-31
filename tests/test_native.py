#!/usr/bin/env python3
import json
import os
import queue
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / ("native_main.exe" if os.name == "nt" else "native_main")
MAX_NATIVE_FRAME = 64 * 1024 * 1024


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


def read_native(stream):
    size = struct.unpack("=I", read_exact(stream, 4))[0]
    return json.loads(read_exact(stream, size))


def send_line(sock, payload):
    sock.sendall(json.dumps(payload, separators=(",", ":")).encode() + b"\n")


def recv_line(sock):
    data = bytearray()
    while b"\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise EOFError("connection closed")
        data.extend(chunk)
    line, _, remainder = data.partition(b"\n")
    if remainder:
        raise AssertionError("unexpected data after control response")
    return json.loads(line)


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
                self.messages.put(read_native(self.stdout))
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
            self.fail("native_main is missing; run `nimble build` before testing")
        self.cache = tempfile.TemporaryDirectory()
        self.addCleanup(self.cache.cleanup)
        self.env = os.environ.copy()
        for name in ("XDG_CACHE_HOME", "LOCALAPPDATA", "HOME", "USERPROFILE"):
            self.env[name] = self.cache.name

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
        process = self.start_cli(command, instance)
        stdout, stderr = process.communicate(timeout=5)
        return process, stdout, stderr

    def assert_no_native_output(self, host):
        with self.assertRaises(queue.Empty):
            host.messages.get(timeout=0.1)

    def enable(self, host):
        response = host.request(
            {"type": "control.handshake", "protocol": 1, "enable": True}
        )
        self.assertTrue(response["enabled"])
        return response["instance"]

    def respond(self, host, request, ok=True, **extra):
        host.send(
            {
                "type": "control.response",
                "protocol": 1,
                "id": request["id"],
                "ok": ok,
                **extra,
            }
        )

    def test_control_cli_and_shutdown(self):
        host = Host(self.env)
        self.addCleanup(host.cleanup)

        version = host.request({"cmd": "version"})
        self.assertEqual(version["version"], "0.6.0")
        self.assertIn("control-port-v1", version["capabilities"])
        self.assertEqual(self.records(), [])
        process, _, stderr = self.run_cli("tabopen x")
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("no opted-in native host", stderr)

        host.send(b"{not-json")
        self.assertEqual(host.receive()["cmd"], "error")
        self.assertEqual(host.request({"cmd": "version"})["version"], "0.6.0")

        instance = self.enable(host)
        record_path = self.records()[0]
        record = json.loads(record_path.read_text())
        self.assertEqual(record["instance"], instance)
        if os.name == "posix":
            self.assertEqual(record_path.stat().st_mode & 0o077, 0)
            self.assertEqual(record_path.parent.stat().st_mode & 0o077, 0)

        with socket.create_connection(("127.0.0.1", record["port"])) as client:
            send_line(
                client,
                {
                    "protocol": 1,
                    "token": "wrong",
                    "operation": "ex",
                    "command": "quitall",
                },
            )
            self.assertEqual(recv_line(client)["error"], "authentication failed")
        self.assert_no_native_output(host)

        disabled = host.request(
            {"type": "control.handshake", "protocol": 1, "enable": False}
        )
        self.assertFalse(disabled["enabled"])
        self.assertEqual(self.records(), [])
        instance = self.enable(host)
        record_path = self.records()[0]

        stale_path = record_path.parent / ("0" * 32 + ".json")
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

        second = Host(self.env)
        self.addCleanup(second.cleanup)
        second_instance = self.enable(second)
        process, stdout, stderr = self.run_cli("tabopen wrong.example")
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(stdout, "")
        self.assertIn("multiple opted-in native hosts", stderr)
        self.assertIn(instance, stderr)
        self.assertIn(second_instance, stderr)
        self.assertFalse(stale_path.exists())

        cli = self.start_cli("tabopen example.com", instance[:8])
        request = host.receive()
        self.assertEqual(request["command"], "tabopen example.com")
        self.respond(host, {**request, "id": "wrong"}, result="wrong")
        time.sleep(0.05)
        self.assertIsNone(cli.poll())
        self.respond(host, request, result="opened")
        self.assertEqual(cli.communicate(timeout=5), ("opened\n", ""))

        second.close_stdin()
        self.assertEqual(second.wait(), 0, second.stderr())

        cli = self.start_cli("broken command")
        request = host.receive()
        self.respond(host, request, ok=False, error="command rejected")
        stdout, stderr = cli.communicate(timeout=5)
        self.assertNotEqual(cli.returncode, 0)
        self.assertEqual(stdout, "")
        self.assertIn("command rejected", stderr)

        time.sleep(0.05)
        commands = [f"concurrent command {index}" for index in range(32)]
        clients = {command: self.start_cli(command) for command in commands}
        requests = {}
        for _ in commands:
            request = host.receive()
            requests[request["command"]] = request
        self.assertEqual(set(requests), set(commands))
        overflow = self.start_cli("overflow command")
        _, stderr = overflow.communicate(timeout=5)
        self.assertNotEqual(overflow.returncode, 0)
        self.assertIn("could not contact", stderr)
        for command in reversed(commands):
            self.respond(host, requests[command], result=command)
        for command, process in clients.items():
            self.assertEqual(process.communicate(timeout=5), (command + "\n", ""))

        pending = self.start_cli("pending command")
        self.assertEqual(host.receive()["command"], "pending command")
        slow = socket.create_connection(
            ("127.0.0.1", json.loads(self.records()[0].read_text())["port"])
        )
        slow.sendall(b"{")
        host.close_stdin()
        stdout, stderr = pending.communicate(timeout=5)
        self.assertEqual(stdout, "")
        self.assertIn("extension disconnected", stderr)
        self.assertEqual(host.wait(), 0, host.stderr())
        slow.close()
        self.assertEqual(self.records(), [])

    def test_legacy_one_shot_and_cli_flags(self):
        version = subprocess.run(
            [BINARY, "--version"], check=True, capture_output=True, text=True,
            env=self.env,
        )
        self.assertEqual(version.stdout, "0.6.0\n")
        empty_instance = subprocess.run(
            [BINARY, "--request", "reload", "--instance", ""],
            capture_output=True,
            env=self.env,
        )
        self.assertEqual(empty_instance.returncode, 2)
        with subprocess.Popen(
            [BINARY, "firefox-manifest", "extension-id"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=self.env,
        ) as process:
            stdout, stderr = process.communicate(
                native_frame({"cmd": "version"}), timeout=5
            )
        self.assertEqual(process.returncode, 0, stderr.decode(errors="replace"))
        size = struct.unpack("=I", stdout[:4])[0]
        self.assertEqual(json.loads(stdout[4 : 4 + size])["version"], "0.6.0")
        self.assertEqual(len(stdout), size + 4)

    def test_oversized_native_frame_is_rejected(self):
        host = Host(self.env)
        self.addCleanup(host.cleanup)
        assert host.stdin is not None
        host.stdin.write(struct.pack("=I", MAX_NATIVE_FRAME + 1))
        host.stdin.flush()
        self.assertEqual(host.wait(), 0)
        self.assertIn("exceeds maximum frame length", host.stderr())


if __name__ == "__main__":
    unittest.main()
