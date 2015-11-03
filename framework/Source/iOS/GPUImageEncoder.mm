#import "GPUImageEncoder.h"

#import "GPUImageContext.h"
#import "GLProgram.h"
#import "GPUImageFilter.h"
#import "GPUImageOutput.h"

#include <deque>
#include <stdio.h>

#define ARC4RANDOM_MAX      0x100000000

NSString *const kGPUImageColorSwizzlingFragmentShaderStringEncoder = SHADER_STRING
(
 varying highp vec2 textureCoordinate;
 
 uniform sampler2D inputImageTexture;
 
 void main()
 {
     gl_FragColor = texture2D(inputImageTexture, textureCoordinate).bgra;
 }
 );


@interface GPUImageEncoder ()
{
    GLuint movieFramebuffer, movieRenderbuffer;
    
    GLProgram *colorSwizzlingProgram;
    GLint colorSwizzlingPositionAttribute, colorSwizzlingTextureCoordinateAttribute;
    GLint colorSwizzlingInputTextureUniform;
    
    GPUImageFramebuffer *firstInputFramebuffer;
    
    CMTime startTime, previousFrameTime;
    
    dispatch_queue_t videoQueue;
    BOOL videoEncodingIsFinished;
    
    BOOL isRecording;
    
    VTCompressionSessionRef session;
    //std::mutex encodeMutex;
}

// Frame rendering
- (void)createDataFBO;
- (void)destroyDataFBO;
- (void)setFilterFBO;

- (void)renderAtInternalSizeUsingFramebuffer:(GPUImageFramebuffer *)inputFramebufferToUse;

@end

@implementation GPUImageEncoder

@synthesize completionBlock;
@synthesize failureBlock;
@synthesize videoInputReadyCallback;
@synthesize frameWrittenCompletionBlock;
@synthesize enabled;
@synthesize paused = _paused;
@synthesize movieWriterContext = _movieWriterContext;

#pragma mark -
#pragma mark Initialization and teardown

- (id)initWithSize:(CGSize)newSize;
{
    if (self = [super init]) {
        
//        self.enabled = YES;
//        alreadyFinishedRecording = NO;
//        videoEncodingIsFinished = NO;
//        
//        videoSize = newSize;
//        startTime = kCMTimeInvalid;
//        previousFrameTime = kCMTimeNegativeInfinity;
//        inputRotation = kGPUImageNoRotation;
//        
//        _movieWriterContext = [[GPUImageContext alloc] init];
//        [_movieWriterContext useSharegroup:[[[GPUImageContext sharedImageProcessingContext] context] sharegroup]];
//        
//        runSynchronouslyOnContextQueue(_movieWriterContext, ^{
//            [_movieWriterContext useAsCurrentContext];
//            
//            if ([GPUImageContext supportsFastTextureUpload])
//            {
//                colorSwizzlingProgram = [_movieWriterContext programForVertexShaderString:kGPUImageVertexShaderString fragmentShaderString:kGPUImagePassthroughFragmentShaderString];
//            }
//            else
//            {
//                colorSwizzlingProgram = [_movieWriterContext programForVertexShaderString:kGPUImageVertexShaderString fragmentShaderString:kGPUImageColorSwizzlingFragmentShaderStringEncoder];
//            }
//            
//            if (!colorSwizzlingProgram.initialized)
//            {
//                [colorSwizzlingProgram addAttribute:@"position"];
//                [colorSwizzlingProgram addAttribute:@"inputTextureCoordinate"];
//                
//                if (![colorSwizzlingProgram link])
//                {
//                    NSString *progLog = [colorSwizzlingProgram programLog];
//                    NSLog(@"Program link log: %@", progLog);
//                    NSString *fragLog = [colorSwizzlingProgram fragmentShaderLog];
//                    NSLog(@"Fragment shader compile log: %@", fragLog);
//                    NSString *vertLog = [colorSwizzlingProgram vertexShaderLog];
//                    NSLog(@"Vertex shader compile log: %@", vertLog);
//                    colorSwizzlingProgram = nil;
//                    NSAssert(NO, @"Filter shader link failed");
//                }
//            }
//            
//            colorSwizzlingPositionAttribute = [colorSwizzlingProgram attributeIndex:@"position"];
//            colorSwizzlingTextureCoordinateAttribute = [colorSwizzlingProgram attributeIndex:@"inputTextureCoordinate"];
//            colorSwizzlingInputTextureUniform = [colorSwizzlingProgram uniformIndex:@"inputImageTexture"];
//            
//            [_movieWriterContext setContextShaderProgram:colorSwizzlingProgram];
//            
//            glEnableVertexAttribArray(colorSwizzlingPositionAttribute);
//            glEnableVertexAttribArray(colorSwizzlingTextureCoordinateAttribute);
//        });
        
        [self setupCompressionSession:NO];
        
    }
    
    return self;
}

