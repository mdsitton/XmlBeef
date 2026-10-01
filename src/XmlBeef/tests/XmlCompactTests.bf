using System;
using System.Collections;
using XmlBeef;

namespace XmlBeef;

/// Compact, Clear(releaseMemory) and MemoryUsage (review P04).
static class XmlCompactTests
{
	const String cSample = "<?xml version=\"1.0\"?>\n<!DOCTYPE r [\n<!NOTATION gif PUBLIC \"-//gif//\">\n<?pi in the subset?>\n<!ENTITY e \"text &#38;amp; more\">\n<!ATTLIST b d CDATA \"default\">\n]>\n" +
		"<!-- before -->\n<r xmlns:p=\"urn:p\">\n  <a x=\"1\" y=\"two\">a &e; b</a>\n  <b p:z=\"3\"><![CDATA[c\r\nd]]></b>\n  <c>keep</c>\n</r>\n<?after data?>\n";

	/// A history of edits: values replaced over and over, attributes appended on two elements in turn
	/// (each append moves the other's span), nodes added and removed.
	static void Edit(XmlDocument doc, int rounds)
	{
		let a = doc.Root.Find("a");
		let b = doc.Root.Find("b");
		for (int i < rounds)
		{
			a.FirstChild.SetValue(scope $"value {i} with some length to it");
			a.SetAttribute(scope $"n{i % 7}", scope $"{i}");
			b.SetAttribute(scope $"m{i % 5}", scope $"{i}");
			let added = doc.Root.AddElement("tmp");
			added.AddText(scope $"temporary {i}");
			if (i % 2 == 0)
				added.Remove();
		}
	}

	[Test]
	public static void Compact_DropsTheEditHistory()
	{
		for (let mode in XmlMetadataMode[](.None, .Positions, .PreserveStyle))
		{
			let doc = scope XmlDocument();
			var config = XmlReadConfig();
			config.MetadataMode = mode;
			Test.Assert(doc.Read(cSample, config) case .Ok);
			Edit(doc, 2000);
			let before = doc.MemoryUsage;
			Test.Assert(before.mNodeSlots > before.mNodes && before.mAttributeSlots > before.mAttributes);
			Test.Assert(before.mTextFilled > 4 * before.mTextLive);
			let written = doc.Write(.. scope String());
			let suite = XmlCanonical.WriteSuiteForm(doc, .. scope String());

			doc.Compact();
			let after = doc.MemoryUsage;
			Test.Assert(after.mNodes == before.mNodes && after.mAttributes == before.mAttributes);
			Test.Assert(after.mNodeSlots == after.mNodes && after.mAttributeSlots == after.mAttributes);
			// One chunk, filled exactly
			Test.Assert(after.mTextLive == before.mTextLive && after.mTextReserved == after.mTextLive && after.mTextFilled == after.mTextLive);
			Test.Assert(after.mTotalReserved < before.mTotalReserved);
			// The same document, written the same way
			Test.Assert(doc.Write(.. scope String()) == written);
			Test.Assert(XmlCanonical.WriteSuiteForm(doc, .. scope String()) == suite);
			Test.Assert(doc.Version == "1.0" && doc.Notations.Length == 1 && doc.Notations[0].mPublicId == "-//gif//");
			Test.Assert(doc.Root.Find("a").GetAttribute("y") == "two");

			// It edits on after, as it would have
			let again = scope XmlDocument();
			Test.Assert(again.Read(cSample, config) case .Ok);
			Edit(again, 2000);
			Edit(doc, 10);
			Edit(again, 10);
			Test.Assert(doc.Write(.. scope String()) == again.Write(.. scope String()));
			let bytes = scope List<uint8>();
			Test.Assert(doc.WriteBytes(bytes) case .Ok);
			let reread = scope XmlDocument();
			Test.Assert(reread.ReadBytes(bytes) case .Ok);
			Test.Assert(XmlCanonical.WriteSuiteForm(reread, .. scope String()) == XmlCanonical.WriteSuiteForm(again, .. scope String()));
		}
	}

	[Test]
	public static void Compact_RenumbersInDocumentOrder()
	{
		let doc = scope XmlDocument();
		var config = XmlReadConfig();
		config.MetadataMode = .Positions;
		Test.Assert(doc.Read("<r>\n<a/>\n<b>x</b>\n<c/></r>", config) case .Ok);
		let a = doc.Root.Find("a");
		let c = doc.Root.LastChild;
		Test.Assert(c.TryGetSourceRange(let cRange));
		let cId = c.Id;
		a.Remove();
		let late = doc.Root.Find("b").AddElement("late");
		let lateId = late.Id;
		let newIds = scope List<XmlNodeId>();
		doc.Compact(newIds);
		// Handles from before are invalid; the IDs map
		Test.Assert(!c.IsValid && !late.IsValid);
		Test.Assert(newIds[a.Id.Value] == default);
		let newC = doc.GetNode(newIds[cId.Value]);
		Test.Assert(newC.IsValid && newC.Name == "c" && newC == doc.Root.LastChild);
		Test.Assert(doc.GetNode(newIds[lateId.Value]).Name == "late");
		// Positions stay with their nodes
		Test.Assert(newC.TryGetSourceRange(let range) && range.mLine == cRange.mLine && range.mColumn == cRange.mColumn && range.mOffset == cRange.mOffset);
		// Document order: each node's ID is greater than its parent's and its previous sibling's
		for (let node in doc.Root.Descendants)
		{
			Test.Assert(node.Id.Value > node.Parent.Id.Value);
			if (node.PreviousSibling.IsValid)
				Test.Assert(node.Id.Value > node.PreviousSibling.Id.Value);
		}
	}

	[Test]
	public static void Compact_KeepsCollectedErrors()
	{
		let doc = scope XmlDocument();
		var config = XmlReadConfig();
		config.CollectErrors = true;
		Test.Assert(doc.Read("<r><a></b><c x='1' x='2'/></r>", config) case .Err);
		let messages = scope List<String>();
		defer { ClearAndDeleteItems!(messages); }
		for (let error in doc.Errors)
			messages.Add(new String(error.mMessage));
		Test.Assert(messages.Count >= 2);
		doc.Compact();
		Test.Assert(doc.Errors.Length == messages.Count);
		for (int i < messages.Count)
			Test.Assert(doc.Errors[i].mMessage == messages[i]);
	}

	[Test]
	public static void Clear_ReleasesMemory()
	{
		let large = scope String("<r>");
		for (int i < 20000)
			large.AppendF("<item id=\"{}\" name=\"n{}\">text {}</item>", i, i % 100, i);
		large.Append("</r>");
		let doc = scope XmlDocument();
		Test.Assert(doc.Read(large) case .Ok);
		let full = doc.MemoryUsage;
		// Clear keeps what it grew to, for the next read
		doc.Clear();
		Test.Assert(doc.MemoryUsage.mTotalReserved >= full.mTextReserved);
		doc.Clear(true);
		let released = doc.MemoryUsage;
		Test.Assert(released.mTextReserved == 0 && released.mTotalReserved < full.mTotalReserved / 20);
		// And reads as before
		Test.Assert(doc.Read("<r><a x='1'/></r>") case .Ok);
		Test.Assert(doc.Root.FirstChild.GetAttribute("x") == "1");
		Test.Assert(doc.Read(large) case .Ok);
		Test.Assert(doc.Root.ChildCount == 20000);
	}
}
