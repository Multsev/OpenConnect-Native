#import <Foundation/Foundation.h>

extern int NSExtensionMain(int argc, const char *argv[]);

// A system extension has an executable entry point; NetworkExtension loads the
// provider class declared in Info.plist after this handoff.
int main(int argc, const char *argv[]) {
    return NSExtensionMain(argc, argv);
}
