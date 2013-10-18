// -*- mode: ObjC -*-

//  This file is part of class-dump, a utility for examining the Objective-C segment of Mach-O files.
//  Copyright (C) 1997-1998, 2000-2001, 2004-2012 Steve Nygard.

#import "CDArchive.h"

#import <ar.h>

#import "CDMachOFile.h"
#import "CDDataCursor.h"
#import "CDLCSegment.h"
#import "CDSection.h"

@implementation CDArchive

static NSString *DeveloperDirectoryPath(NSError *__autoreleasing * error)
{
    NSString *developerDirectoryPath = nil;
    
    @try {
        NSTask *xcode_select = [[NSTask alloc] init];
        xcode_select.launchPath = @"/usr/bin/xcode-select";
        xcode_select.arguments = @[ @"-print-path" ];
        xcode_select.standardOutput = [NSPipe pipe];
        [xcode_select launch];
        [xcode_select waitUntilExit];
        NSData *developerDirData = [[xcode_select.standardOutput fileHandleForReading] readDataToEndOfFile];
        developerDirectoryPath = [[NSString alloc] initWithData:developerDirData encoding:NSUTF8StringEncoding];
        developerDirectoryPath = [developerDirectoryPath stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    @catch (NSException * __unused exception) {
        developerDirectoryPath = nil;
        if (error) {
            *error = [NSError errorWithDomain:nil code:0 userInfo:nil]; // TODO: real error
        }
    }
    
    return developerDirectoryPath;
}

static NSString *ArchiveFileName(struct ar_hdr *header)
{
    NSData *data = [NSData dataWithBytes:header->ar_name length:sizeof(header->ar_name)];
    return [[[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

static NSUInteger ArchiveFileSize(struct ar_hdr *header)
{
    NSData *data = [NSData dataWithBytes:header->ar_size length:sizeof(header->ar_size)];
    return [[[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding] integerValue];
}

+ (CDMachOFile *)machOFileWithArchiveData:(NSData *)archiveData filename:(NSString *)filename error:(NSError *__autoreleasing *)error;
{
    CDDataCursor *cursor = [[CDDataCursor alloc] initWithData:archiveData];
    NSString *magic = [cursor readStringOfLength:SARMAG encoding:NSASCIIStringEncoding];
    if (![magic isEqualToString:@(ARMAG)])
        return nil;
    
    NSString *arch = nil;
    NSString *platform = @"MacOSX";
    
    struct ar_hdr *header = NULL;
    while (cursor.remaining > sizeof(*header)) {
        header = (struct ar_hdr *)((NSUInteger)cursor.bytes + cursor.offset);
        if (![[@(ARFMAG) dataUsingEncoding:NSASCIIStringEncoding] isEqualToData:[NSData dataWithBytes:header->ar_fmag length:sizeof(header->ar_fmag)]]) {
            return nil;
        }
        NSString *extendedFormat1Header = @(AR_EFMT1);
        cursor.offset += sizeof(*header);
        NSString *fileName = ArchiveFileName(header);
        NSUInteger nameSize = 0;
        if ([fileName hasPrefix:extendedFormat1Header]) {
            nameSize = [[fileName substringFromIndex:extendedFormat1Header.length] integerValue];
            fileName = [cursor readStringOfLength:nameSize encoding:NSASCIIStringEncoding];
        }
        
        NSUInteger size = ArchiveFileSize(header) - nameSize;
        NSData *machOData = [NSData dataWithBytesNoCopy:(void *)((NSUInteger)cursor.bytes + cursor.offset) length:size freeWhenDone:NO];
        CDMachOFile *machOFile = [[CDMachOFile alloc] initWithData:machOData filename:[filename stringByAppendingFormat:@"(%@)", fileName] searchPathState:nil];
        if (machOFile) {
            [machOFile hasObjectiveC2Data];
            arch = CDNameForCPUType(machOFile.cputype, machOFile.cpusubtype);
            if (machOFile.maskedCPUType == CPU_TYPE_ARM) {
                // This arm => iPhoneOS assumption may break in the future
                platform = @"iPhoneOS";
            }
            
            CDSection *objcImageInfoSection = nil;
            for (CDLCSegment *segment in machOFile.loadCommands) {
                if ([segment isKindOfClass:[CDLCSegment class]]) {
                    for (CDSection *section in segment.sections) {
                        if ([section.segmentName isEqualToString:@"__DATA" ] && [section.sectionName isEqualToString:@"__objc_imageinfo"]) {
                            objcImageInfoSection = section;
                            break;
                        }
                    }
                }
                if (objcImageInfoSection) {
                    break;
                }
            }
            
            if ([arch isEqualToString:@"i386"] && objcImageInfoSection)
                platform = @"iPhoneSimulator";
            
            CDMachOFileDataCursor *imageInfoCursor = [[CDMachOFileDataCursor alloc] initWithSection:objcImageInfoSection];
            if (imageInfoCursor.remaining >= 8) {
                [imageInfoCursor readInt32]; // version
                uint32_t flags = [imageInfoCursor readInt32];
                if (flags & (1<<5)) { // gparker: @0xced Sufficiently new tools set a bit in __DATA,__objc_imageinfo for simulator-built binaries. [http://twitter.com/gparker/status/390612463101546496]
                    platform = @"iPhoneSimulator";
                }
            }
            
            break;
        }
        cursor.offset += size;
    }
    
    if (!arch)
        return nil;
    
    NSString *developerDirectoryPath = DeveloperDirectoryPath(error);
    if (!developerDirectoryPath)
        return nil;
    
    NSString *sdksDir = [NSString stringWithFormat:@"%@/Platforms/%@.platform/Developer/SDKs/", developerDirectoryPath, platform];
    NSArray *sdkURLs = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:[NSURL fileURLWithPath:sdksDir] includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL];
    NSURL *sdkURL = [[sdkURLs sortedArrayUsingComparator:^NSComparisonResult(NSURL *url1, NSURL *url2) {
        return [url1.lastPathComponent compare:url2.lastPathComponent];
    }] lastObject];
    NSString *sdkName = [sdkURL.lastPathComponent stringByDeletingPathExtension];
    if (![sdkName hasPrefix:platform])
        return nil;
    
    NSString *sdkVersion = [sdkName substringFromIndex:platform.length];
    NSTask *clang = [[NSTask alloc] init];
    clang.launchPath = @"/usr/bin/xcrun";
    NSMutableArray *arguments = [@[ @"clang",
                                    @"-arch", arch,
                                    @"-x", @"c",
                                    @"-o", @"/dev/stdout",
                                    @"-ObjC",
                                    @"-flat_namespace",
                                    @"-undefined", @"suppress",
                                    @"-isysroot", sdkURL.path,
                                  ] mutableCopy];
    
    if ([platform isEqualToString:@"MacOSX"]) {
        [arguments addObject:[@"-mmacosx-version-min=" stringByAppendingString:sdkVersion]];
    } else if ([platform isEqualToString:@"iPhoneOS"]) {
        [arguments addObject:[@"-miphoneos-version-min=" stringByAppendingString:sdkVersion]];
    } else if ([platform isEqualToString:@"iPhoneSimulator"]) {
        [arguments addObject:[@"-mios-simulator-version-min=" stringByAppendingString:sdkVersion]];
    }
    
    NSString *searchPath = [@"-L" stringByAppendingString:[filename stringByDeletingLastPathComponent]];
    NSString *libName = [[filename lastPathComponent] stringByDeletingPathExtension];
    if ([libName hasPrefix:@"lib"])
        libName = [libName substringFromIndex:3];
    NSArray *linkOption = @[ @"-l", libName ];
    
    NSRange frameworkExtensionRange = [filename rangeOfString:@".framework"];
    if (frameworkExtensionRange.location != NSNotFound) {
        searchPath = [@"-F" stringByAppendingString:[[filename substringToIndex:frameworkExtensionRange.location] stringByDeletingLastPathComponent]];
        linkOption = @[ @"-framework", [filename lastPathComponent] ];
    }
    
    [arguments addObject:searchPath];
    [arguments addObjectsFromArray:linkOption];
    [arguments addObject:@"-"];
    clang.arguments = arguments;
    clang.standardInput = [NSPipe pipe];
    clang.standardOutput = [NSPipe pipe];
    clang.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSData *machOData = nil;
    @try {
        [clang launch];
        NSFileHandle *inputFileHandle = [clang.standardInput fileHandleForWriting];
        [inputFileHandle writeData:[@"int main;" dataUsingEncoding:NSASCIIStringEncoding]];
        [inputFileHandle closeFile];
        machOData = [[clang.standardOutput fileHandleForReading] readDataToEndOfFile];
    }
    @catch (NSException * __unused exception) {
        machOData = nil;
    }
    return [[CDMachOFile alloc] initWithData:machOData filename:filename searchPathState:nil];
}

@end
