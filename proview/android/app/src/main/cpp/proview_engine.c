// ProView native engine: probing, thumbnails, decode benchmarking and
// 10-bit HEVC conversion (FFmpeg decode -> Android hardware HEVC encoder).

#include <jni.h>
#include <android/log.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/channel_layout.h>
#include <libavutil/display.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

#define TAG "ProViewEngine"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// MediaCodec constants (android.media.MediaCodecInfo / MediaFormat).
#define COLOR_FormatYUV420SemiPlanar 21
#define COLOR_FormatYUVP010 54
#define HEVCProfileMain 1
#define HEVCProfileMain10 2
#define HEVCProfileMain10HDR10 4096
#define COLOR_STANDARD_BT709 1
#define COLOR_STANDARD_BT601_PAL 2
#define COLOR_STANDARD_BT601_NTSC 4
#define COLOR_STANDARD_BT2020 6
#define COLOR_TRANSFER_SDR_VIDEO 3
#define COLOR_TRANSFER_ST2084 6
#define COLOR_TRANSFER_HLG 7
#define COLOR_RANGE_FULL 1
#define COLOR_RANGE_LIMITED 2
#define BITRATE_MODE_VBR 1

static atomic_int g_cancel = 0;

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void av_log_to_logcat(void *ptr, int level, const char *fmt, va_list vl) {
    if (level > AV_LOG_WARNING) return;
    char line[1024];
    int print_prefix = 1;
    av_log_format_line(ptr, level, fmt, vl, line, sizeof(line), &print_prefix);
    __android_log_print(level <= AV_LOG_ERROR ? ANDROID_LOG_ERROR : ANDROID_LOG_WARN, "FFmpeg", "%s", line);
}

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    av_log_set_callback(av_log_to_logcat);
    return JNI_VERSION_1_6;
}

// Opens a file path, or "fd:<n>" for a descriptor handed over by Android (the descriptor is dup'ed).
static int open_input(const char *path, AVFormatContext **out) {
    AVFormatContext *fmt = NULL;
    AVDictionary *opts = NULL;
    if (!strncmp(path, "fd:", 3) && path[3]) {
        av_dict_set(&opts, "fd", path + 3, 0);
        path = "fd:";
    }
    int ret = avformat_open_input(&fmt, path, NULL, &opts);
    av_dict_free(&opts);
    if (ret < 0) return ret;
    ret = avformat_find_stream_info(fmt, NULL);
    if (ret < 0) {
        avformat_close_input(&fmt);
        return ret;
    }
    *out = fmt;
    return 0;
}

static double stream_fps(const AVStream *st) {
    AVRational r = st->avg_frame_rate.num ? st->avg_frame_rate : st->r_frame_rate;
    return r.num && r.den ? av_q2d(r) : 0;
}

static int stream_rotation(const AVCodecParameters *par) {
    const AVPacketSideData *sd = av_packet_side_data_get(par->coded_side_data, par->nb_coded_side_data,
                                                         AV_PKT_DATA_DISPLAYMATRIX);
    if (!sd || sd->size < 9 * 4) return 0;
    double theta = -av_display_rotation_get((const int32_t *) sd->data);
    int deg = (int) lrint(theta);
    deg = ((deg % 360) + 360) % 360;
    return deg;
}

static const char *safe(const char *s) { return s ? s : ""; }

// Appends `"key":"value"` (escaped) to a JSON object body being built in `buf`; returns the new length.
static int json_tag(char *buf, size_t cap, int n, const char *key, const char *value, int *first) {
    if (!value || !*value || (size_t) n + 16 >= cap) return n;
    n += snprintf(buf + n, cap - n, "%s\"%s\":\"", *first ? "" : ",", key);
    *first = 0;
    for (const char *c = value; *c && (size_t) n + 8 < cap; c++) {
        if (*c == '"' || *c == '\\') buf[n++] = '\\', buf[n++] = *c;
        else if ((unsigned char) *c < 32) buf[n++] = ' ';
        else buf[n++] = *c;
    }
    n += snprintf(buf + n, cap - n, "\"");
    return n;
}

// First non-empty container tag among `keys` (NULL-terminated), matched case-insensitively.
static const char *first_tag(AVFormatContext *fmt, const char *const *keys) {
    for (; *keys; keys++) {
        const AVDictionaryEntry *e = av_dict_get(fmt->metadata, *keys, NULL, 0);
        if (e && e->value && *e->value) return e->value;
    }
    return NULL;
}

// ---------------------------------------------------------------------------
// probe(path) -> JSON

