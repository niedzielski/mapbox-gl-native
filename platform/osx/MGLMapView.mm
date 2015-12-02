#import "MGLMapView_Private.h"
#import "MGLAccountManager_Private.h"
#import "MGLAttributionButton.h"
#import "MGLCompassCell.h"
#import "MGLOpenGLLayer.h"
#import "MGLStyle.h"

#import "../darwin/MGLGeometry_Private.h"
#import "../darwin/MGLMultiPoint_Private.h"

#import <mbgl/darwin/MGLPolygon.h>
#import <mbgl/darwin/MGLPolyline.h>
#import <mbgl/osx/MGLAnnotationImage.h>
#import <mbgl/osx/MGLMapViewDelegate.h>

#import <mbgl/mbgl.hpp>
#import <mbgl/annotation/point_annotation.hpp>
#import <mbgl/map/camera.hpp>
#import <mbgl/platform/darwin/reachability.h>
#import <mbgl/platform/gl.hpp>
#import <mbgl/sprite/sprite_image.hpp>
#import <mbgl/storage/default_file_source.hpp>
#import <mbgl/storage/network_status.hpp>
#import <mbgl/storage/sqlite_cache.hpp>
#import <mbgl/util/constants.hpp>
#import <mbgl/util/math.hpp>
#import <mbgl/util/std.hpp>

#import <map>
#import <unordered_set>

#import "NSBundle+MGLAdditions.h"
#import "NSProcessInfo+MGLAdditions.h"
#import "../darwin/NSException+MGLAdditions.h"
#import "../darwin/NSString+MGLAdditions.h"

#import <QuartzCore/QuartzCore.h>

class MGLMapViewImpl;
class MGLAnnotationContext;

/// Distance from the edge of the view to ornament views (logo, attribution, etc.).
const CGFloat MGLOrnamentPadding = 12;

/// Alpha value of the ornament views (logo, attribution, etc.).
const CGFloat MGLOrnamentOpacity = 0.9;

/// Default duration for programmatic animations.
const NSTimeInterval MGLAnimationDuration = 0.3;

/// Distance in points that a single press of the panning keyboard shortcut pans the map by.
const CGFloat MGLKeyPanningIncrement = 150;

/// Degrees that a single press of the rotation keyboard shortcut rotates the map by.
const CLLocationDegrees MGLKeyRotationIncrement = 25;

/// Reuse identifier and file name of the default point annotation image.
static NSString * const MGLDefaultStyleMarkerSymbolName = @"default_marker";

/// Prefix that denotes a sprite installed by MGLMapView, to avoid collisions
/// with style-defined sprites.
static NSString * const MGLAnnotationSpritePrefix = @"com.mapbox.sprites.";

/// Slop area around the hit testing point, allowing for imprecise annotation selection.
const CGFloat MGLAnnotationImagePaddingForHitTest = 4;

/// Distance from the callout’s anchor point to the annotation it points to.
const CGFloat MGLAnnotationImagePaddingForCallout = 4;

/// Copyright notices displayed in the attribution view.
struct MGLAttribution {
    /// Attribution button label text. A copyright symbol is prepended to this string.
    NSString *title;
    /// URL to open when the attribution button is clicked.
    NSString *urlString;
} MGLAttributions[] = {
    { @"Mapbox", @"https://www.mapbox.com/about/maps/" },
    { @"OpenStreetMap", @"http://www.openstreetmap.org/about/" },
};

/// Unique identifier representing a single annotation in mbgl.
typedef uint32_t MGLAnnotationID;

/// An indication that the requested annotation was not found or is nonexistent.
enum { MGLAnnotationNotFound = UINT32_MAX };

/// Mapping from an annotation’s unique identifier to metadata about that
/// annotation, including the annotation itself.
typedef std::map<MGLAnnotationID, MGLAnnotationContext> MGLAnnotationContextMap;

/// Returns an NSImage for the default marker image.
NSImage *MGLDefaultMarkerImage() {
    NSString *path = [[NSBundle mgl_frameworkBundle] pathForResource:MGLDefaultStyleMarkerSymbolName
                                                             ofType:@"pdf"];
    return [[NSImage alloc] initWithContentsOfFile:path];
}

/// Converts from a duration in seconds to a duration object usable in mbgl.
std::chrono::steady_clock::duration MGLDurationInSeconds(NSTimeInterval duration) {
    return std::chrono::duration_cast<std::chrono::steady_clock::duration>(
        std::chrono::duration<NSTimeInterval, std::chrono::seconds::period>(duration));
}

/// Converts the given color into an mbgl::Color in calibrated RGB space.
mbgl::Color MGLColorObjectFromNSColor(NSColor *color) {
    if (!color) {
        return {{ 0, 0, 0, 0 }};
    }
    CGFloat r, g, b, a;
    [[color colorUsingColorSpaceName:NSCalibratedRGBColorSpace] getRed:&r green:&g blue:&b alpha:&a];
    return {{ (float)r, (float)g, (float)b, (float)a }};
}

/// Lightweight container for metadata about an annotation, including the annotation itself.
class MGLAnnotationContext {
public:
    id <MGLAnnotation> annotation;
    /// mbgl-given identifier for the annotation image used by this annotation.
    /// Based on the annotation image’s reusable identifier.
    NSString *symbolIdentifier;
};

@interface MGLMapView () <NSPopoverDelegate, MGLMultiPointDelegate>

@property (nonatomic, readwrite) NSSegmentedControl *zoomControls;
@property (nonatomic, readwrite) NSSlider *compass;
@property (nonatomic, readwrite) NSImageView *logoView;
@property (nonatomic, readwrite) NSView *attributionView;

/// Mapping from reusable identifiers to annotation images.
@property (nonatomic) NS_MUTABLE_DICTIONARY_OF(NSString *, MGLAnnotationImage *) *annotationImagesByIdentifier;
/// Currently shown popover representing the selected annotation.
@property (nonatomic) NSPopover *calloutForSelectedAnnotation;

@property (nonatomic, readwrite, getter=isDormant) BOOL dormant;

@end

@implementation MGLMapView {
    /// Cross-platform map view controller.
    mbgl::Map *_mbglMap;
    /// Adapter responsible for bridging calls from mbgl to MGLMapView and Cocoa.
    MGLMapViewImpl *_mbglView;
    std::shared_ptr<mbgl::SQLiteCache> _mbglFileCache;
    mbgl::DefaultFileSource *_mbglFileSource;
    
    NSPanGestureRecognizer *_panGestureRecognizer;
    NSMagnificationGestureRecognizer *_magnificationGestureRecognizer;
    NSRotationGestureRecognizer *_rotationGestureRecognizer;
    double _scaleAtBeginningOfGesture;
    CLLocationDirection _directionAtBeginningOfGesture;
    CGFloat _pitchAtBeginningOfGesture;
    
    MGLAnnotationContextMap _annotationContextsByAnnotationID;
    MGLAnnotationID _selectedAnnotationID;
    MGLAnnotationID _lastSelectedAnnotationID;
    /// Size of the rectangle formed by unioning the maximum slop area around every annotation image.
    NSSize _unionedAnnotationImageSize;
    std::vector<MGLAnnotationID> _annotationsNearbyLastClick;
    /// True if any annotations that have tooltips have been installed.
    BOOL _wantsToolTipRects;
    /// True if any annotation images that have custom cursors have been installed.
    BOOL _wantsCursorRects;
    
    // Cached checks for delegate method implementations
    
    BOOL _delegateHasAlphasForShapeAnnotations;
    BOOL _delegateHasStrokeColorsForShapeAnnotations;
    BOOL _delegateHasFillColorsForShapeAnnotations;
    BOOL _delegateHasLineWidthsForShapeAnnotations;
    
    /// True if the current process is the Interface Builder designable
    /// renderer. When drawing the designable, the map is paused, so any call to
    /// it may hang the process.
    BOOL _isTargetingInterfaceBuilder;
    CLLocationDegrees _pendingLatitude;
    CLLocationDegrees _pendingLongitude;
}

#pragma mark Lifecycle

- (instancetype)initWithFrame:(NSRect)frameRect {
    if (self = [super initWithFrame:frameRect]) {
        [self commonInit];
        self.styleURL = nil;
    }
    return self;
}

- (instancetype)initWithFrame:(CGRect)frame styleURL:(nullable NSURL *)styleURL {
    if (self = [super initWithFrame:frame]) {
        [self commonInit];
        self.styleURL = styleURL;
    }
    return self;
}

- (instancetype)initWithCoder:(nonnull NSCoder *)decoder {
    if (self = [super initWithCoder:decoder]) {
        [self commonInit];
    }
    return self;
}

- (void)awakeFromNib {
    [super awakeFromNib];
    
    self.styleURL = nil;
}

+ (NSArray *)restorableStateKeyPaths {
    return @[@"zoomLevel", @"direction"];
}

