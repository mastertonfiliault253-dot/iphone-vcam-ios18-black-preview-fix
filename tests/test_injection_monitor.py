import pathlib
import plistlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class InjectionMonitorTests(unittest.TestCase):
    def test_monitor_has_only_the_two_exact_allowed_process_paths(self) -> None:
        source = (ROOT / "Sources" / "Daemon" / "VCAMInjectionMonitor.m").read_text(
            encoding="utf-8"
        )
        self.assertEqual(source.count(".processPath ="), 2)
        self.assertIn(
            '.processPath = "/System/Library/CoreServices/SpringBoard.app/SpringBoard"',
            source,
        )
        self.assertIn('.processPath = "/usr/sbin/mediaserverd"', source)
        self.assertEqual(source.count(".dylibPath ="), 2)
        for forbidden in (
            "/Applications/Camera.app",
            "MobileSafari",
            "SafariViewService",
            "WebKit",
            "Google Chrome",
        ):
            self.assertNotIn(forbidden, source)

    def test_monitor_retries_after_pid_change_and_requires_constructor_proof(self) -> None:
        source = (ROOT / "Sources" / "Daemon" / "VCAMInjectionMonitor.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("pid != target->observedPID", source)
        self.assertIn("target->injectedPID = 0", source)
        self.assertIn("VCAMProofContainsPID", source)
        self.assertIn("result == 0 && observed == pid", source)
        self.assertIn("observed == pid", source)
        self.assertIn("target->nextAttempt = now + 5", source)
        self.assertIn("ETIMEDOUT", source)
        self.assertNotIn("already loaded", source)

    def test_monitor_is_a_root_rootless_launchdaemon(self) -> None:
        launchd = plistlib.loads(
            (
                ROOT
                / "layout"
                / "Library"
                / "LaunchDaemons"
                / "com.codex.vcaminjectd.plist"
            ).read_bytes()
        )
        self.assertEqual(launchd["ProgramArguments"], ["/var/jb/usr/libexec/vcaminjectd"])
        self.assertEqual(launchd["UserName"], "root")
        self.assertTrue(launchd["RunAtLoad"])
        self.assertTrue(launchd["KeepAlive"])


if __name__ == "__main__":
    unittest.main()
