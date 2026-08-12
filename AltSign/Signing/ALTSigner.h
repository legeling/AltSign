//
//  ALTSigner.h
//  AltSign
//
//  Created by Riley Testut on 5/22/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

#import <Foundation/Foundation.h>

@class ALTAppID;
@class ALTTeam;
@class ALTCertificate;
@class ALTProvisioningProfile;

NS_ASSUME_NONNULL_BEGIN

typedef void (^ALTSigningProgressHandler)(NSString *detail);

@interface ALTSigner : NSObject

@property (nonatomic) ALTTeam *team;
@property (nonatomic) ALTCertificate *certificate;

- (instancetype)initWithTeam:(ALTTeam *)team certificate:(ALTCertificate *)certificate;

- (NSProgress *)signAppAtURL:(NSURL *)appURL provisioningProfiles:(NSArray<ALTProvisioningProfile *> *)profiles completionHandler:(void (^)(BOOL success, NSError *_Nullable error))completionHandler;

- (NSProgress *)signAppAtURL:(NSURL *)appURL
        provisioningProfiles:(NSArray<ALTProvisioningProfile *> *)profiles
             progressHandler:(nullable ALTSigningProgressHandler)progressHandler
           completionHandler:(void (^)(BOOL success, NSError *_Nullable error))completionHandler;

@end

NS_ASSUME_NONNULL_END
