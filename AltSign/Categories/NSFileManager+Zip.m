//
//  NSFileManager+Zip.m
//  AltSign
//
//  Created by Riley Testut on 5/28/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

#import "NSFileManager+Zip.h"

#import "NSError+ALTErrors.h"

#import <CoreFoundation/CoreFoundation.h>

#include "zip.h"
#include "unzip.h"

int ALTReadBufferSize = 8192;
char ALTDirectoryDeliminator = '/';

#define READ_BUFFER_SIZE 8192
#define MAX_FILENAME 512

static const uLong ALTZipUTF8FilenameFlag = 1 << 11;
static const uint16_t ALTZipUnicodePathExtraFieldIdentifier = 0x7075;

static uint16_t ALTReadUInt16LittleEndian(const uint8_t *bytes)
{
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

static uint32_t ALTReadUInt32LittleEndian(const uint8_t *bytes)
{
    return (uint32_t)bytes[0] |
           ((uint32_t)bytes[1] << 8) |
           ((uint32_t)bytes[2] << 16) |
           ((uint32_t)bytes[3] << 24);
}

static NSString *ALTUnicodeFilenameFromExtraField(NSData *filenameData, NSData *extraFieldData)
{
    const uint8_t *extraBytes = extraFieldData.bytes;
    NSUInteger offset = 0;

    while (offset + 4 <= extraFieldData.length)
    {
        uint16_t identifier = ALTReadUInt16LittleEndian(extraBytes + offset);
        uint16_t fieldLength = ALTReadUInt16LittleEndian(extraBytes + offset + 2);
        offset += 4;

        if (fieldLength > extraFieldData.length - offset)
        {
            return nil;
        }

        if (identifier == ALTZipUnicodePathExtraFieldIdentifier && fieldLength >= 5)
        {
            const uint8_t *fieldBytes = extraBytes + offset;
            uint32_t expectedCRC = ALTReadUInt32LittleEndian(fieldBytes + 1);
            uLong actualCRC = crc32(0L, Z_NULL, 0);
            actualCRC = crc32(actualCRC, filenameData.bytes, (uInt)filenameData.length);

            if (fieldBytes[0] == 1 && expectedCRC == (uint32_t)actualCRC)
            {
                NSData *unicodeFilenameData = [NSData dataWithBytes:fieldBytes + 5 length:fieldLength - 5];
                NSString *filename = [[NSString alloc] initWithData:unicodeFilenameData encoding:NSUTF8StringEncoding];
                if (filename.length > 0)
                {
                    return filename;
                }
            }
        }

        offset += fieldLength;
    }

    return nil;
}

static NSDictionary *ALTLegacyFilenameEncodingOptions(void)
{
    static NSDictionary *options;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSNumber *> *legacyEncodings = @[
            @(CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000)),
            @(CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSChineseSimplif)),
            @(CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingBig5)),
            @(CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSChineseTrad)),
            @(NSShiftJISStringEncoding),
            @(CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingEUC_KR)),
            @(CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSLatinUS)),
        ];

        options = @{
            NSStringEncodingDetectionSuggestedEncodingsKey: legacyEncodings,
            NSStringEncodingDetectionUseOnlySuggestedEncodingsKey: @YES,
            NSStringEncodingDetectionAllowLossyKey: @NO,
            NSStringEncodingDetectionFromWindowsKey: @YES,
        };
    });

    return options;
}

static NSString *ALTDecodeZipFilename(NSData *filenameData, NSData *extraFieldData, uLong flags)
{
    if (filenameData.length == 0)
    {
        return nil;
    }

    if ((flags & ALTZipUTF8FilenameFlag) != 0)
    {
        NSString *filename = [[NSString alloc] initWithData:filenameData encoding:NSUTF8StringEncoding];
        if (filename.length > 0)
        {
            return filename;
        }
    }

    NSString *unicodeFilename = ALTUnicodeFilenameFromExtraField(filenameData, extraFieldData);
    if (unicodeFilename.length > 0)
    {
        return unicodeFilename;
    }

    // Some IPA creators write UTF-8 filenames without setting ZIP's UTF-8 flag.
    NSString *filename = [[NSString alloc] initWithData:filenameData encoding:NSUTF8StringEncoding];
    if (filename.length > 0)
    {
        return filename;
    }

    BOOL usedLossyConversion = NO;
    [NSString stringEncodingForData:filenameData
                    encodingOptions:ALTLegacyFilenameEncodingOptions()
                    convertedString:&filename
                usedLossyConversion:&usedLossyConversion];

    return !usedLossyConversion && filename.length > 0 ? filename : nil;
}

