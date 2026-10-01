using System;
using System.Collections;
using XmlBeef;

namespace XmlBeef;

/// PreserveStyle: unchanged documents write back byte for byte; edits regenerate only what changed
/// (plan.md §4.9).
static class XmlPreserveTests
{
	static XmlReadConfig Preserve()
	{
		var config = XmlReadConfig();
		config.MetadataMode = .PreserveStyle;
		return config;
	}

	static XmlDocument ReadPreserved(XmlDocument doc, StringView input, int line = Compiler.CallerLineNum)
	{
		if (doc.Read(input, Preserve()) case .Err(let error))
			Test.FatalError(scope $"line {line}: rejected: {error}");
		return doc;
	}

	static void AssertWritten(XmlDocument doc, StringView expected, int line = Compiler.CallerLineNum)
	{
		let output = doc.Write(.. scope String());
		if (output != expected)
			Test.FatalError(scope $"line {line}: wrote `{output}`, expected `{expected}`");
		// What was written reads back into the same document
		let again = scope XmlDocument();
		if (again.Read(output) case .Err(let error))
			Test.FatalError(scope $"line {line}: the written document was rejected: {error}");
		if (again.WriteCanonical(.. scope String()) != doc.WriteCanonical(.. scope String()))
			Test.FatalError(scope $"line {line}: the written document reads back differently");
	}

	[Test]
	public static void Unchanged_ByteForByte()
	{
		StringView[?] inputs = .(
			"<a/>",
			"\xEF\xBB\xBF<?xml version='1.0'  encoding=\"utf-8\" ?>\r\n<!-- c -->\r\n<a  x = 'v'\r\n   y=\"w\" >t&amp;&#x41;\r\n<![CDATA[ <> ]]><?p  d ?></a >\r\n\r\n<!--end-->\n",
			"<!DOCTYPE r [\n<!ENTITY e \"a<b/>c\">\n<?pi in subset?>\n]>\n<r>x&e;y<s />&e;</r>",
			"<?xml version=\"1.0\" standalone=\"yes\"?><r xmlns:p=\"urn:p\"><p:s p:t=\"&lt;\"/></r>  ",
			"<!DOCTYPE r [<!ATTLIST r d CDATA 'def'>]><r/>",
			"<r>&#13;&#10;\t</r>"
		);
		for (let input in inputs)
		{
			let doc = ReadPreserved(scope .(), input);
			let output = doc.Write(.. scope String());
			if (output != input)
				Test.FatalError(scope $"`{input}` was written as `{output}`");
		}
	}

	[Test]
	public static void Attributes_ChangedInPlace()
	{
		// A changed value keeps its quotes and place; its neighbors keep their text
		let doc = ReadPreserved(scope .(), "<a  x = 'v1'\n   y=\"2\"/>");
		doc.Root.SetAttribute("x", "a'b\"c");
		AssertWritten(doc, "<a  x = 'a&apos;b\"c'\n   y=\"2\"/>");
		// A new one is laid out like the last one read
		doc.Root.SetAttribute("z", "3");
		AssertWritten(doc, "<a  x = 'a&apos;b\"c'\n   y=\"2\"\n   z=\"3\"/>");
		// A removed one takes the space before it
		doc.Root.RemoveAttribute("x");
		AssertWritten(doc, "<a\n   y=\"2\"\n   z=\"3\"/>");
	}

	[Test]
	public static void Elements_RenamedAndFilled()
	{
		let doc = ReadPreserved(scope .(), "<r><a x='1' >t</a ><b k=\"v\" /></r>");
		let a = doc.Root.FirstChild;
		a.Rename("c");
		AssertWritten(doc, "<r><c x='1' >t</c><b k=\"v\" /></r>");
		// An empty-element tag that gets content keeps its space before `>`
		a.NextSibling.AddText("u");
		AssertWritten(doc, "<r><c x='1' >t</c><b k=\"v\" >u</b></r>");
		// New elements are generated, nested
		doc.Root.AddElement("n").AddElement("m").SetAttribute("q", "<");
		AssertWritten(doc, "<r><c x='1' >t</c><b k=\"v\" >u</b><n><m q=\"&lt;\"/></n></r>");
	}

