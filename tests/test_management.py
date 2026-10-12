"""End-to-end manager workflows against isolated files and explicit host mocks."""

import json
import os
import shlex
import shutil
import unittest

import test_installer as maintenance


EE_SECRET = "ee" + "1" * 32 + "www.cloudflare.com".encode().hex()
DD_SECRET = "dd" + "0" * 32


class ManagementTests(unittest.TestCase):
    def setUp(self):
        self.fixture = maintenance.InstallerTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root = self.fixture.root
        self.config = self.fixture.config
        self.units = self.fixture.units
        self.backups = self.fixture.backups
        self.mtg = self.fixture.mtg
        with (self.config / "ee.env").open("a") as file:
            file.write(f"EE_SECRET={EE_SECRET}\nFRONT_DOMAIN=www.cloudflare.com\n")
        with (self.config / "dd.env").open("a") as file:
            file.write("DD_BASE_SECRET=" + "0" * 32 + "\n")
        self.originals = {
            path: path.read_bytes()
            for directory in (self.config, self.units, self.mtg)
            for path in directory.iterdir()
        }

    def run_bash(self, body):
        # Every mutating host dependency is mocked. File operations stay in the fixture.
        setup = r'''
ASSUME_YES=1 NON_INTERACTIVE=1
preflight_checks() { return 0; }
bootstrap_installer() { echo bootstrap >> "$TEST_DIR/bootstrap.log"; }
require_root() { return 0; }
acquire_run_lock() { echo locked >> "$TEST_DIR/lock.log"; }
get_primary_ipv4() { echo 10.0.0.2; }
get_primary_ipv6() { echo fd00::2; }
resolve_domain_a_records() { echo 203.0.113.5; }
resolve_domain_aaaa_records() { echo 2001:db8::5; }
resolve_domain_a_records_via_resolver() { echo 203.0.113.5; }
resolve_domain_aaaa_records_via_resolver() { echo 2001:db8::5; }
timeout() { return 0; }
ss() { return 0; }
dig() { return 0; }
ufw() {
  printf '%s\n' "$*" >> "$TEST_DIR/ufw.log"
  case "$1" in status) echo 'Status: inactive';; show) echo 'ufw allow 22/tcp';; esac
}
sysctl() {
  printf '%s\n' "$*" >> "$TEST_DIR/sysctl.log"
  case "$*" in
    'net.ipv4.tcp_available_congestion_control') echo 'reno cubic bbr';;
    '-n net.core.default_qdisc') echo fq_codel;;
    '-n net.ipv4.tcp_congestion_control') echo cubic;;
  esac
}
check_mode_health() { [[ -f "$(mode_file "$1")" ]] || return 2; }
docker() {
  printf '%s\n' "$*" >> "$TEST_DIR/docker.log"
  if [[ "$1" == pull && "$2" == "$FAIL_PULL" ]]; then return 42; fi
  if [[ "$1" == run && "$*" == *generate-secret* ]]; then
    python3 -c 'import sys; print("ee"+"2"*32+sys.argv[1].encode().hex())' "${@: -1}"
  elif [[ "$1" == stats ]]; then echo '1.2% / 20MiB / 1MB';
  elif [[ "$1" == image && "$2" == inspect ]]; then
    if [[ "$*" == *org.opencontainers.image.version* ]]; then echo 2.0.4; else echo "$NEW_EE"; fi
  fi
}
BBR_FILE="$TEST_DIR/bbr.conf"
'''
        return self.fixture.run_bash(setup + "\n" + body)

    def success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def unchanged(self):
        for path, value in self.originals.items():
            self.assertEqual(path.read_bytes(), value, str(path))

    def commands(self, filename):
        return self.fixture.commands(filename)

    def test_rotation_snapshots_old_key_and_selected_mode(self):
        result = self.run_bash('set_mode_flags all; cmd_rotate_secret dd auto ""')
        self.success(result)
        backup = next(self.backups.iterdir())
        self.assertEqual((backup / "dd.env").read_bytes(), self.originals[self.config / "dd.env"])
        self.assertFalse((backup / "ee.env").exists())
        self.assertIn("DEPLOY_EE=0", (backup / "meta.env").read_text())
        self.assertNotIn(DD_SECRET, result.stdout)
        self.assertNotEqual((self.config / "dd.env").read_bytes(), self.originals[self.config / "dd.env"])

    def test_failed_rotation_restores_old_configuration(self):
        result = self.run_bash('FAIL_RESTART=1; if cmd_rotate_secret dd auto ""; then exit 99; fi')
        self.success(result)
        self.unchanged()
        self.assertNotIn("Secret rotation completed", result.stdout)

    def test_manual_fake_tls_key_must_match_domain_even_in_dry_run(self):
        result = self.run_bash('DRY_RUN=1; cmd_rotate_secret ee bad www.cloudflare.com')
        self.assertNotEqual(result.returncode, 0)
        self.unchanged()
        self.assertFalse(self.backups.exists())
        self.assertEqual(self.commands("docker.log"), [])

    def test_configure_changes_port_without_rotating_secret(self):
        result = self.run_bash('REQUEST[mode]=ee; REQUEST[EE_PORT]=0444; manager_install configure')
        self.success(result)
        content = (self.config / "ee.env").read_text()
        self.assertIn("EE_PORT=444", content)
        self.assertIn(f"EE_SECRET={EE_SECRET}", content)
        self.assertIn("0.0.0.0:444:3128", (self.units / "telegram-proxy-ee.service").read_text())
        self.assertEqual(self.commands("bootstrap.log"), [])

    def test_writing_configuration_protects_keys_even_when_files_exist(self):
        result = self.run_bash('REQUEST[mode]=all; prepare_settings configure; apply_settings')
        self.success(result)
        for path in (self.config / "ee.env", self.config / "dd.env", self.mtg / "config.toml", self.units / "telegram-proxy-ee.service", self.units / "telegram-proxy-dd.service"):
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600, str(path))

    def test_front_domain_change_rotates_key_and_updates_links(self):
        result = self.run_bash('REQUEST[mode]=ee; REQUEST[FRONT_DOMAIN]=www.microsoft.com; SHOW_SECRET=1; manager_install configure')
        self.success(result)
        expected = "ee" + "2" * 32 + "www.microsoft.com".encode().hex()
        self.assertIn(f"EE_SECRET={expected}", (self.config / "ee.env").read_text())
        self.assertIn(expected, result.stdout)
        self.assertIn("rotates", result.stdout)

    def test_failed_configure_health_restores_both_modes(self):
        result = self.run_bash(r'''
REQUEST[mode]=all; REQUEST[EE_PORT]=444
cmd_healthcheck() { ! grep -q '^EE_PORT=444$' "$EE_ENV_FILE"; }
if manager_install configure; then exit 99; fi
''')
        self.success(result)
        self.unchanged()
        self.assertEqual(len(self.commands("sleep.log")), 9)

    def test_failed_fresh_install_removes_new_managed_files(self):
        result = self.run_bash(r'''
rm -f "$EE_ENV_FILE" "$DD_ENV_FILE" "$SYSTEMD_UNIT_DIR/"*.service "$MTG_CONFIG_DIR/config.toml"
REQUEST[mode]=dd; REQUEST[DD_DOMAIN]=203.0.113.5
FAIL_HEALTH=2
if manager_install install; then exit 99; fi
''')
        self.success(result)
        self.assertFalse((self.config / "dd.env").exists())
        self.assertFalse((self.units / "telegram-proxy-dd.service").exists())
        self.assertNotIn("Installation completed", result.stdout)
        self.assertIn("disable --now telegram-proxy-dd.service", self.commands("systemctl.log"))

    def test_second_pull_failure_leaves_existing_configuration(self):
        result = self.run_bash('REQUEST[mode]=all; FAIL_PULL="' + maintenance.OLD_DD + '"; if manager_install configure; then exit 99; fi')
        self.success(result)
        self.unchanged()
        self.assertFalse(self.backups.exists())

    def test_conflicting_port_rejected_before_pull_or_backup(self):
        result = self.run_bash('REQUEST[mode]=ee; REQUEST[EE_PORT]=08443; if manager_install configure; then exit 99; fi')
        self.success(result)
        self.unchanged()
        self.assertEqual(self.commands("docker.log"), [])
        self.assertFalse(self.backups.exists())

    def test_existing_unmanaged_socket_is_not_deleted(self):
        result = self.run_bash(r'''
ss() { echo 'LISTEN 0 128 0.0.0.0:444 0.0.0.0:*'; }
REQUEST[mode]=ee; REQUEST[EE_PORT]=444
if manager_install configure; then exit 99; fi
''')
        self.success(result)
        self.unchanged()
        self.assertFalse(any(line.startswith("rm ") for line in self.commands("docker.log")))

    def test_install_dry_run_does_not_bootstrap_lock_or_backup(self):
        result = self.run_bash('manager_main install --mode dd --domain 203.0.113.5 --port 08444 --dry-run --yes')
        self.success(result)
        self.unchanged()
        for name in ("docker.log", "systemctl.log", "bootstrap.log", "lock.log", "ufw.log"):
            self.assertEqual(self.commands(name), [], name)
        self.assertIn("8444", result.stdout)
        self.assertFalse(self.backups.exists())

    def test_reinstall_is_explicit_and_changes_existing_key(self):
        result = self.run_bash('REQUEST[mode]=dd; REINSTALL=1; manager_install install')
        self.success(result)
        self.assertNotIn(f"DD_SECRET={DD_SECRET}", (self.config / "dd.env").read_text())

    def test_repeat_install_preserves_existing_key(self):
        result = self.run_bash('REQUEST[mode]=dd; manager_install install')
        self.success(result)
        self.assertIn(f"DD_SECRET={DD_SECRET}", (self.config / "dd.env").read_text())

    def test_wizard_back_preserves_earlier_values_and_cancel_writes_nothing(self):
        result = self.run_bash(r'''
REQUEST[mode]=dd; prepare_settings configure
if settings_wizard configure <<<'new.example.com
0

q'; then exit 99; else test "$?" -eq 130; fi
printf 'chosen=%s\n' "$DD_DOMAIN"
''')
        self.success(result)
        self.assertIn("chosen=new.example.com", result.stdout)
        self.unchanged()
        self.assertFalse(self.backups.exists())

    def test_wizard_eof_returns_cancellation(self):
        result = self.run_bash('prepare_settings configure; if settings_wizard </dev/null; then exit 99; else test "$?" -eq 130; fi')
        self.success(result)
        self.unchanged()

    def test_wizard_edits_reviewed_port_before_apply(self):
        result = self.run_bash(r'''
REQUEST[mode]=dd; prepare_settings configure
settings_wizard configure <<'INPUT'


2
2
8555
1
INPUT
printf 'chosen=%s\n' "$DD_PORT"
''')
        self.success(result)
        self.assertIn("chosen=8555", result.stdout)
        self.unchanged()

    def test_health_missing_mode_returns_two_and_all_skips_absent(self):
        result = self.run_bash(r'''
eval "$REAL_HEALTHCHECK"
rm "$EE_ENV_FILE"
set_mode_flags ee
if cmd_healthcheck; then exit 99; else test "$?" -eq 2; fi
set_mode_flags all; cmd_healthcheck
''')
        self.success(result)

    def test_health_json_has_missing_status_without_leaking_key(self):
        result = self.run_bash(r'''
check_mode_health() { if [[ "$1" == ee ]]; then echo 'secret='"$(read_env_key "$EE_ENV_FILE" EE_SECRET)"; return 0; else return 2; fi; }
set_mode_flags all; healthcheck_json
''')
        self.success(result)
        payload = json.loads(result.stdout)
        self.assertEqual([row["exit_code"] for row in payload["modes"]], [0, 2])
        self.assertNotIn(EE_SECRET, result.stdout)
        self.assertIn("REDACTED", result.stdout)

    def test_self_heal_missing_mode_returns_two_without_restart(self):
        result = self.run_bash('rm "$EE_ENV_FILE"; set_mode_flags ee; cmd_self_heal')
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(self.commands("systemctl.log"), [])

    def test_status_json_has_resources_version_and_no_secret(self):
        result = self.run_bash('manager_main status --mode ee --json')
        self.success(result)
        mode = json.loads(result.stdout)["modes"][0]
        self.assertEqual(mode["version"], "2.0.4")
        self.assertIn("20MiB", mode["resources"])
        self.assertNotIn(EE_SECRET, result.stdout)
        self.assertEqual(self.commands("lock.log"), [])

    def test_links_hide_key_until_requested_and_encode_ipv6(self):
        result = self.run_bash(r'''
set_mode_flags dd
upsert_env_key "$DD_ENV_FILE" DD_DOMAIN 2001:db8::5
cmd_links 0 0
''')
        self.success(result)
        self.assertNotIn(DD_SECRET, result.stdout)
        self.assertIn("2001%3Adb8%3A%3A5", result.stdout)
        reveal = self.run_bash('set_mode_flags dd; cmd_links 1 0')
        self.success(reveal)
        self.assertIn(DD_SECRET, reveal.stdout)

    def test_local_qr_receives_complete_link_and_never_calls_curl(self):
        result = self.run_bash(r'''
qrencode() { cat > "$TEST_DIR/qr-input"; echo LOCAL-QR; }
curl() { echo network-call >> "$TEST_DIR/network.log"; return 99; }
set_mode_flags dd; cmd_links 0 1
''')
        self.success(result)
        self.assertIn(DD_SECRET, (self.root / "qr-input").read_text())
        self.assertEqual(self.commands("network.log"), [])

    def test_backup_list_skips_incomplete_and_retention_preserves_unrelated(self):
        result = self.run_bash(r'''
set_mode_flags ee
create_backup first >/dev/null
touch -d '2020-01-01' "$LAST_BACKUP_PATH"
create_backup second >/dev/null
mkdir "$BACKUP_DIR/unrelated" "$BACKUP_DIR/incomplete"
printf 'SNAPSHOT_VERSION=1\n' > "$BACKUP_DIR/incomplete/meta.env"
cmd_backups
prune_backups 1
''')
        self.success(result)
        self.assertNotIn("incomplete", result.stdout)
        self.assertTrue((self.backups / "unrelated").exists())
        self.assertTrue((self.backups / "incomplete").exists())
        self.assertEqual(len(list(self.backups.glob("*/.complete"))), 1)
        self.assertIn("EE=1 DD=0", result.stdout)

    def test_backup_chooser_uses_same_index_as_list(self):
        result = self.run_bash(r'''
set_mode_flags dd; create_backup choose >/dev/null
mkdir "$BACKUP_DIR/incomplete"
printf 'SNAPSHOT_VERSION=1\n' > "$BACKUP_DIR/incomplete/meta.env"
chosen="$(choose_backup <<<1)"
test "$chosen" = "$LAST_BACKUP_PATH"
''')
        self.success(result)

    def test_backup_restores_intentionally_stopped_service(self):
        result = self.run_bash(r'''
set_mode_flags ee; touch "$CONFIG_DIR/paused-ee"
create_backup stopped >/dev/null
rm "$CONFIG_DIR/paused-ee"
restore_backup "$LAST_BACKUP_PATH"
verify_recovery "$LAST_BACKUP_PATH"
''')
        self.success(result)
        self.assertTrue((self.config / "paused-ee").exists())
        self.assertNotIn("restart telegram-proxy-ee.service", self.commands("systemctl.log"))
        self.assertIn("stop telegram-proxy-ee.service", self.commands("systemctl.log"))

    def test_stop_pauses_watchdog_and_start_clears_state(self):
        result = self.run_bash(r'''
set_mode_flags ee; cmd_service stop 50
test -f "$CONFIG_DIR/paused-ee"
printf 'COUNT=3\nLAST=0\n' > "$CONFIG_DIR/watchdog-ee.env"
cmd_service start 50
test ! -f "$CONFIG_DIR/paused-ee"
test ! -f "$CONFIG_DIR/watchdog-ee.env"
''')
        self.success(result)

    def test_failed_service_action_preserves_pause_state(self):
        result = self.run_bash(r'''
set_mode_flags ee
systemctl() { return 9; }
if cmd_service stop 50; then exit 99; fi
test ! -f "$CONFIG_DIR/paused-ee"
touch "$CONFIG_DIR/paused-ee"
if cmd_service start 50; then exit 99; fi
test -f "$CONFIG_DIR/paused-ee"
''')
        self.success(result)

    def test_service_logs_redact_existing_secrets(self):
        result = self.run_bash(r'''
journalctl() { cat "$DD_ENV_FILE"; }
set_mode_flags dd; cmd_service logs 10
''')
        self.success(result)
        self.assertNotIn(DD_SECRET, result.stdout)
        self.assertIn("REDACTED", result.stdout)

    def test_firewall_failure_recovery_removes_only_added_rules(self):
        result = self.run_bash(r'''
collect_sshd_ports() { printf '22\n444\n'; }
REQUEST[mode]=ee; REQUEST[EE_PORT]=444; REQUEST[FIREWALL_POLICY]=enable
FAIL_RESTART=1
if manager_install configure; then exit 99; fi
''')
        self.success(result)
        self.unchanged()
        commands = self.commands("ufw.log")
        self.assertEqual(commands.count("allow 444/tcp"), 1)
        self.assertIn("--force delete allow 444/tcp", commands)
        self.assertNotIn("--force delete allow 22/tcp", commands)
        self.assertIn("--force disable", commands)

    def test_bbr_failure_restores_previous_file_and_runtime(self):
        result = self.run_bash(r'''
printf '# previous BBR settings\n' > "$BBR_FILE"
REQUEST[mode]=ee; REQUEST[ENABLE_BBR]=yes; FAIL_RESTART=1
if manager_install configure; then exit 99; fi
''')
        self.success(result)
        self.assertEqual((self.root / "bbr.conf").read_text(), "# previous BBR settings\n")
        self.assertIn("-w net.core.default_qdisc=fq_codel net.ipv4.tcp_congestion_control=cubic", self.commands("sysctl.log"))

    def test_nat_diagnosis_does_not_compare_dns_to_private_address(self):
        result = self.run_bash('set_mode_flags dd; cmd_diagnose_report ""')
        self.success(result)
        self.assertIn("Public IP is unknown", result.stdout)
        self.assertNotIn("does not match", result.stdout)
        self.assertNotIn("10.0.0.2", result.stdout)

    def test_diagnosis_uses_saved_public_address_and_fails_dns_mismatch(self):
        result = self.run_bash(r'''
upsert_env_key "$DD_ENV_FILE" PUBLIC_IPV4 203.0.113.99
set_mode_flags dd; cmd_diagnose_report "$TEST_DIR/report.txt"
''')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("203.0.113.99", result.stdout)
        self.assertIn("DNS A/AAAA", result.stdout)
        self.assertEqual(os.stat(self.root / "report.txt").st_mode & 0o777, 0o600)

    def test_report_redacts_keys_and_preserves_diagnostic_exit(self):
        result = self.run_bash(r'''
cmd_regional_diagnose() { cat "$EE_ENV_FILE" "$DD_ENV_FILE"; return 7; }
cmd_diagnose_report "$TEST_DIR/report.txt"
''')
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        report = (self.root / "report.txt").read_text()
        self.assertNotIn(EE_SECRET, report)
        self.assertNotIn(DD_SECRET, report)
        self.assertIn("REDACTED", report)

    def test_equivalent_ipv6_dns_records_match(self):
        result = self.run_bash('dns_records_match 2001:0DB8::5 "2001:db8:0:0:0:0:0:5"; check_domain_dns example.com "" 2001:0db8::5 0 1')
        self.success(result)
        self.assertNotIn("mismatch", result.stdout)

    def test_strict_cli_rejects_missing_unknown_and_misplaced_flags(self):
        for arguments in ("install --mode", "status --yes", "menu --dry-run", "service --action invalid", "monitor --interval 0", "status --mode invalid", "healthcheck --json --wat", "backups --keep 0 --prune"):
            with self.subTest(arguments=arguments):
                result = self.run_bash("manager_main " + arguments)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.unchanged()
        self.assertEqual(self.commands("lock.log"), [])

    def test_config_flags_take_precedence_regardless_of_order(self):
        config = self.root / "automation.conf"
        config.write_text("MODE=dd\nDD_DOMAIN=203.0.113.5\nDD_PORT=9000\n")
        result = self.run_bash('manager_main install --dd-port 8555 --config ' + shlex.quote(str(config)) + ' --dry-run')
        self.success(result)
        self.assertIn("8555", result.stdout)
        self.assertNotIn("9000", result.stdout)
        self.unchanged()

    def test_configuration_files_are_read_as_data(self):
        config = self.root / "automation.conf"
        marker = self.root / "executed"
        config.write_text("MODE=dd\nDD_DOMAIN=$(touch " + shlex.quote(str(marker)) + ")\n")
        result = self.run_bash('manager_main install --config ' + shlex.quote(str(config)) + ' --dry-run')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())
        self.unchanged()

    def test_private_secret_file_rotation_and_permission_rejection(self):
        secret_file = self.root / "new-secret"
        secret_file.write_text("dd" + "3" * 32 + "\n")
        secret_file.chmod(0o644)
        result = self.run_bash('manager_main rotate-secret --mode dd --secret-file ' + shlex.quote(str(secret_file)) + ' --yes')
        self.assertEqual(result.returncode, 2)
        self.unchanged()
        secret_file.chmod(0o600)
        result = self.run_bash('manager_main rotate-secret --mode dd --secret-file ' + shlex.quote(str(secret_file)) + ' --yes')
        self.success(result)
        self.assertIn("DD_SECRET=dd" + "3" * 32, (self.config / "dd.env").read_text())

    def test_self_update_rejects_dirty_checkout_and_failed_pull(self):
        result = self.run_bash(r'''
git() { if [[ "$*" == *status* ]]; then echo ' M install.sh'; fi; }
cmd_self_update
''')
        self.assertEqual(result.returncode, 1)
        self.assertIn("local changes", result.stdout)
        failed = self.run_bash(r'''
git() { if [[ "$*" == *pull* ]]; then return 9; fi; }
cmd_self_update
''')
        self.assertEqual(failed.returncode, 1)
        self.assertNotIn("Self-update completed", failed.stdout)

    def test_monitor_enable_writes_stable_runner_and_bounded_timer(self):
        result = self.run_bash('set_mode_flags dd; monitor_enable 5 3 300')
        self.success(result)
        service = (self.units / "telegram-proxy-monitor.service").read_text()
        self.assertIn(str(self.config / "runner/install.sh"), service)
        self.assertIn("--mode dd --max-retries 3 --cooldown 300", service)
        self.assertNotIn(str(maintenance.REPO), service)
        self.assertTrue((self.config / "runner/lib/management.sh").exists())
        self.assertIn("OnUnitActiveSec=5min", (self.units / "telegram-proxy-monitor.timer").read_text())

    def test_monitor_enable_failure_removes_partial_units(self):
        result = self.run_bash(r'''
systemctl() {
  printf '%s\n' "$*" >> "$TEST_DIR/systemctl.log"
  [[ "$1" != enable ]] || return 8
}
if monitor_enable 5 3 300; then exit 99; fi
''')
        self.success(result)
        self.assertFalse((self.units / "telegram-proxy-monitor.service").exists())
        self.assertFalse((self.units / "telegram-proxy-monitor.timer").exists())

    def watchdog_setup(self):
        return r'''
set_mode_flags ee
check_mode_health() { return 1; }
systemctl() { printf '%s\n' "$*" >> "$TEST_DIR/systemctl.log"; if [[ "$1" == is-enabled ]]; then echo enabled; fi; }
'''

    def test_watchdog_retry_limit_prevents_unbounded_restart(self):
        result = self.run_bash(self.watchdog_setup() + r'''
printf 'COUNT=3\nLAST=0\n' > "$CONFIG_DIR/watchdog-ee.env"
if cmd_watchdog 3 300; then exit 99; fi
''')
        self.success(result)
        self.assertNotIn("restart telegram-proxy-ee.service", self.commands("systemctl.log"))

    def test_watchdog_cooldown_prevents_immediate_restart(self):
        result = self.run_bash(self.watchdog_setup() + r'''
printf 'COUNT=1\nLAST=%s\n' "$(date +%s)" > "$CONFIG_DIR/watchdog-ee.env"
if cmd_watchdog 3 300; then exit 99; fi
''')
        self.success(result)
        self.assertNotIn("restart telegram-proxy-ee.service", self.commands("systemctl.log"))

    def test_watchdog_attempt_persists_counter_before_restart(self):
        result = self.run_bash(self.watchdog_setup() + 'if cmd_watchdog 3 300; then exit 99; fi')
        self.success(result)
        self.assertIn("restart telegram-proxy-ee.service", self.commands("systemctl.log"))
        self.assertIn("COUNT=1", (self.config / "watchdog-ee.env").read_text())
        self.assertEqual(os.stat(self.config / "watchdog-ee.env").st_mode & 0o777, 0o600)

    def test_watchdog_leaves_deliberately_stopped_service_alone(self):
        result = self.run_bash(self.watchdog_setup() + 'touch "$CONFIG_DIR/paused-ee"; cmd_watchdog 3 300')
        self.success(result)
        self.assertNotIn("restart telegram-proxy-ee.service", self.commands("systemctl.log"))

    def test_healthy_watchdog_resets_retry_counter(self):
        result = self.run_bash('set_mode_flags ee; printf "COUNT=3\\nLAST=0\\n" > "$CONFIG_DIR/watchdog-ee.env"; cmd_watchdog 3 300')
        self.success(result)
        self.assertFalse((self.config / "watchdog-ee.env").exists())

    def test_uninstall_selected_mode_keeps_other_mode_and_backup(self):
        result = self.run_bash('set_mode_flags ee; manager_uninstall')
        self.success(result)
        self.assertFalse((self.config / "ee.env").exists())
        self.assertEqual((self.config / "dd.env").read_bytes(), self.originals[self.config / "dd.env"])
        self.assertTrue(next(self.backups.iterdir()).joinpath("ee.env").exists())

    def test_failed_uninstall_restores_previous_files(self):
        result = self.run_bash(r'''
systemd_reload() { if [[ -f "$EE_ENV_FILE" ]]; then return 0; else return 9; fi; }
set_mode_flags ee; if manager_uninstall; then exit 99; fi
''')
        self.success(result)
        self.unchanged()

    def test_port_cleanup_deletes_only_selected_holder(self):
        result = self.run_bash(r'''
docker() {
  printf '%s\n' "$*" >> "$TEST_DIR/docker.log"
  case "$1" in
    ps) printf 'wrong-port\nunrelated\nselected\n';;
    inspect)
      case "$3" in
        '{{.Name}}') if [[ "$4" == unrelated ]]; then echo /other; else echo /mtproto-dd; fi;;
        '{{.Config.Image}}') echo telegrammessenger/proxy:latest;;
        *) if [[ "$4" == wrong-port ]]; then echo 9999; else echo 443; fi;;
      esac;;
  esac
}
ui_select() { printf -v "$1" '%s' 1; }
cleanup_port_targets 0443
''')
        self.success(result)
        removals = [command for command in self.commands("docker.log") if command.startswith("rm ")]
        self.assertEqual(removals, ["rm -f selected"])

    def test_preferences_remember_language_and_retention(self):
        result = self.run_bash(r'''
save_preferences() {
  printf 'UI_LANG=%s\nBACKUP_KEEP=%s\n' "$UI_LANG" "$BACKUP_KEEP" > "$CONFIG_DIR/preferences.env"
}
UI_LANG=zh BACKUP_KEEP=7; save_preferences
UI_LANG=en BACKUP_KEEP=20; load_preferences
test "$UI_LANG" = zh; test "$BACKUP_KEEP" = 7
''')
        self.success(result)

    def test_absent_status_does_not_reuse_other_modes_bindings(self):
        result = self.run_bash('rm "$DD_ENV_FILE"; set_mode_flags all; cmd_status 1')
        self.success(result)
        rows = json.loads(result.stdout)["modes"]
        self.assertEqual(rows[0]["bind_ipv4"], "0.0.0.0")
        self.assertEqual(rows[1]["bind_ipv4"], "")
        self.assertEqual(rows[1]["state"], "not_installed")

    def test_simple_wizard_accepts_custom_port_and_applies_once(self):
        result = self.run_bash(r'''
REQUEST[mode]=dd; prepare_settings configure
settings_wizard configure <<'INPUT'

2053
1
INPUT
test "$DD_PORT" = 2053; test "$WIZARD_APPROVED" = 1
''')
        self.success(result)
        self.unchanged()

    def test_simple_install_only_asks_for_address_and_port(self):
        result = self.run_bash(r'''
REQUEST[mode]=ee; prepare_settings install
settings_wizard install <<'INPUT'
1
new.example.com

1
INPUT
test "$EE_DOMAIN:$EE_PORT" = new.example.com:443
test "$WIZARD_APPROVED" = 1
''')
        self.success(result)
        self.assertNotIn("Enable BBR", result.stdout)
        self.assertNotIn("Firewall (", result.stdout)
        self.unchanged()

    def test_apply_button_is_the_only_install_confirmation(self):
        result = self.run_bash(r'''
NON_INTERACTIVE=0 ASSUME_YES=0
REQUEST[mode]=dd
confirm_action() { echo UNEXPECTED_SECOND_CONFIRMATION; return 1; }
manager_install configure <<'INPUT'

8555
1
INPUT
''')
        self.success(result)
        self.assertNotIn("UNEXPECTED_SECOND_CONFIRMATION", result.stdout)
        self.assertIn("DD_PORT=8555", (self.config / "dd.env").read_text())

    def test_cancel_simple_install_does_not_bootstrap_or_save(self):
        result = self.run_bash(r'''
NON_INTERACTIVE=0 ASSUME_YES=0
REQUEST[mode]=ee
manager_install install <<'INPUT'
1
q
INPUT
test "$MENU_CANCELLED" = 1
''')
        self.success(result)
        self.unchanged()
        self.assertEqual(self.commands("bootstrap.log"), [])
        self.assertFalse(self.backups.exists())

    def test_advanced_settings_return_to_review_before_application(self):
        result = self.run_bash(r'''
REQUEST[mode]=ee; prepare_settings configure
settings_wizard configure <<'INPUT'


3
4
203.0.113.5
0
1
INPUT
test "$PUBLIC_IPV4" = 203.0.113.5
test "$WIZARD_APPROVED" = 1
''')
        self.success(result)
        self.assertIn("203.0.113.5", result.stdout)
        self.unchanged()

    def test_failed_rollback_recovers_current_configuration(self):
        result = self.run_bash(r'''
set_mode_flags dd; create_backup before >/dev/null
chosen="$LAST_BACKUP_PATH"
upsert_env_key "$DD_ENV_FILE" DD_PORT 8555
cmd_healthcheck() { grep -q '^DD_PORT=8555$' "$DD_ENV_FILE"; }
if cmd_rollback "$chosen"; then exit 99; fi
test "$(read_env_key "$DD_ENV_FILE" DD_PORT)" = 8555
''')
        self.success(result)
        self.assertNotIn("Rollback completed", result.stdout)
        self.assertEqual(len(list(self.backups.glob("*/.complete"))), 2)

    def migration_setup(self):
        return r'''
rm "$DD_ENV_FILE" "$SYSTEMD_UNIT_DIR/$DD_SERVICE_NAME"
set_mode_flags dd
detect_legacy_running_container() { echo legacy-dd; }
docker_binding_ip_by_family() { if [[ "$3" == ipv4 ]]; then echo 0.0.0.0; fi; }
docker_binding_port_by_family() { echo 8443; }
docker_env_value() { echo 00000000000000000000000000000000; }
docker() {
  printf '%s\n' "$*" >> "$TEST_DIR/docker.log"
  if [[ "$1" == inspect ]]; then echo 'telegrammessenger/proxy@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'; fi
}
'''

    def test_migration_preserves_secret_and_keeps_stopped_original(self):
        result = self.run_bash(self.migration_setup() + 'cmd_migrate "" 203.0.113.5 ""')
        self.success(result)
        self.assertIn(f"DD_SECRET={DD_SECRET}", (self.config / "dd.env").read_text())
        commands = self.commands("docker.log")
        self.assertTrue(any(line.startswith("rename legacy-dd telegram-proxy-legacy-dd-") for line in commands))
        self.assertTrue(any(line.startswith("stop telegram-proxy-legacy-dd-") for line in commands))
        self.assertFalse(any(line.startswith("rm ") for line in commands))
        self.assertIn("retained", result.stdout)

    def test_failed_migration_restores_and_restarts_original_container(self):
        result = self.run_bash(self.migration_setup() + r'''
FAIL_RESTART=1
if cmd_migrate "" 203.0.113.5 ""; then exit 99; fi
''')
        self.success(result)
        self.assertFalse((self.config / "dd.env").exists())
        self.assertFalse((self.units / "telegram-proxy-dd.service").exists())
        self.assertEqual((self.config / "ee.env").read_bytes(), self.originals[self.config / "ee.env"])
        commands = self.commands("docker.log")
        self.assertIn("start legacy-dd", commands)
        self.assertTrue(any(line.startswith("rename telegram-proxy-legacy-dd-") and line.endswith(" legacy-dd") for line in commands))
        self.assertNotIn("Migration completed", result.stdout)

    def test_migration_invalid_port_leaves_legacy_container_running(self):
        result = self.run_bash(self.migration_setup() + r'''
docker_binding_port_by_family() { echo 0; }
if cmd_migrate "" 203.0.113.5 ""; then exit 99; fi
''')
        self.success(result)
        self.assertEqual(self.commands("docker.log"), [])
        self.assertFalse(self.backups.exists())

    def test_migration_cannot_overwrite_an_existing_managed_mode(self):
        result = self.run_bash('set_mode_flags dd; cmd_migrate "" 203.0.113.5 ""')
        self.assertEqual(result.returncode, 1)
        self.unchanged()
        self.assertEqual(self.commands("docker.log"), [])

    def test_migration_conflict_with_unselected_mode_is_rejected(self):
        result = self.run_bash(self.migration_setup() + r'''
docker_binding_port_by_family() { echo 443; }
if cmd_migrate "" 203.0.113.5 ""; then exit 99; fi
''')
        self.success(result)
        self.assertFalse(any(line.startswith("rename ") for line in self.commands("docker.log")))
        self.assertFalse(self.backups.exists())

    def test_ipv6_only_binding_does_not_open_an_ipv4_port(self):
        result = self.run_bash(r'''
is_local_bind_ipv6() { return 0; }
REQUEST[mode]=dd; REQUEST[DD_BIND_IP]=''; REQUEST[DD_BIND_IPV6]=2001:db8::5
manager_install configure
''')
        self.success(result)
        unit = (self.units / "telegram-proxy-dd.service").read_text()
        self.assertIn("[2001:db8::5]:8443:443", unit)
        self.assertNotIn("0.0.0.0:8443", unit)

    def test_uninstall_failure_restores_monitor_units(self):
        result = self.run_bash(r'''
printf 'original timer\n' > "$SYSTEMD_UNIT_DIR/$MONITOR_TIMER"
printf 'original monitor\n' > "$SYSTEMD_UNIT_DIR/$MONITOR_SERVICE"
monitor_disable() { rm "$SYSTEMD_UNIT_DIR/$MONITOR_TIMER" "$SYSTEMD_UNIT_DIR/$MONITOR_SERVICE"; return 9; }
set_mode_flags all
if manager_uninstall; then exit 99; fi
''')
        self.success(result)
        self.unchanged()
        self.assertEqual((self.units / "telegram-proxy-monitor.timer").read_text(), "original timer\n")
        self.assertIn("enable --now telegram-proxy-monitor.timer", self.commands("systemctl.log"))

    @unittest.skipUnless(shutil.which("qrencode"), "requires the Ubuntu development image with qrencode")
    def test_real_qrencode_renders_connection_link_offline(self):
        result = self.run_bash('set_mode_flags dd; cmd_links 0 1')
        self.success(result)
        self.assertIn("\x1b[", result.stdout)
        self.assertIn(DD_SECRET, result.stdout)

    @unittest.skipUnless(shutil.which("systemd-analyze") and os.path.exists("/usr/bin/docker"), "requires the Ubuntu development image")
    def test_real_systemd_parser_accepts_proxy_and_monitor_units(self):
        result = self.run_bash(r'''
REQUEST[mode]=all; prepare_settings configure; apply_settings
monitor_enable 5 3 300
systemd-analyze verify --man=no "$SYSTEMD_UNIT_DIR/$EE_SERVICE_NAME" "$SYSTEMD_UNIT_DIR/$DD_SERVICE_NAME" "$SYSTEMD_UNIT_DIR/$MONITOR_SERVICE" "$SYSTEMD_UNIT_DIR/$MONITOR_TIMER"
''')
        self.success(result)
        unit = (self.units / "telegram-proxy-ee.service").read_text()
        self.assertIn('run /config.toml', unit)

    @unittest.skipUnless(os.geteuid() == 0, "preference writes require root")
    def test_real_preference_write_is_private_and_loaded(self):
        result = self.run_bash('UI_LANG=zh; BACKUP_KEEP=7; save_preferences; UI_LANG=en; BACKUP_KEEP=20; load_preferences; test "$UI_LANG:$BACKUP_KEEP" = zh:7')
        self.success(result)
        self.assertEqual(os.stat(self.config / "preferences.env").st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
