using System;
using internal XmlBeef;

namespace XmlBeef;

/// Character classification and UTF-8 helpers for the XML reader and writers.
///
/// The reader sees only UTF-8 that `FindInvalid` has checked (transcoded first when the document is in
/// another encoding), so its scanners look only for their own stop bytes: every code point outside
/// XML's `Char` production has been rejected before.
internal static class XmlChar
{
	/// Byte classes for name scanning: 0 ends a name, 1 is an ASCII NameStartChar (`:` `_` letters),
	/// 2 an ASCII NameChar that cannot start a name (`-` `.` digits), 3 a non-ASCII byte (decode the
	/// code point and test its ranges).
	public const uint8 cNameStop = 0;
	public const uint8 cNameStart = 1;
	public const uint8 cNameOnly = 2;
	public const uint8 cNameDecode = 3;

	static uint8[256] sNameByte = BuildNameByte();

	static uint8[256] BuildNameByte()
	{
		uint8[256] table = default;
		for (int i < 256)
		{
			char8 c = (char8)i;
			if (i >= 0x80)
				table[i] = cNameDecode;
			else if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' || c == ':')
				table[i] = cNameStart;
			else if ((c >= '0' && c <= '9') || c == '-' || c == '.')
				table[i] = cNameOnly;
		}
		return table;
	}

	/// @return The name class of byte `c` (cNameStop, cNameStart, cNameOnly or cNameDecode).
	[Inline]
	public static uint8 NameByteClass(char8 c)
	{
		return sNameByte[(uint8)c];
	}

	/// @brief Whether `cp` is a NameStartChar ([4], Fifth Edition ranges).
	public static bool IsNameStartChar(char32 cp)
	{
		uint32 c = (uint32)cp;
		if (c < 0x80)
			return sNameByte[c] == cNameStart;
		if (c < 0x300)
			return c >= 0xC0 && c != 0xD7 && c != 0xF7;
		if (c < 0x2000)
			return (c >= 0x370 && c <= 0x37D) || c >= 0x37F;
		if (c < 0x3001)
			return c == 0x200C || c == 0x200D || (c >= 0x2070 && c <= 0x218F) || (c >= 0x2C00 && c <= 0x2FEF);
		if (c <= 0xD7FF)
			return true;
		if (c < 0x10000)
			return (c >= 0xF900 && c <= 0xFDCF) || (c >= 0xFDF0 && c <= 0xFFFD);
		return c <= 0xEFFFF;
	}

	/// @brief Whether `cp` is a NameChar ([4a]).
	public static bool IsNameChar(char32 cp)
	{
		uint32 c = (uint32)cp;
		if (c < 0x80)
			return sNameByte[c] == cNameStart || sNameByte[c] == cNameOnly;
		if (IsNameStartChar(cp))
			return true;
		return c == 0xB7 || (c >= 0x300 && c <= 0x36F) || c == 0x203F || c == 0x2040;
	}

	/// @brief Whether `cp` matches `Char` ([2]): TAB, LF, CR, U+0020-D7FF, U+E000-FFFD, U+10000-10FFFF.
	public static bool IsChar(uint32 c)
	{
		if (c < 0x20)
			return c == 0x09 || c == 0x0A || c == 0x0D;
		if (c <= 0xD7FF)
			return true;
		if (c < 0xE000)
			return false;
		if (c <= 0xFFFD)
			return true;
		return c >= 0x10000 && c <= 0x10FFFF;
	}

	/// @brief Whether `a[0 ..< length]` equals `b[0 ..< length]`: word compares (overlapping at the
	/// end), no call; for the short names of end tags and the name table.
	[Inline]
	public static bool EqualBytes(char8* a, char8* b, int length)
	{
		if (length >= 8)
		{
			int i = 0;
			while (i + 8 < length)
			{
				if (Load64(a + i) != Load64(b + i))
					return false;
				i += 8;
			}
			return Load64(a + length - 8) == Load64(b + length - 8);
		}
		if (length >= 4)
			return Load32(a) == Load32(b) && Load32(a + length - 4) == Load32(b + length - 4);
		for (int i < length)
		{
			if (a[i] != b[i])
				return false;
		}
		return true;
	}

