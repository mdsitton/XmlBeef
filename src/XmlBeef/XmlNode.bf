using System;
using System.Collections;
using internal XmlBeef;

namespace XmlBeef;

/// @brief A node's identity within its document: an index into the document's node table. Stable
/// while the node is in the document; not stable across reads.
public struct XmlNodeId : IHashable, IEquatable<XmlNodeId>
{
	internal uint32 mValue;

	internal this(uint32 value)
	{
		mValue = value;
	}

	/// @brief The ID as a number, for use as an index into per-node side tables (0 is the document node).
	public uint32 Value => mValue;

	public int GetHashCode() => (int)mValue;
	public bool Equals(XmlNodeId other) => mValue == other.mValue;
	public static bool operator ==(XmlNodeId lhs, XmlNodeId rhs) => lhs.mValue == rhs.mValue;
	public static bool operator !=(XmlNodeId lhs, XmlNodeId rhs) => lhs.mValue != rhs.mValue;

	public override void ToString(String output)
	{
		mValue.ToString(output);
	}
}

/// A node of an XmlDocument: a handle (the document and the node's ID) whose properties read the
/// document. Handles are small values; copy them freely.
///
/// A handle is valid while its document is not cleared or read again. Reading from an invalid handle
/// is a fatal error, except for the navigation properties (`Parent`, `FirstChild`, …), which return
/// invalid handles where there is no such node, and the lookups (`Find`, `TryGetAttribute`, …), which
/// treat the default handle (a failed Find's) as "no node" so they chain; check `IsValid`.
public struct XmlNode : IEquatable<XmlNode>
{
	internal XmlDocument mDocument;
	internal uint32 mId;
	uint32 mGeneration;

	internal this(XmlDocument document, uint32 id)
	{
		mDocument = document;
		mId = id;
		mGeneration = document.mGeneration;
	}

	/// A handle to node `id`, or the invalid (default) handle for 0 (which here means "none": the
	/// document node is only reached through XmlDocument.DocumentNode).
	internal static XmlNode Of(XmlDocument document, uint32 id)
	{
		return id != 0 ? XmlNode(document, id) : default;
	}

	/// @brief Whether the handle refers to a node that is still in its document.
	public bool IsValid => mDocument != null && mGeneration == mDocument.mGeneration && mDocument.IsLive(mId);
	/// @brief The node's ID in its document.
	public XmlNodeId Id => .(mId);
	/// @brief The document the node belongs to.
	public XmlDocument Document => mDocument;

	internal ref XmlNodeRecord Record
	{
		get
		{
			if (!IsValid)
				Runtime.FatalError("XmlNode: the handle is invalid (no node, or a cleared document)");
			return ref mDocument.mNodes[mId];
		}
	}

	XmlNode Link(uint32 id) => Of(mDocument, id);

	/// @brief What the node is.
	public XmlNodeKind Kind => Record.mKind;
	/// @brief Whether the node is an element.
	public bool IsElement => IsValid && mDocument.mNodes[mId].mKind == .Element;

	/// @brief Element: the qualified name as written. ProcessingInstruction: the target.
	/// EntityReference: the entity's name. DocType: the root element's name. Empty for other kinds.
	public StringView Name => mDocument.mNames[Record.mName];
	/// @brief The name's interned ID in the document's name table.
	public XmlNameId NameId => Record.mName;
	/// @brief Element: the local part of the name (the name itself without a prefix or without
	/// namespaces).
	public StringView LocalName
	{
		get
		{
			ref XmlNodeRecord node = ref Record;
			if (node.mKind != .Element || !mDocument.mNamespaces)
				return mDocument.mNames[node.mName];
			return mDocument.mNames[mDocument.mNames.LocalOf(node.mName)];
		}
	}
	/// @brief Element: the prefix (empty if none, or without namespaces).
	public StringView Prefix
	{
		get
		{
			ref XmlNodeRecord node = ref Record;
			if (node.mKind != .Element || !mDocument.mNamespaces)
				return default;
			return mDocument.mNames[mDocument.mNames.PrefixOf(node.mName)];
		}
	}
	/// @brief Element: the namespace name (empty for none).
	public StringView NamespaceUri => mDocument.mNames[Record.mNamespace];
	/// @brief Text, CData, Comment: the content. ProcessingInstruction: the data. Empty otherwise.
	public StringView Value => Record.mValue;
	/// @brief Element: whether it was written as an empty-element tag (`<a/>`).
	public bool IsEmptyTag => Record.mFlags.HasFlag(.EmptyTag);

