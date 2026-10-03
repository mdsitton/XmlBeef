using System;
using FormatCore;
using internal FormatCore;
using internal XmlBeef;

namespace XmlBeef;

/// Encoding detection for XML documents (XML 1.0 Appendix F, after the author's StrikeCore
/// `DetectEncoding`: byte order marks, UTF-7's rejection), as FormatCore's `IEncodingDetector`: the
/// transcoding cursors call it on the input's first bytes and decode the rest with FormatCore's
/// `Decoder` into UTF-8, the reader's only internal form.
///
/// The encoding comes from the byte order mark or the first four bytes, then the `encoding=` of the XML
/// declaration picks the decoder of an ASCII-compatible document. Conflicts (plan.md §9 item 6): a UTF-8
/// byte order mark wins over a declaration naming another ASCII-compatible encoding (noted in
/// `mBomOverride`); a UTF-16 or UTF-32 one (or such bytes without one) with a declaration of an 8-bit
/// encoding is an error, as is an 8-bit document declaring UTF-16 or UTF-32. Detection needs only the
/// start of the input (a stream's first PrefixBytes, more while the declaration goes on).
internal struct XmlDetector : IEncodingDetector
{
	/// How much of a stream detection reads first (the declaration must be in it to be seen).
	public const int cPrefixBytes = 4096;

	public static int PrefixBytes
	{
		[Inline]
		get => cPrefixBytes;
	}

	public static void AppendUndecided(String message, int maxTokenBytes)
	{
		message.AppendF("The XML declaration is longer than MaxTokenBytes ({}) before its encoding", maxTokenBytes);
	}

