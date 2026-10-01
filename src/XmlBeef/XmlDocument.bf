using System;
using System.Collections;
using System.IO;
using internal XmlBeef;

namespace XmlBeef;

/// @brief What a node is.
public enum XmlNodeKind : uint8
{
	/// @brief The document itself (XmlDocument.DocumentNode): its children are the prolog's comments,
	/// processing instructions and DOCTYPE, the root element, and what follows it.
	Document,
	/// @brief An element: a name, attributes and children.
	Element,
	/// @brief Character data (references expanded, line ends normalized).
	Text,
	/// @brief A CDATA section's content.
	CData,
	/// @brief A comment.
	Comment,
	/// @brief A processing instruction: its target is the name, its data the value.
	ProcessingInstruction,
	/// @brief A reference to an entity that was not read (a skipped entity): its name.
	EntityReference,
	/// @brief The DOCTYPE: the root element's name; its children are the processing instructions of
	/// the internal subset.
	DocType
}

[AllowDuplicates]
internal enum XmlNodeFlags : uint8
{
	None = 0,
	/// Removed from the document; its slot is not reused until the document is cleared.
	Removed = 1,
	/// An element written as an empty-element tag (`<a/>`).
	EmptyTag = 2
}

/// A node's slot in the document's node table. Links are node IDs; 0 means none; record 0 is the
/// document node.
internal struct XmlNodeRecord
{
	public XmlNodeKind mKind;
	public XmlNodeFlags mFlags;
	/// Element: the qualified name. ProcessingInstruction: the target. EntityReference: the entity.
	/// DocType: the root element's name.
	public XmlNameId mName;
	/// Element: the namespace (None for none or without namespaces).
	public XmlNameId mNamespace;
	/// Text, CData, Comment, ProcessingInstruction: the content.
	public StringView mValue;
	/// Element: its attributes are mAttributes[mAttributeStart ..< mAttributeStart + mAttributeCount].
	public int32 mAttributeStart;
	public int32 mAttributeCount;
	public int32 mChildCount;
	public uint32 mParent;
	public uint32 mFirstChild;
	public uint32 mLastChild;
	public uint32 mNextSibling;
	public uint32 mPrevSibling;
}

[AllowDuplicates]
internal enum XmlAttributeFlags : uint8
{
	None = 0,
	/// Supplied by an ATTLIST default, not written in the tag.
	Defaulted = 1
}

/// A source range without the source name (the document holds it). Line 0: no position.
internal struct XmlRangeRecord
{
	public int32 mLine;
	public int32 mColumn;
	public int32 mOffset;
	public int32 mLength;
}

/// An attribute in the document's attribute table.
internal struct XmlAttributeRecord
{
	public XmlNameId mName;
	public XmlNameId mLocal;
	public XmlNameId mNamespace;
	public StringView mValue;
	public XmlAttributeFlags mFlags;
}

/// An XML document: the root element and everything around and under it.
///
/// The document owns all of its text, names and nodes. Nodes are handed out as `XmlNode` handles (the
/// document plus a node ID), which read the document directly; a handle stays valid until the document
/// is cleared or read again, and `IsValid` tells. Strings returned by the document view its storage and
/// share that lifetime.
///
/// ```
/// let doc = scope XmlDocument();
/// Try!(doc.ReadFile("icon.svg"));
/// for (let path in doc.Root.Descendants.Named("path"))
///     Console.WriteLine(path.GetAttribute("d"));
/// ```
public class XmlDocument
{
	/// @brief This document's read configuration, used by the Read/ReadBytes/ReadFile overloads that
	/// take no config: `doc.ReadConfig.Namespaces = false;`.
	public XmlReadConfig ReadConfig = .();

