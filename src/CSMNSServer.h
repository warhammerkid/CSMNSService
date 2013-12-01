#import <Foundation/Foundation.h>
#import "CSBluetoothOBEXSession.h"


@protocol CSMNSServerDelegate;


@interface CSMNSServer : NSObject <CSBluetoothOBEXSessionDelegate>

@property (nonatomic, assign) id<CSMNSServerDelegate> delegate;
@property (nonatomic, readonly, assign) BOOL isPublished;

- (BOOL)publishService;
- (void)unpublishService;

@end


@protocol CSMNSServerDelegate <NSObject>

@optional

- (void)mnsServer:(CSMNSServer *)server listeningToDevice:(IOBluetoothDevice *)device;
- (void)mnsServer:(CSMNSServer *)server receivedMessage:(NSString *)messageHandle fromDevice:(IOBluetoothDevice *)device;
- (void)mnsServer:(CSMNSServer *)server deviceDisconnected:(IOBluetoothDevice *)device;
- (void)mnsServer:(CSMNSServer *)server sessionError:(NSError *)error device:(IOBluetoothDevice *)device;

@end