- (void)dealloc;
{
    [self teardownCompressionSession];
    [self destroyDataFBO];
}

#pragma mark -
#pragma mark Hardware accelerated encoder

static void vtCallback(void *outputCallbackRefCon,
                       void *sourceFrameRefCon,
                       OSStatus status,
                       VTEncodeInfoFlags infoFlags,
                       CMSampleBufferRef sampleBuffer )
{
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    //    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    //    CMTime dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer);
    
    //printf("status: %d\n", (int) status);
    bool isKeyframe = false;
    if(attachments != NULL) {
        CFDictionaryRef attachment;
        CFBooleanRef dependsOnOthers;
        attachment = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        dependsOnOthers = (CFBooleanRef)CFDictionaryGetValue(attachment, kCMSampleAttachmentKey_DependsOnOthers);
        isKeyframe = (dependsOnOthers == kCFBooleanFalse);
    }
    
    if(isKeyframe) {
        
        // Send the SPS and PPS.
        CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
        size_t spsSize, ppsSize;
        size_t parmCount;
        const uint8_t* sps, *pps;
        
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &sps, &spsSize, &parmCount, nullptr );
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 1, &pps, &ppsSize, &parmCount, nullptr );
        
        std::unique_ptr<uint8_t[]> sps_buf (new uint8_t[spsSize + 4]) ;
        std::unique_ptr<uint8_t[]> pps_buf (new uint8_t[ppsSize + 4]) ;
        
        memcpy(&sps_buf[4], sps, spsSize);
        spsSize+=4 ;
        memcpy(&sps_buf[0], &spsSize, 4);
        memcpy(&pps_buf[4], pps, ppsSize);
        ppsSize += 4;
        memcpy(&pps_buf[0], &ppsSize, 4);
        
        //        ((H264Encode*)outputCallbackRefCon)->compressionSessionOutput((uint8_t*)sps_buf.get(),spsSize, pts.value, dts.value);
        //        ((H264Encode*)outputCallbackRefCon)->compressionSessionOutput((uint8_t*)pps_buf.get(),ppsSize, pts.value, dts.value);
    }
    
    char* bufferData;
    size_t size;
    CMBlockBufferGetDataPointer(block, 0, NULL, &size, &bufferData);
    
    //    ((H264Encode*)outputCallbackRefCon)->compressionSessionOutput((uint8_t*)bufferData,size, pts.value, dts.value);
    
}

