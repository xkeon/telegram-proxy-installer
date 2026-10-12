"""Version checks use bounded metadata queries and never deploy updates."""

import os
import unittest

import test_installer as maintenance
import test_terminal_ui as terminal


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = maintenance.InstallerTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root = self.fixture.root
        (self.root / "os-release").write_text('ID=ubuntu\nVERSION_ID="24.04"\n')
        (self.root / "meta-release").write_text(
            "Dist: noble\nVersion: 24.04.3 LTS\nDate: Thu, 25 Apr 2024 12:00:00 UTC\nSupported: 1\n\n"
            "Dist: resolute\nVersion: 26.04.1 LTS\nDate: Thu, 23 Apr 2026 12:00:00 UTC\nSupported: 1\n\n"
            "Dist: future\nVersion: 28.04 LTS\nDate: Thu, 20 Apr 2028 12:00:00 UTC\nSupported: 1\n"
        )

    def run_bash(self, body):
        setup = r'''
OS_RELEASE_FILE="$TEST_DIR/os-release"
REGISTRY_DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
REGISTRY_FAIL=0 META_FAIL=0 GIT_FAIL=0 DIRTY=0 APT_FAIL=0 BAD_TOKEN=0
LOCAL_HEAD=1111111111111111111111111111111111111111
REMOTE_HEAD="$LOCAL_HEAD"
curl() {
  printf '%s\n' "$*" >> "$TEST_DIR/curl.log"
  if [[ "$*" == *meta-release-lts* ]]; then
    [[ "$META_FAIL" == 0 ]] || return 22
    cat "$TEST_DIR/meta-release"
  elif [[ "$*" == *auth.docker.io* ]]; then
    [[ "$REGISTRY_FAIL" == 0 ]] || return 22
    if [[ "$BAD_TOKEN" == 1 ]]; then echo '{"token":"bad token"}'
    else echo '{"token":"anonymous.token.value"}'; fi
  elif [[ "$*" == *registry-1.docker.io* ]]; then
    local configuration=""
    configuration="$(cat)"
    [[ "$configuration" == 'header = "Authorization: Bearer anonymous.token.value"' ]] || return 99
    printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: %s\r\n' "$REGISTRY_DIGEST"
  else return 99; fi
}
git() {
  printf '%s\n' "$*" >> "$TEST_DIR/git.log"
  case "$*" in
    *rev-parse*) echo "$LOCAL_HEAD";;
    *ls-remote*) [[ "$GIT_FAIL" == 0 ]] && printf '%s\trefs/heads/main\n' "$REMOTE_HEAD";;
    *status*) if [[ "$DIRTY" == 1 ]]; then echo ' M install.sh'; fi;;
    *) return 99;;
  esac
}
timeout() {
  printf '%s\n' "$*" >> "$TEST_DIR/timeout.log"
  shift
  "$@"
}
apt-get() {
  printf '%s\n' "$*" >> "$TEST_DIR/apt.log"
  [[ "$*" == *update* && "$APT_FAIL" == 0 ]]
}
apt-cache() {
  printf '%s\n' "$*" >> "$TEST_DIR/apt-cache.log"
  case "${@: -1}" in
    git) echo 'Candidate: 2.0';;
    openssl) echo 'Candidate: 1:3.5.0-0ubuntu1';;
    curl) echo 'Candidate: 1.0';;
    *) echo 'Candidate: 2.0';;
  esac
}
dpkg-query() {
  case "${@: -1}" in
    docker-ce | moby-engine | qrencode) return 1;;
    openssl) printf 'install ok installed\t1:3.4.0-0ubuntu1';;
    git) printf 'install ok installed\t1.0';;
    curl) printf 'install ok installed\t3.0';;
    *) if [[ "$*" == *Version* ]]; then printf 'install ok installed\t2.0'
       else printf 'install ok installed'; fi;;
  esac
}
'''
        return self.fixture.run_bash(setup + "\n" + body)

    def success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def rows(self, result):
        return [line.rstrip("\t").split("\t") for line in result.stdout.splitlines() if "\t" in line]

    def fake_workers(self):
        return r'''
version_check_script() { version_row version_script abc def update GitHub/main; }
version_check_ubuntu() { version_row version_ubuntu 26.04 26.04 latest Ubuntu/LTS; }
version_check_image() { version_row "version_$1" abc "" unknown Docker; }
version_check_packages() { version_row @qrencode "" 2.0 missing APT; }
'''

    def test_registry_checks_digest_without_pulling_or_restarting(self):
        result = self.run_bash("version_check_image ee")
        self.success(result)
        self.assertEqual(self.rows(result)[0][3], "latest")
        self.assertEqual(self.fixture.commands("systemctl.log"), [])
        self.assertFalse(any(line.startswith("pull") for line in self.fixture.commands("docker.log")))
        calls = "\n".join(self.fixture.commands("curl.log"))
        self.assertNotIn("anonymous.token.value", calls + result.stdout + result.stderr)
        self.assertIn("--max-time 3", calls)

    def test_digest_change_reports_an_update(self):
        result = self.run_bash('REGISTRY_DIGEST="sha256:' + "b" * 64 + '"; version_check_image ee')
        self.success(result)
        self.assertEqual(self.rows(result)[0][3], "update")

    def test_proxy_without_saved_configuration_is_not_reported_as_installed_latest(self):
        result = self.run_bash(r'''
rm "$EE_ENV_FILE"
MTG_IMAGE="nineseconds/mtg@$REGISTRY_DIGEST"
version_check_image ee
''')
        self.success(result)
        row = self.rows(result)[0]
        self.assertEqual(row[3], "missing")
        self.assertEqual(row[1], "Not installed")

    def test_running_container_version_takes_precedence_over_a_newer_configured_pin(self):
        result = self.run_bash(r'''
REGISTRY_DIGEST="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
upsert_env_key "$EE_ENV_FILE" MTG_IMAGE "nineseconds/mtg@$REGISTRY_DIGEST"
docker() {
  if [[ "$*" == *State.Running* ]]; then echo true
  elif [[ "$*" == *Config.Image* ]]; then echo "nineseconds/mtg@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; fi
}
version_check_image ee
''')
        self.success(result)
        row = self.rows(result)[0]
        self.assertEqual(row[3], "update")
        self.assertIn("sha256:aaaaaaaaaaaa", row[1])

    def test_registry_failure_is_unconfirmed_instead_of_latest(self):
        result = self.run_bash("REGISTRY_FAIL=1; version_check_image ee")
        self.success(result)
        row = self.rows(result)[0]
        self.assertEqual(row[3], "unknown")
        self.assertEqual(row[2], "-")

    def test_invalid_auth_token_is_rejected_before_manifest_request(self):
        result = self.run_bash("BAD_TOKEN=1; version_check_image ee")
        self.success(result)
        self.assertEqual(self.rows(result)[0][3], "unknown")
        self.assertEqual(len(self.fixture.commands("curl.log")), 1)

    def test_custom_images_are_not_compared_to_an_unrelated_official_image(self):
        result = self.run_bash(r'''
upsert_env_key "$EE_ENV_FILE" MTG_IMAGE "example/custom@$REGISTRY_DIGEST"
version_check_image ee
''')
        self.success(result)
        self.assertEqual(self.rows(result)[0][3], "unknown")
        self.assertEqual(self.fixture.commands("curl.log"), [])

    def test_official_image_with_docker_io_prefix_compares_full_digest(self):
        result = self.run_bash(r'''
upsert_env_key "$EE_ENV_FILE" MTG_IMAGE "docker.io/nineseconds/mtg@$REGISTRY_DIGEST"
version_check_image ee
''')
        self.success(result)
        self.assertEqual(self.rows(result)[0][3], "latest")

    def test_ubuntu_uses_supported_released_lts_and_ignores_future_release(self):
        result = self.run_bash("version_check_ubuntu")
        self.success(result)
        row = self.rows(result)[0]
        self.assertEqual(row[1:4], ["24.04", "26.04.1", "update"])

    def test_ubuntu_point_release_is_compared_instead_of_only_version_id(self):
        (self.root / "os-release").write_text('ID=ubuntu\nVERSION_ID="26.04"\nVERSION="26.04.1 LTS (Resolute Raccoon)"\n')
        result = self.run_bash("version_check_ubuntu")
        self.success(result)
        self.assertEqual(self.rows(result)[0][1:4], ["26.04.1", "26.04.1", "latest"])
        (self.root / "os-release").write_text('ID=ubuntu\nVERSION_ID="26.04"\nVERSION="26.04 LTS (Resolute Raccoon)"\n')
        result = self.run_bash("version_check_ubuntu")
        self.success(result)
        self.assertEqual(self.rows(result)[0][3], "update")

    def test_newer_non_lts_ubuntu_is_not_recommended_for_downgrade(self):
        (self.root / "os-release").write_text("ID=ubuntu\nVERSION_ID=26.10\n")
        result = self.run_bash("version_check_ubuntu")
        self.success(result)
        self.assertEqual(self.rows(result)[0][3], "newer")

    def test_ubuntu_source_failure_is_explicit(self):
        result = self.run_bash("META_FAIL=1; version_check_ubuntu")
        self.success(result)
        self.assertEqual(self.rows(result)[0][3], "unknown")

    def test_non_ubuntu_hosts_skip_the_ubuntu_release_comparison(self):
        (self.root / "os-release").write_text("ID=debian\nVERSION_ID=13\n")
        result = self.run_bash("version_check_ubuntu")
        self.success(result)
        self.assertEqual(self.rows(result)[0][3], "skip")
        self.assertEqual(self.fixture.commands("curl.log"), [])

    def test_script_queries_main_without_fetching_or_changing_checkout(self):
        result = self.run_bash("version_check_script")
        self.success(result)
        self.assertEqual(self.rows(result)[0][3], "latest")
        calls = self.fixture.commands("git.log")
        self.assertTrue(any("safe.directory=" in call for call in calls))
        self.assertFalse(any(" pull " in call or " fetch " in call or " reset " in call for call in calls))

    def test_script_remote_difference_and_local_changes_are_visible(self):
        result = self.run_bash("DIRTY=1; version_check_script")
        self.success(result)
        row = self.rows(result)[0]
        self.assertEqual(row[3], "update")
        self.assertIn("local changes", row[1])
        result = self.run_bash('REMOTE_HEAD="' + "2" * 40 + '"; version_check_script')
        self.success(result)
        self.assertEqual(self.rows(result)[0][3], "update")

    def test_git_failure_does_not_report_latest(self):
        result = self.run_bash("GIT_FAIL=1; version_check_script")
        self.success(result)
        self.assertEqual(self.rows(result)[0][3], "unknown")

    def test_package_comparison_handles_epochs_newer_versions_and_missing_packages(self):
        result = self.run_bash("version_packages_from_index 1")
        self.success(result)
        rows = {row[0]: row for row in self.rows(result)}
        self.assertEqual(rows["@git"][3], "update")
        self.assertEqual(rows["@openssl"][3], "update")
        self.assertEqual(rows["@curl"][3], "newer")
        self.assertEqual(rows["@qrencode"][3], "missing")
        self.assertEqual(rows["@python3"][3], "latest")
        self.assertEqual(rows["@docker.io"][3], "latest")
        self.assertEqual(self.fixture.commands("apt.log"), [])

    def test_stale_apt_indexes_are_never_reported_as_latest(self):
        result = self.run_bash("version_packages_from_index 0")
        self.success(result)
        for row in self.rows(result):
            self.assertEqual(row[3], "unknown")
            self.assertEqual(row[2], "-")
        self.assertEqual(self.fixture.commands("apt-cache.log"), [])

    def test_failed_apt_refresh_uses_unknown_and_does_not_install_packages(self):
        result = self.run_bash("APT_FAIL=1; version_check_packages")
        self.success(result)
        self.assertTrue(all(row[3] == "unknown" for row in self.rows(result)))
        calls = self.fixture.commands("apt.log")
        if os.geteuid() == 0:
            self.assertEqual(len(calls), 1)
            self.assertIn("APT::Update::Error-Mode=any", calls[0])
        self.assertFalse(any("install" in call or "upgrade" in call for call in calls))

    def test_parallel_collector_counts_updates_unknowns_and_missing_components(self):
        result = self.run_bash(self.fake_workers() + r'''
version_check_run
test "$VERSION_CHECKED" -eq 1
test "$VERSION_UPDATES" -eq 1
test "$VERSION_UNKNOWN" -eq 2
test "$VERSION_MISSING" -eq 1
test "${#VERSION_ROWS[@]}" -eq 5
''')
        self.success(result)

    def test_failed_worker_is_represented_as_unconfirmed(self):
        result = self.run_bash(self.fake_workers() + r'''
version_check_script() { return 1; }
version_check_run
test "$VERSION_UNKNOWN" -eq 3
test "${#VERSION_ROWS[@]}" -eq 5
''')
        self.success(result)

    def test_collector_runs_independent_queries_in_parallel(self):
        result = self.run_bash(r'''
barrier() {
  local attempt=0
  local -a ready=()
  touch "$TEST_DIR/ready-$1"
  for ((attempt=0; attempt<100; attempt++)); do
    ready=("$TEST_DIR"/ready-*)
    if ((${#ready[@]} == 5)); then version_row "$1" a a latest fixture; return 0; fi
    command sleep 0.02
  done
  return 1
}
version_check_script() { barrier version_script; }
version_check_ubuntu() { barrier version_ubuntu; }
version_check_image() { barrier "version_$1"; }
version_check_packages() { barrier @git; }
version_check_run
test "$VERSION_UNKNOWN" -eq 0
test "${#VERSION_ROWS[@]}" -eq 5
''')
        self.success(result)

    def test_menu_checks_versions_once_before_showing_home(self):
        result = self.run_bash(self.fake_workers() + r'''
version_check_script() { echo checked >> "$TEST_DIR/check-count"; version_row version_script a a latest Git; }
load_preferences() { UI_LANG=zh; return 0; }
manager_menu <<'INPUT'
6
0
0
INPUT
''')
        self.success(result)
        self.assertEqual((self.root / "check-count").read_text(), "checked\n")
        self.assertIn("版本检查", result.stdout)
        self.assertEqual(self.fixture.commands("apt.log"), [])

    def test_offline_checks_do_not_block_menu_exit(self):
        result = self.run_bash(r'''
version_check_script() { return 1; }
version_check_ubuntu() { return 1; }
version_check_image() { return 1; }
version_check_packages() { return 1; }
load_preferences() { UI_LANG=zh; return 0; }
manager_menu <<<'0'
''')
        self.success(result)
        self.assertIn("5 项未确认", result.stdout)

    def test_versions_cli_supports_every_language_and_requires_no_installation(self):
        for language, text in (("en", "Version check"), ("zh", "版本检查"), ("ko", "버전 점검"), ("ja", "バージョン点検")):
            with self.subTest(language=language):
                result = self.run_bash(self.fake_workers() + f"main versions --lang {language}")
                self.success(result)
                self.assertIn(text, result.stdout)
                self.assertNotIn("version_state_", result.stdout)
                self.assertEqual(self.fixture.commands("systemctl.log"), [])
                self.assertEqual(self.fixture.commands("docker.log"), [])

    def test_version_badge_fits_common_and_small_terminals(self):
        fixture = terminal.TerminalUITests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        for rows, cols in ((24, 80), (22, 80), (18, 40)):
            with self.subTest(rows=rows, cols=cols):
                code, output = fixture.run_terminal(
                    "UI_LANG=zh; VERSION_CHECKED=1; VERSION_UPDATES=2; VERSION_UNKNOWN=1\n" + terminal.SELECT_MENU,
                    "q", rows=rows, cols=cols,
                )
                self.assertEqual(code, 0, output)
                frame = terminal.ANSI.sub("", output.split("\x1b[H\x1b[2J")[1]).replace("\r", "").split("\nselected=")[0]
                self.assertLessEqual(len(frame.splitlines()), rows)