	/// @brief Detect the encoding from the start of the input: a whole document, or a stream's first
	/// cPrefixBytes (fewer only if that is all of it).
	/// @param prefix The input's first bytes.
	/// @param declared Receives the declared encoding name (empty if none).
	/// @param scratch Scratch space (a UTF-16/32 prefix decoded, to read its declaration).
	/// @return What was found, or an error for an unsupported or contradictory encoding.
	public static Result<EncodingDetection, InputError> Detect(StringView prefix, String declared, String scratch)
	{
		uint8* b = (uint8*)prefix.Ptr;
		int n = prefix.Length;
		EncodingDetection detection = .();
		detection.mEncoding = .Utf8;
		declared.Clear();

		// Byte order marks (UTF-32's before UTF-16's: FF FE 00 00 starts like FF FE)
		if (n >= 4 && b[0] == 0x00 && b[1] == 0x00 && b[2] == 0xFE && b[3] == 0xFF)
			return Wide(prefix, 4, .Utf32BE, true, declared, scratch);
		if (n >= 4 && b[0] == 0xFF && b[1] == 0xFE && b[2] == 0x00 && b[3] == 0x00)
			return Wide(prefix, 4, .Utf32LE, true, declared, scratch);
		if (n >= 4 && ((b[0] == 0x00 && b[1] == 0x00 && b[2] == 0xFF && b[3] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF && b[2] == 0x00 && b[3] == 0x00)))
			return .Err(InputError(.UnsupportedEncoding, "UCS-4 in the unusual byte orders 2143 and 3412 is not supported", 1, 1, 0, 4));
		if (n >= 2 && b[0] == 0xFE && b[1] == 0xFF)
			return Wide(prefix, 2, .Utf16BE, true, declared, scratch);
		if (n >= 2 && b[0] == 0xFF && b[1] == 0xFE)
			return Wide(prefix, 2, .Utf16LE, true, declared, scratch);
		if (Utf8.StartsWithBom(prefix.Ptr, n))
		{
			detection.mUtf8Bom = true;
			let name = DeclaredEncoding(prefix.Substring(3), out detection.mIncomplete);
			declared.Set(name);
			let family = EncodingLabels.Classify(name, let single);
			if (family == .Unknown)
				return .Err(Unsupported(prefix, name));
			if (IsWide(family))
				return .Err(Mismatch(prefix, "UTF-8 (it starts with a UTF-8 byte order mark)", 3));
			// UTF-8 or an 8-bit encoding declared: the byte order mark wins (plan.md §9 item 6), noted
			detection.mBomOverride = family != .None && family != .Utf8;
			return detection;
		}
		if (n >= 4 && b[0] == 0x2B && b[1] == 0x2F && b[2] == 0x76 && (b[3] == 0x38 || b[3] == 0x39 || b[3] == 0x2B || b[3] == 0x2F))
			return .Err(InputError(.UnsupportedEncoding, "UTF-7 is not supported", 1, 1, 0, 4));

		// No byte order mark: the first four bytes of `<?xm` or `<`
		if (n >= 4)
		{
			if (b[0] == 0x00 && b[1] == 0x00 && b[2] == 0x00 && b[3] == 0x3C)
				return Wide(prefix, 0, .Utf32BE, false, declared, scratch);
			if (b[0] == 0x3C && b[1] == 0x00 && b[2] == 0x00 && b[3] == 0x00)
				return Wide(prefix, 0, .Utf32LE, false, declared, scratch);
			if ((b[0] == 0x00 && b[1] == 0x00 && b[2] == 0x3C && b[3] == 0x00) || (b[0] == 0x00 && b[1] == 0x3C && b[2] == 0x00 && b[3] == 0x00))
				return .Err(InputError(.UnsupportedEncoding, "UCS-4 in the unusual byte orders 2143 and 3412 is not supported", 1, 1, 0, 4));
			if (b[0] == 0x00 && b[1] == 0x3C && b[2] == 0x00 && b[3] == 0x3F)
				return Wide(prefix, 0, .Utf16BE, false, declared, scratch);
			if (b[0] == 0x3C && b[1] == 0x00 && b[2] == 0x3F && b[3] == 0x00)
				return Wide(prefix, 0, .Utf16LE, false, declared, scratch);
			if (b[0] == 0x4C && b[1] == 0x6F && b[2] == 0xA7 && b[3] == 0x94)
				return .Err(InputError(.UnsupportedEncoding, "EBCDIC encodings are not supported", 1, 1, 0, 4));
		}

		// ASCII-compatible: the declaration decides
		let name = DeclaredEncoding(prefix, out detection.mIncomplete);
		declared.Set(name);
		switch (EncodingLabels.Classify(name, let single))
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
			// For the converter; where the name is, should there be none
			detection.mEncoding = .Custom;
			detection.mConvert = true;
			detection.mNameOffset = Math.Max(name.Ptr - prefix.Ptr, 0);
			detection.mNameLength = name.Length;
		default:
			return .Err(Mismatch(prefix, "an 8-bit encoding (no UTF-16 or UTF-32 byte order mark or byte pattern)", 0));
		}
		return detection;
	}

	/// A UTF-16 or UTF-32 document from `skip` on: its declaration (if any) must name the same family.
	static Result<EncodingDetection, InputError> Wide(StringView prefix, int skip, TextEncoding wide, bool bom, String declared, String scratch)
	{
		EncodingDetection detection = .();
		detection.mEncoding = wide;
		detection.mSkip = skip;
		// The declaration is ASCII: decode the prefix to read it (invalid units are the decoder's to report)
		scratch.Clear();
		var decoder = Decoder(wide);
		int length = prefix.Length - skip;
		uint8* dst = (uint8*)scratch.PrepareBuffer(length * 2 + 8);
		decoder.Decode((uint8*)prefix.Ptr + skip, length, false, dst, length * 2 + 8, let consumed, let produced, let error);
		scratch.Length = produced;
		let name = DeclaredEncoding(scratch, out detection.mIncomplete);
		declared.Set(name);
		bool sixteen = wide == .Utf16LE || wide == .Utf16BE;
		bool ok;
		switch (EncodingLabels.Classify(name, let single))
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

	static bool IsWide(EncodingFamily family)
	{
		return family >= .Utf16 && family <= .Utf32BE;
	}

	/// The `encoding=` value of an XML declaration at the start of `text`, or an empty view when there is
	/// none (no declaration, or one too malformed to tell: the reader reports those). Only the name's
	/// syntax ([81] EncName) is checked here.
	static StringView DeclaredEncoding(StringView text)
	{
		return DeclaredEncoding(text, ?);
	}

	/// The `encoding` of the XML declaration at the start of `text`, or empty. `incomplete`: `text` ended
	/// inside the declaration before its encoding was known (more input may hold it).
	static StringView DeclaredEncoding(StringView text, out bool incomplete)
	{
		incomplete = false;
		if (text.Length < 6)
		{
			// `<?xml ` itself may be cut off
			incomplete = !text.IsEmpty && StringView("<?xml ").StartsWith(text);
			return default;
		}
		if (!text.StartsWith("<?xml") || !XmlChar.IsSpace(text[5]))
			return default;
		// The declaration ends at its `?>`; pseudo-attributes are short, but the whitespace between them
		// is not limited: the whole text is searched, and an end before `?>` is incomplete
		int limit = text.Length;
		incomplete = true;
		int i = 5;
		while (i + 1 < limit)
		{
			if (text[i] == '?' && text[i + 1] == '>')
			{
				incomplete = false;
				return default;
			}
			if (XmlChar.IsSpace(text[i - 1]) && text.Substring(i).StartsWith("encoding"))
			{
				// Running out of text here is incomplete; malformed syntax is the reader's to report
				int p = i + 8;
				while (p < limit && XmlChar.IsSpace(text[p]))
					p++;
				if (p >= limit)
					return default;
				incomplete = false;
				if (text[p] != '=')
					return default;
				p++;
				while (p < limit && XmlChar.IsSpace(text[p]))
					p++;
				if (p >= limit)
				{
					incomplete = true;
					return default;
				}
				if (text[p] != '"' && text[p] != '\'')
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
				if (p >= limit)
				{
					incomplete = true;
					return default;
				}
				if (p == nameStart)
					return default;
				return text.Substring(nameStart, p - nameStart);
			}
			i++;
		}
		return default;
	}

	/// An error at byte `offset` of `text`, located under XML's newline rules.
	static InputError At(InputErrorKind kind, StringView message, StringView text, int offset, int length)
	{
		Utf8.LineAndColumn<XmlText>(text, offset, let line, let column);
		return InputError(kind, message, line, column, offset, length);
	}

	static InputError Unsupported(StringView text, StringView name)
	{
		let message = scope String();
		message.AppendF("The encoding `{}` is not supported", name);
		return At(.UnsupportedEncoding, message, text, Math.Max(name.Ptr - text.Ptr, 0), name.Length);
	}

	static InputError Mismatch(StringView text, StringView actual, int skip)
	{
		let name = DeclaredEncoding(text.Substring(skip));
		let message = scope String();
		message.AppendF("The encoding declaration `{}` contradicts the document's encoding, {}", name, actual);
		return At(.UnsupportedEncoding, message, text, Math.Max(name.Ptr - text.Ptr, 0), name.Length);
	}
}