	internal XmlDocumentStore mStore ~ delete _;
	internal XmlNameTable mNames ~ delete _;
	internal XmlStack<XmlNodeRecord> mNodes ~ delete _;
	internal XmlStack<XmlAttributeRecord> mAttributes ~ delete _;
	/// The root element's ID (0 when empty) and the DOCTYPE's (0 when none).
	internal uint32 mRoot;
	internal uint32 mDocType;
	/// The XML declaration as read.
	internal bool mHasDeclaration;
	internal StringView mVersion;
	internal StringView mEncodingName;
	internal XmlStandalone mStandalone;
	internal XmlEncoding mEncoding;
	/// XmlReader.EncodingWarning (a literal, or empty).
	internal StringView mEncodingWarning;
	/// The DOCTYPE's identifiers and internal subset (as written), and its notations.
	internal StringView mPublicId;
	internal StringView mSystemId;
	internal bool mHasPublicId;
	internal bool mHasSystemId;
	internal StringView mInternalSubset;
	internal bool mHasInternalSubset;
	internal List<XmlNotation> mNotations ~ delete _;
	/// Read with namespace processing.
	internal bool mNamespaces;
	/// Positions mode: the source range of each node (by ID) and attribute (by index); empty otherwise.
	internal List<XmlRangeRecord> mNodeRanges ~ delete _;
	internal List<XmlRangeRecord> mAttributeRanges ~ delete _;
	/// The document's copy of the input it was read from: values that are views of it are kept as they
	/// are, and only decoded text (references, line ends) is copied into the store.
	char8* mInputStart;
	char8* mInputEnd;
	/// The source name of the last read (for errors).
	internal String mSourceName ~ delete _;
	/// Changes on every Clear and Read, so handles from before can tell they are stale.
	internal uint32 mGeneration;
	/// The reader behind Read, kept for its buffers.
	XmlReader mReader ~ delete _;
	/// Scratch for Read (open elements, the DOCTYPE's processing instructions) and Write.
	List<uint32> mNodeStack ~ delete _;
	List<uint32> mPendingDocTypeNodes ~ delete _;
	internal List<int32> mOrder ~ delete _;

	/// @brief Create an empty document.
	public this()
	{
		mStore = new .();
		mNames = new .();
		mNodes = new .();
		mAttributes = new .();
		mNotations = new .();
		mSourceName = new .();
		mNodeStack = new .();
		mPendingDocTypeNodes = new .();
		mOrder = new .();
		mNodeRanges = new .();
		mAttributeRanges = new .();
		mGeneration = 1;
		mNamespaces = true;
		XmlNodeRecord document = default;
		document.mKind = .Document;
		mNodes.Add(document);
	}

	/// @brief The root element; an invalid handle when the document is empty.
	public XmlNode Root => XmlNode.Of(this, mRoot);

	/// @brief The document itself as a node: its children are the prolog's comments, processing
	/// instructions and DOCTYPE, the root element, and the comments and processing instructions after
	/// it.
	public XmlNode DocumentNode => XmlNode(this, 0);

	/// @brief The DOCTYPE node; an invalid handle when the document has none.
	public XmlNode DocType => XmlNode.Of(this, mDocType);

	/// @brief Whether the document has an XML declaration (`<?xml …?>`).
	public bool HasXmlDeclaration => mHasDeclaration;
	/// @brief The declared version (`1.0`), empty without a declaration.
	public StringView Version => mVersion;
	/// @brief The declared encoding name as written, empty if none.
	public StringView EncodingName => mEncodingName;
	/// @brief The declared `standalone`.
	public XmlStandalone Standalone => mStandalone;
	/// @brief The encoding the document was read in.
	public XmlEncoding Encoding => mEncoding;
	/// @brief A warning about the document's encoding, empty if none (see XmlReader.EncodingWarning).
	public StringView EncodingWarning => mEncodingWarning;
	/// @brief The DOCTYPE's public identifier (see HasPublicId).
	public StringView PublicId => mPublicId;
	/// @brief The DOCTYPE's system identifier (see HasSystemId).
	public StringView SystemId => mSystemId;
	/// @brief Whether the DOCTYPE has a public identifier.
	public bool HasPublicId => mHasPublicId;
	/// @brief Whether the DOCTYPE has a system identifier.
	public bool HasSystemId => mHasSystemId;
	/// @brief The DOCTYPE's internal subset as written (between `[` and `]`), empty if none.
	public StringView InternalSubset => mInternalSubset;
	/// @brief Whether the DOCTYPE has an internal subset (`[…]`, possibly empty).
	public bool HasInternalSubset => mHasInternalSubset;
	/// @brief The notations declared in the internal subset, in declaration order.
	public Span<XmlNotation> Notations => mNotations;
	/// @brief The name of the source last read (XmlReadConfig.SourceName, or ReadFile's path); empty if
	/// unnamed.
	public StringView SourceName => mSourceName;

