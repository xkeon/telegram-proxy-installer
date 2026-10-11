"""Exercise terminal input through pipes and real pseudo-terminals."""

import fcntl
import os
import pty
import re
import select
import shlex
import struct
import subprocess
import tempfile
import termios
import time
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
SELECT_MENU = """
chosen=''
ui_select chosen menu_title main 1 "${UI_MAIN_OPTIONS[@]}"
printf '\\nselected=%s\\n' "$chosen"
"""


class TerminalUITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="proxy ui ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / "config"
        self.config.mkdir()
        (self.root / "units").mkdir()
        (self.config / "ee.env").write_text("EE_PORT=443\nEE_SECRET=private-value\n")
        (self.config / "dd.env").write_text("DD_PORT=8443\n")
        self.setup = f"""
source {shlex.quote(str(REPO / 'install.sh'))}
CONFIG_DIR={shlex.quote(str(self.config))}
SYSTEMD_UNIT_DIR={shlex.quote(str(self.root / 'units'))}
EE_ENV_FILE="$CONFIG_DIR/ee.env"
DD_ENV_FILE="$CONFIG_DIR/dd.env"
systemctl() {{
  printf '%s\\n' "$*" >> {shlex.quote(str(self.root / 'service-calls'))}
  [[ "${{@: -1}}" == "$EE_SERVICE_NAME" ]]
}}
"""

    def environment(self, **extra):
        environment = os.environ.copy()
        environment.pop("NO_COLOR", None)
        environment.update(TERM="xterm-256color", LANG="C.UTF-8", LC_ALL="C.UTF-8")
        environment.update(extra)
        return environment

    def run_pipe(self, body, inputs="", **extra):
        return subprocess.run(
            ["bash", "-c", self.setup + body],
            input=inputs,
            text=True,
            capture_output=True,
            env=self.environment(**extra),
            timeout=10,
        )

    def run_terminal(self, body, keys, rows=24, cols=80, **extra):
        master, slave = pty.openpty()
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        original_attributes = termios.tcgetattr(slave)
        process = subprocess.Popen(
            ["bash", "-c", self.setup + body],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=self.environment(**extra),
        )
        output = bytearray()
        sent = False
        deadline = time.monotonic() + 10
        try:
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.05)[0]:
                    output.extend(os.read(master, 65536))
                # Wait for read to enter character mode, so Ctrl-D reaches it
                # rather than being consumed by the terminal's canonical mode.
                character_input_ready = (
                    b"Esc" in output
                    and not termios.tcgetattr(slave)[3] & termios.ICANON
                )
                if not sent and (character_input_ready or b"Choose a number [1]:" in output):
                    os.write(master, keys.encode())
                    sent = True
                if process.poll() is not None:
                    while select.select([master], [], [], 0)[0]:
                        output.extend(os.read(master, 65536))
                    break
            else:
                self.fail("Terminal interaction timed out: " + output.decode(errors="replace"))
            self.assertTrue(sent, output.decode(errors="replace"))
            self.assertEqual(termios.tcgetattr(slave), original_attributes)
            return process.wait(), output.decode(errors="replace")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_pipe_keeps_numeric_selection_and_emits_no_escape_sequences(self):
        result = self.run_pipe(SELECT_MENU, "10\n", LC_ALL="C")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("selected=10", result.stdout)
        self.assertNotIn("\x1b", result.stdout + result.stderr)
        self.assertIn("EE  * Running  :443", result.stdout)
        self.assertIn("DD  * Not running  :8443", result.stdout)

    def test_invalid_number_can_be_corrected(self):
        result = self.run_pipe(SELECT_MENU, "99\n2\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Invalid choice", result.stdout)
        self.assertIn("selected=2", result.stdout)

    def test_eof_exits_main_menu_cleanly(self):
        result = self.run_pipe("interactive_menu\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_back_from_mode_selection_does_not_run_operation(self):
        result = self.run_pipe("""
cmd_healthcheck() { echo UNEXPECTED_OPERATION; }
interactive_menu
""", "2\n2\n0\n0\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("服务与诊断", result.stdout)
        self.assertNotIn("UNEXPECTED_OPERATION", result.stdout)

    def test_existing_deployment_defaults_to_healthcheck(self):
        result = self.run_pipe("""
command_install() { echo UNEXPECTED_INSTALL; }
cmd_healthcheck() { echo SELECTED_HEALTHCHECK; }
interactive_menu
""", "1\n\n1\n\n0\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SELECTED_HEALTHCHECK", result.stdout)
        self.assertNotIn("UNEXPECTED_INSTALL", result.stdout)

    def test_header_reads_data_without_executing_configuration_or_showing_secret(self):
        marker = self.root / "executed"
        (self.config / "ee.env").write_text(
            f"EE_PORT=$(touch {shlex.quote(str(marker))})\nEE_SECRET=private-value\n"
        )
        result = self.run_pipe("UI_LANG=zh\n" + SELECT_MENU, "0\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())
        self.assertNotIn("private-value", result.stdout)
        self.assertIn(":?", result.stdout)

    def test_actual_menu_supports_all_languages(self):
        for language, title in (("en", "Main Menu"), ("zh", "主菜单"),
                                ("ko", "메인 메뉴"), ("ja", "メインメニュー")):
            with self.subTest(language=language):
                result = self.run_pipe(f"UI_LANG={language}\n" + SELECT_MENU, "0\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(title, result.stdout)
                self.assertIn("selected=0", result.stdout)
                self.assertNotIn("\x1b", result.stdout)

    def test_removed_preview_command_is_rejected_before_any_action(self):
        result = self.run_pipe('main preview --lang zh\n')
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertNotIn("主菜单", result.stdout)
        help_result = self.run_pipe('main --help\n')
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        self.assertNotIn("install.sh preview", help_result.stdout)

    def test_arrow_down_then_enter_selects_healthcheck(self):
        code, output = self.run_terminal(SELECT_MENU, "\x1b[B\n")
        self.assertEqual(code, 0, output)
        self.assertIn("selected=2", output)
        self.assertIn("\x1b[1;37;44m", output)

    def test_arrow_up_wraps_to_exit(self):
        code, output = self.run_terminal(SELECT_MENU, "\x1b[A\n")
        self.assertEqual(code, 0, output)
        self.assertIn("selected=0", output)

    def test_two_digit_shortcut_requires_enter(self):
        code, output = self.run_terminal(SELECT_MENU, "10\n")
        self.assertEqual(code, 0, output)
        self.assertIn("selected=10", output)

    def test_backspace_keeps_highlight_in_sync_with_edited_number(self):
        code, output = self.run_terminal(SELECT_MENU, "10\x7f\n")
        self.assertEqual(code, 0, output)
        self.assertIn("selected=1", output)
        last_frame = ANSI.sub("", output.split("\x1b[H\x1b[2J")[-1])
        self.assertRegex(last_frame, r"›\s+1\s+Install proxy")

    def test_escape_cancels_selection(self):
        code, output = self.run_terminal(SELECT_MENU, "\x1b")
        self.assertEqual(code, 0, output)
        self.assertIn("selected=0", output)

    def test_invalid_keyboard_shortcut_can_be_corrected(self):
        code, output = self.run_terminal(SELECT_MENU, "99\n2\n")
        self.assertEqual(code, 0, output)
        self.assertIn("Invalid choice", output)
        self.assertIn("selected=2", output)

    def test_mode_selector_keeps_ui_out_of_captured_result(self):
        code, output = self.run_terminal("""
mode="$(prompt_mode_all)"
printf '\\nmode=%s\\n' "$mode"
""", "\x1b[A\n")
        self.assertEqual(code, 0, output)
        self.assertIn("mode=dd", output)

    def test_no_color_preserves_keyboard_navigation(self):
        code, output = self.run_terminal(SELECT_MENU, "\x1b[B\n", NO_COLOR="")
        self.assertEqual(code, 0, output)
        self.assertIn("selected=2", output)
        self.assertIn("\x1b[H\x1b[2J", output)
        self.assertNotRegex(output, r"\x1b\[[0-9;]*m")

    def test_dumb_terminal_uses_numbered_menu(self):
        code, output = self.run_terminal(SELECT_MENU, "0\n", TERM="dumb")
        self.assertEqual(code, 0, output)
        self.assertIn("selected=0", output)
        self.assertNotIn("\x1b", output)

    def test_short_terminal_scrolls_to_last_option(self):
        code, output = self.run_terminal("UI_LANG=zh\n" + SELECT_MENU, "\x1b[A\n", rows=18, cols=40)
        self.assertEqual(code, 0, output)
        self.assertIn("selected=0", output)
        frames = output.split("\x1b[H\x1b[2J")
        first_frame = ANSI.sub("", frames[1])
        self.assertLessEqual(len(first_frame.splitlines()), 18)
        self.assertIn("退出", ANSI.sub("", frames[-1]))

    def test_refresh_updates_status_without_querying_on_every_arrow_key(self):
        code, output = self.run_terminal(SELECT_MENU, "r\x1b[Bq")
        self.assertEqual(code, 0, output)
        self.assertIn("selected=0", output)
        calls = (self.root / "service-calls").read_text().splitlines()
        self.assertEqual(len(calls), 4)

    def test_control_d_exits_without_leaving_terminal_settings_changed(self):
        code, output = self.run_terminal("""
if ui_select chosen menu_title main 1 "${UI_MAIN_OPTIONS[@]}"; then
  echo UNEXPECTED_SELECTION
else
  echo input-closed
fi
""", "\x04")
        self.assertEqual(code, 0, output)
        self.assertIn("input-closed", output)
        self.assertNotIn("UNEXPECTED_SELECTION", output)


if __name__ == "__main__":
    unittest.main()
