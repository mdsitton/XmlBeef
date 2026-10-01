using System;
using internal XmlBeef;

namespace XmlBeef;

/// Character data, references, comments, processing instructions, CDATA sections and the XML
/// declaration.
extension XmlReaderCore<TCursor>
{
	/// Bytes that end a run of plain text: `<`, `&`, `]` (a possible `]]>`) and CR (line ends).
	static bool[256] sTextStop = BuildTextStop();

	static bool[256] BuildTextStop()
	{
		bool[256] table = default;
		table['<'] = true;
		table['&'] = true;
		table[']'] = true;
		table['\r'] = true;
		return table;
	}

	/// Skips plain text from `pos`. @return The first stop byte's offset, or the window's end.
	[Inline]
	int ScanText(int pos)
	{
		int p = pos;
		// Words without a stop byte are skipped whole; the one holding it is walked byte by byte
		while (p + 8 <= mEnd)
		{
			uint64 word = XmlChar.Load64(mData + p);
			if ((XmlChar.BytesEqual(word, (uint8)'<') | XmlChar.BytesEqual(word, (uint8)'&') | XmlChar.BytesEqual(word, (uint8)']') | XmlChar.BytesEqual(word, (uint8)'\r')) != 0)
				break;
			p += 8;
		}
		while (true)
		{
			if (p >= mEnd && !Grow(p, 1))
				return p;
			if (sTextStop[(uint8)mData[p]])
				return p;
			p++;
		}
	}

	/// Character data at mPos, up to the next markup: references are expanded and merged in, and an
	/// internal entity's replacement text is read on until its markup (text continues across the
	/// reference's ends). A reference to an entity that is not read (external, or undeclared where that
	/// is allowed) is an EntityReference event of its own.
	Result<XmlEvent, XmlFailure> ReadText()
	{
		int start = mPos;
		int eventStart = DocOffset(start);
		int p = start;
		int runStart = p;
		bool decoded = false;
		while (true)
		{
			p = ScanText(p);
			if (!Avail(p))
			{
				// The end of the input (the element is unclosed: reported next) or of an entity, after
				// which the text goes on
				if (mFrames.Count == 0)
					break;
				if (!decoded)
				{
					decoded = true;
					mTextBuffer.Clear();
				}
				mTextBuffer.Append(View(runStart, p - runStart));
				mPos = p;
				Try!(PopFrame());
				p = mPos;
				runStart = p;
				continue;
			}
			char8 c = mData[p];
			if (c == '<')
				break;
			if (c == ']')
			{
				if (StartsWith(p, "]]>"))
					return .Err(Fail(.InvalidCData, "`]]>` is not allowed in text; write `]]&gt;`", p, 3));
				p++;
				continue;
			}
			if (c == '\r')
			{
				// Line ends are normalized in the document, not in replacement text (a CR from `&#13;`)
				if (mFrames.Count > 0)
				{
					p++;
					continue;
				}
				if (!decoded)
				{
					decoded = true;
					mTextBuffer.Clear();
				}
				mTextBuffer.Append(View(runStart, p - runStart));
				mTextBuffer.Append('\n');
				p += At(p + 1) == '\n' ? 2 : 1;
				runStart = p;
				continue;
			}
			// A reference
			if (!decoded)
			{
				decoded = true;
				mTextBuffer.Clear();
			}
			mTextBuffer.Append(View(runStart, p - runStart));
			if (At(p + 1) == '#')
			{
				p = Try!(ReadCharReference(p, let cp));
				XmlChar.EncodeUtf8(mTextBuffer, cp);
				runStart = p;
				continue;
			}
			int refStart = p;
			int nameEnd = Try!(ScanReferenceName(p));
			StringView name = View(p + 1, nameEnd - p - 1);
			int refEnd = nameEnd + 1;
			char8 predefined = PredefinedEntity(name);
			if (predefined != 0)
			{
				mTextBuffer.Append(predefined);
				p = refEnd;
				runStart = p;
				continue;
			}
			XmlEntity entity = Try!(LookupGeneral(name, refStart, refEnd));
			if (entity == null || entity.IsExternal)
			{
				// Not read: the text so far is an event, the reference the next one
				if (mTextBuffer.Length > 0)
				{
					mPos = refStart;
					return TextEvent(mTextBuffer, eventStart, DocOffset(refStart));
				}
				mPos = refEnd;
				mNameId = .None;
				mName = name;
				mNamespace = .None;
				mValue = default;
				Report(refStart, refEnd, mElements.Count);
				return XmlEvent.EntityReference;
			}
			Try!(PushFrame(entity, refStart, refEnd));
			p = mPos;
			runStart = p;
		}
		mPos = p;
		if (!decoded)
			return TextEvent(View(runStart, p - runStart), eventStart, DocEnd(p));
		mTextBuffer.Append(View(runStart, p - runStart));
		return TextEvent(mTextBuffer, eventStart, DocEnd(p));
	}