	/// @brief Text, CData: whether the value is all whitespace (space, tab, LF, CR).
	public bool IsWhitespace
	{
		get
		{
			for (let c in Record.mValue)
			{
				if (!XmlChar.IsSpace(c))
					return false;
			}
			return true;
		}
	}

	// Navigation

	/// @brief The parent node: an element, the DOCTYPE (for its processing instructions), or the document
	/// node (XmlDocument.DocumentNode) for the root element and what is around it.
	public XmlNode Parent
	{
		get
		{
			ref XmlNodeRecord node = ref Record;
			if (mId == 0)
				return default;
			return XmlNode(mDocument, node.mParent);
		}
	}
	/// @brief The first child node; invalid when there are no children.
	public XmlNode FirstChild => Link(Record.mFirstChild);
	/// @brief The last child node; invalid when there are no children.
	public XmlNode LastChild => Link(Record.mLastChild);
	/// @brief The next node with the same parent; invalid for the last one.
	public XmlNode NextSibling => Link(Record.mNextSibling);
	/// @brief The previous node with the same parent; invalid for the first one.
	public XmlNode PreviousSibling => Link(Record.mPrevSibling);
	/// @brief The child nodes, in order (every kind).
	public XmlNodeList Children
	{
		get
		{
			Runtime.Assert(IsValid, "XmlNode: the handle is invalid");
			return .(mDocument, mId);
		}
	}
	/// @brief Whether the node has children.
	public bool HasChildren => Record.mFirstChild != 0;
	/// @brief The number of child nodes (every kind).
	public int ChildCount => Record.mChildCount;

	/// @brief The node's depth: 0 for the root element and the nodes beside it. Walks up the tree.
	public int Depth
	{
		get
		{
			int depth = 0;
			uint32 id = Record.mParent;
			while (id != 0)
			{
				depth++;
				id = mDocument.mNodes[id].mParent;
			}
			return depth;
		}
	}

	// Attributes

	/// @brief Element: its attributes, in order (specified ones as written, then defaulted ones).
	public XmlAttributeList Attributes
	{
		get
		{
			Runtime.Assert(IsValid, "XmlNode: the handle is invalid");
			return .(mDocument, mId);
		}
	}

	/// @brief Element: the number of attributes.
	public int AttributeCount => Record.mAttributeCount;

	/// The attribute index of the one named `name` (qualified, as written), or -1.
	internal int FindAttribute(StringView name)
	{
		ref XmlNodeRecord node = ref Record;
		let names = mDocument.mNames;
		for (int i = node.mAttributeStart; i < node.mAttributeStart + node.mAttributeCount; i++)
		{
			if (names[mDocument.mAttributes[i].mName] == name)
				return i;
		}
		return -1;
	}

	/// The attribute index of the one in `namespaceUri` (empty: none) named `localName`, or -1.
	internal int FindAttribute(StringView namespaceUri, StringView localName)
	{
		ref XmlNodeRecord node = ref Record;
		let names = mDocument.mNames;
		for (int i = node.mAttributeStart; i < node.mAttributeStart + node.mAttributeCount; i++)
		{
			ref XmlAttributeRecord attribute = ref mDocument.mAttributes[i];
			if (names[attribute.mLocal] == localName && names[attribute.mNamespace] == namespaceUri)
				return i;
		}
		return -1;
	}

	public bool Equals(XmlNode other) => mDocument == other.mDocument && mId == other.mId && mGeneration == other.mGeneration;
	public static bool operator ==(XmlNode lhs, XmlNode rhs) => lhs.Equals(rhs);
	public static bool operator !=(XmlNode lhs, XmlNode rhs) => !lhs.Equals(rhs);
}

/// The children of a node, in order: a live view, valid while its document is not cleared or read
/// again (using it after that is a fatal error).
public struct XmlNodeList : IEnumerable<XmlNode>
{
	XmlDocument mDocument;
	uint32 mParent;
	uint32 mGeneration;

