"""Exercise generated completion scripts against real shell completion engines."""

import json
import os
from pathlib import Path
import pty
import re
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parent.parent
REQUIRE_ALL = "--require-all" in sys.argv
if REQUIRE_ALL:
    sys.argv.remove("--require-all")


class CompletionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="zlap-completion-")
        cls.directory = Path(cls.temp.name)
        cls.work = cls.directory / "work"
        cls.work.mkdir()
        cls.binary = cls.directory / "zlap-fixture"
        subprocess.run(
            [
                "zig", "build-exe", "--dep", "zlap",
                "-Mroot=tests/completion.zig", "-Mzlap=src/root.zig",
                f"-femit-bin={cls.binary}",
            ],
            cwd=ROOT, check=True,
        )
        for name in ["zlap-other", "zlap'fixture", 'zlap"fixture']:
            (cls.directory / name).symlink_to(cls.binary)

        cls.env = dict(os.environ, PATH=f"{cls.directory}:{os.environ['PATH']}", LC_ALL="C.UTF-8")
        cls.scripts = {}
        for shell in ["bash", "zsh", "fish", "powershell", "nu"]:
            paths = []
            for variant in [None, "other", "quoted", "double-quoted"]:
                args = [str(cls.binary), "script", shell]
                if variant:
                    args.append(variant)
                script = subprocess.check_output(args, text=True)
                suffix = ".ps1" if shell == "powershell" else ""
                path = cls.directory / f"{shell}-{variant or 'main'}{suffix}"
                path.write_text(script)
                paths.append(path)
            cls.scripts[shell] = paths

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def shell(self, name):
        executable = shutil.which(name)
        if not executable:
            if REQUIRE_ALL:
                self.fail(f"Required shell is missing: {name}")
            self.skipTest(f"Shell is not installed: {name}")
        return executable

    def run_shell(self, argv):
        result = subprocess.run(
            argv, env=self.env, cwd=self.work, text=True, capture_output=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        return result.stdout

    def complete_in_editor(self, shell, line, cursor=None):
        executable = self.shell(shell)
        paths = self.scripts[shell]
        sources = "; ".join(f"source {shlex.quote(str(path))}" for path in paths)
        if shell == "zsh":
            setup = (
                "autoload -Uz compinit; compinit -D; " + sources + "; "
                "zlap_capture() { printf '\\nZLAP_RESULT:%s\\n' \"$BUFFER\"; "
                "BUFFER=''; zle reset-prompt; }; "
                "zle -N zlap_capture; bindkey '^X' zlap_capture"
            )
            args = [executable, "-f"]
        else:
            setup = (
                sources + "; "
                "bind -x '\"\\C-x\":printf \"\\nZLAP_RESULT:%s\\n\" \"$READLINE_LINE\"; "
                "READLINE_LINE=\"\"'"
            )
            args = [executable, "--noprofile", "--norc", "-i"]

        pid, master = pty.fork()
        if pid == 0:
            os.chdir(self.work)
            os.execve(executable, args, dict(self.env, TERM="dumb"))

        def receive(marker):
            data = b""
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    data += os.read(master, 65536)
                    match = re.search(marker, data)
                    if match:
                        return match
            self.fail(f"{shell} editor timed out: {data!r}")

        try:
            os.write(master, (setup + "; printf '\\nZLAP_READY\\n'\n").encode())
            receive(rb"\r\nZLAP_READY\r\n")
            keys = line.encode()
            if cursor is not None:
                keys += b"\x1b[D" * (len(line) - cursor)
            os.write(master, keys + b"\t\x18")
            match = receive(rb"\r\nZLAP_RESULT:([^\r\n]*)\r\n")
            return match.group(1).decode()
        finally:
            os.kill(pid, signal.SIGTERM)
            os.close(master)
            os.waitpid(pid, 0)

    def test_bash_and_zsh_insert_values_without_corrupting_words(self):
        for shell in ["bash", "zsh"]:
            for line, expected in [
                ("zlap-fixture --format pl", "zlap-fixture --format plain"),
                ("zlap-fixture --format=pl", "zlap-fixture --format=plain"),
                ("zlap-fixture --format two", r"zlap-fixture --format two\ words"),
                ('zlap-fixture --format "two', 'zlap-fixture --format "two words"'),
                ("zlap-fixture --format 'two", "zlap-fixture --format 'two words'"),
                ('zlap-fixture --format="two', 'zlap-fixture --format="two words"'),
                ("zlap-fixture --format='two", "zlap-fixture --format='two words'"),
                ('zlap-fixture --format="two w', 'zlap-fixture --format="two words"'),
                ('zlap-fixture --format="two"', 'zlap-fixture --format="two words"'),
                ('zlap-fixture -f"two', 'zlap-fixture "-ftwo words"'),
                (r"zlap-fixture --format two\ w", 'zlap-fixture --format "two words"'),
                ("zlap-fixture --format 'it", r"zlap-fixture --format it\'s"),
                ("zlap-fixture --format star", r"zlap-fixture --format star\*value"),
                ("zlap-fixture --format it", r"zlap-fixture --format it\'s"),
                ("zlap-fixture --format x:", "zlap-fixture --format x:y"),
                ("zlap-fixture --output ü --format pl", "zlap-fixture --output ü --format plain"),
                ("zlap-fixture -- j", "zlap-fixture -- json"),
                ("zlap-other --format pl", "zlap-other --format plain"),
            ]:
                with self.subTest(shell=shell, line=line):
                    actual = self.complete_in_editor(shell, line)
                    self.assertEqual(shlex.split(actual), shlex.split(expected))

    def test_bash_enum_value_is_not_treated_as_a_directory(self):
        directory = self.work / "plain"
        directory.mkdir()
        try:
            for line in ["zlap-fixture --format pl", 'zlap-fixture --format "pl']:
                with self.subTest(line=line):
                    actual = self.complete_in_editor("bash", line)
                    self.assertEqual(shlex.split(actual), ["zlap-fixture", "--format", "plain"])
        finally:
            directory.rmdir()

    def test_cursor_before_suffix(self):
        line = "zlap-fixture --output ü --format pl --output later"
        cursor = line.index(" --output later")
        for shell in ["bash", "zsh"]:
            with self.subTest(shell=shell):
                actual = self.complete_in_editor(shell, line, cursor)
                expected = line[:cursor] + "ain" + line[cursor:]
                self.assertEqual(shlex.split(actual), shlex.split(expected))

    def test_fish(self):
        executable = self.shell("fish")
        sources = "; ".join(f"source {shlex.quote(str(p))}" for p in self.scripts["fish"])
        for line, expected in [
            ("zlap-fixture --format pl", ["plain"]),
            ("zlap-fixture --format=pl", ["--format=plain"]),
            ("zlap-fixture --format two", ["'two words'"]),
            ("zlap-fixture --format star", ["'star*value'"]),
            ("zlap-fixture --output ü --format pl", ["plain"]),
            ("zlap-fixture --output ", []),
            ("zlap-fixture -- j", ["json"]),
            ("zlap-other --format pl", ["plain"]),
            ("\"zlap'fixture\" --format pl", ["plain"]),
            ("'zlap\"fixture' --format pl", ["plain"]),
        ]:
            with self.subTest(line=line):
                command = sources + "; complete -C " + shlex.quote(line)
                output = self.run_shell([executable, "--no-config", "-c", command])
                self.assertEqual(output.splitlines(), expected)

    def test_powershell(self):
        executable = self.shell("pwsh")
        sources = "; ".join(". '" + str(p).replace("'", "''") + "'" for p in self.scripts["powershell"])
        for line, expected in [
            ("zlap-fixture --format pl", ["plain"]),
            ("zlap-fixture --format=pl", ["--format=plain"]),
            ("zlap-fixture --format two", ["'two words'"]),
            ("zlap-fixture --format it", ["'it''s'"]),
            ("zlap-fixture --output ü --format pl", ["plain"]),
            ("Write-Output ü; zlap-fixture --format pl", ["plain"]),
            ("zlap-fixture --output ", []),
            ("zlap-fixture -- j", ["json"]),
            ("zlap-other --format pl", ["plain"]),
            ("& \"zlap'fixture\" --format pl", ["plain"]),
            ("& 'zlap\"fixture' --format pl", ["plain"]),
            ("& zlap-fixture run --format pl", ["plain"]),
        ]:
            with self.subTest(line=line):
                literal = "'" + line.replace("'", "''") + "'"
                command = sources + f"; $line = {literal}; "
                command += (
                    "ConvertTo-Json -Compress -InputObject @((TabExpansion2 $line $line.Length)"
                    ".CompletionMatches | ForEach-Object { $_.CompletionText })"
                )
                output = self.run_shell([executable, "-NoLogo", "-NoProfile", "-Command", command])
                self.assertEqual(json.loads(output), expected)

    def test_nushell(self):
        executable = self.shell("nu")
        sources = "\n".join(f"source {json.dumps(str(p))}" for p in self.scripts["nu"])
        for line, expected in [
            ("zlap-fixture --format pl", ["plain"]),
            ("zlap-fixture --format=pl", ["--format=plain"]),
            ("zlap-fixture --format two", ["two words"]),
            ("zlap-fixture --output ü --format pl", ["plain"]),
            ("echo ü | zlap-fixture --format pl", ["plain"]),
            ("zlap-fixture --output ", []),
            ("zlap-fixture -- j", ["json"]),
            ("zlap-other --format pl", ["plain"]),
            ("zlap-fixture run --format pl", ["plain"]),
        ]:
            with self.subTest(line=line):
                literal = json.dumps(line, ensure_ascii=False)
                command = sources + f"\n{literal} | commandline complete | to json --raw"
                output = self.run_shell([executable, "--no-config-file", "-c", command])
                self.assertEqual(json.loads(output), expected)


if __name__ == "__main__":
    unittest.main(verbosity=2)
