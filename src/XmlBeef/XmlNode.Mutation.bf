using System;
using internal XmlBeef;

namespace XmlBeef;

/// Changing a node: its place in the tree, its children, its name, value and attributes. Every method
/// needs a valid handle; strings passed in are copied. What would make the document impossible to
/// write as well-formed XML is a fatal error (an invalid name or character, `--` in a comment, a second
/// root element, text outside the root); XmlDocument.IsValidName and IsValidText check names and text
/// first. In a document read with PreserveStyle, the writer regenerates only what these change.
extension XmlNode
{
	// Adding children

	/// @brief Add an element at the end of this node's children: of an element, or of the document
	/// node when it has no root element yet (the new element is the root).
	/// @param name The qualified name; its prefix is resolved from the declarations in scope.
	/// @return The new element.
	public XmlNode AddElement(StringView name)
	{
		CheckContainer();
		mDocument.CheckName(name, "element");
		if (mId == 0 && mDocument.mRoot != 0)
			Runtime.FatalError("XmlBeef: the document has a root element already");
		uint32 id = NewElement(name);
		Link(id, mId, 0, true);
		if (mId == 0)
			mDocument.mRoot = id;
		mDocument.ResolveNamespaces(id);
		return .(mDocument, id);
	}

	/// @brief Add text at the end of this element's children.
	/// @param text The text (any characters XML allows; it is escaped when written).
	/// @return The new text node.
	public XmlNode AddText(StringView text)
	{
		return AddValue(.Text, default, text);
	}

	/// @brief Add a CDATA section at the end of this element's children.
	/// @param text The content (`]]>` is written as two sections).
	/// @return The new CDATA node.
	public XmlNode AddCData(StringView text)
	{
		return AddValue(.CData, default, text);
	}

	/// @brief Add a comment at the end of this node's children (an element's, or the document node's).
	/// @param text The comment, without `<!--` and `-->`: no `--`, and not ending with `-`.
	/// @return The new comment.
	public XmlNode AddComment(StringView text)
	{
		return AddValue(.Comment, default, text);
	}

	/// @brief Add a processing instruction at the end of this node's children (an element's, or the
	/// document node's).
	/// @param target The target: a name other than `xml` in any case.
	/// @param data The data: no `?>`.
	/// @return The new processing instruction.
	public XmlNode AddProcessingInstruction(StringView target, StringView data)
	{
		return AddValue(.ProcessingInstruction, target, data);
	}

	/// @brief Add an element just before this node, under the same parent.
	/// @param name The qualified name.
	/// @return The new element.
	public XmlNode InsertElementBefore(StringView name)
	{
		return InsertElement(name, true);
	}

	/// @brief Add an element just after this node, under the same parent.
	/// @param name The qualified name.
	/// @return The new element.
	public XmlNode InsertElementAfter(StringView name)
	{
		return InsertElement(name, false);
	}

	/// @brief Remove this node and everything under it. Handles to any of them become invalid.
	public void Remove()
	{
		CheckChild();
		mDocument.RemoveNode(mId);
	}

	// Moving

	/// @brief Move this node (with its subtree) to the end of `parent`'s children.
	/// @param parent An element, or the document node, of the same document.
	/// @return False, changing nothing, if the move is not possible: `parent` is invalid, in another
	/// document, this node or under it, or cannot hold this node (text in the document node, a second
	/// root element).
	public bool MoveInto(XmlNode parent)
	{
		CheckChild();
		if (!CanMoveUnder(parent))
			return false;
		uint32 id = mId;
		mDocument.MarkLeaving(id);
		mDocument.Unlink(id);
		Moved(id, parent.mId, 0, true);
		return true;
	}

	/// @brief Move this node (with its subtree) just before `sibling`, under the sibling's parent.
	/// @param sibling A node of the same document, not the document node.
	/// @return False, changing nothing, if the move is not possible (see MoveInto).
	public bool MoveBefore(XmlNode sibling)
	{
		return MoveNextTo(sibling, true);
	}

	/// @brief Move this node (with its subtree) just after `sibling`, under the sibling's parent.
	/// @param sibling A node of the same document, not the document node.
	/// @return False, changing nothing, if the move is not possible (see MoveInto).
	public bool MoveAfter(XmlNode sibling)
	{
		return MoveNextTo(sibling, false);
	}

	// Names and values

	/// @brief Rename an element or a processing instruction's target. An element's prefix is resolved
	/// again; its attributes keep their names.
	/// @param name The new qualified name (a target: a name other than `xml`).
	public void Rename(StringView name)
	{
		CheckChild();
		ref XmlNodeRecord node = ref Record;
		if (node.mKind == .Element)
			mDocument.CheckName(name, "element");
		else if (node.mKind == .ProcessingInstruction)
			CheckTarget(name);
		else
			Runtime.FatalError("XmlNode.Rename: only an element or a processing instruction can be renamed");
		node.mName = mDocument.mNames.Intern(name);
		if (node.mKind == .Element && mDocument.mNamespaces)
			node.mNamespace = mDocument.LookupNamespace(mId, mDocument.mNames.PrefixOf(node.mName));
		mDocument.MarkNode(mId, .NameDirty);
	}

