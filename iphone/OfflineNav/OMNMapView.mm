#import "OMNMapView.h"

#import <MetalKit/MetalKit.h>

#import "OMNInternal.hpp"
#import "OMNMetalContextFactory.h"

#include "drape/drape_global.hpp"
#include "drape/pointers.hpp"
#include "drape_frontend/user_event_stream.hpp"
#include "drape_frontend/visual_params.hpp"

#include "base/logging.hpp"

// The engine has one drawing engine, so one view owns it at a time. A new view takes over from an
// older one that is still alive (Flutter can create a page's map before the previous page's map is
// released), and an older view's teardown must then leave the engine alone.
static __weak OMNMapView * g_activeView = nil;

BOOL OMNMapHasDrawingEngine()
{
  return g_activeView != nil;
}

@implementation OMNMapView
{
  drape_ptr<dp::GraphicsContextFactory> m_factory;
  // Do not call OnSize from layoutSubviews when the real size did not change.
  CGRect m_lastViewSize;
  BOOL m_drapeEngineCreated;
}

+ (Class)layerClass
{
  return [CAMetalLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if ((self = [super initWithFrame:frame]))
  {
    m_lastViewSize = CGRectZero;
    self.multipleTouchEnabled = YES;
    // Correct retina display support in the drawable.
    self.contentScaleFactor = UIScreen.mainScreen.nativeScale;

    CAMetalLayer * layer = (CAMetalLayer *)self.layer;
    layer.device = MTLCreateSystemDefaultDevice();
    NSAssert(layer.device != nil, @"Metal is not supported on this device");
    layer.opaque = YES;

  }
  return self;
}

- (void)dealloc
{
  [self teardown];
}

- (CGSize)pixelSize
{
  CGSize const s = self.bounds.size;
  return CGSizeMake(s.width * self.contentScaleFactor, s.height * self.contentScaleFactor);
}

- (void)createDrapeEngine
{
  OMNMapView * previous = g_activeView;
  if (previous != nil && previous != self)
    [previous teardown];
  g_activeView = self;
  // A new view has no drawing engine until its layer has a size.
  [OMNEngine mapWasLost];

  // The engine reports once its drawing context is up; from then on it can take camera commands.
  __weak OMNMapView * weakSelf = self;
  OMNFramework().SetGraphicsContextInitializationHandler([weakSelf]()
  {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (weakSelf != nil && g_activeView == weakSelf)
        [OMNEngine mapDidBecomeReady];
    });
  });

  CGSize const pixels = [self pixelSize];
  m2::PointU const size(static_cast<uint32_t>(pixels.width), static_cast<uint32_t>(pixels.height));
  m_factory = make_unique_dp<OMNMetalContextFactory>((CAMetalLayer *)self.layer, size);

  LOG(LINFO, ("CreateDrapeEngine started", size.x, size.y));
  Framework::DrapeCreationParams p;
  p.m_apiVersion = dp::ApiVersion::Metal;
  p.m_surfaceWidth = static_cast<int>(size.x);
  p.m_surfaceHeight = static_cast<int>(size.y);
  p.m_visualScale = df::CSF2VS(self.contentScaleFactor);
  p.m_hints.m_isFirstLaunch = false;
  p.m_hints.m_isLaunchByDeepLink = false;
  OMNFramework().CreateDrapeEngine(make_ref(m_factory), std::move(p));
  m_drapeEngineCreated = YES;
  LOG(LINFO, ("CreateDrapeEngine finished"));
  OMNNavigationMapDrawingEngineCreated();
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  // Nothing to draw into before the engine is up; the next layout pass creates the drawing engine.
  if (!OMNEngine.isInitialized)
    return;
  if (CGRectEqualToRect(m_lastViewSize, self.frame) || CGRectIsEmpty(self.bounds))
    return;
  m_lastViewSize = self.frame;

  if (!m_drapeEngineCreated)
  {
    [self createDrapeEngine];
    return;
  }
  CGSize const pixels = [self pixelSize];
  OMNFramework().OnSize(static_cast<int>(pixels.width), static_cast<int>(pixels.height));
}

- (void)teardown
{
  if (!m_drapeEngineCreated)
    return;
  m_drapeEngineCreated = NO;
  if (g_activeView == self)
  {
    g_activeView = nil;
    auto & f = OMNFramework();
    f.SetGraphicsContextInitializationHandler({});
    f.PrepareToShutdown();  // destroys the drawing engine
    [OMNEngine mapWasLost];
  }
  m_factory.reset();
}

// MARK: Touches

- (void)checkMaskedPointer:(UITouch *)touch withEvent:(df::TouchEvent &)e
{
  int64_t const id = reinterpret_cast<int64_t>(touch);
  int8_t pointerIndex = df::TouchEvent::INVALID_MASKED_POINTER;
  if (e.GetFirstTouch().m_id == id)
    pointerIndex = 0;
  else if (e.GetSecondTouch().m_id == id)
    pointerIndex = 1;

  if (e.GetFirstMaskedPointer() == df::TouchEvent::INVALID_MASKED_POINTER)
    e.SetFirstMaskedPointer(pointerIndex);
  else
    e.SetSecondMaskedPointer(pointerIndex);
}

- (void)sendTouchType:(df::TouchEvent::ETouchType)type withTouches:(NSSet *)touches andEvent:(UIEvent *)event
{
  if (!m_drapeEngineCreated)
    return;

  NSArray * allTouches = [[event allTouches] allObjects];
  if ([allTouches count] < 1)
    return;

  CGFloat const scaleFactor = self.contentScaleFactor;
  BOOL const hasForceTouch = self.traitCollection.forceTouchCapability == UIForceTouchCapabilityAvailable;

  df::TouchEvent e;
  UITouch * touch = [allTouches objectAtIndex:0];
  CGPoint const pt = [touch locationInView:self];
  e.SetTouchType(type);

  df::Touch t0;
  t0.m_location = m2::PointD(pt.x * scaleFactor, pt.y * scaleFactor);
  t0.m_id = reinterpret_cast<int64_t>(touch);
  if (hasForceTouch)
    t0.m_force = touch.force / touch.maximumPossibleForce;
  e.SetFirstTouch(t0);

  if (allTouches.count > 1)
  {
    UITouch * second = [allTouches objectAtIndex:1];
    CGPoint const pt1 = [second locationInView:self];
    df::Touch t1;
    t1.m_location = m2::PointD(pt1.x * scaleFactor, pt1.y * scaleFactor);
    t1.m_id = reinterpret_cast<int64_t>(second);
    if (hasForceTouch)
      t1.m_force = second.force / second.maximumPossibleForce;
    e.SetSecondTouch(t1);
  }

  NSArray * toggledTouches = [touches allObjects];
  if (toggledTouches.count > 0)
    [self checkMaskedPointer:[toggledTouches objectAtIndex:0] withEvent:e];
  if (toggledTouches.count > 1)
    [self checkMaskedPointer:[toggledTouches objectAtIndex:1] withEvent:e];

  OMNFramework().TouchEvent(e);
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
  [self sendTouchType:df::TouchEvent::TOUCH_DOWN withTouches:touches andEvent:event];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
  [self sendTouchType:df::TouchEvent::TOUCH_MOVE withTouches:nil andEvent:event];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
  [self sendTouchType:df::TouchEvent::TOUCH_UP withTouches:touches andEvent:event];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
  [self sendTouchType:df::TouchEvent::TOUCH_CANCEL withTouches:touches andEvent:event];
}

@end
