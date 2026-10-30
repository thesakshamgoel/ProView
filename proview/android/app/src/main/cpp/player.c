// ProView preview player for formats Android can't play (ProRes, HEVC 4:2:2, DNxHR...).
// ProRes decodes on the GPU (FFmpeg's Vulkan compute decoder); other codecs decode on all CPU cores.
// Frames are drawn by vkrender.c (10-bit swapchain, shader colour conversion) with a CPU/ANativeWindow
// fallback for devices without usable Vulkan. Audio plays through AAudio and is the master clock.
// Intra-only codecs skip whole frames when the phone falls behind; others relax deblocking.

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <jni.h>
#include <dirent.h>
#include <dlfcn.h>
#include <sched.h>
#include <sys/syscall.h>
#include <aaudio/AAudio.h>
#include <android/log.h>
#include <android/native_window_jni.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <sys/resource.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/display.h>
#include <libavutil/hwcontext.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

#include "vkrender.h"

#define TAG "ProViewPlayer"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

static double mono_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

// ---------------------------------------------------------------------------
// Audio packet queue

typedef struct {
    AVPacket **items;
    int cap, head, count;
} PktQueue;

static void q_push(PktQueue *q, AVPacket *p) {
    if (q->count == q->cap) {
        int ncap = q->cap ? q->cap * 2 : 256;
        AVPacket **n = av_malloc_array(ncap, sizeof(*n));
        for (int i = 0; i < q->count; i++) n[i] = q->items[(q->head + i) % q->cap];
        av_free(q->items);
        q->items = n;
        q->cap = ncap;
        q->head = 0;
    }
    q->items[(q->head + q->count++) % q->cap] = p;
}

static AVPacket *q_pop(PktQueue *q) {
    if (!q->count) return NULL;
    AVPacket *p = q->items[q->head];
    q->head = (q->head + 1) % q->cap;
    q->count--;
    return p;
}

static void q_clear(PktQueue *q) {
    AVPacket *p;
    while ((p = q_pop(q))) av_packet_free(&p);
}

// ---------------------------------------------------------------------------

typedef struct Player {
    pthread_mutex_t lock;
    pthread_cond_t cond;
    pthread_t video_thread, audio_thread, present_thread;
    int threads_started, present_started;
    pthread_mutex_t cpu_lock;  // serialises the CPU output path (video thread and presenter can both reach it)
    // Decode-ahead queue: the video thread decodes into it without ever sleeping for timing; the presenter
    // thread owns pacing, dropping and drawing. Guarded by lock.
    AVFrame *fq[8];
    double fq_t[8];
    int fq_imm[8];             // show immediately (first frame, after a seek or step)
    int fq_head, fq_count, fq_cap;
    double headroom_ms;        // how far ahead of the clock frames arrive (negative: decoder is behind)
    int threads;               // decoder threads in use
    // Performance tuning (see tune_load): ADPF hint session, core pinning
    int fast_cpus[16], n_fast;
    int32_t hint_tids[24];
    int n_hint_tids;
    void *hint;                // APerformanceHintSession
    int hint_tried;
    int tune_adpf, tune_affinity, tune_threads, tune_stage, tune_gpudec;
    int32_t present_tid;
    double t_read, t_send, t_recv, t_wait, t_disp;   // seconds spent per stage (perf log)
    int64_t dec_frames;        // frames received from the decoder
    double perf_t0, perf_disp0;
    int64_t perf_dec0, perf_shown0, perf_drop0;

    AVFormatContext *fmt;
    int vidx, aidx;
    AVCodecContext *vdec, *adec;
    int intra_only;
    double frame_dur;
    double duration;
    int width, height;

    // Display
    ANativeWindow *window;
    int view_w, view_h;
    int window_serial;         // bumped by setSurface; the video thread applies it to the GPU renderer
    int out_w, out_h;
    SwsContext *sws;
    int smooth;
    int rotation;              // clockwise degrees from the container's display matrix
    VkRender *vk;              // GPU output, NULL when Vulkan isn't usable
    int vk_serial;             // window_serial last applied to vk (video thread only)
    int cpu_output;            // GPU output failed; draw with the CPU from now on
    int gpu_decode;            // frames come from the Vulkan ProRes decoder
    int catchup;               // quality stage 0..2, see adapt_catchup
    int late_run, late_far, probing, no_stage2, no_stage3;
    double last_draw;
    int64_t stage_dec0;
    double stage_since, probe_interval;
    AVFrame *sw_frame;         // download target when GPU frames must be drawn by the CPU path

    // Audio
    AAudioStream *stream;
    int sample_rate, channels;
    SwrContext *swr;
    AVFormatContext *afmt;     // the audio thread's own demuxer, so audio reads ahead independently of video
    double audio_target;       // where the audio demuxer must seek when audio_serial changes
    PktQueue aq;
    int audio_serial;          // bumped on seek; audio thread flushes when it changes
    double audio_base_pts;     // pts of the first sample written after the last flush
    int64_t audio_written_base;
    int audio_base_valid;
    int64_t ats_pos, ats_t;    // cached AAudio timestamp (frames, ns); extrapolated between refreshes
    double ats_checked;
    int ats_valid;
    float volume;

    // Playback state (guarded by lock)
    int quit;
    int playing;
    int completed;
    int buffering;
    double rate;
    int seek_pending;
    double seek_target;
    int step_request;          // +1 next frame, -1 previous frame
    double frozen_clock;       // clock value while paused
    double sys_base_pts, sys_base_time;
    double position;
    int64_t dropped, shown;
    double display_time, lock_time;
    char error[256];
} Player;

static double get_clock(Player *p) {
    if (!p->playing || p->buffering) return p->frozen_clock;
    if (p->stream && p->rate == 1.0 && p->audio_base_valid) {
        double now = mono_now();
        // AAudioStream_getTimestamp is an IPC to the audio server and can take milliseconds. A
        // (position, time) pair stays valid, so ask rarely and extrapolate in between.
        if (!p->ats_valid || now - p->ats_checked > 0.1) {
            int64_t pos, t;
            p->ats_checked = now;
            if (AAudioStream_getTimestamp(p->stream, CLOCK_MONOTONIC, &pos, &t) == AAUDIO_OK &&
                pos >= p->audio_written_base && now - t / 1e9 < 0.25) {
                p->ats_pos = pos;
                p->ats_t = t;
                p->ats_valid = 1;
            }
        }
        if (p->ats_valid && p->ats_pos >= p->audio_written_base && now - p->ats_t / 1e9 < 0.6) {
            return p->audio_base_pts + (double) (p->ats_pos - p->audio_written_base) / p->sample_rate +
                   (now - p->ats_t / 1e9);
        }
    }
    return p->sys_base_pts + (mono_now() - p->sys_base_time) * p->rate;
}

// Restarts the system clock from the current position (after pause, seek or rate change).
static void rebase_clock(Player *p, double at) {
    p->frozen_clock = at;
    p->sys_base_pts = at;
    p->sys_base_time = mono_now();
}

static void fq_clear(Player *p) {
    for (int i = 0; i < p->fq_count; i++) av_frame_free(&p->fq[(p->fq_head + i) % 8]);
    p->fq_head = p->fq_count = 0;
}

