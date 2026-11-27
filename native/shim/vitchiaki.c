// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// See vitchiaki.h. Follows chiaki-ng's Android JNI layer (v1.10.1, android/app/src/main/cpp),
// without audio and the controller (the game is played and heard on the TV).

#include "vitchiaki.h"

#include <chiaki/common.h>
#include <chiaki/discovery.h>
#include <chiaki/discoveryservice.h>
#include <chiaki/log.h>
#include <chiaki/regist.h>
#include <chiaki/session.h>

#include <opus/opus.h>
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---- the log: chiaki's lines to stderr (Xcode's console) and to a file, when one is given

static FILE *log_file = NULL;
static pthread_mutex_t log_mutex = PTHREAD_MUTEX_INITIALIZER;
static ChiakiLog global_log;

static void log_cb(ChiakiLogLevel level, const char *msg, void *user)
{
	(void)user;
	char c = '?';
	switch(level)
	{
		case CHIAKI_LOG_DEBUG: c = 'D'; break;
		case CHIAKI_LOG_VERBOSE: c = 'V'; break;
		case CHIAKI_LOG_INFO: c = 'I'; break;
		case CHIAKI_LOG_WARNING: c = 'W'; break;
		case CHIAKI_LOG_ERROR: c = 'E'; break;
	}
	pthread_mutex_lock(&log_mutex);
	fprintf(stderr, "[chiaki %c] %s\n", c, msg);
	if(log_file)
	{
		fprintf(log_file, "[%c] %s\n", c, msg);
		fflush(log_file);
	}
	pthread_mutex_unlock(&log_mutex);
}

static void log_init(ChiakiLog *log)
{
	chiaki_log_init(log, CHIAKI_LOG_ALL & ~CHIAKI_LOG_VERBOSE, log_cb, NULL);
}

int vit_ps_init(const char *log_path)
{
	static bool done = false;
	static int result = 0;
	if(done)
		return result;
	done = true;
	if(log_path)
		log_file = fopen(log_path, "w");
	log_init(&global_log);
	result = (int)chiaki_lib_init();
	CHIAKI_LOGI(&global_log, "chiaki-ng library: %s", chiaki_error_string((ChiakiErrorCode)result));
	return result;
}

const char *vit_ps_error_string(int err)
{
	return chiaki_error_string((ChiakiErrorCode)err);
}

// ---- the stream

struct VitPsSession
{
	ChiakiSession session;
	ChiakiLog log;
	VitPsEventCb on_event;
	VitPsVideoCb on_video;
	void *user;
	int width;
	int height;
	// the game's sound
	VitPsAudioCb on_audio;
	OpusDecoder *opus;
	int channels;
	int rate;
	int16_t *pcm;
	size_t pcm_frames;
};

static void session_audio_header_cb(ChiakiAudioHeader *header, void *user)
{
	VitPsSession *s = user;
	if(s->opus)
	{
		opus_decoder_destroy(s->opus);
		s->opus = NULL;
	}
	int err = 0;
	s->channels = header->channels ? header->channels : 2;
	s->rate = header->rate ? (int)header->rate : 48000;
	s->opus = opus_decoder_create(s->rate, s->channels, &err);
	if(err != OPUS_OK)
	{
		CHIAKI_LOGE(&s->log, "Opus decoder: %s", opus_strerror(err));
		s->opus = NULL;
		return;
	}
	// (the largest Opus frame: 120 ms)
	s->pcm_frames = (size_t)s->rate * 120 / 1000;
	free(s->pcm);
	s->pcm = malloc(s->pcm_frames * s->channels * sizeof(int16_t));
}

static void session_audio_frame_cb(uint8_t *buf, size_t buf_size, void *user)
{
	VitPsSession *s = user;
	if(!s->opus || !s->pcm || !s->on_audio)
		return;
	int n = opus_decode(s->opus, buf, (opus_int32)buf_size, s->pcm, (int)s->pcm_frames, 0);
	if(n > 0)
		s->on_audio(s->pcm, (size_t)n, s->channels, s->rate, s->user);
}

void vit_ps_session_set_audio(VitPsSession *s, VitPsAudioCb on_audio)
{
	if(!s)
		return;
	s->on_audio = on_audio;
	ChiakiAudioSink sink;
	memset(&sink, 0, sizeof(sink));
	if(on_audio)
	{
		sink.user = s;
		sink.header_cb = session_audio_header_cb;
		sink.frame_cb = session_audio_frame_cb;
	}
	chiaki_session_set_audio_sink(&s->session, &sink);
}

