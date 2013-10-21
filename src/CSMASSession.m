#import "CSMASSession.h"


@interface CSMASSession ()
@property (nonatomic, retain) IOBluetoothOBEXSession *session;
@property (nonatomic, assign) CFMutableDataRef obexHeader;
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
    _session = [[IOBluetoothOBEXSession alloc] initWithSDPServiceRecord:record];

    CFMutableDictionaryRef headers = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFCopyStringDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    OBEXAddTargetHeader(MAS_TARGET_HEADER_UUID, 16, headers);
    _obexHeader = OBEXHeadersToBytes(headers);
    CFRelease(headers);
    [_session OBEXConnect:kOBEXConnectFlagNone maxPacketLength:4096 optionalHeaders:CFDataGetMutableBytePtr(_obexHeader) optionalHeadersLength:CFDataGetLength(_obexHeader) eventSelector:@selector(connectEvent:) selectorTarget:self refCon:nil];
}

- (void)connectEvent:(const OBEXSessionEvent *)event {
    // Release header data
    CFRelease(_obexHeader);
    _obexHeader = nil;
    
    // Handle response
    if(event->type == kOBEXSessionEventTypeError) {
        NSLog(@"MAS: OBEX error on connect: %d", event->u.errorData.error);
    } else {
        OBEXConnectCommandResponseData response = event->u.connectCommandResponseData;
        CFDictionaryRef headers;
        switch(response.serverResponseOpCode) {
            case kOBEXResponseCodeSuccessWithFinalBit:
                headers = OBEXGetHeaders(response.headerDataPtr, response.headerDataLength);
                [_connectionId release];
                _connectionId = CFRetain(CFDictionaryGetValue(headers, kOBEXHeaderIDKeyConnectionID));
                CFRelease(headers);
                break;
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
            default:
                NSLog(@"MAS: Unhandled response code on connect: %d", response.serverResponseOpCode);
                break;
        }
    }
    
    // We are successfully connected!
    if(_connectionId) {
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

    SEL eventSelector;
    char *appParamHeader;
    if(enabled) {
        eventSelector = @selector(notificationsEnabledEvent:);
        appParamHeader = "\x0E\x01\x01";
    } else {
        eventSelector = @selector(notificationsDisabledEvent:);
        appParamHeader = "\x0E\x01\x00";
    }
    
    CFMutableDictionaryRef headers = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFCopyStringDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    OBEXAddConnectionIDHeader([_connectionId bytes], (uint32_t)[_connectionId length], headers);
    OBEXAddTypeHeader(CFSTR("x-bt/MAP-NotificationRegistration"), headers);
    OBEXAddApplicationParameterHeader(appParamHeader, 3, headers);
    _obexHeader = OBEXHeadersToBytes(headers);
    CFRelease(headers);
    [_session OBEXPut:YES headersData:CFDataGetMutableBytePtr(_obexHeader) headersDataLength:CFDataGetLength(_obexHeader) bodyData:"\x30" bodyDataLength:1 eventSelector:eventSelector selectorTarget:self refCon:nil];
}

- (void)notificationsEnabledEvent:(const OBEXSessionEvent *)event {
    NSLog(@"MAS: Notifications enabled");
    CFRelease(_obexHeader);
    _obexHeader = nil;
    
    if([_delegate respondsToSelector:@selector(masSessionNotificationsEnabled:)]) {
        [_delegate masSessionNotificationsEnabled:self];
    }
}

- (void)notificationsDisabledEvent:(const OBEXSessionEvent *)event {
    CFRelease(_obexHeader);
    _obexHeader = nil;
    
    if([_delegate respondsToSelector:@selector(masSessionNotificationsDisabled:)]) {
        [_delegate masSessionNotificationsDisabled:self];
    }
}

- (void)loadMessage:(NSString *)messageHandle {
    CFMutableDictionaryRef headers = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFCopyStringDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    OBEXAddConnectionIDHeader([self.connectionId bytes], (uint32_t)[self.connectionId length], headers);
    OBEXAddNameHeader((CFStringRef)messageHandle, headers);
    OBEXAddTypeHeader(CFSTR("x-bt/message"), headers);
    OBEXAddApplicationParameterHeader("\x0A\x01\x00", 3, headers); // Attachment Off
    OBEXAddApplicationParameterHeader("\x14\x01\x01", 3, headers); // Charset UTF-8
    _obexHeader = OBEXHeadersToBytes(headers);
    CFRelease(headers);
    [_session OBEXGet:YES headers:CFDataGetMutableBytePtr(_obexHeader) headersLength:CFDataGetLength(_obexHeader) eventSelector:@selector(messageLoadEvent:) selectorTarget:self refCon:nil];
}

- (void)messageLoadEvent:(const OBEXSessionEvent *)event {
    // Release header data
    CFRelease(_obexHeader);
    _obexHeader = nil;
    
    // Handle response
    if(event->type == kOBEXSessionEventTypeError) {
        NSLog(@"MAS: OBEX error on load message: %d", event->u.errorData.error);
    } else {
        OBEXOpCode responseCode = event->u.getCommandResponseData.serverResponseOpCode;
        if(responseCode == kOBEXResponseCodeSuccessWithFinalBit) {
            CFDictionaryRef headers = OBEXGetHeaders(event->u.getCommandResponseData.headerDataPtr, event->u.getCommandResponseData.headerDataLength);
            NSString *body = [[NSString alloc] initWithData:(NSData *)CFDictionaryGetValue(headers, kOBEXHeaderIDKeyEndOfBody) encoding:NSUTF8StringEncoding];
            if([_delegate respondsToSelector:@selector(masSession:messageDataLoaded:)]) {
                NSDictionary *message = [self parseMessageBody:body];
                [_delegate masSession:self messageDataLoaded:message];
            }
            [body release];
            CFRelease(headers);
        } else {
            NSLog(@"MAS: Unhandled response code on message load: %d", responseCode);
        }
    }
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
    CFMutableDictionaryRef headers = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFCopyStringDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    OBEXAddConnectionIDHeader([_connectionId bytes], (uint32_t)[_connectionId length], headers);
    _obexHeader = OBEXHeadersToBytes(headers);
    CFRelease(headers);
    [_session OBEXDisconnect:CFDataGetMutableBytePtr(_obexHeader) optionalHeadersLength:CFDataGetLength(_obexHeader) eventSelector:@selector(disconnectEvent:) selectorTarget:self refCon:nil];
}

- (void)disconnectEvent:(const OBEXSessionEvent *)event {
    // Release header data
    CFRelease(_obexHeader);
    _obexHeader = nil;
    
    // Handle response
    if(event->type == kOBEXSessionEventTypeError) {
        NSLog(@"MAS: OBEX error on disconnect: %d", event->u.errorData.error);
    } else {
        OBEXOpCode responseCode = event->u.disconnectCommandResponseData.serverResponseOpCode;
        if(responseCode == kOBEXResponseCodeSuccessWithFinalBit) {
            NSLog(@"MAS: Disconnect success");
            [self handleDisconnect];
        } else {
            NSLog(@"MAS: Unhandled response code on disconnect: %d", responseCode);
        }
    }
}

- (void)disconnectedNotification:(IOBluetoothUserNotification *)notification device:(IOBluetoothDevice *)device {
    NSLog(@"MAS: Client disconnected");
    [self handleDisconnect];

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
    
    if([_delegate respondsToSelector:@selector(masSessionDisconnected:)]) {
        [_delegate masSessionDisconnected:self];
    }
}

- (void)dealloc {
    [_device release];
    [_session release];
    [_connectionId release];
    if(_obexHeader) CFRelease(_obexHeader);
    [_reconnectTimer invalidate];
    [_reconnectTimer release];
    
    
    [super dealloc];
}

@end