	internal this(XmlDocument document, uint32 parent)
	{
		mDocument = document;
		mParent = parent;
		mGeneration = document.mGeneration;
	}

	/// @brief Whether the view can still be used.
	public bool IsValid => mDocument != null && mGeneration == mDocument.mGeneration && mDocument.IsLive(mParent);

	ref XmlNodeRecord Parent
	{
		get
		{
			mDocument.CheckView(mGeneration, mParent);
			return ref mDocument.mNodes[mParent];
		}
	}

	/// @brief The number of nodes.
	public int Count => Parent.mChildCount;
	/// @brief Whether there are none.
	public bool IsEmpty => Parent.mFirstChild == 0;
	/// @brief The first node; invalid when there are none.
	public XmlNode First => XmlNode.Of(mDocument, Parent.mFirstChild);
	/// @brief The last node; invalid when there are none.
	public XmlNode Last => XmlNode.Of(mDocument, Parent.mLastChild);

	/// @brief The child elements only, in order.
	public XmlElementList Elements => .(mDocument, Parent.mFirstChild, default, false, default, false);

	/// @brief The child elements with the given qualified name, in order:
	/// `for (let stop in gradient.Children.Named("stop"))`.
	/// @param name The name as written (borrowed for the loop).
	/// @return The matching elements.
	public XmlElementList Named(StringView name) => .(mDocument, Parent.mFirstChild, name, true, default, false);

	/// @brief The child elements in a namespace with a local name, in order.
	/// @param namespaceUri The namespace name (empty: no namespace); borrowed for the loop.
	/// @param localName The local name (borrowed for the loop).
	/// @return The matching elements.
	public XmlElementList Named(StringView namespaceUri, StringView localName) => .(mDocument, Parent.mFirstChild, localName, true, namespaceUri, true);

	public Enumerator GetEnumerator() => .(mDocument, Parent.mFirstChild);

	/// Walks the sibling links, reading the next node before returning the current one.
	public struct Enumerator : IEnumerator<XmlNode>
	{
		XmlDocument mDocument;
		uint32 mNext;
		uint32 mGeneration;

		internal this(XmlDocument document, uint32 first)
		{
			mDocument = document;
			mNext = first;
			mGeneration = document.mGeneration;
		}

		public Result<XmlNode> GetNext() mut
		{
			if (mNext == 0)
				return .Err;
			mDocument.CheckView(mGeneration, 0);
			let node = XmlNode(mDocument, mNext);
			mNext = mDocument.mNodes[mNext].mNextSibling;
			return node;
		}
	}
}

/// Sibling elements, optionally filtered by name (XmlNodeList.Elements and Named). Reads the next
/// match before returning the current one; using it after the document is cleared or read again is a
/// fatal error.
public struct XmlElementList : IEnumerable<XmlNode>
{
	XmlDocument mDocument;
	uint32 mFirst;
	StringView mName;
	StringView mNamespace;
	bool mFiltered;
	bool mByNamespace;
	uint32 mGeneration;

	internal this(XmlDocument document, uint32 first, StringView name, bool filtered, StringView namespaceUri, bool byNamespace)
	{
		mDocument = document;
		mFirst = first;
		mName = name;
		mFiltered = filtered;
		mNamespace = namespaceUri;
		mByNamespace = byNamespace;
		mGeneration = document.mGeneration;
	}

	/// @brief The first match.
	/// @return The element, or an invalid handle when there is none.
	public XmlNode First => XmlNode.Of(mDocument, Next(mFirst));

	/// @brief The number of matches (walks the siblings).
	public int Count
	{
		get
		{
			int count = 0;
			for (uint32 id = Next(mFirst); id != 0; id = Next(mDocument.mNodes[id].mNextSibling))
				count++;
			return count;
		}
	}

	/// The first matching node from `id` on (itself included), or 0
	uint32 Next(uint32 id)
	{
		mDocument.CheckView(mGeneration, 0);
		var id;
		while (id != 0 && !mDocument.Matches(id, mName, mFiltered, mNamespace, mByNamespace))
			id = mDocument.mNodes[id].mNextSibling;
		return id;
	}

