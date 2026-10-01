using System;
using internal XmlBeef;

namespace XmlBeef;

/// @brief The encoding a document was read in.
public enum XmlEncoding : uint8
{
	/// @brief UTF-8, with or without a byte order mark (read as is, no transcoding).
	Utf8,
	/// @brief UTF-16, little-endian.
	Utf16LE,
	/// @brief UTF-16, big-endian.
	Utf16BE,
	/// @brief UTF-32 (UCS-4), little-endian.
	Utf32LE,
	/// @brief UTF-32 (UCS-4), big-endian.
	Utf32BE,
	/// @brief ISO-8859-1 (Latin-1).
	Latin1,
	/// @brief US-ASCII.
	Ascii
}

/// Encoding detection (XML 1.0 Appendix F, after the author's StrikeCore `DetectEncoding`: byte order
/// marks, UTF-7's rejection) and transcoding to UTF-8, the reader's only internal form.
///
/// The encoding comes from the byte order mark or the first four bytes, then the `encoding=` of the XML
/// declaration picks the decoder of an ASCII-compatible document. Conflicts (plan.md §9 item 6): a UTF-8
/// byte order mark wins over a declaration naming another ASCII-compatible encoding; a UTF-16 or UTF-32
/// one (or such bytes without one) with a declaration of an 8-bit encoding is an error, as is an 8-bit
/// document declaring UTF-16 or UTF-32.
internal static class XmlEncodingDetector
{
	enum Family : uint8
	{
		None,
		Unknown,
		Utf8,
		Utf16,
		Utf16LE,
		Utf16BE,
		Utf32,
		Utf32LE,
		Utf32BE,
		Latin1,
		Ascii
	}

