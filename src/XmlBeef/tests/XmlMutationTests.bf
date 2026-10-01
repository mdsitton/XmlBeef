using System;
using System.Collections;
using XmlBeef;

namespace XmlBeef;

/// The mutation API (plan.md §4.8): building, moving, removing, renaming, attributes, namespaces.
static class XmlMutationTests
{
	[Test]
	public static void Build_FromNothing()
	{
		let doc = scope XmlDocument();
		doc.DocumentNode.AddComment(" made in code ");
		let root = doc.DocumentNode.AddElement("svg");
		Test.Assert(doc.Root == root);
		root.SetAttribute("xmlns", "http://www.w3.org/2000/svg");
		root.SetAttribute("width", "10");
		let g = root.AddElement("g");
		g.AddText("a < b & c");
		g.AddCData("<raw>");
		g.AddProcessingInstruction("pi", "data");
		root.AddElement("rect");
		Test.Assert(g.NamespaceUri == "http://www.w3.org/2000/svg");
		Test.Assert(doc.Write(.. scope String()) == "<!-- made in code -->\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\"><g>a &lt; b &amp; c<![CDATA[<raw>]]><?pi data?></g><rect/></svg>\n");
		Test.Assert(root.ChildCount == 2 && g.ChildCount == 3);
	}

	[Test]
	public static void Insert_AndRemove()
	{
		let doc = scope XmlDocument();
		Test.Assert(doc.Read("<r><a/><c/></r>") case .Ok);
		let a = doc.Root.FirstChild;
		let c = doc.Root.LastChild;
		let b = c.InsertElementBefore("b");
		a.InsertElementBefore("first");
		c.InsertElementAfter("last");
		Test.Assert(doc.Write(.. scope String()) == "<r><first/><a/><b/><c/><last/></r>\n");
		b.Remove();
		Test.Assert(!b.IsValid && a.IsValid && doc.Root.ChildCount == 4);
		Test.Assert(a.NextSibling == c && c.PreviousSibling == a);
		doc.Root.Remove();
		Test.Assert(!doc.Root.IsValid && !a.IsValid);
		doc.DocumentNode.AddElement("new");
		Test.Assert(doc.Write(.. scope String()) == "<new/>\n");
	}

	[Test]
	public static void Move_Checked()
	{
		let doc = scope XmlDocument();
		Test.Assert(doc.Read("<r><a><b/></a>t<!--c--></r>") case .Ok);
		let a = doc.Root.FirstChild;
		let b = a.FirstChild;
		let t = a.NextSibling;
		let comment = doc.Root.LastChild;
		// Not into itself or below it, no text outside the root, no second root
		Test.Assert(!a.MoveInto(b) && !a.MoveInto(a));
		Test.Assert(!t.MoveInto(doc.DocumentNode));
		Test.Assert(!b.MoveInto(doc.DocumentNode));
		Test.Assert(!doc.Root.MoveBefore(doc.Root));
		// Allowed moves
		Test.Assert(comment.MoveInto(doc.DocumentNode));
		Test.Assert(b.MoveBefore(a));
		Test.Assert(t.MoveInto(b));
		Test.Assert(doc.Write(.. scope String()) == "<r><b>t</b><a/></r>\n<!--c-->\n");
	}

	[Test]
	public static void Names_AndValues()
	{
		let doc = scope XmlDocument();
		Test.Assert(doc.Read("<r><a>x</a><!--c--><?p d?></r>") case .Ok);
		let a = doc.Root.FirstChild;
		a.Rename("b");
		a.FirstChild.SetValue("y");
		a.NextSibling.SetValue("comment");
		a.NextSibling.NextSibling.SetValue("data");
		a.NextSibling.NextSibling.Rename("q");
		Test.Assert(doc.Write(.. scope String()) == "<r><b>y</b><!--comment--><?q data?></r>\n");
		doc.Root.SetText("only");
		Test.Assert(doc.Write(.. scope String()) == "<r>only</r>\n" && !a.IsValid);
		doc.Root.SetText("");
		Test.Assert(doc.Write(.. scope String()) == "<r/>\n");
	}

