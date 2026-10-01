using System;
using System.Collections;
using internal XmlBeef;

namespace XmlBeef;

/// @brief A value read for an [XmlObject] field or converter: its text, and where it is, for located
/// errors.
public struct XmlValueRef
{
	/// @brief The element holding it: for an attribute, its element; for element text, that element.
	public XmlNode mElement;
	/// @brief The attribute's position among mElement's attributes, or -1 for text.
	public int mAttribute;
	/// @brief The attribute or element name, for messages (empty for an element's own text).
	public StringView mName;
	/// @brief The text: an attribute's normalized value, an element's text, or one list token.
	public StringView mText;

	/// @brief An InvalidValue error located at the value, naming where it is.
	/// @param message What is wrong.
	/// @return The error.
	public XmlParseError MakeError(StringView message)
	{
		return XmlBind.MakeError(mElement, mAttribute, mName, message, .InvalidValue);
	}
}

/// @brief Where an [XmlObject] field's value is written: an attribute, a child element's text, or an
/// element's own text. Converters do not see it: they write text, which the generated code sets here.
public struct XmlValueWriter
{
	enum Target
	{
		Attribute,
		/// The text of the child element mName (created when missing)
		Element,
		/// The text of mElement itself
		Text
	}

	XmlNode mElement;
	Target mTarget;
	StringView mName;
	StringView mNamespace;

	/// @brief The attribute `local` (in `namespaceUri`, empty for none) of `element`.
	/// @param element The element.
	/// @param local The attribute's local name.
	/// @param namespaceUri Its namespace.
	/// @return The writer.
	public static XmlValueWriter Attribute(XmlNode element, StringView local, StringView namespaceUri)
	{
		XmlValueWriter writer = default;
		writer.mElement = element;
		writer.mTarget = .Attribute;
		writer.mName = local;
		writer.mNamespace = namespaceUri;
		return writer;
	}

	/// @brief The text of the child element `local` of `element` (added when missing).
	/// @param element The parent element.
	/// @param local The child's local name.
	/// @param namespaceUri Its namespace (empty: the one in scope).
	/// @return The writer.
	public static XmlValueWriter Element(XmlNode element, StringView local, StringView namespaceUri)
	{
		XmlValueWriter writer = default;
		writer.mElement = element;
		writer.mTarget = .Element;
		writer.mName = local;
		writer.mNamespace = namespaceUri;
		return writer;
	}

	/// @brief The text of `element` itself (its Text and CDATA children; other children stay).
	/// @param element The element.
	/// @return The writer.
	public static XmlValueWriter Text(XmlNode element)
	{
		XmlValueWriter writer = default;
		writer.mElement = element;
		writer.mTarget = .Text;
		return writer;
	}

	/// @brief Write `text`; nothing changes when the value is the same.
	/// @param text The value as text.
	public void Set(StringView text)
	{
		switch (mTarget)
		{
		case .Attribute:
			XmlBind.SetAttribute(mElement, mName, mNamespace, text);
		case .Element:
			XmlBind.ReplaceText(XmlBind.ChildElement(mElement, mName, mNamespace), text);
		case .Text:
			XmlBind.ReplaceText(mElement, text);
		}
	}

	/// @brief Remove the value (a null String, a converter that writes nothing): the attribute, the child
	/// element, or the element's text.
	public void Remove()
	{
		switch (mTarget)
		{
		case .Attribute:
			XmlBind.RemoveAttribute(mElement, mName, mNamespace);
		case .Element:
			XmlBind.RemoveElement(mElement, mName, mNamespace);
		case .Text:
			XmlBind.ReplaceText(mElement, default);
		}
	}
}

/// @brief The child elements of an element with one name, in order (for reading a List field). Used by
/// generated code.
public struct XmlMatchingElements : IEnumerable<XmlNode>
{
	XmlNode mParent;
	StringView mLocal;
	StringView mNamespace;

	internal this(XmlNode parent, StringView local, StringView namespaceUri)
	{
		mParent = parent;
		mLocal = local;
		mNamespace = namespaceUri;
	}

	public Enumerator GetEnumerator() => .(this);

	public struct Enumerator : IEnumerator<XmlNode>
	{
		XmlDocument mDocument;
		StringView mNamespace;
		XmlNameId mLocalId;
		uint32 mNext;

		internal this(XmlMatchingElements list)
		{
			mDocument = list.mParent.mDocument;
			mNamespace = list.mNamespace;
			// The name looked up once: comparisons are of IDs
			mLocalId = mDocument.mNames.FindCached(list.mLocal);
			mNext = mLocalId.IsValid ? mDocument.mNodes[list.mParent.mId].mFirstChild : 0;
		}