	[Inline]
	public static uint64 Load64(char8* p)
	{
		uint64 word = ?;
		Internal.MemCpy(&word, p, 8);
		return word;
	}

	[Inline]
	public static uint32 Load32(char8* p)
	{
		uint32 word = ?;
		Internal.MemCpy(&word, p, 4);
		return word;
	}

	/// @brief The high bit of each byte of `word` that equals `c`, exactly.
	[Inline]
	public static uint64 BytesEqual(uint64 word, uint8 c)
	{
		return ZeroBytes(word ^ ((uint64)c * 0x0101010101010101UL));
	}

	/// @brief The high bit of each byte of `word` below 0x20, exactly (bytes ≥ 0x80 excepted).
	[Inline]
	public static uint64 BytesBelowSpace(uint64 word)
	{
		const uint64 high = 0x8080808080808080UL;
		// Adding 0x60 to a byte below 0x80 sets its high bit when it is at least 0x20
		return ~((word & ~high) + 0x6060606060606060UL) & ~word & high;
	}

	/// @brief Whether `c` is XML whitespace (`S`, [3]): space, tab, LF or CR.
	[Inline]
	public static bool IsSpace(char8 c)
	{
		return c == ' ' || c == '\n' || c == '\t' || c == '\r';
	}

	/// @brief Whether `c` is a PubidChar ([13]).
	public static bool IsPubidChar(char8 c)
	{
		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
			return true;
		switch (c)
		{
		case ' ', '\r', '\n', '-', '\'', '(', ')', '+', ',', '.', '/', ':', '=', '?', ';', '!', '*', '#', '@', '$', '_', '%':
			return true;
		default:
			return false;
		}
	}

	/// @brief Return the byte length of a UTF-8 sequence starting with the given lead byte.
	/// @param leadChar The lead byte of the sequence.
	/// @return 1-4 for valid lead bytes, 0 for continuation/invalid bytes.
	[Inline]
	public static int Utf8SequenceLength(char8 leadChar)
	{
		uint8 lead = (uint8)leadChar;
		if (lead < 0x80) return 1;
		if ((lead & 0xE0) == 0xC0) return 2;
		if ((lead & 0xF0) == 0xE0) return 3;
		if ((lead & 0xF8) == 0xF0) return 4;
		return 0;
	}

	/// @brief Decode the code point at `text[pos]` from input already checked as UTF-8.
	/// @param text The bytes.
	/// @param pos Byte offset of the lead byte.
	/// @param length Receives the sequence length in bytes.
	/// @return The decoded code point.
	public static char32 Decode(char8* text, int pos, out int length)
	{
		uint8* data = (uint8*)text;
		uint8 b0 = data[pos];
		if (b0 < 0x80)
		{
			length = 1;
			return (char32)b0;
		}
		length = Utf8SequenceLength((char8)b0);
		switch (length)
		{
		case 2:
			return (char32)(((uint32)(b0 & 0x1F) << 6) | (uint32)(data[pos + 1] & 0x3F));
		case 3:
			return (char32)(((uint32)(b0 & 0x0F) << 12) | ((uint32)(data[pos + 1] & 0x3F) << 6) | (uint32)(data[pos + 2] & 0x3F));
		case 4:
			return (char32)(((uint32)(b0 & 0x07) << 18) | ((uint32)(data[pos + 1] & 0x3F) << 12) |
				((uint32)(data[pos + 2] & 0x3F) << 6) | (uint32)(data[pos + 3] & 0x3F));
		default:
			length = 1;
			return (char32)0xFFFD;
		}
	}