- (void)commonInit {
    _isTargetingInterfaceBuilder = NSProcessInfo.processInfo.mgl_isInterfaceBuilderDesignablesAgent;
    
    // Set up cross-platform controllers and resources.
    _mbglView = new MGLMapViewImpl(self, [NSScreen mainScreen].backingScaleFactor);
    
    // Place the cache in a location that can be shared among all the
    // applications that embed the Mapbox OS X SDK.
    NSURL *cacheDirectoryURL = [[NSFileManager defaultManager] URLForDirectory:NSCachesDirectory
                                                                      inDomain:NSUserDomainMask
                                                             appropriateForURL:nil
                                                                        create:YES
                                                                         error:nil];
    cacheDirectoryURL = [cacheDirectoryURL URLByAppendingPathComponent:
                         [[NSBundle mgl_frameworkBundle] bundleIdentifier]];
    [[NSFileManager defaultManager] createDirectoryAtURL:cacheDirectoryURL
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    NSURL *cacheURL = [cacheDirectoryURL URLByAppendingPathComponent:@"cache.db"];
    NSString *cachePath = cacheURL ? cacheURL.path : @"";
    _mbglFileCache = mbgl::SharedSQLiteCache::get(cachePath.UTF8String);
    _mbglFileSource = new mbgl::DefaultFileSource(_mbglFileCache.get());
    
    _mbglMap = new mbgl::Map(*_mbglView, *_mbglFileSource, mbgl::MapMode::Continuous);
    
    // Install the OpenGL layer. Interface Builder’s synchronous drawing means
    // we can’t display a map, so don’t even bother to have a map layer.
    self.layer = _isTargetingInterfaceBuilder ? [CALayer layer] : [MGLOpenGLLayer layer];
    
    // Observe for changes to the global access token (and find out the current one).
    [[MGLAccountManager sharedManager] addObserver:self
                                        forKeyPath:@"accessToken"
                                           options:(NSKeyValueObservingOptionInitial |
                                                    NSKeyValueObservingOptionNew)
                                           context:NULL];
    
    // Notify map object when network reachability status changes.
    MGLReachability *reachability = [MGLReachability reachabilityForInternetConnection];
    reachability.reachableBlock = ^(MGLReachability *) {
        mbgl::NetworkStatus::Reachable();
    };
    [reachability startNotifier];
    
    // Install ornaments and gesture recognizers.
    [self installZoomControls];
    [self installCompass];
    [self installLogoView];
    [self installAttributionView];
    [self installGestureRecognizers];
    
    // Set up annotation management and selection state.
    _annotationImagesByIdentifier = [NSMutableDictionary dictionary];
    _annotationContextsByAnnotationID = {};
    _selectedAnnotationID = MGLAnnotationNotFound;
    _lastSelectedAnnotationID = MGLAnnotationNotFound;
    _annotationsNearbyLastClick = {};
    
    // Jump to Null Island initially.
    mbgl::CameraOptions options;
    options.center = mbgl::LatLng(0, 0);
    options.zoom = _mbglMap->getMinZoom();
    _mbglMap->jumpTo(options);
}

/// Adds zoom controls to the lower-right corner.
- (void)installZoomControls {
    _zoomControls = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
    _zoomControls.wantsLayer = YES;
    _zoomControls.layer.opacity = MGLOrnamentOpacity;
    [(NSSegmentedCell *)_zoomControls.cell setTrackingMode:NSSegmentSwitchTrackingMomentary];
    _zoomControls.continuous = YES;
    _zoomControls.segmentCount = 2;
    [_zoomControls setLabel:@"−" forSegment:0]; // U+2212 MINUS SIGN
    [(NSSegmentedCell *)_zoomControls.cell setTag:0 forSegment:0];
    [(NSSegmentedCell *)_zoomControls.cell setToolTip:@"Zoom Out" forSegment:0];
    [_zoomControls setLabel:@"+" forSegment:1];
    [(NSSegmentedCell *)_zoomControls.cell setTag:1 forSegment:1];
    [(NSSegmentedCell *)_zoomControls.cell setToolTip:@"Zoom In" forSegment:1];
    _zoomControls.target = self;
    _zoomControls.action = @selector(zoomInOrOut:);
    _zoomControls.controlSize = NSRegularControlSize;
    [_zoomControls sizeToFit];
    _zoomControls.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_zoomControls];
}

/// Adds a rudimentary compass control to the lower-right corner.
- (void)installCompass {
    _compass = [[NSSlider alloc] initWithFrame:NSZeroRect];
    _compass.wantsLayer = YES;
    _compass.layer.opacity = MGLOrnamentOpacity;
    _compass.cell = [[MGLCompassCell alloc] init];
    _compass.continuous = YES;
    _compass.target = self;
    _compass.action = @selector(rotate:);
    [_compass sizeToFit];
    _compass.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_compass];
}

/// Adds a Mapbox logo to the lower-left corner.
- (void)installLogoView {
    _logoView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _logoView.wantsLayer = YES;
    NSImage *logoImage = [[NSImage alloc] initWithContentsOfFile:
                          [[NSBundle mgl_frameworkBundle] pathForResource:@"mapbox" ofType:@"pdf"]];
    // Account for the image’s built-in padding when aligning other controls to the logo.
    logoImage.alignmentRect = NSInsetRect(logoImage.alignmentRect, 3, 3);
    _logoView.image = logoImage;
    _logoView.translatesAutoresizingMaskIntoConstraints = NO;
    _logoView.accessibilityTitle = @"Mapbox";
    [self addSubview:_logoView];
}

/// Adds legally required map attribution to the lower-left corner.
- (void)installAttributionView {
    _attributionView = [[NSView alloc] initWithFrame:NSZeroRect];
    _attributionView.wantsLayer = YES;
    
    // Make the background and foreground translucent to be unobtrusive.
    _attributionView.layer.opacity = 0.6;
    
    // Blur the background to prevent text underneath the view from running into
    // the text in the view, rendering it illegible.
    CIFilter *attributionBlurFilter = [CIFilter filterWithName:@"CIGaussianBlur"];
    [attributionBlurFilter setDefaults];
    
    // Brighten the background. This is similar to applying a translucent white
    // background on the view, but the effect is a bit more subtle and works
    // well with the blur above.
    CIFilter *attributionColorFilter = [CIFilter filterWithName:@"CIColorControls"];
    [attributionColorFilter setDefaults];
    [attributionColorFilter setValue:@(0.1) forKey:kCIInputBrightnessKey];
    
    // Apply the background effects and a standard button corner radius.
    _attributionView.backgroundFilters = @[attributionColorFilter, attributionBlurFilter];
    _attributionView.layer.cornerRadius = 4;
    
    _attributionView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_attributionView];
    [self updateAttributionView];
}

/// Adds gesture recognizers for manipulating the viewport and selecting annotations.
- (void)installGestureRecognizers {
    self.acceptsTouchEvents = YES;
    _scrollEnabled = YES;
    _zoomEnabled = YES;
    _rotateEnabled = YES;
    _pitchEnabled = YES;
    
    _panGestureRecognizer = [[NSPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanGesture:)];
    _panGestureRecognizer.delaysKeyEvents = YES;
    [self addGestureRecognizer:_panGestureRecognizer];
    
    NSClickGestureRecognizer *clickGestureRecognizer = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(handleClickGesture:)];
    clickGestureRecognizer.delaysPrimaryMouseButtonEvents = NO;
    [self addGestureRecognizer:clickGestureRecognizer];
    
    NSClickGestureRecognizer *secondaryClickGestureRecognizer = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(handleSecondaryClickGesture:)];
    secondaryClickGestureRecognizer.buttonMask = 0x2;
    [self addGestureRecognizer:secondaryClickGestureRecognizer];
    
    NSClickGestureRecognizer *doubleClickGestureRecognizer = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleClickGesture:)];
    doubleClickGestureRecognizer.numberOfClicksRequired = 2;
    doubleClickGestureRecognizer.delaysPrimaryMouseButtonEvents = NO;
    [self addGestureRecognizer:doubleClickGestureRecognizer];
    
    _magnificationGestureRecognizer = [[NSMagnificationGestureRecognizer alloc] initWithTarget:self action:@selector(handleMagnificationGesture:)];
    [self addGestureRecognizer:_magnificationGestureRecognizer];
    
    _rotationGestureRecognizer = [[NSRotationGestureRecognizer alloc] initWithTarget:self action:@selector(handleRotationGesture:)];
    [self addGestureRecognizer:_rotationGestureRecognizer];
}

/// Updates the attribution view to reflect the sources used. For now, this is
/// hard-coded to the standard Mapbox and OpenStreetMap attribution.
- (void)updateAttributionView {
    self.attributionView.subviews = @[];
    
    for (NSUInteger i = 0; i < sizeof(MGLAttributions) / sizeof(MGLAttributions[0]); i++) {
        // For each attribution, add a borderless button that responds to clicks
        // and feels like a hyperlink.
        NSURL *url = [NSURL URLWithString:MGLAttributions[i].urlString];
        NSButton *button = [[MGLAttributionButton alloc] initWithTitle:MGLAttributions[i].title URL:url];
        button.controlSize = NSMiniControlSize;
        button.translatesAutoresizingMaskIntoConstraints = NO;
        
        // Set the new button flush with the buttom of the container and to the
        // right of the previous button, with standard spacing. If there is no
        // previous button, align to the container instead.
        NSView *previousView = self.attributionView.subviews.lastObject;
        [self.attributionView addSubview:button];
        [_attributionView addConstraint:
         [NSLayoutConstraint constraintWithItem:button
                                      attribute:NSLayoutAttributeBottom
                                      relatedBy:NSLayoutRelationEqual
                                         toItem:_attributionView
                                      attribute:NSLayoutAttributeBottom
                                     multiplier:1
                                       constant:0]];
        [_attributionView addConstraint:
         [NSLayoutConstraint constraintWithItem:button
                                      attribute:NSLayoutAttributeLeading
                                      relatedBy:NSLayoutRelationEqual
                                         toItem:previousView ? previousView : _attributionView
                                      attribute:previousView ? NSLayoutAttributeTrailing : NSLayoutAttributeLeading
                                     multiplier:1
                                       constant:8]];
    }
}