	[Test]
	public static void Attributes_Table()
	{
		let doc = scope XmlDocument();
		var config = XmlReadConfig();
		config.MetadataMode = .Positions;
		Test.Assert(doc.Read("<r><a x=\"1\" y=\"2\" z=\"3\"/><b k=\"v\"/></r>", config) case .Ok);
		let a = doc.Root.FirstChild;
		let b = a.NextSibling;
		// Grows a's attributes though b's follow them in the table; source ranges move along
		a.SetAttribute("n", "4");
		Test.Assert(a.RemoveAttribute("y") && !a.RemoveAttribute("y"));
		Test.Assert(a.GetAttribute("z") == "3" && a.GetAttribute("n") == "4" && b.GetAttribute("k") == "v");
		Test.Assert(a.Attributes.Count == 3);
		XmlAttribute z = default;
		for (let attribute in a.Attributes)
		{
			if (attribute.Name == "z")
				z = attribute;
		}
		Test.Assert(z.TryGetSourceRange(let range) && range.mOffset == 18 && range.mLength == 5);
		Test.Assert(doc.Write(.. scope String()) == "<r><a x=\"1\" z=\"3\" n=\"4\"/><b k=\"v\"/></r>\n");
	}

	[Test]
	public static void Attributes_DefaultBecomesSpecified()
	{
		let doc = scope XmlDocument();
		Test.Assert(doc.Read("<!DOCTYPE r [<!ATTLIST r d CDATA 'def'>]><r/>") case .Ok);
		Test.Assert(doc.Write(.. scope String()).Contains("<r/>"));
		doc.Root.SetAttribute("d", "set");
		Test.Assert(doc.Write(.. scope String()).Contains("<r d=\"set\"/>"));
	}

	[Test]
	public static void Namespaces_ResolvedAgain()
	{
		let doc = scope XmlDocument();
		Test.Assert(doc.Read("<r xmlns='urn:d' xmlns:p='urn:p'><a><p:b p:at='1'/></a><s xmlns='urn:s'/></r>") case .Ok);
		let a = doc.Root.FirstChild;
		let pb = a.FirstChild;
		let s = a.NextSibling;
		Test.Assert(a.NamespaceUri == "urn:d" && pb.NamespaceUri == "urn:p");
		// A new element takes the namespaces in scope where it is added
		let n = a.AddElement("n");
		let pn = s.AddElement("p:n");
		Test.Assert(n.NamespaceUri == "urn:d" && pn.NamespaceUri == "urn:p");
		Test.Assert(s.AddElement("m").NamespaceUri == "urn:s");
		// Moved: resolved where it lands
		Test.Assert(n.MoveInto(s) && n.NamespaceUri == "urn:s");
		// A declaration changed or removed: the names under it are resolved again
		a.SetAttribute("xmlns:p", "urn:other");
		Test.Assert(pb.NamespaceUri == "urn:other");
		Test.Assert(pb.Attributes[0].NamespaceUri == "urn:other");
		Test.Assert(a.RemoveAttribute("xmlns:p") && pb.NamespaceUri == "urn:p");
		Test.Assert(s.RemoveAttribute("xmlns") && n.NamespaceUri == "urn:d");
		// Renamed: its own prefix resolved again
		a.Rename("p:a");
		Test.Assert(a.NamespaceUri == "urn:p" && a.LocalName == "a");
		Test.Assert(doc.Root.Find("urn:p", "a") == a);
	}

	[Test]
	public static void Checks_NamesAndText()
	{
		Test.Assert(XmlDocument.IsValidName("a") && XmlDocument.IsValidName("p:a") && XmlDocument.IsValidName("_x.1-é"));
		Test.Assert(!XmlDocument.IsValidName("") && !XmlDocument.IsValidName("1a") && !XmlDocument.IsValidName("a b"));
		Test.Assert(!XmlDocument.IsValidName("a:b:c") && XmlDocument.IsValidName("a:b:c", false));
		Test.Assert(!XmlDocument.IsValidName(":a") && !XmlDocument.IsValidName("a:") && !XmlDocument.IsValidName("a:1"));
		Test.Assert(XmlDocument.IsValidText("tab\tok\r\n") && !XmlDocument.IsValidText("bell\x07") && !XmlDocument.IsValidText("\xFF"));
	}
}
