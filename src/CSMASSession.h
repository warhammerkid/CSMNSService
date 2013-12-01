#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>


@protocol CSMASSessionDelegate;


@interface CSMASSession : NSObject

@property (nonatomic, retain, readonly) IOBluetoothDevice *device;
@property (nonatomic, retain, readonly) NSData *connectionId;
@property (nonatomic, assign) id<CSMASSessionDelegate> delegate;

- (id)initWithDevice:(IOBluetoothDevice *)device;
- (void)connect;
- (void)setNotificationsEnabled:(BOOL)enabled;
- (void)loadMessage:(NSString *)messageHandle;
- (void)disconnect;

@end


@protocol CSMASSessionDelegate <NSObject>

@optional

- (void)masSessionConnected:(CSMASSession *)session;
- (void)masSession:(CSMASSession *)session connectionError:(NSError *)error;
- (void)masSessionNotificationsEnabled:(CSMASSession *)session;
- (void)masSessionNotificationsDisabled:(CSMASSession *)session;
- (void)masSession:(CSMASSession *)session notificationsChangeError:(NSError *)error;
- (void)masSession:(CSMASSession *)session message:(NSString *)messageHandle dataLoaded:(NSDictionary *)messageData;
- (void)masSession:(CSMASSession *)session message:(NSString *)messageHandle loadError:(NSError *)error;
- (void)masSessionDisconnected:(CSMASSession *)session;
- (void)masSession:(CSMASSession *)session disconnectionError:(NSError *)error;
- (void)masSessionDeviceDisconnected:(CSMASSession *)session;

@end