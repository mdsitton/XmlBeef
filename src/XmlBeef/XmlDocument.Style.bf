using System;
using System.Collections;
using internal XmlBeef;

namespace XmlBeef;

[AllowDuplicates]
internal enum XmlStyleFlags : uint16
{
	None = 0,
	/// The source pieces were recorded while reading (a node or attribute added in code has none).
	Captured = 1,
	/// Read from an entity's replacement text: its range is the outermost reference's.
	InEntity = 2,
	/// InEntity, and its parent is not: one of the nodes a reference in the document produced.
	EntityTop = 4,
	/// The range overlaps a sibling's (both came from one entity reference): written with them.
	Shared = 8,
	/// An element written as an empty-element tag in the source.
	EmptyInSource = 16,
	/// Moved: the text before it belonged to its old place.
	LeadingDirty = 32,
	/// Regenerate: the name (renamed), the value, the start tag's attributes.
	NameDirty = 64,
	ValueDirty = 128,
	TagDirty = 256,
	/// Something under the node, or the list of its children, changed.
	SubtreeDirty = 512,
	/// A sibling it shares source with was removed or moved, or a node was put between them.
	GroupDirty = 1024,
	Dirty = NameDirty | ValueDirty | TagDirty | SubtreeDirty | GroupDirty
}

/// PreserveStyle: where a node's text is in the source (offsets into XmlDocument.mSource).
internal struct XmlNodeStyle
{
	/// Where the text before the node starts (the end of the previous construct at its level):
	/// whitespace between the prolog's items, and nothing in content, where all text is a node.
	public int32 mLead;
	public int32 mStart;
	public int32 mEnd;
	/// Elements: the end of the name in the start tag, of the last attribute, and of the start tag;
	/// where the text after the last child starts, and where the end tag starts.
	public int32 mNameEnd;
	public int32 mAttributesEnd;
	public int32 mStartTagEnd;
	public int32 mInnerTail;
	public int32 mEndTagStart;
	public XmlStyleFlags mFlags;
}

/// PreserveStyle: where an attribute's text is in the source.
internal struct XmlAttributeStyle
{
	/// Before the name: the whitespace that separates it from the element's name or the previous
	/// attribute.
	public int32 mLead;
	public int32 mStart;
	/// The value as written, between the quotes.
	public int32 mValueStart;
	public int32 mValueEnd;
	/// Captured, ValueDirty.
	public XmlStyleFlags mFlags;
}

/// PreserveStyle: recording the source while reading, and writing it back (plan.md §4.9).
extension XmlDocument
{
	/// The node's style record, growing the list to reach it.
	internal ref XmlNodeStyle NodeStyle(uint32 id)
	{
		while (mNodeStyles.Count <= (int)id)
			mNodeStyles.Add(default);
		return ref mNodeStyles[id];
	}

	internal XmlStyleFlags StyleFlags(uint32 id)
	{
		return id < (uint32)mNodeStyles.Count ? mNodeStyles[id].mFlags : .None;
	}

	StringView Source(int start, int end)
	{
		return end > start ? mSource.Substring(start, end - start) : default;
	}

	// Capture (Build calls these for each event)

	/// At the first event: the source text, kept as the document's copy of the input when it is that, or
	/// copied (a transcoded document).
	void CaptureBegin(XmlReader reader)
	{
		if (mStyleBegun)
			return;
		mStyleBegun = true;
		KeepSource(reader);
		mContentStart = (int32)reader.ContentStart;
		mDeclarationStart = mContentStart;
		mDeclarationEnd = mContentStart;
		mLastEnd = mContentStart;
	}

	void CaptureDeclaration(XmlReader reader)
	{
		CaptureBegin(reader);
		mDeclarationStart = (int32)reader.Offset;
		mDeclarationEnd = (int32)reader.EndOffset;
		mLastEnd = mDeclarationEnd;
	}

	/// What every node records: its range, the text before it, where it came from, and whether it shares
	/// its source with the previous sibling.
	void CaptureNode(XmlReader reader, uint32 id)
	{
		CaptureBegin(reader);
		uint32 parent = mNodes[id].mParent;
		uint32 prev = mNodes[id].mPrevSibling;
		bool parentInEntity = StyleFlags(parent).HasFlag(.InEntity);
		ref XmlNodeStyle style = ref NodeStyle(id);
		style.mLead = mLastEnd;
		style.mStart = (int32)reader.Offset;
		style.mEnd = (int32)reader.EndOffset;
		style.mFlags = .Captured;
		if (reader.IsInEntity)
		{
			style.mFlags |= .InEntity;
			if (!parentInEntity)
				style.mFlags |= .EntityTop;
		}
		if (prev != 0 && style.mStart < mLastEnd)
		{
			style.mFlags |= .Shared;
			mNodeStyles[prev].mFlags |= .Shared;
		}
	}

