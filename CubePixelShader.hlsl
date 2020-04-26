Texture2D<float4>  rgbChannel     : t0;
SamplerState       defaultSampler : s0;

struct PixelShaderInput
{
    float4 pos   : SV_POSITION;
    float2 texCoord : TEXCOORD0;
};

float4 main(PixelShaderInput input) : SV_TARGET
{
    return float4(rgbChannel.Sample(defaultSampler, input.texCoord));
}
