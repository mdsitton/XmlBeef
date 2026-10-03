using System;
using System.Collections;
using FormatCore;
using internal FormatCore;
using internal XmlBeef;

namespace XmlBeef;

/// Lookups on a node: attributes (as text and typed), child and descendant elements by name or by
/// namespace and local name, and text content.
///
/// The `Find` and `Get…`/`TryGet…` methods also accept the empty handle that a failed Find returns, so
/// lookups chain: `doc.Root.Find("defs").Find("linearGradient").GetDouble("x1", 0)` is 0 when any step
/// is missing.
extension XmlNode
{
	/// Whether this is the empty handle (default, as a failed Find returns).
	bool IsNone => mDocument == null;

	// Finding elements

	/// @brief The first child element with the given qualified name.
	/// @param name The name as written (`svg:rect` with a prefix).
	/// @return The element, or an invalid handle (also for an invalid handle, so Finds chain).
	public XmlNode Find(StringView name)
	{
		if (IsNone)
			return default;
		return Children.Named(name).First;
	}

	/// @brief The first child element in a namespace with a local name.
	/// @param namespaceUri The namespace name (empty: no namespace).
	/// @param localName The local name.
	/// @return The element, or an invalid handle (also for an invalid handle, so Finds chain).
	public XmlNode Find(StringView namespaceUri, StringView localName)
	{
		if (IsNone)
			return default;
		return Children.Named(namespaceUri, localName).First;
	}

	/// @brief Every element below this node, depth first, in document order (an element, then its
	/// descendants): `for (let path in svg.Descendants.Named("path"))`. Do not change the document
	/// during the loop.
	public XmlDescendants Descendants
	{
		get
		{
			Runtime.Assert(IsValid, "XmlNode: the handle is invalid");
			return .(mDocument, mId);
		}
	}

	// Attributes

	/// @brief The value of the attribute with this qualified name.
	/// @param name The name as written (`xlink:href`).
	/// @param value Receives the value, valid until the document changes.
	/// @return Whether the element has the attribute.
	public bool TryGetAttribute(StringView name, out StringView value)
	{
		value = default;
		if (IsNone || Kind != .Element)
			return false;
		int index = FindAttribute(name);
		if (index < 0)
			return false;
		value = mDocument.mAttributes[index].mValue;
		return true;
	}

	/// @brief The value of the attribute in a namespace with a local name.
	/// @param namespaceUri The namespace name (empty: no namespace, as for unprefixed attributes).
	/// @param localName The local name.
	/// @param value Receives the value, valid until the document changes.
	/// @return Whether the element has the attribute.
	public bool TryGetAttribute(StringView namespaceUri, StringView localName, out StringView value)
	{
		value = default;
		if (IsNone || Kind != .Element)
			return false;
		int index = FindAttribute(namespaceUri, localName);
		if (index < 0)
			return false;
		value = mDocument.mAttributes[index].mValue;
		return true;
	}

	/// @brief Whether the element has an attribute with this qualified name.
	/// @param name The name as written.
	/// @return Whether it does.
	public bool HasAttribute(StringView name) => TryGetAttribute(name, let value);

	/// @brief An attribute's value, or `defaultValue` when the element does not have it.
	/// @param name The name as written.
	/// @param defaultValue The fallback.
	/// @return The value (valid until the document changes) or the fallback.
	public StringView GetAttribute(StringView name, StringView defaultValue = default) => TryGetAttribute(name, let value) ? value : defaultValue;

	/// @brief An attribute as an int32: optional whitespace, an optional sign, decimal digits, checked
	/// for overflow.
	/// @param name The name as written.
	/// @param value Receives the number.
	/// @return Whether the element has the attribute and it is such a number.
	public bool TryGetInt32(StringView name, out int32 value)
	{
		value = 0;
		int64 wide = 0;
		if (!TryGetAttribute(name, let text) || !XmlValueParser.TryParseInt64(text, out wide) || wide < int32.MinValue || wide > int32.MaxValue)
			return false;
		value = (int32)wide;
		return true;
	}