- (void)dealloc {
    [[MGLAccountManager sharedManager] removeObserver:self forKeyPath:@"accessToken"];
    
    // Close any annotation callout immediately.
    [self.calloutForSelectedAnnotation close];
    self.calloutForSelectedAnnotation = nil;
    
    if (_mbglMap) {
        delete _mbglMap;
        _mbglMap = nullptr;
    }
    if (_mbglFileSource) {
        delete _mbglFileSource;
        _mbglFileSource = nullptr;
    }
    if (_mbglView) {
        delete _mbglView;
        _mbglView = nullptr;
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(__unused void *)context {
    // Synchronize mbgl::Map’s access token with the global one in MGLAccountManager.
    if ([keyPath isEqualToString:@"accessToken"] && object == [MGLAccountManager sharedManager]) {
        NSString *accessToken = change[NSKeyValueChangeNewKey];
        if (![accessToken isKindOfClass:[NSNull class]]) {
            _mbglFileSource->setAccessToken((std::string)accessToken.UTF8String);
        }
    }
}

- (void)setDelegate:(id<MGLMapViewDelegate>)delegate {
    _delegate = delegate;
    
    // Cache checks for delegate method implementations that may be called in a
    // hot loop, namely the annotation style methods.
    _delegateHasAlphasForShapeAnnotations = [_delegate respondsToSelector:@selector(mapView:alphaForShapeAnnotation:)];
    _delegateHasStrokeColorsForShapeAnnotations = [_delegate respondsToSelector:@selector(mapView:strokeColorForShapeAnnotation:)];
    _delegateHasFillColorsForShapeAnnotations = [_delegate respondsToSelector:@selector(mapView:fillColorForPolygonAnnotation:)];
    _delegateHasLineWidthsForShapeAnnotations = [_delegate respondsToSelector:@selector(mapView:lineWidthForPolylineAnnotation:)];
}

#pragma mark Style

- (nonnull NSURL *)styleURL {
    NSString *styleURLString = @(_mbglMap->getStyleURL().c_str()).mgl_stringOrNilIfEmpty;
    return styleURLString ? [NSURL URLWithString:styleURLString] : [MGLStyle streetsStyleURL];
}

- (void)setStyleURL:(nullable NSURL *)styleURL {
    if (_isTargetingInterfaceBuilder) {
        return;
    }
    
    // Default to Streets.
    if (!styleURL) {
        // An access token is required to load any default style, including
        // Streets.
        if (![MGLAccountManager accessToken]) {
            return;
        }
        styleURL = [MGLStyle streetsStyleURL];
    }
    
    if (![styleURL scheme]) {
        // Assume a relative path into the application’s resource folder,
        // defined in mbgl::platform::assetRoot().
        styleURL = [NSURL URLWithString:[@"asset://" stringByAppendingString:styleURL.absoluteString]];
    }
    
    _mbglMap->setStyleURL(styleURL.absoluteString.UTF8String);
}

- (IBAction)reloadStyle:(__unused id)sender {
    NSURL *styleURL = self.styleURL;
    _mbglMap->setStyleURL("");
    self.styleURL = styleURL;
}

#pragma mark View hierarchy and drawing

- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    [self deselectAnnotation:self.selectedAnnotation animated:NO];
    if (!self.dormant && !newWindow) {
        self.dormant = YES;
        _mbglMap->pause();
    }
}

- (void)viewDidMoveToWindow {
    if (self.dormant && self.window) {
        _mbglMap->resume();
        self.dormant = NO;
    }
}

- (BOOL)wantsLayer {
    return YES;
}

- (BOOL)wantsBestResolutionOpenGLSurface {
    // Use an OpenGL layer, except when drawing the designable, which is just
    // ordinary Cocoa.
    return !_isTargetingInterfaceBuilder;
}

- (void)setFrame:(NSRect)frame {
    super.frame = frame;
    if (!_isTargetingInterfaceBuilder) {
        _mbglMap->update(mbgl::Update::Dimensions);
    }
}

- (void)updateConstraints {
    // Place the zoom controls at the lower-right corner of the view.
    [self addConstraint:
     [NSLayoutConstraint constraintWithItem:self
                                  attribute:NSLayoutAttributeBottom
                                  relatedBy:NSLayoutRelationEqual
                                     toItem:_zoomControls
                                  attribute:NSLayoutAttributeBottom
                                 multiplier:1
                                   constant:MGLOrnamentPadding]];
    [self addConstraint:
     [NSLayoutConstraint constraintWithItem:self
                                  attribute:NSLayoutAttributeTrailing
                                  relatedBy:NSLayoutRelationEqual
                                     toItem:_zoomControls
                                  attribute:NSLayoutAttributeTrailing
                                 multiplier:1
                                   constant:MGLOrnamentPadding]];
    
    // Center the compass above the zoom controls, assuming that the compass is
    // narrower than the zoom controls.
    [self addConstraint:
     [NSLayoutConstraint constraintWithItem:_compass
                                  attribute:NSLayoutAttributeCenterX
                                  relatedBy:NSLayoutRelationEqual
                                     toItem:_zoomControls
                                  attribute:NSLayoutAttributeCenterX
                                 multiplier:1
                                   constant:0]];
    [self addConstraint:
     [NSLayoutConstraint constraintWithItem:_zoomControls
                                  attribute:NSLayoutAttributeTop
                                  relatedBy:NSLayoutRelationEqual
                                     toItem:_compass
                                  attribute:NSLayoutAttributeBottom
                                 multiplier:1
                                   constant:8]];
    
    // Place the logo view in the lower-left corner of the view, accounting for
    // the logo’s alignment rect.
    [self addConstraint:
     [NSLayoutConstraint constraintWithItem:self
                                  attribute:NSLayoutAttributeBottom
                                  relatedBy:NSLayoutRelationEqual
                                     toItem:_logoView
                                  attribute:NSLayoutAttributeBottom
                                 multiplier:1
                                   constant:MGLOrnamentPadding - _logoView.image.alignmentRect.origin.y]];
    [self addConstraint:
     [NSLayoutConstraint constraintWithItem:_logoView
                                  attribute:NSLayoutAttributeLeading
                                  relatedBy:NSLayoutRelationEqual
                                     toItem:self
                                  attribute:NSLayoutAttributeLeading
                                 multiplier:1
                                   constant:MGLOrnamentPadding - _logoView.image.alignmentRect.origin.x]];
    
    // Place the attribution view to the right of the logo view and size it to
    // fit the buttons inside.
    [self addConstraint:[NSLayoutConstraint constraintWithItem:_logoView
                                                     attribute:NSLayoutAttributeBaseline
                                                     relatedBy:NSLayoutRelationEqual
                                                        toItem:_attributionView
                                                     attribute:NSLayoutAttributeBaseline
                                                    multiplier:1
                                                      constant:_logoView.image.alignmentRect.origin.y]];
    [self addConstraint:[NSLayoutConstraint constraintWithItem:_attributionView
                                                     attribute:NSLayoutAttributeLeading
                                                     relatedBy:NSLayoutRelationEqual
                                                        toItem:_logoView
                                                     attribute:NSLayoutAttributeTrailing
                                                    multiplier:1
                                                      constant:8]];
    [self addConstraint:[NSLayoutConstraint constraintWithItem:_attributionView.subviews.firstObject
                                                     attribute:NSLayoutAttributeTop
                                                     relatedBy:NSLayoutRelationEqual
                                                        toItem:_attributionView
                                                     attribute:NSLayoutAttributeTop
                                                    multiplier:1
                                                      constant:0]];
    [self addConstraint:[NSLayoutConstraint constraintWithItem:_attributionView
                                                     attribute:NSLayoutAttributeTrailing
                                                     relatedBy:NSLayoutRelationEqual
                                                        toItem:_attributionView.subviews.lastObject
                                                     attribute:NSLayoutAttributeTrailing
                                                    multiplier:1
                                                      constant:8]];
    
    [super updateConstraints];
}

- (void)renderSync {
    if (!self.dormant) {
        CGFloat zoomFactor   = _mbglMap->getMaxZoom() - _mbglMap->getMinZoom() + 1;
        CGFloat cpuFactor    = (CGFloat)[NSProcessInfo processInfo].processorCount;
        CGFloat memoryFactor = (CGFloat)[NSProcessInfo processInfo].physicalMemory / 1000 / 1000 / 1000;
        CGFloat sizeFactor   = ((CGFloat)_mbglMap->getWidth() / mbgl::util::tileSize) * ((CGFloat)_mbglMap->getHeight() / mbgl::util::tileSize);
        
        NSUInteger cacheSize = zoomFactor * cpuFactor * memoryFactor * sizeFactor * 0.5;
        
        _mbglMap->setSourceTileCacheSize(cacheSize);
        _mbglMap->renderSync();
        
//        [self updateUserLocationAnnotationView];
    }
}

- (void)invalidate {
    MGLAssertIsMainThread();
    
    [self.layer setNeedsDisplay];
}

- (void)notifyMapChange:(mbgl::MapChange)change {
    // Ignore map updates when the Map object isn't set.
    if (!_mbglMap) {
        return;
    }
    
    switch (change) {
        case mbgl::MapChangeRegionWillChange:
        case mbgl::MapChangeRegionWillChangeAnimated:
        {
            if ([self.delegate respondsToSelector:@selector(mapView:regionWillChangeAnimated:)]) {
                BOOL animated = change == mbgl::MapChangeRegionWillChangeAnimated;
                [self.delegate mapView:self regionWillChangeAnimated:animated];
            }
            break;
        }
        case mbgl::MapChangeRegionIsChanging:
        {
            // Update a minimum of UI that needs to stay attached to the map
            // while animating.
            [self updateCompass];
            [self updateAnnotationCallouts];
            
            if ([self.delegate respondsToSelector:@selector(mapViewRegionIsChanging:)]) {
                [self.delegate mapViewRegionIsChanging:self];
            }
            break;
        }
        case mbgl::MapChangeRegionDidChange:
        case mbgl::MapChangeRegionDidChangeAnimated:
        {
            // Update all UI at the end of an animation or atomic change to the
            // viewport. More expensive updates can happen here, but care should
            // still be taken to minimize the work done here because scroll
            // gesture recognition and momentum scrolling is performed as a
            // series of atomic changes, not an animation.
            [self updateZoomControls];
            [self updateCompass];
            [self updateAnnotationCallouts];
            [self updateAnnotationTrackingAreas];
            
            if ([self.delegate respondsToSelector:@selector(mapView:regionDidChangeAnimated:)]) {
                BOOL animated = change == mbgl::MapChangeRegionDidChangeAnimated;
                [self.delegate mapView:self regionDidChangeAnimated:animated];
            }
            break;
        }
        case mbgl::MapChangeWillStartLoadingMap:
        {
            if ([self.delegate respondsToSelector:@selector(mapViewWillStartLoadingMap:)]) {
                [self.delegate mapViewWillStartLoadingMap:self];
            }
            break;
        }
        case mbgl::MapChangeDidFinishLoadingMap:
        {
            if ([self.delegate respondsToSelector:@selector(mapViewDidFinishLoadingMap:)]) {
                [self.delegate mapViewDidFinishLoadingMap:self];
            }
            break;
        }
        case mbgl::MapChangeDidFailLoadingMap:
        {
            // Not yet implemented.
            break;
        }
        case mbgl::MapChangeWillStartRenderingMap:
        {
            if ([self.delegate respondsToSelector:@selector(mapViewWillStartRenderingMap:)]) {
                [self.delegate mapViewWillStartRenderingMap:self];
            }
            break;
        }
        case mbgl::MapChangeDidFinishRenderingMap:
        case mbgl::MapChangeDidFinishRenderingMapFullyRendered:
        {
            if ([self.delegate respondsToSelector:@selector(mapViewDidFinishRenderingMap:fullyRendered:)]) {
                BOOL fullyRendered = change == mbgl::MapChangeDidFinishRenderingMapFullyRendered;
                [self.delegate mapViewDidFinishRenderingMap:self fullyRendered:fullyRendered];
            }
            break;
        }
        case mbgl::MapChangeWillStartRenderingFrame:
        {
            if ([self.delegate respondsToSelector:@selector(mapViewWillStartRenderingFrame:)]) {
                [self.delegate mapViewWillStartRenderingFrame:self];
            }
            break;
        }
        case mbgl::MapChangeDidFinishRenderingFrame:
        case mbgl::MapChangeDidFinishRenderingFrameFullyRendered:
        {
            if ([self.delegate respondsToSelector:@selector(mapViewDidFinishRenderingFrame:fullyRendered:)]) {
                BOOL fullyRendered = change == mbgl::MapChangeDidFinishRenderingFrameFullyRendered;
                [self.delegate mapViewDidFinishRenderingFrame:self fullyRendered:fullyRendered];
            }
            break;
        }
    }
}

#pragma mark Viewport

- (CLLocationCoordinate2D)centerCoordinate {
    return MGLLocationCoordinate2DFromLatLng(_mbglMap->getLatLng());
}

- (void)setCenterCoordinate:(CLLocationCoordinate2D)centerCoordinate {
    [self setCenterCoordinate:centerCoordinate animated:NO];
}

- (void)setCenterCoordinate:(CLLocationCoordinate2D)centerCoordinate animated:(BOOL)animated {
    [self willChangeValueForKey:@"centerCoordinate"];
    _mbglMap->setLatLng(MGLLatLngFromLocationCoordinate2D(centerCoordinate),
                        MGLDurationInSeconds(animated ? MGLAnimationDuration : 0));
    [self didChangeValueForKey:@"centerCoordinate"];
}

- (void)offsetCenterCoordinateBy:(NSPoint)delta animated:(BOOL)animated {
    [self willChangeValueForKey:@"centerCoordinate"];
    _mbglMap->cancelTransitions();
    _mbglMap->moveBy({ delta.x, delta.y },
                     MGLDurationInSeconds(animated ? MGLAnimationDuration : 0));
    [self didChangeValueForKey:@"centerCoordinate"];
}

- (double)zoomLevel {
    return _mbglMap->getZoom();
}

- (void)setZoomLevel:(double)zoomLevel {
    [self setZoomLevel:zoomLevel animated:NO];
}

- (void)setZoomLevel:(double)zoomLevel animated:(BOOL)animated {
    _mbglMap->setZoom(zoomLevel, MGLDurationInSeconds(animated ? MGLAnimationDuration : 0));
}

- (void)scaleBy:(double)scaleFactor atPoint:(NSPoint)point animated:(BOOL)animated {
    [self willChangeValueForKey:@"zoomLevel"];
    mbgl::PrecisionPoint center(point.x, point.y);
    _mbglMap->scaleBy(scaleFactor, center, MGLDurationInSeconds(animated ? MGLAnimationDuration : 0));
    [self didChangeValueForKey:@"zoomLevel"];
}

- (double)maximumZoomLevel {
    return _mbglMap->getMaxZoom();
}

- (double)minimumZoomLevel {
    return _mbglMap->getMinZoom();
}

/// Respond to a click on the zoom control.
- (IBAction)zoomInOrOut:(NSSegmentedControl *)sender {
    switch (sender.selectedSegment) {
        case 0:
            // Zoom out.
            [self moveToEndOfParagraph:sender];
            break;
        case 1:
            // Zoom in.
            [self moveToBeginningOfParagraph:sender];
            break;
        default:
            break;
    }
}

- (CLLocationDirection)direction {
    return mbgl::util::wrap(_mbglMap->getBearing(), 0., 360.);
}

- (void)setDirection:(CLLocationDirection)direction {
    [self setDirection:direction animated:NO];
}

- (void)setDirection:(CLLocationDirection)direction animated:(BOOL)animated {
    [self willChangeValueForKey:@"direction"];
    _mbglMap->setBearing(direction, MGLDurationInSeconds(animated ? MGLAnimationDuration : 0));
    [self didChangeValueForKey:@"direction"];
}

- (void)offsetDirectionBy:(CLLocationDegrees)delta animated:(BOOL)animated {
    [self willChangeValueForKey:@"direction"];
    _mbglMap->cancelTransitions();
    _mbglMap->setBearing(_mbglMap->getBearing() + delta, MGLDurationInSeconds(animated ? MGLAnimationDuration : 0));
    [self didChangeValueForKey:@"direction"];
}

+ (NSSet *)keyPathsForValuesAffectingVisibleCoordinateBounds {
    return [NSSet setWithObjects:@"centerCoordinate", @"zoomLevel", @"direction", @"bounds", nil];
}

- (MGLCoordinateBounds)visibleCoordinateBounds {
    return [self convertRectToCoordinateBounds:self.bounds];
}

- (void)setVisibleCoordinateBounds:(MGLCoordinateBounds)bounds {
    [self setVisibleCoordinateBounds:bounds animated:NO];
}

- (void)setVisibleCoordinateBounds:(MGLCoordinateBounds)bounds animated:(BOOL)animated {
    [self setVisibleCoordinateBounds:bounds edgePadding:NSEdgeInsetsZero animated:animated];
}

- (void)setVisibleCoordinateBounds:(MGLCoordinateBounds)bounds edgePadding:(NSEdgeInsets)insets animated:(BOOL)animated {
    _mbglMap->cancelTransitions();
    
    mbgl::EdgeInsets mbglInsets = MGLEdgeInsetsFromNSEdgeInsets(insets);
    mbgl::CameraOptions options = _mbglMap->cameraForLatLngBounds(MGLLatLngBoundsFromCoordinateBounds(bounds), mbglInsets);
    if (animated) {
        options.duration = MGLDurationInSeconds(MGLAnimationDuration);
    }
    
    [self willChangeValueForKey:@"visibleCoordinateBounds"];
    options.transitionFinishFn = ^() {
        [self didChangeValueForKey:@"visibleCoordinateBounds"];
    };
    _mbglMap->easeTo(options);
}

#pragma mark Mouse events and gestures

- (BOOL)acceptsFirstResponder {
    return YES;
}

/// Drag to pan, plus drag to zoom, rotate, and tilt when a modifier key is held
/// down.
- (void)handlePanGesture:(NSPanGestureRecognizer *)gestureRecognizer {
    NSPoint delta = [gestureRecognizer translationInView:self];
    NSPoint endPoint = [gestureRecognizer locationInView:self];
    NSPoint startPoint = NSMakePoint(endPoint.x - delta.x, self.bounds.size.height - (endPoint.y - delta.y));
    
    NSEventModifierFlags flags = [NSApp currentEvent].modifierFlags;
    if (flags & NSShiftKeyMask) {
        // Shift-drag to zoom.
        if (!self.zoomEnabled) {
            return;
        }
        
        _mbglMap->cancelTransitions();
        
        if (gestureRecognizer.state == NSGestureRecognizerStateBegan) {
            _mbglMap->setGestureInProgress(true);
            _scaleAtBeginningOfGesture = _mbglMap->getScale();
        } else if (gestureRecognizer.state == NSGestureRecognizerStateChanged) {
            CGFloat newZoomLevel = log2f(_scaleAtBeginningOfGesture) - delta.y / 75;
            [self scaleBy:powf(2, newZoomLevel) / _mbglMap->getScale() atPoint:startPoint animated:NO];
        } else if (gestureRecognizer.state == NSGestureRecognizerStateEnded
                   || gestureRecognizer.state == NSGestureRecognizerStateCancelled) {
            _mbglMap->setGestureInProgress(false);
            // Maps.app locks the cursor to the start point, but that would
            // interfere with the pan gesture recognizer. Just move the cursor
            // back at the end of the gesture.
            CGDisplayMoveCursorToPoint(kCGDirectMainDisplay, startPoint);
        }
    } else if (flags & NSAlternateKeyMask) {
        // Option-drag to rotate and/or tilt.
        _mbglMap->cancelTransitions();
        
        if (gestureRecognizer.state == NSGestureRecognizerStateBegan) {
            _mbglMap->setGestureInProgress(true);
            _directionAtBeginningOfGesture = self.direction;
            _pitchAtBeginningOfGesture = _mbglMap->getPitch();
        } else if (gestureRecognizer.state == NSGestureRecognizerStateChanged) {
            mbgl::PrecisionPoint center(startPoint.x, startPoint.y);
            if (self.rotateEnabled) {
                CLLocationDirection newDirection = _directionAtBeginningOfGesture - delta.x / 10;
                [self willChangeValueForKey:@"direction"];
                _mbglMap->setBearing(newDirection, center);
                [self didChangeValueForKey:@"direction"];
            }
            if (self.pitchEnabled) {
                _mbglMap->setPitch(_pitchAtBeginningOfGesture + delta.y / 5);
            }
        } else if (gestureRecognizer.state == NSGestureRecognizerStateEnded
                   || gestureRecognizer.state == NSGestureRecognizerStateCancelled) {
            _mbglMap->setGestureInProgress(false);
        }
    } else if (self.scrollEnabled) {
        // Otherwise, drag to pan.
        _mbglMap->cancelTransitions();
        
        if (gestureRecognizer.state == NSGestureRecognizerStateBegan) {
            [self.window invalidateCursorRectsForView:self];
            _mbglMap->setGestureInProgress(true);
        } else if (gestureRecognizer.state == NSGestureRecognizerStateChanged) {
            delta.y *= -1;
            [self offsetCenterCoordinateBy:delta animated:NO];
            [gestureRecognizer setTranslation:NSZeroPoint inView:self];
        } else if (gestureRecognizer.state == NSGestureRecognizerStateEnded
                   || gestureRecognizer.state == NSGestureRecognizerStateCancelled) {
            _mbglMap->setGestureInProgress(false);
            [self.window invalidateCursorRectsForView:self];
        }
    }
}

/// Pinch to zoom.
- (void)handleMagnificationGesture:(NSMagnificationGestureRecognizer *)gestureRecognizer {
    if (!self.zoomEnabled) {
        return;
    }
    
    _mbglMap->cancelTransitions();
    
    if (gestureRecognizer.state == NSGestureRecognizerStateBegan) {
        _mbglMap->setGestureInProgress(true);
        _scaleAtBeginningOfGesture = _mbglMap->getScale();
    } else if (gestureRecognizer.state == NSGestureRecognizerStateChanged) {
        NSPoint zoomInPoint = [gestureRecognizer locationInView:self];
        mbgl::PrecisionPoint center(zoomInPoint.x, self.bounds.size.height - zoomInPoint.y);
        if (gestureRecognizer.magnification > -1) {
            [self willChangeValueForKey:@"zoomLevel"];
            [self willChangeValueForKey:@"centerCoordinate"];
            _mbglMap->setScale(_scaleAtBeginningOfGesture * (1 + gestureRecognizer.magnification), center);
            [self didChangeValueForKey:@"centerCoordinate"];
            [self didChangeValueForKey:@"zoomLevel"];
        }
    } else if (gestureRecognizer.state == NSGestureRecognizerStateEnded
               || gestureRecognizer.state == NSGestureRecognizerStateCancelled) {
        _mbglMap->setGestureInProgress(false);
    }
}

/// Click or tap to select an annotation.
- (void)handleClickGesture:(NSClickGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer.state != NSGestureRecognizerStateEnded) {
        return;
    }
    
    NSPoint gesturePoint = [gestureRecognizer locationInView:self];
    MGLAnnotationID hitAnnotationID = [self annotationIDAtPoint:gesturePoint persistingResults:YES];
    if (hitAnnotationID != MGLAnnotationNotFound) {
        if (hitAnnotationID != _selectedAnnotationID) {
            id <MGLAnnotation> annotation = [self annotationWithID:hitAnnotationID];
            NSAssert(annotation, @"Cannot select nonexistent annotation with ID %i", hitAnnotationID);
            [self selectAnnotation:annotation animated:YES];
        }
    } else {
        [self deselectAnnotation:self.selectedAnnotation animated:YES];
    }
}

