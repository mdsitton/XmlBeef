using System;
using System.Collections;
using System.IO;
using internal XmlBeef;

namespace XmlBeef;

/// Changing the node tree and attributes. The public entry points are on XmlNode; these are the
/// operations on the tables they share, the checks of what is put in, and writing bytes.
extension XmlDocument
{
	// Links

	/// Links an unlinked node before `sibling`, under the sibling's parent.
	internal void LinkBefore(uint32 sibling, uint32 child)
	{
		ref XmlNodeRecord s = ref mNodes[sibling];
		ref XmlNodeRecord c = ref mNodes[child];
		ref XmlNodeRecord p = ref mNodes[s.mParent];
		c.mParent = s.mParent;
		c.mNextSibling = sibling;
		c.mPrevSibling = s.mPrevSibling;
		if (s.mPrevSibling != 0)
			mNodes[s.mPrevSibling].mNextSibling = child;
		else
			p.mFirstChild = child;
		s.mPrevSibling = child;
		p.mChildCount++;
	}

	/// Links an unlinked node after `sibling`, under the sibling's parent.
	internal void LinkAfter(uint32 sibling, uint32 child)
	{
		uint32 next = mNodes[sibling].mNextSibling;
		if (next != 0)
			LinkBefore(next, child);
		else
			LinkLastChild(mNodes[sibling].mParent, child);
	}

	/// Takes a node (and its subtree) out of its parent's children; it stays in the table.
	internal void Unlink(uint32 id)
	{
		ref XmlNodeRecord c = ref mNodes[id];
		ref XmlNodeRecord p = ref mNodes[c.mParent];
		if (c.mPrevSibling != 0)
			mNodes[c.mPrevSibling].mNextSibling = c.mNextSibling;
		else
			p.mFirstChild = c.mNextSibling;
		if (c.mNextSibling != 0)
			mNodes[c.mNextSibling].mPrevSibling = c.mPrevSibling;
		else
			p.mLastChild = c.mPrevSibling;
		p.mChildCount--;
		c.mParent = 0;
		c.mNextSibling = 0;
		c.mPrevSibling = 0;
	}

	/// Before a node leaves its place: the style marks for the place it leaves.
	internal void MarkLeaving(uint32 id)
	{
		MarkNeighbors(id);
		MarkChanged(mNodes[id].mParent);
	}

	/// After a node took a place: the style marks for it and its new neighbors.
	internal void MarkArrived(uint32 id)
	{
		MarkNeighbors(id);
		MarkChanged(mNodes[id].mParent);
	}

	/// An element's declarations no longer apply to it (renamed), or are gone (the DOCTYPE removed), and
	/// what they gave its attributes must not be lost: defaulted attributes become specified (written),
	/// and in a PreserveStyle document values whose source text is not their value (normalized by an
	/// attribute type such as NMTOKENS, or with references) are regenerated from the value.
	internal void MaterializeDefaults(uint32 element)
	{
		ref XmlNodeRecord node = ref mNodes[element];
		bool any = false;
		for (int i = node.mAttributeStart; i < node.mAttributeStart + node.mAttributeCount; i++)
		{
			if (mAttributes[i].mFlags.HasFlag(.Defaulted))
			{
				mAttributes[i].mFlags &= ~.Defaulted;
				any = true;
			}
			else if (mPreserve && i < mAttributeStyles.Count && mAttributeStyles[i].mFlags.HasFlag(.Captured) &&
				Source(mAttributeStyles[i].mValueStart, mAttributeStyles[i].mValueEnd) != mAttributes[i].mValue)
			{
				MarkAttribute(i, .ValueDirty);
				any = true;
			}
		}
		if (any)
			MarkNode(element, .TagDirty);
	}

