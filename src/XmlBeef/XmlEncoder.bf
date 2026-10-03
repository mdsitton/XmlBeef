using System;
using System.Collections;
using FormatCore;
using internal FormatCore;

namespace XmlBeef;

/// Encodes UTF-8 text into a document encoding, for XmlDocument.WriteBytes: the reverse of XmlDecoder.
internal static class XmlEncoder
{
	/// Appends `text` (valid UTF-8) to `output` in `encoding`.
	/// @return The offset in `text` of the first character the encoding cannot hold, or -1.
	public static int Encode(StringView text, XmlEncoding encoding, List<uint8> output)
	{
		if (encoding == .Utf8)
		{
			output.AddRange(Span<uint8>((uint8*)text.Ptr, text.Length));
			return -1;
		}
		if (encoding == .Custom)
			return text.IsEmpty ? -1 : 0;
		uint16* table = XmlEncodingTables.Get(encoding);
		int i = 0;
		while (i < text.Length)
		{
			uint8 b = (uint8)text[i];
			char32 cp;
			int length;
			if (b < 0x80)
			{
				cp = (char32)b;
				length = 1;
			}
			else
				cp = Utf8.Decode(text.Ptr, i, out length);
			uint32 c = (uint32)cp;
			switch (encoding)
			{
			case .Utf16LE, .Utf16BE:
				if (c >= 0x10000)
				{
					uint32 v = c - 0x10000;
					Put16(output, 0xD800 | (v >> 10), encoding == .Utf16BE);
					Put16(output, 0xDC00 | (v & 0x3FF), encoding == .Utf16BE);
				}
				else
					Put16(output, c, encoding == .Utf16BE);
			case .Utf32LE, .Utf32BE:
				if (encoding == .Utf32BE)
				{
					output.Add((uint8)(c >> 24));
					output.Add((uint8)(c >> 16));
					output.Add((uint8)(c >> 8));
					output.Add((uint8)c);
				}
				else
				{
					output.Add((uint8)c);
					output.Add((uint8)(c >> 8));
					output.Add((uint8)(c >> 16));
					output.Add((uint8)(c >> 24));
				}
			case .Ascii:
				if (c >= 0x80)
					return i;
				output.Add((uint8)c);
			default:
				// Latin-1 (no table: bytes are code points) and the single-byte tables
				if (c < 0x80)
					output.Add((uint8)c);
				else if (table == null)
				{
					if (c > 0xFF)
						return i;
					output.Add((uint8)c);
				}
				else
				{
					int index = -1;
					for (int k < 128)
					{
						if (table[k] == c)
						{
							index = k;
							break;
						}
					}
					if (index < 0)
						return i;
					output.Add((uint8)(0x80 + index));
				}
			}
			i += length;
		}
		return -1;
	}

	/// Whether `encoding` can hold the character `c`.
	public static bool CanEncode(char32 c, XmlEncoding encoding)
	{
		uint32 cp = (uint32)c;
		if (cp < 0x80)
			return encoding != .Custom;
		switch (encoding)
		{
		case .Utf8, .Utf16LE, .Utf16BE, .Utf32LE, .Utf32BE:
			return true;
		case .Ascii, .Custom:
			return false;
		default:
			uint16* table = XmlEncodingTables.Get(encoding);
			if (table == null)
				return cp <= 0xFF;
			for (int k < 128)
			{
				if (table[k] == cp)
					return true;
			}
			return false;
		}
	}

	static void Put16(List<uint8> output, uint32 unit, bool bigEndian)
	{
		if (bigEndian)
		{
			output.Add((uint8)(unit >> 8));
			output.Add((uint8)unit);
		}
		else
		{
			output.Add((uint8)unit);
			output.Add((uint8)(unit >> 8));
		}
	}
}