	[Test]
	public static void Text_ChangedAlone()
	{
		let doc = ReadPreserved(scope .(), "<a>x&amp;y<!--c-->z\r\n<![CDATA[d]]></a>");
		doc.Root.FirstChild.SetValue("p<q");
		AssertWritten(doc, "<a>p&lt;q<!--c-->z\r\n<![CDATA[d]]></a>");
		doc.Root.LastChild.SetValue("e]]>f");
		AssertWritten(doc, "<a>p&lt;q<!--c-->z\r\n<![CDATA[e]]]]><![CDATA[>f]]></a>");
	}

	[Test]
	public static void Prolog_RemovedWithItsSpace()
	{
		let doc = ReadPreserved(scope .(), "<?xml version=\"1.0\"?>\n<!--c1-->\n<!--c2-->\n<r/>\n");
		doc.DocumentNode.FirstChild.Remove();
		AssertWritten(doc, "<?xml version=\"1.0\"?>\n<!--c2-->\n<r/>\n");
		// A new node outside the root goes on its own line
		doc.DocumentNode.AddComment("c3");
		AssertWritten(doc, "<?xml version=\"1.0\"?>\n<!--c2-->\n<r/>\n<!--c3-->\n");
	}

	[Test]
	public static void Moves_KeepTheMovedText()
	{
		let doc = ReadPreserved(scope .(), "<r><a x='1'/><b/></r>");
		Test.Assert(doc.Root.LastChild.MoveBefore(doc.Root.FirstChild));
		AssertWritten(doc, "<r><b/><a x='1'/></r>");
	}

	[Test]
	public static void Entities_ReferenceKeptUntilItsContentChanges()
	{
		let input = "<!DOCTYPE r [<!ENTITY e \"a<b/>c\">]><r>x&e;y<s/></r>";
		let doc = ReadPreserved(scope .(), input);
		// Changing something else keeps the reference
		doc.Root.LastChild.SetAttribute("n", "1");
		AssertWritten(doc, "<!DOCTYPE r [<!ENTITY e \"a<b/>c\">]><r>x&e;y<s n=\"1\"/></r>");
		// Changing what it produced expands it (with the text around it)
		doc.Root.FirstChild.NextSibling.SetAttribute("n", "2");
		AssertWritten(doc, "<!DOCTYPE r [<!ENTITY e \"a<b/>c\">]><r>xa<b n=\"2\"/>cy<s n=\"1\"/></r>");

		// Removing one of the nodes a reference produced expands the rest
		let doc2 = ReadPreserved(scope .(), input);
		doc2.Root.FirstChild.NextSibling.Remove();
		AssertWritten(doc2, "<!DOCTYPE r [<!ENTITY e \"a<b/>c\">]><r>xacy<s/></r>");

		// A reference that produced one element: kept while it is unchanged, also when moved
		let doc3 = ReadPreserved(scope .(), "<!DOCTYPE r [<!ENTITY e \"<b><c/></b>\">]><r><a/>&e;</r>");
		doc3.Root.LastChild.MoveBefore(doc3.Root.FirstChild);
		AssertWritten(doc3, "<!DOCTYPE r [<!ENTITY e \"<b><c/></b>\">]><r>&e;<a/></r>");
		doc3.Root.FirstChild.FirstChild.SetAttribute("k", "v");
		AssertWritten(doc3, "<!DOCTYPE r [<!ENTITY e \"<b><c/></b>\">]><r><b><c k=\"v\"/></b><a/></r>");
	}

	[Test]
	public static void Entities_InAttributeValuesKept()
	{
		let doc = ReadPreserved(scope .(), "<!DOCTYPE svg [<!ENTITY ns \"http://www.w3.org/2000/svg\">]><svg xmlns=\"&ns;\" w='1'/>");
		Test.Assert(doc.Root.NamespaceUri == "http://www.w3.org/2000/svg");
		doc.Root.SetAttribute("w", "2");
		AssertWritten(doc, "<!DOCTYPE svg [<!ENTITY ns \"http://www.w3.org/2000/svg\">]><svg xmlns=\"&ns;\" w='2'/>");
	}

