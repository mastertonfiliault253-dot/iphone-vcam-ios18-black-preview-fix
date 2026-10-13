import pathlib
import plistlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class InjectionMonitorTests(unittest.TestCase):
    def test_cameracaptured_proof_uses_reference_log_preferred_by_hook(self) -> None:
        monitor = (ROOT / "Sources" / "Daemon" / "VCAMInjectionMonitor.m").read_text(
            encoding="utf-8"
        )
        image_utils = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefImageUtils.m"
        ).read_text(encoding="utf-8")
        reference_log = "/var/mobile/Library/VirtualCaptureCard/VCAM/vcam-ref.log"
        candidates = image_utils.split(
            "static const char *candidatePaths[] = {", 1
        )[1].split("};", 1)[0]
        first_candidate = next(
            line.strip().removesuffix(",")
            for line in candidates.splitlines()
            if line.strip().startswith('"')
        )

        self.assertEqual(first_candidate, f'"{reference_log}"')
        self.assertIn(f'.proofPath = "{reference_log}"', monitor)

    def test_monitor_repairs_only_cameracaptured_and_never_springboard_or_apps(self) -> None:
        source = (ROOT / "Sources" / "Daemon" / "VCAMInjectionMonitor.m").read_text(
            encoding="utf-8"
        )
        self.assertEqual(source.count(".processPath ="), 1)
        self.assertNotIn("/System/Library/CoreServices/SpringBoard.app/SpringBoard", source)
        self.assertIn('.processPath = "/usr/libexec/cameracaptured"', source)
        self.assertEqual(source.count(".dylibPath ="), 1)
        # SpringBoard and application clients are loaded by ElleKit from the
        # plist filter; direct PAC injection races dyld and can crash SpringBoard.
        for forbidden in (
            "VCAMSpringBoardClient.dylib",
            "/Applications/Camera.app",
            "MobileSafari",
            "Google",
            "Google Chrome",
            "Microsoft Edge",
            "Firefox",
            "SafariViewService",
            "WebKit",
        ):
            self.assertNotIn(forbidden, source)
        self.assertIn("SpringBoard and application clients use ElleKit auto-injection", source)

    def test_springboard_plist_filter_shrinks_to_springboard_only(self) -> None:
        # M 轮收缩：全局悬浮点（SpringBoard 单例）已真机验证可悬浮于前台 App
        # 之上，浏览器/Camera 不再需要 vcam dylib 足迹（消除重复点）。
        # filter 必须只含 SpringBoard；浏览器条目不得回归。
        plist = (ROOT / "VCAMSpringBoardClient.plist").read_text(encoding="utf-8")
        self.assertIn("com.apple.springboard", plist)
        for forbidden in (
            "com.apple.camera",
            "com.apple.mobilesafari",
            "com.google.chrome.ios",
            "com.google.GoogleMobile",
            "com.microsoft.msedge",
            "org.mozilla.ios.Firefox",
        ):
            self.assertNotIn(forbidden, plist)

    def test_monitor_does_not_reinject_same_stable_pid_without_file_proof(self) -> None:
        source = (ROOT / "Sources" / "Daemon" / "VCAMInjectionMonitor.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("pid != target->observedPID", source)
        self.assertIn("startToken != target->observedStartToken", source)
        self.assertIn("target->injectedPID = 0", source)
        self.assertIn("attemptedPID", source)
        self.assertIn("attemptedStartToken", source)
        self.assertIn("VCAMProofContainsProcess", source)
        self.assertIn("VCAMProcessStartToken", source)
        # A proof is still preferred, but a sandbox-invisible proof must not
        # cause repeated PAC injection into the same stable process.
        self.assertIn("observedStartToken == startToken", source)
        self.assertIn("observed == pid", source)
        self.assertIn("target->nextAttempt = now + 30", source)
        self.assertIn("ETIMEDOUT", source)
        self.assertIn("late-proof", source)
        self.assertIn("assumed-loaded proof=0", source)
        self.assertIn("attempted-without-proof", source)
        self.assertIn("target->attemptedPID == pid &&", source)
        self.assertIn("target->attemptedStartToken == startToken", source)
        # A pid that already has constructor proof must never be injected again,
        # even across daemon restarts.
        self.assertIn("already-loaded proof=1", source)
        self.assertIn("if (VCAMProofContainsProcess(target, pid, startToken)) {", source)
        self.assertNotIn('proofFormat = "pid=%d start=%llu "', source)
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
