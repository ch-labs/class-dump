// -*- mode: ObjC -*-

//  This file is part of class-dump, a utility for examining the Objective-C segment of Mach-O files.
//  Copyright (C) 1997-1998, 2000-2001, 2004-2011 Steve Nygard.

#import "CDLCLinkerOption.h"

#import "CDMachOFile.h"

@implementation CDLCLinkerOption
{
    struct linker_option_command _linkerOptionCommand;
    NSArray *_linkerOption;
}

- (id)initWithDataCursor:(CDMachOFileDataCursor *)cursor;
{
    if ((self = [super initWithDataCursor:cursor])) {
        NSUInteger loadCommandOffset = cursor.offset;
        _linkerOptionCommand.cmd     = [cursor readInt32];
        _linkerOptionCommand.cmdsize = [cursor readInt32];
        _linkerOptionCommand.count   = [cursor readInt32];
        
        NSMutableArray *linkerOption = [[NSMutableArray alloc] init];
        uint32_t count = _linkerOptionCommand.count;
        while (count--) {
            NSUInteger length = strlen((const char *)[cursor.data bytes] + cursor.offset);
            NSString *option = [cursor readStringOfLength:length encoding:NSUTF8StringEncoding];
            [cursor readByte]; // NULL terminator
            [linkerOption addObject:option];
        }
        _linkerOption = [linkerOption copy];
        
        NSUInteger alignment = cursor.machOFile.ptrSize;
        while ((cursor.offset - loadCommandOffset) % alignment != 0) {
            [cursor readByte];
        }
    }
    
    return self;
}

#pragma mark -

- (uint32_t)cmd;
{
    return _linkerOptionCommand.cmd;
}

- (uint32_t)cmdsize;
{
    return _linkerOptionCommand.cmdsize;
}

- (NSString *)extraDescription;
{
    return [self.linkerOption componentsJoinedByString:@" "];
}

@end
