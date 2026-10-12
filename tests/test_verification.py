"""Verify deployment results using host mocks and real loopback TCP sockets."""

import socket
import unittest

import test_installer as maintenance


EE_SECRET = "ee" + "1" * 32 + "www.cloudflare.com".encode().hex()


class VerificationTests(unittest.TestCase):
    def setUp(self):
        self.fixture = maintenance.InstallerTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root = self.fixture.root
        self.config = self.fixture.config
        with (self.config / "ee.env").open("a") as file:
            file.write(f"EE_SECRET={EE_SECRET}\nFRONT_DOMAIN=www.cloudflare.com\n")
        for mode in ("ee", "dd"):
            with (self.config / f"{mode}.env").open("a") as file:
                file.write("PUBLIC_IPV4=203.0.113.5\nPUBLIC_IPV6=2001:db8::5\n")
        (self.fixture.mtg / "config.toml").write_text(
            f'secret = "{EE_SECRET}"\nbind-to = "0.0.0.0:3128"\n'
        )
        self.originals = {
            path: path.read_bytes()
            for directory in (self.config, self.fixture.units, self.fixture.mtg)
            for path in directory.iterdir()
        }

    def run_bash(self, body):
        setup = r'''
eval "$REAL_HEALTHCHECK"
REAL_TCP_CONNECT="$(declare -f tcp_connect)"
ASSUME_YES=1 NON_INTERACTIVE=1
FAIL_LOCAL_PORT="" FAIL_ENTRY=0 FAIL_SERVICE=0 FAIL_AUTOSTART=0
BAD_BINDING=0 BAD_IMAGE=0 FAIL_TLS=0
preflight_checks() { return 0; }
bootstrap_installer() { echo bootstrap >> "$TEST_DIR/bootstrap.log"; }
ss() { return 0; }
port_in_use() { return 0; }
get_primary_ipv4() { echo 10.0.0.2; }
get_primary_ipv6() { echo fd00::2; }
resolve_domain_a_records() { echo 203.0.113.5; }
resolve_domain_aaaa_records() { echo 2001:db8::5; }
timeout() {
  printf '%s\n' "$*" >> "$TEST_DIR/timeout.log"
  [[ "$FAIL_TLS" == 0 ]]
}
tcp_connect() {
  printf '%s %s %s\n' "$1" "$2" "${3:-0}" >> "$TEST_DIR/tcp.log"
  if [[ "${3:-0}" != 0 && "$2" == "$FAIL_LOCAL_PORT" ]]; then return 1; fi
  [[ "${3:-0}" != 0 || "$FAIL_ENTRY" == 0 ]]
}
systemctl() {
  printf '%s\n' "$*" >> "$TEST_DIR/systemctl.log"
  if [[ "$1" == is-active && "$FAIL_SERVICE" == 1 ]]; then return 1; fi
  if [[ "$1" == is-enabled && "$FAIL_AUTOSTART" == 1 ]]; then return 1; fi
  if [[ "$1" == show ]]; then echo 0; fi
}
ufw() {
  printf '%s\n' "$*" >> "$TEST_DIR/ufw.log"
  case "$1" in status) echo 'Status: inactive';; show) echo 'ufw allow 22/tcp';; esac
}
sysctl() {
  case "$*" in
    '-n net.ipv4.tcp_congestion_control') echo cubic;;
    '-n net.core.default_qdisc') echo fq_codel;;
    'net.ipv4.tcp_available_congestion_control') echo 'reno cubic bbr';;
  esac
}
docker_binding_ip_by_family() {
  local prefix=EE
  [[ "$1" == "$EE_CONTAINER_NAME" ]] || prefix=DD
  if [[ "$3" == ipv4 ]]; then
    if [[ "$BAD_BINDING" == 1 ]]; then echo 127.0.0.2
    else read_env_key "$(mode_file "${prefix,,}")" "${prefix}_BIND_IP"; fi
  else read_env_key "$(mode_file "${prefix,,}")" "${prefix}_BIND_IPV6"; fi
}
docker_binding_port_by_family() {
  local prefix=EE bind=""
  [[ "$1" == "$EE_CONTAINER_NAME" ]] || prefix=DD
  if [[ "$3" == ipv4 ]]; then bind="${prefix}_BIND_IP"; else bind="${prefix}_BIND_IPV6"; fi
  [[ -n "$(read_env_key "$(mode_file "${prefix,,}")" "$bind")" ]] || return 0
  read_env_key "$(mode_file "${prefix,,}")" "${prefix}_PORT"
}
docker() {
  printf '%s\n' "$*" >> "$TEST_DIR/docker.log"
  case "$1" in
    ps) printf '%s\n' "$EE_CONTAINER_NAME" "$DD_CONTAINER_NAME";;
    inspect)
      if [[ "$*" == *RestartCount* ]]; then echo 0
      elif [[ "$*" == *Config.Image* ]]; then
        if [[ "$BAD_IMAGE" == 1 ]]; then echo unexpected-image
        elif [[ "${@: -1}" == "$EE_CONTAINER_NAME" ]]; then read_env_key "$EE_ENV_FILE" MTG_IMAGE
        else read_env_key "$DD_ENV_FILE" DD_IMAGE; fi
      fi;;
    logs) printf 'token=%s\n' "$EE_SECRET";;
  esac
}
BBR_FILE="$TEST_DIR/bbr.conf"
'''
        return self.fixture.run_bash(setup + "\n" + body)

    def success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_saved_deployment_reports_each_local_check(self):
        result = self.run_bash("set_mode_flags ee; cmd_healthcheck")
        self.success(result)
        for label in ("Saved configuration", "Service running", "Container running",
                      "Running image", "Port publishing", "Local TCP connection"):
            self.assertIn("[PASS] " + label, result.stdout)
        self.assertNotIn(EE_SECRET, result.stdout + result.stderr)
        self.assertEqual(self.fixture.commands("tcp.log"), ["127.0.0.1 443 4"])

    def test_listener_and_docker_mapping_do_not_hide_a_refused_tcp_connection(self):
        result = self.run_bash("FAIL_LOCAL_PORT=443; set_mode_flags ee; cmd_healthcheck")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("[FAIL] Local TCP connection", result.stdout)
        self.assertIn("443", result.stdout)
        self.assertNotIn(EE_SECRET, result.stdout + result.stderr)
        self.assertIn("[REDACTED]", result.stdout)

    def test_dual_stack_checks_both_families_and_canonicalizes_wildcard_ipv6(self):
        result = self.run_bash(r'''
upsert_env_key "$EE_ENV_FILE" EE_BIND_IPV6 0:0:0:0:0:0:0:0
set_mode_flags ee; cmd_healthcheck
''')
        self.success(result)
        self.assertEqual(self.fixture.commands("tcp.log"), ["127.0.0.1 443 4", "::1 443 6"])
        self.assertIn("[PASS] Local TCP connection: IPv6", result.stdout)

    def test_specific_bind_address_is_probed_instead_of_loopback(self):
        result = self.run_bash(r'''
upsert_env_key "$EE_ENV_FILE" EE_BIND_IP 10.0.0.2
set_mode_flags ee; cmd_healthcheck
''')
        self.success(result)
        self.assertEqual(self.fixture.commands("tcp.log"), ["10.0.0.2 443 4"])

    def test_wrong_container_image_fails_even_with_a_working_tcp_port(self):
        result = self.run_bash("BAD_IMAGE=1; set_mode_flags ee; cmd_healthcheck")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("[FAIL] Running image", result.stdout)
        self.assertIn("[PASS] Local TCP connection", result.stdout)

    def test_wrong_bind_address_fails_even_with_a_working_tcp_port(self):
        result = self.run_bash("BAD_BINDING=1; set_mode_flags ee; cmd_healthcheck")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("[FAIL] Port publishing", result.stdout)
        self.assertIn("127.0.0.2", result.stdout)

    def test_mismatched_mtg_configuration_is_not_reported_as_ready(self):
        (self.fixture.mtg / "config.toml").write_text('secret = "wrong"\nbind-to = "0.0.0.0:3128"\n')
        result = self.run_bash("set_mode_flags ee; cmd_healthcheck")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("[FAIL] Saved configuration", result.stdout)

    def test_all_selected_modes_are_checked_after_one_mode_fails(self):
        result = self.run_bash("FAIL_LOCAL_PORT=443; set_mode_flags all; cmd_healthcheck")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("[FAIL] Local TCP connection: IPv4 127.0.0.1:443", result.stdout)
        self.assertIn("[PASS] Local TCP connection: IPv4 127.0.0.1:8443", result.stdout)

    def test_entry_failure_warns_without_rolling_back_a_healthy_local_proxy(self):
        result = self.run_bash("FAIL_ENTRY=1; REQUEST[mode]=ee; manager_install configure")
        self.success(result)
        self.assertIn("[WARNING] Entry TCP connection", result.stdout)
        self.assertIn("Configuration saved with warnings", result.stdout)
        self.assertIn("nc -vz -w 5 ee.example.com 443", result.stdout)
        self.assertEqual(self.fixture.commands("systemctl.log").count("restart telegram-proxy-ee.service"), 1)
        self.assertNotIn("Local checks passed.", result.stdout)

    def test_local_connection_failure_recovers_the_previous_configuration(self):
        result = self.run_bash(r'''
FAIL_LOCAL_PORT=444; REQUEST[mode]=ee; REQUEST[EE_PORT]=444
if manager_install configure; then exit 99; fi
''')
        self.success(result)
        for path, original in self.originals.items():
            self.assertEqual(path.read_bytes(), original, str(path))
        self.assertIn("[FAIL] Local TCP connection", result.stdout)
        self.assertNotIn("Local checks passed.", result.stdout)
        self.assertNotIn("tg://proxy?", result.stdout)

    def test_final_check_catches_a_port_failure_after_startup(self):
        result = self.run_bash(r'''
REQUEST[mode]=ee; REQUEST[EE_PORT]=444
wait_for_healthcheck() { FAIL_LOCAL_PORT=444; return 0; }
if manager_install configure; then exit 99; fi
''')
        self.success(result)
        for path, original in self.originals.items():
            self.assertEqual(path.read_bytes(), original, str(path))
        self.assertIn("Local checks failed", result.stdout)
        self.assertNotIn("tg://proxy?", result.stdout)

    def test_dns_mismatch_and_cover_tls_failure_are_visible_warnings(self):
        result = self.run_bash(r'''
resolve_domain_a_records() { echo 203.0.113.99; }
FAIL_TLS=1; set_mode_flags ee; verify_installation; verification_summary
''')
        self.success(result)
        self.assertIn("[WARNING] Entry DNS A records", result.stdout)
        self.assertIn("[WARNING] HTTPS cover domain TLS", result.stdout)
        self.assertIn("Configuration saved with warnings", result.stdout)

    def test_nat_without_a_known_public_address_does_not_claim_dns_matches(self):
        result = self.run_bash(r'''
upsert_env_key "$EE_ENV_FILE" PUBLIC_IPV4 ""
upsert_env_key "$DD_ENV_FILE" PUBLIC_IPV4 ""
set_mode_flags ee; verify_installation
''')
        self.success(result)
        self.assertIn("[UNVERIFIED] DNS points to this VPS", result.stdout)
        self.assertNotIn("[PASS] DNS points to this VPS", result.stdout)

    def test_local_success_never_claims_external_telegram_connectivity(self):
        result = self.run_bash("set_mode_flags ee; verify_installation; verification_summary")
        self.success(result)
        self.assertIn("[PASS] Entry TCP connection from this VPS", result.stdout)
        self.assertIn("[UNVERIFIED] External access and Telegram connection", result.stdout)
        self.assertIn("Local checks passed. Verify external access", result.stdout)
        self.assertIn("-verify_return_error -verify_hostname www.cloudflare.com", "\n".join(self.fixture.commands("timeout.log")))

    def test_optional_bbr_and_firewall_results_are_checked(self):
        result = self.run_bash(r'''
ENABLE_BBR=yes FIREWALL_POLICY=enable
set_mode_flags dd; verify_installation
test "$CHECK_WARNINGS" -eq 2
''')
        self.success(result)
        self.assertIn("[WARNING] Enable BBR", result.stdout)
        self.assertIn("[WARNING] Firewall", result.stdout)

    def test_numeric_entry_does_not_require_dns(self):
        result = self.run_bash(r'''
upsert_env_key "$DD_ENV_FILE" DD_DOMAIN 203.0.113.5
set_mode_flags dd; verify_installation
''')
        self.success(result)
        self.assertIn("[N/A] Entry DNS A records", result.stdout)
        self.assertNotIn("[WARNING]", result.stdout)

    def test_verification_results_support_all_four_languages(self):
        for language, marker in (("en", "PASS"), ("zh", "通过"), ("ko", "정상"), ("ja", "成功")):
            with self.subTest(language=language):
                result = self.run_bash(f"UI_LANG={language}; set_mode_flags dd; verify_installation; verification_summary")
                self.success(result)
                self.assertIn(f"[{marker}]", result.stdout)
                self.assertNotIn("verify_", result.stdout)

    def test_real_tcp_probe_accepts_an_ipv4_listener_without_using_ss(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            result = self.run_bash(f'eval "$REAL_TCP_CONNECT"; unset -f timeout; tcp_connect 127.0.0.1 {listener.getsockname()[1]} 4')
        self.success(result)

    def test_real_tcp_probe_rejects_a_closed_port(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        result = self.run_bash(f'eval "$REAL_TCP_CONNECT"; unset -f timeout; tcp_connect 127.0.0.1 {port} 4')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_real_tcp_probe_accepts_ipv6_loopback(self):
        try:
            listener = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
            listener.bind(("::1", 0))
        except OSError as error:
            self.skipTest(f"IPv6 loopback unavailable: {error}")
        with listener:
            listener.listen(1)
            result = self.run_bash(f'eval "$REAL_TCP_CONNECT"; unset -f timeout; tcp_connect ::1 {listener.getsockname()[1]} 6')
        self.success(result)
