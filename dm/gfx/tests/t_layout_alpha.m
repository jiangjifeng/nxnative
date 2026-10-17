#include "../nvn/nvn_mtl.m"
#include <math.h>

int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { (void)p; (void)stage; memset(key, 0, 8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t serial; return ++serial; }

static int sample(id<MTLTexture> input, float out[4]) {
    NSError *err = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 vs(uint v [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[v],0,1); }\n"
        "fragment float4 fs(texture2d<float> t [[texture(0)]]) { return t.read(uint2(0)); }\n" options:nil error:&err];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    id<MTLRenderPipelineState> ps = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!ps) { fprintf(stderr, "%s\n", err.localizedDescription.UTF8String); return 1; }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; id<MTLTexture> tex = [g_dev newTextureWithDescriptor:td];
    id<MTLBuffer> result = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [queue commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = tex; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:ps]; [en setFragmentTexture:input atIndex:0]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(1,1,1)
             toBuffer:result destinationOffset:0 destinationBytesPerRow:16 destinationBytesPerImage:16];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted]; memcpy(out, result.contents, 16);
    return cb.status != MTLCommandBufferStatusCompleted;
}

int main(void) { @autoreleasepool {
    setenv("DM_NVN_OPAQUE_SCENE", "0123456789abcdef 1234567890abcdef", 1);
    g_dev = MTLCreateSystemDefaultDevice(); g_ntreg = 3; g_treg = calloc(g_ntreg, sizeof *g_treg);
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:4 height:2 mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget; d.storageMode = MTLStorageModeShared;
    id<MTLTexture> scene = [g_dev newTextureWithDescriptor:d]; uint32_t pixels[8];
    for (int i = 0; i < 8; i++) pixels[i] = 256u | (512u << 10) | (768u << 20); // Complete RGB, alpha 0.
    [scene replaceRegion:MTLRegionMake2D(0,0,4,2) mipmapLevel:0 withBytes:pixels bytesPerRow:16];
    NvShader *sh = [NvShader new]; strcpy(sh->key, "0123456789abcdef_b");
    uint64_t rid = 0; id<MTLTexture> view = tex_opaque_scene(sh, 1, scene, &rid);
    if (!view || !rid || tex_opaque_scene(sh, 1, scene, &rid) != view) return 1;
    float out[4]; int failed = sample(view, out);
    failed += fabsf(out[0]-256.f/1023.f)>0.0001f || fabsf(out[1]-512.f/1023.f)>0.0001f || fabsf(out[2]-768.f/1023.f)>0.0001f || out[3]!=1;
    failed += sample(scene, out) || out[3]!=0; // The capture's stored alpha is unchanged.
    strcpy(sh->key, "fedcba9876543210_b"); failed += tex_opaque_scene(sh, 1, scene, &rid) != nil;
    strcpy(sh->key, "0123456789abcdef_b");
    d.width = 2; id<MTLTexture> other_size = [g_dev newTextureWithDescriptor:d];
    [other_size replaceRegion:MTLRegionMake2D(0,0,2,2) mipmapLevel:0 withBytes:pixels bytesPerRow:8];
    strcpy(sh->key, "1234567890abcdef_b");
    view = tex_opaque_scene(sh, 1, other_size, &rid);
    if (!view) return 1;
    failed += sample(view, out) || out[3]!=1;
    strcpy(sh->key, "0123456789abcdef_b");
    d.width = 4; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> asset = [g_dev newTextureWithDescriptor:d]; failed += tex_opaque_scene(sh, 1, asset, &rid) != nil;
    d.pixelFormat = MTLPixelFormatRGBA8Unorm; d.usage |= MTLTextureUsageRenderTarget;
    id<MTLTexture> rgba = [g_dev newTextureWithDescriptor:d]; failed += tex_opaque_scene(sh, 1, rgba, &rid) != nil;
    d.pixelFormat = MTLPixelFormatR8Unorm; id<MTLTexture> mask = [g_dev newTextureWithDescriptor:d]; uint8_t reds[8]; memset(reds, 64, sizeof reds);
    [mask replaceRegion:MTLRegionMake2D(0,0,4,2) mipmapLevel:0 withBytes:reds bytesPerRow:4];
    id<MTLTexture> mapped = [mask newTextureViewWithPixelFormat:mask.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(0,1) slices:NSMakeRange(0,1)
                                                   swizzle:MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed,MTLTextureSwizzleZero,MTLTextureSwizzleZero,MTLTextureSwizzleOne)];
    id<MTLTexture> red = tex_alpha_red(2, mapped, &rid);
    if (!red) return 1;
    failed += sample(red, out) || fabsf(out[3]-64.f/255.f)>0.0001f;
    printf("layout capture alpha GPU checks: failed=%d\n", failed);
    return failed != 0;
} }