	/// @brief Remove everything.
	public void Clear()
	{
		mStore.Reset();
		mNames.Clear();
		mNodes.Clear();
		mAttributes.Clear();
		mNotations.Clear();
		mNodeRanges.Clear();
		mAttributeRanges.Clear();
		mSourceName.Clear();
		mRoot = 0;
		mDocType = 0;
		mHasDeclaration = false;
		mVersion = default;
		mEncodingName = default;
		mStandalone = .Unspecified;
		mEncoding = .Utf8;
		mEncodingWarning = default;
		mPublicId = default;
		mSystemId = default;
		mHasPublicId = false;
		mHasSystemId = false;
		mInternalSubset = default;
		mHasInternalSubset = false;
		mNamespaces = true;
		mInputStart = null;
		mInputEnd = null;
		XmlNodeRecord document = default;
		document.mKind = .Document;
		mNodes.Add(document);
		mGeneration++;
	}

	/// @brief The node with the given ID, if it is in this document.
	/// @param id A node ID, from `XmlNode.Id`.
	/// @return The node, or an invalid handle if the ID is unknown or its node was removed.
	public XmlNode GetNode(XmlNodeId id)
	{
		return IsLive(id.mValue) ? XmlNode(this, id.mValue) : default;
	}

	// Reading

	/// @brief Replace the document's content with the XML document in `input`, using ReadConfig.
	/// @param input The document's bytes (any supported encoding; see XmlReader).
	/// @return .Ok, or the first error; the document is then empty.
	public Result<void, XmlParseError> Read(StringView input)
	{
		return Read(input, ReadConfig);
	}

	/// @brief Replace the document's content with the XML document in `input`.
	/// @param input The document's bytes (any supported encoding; see XmlReader).
	/// @param config Namespaces, DTD handling, limits and the source name.
	/// @return .Ok, or the first error; the document is then empty.
	public Result<void, XmlParseError> Read(StringView input, XmlReadConfig config)
	{
		let readerConfig = BeginRead(config);
		// One copy of the input; the reader's views into it last as long as the document
		StringView owned = input;
		if (config.MaxInputBytes <= 0 || input.Length <= config.MaxInputBytes)
		{
			owned = mStore.NewText(input);
			mInputStart = owned.Ptr;
			mInputEnd = owned.Ptr + owned.Length;
		}
		mReader.Reset(owned, readerConfig, mNames);
		return EndRead(Build(mReader, config));
	}

	/// @brief Replace the document's content with the XML document read from a stream, using ReadConfig.
	/// @param stream The document, read from its current position.
	/// @return .Ok, or the first error; the document is then empty.
	public Result<void, XmlParseError> Read(Stream stream)
	{
		return Read(stream, ReadConfig);
	}

	/// @brief Replace the document's content with the XML document read from a stream, through a buffer
	/// of `config.StreamBufferBytes`: memory for the input stays bounded by the buffer and the longest
	/// construct (see `config.MaxTokenBytes`); the document itself grows with the content.
	/// @param stream The document, read from its current position.
	/// @param config Namespaces, DTD handling, limits, buffer size and the source name.
	/// @return .Ok, or the first error (IoError if reading fails); the document is then empty.
	public Result<void, XmlParseError> Read(Stream stream, XmlReadConfig config)
	{
		let readerConfig = BeginRead(config);
		mReader.Reset(stream, readerConfig, mNames);
		return EndRead(Build(mReader, config));
	}

	/// Clears the document for a read and returns the reader's config, naming the document's copy of the
	/// source name.
	XmlReadConfig BeginRead(XmlReadConfig config)
	{
		Clear();
		mSourceName.Set(config.SourceName);
		var readerConfig = config;
		readerConfig.SourceName = mSourceName;
		if (mReader == null)
			mReader = new XmlReader();
		return readerConfig;
	}

