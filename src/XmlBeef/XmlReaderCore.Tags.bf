using System;
using System.Collections;
using internal XmlBeef;

namespace XmlBeef;

/// Start and end tags: attributes, their normalization and defaults, and namespaces.
extension XmlReaderCore<TCursor>
{
	/// Bytes that end a plain attribute value: either quote, `<`, `&`, and those below 0x20 (tab, LF,
	/// CR: other controls cannot be in the input).
	static uint8[256] sValueByte = BuildValueByte();

	static uint8[256] BuildValueByte()
	{
		uint8[256] table = default;
		for (int i < 0x20)
			table[i] = 1;
		table['"'] = 1;
		table['\''] = 1;
		table['<'] = 1;
		table['&'] = 1;
		return table;
	}

	/// A start tag or empty-element tag at mPos (`<` then a name).
	Result<XmlEvent, XmlFailure> ReadStartTag()
	{
		int start = mPos;
		// Collect-errors: for recovery from an error in the tag (cleared when it is reported)
		if (mConfig.CollectErrors)
		{
			mTagStart = start;
			mTagFrames = mFrames.Count;
		}
		int nameEnd = Try!(ScanAsciiName(start + 1, "an element name after `<`"));
		XmlNameId name = mNames.InternCached(View(start + 1, nameEnd - start - 1));
		int p = nameEnd;
		mAttributes.Clear();
		mAttributeBuffer.Clear();
		// Whether namespace processing has anything to do: a prefix, or a declaration
		mNamespaceWork = mNames.HasColon(name);
		bool empty = false;
		while (true)
		{
			int spaceStart = p;
			p = SkipSpace(p);
			if (!Avail(p))
				return .Err(Fail(.UnexpectedEof, scope $"The start tag of `{mNames[name]}` is not closed (expected `>` or `/>`)", start, nameEnd - start));
			char8 c = mData[p];
			if (c == '>')
			{
				p++;
				break;
			}
			if (c == '/')
			{
				if (At(p + 1) != '>')
					return .Err(Unexpected(p + 1, "`>` after `/` (`/>` ends an empty element)"));
				p += 2;
				empty = true;
				break;
			}
			if (p == spaceStart)
			{
				uint8 cls = XmlChar.NameByteClass(c);
				if (cls == XmlChar.cNameStart || (cls == XmlChar.cNameDecode && XmlChar.IsNameStartChar(DecodeAt(p, let length))))
					return .Err(Fail(.UnexpectedChar, "Attributes must be separated by whitespace", p));
				return .Err(Unexpected(p, "whitespace, `>` or `/>`"));
			}
			if (mConfig.MaxAttributesPerElement > 0 && mAttributes.Count >= mConfig.MaxAttributesPerElement)
				return .Err(Fail(.ResourceLimitExceeded, scope $"The element has more attributes than MaxAttributesPerElement ({mConfig.MaxAttributesPerElement})", p));
			int attrEnd = Try!(ScanAsciiName(p, "an attribute name, `>` or `/>`"));
			ref AttributeRecord attribute = ref mAttributes.AddDefault();
			attribute.mName = mNames.InternCached(View(p, attrEnd - p));
			attribute.mOffset = (int32)DocOffset(p);
			attribute.mSpecified = true;
			if (attribute.mName == mXmlnsPrefix || mNames.HasColon(attribute.mName))
				mNamespaceWork = true;
			p = SkipSpace(attrEnd);
			if (At(p) != '=')
				return .Err(Unexpected(p, scope $"`=` after the attribute name `{mNames[attribute.mName]}`"));
			p = SkipSpace(p + 1);
			char8 quote = At(p);
			if (quote != '"' && quote != '\'')
				return .Err(Unexpected(p, "a quoted attribute value (`\"…\"` or `'…'`)"));
			// The common case inline: a value without references or whitespace that ends in the window
			int valueStart = p + 1;
			int q = valueStart;
			while (q + 8 <= mEnd)
			{
				uint64 word = XmlChar.Load64(mData + q);
				if ((XmlChar.BytesEqual(word, (uint8)quote) | XmlChar.BytesEqual(word, (uint8)'<') | XmlChar.BytesEqual(word, (uint8)'&') | XmlChar.BytesBelowSpace(word)) != 0)
					break;
				q += 8;
			}
			while (q < mEnd && sValueByte[(uint8)mData[q]] == 0)
				q++;
			if (q < mEnd && mData[q] == quote && (mConfig.MaxTextBytes <= 0 || q - valueStart <= mConfig.MaxTextBytes))
			{
				attribute.mValue = View(valueStart, q - valueStart);
				attribute.mBufferStart = -1;
				p = q + 1;
				attribute.mEnd = (int32)DocEnd(p);
				continue;
			}
			p = Try!(ReadAttributeValue(p, mAttributeBuffer, out attribute.mValue, let bufferStart));
			attribute.mBufferStart = (int32)bufferStart;
			attribute.mBufferLength = bufferStart >= 0 ? (int32)(mAttributeBuffer.Length - bufferStart) : 0;
			attribute.mEnd = (int32)DocEnd(p);
		}
		mPos = p;
		if (mAttributes.Count > 1)
			Try!(CheckDuplicateAttributes());
		if (mConfig.DtdMode == .Internal && mDtd.mAttributes.Count > 0)
		{
			let declarations = mDtd.GetAttributes(name);
			if (declarations != null)
				Try!(ApplyDeclarations(declarations, start));
		}
		if (mAttributeBuffer.Length > 0)
		{
			for (int i < mAttributes.Count)
			{
				ref AttributeRecord attribute = ref mAttributes[i];
				if (attribute.mBufferStart >= 0)
					attribute.mValue = StringView(mAttributeBuffer.Ptr + attribute.mBufferStart, attribute.mBufferLength);
			}
		}
		int bindingStart = mBindings.Count;
		XmlNameId ns = .None;
		if (mConfig.Namespaces)
		{
			if (mNamespaceWork)
				ns = Try!(ResolveNamespaces(name, start + 1, nameEnd));
			else if (mBindings.Count > 0)
				ns = DefaultNamespace();
		}
		if (mConfig.MaxDepth > 0 && mElements.Count >= mConfig.MaxDepth)
			return .Err(Fail(.ResourceLimitExceeded, scope $"Elements are nested deeper than MaxDepth ({mConfig.MaxDepth})", start, nameEnd - start));
		if (mConfig.MaxNodes > 0 && ++mElementCount > mConfig.MaxNodes)
			return .Err(Fail(.ResourceLimitExceeded, scope $"The document has more elements than MaxNodes ({mConfig.MaxNodes})", start, nameEnd - start));
		ref Element element = ref mElements.AddDefault();
		element.mName = name;
		element.mNamespace = ns;
		element.mFrameLevel = (int32)mFrames.Count;
		element.mBindings = (int32)bindingStart;
		element.mStart = (int32)DocOffset(start);
		// A stream cannot look back for the unclosed-element error at the end: locate it now
		if (mCursor.LocatesOnlyForward && mCursor.Locate(element.mStart, let line, let column))
		{
			element.mLine = (int32)line;
			element.mColumn = (int32)column;
		}
		mNameId = name;
		mName = mNames[name];
		mNamespace = ns;
		mIsEmpty = empty;
		mPendingEnd = empty;
		if (mConfig.CollectErrors)
			mTagStart = -1;
		Report(start, p, mElements.Count - 1);
		return XmlEvent.StartElement;
	}