static NSString *ALTCurrentZipFilename(unzFile zipFile, unz_file_info *info)
{
    if (unzGetCurrentFileInfo(zipFile, info, NULL, 0, NULL, 0, NULL, 0) != UNZ_OK)
    {
        return nil;
    }

    NSMutableData *filenameData = [NSMutableData dataWithLength:info->size_filename];
    NSMutableData *extraFieldData = [NSMutableData dataWithLength:info->size_file_extra];

    if (unzGetCurrentFileInfo(zipFile,
                              info,
                              filenameData.mutableBytes,
                              info->size_filename,
                              extraFieldData.mutableBytes,
                              info->size_file_extra,
                              NULL,
                              0) != UNZ_OK)
    {
        return nil;
    }

    return ALTDecodeZipFilename(filenameData, extraFieldData, info->flag);
}

static BOOL ALTIsSafeArchivePath(NSString *filename)
{
    if (filename.length == 0 || filename.isAbsolutePath)
    {
        return NO;
    }

    for (NSString *component in [filename componentsSeparatedByString:@"/"])
    {
        if ([component isEqualToString:@".."])
        {
            return NO;
        }
    }

    return YES;
}

@implementation NSFileManager (Zip)

- (BOOL)unzipArchiveAtURL:(NSURL *)archiveURL toDirectory:(NSURL *)directoryURL error:(NSError **)error
{
    NSProgress *progress = [NSProgress progressWithTotalUnitCount:0];
    [progress setKind:NSProgressKindFile];
    [progress setUserInfoObject:NSProgressFileOperationKindDecompressingAfterDownloading forKey:NSProgressFileOperationKindKey];
    
    return [self unzipArchiveAtURL:archiveURL toDirectory:directoryURL progress:progress error:error];
}

