//
//  FYClient.m
//  SocketClient
//
//  Created by Marius Rackwitz on 07.05.13.
//  Copyright (c) 2013 Marius Rackwitz. All rights reserved.
//
//
//  The MIT License
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

#import <CFNetwork/CFNetwork.h>
#import <objc/runtime.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <sys/errno.h>
#import <UIKit/UIKit.h>
#import "FYClient.h"
#import "FYActor.h"
#import "FYDelegateProxy.h"
#import "NSURL+FYHelper.h"
#import "SocketClient_Private.h"



const NSTimeInterval FYClientRetryTimeInterval     = 45;
const NSTimeInterval FYClientReconnectTimeInterval = 45;

NSString *const FYWorkerQueueName = @"com.paij.SocketClient.FYClient";

const struct FYMetaChannels FYMetaChannels = {
    .Handshake   = @"/meta/handshake",
    .Connect     = @"/meta/connect",
    .Disconnect  = @"/meta/disconnect",
    .Subscribe   = @"/meta/subscribe",
    .Unsubscribe = @"/meta/unsubscribe",
};

const struct FYConnectionTypes FYConnectionTypes = {
    .LongPolling            = @"long-polling",
    .CallbackPolling        = @"callback-polling",
    .WebSocket              = @"websocket",
};

NSArray *FYSupportedConnectionTypes() {
    return @[FYConnectionTypes.WebSocket];
}

const NSUInteger FYClientStateSetIsConnecting = (1<<2);
typedef NS_ENUM(NSUInteger, FYClientState) {
    FYClientStateDisconnected    = 0,
    FYClientStateHandshaking     = FYClientStateSetIsConnecting | (1<<0),
    FYClientStateConnecting      = FYClientStateSetIsConnecting | (1<<1),
    FYClientStateConnected       = (1<<3),
    FYClientStateDisconnecting   = (1<<4),
};



/*
 Adapt SystemConfiguration rechability's callback as C function pointer to ObjC blocks to pass an inline block handler.
 This has the advantage that the code don't has to be scattered over the whole file.
 */
typedef void(^FYReachabilityBlock)(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags);

static void FYReachabilityCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info) {
    FYReachabilityBlock handler = ((__bridge_transfer typeof(FYReachabilityBlock))info);
    handler(target, flags);
};



/**
 Blocks needs to be copied, when stored. Because you can use one single block as callback for multiple subscripted
 channels and we don't want to copy the block for each channel, use a wrapper object, which copy the block once and
 which will be released first, if all references, which are held each by a channel, were released by unsubscripting
 all these channels.
 */
@interface FYMessageCallbackWrapper : NSObject

/**
 Wrapper block callback.
 */
@property (nonatomic, copy) FYMessageCallback callback;

/**
 Channel extension used to subscribe.
 */
@property (nonatomic, retain) NSDictionary *extension;

/**
 Initializer
 
 @param  callback  The block, which should be wrapped.
 
 @param extension  An extension as an arbitrary JSON encodeable object according to [`ext` documentation][45].
 */
- (id)initWithCallback:(FYMessageCallback)callback extension:(NSDictionary *)extension;

@end


@implementation FYMessageCallbackWrapper

- (id)initWithCallback:(FYMessageCallback)callback extension:(NSDictionary *)extension {
    self = [super init];
    if (self) {
        self.callback = callback;
        self.extension = extension;
    }
    return self;
}

@end



FYDefineDelegateProxy(FYClientDelegate);
FYDefineDelegateProxy(SRWebSocketDelegate);



/*
 Private interface
 */
@interface FYClient () <SRWebSocketDelegate, NSURLConnectionDataDelegate>

// External readonly properties redefined as readwrite
@property (nonatomic, retain, readwrite) NSURL *baseURL;
@property (nonatomic, retain, readwrite) NSString *clientId;
@property (nonatomic, retain, readwrite) SRWebSocket *webSocket;
@property (nonatomic, retain, readwrite) id persist;
@property (nonatomic, assign, readwrite) BOOL reconnecting;

// URL with NSURLConnection-compatible scheme
@property (nonatomic, retain) NSURL *httpBaseURL;

// Internal used properties only
@property (nonatomic, retain) NSMutableDictionary *metaChannelActors;

@property (nonatomic, assign) FYClientState state;
@property (nonatomic, assign) BOOL shouldReconnectOnDidBecomeActive;

@property (nonatomic, retain) NSString *connectionType;
@property (nonatomic, retain) NSDictionary *connectionExtension;
@property (nonatomic, retain, readwrite) NSMutableDictionary *channels;

@property (nonatomic, retain) FYClientDelegateProxy *clientDelegateProxy;
@property (nonatomic, retain) SRWebSocketDelegateProxy *webSocketDelegateProxy;
@property (nonatomic) dispatch_queue_t workerQueue;

// TODO: Enumerate hosts
//@property (nonatomic, retain) NSMutableArray *alternateHosts;
//@property (nonatomic, retain) NSMutableArray *triedHosts;

// UIApplication state notification handler
- (void)applicationWillResignActive:(NSNotification *)note;
- (void)applicationDidBecomeActive:(NSNotification *)note;

// Protected connection status methods
- (void)handshake;
- (void)scheduleKeepAlive;
- (BOOL)isConnecting;

// Channel subscription helper
- (void)validateChannel:(NSString *)channel;