	/// The DOCTYPE was removed: the values its declarations supplied stay. Defaulted attributes become
	/// specified; in a PreserveStyle document, text and attribute values whose source refers to its
	/// entities are regenerated from their (expanded) values.
	void DocTypeRemoved()
	{
		for (uint32 id = 1; id < (uint32)mNodes.Count; id++)
		{
			ref XmlNodeRecord node = ref mNodes[id];
			if (node.mFlags.HasFlag(.Removed))
				continue;
			if (mPreserve && StyleFlags(id).HasFlag(.Captured))
			{
				// References to entities with empty text produced no node: in content they are all the
				// source between nodes and before an end tag holds, and go with the declarations
				ref XmlNodeStyle style = ref mNodeStyles[id];
				if (HasEntityReference(Source(style.mLead, style.mStart)))
				{
					style.mLead = style.mStart;
					MarkChanged(node.mParent);
				}
				if (node.mKind == .Element && HasEntityReference(Source(style.mInnerTail, style.mEndTagStart)))
				{
					style.mInnerTail = style.mEndTagStart;
					MarkChanged(id);
				}
			}
			if (node.mKind == .Element)
			{
				MaterializeDefaults(id);
				if (!mPreserve)
					continue;
				// Produced by a reference: regenerated, not written as the reference
				if (StyleFlags(id).HasFlag(.InEntity))
					MarkNode(id, .TagDirty | .GroupDirty);
			}
			else if (mPreserve && node.mKind == .Text && StyleFlags(id).HasFlag(.Captured))
			{
				// Text read through a reference (its source has `&name;`), or produced by one
				let style = mNodeStyles[id];
				if (style.mFlags.HasFlag(.InEntity) || style.mFlags.HasFlag(.Shared) || HasEntityReference(Source(style.mStart, style.mEnd)))
					MarkNode(id, .ValueDirty | .GroupDirty);
			}
			else if (mPreserve && node.mKind != .Element && StyleFlags(id).HasFlag(.InEntity))
				MarkNode(id, .ValueDirty | .GroupDirty);
		}
	}

	/// Whether `text` (source) has a general entity reference: `&name;`, not `&#…;` or one of the five
	/// predefined.
	static bool HasEntityReference(StringView text)
	{
		int at = 0;
		while (true)
		{
			int amp = text.IndexOf('&', at);
			if (amp < 0)
				return false;
			int semicolon = text.IndexOf(';', amp);
			if (semicolon < 0)
				return false;
			let name = text.Substring(amp + 1, semicolon - amp - 1);
			if (!name.StartsWith('#') && name != "lt" && name != "gt" && name != "amp" && name != "apos" && name != "quot")
				return true;
			at = semicolon;
		}
	}

	/// Unlinks a node and marks it and every descendant removed. Their slots are not reused before
	/// Clear, so handles to them become invalid rather than naming other nodes.
	internal void RemoveNode(uint32 id)
	{
		MarkLeaving(id);
		Unlink(id);
		if (id == mRoot)
			mRoot = 0;
		if (id == mDocType)
		{
			mDocType = 0;
			DocTypeRemoved();
		}
		// Walk the subtree through the links; the removed node's parent is now 0, so the walk stops on
		// returning to it
		uint32 current = id;
		while (true)
		{
			mNodes[current].mFlags |= .Removed;
			if (mNodes[current].mFirstChild != 0)
			{
				current = mNodes[current].mFirstChild;
				continue;
			}
			while (current != id && mNodes[current].mNextSibling == 0)
				current = mNodes[current].mParent;
			if (current == id)
				return;
			current = mNodes[current].mNextSibling;
		}
	}

	/// Whether `ancestor` is `id` or one of its ancestors.
	internal bool IsSelfOrAncestor(uint32 ancestor, uint32 id)
	{
		uint32 current = id;
		while (true)
		{
			if (current == ancestor)
				return true;
			if (current == 0)
				return false;
			current = mNodes[current].mParent;
		}
	}

	// Namespaces

	/// The namespace `prefix` (None: the default namespace) is bound to at `element`, from the `xmlns`
	/// attributes of it and its ancestors (None if unbound).
	internal XmlNameId LookupNamespace(uint32 element, XmlNameId prefix)
	{
		if (prefix == XmlNameTable.cXml)
			return XmlNameTable.cXmlNamespace;
		if (prefix == XmlNameTable.cXmlns)
			return XmlNameTable.cXmlnsNamespace;
		for (uint32 e = element; e != 0; e = mNodes[e].mParent)
		{
			ref XmlNodeRecord node = ref mNodes[e];
			for (int i = node.mAttributeStart; i < node.mAttributeStart + node.mAttributeCount; i++)
			{
				ref XmlAttributeRecord attribute = ref mAttributes[i];
				bool binds = prefix.IsValid
					? (mNames.PrefixOf(attribute.mName) == XmlNameTable.cXmlns && mNames.LocalOf(attribute.mName) == prefix)
					: attribute.mName == XmlNameTable.cXmlns;
				if (binds)
					return attribute.mValue.IsEmpty ? .None : mNames.Intern(attribute.mValue);
			}
		}
		return .None;
	}