	/// An end tag at mPos (`</`): it must name the innermost open element, in the same entity.
	Result<XmlEvent, XmlFailure> ReadEndTag()
	{
		int start = mPos;
		int p = start + 2;
		let open = mElements.Back;
		StringView name = mNames[open.mName];
		if (!StartsWith(p, name) || IsNameCharAt(p + name.Length))
		{
			int actualEnd = Try!(ScanName(p, "an element name after `</`"));
			// Collect-errors: the end tag of a start tag that failed (and was skipped) goes quietly
			if (mConfig.CollectErrors && DropPhantomEndTag(start, View(p, actualEnd - p)))
				return cNoEvent;
			return .Err(Fail(.MismatchedEndTag, scope $"The end tag `</{View(p, actualEnd - p)}>` does not match the start tag `<{name}>`", start, actualEnd - start));
		}
		if (open.mFrameLevel != mFrames.Count)
			return .Err(Fail(.MismatchedEndTag, scope $"The end tag of `{name}` is not in the same entity as its start tag", start, 2 + name.Length));
		p = SkipSpace(p + name.Length);
		if (At(p) != '>')
			return .Err(Unexpected(p, scope $"`>` to close the end tag of `{name}`"));
		p++;
		mPos = p;
		return EndElement(DocOffset(start), DocEnd(p));
	}

