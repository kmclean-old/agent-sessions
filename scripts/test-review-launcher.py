#!/usr/bin/env python3

import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "macapp" / "Agents" / "Resources"
LAUNCHER = RESOURCES / "launch-revdiff.sh"
RUNNER = RESOURCES / "review-run.sh"
SUBMITTER = RESOURCES / "review-submit.sh"


class UnixServer:
    def __init__(self, path, response=None, delay=0):
        self.path = str(path)
        self.response = response
        self.delay = delay
        self.request = None
        self.ready = threading.Event()
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self):
        self.thread.start()
        self.ready.wait(2)
        return self

    def __exit__(self, *_):
        self.thread.join(7)

    def _serve(self):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            server.bind(self.path)
            server.listen(1)
            self.ready.set()
            conn, _ = server.accept()
            with conn:
                data = b""
                while not data.endswith(b"\n"):
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                self.request = json.loads(data)
                if self.delay:
                    time.sleep(self.delay)
                if self.response is not None:
                    conn.sendall((json.dumps(self.response) + "\n").encode())


class ReviewLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self._write_executable(
            self.bin / "nc",
            """#!/usr/bin/env python3
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(float(sys.argv[sys.argv.index('-w') + 1]))
s.connect(sys.argv[-1])
s.sendall(sys.stdin.buffer.read())
while True:
    try: chunk = s.recv(65536)
    except socket.timeout: sys.exit(1)
    if not chunk: break
    sys.stdout.buffer.write(chunk)
""",
        )
        self._write_executable(self.bin / "revdiff", "#!/bin/sh\nexit 0\n")
        self.env = os.environ.copy()
        self.env.update(
            PATH=f"{self.bin}:{self.env['PATH']}",
            AGENTS_SESSION_ID="session one",
            AGENTS_PANE_ID="pane-1",
            LANG="en_CA.UTF-8",
            REVDIFF_TEST="line one\nline two",
            JJ_CONFIG="quotes ' and spaces",
        )

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def _write_executable(path, text):
        path.write_text(text)
        path.chmod(0o755)

    def _run(self, script, *args, env=None, input_text=None):
        return subprocess.run(
            [str(script), *args], cwd=self.base, env=env or self.env,
            input=input_text, text=True, capture_output=True,
        )

    def test_open_returns_on_acceptance_and_preserves_arguments_and_environment(self):
        sock = self.base / "control.sock"
        self.env["AGENTS_CONTROL_SOCK"] = str(sock)
        args = ["--description", "spaces ' quotes\nand newlines", "--untracked"]
        with UnixServer(sock, {"ok": True}) as server:
            started = time.monotonic()
            result = self._run(LAUNCHER, *args)
            elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(elapsed, 2)
        self.assertIn("Do not wait or poll", result.stdout)
        self.assertEqual(server.request["cmd"], "review-open")
        self.assertEqual(server.request["command"], str(self.bin / "revdiff"))
        self.assertEqual(server.request["args"], args)
        self.assertEqual(Path(server.request["cwd"]).resolve(), self.base.resolve())
        self.assertEqual(server.request["session"], "session one")
        self.assertEqual(server.request["pane"], "pane-1")
        self.assertEqual(server.request["env"]["REVDIFF_TEST"], "line one\nline two")
        self.assertEqual(server.request["env"]["JJ_CONFIG"], "quotes ' and spaces")
        self.assertNotIn("AGENTS_SESSION_ID", server.request["env"])

    @unittest.skipUnless(Path("/usr/bin/nc").exists(), "requires macOS nc")
    def test_open_uses_macos_nc_transport(self):
        sock = self.base / "real-nc.sock"
        env = self.env.copy()
        env["AGENTS_CONTROL_SOCK"] = str(sock)
        jq = shutil.which("jq", path=env["PATH"])
        self.assertIsNotNone(jq)
        env["PATH"] = os.pathsep.join(["/usr/bin", str(Path(jq).parent), str(self.bin)])
        with UnixServer(sock, {"ok": True}) as server:
            result = self._run(LAUNCHER, "--untracked", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(server.request["args"], ["--untracked"])

    def test_open_reports_refusal_and_old_app(self):
        for response, phrase in [
            ({"ok": False, "error": "a review is already open"}, "refused the review"),
            ({"ok": False, "error": "unknown cmd: review-open"}, "update or rebuild"),
        ]:
            sock = self.base / f"control-{phrase.split()[0]}.sock"
            self.env["AGENTS_CONTROL_SOCK"] = str(sock)
            with UnixServer(sock, response):
                result = self._run(LAUNCHER)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(phrase, result.stderr)

    def test_open_timeout_is_bounded(self):
        sock = self.base / "timeout.sock"
        self.env["AGENTS_CONTROL_SOCK"] = str(sock)
        with UnixServer(sock, None, delay=6):
            started = time.monotonic()
            result = self._run(LAUNCHER)
            elapsed = time.monotonic() - started
        self.assertNotEqual(result.returncode, 0)
        self.assertGreaterEqual(elapsed, 4.5)
        self.assertLess(elapsed, 6.5)
        self.assertIn("within 5 seconds", result.stderr)

    def test_open_rejects_output_controls(self):
        for arg in ["-o", "-ofile", "--output=x", "--post-flush-command=x"]:
            result = self._run(LAUNCHER, arg)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("managed by Agents.app", result.stderr)

    def test_runner_records_status_and_requests_explicit_flush(self):
        directory = self.base / "review data"
        directory.mkdir()
        capture = self.base / "capture.json"
        fake = self.base / "fake revdiff"
        self._write_executable(
            fake,
            """#!/usr/bin/env python3
import json, os, pathlib, sys
pathlib.Path(os.environ['CAPTURE']).write_text(json.dumps({
    'argv': sys.argv[1:],
    'exit': os.environ.get('REVDIFF_EXIT_CODE_ON_ANNOTATIONS')
}))
print('diagnostic', file=sys.stderr)
sys.exit(10)
""",
        )
        env = self.env | {
            "CAPTURE": str(capture),
            "REVDIFF_OUTPUT": "/tmp/wrong-output",
            "REVDIFF_POST_FLUSH_COMMAND": "wrong-submit-command",
        }
        result = self._run(RUNNER, str(directory), "/tmp/agents-test.sock", str(fake), "--description", "a b'c", env=env)
        self.assertEqual(result.returncode, 10)
        self.assertEqual((directory / "status").read_text(), "10\n")
        self.assertEqual((directory / "stderr").read_text(), "diagnostic\n")
        recorded = json.loads(capture.read_text())
        self.assertEqual(recorded["exit"], "true")
        self.assertEqual(recorded["argv"][:2], ["--description", "a b'c"])
        self.assertEqual(recorded["argv"][-2], f"--output={directory}/annotations.md")
        self.assertEqual(
            recorded["argv"][-1],
            "--post-flush-command='" + str(SUBMITTER).replace("'", "'\\''") + "'",
        )

    def test_launcher_preserves_existing_revdiff_config(self):
        config = self.base / "custom config"
        config.write_text("[Application Options]\n")
        sock = self.base / "config.sock"
        env = self.env | {
            "AGENTS_CONTROL_SOCK": str(sock),
            "REVDIFF_CONFIG": str(config),
        }
        with UnixServer(sock, {"ok": True}) as server:
            result = self._run(LAUNCHER, "--untracked", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(server.request["args"], [f"--config={config}", "--untracked"])

    def test_runner_records_signal_status_when_child_exits_cleanly(self):
        fake = self.base / "signal revdiff"
        marker = self.base / "child-ready"
        self._write_executable(
            fake,
            """#!/usr/bin/env python3
import os, pathlib, signal, sys, time
def stopped(_signum, _frame): sys.exit(0)
for name in ('SIGINT', 'SIGTERM', 'SIGHUP'):
    signal.signal(getattr(signal, name), stopped)
pathlib.Path(os.environ['MARKER']).write_text('ready')
while True: time.sleep(0.05)
""",
        )
        for sent, expected in [(signal.SIGINT, 130), (signal.SIGTERM, 143), (signal.SIGHUP, 129)]:
            with self.subTest(signal=sent):
                directory = self.base / f"signal-{sent}"
                directory.mkdir()
                marker.unlink(missing_ok=True)
                process = subprocess.Popen(
                    [str(RUNNER), str(directory), "/tmp/agents-test.sock", str(fake)],
                    cwd=self.base, env=self.env | {"MARKER": str(marker)},
                    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    start_new_session=True,
                )
                for _ in range(100):
                    if marker.exists():
                        break
                    time.sleep(0.02)
                self.assertTrue(marker.exists())
                os.killpg(process.pid, sent)
                process.communicate(timeout=3)
                self.assertEqual(process.returncode, expected)
                self.assertEqual((directory / "status").read_text(), f"{expected}\n")

    def test_submit_sends_registered_review_identity(self):
        sock = self.base / "submit.sock"
        env = self.env | {
            "AGENTS_CONTROL_SOCK": str(sock),
            "AGENTS_REVIEW_ID": "review ' 7",
        }
        with UnixServer(sock, {"ok": True}) as server:
            result = self._run(SUBMITTER, env=env, input_text="annotations are ignored\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(server.request, {
            "cmd": "review-submit", "session": "session one", "review": "review ' 7"
        })


if __name__ == "__main__":
    unittest.main()