/// Tap with two fingers (“right-click”) to zoom out.
- (void)handleSecondaryClickGesture:(NSClickGestureRecognizer *)gestureRecognizer {
    if (!self.zoomEnabled) {
        return;
    }
    
    _mbglMap->cancelTransitions();
    
    NSPoint gesturePoint = [gestureRecognizer locationInView:self];
    [self scaleBy:0.5 atPoint:NSMakePoint(gesturePoint.x, self.bounds.size.height - gesturePoint.y) animated:YES];
}

/// Double-click or double-tap to zoom in.
- (void)handleDoubleClickGesture:(NSClickGestureRecognizer *)gestureRecognizer {
    if (!self.zoomEnabled) {
        return;
    }
    
    _mbglMap->cancelTransitions();
    
    NSPoint gesturePoint = [gestureRecognizer locationInView:self];
    [self scaleBy:2 atPoint:NSMakePoint(gesturePoint.x, self.bounds.size.height - gesturePoint.y) animated:YES];
}

/// Rotate fingers to rotate.
- (void)handleRotationGesture:(NSRotationGestureRecognizer *)gestureRecognizer {
    if (!self.rotateEnabled) {
        return;
    }
    
    _mbglMap->cancelTransitions();
    
    if (gestureRecognizer.state == NSGestureRecognizerStateBegan) {
        _mbglMap->setGestureInProgress(true);
        _directionAtBeginningOfGesture = self.direction;
    } else if (gestureRecognizer.state == NSGestureRecognizerStateChanged) {
        NSPoint rotationPoint = [gestureRecognizer locationInView:self];
        mbgl::PrecisionPoint center(rotationPoint.x, rotationPoint.y);
        _mbglMap->setBearing(_directionAtBeginningOfGesture + gestureRecognizer.rotationInDegrees, center);
    } else if (gestureRecognizer.state == NSGestureRecognizerStateEnded
               || gestureRecognizer.state == NSGestureRecognizerStateCancelled) {
        _mbglMap->setGestureInProgress(false);
    }
}

