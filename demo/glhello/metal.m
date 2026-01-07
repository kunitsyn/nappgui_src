/* macOS Metal Demo */

#include <sewer/arch.hxx>
#include "metal.h"
#include "glhello.h"
#include <sewer/cassert.h>
#include <gui/view.h>
#include <core/heap.h>
#import <Metal/Metal.h>
#import <MetalKit/MTKView.h>

#if !defined(__MACOS__)
#error This file is only for OSX
#endif

/*---------------------------------------------------------------------------*/

static NSString *i_shader = @"using namespace metal;\n"
                             "struct VertexIn { packed_float3 position; packed_float3 color; float2 uv; };\n"
                             "struct VertexOut { float4 position [[position]]; float3 color; float2 uv; };\n"
                             "constexpr sampler s = sampler(coord::normalized, address::clamp_to_edge, filter::linear);\n"
                             "\n"
                             "vertex VertexOut vertexShader(uint vertexID [[vertex_id]], \n"
                             "                              constant VertexIn *vertexPositions, \n"
                             "                              constant float4x4& mvp [[buffer(1)]]) {\n"
                             "    return { \n"
                             "        mvp * float4(vertexPositions[vertexID].position, 1.0f), \n"
                             "        vertexPositions[vertexID].color, \n"
                             "        vertexPositions[vertexID].uv };\n"
                             "}\n"
                             "\n"
                             "fragment float4 fragmentShader(VertexOut vertexOutPositions [[stage_in]], \n"
                             "                               texture2d<half> texture [[texture(0)]]) {\n"
                             "    return float4(vertexOutPositions.color, 1.0f) * float4(texture.sample(s, vertexOutPositions.uv));\n"
                             "}";

/*---------------------------------------------------------------------------*/

struct _metal_t
{
    MTKView* mtkView;
    id<MTLCommandQueue> commandQueue;
    id<MTLBuffer> triangle;
    id<MTLBuffer> mvp;
    id<MTLLibrary> library;
    id<MTLRenderPipelineState> pipelineState;
    id<MTLTexture> texture;
};

static void i_draw(Metal *metal, real32_t angle, real32_t scale);

/*---------------------------------------------------------------------------*/

@interface GLHelloDelegate : NSObject<MTKViewDelegate>
@property Metal *context;
@property real32_t angle;
@property real32_t scale;
@end

@implementation GLHelloDelegate

- (void) drawInMTKView:(MTKView *) view
{
    i_draw(_context, _angle, _scale);
}

- (void) mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size
{
}

@end

/*---------------------------------------------------------------------------*/

