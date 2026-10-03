using System;
using FormatCore;
using internal FormatCore;
using internal XmlBeef;

namespace XmlBeef;

/// Character classification for the XML reader and writers: XML's grammar classes (names, `Char`,
/// whitespace, PubidChar). UTF-8, SWAR and hex helpers are FormatCore's (`Utf8`, `Swar`, `Hex`); XML's
/// character rules for validation and line counting are `XmlText`.
///
/// The reader sees only UTF-8 that `FindInvalid` has checked (transcoded first when the document is in
/// another encoding), so its scanners look only for their own stop bytes: every code point outside
/// XML's `Char` production has been rejected before.
internal static class XmlChar
{
	/// Byte classes for name scanning: 0 ends a name, 1 is an ASCII NameStartChar (`:` `_` letters),
	/// 2 an ASCII NameChar that cannot start a name (`-` `.` digits), 3 a non-ASCII byte (decode the
	/// code point and test its ranges).
	public const uint8 cNameStop = 0;
	public const uint8 cNameStart = 1;
	public const uint8 cNameOnly = 2;
	public const uint8 cNameDecode = 3;

	static uint8[256] sNameByte = BuildNameByte();

	static uint8[256] BuildNameByte()
	{
		uint8[256] table = default;
		for (int i < 256)
		{
			char8 c = (char8)i;
			if (i >= 0x80)
				table[i] = cNameDecode;
			else if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' || c == ':')
				table[i] = cNameStart;
			else if ((c >= '0' && c <= '9') || c == '-' || c == '.')
				table[i] = cNameOnly;
		}
		return table;
	}

	/// @return The name class of byte `c` (cNameStop, cNameStart, cNameOnly or cNameDecode).
	[Inline]
	public static uint8 NameByteClass(char8 c)
	{
		return sNameByte[(uint8)c];
	}

	/// @brief Whether `cp` is a NameStartChar ([4], Fifth Edition ranges).
	public static bool IsNameStartChar(char32 cp)
	{
		uint32 c = (uint32)cp;
		if (c < 0x80)
			return sNameByte[c] == cNameStart;
		if (c < 0x300)
			return c >= 0xC0 && c != 0xD7 && c != 0xF7;
		if (c < 0x2000)
			return (c >= 0x370 && c <= 0x37D) || c >= 0x37F;
		if (c < 0x3001)
			return c == 0x200C || c == 0x200D || (c >= 0x2070 && c <= 0x218F) || (c >= 0x2C00 && c <= 0x2FEF);
		if (c <= 0xD7FF)
			return true;
		if (c < 0x10000)
			return (c >= 0xF900 && c <= 0xFDCF) || (c >= 0xFDF0 && c <= 0xFFFD);
		return c <= 0xEFFFF;
	}

	/// @brief Whether `cp` is a NameChar ([4a]).
	public static bool IsNameChar(char32 cp)
	{
		uint32 c = (uint32)cp;
		if (c < 0x80)
			return sNameByte[c] == cNameStart || sNameByte[c] == cNameOnly;
		if (IsNameStartChar(cp))
			return true;
		return c == 0xB7 || (c >= 0x300 && c <= 0x36F) || c == 0x203F || c == 0x2040;
	}

	/// @brief Whether `cp` matches `Char` ([2]): TAB, LF, CR, U+0020-D7FF, U+E000-FFFD, U+10000-10FFFF.
	public static bool IsChar(uint32 c)
	{
		if (c < 0x20)
			return c == 0x09 || c == 0x0A || c == 0x0D;
		if (c <= 0xD7FF)
			return true;
		if (c < 0xE000)
			return false;
		if (c <= 0xFFFD)
			return true;
		return c >= 0x10000 && c <= 0x10FFFF;
	}

	/// @brief Whether `c` is XML whitespace (`S`, [3]): space, tab, LF or CR.
	[Inline]
	public static bool IsSpace(char8 c)
	{
		return c == ' ' || c == '\n' || c == '\t' || c == '\r';
	}

	/// @brief Whether `c` is a PubidChar ([13]).
	public static bool IsPubidChar(char8 c)
	{
		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
			return true;
		switch (c)
		{
		case ' ', '\r', '\n', '-', '\'', '(', ')', '+', ',', '.', '/', ':', '=', '?', ';', '!', '*', '#', '@', '$', '_', '%':
			return true;
		default:
			return false;
		}
	}

	/// @brief Find the first ill-formed UTF-8 sequence or code point outside `Char` in
	/// `text[from ..< to]` (FormatCore's `Utf8.FindInvalid<XmlText>`, with XML's error kinds). A sequence
	/// cut by `to` is an error: streams pass only complete sequences until their input ends.
	/// @param text The input.
	/// @param from The first byte to check (after any BOM).
	/// @param to The end of the range.
	/// @param message Receives the error message.
	/// @param kind Receives the error kind.
	/// @param length Receives the length of the offending bytes.
	/// @return The offset of the first error, or -1.
	public static int FindInvalid(char8* text, int from, int to, String message, out XmlErrorKind kind, out int length)
	{
		int bad = Utf8.FindInvalid<XmlText>(text, from, to, message, let inputKind, out length);
		kind = XmlText.MapKind(inputKind);
		return bad;
	}

	/// @brief The 1-based line and column (in code points) of byte `offset`, counting LF, CR and CRLF
	/// as one newline each. A leading BOM takes no column; an offset on the LF of a CRLF is still on the
	/// line the CRLF ends, after its CR.
	/// @param input The document.
	/// @param offset A byte offset into it.
	/// @param line Receives the line.
	/// @param column Receives the column.
	public static void LineAndColumn(StringView input, int offset, out int line, out int column)
	{
		Utf8.LineAndColumn<XmlText>(input, offset, out line, out column);
	}
}