- (BOOL)wantsScrollEventsForSwipeTrackingOnAxis:(__unused NSEventGestureAxis)axis {
    // Track both horizontal and vertical swipes in -scrollWheel:.
    return YES;
}

- (void)scrollWheel:(NSEvent *)event {
    // https://developer.apple.com/library/mac/releasenotes/AppKit/RN-AppKitOlderNotes/#10_7Dragging
    if (event.phase == NSEventPhaseNone && event.momentumPhase == NSEventPhaseNone) {
        // A traditional, vertical scroll wheel zooms instead of panning.
        if (self.zoomEnabled && std::abs(event.scrollingDeltaX) < std::abs(event.scrollingDeltaY)) {
            _mbglMap->cancelTransitions();
            
            [self willChangeValueForKey:@"zoomLevel"];
            [self willChangeValueForKey:@"centerCoordinate"];
            NSPoint gesturePoint = [self convertPoint:event.locationInWindow fromView:nil];
            mbgl::PrecisionPoint center(gesturePoint.x, self.bounds.size.height - gesturePoint.y);
            _mbglMap->scaleBy(exp2(event.scrollingDeltaY / 20), center);
            [self didChangeValueForKey:@"centerCoordinate"];
            [self didChangeValueForKey:@"zoomLevel"];
        }
    } else if (self.scrollEnabled
               && _magnificationGestureRecognizer.state == NSGestureRecognizerStatePossible
               && _rotationGestureRecognizer.state == NSGestureRecognizerStatePossible) {
        // Scroll to pan.
        _mbglMap->cancelTransitions();
        
        CGFloat x = event.scrollingDeltaX;
        CGFloat y = event.scrollingDeltaY;
        if (x || y) {
            [self offsetCenterCoordinateBy:NSMakePoint(x, y) animated:NO];
        }
        
        // Drift pan.
        if (event.momentumPhase != NSEventPhaseNone) {
            [self offsetCenterCoordinateBy:NSMakePoint(x, y) animated:NO];
        }
    }
}

#pragma mark Keyboard events

- (void)keyDown:(NSEvent *)event {
    if (event.modifierFlags & NSNumericPadKeyMask) {
        // This is the recommended way to handle arrow key presses, causing
        // methods like -moveUp: and -moveToBeginningOfParagraph: to be called
        // for various standard keybindings.
        [self interpretKeyEvents:@[event]];
    } else {
        [super keyDown:event];
    }
}

- (IBAction)moveUp:(__unused id)sender {
    [self offsetCenterCoordinateBy:NSMakePoint(0, MGLKeyPanningIncrement) animated:YES];
}

- (IBAction)moveDown:(__unused id)sender {
    [self offsetCenterCoordinateBy:NSMakePoint(0, -MGLKeyPanningIncrement) animated:YES];
}

- (IBAction)moveLeft:(__unused id)sender {
    [self offsetCenterCoordinateBy:NSMakePoint(MGLKeyPanningIncrement, 0) animated:YES];
}

- (IBAction)moveRight:(__unused id)sender {
    [self offsetCenterCoordinateBy:NSMakePoint(-MGLKeyPanningIncrement, 0) animated:YES];
}

- (IBAction)moveToBeginningOfParagraph:(__unused id)sender {
    if (self.zoomEnabled) {
        [self scaleBy:2 atPoint:NSZeroPoint animated:YES];
    }
}

- (IBAction)moveToEndOfParagraph:(__unused id)sender {
    if (self.zoomEnabled) {
        [self scaleBy:0.5 atPoint:NSZeroPoint animated:YES];
    }
}

- (IBAction)moveWordLeft:(__unused id)sender {
    if (self.rotateEnabled) {
        [self offsetDirectionBy:MGLKeyRotationIncrement animated:YES];
    }
}

- (IBAction)moveWordRight:(__unused id)sender {
    if (self.rotateEnabled) {
        [self offsetDirectionBy:-MGLKeyRotationIncrement animated:YES];
    }
}

- (void)setZoomEnabled:(BOOL)zoomEnabled {
    _zoomEnabled = zoomEnabled;
    _zoomControls.enabled = zoomEnabled;
    _zoomControls.hidden = !zoomEnabled;
}

- (void)setRotateEnabled:(BOOL)rotateEnabled {
    _rotateEnabled = rotateEnabled;
    _compass.enabled = rotateEnabled;
    _compass.hidden = !rotateEnabled;
}

#pragma mark Ornaments

/// Updates the zoom controls’ enabled state based on the current zoom level.
- (void)updateZoomControls {
    [_zoomControls setEnabled:self.zoomLevel > self.minimumZoomLevel forSegment:0];
    [_zoomControls setEnabled:self.zoomLevel < self.maximumZoomLevel forSegment:1];
}

/// Updates the compass to point in the same direction as the map.
- (void)updateCompass {
    // The circular slider control goes counterclockwise, whereas our map
    // measures its direction clockwise.
    _compass.doubleValue = -self.direction;
}

- (IBAction)rotate:(NSSlider *)sender {
    [self setDirection:-sender.doubleValue animated:YES];
}

#pragma mark Annotations

- (nullable NS_ARRAY_OF(id <MGLAnnotation>) *)annotations {
    if (_annotationContextsByAnnotationID.empty()) {
        return nil;
    }
    
    std::vector<id <MGLAnnotation> > annotations;
    std::transform(_annotationContextsByAnnotationID.begin(),
                   _annotationContextsByAnnotationID.end(),
                   std::back_inserter(annotations),
                   ^ id <MGLAnnotation> (const std::pair<MGLAnnotationID, MGLAnnotationContext> &pair) {
                       return pair.second.annotation;
                   });
    return [NSArray arrayWithObjects:&annotations[0] count:annotations.size()];
}

