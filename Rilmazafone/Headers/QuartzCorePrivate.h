// Private headers extracted from QuartzCore 1193.39.8 (shipped with macOS 26.2)

#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - CABackdropLayer

@interface CABackdropLayer : CALayer

@property (getter=isEnabled) BOOL enabled;
@property (copy, nullable) NSString *groupName;
@property double scale;
@property double bleedAmount;
@property BOOL windowServerAware;
@property BOOL ignoresOffscreenGroups;
@property BOOL disablesOccludedBackdropBlurs;
@property BOOL allowsInPlaceFiltering;

@end

#pragma mark - CAFilter

@interface CAFilter : NSObject <NSCopying, NSMutableCopying, NSSecureCoding>

+ (nullable instancetype)filterWithName:(NSString *)name;

@property (copy, readonly) NSString *name;
@property (getter=isEnabled) BOOL enabled;
@property BOOL cachesInputImage;

@end

#pragma mark - CALayer Private Extensions

@interface CALayer (RilmazafonePrivate)

@property (nonatomic) BOOL allowsGroupBlending;
@property (nonatomic) BOOL allowsGroupOpacity;
@property (nonatomic) BOOL allowsEdgeAntialiasing;
@property (nonatomic) BOOL allowsInPlaceFiltering;

@end

NS_ASSUME_NONNULL_END