- (void)setupCompressionSession:(BOOL)useBaseline {
    
    //    encodeMutex.lock();
    
    OSStatus err = noErr;
    CFMutableDictionaryRef encoderSpecifications = nullptr;
    VTCompressionSessionRef _session = nullptr;
    
    int frameWidth = 1920;
    int frameHeight = 1080;
    int fps = 25;
    int bitrate = 5000000;
    
    NSDictionary* pixelBufferOptions = @{ (NSString*) kCVPixelBufferPixelFormatTypeKey : //@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                                          @(kCVPixelFormatType_32BGRA),
                                          (NSString*) kCVPixelBufferWidthKey : @(frameWidth),
                                          (NSString*) kCVPixelBufferHeightKey : @(frameHeight),
                                          (NSString*) kCVPixelBufferOpenGLESCompatibilityKey : @YES,
                                          (NSString*) kCVPixelBufferIOSurfacePropertiesKey : @{}};
    
    err = VTCompressionSessionCreate(
                                     kCFAllocatorDefault,
                                     frameWidth,
                                     frameHeight,
                                     kCMVideoCodecType_H264,
                                     encoderSpecifications,
                                     (__bridge CFDictionaryRef)pixelBufferOptions,
                                     NULL,
                                     &vtCallback,
                                     (__bridge void *)self,
                                     &_session);
    
    if(err == noErr) {
        session = _session;
        
        const int32_t v = fps * 1; // 2-second kfi
        
        CFNumberRef ref = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
        err = VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, ref);
        CFRelease(ref);
    }
    
    if(err == noErr) {
        const int v = fps;
        CFNumberRef ref = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
        err = VTSessionSetProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, ref);
        CFRelease(ref);
    }
    
    if(err == noErr) {
        CFBooleanRef allowFrameReodering = useBaseline ? kCFBooleanFalse : kCFBooleanTrue;
        err = VTSessionSetProperty(session , kVTCompressionPropertyKey_AllowFrameReordering, allowFrameReodering);
    }
    
    if(err == noErr) {
        const int v = bitrate;
        CFNumberRef ref = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
        err = VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, ref);
        CFRelease(ref);
    }
    
    if(err == noErr) {
        err = VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    }
    
    if(err == noErr) {
        CFStringRef profileLevel = useBaseline ? kVTProfileLevel_H264_Baseline_AutoLevel : kVTProfileLevel_H264_Main_AutoLevel;
        
        err = VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, profileLevel);
    }
    if(!useBaseline) {
        VTSessionSetProperty(session, kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC);
    }
    if(err == noErr) {
        VTCompressionSessionPrepareToEncodeFrames(session);
    }
    
    //    encodeMutex.unlock();
}

- (void)teardownCompressionSession
{
    if (session) {
        VTCompressionSessionInvalidate((VTCompressionSessionRef)session);
        CFRelease((VTCompressionSessionRef)session);
    }
}


#pragma mark -
#pragma mark Movie recording


- (void)startRecording;
{
    //    alreadyFinishedRecording = NO;
    //    startTime = kCMTimeInvalid;
    //    runSynchronouslyOnContextQueue(_movieWriterContext, ^{
    //        if (audioInputReadyCallback == NULL)
    //        {
    //            [//assetWriter startWriting];
    //        }
    //    });
    //    isRecording = YES;
    //    [assetWriter startSessionAtSourceTime:kCMTimeZero];
}

- (void)startRecordingInOrientation:(CGAffineTransform)orientationTransform;
{
    //assetWriterVideoInput.transform = orientationTransform;
    
    [self startRecording];
}

- (void)cancelRecording;
{
    //    if (assetWriter.status == AVAssetWriterStatusCompleted)
    //    {
    //        return;
    //    }
    //
    //    isRecording = NO
    //    runSynchronouslyOnContextQueue(_movieWriterContext, ^{
    //        alreadyFinishedRecording = YES;
    //
    //        if( assetWriter.status == AVAssetWriterStatusWriting && ! videoEncodingIsFinished )
    //        {
    //            videoEncodingIsFinished = YES;
    //            [assetWriterVideoInput markAsFinished];
    //        }
    //        if( assetWriter.status == AVAssetWriterStatusWriting && ! audioEncodingIsFinished )
    //        {
    //            audioEncodingIsFinished = YES;
    //            [assetWriterAudioInput markAsFinished];
    //        }
    //        [assetWriter cancelWriting];
    //    });
}

- (void)finishRecording;
{
    [self finishRecordingWithCompletionHandler:NULL];
}

