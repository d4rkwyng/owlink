#import <UIKit/UIKit.h>

/// Returns 1 and writes the override if one is set (including an explicit
/// `UIUserInterfaceStyleUnspecified`). Returns 0 if UIKit has no override
/// for that trait — reading it would throw.
int OWReadUserInterfaceStyleOverride(UIWindow *window, NSInteger *outStyle) {
    @try {
        if (outStyle) *outStyle = (NSInteger)window.traitOverrides.userInterfaceStyle;
        return 1;
    } @catch (NSException *exception) {
        return 0;
    }
}
