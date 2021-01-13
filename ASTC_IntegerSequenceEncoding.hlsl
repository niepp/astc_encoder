/**
 * Compute the number of bits required to store a number of items in a specific
 * range using the bounded integer sequence encoding.
 */
uint compute_ise_bitcount(uint items, uint range)
{
	uint bits = bits_trits_quints_table[range][0];
	uint trits = bits_trits_quints_table[range][1];
	uint quints = bits_trits_quints_table[range][2];

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

// 取第n个bit位的值
uint getbit(uint number, uint n)
{
	return (number >> n) & 1;
}

// 取第lsb到msb的这几个bit位的值
uint getbits(uint number, uint msb, uint lsb)
{
	uint count = msb - lsb + 1;
	return (number >> lsb) & ((1 << count) - 1);
}

// 把number的低bitcount位写到bytes的bitoffset偏移处开始的位置
// number must be <= 255; bitcount must be <= 8
uint4 orbits8_ptr(uint4 bytes, uint bitoffset, uint number, uint bitcount)
{
	uint4 retv = bytes;
	bitcount = bitcount > 8 ? 8 : bitcount;
	number &= (1 << bitcount) - 1;

	uint newpos = bitoffset + bitcount;
	if (bitoffset < 32)
	{
		uint lowpart = bitoffset > 0 ? number & ((1 << (32 - bitoffset)) - 1) : number;
		retv.x = bytes.x | (lowpart << bitoffset);

		uint highpart = newpos > 32 ? number >> (32 - bitoffset) : 0;
		retv.y = bytes.y | highpart;
	}
	else if (bitoffset < 64)
	{
		uint lowpart = bitoffset > 32 ? number & ((1 << (64 - bitoffset)) - 1) : number;
		retv.y = bytes.y | (lowpart << (bitoffset - 32));

		uint highpart = newpos > 64 ? number >> (64 - bitoffset) : 0;
		retv.z = bytes.z | highpart;
	}
	else if (bitoffset < 96)
	{
		uint lowpart = bitoffset > 64 ? number & ((1 << (96 - bitoffset)) - 1) : number;
		retv.z = bytes.z | (lowpart << (bitoffset - 64));

		uint highpart = newpos > 96 ? number >> (96 - bitoffset) : 0;
		retv.w = bytes.w | highpart;
	}
	else
	{
		uint lowpart = bitoffset > 96 ? number & ((1 << (128 - bitoffset)) - 1) : number;
		retv.w = bytes.w | (lowpart << (bitoffset - 96));
	}

	return retv;
}

void split_high_low(uint n, uint i, out uint high, out uint low)
{
	uint low_mask = (uint)((1 << i) - 1) & 0xFF;
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


void copy_bytes(uint4 source, uint bytecount, inout uint4 target, inout uint bitoffset)
{
	uint4 outbytes = target;
	uint src_bytes[16];
	uint4_2_array16(source, src_bytes);
	for (uint i = 0; i < bytecount; ++i)
	{
		outbytes = orbits8_ptr(outbytes, bitoffset + i * 8, src_bytes[i], 8);
	}
	target = outbytes;
	bitoffset += bytecount * 8;
}

//void write8(inout uint4 outputs, inout uint bitoffset, uint number, uint bitcount)
//{
//	orbits8_ptr(outputs, bitoffset, number, bitcount);
//	bitoffset += bitcount;
//}

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
	uint t0, t1, t2, t3, t4;
	uint m0, m1, m2, m3, m4;

	split_high_low(b0, bitcount, t0, m0);
	split_high_low(b1, bitcount, t1, m1);
	split_high_low(b2, bitcount, t2, m2);
	split_high_low(b3, bitcount, t3, m3);
	split_high_low(b4, bitcount, t4, m4);

	uint packed = integer_from_trits[t4][t3][t2][t1][t0];

	outputs = orbits8_ptr(outputs, outpos, m0, bitcount);
	outpos += bitcount;

	outputs = orbits8_ptr(outputs, outpos, getbits(packed, 1, 0), 2);
	outpos += 2;

	outputs = orbits8_ptr(outputs, outpos, m1, bitcount);
	outpos += bitcount;

	outputs = orbits8_ptr(outputs, outpos, getbits(packed, 3, 2), 2);
	outpos += 2;

	outputs = orbits8_ptr(outputs, outpos, m2, bitcount);
	outpos += bitcount;

	outputs = orbits8_ptr(outputs, outpos, getbits(packed, 4, 4), 1);
	outpos += 1;

	outputs = orbits8_ptr(outputs, outpos, m3, bitcount);
	outpos += bitcount;

	outputs = orbits8_ptr(outputs, outpos, getbits(packed, 6, 5), 2);
	outpos += 2;

	outputs = orbits8_ptr(outputs, outpos, m4, bitcount);
	outpos += bitcount;

	outputs = orbits8_ptr(outputs, outpos, getbits(packed, 7, 7), 1);
	outpos += 1;

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
	uint q0, q1, q2;
	uint m0, m1, m2;

	split_high_low(b0, bitcount, q0, m0);
	split_high_low(b1, bitcount, q1, m1);
	split_high_low(b2, bitcount, q2, m2);

	uint packed = integer_from_quints[q2][q1][q0];

	outputs = orbits8_ptr(outputs, outpos, m0, bitcount);
	outpos += bitcount;

	outputs = orbits8_ptr(outputs, outpos, getbits(packed, 2, 0), 3);
	outpos += 3;

	outputs = orbits8_ptr(outputs, outpos, m1, bitcount);
	outpos += bitcount;

	outputs = orbits8_ptr(outputs, outpos, getbits(packed, 4, 3), 2);
	outpos += 2;

	outputs = orbits8_ptr(outputs, outpos, m2, bitcount);
	outpos += bitcount;

	outputs = orbits8_ptr(outputs, outpos, getbits(packed, 6, 5), 2);
	outpos += 2;

}

/**
 * Encode a sequence of numbers using using one trit and a custom number of
 * bits per number.
 */
void encode_by_trits(uint numbers[ISE_BYTE_COUNT], uint numcount, uint bitcount, out uint4 outputs, out uint bitoffset)
{
	uint4 outbytes = 0;
	uint bitpos = 0;
	for (uint i = 0; i < numcount; i += 5)
	{
		uint b0 = numbers[i + 0];
		uint b1 = i + 1 >= numcount ? 0 : numbers[i + 1];
		uint b2 = i + 2 >= numcount ? 0 : numbers[i + 2];
		uint b3 = i + 3 >= numcount ? 0 : numbers[i + 3];
		uint b4 = i + 4 >= numcount ? 0 : numbers[i + 4];
		encode_trits(bitcount, b0, b1, b2, b3, b4, outbytes, bitpos);
	}
	outputs = outbytes;
	bitoffset = bitpos;
}

/**
 * Encode a sequence of numbers using one quint and the custom number of bits
 * per number.
 */
void encode_by_quints(uint numbers[ISE_BYTE_COUNT], uint numcount, uint bitcount, out uint4 outputs, out uint bitoffset)
{
	uint4 outbytes = 0;
	uint bitpos = 0;
	for (uint i = 0; i < numcount; i += 3)
	{
		uint b0 = numbers[i + 0];
		uint b1 = i + 1 >= numcount ? 0 : numbers[i + 1];
		uint b2 = i + 2 >= numcount ? 0 : numbers[i + 2];
		encode_quints(bitcount, b0, b1, b2, outbytes, bitpos);
	}
	outputs = outbytes;
	bitoffset = bitpos;
}

/**
 * Encode a sequence of numbers using binary representation with the selected
 * bit count.
 */
inline void encode_by_binary(uint numbers[ISE_BYTE_COUNT], uint numcount, uint bitcount, out uint4 outputs, out uint bitoffset)
{
	uint4 outbytes = uint4(0, 0, 0, 0);
	uint bitpos = 0;
	for (uint i = 0; i < numcount && i < ISE_BYTE_COUNT; ++i)
	{
		outbytes = orbits8_ptr(outbytes, bitpos, numbers[i], bitcount);
		bitpos += bitcount;
	}
	outputs = outbytes;
	bitoffset = bitpos;
}

void integer_sequence_encode(uint numbers[ISE_BYTE_COUNT], uint count, uint range, out uint4 outputs, out uint bitpos)
{
	uint bits = bits_trits_quints_table[range][0];
	uint trits = bits_trits_quints_table[range][1];
	uint quints = bits_trits_quints_table[range][2];

	if (trits == 1)
	{
		encode_by_trits(numbers, count, bits, outputs, bitpos);
	}
	else if (quints == 1)
	{
		encode_by_quints(numbers, count, bits, outputs, bitpos);
	}
	else
	{
		encode_by_binary(numbers, count, bits, outputs, bitpos);
	}

}