	/// @brief An attribute as an int64: optional whitespace, an optional sign, decimal digits, checked
	/// for overflow.
	/// @param name The name as written.
	/// @param value Receives the number.
	/// @return Whether the element has the attribute and it is such a number.
	public bool TryGetInt64(StringView name, out int64 value)
	{
		value = 0;
		return TryGetAttribute(name, let text) && XmlValueParser.TryParseInt64(text, out value);
	}

	/// @brief An attribute as a double: a decimal number with an optional fraction and exponent
	/// (culture-independent), `INF`, `-INF` or `NaN`, with optional whitespace around it.
	/// @param name The name as written.
	/// @param value Receives the number.
	/// @return Whether the element has the attribute and it is such a number.
	public bool TryGetDouble(StringView name, out double value)
	{
		value = 0;
		return TryGetAttribute(name, let text) && XmlValueParser.TryParseDouble(text, out value);
	}

	/// @brief An attribute as a boolean: `true`, `false`, `1` or `0` (XML Schema's), with optional
	/// whitespace around it.
	/// @param name The name as written.
	/// @param value Receives the boolean.
	/// @return Whether the element has the attribute and it is such a boolean.
	public bool TryGetBool(StringView name, out bool value)
	{
		value = false;
		return TryGetAttribute(name, let text) && XmlValueParser.TryParseBool(text, out value);
	}

	/// @brief An int32 attribute, or `defaultValue` when it is absent or not an int32.
	/// @param name The name as written.
	/// @param defaultValue The fallback.
	/// @return The number or the fallback.
	public int32 GetInt32(StringView name, int32 defaultValue = 0) => TryGetInt32(name, let v) ? v : defaultValue;

	/// @brief An int64 attribute, or `defaultValue` when it is absent or not an int64.
	/// @param name The name as written.
	/// @param defaultValue The fallback.
	/// @return The number or the fallback.
	public int64 GetInt64(StringView name, int64 defaultValue = 0) => TryGetInt64(name, let v) ? v : defaultValue;

	/// @brief A double attribute, or `defaultValue` when it is absent or not a number.
	/// @param name The name as written.
	/// @param defaultValue The fallback.
	/// @return The number or the fallback.
	public double GetDouble(StringView name, double defaultValue = 0) => TryGetDouble(name, let v) ? v : defaultValue;

	/// @brief A boolean attribute, or `defaultValue` when it is absent or not a boolean.
	/// @param name The name as written.
	/// @param defaultValue The fallback.
	/// @return The boolean or the fallback.
	public bool GetBool(StringView name, bool defaultValue = false) => TryGetBool(name, let v) ? v : defaultValue;

	// Text

	/// @brief The text of the node's own Text and CDATA children, concatenated (`<title>x</title>` is
	/// `x`); for a Text or CData node, its value. Empty for the empty handle. A single piece is a view;
	/// several are joined into a copy the document owns (freed with it).
	public StringView Text
	{
		get
		{
			if (IsNone)
				return default;
			ref XmlNodeRecord node = ref Record;
			if (node.mKind == .Text || node.mKind == .CData)
				return node.mValue;
			StringView single = default;
			int pieces = 0;
			for (uint32 id = node.mFirstChild; id != 0; id = mDocument.mNodes[id].mNextSibling)
			{
				ref XmlNodeRecord child = ref mDocument.mNodes[id];
				if (child.mKind == .Text || child.mKind == .CData)
				{
					single = child.mValue;
					pieces++;
				}
			}
			if (pieces <= 1)
				return single;
			let joined = scope String();
			AppendText(joined);
			return mDocument.mStore.NewText(joined);
		}
	}

