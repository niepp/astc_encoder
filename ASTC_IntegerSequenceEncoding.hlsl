 /**
  * Table that describes the number of trits or quints along with bits required
  * for storing each range.
  */
static const uint bits_trits_quints_table[QUANT_MAX * 3] =
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

/**
 * Compute the number of bits required to store a number of items in a specific
 * range using the bounded integer sequence encoding.
 */
uint compute_ise_bitcount(uint items, uint range)
{
	int bits = bits_trits_quints_table[range * 3 + 0];
	int trits = bits_trits_quints_table[range * 3 + 1];
	int quints = bits_trits_quints_table[range * 3 + 2];

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

// 取第lsb到msb的这几个bit位的值
uint getbits(uint number, uint msb, uint lsb)
{
	uint count = msb - lsb + 1;
	return (number >> lsb) & ((1 << count) - 1);
}


void split_high_low(uint n, uint i, out uint high, out uint low)
{
	uint low_mask = ((1 << i) - 1);
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

// 把number的低bitcount位写到bytes的bitpos偏移处开始的位置
// number must be <= 255; bitcount must be <= 8
void orbits8_ptr(uint number, uint bitcount, inout uint bytes[16], inout uint bitpos)
{
	uint idx = bitpos / 8;
	uint offset = bitpos % 8;
	uint mask = (number << offset);
	bytes[idx] |= mask & 0xFF;
	bytes[idx + 1] |= (mask >> 8) & 0xFF;
	bitpos += bitcount;
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
	inout uint outputs[16], inout uint outpos)
{
	uint t0, t1, t2, t3, t4;
	uint m0, m1, m2, m3, m4;

	split_high_low(b0, bitcount, t0, m0);
	split_high_low(b1, bitcount, t1, m1);
	split_high_low(b2, bitcount, t2, m2);
	split_high_low(b3, bitcount, t3, m3);
	split_high_low(b4, bitcount, t4, m4);

	uint packhigh = integer_from_trits[t4][t3][t2][t1][t0];

	orbits8_ptr(m0, bitcount, outputs, outpos);
	
	orbits8_ptr(packhigh & 3, 2, outputs, outpos);

	orbits8_ptr(m1, bitcount, outputs, outpos);
	orbits8_ptr((packhigh >> 2) & 3, 2, outputs, outpos);

	orbits8_ptr(m2, bitcount, outputs, outpos);
	orbits8_ptr((packhigh >> 4) & 1, 1, outputs, outpos);

	orbits8_ptr(m3, bitcount, outputs, outpos);
	orbits8_ptr((packhigh >> 5) & 3, 2, outputs, outpos);

	orbits8_ptr(m4, bitcount, outputs, outpos);
	orbits8_ptr((packhigh >> 7) & 1, 1, outputs, outpos);

}

/**
 * Encode a group of 3 numbers using quints and bits.
 */
void encode_quints(uint bitcount,
	uint b0,
	uint b1,
	uint b2,
	inout uint outputs[16], inout uint outpos)
{
	uint q0, q1, q2;
	uint m0, m1, m2;

	split_high_low(b0, bitcount, q0, m0);
	split_high_low(b1, bitcount, q1, m1);
	split_high_low(b2, bitcount, q2, m2);

	uint packhigh = integer_from_quints[q2][q1][q0];

	orbits8_ptr(m0, bitcount, outputs, outpos);
	orbits8_ptr(packhigh & 7, 3, outputs, outpos);

	orbits8_ptr(m1, bitcount, outputs, outpos);
	orbits8_ptr((packhigh >> 3) & 3, 2, outputs, outpos);

	orbits8_ptr(m2, bitcount, outputs, outpos);
	orbits8_ptr((packhigh >> 5) & 3, 2, outputs, outpos);

}

void bise_endpoints(uint numbers[8], uint hasalpha, uint range, inout uint outputs[16], inout uint bitpos)
{
	uint bits = bits_trits_quints_table[range * 3 + 0];
	uint trits = bits_trits_quints_table[range * 3 + 1];
	uint quints = bits_trits_quints_table[range * 3 + 2];

	if (trits == 1)
	{
		bitpos = 0;
		uint b0 = numbers[0];
		uint b1 = numbers[1];
		uint b2 = numbers[2];
		uint b3 = numbers[3];
		uint b4 = numbers[4];
		encode_trits(bits, b0, b1, b2, b3, b4, outputs, bitpos);

		b0 = numbers[5];
		b1 = (hasalpha > 0) ? numbers[6] : 0;
		b2 = (hasalpha > 0) ? numbers[7] : 0;
		encode_trits(bits, b0, b1, b2, 0, 0, outputs, bitpos);

		bitpos = ((8 + 5 * bits) * 8 + 4) / 5;

	}
	else if (quints == 1)
	{
		bitpos = 0;
		uint b0 = numbers[0];
		uint b1 = numbers[1];
		uint b2 = numbers[2];
		encode_quints(bits, b0, b1, b2, outputs, bitpos);

		b0 = numbers[3];
		b1 = numbers[4];
		b2 = numbers[5];
		encode_quints(bits, b0, b1, b2, outputs, bitpos);

		b1 = (hasalpha > 0) ? numbers[6] : 0;
		b2 = (hasalpha > 0) ? numbers[7] : 0;
		encode_quints(bits, b0, b1, 0, outputs, bitpos);

		bitpos = ((7 + 3 * bits) * 8 + 2) / 3;

	}
	else
	{
		bitpos = 0;	
		for (int i = 0; i < 8; ++i)
		{
			uint idx = bitpos / 8;
			uint offset = bitpos % 8;
			uint mask = (numbers[i] << offset);
			outputs[idx] |= mask & 0xFF;
			outputs[idx + 1] |= (mask >> 8) & 0xFF;
			bitpos += bits;
		}
	}

}

void bise_weights(uint numbers[16], uint range, inout uint outputs[16], inout uint bitpos)
{
	int bits = bits_trits_quints_table[range * 3 + 0];
	int trits = bits_trits_quints_table[range * 3 + 1];
	int quints = bits_trits_quints_table[range * 3 + 2];

	if (trits == 1)
	{
		bitpos = 0;
		uint b0 = numbers[0];
		uint b1 = numbers[1];
		uint b2 = numbers[2];
		uint b3 = numbers[3];
		uint b4 = numbers[4];
		encode_trits(bits, b0, b1, b2, b3, b4, outputs, bitpos);

		b0 = numbers[5];
		b1 = numbers[6];
		b2 = numbers[7];
		b3 = numbers[8];
		b4 = numbers[9];
		encode_trits(bits, b0, b1, b2, b3, b4, outputs, bitpos);

		b0 = numbers[10];
		b1 = numbers[11];
		b2 = numbers[12];
		b3 = numbers[13];
		b4 = numbers[14];
		encode_trits(bits, b0, b1, b2, b3, b4, outputs, bitpos);

		b0 = numbers[15];
		encode_trits(bits, b0, 0, 0, 0, 0, outputs, bitpos);

		bitpos = ((8 + 5 * bits) * 16 + 4) / 5;
	}
	else if (quints == 1)
	{
		bitpos = 0;
		uint b0 = numbers[0];
		uint b1 = numbers[1];
		uint b2 = numbers[2];
		encode_quints(bits, b0, b1, b2, outputs, bitpos);

		b0 = numbers[3];
		b1 = numbers[4];
		b2 = numbers[5];
		encode_quints(bits, b0, b1, b2, outputs, bitpos);

		b0 = numbers[6];
		b1 = numbers[7];
		b2 = numbers[8];
		encode_quints(bits, b0, b1, b2, outputs, bitpos);

		b0 = numbers[9];
		b1 = numbers[10];
		b2 = numbers[11];
		encode_quints(bits, b0, b1, b2, outputs, bitpos);

		b0 = numbers[12];
		b1 = numbers[13];
		b2 = numbers[14];
		encode_quints(bits, b0, b1, b2, outputs, bitpos);

		b0 = numbers[15];
		encode_quints(bits, b0, 0, 0, outputs, bitpos);

		bitpos = ((7 + 3 * bits) * 16 + 2) / 3;

	}
	else
	{
		bitpos = 0;
		for (int i = 0; i < 16; ++i)
		{
			uint idx = bitpos / 8;
			uint offset = bitpos % 8;
			uint mask = (numbers[i] << offset);
			outputs[idx] |= mask & 0xFF;
			outputs[idx + 1] |= (mask >> 8) & 0xFF;
			bitpos += bits;
		}

	}

}