	/// @brief Detect the encoding of `input` and make its UTF-8 text.
	/// @param input The document's bytes.
	/// @param buffer Receives the transcoded text when the document is not UTF-8.
	/// @param text Receives the UTF-8 text: `input`, or a view of `buffer`.
	/// @param start Receives the offset of the first content byte in `text` (after a UTF-8 BOM).
	/// @param encoding Receives the encoding the document was read in.
	/// @return An error for an unsupported or contradictory encoding, or bytes invalid in it.
	public static Result<void, XmlParseError> Prepare(StringView input, String buffer, out StringView text, out int start, out XmlEncoding encoding)
	{
		uint8* b = (uint8*)input.Ptr;
		int n = input.Length;
		text = input;
		start = 0;
		encoding = .Utf8;

		// Byte order marks (UTF-32's before UTF-16's: FF FE 00 00 starts like FF FE)
		if (n >= 4 && b[0] == 0x00 && b[1] == 0x00 && b[2] == 0xFE && b[3] == 0xFF)
			return Wide(input, 4, .Utf32BE, true, buffer, out text, out encoding);
		if (n >= 4 && b[0] == 0xFF && b[1] == 0xFE && b[2] == 0x00 && b[3] == 0x00)
			return Wide(input, 4, .Utf32LE, true, buffer, out text, out encoding);
		if (n >= 4 && ((b[0] == 0x00 && b[1] == 0x00 && b[2] == 0xFF && b[3] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF && b[2] == 0x00 && b[3] == 0x00)))
			return .Err(XmlParseError(.UnsupportedEncoding, "UCS-4 in the unusual byte orders 2143 and 3412 is not supported", 1, 1, 0, 4));
		if (n >= 2 && b[0] == 0xFE && b[1] == 0xFF)
			return Wide(input, 2, .Utf16BE, true, buffer, out text, out encoding);
		if (n >= 2 && b[0] == 0xFF && b[1] == 0xFE)
			return Wide(input, 2, .Utf16LE, true, buffer, out text, out encoding);
		if (n >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF)
		{
			start = 3;
			let name = DeclaredEncoding(input.Substring(3));
			let declared = Classify(name);
			if (declared == .Unknown)
				return .Err(Unsupported(input, name));
			if (IsWide(declared))
				return .Err(Mismatch(input, "UTF-8 (it starts with a UTF-8 byte order mark)", 3));
			// UTF-8, Latin-1, ASCII declared: the byte order mark wins (plan.md §9 item 6)
			return .Ok;
		}
		if (n >= 4 && b[0] == 0x2B && b[1] == 0x2F && b[2] == 0x76 && (b[3] == 0x38 || b[3] == 0x39 || b[3] == 0x2B || b[3] == 0x2F))
			return .Err(XmlParseError(.UnsupportedEncoding, "UTF-7 is not supported", 1, 1, 0, 4));

		// No byte order mark: the first four bytes of `<?xm` or `<`
		if (n >= 4)
		{
			if (b[0] == 0x00 && b[1] == 0x00 && b[2] == 0x00 && b[3] == 0x3C)
				return Wide(input, 0, .Utf32BE, false, buffer, out text, out encoding);
			if (b[0] == 0x3C && b[1] == 0x00 && b[2] == 0x00 && b[3] == 0x00)
				return Wide(input, 0, .Utf32LE, false, buffer, out text, out encoding);
			if ((b[0] == 0x00 && b[1] == 0x00 && b[2] == 0x3C && b[3] == 0x00) || (b[0] == 0x00 && b[1] == 0x3C && b[2] == 0x00 && b[3] == 0x00))
				return .Err(XmlParseError(.UnsupportedEncoding, "UCS-4 in the unusual byte orders 2143 and 3412 is not supported", 1, 1, 0, 4));
			if (b[0] == 0x00 && b[1] == 0x3C && b[2] == 0x00 && b[3] == 0x3F)
				return Wide(input, 0, .Utf16BE, false, buffer, out text, out encoding);
			if (b[0] == 0x3C && b[1] == 0x00 && b[2] == 0x3F && b[3] == 0x00)
				return Wide(input, 0, .Utf16LE, false, buffer, out text, out encoding);
			if (b[0] == 0x4C && b[1] == 0x6F && b[2] == 0xA7 && b[3] == 0x94)
				return .Err(XmlParseError(.UnsupportedEncoding, "EBCDIC encodings are not supported", 1, 1, 0, 4));
		}

		// ASCII-compatible: the declaration decides
		let name = DeclaredEncoding(input);
		switch (Classify(name))
		{
		case .None, .Utf8:
			return .Ok;
		case .Latin1:
			encoding = .Latin1;
			TranscodeLatin1(input, buffer);
			text = buffer;
			return .Ok;
		case .Ascii:
			encoding = .Ascii;
			for (int i < n)
			{
				if (b[i] >= 0x80)
					return .Err(XmlParseError.At(.InvalidEncoding, "A byte above 0x7F in a document declared US-ASCII", input.Substring(0, i), i));
			}
			return .Ok;
		case .Unknown:
			return .Err(Unsupported(input, name));
		default:
			return .Err(Mismatch(input, "an 8-bit encoding (no UTF-16 or UTF-32 byte order mark or byte pattern)", 0));
		}
	}

	/// A UTF-16 or UTF-32 document from `skip` on, transcoded into `buffer`; its declaration (if any)
	/// must name the same family.
	static Result<void, XmlParseError> Wide(StringView input, int skip, XmlEncoding wide, bool bom, String buffer, out StringView text, out XmlEncoding encoding)
	{
		text = default;
		encoding = wide;
		buffer.Clear();
		Try!(TranscodeWide(input, skip, wide, buffer));
		text = buffer;
		let declared = Classify(DeclaredEncoding(buffer));
		bool sixteen = wide == .Utf16LE || wide == .Utf16BE;
		bool ok;
		switch (declared)
		{
		case .None:
			ok = true;
		case .Utf16:
			ok = sixteen;
		case .Utf16LE:
			ok = wide == .Utf16LE;
		case .Utf16BE:
			ok = wide == .Utf16BE;
		case .Utf32:
			ok = !sixteen;
		case .Utf32LE:
			ok = wide == .Utf32LE;
		case .Utf32BE:
			ok = wide == .Utf32BE;
		case .Unknown:
			return .Err(Unsupported(buffer, DeclaredEncoding(buffer)));
		default:
			ok = false;
		}
		if (!ok)
		{
			let what = scope String();
			what.Append(sixteen ? "UTF-16" : "UTF-32");
			what.Append(wide == .Utf16LE || wide == .Utf32LE ? "LE" : "BE");
			what.Append(bom ? " (from its byte order mark)" : " (from its first bytes)");
			return .Err(Mismatch(buffer, what, 0));
		}
		return .Ok;
	}

