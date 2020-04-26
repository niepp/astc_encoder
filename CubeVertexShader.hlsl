// A constant buffer that stores the model transform.
cbuffer ModelConstantBuffer : register(b0)
{
    float4x4 model;
	float4x4 viewProj;
};

// Per-vertex data used as input to the vertex shader.
struct VertexShaderInput
{
    float3 pos     : POSITION0;
    float2 texCoord : TEXCOORD0;
	uint instanceId : SV_InstanceID;
};

// Per-vertex data passed to the geometry shader.
struct VertexShaderOutput
{
    float4 pos     : SV_POSITION;
    float2 texCoord : TEXCOORD0;
};

// Simple shader to do vertex processing on the GPU.
VertexShaderOutput main(VertexShaderInput input)
{
    VertexShaderOutput output;
    float4 pos = float4(input.pos, 1.0f);

    float4x4 mvp = mul(model, viewProj);
    output.pos = mul(pos, mvp);

    output.texCoord = input.texCoord;

    return output;
}
