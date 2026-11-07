#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The map: a Metal view the engine draws into. `OMNEngine` must be initialized
/// before the view is created. Touches (pan, pinch, rotate, double tap) go straight
/// to the engine.
NS_SWIFT_NAME(EngineMapView)
@interface OMNMapView : UIView

/// Stops drawing and releases the engine's drawing surface. Called automatically
/// when the view is deallocated; call it earlier to free the surface right away.
- (void)teardown;

@end

NS_ASSUME_NONNULL_END
