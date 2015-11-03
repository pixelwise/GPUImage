#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import "GPUImageContext.h"

extern NSString *const kGPUImageColorSwizzlingFragmentShaderString;


@interface GPUImageEncoder : NSObject <GPUImageInput>
{
    BOOL alreadyFinishedRecording;
    
    GPUImageContext *_movieWriterContext;
    CVPixelBufferRef renderTarget;
    CVOpenGLESTextureRef renderTexture;
    
    CGSize videoSize;
    GPUImageRotationMode inputRotation;
}

@property(nonatomic, copy) void(^completionBlock)(void);
@property(nonatomic, copy) void(^failureBlock)(NSError*);
@property(nonatomic, copy) void(^frameWrittenCompletionBlock)(BOOL, CMTime);
@property(nonatomic, copy) BOOL(^videoInputReadyCallback)(void);
@property(nonatomic) BOOL enabled;
@property(nonatomic, readonly) CMTime duration;
@property(nonatomic, assign) CGAffineTransform transform;
@property(nonatomic, copy) NSArray *metaData;
@property(nonatomic, assign, getter = isPaused) BOOL paused;
@property(nonatomic, retain) GPUImageContext *movieWriterContext;

// Initialization and teardown
- (id)initWithSize:(CGSize)newSize;

// Movie recording
- (void)startRecording;
- (void)startRecordingInOrientation:(CGAffineTransform)orientationTransform;
- (void)finishRecording;
- (void)finishRecordingWithCompletionHandler:(void (^)(void))handler;
- (void)cancelRecording;

@end
