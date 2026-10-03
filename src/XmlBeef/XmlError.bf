using System;
using FormatCore;
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

/// @brief A read error with location information for precise error reporting: FormatCore's
/// `ParseError` over XmlErrorKind (kind, message, source name, 1-based line and column in code points,
/// byte offset (in UTF-8 terms when the input was transcoded) and length; `SetSource`, `Detach`,
/// `ToString` as `source:line:column: message`).
///
/// The error owns nothing and needs no cleanup, so it can be dropped freely (including by `Try!`).
/// `mMessage` views a per-thread buffer: it stays valid until the next XmlParseError is created on the
/// same thread, which in practice means the next failing XmlBeef call. To keep one longer, make an
/// XmlDiagnostic of it (`new XmlDiagnostic(error)`, which owns its text), or copy the message.
/// (XmlDocument.Errors are an exception: their text belongs to the document.)
public typealias XmlParseError = FormatCore.ParseError<XmlErrorKind>;