	/// @brief Encode a Unicode code point as UTF-8 and append to a String.
	/// @param result The destination string.
	/// @param cp The code point to encode (must be 0–0x10FFFF, excluding surrogates).
	public static void EncodeUtf8(String result, uint32 cp)
	{
		if (cp < 0x80)
		{
			result.Append((char8)cp);
		}
		else if (cp < 0x800)
		{
			result.Append((char8)(0xC0 | (cp >> 6)));
			result.Append((char8)(0x80 | (cp & 0x3F)));
		}
		else if (cp < 0x10000)
		{
			result.Append((char8)(0xE0 | (cp >> 12)));
			result.Append((char8)(0x80 | ((cp >> 6) & 0x3F)));
			result.Append((char8)(0x80 | (cp & 0x3F)));
		}
		else
		{
			result.Append((char8)(0xF0 | (cp >> 18)));
			result.Append((char8)(0x80 | ((cp >> 12) & 0x3F)));
			result.Append((char8)(0x80 | ((cp >> 6) & 0x3F)));
			result.Append((char8)(0x80 | (cp & 0x3F)));
		}
	}

	/// @brief Convert a hex digit character to its numeric value.
	/// @param c The hex digit character.
	/// @return 0–15 on success, or 255 if not a hex digit.
	[Inline]
	public static uint8 HexDigitValue(char8 c)
	{
		uint32 ci = (uint8)c;
		uint32 result = ci - (uint32)'0';
		if (result <= 9)
			return (uint8)result;
		// Convert uppercase to lowercase: 'A'|0x20 == 'a'
		result = (ci | 0x20) - (uint32)'a';
		if (result <= 5)
			return (uint8)(result + 10);
		return 255;
	}

	/// @brief Whether the input starts with a UTF-8 byte order mark.
	/// @param data The input.
	/// @param length The bytes available (a BOM needs 3).
	/// @return Whether it does.
	public static bool StartsWithBom(char8* data, int length)
	{
		return length >= 3 && (uint8)data[0] == 0xEF && (uint8)data[1] == 0xBB && (uint8)data[2] == 0xBF;
	}

	/// @brief Find the first ill-formed UTF-8 sequence or code point outside `Char` in
	/// `text[from ..< to]`. A sequence cut by `to` is an error: streams pass only complete sequences
	/// (`CompleteSequencesEnd`) until their input ends.
	/// @param text The input.
	/// @param from The first byte to check (after any BOM).
	/// @param to The end of the range.
	/// @param message Receives the error message.
	/// @param kind Receives the error kind.
	/// @param length Receives the length of the offending bytes.
	/// @return The offset of the first error, or -1.
	public static int FindInvalid(char8* text, int from, int to, String message, out XmlErrorKind kind, out int length)
	{
		uint8* data = (uint8*)text;
		kind = .InvalidEncoding;
		length = 1;
		int i = from;
		while (i < to)
		{
			// 32 bytes of printable ASCII at once, then words of ASCII without control characters other
			// than tab, LF and CR: neither needs further checks
			if (i + 32 <= to && IsPrintableAscii32(data + i))
			{
				i += 32;
				continue;
			}
			if (i + 8 <= to && IsPlainAsciiWord(data + i))
			{
				i += 8;
				continue;
			}
			int limit = Math.Min(i + 8, to);
			while (i < limit)
			{
				uint8 b = data[i];
				if (b >= 0x20 && b < 0x80)
				{
					i++;
					continue;
				}
				if (b < 0x80)
				{
					if (b != 0x09 && b != 0x0A && b != 0x0D)
					{
						kind = .InvalidChar;
						AppendNotCharMessage(message, b);
						return i;
					}
					i++;
					continue;
				}
				int seqLen = Utf8SequenceLength((char8)b);
				if (seqLen == 0)
				{
					message.Append("Invalid UTF-8 lead byte");
					return i;
				}
				if (i + seqLen > to)
				{
					message.Append("Truncated UTF-8 sequence");
					return i;
				}
				for (int j = 1; j < seqLen; j++)
				{
					if ((data[i + j] & 0xC0) != 0x80)
					{
						message.Append("Invalid UTF-8 continuation byte");
						return i + j;
					}
				}
				uint32 cp = (uint32)Decode(text, i, var decodedLength);
				if (seqLen == 2 ? cp < 0x80 : seqLen == 3 ? cp < 0x800 : cp < 0x10000)
				{
					message.Append("Overlong UTF-8 sequence");
					return i;
				}
				if (cp >= 0xD800 && cp <= 0xDFFF)
				{
					message.Append("UTF-8-encoded surrogate");
					return i;
				}
				if (cp > 0x10FFFF)
				{
					message.Append("Code point beyond U+10FFFF");
					return i;
				}
				if (cp == 0xFFFE || cp == 0xFFFF)
				{
					kind = .InvalidChar;
					length = seqLen;
					AppendNotCharMessage(message, cp);
					return i;
				}
				i += seqLen;
			}
		}
		return -1;
	}

