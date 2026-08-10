#include <CoreVideo/CoreVideo.h>
#include <CoreMedia/CoreMedia.h>
#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <stdio.h>
#include <stdlib.h>

extern gboolean gst_plugin_app_register(void);
extern gboolean gst_plugin_coreelements_register(void);
extern gboolean gst_plugin_rtp_register(void);
extern gboolean gst_plugin_rtpmanager_register(void);
extern gboolean gst_plugin_rtsp_register(void);
extern gboolean gst_plugin_tcp_register(void);
extern gboolean gst_plugin_typefindfunctions_register(void);
extern gboolean gst_plugin_udp_register(void);
extern gboolean gst_plugin_videoparsersbad_register(void);
extern gboolean gst_is_apple_core_video_memory(GstMemory *memory);
extern GType gst_core_video_meta_api_get_type(void);
extern gboolean gst_vtdec_register_elements(GstPlugin *plugin);

// GStreamer 1.28.6 was built with the iOS 26.5 SDK, so vtutil contains a
// guarded reference to this iOS 26.2 API. The guard never takes that branch on
// the iOS 16 test target; provide the link-time symbol without importing a
// newer VideoToolbox contract into the probe.
void VTRegisterSupplementalVideoDecoderIfAvailable(CMVideoCodecType codecType) {
    (void)codecType;
}

typedef struct {
    GstMeta meta;
    CVBufferRef cvBuffer;
    CVPixelBufferRef pixelBuffer;
} VCAMGstCoreVideoMeta;

static gboolean registerPlugin(const char *name, gboolean (*registerFunction)(void)) {
    gboolean registered = registerFunction();
    printf("plugin name=%s registered=%d\n", name, registered ? 1 : 0);
    return registered;
}

static gboolean registerVTDecElements(void) {
    return gst_vtdec_register_elements(NULL);
}

static gboolean requireFactory(const char *name) {
    GstElementFactory *factory = gst_element_factory_find(name);
    if (factory == NULL) {
        printf("factory name=%s available=0\n", name);
        return FALSE;
    }
    printf("factory name=%s available=1 long-name=%s\n", name,
           gst_element_factory_get_longname(factory));
    gst_object_unref(factory);
    return TRUE;
}