- (BOOL)unzipArchiveAtURL:(NSURL *)archiveURL toDirectory:(NSURL *)directoryURL progress:(NSProgress *)progress error:(NSError **)error
{
    unzFile zipFile = unzOpen(archiveURL.fileSystemRepresentation);
    if (zipFile == NULL)
    {
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:@{NSURLErrorKey: archiveURL}];
        return NO;
    }
    
    __block FILE *outputFile = nil;
    char buffer[ALTReadBufferSize];
    
    void (^finish)(void) = ^{
        if (outputFile != nil)
        {
            fclose(outputFile);
        }
        
        unzCloseCurrentFile(zipFile);
        unzClose(zipFile);
    };
    
    unz_global_info zipInfo;
    if (unzGetGlobalInfo(zipFile, &zipInfo) != UNZ_OK)
    {
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{NSURLErrorKey: archiveURL}];
        
        finish();
        return NO;
    }
    
    // Calculate total uncompressed size for accurate progress reporting.
    int64_t uncompressedSize = 0;
    
    for (uLong i = 0; i < zipInfo.number_entry; i++)
    {
        unz_file_info info;
        NSString *filename = ALTCurrentZipFilename(zipFile, &info);

        if (filename == nil || !ALTIsSafeArchivePath(filename))
        {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:@{NSURLErrorKey: archiveURL}];
            
            finish();
            return NO;
        }

        if (![filename hasPrefix:@"__MACOSX"] && [filename characterAtIndex:filename.length - 1] != ALTDirectoryDeliminator)
        {
            uncompressedSize += info.uncompressed_size;
        }

        if (i + 1 < zipInfo.number_entry)
        {
            if (unzGoToNextFile(zipFile) != UNZ_OK)
            {
                *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:@{NSURLErrorKey: archiveURL}];
                
                finish();
                return NO;
            }
        }
    }
    
    if (unzGoToFirstFile(zipFile) != UNZ_OK)
    {
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:@{NSURLErrorKey: archiveURL}];
        
        finish();
        return NO;
    }
    
    progress.totalUnitCount = uncompressedSize;
    
    for (uLong i = 0; i < zipInfo.number_entry; i++)
    {
        unz_file_info info;
        NSString *filename = ALTCurrentZipFilename(zipFile, &info);

        if (filename == nil || !ALTIsSafeArchivePath(filename))
        {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:@{NSURLErrorKey: archiveURL}];
            
            finish();
            return NO;
        }

        if ([filename hasPrefix:@"__MACOSX"])
        {
            if (i + 1 < zipInfo.number_entry)
            {
                if (unzGoToNextFile(zipFile) != UNZ_OK)
                {
                    *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:@{NSFilePathErrorKey: filename}];
                    
                    finish();
                    return NO;
                }
            }
            
            continue;
        }
        
        NSError *(^createDirectory)(NSURL *) = ^NSError *(NSURL *directoryURL) {
            NSError *error = nil;
            if (![self createDirectoryAtURL:directoryURL withIntermediateDirectories:YES attributes:nil error:&error])
            {
                return error;
            }
            
            return nil;
        };
        
        NSURL *fileURL = [directoryURL URLByAppendingPathComponent:filename];
        
        if ([filename characterAtIndex:filename.length - 1] == ALTDirectoryDeliminator)
        {
            // Directory
            
            NSError *directoryError = createDirectory(fileURL);
            if (directoryError != nil)
            {
                *error = directoryError;
                finish();
                return NO;
            }
        }
        else
        {
            // File
            if (unzOpenCurrentFile(zipFile) != UNZ_OK)
            {
                *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:@{NSURLErrorKey: fileURL}];
                
                finish();
                return NO;
            }
            
            NSURL *parentDirectory = [fileURL URLByDeletingLastPathComponent];
            if (![[NSFileManager defaultManager] fileExistsAtPath:parentDirectory.path])
            {
                NSError *directoryError = createDirectory(parentDirectory);
                if (directoryError != nil)
                {
                    *error = directoryError;
                    finish();
                    return NO;
                }
            }
            
            outputFile = fopen(fileURL.fileSystemRepresentation, "wb");
            if (outputFile == NULL)
            {
                NSError *underlyingError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{NSURLErrorKey: fileURL}];
                *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:@{NSURLErrorKey: fileURL, NSUnderlyingErrorKey: underlyingError}];
                
                finish();
                return NO;
            }
            
            int result = UNZ_OK;
            
            do
            {
                result = unzReadCurrentFile(zipFile, buffer, ALTReadBufferSize);
                
                if (result < 0)
                {
                    *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:@{NSURLErrorKey: fileURL}];
                    
                    finish();
                    return NO;
                }
                
                size_t count = fwrite(buffer, result, 1, outputFile);
                if (result > 0 && count != 1)
                {
                    *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:@{NSURLErrorKey: fileURL}];
                    
                    finish();
                    return NO;
                }
                
                progress.completedUnitCount += result;
                
            } while (result > 0);
            
            short permissions = (info.external_fa >> 16) & 0x01FF;
            if (![self setAttributes:@{NSFilePosixPermissions: @(permissions)} ofItemAtPath:fileURL.path error:error])
            {
                finish();
                return NO;
            }
            
            fclose(outputFile);
            outputFile = NULL;
        }
        
        unzCloseCurrentFile(zipFile);
        
        if (i + 1 < zipInfo.number_entry)
        {
            if (unzGoToNextFile(zipFile) != UNZ_OK)
            {
                *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:@{NSURLErrorKey: fileURL}];
                
                finish();
                return NO;
            }
        }
    }
    
    finish();
    
    return YES;
}