	/// The namespace of an attribute named `name` on `element`.
	internal XmlNameId AttributeNamespace(uint32 element, XmlNameId name)
	{
		if (name == XmlNameTable.cXmlns)
			return XmlNameTable.cXmlnsNamespace;
		if (!mNames.HasColon(name))
			return .None;
		return LookupNamespace(element, mNames.PrefixOf(name));
	}

	/// Resolves again the namespaces of the elements and attributes under `root` (included), after a
	/// change of the declarations in scope: a move, or an `xmlns` attribute set or removed.
	internal void ResolveNamespaces(uint32 root)
	{
		if (!mNamespaces)
			return;
		NamespacesChanged();
		uint32 current = root;
		while (true)
		{
			ref XmlNodeRecord node = ref mNodes[current];
			if (node.mKind == .Element)
			{
				node.mNamespace = LookupNamespace(current, mNames.PrefixOf(node.mName));
				for (int i = node.mAttributeStart; i < node.mAttributeStart + node.mAttributeCount; i++)
					mAttributes[i].mNamespace = AttributeNamespace(current, mAttributes[i].mName);
			}
			if (mNodes[current].mFirstChild != 0)
			{
				current = mNodes[current].mFirstChild;
				continue;
			}
			while (current != root && mNodes[current].mNextSibling == 0)
				current = mNodes[current].mParent;
			if (current == root)
				return;
			current = mNodes[current].mNextSibling;
		}
	}

	// Attributes. The side tables (source ranges, PreserveStyle) follow their attributes: a table is
	// in use when it is not empty, and attributes added since the read have default (empty) records.

	void SideCopy<T>(List<T> list, int from, int to, int count) where T : struct
	{
		if (list.IsEmpty)
			return;
		while (list.Count < mAttributes.Count)
			list.Add(default);
		for (int i < count)
			list[to + i] = list[from + i];
	}

	void SideClear<T>(List<T> list, int at) where T : struct
	{
		if (list.IsEmpty)
			return;
		while (list.Count < mAttributes.Count)
			list.Add(default);
		list[at] = default;
	}

	void SideRemove<T>(List<T> list, int at, int end) where T : struct
	{
		if (list.IsEmpty)
			return;
		while (list.Count < mAttributes.Count)
			list.Add(default);
		for (int i = at; i < end - 1; i++)
			list[i] = list[i + 1];
	}

	/// Appends an attribute to an element, in place when its attributes are the last in the table, else
	/// moving them to the end first (the old range becomes a hole until Clear).
	internal void AppendAttribute(uint32 id, XmlAttributeRecord attribute)
	{
		ref XmlNodeRecord node = ref mNodes[id];
		int start = node.mAttributeStart;
		int count = node.mAttributeCount;
		if (start + count != mAttributes.Count)
		{
			int newStart = mAttributes.Count;
			mAttributes.GrowUninitialized(count);
			for (int i < count)
				mAttributes[newStart + i] = mAttributes[start + i];
			SideCopy(mAttributeRanges, start, newStart, count);
			SideCopy(mAttributeStyles, start, newStart, count);
			node.mAttributeStart = (int32)newStart;
		}
		mAttributes.Add(attribute);
		SideClear(mAttributeRanges, mAttributes.Count - 1);
		SideClear(mAttributeStyles, mAttributes.Count - 1);
		node.mAttributeCount++;
	}

	/// Removes the attribute at table index `at` of the element, keeping the order of the rest.
	internal void RemoveAttributeAt(uint32 id, int at)
	{
		ref XmlNodeRecord node = ref mNodes[id];
		int end = node.mAttributeStart + node.mAttributeCount;
		for (int i = at; i < end - 1; i++)
			mAttributes[i] = mAttributes[i + 1];
		SideRemove(mAttributeRanges, at, end);
		SideRemove(mAttributeStyles, at, end);
		node.mAttributeCount--;
	}