- (id <MGLAnnotation>)annotationWithID:(MGLAnnotationID)annotationID {
    if (!_annotationContextsByAnnotationID.count(annotationID)) {
        return nil;
    }
    
    MGLAnnotationContext &annotationContext = _annotationContextsByAnnotationID[annotationID];
    return annotationContext.annotation;
}

- (MGLAnnotationID)annotationIDForAnnotation:(id <MGLAnnotation>)annotation {
    if (!annotation) {
        return MGLAnnotationNotFound;
    }
    
    for (auto &pair : _annotationContextsByAnnotationID) {
        if (pair.second.annotation == annotation) {
            return pair.first;
        }
    }
    return MGLAnnotationNotFound;
}

- (void)addAnnotation:(id <MGLAnnotation>)annotation {
    if (annotation) {
        [self addAnnotations:@[annotation]];
    }
}

- (void)addAnnotations:(NS_ARRAY_OF(id <MGLAnnotation>) *)annotations {
    if (!annotations) {
        return;
    }
    
    BOOL delegateHasImagesForAnnotations = [self.delegate respondsToSelector:@selector(mapView:imageForAnnotation:)];
    
    std::vector<mbgl::PointAnnotation> points;
    std::vector<mbgl::ShapeAnnotation> shapes;
    
    for (id <MGLAnnotation> annotation in annotations) {
        NSAssert([annotation conformsToProtocol:@protocol(MGLAnnotation)], @"Annotation does not conform to MGLAnnotation");
        
        if ([annotation isKindOfClass:[MGLMultiPoint class]]) {
            [(MGLMultiPoint *)annotation addShapeAnnotationObjectToCollection:shapes withDelegate:self];
        } else {
            MGLAnnotationImage *annotationImage = nil;
            if (delegateHasImagesForAnnotations) {
                annotationImage = [self.delegate mapView:self imageForAnnotation:annotation];
            }
            if (!annotationImage) {
                annotationImage = [self dequeueReusableAnnotationImageWithIdentifier:MGLDefaultStyleMarkerSymbolName];
            }
            if (!annotationImage) {
                NSImage *image = MGLDefaultMarkerImage();
                NSRect alignmentRect = image.alignmentRect;
                alignmentRect.origin.y = NSMidY(alignmentRect);
                alignmentRect.size.height /= 2;
                image.alignmentRect = alignmentRect;
                annotationImage = [MGLAnnotationImage annotationImageWithImage:image
                                                               reuseIdentifier:MGLDefaultStyleMarkerSymbolName];
            }
            
            if (!self.annotationImagesByIdentifier[annotationImage.reuseIdentifier]) {
                self.annotationImagesByIdentifier[annotationImage.reuseIdentifier] = annotationImage;
                [self installAnnotationImage:annotationImage];
            }
            
            NSString *symbolName = [MGLAnnotationSpritePrefix stringByAppendingString:annotationImage.reuseIdentifier];
            points.emplace_back(MGLLatLngFromLocationCoordinate2D(annotation.coordinate), symbolName ? [symbolName UTF8String] : "");
            
            if (annotation.toolTip.length) {
                _wantsToolTipRects = YES;
            }
        }
    }
    
    if (points.size()) {
        std::vector<MGLAnnotationID> pointAnnotationIDs = _mbglMap->addPointAnnotations(points);
        
        for (size_t i = 0; i < pointAnnotationIDs.size(); ++i) {
            MGLAnnotationContext context;
            context.annotation = annotations[i];
            context.symbolIdentifier = @(points[i].icon.c_str());
            _annotationContextsByAnnotationID[pointAnnotationIDs[i]] = context;
        }
    }
    
    if (shapes.size()) {
        std::vector<MGLAnnotationID> shapeAnnotationIDs = _mbglMap->addShapeAnnotations(shapes);
        
        for (size_t i = 0; i < shapeAnnotationIDs.size(); ++i) {
            MGLAnnotationContext context;
            context.annotation = annotations[i];
            _annotationContextsByAnnotationID[shapeAnnotationIDs[i]] = context;
        }
    }
    
    [self updateAnnotationTrackingAreas];
}

- (void)installAnnotationImage:(MGLAnnotationImage *)annotationImage {
    NSImage *image = annotationImage.image;
    NSSize size = image.size;
    if (size.width < 1 || size.height < 1 || !image.valid) {
        return;
    }
    
    // http://www.cocoabuilder.com/archive/cocoa/82430-nsimage-getting-raw-bitmap-data.html#82431
    [image lockFocus];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithFocusedViewRect:{ NSZeroPoint, size }];
    [image unlockFocus];
    
    std::string pixelString((const char *)rep.bitmapData, rep.pixelsWide * rep.pixelsHigh * 4 /* RGBA */);
    auto cSpriteImage = std::make_shared<mbgl::SpriteImage>((uint16_t)rep.size.width,
                                                            (uint16_t)rep.size.height,
                                                            (float)(rep.pixelsWide / size.width),
                                                            std::move(pixelString));
    NSString *symbolName = [MGLAnnotationSpritePrefix stringByAppendingString:annotationImage.reuseIdentifier];
    _mbglMap->setSprite(symbolName.UTF8String, cSpriteImage);
    
    // Create a slop area with a “radius” equal to the annotation image’s entire
    // size, allowing the eventual click to be on any point within this image.
    // Union this slop area with any existing slop areas.
    _unionedAnnotationImageSize = NSMakeSize(MAX(_unionedAnnotationImageSize.width, size.width),
                                             MAX(_unionedAnnotationImageSize.height, size.height));
    
    if (annotationImage.cursor) {
        _wantsCursorRects = YES;
    }
}

- (void)removeAnnotation:(id <MGLAnnotation>)annotation {
    if (annotation) {
        [self removeAnnotations:@[annotation]];
    }
}

- (void)removeAnnotations:(NS_ARRAY_OF(id <MGLAnnotation>) *)annotations {
    if (!annotations) {
        return;
    }
    
    std::vector<MGLAnnotationID> annotationIDsToRemove;
    annotationIDsToRemove.reserve(annotations.count);
    
    for (id <MGLAnnotation> annotation in annotations) {
        NSAssert([annotation conformsToProtocol:@protocol(MGLAnnotation)], @"Annotation does not conform to MGLAnnotation");
        
        MGLAnnotationID annotationID = [self annotationIDForAnnotation:annotation];
        NSAssert(annotationID != MGLAnnotationNotFound, @"No ID for annotation %@", annotation);
        annotationIDsToRemove.push_back(annotationID);
        
        _annotationContextsByAnnotationID.erase(annotationID);
        
        if (annotationID == _selectedAnnotationID) {
            [self deselectAnnotation:annotation animated:NO];
        }
        
        if (annotationID == _lastSelectedAnnotationID) {
            _lastSelectedAnnotationID = MGLAnnotationNotFound;
        }
    }
    
    _mbglMap->removeAnnotations(annotationIDsToRemove);
    
    [self updateAnnotationTrackingAreas];
}

- (id <MGLAnnotation>)selectedAnnotation {
    if (!_annotationContextsByAnnotationID.count(_selectedAnnotationID)) {
        return nil;
    }
    MGLAnnotationContext &annotationContext = _annotationContextsByAnnotationID.at(_selectedAnnotationID);
    return annotationContext.annotation;
}

- (nullable MGLAnnotationImage *)dequeueReusableAnnotationImageWithIdentifier:(NSString *)identifier {
    if ([identifier hasPrefix:MGLAnnotationSpritePrefix]) {
        identifier = [identifier substringFromIndex:MGLAnnotationSpritePrefix.length];
    }
    return self.annotationImagesByIdentifier[identifier];
}

- (id <MGLAnnotation>)annotationAtPoint:(NSPoint)point {
    return [self annotationWithID:[self annotationIDAtPoint:point persistingResults:NO]];
}

- (MGLAnnotationID)annotationIDAtPoint:(NSPoint)point persistingResults:(BOOL)persist {
    // Look for any annotation near the click. An annotation is “near” if the
    // distance between its center and the click is less than the maximum height
    // or width of an installed annotation image.
    NSRect queryRect = NSInsetRect({ point, NSZeroSize },
                                   -_unionedAnnotationImageSize.width / 2,
                                   -_unionedAnnotationImageSize.height / 2);
    queryRect = NSInsetRect(queryRect, -MGLAnnotationImagePaddingForHitTest,
                            -MGLAnnotationImagePaddingForHitTest);
    std::vector<MGLAnnotationID> nearbyAnnotations = [self annotationIDsInRect:queryRect];
    
    if (nearbyAnnotations.size()) {
        NSRect hitRect = NSInsetRect({ point, NSZeroSize },
                                     -MGLAnnotationImagePaddingForHitTest,
                                     -MGLAnnotationImagePaddingForHitTest);
        mbgl::util::erase_if(nearbyAnnotations, [&](const MGLAnnotationID annotationID) {
            NSAssert(_annotationContextsByAnnotationID.count(annotationID) != 0, @"Unknown annotation found nearby click");
            id <MGLAnnotation> annotation = [self annotationWithID:annotationID];
            if (!annotation) {
                return true;
            }
            
            MGLAnnotationImage *annotationImage = [self imageOfAnnotationWithID:annotationID];
            if (!annotationImage.selectable) {
                return true;
            }
            
            NSRect annotationRect = [self frameOfImage:annotationImage.image
                                  centeredAtCoordinate:annotation.coordinate];
            return !!![annotationImage.image hitTestRect:hitRect withImageDestinationRect:annotationRect
                                                 context:nil hints:nil flipped:NO];
        });
    }
    
    MGLAnnotationID hitAnnotationID = MGLAnnotationNotFound;
    if (nearbyAnnotations.size()) {
        std::sort(nearbyAnnotations.begin(), nearbyAnnotations.end());
        
        if (nearbyAnnotations == _annotationsNearbyLastClick) {
            if (_lastSelectedAnnotationID == _annotationsNearbyLastClick.back()
                || _lastSelectedAnnotationID == MGLAnnotationNotFound) {
                hitAnnotationID = _annotationsNearbyLastClick.front();
            } else {
                auto result = std::find(_annotationsNearbyLastClick.begin(),
                                        _annotationsNearbyLastClick.end(),
                                        _lastSelectedAnnotationID);
                auto distance = std::distance(_annotationsNearbyLastClick.begin(), result);
                hitAnnotationID = _annotationsNearbyLastClick[distance + 1];
            }
        } else {
            if (persist) {
                _annotationsNearbyLastClick = nearbyAnnotations;
            }
            if (_annotationsNearbyLastClick.size()) {
                hitAnnotationID = _annotationsNearbyLastClick.front();
            }
        }
    }
    
    return hitAnnotationID;
}

