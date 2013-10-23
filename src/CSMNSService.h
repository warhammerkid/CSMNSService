#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import "CSMASSession.h"
#import "CSBluetoothOBEXSession.h"


@protocol CSMNSServiceDelegate;


@interface CSMNSService : NSObject <CSMASSessionDelegate, CSBluetoothOBEXSessionDelegate>

@property (nonatomic, assign) id<CSMNSServiceDelegate> delegate;

- (BOOL)publishService;
- (void)startListening:(IOBluetoothDevice *)device;
- (void)startListening:(IOBluetoothDevice *)device reconnect:(BOOL)autoReconnect;
- (void)stopListening:(IOBluetoothDevice *)device;

@end


@protocol CSMNSServiceDelegate <NSObject>

@optional

- (void)mnsService:(CSMNSService *)service messageReceived:(NSDictionary *)message;

@end