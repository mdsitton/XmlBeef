using System;
using System.Collections;
using internal XmlBeef;

namespace XmlBeef;

/// The DOCTYPE and its internal subset: entity, attribute-list, element and notation declarations,
/// parameter-entity references between declarations, comments and processing instructions.
extension XmlReaderCore<TCursor>
{
	/// A DOCTYPE at mPos (`<!DOCTYPE`): its name and external identifier. An internal subset is read
	/// by the next steps (StepInternalSubset); without one, the DocType event is reported now.
	Result<XmlEvent, XmlFailure> ReadDocType()
	{
		int start = mPos;
		if (mConfig.DtdMode == .Prohibit)
			return .Err(Fail(.DtdProhibited, "The document has a DOCTYPE, which XmlDtdMode.Prohibit does not allow", start, 9));
		mSeenDocType = true;
		mDtd.mPresent = true;
		mDocTypeStart = start;
		int p = Try!(RequireSpace(start + 9, "whitespace after `<!DOCTYPE`"));
		int nameStart = p;
		int nameEnd = Try!(ScanName(p, "the root element's name"));
		Try!(CheckQName(nameStart, nameEnd, "The DOCTYPE name"));
		mDocTypeName.Set(View(nameStart, nameEnd - nameStart));
		mDocTypePublicId.Clear();
		mDocTypeSystemId.Clear();
		mHasPublicId = false;
		mHasSystemId = false;
		mInternalSubset = default;
		p = nameEnd;
		int ws = SkipSpace(p);
		if (StartsWith(ws, "SYSTEM") || StartsWith(ws, "PUBLIC"))
		{
			if (ws == p)
				return .Err(Fail(.InvalidDeclaration, "Expected whitespace before the external identifier", ws));
			p = Try!(ReadExternalId(ws, false, let publicId, let systemId, out mHasPublicId, out mHasSystemId));
			mDocTypePublicId.Set(publicId);
			mDocTypeSystemId.Set(systemId);
			mDtd.mHasExternalSubset = true;
			ws = SkipSpace(p);
		}
		p = ws;
		if (At(p) == '[')
		{
			mSubsetStart = p + 1;
			mPos = p + 1;
			mState = .InternalSubset;
			// The whole subset stays in the window, for the DocType event's InternalSubset
			mRetain = mSubsetStart;
			return cNoEvent;
		}
		mSubsetStart = -1;
		return FinishDocType(p);
	}

	/// After the DOCTYPE's name, external identifier and internal subset: `>` and the DocType event.
	Result<XmlEvent, XmlFailure> FinishDocType(int pos)
	{
		if (At(pos) != '>')
			return .Err(Unexpected(pos, mSubsetStart < 0 ? "`[` or `>` in the DOCTYPE" : "`>` to end the DOCTYPE"));
		mPos = pos + 1;
		mState = .Prolog;
		// An undeclared entity in an ATTLIST default is an error only in some documents; now it is known
		if (mDtd.mUndeclaredInDefault >= 0 && EntityDeclaredIsWfc)
			return .Err(Fail(.UndeclaredEntity, "An attribute default refers to an entity that is not declared before it", mDtd.mUndeclaredInDefault, mDtd.mUndeclaredInDefaultLength));
		mNameId = .None;
		mName = mDocTypeName;
		mNamespace = .None;
		mValue = default;
		mPublicId = mDocTypePublicId;
		mSystemId = mDocTypeSystemId;
		Report(mDocTypeStart, mPos, 0);
		return XmlEvent.DocType;
	}

