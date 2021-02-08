
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

uint sum(uint3 color)
{
	return color.r + color.g + color.b;
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

void swap(inout uint4 lhs, inout uint4 rhs)
{
	uint4 tmp = lhs;
	lhs = rhs;
	rhs = tmp;
}

void swap(inout float4 lhs, inout float4 rhs)
{
	float4 tmp = lhs;
	lhs = rhs;
	rhs = tmp;
}

void swap(inout uint lhs, inout uint rhs)
{
	uint tmp = lhs;
	lhs = rhs;
	rhs = tmp;
}
