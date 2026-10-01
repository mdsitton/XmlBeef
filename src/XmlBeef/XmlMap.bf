using System;
using System.Collections;
using internal XmlBeef;

namespace XmlBeef;

/// @brief One dictionary entry as read (see XmlMapStyle): its key, its scalar value or the element an
/// object value is read from, or the error that makes it unreadable. Used by generated code.
public struct XmlMapEntry
{
	/// @brief The key's text and where it is.
	public XmlValueRef mKey;
	/// @brief The value's text and where it is (scalars), when mHasValue.
	public XmlValueRef mValue;
	/// @brief The element an object value is read from (the entry, or its value element).
	public XmlNode mElement;
	/// @brief Whether the entry has a value (an Entries value attribute or KeyValueElements value
	/// element can be missing: the entry is then skipped).
	public bool mHasValue;
	bool mFailed;
	XmlParseError mError;

	internal static XmlMapEntry Failed(XmlParseError error)
	{
		XmlMapEntry entry = default;
		entry.mFailed = true;
		entry.mError = error;
		return entry;
	}

	/// @brief The entry's error (a missing key), if any.
	/// @return .Ok, or the error.
	public Result<void, XmlParseError> Check()
	{
		if (mFailed)
			return .Err(mError);
		return .Ok;
	}
}

/// @brief The entries of a dictionary in `container`, in document order (see XmlMapStyle). Used by
/// generated code.
public struct XmlMapEntries : IEnumerable<XmlMapEntry>
{
	XmlNode mContainer;
	XmlMapStyle mStyle;
	StringView mEntry;
	StringView mKey;
	StringView mValue;
	StringView mNamespace;
	Span<StringView> mClaimed;

	/// @brief The entries.
	/// @param container The wrapper element, or for an unwrapped dictionary the owner.
	/// @param style The shape.
	/// @param entry The entry element name (TypedEntries: empty for any, else only that name).
	/// @param key The key attribute or element name.
	/// @param value The value attribute or element name (empty: the text).
	/// @param namespaceUri The entries' namespace (empty: any).
	/// @param claimed Unwrapped KeysAsNames and Attributes: the names other fields map, left out.
	public this(XmlNode container, XmlMapStyle style, StringView entry, StringView key, StringView value, StringView namespaceUri, Span<StringView> claimed)
	{
		mContainer = container;
		mStyle = style;
		mEntry = entry;
		mKey = key;
		mValue = value;
		mNamespace = namespaceUri;
		mClaimed = claimed;
	}

	public Enumerator GetEnumerator() => .(this);

	public struct Enumerator : IEnumerator<XmlMapEntry>
	{
		XmlMapEntries mMap;
		XmlNode mNext;
		int mAttribute;

		internal this(XmlMapEntries map)
		{
			mMap = map;
			mNext = map.mContainer.FirstChild;
			mAttribute = 0;
		}

		public Result<XmlMapEntry> GetNext() mut
		{
			if (mMap.mStyle == .Attributes)
				return NextAttribute();
			while (mNext.IsValid)
			{
				let child = mNext;
				mNext = mNext.NextSibling;
				if (child.Kind != .Element)
					continue;
				switch (mMap.mStyle)
				{
				case .KeysAsNames:
					if (!mMap.mClaimed.IsEmpty && XmlBind.IsClaimed(child.LocalName, mMap.mClaimed))
						continue;
					if (!mMap.mNamespace.IsEmpty && !XmlBind.IsElement(child, child.LocalName, mMap.mNamespace))
						continue;
					XmlMapEntry entry = default;
					entry.mKey = KeyFromName(child);
					entry.mValue = XmlBind.ElementValue(child);
					entry.mElement = child;
					entry.mHasValue = true;
					return entry;
				case .KeyValueElements:
					if (!XmlBind.IsElement(child, mMap.mEntry, mMap.mNamespace))
						continue;
					if (!(XmlBind.FindElement(child, mMap.mKey, mMap.mNamespace, true, let keyElement) case .Ok))
						return XmlMapEntry.Failed(XmlBind.MakeError(child, -1, default, scope $"The element `{mMap.mKey}` (the key) is required", .MissingValue));
					XmlMapEntry entry = default;
					entry.mKey = XmlBind.ElementValue(keyElement);
					entry.mKey.mName = mMap.mKey;
					if (XmlBind.FindElement(child, mMap.mValue, mMap.mNamespace, false, let valueElement) case .Ok(true))
					{
						entry.mValue = XmlBind.ElementValue(valueElement);
						entry.mElement = valueElement;
						entry.mHasValue = true;
					}
					return entry;
				default:
					// TypedEntries (any element, or only mEntry) and Entries (mEntry)
					if (!mMap.mEntry.IsEmpty && !XmlBind.IsElement(child, mMap.mEntry, mMap.mNamespace))
						continue;
					XmlMapEntry entry = default;
					switch (XmlBind.FindAttribute(child, mMap.mKey, "", true, out entry.mKey))
					{
					case .Err(let error):
						return XmlMapEntry.Failed(error);
					case .Ok:
					}
					entry.mElement = child;
					if (mMap.mStyle == .Entries && !mMap.mValue.IsEmpty)
					{
						if (XmlBind.FindAttribute(child, mMap.mValue, "", false, out entry.mValue) case .Ok(true))
							entry.mHasValue = true;
					}
					else
					{
						entry.mValue = XmlBind.ElementValue(child);
						entry.mHasValue = true;
					}
					return entry;
				}
			}
			return .Err;
		}