	/// One step in the internal subset: declarations, comments and parameter-entity references are
	/// read until a processing instruction (reported) or the subset's `]` (then the DocType event).
	Result<XmlEvent, XmlFailure> StepInternalSubset()
	{
		while (true)
		{
			int p = SkipSpace(mPos);
			mPos = p;
			if (!Avail(p))
			{
				if (mFrames.Count > 0)
				{
					Try!(PopFrame());
					continue;
				}
				return .Err(Fail(.UnexpectedEof, "The internal subset is not closed (expected `]`)", p, 0));
			}
			char8 c = mData[p];
			if (c == ']')
			{
				if (mFrames.Count > 0)
					return .Err(Fail(.InvalidDeclaration, "A parameter entity's replacement text cannot end the internal subset", p));
				mInternalSubset = View(mSubsetStart, p - mSubsetStart);
				return FinishDocType(SkipSpace(p + 1));
			}
			if (c == '%')
			{
				Try!(ParameterReference(p));
				continue;
			}
			if (c != '<')
				return .Err(Unexpected(p, "a markup declaration, comment, processing instruction, parameter-entity reference or `]`"));
			if (StartsWith(p, "<!--"))
				Try!(ReadComment(0));
			else if (At(p + 1) == '?')
				return ReadProcessingInstruction(0);
			else if (StartsWith(p, "<!ENTITY"))
				Try!(ReadEntityDeclaration());
			else if (StartsWith(p, "<!ATTLIST"))
				Try!(ReadAttlistDeclaration());
			else if (StartsWith(p, "<!ELEMENT"))
				Try!(ReadElementDeclaration());
			else if (StartsWith(p, "<!NOTATION"))
				Try!(ReadNotationDeclaration());
			else if (StartsWith(p, "<!["))
				return .Err(Fail(.InvalidDeclaration, "Conditional sections (`<![INCLUDE[`, `<![IGNORE[`) are only allowed in the external subset", p, 3));
			else
				return .Err(Fail(.InvalidDeclaration, "Expected a markup declaration (`<!ENTITY`, `<!ATTLIST`, `<!ELEMENT`, `<!NOTATION`), a comment or a processing instruction", p, 2));
		}
	}

	/// A parameter-entity reference between declarations at `pos` (`%`): an internal one's replacement
	/// text is read as declarations; an external or undeclared one is not read, and stops the
	/// processing of later declarations unless the document is standalone (§5.1).
	Result<void, XmlFailure> ParameterReference(int pos)
	{
		int nameEnd = Try!(ScanName(pos + 1, "a parameter-entity name after `%`"));
		if (At(nameEnd) != ';')
			return .Err(Fail(.InvalidReference, scope $"The parameter-entity reference `%{View(pos + 1, nameEnd - pos - 1)}` must end with `;`", pos, nameEnd - pos));
		StringView name = View(pos + 1, nameEnd - pos - 1);
		int end = nameEnd + 1;
		mPos = end;
		mDtd.mHasParameterReferences = true;
		if (mConfig.DtdMode != .Internal)
			return .Ok;
		if (!mDtd.mParameter.TryGetValue(name, let entity) || entity.IsExternal)
		{
			mDtd.mSkippedParameterEntity = true;
			return .Ok;
		}
		return PushFrame(entity, pos, end);
	}

	/// `<!ENTITY` at mPos: a general or parameter entity, internal (a quoted value) or external.
	Result<void, XmlFailure> ReadEntityDeclaration()
	{
		int start = mPos;
		int p = Try!(RequireSpace(start + 8, "whitespace after `<!ENTITY`"));
		bool parameter = false;
		if (At(p) == '%' && XmlChar.IsSpace(At(p + 1)))
		{
			parameter = true;
			p = SkipSpace(p + 1);
		}
		int nameStart = p;
		int nameEnd = Try!(ScanNameInDeclaration(p, "the entity's name"));
		Try!(CheckNoColon(nameStart, nameEnd, "The entity name"));
		p = Try!(RequireSpace(nameEnd, "whitespace after the entity's name"));
		XmlEntity entity = new .();
		bool kept = false;
		defer
		{
			if (!kept)
				delete entity;
		}
		entity.mName.Set(View(nameStart, nameEnd - nameStart));
		entity.mParameter = parameter;
		entity.mInParameterEntity = mFrames.Count > 0;
		char8 c = At(p);
		if (c == '"' || c == '\'')
		{
			entity.mValue = new .();
			if (parameter)
				entity.mValue.Append(' ');
			p = Try!(ReadEntityValue(p, entity.mValue));
			if (parameter)
				entity.mValue.Append(' ');
		}
		else if (StartsWith(p, "SYSTEM") || StartsWith(p, "PUBLIC"))
		{
			p = Try!(ReadExternalId(p, false, let publicId, let systemId, let hasPublic, let hasSystem));
			if (hasPublic)
				entity.mPublicId = new .(publicId);
			entity.mSystemId = new .(systemId);
			int ws = SkipSpace(p);
			if (StartsWith(ws, "NDATA"))
			{
				if (parameter)
					return .Err(Fail(.InvalidDeclaration, "A parameter entity cannot be unparsed (`NDATA`)", ws, 5));
				if (ws == p)
					return .Err(Fail(.InvalidDeclaration, "Expected whitespace before `NDATA`", ws));
				p = Try!(RequireSpace(ws + 5, "whitespace after `NDATA`"));
				int notationEnd = Try!(ScanNameInDeclaration(p, "a notation name after `NDATA`"));
				Try!(CheckNoColon(p, notationEnd, "The notation name"));
				entity.mNotation = new .(View(p, notationEnd - p));
				p = notationEnd;
			}
		}
		else
			return .Err(FailInDeclaration(p, "a quoted entity value, `SYSTEM` or `PUBLIC`"));
		p = SkipSpace(p);
		if (At(p) != '>')
			return .Err(FailInDeclaration(p, "`>` to end the entity declaration"));
		mPos = p + 1;
		// The first declaration of a name binds (§4.2)
		let table = parameter ? mDtd.mParameter : mDtd.mGeneral;
		if (ProcessDeclarations && !table.ContainsKey(entity.mName))
		{
			table[entity.mName] = entity;
			kept = true;
		}
		return .Ok;
	}