		public Result<XmlNode> GetNext() mut
		{
			while (mNext != 0)
			{
				uint32 id = mNext;
				mNext = mDocument.mNodes[id].mNextSibling;
				if (XmlBind.IsElement(mDocument, id, mLocalId, mNamespace))
					return XmlNode(mDocument, id);
			}
			return .Err;
		}
	}
}

/// @brief The whitespace-separated tokens of a value, each as an XmlValueRef at the same place (for an
/// [XmlAttribute] List). Used by generated code.
public struct XmlTokens : IEnumerable<XmlValueRef>
{
	XmlValueRef mValue;

	internal this(XmlValueRef value)
	{
		mValue = value;
	}

	public Enumerator GetEnumerator() => .(mValue);

	public struct Enumerator : IEnumerator<XmlValueRef>
	{
		XmlValueRef mValue;
		int mPos;

		internal this(XmlValueRef value)
		{
			mValue = value;
			mPos = 0;
		}

		public Result<XmlValueRef> GetNext() mut
		{
			StringView text = mValue.mText;
			while (mPos < text.Length && XmlChar.IsSpace(text[mPos]))
				mPos++;
			if (mPos == text.Length)
				return .Err;
			int start = mPos;
			while (mPos < text.Length && !XmlChar.IsSpace(text[mPos]))
				mPos++;
			var token = mValue;
			token.mText = text.Substring(start, mPos - start);
			return token;
		}
	}
}

/// @brief Writes a List's items as the child elements with one name, in one pass: each Next is the
/// following existing child with that name, or a new one after the last of them (or at the end of the
/// parent); Trim removes those left over. Used by generated code.
public struct XmlChildCursor
{
	XmlNode mParent;
	StringView mLocal;
	StringView mNamespace;
	XmlNode mLast;
	XmlNode mNext;

	public this(XmlNode parent, StringView local, StringView namespaceUri)
	{
		mParent = parent;
		mLocal = local;
		mNamespace = namespaceUri;
		mLast = default;
		mNext = parent.FirstChild;
	}

	/// @brief The element for the next item.
	/// @return The child.
	public XmlNode Next() mut
	{
		while (mNext.IsValid && !XmlBind.IsElement(mNext, mLocal, mNamespace))
			mNext = mNext.NextSibling;
		if (mNext.IsValid)
		{
			mLast = mNext;
			mNext = mNext.NextSibling;
			return mLast;
		}
		// None left: every later child with the name has been used, so the new one goes after the last
		mLast = XmlBind.NewChild(mParent, mLocal, mNamespace, mLast);
		return mLast;
	}

	/// @brief Remove the children with the name after the last item written.
	public void Trim() mut
	{
		while (mNext.IsValid)
		{
			let child = mNext;
			mNext = mNext.NextSibling;
			if (XmlBind.IsElement(child, mLocal, mNamespace))
				XmlBind.RemoveWithIndent(child);
		}
	}
}

/// @brief Writes an [XmlChildren] list in one pass: item i goes into the i-th child element no other
/// field claims if that child has the item's name, else into a new element inserted there (or at the
/// end); Trim removes the unclaimed elements left over. Used by generated code.
public struct XmlFreeChildCursor
{
	XmlNode mParent;
	Span<StringView> mClaimed;
	XmlNode mNext;
	XmlNode mLast;

	public this(XmlNode parent, Span<StringView> claimed)
	{
		mParent = parent;
		mClaimed = claimed;
		mNext = parent.FirstChild;
		mLast = default;
	}

	/// @brief The element for the next item.
	/// @param local The item's element name.
	/// @param namespaceUri Its namespace (empty: the one in scope).
	/// @return The child.
	public XmlNode Next(StringView local, StringView namespaceUri) mut
	{
		while (mNext.IsValid && (mNext.Kind != .Element || XmlBind.IsClaimedElement(mNext, mClaimed)))
			mNext = mNext.NextSibling;
		if (mNext.IsValid && XmlBind.IsElement(mNext, local, namespaceUri))
		{
			mLast = mNext;
			mNext = mNext.NextSibling;
			return mLast;
		}
		mLast = XmlBind.NewChild(mParent, local, namespaceUri, mLast);
		return mLast;
	}

	/// @brief Remove the unclaimed child elements after the last item written.
	public void Trim() mut
	{
		while (mNext.IsValid)
		{
			let child = mNext;
			mNext = mNext.NextSibling;
			if (child.Kind == .Element && !XmlBind.IsClaimedElement(child, mClaimed))
				XmlBind.RemoveWithIndent(child);
		}
	}
}

