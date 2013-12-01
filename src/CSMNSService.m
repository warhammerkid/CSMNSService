#import "CSMNSService.h"


@interface CSMNSService ()
@property (nonatomic, retain) CSMNSServer *server;
@property (nonatomic, retain) NSMutableDictionary *oneTimeSessions;
@property (nonatomic, retain) NSMutableDictionary *autoReconnectSessions;
@property (nonatomic, retain) NSTimer *reconnectTimer;
@end


@implementation CSMNSService

- (id)init {
    self = [super init];
    if(self) {
        self.server = [[[CSMNSServer alloc] init] autorelease];
        self.server.delegate = self;
        self.oneTimeSessions = [NSMutableDictionary dictionary];
        self.autoReconnectSessions = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - Server Side API

- (BOOL)publishService {
    return [_server publishService];
}

- (void)unpublishService {
    [_server unpublishService];
}

#pragma mark - CSMNSServer Delegate Methods

- (void)mnsServer:(CSMNSServer *)server listeningToDevice:(IOBluetoothDevice *)device {
    if([_delegate respondsToSelector:@selector(mnsService:listeningToDevice:)]) {
        [_delegate mnsService:self listeningToDevice:device];
    }
}

- (void)mnsServer:(CSMNSServer *)server receivedMessage:(NSString *)messageHandle fromDevice:(IOBluetoothDevice *)device {
    NSLog(@"MNS: New message: %@", messageHandle);
    [[self sessionForDevice:device] loadMessage:messageHandle];
}

- (void)mnsServer:(CSMNSServer *)server deviceDisconnected:(IOBluetoothDevice *)device {
    NSLog(@"MNS: Received disconnect");
}

- (void)mnsServer:(CSMNSServer *)server sessionError:(NSError *)error device:(IOBluetoothDevice *)device {
    NSLog(@"MNS: Got an error event: %ld (%@)", error.code, device.nameOrAddress);
}

#pragma mark - Client Side API

- (void)startListening:(IOBluetoothDevice *)device {
    [self startListening:device reconnect:NO];
}

- (void)startListening:(IOBluetoothDevice *)device reconnect:(BOOL)autoReconnect {
    // Get session for device
    CSMASSession *session = [self sessionForDevice:device];
    if(!session) {
        // Create session
        session = [[CSMASSession alloc] initWithDevice:device];
        session.delegate = self;
        if(autoReconnect) [_autoReconnectSessions setObject:session forKey:device];
        else [_oneTimeSessions setObject:session forKey:device];
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
    [[self sessionForDevice:device] setNotificationsEnabled:NO];
}

#pragma mark - CSMASSession Delegate Methods

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
    [self removeSession:session reconnect:NO];
}

- (void)masSession:(CSMASSession *)session disconnectionError:(NSError *)error {
    NSLog(@"MAS: Error on disconnect: %ld", error.code);
    [self removeSession:session reconnect:NO];
}

- (void)masSessionDeviceDisconnected:(CSMASSession *)session {
    NSLog(@"MAS: Client disconnected");
    [self removeSession:session reconnect:YES];
}

#pragma mark - Client Side Helpers

- (CSMASSession *)sessionForDevice:(IOBluetoothDevice *)device {
    CSMASSession *session = [_oneTimeSessions objectForKey:device];
    if(session) return session;
    session = [_autoReconnectSessions objectForKey:device];
    return session;
}

- (void)removeSession:(CSMASSession *)session reconnect:(BOOL)doReconnect {
    IOBluetoothDevice *device = session.device;
    [_oneTimeSessions removeObjectForKey:device];
    if(doReconnect && [_autoReconnectSessions objectForKey:device]) {
        NSLog(@"MAS: Automatically reconnecting to '%@' when it's in range", device.nameOrAddress);
        [self scheduleAutoReconnect];
    } else {
        [_autoReconnectSessions removeObjectForKey:device];
    }
}

- (void)scheduleAutoReconnect {
    if(!_reconnectTimer) {
        self.reconnectTimer = [NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(attemptAutoReconnect) userInfo:nil repeats:YES];
    }
}

- (void)attemptAutoReconnect {
    BOOL disconnectedSessions = NO;

    // Go though auto reconnect sessions
    for(IOBluetoothDevice *device in _autoReconnectSessions) {
        CSMASSession *session = [_autoReconnectSessions objectForKey:device];
        if(session.connectionId) continue;
        disconnectedSessions = YES;
        NSLog(@"MAS: Attempting to reconnect to '%@'", device.nameOrAddress);
        [session connect];
    }

    // Stop auto-reconnect timer if no sessions disconnected
    if(!disconnectedSessions) {
        [_reconnectTimer invalidate];
        self.reconnectTimer = nil;
    }
}

#pragma mark - Memory Management

- (void)dealloc {
    [_server unpublishService];
    self.server = nil;
    self.oneTimeSessions = nil;
    self.autoReconnectSessions = nil;
    [_reconnectTimer invalidate];
    self.reconnectTimer = nil;

    [super dealloc];
}

@end