	/// A quoted entity value at `pos`, appended to `output` as replacement text: character references
	/// expanded, general entity references kept as written (§4.5). Parameter-entity references cannot
	/// occur here in the internal subset. @return The position after the closing quote.
	Result<int, XmlFailure> ReadEntityValue(int pos, String output)
	{
		char8 quote = mData[pos];
		int p = pos + 1;
		int runStart = p;
		while (true)
		{
			if (!Avail(p))
				return .Err(Fail(.UnexpectedEof, "The entity value is not closed", pos));
			char8 c = mData[p];
			if (c == quote)
			{
				output.Append(View(runStart, p - runStart));
				p++;
				break;
			}
			if (c == '%')
				return .Err(Fail(.InvalidEntityReference, "A parameter-entity reference cannot occur inside an entity value in the internal subset", p));
			if (c == '&')
			{
				output.Append(View(runStart, p - runStart));
				if (At(p + 1) == '#')
				{
					p = Try!(ReadCharReference(p, let cp));
					XmlChar.EncodeUtf8(output, cp);
				}
				else
				{
					// Bypassed: kept for when the entity is used
					int nameEnd = Try!(ScanReferenceName(p));
					output.Append(View(p, nameEnd + 1 - p));
					p = nameEnd + 1;
				}
				runStart = p;
				continue;
			}
			if (c == '\r' && mFrames.Count == 0)
			{
				output.Append(View(runStart, p - runStart));
				output.Append('\n');
				p += At(p + 1) == '\n' ? 2 : 1;
				runStart = p;
				continue;
			}
			p++;
		}
		if (mConfig.MaxTextBytes > 0 && output.Length > mConfig.MaxTextBytes)
			return .Err(Fail(.ResourceLimitExceeded, scope $"An entity value is longer than MaxTextBytes ({mConfig.MaxTextBytes})", pos, p - pos));
		return p;
	}

	/// `SYSTEM` SystemLiteral, or `PUBLIC` PubidLiteral SystemLiteral (the system literal optional when
	/// `publicOnly` allows it: a notation). The literals view the window. @return The position after it.
	Result<int, XmlFailure> ReadExternalId(int pos, bool publicOnly, out StringView publicId, out StringView systemId, out bool hasPublic, out bool hasSystem)
	{
		publicId = default;
		systemId = default;
		hasPublic = false;
		hasSystem = false;
		if (StartsWith(pos, "SYSTEM"))
		{
			int p = Try!(RequireSpace(pos + 6, "whitespace after `SYSTEM`"));
			p = Try!(ReadSystemLiteral(p, out systemId));
			hasSystem = true;
			return p;
		}
		int p = Try!(RequireSpace(pos + 6, "whitespace after `PUBLIC`"));
		p = Try!(ReadPubidLiteral(p, out publicId));
		hasPublic = true;
		int ws = SkipSpace(p);
		char8 c = At(ws);
		if (c == '"' || c == '\'')
		{
			if (ws == p)
				return .Err(Fail(.InvalidDeclaration, "Expected whitespace between the public identifier and the system literal", ws));
			p = Try!(ReadSystemLiteral(ws, out systemId));
			hasSystem = true;
			return p;
		}
		if (!publicOnly)
			return .Err(FailInDeclaration(ws, "the system literal after the public identifier"));
		return p;
	}

