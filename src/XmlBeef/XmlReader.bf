using System;
using System.Collections;
using System.IO;
using internal XmlBeef;

namespace XmlBeef;

/// @brief What XmlReader.Next reached.
public enum XmlEvent : uint8
{
	/// @brief The end of the document: the root element has ended. Further calls return it again.
	EndOfDocument,
	/// @brief The XML declaration: `Version`, `Encoding` and `Standalone` are set.
	XmlDeclaration,
	/// @brief The DOCTYPE, after its whole internal subset: `Name` is the root element's name;
	/// `PublicId`, `SystemId`, `InternalSubset` and `Notations` are set.
	DocType,
	/// @brief An element begins: `Name` (and with namespaces `LocalName`, `Prefix`, `NamespaceUri`),
	/// the attributes and `IsEmptyElement` are set. Its content follows, then its EndElement (also for
	/// an empty element, `<a/>`, on the next call).
	StartElement,
	/// @brief The innermost element ends: `Name` and its namespace are set.
	EndElement,
	/// @brief Character data (`Value`), with line ends normalized and references expanded. Adjacent text
	/// is one event, also across entity references; CDATA sections are events of their own.
	Text,
	/// @brief A CDATA section's content (`Value`).
	CData,
	/// @brief A comment's text (`Value`).
	Comment,
	/// @brief A processing instruction: `Name` is its target, `Value` its data (from after the
	/// whitespace that follows the target).
	ProcessingInstruction,
	/// @brief A reference to an entity that is not read (`Name`): an external entity, or one whose
	/// declaration may be in an external subset or parameter entity that was not read (a skipped
	/// entity, §4.4.3).
	EntityReference
}

/// A pull reader over an XML 1.0 document: each call to `Next` reads up to the next event and reports
/// it. It builds no document; the event's strings are views into the input or into the reader's
/// buffers, valid until the next call to `Next` or `Reset`.
///
/// The input is bytes in memory: UTF-8 (with or without a byte order mark), UTF-16 or UTF-32 (with a
/// byte order mark, or the `<?xml` byte pattern), ISO-8859-1 or US-ASCII (declared), transcoded to
/// UTF-8 first. Well-formedness is checked in full, with namespaces unless the config turns them off;
/// the internal subset of a DOCTYPE is read and applied (entities, attribute defaults and types);
/// nothing external is ever read. The first error ends the read: `Next` returns it again on every
/// later call.
///
/// ```
/// let reader = scope XmlReader(text);
/// while (true)
/// {
///     switch (Try!(reader.Next()))
///     {
///     case .StartElement: Console.WriteLine(reader.Name);
///     case .EndOfDocument: return .Ok;
///     default:
///     }
/// }
/// ```
public class XmlReader
{
	XmlReaderCore<XmlByteCursor> mBytes ~ delete _;
	/// Created on the first stream read.
	XmlReaderCore<XmlBufferedStreamCursor> mStream ~ delete _;
	XmlStreamState mStreamState ~ delete _;
	/// The core reading now (mBytes or mStream): the event's state is read from it.
	XmlReaderCoreBase mCore;
	bool mStreaming;
	String mTranscoded ~ delete _;

	/// @brief Create a reader with no input; call Reset before reading.
	public this()
	{
		mBytes = new .();
		mCore = mBytes;
		mTranscoded = new .();
	}

	/// @brief Create a reader over `input`, which must outlive the reader's use of it.
	/// @param input The document's bytes (any supported encoding; see the class).
	public this(StringView input) : this()
	{
		Reset(input);
	}

	/// @brief Create a reader over `input` with a config.
	/// @param input The document's bytes (any supported encoding; see the class).
	/// @param config Namespaces, DTD handling, limits and the source name.
	public this(StringView input, XmlReadConfig config) : this()
	{
		Reset(input, config);
	}

	/// @brief Start reading `input` from the beginning with the default config, reusing the reader's
	/// buffers.
	/// @param input The document's bytes.
	public void Reset(StringView input)
	{
		Reset(input, .());
	}

	/// @brief Start reading `input` from the beginning, reusing the reader's buffers.
	/// @param input The document's bytes; it must outlive the read.
	/// @param config Namespaces, DTD handling, limits and the source name (only viewed: it must outlive
	/// the read).
	public void Reset(StringView input, XmlReadConfig config)
	{
		Reset(input, config, null);
	}