	/// Reads a quoted attribute value at `pos` (its opening quote), normalized (§3.3.3: literal
	/// whitespace to spaces, references expanded). @return The position after the closing quote; the
	/// value is `view` (a view of the input: nothing needed decoding, `bufferStart` is -1) or the text
	/// appended to `buffer` from `bufferStart`.
	Result<int, XmlFailure> ReadAttributeValue(int pos, String buffer, out StringView view, out int bufferStart)
	{
		view = default;
		bufferStart = -1;
		char8 quote = mData[pos];
		int p = pos + 1;
		int runStart = p;
		// Fast path: plain text up to the quote is a view. Words without the quote, `<`, `&` or a byte
		// below 0x20 (tab, LF and CR: other controls cannot be in the input) are skipped whole.
		while (p + 8 <= mEnd)
		{
			uint64 word = XmlChar.Load64(mData + p);
			if ((XmlChar.BytesEqual(word, (uint8)quote) | XmlChar.BytesEqual(word, (uint8)'<') | XmlChar.BytesEqual(word, (uint8)'&') | XmlChar.BytesBelowSpace(word)) != 0)
				break;
			p += 8;
		}
		while (true)
		{
			if (p >= mEnd && !Grow(p, 1))
				break;
			char8 c = mData[p];
			if (c == quote)
			{
				view = View(runStart, p - runStart);
				if (mConfig.MaxTextBytes > 0 && view.Length > mConfig.MaxTextBytes)
					return .Err(Fail(.ResourceLimitExceeded, scope $"An attribute value is longer than MaxTextBytes ({mConfig.MaxTextBytes})", pos, p - pos));
				return p + 1;
			}
			if (c == '<' || c == '&' || c == '\t' || c == '\n' || c == '\r')
				break;
			p++;
		}
		bufferStart = buffer.Length;
		buffer.Append(View(runStart, p - runStart));
		int level = mFrames.Count;
		while (true)
		{
			if (!Avail(p))
			{
				if (mFrames.Count > level)
				{
					mPos = p;
					Try!(PopFrame());
					p = mPos;
					continue;
				}
				return .Err(Fail(.UnexpectedEof, "The attribute value is not closed", pos));
			}
			char8 c = mData[p];
			switch (c)
			{
			case '<':
				if (mFrames.Count > level)
					return .Err(Fail(.UnexpectedChar, "The replacement text contains `<`, which an attribute value cannot (No < in Attribute Values)", p));
				return .Err(Fail(.UnexpectedChar, "`<` is not allowed in an attribute value; write `&lt;`", p));
			case '\t', '\n':
				buffer.Append(' ');
				p++;
			case '\r':
				buffer.Append(' ');
				// Line ends are normalized in the document, not in replacement text (a CR from `&#13;`)
				p += (mFrames.Count == 0 && At(p + 1) == '\n') ? 2 : 1;
			case '&':
				p = Try!(AttributeReference(p, buffer));
			default:
				if (c == quote && mFrames.Count == level)
				{
					p++;
					if (mConfig.MaxTextBytes > 0 && buffer.Length - bufferStart > mConfig.MaxTextBytes)
						return .Err(Fail(.ResourceLimitExceeded, scope $"An attribute value is longer than MaxTextBytes ({mConfig.MaxTextBytes})", pos, p - pos));
					return p;
				}
				// A run of plain text (inside replacement text, either quote is data)
				int run = p;
				p++;
				while (Avail(p))
				{
					char8 d = mData[p];
					if (d == '<' || d == '&' || d == '\t' || d == '\n' || d == '\r' || (d == quote && mFrames.Count == level))
						break;
					p++;
				}
				buffer.Append(View(run, p - run));
				if (mConfig.MaxTextBytes > 0 && buffer.Length - bufferStart > mConfig.MaxTextBytes)
					return .Err(Fail(.ResourceLimitExceeded, scope $"An attribute value is longer than MaxTextBytes ({mConfig.MaxTextBytes})", pos, p - pos));
			}
		}
	}

	/// A reference in an attribute value at `pos` (`&`): a character is appended; an internal entity's
	/// replacement text is pushed (read on by ReadAttributeValue). @return Where to go on.
	Result<int, XmlFailure> AttributeReference(int pos, String buffer)
	{
		if (At(pos + 1) == '#')
		{
			int end = Try!(ReadCharReference(pos, let cp));
			XmlChar.EncodeUtf8(buffer, cp);
			return end;
		}
		int nameEnd = Try!(ScanReferenceName(pos));
		StringView name = View(pos + 1, nameEnd - pos - 1);
		int end = nameEnd + 1;
		char8 predefined = PredefinedEntity(name);
		if (predefined != 0)
		{
			buffer.Append(predefined);
			return end;
		}
		XmlEntity entity = Try!(LookupGeneral(name, pos, end));
		if (entity == null)
			return end;
		if (entity.IsExternal)
			return .Err(Fail(.InvalidEntityReference, scope $"An attribute value cannot refer to the external entity `{name}`", pos, end - pos));
		Try!(PushFrame(entity, pos, end));
		return mPos;
	}

