#include "CRDP.h"

#include <freerdp/addin.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/rdpdr.h>
#include <freerdp/crypto/crypto.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/locale/keyboard.h>
#include <winpr/thread.h>
#include <winpr/wlog.h>

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static const char* CRDP_TAG = "CRDP";

typedef struct {
    rdpContext _p;
    struct crdp_client* client;
    pBeginPaint prev_begin_paint;
    pEndPaint prev_end_paint;
} crdp_context;

struct crdp_client {
    freerdp* instance;
    crdp_config_t config;
    crdp_frame_cb frame_cb;
    void* frame_user;
    crdp_disconnected_cb disconnect_cb;
    void* disconnect_user;
    pthread_t thread;
    bool stop;
    bool connected;
};

static void crdp_free_config(crdp_config_t* cfg) {
    if (!cfg) return;
    free((void*)cfg->host);
    free((void*)cfg->username);
    free((void*)cfg->password);
    free((void*)cfg->domain);
    free((void*)cfg->drive_path);
    free((void*)cfg->drive_name);
    memset(cfg, 0, sizeof(crdp_config_t));
}

// Helper to validate drive path exists and is a directory
static bool crdp_validate_drive_path(const char* path) {
    if (!path || path[0] == '\0') return false;
    struct stat st;
    if (stat(path, &st) != 0) return false;
    return S_ISDIR(st.st_mode);
}

static BOOL crdp_begin_paint(rdpContext* context) {
    crdp_context* ctx = (crdp_context*)context;
    BOOL ok = TRUE;
    if (ctx->prev_begin_paint) {
        ok = ctx->prev_begin_paint(context);
    }
    return ok;
}

static BOOL crdp_end_paint(rdpContext* context) {
    crdp_context* ctx = (crdp_context*)context;
    rdpGdi* gdi = context->gdi;
    BOOL ok = TRUE;
    if (ctx->prev_end_paint) {
        ok = ctx->prev_end_paint(context);
    }

    if (gdi && ctx->client && ctx->client->frame_cb) {
        ctx->client->frame_cb(gdi->primary_buffer,
                              (UINT32)gdi->width,
                              (UINT32)gdi->height,
                              gdi->stride,
                              ctx->client->frame_user);
    }

    return ok;
}

static BOOL crdp_desktop_resize(rdpContext* context) {
    rdpSettings* settings = context->settings;
    if (!context->gdi || !settings) return FALSE;
    return gdi_resize(context->gdi, settings->DesktopWidth, settings->DesktopHeight);
}

static BOOL crdp_authenticate(freerdp* instance, char** username, char** password, char** domain) {
    crdp_context* ctx = (crdp_context*)instance->context;
    if (!ctx || !ctx->client) return FALSE;
    const crdp_config_t* cfg = &ctx->client->config;

    if (username && cfg->username) *username = strdup(cfg->username);
    if (password && cfg->password) *password = strdup(cfg->password);
    if (domain && cfg->domain) *domain = strdup(cfg->domain);
    return TRUE;
}

static DWORD crdp_verify_certificate_ex(freerdp* instance,
                                        const char* host,
                                        UINT16 port,
                                        const char* common_name,
                                        const char* subject,
                                        const char* issuer,
                                        const char* fingerprint,
                                        DWORD flags) {
    WLog_INFO(CRDP_TAG, "Accepting certificate for %s:%u", host, port);
    return 2; // accept for this session
}

static DWORD crdp_verify_changed_certificate_ex(freerdp* instance,
                                                const char* host,
                                                UINT16 port,
                                                const char* common_name,
                                                const char* subject,
                                                const char* issuer,
                                                const char* new_fingerprint,
                                                const char* old_subject,
                                                const char* old_issuer,
                                                const char* old_fingerprint,
                                                DWORD flags) {
    WLog_INFO(CRDP_TAG, "Accepting changed certificate for %s:%u", host, port);
    return 2; // accept for this session
}