// SRWebSocket facade methods
- (void)openSocketConnection;
- (void)closeSocketConnection;
- (void)sendSocketMessage:(NSDictionary *)message;

// NSURLConnection facade methods
- (void)sendHTTPMessage:(NSDictionary *)message;

// Communication helper functions
- (void)handlePOSIXError:(NSError *)error;
- (void)sendMessage:(NSDictionary *)message;
- (NSString *)generateMessageId;

// Bayeux protocol functions
- (void)sendHandshake;
- (void)sendConnect;
- (void)sendDisconnect;
- (void)sendSubscribe:(id)channel withExtension:(NSDictionary *)extension;
- (void)sendUnsubscribe:(id)channel;
- (void)sendPublish:(NSDictionary *)userInfo onChannel:(NSString *)channel withExtension:(NSDictionary *)extension;

// Bayeux protocol responses handlers
- (void)handleResponse:(NSString *)message;
- (void)client:(FYClient *)client receivedHandshakeMessage:(FYMessage *)message;
- (void)client:(FYClient *)client receivedConnectMessage:(FYMessage *)message;
- (void)client:(FYClient *)client receivedDisconnectMessage:(FYMessage *)message;
- (void)client:(FYClient *)client receivedSubscribeMessage:(FYMessage *)message;
- (void)client:(FYClient *)client receivedUnsubscribeMessage:(FYMessage *)message;

// JSON serialization & deserialization
- (NSString *)stringBySerializingObject:(NSObject *)object;
- (NSData *)dataBySerializingObject:(NSObject *)object;
- (id)deserializeString:(NSString *)string;
- (id)deserializeData:(NSData *)data;

// General helper
- (void)performBlock:(void(^)(FYClient *))block afterDelay:(NSTimeInterval)delay;
- (void)chainActorForMetaChannel:(NSString *)channel onceWithActorBlock:(FYActorBlock)block;

@end


@implementation FYClient

// Exclude properties from automatic synthesization
@dynamic connected;
@dynamic delegateQueue;

- (id)init {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:[NSString stringWithFormat:@"Don't use [%@ %@]. You must use the designated "
                                           "initializer: %@.", self.class, NSStringFromSelector(_cmd),
                                           NSStringFromSelector(@selector(initWithURL:))]
                                 userInfo:nil];
}

