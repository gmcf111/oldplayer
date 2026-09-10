#import "OPSoftVideoView.h"
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <QuartzCore/QuartzCore.h>

static const char *kVertexShader =
    "attribute vec4 a_position;\n"
    "attribute vec2 a_texcoord;\n"
    "varying vec2 v_uv;\n"
    "void main() {\n"
    "  gl_Position = a_position;\n"
    "  v_uv = a_texcoord;\n"
    "}\n";

// Limited-range BT.601: Y in [16,235], U/V centered on 128.
static const char *kFragmentShader =
    "precision mediump float;\n"
    "varying vec2 v_uv;\n"
    "uniform sampler2D s_y;\n"
    "uniform sampler2D s_u;\n"
    "uniform sampler2D s_v;\n"
    "void main() {\n"
    "  float y = (texture2D(s_y, v_uv).r - 0.0625) * 1.164;\n"
    "  float u = texture2D(s_u, v_uv).r - 0.5;\n"
    "  float v = texture2D(s_v, v_uv).r - 0.5;\n"
    "  gl_FragColor = vec4(y + 1.596 * v,\n"
    "                      y - 0.391 * u - 0.813 * v,\n"
    "                      y + 2.018 * u, 1.0);\n"
    "}\n";

@interface OPSoftVideoView () {
    EAGLContext *context;
    GLuint program;
    GLuint textures[3];
    GLuint framebuffer;
    GLuint renderbuffer;
    GLint backingW;
    GLint backingH;
    GLint attrPos;
    GLint attrUV;
    GLint uniY;
    GLint uniU;
    GLint uniV;
    int texAllocW[3];
    int texAllocH[3];
    BOOL glReady;
}
@end

@implementation OPSoftVideoView

+ (Class)layerClass {
    return [CAEAGLLayer class];
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor blackColor];
        self.contentScaleFactor = 1.0; // 1:1 pixels; old GPUs are slow enough
        CAEAGLLayer *layer = (CAEAGLLayer *)self.layer;
        layer.opaque = YES;
        layer.drawableProperties = @{
            kEAGLDrawablePropertyRetainedBacking: @NO,
            kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8
        };
        [self setupGL];
    }
    return self;
}

- (void)dealloc {
    if ([EAGLContext currentContext] == context) {
        [EAGLContext setCurrentContext:nil];
    }
    if (glReady) {
        [EAGLContext setCurrentContext:context];
        if (framebuffer) glDeleteFramebuffers(1, &framebuffer);
        if (renderbuffer) glDeleteRenderbuffers(1, &renderbuffer);
        glDeleteTextures(3, textures);
        if (program) glDeleteProgram(program);
        [EAGLContext setCurrentContext:nil];
    }
}

#pragma mark - Setup

- (GLuint)compileShader:(GLenum)type source:(const char *)source {
    GLuint sh = glCreateShader(type);
    glShaderSource(sh, 1, &source, NULL);
    glCompileShader(sh);
    GLint ok = 0;
    glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        GLchar log[256];
        glGetShaderInfoLog(sh, sizeof(log), NULL, log);
        NSLog(@"OPSoftVideoView: shader compile failed: %s", log);
        glDeleteShader(sh);
        return 0;
    }
    return sh;
}

- (void)setupGL {
    context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    if (!context) {
        NSLog(@"OPSoftVideoView: no ES2 context");
        return;
    }
    if (![EAGLContext setCurrentContext:context]) return;

    GLuint vs = [self compileShader:GL_VERTEX_SHADER source:kVertexShader];
    GLuint fs = [self compileShader:GL_FRAGMENT_SHADER source:kFragmentShader];
    if (!vs || !fs) {
        if (vs) glDeleteShader(vs);
        if (fs) glDeleteShader(fs);
        return;
    }
    program = glCreateProgram();
    glAttachShader(program, vs);
    glAttachShader(program, fs);
    glBindAttribLocation(program, 0, "a_position");
    glBindAttribLocation(program, 1, "a_texcoord");
    glLinkProgram(program);
    glDeleteShader(vs);
    glDeleteShader(fs);
    GLint linked = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) {
        NSLog(@"OPSoftVideoView: program link failed");
        glDeleteProgram(program);
        program = 0;
        return;
    }
    attrPos = 0;
    attrUV = 1;
    uniY = glGetUniformLocation(program, "s_y");
    uniU = glGetUniformLocation(program, "s_u");
    uniV = glGetUniformLocation(program, "s_v");

    glGenTextures(3, textures);
    for (int i = 0; i < 3; i++) {
        glBindTexture(GL_TEXTURE_2D, textures[i]);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    }
    glGenFramebuffers(1, &framebuffer);
    glGenRenderbuffers(1, &renderbuffer);
    glReady = YES;
}

