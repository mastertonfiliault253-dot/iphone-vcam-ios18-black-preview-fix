import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class MediaPickerIntegrationTests(unittest.TestCase):
    def test_unified_picker_accepts_images_and_videos(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")
        self.assertIn("presentMediaPicker", picker)
        self.assertIn("PHPickerFilter.imagesFilter", picker)
        self.assertIn("PHPickerFilter.videosFilter", picker)
        self.assertIn("@[UTTypeImage, UTTypeMovie]", picker)
        self.assertIn("installMediaFromTemporaryURL", picker)
        self.assertIn("loadFileRepresentationForTypeIdentifier", picker)

    def test_import_is_brokered_and_activates_single_decoder(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")
        configuration = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(encoding="utf-8")
        self.assertIn("[VCAMConfiguration importMediaAtURL:temporaryURL", picker)
        self.assertIn('@"localDecoderMode": @"single"', picker)
        self.assertIn('@"replaceAudio": @NO', picker)
        self.assertIn("VCAMConfigurationBrokerImportCommand", configuration)
        self.assertIn("receiveImportedMediaFromClient", configuration)

    def test_photo_picker_normalizes_a_missing_suggested_extension(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")
        self.assertIn("VCAMNormalizedMediaName", picker)
        normalizer = picker.split("static NSString *VCAMNormalizedMediaName", 1)[1].split(
            "@interface VCAMMediaPickerController", 1
        )[0]
        self.assertIn("temporaryURL.pathExtension", normalizer)
        self.assertIn("preferredFilenameExtension", normalizer)
        self.assertLess(normalizer.index("temporaryURL.pathExtension"), normalizer.index("preferredFilenameExtension"))
        self.assertIn("stringByAppendingPathExtension", normalizer)
        callback = picker.split("loadFileRepresentationForTypeIdentifier", 1)[1].split("}];", 1)[0]
        self.assertIn("VCAMNormalizedMediaName(suggestedName, url, mediaType)", callback)

    def test_photo_picker_prefers_registered_types_with_supported_extensions(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")
        selector = picker.split("static NSString *VCAMConcreteProviderTypeIdentifier", 1)[1].split(
            "static NSString *VCAMNormalizedMediaName", 1
        )[0]
        self.assertIn("fallbackIdentifier", selector)
        self.assertIn("registeredType.preferredFilenameExtension", selector)
        self.assertIn("VCAMIsSupportedMediaExtension", selector)
        self.assertLess(
            selector.index("VCAMIsSupportedMediaExtension"),
            selector.index("return fallbackIdentifier"),
        )

    def test_broker_preflights_import_before_client_sends_payload(self) -> None:
        configuration = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(encoding="utf-8")
        client = configuration.split("+ (nullable NSString *)importMediaAtURL:", 1)[1].split(
            "+ (nullable NSString *)resolvedMediaPathForSharedPath:", 1
        )[0]
        self.assertIn("VCAMReadBrokerMessage", client)
        self.assertIn('preflight[@"message"]', client)
        self.assertIn("VCAM media import preflight failed", client)
        self.assertLess(client.index("VCAMReadBrokerMessage"), client.index("while (success && remaining > 0)"))
        server = configuration.split("BOOL importCommand =", 1)[1].split(
            "if (success && command == VCAMConfigurationBrokerFetchMediaCommand)", 1
        )[0]
        self.assertIn("validatedMediaImportHeader", server)
        self.assertGreaterEqual(server.count("VCAMWriteBrokerMessage"), 2)
        self.assertLess(server.index("VCAMWriteBrokerMessage"), server.index("receiveImportedMediaFromClient"))

    def test_broker_rejects_untyped_import_headers_without_subscripting_them(self) -> None:
        configuration = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(encoding="utf-8")
        validator = configuration.split("+ (nullable NSDictionary<NSString *, id> *)validatedMediaImportHeader:", 1)[
            1
        ].split("+ (nullable NSString *)receiveImportedMediaFromClient:", 1)[0]
        self.assertIn("[fileSizeValue isKindOfClass:NSNumber.class]", validator)
        self.assertLess(
            validator.index("[fileSizeValue isKindOfClass:NSNumber.class]"),
            validator.index("[fileSizeValue unsignedLongLongValue]"),
        )
        server = configuration.split("BOOL importCommand =", 1)[1].split(
            "if (success && command == VCAMConfigurationBrokerFetchMediaCommand)", 1
        )[0]
        self.assertIn("NSDictionary<NSString *, id> *headerDictionary", server)
        self.assertNotIn('header[@"suggestedName"]', server)
        self.assertNotIn('header[@"fileSize"]', server)

    def test_media_fetch_rejects_an_untyped_broker_response_header(self) -> None:
        configuration = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(encoding="utf-8")
        fetch = configuration.split("+ (nullable NSString *)resolvedMediaPathForSharedPath:", 1)[1].split(
            "+ (void)startWriteBroker", 1
        )[0]
        self.assertIn("id decodedResponseHeader", fetch)
        self.assertIn("[decodedResponseHeader isKindOfClass:NSDictionary.class]", fetch)
        self.assertIn("[fileSizeValue isKindOfClass:NSNumber.class]", fetch)
        self.assertLess(
            fetch.index("[fileSizeValue isKindOfClass:NSNumber.class]"),
            fetch.index("[fileSizeValue unsignedLongLongValue]"),
        )

    def test_broker_suppresses_sigpipe_on_each_accepted_client(self) -> None:
        configuration = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(encoding="utf-8")
        accepted_client = configuration.split("int client = accept(server, NULL, NULL);", 1)[1].split(
            "@autoreleasepool", 1
        )[0]
        self.assertIn("SO_NOSIGPIPE", accepted_client)
        self.assertIn("setsockopt(client", accepted_client)

    def test_versioned_import_protocol_keeps_command_three_as_legacy(self) -> None:
        configuration = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(encoding="utf-8")
        self.assertIn("VCAMConfigurationBrokerLegacyImportCommand = 3", configuration)
        self.assertIn("VCAMConfigurationBrokerImportCommand = 5", configuration)
        client = configuration.split("+ (nullable NSString *)importMediaAtURL:", 1)[1].split(
            "+ (nullable NSString *)resolvedMediaPathForSharedPath:", 1
        )[0]
        self.assertIn("uint8_t command = VCAMConfigurationBrokerImportCommand", client)
        server = configuration.split("+ (void)startWriteBroker", 1)[1]
        self.assertIn("command == VCAMConfigurationBrokerLegacyImportCommand", server)
        self.assertIn("command == VCAMConfigurationBrokerImportCommand", server)
        self.assertIn("BOOL preflightRequired = command == VCAMConfigurationBrokerImportCommand", server)
        self.assertIn("if (preflightRequired)", server)

    def test_import_preserves_a_more_specific_local_transfer_error(self) -> None:
        configuration = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(encoding="utf-8")
        client = configuration.split("+ (nullable NSString *)importMediaAtURL:", 1)[1].split(
            "+ (nullable NSString *)resolvedMediaPathForSharedPath:", 1
        )[0]
        failure = client.rsplit("NSString *message =", 1)[1]
        self.assertIn("!success && transferMessage.length > 0", failure)
        self.assertIn("? transferMessage", failure)
        self.assertLess(failure.index("? transferMessage"), failure.index("message.length > 0"))

    def test_image_is_static_and_video_uses_incremental_reader_without_preload(self) -> None:
        source = (ROOT / "Sources" / "Sources" / "VCAMLocalMediaSource.m").read_text(encoding="utf-8")
        producer = (ROOT / "Sources" / "Daemon" / "VCAMFrameProducer.m").read_text(encoding="utf-8")
        self.assertIn("CGImageSourceCreateImageAtIndex", source)
        self.assertIn("_stillImage", source)
        self.assertIn("AVAssetReaderTrackOutput", source)
        self.assertIn("copyNextSampleBuffer", source)
        self.assertIn("AVAssetReaderStatusCompleted", source)
        self.assertIn("CMSampleBufferGetPresentationTimeStamp", source)
        self.assertIn("CMSampleBufferGetDuration", source)
        self.assertIn("CMTimeSubtract(nextDuePTS", source)
        self.assertIn("restartVideoReaderAfterEndAtHostTime", source)
        self.assertIn("self.configuration.loopMedia", source)
        self.assertIn("_currentVideoSample", source)
        self.assertIn("_lastRenderedVideoSample", source)
        self.assertIn("local reader ready", source)
        self.assertIn("local reader first-frame", source)
        self.assertIn("local reader failed", source)
        self.assertIn("local reader eof", source)
        reader_builder = source.split("- (BOOL)rebuildVideoReader:", 1)[1].split(
            "- (BOOL)advanceVideoFrame", 1
        )[0]
        self.assertEqual(reader_builder.count("assetReaderTrackOutputWithTrack"), 1)
        reader_playback = source.split("- (BOOL)startVideoReader:", 1)[1].split(
            "- (BOOL)hasVideoAsset", 1
        )[0]
        self.assertEqual(reader_playback.count("copyNextSampleBuffer"), 1)
        retained_frame_state = source.split("@interface VCAMLocalMediaSource () {", 1)[1].split("}", 1)[0]
        self.assertEqual(retained_frame_state.count("CMSampleBufferRef"), 3)
        self.assertIn("_lastRenderedStillSample", retained_frame_state)
        still_branch = source.split("if (_stillImage != NULL) {", 2)[2].split(
            "CMTime sourcePTS", 1
        )[0]
        self.assertIn("CMSampleBufferCreateCopyWithNewTiming", still_branch)
        self.assertIn("CMSampleBufferCreateCopy", still_branch)
        self.assertIn("cacheHit:YES", still_branch)
        self.assertIn("CACurrentMediaTime() - renderStart", still_branch)
        self.assertNotIn("AVPlayerItemVideoOutput", source)
        self.assertNotIn("tripleBGRAOutput", source)
        self.assertNotIn("tripleVideoRangeOutput", source)
        self.assertNotIn("tripleFullRangeOutput", source)
        self.assertNotIn("videoFrames", source)
        self.assertNotIn("videoFrames", producer)
        self.assertNotIn("NSMutableArray", producer)

    def test_heif_uses_the_primary_image_and_applies_embedded_orientation(self) -> None:
        source = (ROOT / "Sources" / "Sources" / "VCAMLocalMediaSource.m").read_text(
            encoding="utf-8"
        )

        self.assertIn("CGImageSourceGetPrimaryImageIndex", source)
        self.assertIn("CGImageSourceCreateThumbnailAtIndex", source)
        self.assertIn("kCGImageSourceCreateThumbnailFromImageAlways", source)
        self.assertIn("kCGImageSourceCreateThumbnailWithTransform", source)

    def test_photo_picker_normalizes_images_before_broker_import(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(
            encoding="utf-8"
        )
        callback = picker.split("didFinishPicking:", 1)[1].split(
            "- (void)promptForOnlineVideo", 1
        )[0]

        self.assertIn("loadObjectOfClass:UIImage.class", callback)
        self.assertIn("UIGraphicsImageRenderer", callback)
        self.assertIn("UIImageJPEGRepresentation", callback)
        self.assertIn('@"selected.jpg"', callback)
        self.assertIn("loadFileRepresentationForTypeIdentifier", callback)

    def test_video_reader_validates_the_first_frame_before_start_succeeds(self) -> None:
        source = (ROOT / "Sources" / "Sources" / "VCAMLocalMediaSource.m").read_text(encoding="utf-8")
        starter = source.split("- (BOOL)startVideoReader:", 1)[1].split(
            "- (BOOL)rebuildVideoReader:", 1
        )[0]
        self.assertIn("if (![self rebuildVideoReader:error]) return NO;", starter)
        self.assertIn("if ([self advanceVideoFrame]) return YES;", starter)
        self.assertIn("if ([self startFFmpegVideoReader:error]) return YES;", starter)
        self.assertIn("if ([self startFFmpegSoftwareReader:error]) return YES;", starter)
        self.assertIn("return [self startFFmpegHwaccelReader:error];", starter)
        self.assertLess(
            starter.index("startFFmpegSoftwareReader:error"),
            starter.index("startFFmpegHwaccelReader:error"),
        )
        self.assertIn("Unable to decode the first video frame", starter)
        self.assertLess(starter.index("rebuildVideoReader:error"), starter.index("advanceVideoFrame"))

        hwaccel = source.split("- (BOOL)advanceHwaccelFrame", 1)[1].split(
            "- (BOOL)startFFmpegVideoReader", 1
        )[0]
        self.assertIn("self.configuration.loopMedia &&", hwaccel)
        self.assertIn("_ffFirstFrameLogged", hwaccel)
        self.assertIn("av_err2str(sendResult)", hwaccel)

    def test_video_reader_uses_one_native_track_output_and_logs_first_sample_shape(self) -> None:
        source = (ROOT / "Sources" / "Sources" / "VCAMLocalMediaSource.m").read_text(encoding="utf-8")
        reader_builder = source.split("- (BOOL)rebuildVideoReader:", 1)[1].split(
            "- (BOOL)advanceVideoFrame", 1
        )[0]
        first_sample = source.split("- (BOOL)advanceVideoFrame", 1)[1].split(
            "- (CMTime)durationForCurrentVideoFrame", 1
        )[0]

        self.assertIn("AVAssetReaderTrackOutput *videoOutput", source)
        self.assertEqual(reader_builder.count("assetReaderTrackOutputWithTrack"), 1)
        self.assertIn("assetReaderTrackOutputWithTrack:videoTrack", reader_builder)
        self.assertIn("kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange", reader_builder)
        self.assertNotIn("kCVPixelFormatType_32BGRA", reader_builder)
        self.assertNotIn("AVAssetReaderVideoCompositionOutput", reader_builder)
        self.assertNotIn("videoComposition", reader_builder)
        self.assertIn("local reader first-sample", first_sample)
        for field in ("mediaSubtype=%08x", "hasImageBuffer=%d", "hasDataBuffer=%d", "outputClass=%@"):
            self.assertIn(field, first_sample)
        self.assertIn("sourceTransform:self.videoTransform", source)

    def test_video_reader_skips_only_a_bounded_number_of_non_pixel_markers(self) -> None:
        source = (ROOT / "Sources" / "Sources" / "VCAMLocalMediaSource.m").read_text(encoding="utf-8")
        advance = source.split("- (BOOL)advanceVideoFrame", 1)[1].split(
            "- (CMTime)durationForCurrentVideoFrame", 1
        )[0]

        self.assertIn("static const NSUInteger VCAMVideoNonPixelSampleSkipLimit = 32;", source)
        self.assertIn(
            "while (skippedNonPixelSamples < VCAMVideoNonPixelSampleSkipLimit)",
            advance,
        )
        self.assertEqual(advance.count("copyNextSampleBuffer"), 1)
        self.assertIn("kCMSampleBufferAttachmentKey_EmptyMedia", advance)
        self.assertIn("kCMSampleBufferAttachmentKey_PermanentEmptyMedia", advance)
        self.assertIn("CMSampleBufferGetNumSamples(sample)", advance)
        self.assertIn("CMSampleBufferDataIsReady(sample)", advance)
        skip_path = advance.split("if (pixelBuffer != NULL) break;", 1)[1].split(
            "if (sample == NULL || pixelBuffer == NULL)", 1
        )[0]
        self.assertIn("CFRelease(sample);", skip_path)
        self.assertIn("sample = NULL;", skip_path)
        self.assertIn("skippedNonPixelSamples += 1;", skip_path)
        self.assertNotIn("reportVideoReaderFailure", skip_path)
        self.assertIn("local reader skipped non-pixel sample", skip_path)
        self.assertIn("if (permanentEmptyMedia) break;", skip_path)

    def test_video_reader_rebases_after_two_catch_up_frames(self) -> None:
        source = (ROOT / "Sources" / "Sources" / "VCAMLocalMediaSource.m").read_text(encoding="utf-8")
        playback = source.split("- (CVPixelBufferRef)copyCurrentVideoPixelBufferForTemplate:", 1)[1].split(
            "- (BOOL)hasVideoAsset", 1
        )[0]
        self.assertIn("static const NSUInteger VCAMVideoCatchUpLimit = 1;", source)
        self.assertIn("while (catchUpCount < VCAMVideoCatchUpLimit)", playback)
        self.assertIn("if (catchUpCount == VCAMVideoCatchUpLimit)", playback)
        rebase = playback.split("if (catchUpCount == VCAMVideoCatchUpLimit)", 1)[1]
        self.assertIn("_videoHostStart = now;", rebase)
        self.assertIn("_videoMediaStartPTS = _currentVideoPTS;", rebase)

    def test_panel_connects_media_live_and_transform_actions(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")
        panel = (ROOT / "Sources" / "UI" / "VCAMControlPanelViewController.m").read_text(encoding="utf-8")
        for action in (
            "presentMediaPicker",
            "presentDocumentPicker",
            "promptForOnlineVideo",
            "promptForLiveStream",
            "rotateClockwise",
            "rotateCounterClockwise",
            "toggleMirror",
            "cycleContentMode",
            "enableVirtualCamera",
            "restoreRealCamera",
        ):
            self.assertIn(action, picker)
        self.assertIn(
            "PHPickerConfigurationAssetRepresentationModeCompatible", picker
        )
        self.assertNotIn(
            "PHPickerConfigurationAssetRepresentationModeCurrent", picker
        )
        for title in (
            "从相册选择",
            "从文件选择",
            "在线源下载",
            "输入直播流",
            "启用虚拟相机",
            "恢复真实相机",
        ):
            self.assertIn(title, panel)
        self.assertNotIn("选择替换软件和进程", panel)

    def test_obs_bridge_has_latest_frame_and_stale_fail_open(self) -> None:
        obs = (ROOT / "Sources" / "Sources" / "VCAMOBSStreamSource.m").read_text(encoding="utf-8")
        self.assertIn("NSURLSessionWebSocketTask", obs)
        self.assertIn("latestJPEG", obs)
        self.assertIn("latestFrameHostTime", obs)
        self.assertIn("< 3.5", obs)
        self.assertIn("return NULL", obs)

    def test_rtsp_consumes_tcp_continuously_and_converts_latest_clean_frame(self) -> None:
        rtsp = (ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m").read_text(encoding="utf-8")
        converter = (ROOT / "Sources" / "Daemon" / "VCAMPixelConverter.m").read_text(encoding="utf-8")
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn('av_dict_set(options, "rtsp_transport", "tcp"', rtsp)
        self.assertNotIn('"nobuffer"', rtsp)
        self.assertNotIn('"low_delay"', rtsp)
        self.assertNotIn('"reorder_queue_size"', rtsp)
        self.assertIn("AV_HWDEVICE_TYPE_VIDEOTOOLBOX", rtsp)
        self.assertIn("hardware session produced no frames; reconnecting", rtsp)
        self.assertIn("decodeOneHardwareSession", rtsp)
        self.assertIn("av_frame_clone", rtsp)
        self.assertIn("_pendingSoftwareFrame", rtsp)
        self.assertIn("conversionQueue", rtsp)
        self.assertIn("sendResult = avcodec_send_packet(codecContext, packet)", rtsp)
        self.assertIn("sendResult != AVERROR(EAGAIN)", rtsp)
        self.assertIn("retry this exact packet", rtsp)
        self.assertNotIn('"discardcorrupt"', rtsp)
        self.assertIn("AV_FRAME_FLAG_CORRUPT", rtsp)
        self.assertIn("AV_FRAME_FLAG_KEY", rtsp)
        self.assertIn("decode_error_flags", rtsp)
        self.assertIn("AV_PKT_FLAG_KEY", rtsp)
        self.assertIn("recoveryPacketLimit = 120", rtsp)
        self.assertIn("recoveryTimeLimit = 5.0", rtsp)
        self.assertIn('@"%@ key-frame recovery timed out', rtsp)
        self.assertIn("self.streamName", rtsp)
        self.assertIn("clean-key recovery exceeded five seconds", rtsp)
        self.assertIn("receive_frame ended", rtsp)
        self.assertIn("_latestPixelBuffer", rtsp)
        self.assertIn("< 3.5", rtsp)
        self.assertIn("VCAMCopyBGRAFromAVFrame", rtsp)
        self.assertIn("AV_PIX_FMT_YUV420P", converter)
        self.assertIn("AV_PIX_FMT_NV12", converter)
        self.assertIn("AV_PIX_FMT_YUV420P10LE", converter)
        self.assertIn("AV_PIX_FMT_P010LE", converter)
        self.assertIn("maximumDimension = 1920", converter)
        self.assertIn("kCVPixelBufferCGImageCompatibilityKey", converter)
        self.assertIn("kCVPixelBufferCGBitmapContextCompatibilityKey", converter)
        self.assertIn("vImageConvert_420Yp8_CbCr8ToARGB8888", converter)
        self.assertIn("vImageConvert_420Yp8_Cb8_Cr8ToARGB8888", converter)
        self.assertIn("vImageScale_ARGB8888", converter)
        self.assertIn("VCAMPixelConverter.m", makefile)
        self.assertIn("Sources/Sources/VCAMRTSPStreamSource.m", makefile)

    def test_portrait_decoded_video_uses_vimage_transform_instead_of_cgimage(self) -> None:
        converter = (ROOT / "Sources" / "Daemon" / "VCAMPixelConverter.m").read_text(
            encoding="utf-8"
        )
        renderer = (ROOT / "Sources" / "Core" / "VCAMFrameRenderer.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("VCAMRenderNV12PixelBufferToBGRA", converter)
        self.assertIn("VCAMRenderBGRAPixelBufferToBGRA", converter)
        self.assertIn("static BOOL VCAMRenderBGRABuffer", converter)
        self.assertIn("vImageRotate90_ARGB8888", converter)
        self.assertIn("vImageHorizontalReflect_ARGB8888", converter)
        self.assertIn("vImageVerticalReflect_ARGB8888", converter)
        self.assertIn("vImageScale_ARGB8888", converter)
        transformed = converter.split("static BOOL VCAMRenderBGRABuffer", 1)[1].split(
            "BOOL VCAMRenderBGRAPixelBufferToBGRA", 1
        )[0]
        self.assertIn("input.width == output.width", transformed)
        self.assertIn("memcpy", transformed)
        self.assertIn("kvImageNoFlags", transformed)
        self.assertNotIn("kvImageHighQualityResampling", transformed)
        self.assertIn("VCAMRenderNV12PixelBufferToBGRA", renderer)
        self.assertIn("VCAMRenderBGRAPixelBufferToBGRA", renderer)
        self.assertIn("sourceFormat == kCVPixelFormatType_32BGRA", renderer)
        self.assertLess(
            renderer.index("VCAMRenderBGRAPixelBufferToBGRA"),
            renderer.index("VTCreateCGImageFromCVPixelBuffer"),
        )

    def test_floating_dot_is_springboard_owned_and_accessible(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")
        panel = (ROOT / "Sources" / "UI" / "VCAMControlPanelViewController.m").read_text(encoding="utf-8")
        self.assertIn('NSClassFromString(@"SBIconController")', picker)
        self.assertIn("UIPanGestureRecognizer", picker)
        self.assertIn("numberOfTouchesRequired = 3", picker)
        self.assertIn("UIAccessibilityIsVoiceOverRunning", picker)
        self.assertIn("VCAMFloatingWindowIdentifier", picker)
        self.assertIn("installGestureOnWindowIfNeeded", picker)
        self.assertIn("UIWindowLevelStatusBar", picker)
        self.assertIn("presentPanelWithRemainingRetries", picker)
        self.assertIn("accessibilityLabel", panel)

    def test_three_finger_toggle_can_coexist_with_host_gestures(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(
            encoding="utf-8"
        )
        simultaneous = picker.split(
            "shouldRecognizeSimultaneouslyWithGestureRecognizer:", 1
        )[1].split("- (void)dragButton:", 1)[0]
        self.assertIn("VCAMGestureTagKey", simultaneous)
        self.assertIn("VCAMFloatingDotTag", simultaneous)
        self.assertIn("return", simultaneous)
        self.assertNotIn("return NO;", simultaneous)

    def test_hls_configuration_is_accepted_by_broker_and_cli(self) -> None:
        configuration = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(
            encoding="utf-8"
        )
        writer = (ROOT / "scripts" / "write-config.py").read_text(encoding="utf-8")
        allowed_keys = configuration.split("allowedPreferenceKeys", 1)[1].split(
            "+ (BOOL)validateChanges", 1
        )[0]
        self.assertIn('@"hlsURL"', allowed_keys)
        self.assertIn('"hls"', writer)
        self.assertIn('parser.add_argument("--hls-url")', writer)
        self.assertIn('values["hlsURL"] = args.hls_url', writer)

    def test_foreground_app_exclusively_owns_the_floating_dot(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("VCAMAppForegroundStateNotification", picker)
        self.assertIn("notify_set_state", picker)
        self.assertIn("notify_get_state", picker)
        self.assertIn("currentState == (uint64_t)getpid()", picker)
        self.assertIn("kill((pid_t)foregroundPID, 0)", picker)
        self.assertIn("VCAMForegroundAppIsAlive()", picker)
        self.assertIn("VCAMPickerPostAppActive(YES)", picker)
        self.assertIn("VCAMPickerPostAppActive(NO)", picker)
        self.assertIn("controller.hostResignedActive = foregroundAppActive", picker)

    def test_three_finger_visibility_is_global_across_ui_hosts(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(
            encoding="utf-8"
        )
        visibility = picker.split("- (BOOL)isFloatingButtonVisibleForValues:", 1)[1].split(
            "- (nullable NSValue *)savedFloatingButtonCenterForWindow:", 1
        )[0]
        toggle = picker.split("- (void)toggleFloatingButton:", 1)[1].split(
            "- (BOOL)gestureRecognizer:", 1
        )[0]
        self.assertIn('visibility[@"global"]', visibility)
        self.assertIn("return saved == nil ? YES : saved.boolValue", visibility)
        self.assertIn('visibility[@"global"] = @(!currentlyVisible)', toggle)

    def test_panel_shows_stream_health_and_hides_injection_targets(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(
            encoding="utf-8"
        )
        panel = (ROOT / "Sources" / "UI" / "VCAMControlPanelViewController.m").read_text(
            encoding="utf-8"
        )
        preview = (ROOT / "Sources" / "UI" / "VCAMSharedFramePreviewView.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("streamingStatus", picker)
        self.assertIn("已收到推流", picker)
        self.assertIn("未收到推流", picker)
        self.assertIn("推流状态", panel)
        self.assertIn("controlPanelDidRequestStatusRefresh", panel)
        self.assertNotIn("仅注入 mediaserverd 与 SpringBoard", picker)
        self.assertNotIn("麦克风保持真实输入", picker)
        self.assertIn("VCAMPreviewLastFrameHostTime", preview)

    def test_stream_health_reads_fresh_shared_metadata_without_copying_pixels(self) -> None:
        header = (ROOT / "Sources" / "Shared" / "VCAMSharedFrame.h").read_text(
            encoding="utf-8"
        )
        shared = (ROOT / "Sources" / "Shared" / "VCAMSharedFrame.m").read_text(
            encoding="utf-8"
        )
        preview = (ROOT / "Sources" / "UI" / "VCAMSharedFramePreviewView.m").read_text(
            encoding="utf-8"
        )
        status = preview.split("+ (NSDictionary<NSString *, id> *)streamingStatus", 1)[1].split(
            "+ (Class)layerClass", 1
        )[0]
        self.assertIn("VCAMSharedFrameReaderGetLatestMetadata", header)
        self.assertIn("VCAMSharedSurfaceReaderGetLatestMetadata", header)
        self.assertIn("VCAMSharedFrameReaderGetLatestMetadata", shared)
        self.assertIn("VCAMSharedSurfaceReaderGetLatestMetadata", shared)
        self.assertIn("VCAMSharedFrameReaderGetLatestMetadata", status)
        self.assertIn("VCAMSharedSurfaceReaderGetLatestMetadata", status)
        self.assertNotIn("VCAMSharedFrameReaderCopyLatest", status)
        self.assertNotIn("VCAMSharedSurfaceReaderCopyLatest", status)

    def test_stale_virtual_frames_render_black_after_timeout(self) -> None:
        image_utils = (ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefImageUtils.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("VCAMLastVirtualFrameHostTime", image_utils)
        self.assertIn("<= 2.5", image_utils)
        self.assertIn("virtual frame stale; rendering black instead of frozen frame", image_utils)

    def test_preview_displays_worker_oriented_pixels_without_a_second_transform(self) -> None:
        preview = (ROOT / "Sources" / "UI" / "VCAMSharedFramePreviewView.m").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("CGAffineTransformMakeScale", preview)
        self.assertNotIn("affineTransform", preview)
        self.assertNotIn("rotationDegrees", preview)

    def test_ui_only_notifications_do_not_reconnect_an_unchanged_rtsp_source(self) -> None:
        producer = (ROOT / "Sources" / "Daemon" / "VCAMFrameProducer.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("VCAMConfigurationsProduceSameFrames", producer)
        self.assertIn("sourceHealthy", producer)
        self.assertIn("reload skipped unchanged media configuration", producer)
        comparison = producer.split("VCAMConfigurationsProduceSameFrames", 1)[1].split(
            "@interface VCAMFrameProducer", 1
        )[0]
        for field in (
            "enabled",
            "loopMedia",
            "mirrorHorizontally",
            "rotationDegrees",
            "sourceKind",
            "contentMode",
            "preferredFramesPerSecond",
            "mediaPath",
            "obsWebSocketURL",
            "rtspURL",
        ):
            self.assertIn(field, comparison)

    def test_enable_and_restore_drive_shared_frame_active_state(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")
        header = (ROOT / "Sources" / "UI" / "VCAMControlPanelViewController.h").read_text(
            encoding="utf-8"
        )
        panel = (ROOT / "Sources" / "UI" / "VCAMControlPanelViewController.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("controlPanelDidRequestEnableVirtualCamera", header)
        self.assertIn("controlPanelDidRequestEnableVirtualCamera", panel)
        self.assertIn("controlPanelDidRequestEnableVirtualCamera", picker)
        self.assertIn('@"enabled": @YES', picker)
        self.assertIn('@"source": source', picker)
        self.assertNotIn('@"injectionMediaServerEnabled": @YES', picker)
        configuration = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(
            encoding="utf-8"
        )
        allowed_keys = configuration.split("allowedPreferenceKeys", 1)[1].split(
            "+ (BOOL)validateChanges", 1
        )[0]
        self.assertIn('@"enabled"', allowed_keys)
        self.assertIn('@"source"', allowed_keys)
        for configured_source_check in ("BOOL hasRTSP", "BOOL hasOBS", "BOOL hasLocalMedia"):
            self.assertIn(configured_source_check, picker)
        self.assertIn('updatePreferences:@{@"enabled": @NO}', picker)
        self.assertNotIn('@"source": @"camera", @"enabled": @NO', picker)
        self.assertIn('CFSTR("com.codex.vcam/preferences.changed")', picker)
        self.assertIn("VCAMSharedFrameSetRequestedActive", configuration)
        self.assertIn("!VCAMSynchronizeSharedRequestedState(readBack, error)", configuration)


if __name__ == "__main__":
    unittest.main()
