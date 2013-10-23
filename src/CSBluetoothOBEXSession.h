#import <IOBluetooth/IOBluetooth.h>


@protocol CSBluetoothOBEXSessionDelegate;


@interface CSBluetoothOBEXSession : NSObject

@property (nonatomic, assign) id<CSBluetoothOBEXSessionDelegate> delegate;

- (IOBluetoothDevice *)getDevice;

// Server sessions
+ (IOBluetoothSDPServiceRecord *)publishService:(NSDictionary *)recordAttributes startHandler:(void (^)(CSBluetoothOBEXSession*))handler;
+ (void)unpublishService:(IOBluetoothSDPServiceRecord *)serviceRecord;
- (void)sendConnectResponse:(OBEXOpCode)responseCode headers:(NSDictionary *)headers;
- (void)sendPutContinueResponse;
- (void)sendPutSuccessResponse;

@end


@protocol CSBluetoothOBEXSessionDelegate
@required

- (void)OBEXSession:(CSBluetoothOBEXSession *)session receivedConnect:(NSDictionary *)headers;
- (void)OBEXSession:(CSBluetoothOBEXSession *)session receivedPut:(NSDictionary *)headers;
- (void)OBEXSession:(CSBluetoothOBEXSession *)session receivedDisconnect:(NSDictionary *)headers;
- (void)OBEXSession:(CSBluetoothOBEXSession *)session receivedError:(NSError *)error;

@end