	/// @brief Set the content of text, a CDATA section, a comment, or a processing instruction's data.
	/// @param value The new content (with the rules of AddText, AddCData, AddComment,
	/// AddProcessingInstruction).
	public void SetValue(StringView value)
	{
		CheckChild();
		ref XmlNodeRecord node = ref Record;
		if (node.mKind != .Text && node.mKind != .CData && node.mKind != .Comment && node.mKind != .ProcessingInstruction)
			Runtime.FatalError("XmlNode.SetValue: only text, CDATA, comments and processing instructions have a value to set");
		CheckValue(node.mKind, value);
		node.mValue = mDocument.mStore.NewText(value);
		mDocument.MarkNode(mId, .ValueDirty);
	}

	/// @brief Replace this element's children by one text node (none for empty text).
	/// @param text The text.
	public void SetText(StringView text)
	{
		CheckChild();
		if (Record.mKind != .Element)
			Runtime.FatalError("XmlNode.SetText: only an element has text content to set");
		XmlDocument.CheckText(text, "text");
		while (mDocument.mNodes[mId].mFirstChild != 0)
			mDocument.RemoveNode(mDocument.mNodes[mId].mFirstChild);
		if (!text.IsEmpty)
			AddText(text);
	}

	// Attributes

	/// @brief Set an attribute of this element: the value of the one with this name (a default from the
	/// DTD becomes specified), or a new attribute after the others. Setting or changing an `xmlns`
	/// declaration resolves the names under the element again.
	/// @param name The qualified name.
	/// @param value The value (escaped when written).
	public void SetAttribute(StringView name, StringView value)
	{
		CheckElement();
		mDocument.CheckName(name, "attribute");
		XmlDocument.CheckText(value, "attribute value");
		int index = FindAttribute(name);
		StringView owned = mDocument.mStore.NewText(value);
		XmlNameId nameId;
		if (index >= 0)
		{
			ref XmlAttributeRecord attribute = ref mDocument.mAttributes[index];
			attribute.mValue = owned;
			attribute.mFlags &= ~.Defaulted;
			nameId = attribute.mName;
			mDocument.MarkAttribute(index, .ValueDirty);
		}
		else
		{
			XmlAttributeRecord attribute = default;
			attribute.mName = mDocument.mNames.Intern(name);
			attribute.mLocal = mDocument.mNamespaces ? mDocument.mNames.LocalOf(attribute.mName) : attribute.mName;
			attribute.mNamespace = mDocument.mNamespaces ? mDocument.AttributeNamespace(mId, attribute.mName) : .None;
			attribute.mValue = owned;
			mDocument.AppendAttribute(mId, attribute);
			nameId = attribute.mName;
		}
		mDocument.MarkNode(mId, .TagDirty);
		if (IsNamespaceDeclaration(nameId))
			mDocument.ResolveNamespaces(mId);
	}

	/// @brief Remove this element's attribute with this name. A default from the DTD is removed too
	/// (reading the written document supplies it again).
	/// @param name The qualified name.
	/// @return Whether there was one.
	public bool RemoveAttribute(StringView name)
	{
		CheckElement();
		int index = FindAttribute(name);
		if (index < 0)
			return false;
		XmlNameId nameId = mDocument.mAttributes[index].mName;
		mDocument.RemoveAttributeAt(mId, index);
		mDocument.MarkNode(mId, .TagDirty);
		if (IsNamespaceDeclaration(nameId))
			mDocument.ResolveNamespaces(mId);
		return true;
	}

	// Helpers

	bool IsNamespaceDeclaration(XmlNameId name)
	{
		return mDocument.mNamespaces && (name == XmlNameTable.cXmlns || mDocument.mNames.PrefixOf(name) == XmlNameTable.cXmlns);
	}

	uint32 NewElement(StringView name)
	{
		uint32 id = mDocument.NewNode(.Element);
		ref XmlNodeRecord node = ref mDocument.mNodes[id];
		node.mName = mDocument.mNames.Intern(name);
		node.mFlags = .EmptyTag;
		return id;
	}

	XmlNode AddValue(XmlNodeKind kind, StringView target, StringView value)
	{
		CheckContainer();
		if (mId == 0 && (kind == .Text || kind == .CData))
			Runtime.FatalError("XmlBeef: text and CDATA sections cannot be outside the root element");
		if (kind == .ProcessingInstruction)
			CheckTarget(target);
		CheckValue(kind, value);
		uint32 id = mDocument.NewNode(kind);
		ref XmlNodeRecord node = ref mDocument.mNodes[id];
		node.mValue = mDocument.mStore.NewText(value);
		if (kind == .ProcessingInstruction)
			node.mName = mDocument.mNames.Intern(target);
		Link(id, mId, 0, true);
		return .(mDocument, id);
	}

