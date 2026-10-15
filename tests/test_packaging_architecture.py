import json
import pathlib
import plistlib
import subprocess
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class PackagingArchitectureTests(unittest.TestCase):
    def test_debian_maintainer_scripts_are_executable_in_git(self) -> None:
        for relative_path in (
            "layout/DEBIAN/postinst",
            "layout/DEBIAN/prerm",
            "layout/DEBIAN/postrm",
        ):
            result = subprocess.run(
                ["git", "ls-files", "--stage", relative_path],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertTrue(
                result.stdout.startswith("100755 "),
                f"{relative_path} must be committed as executable",
            )

    def test_package_targets_ios_18(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        control = (ROOT / "control").read_text(encoding="utf-8")
        self.assertIn("TARGET = iphone:clang:latest:18.0", makefile)
        self.assertIn("firmware (>= 18.0)", control)
        self.assertIn("firmware (<< 19.0)", control)

    def test_ci_rejects_arm64e_ui_without_objective_c_stub_sections(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "build.yml").read_text(
            encoding="utf-8"
        )
        # FFmpeg is built as arm64+arm64e fat static libraries so the injected
        # SpringBoard client ships both slices and CI thins arm64e for the
        # ObjC stub section checks.
        self.assertIn('lipo "$springboard_client" -verify_arch arm64 arm64e', workflow)
        self.assertIn('lipo "$springboard_client" -thin arm64e', workflow)
        self.assertIn('otool -l /tmp/VCAMSpringBoardClient-arm64e.dylib', workflow)
        self.assertIn("sectname __objc_stubs", workflow)
        self.assertIn("sectname __objc_intobj", workflow)

    def test_package_version_matches_runtime_build_tag(self) -> None:
        control = (ROOT / "control").read_text(encoding="utf-8")
        version = next(
            line.split(":", 1)[1].strip()
            for line in control.splitlines()
            if line.startswith("Version:")
        )
        configuration = (
            ROOT / "Sources" / "Core" / "VCAMConfiguration.m"
        ).read_text(encoding="utf-8")
        self.assertIn(f'com.codex.vcam/{version}', configuration)

    def test_architecture_documents_ui_only_apps_and_fail_closed_capture(self) -> None:
        architecture = (ROOT / "ARCHITECTURE.md").read_text(encoding="utf-8")
        injection = (ROOT / "docs" / "injection-target-architecture.md").read_text(
            encoding="utf-8"
        )
        self.assertIn("hosts receive UI only", architecture)
        self.assertIn("capture is fail-closed", architecture)
        self.assertNotIn("fails open", architecture)
        self.assertIn("Camera and the listed browser main processes", injection)
        self.assertNotIn("There is no Camera, browser", injection)

    def test_manifest_describes_two_injections_and_two_isolated_daemons(self) -> None:
        manifest = json.loads((ROOT / "packaging" / "targets.json").read_text(encoding="utf-8"))
        targets = {target["name"]: target for target in manifest["targets"]}
        self.assertEqual(
            set(targets),
            {"VCAMMediaServerClient", "VCAMSpringBoardClient", "vcamd", "vcaminjectd"},
        )
        self.assertTrue(targets["VCAMMediaServerClient"]["injected"])
        self.assertTrue(targets["VCAMSpringBoardClient"]["injected"])
        self.assertFalse(targets["vcamd"]["injected"])
        self.assertFalse(targets["vcaminjectd"]["injected"])
        self.assertEqual(
            targets["vcaminjectd"]["allowedTargets"],
            ["cameracaptured"],
        )
        self.assertEqual(
            targets["VCAMSpringBoardClient"]["bundleIds"],
            [
                "com.apple.springboard",
                "com.apple.camera",
                "com.apple.mobilesafari",
                "com.google.chrome.ios",
                "com.microsoft.msedge",
                "org.mozilla.ios.Firefox",
            ],
        )
        self.assertNotIn("hls-ffmpeg-videotoolbox", targets["vcamd"]["sources"])
        self.assertEqual(
            targets["vcamd"]["rollbackSources"],
            [
                "local-image-imageio",
                "local-video-avassetreader",
                "hls-ffmpeg-videotoolbox",
            ],
        )
        self.assertEqual(targets["VCAMMediaServerClient"]["executables"], ["cameracaptured"])

    def test_launchdaemon_runs_package_worker_from_rootless_prefix(self) -> None:
        launchd = (
            ROOT / "layout" / "Library" / "LaunchDaemons" / "com.codex.vcamd.plist"
        ).read_text(encoding="utf-8")
        postinst = (ROOT / "layout" / "DEBIAN" / "postinst").read_text(encoding="utf-8")
        prerm = (ROOT / "layout" / "DEBIAN" / "prerm").read_text(encoding="utf-8")
        postrm = (ROOT / "layout" / "DEBIAN" / "postrm").read_text(encoding="utf-8")
        self.assertIn("com.codex.vcamd", launchd)
        self.assertIn("<string>/var/jb/usr/libexec/vcamd</string>", launchd)
        self.assertNotIn("tweaksupport", launchd)
        self.assertIn("launchctl bootstrap system", postinst)
        self.assertIn("launchctl kickstart -k system/com.codex.vcamd", postinst)
        self.assertIn("for attempt in 1 2 3 4 5", postinst)
        self.assertIn("launchctl print system/com.codex.vcamd", postinst)
        self.assertIn("launchctl bootout system/com.codex.vcamd", prerm)
        self.assertIn('remove|purge)', postrm)
        self.assertIn("killall -9 cameracaptured", postrm)
        self.assertIn("killall -9 SpringBoard", postrm)

        injection_launchd = (
            ROOT / "layout" / "Library" / "LaunchDaemons" / "com.codex.vcaminjectd.plist"
        ).read_text(encoding="utf-8")
        self.assertIn("<string>/var/jb/usr/libexec/vcaminjectd</string>", injection_launchd)
        self.assertIn("<string>root</string>", injection_launchd)
        self.assertIn("launchctl bootstrap system", postinst)
        self.assertIn("system/com.codex.vcaminjectd", postinst)
        self.assertIn("system/com.codex.vcaminjectd", prerm)

    def test_upgrade_respawns_injection_hosts_before_loading_clients(self) -> None:
        postinst = (
            ROOT / "layout" / "DEBIAN" / "postinst"
        ).read_text(encoding="utf-8")
        restart = "killall -9 SpringBoard cameracaptured"
        self.assertIn(restart, postinst)
        self.assertLess(
            postinst.index(restart),
            postinst.index('vcam_log_injection "automatic target=SpringBoard'),
        )
        self.assertIn(
            'vcam_log_injection "deferred target=cameracaptured reason=vcaminjectd"',
            postinst,
        )
        self.assertNotIn("vcam_best_effort_inject", postinst)

    def test_ci_rejects_springboard_as_an_active_injection_monitor_target(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "build.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "grep -q '\"/usr/libexec/cameracaptured\"' Sources/Daemon/VCAMInjectionMonitor.m",
            workflow,
        )
        self.assertIn(
            "! grep -q '\"/System/Library/CoreServices/SpringBoard.app/SpringBoard\"' "
            "Sources/Daemon/VCAMInjectionMonitor.m",
            workflow,
        )
        self.assertIn(
            'test "$(grep -c \'^            \\.processPath = \' '
            'Sources/Daemon/VCAMInjectionMonitor.m)" -eq 1',
            workflow,
        )
        self.assertIn(
            'test "$(grep -c \'^            \\.dylibPath = \' '
            'Sources/Daemon/VCAMInjectionMonitor.m)" -eq 1',
            workflow,
        )

    def test_realtime_worker_sets_decoder_jetsam_budget_before_allocating(self) -> None:
        launchd_path = (
            ROOT / "layout" / "Library" / "LaunchDaemons" / "com.codex.vcamd.plist"
        )
        launchd = plistlib.loads(launchd_path.read_bytes())
        self.assertEqual(launchd["ProcessType"], "Interactive")
        self.assertEqual(launchd["POSIXSpawnType"], "Interactive")
        self.assertEqual(launchd["UserName"], "mobile")
        self.assertFalse(launchd["EnablePressuredExit"])
        self.assertFalse(launchd["EnableTransactions"])
        self.assertTrue(launchd["KeepAlive"])
        self.assertNotIn("JetsamProperties", launchd)

        entitlements = plistlib.loads((ROOT / "vcamd.entitlements").read_bytes())
        self.assertEqual(
            entitlements,
            {
                "com.apple.private.memorystatus": True,
                "com.apple.videotoolbox.hardwarevideodecoder": True,
            },
        )
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn(
            "vcamd_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/vcamd.entitlements",
            makefile,
        )

        main = (ROOT / "Sources" / "Daemon" / "main.m").read_text(encoding="utf-8")
        self.assertIn("MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES", main)
        self.assertIn("MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES", main)
        self.assertIn("memlimit_active = VCAMWorkerMemoryLimitMB", main)
        self.assertIn("memlimit_inactive = VCAMWorkerMemoryLimitMB", main)
        self.assertIn("VCAMWorkerMemoryLimitMB = 256", main)
        for unsafe_escalation in (
            "JETSAM_PRIORITY_CRITICAL",
            "MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES",
            "MEMORYSTATUS_CMD_SET_PROCESS_IS_MANAGED",
        ):
            self.assertNotIn(unsafe_escalation, main)
        self.assertLess(
            main.index("VCAMRaiseJetsamMemoryLimit();"),
            main.index("VCAMSharedFrameWriterCreate();"),
        )

    def test_package_scheme_is_rootless_only(self) -> None:
        manifest = json.loads((ROOT / "packaging" / "targets.json").read_text(encoding="utf-8"))
        build = (ROOT / "scripts" / "build-all.sh").read_text(encoding="utf-8")
        wsl_build = (ROOT / "scripts" / "build-rootless-wsl.sh").read_text(encoding="utf-8")
        self.assertEqual(manifest["scheme"], "rootless")
        self.assertIn("THEOS_PACKAGE_SCHEME=rootless", build)
        self.assertNotIn("THEOS_PACKAGE_SCHEME=roothide", build)
        self.assertFalse((ROOT / "scripts" / "build-roothide-wsl.sh").exists())
        self.assertTrue((ROOT / "scripts" / "build-rootless-wsl.sh").exists())
        self.assertIn("EXPECTED_PACKAGE_VERSION", wsl_build)
        self.assertIn('"$PROJECT_ROOT/control"', wsl_build)
        self.assertIn("--exclude='./dist'", wsl_build)
        self.assertNotIn('cp -a "$PROJECT_ROOT/."', wsl_build)
        self.assertNotIn("worker7", wsl_build)

    def test_shared_transport_is_triple_buffered_atomic_and_stale_aware(self) -> None:
        header = (ROOT / "Sources" / "Shared" / "VCAMSharedFrame.h").read_text(encoding="utf-8")
        broker_header = (ROOT / "Sources" / "Shared" / "VCAMSurfaceBroker.h").read_text(encoding="utf-8")
        implementation = (ROOT / "Sources" / "Shared" / "VCAMSharedFrame.m").read_text(encoding="utf-8")
        self.assertIn("VCAMSharedFrameSlotCount = VCAMSurfaceBrokerVideoSlotCount", header)
        self.assertIn("VCAMSurfaceBrokerVideoSlotCount = 3", broker_header)
        self.assertIn("mmap", implementation)
        self.assertIn("_Atomic", implementation)
        self.assertIn("slotSequence[slot], 0", implementation)
        self.assertIn("maximumAgeNanoseconds", implementation)
        self.assertIn("active", implementation)
        self.assertIn("VCAMSharedFrameVersion = 4", implementation)
        self.assertIn("_Atomic(uint64_t) requestedState", implementation)
        self.assertIn("atomic_compare_exchange_weak_explicit", implementation)
        self.assertIn("VCAMSharedFrameSetRequestedActive", header)
        self.assertIn("VCAMSharedFrameReaderGetActiveState", header)
        self.assertIn("if (!VCAMSharedFrameHeaderIsValid(writer->header))", implementation)
        self.assertIn("O_RDWR | O_CREAT", implementation)
        self.assertIn("VCAMSharedFrameInitializeHeader(header, active)", implementation)
        self.assertIn("flock(descriptor, LOCK_EX)", implementation)
        writer_create = implementation.split("VCAMSharedFrameWriter *VCAMSharedFrameWriterCreate", 1)[1].split(
            "void VCAMSharedFrameWriterDestroy", 1
        )[0]
        self.assertLess(writer_create.index("VCAMSharedFrameLockExclusive"), writer_create.index("HeaderIsValid"))
        self.assertLess(writer_create.index("HeaderIsValid"), writer_create.index("VCAMSharedFrameUnlock"))
        self.assertNotIn("VCAMSharedFrameInitializeHeader(writer->header", writer_create)
        self.assertIn("VCAMSharedFrameWriterDestroy(writer);", writer_create)
        mode_write = implementation.split("bool VCAMSharedFrameSetRequestedActive", 1)[1].split(
            "VCAMSharedFrameReader *VCAMSharedFrameReaderCreate", 1
        )[0]
        self.assertLess(mode_write.index("VCAMSharedFrameLockExclusive"), mode_write.index("HeaderIsValid"))
        self.assertLess(mode_write.index("HeaderIsValid"), mode_write.index("VCAMSharedFrameUnlock"))
        writer_destroy = implementation.split("void VCAMSharedFrameWriterDestroy", 1)[1].split(
            "bool VCAMSharedFrameWriterPublish", 1
        )[0]
        self.assertNotIn("writer->header->requestedState", writer_destroy)
        writer_publish = implementation.split("bool VCAMSharedFrameWriterPublish", 1)[1].split(
            "bool VCAMSharedFrameSetRequestedActive", 1
        )[0]
        self.assertNotIn("writer->header->requestedState", writer_publish)
        self.assertLess(
            writer_publish.index("VCAMSharedFrameLockExclusive(writer->descriptor)"),
            writer_publish.index("publishedSequence"),
        )
        self.assertLess(
            writer_publish.index("publishedSequence, sequence, memory_order_release"),
            writer_publish.rindex("VCAMSharedFrameUnlock(writer->descriptor)"),
        )

    def test_shared_transport_uses_cameracaptured_allowed_directory(self) -> None:
        implementation = (
            ROOT / "Sources" / "Shared" / "VCAMSharedFrame.m"
        ).read_text(encoding="utf-8")
        postinst = (ROOT / "layout" / "DEBIAN" / "postinst").read_text(
            encoding="utf-8"
        )
        transport_directory = "/var/mobile/Library/VirtualCaptureCard/VCAM"

        # iOS 18 cameracaptured explicitly grants read-write access to its
        # home-relative /Library/VirtualCaptureCard/ directory. Its sandbox
        # rejects both arbitrary /var/tmp files and lookup of VCAM's custom
        # Mach service, so the shared mmap headers must live under that grant.
        self.assertIn(
            f'"{transport_directory}/com.codex.vcam.frames"', implementation
        )
        self.assertIn(
            f'"{transport_directory}/com.codex.vcam.surfaces"', implementation
        )
        self.assertNotIn('"/var/tmp/com.codex.vcam.frames"', implementation)
        self.assertNotIn('"/var/tmp/com.codex.vcam.surfaces"', implementation)
        self.assertIn(
            f"install -d -o mobile -g mobile -m 0700 {transport_directory}",
            postinst,
        )

    def test_cameracaptured_reference_log_uses_and_resets_allowed_path(self) -> None:
        implementation = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefImageUtils.m"
        ).read_text(encoding="utf-8")
        postinst = (ROOT / "layout" / "DEBIAN" / "postinst").read_text(
            encoding="utf-8"
        )
        reference_log = (
            "/var/mobile/Library/VirtualCaptureCard/VCAM/vcam-ref.log"
        )
        candidates = implementation.split(
            "static const char *candidatePaths[] = {", 1
        )[1].split("};", 1)[0]
        first_candidate = next(
            line.strip().removesuffix(",")
            for line in candidates.splitlines()
            if line.strip().startswith('"')
        )

        self.assertEqual(first_candidate, f'"{reference_log}"')
        self.assertIn(f"vcam_ref_log={reference_log}", postinst)
        self.assertIn(': > "$vcam_ref_log"', postinst)
        self.assertIn('chown mobile:mobile "$vcam_ref_log"', postinst)
        self.assertIn('chmod 0600 "$vcam_ref_log"', postinst)
        self.assertLess(
            postinst.index(': > "$vcam_ref_log"'),
            postinst.index("killall -9 SpringBoard cameracaptured"),
        )

    def test_worker_hides_source_selection_and_publication(self) -> None:
        producer = (ROOT / "Sources" / "Daemon" / "VCAMFrameProducer.m").read_text(encoding="utf-8")
        main = (ROOT / "Sources" / "Daemon" / "main.m").read_text(encoding="utf-8")
        for source in ("VCAMLocalMediaSource", "VCAMOBSStreamSource", "VCAMRTSPStreamSource"):
            self.assertIn(source, producer)
        self.assertIn("VCAMSharedFrameWriterPublish", main)
        self.assertNotIn("VCAMSharedFrameWriterClear", main)
        self.assertNotIn("VCAMSharedFrameWriterSetActive", main)
        self.assertNotIn("VCAMSharedFrameSetRequestedActive", main)
        self.assertIn("if (pixelBuffer != NULL) {", main)
        self.assertIn("VCAMSharedFrameWriterPublishForSurfaceGeneration", main)
        self.assertIn("preferences.changed", main)
        is_enabled = producer.split("- (BOOL)isEnabled", 1)[1].split(
            "- (NSInteger)preferredFramesPerSecond", 1
        )[0]
        self.assertIn("self.configuration.enabled", is_enabled)
        self.assertNotIn("self.source != nil", is_enabled)

    def test_springboard_is_the_only_requested_mode_writer(self) -> None:
        header = (ROOT / "Sources" / "Shared" / "VCAMSharedFrame.h").read_text(encoding="utf-8")
        configuration = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(encoding="utf-8")
        worker = (ROOT / "Sources" / "Daemon" / "main.m").read_text(encoding="utf-8")
        springboard_entry = (ROOT / "Sources" / "Hooks" / "VCAMSpringBoardEntry.xm").read_text(
            encoding="utf-8"
        )

        self.assertNotIn("VCAMSharedFrameWriterSetActive", header)
        self.assertNotIn("VCAMSharedFrameWriterClear", header)
        daemon_sources = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (ROOT / "Sources" / "Daemon").glob("**/*")
            if path.is_file()
        )
        self.assertNotIn("VCAMSharedFrameSetRequestedActive", worker)
        self.assertNotIn("VCAMSharedFrameSetRequestedActive", daemon_sources)
        self.assertEqual(configuration.count("VCAMSharedFrameSetRequestedActive"), 1)
        self.assertIn("@synchronized (self)", configuration)
        self.assertIn("VCAMSynchronizeSharedRequestedState(readBack, error)", configuration)
        self.assertIn(
            "VCAMSynchronizeSharedRequestedState(\n                [self readValuesFromDisk]",
            configuration,
        )
        self.assertIn("[VCAMConfiguration startWriteBroker]", springboard_entry)

        synchronize = configuration.split("static BOOL VCAMSynchronizeSharedRequestedState", 1)[1].split(
            "+ (BOOL)writeValuesDirectly", 1
        )[0]
        self.assertIn("[enabledValue isKindOfClass:NSNumber.class]", synchronize)
        self.assertIn("return YES", synchronize)

    def test_headless_renderer_has_no_core_image_or_gpu_context(self) -> None:
        renderer = (ROOT / "Sources" / "Core" / "VCAMFrameRenderer.m").read_text(encoding="utf-8")
        producer = (ROOT / "Sources" / "Daemon" / "VCAMFrameProducer.m").read_text(encoding="utf-8")
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn("CGBitmapContextCreate", renderer)
        self.assertIn("VTCreateCGImageFromCVPixelBuffer", renderer)
        self.assertIn("kCVPixelBufferCGImageCompatibilityKey", renderer)
        self.assertIn("kCVPixelBufferCGBitmapContextCompatibilityKey", renderer)
        self.assertNotIn("kCVPixelBufferIOSurfacePropertiesKey", renderer)
        self.assertNotIn("kCVPixelBufferIOSurfacePropertiesKey", producer)
        self.assertNotIn("CIContext", renderer)
        self.assertNotIn("CoreImage", makefile.split("vcamd_FRAMEWORKS", 1)[1].splitlines()[0])
        self.assertIn("vcamd_ARCHS = arm64", makefile)

    def test_ffmpeg_is_linked_only_to_worker(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        # vcamd is the only FFmpeg worker. SpringBoard owns only native
        # AVPlayer playback; mediaserverd remains a shallow consumer.
        self.assertIn("vcamd_LIBRARIES = avformat avcodec avutil", makefile)
        self.assertNotIn("VCAMSpringBoardClient_LIBRARIES", makefile)
        self.assertNotIn("VCAMMediaServerClient_LIBRARIES", makefile)

    def test_wsl_release_copy_drops_path_bound_module_cache(self) -> None:
        build_script = (ROOT / "scripts" / "build-rootless-wsl.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("--exclude='./.theos'", build_script)
        self.assertIn("--exclude='./packages'", build_script)
        self.assertIn("--exclude='./dist'", build_script)

    def test_configuration_accepts_images_and_worker_direct_read(self) -> None:
        configuration = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(encoding="utf-8")
        for extension in ('@"png"', '@"jpg"', '@"jpeg"', '@"heic"', '@"heif"'):
            self.assertIn(extension, configuration)
        self.assertIn("isMediaWorkerHost", configuration)
        self.assertIn("self.isWriteBrokerHost || self.isMediaWorkerHost", configuration)
        self.assertIn("VCAMLocalDecoderModeSinglePlayer", configuration)
        # U-round P1: the broker preview snapshot copies the mmap ring by the
        # destination format, so an NV12 (RTSP direct-publish) session needs
        # an NV12 destination pool selected from the reported metadata or the
        # snapshot JPEG is BGRA-misread noise.
        self.assertIn("framePoolNV12", configuration)
        self.assertIn(
            "kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange", configuration
        )

    def test_springboard_contains_preview_but_no_source_decoder(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        preview = (ROOT / "Sources" / "UI" / "VCAMSharedFramePreviewView.m").read_text(encoding="utf-8")
        panel = (ROOT / "Sources" / "UI" / "VCAMControlPanelViewController.m").read_text(encoding="utf-8")
        self.assertIn("VCAMSharedFramePreviewView.m", makefile)
        self.assertIn("VCAMSharedFrameReaderCopyLatest", preview)
        self.assertIn("AVSampleBufferDisplayLayer", preview)
        self.assertIn("VCAMSharedFramePreviewView", panel)
        self.assertNotIn("presentTargetSelector", panel)


if __name__ == "__main__":
    unittest.main()