- (nullable NSURL *)unzipAppBundleAtURL:(NSURL *)ipaURL toDirectory:(NSURL *)directoryURL error:(NSError **)error
{
    if (![self unzipArchiveAtURL:ipaURL toDirectory:directoryURL error:error])
    {
        return nil;
    }
    
    NSURL *payloadDirectory = [directoryURL URLByAppendingPathComponent:@"Payload"];
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:payloadDirectory.path error:error];
    if (contents == nil)
    {
        return nil;
    }
    
    for (NSString *filename in contents)
    {
        if ([filename.pathExtension.lowercaseString isEqualToString:@"app"])
        {
            NSURL *appBundleURL = [payloadDirectory URLByAppendingPathComponent:filename];
            NSURL *outputURL = [directoryURL URLByAppendingPathComponent:filename];
            
            if (![[NSFileManager defaultManager] moveItemAtURL:appBundleURL toURL:outputURL error:error])
            {
                return nil;
            }
            
            NSError *deleteError = nil;
            if (![[NSFileManager defaultManager] removeItemAtURL:payloadDirectory error:&deleteError])
            {
                *error = deleteError;
                
                return nil;
            }
            
            return outputURL;
        }
    }
    
    *error = [NSError errorWithDomain:AltSignErrorDomain code:ALTErrorMissingAppBundle userInfo:@{NSURLErrorKey: ipaURL}];
    return nil;
}

- (NSURL *)zipAppBundleAtURL:(NSURL *)appBundleURL error:(NSError **)error
{
    NSString *appBundleFilename = [appBundleURL lastPathComponent];
    NSString *appName = [appBundleFilename stringByDeletingPathExtension];
    
    NSString *ipaName = [NSString stringWithFormat:@"%@.ipa", appName];
    NSURL *ipaURL = [[appBundleURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:ipaName];
    
    if ([self fileExistsAtPath:ipaURL.path])
    {
        if (![self removeItemAtURL:ipaURL error:error])
        {
            return nil;
        }
    }
    
    zipFile zipFile = zipOpen(ipaURL.fileSystemRepresentation, APPEND_STATUS_CREATE);
    if (zipFile == nil)
    {
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:@{NSURLErrorKey: ipaURL}];
        return nil;
    }
    
    NSURL *payloadDirectory = [NSURL fileURLWithPath:@"Payload" isDirectory:YES];
    NSURL *appBundleDirectory = [payloadDirectory URLByAppendingPathComponent:appBundleFilename isDirectory:YES];
    
    NSDirectoryEnumerator *countEnumerator = [self enumeratorAtURL:appBundleURL
                                        includingPropertiesForKeys:@[]
                                                           options:0
                                                      errorHandler:^BOOL(NSURL * _Nonnull url, NSError * _Nonnull error) {
                                                          if (error) {
                                                              NSLog(@"[Error] %@ (%@)", error, url);
                                                              return NO;
                                                          }
                                                          
                                                          return YES;
                                                      }];
    
    NSInteger totalCount = 0;
    for (NSURL *__unused fileURL in countEnumerator)
    {
        totalCount++;
    }
    
    NSProgress *progress = [NSProgress progressWithTotalUnitCount:totalCount + 2]; // We add two extra entries at the end.
 
    NSDirectoryEnumerator *enumerator = [self enumeratorAtURL:appBundleURL
                                   includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                      options:0
                                                 errorHandler:^BOOL(NSURL * _Nonnull url, NSError * _Nonnull error) {
        if (error) {
            NSLog(@"[Error] %@ (%@)", error, url);
            return NO;
        }
        
        return YES;
    }];
    
    BOOL success = YES;
    
    for (NSURL *fileURL in enumerator)
    {
        NSNumber *isDirectory = nil;
        if (![fileURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:error])
        {
            success = NO;
            break;
        }
        
        if (![self writeItemAtURL:fileURL toZipFile:&zipFile depth:enumerator.level relativeURL:appBundleDirectory isDirectory:[isDirectory boolValue] error:error])
        {
            success = NO;
            break;
        }
        
        progress.completedUnitCount += 1;
    }
    
    if (success)
    {
        if (![self writeItemAtURL:payloadDirectory toZipFile:&zipFile depth:1 relativeURL:nil isDirectory:YES error:error])
        {
            success = NO;
        }
        
        progress.completedUnitCount += 1;

        if (![self writeItemAtURL:appBundleDirectory toZipFile:&zipFile depth:2 relativeURL:nil isDirectory:YES error:error])
        {
            success = NO;
        }
        
        progress.completedUnitCount += 1;
    }
    
    zipClose(zipFile, NULL);
    
    return success ? ipaURL : nil;
}