- (std::vector<MGLAnnotationID>)annotationIDsInRect:(NSRect)rect {
    mbgl::LatLngBounds queryBounds = [self convertRectToLatLngBounds:rect];
    return _mbglMap->getPointAnnotationsInBounds(queryBounds);
}

- (NS_ARRAY_OF(id <MGLAnnotation>) *)selectedAnnotations {
    id <MGLAnnotation> selectedAnnotation = self.selectedAnnotation;
    return selectedAnnotation ? @[selectedAnnotation] : @[];
}

- (void)setSelectedAnnotation:(id <MGLAnnotation>)selectedAnnotation {
    _selectedAnnotationID = [self annotationIDForAnnotation:selectedAnnotation];
}

- (void)setSelectedAnnotations:(NS_ARRAY_OF(id <MGLAnnotation>) *)selectedAnnotations {
    if (!selectedAnnotations.count) {
        return;
    }
    
    id <MGLAnnotation> firstAnnotation = selectedAnnotations[0];
    NSAssert([firstAnnotation conformsToProtocol:@protocol(MGLAnnotation)], @"Annotation does not conform to MGLAnnotation");
    if ([firstAnnotation isKindOfClass:[MGLMultiPoint class]]) {
        return;
    }
    
    if (MGLCoordinateInCoordinateBounds(firstAnnotation.coordinate, self.visibleCoordinateBounds)) {
        [self selectAnnotation:firstAnnotation animated:NO];
    }
}

- (void)selectAnnotation:(id <MGLAnnotation>)annotation animated:(BOOL)animated
{
    if (!annotation || [annotation isKindOfClass:[MGLMultiPoint class]]) {
        return;
    }
    
    id <MGLAnnotation> selectedAnnotation = self.selectedAnnotation;
    if (annotation == selectedAnnotation) {
        return;
    }
    
    [self deselectAnnotation:selectedAnnotation animated:NO];
    
    MGLAnnotationID annotationID = [self annotationIDForAnnotation:annotation];
    if (annotationID == MGLAnnotationNotFound) {
        [self addAnnotation:annotation];
    }
    
    NSRect positioningRect = [self positioningRectForCalloutForAnnotationWithID:annotationID];
    if (NSIsEmptyRect(NSIntersectionRect(positioningRect, self.bounds))) {
        return;
    }
    
    [self willChangeValueForKey:@"selectedAnnotation"];
    _selectedAnnotationID = annotationID;
    _lastSelectedAnnotationID = _selectedAnnotationID;
    [self didChangeValueForKey:@"selectedAnnotation"];
    
    if ([annotation respondsToSelector:@selector(title)]
        && annotation.title
        && !self.calloutForSelectedAnnotation.shown
        && [self.delegate respondsToSelector:@selector(mapView:annotationCanShowCallout:)]
        && [self.delegate mapView:self annotationCanShowCallout:annotation]) {
        NSPopover *callout = [self calloutForAnnotation:annotation];
        callout.animates = animated;
        
        callout.delegate = self;
        self.calloutForSelectedAnnotation = callout;
        NSRectEdge edge = (self.userInterfaceLayoutDirection == NSUserInterfaceLayoutDirectionRightToLeft
                           ? NSMinXEdge
                           : NSMaxXEdge);
        [callout showRelativeToRect:positioningRect ofView:self preferredEdge:edge];
    }
}

- (NSPopover *)calloutForAnnotation:(id <MGLAnnotation>)annotation {
    NSPopover *callout = [[NSPopover alloc] init];
    callout.behavior = NSPopoverBehaviorTransient;
    
    NSViewController *viewController;
    if ([self.delegate respondsToSelector:@selector(mapView:calloutViewControllerForAnnotation:)]) {
        viewController = [self.delegate mapView:self calloutViewControllerForAnnotation:annotation];
    }
    if (!viewController) {
        viewController = [[NSViewController alloc] initWithNibName:@"MGLAnnotationCallout"
                                                            bundle:[NSBundle mgl_frameworkBundle]];
    }
    NSAssert(viewController, @"Unable to load MGLAnnotationCallout view controller");
    viewController.representedObject = annotation;
    callout.contentViewController = viewController;
    
    return callout;
}

- (NSRect)positioningRectForCalloutForAnnotationWithID:(MGLAnnotationID)annotationID {
    id <MGLAnnotation> annotation = [self annotationWithID:annotationID];
    if (!annotation) {
        return NSZeroRect;
    }
    NSImage *image = [self imageOfAnnotationWithID:annotationID].image;
    if (!image) {
        return NSZeroRect;
    }
    
    NSRect positioningRect = [self frameOfImage:image centeredAtCoordinate:annotation.coordinate];
    positioningRect = NSOffsetRect(image.alignmentRect, positioningRect.origin.x, positioningRect.origin.y);
    return NSInsetRect(positioningRect, -MGLAnnotationImagePaddingForCallout,
                       -MGLAnnotationImagePaddingForCallout);
}

- (NSRect)frameOfImage:(NSImage *)image centeredAtCoordinate:(CLLocationCoordinate2D)coordinate {
    NSPoint calloutAnchorPoint = [self convertCoordinate:coordinate toPointToView:self];
    return NSInsetRect({ calloutAnchorPoint, NSZeroSize }, -image.size.width / 2, -image.size.height / 2);
}

- (MGLAnnotationImage *)imageOfAnnotationWithID:(MGLAnnotationID)annotationID {
    if (annotationID == MGLAnnotationNotFound
        || _annotationContextsByAnnotationID.count(annotationID) == 0) {
        return nil;
    }
    
    NSString *customSymbol = _annotationContextsByAnnotationID.at(annotationID).symbolIdentifier;
    NSString *symbolName = customSymbol.length ? customSymbol : MGLDefaultStyleMarkerSymbolName;
    
    return [self dequeueReusableAnnotationImageWithIdentifier:symbolName];
}

- (void)deselectAnnotation:(id <MGLAnnotation>)annotation animated:(BOOL)animated {
    if (!annotation || self.selectedAnnotation != annotation) {
        return;
    }
    
    NSPopover *callout = self.calloutForSelectedAnnotation;
    callout.animates = animated;
    [callout performClose:self];
    
    self.selectedAnnotation = nil;
}

- (void)updateAnnotationCallouts {
    NSPopover *callout = self.calloutForSelectedAnnotation;
    if (callout) {
        callout.positioningRect = [self positioningRectForCalloutForAnnotationWithID:_selectedAnnotationID];
    }
}

#pragma mark MGLMultiPointDelegate methods

- (double)alphaForShapeAnnotation:(MGLShape *)annotation {
    if (_delegateHasAlphasForShapeAnnotations) {
        return [self.delegate mapView:self alphaForShapeAnnotation:annotation];
    }
    return 1.0;
}

- (mbgl::Color)strokeColorForShapeAnnotation:(MGLShape *)annotation {
    NSColor *color = (_delegateHasStrokeColorsForShapeAnnotations
                      ? [self.delegate mapView:self strokeColorForShapeAnnotation:annotation]
                      : [NSColor blackColor]);
    return MGLColorObjectFromNSColor(color);
}

- (mbgl::Color)fillColorForPolygonAnnotation:(MGLPolygon *)annotation {
    NSColor *color = (_delegateHasFillColorsForShapeAnnotations
                      ? [self.delegate mapView:self fillColorForPolygonAnnotation:annotation]
                      : [NSColor blueColor]);
    return MGLColorObjectFromNSColor(color);
}

- (CGFloat)lineWidthForPolylineAnnotation:(MGLPolyline *)annotation {
    if (_delegateHasLineWidthsForShapeAnnotations) {
        return [self.delegate mapView:self lineWidthForPolylineAnnotation:(MGLPolyline *)annotation];
    }
    return 3.0;
}

#pragma mark MGLPopoverDelegate methods

- (void)popoverDidShow:(__unused NSNotification *)notification {
    id <MGLAnnotation> annotation = self.selectedAnnotation;
    if ([self.delegate respondsToSelector:@selector(mapView:didSelectAnnotation:)]) {
        [self.delegate mapView:self didSelectAnnotation:annotation];
    }
}

- (void)popoverDidClose:(__unused NSNotification *)notification {
    id <MGLAnnotation> annotation = self.calloutForSelectedAnnotation.contentViewController.representedObject;
    self.calloutForSelectedAnnotation = nil;
    self.selectedAnnotation = nil;
    
    if ([self.delegate respondsToSelector:@selector(mapView:didDeselectAnnotation:)]) {
        [self.delegate mapView:self didDeselectAnnotation:annotation];
    }
}

#pragma mark Overlays

- (void)addOverlay:(id <MGLOverlay>)overlay {
    [self addOverlays:@[overlay]];
}

- (void)addOverlays:(NS_ARRAY_OF(id <MGLOverlay>) *)overlays
{
    for (id <MGLOverlay> overlay in overlays) {
        NSAssert([overlay conformsToProtocol:@protocol(MGLOverlay)], @"Overlay does not conform to MGLOverlay");
    }
    [self addAnnotations:overlays];
}

- (void)removeOverlay:(id <MGLOverlay>)overlay {
    [self removeOverlays:@[overlay]];
}

- (void)removeOverlays:(NS_ARRAY_OF(id <MGLOverlay>) *)overlays {
    for (id <MGLOverlay> overlay in overlays) {
        NSAssert([overlay conformsToProtocol:@protocol(MGLOverlay)], @"Overlay does not conform to MGLOverlay");
    }
    [self removeAnnotations:overlays];
}

#pragma mark Tooltips and cursors