		Result<XmlMapEntry> NextAttribute() mut
		{
			let attributes = mMap.mContainer.Attributes;
			while (mAttribute < attributes.Count)
			{
				int position = mAttribute++;
				let attribute = attributes[position];
				StringView name = attribute.Name;
				if (!attribute.IsSpecified || name == "xmlns" || name.StartsWith("xmlns:") || name.StartsWith("xml:"))
					continue;
				if (!mMap.mClaimed.IsEmpty && XmlBind.IsClaimed(attribute.LocalName, mMap.mClaimed))
					continue;
				XmlMapEntry entry = default;
				entry.mKey.mElement = mMap.mContainer;
				entry.mKey.mAttribute = position;
				entry.mKey.mName = name;
				entry.mKey.mText = name;
				entry.mValue = entry.mKey;
				entry.mValue.mText = attribute.Value;
				entry.mElement = mMap.mContainer;
				entry.mHasValue = true;
				return entry;
			}
			return .Err;
		}

		static XmlValueRef KeyFromName(XmlNode element)
		{
			XmlValueRef key;
			key.mElement = element;
			key.mAttribute = -1;
			key.mName = default;
			key.mText = element.LocalName;
			return key;
		}
	}
}

/// @brief Writes a dictionary in place (see XmlMapStyle): the existing entries indexed by key once (the
/// last of repeated keys kept), each key written into its entry or a new one appended, and at Finish
/// the entries no key was written to removed. Used by generated code.
public class XmlMapWriter
{
	class Entry
	{
		public XmlNode mNode;
		public bool mUsed;
	}

	XmlNode mContainer;
	XmlMapStyle mStyle;
	StringView mEntry;
	StringView mKey;
	StringView mValue;
	StringView mNamespace;
	Dictionary<String, Entry> mEntries = new .() ~ DeleteDictionaryAndKeysAndValues!(_);

	/// @brief Index the dictionary's entries in `container` (parameters as XmlMapEntries).
	/// @param container The wrapper element, or for an unwrapped dictionary the owner.
	/// @param style The shape.
	/// @param entry The entry element name (TypedEntries: empty for any).
	/// @param key The key attribute or element name.
	/// @param value The value attribute or element name (empty: the text).
	/// @param namespaceUri The entries' namespace.
	/// @param claimed Unwrapped KeysAsNames and Attributes: the names other fields map, left alone.
	public this(XmlNode container, XmlMapStyle style, StringView entry, StringView key, StringView value, StringView namespaceUri, Span<StringView> claimed)
	{
		mContainer = container;
		mStyle = style;
		mEntry = entry;
		mKey = key;
		mValue = value;
		mNamespace = namespaceUri;
		for (let found in XmlMapEntries(container, style, entry, key, value, namespaceUri, claimed))
		{
			if (found.Check() case .Err)
				continue;
			let text = scope String(found.mKey.mText);
			if (mEntries.TryGetValue(text, let earlier))
			{
				// A repeated key: the last one is the one reading used
				if (style != .Attributes)
					XmlBind.RemoveWithIndent(EntryOf(earlier.mNode));
				earlier.mNode = found.mElement;
				continue;
			}
			let added = new Entry();
			added.mNode = style == .Attributes ? default : found.mElement;
			mEntries[new String(text)] = added;
		}
	}

	/// The entry element (for KeyValueElements, mNode may be the value element: its parent).
	XmlNode EntryOf(XmlNode node)
	{
		if (mStyle == .KeyValueElements && node.IsValid && !XmlBind.IsElement(node, mEntry, mNamespace))
			return node.Parent;
		return node;
	}

	/// @brief Write a scalar value for `key`.
	/// @param key The key's text.
	/// @param typeName TypedEntries: the value type's element name.
	/// @param text The value's text.
	/// @return .Ok, or an error for a key that cannot be a name (KeysAsNames, Attributes).
	public Result<void, XmlParseError> SetScalar(StringView key, StringView typeName, StringView text)
	{
		switch (mStyle)
		{
		case .Attributes:
			Try!(CheckName(key));
			MarkUsed(key);
			XmlBind.SetAttribute(mContainer, key, "", text);
		case .Entries:
			let element = Get(key, mEntry, mNamespace);
			if (mValue.IsEmpty)
				XmlBind.ReplaceText(element, text);
			else
				XmlBind.SetAttribute(element, mValue, "", text);
		case .KeyValueElements:
			XmlBind.ReplaceText(XmlBind.ChildElement(Get(key, mEntry, mNamespace), mValue, mNamespace), text);
		case .KeysAsNames:
			Try!(CheckName(key));
			XmlBind.ReplaceText(Get(key, key, mNamespace), text);
		case .TypedEntries:
			XmlBind.ReplaceText(Get(key, typeName, mNamespace), text);
		}
		return .Ok;
	}

