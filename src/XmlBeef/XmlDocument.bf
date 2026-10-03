using System;
using System.Collections;
using System.IO;
using FormatCore;
using internal FormatCore;
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
	EmptyTag = 2,
	/// Its name or value was changed (a DOCTYPE processing instruction is then regenerated).
	Edited = 4,
	/// A DOCTYPE processing instruction read from a parameter entity: the entity writes it, so it
	/// cannot be changed.
	FromEntity = 8,
	/// A DOCTYPE processing instruction whose place in the internal subset's text is recorded.
	InSubsetText = 16
}

/// A DOCTYPE processing instruction's place in the internal subset's text (offsets into it).
internal struct XmlSubsetItem
{
	/// Its node; 0 (the document node, never in the subset) once compaction dropped a removed one.
	public uint32 mId;
	public int32 mStart;
	public int32 mEnd;
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
	/// The DOCTYPE's processing instructions in the internal subset's text, in order, and the
	/// document offset where that text starts: the writers rebuild the subset around them.
	internal List<XmlSubsetItem> mSubsetItems ~ delete _;
	internal int32 mSubsetOffset;
	/// The errors of the last read with XmlReadConfig.CollectErrors (their text in the store).
	List<XmlParseError> mErrors ~ delete _;
	internal List<XmlNotation> mNotations ~ delete _;
	/// Read with namespace processing.
	internal bool mNamespaces;
	/// Positions mode: the source range of each node (by ID) and attribute (by index); empty otherwise.
	internal List<XmlRangeRecord> mNodeRanges ~ delete _;
	internal List<XmlRangeRecord> mAttributeRanges ~ delete _;
	/// The document's copy of the input it was read from: values that are views of it are kept as they
	/// are, and only decoded text (references, line ends) is copied into the store (FormatCore's
	/// KeptSource).
	KeptSource mInput;
	/// PreserveStyle (XmlDocument.Style.bf): the source text (UTF-8, as the reader's offsets index it),
	/// whether the input started with a byte order mark, the landmarks outside the nodes, and the
	/// nodes' and attributes' source pieces (by ID and index; empty otherwise).
	internal bool mPreserve;
	/// The source text, kept by reads with metadata from memory (KeepSource); positions are located in
	/// it on demand, through the line starts (built on first use).
	internal StringView mSource;
	bool mSourceKept;
	LineIndex<XmlText> mLineStarts ~ delete _;
	internal bool mHasBom;
	internal int32 mContentStart;
	internal int32 mDeclarationStart;
	internal int32 mDeclarationEnd;
	internal int32 mTailStart;
	internal List<XmlNodeStyle> mNodeStyles ~ delete _;
	internal List<XmlAttributeStyle> mAttributeStyles ~ delete _;
	/// While WriteBytes writes: the encoding generated pieces are checked for, and the options saying what
	/// to do with a character it cannot hold (mFixing: a policy other than failing is active).
	/// A mutation may have made the namespaces invalid (CheckNamespaces runs before WriteBytes).
	internal bool mNamespacesChanged;
	internal bool mFixing;
	internal XmlEncoding mFixEncoding;
	internal XmlWriteOptions mFixOptions;
	/// Capture state during a PreserveStyle read: the end of the last construct at the current level,
	/// and the enclosing levels'.
	bool mStyleBegun;
	int32 mLastEnd;
	List<int32> mStyleEnds ~ delete _;
	/// The source name of the last read (for errors).
	internal String mSourceName ~ delete _;
	/// Changes on every Clear and Read, so handles from before can tell they are stale.
	internal uint32 mGeneration;
	/// The reader behind Read, kept for its buffers.
	XmlReader mReader ~ delete _;
	/// Scratch for Read (open elements, the DOCTYPE's processing instructions) and Write.
	XmlStack<uint32> mNodeStack ~ delete _;
	List<uint32> mPendingDocTypeNodes ~ delete _;

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
		mNodeRanges = new .();
		mAttributeRanges = new .();
		mNodeStyles = new .();
		mAttributeStyles = new .();
		mStyleEnds = new .();
		mLineStarts = new .();
		mSubsetItems = new .();
		mErrors = new .();
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
	/// @brief The errors of the last read with XmlReadConfig.CollectErrors, in order (empty otherwise, or
	/// when it read without error). Read returns the first. Their text belongs to the document (valid
	/// until it is cleared or read again; XmlParseError.Detach copies one).
	public Span<XmlParseError> Errors => mErrors;
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
		mSubsetItems.Clear();
		mSubsetOffset = 0;
		mErrors.Clear();
		mNamespacesChanged = false;
		mNamespaces = true;
		mInput.Clear();
		mPreserve = false;
		mSource = default;
		mSourceKept = false;
		mLineStarts.Clear();
		mHasBom = false;
		mContentStart = 0;
		mDeclarationStart = 0;
		mDeclarationEnd = 0;
		mTailStart = 0;
		mNodeStyles.Clear();
		mAttributeStyles.Clear();
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
			mInput.Set(owned);
		}
		mHasBom = StartsWithAnyBom(input);
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
		if (config.MetadataMode == .PreserveStyle)
		{
			// The document keeps the whole source text anyway: read it all, then as memory input
			let bytes = scope List<uint8>();
			if (ReadShell.ReadStreamBytes(stream, config.MaxInputBytes, bytes) case .Err(let inputError))
			{
				Clear();
				var error = XmlInput.Error(inputError);
				error.SetSource(config.SourceName);
				return .Err(error);
			}
			return Read(StringView((char8*)bytes.Ptr, bytes.Count), config);
		}
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
		// Collect-errors keeps what was read
		if (result case .Err && mErrors.IsEmpty)
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
		// The whole file within MaxInputBytes (FormatCore's read shell: a larger file fails from its size
		// before anything is read, one that grows while read stops at the limit)
		if (ReadShell.ReadFileBytes(path, config.MaxInputBytes, bytes) case .Err(let inputError))
		{
			Clear();
			var error = XmlInput.Error(inputError);
			error.SetSource(config.SourceName);
			return .Err(error);
		}
		return ReadBytes(bytes, config);
	}

	/// Turns the reader's events into records.
	Result<void, XmlParseError> Build(XmlReader reader, XmlReadConfig config)
	{
		switch (config.MetadataMode)
		{
		case .None: return Build<const 0>(reader, config);
		case .Positions: return Build<const 1>(reader, config);
		case .PreserveStyle: return Build<const 2>(reader, config);
		}
	}

	/// Build for one metadata mode (the XmlMetadataMode as a number), so a read without metadata has
	/// none of its work in the loop.
	Result<void, XmlParseError> Build<CMode>(XmlReader reader, XmlReadConfig config) where CMode : const int
	{
		mNamespaces = config.Namespaces;
		mNodeStack.Count = 0;
		mPendingDocTypeNodes.Clear();
		const bool positions = CMode != 0;
		const bool preserve = CMode == 2;
		mPreserve = preserve;
		mStyleBegun = false;
		mStyleEnds.Clear();
		uint32 current = 0;
		while (true)
		{
			let next = reader.Next();
			if (next case .Err(let error))
			{
				if (!config.CollectErrors)
					return .Err(error);
				// Collect-errors: kept (its text copied into the store), and the reader goes on unless it
				// stopped
				var kept = error;
				kept.mMessage = mStore.NewText(error.mMessage);
				kept.mSource = mSourceName;
				mErrors.Add(kept);
				if (reader.IsStopped)
					return .Err(mErrors[0]);
				continue;
			}
			let event = next.Get();
			int nodesBefore = mNodes.Count;
			// The event's fields, read straight from the core (it changes only on Reset)
			XmlReaderCoreBase core = reader.Core;
			switch (event)
			{
			case .StartElement:
				uint32 id = NewNode(.Element);
				ref XmlNodeRecord element = ref mNodes[id];
				element.mName = core.mNameId;
				element.mNamespace = core.mNamespace;
				if (core.mIsEmpty)
					element.mFlags = .EmptyTag;
				int count = core.mAttributes.Count;
				element.mAttributeStart = (int32)mAttributes.Count;
				element.mAttributeCount = (int32)count;
				XmlAttributeRecord* attributes = mAttributes.GrowUninitialized(count);
				XmlReaderCoreBase.AttributeRecord* read = core.mAttributes.Span.Ptr;
				for (int i < count)
				{
					XmlAttributeRecord* attribute = &attributes[i];
					XmlReaderCoreBase.AttributeRecord* source = &read[i];
					attribute.mName = source.mName;
					attribute.mLocal = source.mLocal.IsValid ? source.mLocal : source.mName;
					attribute.mNamespace = source.mNamespace;
					attribute.mValue = Own(source.mValue);
					attribute.mFlags = source.mSpecified ? .None : .Defaulted;
				}
				if (positions)
				{
					// Attribute ranges by index, after the element's own (events come in source order)
					RecordRange(mNodeRanges, id, reader, reader.Offset, reader.EndOffset - reader.Offset);
					for (int i < count)
					{
						// Name through closing quote; a defaulted attribute has none
						XmlReaderCoreBase.AttributeRecord* source = &read[i];
						if (source.mSpecified)
							RecordRange(mAttributeRanges, (int)element.mAttributeStart + i, reader, source.mOffset, source.mEnd - source.mOffset);
					}
				}
				LinkLastChild(current, id);
				if (current == 0)
					mRoot = id;
				if (preserve)
					CaptureStartElement(reader, id);
				mNodeStack.Add(current);
				current = id;
			case .EndElement:
				// The element's range runs through its end tag
				if (positions)
					mNodeRanges[current].mLength = (int32)(reader.EndOffset - mNodeRanges[current].mOffset);
				if (preserve)
					CaptureEndElement(reader, current);
				current = mNodeStack.PopBack();
			case .Text:
				AddValueNode(.Text, core.mValue, current);
			case .CData:
				AddValueNode(.CData, core.mValue, current);
			case .Comment:
				AddValueNode(.Comment, core.mValue, current);
			case .ProcessingInstruction:
				uint32 id = NewNode(.ProcessingInstruction);
				mNodes[id].mName = mNames.Intern(reader.Name);
				mNodes[id].mValue = Own(reader.Value);
				// The internal subset's are the DOCTYPE's children, linked when it is reported, with their
				// place in the subset's text (one from a parameter entity has the reference's)
				if (reader.IsInDocType)
				{
					mPendingDocTypeNodes.Add(id);
					if (reader.IsInEntity)
						mNodes[id].mFlags |= .FromEntity;
					else
					{
						mNodes[id].mFlags |= .InSubsetText;
						int subset = reader.SubsetStart;
						mSubsetItems.Add(.() { mId = id, mStart = (int32)(reader.Offset - subset), mEnd = (int32)(reader.EndOffset - subset) });
					}
				}
				else
					LinkLastChild(current, id);
			case .EntityReference:
				uint32 id = NewNode(.EntityReference);
				mNodes[id].mName = mNames.Intern(reader.Name);
				LinkLastChild(current, id);
			case .XmlDeclaration:
				if (preserve)
					CaptureDeclaration(reader);
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
				mSubsetOffset = (int32)reader.SubsetStart;
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
				if (preserve)
				{
					CaptureBegin(reader);
					mTailStart = mLastEnd;
				}
				if (!mErrors.IsEmpty)
					return .Err(mErrors[0]);
				return .Ok;
			}
			// Text, CDATA, comments, PIs, references, the DOCTYPE: the event's range
			if (positions && event != .StartElement && mNodes.Count > nodesBefore)
			{
				RecordRange(mNodeRanges, (uint32)(mNodes.Count - 1), reader, reader.Offset, reader.EndOffset - reader.Offset);
				// The DOCTYPE's processing instructions are written with it
				if (preserve && !(event == .ProcessingInstruction && reader.IsInDocType))
					CaptureLeaf(reader, (uint32)(mNodes.Count - 1));
			}
		}
	}

	/// Records a source range at `index` of `ranges` (growing it with "no position" records). From memory
	/// input only the offsets are recorded (line -1): TryGetRange locates them in the kept source when
	/// asked. A stream keeps no source, so its ranges are located as they are read.
	void RecordRange(List<XmlRangeRecord> ranges, int index, XmlReader reader, int offset, int length)
	{
		if (!mSourceKept)
			KeepSource(reader);
		XmlRangeRecord record;
		if (!mSource.IsEmpty)
			record = .() { mLine = -1, mColumn = 0, mOffset = (int32)offset, mLength = (int32)length };
		else
		{
			reader.Locate(offset, let line, let column);
			record = .() { mLine = (int32)line, mColumn = (int32)column, mOffset = (int32)offset, mLength = (int32)length };
		}
		// Usually the next one
		while (ranges.Count < index)
			ranges.Add(default);
		if (index == ranges.Count)
			ranges.Add(record);
		else
			ranges[index] = record;
	}

	/// At the first event of a read with metadata: the source text the reader's offsets index, kept as
	/// the document's copy of the input when it is that, else copied (a transcoded document); none from a
	/// stream.
	internal void KeepSource(XmlReader reader)
	{
		if (mSourceKept)
			return;
		mSourceKept = true;
		StringView text = reader.SourceText;
		if (text.IsEmpty)
			mSource = default;
		else if (mInput.Contains(text))
			mSource = text;
		else
			mSource = mStore.NewText(text);
	}

	/// Line and column of `offset` in the kept source, through an index of line starts built on first use.
	void LocateInSource(int offset, out int line, out int column)
	{
		mLineStarts.Locate(mSource.Ptr, mSource.Length, offset, out line, out column);
	}

	/// Whether `input` starts with a UTF-8, UTF-16 or UTF-32 byte order mark.
	static bool StartsWithAnyBom(StringView input)
	{
		if (Utf8.StartsWithBom(input.Ptr, input.Length))
			return true;
		if (input.Length >= 2 && (((uint8)input[0] == 0xFE && (uint8)input[1] == 0xFF) || ((uint8)input[0] == 0xFF && (uint8)input[1] == 0xFE)))
			return true;
		return input.Length >= 4 && input[0] == 0 && input[1] == 0 && (uint8)input[2] == 0xFE && (uint8)input[3] == 0xFF;
	}

	/// The recorded source range, if the document was read with positions and the item has one.
	internal bool TryGetRange(List<XmlRangeRecord> ranges, int index, out XmlSourceRange range)
	{
		if (index < ranges.Count && ranges[index].mLine != 0)
		{
			if (ranges[index].mLine < 0)
			{
				LocateInSource(ranges[index].mOffset, let line, let column);
				ranges[index].mLine = (int32)line;
				ranges[index].mColumn = (int32)column;
			}
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
		return mInput.Own(text, mStore.Text);
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
