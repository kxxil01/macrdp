#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <freerdp/freerdp.h>
#include <freerdp/input.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct crdp_client crdp_client_t;

typedef void (*crdp_frame_cb)(const uint8_t* data, uint32_t width, uint32_t height, uint32_t stride, void* user);
typedef void (*crdp_disconnected_cb)(void* user);

typedef struct {
    const char* host;
    uint16_t port;
    const char* username;
    const char* password;
    const char* domain;
    uint32_t width;
    uint32_t height;
    bool enable_nla;
    bool allow_gfx;
    // Drive redirection - share a local folder with remote
    // If set, folder appears as \\tsclient\<drive_name> on Windows
    const char* drive_path;  // Local folder path (e.g., "/Users/user/Downloads")
    const char* drive_name;  // Name shown on Windows (e.g., "Mac")
} crdp_config_t;

crdp_client_t* crdp_client_new(crdp_frame_cb frame_cb, void* frame_user, crdp_disconnected_cb disconnect_cb, void* disconnect_user);
int crdp_client_connect(crdp_client_t* client, const crdp_config_t* config);
void crdp_client_disconnect(crdp_client_t* client);
void crdp_client_free(crdp_client_t* client);

// Input helpers
int crdp_send_pointer_event(crdp_client_t* client, uint16_t flags, uint16_t x, uint16_t y);
int crdp_send_keyboard_event(crdp_client_t* client, uint16_t flags, uint16_t scancode);

#ifdef __cplusplus
}
#endif
