#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>


@protocol CSMASSessionDelegate;


@interface CSMASSession : NSObject

@property (nonatomic, assign, readonly) BOOL autoReconnect;
@property (nonatomic, retain, readonly) IOBluetoothDevice *device;
@property (nonatomic, retain, readonly) NSData *connectionId;
@property (nonatomic, assign) id<CSMASSessionDelegate> delegate;

- (id)initWithDevice:(IOBluetoothDevice *)device reconnect:(BOOL)autoReconnect;
- (void)connect;
- (void)setNotificationsEnabled:(BOOL)enabled;
- (void)loadMessage:(NSString *)messageHandle;
- (void)disconnect;

@end


@protocol CSMASSessionDelegate <NSObject>

@optional

- (void)masSessionConnected:(CSMASSession *)session;
- (void)masSessionNotificationsEnabled:(CSMASSession *)session;
- (void)masSessionNotificationsDisabled:(CSMASSession *)session;
- (void)masSession:(CSMASSession *)session messageDataLoaded:(NSDictionary *)messageData;
- (void)masSessionDisconnected:(CSMASSession *)session;

@end