	// Checks of what is put in: a document that cannot be written as well-formed XML is a programming
	// error (a fatal error), as an invalid handle is. IsValidName and IsValidText let callers check
	// first.

	/// @brief Whether `name` can name an element, attribute or processing instruction: an XML Name
	/// (with namespaces on: at most one colon, between a prefix and a local name).
	/// @param name The name.
	/// @param namespaces Whether the colon rules of Namespaces 1.0 apply.
	/// @return Whether it is valid.
	public static bool IsValidName(StringView name, bool namespaces = true)
	{
		if (name.IsEmpty || !IsValidText(name))
			return false;
		int i = 0;
		int colons = 0;
		int colonAt = -1;
		while (i < name.Length)
		{
			char32 cp = XmlChar.Decode(name.Ptr, i, let length);
			if (i == 0 ? !XmlChar.IsNameStartChar(cp) : !XmlChar.IsNameChar(cp))
				return false;
			if (cp == ':')
			{
				colons++;
				colonAt = i;
			}
			i += length;
		}
		if (namespaces && colons > 0)
			return colons == 1 && colonAt > 0 && colonAt < name.Length - 1 && XmlChar.IsNameStartChar(XmlChar.Decode(name.Ptr, colonAt + 1, ?));
		return true;
	}

	/// @brief Whether `text` can be content: well-formed UTF-8 of characters XML allows (no C0 controls
	/// other than tab, LF and CR; no U+FFFE or U+FFFF).
	/// @param text The text.
	/// @return Whether it is valid.
	public static bool IsValidText(StringView text)
	{
		let message = scope String();
		return XmlChar.FindInvalid(text.Ptr, 0, text.Length, message, ?, ?) < 0;
	}

	internal void CheckName(StringView name, StringView what)
	{
		if (!IsValidName(name, mNamespaces))
			Runtime.FatalError(scope $"XmlBeef: `{name}` is not a valid {what} name");
	}

	internal static void CheckText(StringView text, StringView what)
	{
		if (!IsValidText(text))
			Runtime.FatalError(scope $"XmlBeef: the {what} contains a character XML does not allow, or is not UTF-8");
	}

	// Namespace well-formedness of an edited document