	public Enumerator GetEnumerator() => .(this);

	public struct Enumerator : IEnumerator<XmlNode>
	{
		XmlElementList mList;
		uint32 mNext;

		internal this(XmlElementList list)
		{
			mList = list;
			mNext = list.Next(list.mFirst);
		}

		public Result<XmlNode> GetNext() mut
		{
			if (mNext == 0)
				return .Err;
			let node = XmlNode(mList.mDocument, mNext);
			mNext = mList.Next(mList.mDocument.mNodes[mNext].mNextSibling);
			return node;
		}
	}
}

extension XmlDocument
{
	/// Whether node `id` is an element matching the filter: any element, a qualified name, or (by
	/// namespace) a namespace and local name.
	internal bool Matches(uint32 id, StringView name, bool filtered, StringView namespaceUri, bool byNamespace)
	{
		ref XmlNodeRecord node = ref mNodes[id];
		if (node.mKind != .Element)
			return false;
		if (!filtered)
			return true;
		if (!byNamespace)
			return mNames[node.mName] == name;
		XmlNameId local = mNamespaces ? mNames.LocalOf(node.mName) : node.mName;
		return mNames[local] == name && mNames[node.mNamespace] == namespaceUri;
	}
}

/// @brief An attribute of an element: a view of the document's attribute table, valid while the
/// document is not cleared or read again.
public struct XmlAttribute
{
	XmlDocument mDocument;
	int mIndex;

	internal this(XmlDocument document, int index)
	{
		mDocument = document;
		mIndex = index;
	}

	ref XmlAttributeRecord Record => ref mDocument.mAttributes[mIndex];

	/// @brief The qualified name as written.
	public StringView Name => mDocument.mNames[Record.mName];
	/// @brief The local name (the name itself without a prefix or without namespaces).
	public StringView LocalName => mDocument.mNames[Record.mLocal];
	/// @brief The prefix (empty if none, or without namespaces).
	public StringView Prefix
	{
		get
		{
			if (!mDocument.mNamespaces)
				return default;
			return mDocument.mNames[mDocument.mNames.PrefixOf(Record.mName)];
		}
	}
	/// @brief The namespace name (empty for none: an unprefixed attribute is in no namespace).
	public StringView NamespaceUri => mDocument.mNames[Record.mNamespace];
	/// @brief The normalized value (§3.3.3).
	public StringView Value => Record.mValue;
	/// @brief Whether it was written in the tag (false: a default from an ATTLIST declaration).
	public bool IsSpecified => !Record.mFlags.HasFlag(.Defaulted);
	/// @brief The name's interned ID.
	public XmlNameId NameId => Record.mName;
}

/// An element's attributes, in order: a live view, valid while its document is not cleared or read
/// again.
public struct XmlAttributeList : IEnumerable<XmlAttribute>
{
	XmlDocument mDocument;
	uint32 mElement;
	uint32 mGeneration;

	internal this(XmlDocument document, uint32 element)
	{
		mDocument = document;
		mElement = element;
		mGeneration = document.mGeneration;
	}

	ref XmlNodeRecord Element
	{
		get
		{
			mDocument.CheckView(mGeneration, mElement);
			return ref mDocument.mNodes[mElement];
		}
	}

	/// @brief The number of attributes.
	public int Count => Element.mAttributeCount;

	/// @brief The attribute at `index` (0 ..< Count).
	public XmlAttribute this[int index]
	{
		get
		{
			ref XmlNodeRecord element = ref Element;
			Runtime.Assert(index >= 0 && index < element.mAttributeCount, "XmlAttributeList: index out of range");
			return .(mDocument, element.mAttributeStart + index);
		}
	}

	public Enumerator GetEnumerator() => .(this);

	public struct Enumerator : IEnumerator<XmlAttribute>
	{
		XmlAttributeList mList;
		int mIndex;

		internal this(XmlAttributeList list)
		{
			mList = list;
			mIndex = 0;
		}

		public Result<XmlAttribute> GetNext() mut
		{
			if (mIndex >= mList.Count)
				return .Err;
			return mList[mIndex++];
		}
	}
}