JNIEXPORT jstring JNICALL
Java_app_proview_proview_NativeEngine_probe(JNIEnv *env, jclass cls, jstring jpath) {
    const char *path = (*env)->GetStringUTFChars(env, jpath, NULL);
    AVFormatContext *fmt = NULL;
    int ret = open_input(path, &fmt);
    (*env)->ReleaseStringUTFChars(env, jpath, path);
    if (ret < 0) {
        char err[256], json[400];
        av_strerror(ret, err, sizeof(err));
        snprintf(json, sizeof(json), "{\"error\":\"%s\"}", err);
        return (*env)->NewStringUTF(env, json);
    }

    char json[8192];
    int n = snprintf(json, sizeof(json), "{\"rev\":2,\"container\":\"%s\",\"duration\":%.3f,\"bitRate\":%lld",
                     safe(fmt->iformat->name),
                     fmt->duration > 0 ? fmt->duration / (double) AV_TIME_BASE : 0.0,
                     (long long) fmt->bit_rate);

    int vidx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (vidx >= 0) {
        AVStream *st = fmt->streams[vidx];
        AVCodecParameters *p = st->codecpar;
        const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(p->format);
        const char *chroma = "";
        if (d && !(d->flags & AV_PIX_FMT_FLAG_RGB) && d->nb_components >= 3) {
            if (d->log2_chroma_w == 1 && d->log2_chroma_h == 1) chroma = "4:2:0";
            else if (d->log2_chroma_w == 1 && d->log2_chroma_h == 0) chroma = "4:2:2";
            else if (d->log2_chroma_w == 0 && d->log2_chroma_h == 0) chroma = "4:4:4";
        }
        char fourcc[AV_FOURCC_MAX_STRING_SIZE] = {0};
        av_fourcc_make_string(fourcc, p->codec_tag);
        for (char *c = fourcc; *c; c++) if (*c == '"' || *c == '\\' || *c < 32) *c = '?';
        const char *profile = avcodec_profile_name(p->codec_id, p->profile);
        n += snprintf(json + n, sizeof(json) - n,
                      ",\"video\":{\"codec\":\"%s\",\"profile\":\"%s\",\"fourcc\":\"%s\",\"width\":%d,\"height\":%d,"
                      "\"fps\":%.3f,\"pixFmt\":\"%s\",\"bitDepth\":%d,\"chroma\":\"%s\",\"alpha\":%s,"
                      "\"primaries\":\"%s\",\"transfer\":\"%s\",\"matrix\":\"%s\",\"range\":\"%s\","
                      "\"rotation\":%d,\"bitRate\":%lld,\"frames\":%lld,\"level\":%d,\"sarNum\":%d,\"sarDen\":%d,"
                      "\"progressive\":%s}",
                      safe(avcodec_get_name(p->codec_id)), safe(profile), fourcc, p->width, p->height,
                      stream_fps(st), safe(av_get_pix_fmt_name(p->format)), d ? d->comp[0].depth : 0, chroma,
                      d && (d->flags & AV_PIX_FMT_FLAG_ALPHA) ? "true" : "false",
                      safe(av_color_primaries_name(p->color_primaries)),
                      safe(av_color_transfer_name(p->color_trc)),
                      safe(av_color_space_name(p->color_space)),
                      safe(av_color_range_name(p->color_range)),
                      stream_rotation(p), (long long) p->bit_rate, (long long) st->nb_frames, p->level,
                      st->sample_aspect_ratio.num ? st->sample_aspect_ratio.num : p->sample_aspect_ratio.num,
                      st->sample_aspect_ratio.num ? st->sample_aspect_ratio.den : p->sample_aspect_ratio.den,
                      p->field_order == AV_FIELD_UNKNOWN || p->field_order == AV_FIELD_PROGRESSIVE ? "true" : "false");
    }
    int aidx = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, vidx, NULL, 0);
    if (aidx >= 0) {
        AVCodecParameters *p = fmt->streams[aidx]->codecpar;
        char layout[64] = "";
        av_channel_layout_describe(&p->ch_layout, layout, sizeof(layout));
        n += snprintf(json + n, sizeof(json) - n,
                      ",\"audio\":{\"codec\":\"%s\",\"channels\":%d,\"sampleRate\":%d,\"bits\":%d,\"bitRate\":%lld,"
                      "\"layout\":\"%s\"}",
                      safe(avcodec_get_name(p->codec_id)), p->ch_layout.nb_channels, p->sample_rate,
                      p->bits_per_raw_sample ? p->bits_per_raw_sample : p->bits_per_coded_sample,
                      (long long) p->bit_rate, layout);
    }
    // Stream counts and the descriptive tags cameras and editors write into the container.
    int nv = 0, na = 0, ns = 0;
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        switch (fmt->streams[i]->codecpar->codec_type) {
            case AVMEDIA_TYPE_VIDEO:
                if (!(fmt->streams[i]->disposition & AV_DISPOSITION_ATTACHED_PIC)) nv++;
                break;
            case AVMEDIA_TYPE_AUDIO: na++; break;
            case AVMEDIA_TYPE_SUBTITLE: ns++; break;
            default: break;
        }
    }
    n += snprintf(json + n, sizeof(json) - n, ",\"streams\":{\"video\":%d,\"audio\":%d,\"subtitle\":%d}", nv, na, ns);
    static const char *const k_encoder[] = {"encoder", "writing_library", "com.apple.quicktime.software", "software", NULL};
    static const char *const k_created[] = {"creation_time", "com.apple.quicktime.creationdate", "date", NULL};
    static const char *const k_make[] = {"com.apple.quicktime.make", "make", "manufacturer", NULL};
    static const char *const k_model[] = {"com.apple.quicktime.model", "model", NULL};
    static const char *const k_loc[] = {"com.apple.quicktime.location.ISO6709", "location", "location-eng", NULL};
    static const char *const k_title[] = {"title", "com.apple.quicktime.title", NULL};
    static const char *const k_brand[] = {"major_brand", NULL};
    n += snprintf(json + n, sizeof(json) - n, ",\"tags\":{");
    int first = 1;
    n = json_tag(json, sizeof(json), n, "encoder", first_tag(fmt, k_encoder), &first);
    n = json_tag(json, sizeof(json), n, "created", first_tag(fmt, k_created), &first);
    n = json_tag(json, sizeof(json), n, "make", first_tag(fmt, k_make), &first);
    n = json_tag(json, sizeof(json), n, "model", first_tag(fmt, k_model), &first);
    n = json_tag(json, sizeof(json), n, "location", first_tag(fmt, k_loc), &first);
    n = json_tag(json, sizeof(json), n, "title", first_tag(fmt, k_title), &first);
    n = json_tag(json, sizeof(json), n, "brand", first_tag(fmt, k_brand), &first);
    n += snprintf(json + n, sizeof(json) - n, "}");
    snprintf(json + n, sizeof(json) - n, "}");
    avformat_close_input(&fmt);
    return (*env)->NewStringUTF(env, json);
}

// ---------------------------------------------------------------------------
// Decoder helper shared by thumbnail and benchmark.

// GPU decoding: FFmpeg's Vulkan compute ProRes decoder. Returns a device context or NULL when the phone
// can't do it (the caller then decodes on the CPU).
extern char proview_tune[128];

static AVBufferRef *open_gpu_device(void) {
    // Off unless asked for ("gpudec=1"): Adreno's shader compiler crashes on FFmpeg's ProRes decode shaders.
    if (!strstr(proview_tune, "gpudec=1")) return NULL;
    AVBufferRef *dev = NULL;
    if (av_hwdevice_ctx_create(&dev, AV_HWDEVICE_TYPE_VULKAN, NULL, NULL, 0) < 0) return NULL;
    return dev;
}

static enum AVPixelFormat pick_gpu_format(AVCodecContext *ctx, const enum AVPixelFormat *fmts) {
    for (const enum AVPixelFormat *f = fmts; *f != AV_PIX_FMT_NONE; f++)
        if (*f == AV_PIX_FMT_VULKAN) return *f;
    for (const enum AVPixelFormat *f = fmts; *f != AV_PIX_FMT_NONE; f++) {
        const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(*f);
        if (d && !(d->flags & AV_PIX_FMT_FLAG_HWACCEL)) return *f;
    }
    return fmts[0];
}

// Opens the video decoder. With `gpu` set and a ProRes stream, decoding runs on the GPU (frames come back as
// AV_PIX_FMT_VULKAN; see download_frame). *used_gpu reports what was actually opened.
static AVCodecContext *open_video_decoder_ex(AVFormatContext *fmt, int vidx, int thread_type, AVBufferRef *gpu,
                                             int *used_gpu) {
    AVStream *st = fmt->streams[vidx];
    const AVCodec *dec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!dec) return NULL;
    if (used_gpu) *used_gpu = 0;
    for (int attempt = 0; attempt < 2; attempt++) {
        int use_gpu = attempt == 0 && gpu && st->codecpar->codec_id == AV_CODEC_ID_PRORES;
        if (attempt == 1 && !(gpu && st->codecpar->codec_id == AV_CODEC_ID_PRORES)) break;
        AVCodecContext *ctx = avcodec_alloc_context3(dec);
        avcodec_parameters_to_context(ctx, st->codecpar);
        ctx->pkt_timebase = st->time_base;
        ctx->thread_count = 0;
        ctx->thread_type = thread_type;
        if (use_gpu) {
            ctx->hw_device_ctx = av_buffer_ref(gpu);
            ctx->get_format = pick_gpu_format;
        }
        if (avcodec_open2(ctx, dec, NULL) >= 0) {
            if (used_gpu) *used_gpu = use_gpu;
            return ctx;
        }
        avcodec_free_context(&ctx);
    }
    return NULL;
}

