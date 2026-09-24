#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <unistd.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import "NSPrivate.h"
#import "NSDaemon.h"
#import "NSInputInjector.h"
#import "NSScreenCapture.h"

// Receiver daemon. Runs in SpringBoard, talks to:
// - the app over TCP 127.0.0.1:17999 (pair/stop/status, JSON per line)
// - the server over websocket as role=phone

static const uint16_t kDaemonPort = 17999;

@implementation NSDaemon {
    BOOL _started;
    NSString *_serverBase;
    NSString *_code;
    BOOL _sharing;
    NSURLSessionWebSocketTask *_ws;
    NSURLSession *_session;
}

+ (instancetype)sharedInstance {
    static NSDaemon *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _serverBase = [[NSUserDefaults standardUserDefaults]
            stringForKey:@"NicheShareServer"] ?: @"https://nicheshare.example.com";
        _session = [NSURLSession sessionWithConfiguration:
            [NSURLSessionConfiguration defaultSessionConfiguration]];
    }
    return self;
}

- (void)start {
    if (_started) return;
    _started = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        [self acceptLoop];
    });
    NSLog(@"[NicheShare] daemon on 127.0.0.1:%d", kDaemonPort);
}

#pragma mark - App channel

// Blocking accept loop on a background thread.
- (void)acceptLoop {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kDaemonPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { close(fd); return; }
    if (listen(fd, 1) != 0) { close(fd); return; }
    while (_started) {
        int client = accept(fd, NULL, NULL);
        if (client < 0) continue;
        [self handleClient:client];
        close(client);
    }
    close(fd);
}

- (void)handleClient:(int)client {
    NSMutableData *buf = [NSMutableData data];
    char tmp[1024];
    ssize_t n;
    while ((n = recv(client, tmp, sizeof(tmp), 0)) > 0) {
        [buf appendBytes:tmp length:(NSUInteger)n];
        NSRange nl = [buf rangeOfData:[NSData dataWithBytes:"\n" length:1]
                              options:0 range:NSMakeRange(0, buf.length)];
        if (nl.location != NSNotFound) {
            NSData *line = [buf subdataWithRange:NSMakeRange(0, nl.location)];
            NSDictionary *reply = [self handleCommandData:line];
            NSData *out = [NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
            NSMutableData *packet = [out mutableCopy];
            [packet appendData:[NSData dataWithBytes:"\n" length:1]];
            send(client, packet.bytes, packet.length, 0);
            [buf replaceBytesInRange:NSMakeRange(0, nl.location + 1) withBytes:NULL length:0];
        }
    }
}

- (NSDictionary *)handleCommandData:(NSData *)data {
    NSDictionary *cmd = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![cmd isKindOfClass:[NSDictionary class]]) return @{@"ok": @NO, @"error": @"bad json"};
    NSString *action = cmd[@"cmd"];
    if ([action isEqualToString:@"pair"]) {
        NSString *server = cmd[@"server"];
        if ([server isKindOfClass:[NSString class]] && server.length > 0) {
            _serverBase = server;
        }
        NSString *code = [self pairSync];
        if (code) return @{@"ok": @YES, @"code": code};
        return @{@"ok": @NO, @"error": @"pairing failed (server?)"};
    }
    if ([action isEqualToString:@"stop"]) {
        [self stopSharing];
        return @{@"ok": @YES};
    }
    if ([action isEqualToString:@"status"]) {
        return @{@"ok": @YES, @"sharing": @(_sharing), @"code": _code ?: @""};
    }
    return @{@"ok": @NO, @"error": @"unknown cmd"};
}

#pragma mark - Signaling

// Pairing runs on the TCP thread, never main.
- (NSString *)pairSync {
    [self stopSharing];
    NSURL *url = [NSURL URLWithString:[_serverBase stringByAppendingString:@"/api/room"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    __block NSString *code = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[_session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        if (data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json[@"code"] isKindOfClass:[NSString class]]) code = json[@"code"];
        }
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    if (!code) return nil;
    _code = code;
    [self connectWS];
    _sharing = YES;
    [[NSScreenCapture sharedInstance] startWithHandler:^(IOSurfaceRef surface, CGSize size) {
        (void)surface; (void)size;
    }];
    return code;
}

- (void)stopSharing {
    _sharing = NO;
    _code = nil;
    [_ws cancel];
    _ws = nil;
    [[NSScreenCapture sharedInstance] stop];
}

- (void)connectWS {
    NSString *wsBase = _serverBase;
    if ([wsBase hasPrefix:@"https://"]) wsBase = [@"wss://" stringByAppendingString:[wsBase substringFromIndex:8]];
    else if ([wsBase hasPrefix:@"http://"]) wsBase = [@"ws://" stringByAppendingString:[wsBase substringFromIndex:7]];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/ws?code=%@&role=phone", wsBase, _code]];
    _ws = [_session webSocketTaskWithURL:url];
    [self listenWS];
    [_ws resume];
}

- (void)listenWS {
    __weak typeof(self) weakSelf = self;
    [_ws receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || error) return;
        if (message.type == NSURLSessionWebSocketMessageTypeString) {
            [strongSelf handleSignal:message.string];
        }
        [strongSelf listenWS];
    }];
}

- (void)handleSignal:(NSString *)raw {
    NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![msg isKindOfClass:[NSDictionary class]]) return;
    if (![msg[@"t"] isEqualToString:@"input"]) return;
    NSString *kind = msg[@"kind"];
    BOOL ok = NO;
    if ([kind isEqualToString:@"tap"]) {
        double x = [msg[@"x"] doubleValue], y = [msg[@"y"] doubleValue];
        ok = [[NSInputInjector sharedInstance] injectTapAtX:x y:y];
    } else if ([kind isEqualToString:@"key"]) {
        NSString *key = msg[@"key"];
        if ([key isKindOfClass:[NSString class]]) {
            ok = [[NSInputInjector sharedInstance] injectKey:key];
        }
    }
    NSLog(@"[NicheShare] input %@ -> %@", kind, ok ? @"ok" : @"FAILED");
}

@end
