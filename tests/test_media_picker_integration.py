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
        self.assertIn("importMediaFromURL", picker)
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
        self.assertIn("preferredExtension", selector)
        self.assertIn("[extension isEqualToString:preferredExtension]", selector)
        self.assertIn("registeredType.preferredFilenameExtension", selector)
        self.assertIn("VCAMIsSupportedMediaExtension", selector)
        self.assertLess(
            selector.index("VCAMIsSupportedMediaExtension"),
            selector.index("return supportedIdentifier"),
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
            "success = success && command == VCAMConfigurationBrokerUpdateCommand", 1
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
            "success = success && command == VCAMConfigurationBrokerUpdateCommand", 1
        )[0]
        self.assertIn("NSDictionary<NSString *, id> *headerDictionary", server)
        self.assertNotIn('header[@"suggestedName"]', server)
        self.assertNotIn('header[@"fileSize"]', server)

    def test_media_path_never_uses_the_broker_as_a_file_read_oracle(self) -> None:
        configuration = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(encoding="utf-8")
        fetch = configuration.split("+ (nullable NSString *)resolvedMediaPathForSharedPath:", 1)[1].split(
            "+ (void)startWriteBroker", 1
        )[0]
        self.assertIn("VCAMMediaPathIsAllowed(sharedPath)", fetch)
        self.assertNotIn("dataWithContentsOfFile", fetch)
        self.assertNotIn("BrokerFetchMediaCommand", configuration)

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
        self.assertIn("kCGImagePropertyPixelWidth", source)
        self.assertIn("kCGImagePropertyPixelHeight", source)
        self.assertIn("MAX(sourceWidth, sourceHeight)", source)
        self.assertIn("kCGImageSourceThumbnailMaxPixelSize: @(sourceMaximumDimension)", source)
        self.assertNotIn("maximumDecodedPixels", source)
        self.assertNotIn("MIN((NSUInteger)8192", source)

    def test_static_images_use_one_native_surface_and_reset_old_user_transforms(self) -> None:
        producer = (ROOT / "Sources" / "Daemon" / "VCAMFrameProducer.m").read_text(
            encoding="utf-8"
        )
        daemon = (ROOT / "Sources" / "Daemon" / "main.m").read_text(
            encoding="utf-8"
        )
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(
            encoding="utf-8"
        )
        install = picker.split("- (void)importMediaFromURL:", 1)[1].split(
            "- (void)rotateClockwise", 1
        )[0]
        self.assertIn("slotCount = 1", producer)
        self.assertIn("VCAMSharedSurfaceWriterRefreshLatest", daemon)
        self.assertIn('@"rotationDegrees": @0', install)
        self.assertIn('@"mirrorHorizontally": @NO', install)
        live = picker.split("- (void)promptForLiveStream", 1)[1].split(
            "- (NSUInteger)beginMediaSelection", 1
        )[0]
        self.assertIn('@"rotationDegrees": @0', live)
        self.assertIn('@"mirrorHorizontally": @NO', live)

    def test_async_media_selection_is_backgrounded_main_committed_and_last_wins(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("mediaSelectionGeneration", picker)
        self.assertIn("NSUInteger generation = [self beginMediaSelection]", picker)
        self.assertIn("generation != self.mediaSelectionGeneration", picker)
        self.assertIn("dispatch_get_global_queue(QOS_CLASS_UTILITY, 0)", picker)
        importer = picker.split("- (void)importMediaFromURL:", 1)[1].split(
            "- (void)activateImportedMediaAtPath:", 1
        )[0]
        self.assertIn("preferredFramesPerSecondForMediaPath", importer)
        self.assertIn("dispatch_async(dispatch_get_main_queue()", importer)
        activation = picker.split("- (void)activateImportedMediaAtPath:", 1)[1].split(
            "- (void)rotateClockwise", 1
        )[0]
        self.assertNotIn("tracksWithMediaType", activation)
        self.assertIn("generation != self.mediaSelectionGeneration", activation)

    def test_dynamic_iosurface_metadata_carries_source_dimensions_and_slot_depth(self) -> None:
        shared = (ROOT / "Sources" / "Shared" / "VCAMSharedFrame.m").read_text(
            encoding="utf-8"
        )
        header = (ROOT / "Sources" / "Shared" / "VCAMSharedFrame.h").read_text(
            encoding="utf-8"
        )
        self.assertIn("VCAMSharedSurfaceVersion = 8", shared)
        self.assertIn("producerStartToken", shared)
        self.assertIn("consumerStartToken", shared)
        self.assertIn("VCAMSharedSurfaceWriterCreateConfigured", header)
        broker_header = (ROOT / "Sources" / "Shared" / "VCAMSurfaceBroker.h").read_text(
            encoding="utf-8"
        )
        self.assertIn("count == VCAMSurfaceBrokerStaticSlotCount", broker_header)
        self.assertIn("count == VCAMSurfaceBrokerVideoSlotCount", broker_header)
        self.assertIn("SlotCountIsValid(uint64_t count)", broker_header)
        self.assertIn("VCAMSurfaceBrokerSlotCountIsValid(header->slotCount)", shared)
        self.assertIn("VCAMSurfaceBrokerSlotCountIsValid(slotCount)", shared)
        self.assertNotIn("header->width > 8192", shared)
        self.assertIn("kIOSurfacePixelFormat: @(pixelFormat)", shared)
        self.assertIn("metadata->width = width", shared)
        self.assertIn("frame->metadata = surfaceMetadata", shared)
        self.assertIn("metadata->surfaceGeneration = generation", shared)
        self.assertIn("slotColorPrimaries", shared)
        self.assertIn("slotTransferFunction", shared)
        self.assertIn("slotYCbCrMatrix", shared)
        self.assertIn("VCAMApplyColorMetadata(pixelBuffer, &surfaceMetadata)", shared)
        self.assertIn("uint32_t surfaceID", header)
        release = shared.split("void VCAMSharedSurfaceFrameRelease", 1)[1]
        self.assertIn("VCAMSharedSurfaceReleaseUse", release)
        self.assertIn("frame->surfaceID", release)

    def test_obs_video_uses_source_sized_three_slot_surface(self) -> None:
        producer = (ROOT / "Sources" / "Daemon" / "VCAMFrameProducer.m").read_text(
            encoding="utf-8"
        )
        obs = (ROOT / "Sources" / "Sources" / "VCAMOBSStreamSource.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("BOOL nativeOBS", producer)
        self.assertIn("[obs copyLatestImage]", producer)
        self.assertIn("CGImageGetWidth(image)", producer)
        self.assertIn("copySampleFromCGImage:image", producer)
        self.assertIn("- (CGImageRef)copyLatestImage", obs)
        self.assertEqual(obs.count("jpeg = self.latestJPEG"), 1)

    def test_mmap_is_only_a_fresh_bootstrap_for_a_new_surface_generation(self) -> None:
        image_utils = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefImageUtils.m"
        ).read_text(encoding="utf-8")
        shared = (ROOT / "Sources" / "Shared" / "VCAMSharedFrame.m").read_text(
            encoding="utf-8"
        )
        daemon = (ROOT / "Sources" / "Daemon" / "main.m").read_text(
            encoding="utf-8"
        )
        bridge = (
            ROOT / "Sources" / "SpringBoard" / "VCAMSpringBoardMediaBridge.m"
        ).read_text(encoding="utf-8")
        self.assertIn("VCAMAdoptedSurfaceGeneration", image_utils)
        self.assertIn("currentSurface.surfaceGeneration !=", image_utils)
        self.assertIn("allowMmapBootstrap && VCAMSharedFrameReaderCopyLatest", image_utils)
        self.assertNotIn("VCAMReader, scratch, 0, &metadata", image_utils)
        self.assertIn("VCAMAdoptedSurfaceGeneration = metadata.surfaceGeneration", image_utils)
        self.assertIn("currentSurface.surfaceGeneration ==", image_utils)
        self.assertIn("metadata.surfaceGeneration != 0", image_utils)
        self.assertIn("VCAMLegacyMmapCutoffNanoseconds", image_utils)
        self.assertIn("metadata.monotonicTimestampNanoseconds >=", image_utils)
        self.assertIn("VCAMAdoptedSurfaceGeneration = 0", image_utils)
        self.assertIn("slotSurfaceGeneration", shared)
        self.assertIn("VCAMSharedFrameWriterPublishForSurfaceGeneration", daemon)
        self.assertIn("VCAMSharedFrameWriterPublishForSurfaceGeneration", bridge)

    def test_rtsp_transform_uses_the_same_native_frame_for_size_and_render(self) -> None:
        producer = (ROOT / "Sources" / "Daemon" / "VCAMFrameProducer.m").read_text(
            encoding="utf-8"
        )
        rtsp_branch = producer.split("VCAMRTSPStreamSource *rtsp", 1)[1].split(
            "- (NSInteger)preferredFramesPerSecond", 1
        )[0]
        self.assertIn("copySampleFromPixelBuffer:native", rtsp_branch)
        self.assertNotIn("copyVideoSampleForTemplate", rtsp_branch)

    def test_photo_picker_preserves_the_original_file_representation(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(
            encoding="utf-8"
        )
        callback = picker.split("didFinishPicking:", 1)[1].split(
            "- (void)promptForOnlineVideo", 1
        )[0]

        self.assertIn("loadFileRepresentationForTypeIdentifier", callback)
        self.assertIn("VCAMNormalizedMediaName(suggestedName, url, mediaType)", callback)
        self.assertNotIn("loadObjectOfClass:UIImage.class", callback)
        self.assertNotIn("UIGraphicsImageRenderer", callback)
        self.assertNotIn("UIImageJPEGRepresentation", callback)
        self.assertIn("PHPickerConfigurationAssetRepresentationModeCurrent", picker)
        self.assertNotIn("PHPickerConfigurationAssetRepresentationModeCompatible", picker)

    def test_each_import_gets_a_new_path_and_old_imports_are_bounded(self) -> None:
        configuration = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(
            encoding="utf-8"
        )
        receiver = configuration.split(
            "+ (nullable NSString *)receiveImportedMediaFromClient:", 1
        )[1].split("+ (nullable NSString *)importMediaAtURL:", 1)[0]

        self.assertIn('[@"selected-" stringByAppendingString:NSUUID.UUID.UUIDString]', receiver)
        self.assertIn("VCAMPruneImportedMediaFiles", receiver)
        self.assertNotIn('[NSString stringWithFormat:@"selected.%@", extension]', receiver)

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
            "PHPickerConfigurationAssetRepresentationModeCurrent", picker
        )
        self.assertNotIn(
            "PHPickerConfigurationAssetRepresentationModeCompatible", picker
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
        self.assertNotIn("hardware session produced no frames; reconnecting", rtsp)
        session = rtsp.split("- (BOOL)decodeOneSession", 1)[1].split(
            "- (BOOL)consumeFFmpegFrame", 1
        )[0]
        self.assertNotIn("decodeOneHardwareSession", session)
        self.assertIn("decodeOneFFmpegSession", session)
        self.assertNotIn("avcodec_get_hw_config", rtsp)
        self.assertIn("AV_PIX_FMT_VIDEOTOOLBOX", rtsp)
        self.assertIn("av_frame_clone", rtsp)
        self.assertIn("_pendingSoftwareFrame", rtsp)
        self.assertIn("conversionQueue", rtsp)
        self.assertIn("sendResult = avcodec_send_packet(codecContext, feedPacket)", rtsp)
        self.assertIn("sendResult != AVERROR(EAGAIN)", rtsp)
        self.assertIn("retry this exact packet", rtsp)
        self.assertNotIn('"discardcorrupt"', rtsp)
        self.assertIn("AV_FRAME_FLAG_CORRUPT", rtsp)
        self.assertIn("decode_error_flags", rtsp)
        self.assertIn("self.streamName", rtsp)
        self.assertIn("receive_frame ended", rtsp)
        self.assertIn("_latestPixelBuffer", rtsp)
        self.assertIn("< 3.5", rtsp)
        self.assertIn("VCAMCopyBGRAFromAVFrame", rtsp)
        self.assertIn("AV_PIX_FMT_YUV420P", converter)
        self.assertIn("AV_PIX_FMT_NV12", converter)
        self.assertIn("AV_PIX_FMT_YUV420P10LE", converter)
        self.assertIn("AV_PIX_FMT_P010LE", converter)
        self.assertNotIn("maximumDimension = 1920", converter)
        self.assertIn("int outputWidth = frame->width", converter)
        self.assertIn("int outputHeight = frame->height", converter)
        self.assertIn("VCAMSourceSizedVideoPipelineBudget", converter)
        self.assertIn("VCAMSourceSizedVideoBGRACopies = 8ULL", converter)
        self.assertIn("256ULL * 1024ULL * 1024ULL", converter)
        self.assertNotIn("VCAMScaleBGRAInPlace", converter)
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
        self.assertIn("window.rootViewController = rootController", picker)
        self.assertIn("floatingWindow.rootViewController.view", picker)
        self.assertIn("presentPanelWithRemainingRetries", picker)
        self.assertIn("accessibilityLabel", panel)

    def test_floating_dot_saves_the_window_center_and_migrates_buggy_top_left_state(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(
            encoding="utf-8"
        )
        saved = picker.split("- (nullable NSValue *)savedFloatingButtonCenterForWindow:", 1)[1].split(
            "- (void)saveFloatingButtonPositionInWindow:", 1
        )[0]
        write = picker.split("- (void)saveFloatingButtonPositionInWindow:", 1)[1].split(
            "- (void)installButtonWhenWindowIsReady", 1
        )[0]
        self.assertIn("legacyTopLeftX", saved)
        self.assertIn("legacyTopLeftY", saved)
        self.assertIn("self.floatingWindow.center.x", write)
        self.assertIn("self.floatingWindow.center.y", write)
        self.assertNotIn("self.button.center.x", write)
        self.assertNotIn("self.button.center.y", write)

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
        self.assertIn("VCAMSharedSurfaceReaderGetLatestMetadata", preview)

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
        latest_metadata = preview.split("static BOOL VCAMPreviewGetLatestMetadata", 1)[1].split(
            "@implementation VCAMSharedFramePreviewView", 1
        )[0]
        self.assertIn("VCAMSharedFrameReaderGetLatestMetadata", header)
        self.assertIn("VCAMSharedSurfaceReaderGetLatestMetadata", header)
        self.assertIn("VCAMSharedFrameReaderGetLatestMetadata", shared)
        self.assertIn("VCAMSharedSurfaceReaderGetLatestMetadata", shared)
        self.assertIn("VCAMSharedFrameReaderGetLatestMetadata", latest_metadata)
        self.assertIn("VCAMSharedSurfaceReaderGetLatestMetadata", latest_metadata)
        self.assertIn("VCAMPreviewGetLatestMetadata", status)
        self.assertNotIn("VCAMSharedFrameReaderCopyLatest", status)
        self.assertNotIn("VCAMSharedSurfaceReaderCopyLatest", status)
        self.assertNotIn("VCAMSharedSurfaceReaderSetReady", status)
        self.assertNotIn("consumerUseState", status)
        self.assertIn("NSAssert(NSThread.isMainThread", status)
        self.assertNotIn("VCAMPreviewSeenFrame", preview)
        self.assertNotIn("VCAMPreviewLastFrameHostTime", preview)

        frame_metadata = shared.split(
            "bool VCAMSharedFrameReaderGetLatestMetadata", 1
        )[1].split("bool VCAMSharedFrameReaderCopyLatest", 1)[0]
        frame_copy = shared.split("bool VCAMSharedFrameReaderCopyLatest", 1)[1].split(
            "static bool VCAMSharedSurfaceHeaderIsValid", 1
        )[0]
        surface_metadata = shared.split(
            "bool VCAMSharedSurfaceReaderGetLatestMetadata", 1
        )[1].split("bool VCAMSharedSurfaceReaderCopyLatest", 1)[0]
        surface_copy = shared.split("bool VCAMSharedSurfaceReaderCopyLatest", 1)[1].split(
            "VCAMSharedSurfaceReaderFailure VCAMSharedSurfaceReaderLastFailure", 1
        )[0]
        self.assertIn("VCAMSharedFrameReaderGetSnapshot", frame_metadata)
        self.assertIn("VCAMSharedFrameReaderGetSnapshot", frame_copy)
        self.assertIn("VCAMSharedSurfaceReaderGetSnapshot", surface_metadata)
        self.assertIn("VCAMSharedSurfaceReaderGetSnapshot", surface_copy)
        self.assertIn(
            "reader == NULL || !VCAMSharedSurfaceReaderEnsureMapped(reader)",
            surface_copy,
        )
        self.assertNotIn("publishedTimestampNanoseconds", frame_metadata)
        self.assertNotIn("publishedTimestampNanoseconds", frame_copy)
        self.assertNotIn("publishedTimestampNanoseconds", surface_metadata)
        self.assertNotIn("publishedTimestampNanoseconds", surface_copy)

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

    def test_preview_follows_the_newest_mmap_or_iosurface_producer(self) -> None:
        preview = (ROOT / "Sources" / "UI" / "VCAMSharedFramePreviewView.m").read_text(
            encoding="utf-8"
        )
        display_tick = preview.split("- (void)displayTick:", 1)[1].split("\n}\n\n@end", 1)[0]
        latest_metadata = preview.split("static BOOL VCAMPreviewGetLatestMetadata", 1)[1].split(
            "@implementation VCAMSharedFramePreviewView", 1
        )[0]
        streaming_status = preview.split(
            "+ (NSDictionary<NSString *, id> *)streamingStatus", 1
        )[1].split("+ (Class)layerClass", 1)[0]

        self.assertIn("VCAMSharedSurfaceReader *_surfaceReader", preview)
        self.assertIn("VCAMSharedFrameReaderGetLatestMetadata", latest_metadata)
        self.assertIn("VCAMSharedSurfaceReaderGetLatestMetadata", latest_metadata)
        self.assertIn("surfaceMetadata.monotonicTimestampNanoseconds >=", latest_metadata)
        self.assertIn("VCAMPreviewGetLatestMetadata", display_tick)
        self.assertIn("VCAMPreviewGetLatestMetadata", streaming_status)
        self.assertIn("VCAMSharedSurfaceReaderCopyLatestPassive", display_tick)
        self.assertIn("VCAMSharedSurfaceFrameRelease", display_tick)
        self.assertIn("frameWasSurface == self.lastFrameWasSurface", display_tick)
        self.assertIn("metadata.surfaceGeneration == self.lastSurfaceGeneration", display_tick)
        self.assertIn("self.lastSurfaceGeneration = metadata.surfaceGeneration", display_tick)
        self.assertIn("pixelFormat != _formatPixelFormat", display_tick)
        self.assertLess(
            display_tick.index("[layer enqueueSampleBuffer:sample]"),
            display_tick.index("self.lastSequence = metadata.sequence"),
        )

        shared = (ROOT / "Sources" / "Shared" / "VCAMSharedFrame.m").read_text(
            encoding="utf-8"
        )
        passive_copy = shared.split("bool VCAMSharedSurfaceReaderCopyLatestPassive", 1)[1].split(
            "VCAMSharedSurfaceReaderFailure VCAMSharedSurfaceReaderLastFailure", 1
        )[0]
        self.assertIn("VCAMSharedSurfaceReaderCopyLatestInternal", passive_copy)
        self.assertIn("false", passive_copy)
        clear_ready = shared.split("static void VCAMSharedSurfaceReaderSetReady", 1)[1].split(
            "void VCAMSharedSurfaceReaderDestroy", 1
        )[0]
        self.assertLess(clear_ready.index("(int32_t)getpid()"), clear_ready.index("consumerReady, 0"))

    def test_status_reports_measured_source_fps_instead_of_configured_fps(self) -> None:
        preview = (ROOT / "Sources" / "UI" / "VCAMSharedFramePreviewView.m").read_text(
            encoding="utf-8"
        )
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(
            encoding="utf-8"
        )
        streaming_status = preview.split(
            "+ (NSDictionary<NSString *, id> *)streamingStatus", 1
        )[1].split("+ (Class)layerClass", 1)[0]
        current_status = picker.split(
            "- (NSDictionary<NSString *, NSString *> *)currentStatus", 1
        )[1].split("- (void)showSourceMenu:", 1)[0]

        self.assertIn("metadata.sequence - lastSequence", streaming_status)
        self.assertIn("surfaceGeneration != lastSurfaceGeneration", streaming_status)
        self.assertIn('@"fps": @(measuredFPS)', streaming_status)
        self.assertIn('streamStatus[@"fps"]', current_status)
        self.assertNotIn('values[@"preferredFramesPerSecond"]', current_status)
        self.assertNotIn("VCAMPreviewWindowFrames", preview)

    def test_static_images_are_not_reported_as_fps_streams(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(
            encoding="utf-8"
        )
        current_status = picker.split(
            "- (NSDictionary<NSString *, NSString *> *)currentStatus", 1
        )[1].split("- (void)showSourceMenu:", 1)[0]

        self.assertIn("BOOL staticImage", current_status)
        self.assertIn('detail = [detail stringByAppendingString:@"\\n静态图片"]', current_status)
        self.assertIn('streamText = @"已加载静态图片"', current_status)
        self.assertLess(current_status.index("if (staticImage)"), current_status.index('streamStatus[@"fps"]'))

    def test_sandboxed_app_preview_falls_back_to_springboard_broker(self) -> None:
        configuration_header = (
            ROOT / "Sources" / "Core" / "VCAMConfiguration.h"
        ).read_text(encoding="utf-8")
        configuration = (
            ROOT / "Sources" / "Core" / "VCAMConfiguration.m"
        ).read_text(encoding="utf-8")
        preview = (
            ROOT / "Sources" / "UI" / "VCAMSharedFramePreviewView.m"
        ).read_text(encoding="utf-8")

        self.assertIn("VCAMConfigurationBrokerPreviewCommand", configuration)
        self.assertIn("copyPreviewSnapshotFromBroker", configuration_header)
        self.assertIn("VCAMSharedSurfaceReaderCopyLatestPassive", configuration)
        self.assertIn("UIImageJPEGRepresentation", configuration)
        self.assertIn("requestBrokerPreviewIfNeeded", preview)
        self.assertIn("dispatch_get_global_queue", preview)
        self.assertIn("brokerImageView", preview)
        self.assertNotIn(
            "(_reader == NULL && _surfaceReader == NULL) || _pixelBufferPool == NULL",
            preview,
        )

    def test_large_static_images_use_source_sized_springboard_surface(self) -> None:
        bridge = (
            ROOT / "Sources" / "SpringBoard" / "VCAMSpringBoardMediaBridge.m"
        ).read_text(encoding="utf-8")
        static_surface = bridge.split("- (BOOL)startStaticImage:", 1)[1].split(
            "- (void)refreshStaticImage:", 1
        )[0]

        self.assertIn("MAX(width, height)", static_surface)
        self.assertIn("outputWidth, outputHeight, kCVPixelFormatType_32BGRA, 1", static_surface)
        self.assertNotIn("8192", static_surface)
        self.assertNotIn("16000000", static_surface)

    def test_unadopted_video_surface_is_probed_instead_of_rendered_every_frame(self) -> None:
        bridge = (
            ROOT / "Sources" / "SpringBoard" / "VCAMSpringBoardMediaBridge.m"
        ).read_text(encoding="utf-8")
        tick = bridge.split("- (void)tick:", 1)[1].split(
            "- (NSDictionary<NSString *, id> *)healthSnapshot", 1
        )[0]

        self.assertIn("VCAMSurfaceHandshakeProbeIntervalNanoseconds", bridge)
        self.assertIn("surfaceProbeDue", tick)
        self.assertIn("surfaceConsumerReady || surfaceProbeDue", tick)
        self.assertIn("useSurfaceDestination && destination == NULL", tick)
        self.assertIn("lastSurfaceProbeTimestampNanoseconds = now", tick)
        self.assertIn("VCAMSharedFrameWriterPublishForSurfaceGeneration", tick)
        self.assertIn("VCAMSharedSurfaceWriterGeneration(self.surfaceWriter)", tick)

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


    def test_configuration_schema_rejects_wrong_types_and_sanitizes_disk_values(self) -> None:
        configuration = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("VCAMConfigurationValueIsValid", configuration)
        self.assertIn("VCAMSanitizedConfigurationValues", configuration)
        self.assertIn("number >= 1 && number <= 60", configuration)
        self.assertIn("配置值类型或范围无效", configuration)
        self.assertGreaterEqual(configuration.count("VCAMSanitizedConfigurationValues(values)"), 3)

    def test_stream_health_never_waits_for_the_broker_on_the_main_thread(self) -> None:
        preview = (ROOT / "Sources" / "UI" / "VCAMSharedFramePreviewView.m").read_text(
            encoding="utf-8"
        )
        status = preview.split("+ (NSDictionary<NSString *, id> *)streamingStatus", 1)[1].split(
            "+ (Class)layerClass", 1
        )[0]
        broker_call = status.index("copyPreviewSnapshotFromBroker")
        background = status.rfind("dispatch_async(dispatch_get_global_queue", 0, broker_call)
        self.assertGreaterEqual(background, 0)
        self.assertIn("brokerStatusFetchInFlight", status)
        self.assertIn('removeObjectForKey:@"jpegData"', status)

    def test_loopback_broker_has_a_short_handshake_timeout(self) -> None:
        configuration = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(
            encoding="utf-8"
        )
        broker = configuration.split("+ (void)startWriteBroker", 1)[1].split(
            "+ (instancetype)loadCurrent", 1
        )[0]
        self.assertIn("struct timeval clientTimeout = {.tv_sec = 2", broker)
        self.assertIn("clientTimeout.tv_sec = 30;", broker)
        self.assertNotIn(".tv_sec = 120", broker)
        self.assertNotIn("VCAMSurfaceBrokerValidateConfigurationToken", configuration)
        # Token authentication removed (0.8.80 parity — loopback trust).
        self.assertNotIn("broker rejected unauthenticated loopback client", broker)
        connect = configuration.split("+ (int)connectedBrokerSocket", 1)[1].split(
            "+ (NSDictionary<NSString *, id> *)copyValuesFromBroker", 1
        )[0]
        # Token path removed (0.8.80 parity — loopback without token).
        self.assertNotIn("VCAMSurfaceBrokerCopyConfigurationToken", connect)
        self.assertNotIn("VCAMWriteAll(descriptor, token, sizeof(token))", connect)

    def test_broker_tokens_are_xpc_issued_single_use_and_concurrent_safe(self) -> None:
        broker = (ROOT / "Sources" / "Shared" / "VCAMSurfaceBroker.m").read_text(
            encoding="utf-8"
        )
        server = (ROOT / "Sources" / "Daemon" / "VCAMSurfaceBrokerServer.m").read_text(
            encoding="utf-8"
        )
        self.assertIn('"config-auth"', broker)
        self.assertIn("xpc_connection_send_message_with_reply_sync", broker)
        self.assertIn('"config-auth-consume"', broker)
        self.assertIn("VCAMSurfaceBrokerValidateConfigurationToken", broker)
        # config-auth no longer gates on peer identity (CanControl removed):
        # tokens are 10s single-use and only unlock the SpringBoard broker.
        self.assertNotIn("VCAMSurfaceBrokerPeerCanControl", server)
        self.assertIn("config-auth issued pid", server)
        self.assertIn("VCAMConfigurationTokenCapacity = 16", server)
        self.assertIn("VCAMSurfaceBrokerStoreConfigurationToken", server)
        self.assertIn("VCAMSurfaceBrokerConsumeConfigurationToken", server)
        self.assertIn("memset(token, 0, sizeof(*token))", server)
        self.assertIn("VCAMSurfaceBrokerPeerIdentitySpringBoard", server)

    def test_surface_writer_claims_a_slot_before_rendering(self) -> None:
        shared = (ROOT / "Sources" / "Shared" / "VCAMSharedFrame.m").read_text(
            encoding="utf-8"
        )
        copy_next = shared.split("VCAMSharedSurfaceWriterCopyNextPixelBuffer", 1)[1].split(
            "VCAMSharedSurfaceWriterPublish", 1
        )[0]
        self.assertIn("atomic_compare_exchange_strong_explicit", copy_next)
        self.assertIn("VCAMSharedSurfaceUseState(surfaceID, UINT32_MAX)", copy_next)
        self.assertLess(
            copy_next.index("atomic_compare_exchange_strong_explicit"),
            copy_next.index("slotSequence[slot], 0"),
        )

    def test_configuration_write_rolls_back_before_notifying(self) -> None:
        configuration = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(
            encoding="utf-8"
        )
        write = configuration.split("+ (BOOL)writeValuesDirectly", 1)[1].split(
            "+ (BOOL)submitChangesToBroker", 1
        )[0]
        self.assertIn("previousValues", write)
        self.assertIn("previousFileExisted && previousData == nil", write)
        self.assertIn("existing config backup unreadable", write)
        self.assertIn("rolled back restored=", write)
        self.assertLess(write.index("if (!written)"), write.index("CFNotificationCenterPostNotification"))

    def test_static_images_have_an_explicit_source_sized_memory_budget(self) -> None:
        bridge = (ROOT / "Sources" / "SpringBoard" / "VCAMSpringBoardMediaBridge.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("VCAMStaticImageMaximumSurfaceBytes", bridge)
        self.assertIn("pixelCount > VCAMStaticImageMaximumSurfaceBytes / 4ULL", bridge)
        self.assertIn("(uint64_t)transformedWidth * (uint64_t)transformedHeight", bridge)
        self.assertIn("exceeds the 64 MiB source-sized surface budget", bridge)

    def test_files_import_does_not_block_the_springboard_main_thread(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(
            encoding="utf-8"
        )
        delegate = picker.split("didPickDocumentsAtURLs:", 1)[1].split(
            "- (void)picker:(PHPickerViewController *)picker", 1
        )[0]
        self.assertIn("QOS_CLASS_UTILITY", delegate)
        self.assertIn("importMediaFromURL", delegate)
        importer = picker.split("- (void)importMediaFromURL:", 1)[1].split(
            "- (void)activateImportedMediaAtPath:", 1
        )[0]
        self.assertIn("importMediaAtURL", importer)
        self.assertIn("dispatch_get_main_queue()", importer)
        self.assertLess(importer.index("importMediaAtURL"), importer.index("dispatch_get_main_queue()"))

    def test_imports_do_not_block_control_and_never_prune_the_active_media(self) -> None:
        configuration = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(
            encoding="utf-8"
        )
        prune = configuration.split("static void VCAMPruneImportedMediaFiles", 1)[1].split(
            "static NSString *VCAMDiagnosticsLogPath", 1
        )[0]
        self.assertIn("activePath", prune)
        self.assertIn("[path isEqualToString:activePath]", prune)
        receiver = configuration.split("+ (nullable NSString *)receiveImportedMediaFromClient", 1)[1].split(
            "+ (nullable NSString *)importMediaAtURL", 1
        )[0]
        self.assertIn("VCAMConfiguration.configurationPath", receiver)
        self.assertIn('persisted[@"mediaPath"]', receiver)
        broker = configuration.split("+ (void)startWriteBroker", 1)[1].split(
            "+ (instancetype)loadCurrent", 1
        )[0]
        self.assertIn('"com.codex.vcam.configuration.import"', broker)
        self.assertIn("dispatch_async(importQueue", broker)
        self.assertLess(broker.index("dispatch_async(importQueue"), broker.index("continue;", broker.index("dispatch_async(importQueue")))

    def test_online_download_is_stream_capped_and_supersedable(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("NSURLSessionDownloadDelegate", picker)
        self.assertIn("VCAMOnlineMediaMaximumBytes", picker)
        self.assertIn("VCAMOnlineMediaReserveBytes", picker)
        self.assertIn("totalBytesWritten > VCAMOnlineMediaMaximumBytes", picker)
        self.assertIn("[downloadTask cancel]", picker)
        selection = picker.split("- (NSUInteger)beginMediaSelection", 1)[1].split(
            "- (NSInteger)preferredFramesPerSecondForMediaPath", 1
        )[0]
        self.assertIn("[self.onlineDownloadTask cancel]", selection)
        self.assertIn("self.button.enabled = YES", selection)

    def test_hls_catches_up_only_after_sustained_live_edge_lag(self) -> None:
        bridge = (ROOT / "Sources" / "SpringBoard" / "VCAMSpringBoardMediaBridge.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("self.consecutiveHighLiveLagTicks >= 90", bridge)
        self.assertIn("CMTimeRangeGetEnd", bridge)
        self.assertIn("springboard HLS live-edge catch-up", bridge)

    def test_diagnostic_logs_are_bounded(self) -> None:
        configuration = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(
            encoding="utf-8"
        )
        mediaserver = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefImageUtils.m"
        ).read_text(encoding="utf-8")
        self.assertIn("VCAMAppendBoundedLine", configuration)
        self.assertIn("metadata.st_size > 4 * 1024 * 1024", configuration)
        self.assertIn("metadata.st_size > 4 * 1024 * 1024", mediaserver)
        self.assertIn("flock(descriptor, LOCK_EX)", configuration)
        self.assertIn("flock(descriptor, LOCK_EX)", mediaserver)


if __name__ == "__main__":
    unittest.main()