/// @brief Runtime support for the code [XmlObject] generates: finding a field's value, converting it with
/// located errors, and writing it back in place. Public because the generated code lives in the user's
/// types; not meant to be called directly.
///
/// Names match by local name; an element name with an empty namespace matches any namespace, an
/// attribute name with an empty namespace only attributes in none. A document read without namespaces
/// matches by name alone.
public static class XmlBind
{
	/// @brief An error located at the attribute (or, without one, the element), in the form
	/// `element: name: message`.
	/// @param element The element.
	/// @param attribute The attribute's position among its attributes, or -1.
	/// @param name The attribute or child element name, or empty.
	/// @param message What is wrong.
	/// @param kind The error kind.
	/// @return The error.
	public static XmlParseError MakeError(XmlNode element, int attribute, StringView name, StringView message, XmlErrorKind kind)
	{
		XmlSourceRange range = default;
		bool located = attribute >= 0 && element.Attributes[attribute].TryGetSourceRange(out range);
		if (!located)
			located = element.TryGetSourceRange(out range);
		let text = scope String();
		text.Append(element.Name, ": ");
		if (!name.IsEmpty && name != element.Name)
			text.Append(name, ": ");
		text.Append(message);
		var error = XmlParseError(kind, text, located ? range.mLine : 0, located ? range.mColumn : 0, located ? range.mOffset : 0, located ? range.mLength : 0);
		if (!element.Document.SourceName.IsEmpty)
			error.SetSource(element.Document.SourceName);
		return error;
	}

	static XmlParseError Missing(XmlNode element, StringView what)
	{
		return MakeError(element, -1, default, scope $"{what} is required", .MissingValue);
	}

	// Matching

	/// @brief Whether `node` is an element named `local` in `namespaceUri` (empty: any).
	/// @param node The node.
	/// @param local The local name.
	/// @param namespaceUri The namespace, or empty for any.
	/// @return Whether it matches.
	public static bool IsElement(XmlNode node, StringView local, StringView namespaceUri)
	{
		if (!node.IsValid)
			return false;
		let document = node.mDocument;
		return IsElement(document, node.mId, document.mNames.FindCached(local), namespaceUri);
	}

	/// Whether node `id` is an element whose local name is `localId` (None: the name is in no node of the
	/// document, so nothing matches) in `namespaceUri` (empty: any). Names compare as interned IDs.
	internal static bool IsElement(XmlDocument document, uint32 id, XmlNameId localId, StringView namespaceUri)
	{
		ref XmlNodeRecord node = ref document.mNodes[id];
		if (node.mKind != .Element || !localId.IsValid)
			return false;
		if (!document.mNamespaces)
			return node.mName == localId;
		if (document.mNames.LocalOf(node.mName) != localId)
			return false;
		return namespaceUri.IsEmpty || document.mNames[node.mNamespace] == namespaceUri;
	}

	/// The position of the attribute among the element's, or -1. Names compare as interned IDs.
	static int AttributePosition(XmlNode element, StringView local, StringView namespaceUri)
	{
		let document = element.mDocument;
		let names = document.mNames;
		XmlNameId localId = names.FindCached(local);
		if (!localId.IsValid)
			return -1;
		XmlNameId namespaceId = .None;
		if (!namespaceUri.IsEmpty && document.mNamespaces)
		{
			namespaceId = names.FindCached(namespaceUri);
			if (!namespaceId.IsValid)
				return -1;
		}
		ref XmlNodeRecord node = ref document.mNodes[element.mId];
		for (int i < node.mAttributeCount)
		{
			ref XmlAttributeRecord attribute = ref document.mAttributes[node.mAttributeStart + i];
			if (!document.mNamespaces)
			{
				if (attribute.mName == localId)
					return i;
			}
			else if (attribute.mLocal == localId && attribute.mNamespace == namespaceId)
				return i;
		}
		return -1;
	}

	// Finding values

	/// @brief The attribute `local`.
	/// @param element The element.
	/// @param local The attribute's local name.
	/// @param namespaceUri Its namespace (empty: none).
	/// @param required Whether it must be there.
	/// @param value Receives the value when it is there.
	/// @return Whether it is there, or the error.
	public static Result<bool, XmlParseError> FindAttribute(XmlNode element, StringView local, StringView namespaceUri, bool required, out XmlValueRef value)
	{
		value = default;
		int position = AttributePosition(element, local, namespaceUri);
		if (position < 0)
		{
			if (required)
				return .Err(Missing(element, scope $"The attribute `{local}`"));
			return false;
		}
		let document = element.mDocument;
		ref XmlAttributeRecord attribute = ref document.mAttributes[document.mNodes[element.mId].mAttributeStart + position];
		value.mElement = element;
		value.mAttribute = position;
		value.mName = document.mNames[attribute.mName];
		value.mText = attribute.mValue;
		return true;
	}

