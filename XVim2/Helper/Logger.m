//
//  Logger.m
//  NiChannelBrowser
//
//  Created by Shuichiro Suzuki on 12/25/11.
//  Copyright 2011 JugglerShu.Net. All rights reserved.
//

#import "Logger.h"
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>


#define LOGGER_DEFAULT_NAME @"LoggerDefaultName"

static Logger* s_defaultLogger = nil;


@interface Logger () {
    NSFileHandle* _logFile;
}
@end


@implementation Logger
@synthesize level, name;

+ (Logger*)defaultLogger
{
    if (s_defaultLogger == nil) {
#ifdef DEBUG
        s_defaultLogger = [[Logger alloc] initWithName:LOGGER_DEFAULT_NAME];
#else
        s_defaultLogger = [[Logger alloc] initWithName:LOGGER_DEFAULT_NAME level:LogError];
#endif
    }
    return s_defaultLogger;
}

- (void)forwardInvocationForLogger:(NSInvocation*)invocation
{
    NSString* selector = NSStringFromSelector([invocation selector]);
    NSString* forward =
                [[NSString alloc] initWithFormat:@"LOGGER_HIDDEN_%@", NSStringFromSelector([invocation selector])];
    if ([[invocation target] respondsToSelector:NSSelectorFromString(forward)]) {
        [Logger logWithLevel:LogTrace format:@"ENTER METHOD - %@ %@", NSStringFromClass([self class]), selector];
        [invocation setSelector:NSSelectorFromString(forward)];
        [invocation invoke];
        [Logger logWithLevel:LogTrace format:@"LEAVE METHOD - %@ %@", NSStringFromClass([self class]), selector];
    }
    else {
        [super forwardInvocation:invocation];
    }
}

- (NSMethodSignature*)methodSignatureForSelector:(SEL)selector { return [super methodSignatureForSelector:selector]; }

+ (void)registerTracing:(NSString*)name
{
    Class c = NSClassFromString(name);
    if (nil == c) {
        DEBUG_LOG(@"Can't find class : %@", name);
        return;
    }
    unsigned int num;
    Method* m = class_copyMethodList(c, &num);
    xvim_ignore_warning_undeclared_selector_push
    IMP no_imp = class_getMethodImplementation([Logger class],
                                               @selector(there_is_not_such_method)); // Find imple for not implemented
    xvim_ignore_warning_pop
    for (unsigned int i = 0; i < num; i++) {
        SEL selector = method_getName(m[i]);
        NSString* new_selector = [[NSString alloc] initWithFormat:@"LOGGER_HIDDEN_%@", NSStringFromSelector(selector)];
        class_addMethod(c, NSSelectorFromString(new_selector), method_getImplementation(m[i]),
                        method_getTypeEncoding(m[i]));
        method_setImplementation(m[i], no_imp);
    }

    // Set forwardInvocation:
    Method myinv = class_getClassMethod([Logger class], @selector(forwardInvocationForLogger:));
    class_addMethod(c, @selector(forwardInvocation:),
                    class_getMethodImplementation([Logger class], @selector(forwardInvocationForLogger:)),
                    method_getTypeEncoding(myinv));
}


- (id)init { return [self initWithName:LOGGER_DEFAULT_NAME]; }

- (id)initWithName:(NSString*)n { return [self initWithName:n level:LogDebug]; }

- (id)initWithName:(NSString*)n level:(LogLevel)l
{
    if (self = [super init]) {
        self.name = n;
        self.level = l;
    }
    return self;
}

- (void)write:(NSString*)fmt args:(va_list)args
{
    va_list args2;
    va_copy(args2, args);

    // Write to stderr
    NSString* s = [[NSString alloc] initWithFormat:fmt arguments:args];
    printf("%s\n", [[s stringByReplacingOccurrencesOfString:@"%%" withString:@"%%%%"] UTF8String]);

    // Write to file
    if (nil != _logFile) {
        NSString* msg = [[NSString alloc] initWithFormat:fmt arguments:args2];
        [_logFile writeData:[msg dataUsingEncoding:NSUTF8StringEncoding]];
        [_logFile writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    }

    va_end(args2);
}

- (void)logWithLevel:(LogLevel)l format:(NSString*)format args:(va_list)args
{
    if (l < self.level) {
        return;
    }
    static NSDateFormatter* s_formatter = nil;
    if (s_formatter == nil) {
        s_formatter = [[NSDateFormatter alloc] init];
        [s_formatter setDateFormat:@"HH:mm:ss:SSS"];
    }
    NSString* sNow = [s_formatter stringFromDate:[NSDate date]];
    NSString* fmt = [NSString stringWithFormat:@"[%@]%@", sNow, format];
    [self write:fmt args:args];
}

- (void)logWithLevel:(LogLevel)l format:(NSString*)fmt, ...
{
    va_list argumentList;
    va_start(argumentList, fmt);
    [self logWithLevel:l format:fmt args:argumentList];
    va_end(argumentList);
}

- (void)logWithString:(NSString*)s
{
    [self logWithLevel:LogDebug format:s];
}

+ (void)logWithLevel:(LogLevel)l format:(NSString*)fmt, ...
{
    va_list argumentList;
    va_start(argumentList, fmt);
    [[Logger defaultLogger] logWithLevel:l format:fmt args:argumentList];
    va_end(argumentList);
}

- (void)setLogFile:(NSString*)path
{
    [_logFile closeFile];
    _logFile = nil;

    if (nil != path) {
        NSFileManager* fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) {
            [fm createFileAtPath:path contents:nil attributes:nil];
        }
        
        int fd = -1;
        int filenum = 1;
        int attempts = 0;
        NSString *fullpath = path;
        
        // If the logfile is being held open by another XVim, try adding a
        // discriminator to the file name, and try again.
        while (attempts++ < 20 && fd < 0) {
            fd = open( fullpath.UTF8String, O_RDWR + O_EXLOCK + O_NONBLOCK + O_CREAT );
            if (fd < 0 && (errno == EWOULDBLOCK || errno == EDEADLK)) {
                filenum++;
                fullpath = [path stringByAppendingString:[@(filenum) stringValue]];
            }
        }
        
        _logFile = (fd>=0)
                ? [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES]
                : [NSFileHandle fileHandleForWritingAtPath:path];
        
        [_logFile seekToEndOfFile];
    }
}

