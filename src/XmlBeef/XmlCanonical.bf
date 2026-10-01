using System;
using System.Collections;
using internal XmlBeef;

namespace XmlBeef;

/// Canonical forms of a document.
public static class XmlCanonical
{
	/// @brief Write the W3C conformance suite's canonical form of the document `reader` reads: James
	/// Clark's Canonical XML with Sun's notation block (docs/test-suites.md §4). UTF-8, no XML
	/// declaration, comments or DOCTYPE (but a `<!DOCTYPE root [ … ]>` block of the declared notations,
	/// sorted by name, where the DOCTYPE was), every element as a start and end tag, attributes
	/// (defaulted ones included) sorted by name, character data and attribute values escaped the same
	/// way, processing instructions as `<?target data?>` with one space after the target, no trailing
	/// newline.
	/// @param reader A reader at the start of a document; it is read to the end.
	/// @param output The string to append to.
	/// @return The read's first error, if any.
	public static Result<void, XmlParseError> WriteSuiteForm(XmlReader reader, String output)
	{
		let order = scope List<int>();
		while (true)
		{
			switch (Try!(reader.Next()))
			{
			case .EndOfDocument:
				return .Ok;
			case .StartElement:
				output.Append('<');
				output.Append(reader.Name);
				order.Clear();
				for (int i < reader.AttributeCount)
					order.Add(i);
				order.Sort(scope (a, b) => CompareOrdinal(reader.AttributeName(a), reader.AttributeName(b)));
				for (let index in order)
				{
					output.Append(' ');
					output.Append(reader.AttributeName(index));
					output.Append("=\"");
					AppendEscaped(output, reader.AttributeValue(index));
					output.Append('"');
				}
				output.Append('>');
			case .EndElement:
				output.Append("</");
				output.Append(reader.Name);
				output.Append('>');
			case .Text, .CData:
				AppendEscaped(output, reader.Value);
			case .ProcessingInstruction:
				AppendProcessingInstruction(output, reader.Name, reader.Value);
			case .DocType:
				AppendNotations(output, reader.Name, reader.Notations);
			case .XmlDeclaration, .Comment, .EntityReference:
			}
		}
	}

	/// @brief Write the W3C conformance suite's canonical form of a document (see
	/// WriteSuiteForm(XmlReader, String)): the same text the reader's events give.
	/// @param document The document.
	/// @param output The string to append to.
	public static void WriteSuiteForm(XmlDocument document, String output)
	{
		let nodes = document.mNodes;
		let names = document.mNames;
		let order = scope List<int>();
		for (uint32 top = nodes[0].mFirstChild; top != 0; top = nodes[top].mNextSibling)
		{
			ref XmlNodeRecord topNode = ref nodes[top];
			if (topNode.mKind == .DocType)
			{
				for (uint32 pi = topNode.mFirstChild; pi != 0; pi = nodes[pi].mNextSibling)
					AppendProcessingInstruction(output, names[nodes[pi].mName], nodes[pi].mValue);
				AppendNotations(output, names[topNode.mName], document.mNotations);
				continue;
			}
			// A subtree, walking the links
			uint32 id = top;
			while (true)
			{
				ref XmlNodeRecord node = ref nodes[id];
				switch (node.mKind)
				{
				case .Element:
					output.Append('<');
					output.Append(names[node.mName]);
					order.Clear();
					for (int i = node.mAttributeStart; i < node.mAttributeStart + node.mAttributeCount; i++)
						order.Add(i);
					order.Sort(scope (a, b) => CompareOrdinal(names[document.mAttributes[a].mName], names[document.mAttributes[b].mName]));
					for (let index in order)
					{
						output.Append(' ');
						output.Append(names[document.mAttributes[index].mName]);
						output.Append("=\"");
						AppendEscaped(output, document.mAttributes[index].mValue);
						output.Append('"');
					}
					output.Append('>');
					if (node.mFirstChild != 0)
					{
						id = node.mFirstChild;
						continue;
					}
					output.Append("</");
					output.Append(names[node.mName]);
					output.Append('>');
				case .Text, .CData:
					AppendEscaped(output, node.mValue);
				case .ProcessingInstruction:
					AppendProcessingInstruction(output, names[node.mName], node.mValue);
				default:
				}
				// Next: the sibling, or the end tags of the elements this was the last child of
				while (id != top && nodes[id].mNextSibling == 0)
				{
					id = nodes[id].mParent;
					output.Append("</");
					output.Append(names[nodes[id].mName]);
					output.Append('>');
				}
				if (id == top)
					break;
				id = nodes[id].mNextSibling;
			}
		}
	}

	static void AppendProcessingInstruction(String output, StringView target, StringView data)
	{
		output.Append("<?");
		output.Append(target);
		output.Append(' ');
		output.Append(data);
		output.Append("?>");
	}

	/// Sun's notation block: `<!DOCTYPE root [` and the notations sorted by name, or nothing without any.
	static void AppendNotations(String output, StringView root, Span<XmlNotation> notations)
	{
		if (notations.Length == 0)
			return;
		output.Append("<!DOCTYPE ");
		output.Append(root);
		output.Append(" [\n");
		let sorted = scope List<XmlNotation>();
		sorted.AddRange(notations);
		sorted.Sort(scope (a, b) => CompareOrdinal(a.mName, b.mName));
		for (let notation in sorted)
		{
			output.Append("<!NOTATION ");
			output.Append(notation.mName);
			if (notation.mHasPublicId)
			{
				output.Append(" PUBLIC '");
				output.Append(notation.mPublicId);
				output.Append('\'');
				if (notation.mHasSystemId)
				{
					output.Append(" '");
					output.Append(notation.mSystemId);
					output.Append('\'');
				}
			}
			else
			{
				output.Append(" SYSTEM '");
				output.Append(notation.mSystemId);
				output.Append('\'');
			}
			output.Append(">\n");
		}
		output.Append("]>\n");
	}

	/// Byte order, which for UTF-8 is code point order.
	static int CompareOrdinal(StringView a, StringView b)
	{
		int common = Math.Min(a.Length, b.Length);
		int result = Internal.MemCmp(a.Ptr, b.Ptr, common);
		if (result != 0)
			return result;
		return a.Length <=> b.Length;
	}

	/// The suite's escapes, the same in text and attribute values: `& < > "`, tab, LF and CR.
	static void AppendEscaped(String output, StringView text)
	{
		int run = 0;
		for (int i < text.Length)
		{
			StringView escape;
			switch (text[i])
			{
			case '&': escape = "&amp;";
			case '<': escape = "&lt;";
			case '>': escape = "&gt;";
			case '"': escape = "&quot;";
			case '\t': escape = "&#9;";
			case '\n': escape = "&#10;";
			case '\r': escape = "&#13;";
			default: continue;
			}
			output.Append(text.Substring(run, i - run));
			output.Append(escape);
			run = i + 1;
		}
		output.Append(text.Substring(run));
	}
}