	void CaptureLeaf(XmlReader reader, uint32 id)
	{
		CaptureNode(reader, id);
		mLastEnd = Math.Max(mLastEnd, mNodeStyles[id].mEnd);
	}

	void CaptureStartElement(XmlReader reader, uint32 id)
	{
		CaptureNode(reader, id);
		ref XmlNodeStyle style = ref mNodeStyles[id];
		style.mStartTagEnd = style.mEnd;
		style.mNameEnd = style.mStart + 1 + (int32)reader.Name.Length;
		if (reader.IsEmptyElement)
			style.mFlags |= .EmptyInSource;
		int32 end = style.mNameEnd;
		if (!style.mFlags.HasFlag(.InEntity))
		{
			ref XmlNodeRecord element = ref mNodes[id];
			for (int i < element.mAttributeCount)
			{
				reader.GetAttributeRange(i, let offset, let attributeEnd);
				if (attributeEnd <= 0)
					continue;
				int index = element.mAttributeStart + i;
				while (mAttributeStyles.Count <= index)
					mAttributeStyles.Add(default);
				ref XmlAttributeStyle attribute = ref mAttributeStyles[index];
				attribute.mLead = end;
				attribute.mStart = (int32)offset;
				// The first quote after the name is the opening one (only `=` and spaces are between)
				int quote = offset;
				while (quote < attributeEnd && mSource[quote] != '"' && mSource[quote] != '\'')
					quote++;
				attribute.mValueStart = (int32)quote + 1;
				attribute.mValueEnd = (int32)attributeEnd - 1;
				attribute.mFlags = .Captured;
				end = (int32)attributeEnd;
			}
		}
		style.mAttributesEnd = end;
		mStyleEnds.Add(mLastEnd);
		mLastEnd = style.mStartTagEnd;
	}

	void CaptureEndElement(XmlReader reader, uint32 id)
	{
		ref XmlNodeStyle style = ref mNodeStyles[id];
		if (style.mFlags.HasFlag(.EmptyInSource))
		{
			style.mInnerTail = style.mStartTagEnd;
			style.mEndTagStart = style.mStartTagEnd;
		}
		else
		{
			style.mInnerTail = mLastEnd;
			style.mEndTagStart = (int32)reader.Offset;
			style.mEnd = (int32)reader.EndOffset;
		}
		mLastEnd = Math.Max(mStyleEnds.PopBack(), style.mEnd);
	}

	// Marking changes (the mutation API calls these; nothing happens without PreserveStyle)

	/// Marks part of a node to be regenerated, and its ancestors as changed below.
	internal void MarkNode(uint32 id, XmlStyleFlags flags)
	{
		if (!mPreserve)
			return;
		NodeStyle(id).mFlags |= flags;
		MarkChanged(mNodes[id].mParent);
	}

	/// Marks a node and its ancestors as changed below (a child added, removed or changed).
	internal void MarkChanged(uint32 id)
	{
		if (!mPreserve)
			return;
		uint32 current = id;
		while (true)
		{
			ref XmlNodeStyle style = ref NodeStyle(current);
			// Its ancestors were marked with it
			if (style.mFlags.HasFlag(.SubtreeDirty))
				return;
			style.mFlags |= .SubtreeDirty;
			if (current == 0)
				return;
			current = mNodes[current].mParent;
		}
	}

	/// Before a node leaves its place or after it takes one: it and its neighbors stop sharing source.
	internal void MarkNeighbors(uint32 id)
	{
		if (!mPreserve)
			return;
		uint32[3] ids = .(id, mNodes[id].mPrevSibling, mNodes[id].mNextSibling);
		for (let n in ids)
		{
			if (n != 0 && StyleFlags(n).HasFlag(.Shared))
				mNodeStyles[n].mFlags |= .GroupDirty;
		}
	}

	internal void MarkAttribute(int index, XmlStyleFlags flags)
	{
		if (mPreserve && index < mAttributeStyles.Count)
			mAttributeStyles[index].mFlags |= flags;
	}

	// Writing back

	/// Can the node's text be taken from the source: it was read, and is not inside an element that
	/// came from the same entity reference.
	bool CanSource(uint32 id)
	{
		let flags = StyleFlags(id);
		return flags.HasFlag(.Captured) && (!flags.HasFlag(.InEntity) || flags.HasFlag(.EntityTop));
	}