- (void)finishRecordingWithCompletionHandler:(void (^)(void))handler;
{
    runSynchronouslyOnContextQueue(_movieWriterContext, ^{
        isRecording = NO;
        
        //        if (assetWriter.status == AVAssetWriterStatusCompleted || assetWriter.status == AVAssetWriterStatusCancelled || assetWriter.status == AVAssetWriterStatusUnknown)
        //        {
        //            if (handler)
        //                runAsynchronouslyOnContextQueue(_movieWriterContext, handler);
        //            return;
        //        }
        //        if( assetWriter.status == AVAssetWriterStatusWriting && ! videoEncodingIsFinished )
        //        {
        //            videoEncodingIsFinished = YES;
        //            [assetWriterVideoInput markAsFinished];
        //        }
        //        if( assetWriter.status == AVAssetWriterStatusWriting && ! audioEncodingIsFinished )
        //        {
        //            audioEncodingIsFinished = YES;
        //            [assetWriterAudioInput markAsFinished];
        //        }
        //#if (!defined(__IPHONE_6_0) || (__IPHONE_OS_VERSION_MAX_ALLOWED < __IPHONE_6_0))
        //        // Not iOS 6 SDK
        //        [assetWriter finishWriting];
        //        if (handler)
        //            runAsynchronouslyOnContextQueue(_movieWriterContext,handler);
        //#else
        //        // iOS 6 SDK
        //        if ([assetWriter respondsToSelector:@selector(finishWritingWithCompletionHandler:)]) {
        //            // Running iOS 6
        //            [assetWriter finishWritingWithCompletionHandler:(handler ?: ^{ })];
        //        }
        //        else {
        //            // Not running iOS 6
        //#pragma clang diagnostic push
        //#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        //            [assetWriter finishWriting];
        //#pragma clang diagnostic pop
        //            if (handler)
        //                runAsynchronouslyOnContextQueue(_movieWriterContext, handler);
        //        }
        //#endif
    });
}

- (BOOL)wantsMonochromeInput {
    return NO;
}

- (void)setCurrentlyReceivingMonochromeInput:(BOOL)newValue
{
    
}

#pragma mark -
#pragma mark Frame rendering

