#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>

#import "OMNInternal.hpp"

#include "geometry/mercator.hpp"

#include "platform/location.hpp"

#include "base/math.hpp"

#include <cmath>

namespace
{
/// One simulated position per second, so the distance between points is also the speed in m/s.
constexpr NSTimeInterval kSimulationIntervalSeconds = 1.0;

location::GpsInfo GpsInfoFromLocation(CLLocation * l)
{
  location::GpsInfo info;
  info.m_source = location::EAppleNative;
  info.m_latitude = l.coordinate.latitude;
  info.m_longitude = l.coordinate.longitude;
  info.m_timestamp = l.timestamp.timeIntervalSince1970;

  if (l.horizontalAccuracy >= 0.0)
    info.m_horizontalAccuracy = l.horizontalAccuracy;

  if (l.verticalAccuracy >= 0.0)
  {
    info.m_verticalAccuracy = l.verticalAccuracy;
    info.m_altitude = l.altitude;
  }

  if (l.course >= 0.0)
    info.m_bearing = l.course;

  if (l.speed >= 0.0)
    info.m_speed = l.speed;
  return info;
}

/// Initial great-circle bearing from `from` to `to`, in degrees clockwise from north.
double BearingDegrees(CLLocationCoordinate2D from, CLLocationCoordinate2D to)
{
  double const lat1 = math::DegToRad(from.latitude);
  double const lat2 = math::DegToRad(to.latitude);
  double const dLon = math::DegToRad(to.longitude - from.longitude);
  double const y = std::sin(dLon) * std::cos(lat2);
  double const x = std::cos(lat1) * std::sin(lat2) - std::sin(lat1) * std::cos(lat2) * std::cos(dLon);
  double const degrees = math::RadToDeg(std::atan2(y, x));
  return std::fmod(degrees + 360.0, 360.0);
}

BOOL IsAuthorized(CLAuthorizationStatus status)
{
  return status == kCLAuthorizationStatusAuthorizedWhenInUse || status == kCLAuthorizationStatusAuthorizedAlways;
}

BOOL HostAllowsBackgroundLocation()
{
  NSArray * modes = [NSBundle.mainBundle objectForInfoDictionaryKey:@"UIBackgroundModes"];
  return [modes containsObject:@"location"];
}
}  // namespace

@interface OMNLocationController () <CLLocationManagerDelegate>
@end

@implementation OMNLocationController
{
  CLLocationManager * _manager;
  NSMutableArray<void (^)(BOOL)> * _permissionCallbacks;

  BOOL _realUpdatesStarted;

  NSTimer * _simulationTimer;
  NSArray<NSValue *> * _simulationPoints;
  NSUInteger _simulationIndex;
  CLLocation * _simulationPrevious;
}

+ (instancetype)shared
{
  static OMNLocationController * instance;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ instance = [[OMNLocationController alloc] init]; });
  return instance;
}

- (instancetype)init
{
  if ((self = [super init]))
  {
    _permissionCallbacks = [NSMutableArray array];
    _manager = [[CLLocationManager alloc] init];
    _manager.delegate = self;
  }
  return self;
}

// MARK: Permission

- (BOOL)hasPermission
{
  return IsAuthorized(_manager.authorizationStatus);
}

