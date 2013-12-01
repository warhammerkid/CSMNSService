#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import "CSMASSession.h"
#import "CSMNSServer.h"


@protocol CSMNSServiceDelegate;


@interface CSMNSService : NSObject <CSMNSServerDelegate, CSMASSessionDelegate>

@property (nonatomic, assign) id<CSMNSServiceDelegate> delegate;

- (void)startListening:(IOBluetoothDevice *)device;
- (void)startListening:(IOBluetoothDevice *)device reconnect:(BOOL)autoReconnect;
- (void)stopListening:(IOBluetoothDevice *)device;
- (void)stopListeningAll;

@end


@protocol CSMNSServiceDelegate <NSObject>

@optional

- (void)mnsService:(CSMNSService *)service listeningToDevice:(IOBluetoothDevice *)device;
- (void)mnsService:(CSMNSService *)service stoppedListeningToDevice:(IOBluetoothDevice *)device;
- (void)mnsService:(CSMNSService *)service messageReceived:(NSDictionary *)message;

@end