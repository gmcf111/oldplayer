#import <UIKit/UIKit.h>

/**
 * OpenGL ES 2.0 view that renders YUV420P frames (the decoder's native
 * output) with a BT.601 color matrix in the fragment shader. Aspect-fit,
 * letterboxed with black. All methods must be called on the main thread.
 */
@interface OPSoftVideoView : UIView

// Copies the planes synchronously and presents them.
- (void)displayY:(const uint8_t *)y
               U:(const uint8_t *)u
               V:(const uint8_t *)v
           width:(int)width
          height:(int)height
         strideY:(int)strideY
         strideU:(int)strideU
         strideV:(int)strideV;

// Clears the screen to black.
- (void)clear;

@end
