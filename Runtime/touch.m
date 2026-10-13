// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

// Touch injection for UI tests. Mouse events don't reach a hidden window, so
// touches are built the way UIKit's own HID path builds them: a UITouch and a
// UITouchesEvent carrying a digitizer IOHIDEvent, handed to
// -[UIApplication sendEvent:]. UIKit views, controls, scroll views and UIKit
// gesture recognizers react to them, and so do SwiftUI's gestures once the
// touch carries the recognizers of SwiftUI's gesture containers (see below).
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <mach/mach_time.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                                                    CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, Boolean, Boolean, uint32_t);
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEventWithQuality(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                                                     CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat,
                                                                     CGFloat, CGFloat, CGFloat, Boolean, Boolean, uint32_t);
extern void IOHIDEventAppendEvent(IOHIDEventRef, IOHIDEventRef, uint32_t);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef, uint32_t, int64_t);

@interface UITouch (SimlessPrivate)
- (void)setWindow:(UIWindow *)window;
- (void)setView:(UIView *)view;
- (void)setTapCount:(NSUInteger)count;
- (void)setIsTap:(BOOL)isTap;
- (void)setTimestamp:(NSTimeInterval)timestamp;
- (void)setPhase:(UITouchPhase)phase;
- (void)setGestureView:(UIView *)view;
- (void)_setLocationInWindow:(CGPoint)location resetPrevious:(BOOL)reset;
- (void)_setIsFirstTouchForView:(BOOL)first;
- (void)_setHidEvent:(IOHIDEventRef)event;
@end

@interface UIEvent (SimlessPrivate)
- (void)_clearTouches;
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayed;
- (void)_setHIDEvent:(IOHIDEventRef)event;
- (void)_setTimestamp:(NSTimeInterval)timestamp;
@end

@interface UIApplication (SimlessPrivate)
- (UIEvent *)_touchesEvent;
@end

@interface UIView (SimlessPrivate)
- (id)_hitTestWithContext:(id)context;
@end

@interface NSObject (SimlessHitTestContext)
- (instancetype)initWithPoint:(CGPoint)point radius:(CGFloat)radius event:(UIEvent *)event;
@end

@interface UIEvent (SimlessGestures)
- (void)_addGestureRecognizersFromContainer:(id)container toTouch:(UITouch *)touch;
@end

static UITouch *current;

static IOHIDEventRef simless_hid_event(CGPoint p, UITouchPhase phase) {
    uint64_t t = mach_absolute_time();
    BOOL touching = phase != UITouchPhaseEnded && phase != UITouchPhaseCancelled;
    uint32_t mask = (phase == UITouchPhaseMoved) ? 4 /* position */ : (1 | 2) /* range | touch */;
    IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, t, 3 /* hand */, 0, 0, mask, 0,
                                                        0, 0, 0, 0, 0, 0, touching, 0);
    IOHIDEventSetIntegerValue(hand, (11 << 16) | 25 /* digitizer: is display integrated */, 1);
    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEventWithQuality(kCFAllocatorDefault, t, 1, 2, mask,
                                                                           p.x, p.y, 0, 0, 0, 5, 5, 1, 1, 1,
                                                                           touching, touching, 0);
    IOHIDEventAppendEvent(hand, finger, 0);
    CFRelease(finger);
    return hand;
}

static NSTimeInterval lastTimestamp;

/// One phase of a one-finger touch at `point` in `window` coordinates.
/// phase: 0 began, 1 moved, 2 stationary, 3 ended, 4 cancelled.
/// Returns NO if UIKit lacks a method this needs.
BOOL simless_touch(UIWindow *window, CGPoint point, int phase) {
    UIApplication *app = UIApplication.sharedApplication;
    if (![app respondsToSelector:@selector(_touchesEvent)]) return NO;
    UITouchPhase p = (UITouchPhase)phase;
    if (p == UITouchPhaseBegan || current == nil) {
        current = [[UITouch alloc] init];
        UIView *view = [window hitTest:point withEvent:nil] ?: window;
        [current setWindow:window];
        [current setView:view];
        if ([current respondsToSelector:@selector(setGestureView:)]) [current setGestureView:view];
        [current setTapCount:1];
        [current _setLocationInWindow:point resetPrevious:YES];
        if ([current respondsToSelector:@selector(_setIsFirstTouchForView:)]) [current _setIsFirstTouchForView:YES];
        if ([current respondsToSelector:@selector(setIsTap:)]) [current setIsTap:YES];
    } else {
        [current _setLocationInWindow:point resetPrevious:NO];
        if (p == UITouchPhaseMoved && [current respondsToSelector:@selector(setIsTap:)]) [current setIsTap:NO];
    }
    [current setPhase:p];
    // Event times only go forward, even for two events in the same instant.
    NSTimeInterval now = MAX(NSProcessInfo.processInfo.systemUptime, lastTimestamp + 0.0005);
    lastTimestamp = now;
    [current setTimestamp:now];
    IOHIDEventRef hid = simless_hid_event(point, p);
    if ([current respondsToSelector:@selector(_setHidEvent:)]) [current _setHidEvent:hid];
    UIEvent *event = [app _touchesEvent];
    [event _clearTouches];
    if ([event respondsToSelector:@selector(_setTimestamp:)]) [event _setTimestamp:now];
    if ([event respondsToSelector:@selector(_setHIDEvent:)]) [event _setHIDEvent:hid];
    [event _addTouch:current forDelayedDelivery:NO];
    // SwiftUI's gestures live in gesture recognizer containers that aren't
    // views; UIKit finds the deepest one under the finger with its own hit
    // test, and the touch carries the recognizers from there up.
    if (p == UITouchPhaseBegan) {
        Class contextClass = NSClassFromString(@"_UIHitTestContext");
        if (contextClass && [window respondsToSelector:@selector(_hitTestWithContext:)]
            && [event respondsToSelector:@selector(_addGestureRecognizersFromContainer:toTouch:)]) {
            // Asked of the view under the finger (and up), in its own coordinates.
            for (UIView *v = current.view; v != nil; v = v.superview) {
                if (![v respondsToSelector:@selector(_hitTestWithContext:)]) continue;
                id context = [[contextClass alloc] initWithPoint:[v convertPoint:point fromView:window] radius:0 event:event];
                id target = [v _hitTestWithContext:context];
                if (target == nil) { if (v == window) break; continue; }
                // A view (a UIKit control, say) gets its recognizers the usual way.
                if (![target isKindOfClass:UIView.class]) [event _addGestureRecognizersFromContainer:target toTouch:current];
                break;
            }
        }
    }
    [app sendEvent:event];
    CFRelease(hid);
    if (p == UITouchPhaseEnded || p == UITouchPhaseCancelled) current = nil;
    return YES;
}
