//
//  NSError+ALTError.m
//  AltSign
//
//  Created by Riley Testut on 5/10/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

#import "NSError+ALTErrors.h"

NSErrorDomain const AltSignErrorDomain = @"AltSign.Error";
NSErrorDomain const ALTAppleAPIErrorDomain = @"AltStore.AppleDeveloperError";
NSErrorDomain const ALTUnderlyingAppleAPIErrorDomain = @"Apple.APIError";

NSErrorUserInfoKey const ALTSourceFileErrorKey = @"ALTSourceFile";
NSErrorUserInfoKey const ALTSourceLineErrorKey = @"ALTSourceLine";
NSErrorUserInfoKey const ALTAppNameErrorKey = @"appName";
NSErrorUserInfoKey const ALTAppleAPIRequestOperationErrorKey = @"ALTAppleAPIRequestOperation";
NSErrorUserInfoKey const ALTAppleAPIHTTPStatusCodeErrorKey = @"ALTAppleAPIHTTPStatusCode";
NSErrorUserInfoKey const ALTAppleAPIResponseMIMETypeErrorKey = @"ALTAppleAPIResponseMIMEType";

@implementation NSError (ALTError)

+ (void)load
{
    [NSError setUserInfoValueProviderForDomain:AltSignErrorDomain provider:^id _Nullable(NSError * _Nonnull error, NSErrorUserInfoKey  _Nonnull userInfoKey) {
        if ([userInfoKey isEqualToString:NSLocalizedDescriptionKey])
        {
            if ([error altsign_localizedFailure] != nil)
            {
                // Error has localizedFailure, so return nil to construct localizedDescription from it + localizedFailureReason.
                return nil;
            }
            else
            {
                // Otherwise, return failureReason for localizedDescription to avoid system prepending "Operation Failed" message.
                // Do NOT return [error alt_localizedFailureReason], which might be unexpectedly nil if unrecognized error code.
                return error.localizedFailureReason;
            }
        }
        else if ([userInfoKey isEqualToString:NSLocalizedFailureReasonErrorKey])
        {
            // Return failureReason for both keys to prevent prepending "Operation Failed" message to localizedDescription.
            return [error alt_localizedFailureReason];
        }
        else if ([userInfoKey isEqualToString:NSLocalizedRecoverySuggestionErrorKey])
        {
            return [error altsign_localizedRecoverySuggestion];
        }

        return nil;
    }];

    [NSError setUserInfoValueProviderForDomain:ALTAppleAPIErrorDomain provider:^id _Nullable(NSError * _Nonnull error, NSErrorUserInfoKey  _Nonnull userInfoKey) {
        if ([userInfoKey isEqualToString:NSLocalizedDescriptionKey])
        {
            if ([error altsign_localizedFailure] != nil)
            {
                // Error has localizedFailure, so return nil to construct localizedDescription from it + localizedFailureReason.
                return nil;
            }
            else
            {
                // Otherwise, return failureReason for localizedDescription to avoid system prepending "Operation Failed" message.
                // Do NOT return [error alt_appleapi_localizedFailureReason], which might be unexpectedly nil if unrecognized error code.
                return error.localizedFailureReason;
            }
        }
        else if ([userInfoKey isEqualToString:NSLocalizedFailureReasonErrorKey])
        {
            // Return failureReason for both keys to prevent prepending "Operation Failed" message to localizedDescription.
            return [error alt_appleapi_localizedFailureReason];
        }
        else if ([userInfoKey isEqualToString:NSLocalizedRecoverySuggestionErrorKey])
        {
            return [error alt_appleapi_localizedRecoverySuggestion];
        }

        return nil;
    }];
}

- (nullable NSString *)altsign_localizedFailure
{
    // Copied logic from AltStore's NSError+AltStore.swift.
    NSString *localizedFailure = self.userInfo[NSLocalizedFailureErrorKey];
    if (localizedFailure != nil)
    {
        return localizedFailure;
    }

    id (^provider)(NSError *, NSErrorUserInfoKey) = [NSError userInfoValueProviderForDomain:self.domain];
    if (provider == nil)
    {
        return nil;
    }

    localizedFailure = provider(self, NSLocalizedFailureErrorKey);
    return localizedFailure;
}