	/// @brief Check the document against Namespaces in XML 1.0, as the reader would on reading it back:
	/// every prefix bound where it is used, no two attributes of an element with the same namespace and
	/// local name, and the rules for `xml`, `xmlns` and empty declarations. Mutations allow incomplete
	/// states (an element added before its prefix is declared); WriteBytes and WriteFile check before
	/// writing an edited document, Write(String) does not.
	/// @return .Ok, or the first problem (no source position: it names the element).
	public Result<void, XmlParseError> CheckNamespaces()
	{
		if (!mNamespaces || mRoot == 0)
			return .Ok;
		let names = mNames;
		uint32 current = mRoot;
		while (true)
		{
			ref XmlNodeRecord node = ref mNodes[current];
			if (node.mKind == .Element)
				Try!(CheckElementNamespaces(current));
			if (node.mFirstChild != 0)
			{
				current = node.mFirstChild;
				continue;
			}
			while (current != mRoot && mNodes[current].mNextSibling == 0)
				current = mNodes[current].mParent;
			if (current == mRoot)
				break;
			current = mNodes[current].mNextSibling;
		}
		mNamespacesChanged = false;
		return .Ok;

		XmlParseError Problem(XmlErrorKind kind, StringView message)
		{
			return XmlParseError(kind, message, 0, 0, 0, 0);
		}

		Result<void, XmlParseError> CheckElementNamespaces(uint32 id)
		{
			ref XmlNodeRecord element = ref mNodes[id];
			StringView elementName = names[element.mName];
			// Its declarations
			for (int i = element.mAttributeStart; i < element.mAttributeStart + element.mAttributeCount; i++)
			{
				ref XmlAttributeRecord attribute = ref mAttributes[i];
				StringView value = attribute.mValue;
				if (attribute.mName == XmlNameTable.cXmlns)
				{
					if (value == XmlNameTable.XmlNamespaceUri || value == XmlNameTable.XmlnsNamespaceUri)
						return .Err(Problem(.InvalidNamespaceDeclaration, scope $"{elementName}: the default namespace cannot be `{value}`"));
					continue;
				}
				if (names.PrefixOf(attribute.mName) != XmlNameTable.cXmlns)
					continue;
				let prefix = names.LocalOf(attribute.mName);
				StringView prefixText = names[prefix];
				if (prefix == XmlNameTable.cXmlns)
					return .Err(Problem(.InvalidNamespaceDeclaration, scope $"{elementName}: the prefix `xmlns` cannot be declared"));
				if (prefix == XmlNameTable.cXml)
				{
					if (value != XmlNameTable.XmlNamespaceUri)
						return .Err(Problem(.InvalidNamespaceDeclaration, scope $"{elementName}: the prefix `xml` can only be bound to `{XmlNameTable.XmlNamespaceUri}`"));
					continue;
				}
				if (value.IsEmpty)
					return .Err(Problem(.InvalidNamespaceDeclaration, scope $"{elementName}: the prefix `{prefixText}` cannot be undeclared (`xmlns:{prefixText}=\"\"`) in XML 1.0"));
				if (value == XmlNameTable.XmlNamespaceUri || value == XmlNameTable.XmlnsNamespaceUri)
					return .Err(Problem(.InvalidNamespaceDeclaration, scope $"{elementName}: the prefix `{prefixText}` cannot be bound to `{value}`"));
			}
			// Its name and its attributes' names: bound prefixes
			let elementPrefix = names.PrefixOf(element.mName);
			if (elementPrefix == XmlNameTable.cXmlns)
				return .Err(Problem(.InvalidNamespaceDeclaration, scope $"{elementName}: an element cannot have the prefix `xmlns`"));
			if (elementPrefix.IsValid && !LookupNamespace(id, elementPrefix).IsValid)
				return .Err(Problem(.UnboundPrefix, scope $"{elementName}: the prefix `{names[elementPrefix]}` is not bound"));
			for (int i = element.mAttributeStart; i < element.mAttributeStart + element.mAttributeCount; i++)
			{
				ref XmlAttributeRecord attribute = ref mAttributes[i];
				let prefix = names.PrefixOf(attribute.mName);
				if (!prefix.IsValid || prefix == XmlNameTable.cXmlns)
					continue;
				let ns = LookupNamespace(id, prefix);
				if (!ns.IsValid)
					return .Err(Problem(.UnboundPrefix, scope $"{elementName}: the prefix `{names[prefix]}` of the attribute `{names[attribute.mName]}` is not bound"));
				// Unique (namespace, local name)
				for (int j = element.mAttributeStart; j < i; j++)
				{
					ref XmlAttributeRecord other = ref mAttributes[j];
					let otherPrefix = names.PrefixOf(other.mName);
					if (!otherPrefix.IsValid || otherPrefix == XmlNameTable.cXmlns)
						continue;
					if (names.LocalOf(other.mName) == names.LocalOf(attribute.mName) && LookupNamespace(id, otherPrefix) == ns)
						return .Err(Problem(.DuplicateAttribute, scope $"{elementName}: the attributes `{names[other.mName]}` and `{names[attribute.mName]}` have the same namespace and local name"));
				}
			}
			return .Ok;
		}
	}

	/// A mutation may have changed what names mean or bind: WriteBytes checks namespaces again.
	internal void NamespacesChanged()
	{
		if (mNamespaces)
			mNamespacesChanged = true;
	}

	// Writing bytes

	/// @brief Write the document (as Write does) as bytes: in the document's encoding when it was read
	/// with PreserveStyle (its byte order mark included), in UTF-8 otherwise.
	/// @param output The list to append to.
	/// @return .Ok, or an InvalidEncoding error naming a character that the encoding cannot hold (a
	/// value set in code), UnsupportedEncoding for a document read through
	/// XmlReadConfig.EncodingConverter. The output is then as it was.
	public Result<void, XmlParseError> WriteBytes(List<uint8> output)
	{
		return WriteBytes(output, .());
	}

