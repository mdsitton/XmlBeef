using System;

namespace XmlBeef;

/// @brief What a document records about the source while reading.
public enum XmlMetadataMode : uint8
{
	/// @brief Nothing beyond the content.
	None,
	/// @brief Where each node and attribute came from, for diagnostics such as "path at icon.svg:12:5".
	Positions,
	/// @brief Positions, plus the source text of every construct, so a document writes back as it was
	/// read, regenerating only what was changed.
	PreserveStyle
}

/// @brief How a document type declaration (`<!DOCTYPE …>`) is treated.
public enum XmlDtdMode : uint8
{
	/// @brief A DOCTYPE is an error (XmlErrorKind.DtdProhibited).
	Prohibit,
	/// @brief The DOCTYPE and its internal subset are checked for well-formedness but no declaration
	/// is applied: entity references other than the predefined five are reported as skipped
	/// (XmlEvent.EntityReference), and no attribute gets a default or a declared type.
	Ignore,
	/// @brief The internal subset is read and applied: general and parameter entities, attribute
	/// defaults and types, notations. Nothing external is ever read.
	Internal
}

/// Settings for reading XML: namespaces, DTD handling, metadata, the source name for errors, and
/// resource limits for untrusted input. One struct for every entry point.
public struct XmlReadConfig
{
	/// @brief What the document records about the source (XmlDocument only).
	public XmlMetadataMode MetadataMode = .None;
	/// @brief Collect-errors: a well-formedness error does not stop the read. XmlReader.Next returns it,
	/// and the next call goes on after it (a broken construct is skipped, a mismatched end tag closes
	/// the elements down to the one it names, unclosed elements are closed at the end), so an editor or
	/// linter gets every error and as much of the document as could be read. An XmlDocument keeps what
	/// it read and lists the errors in `Errors`. Encoding, I/O and resource-limit errors still stop the
	/// read, as does MaxErrors.
	public bool CollectErrors = false;
	/// @brief With CollectErrors: stop after this many errors. 0 = no limit.
	public int MaxErrors = 100;
	/// @brief Name of the input for error messages and source ranges, typically its file path. Only
	/// read during the call; copies are kept.
	public StringView SourceName = default;

	/// @brief Namespace processing (Namespaces in XML 1.0): names must be qualified names, prefixes
	/// must be declared, and every name is resolved to its namespace. Off, a colon is an ordinary name
	/// character and nothing is resolved.
	public bool Namespaces = true;
	/// @brief How a DOCTYPE is treated.
	public XmlDtdMode DtdMode = .Internal;

	/// @brief Converts documents in legacy encodings the reader does not decode itself (its built-in ones:
	/// UTF-8, UTF-16, UTF-32, ISO-8859-1 to -16, US-ASCII, Windows-874 and 1250 to 1258, KOI8-R and -U,
	/// IBM866, Macintosh). Called with the declared name of any other encoding; null: such a document is
	/// an UnsupportedEncoding error. Only viewed: it must outlive the read.
	public XmlEncodingConverter EncodingConverter = null;
	/// @brief A document with no byte order mark and no encoding declaration must be UTF-8; set
	/// Windows1252 to read one that is not as Windows-1252 instead of rejecting it.
	public XmlEncodingFallback EncodingFallback = .None;

	/// @brief Maximum element nesting depth: 1 allows the root element only. 0 = unlimited.
	public int MaxDepth = 256;
	/// @brief Maximum input size in bytes (before transcoding). 0 = unlimited.
	public int MaxInputBytes = 0;
	/// @brief Maximum number of elements in the document. 0 = unlimited.
	public int MaxNodes = 0;
	/// @brief Maximum number of attributes on one element, defaulted ones included. 0 = unlimited.
	public int MaxAttributesPerElement = 4096;
	/// @brief Maximum length in bytes of a name (element, attribute, entity, PI target). 0 = unlimited.
	public int MaxNameBytes = 50000;
	/// @brief Maximum length in bytes of one text, CDATA, comment, PI or attribute value after
	/// decoding. 0 = unlimited.
	public int MaxTextBytes = 10000000;
	/// @brief Maximum number of namespace declarations in scope at once. 0 = unlimited.
	public int MaxNamespaceBindings = 1024;

	/// @brief Maximum nesting of entity references inside entity replacement text. 0 = unlimited.
	public int MaxEntityDepth = 20;
	/// @brief Maximum number of bytes produced by expanding entity references, in content and in
	/// attribute values (defaulted attributes included), over the whole document. 0 = unlimited.
	public int MaxEntityExpansionBytes = 10000000;
	/// @brief Once expansion has produced this many bytes, it may produce at most
	/// MaxEntityAmplification times the input's size. 0 = the ratio applies from the start.
	public int EntityAmplificationThreshold = 1 << 20;
	/// @brief Maximum ratio of expanded bytes to input bytes past EntityAmplificationThreshold.
	/// 0 = no ratio.
	public int MaxEntityAmplification = 10;

	/// @brief Buffer size in bytes for reading a Stream. 0 = default (64 KiB); values below 16 are raised
	/// to 16. Setting it also makes XmlDocument.ReadFile stream the file through a buffer of this size
	/// instead of loading it whole.
	public int StreamBufferBytes = 0;
	/// @brief Streams only: the most bytes the reader may hold at once for one construct (a tag, a run of
	/// text, a comment, a processing instruction, CDATA section, the whole internal subset), counted from
	/// its start through what the reader looks at to find its end. Longer constructs fail with
	/// ResourceLimitExceeded whatever the buffer size: the buffer never grows past this, and
	/// StreamBufferBytes is lowered to it. Whitespace between constructs is not held. 0 = unlimited.
	public int MaxTokenBytes = 10000000;

	/// @brief The limits raised for large trusted inputs (libxml2's XML_PARSE_HUGE): depth 2048, text and
	/// tokens 1 GB, entity depth 40 and expansion 1 GB, with the namespace and attribute limits lifted.
	public static XmlReadConfig Huge
	{
		get
		{
			var config = XmlReadConfig();
			config.MaxDepth = 2048;
			config.MaxAttributesPerElement = 0;
			config.MaxNameBytes = 10000000;
			config.MaxTextBytes = 1000000000;
			config.MaxNamespaceBindings = 0;
			config.MaxEntityDepth = 40;
			config.MaxEntityExpansionBytes = 1000000000;
			config.MaxTokenBytes = 1000000000;
			return config;
		}
	}
}