	XmlNode InsertElement(StringView name, bool before)
	{
		CheckChild();
		mDocument.CheckName(name, "element");
		uint32 parent = Record.mParent;
		if (parent == 0)
			Runtime.FatalError("XmlBeef: the document has a root element already");
		uint32 id = NewElement(name);
		Link(id, parent, mId, before);
		mDocument.ResolveNamespaces(id);
		return .(mDocument, id);
	}

	/// Links an unlinked node: before or after `sibling`, or with no sibling at the end of `parent`.
	void Link(uint32 id, uint32 parent, uint32 sibling, bool before)
	{
		if (sibling == 0)
			mDocument.LinkLastChild(parent, id);
		else if (before)
			mDocument.LinkBefore(sibling, id);
		else
			mDocument.LinkAfter(sibling, id);
		mDocument.MarkArrived(id);
	}

	/// After an unlink: links the node in its new place, marks it moved, resolves its names there.
	void Moved(uint32 id, uint32 parent, uint32 sibling, bool before)
	{
		Link(id, parent, sibling, before);
		// The text before it belonged to its old place
		if (mDocument.mPreserve)
			mDocument.NodeStyle(id).mFlags |= .LeadingDirty;
		if (parent == 0 && mDocument.mNodes[id].mKind == .Element)
			mDocument.mRoot = id;
		mDocument.ResolveNamespaces(id);
	}

	bool MoveNextTo(XmlNode sibling, bool before)
	{
		CheckChild();
		if (!sibling.IsValid || sibling.mDocument != mDocument || sibling.mId == 0 || sibling.mId == mId)
			return false;
		uint32 parent = mDocument.mNodes[sibling.mId].mParent;
		if (!CanMoveUnder(XmlNode(mDocument, parent)))
			return false;
		uint32 id = mId;
		mDocument.MarkLeaving(id);
		mDocument.Unlink(id);
		Moved(id, parent, sibling.mId, before);
		return true;
	}

	/// Whether this node can be moved under `parent`: an element or the document node of this document,
	/// not this node or under it, and able to hold it.
	bool CanMoveUnder(XmlNode parent)
	{
		if (!parent.IsValid || parent.mDocument != mDocument || mDocument.IsSelfOrAncestor(mId, parent.mId))
			return false;
		XmlNodeKind parentKind = mDocument.mNodes[parent.mId].mKind;
		XmlNodeKind kind = Record.mKind;
		if (kind == .DocType)
			return false;
		if (parentKind == .Element)
			return true;
		if (parentKind != .Document)
			return false;
		if (kind == .Text || kind == .CData || kind == .EntityReference)
			return false;
		// A second root element
		return kind != .Element || mDocument.mRoot == 0 || mDocument.mRoot == mId;
	}

	void CheckTarget(StringView target)
	{
		mDocument.CheckName(target, "processing instruction target");
		if (target.Equals("xml", true))
			Runtime.FatalError("XmlBeef: a processing instruction target cannot be `xml`");
		if (mDocument.mNamespaces && target.Contains(':'))
			Runtime.FatalError("XmlBeef: a processing instruction target cannot have a colon with namespaces on");
	}

	static void CheckValue(XmlNodeKind kind, StringView value)
	{
		XmlDocument.CheckText(value, "value");
		if (kind == .Comment && (value.Contains("--") || value.EndsWith('-')))
			Runtime.FatalError("XmlBeef: a comment cannot contain `--` or end with `-`");
		if (kind == .ProcessingInstruction && value.Contains("?>"))
			Runtime.FatalError("XmlBeef: a processing instruction's data cannot contain `?>`");
	}

	/// A node that can have children added: an element or the document node.
	void CheckContainer()
	{
		if (!IsValid && !(mDocument != null && mId == 0))
			Runtime.FatalError("XmlNode: the handle is invalid (no node, a removed node, or a cleared document)");
		let kind = mDocument.mNodes[mId].mKind;
		if (kind != .Element && kind != .Document)
			Runtime.FatalError("XmlNode: only an element or the document node can have children added");
	}

	/// A node in the tree: valid, and not the document node.
	void CheckChild()
	{
		if (!IsValid)
			Runtime.FatalError("XmlNode: the handle is invalid (no node, a removed node, or a cleared document)");
		if (mId == 0)
			Runtime.FatalError("XmlNode: the document node has no place, name or value to change");
	}

	void CheckElement()
	{
		CheckChild();
		if (Record.mKind != .Element)
			Runtime.FatalError("XmlNode: only an element has attributes");
	}
}
