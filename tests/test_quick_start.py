"""Run the documented bootstrap with isolated package, Git and sudo fixtures."""

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]


class QuickStartTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="proxy bootstrap ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = self.root / "project"
        self.log = self.root / "commands.log"
        self.started = self.root / "installer.log"
        self.installer = self.root / "fixture-installer.sh"
        self.installer.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$@" > "$TASK_INSTALL_LOG"\n')
        readme = (REPO / "README.md").read_text()
        self.scripts = {}
        for language, heading in (("en", "Quick Start"), ("zh", "快速开始"),
                                  ("ko", "빠른 시작"), ("ja", "クイックスタート")):
            match = re.search(r"### " + heading + r"\n.*?```bash\n(.*?)\n```", readme, re.S)
            self.assertIsNotNone(match, heading)
            # Keep HOME intact; route only the documented checkout path into our fixture.
            self.scripts[language] = match.group(1).replace("$HOME/telegram-proxy-installer", str(self.project))

    def run_bootstrap(self, language="zh", fail_apt=0, fail_git=0):
        prefix = r'''
sudo() {
  printf '%s\n' "$*" >> "$TASK_COMMAND_LOG"
  if [[ "$1" == apt-get ]]; then
    if [[ "$TASK_FAIL_APT" != 0 ]]; then return "$TASK_FAIL_APT"; fi
    if [[ "$2" == install ]]; then touch "$TASK_GIT_READY"; fi
  elif [[ "$1" == bash ]]; then
    shift
    command bash "$@"
  else return 99; fi
}
git() {
  [[ -f "$TASK_GIT_READY" ]] || return 127
  printf 'git %s\n' "$*" >> "$TASK_COMMAND_LOG"
  [[ "$TASK_FAIL_GIT" == 0 ]] || return "$TASK_FAIL_GIT"
  if [[ "$1" == clone ]]; then
    mkdir -p "${@: -1}/.git"
    cp "$TASK_FIXTURE_INSTALLER" "${@: -1}/install.sh"
  fi
}
'''
        environment = os.environ.copy()
        environment.update(
            TASK_COMMAND_LOG=str(self.log), TASK_INSTALL_LOG=str(self.started),
            TASK_GIT_READY=str(self.root / "git-ready"), TASK_FIXTURE_INSTALLER=str(self.installer),
            TASK_FAIL_APT=str(fail_apt), TASK_FAIL_GIT=str(fail_git),
        )
        return subprocess.run(["bash", "-c", prefix + self.scripts[language]],
                              env=environment, text=True, capture_output=True, timeout=10)

    def test_missing_git_is_installed_before_download_and_menu_launch(self):
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        lines = self.log.read_text().splitlines()
        self.assertEqual(lines[:2], ["apt-get update", "apt-get install -y git ca-certificates"])
        self.assertTrue(lines[2].startswith("git clone https://github.com/xkeon/telegram-proxy-installer.git "))
        self.assertEqual(self.started.read_text(), "--lang\nzh\n")

    def test_download_failure_stops_without_running_missing_installer(self):
        result = self.run_bootstrap(fail_git=68)
        self.assertEqual(result.returncode, 68, result.stdout + result.stderr)
        self.assertFalse(self.project.exists())
        self.assertFalse(self.started.exists())
        self.assertFalse(any(line.startswith("bash ") for line in self.log.read_text().splitlines()))

    def test_package_failure_stops_before_git(self):
        result = self.run_bootstrap(fail_apt=69)
        self.assertEqual(result.returncode, 69, result.stdout + result.stderr)
        self.assertEqual(self.log.read_text().splitlines(), ["apt-get update"])
        self.assertFalse(self.project.exists())
        self.assertFalse(self.started.exists())

    def test_existing_checkout_update_failure_preserves_it_and_stops(self):
        self.project.mkdir()
        (self.project / ".git").mkdir()
        script = self.project / "install.sh"
        script.write_bytes(self.installer.read_bytes())
        result = self.run_bootstrap(fail_git=70)
        self.assertEqual(result.returncode, 70, result.stdout + result.stderr)
        self.assertEqual(script.read_bytes(), self.installer.read_bytes())
        self.assertFalse(self.started.exists())
        self.assertIn("pull --ff-only", self.log.read_text())
        self.assertNotIn("git clone", self.log.read_text())

    def test_existing_checkout_opens_real_menu_in_each_language(self):
        self.project.mkdir()
        (self.project / ".git").mkdir()
        (self.project / "install.sh").write_bytes(self.installer.read_bytes())
        for language in self.scripts:
            with self.subTest(language=language):
                result = self.run_bootstrap(language)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.started.read_text(), "--lang\n" + language + "\n")
        self.assertNotIn("git clone", self.log.read_text())