- (void)updateAnnotationTrackingAreas {
    if (_wantsToolTipRects) {
        [self removeAllToolTips];
        std::vector<MGLAnnotationID> annotationIDs = [self annotationIDsInRect:self.bounds];
        for (MGLAnnotationID annotationID : annotationIDs) {
            MGLAnnotationImage *annotationImage = [self imageOfAnnotationWithID:annotationID];
            id <MGLAnnotation> annotation = [self annotationWithID:annotationID];
            if (annotation.toolTip.length) {
                NSImage *image = annotationImage.image;
                NSRect annotationRect = [self frameOfImage:image
                                      centeredAtCoordinate:annotation.coordinate];
                annotationRect = NSOffsetRect(image.alignmentRect, annotationRect.origin.x, annotationRect.origin.y);
                if (!NSIsEmptyRect(annotationRect)) {
                    [self addToolTipRect:annotationRect owner:self userData:(void *)(NSUInteger)annotationID];
                }
            }
            if (annotationImage.cursor) {
                _wantsCursorRects = YES;
            }
        }
    }
    
    if (_wantsCursorRects) {
        [self.window invalidateCursorRectsForView:self];
    }
}

- (NSString *)view:(__unused NSView *)view stringForToolTip:(__unused NSToolTipTag)tag point:(__unused NSPoint)point userData:(void *)data {
    if ((NSUInteger)data >= MGLAnnotationNotFound) {
        return nil;
    }
    MGLAnnotationID annotationID = (NSUInteger)data;
    id <MGLAnnotation> annotation = [self annotationWithID:annotationID];
    return annotation.toolTip;
}

- (void)resetCursorRects {
    if (_panGestureRecognizer.state == NSGestureRecognizerStateBegan
        || _panGestureRecognizer.state == NSGestureRecognizerStateChanged) {
        [self addCursorRect:self.bounds cursor:[NSCursor closedHandCursor]];
        return;
    }
    if (!_wantsCursorRects) {
        return;
    }
    
    std::vector<MGLAnnotationID> annotationIDs = [self annotationIDsInRect:self.bounds];
    for (MGLAnnotationID annotationID : annotationIDs) {
        id <MGLAnnotation> annotation = [self annotationWithID:annotationID];
        MGLAnnotationImage *annotationImage = [self imageOfAnnotationWithID:annotationID];
        if (annotationImage.cursor) {
            NSImage *image = annotationImage.image;
            NSRect annotationRect = [self frameOfImage:image
                                  centeredAtCoordinate:annotation.coordinate];
            annotationRect = NSOffsetRect(image.alignmentRect, annotationRect.origin.x, annotationRect.origin.y);
            [self addCursorRect:annotationRect cursor:annotationImage.cursor];
        }
    }
}

#pragma mark Interface Builder methods

- (void)prepareForInterfaceBuilder {
    [super prepareForInterfaceBuilder];
    
    // Color the background a glorious Mapbox teal.
    self.layer.borderColor = [NSColor colorWithRed:59/255.
                                             green:178/255.
                                              blue:208/255.
                                             alpha:0.8].CGColor;
    self.layer.borderWidth = 2;
    self.layer.backgroundColor = [NSColor colorWithRed:59/255.
                                                 green:178/255.
                                                  blue:208/255.
                                                 alpha:0.6].CGColor;
    
    // Place a playful marker right smack dab in the middle.
    self.layer.contents = MGLDefaultMarkerImage();
    self.layer.contentsGravity = kCAGravityCenter;
    self.layer.contentsScale = [NSScreen mainScreen].backingScaleFactor;
}

#pragma mark Geometric methods

- (CLLocationCoordinate2D)convertPoint:(NSPoint)point toCoordinateFromView:(nullable NSView *)view {
    return MGLLocationCoordinate2DFromLatLng([self convertPoint:point toLatLngFromView:view]);
}

- (mbgl::LatLng)convertPoint:(NSPoint)point toLatLngFromView:(nullable NSView *)view {
    NSPoint convertedPoint = [self convertPoint:point fromView:view];
    return _mbglMap->latLngForPixel(mbgl::PrecisionPoint(convertedPoint.x, convertedPoint.y));
}

- (NSPoint)convertCoordinate:(CLLocationCoordinate2D)coordinate toPointToView:(nullable NSView *)view {
    return [self convertLatLng:MGLLatLngFromLocationCoordinate2D(coordinate) toPointToView:view];
}

- (NSPoint)convertLatLng:(mbgl::LatLng)latLng toPointToView:(nullable NSView *)view {
    mbgl::vec2<double> pixel = _mbglMap->pixelForLatLng(latLng);
    return [self convertPoint:NSMakePoint(pixel.x, pixel.y) toView:view];
}

- (MGLCoordinateBounds)convertRectToCoordinateBounds:(NSRect)rect {
    return MGLCoordinateBoundsFromLatLngBounds([self convertRectToLatLngBounds:rect]);
}

- (mbgl::LatLngBounds)convertRectToLatLngBounds:(NSRect)rect {
    mbgl::LatLngBounds bounds = mbgl::LatLngBounds::getExtendable();
    bounds.extend([self convertPoint:rect.origin toLatLngFromView:self]);
    bounds.extend([self convertPoint:{ NSMaxX(rect), NSMinY(rect) } toLatLngFromView:self]);
    bounds.extend([self convertPoint:{ NSMaxX(rect), NSMaxY(rect) } toLatLngFromView:self]);
    bounds.extend([self convertPoint:{ NSMinX(rect), NSMaxY(rect) } toLatLngFromView:self]);
    
    // The world is wrapping if a point just outside the bounds is also within
    // the rect.
    mbgl::LatLng outsideLatLng;
    if (bounds.sw.longitude > -180) {
        outsideLatLng = {
            (bounds.sw.latitude + bounds.ne.latitude) / 2,
            bounds.sw.longitude - 1,
        };
    } else if (bounds.ne.longitude < 180) {
        outsideLatLng = {
            (bounds.sw.latitude + bounds.ne.latitude) / 2,
            bounds.ne.longitude + 1,
        };
    }
    
    // If the world is wrapping, extend the bounds to cover all longitudes.
    if (NSPointInRect([self convertLatLng:outsideLatLng toPointToView:self], rect)) {
        bounds.sw.longitude = -180;
        bounds.ne.longitude = 180;
    }
    
    return bounds;
}

- (CLLocationDistance)metersPerPixelAtLatitude:(CLLocationDegrees)latitude {
    return _mbglMap->getMetersPerPixelAtLatitude(latitude, self.zoomLevel);
}

#pragma mark Debugging

- (MGLMapDebugMaskOptions)debugMask {
    mbgl::MapDebugOptions options = _mbglMap->getDebug();
    MGLMapDebugMaskOptions mask = 0;
    if (options & mbgl::MapDebugOptions::TileBorders) {
        mask |= MGLMapDebugTileBoundariesMask;
    }
    if (options & mbgl::MapDebugOptions::ParseStatus) {
        mask |= MGLMapDebugTileInfoMask;
    }
    if (options & mbgl::MapDebugOptions::Timestamps) {
        mask |= MGLMapDebugTimestampsMask;
    }
    if (options & mbgl::MapDebugOptions::Collision) {
        mask |= MGLMapDebugCollisionBoxesMask;
    }
    return mask;
}

- (void)setDebugMask:(MGLMapDebugMaskOptions)debugMask {
    mbgl::MapDebugOptions options = mbgl::MapDebugOptions::NoDebug;
    if (debugMask & MGLMapDebugTileBoundariesMask) {
        options |= mbgl::MapDebugOptions::TileBorders;
    }
    if (debugMask & MGLMapDebugTileInfoMask) {
        options |= mbgl::MapDebugOptions::ParseStatus;
    }
    if (debugMask & MGLMapDebugTimestampsMask) {
        options |= mbgl::MapDebugOptions::Timestamps;
    }
    if (debugMask & MGLMapDebugCollisionBoxesMask) {
        options |= mbgl::MapDebugOptions::Collision;
    }
    _mbglMap->setDebug(options);
}

class MGLMapViewImpl : public mbgl::View {
public:
    MGLMapViewImpl(MGLMapView *nativeView_, const float scaleFactor_)
        : nativeView(nativeView_), scaleFactor(scaleFactor_) {}
    virtual ~MGLMapViewImpl() {}
    
    
    float getPixelRatio() const override {
        return scaleFactor;
    }
    
    std::array<uint16_t, 2> getSize() const override {
        return {{ static_cast<uint16_t>(nativeView.bounds.size.width),
            static_cast<uint16_t>(nativeView.bounds.size.height) }};
    }
    
    std::array<uint16_t, 2> getFramebufferSize() const override {
        NSRect bounds = [nativeView convertRectToBacking:nativeView.bounds];
        return {{ static_cast<uint16_t>(bounds.size.width),
            static_cast<uint16_t>(bounds.size.height) }};
    }
    
    void notify() override {}
    
    void notifyMapChange(mbgl::MapChange change) override {
        assert([[NSThread currentThread] isMainThread]);
        [nativeView notifyMapChange:change];
    }
    
    void activate() override {
        MGLOpenGLLayer *layer = (MGLOpenGLLayer *)nativeView.layer;
        if ([NSOpenGLContext currentContext] != layer.openGLContext) {
            [layer.openGLContext makeCurrentContext];
            
            mbgl::gl::InitializeExtensions([](const char *name) {
                static CFBundleRef framework = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.opengl"));
                if (!framework) {
                    throw std::runtime_error("Failed to load OpenGL framework.");
                }
                
                CFStringRef str = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII);
                void *symbol = CFBundleGetFunctionPointerForName(framework, str);
                CFRelease(str);
                
                return reinterpret_cast<mbgl::gl::glProc>(symbol);
            });
        }
    }
    
    void deactivate() override {
        [NSOpenGLContext clearCurrentContext];
    }
    
    void invalidate() override {
        [nativeView performSelectorOnMainThread:@selector(invalidate)
                                     withObject:nil
                                  waitUntilDone:NO];
    }
    
    void beforeRender() override {
        activate();
    }
    
    void afterRender() override {}
    
private:
    __weak MGLMapView *nativeView = nullptr;
    const float scaleFactor;
};

@end