	/// The first child element of `element` named `local` (in `namespaceUri`, empty: any), or 0.
	static uint32 FirstElement(XmlNode element, StringView local, StringView namespaceUri)
	{
		let document = element.mDocument;
		XmlNameId localId = document.mNames.FindCached(local);
		if (!localId.IsValid)
			return 0;
		for (uint32 id = document.mNodes[element.mId].mFirstChild; id != 0; id = document.mNodes[id].mNextSibling)
		{
			if (IsElement(document, id, localId, namespaceUri))
				return id;
		}
		return 0;
	}

	/// @brief The first child element `local`.
	/// @param element The parent.
	/// @param local The child's local name.
	/// @param namespaceUri Its namespace (empty: any).
	/// @param required Whether it must be there.
	/// @param child Receives the child when it is there.
	/// @return Whether it is there, or the error.
	public static Result<bool, XmlParseError> FindElement(XmlNode element, StringView local, StringView namespaceUri, bool required, out XmlNode child)
	{
		child = default;
		uint32 id = FirstElement(element, local, namespaceUri);
		if (id != 0)
		{
			child = XmlNode(element.mDocument, id);
			return true;
		}
		if (required)
			return .Err(Missing(element, scope $"The element `{local}`"));
		return false;
	}

	/// @brief An element's text as a value (`<title>x</title>`).
	/// @param element The element.
	/// @return The value.
	public static XmlValueRef ElementValue(XmlNode element)
	{
		XmlValueRef value;
		value.mElement = element;
		value.mAttribute = -1;
		value.mName = default;
		value.mText = element.Text;
		return value;
	}

	/// @brief An element's own text, when it has any Text or CDATA child.
	/// @param element The element.
	/// @param required Whether it must be there.
	/// @param value Receives the value when it is there.
	/// @return Whether it is there, or the error.
	public static Result<bool, XmlParseError> FindText(XmlNode element, bool required, out XmlValueRef value)
	{
		value = default;
		for (let child in element.Children)
		{
			if (child.Kind == .Text || child.Kind == .CData)
			{
				value = ElementValue(element);
				return true;
			}
		}
		if (required)
			return .Err(Missing(element, "Text"));
		return false;
	}

	/// @brief The child elements `local`, in order.
	/// @param element The parent.
	/// @param local The local name.
	/// @param namespaceUri The namespace (empty: any).
	/// @return The elements.
	public static XmlMatchingElements Elements(XmlNode element, StringView local, StringView namespaceUri)
	{
		return .(element, local, namespaceUri);
	}

	/// @brief Whether the element has a child element `local`.
	/// @param element The parent.
	/// @param local The local name.
	/// @param namespaceUri The namespace (empty: any).
	/// @return Whether it has one.
	public static bool HasElement(XmlNode element, StringView local, StringView namespaceUri)
	{
		return FirstElement(element, local, namespaceUri) != 0;
	}

	/// @brief A value's whitespace-separated tokens.
	/// @param value The value.
	/// @return The tokens.
	public static XmlTokens Tokens(XmlValueRef value)
	{
		return .(value);
	}

	// Converting values

	/// @brief The value as an integer within [min, max] (XML whitespace around it allowed).
	/// @param value The value.
	/// @param min The field type's smallest value.
	/// @param max The field type's largest value.
	/// @return The integer, or the error.
	public static Result<int64, XmlParseError> ToInteger(XmlValueRef value, int64 min, int64 max)
	{
		if (!XmlValueParser.TryParseInt64(value.mText, let v))
		{
			if (IsDecimalInteger(value.mText))
				return .Err(value.MakeError(scope $"{value.mText} is outside the range {min} to {max}"));
			return .Err(value.MakeError(scope $"expected an integer, found `{value.mText}`"));
		}
		if (v < min || v > max)
			return .Err(value.MakeError(scope $"{v} is outside the range {min} to {max}"));
		return v;
	}

