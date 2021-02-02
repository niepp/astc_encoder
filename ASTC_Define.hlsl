
#define BLOCK_BYTES	 16

#define X_GRIDS 4
#define Y_GRIDS 4


#define ISE_BYTE_COUNT (BLOCK_BYTES + 4)
#define MAX_WEIGHT_RANGE_NUM 12

#define MAX_ENCODED_WEIGHT_BYTES 12
#define MAX_ENCODED_COLOR_ENDPOINT_BYTES 12

#define SMALL_VALUE 0.00001

/*
* supported color_endpoint_mode
*/
#define CEM_LDR_RGB_DIRECT 8
#define CEM_LDR_RGBA_DIRECT 12

/**
 * form [ARM:astc-encoder]
 * Define normalized (starting at zero) numeric ranges that can be represented
 * with 8 bits or less.
 */
#define	QUANT_2 0
#define	QUANT_3 1
#define	QUANT_4 2
#define	QUANT_5 3
#define	QUANT_6 4
#define	QUANT_8 5
#define	QUANT_10 6
#define	QUANT_12 7
#define	QUANT_16 8
#define	QUANT_20 9
#define	QUANT_24 10
#define	QUANT_32 11
#define	QUANT_40 12
#define	QUANT_48 13
#define	QUANT_64 14
#define	QUANT_80 15
#define	QUANT_96 16
#define	QUANT_128 17
#define	QUANT_160 18
#define	QUANT_192 19
#define	QUANT_256 20
#define	QUANT_MAX 21

int sum(int3 color)
{
	return color.r + color.g + color.b;
}

float3 to_float3(int3 color)
{
	return float3(color.r, color.g, color.b);
}

int3 to_int3(float3 color)
{
	return int3(color.r, color.g, color.b);
}

float4 to_float4(int4 color)
{
	return float4(color.r, color.g, color.b, color.a);
}

int4 to_int4(float4 color)
{
	return int4(color.r, color.g, color.b, color.a);
}

int4 array16_2_int4(int inputs[16])
{
	uint4 outputs = 0;
	outputs.x = (inputs[0]) | (inputs[1] << 8) | (inputs[2] << 16) | (inputs[3] << 24);
	outputs.y = (inputs[4]) | (inputs[5] << 8) | (inputs[6] << 16) | (inputs[7] << 24);
	outputs.z = (inputs[8]) | (inputs[9] << 8) | (inputs[10] << 16) | (inputs[11] << 24);
	outputs.w = (inputs[12]) | (inputs[13] << 8) | (inputs[14] << 16) | (inputs[15] << 24);
	return outputs;
}

void int4_2_array16(int4 src, out int dst[16])
{
	dst[0] = src.x & 0xFF;
	dst[1] = (src.x >> 8) & 0xFF;
	dst[2] = (src.x >> 16) & 0xFF;
	dst[3] = (src.x >> 24) & 0xFF;

	dst[4] = src.y & 0xFF;
	dst[5] = (src.y >> 8) & 0xFF;
	dst[6] = (src.y >> 16) & 0xFF;
	dst[7] = (src.y >> 24) & 0xFF;

	dst[8] = src.z & 0xFF;
	dst[9] = (src.z >> 8) & 0xFF;
	dst[10] = (src.z >> 16) & 0xFF;
	dst[11] = (src.z >> 24) & 0xFF;

	dst[12] = src.w & 0xFF;
	dst[13] = (src.w >> 8) & 0xFF;
	dst[14] = (src.w >> 16) & 0xFF;
	dst[15] = (src.w >> 24) & 0xFF;

}

void swap(inout int4 lhs, inout int4 rhs)
{
	int4 tmp = lhs;
	lhs = rhs;
	rhs = tmp;
}

void swap(inout float4 lhs, inout float4 rhs)
{
	float4 tmp = lhs;
	lhs = rhs;
	rhs = tmp;
}

void swap(inout int lhs, inout int rhs)
{
	int tmp = lhs;
	lhs = rhs;
	rhs = tmp;
}