// ---------------------------------------------------------------------------
// Performance: keep decoding on the fast cores and tell Android the per-frame deadline (ADPF), so the
// governor raises clocks instead of leaving cores half-speed while decoder threads wait on each other.

static struct {
    void *(*get_manager)(void);
    void *(*create)(void *, const int32_t *, size_t, int64_t);
    int (*update)(void *, int64_t);
    int (*report)(void *, int64_t);
    void (*close)(void *);
    int loaded;
} adpf;

static int adpf_load(void) {
    if (adpf.loaded) return adpf.loaded > 0;
    adpf.loaded = -1;
    void *h = dlopen("libandroid.so", RTLD_NOW);
    if (!h) return 0;
    adpf.get_manager = dlsym(h, "APerformanceHint_getManager");
    adpf.create = dlsym(h, "APerformanceHint_createSession");
    adpf.update = dlsym(h, "APerformanceHint_updateTargetWorkDuration");
    adpf.report = dlsym(h, "APerformanceHint_reportActualWorkDuration");
    adpf.close = dlsym(h, "APerformanceHint_closeSession");
    if (!adpf.get_manager || !adpf.create || !adpf.update || !adpf.report || !adpf.close) return 0;
    adpf.loaded = 1;
    return 1;
}

static int list_tids(int32_t *out, int max) {
    DIR *d = opendir("/proc/self/task");
    int n = 0;
    if (!d) return 0;
    struct dirent *e;
    while ((e = readdir(d)) && n < max)
        if (e->d_name[0] >= '0' && e->d_name[0] <= '9') out[n++] = atoi(e->d_name);
    closedir(d);
    return n;
}

static int32_t my_tid(void) { return (int32_t) syscall(SYS_gettid); }

static void pin_to_fast_cores(Player *p) {
    if (!p->tune_affinity || p->n_fast < 2) return;
    cpu_set_t set;
    CPU_ZERO(&set);
    for (int i = 0; i < p->n_fast; i++) CPU_SET(p->fast_cpus[i], &set);
    sched_setaffinity(0, sizeof(set), &set);
}

static void unpin(void) {
    cpu_set_t set;
    CPU_ZERO(&set);
    long n = sysconf(_SC_NPROCESSORS_CONF);
    for (long i = 0; i < n && i < CPU_SETSIZE; i++) CPU_SET(i, &set);
    sched_setaffinity(0, sizeof(set), &set);
}

// Creates the hint session once the video and presenter threads are running.
static void hint_start(Player *p) {
    if (p->hint_tried || !p->tune_adpf || !adpf_load()) return;
    p->hint_tried = 1;
    int32_t tids[28];
    int n = 0;
    for (int i = 0; i < p->n_hint_tids && n < 24; i++) tids[n++] = p->hint_tids[i];
    tids[n++] = my_tid();
    if (p->present_tid) tids[n++] = p->present_tid;
    void *mgr = adpf.get_manager();
    if (!mgr) return;
    p->hint = adpf.create(mgr, tids, n, (int64_t) (p->frame_dur * 0.9 * 1e9));
    LOGI("ADPF hint session %s (%d threads, target %.1f ms)", p->hint ? "created" : "unavailable", n,
         p->frame_dur * 900.0);
}

static void hint_report(Player *p, double seconds) {
    if (p->hint && seconds > 0) adpf.report(p->hint, (int64_t) (seconds * 1e9));
}

// Optional overrides for experiments, set from an intent extra: "threads=8,adpf=0,affinity=1".
char proview_tune[128];   // also read by the conversion engine

static void tune_load(Player *p) {
    p->tune_adpf = 1;
    p->tune_affinity = 1;
    p->tune_threads = 0;
    p->tune_stage = -1;
    p->tune_gpudec = 0;
    if (!proview_tune[0]) return;
    int v;
    const char *s = proview_tune;
    if ((s = strstr(proview_tune, "threads=")) && sscanf(s, "threads=%d", &v) == 1) p->tune_threads = v;
    if ((s = strstr(proview_tune, "adpf=")) && sscanf(s, "adpf=%d", &v) == 1) p->tune_adpf = v;
    if ((s = strstr(proview_tune, "affinity=")) && sscanf(s, "affinity=%d", &v) == 1) p->tune_affinity = v;
    if ((s = strstr(proview_tune, "stage=")) && sscanf(s, "stage=%d", &v) == 1) p->tune_stage = v;
    if ((s = strstr(proview_tune, "gpudec=")) && sscanf(s, "gpudec=%d", &v) == 1) p->tune_gpudec = v;
    LOGI("tune: threads=%d adpf=%d affinity=%d", p->tune_threads, p->tune_adpf, p->tune_affinity);
}

// ---------------------------------------------------------------------------
// Video output

// Applies a pending window change to the GPU renderer. Presenter thread only; lock must not be held.
static void sync_gpu_window(Player *p) {
    pthread_mutex_lock(&p->lock);
    int serial = p->window_serial;
    ANativeWindow *win = p->window;
    if (win) ANativeWindow_acquire(win);
    int w = p->view_w, h = p->view_h;
    pthread_mutex_unlock(&p->lock);
    if (serial != p->vk_serial) {
        vkr_set_window(p->vk, p->cpu_output ? NULL : win, w, h);
        pthread_mutex_lock(&p->lock);
        p->vk_serial = serial;
        pthread_cond_broadcast(&p->cond);
        pthread_mutex_unlock(&p->lock);
    }
    if (win) ANativeWindow_release(win);
}

static void display_cpu(Player *p, AVFrame *frame);

// CPU output: download GPU frames if needed, convert with swscale and post to the window.
static void display_sw(Player *p, AVFrame *frame) {
    pthread_mutex_lock(&p->cpu_lock);
    if (frame->format == AV_PIX_FMT_VULKAN) {
        if (!p->sw_frame) p->sw_frame = av_frame_alloc();
        av_frame_unref(p->sw_frame);
        if (av_hwframe_transfer_data(p->sw_frame, frame, 0) >= 0) {
            av_frame_copy_props(p->sw_frame, frame);
            display_cpu(p, p->sw_frame);
        }
    } else {
        display_cpu(p, frame);
    }
    pthread_mutex_unlock(&p->cpu_lock);
}

// Waits on the condition for up to `sec` seconds (lock must be held).
static void timed_wait(Player *p, double sec);

static void adapt_catchup(Player *p, double late);

// Draws a frame on the GPU, falling back to the CPU path if the GPU output fails.
static void draw_frame(Player *p, AVFrame *f) {
    if (p->vk && !p->cpu_output) {
        sync_gpu_window(p);
        VkrView view = {0, p->rotation};
        double t0 = mono_now();
        int ret = vkr_draw(p->vk, f, &view);
        p->display_time += mono_now() - t0;
        if (ret >= 0) return;
        LOGE("GPU output failed (%s); switching to CPU output", av_err2str(ret));
        pthread_mutex_lock(&p->lock);
        p->cpu_output = 1;
        p->vk_serial = -1;
        pthread_cond_broadcast(&p->cond);
        pthread_mutex_unlock(&p->lock);
        vkr_set_window(p->vk, NULL, 0, 0);
    }
    double t0 = mono_now();
    display_sw(p, f);
    p->display_time += mono_now() - t0;
}

