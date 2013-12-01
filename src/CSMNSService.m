#import "CSMNSService.h"


@interface CSMNSService ()
@property (nonatomic, retain) CSMNSServer *server;
@property (nonatomic, retain) NSMutableDictionary *masSessions;
@end


@implementation CSMNSService

- (id)init {
    self = [super init];
    if(self) {
        self.server = [[[CSMNSServer alloc] init] autorelease];
        self.server.delegate = self;
        self.masSessions = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - Server Side

- (BOOL)publishService {
    return [_server publishService];
}

- (void)unpublishService {
    [_server unpublishService];
}

- (void)mnsServer:(CSMNSServer *)server listeningToDevice:(IOBluetoothDevice *)device {
    if([_delegate respondsToSelector:@selector(mnsService:listeningToDevice:)]) {
        [_delegate mnsService:self listeningToDevice:device];
    }
}

- (void)mnsServer:(CSMNSServer *)server receivedMessage:(NSString *)messageHandle fromDevice:(IOBluetoothDevice *)device {
    NSLog(@"MNS: New message: %@", messageHandle);
    [[_masSessions objectForKey:device] loadMessage:messageHandle];
}

- (void)mnsServer:(CSMNSServer *)server deviceDisconnected:(IOBluetoothDevice *)device {
    NSLog(@"MNS: Received disconnect");
}

- (void)mnsServer:(CSMNSServer *)server sessionError:(NSError *)error device:(IOBluetoothDevice *)device {
    NSLog(@"MNS: Got an error event: %ld (%@)", error.code, device.nameOrAddress);
}

#pragma mark - Client Side

- (void)startListening:(IOBluetoothDevice *)device {
    [self startListening:device reconnect:NO];
}

- (void)startListening:(IOBluetoothDevice *)device reconnect:(BOOL)autoReconnect {
    // Get session for device
    CSMASSession *session = [_masSessions objectForKey:device];
    if(!session) {
        // Create session
        session = [[CSMASSession alloc] initWithDevice:device reconnect:autoReconnect];
        session.delegate = self;
        [_masSessions setObject:session forKey:device];
        [session release];
    }

    if(session.connectionId) {
        // Already connected - enable notifications
        [session setNotificationsEnabled:YES];
    } else {
        // Connect!
        [session connect];
    }
}

- (void)stopListening:(IOBluetoothDevice *)device {
    [[_masSessions objectForKey:device] setNotificationsEnabled:NO];
}

- (void)masSessionConnected:(CSMASSession *)session {
    // Now that we're connected, turn on notifications
    [session setNotificationsEnabled:YES];
}

- (void)masSession:(CSMASSession *)session connectionError:(NSError *)error {
    switch(error.code) {
        case kOBEXResponseCodeServiceUnavailableWithFinalBit:
            NSLog(@"MAS: Connection Error: Service Unavailable");
            break;
        case kOBEXResponseCodeBadRequestWithFinalBit:
            NSLog(@"MAS: Connection Error: Bad Request");
            break;
        case kOBEXResponseCodeForbiddenWithFinalBit:
            // On iOS, the user must turn on notifications for this device to not get this message
            NSLog(@"MAS: Connection Error: Forbidden");
            break;
        case kOBEXSessionTransportDiedError:
            NSLog(@"MAS: Could not connect");
            break;
        default:
            NSLog(@"MAS: Error on connect: %ld", error.code);
            break;
    }
}

- (void)masSessionNotificationsEnabled:(CSMASSession *)session {
    NSLog(@"MAS: Notifications enabled");
}

- (void)masSessionNotificationsDisabled:(CSMASSession *)session {
    // Disconnect, as there's no reason to maintain a connection if we aren't listening
    [session disconnect];
}

- (void)masSession:(CSMASSession *)session notificationsChangeError:(NSError *)error {
    NSLog(@"MAS: Error changing notification state: %ld", error.code);
}

- (void)masSession:(CSMASSession *)session message:(NSString *)messageHandle dataLoaded:(NSDictionary *)messageData {
    if([_delegate respondsToSelector:@selector(mnsService:messageReceived:)]) {
        [_delegate mnsService:self messageReceived:messageData];
    }
}

- (void)masSession:(CSMASSession *)session message:(NSString *)messageHandle loadError:(NSError *)error {
    NSLog(@"MAS: Error loading message: %ld", error.code);
}

- (void)masSessionDisconnected:(CSMASSession *)session {
    NSLog(@"MAS: Disconnect success");
}

- (void)masSession:(CSMASSession *)session disconnectionError:(NSError *)error {
    NSLog(@"MAS: Error on disconnect: %ld", error.code);
}

- (void)masSessionDeviceDisconnected:(CSMASSession *)session {
    NSLog(@"MAS: Client disconnected");
}

- (void)dealloc {
    [_server unpublishService];
    self.server = nil;
    self.masSessions = nil;

    [super dealloc];
}

@end