static AVCodecContext *open_video_decoder(AVFormatContext *fmt, int vidx, int thread_type) {
    return open_video_decoder_ex(fmt, vidx, thread_type, NULL, NULL);
}

// Brings a GPU-decoded frame into system memory (in its native YCbCr format) so the converter can use it.
// Returns 0 and leaves *frame untouched for frames already in system memory.
static int download_frame(AVFrame *frame, AVFrame *scratch) {
    if (frame->format != AV_PIX_FMT_VULKAN) return 0;
    av_frame_unref(scratch);
    int ret = av_hwframe_transfer_data(scratch, frame, 0);
    if (ret < 0) return ret;
    av_frame_copy_props(scratch, frame);
    av_frame_unref(frame);
    av_frame_move_ref(frame, scratch);
    return 0;
}

// thumbnail(path, atSec, maxSide, directBuffer RGBA) -> (width << 16) | height, or 0 on failure.
JNIEXPORT jint JNICALL
Java_app_proview_proview_NativeEngine_thumbnail(JNIEnv *env, jclass cls, jstring jpath, jdouble at_sec,
                                                 jint max_side, jobject jbuf) {
    uint8_t *out = (*env)->GetDirectBufferAddress(env, jbuf);
    jlong cap = (*env)->GetDirectBufferCapacity(env, jbuf);
    const char *path = (*env)->GetStringUTFChars(env, jpath, NULL);
    AVFormatContext *fmt = NULL;
    int ret = open_input(path, &fmt);
    (*env)->ReleaseStringUTFChars(env, jpath, path);
    if (ret < 0) return 0;

    jint result = 0;
    AVCodecContext *dec = NULL;
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    int vidx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (vidx < 0 || !(dec = open_video_decoder(fmt, vidx, FF_THREAD_SLICE))) goto done;

    AVStream *st = fmt->streams[vidx];
    if (at_sec > 0) {
        int64_t ts = av_rescale_q((int64_t) (at_sec * AV_TIME_BASE), AV_TIME_BASE_Q, st->time_base);
        if (st->start_time != AV_NOPTS_VALUE) ts += st->start_time;
        av_seek_frame(fmt, vidx, ts, AVSEEK_FLAG_BACKWARD);
    }

    int got = 0, sent_eof = 0;
    while (!got) {
        if (!sent_eof) {
            ret = av_read_frame(fmt, pkt);
            if (ret < 0) {
                avcodec_send_packet(dec, NULL);
                sent_eof = 1;
            } else {
                if (pkt->stream_index == vidx) avcodec_send_packet(dec, pkt);
                av_packet_unref(pkt);
            }
        }
        ret = avcodec_receive_frame(dec, frame);
        if (ret == 0) got = 1;
        else if (ret != AVERROR(EAGAIN)) break;
    }
    if (!got) goto done;

    double sar = frame->sample_aspect_ratio.num ? av_q2d(frame->sample_aspect_ratio) : 1.0;
    double dw = frame->width * sar, dh = frame->height;
    double scale = FFMIN(1.0, max_side / FFMAX(dw, dh));
    int w = FFMAX(2, (int) (dw * scale) & ~1), h = FFMAX(2, (int) (dh * scale) & ~1);
    if ((jlong) w * h * 4 > cap) goto done;

    SwsContext *sws = sws_alloc_context();
    sws->flags = SWS_AREA;
    AVFrame *dst = av_frame_alloc();
    dst->width = w;
    dst->height = h;
    dst->format = AV_PIX_FMT_RGBA;
    dst->data[0] = out;
    dst->linesize[0] = w * 4;
    if (sws_scale_frame(sws, dst, frame) >= 0) result = (w << 16) | h;
    av_frame_free(&dst);
    sws_free_context(&sws);

done:
    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&dec);
    avformat_close_input(&fmt);
    return result;
}

// decodeSpeed(path) -> frames per second this device can software-decode the video at.
JNIEXPORT jdouble JNICALL
Java_app_proview_proview_NativeEngine_decodeSpeed(JNIEnv *env, jclass cls, jstring jpath) {
    const char *path = (*env)->GetStringUTFChars(env, jpath, NULL);
    AVFormatContext *fmt = NULL;
    int ret = open_input(path, &fmt);
    (*env)->ReleaseStringUTFChars(env, jpath, path);
    if (ret < 0) return 0;

    double fps = 0;
    AVCodecContext *dec = NULL;
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc(), *scratch = av_frame_alloc();
    AVBufferRef *gpu = NULL;
    int vidx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (vidx >= 0 && fmt->streams[vidx]->codecpar->codec_id == AV_CODEC_ID_PRORES) gpu = open_gpu_device();
    if (vidx < 0 || !(dec = open_video_decoder_ex(fmt, vidx, FF_THREAD_FRAME | FF_THREAD_SLICE, gpu, NULL))) goto done;

    int frames = 0, warmup = 8;
    double start = 0;
    while (av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index == vidx) {
            avcodec_send_packet(dec, pkt);
            while (avcodec_receive_frame(dec, frame) == 0) {
                download_frame(frame, scratch);   // the conversion downloads GPU frames too, so time it
                if (++frames == warmup) start = now_sec();
                av_frame_unref(frame);
            }
        }
        av_packet_unref(pkt);
        if (start > 0 && (now_sec() - start > 2.0 || frames - warmup >= 120)) break;
    }
    if (start > 0 && frames > warmup) fps = (frames - warmup) / (now_sec() - start);

done:
    LOGI("decodeSpeed: %.1f fps (%s)", fps, dec && dec->hw_device_ctx ? "GPU" : "CPU");
    av_frame_free(&frame);
    av_frame_free(&scratch);
    av_packet_free(&pkt);
    avcodec_free_context(&dec);
    av_buffer_unref(&gpu);
    avformat_close_input(&fmt);
    return fps;
}

// ---------------------------------------------------------------------------
// Conversion

typedef struct Converter {
    JNIEnv *env;
    jobject listener;
    jmethodID on_progress;
    jmethodID on_info;

    AVFormatContext *in, *out;
    int vidx, aidx;
    AVStream *out_vst, *out_ast;
    AVCodecContext *vdec, *adec, *aenc;
    SwsContext *sws;
    SwrContext *swr;
    AVAudioFifo *fifo;
    int audio_copy;
    int64_t audio_samples_out;
    int64_t audio_first_pts_us;

    AMediaCodec *enc;
    int ten_bit;
    int width, height;          // encoder (output) size
    int src_width, src_height;  // even-cropped source size
    int stride, slice_height;
    int header_written;
    AVPacket **pending;
    int nb_pending, cap_pending;
    int encoder_eos;

    int64_t start_us;
    double duration;
    double last_report;
    double started_at;
    int64_t frames_in;
    AVBufferRef *gpu;          // Vulkan device for GPU ProRes decoding (NULL: CPU)
    int gpu_decode;
    AVFrame *dl;               // download scratch for GPU frames
    int bitrate;
    double fps;
    double last_video_sec;
    char error[512];
} Converter;

