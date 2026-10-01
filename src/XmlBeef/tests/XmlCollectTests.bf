using System;
using System.Collections;
using XmlBeef;

namespace XmlBeef;

/// Collect-errors (XmlReadConfig.CollectErrors): every error reported, the read going on after each,
/// and the document keeping what could be read.
static class XmlCollectTests
{
	static XmlReadConfig Collect()
	{
		var config = XmlReadConfig();
		config.CollectErrors = true;
		return config;
	}

	/// Reads `input` collecting errors: the error kinds must be `kinds`, and the document `expected` in
	/// canonical form.
	static void Expect(StringView input, Span<XmlErrorKind> kinds, StringView expected, int line = Compiler.CallerLineNum)
	{
		let doc = scope XmlDocument();
		let result = doc.Read(input, Collect());
		let got = scope String();
		for (let error in doc.Errors)
			got.AppendF("{} ", error.mKind);
		let want = scope String();
		for (let kind in kinds)
			want.AppendF("{} ", kind);
		if (got != want)
			Test.FatalError(scope $"line {line}: errors `{got}`, expected `{want}`");
		if ((result case .Err) != !kinds.IsEmpty)
			Test.FatalError(scope $"line {line}: Read's result does not match the errors");
		let written = doc.WriteCanonical(.. scope String());
		if (written != expected)
			Test.FatalError(scope $"line {line}: read as `{written}`, expected `{expected}`");
	}

	[Test]
	public static void Recovery_EachConstruct()
	{
		// A broken start tag is skipped (its end tag goes quietly), a stray end tag dropped, a broken
		// comment and reference skipped, the unclosed root closed at the end
		Expect("<r><a x=\"1\" y=2>t</a><b></c></b><!-- x -- y --><d>&bad;</d><e/>",
			XmlErrorKind[](.UnexpectedChar, .MismatchedEndTag, .InvalidComment, .UndeclaredEntity, .UnclosedElement),
			"<r>t<b/><d/><e/></r>\n");
		// A mismatched end tag naming an open element closes down to it
		Expect("<r><a><b></a><c/></r>", XmlErrorKind[](.MismatchedEndTag), "<r><a><b/></a><c/></r>\n");
		// A second root element is skipped whole
		Expect("<r/><s><t/></s><!--c-->", XmlErrorKind[](.InvalidDocumentStructure), "<r/>\n<!--c-->\n");
		// Text outside the root, `]]>` in text (the text before it in the same run goes with it), a broken
		// processing instruction
		Expect("x<r>a]]>b<?xml bad?>c</r>", XmlErrorKind[](.InvalidDocumentStructure, .InvalidCData, .InvalidProcessingInstruction), "<r>bc</r>\n");
		// A broken declaration in the internal subset: the next one is read
		Expect("<!DOCTYPE r [<!ENTITY a 'x' junk><!ENTITY b 'y'>]><r>&b;</r>", XmlErrorKind[](.UnexpectedChar), "<!DOCTYPE r [<!ENTITY a 'x' junk><!ENTITY b 'y'>]>\n<r>y</r>\n");
		// Nothing wrong: nothing reported
		Expect("<r><a/></r>", default, "<r><a/></r>\n");
	}

	[Test]
	public static void Recovery_EntitiesAndPositions()
	{
		// An error in an entity's text: reading goes on after the reference
		Expect("<!DOCTYPE r [<!ENTITY e 'a<b'>]><r>&e;<c/></r>", XmlErrorKind[](.UnexpectedEof), "<!DOCTYPE r [<!ENTITY e 'a<b'>]>\n<r>a<c/></r>\n");
		// Errors are located, in order
		let doc = scope XmlDocument();
		Test.Assert(doc.Read("<r>\n  <a b=1/>\n  </x>\n</r>", Collect()) case .Err(let first));
		Test.Assert(first.mLine == 2 && doc.Errors.Length == 2);
		Test.Assert(doc.Errors[1].mLine == 3 && doc.Errors[1].mColumn == 3);
		// The broken `<a b=1/>` and the stray `</x>` are gone; the whitespace around them stays
		Test.Assert(doc.Root.IsValid && doc.Root.ChildCount == 3 && doc.Root.Children.Elements.Count == 0);
	}

	[Test]
	public static void Reader_GoesOn()
	{
		var config = Collect();
		let reader = scope XmlReader("<r><a></b><c/></r>", config);
		int errors = 0;
		int starts = 0;
		int ends = 0;
		while (true)
		{
			switch (reader.Next())
			{
			case .Ok(let event):
				if (event == .StartElement)
					starts++;
				else if (event == .EndElement)
					ends++;
				if (event == .EndOfDocument)
				{
					// Every start has its end, after two errors: `</b>` names no open element, and `</r>`
					// comes with `a` still open
					Test.Assert(errors == 2 && starts == 3 && ends == 3 && !reader.IsStopped);
					return;
				}
			case .Err:
				errors++;
				Test.Assert(!reader.IsStopped);
			}
		}
	}

	[Test]
	public static void Limits_StopTheRead()
	{
		// MaxErrors
		var config = Collect();
		config.MaxErrors = 5;
		let doc = scope XmlDocument();
		let input = scope String("<r>");
		for (int i < 20)
			input.Append("&x;");
		input.Append("</r>");
		Test.Assert(doc.Read(input, config) case .Err);
		Test.Assert(doc.Errors.Length == 5 && doc.Root.IsValid);

		// An encoding error stops it
		let reader = scope XmlReader("<r>\xFF</r>", Collect());
		Test.Assert(reader.Next() case .Err(let error) && error.mKind == .InvalidEncoding && reader.IsStopped);

		// Without CollectErrors, the first error ends the read and empties the document
		Test.Assert(doc.Read("<r><a></b></r>") case .Err);
		Test.Assert(doc.Errors.IsEmpty && !doc.Root.IsValid);
	}
}