// Presenter: owns pacing against the audio clock, late-frame dropping and drawing. Because the video thread
// decodes ahead into a queue and never sleeps for timing, every decoder thread stays busy.
static void *present_main(void *arg) {
    Player *p = arg;
    p->present_tid = my_tid();
    setpriority(PRIO_PROCESS, 0, -8);
    for (;;) {
        AVFrame *f = NULL;
        double ft = 0, late = 0;
        int imm = 0, take = 0;
        pthread_mutex_lock(&p->lock);
        for (;;) {
            if (p->quit) break;
            if (p->fq_count > 0) {
                if (p->fq_imm[p->fq_head]) {
                    take = 1;
                    break;
                }
                if (p->playing && !p->buffering) {
                    double wait = (p->fq_t[p->fq_head] - get_clock(p)) / FFMAX(p->rate, 0.1);
                    if (wait <= 0.002) {
                        take = 1;
                        break;
                    }
                    if (p->vk && !p->cpu_output && p->window_serial != p->vk_serial) break;
                    timed_wait(p, FFMIN(wait, 0.05));
                    continue;
                }
            }
            if (p->vk && !p->cpu_output && p->window_serial != p->vk_serial) break;
            timed_wait(p, p->fq_count > 0 ? 0.1 : 0.25);
        }
        if (p->quit) {
            pthread_mutex_unlock(&p->lock);
            break;
        }
        if (take) {
            f = p->fq[p->fq_head];
            ft = p->fq_t[p->fq_head];
            imm = p->fq_imm[p->fq_head];
            p->fq[p->fq_head] = NULL;
            p->fq_head = (p->fq_head + 1) % 8;
            p->fq_count--;
            late = get_clock(p) - ft;
            p->position = ft;
            if (!imm) p->headroom_ms = p->headroom_ms * 0.92 - late * 1000.0 * 0.08;
            pthread_cond_broadcast(&p->cond);   // room in the queue for the decoder
        }
        pthread_mutex_unlock(&p->lock);

        if (!f) {   // window attached / resized: repaint the current frame
            if (p->vk && !p->cpu_output) {
                sync_gpu_window(p);
                VkrView view = {0, p->rotation};
                vkr_redraw(p->vk, &view);
            }
            continue;
        }
        if (!imm && !p->intra_only && !p->gpu_decode) adapt_catchup(p, late);
        if (!imm && late > 0.1 && !p->intra_only && mono_now() - p->last_draw < 0.5) {
            p->dropped++;   // decoded but too late to show
        } else {
            // (Far behind we still show a frame every half second, so the picture never goes black.)
            draw_frame(p, f);
            p->last_draw = mono_now();
            p->shown++;
        }
        av_frame_free(&f);
    }
    return NULL;
}

static void display_cpu(Player *p, AVFrame *frame) {
    pthread_mutex_lock(&p->lock);
    ANativeWindow *win = p->window;
    if (win) ANativeWindow_acquire(win);
    int vw = p->view_w, vh = p->view_h, smooth = p->smooth;
    pthread_mutex_unlock(&p->lock);
    if (!win) return;

    // Render at the smaller of the video size and the on-screen size (saves a lot of CPU on 4K).
    int w = frame->width, h = frame->height;
    if (vw > 0 && vh > 0) {
        double s = FFMIN(1.0, FFMIN((double) vw / w, (double) vh / h));
        w = FFMAX(2, (int) (w * s) & ~1);
        h = FFMAX(2, (int) (h * s) & ~1);
    }
    if (w != p->out_w || h != p->out_h) {
        ANativeWindow_setBuffersGeometry(win, w, h, WINDOW_FORMAT_RGBA_8888);
        p->out_w = w;
        p->out_h = h;
    }
    ANativeWindow_Buffer buf;
    double t0 = mono_now();
    if (ANativeWindow_lock(win, &buf, NULL) == 0) {
        p->lock_time += mono_now() - t0;
        if (!p->sws) {
            p->sws = sws_alloc_context();
            p->sws->threads = 0;
        }
        // Ordered dithering hides banding when 10-bit video becomes 8-bit RGB, and (unlike error
        // diffusion) it runs on all cores: ~3 ms per 4K frame instead of ~17 ms.
        p->sws->flags = SWS_BILINEAR;
        p->sws->dither = smooth ? SWS_DITHER_BAYER : SWS_DITHER_NONE;
        AVFrame *dst = av_frame_alloc();
        dst->width = buf.width;
        dst->height = buf.height;
        dst->format = AV_PIX_FMT_RGBA;
        dst->color_range = AVCOL_RANGE_JPEG;
        dst->data[0] = buf.bits;
        dst->linesize[0] = buf.stride * 4;
        if (frame->color_range == AVCOL_RANGE_UNSPECIFIED) frame->color_range = AVCOL_RANGE_MPEG;
        if (frame->colorspace == AVCOL_SPC_UNSPECIFIED)
            frame->colorspace = frame->height >= 720 ? AVCOL_SPC_BT709 : AVCOL_SPC_SMPTE170M;
        sws_scale_frame(p->sws, dst, frame);
        av_frame_free(&dst);
        ANativeWindow_unlockAndPost(win);
    }
    p->display_time += mono_now() - t0;
    ANativeWindow_release(win);
}

static double frame_time(Player *p, AVFrame *f) {
    AVStream *st = p->fmt->streams[p->vidx];
    int64_t pts = f->best_effort_timestamp != AV_NOPTS_VALUE ? f->best_effort_timestamp : f->pts;
    if (pts == AV_NOPTS_VALUE) return p->position + p->frame_dur;
    double t = pts * av_q2d(st->time_base);
    if (st->start_time != AV_NOPTS_VALUE) t -= st->start_time * av_q2d(st->time_base);
    return t;
}

static int is_intra_only(enum AVCodecID id) {
    const AVCodecDescriptor *d = avcodec_descriptor_get(id);
    return d && (d->props & AV_CODEC_PROP_INTRA_ONLY);
}

// Waits on the condition for up to `sec` seconds (lock must be held).
static void timed_wait(Player *p, double sec) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    long ns = ts.tv_nsec + (long) (sec * 1e9);
    ts.tv_sec += ns / 1000000000L;
    ts.tv_nsec = ns % 1000000000L;
    pthread_cond_timedwait(&p->cond, &p->lock, &ts);
}

static void do_seek(Player *p, double target) {
    AVStream *st = p->fmt->streams[p->vidx];
    int64_t ts = (int64_t) (target / av_q2d(st->time_base));
    if (st->start_time != AV_NOPTS_VALUE) ts += st->start_time;
    av_seek_frame(p->fmt, p->vidx, ts, AVSEEK_FLAG_BACKWARD);
    avcodec_flush_buffers(p->vdec);
    pthread_mutex_lock(&p->lock);
    q_clear(&p->aq);
    fq_clear(p);
    p->audio_target = target;
    p->audio_serial++;
    p->audio_base_valid = 0;
    p->ats_valid = 0;
    p->completed = 0;
    pthread_cond_broadcast(&p->cond);
    pthread_mutex_unlock(&p->lock);
}

