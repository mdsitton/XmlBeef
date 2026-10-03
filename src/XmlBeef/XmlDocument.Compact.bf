using System;
using System.Collections;
using FormatCore;
using internal FormatCore;
using internal XmlBeef;

namespace XmlBeef;

/// @brief What a document holds in memory (XmlDocument.MemoryUsage).
public struct XmlMemoryUsage
{
	/// @brief Node slots in the node table (the document node included), and the nodes in the document:
	/// the difference is removed nodes, whose slots stay until Clear or Compact.
	public int mNodeSlots;
	public int mNodes;
	/// @brief Attribute slots in the attribute table, and the attributes of the document's elements: the
	/// difference is removed attributes and the old places of moved ones.
	public int mAttributeSlots;
	public int mAttributes;
	/// @brief The bytes of the document's text arena (its copy of the input, decoded and set values), and
	/// how many of them are in use since the last read or Clear.
	public int mTextReserved;
	public int mTextFilled;
	/// @brief The bytes of text the document's content views: its values, the kept source (PreserveStyle
	/// and positions), the DOCTYPE's text and the errors' messages. Compact leaves about this much in the
	/// arena.
	public int mTextLive;
	/// @brief Everything the document holds, approximately: the arena, the tables' capacities, the name
	/// table and the side tables (positions, style).
	public int mTotalReserved;
}

/// Compaction and memory release (review P04): editing leaves replaced values in the text arena and
/// removed nodes and moved attribute spans in the tables until Clear; Compact rebuilds the document
/// from what is live.
extension XmlDocument
{
	/// @brief What the document holds in memory: slots and arena bytes, live and reserved.
	public XmlMemoryUsage MemoryUsage
	{
		get
		{
			XmlMemoryUsage usage = default;
			usage.mNodeSlots = mNodes.Count;
			usage.mAttributeSlots = mAttributes.Count;
			usage.mTextReserved = mStore.Text.ReservedBytes;
			usage.mTextFilled = mStore.Text.FilledBytes;
			let order = scope List<uint32>();
			LiveOrder(order);
			usage.mNodes = order.Count;
			int live = KeepsSource ? mSource.Length : 0;
			for (let id in order)
			{
				ref XmlNodeRecord node = ref mNodes[id];
				live += OwnedLength(node.mValue);
				usage.mAttributes += node.mAttributeCount;
				for (int i = node.mAttributeStart; i < node.mAttributeStart + node.mAttributeCount; i++)
					live += OwnedLength(mAttributes[i].mValue);
			}
			ForEachHeaderText(scope [&](text) => { live += OwnedLength(text); });
			usage.mTextLive = live;
			usage.mTotalReserved = usage.mTextReserved + mNodes.ReservedBytes + mAttributes.ReservedBytes + mNames.ReservedBytes +
				mNodeStyles.ReservedBytes + mAttributeStyles.ReservedBytes +
				mNodeRanges.ReservedBytes + mAttributeRanges.ReservedBytes + mLineStarts.ReservedBytes +
				mSubsetItems.Capacity * strideof(XmlSubsetItem) + mErrors.Capacity * strideof(XmlParseError) + mNotations.Capacity * strideof(XmlNotation) +
				mNodeStack.ReservedBytes + mPendingDocTypeNodes.Capacity * sizeof(uint32) + mStyleEnds.Capacity * sizeof(int32) + mSourceName.AllocSize;
			return usage;
		}
	}