static BOOL crdp_pre_connect(freerdp* instance) {
    crdp_context* ctx = (crdp_context*)instance->context;
    if (!ctx || !ctx->client) return FALSE;
    const crdp_config_t* cfg = &ctx->client->config;
    rdpSettings* settings = ctx->_p.settings;

    freerdp_settings_set_string(settings, FreeRDP_ServerHostname, cfg->host);
    freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, cfg->port ? cfg->port : 3389);
    freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, cfg->width ? cfg->width : 1280);
    freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, cfg->height ? cfg->height : 720);
    freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32);
    freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, cfg->allow_gfx);
    freerdp_settings_set_bool(settings, FreeRDP_SoftwareGdi, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_AutoLogonEnabled, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, cfg->enable_nla);
    freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_NegotiateSecurityLayer, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_IgnoreCertificate, TRUE); // Accept all for now
    freerdp_settings_set_bool(settings, FreeRDP_UseMultimon, FALSE);

    // Connection timeout (in milliseconds, 0 = system default)
    if (cfg->timeout_seconds > 0) {
        uint32_t timeout_ms = cfg->timeout_seconds * 1000;
        freerdp_settings_set_uint32(settings, FreeRDP_TcpConnectTimeout, timeout_ms);
        WLog_INFO(CRDP_TAG, "Connection timeout set to %u seconds", cfg->timeout_seconds);
    }

    if (cfg->username) freerdp_settings_set_string(settings, FreeRDP_Username, cfg->username);
    if (cfg->password) freerdp_settings_set_string(settings, FreeRDP_Password, cfg->password);
    if (cfg->domain) freerdp_settings_set_string(settings, FreeRDP_Domain, cfg->domain);

    // Drive redirection - share local folder with remote Windows
    // Appears as \\tsclient\<drive_name> on Windows
    if (crdp_validate_drive_path(cfg->drive_path)) {
        const char* drive_name = cfg->drive_name && cfg->drive_name[0] ? cfg->drive_name : "Mac";
        
        // Enable device redirection (required for RDPDR channel)
        freerdp_settings_set_bool(settings, FreeRDP_DeviceRedirection, TRUE);
        
        // Create drive device: args = { name, path } - name first, then path
        // This matches FreeRDP's freerdp_client_add_drive() implementation
        const char* drive_args[] = { drive_name, cfg->drive_path };
        RDPDR_DEVICE* device = freerdp_device_new(RDPDR_DTYP_FILESYSTEM, 2, drive_args);
        
        if (device) {
            if (freerdp_device_collection_add(settings, device)) {
                WLog_INFO(CRDP_TAG, "Drive redirection enabled: %s -> \\\\tsclient\\%s", 
                          cfg->drive_path, drive_name);
                
                // Explicitly add rdpdr static channel to ensure it gets loaded
                const char* rdpdr_params[] = { "rdpdr" };
                freerdp_client_add_static_channel(settings, 1, rdpdr_params);
                
                // Also add the drive channel
                const char* drive_channel_params[] = { "drive" };
                freerdp_client_add_static_channel(settings, 1, drive_channel_params);
            } else {
                WLog_WARN(CRDP_TAG, "Failed to add drive to device collection");
                freerdp_device_free(device);
            }
        } else {
            WLog_WARN(CRDP_TAG, "Failed to create drive device");
        }
    } else if (cfg->drive_path && cfg->drive_path[0]) {
        // Path was specified but invalid
        WLog_WARN(CRDP_TAG, "Drive path invalid or not a directory: %s", cfg->drive_path);
    }

    if (freerdp_client_load_addins(ctx->_p.channels, settings) != CHANNEL_RC_OK) {
        WLog_WARN(CRDP_TAG, "Unable to load client channels");
    }

    return TRUE;
}

static BOOL crdp_post_connect(freerdp* instance) {
    crdp_context* ctx = (crdp_context*)instance->context;
    if (!ctx) return FALSE;

    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) return FALSE;

    rdpUpdate* update = ctx->_p.update;
    ctx->prev_begin_paint = update->BeginPaint;
    ctx->prev_end_paint = update->EndPaint;
    update->BeginPaint = crdp_begin_paint;
    update->EndPaint = crdp_end_paint;
    update->DesktopResize = crdp_desktop_resize;

    return TRUE;
}

static BOOL crdp_context_new(freerdp* instance, rdpContext* context) {
    crdp_context* ctx = (crdp_context*)context;
    ctx->client = NULL;
    ctx->prev_begin_paint = NULL;
    ctx->prev_end_paint = NULL;
    return TRUE;
}

static void crdp_context_free(freerdp* instance, rdpContext* context) {
    if (context->gdi) {
        gdi_free(instance);
    }
}

