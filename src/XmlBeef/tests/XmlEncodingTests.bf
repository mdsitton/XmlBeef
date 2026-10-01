using System;
using System.Collections;
using XmlBeef;
using static XmlBeef.XmlTestUtil;

namespace XmlBeef;

/// Declared single-byte encodings, the converter hook and the Windows-1252 fallback (plan.md §9 item 7).
static class XmlEncodingTests
{
	static void AcceptsAs(StringView input, StringView expected, XmlEncoding encoding, XmlReadConfig config = .(), int line = Compiler.CallerLineNum)
	{
		let reader = scope XmlReader(input, config);
		let output = scope String();
		switch (XmlCanonical.WriteSuiteForm(reader, output))
		{
		case .Ok:
			if (output != expected)
				Test.FatalError(scope $"line {line}: got `{output}`, expected `{expected}`");
			if (reader.DocumentEncoding != encoding)
				Test.FatalError(scope $"line {line}: read as {reader.DocumentEncoding}, expected {encoding}");
		case .Err(let error):
			Test.FatalError(scope $"line {line}: rejected: {error}");
		}
	}

	[Test]
	public static void Tables_Decode()
	{
		AcceptsAs("<?xml version=\"1.0\" encoding=\"windows-1251\"?><a>\xCF\xF0\xE8\xE2\xE5\xF2</a>", "<a>Привет</a>", .Windows1251);
		AcceptsAs("<?xml version='1.0' encoding='CP1251'?><a>\xFF</a>", "<a>я</a>", .Windows1251);
		AcceptsAs("<?xml version=\"1.0\" encoding=\"windows-1252\"?><a b=\"\x80\">\x93q\x94</a>", "<a b=\"€\">“q”</a>", .Windows1252);
		AcceptsAs("<?xml version=\"1.0\" encoding=\"koi8-r\"?><a>\xF0\xD2\xC9\xD7\xC5\xD4</a>", "<a>Привет</a>", .Koi8R);
		AcceptsAs("<?xml version=\"1.0\" encoding=\"ISO-8859-15\"?><a>\xA4</a>", "<a>€</a>", .Iso8859_15);
		AcceptsAs("<?xml version=\"1.0\" encoding=\"ISO-8859-2\"?><a>\xB1</a>", "<a>ą</a>", .Iso8859_2);
		AcceptsAs("<?xml version=\"1.0\" encoding=\"macintosh\"?><a>\x80</a>", "<a>Ä</a>", .Macintosh);
		// Names in the encoding too
		AcceptsAs("<?xml version=\"1.0\" encoding=\"windows-1251\"?><\xEC\xE8\xF0/>", "<мир></мир>", .Windows1251);
	}

	[Test]
	public static void Tables_ExactIsoStandards()
	{
		// ISO-8859-9 and -11 have C1 controls at 0x80-0x9F (WHATWG reads them as windows-1254 and -874)
		AcceptsAs("<?xml version=\"1.0\" encoding=\"ISO-8859-9\"?><a>\xD0\x85</a>", "<a>Ğ\u{85}</a>", .Iso8859_9);
		AcceptsAs("<?xml version=\"1.0\" encoding=\"windows-1254\"?><a>\xD0\x85</a>", "<a>Ğ…</a>", .Windows1254);
		AcceptsAs("<?xml version=\"1.0\" encoding=\"TIS-620\"?><a>\xA1</a>", "<a>ก</a>", .Iso8859_11);
		// ISO-8859-1 is Latin-1 (C1 at 0x80), not windows-1252 (€ at 0x80)
		AcceptsAs("<?xml version=\"1.0\" encoding=\"latin1\"?><a>\x80\xE9</a>", "<a>\u{80}é</a>", .Latin1);
	}

	[Test]
	public static void Tables_UndefinedByte()
	{
		// 0xAA is not defined in windows-1253
		Rejects("<?xml version=\"1.0\" encoding=\"windows-1253\"?><a>\xAA</a>", .InvalidEncoding);
	}

	[Test]
	public static void Bom_WinsOverEightBitDeclaration()
	{
		let input = "\xEF\xBB\xBF<?xml version=\"1.0\" encoding=\"windows-1251\"?><a>\xD0\xBC</a>";
		AcceptsAs(input, "<a>м</a>", .Utf8);
		// With a warning, from memory and from a stream
		let doc = scope XmlDocument();
		Test.Assert(doc.Read(input) case .Ok);
		Test.Assert(doc.EncodingWarning.Contains("byte order mark"));
		var config = XmlReadConfig();
		config.StreamBufferBytes = 16;
		Test.Assert(doc.Read(scope XmlStreamTests.TrickleStream(input, 5), config) case .Ok);
		Test.Assert(doc.EncodingWarning.Contains("byte order mark"));
		Test.Assert(doc.Read("\xEF\xBB\xBF<?xml version=\"1.0\" encoding=\"UTF-8\"?><a/>") case .Ok);
		Test.Assert(doc.EncodingWarning.IsEmpty);
	}

	[Test]
	public static void Converter_Hook()
	{
		// A toy converter for one name: the bytes are copied as they are
		var config = XmlReadConfig();
		config.EncodingConverter = scope (name, input, output) =>
			{
				if (!name.Equals("x-shifted", true))
					return false;
				output.Append((char8*)input.Ptr, input.Length);
				return true;
			};
		AcceptsAs("<?xml version=\"1.0\" encoding=\"x-shifted\"?><a>t</a>", "<a>t</a>", .Custom, config);
		RejectsWith("<?xml version=\"1.0\" encoding=\"x-other\"?><a/>", .UnsupportedEncoding, config);
		// The converter's output is validated like any input
		var broken = XmlReadConfig();
		broken.EncodingConverter = scope (name, input, output) =>
			{
				output.Append("<a>\x01</a>");
				return true;
			};
		RejectsWith("<?xml version=\"1.0\" encoding=\"x-any\"?><a/>", .InvalidChar, broken);
	}

	[Test]
	public static void Fallback_Windows1252()
	{
		let input = "<a>caf\xE9 \x80</a>";
		Rejects(input, .InvalidEncoding);
		var config = XmlReadConfig();
		config.EncodingFallback = .Windows1252;
		AcceptsAs(input, "<a>café €</a>", .Windows1252, config);
		// Valid UTF-8 is still read as UTF-8, and a declaration still decides
		AcceptsAs("<a>caf\xC3\xA9</a>", "<a>café</a>", .Utf8, config);
		RejectsWith("<?xml version=\"1.0\" encoding=\"UTF-8\"?><a>\xE9</a>", .InvalidEncoding, config);
	}

	[Test]
	public static void Document_ReadsAndWritesUtf8()
	{
		let doc = scope XmlDocument();
		Test.Assert(doc.Read("<?xml version=\"1.0\" encoding=\"windows-1251\"?><a>\xCF\xF0\xE8</a>") case .Ok);
		Test.Assert(doc.Encoding == .Windows1251 && doc.EncodingName == "windows-1251" && doc.Root.Text == "При");
		let output = doc.Write(.. scope String());
		Test.Assert(output == "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a>При</a>\n");
	}
}