	/// @brief Rebuild the document from what is in it: removed nodes, removed and moved attributes, and
	/// replaced text are dropped, and the tables and the text arena shrink to fit. Nodes are renumbered in
	/// document order, so every handle (`XmlNode`, `XmlAttribute`, saved lists and enumerators) becomes
	/// invalid, as after Clear, and every string the document returned before is freed. The document
	/// reads, edits and writes as before (PreserveStyle keeps its source and what changed). Names stay
	/// interned.
	/// @param newIds If given, filled with each old node ID's new one (indexed by the old ID's Value):
	/// 0 for a removed node (the document node keeps 0).
	public void Compact(List<XmlNodeId> newIds = null)
	{
		let order = scope List<uint32>();
		LiveOrder(order);
		uint32[] map = scope uint32[mNodes.Count];
		for (int i < order.Count)
			map[order[i]] = (uint32)i;

		// One chunk for all the live text: the kept source whole (values that view it are moved with it),
		// the rest value by value
		bool keepSource = KeepsSource;
		int total = keepSource ? mSource.Length : 0;
		int attributeCount = 0;
		for (let id in order)
		{
			ref XmlNodeRecord node = ref mNodes[id];
			total += OwnedLength(node.mValue);
			attributeCount += node.mAttributeCount;
			for (int i = node.mAttributeStart; i < node.mAttributeStart + node.mAttributeCount; i++)
				total += OwnedLength(mAttributes[i].mValue);
		}
		ForEachHeaderText(scope [&](text) => { total += OwnedLength(text); });
		let store = new XmlDocumentStore(total);
		StringView source = keepSource ? store.NewText(mSource) : default;

		let nodes = new XmlStack<XmlNodeRecord>(Math.Max(order.Count, 16));
		let attributes = new XmlStack<XmlAttributeRecord>(Math.Max(attributeCount, 16));
		let nodeStyles = new SideTable<XmlNodeStyle>();
		let nodeRanges = new SideTable<XmlRangeRecord>();
		let attributeStyles = new SideTable<XmlAttributeStyle>();
		let attributeRanges = new SideTable<XmlRangeRecord>();
		for (let id in order)
		{
			var node = mNodes[id];
			node.mParent = map[node.mParent];
			node.mFirstChild = map[node.mFirstChild];
			node.mLastChild = map[node.mLastChild];
			node.mNextSibling = map[node.mNextSibling];
			node.mPrevSibling = map[node.mPrevSibling];
			node.mValue = MoveText(node.mValue, store, source);
			int start = node.mAttributeStart;
			node.mAttributeStart = (int32)attributes.Count;
			for (int i = start; i < start + node.mAttributeCount; i++)
			{
				var attribute = mAttributes[i];
				attribute.mValue = MoveText(attribute.mValue, store, source);
				attributes.Add(attribute);
				if (!mAttributeStyles.IsEmpty)
					attributeStyles.Add(mAttributeStyles.Get(i));
				if (!mAttributeRanges.IsEmpty)
					attributeRanges.Add(mAttributeRanges.Get(i));
			}
			nodes.Add(node);
			if (!mNodeStyles.IsEmpty)
				nodeStyles.Add(mNodeStyles.Get(id));
			if (!mNodeRanges.IsEmpty)
				nodeRanges.Add(mNodeRanges.Get(id));
		}

		// The places of the DOCTYPE's processing instructions in the subset's text: a removed one's stays,
		// naming the document node (never in the subset), so the writers still leave its text out
		for (int i < mSubsetItems.Count)
			mSubsetItems[i].mId = map[mSubsetItems[i].mId];
		mRoot = map[mRoot];
		mDocType = map[mDocType];
		mVersion = MoveText(mVersion, store, source);
		mEncodingName = MoveText(mEncodingName, store, source);
		mPublicId = MoveText(mPublicId, store, source);
		mSystemId = MoveText(mSystemId, store, source);
		mInternalSubset = MoveText(mInternalSubset, store, source);
		for (int i < mNotations.Count)
		{
			ref XmlNotation notation = ref mNotations[i];
			notation.mName = MoveText(notation.mName, store, source);
			notation.mPublicId = MoveText(notation.mPublicId, store, source);
			notation.mSystemId = MoveText(notation.mSystemId, store, source);
		}
		for (int i < mErrors.Count)
			mErrors[i].mMessage = MoveText(mErrors[i].mMessage, store, source);
		mSource = source;
		// Nothing views the input copy any more (the source, when kept, is a copy of its own)
		mInput.Clear();

		if (newIds != null)
		{
			newIds.Clear();
			for (int i < map.Count)
				newIds.Add(.(map[i]));
		}
		delete mStore;
		mStore = store;
		delete mNodes;
		mNodes = nodes;
		delete mAttributes;
		mAttributes = attributes;
		delete mNodeStyles;
		mNodeStyles = nodeStyles;
		delete mNodeRanges;
		mNodeRanges = nodeRanges;
		delete mAttributeStyles;
		mAttributeStyles = attributeStyles;
		delete mAttributeRanges;
		mAttributeRanges = attributeRanges;
		mGeneration++;
	}