static void session_event_cb(ChiakiEvent *event, void *user)
{
	VitPsSession *s = user;
	switch(event->type)
	{
		case CHIAKI_EVENT_CONNECTED:
			s->on_event(VIT_PS_EVENT_CONNECTED, 0, NULL, s->user);
			break;
		case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
			s->on_event(VIT_PS_EVENT_LOGIN_PIN, event->login_pin_request.pin_incorrect ? 1 : 0, NULL, s->user);
			break;
		case CHIAKI_EVENT_QUIT:
			s->on_event(VIT_PS_EVENT_QUIT, (int)event->quit.reason, event->quit.reason_str, s->user);
			break;
		default:
			break;
	}
}

static bool session_video_cb(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
	VitPsSession *s = user;
	return s->on_video(buf, buf_size, frames_lost, frame_recovered, s->user);
}

int vit_ps_session_new(VitPsSession **out, const char *host, const uint8_t regist_key[16], const uint8_t rp_key[16],
		int height, int fps, VitPsEventCb on_event, VitPsVideoCb on_video, void *user)
{
	*out = NULL;
	if(!host || !on_event || !on_video)
		return CHIAKI_ERR_INVALID_DATA;
	VitPsSession *s = calloc(1, sizeof(VitPsSession));
	if(!s)
		return CHIAKI_ERR_MEMORY;
	log_init(&s->log);
	s->on_event = on_event;
	s->on_video = on_video;
	s->user = user;

	ChiakiConnectInfo info;
	memset(&info, 0, sizeof(info));
	info.ps5 = true;
	info.host = host;
	_Static_assert(sizeof(info.regist_key) == 16, "regist key size");
	_Static_assert(sizeof(info.morning) == 16, "morning size");
	memcpy(info.regist_key, regist_key, sizeof(info.regist_key));
	memcpy(info.morning, rp_key, sizeof(info.morning));
	chiaki_connect_video_profile_preset(&info.video_profile,
			height >= 1080 ? CHIAKI_VIDEO_RESOLUTION_PRESET_1080p : CHIAKI_VIDEO_RESOLUTION_PRESET_720p,
			fps >= 60 ? CHIAKI_VIDEO_FPS_PRESET_60 : CHIAKI_VIDEO_FPS_PRESET_30);
	// (H.264: what every iPhone's decoder takes, as the Android app)
	info.video_profile.codec = CHIAKI_CODEC_H264;
	info.video_profile_auto_downgrade = true;
	s->width = (int)info.video_profile.width;
	s->height = (int)info.video_profile.height;

	ChiakiErrorCode err = chiaki_session_init(&s->session, &info, &s->log);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&s->log, "session init failed: %s", chiaki_error_string(err));
		free(s);
		return (int)err;
	}
	chiaki_session_set_event_cb(&s->session, session_event_cb, s);
	chiaki_session_set_video_sample_cb(&s->session, session_video_cb, s);
	*out = s;
	return CHIAKI_ERR_SUCCESS;
}

int vit_ps_session_start(VitPsSession *s)
{
	return (int)chiaki_session_start(&s->session);
}

void vit_ps_session_stop(VitPsSession *s)
{
	if(!s)
		return;
	chiaki_session_stop(&s->session);
	chiaki_session_join(&s->session);
}

void vit_ps_session_free(VitPsSession *s)
{
	if(!s)
		return;
	chiaki_session_fini(&s->session);
	if(s->opus)
		opus_decoder_destroy(s->opus);
	free(s->pcm);
	free(s);
}

void vit_ps_session_set_login_pin(VitPsSession *s, const char *pin)
{
	if(!s || !pin)
		return;
	chiaki_session_set_login_pin(&s->session, (const uint8_t *)pin, strlen(pin));
}

void vit_ps_session_request_idr(VitPsSession *s)
{
	if(s)
		chiaki_session_request_idr(&s->session);
}

void vit_ps_session_video_size(VitPsSession *s, int *width, int *height)
{
	*width = s ? s->width : 0;
	*height = s ? s->height : 0;
}

bool vit_ps_quit_reason_is_error(int reason)
{
	return chiaki_quit_reason_is_error((ChiakiQuitReason)reason);
}

const char *vit_ps_quit_reason_string(int reason)
{
	return chiaki_quit_reason_string((ChiakiQuitReason)reason);
}

