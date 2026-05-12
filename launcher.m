// RIT.app launcher (Objective-C / Cocoa). Compiled at .pkg build time.
//
// Why a Mach-O launcher instead of a bash script:
//   1. CFBundleExecutable can point at a real binary, so macOS treats us as
//      a proper .app. Our NSApp.activationPolicy = Accessory hides our Dock
//      entry — only wine64/Client.exe's window appears (with our .app icon).
//   2. The .app is now arm64-signed (this binary) but spawns x86_64 wine64,
//      letting macOS auto-prompt to install Rosetta 2 on first launch the
//      normal way.
//   3. Cleaner shutdown: when the user clicks the Dock's red-X on the main
//      window, we receive the NSApplication terminate event and can kill
//      wineserver explicitly. No orphan wine processes.

#import <Cocoa/Cocoa.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/sysctl.h>
#include <signal.h>

extern char **environ;

static NSString *gWinePrefix = nil;
static pid_t    gWinePid    = 0;

static void killWine(void) {
    if (gWinePid > 0) kill(-gWinePid, SIGTERM);
    // Also nuke wineserver via the engine binary, just in case.
    NSString *res = [[NSBundle mainBundle] resourcePath];
    NSString *wineserver = [res stringByAppendingPathComponent:@"wine/bin/wineserver"];
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = wineserver;
    t.arguments  = @[@"-k"];
    t.environment = @{ @"WINEPREFIX": gWinePrefix };
    @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}
}

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    killWine();
    return NSTerminateNow;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}
@end

static void waitForWineInBackground(void) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int status = 0;
        waitpid(gWinePid, &status, 0);
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp terminate:nil];
        });
    });
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSBundle *bundle  = [NSBundle mainBundle];
        NSString *resPath = [bundle resourcePath];
        NSString *winePrefix = [resPath stringByAppendingPathComponent:@"prefix"];
        NSString *wineBin    = [resPath stringByAppendingPathComponent:@"wine/bin/wine64"];

        gWinePrefix = winePrefix;

        setenv("WINEPREFIX", [winePrefix UTF8String], 1);
        setenv("WINEARCH", "win64", 1);
        setenv("WINEDEBUG", "-all", 1);
        // Make wine pick our bundled wine engine first.
        NSString *winePath = [resPath stringByAppendingPathComponent:@"wine/bin"];
        const char *oldPath = getenv("PATH");
        NSString *newPath  = [NSString stringWithFormat:@"%@:%s", winePath, oldPath ? oldPath : "/usr/bin:/bin"];
        setenv("PATH", [newPath UTF8String], 1);

        // Create dosdevices/c: and z: if missing (we strip them at build).
        NSString *dosdev = [winePrefix stringByAppendingPathComponent:@"dosdevices"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:dosdev]) {
            [fm createDirectoryAtPath:dosdev withIntermediateDirectories:YES attributes:nil error:nil];
            [fm createSymbolicLinkAtPath:[dosdev stringByAppendingPathComponent:@"c:"]
                     withDestinationPath:@"../drive_c" error:nil];
            [fm createSymbolicLinkAtPath:[dosdev stringByAppendingPathComponent:@"z:"]
                     withDestinationPath:@"/" error:nil];
        }

        // Hide our Dock entry — only wine's app window (which inherits this
        // bundle's icon) should appear there.
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [NSApp setDelegate:delegate];

        // Spawn wine64 as a child process group so we can SIGTERM the whole tree.
        const char *args[] = {
            [wineBin UTF8String],
            "start",
            "C:\\Client.application",
            NULL,
        };
        posix_spawnattr_t attr;
        posix_spawnattr_init(&attr);
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
        posix_spawnattr_setpgroup(&attr, 0);   // child becomes its own group leader

        int rc = posix_spawn(&gWinePid, [wineBin UTF8String], NULL, &attr, (char **)args, environ);
        posix_spawnattr_destroy(&attr);
        if (rc != 0) {
            NSAlert *a = [[NSAlert alloc] init];
            a.messageText = @"Failed to launch Wine";
            a.informativeText = [NSString stringWithFormat:@"posix_spawn errno %d for %@", rc, wineBin];
            [a runModal];
            return 1;
        }

        waitForWineInBackground();
        [NSApp run];     // run loop; terminated when wine64 exits or user quits
        killWine();
    }
    return 0;
}
