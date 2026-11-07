// Headless navigation session driving the engine's routing: builds a route between two fixed
// points, starts and stops turn-by-turn guidance, and reports a guidance snapshot once a second
// while guiding. This is the iOS counterpart of NavigationSession.kt in the Android plugin and
// keeps the same behaviour, including the follow-camera timing.

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

#import "OMNInternal.hpp"

#include "map/routing_manager.hpp"
#include "map/routing_mark.hpp"

#include "routing/following_info.hpp"
#include "routing/routing_callbacks.hpp"
#include "routing/routing_options.hpp"
#include "routing/routing_session.hpp"

#include "geometry/distance_on_sphere.hpp"
#include "geometry/mercator.hpp"
#include "geometry/point_with_altitude.hpp"

#include "base/logging.hpp"

#include <string>
#include <vector>

@interface OMNRouteResult ()
@property(nonatomic, readwrite) BOOL ok;
@property(nonatomic, readwrite) BOOL cancelled;
@property(nonatomic, readwrite) NSInteger errorCode;
@property(nonatomic, readwrite, copy) NSArray<NSString *> * missingMaps;
@property(nonatomic, readwrite, copy, nullable) NSString * distanceText;
@property(nonatomic, readwrite, copy, nullable) NSString * distanceUnits;
@property(nonatomic, readwrite) NSInteger timeSeconds;
@end

@implementation OMNRouteResult
@end

// MARK: - Voice

@interface OMNSpeaker : NSObject <AVSpeechSynthesizerDelegate>
+ (instancetype)shared;
- (void)speak:(NSString *)text;
- (void)stop;
@end

@implementation OMNSpeaker
{
  AVSpeechSynthesizer * _synthesizer;
  BOOL _sessionActive;
}

+ (instancetype)shared
{
  static OMNSpeaker * instance;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ instance = [[OMNSpeaker alloc] init]; });
  return instance;
}

- (instancetype)init
{
  if ((self = [super init]))
  {
    _synthesizer = [[AVSpeechSynthesizer alloc] init];
    _synthesizer.delegate = self;
  }
  return self;
}

- (void)activateSession
{
  if (_sessionActive)
    return;
  AVAudioSession * session = AVAudioSession.sharedInstance;
  NSError * error = nil;
  // Spoken directions interrupt other spoken audio and lower music while they play.
  [session setCategory:AVAudioSessionCategoryPlayback
                  mode:AVAudioSessionModeVoicePrompt
               options:AVAudioSessionCategoryOptionInterruptSpokenAudioAndMixWithOthers |
                       AVAudioSessionCategoryOptionDuckOthers
                 error:&error];
  if (error == nil)
    [session setActive:YES error:&error];
  _sessionActive = (error == nil);
}

- (void)deactivateSession
{
  if (!_sessionActive)
    return;
  _sessionActive = NO;
  [AVAudioSession.sharedInstance setActive:NO
                               withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                     error:nil];
}

- (void)speak:(NSString *)text
{
  NSLog(@"offline_navigation: speaking \"%@\"", text);
  [self activateSession];
  AVSpeechUtterance * utterance = [AVSpeechUtterance speechUtteranceWithString:text];
  utterance.voice = [AVSpeechSynthesisVoice voiceWithLanguage:AVSpeechSynthesisVoice.currentLanguageCode];
  utterance.rate = AVSpeechUtteranceDefaultSpeechRate;
  [_synthesizer speakUtterance:utterance];
}