	/// @brief Append the text of the node's own Text and CDATA children (see Text).
	/// @param output The string to append to.
	public void AppendText(String output)
	{
		if (IsNone)
			return;
		ref XmlNodeRecord node = ref Record;
		if (node.mKind == .Text || node.mKind == .CData)
		{
			output.Append(node.mValue);
			return;
		}
		for (uint32 id = node.mFirstChild; id != 0; id = mDocument.mNodes[id].mNextSibling)
		{
			ref XmlNodeRecord child = ref mDocument.mNodes[id];
			if (child.mKind == .Text || child.mKind == .CData)
				output.Append(child.mValue);
		}
	}

	/// @brief Append all the text below the node (Text and CDATA of every descendant, in document
	/// order): `<p>a <b>b</b> c</p>` is `a b c`.
	/// @param output The string to append to.
	public void AppendInnerText(String output)
	{
		if (IsNone)
			return;
		ref XmlNodeRecord node = ref Record;
		if (node.mKind == .Text || node.mKind == .CData)
		{
			output.Append(node.mValue);
			return;
		}
		uint32 id = node.mFirstChild;
		while (id != 0)
		{
			ref XmlNodeRecord current = ref mDocument.mNodes[id];
			if (current.mKind == .Text || current.mKind == .CData)
				output.Append(current.mValue);
			if (current.mKind == .Element && current.mFirstChild != 0)
			{
				id = current.mFirstChild;
				continue;
			}
			// The next sibling, or that of the nearest ancestor below this node that has one
			while (id != mId && mDocument.mNodes[id].mNextSibling == 0)
				id = mDocument.mNodes[id].mParent;
			if (id == mId)
				break;
			id = mDocument.mNodes[id].mNextSibling;
		}
	}
}

/// Every element below a node (XmlNode.Descendants), depth first in document order, optionally only
/// those with a name. Do not change the document while enumerating; using it after the document is
/// cleared or read again is a fatal error.
public struct XmlDescendants : IEnumerable<XmlNode>
{
	XmlDocument mDocument;
	uint32 mRoot;
	StringView mName;
	StringView mNamespace;
	bool mFiltered;
	bool mByNamespace;
	uint32 mGeneration;

	internal this(XmlDocument document, uint32 root)
	{
		mDocument = document;
		mRoot = root;
		mName = default;
		mNamespace = default;
		mFiltered = false;
		mByNamespace = false;
		mGeneration = document.mGeneration;
	}

	/// @brief Only the descendants with a qualified name: `svg.Descendants.Named("path")`.
	/// @param name The name as written (borrowed for the loop).
	/// @return The matching descendants, in the same order.
	public XmlDescendants Named(StringView name)
	{
		var named = this;
		named.mName = name;
		named.mFiltered = true;
		named.mByNamespace = false;
		return named;
	}

	/// @brief Only the descendants in a namespace with a local name.
	/// @param namespaceUri The namespace name (empty: no namespace); borrowed for the loop.
	/// @param localName The local name (borrowed for the loop).
	/// @return The matching descendants, in the same order.
	public XmlDescendants Named(StringView namespaceUri, StringView localName)
	{
		var named = this;
		named.mName = localName;
		named.mNamespace = namespaceUri;
		named.mFiltered = true;
		named.mByNamespace = true;
		return named;
	}

	/// @brief The first match, depth first.
	/// @return The element, or an invalid handle when there is none.
	public XmlNode First => XmlNode.Of(mDocument, Match(After(mRoot, true)));

	/// @brief The number of matches. Walks the subtree.
	public int Count
	{
		get
		{
			int count = 0;
			for (uint32 id = Match(After(mRoot, true)); id != 0; id = Match(After(id, true)))
				count++;
			return count;
		}
	}

	/// The node after `id` in depth-first order within the subtree, or 0 at its end. With `enter`,
	/// `id`'s own children come first.
	uint32 After(uint32 id, bool enter)
	{
		mDocument.CheckView(mGeneration, mRoot);
		if (enter && mDocument.mNodes[id].mFirstChild != 0 && (id == mRoot || mDocument.mNodes[id].mKind == .Element))
			return mDocument.mNodes[id].mFirstChild;
		var id;
		while (id != mRoot)
		{
			uint32 next = mDocument.mNodes[id].mNextSibling;
			if (next != 0)
				return next;
			id = mDocument.mNodes[id].mParent;
		}
		return 0;
	}