	/// Whether an element's tags are in the source (it was read, and not from an entity).
	bool TagsFromSource(uint32 id)
	{
		let flags = StyleFlags(id);
		return flags.HasFlag(.Captured) && !flags.HasFlag(.InEntity);
	}

	/// Writes the document from its source text, regenerating what was added or changed.
	void WritePreserving(String output)
	{
		if (mHasBom)
			output.Append("\u{FEFF}");
		int writeStart = output.Length;
		if (mHasDeclaration)
			output.Append(Source(mDeclarationStart, mDeclarationEnd));
		uint32 parent = 0;
		uint32 id = mNodes[0].mFirstChild;
		while (true)
		{
			if (id == 0)
			{
				// The end of the parent's children
				if (parent == 0)
					break;
				WriteEndTagPreserving(parent, output);
				id = mNodes[parent].mNextSibling;
				parent = mNodes[parent].mParent;
				continue;
			}
			let flags = StyleFlags(id);
			if (flags.HasFlag(.Shared))
			{
				id = WriteGroup(id, writeStart, output);
				continue;
			}
			ref XmlNodeRecord node = ref mNodes[id];
			if (CanSource(id) && (flags & .Dirty) == 0)
			{
				// Unchanged: as read, with the text before it unless it moved
				let style = mNodeStyles[id];
				output.Append(Source(flags.HasFlag(.LeadingDirty) ? style.mStart : style.mLead, style.mEnd));
				id = node.mNextSibling;
				continue;
			}
			WriteLeading(id, writeStart, output);
			if (node.mKind == .Element)
			{
				WriteStartTagPreserving(id, output);
				if (node.mFirstChild != 0)
				{
					parent = id;
					id = node.mFirstChild;
					continue;
				}
				WriteEndTagPreserving(id, output);
			}
			else
				WriteGenerated(id, output);
			id = mNodes[id].mNextSibling;
		}
		if (mPreserve)
			output.Append(Source(mTailStart, mSource.Length));
	}

	/// The text before a node: from the source when it is still in its place, a line break before a
	/// new node outside the root, nothing otherwise.
	void WriteLeading(uint32 id, int writeStart, String output)
	{
		let flags = StyleFlags(id);
		if (CanSource(id) && !flags.HasFlag(.LeadingDirty))
		{
			let style = mNodeStyles[id];
			output.Append(Source(style.mLead, style.mStart));
		}
		else if (mNodes[id].mParent == 0 && output.Length > writeStart && !output.EndsWith('\n'))
			output.Append('\n');
	}

	/// A node and everything under it in canonical form.
	void WriteGenerated(uint32 id, String output)
	{
		ref XmlNodeRecord node = ref mNodes[id];
		switch (node.mKind)
		{
		case .Element:
			WriteElementTree(id, default, output);
		case .DocType:
			if (StyleFlags(id).HasFlag(.Captured))
				WriteDocTypePreserving(id, output);
			else
				WriteDocType(output);
		default:
			WriteLeaf(node, output);
		}
	}

	/// A DOCTYPE whose processing instructions changed: its text as read, with the internal subset
	/// rebuilt (AppendInternalSubset), or one added before the `>` when it had none.
	void WriteDocTypePreserving(uint32 id, String output)
	{
		let style = mNodeStyles[id];
		if (mHasInternalSubset)
		{
			int subsetEnd = mSubsetOffset + mInternalSubset.Length;
			output.Append(Source(style.mStart, mSubsetOffset));
			AppendInternalSubset(output, Source(mSubsetOffset, subsetEnd));
			output.Append(Source(subsetEnd, style.mEnd));
			return;
		}
		output.Append(Source(style.mStart, style.mEnd - 1));
		if (mNodes[id].mFirstChild != 0)
		{
			output.Append(" [");
			AppendInternalSubset(output, default);
			output.Append(']');
		}
		output.Append('>');
	}

	/// Siblings that came from one entity reference (with text around it): the reference as written
	/// when none of them changed, else each regenerated. @return The sibling after them.
	uint32 WriteGroup(uint32 head, int writeStart, String output)
	{
		let headStyle = mNodeStyles[head];
		int32 end = headStyle.mEnd;
		bool clean = CanSource(head) && (headStyle.mFlags & .Dirty) == 0;
		uint32 last = head;
		while (true)
		{
			uint32 next = mNodes[last].mNextSibling;
			let flags = StyleFlags(next);
			if (next == 0 || !flags.HasFlag(.Shared) || mNodeStyles[next].mStart >= end)
				break;
			if (!CanSource(next) || (flags & .Dirty) != 0 || flags.HasFlag(.LeadingDirty))
				clean = false;
			end = Math.Max(end, mNodeStyles[next].mEnd);
			last = next;
		}
		if (clean)
			output.Append(Source(headStyle.mFlags.HasFlag(.LeadingDirty) ? headStyle.mStart : headStyle.mLead, end));
		else
		{
			WriteLeading(head, writeStart, output);
			for (uint32 id = head; ; id = mNodes[id].mNextSibling)
			{
				WriteGenerated(id, output);
				if (id == last)
					break;
			}
		}
		return mNodes[last].mNextSibling;
	}

