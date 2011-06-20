// -*- mode: ObjC -*-

//  This file is part of class-dump, a utility for examining the Objective-C segment of Mach-O files.
//  Copyright (C) 2011 Cédric Luthi.

#import <Foundation/Foundation.h>
#import "NSString-Extensions.h"

#import "CDFile.h"
#import "CDMachOFile.h"
#import "CDLCSymbolTable.h"
#import "CDSymbol.h"
#import "CDObjectiveCProcessor.h"
#import "CDOCClass.h"
#import "CDOCMethod.h"

static NSString *symbolName = nil;
static NSString *underscoreSymbolName = nil;
static NSString *classNameNew = nil;
static NSString *classNameOld = nil;

BOOL searchDylib(NSString *dylibPath)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    BOOL symbolFound = NO;
    BOOL isFramework = [[dylibPath pathExtension] isEqualToString:@"framework"];
    if (isFramework)
    {
        NSBundle *dylibBundle = [NSBundle bundleWithPath:dylibPath];
        NSString *executablePath = [dylibBundle executablePath];
        if (executablePath)
            dylibPath = executablePath;
        
        NSString *frameworksPath = [dylibBundle pathForResource:@"Frameworks" ofType:nil];
        if ([[NSFileManager defaultManager] fileExistsAtPath:frameworksPath])
        {
            for (NSString *sublib in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:frameworksPath error:NULL])
            {
                NSString *sublibPath = [frameworksPath stringByAppendingPathComponent:sublib];
                symbolFound |= searchDylib(sublibPath);
            }
        }
    }
    
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:dylibPath error:NULL];
    if (!isFramework && ![[attributes objectForKey:NSFileType] isEqualToString:NSFileTypeRegular])
        return symbolFound;
    
    NSData *dylibData = [NSData dataWithContentsOfMappedFile:dylibPath];
    CDFile *file = [CDFile fileWithData:dylibData filename:dylibPath searchPathState:nil];
    if (file == nil)
        return symbolFound;
    
    CDMachOFile *machOFile = [file machOFileWithArch:(CDArchFromName(@"x86_64"))];
    [[machOFile symbolTable] loadSymbols];
    
    NSArray *symbols = [[machOFile symbolTable] symbols];
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"(name == %@ OR name == %@ OR name == %@ OR name == %@) AND isInSection == TRUE", symbolName, underscoreSymbolName, classNameNew, classNameOld];
    CDSymbol *symbol = [[symbols filteredArrayUsingPredicate:predicate] lastObject];
    if (symbol)
    {
        printf("%s: %s\n", [[symbol name] UTF8String], [dylibPath UTF8String]);
        symbolFound = YES;
    }
    
    [pool drain];
    return symbolFound;
}

int main(int argc, char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    if (argc != 2)
        return EXIT_FAILURE;
    
    BOOL symbolFound = NO;
    NSString *sdkRoot = @"/Developer/SDKs/MacOSX10.6.sdk";
    symbolName = [NSString stringWithUTF8String:argv[1]];
    underscoreSymbolName = [@"_" stringByAppendingString:symbolName];
    classNameNew = [ObjCClassSymbolPrefix stringByAppendingString:symbolName];
    classNameOld = [@".objc_class_name_" stringByAppendingString:symbolName];
    if (![symbolName hasPrefix:@"_"])
        symbolName = underscoreSymbolName;
    
    NSArray *paths = [NSArray arrayWithObjects:@"/System/Library/Frameworks", @"/System/Library/PrivateFrameworks", @"/usr/lib", nil];
    for (NSString *path in paths)
    {
        NSString *dylibRoot = [sdkRoot stringByAppendingPathComponent:path];
        for (NSString *dylib in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dylibRoot error:NULL])
        {
            NSString *dylibPath = [dylibRoot stringByAppendingPathComponent:dylib];
            symbolFound |= searchDylib(dylibPath);
        }
    }
    
    [pool drain];
    
    return symbolFound ? 0 : 2;
}