// ---- finding the consoles

struct VitPsDiscovery
{
	ChiakiDiscoveryService service;
	VitPsHostsCb cb;
	void *user;
};

static void copy_str(char *dst, size_t size, const char *src)
{
	if(!src)
	{
		dst[0] = '\0';
		return;
	}
	strncpy(dst, src, size - 1);
	dst[size - 1] = '\0';
}

static void discovery_cb(ChiakiDiscoveryHost *hosts, size_t count, void *user)
{
	VitPsDiscovery *d = user;
	VitPsHost *out = count ? calloc(count, sizeof(VitPsHost)) : NULL;
	if(count && !out)
		return;
	for(size_t i = 0; i < count; i++)
	{
		ChiakiDiscoveryHost *h = &hosts[i];
		out[i].state = h->state == CHIAKI_DISCOVERY_HOST_STATE_READY ? 1 : h->state == CHIAKI_DISCOVERY_HOST_STATE_STANDBY ? 2 : 0;
		out[i].ps5 = chiaki_discovery_host_is_ps5(h);
		copy_str(out[i].addr, sizeof(out[i].addr), h->host_addr);
		copy_str(out[i].name, sizeof(out[i].name), h->host_name);
		copy_str(out[i].id, sizeof(out[i].id), h->host_id);
		copy_str(out[i].running_app, sizeof(out[i].running_app), h->running_app_name);
	}
	d->cb(out, count, d->user);
	free(out);
}

int vit_ps_discovery_new(VitPsDiscovery **out, const char *own_ipv4, VitPsHostsCb cb, void *user)
{
	*out = NULL;
	VitPsDiscovery *d = calloc(1, sizeof(VitPsDiscovery));
	if(!d)
		return CHIAKI_ERR_MEMORY;
	d->cb = cb;
	d->user = user;

	struct sockaddr_in broadcast;
	memset(&broadcast, 0, sizeof(broadcast));
	broadcast.sin_family = AF_INET;
	broadcast.sin_addr.s_addr = htonl(INADDR_BROADCAST);
	struct sockaddr_storage send_addr;
	memset(&send_addr, 0, sizeof(send_addr));
	memcpy(&send_addr, &broadcast, sizeof(broadcast));

	// the /24 network's addresses, each sent the search too ("extra broadcasts" for chiaki)
	struct sockaddr_storage *each = NULL;
	size_t each_count = 0;
	struct in_addr own;
	if(own_ipv4 && inet_pton(AF_INET, own_ipv4, &own) == 1)
	{
		each = calloc(254, sizeof(struct sockaddr_storage));
		if(each)
		{
			uint32_t base = ntohl(own.s_addr) & 0xffffff00u;
			uint32_t me = ntohl(own.s_addr);
			for(uint32_t i = 1; i <= 254; i++)
			{
				if(base + i == me)
					continue;
				struct sockaddr_in a;
				memset(&a, 0, sizeof(a));
				a.sin_family = AF_INET;
				a.sin_addr.s_addr = htonl(base + i);
				memcpy(&each[each_count++], &a, sizeof(a));
			}
		}
	}

	ChiakiDiscoveryServiceOptions options;
	memset(&options, 0, sizeof(options));
	options.hosts_max = 8;
	options.host_drop_pings = 3;
	options.ping_ms = 500;
	options.ping_initial_ms = 0;
	options.send_addr = &send_addr;
	options.send_addr_size = sizeof(struct sockaddr_in);
	options.broadcast_addrs = each;
	options.broadcast_num = each_count;
	options.cb = discovery_cb;
	options.cb_user = d;

	ChiakiErrorCode err = chiaki_discovery_service_init(&d->service, &options, &global_log);
	free(each);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&global_log, "discovery failed to start: %s", chiaki_error_string(err));
		free(d);
		return (int)err;
	}
	*out = d;
	return CHIAKI_ERR_SUCCESS;
}

void vit_ps_discovery_free(VitPsDiscovery *d)
{
	if(!d)
		return;
	chiaki_discovery_service_fini(&d->service);
	free(d);
}

int vit_ps_wakeup(const char *host, uint64_t credential)
{
	return (int)chiaki_discovery_wakeup(&global_log, NULL, host, credential, true);
}

// ---- registering

