"""Exercise the standalone bootstrap and one-command download without host mutations."""

import os
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
MODULES = ("cli", "installer", "management", "menu", "messages", "migration", "operations")


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="proxy bootstrap ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = self.root / "project"
        self.fixture = self.root / "checkout-fixture"
        (self.fixture / "lib").mkdir(parents=True)
        (self.fixture / ".git").mkdir()
        (self.fixture / "install.sh").write_text(
            '#!/usr/bin/env bash\nprintf "%s\\n" "$@" > "$TASK_INSTALL_LOG"\nexit "${TASK_INSTALL_EXIT:-0}"\n'
        )
        for module in MODULES:
            (self.fixture / "lib" / (module + ".sh")).write_text("# fixture module\n")
        self.log = self.root / "commands.log"
        self.started = self.root / "installer.log"

    def run_bootstrap(self, arguments="--lang zh", *, git_ready=False, fail_apt=0, fail_git=0,
                      dirty="", incomplete=False, installer_exit=0):
        if git_ready:
            (self.root / "git-ready").touch()
        prefix = "source " + shlex.quote(str(REPO / "bootstrap.sh")) + "\n" + r'''
command() {
  if [[ "$*" == '-v git' && ! -f "$TASK_GIT_READY" ]]; then return 1; fi
  builtin command "$@"
}
bootstrap_as_root() {
  printf '%s\n' "$*" >> "$TASK_COMMAND_LOG"
  if [[ "$1" == apt-get ]]; then
    if [[ "$TASK_FAIL_APT" != 0 ]]; then return "$TASK_FAIL_APT"; fi
    if [[ "$2" == install ]]; then touch "$TASK_GIT_READY"; fi
  elif [[ "$1" == bash ]]; then
    shift
    builtin command bash "$@"
  else return 99; fi
}
git() {
  [[ -f "$TASK_GIT_READY" ]] || return 127
  printf 'git %s\n' "$*" >> "$TASK_COMMAND_LOG"
  if [[ "$*" == *'status --porcelain' ]]; then printf '%s' "$TASK_DIRTY"; return 0; fi
  [[ "$TASK_FAIL_GIT" == 0 ]] || return "$TASK_FAIL_GIT"
  if [[ "$1" == clone ]]; then
    cp -a "$TASK_FIXTURE/." "${@: -1}/"
    if [[ "$TASK_INCOMPLETE" == 1 ]]; then rm "${@: -1}/lib/menu.sh"; fi
  fi
}
'''
        environment = os.environ.copy()
        environment.update(
            TELEGRAM_PROXY_DIR=str(self.project), TASK_COMMAND_LOG=str(self.log),
            TASK_INSTALL_LOG=str(self.started), TASK_GIT_READY=str(self.root / "git-ready"),
            TASK_FIXTURE=str(self.fixture), TASK_FAIL_APT=str(fail_apt), TASK_FAIL_GIT=str(fail_git),
            TASK_DIRTY=dirty, TASK_INCOMPLETE=str(int(incomplete)), TASK_INSTALL_EXIT=str(installer_exit),
        )
        return subprocess.run(["bash", "-c", prefix + "bootstrap_main " + arguments],
                              cwd=self.root, env=environment, text=True, capture_output=True, timeout=10)

    def commands(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_missing_git_is_installed_before_clone_and_actual_menu(self):
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.commands()[:2], ["apt-get update", "apt-get install -y git ca-certificates"])
        self.assertTrue(self.commands()[2].startswith("git clone --branch main --single-branch https://github.com/"))
        self.assertEqual(self.started.read_text(), "--lang\nzh\n")
        self.assertTrue((self.project / "lib/menu.sh").exists())
        self.assertFalse(list(self.root.glob(".telegram-proxy-download.*")))

    def test_available_git_skips_package_installation(self):
        result = self.run_bootstrap(git_ready=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any(line.startswith("apt-get ") for line in self.commands()))

    def test_failed_clone_cleans_staging_and_does_not_launch(self):
        result = self.run_bootstrap(fail_git=68)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertFalse(self.project.exists())
        self.assertFalse(self.started.exists())
        self.assertFalse(list(self.root.glob(".telegram-proxy-download.*")))

    def test_package_failure_stops_before_git(self):
        result = self.run_bootstrap(fail_apt=69)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.commands(), ["apt-get update"])
        self.assertFalse(self.project.exists())
        self.assertFalse(self.started.exists())

    def test_existing_checkout_update_failure_keeps_files(self):
        shutil.copytree(self.fixture, self.project)
        original = (self.project / "install.sh").read_bytes()
        result = self.run_bootstrap(fail_git=70)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual((self.project / "install.sh").read_bytes(), original)
        self.assertFalse(self.started.exists())
        self.assertTrue(any("pull --ff-only" in line for line in self.commands()))
        self.assertFalse(any("git clone" in line for line in self.commands()))

    def test_existing_checkout_opens_menu_in_each_language(self):
        shutil.copytree(self.fixture, self.project)
        for language in ("en", "zh", "ko", "ja"):
            with self.subTest(language=language):
                result = self.run_bootstrap("--lang " + language)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.started.read_text(), "--lang\n" + language + "\n")
        self.assertFalse(any("git clone" in line for line in self.commands()))

    def test_dirty_checkout_is_preserved_and_never_pulled_or_run(self):
        shutil.copytree(self.fixture, self.project)
        result = self.run_bootstrap(dirty=" M install.sh\n")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Local changes", result.stderr)
        self.assertFalse(any("pull" in line for line in self.commands()))
        self.assertFalse(self.started.exists())

    def test_incomplete_download_is_removed_without_launch(self):
        result = self.run_bootstrap(incomplete=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("lib/menu.sh", result.stderr)
        self.assertFalse(self.project.exists())
        self.assertFalse(list(self.root.glob(".telegram-proxy-download.*")))
        self.assertFalse(self.started.exists())

    def test_non_checkout_directory_is_preserved(self):
        self.project.mkdir()
        sentinel = self.project / "user-data"
        sentinel.write_text("keep me")
        result = self.run_bootstrap(git_ready=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(sentinel.read_text(), "keep me")
        self.assertEqual(self.commands(), [])

    def test_installer_failure_is_returned(self):
        result = self.run_bootstrap(installer_exit=73)
        self.assertEqual(result.returncode, 73, result.stdout + result.stderr)

    def test_help_and_invalid_arguments_do_not_install_or_download(self):
        for arguments, code in (("--help", 0), ("--lang", 2), ("--lang invalid", 2), ("--unknown", 2)):
            with self.subTest(arguments=arguments):
                result = self.run_bootstrap(arguments)
                self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        self.assertEqual(self.commands(), [])
        self.assertFalse(self.project.exists())


class QuickStartCommandTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="proxy entry ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.started = self.root / "started"
        self.scripts = {}
        readme = (REPO / "README.md").read_text()
        for language, heading in (("en", "Quick Start"), ("zh", "快速开始"),
                                  ("ko", "빠른 시작"), ("ja", "クイックスタート")):
            match = re.search(r"### " + heading + r"\n.*?```bash\n(.*?)\n```", readme, re.S)
            self.assertIsNotNone(match, heading)
            self.scripts[language] = match.group(1).replace("$HOME/telegram-proxy-start.sh", str(self.root / "start.sh"))
            self.assertNotIn("\n", self.scripts[language])

    def run_command(self, language="zh", fail_download=0, fail_packages=0):
        prefix = r'''
sudo() { return "$TASK_FAIL_PACKAGES"; }
curl() {
  [[ "$TASK_FAIL_DOWNLOAD" == 0 ]] || return "$TASK_FAIL_DOWNLOAD"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "$TASK_STARTED"\n' > "${@: -1}"
}
'''
        environment = os.environ.copy()
        environment.update(TASK_FAIL_DOWNLOAD=str(fail_download), TASK_FAIL_PACKAGES=str(fail_packages),
                           TASK_STARTED=str(self.started))
        return subprocess.run(["bash", "-c", prefix + self.scripts[language]], env=environment,
                              text=True, capture_output=True, timeout=10)

    def test_command_downloads_complete_script_and_passes_language(self):
        for language in self.scripts:
            with self.subTest(language=language):
                result = self.run_command(language)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.started.read_text(), "--lang\n" + language + "\n")

    def test_failed_download_does_not_execute_an_existing_launcher(self):
        (self.root / "start.sh").write_text('echo UNEXPECTED_EXECUTION\n')
        result = self.run_command(fail_download=22)
        self.assertEqual(result.returncode, 22, result.stdout + result.stderr)
        self.assertNotIn("UNEXPECTED_EXECUTION", result.stdout)
        self.assertFalse(self.started.exists())

    def test_package_failure_prevents_download_and_execution(self):
        result = self.run_command(fail_packages=74)
        self.assertEqual(result.returncode, 74, result.stdout + result.stderr)
        self.assertFalse((self.root / "start.sh").exists())
        self.assertFalse(self.started.exists())
