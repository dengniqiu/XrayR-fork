"""Run with root on Linux: python3 -m unittest discover -s tests -v.

Each test uses a disposable chroot. Downloads and service commands are mocked;
real Bash and BusyBox perform file operations without touching host services.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


REPO = Path(__file__).resolve().parents[1]
CHROOT = shutil.which("chroot")


@unittest.skipUnless(
    sys.platform == "linux" and os.geteuid() == 0 and shutil.which("busybox"),
    "requires Linux, root, and a static BusyBox",
)
class ScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xrayr-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in (
            "bin", "dev", "etc/init.d", "etc/runlevels/default", "proc/self",
            "run", "sys/fs/cgroup", "test", "tmp", "usr/bin", "var/log",
        ):
            self.path(directory).mkdir(parents=True, exist_ok=True)
        # No host devices or procfs mounts are exposed to the test.
        self.write("dev/null", "")
        self.write("dev/zero", "")
        self.copy_program("/bin/bash")
        busybox = shutil.which("busybox")
        self.copy_program(busybox, "/bin/busybox")
        applets = subprocess.check_output([busybox, "--list"], text=True).splitlines()
        for applet in applets:
            target = self.path("bin/" + applet)
            if not target.exists():
                target.symlink_to("/bin/busybox")
        for relative in ("install.sh", "scripts/xrayr-manager.sh"):
            target = self.path("test/" + relative)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / relative, target)
        self.write("proc/meminfo", "MemTotal: 131072 kB\n")
        self.write("proc/self/cgroup", "0::/\n")
        self.write("proc/version", "Linux Alpine\n")
        self.write("etc/alpine-release", "3.22.0\n")
        self.write("etc/os-release", 'ID=alpine\nVERSION_ID="3.22.0"\n')
        self.write("test/state", "stopped")
        self.write("test/fs", "ext4")
        self.command("uname", 'case "$1" in -s) echo Linux ;; -m) echo aarch64 ;; esac')
        self.command("sleep", "exit 0")
        self.command("df", '''printf 'Filesystem Type 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/test %s 1048576 0 1048576 0%% /\n' "$(cat /test/fs)"''')
        self.command("curl", '''url= output=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) output=$2; shift 2 ;;
        --retry|--retry-delay|--max-time) shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
printf '%s\n' "$url" >> /test/urls
case "$url" in
    */releases/latest) printf '{"tag_name":"v1.2.3"}'; exit 0 ;;
    */releases/download/*)
        [ ! -f /test/fail-download ] || exit 22
        case "$url" in
            *.zip) cp /test/asset.zip "$output" ;;
            *)
                cp /test/binary "$output"
                ls -i "$output" | awk '{print $1}' > /test/inode
                printf '%s' "$output" > /test/download-path ;;
        esac ;;
    */config/*) printf 'placeholder\n' > "$output" ;;
    */scripts/xrayr-manager.sh)
        [ ! -f /test/fail-manager ] || exit 22
        cp /test/scripts/xrayr-manager.sh "$output" ;;
    */install.sh) cp /test/install.sh "$output" ;;
    *) exit 22 ;;
esac''')
        self.write("test/binary", '#!/bin/bash\necho mock-XrayR\n', mode=0o755)
        with zipfile.ZipFile(self.path("test/asset.zip"), "w") as archive:
            archive.writestr("nested/XrayR", "#!/bin/bash\necho mock-XrayR\n")
        self.command("rc-service", '''printf 'rc-service %s\n' "$*" >> /test/services
case "$2" in
    status) [ "$(cat /test/state)" = running ] ;;
    start|restart)
        if [ -f /test/fail-start ]; then rm /test/fail-start; exit 1; fi
        echo running > /test/state ;;
    stop) echo stopped > /test/state ;;
esac''')
        self.command("rc-update", '''printf 'rc-update %s\n' "$*" >> /test/services
case "$1" in
    add) ln -sf "/etc/init.d/$2" "/etc/runlevels/default/$2" ;;
    del) rm -f "/etc/runlevels/default/$2" ;;
esac''')
        self.command("systemctl", '''printf 'systemctl %s\n' "$*" >> /test/services
case "$1" in
    is-active) [ "$(cat /test/state)" = running ] ;;
    is-enabled) [ -f /test/enabled ] ;;
    enable) touch /test/enabled ;;
    disable) rm -f /test/enabled ;;
    start|restart)
        if [ -f /test/fail-start ]; then rm /test/fail-start; exit 1; fi
        echo running > /test/state ;;
    stop) echo stopped > /test/state ;;
esac''')

    def path(self, relative):
        return self.root / relative.lstrip("/")

    def write(self, relative, content, mode=None):
        target = self.path(relative)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        if mode is not None:
            target.chmod(mode)

    def command(self, name, body):
        target = self.path("bin/" + name)
        if target.is_symlink():
            target.unlink()
        self.write("bin/" + name, "#!/bin/bash\n" + body + "\n", mode=0o755)

    def copy_program(self, source, destination=None):
        target = self.path(destination or source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        target.chmod(0o755)
        result = subprocess.run(["ldd", source], capture_output=True, text=True)
        for library in re.findall(r"(?:=>\s+)?(/[^\s()]+)", result.stdout):
            target = self.path(library)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(library, target)

    def run_shell(self, script, *, ok=True):
        result = subprocess.run(
            [CHROOT, str(self.root), "/bin/bash", "-c", script],
            env={"PATH": "/bin:/usr/bin", "HOME": "/root", "LC_ALL": "C"},
            capture_output=True, text=True, timeout=20,
        )
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def install(self, *, ok=True, prefix=""):
        return self.run_shell(prefix + "bash /test/install.sh install", ok=ok)

    def systemd(self):
        self.path("run/systemd/system").mkdir(parents=True)
        self.path("etc/alpine-release").unlink()
        self.write("etc/issue", "Ubuntu 22.04\n")
        self.write("etc/os-release", 'ID=ubuntu\nVERSION_ID="22.04"\n')

    def assert_clean(self, directory="usr/local/XrayR"):
        self.assertFalse(list(self.path(directory).glob(".install.*")))

    def test_low_memory_openrc_same_inode_and_runtime_env(self):
        self.install()
        binary = self.path("usr/local/XrayR/XrayR")
        self.assertEqual(binary.stat().st_ino, int(self.path("test/inode").read_text()))
        self.assertTrue(self.path("test/download-path").read_text().startswith("/usr/local/XrayR/.install."))
        self.assertEqual(self.path("etc/XrayR/runtime.env").read_text(), "GOMEMLIMIT=64MiB\nGOGC=50\n")
        self.assertTrue(self.path("etc/runlevels/default/XrayR").is_symlink())
        self.assertNotIn("systemctl", self.path("test/services").read_text())
        self.run_shell("sh -n /etc/init.d/XrayR")
        result = self.run_shell('RC_SVCNAME=XrayR sh -c \' . /etc/init.d/XrayR; env\'')
        self.assertIn("GOMEMLIMIT=64MiB", result.stdout)
        self.assertIn("GOGC=50", result.stdout)
        self.assert_clean()

    def test_stdin_install_entry(self):
        self.run_shell("bash -s -- install < /test/install.sh")
        self.assertTrue(self.path("usr/local/XrayR/XrayR").exists())
        self.assert_clean()

    def test_full_size_binary_is_renamed_not_copied(self):
        with self.path("test/binary").open("r+b") as binary:
            binary.truncate(112 * 1024 * 1024)
        self.install()
        binary = self.path("usr/local/XrayR/XrayR")
        self.assertEqual(binary.stat().st_size, 112 * 1024 * 1024)
        self.assertEqual(binary.stat().st_ino, int(self.path("test/inode").read_text()))
        self.assert_clean()

    def test_tmpfs_ramfs_and_rootfs_rejected_before_download(self):
        for fs_type in ("tmpfs", "ramfs", "rootfs"):
            with self.subTest(fs_type=fs_type):
                self.write("test/fs", fs_type)
                self.install(ok=False)
                self.assertNotIn("/releases/download/", self.path("test/urls").read_text())
                self.assertFalse(self.path("usr/local/XrayR/XrayR").exists())
                self.assert_clean()

    def test_failed_download_preserves_old_binary_and_running_service(self):
        self.write("usr/local/XrayR/XrayR", "old-binary")
        self.write("etc/init.d/XrayR", "old-service")
        self.write("test/state", "running")
        self.write("test/fail-download", "")
        self.install(ok=False)
        self.assertEqual(self.path("usr/local/XrayR/XrayR").read_text(), "old-binary")
        self.assertEqual(self.path("test/state").read_text(), "running")
        self.assert_clean()

    def test_manager_download_failure_does_not_stop_old_service(self):
        self.write("usr/local/XrayR/XrayR", "old-binary")
        self.write("etc/init.d/XrayR", "old-service")
        self.write("test/state", "running")
        self.write("test/fail-manager", "")
        self.install(ok=False)
        self.assertEqual(self.path("usr/local/XrayR/XrayR").read_text(), "old-binary")
        self.assertEqual(self.path("test/state").read_text(), "running")
        self.assert_clean()

    def test_upgrade_restarts_only_previously_running_service(self):
        self.install()
        self.write("test/state", "running")
        self.write("etc/XrayR/config.yml", "keep-me")
        self.install()
        self.assertEqual(self.path("etc/XrayR/config.yml").read_text(), "keep-me")
        self.assertEqual(self.path("test/state").read_text().strip(), "running")
        self.assertIn("rc-service XrayR stop", self.path("test/services").read_text())
        self.assertTrue(list(self.path("etc").glob("XrayR.bak.*")))
        self.assert_clean()

    def test_failed_restart_restores_previous_binary(self):
        self.install()
        self.write("usr/local/XrayR/XrayR", "old-binary")
        self.write("test/state", "running")
        self.write("test/fail-start", "")
        self.install(ok=False)
        self.assertEqual(self.path("usr/local/XrayR/XrayR").read_text(), "old-binary")
        self.assertEqual(self.path("test/state").read_text().strip(), "running")
        self.assert_clean()

    def test_cgroup_v2_limit_selects_low_memory_path(self):
        self.write("proc/meminfo", "MemTotal: 8388608 kB\n")
        self.write("sys/fs/cgroup/memory.max", "134217728\n")
        self.install()
        self.assertIn("GOMEMLIMIT=64MiB", self.path("etc/XrayR/runtime.env").read_text())
        self.assertNotIn(".zip", self.path("test/urls").read_text())

    def test_nested_cgroup_v1_limit(self):
        self.write("proc/meminfo", "MemTotal: 8388608 kB\n")
        self.write("proc/self/cgroup", "5:memory:/container\n")
        self.write("sys/fs/cgroup/memory/memory.limit_in_bytes", "9223372036854771712\n")
        self.write("sys/fs/cgroup/memory/container/memory.limit_in_bytes", "134217728\n")
        result = self.run_shell("source /test/install.sh; total_memory_kib")
        self.assertEqual(result.stdout.strip(), "131072")

    def test_systemd_high_memory_zip_path(self):
        self.systemd()
        self.write("proc/meminfo", "MemTotal: 1048576 kB\n")
        self.install()
        self.assertIn(".zip", self.path("test/urls").read_text())
        self.assertTrue(self.path("usr/local/XrayR/XrayR").exists())
        self.assertIn("EnvironmentFile=", self.path("etc/systemd/system/XrayR.service").read_text())
        service = self.path("etc/systemd/system/XrayR.service").read_text()
        self.assertIn("WorkingDirectory=/usr/local/XrayR\n", service)
        self.assertIn("ExecStart=/usr/local/XrayR/XrayR --config /etc/XrayR/config.yml\n", service)
        self.assertNotIn('WorkingDirectory="', service)
        self.assertNotIn("rc-update", self.path("test/services").read_text())
        self.assertFalse(self.path("etc/XrayR/runtime.env").exists())
        self.assert_clean()

    def test_custom_install_path_is_used_by_later_manager_commands(self):
        self.install(prefix="XRAYR_INSTALL_DIR=/disk/XrayR XRAYR_CONFIG_DIR=/disk/config " )
        result = self.run_shell("bash /usr/bin/XrayR version")
        self.assertIn("mock-XrayR", result.stdout)
        self.assertIn("/disk/config/config.yml", self.path("etc/init.d/XrayR").read_text())
        self.assert_clean("disk/XrayR")

    def test_openrc_manager_start_stop_enable_disable(self):
        self.install()
        for action in ("start", "stop", "enable", "disable"):
            self.run_shell("bash /usr/bin/XrayR " + action)
        calls = self.path("test/services").read_text()
        for call in ("rc-service XrayR start", "rc-service XrayR stop",
                     "rc-update add XrayR default", "rc-update del XrayR default"):
            self.assertIn(call, calls)
        self.assertNotIn("systemctl", calls)

    def test_systemd_manager_start_stop_enable_disable(self):
        self.systemd()
        self.install()
        for action in ("start", "stop", "enable", "disable"):
            self.run_shell("bash /usr/bin/XrayR " + action)
        self.assertNotIn("rc-service", self.path("test/services").read_text())

    def test_manager_update_download_source(self):
        self.install()
        self.run_shell("bash /usr/bin/XrayR update v9.9.9")
        urls = self.path("test/urls").read_text()
        self.assertIn("dengniqiu/XrayR-fork/main/install.sh", urls)
        self.assertIn("/releases/download/v9.9.9/", urls)
        self.assertNotIn("zys960930", urls)

    def test_uninstall_openrc(self):
        self.install()
        self.run_shell("bash /test/install.sh uninstall")
        for relative in ("usr/local/XrayR", "etc/XrayR", "etc/init.d/XrayR",
                         "usr/bin/XrayR", "etc/XrayR-manager.conf"):
            self.assertFalse(self.path(relative).exists(), relative)

    def test_runtime_env_is_not_overwritten(self):
        self.write("etc/XrayR/runtime.env", "GOMEMLIMIT=80MiB\nGOGC=75\n")
        self.install()
        self.assertEqual(self.path("etc/XrayR/runtime.env").read_text(), "GOMEMLIMIT=80MiB\nGOGC=75\n")

    def test_unsafe_install_path_is_rejected(self):
        self.install(prefix="XRAYR_INSTALL_DIR=/usr/local " , ok=False)
        self.assertFalse(self.path("test/urls").exists())


if __name__ == "__main__":
    unittest.main()
