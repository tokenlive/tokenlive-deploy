"""Deployment version contracts; real Compose config only, never a Docker daemon."""

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG_KEYS = (
    "REGISTRY VERSION ADMIN_VERSION GATEWAY_VERSION BUILD_KIND "
    "ADMIN_BUILD_VERSION GATEWAY_BUILD_VERSION ADMIN_BUILD_KIND GATEWAY_BUILD_KIND "
    "RELEASE_TAG ADMIN_RELEASE_TAG GATEWAY_RELEASE_TAG "
    "ADMIN_DIR GATEWAY_DIR IMAGE_SOURCE DOMAIN HTTP_PORT HTTPS_PORT ADMIN_PASSWORD "
    "DB_TYPE DB_DSN STORAGE_CACHE_TYPE PROMETHEUS_SERVER_URL GATEWAY_SYNC_TOKEN "
    "REDIS_ADDR REDIS_PASSWORD REDIS_DB GATEWAY_CONFIG_SOURCE GATEWAY_STATE_STORE "
    "CLICKHOUSE_ENABLED CLICKHOUSE_ADDR CLICKHOUSE_DATABASE CLICKHOUSE_USERNAME "
    "CLICKHOUSE_PASSWORD UPDATE_CHECK_ENABLED UPDATE_CHECK_INTERVAL_SECONDS "
    "GATEWAY_VERSION_NAMESPACE"
).split()


def clean_env():
    return {
        key: value
        for key, value in os.environ.items()
        if key not in CONFIG_KEYS
        and not key.startswith(("TL_", "COMPOSE_", "DOCKER_"))
    }


class ComposeVersionsTest(unittest.TestCase):
    def compose(self, values, build=False, images=False):
        with tempfile.TemporaryDirectory() as directory:
            env_file = pathlib.Path(directory) / "test.env"
            env_file.write_text(values, encoding="utf-8")
            command = [
                "docker", "compose", "--env-file", str(env_file),
                "-f", str(ROOT / "docker-compose.yml"),
            ]
            if build:
                command += ["-f", str(ROOT / "docker-compose.build.yml")]
            command += ["config", "--images"] if images else ["config", "--format", "json"]
            result = subprocess.check_output(command, cwd=ROOT, env=clean_env(), text=True)
            return result if images else json.loads(result)["services"]

    def test_component_versions(self):
        for build in (False, True):
            with self.subTest(build=build):
                images = self.compose(
                    "VERSION=v1.0.0\nADMIN_VERSION=v1.1.0\nGATEWAY_VERSION=v1.2.0\n",
                    build=build, images=True,
                )
                self.assertIn("ghcr.io/tokenlive/tokenlive-admin:v1.1.0", images)
                self.assertIn("ghcr.io/tokenlive/tokenlive-gateway:v1.2.0", images)

    def test_legacy_default_and_single_component_fallbacks(self):
        cases = (
            ("VERSION=v1.0.0\n", "v1.0.0", "v1.0.0"),
            ("", "latest", "latest"),
            ("VERSION=\nADMIN_VERSION=\nGATEWAY_VERSION=\n", "latest", "latest"),
            ("VERSION=v1.0.0\nADMIN_VERSION=v1.1.0\n", "v1.1.0", "v1.0.0"),
            ("VERSION=v1.0.0\nGATEWAY_VERSION=v1.2.0\n", "v1.0.0", "v1.2.0"),
        )
        for build in (False, True):
            for values, admin, gateway in cases:
                with self.subTest(build=build, values=values):
                    images = self.compose(values, build=build, images=True)
                    self.assertIn(f"ghcr.io/tokenlive/tokenlive-admin:{admin}", images)
                    self.assertIn(f"ghcr.io/tokenlive/tokenlive-gateway:{gateway}", images)

    def test_update_configuration_defaults(self):
        services = self.compose("")
        admin = services["admin"]["environment"]
        self.assertEqual(admin.get("UPDATE_CHECK_ENABLED"), "true")
        self.assertEqual(admin.get("UPDATE_CHECK_INTERVAL_SECONDS"), "21600")
        self.assertEqual(admin.get("GATEWAY_VERSION_NAMESPACE"), "default")
        self.assertEqual(services["gateway"]["environment"].get("GATEWAY_VERSION_NAMESPACE"), "default")

    def test_update_configuration_overrides(self):
        services = self.compose(
            "UPDATE_CHECK_ENABLED=false\nUPDATE_CHECK_INTERVAL_SECONDS=900\n"
            "GATEWAY_VERSION_NAMESPACE=isolated-deployment\n"
        )
        admin = services["admin"]["environment"]
        self.assertEqual(admin.get("UPDATE_CHECK_ENABLED"), "false")
        self.assertEqual(admin.get("UPDATE_CHECK_INTERVAL_SECONDS"), "900")
        self.assertEqual(admin.get("GATEWAY_VERSION_NAMESPACE"), "isolated-deployment")
        self.assertEqual(
            services["gateway"]["environment"].get("GATEWAY_VERSION_NAMESPACE"),
            "isolated-deployment",
        )

    def test_compose_local_build_defaults_to_dev_even_with_versioned_tags(self):
        for values in ("", "VERSION=latest\n", "VERSION=v1.0.0\n", "VERSION=edge\n"):
            with self.subTest(values=values):
                services = self.compose(values, build=True)
                for component in ("admin", "gateway"):
                    args = services[component]["build"].get("args", {})
                    self.assertEqual(args.get("VERSION"), "dev")
                    self.assertEqual(args.get("BUILD_KIND"), "dev")

    def test_compose_explicit_runtime_metadata_is_independent_of_image_tags(self):
        services = self.compose(
            "ADMIN_VERSION=admin-edge\nGATEWAY_VERSION=gateway-edge\n"
            "ADMIN_BUILD_VERSION=v1.1.0\nGATEWAY_BUILD_VERSION=v1.2.0\n"
            "BUILD_KIND=release\nGATEWAY_BUILD_KIND=dev\n",
            build=True,
        )
        self.assertEqual(services["admin"]["image"], "ghcr.io/tokenlive/tokenlive-admin:admin-edge")
        self.assertEqual(services["gateway"]["image"], "ghcr.io/tokenlive/tokenlive-gateway:gateway-edge")
        self.assertEqual(services["admin"]["build"].get("args", {}).get("VERSION"), "v1.1.0")
        self.assertEqual(services["gateway"]["build"].get("args", {}).get("VERSION"), "v1.2.0")
        self.assertEqual(services["admin"]["build"].get("args", {}).get("BUILD_KIND"), "release")
        self.assertEqual(services["gateway"]["build"].get("args", {}).get("BUILD_KIND"), "dev")


class ScriptVersionsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = pathlib.Path(self.temporary.name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.log = self.directory / "docker.jsonl"
        # Only the strict read-only config allowlist can reach the real CLI.
        # Every Docker mutation is recorded and swallowed at this boundary.
        docker = self.bin / "docker"
        docker.write_text(
            f"#!{sys.executable}\n"
            "import json, os, subprocess, sys\n"
            "with open(os.environ['TEST_DOCKER_LOG'], 'a') as log:\n"
            "    log.write(json.dumps({'argv': sys.argv[1:], 'env': {\n"
            "        key: os.environ.get(key) for key in "
            "['REGISTRY', 'VERSION', 'ADMIN_VERSION', 'GATEWAY_VERSION']}}) + '\\n')\n"
            "args = sys.argv[1:]\n"
            "if args and args[0] == 'compose':\n"
            "    index = 1\n"
            "    while index < len(args) and args[index] in ('-f', '--profile', '--env-file'):\n"
            "        index += 2\n"
            "    if args[index:] in (['config', '--environment'], ['config', '--images', 'admin', 'gateway']):\n"
            "        if os.environ.get('TEST_CONFIG_FAIL'):\n"
            "            sys.exit(2)\n"
            "        if os.environ.get('TEST_CONFIG_EMPTY'):\n"
            "            sys.exit(0)\n"
            f"        sys.exit(subprocess.call([{shutil.which('docker')!r}, *args]))\n",
            encoding="utf-8",
        )
        docker.chmod(0o755)
        self.env = clean_env()
        self.env.update(PATH=f"{self.bin}{os.pathsep}{self.env['PATH']}", TEST_DOCKER_LOG=str(self.log))
        for component in ("admin", "gateway"):
            project = self.directory / component
            (project / "deploy/build").mkdir(parents=True)
            (project / "deploy/build/Dockerfile").touch()
            self.env[f"{component.upper()}_DIR"] = str(project)
        self.install_dir = self.directory / "install"
        self.install_dir.mkdir()
        for filename in ("docker-compose.yml", "docker-compose.build.yml"):
            shutil.copyfile(ROOT / filename, self.install_dir / filename)

    def run_script(self, script, arguments, values=None, success=True):
        env = self.env.copy()
        env.update(values or {})
        result = subprocess.run(
            ["bash", str(ROOT / script), *arguments], cwd=self.install_dir,
            env=env, text=True, capture_output=True, timeout=10,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def builds(self, calls):
        return [call["argv"] for call in calls if call["argv"][0] == "build"]

    def assert_build(self, command, image, version, kind="dev"):
        self.assertEqual(command[command.index("-t") + 1], image)
        args = [command[index + 1] for index, value in enumerate(command) if value == "--build-arg"]
        self.assertIn(f"VERSION={version}", args)
        self.assertIn(f"BUILD_KIND={kind}", args)

    def test_build_component_flags_control_build_and_push(self):
        calls = self.run_script("build-images.sh", [
            "--version", "v1.0.0", "--admin-version", "v1.1.0",
            "--gateway-version", "v1.2.0", "--registry", "registry.example/team", "--push",
        ])
        builds = self.builds(calls)
        self.assertEqual(len(builds), 2)
        self.assert_build(builds[0], "registry.example/team/tokenlive-admin:v1.1.0", "dev")
        self.assert_build(builds[1], "registry.example/team/tokenlive-gateway:v1.2.0", "dev")
        self.assertIn(["push", "registry.example/team/tokenlive-admin:v1.1.0"], [c["argv"] for c in calls])
        self.assertIn(["push", "registry.example/team/tokenlive-gateway:v1.2.0"], [c["argv"] for c in calls])

    def test_build_component_environment_beats_legacy_flag(self):
        calls = self.run_script(
            "build-images.sh", ["--version", "v1.0.0"],
            {"ADMIN_VERSION": "v1.1.0", "GATEWAY_VERSION": "v1.2.0"},
        )
        builds = self.builds(calls)
        self.assert_build(builds[0], "ghcr.io/tokenlive/tokenlive-admin:v1.1.0", "dev")
        self.assert_build(builds[1], "ghcr.io/tokenlive/tokenlive-gateway:v1.2.0", "dev")

    def test_build_single_override_leaves_other_component_on_legacy_version(self):
        calls = self.run_script(
            "build-images.sh", ["--admin-version", "v1.3.0"],
            {"VERSION": "v1.0.0", "ADMIN_VERSION": "v1.1.0"},
        )
        builds = self.builds(calls)
        self.assert_build(builds[0], "ghcr.io/tokenlive/tokenlive-admin:v1.3.0", "dev")
        self.assert_build(builds[1], "ghcr.io/tokenlive/tokenlive-gateway:v1.0.0", "dev")

    def test_build_single_component_keeps_legacy_version(self):
        calls = self.run_script("build-images.sh", ["--gateway", "--version", "v1.0.0", "--push"])
        builds = self.builds(calls)
        self.assertEqual(len(builds), 1)
        self.assert_build(builds[0], "ghcr.io/tokenlive/tokenlive-gateway:v1.0.0", "dev")
        self.assertEqual([c["argv"] for c in calls if c["argv"][0] == "push"],
                         [["push", "ghcr.io/tokenlive/tokenlive-gateway:v1.0.0"]])

    def test_build_aliases_never_become_runtime_versions(self):
        for values, expected in (
            ({}, "latest"),
            ({"VERSION": "latest"}, "latest"),
            ({"VERSION": "edge"}, "edge"),
        ):
            with self.subTest(values=values):
                self.log.unlink(missing_ok=True)
                calls = self.run_script("build-images.sh", [], values)
                builds = self.builds(calls)
                self.assert_build(builds[0], f"ghcr.io/tokenlive/tokenlive-admin:{expected}", "dev")
                self.assert_build(builds[1], f"ghcr.io/tokenlive/tokenlive-gateway:{expected}", "dev")

    def test_build_runtime_metadata_and_release_kind_are_explicit(self):
        calls = self.run_script(
            "build-images.sh", ["--admin-version", "admin-edge", "--gateway-version", "gateway-edge"],
            {
                "ADMIN_BUILD_VERSION": "v1.1.0", "GATEWAY_BUILD_VERSION": "v1.2.0",
                "BUILD_KIND": "release", "GATEWAY_BUILD_KIND": "dev",
            },
        )
        builds = self.builds(calls)
        self.assert_build(builds[0], "ghcr.io/tokenlive/tokenlive-admin:admin-edge", "v1.1.0", "release")
        self.assert_build(builds[1], "ghcr.io/tokenlive/tokenlive-gateway:gateway-edge", "v1.2.0", "dev")

    def test_install_component_flags_write_selected_versions(self):
        self.run_script("install.sh", [
            "--yes", "--no-start", "--version", "v1.0.0",
            "--admin-version", "v1.1.0", "--gateway-version", "v1.2.0",
        ])
        values = (self.install_dir / ".env").read_text()
        self.assertIn("VERSION=v1.0.0\n", values)
        self.assertIn("ADMIN_VERSION=v1.1.0\n", values)
        self.assertIn("GATEWAY_VERSION=v1.2.0\n", values)

    def test_install_prefixed_environment_and_flag_precedence(self):
        self.run_script(
            "install.sh", ["--yes", "--no-start", "--admin-version", "v1.3.0"],
            {"TL_VERSION": "v1.0.0", "TL_ADMIN_VERSION": "v1.1.0", "TL_GATEWAY_VERSION": "v1.2.0"},
        )
        values = (self.install_dir / ".env").read_text()
        self.assertIn("VERSION=v1.0.0\n", values)
        self.assertIn("ADMIN_VERSION=v1.3.0\n", values)
        self.assertIn("GATEWAY_VERSION=v1.2.0\n", values)

    def test_install_plain_environment_selects_component_versions(self):
        self.run_script(
            "install.sh", ["--yes", "--no-start"],
            {"VERSION": "v1.0.0", "ADMIN_VERSION": "v1.1.0", "GATEWAY_VERSION": "v1.2.0"},
        )
        values = (self.install_dir / ".env").read_text()
        self.assertIn("VERSION=v1.0.0\n", values)
        self.assertIn("ADMIN_VERSION=v1.1.0\n", values)
        self.assertIn("GATEWAY_VERSION=v1.2.0\n", values)

    def test_upgrade_preserves_config_and_uses_component_images(self):
        contents = (
            "# existing installation\nIMAGE_SOURCE=remote\nREGISTRY=registry.example/team\n"
            "VERSION=v1.0.0\nADMIN_VERSION=v1.1.0\nGATEWAY_VERSION=v1.2.0\n"
            "ADMIN_PASSWORD=fixture-only\nCUSTOM_SETTING=untouched\n"
            "UPDATE_CHECK_ENABLED=false\nGATEWAY_VERSION_NAMESPACE=existing\n"
        )
        (self.install_dir / ".env").write_text(contents)
        calls = self.run_script("install.sh", ["--upgrade", "--yes"])
        self.assertEqual((self.install_dir / ".env").read_text(), contents)
        removals = [call["argv"][1:] for call in calls if call["argv"][0] == "rmi"]
        self.assertEqual(len(removals), 1)
        self.assertCountEqual(
            removals[0],
            ["registry.example/team/tokenlive-gateway:v1.2.0",
             "registry.example/team/tokenlive-admin:v1.1.0"],
        )

    def test_install_preserves_existing_quoted_image_fields(self):
        (self.install_dir / ".env").write_text(
            "REGISTRY='registry.example/team'\nVERSION=\"v1.0.0\"\n"
            "ADMIN_VERSION='v1.1.0'\nGATEWAY_VERSION=\"v1.2.0\"\n"
        )
        self.run_script("install.sh", ["--yes", "--no-start", "--gateway-version", "v1.4.0"])
        values = (self.install_dir / ".env").read_text()
        self.assertIn("REGISTRY=registry.example/team\n", values)
        self.assertIn("\nVERSION=v1.0.0\n", values)
        self.assertIn("ADMIN_VERSION=v1.1.0\n", values)
        self.assertIn("GATEWAY_VERSION=v1.4.0\n", values)

    def test_install_default_and_empty_override_keep_fallbacks(self):
        self.run_script("install.sh", ["--yes", "--no-start"])
        values = (self.install_dir / ".env").read_text()
        self.assertIn("\nVERSION=latest\n", values)
        self.assertIn("ADMIN_VERSION=\n", values)
        self.assertIn("GATEWAY_VERSION=\n", values)
        (self.install_dir / ".env").write_text("VERSION=v1.0.0\nADMIN_VERSION=v1.1.0\n")
        self.run_script("install.sh", [
            "--yes", "--no-start", "--version", "v2.0.0", "--admin-version", "",
        ])
        values = (self.install_dir / ".env").read_text()
        self.assertIn("\nVERSION=v2.0.0\n", values)
        self.assertIn("ADMIN_VERSION=\n", values)

    def test_install_config_resolution_failure_preserves_existing_file(self):
        contents = "VERSION=v1.0.0\nADMIN_VERSION=v1.1.0\n"
        (self.install_dir / ".env").write_text(contents)
        self.run_script(
            "install.sh", ["--yes", "--no-start"], {"TEST_CONFIG_FAIL": "1"}, success=False,
        )
        self.assertEqual((self.install_dir / ".env").read_text(), contents)

    def test_deploy_pull_and_up_share_selected_versions_and_profile(self):
        calls = self.run_script("install.sh", [
            "--yes", "--redis", "--version", "v1.0.0", "--admin-version", "v1.1.0",
        ])
        prefix = ["compose", "--profile", "with-redis", "-f", "docker-compose.yml"]
        for operation in (["pull"], ["up", "-d"]):
            call = next(call for call in calls if call["argv"] == prefix + operation)
            self.assertEqual(call["env"]["VERSION"], "v1.0.0")
            self.assertEqual(call["env"]["ADMIN_VERSION"], "v1.1.0")
        self.assertFalse(any(call["argv"][0] == "rmi" for call in calls))

    def test_upgrade_transient_override_matches_compose_files_profile_and_images(self):
        contents = (
            "IMAGE_SOURCE=remote\nREGISTRY='registry.example/team'\nVERSION=\"v1.0.0\"\n"
            "ADMIN_VERSION='v1.1.0'\nREDIS_ADDR=redis:6379\nCUSTOM_SETTING=untouched\n"
        )
        (self.install_dir / ".env").write_text(contents)
        calls = self.run_script(
            "install.sh",
            ["--upgrade", "--yes", "--version", "v2.0.0", "--gateway-version", "v2.2.0"],
        )
        self.assertEqual((self.install_dir / ".env").read_text(), contents)
        removals = [call["argv"][1:] for call in calls if call["argv"][0] == "rmi"]
        self.assertEqual(len(removals), 1)
        self.assertCountEqual(
            removals[0],
            ["registry.example/team/tokenlive-admin:v1.1.0",
             "registry.example/team/tokenlive-gateway:v2.2.0"],
        )
        prefix = ["compose", "--profile", "with-redis", "-f", "docker-compose.yml"]
        for operation in (["config", "--images", "admin", "gateway"], ["pull"], ["up", "-d"]):
            call = next(call for call in calls if call["argv"] == prefix + operation)
            self.assertEqual(call["env"]["VERSION"], "v2.0.0")
            self.assertEqual(call["env"]["GATEWAY_VERSION"], "v2.2.0")
            self.assertIsNone(call["env"]["ADMIN_VERSION"])

    def test_upgrade_keeps_legacy_version_fallback(self):
        (self.install_dir / ".env").write_text("VERSION=v1.0.0\n")
        calls = self.run_script("install.sh", ["--upgrade", "--yes", "--version", "v2.0.0"])
        removals = [call["argv"][1:] for call in calls if call["argv"][0] == "rmi"]
        self.assertEqual(len(removals), 1)
        self.assertCountEqual(removals[0], [
            "ghcr.io/tokenlive/tokenlive-admin:v2.0.0",
            "ghcr.io/tokenlive/tokenlive-gateway:v2.0.0",
        ])

    def test_local_upgrade_uses_both_compose_files_and_component_override(self):
        contents = "IMAGE_SOURCE=local\nREDIS_ADDR=redis:6379\nVERSION=v1.0.0\n"
        (self.install_dir / ".env").write_text(contents)
        calls = self.run_script(
            "install.sh", ["--upgrade", "--yes"], {"TL_GATEWAY_VERSION": "v1.2.0"},
        )
        prefix = [
            "compose", "--profile", "with-redis", "-f", "docker-compose.yml",
            "-f", "docker-compose.build.yml",
        ]
        for operation in (["down"], ["down", "--rmi", "local"], ["up", "-d", "--build"]):
            call = next(call for call in calls if call["argv"] == prefix + operation)
            self.assertEqual(call["env"]["GATEWAY_VERSION"], "v1.2.0")
        self.assertEqual((self.install_dir / ".env").read_text(), contents)
        self.assertFalse(any("pull" in call["argv"] or call["argv"][0] == "rmi" for call in calls))

    def test_upgrade_resolution_failure_does_not_stop_or_remove_images(self):
        for values in ({"TEST_CONFIG_FAIL": "1"}, {"TEST_CONFIG_EMPTY": "1"}):
            with self.subTest(values=values):
                self.log.unlink(missing_ok=True)
                (self.install_dir / ".env").write_text("VERSION=v1.0.0\n")
                calls = self.run_script("install.sh", ["--upgrade", "--yes"], values, success=False)
                for call in calls:
                    self.assertNotIn(call["argv"][0], ("rmi", "pull", "up"))
                    self.assertTrue(set(call["argv"]).isdisjoint(("down", "pull", "up")))


if __name__ == "__main__":
    unittest.main()
