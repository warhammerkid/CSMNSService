#import "CSBluetoothOBEXSession.h"

#define ERROR_DOMAIN @"CSBluetoothOBEXSession"


@interface CSBluetoothOBEXSession ()
@property (nonatomic, retain) IOBluetoothOBEXSession *session;
@property (nonatomic, assign) OBEXMaxPacketLength maxPacketLength;
@property (nonatomic, retain) NSMutableData *obexHeader;
@property (nonatomic, retain) NSMutableDictionary *putHeaderAccumulator;
@end


@implementation CSBluetoothOBEXSession

- (IOBluetoothDevice *)getDevice {
    return [_session getDevice];
}

#pragma mark - Server Sessions

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
    NSDictionary *headers = nil;
    switch(event->type) {
        case kOBEXSessionEventTypeConnectCommandReceived:
            headers = (NSDictionary *)OBEXGetHeaders(event->u.connectCommandData.headerDataPtr, event->u.connectCommandData.headerDataLength);
            _maxPacketLength = event->u.connectCommandData.maxPacketSize;
            [_delegate OBEXSession:self receivedConnect:headers];
            break;
        case kOBEXSessionEventTypePutCommandReceived:
            headers = (NSDictionary *)OBEXGetHeaders(event->u.putCommandData.headerDataPtr, event->u.putCommandData.headerDataLength);
            if(!_putHeaderAccumulator) _putHeaderAccumulator = [NSMutableDictionary new];
            [self accumulateHeaders:headers in:_putHeaderAccumulator];
            [_delegate OBEXSession:self receivedPut:_putHeaderAccumulator];
            break;
        case kOBEXSessionEventTypeDisconnectCommandReceived:
            headers = (NSDictionary *)OBEXGetHeaders(event->u.disconnectCommandData.headerDataPtr, event->u.disconnectCommandData.headerDataLength);
            [_delegate OBEXSession:self receivedDisconnect:headers];
            break;
        case kOBEXSessionEventTypeError:
            [_delegate OBEXSession:self receivedError:[NSError errorWithDomain:ERROR_DOMAIN code:event->u.errorData.error userInfo:nil]];
            break;
        default:
            break;
    }
    [headers release];
}

- (void)sendConnectResponse:(OBEXOpCode)responseCode headers:(NSDictionary *)headers {
    NSMutableData *h = [self buildOBEXHeader:headers];
    [_session OBEXConnectResponse:responseCode flags:0 maxPacketLength:_maxPacketLength optionalHeaders:h.mutableBytes optionalHeadersLength:h.length eventSelector:@selector(handleOBEXEvent:) selectorTarget:self refCon:nil];
}

- (void)sendPutContinueResponse {
    [_session OBEXPutResponse:kOBEXResponseCodeContinueWithFinalBit optionalHeaders:nil optionalHeadersLength:0 eventSelector:@selector(handleOBEXEvent:) selectorTarget:self refCon:nil];
}

- (void)sendPutSuccessResponse {
    [_putHeaderAccumulator release];
    _putHeaderAccumulator = nil;

    [_session OBEXPutResponse:kOBEXResponseCodeSuccessWithFinalBit optionalHeaders:nil optionalHeadersLength:0 eventSelector:@selector(handleOBEXEvent:) selectorTarget:self refCon:nil];
}

#pragma mark - Client Sessions

- (instancetype)initWithSDPServiceRecord:(IOBluetoothSDPServiceRecord *)record {
    self = [super init];
    if(self) {
        _session = [[IOBluetoothOBEXSession alloc] initWithSDPServiceRecord:record];
    }
    return self;
}

- (void)sendConnect:(NSDictionary *)headers handler:(ResponseHandler)handler {
    NSMutableData *h = [self buildOBEXHeader:headers];
    [_session OBEXConnect:kOBEXConnectFlagNone maxPacketLength:4096 optionalHeaders:h.mutableBytes optionalHeadersLength:h.length eventSelector:@selector(handleResponse:) selectorTarget:self refCon:Block_copy(handler)];
}

- (void)sendGet:(NSDictionary *)headers handler:(ResponseHandler)handler {
    NSMutableData *h = [self buildOBEXHeader:headers];
    assert(h.length + 100 < _maxPacketLength); // Split gets currently unsupported
    [_session OBEXGet:YES headers:h.mutableBytes headersLength:h.length eventSelector:@selector(handleResponse:) selectorTarget:self refCon:Block_copy(handler)];
}