- (BOOL)writeItemAtURL:(NSURL *)fileURL toZipFile:(zipFile *)zipFile depth:(NSInteger)depth relativeURL:(nullable NSURL *)relativeURL isDirectory:(BOOL)isDirectory error:(NSError **)error
{
    NSArray<NSString *> *components = fileURL.pathComponents;
    NSArray<NSString *> *relativeComponents = [components subarrayWithRange:NSMakeRange(components.count - depth, depth)];
    
    NSString *relativePath = [relativeComponents componentsJoinedByString:@"/"];
    NSString *filename = nil;
    
    if (relativeURL != nil)
    {
        NSURL *relatedURL = [relativeURL URLByAppendingPathComponent:relativePath];
        filename = relatedURL.relativePath;
    }
    else
    {
        filename = relativePath;
    }
    
    NSData *data = nil;
    zip_fileinfo fileInfo = {};
    
    if (isDirectory)
    {
        if ([filename hasPrefix:@"/"])
        {
            filename = [filename stringByReplacingCharactersInRange:NSMakeRange(0, 1) withString:@""];
        }
        
        if (![filename hasSuffix:@"/"])
        {
            filename = [filename stringByAppendingString:@"/"];
        }
    }
    else
    {
        NSDictionary *attributes = [self attributesOfItemAtPath:fileURL.path error:error];
        if (attributes == nil)
        {
            return NO;
        }
        
        NSNumber *permissionsValue = attributes[NSFilePosixPermissions];
        if (permissionsValue == nil)
        {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:@{NSURLErrorKey: fileURL}];
            return NO;
        }
        
        short permissions = permissionsValue.shortValue;
        NSInteger shiftedPermissions = 0100000 + permissions;
        uLong permissionsLong = @(shiftedPermissions).unsignedLongValue;
        
        fileInfo.external_fa = (unsigned int)(permissionsLong << 16L);
        
        data = [NSData dataWithContentsOfURL:fileURL options:0 error:error];
        if (data == nil)
        {
            return NO;
        }
    }
    
    NSData *filenameData = [filename dataUsingEncoding:NSUTF8StringEncoding];
    if (filenameData == nil)
    {
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteInapplicableStringEncodingError userInfo:@{NSFilePathErrorKey: filename}];
        return NO;
    }

    NSMutableData *nullTerminatedFilenameData = [filenameData mutableCopy];
    uint8_t nullTerminator = 0;
    [nullTerminatedFilenameData appendBytes:&nullTerminator length:1];

    if (zipOpenNewFileInZip4(*zipFile,
                             nullTerminatedFilenameData.bytes,
                             &fileInfo,
                             NULL,
                             0,
                             NULL,
                             0,
                             NULL,
                             Z_DEFLATED,
                             Z_DEFAULT_COMPRESSION,
                             0,
                             -MAX_WBITS,
                             8,
                             Z_DEFAULT_STRATEGY,
                             NULL,
                             0,
                             0,
                             ALTZipUTF8FilenameFlag) != ZIP_OK)
    {
        zipCloseFileInZip(*zipFile);
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:@{NSFilePathErrorKey: filename}];
        return NO;
    }
    
    if (zipWriteInFileInZip(*zipFile, data.bytes, (unsigned int)data.length) != ZIP_OK)
    {
        zipCloseFileInZip(*zipFile);
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:@{NSFilePathErrorKey: filename}];
        return NO;
    }
    
    return YES;
}

@end