// Quality ladder for CPU-decoded inter-frame codecs (HEVC 4:2:2 ...) that can't keep up in real time:
//   0 full quality   1 loop filter off (slightly softer)   2 B-frames skipped (a lower but steady frame
//   rate looks far better than an irregular 45)   3 keyframes only (a slideshow with sound, for clips far
//   beyond this CPU while a smooth copy is prepared). Stages 2 and 3 are withdrawn if they yield no frames.
// The player escalates after sustained lateness and periodically probes one step back up.
static void set_stage(Player *p, int stage) {
    p->catchup = stage;
    p->vdec->skip_loop_filter = stage >= 1 ? AVDISCARD_ALL : AVDISCARD_DEFAULT;
    p->vdec->skip_frame = stage >= 3 ? AVDISCARD_NONINTRA : (stage == 2 ? AVDISCARD_BIDIR : AVDISCARD_DEFAULT);
    p->stage_dec0 = p->dec_frames;
}

static void adapt_catchup(Player *p, double late) {
    if (p->tune_stage >= 0) return;   // experiment: stage locked
    double now = mono_now();
    // Hopeless (frames arriving seconds late): go straight to the keyframe preview instead of climbing.
    p->late_far = late > 2.0 ? p->late_far + 1 : 0;
    if (p->late_far >= 8 && p->catchup < 3 && !p->no_stage3) {
        if (p->probing) p->probe_interval = FFMIN(p->probe_interval * 2, 120.0);
        p->probing = 0;
        set_stage(p, 3);
        p->late_run = p->late_far = 0;
        p->stage_since = now;
        LOGI("far behind (%.1f s); keyframe preview", late);
        return;
    }
    // Frame threads deliver in bursts, so judge by the smoothed lead over the clock, not single frames.
    int sustain = (int) ((p->catchup == 0 ? 1.5 : 3.0) / p->frame_dur);
    // Stage 3 is only for hopeless clips: still more than a second behind after skipping B-frames.
    double behind = p->catchup >= 2 ? -1200.0 : -35.0;
    if (p->headroom_ms < behind) {
        p->late_run++;
    } else if (p->headroom_ms > behind + 25.0) {
        p->late_run = 0;
    }
    int next_ok = p->catchup == 2 ? !p->no_stage3 : !(p->catchup == 1 && p->no_stage2);
    if (p->late_run >= sustain && p->catchup < 3 && next_ok) {
        if (p->probing) p->probe_interval = FFMIN(p->probe_interval * 2, 120.0);
        p->probing = 0;
        set_stage(p, p->catchup + 1);
        p->late_run = 0;
        p->stage_since = now;
        LOGI("falling behind; quality stage %d", p->catchup);
        return;
    }
    if (p->catchup > 0) {
        if (p->probing && now - p->stage_since > 4.0) {   // survived a probe at the lower stage
            p->probing = 0;
            p->probe_interval = 15.0;
        }
        if (!p->probing && now - p->stage_since > p->probe_interval) {
            set_stage(p, p->catchup - 1);
            p->probing = 1;
            p->late_run = 0;
            p->stage_since = now;
            LOGI("probing quality stage %d", p->catchup);
        }
    }
}

static void *video_main(void *arg) {
    Player *p = arg;
    setpriority(PRIO_PROCESS, 0, -8);   // Android lets apps raise a thread above normal priority
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    double seek_target = -1;     // discard frames before this (accurate seek)
    int show_next = 1;           // show the next decoded frame immediately (start / after seek / step)
    int eof = 0;

    for (;;) {
        // Skipping B-frames only works when the stream mixes P and B; all-B streams would go silent.
        if (p->catchup == 2 && mono_now() - p->stage_since > 1.5 && p->dec_frames - p->stage_dec0 < 3) {
            LOGI("B-frame skipping produced no frames; withdrawing");
            set_stage(p, 1);
            p->no_stage2 = 1;
            p->stage_since = mono_now();
        }
        if (p->catchup == 3 && mono_now() - p->stage_since > 4.0 && p->dec_frames - p->stage_dec0 < 1) {
            LOGI("keyframe-only decoding produced no frames; withdrawing");
            set_stage(p, 2);
            p->no_stage3 = 1;
            p->stage_since = mono_now();
        }
        pthread_mutex_lock(&p->lock);
        if (p->quit) {
            pthread_mutex_unlock(&p->lock);
            break;
        }
        if (p->seek_pending) {
            double t = p->seek_target;
            p->seek_pending = 0;
            rebase_clock(p, t);
            p->position = t;
            pthread_mutex_unlock(&p->lock);
            do_seek(p, t);
            seek_target = t;
            show_next = 1;
            eof = 0;
            continue;
        }
        if (p->step_request < 0) {
            // Previous frame: seek accurately to one frame before the current one.
            double t = FFMAX(0, p->position - p->frame_dur);
            p->step_request = 0;
            p->seek_pending = 1;
            p->seek_target = t;
            pthread_mutex_unlock(&p->lock);
            continue;
        }
        int stepping = p->step_request > 0;
        if ((!p->playing && !show_next && !stepping) || (eof && p->completed)) {
            timed_wait(p, 0.1);
            pthread_mutex_unlock(&p->lock);
            continue;
        }
        pthread_mutex_unlock(&p->lock);

        double dec_t0 = mono_now();
        int ret = eof ? AVERROR_EOF : av_read_frame(p->fmt, pkt);
        p->t_read += mono_now() - dec_t0;
        if (ret < 0) {
            if (!eof) {
                eof = 1;
                avcodec_send_packet(p->vdec, NULL);
            }
        } else if (pkt->stream_index != p->vidx) {   // audio is read by the audio thread's own demuxer
            av_packet_unref(pkt);
            continue;
        } else {
            // Behind schedule on an intra-only codec: skip decoding this frame entirely.
            if (p->intra_only && !show_next && !stepping && seek_target < 0 && pkt->pts != AV_NOPTS_VALUE) {
                AVStream *st = p->fmt->streams[p->vidx];
                double t = pkt->pts * av_q2d(st->time_base) -
                           (st->start_time != AV_NOPTS_VALUE ? st->start_time * av_q2d(st->time_base) : 0);
                pthread_mutex_lock(&p->lock);
                double late = get_clock(p) - t;
                pthread_mutex_unlock(&p->lock);
                if (late > p->frame_dur * 1.5) {
                    p->dropped++;
                    av_packet_unref(pkt);
                    continue;
                }
            }
            double ts = mono_now();
            avcodec_send_packet(p->vdec, pkt);
            p->t_send += mono_now() - ts;
            av_packet_unref(pkt);
        }

        for (;;) {
            double tr = mono_now();
            ret = avcodec_receive_frame(p->vdec, frame);
            p->t_recv += mono_now() - tr;
            if (ret == AVERROR_EOF) {
                pthread_mutex_lock(&p->lock);
                while (!p->quit && !p->seek_pending && p->fq_count > 0) timed_wait(p, 0.05);
                if (p->quit || p->seek_pending) {
                    pthread_mutex_unlock(&p->lock);
                    break;
                }
                p->completed = 1;
                p->playing = 0;
                p->frozen_clock = p->position;
                if (p->stream) AAudioStream_requestPause(p->stream);
                pthread_mutex_unlock(&p->lock);
                break;
            }
            if (ret < 0) break;
            double t = frame_time(p, frame);
            p->dec_frames++;
            hint_report(p, mono_now() - dec_t0);
            dec_t0 = mono_now();
            if (!p->hint_tried && p->dec_frames > 30) hint_start(p);
            {
                double now = mono_now();
                if (p->perf_t0 == 0) p->perf_t0 = now;
                if (now - p->perf_t0 >= 2.0) {
                    double dt = now - p->perf_t0;
                    int64_t sh = p->shown - p->perf_shown0;
                    double nf = FFMAX(1, p->dec_frames - p->perf_dec0);
                    LOGI("perf: decoded %.1f fps, shown %.1f fps, dropped %lld, present %.1f ms, headroom %.0f ms, stage %d, threads %d, queue %d/%d, pos %.2f, xruns %d | per frame: read %.1f ms, send %.1f ms, recv %.1f ms, queue-wait %.1f ms",
                         (p->dec_frames - p->perf_dec0) / dt, sh / dt, (long long) (p->dropped - p->perf_drop0),
                         sh > 0 ? (p->display_time - p->perf_disp0) * 1000.0 / sh : 0.0, p->headroom_ms, p->catchup,
                         p->threads, p->fq_count, p->fq_cap, p->position,
                         p->stream ? AAudioStream_getXRunCount(p->stream) : -1, p->t_read * 1000 / nf, p->t_send * 1000 / nf, p->t_recv * 1000 / nf,
                         p->t_wait * 1000 / nf);
                    p->t_read = p->t_send = p->t_recv = p->t_wait = 0;
                    p->perf_t0 = now;
                    p->perf_dec0 = p->dec_frames;
                    p->perf_shown0 = p->shown;
                    p->perf_drop0 = p->dropped;
                    p->perf_disp0 = p->display_time;
                }
            }
            if (seek_target >= 0 && t < seek_target - p->frame_dur * 0.5) {
                av_frame_unref(frame);
                continue;
            }
            seek_target = -1;

            pthread_mutex_lock(&p->lock);
            int immediate = show_next || p->step_request > 0;
            if (immediate) {
                p->step_request = 0;
                show_next = 0;
                p->buffering = 0;
                p->position = t;
                rebase_clock(p, t);
            }
            // Backpressure only: decode at most `fq_cap` frames ahead. No sleeping for display timing.
            double tw = mono_now();
            while (!p->quit && !p->seek_pending && p->step_request == 0 && p->fq_count >= p->fq_cap)
                timed_wait(p, 0.05);
            p->t_wait += mono_now() - tw;
            if (p->quit || p->seek_pending || p->step_request != 0) {
                pthread_mutex_unlock(&p->lock);
                av_frame_unref(frame);
                break;
            }
            int slot = (p->fq_head + p->fq_count) % 8;
            p->fq[slot] = av_frame_clone(frame);
            p->fq_t[slot] = t;
            p->fq_imm[slot] = immediate;
            if (p->fq[slot]) p->fq_count++;
            pthread_cond_broadcast(&p->cond);
            pthread_mutex_unlock(&p->lock);
            av_frame_unref(frame);
        }
    }
    av_frame_free(&frame);
    av_packet_free(&pkt);
    return NULL;
}

