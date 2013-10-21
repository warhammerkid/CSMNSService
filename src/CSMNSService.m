#import "CSMNSService.h"


@interface CSMNSService ()
@property (nonatomic, assign) IOBluetoothUserNotification *connectNotification;
@property (nonatomic, retain) NSMutableDictionary *mnsSessions;
@property (nonatomic, assign) CFMutableDataRef obexHeader;
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
       @"0004 - ProtocolDescriptorList": @[
           @[[IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16L2CAP]],
           @[
               [IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16RFCOMM],
               @{@"DataElementSize": @1, @"DataElementType": @1, @"DataElementValue": @10}
           ],
           @[[IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16OBEX]]
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
    IOBluetoothSDPServiceRecordRef serviceRecordRef;
    IOReturn err = IOBluetoothAddServiceDict((CFDictionaryRef)recordAttributes, &serviceRecordRef);
    if(err != kIOReturnSuccess) return NO;
    IOBluetoothSDPServiceRecord *serviceRecord = [IOBluetoothSDPServiceRecord withSDPServiceRecordRef:serviceRecordRef];
    if(!serviceRecord) {
        CFRelease(serviceRecordRef);
        return NO;
    }

    // Start listening for connections to the service
    BluetoothRFCOMMChannelID channelId;
    [serviceRecord getRFCOMMChannelID:&channelId];
    self.connectNotification = [IOBluetoothRFCOMMChannel registerForChannelOpenNotifications:self selector:@selector(serverConnectNotification:channel:) withChannelID:channelId direction:kIOBluetoothUserNotificationChannelDirectionIncoming];
    CFRelease(serviceRecordRef);

    return YES;
}

- (void)serverConnectNotification:(IOBluetoothUserNotification *)notification channel:(IOBluetoothRFCOMMChannel *)channel {
    IOBluetoothDevice *device = [channel getDevice];
    IOBluetoothOBEXSession *session = [IOBluetoothOBEXSession withIncomingRFCOMMChannel:channel eventSelector:@selector(serverOBEXEvent:) selectorTarget:self refCon:device];
    [_mnsSessions setObject:session forKey:device];
}

#define MNS_TARGET_HEADER_UUID "\xBB\x58\x2B\x41\x42\x0C\x11\xDB\xB0\xDE\x08\x00\x20\x0C\x9A\x66"
#define CONNECTION_ID "\xDE\xAD\xBE\xEF"
- (void)serverOBEXEvent:(const OBEXSessionEvent *)event {
    // Release old header data
    if(_obexHeader) CFRelease(_obexHeader);
    _obexHeader = nil;
    
    // Get the IOBluetoothOBEXSession object for the event
    IOBluetoothDevice *device = event->refCon;
    IOBluetoothOBEXSession *session = [_mnsSessions objectForKey:device];

    // Build a response
    CFMutableDictionaryRef outHeaders = nil;
    CFDictionaryRef inHeaders = nil;
    switch(event->type) {
        case kOBEXSessionEventTypeConnectCommandReceived:
            inHeaders = OBEXGetHeaders(event->u.connectCommandData.headerDataPtr, event->u.connectCommandData.headerDataLength);
            NSLog(@"MNS: Received connect command: %@", inHeaders);
            CFRelease(inHeaders);
            outHeaders = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFCopyStringDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            OBEXAddConnectionIDHeader(CONNECTION_ID, 4, outHeaders);
            OBEXAddWhoHeader(MNS_TARGET_HEADER_UUID, 16, outHeaders);
            self.obexHeader = OBEXHeadersToBytes(outHeaders);
            [session OBEXConnectResponse:kOBEXResponseCodeSuccessWithFinalBit flags:0 maxPacketLength:event->u.connectCommandData.maxPacketSize optionalHeaders:CFDataGetMutableBytePtr(_obexHeader) optionalHeadersLength:CFDataGetLength(_obexHeader) eventSelector:@selector(serverOBEXEvent:) selectorTarget:self refCon:device];
            CFRelease(outHeaders);
            break;
        case kOBEXSessionEventTypePutCommandReceived:
            inHeaders = OBEXGetHeaders(event->u.putCommandData.headerDataPtr, event->u.putCommandData.headerDataLength);
            NSString *body = [[NSString alloc] initWithData:(NSData *)CFDictionaryGetValue(inHeaders, kOBEXHeaderIDKeyEndOfBody) encoding:NSUTF8StringEncoding];
            [self serverMAPEvent:body device:device];
            [body release];
            CFRelease(inHeaders);
            [session OBEXPutResponse:kOBEXResponseCodeSuccessWithFinalBit optionalHeaders:nil optionalHeadersLength:0 eventSelector:@selector(serverOBEXEvent:) selectorTarget:self refCon:device];
            break;
        case kOBEXSessionEventTypeAbortCommandReceived:
            NSLog(@"MNS: Got an abort command...");
            break;
        case kOBEXSessionEventTypeDisconnectCommandReceived:
            NSLog(@"MNS: Received disconnect");
            [_mnsSessions removeObjectForKey:device];
            break;
        case kOBEXSessionEventTypeError:
            NSLog(@"MNS: Got an error event: %d", event->u.errorData.error);
            break;
        default:
            NSLog(@"MNS: Invalid command type");
            break;
    }
}

- (void)serverMAPEvent:(NSString *)body device:(IOBluetoothDevice *)device {
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithXMLString:body options:0 error:nil];
    NSArray *newMessageHandles = [doc nodesForXPath:@".//event[@type='NewMessage']/@handle" error:nil];
    if([newMessageHandles count] > 0) {
        NSString *handle = [[newMessageHandles objectAtIndex:0] stringValue];
        NSLog(@"MNS: New message: %@", handle);
        [[_masSessions objectForKey:device] loadMessage:handle];
    }
    [doc release];
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
    [self.connectNotification unregister];
    self.mnsSessions = nil;
    if(self.obexHeader) CFRelease(self.obexHeader);
    self.masSessions = nil;

    [super dealloc];
}

@end