	Result<int, XmlFailure> ReadSystemLiteral(int pos, out StringView literal)
	{
		literal = default;
		char8 quote = At(pos);
		if (quote != '"' && quote != '\'')
			return .Err(FailInDeclaration(pos, "a quoted system literal"));
		int p = pos + 1;
		while (Avail(p) && mData[p] != quote)
			p++;
		if (!Avail(p))
			return .Err(Fail(.UnexpectedEof, "The system literal is not closed", pos));
		literal = View(pos + 1, p - pos - 1);
		return p + 1;
	}

	Result<int, XmlFailure> ReadPubidLiteral(int pos, out StringView literal)
	{
		literal = default;
		char8 quote = At(pos);
		if (quote != '"' && quote != '\'')
			return .Err(FailInDeclaration(pos, "a quoted public identifier"));
		int p = pos + 1;
		while (Avail(p) && mData[p] != quote)
		{
			if (!XmlChar.IsPubidChar(mData[p]))
				return .Err(Fail(.InvalidDeclaration, scope $"A public identifier cannot contain `{View(p, XmlChar.Utf8SequenceLength(mData[p]))}`", p));
			p++;
		}
		if (!Avail(p))
			return .Err(Fail(.UnexpectedEof, "The public identifier is not closed", pos));
		literal = View(pos + 1, p - pos - 1);
		return p + 1;
	}

	/// `<!ATTLIST` at mPos: attribute definitions for an element type. The first definition of an
	/// attribute binds (§3.3).
	Result<void, XmlFailure> ReadAttlistDeclaration()
	{
		int start = mPos;
		int p = Try!(RequireSpace(start + 9, "whitespace after `<!ATTLIST`"));
		int nameEnd = Try!(ScanNameInDeclaration(p, "the element type's name"));
		Try!(CheckQName(p, nameEnd, "The element type name"));
		XmlNameId element = mNames.Intern(View(p, nameEnd - p));
		p = nameEnd;
		bool process = ProcessDeclarations;
		while (true)
		{
			int ws = SkipSpace(p);
			if (At(ws) == '>')
			{
				mPos = ws + 1;
				return .Ok;
			}
			if (ws == p)
				return .Err(FailInDeclaration(ws, "whitespace or `>`"));
			p = ws;
			int attrEnd = Try!(ScanNameInDeclaration(p, "an attribute name or `>`"));
			Try!(CheckQName(p, attrEnd, "The attribute name"));
			XmlAttributeDecl declaration = default;
			declaration.mName = mNames.Intern(View(p, attrEnd - p));
			p = Try!(RequireSpace(attrEnd, "whitespace after the attribute name"));
			p = Try!(ReadAttributeType(p, out declaration.mType));
			p = Try!(RequireSpace(p, "whitespace before the attribute's default"));
			if (StartsWith(p, "#REQUIRED"))
			{
				declaration.mDefault = .Required;
				p += 9;
			}
			else if (StartsWith(p, "#IMPLIED"))
			{
				declaration.mDefault = .Implied;
				p += 8;
			}
			else
			{
				declaration.mDefault = .Value;
				if (StartsWith(p, "#FIXED"))
				{
					declaration.mDefault = .Fixed;
					p = Try!(RequireSpace(p + 6, "whitespace after `#FIXED`"));
				}
				char8 quote = At(p);
				if (quote != '"' && quote != '\'')
					return .Err(FailInDeclaration(p, "`#REQUIRED`, `#IMPLIED`, `#FIXED` or a quoted default value"));
				int expandedBefore = mExpandedBytes;
				mScratch.Clear();
				p = Try!(ReadAttributeValue(p, mScratch, let view, let bufferStart));
				StringView value = bufferStart >= 0 ? StringView(mScratch) : view;
				if (declaration.mType != .CData)
				{
					let normalized = scope String();
					CollapseSpaces(value, normalized);
					declaration.mDefaultValue = mDtd.Own(normalized);
				}
				else
					declaration.mDefaultValue = mDtd.Own(value);
				declaration.mExpanded = mExpandedBytes != expandedBefore;
			}
			if (!process)
				continue;
			List<XmlAttributeDecl> list;
			if (!mDtd.mAttributes.TryGetValue(element, out list))
			{
				list = new .();
				mDtd.mAttributes[element] = list;
			}
			bool declared = false;
			for (let existing in list)
			{
				if (existing.mName == declaration.mName)
				{
					declared = true;
					break;
				}
			}
			if (!declared)
				list.Add(declaration);
		}
	}

