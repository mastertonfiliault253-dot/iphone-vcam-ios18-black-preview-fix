import pathlib
import plistlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class InjectionMonitorTests(unittest.TestCase):
    def test_monitor_repairs_only_system_clients_and_never_apps(self) -> None:
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
        # Application clients (Camera, Safari, browsers) are loaded by ElleKit
        # from the plist filter; opainject must never target an app process.
        for forbidden in (
            "/Applications/Camera.app",
            "MobileSafari",
            "Google Chrome",
            "Microsoft Edge",
            "Firefox",
            "SafariViewService",
            "WebKit",
        ):
            self.assertNotIn(forbidden, source)
        self.assertIn("application clients use ElleKit auto-injection", source)

    def test_springboard_plist_filter_keeps_application_clients(self) -> None:
        plist = (ROOT / "VCAMSpringBoardClient.plist").read_text(encoding="utf-8")
        for expected in (
            "com.apple.camera",
            "com.apple.mobilesafari",
            "com.google.chrome.ios",
            "com.microsoft.msedge",
            "org.mozilla.ios.Firefox",
        ):
            self.assertIn(expected, plist)

    def test_monitor_retries_after_pid_change_and_requires_constructor_proof(self) -> None:
        source = (ROOT / "Sources" / "Daemon" / "VCAMInjectionMonitor.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("pid != target->observedPID", source)
        self.assertIn("startToken != target->observedStartToken", source)
        self.assertIn("target->injectedPID = 0", source)
        self.assertIn("VCAMProofContainsProcess", source)
        self.assertIn("VCAMProcessStartToken", source)
        # The injector's exit status is not the source of truth: opainject PAC
        # mode can time out after a successful dlopen, so only the on-disk
        # constructor proof plus a stable pid count as success.
        self.assertIn("observedStartToken == startToken", source)
        self.assertIn("observed == pid", source)
        self.assertIn("target->nextAttempt = now + 30", source)
        self.assertIn("ETIMEDOUT", source)
        self.assertIn("late-proof", source)
        # A pid that already has constructor proof must never be injected again,
        # even across daemon restarts.
        self.assertIn("already-loaded proof=1", source)
        self.assertIn("if (VCAMProofContainsProcess(target, pid, startToken)) {", source)
        self.assertIn('proofFormat = "pid=%d start=%llu "', source)
        self.assertIn('proofFormat = "[%d][start=%llu]["', source)

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
