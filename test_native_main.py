#!/usr/bin/env python3

import concurrent.futures
import io
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest

try:
    import resource
except ImportError:
    resource = None


BINARY = ""
TIMEOUT = 5


class ProtocolError(Exception):
    pass


def encode_message(message):
    payload = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode()
    return len(payload).to_bytes(4, sys.byteorder) + payload


def read_exact(stream, size):
    data = b""
    while len(data) < size:
        chunk = stream.read(size - len(data))
        if not chunk:
            raise ProtocolError(
                f"native host closed stdout after {len(data)} of {size} bytes"
            )
        data += chunk
    return data


def read_response(stream):
    size = int.from_bytes(read_exact(stream, 4), sys.byteorder)
    return json.loads(read_exact(stream, size).decode())


def parse_output(output):
    stream = io.BytesIO(output)
    response = read_response(stream)
    trailing = stream.read()
    if trailing:
        raise ProtocolError(f"response has {len(trailing)} trailing bytes")
    return response


def process_diagnostics(process):
    details = []
    if os.name == "posix" and shutil.which("ps"):
        result = subprocess.run(
            ["ps", "-o", "pid=,ppid=,state=,time=,command=", "-p", str(process.pid)],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        details.append(result.stdout)
    if sys.platform == "darwin" and shutil.which("sample"):
        result = subprocess.run(
            ["sample", str(process.pid), "2", "-file", "-"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        details.extend([result.stdout, result.stderr])
    return "".join(details).strip()


def one_shot(message, env=None):
    process = subprocess.Popen(
        [BINARY],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    try:
        stdout, stderr = process.communicate(encode_message(message), timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        details = process_diagnostics(process)
        process.kill()
        process.communicate()
        raise ProtocolError(f"native host {process.pid} did not exit\n{details}")
    if process.returncode != 0:
        raise ProtocolError(
            f"native host exited with {process.returncode}: {stderr.decode(errors='replace')}"
        )
    return parse_output(stdout)


class NativeHost:
    def __init__(self, env=None):
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
        self.stderr = self.process.stderr

    def request(self, message):
        self.stdin.write(encode_message(message))
        self.stdin.flush()
        result = queue.Queue()

        def read():
            try:
                result.put(read_response(self.stdout))
            except Exception as error:
                result.put(error)

        thread = threading.Thread(target=read, daemon=True)
        thread.start()
        try:
            response = result.get(timeout=TIMEOUT)
        except queue.Empty:
            details = process_diagnostics(self.process)
            self.kill()
            raise ProtocolError(
                f"native host {self.process.pid} did not respond to {message!r}\n{details}"
            )
        if isinstance(response, Exception):
            raise response
        return response

    def close(self):
        if self.process.poll() is not None:
            raise ProtocolError(
                f"native host exited before stdin closed with {self.process.returncode}"
            )
        self.stdin.close()
        try:
            returncode = self.process.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            details = process_diagnostics(self.process)
            self.kill()
            raise ProtocolError(
                f"native host {self.process.pid} did not exit after EOF\n{details}"
            )
        if returncode != 0:
            stderr = self.stderr.read().decode(errors="replace")
            raise ProtocolError(f"native host exited with {returncode}: {stderr}")

    def kill(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=TIMEOUT)


def child_cpu_time():
    if resource is None:
        raise RuntimeError("CPU accounting is unavailable")
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    return usage.ru_utime + usage.ru_stime


class NativeMessengerTests(unittest.TestCase):
    def test_version_and_eof(self):
        response = one_shot({"cmd": "version"})
        self.assertEqual(response["cmd"], "version")
        self.assertEqual(response["code"], 0)
        self.assertTrue(response["version"])

    def test_config_file(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            config = home / ".tridactylrc"
            content = "bind --mode=normal j scrollline 1\n# snowman: \u2603\n"
            config.write_text(content, encoding="utf-8")
            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(home),
                    "USERPROFILE": str(home),
                    "XDG_CONFIG_HOME": str(home / ".config"),
                    "APPDATA": str(home / ".config"),
                    "LOCALAPPDATA": str(home / ".config"),
                }
            )
            path_response = one_shot({"cmd": "getconfigpath"}, env)
            self.assertEqual(path_response["code"], 0)
            self.assertEqual(Path(path_response["content"]).resolve(), config.resolve())

            config_response = one_shot({"cmd": "getconfig"}, env)
            self.assertEqual(config_response["code"], 0)
            self.assertEqual(config_response["content"], content)

            read_result = one_shot(
                {"cmd": "read", "file": "~/.tridactylrc"}, env
            )
            self.assertEqual(read_result["code"], 0)
            self.assertEqual(read_result["content"], content)

    def test_process_commands(self):
        ppid = one_shot({"cmd": "ppid"})
        self.assertGreater(int(ppid["content"]), 0)
        command = "echo native-run" if os.name == "nt" else "printf native-run"
        response = one_shot({"cmd": "run", "command": command, "content": ""})
        self.assertEqual(response["code"], 0)
        self.assertEqual(response["content"].strip(), "native-run")

    def test_concurrent_one_shot_hosts(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
            responses = list(
                executor.map(lambda _: one_shot({"cmd": "version"}), range(4))
            )
        self.assertTrue(all(response["code"] == 0 for response in responses))

    @unittest.skipIf(resource is None, "CPU accounting is unavailable")
    def test_persistent_host_is_idle(self):
        before_cpu = child_cpu_time()
        host = NativeHost()
        self.addCleanup(host.kill)
        self.assertEqual(host.request({"cmd": "version"})["code"], 0)
        self.assertTrue(host.request({"cmd": "env", "var": "HOME"})["content"])
        time.sleep(2)
        host.close()
        cpu_time = child_cpu_time() - before_cpu
        self.assertLess(cpu_time, 0.5, f"idle native host used {cpu_time:.2f}s of CPU")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} PATH_TO_NATIVE_MAIN")
    BINARY = str(Path(sys.argv[1]).resolve())
    if not Path(BINARY).is_file():
        sys.exit(f"native host does not exist: {BINARY}")
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(NativeMessengerTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(not result.wasSuccessful())
