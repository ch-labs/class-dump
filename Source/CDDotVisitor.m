// -*- mode: ObjC -*-

//  This file is part of class-dump, a utility for examining the Objective-C segment of Mach-O files.
//  Copyright (C) 1997-1998, 2000-2001, 2004-2012 Steve Nygard.

#import "CDDotVisitor.h"

#import "CDOCClass.h"
#import "CDOCIvar.h"
#import "CDType.h"
#import "CDTypeName.h"

@implementation CDDotVisitor

- (id)init;
{
    if ((self = [super init])) {
        allClasses = [[NSMutableSet alloc] init];
        referencedClassNames = [[NSMutableSet alloc] init];
        allProtocols = [[NSMutableSet alloc] init];
    }
    
    return self;
}

- (void)dealloc;
{
    [allClasses release];
    [referencedClassNames release];
    [allProtocols release];
    
    [super dealloc];
}

- (void)willVisitClass:(CDOCClass *)aClass;
{
    [allClasses addObject:aClass];
}

- (void)willVisitProtocol:(CDOCProtocol *)aProtocol;
{
    [allProtocols addObject:aProtocol];
}

- (void)didEndVisiting;
{
    NSSet *classNames = [allClasses valueForKeyPath:@"name"];
    NSSet *protocolNames = [allProtocols valueForKeyPath:@"name"];
    
    NSMutableString *digraph = [[[NSMutableString alloc] init] autorelease];
    [digraph appendString:@"digraph Dependencies {\n"
                          @"graph [ rankdir = \"LR\" ];\n"
                          @"node [ shape = record ]\n"];
    
    for (CDOCClass *class in allClasses) {
        for (CDOCIvar *ivar in class.ivars) {
            if ([classNames containsObject:ivar.parsedType.typeName.name]) {
                [referencedClassNames addObject:class.name];
                [digraph appendFormat:@"\"%@\":%u -> \"%@\"\n", class.name, ivar.offset, ivar.parsedType.typeName.name];
            }
        }
    }
    
    for (CDOCClass *class in allClasses) {
        if (![referencedClassNames containsObject:class.name])
            continue;
        
        [digraph appendFormat:@"%@ [ label = \"%@", class.name, class.name];
        for (CDOCIvar *ivar in class.ivars) {
            NSString *protocolName = nil;
            NSArray *protocols = [[ivar parsedType] valueForKey:@"protocols"];
            if ([protocols count] == 1)
                protocolName = [protocols objectAtIndex:0];
            
            if ([classNames containsObject:ivar.parsedType.typeName.name] || [protocolNames containsObject:protocolName])
                [digraph appendFormat:@" | <%u> %@", ivar.offset, ivar.name];
        }
        [digraph appendString:@"\" ]\n"];
        
        BOOL isRootClass = [class.superClassName isEqualToString:@"NSObject"] || [class.superClassName isEqualToString:@"NSProxy"];
        if (!isRootClass)
            [digraph appendFormat:@"%@ -> %@ [ style = dotted ]\n", class.name, class.superClassName];
    }
    
    [digraph appendString:@"}\n"];
    
    NSData *data = [digraph dataUsingEncoding:NSUTF8StringEncoding];
    [(NSFileHandle *)[NSFileHandle fileHandleWithStandardOutput] writeData:data];
}

@end