	/// An attribute type at `pos`: a keyword, `NOTATION (…)` or an enumeration `(…)`.
	Result<int, XmlFailure> ReadAttributeType(int pos, out XmlAttributeType type)
	{
		type = .CData;
		if (At(pos) == '(')
		{
			type = .Enumeration;
			return ReadNameGroup(pos, true);
		}
		int p = pos;
		while (Avail(p) && mData[p] >= 'A' && mData[p] <= 'Z')
			p++;
		switch (View(pos, p - pos))
		{
		case "CDATA": type = .CData;
		case "ID": type = .Id;
		case "IDREF": type = .IdRef;
		case "IDREFS": type = .IdRefs;
		case "ENTITY": type = .Entity;
		case "ENTITIES": type = .Entities;
		case "NMTOKEN": type = .NmToken;
		case "NMTOKENS": type = .NmTokens;
		case "NOTATION":
			type = .Notation;
			p = Try!(RequireSpace(p, "whitespace after `NOTATION`"));
			if (At(p) != '(')
				return .Err(FailInDeclaration(p, "`(` and the notation names"));
			return ReadNameGroup(p, false);
		default:
			return .Err(FailInDeclaration(pos, "an attribute type (`CDATA`, `ID`, `IDREF`, `IDREFS`, `ENTITY`, `ENTITIES`, `NMTOKEN`, `NMTOKENS`, `NOTATION` or an enumeration)"));
		}
		return p;
	}

	/// `( S? x (S? '|' S? x)* S? )` at `pos`, x a Nmtoken (an enumeration) or a Name (notations).
	Result<int, XmlFailure> ReadNameGroup(int pos, bool tokens)
	{
		int p = pos + 1;
		while (true)
		{
			p = SkipSpace(p);
			if (tokens)
			{
				int tokenStart = p;
				while (IsNameCharAt(p))
				{
					DecodeAt(p, let length);
					p += length;
				}
				if (p == tokenStart)
					return .Err(FailInDeclaration(p, "a name token in the enumeration"));
			}
			else
				p = Try!(ScanNameInDeclaration(p, "a notation name"));
			p = SkipSpace(p);
			char8 c = At(p);
			if (c == ')')
				return p + 1;
			if (c != '|')
				return .Err(FailInDeclaration(p, "`|` or `)`"));
			p++;
		}
	}

	/// `<!ELEMENT` at mPos: the content model's syntax is checked (no validation).
	Result<void, XmlFailure> ReadElementDeclaration()
	{
		int start = mPos;
		int p = Try!(RequireSpace(start + 9, "whitespace after `<!ELEMENT`"));
		int nameEnd = Try!(ScanNameInDeclaration(p, "the element type's name"));
		Try!(CheckQName(p, nameEnd, "The element type name"));
		p = Try!(RequireSpace(nameEnd, "whitespace after the element type's name"));
		if (StartsWith(p, "EMPTY"))
			p += 5;
		else if (StartsWith(p, "ANY"))
			p += 3;
		else if (At(p) == '(')
			p = Try!(ReadContentModel(p));
		else
			return .Err(FailInDeclaration(p, "`EMPTY`, `ANY` or a content model in parentheses"));
		p = SkipSpace(p);
		if (At(p) != '>')
			return .Err(FailInDeclaration(p, "`>` to end the element declaration"));
		mPos = p + 1;
		return .Ok;
	}

	/// A content model at `pos` (`(`): mixed content (`(#PCDATA | a)*`) or element content (nested
	/// choices and sequences with `?`, `*`, `+`), read without recursion.
	Result<int, XmlFailure> ReadContentModel(int pos)
	{
		int p = SkipSpace(pos + 1);
		if (StartsWith(p, "#PCDATA"))
		{
			p += 7;
			bool names = false;
			while (true)
			{
				p = SkipSpace(p);
				char8 c = At(p);
				if (c == '|')
				{
					p = SkipSpace(p + 1);
					p = Try!(ScanNameInDeclaration(p, "an element name"));
					names = true;
					continue;
				}
				if (c == ')')
				{
					p++;
					if (At(p) == '*')
						return p + 1;
					if (names)
						return .Err(FailInDeclaration(p, "`*` after a mixed content model with element names (`(#PCDATA | a)*`)"));
					return p;
				}
				return .Err(FailInDeclaration(p, "`|` or `)` in the mixed content model"));
			}
		}
		// Element content: the separator of each open group (0 until its second item)
		let groups = scope List<char8>();
		groups.Add(0);
		bool expectItem = true;
		while (true)
		{
			p = SkipSpace(p);
			if (expectItem)
			{
				if (At(p) == '(')
				{
					groups.Add(0);
					p++;
					continue;
				}
				p = Try!(ScanNameInDeclaration(p, "an element name or `(` in the content model"));
				p = SkipOccurrence(p);
				expectItem = false;
				continue;
			}
			char8 c = At(p);
			if (c == '|' || c == ',')
			{
				ref char8 separator = ref groups.Back;
				if (separator == 0)
					separator = c;
				else if (separator != c)
					return .Err(Fail(.InvalidDeclaration, "A content model group cannot mix `|` and `,`", p));
				p++;
				expectItem = true;
				continue;
			}
			if (c == ')')
			{
				p = SkipOccurrence(p + 1);
				groups.PopBack();
				if (groups.Count == 0)
					return p;
				continue;
			}
			return .Err(FailInDeclaration(p, "`|`, `,` or `)` in the content model"));
		}
	}

