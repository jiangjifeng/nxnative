// GameController input for macOS, kept separate from keyboard input in hle_hid.c.
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#include "dm.h"
#include "dm_input.h"
#include "gamepad_mac.h"
#include <math.h>

static NSArray<GCController *> *g_controllers;
static int g_active = 1;
static dispatch_source_t g_poll;

static void read_stick(GCControllerDirectionPad *stick, int32_t *x, int32_t *y) {
    float sx = stick.xAxis.value, sy = stick.yAxis.value;
    if (sx * sx + sy * sy < 0.12f * 0.12f) { *x = *y = 0; return; }
    *x = (int32_t)(fmaxf(-1.f, fminf(1.f, sx)) * DM_STICK_MAX);
    *y = (int32_t)(fmaxf(-1.f, fminf(1.f, sy)) * DM_STICK_MAX);
}

static int64_t magnitude(int32_t x, int32_t y) { return (int64_t)x * x + (int64_t)y * y; }

static void publish_controllers(void) {
    uint64_t buttons = 0;
    int32_t lx = 0, ly = 0, rx = 0, ry = 0;
    if (g_active) for (GCController *controller in g_controllers) {
        GCExtendedGamepad *pad = controller.extendedGamepad;
        // Switch Pro profiles already expose their native A/B/X/Y labels.
        // A second positional swap reverses the physical buttons; preserve the
        // named elements and the player's system-level controller mappings.
        #define BUTTON(input, bit) do { if ((input).isPressed) buttons |= (bit); } while (0)
        BUTTON(pad.buttonA, DM_BTN_A); BUTTON(pad.buttonB, DM_BTN_B);
        BUTTON(pad.buttonX, DM_BTN_X); BUTTON(pad.buttonY, DM_BTN_Y);
        BUTTON(pad.leftShoulder, DM_BTN_L); BUTTON(pad.rightShoulder, DM_BTN_R);
        BUTTON(pad.leftTrigger, DM_BTN_ZL); BUTTON(pad.rightTrigger, DM_BTN_ZR);
        BUTTON(pad.buttonMenu, DM_BTN_PLUS); BUTTON(pad.buttonOptions, DM_BTN_MINUS);
        BUTTON(pad.leftThumbstickButton, DM_BTN_LS); BUTTON(pad.rightThumbstickButton, DM_BTN_RS);
        BUTTON(pad.dpad.left, DM_BTN_LEFT); BUTTON(pad.dpad.up, DM_BTN_UP);
        BUTTON(pad.dpad.right, DM_BTN_RIGHT); BUTTON(pad.dpad.down, DM_BTN_DOWN);
        #undef BUTTON
        // Connected controllers share player one; an idle device cannot erase
        // the other controller's buttons or either of its sticks.
        int32_t x, y;
        read_stick(pad.leftThumbstick, &x, &y);
        if (magnitude(x, y) > magnitude(lx, ly)) { lx = x; ly = y; }
        read_stick(pad.rightThumbstick, &x, &y);
        if (magnitude(x, y) > magnitude(rx, ry)) { rx = x; ry = y; }
    }
    static int trace = -1, records;
    static uint64_t previous_buttons = UINT64_MAX;
    static int32_t previous_axes[4];
    if (trace < 0) trace = getenv("DM_MAC_PAD_LOG") != NULL;
    if (trace && records < 256 && (buttons != previous_buttons || lx != previous_axes[0] || ly != previous_axes[1] || rx != previous_axes[2] || ry != previous_axes[3])) {
        LOG("Mac gamepad publish: active=%d buttons=%#llx left=%d,%d right=%d,%d", g_active, (unsigned long long)buttons, lx, ly, rx, ry);
        previous_buttons = buttons; previous_axes[0] = lx; previous_axes[1] = ly; previous_axes[2] = rx; previous_axes[3] = ry; records++;
    }
    dm_pad_set(buttons, lx, ly, rx, ry);
}

static void install_controllers(NSArray<GCController *> *controllers) {
    for (GCController *controller in g_controllers) controller.extendedGamepad.valueChangedHandler = nil;
    NSMutableArray<GCController *> *supported = [NSMutableArray array];
    for (GCController *controller in controllers) {
        if (!controller.extendedGamepad) continue;
        [supported addObject:controller];
        controller.handlerQueue = dispatch_get_main_queue();
        controller.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *pad, GCControllerElement *element) {
            (void)pad; (void)element; publish_controllers();
        };
        LOG("Mac controller connected: %s (%s)", controller.vendorName.UTF8String ?: "unknown", controller.productCategory.UTF8String ?: "unknown");
    }
    g_controllers = supported;
    LOG("Mac controllers: %lu", (unsigned long)g_controllers.count);
    publish_controllers();
}

void dm_mac_gamepad_active(int active) { g_active = active; LOG("Mac input focus: %s", active ? "active" : "inactive"); publish_controllers(); }

void dm_mac_gamepad_start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Keep the framework's state current across focus transitions. The
        // window's explicit g_active gate controls what reaches the game.
        GCController.shouldMonitorBackgroundEvents = YES;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSNotificationName name in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification]) {
            [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
                (void)notification; install_controllers(GCController.controllers);
            }];
        }
        install_controllers(GCController.controllers);
        // Some Bluetooth profiles coalesce callbacks. Sample their current
        // state as well; callbacks still latch short button presses promptly.
        g_poll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(g_poll, DISPATCH_TIME_NOW, NSEC_PER_SEC / 60, NSEC_PER_MSEC);
        dispatch_source_set_event_handler(g_poll, ^{ publish_controllers(); });
        dispatch_resume(g_poll);
    });
}
