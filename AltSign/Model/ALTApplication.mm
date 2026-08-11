//
//  ALTApplication.m
//  AltSign
//
//  Created by Riley Testut on 6/24/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

#import "ALTApplication.h"
#import "ALTProvisioningProfile.h"

#include "alt_ldid.hpp"

ALTDeviceType ALTDeviceTypeFromUIDeviceFamily(NSInteger deviceFamily)
{
    switch (deviceFamily)
    {
        case 1: return ALTDeviceTypeiPhone;
        case 2: return ALTDeviceTypeiPad;
        case 3: return ALTDeviceTypeAppleTV;
        default: return ALTDeviceTypeNone;
    }
}

@interface ALTApplication ()

@property (nonatomic, copy, nullable, readonly) NSString *iconName;

@end

@implementation ALTApplication
@synthesize entitlements = _entitlements;
@synthesize entitlementsString = _entitlementsString;
@synthesize provisioningProfile = _provisioningProfile;

- (instancetype)initWithFileURL:(NSURL *)fileURL
{
    self = [super init];
    if (self)
    {
        NSBundle *bundle = [NSBundle bundleWithURL:fileURL];
        if (bundle == nil)
        {
            return nil;
        }
        
        // Load info dictionary directly from disk, since NSBundle caches values
        // that might not reflect the updated values on disk (such as bundle identifier).
        NSURL *infoPlistURL = [bundle.bundleURL URLByAppendingPathComponent:@"Info.plist"];
        NSDictionary *infoDictionary = [NSDictionary dictionaryWithContentsOfURL:infoPlistURL];
        if (infoDictionary == nil)
        {
            return nil;
        }
        
        id displayNameValue = infoDictionary[@"CFBundleDisplayName"];
        id bundleNameValue = infoDictionary[(NSString *)kCFBundleNameKey];
        id bundleIdentifierValue = infoDictionary[(NSString *)kCFBundleIdentifierKey];

        NSString *name = [displayNameValue isKindOfClass:[NSString class]] ? displayNameValue : nil;
        if (name.length == 0 && [bundleNameValue isKindOfClass:[NSString class]])
        {
            name = bundleNameValue;
        }

        NSString *bundleIdentifier = [bundleIdentifierValue isKindOfClass:[NSString class]] ? bundleIdentifierValue : nil;
                
        if (name.length == 0 || bundleIdentifier.length == 0)
        {
            return nil;
        }
        
        // These technically can be nil, but in practice every app should have a version and build version.
        id versionValue = infoDictionary[@"CFBundleShortVersionString"];
        id buildVersionValue = infoDictionary[(NSString *)kCFBundleVersionKey];
        NSString *version = [versionValue isKindOfClass:[NSString class]] ? versionValue : @"1.0";
        NSString *buildVersion = [buildVersionValue isKindOfClass:[NSString class]] ? buildVersionValue : @"1";
        
        id minimumVersionValue = infoDictionary[@"MinimumOSVersion"];
        NSString *minimumVersionString = [minimumVersionValue isKindOfClass:[NSString class]] ? minimumVersionValue : @"1.0";
        NSArray *versionComponents = [minimumVersionString componentsSeparatedByString:@"."];
        
        NSInteger majorVersion = [versionComponents.firstObject integerValue];
        NSInteger minorVersion = (versionComponents.count > 1) ? [versionComponents[1] integerValue] : 0;
        NSInteger patchVersion = (versionComponents.count > 2) ? [versionComponents[2] integerValue] : 0;
        
        NSOperatingSystemVersion minimumVersion;
        minimumVersion.majorVersion = majorVersion;
        minimumVersion.minorVersion = minorVersion;
        minimumVersion.patchVersion = patchVersion;
        
        NSArray<NSNumber *> *deviceFamilies = infoDictionary[@"UIDeviceFamily"];
        ALTDeviceType supportedDeviceTypes = ALTDeviceTypeNone;
        
        if ([deviceFamilies isKindOfClass:[NSNumber class]])
        {
            NSInteger rawDeviceFamily = [(NSNumber *)deviceFamilies integerValue];
            supportedDeviceTypes = ALTDeviceTypeFromUIDeviceFamily(rawDeviceFamily);
        }
        else if ([deviceFamilies isKindOfClass:[NSArray class]] && deviceFamilies.count > 0)
        {
            for (id deviceFamily in deviceFamilies)
            {
                if (![deviceFamily isKindOfClass:[NSNumber class]])
                {
                    continue;
                }

                NSInteger rawDeviceFamily = [deviceFamily integerValue];
                supportedDeviceTypes |= ALTDeviceTypeFromUIDeviceFamily(rawDeviceFamily);
            }
        }
        else
        {
            supportedDeviceTypes = ALTDeviceTypeiPhone;
        }
        
        id iconsValue = infoDictionary[@"CFBundleIcons"];
        NSDictionary *icons = [iconsValue isKindOfClass:[NSDictionary class]] ? iconsValue : nil;
        id primaryIcon = icons[@"CFBundlePrimaryIcon"];
        
        NSString *iconName = nil;
        
        if ([primaryIcon isKindOfClass:[NSString class]])
        {
            iconName = (NSString *)primaryIcon;
        }
        else
        {
            id iconFilesValue = [primaryIcon isKindOfClass:[NSDictionary class]] ? primaryIcon[@"CFBundleIconFiles"] : nil;
            if (![iconFilesValue isKindOfClass:[NSArray class]])
            {
                iconFilesValue = infoDictionary[@"CFBundleIconFiles"];
            }

            if ([iconFilesValue isKindOfClass:[NSArray class]])
            {
                id lastIconValue = [(NSArray *)iconFilesValue lastObject];
                iconName = [lastIconValue isKindOfClass:[NSString class]] ? lastIconValue : nil;
            }

            if (iconName.length == 0)
            {
                id legacyIconValue = infoDictionary[@"CFBundleIconFile"];
                iconName = [legacyIconValue isKindOfClass:[NSString class]] ? legacyIconValue : nil;
            }
        }
        
        _bundle = bundle;
        _fileURL = [fileURL copy];
        _name = [name copy];
        _bundleIdentifier = [bundleIdentifier copy];
        _version = [version copy];
        _buildVersion = [buildVersion copy];
        _minimumiOSVersion = minimumVersion;
        _supportedDeviceTypes = supportedDeviceTypes;
        _iconName = [iconName copy];
    }
    
    return self;
}