	[Inline]
	int SkipOccurrence(int pos)
	{
		char8 c = At(pos);
		return (c == '?' || c == '*' || c == '+') ? pos + 1 : pos;
	}

	/// `<!NOTATION` at mPos.
	Result<void, XmlFailure> ReadNotationDeclaration()
	{
		int start = mPos;
		int p = Try!(RequireSpace(start + 10, "whitespace after `<!NOTATION`"));
		int nameEnd = Try!(ScanNameInDeclaration(p, "the notation's name"));
		Try!(CheckNoColon(p, nameEnd, "The notation name"));
		// Copies: reading on may move a stream's buffer
		let name = scope String(View(p, nameEnd - p));
		p = Try!(RequireSpace(nameEnd, "whitespace after the notation's name"));
		if (!StartsWith(p, "SYSTEM") && !StartsWith(p, "PUBLIC"))
			return .Err(FailInDeclaration(p, "`SYSTEM` or `PUBLIC`"));
		p = Try!(ReadExternalId(p, true, let publicView, let systemView, let hasPublic, let hasSystem));
		let publicId = scope String(publicView);
		let systemId = scope String(systemView);
		p = SkipSpace(p);
		if (At(p) != '>')
			return .Err(FailInDeclaration(p, "`>` to end the notation declaration"));
		mPos = p + 1;
		if (mConfig.DtdMode != .Internal || mDtd.FindNotation(name) != null)
			return .Ok;
		XmlNotation notation;
		notation.mName = mDtd.Own(name);
		let normalized = scope String();
		for (let part in publicId.Split(' ', '\t', '\n', '\r'))
		{
			if (part.IsEmpty)
				continue;
			if (!normalized.IsEmpty)
				normalized.Append(' ');
			normalized.Append(part);
		}
		notation.mPublicId = mDtd.Own(normalized);
		notation.mSystemId = mDtd.Own(systemId);
		notation.mHasPublicId = hasPublic;
		notation.mHasSystemId = hasSystem;
		mDtd.mNotations.Add(notation);
		return .Ok;
	}

	/// Whitespace is required at `pos`. @return The position after it.
	Result<int, XmlFailure> RequireSpace(int pos, StringView expected)
	{
		if (!XmlChar.IsSpace(At(pos)))
			return .Err(FailInDeclaration(pos, expected));
		return SkipSpace(pos);
	}

	/// A name in a declaration (a `%` there is a parameter-entity reference, not allowed in the internal
	/// subset).
	Result<int, XmlFailure> ScanNameInDeclaration(int pos, StringView expected)
	{
		if (At(pos) == '%')
			return .Err(FailInDeclaration(pos, expected));
		return ScanName(pos, expected);
	}

	/// The error for something unexpected inside a declaration, worded for a parameter-entity reference.
	XmlFailure FailInDeclaration(int pos, StringView expected)
	{
		if (At(pos) == '%')
			return Fail(.InvalidEntityReference, "A parameter-entity reference cannot occur inside a markup declaration in the internal subset", pos);
		return Unexpected(pos, expected);
	}

	/// With namespaces: a name in the DTD that names elements or attributes must be a qualified name.
	Result<void, XmlFailure> CheckQName(int start, int end, StringView what)
	{
		if (!mConfig.Namespaces)
			return .Ok;
		XmlNameId id = mNames.Intern(View(start, end - start));
		if (!mNames.IsQName(id))
			return .Err(Fail(.InvalidQName, scope $"{what} `{mNames[id]}` is not a valid qualified name (one colon between a prefix and a local name)", start, end - start));
		return .Ok;
	}
}
