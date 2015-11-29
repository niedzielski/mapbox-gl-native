#import "MGLMultiPoint_Private.h"
#import "MGLGeometry.h"

#import <mbgl/util/geo.hpp>

mbgl::Color MGLColorObjectFromCGColorRef(CGColorRef cgColor) {
    if (!cgColor) {
        return {{ 0, 0, 0, 0 }};
    }
    NSCAssert(CGColorGetNumberOfComponents(cgColor) >= 4, @"Color must have at least 4 components");
    const CGFloat *components = CGColorGetComponents(cgColor);
    return {{ (float)components[0], (float)components[1], (float)components[2], (float)components[3] }};
}

@implementation MGLMultiPoint
{
    CLLocationCoordinate2D *_coords;
    size_t _count;
    mbgl::LatLngBounds _bounds;
}

- (instancetype)initWithCoordinates:(CLLocationCoordinate2D *)coords
                              count:(NSUInteger)count
{
    self = [super init];

    if (self)
    {
        _count = count;
        _coords = (CLLocationCoordinate2D *)malloc(_count * sizeof(CLLocationCoordinate2D));
        _bounds = mbgl::LatLngBounds::getExtendable();

        for (NSUInteger i = 0; i < _count; i++)
        {
            _coords[i] = coords[i];
            _bounds.extend(mbgl::LatLng(coords[i].latitude, coords[i].longitude));
        }
    }

    return self;
}

- (void)dealloc
{
    free(_coords);
}

- (CLLocationCoordinate2D)coordinate
{
    if ([self isMemberOfClass:[MGLMultiPoint class]])
    {
        [[NSException exceptionWithName:@"MGLAbstractClassException"
                                 reason:@"MGLMultiPoint is an abstract class"
                               userInfo:nil] raise];
    }

    assert(_count > 0);

    return CLLocationCoordinate2DMake(_coords[0].latitude, _coords[0].longitude);
}

- (NSUInteger)pointCount
{
    if ([self isMemberOfClass:[MGLMultiPoint class]])
    {
        [[NSException exceptionWithName:@"MGLAbstractClassException"
                                 reason:@"MGLMultiPoint is an abstract class"
                               userInfo:nil] raise];
    }

    return _count;
}

- (void)getCoordinates:(CLLocationCoordinate2D *)coords range:(NSRange)range
{
    if ([self isMemberOfClass:[MGLMultiPoint class]])
    {
        [[NSException exceptionWithName:@"MGLAbstractClassException"
                                 reason:@"MGLMultiPoint is an abstract class"
                               userInfo:nil] raise];
    }

    assert(range.location + range.length <= _count);

    NSUInteger index = 0;

    for (NSUInteger i = range.location; i < range.location + range.length; i++)
    {
        coords[index] = _coords[i];
        index++;
    }
}

- (MGLCoordinateBounds)overlayBounds
{
    return {
        CLLocationCoordinate2DMake(_bounds.sw.latitude,  _bounds.sw.longitude),
        CLLocationCoordinate2DMake(_bounds.ne.latitude, _bounds.ne.longitude)
    };
}

- (BOOL)intersectsOverlayBounds:(MGLCoordinateBounds)overlayBounds
{
    mbgl::LatLngBounds area(
        mbgl::LatLng(overlayBounds.sw.latitude, overlayBounds.sw.longitude),
        mbgl::LatLng(overlayBounds.ne.latitude, overlayBounds.ne.longitude)
    );

    return _bounds.intersects(area);
}

- (void)addShapeAnnotationObjectToCollection:(std::vector<mbgl::ShapeAnnotation> &)shapes withDelegate:(id <MGLMultiPointDelegate>)delegate {
    NSUInteger count = self.pointCount;
    if (count == 0) {
        return;
    }
    
    CLLocationCoordinate2D *coordinates = (CLLocationCoordinate2D *)malloc(count * sizeof(CLLocationCoordinate2D));
    NSAssert(coordinates, @"Unable to allocate annotation with %lu points", (unsigned long)count);
    [self getCoordinates:coordinates range:NSMakeRange(0, count)];
    
    mbgl::AnnotationSegment segment;
    segment.reserve(count);
    for (NSUInteger i = 0; i < count; i++) {
        segment.push_back(mbgl::LatLng(coordinates[i].latitude, coordinates[i].longitude));
    }
    free(coordinates);
    shapes.emplace_back(mbgl::AnnotationSegments {{ segment }},
                        [self shapeAnnotationPropertiesObjectWithDelegate:delegate]);
}

- (mbgl::ShapeAnnotation::Properties)shapeAnnotationPropertiesObjectWithDelegate:(__unused id <MGLMultiPointDelegate>)delegate {
    return mbgl::ShapeAnnotation::Properties();
}

@end
