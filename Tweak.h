#import <Foundation/Foundation.h>

@interface LAEvent : NSObject
- (instancetype)initWithName:(NSString *)name mode:(NSString *)mode;
- (NSString *)name;
- (NSString *)mode;
@end

@interface LAActivator : NSObject
+ (instancetype)sharedActivator;
- (void)registerListener:(id)listener forName:(NSString *)name;
- (id)eventWithName:(NSString *)name;
- (void)sendEventToListener:(LAEvent *)event forListenerName:(NSString *)name;
- (void)sendEventToListener:(LAEvent *)event;
- (BOOL)isListenerRegistered:(NSString *)name;
- (id)listenerForName:(NSString *)name;
- (NSArray *)eventNamesForListenerWithName:(NSString *)name;
@end