- (nullable NSString *)alt_localizedFailureReason
{
    switch ((ALTError)self.code)
    {
        case ALTErrorUnknown:
            return NSLocalizedString(@"AltForge could not determine why the app could not be signed.", @"");

        case ALTErrorInvalidApp:
            return NSLocalizedString(@"The app is invalid.", @"");

        case ALTErrorMissingAppBundle:
            return NSLocalizedString(@"The provided .ipa does not contain an app bundle.", @"");

        case ALTErrorMissingInfoPlist:
            return NSLocalizedString(@"The provided app is missing its Info.plist.", @"");

        case ALTErrorMissingProvisioningProfile:
            return NSLocalizedString(@"Could not find matching provisioning profile.", @"");

        case ALTErrorMissingAppleRootCertificate:
            return NSLocalizedString(@"The Apple root signing certificate could not be found.", @"");

        case ALTErrorInvalidCertificate:
            return NSLocalizedString(@"The signing certificate is invalid or has expired.", @"");

        case ALTErrorInvalidProvisioningProfile:
            return NSLocalizedString(@"The provisioning profile is invalid or has expired.", @"");
    }

    return nil;
}

- (nullable NSString *)altsign_localizedRecoverySuggestion
{
    switch ((ALTError)self.code)
    {
        case ALTErrorInvalidApp:
        case ALTErrorMissingAppBundle:
        case ALTErrorMissingInfoPlist:
            return NSLocalizedString(@"Download or export the app again from a trusted source, then retry with the new IPA file.", @"");

        case ALTErrorMissingProvisioningProfile:
            return NSLocalizedString(@"Sign in with your Apple ID again so AltForge can create a new provisioning profile.", @"");

        case ALTErrorMissingAppleRootCertificate:
            return NSLocalizedString(@"Update the operating system's trusted certificates, then try again.", @"");

        case ALTErrorInvalidCertificate:
        case ALTErrorInvalidProvisioningProfile:
            return NSLocalizedString(@"Sign in with your Apple ID again so AltForge can create fresh signing assets.", @"");

        case ALTErrorUnknown:
            return NSLocalizedString(@"Try again. If the problem continues, update AltForge and AltForge Server before retrying.", @"");
    }

    return nil;
}

- (nullable NSString *)alt_appleapi_localizedFailureReason
{
    switch ((ALTAppleAPIError)self.code)
    {
        case ALTAppleAPIErrorUnknown:
            return NSLocalizedString(@"Apple Developer services returned an unknown error.", @"");

        case ALTAppleAPIErrorInvalidParameters:
            return NSLocalizedString(@"AltForge sent an invalid request to Apple Developer services.", @"");

        case ALTAppleAPIErrorIncorrectCredentials:
            return NSLocalizedString(@"Your Apple ID or password is incorrect.", @"");

        case ALTAppleAPIErrorNoTeams:
            return NSLocalizedString(@"You are not a member of any development teams.", @"");

        case ALTAppleAPIErrorAppSpecificPasswordRequired:
            return NSLocalizedString(@"This Apple ID requires an app-specific password.", @"");

        case ALTAppleAPIErrorInvalidDeviceID:
            return NSLocalizedString(@"This device's UDID is invalid.", @"");

        case ALTAppleAPIErrorDeviceAlreadyRegistered:
            return NSLocalizedString(@"This device is already registered with this team.", @"");

        case ALTAppleAPIErrorInvalidCertificateRequest:
            return NSLocalizedString(@"The certificate request is invalid.", @"");

        case ALTAppleAPIErrorCertificateDoesNotExist:
            return NSLocalizedString(@"There is no certificate with the requested serial number for this team.", @"");

        case ALTAppleAPIErrorInvalidAppIDName:
        {
            NSString *appName = self.userInfo[ALTAppNameErrorKey];
            if (appName != nil)
            {
                return [NSString stringWithFormat:NSLocalizedString(@"The name “%@” contains invalid characters.", @""), appName];
            }

            return NSLocalizedString(@"The name of this app contains invalid characters.", @"");
        }

        case ALTAppleAPIErrorInvalidBundleIdentifier:
            return NSLocalizedString(@"The bundle identifier for this app is invalid.", @"");

        case ALTAppleAPIErrorBundleIdentifierUnavailable:
            return NSLocalizedString(@"The bundle identifier for this app has already been registered.", @"");

        case ALTAppleAPIErrorAppIDDoesNotExist:
            return NSLocalizedString(@"There is no App ID with the requested identifier on this team.", @"");

        case ALTAppleAPIErrorMaximumAppIDLimitReached:
            return NSLocalizedString(@"You may only register 10 App IDs every 7 days.", @"");

        case ALTAppleAPIErrorInvalidAppGroup:
            return NSLocalizedString(@"The provided app group is invalid.", @"");

        case ALTAppleAPIErrorAppGroupDoesNotExist:
            return NSLocalizedString(@"The requested app group does not exist on this team.", @"");

        case ALTAppleAPIErrorInvalidProvisioningProfileIdentifier:
            return NSLocalizedString(@"The identifier for the requested provisioning profile is invalid.", @"");

        case ALTAppleAPIErrorProvisioningProfileDoesNotExist:
            return NSLocalizedString(@"There is no provisioning profile with the requested identifier on this team.", @"");

        case ALTAppleAPIErrorRequiresTwoFactorAuthentication:
            return NSLocalizedString(@"This account requires signing in with two-factor authentication.", @"");

        case ALTAppleAPIErrorIncorrectVerificationCode:
            return NSLocalizedString(@"Incorrect verification code.", @"");

        case ALTAppleAPIErrorAuthenticationHandshakeFailed:
            return NSLocalizedString(@"The secure sign-in with Apple could not be completed.", @"");

        case ALTAppleAPIErrorInvalidAnisetteData:
            return NSLocalizedString(@"This Mac's Apple authentication data is missing or invalid.", @"");

        case ALTAppleAPIErrorInvalidResponse:
            return NSLocalizedString(@"Apple Developer services returned a response that AltForge could not read.", @"");
    }

    return nil;
}

