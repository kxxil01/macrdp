#import <AppKit/AppKit.h>
#include <stdlib.h>
#include <string.h>

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

// Set text to macOS clipboard
int crdp_clipboard_set_text(const char* text) {
    if (!text) return -1;
    @autoreleasepool {
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];
        NSString *str = [NSString stringWithUTF8String:text];
        if (str) {
            [pasteboard setString:str forType:NSPasteboardTypeString];
            return 0;
        }
    }
    return -1;
}