static void set_error(Converter *c, const char *msg, int averr) {
    if (c->error[0]) return;
    if (averr) {
        char e[128];
        av_strerror(averr, e, sizeof(e));
        snprintf(c->error, sizeof(c->error), "%s (%s)", msg, e);
    } else {
        snprintf(c->error, sizeof(c->error), "%s", msg);
    }
    LOGE("%s", c->error);
}

static void report(Converter *c, int force) {
    double t = now_sec();
    if (!force && t - c->last_report < 0.25) return;
    c->last_report = t;
    double elapsed = t - c->started_at;
    double fps = elapsed > 0 ? c->frames_in / elapsed : 0;
    (*c->env)->CallVoidMethod(c->env, c->listener, c->on_progress, c->last_video_sec, c->duration, fps);
}

static int write_packet(Converter *c, AVPacket *pkt) {
    if (!c->header_written) {
        if (c->nb_pending == c->cap_pending) {
            c->cap_pending = c->cap_pending ? c->cap_pending * 2 : 64;
            c->pending = av_realloc_array(c->pending, c->cap_pending, sizeof(*c->pending));
        }
        c->pending[c->nb_pending++] = av_packet_clone(pkt);
        return 0;
    }
    int ret = av_interleaved_write_frame(c->out, pkt);
    if (ret < 0) set_error(c, "Couldn't write the converted file", ret);
    return ret;
}

static int write_header(Converter *c, const uint8_t *csd, size_t size) {
    AVCodecParameters *p = c->out_vst->codecpar;
    p->extradata = av_mallocz(size + AV_INPUT_BUFFER_PADDING_SIZE);
    memcpy(p->extradata, csd, size);
    p->extradata_size = (int) size;

    AVDictionary *opts = NULL;
    av_dict_set(&opts, "movflags", "+faststart+write_colr", 0);
    int ret = avformat_write_header(c->out, &opts);
    av_dict_free(&opts);
    if (ret < 0) {
        set_error(c, "Couldn't start the converted file", ret);
        return ret;
    }
    c->header_written = 1;
    for (int i = 0; i < c->nb_pending; i++) {
        if (ret >= 0) ret = write_packet(c, c->pending[i]);
        av_packet_free(&c->pending[i]);
    }
    c->nb_pending = 0;
    return ret;
}

static int drain_encoder(Converter *c, int64_t timeout_us) {
    for (;;) {
        AMediaCodecBufferInfo info;
        ssize_t idx = AMediaCodec_dequeueOutputBuffer(c->enc, &info, timeout_us);
        if (idx == AMEDIACODEC_INFO_TRY_AGAIN_LATER) return 0;
        if (idx == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
            // Some encoders only report the stream headers (VPS/SPS/PPS) through the output format.
            AMediaFormat *of = AMediaCodec_getOutputFormat(c->enc);
            void *csd = NULL;
            size_t csd_size = 0;
            int ret = 0;
            if (of && !c->header_written && AMediaFormat_getBuffer(of, "csd-0", &csd, &csd_size) && csd_size > 0)
                ret = write_header(c, csd, csd_size);
            if (of) AMediaFormat_delete(of);
            if (ret < 0) return ret;
            continue;
        }
        if (idx == AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED) continue;
        if (idx < 0) {
            set_error(c, "The phone's video encoder stopped unexpectedly", 0);
            return AVERROR_EXTERNAL;
        }
        size_t size;
        uint8_t *buf = AMediaCodec_getOutputBuffer(c->enc, idx, &size);
        int ret = 0;
        if (info.size > 0 && buf) {
            const uint8_t *data = buf + info.offset;
            if (info.flags & AMEDIACODEC_BUFFER_FLAG_CODEC_CONFIG) {
                if (!c->header_written) ret = write_header(c, data, info.size);
            } else {
                AVPacket *pkt = av_packet_alloc();
                av_new_packet(pkt, info.size);
                memcpy(pkt->data, data, info.size);
                pkt->stream_index = c->out_vst->index;
                pkt->pts = pkt->dts = av_rescale_q(info.presentationTimeUs, AV_TIME_BASE_Q, c->out_vst->time_base);
                if (info.flags & 1 /* BUFFER_FLAG_KEY_FRAME */) pkt->flags |= AV_PKT_FLAG_KEY;
                if (!c->header_written) {
                    set_error(c, "The phone's video encoder didn't provide stream headers", 0);
                    ret = AVERROR_EXTERNAL;
                } else {
                    ret = write_packet(c, pkt);
                }
                av_packet_free(&pkt);
            }
        }
        AMediaCodec_releaseOutputBuffer(c->enc, idx, false);
        if (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) {
            c->encoder_eos = 1;
            return 0;
        }
        if (ret < 0) return ret;
        timeout_us = 0;
    }
}

static int setup_encoder(Converter *c, int bitrate, double fps, int try_ten_bit);

static int encode_video_frame(Converter *c, AVFrame *frame) {
    ssize_t idx;
    for (;;) {
        if (atomic_load(&g_cancel)) return AVERROR_EXIT;
        idx = AMediaCodec_dequeueInputBuffer(c->enc, 5000);
        if (idx >= 0) break;
        int ret = drain_encoder(c, 0);
        if (ret < 0) return ret;
    }
    size_t cap;
    uint8_t *buf = AMediaCodec_getInputBuffer(c->enc, idx, &cap);
    size_t needed = (size_t) c->stride * c->slice_height + (size_t) c->stride * (c->height / 2);
    if (!buf || cap < needed) {
        set_error(c, "The phone's video encoder gave an unexpected buffer layout", 0);
        return AVERROR_EXTERNAL;
    }

    AVFrame *dst = av_frame_alloc();
    dst->width = c->width;
    dst->height = c->height;
    dst->format = c->ten_bit ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12;
    dst->color_range = AVCOL_RANGE_MPEG;
    dst->color_primaries = frame->color_primaries;
    dst->color_trc = frame->color_trc;
    dst->colorspace = frame->colorspace;
    dst->data[0] = buf;
    dst->data[1] = buf + (size_t) c->stride * c->slice_height;
    dst->linesize[0] = dst->linesize[1] = c->stride;

    // Crop odd source dimensions to the even encoder size.
    frame->crop_right += frame->width - c->src_width;
    frame->crop_bottom += frame->height - c->src_height;
    av_frame_apply_cropping(frame, AV_FRAME_CROP_UNALIGNED);
    // Treat unspecified source range as limited (video) range.
    if (frame->color_range == AVCOL_RANGE_UNSPECIFIED) frame->color_range = AVCOL_RANGE_MPEG;

    int ret = sws_scale_frame(c->sws, dst, frame);
    av_frame_free(&dst);
    if (ret < 0) {
        AMediaCodec_queueInputBuffer(c->enc, idx, 0, 0, 0, 0);
        set_error(c, "Couldn't convert the video frame format", ret);
        return ret;
    }

    int64_t pts = frame->best_effort_timestamp != AV_NOPTS_VALUE ? frame->best_effort_timestamp : frame->pts;
    int64_t pts_us = av_rescale_q(pts, c->in->streams[c->vidx]->time_base, AV_TIME_BASE_Q) - c->start_us;
    if (pts_us < 0) pts_us = 0;
    c->last_video_sec = pts_us / 1e6;
    c->frames_in++;

    if (AMediaCodec_queueInputBuffer(c->enc, idx, 0, needed, pts_us, 0) != AMEDIA_OK) {
        // Some encoders accept a 10-bit configuration but then refuse 10-bit frames: restart in 8-bit.
        if (c->ten_bit && c->frames_in == 1) {
            AMediaCodec_stop(c->enc);
            AMediaCodec_delete(c->enc);
            c->enc = NULL;
            if (setup_encoder(c, c->bitrate, c->fps, 0) >= 0) {
                c->frames_in = 0;
                return encode_video_frame(c, frame);
            }
        }
        set_error(c, "The phone's video encoder rejected a frame", 0);
        return AVERROR_EXTERNAL;
    }
    report(c, 0);
    return drain_encoder(c, 0);
}

