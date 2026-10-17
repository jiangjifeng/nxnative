#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <pthread.h>
#include <stdatomic.h>
#include "nvn_fps.h"
#include "nvn_fps_hud.h"

static nvn_fps g_fps;
static pthread_mutex_t g_fps_mu = PTHREAD_MUTEX_INITIALIZER;
static _Atomic int g_fps_enabled;
static CATextLayer *g_fps_layer;
static NSTimer *g_fps_timer;
static int g_fps_top_left;
static double g_fps_left, g_fps_top, g_fps_scale = 1;

void nvn_fps_presented(double time) {
    if (!atomic_load_explicit(&g_fps_enabled, memory_order_relaxed)) return;
    pthread_mutex_lock(&g_fps_mu);
    nvn_fps_push(&g_fps, time);
    pthread_mutex_unlock(&g_fps_mu);
}
void nvn_fps_hud_layout(double left, double top, double scale) {
    g_fps_left = left; g_fps_top = top; g_fps_scale = scale;
    if (!g_fps_layer) return;
    CGRect b = g_fps_layer.superlayer.bounds;
    CGFloat w = fmin(200, fmax(0, b.size.width - left - 16)), h = 22;
    CGFloat y = g_fps_top_left ? CGRectGetMinY(b) + top + 8 : CGRectGetMaxY(b) - top - 8 - h;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    g_fps_layer.frame = CGRectMake(CGRectGetMinX(b) + left + 8, y, w, h);
    g_fps_layer.contentsScale = fmax(1, scale);
    [CATransaction commit];
}
static void fps_update(void) {
    nvn_fps s;
    pthread_mutex_lock(&g_fps_mu); s = g_fps; pthread_mutex_unlock(&g_fps_mu);
    double fps, ms;
    NSString *text = @"-- FPS | -- ms";
    if (nvn_fps_read(&s, CACurrentMediaTime(), &fps, &ms)) {
        text = fps > 0 ? [NSString stringWithFormat:@"%.1f FPS | %.1f ms", fps, ms] : @"0.0 FPS | -- ms";
    }
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    g_fps_layer.string = text;
    [CATransaction commit];
    // Bounds can change while a Mac window is resized; no per-frame UI work.
    nvn_fps_hud_layout(g_fps_left, g_fps_top, g_fps_scale);
}
void nvn_fps_hud_install(void *parent, int top_left_origin) {
    const char *e = getenv("DM_SHOW_FPS");
    if (!parent || g_fps_layer || (e && !strcmp(e, "0"))) return;
    CALayer *layer = (__bridge CALayer *)parent;
    g_fps_top_left = top_left_origin;
    g_fps_layer = [CATextLayer layer];
    CGFontRef font = CGFontCreateWithFontName(CFSTR("Menlo-Bold"));
    g_fps_layer.font = font; if (font) CGFontRelease(font);
    g_fps_layer.fontSize = 12;
    g_fps_layer.alignmentMode = kCAAlignmentCenter;
    CGColorRef fg = CGColorCreateGenericRGB(1, 1, 1, 1), bg = CGColorCreateGenericRGB(0, 0, 0, 0.7);
    g_fps_layer.foregroundColor = fg; g_fps_layer.backgroundColor = bg;
    CGColorRelease(fg); CGColorRelease(bg);
    g_fps_layer.cornerRadius = 4; g_fps_layer.masksToBounds = YES;
    g_fps_layer.zPosition = 1000;
    [layer addSublayer:g_fps_layer];
    atomic_store_explicit(&g_fps_enabled, 1, memory_order_relaxed);
    fps_update();
    g_fps_timer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { (void)t; fps_update(); }];
    g_fps_timer.tolerance = 0.1;
    [NSRunLoop.mainRunLoop addTimer:g_fps_timer forMode:NSRunLoopCommonModes];
}