	/// A start tag: as written where it can be, with changed attributes regenerated in place, or
	/// generated (`/>` when the element has no children).
	void WriteStartTagPreserving(uint32 id, String output)
	{
		ref XmlNodeRecord node = ref mNodes[id];
		bool hasChildren = node.mFirstChild != 0;
		if (!TagsFromSource(id))
		{
			WriteStartTag(node, output);
			output.Append(hasChildren ? ">" : "/>");
			return;
		}
		let style = mNodeStyles[id];
		if (style.mFlags.HasFlag(.NameDirty))
		{
			output.Append('<');
			output.Append(mNames[node.mName]);
		}
		else
			output.Append(Source(style.mStart, style.mNameEnd));
		if (style.mFlags.HasFlag(.TagDirty))
			WriteAttributesPreserving(id, output);
		else
			output.Append(Source(style.mNameEnd, style.mAttributesEnd));
		StringView close = Source(style.mAttributesEnd, style.mStartTagEnd);
		if (style.mFlags.HasFlag(.EmptyInSource) && hasChildren)
		{
			// `<a/>` that has content now: `<a>`, keeping the space before the `/`
			output.Append(close.Substring(0, close.Length - 2));
			output.Append('>');
		}
		else
			output.Append(close);
	}

	/// The end tag that goes with WriteStartTagPreserving's start tag, if any.
	void WriteEndTagPreserving(uint32 id, String output)
	{
		ref XmlNodeRecord node = ref mNodes[id];
		bool hasChildren = node.mFirstChild != 0;
		let flags = StyleFlags(id);
		if (!TagsFromSource(id) || flags.HasFlag(.EmptyInSource))
		{
			if (hasChildren)
			{
				output.Append("</");
				output.Append(mNames[node.mName]);
				output.Append('>');
			}
			return;
		}
		let style = mNodeStyles[id];
		output.Append(Source(style.mInnerTail, style.mEndTagStart));
		if (flags.HasFlag(.NameDirty))
		{
			output.Append("</");
			output.Append(mNames[node.mName]);
			output.Append('>');
		}
		else
			output.Append(Source(style.mEndTagStart, style.mEnd));
	}

	/// The attributes of a start tag whose attributes changed: each one read keeps its text (its
	/// value regenerated in its quotes if it changed); a removed one takes the space before it along;
	/// a new one is laid out like the last one read (on its own line when they are).
	void WriteAttributesPreserving(uint32 id, String output)
	{
		ref XmlNodeRecord node = ref mNodes[id];
		int start = node.mAttributeStart;
		int end = start + node.mAttributeCount;
		StringView newLead = " ";
		for (int i = start; i < end; i++)
		{
			if (i < mAttributeStyles.Count && mAttributeStyles[i].mFlags.HasFlag(.Captured))
				newLead = Source(mAttributeStyles[i].mLead, mAttributeStyles[i].mStart);
		}
		for (int i = start; i < end; i++)
		{
			ref XmlAttributeRecord attribute = ref mAttributes[i];
			if (attribute.mFlags.HasFlag(.Defaulted))
				continue;
			XmlAttributeStyle style = i < mAttributeStyles.Count ? mAttributeStyles[i] : default;
			if (!style.mFlags.HasFlag(.Captured))
			{
				output.Append(newLead);
				output.Append(mNames[attribute.mName]);
				output.Append("=\"");
				int valueStart = output.Length;
				AppendAttributeEscaped(output, attribute.mValue);
				FixUnencodable(output, valueStart, .AttributeValue);
				output.Append('"');
				continue;
			}
			output.Append(Source(style.mLead, style.mStart));
			if (style.mFlags.HasFlag(.ValueDirty))
			{
				char8 quote = mSource[style.mValueStart - 1];
				output.Append(Source(style.mStart, style.mValueStart));
				int valueStart = output.Length;
				AppendAttributeEscaped(output, attribute.mValue, quote);
				FixUnencodable(output, valueStart, .AttributeValue);
				output.Append(quote);
			}
			else
				output.Append(Source(style.mStart, style.mValueEnd + 1));
		}
	}
}
