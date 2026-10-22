#import <ScreenSaver/ScreenSaver.h>
#include <stdio.h>

// Installer smoke check: load the real bundle and exercise its lifecycle.
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        [NSApplication sharedApplication];
        NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
        NSError *error = nil;
        if (![bundle loadAndReturnError:&error]) {
            fprintf(stderr, "Screen saver could not load: %s\n", error.localizedDescription.UTF8String ?: "unknown error");
            return 1;
        }
        Class viewClass = bundle.principalClass;
        if (![viewClass isSubclassOfClass:ScreenSaverView.class]) {
            fprintf(stderr, "Screen saver principal class is invalid.\n");
            return 1;
        }
        ScreenSaverView *view = [[viewClass alloc] initWithFrame:NSMakeRect(0, 0, 320, 180) isPreview:YES];
        if (!view) return 1;
        [view startAnimation];
        [view animateOneFrame];
        [view stopAnimation];
        puts("Screen saver bundle load and lifecycle: OK");
    }
    return 0;
}