	Result<void, XmlParseError> EndRead(Result<void, XmlParseError> result)
	{
		// Nothing may keep viewing the caller's input or stream
		mReader.Reset(StringView());
		if (result case .Err)
		{
			let sourceName = scope String(mSourceName);
			Clear();
			mSourceName.Set(sourceName);
		}
		return result;
	}

	/// @brief Replace the document's content with the XML document in `bytes`, using ReadConfig.
	/// @param bytes The document.
	/// @return .Ok, or the first error; the document is then empty.
	public Result<void, XmlParseError> ReadBytes(Span<uint8> bytes)
	{
		return Read(StringView((char8*)bytes.Ptr, bytes.Length), ReadConfig);
	}

	/// @brief Replace the document's content with the XML document in `bytes`.
	/// @param bytes The document.
	/// @param config Namespaces, DTD handling, limits and the source name.
	/// @return .Ok, or the first error; the document is then empty.
	public Result<void, XmlParseError> ReadBytes(Span<uint8> bytes, XmlReadConfig config)
	{
		return Read(StringView((char8*)bytes.Ptr, bytes.Length), config);
	}

	/// @brief Replace the document's content with the XML document in a file, using ReadConfig.
	/// @param path The file's path; errors name it unless ReadConfig.SourceName is set.
	/// @return .Ok, or the first error (IoError if the file cannot be read); the document is then empty.
	public Result<void, XmlParseError> ReadFile(StringView path)
	{
		return ReadFile(path, ReadConfig);
	}

	/// @brief Replace the document's content with the XML document in a file: loaded whole, or with
	/// `config.StreamBufferBytes` set, streamed through a buffer of that size.
	/// @param path The file's path; errors name it unless config.SourceName is set.
	/// @param config Namespaces, DTD handling, limits, buffer size and the source name.
	/// @return .Ok, or the first error (IoError if the file cannot be read); the document is then empty.
	public Result<void, XmlParseError> ReadFile(StringView path, XmlReadConfig config)
	{
		var config;
		if (config.SourceName.IsEmpty)
			config.SourceName = path;
		if (config.StreamBufferBytes > 0)
		{
			let file = scope FileStream();
			if (file.Open(path, .Read, .Read) case .Err)
			{
				Clear();
				var error = XmlParseError(.IoError, "Cannot open the file", 0, 0, 0, 0);
				error.SetSource(config.SourceName);
				return .Err(error);
			}
			return Read(file, config);
		}
		let bytes = scope List<uint8>();
		if (ReadFileBytes(path, config.MaxInputBytes, bytes) case .Err(var error))
		{
			Clear();
			error.SetSource(config.SourceName);
			return .Err(error);
		}
		return ReadBytes(bytes, config);
	}

	/// Reads a whole file into `bytes`, but with a `maxInputBytes` budget never more than that: a larger
	/// file fails from its size before anything is read, and one that grows while read stops at the
	/// limit.
	static Result<void, XmlParseError> ReadFileBytes(StringView path, int maxInputBytes, List<uint8> bytes)
	{
		let file = scope FileStream();
		if (file.Open(path, .Read, .Read) case .Err)
			return .Err(XmlParseError(.IoError, "Cannot read the file", 0, 0, 0, 0));
		int64 size = file.Length;
		if (maxInputBytes > 0 && size > maxInputBytes)
			return .Err(XmlParseError(.ResourceLimitExceeded, scope $"The input ({size} bytes) exceeds MaxInputBytes ({maxInputBytes})", 1, 1, 0, 0));
		// The expected size in one read (plus a byte to see the end), then more if the file grew
		int chunk = (int)size + 1;
		while (true)
		{
			int filled = bytes.Count;
			bytes.Count = filled + chunk;
			switch (file.TryRead(.(bytes.Ptr + filled, chunk)))
			{
			case .Ok(let read):
				bytes.Count = filled + Math.Max(read, 0);
				if (read <= 0)
					return .Ok;
				if (maxInputBytes > 0 && bytes.Count > maxInputBytes)
					return .Err(XmlParseError(.ResourceLimitExceeded, scope $"The input exceeds MaxInputBytes ({maxInputBytes})", 1, 1, 0, 0));
				chunk = Math.Max(chunk - read, 4096);
			case .Err:
				bytes.Count = filled;
				return .Err(XmlParseError(.IoError, "Cannot read the file", 0, 0, 0, 0));
			}
		}
	}