	/// @brief Start reading bytes from the beginning.
	/// @param input The document's bytes; they must outlive the read.
	/// @param config Namespaces, DTD handling, limits and the source name.
	public void Reset(Span<uint8> input, XmlReadConfig config)
	{
		Reset(StringView((char8*)input.Ptr, input.Length), config);
	}

	/// Starts a read that interns names into `names` (a document's, cleared by it; null: the reader's own).
	internal void Reset(StringView input, XmlReadConfig config, XmlNameTable names)
	{
		mStreaming = false;
		mCore = mBytes;
		mTranscoded.Clear();
		mBytes.Reset(XmlByteCursor(input, mTranscoded, config), config, names);
	}

	/// @brief Start reading a stream with the default config.
	/// @param stream The document (any supported encoding; see the class), read from its current
	/// position; it must outlive the reader's use of it.
	public void Reset(Stream stream)
	{
		Reset(stream, .());
	}

	/// @brief Start reading a stream through a buffer of `config.StreamBufferBytes` (64 KiB by default):
	/// memory stays bounded by the buffer and the longest construct (see `config.MaxTokenBytes`). The
	/// events and errors are those of the same document in memory, except that an encoding error further
	/// on than the first buffer is reported when the reader gets there, after the events before it.
	/// @param stream The document, read from its current position; it must outlive the reader's use of it.
	/// @param config Namespaces, DTD handling, limits, buffer size and the source name.
	public void Reset(Stream stream, XmlReadConfig config)
	{
		Reset(stream, config, null);
	}

	/// A stream read that interns names into `names` (a document's; null: the reader's own).
	internal void Reset(Stream stream, XmlReadConfig config, XmlNameTable names)
	{
		mStreaming = true;
		if (mStream == null)
		{
			mStream = new .();
			mStreamState = new .();
		}
		mCore = mStream;
		mStream.Reset(XmlBufferedStreamCursor(stream, mStreamState, config), config, names);
	}

	/// The table the event's names are interned in.
	internal XmlNameTable Names => mCore.mNames;

	/// @brief ProcessingInstruction: whether it is inside the DOCTYPE's internal subset (reported before
	/// the DocType event, which comes at the DOCTYPE's end).
	public bool IsInDocType => mCore.InDocType;

	/// @brief Read up to the next event.
	/// @return The event, or the read's error (see IsStopped).
	[Inline]
	public Result<XmlEvent, XmlParseError> Next()
	{
		if (!mStreaming)
		{
			if (mBytes.NextEvent() case .Ok(let event))
				return .Ok(event);
			return .Err(mBytes.Error);
		}
		if (mStream.NextEvent() case .Ok(let event))
			return .Ok(event);
		return .Err(mStream.Error);
	}

	/// @brief Whether the read has stopped at an error; Next returns it again.
	public bool IsStopped => mCore.IsStopped;

	/// @brief StartElement, EndElement: the element's qualified name as written. ProcessingInstruction:
	/// the target. EntityReference: the entity's name. DocType: the root element's name.
	public StringView Name => mCore.mName;
	/// @brief StartElement, EndElement: the element's interned name (also its ID in `NameTable`).
	public XmlNameId NameId => mCore.mNameId;
	/// @brief StartElement, EndElement: the local part of the name (the name itself without
	/// namespaces or without a prefix).
	public StringView LocalName
	{
		get
		{
			if (!mCore.mNameId.IsValid || !mCore.mConfig.Namespaces)
				return mCore.mName;
			return mCore.mNames[mCore.mNames.LocalOf(mCore.mNameId)];
		}
	}
	/// @brief StartElement, EndElement: the prefix (empty if none, or without namespaces).
	public StringView Prefix
	{
		get
		{
			if (!mCore.mNameId.IsValid || !mCore.mConfig.Namespaces)
				return default;
			return mCore.mNames[mCore.mNames.PrefixOf(mCore.mNameId)];
		}
	}
	/// @brief StartElement, EndElement: the namespace name (empty for none).
	public StringView NamespaceUri => mCore.mNames[mCore.mNamespace];
	/// @brief StartElement, EndElement: the namespace's interned ID (XmlNameId.None for none).
	public XmlNameId NamespaceId => mCore.mNamespace;
	/// @brief Text, CData, Comment, ProcessingInstruction: the content.
	public StringView Value => mCore.mValue;
	/// @brief StartElement: whether the element was written as an empty-element tag (`<a/>`).
	public bool IsEmptyElement => mCore.mIsEmpty;
	/// @brief The depth of the event: 0 for the root element's StartElement and EndElement and for
	/// everything outside it, 1 for the root's content, and so on.
	public int Depth => mCore.mDepth;
	/// @brief Byte offset into the input where the event's construct starts (inside an entity's
	/// replacement text: the reference's). In UTF-8 terms when the input was transcoded.
	public int Offset => mCore.mEventOffset;
	/// @brief Byte offset just past the event's construct.
	public int EndOffset => mCore.mEventEnd;
	/// The core reading now, for XmlDocument.Build to read the event's fields without the dispatch of
	/// the properties (valid until the next Reset).
	internal XmlReaderCoreBase Core => mCore;
	/// Whether the event was read from an entity's replacement text (its range is the reference's).
	internal bool IsInEntity => mCore.mFrames.Count > 0;
	/// The offset of the first content byte, after a UTF-8 byte order mark (after the first Next).
	internal int ContentStart => mCore.mContentStart;
	/// In-memory input: the UTF-8 text the offsets index (the input, or its transcoding).
	internal StringView SourceText => mStreaming ? default : mBytes.mCursor.Text;