// ---------------------------------------------------------------------------
// Audio

static void *audio_main(void *arg) {
    Player *p = arg;
    setpriority(PRIO_PROCESS, 0, -16);   // audio must never be starved by the decoder threads
    AVFrame *frame = av_frame_alloc();
    AVPacket *pkt = av_packet_alloc();
    float *buf = NULL;
    int buf_cap = 0;
    int serial = -1;
    int stream_running = 0;
    int aeof = 0;
    AVStream *ast = p->afmt->streams[p->aidx];

    for (;;) {
        pthread_mutex_lock(&p->lock);
        while (!p->quit && (!p->playing || p->rate != 1.0 || (aeof && serial == p->audio_serial))) {
            if ((!p->playing || p->rate != 1.0) && stream_running) {
                AAudioStream_requestPause(p->stream);
                stream_running = 0;
            }
            timed_wait(p, 0.1);
        }
        if (p->quit) {
            pthread_mutex_unlock(&p->lock);
            break;
        }
        if (serial != p->audio_serial) {
            serial = p->audio_serial;
            double target = FFMAX(0, p->audio_target);
            if (stream_running) {
                AAudioStream_requestPause(p->stream);
                stream_running = 0;
            }
            pthread_mutex_unlock(&p->lock);
            aaudio_stream_state_t next;
            AAudioStream_waitForStateChange(p->stream, AAUDIO_STREAM_STATE_PAUSING, &next, 200000000LL);
            AAudioStream_requestFlush(p->stream);
            AAudioStream_waitForStateChange(p->stream, AAUDIO_STREAM_STATE_FLUSHING, &next, 200000000LL);
            int64_t ts = (int64_t) (target / av_q2d(ast->time_base));
            if (ast->start_time != AV_NOPTS_VALUE) ts += ast->start_time;
            av_seek_frame(p->afmt, p->aidx, ts, AVSEEK_FLAG_BACKWARD);
            avcodec_flush_buffers(p->adec);
            swr_close(p->swr);
            swr_init(p->swr);
            aeof = 0;
            continue;
        }
        double seek_floor = p->audio_target - 0.02;
        int need_base = !p->audio_base_valid;
        pthread_mutex_unlock(&p->lock);

        if (!stream_running) {
            AAudioStream_requestStart(p->stream);
            stream_running = 1;
        }
        // Read a long way ahead of playback (the audio buffer is tiny, a stalled read would underrun).
        int ret = av_read_frame(p->afmt, pkt);
        if (ret < 0) {
            aeof = 1;
            continue;
        }
        if (pkt->stream_index != p->aidx) {
            av_packet_unref(pkt);
            continue;
        }
        avcodec_send_packet(p->adec, pkt);
        av_packet_unref(pkt);
        while (avcodec_receive_frame(p->adec, frame) == 0) {
            int64_t pts = frame->best_effort_timestamp;
            double t = pts == AV_NOPTS_VALUE ? -1 : pts * av_q2d(ast->time_base) -
                       (ast->start_time != AV_NOPTS_VALUE ? ast->start_time * av_q2d(ast->time_base) : 0);
            // After a seek, drop audio from before the target so it lines up with the video.
            if (need_base && t >= 0 && t + (double) frame->nb_samples / frame->sample_rate < seek_floor) {
                av_frame_unref(frame);
                continue;
            }
            int out = swr_get_out_samples(p->swr, frame->nb_samples);
            if (out * p->channels > buf_cap) {
                buf_cap = out * p->channels;
                av_free(buf);
                buf = av_malloc(buf_cap * sizeof(float));
            }
            uint8_t *outp[1] = {(uint8_t *) buf};
            int got = swr_convert(p->swr, outp, out, (const uint8_t **) frame->extended_data, frame->nb_samples);
            av_frame_unref(frame);
            if (got <= 0) continue;
            float vol = p->volume;
            if (vol != 1.0f)
                for (int i = 0; i < got * p->channels; i++) buf[i] *= vol;

            if (need_base) {
                pthread_mutex_lock(&p->lock);
                if (serial == p->audio_serial) {
                    p->audio_base_pts = t >= 0 ? t : p->audio_target;
                    p->audio_written_base = AAudioStream_getFramesWritten(p->stream);
                    p->ats_valid = 0;
                    p->audio_base_valid = 1;
                }
                pthread_mutex_unlock(&p->lock);
                need_base = 0;
            }
            int off = 0;
            while (off < got) {
                if (p->quit || serial != p->audio_serial || !p->playing) break;
                aaudio_result_t w = AAudioStream_write(p->stream, buf + off * p->channels, got - off, 100000000LL);
                if (w < 0) break;
                off += w;
            }
        }
    }
    if (stream_running) AAudioStream_requestStop(p->stream);
    av_free(buf);
    av_packet_free(&pkt);
    av_frame_free(&frame);
    return NULL;
}

