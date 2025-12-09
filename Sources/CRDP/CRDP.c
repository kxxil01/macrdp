#include "CRDP.h"

#include <freerdp/addin.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/rdpdr.h>
#include <freerdp/crypto/crypto.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/locale/keyboard.h>
#include <freerdp/channels/channels.h>
#include <winpr/clipboard.h>
#include <winpr/thread.h>
#include <winpr/wlog.h>

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

// External functions from clipboard_mac.m
extern char* crdp_clipboard_get_text(void);
extern int crdp_clipboard_set_text(const char* text);
extern void crdp_clipboard_start_monitor(void (*callback)(void* ctx), void* ctx);
extern void crdp_clipboard_stop_monitor(void);

static const char* CRDP_TAG = "CRDP";

typedef struct {
    rdpContext _p;
    struct crdp_client* client;
    pBeginPaint prev_begin_paint;
    pEndPaint prev_end_paint;
    CliprdrClientContext* cliprdr;
    wClipboard* clipboard;
    UINT32 clipboardCapabilities;
    BOOL clipboardSync;
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

// Clipboard callbacks
static UINT crdp_cliprdr_send_client_format_list(CliprdrClientContext* cliprdr) {
    crdp_context* ctx = (crdp_context*)cliprdr->custom;
    if (!ctx) return ERROR_INTERNAL_ERROR;
    
    // Always advertise text formats
    CLIPRDR_FORMAT formats[2] = { 0 };
    formats[0].formatId = 13; // CF_UNICODETEXT
    formats[0].formatName = NULL;
    formats[1].formatId = 1;  // CF_TEXT
    formats[1].formatName = NULL;
    
    CLIPRDR_FORMAT_LIST formatList = { 0 };
    formatList.common.msgFlags = 0;
    formatList.numFormats = 2;
    formatList.formats = formats;
    
    return cliprdr->ClientFormatList(cliprdr, &formatList);
}

static UINT crdp_cliprdr_send_client_format_list_response(CliprdrClientContext* cliprdr, BOOL status) {
    CLIPRDR_FORMAT_LIST_RESPONSE response = { 0 };
    response.common.msgFlags = status ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
    return cliprdr->ClientFormatListResponse(cliprdr, &response);
}

static UINT crdp_cliprdr_send_client_capabilities(CliprdrClientContext* cliprdr) {
    CLIPRDR_CAPABILITIES capabilities = { 0 };
    CLIPRDR_GENERAL_CAPABILITY_SET generalCaps = { 0 };
    
    capabilities.cCapabilitiesSets = 1;
    capabilities.capabilitySets = (CLIPRDR_CAPABILITY_SET*)&generalCaps;
    
    generalCaps.capabilitySetType = CB_CAPSTYPE_GENERAL;
    generalCaps.capabilitySetLength = 12;
    generalCaps.version = CB_CAPS_VERSION_2;
    generalCaps.generalFlags = CB_USE_LONG_FORMAT_NAMES;
    
    return cliprdr->ClientCapabilities(cliprdr, &capabilities);
}

static UINT crdp_cliprdr_monitor_ready(CliprdrClientContext* cliprdr, const CLIPRDR_MONITOR_READY* ready) {
    crdp_context* ctx = (crdp_context*)cliprdr->custom;
    WLog_INFO(CRDP_TAG, "Clipboard monitor ready");
    ctx->clipboardSync = TRUE;
    crdp_cliprdr_send_client_capabilities(cliprdr);
    return crdp_cliprdr_send_client_format_list(cliprdr);
}

static UINT crdp_cliprdr_server_capabilities(CliprdrClientContext* cliprdr, const CLIPRDR_CAPABILITIES* caps) {
    crdp_context* ctx = (crdp_context*)cliprdr->custom;
    for (UINT32 i = 0; i < caps->cCapabilitiesSets; i++) {
        const CLIPRDR_CAPABILITY_SET* capSet = &caps->capabilitySets[i];
        if (capSet->capabilitySetType == CB_CAPSTYPE_GENERAL) {
            const CLIPRDR_GENERAL_CAPABILITY_SET* genCaps = (const CLIPRDR_GENERAL_CAPABILITY_SET*)capSet;
            ctx->clipboardCapabilities = genCaps->generalFlags;
        }
    }
    return CHANNEL_RC_OK;
}

static UINT crdp_cliprdr_server_format_list(CliprdrClientContext* cliprdr, const CLIPRDR_FORMAT_LIST* list) {
    crdp_context* ctx = (crdp_context*)cliprdr->custom;
    if (!ctx) return ERROR_INTERNAL_ERROR;
    
    WLog_DBG(CRDP_TAG, "Server sent format list with %u formats", list->numFormats);
    
    // Find a text format we can handle - prefer CF_UNICODETEXT over CF_TEXT
    UINT32 textFormatId = 0;
    for (UINT32 i = 0; i < list->numFormats; i++) {
        const CLIPRDR_FORMAT* format = &list->formats[i];
        // CF_UNICODETEXT = 13, CF_TEXT = 1 - prefer Unicode
        if (format->formatId == 13) {
            textFormatId = 13;
        } else if (format->formatId == 1 && textFormatId == 0) {
            textFormatId = 1;
        }
    }
    
    crdp_cliprdr_send_client_format_list_response(cliprdr, TRUE);
    
    // Request the text data from server
    if (textFormatId != 0) {
        WLog_DBG(CRDP_TAG, "Requesting clipboard data, format=%u", textFormatId);
        CLIPRDR_FORMAT_DATA_REQUEST request = { 0 };
        request.requestedFormatId = textFormatId;
        cliprdr->ClientFormatDataRequest(cliprdr, &request);
    }
    
    return CHANNEL_RC_OK;
}

static UINT crdp_cliprdr_server_format_list_response(CliprdrClientContext* cliprdr, const CLIPRDR_FORMAT_LIST_RESPONSE* resp) {
    return CHANNEL_RC_OK;
}

static UINT crdp_cliprdr_server_lock_clipboard_data(CliprdrClientContext* cliprdr, const CLIPRDR_LOCK_CLIPBOARD_DATA* lock) {
    return CHANNEL_RC_OK;
}

static UINT crdp_cliprdr_server_unlock_clipboard_data(CliprdrClientContext* cliprdr, const CLIPRDR_UNLOCK_CLIPBOARD_DATA* unlock) {
    return CHANNEL_RC_OK;
}

static UINT crdp_cliprdr_server_format_data_request(CliprdrClientContext* cliprdr, const CLIPRDR_FORMAT_DATA_REQUEST* req) {
    crdp_context* ctx = (crdp_context*)cliprdr->custom;
    if (!ctx) return ERROR_INTERNAL_ERROR;
    
    fprintf(stderr, "[CRDP] Server requesting clipboard data, format=%u\n", req->requestedFormatId);
    
    CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
    
    // CF_UNICODETEXT = 13, CF_TEXT = 1
    if (req->requestedFormatId == 13 || req->requestedFormatId == 1) {
        char* text = crdp_clipboard_get_text();
        fprintf(stderr, "[CRDP] Local clipboard text: %s\n", text ? text : "(null)");
        if (text) {
            size_t len = strlen(text);
            // Convert to UTF-16LE for CF_UNICODETEXT
            if (req->requestedFormatId == 13) {
                // Simple ASCII to UTF-16LE conversion (works for basic text)
                size_t utf16_len = (len + 1) * 2;
                uint8_t* utf16 = calloc(1, utf16_len);
                if (utf16) {
                    for (size_t i = 0; i <= len; i++) {
                        utf16[i * 2] = (uint8_t)text[i];
                        utf16[i * 2 + 1] = 0;
                    }
                    response.common.msgFlags = CB_RESPONSE_OK;
                    response.common.dataLen = (UINT32)utf16_len;
                    response.requestedFormatData = utf16;
                    UINT rc = cliprdr->ClientFormatDataResponse(cliprdr, &response);
                    free(utf16);
                    free(text);
                    return rc;
                }
            } else {
                // CF_TEXT - send as-is with null terminator
                response.common.msgFlags = CB_RESPONSE_OK;
                response.common.dataLen = (UINT32)(len + 1);
                response.requestedFormatData = (uint8_t*)text;
                UINT rc = cliprdr->ClientFormatDataResponse(cliprdr, &response);
                free(text);
                return rc;
            }
            free(text);
        }
    }
    
    // No data available
    response.common.msgFlags = CB_RESPONSE_FAIL;
    response.common.dataLen = 0;
    response.requestedFormatData = NULL;
    return cliprdr->ClientFormatDataResponse(cliprdr, &response);
}

static UINT crdp_cliprdr_server_format_data_response(CliprdrClientContext* cliprdr, const CLIPRDR_FORMAT_DATA_RESPONSE* resp) {
    crdp_context* ctx = (crdp_context*)cliprdr->custom;
    if (!ctx) return ERROR_INTERNAL_ERROR;
    
    if (resp->common.msgFlags & CB_RESPONSE_OK && resp->requestedFormatData && resp->common.dataLen > 0) {
        WLog_DBG(CRDP_TAG, "Received clipboard data: %u bytes", resp->common.dataLen);
        
        const uint8_t* data = resp->requestedFormatData;
        size_t len = resp->common.dataLen;
        
        // UTF-16LE to UTF-8 conversion
        // Allocate enough space for worst case (4 bytes per character)
        char* utf8 = calloc(1, len * 2 + 1);
        if (utf8) {
            size_t j = 0;
            for (size_t i = 0; i + 1 < len; i += 2) {
                uint16_t ch = data[i] | (data[i + 1] << 8);
                if (ch == 0) break;
                
                // Convert UTF-16 code point to UTF-8
                if (ch < 0x80) {
                    utf8[j++] = (char)ch;
                } else if (ch < 0x800) {
                    utf8[j++] = (char)(0xC0 | (ch >> 6));
                    utf8[j++] = (char)(0x80 | (ch & 0x3F));
                } else {
                    utf8[j++] = (char)(0xE0 | (ch >> 12));
                    utf8[j++] = (char)(0x80 | ((ch >> 6) & 0x3F));
                    utf8[j++] = (char)(0x80 | (ch & 0x3F));
                }
            }
            utf8[j] = '\0';
            
            if (j > 0) {
                crdp_clipboard_set_text(utf8);
                WLog_INFO(CRDP_TAG, "Clipboard synced from server: %zu chars", j);
            }
            free(utf8);
        }
    }
    return CHANNEL_RC_OK;
}

// Callback when local macOS clipboard changes
static void crdp_local_clipboard_changed(void* context) {
    crdp_context* ctx = (crdp_context*)context;
    if (!ctx || !ctx->cliprdr || !ctx->clipboardSync) return;
    
    fprintf(stderr, "[CRDP] Local clipboard changed, notifying server\n");
    crdp_cliprdr_send_client_format_list(ctx->cliprdr);
}

static void crdp_cliprdr_init(crdp_context* ctx, CliprdrClientContext* cliprdr) {
    ctx->cliprdr = cliprdr;
    cliprdr->custom = ctx;
    
    ctx->clipboard = ClipboardCreate();
    ctx->clipboardSync = FALSE;
    ctx->clipboardCapabilities = 0;
    
    cliprdr->MonitorReady = crdp_cliprdr_monitor_ready;
    cliprdr->ServerCapabilities = crdp_cliprdr_server_capabilities;
    cliprdr->ServerFormatList = crdp_cliprdr_server_format_list;
    cliprdr->ServerFormatListResponse = crdp_cliprdr_server_format_list_response;
    cliprdr->ServerLockClipboardData = crdp_cliprdr_server_lock_clipboard_data;
    cliprdr->ServerUnlockClipboardData = crdp_cliprdr_server_unlock_clipboard_data;
    cliprdr->ServerFormatDataRequest = crdp_cliprdr_server_format_data_request;
    cliprdr->ServerFormatDataResponse = crdp_cliprdr_server_format_data_response;
    
    // Start monitoring local clipboard for changes
    crdp_clipboard_start_monitor(crdp_local_clipboard_changed, ctx);
    
    WLog_INFO(CRDP_TAG, "Clipboard channel initialized");
}

static void crdp_cliprdr_uninit(crdp_context* ctx) {
    // Stop monitoring local clipboard
    crdp_clipboard_stop_monitor();
    
    if (ctx->clipboard) {
        ClipboardDestroy(ctx->clipboard);
        ctx->clipboard = NULL;
    }
    ctx->cliprdr = NULL;
}

static void crdp_OnChannelConnectedEventHandler(void* context, const ChannelConnectedEventArgs* e) {
    crdp_context* ctx = (crdp_context*)context;
    if (!ctx) return;
    
    WLog_DBG(CRDP_TAG, "Channel connected: %s", e->name);
    
    if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        crdp_cliprdr_init(ctx, (CliprdrClientContext*)e->pInterface);
    }
}