	/// The general entity a reference names (the predefined five are handled before). @return The
	/// entity; null for an undeclared one where that is no well-formedness error (the reference is
	/// skipped); an error where it is, or for an unparsed entity.
	Result<XmlEntity, XmlFailure> LookupGeneral(StringView name, int refStart, int refEnd)
	{
		if (mConfig.DtdMode == .Internal && mDtd.mGeneral.TryGetValue(name, let entity))
		{
			if (entity.IsUnparsed)
				return .Err(Fail(.InvalidEntityReference, scope $"The unparsed entity `{name}` cannot be referenced; it can only be named in an ENTITY attribute", refStart, refEnd - refStart));
			if (entity.mInParameterEntity && mStandalone == .Yes)
				return .Err(Fail(.UndeclaredEntity, scope $"The entity `{name}` is declared in a parameter entity, which a standalone document cannot refer to", refStart, refEnd - refStart));
			return entity;
		}
		if (mState == .InternalSubset)
		{
			// An ATTLIST default: whether this is an error depends on the rest of the DTD
			if (mStandalone == .Yes)
				return .Err(Fail(.UndeclaredEntity, scope $"The entity `{name}` is not declared before its use", refStart, refEnd - refStart));
			if (mDtd.mUndeclaredInDefault < 0 && mFrames.Count == 0)
			{
				mDtd.mUndeclaredInDefault = refStart;
				mDtd.mUndeclaredInDefaultLength = refEnd - refStart;
			}
			return (XmlEntity)null;
		}
		if (EntityDeclaredIsWfc)
			return .Err(Fail(.UndeclaredEntity, scope $"The entity `{name}` is not declared", refStart, refEnd - refStart));
		return (XmlEntity)null;
	}

	/// Checks Unique Att Spec by name: pairwise for few attributes, with a set for many.
	Result<void, XmlFailure> CheckDuplicateAttributes()
	{
		int count = mAttributes.Count;
		if (count < 2)
			return .Ok;
		if (count <= 16)
		{
			for (int i = 1; i < count; i++)
			{
				XmlNameId name = mAttributes[i].mName;
				for (int j < i)
				{
					if (mAttributes[j].mName == name)
						return .Err(DuplicateAttribute(i));
				}
			}
			return .Ok;
		}
		mSeenNames.Clear();
		for (int i < count)
		{
			if (!mSeenNames.Add(mAttributes[i].mName))
				return .Err(DuplicateAttribute(i));
		}
		return .Ok;
	}

	XmlFailure DuplicateAttribute(int index)
	{
		let attribute = mAttributes[index];
		return Fail(.DuplicateAttribute, scope $"The attribute `{mNames[attribute.mName]}` appears more than once on this element", attribute.mOffset, mNames[attribute.mName].Length);
	}

	/// Applies the element type's ATTLIST declarations: declared types normalize specified values, and
	/// defaults are added for attributes the tag omits (§3.3.2, §3.3.3).
	Result<void, XmlFailure> ApplyDeclarations(List<XmlAttributeDecl> declarations, int tagStart)
	{
		for (let declaration in declarations)
		{
			int index = -1;
			for (int i < mAttributes.Count)
			{
				if (mAttributes[i].mName == declaration.mName)
				{
					index = i;
					break;
				}
			}
			if (index >= 0)
			{
				if (declaration.mType != .CData)
					NormalizeTokens(ref mAttributes[index]);
				continue;
			}
			if (declaration.mDefault != .Value && declaration.mDefault != .Fixed)
				continue;
			if (mConfig.MaxAttributesPerElement > 0 && mAttributes.Count >= mConfig.MaxAttributesPerElement)
				return .Err(Fail(.ResourceLimitExceeded, scope $"The element has more attributes than MaxAttributesPerElement ({mConfig.MaxAttributesPerElement})", tagStart));
			if (declaration.mExpanded)
				Try!(CountExpansion(declaration.mDefaultValue.Length, tagStart, 1));
			AttributeRecord attribute = default;
			attribute.mName = declaration.mName;
			attribute.mValue = declaration.mDefaultValue;
			attribute.mBufferStart = -1;
			attribute.mOffset = (int32)DocOffset(tagStart);
			attribute.mSpecified = false;
			mAttributes.Add(attribute);
			if (attribute.mName == mXmlnsPrefix || mNames.HasColon(attribute.mName))
				mNamespaceWork = true;
		}
		return .Ok;
	}

