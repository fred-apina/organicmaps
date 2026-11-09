// Public Objective-C API of OfflineNavEngine.framework: the Organic Maps routing
// and map engine, trimmed to what the offline_navigation Flutter plugin needs.
//
// Everything is main-thread: call from the main thread, callbacks arrive on it.
// The engine is a process-wide singleton, so the API is class methods.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// NSError domain of every error this framework reports.
FOUNDATION_EXPORT NSErrorDomain const OMNErrorDomain;
/// `userInfo[OMNErrorCodeKey]` is a stable machine-readable code such as
/// "checksum_mismatch" (the same codes the Android plugin reports).
FOUNDATION_EXPORT NSErrorUserInfoKey const OMNErrorCodeKey;

typedef NS_ENUM(NSInteger, OMNTravelMode) {
  OMNTravelModeDrive = 0,
  OMNTravelModeWalk = 1,
  OMNTravelModeCycle = 2,
};

/// A geographic point with an optional display name.
NS_SWIFT_NAME(EnginePoint)
@interface OMNPoint : NSObject
@property(nonatomic, readonly) double latitude;
@property(nonatomic, readonly) double longitude;
@property(nonatomic, readonly, copy, nullable) NSString * name;
- (instancetype)initWithLatitude:(double)latitude longitude:(double)longitude name:(nullable NSString *)name;
@end

/// Outcome of a route build.
NS_SWIFT_NAME(EngineRouteResult)
@interface OMNRouteResult : NSObject
@property(nonatomic, readonly) BOOL ok;
/// The build was aborted because routing was closed.
@property(nonatomic, readonly) BOOL cancelled;
/// Native routing result code; meaningful when `ok` is NO.
@property(nonatomic, readonly) NSInteger errorCode;
/// Country ids that must be downloaded before this route can be built.
@property(nonatomic, readonly, copy) NSArray<NSString *> * missingMaps;
@property(nonatomic, readonly, copy, nullable) NSString * distanceText;
@property(nonatomic, readonly, copy, nullable) NSString * distanceUnits;
@property(nonatomic, readonly) NSInteger timeSeconds;
@end

/// A region map installed in the engine's maps directory.
NS_SWIFT_NAME(EngineRegionMap)
@interface OMNRegionMap : NSObject
@property(nonatomic, readonly, copy) NSString * mapId;
@property(nonatomic, readonly) int64_t sizeBytes;
@end

typedef void (^OMNCompletion)(NSError * _Nullable error);
typedef void (^OMNRegionMapCompletion)(OMNRegionMap * _Nullable map, NSError * _Nullable error);
typedef void (^OMNRouteCompletion)(OMNRouteResult * _Nullable result, NSError * _Nullable error);
typedef void (^OMNEventHandler)(NSDictionary<NSString *, id> * event);

// MARK: - Lifecycle, location and country maps

NS_SWIFT_NAME(Engine)
@interface OMNEngine : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Directory that holds the engine's shared data files (fonts, symbols, style rules...).
/// Must be set before `initialize`.
@property(class, nonatomic, copy, nullable) NSString * dataDirectory;

/// Starts the engine. Safe to call repeatedly: later calls wait for the first.
+ (void)initializeWithCompletion:(OMNCompletion)completion;
@property(class, nonatomic, readonly) BOOL isInitialized;

+ (BOOL)hasLocationPermission;
+ (void)requestLocationPermission:(void (^)(BOOL granted))completion;

/// The engine's map-data version, for example "260714".
+ (NSString *)dataVersion;
+ (nullable NSString *)countryIdAtLatitude:(double)latitude longitude:(double)longitude;
+ (NSInteger)statusOfCountry:(NSString *)countryId;
/// Whether `countryId` is in the engine's country list. The engine aborts the process when it is asked about an id
/// that is not, so the calls below that take an id check it first; use this to tell an unknown id from a known one.
+ (BOOL)isCountry:(NSString *)countryId;
/// The engine's display name for a country-list node (a country, or a region of one); nil for an unknown id.
+ (nullable NSString *)nameOfCountry:(NSString *)countryId;
/// Size in bytes of the map of a country-list node: a region's file, or the sum of its regions for a country the
/// engine splits. 0 for an unknown id.
+ (int64_t)sizeOfCountry:(NSString *)countryId;
+ (void)startDownloadOfCountries:(NSArray<NSString *> *)countryIds;
+ (void)cancelDownloadOfCountries:(NSArray<NSString *> *)countryIds;

/// Set to receive download events (dictionaries shaped like the Android plugin's); nil to stop.
@property(class, nonatomic, copy, nullable) OMNEventHandler downloadEventHandler;

@end

// MARK: - Base world maps

@interface OMNEngine (BaseMaps)

/// Bytes of base world maps still missing (0 = present); negative values are engine errors.
+ (int64_t)baseMapBytesToDownload;
/// Progress arrives on `downloadEventHandler` under the country id "__base__".
+ (void)downloadBaseMapsWithCompletion:(OMNCompletion)completion;
+ (void)cancelBaseMapDownload;

@end

// MARK: - Region maps

@interface OMNEngine (RegionMaps)

+ (nullable NSString *)regionMapsDirectory:(NSError * _Nullable * _Nullable)error;
+ (int64_t)freeSpaceBytes;
+ (void)installRegionMapWithId:(NSString *)mapId
                          path:(NSString *)path
                        sha256:(nullable NSString *)sha256
                      moveFile:(BOOL)moveFile
                       replace:(BOOL)replace
                    completion:(OMNRegionMapCompletion)completion;
+ (void)removeRegionMapWithId:(NSString *)mapId completion:(OMNCompletion)completion;
+ (NSArray<OMNRegionMap *> *)listRegionMaps;
+ (BOOL)isRegionMapInstalled:(NSString *)mapId;

@end

// MARK: - Navigation

@interface OMNEngine (Navigation)

+ (void)buildRouteFrom:(OMNPoint *)start
                    to:(OMNPoint *)destination
                  mode:(OMNTravelMode)mode
            completion:(OMNRouteCompletion)completion;
+ (void)startGuidanceSimulated:(BOOL)simulate voice:(BOOL)voice completion:(OMNCompletion)completion;
+ (void)stopGuidance;
+ (void)closeRouting;
+ (void)setViewportLatitude:(double)latitude longitude:(double)longitude zoom:(NSInteger)zoom;

/// Set to receive a guidance snapshot about once a second while guiding; nil to stop.
@property(class, nonatomic, copy, nullable) OMNEventHandler guidanceEventHandler;

@end

NS_ASSUME_NONNULL_END