	/// @brief The end of the complete UTF-8 sequences in `text[from ..< to]`: `to`, or the start of a
	/// sequence cut off by `to` (a stream validates it once the rest arrives).
	/// @param text The input.
	/// @param from The start of the range.
	/// @param to The end of the range.
	/// @return The end of the complete sequences.
	public static int CompleteSequencesEnd(char8* text, int from, int to)
	{
		for (int back = 1; back <= 3; back++)
		{
			int p = to - back;
			if (p < from)
				break;
			uint8 b = (uint8)text[p];
			if ((b & 0xC0) == 0x80)
				continue;
			// A lead byte (or ASCII): cut if its sequence runs past `to`; invalid bytes are FindInvalid's
			int seqLen = Utf8SequenceLength((char8)b);
			return (seqLen > 0 && p + seqLen > to) ? p : to;
		}
		return to;
	}

	/// Whether the 32 bytes at `p` are all ASCII with no control characters but tab, LF and CR: exact
	/// per byte, as below. Lines of text hold an LF every few dozen bytes, so the controls are checked
	/// only when a byte below 0x20 is present.
	[Inline]
	static bool IsPrintableAscii32(uint8* p)
	{
		const uint64 high = 0x8080808080808080UL;
		const uint64 add = 0x6060606060606060UL;
		uint64 a = Load64((char8*)p);
		uint64 b = Load64((char8*)p + 8);
		uint64 c = Load64((char8*)p + 16);
		uint64 d = Load64((char8*)p + 24);
		if (((a | b | c | d) & high) != 0)
			return false;
		if (((a + add) & (b + add) & (c + add) & (d + add) & high) == high)
			return true;
		return (BadControls(a) | BadControls(b) | BadControls(c) | BadControls(d)) == 0;
	}

	/// The high bit of each byte of an ASCII word that is a control character other than tab, LF and CR.
	[Inline]
	static uint64 BadControls(uint64 word)
	{
		return BytesBelowSpace(word) & ~(BytesEqual(word, 0x09) | BytesEqual(word, 0x0A) | BytesEqual(word, 0x0D));
	}

	/// Whether the 8 bytes at `p` are ASCII other than the control characters, tab, LF and CR excepted.
	/// Every test is exact per byte: once the high bits are known to be clear, adding to a byte cannot
	/// carry into the next one.
	[Inline]
	static bool IsPlainAsciiWord(uint8* p)
	{
		const uint64 ones = 0x0101010101010101UL;
		const uint64 high = 0x8080808080808080UL;
		uint64 word = ?;
		Internal.MemCpy(&word, p, 8);
		if ((word & high) != 0)
			return false;
		// High bit set for bytes >= 0x20
		uint64 printable = (word + 0x60 * ones) & high;
		if (printable == high)
			return true;
		uint64 control = ~printable & high;
		uint64 allowed = ZeroBytes(word ^ (0x09 * ones)) | ZeroBytes(word ^ (0x0A * ones)) | ZeroBytes(word ^ (0x0D * ones));
		return (control & ~allowed) == 0;
	}

	/// Nonzero when `word` has a byte below 0x0E (exact as to whether there is one).
	[Inline]
	public static uint64 BytesBelow0E(uint64 word)
	{
		return (word - 0x0E0E0E0E0E0E0E0EUL) & ~word & 0x8080808080808080UL;
	}