#if TARGET_OS_IPHONE
- (UIImage *)icon
{
    NSString *iconName = self.iconName;
    if (iconName == nil)
    {
        return nil;
    }
    
    UIImage *icon = [UIImage imageNamed:iconName inBundle:self.bundle compatibleWithTraitCollection:nil];
    return icon;
}
#endif

- (NSDictionary<ALTEntitlement,id> *)entitlements
{
    if (_entitlements == nil)
    {
        NSDictionary<NSString *, id> *appEntitlements = @{};
        
        if (self.entitlementsString.length != 0)
        {
            NSData *entitlementsData = [self.entitlementsString dataUsingEncoding:NSUTF8StringEncoding];
            
            NSError *error = nil;
            NSDictionary *entitlements = [NSPropertyListSerialization propertyListWithData:entitlementsData options:0 format:nil error:&error];
            
            if (entitlements != nil)
            {
                appEntitlements = entitlements;
            }
            else
            {
                NSLog(@"Error parsing entitlements: %@", error);
            }
        }
        
        _entitlements = appEntitlements;
    }
    
    return _entitlements;
}

- (NSString *)entitlementsString
{
    if (_entitlementsString == nil)
    {
        NSString *path = [self.fileURL.path.stringByStandardizingPath stringByAppendingString:@"/"];
        
        std::string rawEntitlements = ldid::Entitlements(path.fileSystemRepresentation);
        _entitlementsString = @(rawEntitlements.c_str());
    }
    
    return _entitlementsString;
}

- (ALTProvisioningProfile *)provisioningProfile
{
    if (_provisioningProfile == nil)
    {
        NSURL *provisioningProfileURL = [self.fileURL URLByAppendingPathComponent:@"embedded.mobileprovision"];
        _provisioningProfile = [[ALTProvisioningProfile alloc] initWithURL:provisioningProfileURL];
    }
    
    return _provisioningProfile;
}

- (NSSet<ALTApplication *> *)appExtensions
{
    NSMutableSet *appExtensions = [NSMutableSet set];
    
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtURL:self.bundle.builtInPlugInsURL includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsSubdirectoryDescendants errorHandler:nil];
    for (NSURL *fileURL in enumerator)
    {
        if (![fileURL.pathExtension.lowercaseString isEqualToString:@"appex"])
        {
            continue;
        }
        
        ALTApplication *appExtension = [[ALTApplication alloc] initWithFileURL:fileURL];
        if (appExtension == nil)
        {
            continue;
        }
        
        [appExtensions addObject:appExtension];
    }
    
    return appExtensions;
}

@end