	/// @brief XmlDeclaration: the version as written (`1.0`; any `1.x` is read as 1.0).
	public StringView Version => mCore.mVersion;
	/// @brief XmlDeclaration: the declared encoding name, empty if none.
	public StringView Encoding => mCore.mEncodingName;
	/// @brief XmlDeclaration: the `standalone` pseudo-attribute.
	public XmlStandalone Standalone => mCore.mStandalone;
	/// @brief The encoding the document was read in (after the first Next).
	public XmlEncoding DocumentEncoding => mStreaming ? mStream.mCursor.Encoding : mBytes.mCursor.Encoding;
	/// @brief A warning about the document's encoding, empty if none (after the first Next): the one
	/// there is, a UTF-8 byte order mark overriding an encoding declaration that names another
	/// (8-bit) encoding, which is read as UTF-8 (plan.md §9 item 6).
	public StringView EncodingWarning
	{
		get
		{
			bool overridden = mStreaming ? mStream.mCursor.BomOverridesDeclaration : mBytes.mCursor.BomOverridesDeclaration;
			return overridden ? "The document starts with a UTF-8 byte order mark, so its encoding declaration is ignored and it is read as UTF-8" : default;
		}
	}

	/// @brief DocType: the public identifier as written (empty if none; see HasPublicId).
	public StringView PublicId => mCore.mPublicId;
	/// @brief DocType: the system identifier (empty if none; see HasSystemId).
	public StringView SystemId => mCore.mSystemId;
	/// @brief DocType: whether a public identifier was given.
	public bool HasPublicId => mCore.mHasPublicId;
	/// @brief DocType: whether a system identifier was given.
	public bool HasSystemId => mCore.mHasSystemId;
	/// @brief DocType: the internal subset's text between `[` and `]`, empty if none.
	public StringView InternalSubset => mCore.mInternalSubset;
	/// @brief DocType: whether it has an internal subset (`[…]`, possibly empty).
	public bool HasInternalSubset => mCore.HasInternalSubset;
	/// @brief The notations declared in the internal subset, in declaration order (from DocType on).
	public Span<XmlNotation> Notations => mCore.mDtd.mNotations;

	/// @brief StartElement: the number of attributes, defaulted ones (from ATTLIST declarations)
	/// included, after the specified ones. Namespace declarations (`xmlns`, `xmlns:p`) are attributes.
	public int AttributeCount => mCore.mAttributes.Count;

	/// @brief StartElement: an attribute's qualified name as written.
	/// @param index 0 ..< AttributeCount.
	/// @return The name.
	public StringView AttributeName(int index) => mCore.mNames[mCore.mAttributes[index].mName];

	/// @brief StartElement: an attribute's interned name.
	/// @param index 0 ..< AttributeCount.
	/// @return The name's ID.
	public XmlNameId AttributeNameId(int index) => mCore.mAttributes[index].mName;

