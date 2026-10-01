using System;
using internal XmlBeef;

namespace XmlBeef;

/// Categories of errors that can occur when reading an XML document.
public enum XmlErrorKind : uint8
{
	// Encoding and characters
	/// Bytes that are not valid in the document's encoding (ill-formed UTF-8 or UTF-16).
	InvalidEncoding,
	/// An encoding the reader cannot read (EBCDIC, UTF-7, an unknown name), or an encoding declaration
	/// that contradicts the byte order mark or the bytes.
	UnsupportedEncoding,
	/// A code point outside XML's `Char` production (control characters, U+FFFE, U+FFFF), literal or
	/// from a character reference.
	InvalidChar,

	// Lexical
	/// A character that cannot start or continue what is being read.
	UnexpectedChar,
	/// The input (or an entity's replacement text) ended inside a construct.
	UnexpectedEof,
	/// A malformed name, or a name character where none is allowed.
	InvalidName,
	/// A malformed XML declaration (`<?xml …?>`).
	InvalidXmlDeclaration,
	/// A malformed character or entity reference.
	InvalidReference,
	/// A malformed comment (`--` inside it).
	InvalidComment,
	/// A malformed processing instruction, or one with the reserved target `xml`.
	InvalidProcessingInstruction,
	/// `]]>` in character data, or a CDATA section where none may be.
	InvalidCData,
	/// A malformed DOCTYPE or markup declaration, or a declaration where none may be.
	InvalidDeclaration,

	// Structure
	/// An end tag that does not match the open element, or one with no open element.
	MismatchedEndTag,
	/// An element still open at the end of the input or of the entity it started in.
	UnclosedElement,
	/// The same attribute twice on one element.
	DuplicateAttribute,
	/// No root element, a second root, or text, a reference or a CDATA section outside the root.
	InvalidDocumentStructure,

	// Entities
	/// A reference to an entity that is not declared where the document must declare it.
	UndeclaredEntity,
	/// An entity that refers to itself, directly or through others.
	RecursiveEntity,
	/// A reference that is not allowed where it is: to an unparsed entity, to an external entity in an
	/// attribute value, to a general entity in the DTD, or a parameter entity inside a declaration of
	/// the internal subset.
	InvalidEntityReference,

	// Namespaces
	/// A name that is not a valid qualified name (more than one colon, an empty prefix or local part),
	/// or a colon in an entity name, PI target or notation name.
	InvalidQName,
	/// A prefix used without a namespace declaration in scope.
	UnboundPrefix,
	/// A namespace declaration that breaks the rules for `xml`, `xmlns` and empty namespace names.
	InvalidNamespaceDeclaration,

	// Configuration
	/// A DOCTYPE in a document read with XmlDtdMode.Prohibit.
	DtdProhibited,

	// Limits
	/// A resource limit was exceeded.
	ResourceLimitExceeded,

	// File I/O
	/// Reading the input failed.
	IoError,

	// Typed mapping ([XmlObject])
	/// A required attribute, element or text is absent.
	MissingValue,
	/// A value that does not fit its field: not a number, out of range, no case of the enum.
	InvalidValue,
	/// In a strict type, an attribute, element or text no field maps.
	UnexpectedContent
}

/// A read error with location information for precise error reporting.
///
/// The error owns nothing and needs no cleanup, so it can be dropped freely (including by `Try!`).
/// `mMessage` views a per-thread buffer: it stays valid until the next XmlParseError is created on the
/// same thread, which in practice means the next failing XmlBeef call. To keep one longer, make an
/// XmlDiagnostic of it (`new XmlDiagnostic(error)`, which owns its text), or copy the message.
/// (XmlDocument.Errors are an exception: their text belongs to the document.)
public struct XmlParseError
{
	/// Per-thread message and source-name storage, freed when the thread exits.
	static LazyTLS<String> sMessageBuffer = new .() ~ delete _;
	static LazyTLS<String> sSourceBuffer = new .() ~ delete _;

	public XmlErrorKind mKind;
	/// @brief Human-readable description. Valid until the next error on this thread.
	public StringView mMessage;
	/// @brief Name of the input the position refers to; empty if unnamed. Valid until the next error
	/// on this thread.
	public StringView mSource;
	/// @brief 1-based line (0 when there is no position).
	public int32 mLine;
	/// @brief 1-based column, in code points.
	public int32 mColumn;
	/// @brief Byte offset into the input (in UTF-8 terms when the input was transcoded).
	public int32 mOffset;
	/// @brief Length of the erroneous span in bytes.
	public int32 mLength;

	/// @brief Creates a new error at the given location.
	/// @param kind The category of error.
	/// @param message Human-readable description.
	/// @param line 1-based line number.
	/// @param column 1-based column number.
	/// @param offset Byte offset into the input.
	/// @param length Length of the erroneous span in bytes.
	public this(XmlErrorKind kind, StringView message, int line, int column, int offset, int length = 1)
	{
		mKind = kind;
		mLine = (int32)line;
		mColumn = (int32)column;
		mOffset = (int32)offset;
		mLength = (int32)length;

		mMessage = Store(sMessageBuffer.Value, message);
		mSource = default;
	}

	/// An error at byte `offset` of `input`, with the line and column computed from it.
	internal static XmlParseError At(XmlErrorKind kind, StringView message, StringView input, int offset, int length = 1)
	{
		XmlChar.LineAndColumn(input, offset, let line, let column);
		return XmlParseError(kind, message, line, column, offset, length);
	}

	/// Copies `text` into a per-thread buffer and returns a view of it.
	static StringView Store(String buffer, StringView text)
	{
		// The text may itself be a view of the buffer (an error rebuilt from a previous one)
		char8* start = buffer.Ptr;
		if (text.Ptr >= start && text.Ptr < start + buffer.Length)
		{
			let copy = scope String(text);
			buffer.Set(copy);
		}
		else
			buffer.Set(text);
		return buffer;
	}

	/// @brief Set the source name the position refers to. Stored like the message: valid until the next
	/// error on this thread.
	/// @param source The source name, e.g. a file path.
	public void SetSource(StringView source) mut
	{
		mSource = Store(sSourceBuffer.Value, source);
	}

	/// @brief Copy the message and source name into this thread's error buffers, so the error no longer
	/// depends on where they were. Afterwards the error is like any other: valid until the next error on
	/// this thread.
	public void Detach() mut
	{
		mMessage = Store(sMessageBuffer.Value, mMessage);
		let source = mSource;
		mSource = default;
		if (!source.IsEmpty)
			mSource = Store(sSourceBuffer.Value, source);
	}

	/// @brief Formats the error as `source:line:column: message`, dropping the parts that are unknown
	/// (no source name, or no position: line 0).
	/// @param strBuffer The string to append to.
	public override void ToString(String strBuffer)
	{
		if (!mSource.IsEmpty)
		{
			strBuffer.Append(mSource);
			strBuffer.Append(':');
		}
		if (mLine > 0)
			strBuffer.AppendF("{}:{}:", mLine, mColumn);
		if (!mSource.IsEmpty || mLine > 0)
			strBuffer.Append(' ');
		strBuffer.Append(mMessage);
	}
}