	static bool IsWide(Family family)
	{
		return family >= .Utf16 && family <= .Utf32BE;
	}

	/// Converts UTF-16 or UTF-32 code units from `skip` on to UTF-8, into a buffer sized for the worst
	/// case (3 bytes per UTF-16 unit, 4 per UTF-32 one) and trimmed after. Runs of ASCII in UTF-16LE,
	/// the common case, are copied four units at a time.
	static Result<void, XmlParseError> TranscodeWide(StringView input, int skip, XmlEncoding wide, String output)
	{
		uint8* b = (uint8*)input.Ptr;
		int n = input.Length;
		bool sixteen = wide == .Utf16LE || wide == .Utf16BE;
		int unit = sixteen ? 2 : 4;
		int start = output.Length;
		uint8* o = (uint8*)output.PrepareBuffer((n - skip) / unit * (sixteen ? 3 : 4) + 4);
		// Bytes written to o
		int w = 0;
		int i = skip;
		while (i + unit <= n)
		{
			if (wide == .Utf16LE)
			{
				while (i + 8 <= n)
				{
					uint64 word = XmlChar.Load64((char8*)b + i);
					if ((word & 0xFF80FF80FF80FF80UL) != 0)
						break;
					o[w] = (uint8)word;
					o[w + 1] = (uint8)(word >> 16);
					o[w + 2] = (uint8)(word >> 32);
					o[w + 3] = (uint8)(word >> 48);
					w += 4;
					i += 8;
				}
				if (i + unit > n)
					break;
			}
			uint32 cp;
			switch (wide)
			{
			case .Utf16LE:
				cp = (uint32)b[i] | ((uint32)b[i + 1] << 8);
			case .Utf16BE:
				cp = ((uint32)b[i] << 8) | (uint32)b[i + 1];
			case .Utf32LE:
				cp = (uint32)b[i] | ((uint32)b[i + 1] << 8) | ((uint32)b[i + 2] << 16) | ((uint32)b[i + 3] << 24);
			default:
				cp = ((uint32)b[i] << 24) | ((uint32)b[i + 1] << 16) | ((uint32)b[i + 2] << 8) | (uint32)b[i + 3];
			}
			i += unit;
			if (sixteen && cp >= 0xD800 && cp <= 0xDBFF)
			{
				// A high surrogate: the low one must follow
				uint32 low = 0;
				if (i + 2 <= n)
					low = wide == .Utf16LE ? ((uint32)b[i] | ((uint32)b[i + 1] << 8)) : (((uint32)b[i] << 8) | (uint32)b[i + 1]);
				if (low < 0xDC00 || low > 0xDFFF)
					return .Err(WideError("A UTF-16 high surrogate without its low surrogate", output, start, w));
				i += 2;
				cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
			}
			else if (cp >= 0xD800 && cp <= 0xDFFF)
				return .Err(WideError(sixteen ? "A UTF-16 low surrogate without its high surrogate" : "A surrogate code point in UTF-32", output, start, w));
			else if (cp > 0x10FFFF)
				return .Err(WideError("A UTF-32 code unit beyond U+10FFFF", output, start, w));
			w = PutUtf8(o, w, cp);
		}
		output.Length = start + w;
		if (i != n)
			return .Err(XmlParseError.At(.InvalidEncoding, sixteen ? "The input ends in the middle of a UTF-16 code unit" : "The input ends in the middle of a UTF-32 code unit", output, output.Length));
		return .Ok;
	}

	/// An error at the end of what was converted (`written` bytes from `start`), located in it.
	static XmlParseError WideError(StringView message, String output, int start, int written)
	{
		output.Length = start + written;
		return XmlParseError.At(.InvalidEncoding, message, output, output.Length);
	}

	/// Writes `cp` as UTF-8 at `dst[at]`. @return The index just past it.
	[Inline]
	static int PutUtf8(uint8* dst, int at, uint32 cp)
	{
		if (cp < 0x80)
		{
			dst[at] = (uint8)cp;
			return at + 1;
		}
		if (cp < 0x800)
		{
			dst[at] = (uint8)(0xC0 | (cp >> 6));
			dst[at + 1] = (uint8)(0x80 | (cp & 0x3F));
			return at + 2;
		}
		if (cp < 0x10000)
		{
			dst[at] = (uint8)(0xE0 | (cp >> 12));
			dst[at + 1] = (uint8)(0x80 | ((cp >> 6) & 0x3F));
			dst[at + 2] = (uint8)(0x80 | (cp & 0x3F));
			return at + 3;
		}
		dst[at] = (uint8)(0xF0 | (cp >> 18));
		dst[at + 1] = (uint8)(0x80 | ((cp >> 12) & 0x3F));
		dst[at + 2] = (uint8)(0x80 | ((cp >> 6) & 0x3F));
		dst[at + 3] = (uint8)(0x80 | (cp & 0x3F));
		return at + 4;
	}

