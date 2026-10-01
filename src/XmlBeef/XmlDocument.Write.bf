using System;
using System.Collections;
using internal XmlBeef;

namespace XmlBeef;

/// @brief How XmlDocument.Write formats the document.
public struct XmlWriteOptions
{
	/// @brief The indentation unit (`"  "`, `"\t"`); empty for none. Indentation is added only inside
	/// elements whose content is elements alone (whitespace-only text there is replaced by it); an
	/// element with text or CDATA content, and everything inside it, is written as it is.
	public StringView Indent = default;
}

/// The canonical writer (plan.md §4.11).
extension XmlDocument
{
	/// @brief Append the document as XML text. A document read with XmlMetadataMode.PreserveStyle is
	/// written as it was read, byte for byte in UTF-8 terms (its byte order mark as U+FEFF, its XML
	/// declaration as written even when it names another encoding: WriteBytes and WriteFile write it in
	/// that encoding), with what was changed regenerated and the rest left as it was; any other
	/// document in canonical form (WriteCanonical).
	/// @param output The string to append to.
	public void Write(String output)
	{
		if (mPreserve)
			WritePreserving(output);
		else
			WriteCanonical(output, .());
	}

	/// @brief Append the document as XML text in canonical form with options (see WriteCanonical).
	/// @param output The string to append to.
	/// @param options Indentation.
	public void Write(String output, XmlWriteOptions options)
	{
		WriteCanonical(output, options);
	}

	/// @brief Append the document as XML text in canonical form: UTF-8 (an XML declaration, when the
	/// document had one, says so), `\n` line ends, double-quoted attributes with minimal escaping, `<a/>`
	/// for elements without content, the DOCTYPE with its internal subset as written, comments,
	/// processing instructions, CDATA sections and skipped entity references kept. Attributes from
	/// ATTLIST defaults are not written (the internal subset supplies them again). Each node outside the
	/// root element, and the root, ends a line.
	/// @param output The string to append to.
	/// @param options Indentation.
	public void WriteCanonical(String output, XmlWriteOptions options = .())
	{
		if (mHasDeclaration)
		{
			output.Append("<?xml version=\"");
			output.Append(mVersion);
			output.Append("\" encoding=\"UTF-8\"");
			if (mStandalone != .Unspecified)
				output.Append(mStandalone == .Yes ? " standalone=\"yes\"" : " standalone=\"no\"");
			output.Append("?>\n");
		}
		for (uint32 id = mNodes[0].mFirstChild; id != 0; id = mNodes[id].mNextSibling)
		{
			ref XmlNodeRecord node = ref mNodes[id];
			switch (node.mKind)
			{
			case .Element:
				WriteElementTree(id, options.Indent, output);
			case .DocType:
				WriteDocType(output);
			default:
				WriteLeaf(node, output);
			}
			output.Append('\n');
		}
	}

	/// Writes an element and everything under it, walking the links (no recursion).
	void WriteElementTree(uint32 root, StringView indent, String output)
	{
		// Per open element: whether its children are indented. Below an element whose children are not
		// (mixed content), nothing is.
		let indented = scope List<bool>();
		int depth = 0;
		uint32 id = root;
		while (true)
		{
			ref XmlNodeRecord node = ref mNodes[id];
			bool parentIndented = indented.Count > 0 && indented.Back;
			bool skip = parentIndented && node.mKind == .Text && IsWhitespace(node.mValue);
			if (!skip)
			{
				if (parentIndented)
				{
					output.Append('\n');
					AppendIndent(output, indent, depth);
				}
				if (node.mKind == .Element)
				{
					WriteStartTag(node, output);
					bool indentChildren = !indent.IsEmpty && (indented.Count == 0 || indented.Back) && IsElementOnly(node);
					if (node.mFirstChild != 0 && (!indentChildren || HasElementChild(node)))
					{
						output.Append('>');
						indented.Add(indentChildren);
						depth++;
						id = node.mFirstChild;
						continue;
					}
					output.Append("/>");
				}
				else
					WriteLeaf(node, output);
			}
			// Next: the sibling, or the end tags of the elements this was the last child of
			while (true)
			{
				if (id == root)
					return;
				if (mNodes[id].mNextSibling != 0)
				{
					id = mNodes[id].mNextSibling;
					break;
				}
				id = mNodes[id].mParent;
				depth--;
				if (indented.PopBack())
				{
					output.Append('\n');
					AppendIndent(output, indent, depth);
				}
				output.Append("</");
				output.Append(mNames[mNodes[id].mName]);
				output.Append('>');
			}
		}
	}

	static void AppendIndent(String output, StringView indent, int depth)
	{
		for (int i < depth)
			output.Append(indent);
	}

	/// Whether every child is an element, or text of whitespace only (comments and PIs too).
	bool IsElementOnly(XmlNodeRecord node)
	{
		for (uint32 id = node.mFirstChild; id != 0; id = mNodes[id].mNextSibling)
		{
			ref XmlNodeRecord child = ref mNodes[id];
			if (child.mKind == .CData || child.mKind == .EntityReference || (child.mKind == .Text && !IsWhitespace(child.mValue)))
				return false;
		}
		return true;
	}