struct VitPsRegist
{
	ChiakiRegist regist;
	ChiakiLog log;
	VitPsRegistCb cb;
	void *user;
	char *host;
	/** why it failed, from chiaki's log lines (0: not known) */
	int reason;
};

// chiaki-ng tells only "failed" when registering doesn't work; why is in its log lines (regist.c of
// the pinned v1.10.1, on the registering thread, before its callback): they are read here to tell
// the user what to do. Lines not recognised leave VIT_PS_REGIST_FAILED.
static void regist_log_cb(ChiakiLogLevel level, const char *msg, void *user)
{
	VitPsRegist *r = user;
	if(r && msg && level == CHIAKI_LOG_ERROR)
	{
		if(strstr(msg, "Reported Application Reason:"))
		{
			// CHIAKI_RP_APPLICATION_REASON_REGIST_FAILED ("probably invalid PIN") and _INVALID_PSN_ID
			if(strstr(msg, "0x80108b09"))
				r->reason = VIT_PS_REGIST_WRONG_PIN;
			else if(strstr(msg, "0x80108b02"))
				r->reason = VIT_PS_REGIST_BAD_ACCOUNT;
			else
				r->reason = VIT_PS_REGIST_FAILED;
		}
		else if(strstr(msg, "Regist received HTTP code"))
			r->reason = VIT_PS_REGIST_WRONG_PIN; // (the reason line, if any, follows)
		else if(strstr(msg, "refused the registration search"))
			r->reason = VIT_PS_REGIST_NOT_LINKING;
		else if(!r->reason && (strstr(msg, "getaddrinfo") || strstr(msg, "timed out waiting for search response")
				|| strstr(msg, "failed to connect for search") || strstr(msg, "Regist connect failed")))
			r->reason = VIT_PS_REGIST_NOT_FOUND;
	}
	log_cb(level, msg, NULL);
}

static void regist_cb(ChiakiRegistEvent *event, void *user)
{
	VitPsRegist *r = user;
	switch(event->type)
	{
		case CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS:
		{
			ChiakiRegisteredHost *h = event->registered_host;
			VitPsRegistered out;
			memset(&out, 0, sizeof(out));
			copy_str(out.nickname, sizeof(out.nickname), h->server_nickname);
			memcpy(out.mac, h->server_mac, sizeof(out.mac));
			_Static_assert(sizeof(h->rp_regist_key) == 16, "regist key size");
			_Static_assert(sizeof(h->rp_key) == 16, "rp key size");
			memcpy(out.regist_key, h->rp_regist_key, sizeof(out.regist_key));
			memcpy(out.rp_key, h->rp_key, sizeof(out.rp_key));
			r->cb(VIT_PS_REGIST_OK, &out, r->user);
			break;
		}
		case CHIAKI_REGIST_EVENT_TYPE_FINISHED_FAILED:
			r->cb(r->reason ? r->reason : VIT_PS_REGIST_FAILED, NULL, r->user);
			break;
		case CHIAKI_REGIST_EVENT_TYPE_FINISHED_CANCELED:
			r->cb(VIT_PS_REGIST_CANCELED, NULL, r->user);
			break;
	}
}

int vit_ps_regist_start(VitPsRegist **out, const char *host, const uint8_t account_id[8], uint32_t pin, VitPsRegistCb cb, void *user)
{
	*out = NULL;
	VitPsRegist *r = calloc(1, sizeof(VitPsRegist));
	if(!r)
		return CHIAKI_ERR_MEMORY;
	chiaki_log_init(&r->log, CHIAKI_LOG_ALL & ~CHIAKI_LOG_VERBOSE, regist_log_cb, r);
	r->cb = cb;
	r->user = user;
	r->host = strdup(host);
	if(!r->host)
	{
		free(r);
		return CHIAKI_ERR_MEMORY;
	}

	ChiakiRegistInfo info;
	memset(&info, 0, sizeof(info));
	info.target = CHIAKI_TARGET_PS5_1;
	info.host = r->host;
	info.broadcast = false;
	info.psn_online_id = NULL;
	_Static_assert(sizeof(info.psn_account_id) == 8, "account id size");
	memcpy(info.psn_account_id, account_id, sizeof(info.psn_account_id));
	info.pin = pin;

	ChiakiErrorCode err = chiaki_regist_start(&r->regist, &r->log, &info, regist_cb, r);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&r->log, "registering failed to start: %s", chiaki_error_string(err));
		free(r->host);
		free(r);
		return (int)err;
	}
	*out = r;
	return CHIAKI_ERR_SUCCESS;
}