- (BOOL)ensureBuffers {
    if (!glReady) return NO;
    [EAGLContext setCurrentContext:context];
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, renderbuffer);
    CGSize points = self.bounds.size;
    CGFloat scale = self.contentScaleFactor;
    GLint w = (GLint)(points.width * scale);
    GLint h = (GLint)(points.height * scale);
    if (w != backingW || h != backingH) {
        if (![context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)self.layer]) {
            return NO;
        }
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &backingW);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &backingH);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            return NO;
        }
    }
    return YES;
}

#pragma mark - Rendering

- (void)uploadPlane:(int)plane
              bytes:(const uint8_t *)bytes
              width:(int)width
             height:(int)height
             stride:(int)stride {
    if (stride < width) stride = width;
    if (texAllocW[plane] != stride || texAllocH[plane] != height) {
        glBindTexture(GL_TEXTURE_2D, textures[plane]);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE, stride, height, 0,
                     GL_LUMINANCE, GL_UNSIGNED_BYTE, NULL);
        texAllocW[plane] = stride;
        texAllocH[plane] = height;
    }
    glBindTexture(GL_TEXTURE_2D, textures[plane]);
    if (stride == width) {
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height,
                        GL_LUMINANCE, GL_UNSIGNED_BYTE, bytes);
    } else {
        // Padded lines: upload row by row into a stride-wide texture and
        // shrink the UV range below so only real pixels are sampled.
        for (int y = 0; y < height; y++) {
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, y, width, 1,
                            GL_LUMINANCE, GL_UNSIGNED_BYTE, bytes + (size_t)y * stride);
        }
    }
}

- (void)displayY:(const uint8_t *)y
               U:(const uint8_t *)u
               V:(const uint8_t *)v
           width:(int)width
          height:(int)height
         strideY:(int)strideY
         strideU:(int)strideU
         strideV:(int)strideV {
    if (!y || !u || !v || width <= 0 || height <= 0) return;
    if (![self ensureBuffers]) return;
    glUseProgram(program);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    [self uploadPlane:0 bytes:y width:width height:height stride:strideY];
    [self uploadPlane:1 bytes:u width:width / 2 height:height / 2 stride:strideU];
    [self uploadPlane:2 bytes:v width:width / 2 height:height / 2 stride:strideV];

    // Aspect-fit viewport (letterbox).
    float viewAspect = backingW > 0 && backingH > 0 ? (float)backingW / backingH : 1.0f;
    float videoAspect = (float)width / height;
    GLint vpW = backingW, vpH = backingH, vpX = 0, vpY = 0;
    if (videoAspect > viewAspect) {
        vpH = (GLint)(backingW / videoAspect);
        vpY = (backingH - vpH) / 2;
    } else {
        vpW = (GLint)(backingH * videoAspect);
        vpX = (backingW - vpW) / 2;
    }
    glViewport(0, 0, backingW, backingH);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glViewport(vpX, vpY, vpW, vpH);

    static const GLfloat pos[] = { -1, -1,  1, -1,  -1, 1,  1, 1 };
    // NOTE: textures are stride-wide, so sample only [0, width/stride].
    // V is flipped because GL texture row 0 is the bottom.
    float sMax = (float)width / (strideY > width ? strideY : width);
    const GLfloat quadUV[] = { 0, 1,  sMax, 1,  0, 0,  sMax, 0 };
    glVertexAttribPointer((GLuint)attrPos, 2, GL_FLOAT, GL_FALSE, 0, pos);
    glEnableVertexAttribArray((GLuint)attrPos);
    glVertexAttribPointer((GLuint)attrUV, 2, GL_FLOAT, GL_FALSE, 0, quadUV);
    glEnableVertexAttribArray((GLuint)attrUV);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, textures[0]);
    glUniform1i(uniY, 0);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, textures[1]);
    glUniform1i(uniU, 1);
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, textures[2]);
    glUniform1i(uniV, 2);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    [context presentRenderbuffer:GL_RENDERBUFFER];
}

- (void)clear {
    if (![self ensureBuffers]) return;
    glViewport(0, 0, backingW, backingH);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    [context presentRenderbuffer:GL_RENDERBUFFER];
}

@end