	/// Trims spaces from both ends of the value and collapses runs of them (a non-CDATA type).
	void NormalizeTokens(ref AttributeRecord attribute)
	{
		StringView value = attribute.mBufferStart >= 0 ? StringView(mAttributeBuffer.Ptr + attribute.mBufferStart, attribute.mBufferLength) : attribute.mValue;
		mScratch.Clear();
		CollapseSpaces(value, mScratch);
		if (mScratch.Length == value.Length)
			return;
		attribute.mBufferStart = (int32)mAttributeBuffer.Length;
		attribute.mBufferLength = (int32)mScratch.Length;
		mAttributeBuffer.Append(mScratch);
	}

	/// Appends `value` with leading and trailing spaces removed and runs of spaces collapsed to one
	/// (only U+0020: a tab from `&#9;` is kept).
	static void CollapseSpaces(StringView value, String output)
	{
		bool pending = false;
		for (let c in value)
		{
			if (c == ' ')
			{
				pending = output.Length > 0;
				continue;
			}
			if (pending)
			{
				output.Append(' ');
				pending = false;
			}
			output.Append(c);
		}
	}

	/// Namespace processing for the current start tag: binds its declarations, checks every name, and
	/// resolves the element's and attributes' namespaces. @return The element's namespace.
	Result<XmlNameId, XmlFailure> ResolveNamespaces(XmlNameId element, int nameStart, int nameEnd)
	{
		for (int i < mAttributes.Count)
		{
			let attribute = mAttributes[i];
			if (attribute.mName == mXmlnsPrefix)
			{
				StringView uri = attribute.mValue;
				if (uri == cXmlNamespace || uri == cXmlnsNamespace)
					return .Err(Fail(.InvalidNamespaceDeclaration, scope $"The default namespace cannot be `{uri}`", attribute.mOffset, 5));
				Binding binding;
				binding.mPrefix = .None;
				binding.mUri = uri.IsEmpty ? .None : mNames.Intern(uri);
				Try!(AddBinding(binding, attribute.mOffset));
				continue;
			}
			if (!mNames.HasColon(attribute.mName))
				continue;
			if (!mNames.IsQName(attribute.mName))
				return .Err(Fail(.InvalidQName, scope $"The attribute name `{mNames[attribute.mName]}` is not a valid qualified name (one colon between a prefix and a local name)", attribute.mOffset, mNames[attribute.mName].Length));
			if (mNames.PrefixOf(attribute.mName) != mXmlnsPrefix)
				continue;
			XmlNameId prefix = mNames.LocalOf(attribute.mName);
			StringView uri = attribute.mValue;
			int length = mNames[attribute.mName].Length;
			if (prefix == mXmlnsPrefix)
				return .Err(Fail(.InvalidNamespaceDeclaration, "The prefix `xmlns` cannot be declared", attribute.mOffset, length));
			if (prefix == mXmlPrefix)
			{
				if (uri != cXmlNamespace)
					return .Err(Fail(.InvalidNamespaceDeclaration, scope $"The prefix `xml` can only be bound to `{cXmlNamespace}`", attribute.mOffset, length));
				continue;
			}
			if (uri.IsEmpty)
				return .Err(Fail(.InvalidNamespaceDeclaration, scope $"The prefix `{mNames[prefix]}` cannot be undeclared (`xmlns:{mNames[prefix]}=\"\"`) in XML 1.0", attribute.mOffset, length));
			if (uri == cXmlNamespace || uri == cXmlnsNamespace)
				return .Err(Fail(.InvalidNamespaceDeclaration, scope $"The prefix `{mNames[prefix]}` cannot be bound to `{uri}`", attribute.mOffset, length));
			Binding binding;
			binding.mPrefix = prefix;
			binding.mUri = mNames.Intern(uri);
			Try!(AddBinding(binding, attribute.mOffset));
		}

		if (!mNames.IsQName(element))
			return .Err(Fail(.InvalidQName, scope $"The element name `{mNames[element]}` is not a valid qualified name (one colon between a prefix and a local name)", nameStart, nameEnd - nameStart));
		XmlNameId ns = Try!(ResolvePrefix(mNames.PrefixOf(element), true, nameStart, nameEnd - nameStart));

		int prefixed = 0;
		for (int i < mAttributes.Count)
		{
			ref AttributeRecord attribute = ref mAttributes[i];
			attribute.mLocal = attribute.mName;
			if (attribute.mName == mXmlnsPrefix)
			{
				attribute.mNamespace = mXmlnsUri;
				continue;
			}
			if (!mNames.HasColon(attribute.mName))
				continue;
			if (!mNames.IsQName(attribute.mName))
				return .Err(Fail(.InvalidQName, scope $"The attribute name `{mNames[attribute.mName]}` is not a valid qualified name (one colon between a prefix and a local name)", attribute.mOffset, mNames[attribute.mName].Length));
			attribute.mPrefix = mNames.PrefixOf(attribute.mName);
			attribute.mLocal = mNames.LocalOf(attribute.mName);
			attribute.mNamespace = Try!(ResolvePrefix(attribute.mPrefix, false, attribute.mOffset, mNames[attribute.mName].Length));
			prefixed++;
		}
		if (prefixed > 16)
		{
			// Attributes Unique, for many: a set of (namespace, local name), remembering the first
			mSeenExpanded.Clear();
			for (int i < mAttributes.Count)
			{
				let a = mAttributes[i];
				if (!a.mPrefix.IsValid)
					continue;
				uint64 key = ((uint64)a.mNamespace.mValue << 32) | a.mLocal.mValue;
				if (mSeenExpanded.TryAdd(key, let keyPtr, let indexPtr))
				{
					*indexPtr = (int32)i;
					continue;
				}
				let b = mAttributes[*indexPtr];
				return .Err(Fail(.DuplicateAttribute, scope $"The attributes `{mNames[b.mName]}` and `{mNames[a.mName]}` have the same namespace and local name", a.mOffset, mNames[a.mName].Length));
			}
		}
		else if (prefixed > 1)
		{
			// Attributes Unique: no two with the same namespace and local name
			for (int i = 1; i < mAttributes.Count; i++)
			{
				let a = mAttributes[i];
				if (!a.mPrefix.IsValid)
					continue;
				for (int j < i)
				{
					let b = mAttributes[j];
					if (b.mPrefix.IsValid && b.mLocal == a.mLocal && b.mNamespace == a.mNamespace)
						return .Err(Fail(.DuplicateAttribute, scope $"The attributes `{mNames[b.mName]}` and `{mNames[a.mName]}` have the same namespace and local name", a.mOffset, mNames[a.mName].Length));
				}
			}
		}
		return ns;
	}