	/// An attribute's interned local name (its name when it has no prefix or without namespaces).
	internal XmlNameId AttributeLocalId(int index)
	{
		let attribute = mCore.mAttributes[index];
		return attribute.mLocal.IsValid ? attribute.mLocal : attribute.mName;
	}

	/// An attribute's interned namespace (None for no namespace).
	internal XmlNameId AttributeNamespaceId(int index) => mCore.mAttributes[index].mNamespace;

	/// @brief StartElement: where an attribute is in the input, from its name to just past its value's
	/// closing quote (inside an entity's replacement text: the reference). Both 0 for a defaulted one.
	/// @param index 0 ..< AttributeCount.
	/// @param offset Receives the byte offset of its name.
	/// @param end Receives the byte offset just past it.
	public void GetAttributeRange(int index, out int offset, out int end)
	{
		let attribute = mCore.mAttributes[index];
		offset = attribute.mSpecified ? attribute.mOffset : 0;
		end = attribute.mSpecified ? attribute.mEnd : 0;
	}

	/// @brief StartElement: an attribute's local name (the name itself without a prefix or namespaces).
	/// @param index 0 ..< AttributeCount.
	/// @return The local name.
	public StringView AttributeLocalName(int index)
	{
		let attribute = mCore.mAttributes[index];
		return mCore.mNames[attribute.mLocal.IsValid ? attribute.mLocal : attribute.mName];
	}

	/// @brief StartElement: an attribute's prefix (empty if none).
	/// @param index 0 ..< AttributeCount.
	/// @return The prefix.
	public StringView AttributePrefix(int index) => mCore.mNames[mCore.mAttributes[index].mPrefix];

	/// @brief StartElement: an attribute's namespace (empty for none: an unprefixed attribute is in no
	/// namespace).
	/// @param index 0 ..< AttributeCount.
	/// @return The namespace name.
	public StringView AttributeNamespaceUri(int index) => mCore.mNames[mCore.mAttributes[index].mNamespace];

	/// @brief StartElement: an attribute's normalized value (§3.3.3).
	/// @param index 0 ..< AttributeCount.
	/// @return The value.
	public StringView AttributeValue(int index) => mCore.mAttributes[index].mValue;

	/// @brief StartElement: whether the attribute was given in the tag (false: a default from an
	/// ATTLIST declaration).
	/// @param index 0 ..< AttributeCount.
	/// @return Whether it was specified.
	public bool IsAttributeSpecified(int index) => mCore.mAttributes[index].mSpecified;

	/// @brief StartElement: the value of the attribute with this qualified name.
	/// @param name The name as written (`xlink:href`).
	/// @param value Receives the value.
	/// @return Whether the element has the attribute.
	public bool TryGetAttribute(StringView name, out StringView value)
	{
		for (int i < mCore.mAttributes.Count)
		{
			let attribute = mCore.mAttributes[i];
			if (mCore.mNames[attribute.mName] == name)
			{
				value = attribute.mValue;
				return true;
			}
		}
		value = default;
		return false;
	}

	/// @brief StartElement: the value of the attribute with this namespace and local name.
	/// @param namespaceUri The namespace name (empty: no namespace).
	/// @param localName The local name.
	/// @param value Receives the value.
	/// @return Whether the element has the attribute.
	public bool TryGetAttribute(StringView namespaceUri, StringView localName, out StringView value)
	{
		for (int i < mCore.mAttributes.Count)
		{
			let attribute = mCore.mAttributes[i];
			XmlNameId local = attribute.mLocal.IsValid ? attribute.mLocal : attribute.mName;
			if (mCore.mNames[local] == localName && mCore.mNames[attribute.mNamespace] == namespaceUri)
			{
				value = attribute.mValue;
				return true;
			}
		}
		value = default;
		return false;
	}

	/// @brief Text, CData: whether the value is all whitespace (space, tab, LF, CR).
	public bool IsWhitespace
	{
		get
		{
			for (let c in mCore.mValue)
			{
				if (!XmlChar.IsSpace(c))
					return false;
			}
			return true;
		}
	}

	/// The line and column of a document offset at or after the current event's start.
	internal bool Locate(int offset, out int line, out int column)
	{
		if (mStreaming)
			return mStream.mCursor.Locate(offset, out line, out column);
		return mBytes.mCursor.Locate(offset, out line, out column);
	}
}
