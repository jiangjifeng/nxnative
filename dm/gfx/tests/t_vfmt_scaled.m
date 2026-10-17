#include "../nvn/nvn_mtl.m"
#include <math.h>

int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { (void)p; (void)stage; memset(key, 0, 8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t serial; return ++serial; }

// Exercise the production vertex descriptor and an actual GPU fetch. Values above
// one and 127 distinguish UI2F from normalized, signed and constant-zero inputs.
int main(void) { @autoreleasepool {
    g_dev = MTLCreateSystemDefaultDevice();
    NSError *err = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct I { float4 a [[attribute(0)]]; }; struct V { float4 p [[position]]; float4 a; };\n"
        "vertex V vs(I in [[stage_in]], uint v [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return {float4(p[v],0,1),in.a}; }\n"
        "fragment float4 fs(V in [[stage_in]]) { return in.a; }\n" options:nil error:&err];
    if (!lib) { fprintf(stderr, "%s\n", err.localizedDescription.UTF8String); return 1; }
    NvShader *vs = [NvShader new], *fs = [NvShader new];
    vs->fn = [lib newFunctionWithName:@"vs"]; fs->fn = [lib newFunctionWithName:@"fs"];
    vs->rf.nv = 1; vs->rf.v[0].loc = 0; vs->rf.v[0].nvn = 2; vs->rf.v[0].ct = NVN_CT_FLOAT;
    pso_key key = {0}; key.cfmt[0] = MTLPixelFormatRGBA32Float; key.chmask = 0xf; key.samples = 1;
    key.attr[2] = (va_st){.fmt=NVN_FORMAT_RG8_UI2F, .offset=2, .stream=1}; key.stream[1].stride = 4;
    MTLRenderPipelineDescriptor *pd = pso_desc(&key, vs, fs, nil, 0);
    if (pd.vertexDescriptor.attributes[0].bufferIndex != VB_SLOT(1)) {
        fprintf(stderr, "RG8_UI2F fell back to a constant attribute\n"); return 1;
    }
    id<MTLRenderPipelineState> ps = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!ps) { fprintf(stderr, "%s\n", err.localizedDescription.UTF8String); return 1; }
    uint8_t bytes[] = {9,11,17,203, 9,11,17,203, 9,11,17,203};
    id<MTLBuffer> vb = [g_dev newBufferWithBytes:bytes length:sizeof bytes options:MTLResourceStorageModeShared];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; id<MTLTexture> tex = [g_dev newTextureWithDescriptor:td];
    id<MTLBuffer> result = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [queue commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = tex; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:ps]; [en setVertexBuffer:vb offset:0 atIndex:VB_SLOT(1)];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(1,1,1)
                toBuffer:result destinationOffset:0 destinationBytesPerRow:16 destinationBytesPerImage:16];
    [blit endEncoding]; [cb commit]; [cb waitUntilCompleted];
    float *v = result.contents;
    int failed = cb.status != MTLCommandBufferStatusCompleted || fabsf(v[0]-17)>0.01f || fabsf(v[1]-203)>0.01f || v[2]!=0 || v[3]!=1;
    printf("RG8_UI2F GPU fetch: %g %g %g %g; failed=%d\n", v[0], v[1], v[2], v[3], failed);
    return failed;
} }
