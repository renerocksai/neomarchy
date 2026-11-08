#!/usr/bin/env python3
"""Exercise the real QML service and mpv without desktop or account state."""

import json
import os
from pathlib import Path
import shutil
import shlex
import signal
import socket
import subprocess
import tempfile
import time
import unittest
import wave


ROOT = Path(__file__).resolve().parents[1]
HARNESS = ROOT / "tests" / "PlayerHarness.qml"


def alive(pid):
    try:
        # A dead child may await reaping briefly by its new parent.
        state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
        return state != "Z"
    except FileNotFoundError:
        return False


class PlayerLifecycle(unittest.TestCase):
    def setUp(self):
        for command in ("quickshell", "mpv", "setpriv"):
            self.assertIsNotNone(shutil.which(command), f"Install {command} to run these tests")
        self.temp = tempfile.TemporaryDirectory(prefix="neomarchy-test-")
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.env = os.environ.copy()
        for variable, directory in (
            ("XDG_CONFIG_HOME", "config"), ("XDG_STATE_HOME", "state"),
            ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache"),
            ("XDG_RUNTIME_DIR", "run"),
        ):
            target = base / directory
            target.mkdir(mode=0o700)
            self.env[variable] = str(target)
        self.env["QT_QPA_PLATFORM"] = "offscreen"
        self.env.pop("WAYLAND_DISPLAY", None)
        self.env["NO_COLOR"] = "1"
        # Quickshell only imports files beneath its configuration root.
        shell_dir = base / "shell"
        plugin_dir = shell_dir / "plugin"
        (plugin_dir / "bin").mkdir(parents=True)
        shutil.copy2(ROOT / "Service.qml", plugin_dir / "Service.qml")
        shutil.copy2(ROOT / "bin" / "neowake", plugin_dir / "bin" / "neowake")
        self.harness = shell_dir / "shell.qml"
        shutil.copy2(HARNESS, self.harness)
        audio = base / "silence.wav"
        with wave.open(str(audio), "wb") as stream:
            stream.setparams((1, 2, 8000, 0, "NONE", "not compressed"))
            stream.writeframes(b"\0\0" * 8000 * 60)
        self.env["NEOMARCHY_TEST_AUDIO"] = str(audio)
        # Run real mpv, but never open an audio device or load user scripts.
        shimdir = base / "bin"
        shimdir.mkdir()
        shim = shimdir / "mpv"
        shim.write_text('#!/bin/sh\nexec /usr/bin/mpv --no-config --load-scripts=no --ao=null "$@"\n')
        shim.chmod(0o700)
        self.env["PATH"] = str(shimdir) + os.pathsep + self.env["PATH"]
        self.players = []
        self.shell_pid = None
        self.log = tempfile.TemporaryFile(mode="w+")
        self.addCleanup(self.log.close)
        self.shell = subprocess.Popen(
            ["quickshell", "--no-color", "-p", str(self.harness)],
            env=self.env, stdout=self.log, stderr=subprocess.STDOUT,
        )
        self.addCleanup(self.shutdown)
        state = self.wait_for(lambda: self.status(), "Quickshell IPC did not start")
        self.shell_pid = state["shellPid"]

    def shutdown(self):
        if self.shell_pid and alive(self.shell_pid):
            os.kill(self.shell_pid, signal.SIGCONT)
            os.kill(self.shell_pid, signal.SIGTERM)
        if self.shell.poll() is None:
            self.shell.terminate()
        try:
            self.shell.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.shell.kill()
            self.shell.wait(timeout=3)
        for pid in self.players:
            if alive(pid):
                os.kill(pid, signal.SIGTERM)

    def call(self, method):
        result = subprocess.run(
            ["quickshell", "-p", str(self.harness), "ipc", "call", "lifecycle", method],
            env=self.env, capture_output=True, text=True, timeout=3,
        )
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip())
        return result.stdout.strip()

    def status(self):
        return json.loads(self.call("status"))

    def wait_for(self, check, message, timeout=6):
        deadline = time.monotonic() + timeout
        detail = ""
        while time.monotonic() < deadline:
            try:
                result = check()
                if result:
                    return result
            except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
                detail = str(error)
            time.sleep(0.05)
        self.log.seek(0)
        self.fail(f"{message}: {detail}\n{self.log.read()[-5000:]}")

    def property(self, name):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(2)
            connection.connect(self.player_socket)
            connection.sendall((json.dumps({"command": ["get_property", name], "request_id": 1}) + "\n").encode())
            with connection.makefile("rb") as response:
                while True:
                    message = json.loads(response.readline())
                    if message.get("request_id") == 1:
                        self.assertEqual(message.get("error"), "success")
                        return message.get("data")

    def start_player(self):
        self.call("start")
        state = self.wait_for(
            lambda: (value if (value := self.status())["fileLoaded"] else None),
            "Player did not load the silent audio",
        )
        self.player_socket = state["socket"]
        pid = self.property("pid")
        self.players.append(pid)
        self.assertTrue(alive(pid))
        self.assertEqual(self.property("volume"), 0)
        return pid

    def test_transport_controls(self):
        self.start_player()
        self.call("toggle")
        self.wait_for(lambda: self.property("pause") is True, "Pause did not reach mpv")
        self.wait_for(lambda: not self.status()["playing"], "Panel did not observe pause")
        self.call("toggle")
        self.wait_for(lambda: self.property("pause") is False, "Resume did not reach mpv")
        self.wait_for(lambda: self.status()["playing"], "Panel did not observe resume")
        self.call("stop")
        self.wait_for(lambda: self.property("idle-active"), "Stop did not unload audio")
        self.assertFalse(self.status()["playing"])

    def test_abrupt_shell_exit_stops_player(self):
        pid = self.start_player()
        os.kill(self.shell_pid, signal.SIGKILL)
        self.wait_for(lambda: not alive(pid), "mpv survived its controlling shell", timeout=3)

    def test_shell_exit_before_player_exec_stops_launcher(self):
        base = Path(self.temp.name)
        ready, release = base / "launcher.pid", base / "release"
        launcher = base / "bin" / "setpriv"
        launcher.write_text(
            '#!/bin/sh\n'
            f'printf "%s\\n" "$$" > {shlex.quote(str(ready))}\n'
            f'while [ ! -e {shlex.quote(str(release))} ]; do /usr/bin/sleep 0.01; done\n'
            'exec /usr/bin/setpriv "$@"\n'
        )
        launcher.chmod(0o700)
        self.call("start")
        self.wait_for(ready.exists, "Player launcher did not start")
        pid = int(ready.read_text())
        self.players.append(pid)
        player_socket = self.status()["socket"]
        try:
            os.kill(self.shell_pid, signal.SIGKILL)
            self.wait_for(lambda: not alive(self.shell_pid), "Shell did not exit")
        finally:
            release.touch()
        self.wait_for(lambda: not alive(pid), "Player launched after its owner exited", timeout=3)
        self.assertFalse(Path(player_socket).exists())

    def test_service_reload_stops_previous_player(self):
        old_pid = self.start_player()
        self.call("unload")
        self.wait_for(lambda: not alive(old_pid), "mpv survived service destruction")
        self.call("load")
        self.wait_for(lambda: self.status()["loaded"], "Service did not reload")
        new_pid = self.start_player()
        self.assertNotEqual(old_pid, new_pid)
        self.assertFalse(alive(old_pid))

    def test_stalled_shell_keeps_player_and_recovers_controls(self):
        pid = self.start_player()
        before = self.property("time-pos")
        os.kill(self.shell_pid, signal.SIGSTOP)
        try:
            time.sleep(0.3)
            self.assertTrue(alive(pid))
            self.assertGreater(self.property("time-pos"), before)
        finally:
            os.kill(self.shell_pid, signal.SIGCONT)
        self.call("toggle")
        self.wait_for(lambda: self.property("pause") is True, "Controls did not recover")


if __name__ == "__main__":
    unittest.main(verbosity=2)
