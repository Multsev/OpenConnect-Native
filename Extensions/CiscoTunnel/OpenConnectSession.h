#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>

@class NEPacketTunnelFlow;
@class TunnelConfiguration;

NS_ASSUME_NONNULL_BEGIN

@interface OpenConnectSession: NSObject
- (instancetype)initWithConfiguration:(TunnelConfiguration *)configuration;
- (void)startWithPacketFlow:(NEPacketTunnelFlow *)packetFlow
            configureNetwork:(void (^)(NEPacketTunnelNetworkSettings *settings, void (^)(NSError *_Nullable error)))configureNetwork
                      failed:(void (^)(NSError *error))failed
    NS_SWIFT_NAME(start(packetFlow:configureNetwork:failed:));
- (void)stop;
@end

NS_ASSUME_NONNULL_END
