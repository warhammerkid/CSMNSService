#import "CSBluetoothOBEXSession.h"


@interface CSBluetoothOBEXSession ()
@property (nonatomic, retain) IOBluetoothOBEXSession *session;
@property (nonatomic, assign) OBEXMaxPacketLength maxPacketLength;
@property (nonatomic, retain) NSMutableData *obexHeader;
@property (nonatomic, retain) NSMutableDictionary *putHeaderAccumulator;
@end


@implementation CSBluetoothOBEXSession

static NSMutableDictionary *publishedServices;

typedef struct {
    IOBluetoothUserNotification *connectNotification;
    IOBluetoothSDPServiceRecord *serviceRecord;
    void (^handler)(CSBluetoothOBEXSession *);
} PublishedService;

+ (IOBluetoothSDPServiceRecord *)publishService:(NSDictionary *)recordAttributes startHandler:(void (^)(CSBluetoothOBEXSession *))handler {
    // Build SDP record attributes - at protocol descriptor list, as it's always the same for OBEX services
    NSMutableDictionary *mutableRecordAttributes = [NSMutableDictionary dictionaryWithDictionary:recordAttributes];
    NSArray *protocolDescriptorList = @[
        @[[IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16L2CAP]],
        @[
            [IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16RFCOMM],
            @{@"DataElementSize": @1, @"DataElementType": @1, @"DataElementValue": @10}
        ],
        @[[IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16OBEX]]
    ];
    [mutableRecordAttributes setObject:protocolDescriptorList forKey:@"0004 - ProtocolDescriptorList"];

    // Publish SDP record
    IOBluetoothSDPServiceRecordRef serviceRecordRef;
    IOReturn err = IOBluetoothAddServiceDict((CFDictionaryRef)mutableRecordAttributes, &serviceRecordRef);
    if(err != kIOReturnSuccess) return nil;
    IOBluetoothSDPServiceRecord *serviceRecord = [[IOBluetoothSDPServiceRecord withSDPServiceRecordRef:serviceRecordRef] retain];
    CFRelease(serviceRecordRef);

    // Start listening for connections to the service
    BluetoothRFCOMMChannelID channelId;
    if([serviceRecord getRFCOMMChannelID:&channelId] != kIOReturnSuccess) return nil;
    IOBluetoothUserNotification *connectNotification = [IOBluetoothRFCOMMChannel registerForChannelOpenNotifications:self selector:@selector(handleConnectNotification:channel:) withChannelID:channelId direction:kIOBluetoothUserNotificationChannelDirectionIncoming];

    // Save published service
    PublishedService publishedService;
    publishedService.connectNotification = connectNotification;
    publishedService.serviceRecord = serviceRecord;
    publishedService.handler = Block_copy(handler);
    if(!publishedServices) publishedServices = [NSMutableDictionary new];
    [publishedServices setObject:[NSValue valueWithBytes:&publishedService objCType:@encode(PublishedService)] forKey:@(channelId)];

    return serviceRecord;
}

+ (void)unpublishService:(IOBluetoothSDPServiceRecord *)serviceRecord {
    // Get published service key
    BluetoothRFCOMMChannelID channelId;
    if([serviceRecord getRFCOMMChannelID:&channelId] != kIOReturnSuccess) return;
    NSNumber *serviceKey = @(channelId);

    // Get published service
    NSValue *serviceValue = [publishedServices objectForKey:serviceKey];
    if(!serviceValue) return;
    PublishedService service;
    [serviceValue getValue:&service];

    // Unpublish service
    [service.connectNotification unregister];
    BluetoothSDPServiceRecordHandle serviceHandle;
    if([service.serviceRecord getServiceRecordHandle:&serviceHandle] == kIOReturnSuccess) {
        IOBluetoothRemoveServiceWithRecordHandle(serviceHandle);
    }

    // Clean up
    [service.serviceRecord release];
    Block_release(service.handler);
    [publishedServices removeObjectForKey:serviceKey];
}

+ (void)handleConnectNotification:(IOBluetoothUserNotification *)notification channel:(IOBluetoothRFCOMMChannel *)channel {
    // Get PublishedService - ignore connect if we can't get it
    NSValue *serviceValue = [publishedServices objectForKey:@([channel getChannelID])];
    if(!serviceValue) return;
    PublishedService service;
    [serviceValue getValue:&service];

    // Create CSBluetoothOBEXSession
    CSBluetoothOBEXSession *session = [CSBluetoothOBEXSession new];
    session.session = [IOBluetoothOBEXSession withIncomingRFCOMMChannel:channel eventSelector:@selector(handleOBEXEvent:) selectorTarget:session refCon:nil];
    
    // Call handler
    service.handler([session autorelease]);
}

