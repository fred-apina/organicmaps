// Internal declarations shared by the OfflineNavEngine sources. Not public API.
#pragma once

#import <Foundation/Foundation.h>

#import "OMNEngine.h"

#include "map/framework.hpp"

NS_ASSUME_NONNULL_BEGIN

/// The engine singleton, created on first use.
Framework & OMNFramework();

/// An NSError in OMNErrorDomain carrying a stable `code` string.
NSError * OMNError(NSString * code, NSString * message);

/// Sends a download event to the handler set by the host, on the main thread.
void OMNSendDownloadEvent(NSDictionary<NSString *, id> * event);

/// NSErrorUserInfoKey for extra machine-readable details of an error.
extern NSErrorUserInfoKey const OMNErrorDetailsKey;

/// Navigation's side of OMNEngine mapDidBecomeReady / mapWasLost.
void OMNNavigationMapDidBecomeReady();
void OMNNavigationMapWasLost();

@interface OMNEngine ()

/// YES when the engine is initialized; otherwise fills `error` with "not_ready".
+ (BOOL)requireReady:(NSError * _Nullable __autoreleasing * _Nullable)error;

/// The map view got a drawing engine that can show the current route.
+ (void)mapDidBecomeReady;
/// The map view is gone.
+ (void)mapWasLost;

@end

/// Source of device location for the engine: the real GPS or a simulated drive.
/// Every update, real or simulated, goes to the engine and to the one-shot
/// first-fix handler.
@interface OMNLocationController : NSObject

+ (instancetype)shared;

@property(nonatomic, readonly) BOOL hasPermission;
- (void)requestPermission:(void (^)(BOOL granted))completion;

/// Called once with the next location, whatever its source.
@property(nonatomic, copy, nullable) void (^firstFixHandler)(void);

- (void)startRealUpdates;
/// Feeds `points` (lat/lon pairs in NSValue of CGPoint: x = latitude, y = longitude)
/// to the engine one per second, like a car driving the route.
- (void)startSimulationWithPoints:(NSArray<NSValue *> *)points;
- (void)stopAll;
@property(nonatomic, readonly) BOOL isSimulating;

@end

NS_ASSUME_NONNULL_END