	/// The number of code points in `text[from ..< to]`: its bytes that are not UTF-8 continuation bytes
	/// (10xxxxxx), counted 8 at a time.
	public static int CountCodePoints(char8* text, int from, int to)
	{
		const uint64 high = 0x8080808080808080UL;
		int count = 0;
		int p = from;
		while (p + 8 <= to)
		{
			uint64 word = Load64(text + p);
			uint64 continuation = word & ~(word << 1) & high;
			count += continuation == 0 ? 8 : 8 - CountHighBits(continuation);
			p += 8;
		}
		while (p < to)
		{
			if (((uint8)text[p] & 0xC0) != 0x80)
				count++;
			p++;
		}
		return count;
	}

	/// The number of bytes of `mask` whose high bit is set (no other bits may be).
	[Inline]
	public static int CountHighBits(uint64 mask)
	{
		return (int)(((mask >> 7) * 0x0101010101010101UL) >> 56);
	}

	/// The high bit of each zero byte of `x`, exactly.
	[Inline]
	public static uint64 ZeroBytes(uint64 x)
	{
		const uint64 low7 = 0x7F7F7F7F7F7F7F7FUL;
		return ~(((x & low7) + low7) | x | low7);
	}

	static void AppendNotCharMessage(String message, uint32 cp)
	{
		message.Append("The code point ");
		AppendCodePointName(message, cp);
		message.Append(" is not allowed in XML (it is not a `Char`)");
	}

	/// @brief Append `U+XXXX` (at least four uppercase hex digits).
	/// @param output The string to append to.
	/// @param cp The code point.
	public static void AppendCodePointName(String output, uint32 cp)
	{
		output.Append("U+");
		AppendHex(output, cp, 4);
	}

	/// @brief Append `value` in uppercase hex with at least `minDigits` digits.
	/// @param output The string to append to.
	/// @param value The value.
	/// @param minDigits The minimum number of digits (zero-padded).
	public static void AppendHex(String output, uint32 value, int minDigits)
	{
		int digits = 1;
		while (digits < 8 && (value >> (4 * digits)) != 0)
			digits++;
		digits = Math.Max(digits, minDigits);
		for (int d = digits - 1; d >= 0; d--)
		{
			uint32 nibble = (value >> (4 * d)) & 0xF;
			output.Append(nibble < 10 ? (char8)('0' + nibble) : (char8)('A' + nibble - 10));
		}
	}

	/// @brief The byte length of the newline at `text[pos]`, or 0: LF, CR, or CRLF (one newline).
	[Inline]
	public static int NewlineLength(char8* text, int pos, int end)
	{
		char8 c = text[pos];
		if (c == '\n')
			return 1;
		if (c != '\r')
			return 0;
		return (pos + 1 < end && text[pos + 1] == '\n') ? 2 : 1;
	}

	/// @brief The 1-based line and column (in code points) of byte `offset`, counting LF, CR and CRLF
	/// as one newline each. A leading BOM takes no column.
	/// @param input The document.
	/// @param offset A byte offset into it.
	/// @param line Receives the line.
	/// @param column Receives the column.
	public static void LineAndColumn(StringView input, int offset, out int line, out int column)
	{
		int end = Math.Min(offset, input.Length);
		int i = StartsWithBom(input.Ptr, input.Length) ? 3 : 0;
		line = 1;
		column = 1;
		while (i < end)
		{
			int newline = NewlineLength(input.Ptr, i, input.Length);
			// An offset on the LF of a CRLF is still on the line the CRLF ends, after its CR (as
			// XmlLineCounter and the document's line index count it)
			if (i + newline > end)
			{
				column++;
				break;
			}
			if (newline > 0)
			{
				i += newline;
				line++;
				column = 1;
				continue;
			}
			i += Math.Max(Utf8SequenceLength(input[i]), 1);
			column++;
		}
	}
}
