# Architecture

The external seam is `VCAMFramePipeline`. Capture hooks know only how to ask for
a replacement video sample, audio sample, or photo auxiliary data. They do not
know whether bytes came from a local asset or OBS.

`VCAMMediaSource` is an internal seam with four current adapters:

- `VCAMLocalMediaSource` owns AVAssetReader lifecycle and looping.
- `VCAMOBSStreamSource` owns WebSocket reconnection and the latest network frame.
- `VCAMRTSPStreamSource` owns FFmpeg demux and VideoToolbox decoding.
- `VCAMHLSStreamSource` uses AVPlayer's native hardware-backed HLS pipeline.

`VCAMFrameRenderer` is the format-normalization module. It hides pixel-buffer
allocation, orientation, content mode, mirroring, timing and target size.

`VCAMPhotoAuxiliaryData` owns depth, photo metadata and pre-paired Live Photo
resources. This keeps optional photo behavior out of the real-time frame path.

The desktop bridge captures OBS Virtual Camera and emits versioned packets. Its
protocol codec is independent of OpenCV and covered by host tests.

The implementation intentionally fails open. A source error returns `NULL` at
the pipeline seam, and the hook forwards the original camera or microphone
sample. This invariant is more important than keeping replacement active.