- (void)handleOBEXEvent:(const OBEXSessionEvent *)event {
    // Release old header data
    if(_obexHeader) CFRelease(_obexHeader);
    _obexHeader = nil;
    
    // Notify delegate based on type
    CFDictionaryRef inHeaders = nil;
    switch(event->type) {
        case kOBEXSessionEventTypeConnectCommandReceived:
            inHeaders = OBEXGetHeaders(event->u.connectCommandData.headerDataPtr, event->u.connectCommandData.headerDataLength);
            _maxPacketLength = event->u.connectCommandData.maxPacketSize;
            [_delegate OBEXSession:self receivedConnect:(NSDictionary *)inHeaders];
            CFRelease(inHeaders);
            break;
        case kOBEXSessionEventTypePutCommandReceived:
            inHeaders = OBEXGetHeaders(event->u.putCommandData.headerDataPtr, event->u.putCommandData.headerDataLength);
            if(!_putHeaderAccumulator) _putHeaderAccumulator = [NSMutableDictionary new];
            [self accumulateHeaders:inHeaders in:_putHeaderAccumulator];
            [_delegate OBEXSession:self receivedPut:_putHeaderAccumulator];
            CFRelease(inHeaders);
            break;
        case kOBEXSessionEventTypeDisconnectCommandReceived:
            inHeaders = OBEXGetHeaders(event->u.disconnectCommandData.headerDataPtr, event->u.disconnectCommandData.headerDataLength);
            [_delegate OBEXSession:self receivedDisconnect:(NSDictionary *)inHeaders];
            CFRelease(inHeaders);
            break;
        case kOBEXSessionEventTypeError:
            [_delegate OBEXSession:self receivedError:[NSError errorWithDomain:@"CSBluetoothOBEXSession" code:event->u.errorData.error userInfo:nil]];
            break;
        default:
            break;
    }
}

- (void)sendConnectResponse:(OBEXOpCode)responseCode headers:(NSDictionary *)headers {
    if(headers) {
        NSMutableData *h = [self buildOBEXHeader:headers];
        [_session OBEXConnectResponse:responseCode flags:0 maxPacketLength:_maxPacketLength optionalHeaders:h.mutableBytes optionalHeadersLength:h.length eventSelector:@selector(handleOBEXEvent:) selectorTarget:self refCon:nil];
    } else {
        [_session OBEXConnectResponse:responseCode flags:0 maxPacketLength:_maxPacketLength optionalHeaders:nil optionalHeadersLength:0 eventSelector:@selector(handleOBEXEvent:) selectorTarget:self refCon:nil];
    }
}

- (void)sendPutContinueResponse {
    [_session OBEXPutResponse:kOBEXResponseCodeContinueWithFinalBit optionalHeaders:nil optionalHeadersLength:0 eventSelector:@selector(handleOBEXEvent:) selectorTarget:self refCon:nil];
}

- (void)sendPutSuccessResponse {
    [_putHeaderAccumulator release];
    _putHeaderAccumulator = nil;

    [_session OBEXPutResponse:kOBEXResponseCodeSuccessWithFinalBit optionalHeaders:nil optionalHeadersLength:0 eventSelector:@selector(handleOBEXEvent:) selectorTarget:self refCon:nil];
}

- (IOBluetoothDevice *)getDevice {
    return [_session getDevice];
}

- (NSMutableData *)buildOBEXHeader:(NSDictionary *)headers {
    [_obexHeader release];
    _obexHeader = (NSMutableData *)OBEXHeadersToBytes((CFDictionaryRef)headers);
    return _obexHeader;
}

// Used for merging multiple data transmissions of a body into one set of headers
- (void)accumulateHeaders:(CFDictionaryRef)headers in:(NSMutableDictionary *)accumulator {
    NSDictionary *h = (NSDictionary *)headers;
    NSString *bodyKey = (NSString *)kOBEXHeaderIDKeyBody;
    NSString *endOfBodyKey = (NSString *)kOBEXHeaderIDKeyEndOfBody;

    for(NSString *k in h) {
        if([k isEqualToString:bodyKey]) {
            NSMutableData *body = accumulator[k];
            if(!body) accumulator[k] = [NSMutableData dataWithData:h[k]];
            else [body appendData:h[k]];
        } else if([k isEqualToString:endOfBodyKey]) {
            NSMutableData *body = accumulator[bodyKey];
            if(body) {
                [body appendData:h[k]];
                accumulator[k] = body;
                [accumulator removeObjectForKey:bodyKey];
            } else {
                accumulator[k] = h[k];
            }
        } else {
            accumulator[k] = h[k];
        }
    }
}

- (void)dealloc {
    [_session release];
    [_obexHeader release];
    [_putHeaderAccumulator release];
    
    [super dealloc];
}

@end
