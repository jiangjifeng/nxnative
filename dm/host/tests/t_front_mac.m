// AppKit integration checks. Each mode opens a short-lived test window.
#include "../front_mac.m"
#include <assert.h>
#include <unistd.h>

static const char *mode;
void mtl_set_ui_rect_fn(void (*fn)(double *, double *)) { (void)fn; }
void dm_ui_rect(int *x, int *y, int *w, int *h) { *x = *y = 0; *w = 1280; *h = 720; }
int dm_screen_real(int *w, int *h) { *w = 1280; *h = 720; return 1; }
void dm_input_set(uint64_t b, int32_t lx, int32_t ly, int32_t rx, int32_t ry) { (void)b; (void)lx; (void)ly; (void)rx; (void)ry; }
void dm_touch_set(const dm_touch *touch, int count) { (void)touch; (void)count; }
void dm_audio_suspend(int on) { (void)on; }
void dm_gfx_suspend(int on) { (void)on; }
void dm_focus_set(int state) { (void)state; }
void dm_mac_gamepad_start(void) {}
void dm_mac_gamepad_active(int active) { (void)active; }

void dm_host_shutdown(const char *reason) {
    const char *expected = !strcmp(mode, "close") || !strcmp(mode, "cmdw") ? "Mac window close"
                         : !strcmp(mode, "dock") ? "macOS Quit" : "Mac Quit menu";
    assert(!strcmp(reason, expected));
    assert(!g_btn && !g_w && !g_a && !g_s && !g_d);
    fprintf(stderr, "Mac front end %s: shutdown through %s PASS\n", mode, reason);
    _exit(0);
}
static void guest(void) { for (;;) usleep(100000); }

int main(int argc, char **argv) {
    assert(argc == 2); mode = argv[1];
    assert(!strcmp(mode, "close") || !strcmp(mode, "menu") || !strcmp(mode, "cmdq") || !strcmp(mode, "cmdw") || !strcmp(mode, "dock"));
    setenv("DM_WINDOW", "1", 1);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        NSWindow *window = NSApp.keyWindow;
        // A desktop that has not granted the test window focus may have no key
        // window. Report the setup failure without producing a macOS crash report.
        if (!window) { fprintf(stderr, "Mac front end %s: no active test window; run on a desktop with window focus\n", mode); _exit(77); }
        if (!strcmp(mode, "close")) [window performClose:nil];
        else if (!strcmp(mode, "menu")) [[NSApp.mainMenu itemAtIndex:0].submenu performActionForItemAtIndex:0];
        else if (!strcmp(mode, "dock")) [NSApp terminate:nil];
        else {
            BOOL quit = !strcmp(mode, "cmdq");
            NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:window.windowNumber context:nil characters:quit ? @"q" : @"w" charactersIgnoringModifiers:quit ? @"q" : @"w" isARepeat:NO keyCode:quit ? 12 : 13];
            [NSApp postEvent:event atStart:NO];
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ fprintf(stderr, "Mac front end %s timed out\n", mode); _exit(90); });
    front_run(guest);
    return 91;
}
