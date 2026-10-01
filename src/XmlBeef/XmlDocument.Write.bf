using System;
using System.Collections;
using internal XmlBeef;

namespace XmlBeef;

/// @brief How XmlDocument.Write formats the document, and how WriteBytes and WriteFile treat
/// characters the document's encoding cannot hold.
public struct XmlWriteOptions
{
	/// @brief The indentation unit (`"  "`, `"\t"`); empty for none. Indentation is added only inside
	/// elements whose content is elements alone (whitespace-only text there is replaced by it); an
	/// element with text or CDATA content, and everything inside it, is written as it is. Canonical
	/// form only: a PreserveStyle document keeps its own layout.
	public StringView Indent = default;
	/// @brief WriteBytes and WriteFile: what to do with a character the document's encoding cannot hold
	/// (a value set in code, say `✓` in a Windows-1251 document).
	public XmlUnencodable Unencodable = .Error;
	/// @brief Unencodable.Replace: the text written instead of such a character (it must itself be
	/// encodable and valid where it goes).
	public StringView Replacement = "?";
	/// @brief Unencodable.Custom: decides for each such character.
	public XmlUnencodableHandler Handler = null;
}

/// @brief What WriteBytes and WriteFile do with a character the document's encoding cannot hold.
public enum XmlUnencodable
{
	/// @brief Fail with an error naming the character (the default).
	Error,
	/// @brief Write a character reference (`&#x2713;`) in text and attribute values, and in a CDATA
	/// section around one (`]]>&#x2713;<![CDATA[`): nothing is lost. In comments, processing
	/// instructions and names XML has no escape: still an error there.
	CharacterReference,
	/// @brief Write XmlWriteOptions.Replacement instead, anywhere but in names (still an error there).
	Replace,
	/// @brief Write the whole document in UTF-8 instead, when it has such a character; a PreserveStyle
	/// document's XML declaration then says `encoding="UTF-8"`, and nothing else changes.
	Utf8,
	/// @brief Ask XmlWriteOptions.Handler.
	Custom
}

/// @brief Where a character is in the written document.
public enum XmlTextContext
{
	Text,
	AttributeValue,
	CData,
	Comment,
	ProcessingInstruction
}

