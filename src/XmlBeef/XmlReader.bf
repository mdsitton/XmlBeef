using System;
using System.Collections;
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
	String mTranscoded ~ delete _;

	/// @brief Create a reader with no input; call Reset before reading.
	public this()
	{
		mBytes = new .();
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
		mTranscoded.Clear();
		mBytes.Reset(XmlByteCursor(input, mTranscoded, config), config);
	}

	/// @brief Start reading bytes from the beginning.
	/// @param input The document's bytes; they must outlive the read.
	/// @param config Namespaces, DTD handling, limits and the source name.
	public void Reset(Span<uint8> input, XmlReadConfig config)
	{
		Reset(StringView((char8*)input.Ptr, input.Length), config);
	}

	/// @brief Read up to the next event.
	/// @return The event, or the read's error (see IsStopped).
	[Inline]
	public Result<XmlEvent, XmlParseError> Next()
	{
		if (mBytes.NextEvent() case .Ok(let event))
			return .Ok(event);
		return .Err(mBytes.Error);
	}

	/// @brief Whether the read has stopped at an error; Next returns it again.
	public bool IsStopped => mBytes.IsStopped;

	/// @brief StartElement, EndElement: the element's qualified name as written. ProcessingInstruction:
	/// the target. EntityReference: the entity's name. DocType: the root element's name.
	public StringView Name => mBytes.mName;
	/// @brief StartElement, EndElement: the element's interned name (also its ID in `NameTable`).
	public XmlNameId NameId => mBytes.mNameId;
	/// @brief StartElement, EndElement: the local part of the name (the name itself without
	/// namespaces or without a prefix).
	public StringView LocalName
	{
		get
		{
			if (!mBytes.mNameId.IsValid || !mBytes.mConfig.Namespaces)
				return mBytes.mName;
			return mBytes.mNames[mBytes.mNames.LocalOf(mBytes.mNameId)];
		}
	}
	/// @brief StartElement, EndElement: the prefix (empty if none, or without namespaces).
	public StringView Prefix
	{
		get
		{
			if (!mBytes.mNameId.IsValid || !mBytes.mConfig.Namespaces)
				return default;
			return mBytes.mNames[mBytes.mNames.PrefixOf(mBytes.mNameId)];
		}
	}
	/// @brief StartElement, EndElement: the namespace name (empty for none).
	public StringView NamespaceUri => mBytes.mNames[mBytes.mNamespace];
	/// @brief StartElement, EndElement: the namespace's interned ID (XmlNameId.None for none).
	public XmlNameId NamespaceId => mBytes.mNamespace;
	/// @brief Text, CData, Comment, ProcessingInstruction: the content.
	public StringView Value => mBytes.mValue;
	/// @brief StartElement: whether the element was written as an empty-element tag (`<a/>`).
	public bool IsEmptyElement => mBytes.mIsEmpty;
	/// @brief The depth of the event: 0 for the root element's StartElement and EndElement and for
	/// everything outside it, 1 for the root's content, and so on.
	public int Depth => mBytes.mDepth;
	/// @brief Byte offset into the input where the event's construct starts (inside an entity's
	/// replacement text: the reference's). In UTF-8 terms when the input was transcoded.
	public int Offset => mBytes.mEventOffset;
	/// @brief Byte offset just past the event's construct.
	public int EndOffset => mBytes.mEventEnd;

	/// @brief XmlDeclaration: the version as written (`1.0`; any `1.x` is read as 1.0).
	public StringView Version => mBytes.mVersion;
	/// @brief XmlDeclaration: the declared encoding name, empty if none.
	public StringView Encoding => mBytes.mEncodingName;
	/// @brief XmlDeclaration: the `standalone` pseudo-attribute.
	public XmlStandalone Standalone => mBytes.mStandalone;
	/// @brief The encoding the document was read in (after the first Next).
	public XmlEncoding DocumentEncoding => mBytes.mCursor.Encoding;

	/// @brief DocType: the public identifier as written (empty if none; see HasPublicId).
	public StringView PublicId => mBytes.mPublicId;
	/// @brief DocType: the system identifier (empty if none; see HasSystemId).
	public StringView SystemId => mBytes.mSystemId;
	/// @brief DocType: whether a public identifier was given.
	public bool HasPublicId => mBytes.mHasPublicId;
	/// @brief DocType: whether a system identifier was given.
	public bool HasSystemId => mBytes.mHasSystemId;
	/// @brief DocType: the internal subset's text between `[` and `]`, empty if none.
	public StringView InternalSubset => mBytes.mInternalSubset;
	/// @brief The notations declared in the internal subset, in declaration order (from DocType on).
	public Span<XmlNotation> Notations => mBytes.mDtd.mNotations;

	/// @brief StartElement: the number of attributes, defaulted ones (from ATTLIST declarations)
	/// included, after the specified ones. Namespace declarations (`xmlns`, `xmlns:p`) are attributes.
	public int AttributeCount => mBytes.mAttributes.Count;

	/// @brief StartElement: an attribute's qualified name as written.
	/// @param index 0 ..< AttributeCount.
	/// @return The name.
	public StringView AttributeName(int index) => mBytes.mNames[mBytes.mAttributes[index].mName];

	/// @brief StartElement: an attribute's interned name.
	/// @param index 0 ..< AttributeCount.
	/// @return The name's ID.
	public XmlNameId AttributeNameId(int index) => mBytes.mAttributes[index].mName;

	/// @brief StartElement: an attribute's local name (the name itself without a prefix or namespaces).
	/// @param index 0 ..< AttributeCount.
	/// @return The local name.
	public StringView AttributeLocalName(int index)
	{
		let attribute = mBytes.mAttributes[index];
		return mBytes.mNames[attribute.mLocal.IsValid ? attribute.mLocal : attribute.mName];
	}

	/// @brief StartElement: an attribute's prefix (empty if none).
	/// @param index 0 ..< AttributeCount.
	/// @return The prefix.
	public StringView AttributePrefix(int index) => mBytes.mNames[mBytes.mAttributes[index].mPrefix];

	/// @brief StartElement: an attribute's namespace (empty for none: an unprefixed attribute is in no
	/// namespace).
	/// @param index 0 ..< AttributeCount.
	/// @return The namespace name.
	public StringView AttributeNamespaceUri(int index) => mBytes.mNames[mBytes.mAttributes[index].mNamespace];

	/// @brief StartElement: an attribute's normalized value (§3.3.3).
	/// @param index 0 ..< AttributeCount.
	/// @return The value.
	public StringView AttributeValue(int index) => mBytes.mAttributes[index].mValue;

	/// @brief StartElement: whether the attribute was given in the tag (false: a default from an
	/// ATTLIST declaration).
	/// @param index 0 ..< AttributeCount.
	/// @return Whether it was specified.
	public bool IsAttributeSpecified(int index) => mBytes.mAttributes[index].mSpecified;

	/// @brief StartElement: the value of the attribute with this qualified name.
	/// @param name The name as written (`xlink:href`).
	/// @param value Receives the value.
	/// @return Whether the element has the attribute.
	public bool TryGetAttribute(StringView name, out StringView value)
	{
		for (let attribute in mBytes.mAttributes)
		{
			if (mBytes.mNames[attribute.mName] == name)
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
		for (let attribute in mBytes.mAttributes)
		{
			XmlNameId local = attribute.mLocal.IsValid ? attribute.mLocal : attribute.mName;
			if (mBytes.mNames[local] == localName && mBytes.mNames[attribute.mNamespace] == namespaceUri)
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
			for (let c in mBytes.mValue)
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
		return mBytes.mCursor.Locate(offset, out line, out column);
	}
}