	/// @brief The value as a uint64 (up to 18446744073709551615).
	/// @param value The value.
	/// @return The integer, or the error.
	public static Result<uint64, XmlParseError> ToUInt64(XmlValueRef value)
	{
		StringView digits = Trim(value.mText);
		if (digits.StartsWith('+'))
			digits = digits.Substring(1);
		if (!IsDecimalInteger(value.mText))
			return .Err(value.MakeError(scope $"expected an integer, found `{value.mText}`"));
		if (digits.StartsWith('-'))
		{
			for (let c in digits.Substring(1))
			{
				if (c != '0')
					return .Err(value.MakeError(scope $"{Trim(value.mText)} is outside the range 0 to {uint64.MaxValue}"));
			}
			return 0;
		}
		uint64 result = 0;
		for (let c in digits)
		{
			uint64 digit = (uint64)(c - '0');
			if (result > (uint64.MaxValue - digit) / 10)
				return .Err(value.MakeError(scope $"{Trim(value.mText)} is outside the range 0 to {uint64.MaxValue}"));
			result = result * 10 + digit;
		}
		return result;
	}

	static StringView Trim(StringView text)
	{
		int start = 0;
		int end = text.Length;
		while (start < end && XmlChar.IsSpace(text[start]))
			start++;
		while (end > start && XmlChar.IsSpace(text[end - 1]))
			end--;
		return text.Substring(start, end - start);
	}

	/// An optional sign and decimal digits (any length), with whitespace around.
	static bool IsDecimalInteger(StringView text)
	{
		StringView s = Trim(text);
		if (s.StartsWith('-') || s.StartsWith('+'))
			s = s.Substring(1);
		if (s.IsEmpty)
			return false;
		for (let c in s)
		{
			if (c < '0' || c > '9')
				return false;
		}
		return true;
	}

	/// @brief The value as a double (`1.5`, `-2e3`, `INF`, `-INF`, `NaN`).
	/// @param value The value.
	/// @return The number, or the error.
	public static Result<double, XmlParseError> ToDouble(XmlValueRef value)
	{
		if (XmlValueParser.TryParseDouble(value.mText, let number))
			return number;
		return .Err(value.MakeError(scope $"expected a number, found `{value.mText}`"));
	}

	/// @brief The value as a boolean (`true`, `false`, `1`, `0`).
	/// @param value The value.
	/// @return The boolean, or the error.
	public static Result<bool, XmlParseError> ToBool(XmlValueRef value)
	{
		if (XmlValueParser.TryParseBool(value.mText, let b))
			return b;
		return .Err(value.MakeError(scope $"expected true or false, found `{value.mText}`"));
	}

	/// @brief The value's text for an enum (without whitespace around it).
	/// @param value The value.
	/// @return The text.
	public static StringView EnumText(XmlValueRef value)
	{
		return Trim(value.mText);
	}

	/// @brief The error for a text that names no enum case.
	/// @param value The value.
	/// @param text The text.
	/// @param cases The accepted names, "a, b, c".
	/// @return The error.
	public static XmlParseError UnknownCase(XmlValueRef value, StringView text, StringView cases)
	{
		return value.MakeError(scope $"`{text}` is not one of {cases}");
	}

	// Formatting values

	/// @brief Append an integer in decimal.
	/// @param output The text.
	/// @param v The value.
	public static void AppendInteger(String output, int64 v)
	{
		v.ToString(output);
	}

	/// @brief Append an unsigned integer in decimal.
	/// @param output The text.
	/// @param v The value.
	public static void AppendUnsigned(String output, uint64 v)
	{
		v.ToString(output);
	}

	/// @brief Append a double in its shortest form that reads back the same (`INF`, `-INF`, `NaN` for
	/// the special values).
	/// @param output The text.
	/// @param v The value.
	public static void AppendDouble(String output, double v)
	{
		if (v.IsNaN)
			output.Append("NaN");
		else if (v.IsInfinity)
			output.Append(v > 0 ? "INF" : "-INF");
		else
			v.ToString(output);
	}

	/// @brief Append `true` or `false`.
	/// @param output The text.
	/// @param v The value.
	public static void AppendBool(String output, bool v)
	{
		output.Append(v ? "true" : "false");
	}

	// Writing

	/// @brief Set the attribute `local` (in `namespaceUri`) to `text`: the existing one keeps its name and
	/// place; a new one in a namespace gets a prefix bound in scope, or one declared on the element.
	/// Nothing changes when the value is the same.
	/// @param element The element.
	/// @param local The local name.
	/// @param namespaceUri The namespace (empty: none).
	/// @param text The value.
	public static void SetAttribute(XmlNode element, StringView local, StringView namespaceUri, StringView text)
	{
		int position = AttributePosition(element, local, namespaceUri);
		if (position >= 0)
		{
			let attribute = element.Attributes[position];
			if (attribute.Value != text || !attribute.IsSpecified)
				element.SetAttribute(scope String(attribute.Name), text);
			return;
		}
		if (namespaceUri.IsEmpty || !element.Document.mNamespaces)
		{
			element.SetAttribute(local, text);
			return;
		}
		let prefix = scope String();
		if (!FindPrefix(element, namespaceUri, false, prefix))
		{
			// Declare one: ns0, ns1, … whichever is free here
			for (int n = 0; ; n++)
			{
				prefix.Clear();
				prefix.AppendF("ns{}", n);
				let document = element.Document;
				if (!document.LookupNamespace(element.mId, document.mNames.Intern(prefix)).IsValid)
					break;
			}
			element.SetAttribute(scope $"xmlns:{prefix}", namespaceUri);
		}
		element.SetAttribute(scope $"{prefix}:{local}", text);
	}