	[Test]
	public static void Bytes_InTheDocumentsEncoding()
	{
		// UTF-16LE with a byte order mark, and Windows-1251, written back as read
		let utf16 = scope List<uint8>();
		utf16.Add(0xFF);
		utf16.Add(0xFE);
		for (let c in "<a>\u{416}</a>".DecodedChars)
		{
			utf16.Add((uint8)((uint32)c & 0xFF));
			utf16.Add((uint8)((uint32)c >> 8));
		}
		let doc = scope XmlDocument();
		Test.Assert(doc.ReadBytes(utf16, Preserve()) case .Ok);
		Test.Assert(doc.Write(.. scope String()) == "\u{FEFF}<a>\u{416}</a>");
		let bytes = scope List<uint8>();
		Test.Assert(doc.WriteBytes(bytes) case .Ok);
		Test.Assert(bytes.Count == utf16.Count && Internal.MemCmp(bytes.Ptr, utf16.Ptr, bytes.Count) == 0);

		let cp1251 = "<?xml version=\"1.0\" encoding=\"windows-1251\"?><a>\xCF\xF0\xE8</a>";
		Test.Assert(doc.Read(cp1251, Preserve()) case .Ok);
		doc.Root.FirstChild.SetValue("Мир");
		bytes.Clear();
		Test.Assert(doc.WriteBytes(bytes) case .Ok);
		Test.Assert(StringView((char8*)bytes.Ptr, bytes.Count) == "<?xml version=\"1.0\" encoding=\"windows-1251\"?><a>\xCC\xE8\xF0</a>");
		// A character the encoding does not have
		doc.Root.FirstChild.SetValue("€uro ✓");
		bytes.Clear();
		switch (doc.WriteBytes(bytes))
		{
		case .Ok: Test.FatalError("✓ written in windows-1251");
		case .Err(let error): Test.Assert(error.mKind == .InvalidEncoding && error.mMessage.Contains("U+2713"));
		}
		// Without PreserveStyle: UTF-8 in canonical form
		Test.Assert(doc.Read(cp1251) case .Ok);
		bytes.Clear();
		Test.Assert(doc.WriteBytes(bytes) case .Ok);
		Test.Assert(StringView((char8*)bytes.Ptr, bytes.Count) == "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a>При</a>\n");
	}

	[Test]
	public static void DocType_ProcessingInstructionsEdited()
	{
		let input = "<!DOCTYPE r SYSTEM 'r.dtd' [\n  <!ENTITY e 'x'>\n  <?keep one?>\n  <?edit two?>\n  <?drop three?>\n]>\n<r>&e;</r>";
		let doc = ReadPreserved(scope .(), input);
		let docType = doc.DocType;
		Test.Assert(docType.ChildCount == 3);
		docType.FirstChild.NextSibling.SetValue("2");
		docType.LastChild.Remove();
		docType.AddComment(" new ");
		docType.AddProcessingInstruction("added", "4");
		// The DOCTYPE as written, its subset rebuilt: kept, changed in place, removed with its line, added
		AssertWritten(doc, "<!DOCTYPE r SYSTEM 'r.dtd' [\n  <!ENTITY e 'x'>\n  <?keep one?>\n  <?edit 2?>\n<!-- new -->\n<?added 4?>\n]>\n<r>&e;</r>");
		// The canonical writer rebuilds it the same way
		let canonical = doc.WriteCanonical(.. scope String());
		Test.Assert(canonical == "<!DOCTYPE r SYSTEM \"r.dtd\" [\n  <!ENTITY e 'x'>\n  <?keep one?>\n  <?edit 2?>\n<!-- new -->\n<?added 4?>\n]>\n<r>x</r>\n");

		// A DOCTYPE without a subset gets one
		let plain = ReadPreserved(scope .(), "<!DOCTYPE r>\n<r/>");
		plain.DocType.AddProcessingInstruction("p", "d");
		AssertWritten(plain, "<!DOCTYPE r [<?p d?>]>\n<r/>");

		// One from a parameter entity: its entity writes it, so it cannot be changed
		let fromEntity = ReadPreserved(scope .(), "<!DOCTYPE r [<!ENTITY % pe '<?pi inner?>'> %pe;]><r/>");
		Test.Assert(fromEntity.DocType.ChildCount == 1 && !fromEntity.DocType.FirstChild.IsEditable);
		Test.Assert(fromEntity.DocType.FirstChild.Value == "inner");
	}

	static StringView Bytes(List<uint8> bytes) => .((char8*)bytes.Ptr, bytes.Count);

