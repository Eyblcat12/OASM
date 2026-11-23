import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("runtime", Path(__file__).resolve().parents[1] / "manage-runtime.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.base = self.directory / "compose.yaml"
        self.custom = self.directory / "custom.yaml"
        self.env = self.directory / ".env"
        for path in (self.base, self.custom, self.env):
            path.write_text("fixture")
        self.project = "operator-stack"
        self.root = self.directory / ".local/share/ncs-oasm/runtime" / self.project
        self.manifest = {"connectors": [
            {"slug": "nuclei", "configInband": True, "resourceDefaults": {
                "cpu": "500m", "memory": "4096Mi", "timeoutSeconds": 600}},
            {"slug": "other", "resourceDefaults": {"timeoutSeconds": 900}},
        ]}
        self.calls = []
        self.fail_config = False
        self.selected_image = "oasm/oasm-api:v0.13.0"
        self.labels = {
            "com.docker.compose.project": self.project,
            "com.docker.compose.service": "core-api",
            "com.docker.compose.project.working_dir": str(self.directory),
            "com.docker.compose.project.config_files": f"{self.base},{self.custom}",
            "com.docker.compose.project.environment_file": str(self.env),
        }

    def docker(self, *args, capture=True):
        self.calls.append(args)
        if args[0] == "inspect":
            if args[2] == "{{.Config.Image}}":
                return "oasm/oasm-api:v0.13.0"
            return json.dumps(self.labels)
        if args[0] == "cp":
            Path(args[-1]).write_text(json.dumps(self.manifest))
            return ""
        if "config" in args and self.fail_config:
            raise subprocess.CalledProcessError(1, ["docker", *args])
        if "config" in args:
            return json.dumps({"services": {"core-api": {"image": self.selected_image}}})
        if "ps" in args:
            return "new-api"
        return ""

    def run_cli(self, *arguments):
        with patch.object(runtime, "docker", side_effect=self.docker), \
             patch.object(Path, "home", return_value=self.directory), \
             patch.object(sys, "argv", ["manage-runtime.py", *arguments]), \
             contextlib.redirect_stdout(io.StringIO()):
            runtime.main()

    def test_only_timeout_changes(self):
        original = copy.deepcopy(self.manifest)
        runtime.set_timeout(self.manifest, 60)
        original["connectors"][0]["resourceDefaults"]["timeoutSeconds"] = 3600
        self.assertEqual(self.manifest, original)

    def test_duplicate_nuclei_rejected(self):
        self.manifest["connectors"].append(copy.deepcopy(self.manifest["connectors"][0]))
        with self.assertRaises(ValueError):
            runtime.set_timeout(self.manifest, 60)

    def test_check_is_read_only(self):
        self.run_cli("timeout", "60", "--check")
        self.assertFalse(self.root.exists())
        self.assertFalse(any("up" in command for command in self.calls))

    def test_preserves_stack_and_recreates_only_api(self):
        self.run_cli("timeout", "60")
        command = next(command for command in self.calls if "up" in command)
        self.assertIn(str(self.base), command)
        self.assertIn(str(self.custom), command)
        self.assertIn(str(self.env), command)
        self.assertIn(self.project, command)
        self.assertIn("--no-deps", command)
        self.assertEqual(command[-1], "core-api")
        new_manifest = json.loads((self.root / "manifest.json").read_text())
        self.assertEqual(new_manifest["connectors"][0]["resourceDefaults"]["timeoutSeconds"], 3600)
        self.assertEqual(new_manifest["connectors"][1], self.manifest["connectors"][1])
        overlay = json.loads((self.root / "compose.runtime.yaml").read_text())
        self.assertEqual(set(overlay["services"]), {"core-api"})
        self.assertTrue(overlay["services"]["core-api"]["volumes"][0]["read_only"])

    def test_validation_failure_restores_files_without_restart(self):
        self.run_cli("timeout", "60")
        paths = list(self.root.glob("*"))
        before = {path: path.read_text() for path in paths}
        self.calls.clear()
        self.fail_config = True
        with self.assertRaises(ValueError):
            self.run_cli("timeout", "30")
        for path, contents in before.items():
            self.assertEqual(path.read_text(), contents)
        self.assertFalse(any("up" in command for command in self.calls))

    def test_apply_uses_saved_value_and_deduplicates_managed_overlay(self):
        self.run_cli("timeout", "60")
        (self.root / "settings.json").write_text('{"nuclei_timeout_minutes": 45}')
        self.labels["com.docker.compose.project.config_files"] += "," + str(self.root / "compose.runtime.yaml")
        self.calls.clear()
        self.run_cli("apply")
        command = next(command for command in self.calls if "up" in command)
        self.assertEqual(command.count(str(self.root / "compose.runtime.yaml")), 1)
        data = json.loads((self.root / "manifest.json").read_text())
        self.assertEqual(data["connectors"][0]["resourceDefaults"]["timeoutSeconds"], 2700)

    def test_bad_range_rejected_without_restart(self):
        with self.assertRaises(ValueError):
            self.run_cli("timeout", "1")
        self.assertFalse(self.root.exists())
        self.assertFalse(any("up" in command for command in self.calls))

    def test_image_change_rejected_without_restart(self):
        self.selected_image = "oasm/oasm-api:different-release"
        with self.assertRaises(ValueError):
            self.run_cli("timeout", "60")
        self.assertFalse((self.root / "manifest.json").exists())
        self.assertFalse(any("up" in command for command in self.calls))

    def test_rejects_wrong_service_or_missing_files(self):
        self.labels["com.docker.compose.service"] = "results"
        with self.assertRaises(ValueError):
            self.run_cli("timeout", "60")
        self.labels["com.docker.compose.service"] = "core-api"
        self.custom.unlink()
        with self.assertRaises(ValueError):
            self.run_cli("timeout", "60")
        self.assertFalse(self.root.exists())


if __name__ == "__main__":
    unittest.main()