	/// The first element from `id` on (itself included) that matches the filter, or 0
	uint32 Match(uint32 id)
	{
		var id;
		while (id != 0 && !mDocument.Matches(id, mName, mFiltered, mNamespace, mByNamespace))
			id = After(id, true);
		return id;
	}

	public Enumerator GetEnumerator() => .(this);

	public struct Enumerator : IEnumerator<XmlNode>
	{
		XmlDescendants mNodes;
		uint32 mNext;

		internal this(XmlDescendants nodes)
		{
			mNodes = nodes;
			mNext = nodes.Match(nodes.After(nodes.mRoot, true));
		}

		public Result<XmlNode> GetNext() mut
		{
			if (mNext == 0)
				return .Err;
			let node = XmlNode(mNodes.mDocument, mNext);
			mNext = mNodes.Match(mNodes.After(mNext, true));
			return node;
		}
	}
}

/// Parsing of attribute and text values into numbers and booleans.
internal static class XmlValueParser
{
	/// The text without XML whitespace at either end.
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

	public static bool TryParseInt64(StringView text, out int64 value)
	{
		value = 0;
		let s = Trim(text);
		int i = 0;
		bool negative = false;
		if (i < s.Length && (s[i] == '-' || s[i] == '+'))
		{
			negative = s[i] == '-';
			i++;
		}
		if (i == s.Length)
			return false;
		uint64 magnitude = 0;
		for (; i < s.Length; i++)
		{
			char8 c = s[i];
			if (c < '0' || c > '9')
				return false;
			uint64 digit = (uint64)(c - '0');
			if (magnitude > (uint64.MaxValue - digit) / 10)
				return false;
			magnitude = magnitude * 10 + digit;
		}
		if (negative)
		{
			if (magnitude > (uint64)int64.MaxValue + 1)
				return false;
			value = (int64)(0 - magnitude);
		}
		else
		{
			if (magnitude > (uint64)int64.MaxValue)
				return false;
			value = (int64)magnitude;
		}
		return true;
	}

	public static bool TryParseDouble(StringView text, out double value)
	{
		value = 0;
		let s = Trim(text);
		switch (s)
		{
		case "INF", "+INF":
			value = double.PositiveInfinity;
			return true;
		case "-INF":
			value = double.NegativeInfinity;
			return true;
		case "NaN":
			value = double.NaN;
			return true;
		}
		// Only the decimal forms: digits, one `.`, an exponent (Double.Parse alone accepts more)
		int i = 0;
		if (i < s.Length && (s[i] == '-' || s[i] == '+'))
			i++;
		int digits = 0;
		while (i < s.Length && s[i] >= '0' && s[i] <= '9')
		{
			i++;
			digits++;
		}
		if (i < s.Length && s[i] == '.')
		{
			i++;
			while (i < s.Length && s[i] >= '0' && s[i] <= '9')
			{
				i++;
				digits++;
			}
		}
		if (digits == 0)
			return false;
		if (i < s.Length && (s[i] == 'e' || s[i] == 'E'))
		{
			i++;
			if (i < s.Length && (s[i] == '-' || s[i] == '+'))
				i++;
			int exponentDigits = 0;
			while (i < s.Length && s[i] >= '0' && s[i] <= '9')
			{
				i++;
				exponentDigits++;
			}
			if (exponentDigits == 0)
				return false;
		}
		if (i != s.Length)
			return false;
		// Correctly rounded and culture-independent (FormatCore's DecimalParse: Clinger's fast path, then
		// corlib's parser with `.` pinned)
		return DecimalParse.ParseDouble(s, out value);
	}

	public static bool TryParseBool(StringView text, out bool value)
	{
		value = false;
		switch (Trim(text))
		{
		case "true", "1":
			value = true;
			return true;
		case "false", "0":
			return true;
		default:
			return false;
		}
	}
}