// ---------------------------------------------------------------------------
// JNI

#define P(h) ((Player *) (intptr_t) (h))

static int open_path_ex(const char *path, AVFormatContext **out, int quick) {
    AVDictionary *opts = NULL;
    if (quick) {   // the audio demuxer only needs one stream: probe less so playback starts sooner
        av_dict_set(&opts, "probesize", "1500000", 0);
        av_dict_set(&opts, "analyzeduration", "600000", 0);
    }
    if (!strncmp(path, "fd:", 3) && path[3]) {
        av_dict_set(&opts, "fd", path + 3, 0);
        path = "fd:";
    }
    int ret = avformat_open_input(out, path, NULL, &opts);
    av_dict_free(&opts);
    if (ret >= 0) ret = avformat_find_stream_info(*out, NULL);
    return ret;
}

static int open_path(const char *path, AVFormatContext **out) { return open_path_ex(path, out, 0); }

// Number of decoder threads: the phone's fast cores only. Frame threading finishes frames in order, so
// one slow efficiency core holding up the queue costs more than the extra thread gains.
static int pick_threads(Player *p) {
    long n = sysconf(_SC_NPROCESSORS_CONF);
    if (n < 1) n = 4;
    if (n > 32) n = 32;
    long freq[32], max = 0;
    for (int i = 0; i < n; i++) {
        char path[96];
        snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq", i);
        FILE *f = fopen(path, "r");
        freq[i] = 0;
        if (f) {
            if (fscanf(f, "%ld", &freq[i]) != 1) freq[i] = 0;
            fclose(f);
        }
        if (freq[i] > max) max = freq[i];
    }
    p->n_fast = 0;
    for (int i = 0; i < n; i++)
        if (max == 0 || freq[i] >= max * 0.75) {
            if (p->n_fast < 16) p->fast_cpus[p->n_fast++] = i;
        }
    long fast = p->n_fast;
    if (fast < 2) fast = 2;
    if (fast > 8) fast = 8;
    return (int) fast;
}

static void setup_audio(Player *p) {
    AVStream *st = p->fmt->streams[p->aidx];
    const AVCodec *dec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!dec) return;
    p->adec = avcodec_alloc_context3(dec);
    avcodec_parameters_to_context(p->adec, st->codecpar);
    p->adec->pkt_timebase = st->time_base;
    if (avcodec_open2(p->adec, dec, NULL) < 0) {
        avcodec_free_context(&p->adec);
        return;
    }
    p->sample_rate = p->adec->sample_rate > 0 ? p->adec->sample_rate : 48000;
    p->channels = 2;

    AAudioStreamBuilder *b;
    if (AAudio_createStreamBuilder(&b) != AAUDIO_OK) return;
    AAudioStreamBuilder_setFormat(b, AAUDIO_FORMAT_PCM_FLOAT);
    AAudioStreamBuilder_setChannelCount(b, p->channels);
    AAudioStreamBuilder_setSampleRate(b, p->sample_rate);
    AAudioStreamBuilder_setUsage(b, AAUDIO_USAGE_MEDIA);
    AAudioStreamBuilder_setContentType(b, AAUDIO_CONTENT_TYPE_MOVIE);
    // Playback, not a low-latency instrument: favour big buffers so a busy CPU can't starve the audio clock.
    AAudioStreamBuilder_setPerformanceMode(b, AAUDIO_PERFORMANCE_MODE_POWER_SAVING);
    if (AAudioStreamBuilder_openStream(b, &p->stream) != AAUDIO_OK) p->stream = NULL;
    AAudioStreamBuilder_delete(b);
    if (!p->stream) return;
    p->sample_rate = AAudioStream_getSampleRate(p->stream);
    {
        int32_t cap = AAudioStream_getBufferCapacityInFrames(p->stream);
        int32_t want = p->sample_rate / 3;   // ~330 ms of cushion
        AAudioStream_setBufferSizeInFrames(p->stream, cap > 0 ? FFMIN(cap, want) : want);
        LOGI("audio buffer %d of %d frames", AAudioStream_getBufferSizeInFrames(p->stream), cap);
    }

    AVChannelLayout out_layout = AV_CHANNEL_LAYOUT_STEREO, in_layout;
    if (p->adec->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC)
        av_channel_layout_default(&in_layout, p->adec->ch_layout.nb_channels);
    else
        av_channel_layout_copy(&in_layout, &p->adec->ch_layout);
    swr_alloc_set_opts2(&p->swr, &out_layout, AV_SAMPLE_FMT_FLT, p->sample_rate, &in_layout,
                        p->adec->sample_fmt, p->adec->sample_rate, 0, NULL);
    av_channel_layout_uninit(&in_layout);
    if (!p->swr || swr_init(p->swr) < 0) {
        AAudioStream_close(p->stream);
        p->stream = NULL;
    }
}

// Picks the Vulkan (GPU) decoder when offered; FFmpeg calls this again without it if it can't start.
static enum AVPixelFormat get_format(AVCodecContext *avctx, const enum AVPixelFormat *fmts) {
    Player *p = avctx->opaque;
    const enum AVPixelFormat *f;
    for (f = fmts; *f != AV_PIX_FMT_NONE; f++) {
        if (*f == AV_PIX_FMT_VULKAN && p->vk) {
            p->gpu_decode = 1;
            return *f;
        }
    }
    p->gpu_decode = 0;
    for (f = fmts; *f != AV_PIX_FMT_NONE; f++) {
        const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(*f);
        if (d && !(d->flags & AV_PIX_FMT_FLAG_HWACCEL)) return *f;
    }
    return fmts[0];
}

JNIEXPORT void JNICALL
Java_app_proview_proview_NativePlayer_setTune(JNIEnv *env, jclass cls, jstring jtune) {
    const char *t = (*env)->GetStringUTFChars(env, jtune, NULL);
    snprintf(proview_tune, sizeof(proview_tune), "%s", t);
    (*env)->ReleaseStringUTFChars(env, jtune, t);
}