+ (void)logStackTrace:(NSException*)ex
{
    for (NSString* e in [ex callStackSymbols]) {
        (void)(e);
        TRACE_LOG(@"%@", e);
    }
}

+ (void)traceMethodList:(NSString*)class {
    Class c = NSClassFromString(class);
    if (nil == c) {
        DEBUG_LOG(@"Can't find class : %@", class);
        return;
    }
    unsigned int num;
    Method* m = class_copyMethodList(c, &num);
    TRACE_LOG(@"METHOD LIST : %@", class);
    for (unsigned int i = 0; i < num; i++) {
        SEL selector __unused = method_getName(m[i]);
        TRACE_LOG(@"%@", NSStringFromSelector(selector));
    }
}

            + (void)logAvailableClasses : (LogLevel)l
{
    int numClasses;
    Class* classes = NULL;

    numClasses = objc_getClassList(NULL, 0);
    NSMutableString* text = [[NSMutableString alloc] init];
    if (numClasses > 0) {
        classes = (Class*)malloc(sizeof(Class) * (NSUInteger)numClasses);
        numClasses = objc_getClassList(classes, numClasses);
        // Enumerate Classes
        for (int i = 0; i < numClasses; i++) {
            NSString* className = [NSString stringWithCString:class_getName(classes[i]) encoding:NSASCIIStringEncoding];
            [text appendFormat:@"<h2>%@</h2>\n", className];
            [Logger logWithLevel:l format:className];
            [text appendString:@"<ul>\n"];
            Class superClass = class_getSuperclass(classes[i]);
            while (nil != superClass) {
                [text appendFormat:@"<- %@ ", [NSString stringWithCString:class_getName(superClass)
                                                                   encoding:NSASCIIStringEncoding]];
                superClass = class_getSuperclass(superClass);
            }
            [text appendString:@"\n"];
            unsigned int num;
            Method* m = class_copyMethodList(classes[i], &num);
            for (NSUInteger j = 0; j < num; j++) {
                NSString* methodName = NSStringFromSelector(method_getName(m[j]));
                [text appendFormat:@"<li>%@</li>\n", methodName];
                //[Logger logWithLevel:l format:@"    %@",NSStringFromSelector(method_getName(m[j]))];
            }
            [text appendString:@"</ul>\n"];
            NSError* error;
            NSString* documentsDirectory = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/XVim"];
            NSString* path = [documentsDirectory stringByAppendingPathComponent:className];
            if (![text writeToFile:path atomically:NO encoding:NSUnicodeStringEncoding error:&error]) {
                // error
            }
            [text setString:@""];
        }
        free(classes);
    }
}

+ (void)traceViewInfoImpl:(NSView*)obj subView:(BOOL)sub prefix:(NSString*)pre
{
    NSString* className = NSStringFromClass([obj class]);
    NSRect f __unused = obj.frame;
    NSRect b __unused = obj.bounds;
    TRACE_LOG(@"%@ViewInfo : Class:%@ frame:%f,%f,%f,%f bounds:%f,%f,%f,%f", pre, className, f.origin.x, f.origin.y,
              f.size.width, f.size.height, b.origin.x, b.origin.y, b.size.width, b.size.height);

    if (sub) {
        for (NSView* v in [obj subviews]) {
            [Logger traceViewInfoImpl:v subView:sub prefix:className];
        }
    }
}

+ (void)traceViewInfo:(NSView*)obj subView:(BOOL)sub { [Logger traceViewInfoImpl:obj subView:sub prefix:@""]; }


+ (void)traceView:(NSView*)view depth:(NSUInteger)depth
{
    NSMutableString* str = [[NSMutableString alloc] init];
    for (NSUInteger i = 0; i < depth; i++) {
        [str appendString:@"   "];
    }
    [str appendString:@"%p:%@ (Tag:%d)"];
    NSLog(str, view, NSStringFromClass([view class]), [view tag]);
    for (NSView* v in [view subviews]) {
        [self traceView:v depth:depth + 1];
    }
}


+ (void)traceMenu:(NSMenu*)menu depth:(int)depth
{
    NSMutableString* tabs = [[NSMutableString alloc] init];
    for (int i = 0; i < depth; i++) {
        [tabs appendString:@"\t"];
    }
    for (NSMenuItem* item in [menu itemArray]) {
        if (![item isSeparatorItem]) {
            TRACE_LOG(@"%@Title:%@    Action:%@", tabs, [item title], NSStringFromSelector([item action]));
        }
        [Logger traceMenu:[item submenu] depth:depth + 1];
    }
}

+ (void)traceMenu:(NSMenu*)menu
{
    TRACE_LOG(@"Tracing menu items in menu(%p)", menu);
    [Logger traceMenu:menu depth:0];
}
@end
