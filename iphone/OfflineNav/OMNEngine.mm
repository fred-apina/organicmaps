#import "OMNEngine.h"

#import <UIKit/UIKit.h>

#import "OMNInternal.hpp"

#include "geometry/mercator.hpp"

#include "shaders/metal_program_pool.hpp"

#include "platform/downloader_defines.hpp"
#include "platform/platform.hpp"

#include "storage/country_info_getter.hpp"
#include "storage/storage.hpp"

#include "base/exception.hpp"
#include "base/logging.hpp"

#include <string>

NSErrorDomain const OMNErrorDomain = @"OfflineNavEngine";
NSErrorUserInfoKey const OMNErrorCodeKey = @"code";
NSErrorUserInfoKey const OMNErrorDetailsKey = @"details";

NSError * OMNError(NSString * code, NSString * message)
{
  return [NSError errorWithDomain:OMNErrorDomain
                             code:1
                         userInfo:@{OMNErrorCodeKey: code, NSLocalizedDescriptionKey: message}];
}

@implementation OMNPoint
- (instancetype)initWithLatitude:(double)latitude longitude:(double)longitude name:(NSString *)name
{
  if ((self = [super init]))
  {
    _latitude = latitude;
    _longitude = longitude;
    _name = [name copy];
  }
  return self;
}
@end

namespace
{
enum class State
{
  Idle,
  Initializing,
  Ready
};

State g_state = State::Idle;
NSMutableArray<OMNCompletion> * g_onReady = [NSMutableArray array];
NSString * g_dataDirectory = nil;
OMNEventHandler g_downloadHandler = nil;
int g_storageSlot = -1;

// A native abort during engine init (for example a corrupt settings file) kills the process before
// any of this code can react. So a marker is set before init and cleared after it. If it is still
// set at the next start, the previous init died half way: delete the engine's settings file so a
// corrupt one cannot crash the app forever. Downloaded maps and the host app's files are never
// touched.
NSString * const kInitInFlightKey = @"offline_navigation_engine_init_in_flight";

NSString * SupportDirectory()
{
  NSString * support =
      NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
  return [support stringByAppendingPathComponent:@"offline_navigation"];
}

void SetInitInFlight(bool inFlight)
{
  [NSUserDefaults.standardUserDefaults setBool:inFlight forKey:kInitInFlightKey];
  [NSUserDefaults.standardUserDefaults synchronize];  // must survive an immediate native crash
}

void SelfHealIfPreviousInitCrashed()
{
  if (![NSUserDefaults.standardUserDefaults boolForKey:kInitInFlightKey])
    return;
  NSLog(@"offline_navigation: previous engine init never completed, clearing engine settings (self-heal)");
  NSString * settings = [SupportDirectory() stringByAppendingPathComponent:@"settings.ini"];
  [NSFileManager.defaultManager removeItemAtPath:settings error:nil];
}

void ConfigurePlatform()
{
  NSString * root = SupportDirectory();
  [NSFileManager.defaultManager createDirectoryAtPath:root
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  // Downloaded maps must not go to iCloud backups.
  Platform::DisableBackupForFile(root.UTF8String);

  // The compiled shaders are built per SDK, so they ship inside the framework, not with the data.
  NSString * shaders = [[NSBundle bundleForClass:OMNEngine.class] pathForResource:@"shaders_metal" ofType:@"metallib"];
  if (shaders != nil)
    gpu::metal::SetShaderLibraryPath(shaders.UTF8String);

  Platform & pl = GetPlatform();
  pl.SetResourceDir(g_dataDirectory.UTF8String);
  pl.SetWritableDirForTests(root.UTF8String);
  pl.SetSettingsDir(root.UTF8String);
}

void AddCoreStrings(Framework & f)
{
  // Texts the engine core puts on the map or into routes. Same keys the Organic Maps app sets.
  f.AddString("core_entrance", "Entrance");
  f.AddString("core_exit", "Exit");
  f.AddString("core_my_places", "My Places");
  f.AddString("core_my_position", "My Position");
  f.AddString("core_placepage_unknown_place", "Unknown Place");
  f.AddString("postal_code", "Postal Code");
}

void SubscribeToStorage()
{
  if (g_storageSlot >= 0 || g_state != State::Ready || g_downloadHandler == nil)
    return;

  auto & storage = OMNFramework().GetStorage();
  g_storageSlot = storage.Subscribe(
      [](storage::CountryId const & countryId)
  {
    storage::NodeStatuses ns;
    OMNFramework().GetStorage().GetNodeStatuses(countryId, ns);
    // NOTE: the overall progress of a group node (a country made of many maps) must not be read
    // here, the engine aborts on it. Status changes fire for ancestor groups too. Byte progress
    // comes from the progress callback; progress -1 means "no progress info in this event".
    OMNSendDownloadEvent(@{
      @"countryId": @(countryId.c_str()),
      @"status": @(static_cast<int>(ns.m_status)),
      @"errorCode": @(static_cast<int>(ns.m_error)),
      @"progress": @(-1),
    });
  },
      [](storage::CountryId const & countryId, downloader::Progress const & progress)
  {
    int const percent = progress.m_bytesTotal > 0
                          ? static_cast<int>(progress.m_bytesDownloaded * 100.0 / progress.m_bytesTotal)
                          : 0;
    OMNSendDownloadEvent(@{
      @"countryId": @(countryId.c_str()),
      @"status": @1,  // in progress
      @"progress": @(percent),
      @"localSize": @(progress.m_bytesDownloaded),
      @"remoteSize": @(progress.m_bytesTotal),
    });
  });
}

void UnsubscribeFromStorage()
{
  if (g_storageSlot < 0)
    return;
  OMNFramework().GetStorage().Unsubscribe(g_storageSlot);
  g_storageSlot = -1;
}

void ObserveApplicationLifecycle()
{
  NSNotificationCenter * nc = NSNotificationCenter.defaultCenter;
  // Metal cannot draw in the background, so drawing stops when the app resigns active and resumes
  // when it becomes active again. Same as the Organic Maps app.
  [nc addObserverForName:UIApplicationWillResignActiveNotification
                  object:nil
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification *) {
                auto & f = OMNFramework();
                f.SetRenderingDisabled(false);
                f.EnterBackground();
              }];
  [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                  object:nil
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification *) {
                auto & f = OMNFramework();
                f.EnterForeground();
                f.SetRenderingEnabled();
              }];
}

