// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// VI Translator's small C layer over chiaki-ng's library (PS Remote Play), for Swift: only plain
// types cross it (no chiaki struct), so the Swift side never depends on chiaki's struct layouts.
// The same calls as the Android app's JNI layer (native/jni/chiaki-jni.c there): a session with
// video only (no audio, no controller), the discovery of the consoles, waking one, registering.

#ifndef VIT_CHIAKI_H
#define VIT_CHIAKI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Once, before anything else. 0 on success (chiaki's error codes otherwise). [log_path]: chiaki's log, or NULL. */
int vit_ps_init(const char *log_path);

const char *vit_ps_error_string(int err);

// ---- the stream

typedef struct VitPsSession VitPsSession;

enum {
	VIT_PS_EVENT_CONNECTED = 1,
	/** the PS5 asks for the account's login passcode; value: 1 when the last one was wrong */
	VIT_PS_EVENT_LOGIN_PIN = 2,
	/** the session ended; value: chiaki's quit reason, text: its words (may be NULL) */
	VIT_PS_EVENT_QUIT = 3,
	/**
	 * the PS5 can't stream what it shows (a screen or game that blocks Remote Play); value: 1 when
	 * it can't, 0 when it can again. The stream stays up meanwhile.
	 */
	VIT_PS_EVENT_CANT_DISPLAY = 4,
};

/** On chiaki's threads. */
typedef void (*VitPsEventCb)(int type, int value, const char *text, void *user);

/**
 * One frame of video as the PS5 sent it (H.264 Annex B: start codes, the parameter sets before
 * each key frame), on chiaki's thread. Return false when it couldn't be decoded (chiaki then asks
 * for a key frame).
 */
typedef bool (*VitPsVideoCb)(const uint8_t *buf, size_t size, int32_t frames_lost, bool frame_recovered, void *user);

/**
 * A Remote Play session with the PS5 at [host], with the keys from registering ([regist_key] and
 * [rp_key], 16 bytes each). [height]: 720 or 1080; [fps]: 30 or 60. The callbacks get [user].
 */
int vit_ps_session_new(VitPsSession **out, const char *host, const uint8_t regist_key[16], const uint8_t rp_key[16],
		int height, int fps, VitPsEventCb on_event, VitPsVideoCb on_video, void *user);
int vit_ps_session_start(VitPsSession *s);
/** Stop and wait for its threads to end. */
void vit_ps_session_stop(VitPsSession *s);
void vit_ps_session_free(VitPsSession *s);
void vit_ps_session_set_login_pin(VitPsSession *s, const char *pin);
void vit_ps_session_request_idr(VitPsSession *s);
/** the stream's picture size (from its profile) */
void vit_ps_session_video_size(VitPsSession *s, int *width, int *height);

/**
 * The game's sound, decoded (16-bit PCM, interleaved [channels], [rate] Hz), on chiaki's thread; for
 * "Keep translating with the screen off" (iOS keeps an app running while it plays sound). Set it
 * before vit_ps_session_start; NULL: the sound is dropped unread, as before.
 */
typedef void (*VitPsAudioCb)(const int16_t *pcm, size_t frames, int channels, int rate, void *user);
void vit_ps_session_set_audio(VitPsSession *s, VitPsAudioCb on_audio);

bool vit_ps_quit_reason_is_error(int reason);

// ---- H.264 on the CPU (FFmpeg's decoder): the picture while the app is in the background, where
//      iOS keeps the hardware decoder from apps. Not thread-safe: one stream's frames, in order.

typedef struct VitSwDecoder VitSwDecoder;

VitSwDecoder *vit_sw_decoder_new(void);
void vit_sw_decoder_free(VitSwDecoder *d);
/** One frame (Annex B, as chiaki gives it). True when it was decoded (a picture is ready). */
bool vit_sw_decode(VitSwDecoder *d, const uint8_t *buf, size_t size);
/** The last picture's size (0 without one). */
void vit_sw_frame_size(VitSwDecoder *d, int *width, int *height);
/**
 * The last picture as RGBA (width x height x 4, top row first) into [out]: BT.709 limited range to
 * full, then, with [stretch_levels], the studio levels stretched once more (16–235 to 0–255), as the
 * GPU path does for the PS5's picture. False without a picture or when [out_size] is too small.
 */
bool vit_sw_frame_rgba(VitSwDecoder *d, uint8_t *out, size_t out_size, bool stretch_levels);
const char *vit_ps_quit_reason_string(int reason);

// ---- finding the consoles

typedef struct VitPsHost
{
	/** 0 unknown, 1 on, 2 rest mode */
	int state;
	bool ps5;
	char addr[64];
	char name[128];
	char id[64];
	char running_app[128];
} VitPsHost;

/** Every update of the consoles found (on chiaki's thread). */
typedef void (*VitPsHostsCb)(const VitPsHost *hosts, size_t count, void *user);

typedef struct VitPsDiscovery VitPsDiscovery;

/**
 * Look for PlayStations while it lives: a search is broadcast every half second and, as iOS keeps
 * broadcasts for apps with Apple's multicast permission, also sent to every address of the phone's
 * /24 network when [own_ipv4] ("192.168.1.23") is given.
 */
int vit_ps_discovery_new(VitPsDiscovery **out, const char *own_ipv4, VitPsHostsCb cb, void *user);
void vit_ps_discovery_free(VitPsDiscovery *d);

/** Wake a PS5 in rest mode: [credential] is its registration key read as hex. */
int vit_ps_wakeup(const char *host, uint64_t credential);

// ---- registering (linking the phone with the PS5, once)

typedef struct VitPsRegistered
{
	char nickname[0x21];
	uint8_t mac[6];
	uint8_t regist_key[16];
	uint8_t rp_key[16];
} VitPsRegistered;

enum {
	VIT_PS_REGIST_OK = 0,
	VIT_PS_REGIST_FAILED = 1,
	VIT_PS_REGIST_CANCELED = 2,
};

/** Once, on chiaki's thread; [host] is set when [result] is VIT_PS_REGIST_OK. */
typedef void (*VitPsRegistCb)(int result, const VitPsRegistered *host, void *user);

typedef struct VitPsRegist VitPsRegist;

/** Register with the PS5 at [host]: the PSN account ID (8 bytes) and the 8-digit PIN the PS5 shows. */
int vit_ps_regist_start(VitPsRegist **out, const char *host, const uint8_t account_id[8], uint32_t pin, VitPsRegistCb cb, void *user);
/** Stop it if it still runs, and free it (not from its own callback). */
void vit_ps_regist_free(VitPsRegist *r);

#ifdef __cplusplus
}
#endif

#endif