	[Test]
	public static void Bytes_UnencodablePolicies()
	{
		let input = "<?xml version='1.0' encoding='windows-1251'?><a t='x'>\xCF<![CDATA[c]]><!--k--></a>";
		let doc = scope XmlDocument();
		Test.Assert(doc.Read(input, Preserve()) case .Ok);
		let a = doc.Root;
		a.FirstChild.SetValue("П✓");
		a.SetAttribute("t", "y✓");
		a.FirstChild.NextSibling.SetValue("c✓");
		let bytes = scope List<uint8>();

		// Error, the default: nothing written
		Test.Assert(doc.WriteBytes(bytes) case .Err && bytes.IsEmpty);

		// Character references (and CDATA split around one)
		var options = XmlWriteOptions();
		options.Unencodable = .CharacterReference;
		Test.Assert(doc.WriteBytes(bytes, options) case .Ok);
		Test.Assert(Bytes(bytes) == "<?xml version='1.0' encoding='windows-1251'?><a t='y&#x2713;'>\xCF&#x2713;<![CDATA[c]]>&#x2713;<![CDATA[]]><!--k--></a>");
		// ... which reads back the same
		let again = scope XmlDocument();
		Test.Assert(again.ReadBytes(bytes) case .Ok);
		Test.Assert(again.Root.FirstChild.Value == "П✓" && again.Root.GetAttribute("t") == "y✓");
		var text = scope String();
		again.Root.AppendText(text);
		Test.Assert(text == "П✓c✓");

		// No reference in a comment: still an error there
		a.LastChild.SetValue("k✓");
		bytes.Clear();
		switch (doc.WriteBytes(bytes, options))
		{
		case .Ok: Test.FatalError("a reference in a comment");
		case .Err(let error): Test.Assert(error.mMessage.Contains("U+2713") && error.mMessage.Contains("no character reference"));
		}

		// Replace
		options.Unencodable = .Replace;
		options.Replacement = "?";
		bytes.Clear();
		Test.Assert(doc.WriteBytes(bytes, options) case .Ok);
		Test.Assert(Bytes(bytes) == "<?xml version='1.0' encoding='windows-1251'?><a t='y?'>\xCF?<![CDATA[c?]]><!--k?--></a>");

		// Custom: by context
		options.Unencodable = .Custom;
		options.Handler = scope (c, context, replacement) =>
			{
				if (context == .Comment)
					return false;
				replacement.Append(context == .Text ? "[check]" : "_");
				return true;
			};
		bytes.Clear();
		Test.Assert(doc.WriteBytes(bytes, options) case .Err);
		a.LastChild.SetValue("k");
		Test.Assert(doc.WriteBytes(bytes, options) case .Ok);
		Test.Assert(Bytes(bytes) == "<?xml version='1.0' encoding='windows-1251'?><a t='y_'>\xCF[check]<![CDATA[c_]]><!--k--></a>");

		// UTF-8 for the whole document, saying so
		options.Unencodable = .Utf8;
		bytes.Clear();
		Test.Assert(doc.WriteBytes(bytes, options) case .Ok);
		Test.Assert(Bytes(bytes) == "<?xml version='1.0' encoding='UTF-8'?><a t='y✓'>П✓<![CDATA[c✓]]><!--k--></a>");
		// When everything can be held, the document's own encoding still
		a.FirstChild.SetValue("П");
		a.SetAttribute("t", "y");
		a.FirstChild.NextSibling.SetValue("c");
		bytes.Clear();
		Test.Assert(doc.WriteBytes(bytes, options) case .Ok);
		Test.Assert(Bytes(bytes) == "<?xml version='1.0' encoding='windows-1251'?><a t='y'>\xCF<![CDATA[c]]><!--k--></a>");
	}

	[Test]
	public static void Streams_SameAsMemory()
	{
		let input = "<?xml version='1.0'?>\r\n<r a = \"1\">\r\n  <s/>\r\n</r>\r\n";
		let doc = scope XmlDocument();
		var config = Preserve();
		config.StreamBufferBytes = 16;
		Test.Assert(doc.Read(scope XmlStreamTests.TrickleStream(input, 3), config) case .Ok);
		Test.Assert(doc.Write(.. scope String()) == input);
		doc.Root.SetAttribute("a", "2");
		Test.Assert(doc.Write(.. scope String()) == "<?xml version='1.0'?>\r\n<r a = \"2\">\r\n  <s/>\r\n</r>\r\n");
	}
}
