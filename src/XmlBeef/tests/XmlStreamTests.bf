using System;
using System.Collections;
using System.IO;
using XmlBeef;
using static XmlBeef.XmlTestUtil;

namespace XmlBeef;

/// Reading from a Stream (XmlBufferedStreamCursor): the same documents, errors and positions as from
/// memory, whatever the buffer size and however the stream splits its reads.
static class XmlStreamTests
{
	/// A stream over bytes that returns at most `chunk` bytes per read, and fails once `failAt` bytes have
	/// been read (if set). (KdlBeef's TrickleStream.)
	public class TrickleStream : Stream
	{
		StringView mData;
		int mPos;
		int mChunk;
		int mFailAt;

		public this(StringView data, int chunk, int failAt = -1)
		{
			mData = data;
			mChunk = chunk;
			mFailAt = failAt;
		}

		public override int64 Position
		{
			get => mPos;
			set => mPos = (int)value;
		}
		public override int64 Length => mData.Length;
		public override bool CanRead => true;
		public override bool CanWrite => false;

		public override Result<int> TryRead(Span<uint8> data)
		{
			if (mFailAt >= 0 && mPos >= mFailAt)
				return .Err;
			int n = Math.Min(Math.Min(mChunk, data.Length), mData.Length - mPos);
			if (mFailAt >= 0)
				n = Math.Min(n, mFailAt - mPos);
			Internal.MemCpy(data.Ptr, mData.Ptr + mPos, n);
			mPos += n;
			return n;
		}

		public override Result<int> TryWrite(Span<uint8> data) => .Err;
		public override Result<void> Close() => .Ok;
	}

	/// A document with something at every kind of boundary a refill can split.
	static void BuildSample(String input)
	{
		input.Append("\xEF\xBB\xBF<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n<!-- a comment -->\r\n");
		input.Append("<!DOCTYPE svg [\r\n  <!ENTITY ns_svg \"http://www.w3.org/2000/svg\">\r\n  <!ENTITY e \"<g id='x'>é&#x1F600;</g>\">\r\n");
		input.Append("  <!ATTLIST rect fill CDATA \"none\">\r\n  <?pi in the subset?>\r\n]>\r\n");
		input.Append("<svg xmlns=\"&ns_svg;\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" viewBox=\"0 0 10 10\">\r\n");
		input.Append("  <rect x=\"1\"\r\n        y='2' width=\"&#x33;\" />&e;\r\n");
		input.Append("  <text>a &amp; b &lt; c — ünï \u{10000}</text><![CDATA[x < y]]>\r\n");
		input.Append("  <path d=\"");
		for (int i < 200)
			input.AppendF("M{} {} ", i, i * 2);
		input.Append("\"/>\r\n  <use xlink:href=\"#x\"/><?target data?>\r\n</svg>\r\n<!-- after -->");
	}

	static void AssertSameAsMemory(StringView input, int chunk, int buffer, int line = Compiler.CallerLineNum)
	{
		let expected = scope XmlDocument();
		if (expected.Read(input) case .Err(let sampleError))
			Test.FatalError(scope $"line {line}: the sample itself is rejected: {sampleError}");
		let expectedText = XmlCanonical.WriteSuiteForm(expected, .. scope .());

		var config = XmlReadConfig();
		config.StreamBufferBytes = buffer;
		let doc = scope XmlDocument();
		let stream = scope TrickleStream(input, chunk);
		switch (doc.Read(stream, config))
		{
		case .Ok:
			let text = XmlCanonical.WriteSuiteForm(doc, .. scope .());
			if (text != expectedText)
				Test.FatalError(scope $"line {line}: chunk {chunk}, buffer {buffer}: `{text}`, expected `{expectedText}`");
		case .Err(let error):
			Test.FatalError(scope $"line {line}: chunk {chunk}, buffer {buffer}: rejected: {error}");
		}
	}

	[Test]
	public static void Stream_SameAsMemory()
	{
		let input = scope String();
		BuildSample(input);
		for (let chunk in int[](1, 2, 3, 7, 64, 4096))
		{
			for (let buffer in int[](16, 17, 31, 100, 0))
				AssertSameAsMemory(input, chunk, buffer);
		}
	}

