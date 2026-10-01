using System;
using System.Collections;
using XmlBeef;

namespace XmlBeef;

/// Follow-up review: a wrapped list in the root's namespace whose items are in their own.
[XmlObject(Name = "item", Namespace = "urn:item")]
class FollowUpItem
{
	public int32 id;
}

[XmlObject(Name = "root", Namespace = "urn:root", Strict = true)]
class FollowUpRoot
{
	[XmlArray(Name = "items")] public List<FollowUpItem> items ~ DeleteContainerAndItems!(_);

	public this()
	{
		items = new .();
	}
}

/// Regressions for the follow-up review of the P02, P04, A01-A04 and SP1 commits (cb3534e..b7e953e),
/// in its order.
static class XmlReviewFollowUpTests
{
	/// 1. Compact keeps the places of removed DOCTYPE processing instructions, so they stay out.
	[Test]
	public static void Compact_KeepsRemovedSubsetPisOut()
	{
		for (let mode in XmlMetadataMode[](.None, .Positions, .PreserveStyle))
		{
			var config = XmlReadConfig();
			config.MetadataMode = mode;
			let doc = scope XmlDocument();
			Test.Assert(doc.Read("<!DOCTYPE r [<?gone data?><?keep more?>]><r/>", config) case .Ok);
			doc.DocType.FirstChild.Remove();
			let before = doc.Write(.. scope String());
			Test.Assert(!before.Contains("gone") && before.Contains("<?keep more?>"));
			doc.Compact();
			Test.Assert(doc.Write(.. scope String()) == before);
			// Edits after compaction still find their places
			doc.DocType.FirstChild.SetValue("changed");
			let after = doc.Write(.. scope String());
			Test.Assert(!after.Contains("gone") && after.Contains("<?keep changed?>") && !after.Contains("more"));
		}
	}

	/// 2. Renaming an element whose attribute values the old name's ATTLIST normalized writes the values.
	[Test]
	public static void Rename_KeepsNormalizedValues()
	{
		var config = XmlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let doc = scope XmlDocument();
		Test.Assert(doc.Read("<!DOCTYPE r [<!ATTLIST r a NMTOKENS #IMPLIED b CDATA #IMPLIED>]><r a=' x   y ' b='plain'/>", config) case .Ok);
		Test.Assert(doc.Root.GetAttribute("a") == "x y");
		doc.Root.Rename("s");
		let written = doc.Write(.. scope String());
		Test.Assert(written.Contains("<s a='x y' b='plain'/>"));
		let again = scope XmlDocument();
		Test.Assert(again.Read(written) case .Ok);
		Test.Assert(again.Root.GetAttribute("a") == "x y");
	}

	/// 3. A strict root with a wrapped list of items in another namespace reads its own output.
	[Test]
	public static void Typed_WrapperInTheFieldsNamespace()
	{
		let root = scope FollowUpRoot();
		Test.Assert(XmlSerializer.Read("<root xmlns='urn:root' xmlns:i='urn:item'><items><i:item id='1'/><i:item id='2'/></items></root>", root) case .Ok);
		Test.Assert(root.items.Count == 2 && root.items[1].id == 2);
		let output = scope String();
		Test.Assert(XmlSerializer.Write(root, output) case .Ok);
		let again = scope FollowUpRoot();
		if (XmlSerializer.Read(output, again) case .Err(let error))
			Test.FatalError(scope $"`{output}` was rejected: {error}");
		Test.Assert(again.items.Count == 2 && again.items[0].id == 1);
		// The wrapper is the root's child element: in another namespace it is not the list's
		Test.Assert(XmlSerializer.Read("<root xmlns='urn:root' xmlns:i='urn:item'><i:items><i:item id='1'/></i:items></root>", scope FollowUpRoot()) case .Err);
	}

	/// 5. Clear(true) frees, and MemoryUsage counts, the DOCTYPE's tables too.
	[Test]
	public static void Clear_ReleasesTheSubsetTables()
	{
		let input = scope String("<!DOCTYPE r [");
		for (int i < 10000)
			input.Append("<?pi data?>");
		input.Append("]><r/>");
		let doc = scope XmlDocument();
		Test.Assert(doc.Read(input) case .Ok);
		let full = doc.MemoryUsage;
		Test.Assert(full.mTotalReserved > 10000 * 12);
		doc.Clear(true);
		Test.Assert(doc.MemoryUsage.mTotalReserved < 8 * 1024);
	}

	/// 6. An error located on the LF of a CRLF is placed the same way whatever follows it, from a stream
	/// and from memory.
	[Test]
	public static void Positions_CrlfAtTheOffset()
	{
		var config = XmlReadConfig();
		config.StreamBufferBytes = 16;
		config.MaxTokenBytes = 5;
		for (let input in StringView[]("<!--\r\n", "<!--\r\n--><r/>", "<!--\r\n--><r/>                                   "))
		{
			let doc = scope XmlDocument();
			switch (doc.Read(scope XmlStreamTests.TrickleStream(input, 16), config))
			{
			case .Ok:
				Test.FatalError(scope $"`{input}` was accepted");
			case .Err(let error):
				Test.Assert(error.mOffset == 5 && error.mLine == 1 && error.mColumn == 6);
			}
		}
		XmlChar.LineAndColumn("<!--\r\n-->", 5, let line, let column);
		Test.Assert(line == 1 && column == 6);
		XmlChar.LineAndColumn("<!--\r\n-->", 6, let nextLine, let nextColumn);
		Test.Assert(nextLine == 2 && nextColumn == 1);
	}
}
