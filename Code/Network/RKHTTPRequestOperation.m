//
//  RKHTTPRequestOperation.m
//  RestKit
//
//  Created by Blake Watters on 8/7/12.
//  Copyright (c) 2012 RestKit. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "RKHTTPRequestOperation.h"
#import "RKLog.h"
#import "lcl_RK.h"
#import "RKHTTPUtilities.h"
#import "RKMIMETypes.h"

typedef signed short RKOperationState;

extern NSString * const RKErrorDomain;

static NSString * const kRKNetworkingLockName = @"com.restkit.networking.operation.lock";

NSString *const RKHTTPRequestOperationDidStartNotification = @"RKHTTPRequestOperationDidStartNotification";
NSString *const RKHTTPRequestOperationDidFinishNotification = @"RKHTTPRequestOperationDidFinishNotification";

// Set Logging Component
#undef RKLogComponent
#define RKLogComponent RKlcl_cRestKitNetwork

NSString *RKStringFromIndexSet(NSIndexSet *indexSet); // Defined in RKResponseDescriptor.m

const NSMutableIndexSet *acceptableStatusCodes;
const NSMutableSet *acceptableContentTypes;

@interface RKHTTPRequestOperation ()

@property (readwrite, nonatomic, strong) NSError *rkHTTPError;
@property (readwrite, nonatomic, strong) id<RKHTTPClient> HTTPClient;
@property (readwrite, nonatomic, strong) NSURLRequest *request;
@property (readwrite, nonatomic, strong) NSHTTPURLResponse *response;
@property (readwrite, nonatomic, strong) NSError *error;
@property (readwrite, nonatomic, strong) NSData *responseData;
@property (readwrite, nonatomic, strong) NSString *responseString;
@property (readwrite, nonatomic, strong) id responseObject;
@property (readwrite, nonatomic, strong) NSError *responseSerializationError;
@property (readwrite, nonatomic, strong) NSRecursiveLock *lock;
@property (readwrite, nonatomic, strong) NSURLSessionTask *requestTask;

@end

@implementation RKHTTPRequestOperation

- (void)dealloc
{
#if !OS_OBJECT_USE_OBJC
    if (_failureCallbackQueue) dispatch_release(_failureCallbackQueue);
    if (_successCallbackQueue) dispatch_release(_successCallbackQueue);
#endif
    _failureCallbackQueue = NULL;
    _successCallbackQueue = NULL;
}

- (instancetype)initWithRequest:(NSURLRequest *)urlRequest HTTPClient:(id<RKHTTPClient>)HTTPClient{
    
    NSParameterAssert(urlRequest);
    NSParameterAssert(HTTPClient);
    
    self = [super init];
    if (!self) {
        return nil;
    }
    
    self.isExecuting = NO;
    self.isFinished = NO;
    self.lock = [[NSRecursiveLock alloc] init];
    self.lock.name = kRKNetworkingLockName;
    self.request = urlRequest;
    self.HTTPClient = HTTPClient;
    
    return self;
}

+ (BOOL)canProcessRequest:(NSURLRequest *)request
{
    return YES;
}

- (void)setSuccessCallbackQueue:(dispatch_queue_t)successCallbackQueue
{
    if (successCallbackQueue != _successCallbackQueue) {
        if (_successCallbackQueue) {
#if !OS_OBJECT_USE_OBJC
            dispatch_release(_successCallbackQueue);
#endif
            _successCallbackQueue = NULL;
        }
        
        if (successCallbackQueue) {
#if !OS_OBJECT_USE_OBJC
            dispatch_retain(successCallbackQueue);
#endif
            _successCallbackQueue = successCallbackQueue;
        }
    }
}

- (void)setFailureCallbackQueue:(dispatch_queue_t)failureCallbackQueue
{
    if (failureCallbackQueue != _failureCallbackQueue) {
        if (_failureCallbackQueue) {
#if !OS_OBJECT_USE_OBJC
            dispatch_release(_failureCallbackQueue);
#endif
            _failureCallbackQueue = NULL;
        }
        
        if (failureCallbackQueue) {
#if !OS_OBJECT_USE_OBJC
            dispatch_retain(failureCallbackQueue);
#endif
            _failureCallbackQueue = failureCallbackQueue;
        }
    }
}