	/// @brief Remove the attribute `local` (in `namespaceUri`), if it is there.
	/// @param element The element.
	/// @param local The local name.
	/// @param namespaceUri The namespace (empty: none).
	public static void RemoveAttribute(XmlNode element, StringView local, StringView namespaceUri)
	{
		int position = AttributePosition(element, local, namespaceUri);
		if (position >= 0)
			element.RemoveAttribute(scope String(element.Attributes[position].Name));
	}

	/// A prefix bound to `namespaceUri` at `element` (not shadowed below), or for an element with
	/// `allowDefault` the default namespace (an empty prefix).
	static bool FindPrefix(XmlNode element, StringView namespaceUri, bool allowDefault, String prefix)
	{
		// The reserved namespaces are bound without declarations, to their own prefixes only
		if (namespaceUri == XmlNameTable.XmlNamespaceUri)
		{
			prefix.Set("xml");
			return true;
		}
		if (namespaceUri == XmlNameTable.XmlnsNamespaceUri)
		{
			prefix.Set("xmlns");
			return true;
		}
		let document = element.Document;
		let names = document.mNames;
		XmlNameId ns = names.Intern(namespaceUri);
		if (allowDefault && document.LookupNamespace(element.mId, .None) == ns)
			return true;
		for (var e = element; e.IsValid && e.Kind == .Element; e = e.Parent)
		{
			for (let attribute in e.Attributes)
			{
				if (attribute.Value != namespaceUri || names.PrefixOf(attribute.NameId) != XmlNameTable.cXmlns)
					continue;
				let candidate = names.LocalOf(attribute.NameId);
				if (document.LookupNamespace(element.mId, candidate) == ns)
				{
					prefix.Set(names[candidate]);
					return true;
				}
			}
		}
		return false;
	}

	/// @brief The first child element `local`, added at the end when there is none.
	/// @param element The parent.
	/// @param local The local name.
	/// @param namespaceUri The namespace (empty: the one in scope).
	/// @return The child.
	public static XmlNode ChildElement(XmlNode element, StringView local, StringView namespaceUri)
	{
		for (let candidate in element.Children)
		{
			if (IsElement(candidate, local, namespaceUri))
				return candidate;
		}
		return NewChild(element, local, namespaceUri, default);
	}

	/// @brief Remove every child element `local`.
	/// @param element The parent.
	/// @param local The local name.
	/// @param namespaceUri The namespace (empty: any).
	public static void RemoveElement(XmlNode element, StringView local, StringView namespaceUri)
	{
		var child = element.FirstChild;
		while (child.IsValid)
		{
			let next = child.NextSibling;
			if (IsElement(child, local, namespaceUri))
				RemoveWithIndent(child);
			child = next;
		}
	}

	/// @brief Remove an element and the whitespace-only text before it (its indentation), so a formatted
	/// document keeps its layout.
	/// @param element The element.
	public static void RemoveWithIndent(XmlNode element)
	{
		let before = element.PreviousSibling;
		if (before.IsValid && before.Kind == .Text && before.IsWhitespace)
			before.Remove();
		element.Remove();
	}