	static void TranscodeLatin1(StringView input, String output)
	{
		output.Clear();
		output.Reserve(input.Length + input.Length / 8 + 16);
		for (let c in input)
		{
			if ((uint8)c < 0x80)
				output.Append(c);
			else
				XmlChar.EncodeUtf8(output, (uint8)c);
		}
	}

	/// The `encoding=` value of an XML declaration at the start of `text`, or an empty view when there is
	/// none (no declaration, or one too malformed to tell: the reader reports those). Only the name's
	/// syntax ([81] EncName) is checked here.
	static StringView DeclaredEncoding(StringView text)
	{
		if (!text.StartsWith("<?xml") || text.Length < 6 || !XmlChar.IsSpace(text[5]))
			return default;
		// The declaration ends at its `?>`; search a bounded prefix (pseudo-attributes are short, but
		// whitespace between them is not limited, so allow plenty)
		int limit = Math.Min(text.Length, 4096);
		int i = 5;
		while (i + 8 <= limit)
		{
			if (text[i] == '?' && text[i + 1] == '>')
				return default;
			if (XmlChar.IsSpace(text[i - 1]) && text.Substring(i).StartsWith("encoding"))
			{
				int p = i + 8;
				while (p < limit && XmlChar.IsSpace(text[p]))
					p++;
				if (p >= limit || text[p] != '=')
					return default;
				p++;
				while (p < limit && XmlChar.IsSpace(text[p]))
					p++;
				if (p >= limit || (text[p] != '"' && text[p] != '\''))
					return default;
				char8 quote = text[p++];
				int nameStart = p;
				while (p < limit && text[p] != quote)
				{
					char8 c = text[p];
					bool letter = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
					if (!(letter || (p > nameStart && ((c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-'))))
						return default;
					p++;
				}
				if (p >= limit || p == nameStart)
					return default;
				return text.Substring(nameStart, p - nameStart);
			}
			i++;
		}
		return default;
	}

	static Family Classify(StringView name)
	{
		if (name.IsEmpty)
			return .None;
		let lower = scope String(name);
		lower.ToLower();
		switch (lower)
		{
		case "utf-8", "utf8":
			return .Utf8;
		case "utf-16", "ucs-2", "iso-10646-ucs-2", "csunicode", "unicode":
			return .Utf16;
		case "utf-16le":
			return .Utf16LE;
		case "utf-16be":
			return .Utf16BE;
		case "utf-32", "ucs-4", "iso-10646-ucs-4", "csucs4":
			return .Utf32;
		case "utf-32le":
			return .Utf32LE;
		case "utf-32be":
			return .Utf32BE;
		case "iso-8859-1", "iso8859-1", "iso_8859-1", "latin1", "l1", "iso-ir-100", "cp819", "ibm819", "csisolatin1":
			return .Latin1;
		case "us-ascii", "ascii", "iso646-us", "ansi_x3.4-1968", "cp367", "ibm367", "csascii":
			return .Ascii;
		default:
			return .Unknown;
		}
	}

	static XmlParseError Unsupported(StringView text, StringView name)
	{
		let message = scope String();
		message.AppendF("The encoding `{}` is not supported", name);
		return XmlParseError.At(.UnsupportedEncoding, message, text, Math.Max(name.Ptr - text.Ptr, 0), name.Length);
	}

	static XmlParseError Mismatch(StringView text, StringView actual, int skip)
	{
		let name = DeclaredEncoding(text.Substring(skip));
		let message = scope String();
		message.AppendF("The encoding declaration `{}` contradicts the document's encoding, {}", name, actual);
		return XmlParseError.At(.UnsupportedEncoding, message, text, Math.Max(name.Ptr - text.Ptr, 0), name.Length);
	}
}
