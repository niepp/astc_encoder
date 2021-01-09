
#define BLOCK_SIZE_X	4
#define BLOCK_SIZE_Y	4
#define BLOCK_SIZE		(BLOCK_SIZE_X * BLOCK_SIZE_Y)
#define BLOCK_BYTES		16

#define ISE_BYTE_COUNT BLOCK_BYTES

#define BLOCK_MODE_COUNT 2048

#define MAX_WEIGHTS_PER_BLOCK 64
#define MIN_WEIGHT_BITS_PER_BLOCK 24
#define MAX_WEIGHT_BITS_PER_BLOCK 96

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


// candidate blockmode (weights quantmethod & endpoints quantmethod)
#define BLOCK_MODE_NUM 10
static const uint block_modes[2][BLOCK_MODE_NUM][2] =
{
	{ // CEM_LDR_RGB_DIRECT
		{QUANT_3, QUANT_256},
		{QUANT_4, QUANT_256},
		{QUANT_5, QUANT_256},
		{QUANT_6, QUANT_256},
		{QUANT_8, QUANT_256},
		{QUANT_12, QUANT_256},
		{QUANT_16, QUANT_192},
		{QUANT_20, QUANT_96},
		{QUANT_24, QUANT_64},
		{QUANT_32, QUANT_32},
	},

	{ // CEM_LDR_RGBA_DIRECT
		{QUANT_3, QUANT_256},
		{QUANT_4, QUANT_256},
		{QUANT_5, QUANT_256},
		{QUANT_6, QUANT_256},
		{QUANT_8, QUANT_192},
		{QUANT_12, QUANT_96},
		{QUANT_16, QUANT_48},
		{QUANT_20, QUANT_32},
		{QUANT_24, QUANT_24},
		{QUANT_32, QUANT_12},
	}
};

// endpoint method only use
/*
	QUANT_12
	QUANT_24
	QUANT_32
	QUANT_48
	QUANT_64
	QUANT_96
	QUANT_192
	QUANT_256
*/

static const uint quant_method_map[] = { 255, 255, 255, 255, 255, 255, 255, 0, 255, 255, 1, 2, 255, 3, 4, 255, 5, 255, 255, 6, 7, };

// form [ARM:astc-encoder]
static const uint weight_quantize_table[] = { 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24, 32, 40, 48, 64, 80, 96, 128, 160, 192, 256 };


 /**
  * Table that describes the number of trits or quints along with bits required
  * for storing each range.
  */
static const uint bits_trits_quints_table[QUANT_MAX][3] =
{
	{1, 0, 0},  // RANGE_2
	{0, 1, 0},  // RANGE_3
	{2, 0, 0},  // RANGE_4
	{0, 0, 1},  // RANGE_5
	{1, 1, 0},  // RANGE_6
	{3, 0, 0},  // RANGE_8
	{1, 0, 1},  // RANGE_10
	{2, 1, 0},  // RANGE_12
	{4, 0, 0},  // RANGE_16
	{2, 0, 1},  // RANGE_20
	{3, 1, 0},  // RANGE_24
	{5, 0, 0},  // RANGE_32
	{3, 0, 1},  // RANGE_40
	{4, 1, 0},  // RANGE_48
	{6, 0, 0},  // RANGE_64
	{4, 0, 1},  // RANGE_80
	{5, 1, 0},  // RANGE_96
	{7, 0, 0},  // RANGE_128
	{5, 0, 1},  // RANGE_160
	{6, 1, 0},  // RANGE_192
	{8, 0, 0}   // RANGE_256
};


uint sum(uint3 color)
{
	return color.r + color.g + color.b;
}

float3 to_float3(uint3 color)
{
	return float3(color.r, color.g, color.b);
}

uint3 to_int3(float3 color)
{
	return uint3(color.r, color.g, color.b);
}

float4 to_float4(uint4 color)
{
	return float4(color.r, color.g, color.b, color.a);
}

uint4 to_int4(float4 color)
{
	return uint4(color.r, color.g, color.b, color.a);
}

uint4 array16_2_uint4(uint inputs[16])
{
	uint4 outputs = 0;
	outputs.x = (inputs[0]) | (inputs[1] << 8) | (inputs[2] << 16) | (inputs[3] << 24);
	outputs.y = (inputs[4]) | (inputs[5] << 8) | (inputs[6] << 16) | (inputs[7] << 24);
	outputs.z = (inputs[8]) | (inputs[9] << 8) | (inputs[10] << 16) | (inputs[11] << 24);
	outputs.w = (inputs[12]) | (inputs[13] << 8) | (inputs[14] << 16) | (inputs[15] << 24);
	return outputs;
}

void uint4_2_array16(uint4 src, out uint dst[16])
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

void swap(inout uint4 lhs, inout uint4 rhs)
{
	uint4 tmp = lhs;
	lhs = rhs;
	rhs = tmp;
}

void swap(inout uint3 lhs, inout uint3 rhs)
{
	uint3 tmp = lhs;
	lhs = rhs;
	rhs = tmp;
}

void swap(inout uint lhs, inout uint rhs)
{
	uint tmp = lhs;
	lhs = rhs;
	rhs = tmp;
}