#pragma mark - NSOperation

- (BOOL)isReady {
    
    return  ![self isExecuting] &&
            ![self isFinished] &&
            ![self isCancelled] &&
            [super isReady];
}

- (BOOL)isPaused {
    return self.requestTask && self.requestTask.state == NSURLSessionTaskStateSuspended;
}

- (BOOL)isExecuting {
    return self.requestTask && self.requestTask.state == NSURLSessionTaskStateRunning;
}

- (BOOL)isFinished {
    return self.requestTask && self.requestTask.state == NSURLSessionTaskStateCompleted;
}

- (BOOL)isCancelled {
    return [super isCancelled] || [self isFinished];
}

- (BOOL)isConcurrent {
    return YES;
}

- (void)setIsExecuting:(BOOL)isExecuting {
    [self willChangeValueForKey:@"isExecuting"];
    [self didChangeValueForKey:@"isExecuting"];
}

- (void)setIsFinished:(BOOL)isFinished {
    [self willChangeValueForKey:@"isFinished"];
    [self didChangeValueForKey:@"isFinished"];
}

- (void)setIsCancelled:(BOOL)isFinished {
    [self willChangeValueForKey:@"isCancelled"];
    [self didChangeValueForKey:@"isCancelled"];
}

- (void)start {
    
    [self.lock lock];
    if ([self isReady]) {
        
        // Notify observers/queue
        self.isExecuting = YES;

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:RKHTTPRequestOperationDidStartNotification object:self];
        });
        
        self.requestTask = [self.HTTPClient performRequest:self.request
                                     acceptableStatusCodes:self.acceptableStatusCodes
                                    acceptableContentTypes:self.acceptableContentTypes
                                         completionHandler:^(id responseObject, NSData *responseData, NSURLResponse *response, NSError *error) {
            
            self.responseData = responseData;
            self.responseString = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
            self.responseObject = responseObject;            
            self.response = (NSHTTPURLResponse*) response;
            self.error = error;
            [self finish];
        }];
    }
    [self.lock unlock];
}

- (void)pause {
    
    if ([self isPaused] || [self isFinished] || [self isCancelled]) {
        return;
    }
    
    [self.lock lock];
    
    [self.requestTask suspend];
    
    self.isExecuting = NO;
    
    [self.lock unlock];
}


- (void)resume {
    
    if (![self isPaused]) {
        return;
    }
    
    [self.lock lock];
    
    [self.requestTask resume];
    
    self.isExecuting = YES;

    [self.lock unlock];
}


- (void)finish {

    // Notify observers/queue
    self.isExecuting = NO;
    self.isFinished = YES;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:RKHTTPRequestOperationDidFinishNotification object:self];
    });
}

- (void)cancel {
    
    [self.lock lock];
    if (![self isFinished] && ![self isCancelled]) {
        
        [self.requestTask cancel];
        
        self.isCancelled = YES;
        [super cancel];
    }
    [self.lock unlock];
}

- (void)setCompletionBlockWithSuccess:(void (^)(RKHTTPRequestOperation *operation, id responseObject))success
                              failure:(void (^)(RKHTTPRequestOperation *operation, NSError *error))failure{
    
    __weak typeof(self) weakSelf = self;
    self.completionBlock = ^{
        if (weakSelf.error) {
            if (failure) {
                dispatch_async(weakSelf.failureCallbackQueue ?: dispatch_get_main_queue(), ^{
                    failure(weakSelf, weakSelf.error);
                });
            }
        } else {
            if (success) {
                dispatch_async(weakSelf.successCallbackQueue ?: dispatch_get_main_queue(), ^{
                    success(weakSelf, weakSelf.responseData);
                });
            }
        }
    };
}


#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    RKHTTPRequestOperation *operation = [(RKHTTPRequestOperation *)[[self class] allocWithZone:zone] initWithRequest:self.request HTTPClient:self.HTTPClient];
    
    operation.successCallbackQueue = self.successCallbackQueue;
    operation.failureCallbackQueue = self.failureCallbackQueue;
    
    return operation;
}

@end