	[Test]
	public static void Stream_Encodings()
	{
		let text = scope String();
		BuildSample(text);
		// UTF-16 in both byte orders, through every split of the code units and surrogate pairs
		let body = scope String(text.Substring(3));
		body.Replace("encoding=\"UTF-8\"", "encoding=\"UTF-16\"");
		for (let bigEndian in bool[](false, true))
		{
			let bytes = scope List<uint8>();
			Utf16(body, bigEndian, true, bytes);
			for (let chunk in int[](1, 3, 5, 4096))
				AssertSameAsMemory(Bytes(bytes), chunk, 16);
		}
		// A table encoding
		let latin = "<?xml version=\"1.0\" encoding=\"windows-1251\"?><a b=\"\xCF\xF0\">\xE8\xE2\xE5\xF2</a>";
		for (let chunk in int[](1, 2, 4096))
			AssertSameAsMemory(latin, chunk, 16);
		// The fallback reads the whole stream first
		var config = XmlReadConfig();
		config.EncodingFallback = .Windows1252;
		config.StreamBufferBytes = 16;
		let doc = scope XmlDocument();
		Test.Assert(doc.Read(scope TrickleStream("<a>caf\xE9</a>", 2), config) case .Ok);
		Test.Assert(doc.Root.Text == "café" && doc.Encoding == .Windows1252);
	}

	/// The line and column of byte `offset`, counted one byte at a time: LF, CR and CRLF end a line,
	/// and every byte but a UTF-8 continuation byte is a column.
	static void ReferencePosition(StringView text, int offset, out int line, out int column)
	{
		line = 1;
		column = 1;
		for (int i < offset)
		{
			char8 c = text[i];
			if (c == '\n' || (c == '\r' && (i + 1 >= text.Length || text[i + 1] != '\n')))
			{
				line++;
				column = 1;
			}
			else if (c != '\r' && ((uint8)c & 0xC0) != 0x80)
				column++;
		}
	}

	/// Positions are counted a word at a time (XmlLineCounter): the same as one byte at a time, whatever
	/// mix of multi-byte characters and line ends the words split, from memory and from streams.
	[Test]
	public static void Stream_PositionsCountedByWords()
	{
		let random = scope Random(7);
		let pieces = scope StringView[]("a", "bcdefgh", "é", "中", "\u{10000}", "\r\n", "\r", "\n", "  ", "<b/>", "<c>x</c>");
		for (int round < 300)
		{
			let input = scope String("<r>");
			for (int i < random.Next(40))
				input.Append(pieces[random.Next(pieces.Count)]);
			// An error located at its offset, or the unclosed element, located at its start tag
			bool unclosed = random.Next(2) == 0;
			input.Append(unclosed ? "<open>" : "&bad;");
			for (int i < random.Next(20))
				input.Append(pieces[random.Next(pieces.Count)]);
			if (!unclosed)
				input.Append("</r>");
			let memory = scope XmlDocument();
			XmlParseError expected = default;
			if (memory.Read(input) case .Err(let memoryError))
				expected = memoryError;
			else
				Test.FatalError(scope $"`{input}` was accepted");
			let expectedText = expected.ToString(.. scope .());
			if (!unclosed)
			{
				ReferencePosition(input, expected.mOffset, let line, let column);
				if (expected.mLine != line || expected.mColumn != column)
					Test.FatalError(scope $"`{input}`: {expected.mLine}:{expected.mColumn}, counted {line}:{column}");
			}
			else
			{
				ReferencePosition(input, input.IndexOf("<open>"), let line, let column);
				if (!expectedText.Contains(scope $"{line}:{column}"))
					Test.FatalError(scope $"`{input}`: `{expectedText}` does not name {line}:{column}");
			}
			for (let buffer in int[](16, 23, 0))
			{
				var config = XmlReadConfig();
				config.StreamBufferBytes = buffer;
				let doc = scope XmlDocument();
				switch (doc.Read(scope TrickleStream(input, 5), config))
				{
				case .Ok:
					Test.FatalError(scope $"`{input}` was accepted from a stream");
				case .Err(let error):
					let text = error.ToString(.. scope .());
					if (text != expectedText)
						Test.FatalError(scope $"`{input}`, buffer {buffer}: from a stream `{text}`, from memory `{expectedText}`");
				}
			}
		}
	}