void FinishInitialization(NSError * error)
{
  NSArray<OMNCompletion> * callbacks = [g_onReady copy];
  [g_onReady removeAllObjects];
  for (OMNCompletion completion in callbacks)
    completion(error);
}
}  // namespace

void OMNSendDownloadEvent(NSDictionary<NSString *, id> * event)
{
  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_downloadHandler)
      g_downloadHandler(event);
  });
}

@implementation OMNEngine

+ (NSString *)dataDirectory
{
  return g_dataDirectory;
}

+ (void)setDataDirectory:(NSString *)dataDirectory
{
  g_dataDirectory = [dataDirectory copy];
}

+ (BOOL)isInitialized
{
  return g_state == State::Ready;
}

+ (BOOL)requireReady:(NSError **)error
{
  if (g_state == State::Ready)
    return YES;
  if (error)
    *error = OMNError(@"not_ready", @"The map engine is not initialized");
  return NO;
}

+ (void)initializeWithCompletion:(OMNCompletion)completion
{
  dispatch_async(dispatch_get_main_queue(), ^{
    switch (g_state)
    {
    case State::Ready: completion(nil); return;
    case State::Initializing: [g_onReady addObject:[completion copy]]; return;
    case State::Idle: break;
    }

    if (g_dataDirectory.length == 0)
    {
      completion(OMNError(@"init_failed", @"The engine's data directory is not set"));
      return;
    }

    g_state = State::Initializing;
    [g_onReady addObject:[completion copy]];

    try
    {
      SelfHealIfPreviousInitCrashed();
      SetInitInFlight(true);

      ConfigurePlatform();
      auto & f = OMNFramework();
      AddCoreStrings(f);
      // Also configures the turn-notification units. Without it the engine aborts the first time
      // a turn notification is generated.
      f.SetupMeasurementSystem();
      ObserveApplicationLifecycle();

      SetInitInFlight(false);
      g_state = State::Ready;
      SubscribeToStorage();
      FinishInitialization(nil);
    }
    catch (RootException const & ex)
    {
      LOG(LERROR, ("Engine initialization failed:", ex.Msg()));
      g_state = State::Idle;
      FinishInitialization(OMNError(@"init_failed", @(ex.Msg().c_str())));
    }
    catch (std::exception const & ex)
    {
      LOG(LERROR, ("Engine initialization failed:", ex.what()));
      g_state = State::Idle;
      FinishInitialization(OMNError(@"init_failed", @(ex.what())));
    }
  });
}

