#import "../osx/MGLAccountManager_Private.h"

#import <mbgl/osx/MGLMapView.h>

#import "NSBundle+MGLAdditions.h"
#import "../darwin/NSString+MGLAdditions.h"

@interface MGLAccountManager ()

@property (atomic) NSString *accessToken;

@end

@implementation MGLAccountManager

#pragma mark - Internal

+ (void)load {
    mgl_linkBundleCategory();
    mgl_linkStringCategory();
    
    [MGLMapView restorableStateKeyPaths];
    
    // Read the initial configuration from Info.plist.
    NSString *accessToken = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"MGLMapboxAccessToken"];
    if (accessToken.length) {
        self.accessToken = accessToken;
    }
}

// Can be called from any thread.
//
+ (instancetype)sharedManager {
    static dispatch_once_t onceToken;
    static MGLAccountManager *_sharedManager;
    void (^setupBlock)() = ^{
        dispatch_once(&onceToken, ^{
            _sharedManager = [[self alloc] init];
        });
    };
    if (![[NSThread currentThread] isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            setupBlock();
        });
    }
    else {
        setupBlock();
    }
    return _sharedManager;
}

+ (void)setAccessToken:(NSString *)accessToken {
    accessToken = [accessToken stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![accessToken length]) return;
    
    [MGLAccountManager sharedManager].accessToken = accessToken;
}

+ (NSString *)accessToken {
    return [MGLAccountManager sharedManager].accessToken;
}

@end
