using System;
using System.Collections;
using XmlBeef;
using static XmlBeef.XmlTestUtil;

namespace XmlBeef;

/// The Positions sidecar and the resource limits not covered elsewhere.
static class XmlPositionsTests
{
	static void AssertRange(XmlSourceRange range, int line, int column, int offset, int length, int sourceLine = Compiler.CallerLineNum)
	{
		if (range.mLine != line || range.mColumn != column || range.mOffset != offset || range.mLength != length)
			Test.FatalError(scope $"line {sourceLine}: {range.mLine}:{range.mColumn} @{range.mOffset}+{range.mLength}, expected {line}:{column} @{offset}+{length}");
	}

	[Test]
	public static void Positions_NodesAndAttributes()
	{
		let input = "<?xml version=\"1.0\"?>\n<!DOCTYPE r [<!ATTLIST e d CDATA 'x'>]>\n<r>\n  <e a=\"1\"\n     b='two'/>text<!--c-->\n  <é/></r>";
		var config = XmlReadConfig();
		config.MetadataMode = .Positions;
		config.SourceName = "doc.xml";
		let doc = scope XmlDocument();
		Test.Assert(doc.Read(input, config) case .Ok);
		let root = doc.Root;
		Test.Assert(root.TryGetSourceRange(let rootRange));
		AssertRange(rootRange, 3, 1, 62, input.Length - 62);
		Test.Assert(rootRange.ToString(.. scope .()) == "doc.xml:3:1");
		let e = root.Find("e");
		Test.Assert(e.TryGetSourceRange(let eRange));
		AssertRange(eRange, 4, 3, 68, 23);
		Test.Assert(e.Attributes[0].TryGetSourceRange(let a));
		AssertRange(a, 4, 6, 71, 5);
		Test.Assert(e.Attributes[1].TryGetSourceRange(let b));
		AssertRange(b, 5, 6, 82, 7);
		// A defaulted attribute has no position
		Test.Assert(e.Attributes[2].Name == "d" && !e.Attributes[2].TryGetSourceRange(let d));
		let text = e.NextSibling;
		Test.Assert(text.Kind == .Text);
		Test.Assert(text.TryGetSourceRange(let textRange));
		AssertRange(textRange, 5, 15, 91, 4);
		Test.Assert(text.NextSibling.TryGetSourceRange(let comment));
		AssertRange(comment, 5, 19, 95, 8);
		// Columns count code points
		Test.Assert(root.Find("é").TryGetSourceRange(let accented));
		AssertRange(accented, 6, 3, 106, 5);
		Test.Assert(doc.DocType.TryGetSourceRange(let docType));
		AssertRange(docType, 2, 1, 22, 39);
		// Without Positions, nothing is recorded
		let plain = scope XmlDocument();
		Test.Assert(plain.Read(input) case .Ok);
		Test.Assert(!plain.Root.TryGetSourceRange(let none));
	}

	[Test]
	public static void Positions_FromAStream()
	{
		let input = "<r>\r\n  <a x=\"1\">t</a>\r\n  <b/>\r\n</r>";
		var config = XmlReadConfig();
		config.MetadataMode = .Positions;
		config.StreamBufferBytes = 16;
		let doc = scope XmlDocument();
		Test.Assert(doc.Read(scope XmlStreamTests.TrickleStream(input, 3), config) case .Ok);
		Test.Assert(doc.Root.Find("b").TryGetSourceRange(let b));
		AssertRange(b, 3, 3, 25, 4);
		Test.Assert(doc.Root.Find("a").Attributes[0].TryGetSourceRange(let x));
		AssertRange(x, 2, 6, 10, 5);
		// The same from memory
		config.StreamBufferBytes = 0;
		let memory = scope XmlDocument();
		Test.Assert(memory.Read(input, config) case .Ok);
		Test.Assert(memory.Root.Find("b").TryGetSourceRange(let mb));
		AssertRange(mb, 3, 3, 25, 4);
	}

	[Test]
	public static void Positions_InsideEntitiesAreTheReference()
	{
		var config = XmlReadConfig();
		config.MetadataMode = .Positions;
		let doc = scope XmlDocument();
		Test.Assert(doc.Read("<!DOCTYPE r [<!ENTITY e \"<b>x</b>\">]>\n<r>&e;</r>", config) case .Ok);
		Test.Assert(doc.Root.Find("b").TryGetSourceRange(let b));
		AssertRange(b, 2, 4, 41, 3);
	}

	[Test]
	public static void Limits_NamespaceBindings()
	{
		var config = XmlReadConfig();
		config.MaxNamespaceBindings = 3;
		RejectsWith("<a xmlns:p1=\"u1\" xmlns:p2=\"u2\"><b xmlns:p3=\"u3\" xmlns:p4=\"u4\"/></a>", .ResourceLimitExceeded, config);
		// Bindings go out of scope with their element
		let input = scope String("<a>");
		for (int i < 10)
			input.AppendF("<b xmlns:p{0}=\"u{0}\" xmlns:q{0}=\"v{0}\"/>", i);
		input.Append("</a>");
		let reader = scope XmlReader(input, config);
		let output = scope String();
		Test.Assert(XmlCanonical.WriteSuiteForm(reader, output) case .Ok);
	}

	[Test]
	public static void Limits_AmplificationThreshold()
	{
		// 2,000 references to a 1,000-byte entity: 2 MB from 10 KB of input
		let input = scope String("<!DOCTYPE r [<!ENTITY e \"");
		input.Append('x', 1000);
		input.Append("\">]><r>");
		for (int i < 2000)
			input.Append("&e;");
		input.Append("</r>");
		Rejects(input, .ResourceLimitExceeded);
		// Within the threshold the ratio does not apply
		var config = XmlReadConfig();
		config.EntityAmplificationThreshold = 4 << 20;
		let reader = scope XmlReader(input, config);
		let output = scope String();
		Test.Assert(XmlCanonical.WriteSuiteForm(reader, output) case .Ok);
		// MaxEntityExpansionBytes applies whatever the ratio
		config.MaxEntityExpansionBytes = 1 << 20;
		RejectsWith(input, .ResourceLimitExceeded, config);
	}

	[Test]
	public static void Limits_HugePreset()
	{
		let deep = scope String();
		for (int i < 1000)
			deep.Append("<a>");
		for (int i < 1000)
			deep.Append("</a>");
		Rejects(deep, .ResourceLimitExceeded);
		let reader = scope XmlReader(deep, XmlReadConfig.Huge);
		let output = scope String();
		Test.Assert(XmlCanonical.WriteSuiteForm(reader, output) case .Ok);
	}
}