static int decode_video(Converter *c, AVPacket *pkt) {
    int ret = avcodec_send_packet(c->vdec, pkt);
    if (ret < 0 && ret != AVERROR_EOF) {
        // A corrupt packet: skip it rather than failing the whole conversion.
        LOGE("video send_packet failed: %d", ret);
        return 0;
    }
    AVFrame *frame = av_frame_alloc();
    for (;;) {
        ret = avcodec_receive_frame(c->vdec, frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            ret = 0;
            break;
        }
        if (ret == AVERROR_INVALIDDATA) continue;  // damaged frame: skip it
        if (ret < 0) {
            set_error(c, "Couldn't decode the video", ret);
            break;
        }
        if (c->gpu_decode && (ret = download_frame(frame, c->dl)) < 0) {
            set_error(c, "Couldn't read a frame back from the GPU", ret);
            break;
        }
        ret = encode_video_frame(c, frame);
        av_frame_unref(frame);
        if (ret < 0) break;
    }
    av_frame_free(&frame);
    return ret;
}

static int encode_audio(Converter *c, AVFrame *frame) {
    int ret = avcodec_send_frame(c->aenc, frame);
    if (ret < 0 && ret != AVERROR_EOF) {
        set_error(c, "Couldn't encode the audio", ret);
        return ret;
    }
    AVPacket *pkt = av_packet_alloc();
    while ((ret = avcodec_receive_packet(c->aenc, pkt)) == 0) {
        pkt->stream_index = c->out_ast->index;
        av_packet_rescale_ts(pkt, c->aenc->time_base, c->out_ast->time_base);
        ret = write_packet(c, pkt);
        av_packet_unref(pkt);
        if (ret < 0) break;
    }
    av_packet_free(&pkt);
    return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}

static int flush_fifo(Converter *c, int final) {
    int fs = c->aenc->frame_size;
    while (av_audio_fifo_size(c->fifo) >= fs || (final && av_audio_fifo_size(c->fifo) > 0)) {
        int n = FFMIN(fs, av_audio_fifo_size(c->fifo));
        AVFrame *f = av_frame_alloc();
        f->nb_samples = n;
        f->format = c->aenc->sample_fmt;
        f->sample_rate = c->aenc->sample_rate;
        av_channel_layout_copy(&f->ch_layout, &c->aenc->ch_layout);
        av_frame_get_buffer(f, 0);
        av_audio_fifo_read(c->fifo, (void **) f->data, n);
        f->pts = av_rescale_q(c->audio_first_pts_us, AV_TIME_BASE_Q, c->aenc->time_base) + c->audio_samples_out;
        c->audio_samples_out += n;
        int ret = encode_audio(c, f);
        av_frame_free(&f);
        if (ret < 0) return ret;
    }
    return 0;
}

static int process_audio(Converter *c, AVPacket *pkt) {
    AVStream *ist = c->in->streams[c->aidx];
    if (c->audio_copy) {
        if (!pkt) return 0;
        AVPacket *p = av_packet_clone(pkt);
        int64_t off = av_rescale_q(c->start_us, AV_TIME_BASE_Q, ist->time_base);
        if (p->pts != AV_NOPTS_VALUE) p->pts -= off;
        if (p->dts != AV_NOPTS_VALUE) p->dts -= off;
        if (p->pts < 0 || p->dts < 0) {
            av_packet_free(&p);
            return 0;
        }
        av_packet_rescale_ts(p, ist->time_base, c->out_ast->time_base);
        p->stream_index = c->out_ast->index;
        p->pos = -1;
        int ret = write_packet(c, p);
        av_packet_free(&p);
        return ret;
    }

    int ret = avcodec_send_packet(c->adec, pkt);
    if (ret < 0 && ret != AVERROR_EOF) return 0;  // skip a corrupt audio packet
    AVFrame *frame = av_frame_alloc();
    while ((ret = avcodec_receive_frame(c->adec, frame)) == 0) {
        if (c->audio_first_pts_us == AV_NOPTS_VALUE) {
            int64_t pts = frame->best_effort_timestamp;
            c->audio_first_pts_us = pts == AV_NOPTS_VALUE ? 0
                    : FFMAX(0, av_rescale_q(pts, ist->time_base, AV_TIME_BASE_Q) - c->start_us);
        }
        int out_samples = swr_get_out_samples(c->swr, frame->nb_samples);
        uint8_t **buf = NULL;
        av_samples_alloc_array_and_samples(&buf, NULL, c->aenc->ch_layout.nb_channels, out_samples,
                                           c->aenc->sample_fmt, 0);
        int got = swr_convert(c->swr, buf, out_samples, (const uint8_t **) frame->extended_data,
                              frame->nb_samples);
        if (got > 0) av_audio_fifo_write(c->fifo, (void **) buf, got);
        av_freep(&buf[0]);
        av_freep(&buf);
        av_frame_unref(frame);
        ret = flush_fifo(c, 0);
        if (ret < 0) break;
    }
    av_frame_free(&frame);
    if (!pkt) {
        ret = flush_fifo(c, 1);
        if (ret >= 0) ret = encode_audio(c, NULL);
        return ret;
    }
    return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}