void vit_ps_regist_free(VitPsRegist *r)
{
	if(!r)
		return;
	chiaki_regist_stop(&r->regist);
	chiaki_regist_fini(&r->regist);
	free(r->host);
	free(r);
}

// ---- H.264 on the CPU (FFmpeg)

struct VitSwDecoder
{
	AVCodecContext *ctx;
	AVPacket *packet;
	AVFrame *frame;
	bool has_frame;
};

VitSwDecoder *vit_sw_decoder_new(void)
{
	const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_H264);
	if(!codec)
		return NULL;
	VitSwDecoder *d = calloc(1, sizeof(VitSwDecoder));
	if(!d)
		return NULL;
	d->ctx = avcodec_alloc_context3(codec);
	d->packet = av_packet_alloc();
	d->frame = av_frame_alloc();
	if(!d->ctx || !d->packet || !d->frame)
	{
		vit_sw_decoder_free(d);
		return NULL;
	}
	// (low delay: a frame out for each frame in, as chiaki gives whole frames)
	d->ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
	d->ctx->thread_count = 2;
	if(avcodec_open2(d->ctx, codec, NULL) < 0)
	{
		vit_sw_decoder_free(d);
		return NULL;
	}
	return d;
}

void vit_sw_decoder_free(VitSwDecoder *d)
{
	if(!d)
		return;
	if(d->ctx)
		avcodec_free_context(&d->ctx);
	if(d->packet)
		av_packet_free(&d->packet);
	if(d->frame)
		av_frame_free(&d->frame);
	free(d);
}

bool vit_sw_decode(VitSwDecoder *d, const uint8_t *buf, size_t size)
{
	if(!d || !buf || !size)
		return false;
	d->packet->data = (uint8_t *)buf;
	d->packet->size = (int)size;
	if(avcodec_send_packet(d->ctx, d->packet) < 0)
		return false;
	bool got = false;
	while(avcodec_receive_frame(d->ctx, d->frame) == 0)
		got = true;
	if(got)
		d->has_frame = true;
	return got;
}

void vit_sw_frame_size(VitSwDecoder *d, int *width, int *height)
{
	*width = d && d->has_frame ? d->frame->width : 0;
	*height = d && d->has_frame ? d->frame->height : 0;
}

static inline uint8_t clamp8(int v)
{
	return v < 0 ? 0 : v > 255 ? 255 : (uint8_t)v;
}

bool vit_sw_frame_rgba(VitSwDecoder *d, uint8_t *out, size_t out_size, bool stretch_levels)
{
	if(!d || !d->has_frame)
		return false;
	AVFrame *f = d->frame;
	if(f->format != AV_PIX_FMT_YUV420P && f->format != AV_PIX_FMT_YUVJ420P)
		return false;
	int w = f->width, h = f->height;
	if(out_size < (size_t)w * h * 4)
		return false;
	// BT.709, limited range to full, in fixed point (x1024); with the studio levels stretched once
	// more, every factor is 255/219 bigger and 16 x 255/219 is taken off (as the Android app's YuvSnapshot)
	int ky, off, kr, kgu, kgv, kb;
	if(stretch_levels)
	{
		ky = 1388; off = -19076; kr = 2138; kgu = 254; kgv = 636; kb = 2519;
	}
	else
	{
		ky = 1192; off = 0; kr = 1836; kgu = 218; kgv = 546; kb = 2163;
	}
	for(int row = 0; row < h; row++)
	{
		const uint8_t *yl = f->data[0] + (size_t)row * f->linesize[0];
		const uint8_t *ul = f->data[1] + (size_t)(row >> 1) * f->linesize[1];
		const uint8_t *vl = f->data[2] + (size_t)(row >> 1) * f->linesize[2];
		uint8_t *o = out + (size_t)row * w * 4;
		for(int col = 0; col < w; col++)
		{
			int yy = yl[col] - 16;
			if(yy < 0)
				yy = 0;
			int uu = ul[col >> 1] - 128;
			int vv = vl[col >> 1] - 128;
			int c = ky * yy + off;
			o[0] = clamp8((c + kr * vv) >> 10);
			o[1] = clamp8((c - kgu * uu - kgv * vv) >> 10);
			o[2] = clamp8((c + kb * uu) >> 10);
			o[3] = 255;
			o += 4;
		}
	}
	return true;
}
