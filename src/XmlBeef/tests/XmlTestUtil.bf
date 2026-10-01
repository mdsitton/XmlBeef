using System;
using System.Collections;
using XmlBeef;

namespace XmlBeef;

/// Helpers shared by the tests: canonical form through the reader, expected errors, and encoded input.
static class XmlTestUtil
{
	/// The input must be well-formed and its suite canonical form (XmlCanonical.WriteSuiteForm) `expected`.
	public static void Accepts(StringView input, StringView expected, bool namespaces = true, int line = Compiler.CallerLineNum)
	{
		var config = XmlReadConfig();
		config.Namespaces = namespaces;
		let reader = scope XmlReader(input, config);
		let output = scope String();
		switch (XmlCanonical.WriteSuiteForm(reader, output))
		{
		case .Ok:
			if (output != expected)
				Test.FatalError(scope $"line {line}: canonical form of `{input}`: got `{output}`, expected `{expected}`");
		case .Err(let error):
			Test.FatalError(scope $"line {line}: `{input}` was rejected: {error}");
		}
	}

	/// The input must be rejected with an error of `kind`.
	public static void Rejects(StringView input, XmlErrorKind kind, bool namespaces = true, int line = Compiler.CallerLineNum)
	{
		var config = XmlReadConfig();
		config.Namespaces = namespaces;
		RejectsWith(input, kind, config, line);
	}

	/// The input must be rejected with an error of `kind` when read with `config`.
	public static void RejectsWith(StringView input, XmlErrorKind kind, XmlReadConfig config, int line = Compiler.CallerLineNum)
	{
		let reader = scope XmlReader(input, config);
		let output = scope String();
		switch (XmlCanonical.WriteSuiteForm(reader, output))
		{
		case .Ok:
			Test.FatalError(scope $"line {line}: `{input}` was accepted as `{output}`, expected {kind}");
		case .Err(let error):
			if (error.mKind != kind)
				Test.FatalError(scope $"line {line}: `{input}`: expected {kind}, got {error.mKind}: {error}");
		}
	}

	/// The input must be rejected, whatever the error.
	public static void RejectsAny(StringView input, bool namespaces = true, int line = Compiler.CallerLineNum)
	{
		var config = XmlReadConfig();
		config.Namespaces = namespaces;
		let reader = scope XmlReader(input, config);
		let output = scope String();
		if (XmlCanonical.WriteSuiteForm(reader, output) case .Ok)
			Test.FatalError(scope $"line {line}: `{input}` was accepted as `{output}`");
	}

	/// The next event must be `expected`.
	public static void Expect(XmlReader reader, XmlEvent expected, int line = Compiler.CallerLineNum)
	{
		switch (reader.Next())
		{
		case .Ok(let event):
			if (event != expected)
				Test.FatalError(scope $"line {line}: expected {expected}, got {event}");
		case .Err(let error):
			Test.FatalError(scope $"line {line}: expected {expected}, got error {error}");
		}
	}

	/// Appends `text` encoded as UTF-16, with or without a byte order mark.
	public static void Utf16(StringView text, bool bigEndian, bool bom, List<uint8> output)
	{
		if (bom)
			AddUnit(0xFEFF, bigEndian, output);
		for (let cp in text.DecodedChars)
		{
			uint32 c = (uint32)cp;
			if (c >= 0x10000)
			{
				c -= 0x10000;
				AddUnit(0xD800 + (c >> 10), bigEndian, output);
				AddUnit(0xDC00 + (c & 0x3FF), bigEndian, output);
			}
			else
				AddUnit(c, bigEndian, output);
		}
	}

	static void AddUnit(uint32 unit, bool bigEndian, List<uint8> output)
	{
		if (bigEndian)
		{
			output.Add((uint8)(unit >> 8));
			output.Add((uint8)unit);
		}
		else
		{
			output.Add((uint8)unit);
			output.Add((uint8)(unit >> 8));
		}
	}

	/// A view of bytes as reader input.
	public static StringView Bytes(List<uint8> bytes)
	{
		return StringView((char8*)bytes.Ptr, bytes.Count);
	}
}