+ (void)mapDidBecomeReady
{
  OMNNavigationMapDidBecomeReady();
}

+ (void)mapWasLost
{
  OMNNavigationMapWasLost();
}

// MARK: Location permission

+ (BOOL)hasLocationPermission
{
  return OMNLocationController.shared.hasPermission;
}

+ (void)requestLocationPermission:(void (^)(BOOL))completion
{
  [OMNLocationController.shared requestPermission:completion];
}

// MARK: Country maps

+ (NSString *)dataVersion
{
  if (![self requireReady:nil])
    return @"";
  return [NSString stringWithFormat:@"%lld", static_cast<long long>(OMNFramework().GetCurrentDataVersion())];
}

+ (NSString *)countryIdAtLatitude:(double)latitude longitude:(double)longitude
{
  if (![self requireReady:nil])
    return nil;
  auto const id = OMNFramework().GetCountryInfoGetter().GetRegionCountryId(mercator::FromLatLon(latitude, longitude));
  return id.empty() ? nil : @(id.c_str());
}

+ (BOOL)isCountry:(NSString *)countryId
{
  if (countryId.length == 0 || ![self requireReady:nil])
    return NO;
  return OMNFramework().GetStorage().IsNode(countryId.UTF8String);
}

+ (NSString *)nameOfCountry:(NSString *)countryId
{
  if (![self isCountry:countryId])
    return nil;
  storage::NodeAttrs attrs;
  OMNFramework().GetStorage().GetNodeAttrs(countryId.UTF8String, attrs);
  return [NSString stringWithUTF8String:attrs.m_nodeLocalName.c_str()];
}

+ (int64_t)sizeOfCountry:(NSString *)countryId
{
  if (![self isCountry:countryId])
    return 0;
  storage::NodeAttrs attrs;
  OMNFramework().GetStorage().GetNodeAttrs(countryId.UTF8String, attrs);
  return static_cast<int64_t>(attrs.m_mwmSize);
}

+ (NSInteger)statusOfCountry:(NSString *)countryId
{
  if (![self isCountry:countryId])
    return 0;
  storage::NodeStatuses ns;
  OMNFramework().GetStorage().GetNodeStatuses(countryId.UTF8String, ns);
  return static_cast<NSInteger>(ns.m_status);
}

+ (void)startDownloadOfCountries:(NSArray<NSString *> *)countryIds
{
  if (![self requireReady:nil])
    return;
  for (NSString * id in countryIds)
    if ([self isCountry:id])
      OMNFramework().GetStorage().DownloadNode(id.UTF8String);
}

+ (void)cancelDownloadOfCountries:(NSArray<NSString *> *)countryIds
{
  if (![self requireReady:nil])
    return;
  for (NSString * id in countryIds)
    if ([self isCountry:id])
      OMNFramework().GetStorage().CancelDownloadNode(id.UTF8String);
}

+ (OMNEventHandler)downloadEventHandler
{
  return g_downloadHandler;
}

+ (void)setDownloadEventHandler:(OMNEventHandler)handler
{
  g_downloadHandler = [handler copy];
  if (handler)
    SubscribeToStorage();
  else if (g_state == State::Ready)
    UnsubscribeFromStorage();
}

@end