	/// @brief Add a child element `local` in `namespaceUri`: after `after` (when valid) with a copy of the
	/// whitespace before it, else at the end of the parent's elements, laid out like the last of them.
	/// The name gets the prefix bound to the namespace in scope, or declares it as the element's
	/// default namespace.
	/// @param parent The parent.
	/// @param local The local name.
	/// @param namespaceUri The namespace (empty: the one in scope).
	/// @param after A child of `parent` to add it after, or invalid.
	/// @return The new element.
	public static XmlNode NewChild(XmlNode parent, StringView local, StringView namespaceUri, XmlNode after)
	{
		let name = scope String();
		bool declare = false;
		if (!namespaceUri.IsEmpty && parent.Document.mNamespaces)
		{
			let prefix = scope String();
			if (FindPrefix(parent, namespaceUri, true, prefix))
			{
				if (!prefix.IsEmpty)
					name.Append(prefix, ":");
			}
			else
				declare = true;
		}
		name.Append(local);

		XmlNode anchor = after;
		if (!anchor.IsValid)
		{
			// After the last child element, when the parent has any
			for (var c = parent.LastChild; c.IsValid; c = c.PreviousSibling)
			{
				if (c.Kind == .Element)
				{
					anchor = c;
					break;
				}
			}
		}
		XmlNode created;
		if (anchor.IsValid)
		{
			created = anchor.InsertElementAfter(name);
			// The indentation of the element it follows
			let before = anchor.PreviousSibling;
			if (before.IsValid && before.Kind == .Text && before.IsWhitespace)
				parent.AddText(scope String(before.Value)).MoveBefore(created);
		}
		else
		{
			// The first element: before the whitespace that ends the parent's content
			let last = parent.LastChild;
			if (parent.Kind == .Element && last.IsValid && last.Kind == .Text && last.IsWhitespace && last.Value.Contains('\n'))
			{
				created = parent.AddElement(name);
				created.MoveBefore(last);
				parent.AddText(scope $"{last.Value}  ").MoveBefore(created);
			}
			else
				created = parent.AddElement(name);
		}
		if (declare)
			created.SetAttribute("xmlns", namespaceUri);
		return created;
	}

	/// @brief Make the element's own text `text` (empty or null: none): one Text child keeps its place,
	/// other children stay. Nothing changes when the text is the same.
	/// @param element The element.
	/// @param text The text.
	public static void ReplaceText(XmlNode element, StringView text)
	{
		if (element.Text == text)
			return;
		XmlNode firstText = default;
		int pieces = 0;
		for (let child in element.Children)
		{
			if (child.Kind == .Text || child.Kind == .CData)
			{
				if (pieces++ == 0)
					firstText = child;
			}
		}
		if (pieces == 1 && firstText.Kind == .Text && !text.IsEmpty)
		{
			firstText.SetValue(text);
			return;
		}
		// Where the first piece was: before the node after it that stays
		XmlNode place = default;
		var child = element.FirstChild;
		bool seen = false;
		while (child.IsValid)
		{
			let next = child.NextSibling;
			if (child.Kind == .Text || child.Kind == .CData)
			{
				seen = true;
				child.Remove();
			}
			else if (seen && !place.IsValid)
				place = child;
			child = next;
		}
		if (text.IsEmpty)
			return;
		let added = element.AddText(text);
		if (place.IsValid)
			added.MoveBefore(place);
	}

	// Aliases

	/// @brief Move an attribute found under an older name to the current one (when the current one is
	/// not there), keeping its prefix.
	/// @param element The element.
	/// @param local The current local name.
	/// @param alias An older local name.
	/// @param namespaceUri The namespace (empty: none).
	public static void RenameAttributeAlias(XmlNode element, StringView local, StringView alias, StringView namespaceUri)
	{
		if (AttributePosition(element, local, namespaceUri) >= 0)
			return;
		int position = AttributePosition(element, alias, namespaceUri);
		if (position < 0)
			return;
		let old = element.Attributes[position];
		let name = scope String();
		if (!old.Prefix.IsEmpty)
			name.Append(old.Prefix, ":");
		name.Append(local);
		let value = scope String(old.Value);
		element.RemoveAttribute(scope String(old.Name));
		element.SetAttribute(name, value);
	}

	/// @brief Rename child elements found under an older name (when none has the current one), keeping
	/// their prefix.
	/// @param element The parent.
	/// @param local The current local name.
	/// @param alias An older local name.
	/// @param namespaceUri The namespace (empty: any).
	public static void RenameElementAlias(XmlNode element, StringView local, StringView alias, StringView namespaceUri)
	{
		if (HasElement(element, local, namespaceUri))
			return;
		for (let child in element.Children)
		{
			if (!IsElement(child, alias, namespaceUri))
				continue;
			let name = scope String();
			if (!child.Prefix.IsEmpty)
				name.Append(child.Prefix, ":");
			name.Append(local);
			child.Rename(name);
		}
	}

	// [XmlChildren] and strict types

	/// Splits a claim (`local` or `{namespace}local`) into its namespace (empty: none given) and local
	/// name.
	static void SplitClaim(StringView claim, out StringView ns, out StringView local)
	{
		ns = default;
		local = claim;
		if (claim.StartsWith('{'))
		{
			int close = claim.IndexOf('}');
			if (close > 0)
			{
				ns = claim.Substring(1, close - 1);
				local = claim.Substring(close + 1);
			}
		}
	}

