using System;
using System.Collections;
using XmlBeef;

namespace XmlTester;

/// `XmlTester -mutate SEED`: random edits of a PreserveStyle document, then a check that the preserving
/// writer kept them: the written text must read back into the same document (compared in canonical
/// form). The edits keep the document well-formed: no root or DOCTYPE removed, no namespace
/// declaration touched, moves only among an element's children.
static class Mutate
{
	public const int cEdits = 8;

	public static int Run(XmlDocument doc, XmlReadConfig config, int seed)
	{
		let random = scope Random(seed);
		let log = scope String();
		for (int edit < cEdits)
			Apply(doc, random, edit, log);

		let written = scope String();
		doc.Write(written);
		// Read back the bytes, in the document's encoding
		let bytes = scope List<uint8>();
		if (doc.WriteBytes(bytes) case .Err(let encodeError))
		{
			Console.Error.WriteLine(scope $"the document cannot be written in its encoding: {encodeError}");
			return 3;
		}
		let again = scope XmlDocument();
		var readConfig = config;
		readConfig.MetadataMode = .None;
		if (again.ReadBytes(bytes, readConfig) case .Err(let error))
		{
			Console.Error.WriteLine(scope $"the written document was rejected: {error}");
			Console.Error.Write(log);
			Console.Error.WriteLine("--- written:");
			Console.Error.WriteLine(written);
			return 3;
		}
		// The suite form: defaulted attributes in it (the canonical writer leaves them to the DTD, which
		// would hide a lost one), adjacent text and CDATA merged
		let expected = XmlCanonical.WriteSuiteForm(doc, .. scope String());
		let actual = XmlCanonical.WriteSuiteForm(again, .. scope String());
		if (expected != actual)
		{
			Console.Error.WriteLine("the written document reads back differently");
			Console.Error.Write(log);
			Console.Error.WriteLine("--- written:");
			Console.Error.WriteLine(written);
			Console.Error.WriteLine("--- expected (canonical):");
			Console.Error.WriteLine(expected);
			Console.Error.WriteLine("--- read back (canonical):");
			Console.Error.WriteLine(actual);
			return 4;
		}
		Console.Out.Write(written);
		return 0;
	}

	/// The nodes of the document outside the DOCTYPE, in document order.
	static void Collect(XmlDocument doc, List<XmlNode> nodes)
	{
		let stack = scope List<XmlNode>();
		for (let child in doc.DocumentNode.Children)
		{
			if (child.Kind == .DocType)
				continue;
			stack.Add(child);
			while (!stack.IsEmpty)
			{
				let node = stack.PopBack();
				nodes.Add(node);
				for (var c = node.LastChild; c.IsValid; c = c.PreviousSibling)
					stack.Add(c);
			}
		}
	}

	static bool IsDeclaration(XmlAttribute attribute)
	{
		return attribute.Name == "xmlns" || attribute.Name.StartsWith("xmlns:");
	}

	static void Apply(XmlDocument doc, Random random, int edit, String log)
	{
		let nodes = scope List<XmlNode>();
		Collect(doc, nodes);
		let elements = scope List<XmlNode>();
		for (let n in nodes)
		{
			if (n.Kind == .Element)
				elements.Add(n);
		}
		if (elements.IsEmpty)
			return;
		let element = elements[random.Next(elements.Count)];
		let node = nodes[random.Next(nodes.Count)];
		switch (random.Next(9))
		{
		case 8:
			// The DOCTYPE's processing instructions (not those its parameter entities write)
			let docType = doc.DocType;
			if (!docType.IsValid)
				return;
			let editable = scope List<XmlNode>();
			for (let child in docType.Children)
			{
				if (child.IsEditable)
					editable.Add(child);
			}
			int choice = random.Next(4);
			if (choice == 3)
			{
				// The whole DOCTYPE: what it supplied (defaults, entity text) must stay. Not with references to
				// unread entities, which have no value to write without it.
				for (let n in nodes)
				{
					if (n.Kind == .EntityReference)
						return;
				}
				log.Append("remove the DOCTYPE\n");
				docType.Remove();
			}
			else if (editable.IsEmpty || choice == 0)
			{
				log.Append("add a processing instruction to the DOCTYPE\n");
				docType.AddProcessingInstruction("added", scope $"pi {edit}");
			}
			else if (choice == 1)
			{
				log.Append("change a DOCTYPE processing instruction\n");
				editable[random.Next(editable.Count)].SetValue(scope $"changed {edit}");
			}
			else
			{
				log.Append("remove a DOCTYPE processing instruction\n");
				editable[random.Next(editable.Count)].Remove();
			}
		case 0:
			// Change an attribute, or add one
			let attributes = scope List<XmlAttribute>();
			for (let a in element.Attributes)
			{
				if (!IsDeclaration(a))
					attributes.Add(a);
			}
			let name = scope String();
			if (!attributes.IsEmpty && random.Next(2) == 0)
				name.Set(attributes[random.Next(attributes.Count)].Name);
			else
				name.AppendF("data-m{}", edit);
			log.AppendF("set attribute {} on {}\n", name, element.Name);
			element.SetAttribute(name, scope $"v{edit}&<\"'");
		case 1:
			// Not where the internal subset may declare a default: reading the written document back
			// supplies it again (RemoveAttribute's documented behavior)
			if (doc.HasInternalSubset)
				return;
			for (let a in element.Attributes)
			{
				if (IsDeclaration(a))
					continue;
				log.AppendF("remove attribute {} from {}\n", a.Name, element.Name);
				element.RemoveAttribute(scope String(a.Name));
				break;
			}
		case 2:
			if (node == doc.Root)
				return;
			log.AppendF("remove a {} ({})\n", node.Kind, node.Name);
			node.Remove();
		case 3:
			switch (node.Kind)
			{
			case .Text:
				log.Append("set text\n");
				node.SetValue(scope $"t{edit} & < > ]]> \" '\r\n");
			case .CData:
				log.Append("set CDATA\n");
				node.SetValue(scope $"c{edit} ]]> <&\r\n\r");
			case .Comment:
				log.Append("set comment\n");
				node.SetValue(scope $" comment {edit} ");
			case .ProcessingInstruction:
				log.Append("set processing instruction data\n");
				node.SetValue(scope $"data {edit}");
			default:
			}
		case 4:
			log.AppendF("add an element to {}\n", element.Name);
			let added = element.AddElement("x-new");
			if (random.Next(2) == 0)
				added.AddText("new");
		case 5:
			// What the old name's declarations gave the attributes (defaults, normalization) must stay
			log.AppendF("rename {}\n", element.Name);
			element.Rename(scope $"renamed{edit}");
		case 6:
			// Move a node before its previous sibling, inside an element
			let prev = node.PreviousSibling;
			if (!prev.IsValid || node.Parent.Kind != .Element)
				return;
			log.AppendF("move a {} before a {}\n", node.Kind, prev.Kind);
			node.MoveBefore(prev);
		case 7:
			log.AppendF("add text to {}\n", element.Name);
			element.AddText(scope $"added {edit}");
		}
	}
}
