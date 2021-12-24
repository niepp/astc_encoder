 /**
  * Table that describes the number of trits or quints along with bits required
  * for storing each range.
  */
static const int bits_trits_quints_table[QUANT_MAX * 3] =
{
	1, 0, 0,  // RANGE_2
	0, 1, 0,  // RANGE_3
	2, 0, 0,  // RANGE_4
	0, 0, 1,  // RANGE_5
	1, 1, 0,  // RANGE_6
	3, 0, 0,  // RANGE_8
	1, 0, 1,  // RANGE_10
	2, 1, 0,  // RANGE_12
	4, 0, 0,  // RANGE_16
	2, 0, 1,  // RANGE_20
	3, 1, 0,  // RANGE_24
	5, 0, 0,  // RANGE_32
	3, 0, 1,  // RANGE_40
	4, 1, 0,  // RANGE_48
	6, 0, 0,  // RANGE_64
	4, 0, 1,  // RANGE_80
	5, 1, 0,  // RANGE_96
	7, 0, 0,  // RANGE_128
	5, 0, 1,  // RANGE_160
	6, 1, 0,  // RANGE_192
	8, 0, 0   // RANGE_256
};

static const int integer_from_trits[243] =
{
	0,1,2,    4,5,6,    8,9,10, 
	16,17,18, 20,21,22, 24,25,26,
	3,7,15,   19,23,27, 12,13,14, 
	32,33,34, 36,37,38, 40,41,42,
	48,49,50, 52,53,54, 56,57,58,
	35,39,47, 51,55,59, 44,45,46, 
	64,65,66, 68,69,70, 72,73,74,
	80,81,82, 84,85,86, 88,89,90,
	67,71,79, 83,87,91, 76,77,78,

	128,129,130, 132,133,134, 136,137,138,
	144,145,146, 148,149,150, 152,153,154,
	131,135,143, 147,151,155, 140,141,142,
	160,161,162, 164,165,166, 168,169,170,
	176,177,178, 180,181,182, 184,185,186,
	163,167,175, 179,183,187, 172,173,174,
	192,193,194, 196,197,198, 200,201,202,
	208,209,210, 212,213,214, 216,217,218,
	195,199,207, 211,215,219, 204,205,206,

	96,97,98, 	 100,101,102, 104,105,106,
	112,113,114, 116,117,118, 120,121,122,
	99,103,111,  115,119,123, 108,109,110, 
	224,225,226, 228,229,230, 232,233,234,
	240,241,242, 244,245,246, 248,249,250,
	227,231,239, 243,247,251, 236,237,238,
	28,29,30, 	 60,61,62, 	  92,93,94, 
	156,157,158, 188,189,190, 220,221,222,
	31,63,127, 	 159,191,255, 252,253,254,

};

static const int integer_from_quints[125] =
{
	0,1,2,3,4, 			8,9,10,11,12, 			16,17,18,19,20,			24,25,26,27,28, 		5,13,21,29,6,
	32,33,34,35,36, 	40,41,42,43,44, 		48,49,50,51,52, 		56,57,58,59,60, 		37,45,53,61,14,	
	64,65,66,67,68, 	72,73,74,75,76, 		80,81,82,83,84, 		88,89,90,91,92, 		69,77,85,93,22,
	96,97,98,99,100, 	104,105,106,107,108,	112,113,114,115,116,	120,121,122,123,124, 	101,109,117,125,30,	
	102,103,70,71,38, 	110,111,78,79,46, 		118,119,86,87,54, 		126,127,94,95,62, 		39,47,55,63,31
};


// Compute the number of bits required to store a number of items in a specific
// range using the bounded integer sequence encoding.
uint compute_ise_bitcount(uint items, int range)
{
	uint bits = bits_trits_quints_table[range * 3 + 0];
	uint trits = bits_trits_quints_table[range * 3 + 1];
	uint quints = bits_trits_quints_table[range * 3 + 2];

	if (trits)
	{
		return ((8 + 5 * bits) * items + 4) / 5;
	}

	if (quints)
	{
		return ((7 + 3 * bits) * items + 2) / 3;
	}

	return items * bits;
}


// 把number的低bitcount位写到bytes的bitoffset偏移处开始的位置
// number must be <= 255; bitcount must be <= 8
void orbits8_ptr(inout uint4 outputs, inout uint bitoffset, uint number, uint bitcount)
{
	//bitcount = clamp(bitcount, 0, 8);
	//number &= (1 << bitcount) - 1;
	uint newpos = bitoffset + bitcount;

	uint nidx = newpos >> 5;
	uint uidx = bitoffset >> 5;
	uint bit_idx = bitoffset & 31;

	uint bytes[4] = {outputs.x, outputs.y, outputs.z, outputs.w};
	bytes[uidx] |= (number << bit_idx);
	bytes[uidx + 1] |= (nidx > uidx) ? (number >> (32 - bit_idx)) : 0;

	outputs.x = bytes[0];
	outputs.y = bytes[1];
	outputs.z = bytes[2];
	outputs.w = bytes[3];

	bitoffset = newpos;

}

void split_high_low(uint n, uint i, out int high, out uint low)
{
	uint low_mask = (uint)((1 << i) - 1);
	low = n & low_mask;
	high = (n >> i) & 0xFF;
}

/**
 * Reverse bits of a byte.
 */
uint reverse_byte(uint p)
{
	p = ((p & 0xF) << 4) | ((p >> 4) & 0xF);
	p = ((p & 0x33) << 2) | ((p >> 2) & 0x33);
	p = ((p & 0x55) << 1) | ((p >> 1) & 0x55);
	return p;
}