	/// @brief Whether a field claims the child element `element`: a claim without a namespace matches its
	/// local name in any namespace (as element fields read), one with a namespace that namespace only.
	/// @param element The element.
	/// @param claimed The claims (`local` or `{namespace}local`).
	/// @return Whether it is claimed.
	public static bool IsClaimedElement(XmlNode element, Span<StringView> claimed)
	{
		if (claimed.IsEmpty)
			return false;
		StringView local = element.LocalName;
		bool namespaces = element.Document.mNamespaces;
		for (let claim in claimed)
		{
			SplitClaim(claim, let ns, let claimLocal);
			if (claimLocal == local && (ns.IsEmpty || !namespaces || element.NamespaceUri == ns))
				return true;
		}
		return false;
	}

	/// @brief Whether a field claims the attribute `attribute`: a claim without a namespace matches only
	/// an attribute in none (as attribute fields read), one with a namespace that namespace only.
	/// @param attribute The attribute.
	/// @param namespaces Whether its document was read with namespaces (else names match whole).
	/// @param claimed The claims (`local` or `{namespace}local`).
	/// @return Whether it is claimed.
	public static bool IsClaimedAttribute(XmlAttribute attribute, bool namespaces, Span<StringView> claimed)
	{
		for (let claim in claimed)
		{
			SplitClaim(claim, let ns, let claimLocal);
			if (!namespaces)
			{
				if (attribute.Name == claimLocal)
					return true;
			}
			else if (attribute.LocalName == claimLocal && attribute.NamespaceUri == ns)
				return true;
		}
		return false;
	}

	/// @brief The error for a child element no [XmlObject] type of an [XmlChildren] list is named after.
	/// @param child The child.
	/// @param expected The accepted names, "a, b, c".
	/// @return The error.
	public static XmlParseError UnknownChild(XmlNode child, StringView expected)
	{
		return MakeError(child, -1, default, scope $"unknown element: expected one of {expected}", .InvalidValue);
	}

	/// @brief Strict types: an error at the first attribute, child element or non-whitespace text that no
	/// field maps (namespace declarations and `xml:` attributes are always allowed).
	/// @param element The element read.
	/// @param attributes The attribute names the fields map.
	/// @param elements The child element names the fields map.
	/// @param allElements Whether a field takes every child element ([XmlChildren], an unwrapped
	/// KeysAsNames dictionary).
	/// @param allAttributes Whether a field takes every attribute (an unwrapped Attributes dictionary).
	/// @param text Whether a field maps the element's text.
	/// @return .Ok, or the error.
	public static Result<void, XmlParseError> CheckStrict(XmlNode element, Span<StringView> attributes, Span<StringView> elements, bool allElements, bool allAttributes, bool text)
	{
		int position = 0;
		for (let attribute in element.Attributes)
		{
			StringView name = attribute.Name;
			bool known = allAttributes || !attribute.IsSpecified || name == "xmlns" || name.StartsWith("xmlns:") || name.StartsWith("xml:") ||
				IsClaimedAttribute(attribute, element.Document.mNamespaces, attributes) || IsEntryKey(element, name);
			if (!known)
				return .Err(MakeError(element, position, name, "no field maps this attribute", .UnexpectedContent));
			position++;
		}
		for (let child in element.Children)
		{
			if (child.Kind == .Element && !allElements && !IsClaimedElement(child, elements))
				return .Err(MakeError(child, -1, default, "no field maps this element", .UnexpectedContent));
			if (!text && (child.Kind == .CData || (child.Kind == .Text && !child.IsWhitespace)))
				return .Err(MakeError(element, -1, default, "no field maps the text in this element", .UnexpectedContent));
		}
		return .Ok;
	}

	/// @brief The error for a root element that is not the type's.
	/// @param root The root element.
	/// @param local The expected local name.
	/// @param namespaceUri The expected namespace (empty: any).
	/// @return The error, or .Ok when it matches.
	public static Result<void, XmlParseError> CheckRoot(XmlNode root, StringView local, StringView namespaceUri)
	{
		if (!root.IsValid)
			return .Err(XmlParseError(.MissingValue, "The document has no root element", 0, 0, 0, 0));
		if (IsElement(root, local, namespaceUri))
			return .Ok;
		let expected = scope String()..AppendF("`{}`", local);
		if (!namespaceUri.IsEmpty)
			expected.AppendF(" in `{}`", namespaceUri);
		return .Err(MakeError(root, -1, default, scope $"expected the root element {expected}", .InvalidValue));
	}
}
