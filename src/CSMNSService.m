#import "CSMNSService.h"


@interface CSMNSService ()
@property (nonatomic, retain) IOBluetoothSDPServiceRecord *sdpRecord;
@property (nonatomic, retain) NSMutableDictionary *mnsSessions;
@property (nonatomic, retain) NSMutableDictionary *masSessions;
@end


@implementation CSMNSService

- (id)init {
    self = [super init];
    if(self) {
        self.mnsSessions = [NSMutableDictionary dictionary];
        self.masSessions = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - Server Side

- (BOOL)publishService {
    // Build SDP record attributes
    NSDictionary *recordAttributes = @{
       @"0001 - ServiceClassIDList": @[
           [IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16ServiceClassMessageNotificationServer]
       ],
       @"0009 - BluetoothProfileDescriptorList": @[
           @[
               [IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16ServiceClassMessageAccessProfile],
               @(0x100) // v1.0
           ]
       ],
       @"0100 - ServiceName*": @"CSMNSService"
    };

    // Publish SDP record
    _sdpRecord = [[CSBluetoothOBEXSession publishService:recordAttributes startHandler:^(CSBluetoothOBEXSession *session) {
        session.delegate = self;
        [_mnsSessions setObject:session forKey:[session getDevice]];
    }] retain];

    return !!_sdpRecord;
}

#define MNS_TARGET_HEADER_UUID "\xBB\x58\x2B\x41\x42\x0C\x11\xDB\xB0\xDE\x08\x00\x20\x0C\x9A\x66"
#define CONNECTION_ID "\xDE\xAD\xBE\xEF"
- (void)OBEXSession:(CSBluetoothOBEXSession *)session receivedConnect:(NSDictionary *)headers {
    NSLog(@"MNS: Received connect command: %@", headers);
    [session sendConnectResponse:kOBEXResponseCodeSuccessWithFinalBit headers:@{
        (id)kOBEXHeaderIDKeyConnectionID: [NSData dataWithBytesNoCopy:CONNECTION_ID length:4 freeWhenDone:NO],
        (id)kOBEXHeaderIDKeyWho: [NSData dataWithBytesNoCopy:MNS_TARGET_HEADER_UUID length:16 freeWhenDone:NO]
    }];
}

- (void)OBEXSession:(CSBluetoothOBEXSession *)session receivedPut:(NSDictionary *)headers {
    NSData *endOfBody = headers[(id)kOBEXHeaderIDKeyEndOfBody];
    if(endOfBody) {
        NSString *body = [[NSString alloc] initWithData:endOfBody encoding:NSUTF8StringEncoding];
        NSXMLDocument *doc = [[NSXMLDocument alloc] initWithXMLString:body options:0 error:nil];
        NSArray *newMessageHandles = [doc nodesForXPath:@".//event[@type='NewMessage']/@handle" error:nil];
        if([newMessageHandles count] > 0) {
            NSString *handle = [[newMessageHandles objectAtIndex:0] stringValue];
            NSLog(@"MNS: New message: %@", handle);
            [[_masSessions objectForKey:[session getDevice]] loadMessage:handle];
        }
        [doc release];
        [body release];

        [session sendPutSuccessResponse];
    } else {
        [session sendPutContinueResponse];
    }
}

- (void)OBEXSession:(CSBluetoothOBEXSession *)session receivedDisconnect:(NSDictionary *)headers {
    NSLog(@"MNS: Received disconnect");
    [_mnsSessions removeObjectForKey:[session getDevice]];
}

- (void)OBEXSession:(CSBluetoothOBEXSession *)session receivedError:(NSError *)error {
    NSLog(@"MNS: Got an error event: %ld", error.code);
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
    self.mnsSessions = nil;
    self.masSessions = nil;

    [super dealloc];
}

@end
