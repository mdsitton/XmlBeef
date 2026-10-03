using System;
using FormatCore;
using internal FormatCore;

namespace XmlBeef;

/// XML's character rules for FormatCore's validator, cursors and line counting (`ITextPolicy`): the
/// input must be `Char`s ([2]: tab, LF, CR, U+0020-D7FF, U+E000-FFFD, U+10000-10FFFF), checked before
/// the reader sees it; LF, CR and CRLF are the newlines.
internal struct XmlText : ITextPolicy
{
	public static bool ValidatesUpFront
	{
		[Inline]
		get => true;
	}

	/// ASCII other than the control characters, tab, LF and CR excepted. Every test is exact per byte:
	/// once the high bits are known to be clear, adding to a byte cannot carry into the next one.
	[Inline]
	public static bool IsPlainWord(uint64 word)
	{
		if ((word & Swar.High) != 0)
			return false;
		// High bit set for bytes >= 0x20
		uint64 printable = (word + 0x60 * Swar.Ones) & Swar.High;
		if (printable == Swar.High)
			return true;
		uint64 control = ~printable & Swar.High;
		uint64 allowed = Swar.BytesEqual(word, 0x09) | Swar.BytesEqual(word, 0x0A) | Swar.BytesEqual(word, 0x0D);
		return (control & ~allowed) == 0;
	}

	/// 32 bytes at once: all ASCII, then all at least 0x20; only a block with a control character checks
	/// which (lines of text hold an LF every few dozen bytes).
	[Inline]
	public static bool IsPlainBlock(uint64 a, uint64 b, uint64 c, uint64 d)
	{
		const uint64 add = 0x6060606060606060UL;
		if (((a | b | c | d) & Swar.High) != 0)
			return false;
		if (((a + add) & (b + add) & (c + add) & (d + add) & Swar.High) == Swar.High)
			return true;
		return (BadControls(a) | BadControls(b) | BadControls(c) | BadControls(d)) == 0;
	}

	/// The high bit of each byte of an ASCII word that is a control character other than tab, LF and CR.
	[Inline]
	static uint64 BadControls(uint64 word)
	{
		return Swar.BytesBelowSpace(word) & ~(Swar.BytesEqual(word, 0x09) | Swar.BytesEqual(word, 0x0A) | Swar.BytesEqual(word, 0x0D));
	}

	[Inline]
	public static bool AllowsAscii(uint8 b) => b >= 0x20 || b == 0x09 || b == 0x0A || b == 0x0D;

	public static bool BansCodePoints
	{
		[Inline]
		get => true;
	}

	/// Well-formed UTF-8 excludes surrogates and code points above U+10FFFF already: only U+FFFE and
	/// U+FFFF remain outside `Char`.
	[Inline]
	public static bool AllowsCodePoint(uint32 cp) => cp != 0xFFFE && cp != 0xFFFF;

	public static void AppendBanned(String message, uint32 cp)
	{
		message.Append("The code point ");
		Hex.AppendCodePointName(message, cp);
		message.Append(" is not allowed in XML (it is not a `Char`)");
	}

	[Inline]
	public static int NewlineLength(char8* text, int pos, int end) => Utf8.AsciiNewlineLength(text, pos, end);

	[Inline]
	public static uint64 MayHoldNewline(uint64 word) => Swar.BytesBelow0E(word);

	public static bool OnlyAsciiNewlines
	{
		[Inline]
		get => true;
	}

	/// @brief The XML error kind of an input error.
	/// @param kind The cursor's kind.
	/// @return XmlBeef's kind.
	public static XmlErrorKind MapKind(InputErrorKind kind)
	{
		switch (kind)
		{
		case .InvalidUtf8, .InvalidEncoding: return .InvalidEncoding;
		case .InvalidChar: return .InvalidChar;
		case .UnsupportedEncoding, .ByteOrderMark: return .UnsupportedEncoding;
		case .ResourceLimitExceeded: return .ResourceLimitExceeded;
		case .IoError: return .IoError;
		}
	}
}
