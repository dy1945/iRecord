#!/usr/bin/env python3
"""Exercise the installer with isolated, signed fixtures; never touch real iRecord."""

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import unittest
import uuid


INSTALLER = Path(__file__).with_name("install_app.sh")


class InstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("codesign") or not shutil.which("cc"):
            raise unittest.SkipTest("Requires macOS codesign and a C compiler")
        cls.build = tempfile.TemporaryDirectory(prefix="irecord-installer-build-")
        build = Path(cls.build.name)
        source = build / "wait.c"
        source.write_text("#include <unistd.h>\nint main(void) { for (;;) sleep(1); }\n")
        cls.executable = build / "iRecordFixture"
        subprocess.run(["cc", str(source), "-o", str(cls.executable)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="irecord-installer-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "source").mkdir()
        (self.root / "applications").mkdir()
        self.source = self.root / "source" / "iRecord.app"
        self.destination = self.root / "applications" / "iRecord.app"
        self.addCleanup(self.unregister_fixture)
        self.log = self.root / "cli-install.json"
        self.environment = dict(os.environ, IRECORD_INSTALL_TEST_LOG=str(self.log))
        self.make_bundle(self.source, "new")
        self.make_bundle(self.destination, "old")

    def unregister_fixture(self):
        subprocess.run([
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
            "-u", str(self.destination),
        ], capture_output=True)

    def make_bundle(self, bundle, version):
        contents = bundle / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Helpers").mkdir()
        shutil.copy2(self.executable, contents / "MacOS" / "iRecordFixture")
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump({
                "CFBundleIdentifier": "dev.irecord.installer-fixture." + uuid.uuid4().hex,
                "CFBundleExecutable": "iRecordFixture",
                "CFBundleName": "iRecordFixture",
                "CFBundleDisplayName": "iRecordFixture",
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1",
                "LSUIElement": True,
            }, stream)
        (contents / "fixture-version").write_text(version)
        helper = contents / "Helpers" / "irecord"
        helper.write_text('''#!/usr/bin/python3
import json
import os
from pathlib import Path
import sys
assert sys.argv[1:] == ["install"]
parent = Path(__file__).resolve().parents[3]
backups = list(parent.glob(".irecord-install-*/backup/*"))
Path(os.environ["IRECORD_INSTALL_TEST_LOG"]).write_text(json.dumps({
    "backups": [str(path) for path in backups],
    "old_versions": [(path / "Contents" / "fixture-version").read_text() for path in backups],
}))
''')
        helper.chmod(0o755)
        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(bundle)], check=True)

    def install(self, environment=None):
        return subprocess.run(
            ["/bin/bash", str(INSTALLER), str(self.source), str(self.destination)],
            env=environment or self.environment,
            text=True, capture_output=True, timeout=30,
        )

    def stop_fixture(self, process):
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)

    def test_running_destination_is_not_renamed_or_replaced(self):
        executable = self.destination / "Contents" / "MacOS" / "iRecordFixture"
        inode = executable.stat().st_ino
        process = subprocess.Popen([str(executable)])
        self.addCleanup(self.stop_fixture, process)
        # Wait for the process to map the fixture before invoking the installer.
        for _ in range(50):
            mapped = subprocess.run(
                ["/usr/sbin/lsof", "-t", "-a", "-d", "txt", str(executable)],
                capture_output=True, text=True,
            )
            if str(process.pid) in mapped.stdout.split():
                break
            self.assertIsNone(process.poll(), "Fixture exited before installer test")
            time.sleep(0.02)
        else:
            self.fail("Could not observe fixture executable mapping")
        result = self.install()
        self.assertNotEqual(result.returncode, 0, "Installer must refuse a running destination: " + result.stdout)
        self.assertEqual(executable.stat().st_ino, inode, "Running executable was replaced")
        self.assertIsNone(process.poll(), "Installer stopped a running app")
        self.assertEqual((self.destination / "Contents" / "fixture-version").read_text(), "old")
        self.assertFalse(self.log.exists(), "CLI install ran despite running App")
        self.assertEqual(list(self.destination.parent.glob(".irecord-install-*")), [])

    def test_idle_install_preserves_backup_app_name_and_installs_cli(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.destination / "Contents" / "fixture-version").read_text(), "new")
        log = json.loads(self.log.read_text())
        self.assertEqual(len(log["backups"]), 1, "Expected one retained bundle backup during replacement")
        self.assertEqual(Path(log["backups"][0]).name, "iRecord.app")
        self.assertEqual(log["old_versions"], ["old"])
        self.assertEqual(list(self.destination.parent.glob(".irecord-install-*")), [])
        verify = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(self.destination)], capture_output=True, text=True)
        self.assertEqual(verify.returncode, 0, verify.stderr)

    def test_failed_replacement_restores_existing_app(self):
        # Intercept only the replacement move; permit backup and rollback moves.
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        move = bin_dir / "mv"
        move.write_text('''#!/usr/bin/python3
import os
from pathlib import Path
import sys
source, destination = map(Path, sys.argv[-2:])
stage = source.parent.parent if source.parent.name == "incoming" else source.parent
if source.name == "iRecord.app" and stage.name.startswith(".irecord-install-") and str(destination) == os.environ["IRECORD_INSTALL_TEST_DEST"]:
    Path(os.environ["IRECORD_INSTALL_TEST_FAILURE"]).touch()
    sys.exit(73)
os.execv("/bin/mv", ["/bin/mv"] + sys.argv[1:])
''')
        move.chmod(0o755)
        failure = self.root / "injected-failure"
        environment = dict(self.environment,
            PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
            IRECORD_INSTALL_TEST_DEST=str(self.destination),
            IRECORD_INSTALL_TEST_FAILURE=str(failure),
        )
        inode = (self.destination / "Contents" / "MacOS" / "iRecordFixture").stat().st_ino
        result = self.install(environment)
        self.assertTrue(failure.exists(), "Replacement move failure was not injected")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.destination / "Contents" / "fixture-version").read_text(), "old")
        self.assertEqual((self.destination / "Contents" / "MacOS" / "iRecordFixture").stat().st_ino, inode)
        self.assertFalse(self.log.exists())
        self.assertEqual(list(self.destination.parent.glob(".irecord-install-*")), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
