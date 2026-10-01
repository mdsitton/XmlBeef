using System;
using internal XmlBeef;

namespace XmlBeef;

/// What XmlEncodingDetector.Detect found about a document's encoding.
internal struct XmlDetection
{
	/// The decoder to use (Utf8: the bytes are read as they are).
	public XmlEncoding mEncoding;
	/// Bytes of a UTF-16 or UTF-32 byte order mark, skipped before decoding.
	public int mSkip;
	/// The text starts with a UTF-8 byte order mark, kept: its content starts at offset 3.
	public bool mUtf8Bom;
	/// ASCII-compatible without a declaration: UTF-8, or with XmlEncodingFallback.Windows1252 Windows-1252
	/// when the whole input is not valid UTF-8.
	public bool mUndeclared;
	/// The declared encoding is for XmlReadConfig.EncodingConverter.
	public bool mConvert;
	/// A UTF-8 byte order mark overrode a declaration of another (8-bit) encoding (plan.md §9 item 6).
	public bool mBomOverride;
}

/// Encoding detection (XML 1.0 Appendix F, after the author's StrikeCore `DetectEncoding`: byte order
/// marks, UTF-7's rejection) and transcoding to UTF-8, the reader's only internal form.
///
/// The encoding comes from the byte order mark or the first four bytes, then the `encoding=` of the XML
/// declaration picks the decoder of an ASCII-compatible document. Conflicts (plan.md §9 item 6): a UTF-8
/// byte order mark wins over a declaration naming another ASCII-compatible encoding; a UTF-16 or UTF-32
/// one (or such bytes without one) with a declaration of an 8-bit encoding is an error, as is an 8-bit
/// document declaring UTF-16 or UTF-32. Detection needs only the start of the input (a stream's first
/// bytes); the decoders (XmlDecoder) work on any part of it.
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
		Ascii,
		/// One of the table-driven encodings.
		SingleByte
	}

	/// How much of a stream detection reads first (the declaration must be in it to be seen).
	public const int cPrefixBytes = 4096;

	/// @brief Detect the encoding from the start of the input: a whole document, or a stream's first
	/// cPrefixBytes (fewer only if that is all of it).
	/// @param prefix The input's first bytes.
	/// @param declared Receives the declared encoding name (empty if none).
	/// @param scratch Scratch space (a UTF-16/32 prefix decoded, to read its declaration).
	/// @return What was found, or an error for an unsupported or contradictory encoding.
	public static Result<XmlDetection, XmlParseError> Detect(StringView prefix, String declared, String scratch)
	{
		uint8* b = (uint8*)prefix.Ptr;
		int n = prefix.Length;
		XmlDetection detection = default;
		detection.mEncoding = .Utf8;

		// Byte order marks (UTF-32's before UTF-16's: FF FE 00 00 starts like FF FE)
		if (n >= 4 && b[0] == 0x00 && b[1] == 0x00 && b[2] == 0xFE && b[3] == 0xFF)
			return Wide(prefix, 4, .Utf32BE, true, declared, scratch);
		if (n >= 4 && b[0] == 0xFF && b[1] == 0xFE && b[2] == 0x00 && b[3] == 0x00)
			return Wide(prefix, 4, .Utf32LE, true, declared, scratch);
		if (n >= 4 && ((b[0] == 0x00 && b[1] == 0x00 && b[2] == 0xFF && b[3] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF && b[2] == 0x00 && b[3] == 0x00)))
			return .Err(XmlParseError(.UnsupportedEncoding, "UCS-4 in the unusual byte orders 2143 and 3412 is not supported", 1, 1, 0, 4));
		if (n >= 2 && b[0] == 0xFE && b[1] == 0xFF)
			return Wide(prefix, 2, .Utf16BE, true, declared, scratch);
		if (n >= 2 && b[0] == 0xFF && b[1] == 0xFE)
			return Wide(prefix, 2, .Utf16LE, true, declared, scratch);
		if (n >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF)
		{
			detection.mUtf8Bom = true;
			let name = DeclaredEncoding(prefix.Substring(3));
			declared.Set(name);
			let family = Classify(name, let single);
			if (family == .Unknown)
				return .Err(Unsupported(prefix, name));
			if (IsWide(family))
				return .Err(Mismatch(prefix, "UTF-8 (it starts with a UTF-8 byte order mark)", 3));
			// UTF-8 or an 8-bit encoding declared: the byte order mark wins (plan.md §9 item 6), noted
			detection.mBomOverride = family != .None && family != .Utf8;
			return detection;
		}
		if (n >= 4 && b[0] == 0x2B && b[1] == 0x2F && b[2] == 0x76 && (b[3] == 0x38 || b[3] == 0x39 || b[3] == 0x2B || b[3] == 0x2F))
			return .Err(XmlParseError(.UnsupportedEncoding, "UTF-7 is not supported", 1, 1, 0, 4));

		// No byte order mark: the first four bytes of `<?xm` or `<`
		if (n >= 4)
		{
			if (b[0] == 0x00 && b[1] == 0x00 && b[2] == 0x00 && b[3] == 0x3C)
				return Wide(prefix, 0, .Utf32BE, false, declared, scratch);
			if (b[0] == 0x3C && b[1] == 0x00 && b[2] == 0x00 && b[3] == 0x00)
				return Wide(prefix, 0, .Utf32LE, false, declared, scratch);
			if ((b[0] == 0x00 && b[1] == 0x00 && b[2] == 0x3C && b[3] == 0x00) || (b[0] == 0x00 && b[1] == 0x3C && b[2] == 0x00 && b[3] == 0x00))
				return .Err(XmlParseError(.UnsupportedEncoding, "UCS-4 in the unusual byte orders 2143 and 3412 is not supported", 1, 1, 0, 4));
			if (b[0] == 0x00 && b[1] == 0x3C && b[2] == 0x00 && b[3] == 0x3F)
				return Wide(prefix, 0, .Utf16BE, false, declared, scratch);
			if (b[0] == 0x3C && b[1] == 0x00 && b[2] == 0x3F && b[3] == 0x00)
				return Wide(prefix, 0, .Utf16LE, false, declared, scratch);
			if (b[0] == 0x4C && b[1] == 0x6F && b[2] == 0xA7 && b[3] == 0x94)
				return .Err(XmlParseError(.UnsupportedEncoding, "EBCDIC encodings are not supported", 1, 1, 0, 4));
		}

		// ASCII-compatible: the declaration decides
		let name = DeclaredEncoding(prefix);
		declared.Set(name);
		switch (Classify(name, let single))
		{
		case .None:
			detection.mUndeclared = true;
		case .Utf8:
		case .Latin1:
			detection.mEncoding = .Latin1;
		case .Ascii:
			detection.mEncoding = .Ascii;
		case .SingleByte:
			detection.mEncoding = single;
		case .Unknown:
			detection.mEncoding = .Custom;
			detection.mConvert = true;
		default:
			return .Err(Mismatch(prefix, "an 8-bit encoding (no UTF-16 or UTF-32 byte order mark or byte pattern)", 0));
		}
		return detection;
	}

	/// A UTF-16 or UTF-32 document from `skip` on: its declaration (if any) must name the same family.
	static Result<XmlDetection, XmlParseError> Wide(StringView prefix, int skip, XmlEncoding wide, bool bom, String declared, String scratch)
	{
		XmlDetection detection = default;
		detection.mEncoding = wide;
		detection.mSkip = skip;
		// The declaration is ASCII: decode the prefix to read it (invalid units are the decoder's to report)
		scratch.Clear();
		var decoder = XmlDecoder(wide);
		int length = prefix.Length - skip;
		uint8* dst = (uint8*)scratch.PrepareBuffer(length * 2 + 8);
		decoder.Decode((uint8*)prefix.Ptr + skip, length, false, dst, length * 2 + 8, let consumed, let produced, let error);
		scratch.Length = produced;
		let name = DeclaredEncoding(scratch);
		declared.Set(name);
		bool sixteen = wide == .Utf16LE || wide == .Utf16BE;
		bool ok;
		switch (Classify(name, let single))
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
			return .Err(Unsupported(scratch, name));
		default:
			ok = false;
		}
		if (!ok)
		{
			let what = scope String();
			what.Append(sixteen ? "UTF-16" : "UTF-32");
			what.Append(wide == .Utf16LE || wide == .Utf32LE ? "LE" : "BE");
			what.Append(bom ? " (from its byte order mark)" : " (from its first bytes)");
			return .Err(Mismatch(scratch, what, 0));
		}
		return detection;
	}

	/// @brief Detect the encoding of a whole in-memory document and make its UTF-8 text.
	/// @param input The document's bytes.
	/// @param buffer Receives the transcoded text when the document is not UTF-8.
	/// @param config The converter for other encodings and the fallback for undeclared non-UTF-8.
	/// @param text Receives the UTF-8 text: `input`, or a view of `buffer`.
	/// @param start Receives the offset of the first content byte in `text` (after a UTF-8 BOM).
	/// @param encoding Receives the encoding the document was read in.
	/// @return An error for an unsupported or contradictory encoding, or bytes invalid in it.
	public static Result<void, XmlParseError> Prepare(StringView input, String buffer, XmlReadConfig config, out StringView text, out int start, out XmlEncoding encoding)
	{
		return Prepare(input, buffer, config, out text, out start, out encoding, let bomOverride);
	}

	/// Prepare, also telling whether a UTF-8 byte order mark overrode an 8-bit declaration.
	public static Result<void, XmlParseError> Prepare(StringView input, String buffer, XmlReadConfig config, out StringView text, out int start, out XmlEncoding encoding, out bool bomOverride)
	{
		text = input;
		start = 0;
		encoding = .Utf8;
		bomOverride = false;
		let declared = scope String();
		let scratch = scope String();
		let detection = Try!(Detect(input, declared, scratch));
		bomOverride = detection.mBomOverride;
		encoding = detection.mEncoding;
		if (detection.mUtf8Bom)
			start = 3;
		if (detection.mConvert)
		{
			buffer.Clear();
			if (config.EncodingConverter != null && config.EncodingConverter(declared, Span<uint8>((uint8*)input.Ptr, input.Length), buffer))
			{
				text = buffer;
				return .Ok;
			}
			return .Err(Unsupported(input, DeclaredEncoding(input)));
		}
		if (detection.mUndeclared && config.EncodingFallback == .Windows1252 && !IsValidUtf8(input))
			encoding = .Windows1252;
		if (encoding == .Utf8)
			return .Ok;
		// Transcode it all at once, into a buffer sized for the worst case
		var decoder = XmlDecoder(encoding);
		int length = input.Length - detection.mSkip;
		int capacity = length * decoder.MaxExpansion + 8;
		buffer.Clear();
		uint8* dst = (uint8*)buffer.PrepareBuffer(capacity);
		bool ok = decoder.Decode((uint8*)input.Ptr + detection.mSkip, length, true, dst, capacity, let consumed, let produced, let error);
		buffer.Length = produced;
		if (!ok)
			return .Err(DecodeError(error, encoding, declared, input[detection.mSkip + consumed], buffer, produced));
		text = buffer;
		return .Ok;
	}

	/// A decoding error at the end of what was decoded (`produced` bytes of `text`), naming the byte for an
	/// 8-bit encoding.
	public static XmlParseError DecodeError(StringView error, XmlEncoding encoding, StringView declared, char8 byte, StringView text, int produced)
	{
		if (encoding == .Utf8 || encoding == .Utf16LE || encoding == .Utf16BE || encoding == .Utf32LE || encoding == .Utf32BE)
			return XmlParseError.At(.InvalidEncoding, error, text, produced);
		let message = scope String();
		message.AppendF("The byte 0x{:X2} is not defined in the encoding `{}`", (uint8)byte, declared.IsEmpty ? "Windows-1252" : declared);
		return XmlParseError.At(.InvalidEncoding, message, text, produced);
	}

	/// Whether `input` is well-formed UTF-8 (the fallback's test; Char rules are checked later either way).
	public static bool IsValidUtf8(StringView input)
	{
		let message = scope String();
		int bad = XmlChar.FindInvalid(input.Ptr, 0, input.Length, message, let kind, let length);
		return bad < 0 || kind != .InvalidEncoding;
	}

	static bool IsWide(Family family)
	{
		return family >= .Utf16 && family <= .Utf32BE;
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
		int limit = Math.Min(text.Length, cPrefixBytes);
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

	/// The family of an encoding name (case-insensitive); `single` receives a table encoding's case.
	static Family Classify(StringView name, out XmlEncoding single)
	{
		single = .Utf8;
		if (name.IsEmpty)
			return .None;
		let lower = scope String(name);
		lower.ToLower();
		if (XmlEncodingTables.TryGetByLabel(lower, out single))
			return .SingleByte;
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
		case "iso-8859-1", "iso8859-1", "iso88591", "iso_8859-1", "iso_8859-1:1987", "latin1", "l1", "iso-ir-100", "cp819", "ibm819", "csisolatin1":
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

/// Decodes one encoding into UTF-8, a piece at a time: the whole input at once for memory, or as a
/// stream's bytes arrive (a code unit cut off at a piece's end waits for the next piece).
internal struct XmlDecoder
{
	XmlEncoding mEncoding;
	uint16* mTable;

	public this(XmlEncoding encoding)
	{
		mEncoding = encoding;
		mTable = XmlEncodingTables.Get(encoding);
	}

	/// The most UTF-8 bytes one input byte can become.
	public int MaxExpansion
	{
		get
		{
			switch (mEncoding)
			{
			case .Utf8, .Ascii, .Utf32LE, .Utf32BE: return 1;
			case .Latin1: return 2;
			default: return 3;
			}
		}
	}

	/// @brief Decode `src` into `dst` as far as both allow: stops at a code unit cut off at the end of
	/// `src` (unless `final`, where that is an error) or when `dst` has no room for the next one (4 bytes).
	/// @param src The input.
	/// @param srcLength Its length.
	/// @param final Whether `src` ends the input.
	/// @param dst The output.
	/// @param dstCapacity Its room.
	/// @param consumed Receives how many input bytes were decoded.
	/// @param produced Receives how many output bytes were written.
	/// @param error Receives the message when the input is invalid in the encoding.
	/// @return Whether it was valid (as far as it was decoded).
	public bool Decode(uint8* src, int srcLength, bool final, uint8* dst, int dstCapacity, out int consumed, out int produced, out StringView error)
	{
		error = default;
		consumed = 0;
		produced = 0;
		int i = 0;
		int w = 0;
		defer
		{
			consumed = i;
			produced = w;
		}
		switch (mEncoding)
		{
		case .Utf8:
			int count = Math.Min(srcLength, dstCapacity);
			Internal.MemCpy(dst, src, count);
			i = count;
			w = count;
			return true;
		case .Ascii:
			int count = Math.Min(srcLength, dstCapacity);
			while (i < count)
			{
				if (src[i] >= 0x80)
				{
					error = "A byte above 0x7F in a document declared US-ASCII";
					return false;
				}
				dst[w++] = src[i++];
			}
			return true;
		case .Utf16LE, .Utf16BE, .Utf32LE, .Utf32BE:
			return DecodeWide(src, srcLength, final, dst, dstCapacity, ref i, ref w, out error);
		default:
			// Latin-1 and the tables: a byte at a time, ASCII copied
			while (i < srcLength && w + 4 <= dstCapacity)
			{
				uint8 c = src[i];
				if (c < 0x80)
				{
					dst[w++] = c;
					i++;
					continue;
				}
				uint32 cp = mTable != null ? mTable[c - 0x80] : c;
				if (cp == 0)
				{
					error = "A byte that the declared encoding does not define";
					return false;
				}
				w = PutUtf8(dst, w, cp);
				i++;
			}
			return true;
		}
	}

	bool DecodeWide(uint8* b, int n, bool final, uint8* dst, int dstCapacity, ref int i, ref int w, out StringView error)
	{
		error = default;
		bool sixteen = mEncoding == .Utf16LE || mEncoding == .Utf16BE;
		int unit = sixteen ? 2 : 4;
		while (i + unit <= n && w + 4 <= dstCapacity)
		{
			if (mEncoding == .Utf16LE)
			{
				// Runs of ASCII, four units at a time
				while (i + 8 <= n && w + 4 <= dstCapacity)
				{
					uint64 word = XmlChar.Load64((char8*)b + i);
					if ((word & 0xFF80FF80FF80FF80UL) != 0)
						break;
					dst[w] = (uint8)word;
					dst[w + 1] = (uint8)(word >> 16);
					dst[w + 2] = (uint8)(word >> 32);
					dst[w + 3] = (uint8)(word >> 48);
					w += 4;
					i += 8;
				}
				if (i + unit > n || w + 4 > dstCapacity)
					break;
			}
			uint32 cp;
			switch (mEncoding)
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
			if (sixteen && cp >= 0xD800 && cp <= 0xDBFF)
			{
				// A high surrogate: the low one must follow (wait for it if it is not here yet)
				if (i + 4 > n)
				{
					if (!final)
						return true;
					error = "A UTF-16 high surrogate without its low surrogate";
					return false;
				}
				uint32 low = mEncoding == .Utf16LE ? ((uint32)b[i + 2] | ((uint32)b[i + 3] << 8)) : (((uint32)b[i + 2] << 8) | (uint32)b[i + 3]);
				if (low < 0xDC00 || low > 0xDFFF)
				{
					error = "A UTF-16 high surrogate without its low surrogate";
					return false;
				}
				cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
				i += 4;
			}
			else if (cp >= 0xD800 && cp <= 0xDFFF)
			{
				error = sixteen ? "A UTF-16 low surrogate without its high surrogate" : "A surrogate code point in UTF-32";
				return false;
			}
			else if (cp > 0x10FFFF)
			{
				error = "A UTF-32 code unit beyond U+10FFFF";
				return false;
			}
			else
				i += unit;
			w = PutUtf8(dst, w, cp);
		}
		if (final && i < n && i + unit > n && w + 4 <= dstCapacity)
		{
			error = sixteen ? "The input ends in the middle of a UTF-16 code unit" : "The input ends in the middle of a UTF-32 code unit";
			return false;
		}
		return true;
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
}