- (void)dealloc {
    // Explicitly assign nil to provoke memory management
    self.callbackQueue = nil;
    self.delegateQueue = nil;
    self.workerQueue   = nil;
    
    // Remove observations
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (id)initWithURL:(NSURL *)baseURL {
    self = [super init];
    if (self) {
        // Validate and set URL
        NSParameterAssert(baseURL);
        NSString *scheme = baseURL.scheme.lowercaseString;
        NSParameterAssert([scheme isEqualToString:@"ws"] || [scheme isEqualToString:@"wss"] ||
                          [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]);
        self.baseURL = baseURL;
        
        // Transform URL to a HTTP URL if needed
        self.httpBaseURL = [scheme hasPrefix:@"http"]
            ? baseURL
            : [baseURL URLWithScheme:[scheme isEqualToString:@"wss"] ? @"https" : @"http" host:baseURL.host];
        
        // This must be done before delegateQueue was set.
        self.clientDelegateProxy = [FYClientDelegateProxy alloc]; // yes - there is no init ;)
        
        // Init worker queue
        NSString *workerQueueName = [FYWorkerQueueName stringByAppendingFormat:@"_%d", (int)self];
        const char *workerQueueChars = [workerQueueName cStringUsingEncoding:NSASCIIStringEncoding];
        self.workerQueue = dispatch_queue_create(workerQueueChars, NULL);
        
        // Init returning queues
        self.delegateQueue = dispatch_get_main_queue();
        self.callbackQueue = dispatch_get_main_queue();
        
        // Init channel collection
        self.channels = [NSMutableDictionary new];
        
        // Init state properties
        self.state = FYClientStateDisconnected;
        self.shouldReconnectOnDidBecomeActive = NO;
        
        // Init connection parameters
        self.retryTimeInterval     = FYClientRetryTimeInterval;
        self.reconnectTimeInterval = FYClientReconnectTimeInterval;
        self.maySendHandshakeAsync = YES;
        self.awaitOnlyHandshake    = YES;
        
        // Bind own message handler selectors dynamically to meta channel names
        id<FYActor>(^makeActor)(SEL) = ^id<FYActor>(SEL selector){
            return [[FYSelTargetActor alloc] initWithTarget:self selector:selector];
         };
        
        self.metaChannelActors = @{
             FYMetaChannels.Handshake:   makeActor(@selector(client:receivedHandshakeMessage:)),
             FYMetaChannels.Connect:     makeActor(@selector(client:receivedConnectMessage:)),
             FYMetaChannels.Disconnect:  makeActor(@selector(client:receivedDisconnectMessage:)),
             FYMetaChannels.Subscribe:   makeActor(@selector(client:receivedSubscribeMessage:)),
             FYMetaChannels.Unsubscribe: makeActor(@selector(client:receivedUnsubscribeMessage:)),
         }.mutableCopy;
        
        // Observe UIApplication notifications
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(applicationWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
        [center addObserver:self selector:@selector(applicationDidBecomeActive:)  name:UIApplicationDidBecomeActiveNotification  object:nil];
    }
    return self;
}

- (id)persist {
    return (self.persist = self);
}


#pragma mark - Custom delegate getter and setter forwards to delegateProxy

- (void)setDelegate:(id<FYClientDelegate>)delegate {
    self.clientDelegateProxy.proxiedObject = delegate;
}

- (id<FYClientDelegate>)delegate {
    return self.clientDelegateProxy.proxiedObject;
}

- (void)setDelegateQueue:(dispatch_queue_t)delegateQueue {
    NSAssert(self.clientDelegateProxy, @"Delegate proxy has to be initialized before delegateQueue can be set.");
    self.clientDelegateProxy.delegateQueue = delegateQueue;
}

- (dispatch_queue_t)delegateQueue {
    return self.clientDelegateProxy.delegateQueue;
}


#pragma mark - Compatiblity to versions below iOS 6.1, where ARC doesn't support automatic dispatch_retain & dispatch_release

- (void)setCallbackQueue:(dispatch_queue_t)callbackQueue {
    if (callbackQueue) {
        fy_dispatch_retain(callbackQueue);
    }
    if (_callbackQueue) {
        fy_dispatch_release(_callbackQueue);
    }
    _callbackQueue = callbackQueue;
}

- (void)setWorkerQueue:(dispatch_queue_t)workerQueue {
    if (workerQueue) {
        fy_dispatch_retain(workerQueue);
    }
    if (_workerQueue) {
        fy_dispatch_release(_workerQueue);
    }
    _workerQueue = workerQueue;
}


#pragma mark - UIApplication state notification handlers

- (void)applicationWillResignActive:(NSNotification *)note {
    self.shouldReconnectOnDidBecomeActive = self.isConnected || self.isConnecting;
    [self disconnect];
}

- (void)applicationDidBecomeActive:(NSNotification *)note {
    if (self.shouldReconnectOnDidBecomeActive) {
        // This is needed if the client is initialized before application did become active,
        // typically this will be [UIApplicationDelegate application:didFinishLaunchingWithOptions:]
        [self reconnect];
    }
}


#pragma mark - Public connection status methods

- (void)connect {
    [self connectWithExtension:nil];
}

- (void)connectOnSuccess:(FYClientConnectSuccessBlock)block; {
    [self connectWithExtension:nil onSuccess:block];
}

- (void)connectWithExtension:(NSDictionary *)extension {
    [self connectWithExtension:extension onSuccess:nil];
}

- (void)connectWithExtension:(NSDictionary *)extension onSuccess:(FYClientConnectSuccessBlock)block; {
    self.connectionExtension = extension;
    
    if (block) {
        NSString *channel = FYMetaChannels.Connect;
        if (self.awaitOnlyHandshake) {
            channel = FYMetaChannels.Handshake;
        }
        
        // TODO: This is not sufficient if self.maySendHandshakeAsync=YES and socket will be opened after handshake
        // succeeds.
        
        // Swizzle actor:
        // This will even ensure that if the connect fails or a disconnect occurs before Bayeux connect was confirmed by
        // by the server the original success block will be called exactly once on success.
        __block __unsafe_unretained FYActorBlock recursiveActorBlock;
        FYActorBlock actorBlock = ^(FYClient *self, FYMessage *message) {
            // First argument is named self, because it MUST be the same as the receiver in the outer scope, and we
            // don't want to cause retain cycles by capturing self strongly in this block. Syntax hightlighting stays
            // pretty and no additional `__weak` var is needed.
            
            if (self.connected) {
                // Execute success block
                dispatch_async(self.callbackQueue, ^{
                    block(self);
                 });
            } else {
                // Connect was not successful. Chain block again.
                [self chainActorForMetaChannel:channel onceWithActorBlock:recursiveActorBlock];
            }
         };
        recursiveActorBlock = actorBlock;
        
        [self chainActorForMetaChannel:channel onceWithActorBlock:actorBlock];
    }
    
    // Connect now
    dispatch_async(self.workerQueue, ^{
        [self openSocketConnection];
     });
    
    if (self.maySendHandshakeAsync) {
        // Do the handshake parallel to opening socket connection on an own URL request
        dispatch_async(self.workerQueue, ^{
            [self handshake];
         });
    }
}

- (void)disconnect {
    self.reconnecting = NO;
    self.persist = nil;
    self.state = FYClientStateDisconnecting;
    if (self.clientId) {
        [self sendDisconnect];
    } else if (self.state == FYClientStateHandshaking) {
        [self chainActorForMetaChannel:FYMetaChannels.Handshake onceWithActorBlock:^(FYClient *self, FYMessage *message) {
            if (self.connected && self.clientId) {
                [self sendDisconnect];
            }
         }];
    }
}

- (void)reconnect {
    // Save current channels
    NSMutableDictionary *channels = self.channels.mutableCopy;
    [self connectWithExtension:self.connectionExtension onSuccess:self.isReconnecting ? nil : ^(FYClient *self) {
        if (self.state >= FYClientStateConnecting) {
            // Re-subscript to channels on server-side
            self.channels = channels;
            for (NSString *channel in channels) {
                // Send subscribe directly, without unboxing and re-boxing FYMessageCallbacks
                [self sendSubscribe:channel withExtension:[channels[channel] extension]];
            }
        }
        self.reconnecting = NO;
     }];
    self.reconnecting = YES;
}

- (BOOL)isConnected {
    return self.state == FYClientStateConnected;
}

- (BOOL)isConnecting {
    return self.state & FYClientStateSetIsConnecting;
}

- (NSArray *)subscriptedChannels {
    return self.channels.allKeys;
}


#pragma mark Protected connection status methods

- (void)handshake {
    self.clientId = nil;
    self.state = FYClientStateHandshaking;
    [self sendHandshake];
}

- (void)scheduleKeepAlive {
    FYLog(@"Scheduled a keep-alive connect in %.3f.", self.retryTimeInterval);
    if (self.retryTimeInterval > 0) {
        // Schedule the next keep-alive connect.
        [self performBlock:^(FYClient *client) {
            // Check if the client is still connected, or if we may received an advice, which caused a handshake or
            // a disconnect. So we prevent unnecessary connect messages and especially connect message without
            // clientIds which would cause an exception.
            if (client.state == FYClientStateConnected && self.clientId) {
                FYLog(@"Send scheduled keep-alive connect at: %.3f.", [NSDate.date timeIntervalSince1970]);
                [client sendConnect];
            }
        } afterDelay:self.retryTimeInterval];
    }
}


#pragma mark - Channel subscription helper

- (void)validateChannel:(NSString *)channel {
    NSAssert([channel hasPrefix:@"/"], @"A valid channel or channel pattern has to begin with a slash.");
}


#pragma mark - Channel subscription

- (void)subscribeChannel:(NSString *)channel callback:(FYMessageCallback)callback {
    [self validateChannel:channel];
    [self subscribeChannel:channel callback:callback extension:nil];
}

- (void)subscribeChannel:(NSString *)channel callback:(FYMessageCallback)callback extension:(NSDictionary *)extension {
    [self validateChannel:channel];
    self.channels[channel] = [[FYMessageCallbackWrapper alloc] initWithCallback:callback extension:extension];
    [self sendSubscribe:channel withExtension:extension];
}

- (void)subscribeChannels:(NSArray *)channels callback:(FYMessageCallback)callback {
    [self subscribeChannels:channels callback:callback extension:nil];
}

- (void)subscribeChannels:(NSArray *)channels callback:(FYMessageCallback)callback extension:(NSDictionary *)extension {
    FYMessageCallbackWrapper *wrapper = [[FYMessageCallbackWrapper alloc] initWithCallback:callback extension:extension];
    for (NSString *channel in channels) {
        [self validateChannel:channel];
        self.channels[channel] = wrapper;
    }
    [self sendSubscribe:channels withExtension:extension];
}

- (void)unsubscribeChannel:(NSString *)channel {
    [self validateChannel:channel];
    [self.channels removeObjectForKey:channel];
    [self sendUnsubscribe:channel];
}

- (void)unsubscribeChannels:(NSArray *)channels {
    for (NSString *channel in channels) {
        [self validateChannel:channel];
    }
    [self.channels removeObjectsForKeys:channels];
    [self sendUnsubscribe:channels];
}

- (void)unsubscribeAll {
    for (NSString *channelName in self.channels) {
        [self sendUnsubscribe:channelName];
    }
}


#pragma mark - Publish on channel

- (void)publish:(NSDictionary *)userInfo onChannel:(NSString *)channel {
    [self sendPublish:userInfo onChannel:channel withExtension:nil];
}

- (void)publish:(NSDictionary *)userInfo onChannel:(NSString *)channel withExtension:(NSDictionary *)extension {
    [self sendPublish:userInfo onChannel:channel withExtension:extension];
}


#pragma mark - SRWebSocket facade methods

- (void)openSocketConnection {
    // Reset existing connection state information
    self.clientId = nil;
    [self.channels removeAllObjects];
    
    // Clean up any existing socket
    self.webSocket.delegate = nil;
    [self.webSocket close];
    
    // Init a new socket
    self.webSocket = [[SRWebSocket alloc] initWithURLRequest:[NSURLRequest requestWithURL:self.baseURL]];
    self.webSocket.delegate = self;
    
    // Let's respond the socket on our workerQueue, we will dispatch on our delegate / callback queues for our own.
    if ([self.webSocket respondsToSelector:@selector(setDelegateDispatchQueue:)]) {
        [self.webSocket performSelector:@selector(setDelegateDispatchQueue:) withObject:(id)self.workerQueue];
    } else {
        self.webSocketDelegateProxy = [SRWebSocketDelegateProxy alloc];
        self.webSocketDelegateProxy.delegateQueue = self.workerQueue;
        self.webSocketDelegateProxy.proxiedObject = self;
        self.webSocket.delegate = self.webSocketDelegateProxy;
    }
    
    [self.webSocket open];
}

- (void)closeSocketConnection {
    [self.webSocket close];
}

- (void)sendSocketMessage:(NSDictionary *)message {
    dispatch_async(self.workerQueue, ^{
        NSString *serializedMessage = [self stringBySerializingObject:message];
        if (serializedMessage) {
            if (self.webSocket.readyState == SR_OPEN) {
                FYLog(@"Send: %@", message);
                [self.webSocket send:serializedMessage];
            } else {
                NSError *error = [NSError errorWithDomain:FYErrorDomain code:FYErrorSocketNotOpen userInfo:@{
                     NSLocalizedDescriptionKey:        @"The socket connection is not open, but required to be opened.",
                     NSLocalizedFailureReasonErrorKey: [NSString stringWithFormat:@"Could not send message %@", message],
                 }];
                [self.clientDelegateProxy client:self failedWithError:error];
            }
        }
     });
}


#pragma mark - SRWebSocketDelegate's implementation

- (void)webSocketDidOpen:(SRWebSocket *)aWebSocket {
    if (self.maySendHandshakeAsync) {
        // Handshake was already sent.
        if (self.state == FYClientStateConnecting) {
            self.state = FYClientStateConnected;
            
            // Successful response to handshake was already received, but socket was not open, so we must schedule the
            // first connect here.
            [self scheduleKeepAlive];
            
            [self.clientDelegateProxy clientConnected:self];
        }
    } else {
        [self handshake];
    }
}

- (void)webSocket:(SRWebSocket *)webSocket didReceiveMessage:(NSString *)message {
    [self handleResponse:message];
}

- (void)webSocket:(SRWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean {
    if (self.state == FYClientStateDisconnected) {
        // Filter out expected disconnects
        return;
    }
    self.state = FYClientStateDisconnected;
    
    NSError *error;
    if (reason || !wasClean) {
        error = [NSError errorWithDomain:FYErrorDomain code:FYErrorSocketClosed userInfo:@{
             NSLocalizedDescriptionKey:        @"The socket connection was closed.",
             NSLocalizedFailureReasonErrorKey: reason ?: @"Unknown",
         }];
    }
    
    [self.clientDelegateProxy client:self disconnectedWithMessage:nil error:error];
}

- (void)webSocket:(SRWebSocket *)webSocket didFailWithError:(NSError *)error {
    if ([error.domain isEqualToString:NSPOSIXErrorDomain]) {
        [self handlePOSIXError:error];
    }
    [self.clientDelegateProxy client:self failedWithError:error];
}


#pragma mark - NSURLConnection facade

- (void)sendHTTPMessage:(NSDictionary *)message {
    dispatch_async(self.workerQueue, ^{
        NSData *serializedMessage = [self dataBySerializingObject:@[message]];
        if (serializedMessage) {
            FYLog(@"Send: %@", message);
            
            // Initialize a new URL request
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.httpBaseURL];
            request.HTTPMethod  = @"POST";
            request.HTTPBody    = serializedMessage;
            
            // Set HTTP headers
            NSDictionary *headers = @{
                @"Accept":          @"application/json",
                @"Accept-Encoding": @"gzip",
                @"Content-Type":    @"application/json",
             };
            // TODO: Add here a delegate method to further initialize requests header fields for authorization
            // with inout &headers
            for (NSString *headerField in headers) {
                [request addValue:headers[headerField] forHTTPHeaderField:headerField];
            }
            
            // Configure request options
            request.HTTPShouldUsePipelining = YES;
            request.cachePolicy             = NSURLRequestReloadIgnoringLocalCacheData;
            // Implicitly needed defaults
            //request.allowsCellularAccess    = YES;
            //request.HTTPShouldHandleCookies = YES;
            
            // Send request
            NSURLConnection *connection;
            connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
            [connection scheduleInRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode];
            [connection start];
        }
    });
}

#pragma mark - NSURLConnectionDataDelegate's implementation

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    NSAssert([response isKindOfClass:NSHTTPURLResponse.class], @"Expected only HTTP responses!");
    objc_setAssociatedObject(connection, (__bridge const void *)(NSHTTPURLResponse.class), response, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    dispatch_async(self.workerQueue, ^{
        NSString *message = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSHTTPURLResponse *response = objc_getAssociatedObject(connection, (__bridge const void *)(NSHTTPURLResponse.class));
        if (response.statusCode != 200) {
            NSError *error = [NSError errorWithDomain:FYErrorDomain code:FYErrorHTTPUnexpectedStatusCode userInfo:@{
                NSLocalizedDescriptionKey:        @"The HTTP request returned with an unexpected status code.",
                NSLocalizedFailureReasonErrorKey: [NSString stringWithFormat:@"Received unexpected response with "
                                                   "status code %d with content: %@.", response.statusCode, message]
             }];
            [self.clientDelegateProxy client:self failedWithError:error];
        } else {
            [self handleResponse:message];
        }
     });
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    [self.clientDelegateProxy client:self failedWithError:error];
}


#pragma mark - Communication helper functions

- (void)handlePOSIXError:(NSError *)error {
    NSParameterAssert([error.domain isEqualToString:NSPOSIXErrorDomain]);
    
    if (self.reconnectTimeInterval < 0) {
        // We will handle some errors by trying to reconnect under certain conditions, but reconnect is disabled, so we
        // don't need to do anything further here.
        return;
    }
    
    if ([error.domain isEqualToString:NSPOSIXErrorDomain]) {
        switch (error.code) {
            case ENETDOWN:       // Network is down
            case ENETUNREACH:    // Network is unreachable
            case EHOSTDOWN:      // Host is down
            case EHOSTUNREACH:   // No route to host
            {
                // Use SystemConfiguration to await a network connection
                __weak FYClient *client = self;
                __block SCNetworkReachabilityRef ref = SCNetworkReachabilityCreateWithName(NULL, self.baseURL.host.UTF8String);
                SCNetworkReachabilityContext context = {
                    .info = (__bridge_retained void *)[^(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags){
                        if (!(flags & kSCNetworkReachabilityFlagsReachable)
                            || (   flags & kSCNetworkReachabilityFlagsConnectionRequired
                                && flags & kSCNetworkReachabilityFlagsTransientConnection
                            )) {
                            return;
                        }
                        
                        // Tear down
                        SCNetworkReachabilitySetCallback(ref, NULL, NULL);
                        SCNetworkReachabilitySetDispatchQueue(ref, NULL);
                        CFRelease(ref);
                        ref = nil;
                        
                        // Try to reconnect
                        if (!client.isReconnecting && client.reconnectTimeInterval > 0) {
                            if (client && client.state != FYClientStateDisconnected) {
                                // Reconnect if client was not disconnected meanwhile
                                [client reconnect];
                            }
                        }
                     } copy],
                 };
                
                SCNetworkReachabilitySetCallback(ref, FYReachabilityCallback, &context);
                SCNetworkReachabilitySetDispatchQueue(ref, self.workerQueue);
                break;
            }
                
            case ECONNRESET:     // Connection reset by peer
            case ENOTCONN:       // Socket is not connected
            case ETIMEDOUT:      // Operation timed out
            case ECONNREFUSED:   // Connection refused
                // Try to reconnect
                [self performBlock:^(FYClient *client) {
                    [self reconnect];
                 } afterDelay:self.reconnectTimeInterval];
                break;
        }
    }
}

- (void)sendMessage:(NSDictionary *)message {
    if (self.webSocket.readyState == SR_OPEN) {
        [self sendSocketMessage:message];
    } else {
        [self sendHTTPMessage:message];
    }
}

- (NSString *)generateMessageId {
    return [NSString stringWithFormat:@"msg_%.5f_%d", [NSDate.date timeIntervalSince1970], 0];
}


#pragma mark - Bayeux procotol functions

- (void)sendHandshake {
    [self sendMessage:@{
        @"channel":                  FYMetaChannels.Handshake,
        @"version":                  @"1.0",
        @"minimumVersion":           @"1.0beta",
        @"supportedConnectionTypes": FYSupportedConnectionTypes(),
     }];
}

- (void)sendConnect {
    [self sendSocketMessage:@{
        @"channel":        FYMetaChannels.Connect,
        @"clientId":       self.clientId,
        @"connectionType": self.connectionType,
        @"ext":            self.connectionExtension ?: NSNull.null,
     }];
}

- (void)sendDisconnect {
    [self sendSocketMessage:@{
        @"channel":        FYMetaChannels.Disconnect,
        @"clientId":       self.clientId,
     }];
}

- (void)sendSubscribe:(id)channel withExtension:(NSDictionary *)extension {
    [self sendSocketMessage:@{
        @"channel":      FYMetaChannels.Subscribe,
        @"clientId":     self.clientId,
        @"subscription": channel,
        @"ext":          extension ?: NSNull.null
     }];
}

- (void)sendUnsubscribe:(id)channel {
    [self sendSocketMessage:@{
        @"channel":      FYMetaChannels.Unsubscribe,
        @"clientId":     self.clientId,
        @"subscription": channel,
     }];
}

- (void)sendPublish:(NSDictionary *)userInfo onChannel:(NSString *)channel withExtension:(NSDictionary *)extension {
    [self sendSocketMessage:@{
        @"channel":  channel,
        @"clientId": self.clientId,
        @"data":     userInfo,
        @"id":       [self generateMessageId],
        @"ext":      extension ?: NSNull.null
     }];
}


#pragma mark - Bayeux protocol responses handlers

- (void)handleResponse:(NSString *)message {
    id result = [self deserializeString:message];
    if (![result isKindOfClass:NSArray.class]) {
        // Response is malformed
        NSError *error = [NSError errorWithDomain:FYErrorDomain code:FYErrorMalformedJSONData userInfo:@{
            NSLocalizedDescriptionKey:        @"Response is malformed.",
            NSLocalizedFailureReasonErrorKey: [NSString stringWithFormat:@"Expected an array of messages, but got: %@.",
                                               result],
         }];
        [self.clientDelegateProxy client:self failedWithError:error];
        return;
    }
    
    NSArray *messages = result;
    for (NSDictionary *userInfo in messages) {
        FYLog(@"handleResponse: %@", userInfo);
        
        // Box in message object to unserialize all fields
        FYMessage *message = [[FYMessage alloc] initWithUserInfo:userInfo];
        
        BOOL handled = NO;
        
        // Handle advice before handling meta channel message, so the retryTimeInterval can be modified before the
        // handshake occurs which will schedule the first connect message.
        if (message.advice) {
            if (message.advice[@"reconnect"]) {
                [self handleReconnectAdviceOfMessage:message];
            }
        }
        
        // Check if its a meta channel message, which must be handled.
        for (NSString *channel in self.metaChannelActors) {
            if ([channel isEqualToString:message.channel]) {
                id<FYActor> actor = self.metaChannelActors[channel];
                [actor client:self receivedMessage:message];
                handled = YES;
                break;
            }
        }
        
        if (!handled) {
            if ([message.channel hasPrefix:@"/meta"]) {
                // Unhandled meta channel
                NSError *error = [NSError errorWithDomain:FYErrorDomain code:FYErrorUnhandledMetaChannelMessage userInfo:@{
                    NSLocalizedDescriptionKey:        @"Unhandled meta channel message",
                    NSLocalizedFailureReasonErrorKey: [NSString stringWithFormat:@"Unhandled meta channel message on "
                                                       "channel '%@'.", message.channel],
                 }];
                [self.clientDelegateProxy client:self failedWithError:error];
            } else if (self.channels[message.channel]) {
                // User-defined channel
                if (message.data) {
                    FYMessageCallbackWrapper *wrapper = self.channels[message.channel];
                    dispatch_async(self.callbackQueue, ^{
                        wrapper.callback(message.data);
                     });
                }
            } else {
                // Unexpected channel
                [self.clientDelegateProxy client:self receivedUnexpectedMessage:message];
            }
        }
    }
}


#pragma mark - Advice handlers

- (void)handleReconnectAdviceOfMessage:(FYMessage *)message {
    if ([message.successful boolValue]) {
        // Don't handle reconnect advice on succesful messages.
        return;
    }
    
    NSString *reconnectAdvice = message.advice[@"reconnect"];
    if ([reconnectAdvice isEqualToString:@"retry"]) {
        // Use delay given by server, if available
        NSTimeInterval delay = self.retryTimeInterval;
        if (message.advice[@"interval"]) {
            // Interval is given in milliseconds, NSTimeInterval is in seconds.
            delay = [message.advice[@"interval"] doubleValue] / 1000.0;
        }
        
        // Let delegate implementation customize given delay
        [self.clientDelegateProxy clientWasAdvisedToRetry:self retryInterval:&delay];
        
        if (delay == 0) {
            self.retryTimeInterval = FYClientRetryTimeInterval;
        } else {
            self.retryTimeInterval = delay;
        }
    } else if ([reconnectAdvice isEqualToString:@"handshake"]) {
        BOOL retry = NO;
        [self.clientDelegateProxy clientWasAdvisedToHandshake:self shouldRetry:&retry];
        if (retry) {
            [self handshake];
        }
    } else if ([reconnectAdvice isEqualToString:@"none"]) {
        if ([message.subscription isEqualToString:@"connection"]) {
            self.state = FYClientStateDisconnected;
            
            NSError *error = [NSError errorWithDomain:FYErrorDomain code:FYErrorReceivedAdviceReconnectTypeNone userInfo:@{
                NSLocalizedDescriptionKey:        [NSString stringWithFormat:@"Received reconnect advice 'none'."],
                NSLocalizedFailureReasonErrorKey: message.error ?: @"Unknown",
             }];
            [self.clientDelegateProxy client:self disconnectedWithMessage:message error:error];
        }
    }
}


#pragma mark - Channel handlers

- (void)client:(FYClient *)client receivedHandshakeMessage:(FYMessage *)message {
    if ([message.successful boolValue]) {
        self.clientId = message.clientId;
        
        if (self.state != FYClientStateHandshaking) {
            FYLog(@"Don't handle successful handshake further, because client is not in state 'Handshaking' and didn't "
                  " expected a handshake message or has disconnected while handshake was in progress.");
            return;
        }
        
        // Choose connection type based on responded supportedConnectionTypes.
        NSMutableSet *commonSupportedConnectionTypes = [[NSMutableSet alloc] initWithArray:FYSupportedConnectionTypes()];
        [commonSupportedConnectionTypes intersectsSet:[[NSSet alloc] initWithArray:message.supportedConnectionTypes]];
        
        if (!commonSupportedConnectionTypes.count > 0) {
            // No common supported connection type.
            NSError *error = [NSError errorWithDomain:FYErrorDomain code:FYErrorNoCommonSupportedConnectionType userInfo:@{
                NSLocalizedDescriptionKey:        [NSString stringWithFormat:@"Error while trying to connect with host "
                                                   "%@.", self.baseURL.absoluteString],
                NSLocalizedFailureReasonErrorKey: [NSString stringWithFormat:@"No common supported connection type. "
                                                   "Server supports the following: %@. Required was one of: %@.",
                                                   message.supportedConnectionTypes, FYSupportedConnectionTypes()]
             }];
            [self.clientDelegateProxy client:self disconnectedWithMessage:message error:error];
            return;
        }
        
        self.state = FYClientStateConnecting;
        
        if ([commonSupportedConnectionTypes containsObject:FYConnectionTypes.WebSocket]) {
            self.connectionType = FYConnectionTypes.WebSocket;
            if (self.webSocket.readyState == SR_OPEN) {
                self.state = FYClientStateConnected;
                
                // Schedule the first keep-alive connect.
                // DON'T send this immediately. This would cause (at least with Faye 0.8.9) an exceeding of the retry
                // interval, which will cause a timeout/disconnet.
                [self scheduleKeepAlive];
            }
        } else {
            NSAssert(@"The implementation of %@ does not handle all of the supported connection types "
                     "(FYSupportedConnectionTypes()=%@)!", NSStringFromSelector(_cmd), FYSupportedConnectionTypes());
        }
        
        if (self.state == FYClientStateConnected) {
            [self.clientDelegateProxy clientConnected:self];
        }
    } else {
        // Handshake failed.
        NSError *error = [NSError errorWithDomain:FYErrorDomain code:FYErrorHandshakeFailed userInfo:@{
            NSLocalizedDescriptionKey:        [NSString stringWithFormat:@"Error on handshake with host %@",
                                               self.baseURL.absoluteString],
            NSLocalizedFailureReasonErrorKey: message.error ?: @"Unknown",
         }];
        [self.clientDelegateProxy client:self failedWithError:error];
    }
}

- (void)client:(FYClient *)client receivedConnectMessage:(FYMessage *)message {
    if ([message.successful boolValue]) {
        FYLog(@"Received successful connect at: %.3f.", [NSDate.date timeIntervalSince1970]);
        
        if (self.state != FYClientStateConnected) { // TODO: This will never be true!
            // Initial connect.
            if (!self.awaitOnlyHandshake) {
                [self.clientDelegateProxy clientConnected:self];
            }
        }
        
        // Schedule immediately the next keep-alive connect.
        [self scheduleKeepAlive];
    } else {
        self.state = FYClientStateDisconnected;
        
        // Web socket connection was established, but Bayeux connection failed.
        NSError *error = [NSError errorWithDomain:FYErrorDomain code:FYErrorConnectFailed userInfo:@{
            NSLocalizedDescriptionKey:        [NSString stringWithFormat:@"Web Socket connection was established, "
                                               "but Bayeux connection failed on host %@.", self.baseURL.absoluteString],
            NSLocalizedFailureReasonErrorKey: message.error ?: @"Unknown",
         }];
        [self.clientDelegateProxy client:self disconnectedWithMessage:message error:error];
    }
}

- (void)client:(FYClient *)client receivedDisconnectMessage:(FYMessage *)message {
    if ([message.successful boolValue]) {
        self.state = FYClientStateDisconnected;
        [self closeSocketConnection];
        [self.clientDelegateProxy client:self disconnectedWithMessage:message error:nil];
    } else {
        // Disconnection failed.
        NSError *error = [NSError errorWithDomain:FYErrorDomain code:FYErrorSubscribeFailed userInfo:@{
            NSLocalizedDescriptionKey:        [NSString stringWithFormat:@"Error on disconnecting from host %@",
                                               self.baseURL.absoluteString],
            NSLocalizedFailureReasonErrorKey: message.error ?: @"Unknown",
         }];
        [self.clientDelegateProxy client:self failedWithError:error];
    }
}

- (void)client:(FYClient *)client receivedSubscribeMessage:(FYMessage *)message {
    if ([message.successful boolValue]) {
        [self.clientDelegateProxy client:self subscriptionSucceedToChannel:message.subscription];
    } else {
        // Subscription failed.
        NSError *error = [NSError errorWithDomain:FYErrorDomain code:FYErrorSubscribeFailed userInfo:@{
            NSLocalizedDescriptionKey:        [NSString stringWithFormat:@"Error subscribing to channel '%@'.",
                                               message.subscription],
            NSLocalizedFailureReasonErrorKey: message.error ?: @"Unknown",
         }];
        [self.clientDelegateProxy client:self failedWithError:error];
    }
}

- (void)client:(FYClient *)client receivedUnsubscribeMessage:(FYMessage *)message {
    if ([message.successful boolValue]) {
        [self.channels removeObjectForKey:message.subscription];
    } else {
        // Unsubscription failed.
        NSError *error = [NSError errorWithDomain:FYErrorDomain code:FYErrorUnsubscribeFailed userInfo:@{
            NSLocalizedDescriptionKey:        [NSString stringWithFormat:@"Error unsubscribing from channel '%@'.",
                                               message.subscription],
            NSLocalizedFailureReasonErrorKey: message.error ?: @"Unknown",
         }];
        [self.clientDelegateProxy client:self failedWithError:error];
    }
}


#pragma mark - JSON serialization & deserialization

- (NSString *)stringBySerializingObject:(NSObject *)object {
    return [[NSString alloc] initWithData:[self dataBySerializingObject:object] encoding:NSUTF8StringEncoding];
}

- (NSData *)dataBySerializingObject:(NSObject *)object {
    NSError *error = nil;
    NSJSONWritingOptions options = 0;
    #ifdef FYDebug
        options |= NSJSONWritingPrettyPrinted;
    #endif
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:options error:&error];
    if (error) {
        // Object data was malformed.
        NSError *fyError = [NSError errorWithDomain:FYErrorDomain code:FYErrorMalformedObjectData userInfo:@{
             NSLocalizedDescriptionKey: @"Can't serialize malformed data.",
             NSUnderlyingErrorKey:      error,
         }];
        [self.clientDelegateProxy client:self failedWithError:fyError];
        return nil;
    }
    return data;
}

- (id)deserializeString:(NSString *)string {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    return [self deserializeData:data];
}

- (id)deserializeData:(NSData *)data {
    NSError *error = nil;
    id result = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:&error];
    if (error) {
        // JSON string was malformed.
        NSError *fyError = [NSError errorWithDomain:FYErrorDomain code:FYErrorMalformedJSONData userInfo:@{
             NSLocalizedDescriptionKey: @"JSON data is malformed.",
             NSUnderlyingErrorKey:      error,
         }];
        [self.clientDelegateProxy client:self failedWithError:fyError];
        return nil;
    } else {
        return result;
    }
}


#pragma mark - Generic helper

- (void)performBlock:(void(^)(FYClient *))block afterDelay:(NSTimeInterval)delay {
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_SEC);
    __weak FYClient *this = self;
    dispatch_after(popTime, self.workerQueue, ^{
        block(this);
     });
}

- (void)chainActorForMetaChannel:(NSString *)channel onceWithActorBlock:(FYActorBlock)block {
    self.metaChannelActors[channel] = [FYBlockActor chain:self.metaChannelActors[channel]
                                                     once:block
                                                  restore:^(id<FYActor> actor) {
                                                      self.metaChannelActors[channel] = actor;
                                                  }];
}

@end