static void* crdp_thread_start(void* arg) {
    crdp_client_t* client = (crdp_client_t*)arg;

    if (!freerdp_connect(client->instance)) {
        WLog_ERR(CRDP_TAG, "connect failed");
        goto finish;
    }

    client->connected = true;

    rdpContext* context = client->instance->context;

    while (!client->stop) {
        if (freerdp_shall_disconnect_context(context)) break;
        if (!freerdp_check_event_handles(context)) {
            WLog_ERR(CRDP_TAG, "event handling failed");
            break;
        }
    }

    freerdp_disconnect(client->instance);
    client->connected = false;

finish:
    if (client->disconnect_cb) client->disconnect_cb(client->disconnect_user);
    return NULL;
}

crdp_client_t* crdp_client_new(crdp_frame_cb frame_cb, void* frame_user, crdp_disconnected_cb disconnect_cb, void* disconnect_user) {
    crdp_client_t* client = calloc(1, sizeof(crdp_client_t));
    if (!client) return NULL;

    client->frame_cb = frame_cb;
    client->frame_user = frame_user;
    client->disconnect_cb = disconnect_cb;
    client->disconnect_user = disconnect_user;
    client->stop = false;
    client->connected = false;

    return client;
}

int crdp_client_connect(crdp_client_t* client, const crdp_config_t* config) {
    if (!client || !config) return -1;
    if (client->connected) return 0;

    crdp_free_config(&client->config);
    client->config = *config;
    client->config.host = config->host ? strdup(config->host) : NULL;
    client->config.username = config->username ? strdup(config->username) : NULL;
    client->config.password = config->password ? strdup(config->password) : NULL;
    client->config.domain = config->domain ? strdup(config->domain) : NULL;
    client->config.drive_path = config->drive_path ? strdup(config->drive_path) : NULL;
    client->config.drive_name = config->drive_name ? strdup(config->drive_name) : NULL;

    freerdp* instance = freerdp_new();
    if (!instance) return -2;

    instance->ContextSize = sizeof(crdp_context);
    instance->ContextNew = crdp_context_new;
    instance->ContextFree = crdp_context_free;

    // Register static channel addin provider - this enables built-in channels
    // like rdpdr (drive redirection) and cliprdr (clipboard) to be loaded
    // without requiring separate .dylib plugin files
    freerdp_register_addin_provider(freerdp_channels_load_static_addin_entry, 0);

    if (!freerdp_context_new(instance)) {
        freerdp_free(instance);
        return -3;
    }

    crdp_context* ctx = (crdp_context*)instance->context;
    ctx->client = client;

    instance->PreConnect = crdp_pre_connect;
    instance->PostConnect = crdp_post_connect;
    instance->Authenticate = crdp_authenticate;
    instance->VerifyCertificateEx = crdp_verify_certificate_ex;
    instance->VerifyChangedCertificateEx = crdp_verify_changed_certificate_ex;

    client->instance = instance;
    client->stop = false;

    if (pthread_create(&client->thread, NULL, crdp_thread_start, client) != 0) {
        freerdp_context_free(client->instance);
        freerdp_free(client->instance);
        client->instance = NULL;
        return -4;
    }

    return 0;
}

void crdp_client_disconnect(crdp_client_t* client) {
    if (!client) return;
    client->stop = true;

    if (client->instance) {
        freerdp_abort_connect_context(client->instance->context);
    }

    if (client->thread) {
        pthread_join(client->thread, NULL);
        memset(&client->thread, 0, sizeof(pthread_t));
    }

    if (client->instance) {
        freerdp_context_free(client->instance);
        freerdp_free(client->instance);
        client->instance = NULL;
    }

    client->connected = false;
}

void crdp_client_free(crdp_client_t* client) {
    if (!client) return;
    crdp_client_disconnect(client);
    crdp_free_config(&client->config);
    free(client);
}

int crdp_send_pointer_event(crdp_client_t* client, uint16_t flags, uint16_t x, uint16_t y) {
    if (!client || !client->instance || !client->instance->context || !client->instance->context->input) return -1;
    return freerdp_input_send_mouse_event(client->instance->context->input, flags, x, y);
}

int crdp_send_keyboard_event(crdp_client_t* client, uint16_t flags, uint16_t scancode) {
    if (!client || !client->instance || !client->instance->context || !client->instance->context->input) return -1;
    return freerdp_input_send_keyboard_event(client->instance->context->input, flags, (UINT8)scancode);
}
