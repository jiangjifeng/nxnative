// Exercise the GameController profiles used by the Mac input bridge.
#include "../gamepad_mac.m"
#include <assert.h>

static uint64_t received_buttons;
static int32_t received_axes[4];
void dm_pad_set(uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    received_buttons = buttons;
    received_axes[0] = lx; received_axes[1] = ly;
    received_axes[2] = rx; received_axes[3] = ry;
}

static void neutral(void) {
    assert(!received_buttons);
    for (int i = 0; i < 4; i++) assert(!received_axes[i]);
}

int main(void) {
    @autoreleasepool {
        GCController *one = GCController.controllerWithExtendedGamepad;
        GCController *two = GCController.controllerWithExtendedGamepad;
        install_controllers(@[one, two]);
        neutral();
        assert(one.extendedGamepad.valueChangedHandler);

        // Preserve the named face buttons, including the Switch Pro A/B labels.
        GCControllerButtonInput *face[] = {one.extendedGamepad.buttonA, one.extendedGamepad.buttonB, one.extendedGamepad.buttonX, one.extendedGamepad.buttonY};
        const uint64_t expected[] = {DM_BTN_A, DM_BTN_B, DM_BTN_X, DM_BTN_Y};
        for (int i = 0; i < 4; i++) {
            [face[i] setValue:1]; publish_controllers(); assert(received_buttons == expected[i]);
            [face[i] setValue:0]; publish_controllers(); neutral();
        }

        [one.extendedGamepad.leftThumbstick setValueForXAxis:-0.6f yAxis:0.8f];
        [one.extendedGamepad.rightThumbstick setValueForXAxis:0.75f yAxis:-0.5f];
        [one.extendedGamepad.leftTrigger setValue:1];
        [one.extendedGamepad.buttonMenu setValue:1];
        [two.extendedGamepad.buttonA setValue:1];
        publish_controllers();
        assert(received_buttons == (DM_BTN_ZL | DM_BTN_PLUS | DM_BTN_A));
        assert(abs(received_axes[0] + 19660) <= 1 && abs(received_axes[1] - 26213) <= 1);
        assert(abs(received_axes[2] - 24575) <= 1 && abs(received_axes[3] + 16383) <= 1);

        // Losing focus releases all input; regaining it samples current state.
        dm_mac_gamepad_active(0); neutral();
        [two.extendedGamepad.buttonA setValue:0];
        dm_mac_gamepad_active(1);
        assert(received_buttons == (DM_BTN_ZL | DM_BTN_PLUS));

        // A disconnected device cannot leave a held button or stick behind.
        install_controllers(@[two]); neutral();
        assert(!one.extendedGamepad.valueChangedHandler);
        [two.extendedGamepad.leftThumbstick setValueForXAxis:0.02f yAxis:-0.03f];
        publish_controllers(); neutral();
        [two.extendedGamepad.dpad setValueForXAxis:-1 yAxis:1];
        publish_controllers(); assert(received_buttons == (DM_BTN_LEFT | DM_BTN_UP));
        install_controllers(@[]); neutral();
        puts("Mac gamepad: face labels, both sticks, triggers, merging, focus and disconnect PASS");
    }
    return 0;
}
