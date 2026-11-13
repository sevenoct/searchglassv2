#import <UIKit/UIKit.h>
#import <spawn.h>

extern char **environ;

@interface PSListController : UIViewController {
    NSArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)reloadSpecifiers;
@end

@interface GSRootListController : PSListController
@end

@implementation GSRootListController
- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}
- (void)resetDefaults {
    CFStringRef dom = CFSTR("com.hasan.glasssearch");
    CFArrayRef keys = CFPreferencesCopyKeyList(dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keys) {
        CFPreferencesSetMultiple(NULL, keys, dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFRelease(keys);
    }
    CFPreferencesAppSynchronize(dom);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.hasan.glasssearch/prefs"), NULL, NULL, YES);
    [self reloadSpecifiers];
}
- (void)respring {
    NSArray *tries = @[@"/var/jb/usr/bin/sbreload", @"/usr/bin/sbreload"];
    for (NSString *p in tries) {
        if (![NSFileManager.defaultManager fileExistsAtPath:p]) continue;
        pid_t pid;
        char *args[] = {(char *)"sbreload", NULL};
        posix_spawn(&pid, p.fileSystemRepresentation, NULL, NULL, args, environ);
        return;
    }
    pid_t pid;
    char *args[] = {(char *)"killall", (char *)"-9", (char *)"SpringBoard", NULL};
    posix_spawnp(&pid, "killall", NULL, NULL, args, environ);
}
@end
