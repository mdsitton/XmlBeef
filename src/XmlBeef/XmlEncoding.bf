using System;
using FormatCore;

namespace XmlBeef;

/// @brief The encoding a document was read in: FormatCore's `TextEncoding` (UTF-8, UTF-16LE/BE,
/// UTF-32LE/BE, Latin-1, US-ASCII, `Custom` for XmlReadConfig.EncodingConverter, and the WHATWG
/// single-byte encodings decoded through tables: IBM866, ISO-8859-2 to -16, KOI8-R/U, macintosh,
/// x-mac-cyrillic, windows-874 and windows-1250 to -1258).
public typealias XmlEncoding = FormatCore.TextEncoding;

/// @brief What to do with a document that has no byte order mark and no encoding declaration but is not
/// valid UTF-8 (which the XML specification makes a fatal error): FormatCore's `EncodingFallback`
/// (`None`: report it; `Windows1252`: read it as Windows-1252, the author's StrikeCore heuristic).
public typealias XmlEncodingFallback = FormatCore.EncodingFallback;

/// @brief Converts a document in a legacy encoding the reader does not decode itself (Shift_JIS, EUC-JP,
/// GBK, Big5, EUC-KR, …) to UTF-8: see XmlReadConfig.EncodingConverter. FormatCore's
/// `EncodingConverter(StringView encodingName, Span<uint8> input, String output)`: the name as the
/// declaration writes it, the document's bytes, the UTF-8 output; false makes it an UnsupportedEncoding
/// error.
public typealias XmlEncodingConverter = FormatCore.EncodingConverter;