static int setup_audio(Converter *c, int audio_bitrate) {
    AVStream *ist = c->in->streams[c->aidx];
    AVCodecParameters *ip = ist->codecpar;
    c->out_ast = avformat_new_stream(c->out, NULL);
    if (ip->codec_id == AV_CODEC_ID_AAC && ip->ch_layout.nb_channels <= 2) {
        c->audio_copy = 1;
        avcodec_parameters_copy(c->out_ast->codecpar, ip);
        c->out_ast->codecpar->codec_tag = 0;
        c->out_ast->time_base = ist->time_base;
        return 0;
    }

    const AVCodec *dec = avcodec_find_decoder(ip->codec_id);
    const AVCodec *enc = avcodec_find_encoder(AV_CODEC_ID_AAC);
    if (!dec || !enc) return AVERROR_DECODER_NOT_FOUND;
    c->adec = avcodec_alloc_context3(dec);
    avcodec_parameters_to_context(c->adec, ip);
    c->adec->pkt_timebase = ist->time_base;
    int ret = avcodec_open2(c->adec, dec, NULL);
    if (ret < 0) return ret;

    int rate = c->adec->sample_rate;
    if (rate != 44100 && rate != 48000 && rate != 32000 && rate != 96000) rate = 48000;
    c->aenc = avcodec_alloc_context3(enc);
    c->aenc->sample_fmt = AV_SAMPLE_FMT_FLTP;
    c->aenc->sample_rate = rate;
    c->aenc->bit_rate = audio_bitrate;
    c->aenc->time_base = (AVRational) {1, rate};
    if (c->adec->ch_layout.nb_channels == 1) av_channel_layout_default(&c->aenc->ch_layout, 1);
    else av_channel_layout_default(&c->aenc->ch_layout, 2);
    if (c->out->oformat->flags & AVFMT_GLOBALHEADER) c->aenc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    ret = avcodec_open2(c->aenc, enc, NULL);
    if (ret < 0) return ret;
    avcodec_parameters_from_context(c->out_ast->codecpar, c->aenc);
    c->out_ast->time_base = c->aenc->time_base;

    AVChannelLayout in_layout;
    if (c->adec->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC)
        av_channel_layout_default(&in_layout, c->adec->ch_layout.nb_channels);
    else
        av_channel_layout_copy(&in_layout, &c->adec->ch_layout);
    ret = swr_alloc_set_opts2(&c->swr, &c->aenc->ch_layout, c->aenc->sample_fmt, rate,
                              &in_layout, c->adec->sample_fmt, c->adec->sample_rate, 0, NULL);
    av_channel_layout_uninit(&in_layout);
    if (ret < 0 || (ret = swr_init(c->swr)) < 0) return ret;
    c->fifo = av_audio_fifo_alloc(c->aenc->sample_fmt, c->aenc->ch_layout.nb_channels, 4096);
    return 0;
}

static void map_color(const AVCodecParameters *p, int *standard, int *transfer, int *range, int *hdr10) {
    switch (p->color_primaries) {
        case AVCOL_PRI_BT2020: *standard = COLOR_STANDARD_BT2020; break;
        case AVCOL_PRI_BT470BG: *standard = COLOR_STANDARD_BT601_PAL; break;
        case AVCOL_PRI_SMPTE170M: *standard = COLOR_STANDARD_BT601_NTSC; break;
        default: *standard = COLOR_STANDARD_BT709;
    }
    *hdr10 = 0;
    switch (p->color_trc) {
        case AVCOL_TRC_SMPTE2084: *transfer = COLOR_TRANSFER_ST2084; *hdr10 = 1; break;
        case AVCOL_TRC_ARIB_STD_B67: *transfer = COLOR_TRANSFER_HLG; break;
        default: *transfer = COLOR_TRANSFER_SDR_VIDEO;
    }
    *range = COLOR_RANGE_LIMITED;
}

static int setup_encoder(Converter *c, int bitrate, double fps, int try_ten_bit) {
    AVCodecParameters *ip = c->in->streams[c->vidx]->codecpar;
    int standard, transfer, range, hdr10;
    map_color(ip, &standard, &transfer, &range, &hdr10);

    c->enc = AMediaCodec_createEncoderByType("video/hevc");
    if (!c->enc) {
        set_error(c, "This phone has no HEVC video encoder", 0);
        return AVERROR_ENCODER_NOT_FOUND;
    }
    AMediaFormat *f = AMediaFormat_new();
    AMediaFormat_setString(f, AMEDIAFORMAT_KEY_MIME, "video/hevc");
    AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_WIDTH, c->width);
    AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_HEIGHT, c->height);
    AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_COLOR_FORMAT,
                          try_ten_bit ? COLOR_FormatYUVP010 : COLOR_FormatYUV420SemiPlanar);
    AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_PROFILE,
                          try_ten_bit ? (hdr10 ? HEVCProfileMain10HDR10 : HEVCProfileMain10) : HEVCProfileMain);
    AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_BIT_RATE, bitrate);
    AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_BITRATE_MODE, BITRATE_MODE_VBR);
    AMediaFormat_setFloat(f, AMEDIAFORMAT_KEY_FRAME_RATE, (float) fps);
    AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_I_FRAME_INTERVAL, 1);
    AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_COLOR_STANDARD, standard);
    AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_COLOR_TRANSFER, transfer);
    AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_COLOR_RANGE, range);
    AMediaFormat_setInt32(f, "max-bframes", 0);
    AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_PRIORITY, 1);  // best effort: may run faster than real time
    AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_OPERATING_RATE, (int) FFMIN(240, fps * 4));

    media_status_t st = AMediaCodec_configure(c->enc, f, NULL, NULL, AMEDIACODEC_CONFIGURE_FLAG_ENCODE);
    if (st != AMEDIA_OK) {
        // Some encoders refuse a high operating rate; retry at real time.
        AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_OPERATING_RATE, (int) fps);
        AMediaCodec_delete(c->enc);
        c->enc = AMediaCodec_createEncoderByType("video/hevc");
        st = AMediaCodec_configure(c->enc, f, NULL, NULL, AMEDIACODEC_CONFIGURE_FLAG_ENCODE);
    }
    AMediaFormat_delete(f);
    if (st != AMEDIA_OK || AMediaCodec_start(c->enc) != AMEDIA_OK) {
        AMediaCodec_delete(c->enc);
        c->enc = NULL;
        return AVERROR_EXTERNAL;
    }
    c->ten_bit = try_ten_bit;
    c->bitrate = bitrate;
    c->fps = fps;

    // Input buffer layout as reported by the encoder.
    int stride = 0, slice = 0;
    AMediaFormat *inf = AMediaCodec_getInputFormat(c->enc);
    if (inf) {
        AMediaFormat_getInt32(inf, AMEDIAFORMAT_KEY_STRIDE, &stride);
        AMediaFormat_getInt32(inf, AMEDIAFORMAT_KEY_SLICE_HEIGHT, &slice);
        AMediaFormat_delete(inf);
    }
    int row_bytes = c->width * (try_ten_bit ? 2 : 1);
    if (stride <= 0) stride = row_bytes;
    else if (stride < row_bytes) stride *= (try_ten_bit ? 2 : 1);  // some encoders report stride in pixels
    if (slice < c->height) slice = c->height;
    c->stride = stride;
    c->slice_height = slice;

    char *name = NULL;
    AMediaCodec_getName(c->enc, &name);
    LOGI("encoder %s %dx%d %s stride=%d slice=%d bitrate=%d fps=%.3f", name ? name : "?", c->width, c->height,
         try_ten_bit ? "P010" : "NV12", stride, slice, bitrate, fps);
    char label[256];
    snprintf(label, sizeof(label), "%s@%dx%d", name ? name : "", c->width, c->height);
    jstring jname = (*c->env)->NewStringUTF(c->env, label);
    (*c->env)->CallVoidMethod(c->env, c->listener, c->on_info, jname, try_ten_bit ? 10 : 8);
    (*c->env)->DeleteLocalRef(c->env, jname);
    if (name) AMediaCodec_releaseName(c->enc, name);
    return 0;
}