/// @brief Decides what to write for a character the document's encoding cannot hold.
/// @param c The character.
/// @param context Where it is.
/// @param replacement Receives the text to write instead, as written (it must be encodable and valid
/// where it goes: a character reference is valid only in text and attribute values).
/// @return False to fail with an error instead.
public delegate bool XmlUnencodableHandler(char32 c, XmlTextContext context, String replacement);

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
			int valueStart = output.Length;
			AppendAttributeEscaped(output, attribute.mValue);
			FixUnencodable(output, valueStart, .AttributeValue);
			output.Append('"');
		}
	}

	/// A node without children: text, CDATA, a comment, a processing instruction, an entity reference.
	void WriteLeaf(XmlNodeRecord node, String output)
	{
		int start = output.Length;
		switch (node.mKind)
		{
		case .Text:
			AppendTextEscaped(output, node.mValue);
			FixUnencodable(output, start, .Text);
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
			FixUnencodable(output, start, .CData);
		case .Comment:
			output.Append("<!--");
			output.Append(node.mValue);
			FixUnencodable(output, start, .Comment);
			output.Append("-->");
		case .ProcessingInstruction:
			output.Append("<?");
			output.Append(mNames[node.mName]);
			if (!node.mValue.IsEmpty)
			{
				output.Append(' ');
				int dataStart = output.Length;
				output.Append(node.mValue);
				FixUnencodable(output, dataStart, .ProcessingInstruction);
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
		if (mHasInternalSubset || mNodes[mDocType].mFirstChild != 0)
		{
			output.Append(" [");
			AppendInternalSubset(output, mInternalSubset);
			output.Append(']');
		}
		output.Append('>');
	}

	/// The internal subset `subset` (its text as read) with the DOCTYPE's current children: each
	/// processing instruction read from it kept as written, regenerated where it was if changed, dropped
	/// (with its line) if removed or moved away; comments and processing instructions added to the
	/// DOCTYPE appended at the end.
	internal void AppendInternalSubset(String output, StringView subset)
	{
		int pos = 0;
		for (let item in mSubsetItems)
		{
			output.Append(subset.Substring(pos, item.mStart - pos));
			ref XmlNodeRecord node = ref mNodes[item.mId];
			pos = item.mEnd;
			if (!node.mFlags.HasFlag(.Removed) && mDocType != 0 && node.mParent == mDocType)
			{
				if (node.mFlags.HasFlag(.Edited))
					WriteLeaf(node, output);
				else
					output.Append(subset.Substring(item.mStart, item.mEnd - item.mStart));
				continue;
			}
			// Gone: alone on its line, the line goes with it
			int newline = (pos < subset.Length) ? XmlChar.NewlineLength(subset.Ptr, pos, subset.Length) : 0;
			int indent = output.Length;
			while (indent > 0 && (output[indent - 1] == ' ' || output[indent - 1] == '\t'))
				indent--;
			if (newline > 0 && (indent == 0 || output[indent - 1] == '\n'))
			{
				output.Length = indent;
				pos += newline;
			}
		}
		output.Append(subset.Substring(pos));
		if (mDocType == 0)
			return;
		// Added ones, at the end (on lines of their own when the subset is laid out in lines)
		bool lines = subset.Contains('\n');
		for (uint32 id = mNodes[mDocType].mFirstChild; id != 0; id = mNodes[id].mNextSibling)
		{
			ref XmlNodeRecord node = ref mNodes[id];
			if (node.mFlags.HasFlag(.InSubsetText) || node.mFlags.HasFlag(.FromEntity))
				continue;
			if (lines && !output.EndsWith('\n'))
				output.Append('\n');
			WriteLeaf(node, output);
			if (lines)
				output.Append('\n');
		}
	}

	/// A system literal in double quotes, or single ones when it contains a double quote.
	static void AppendQuoted(String output, StringView literal)
	{
		char8 quote = literal.Contains('"') ? '\'' : '"';
		output.Append(quote);
		output.Append(literal);
		output.Append(quote);
	}

	/// During WriteBytes with a policy for unencodable characters: applies it to the piece written from
	/// `start` on (a generated text, attribute value, CDATA section, comment or PI's data). What it
	/// leaves is the encoder's error.
	internal void FixUnencodable(String output, int start, XmlTextContext context)
	{
		if (!mFixing)
			return;
		int i = start;
		let replacement = scope String();
		while (i < output.Length)
		{
			if ((uint8)output[i] < 0x80)
			{
				i++;
				continue;
			}
			char32 c = XmlChar.Decode(output.Ptr, i, let length);
			if (XmlEncoder.CanEncode(c, mFixEncoding))
			{
				i += length;
				continue;
			}
			replacement.Clear();
			bool replace = false;
			switch (mFixOptions.Unencodable)
			{
			case .CharacterReference:
				if (context == .Text || context == .AttributeValue || context == .CData)
				{
					if (context == .CData)
						replacement.Append("]]>");
					replacement.Append("&#x");
					XmlChar.AppendHex(replacement, (uint32)c, 1);
					replacement.Append(';');
					if (context == .CData)
						replacement.Append("<![CDATA[");
					replace = true;
				}
			case .Replace:
				replacement.Append(mFixOptions.Replacement);
				replace = true;
			case .Custom:
				replace = mFixOptions.Handler != null && mFixOptions.Handler(c, context, replacement);
			default:
			}
			if (!replace)
			{
				i += length;
				continue;
			}
			output.Remove(i, length);
			output.Insert(i, replacement);
			i += replacement.Length;
		}
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