	/// Whether any child is not whitespace-only text (indented content that is all whitespace is empty).
	bool HasElementChild(XmlNodeRecord node)
	{
		for (uint32 id = node.mFirstChild; id != 0; id = mNodes[id].mNextSibling)
		{
			if (mNodes[id].mKind != .Text)
				return true;
		}
		return false;
	}

	static bool IsWhitespace(StringView text)
	{
		for (let c in text)
		{
			if (!XmlChar.IsSpace(c))
				return false;
		}
		return true;
	}

	/// `<name` and the specified attributes.
	void WriteStartTag(XmlNodeRecord node, String output)
	{
		output.Append('<');
		output.Append(mNames[node.mName]);
		for (int i = node.mAttributeStart; i < node.mAttributeStart + node.mAttributeCount; i++)
		{
			ref XmlAttributeRecord attribute = ref mAttributes[i];
			if (attribute.mFlags.HasFlag(.Defaulted))
				continue;
			output.Append(' ');
			output.Append(mNames[attribute.mName]);
			output.Append("=\"");
			AppendAttributeEscaped(output, attribute.mValue);
			output.Append('"');
		}
	}

	/// A node without children: text, CDATA, a comment, a processing instruction, an entity reference.
	void WriteLeaf(XmlNodeRecord node, String output)
	{
		switch (node.mKind)
		{
		case .Text:
			AppendTextEscaped(output, node.mValue);
		case .CData:
			output.Append("<![CDATA[");
			// `]]>` cannot be inside a CDATA section: end it there and start another
			int run = 0;
			for (int i = 0; i + 2 < node.mValue.Length; i++)
			{
				if (node.mValue[i] == ']' && node.mValue[i + 1] == ']' && node.mValue[i + 2] == '>')
				{
					output.Append(node.mValue.Substring(run, i + 2 - run));
					output.Append("]]><![CDATA[");
					run = i + 2;
				}
			}
			output.Append(node.mValue.Substring(run));
			output.Append("]]>");
		case .Comment:
			output.Append("<!--");
			output.Append(node.mValue);
			output.Append("-->");
		case .ProcessingInstruction:
			output.Append("<?");
			output.Append(mNames[node.mName]);
			if (!node.mValue.IsEmpty)
			{
				output.Append(' ');
				output.Append(node.mValue);
			}
			output.Append("?>");
		case .EntityReference:
			output.Append('&');
			output.Append(mNames[node.mName]);
			output.Append(';');
		default:
		}
	}

	void WriteDocType(String output)
	{
		output.Append("<!DOCTYPE ");
		output.Append(mNames[mNodes[mDocType].mName]);
		if (mHasPublicId)
		{
			output.Append(" PUBLIC \"");
			output.Append(mPublicId);
			output.Append('"');
			if (mHasSystemId)
			{
				output.Append(' ');
				AppendQuoted(output, mSystemId);
			}
		}
		else if (mHasSystemId)
		{
			output.Append(" SYSTEM ");
			AppendQuoted(output, mSystemId);
		}
		if (mHasInternalSubset)
		{
			output.Append(" [");
			output.Append(mInternalSubset);
			output.Append(']');
		}
		output.Append('>');
	}

	/// A system literal in double quotes, or single ones when it contains a double quote.
	static void AppendQuoted(String output, StringView literal)
	{
		char8 quote = literal.Contains('"') ? '\'' : '"';
		output.Append(quote);
		output.Append(literal);
		output.Append(quote);
	}

	/// Text: `&` and `<` escaped, `>` after `]]`, and CR as `&#13;` (a literal one would be read as a
	/// line end).
	internal static void AppendTextEscaped(String output, StringView text)
	{
		int run = 0;
		for (int i < text.Length)
		{
			StringView escape;
			switch (text[i])
			{
			case '&': escape = "&amp;";
			case '<': escape = "&lt;";
			case '\r': escape = "&#13;";
			case '>':
				if (i < 2 || text[i - 1] != ']' || text[i - 2] != ']')
					continue;
				escape = "&gt;";
			default: continue;
			}
			output.Append(text.Substring(run, i - run));
			output.Append(escape);
			run = i + 1;
		}
		output.Append(text.Substring(run));
	}

	/// Attribute values (double-quoted): `&`, `<` and `"` escaped, and tab, LF and CR as character
	/// references (literal ones would be normalized to spaces).
	internal static void AppendAttributeEscaped(String output, StringView text)
	{
		AppendAttributeEscaped(output, text, '"');
	}

	/// Attribute values in `quote` (`"` or `'`): `&`, `<` and the quote escaped, and tab, LF and CR as
	/// character references.
	internal static void AppendAttributeEscaped(String output, StringView text, char8 quote)
	{
		int run = 0;
		for (int i < text.Length)
		{
			StringView escape;
			char8 c = text[i];
			if (c == quote)
				escape = quote == '"' ? "&quot;" : "&apos;";
			else switch (c)
			{
			case '&': escape = "&amp;";
			case '<': escape = "&lt;";
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
