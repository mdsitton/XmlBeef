using System;

namespace XmlBeef;

/// Where a node or attribute came from in the source (see XmlMetadataMode.Positions).
public struct XmlSourceRange
{
	/// @brief Name of the source (XmlReadConfig.SourceName, or the path for ReadFile); empty if unnamed.
	/// Borrowed from the document: valid until it is cleared, read again or deleted.
	public StringView mSource;
	/// @brief 1-based line of the start.
	public int mLine;
	/// @brief 1-based column of the start, in code points.
	public int mColumn;
	/// @brief Byte offset of the start (in UTF-8 terms when the input was transcoded).
	public int mOffset;
	/// @brief Length in bytes: an element from its `<` through its end tag (or `/>`); an attribute from
	/// its name through its value's closing quote; other nodes their construct. Inside an entity's
	/// replacement text, the range is the outermost reference's.
	public int mLength;

	public this(int line, int column, int offset, int length, StringView source = default)
	{
		mSource = source;
		mLine = line;
		mColumn = column;
		mOffset = offset;
		mLength = length;
	}

	/// @brief Formats the position as `source:line:column`, or `line:column` without a source name.
	/// @param strBuffer The string to append to.
	public override void ToString(String strBuffer)
	{
		if (!mSource.IsEmpty)
		{
			strBuffer.Append(mSource);
			strBuffer.Append(':');
		}
		strBuffer.AppendF("{}:{}", mLine, mColumn);
	}
}