JNIEXPORT jlong JNICALL
Java_app_proview_proview_NativePlayer_create(JNIEnv *env, jclass cls) {
    Player *p = av_mallocz(sizeof(Player));
    pthread_mutex_init(&p->lock, NULL);
    pthread_cond_init(&p->cond, NULL);
    pthread_mutex_init(&p->cpu_lock, NULL);
    p->vidx = p->aidx = -1;
    p->rate = 1.0;
    p->volume = 1.0f;
    p->buffering = 1;
    p->smooth = 1;
    p->probe_interval = 15.0;
    return (jlong) (intptr_t) p;
}

// Opens the file and starts the decoding threads (paused). Returns null or an error message.
JNIEXPORT jstring JNICALL
Java_app_proview_proview_NativePlayer_open(JNIEnv *env, jclass cls, jlong h, jstring jpath, jstring jaudio) {
    Player *p = P(h);
    const char *path = (*env)->GetStringUTFChars(env, jpath, NULL);
    // Audio gets its own descriptor (an independent read position) and demuxer.
    const char *apath = (*env)->GetStringUTFChars(env, jaudio, NULL);
    char *path_copy = strdup(apath);
    (*env)->ReleaseStringUTFChars(env, jaudio, apath);
    int ret = open_path(path, &p->fmt);
    (*env)->ReleaseStringUTFChars(env, jpath, path);
    if (ret < 0) {
        free(path_copy);
        return (*env)->NewStringUTF(env, "Couldn't open this file");
    }

    p->vidx = av_find_best_stream(p->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (p->vidx < 0) return (*env)->NewStringUTF(env, "This file has no video");
    AVStream *st = p->fmt->streams[p->vidx];
    const AVCodec *dec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!dec) return (*env)->NewStringUTF(env, "ProView can't decode this video format");
    p->vdec = avcodec_alloc_context3(dec);
    avcodec_parameters_to_context(p->vdec, st->codecpar);
    p->vdec->pkt_timebase = st->time_base;
    tune_load(p);
    p->threads = p->tune_threads > 0 ? p->tune_threads : pick_threads(p);
    if (!p->n_fast) pick_threads(p);
    p->vdec->thread_count = p->threads;
    p->vdec->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
    p->vdec->flags2 |= AV_CODEC_FLAG2_FAST;
    p->vdec->opaque = p;
    // Decoder threads inherit this thread's priority and core affinity.
    setpriority(PRIO_PROCESS, 0, -8);
    pin_to_fast_cores(p);
    int32_t before[96], after[96];
    int n_before = list_tids(before, 96);

    p->vk = vkr_create();
    // GPU ProRes decoding is off by default: Qualcomm's Adreno shader compiler crashes (SIGSEGV in
    // libllvm-qgl.so) while compiling FFmpeg's decode shaders, and the CPU already decodes 4K60 ProRes at
    // ~75 fps on a Snapdragon 8 Gen 3. Rendering stays on the GPU. Opt in with "gpudec=1" to experiment.
    if (p->vk && p->tune_gpudec && st->codecpar->codec_id == AV_CODEC_ID_PRORES) {
        p->vdec->hw_device_ctx = av_buffer_ref(vkr_device(p->vk));
        p->vdec->get_format = get_format;
    }
    int open_ret = avcodec_open2(p->vdec, dec, NULL);
    if (open_ret >= 0 && p->tune_stage >= 0) set_stage(p, p->tune_stage);
    setpriority(PRIO_PROCESS, 0, 0);
    unpin();
    {
        int n_after = list_tids(after, 96);
        p->n_hint_tids = 0;
        for (int i = 0; i < n_after && p->n_hint_tids < 24; i++) {
            int known = 0;
            for (int j = 0; j < n_before; j++)
                if (before[j] == after[i]) known = 1;
            if (!known) p->hint_tids[p->n_hint_tids++] = after[i];
        }
    }
    if (open_ret < 0) return (*env)->NewStringUTF(env, "Couldn't start the video decoder");

    const AVPacketSideData *sd = av_packet_side_data_get(st->codecpar->coded_side_data,
                                                         st->codecpar->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
    if (sd && sd->size >= 9 * sizeof(int32_t)) {
        double theta = av_display_rotation_get((const int32_t *) sd->data);
        if (!isnan(theta)) p->rotation = (((int) lround(-theta / 90.0) * 90) % 360 + 360) % 360;
    }

    p->intra_only = is_intra_only(st->codecpar->codec_id);
    AVRational fr = st->avg_frame_rate.num ? st->avg_frame_rate : st->r_frame_rate;
    p->frame_dur = fr.num && fr.den ? av_q2d(av_inv_q(fr)) : 1.0 / 30;
    p->duration = p->fmt->duration > 0 ? p->fmt->duration / (double) AV_TIME_BASE : 0;
    p->width = st->codecpar->width;
    p->height = st->codecpar->height;
    {   // ~160 MB of 10-bit 4:2:2 frames in flight at most
        double bytes = (double) p->width * p->height * 4.0;
        int cap = (int) (160e6 / FFMAX(bytes, 1.0));
        p->fq_cap = FFMAX(2, FFMIN(8, cap));
    }

    p->aidx = av_find_best_stream(p->fmt, AVMEDIA_TYPE_AUDIO, -1, p->vidx, NULL, 0);
    if (p->aidx >= 0) setup_audio(p);
    if (p->stream && (open_path_ex(path_copy, &p->afmt, 1) < 0 || p->aidx >= (int) p->afmt->nb_streams)) {
        LOGE("couldn't open a second demuxer for audio; playing without sound");
        avformat_close_input(&p->afmt);
        AAudioStream_close(p->stream);
        p->stream = NULL;
    }
    free(path_copy);
    if (!p->stream) p->aidx = -1;

    pthread_create(&p->video_thread, NULL, video_main, p);
    pthread_create(&p->present_thread, NULL, present_main, p);
    p->present_started = 1;
    if (p->stream) pthread_create(&p->audio_thread, NULL, audio_main, p);
    p->threads_started = 1;
    LOGI("opened %dx%d %s intra=%d audio=%d gpu=%d rot=%d", p->width, p->height, dec->name, p->intra_only,
         p->stream != NULL, p->vk != NULL, p->rotation);
    return NULL;
}

JNIEXPORT void JNICALL
Java_app_proview_proview_NativePlayer_setSurface(JNIEnv *env, jclass cls, jlong h, jobject surface, jint w, jint hgt) {
    Player *p = P(h);
    ANativeWindow *win = surface ? ANativeWindow_fromSurface(env, surface) : NULL;
    pthread_mutex_lock(&p->lock);
    ANativeWindow *old = p->window;
    p->window = win;
    p->view_w = w;
    p->view_h = hgt;
    p->out_w = p->out_h = 0;
    int serial = ++p->window_serial;
    // CPU output redraws the current frame on the new surface by decoding it again.
    if (win && !p->playing && (!p->vk || p->cpu_output)) {
        p->seek_pending = 1;
        p->seek_target = p->position;
    }
    pthread_cond_broadcast(&p->cond);
    // A destroyed surface must not be drawn to after this returns: wait for the GPU renderer to let go.
    if (!win && p->vk && p->threads_started) {
        double until = mono_now() + 1.0;
        while (p->vk_serial != serial && !p->cpu_output && !p->quit && mono_now() < until) timed_wait(p, 0.05);
    }
    pthread_mutex_unlock(&p->lock);
    if (old) ANativeWindow_release(old);
}

JNIEXPORT void JNICALL
Java_app_proview_proview_NativePlayer_play(JNIEnv *env, jclass cls, jlong h) {
    Player *p = P(h);
    pthread_mutex_lock(&p->lock);
    if (p->completed) {
        p->completed = 0;
        p->seek_pending = 1;
        p->seek_target = 0;
        p->position = 0;
    }
    rebase_clock(p, p->position);
    p->playing = 1;
    pthread_cond_broadcast(&p->cond);
    pthread_mutex_unlock(&p->lock);
}

JNIEXPORT void JNICALL
Java_app_proview_proview_NativePlayer_pause(JNIEnv *env, jclass cls, jlong h) {
    Player *p = P(h);
    pthread_mutex_lock(&p->lock);
    if (p->playing) p->frozen_clock = p->position;
    p->playing = 0;
    pthread_cond_broadcast(&p->cond);
    pthread_mutex_unlock(&p->lock);
}

JNIEXPORT void JNICALL
Java_app_proview_proview_NativePlayer_seek(JNIEnv *env, jclass cls, jlong h, jdouble sec) {
    Player *p = P(h);
    pthread_mutex_lock(&p->lock);
    p->seek_pending = 1;
    p->seek_target = FFMAX(0, p->duration > 0 ? FFMIN(sec, p->duration - p->frame_dur) : sec);
    p->position = p->seek_target;
    p->completed = 0;
    pthread_cond_broadcast(&p->cond);
    pthread_mutex_unlock(&p->lock);
}

JNIEXPORT void JNICALL
Java_app_proview_proview_NativePlayer_step(JNIEnv *env, jclass cls, jlong h, jint dir) {
    Player *p = P(h);
    pthread_mutex_lock(&p->lock);
    p->playing = 0;
    p->frozen_clock = p->position;
    p->step_request = dir > 0 ? 1 : -1;
    pthread_cond_broadcast(&p->cond);
    pthread_mutex_unlock(&p->lock);
}

JNIEXPORT void JNICALL
Java_app_proview_proview_NativePlayer_setRate(JNIEnv *env, jclass cls, jlong h, jdouble rate) {
    Player *p = P(h);
    pthread_mutex_lock(&p->lock);
    double now = get_clock(p);
    p->rate = rate;
    rebase_clock(p, now);
    // Speed changes are video-only; resync audio from the current position when back at 1x.
    p->audio_target = now;
    p->audio_serial++;
    p->audio_base_valid = 0;
    p->ats_valid = 0;
    q_clear(&p->aq);
    pthread_cond_broadcast(&p->cond);
    pthread_mutex_unlock(&p->lock);
}

JNIEXPORT void JNICALL
Java_app_proview_proview_NativePlayer_setVolume(JNIEnv *env, jclass cls, jlong h, jfloat v) {
    P(h)->volume = v;
}

JNIEXPORT void JNICALL
Java_app_proview_proview_NativePlayer_setSmooth(JNIEnv *env, jclass cls, jlong h, jboolean on) {
    P(h)->smooth = on;
}

// [position, duration, playing, buffering, completed, width, height, dropped]
JNIEXPORT jdoubleArray JNICALL
Java_app_proview_proview_NativePlayer_state(JNIEnv *env, jclass cls, jlong h) {
    Player *p = P(h);
    pthread_mutex_lock(&p->lock);
    AVRational sar = p->vdec ? p->vdec->sample_aspect_ratio : (AVRational) {0, 1};
    double dw = p->width * (sar.num > 0 && sar.den > 0 ? av_q2d(sar) : 1.0), dh = p->height;
    if (p->rotation == 90 || p->rotation == 270) {
        double t = dw;
        dw = dh;
        dh = t;
    }
    double v[8] = {p->position, p->duration, p->playing, p->buffering, p->completed, dw, dh, (double) p->dropped};
    pthread_mutex_unlock(&p->lock);
    jdoubleArray arr = (*env)->NewDoubleArray(env, 8);
    (*env)->SetDoubleArrayRegion(env, arr, 0, 8, v);
    return arr;
}

// How the clip is being played, for the player's info panel: {"decode":"gpu|cpu","output":"gpu|cpu","bits":10,...}
JNIEXPORT jstring JNICALL
Java_app_proview_proview_NativePlayer_info(JNIEnv *env, jclass cls, jlong h) {
    Player *p = P(h);
    char buf[256];
    pthread_mutex_lock(&p->lock);
    int gpu_out = p->vk && !p->cpu_output;
    snprintf(buf, sizeof(buf),
             "{\"decode\":\"%s\",\"output\":\"%s\",\"bits\":%d,\"stage\":%d,\"threads\":%d,\"rotation\":%d,"
             "\"headroom\":%.0f,\"dropped\":%lld}",
             p->gpu_decode ? "gpu" : "cpu", gpu_out ? "gpu" : "cpu", gpu_out ? vkr_output_bits(p->vk) : 8,
             p->catchup, p->threads, p->rotation, p->headroom_ms, (long long) p->dropped);
    pthread_mutex_unlock(&p->lock);
    return (*env)->NewStringUTF(env, buf);
}

JNIEXPORT void JNICALL
Java_app_proview_proview_NativePlayer_release(JNIEnv *env, jclass cls, jlong h) {
    Player *p = P(h);
    LOGI("stats: shown %lld, dropped %lld, avg display %.1f ms (buffer wait %.1f ms), %s decode, %s output",
         (long long) p->shown, (long long) p->dropped, p->shown ? p->display_time * 1000 / p->shown : 0.0,
         p->shown ? p->lock_time * 1000 / p->shown : 0.0, p->gpu_decode ? "GPU" : "CPU",
         p->vk && !p->cpu_output ? "GPU" : "CPU");
    pthread_mutex_lock(&p->lock);
    p->quit = 1;
    p->playing = 0;
    pthread_cond_broadcast(&p->cond);
    pthread_mutex_unlock(&p->lock);
    if (p->threads_started) {
        pthread_join(p->video_thread, NULL);
        if (p->present_started) pthread_join(p->present_thread, NULL);
        if (p->stream) pthread_join(p->audio_thread, NULL);
    }
    fq_clear(p);
    if (p->stream) AAudioStream_close(p->stream);
    q_clear(&p->aq);
    av_free(p->aq.items);
    swr_free(&p->swr);
    sws_free_context(&p->sws);
    if (p->hint) adpf.close(p->hint);
    avcodec_free_context(&p->vdec);
    avcodec_free_context(&p->adec);
    avformat_close_input(&p->fmt);
    avformat_close_input(&p->afmt);
    av_frame_free(&p->sw_frame);
    vkr_destroy(p->vk);
    if (p->window) ANativeWindow_release(p->window);
    pthread_mutex_destroy(&p->cpu_lock);
    pthread_mutex_destroy(&p->lock);
    pthread_cond_destroy(&p->cond);
    av_free(p);
}
