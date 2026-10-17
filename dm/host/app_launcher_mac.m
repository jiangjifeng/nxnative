// Configure the bundled host in place, preserving its Launch Services identity.
#import <Cocoa/Cocoa.h>
#include "app_launcher_mac.h"
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void envpath(const char *key, NSString *path) { setenv(key, path.fileSystemRepresentation, 1); }
static int fail(NSString *message) {
    NSAlert *alert = [NSAlert new];
    NSString *name = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"Game";
    alert.messageText = [@"Unable to start " stringByAppendingString:name];
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    return 1;
}
void dm_mac_app_setup(int *argc, char ***argv) {
    @autoreleasepool {
        NSBundle *bundle = NSBundle.mainBundle;
        NSString *game = [bundle.resourcePath stringByAppendingPathComponent:@"game"];
        NSString *host = [bundle.bundlePath stringByAppendingPathComponent:@"Contents/MacOS/dmhost"];
        NSString *patched = [game stringByAppendingPathComponent:@"patched"];
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *title = [bundle objectForInfoDictionaryKey:@"DMGameTitleID"];
        if (!title.length) return;   // Plain command-line host: retain its arguments and environment
        // Diagnostic bundles keep per-frame attribution in log.txt without a
        // debugger or per-frame TSV. Regular bundles retain the default logging.
        if ([[bundle objectForInfoDictionaryKey:@"DMGameSlowFrameDiagnostics"] boolValue] && !getenv("DM_SLOWFRAME")) setenv("DM_SLOWFRAME", "1", 1);
        NSString *marker = [bundle objectForInfoDictionaryKey:@"DMGameRomfsMarker"];
        NSString *support = [fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject.path;
        NSString *data = [[support stringByAppendingPathComponent:@"nxnative"] stringByAppendingPathComponent:title];
        if (!marker.length || ![fm isExecutableFileAtPath:host] || ![fm fileExistsAtPath:[[game stringByAppendingPathComponent:@"romfs"] stringByAppendingPathComponent:marker]])
            exit(fail(@"The bundled game files are incomplete. Rebuild the app."));
        NSError *error = nil;
        for (NSString *sub in @[@"run", @"save", @"temp"]) {
            if (![fm createDirectoryAtPath:[data stringByAppendingPathComponent:sub] withIntermediateDirectories:YES attributes:nil error:&error])
                exit(fail([NSString stringWithFormat:@"Unable to create the save directory: %@", error.localizedDescription]));
        }
        int lock = open([[data stringByAppendingPathComponent:@"run/game.lock"] fileSystemRepresentation], O_CREAT | O_RDWR, 0600);
        if (lock < 0) exit(fail(@"Unable to open the game data directory."));
        if (flock(lock, LOCK_EX | LOCK_NB)) exit(0);
        NSString *log = [data stringByAppendingPathComponent:@"run/log.txt"];
        NSString *previous = [data stringByAppendingPathComponent:@"run/log.prev.txt"];
        if ([fm fileExistsAtPath:log]) { [fm removeItemAtPath:previous error:NULL]; [fm moveItemAtPath:log toPath:previous error:NULL]; }
        if (!freopen(log.fileSystemRepresentation, "w", stdout)) exit(fail(@"Unable to create the game log."));
        dup2(STDOUT_FILENO, STDERR_FILENO); setvbuf(stdout, NULL, _IOLBF, 0);
        [[NSString stringWithFormat:@"%d\n", getpid()] writeToFile:[data stringByAppendingPathComponent:@"run/dmhost.pid"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        envpath("DM_ROOT", data);
        envpath("DM_ROMFS", [game stringByAppendingPathComponent:@"romfs"]);
        envpath("DM_AOC_DIR", [game stringByAppendingPathComponent:@"aoc"]);
        envpath("DM_SAVE", [data stringByAppendingPathComponent:@"save"]);
        envpath("DM_TEMP", [data stringByAppendingPathComponent:@"temp"]);
        envpath("DM_MSL_DIR", [game stringByAppendingPathComponent:@"metal_shader_cache"]);
        envpath("DM_NVN_SHMAP", [game stringByAppendingPathComponent:@"profile/shader_map.tsv"]);
        envpath("DM_FONT_DIR", [game stringByAppendingPathComponent:@"font"]);
        setenv("DM_WINDOW", "1", 1); setenv("DM_AUDIO", "1", 1);
        if (!getenv("DM_LANG")) envpath("DM_LANG", [bundle objectForInfoDictionaryKey:@"DMGameDefaultLanguage"] ?: @"en");
        chdir(data.fileSystemRepresentation);
        // Finder starts dmhost itself. Replacing it with exec breaks foreground
        // registration when CFBundleExecutable names a separate launcher.
        static char *args[3];
        args[0] = strdup((*argv)[0]); args[1] = strdup(patched.fileSystemRepresentation);
        *argc = 2; *argv = args;
    }
}