/**
 * Encode a group of 5 numbers using trits and bits.
 */
void encode_trits(uint bitcount,
	uint b0,
	uint b1,
	uint b2,
	uint b3,
	uint b4,
	inout uint4 outputs, inout uint outpos)
{
	int t0, t1, t2, t3, t4;
	uint m0, m1, m2, m3, m4;

	split_high_low(b0, bitcount, t0, m0);
	split_high_low(b1, bitcount, t1, m1);
	split_high_low(b2, bitcount, t2, m2);
	split_high_low(b3, bitcount, t3, m3);
	split_high_low(b4, bitcount, t4, m4);

	uint packhigh = integer_from_trits[t4 * 81 + t3 * 27 + t2 * 9 + t1 * 3 + t0];

	orbits8_ptr(outputs, outpos, m0, bitcount);
	orbits8_ptr(outputs, outpos, packhigh & 3, 2);

	orbits8_ptr(outputs, outpos, m1, bitcount);
	orbits8_ptr(outputs, outpos, (packhigh >> 2) & 3, 2);

	orbits8_ptr(outputs, outpos, m2, bitcount);
	orbits8_ptr(outputs, outpos, (packhigh >> 4) & 1, 1);

	orbits8_ptr(outputs, outpos, m3, bitcount);
	orbits8_ptr(outputs, outpos, (packhigh >> 5) & 3, 2);

	orbits8_ptr(outputs, outpos, m4, bitcount);
	orbits8_ptr(outputs, outpos, (packhigh >> 7) & 1, 1);

}

/**
 * Encode a group of 3 numbers using quints and bits.
 */
void encode_quints(uint bitcount,
	uint b0,
	uint b1,
	uint b2,
	inout uint4 outputs, inout uint outpos)
{
	int q0, q1, q2;
	uint m0, m1, m2;

	split_high_low(b0, bitcount, q0, m0);
	split_high_low(b1, bitcount, q1, m1);
	split_high_low(b2, bitcount, q2, m2);

	uint packhigh = integer_from_quints[q2 * 25 + q1 * 5 + q0];

	orbits8_ptr(outputs, outpos, m0, bitcount);	
	orbits8_ptr(outputs, outpos, packhigh & 7, 3);
	
	orbits8_ptr(outputs, outpos, m1, bitcount);	
	orbits8_ptr(outputs, outpos, (packhigh >> 3) & 3, 2);
	
	orbits8_ptr(outputs, outpos, m2, bitcount);
	orbits8_ptr(outputs, outpos, (packhigh >> 5) & 3, 2);

}

void bise_endpoints(uint numbers[8], int range, inout uint4 outputs)
{
	uint bitpos = 0;
	uint bits = bits_trits_quints_table[range * 3 + 0];
	uint trits = bits_trits_quints_table[range * 3 + 1];
	uint quints = bits_trits_quints_table[range * 3 + 2];

#if HAS_ALPHA
	int count = 8;
#else
	int count = 6;
#endif

	if (trits == 1)
	{
		encode_trits(bits, numbers[0], numbers[1], numbers[2], numbers[3], numbers[4], outputs, bitpos);
		encode_trits(bits, numbers[5], numbers[6], numbers[7], 0, 0, outputs, bitpos);
		bitpos = ((8 + 5 * bits) * count + 4) / 5;
	}
	else if (quints == 1)
	{
		encode_quints(bits, numbers[0], numbers[1], numbers[2], outputs, bitpos);
		encode_quints(bits, numbers[3], numbers[4], numbers[5], outputs, bitpos);
		encode_quints(bits, numbers[6], numbers[7], 0, outputs, bitpos);
		bitpos = ((7 + 3 * bits) * count + 2) / 3;
	}
	else
	{
		for (int i = 0; i < count; ++i)
		{
			orbits8_ptr(outputs, bitpos, numbers[i], bits);
		}
	}

}

void bise_weights(uint numbers[16], int range, inout uint4 outputs)
{
	uint bitpos = 0;
	uint bits = bits_trits_quints_table[range * 3 + 0];
	uint trits = bits_trits_quints_table[range * 3 + 1];
	uint quints = bits_trits_quints_table[range * 3 + 2];

	if (trits == 1)
	{
		encode_trits(bits, numbers[0], numbers[1], numbers[2], numbers[3], numbers[4], outputs, bitpos);
		encode_trits(bits, numbers[5], numbers[6], numbers[7], numbers[8], numbers[9], outputs, bitpos);
		encode_trits(bits, numbers[10], numbers[11], numbers[12], numbers[13], numbers[14], outputs, bitpos);
		encode_trits(bits, numbers[15], 0, 0, 0, 0, outputs, bitpos);
		bitpos = ((8 + 5 * bits) * 16 + 4) / 5;
	}
	else if (quints == 1)
	{
		encode_quints(bits, numbers[0], numbers[1], numbers[2], outputs, bitpos);
		encode_quints(bits, numbers[3], numbers[4], numbers[5], outputs, bitpos);
		encode_quints(bits, numbers[6], numbers[7], numbers[8], outputs, bitpos);
		encode_quints(bits, numbers[9], numbers[10], numbers[11], outputs, bitpos);
		encode_quints(bits, numbers[12], numbers[13], numbers[14], outputs, bitpos);
		encode_quints(bits, numbers[15], 0, 0, outputs, bitpos);
		bitpos = ((7 + 3 * bits) * 16 + 2) / 3;
	}
	else
	{
		for (int i = 0; i < 16; ++i)
		{
			orbits8_ptr(outputs, bitpos, numbers[i], bits);
		}
	}

}

