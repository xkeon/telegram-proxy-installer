"""Exercise installer workflows with temporary files and mocked host services."""

import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
OLD_EE = "nineseconds/mtg@sha256:" + "a" * 64
NEW_EE = "nineseconds/mtg@sha256:" + "b" * 64
OLD_DD = "telegrammessenger/proxy@sha256:" + "c" * 64
NEW_DD = "telegrammessenger/proxy@sha256:" + "d" * 64


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="proxy maintenance ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / "config"
        self.units = self.root / "units"
        self.backups = self.root / "backups"
        self.mtg = self.root / "mtg"
        self.config.mkdir()
        self.units.mkdir()
        self.mtg.mkdir()
        (self.mtg / "config.toml").write_text('bind-to = "0.0.0.0:3128"\n')
        (self.config / "ee.env").write_text(
            f"MTG_IMAGE={OLD_EE}\nEE_DOMAIN=ee.example.com\nEE_PORT=443\n"
            "EE_BIND_IP=0.0.0.0\nEE_BIND_IPV6=\n"
        )
        (self.config / "dd.env").write_text(
            f"DD_IMAGE={OLD_DD}\nDD_DOMAIN=dd.example.com\nDD_PORT=8443\n"
            "DD_BIND_IP=0.0.0.0\nDD_BIND_IPV6=\n"
            f"DD_SECRET=dd{'0' * 32}\n"
        )
        (self.units / "telegram-proxy-ee.service").write_text(f"old {OLD_EE}\n")
        (self.units / "telegram-proxy-dd.service").write_text(f"old {OLD_DD}\n")
        self.originals = {
            path: path.read_bytes()
            for directory in (self.config, self.units, self.mtg)
            for path in directory.iterdir()
        }

    def run_bash(self, body):
        setup = f"""
set -euo pipefail
source {shlex.quote(str(REPO / 'install.sh'))}
TEST_DIR={shlex.quote(str(self.root))}
CONFIG_DIR="$TEST_DIR/config"
SYSTEMD_UNIT_DIR="$TEST_DIR/units"
MTG_CONFIG_DIR="$TEST_DIR/mtg"
BACKUP_DIR="$TEST_DIR/backups"
EE_ENV_FILE="$CONFIG_DIR/ee.env"
DD_ENV_FILE="$CONFIG_DIR/dd.env"
NEW_EE={shlex.quote(NEW_EE)}
NEW_DD={shlex.quote(NEW_DD)}
FAIL_PULL=''
FAIL_RESTART=0
FAIL_HEALTH=0
HEALTH_CALLS=0
docker() {{
  printf '%s\\n' "$*" >> "$TEST_DIR/docker.log"
  if [[ "$1" == pull && "$2" == "$FAIL_PULL" ]]; then return 42; fi
  if [[ "$1" == image && "$2" == inspect ]]; then printf '%s' "$NEW_EE"; fi
  return 0
}}
systemctl() {{
  printf '%s\\n' "$*" >> "$TEST_DIR/systemctl.log"
  if [[ "$1" == restart && "$FAIL_RESTART" -gt 0 ]]; then
    FAIL_RESTART=$((FAIL_RESTART - 1))
    return 43
  fi
  return 0
}}
REAL_HEALTHCHECK="$(declare -f cmd_healthcheck)"
cmd_healthcheck() {{
  HEALTH_CALLS=$((HEALTH_CALLS + 1))
  if [[ "$FAIL_HEALTH" -eq 1 ]] && grep -Fq "$NEW_EE" "$EE_ENV_FILE"; then return 1; fi
  if [[ "$FAIL_HEALTH" -eq 2 ]]; then return 1; fi
  return 0
}}
sleep() {{ printf '%s\\n' "$*" >> "$TEST_DIR/sleep.log"; }}
"""
        return subprocess.run(
            ["bash", "-c", setup + "\n" + body],
            cwd=REPO,
            text=True,
            capture_output=True,
            timeout=20,
        )

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_files_unchanged(self):
        for path, original in self.originals.items():
            self.assertEqual(path.read_bytes(), original, str(path))

    def commands(self, filename):
        path = self.root / filename
        return path.read_text().splitlines() if path.exists() else []

    def test_port_boundaries_and_decimal_normalization(self):
        valid = {"1": "1", "65535": "65535", "0443": "443", "08443": "8443"}
        for value, expected in valid.items():
            with self.subTest(value=value):
                result = self.run_bash(f"normalize_port {shlex.quote(value)}")
                self.assert_success(result)
                self.assertEqual(result.stdout, expected)
        for value in ("", "0", "000", "65536", "999999999999999999999999", "-1", "8x"):
            with self.subTest(value=value):
                result = self.run_bash(f"normalize_port {shlex.quote(value)}")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stderr, "")

    def test_equivalent_ports_conflict_on_same_bind(self):
        self.assert_success(
            self.run_bash("ports_conflict_for_bindings 443 0.0.0.0 '' 0443 0.0.0.0 ''")
        )

    def test_same_port_on_different_specific_ips_does_not_conflict(self):
        result = self.run_bash(
            "ports_conflict_for_bindings 443 192.0.2.1 '' 0443 192.0.2.2 ''"
        )
        self.assertNotEqual(result.returncode, 0)

    def test_prompt_stores_canonical_port(self):
        result = self.run_bash("""
port_in_use() { return 1; }
ask_port ask_ee_port chosen <<< '08443'
printf '\\nchosen=%s\\n' "$chosen"
""")
        self.assert_success(result)
        self.assertIn("chosen=8443", result.stdout)

    def test_selected_port_is_normalized_before_occupancy_check(self):
        result = self.run_bash("""
port_in_use() { printf '%s' "$1" > "$TEST_DIR/checked-port"; return 1; }
check_and_prepare_port 0443
""")
        self.assert_success(result)
        self.assertEqual((self.root / "checked-port").read_text(), "443")

    def run_preflight(self, os_id, version):
        os_release = self.root / "os-release"
        os_release.write_text(f'ID={os_id}\nVERSION_ID="{version}"\n')
        return self.run_bash(f"""
OS_RELEASE_FILE={shlex.quote(str(os_release))}
ps() {{ printf 'systemd\\n'; }}
timedatectl() {{ printf 'yes\\n'; }}
getent() {{ return 0; }}
df() {{ printf 'Filesystem blocks used available capacity mount\\n/dev/test 8192 1024 7168 12%% /\\n'; }}
awk() {{
  if [[ "${{@: -1}}" == /proc/meminfo ]]; then printf '1048576\\n'; else command awk "$@"; fi
}}
confirm_continue() {{ return 1; }}
preflight_checks
""")

    def test_latest_ubuntu_passes_version_preflight(self):
        result = self.run_preflight("ubuntu", "26.04")
        self.assert_success(result)
        self.assertNotIn("Target is tuned", result.stdout)

    def test_other_os_versions_require_preflight_confirmation(self):
        for os_id, version in (("ubuntu", "22.04"), ("ubuntu", "24.04"), ("debian", "13")):
            with self.subTest(os_id=os_id, version=version):
                result = self.run_preflight(os_id, version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Ubuntu 26.04 LTS", result.stdout)
                self.assertIn(f"detected {os_id} {version}", result.stdout)

    def test_pull_failure_changes_no_files_or_services(self):
        result = self.run_bash("""
set_mode_flags ee
FAIL_PULL="$NEW_EE"
if cmd_upgrade "$NEW_EE" ''; then exit 99; fi
""")
        self.assert_success(result)
        self.assert_files_unchanged()
        self.assertEqual(self.commands("systemctl.log"), [])

    def test_dual_mode_second_pull_failure_changes_neither_mode(self):
        result = self.run_bash("""
set_mode_flags all
FAIL_PULL="$NEW_DD"
if cmd_upgrade "$NEW_EE" "$NEW_DD"; then exit 99; fi
""")
        self.assert_success(result)
        self.assert_files_unchanged()
        self.assertEqual(self.commands("systemctl.log"), [])

    def test_invalid_second_digest_prevents_first_mode_mutation(self):
        result = self.run_bash("""
set_mode_flags all
if cmd_upgrade "$NEW_EE" invalid; then exit 99; fi
""")
        self.assert_success(result)
        self.assert_files_unchanged()
        self.assertEqual(self.commands("docker.log"), [])

    def test_auto_pull_failure_does_not_use_cached_digest(self):
        result = self.run_bash("""
set_mode_flags ee
FAIL_PULL=nineseconds/mtg:2
if cmd_upgrade auto ''; then exit 99; fi
""")
        self.assert_success(result)
        self.assert_files_unchanged()
        self.assertEqual(self.commands("docker.log"), ["pull nineseconds/mtg:2"])

    def test_failed_backup_prevents_upgrade_mutation(self):
        result = self.run_bash("""
set_mode_flags ee
cp() { return 44; }
if cmd_upgrade "$NEW_EE" ''; then exit 99; fi
""")
        self.assert_success(result)
        self.assert_files_unchanged()
        self.assertEqual(self.commands("systemctl.log"), [])

    def test_successful_upgrade_uses_new_digests_in_units(self):
        result = self.run_bash("""
set_mode_flags all
cmd_upgrade "$NEW_EE" "$NEW_DD"
""")
        self.assert_success(result)
        for mode, digest in (("ee", NEW_EE), ("dd", NEW_DD)):
            self.assertIn(digest, (self.config / f"{mode}.env").read_text())
            self.assertIn(digest, (self.units / f"telegram-proxy-{mode}.service").read_text())
        self.assertEqual(
            self.commands("systemctl.log"),
            ["is-active --quiet telegram-proxy-ee.service", "is-active --quiet telegram-proxy-dd.service",
             "daemon-reload", "restart telegram-proxy-ee.service", "restart telegram-proxy-dd.service"],
        )
        backups = list(self.backups.iterdir())
        self.assertEqual(len(backups), 1)
        self.assertIn(OLD_EE, (backups[0] / "ee.env").read_text())

    def test_failed_restart_restores_files_and_restarts_previous_services(self):
        result = self.run_bash("""
set_mode_flags all
FAIL_RESTART=1
if cmd_upgrade "$NEW_EE" "$NEW_DD"; then exit 99; fi
""")
        self.assert_success(result)
        self.assert_files_unchanged()
        commands = self.commands("systemctl.log")
        self.assertEqual(commands.count("restart telegram-proxy-ee.service"), 2)
        self.assertIn("restart telegram-proxy-dd.service", commands)

    def test_failed_healthcheck_restores_previous_configuration(self):
        result = self.run_bash("""
set_mode_flags ee
FAIL_HEALTH=1
if cmd_upgrade "$NEW_EE" ''; then exit 99; fi
""")
        self.assert_success(result)
        self.assert_files_unchanged()
        self.assertEqual(len(self.commands("sleep.log")), 9)

    def test_recovery_failure_is_reported_with_backup_path(self):
        result = self.run_bash("""
set_mode_flags ee
FAIL_RESTART=2
if cmd_upgrade "$NEW_EE" ''; then exit 99; fi
""")
        self.assert_success(result)
        self.assertIn("Automatic recovery failed", result.stdout)
        self.assertIn(str(self.backups), result.stdout)

    def test_rollback_restarts_active_service(self):
        result = self.run_bash("""
set_mode_flags dd
create_backup regression
cmd_rollback "$LAST_BACKUP_PATH"
""")
        self.assert_success(result)
        self.assertIn("restart telegram-proxy-dd.service", self.commands("systemctl.log"))

    def test_rollback_restart_failure_is_not_reported_as_success(self):
        result = self.run_bash("""
set_mode_flags dd
create_backup regression
FAIL_RESTART=1
if cmd_rollback "$LAST_BACKUP_PATH"; then exit 99; fi
""")
        self.assert_success(result)
        self.assertNotIn("Rollback completed", result.stdout)

    def test_rollback_health_failure_is_not_reported_as_success(self):
        result = self.run_bash("""
set_mode_flags dd
create_backup regression
FAIL_HEALTH=2
if cmd_rollback "$LAST_BACKUP_PATH"; then exit 99; fi
""")
        self.assert_success(result)
        self.assertNotIn("Rollback completed", result.stdout)


if __name__ == "__main__":
    unittest.main()
