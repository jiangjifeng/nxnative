#pragma once

// Called from the drawable's presented callback, with its actual presentedTime.
void nvn_fps_presented(double time);
// Main thread only. parent is a CALayer; top_left_origin is 1 for UIKit, 0 for
// AppKit. The overlay is on by default; DM_SHOW_FPS=0 disables it at launch.
void nvn_fps_hud_install(void *parent, int top_left_origin);
// Insets are measured from the parent's top left in points (iOS safe area).
void nvn_fps_hud_layout(double left, double top, double scale);