- (void)createDataFBO;
{
    glActiveTexture(GL_TEXTURE1);
    glGenFramebuffers(1, &movieFramebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, movieFramebuffer);
    
    if ([GPUImageContext supportsFastTextureUpload])
    {
        // Code originally sourced from http://allmybrain.com/2011/12/08/rendering-to-a-texture-with-ios-5-texture-cache-api/
        
        //        CVPixelBufferPoolCreatePixelBuffer (NULL, [assetWriterPixelBufferInput pixelBufferPool], &renderTarget);
        
        /* AVAssetWriter will use BT.601 conversion matrix for RGB to YCbCr conversion
         * regardless of the kCVImageBufferYCbCrMatrixKey value.
         * Tagging the resulting video file as BT.601, is the best option right now.
         * Creating a proper BT.709 video is not possible at the moment.
         */
        CVBufferSetAttachment(renderTarget, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(renderTarget, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(renderTarget, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
        
        CVOpenGLESTextureCacheCreateTextureFromImage (kCFAllocatorDefault, [_movieWriterContext coreVideoTextureCache], renderTarget,
                                                      NULL, // texture attributes
                                                      GL_TEXTURE_2D,
                                                      GL_RGBA, // opengl format
                                                      (int)videoSize.width,
                                                      (int)videoSize.height,
                                                      GL_BGRA, // native iOS format
                                                      GL_UNSIGNED_BYTE,
                                                      0,
                                                      &renderTexture);
        
        glBindTexture(CVOpenGLESTextureGetTarget(renderTexture), CVOpenGLESTextureGetName(renderTexture));
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, CVOpenGLESTextureGetName(renderTexture), 0);
    }
    else
    {
        glGenRenderbuffers(1, &movieRenderbuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, movieRenderbuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8_OES, (int)videoSize.width, (int)videoSize.height);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, movieRenderbuffer);
    }
    
    
    //    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    //    NSAssert(status == GL_FRAMEBUFFER_COMPLETE, @"Incomplete filter FBO: %d", status);
}

- (void)destroyDataFBO;
{
    runSynchronouslyOnContextQueue(_movieWriterContext, ^{
        [_movieWriterContext useAsCurrentContext];
        
        if (movieFramebuffer)
        {
            glDeleteFramebuffers(1, &movieFramebuffer);
            movieFramebuffer = 0;
        }
        
        if (movieRenderbuffer)
        {
            glDeleteRenderbuffers(1, &movieRenderbuffer);
            movieRenderbuffer = 0;
        }
        
        if ([GPUImageContext supportsFastTextureUpload])
        {
            if (renderTexture)
            {
                CFRelease(renderTexture);
            }
            if (renderTarget)
            {
                CVPixelBufferRelease(renderTarget);
            }
            
        }
    });
}

- (void)setFilterFBO;
{
    if (!movieFramebuffer)
    {
        [self createDataFBO];
    }
    
    glBindFramebuffer(GL_FRAMEBUFFER, movieFramebuffer);
    
    glViewport(0, 0, (int)videoSize.width, (int)videoSize.height);
}

- (void)renderAtInternalSizeUsingFramebuffer:(GPUImageFramebuffer *)inputFramebufferToUse;
{
    [_movieWriterContext useAsCurrentContext];
    [self setFilterFBO];
    
    [_movieWriterContext setContextShaderProgram:colorSwizzlingProgram];
    
    double val = ((double)arc4random() / ARC4RANDOM_MAX);
    
    glClearColor(val, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    
    // This needs to be flipped to write out to video correctly
    static const GLfloat squareVertices[] = {
        -1.0f, -1.0f,
        1.0f, -1.0f,
        -1.0f,  1.0f,
        1.0f,  1.0f,
    };
    
    const GLfloat *textureCoordinates = [GPUImageFilter textureCoordinatesForRotation:inputRotation];
    
    glActiveTexture(GL_TEXTURE4);
    glBindTexture(GL_TEXTURE_2D, [inputFramebufferToUse texture]);
    glUniform1i(colorSwizzlingInputTextureUniform, 4);
    
    //    NSLog(@"Movie writer framebuffer: %@", inputFramebufferToUse);
    
    glVertexAttribPointer(colorSwizzlingPositionAttribute, 2, GL_FLOAT, 0, 0, squareVertices);
    glVertexAttribPointer(colorSwizzlingTextureCoordinateAttribute, 2, GL_FLOAT, 0, 0, textureCoordinates);
    
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glFinish();
}

void runSynchronouslyOnVideoProcessingQueue(void (^block)(void))
{
    dispatch_queue_t videoProcessingQueue = [GPUImageContext sharedContextQueue];
#if !OS_OBJECT_USE_OBJC
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (dispatch_get_current_queue() == videoProcessingQueue)
#pragma clang diagnostic pop
#else
        if (dispatch_get_specific([GPUImageContext contextKey]))
#endif
        {
            block();
        }else
        {
            dispatch_sync(videoProcessingQueue, block);
        }
}

void runAsynchronouslyOnVideoProcessingQueue(void (^block)(void))
{
    dispatch_queue_t videoProcessingQueue = [GPUImageContext sharedContextQueue];
    
#if !OS_OBJECT_USE_OBJC
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (dispatch_get_current_queue() == videoProcessingQueue)
#pragma clang diagnostic pop
#else
        if (dispatch_get_specific([GPUImageContext contextKey]))
#endif
        {
            block();
        }else
        {
            dispatch_async(videoProcessingQueue, block);
        }
}

void runSynchronouslyOnContextQueue(GPUImageContext *context, void (^block)(void))
{
    dispatch_queue_t videoProcessingQueue = [context contextQueue];
#if !OS_OBJECT_USE_OBJC
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (dispatch_get_current_queue() == videoProcessingQueue)
#pragma clang diagnostic pop
#else
        if (dispatch_get_specific([GPUImageContext contextKey]))
#endif
        {
            block();
        }else
        {
            dispatch_sync(videoProcessingQueue, block);
        }
}

void runAsynchronouslyOnContextQueue(GPUImageContext *context, void (^block)(void))
{
    dispatch_queue_t videoProcessingQueue = [context contextQueue];
    
#if !OS_OBJECT_USE_OBJC
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (dispatch_get_current_queue() == videoProcessingQueue)
#pragma clang diagnostic pop
#else
        if (dispatch_get_specific([GPUImageContext contextKey]))
#endif
        {
            block();
        }else
        {
            dispatch_async(videoProcessingQueue, block);
        }
}

#pragma mark -
#pragma mark GPUImageInput protocol

- (void)newFrameReadyAtTime:(CMTime)frameTime atIndex:(NSInteger)textureIndex;
{
    if (!isRecording)
    {
        [firstInputFramebuffer unlock];
        return;
    }
    
    // Drop frames forced by images and other things with no time constants
    // Also, if two consecutive times with the same value are added to the movie, it aborts recording, so I bail on that case
    if ( (CMTIME_IS_INVALID(frameTime)) || (CMTIME_COMPARE_INLINE(frameTime, ==, previousFrameTime)) || (CMTIME_IS_INDEFINITE(frameTime)) )
    {
        [firstInputFramebuffer unlock];
        return;
    }
    if (CMTIME_IS_INVALID(startTime))
    {
        runSynchronouslyOnContextQueue(_movieWriterContext, ^{
            //            if ((videoInputReadyCallback == NULL) && (assetWriter.status != AVAssetWriterStatusWriting))
            //            {
            //                [assetWriter startWriting];
            //            }
            //
            //            [assetWriter startSessionAtSourceTime:frameTime];
            startTime = frameTime;
        });
    }
    
    GPUImageFramebuffer *inputFramebufferForBlock = firstInputFramebuffer;
    glFinish();
    
    runAsynchronouslyOnVideoProcessingQueue(^{
        
        // Render the frame with swizzled colors, so that they can be uploaded quickly as BGRA frames
        [_movieWriterContext useAsCurrentContext];
        [self renderAtInternalSizeUsingFramebuffer:inputFramebufferForBlock];
        
        CVPixelBufferRef pixel_buffer = NULL;
        
        if ([GPUImageContext supportsFastTextureUpload])
        {
            pixel_buffer = renderTarget;
            CVPixelBufferLockBaseAddress(pixel_buffer, 0);
        }
        else
        {
            //            CVReturn status = CVPixelBufferPoolCreatePixelBuffer (NULL, [assetWriterPixelBufferInput pixelBufferPool], &pixel_buffer);
            //            if ((pixel_buffer == NULL) || (status != kCVReturnSuccess))
            //            {
            //                CVPixelBufferRelease(pixel_buffer);
            //                return;
            //            }
            //            else
            //            {
            //                CVPixelBufferLockBaseAddress(pixel_buffer, 0);
            //
            //                GLubyte *pixelBufferData = (GLubyte *)CVPixelBufferGetBaseAddress(pixel_buffer);
            //                glReadPixels(0, 0, videoSize.width, videoSize.height, GL_RGBA, GL_UNSIGNED_BYTE, pixelBufferData);
            //            }
        }
        
        void(^write)() = ^() {
            
            NSLog(@"Write frame");
            
            CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);
            
            previousFrameTime = frameTime;
            
            if (![GPUImageContext supportsFastTextureUpload])
            {
                CVPixelBufferRelease(pixel_buffer);
            }
        };
        
        write();
        
        [inputFramebufferForBlock unlock];
    });
}

- (NSInteger)nextAvailableTextureIndex;
{
    return 0;
}

- (void)setInputFramebuffer:(GPUImageFramebuffer *)newInputFramebuffer atIndex:(NSInteger)textureIndex;
{
    [newInputFramebuffer lock];
    //    runSynchronouslyOnContextQueue(_movieWriterContext, ^{
    firstInputFramebuffer = newInputFramebuffer;
    //    });
}

- (void)setInputRotation:(GPUImageRotationMode)newInputRotation atIndex:(NSInteger)textureIndex;
{
    inputRotation = newInputRotation;
}

- (void)setInputSize:(CGSize)newSize atIndex:(NSInteger)textureIndex;
{
}

- (CGSize)maximumOutputSize;
{
    return videoSize;
}

- (void)endProcessing
{
    if (completionBlock)
    {
        if (!alreadyFinishedRecording)
        {
            alreadyFinishedRecording = YES;
            completionBlock();
        }
    }
}

- (BOOL)shouldIgnoreUpdatesToThisTarget;
{
    return NO;
}

- (CMTime)duration {
    if( ! CMTIME_IS_VALID(startTime) )
        return kCMTimeZero;
    if( ! CMTIME_IS_NEGATIVE_INFINITY(previousFrameTime) )
        return CMTimeSubtract(previousFrameTime, startTime);
    return kCMTimeZero;
}

//- (CGAffineTransform)transform {
//    return assetWriterVideoInput.transform;
//}
//
//- (void)setTransform:(CGAffineTransform)transform {
//    assetWriterVideoInput.transform = transform;
//}

@end