	/// Turns the reader's events into records.
	Result<void, XmlParseError> Build(XmlReader reader, XmlReadConfig config)
	{
		mNamespaces = config.Namespaces;
		mNodeStack.Clear();
		mPendingDocTypeNodes.Clear();
		bool positions = config.MetadataMode != .None;
		uint32 current = 0;
		while (true)
		{
			let event = Try!(reader.Next());
			int nodesBefore = mNodes.Count;
			switch (event)
			{
			case .StartElement:
				uint32 id = NewNode(.Element);
				ref XmlNodeRecord element = ref mNodes[id];
				element.mName = reader.NameId;
				element.mNamespace = reader.NamespaceId;
				if (reader.IsEmptyElement)
					element.mFlags = .EmptyTag;
				int count = reader.AttributeCount;
				element.mAttributeStart = (int32)mAttributes.Count;
				element.mAttributeCount = (int32)count;
				XmlAttributeRecord* attributes = mAttributes.GrowUninitialized(count);
				for (int i < count)
				{
					XmlAttributeRecord* attribute = &attributes[i];
					attribute.mName = reader.AttributeNameId(i);
					attribute.mLocal = reader.AttributeLocalId(i);
					attribute.mNamespace = reader.AttributeNamespaceId(i);
					attribute.mValue = Own(reader.AttributeValue(i));
					attribute.mFlags = reader.IsAttributeSpecified(i) ? .None : .Defaulted;
				}
				if (positions)
				{
					// Attribute ranges by index, after the element's own (events come in source order)
					RecordRange(mNodeRanges, id, reader, reader.Offset, reader.EndOffset - reader.Offset);
					for (int i < count)
					{
						reader.GetAttributeRange(i, let offset, let end);
						if (end > 0)
							RecordRange(mAttributeRanges, (int)element.mAttributeStart + i, reader, offset, end - offset);
					}
				}
				LinkLastChild(current, id);
				if (current == 0)
					mRoot = id;
				mNodeStack.Add(current);
				current = id;
			case .EndElement:
				// The element's range runs through its end tag
				if (positions)
					mNodeRanges[current].mLength = (int32)(reader.EndOffset - mNodeRanges[current].mOffset);
				current = mNodeStack.PopBack();
			case .Text:
				AddValueNode(.Text, reader.Value, current);
			case .CData:
				AddValueNode(.CData, reader.Value, current);
			case .Comment:
				AddValueNode(.Comment, reader.Value, current);
			case .ProcessingInstruction:
				uint32 id = NewNode(.ProcessingInstruction);
				mNodes[id].mName = mNames.Intern(reader.Name);
				mNodes[id].mValue = Own(reader.Value);
				// The internal subset's are the DOCTYPE's children, linked when it is reported
				if (reader.IsInDocType)
					mPendingDocTypeNodes.Add(id);
				else
					LinkLastChild(current, id);
			case .EntityReference:
				uint32 id = NewNode(.EntityReference);
				mNodes[id].mName = mNames.Intern(reader.Name);
				LinkLastChild(current, id);
			case .XmlDeclaration:
				mHasDeclaration = true;
				mVersion = mStore.NewText(reader.Version);
				mEncodingName = mStore.NewText(reader.Encoding);
				mStandalone = reader.Standalone;
			case .DocType:
				uint32 id = NewNode(.DocType);
				mNodes[id].mName = mNames.Intern(reader.Name);
				LinkLastChild(0, id);
				mDocType = id;
				for (let pi in mPendingDocTypeNodes)
					LinkLastChild(id, pi);
				mPublicId = mStore.NewText(reader.PublicId);
				mSystemId = mStore.NewText(reader.SystemId);
				mHasPublicId = reader.HasPublicId;
				mHasSystemId = reader.HasSystemId;
				mInternalSubset = mStore.NewText(reader.InternalSubset);
				mHasInternalSubset = reader.HasInternalSubset;
				for (var notation in reader.Notations)
				{
					notation.mName = mStore.NewText(notation.mName);
					notation.mPublicId = mStore.NewText(notation.mPublicId);
					notation.mSystemId = mStore.NewText(notation.mSystemId);
					mNotations.Add(notation);
				}
			case .EndOfDocument:
				mEncoding = reader.DocumentEncoding;
				mEncodingWarning = reader.EncodingWarning;
				return .Ok;
			}
			// Text, CDATA, comments, PIs, references, the DOCTYPE: the event's range
			if (positions && event != .StartElement && mNodes.Count > nodesBefore)
				RecordRange(mNodeRanges, (uint32)(mNodes.Count - 1), reader, reader.Offset, reader.EndOffset - reader.Offset);
		}
	}

