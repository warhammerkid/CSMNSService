#import "CSMASSession.h"
#import "CSBluetoothOBEXSession.h"


@interface CSMASSession ()
@property (nonatomic, retain) CSBluetoothOBEXSession *session;
@property (nonatomic, assign) IOBluetoothUserNotification *disconnectNotification;
@property (nonatomic, retain) NSTimer *reconnectTimer;
@end


@implementation CSMASSession

- (id)initWithDevice:(IOBluetoothDevice *)device reconnect:(BOOL)autoReconnect {
    self = [super init];
    if(self) {
        _device = [device retain];
        _autoReconnect = autoReconnect;
    }
    return self;
}

#define MAS_TARGET_HEADER_UUID "\xBB\x58\x2B\x40\x42\x0C\x11\xDB\xB0\xDE\x08\x00\x20\x0C\x9A\x66"
- (void)connect {
    IOBluetoothSDPServiceRecord *record = [_device getServiceRecordForUUID:[IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16ServiceClassMessageAccessServer]];
    [_session release];
    _session = [[CSBluetoothOBEXSession alloc] initWithSDPServiceRecord:record];

    [_session sendConnect:@{
        (id)kOBEXHeaderIDKeyTarget: [NSData dataWithBytesNoCopy:MAS_TARGET_HEADER_UUID length:16 freeWhenDone:NO]
    } handler:^(CSBluetoothOBEXSession *session, NSDictionary *headers, NSError *error) {
        if(error) {
            if([_delegate respondsToSelector:@selector(masSession:connectionError:)]) {
                [_delegate masSession:self connectionError:error];
            }
        } else {
            // Get connection id
            [_connectionId release];
            _connectionId = [headers[(id)kOBEXHeaderIDKeyConnectionID] retain];

            // Register for disconnect
            _disconnectNotification = [_device registerForDisconnectNotification:self selector:@selector(disconnectedNotification:device:)];

            // Disable reconnect timer if it's running
            [_reconnectTimer invalidate];
            [_reconnectTimer release];
            _reconnectTimer = nil;

            // Notify delegate
            if([_delegate respondsToSelector:@selector(masSessionConnected:)]) {
                [_delegate masSessionConnected:self];
            }
        }
    }];
}

- (void)attemptAutoReconnect {
    if(_connectionId) {
        NSLog(@"MAS: Did not expect to receive auto-reconnect tick when already connected");
        [_reconnectTimer invalidate];
        [_reconnectTimer release];
        _reconnectTimer = nil;
    } else {
        NSLog(@"MAS: Attempting to reconnect to '%@'", _device.nameOrAddress);
        [self connect];
    }
}

- (void)setNotificationsEnabled:(BOOL)enabled {
    if(!_connectionId) return;
    
    NSMutableData *emptyBody = [NSMutableData dataWithBytes:"\x30" length:1];
    NSData *appParams = [NSData dataWithBytesNoCopy:(enabled ? "\x0E\x01\x01" : "\x0E\x01\x00") length:3 freeWhenDone:NO];
    [_session sendPut:@{
        (id)kOBEXHeaderIDKeyConnectionID: _connectionId,
        (id)kOBEXHeaderIDKeyType: @"x-bt/MAP-NotificationRegistration",
        (id)kOBEXHeaderIDKeyAppParameters: appParams
    } body:emptyBody handler:^(CSBluetoothOBEXSession *session, NSDictionary *headers, NSError *error) {
        if(error) {
            if([_delegate respondsToSelector:@selector(masSession:notificationsChangeError:)]) {
                [_delegate masSession:self notificationsChangeError:error];
            }
        } else if(enabled) {
            if([_delegate respondsToSelector:@selector(masSessionNotificationsEnabled:)]) {
                [_delegate masSessionNotificationsEnabled:self];
            }
        } else {
            if([_delegate respondsToSelector:@selector(masSessionNotificationsDisabled:)]) {
                [_delegate masSessionNotificationsDisabled:self];
            }
        }
    }];
}

- (void)loadMessage:(NSString *)messageHandle {
    if(!_connectionId) return;

    [_session sendGet:@{
        (id)kOBEXHeaderIDKeyConnectionID: _connectionId,
        (id)kOBEXHeaderIDKeyType: @"x-bt/message",
        (id)kOBEXHeaderIDKeyName: messageHandle,
        (id)kOBEXHeaderIDKeyAppParameters: [NSData dataWithBytesNoCopy:"\x0A\x01\x00\x14\x01\x01" length:6 freeWhenDone:NO] // Attachment Off & Charset UTF-8
    } handler:^(CSBluetoothOBEXSession *session, NSDictionary *headers, NSError *error) {
        if(error) {
            if([_delegate respondsToSelector:@selector(masSession:message:loadError:)]) {
                [_delegate masSession:self message:messageHandle loadError:error];
            }
        } else {
            NSString *body = [[NSString alloc] initWithData:headers[(id)kOBEXHeaderIDKeyEndOfBody] encoding:NSUTF8StringEncoding];
            if([_delegate respondsToSelector:@selector(masSession:message:dataLoaded:)]) {
                NSDictionary *message = [self parseMessageBody:body];
                [_delegate masSession:self message:messageHandle dataLoaded:message];
            }
            [body release];
        }
    }];
}

- (NSDictionary *)parseMessageBody:(NSString *)body {
    // Parse out message
    NSRange messageStart = [body rangeOfString:@"\r\nBEGIN:MSG\r\n"];
    NSRange messageEnd = [body rangeOfString:@"\r\nEND:MSG\r\n" options:NSBackwardsSearch];
    NSUInteger start = messageStart.location+messageStart.length;
    NSString *messageText = [body substringWithRange:NSMakeRange(start, messageEnd.location - start)];
    
    return @{@"rawMessage": body, @"body": messageText};
}

- (void)disconnect {
    [_session sendDisconnect:@{
        (id)kOBEXHeaderIDKeyConnectionID: _connectionId
    } handler:^(CSBluetoothOBEXSession *session, NSDictionary *headers, NSError *error) {
        if(error) {
            if([_delegate respondsToSelector:@selector(masSession:disconnectionError:)]) {
                [_delegate masSession:self disconnectionError:error];
            }
        } else {
            [self handleDisconnect];
            if([_delegate respondsToSelector:@selector(masSessionDisconnected:)]) {
                [_delegate masSessionDisconnected:self];
            }
        }
    }];
}

- (void)disconnectedNotification:(IOBluetoothUserNotification *)notification device:(IOBluetoothDevice *)device {
    [self handleDisconnect];
    if([_delegate respondsToSelector:@selector(masSessionDeviceDisconnected:)]) {
        [_delegate masSessionDeviceDisconnected:self];
    }

    if(_autoReconnect) {
        NSLog(@"MAS: Automatically reconnecting to '%@' when it's in range", _device.nameOrAddress);
        _reconnectTimer = [[NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(attemptAutoReconnect) userInfo:nil repeats:YES] retain];
    }
}

- (void)handleDisconnect {
    [_disconnectNotification unregister];
    _disconnectNotification = nil;
    [_connectionId release];
    _connectionId = nil;
    [_session release];
    _session = nil;
}

- (void)dealloc {
    [_disconnectNotification unregister];
    [_device release];
    [_session release];
    [_connectionId release];
    [_reconnectTimer invalidate];
    [_reconnectTimer release];
    
    
    [super dealloc];
}

@end
