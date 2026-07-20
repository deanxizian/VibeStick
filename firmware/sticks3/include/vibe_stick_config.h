#pragma once

#define VIBE_STICK_DEVICE_NAME "VibeStick"
#define FIRMWARE_NAME "vibestick"
#define VIBE_STICK_VERSION "0.1.7"
#define FIRMWARE_VERSION VIBE_STICK_VERSION
#define TRANSPORT "HTTP"
#define VIBE_STICK_STATE_PATH "/state"
#define VIBE_STICK_EVENT_PATH "/event"
#define VIBE_STICK_QUOTA_REFRESH_PATH "/quota/refresh"
#define VIBE_STICK_RECORDING_START_PATH "/recording/start"
#define VIBE_STICK_RECORDING_AUDIO_PATH "/recording/audio"
#define VIBE_STICK_RECORDING_STOP_PATH "/recording/stop"
#define VIBE_STICK_STATE_POLL_MS 2000

#if __has_include("vibe_stick_secrets.h")
#include "vibe_stick_secrets.h"
#else
#define VIBE_STICK_WIFI_SSID ""
#define VIBE_STICK_WIFI_PASSWORD ""
#define VIBE_STICK_BRIDGE_HOST "127.0.0.1"
#define VIBE_STICK_BRIDGE_PORT 8765
#endif

#ifndef VIBE_STICK_BRIDGE_TOKEN
#define VIBE_STICK_BRIDGE_TOKEN ""
#endif

#ifndef VIBE_STICK_DEPLOYMENT_NONCE
#define VIBE_STICK_DEPLOYMENT_NONCE ""
#endif

#ifndef VIBE_STICK_SPEAKER_VOLUME
#define VIBE_STICK_SPEAKER_VOLUME 85
#endif

#if VIBE_STICK_SPEAKER_VOLUME < 0 || VIBE_STICK_SPEAKER_VOLUME > 100
#error "VIBE_STICK_SPEAKER_VOLUME must be between 0 and 100"
#endif