- (void)stop
{
  [_synthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
  [self deactivateSession];
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didFinishSpeechUtterance:(AVSpeechUtterance *)utterance
{
  if (!synthesizer.isSpeaking)
    [self deactivateSession];
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didCancelSpeechUtterance:(AVSpeechUtterance *)utterance
{
  if (!synthesizer.isSpeaking)
    [self deactivateSession];
}

@end

// MARK: - Session

namespace
{
constexpr NSTimeInterval kGuidanceIntervalSeconds = 1.0;

/// Max distance between simulated route points, in meters. One point goes out per second, so this
/// is also the simulated speed in m/s: 15 m/s is about 54 km/h, realistic urban driving, and small
/// enough hops that the follow camera animates smoothly instead of flying out in zoom-out arcs.
constexpr double kSimulationStepMeters = 15.0;

/// Engage the follow camera anyway if no position arrives in time; the camera then recovers on the
/// next position.
constexpr NSTimeInterval kFollowFallbackSeconds = 5.0;

/// Delay between the first position arriving and engaging the follow camera. The map renderer must
/// have processed the position before the route is followed, or the first position resets the
/// my-position mode and the navigation zoom is never applied. The renderer picks positions up
/// within a frame or two; this covers even a slow frame.
constexpr NSTimeInterval kFollowEngageDelaySeconds = 3.0;

NSArray<NSString *> * const kUnitNames = @[@"Meters", @"Kilometers", @"Feet", @"Miles"];

/// Decides when the route preview has to be fitted to the screen again.
///
/// When a route has been built the engine zooms the map to it, but only if the map's drawing
/// engine exists at that moment; otherwise the zoom is silently dropped and the preview stays at
/// the zoom it started with. A short route is built in well under a second, often before the map
/// of a freshly opened page has a drawing engine. So: when a route is built while the map is not
/// ready, remember that, and when the map becomes ready ask the engine for the route once more,
/// which makes it fit the route this time.
struct RefitGate
{
  bool mapReady = false;
  bool refitPending = false;

  void OnRouteBuilt() { refitPending = !mapReady; }
  bool OnMapReady()
  {
    mapReady = true;
    bool const refit = refitPending;
    refitPending = false;
    return refit;
  }
  void OnMapLost() { mapReady = false; }
  void OnRouteClosed() { refitPending = false; }
};

RefitGate g_refitGate;
bool g_listenerAttached = false;
OMNRouteCompletion g_pendingBuild = nil;
OMNEventHandler g_guidanceHandler = nil;
bool g_guiding = false;
bool g_voice = false;
bool g_followArmed = false;
NSTimer * g_pumpTimer = nil;
NSTimer * g_followFallbackTimer = nil;

RoutingManager & Rm()
{
  return OMNFramework().GetRoutingManager();
}

routing::RouterType RouterFor(OMNTravelMode mode)
{
  switch (mode)
  {
  case OMNTravelModeWalk: return routing::RouterType::Pedestrian;
  case OMNTravelModeCycle: return routing::RouterType::Bicycle;
  case OMNTravelModeDrive: break;
  }
  return routing::RouterType::Vehicle;
}

RouteMarkData MakeMark(OMNPoint * point, RouteMarkType type, NSString * defaultName)
{
  RouteMarkData data;
  data.m_title = (point.name ?: defaultName).UTF8String;
  data.m_pointType = type;
  data.m_isMyPosition = false;
  data.m_position = mercator::FromLatLon(point.latitude, point.longitude);
  return data;
}

NSString * UnitsName(platform::Distance const & distance)
{
  auto const index = static_cast<NSUInteger>(distance.GetUnits());
  return index < kUnitNames.count ? kUnitNames[index] : @"Meters";
}

/// The following info, or false when the route is not active or the info is not valid yet.
bool GetFollowingInfo(routing::FollowingInfo & info)
{
  auto & rm = Rm();
  if (!rm.IsRoutingActive())
    return false;
  rm.GetRouteFollowingInfo(info);
  return info.IsValid();
}

NSDictionary<NSString *, id> * Serialize(routing::FollowingInfo const & info)
{
  return @{
    @"distToTarget": @(info.m_distToTarget.GetDistanceString().c_str()),
    @"distToTargetUnits": UnitsName(info.m_distToTarget),
    @"distToTurn": @(info.m_distToTurn.GetDistanceString().c_str()),
    @"distToTurnUnits": UnitsName(info.m_distToTurn),
    @"currentStreet": @(info.m_currentStreetName.c_str()),
    @"nextStreet": @(info.m_nextStreetName.c_str()),
    @"timeSeconds": @(info.m_time),
    @"completionPercent": @(info.m_completionPercent),
    @"carDirection": @(static_cast<int>(info.m_turn)),
    @"exitNum": @(info.m_exitNum),
    @"speedLimitMps": @(info.m_speedLimitMps),
  };
}

void CompletePendingBuild(OMNRouteResult * result)
{
  OMNRouteCompletion pending = g_pendingBuild;
  g_pendingBuild = nil;
  if (pending)
    pending(result, nil);
}

OMNRouteResult * FailedResult(NSInteger code, NSArray<NSString *> * missingMaps)
{
  OMNRouteResult * result = [[OMNRouteResult alloc] init];
  result.ok = NO;
  result.cancelled = NO;
  result.errorCode = code;
  result.missingMaps = missingMaps ?: @[];
  result.timeSeconds = 0;
  return result;
}

void OnRouteBuildingResult(routing::RouterResultCode code, storage::CountriesSet const & missing)
{
  bool const succeeded = code == routing::RouterResultCode::NoError || code == routing::RouterResultCode::HasWarnings;

  if (g_pendingBuild == nil)
  {
    // No build in flight: this is a rebuild during guidance (for example the position left the
    // route). The rebuild can deactivate the camera's route following while the session-level
    // follow flag stays set, so a plain follow would do nothing: ask for it again.
    NSLog(@"offline_navigation: mid-guidance routing event: code=%d missing=%zu", static_cast<int>(code), missing.size());
    if (g_guiding && succeeded)
      Rm().FollowRoute();
    return;
  }

  if (!succeeded)
  {
    NSMutableArray<NSString *> * maps = [NSMutableArray array];
    for (auto const & id : missing)
      [maps addObject:@(id.c_str())];
    CompletePendingBuild(FailedResult(static_cast<NSInteger>(code), maps));
    return;
  }

  g_refitGate.OnRouteBuilt();
  OMNRouteResult * result = [[OMNRouteResult alloc] init];
  result.ok = YES;
  result.cancelled = NO;
  result.errorCode = 0;
  result.missingMaps = @[];
  routing::FollowingInfo info;
  if (GetFollowingInfo(info))
  {
    result.distanceText = @(info.m_distToTarget.GetDistanceString().c_str());
    result.distanceUnits = UnitsName(info.m_distToTarget);
    result.timeSeconds = info.m_time;
  }
  CompletePendingBuild(result);
}

void AttachRoutingListener()
{
  if (g_listenerAttached)
    return;
  Rm().SetRouteBuildingListener([](routing::RouterResultCode code, storage::CountriesSet const & missing)
  {
    // Copy: the set belongs to the engine and is gone once this callback returns.
    storage::CountriesSet const missingCopy = missing;
    dispatch_async(dispatch_get_main_queue(), ^{ OnRouteBuildingResult(code, missingCopy); });
  });
  g_listenerAttached = true;
}

// MARK: Follow camera (one shot)

void DisarmFollowTrigger()
{
  if (!g_followArmed)
    return;
  g_followArmed = false;
  [g_followFallbackTimer invalidate];
  g_followFallbackTimer = nil;
  OMNLocationController.shared.firstFixHandler = nil;
}

void EngageFollow()
{
  if (!g_followArmed)
    return;
  DisarmFollowTrigger();
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(kFollowEngageDelaySeconds * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   if (!g_guiding)
                     return;
                   // A plain follow, exactly once, after the renderer has the position. Do NOT toggle
                   // DisableFollowMode first: that flips the session to "route, not following",
                   // which stops route matching entirely (frozen ETA and turns).
                   Rm().FollowRoute();
                 });
}

// IMPORTANT: following the route must run only after the map has its first position. If it runs
// earlier, the first position resets the my-position mode and keeps the current (wide) zoom,
// leaving the navigation camera permanently zoomed out. So: start locations first, then follow on
// the first position, with a timed fallback (later positions recover the camera anyway).
void ArmFollowTrigger()
{
  if (g_followArmed)
    return;
  g_followArmed = true;
  OMNLocationController.shared.firstFixHandler = ^{ EngageFollow(); };
  g_followFallbackTimer = [NSTimer scheduledTimerWithTimeInterval:kFollowFallbackSeconds
                                                          repeats:NO
                                                            block:^(NSTimer *) { EngageFollow(); }];
}

// MARK: Guidance pump

void SpeakPendingNotifications()
{
  auto & rm = Rm();
  // Notifications are only generated while the engine has a notification locale; without one it
  // aborts, so voice is switched on (and the locale set) when guidance starts.
  if (!rm.AreTurnNotificationsEnabled() || !rm.IsRoutingActive())
    return;
  std::vector<std::string> notifications;
  rm.GenerateNotifications(notifications, false /* announceStreets */);
  for (std::string const & text : notifications)
    [OMNSpeaker.shared speak:@(text.c_str())];
}

void PumpGuidance()
{
  if (!g_guiding)
    return;
  routing::FollowingInfo info;
  if (!GetFollowingInfo(info))
    return;
  if (g_guidanceHandler)
    g_guidanceHandler(Serialize(info));
  if (g_voice)
    SpeakPendingNotifications();
}

void StopGuidanceNow()
{
  g_guiding = false;
  DisarmFollowTrigger();
  [g_pumpTimer invalidate];
  g_pumpTimer = nil;
  // Stop all position sources outside guidance. A leftover source keeps feeding positions into the
  // routing session; a position far off a built route triggers a rebuild from there, which can
  // fail and silently REMOVE the route, breaking the next "start navigation" with no route.
  [OMNLocationController.shared stopAll];
  [OMNSpeaker.shared stop];
  if (OMNEngine.isInitialized)
    Rm().DisableFollowMode();
}

/// Route points for the simulated drive, at most `kSimulationStepMeters` apart.
NSArray<NSValue *> * SimulationPoints()
{
  std::vector<geometry::PointWithAltitude> points;
  if (!Rm().RoutingSession().GetRouteJunctionPoints(points) || points.empty())
    return nil;

  std::vector<geometry::PointWithAltitude> dense;
  dense.reserve(points.size());
  dense.push_back(points[0]);
  for (size_t i = 1; i < points.size(); ++i)
  {
    double const dist = ms::DistanceOnEarth(points[i - 1].ToLatLon(), points[i].ToLatLon());
    if (dist > kSimulationStepMeters)
    {
      int const steps = static_cast<int>(dist / kSimulationStepMeters) + 1;
      for (int s = 1; s < steps; ++s)
        dense.push_back(points[i - 1].Interpolate(points[i], static_cast<double>(s) / steps));
    }
    dense.push_back(points[i]);
  }

  NSMutableArray<NSValue *> * result = [NSMutableArray arrayWithCapacity:dense.size()];
  for (auto const & p : dense)
  {
    auto const ll = p.ToLatLon();
    [result addObject:[NSValue valueWithCGPoint:CGPointMake(ll.m_lat, ll.m_lon)]];
  }
  return result;
}
}  // namespace

void OMNNavigationMapDidBecomeReady()
{
  if (!g_refitGate.OnMapReady())
    return;
  // During guidance the follow camera owns the view.
  if (g_guiding || !Rm().IsRouteBuilt())
    return;
  NSLog(@"offline_navigation: route was built before the map was ready: building it again to fit it");
  // The routing listener sees no pending build and ignores the result; the engine zooms the map to
  // the route as it does after any build.
  Rm().BuildRoute();
}

void OMNNavigationMapWasLost()
{
  g_refitGate.OnMapLost();
}

@implementation OMNEngine (Navigation)

+ (OMNEventHandler)guidanceEventHandler
{
  return g_guidanceHandler;
}

+ (void)setGuidanceEventHandler:(OMNEventHandler)handler
{
  g_guidanceHandler = [handler copy];
}

+ (void)buildRouteFrom:(OMNPoint *)start
                    to:(OMNPoint *)destination
                  mode:(OMNTravelMode)mode
            completion:(OMNRouteCompletion)completion
{
  NSError * error = nil;
  if (![self requireReady:&error])
  {
    completion(nil, error);
    return;
  }
  if (g_pendingBuild != nil)
  {
    completion(nil, OMNError(@"build_in_progress", @"Another route build is already in progress"));
    return;
  }
  AttachRoutingListener();
  g_pendingBuild = [completion copy];

  auto & rm = Rm();
  rm.CloseRouting(true /* removeRoutePoints */);
  rm.SetRouter(RouterFor(mode));
  bool const optimize = routing::RoutingOptions::LoadRouteOptimizationFromSettings();
  rm.AddRoutePoint(MakeMark(start, RouteMarkType::Start, @"Start"), optimize);
  rm.AddRoutePoint(MakeMark(destination, RouteMarkType::Finish, @"Destination"), optimize);
  rm.BuildRoute();
}

+ (void)startGuidanceSimulated:(BOOL)simulate voice:(BOOL)voice completion:(OMNCompletion)completion
{
  NSError * error = nil;
  if (![self requireReady:&error])
  {
    completion(error);
    return;
  }
  auto & rm = Rm();
  if (!rm.IsRouteBuilt())
  {
    completion(OMNError(@"no_route", @"No route has been built"));
    return;
  }
  if (!simulate && !OMNLocationController.shared.hasPermission)
  {
    completion(OMNError(@"guidance_start_failed", @"Location permission is not granted"));
    return;
  }

  g_voice = voice;
  // Spoken turn notifications on or off in the engine to match the request.
  rm.EnableTurnNotifications(voice);
  if (voice)
    rm.SetTurnNotificationsLocale(AVSpeechSynthesisVoice.currentLanguageCode.UTF8String);

  // A fixed street-level zoom. Auto-zoom scales the camera to the current speed, which zooms far
  // out during a simulated drive (it runs at an unrealistically even speed). A fixed zoom gives a
  // stable follow camera.
  auto & f = OMNFramework();
  f.SaveAutoZoom(false);
  f.AllowAutoZoom(false);

  ArmFollowTrigger();

  if (simulate)
  {
    NSArray<NSValue *> * points = SimulationPoints();
    if (points == nil)
    {
      DisarmFollowTrigger();
      completion(OMNError(@"no_route_points", @"Could not get route points for simulation"));
      return;
    }
    [OMNLocationController.shared startSimulationWithPoints:points];
  }
  else
  {
    [OMNLocationController.shared startRealUpdates];
  }

  g_guiding = true;
  [g_pumpTimer invalidate];
  g_pumpTimer = [NSTimer scheduledTimerWithTimeInterval:kGuidanceIntervalSeconds
                                                repeats:YES
                                                  block:^(NSTimer *) { PumpGuidance(); }];
  completion(nil);
}

+ (void)stopGuidance
{
  StopGuidanceNow();
}

+ (void)closeRouting
{
  // A build may still be in flight (for example the page was closed while a large region was
  // calculating). Complete it as cancelled so the callback is not orphaned: an orphaned callback
  // would block every later build with "build_in_progress".
  if (g_pendingBuild != nil)
  {
    OMNRouteResult * result = [[OMNRouteResult alloc] init];
    result.ok = NO;
    result.cancelled = YES;
    result.errorCode = 0;
    result.missingMaps = @[];
    result.timeSeconds = 0;
    CompletePendingBuild(result);
  }
  g_refitGate.OnRouteClosed();
  StopGuidanceNow();
  if (self.isInitialized)
  {
    Rm().CloseRouting(true /* removeRoutePoints */);
    Rm().RemoveRoutePoints();
  }
}

+ (void)setViewportLatitude:(double)latitude longitude:(double)longitude zoom:(NSInteger)zoom
{
  if (![self requireReady:nil])
    return;
  OMNFramework().SetViewportCenter(mercator::FromLatLon(latitude, longitude), static_cast<int>(zoom), true /* isAnim */);
}

@end