	/// Reports `value` as a Text event, or nothing when it is empty.
	[Inline]
	Result<XmlEvent, XmlFailure> TextEvent(StringView value, int start, int end)
	{
		if (value.IsEmpty)
			return cNoEvent;
		if (mConfig.MaxTextBytes > 0 && value.Length > mConfig.MaxTextBytes)
			return .Err(Fail(.ResourceLimitExceeded, scope $"A text is longer than MaxTextBytes ({mConfig.MaxTextBytes})", start, 0));
		mValue = value;
		mNameId = .None;
		mName = default;
		mNamespace = .None;
		mDepth = mElements.Count;
		mEventOffset = start;
		mEventEnd = end;
		return XmlEvent.Text;
	}

	/// The character a predefined entity stands for (`lt gt amp apos quot`), or 0.
	static char8 PredefinedEntity(StringView name)
	{
		switch (name)
		{
		case "lt": return '<';
		case "gt": return '>';
		case "amp": return '&';
		case "apos": return '\'';
		case "quot": return '"';
		default: return 0;
		}
	}

	/// Reads `&name` at `pos` and checks the `;` after it. @return The offset of the `;`.
	[Inline]
	Result<int, XmlFailure> ScanReferenceName(int pos)
	{
		int p = pos + 1;
		if (!Avail(p) || (XmlChar.NameByteClass(mData[p]) != XmlChar.cNameStart &&
			(XmlChar.NameByteClass(mData[p]) != XmlChar.cNameDecode || !XmlChar.IsNameStartChar(DecodeAt(p, let length)))))
			return .Err(Fail(.InvalidReference, "`&` must start a reference (`&name;` or `&#…;`); write `&amp;` for the character", pos));
		int nameEnd = Try!(ScanName(p, "an entity name after `&`"));
		if (At(nameEnd) != ';')
			return .Err(Fail(.InvalidReference, scope $"The reference `&{View(p, nameEnd - p)}` must end with `;`", pos, nameEnd - pos));
		return nameEnd;
	}