	/// @brief Write the document as bytes (see WriteBytes(List<uint8>)), with options: indentation for a
	/// canonical document, and what to do with characters the encoding cannot hold
	/// (XmlWriteOptions.Unencodable).
	/// @param output The list to append to.
	/// @param options The options.
	/// @return .Ok, or an error as WriteBytes(List<uint8>). The output is then as it was.
	public Result<void, XmlParseError> WriteBytes(List<uint8> output, XmlWriteOptions options)
	{
		// An edited document must still be namespace well-formed
		if (mNamespacesChanged)
			Try!(CheckNamespaces());
		XmlEncoding encoding = mPreserve ? mEncoding : .Utf8;
		bool utf8Fallback = options.Unencodable == .Utf8;
		if (encoding == .Custom && !utf8Fallback)
			return .Err(XmlParseError(.UnsupportedEncoding, "A document read through EncodingConverter cannot be written in its encoding; use Write for UTF-8 text, or XmlUnencodable.Utf8", 0, 0, 0, 0));
		let text = scope String();
		// The policy applies to what the writer generates: what it keeps from the source was in the encoding
		mFixing = !utf8Fallback && options.Unencodable != .Error && encoding != .Utf8;
		mFixEncoding = encoding;
		mFixOptions = options;
		defer { mFixing = false; mFixOptions = default; }
		if (mPreserve)
			WritePreserving(text);
		else
			WriteCanonical(text, options);

		int before = output.Count;
		int bad = (encoding == .Custom) ? 0 : XmlEncoder.Encode(text, encoding, output);
		if (bad < 0)
			return .Ok;
		output.Count = before;
		if (utf8Fallback)
		{
			// The whole document in UTF-8, saying so in its declaration
			SetDeclaredEncoding(text, "UTF-8");
			XmlEncoder.Encode(text, .Utf8, output);
			return .Ok;
		}
		char32 cp = XmlChar.Decode(text.Ptr, bad, let length);
		let message = scope String();
		message.Append("The character ");
		XmlChar.AppendCodePointName(message, (uint32)cp);
		message.AppendF(" cannot be written in the document's encoding ({})", encoding);
		if (options.Unencodable == .CharacterReference)
			message.Append(" (where XML has no character reference: a comment, a processing instruction, a name)");
		return .Err(XmlParseError.At(.InvalidEncoding, message, text, bad, length));
	}

	/// The `encoding` of the XML declaration at the start of `text` (after a byte order mark) made
	/// `name`, if it has one.
	static void SetDeclaredEncoding(String text, StringView name)
	{
		int start = text.StartsWith("\u{FEFF}") ? 3 : 0;
		if (!text.Substring(start).StartsWith("<?xml"))
			return;
		int end = text.IndexOf("?>", start);
		int at = text.IndexOf("encoding", start);
		if (end < 0 || at < 0 || at > end)
			return;
		int quote = at + 8;
		while (quote < end && text[quote] != '"' && text[quote] != '\'')
			quote++;
		int close = (quote + 1 < end) ? text.IndexOf(text[quote], quote + 1) : -1;
		if (close < 0 || close > end)
			return;
		text.Remove(quote + 1, close - quote - 1);
		text.Insert(quote + 1, name);
	}

	/// @brief Write the document (as WriteBytes does) to a file, replacing it.
	/// @param path The file's path.
	/// @return .Ok, or WriteBytes' errors, or IoError if the file cannot be written.
	public Result<void, XmlParseError> WriteFile(StringView path)
	{
		return WriteFile(path, .());
	}

	/// @brief Write the document (as WriteBytes does, with options) to a file, replacing it.
	/// @param path The file's path.
	/// @param options The options (see WriteBytes(List<uint8>, XmlWriteOptions)).
	/// @return .Ok, or WriteBytes' errors, or IoError if the file cannot be written.
	public Result<void, XmlParseError> WriteFile(StringView path, XmlWriteOptions options)
	{
		let bytes = scope List<uint8>();
		Try!(WriteBytes(bytes, options));
		let file = scope FileStream();
		if (file.Create(path, .Write) case .Err)
			return .Err(XmlParseError(.IoError, "Cannot create the file", 0, 0, 0, 0));
		if (file.TryWrite(Span<uint8>(bytes.Ptr, bytes.Count)) case .Err)
			return .Err(XmlParseError(.IoError, "Cannot write the file", 0, 0, 0, 0));
		return .Ok;
	}
}