// Encodes one blank frame to check the encoder really handles the configured input format.
// Some encoders accept a 10-bit configuration but then fail on 10-bit frames.
static int encoder_accepts_frames(Converter *c) {
    ssize_t idx = AMediaCodec_dequeueInputBuffer(c->enc, 200000);
    if (idx < 0) return 0;
    size_t cap;
    uint8_t *buf = AMediaCodec_getInputBuffer(c->enc, idx, &cap);
    size_t needed = (size_t) c->stride * c->slice_height + (size_t) c->stride * (c->height / 2);
    if (!buf || cap < needed) return 0;
    memset(buf, 0, needed);
    if (AMediaCodec_queueInputBuffer(c->enc, idx, 0, needed, 0, 0) != AMEDIA_OK) return 0;
    int eos_sent = 0;
    for (int i = 0; i < 100; i++) {  // up to ~5 s
        if (!eos_sent) {
            ssize_t in = AMediaCodec_dequeueInputBuffer(c->enc, 0);
            if (in >= 0) {
                AMediaCodec_queueInputBuffer(c->enc, in, 0, 0, 0, AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
                eos_sent = 1;
            }
        }
        AMediaCodecBufferInfo info;
        ssize_t out = AMediaCodec_dequeueOutputBuffer(c->enc, &info, 50000);
        if (out == AMEDIACODEC_INFO_TRY_AGAIN_LATER || out == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED ||
            out == AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED)
            continue;
        if (out < 0) return 0;
        AMediaCodec_releaseOutputBuffer(c->enc, out, false);
        if (!(info.flags & AMEDIACODEC_BUFFER_FLAG_CODEC_CONFIG) && info.size > 0) return 1;
        if (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) return 0;
    }
    return 0;
}

static void close_encoder(Converter *c) {
    if (!c->enc) return;
    AMediaCodec_stop(c->enc);
    AMediaCodec_delete(c->enc);
    c->enc = NULL;
}

// Starts the encoder at the current size: 10-bit if it truly works, otherwise 8-bit.
static int start_encoder(Converter *c, int bitrate, double fps) {
    if (setup_encoder(c, bitrate, fps, 1) >= 0) {
        int ok = encoder_accepts_frames(c);
        close_encoder(c);
        if (ok && setup_encoder(c, bitrate, fps, 1) >= 0) return 0;
        close_encoder(c);
        LOGI("10-bit encoding not usable at %dx%d; using 8-bit", c->width, c->height);
    }
    if (setup_encoder(c, bitrate, fps, 0) >= 0) return 0;
    close_encoder(c);
    return -1;
}

static int signal_encoder_eos(Converter *c) {
    for (int tries = 0; tries < 2000; tries++) {
        ssize_t idx = AMediaCodec_dequeueInputBuffer(c->enc, 5000);
        if (idx >= 0) {
            AMediaCodec_queueInputBuffer(c->enc, idx, 0, 0, 0, AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
            return 0;
        }
        int ret = drain_encoder(c, 0);
        if (ret < 0) return ret;
    }
    set_error(c, "The phone's video encoder stopped responding", 0);
    return AVERROR_EXTERNAL;
}

JNIEXPORT void JNICALL
Java_app_proview_proview_NativeEngine_cancelConvert(JNIEnv *env, jclass cls) {
    atomic_store(&g_cancel, 1);
}

// convert(inPath, outPath, videoBitrate, audioBitrate, listener) -> null on success, else an error message.
JNIEXPORT jstring JNICALL
Java_app_proview_proview_NativeEngine_convert(JNIEnv *env, jclass cls, jstring jin, jstring jout,
                                               jint video_bitrate, jint audio_bitrate, jobject listener) {
    atomic_store(&g_cancel, 0);
    Converter conv = {0}, *c = &conv;
    c->env = env;
    c->listener = listener;
    jclass lcls = (*env)->GetObjectClass(env, listener);
    c->on_progress = (*env)->GetMethodID(env, lcls, "onProgress", "(DDD)V");
    c->on_info = (*env)->GetMethodID(env, lcls, "onEncoder", "(Ljava/lang/String;I)V");
    if (!c->on_progress || !c->on_info || (*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return (*env)->NewStringUTF(env, "Internal error: progress callback missing");
    }
    c->audio_first_pts_us = AV_NOPTS_VALUE;
    c->vidx = c->aidx = -1;

    const char *in_path = (*env)->GetStringUTFChars(env, jin, NULL);
    const char *out_path = (*env)->GetStringUTFChars(env, jout, NULL);
    AVPacket *pkt = av_packet_alloc();
    int ret = open_input(in_path, &c->in);
    if (ret < 0) {
        set_error(c, "Couldn't open the video", ret);
        goto end;
    }
    c->vidx = av_find_best_stream(c->in, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (c->vidx < 0) {
        set_error(c, "This file has no video track", 0);
        goto end;
    }
    c->aidx = av_find_best_stream(c->in, AVMEDIA_TYPE_AUDIO, -1, c->vidx, NULL, 0);
    AVStream *ivst = c->in->streams[c->vidx];
    c->duration = c->in->duration > 0 ? c->in->duration / (double) AV_TIME_BASE : 0;
    c->start_us = c->in->start_time != AV_NOPTS_VALUE ? c->in->start_time : 0;

    if (ivst->codecpar->codec_id == AV_CODEC_ID_PRORES) c->gpu = open_gpu_device();
    c->dl = av_frame_alloc();
    c->vdec = open_video_decoder_ex(c->in, c->vidx, FF_THREAD_FRAME | FF_THREAD_SLICE, c->gpu, &c->gpu_decode);
    LOGI("conversion decoder: %s", c->gpu_decode ? "GPU (Vulkan)" : "CPU");
    if (!c->vdec) {
        set_error(c, "ProView can't decode this video format", 0);
        goto end;
    }
    c->src_width = c->width = ivst->codecpar->width & ~1;
    c->src_height = c->height = ivst->codecpar->height & ~1;
    double fps = stream_fps(ivst);
    if (fps <= 0 || fps > 240) fps = 30;

    ret = avformat_alloc_output_context2(&c->out, NULL, "mp4", out_path);
    if (ret < 0) {
        set_error(c, "Couldn't create the converted file", ret);
        goto end;
    }

    // Video output stream; codec headers are filled in once the encoder produces them.
    c->out_vst = avformat_new_stream(c->out, NULL);
    AVCodecParameters *vp = c->out_vst->codecpar;
    vp->codec_type = AVMEDIA_TYPE_VIDEO;
    vp->codec_id = AV_CODEC_ID_HEVC;
    vp->codec_tag = MKTAG('h', 'v', 'c', '1');
    vp->width = c->width;
    vp->height = c->height;
    vp->sample_aspect_ratio = ivst->codecpar->sample_aspect_ratio;
    vp->color_range = AVCOL_RANGE_MPEG;
    vp->color_primaries = ivst->codecpar->color_primaries != AVCOL_PRI_UNSPECIFIED
                          ? ivst->codecpar->color_primaries : AVCOL_PRI_BT709;
    vp->color_trc = ivst->codecpar->color_trc != AVCOL_TRC_UNSPECIFIED ? ivst->codecpar->color_trc : AVCOL_TRC_BT709;
    vp->color_space = ivst->codecpar->color_space != AVCOL_SPC_UNSPECIFIED
                      ? ivst->codecpar->color_space : AVCOL_SPC_BT709;
    vp->bit_rate = video_bitrate;
    c->out_vst->time_base = ivst->time_base;
    c->out_vst->avg_frame_rate = ivst->avg_frame_rate;
    const AVPacketSideData *dm = av_packet_side_data_get(ivst->codecpar->coded_side_data,
                                                         ivst->codecpar->nb_coded_side_data,
                                                         AV_PKT_DATA_DISPLAYMATRIX);
    if (dm) {
        AVPacketSideData *nsd = av_packet_side_data_new(&vp->coded_side_data, &vp->nb_coded_side_data,
                                                        AV_PKT_DATA_DISPLAYMATRIX, dm->size, 0);
        if (nsd) memcpy(nsd->data, dm->data, dm->size);
    }

    if (c->aidx >= 0 && (ret = setup_audio(c, audio_bitrate)) < 0) {
        LOGE("audio setup failed (%d); converting without audio", ret);
        // Drop the audio stream we may have created; FFmpeg can't remove streams, so start over.
        avformat_free_context(c->out);
        c->out = NULL;
        avcodec_free_context(&c->adec);
        avcodec_free_context(&c->aenc);
        swr_free(&c->swr);
        c->aidx = -1;
        ret = 0;
        avformat_alloc_output_context2(&c->out, NULL, "mp4", out_path);
        AVStream *nv = avformat_new_stream(c->out, NULL);
        avcodec_parameters_copy(nv->codecpar, vp);
        nv->time_base = c->out_vst->time_base;
        nv->avg_frame_rate = c->out_vst->avg_frame_rate;
        c->out_vst = nv;
    }

    c->sws = sws_alloc_context();
    c->sws->flags = SWS_BICUBIC | SWS_ACCURATE_RND;
    c->sws->threads = 0;

    // Try full resolution first; phones whose encoder can't handle it get a smaller (scaled) copy.
    static const int limits[][2] = {{0, 0}, {2560, 1440}, {1920, 1080}, {1280, 720}};
    int started = 0;
    for (int i = 0; i < 4 && !started; i++) {
        int long_side = FFMAX(c->src_width, c->src_height), short_side = FFMIN(c->src_width, c->src_height);
        double scale = 1.0;
        if (i > 0) {
            if (long_side <= limits[i][0] && short_side <= limits[i][1]) continue;
            scale = FFMIN((double) limits[i][0] / long_side, (double) limits[i][1] / short_side);
        }
        c->width = (int) (c->src_width * scale) & ~1;
        c->height = (int) (c->src_height * scale) & ~1;
        int bitrate = (int) (video_bitrate * scale * scale);
        started = start_encoder(c, bitrate, fps) >= 0;
    }
    if (!started) {
        set_error(c, "This phone's video encoder can't make a copy of this clip", 0);
        goto end;
    }
    c->out_vst->codecpar->width = c->width;
    c->out_vst->codecpar->height = c->height;

    ret = avio_open(&c->out->pb, out_path, AVIO_FLAG_WRITE);
    if (ret < 0) {
        set_error(c, "Couldn't write to the output folder", ret);
        goto end;
    }

    c->started_at = now_sec();
    report(c, 1);
    while (!c->error[0]) {
        if (atomic_load(&g_cancel)) {
            ret = AVERROR_EXIT;
            break;
        }
        ret = av_read_frame(c->in, pkt);
        if (ret == AVERROR_EOF || (ret == AVERROR(EIO) && avio_feof(c->in->pb))) {
            ret = 0;
            break;
        }
        if (ret < 0) {
            set_error(c, "Couldn't read the video file", ret);
            break;
        }
        if (pkt->stream_index == c->vidx) ret = decode_video(c, pkt);
        else if (pkt->stream_index == c->aidx) ret = process_audio(c, pkt);
        av_packet_unref(pkt);
        if (ret < 0) break;
    }

    if (ret >= 0 && !c->error[0]) ret = decode_video(c, NULL);
    if (ret >= 0 && !c->error[0] && c->aidx >= 0) ret = process_audio(c, NULL);
    if (ret >= 0 && !c->error[0]) ret = signal_encoder_eos(c);
    for (int i = 0; ret >= 0 && !c->error[0] && !c->encoder_eos && i < 4000; i++) {
        if (atomic_load(&g_cancel)) {
            ret = AVERROR_EXIT;
            break;
        }
        ret = drain_encoder(c, 10000);
    }
    if (ret >= 0 && !c->error[0] && !c->encoder_eos) set_error(c, "The phone's video encoder didn't finish", 0);
    if (ret >= 0 && !c->error[0] && !c->header_written) set_error(c, "The phone's video encoder produced no video", 0);
    if (ret >= 0 && !c->error[0]) {
        ret = av_write_trailer(c->out);
        if (ret < 0) set_error(c, "Couldn't finish writing the converted file", ret);
        else report(c, 1);
    }
    if (ret == AVERROR_EXIT && !c->error[0]) snprintf(c->error, sizeof(c->error), "cancelled");

end:
    {
        double elapsed = now_sec() - c->started_at;
        if (c->frames_in > 0 && elapsed > 0)
            LOGI("converted %lld frames in %.1f s = %.1f fps (%s decode)", (long long) c->frames_in, elapsed,
                 c->frames_in / elapsed, c->gpu_decode ? "GPU" : "CPU");
    }
    if (c->enc) {
        AMediaCodec_stop(c->enc);
        AMediaCodec_delete(c->enc);
    }
    for (int i = 0; i < c->nb_pending; i++) av_packet_free(&c->pending[i]);
    av_freep(&c->pending);
    if (c->out) {
        if (c->out->pb) avio_closep(&c->out->pb);
        avformat_free_context(c->out);
    }
    av_packet_free(&pkt);
    avcodec_free_context(&c->vdec);
    av_frame_free(&c->dl);
    av_buffer_unref(&c->gpu);
    avcodec_free_context(&c->adec);
    avcodec_free_context(&c->aenc);
    swr_free(&c->swr);
    if (c->fifo) av_audio_fifo_free(c->fifo);
    sws_free_context(&c->sws);
    avformat_close_input(&c->in);
    (*env)->ReleaseStringUTFChars(env, jin, in_path);
    (*env)->ReleaseStringUTFChars(env, jout, out_path);
    return c->error[0] ? (*env)->NewStringUTF(env, c->error) : NULL;
}