- (void)sendPut:(NSDictionary *)headers body:(NSMutableData *)body handler:(ResponseHandler)handler {
    NSMutableData *h = [self buildOBEXHeader:headers];
    assert(h.length + body.length + 100 < _maxPacketLength); // Split puts currently unsupported
    [_session OBEXPut:YES headersData:h.mutableBytes headersDataLength:h.length bodyData:body.mutableBytes bodyDataLength:body.length eventSelector:@selector(handleResponse:) selectorTarget:self refCon:Block_copy(handler)];
}

- (void)sendDisconnect:(NSDictionary *)headers handler:(ResponseHandler)handler {
    NSMutableData *h = [self buildOBEXHeader:headers];
    [_session OBEXDisconnect:h.mutableBytes optionalHeadersLength:h.length eventSelector:@selector(handleResponse:) selectorTarget:self refCon:Block_copy(handler)];
}

- (void)handleResponse:(const OBEXSessionEvent *)event {
    NSError *error = nil;
    NSDictionary *headers = nil;

    OBEXOpCode responseCode = 0;
    switch(event->type) {
        case kOBEXSessionEventTypeConnectCommandResponseReceived:
            responseCode = event->u.connectCommandResponseData.serverResponseOpCode;
            headers = (NSDictionary *)OBEXGetHeaders(event->u.connectCommandResponseData.headerDataPtr, event->u.connectCommandResponseData.headerDataLength);
            _maxPacketLength = event->u.connectCommandResponseData.maxPacketSize;
            break;
        case kOBEXSessionEventTypeGetCommandResponseReceived:
            responseCode = event->u.getCommandResponseData.serverResponseOpCode;
            headers = (NSDictionary *)OBEXGetHeaders(event->u.getCommandResponseData.headerDataPtr, event->u.getCommandResponseData.headerDataLength);
            break;
        case kOBEXSessionEventTypePutCommandResponseReceived:
            responseCode = event->u.putCommandResponseData.serverResponseOpCode;
            headers = (NSDictionary *)OBEXGetHeaders(event->u.putCommandResponseData.headerDataPtr, event->u.putCommandResponseData.headerDataLength);
            break;
        case kOBEXSessionEventTypeDisconnectCommandResponseReceived:
            responseCode = event->u.disconnectCommandResponseData.serverResponseOpCode;
            headers = (NSDictionary *)OBEXGetHeaders(event->u.disconnectCommandResponseData.headerDataPtr, event->u.disconnectCommandResponseData.headerDataLength);
            break;
        case kOBEXSessionEventTypeError:
            responseCode = event->u.errorData.error;
            break;
        default:
            break;
    }
    if(responseCode != kOBEXResponseCodeSuccessWithFinalBit) {
        error = [NSError errorWithDomain:ERROR_DOMAIN code:responseCode userInfo:nil];
    }

    ResponseHandler handler = event->refCon;
    handler(self, headers, error);
    Block_release(handler);
    [headers release];
}

#pragma mark - Utilities

- (NSMutableData *)buildOBEXHeader:(NSDictionary *)headers {
    [_obexHeader release];
    if(headers) {
        _obexHeader = (NSMutableData *)OBEXHeadersToBytes((CFDictionaryRef)headers);
    } else {
        _obexHeader = nil;
    }
    return _obexHeader;
}

// Used for merging multiple data transmissions of a body into one set of headers
- (void)accumulateHeaders:(NSDictionary *)headers in:(NSMutableDictionary *)accumulator {
    NSString *bodyKey = (NSString *)kOBEXHeaderIDKeyBody;
    NSString *endOfBodyKey = (NSString *)kOBEXHeaderIDKeyEndOfBody;

    for(NSString *k in headers) {
        if([k isEqualToString:bodyKey]) {
            NSMutableData *body = accumulator[k];
            if(!body) accumulator[k] = [NSMutableData dataWithData:headers[k]];
            else [body appendData:headers[k]];
        } else if([k isEqualToString:endOfBodyKey]) {
            NSMutableData *body = accumulator[bodyKey];
            if(body) {
                [body appendData:headers[k]];
                accumulator[k] = body;
                [accumulator removeObjectForKey:bodyKey];
            } else {
                accumulator[k] = headers[k];
            }
        } else {
            accumulator[k] = headers[k];
        }
    }
}

#pragma mark - Memory

- (void)dealloc {
    [_session release];
    [_obexHeader release];
    [_putHeaderAccumulator release];
    
    [super dealloc];
}

@end