Metal *metal_create(View *view, int *err)
{
    NSView *nview = view_native(view);
    // NAppGUI only sends us draw updates when either
    // (1) NSGraphicsContext is set, which we won't have, or
    // (2) this flag is set.
    // We need draw updates for GLHello to work.
    [nview NAppGUIOSX_setOpenGL];
    // Despite NAppGUI releasing the NSOpenGLContext when we destroy
    // OpenGL, it may still bind to the view as a layer.
    // Without this line, we may see a frame of old OpenGL data
    // on the view when switching OpenGL <-> Metal.
    [nview setLayer:nil];
    
    MTKView *mtkView = [[MTKView alloc] initWithFrame:nview.frame];
    [mtkView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [mtkView setPaused:YES];
    [mtkView setEnableSetNeedsDisplay:YES];
    [nview addSubview:mtkView];
    
    id<MTLDevice> device = [mtkView preferredDevice];
    [mtkView setDevice:device];
    
    id<MTLCommandQueue> commandQueue = [device newCommandQueue];
    if (!commandQueue)
    {
        *err = 2;
        goto cleanup_0;
    }
    
    real32_t vertices[] = {
        0, 1, 0, 1, 0, 0, .5f, 0, /* v0 pos, color, tex */
        -1, -1, 0, 0, 1, 0, 0, 1, /* v1 pos, color, tex */
        1, -1, 0, 0, 0, 1, 1, 1   /* v2 pos, color, tex */
    };
    id<MTLBuffer> triangleBuffer = [device newBufferWithBytes:vertices
                                                       length:sizeof(vertices)
                                                      options:MTLResourceStorageModeShared];
    if (!triangleBuffer) {
        *err = 3;
        goto cleanup_1;
    }
    
    id<MTLBuffer> mvpBuffer = [device newBufferWithLength:sizeof(real32_t[16])
                                                  options:MTLResourceStorageModeShared];
    if (!mvpBuffer) {
        *err = 4;
        goto cleanup_2;
    }
    
    id<MTLLibrary> library = [device newLibraryWithSource:i_shader
                                                  options:nil
                                                    error:nil];
    if (!library) {
        *err = 5;
        goto cleanup_3;
    }
    
    id<MTLFunction> vertexShader = [library newFunctionWithName:@"vertexShader"];
    id<MTLFunction> fragmentShader = [library newFunctionWithName:@"fragmentShader"];
    MTLRenderPipelineDescriptor *rpDesc = [[MTLRenderPipelineDescriptor alloc] init];
    [rpDesc setLabel:@"GLHello Rendering Pipeline"];
    [rpDesc setVertexFunction:vertexShader];
    [rpDesc setFragmentFunction:fragmentShader];
    [[[rpDesc colorAttachments] objectAtIndexedSubscript:0] setPixelFormat:MTLPixelFormatBGRA8Unorm];
    id<MTLRenderPipelineState> rpState = [device newRenderPipelineStateWithDescriptor:rpDesc
                                                                                error:nil];
    [rpDesc release];
    [library release];
    if (!rpState) {
        *err = 6;
        goto cleanup_3;
    }
    
    const byte_t *texdata = NULL;
    uint32_t texwidth, texheight;
    pixformat_t texformat;
    glhello_texdata(&texdata, &texwidth, &texheight, &texformat);
    cassert(texformat == ekRGB24);
    
    MTLTextureDescriptor *textureDescriptor = [[MTLTextureDescriptor alloc] init];
    textureDescriptor.pixelFormat = MTLPixelFormatBGRA8Unorm;
    textureDescriptor.width = texwidth;
    textureDescriptor.height = texheight;
    id<MTLTexture> texture = [device newTextureWithDescriptor:textureDescriptor];
    if (!texture) {
        *err = 7;
        goto cleanup_4;
    }
    
    byte_t *texdata_padded_with_alpha = malloc(texwidth * texheight * 4);
    for (size_t i = 0; i < texwidth; ++i) {
        for (size_t j = 0; j < texheight; ++j) {
            const size_t in_start = (j * texwidth + i) * 3;
            const size_t out_start = (j * texwidth + i) * 4;
            texdata_padded_with_alpha[out_start + 0] = texdata[in_start + 0];
            texdata_padded_with_alpha[out_start + 1] = texdata[in_start + 1];
            texdata_padded_with_alpha[out_start + 2] = texdata[in_start + 2];
            texdata_padded_with_alpha[out_start + 3] = 0xff;
        }
    }
    MTLRegion textureRegion = MTLRegionMake2D(0, 0, texwidth, texheight);
    [texture replaceRegion:textureRegion
               mipmapLevel:0
                 withBytes:texdata_padded_with_alpha
               bytesPerRow:4 * texwidth];
    free(texdata_padded_with_alpha);
    
    Metal *ret = heap_new0(Metal);
    ret->mtkView = mtkView;
    ret->commandQueue = commandQueue;
    ret->triangle = triangleBuffer;
    ret->mvp = mvpBuffer;
    ret->pipelineState = rpState;
    ret->texture = texture;
    
    GLHelloDelegate *delegate = [[GLHelloDelegate alloc] init];
    delegate.context = ret;
    [mtkView setDelegate:delegate];
    
    return ret;
    
cleanup_4:
    [rpState release];
cleanup_3:
    [mvpBuffer release];
cleanup_2:
    [triangleBuffer release];
cleanup_1:
    [commandQueue release];
cleanup_0:
    [mtkView release];
    return NULL;
}

/*---------------------------------------------------------------------------*/

void metal_destroy(Metal **metal)
{
    [[(*metal)->mtkView superview] NAppGUIOSX_unsetOpenGL];
    [(*metal)->mtkView removeFromSuperview];
    [[(*metal)->mtkView delegate] release];
    [(*metal)->mtkView setDelegate:nil];
    [(*metal)->mtkView release];
    
    [(*metal)->commandQueue release];
    [(*metal)->triangle release];
    [(*metal)->mvp release];
    [(*metal)->pipelineState release];
    [(*metal)->texture release];
    heap_delete(metal, Metal);
}

/*---------------------------------------------------------------------------*/

void metal_draw(Metal *metal, real32_t angle, real32_t scale)
{
    [(GLHelloDelegate *)[metal->mtkView delegate] setAngle:angle];
    [(GLHelloDelegate *)[metal->mtkView delegate] setScale:scale];
    [metal->mtkView draw];
}

/*---------------------------------------------------------------------------*/

void i_draw(Metal *metal, real32_t angle, real32_t scale)
{
    id<CAMetalDrawable> drawable = [metal->mtkView currentDrawable];
    if (drawable == NULL)
    {
        return;
    }
    id<MTLCommandBuffer> commandBuffer = [metal->commandQueue commandBuffer];
    MTLRenderPassDescriptor *renderPassDesc = [[MTLRenderPassDescriptor alloc] init];
    
    MTLRenderPassColorAttachmentDescriptor *renderPassCADesc = [[renderPassDesc colorAttachments] objectAtIndexedSubscript:0];
    [renderPassCADesc setTexture:[drawable texture]];
    [renderPassCADesc setLoadAction:MTLLoadActionClear];
    [renderPassCADesc setClearColor:MTLClearColorMake(.8f, .8f, .8f, 1.f)];
    [renderPassCADesc setStoreAction:MTLStoreActionStore];
    
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDesc];
    [encoder setRenderPipelineState:metal->pipelineState];
    [encoder setVertexBuffer:metal->triangle offset:0 atIndex:0];
    [encoder setFragmentTexture:metal->texture atIndex:0];
    
    real32_t mvp[16];
    glhello_scale_rotate_Z(mvp, angle * M_PI * 2, scale);
    memcpy([metal->mvp contents], mvp, sizeof(mvp));
    [encoder setVertexBuffer:metal->mvp offset:0 atIndex:1];
    
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    [renderPassDesc release];
}