	[Test]
	public static void Stream_ErrorsSameAsMemory()
	{
		let cases = scope String[](
			"<a>\n  <b></c></a>",
			"<a>\n\n  <b>",
			"<!DOCTYPE a [<!ENTITY e \"<b>\">]>\n<a>&e;</a>",
			"<a x=\"1\" x=\"2\"/>",
			"<a>\r\n<!-- -- --></a>",
			"<a><![CDATA[x]]></a><b/>");
		for (let input in cases)
		{
			let memory = scope XmlDocument();
			XmlParseError expected = default;
			if (memory.Read(input) case .Err(let memoryError))
				expected = memoryError;
			let expectedText = expected.ToString(.. scope .());
			for (let chunk in int[](1, 3))
			{
				var config = XmlReadConfig();
				config.StreamBufferBytes = 16;
				let doc = scope XmlDocument();
				switch (doc.Read(scope TrickleStream(input, chunk), config))
				{
				case .Ok:
					Test.FatalError(scope $"`{input}` was accepted from a stream");
				case .Err(let error):
					let text = error.ToString(.. scope .());
					if (text != expectedText || error.mOffset != expected.mOffset)
						Test.FatalError(scope $"`{input}`: from a stream `{text}` at {error.mOffset}, from memory `{expectedText}` at {expected.mOffset}");
				}
			}
		}
	}

	[Test]
	public static void Stream_Limits()
	{
		// A construct longer than MaxTokenBytes, whatever the buffer
		var config = XmlReadConfig();
		config.MaxTokenBytes = 64;
		config.StreamBufferBytes = 16;
		let input = scope String("<a>");
		input.Append('x', 100);
		input.Append("</a>");
		let doc = scope XmlDocument();
		switch (doc.Read(scope TrickleStream(input, 7), config))
		{
		case .Ok:
			Test.FatalError("Expected MaxTokenBytes");
		case .Err(let error):
			Test.Assert(error.mKind == .ResourceLimitExceeded);
		}
		// Whitespace between constructs is not held, so long indentation is fine
		let spaced = scope String("<a>");
		for (int i < 20)
		{
			spaced.Append(' ', 50);
			spaced.Append("<b/>");
		}
		spaced.Append("</a>");
		var spacedConfig = config;
		spacedConfig.MaxTokenBytes = 0;
		Test.Assert(doc.Read(scope TrickleStream(spaced, 5), spacedConfig) case .Ok);
		// MaxInputBytes counts what was read
		var small = XmlReadConfig();
		small.MaxInputBytes = 10;
		small.StreamBufferBytes = 16;
		switch (doc.Read(scope TrickleStream("<a>0123456789</a>", 4), small))
		{
		case .Ok:
			Test.FatalError("Expected MaxInputBytes");
		case .Err(let error):
			Test.Assert(error.mKind == .ResourceLimitExceeded);
		}
	}

	[Test]
	public static void Stream_IoError()
	{
		var config = XmlReadConfig();
		config.StreamBufferBytes = 16;
		let doc = scope XmlDocument();
		switch (doc.Read(scope TrickleStream("<a><b>text</b><c/></a>", 3, 12), config))
		{
		case .Ok:
			Test.FatalError("Expected an I/O error");
		case .Err(let error):
			Test.Assert(error.mKind == .IoError);
		}
	}

	[Test]
	public static void Stream_Reader()
	{
		// The reader over a stream: views valid for the event, across refills
		let input = "<root a=\"first value\" b=\"second value\"><?pi some data here?>text&amp;more</root>";
		var config = XmlReadConfig();
		config.StreamBufferBytes = 16;
		let reader = scope XmlReader();
		reader.Reset(scope TrickleStream(input, 3), config);
		Expect(reader, .StartElement);
		Test.Assert(reader.AttributeValue(0) == "first value" && reader.AttributeValue(1) == "second value");
		Expect(reader, .ProcessingInstruction);
		Test.Assert(reader.Name == "pi" && reader.Value == "some data here");
		Expect(reader, .Text);
		Test.Assert(reader.Value == "text&more");
		Expect(reader, .EndElement);
		Expect(reader, .EndOfDocument);
	}

	[Test]
	public static void Stream_ReadFile()
	{
		let path = scope String();
		Path.GetTempFileName(path);
		defer File.Delete(path);
		let input = scope String();
		BuildSample(input);
		File.WriteAllText(path, input);
		let memory = scope XmlDocument();
		Test.Assert(memory.Read(input) case .Ok);
		var config = XmlReadConfig();
		config.StreamBufferBytes = 32;
		let doc = scope XmlDocument();
		Test.Assert(doc.ReadFile(path, config) case .Ok);
		Test.Assert(XmlCanonical.WriteSuiteForm(doc, .. scope .()) == XmlCanonical.WriteSuiteForm(memory, .. scope .()));
	}
}