	/// Records a source range at `index` of `ranges` (growing it with "no position" records), its line
	/// and column from the reader.
	static void RecordRange(List<XmlRangeRecord> ranges, int index, XmlReader reader, int offset, int length)
	{
		while (ranges.Count <= index)
			ranges.Add(default);
		reader.Locate(offset, let line, let column);
		ranges[index] = .() { mLine = (int32)line, mColumn = (int32)column, mOffset = (int32)offset, mLength = (int32)length };
	}

	/// The recorded source range, if the document was read with positions and the item has one.
	internal bool TryGetRange(List<XmlRangeRecord> ranges, int index, out XmlSourceRange range)
	{
		if (index < ranges.Count && ranges[index].mLine > 0)
		{
			let r = ranges[index];
			range = .(r.mLine, r.mColumn, r.mOffset, r.mLength, mSourceName);
			return true;
		}
		range = default;
		return false;
	}

	void AddValueNode(XmlNodeKind kind, StringView value, uint32 parent)
	{
		uint32 id = NewNode(kind);
		mNodes[id].mValue = Own(value);
		LinkLastChild(parent, id);
	}

	/// A view the document owns: `text` itself when it views the document's copy of the input, else a
	/// copy in the store.
	[Inline]
	StringView Own(StringView text)
	{
		if (text.Ptr >= mInputStart && text.Ptr + text.Length <= mInputEnd && mInputStart != null)
			return text;
		return mStore.NewText(text);
	}

	// Node table

	internal bool IsLive(uint32 id)
	{
		return id < (uint32)mNodes.Count && !mNodes[id].mFlags.HasFlag(.Removed);
	}

	/// A saved view (Children, Attributes, Named, Descendants) made at `generation` for node `id`: a fatal
	/// error if the document was read again or cleared since, or the node removed.
	[Inline]
	internal void CheckView(uint32 generation, uint32 id)
	{
		if (generation != mGeneration || !IsLive(id))
			Runtime.FatalError("XmlBeef: a saved node list, attribute list or enumerator is stale: its document was read again or cleared, or its node removed");
	}

	/// Adds an unlinked node.
	[Inline]
	internal uint32 NewNode(XmlNodeKind kind)
	{
		uint32 id = (uint32)mNodes.Count;
		ref XmlNodeRecord node = ref mNodes.AddDefault();
		node.mKind = kind;
		node.mAttributeStart = (int32)mAttributes.Count;
		return id;
	}

	/// Links an unlinked node as the last child of `parent`.
	internal void LinkLastChild(uint32 parent, uint32 child)
	{
		ref XmlNodeRecord p = ref mNodes[parent];
		ref XmlNodeRecord c = ref mNodes[child];
		c.mParent = parent;
		c.mNextSibling = 0;
		c.mPrevSibling = p.mLastChild;
		if (p.mLastChild != 0)
			mNodes[p.mLastChild].mNextSibling = child;
		else
			p.mFirstChild = child;
		p.mLastChild = child;
		p.mChildCount++;
	}
}