static gboolean printBusError(GstBus *bus) {
    GstMessage *message = gst_bus_pop_filtered(bus, GST_MESSAGE_ERROR | GST_MESSAGE_EOS);
    if (message == NULL) return FALSE;
    if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
        GError *error = NULL;
        gchar *debug = NULL;
        gst_message_parse_error(message, &error, &debug);
        printf("bus error source=%s message=%s debug=%s\n",
               GST_OBJECT_NAME(message->src), error != NULL ? error->message : "unknown",
               debug != NULL ? debug : "none");
        g_clear_error(&error);
        g_free(debug);
    } else {
        printf("bus eos=1\n");
    }
    gst_message_unref(message);
    return TRUE;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("probe start build=gstreamer-1.28.6 target=ios16\n");
    if (argc != 2) {
        fprintf(stderr, "usage: %s rtsp://host:port/path\n", argv[0]);
        return 64;
    }

    GError *initError = NULL;
    if (!gst_init_check(&argc, &argv, &initError)) {
        printf("gst init failed error=%s\n", initError != NULL ? initError->message : "unknown");
        g_clear_error(&initError);
        return 71;
    }
    printf("gst init succeeded\n");
    gboolean pluginsReady = TRUE;
    pluginsReady &= registerPlugin("coreelements", gst_plugin_coreelements_register);
    pluginsReady &= registerPlugin("app", gst_plugin_app_register);
    pluginsReady &= registerPlugin("vtdec-elements", registerVTDecElements);
    pluginsReady &= registerPlugin("rtp", gst_plugin_rtp_register);
    pluginsReady &= registerPlugin("rtpmanager", gst_plugin_rtpmanager_register);
    pluginsReady &= registerPlugin("rtsp", gst_plugin_rtsp_register);
    pluginsReady &= registerPlugin("tcp", gst_plugin_tcp_register);
    pluginsReady &= registerPlugin("udp", gst_plugin_udp_register);
    pluginsReady &= registerPlugin("typefindfunctions", gst_plugin_typefindfunctions_register);
    pluginsReady &= registerPlugin("videoparsersbad", gst_plugin_videoparsersbad_register);
    if (!pluginsReady) return 65;

    const char *requiredFactories[] = {
        "rtspsrc", "rtph264depay", "h264parse", "vtdec", "appsink"
    };
    for (size_t index = 0; index < sizeof(requiredFactories) / sizeof(requiredFactories[0]); index++) {
        if (!requireFactory(requiredFactories[index])) return 66;
    }

    gchar *pipelineDescription = g_strdup_printf(
        "rtspsrc location=\"%s\" protocols=tcp latency=120 drop-on-latency=true "
        "! rtph264depay ! h264parse config-interval=-1 "
        "! video/x-h264,stream-format=avc,alignment=au "
        "! vtdec ! video/x-raw,format=NV12 "
        "! appsink name=probe-sink sync=false max-buffers=3 drop=true",
        argv[1]);
    GError *parseError = NULL;
    GstElement *pipeline = gst_parse_launch(pipelineDescription, &parseError);
    g_free(pipelineDescription);
    if (pipeline == NULL || parseError != NULL) {
        printf("pipeline parse failed error=%s\n",
               parseError != NULL ? parseError->message : "unknown");
        g_clear_error(&parseError);
        if (pipeline != NULL) gst_object_unref(pipeline);
        return 67;
    }

    GstElement *sinkElement = gst_bin_get_by_name(GST_BIN(pipeline), "probe-sink");
    GstBus *bus = gst_element_get_bus(pipeline);
    if (sinkElement == NULL || bus == NULL) {
        printf("pipeline lookup failed sink=%d bus=%d\n", sinkElement != NULL, bus != NULL);
        if (sinkElement != NULL) gst_object_unref(sinkElement);
        if (bus != NULL) gst_object_unref(bus);
        gst_object_unref(pipeline);
        return 68;
    }

    GstStateChangeReturn stateResult = gst_element_set_state(pipeline, GST_STATE_PLAYING);
    printf("pipeline state-request=%d\n", stateResult);
    if (stateResult == GST_STATE_CHANGE_FAILURE) {
        (void)printBusError(bus);
        gst_element_set_state(pipeline, GST_STATE_NULL);
        gst_object_unref(bus);
        gst_object_unref(sinkElement);
        gst_object_unref(pipeline);
        return 69;
    }

    unsigned sampleCount = 0;
    unsigned nv12Count = 0;
    unsigned coreVideoCount = 0;
    unsigned nonNullPixelBufferCount = 0;
    for (unsigned attempt = 0; attempt < 90 && nonNullPixelBufferCount < 30; attempt++) {
        GstSample *sample = gst_app_sink_try_pull_sample(GST_APP_SINK(sinkElement), GST_SECOND);
        if (sample == NULL) {
            if (printBusError(bus)) break;
            continue;
        }
        sampleCount += 1;
        GstCaps *caps = gst_sample_get_caps(sample);
        GstBuffer *buffer = gst_sample_get_buffer(sample);
        const GstStructure *structure = caps != NULL ? gst_caps_get_structure(caps, 0) : NULL;
        const gchar *format = structure != NULL ? gst_structure_get_string(structure, "format") : NULL;
        gint width = 0;
        gint height = 0;
        if (structure != NULL) {
            gst_structure_get_int(structure, "width", &width);
            gst_structure_get_int(structure, "height", &height);
        }
        if (g_strcmp0(format, "NV12") == 0) nv12Count += 1;

        gboolean appleMemory = FALSE;
        if (buffer != NULL) {
            for (guint memoryIndex = 0; memoryIndex < gst_buffer_n_memory(buffer); memoryIndex++) {
                GstMemory *memory = gst_buffer_peek_memory(buffer, memoryIndex);
                if (memory != NULL && gst_is_apple_core_video_memory(memory)) appleMemory = TRUE;
            }
        }
        if (appleMemory) coreVideoCount += 1;

        VCAMGstCoreVideoMeta *meta = buffer == NULL ? NULL :
            (VCAMGstCoreVideoMeta *)gst_buffer_get_meta(buffer, gst_core_video_meta_api_get_type());
        CVPixelBufferRef pixelBuffer = meta != NULL && meta->pixelBuffer != NULL
            ? CVPixelBufferRetain(meta->pixelBuffer) : NULL;
        if (pixelBuffer != NULL) {
            nonNullPixelBufferCount += 1;
            if (nonNullPixelBufferCount <= 3 || nonNullPixelBufferCount == 30) {
                printf("frame count=%u size=%zux%zu format=%08x iosurface=%d pts=%llu\n",
                       nonNullPixelBufferCount, CVPixelBufferGetWidth(pixelBuffer),
                       CVPixelBufferGetHeight(pixelBuffer),
                       (unsigned)CVPixelBufferGetPixelFormatType(pixelBuffer),
                       CVPixelBufferGetIOSurface(pixelBuffer) != NULL,
                       (unsigned long long)(buffer != NULL ? GST_BUFFER_PTS(buffer) : GST_CLOCK_TIME_NONE));
            }
            CVPixelBufferRelease(pixelBuffer);
        }
        gst_sample_unref(sample);
    }

    printf("verdict samples=%u nv12=%u apple-memory=%u non-null-cvpixelbuffer=%u result=%s\n",
           sampleCount, nv12Count, coreVideoCount, nonNullPixelBufferCount,
           nonNullPixelBufferCount >= 30 && nv12Count >= 30 ? "PASS" : "FAIL");
    (void)printBusError(bus);
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(bus);
    gst_object_unref(sinkElement);
    gst_object_unref(pipeline);
    return nonNullPixelBufferCount >= 30 && nv12Count >= 30 ? 0 : 70;
}