	/// Reads a character reference at `pos` (`&#…;` or `&#x…;`): the code point must be a `Char`.
	/// @return The position after its `;`.
	Result<int, XmlFailure> ReadCharReference(int pos, out uint32 cp)
	{
		cp = 0;
		int p = pos + 2;
		bool hex = At(p) == 'x';
		if (hex)
			p++;
		uint64 value = 0;
		int digits = 0;
		while (true)
		{
			char8 c = At(p);
			uint32 digit;
			if (c >= '0' && c <= '9')
				digit = (uint32)(c - '0');
			else if (hex && ((c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')))
				digit = XmlChar.HexDigitValue(c);
			else
				break;
			// Saturate: anything beyond U+10FFFF is reported as such, however long
			value = Math.Min(value * (hex ? 16 : 10) + digit, 0x110000);
			digits++;
			p++;
		}
		if (digits == 0)
		{
			if (At(p) == 'X')
				return .Err(Fail(.InvalidReference, "A hexadecimal character reference starts with a lowercase `&#x`", pos, p + 1 - pos));
			return .Err(Fail(.InvalidReference, hex ? "A character reference needs hexadecimal digits after `&#x`" : "A character reference needs digits after `&#`", pos, p - pos));
		}
		if (At(p) != ';')
			return .Err(Fail(.InvalidReference, "A character reference must end with `;`", pos, p - pos));
		p++;
		if (!XmlChar.IsChar((uint32)value))
		{
			let message = scope String();
			message.Append("The character reference `");
			message.Append(View(pos, p - pos));
			message.Append("` refers to ");
			if (value > 0x10FFFF)
				message.Append("a value beyond U+10FFFF");
			else
				XmlChar.AppendCodePointName(message, (uint32)value);
			message.Append(", which is not a `Char`");
			return .Err(Fail(.InvalidChar, message, pos, p - pos));
		}
		cp = (uint32)value;
		return p;
	}

	/// A comment at mPos (`<!--`).
	Result<XmlEvent, XmlFailure> ReadComment(int depth)
	{
		int start = mPos;
		int p = start + 4;
		int runStart = p;
		bool decoded = false;
		int end = p;
		while (true)
		{
			while (Avail(p) && mData[p] != '-' && mData[p] != '\r')
				p++;
			if (!Avail(p))
				return .Err(Fail(.UnexpectedEof, "The comment is not closed (expected `-->`)", start, 4));
			if (mData[p] == '\r')
			{
				if (mFrames.Count > 0)
				{
					p++;
					continue;
				}
				if (!decoded)
				{
					decoded = true;
					mTextBuffer.Clear();
				}
				mTextBuffer.Append(View(runStart, p - runStart));
				mTextBuffer.Append('\n');
				p += At(p + 1) == '\n' ? 2 : 1;
				runStart = p;
				continue;
			}
			if (At(p + 1) == '-')
			{
				if (At(p + 2) != '>')
					return .Err(Fail(.InvalidComment, "`--` is not allowed inside a comment", p, 2));
				end = p;
				p += 3;
				break;
			}
			p++;
		}
		if (decoded)
		{
			mTextBuffer.Append(View(runStart, end - runStart));
			mValue = mTextBuffer;
		}
		else
			mValue = View(runStart, end - runStart);
		if (mConfig.MaxTextBytes > 0 && mValue.Length > mConfig.MaxTextBytes)
			return .Err(Fail(.ResourceLimitExceeded, scope $"A comment is longer than MaxTextBytes ({mConfig.MaxTextBytes})", start, 4));
		mPos = p;
		mNameId = .None;
		mName = default;
		mNamespace = .None;
		Report(start, p, depth);
		return XmlEvent.Comment;
	}

	/// A processing instruction at mPos (`<?`, not the XML declaration).
	Result<XmlEvent, XmlFailure> ReadProcessingInstruction(int depth)
	{
		int start = mPos;
		int targetEnd = Try!(ScanName(start + 2, "a processing instruction target after `<?`"));
		StringView target = View(start + 2, targetEnd - start - 2);
		if (target.Equals("xml", true))
			return .Err(Fail(.InvalidProcessingInstruction, "The processing instruction target `xml` is reserved (an XML declaration must be at the very start of the document)", start, targetEnd - start));
		Try!(CheckNoColon(start + 2, targetEnd, "The processing instruction target"));
		int p = targetEnd;
		int runStart = p;
		int end = p;
		bool decoded = false;
		if (StartsWith(p, "?>"))
		{
			runStart = p;
			end = p;
			p += 2;
		}
		else
		{
			if (!XmlChar.IsSpace(At(p)))
				return .Err(Unexpected(p, "whitespace or `?>` after the processing instruction target"));
			p = SkipSpace(p);
			runStart = p;
			while (true)
			{
				while (Avail(p) && mData[p] != '?' && mData[p] != '\r')
					p++;
				if (!Avail(p))
					return .Err(Fail(.UnexpectedEof, "The processing instruction is not closed (expected `?>`)", start, targetEnd - start));
				if (mData[p] == '\r')
				{
					if (mFrames.Count > 0)
					{
						p++;
						continue;
					}
					if (!decoded)
					{
						decoded = true;
						mTextBuffer.Clear();
					}
					mTextBuffer.Append(View(runStart, p - runStart));
					mTextBuffer.Append('\n');
					p += At(p + 1) == '\n' ? 2 : 1;
					runStart = p;
					continue;
				}
				if (At(p + 1) == '>')
				{
					end = p;
					p += 2;
					break;
				}
				p++;
			}
		}
		if (decoded)
		{
			mTextBuffer.Append(View(runStart, end - runStart));
			mValue = mTextBuffer;
		}
		else
			mValue = View(runStart, end - runStart);
		if (mConfig.MaxTextBytes > 0 && mValue.Length > mConfig.MaxTextBytes)
			return .Err(Fail(.ResourceLimitExceeded, scope $"A processing instruction is longer than MaxTextBytes ({mConfig.MaxTextBytes})", start, targetEnd - start));
		mPos = p;
		mNameId = .None;
		// From offsets: reading the data may have moved a stream's buffer
		mName = View(start + 2, targetEnd - start - 2);
		mNamespace = .None;
		Report(start, p, depth);
		return XmlEvent.ProcessingInstruction;
	}

	/// A CDATA section at mPos (`<![CDATA[`).
	Result<XmlEvent, XmlFailure> ReadCData()
	{
		int start = mPos;
		int p = start + 9;
		int runStart = p;
		bool decoded = false;
		int end = p;
		while (true)
		{
			while (Avail(p) && mData[p] != ']' && mData[p] != '\r')
				p++;
			if (!Avail(p))
				return .Err(Fail(.UnexpectedEof, "The CDATA section is not closed (expected `]]>`)", start, 9));
			if (mData[p] == '\r')
			{
				if (mFrames.Count > 0)
				{
					p++;
					continue;
				}
				if (!decoded)
				{
					decoded = true;
					mTextBuffer.Clear();
				}
				mTextBuffer.Append(View(runStart, p - runStart));
				mTextBuffer.Append('\n');
				p += At(p + 1) == '\n' ? 2 : 1;
				runStart = p;
				continue;
			}
			if (StartsWith(p, "]]>"))
			{
				end = p;
				p += 3;
				break;
			}
			p++;
		}
		if (decoded)
		{
			mTextBuffer.Append(View(runStart, end - runStart));
			mValue = mTextBuffer;
		}
		else
			mValue = View(runStart, end - runStart);
		if (mConfig.MaxTextBytes > 0 && mValue.Length > mConfig.MaxTextBytes)
			return .Err(Fail(.ResourceLimitExceeded, scope $"A CDATA section is longer than MaxTextBytes ({mConfig.MaxTextBytes})", start, 9));
		mPos = p;
		mNameId = .None;
		mName = default;
		mNamespace = .None;
		Report(start, p, mElements.Count);
		return XmlEvent.CData;
	}

	/// Whether an XML declaration starts at `pos`: `<?xml` then whitespace or `?` (`<?xml-stylesheet`
	/// is a processing instruction).
	bool IsXmlDeclarationStart(int pos)
	{
		if (!StartsWith(pos, "<?xml"))
			return false;
		char8 c = At(pos + 5);
		return XmlChar.IsSpace(c) || c == '?';
	}

	/// The XML declaration at mPos: `version`, then optionally `encoding` and `standalone`, in that order.
	Result<XmlEvent, XmlFailure> ReadXmlDeclaration()
	{
		int start = mPos;
		int p = start + 5;
		int ws = SkipSpace(p);
		if (ws == p || !StartsWith(ws, "version"))
			return .Err(Fail(.InvalidXmlDeclaration, "The XML declaration must start with `version`", ws));
		p = ws + 7;
		int valueStart = 0;
		StringView version = Try!(ReadPseudoAttribute(ref p, "version", out valueStart));
		if (version.Length < 3 || version[0] != '1' || version[1] != '.' || !AllDigits(version.Substring(2)))
			return .Err(Fail(.InvalidXmlDeclaration, scope $"The version `{version}` is not `1.` followed by digits", valueStart, version.Length));
		mVersion = version;
		mEncodingName = default;
		mStandalone = .Unspecified;
		ws = SkipSpace(p);
		if (StartsWith(ws, "encoding"))
		{
			if (ws == p)
				return .Err(Fail(.InvalidXmlDeclaration, "Expected whitespace before `encoding`", ws));
			p = ws + 8;
			StringView encoding = Try!(ReadPseudoAttribute(ref p, "encoding", out valueStart));
			if (!IsEncName(encoding))
				return .Err(Fail(.InvalidXmlDeclaration, scope $"The encoding name `{encoding}` is malformed (a letter, then letters, digits, `.`, `_` or `-`)", valueStart, Math.Max(encoding.Length, 1)));
			mEncodingName = encoding;
			ws = SkipSpace(p);
		}
		if (StartsWith(ws, "standalone"))
		{
			if (ws == p)
				return .Err(Fail(.InvalidXmlDeclaration, "Expected whitespace before `standalone`", ws));
			p = ws + 10;
			StringView standalone = Try!(ReadPseudoAttribute(ref p, "standalone", out valueStart));
			if (standalone == "yes")
				mStandalone = .Yes;
			else if (standalone == "no")
				mStandalone = .No;
			else
				return .Err(Fail(.InvalidXmlDeclaration, scope $"`standalone` must be `yes` or `no`, not `{standalone}`", valueStart, Math.Max(standalone.Length, 1)));
			ws = SkipSpace(p);
		}
		if (!StartsWith(ws, "?>"))
		{
			if (StartsWith(ws, "encoding") || StartsWith(ws, "version") || StartsWith(ws, "standalone"))
				return .Err(Fail(.InvalidXmlDeclaration, "The XML declaration's pseudo-attributes must be `version`, `encoding`, `standalone`, each at most once and in that order", ws));
			return .Err(Fail(.InvalidXmlDeclaration, "Expected `?>` to end the XML declaration (its pseudo-attributes are `version`, `encoding` and `standalone`, in that order)", ws));
		}
		mPos = ws + 2;
		mNameId = .None;
		mName = default;
		mNamespace = .None;
		mValue = default;
		Report(start, mPos, 0);
		return XmlEvent.XmlDeclaration;
	}

	/// After a pseudo-attribute's name: `S? = S?` and a quoted value. @return The value.
	Result<StringView, XmlFailure> ReadPseudoAttribute(ref int pos, StringView name, out int valueStart)
	{
		valueStart = 0;
		int p = SkipSpace(pos);
		if (At(p) != '=')
			return .Err(Fail(.InvalidXmlDeclaration, scope $"Expected `=` after `{name}`", p));
		p = SkipSpace(p + 1);
		char8 quote = At(p);
		if (quote != '"' && quote != '\'')
			return .Err(Fail(.InvalidXmlDeclaration, scope $"Expected a quoted value for `{name}`", p));
		p++;
		valueStart = p;
		while (Avail(p) && mData[p] != quote)
		{
			char8 c = mData[p];
			if (c == '?' || c == '>' || c == '<' || c == '"' || c == '\'')
				return .Err(Fail(.InvalidXmlDeclaration, scope $"The value of `{name}` is not closed by its quote", valueStart - 1));
			p++;
		}
		if (!Avail(p))
			return .Err(Fail(.UnexpectedEof, "The XML declaration is not closed", valueStart - 1));
		pos = p + 1;
		return View(valueStart, p - valueStart);
	}

	static bool AllDigits(StringView text)
	{
		if (text.IsEmpty)
			return false;
		for (let c in text)
		{
			if (c < '0' || c > '9')
				return false;
		}
		return true;
	}

	/// Whether `name` matches EncName ([81]): `[A-Za-z] ([A-Za-z0-9._] | '-')*`.
	static bool IsEncName(StringView name)
	{
		if (name.IsEmpty)
			return false;
		for (int i < name.Length)
		{
			char8 c = name[i];
			bool letter = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
			if (!letter && (i == 0 || !((c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-')))
				return false;
		}
		return true;
	}
}