- (nullable NSString *)alt_appleapi_localizedRecoverySuggestion
{
    switch ((ALTAppleAPIError)self.code)
    {
        case ALTAppleAPIErrorUnknown:
        case ALTAppleAPIErrorInvalidParameters:
            return NSLocalizedString(@"Update AltForge and AltForge Server, then try again.", @"");

        case ALTAppleAPIErrorIncorrectCredentials:
            return NSLocalizedString(@"Check the Apple ID and password, then try again.", @"");

        case ALTAppleAPIErrorAppSpecificPasswordRequired:
            return NSLocalizedString(@"Create an app-specific password at appleid.apple.com, then sign in with it.", @"");

        case ALTAppleAPIErrorNoTeams:
            return NSLocalizedString(@"Check that this Apple ID can use Apple Developer services and has accepted the latest Apple agreements, then try again.", @"");

        case ALTAppleAPIErrorInvalidDeviceID:
            return NSLocalizedString(@"Reconnect and unlock the device, then trust this computer when prompted.", @"");

        case ALTAppleAPIErrorDeviceAlreadyRegistered:
            return NSLocalizedString(@"The device is already registered. Try the installation again.", @"");

        case ALTAppleAPIErrorInvalidCertificateRequest:
        case ALTAppleAPIErrorCertificateDoesNotExist:
            return NSLocalizedString(@"Sign in again so AltForge can prepare a valid development certificate.", @"");

        case ALTAppleAPIErrorInvalidAppIDName:
        case ALTAppleAPIErrorInvalidBundleIdentifier:
        case ALTAppleAPIErrorBundleIdentifierUnavailable:
            return NSLocalizedString(@"Use a complete, unmodified IPA from a trusted source. If the problem continues, try another Apple ID.", @"");

        case ALTAppleAPIErrorAppIDDoesNotExist:
        case ALTAppleAPIErrorInvalidAppGroup:
        case ALTAppleAPIErrorAppGroupDoesNotExist:
        case ALTAppleAPIErrorInvalidProvisioningProfileIdentifier:
        case ALTAppleAPIErrorProvisioningProfileDoesNotExist:
            return NSLocalizedString(@"Try the installation again so AltForge can recreate the required Apple Developer records.", @"");

        case ALTAppleAPIErrorMaximumAppIDLimitReached:
            return NSLocalizedString(@"Wait for an existing App ID to expire, or use a paid Apple Developer account.", @"");

        case ALTAppleAPIErrorRequiresTwoFactorAuthentication:
            return NSLocalizedString(@"Enter the latest six-digit verification code sent to your trusted Apple device.", @"");

        case ALTAppleAPIErrorIncorrectVerificationCode:
            return NSLocalizedString(@"Sign in again to request a new verification code, then enter the latest code.", @"");

        case ALTAppleAPIErrorAuthenticationHandshakeFailed:
            return NSLocalizedString(@"Check the network and device date and time, then update AltForge Server before retrying.", @"");

        case ALTAppleAPIErrorInvalidAnisetteData:
#if TARGET_OS_OSX
            return NSLocalizedString(@"Check this Mac's date and time, then update AltForge Server before retrying.", @"");
#else
            return NSLocalizedString(@"Check the computer's date and time, then update AltForge Server before retrying.", @"");
#endif

        case ALTAppleAPIErrorInvalidResponse:
            return NSLocalizedString(@"Check the network, then update AltForge and AltForge Server before retrying.", @"");
    }

    return nil;
}

@end