static void crdp_OnChannelDisconnectedEventHandler(void* context, const ChannelDisconnectedEventArgs* e) {
    crdp_context* ctx = (crdp_context*)context;
    if (!ctx) return;
    
    if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        crdp_cliprdr_uninit(ctx);
    }
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
    
    // Enable clipboard redirection (copy/paste between local and remote)
    freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, TRUE);
    
    // Explicitly add cliprdr static channel
    const char* cliprdr_params[] = { "cliprdr" };
    freerdp_client_add_static_channel(settings, 1, cliprdr_params);

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
                // The rdpdr channel will load the drive device service internally
                const char* rdpdr_params[] = { "rdpdr" };
                freerdp_client_add_static_channel(settings, 1, rdpdr_params);
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

    // Subscribe to channel events for clipboard support
    if (instance->context->pubSub) {
        PubSub_SubscribeChannelConnected(instance->context->pubSub, crdp_OnChannelConnectedEventHandler);
        PubSub_SubscribeChannelDisconnected(instance->context->pubSub, crdp_OnChannelDisconnectedEventHandler);
        WLog_DBG(CRDP_TAG, "Subscribed to channel events");
    } else {
        WLog_WARN(CRDP_TAG, "pubSub is NULL, cannot subscribe to channel events");
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
    instance->LoadChannels = freerdp_client_load_channels;
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