- (void)requestPermission:(void (^)(BOOL))completion
{
  CLAuthorizationStatus const status = _manager.authorizationStatus;
  if (status != kCLAuthorizationStatusNotDetermined)
  {
    completion(IsAuthorized(status));
    return;
  }
  [_permissionCallbacks addObject:[completion copy]];
  if (_permissionCallbacks.count == 1)
    [_manager requestWhenInUseAuthorization];
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager
{
  CLAuthorizationStatus const status = manager.authorizationStatus;
  if (status == kCLAuthorizationStatusNotDetermined)
    return;
  NSArray<void (^)(BOOL)> * callbacks = [_permissionCallbacks copy];
  [_permissionCallbacks removeAllObjects];
  for (void (^callback)(BOOL) in callbacks)
    callback(IsAuthorized(status));

  if (_realUpdatesStarted && IsAuthorized(status))
    [self beginRealUpdates];
}

// MARK: Real updates

- (void)startRealUpdates
{
  _realUpdatesStarted = YES;
  if (!self.hasPermission)
    return;  // starts as soon as the permission is granted
  [self beginRealUpdates];
}

- (void)beginRealUpdates
{
  _manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation;
  _manager.distanceFilter = kCLDistanceFilterNone;
  _manager.activityType = CLActivityTypeAutomotiveNavigation;
  _manager.pausesLocationUpdatesAutomatically = NO;
  // Setting this without the matching background mode in the host app's Info.plist raises an
  // exception, so it is only set when the host declared it.
  if (HostAllowsBackgroundLocation())
  {
    _manager.allowsBackgroundLocationUpdates = YES;
    _manager.showsBackgroundLocationIndicator = YES;
  }
  [_manager startUpdatingLocation];
  if (CLLocationManager.headingAvailable)
    [_manager startUpdatingHeading];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations
{
  if (_simulationTimer != nil)
    return;  // a simulated drive owns the position
  CLLocation * l = locations.lastObject;
  if (l == nil)
    return;
  [self deliver:GpsInfoFromLocation(l)];
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
  if (_simulationTimer != nil)
    return;
  OMNFramework().OnLocationError(error.code == kCLErrorDenied ? location::EDenied : location::EUnknown);
}

- (void)locationManager:(CLLocationManager *)manager didUpdateHeading:(CLHeading *)heading
{
  // A negative accuracy means the heading is invalid.
  if (heading == nil || heading.headingAccuracy < 0.0)
    return;
  location::CompassInfo info;
  info.m_bearing = math::DegToRad(heading.trueHeading >= 0.0 ? heading.trueHeading : heading.magneticHeading);
  OMNFramework().OnCompassUpdate(info);
}

// MARK: Simulation

- (BOOL)isSimulating
{
  return _simulationTimer != nil;
}

- (void)startSimulationWithPoints:(NSArray<NSValue *> *)points
{
  [self stopSimulation];
  _simulationPoints = [points copy];
  _simulationIndex = 0;
  _simulationPrevious = nil;
  _simulationTimer = [NSTimer scheduledTimerWithTimeInterval:kSimulationIntervalSeconds
                                                      target:self
                                                    selector:@selector(simulationTick)
                                                    userInfo:nil
                                                     repeats:YES];
  // The first position goes out right away.
  [self simulationTick];
}

- (void)simulationTick
{
  if (_simulationIndex >= _simulationPoints.count)
  {
    [self stopSimulation];  // reached the end of the route
    return;
  }

  CGPoint const p = _simulationPoints[_simulationIndex].CGPointValue;
  CLLocationCoordinate2D const coordinate = CLLocationCoordinate2DMake(p.x, p.y);
  location::GpsInfo info;
  info.m_source = location::EAppleNative;
  info.m_latitude = coordinate.latitude;
  info.m_longitude = coordinate.longitude;
  info.m_timestamp = NSDate.date.timeIntervalSince1970;
  info.m_horizontalAccuracy = 1.0;

  CLLocation * current = [[CLLocation alloc] initWithLatitude:coordinate.latitude longitude:coordinate.longitude];
  if (_simulationPrevious != nil)
  {
    info.m_speed = [_simulationPrevious distanceFromLocation:current] / kSimulationIntervalSeconds;
    info.m_bearing = BearingDegrees(_simulationPrevious.coordinate, coordinate);
  }
  _simulationPrevious = current;
  _simulationIndex += 1;
  [self deliver:info];
}

- (void)stopSimulation
{
  [_simulationTimer invalidate];
  _simulationTimer = nil;
  _simulationPoints = nil;
}

// MARK: Common

- (void)deliver:(location::GpsInfo const &)info
{
  OMNFramework().OnLocationUpdate(info);
  void (^handler)(void) = self.firstFixHandler;
  if (handler)
  {
    self.firstFixHandler = nil;
    handler();
  }
}

- (void)stopAll
{
  _realUpdatesStarted = NO;
  [self stopSimulation];
  [_manager stopUpdatingLocation];
  [_manager stopUpdatingHeading];
  self.firstFixHandler = nil;
}

@end