	/// @brief Remove everything, and with `releaseMemory` also free what the document keeps for the next
	/// read (its text arena's chunks, its tables' and name table's capacity, the reader's buffers): after
	/// an unusually large document, for instance. Clear() keeps it, so reading document after document
	/// allocates nothing once the document has grown to the largest.
	/// @param releaseMemory Whether to free the retained memory.
	public void Clear(bool releaseMemory)
	{
		Clear();
		if (!releaseMemory)
			return;
		mStore.Release();
		mNames.Release();
		mNodes.TrimExcess();
		mAttributes.TrimExcess();
		mNodeStyles.Release();
		mAttributeStyles.Release();
		mNodeRanges.Release();
		mAttributeRanges.Release();
		mLineStarts.Release();
		mNodeStack.TrimExcess();
		mPendingDocTypeNodes.Capacity = 0;
		mStyleEnds.Capacity = 0;
		mSubsetItems.Capacity = 0;
		mErrors.Capacity = 0;
		mNotations.Capacity = 0;
		mSourceName.Clear();
		DeleteAndNullify!(mReader);
	}

	/// Whether the document keeps its source text (PreserveStyle and positions read from memory): it is
	/// moved whole, with the values that view it.
	bool KeepsSource => mSourceKept && !mSource.IsEmpty;

	/// The live nodes in document order, the document node first.
	void LiveOrder(List<uint32> order)
	{
		order.Add(0);
		uint32 current = mNodes[0].mFirstChild;
		while (current != 0)
		{
			order.Add(current);
			if (mNodes[current].mFirstChild != 0)
			{
				current = mNodes[current].mFirstChild;
				continue;
			}
			while (current != 0 && mNodes[current].mNextSibling == 0)
				current = mNodes[current].mParent;
			if (current != 0)
				current = mNodes[current].mNextSibling;
		}
	}

	/// The text the document holds outside the node and attribute tables.
	void ForEachHeaderText(delegate void(StringView) action)
	{
		action(mVersion);
		action(mEncodingName);
		action(mPublicId);
		action(mSystemId);
		action(mInternalSubset);
		for (let notation in mNotations)
		{
			action(notation.mName);
			action(notation.mPublicId);
			action(notation.mSystemId);
		}
		for (let error in mErrors)
			action(error.mMessage);
	}

	/// The bytes `text` takes in a compacted arena: none when it views the kept source (moved with it).
	int OwnedLength(StringView text)
	{
		if (KeepsSource && text.Ptr >= mSource.Ptr && text.Ptr + text.Length <= mSource.Ptr + mSource.Length)
			return 0;
		return text.Length;
	}

	/// `text` in the new store: at the same place in the moved source when it views the old one, else a
	/// copy. An empty view stays empty (and null stays null).
	StringView MoveText(StringView text, XmlDocumentStore store, StringView source)
	{
		if (text.IsEmpty)
			return text.Ptr == null ? default : "";
		if (!source.IsEmpty && text.Ptr >= mSource.Ptr && text.Ptr + text.Length <= mSource.Ptr + mSource.Length)
			return .(source.Ptr + (text.Ptr - mSource.Ptr), text.Length);
		return store.NewText(text);
	}
}
