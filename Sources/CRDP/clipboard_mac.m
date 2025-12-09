#import <AppKit/AppKit.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

// Callback for clipboard changes
static void (*g_clipboard_change_callback)(void* ctx) = NULL;
static void* g_clipboard_change_ctx = NULL;
static NSInteger g_last_change_count = 0;
static pthread_t g_monitor_thread;
static volatile int g_monitor_running = 0;

// Get text from macOS clipboard
char* crdp_clipboard_get_text(void) {
    @autoreleasepool {
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        NSString *text = [pasteboard stringForType:NSPasteboardTypeString];
        if (text) {
            const char *utf8 = [text UTF8String];
            return strdup(utf8);
        }
    }
    return NULL;
}

// Set text to macOS clipboard (without triggering our own callback)
int crdp_clipboard_set_text(const char* text) {
    if (!text) return -1;
    @autoreleasepool {
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];
        NSString *str = [NSString stringWithUTF8String:text];
        if (str) {
            [pasteboard setString:str forType:NSPasteboardTypeString];
            // Update change count so we don't trigger callback for our own change
            g_last_change_count = [pasteboard changeCount];
            return 0;
        }
    }
    return -1;
}

// Get current pasteboard change count
NSInteger crdp_clipboard_get_change_count(void) {
    @autoreleasepool {
        return [[NSPasteboard generalPasteboard] changeCount];
    }
}

// Monitor thread function
static void* clipboard_monitor_thread(void* arg) {
    while (g_monitor_running) {
        @autoreleasepool {
            NSInteger current = [[NSPasteboard generalPasteboard] changeCount];
            if (current != g_last_change_count) {
                g_last_change_count = current;
                if (g_clipboard_change_callback) {
                    g_clipboard_change_callback(g_clipboard_change_ctx);
                }
            }
        }
        // Poll every 500ms
        usleep(500000);
    }
    return NULL;
}

// Start monitoring clipboard for changes
void crdp_clipboard_start_monitor(void (*callback)(void* ctx), void* ctx) {
    if (g_monitor_running) return;
    
    g_clipboard_change_callback = callback;
    g_clipboard_change_ctx = ctx;
    g_last_change_count = crdp_clipboard_get_change_count();
    g_monitor_running = 1;
    
    pthread_create(&g_monitor_thread, NULL, clipboard_monitor_thread, NULL);
}

// Stop monitoring clipboard
void crdp_clipboard_stop_monitor(void) {
    if (!g_monitor_running) return;
    
    g_monitor_running = 0;
    pthread_join(g_monitor_thread, NULL);
    g_clipboard_change_callback = NULL;
    g_clipboard_change_ctx = NULL;
}