	/// The default namespace in scope (None for none).
	XmlNameId DefaultNamespace()
	{
		for (int i = mBindings.Count - 1; i >= 0; i--)
		{
			if (!mBindings[i].mPrefix.IsValid)
				return mBindings[i].mUri;
		}
		return .None;
	}

	Result<void, XmlFailure> AddBinding(Binding binding, int offset)
	{
		if (mConfig.MaxNamespaceBindings > 0 && mBindings.Count >= mConfig.MaxNamespaceBindings)
			return .Err(Fail(.ResourceLimitExceeded, scope $"More namespace declarations are in scope than MaxNamespaceBindings ({mConfig.MaxNamespaceBindings})", offset));
		mBindings.Add(binding);
		return .Ok;
	}

	/// The namespace a prefix is bound to; for no prefix, the default namespace of an element (none for
	/// an attribute).
	Result<XmlNameId, XmlFailure> ResolvePrefix(XmlNameId prefix, bool element, int offset, int length)
	{
		if (!prefix.IsValid)
			return element ? DefaultNamespace() : XmlNameId.None;
		if (prefix == mXmlPrefix)
			return mXmlUri;
		if (prefix == mXmlnsPrefix)
		{
			if (element)
				return .Err(Fail(.InvalidNamespaceDeclaration, "An element name cannot have the prefix `xmlns`", offset, length));
			return mXmlnsUri;
		}
		for (int i = mBindings.Count - 1; i >= 0; i--)
		{
			if (mBindings[i].mPrefix == prefix)
				return mBindings[i].mUri;
		}
		return .Err(Fail(.UnboundPrefix, scope $"The prefix `{mNames[prefix]}` is not bound to a namespace", offset, length));
	}
}
