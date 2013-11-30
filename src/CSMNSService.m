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
    [[_masSessions objectForKey:device] loadMessage:messageHandle];
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

- (void)masSessionNotificationsDisabled:(CSMASSession *)session {
    // Disconnect, as there's no reason to maintain a connection if we aren't listening
    [session disconnect];
}

- (void)masSession:(CSMASSession *)session messageDataLoaded:(NSDictionary *)messageData {
    if([_delegate respondsToSelector:@selector(mnsService:messageReceived:)]) {
        [_delegate mnsService:self messageReceived:messageData];
    }
}

- (void)dealloc {
    [_server unpublishService];
    self.server = nil;
    self.masSessions = nil;

    [super dealloc];
}

@end
