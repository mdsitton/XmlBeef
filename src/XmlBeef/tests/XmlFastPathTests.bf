using System;
using System.Collections;
using XmlBeef;
using internal XmlBeef;
using static XmlBeef.XmlTestUtil;

namespace XmlBeef;

/// The word-at-a-time scans and other fast paths, at every alignment: what the slow paths would read
/// must come out of the fast ones too.
static class XmlFastPathTests
{
	/// Names of 4-7 bytes that differ only in their first and last bytes hash apart (the name table's
	/// hash built them from two overlapping words ORed together: such names collided under every seed).
	[Test]
	public static void NameTable_HashUsesEveryByte()
	{
		let table = scope XmlNameTable();
		let seen = scope HashSet<uint32>();
		let name = scope String();
		for (int length = 4; length <= 7; length++)
		{
			seen.Clear();
			for (int first < 16)
			{
				for (int last < 16)
				{
					name.Clear();
					name.Append((char8)('a' + first));
					for (int i = 1; i < length - 1; i++)
						name.Append('m');
					name.Append((char8)('a' + last));
					seen.Add(table.[Friend]Hash(name.Ptr, name.Length));
				}
			}
			Test.Assert(seen.Count == 256);
		}
	}

	[Test]
	public static void Text_StopBytesAtEveryOffset()
	{
		// `<`, `&`, `]` and CR at each position of the 8-byte words after the start tag
		for (int pad < 20)
		{
			let filler = scope String()..Append('x', pad);
			Accepts(scope $"<a>{filler}<b/></a>", scope $"<a>{filler}<b></b></a>");
			Accepts(scope $"<a>{filler}&amp;y</a>", scope $"<a>{filler}&amp;y</a>");
			Accepts(scope $"<a>{filler}]x</a>", scope $"<a>{filler}]x</a>");
			Accepts(scope $"<a>{filler}\r\ny</a>", scope $"<a>{filler}&#10;y</a>");
			Rejects(scope $"<a>{filler}]]>y</a>", .InvalidCData);
		}
	}

	[Test]
	public static void Attributes_StopBytesAtEveryOffset()
	{
		for (int pad < 20)
		{
			let filler = scope String()..Append('v', pad);
			Accepts(scope $"<a b=\"{filler}\" c='{filler}'/>", scope $"<a b=\"{filler}\" c=\"{filler}\"></a>");
			Accepts(scope $"<a b=\"{filler}'x\"/>", scope $"<a b=\"{filler}'x\"></a>");
			Accepts(scope $"<a b=\"{filler}\tx\"/>", scope $"<a b=\"{filler} x\"></a>");
			Accepts(scope $"<a b=\"{filler}&lt;x\"/>", scope $"<a b=\"{filler}&lt;x\"></a>");
			Rejects(scope $"<a b=\"{filler}<x\"/>", .UnexpectedChar);
			Rejects(scope $"<a b=\"{filler}", .UnexpectedEof);
		}
	}

	[Test]
	public static void Validation_ControlsAnywhere()
	{
		// A control character at every offset of the 32-byte blocks, among tabs, LFs and CRs (allowed)
		for (int pad < 70)
		{
			let text = scope String();
			text.Append("<a>");
			for (int i < pad)
				text.Append((i % 9 == 0) ? '\n' : (i % 7 == 0) ? '\t' : 'x');
			Accepts(scope $"{text}</a>", scope String()..Append("<a>")..Append(scope String(text.Substring(3))..Replace("\n", "&#10;")..Replace("\t", "&#9;"))..Append("</a>"));
			Rejects(scope $"{text}\x01</a>", .InvalidChar);
			Rejects(scope $"{text}\x1F</a>", .InvalidChar);
			Rejects(scope $"{text}\xFF</a>", .InvalidEncoding);
			Rejects(scope $"{text}\xEF\xBF\xBE</a>", .InvalidChar);
		}
	}

	[Test]
	public static void Utf16_AsciiRunsMeetOtherCharacters()
	{
		// ASCII runs of every length, then non-ASCII, a surrogate pair, and broken surrogates
		for (int pad < 12)
		{
			let filler = scope String()..Append('a', pad);
			let le = scope List<uint8>();
			Utf16(scope $"<r>{filler}é\u{1F600}{filler}</r>", false, true, le);
			Accepts(Bytes(le), scope $"<r>{filler}é\u{1F600}{filler}</r>");
			let broken = scope List<uint8>();
			Utf16(scope $"<r>{filler}", false, true, broken);
			broken.Add(0x3D);
			broken.Add(0xD8);
			Utf16("x</r>", false, false, broken);
			Rejects(Bytes(broken), .InvalidEncoding);
			let odd = scope List<uint8>();
			Utf16(scope $"<r>{filler}</r>", false, true, odd);
			odd.Add(0x20);
			Rejects(Bytes(odd), .InvalidEncoding);
		}
	}

	[Test]
	public static void Names_CacheCollisions()
	{
		// Names with one first byte, last byte and length share a cache slot; each keeps its own ID
		let reader = scope XmlReader("<r axb=\"1\" ayb=\"2\"><axb/><ayb/><axb ayb=\"3\"/></r>");
		Expect(reader, .StartElement);
		Test.Assert(reader.AttributeName(0) == "axb" && reader.AttributeName(1) == "ayb" && reader.AttributeNameId(0) != reader.AttributeNameId(1));
		let axb = reader.AttributeNameId(0);
		let ayb = reader.AttributeNameId(1);
		Expect(reader, .StartElement);
		Test.Assert(reader.Name == "axb" && reader.NameId == axb);
		Expect(reader, .EndElement);
		Expect(reader, .StartElement);
		Test.Assert(reader.Name == "ayb" && reader.NameId == ayb);
		Expect(reader, .EndElement);
		Expect(reader, .StartElement);
		Test.Assert(reader.NameId == axb && reader.AttributeNameId(0) == ayb);
		// Duplicates are still found through the cache
		Rejects("<r axb=\"1\" ayb=\"2\" axb=\"3\"/>", .DuplicateAttribute);
	}

	[Test]
	public static void Names_LongAndNonAscii()
	{
		let long = scope String()..Append('n', 300);
		Accepts(scope $"<{long} {long}x=\"1\"/>", scope $"<{long} {long}x=\"1\"></{long}>");
		Accepts("<é a·b=\"1\" ab=\"2\"/>", "<é ab=\"2\" a·b=\"1\"></é>");
		// A non-ASCII character after an ASCII start takes the full name scan
		Accepts("<a中 b中=\"1\"/>", "<a中 b中=\"1\"></a中>");
		Rejects("<a b×=\"1\"/>", .InvalidName);
	}
}