	/// @brief The element to write an object value for `key` into.
	/// @param key The key's text.
	/// @param typeName The object's element name (TypedEntries).
	/// @param namespaceUri The object's namespace (TypedEntries; empty: the dictionary's).
	/// @return The element, or an error for a key that cannot be a name (KeysAsNames).
	public Result<XmlNode, XmlParseError> ObjectElement(StringView key, StringView typeName, StringView namespaceUri)
	{
		switch (mStyle)
		{
		case .KeyValueElements:
			return XmlBind.ChildElement(Get(key, mEntry, mNamespace), mValue, mNamespace);
		case .KeysAsNames:
			Try!(CheckName(key));
			return Get(key, key, mNamespace);
		case .Entries:
			return Get(key, mEntry, mNamespace);
		default:
			return Get(key, typeName, namespaceUri.IsEmpty ? mNamespace : namespaceUri);
		}
	}

	/// @brief Remove the entries no key was written to.
	public void Finish()
	{
		for (let pair in mEntries)
		{
			if (pair.value.mUsed)
				continue;
			if (mStyle == .Attributes)
				XmlBind.RemoveAttribute(mContainer, pair.key, "");
			else
				XmlBind.RemoveWithIndent(EntryOf(pair.value.mNode));
		}
	}

	void MarkUsed(StringView key)
	{
		if (mEntries.TryGetValueAlt(key, let entry))
			entry.mUsed = true;
		else
		{
			let added = new Entry();
			added.mUsed = true;
			mEntries[new String(key)] = added;
		}
	}

	Result<void, XmlParseError> CheckName(StringView key)
	{
		if (XmlDocument.IsValidName(key, false) && !key.Contains(':'))
			return .Ok;
		return .Err(XmlBind.MakeError(mContainer, -1, default, scope $"the key `{key}` cannot be written as an XML name", .InvalidValue));
	}

	/// The entry element for `key` named `name`: the existing one (replaced when a TypedEntries entry's
	/// type changed), or a new one after the last entry, with the key written.
	XmlNode Get(StringView key, StringView name, StringView namespaceUri)
	{
		Entry entry;
		if (mEntries.TryGetValueAlt(key, out entry) && entry.mNode.IsValid)
		{
			entry.mUsed = true;
			XmlNode element = EntryOf(entry.mNode);
			if (XmlBind.IsElement(element, name, namespaceUri))
				return element;
			// Another type: a new entry in its place
			let replacement = NewEntry(key, name, namespaceUri, element);
			XmlBind.RemoveWithIndent(element);
			entry.mNode = replacement;
			return replacement;
		}
		let created = NewEntry(key, name, namespaceUri, default);
		if (entry == null)
		{
			entry = new Entry();
			mEntries[new String(key)] = entry;
		}
		entry.mNode = created;
		entry.mUsed = true;
		return created;
	}

	XmlNode NewEntry(StringView key, StringView name, StringView namespaceUri, XmlNode after)
	{
		let element = XmlBind.NewChild(mContainer, name, namespaceUri, after);
		switch (mStyle)
		{
		case .TypedEntries, .Entries:
			element.SetAttribute(mKey, key);
		case .KeyValueElements:
			XmlBind.ReplaceText(XmlBind.ChildElement(element, mKey, mNamespace), key);
		default:
		}
		return element;
	}
}

extension XmlBind
{
	/// @brief The error for a TypedEntries entry whose element name is not its value type's.
	/// @param element The entry.
	/// @param typeName The expected element name.
	/// @return .Ok when it matches, or the error.
	public static Result<void, XmlParseError> CheckEntryType(XmlNode element, StringView typeName)
	{
		if (element.LocalName == typeName)
			return .Ok;
		return .Err(MakeError(element, -1, default, scope $"expected a `{typeName}` entry", .InvalidValue));
	}

	[ThreadStatic]
	static XmlNode sEntryElement;
	[ThreadStatic]
	static StringView sEntryKey;

	/// @brief Before reading an object value from a dictionary entry that holds its key in an attribute:
	/// a strict type's check allows that attribute there.
	/// @param element The entry element.
	/// @param key The key attribute's name (empty: none).
	/// @return The previous state, for LeaveEntry.
	public static (XmlNode, StringView) EnterEntry(XmlNode element, StringView key)
	{
		let previous = (sEntryElement, sEntryKey);
		sEntryElement = element;
		sEntryKey = key;
		return previous;
	}

	/// @brief After reading the entry's object value.
	/// @param previous What EnterEntry returned.
	public static void LeaveEntry((XmlNode, StringView) previous)
	{
		sEntryElement = previous.0;
		sEntryKey = previous.1;
	}

	/// Whether `name` on `element` is the key attribute of the entry being read.
	internal static bool IsEntryKey(XmlNode element, StringView name)
	{
		return !sEntryKey.IsEmpty && sEntryElement == element && name == sEntryKey;
	}
}
