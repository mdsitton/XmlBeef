using System;
using internal XmlBeef;

namespace XmlBeef;

/// @brief The encoding a document was read in.
public enum XmlEncoding : uint8
{
	/// @brief UTF-8, with or without a byte order mark (read as is, no transcoding).
	Utf8,
	/// @brief UTF-16, little-endian.
	Utf16LE,
	/// @brief UTF-16, big-endian.
	Utf16BE,
	/// @brief UTF-32 (UCS-4), little-endian.
	Utf32LE,
	/// @brief UTF-32 (UCS-4), big-endian.
	Utf32BE,
	/// @brief ISO-8859-1 (Latin-1).
	Latin1,
	/// @brief US-ASCII.
	Ascii,
	/// @brief A legacy encoding converted by XmlReadConfig.EncodingConverter.
	Custom,
	// Single-byte encodings, decoded through tables (XmlEncodingTables.bf, generated from the WHATWG
	// Encoding Standard's indexes by tools/gen-encoding-tables.py)
	/// @brief IBM866 (DOS Cyrillic).
	Ibm866,
	/// @brief ISO-8859-2 (Latin-2, Central European).
	Iso8859_2,
	/// @brief ISO-8859-3 (Latin-3, South European).
	Iso8859_3,
	/// @brief ISO-8859-4 (Latin-4, North European).
	Iso8859_4,
	/// @brief ISO-8859-5 (Cyrillic).
	Iso8859_5,
	/// @brief ISO-8859-6 (Arabic).
	Iso8859_6,
	/// @brief ISO-8859-7 (Greek).
	Iso8859_7,
	/// @brief ISO-8859-8 (Hebrew; also ISO-8859-8-I).
	Iso8859_8,
	/// @brief ISO-8859-9 (Latin-5, Turkish).
	Iso8859_9,
	/// @brief ISO-8859-10 (Latin-6, Nordic).
	Iso8859_10,
	/// @brief ISO-8859-11 (Thai; also TIS-620).
	Iso8859_11,
	/// @brief ISO-8859-13 (Latin-7, Baltic).
	Iso8859_13,
	/// @brief ISO-8859-14 (Latin-8, Celtic).
	Iso8859_14,
	/// @brief ISO-8859-15 (Latin-9).
	Iso8859_15,
	/// @brief ISO-8859-16 (Latin-10, South-Eastern European).
	Iso8859_16,
	/// @brief KOI8-R (Russian).
	Koi8R,
	/// @brief KOI8-U (Ukrainian).
	Koi8U,
	/// @brief Mac OS Roman (`macintosh`).
	Macintosh,
	/// @brief Mac OS Cyrillic (`x-mac-cyrillic`).
	MacCyrillic,
	/// @brief Windows-874 (Thai).
	Windows874,
	/// @brief Windows-1250 (Central European).
	Windows1250,
	/// @brief Windows-1251 (Cyrillic).
	Windows1251,
	/// @brief Windows-1252 (Western European).
	Windows1252,
	/// @brief Windows-1253 (Greek).
	Windows1253,
	/// @brief Windows-1254 (Turkish).
	Windows1254,
	/// @brief Windows-1255 (Hebrew).
	Windows1255,
	/// @brief Windows-1256 (Arabic).
	Windows1256,
	/// @brief Windows-1257 (Baltic).
	Windows1257,
	/// @brief Windows-1258 (Vietnamese).
	Windows1258
}

/// @brief What to do with a document that has no byte order mark and no encoding declaration but is not
/// valid UTF-8 (which the XML specification makes a fatal error).
public enum XmlEncodingFallback : uint8
{
	/// @brief Report it: an encoding error (the specification's rule).
	None,
	/// @brief Read it as Windows-1252, a superset of Latin-1's printable range: how hand-edited files in
	/// the wild usually turn out to be encoded (the author's StrikeCore heuristic).
	Windows1252
}

/// @brief Converts a document in a legacy encoding the reader does not decode itself (Shift_JIS, EUC-JP,
/// GBK, Big5, EUC-KR, …) to UTF-8: see XmlReadConfig.EncodingConverter.
/// @param encodingName The name in the document's encoding declaration, as written.
/// @param input The document's bytes.
/// @param output Receives the document as UTF-8.
/// @return Whether the encoding was converted; false makes it an UnsupportedEncoding error.
public delegate bool XmlEncodingConverter(StringView encodingName, Span<uint8> input, String output);
